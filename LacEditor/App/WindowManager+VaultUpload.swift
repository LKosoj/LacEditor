import AppKit

/// Хозяин открытых вкладок для движка отправки: только вкладка меняет текст своего документа.
@MainActor
final class VaultUploadHostAdapter: VaultUploadHost {
    private weak var manager: WindowManager?
    private weak var session: VaultSession?

    init(manager: WindowManager, session: VaultSession) {
        self.manager = manager
        self.session = session
    }

    private func state(for path: String) -> AppState? {
        guard let manager, let session else { return nil }
        return manager.state(forVaultPath: path, in: session)
    }

    func applyMergedText(_ text: String, serverPath: String, expectedFileText: String) async -> VaultApplyResult {
        // Вкладки нет: файл запишет движок.
        guard let state = state(for: serverPath) else { return .engineMayWrite }
        return await state.replaceVaultNoteText(text, path: serverPath, expectedFileText: expectedFileText, recordsUpdate: true)
    }

    func fileRewritten(serverPath: String) async {
        state(for: serverPath)?.vaultFileRewritten(path: serverPath)
    }
}

@MainActor
private final class VaultUploadResultBox {
    var summary: VaultUploadSummary?
    /// Модальное окно «Отправляется…» уже закрыто.
    var isClosed = false
}

/// Отправка правок на уровне приложения: хозяин вкладок, вопросы при выходе и при переключении хранилища.
extension WindowManager {
    /// Вкладка, в которой открыта заметка `path` этого хранилища.
    func state(forVaultPath path: String, in session: VaultSession) -> AppState? {
        states(of: session).first { $0.vaultNote?.path == path }
    }

    /// Подключает обработчики событий отправки: плашки, сообщение об объединении, озвучивание, хозяина вкладок.
    func configureVaultUpload(_ session: VaultSession) {
        let adapter = VaultUploadHostAdapter(manager: self, session: session)
        vaultUploadHost = adapter
        session.setUploadHost(adapter)
        session.mergedHandler = { [weak self, weak session] path in
            guard let self, let session else { return }
            self.state(forVaultPath: path, in: session)?.vaultMerged(path: path)
        }
        session.uploadIssueHandler = { [weak self, weak session] path, issue in
            guard let self, let session, let issue, let state = self.state(forVaultPath: path, in: session) else { return }
            AccessibilityNotification.Announcement(L10n.tr("服务器没有接受这篇笔记的修改（%@）", issue.userMessage)).post()
            state.objectWillChange.send()
        }
        session.uploadsFinishedHandler = { [weak self, weak session] sent in
            // Одну только что сохранённую заметку не объявляем: говорим об очереди, накопленной без связи, или о нескольких заметках.
            guard sent > 0, let self, let session else { return }
            let wasOffline = session.hadOfflineSpell
            session.hadOfflineSpell = false
            guard sent > 1 || wasOffline, let state = self.activeState, state.vaultSession === session, state.vaultNote != nil else { return }
            state.announceVault(L10n.tr("修改已发送"))
        }
    }

    // MARK: Выход из приложения

