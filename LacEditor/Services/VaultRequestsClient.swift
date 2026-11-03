import Foundation

/// Минимум API сервера, нужный движку запросов (для тестов подменяется).
protocol VaultRequestsAPI: Sendable {
    func submitRequest(requestID: String, text: String) async throws -> String
    func job(id: String) async throws -> VaultJob
    func downloadArtifact(path: String) async throws -> VaultArtifactData
}

struct VaultArtifactData: Equatable {
    var data: Data
    /// Из `Content-Disposition`, если сервер его прислал.
    var fileName: String?
}

extension VaultClient: VaultRequestsAPI {}

/// Файл запросов `Vaults/<vaultID>/requests.json`: текст мысли лежит на диске до отправки. Один владелец — `VaultRequestsClient`.
struct VaultRequestsStore {
    static let currentVersion = 1

    private struct FileContents: Codable {
        var version: Int
        var requests: [VaultPendingRequest]
    }

    let directory: URL

    init(directory: URL) { self.directory = directory }

    static func defaultDirectory(vaultID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(vaultID.uuidString, isDirectory: true)
    }

    var fileURL: URL { directory.appendingPathComponent("requests.json") }
    private var corruptURL: URL { directory.appendingPathComponent("requests.json.corrupt") }

    /// Повреждённый файл переименовывается в `.corrupt`, список пуст; файл новее известной версии — `.storageUnavailable`.
    func load() throws -> [VaultPendingRequest] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw VaultRequestError.storageUnavailable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let contents = try? decoder.decode(FileContents.self, from: data) else {
            try? manager.removeItem(at: corruptURL)
            do { try manager.moveItem(at: fileURL, to: corruptURL) } catch { throw VaultRequestError.storageUnavailable }
            return []
        }
        guard contents.version <= Self.currentVersion else { throw VaultRequestError.storageUnavailable }
        return contents.requests
    }

    /// Атомарно, права 0600; пустой список удаляет файл.
    func save(_ requests: [VaultPendingRequest]) throws {
        let manager = FileManager.default
        if requests.isEmpty {
            if manager.fileExists(atPath: fileURL.path) {
                do { try manager.removeItem(at: fileURL) } catch { throw VaultRequestError.storageUnavailable }
            }
            return
        }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let marker = directory.appendingPathComponent(".metadata_never_index")
            if !manager.fileExists(atPath: marker.path) { try Data().write(to: marker) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FileContents(version: Self.currentVersion, requests: requests))
            try data.write(to: fileURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw VaultRequestError.storageUnavailable
        }
    }

    /// «Удалить подключение»: запросы этого подключения больше некому отправлять.
    static func removeAll(vaultID: UUID) {
        let store = VaultRequestsStore(directory: defaultDirectory(vaultID: vaultID))
        try? FileManager.default.removeItem(at: store.fileURL)
        try? FileManager.default.removeItem(at: store.corruptURL)
    }
}

