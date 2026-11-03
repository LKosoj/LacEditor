import AppKit
import Combine
import Foundation
import SwiftUI

/// Общая точка запросов к серверу хранилища для всех окон: клиент на подключение, свой туннель, озвучивание итогов.
@MainActor
final class VaultRequestsHub: ObservableObject {
    static let shared = VaultRequestsHub()

    static let lastCaptureConnectionKey = "VaultLastCaptureConnectionID"
    /// Туннель, поднятый хабом, останавливается через столько секунд после последнего запроса.
    static let tunnelIdleSeconds: TimeInterval = 30

    /// Точка подключения этапа 4: подключение активной сессии режима и её готовый клиент (nil — сессии нет).
    /// Пока замыкание не выставлено, хаб сам поднимает клиент и туннель.
    var activeSessionProvider: () -> (connection: VaultConnection, client: VaultClient)? = { nil }

    private let connections: VaultConnectionStore
    private let defaults: UserDefaults
    private var clients: [UUID: VaultRequestsClient] = [:]
    private var subscriptions: [UUID: Task<Void, Never>] = [:]
    private var streams: [UUID: Task<AsyncStream<VaultRequestUpdate>, Never>] = [:]
    private var draftReturners: [UUID: (String) -> Bool] = [:]
    private let draftStore: VaultCaptureDraftStore
    private var tunnels: [UUID: VaultTunnel] = [:]
    private var tunnelObservers: [UUID: AnyCancellable] = [:]
    private var tunnelStops: [UUID: Task<Void, Never>] = [:]
    private var tunnelFailures: [UUID: VaultTunnelFailure] = [:]
    private var announced: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init(connections: VaultConnectionStore = .shared, defaults: UserDefaults = .standard,
         draftStore: VaultCaptureDraftStore = VaultCaptureDraftStore()) {
        self.connections = connections
        self.defaults = defaults
        self.draftStore = draftStore
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connectionRestored(vaultID: nil) }
        }
        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connectionRestored(vaultID: nil) }
        }
        observers = [wake, active]
    }

    // MARK: Выбор подключения

    /// По порядку: подключение активной сессии; последнее использованное для записи; единственное сохранённое; иначе nil (выбор у пользователя).
    func resolveConnection() -> VaultConnection? {
        if let active = activeSessionProvider()?.connection { return active }
        let saved = connections.connections
        if let text = defaults.string(forKey: Self.lastCaptureConnectionKey), let id = UUID(uuidString: text),
           let remembered = saved.first(where: { $0.id == id }) {
            return remembered
        }
        return saved.count == 1 ? saved.first : nil
    }

    func rememberConnection(_ id: UUID) {
        defaults.set(id.uuidString, forKey: Self.lastCaptureConnectionKey)
    }

    /// Пока активной сессии нет, подключение выбирает пользователь (если сохранённых несколько).
    var hasActiveSession: Bool { activeSessionProvider() != nil }

    // MARK: Клиенты

    func client(for connection: VaultConnection) -> VaultRequestsClient {
        if let existing = clients[connection.id] { return existing }
        let id = connection.id
        let client = VaultRequestsClient(
            vaultID: id,
            store: VaultRequestsStore(directory: VaultRequestsStore.defaultDirectory(vaultID: id)),
            api: { [weak self] in
                guard let self else { throw VaultClientError.offline }
                return try await self.makeAPI(vaultID: id)
            })
        clients[id] = client
        let streamTask = Task { await client.updates() }
        streams[id] = streamTask
        subscriptions[id] = Task { [weak self] in
            for await update in await streamTask.value {
                guard let self else { return }
                self.handle(update, vaultID: id)
            }
        }
        return client
    }

    /// Клиент, чья подписка хаба уже оформлена: быстрый итог после `submit` не пропадёт.
    func readyClient(for connection: VaultConnection) async -> VaultRequestsClient {
        let client = client(for: connection)
        _ = await streams[connection.id]?.value
        return client
    }

    /// Контроллер панели берёт возврат текста в свой черновик на себя (в окне может быть несвежий текст в памяти).
    func registerDraftReturner(id: UUID, _ returner: @escaping (String) -> Bool) { draftReturners[id] = returner }

    func unregisterDraftReturner(id: UUID) { draftReturners[id] = nil }

    /// Окончательный отказ: текст мысли возвращается в черновик — и для запросов, досланных после перезапуска.
    private func returnToDraft(_ text: String) {
        for returner in draftReturners.values where returner(text) { return }
        try? draftStore.save(VaultCaptureDraftStore.merged(draftStore.load(), returning: text))
    }

    /// Клиенты, уже созданные в этом запуске (для вида «Спросить»: подхватить вопросы после перезапуска).
    var loadedClients: [VaultRequestsClient] { Array(clients.values) }

    /// При запуске: клиент для каждого подключения, у которого есть `requests.json`, и продолжение отправки и опроса.
    func resumeAll() {
        for connection in connections.connections {
            let directory = VaultRequestsStore.defaultDirectory(vaultID: connection.id)
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("requests.json").path) else { continue }
            let client = client(for: connection)
            Task { try? await client.resumePending() }
        }
    }

    /// Связь вернулась (пробуждение Mac, активация приложения, туннель готов, сеть сессии вернулась); nil — всем.
    func connectionRestored(vaultID: UUID?) {
        for (id, client) in clients where vaultID == nil || vaultID == id {
            Task { await client.connectionRestored() }
        }
    }

    /// Подключение исправлено: возобновить запросы, остановленные из-за 401/403/адреса.
    func retryStopped(vaultID: UUID) {
        guard let client = clients[vaultID] else { return }
        Task {
            for record in await client.pending() { await client.retry(requestID: record.requestID) }
        }
    }

    /// Причина, по которой собственный туннель не поднялся; для сообщения пользователю.
    func tunnelFailure(for vaultID: UUID) -> VaultTunnelFailure? { tunnelFailures[vaultID] }

    // MARK: Клиент сервера

    private func makeAPI(vaultID: UUID) async throws -> any VaultRequestsAPI {
        if let active = activeSessionProvider(), active.connection.id == vaultID { return active.client }
        guard let connection = connections.connections.first(where: { $0.id == vaultID }),
              let token = (try? connections.token(for: vaultID)) ?? nil, !token.isEmpty else {
            throw VaultClientError.unauthorized
        }
        tunnelStops[vaultID]?.cancel()
        tunnelStops[vaultID] = nil
        var base = URL(string: connection.baseURL)
        if let settings = connection.tunnel {
            let tunnel = ownTunnel(for: connection.id, settings: settings)
            do {
                let port = try await tunnel.start()
                tunnelFailures[vaultID] = nil
                base = URL(string: "http://127.0.0.1:\(port)")
                // Туннель нужен и для скачивания файла: остановка планируется после любого обращения.
                scheduleTunnelStop(vaultID: vaultID)
            } catch let failure as VaultTunnelFailure {
                tunnelFailures[vaultID] = failure
                // Постоянный отказ (ключ, хост) повтором не исправить: запись остаётся, пока не исправят подключение.
                throw failure.isPermanent ? VaultClientError.unauthorized : VaultClientError.offline
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw VaultClientError.offline
            }
        }
        guard let base else { throw VaultClientError.insecureAddress }
        return VaultClient(baseURL: base, token: token)
    }

    private func ownTunnel(for id: UUID, settings: VaultTunnelSettings) -> VaultTunnel {
        if let existing = tunnels[id] { return existing }
        let tunnel = VaultTunnel(settings: settings)
        tunnels[id] = tunnel
        tunnelObservers[id] = tunnel.$state.removeDuplicates().sink { [weak self] state in
            if case .ready = state { self?.connectionRestored(vaultID: id) }
        }
        return tunnel
    }

    private func scheduleTunnelStop(vaultID: UUID) {
        guard let client = clients[vaultID], tunnels[vaultID] != nil else { return }
        tunnelStops[vaultID]?.cancel()
        tunnelStops[vaultID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.tunnelIdleSeconds))
            while !Task.isCancelled {
                if await client.hasActiveRequests() {
                    try? await Task.sleep(for: .seconds(Self.tunnelIdleSeconds))
                    continue
                }
                self?.tunnels[vaultID]?.stop()
                return
            }
        }
    }

    // MARK: Озвучивание итогов

    private func handle(_ update: VaultRequestUpdate, vaultID: UUID) {
        guard update.phase.isTerminal else { return }
        scheduleTunnelStop(vaultID: vaultID)
        // Остановка до исправления подключения озвучивается каждый раз: после повтора итог будет новым.
        if update.phase.isFinal {
            guard announced.insert(update.request.requestID).inserted else { return }
            if update.request.kind == .capture, case .failed(let failure) = update.phase {
                switch failure {
                case .rejected, .serverError: returnToDraft(update.request.text)
                default: break
                }
            }
        }
        Self.announce(Self.finalMessage(for: update))
    }

    /// Текст итога для озвучивания и строки состояния.
    nonisolated static func finalMessage(for update: VaultRequestUpdate) -> String {
        switch update.phase {
        case .completed(let result):
            switch update.request.kind {
            case .ask: return L10n.tr("第二大脑的回答已就绪")
            case .capture:
                return VaultReply.isCaptureAcknowledgement(result.report) ? L10n.tr("已记录") : L10n.tr("服务器作了回答（这不是记录）")
            }
        case .failed(let failure):
            return failure.userMessage
        default:
            return ""
        }
    }

    /// Озвучивание не отнимает фокус.
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}
