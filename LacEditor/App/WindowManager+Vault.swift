import AppKit

/// Режим хранилища на уровне приложения: одна сессия на все окна (`activeVaultSession`) и привязка к ней вкладок.
/// Писательский режим и хранилище в одной вкладке не совмещаются.
extension WindowManager {
    // MARK: Вход и выход

    /// Сессия для подключения: уже работающая или новая. Параллельные вызовы ждут один и тот же запуск.
    /// Изменились настройки того же подключения — старая сессия останавливается, вкладки переходят к новой.
    /// Другое хранилище при работающем не открывается: переключение идёт через `enterVault` с подтверждением.
    func ensureVaultSession(for connection: VaultConnection) async throws -> VaultSession {
        if let running = vaultStartTask {
            if vaultStartingID == connection.id { return try await running.value }
            _ = try? await running.value
        }
        if let active = activeVaultSession {
            guard active.connection.id == connection.id else { throw CancellationError() }
            if active.connection == connection { return active }
            return try await startVaultSession(for: connection, replacing: active)
        }
        return try await startVaultSession(for: connection, replacing: nil)
    }

    private func startVaultSession(for connection: VaultConnection, replacing old: VaultSession?) async throws -> VaultSession {
        let task = Task { @MainActor () -> VaultSession in
            let session = try await VaultSession.make(connection: connection)
            configureVaultSession(session)
            configureVaultUpload(session)
            let moved = old.map { states(of: $0) } ?? []
            if let old { await old.stop() }
            // Сессия видна приложению ещё до конца запуска: параллельные входы и открытия не создают вторую.
            activeVaultSession = session
            VaultRequestsHub.shared.activeSessionProvider = { [weak self] in
                self?.activeVaultSession.map { ($0.connection, $0.client) }
            }
            for state in moved {
                state.vaultSearchStorage?.cancel()
                state.vaultSession = session
                session.attach()
            }
            do {
                try await session.start()
            } catch {
                if activeVaultSession === session { activeVaultSession = nil }
                VaultRequestsHub.shared.activeSessionProvider = { nil }
                for state in moved { detachVault(from: state, stopsSession: false) }
                await session.stop()
                throw error
            }
            if vaultCleanedIDs.insert(connection.id).inserted {
                // Первый запуск сессии в этом сеансе: следы прошлого сеанса убираются, кроме возвращающихся вкладок.
                await session.engine.cleanupAfterCrash(restoredPaths: restoredVaultPaths[connection.id.uuidString] ?? [])
            }
            for state in moved where state.vaultNote != nil { state.restoreVaultNoteBinding() }
            VaultRequestsHub.shared.resumeAll()
            return session
        }
        vaultStartTask = task
        vaultStartingID = connection.id
        defer {
            vaultStartTask = nil
            vaultStartingID = nil
        }
        return try await task.value
    }

    private func configureVaultSession(_ session: VaultSession) {
        session.serverChangeHandler = { [weak self, weak session] changes in
            guard let self, let session else { return }
            self.handleVaultServerChanges(changes, session: session)
        }
        session.localTextPreservedHandler = { [weak self, weak session] path in
            guard let self, let session else { return }
            let target = self.states(of: session).first { $0.vaultNote?.path == path } ?? self.activeState
            let message = L10n.tr("本地文本已先保存为快照，再被服务器版本替换")
            target?.showVaultNotice(message)
            AccessibilityNotification.Announcement(message).post()
        }
        session.connectionRestoredHandler = { [weak self, weak session] in
            guard let self, let session else { return }
            for state in self.states(of: session) { state.retryVaultOpeningIfWaiting() }
        }
    }