/// Движок запросов: запись на диск до отправки, повтор с тем же `request_id`, опрос с растущей паузой.
actor VaultRequestsClient {
    private struct Worker {
        var token: UUID
        var task: Task<Void, Never>
    }

    let vaultID: UUID
    private let store: VaultRequestsStore
    private let api: @Sendable () async throws -> any VaultRequestsAPI
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let makeRequestID: @Sendable () -> String
    private let now: @Sendable () -> Date

    private var records: [VaultPendingRequest] = []
    private var isLoaded = false
    private var phases: [String: VaultRequestPhase] = [:]
    private var inFlight: Set<String> = []
    private var workers: [String: Worker] = [:]
    private var sleepers: [UUID: Task<Void, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<VaultRequestUpdate>.Continuation] = [:]
    private var restoredGeneration = 0

    init(vaultID: UUID,
         store: VaultRequestsStore,
         api: @escaping @Sendable () async throws -> any VaultRequestsAPI,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
         now: @escaping @Sendable () -> Date = Date.init) {
        self.vaultID = vaultID
        self.store = store
        self.api = api
        self.sleep = sleep
        self.makeRequestID = makeRequestID
        self.now = now
    }

    /// 2, 4, 8, 16, 30, 30, …
    static func backoff(step: Int) -> TimeInterval {
        let steps: [TimeInterval] = [2, 4, 8, 16, 30]
        return steps[max(0, min(step, steps.count - 1))]
    }

    // MARK: Команды

    /// Проверяет текст, записывает запись на диск, запускает отправку в фоне и сразу возвращает `requestID`.
    func submit(text: String, kind: VaultRequestKind) throws -> String {
        let valid = try VaultRequestText.validated(text)
        try ensureLoaded()
        let record = VaultPendingRequest(requestID: makeRequestID(), text: valid, kind: kind, jobID: nil, createdAt: now())
        try store.save(records + [record])
        records.append(record)
        startWorker(record.requestID)
        return record.requestID
    }

    /// Читает `requests.json` и запускает по каждой записи: без `jobID` — отправку с тем же `request_id`, с `jobID` — только опрос.
    func resumePending() throws {
        try ensureLoaded()
        for record in records { startWorker(record.requestID) }
    }

    func pending() -> [VaultPendingRequest] { records }

    /// Есть ли запросы, которым нужен туннель: остановленные до исправления подключения его не держат.
    func hasActiveRequests() -> Bool {
        records.contains { record in
            if case .failed(.needsConnectionFix) = phases[record.requestID] { return false }
            return true
        }
    }

    /// Скачивание итогового файла задачи через тот же канал (туннель и токен подставляет `api`).
    func downloadArtifact(path: String) async throws -> VaultArtifactData {
        try await api().downloadArtifact(path: path)
    }

    /// Сначала приходят текущие фазы (replay), потом новые.
    func updates() -> AsyncStream<VaultRequestUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: VaultRequestUpdate.self, bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        for record in records {
            if let phase = phases[record.requestID] { continuation.yield(VaultRequestUpdate(request: record, phase: phase)) }
        }
        return stream
    }

    /// Связь вернулась: будит все паузы, рост паузы начинается с 2 с.
    func connectionRestored() {
        restoredGeneration += 1
        for task in sleepers.values { task.cancel() }
    }

    /// Возобновить запись, остановленную из-за `needsConnectionFix`.
    func retry(requestID: String) {
        guard records.contains(where: { $0.requestID == requestID }) else { return }
        startWorker(requestID)
    }

    /// Только пока запись ждёт связь, без `jobID` и без запроса в полёте.
    func cancelWaiting(requestID: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.requestID == requestID }),
              records[index].jobID == nil, phases[requestID] == .waitingForConnection,
              !inFlight.contains(requestID) else { return false }
        var updated = records
        updated.remove(at: index)
        guard (try? store.save(updated)) != nil else { return false }
        records = updated
        workers[requestID]?.task.cancel()
        workers[requestID] = nil
        phases[requestID] = nil
        return true
    }

    /// Останавливает фоновые задачи; записи остаются на диске.
    func stop() {
        for worker in workers.values { worker.task.cancel() }
        workers = [:]
        for task in sleepers.values { task.cancel() }
    }

    // MARK: Работник

    private func ensureLoaded() throws {
        guard !isLoaded else { return }
        records = try store.load()
        isLoaded = true
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func startWorker(_ requestID: String) {
        guard workers[requestID] == nil else { return }
        let token = UUID()
        let task = Task { await self.run(requestID, token: token) }
        workers[requestID] = Worker(token: token, task: task)
    }

    private func publish(_ requestID: String, _ phase: VaultRequestPhase, request: VaultPendingRequest? = nil) {
        guard let snapshot = request ?? records.first(where: { $0.requestID == requestID }) else { return }
        if phases[requestID] == phase { return }
        phases[requestID] = phase
        for continuation in subscribers.values { continuation.yield(VaultRequestUpdate(request: snapshot, phase: phase)) }
    }

    private func setJobID(_ jobID: String, for requestID: String) {
        guard let index = records.firstIndex(where: { $0.requestID == requestID }) else { return }
        records[index].jobID = jobID
        try? store.save(records)
    }

    /// Удаляет запись до публикации итога: повторный запуск не покажет результат дважды.
    private func removeRecord(_ requestID: String) -> VaultPendingRequest? {
        guard let index = records.firstIndex(where: { $0.requestID == requestID }) else { return nil }
        let removed = records.remove(at: index)
        try? store.save(records)
        return removed
    }

    private func pause(step: inout Int) async throws {
        let seconds = Self.backoff(step: step)
        step += 1
        let id = UUID()
        let sleeper = sleep
        let task = Task<Void, Never> {
            do { try await sleeper(seconds) } catch {}
        }
        sleepers[id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        sleepers[id] = nil
        try Task.checkCancellation()
    }

    private func run(_ requestID: String, token: UUID) async {
        defer { if workers[requestID]?.token == token { workers[requestID] = nil } }
        var step = 0
        var generation = restoredGeneration
        while !Task.isCancelled {
            guard let record = records.first(where: { $0.requestID == requestID }) else { return }
            if generation != restoredGeneration { generation = restoredGeneration; step = 0 }
            do {
                let client = try await api()
                if let jobID = record.jobID {
                    let job = try await client.job(id: jobID)
                    switch job.state {
                    case .queued:
                        publish(requestID, .queued)
                        try await pause(step: &step)
                    case .running:
                        publish(requestID, .running)
                        try await pause(step: &step)
                    case .completed:
                        guard let removed = removeRecord(requestID) else { return }
                        publish(requestID, .completed(VaultRequestResult(report: job.report ?? "", artifacts: job.artifactItems)),
                                request: removed)
                        return
                    case .failed:
                        guard let removed = removeRecord(requestID) else { return }
                        let failure: VaultRequestFailure = job.error == "interrupted"
                            ? .interrupted
                            : .serverError(job.error ?? job.report, canRetry: job.retryable != false)
                        publish(requestID, .failed(failure), request: removed)
                        return
                    }
                } else {
                    if phases[requestID] != .waitingForConnection { publish(requestID, .submitting) }
                    inFlight.insert(requestID)
                    defer { inFlight.remove(requestID) }
                    let jobID = try await client.submitRequest(requestID: record.requestID, text: record.text)
                    setJobID(jobID, for: requestID)
                    publish(requestID, .queued)
                    step = 0
                }
            } catch is CancellationError {
                return
            } catch {
                let failure = (error as? VaultClientError) ?? .offline
                if await handle(failure, requestID: requestID, polling: record.jobID != nil, step: &step) { return }
            }
        }
    }

    /// true — работник завершён.
    private func handle(_ error: VaultClientError, requestID: String, polling: Bool, step: inout Int) async -> Bool {
        switch error {
        case .offline, .timeout, .incompleteResponse, .invalidResponse:
            return await waitForConnection(requestID, step: &step)
        case .server(let status, _) where status >= 500 || status == 408 || status == 429:
            return await waitForConnection(requestID, step: &step)
        case .unauthorized, .forbidden, .insecureAddress:
            publish(requestID, .failed(.needsConnectionFix(error)))
            return true
        case .notFound where polling:
            if let removed = removeRecord(requestID) { publish(requestID, .failed(.jobLost), request: removed) }
            return true
        case .tooLarge where !polling, .server(400, _) where !polling, .server(409, _) where !polling:
            // Явный отказ сервера на отправку: только здесь запись удаляется, текст возвращается пользователю.
            guard let removed = removeRecord(requestID) else { return true }
            publish(requestID, .failed(.rejected(error)), request: removed)
            return true
        default:
            // Остальное (ошибка TLS, 4xx при опросе, неизвестное) запись не удаляет: повтор после исправления подключения.
            publish(requestID, .failed(.needsConnectionFix(error)))
            return true
        }
    }

    private func waitForConnection(_ requestID: String, step: inout Int) async -> Bool {
        publish(requestID, .waitingForConnection)
        do { try await pause(step: &step) } catch { return true }
        return false
    }
}
