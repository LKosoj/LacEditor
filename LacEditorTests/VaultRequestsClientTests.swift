import Foundation
import XCTest
@testable import LacEditor

/// Заглушка сервера: идемпотентна по `request_id`, сценарии ответов задаются списками.
final class FakeRequestsAPI: VaultRequestsAPI, @unchecked Sendable {
    enum SubmitStep { case ok, fail(VaultClientError), acceptThenFail(VaultClientError) }

    private let lock = NSLock()
    private var submitSteps: [SubmitStep]
    private var jobSteps: [Result<VaultJob, VaultClientError>]
    private var server: [String: (text: String, jobID: String)] = [:]
    private(set) var submitCalls: [(requestID: String, text: String)] = []
    private(set) var jobCalls: [String] = []
    var onSubmit: (@Sendable (String) -> Void)?

    init(submit: [SubmitStep] = [], jobs: [Result<VaultJob, VaultClientError>] = []) {
        submitSteps = submit
        jobSteps = jobs
    }

    var serverJobCount: Int { lock.withLock { server.count } }
    var submitCount: Int { lock.withLock { submitCalls.count } }
    var jobCount: Int { lock.withLock { jobCalls.count } }
    var submitRequestIDs: [String] { lock.withLock { submitCalls.map(\.requestID) } }
    var polledJobs: [String] { lock.withLock { jobCalls } }

    func submitRequest(requestID: String, text: String) async throws -> String {
        onSubmit?(requestID)
        let step: SubmitStep = lock.withLock {
            submitCalls.append((requestID, text))
            return submitSteps.isEmpty ? .ok : submitSteps.removeFirst()
        }
        func accept() throws -> String {
            try lock.withLock {
                if let known = server[requestID] {
                    guard known.text == text else { throw VaultClientError.server(status: 409, message: nil) }
                    return known.jobID
                }
                let jobID = "job-\(requestID)"
                server[requestID] = (text, jobID)
                return jobID
            }
        }
        switch step {
        case .ok: return try accept()
        case .fail(let error): throw error
        case .acceptThenFail(let error): _ = try accept(); throw error
        }
    }

    func job(id: String) async throws -> VaultJob {
        let step: Result<VaultJob, VaultClientError> = lock.withLock {
            jobCalls.append(id)
            if jobSteps.count > 1 { return jobSteps.removeFirst() }
            return jobSteps.first ?? .success(VaultJob(state: .completed, report: "ok", artifacts: []))
        }
        return try step.get()
    }

    func downloadArtifact(path: String) async throws -> VaultArtifactData {
        VaultArtifactData(data: Data(), fileName: nil)
    }
}

/// Паузы записываются; `hangFirst` подвешивает первые N пауз до отмены (пробуждения).
final class FakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var pausesStorage: [TimeInterval] = []
    private var hangLeft: Int

    init(hangFirst: Int = 0) { hangLeft = hangFirst }

    var pauses: [TimeInterval] { lock.withLock { pausesStorage } }

    func sleep(_ seconds: TimeInterval) async throws {
        let hang: Bool = lock.withLock {
            pausesStorage.append(seconds)
            if hangLeft > 0 { hangLeft -= 1; return true }
            return false
        }
        if hang { try await Task.sleep(for: .seconds(60)) } else { await Task.yield() }
    }
}

