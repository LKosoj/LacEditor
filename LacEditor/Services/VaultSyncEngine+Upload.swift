import Foundation

/// Хозяин открытых вкладок (менеджер окон): только он меняет текст открытого документа, иначе поднимется
/// «файл изменён на диске». Движок просит его записать объединённый текст.
@MainActor
protocol VaultUploadHost: AnyObject {
    /// Применить объединённый текст к открытому документу `serverPath`. `expectedFileText` — текст, который сейчас в файле;
    /// если в редакторе что-то другое (есть ввод после сохранения) — вернуть `.busy`.
    func applyMergedText(_ text: String, serverPath: String, expectedFileText: String) async -> VaultApplyResult
    /// Движок сам записал файл (`.engineMayWrite`): тихо перечитать документ, если он открыт.
    func fileRewritten(serverPath: String) async
}

/// Состояние очереди отправки. Живёт внутри `VaultSyncEngine`, трогается только из актора.
final class VaultUploadState {
    weak var host: VaultUploadHost?
    var loopTask: Task<Void, Never>?
    var wakeTask: Task<Void, Never>?
    var retryAfter: [String: Date] = [:]
    var attempts: [String: Int] = [:]
    var rejectedTries: [String: Int] = [:]
    var mergeRounds: [String: Int] = [:]
    /// Пути, которые уже пробовали в этой серии: один путь — одна попытка за серию.
    var attempted: Set<String> = []
    /// Пути, которые идут первыми и мимо пауз и отказов («Отправить сейчас»).
    var forced: [String] = []
    var isAuthPaused = false
    var sentInRun = 0
    var lastSent = 0
    var pathWaiters: [String: [VaultWaiter<VaultUploadOutcome>]] = [:]
    var loopWaiters: [VaultWaiter<Void>] = []
}

/// Отправка правок открытых заметок: очередь, трёхстороннее объединение при 409, конфликты, «Неотправленное».
///
/// Порядок при объединении всегда один: (а) файл на диске становится объединённым текстом → (б) база сдвигается на версию
/// сервера → (в) `PUT` с `If-Match` = ETag сервера. Если приложение умрёт между (а) и (б), следующий `PUT` даст 409,
/// а объединение «старая база, объединённый, сервер» не увидит пересечений: строки сервера не затираются.
/// Отправка никогда не отменяется на лету; результат запроса принимается всегда (он факт), сверка идёт по SHA-256 файла.
extension VaultSyncEngine {
    static let maxUploadBytes = 16 * 1024 * 1024

    private enum MergeStep {
        case again
        case done(VaultUploadOutcome)
    }

    // MARK: Публичные операции

    func setUploadHost(_ host: VaultUploadHost?) {
        uploadState.host = host
    }

    /// После каждого сохранения файла заметки: ставит её в очередь (или снимает метку, если текст равен базе).
    func enqueueUpload(serverPath: String) async {
        loadStateIfNeeded()
        // Новое сохранение — новая попытка: токен могли поправить.
        _ = clearAuthPause()
        enqueue(serverPath, immediate: false)
    }

    /// Отправляет одну заметку вне очереди и ждёт итог не дольше `timeout`; по таймеру запрос не отменяется.
    func uploadNow(serverPath: String, timeout: TimeInterval? = nil) async -> VaultUploadOutcome {
        loadStateIfNeeded()
        guard !isShutdown, !isStateUnavailable else { return .offline }
        guard recordsByPath[serverPath] != nil else { return .notQueued }
        enqueue(serverPath, immediate: true)
        guard var record = recordsByPath[serverPath] else { return .notQueued }
        switch record.state {
        case .synced: return .alreadySynced
        case .conflict: return .conflict
        case .deletedOnServer: return .deletedOnServer
        case .loading, .newerOnServer: return .notQueued
        case .modified, .uploading: break
        }
        _ = clearAuthPause()
        uploadState.attempts[serverPath] = nil
        uploadState.rejectedTries[serverPath] = nil
        if record.uploadIssue != nil {
            record.uploadIssue = nil
            record.uploadIssueDetail = nil
            recordsByPath[serverPath] = record
            persistOrBlock()
            emit(.uploadIssue(serverPath: serverPath, nil))
        }
        if record.state != .uploading {
            uploadState.retryAfter[serverPath] = nil
            uploadState.attempted.remove(serverPath)
            if !uploadState.forced.contains(serverPath) { uploadState.forced.append(serverPath) }
        }
        let waiter = VaultWaiter<VaultUploadOutcome>()
        uploadState.pathWaiters[serverPath, default: []].append(waiter)
        if let timeout { Self.finishLater(waiter, after: timeout, with: .timedOut) }
        startLoop()
        return await waiter.wait()
    }