    /// Вход из листа подключения (этап 2 вызывает `onConnect`). Если уже открыто другое хранилище — подтверждение переключения.
    func enterVault(_ connection: VaultConnection, from state: AppState) {
        if let active = activeVaultSession, active.connection.id != connection.id {
            confirmVaultSwitch(from: active, to: connection) { [weak self] approved in
                guard approved, let self else { return }
                self.vaultQuitApproved = true
                Task { @MainActor in
                    // Закрытие вкладки с правками можно отменить: тогда прежнее хранилище остаётся.
                    // Правки уже отправлены или оставлены на Mac по выбору человека: вкладки закрываются без новых вопросов.
                    let left = await self.leaveVault()
                    self.vaultQuitApproved = false
                    guard left else { return }
                    self.enterVault(connection, from: state)
                }
            }
            return
        }
        state.showVaultNotice(L10n.tr("连接中"))
        Task { @MainActor in
            do {
                let session = try await ensureVaultSession(for: connection)
                // Отказ выйти из режима писателя — не ошибка: вкладка остаётся как была.
                guard attachVault(session, to: state) else { return }
                state.isSidebarVisible = true
                state.showVaultNotice(L10n.tr("已连接到笔记库“%@”", connection.name))
                if session.needsStateAttention { state.confirmVaultStateAttention() }
            } catch is CancellationError {
                return
            } catch {
                let message = (error as? VaultClientError)?.userMessage
                    ?? (error as? VaultTunnelFailure)?.userMessage ?? error.localizedDescription
                state.showVaultNotice(message, isError: true)
            }
        }
    }

    /// «Закрыть хранилище»: вкладки заметок закрываются обычным путём (с вопросом о сохранении), затем завершаются
    /// закрытия заметок в движке и сессия останавливается. Файлы открытых заметок остаются на Mac.
    /// false — пользователь отменил закрытие вкладки: сессия и эта вкладка остаются.
    @discardableResult
    func leaveVault() async -> Bool {
        guard let session = activeVaultSession else { return true }
        for state in states(of: session) where state.vaultNote != nil {
            state.hostWindow?.performClose(nil)
            // Ответ на вопрос о сохранении приходит позже: ждём, пока вкладка закроется или вопрос закончится.
            try? await Task.sleep(nanoseconds: 100_000_000)
            while state.vaultSession === session, isConfirmingClose { try? await Task.sleep(nanoseconds: 100_000_000) }
            if state.vaultSession === session { try? await Task.sleep(nanoseconds: 250_000_000) }
            if state.vaultSession === session { return false }
        }
        for state in states(of: session) { detachVault(from: state, stopsSession: false) }
        await session.waitForClosings()
        // «Закрыть хранилище»: закрытые вкладки с неотправленным получают короткую попытку отправки до остановки.
        // При переключении человек уже выбрал, отправлять или оставить (`vaultQuitApproved`).
        if !vaultQuitApproved {
            let summary = await session.engine.uploadPending(timeout: 5)
            let left = summary.remaining.count + summary.conflicts.count
            if left > 0 {
                let text = L10n.tr("%lld 篇笔记未上传，已留在此 Mac 上", left)
                activeState?.showVaultNotice(text)
                AccessibilityNotification.Announcement(text).post()
            }
        }
        if activeVaultSession === session {
            activeVaultSession = nil
            VaultRequestsHub.shared.activeSessionProvider = { nil }
        }
        await session.stop()
        return true
    }

    // MARK: Привязка вкладок