final class VaultRequestsClientTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-requests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var requestsFile: URL { directory.appendingPathComponent("requests.json") }

    private func makeClient(_ api: FakeRequestsAPI, sleeper: FakeSleeper = FakeSleeper(), directory: URL? = nil) -> VaultRequestsClient {
        let counter = Counter()
        return VaultRequestsClient(vaultID: UUID(), store: VaultRequestsStore(directory: directory ?? self.directory),
                                   api: { api }, sleep: { try await sleeper.sleep($0) },
                                   makeRequestID: { "req-\(counter.next())" })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [VaultRequestUpdate] = []
        func add(_ item: VaultRequestUpdate) { lock.withLock { items.append(item) } }
        var all: [VaultRequestUpdate] { lock.withLock { items } }
    }

    /// Читает обновления, пока `done` не вернёт true (или 5 с).
    private func collect(_ stream: AsyncStream<VaultRequestUpdate>, until done: @escaping @Sendable ([VaultRequestUpdate]) -> Bool) async -> [VaultRequestUpdate] {
        let box = Box()
        let reader = Task {
            for await update in stream {
                box.add(update)
                if done(box.all) { return }
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            reader.cancel()
        }
        await reader.value
        timeout.cancel()
        return box.all
    }

    private func waitFor(_ condition: @escaping () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func running(_ report: String? = nil) -> Result<VaultJob, VaultClientError> {
        .success(VaultJob(state: .running, report: nil, artifacts: []))
    }

    private func completed(_ report: String = "✓ Сохранено") -> Result<VaultJob, VaultClientError> {
        .success(VaultJob(state: .completed, report: report, artifacts: []))
    }

    private func isTerminal(_ updates: [VaultRequestUpdate]) -> Bool { updates.last?.phase.isTerminal == true }

    // MARK: Тесты

    func testRecordIsOnDiskBeforeFirstSend() async throws {
        let api = FakeRequestsAPI(jobs: [completed()])
        let seen = Box()
        let file = requestsFile
        api.onSubmit = { _ in
            if let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) {
                seen.add(VaultRequestUpdate(request: VaultPendingRequest(requestID: text, text: "", kind: .capture, createdAt: Date()), phase: .submitting))
            }
        }
        let client = makeClient(api)
        let stream = await client.updates()
        let id = try await client.submit(text: "  мысль  ", kind: .capture)
        _ = await collect(stream) { self.isTerminal($0) }
        let onDisk = try XCTUnwrap(seen.all.first?.request.requestID)
        XCTAssertTrue(onDisk.contains("\"requestID\" : \"\(id)\""))
        XCTAssertTrue(onDisk.contains("\"text\" : \"мысль\""))
        XCTAssertTrue(onDisk.contains("\"kind\" : \"capture\""))
        XCTAssertFalse(onDisk.contains("jobID"))
    }

    func testSameRequestIDOnEveryRetry() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.offline), .fail(.timeout), .ok], jobs: [running()])
        let client = makeClient(api)
        let stream = await client.updates()
        let id = try await client.submit(text: "мысль", kind: .capture)
        let updates = await collect(stream) { $0.last?.phase == .queued }
        XCTAssertEqual(api.submitRequestIDs, [id, id, id])
        XCTAssertEqual(updates.map(\.phase), [.submitting, .waitingForConnection, .queued])
        let pending = await client.pending()
        XCTAssertEqual(pending.first?.jobID, "job-\(id)")
        await client.stop()
    }

    func testResponseLostAfterServerAccepted() async throws {
        let api = FakeRequestsAPI(submit: [.acceptThenFail(.timeout), .ok], jobs: [completed()])
        let client = makeClient(api)
        let stream = await client.updates()
        let id = try await client.submit(text: "мысль", kind: .capture)
        let updates = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(api.serverJobCount, 1)
        XCTAssertEqual(api.polledJobs.first, "job-\(id)")
        guard case .completed = updates.last?.phase else { return XCTFail("нет completed") }
    }

    func testPollingBackoffGrowsAndCaps() async throws {
        XCTAssertEqual((0..<7).map { VaultRequestsClient.backoff(step: $0) }, [2, 4, 8, 16, 30, 30, 30])
        let sleeper = FakeSleeper()
        let api = FakeRequestsAPI(jobs: Array(repeating: running(), count: 6) + [completed()])
        let client = makeClient(api, sleeper: sleeper)
        let stream = await client.updates()
        _ = try await client.submit(text: "вопрос", kind: .ask)
        _ = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(sleeper.pauses, [2, 4, 8, 16, 30, 30])
    }

    func testConnectionRestoredWakesImmediatelyAndResetsBackoff() async throws {
        let sleeper = FakeSleeper(hangFirst: 2)
        let api = FakeRequestsAPI(jobs: [running(), running(), running(), completed()])
        let client = makeClient(api, sleeper: sleeper)
        let stream = await client.updates()
        _ = try await client.submit(text: "вопрос", kind: .ask)
        await waitFor { sleeper.pauses.count == 1 }
        XCTAssertEqual(sleeper.pauses, [2])
        await client.connectionRestored()
        await waitFor { sleeper.pauses.count == 2 }
        // вторая пауза тоже подвешена: будим ещё раз, потом пауза снова должна быть 2 с
        XCTAssertEqual(sleeper.pauses, [2, 2])
        await client.connectionRestored()
        _ = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(sleeper.pauses, [2, 2, 2])
    }

    func testCompletedRemovesRecordBeforePublishing() async throws {
        let item = VaultJobArtifact(id: "artifact-1", name: "r.md", mimeType: "text/markdown", downloadPath: "/v1/jobs/j/artifacts/artifact-1")
        let api = FakeRequestsAPI(jobs: [.success(VaultJob(state: .completed, report: "готово", artifacts: [item.downloadPath], artifactItems: [item]))])
        let client = makeClient(api)
        let stream = await client.updates()
        _ = try await client.submit(text: "вопрос", kind: .ask)
        var fileExistedAtCompletion = true
        for await update in stream {
            if case .completed(let result) = update.phase {
                fileExistedAtCompletion = FileManager.default.fileExists(atPath: requestsFile.path)
                XCTAssertEqual(result.report, "готово")
                XCTAssertEqual(result.artifacts, [item])
                break
            }
        }
        XCTAssertFalse(fileExistedAtCompletion)
    }

    func testFailedInterruptedNoAutoRetry() async throws {
        let api = FakeRequestsAPI(jobs: [.success(VaultJob(state: .failed, report: nil, artifacts: [], error: "interrupted", retryable: false))])
        let client = makeClient(api)
        let stream = await client.updates()
        _ = try await client.submit(text: "мысль", kind: .capture)
        let updates = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(updates.last?.phase, .failed(.interrupted))
        XCTAssertEqual(api.submitCount, 1)
        let pending = await client.pending()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(VaultRequestFailure.interrupted.canRetry)
        XCTAssertEqual(VaultRequestFailure.interrupted.userMessage, L10n.tr("服务器中断了任务；记录可能已保存，请检查每日笔记"))
    }

    func testFailedPlainIsRetryableUnlessFalse() async throws {
        for (retryable, expected) in [(nil, true), (true, true), (false, false)] as [(Bool?, Bool)] {
            let api = FakeRequestsAPI(jobs: [.success(VaultJob(state: .failed, report: nil, artifacts: [], error: "boom", retryable: retryable))])
            let client = makeClient(api, directory: directory.appendingPathComponent("r-\(String(describing: retryable))"))
            let stream = await client.updates()
            _ = try await client.submit(text: "вопрос", kind: .ask)
            let updates = await collect(stream) { self.isTerminal($0) }
            XCTAssertEqual(updates.last?.phase, .failed(.serverError("boom", canRetry: expected)))
            let pending = await client.pending()
            XCTAssertTrue(pending.isEmpty)
        }
    }

    func testResumePendingAfterRestart() async throws {
        let store = VaultRequestsStore(directory: directory)
        let a = VaultPendingRequest(requestID: "a", text: "первая", kind: .capture, jobID: nil, createdAt: Date())
        let b = VaultPendingRequest(requestID: "b", text: "вторая", kind: .ask, jobID: "job-b", createdAt: Date())
        try store.save([a, b])
        let api = FakeRequestsAPI(jobs: [completed()])
        let client = makeClient(api)
        let stream = await client.updates()
        try await client.resumePending()
        let updates = await collect(stream) { $0.filter { $0.phase.isTerminal }.count == 2 }
        XCTAssertEqual(api.submitRequestIDs, ["a"])
        XCTAssertTrue(api.polledJobs.contains("job-b"))
        XCTAssertEqual(updates.filter { $0.phase.isTerminal }.count, 2)
    }

    func testRestartAfterAckDoesNotResubmit() async throws {
        let first = FakeRequestsAPI(jobs: [running()])
        let sleeper = FakeSleeper(hangFirst: 100)
        let client = makeClient(first, sleeper: sleeper)
        let id = try await client.submit(text: "вопрос", kind: .ask)
        await waitFor { !sleeper.pauses.isEmpty }
        await client.stop()
        let saved = try VaultRequestsStore(directory: directory).load()
        XCTAssertEqual(saved.first?.jobID, "job-\(id)")
        let second = FakeRequestsAPI(jobs: [completed()])
        let restarted = makeClient(second)
        let stream = await restarted.updates()
        try await restarted.resumePending()
        _ = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(second.submitCount, 0)
    }

    func testRejectedRemovesRecordAndCarriesText() async throws {
        for error in [VaultClientError.server(status: 400, message: "bad"), .tooLarge] {
            let api = FakeRequestsAPI(submit: [.fail(error)])
            let client = makeClient(api, directory: directory.appendingPathComponent("rej-\(error.userMessage.count)"))
            let stream = await client.updates()
            _ = try await client.submit(text: "моя мысль", kind: .capture)
            let updates = await collect(stream) { self.isTerminal($0) }
            XCTAssertEqual(updates.last?.phase, .failed(.rejected(error)))
            XCTAssertEqual(updates.last?.request.text, "моя мысль")
            let pending = await client.pending()
            XCTAssertTrue(pending.isEmpty)
        }
    }

    func testUnauthorizedKeepsRecordAndStops() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.unauthorized), .ok], jobs: [running()])
        let sleeper = FakeSleeper(hangFirst: 100)
        let client = makeClient(api, sleeper: sleeper)
        let stream = await client.updates()
        let id = try await client.submit(text: "мысль", kind: .capture)
        _ = await collect(stream) { $0.last?.phase == .failed(.needsConnectionFix(.unauthorized)) }
        let pending = await client.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(api.submitCount, 1)
        XCTAssertTrue(sleeper.pauses.isEmpty)
        let stream2 = await client.updates()
        await client.retry(requestID: id)
        _ = await collect(stream2) { $0.last?.phase == .queued }
        XCTAssertEqual(api.submitRequestIDs, [id, id])
        await client.stop()
    }

    func testSecureConnectionFailureKeepsRecordAndStops() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.secureConnectionFailed)])
        let sleeper = FakeSleeper(hangFirst: 100)
        let client = makeClient(api, sleeper: sleeper)
        let stream = await client.updates()
        _ = try await client.submit(text: "мысль", kind: .capture)
        let updates = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(updates.last?.phase, .failed(.needsConnectionFix(.secureConnectionFailed)))
        let pending = await client.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(api.submitCount, 1)
        XCTAssertTrue(sleeper.pauses.isEmpty)
        let active = await client.hasActiveRequests()
        XCTAssertFalse(active)
    }

    func testClientErrorWhilePollingKeepsRecord() async throws {
        for error in [VaultClientError.server(status: 400, message: nil), .tooLarge, .preconditionRequired] {
            let api = FakeRequestsAPI(jobs: [.failure(error)])
            let client = makeClient(api, directory: directory.appendingPathComponent("poll-\(error.userMessage.count)"))
            let stream = await client.updates()
            _ = try await client.submit(text: "вопрос", kind: .ask)
            let updates = await collect(stream) { self.isTerminal($0) }
            XCTAssertEqual(updates.last?.phase, .failed(.needsConnectionFix(error)))
            let pending = await client.pending()
            XCTAssertEqual(pending.count, 1)
        }
    }

    func testUnknownSubmitErrorKeepsRecord() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.preconditionRequired)])
        let client = makeClient(api)
        let stream = await client.updates()
        _ = try await client.submit(text: "мысль", kind: .capture)
        _ = await collect(stream) { self.isTerminal($0) }
        let pending = await client.pending()
        XCTAssertEqual(pending.count, 1)
    }

    func testTimeoutAndTooManyRequestsAreRetried() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.server(status: 408, message: nil)), .fail(.server(status: 429, message: nil)), .ok],
                                  jobs: [completed()])
        let client = makeClient(api)
        let stream = await client.updates()
        _ = try await client.submit(text: "мысль", kind: .capture)
        let updates = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(api.submitCount, 3)
        if case .completed = updates.last?.phase {} else { XCTFail("ожидалось завершение") }
    }

    func testStoppedMessageDependsOnError() {
        let unknown = VaultRequestFailure.needsConnectionFix(.server(status: 418, message: nil)).userMessage
        XCTAssertFalse(unknown.isEmpty)
        XCTAssertNotEqual(unknown, VaultRequestFailure.needsConnectionFix(.unauthorized).userMessage)
    }

    func testCancelledWaitingRequestIsNeverSent() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.offline)])
        let client = makeClient(api, sleeper: FakeSleeper(hangFirst: 100))
        let stream = await client.updates()
        let id = try await client.submit(text: "мысль", kind: .capture)
        _ = await collect(stream) { $0.last?.phase == .waitingForConnection }
        let cancelled = await client.cancelWaiting(requestID: id)
        XCTAssertTrue(cancelled)
        await client.connectionRestored()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(api.submitCount, 1)
        let pending = await client.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testJobNotFoundIsReportedNotResubmitted() async throws {
        let api = FakeRequestsAPI(jobs: [.failure(.notFound)])
        let client = makeClient(api)
        let stream = await client.updates()
        _ = try await client.submit(text: "мысль", kind: .capture)
        let updates = await collect(stream) { self.isTerminal($0) }
        XCTAssertEqual(updates.last?.phase, .failed(.jobLost))
        XCTAssertEqual(api.submitCount, 1)
        let pending = await client.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testTextValidation() async throws {
        let client = makeClient(FakeRequestsAPI())
        func failure(_ text: String) async -> VaultRequestError? {
            do { _ = try await client.submit(text: text, kind: .capture); return nil } catch { return error as? VaultRequestError }
        }
        let empty = await failure("  \n ")
        XCTAssertEqual(empty, .empty)
        let tooManyScalars = await failure(String(repeating: "a", count: 100_001))
        XCTAssertEqual(tooManyScalars, .tooLong)
        let tooManyBytes = await failure(String(repeating: "😀", count: 70_000))
        XCTAssertEqual(tooManyBytes, .tooLong)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestsFile.path))
        XCTAssertEqual(try VaultRequestText.validated("  x \n"), "x")
    }

    func testStorageFailureDoesNotSend() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        let api = FakeRequestsAPI()
        let client = makeClient(api, directory: blocker.appendingPathComponent("sub"))
        do {
            _ = try await client.submit(text: "мысль", kind: .capture)
            XCTFail("должна быть ошибка")
        } catch {
            XCTAssertEqual(error as? VaultRequestError, .storageUnavailable)
        }
        XCTAssertEqual(api.submitCount, 0)
    }

    func testCorruptFileIsMovedAside() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("мусор".utf8).write(to: requestsFile)
        let api = FakeRequestsAPI(jobs: [running()])
        let client = makeClient(api, sleeper: FakeSleeper(hangFirst: 100))
        _ = try await client.submit(text: "мысль", kind: .capture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("requests.json.corrupt").path))
        let pending = await client.pending()
        XCTAssertEqual(pending.count, 1)
        await client.stop()
    }

    func testNewerVersionRefusesSubmit() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{\"version\":99,\"requests\":[]}".utf8)
        try original.write(to: requestsFile)
        let api = FakeRequestsAPI()
        let client = makeClient(api)
        do {
            _ = try await client.submit(text: "мысль", kind: .capture)
            XCTFail("должна быть ошибка")
        } catch {
            XCTAssertEqual(error as? VaultRequestError, .storageUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: requestsFile), original)
        XCTAssertEqual(api.submitCount, 0)
    }

    func testCancelWaitingOnlyBeforeAck() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.offline)])
        let client = makeClient(api, sleeper: FakeSleeper(hangFirst: 100))
        let stream = await client.updates()
        let id = try await client.submit(text: "мысль", kind: .capture)
        _ = await collect(stream) { $0.last?.phase == .waitingForConnection }
        let cancelled = await client.cancelWaiting(requestID: id)
        XCTAssertTrue(cancelled)
        let afterCancel = await client.pending()
        XCTAssertTrue(afterCancel.isEmpty)

        let acked = FakeRequestsAPI(jobs: [running()])
        let other = makeClient(acked, sleeper: FakeSleeper(hangFirst: 100), directory: directory.appendingPathComponent("acked"))
        let stream2 = await other.updates()
        let id2 = try await other.submit(text: "вопрос", kind: .ask)
        _ = await collect(stream2) { $0.last?.phase == .queued }
        let refused = await other.cancelWaiting(requestID: id2)
        XCTAssertFalse(refused)
        await other.stop()
    }

    func testMultipleSubscribersAndReplay() async throws {
        let api = FakeRequestsAPI(submit: [.fail(.offline)], jobs: [running()])
        let client = makeClient(api, sleeper: FakeSleeper(hangFirst: 1))
        let first = await client.updates()
        _ = try await client.submit(text: "мысль", kind: .capture)
        let earlyUpdates = await collect(first) { $0.last?.phase == .waitingForConnection }
        XCTAssertEqual(earlyUpdates.map(\.phase), [.submitting, .waitingForConnection])
        let late = await client.updates()
        let replay = await collect(late) { !$0.isEmpty }
        XCTAssertEqual(replay.first?.phase, .waitingForConnection)
        await client.connectionRestored()
        await client.stop()
    }

    func testNoDoubleWorkerOnResumeAndRetry() async throws {
        let store = VaultRequestsStore(directory: directory)
        try store.save([VaultPendingRequest(requestID: "a", text: "вопрос", kind: .ask, jobID: "job-a", createdAt: Date())])
        let api = FakeRequestsAPI(jobs: [running()])
        let sleeper = FakeSleeper(hangFirst: 100)
        let client = makeClient(api, sleeper: sleeper)
        try await client.resumePending()
        try await client.resumePending()
        await client.retry(requestID: "a")
        await waitFor { !sleeper.pauses.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.jobCount, 1)
        await client.stop()
    }

    func testFileRemovedWhenEmptyAndPermissions() async throws {
        let api = FakeRequestsAPI(jobs: [running(), completed()])
        let sleeper = FakeSleeper(hangFirst: 1)
        let client = makeClient(api, sleeper: sleeper)
        let stream = await client.updates()
        _ = try await client.submit(text: "мысль", kind: .capture)
        await waitFor { !sleeper.pauses.isEmpty }
        let attributes = try FileManager.default.attributesOfItem(atPath: requestsFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".metadata_never_index").path))
        await client.connectionRestored()
        _ = await collect(stream) { self.isTerminal($0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestsFile.path))
    }
}
