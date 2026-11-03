import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LacEditor

/// Игрушечный сервер для отправки правок: GET/PUT файла с проверкой `If-Match`, закрытие конфликта, сбои сети.
private final class UploadFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var networkDown = false
    private var putStatus: Int?
    private var putReason: String?
    private var loseNextPutReply = false
    private var putDelay: TimeInterval = 0
    private(set) var putCount = 0
    private(set) var resolved: [String] = []

    func set(_ path: String, _ text: String) { lock.lock(); files[path] = Data(text.utf8); lock.unlock() }
    func text(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[path].flatMap { String(data: $0, encoding: .utf8) }
    }
    func set(networkDown value: Bool) { lock.lock(); networkDown = value; lock.unlock() }
    func set(putStatus value: Int?, reason: String? = nil) { lock.lock(); putStatus = value; putReason = reason; lock.unlock() }
    /// Запись проходит, но ответ клиенту теряется (ошибка сети).
    func set(loseNextPutReply value: Bool) { lock.lock(); loseNextPutReply = value; lock.unlock() }
    /// Сервер отвечает на PUT не сразу: можно успеть остановить движок во время запроса.
    func set(putDelay value: TimeInterval) { lock.lock(); putDelay = value; lock.unlock() }
    var puts: Int { lock.lock(); defer { lock.unlock() }; return putCount }
    var resolvedIDs: [String] { lock.lock(); defer { lock.unlock() }; return resolved }

    func install() {
        VaultStubProtocol.handler = { [self] request in
            lock.lock()
            let down = networkDown, forced = putStatus, reason = putReason
            lock.unlock()
            let path = request.url!.path
            if down, path != "/healthz" { throw URLError(.notConnectedToInternet) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let target = items.first { $0.name == "path" }?.value ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case (_, "/healthz"):
                return (200, [:], Data("{\"status\":\"ok\"}".utf8))
            case ("GET", "/v1/vault/file"):
                lock.lock(); let data = files[target]; lock.unlock()
                guard let data else { return (404, [:], Data("{\"error\":\"not found\"}".utf8)) }
                return (200, ["Content-Length": "\(data.count)", "ETag": "\"\(VaultClient.sha256Hex(data))\""], data)
            case ("PUT", "/v1/vault/file"):
                lock.lock(); putCount += 1; let pause = putDelay; lock.unlock()
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                if let forced {
                    let body = reason.map { "{\"error\":\"x\",\"reason\":\"\($0)\"}" } ?? "{\"error\":\"x\"}"
                    return (forced, [:], Data(body.utf8))
                }
                let body = Self.body(of: request)
                let ifMatch = (request.value(forHTTPHeaderField: "If-Match") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                lock.lock()
                let current = files[target]
                let currentTag = current.map { VaultClient.sha256Hex($0) }
                if currentTag != ifMatch {
                    lock.unlock()
                    let json = "{\"conflict_id\":\"c-\(putCount)\",\"current_etag\":\"\(currentTag ?? String(repeating: "0", count: 64))\"}"
                    return (409, [:], Data(json.utf8))
                }
                files[target] = body
                let lose = loseNextPutReply
                loseNextPutReply = false
                lock.unlock()
                if lose { throw URLError(.notConnectedToInternet) }
                return (200, [:], Data("{\"etag\":\"\(VaultClient.sha256Hex(body))\"}".utf8))
            case ("POST", _) where path.hasPrefix("/v1/vault/conflicts/"):
                lock.lock(); resolved.append(path); lock.unlock()
                return (200, [:], Data("{}".utf8))
            default:
                return (404, [:], Data())
            }
        }
    }

    private static func body(of request: URLRequest) -> Data {
        // Тело PUT запоминает `VaultStubProtocol`; последний PUT — наш.
        let all = zip(VaultStubProtocol.requests, VaultStubProtocol.bodies).filter { $0.0.httpMethod == "PUT" }
        return all.last?.1 ?? Data()
    }
}

/// Хозяин вкладок для тестов: пишет файл сам (как редактор) или отвечает заданным результатом.
@MainActor
private final class UploadFakeHost: VaultUploadHost {
    var store: VaultStateStore
    var forcedResult: VaultApplyResult?
    private(set) var applied: [String] = []
    private(set) var rewritten: [String] = []

