import Foundation

/// Вид «Спросить» режима хранилища: вопрос серверу и ответы текущего запуска (только в памяти). Один на окно.
@MainActor
final class VaultAskModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        var id: String
        var question: String
        var phase: VaultRequestPhase
        var vaultID: UUID
        /// «Скрыть» нажато: прогресс не показывается, итог придёт в список ответов.
        var isHidden = false

        var result: VaultRequestResult? {
            if case .completed(let result) = phase { return result }
            return nil
        }
    }

    static let maxEntries = 20

    @Published private(set) var entries: [Entry] = []
    @Published var question = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var submitError: String?

    /// Точки подключения этапов 4 и 6.
    var connectionProvider: () -> VaultConnection? = { VaultRequestsHub.shared.resolveConnection() }
    /// Серверный путь → открыть заметку.
    var openNote: ((String) -> Void)?
    var openDailyNote: (() -> Void)?
    /// (имя файла, текст) → новая несохранённая вкладка.
    var openText: ((String, String) -> Void)?
    /// Строка состояния окна и озвучивание готового ответа.
    var statusReporter: ((String) -> Void)?

    private let hub: VaultRequestsHub
    private var clients: [UUID: VaultRequestsClient] = [:]
    private var tracking: [String: Task<Void, Never>] = [:]
    /// Запросы, ожидание которых отменено: поздние обновления по ним не записываются.
    private var cancelledIDs: Set<String> = []

    init(hub: VaultRequestsHub = .shared) { self.hub = hub }

    var canAsk: Bool {
        !isSubmitting && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Вопросы, ожидавшие ответа до перезапуска приложения, снова появляются в списке.
    func start() {
        for client in hub.loadedClients {
            Task {
                // Сначала записи читаются с диска, потом берётся список.
                try? await client.resumePending()
                for record in await client.pending() where record.kind == .ask {
                    adopt(record, client: client)
                }
            }
        }
    }

    func ask() {
        guard canAsk, let connection = connectionProvider() else { return }
        submit(question, connection: connection, clearsField: true)
    }

    /// Новый запрос с тем же вопросом (прежний `request_id` вернул бы ту же упавшую задачу).
    func retry(_ id: String) {
        guard !isSubmitting, let entry = entries.first(where: { $0.id == id }),
              let connection = VaultConnectionStore.shared.connections.first(where: { $0.id == entry.vaultID }) else { return }
        submit(entry.question, connection: connection, clearsField: false, replacing: id)
    }

    func hide(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isHidden = true
    }

    /// Только пока запрос ждёт связь и ещё не принят сервером.
    func cancelWaiting(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }), let client = clients[entry.vaultID] else { return }
        Task {
            if await client.cancelWaiting(requestID: id) {
                cancelledIDs.insert(id)
                tracking[id]?.cancel()
                entries.removeAll { $0.id == id }
                if question.isEmpty { question = entry.question }
            }
        }
    }

    /// Кнопка «Повторить» без сети: разбудить паузы.
    func retryNow() { hub.connectionRestored(vaultID: nil) }

    func downloadArtifact(_ artifact: VaultJobArtifact, in entryID: String) async throws -> VaultArtifactData {
        guard let entry = entries.first(where: { $0.id == entryID }), let client = clients[entry.vaultID] else {
            throw VaultClientError.offline
        }
        return try await client.downloadArtifact(path: artifact.downloadPath)
    }

    /// Открывает артефакт как несохранённую вкладку, если это текст; иначе false.
    func open(_ artifact: VaultJobArtifact, data: Data) -> Bool {
        guard let text = VaultArtifactText.decode(data, name: artifact.name, mimeType: artifact.mimeType) else { return false }
        openText?(artifact.name, text)
        return true
    }

    /// Ответ, пришедший на «Записать мысль», когда сервер счёл её вопросом: показывается в списке ответов.
    func adoptAnswer(id: String, question: String, result: VaultRequestResult, vaultID: UUID, client: VaultRequestsClient) {
        guard !entries.contains(where: { $0.id == id }), !cancelledIDs.contains(id) else { return }
        clients[vaultID] = client
        insert(Entry(id: id, question: question, phase: .completed(result), vaultID: vaultID))
    }

    // MARK: Внутреннее

    /// `replacing`: прежняя запись убирается только после успешной постановки нового запроса.
    private func submit(_ text: String, connection: VaultConnection, clearsField: Bool, replacing old: String? = nil) {
        isSubmitting = true
        submitError = nil
        Task {
            defer { isSubmitting = false }
            do {
                let client = await hub.readyClient(for: connection)
                clients[connection.id] = client
                let stream = await client.updates()
                let id = try await client.submit(text: text, kind: .ask)
                hub.rememberConnection(connection.id)
                if clearsField, question == text { question = "" }
                if let old { entries.removeAll { $0.id == old } }
                insert(Entry(id: id, question: text.trimmingCharacters(in: .whitespacesAndNewlines), phase: .submitting, vaultID: connection.id))
                track(id, client: client, stream: stream)
            } catch let error as VaultRequestError {
                submitError = VaultCaptureController.message(for: error)
            } catch {
                submitError = L10n.tr("无法保存想法，请重试")
            }
        }
    }

    private func adopt(_ record: VaultPendingRequest, client: VaultRequestsClient) {
        guard !entries.contains(where: { $0.id == record.requestID }), !cancelledIDs.contains(record.requestID) else { return }
        clients[client.vaultID] = client
        insert(Entry(id: record.requestID, question: record.text, phase: .waitingForConnection, vaultID: client.vaultID))
        track(record.requestID, client: client)
    }

    private func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            // Лишними становятся самые старые уже завершённые записи.
            if let index = entries.lastIndex(where: { $0.phase.isTerminal }) { entries.remove(at: index) }
        }
    }

    private func track(_ id: String, client: VaultRequestsClient, stream existing: AsyncStream<VaultRequestUpdate>? = nil) {
        tracking[id] = Task { [weak self] in
            let stream: AsyncStream<VaultRequestUpdate>
            if let existing { stream = existing } else { stream = await client.updates() }
            for await update in stream where update.request.requestID == id {
                guard let self else { return }
                self.apply(update)
                if update.phase.isFinal { break }
            }
            self?.tracking[id] = nil
        }
    }

    private func apply(_ update: VaultRequestUpdate) {
        guard !cancelledIDs.contains(update.request.requestID),
              let index = entries.firstIndex(where: { $0.id == update.request.requestID }) else { return }
        entries[index].phase = update.phase
        if update.phase.isTerminal {
            entries[index].isHidden = false
            statusReporter?(VaultRequestsHub.finalMessage(for: update))
        }
    }
}