    /// Отправляет всю очередь и ждёт, пока она разберётся (или `timeout`). Запросы по таймеру не отменяются.
    func uploadPending(timeout: TimeInterval? = nil) async -> VaultUploadSummary {
        loadStateIfNeeded()
        guard !isShutdown, !isStateUnavailable else { return uploadSummary() }
        _ = clearAuthPause()
        for record in recordsByPath.values where record.state == .modified && record.uploadIssue == nil {
            uploadState.retryAfter[record.serverPath] = nil
        }
        let waiter = VaultWaiter<Void>()
        uploadState.loopWaiters.append(waiter)
        if let timeout { Self.finishLater(waiter, after: timeout, with: ()) }
        startLoop()
        await waiter.wait()
        return uploadSummary()
    }

    func pendingUploads() -> [VaultOpenNoteRecord] {
        loadStateIfNeeded()
        return Self.byQueueOrder(recordsByPath.values.filter { $0.state == .modified || $0.state == .uploading })
    }

    func conflictRecords() -> [VaultOpenNoteRecord] {
        loadStateIfNeeded()
        return Self.byQueueOrder(recordsByPath.values.filter { $0.state == .conflict })
    }

    /// Текст основы (версии сервера, на которой построен файл) для открытой заметки; nil — основы нет.
    func baseText(serverPath: String) -> String? {
        loadStateIfNeeded()
        return readBaseText(serverPath)
    }

    // MARK: Конфликт

    /// Данные для листа конфликта. Версия сервера читается заново; сервер мог уже совпасть с нашим текстом.
    func conflictContext(serverPath: String) async throws -> VaultConflictLoad {
        loadStateIfNeeded()
        guard let record = recordsByPath[serverPath], record.state == .conflict else { throw VaultSyncError.notOpen }
        let file = try await perform { try await client.file(path: serverPath) }
        guard recordsByPath[serverPath]?.state == .conflict else { throw VaultSyncError.notOpen }
        guard let mineData = (try? store.readNote(serverPath: serverPath)) ?? nil,
              let mine = String(data: mineData, encoding: .utf8),
              let server = String(data: file.data, encoding: .utf8) else { throw VaultClientError.invalidResponse }
        heldServerVersions[serverPath] = (file.data, file.etag, file.modifiedNs)
        let base = readBaseText(serverPath) ?? ""
        let outcome = await Task.detached(priority: .userInitiated) { VaultMerge.merge(base: base, mine: mine, server: server) }.value
        guard recordsByPath[serverPath]?.state == .conflict, currentFileSHA(serverPath) == VaultClient.sha256Hex(mineData) else {
            throw VaultSyncError.notOpen
        }
        switch outcome {
        case .merged:
            // Сервер вернулся к прежнему тексту: правки больше не пересекаются, обычная отправка сольёт сама.
            if var current = recordsByPath[serverPath] {
                current.state = .modified
                current.queuedSHA256 = VaultClient.sha256Hex(mineData)
                if current.queuedAt == nil { current.queuedAt = Date() }
                recordsByPath[serverPath] = current
                persistOrBlock()
                emit(.noteState(serverPath: serverPath, .modified))
            }
            uploadState.retryAfter[serverPath] = nil
            uploadState.attempted.remove(serverPath)
            scheduleLoopWake()
            return .noLongerConflicting
        case .conflict(let conflict):
            return .conflict(VaultConflictContext(serverPath: serverPath, base: base, mine: mine, server: server,
                                                  serverETag: file.etag, conflict: conflict))
        }
    }

    /// Две страховочные копии перед применением решения. false — хоть одна не записалась: решение не применяется.
    func saveConflictSnapshots(serverPath: String, context: VaultConflictContext) async -> Bool {
        guard let url = store.noteURL(for: serverPath) else { return false }
        let location = DocumentSnapshotLocation.file(path: url.standardizedFileURL.path)
        let time = Self.timeLabel()
        do {
            try snapshotStore.add(text: context.mine, name: L10n.tr("解决冲突前：你的版本") + " " + time, encodingName: "UTF-8",
                                  location: location, keepLast: configuration.snapshotKeepLast)
            try snapshotStore.add(text: context.server, name: L10n.tr("解决冲突前：服务器版本") + " " + time, encodingName: "UTF-8",
                                  location: location, keepLast: configuration.snapshotKeepLast)
            return true
        } catch {
            return false
        }
    }