    init(store: VaultStateStore) { self.store = store }

    func applyMergedText(_ text: String, serverPath: String, expectedFileText: String) async -> VaultApplyResult {
        if let forcedResult { return forcedResult }
        guard let current = try? store.readNote(serverPath: serverPath), String(data: current, encoding: .utf8) == expectedFileText else {
            return .busy
        }
        _ = try? store.writeNote(Data(text.utf8), serverPath: serverPath)
        applied.append(text)
        return .applied
    }

    func fileRewritten(serverPath: String) async { rewritten.append(serverPath) }
}

final class VaultUploadTests: XCTestCase {
    private var tmp: URL!
    private var server: UploadFakeServer!
    private var store: VaultStateStore!
    private var snapshots: DocumentSnapshotStore!
    private var engines: [VaultSyncEngine] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vault-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        VaultStubProtocol.reset()
        server = UploadFakeServer()
        server.install()
        store = VaultStateStore(vaultID: UUID(), root: tmp.appendingPathComponent("vault", isDirectory: true))
        snapshots = DocumentSnapshotStore(baseDirectory: tmp.appendingPathComponent("Snapshots", isDirectory: true))
    }

    override func tearDownWithError() throws {
        for engine in engines { Task { await engine.shutdown() } }
        engines = []
        VaultStubProtocol.reset()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeEngine() -> VaultSyncEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VaultStubProtocol.self]
        let client = VaultClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-token", session: URLSession(configuration: configuration))
        var settings = VaultSyncConfiguration()
        settings.failureThreshold = 2
        settings.probeDelays = [0.02]
        settings.uploadDebounce = 0.01
        settings.uploadRetryDelays = [0.05]
        settings.hostBusyDelay = 0.05
        settings.mergePause = 0.2
        let engine = VaultSyncEngine(connection: VaultConnection(name: "test"), client: client, store: store,
                                     configuration: settings, snapshotStore: snapshots)
        engines.append(engine)
        return engine
    }

    /// Открывает заметку с серверным текстом `text` и возвращает движок.
    private func openNote(_ path: String = "a.md", text: String) async throws -> VaultSyncEngine {
        server.set(path, text)
        let engine = makeEngine()
        _ = try await engine.open(serverPath: path)
        return engine
    }

    private func edit(_ path: String = "a.md", to text: String) throws {
        _ = try store.writeNote(Data(text.utf8), serverPath: path)
    }

    private func fileText(_ path: String = "a.md") -> String? {
        (try? store.readNote(serverPath: path)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
    }

    private func waitFor(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    // MARK: Обычная отправка

    func testSaveIsSentWithIfMatchAndBaseMoves() async throws {
        let engine = try await openNote(text: "один\n")
        let oldETag = VaultClient.sha256Hex(Data("один\n".utf8))
        try edit(to: "один\nдва\n")
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(server.text("a.md"), "один\nдва\n")
        let put = try XCTUnwrap(VaultStubProtocol.requests.last { $0.httpMethod == "PUT" })
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-Match"), "\"\(oldETag)\"")
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.state, .synced)
        XCTAssertEqual(record?.baseETag, VaultClient.sha256Hex(Data("один\nдва\n".utf8)))
        XCTAssertEqual(try store.readBase(serverPath: "a.md"), Data("один\nдва\n".utf8))
    }

    func testSentNoteIsRecheckedByContentBecauseModifiedTimeIsUnknown() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        _ = await engine.uploadNow(serverPath: "a.md")
        let marked = await engine.needsRecheck.contains("a.md")
        XCTAssertTrue(marked)
    }

    func testQueuedSaveIsSentByTimerAfterDebounce() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        await engine.enqueueUpload(serverPath: "a.md")
        let state = await engine.records()["a.md"]?.state
        XCTAssertTrue(state == .modified || state == .uploading)
        let sent = await waitFor { self.server.text("a.md") == "a\nb\n" }
        XCTAssertTrue(sent)
    }

    func testTextEqualToBaseIsNotSent() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        await engine.enqueueUpload(serverPath: "a.md")
        try edit(to: "a\n")
        await engine.enqueueUpload(serverPath: "a.md")
        let state = await engine.records()["a.md"]?.state
        XCTAssertEqual(state, .synced)
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .alreadySynced)
        XCTAssertEqual(server.puts, 0)
    }

    // MARK: Объединение при 409

    func testServerChangedElsewhereIsMergedAndSentOnce() async throws {
        let engine = try await openNote(text: "1\n2\n3\n4\n5\n")
        let host = await MainActor.run { UploadFakeHost(store: store) }
        await engine.setUploadHost(host)
        server.set("a.md", "1\n2\n3\n4\nсервер\n")
        try edit(to: "моё\n2\n3\n4\n5\n")
        let log = EventBox()
        let stream = engine.events
        Task { for await event in stream { log.add(event) } }

        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(server.text("a.md"), "моё\n2\n3\n4\nсервер\n")
        XCTAssertEqual(fileText(), "моё\n2\n3\n4\nсервер\n")
        XCTAssertEqual(server.puts, 2)
        XCTAssertEqual(server.resolvedIDs.count, 1)
        let ok = await waitFor { log.all.contains(.merged(serverPath: "a.md")) }
        XCTAssertTrue(ok)
        let snapshotsList = snapshots.list(location: .file(path: try XCTUnwrap(store.noteURL(for: "a.md")).standardizedFileURL.path))
        XCTAssertFalse(snapshotsList.isEmpty)
    }

    func testOverlappingEditsBecomeConflictAndFileStaysMine() async throws {
        let engine = try await openNote(text: "общая\n")
        server.set("a.md", "серверная\n")
        try edit(to: "моя\n")
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(fileText(), "моя\n")
        XCTAssertEqual(server.text("a.md"), "серверная\n")
        let state = await engine.records()["a.md"]?.state
        XCTAssertEqual(state, .conflict)
        let conflicts = await engine.conflictRecords()
        XCTAssertEqual(conflicts.map(\.serverPath), ["a.md"])
    }

    func testLostReplyIsRecognisedAsOwnWrite() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        server.set(loseNextPutReply: true)
        let first = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(first, .offline)
        server.set(networkDown: false)
        let second = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(second, .sent)
        XCTAssertEqual(server.text("a.md"), "a\nb\n")
        let state = await engine.records()["a.md"]?.state
        XCTAssertEqual(state, .synced)
    }

    func testBusyHostDelaysMergeWithoutLosingText() async throws {
        let engine = try await openNote(text: "1\n2\n3\n4\n5\n")
        let host = await MainActor.run { UploadFakeHost(store: store) }
        await MainActor.run { host.forcedResult = .busy }
        await engine.setUploadHost(host)
        server.set("a.md", "1\n2\n3\n4\nсервер\n")
        try edit(to: "моё\n2\n3\n4\n5\n")
        let first = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(first, .retryLater)
        XCTAssertEqual(fileText(), "моё\n2\n3\n4\n5\n")
        await MainActor.run { host.forcedResult = nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        // За паузу цикл мог уже отправить сам: нужен итог «отправлено», а не конкретный ответ.
        let second = await engine.uploadNow(serverPath: "a.md")
        XCTAssertTrue(second == .sent || second == .alreadySynced)
        XCTAssertEqual(server.text("a.md"), "моё\n2\n3\n4\nсервер\n")
    }

    // MARK: Конфликт

    func testResolveConflictSendsChosenText() async throws {
        let engine = try await openNote(text: "общая\n")
        server.set("a.md", "серверная\n")
        try edit(to: "моя\n")
        _ = await engine.uploadNow(serverPath: "a.md")
        let load = try await engine.conflictContext(serverPath: "a.md")
        guard case .conflict(let context) = load else { return XCTFail("ожидался конфликт") }
        XCTAssertEqual(context.mine, "моя\n")
        XCTAssertEqual(context.server, "серверная\n")
        XCTAssertEqual(context.base, "общая\n")
        let saved = await engine.saveConflictSnapshots(serverPath: "a.md", context: context)
        XCTAssertTrue(saved)
        var selection = VaultConflictSelection(conflict: context.conflict)
        let id = try XCTUnwrap(selection.firstUnresolved)
        selection.choose(.server, for: id)
        let text = try XCTUnwrap(selection.resolvedText)
        try edit(to: text)
        // Выбрана версия сервера: после сдвига основы текст равен ей, отправлять нечего.
        let outcome = await engine.resolveConflict(serverPath: "a.md", text: text, serverETag: context.serverETag)
        XCTAssertEqual(outcome, .alreadySynced)
        XCTAssertEqual(server.text("a.md"), "серверная\n")
        let state = await engine.records()["a.md"]?.state
        XCTAssertEqual(state, .synced)
    }

    func testResolveConflictRefusesIfFileChanged() async throws {
        let engine = try await openNote(text: "общая\n")
        server.set("a.md", "серверная\n")
        try edit(to: "моя\n")
        _ = await engine.uploadNow(serverPath: "a.md")
        let load = try await engine.conflictContext(serverPath: "a.md")
        guard case .conflict(let context) = load else { return XCTFail("ожидался конфликт") }
        try edit(to: "ещё правка\n")
        let outcome = await engine.resolveConflict(serverPath: "a.md", text: "серверная\n", serverETag: context.serverETag)
        XCTAssertEqual(outcome, .fileChanged)
        XCTAssertEqual(server.text("a.md"), "серверная\n")
    }

    // MARK: Сбои

    func testOfflineKeepsNoteQueuedThenSendsAfterReconnect() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        server.set(networkDown: true)
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .offline)
        let pending = await engine.pendingUploads()
        XCTAssertEqual(pending.map(\.serverPath), ["a.md"])
        server.set(networkDown: false)
        let summary = await engine.uploadPending(timeout: 3)
        XCTAssertTrue(summary.remaining.isEmpty)
        XCTAssertEqual(server.text("a.md"), "a\nb\n")
    }

    func testRejectionStopsRetriesAndIsClearedByNewEdit() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        server.set(putStatus: 413)
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .issue(.tooLarge))
        let putsAfterFirst = server.puts
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.puts, putsAfterFirst)
        let issue = await engine.records()["a.md"]?.uploadIssue
        XCTAssertEqual(issue, .tooLarge)
        server.set(putStatus: nil)
        try edit(to: "a\nb\nc\n")
        await engine.enqueueUpload(serverPath: "a.md")
        let cleared = await engine.records()["a.md"]?.uploadIssue
        XCTAssertNil(cleared)
        let sent = await waitFor { self.server.text("a.md") == "a\nb\nc\n" }
        XCTAssertTrue(sent)
    }

    func testNotUTF8ReasonMapsToItsOwnIssue() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        server.set(putStatus: 422, reason: "not_utf8")
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .issue(.notUTF8))
    }

    func testUnauthorizedPausesWholeQueue() async throws {
        let engine = try await openNote(text: "a\n")
        server.set(putStatus: 401)
        try edit(to: "a\nb\n")
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .issue(.unauthorized))
        let putsAfter = server.puts
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(server.puts, putsAfter)
    }

    func testUnauthorizedIsNotStoredAndQueueGoesAfterTokenFix() async throws {
        let engine = try await openNote(text: "a\n")
        server.set(putStatus: 401)
        try edit(to: "a\nb\n")
        _ = await engine.uploadNow(serverPath: "a.md")
        let stored = await engine.records()["a.md"]?.uploadIssue
        XCTAssertNil(stored)
        server.set(putStatus: nil)
        let summary = await engine.uploadPending(timeout: 3)
        XCTAssertTrue(summary.remaining.isEmpty)
        XCTAssertEqual(server.text("a.md"), "a\nb\n")
    }

    func testAuthPauseIsAnnouncedAndClearedBySuccessfulResponse() async throws {
        let engine = try await openNote(text: "a\n")
        let events = EventBox()
        let stream = engine.events
        let listener = Task { for await event in stream { events.add(event) } }
        server.set(putStatus: 401)
        try edit(to: "a\nb\n")
        _ = await engine.uploadNow(serverPath: "a.md")
        let paused = await waitFor { events.all.contains(.authPaused(true)) }
        XCTAssertTrue(paused)
        // Токен поправили: любой успешный ответ сервера снимает паузу, очередь уходит сама.
        server.set(putStatus: nil)
        try await engine.perform { try await engine.client.health() }
        let cleared = await waitFor { events.all.contains(.authPaused(false)) }
        XCTAssertTrue(cleared)
        let sent = await waitFor { self.server.text("a.md") == "a\nb\n" }
        XCTAssertTrue(sent)
        listener.cancel()
    }

    func testTooLargeLocalTextIsRejectedWithoutRequest() async throws {
        let engine = try await openNote(text: "a\n")
        let big = String(repeating: "x", count: VaultSyncEngine.maxUploadBytes + 1)
        try edit(to: big)
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .issue(.tooLarge))
        XCTAssertEqual(server.puts, 0)
        let issue = await engine.records()["a.md"]?.uploadIssue
        XCTAssertEqual(issue, .tooLarge)
    }

    func testHostSaysAppliedButFileIsNotMergedKeepsText() async throws {
        let engine = try await openNote(text: "1\n2\n3\n4\n5\n")
        let host = await MainActor.run { UploadFakeHost(store: store) }
        await MainActor.run { host.forcedResult = .applied }
        await engine.setUploadHost(host)
        server.set("a.md", "1\n2\n3\n4\nсервер\n")
        try edit(to: "моё\n2\n3\n4\n5\n")
        let outcome = await engine.uploadNow(serverPath: "a.md")
        XCTAssertEqual(outcome, .retryLater)
        XCTAssertEqual(fileText(), "моё\n2\n3\n4\n5\n")
        XCTAssertEqual(server.text("a.md"), "1\n2\n3\n4\nсервер\n")
    }

    func testCleanupKeepsSyncedRecordWhoseFileDiffersFromBase() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nправка\n")
        await engine.cleanupAfterCrash(restoredPaths: [])
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.state, .modified)
        XCTAssertEqual(fileText(), "a\nправка\n")
    }

    // MARK: Остановка во время запроса

    func testShutdownDuringRequestWritesNothing() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        server.set(putDelay: 0.4)
        let upload = Task { await engine.uploadNow(serverPath: "a.md") }
        let started = await waitFor { self.server.puts == 1 }
        XCTAssertTrue(started)
        await engine.shutdown()
        _ = await upload.value
        try await Task.sleep(nanoseconds: 100_000_000)
        // Ответ выброшен: база прежняя, запись не стала «синхронизировано», файл на месте.
        XCTAssertEqual(try store.readBase(serverPath: "a.md"), Data("a\n".utf8))
        let record = await engine.records()["a.md"]
        XCTAssertNotEqual(record?.state, .synced)
        XCTAssertEqual(record?.baseETag, VaultClient.sha256Hex(Data("a\n".utf8)))
        XCTAssertEqual(fileText(), "a\nb\n")
    }

    // MARK: Отмена правок

    func testDiscardForClosedNoteRemovesItAndOpenNoteReturnsBase() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        server.set(networkDown: true)
        _ = await engine.uploadNow(serverPath: "a.md")
        let open = await engine.discardLocalChanges(serverPath: "a.md")
        XCTAssertEqual(open, .revertTo("a\n"))
        let missing = await engine.discardLocalChanges(serverPath: "nope.md")
        XCTAssertEqual(missing, .notFound)
        let closed = await engine.discardLocalChanges(serverPath: "a.md", tabIsClosing: true)
        XCTAssertEqual(closed, .removed)
        let records = await engine.records()
        XCTAssertNil(records["a.md"])
        XCTAssertNil(fileText())
    }

    func testInterruptedUploadBecomesModifiedAfterRestart() async throws {
        let engine = try await openNote(text: "a\n")
        try edit(to: "a\nb\n")
        server.set(networkDown: true)
        _ = await engine.uploadNow(serverPath: "a.md")
        var loaded = try store.load()
        var record = try XCTUnwrap(loaded["a.md"])
        record.state = .uploading
        loaded["a.md"] = record
        try store.save(loaded)
        // Новый движок читает состояние с диска; при старте сессии `cleanupAfterCrash` зовёт нормализацию.
        server.set(networkDown: false)
        let second = makeEngine()
        _ = await second.pendingUploads()
        await second.normalizeInterruptedUploads()
        let pending = await second.pendingUploads()
        XCTAssertEqual(pending.map(\.state), [.modified])
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [VaultSyncEvent] = []
    func add(_ event: VaultSyncEvent) { lock.lock(); items.append(event); lock.unlock() }
    var all: [VaultSyncEvent] { lock.lock(); defer { lock.unlock() }; return items }
}
