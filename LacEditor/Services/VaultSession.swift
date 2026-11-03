import AppKit
import Combine
import Foundation
import Network

/// Сессия хранилища на всё приложение: туннель, клиент, движок открытых заметок и каталог имён.
/// Окна привязываются к ней через `attach()`/`detach()`; сама сессия живёт в `WindowManager.activeVaultSession`.
@MainActor
final class VaultSession: ObservableObject {
    let connection: VaultConnection
    let client: VaultClient
    let engine: VaultSyncEngine
    let catalog: VaultCatalog
    let tunnel: VaultTunnel?

    @Published private(set) var isConnecting = true
    /// Сервер ответил 401 при отправке: очередь стоит, пока токен не исправят (новое подключение — новая сессия).
    @Published private(set) var isAuthPaused = false
    @Published private(set) var isOnline = true { didSet { if !isOnline { hadOfflineSpell = true } } }
    /// Связь пропадала с прошлого объявления об отправке: очередь, накопленную без связи, стоит объявить.
    var hadOfflineSpell = false
    @Published private(set) var lastSyncDate: Date?
    /// По пути на сервере: состояние каждой записи движка (открытые во вкладках и «Неотправленное»).
    @Published private(set) var noteStates: [String: VaultNoteSyncState] = [:]
    /// Что не отправлено и что в конфликте, по строкам для боковой панели и вопроса при выходе.
    @Published private(set) var unsentSummary: VaultUnsentSummary = .empty
    /// Причина отказа сервера по пути (пока заметка не изменится).
    @Published private(set) var uploadIssues: [String: VaultUploadIssue] = [:]
    /// Закреплённые заметки: хранятся в данных приложения по `vaultID`, не в хранилище.
    @Published var pinnedPaths: [String] {
        didSet { if pinnedPaths != oldValue { savePinned() } }
    }
    @Published private(set) var attachedStateCount = 0
    /// Одна строка об ошибке подключения (без модальных окон); nil — всё хорошо.
    @Published private(set) var connectionIssue: String?
    /// Повреждённое локальное состояние отложено в карантин: уборка и новые заметки заблокированы, пока пользователь не подтвердит.
    @Published private(set) var isQuarantined = false
    /// Движок не смог записать состояние (`.stateBlocked`): отдельный флаг, проверка связи его не сбрасывает.
    @Published private(set) var isStateBlocked = false
    /// Движок заменил локальный текст версией сервера, сохранив его в снимок: менеджер окон сообщает пользователю.
    var localTextPreservedHandler: ((String) -> Void)?

    /// Серверные изменения открытых заметок; выставляет менеджер окон.
    var serverChangeHandler: (([VaultNoteChange]) -> Void)?
    /// Связь вернулась (после обрыва): менеджер окон сообщает очереди запросов этапа 7.
    var connectionRestoredHandler: (() -> Void)?
    /// Правки сервера слиты с локальными (файл и редактор уже обновлены): менеджер окон показывает короткую плашку.
    var mergedHandler: ((String) -> Void)?
    /// Сервер не принял правки (nil — отказ снят): менеджер окон показывает плашку на вкладке.
    var uploadIssueHandler: ((String, VaultUploadIssue?) -> Void)?
    /// Серия отправки закончилась: сколько заметок ушло (для объявления VoiceOver).
    var uploadsFinishedHandler: ((Int) -> Void)?

    var title: String { connection.name }
    var needsStateAttention: Bool { isQuarantined || isStateBlocked }
    var unsentCount: Int { noteStates.values.filter { $0 == .modified || $0 == .uploading }.count }
    /// Неотправленные, которые просят внимания: отказ, нет связи или ждут дольше `VaultUnsentSummary.attentionDelay`.
    /// Только что сохранённая заметка значок не меняет: она уходит сама.
    var attentionUnsentCount: Int { unsentSummary.attentionUnsent().count }
    var conflictCount: Int { noteStates.values.filter { $0 == .conflict }.count }
    var status: VaultStatus {
        VaultStatus.resolve(isConnecting: isConnecting, isOnline: isOnline, unsentCount: attentionUnsentCount, conflictCount: conflictCount)
    }

