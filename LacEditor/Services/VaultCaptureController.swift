import AppKit
import Combine
import Foundation

/// «Записать мысль…»: панель закрывается сразу, как только запрос записан в `requests.json`;
/// ход (отправка, ожидание связи, итог) показывается сообщениями и озвучивается. Один контроллер на окно.
@MainActor
final class VaultCaptureController: ObservableObject {
    /// Панель открыта, пока не nil (как у быстрого открытия).
    @Published private(set) var request: UUID?
    /// Черновик; пишется в файл через 0,5 с после последнего ввода и при закрытии панели.
    @Published var text: String = "" {
        didSet { if text != oldValue { scheduleDraftSave() } }
    }
    @Published private(set) var connection: VaultConnection?
    /// Ошибка последней попытки (текст остался в поле).
    @Published private(set) var notice: String?
    @Published private(set) var isSubmitting = false
    /// Ставит этап 4: открыть заметку дня после «Записано».
    var openDailyNote: (() -> Void)?

    private weak var appState: AppState?
    private let draftStore: VaultCaptureDraftStore
    private let hub: VaultRequestsHub
    private var draftSaveTask: Task<Void, Never>?
    private var tracking: [String: Task<Void, Never>] = [:]
    private let returnerID = UUID()
    /// Предупреждение, которое строка состояния не удержит (её перебивают фазы запроса): показывается при следующем открытии панели.
    private var deferredNotice: String?

    init(appState: AppState, draftStore: VaultCaptureDraftStore = VaultCaptureDraftStore(), hub: VaultRequestsHub = .shared) {
        self.appState = appState
        self.draftStore = draftStore
        self.hub = hub
        hub.registerDraftReturner(id: returnerID) { [weak self] returned in
            guard let self else { return false }
            self.restoreToDraft(returned)
            return true
        }
    }

    deinit {
        let hub = hub, id = returnerID
        Task { @MainActor in hub.unregisterDraftReturner(id: id) }
    }

    var isPresented: Bool { request != nil }

    /// Сохранённые подключения (для пустого состояния и выбора «Куда»).
    var availableConnections: [VaultConnection] { VaultConnectionStore.shared.connections }

    /// Выбор «Куда» нужен, только если сессии нет и подключений несколько.
    var showsConnectionPicker: Bool { !hub.hasActiveSession && availableConnections.count > 1 }

    /// Текст валиден и есть подключение.
    var canSend: Bool {
        guard connection != nil, !isSubmitting else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.unicodeScalars.count <= VaultRequestText.maxScalars
    }

