import AppKit
import Combine
import Foundation

/// Плашка над редактором заметки хранилища.
enum VaultBannerKind: Equatable {
    /// Сервер прислал новую версию, пока в окне есть несохранённые правки.
    case newerOnServer
    case deletedOnServer
    /// Правки пересеклись с серверными: нужно решение человека.
    case conflict
    /// Сервер не принимает правки этой заметки.
    case rejected(VaultUploadIssue)
}

/// Заметка хранилища в одной вкладке: открытие, сохранение, закрытие и серверные обновления.
extension AppState {
    // MARK: Файлы хранилища

    /// Корень всех локальных копий: `Application Support/<приложение>/Vaults/`.
    private static var vaultsRootPath: String {
        VaultStateStore.defaultRoot(vaultID: UUID()).deletingLastPathComponent().standardizedFileURL.path + "/"
    }

    /// Файл лежит среди локальных копий хранилища: в «Недавние», избранное и индекс «По словам» он не попадает.
    static func isVaultLocalFile(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(vaultsRootPath)
    }

    func isVaultFile(_ url: URL) -> Bool { Self.isVaultLocalFile(url) }

    /// Документ вкладки, в котором лежит заметка хранилища.
    var vaultDocument: EditorDocument? {
        guard let session = vaultSession, let path = vaultNote?.path else { return nil }
        return documents.first { document in document.url.flatMap { session.serverPath(for: $0) } == path }
    }

    var vaultNoteState: VaultNoteSyncState? {
        guard let path = vaultNote?.path else { return nil }
        return vaultSession?.noteStates[path]
    }

    /// Плашка: версия сервера новее или заметка удалена на сервере; «Оставить мои правки» прячет её до следующего изменения.
    var vaultBanner: VaultBannerKind? {
        if let kind = vaultUploadBanner { return kind }
        guard !vaultBannerDismissed else { return nil }
        switch vaultNoteState {
        case .newerOnServer: return .newerOnServer
        case .deletedOnServer: return .deletedOnServer
        default: return nil
        }
    }

    /// Состояние связи и заметок меняется в сессии: окно (панель инструментов, строка состояния) обновляется вместе с ней.
    func observeVaultSession() {
        vaultSessionObservation = vaultSession?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: Открытие

    /// Привязывает вкладку к заметке и открывает её: сначала файл на Mac (скачивание или уже готовый), затем обычное чтение файла.
    func beginVaultNoteOpening(path: String, completion: ((Bool) -> Void)?) {
        guard let session = vaultSession else {
            completion?(false)
            return
        }
        vaultOpeningTask?.cancel()
        vaultSlowTask?.cancel()
        vaultNote = VaultNoteBinding(vaultID: session.connection.id.uuidString, path: path)
        vaultOpening = .loading
        vaultOpeningIssue = nil
        vaultBannerDismissed = false
        vaultOpeningCompletion = completion
        vaultSlowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VaultOpeningState.slowDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, let state = self.vaultOpening else { return }
            self.vaultOpening = state.afterDelay()
        }
        vaultOpeningTask = Task { @MainActor [weak self] in
            do {
                let url = try await session.fileURL(for: path)
                guard !Task.isCancelled, let self, self.vaultNote?.path == path else { return }
                self.vaultSlowTask?.cancel()
                self.vaultOpening = nil
                self.openFile(url)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.vaultNote?.path == path else { return }
                self.vaultSlowTask?.cancel()
                switch error {
                case VaultClientError.offline, VaultClientError.timeout:
                    // Не ошибка: заметка откроется сама, как только появится связь (или по «Повторить»).
                    self.vaultOpening = .waitingForConnection
                default:
                    self.vaultOpening = nil
                    self.vaultOpeningIssue = Self.vaultOpeningMessage(for: error)
                }
            }
        }
    }

    private static func vaultOpeningMessage(for error: Error) -> String {
        if let error = error as? VaultClientError { return error.userMessage }
        if error as? VaultSyncError == .pathCollision { return L10n.tr("此笔记已在另一个标签中打开") }
        return error.localizedDescription
    }