    /// Слова для строки состояния: без связи — сколько заметок ждёт отправки, при связи — время последней сверки.
    var statusText: String {
        if isAuthPaused { return VaultClientError.unauthorized.userMessage }
        switch status {
        case .offline where unsentCount > 0:
            return L10n.tr("未连接 · %lld 条未上传", unsentCount)
        case .online:
            guard let date = lastSyncDate else { return status.spokenName }
            return L10n.tr("已同步 %@", DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))
        default:
            return status.spokenName
        }
    }

    private let defaults: UserDefaults
    private var eventsTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var attentionTask: Task<Void, Never>?
    private var tunnelObservation: AnyCancellable?
    private var pathMonitor: NWPathMonitor?
    private var wasPathSatisfied = true
    private var wakeObserver: NSObjectProtocol?
    private var isStarted = false
    private var isSuspended = false
    private var isChecking = false
    private var wikiCache: MarkdownWikiLinkResolver?
    private var wikiToken: UInt = 0
    private var catalogObservation: AnyCancellable?
    /// Закрытия заметок в работе: повторное открытие того же пути и выход из режима ждут их конца.
    private var closingTasks: [String: Task<Void, Never>] = [:]
    /// Папки, раскрытые в боковой панели: их содержимое обновляется вместе с корнями.
    private var loadedFolders: Set<String> = []

    static let checkInterval: TimeInterval = 60

    init(connection: VaultConnection, client: VaultClient, engine: VaultSyncEngine, catalog: VaultCatalog,
         tunnel: VaultTunnel?, defaults: UserDefaults = .standard) {
        self.connection = connection
        self.client = client
        self.engine = engine
        self.catalog = catalog
        self.tunnel = tunnel
        self.defaults = defaults
        self.pinnedPaths = defaults.stringArray(forKey: Self.pinnedKey(connection.id)) ?? []
        // Каталог имён изменился: список для `[[…]]` пересобирается при следующем обращении (после смены значения).
        catalogObservation = catalog.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.wikiCache = nil
            self?.objectWillChange.send()
        }
    }

    /// Список заметок хранилища для wiki-ссылок: база — каталог открытых заметок на Mac, пути — имена с сервера.
    var wikiResolver: MarkdownWikiLinkResolver {
        if let wikiCache { return wikiCache }
        wikiToken &+= 1
        let resolver = MarkdownWikiLinkResolver(base: engine.openDirectory, paths: catalog.wikiLinkPaths(), token: wikiToken)
        wikiCache = resolver
        return resolver
    }

    /// Собирает сессию: токен, туннель (если включён) и клиент. Бросает `VaultClientError` или `VaultTunnelFailure`.
    static func make(connection: VaultConnection, store: VaultConnectionStore? = nil) async throws -> VaultSession {
        let connectionStore = store ?? VaultConnectionStore.shared
        guard let token = try? connectionStore.token(for: connection.id), !token.isEmpty else { throw VaultClientError.unauthorized }
        var tunnel: VaultTunnel?
        let baseURL: URL
        if let settings = connection.tunnel {
            let created = VaultTunnel(settings: settings)
            let port = try await created.start()
            tunnel = created
            guard let url = URL(string: "http://127.0.0.1:\(port)") else { throw VaultClientError.insecureAddress }
            baseURL = url
        } else {
            guard let url = try? VaultAddressRule.check(connection.baseURL) else { throw VaultClientError.insecureAddress }
            baseURL = url
        }
        let client = VaultClient(baseURL: baseURL, token: token)
        let engine = VaultSyncEngine(connection: connection, client: client, store: VaultStateStore(vaultID: connection.id))
        let catalog = VaultCatalog(client: client, hiddenRoots: connection.hiddenRoots)
        return VaultSession(connection: connection, client: client, engine: engine, catalog: catalog, tunnel: tunnel)
    }

    // MARK: Привязка окон

    func attach() {
        attachedStateCount += 1
        if isSuspended { resume() }
    }

    /// true — окон режима не осталось: менеджер окон приостанавливает проверки (очередь отправки и туннель живут).
    func detach() -> Bool {
        attachedStateCount = max(0, attachedStateCount - 1)
        return attachedStateCount == 0
    }

    // MARK: Запуск и остановка

    /// Проверка связи → корни каталога → фоновый полный список → слежение за связью и таймер сверки.
    /// Нет связи — не ошибка: сессия остаётся, правки открытых заметок живут на этом Mac.
    /// Бросает только `unauthorized`/`forbidden`: подключение нужно исправить.
    func start() async throws {
        guard !isStarted else { return }
        isStarted = true
        isSuspended = false
        isConnecting = true
        connectionIssue = nil
        observeEnvironment()
        startEvents()
        isQuarantined = engine.store.hasQuarantinedState
        defer { isConnecting = false }
        do {
            try await probeHealth()
            markOnline()
            try await catalog.loadRoots()
            loadedFolders.insert(VaultDailyNote.folder)
            Task { try? await self.catalog.loadChildren(of: VaultDailyNote.folder) }
            Task { _ = await self.catalog.refreshFullListing() }
        } catch let error as VaultClientError {
            switch error {
            case .offline, .timeout:
                isOnline = await engine.isOnline()
            case .unauthorized, .forbidden:
                connectionIssue = error.userMessage
                startPolling()
                await refreshStates()
                throw error
            default:
                connectionIssue = error.userMessage
            }
        } catch {
            isOnline = await engine.isOnline()
        }
        startPolling()
        await refreshStates()
        // Неотправленное с прошлого запуска уходит сразу, как только есть связь.
        Task { _ = await self.engine.uploadPending() }
    }

    /// Движок считает связь потерянной после двух сетевых ошибок подряд: при первой ошибке проверяем ещё раз,
    /// чтобы состояние сессии и движка не расходилось.
    private func probeHealth() async throws {
        do {
            try await engine.perform { try await client.health(timeout: 8) }
        } catch let error as VaultClientError where error == .offline || error == .timeout {
            try await engine.perform { try await client.health(timeout: 8) }
        }
    }

    /// Связь есть: если сессия считала её потерянной, это возврат связи (ждущие вкладки открываются, очередь запросов возобновляется).
    private func markOnline() {
        let wasOnline = isOnline
        isOnline = true
        guard !wasOnline else { return }
        connectionIssue = nil
        connectionRestoredHandler?()
        Task { await self.checkNow() }
        if catalog.roots.isEmpty { Task { await self.reloadCatalog() } }
    }

    /// Выход из режима: проверки и туннель останавливаются; файлы открытых заметок остаются на Mac.
    func stop() async {
        isStarted = false
        stopPolling()
        stopEnvironment()
        eventsTask?.cancel()
        eventsTask = nil
        await engine.shutdown()
        tunnel?.stop()
        catalog.clear()
    }

    /// Последнее окно режима закрыто: проверки и каталог в памяти не нужны, очередь отправки и туннель остаются.
    func suspend() {
        guard isStarted, !isSuspended else { return }
        isSuspended = true
        stopPolling()
        catalog.clear()
        loadedFolders = []
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        startPolling()
        Task { await self.reloadCatalog() }
    }

    // MARK: События движка

    private func startEvents() {
        guard eventsTask == nil else { return }
        let stream = engine.events
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: VaultSyncEvent) {
        switch event {
        case .noteState(let path, let state):
            noteStates[path] = state
        case .connection(let online):
            if online { markOnline() } else { isOnline = false }
        case .lastSync(let date):
            lastSyncDate = date
        case .noteLoadFailed(let path):
            // Скачивание не удалось или отменено: «Загрузка» снимается, записи нет.
            if noteStates[path] == .loading { noteStates[path] = nil }
            Task { await self.refreshStates() }
        case .localTextPreserved(let path):
            localTextPreservedHandler?(path)
            Task { await self.refreshStates() }
        case .stateBlocked:
            isStateBlocked = true
            Task { await self.refreshStates() }
        case .merged(let path):
            mergedHandler?(path)
            Task { await self.refreshStates() }
        case .authPaused(let paused):
            isAuthPaused = paused
            if paused { connectionIssue = VaultClientError.unauthorized.userMessage }
            else if connectionIssue == VaultClientError.unauthorized.userMessage { connectionIssue = nil }
        case .uploadIssue(let path, let issue):
            uploadIssueHandler?(path, issue)
            Task { await self.refreshStates() }
        case .uploadsFinished(let sent):
            uploadsFinishedHandler?(sent)
            Task { await self.refreshStates() }
        }
    }

    /// Хозяин вкладок для объединения: только он меняет открытый документ.
    func setUploadHost(_ host: VaultUploadHost?) {
        Task { await engine.setUploadHost(host) }
    }

    /// Пользователь подтвердил продолжение после повреждённого состояния: карантинные файлы остаются (переименованы), уборка разрешена.
    func acknowledgeQuarantine() async {
        await engine.acknowledgeQuarantine()
        isQuarantined = engine.store.hasQuarantinedState
        isStateBlocked = await engine.isStateBlocked()
        await refreshStates()
    }

    /// Состояния всех записей движка заново (после закрытия вкладки, выхода, отправки).
    func refreshStates() async {
        let records = await engine.records()
        let states = records.mapValues(\.state)
        if states != noteStates { noteStates = states }
        let summary = VaultUnsentSummary(records: records, isOnline: isOnline)
        if summary != unsentSummary { unsentSummary = summary }
        let issues = records.compactMapValues(\.uploadIssue)
        if issues != uploadIssues { uploadIssues = issues }
        scheduleAttentionRefresh()
    }

    /// Ждущая отправки заметка со временем начинает просить внимания: интерфейс обновляется в этот момент.
    private func scheduleAttentionRefresh() {
        attentionTask?.cancel()
        attentionTask = nil
        guard let delay = unsentSummary.nextAttentionDelay() else { return }
        attentionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((max(delay, 0) + 0.2) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshStates()
            self?.objectWillChange.send()
        }
    }

    // MARK: Сверка

    private func startPolling() {
        guard pollTask == nil, !isSuspended else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.checkInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.checkNow()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Сверка открытых заметок с сервером. Без открытых заметок — лёгкий запрос здоровья, чтобы состояние связи не устаревало.
    func checkNow() async {
        guard isStarted, !isSuspended, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        if !isOnline { await engine.connectivityMayHaveChanged() }
        let changes = await engine.checkOpenNotes()
        if !changes.isEmpty { serverChangeHandler?(changes) }
        if isOnline, noteStates.isEmpty { try? await engine.perform { try await client.health(timeout: 8) } }
        let engineOnline = await engine.isOnline()
        if engineOnline { markOnline() } else if isOnline { isOnline = false }
        await refreshStates()
    }

    /// «Проверить сейчас»: сверка открытых заметок и обновление списка имён.
    func checkAndReload() async {
        await checkNow()
        await reloadCatalog()
    }

    func reloadCatalog() async {
        do {
            try await engine.perform { try await catalog.loadRoots() }
            connectionIssue = nil
            markOnline()
        } catch let error as VaultClientError {
            if error != .offline, error != .timeout { connectionIssue = error.userMessage }
        } catch {}
        for folder in loadedFolders { try? await catalog.loadChildren(of: folder) }
        Task { _ = await self.catalog.refreshFullListing() }
    }

    /// Содержимое папки по требованию (раскрытие в панели); запоминается для обновления при сверке.
    func loadFolder(_ path: String) async {
        loadedFolders.insert(path)
        do { try await engine.perform { try await catalog.loadChildren(of: path) } } catch {}
    }

    // MARK: Заметки

    /// Локальный путь заметки; скачивает, если файла нет. Нет связи и нет файла — `VaultClientError.offline`.
    func fileURL(for path: String) async throws -> URL {
        defer { Task { await self.refreshStates() } }
        // Закрытие той же заметки ещё идёт: сначала оно, иначе открытие потеряется между «удалить файл» и «скачать».
        await closingTasks[path]?.value
        return try await engine.open(serverPath: path)
    }

    func serverPath(for url: URL) -> String? {
        engine.serverPath(forLocalPath: url.path)
    }

    /// Файл лежит в `open/` этого хранилища.
    func contains(_ url: URL) -> Bool { serverPath(for: url) != nil }

    /// Вкладка закрыта: движок решает, удалять ли файл (неотправленное остаётся).
    func noteClosed(path: String) {
        let previous = closingTasks[path]
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Файл мог быть сохранён за миг до закрытия: сначала сверка с базой, иначе правка пропадёт вместе с файлом.
            await self.engine.enqueueUpload(serverPath: path)
            await self.engine.noteClosed(serverPath: path)
            await self.refreshStates()
        }
        closingTasks[path] = task
        Task { [weak self] in
            await task.value
            if self?.closingTasks[path] == task { self?.closingTasks[path] = nil }
        }
    }

    /// Ждёт все начатые закрытия заметок (перед остановкой сессии).
    func waitForClosings() async {
        while let task = closingTasks.values.first {
            await task.value
            closingTasks = closingTasks.filter { $0.value != task }
        }
    }

    /// Файл заметки сохранён на Mac: если текст отличается от базы сервера, заметка встаёт в очередь отправки.
    /// Равный базе текст (серверное обновление, отмена правок до исходного) снимает метку «Не отправлено».
    func noteSaved(url: URL) async {
        guard let path = await engine.serverPath(for: url) else { return }
        await engine.enqueueUpload(serverPath: path)
        await refreshStates()
    }

    // MARK: Закреплённое

    func togglePin(_ path: String) {
        pinnedPaths = VaultPresentation.togglingPin(path, in: pinnedPaths)
    }

    func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }

    private static func pinnedKey(_ id: UUID) -> String { "VaultPinnedPaths.\(id.uuidString)" }

    private func savePinned() {
        defaults.set(pinnedPaths, forKey: Self.pinnedKey(connection.id))
    }

    // MARK: Сеть и сон

    private func observeEnvironment() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                // Только возврат сети: каждое изменение интерфейса не должно перезапускать туннель.
                if satisfied, !self.wasPathSatisfied { self.connectivityMayHaveChanged() }
                self.wasPathSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.laceditor.vault-path"))
        pathMonitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connectivityMayHaveChanged() }
        }
        if let tunnel {
            tunnelObservation = tunnel.$state.removeDuplicates().sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let failure):
                    self.connectionIssue = failure.userMessage
                case .ready:
                    self.connectionIssue = nil
                    Task { await self.engine.connectivityMayHaveChanged() }
                default:
                    break
                }
            }
        }
    }

    private func stopEnvironment() {
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        tunnelObservation = nil
    }

    /// Пробуждение Mac, возврат сети, «Повторить»: туннель и движок проверяют связь сразу.
    func connectivityMayHaveChanged() {
        tunnel?.restartNow()
        Task { await engine.connectivityMayHaveChanged() }
        VaultRequestsHub.shared.connectionRestored(vaultID: connection.id)
    }
}