    var characterCount: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }

    // MARK: Панель

    func present() {
        guard request == nil, let appState else { return }
        appState.commandPalette.dismiss()
        appState.folderSearch.cancelQuickOpen()
        appState.vaultSearchStorage?.dismissQuickOpen()
        appState.snippetPicker.dismiss()
        text = draftStore.load()
        connection = hub.resolveConnection()
        notice = deferredNotice
        deferredNotice = nil
        request = UUID()
    }

    /// Esc, клик вне панели, «Закрыть»: черновик сохраняется сразу; запросы в пути продолжаются.
    func dismiss() {
        flushDraft()
        request = nil
    }

    func chooseConnection(_ connection: VaultConnection) {
        self.connection = connection
        hub.rememberConnection(connection.id)
    }

    /// Записывает запрос на диск и закрывает панель; поле и файл черновика очищаются только после успешной записи.
    func send() {
        guard canSend, let connection else { return }
        let sent = text
        isSubmitting = true
        notice = nil
        Task {
            defer { isSubmitting = false }
            do {
                let client = await hub.readyClient(for: connection)
                // Подписка оформляется до отправки: быстрый итог не потеряется.
                let stream = await client.updates()
                let id = try await client.submit(text: sent, kind: .capture)
                hub.rememberConnection(connection.id)
                appState?.showVaultStatus(L10n.tr("正在发送…"))
                // Убирается только отправленная часть: то, что дописано за время отправки, остаётся в черновике.
                if text.hasPrefix(sent) {
                    text = String(text.dropFirst(sent.count))
                } else {
                    // Правили середину: чужой текст не трогаем, но предупреждаем, что отправленная мысль осталась в черновике.
                    let message = L10n.tr("想法已发送；草稿中保留了带修改的文字")
                    deferredNotice = message
                    VaultRequestsHub.announce(message)
                }
                flushDraft()
                track(id, stream: stream, client: client, vaultID: connection.id)
                request = nil
            } catch let error as VaultRequestError {
                notice = Self.message(for: error)
            } catch {
                notice = L10n.tr("无法保存想法，请重试")
            }
        }
    }

    static func message(for error: VaultRequestError) -> String {
        switch error {
        case .empty: L10n.tr("写下想法，它会进入笔记库")
        case .tooLong: L10n.tr("想法太长（最多 100000 个字符）")
        case .storageUnavailable: L10n.tr("无法保存想法，请重试")
        }
    }

    // MARK: Диктовка

    var dictationUnavailableReason: String? {
        guard let appState else { return nil }
        return AIDictationController.voiceUnavailableReason(preferences: appState.preferences)
    }

    var isDictationEnabled: Bool {
        guard let appState else { return false }
        return dictationUnavailableReason == nil && (appState.aiDictation.state == .idle || appState.aiDictation.isCapturingExternally)
    }

    func toggleDictation() {
        appState?.aiDictation.toggle(into: { [weak self] dictated, dictationNotice in
            self?.appendDictated(dictated, notice: dictationNotice)
        })
    }

    /// Продиктованный текст дописывается в конец черновика; закрытая панель не открывается.
    private func appendDictated(_ dictated: String, notice dictationNotice: String?) {
        if let dictationNotice, request != nil { notice = dictationNotice }
        // Панель закрыта: актуален файл, а не текст в памяти (как в `restoreToDraft`).
        let base = request == nil ? draftStore.load() : text
        var parts: [String] = []
        if let addition = AIDictationController.insertion(of: dictated, in: base as NSString, at: (base as NSString).length) {
            text = base + addition
            flushDraft()
            parts.append(L10n.tr("听写文字已加入草稿"))
        }
        // Одно сообщение: замечание диктовки не затирается итогом.
        if request == nil {
            if let dictationNotice { parts.append(dictationNotice) }
            if !parts.isEmpty { appState?.showVaultStatus(parts.reversed().joined(separator: "\n"), isError: dictationNotice != nil) }
        }
    }

    // MARK: Черновик

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushDraft()
        }
    }

    private func flushDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        do {
            try draftStore.save(text)
        } catch {
            let message = Self.message(for: .storageUnavailable)
            notice = message
            VaultRequestsHub.announce(message)
        }
    }

    /// Окончательный отказ: текст возвращается в черновик (в пустое поле — как есть, иначе после пустой строки).
    private func restoreToDraft(_ returned: String) {
        // Панель закрыта: актуален файл, а не текст в памяти.
        text = VaultCaptureDraftStore.merged(request == nil ? draftStore.load() : text, returning: returned)
        flushDraft()
    }

    // MARK: Ход запроса

    private func track(_ id: String, stream: AsyncStream<VaultRequestUpdate>, client: VaultRequestsClient, vaultID: UUID) {
        tracking[id] = Task { [weak self] in
            for await update in stream where update.request.requestID == id {
                guard let self else { return }
                self.handle(update, client: client, vaultID: vaultID)
                if update.phase.isFinal { break }
            }
            self?.tracking[id] = nil
        }
    }

    private func handle(_ update: VaultRequestUpdate, client: VaultRequestsClient, vaultID: UUID) {
        guard let appState else { return }
        switch update.phase {
        case .submitting:
            appState.showVaultStatus(L10n.tr("正在发送…"))
        case .waitingForConnection:
            let message = L10n.tr("将在恢复连接后发送")
            appState.showVaultStatus(message)
            VaultRequestsHub.announce(message)
        case .queued, .running:
            appState.showVaultStatus(L10n.tr("服务器已接收，正在记录…"))
        case .completed(let result):
            if VaultReply.isCaptureAcknowledgement(result.report) {
                appState.showVaultStatus(L10n.tr("已记录"))
            } else {
                // Сервер счёл мысль вопросом: ответ не теряется, он виден в «Спросить».
                appState.showVaultStatus(L10n.tr("服务器作了回答（这不是记录）"))
                appState.vaultAsk.adoptAnswer(id: update.request.requestID, question: update.request.text, result: result,
                                              vaultID: vaultID, client: client)
            }
        case .failed(let failure):
            var message = failure.userMessage
            if case .needsConnectionFix = failure, let tunnel = hub.tunnelFailure(for: vaultID) {
                message = tunnel.userMessage
            }
            switch failure {
            case .rejected, .serverError:
                // Текст в черновик возвращает хаб (он видит и запросы, досланные после перезапуска).
                message += "\n" + L10n.tr("未能发送，文字已放回草稿")
            default: break
            }
            appState.showVaultStatus(message, isError: true)
        }
    }
}