    /// «Отменить» на оверлее открытия: загрузка прекращается, пустая вкладка закрывается.
    func cancelVaultOpening() {
        vaultOpeningTask?.cancel()
        vaultSlowTask?.cancel()
        vaultOpeningCompletion?(false)
        vaultOpeningCompletion = nil
        releaseVaultNote()
        if documents.count == 1, documents.first?.isDisposableBlank == true,
           (hostWindow?.tabGroup?.windows.count ?? 1) > 1 {
            hostWindow?.performClose(nil)
        }
    }

    func retryVaultOpening() {
        guard let path = vaultNote?.path, vaultSession != nil else { return }
        beginVaultNoteOpening(path: path, completion: vaultOpeningCompletion)
    }

    /// После восстановления вкладки: движок снова считает заметку открытой (запись и файл уже есть, сеть не нужна),
    /// охранник страницы ставится, когда текст документа готов. Файла нет — заметка открывается заново.
    func restoreVaultNoteBinding() {
        guard let session = vaultSession, let path = vaultNote?.path else { return }
        Task { @MainActor in
            do {
                let url = try await session.fileURL(for: path)
                if let document = vaultDocument {
                    if document.ioState == .idle { vaultDocumentLoaded(document, at: url) }
                } else if documents.allSatisfy(\.isDisposableBlank) {
                    // Документ не вернулся (в сессии остался пустой): заметка открывается заново из файла.
                    beginVaultNoteOpening(path: path, completion: nil)
                }
            } catch {
                vaultNote = nil
                beginVaultNoteOpening(path: path, completion: nil)
            }
        }
    }

    /// Связь вернулась: вкладки, ждавшие её, открываются сами.
    func retryVaultOpeningIfWaiting() {
        if vaultOpening == .waitingForConnection { retryVaultOpening() }
    }

    /// Вызывается, когда документ вкладки получил текст: охранник страницы (этап 5а) и `completion` открытия.
    func vaultDocumentLoaded(_ document: EditorDocument, at url: URL) {
        guard let note = vaultNote, let session = vaultSession, session.serverPath(for: url) == note.path else { return }
        attachVaultPageGuard(to: document, serverPath: note.path)
        let completion = vaultOpeningCompletion
        vaultOpeningCompletion = nil
        completion?(true)
    }

    // MARK: Закрытие и сохранение

    /// Идемпотентно: вкладка перестаёт быть заметкой хранилища; движок решает, удалять ли файл на Mac.
    func releaseVaultNote() {
        vaultOpeningTask?.cancel()
        vaultSlowTask?.cancel()
        vaultOpening = nil
        vaultOpeningIssue = nil
        vaultBannerDismissed = false
        vaultOpeningCompletion = nil
        vaultServerUpdates.clear()
        guard let note = vaultNote else { return }
        vaultNote = nil
        for document in documents { detachVaultPageGuard(from: document) }
        vaultSession?.noteClosed(path: note.path)
        noteVaultNoteClosed(path: note.path)
    }

    /// Правая панель хранит предыдущие тексты серверных обновлений: при закрытии заметки их убираем.
    func noteVaultNoteClosed(path: String) {
        vaultServerUpdates.remove(path: path)
        finishVaultDiscardAfterClose(path: path)
    }

    /// Файл заметки записан на Mac: если он отличается от базы сервера, запись становится «Не отправлено».
    func noteSavedForVault(_ url: URL) {
        vaultSavedFileChanged(url)
    }

    /// «Проверить сейчас» (⌘R): сверка открытых заметок и обновление списка имён.
    func checkVaultNow() {
        guard let session = vaultSession else { return }
        showVaultStatus(L10n.tr("正在检查…"))
        Task { @MainActor in
            await session.checkAndReload()
            showVaultStatus(session.isOnline ? L10n.tr("已是最新") : L10n.tr("未连接"))
        }
    }