    /// Вопрос про неотправленное до обычной процедуры выхода. `completion(true)` — выходить.
    func confirmVaultUnsentBeforeQuit(completion: @escaping (Bool) -> Void) {
        guard let session = activeVaultSession else { completion(true); return }
        Task { @MainActor in
            await session.refreshStates()
            let summary = session.unsentSummary
            guard let prompt = summary.quitPrompt() else { completion(true); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("尚未上传的笔记：%lld", prompt.count)
            var lines = prompt.listed.map { "• " + L10n.tr("%@：%@", $0.title, $0.statusText) }
            if prompt.moreCount > 0 { lines.append(L10n.tr("还有 %lld 篇", prompt.moreCount)) }
            var footer: [String] = []
            if prompt.isOffline { footer.append(L10n.tr("服务器目前无法连接。")) }
            if session.isAuthPaused { footer.append(VaultClientError.unauthorized.userMessage) }
            if prompt.conflictCount > 0 { footer.append(L10n.tr("未解决的冲突：%lld。修改会保留在此 Mac 上。", prompt.conflictCount)) }
            if prompt.blockedCount > 0 { footer.append(L10n.tr("服务器未接受或已删除的笔记：%lld。修改会保留在此 Mac 上。", prompt.blockedCount)) }
            if prompt.isOffline || prompt.offersSend {
                footer.append(L10n.tr("如果现在退出，这些修改会保留在此 Mac 上，并在下次连接笔记库时发送。"))
            }
            alert.informativeText = (lines + [""] + footer).joined(separator: "\n")
            if prompt.offersSend {
                alert.addButton(withTitle: L10n.tr("发送并退出"))
                alert.addButton(withTitle: L10n.tr("退出，稍后发送"))
            } else {
                alert.addButton(withTitle: prompt.isOffline ? L10n.tr("退出，稍后发送") : L10n.tr("退出"))
            }
            alert.addButton(withTitle: L10n.tr("取消"))
            let response = alert.runModal()
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if prompt.offersSend {
                switch index {
                case 0:
                    guard let result = await self.sendUnsentWithProgress(session) else { completion(true); return }
                    if result.remaining.isEmpty { completion(true); return }
                    let failed = NSAlert()
                    failed.alertStyle = .warning
                    failed.messageText = L10n.tr("有 %lld 篇笔记未能发送", result.remaining.count)
                    failed.informativeText = L10n.tr("修改已保存在此 Mac 上。")
                    failed.addButton(withTitle: L10n.tr("退出"))
                    failed.addButton(withTitle: L10n.tr("取消"))
                    completion(failed.runModal() == .alertFirstButtonReturn)
                case 1: completion(true)
                default: completion(false)
                }
            } else {
                completion(index == 0)
            }
        }
    }

    /// Отправка очереди с окном «Отправляется…». nil — человек не стал ждать.
    private func sendUnsentWithProgress(_ session: VaultSession) async -> VaultUploadSummary? {
        let alert = NSAlert()
        alert.messageText = L10n.tr("正在发送…")
        alert.addButton(withTitle: L10n.tr("不等待并退出"))
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
        bar.isIndeterminate = true
        // «Уменьшить движение»: полоса стоит на месте, слова в заголовке остаются.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { bar.startAnimation(nil) }
        alert.accessoryView = bar
        // Задача стартует только внутри модального цикла (главный поток занят `runModal`), поэтому `abortModal` всегда к месту.
        let box = VaultUploadResultBox()
        Task { @MainActor in
            box.summary = await session.engine.uploadPending(timeout: 15)
            // Окно уже закрыли кнопкой: `abortModal` оборвал бы чужое модальное окно.
            if !box.isClosed { NSApp.abortModal() }
        }
        let response = alert.runModal()
        box.isClosed = true
        return response == .abort ? box.summary : nil
    }

    // MARK: Переключение хранилища

    /// Один вопрос вместо двух: переключить хранилище, отправив или оставив неотправленное. `completion(true)` — переключать.
    func confirmVaultSwitch(from active: VaultSession, to connection: VaultConnection, completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            await active.refreshStates()
            let summary = active.unsentSummary
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("关闭笔记库“%@”并打开“%@”？", active.connection.name, connection.name)
            let canSend = summary.hasSendable && active.isOnline
            if summary.unsentCount + summary.conflictCount == 0 {
                alert.addButton(withTitle: L10n.tr("关闭并打开"))
                alert.addButton(withTitle: L10n.tr("取消"))
                completion(alert.runModal() == .alertFirstButtonReturn)
                return
            }
            alert.informativeText = L10n.tr("笔记库“%@”中尚未上传的笔记：%lld", active.connection.name,
                                           summary.unsentCount + summary.conflictCount)
            if canSend { alert.addButton(withTitle: L10n.tr("发送并切换")) }
            alert.addButton(withTitle: L10n.tr("切换，下次打开“%@”时发送", active.connection.name))
            alert.addButton(withTitle: L10n.tr("取消"))
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let switchOnly = canSend ? 1 : 0
            if canSend, index == 0 {
                let result = await self.sendUnsentWithProgress(active)
                if let result, !result.remaining.isEmpty {
                    let failed = NSAlert()
                    failed.alertStyle = .warning
                    failed.messageText = L10n.tr("有 %lld 篇笔记未能发送", result.remaining.count)
                    failed.addButton(withTitle: L10n.tr("仍然切换"))
                    failed.addButton(withTitle: L10n.tr("留在这里"))
                    completion(failed.runModal() == .alertFirstButtonReturn)
                } else {
                    completion(true)
                }
            } else {
                completion(index == switchOnly)
            }
        }
    }
}
