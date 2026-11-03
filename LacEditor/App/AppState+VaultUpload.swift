import AppKit
import Combine
import Foundation
import SwiftUI

/// Сообщение «Добавлены изменения с сервера» после объединения.
struct VaultMergeNotice: Equatable {
    let id = UUID()
    let path: String
}

/// Состояние интерфейса отправки правок одной вкладки (единственное новое поле в `AppState`).
@MainActor
final class VaultUploadUIState: ObservableObject {
    /// Окно вкладки обновляется вместе с сообщением (плашка живёт в панели заголовка).
    weak var owner: AppState?
    @Published var mergeNotice: VaultMergeNotice? { didSet { owner?.objectWillChange.send() } }
    /// Идёт попытка отправить заметку при закрытии вкладки: в строке состояния «Отправляется…».
    @Published var closeFlushPath: String?
    /// Запрос боковой панели раскрыть раздел: «Неотправленное» или «Конфликты».
    @Published var revealRequest: VaultSidebarReveal?
    /// Лист решения конфликта, пока он открыт.
    var conflictSheet: NSWindow?
    /// Заметки, правки которых надо стереть сразу после закрытия вкладки.
    var discardAfterClose: Set<String> = []
    var mergeNoticeTask: Task<Void, Never>?
    /// На сообщении об объединении курсор или фокус клавиатуры: оно не скрывается само.
    var noticeIsEngaged = false
}

enum VaultSidebarReveal: Equatable {
    case unsent, conflicts
}

/// Отправка правок на уровне вкладки: сохранение, закрытие, «Отправить сейчас», отмена правок, объединение, конфликт.
extension AppState {
    // MARK: Файл сохранён

    /// Файл заметки записан на Mac: заметка встаёт в очередь отправки (или метка снимается, если текст равен базе).
    func vaultSavedFileChanged(_ url: URL) {
        guard let session = vaultSession, session.contains(url) else { return }
        Task { await session.noteSaved(url: url) }
    }

    // MARK: Закрытие вкладки

    /// Шаг цепочки закрытия вкладки (после вопроса «Сохранить изменения?»): правки уходят на сервер, пока вкладка ещё видна.
    /// Не вышло за `closeFlushTimeout` — вопрос с тремя кнопками.
    func vaultConfirmClosing(_ document: EditorDocument, completion: @escaping (Bool) -> Void) {
        guard let session = vaultSession, let path = vaultNote?.path, vaultDocument === document,
              windowManager?.vaultQuitApproved != true else {
            completion(true)
            return
        }
        // За время ожидания можно набрать текст: тогда вкладка не закрывается.
        // Отказ только если текст изменился за ожидание: после «不保存» документ остаётся «грязным», но закрываться должен.
        let startRevision = document.textRevision
        let startedPending = document.hasPendingLiveEdits
        let finish: (Bool) -> Void = { close in
            let typed = document.textRevision != startRevision || (document.hasPendingLiveEdits && !startedPending)
            completion(close && typed ? false : close)
        }
        Task { @MainActor [weak self] in
            await session.engine.enqueueUpload(serverPath: path)
            let record = await session.engine.records()[path]
            guard let record, record.state != .synced else {
                finish(true)
                return
            }
            var outcome: VaultUploadOutcome
            if await session.engine.isOnline(), record.state == .modified || record.state == .uploading, record.uploadIssue == nil {
                self?.vaultUpload.closeFlushPath = path
                self?.announceVault(L10n.tr("正在发送…"))
                outcome = await session.engine.uploadNow(serverPath: path, timeout: session.engine.configuration.closeFlushTimeout)
                self?.vaultUpload.closeFlushPath = nil
            } else if record.state == .conflict {
                outcome = .conflict
            } else if record.state == .deletedOnServer {
                outcome = .deletedOnServer
            } else if let issue = record.uploadIssue {
                outcome = .issue(issue)
            } else {
                outcome = .offline
            }
            await session.refreshStates()
            switch outcome {
            case .sent, .alreadySynced, .notQueued:
                finish(true)
            default:
                guard let self else { completion(true); return }
                self.askVaultClose(path: path, outcome: outcome, completion: finish)
            }
        }
    }