    /// Повреждённое локальное состояние хранилища: подтверждение продолжения (кнопка в панели, меню строки состояния, вход).
    func confirmVaultStateAttention() {
        guard let session = vaultSession, session.needsStateAttention else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("笔记库的本地状态已损坏")
        alert.informativeText = L10n.tr("本地状态已损坏，未上传的修改可能需要检查；已保存的副本请在笔记的快照中查看。是否继续工作？")
        alert.addButton(withTitle: L10n.tr("继续"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await session.acknowledgeQuarantine() }
        }
        if let window = hostWindow { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    // MARK: Серверные обновления

    func handleVaultChange(_ change: VaultNoteChange) async {
        guard let session = vaultSession, let path = vaultNote?.path else { return }
        vaultBannerDismissed = false
        switch change {
        case .updated(_, let data, _):
            guard let document = vaultDocument, document.ioState == .idle else {
                // Документ ещё грузится или занят: текст не трогаем, вкладка узнает о новой версии из плашки.
                await session.engine.markNewerOnServer(serverPath: path)
                await session.refreshStates()
                return
            }
            _ = document.synchronizedText()
            let state = await session.engine.records()[path]?.state
            if !document.isDirty, !document.hasPendingLiveEdits, state == .synced || state == .newerOnServer {
                await applyVaultServerText(data, path: path, to: document)
            } else {
                // Несохранённые правки: тихо ничего не меняем, показываем плашку. Объединение — этап 5.
                await session.engine.markNewerOnServer(serverPath: path)
                await session.refreshStates()
            }
        case .deleted:
            await session.refreshStates()
        }
    }

    /// Применяет текст сервера отменяемой заменой минимального диапазона (одно ⌘Z), без перезагрузки файла.
    /// Запасной путь — `reloadFromDisk` (вкладка не на экране, текст нельзя править). Общая функция: её же использует этап 5.
    /// `replacesLocalEdits` — пользователь сам просит версию сервера: несохранённый текст сначала уходит в снимок.
    /// Без него несохранённые правки (до или во время записи) запись не затирает: вкладка получает плашку «новее на сервере».
    @discardableResult
    func applyVaultServerText(_ data: Data, path: String, to document: EditorDocument, replacesLocalEdits: Bool = false) async -> Bool {
        guard let session = vaultSession, let text = String(data: data, encoding: .utf8), document.ioState == .idle else { return false }
        let previous = document.synchronizedText()
        func hasLocalEdits() -> Bool { document.isDirty || document.hasPendingLiveEdits }
        if hasLocalEdits() {
            guard replacesLocalEdits else {
                await session.engine.markNewerOnServer(serverPath: path)
                await session.refreshStates()
                return false
            }
            preserveVaultLocalText(previous, of: document)
        }
        guard let url = try? await session.engine.applyServerVersion(serverPath: path) else { return false }
        // Движок пишет файл только у заметки без неотправленных правок: иначе версия сервера не применена, редактор не трогаем.
        guard await session.engine.records()[path]?.state == .synced else {
            await session.refreshStates()
            return false
        }
        // Файл уже записан: снимок версии обновляется сразу, чтобы не появилась плашка «изменён на диске».
        if let snapshot = try? FileRevisionSnapshot.capture(url) { document.updateFileRevisionSnapshot(snapshot) }
        // За время записи текст могли изменить: тогда он остаётся как есть, а сервер считается «новее».
        guard document.ioState == .idle, document.synchronizedText() == previous, replacesLocalEdits || !hasLocalEdits() else {
            await session.engine.markNewerOnServer(serverPath: path)
            await session.refreshStates()
            return false
        }
        noteVaultServerUpdate(path: path, previousText: previous)
        if vaultPageGuardIsReadOnly(document) {
            reloadFromDisk(document, at: url)
            await session.refreshStates()
            return true
        }
        if selectedDocument === document, let change = VaultTextDiff.enclosingChange(from: previous, to: text),
           replaceForVault(document, change: change, previous: previous) {
            _ = document.synchronizedText()
            if let snapshot = try? FileRevisionSnapshot.capture(url) { document.updateFileRevisionSnapshot(snapshot) }
            document.markSaved(snapshot: text, revision: document.textRevision)
            announceVaultUpdate(document)
            await session.refreshStates()
            return true
        }
        reloadFromDisk(document, at: url)
        await session.refreshStates()
        return true
    }

    /// Несохранённый текст перед заменой версией сервера: снимок в истории версий документа (не удаляется при закрытии заметки).
    private func preserveVaultLocalText(_ text: String, of document: EditorDocument) {
        guard let url = document.url else { return }
        _ = try? DocumentSnapshotStore.shared.add(text: text, name: VaultSyncEngine.preservedSnapshotName, encodingName: "UTF-8",
                                              location: .file(path: url.standardizedFileURL.path), keepLast: 50)
    }

    func vaultPageGuardIsReadOnly(_ document: EditorDocument) -> Bool {
        document.vaultPageGuard?.isReadOnly == true
    }

    func replaceForVault(_ document: EditorDocument, change: (range: NSRange, replacement: String), previous: String,
                         actionName: String = L10n.tr("服务器更新")) -> Bool {
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false,
                                                     allowsInsertionPoint: true, requiresEditable: true, includesEditorText: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        // Нет результата — вкладка неактивна или идёт ввод; текст редактора с токенами вместо картинок тоже не подходит.
        guard let current = extraction.result, extraction.editorText == previous else { return false }
        let original = (previous as NSString).substring(with: change.range)
        let request = EditorRangeReplacementRequest(
            documentID: document.id, range: change.range, originalText: original, replacementText: change.replacement,
            expectedEditorRevision: current.editorRevision, actionName: actionName)
        request.groupsUndo = true
        request.isVaultServerUpdate = document.vaultPageGuard != nil
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        return request.wasHandled
    }

    /// Страница с рабочей зоной обновляется сервером целиком: «добавлена запись» тут не подходит.
    private func announceVaultUpdate(_ document: EditorDocument) {
        let message: String
        if document.vaultPageGuard != nil {
            message = L10n.tr("页面已由服务器更新")
        } else {
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            message = L10n.tr("已添加条目 %@", time)
        }
        showVaultNotice(message, on: document)
        AccessibilityNotification.Announcement(message).post()
    }

    /// Запоминает текст до обновления сервером для «Показать изменения сервера» в правой панели.
    func noteVaultServerUpdate(path: String, previousText: String) {
        vaultServerUpdates.record(path: path, previousText: previousText)
        objectWillChange.send()
    }

    /// Краткое сообщение строки состояния: исчезает само; ошибка без открытого документа показывается листом окна.
    func showVaultNotice(_ text: String, isError: Bool = false) {
        guard let document = selectedDocument else {
            guard isError else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = text
            alert.addButton(withTitle: L10n.tr("确定"))
            if let window = hostWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        showVaultNotice(text, isError: isError, on: document)
    }

    private func showVaultNotice(_ text: String, isError: Bool = false, on document: EditorDocument) {
        if isError { document.setStatusError(text) } else { document.statusMessage = text }
        Task { @MainActor [weak document] in
            try? await Task.sleep(nanoseconds: (isError ? 8 : 4) * 1_000_000_000)
            if document?.statusMessage == text { document?.statusMessage = nil }
        }
    }

    /// «Загрузить версию сервера»: версия, которую сервер прислал раньше. Несохранённый текст сначала уходит в снимок;
    /// правки, уже записанные на диск и не отправленные на сервер, этап 5 сохраняет копией.
    func loadVaultServerVersion() {
        guard let session = vaultSession, let path = vaultNote?.path, let document = vaultDocument else { return }
        Task { @MainActor in
            guard let held = await session.engine.heldServerVersions[path] else { return }
            await applyVaultServerText(held.data, path: path, to: document, replacesLocalEdits: true)
        }
    }

    /// «Оставить мои правки»: плашка прячется; при следующем сохранении заметка станет «Не отправлено».
    func keepLocalVaultVersion() {
        vaultBannerDismissed = true
    }

    // MARK: Заголовок

    /// «Хранилище › projects › status»: имя подключения и папки пути; nil — вкладка не из хранилища.
    var vaultTitlePrefix: String? {
        guard let session = vaultSession, let path = vaultNote?.path else { return nil }
        return VaultPresentation.titlePrefix(connectionName: session.connection.name, path: path)
    }

    /// Подпись значка вкладки для VoiceOver: «Заметка хранилища, status, нет связи».
    var vaultTabAccessibilityLabel: String? {
        guard let session = vaultSession, let path = vaultNote?.path else { return nil }
        return L10n.tr("笔记库笔记，%@，%@", VaultPresentation.displayName(ofPath: path), session.status.spokenName)
    }
}