    /// Вызывается после того, как интерфейс записал `text` в файл заметки. Основа сдвигается на версию сервера, с которой решал
    /// человек (`serverETag`); дальше обычная отправка. Новый 409 снова даёт объединение или новый конфликт.
    func resolveConflict(serverPath: String, text: String, serverETag: String) async -> VaultUploadOutcome {
        loadStateIfNeeded()
        guard !isShutdown, var record = recordsByPath[serverPath], record.state == .conflict else { return .notQueued }
        let data = Data(text.utf8)
        let sha = VaultClient.sha256Hex(data)
        guard currentFileSHA(serverPath) == sha else { return .fileChanged }
        var version = heldServerVersions[serverPath]
        if version?.etag != serverETag {
            do {
                let file = try await perform { try await client.file(path: serverPath) }
                version = (file.data, file.etag, file.modifiedNs)
            } catch let error as VaultClientError where error == .offline || error == .timeout {
                return .offline
            } catch {
                return .retryLater
            }
        }
        guard let version, version.etag == serverETag else { return .fileChanged }
        guard let current = recordsByPath[serverPath], current.state == .conflict, currentFileSHA(serverPath) == sha else {
            return .fileChanged
        }
        record = current
        do { try store.writeBase(version.data, serverPath: serverPath) } catch { return .retryLater }
        record.baseETag = version.etag
        record.baseModifiedNs = version.modifiedNs
        record.baseSize = version.data.count
        record.state = .modified
        record.queuedSHA256 = sha
        if record.queuedAt == nil { record.queuedAt = Date() }
        record.uploadIssue = nil
        record.uploadIssueDetail = nil
        recordsByPath[serverPath] = record
        heldServerVersions[serverPath] = nil
        uploadState.mergeRounds[serverPath] = nil
        persistOrBlock()
        emit(.noteState(serverPath: serverPath, .modified))
        return await uploadNow(serverPath: serverPath)
    }

    /// «Отменить мои правки»: закрытая заметка удаляется с диска совсем; у открытой отдаётся текст основы,
    /// файл меняет редактор (отменяемой заменой), после чего `enqueueUpload` увидит «текст = база».
    func discardLocalChanges(serverPath: String, tabIsClosing: Bool = false) async -> VaultDiscardResult {
        loadStateIfNeeded()
        guard let record = recordsByPath[serverPath] else { return .notFound }
        if record.state == .uploading { return .busy }
        if !record.isOpenInTab || tabIsClosing {
            guard removeLocal(serverPath: serverPath) else { return .busy }
            forget(serverPath)
            return .removed
        }
        guard let base = readBaseText(serverPath) else { return .busy }
        return .revertTo(base)
    }

    // MARK: Постановка в очередь

    @discardableResult
    private func enqueue(_ path: String, immediate: Bool) -> Bool {
        guard !isShutdown, !isStateUnavailable, var record = recordsByPath[path] else { return false }
        switch record.state {
        case .conflict, .deletedOnServer, .loading: return false
        default: break
        }
        let data: Data
        do {
            guard let read = try store.readNote(serverPath: path) else { return false }
            data = read
        } catch {
            return false
        }
        let sha = VaultClient.sha256Hex(data)
        if record.state == .uploading {
            // Запрос в полёте: после ответа он сам сверит файл и пошлёт новую версию.
            record.queuedSHA256 = sha
            recordsByPath[path] = record
            persistOrBlock()
            return true
        }
        if sha == record.baseETag {
            markSyncedEqualToBase(path)
            return false
        }
        record.state = .modified
        record.queuedSHA256 = sha
        if record.queuedAt == nil { record.queuedAt = Date() }
        let hadIssue = record.uploadIssue != nil
        record.uploadIssue = nil
        record.uploadIssueDetail = nil
        recordsByPath[path] = record
        persistOrBlock()
        uploadState.attempted.remove(path)
        uploadState.attempts[path] = nil
        uploadState.rejectedTries[path] = nil
        uploadState.retryAfter[path] = immediate ? nil : Date().addingTimeInterval(configuration.uploadDebounce)
        emit(.noteState(serverPath: path, .modified))
        if hadIssue { emit(.uploadIssue(serverPath: path, nil)) }
        scheduleLoopWake()
        return true
    }

    /// Текст равен базе (правки отменены или уже на сервере): метка снимается, закрытая заметка убирается с диска.
    private func markSyncedEqualToBase(_ path: String) {
        guard var record = recordsByPath[path] else { return }
        let hadIssue = record.uploadIssue != nil
        record.state = .synced
        record.queuedSHA256 = nil
        record.queuedAt = nil
        record.uploadIssue = nil
        record.uploadIssueDetail = nil
        recordsByPath[path] = record
        forget(path)
        persistOrBlock()
        emit(.noteState(serverPath: path, .synced))
        if hadIssue { emit(.uploadIssue(serverPath: path, nil)) }
        if !record.isOpenInTab { removeLocal(serverPath: path) }
    }