    private func askVaultClose(path: String, outcome: VaultUploadOutcome, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("修改尚未上传到服务器")
        switch outcome {
        case .conflict:
            alert.informativeText = L10n.tr("这篇笔记与服务器上的修改冲突。你的修改会保存在此 Mac 上，可稍后在“冲突的笔记”中解决。")
        case .issue(let issue):
            alert.informativeText = L10n.tr("服务器没有接受这些修改（%@）。修改会保存在此 Mac 上。", issue.userMessage)
        case .deletedOnServer:
            alert.informativeText = L10n.tr("这篇笔记已在服务器上删除。你的文本会保存在此 Mac 的“未上传”中。")
        default:
            alert.informativeText = L10n.tr("它们会保存在此 Mac 上，并在连接恢复后发送。")
        }
        alert.addButton(withTitle: L10n.tr("关闭"))
        alert.addButton(withTitle: L10n.tr("撤销修改…"))
        alert.addButton(withTitle: L10n.tr("取消"))
        presentVaultAlert(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                completion(true)
            case .alertSecondButtonReturn:
                self?.confirmVaultDiscard(path: path) { confirmed in
                    guard confirmed else { self?.askVaultClose(path: path, outcome: outcome, completion: completion); return }
                    self?.vaultUpload.discardAfterClose.insert(path)
                    completion(true)
                }
            default:
                completion(false)
            }
        }
    }

    /// Второй вопрос: необратимое удаление правок.
    private func confirmVaultDiscard(path: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.tr("撤销对“%@”的修改？", VaultPresentation.displayName(ofPath: path))
        alert.informativeText = L10n.tr("这些修改尚未上传到服务器。撤销后会从此 Mac 永久删除，无法恢复。")
        alert.addButton(withTitle: L10n.tr("保留修改"))
        alert.addButton(withTitle: L10n.tr("撤销修改")).hasDestructiveAction = true
        presentVaultAlert(alert) { completion($0 == .alertSecondButtonReturn) }
    }

    func presentVaultAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = hostWindow, window.isVisible {
            alert.beginSheetModal(for: window) { response in DispatchQueue.main.async { completion(response) } }
        } else {
            completion(alert.runModal())
        }
    }

    /// Вкладка закрыта: если человек выбрал «Отменить правки», файлы заметки стираются насовсем.
    func finishVaultDiscardAfterClose(path: String) {
        guard vaultUpload.discardAfterClose.remove(path) != nil, let session = vaultSession ?? windowManager?.activeVaultSession else { return }
        Task { @MainActor in
            await session.waitForClosings()
            _ = await session.engine.discardLocalChanges(serverPath: path, tabIsClosing: true)
            await session.refreshStates()
        }
    }

    // MARK: Отправить сейчас, отменить правки

    /// «Отправить сейчас» из боковой панели, плашки и меню: без паузы, итог словами в строке состояния.
    func sendVaultNow(_ serverPath: String) {
        guard let session = vaultSession ?? windowManager?.activeVaultSession else { return }
        Task { @MainActor in
            let outcome = await session.engine.uploadNow(serverPath: serverPath)
            await session.refreshStates()
            switch outcome {
            case .sent: announceVault(L10n.tr("修改已发送"))
            case .conflict: showVaultNotice(L10n.tr("冲突"))
            case .offline: showVaultNotice(L10n.tr("等待连接"))
            case .retryLater: showVaultNotice(L10n.tr("服务器暂时无法处理，稍后自动重试"))
            case .issue(let issue): showVaultNotice(issue.userMessage, isError: true)
            default: break
            }
        }
    }

    /// «Отменить мои правки…» из боковой панели. Закрытая заметка стирается насовсем (после вопроса),
    /// открытая возвращается к версии сервера одной отменяемой заменой.
    func discardVaultChanges(serverPath: String) {
        guard let session = vaultSession ?? windowManager?.activeVaultSession else { return }
        confirmVaultDiscard(path: serverPath) { [weak self] confirmed in
            guard confirmed, let self else { return }
            Task { @MainActor in
                switch await session.engine.discardLocalChanges(serverPath: serverPath) {
                case .removed:
                    self.announceVault(L10n.tr("修改已撤销"))
                case .revertTo(let base):
                    guard let state = self.windowManager?.state(forVaultPath: serverPath, in: session) else { return }
                    let result = await state.revertVaultNote(to: base, path: serverPath)
                    if result == .busy { self.showVaultNotice(L10n.tr("笔记正忙，请再试一次"), isError: true) }
                    else { self.announceVault(L10n.tr("修改已撤销")) }
                case .busy:
                    self.showVaultNotice(L10n.tr("笔记正忙，请再试一次"), isError: true)
                case .notFound:
                    break
                }
                await session.refreshStates()
            }
        }
    }

    /// Открытая заметка возвращается к основе: снимок перед отменой, затем та же замена, что при объединении.
    func revertVaultNote(to base: String, path: String) async -> VaultApplyResult {
        guard let session = vaultSession, let document = vaultDocument else { return .busy }
        let current = document.synchronizedText()
        if !document.isDirty, !document.hasPendingLiveEdits, let url = document.url {
            _ = try? DocumentSnapshotStore.shared.add(text: current, name: L10n.tr("撤销前：你的版本"), encodingName: "UTF-8",
                                                  location: .file(path: url.standardizedFileURL.path), keepLast: 50)
        }
        var result = await replaceVaultNoteText(base, path: path, expectedFileText: current, recordsUpdate: false,
                                                actionName: L10n.tr("撤销我的修改"))
        if result == .engineMayWrite, let url = session.engine.store.noteURL(for: path) {
            if (try? session.engine.store.writeNote(Data(base.utf8), serverPath: path)) != nil {
                reloadFromDisk(document, at: url)
                result = .applied
            } else {
                result = .busy
            }
        }
        if result == .applied { await session.engine.enqueueUpload(serverPath: path) }
        return result
    }

    // MARK: Объединение: запись текста в открытую заметку

    /// Заменяет текст открытой заметки: одна отменяемая замена в редакторе и запись файла вместе.
    /// `.engineMayWrite` — редактор не может принять замену (вкладка не выбрана, страница только для чтения): файл запишет вызывающий.
    func replaceVaultNoteText(_ text: String, path: String, expectedFileText: String, recordsUpdate: Bool,
                              actionName: String = L10n.tr("合并服务器的修改")) async -> VaultApplyResult {
        guard let session = vaultSession, let document = vaultDocument, vaultNote?.path == path else { return .engineMayWrite }
        guard document.ioState == .idle else { return .busy }
        let previous = document.synchronizedText()
        guard !document.isDirty, !document.hasPendingLiveEdits, previous == expectedFileText else { return .busy }
        guard selectedDocument === document, !vaultPageGuardIsReadOnly(document),
              let change = VaultTextDiff.enclosingChange(from: previous, to: text) else { return .engineMayWrite }
        guard replaceForVault(document, change: change, previous: previous, actionName: actionName) else { return .engineMayWrite }
        _ = document.synchronizedText()
        guard let url = try? session.engine.store.writeNote(Data(text.utf8), serverPath: path) else { return .busy }
        if let snapshot = try? FileRevisionSnapshot.capture(url) { document.updateFileRevisionSnapshot(snapshot) }
        document.markSaved(snapshot: text, revision: document.textRevision)
        if recordsUpdate { noteVaultServerUpdate(path: path, previousText: previous) }
        return .applied
    }

    /// Движок сам переписал файл открытой вкладки: документ тихо перечитывается.
    func vaultFileRewritten(path: String) {
        guard let session = vaultSession, let document = vaultDocument, vaultNote?.path == path,
              let url = session.engine.store.noteURL(for: path) else { return }
        reloadFromDisk(document, at: url)
    }

    /// Объединение закончилось: короткое сообщение с «Показать» и «Отменить» и озвучивание.
    func vaultMerged(path: String) {
        guard vaultNote?.path == path else { return }
        vaultUpload.mergeNoticeTask?.cancel()
        let notice = VaultMergeNotice(path: path)
        vaultUpload.mergeNotice = notice
        announceVault(L10n.tr("已添加服务器的修改"))
        vaultUpload.mergeNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            // Пока на сообщении курсор или фокус, оно остаётся.
            while !Task.isCancelled, self?.vaultUpload.noticeIsEngaged == true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, self?.vaultUpload.mergeNotice == notice else { return }
            self?.vaultUpload.mergeNotice = nil
        }
    }

    func dismissVaultMergeNotice() {
        vaultUpload.mergeNoticeTask?.cancel()
        vaultUpload.mergeNotice = nil
    }

    func showVaultMergeChanges() {
        guard let path = vaultUpload.mergeNotice?.path else { return }
        showVaultServerChanges(for: path)
        dismissVaultMergeNotice()
    }

    /// «Отменить» в сообщении: обычная отмена редактора, если последним действием была именно замена от сервера.
    func undoVaultMerge() {
        defer { dismissVaultMergeNotice() }
        guard let undo = hostWindow?.firstResponder?.undoManager, undo.canUndo,
              undo.undoActionName == L10n.tr("合并服务器的修改") else { return }
        undo.undo()
    }

    // MARK: Плашка

    /// Плашка над текстом для состояний этапа 5 (конфликт и отказ сервера не прячутся кнопкой «Оставить»).
    var vaultUploadBanner: VaultBannerKind? {
        guard let path = vaultNote?.path, let session = vaultSession else { return nil }
        if session.noteStates[path] == .conflict { return .conflict }
        if let issue = session.uploadIssues[path] { return .rejected(issue) }
        return nil
    }

    func announceVault(_ text: String) {
        showVaultNotice(text)
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Показ разделов боковой панели

    /// «Неотправленное» и «Конфликты» из меню: боковая панель открывается и раскрывает нужный раздел.
    func showVaultUnsent(conflicts: Bool = false) {
        guard vaultSession != nil else { return }
        isSidebarVisible = true
        vaultUpload.revealRequest = conflicts ? .conflicts : .unsent
    }

    // MARK: Конфликт

    /// Лист решения конфликта по заметке (по кнопке плашки или меню строки). Файл сначала сохраняется.
    func presentVaultConflict(serverPath: String) {
        guard let session = vaultSession ?? windowManager?.activeVaultSession, vaultUpload.conflictSheet == nil,
              let window = hostWindow else { return }
        let proceed = { [weak self] in
            guard let self else { return }
            let model = VaultConflictSheetModel(session: session, serverPath: serverPath)
            model.onApply = { [weak self] context, text in await self?.resolveVaultConflict(context: context, text: text) ?? .busy }
            model.onClose = { [weak self] in self?.closeVaultConflictSheet() }
            let sheet = NSWindow(contentViewController: NSHostingController(rootView: VaultConflictSheet(model: model)))
            sheet.title = model.title
            sheet.styleMask = [.titled, .closable, .resizable]
            sheet.setContentSize(NSSize(width: 720, height: 560))
            self.vaultUpload.conflictSheet = sheet
            window.beginSheet(sheet)
            model.load()
        }
        if let document = vaultDocument, vaultNote?.path == serverPath, document.isDirty || document.hasPendingLiveEdits {
            // Лист работает по сохранённому файлу: не сохранилось — лист не открывается, ошибку показывает обычное сохранение.
            guard save(document) else { return }
            waitForPendingSaves {
                guard document.isDirty == false else { return }
                proceed()
            }
        } else {
            proceed()
        }
    }

    func closeVaultConflictSheet() {
        guard let sheet = vaultUpload.conflictSheet else { return }
        hostWindow?.endSheet(sheet)
        vaultUpload.conflictSheet = nil
    }

    /// Применяет решение: две страховочные копии, запись текста в заметку и в файл, отправка. Только по сохранённому файлу.
    func resolveVaultConflict(context: VaultConflictContext, text: String) async -> VaultConflictApplyResult {
        guard let session = vaultSession ?? windowManager?.activeVaultSession else { return .busy }
        let path = context.serverPath
        guard await session.engine.saveConflictSnapshots(serverPath: path, context: context) else { return .snapshotsFailed }
        let target = windowManager?.state(forVaultPath: path, in: session)
        if let target, target.vaultDocument != nil {
            var result = await target.replaceVaultNoteText(text, path: path, expectedFileText: context.mine, recordsUpdate: false,
                                                          actionName: L10n.tr("解决冲突"))
            if result == .engineMayWrite {
                guard let current = (try? session.engine.store.readNote(serverPath: path)) ?? nil, current == Data(context.mine.utf8),
                      (try? session.engine.store.writeNote(Data(text.utf8), serverPath: path)) != nil else { return .busy }
                target.vaultFileRewritten(path: path)
                result = .applied
            }
            if result == .busy { return .busy }
        } else {
            guard let current = (try? session.engine.store.readNote(serverPath: path)) ?? nil, current == Data(context.mine.utf8),
                  (try? session.engine.store.writeNote(Data(text.utf8), serverPath: path)) != nil else { return .busy }
        }
        let outcome = await session.engine.resolveConflict(serverPath: path, text: text, serverETag: context.serverETag)
        await session.refreshStates()
        switch outcome {
        case .sent, .alreadySynced: return .resolved(sent: true)
        case .fileChanged: return .changed
        case .conflict, .deletedOnServer, .issue: return .heldBack(outcome)
        default: return .resolved(sent: false)
        }
    }
}

/// Итог применения решения конфликта для листа.
enum VaultConflictApplyResult: Equatable {
    case resolved(sent: Bool)
    /// Решение записано, но заметка снова не ушла: новый конфликт, отказ сервера или удаление на сервере.
    case heldBack(VaultUploadOutcome)
    case snapshotsFailed
    case busy
    case changed
}