    /// Привязывает вкладку к сессии. В вкладке писательского режима сначала спрашивает: режимы не совмещаются.
    /// false — пользователь отказался выходить из режима писателя.
    @discardableResult
    func attachVault(_ session: VaultSession, to state: AppState, confirmsWriterExit: Bool = true) -> Bool {
        if state.vaultSession === session { return true }
        if state.writerSession != nil, confirmsWriterExit {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.tr("要在此标签页打开笔记库，需要先退出写作模式")
            alert.addButton(withTitle: L10n.tr("退出写作模式"))
            alert.addButton(withTitle: L10n.tr("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        detachVault(from: state)
        detachWriter(from: state)
        state.vaultSession = session
        session.attach()
        return true
    }

    /// Отвязка вкладки; когда окон не осталось, проверки приостанавливаются (сессия и очередь отправки живут).
    func detachVault(from state: AppState, stopsSession: Bool = true) {
        guard let session = state.vaultSession else { return }
        state.releaseVaultNote()
        state.vaultSearchStorage?.cancel()
        state.vaultSession = nil
        if session.detach(), stopsSession { session.suspend() }
    }

    func states(of session: VaultSession) -> [AppState] {
        states.values.filter { $0.vaultSession === session }
    }

    // MARK: Заметки

    /// Открывает заметку: уже открытую выделяет, в пустой вкладке открывает на месте, иначе — в новой вкладке.
    /// `completion(true)` — текст заметки загружен в документ.
    func openVaultNote(path: String, from source: AppState?, inNewTab: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard let session = activeVaultSession, VaultPath.validated(path) != nil else {
            completion?(false)
            return
        }
        if let existing = states(of: session).first(where: { $0.vaultNote?.path == path }) {
            existing.hostWindow?.makeKeyAndOrderFront(nil)
            if let tabs = existing.hostWindow?.tabGroup { tabs.selectedWindow = existing.hostWindow }
            completion?(true)
            return
        }
        let origin = source ?? activeState
        // «В новой вкладке» — всегда новая; иначе пустая вкладка используется, а занятая не заменяется: открывается новая.
        let target: AppState
        if !inNewTab, let origin, origin.vaultNote == nil, origin.documents.count == 1, origin.documents.first?.isDisposableBlank == true {
            target = origin
        } else {
            target = openNativeTab(from: origin)
        }
        guard attachVault(session, to: target) else {
            completion?(false)
            return
        }
        target.hostWindow?.makeKeyAndOrderFront(nil)
        target.beginVaultNoteOpening(path: path, completion: completion)
    }

    /// «Сегодня»: заметка дня `daily/YYYY-MM-DD.md`. Если сервер ещё не создал её, это не ошибка:
    /// сообщение «Записей за сегодня нет», запись делается через «Записать мысль…».
    func openVaultDailyNote(from source: AppState?) {
        let path = VaultDailyNote.path(for: Date())
        guard let session = activeVaultSession else { return }
        Task { @MainActor in
            if session.isOnline { await session.loadFolder(VaultDailyNote.folder) }
            if let children = session.catalog.childrenByPath[VaultDailyNote.folder], !children.contains(where: { $0.path == path }) {
                (source ?? activeState)?.showVaultNotice(L10n.tr("今天还没有记录"))
                return
            }
            openVaultNote(path: path, from: source)
        }
    }

    /// Восстановление вкладки из файла сессии: документ вернулся обычным путём (файл заметки остался на Mac),
    /// здесь вкладка снова привязывается к хранилищу. Нет связи — работает локальная копия, правки уйдут позже.
    func restoreVaultNote(_ binding: VaultNoteBinding?, in state: AppState) {
        guard let binding, binding.isValid, let id = UUID(uuidString: binding.vaultID),
              let connection = VaultConnectionStore.shared.connections.first(where: { $0.id == id }) else { return }
        state.vaultNote = binding
        Task { @MainActor in
            do {
                let session = try await ensureVaultSession(for: connection)
                attachVault(session, to: state, confirmsWriterExit: false)
                state.vaultNote = binding
                state.restoreVaultNoteBinding()
            } catch {
                // Токен не принят или туннель не поднялся: вкладка остаётся обычной, причина — в строке состояния.
                state.vaultNote = nil
                let message = (error as? VaultClientError)?.userMessage
                    ?? (error as? VaultTunnelFailure)?.userMessage ?? error.localizedDescription
                state.showVaultNotice(message, isError: true)
            }
        }
    }

    // MARK: Изменения на сервере

    private func handleVaultServerChanges(_ changes: [VaultNoteChange], session: VaultSession) {
        for change in changes {
            let path: String
            switch change {
            case .updated(let serverPath, _, _), .deleted(let serverPath): path = serverPath
            }
            guard let state = states(of: session).first(where: { $0.vaultNote?.path == path }) else { continue }
            Task { @MainActor in await state.handleVaultChange(change) }
        }
    }
}