    // MARK: Цикл отправки

    private func startLoop() {
        guard !isShutdown, uploadState.loopTask == nil else { return }
        uploadState.wakeTask?.cancel()
        uploadState.wakeTask = nil
        uploadState.loopTask = Task { await self.runUploadLoop() }
    }

    /// Будит цикл в момент, когда ближайшая заметка станет готова к отправке. Без связи не будит: вернётся связь, и цикл пойдёт сам.
    func scheduleLoopWake() {
        guard !isShutdown, uploadState.loopTask == nil else { return }
        uploadState.wakeTask?.cancel()
        uploadState.wakeTask = nil
        guard online, !uploadState.isAuthPaused else { return }
        let candidates = recordsByPath.values.filter { $0.state == .modified && $0.uploadIssue == nil }
        guard let earliest = candidates.map({ uploadState.retryAfter[$0.serverPath] ?? .distantPast }).min() else { return }
        let delay = earliest.timeIntervalSinceNow
        if delay <= 0 {
            startLoop()
            return
        }
        uploadState.wakeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.wakeFired()
        }
    }

    private func wakeFired() {
        uploadState.wakeTask = nil
        startLoop()
    }

    /// Связь вернулась: паузы повторов снимаются, очередь идёт сразу.
    func resumeUploadsAfterReconnect() {
        guard !isShutdown, isLoadedForUpload else { return }
        uploadState.retryAfter = [:]
        _ = clearAuthPause()
        scheduleLoopWake()
    }

    /// 401: очередь стоит, пока токен не исправят; сессия показывает причину в строке состояния.
    private func pauseForAuth() {
        guard !uploadState.isAuthPaused else { return }
        uploadState.isAuthPaused = true
        emit(.authPaused(true))
    }

    /// Пауза снимается новой попыткой, возвратом связи и любым успешным ответом сервера. true — пауза была.
    @discardableResult
    func clearAuthPause() -> Bool {
        guard uploadState.isAuthPaused else { return false }
        uploadState.isAuthPaused = false
        emit(.authPaused(false))
        return true
    }

    private var isLoadedForUpload: Bool { !recordsByPath.isEmpty }

    /// После перезапуска запись «Отправляется…» превращается в «Не отправлено»: повтор даст 409 «своей записи» или успех.
    func normalizeInterruptedUploads() {
        var changed = false
        for (path, var record) in recordsByPath where record.state == .uploading || record.uploadIssue == .unauthorized {
            if record.state == .uploading { record.state = .modified }
            if record.uploadIssue == .unauthorized { record.uploadIssue = nil; record.uploadIssueDetail = nil }
            recordsByPath[path] = record
            changed = true
        }
        if changed { persistOrBlock() }
    }

    /// Останавливает таймеры и будит ожидающих: запрос в полёте не отменяется, его результат всё равно записывается.
    func cancelUploadTimers() {
        uploadState.wakeTask?.cancel()
        uploadState.wakeTask = nil
        for waiters in uploadState.pathWaiters.values { waiters.forEach { $0.finish(.timedOut) } }
        uploadState.pathWaiters = [:]
        uploadState.loopWaiters.forEach { $0.finish(()) }
        uploadState.loopWaiters = []
    }

    private func nextUploadCandidate() -> String? {
        for path in uploadState.forced {
            if let record = recordsByPath[path], record.state == .modified || record.state == .uploading,
               !uploadState.attempted.contains(path) {
                return path
            }
        }
        guard online, !uploadState.isAuthPaused else { return nil }
        let now = Date()
        let ready = recordsByPath.values.filter {
            ($0.state == .modified || $0.state == .uploading) && $0.uploadIssue == nil
                && !uploadState.attempted.contains($0.serverPath)
                && (uploadState.retryAfter[$0.serverPath] ?? .distantPast) <= now
        }
        return Self.byQueueOrder(ready).first?.serverPath
    }

    private func runUploadLoop() async {
        uploadState.attempted = []
        uploadState.sentInRun = 0
        outer: while !isShutdown {
            while !isShutdown, let path = nextUploadCandidate() {
                uploadState.attempted.insert(path)
                uploadState.forced.removeAll { $0 == path }
                let outcome = await uploadOne(path)
                completeAttempt(path, outcome)
                if case .issue(.unauthorized) = outcome {
                    pauseForAuth()
                    break outer
                }
            }
            let didClose = await closePendingServerConflicts()
            if !didClose || nextUploadCandidate() == nil { break }
        }
        // Дальше без приостановок: пока цикл «живой», новые постановки его не запускают.
        let sent = uploadState.sentInRun
        uploadState.lastSent = sent
        uploadState.loopTask = nil
        uploadState.forced.removeAll { recordsByPath[$0] == nil }
        for (path, waiters) in uploadState.pathWaiters {
            let outcome = settledOutcome(path)
            waiters.forEach { $0.finish(outcome) }
        }
        uploadState.pathWaiters = [:]
        let loopWaiters = uploadState.loopWaiters
        uploadState.loopWaiters = []
        loopWaiters.forEach { $0.finish(()) }
        if sent > 0 { emit(.uploadsFinished(sent: sent)) }
        scheduleLoopWake()
    }

    private func completeAttempt(_ path: String, _ outcome: VaultUploadOutcome) {
        if outcome == .sent { uploadState.sentInRun += 1 }
        if let record = recordsByPath[path], record.state == .modified, record.uploadIssue == nil {
            if outcome == .sent {
                // Пока шёл запрос, файл сохранили ещё раз: следующий проход без паузы.
                uploadState.attempted.remove(path)
                uploadState.retryAfter[path] = nil
            } else if (uploadState.retryAfter[path] ?? .distantPast) <= Date() {
                // Страховка от вращения вхолостую: без пометки заметка бралась бы снова сразу.
                uploadState.retryAfter[path] = Date().addingTimeInterval(max(configuration.uploadDebounce, 0.05))
            }
        }
        if let waiters = uploadState.pathWaiters.removeValue(forKey: path) { waiters.forEach { $0.finish(outcome) } }
    }

    /// Итог для ожидающего, чью заметку цикл не успел или не стал пробовать.
    private func settledOutcome(_ path: String) -> VaultUploadOutcome {
        guard let record = recordsByPath[path] else { return .notQueued }
        switch record.state {
        case .synced: return .alreadySynced
        case .conflict: return .conflict
        case .deletedOnServer: return .deletedOnServer
        case .modified, .uploading:
            if let issue = record.uploadIssue { return .issue(issue) }
            return online ? .retryLater : .offline
        default: return .notQueued
        }
    }

    private func uploadSummary() -> VaultUploadSummary {
        let unsent = recordsByPath.values.filter { $0.state == .modified || $0.state == .uploading }
        var issues: [String: VaultUploadIssue] = [:]
        for record in unsent { if let issue = record.uploadIssue { issues[record.serverPath] = issue } }
        return VaultUploadSummary(sent: uploadState.lastSent, remaining: Self.byQueueOrder(unsent).map(\.serverPath),
                                  conflicts: Self.byQueueOrder(recordsByPath.values.filter { $0.state == .conflict }).map(\.serverPath),
                                  issues: issues, isOffline: !online)
    }

    // MARK: Одна отправка

    private func uploadOne(_ path: String) async -> VaultUploadOutcome {
        let outcome = await performUpload(path)
        guard !isShutdown else { return outcome }
        if var record = recordsByPath[path], record.state == .uploading {
            record.state = .modified
            recordsByPath[path] = record
            persistOrBlock()
            emit(.noteState(serverPath: path, .modified))
        }
        return outcome
    }

    private func performUpload(_ path: String) async -> VaultUploadOutcome {
        while !isShutdown {
            guard let record = recordsByPath[path], record.state == .modified || record.state == .uploading else {
                return settledOutcome(path)
            }
            let data: Data
            do {
                guard let read = try store.readNote(serverPath: path) else { return .notQueued }
                data = read
            } catch {
                return .retryLater
            }
            let sha = VaultClient.sha256Hex(data)
            if sha == record.baseETag {
                markSyncedEqualToBase(path)
                return .alreadySynced
            }
            if data.count > Self.maxUploadBytes { return setIssue(path, .tooLarge, detail: nil) }
            guard let candidate = String(data: data, encoding: .utf8) else { return setIssue(path, .notUTF8, detail: nil) }
            let baseText = readBaseText(path) ?? ""
            guard VaultUploadCheck.allows(serverPath: path, base: baseText, candidate: candidate) else {
                return setIssue(path, .ownerNotesOnly, detail: "local-check")
            }
            var sending = record
            sending.state = .uploading
            sending.uploadIssue = nil
            sending.uploadIssueDetail = nil
            recordsByPath[path] = sending
            persistOrBlock()
            emit(.noteState(serverPath: path, .uploading))
            let baseETag = record.baseETag
            let result: VaultPutResult
            do {
                result = try await perform { try await client.put(path: path, data: data, ifMatch: baseETag) }
            } catch {
                // После остановки ничего не пишем: повтор при следующем запуске разберётся сам.
                guard !isShutdown else { return .retryLater }
                return handleUploadError(error, path: path)
            }
            // Ответ на идущий запрос после остановки выбрасывается: следующий запуск распознает «409 своей записи».
            guard !isShutdown else { return .retryLater }
            switch result {
            case .saved(let etag):
                finishSent(path, data: data, etag: etag)
                return .sent
            case .conflict(let conflictID, let currentETag):
                if currentETag == sha {
                    // Ответ на нашу же запись потерялся: объединять нечего.
                    finishSent(path, data: data, etag: currentETag)
                    await cancelServerConflict(path: path, id: conflictID)
                    return .sent
                }
                guard recordsByPath[path]?.baseETag == baseETag else { return .fileChanged }
                switch await mergeAfter409(path: path, data: data, sha: sha, conflictID: conflictID) {
                case .again: continue
                case .done(let outcome): return outcome
                }
            }
        }
        return .retryLater
    }

    /// Сервер принял запись: база становится отправленным текстом. Если за время запроса файл сохранили ещё раз,
    /// заметка остаётся в очереди с новым текстом.
    private func finishSent(_ path: String, data: Data, etag: String) {
        guard !isShutdown, var record = recordsByPath[path] else { return }
        do {
            try store.writeBase(data, serverPath: path)
        } catch {
            // База не записалась: ETag не сдвигаем, повтор даст 409 «своей записи» и починит.
            uploadState.retryAfter[path] = Date().addingTimeInterval(configuration.hostBusyDelay)
            return
        }
        let sentSHA = VaultClient.sha256Hex(data)
        record.baseETag = etag
        record.baseModifiedNs = nil
        record.baseSize = data.count
        // Время изменения неизвестно: по одному размеру серверную правку того же размера не заметить, поэтому сверка по содержимому.
        needsRecheck.insert(path)
        record.uploadIssue = nil
        record.uploadIssueDetail = nil
        uploadState.attempts[path] = nil
        uploadState.rejectedTries[path] = nil
        uploadState.mergeRounds[path] = nil
        heldServerVersions[path] = nil
        let now = (try? store.readNote(serverPath: path)) ?? nil
        if let now, VaultClient.sha256Hex(now) != sentSHA {
            record.state = .modified
            record.queuedSHA256 = VaultClient.sha256Hex(now)
            recordsByPath[path] = record
            persistOrBlock()
            emit(.noteState(serverPath: path, .modified))
        } else {
            record.state = .synced
            record.queuedSHA256 = nil
            record.queuedAt = nil
            recordsByPath[path] = record
            persistOrBlock()
            emit(.noteState(serverPath: path, .synced))
            if !record.isOpenInTab { removeLocal(serverPath: path) }
        }
        emit(.uploadIssue(serverPath: path, nil))
        emit(.lastSync(Date()))
    }

    // MARK: Ошибки

    private func handleUploadError(_ error: Error, path: String) -> VaultUploadOutcome {
        guard let clientError = error as? VaultClientError else { return .retryLater }
        switch clientError {
        case .offline, .timeout, .secureConnectionFailed:
            scheduleRetry(path)
            return .offline
        case .incompleteResponse:
            scheduleRetry(path)
            return .retryLater
        case .server(let status, _) where status >= 500:
            scheduleRetry(path)
            return .retryLater
        case .tooLarge:
            return setIssue(path, .tooLarge, detail: nil)
        case .forbidden:
            return setIssue(path, .forbidden, detail: nil)
        case .ownerNotesOnly(let reason):
            return reason == "not_utf8" ? setIssue(path, .notUTF8, detail: reason) : setIssue(path, .ownerNotesOnly, detail: reason)
        case .notFound:
            return markDeletedOnServer(path)
        case .unauthorized:
            // В записи не хранится: пауза `isAuthPaused` снимется при новом токене, и заметка уйдёт сама.
            return .issue(.unauthorized)
        default:
            // 428, 4xx и неразборчивые ответы: несколько повторов, потом отказ.
            let tries = (uploadState.rejectedTries[path] ?? 0) + 1
            uploadState.rejectedTries[path] = tries
            if tries >= 3 { return setIssue(path, .rejected, detail: nil) }
            scheduleRetry(path)
            return .retryLater
        }
    }

    private func scheduleRetry(_ path: String) {
        let attempts = (uploadState.attempts[path] ?? 0) + 1
        uploadState.attempts[path] = attempts
        let delays = configuration.uploadRetryDelays.isEmpty ? [5] : configuration.uploadRetryDelays
        uploadState.retryAfter[path] = Date().addingTimeInterval(max(delays[min(attempts - 1, delays.count - 1)], 0))
    }

    private func setIssue(_ path: String, _ issue: VaultUploadIssue, detail: String?) -> VaultUploadOutcome {
        if var record = recordsByPath[path] {
            record.state = .modified
            record.uploadIssue = issue
            record.uploadIssueDetail = detail
            recordsByPath[path] = record
            persistOrBlock()
            emit(.noteState(serverPath: path, .modified))
        }
        emit(.uploadIssue(serverPath: path, issue))
        return .issue(issue)
    }

    private func markDeletedOnServer(_ path: String) -> VaultUploadOutcome {
        heldServerVersions[path] = nil
        setState(.deletedOnServer, for: path)
        return .deletedOnServer
    }

    // MARK: Объединение при 409

    private func mergeAfter409(path: String, data: Data, sha: String, conflictID: String) async -> MergeStep {
        let server: VaultFile
        do {
            server = try await perform { try await client.file(path: path) }
        } catch VaultClientError.notFound {
            return .done(markDeletedOnServer(path))
        } catch {
            guard !isShutdown else { return .done(.retryLater) }
            return .done(handleUploadError(error, path: path))
        }
        guard !isShutdown else { return .done(.retryLater) }
        await cancelServerConflict(path: path, id: conflictID)
        guard !isShutdown, let record = recordsByPath[path], record.state == .modified || record.state == .uploading else {
            return .done(settledOutcome(path))
        }
        if server.etag == sha {
            finishSent(path, data: data, etag: server.etag)
            return .done(.sent)
        }
        guard currentFileSHA(path) == sha else { return .done(.fileChanged) }

        let rounds = (uploadState.mergeRounds[path] ?? 0) + 1
        uploadState.mergeRounds[path] = rounds
        if rounds > max(configuration.maxMergeRounds, 1) {
            uploadState.mergeRounds[path] = 0
            uploadState.retryAfter[path] = Date().addingTimeInterval(configuration.mergePause)
            return .done(.retryLater)
        }

        guard let mine = String(data: data, encoding: .utf8), let serverText = String(data: server.data, encoding: .utf8) else {
            return .done(setIssue(path, .notUTF8, detail: nil))
        }
        let baseText = readBaseText(path) ?? ""
        let outcome = await Task.detached(priority: .userInitiated) {
            VaultMerge.merge(base: baseText, mine: mine, server: serverText)
        }.value
        // Пока считалось объединение, всё могло измениться: тогда попытка бросается и берётся заново.
        guard !isShutdown, let after = recordsByPath[path], after.baseETag == record.baseETag,
              after.state == .modified || after.state == .uploading, currentFileSHA(path) == sha else {
            return .done(.fileChanged)
        }
        switch outcome {
        case .conflict:
            var held = after
            held.state = .conflict
            held.queuedSHA256 = nil
            held.uploadIssue = nil
            held.uploadIssueDetail = nil
            recordsByPath[path] = held
            heldServerVersions[path] = (server.data, server.etag, server.modifiedNs)
            persistOrBlock()
            emit(.noteState(serverPath: path, .conflict))
            return .done(.conflict)
        case .merged(let merged):
            guard VaultUploadCheck.allows(serverPath: path, base: serverText, candidate: merged) else {
                return .done(setIssue(path, .ownerNotesOnly, detail: "local-check"))
            }
            // Страховка: моя версия до объединения. Не записалась — объединение всё равно идёт (текст есть в файле и в результате).
            if let url = store.noteURL(for: path) {
                try? snapshotStore.add(text: mine, name: L10n.tr("合并前：你的版本") + " " + Self.timeLabel(), encodingName: "UTF-8",
                                       location: .file(path: url.standardizedFileURL.path), keepLast: configuration.snapshotKeepLast)
            }
            let mergedData = Data(merged.utf8)
            guard await applyMergedFile(path, merged: mergedData, mergedText: merged, previousText: mine, previousData: data),
                  !isShutdown else {
                uploadState.retryAfter[path] = Date().addingTimeInterval(configuration.hostBusyDelay)
                return .done(.retryLater)
            }
            return shiftBase(path, to: server, mergedData: mergedData, equalsServer: mergedData == server.data)
        }
    }

    /// Шаг (а): файл становится объединённым текстом. Открытой вкладкой владеет хозяин (редактор), иначе пишет движок.
    private func applyMergedFile(_ path: String, merged: Data, mergedText: String, previousText: String, previousData: Data) async -> Bool {
        guard !isShutdown else { return false }
        let mergedSHA = VaultClient.sha256Hex(merged)
        let isOpen = recordsByPath[path]?.isOpenInTab == true
        if isOpen {
            guard let host = uploadState.host else { return false }
            switch await host.applyMergedText(mergedText, serverPath: path, expectedFileText: previousText) {
            case .busy:
                return false
            case .applied:
                return currentFileSHA(path) == mergedSHA
            case .engineMayWrite:
                guard writeIfUnchanged(path, merged: merged, previousData: previousData) else { return false }
                await host.fileRewritten(serverPath: path)
                return true
            }
        }
        return writeIfUnchanged(path, merged: merged, previousData: previousData)
    }

    /// Пишет файл, только если он всё ещё тот текст, который отправлялся (проверка и запись без приостановок).
    private func writeIfUnchanged(_ path: String, merged: Data, previousData: Data) -> Bool {
        guard let current = (try? store.readNote(serverPath: path)) ?? nil else { return false }
        if current == merged { return true }
        guard current == previousData else { return false }
        return (try? store.writeNote(merged, serverPath: path)) != nil
    }

    /// Шаг (б): база сдвигается на версию сервера. Дальше цикл сразу шлёт `PUT` с её ETag (файл уже объединённый).
    private func shiftBase(_ path: String, to server: VaultFile, mergedData: Data, equalsServer: Bool) -> MergeStep {
        guard !isShutdown else { return .done(.retryLater) }
        guard var record = recordsByPath[path] else { return .done(.notQueued) }
        do {
            try store.writeBase(server.data, serverPath: path)
        } catch {
            // Файл уже объединённый, база старая: следующий PUT даст 409, и объединение не увидит пересечений.
            uploadState.retryAfter[path] = Date().addingTimeInterval(configuration.hostBusyDelay)
            return .done(.retryLater)
        }
        record.baseETag = server.etag
        record.baseModifiedNs = server.modifiedNs
        record.baseSize = server.data.count
        heldServerVersions[path] = nil
        if equalsServer {
            // Мои правки уже есть на сервере: отправлять нечего.
            record.state = .synced
            record.queuedSHA256 = nil
            record.queuedAt = nil
        } else {
            record.state = .modified
            record.queuedSHA256 = VaultClient.sha256Hex(mergedData)
        }
        recordsByPath[path] = record
        persistOrBlock()
        emit(.merged(serverPath: path))
        emit(.noteState(serverPath: path, record.state))
        if equalsServer {
            if !record.isOpenInTab { removeLocal(serverPath: path) }
            return .done(.alreadySynced)
        }
        return .again
    }

    // MARK: Закрытие конфликта на сервере

    /// Серверный конфликт после нашего 409 закрывается решением «cancel». Не вышло — идентификатор хранится и повторяется.
    private func cancelServerConflict(path: String, id: String) async {
        if var record = recordsByPath[path], record.pendingConflictID != id {
            record.pendingConflictID = id
            recordsByPath[path] = record
            persistOrBlock()
        }
        do {
            try await perform { try await client.resolveConflict(id: id, decision: "cancel") }
            clearPendingConflict(path, id: id)
        } catch VaultClientError.notFound {
            clearPendingConflict(path, id: id)
        } catch {}
    }

    private func clearPendingConflict(_ path: String, id: String) {
        guard var record = recordsByPath[path], record.pendingConflictID == id else { return }
        record.pendingConflictID = nil
        recordsByPath[path] = record
        persistOrBlock()
    }

    /// Хвост цикла: по одной попытке для записей с незакрытым серверным конфликтом. true — были попытки.
    private func closePendingServerConflicts() async -> Bool {
        guard online else { return false }
        let pending = recordsByPath.values.compactMap { record in record.pendingConflictID.map { (record.serverPath, $0) } }
        for (path, id) in pending where !isShutdown { await cancelServerConflict(path: path, id: id) }
        return !pending.isEmpty
    }

    // MARK: Помощники

    private func readBaseText(_ path: String) -> String? {
        guard let data = (try? store.readBase(serverPath: path)) ?? nil else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func currentFileSHA(_ path: String) -> String? {
        guard let data = (try? store.readNote(serverPath: path)) ?? nil else { return nil }
        return VaultClient.sha256Hex(data)
    }

    /// Паузы и счётчики заметки, которой больше нет в очереди.
    private func forget(_ path: String) {
        uploadState.retryAfter[path] = nil
        uploadState.attempts[path] = nil
        uploadState.rejectedTries[path] = nil
        uploadState.mergeRounds[path] = nil
        uploadState.attempted.remove(path)
        uploadState.forced.removeAll { $0 == path }
    }

    private static func finishLater<Value: Sendable>(_ waiter: VaultWaiter<Value>, after seconds: TimeInterval, with value: Value) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            waiter.finish(value)
        }
    }

    private static func timeLabel() -> String {
        DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    }

    private static func byQueueOrder<S: Sequence>(_ records: S) -> [VaultOpenNoteRecord] where S.Element == VaultOpenNoteRecord {
        records.sorted { lhs, rhs in
            switch (lhs.queuedAt, rhs.queuedAt) {
            case let (a?, b?) where a != b: return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.serverPath < rhs.serverPath
            }
        }
    }
}
