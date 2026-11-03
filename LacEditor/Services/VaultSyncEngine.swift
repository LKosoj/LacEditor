import Foundation

/// Что изменилось на сервере в открытой заметке (файл на диске при этом не трогается).
enum VaultNoteChange: Equatable {
    case updated(serverPath: String, data: Data, etag: String)
    case deleted(serverPath: String)
}

enum VaultSyncEvent: Equatable {
    case noteState(serverPath: String, VaultNoteSyncState)
    case connection(isOnline: Bool)
    case lastSync(Date)
    /// Скачивание заметки не удалось или отменено: состояние `.loading` снято, записи нет.
    case noteLoadFailed(serverPath: String)
    /// Перед заменой версией сервера локальный текст без записи сохранён в снимок (имя `VaultSyncEngine.preservedSnapshotName`).
    case localTextPreserved(serverPath: String)
    /// Состояние не записалось: новые заметки не открываются, уборка и удаление отключены.
    case stateBlocked
    /// Правки сервера объединены с локальными (файл и редактор уже обновлены).
    case merged(serverPath: String)
    /// Сервер не принял правки (nil — отказ снят).
    case uploadIssue(serverPath: String, VaultUploadIssue?)
    /// Очередь отправки разобрана: сколько заметок ушло за серию.
    case uploadsFinished(sent: Int)
    /// 401 при отправке: очередь стоит (true) или пауза снята (false).
    case authPaused(Bool)
}

enum VaultSyncError: Error, Equatable {
    case invalidPath
    /// Путь отличается от уже открытого только регистром или видом Unicode: на APFS это один файл.
    case pathCollision
    /// `state.json` повреждён или новее известной версии: новые заметки не открываются.
    case stateUnavailable
    case notOpen
}

struct VaultSyncConfiguration: Sendable {
    /// Сколько сетевых ошибок подряд означают «нет связи».
    var failureThreshold = 2
    /// Паузы между проверками `/healthz` без связи, секунды; последняя повторяется.
    var probeDelays: [TimeInterval] = [5, 10, 20, 40, 60]
    /// Пауза после сохранения перед отправкой: склеивает серию автосохранений.
    var uploadDebounce: TimeInterval = 1.5
    /// Паузы между повторами отправки при сетевых сбоях и 5xx; последняя повторяется.
    var uploadRetryDelays: [TimeInterval] = [5, 10, 20, 40, 60]
    /// Сколько закрытие вкладки ждёт отправку.
    var closeFlushTimeout: TimeInterval = 2.5
    var snapshotKeepLast = 50
    /// Объединений подряд, после которых идёт пауза: сервер меняется между нашими запросами.
    var maxMergeRounds = 5
    var mergePause: TimeInterval = 30
    /// Пауза, когда хозяин вкладки занят (идёт ввод): повтор объединения.
    var hostBusyDelay: TimeInterval = 3
    static let standard = VaultSyncConfiguration()
}

/// Открытые заметки хранилища: скачивание в `open/`, сверка с сервером, учёт связи, удаление при закрытии.
/// Отправку правок добавляет `VaultSyncEngine+Upload.swift`.
actor VaultSyncEngine {
    nonisolated let events: AsyncStream<VaultSyncEvent>
    nonisolated var openDirectory: URL { store.openDirectory }

    // Доступно расширениям в других файлах (отправка правок).
    let client: VaultClient
    let store: VaultStateStore
    var recordsByPath: [String: VaultOpenNoteRecord] = [:]
    /// Версия сервера, о которой уже сообщили: пока вкладка решает, применять ли её.
    var heldServerVersions: [String: (data: Data, etag: String, modifiedNs: Int64?)] = [:]

    private let connection: VaultConnection
    let configuration: VaultSyncConfiguration
    let snapshotStore: DocumentSnapshotStore
    private let continuation: AsyncStream<VaultSyncEvent>.Continuation

    private var isLoaded = false
    var isStateUnavailable = false
    /// Есть следы повреждённого `state.json` или файлы без записей: уборка после сбоя ничего не удаляет.
    private var isCleanupBlocked = false
    var isShutdown = false
    private var epoch = 0
    private var generations: [String: UInt] = [:]
    private var inflightOpens: [String: (generation: UInt, task: Task<URL, Error>)] = [:]
    var needsRecheck: Set<String> = []
    private var isChecking = false
    var online = true
    private var consecutiveFailures = 0
    private var probeTask: Task<Void, Never>?
    private var probeToken = 0
    /// Состояние очереди отправки (`VaultSyncEngine+Upload.swift`).
    let uploadState = VaultUploadState()

    init(connection: VaultConnection, client: VaultClient, store: VaultStateStore,
         configuration: VaultSyncConfiguration = .standard, snapshotStore: DocumentSnapshotStore = .shared) {
        self.connection = connection
        self.client = client
        self.store = store
        self.configuration = configuration
        self.snapshotStore = snapshotStore
        let stream = AsyncStream<VaultSyncEvent>.makeStream(of: VaultSyncEvent.self, bufferingPolicy: .bufferingNewest(64))
        events = stream.stream
        continuation = stream.continuation
    }

    /// Путь на сервере по локальному пути внутри `open/`; записи не нужны.
    nonisolated func serverPath(forLocalPath path: String) -> String? {
        store.serverPath(forLocalURL: URL(fileURLWithPath: path))
    }

    // MARK: Запросы состояния

    func localURL(for serverPath: String) -> URL? {
        loadStateIfNeeded()
        return recordsByPath[serverPath] == nil ? nil : store.noteURL(for: serverPath)
    }

    func serverPath(for localURL: URL) -> String? {
        loadStateIfNeeded()
        guard let path = store.serverPath(forLocalURL: localURL), recordsByPath[path] != nil else { return nil }
        return path
    }

    func records() -> [String: VaultOpenNoteRecord] {
        loadStateIfNeeded()
        return recordsByPath
    }

    func isOnline() -> Bool { online }

    /// Состояние не записывается или недоступно: новые заметки не открываются, уборка отключена.
    func isStateBlocked() -> Bool { isStateUnavailable }

    func generation(of serverPath: String) -> UInt { generations[serverPath] ?? 0 }

    // MARK: Открытие

    /// Локальный путь заметки. Есть запись и файл — без запроса (неотправленное, восстановленная вкладка);
    /// иначе скачивание с проверкой длины и SHA-256. Закрытие вкладки во время скачивания отменяет результат.
    func open(serverPath: String) async throws -> URL {
        guard !isShutdown else { throw CancellationError() }
        guard VaultPath.validated(serverPath) != nil, store.noteURL(for: serverPath) != nil else { throw VaultSyncError.invalidPath }
        loadStateIfNeeded()
        if isStateUnavailable { throw VaultSyncError.stateUnavailable }
        let key = Self.canonicalKey(serverPath)
        if recordsByPath.keys.contains(where: { !$0.utf8.elementsEqual(serverPath.utf8) && Self.canonicalKey($0) == key })
            || inflightOpens.keys.contains(where: { !$0.utf8.elementsEqual(serverPath.utf8) && Self.canonicalKey($0) == key }) {
            throw VaultSyncError.pathCollision
        }
        if var record = recordsByPath[serverPath] {
            if let url = store.noteURL(for: serverPath), isRegularFile(url) {
                if !record.isOpenInTab {
                    record.isOpenInTab = true
                    recordsByPath[serverPath] = record
                    try persist()
                }
                needsRecheck.insert(serverPath)
                return url
            }
            recordsByPath[serverPath] = nil
            heldServerVersions[serverPath] = nil
            try persist()
        }
        if let running = inflightOpens[serverPath] { return try await running.task.value }
        let generation = (generations[serverPath] ?? 0) + 1
        generations[serverPath] = generation
        let startEpoch = epoch
        emit(.noteState(serverPath: serverPath, .loading))
        let task = Task { () -> URL in
            defer { self.finishDownload(serverPath, generation: generation) }
            do {
                return try await self.download(serverPath, generation: generation, epoch: startEpoch)
            } catch {
                self.reportLoadFailure(serverPath, generation: generation)
                throw error
            }
        }
        inflightOpens[serverPath] = (generation, task)
        return try await task.value
    }

    /// Снимает `.loading`, если за это время не началось новое скачивание того же пути.
    private func reportLoadFailure(_ serverPath: String, generation: UInt) {
        if let running = inflightOpens[serverPath], running.generation != generation { return }
        emit(.noteLoadFailed(serverPath: serverPath))
    }

    private func finishDownload(_ serverPath: String, generation: UInt) {
        if inflightOpens[serverPath]?.generation == generation { inflightOpens[serverPath] = nil }
    }

    private func download(_ serverPath: String, generation: UInt, epoch startEpoch: Int) async throws -> URL {
        let file = try await perform { try await client.file(path: serverPath) }
        // Вкладку закрыли или режим остановили, пока шёл ответ: ничего не пишем.
        guard generations[serverPath] == generation, epoch == startEpoch, !isShutdown else { throw CancellationError() }
        // Сначала сохраняем чужой текст: при сбое файл остаётся на месте, откат ниже его не касается.
        if try preserveUnrecordedLocalFile(serverPath, replacingWith: file.data) {
            emit(.localTextPreserved(serverPath: serverPath))
        }
        do {
            let url = try store.writeNote(file.data, serverPath: serverPath)
            try store.writeBase(file.data, serverPath: serverPath)
            recordsByPath[serverPath] = VaultOpenNoteRecord(
                serverPath: serverPath, baseETag: file.etag, baseModifiedNs: file.modifiedNs, baseSize: file.data.count,
                state: .synced, isOpenInTab: true)
            try persist()
            emit(.noteState(serverPath: serverPath, .synced))
            emit(.lastSync(Date()))
            return url
        } catch {
            recordsByPath[serverPath] = nil
            try? store.removeNote(serverPath: serverPath)
            throw error
        }
    }

    /// Файл есть, а записи нет (например, после повреждённого `state.json`): перед заменой версией сервера
    /// его текст уходит в снимок; не получилось сохранить — файл не трогаем.
    /// true — снимок создан.
    private func preserveUnrecordedLocalFile(_ serverPath: String, replacingWith data: Data) throws -> Bool {
        guard let url = store.noteURL(for: serverPath), isRegularFile(url) else { return false }
        let local = try Data(contentsOf: url)
        guard local != data else { return false }
        guard let text = String(data: local, encoding: .utf8) else { throw VaultSyncError.stateUnavailable }
        try snapshotStore.add(text: text, name: Self.preservedSnapshotName, encodingName: "UTF-8",
                              location: .file(path: url.standardizedFileURL.path), keepLast: 50)
        return true
    }

    /// Имя снимка, сделанного перед заменой файла без записи: при закрытии заметки он не удаляется.
    static let preservedSnapshotName = "vault-preserved-local-text"

    // MARK: Сверка с сервером

    /// Сверяет открытые во вкладках заметки: один запрос списка на папку; файл скачивается только если
    /// список его не подтвердил. Удалённой заметку делает только ответ 404 на сам файл.
    func checkOpenNotes() async -> [VaultNoteChange] {
        guard !isShutdown, !isChecking else { return [] }
        loadStateIfNeeded()
        guard !isStateUnavailable, online else { return [] }
        let candidates = recordsByPath.values.filter { $0.isOpenInTab && $0.state != .deletedOnServer }
        guard !candidates.isEmpty else { return [] }
        isChecking = true
        defer { isChecking = false }
        let startEpoch = epoch
        func isStale() -> Bool { isShutdown || epoch != startEpoch }
        let startedGenerations = Dictionary(uniqueKeysWithValues: candidates.map { ($0.serverPath, generation(of: $0.serverPath)) })
        var folders: [String: [String]] = [:]
        for record in candidates { folders[Self.parentFolder(of: record.serverPath), default: []].append(record.serverPath) }
        var changes: [VaultNoteChange] = []
        var sawNetworkError = false

        folderLoop: for folder in folders.keys.sorted() {
            var listing: [String: VaultTreeEntry] = [:]
            do {
                for entry in try await listFolder(folder) { listing[entry.path] = entry }
                if isStale() { return changes }
            } catch let error as VaultClientError {
                switch error {
                case .offline, .timeout: sawNetworkError = true; break folderLoop
                case .notFound: break   // папки нет: каждый файл проверяется отдельно
                default: continue folderLoop
                }
            } catch {
                break folderLoop
            }
            for path in (folders[folder] ?? []).sorted() {
                if isStale() { return changes }
                guard let record = recordsByPath[path], generation(of: path) == startedGenerations[path] else { continue }
                if isConfirmedByListing(record, entry: listing[path]) { continue }
                do {
                    let file = try await perform { try await client.file(path: path) }
                    if isStale() { return changes }
                    guard let current = recordsByPath[path], generation(of: path) == startedGenerations[path] else { continue }
                    needsRecheck.remove(path)
                    if file.etag == current.baseETag {
                        updateBaseMetadata(path, from: file)
                    } else if heldServerVersions[path]?.etag != file.etag {
                        heldServerVersions[path] = (file.data, file.etag, file.modifiedNs)
                        changes.append(.updated(serverPath: path, data: file.data, etag: file.etag))
                    }
                } catch VaultClientError.notFound {
                    if isStale() { return changes }
                    guard recordsByPath[path] != nil, generation(of: path) == startedGenerations[path] else { continue }
                    needsRecheck.remove(path)
                    heldServerVersions[path] = nil
                    setState(.deletedOnServer, for: path)
                    changes.append(.deleted(serverPath: path))
                } catch VaultClientError.offline, VaultClientError.timeout {
                    sawNetworkError = true
                    break folderLoop
                } catch is CancellationError {
                    break folderLoop
                } catch {
                    continue   // повтор на следующем проходе
                }
            }
        }
        if !sawNetworkError, !isStale() { emit(.lastSync(Date())) }
        return changes
    }

    /// Все записи папки (depth 0) по страницам, в рамках учёта связи.
    private func listFolder(_ folder: String) async throws -> [VaultTreeEntry] {
        try await perform {
            var entries: [VaultTreeEntry] = []
            var token: String?
            var seenTokens = Set<String>()
            repeat {
                let page = try await client.tree(path: folder, depth: 0, pageSize: 1000, pageToken: token)
                entries += page.entries
                // Токен уже встречался (в том числе A→B→A) или страниц слишком много — сервер зациклил обход.
                if let next = page.nextPageToken {
                    guard seenTokens.insert(next).inserted, seenTokens.count <= 10_000 else { throw VaultClientError.invalidResponse }
                }
                token = page.nextPageToken
            } while token != nil
            return entries
        }
    }

    /// Список подтверждает базу (или уже сообщённую версию), если совпало всё, что есть у обеих сторон, и хоть что-то.
    private func isConfirmedByListing(_ record: VaultOpenNoteRecord, entry: VaultTreeEntry?) -> Bool {
        guard let entry, !needsRecheck.contains(record.serverPath) else { return false }
        func matches(_ modifiedNs: Int64?, _ size: Int?) -> Bool {
            var compared = false
            if let listed = entry.mtimeNs, let known = modifiedNs {
                guard listed == known else { return false }
                compared = true
            }
            if let listed = entry.size, let known = size {
                guard listed == known else { return false }
                compared = true
            }
            return compared
        }
        if matches(record.baseModifiedNs, record.baseSize) { return true }
        if let held = heldServerVersions[record.serverPath] { return matches(held.modifiedNs, held.data.count) }
        return false
    }

    private func updateBaseMetadata(_ path: String, from file: VaultFile) {
        guard var record = recordsByPath[path] else { return }
        guard record.baseModifiedNs != file.modifiedNs || record.baseSize != file.data.count else { return }
        record.baseModifiedNs = file.modifiedNs
        record.baseSize = file.data.count
        recordsByPath[path] = record
        persistOrBlock()
    }

    // MARK: Версия сервера

    /// Записывает присланную версию (файл, база, запись). При несохранённых правках ничего не пишет:
    /// слияние — отправка правок.
    func applyServerVersion(serverPath: String) async throws -> URL {
        loadStateIfNeeded()
        guard !isShutdown else { throw CancellationError() }
        guard var record = recordsByPath[serverPath], let url = store.noteURL(for: serverPath) else { throw VaultSyncError.notOpen }
        if isStateUnavailable { throw VaultSyncError.stateUnavailable }
        guard let held = heldServerVersions[serverPath] else { throw VaultSyncError.notOpen }
        if [.modified, .uploading, .conflict].contains(record.state) { return url }
        _ = try store.writeNote(held.data, serverPath: serverPath)
        try store.writeBase(held.data, serverPath: serverPath)
        record.baseETag = held.etag
        record.baseModifiedNs = held.modifiedNs
        record.baseSize = held.data.count
        record.state = .synced
        record.queuedSHA256 = nil
        record.queuedAt = nil
        recordsByPath[serverPath] = record
        try persist()
        heldServerVersions[serverPath] = nil
        emit(.noteState(serverPath: serverPath, .synced))
        return url
    }

    func markNewerOnServer(serverPath: String) async {
        loadStateIfNeeded()
        guard recordsByPath[serverPath]?.state == .synced else { return }
        setState(.newerOnServer, for: serverPath)
    }

    // MARK: Закрытие и уборка

    /// true — заметка удалена с диска совсем. Несохранённое на сервер остаётся («Неотправленное»).
    @discardableResult
    func noteClosed(serverPath: String) async -> Bool {
        loadStateIfNeeded()
        generations[serverPath] = (generations[serverPath] ?? 0) + 1
        // Скачивание не отменяем: результат отбросит проверка поколения (отмена сетевого запроса на Linux зависает).
        inflightOpens[serverPath] = nil
        needsRecheck.remove(serverPath)
        heldServerVersions[serverPath] = nil
        // Без надёжного состояния ничего не удаляем: там могут быть неотправленные правки.
        guard !isStateUnavailable, !isShutdown else { return false }
        guard var record = recordsByPath[serverPath] else {
            // Записи нет: файл удаляем, только если это не другой вид записи того же пути на регистронезависимой ФС.
            let key = Self.canonicalKey(serverPath)
            if recordsByPath.keys.contains(where: { Self.canonicalKey($0) == key }) { return false }
            return store.noteURL(for: serverPath) == nil ? true : removeFiles(serverPath)
        }
        // Словарь считает канонически равные строки одним ключом: запись другого вида того же пути не трогаем.
        guard record.serverPath.utf8.elementsEqual(serverPath.utf8) else { return false }
        switch record.state {
        case .modified, .uploading, .conflict:
            return keepUnsent(&record)
        case .synced, .loading, .newerOnServer, .deletedOnServer:
            // Удаляем, только если локальный файл доказуемо равен базе (или его нет): иначе это неотправленные правки.
            switch compareWithBase(serverPath) {
            case .equal, .missing:
                return removeLocal(serverPath: serverPath)
            case .different, .unreadable:
                if record.state == .synced || record.state == .loading { record.state = .modified }
                return keepUnsent(&record)
            }
        }
    }

    private enum LocalComparison { case equal, different, missing, unreadable }

    private func compareWithBase(_ serverPath: String) -> LocalComparison {
        let note: Data?
        do { note = try store.readNote(serverPath: serverPath) } catch { return .unreadable }
        guard let note else { return .missing }
        let base: Data?
        do { base = try store.readBase(serverPath: serverPath) } catch { return .unreadable }
        guard let base else { return .different }
        return note == base ? .equal : .different
    }

    private func keepUnsent(_ record: inout VaultOpenNoteRecord) -> Bool {
        record.isOpenInTab = false
        recordsByPath[record.serverPath] = record
        persistOrBlock()
        return false
    }

    /// Файл, база, запись и снимки насовсем. Ошибка удаления файла — запись остаётся без вкладки, возврат false.
    @discardableResult
    func removeLocal(serverPath: String) -> Bool {
        guard removeFiles(serverPath) else {
            if var record = recordsByPath[serverPath] {
                record.isOpenInTab = false
                recordsByPath[serverPath] = record
                persistOrBlock()
            }
            return false
        }
        recordsByPath[serverPath] = nil
        heldServerVersions[serverPath] = nil
        persistOrBlock()
        return true
    }

    /// Файлы и снимки заметки; true, если файлы удалены.
    func removeFiles(_ serverPath: String) -> Bool {
        do { try store.removeNote(serverPath: serverPath) } catch { return false }
        deleteSnapshots(of: serverPath)
        return true
    }

    private func deleteSnapshots(of serverPath: String) {
        guard let url = store.noteURL(for: serverPath) else { return }
        let location = DocumentSnapshotLocation.file(path: url.standardizedFileURL.path)
        let all = snapshotStore.list(location: location)
        let kept = all.filter { $0.name == Self.preservedSnapshotName }
        if kept.isEmpty { try? snapshotStore.deleteAll(location: location); return }
        for info in all where info.name != Self.preservedSnapshotName { try? snapshotStore.delete(id: info.id, location: location) }
    }

    /// После сбоя: оставляет восстановленные вкладки и всё, что не `synced`; остальное, включая сирот, удаляет.
    /// Повреждённое состояние — ничего не удаляется.
    func cleanupAfterCrash(restoredPaths: Set<String>) async {
        loadStateIfNeeded()
        guard !isStateUnavailable, !isCleanupBlocked, !isShutdown else { return }
        var kept = Set<String>()
        for (path, record) in recordsByPath {
            let hasFile = store.noteURL(for: path).map { isRegularFile($0) } ?? false
            guard hasFile else {
                recordsByPath[path] = nil
                _ = removeFiles(path)
                continue
            }
            let isRestored = restoredPaths.contains(path)
            guard isRestored || ![.synced, .loading].contains(record.state) else {
                // Запись «синхронизировано», но файл отличается от базы (приложение закрылось до сверки): правки остаются в очереди.
                if record.state == .synced, let current = (try? store.readNote(serverPath: path)) ?? nil,
                   let base = (try? store.readBase(serverPath: path)) ?? nil, current != base {
                    var changed = record
                    changed.state = .modified
                    changed.isOpenInTab = false
                    changed.queuedSHA256 = VaultClient.sha256Hex(current)
                    changed.queuedAt = changed.queuedAt ?? Date()
                    recordsByPath[path] = changed
                    kept.insert(path)
                    continue
                }
                if removeFiles(path) { recordsByPath[path] = nil } else { kept.insert(path) }
                continue
            }
            var updated = record
            updated.isOpenInTab = isRestored
            recordsByPath[path] = updated
            if isRestored { needsRecheck.insert(path) }
            kept.insert(path)
        }
        var keeping = kept
        for path in restoredPaths {
            if let url = store.noteURL(for: path), isRegularFile(url) { keeping.insert(path) }
        }
        preserveUnrecordedFiles(keeping: &keeping, afterAcknowledge: false)
        let orphans = (try? store.cleanupOrphans(keeping: keeping)) ?? []
        for path in orphans { deleteSnapshots(of: path) }
        normalizeInterruptedUploads()
        persistOrBlock()
    }

    /// Файлы `open/` без записи могут быть неотправленными правками из повреждённого `state.json`:
    /// перед удалением их текст уходит в снимок; не UTF-8 или сбой снимка — файл остаётся.
    /// `afterAcknowledge` — вызов при решении о карантине: снимок только файлам без базы
    /// (остальные сохранит уборка), сразу, чтобы текст не зависел от уборки в этом же запуске.
    private func preserveUnrecordedFiles(keeping: inout Set<String>, afterAcknowledge: Bool) {
        guard let walker = FileManager.default.enumerator(atPath: store.openDirectory.path) else { return }
        for case let name as String in walker {
            guard let path = VaultPath.validated(name), !keeping.contains(path),
                  let url = store.noteURL(for: path), isRegularFile(url) else { continue }
            // Ссылку не читаем (она может вести наружу): её удалит `cleanupOrphans`.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            // Равен базе — это скачанная копия без правок: просто удаляется. Отличается от базы — правки, снимок всегда.
            let base = try? store.readBase(serverPath: path)
            if let base, afterAcknowledge || base == data { continue }
            // Не UTF-8 снимком не сохранить: файл остаётся.
            guard let text = String(data: data, encoding: .utf8) else { keeping.insert(path); continue }
            // Базы нет: снимок только при решении о карантине, иначе обычные сироты копились бы.
            if base == nil, !afterAcknowledge { continue }
            do {
                try snapshotStore.add(text: text, name: Self.preservedSnapshotName, encodingName: "UTF-8",
                                      location: .file(path: url.standardizedFileURL.path), keepLast: 50)
                emit(.localTextPreserved(serverPath: path))
            } catch {
                keeping.insert(path)
            }
        }
    }

    /// Есть перенесённый повреждённый `state.json` (карантин): пока пользователь не решил, уборка ничего не удаляет.
    nonisolated var hasQuarantinedState: Bool { store.hasQuarantinedState }

    // MARK: Связь

    /// Учёт связи: две сетевые ошибки подряд — «нет связи»; любой ответ сервера считается признаком связи.
    func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            let result = try await operation()
            noteReachable()
            if clearAuthPause() { scheduleLoopWake() }
            return result
        } catch let error as VaultClientError {
            switch error {
            case .offline, .timeout: noteNetworkFailure()
            default: noteReachable()
            }
            throw error
        }
    }

    private func noteReachable() {
        consecutiveFailures = 0
        guard !online, !isShutdown else { return }
        online = true
        resumeUploadsAfterReconnect()
        // Сетевую проверку не отменяем: поздний результат отбрасывает номер `probeToken`.
        probeToken += 1
        probeTask = nil
        emit(.connection(isOnline: true))
    }

    private func noteNetworkFailure() {
        guard !isShutdown else { return }
        consecutiveFailures += 1
        guard online, consecutiveFailures >= max(configuration.failureThreshold, 1) else { return }
        online = false
        emit(.connection(isOnline: false))
        startProbeLoop(immediately: false)
    }

    private func startProbeLoop(immediately: Bool) {
        probeToken += 1
        let token = probeToken
        probeTask = Task { await self.runProbeLoop(token: token, immediately: immediately) }
    }

    private func runProbeLoop(token: Int, immediately: Bool) async {
        var step = 0
        var skipPause = immediately
        let delays = configuration.probeDelays.isEmpty ? [5] : configuration.probeDelays
        while token == probeToken, !online {
            if !skipPause {
                let seconds = max(delays[min(step, delays.count - 1)], 0)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard token == probeToken, !online, !isShutdown else { return }
            }
            skipPause = false
            // Успех (и любой ответ сервера) возвращает связь внутри `perform`.
            do { try await perform { try await client.health(timeout: 5) } } catch is CancellationError { return } catch {}
            step += 1
        }
    }

    /// Сеть или сон могли измениться: без связи — проверка `/healthz` сразу.
    func connectivityMayHaveChanged() {
        guard !isShutdown else { return }
        if online { consecutiveFailures = 0 } else { startProbeLoop(immediately: true) }
    }

    /// Останавливает проверки и скачивания и закрывает `events`.
    func shutdown() {
        isShutdown = true
        cancelUploadTimers()
        epoch += 1
        probeToken += 1
        probeTask = nil
        inflightOpens = [:]
        continuation.finish()
    }

    // MARK: Для расширений и внутреннее

    func persist() throws {
        // После `shutdown()` папка хранилища может быть уже удалена: не воссоздаём её.
        guard !isShutdown else { return }
        try store.save(recordsByPath)
    }

    /// Запись состояния, ошибка которой не должна пропасть: дальше новые заметки не открываются.
    func persistOrBlock() {
        do { try persist() } catch {
            if !isStateUnavailable { isStateUnavailable = true; emit(.stateBlocked) }
        }
    }

    /// Решение пользователя после повреждённого `state.json`: карантинные копии переименовываются
    /// (`state.json.acknowledged…`, не удаляются), уборка и открытие заметок снова разрешены.
    func acknowledgeQuarantine() {
        loadStateIfNeeded()
        guard !isShutdown else { return }
        store.acknowledgeQuarantine()
        isCleanupBlocked = false
        if !store.isReadOnly { isStateUnavailable = false }
        var keeping = Set(recordsByPath.keys)
        preserveUnrecordedFiles(keeping: &keeping, afterAcknowledge: true)
    }

    func setState(_ state: VaultNoteSyncState, for serverPath: String) {
        guard var record = recordsByPath[serverPath] else { return }
        record.state = state
        recordsByPath[serverPath] = record
        persistOrBlock()
        emit(.noteState(serverPath: serverPath, state))
    }

    func loadStateIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        do {
            recordsByPath = try store.load()
            isStateUnavailable = store.isReadOnly
            isCleanupBlocked = store.hasQuarantinedState || (recordsByPath.isEmpty && store.hasOpenFiles)
        } catch {
            isStateUnavailable = true
        }
    }

    func emit(_ event: VaultSyncEvent) {
        guard !isShutdown else { return }
        continuation.yield(event)
    }

    func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    nonisolated private static func canonicalKey(_ path: String) -> String {
        // Сравнение String в Swift учитывает канонический Unicode («й» и «и»+«̆» равны).
        path.lowercased()
    }

    nonisolated private static func parentFolder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
