import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LacEditor

/// Игрушечный сервер хранилища поверх `VaultStubProtocol`: файлы, список папки, `/healthz`, сбои сети.
private final class FakeVaultServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (data: Data, mtime: Int64)] = [:]
    private var networkDown = false
    private var healthFailures = 0
    private var fileDelay: TimeInterval = 0
    private var truncate = false
    private var treeStatus: [String: Int] = [:]
    private var forcedStatus: Int?
    private var emptyTree = false

    func put(_ path: String, _ text: String, mtime: Int64 = 100) {
        lock.lock(); files[path] = (Data(text.utf8), mtime); lock.unlock()
    }
    func remove(_ path: String) { lock.lock(); files[path] = nil; lock.unlock() }
    func set(networkDown value: Bool) { lock.lock(); networkDown = value; lock.unlock() }
    func set(healthFailures value: Int) { lock.lock(); healthFailures = value; lock.unlock() }
    func set(fileDelay value: TimeInterval) { lock.lock(); fileDelay = value; lock.unlock() }
    func set(truncate value: Bool) { lock.lock(); truncate = value; lock.unlock() }
    func set(treeStatus status: Int, for folder: String) { lock.lock(); treeStatus[folder] = status; lock.unlock() }
    func set(emptyTree value: Bool) { lock.lock(); emptyTree = value; lock.unlock() }
    func set(forcedStatus value: Int?) { lock.lock(); forcedStatus = value; lock.unlock() }

    static func etag(_ data: Data) -> String { VaultClient.sha256Hex(data) }

    func install() {
        VaultStubProtocol.handler = { [self] request in
            lock.lock()
            let down = networkDown, delay = fileDelay, cut = truncate, forced = forcedStatus
            lock.unlock()
            let path = request.url!.path
            if down, path != "/healthz" || healthShouldFail() { throw URLError(.notConnectedToInternet) }
            if let forced, path != "/healthz" { return (forced, [:], Data("{\"error\":\"x\"}".utf8)) }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let target = items.first { $0.name == "path" }?.value ?? ""
            switch path {
            case "/healthz":
                return (200, [:], Data("{\"status\":\"ok\"}".utf8))
            case "/v1/vault/file":
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                lock.lock(); let file = files[target]; lock.unlock()
                guard let file else { return (404, [:], Data("{\"error\":\"not found\"}".utf8)) }
                var body = file.data
                let length = body.count
                if cut { body = body.prefix(max(body.count - 1, 0)) }
                return (200, ["Content-Length": "\(length)", "ETag": "\"\(Self.etag(file.data))\"",
                              "X-File-Modified-Ns": "\(file.mtime)"], body)
            case "/v1/vault/tree":
                lock.lock(); let status = treeStatus[target]; let snapshot = emptyTree ? [:] : files; lock.unlock()
                if let status { return (status, [:], Data("{\"error\":\"x\"}".utf8)) }
                let prefix = target.isEmpty ? "" : target + "/"
                let entries: [[String: Any]] = snapshot.keys.sorted().filter {
                    $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/")
                }.map { ["path": $0, "name": $0, "kind": "file", "size": snapshot[$0]!.data.count, "mtime_ns": snapshot[$0]!.mtime] }
                let body = try! JSONSerialization.data(withJSONObject: ["entries": entries, "listing_complete": true])
                return (200, [:], body)
            default:
                return (404, [:], Data())
            }
        }
    }

    /// Пока заданы неудачные пробы `/healthz`, он отвечает ошибкой сети.
    private func healthShouldFail() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if healthFailures > 0 { healthFailures -= 1; return true }
        networkDown = false
        return false
    }

    func requests(path: String) -> [URLRequest] { VaultStubProtocol.requests.filter { $0.url?.path == path } }
}

final class VaultSyncEngineTests: XCTestCase {
    private var tmp: URL!
    private var server: FakeVaultServer!
    private var store: VaultStateStore!
    private var snapshots: DocumentSnapshotStore!
    private var engines: [VaultSyncEngine] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vault-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        VaultStubProtocol.reset()
        server = FakeVaultServer()
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

    private func makeEngine(delays: [TimeInterval] = [0.02, 0.02], store custom: VaultStateStore? = nil) -> VaultSyncEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VaultStubProtocol.self]
        let client = VaultClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-token", session: URLSession(configuration: configuration))
        let engine = VaultSyncEngine(connection: VaultConnection(name: "test"), client: client, store: custom ?? store,
                                     configuration: VaultSyncConfiguration(failureThreshold: 2, probeDelays: delays),
                                     snapshotStore: snapshots)
        engines.append(engine)
        return engine
    }

    private func tree(_ url: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return [] }
        return (walker.allObjects as? [String] ?? []).sorted()
    }

    private func waitFor(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func collectEvents(_ engine: VaultSyncEngine) -> EventLog {
        let log = EventLog()
        let stream = engine.events
        Task { for await event in stream { log.add(event) } }
        return log
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [VaultSyncEvent] = []
        func add(_ event: VaultSyncEvent) { lock.lock(); items.append(event); lock.unlock() }
        var all: [VaultSyncEvent] { lock.lock(); defer { lock.unlock() }; return items }
    }

    // MARK: Открытие

    func testOpenDownloadsVerifiesAndWrites() async throws {
        server.put("daily/a.md", "привет", mtime: 42)
        let engine = makeEngine()
        let log = collectEvents(engine)
        let url = try await engine.open(serverPath: "daily/a.md")
        XCTAssertEqual(url.standardizedFileURL.path, store.openDirectory.appendingPathComponent("daily/a.md").standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: url), Data("привет".utf8))
        XCTAssertEqual(try store.readBase(serverPath: "daily/a.md"), Data("привет".utf8))
        let allRecords = await engine.records()
        let record = try XCTUnwrap(allRecords["daily/a.md"])
        XCTAssertEqual(record.baseETag, VaultClient.sha256Hex(Data("привет".utf8)))
        XCTAssertEqual(record.baseModifiedNs, 42)
        XCTAssertEqual(record.baseSize, Data("привет".utf8).count)
        XCTAssertEqual(record.state, .synced)
        XCTAssertTrue(record.isOpenInTab)
        XCTAssertEqual(try store.load()["daily/a.md"], record)
        let ok = await waitFor { log.all.count >= 3 }
        XCTAssertTrue(ok)
        let events = log.all
        XCTAssertEqual(events[0], .noteState(serverPath: "daily/a.md", .loading))
        XCTAssertEqual(events[1], .noteState(serverPath: "daily/a.md", .synced))
        if case .lastSync = events[2] {} else { XCTFail("ожидалось lastSync") }
    }

    func testOpenBadServerPathNeverWrites() async {
        let engine = makeEngine()
        for bad in ["../x.md", "/etc/passwd", "a\\b.md"] {
            do {
                _ = try await engine.open(serverPath: bad)
                XCTFail(bad)
            } catch {
                XCTAssertEqual(error as? VaultSyncError, .invalidPath)
            }
        }
        XCTAssertTrue(VaultStubProtocol.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testTruncatedResponseLeavesLocalFileUntouched() async throws {
        server.put("a.md", "полный текст")
        server.set(truncate: true)
        let engine = makeEngine()
        do {
            _ = try await engine.open(serverPath: "a.md")
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(error as? VaultClientError, .incompleteResponse)
        }
        XCTAssertEqual(tree(store.openDirectory), [])
        XCTAssertEqual(tree(store.openStateDirectory), [])
        let records = await engine.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testOpenExistingLocalFileMakesNoRequest() async throws {
        _ = try store.writeNote(Data("мои правки".utf8), serverPath: "a.md")
        try store.writeBase(Data("старое".utf8), serverPath: "a.md")
        let record = VaultOpenNoteRecord(serverPath: "a.md", baseETag: String(repeating: "1", count: 64), baseModifiedNs: 1,
                                         baseSize: Data("старое".utf8).count, state: .modified, isOpenInTab: false)
        try store.save(["a.md": record])
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        XCTAssertTrue(VaultStubProtocol.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("мои правки".utf8))
        let opened = await engine.records()["a.md"]
        XCTAssertEqual(opened?.isOpenInTab, true)
        // Заметка помечена для сверки: следующий проход не верит списку папки.
        server.put("a.md", "старое", mtime: 1)
        _ = await engine.checkOpenNotes()
        XCTAssertEqual(server.requests(path: "/v1/vault/file").count, 1)
    }

    func testOpenWithMissingFileRedownloads() async throws {
        server.put("a.md", "с сервера")
        try store.save(["a.md": VaultOpenNoteRecord(serverPath: "a.md", baseETag: String(repeating: "1", count: 64), state: .modified)])
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        XCTAssertEqual(try Data(contentsOf: url), Data("с сервера".utf8))
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.state, .synced)
    }

    func testConcurrentOpensShareOneDownload() async throws {
        server.put("a.md", "x")
        server.set(fileDelay: 0.2)
        let engine = makeEngine()
        async let first = engine.open(serverPath: "a.md")
        async let second = engine.open(serverPath: "a.md")
        let urls = try await [first, second]
        XCTAssertEqual(urls[0], urls[1])
        XCTAssertEqual(server.requests(path: "/v1/vault/file").count, 1)
    }

    func testCloseWhileLoadingWritesNothing() async throws {
        server.put("a.md", "x")
        server.set(fileDelay: 0.4)
        let engine = makeEngine()
        let opening = Task { try await engine.open(serverPath: "a.md") }
        try await Task.sleep(nanoseconds: 150_000_000)
        let removed = await engine.noteClosed(serverPath: "a.md")
        XCTAssertTrue(removed)
        do {
            _ = try await opening.value
            XCTFail("ожидалась отмена")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(tree(store.openDirectory), [])
        XCTAssertEqual(tree(store.openStateDirectory), [])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testCloseSyncedRemovesEverything() async throws {
        server.put("daily/a.md", "x")
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "daily/a.md")
        let location = DocumentSnapshotLocation.file(path: url.standardizedFileURL.path)
        try snapshots.add(text: "x", name: "s", encodingName: "utf-8", location: location, keepLast: 5)
        XCTAssertEqual(snapshots.list(location: location).count, 1)
        let removed = await engine.noteClosed(serverPath: "daily/a.md")
        XCTAssertTrue(removed)
        XCTAssertEqual(tree(store.openDirectory), [])
        XCTAssertEqual(tree(store.openStateDirectory), [])
        XCTAssertTrue(snapshots.list(location: location).isEmpty)
        XCTAssertEqual(tree(store.root), [".metadata_never_index", "open", "open-state", "state.json"])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testCloseModifiedKeepsFile() async throws {
        server.put("a.md", "x")
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        let location = DocumentSnapshotLocation.file(path: url.standardizedFileURL.path)
        try snapshots.add(text: "x", name: "s", encodingName: "utf-8", location: location, keepLast: 5)
        await engine.setState(.modified, for: "a.md")
        let removed = await engine.noteClosed(serverPath: "a.md")
        XCTAssertFalse(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try store.readBase(serverPath: "a.md"))
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.isOpenInTab, false)
        XCTAssertEqual(snapshots.list(location: location).count, 1)
    }

    func testCloseDeletedOnServerRemovesOnlyIfEqualToBase() async throws {
        server.put("a.md", "x")
        server.put("b.md", "y")
        let engine = makeEngine()
        let a = try await engine.open(serverPath: "a.md")
        let b = try await engine.open(serverPath: "b.md")
        await engine.setState(.deletedOnServer, for: "a.md")
        await engine.setState(.deletedOnServer, for: "b.md")
        try Data("изменено".utf8).write(to: b)
        let removedA = await engine.noteClosed(serverPath: "a.md")
        let removedB = await engine.noteClosed(serverPath: "b.md")
        XCTAssertTrue(removedA)
        XCTAssertFalse(removedB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    // MARK: Уборка после сбоя

    func testCleanupAfterCrashRemovesOrphans() async throws {
        let etag = String(repeating: "1", count: 64)
        for path in ["orphan.md", "synced.md", "mod.md", "restored.md"] { _ = try store.writeNote(Data(path.utf8), serverPath: path) }
        for path in ["orphan-base.md", "synced.md", "mod.md", "restored.md"] { try store.writeBase(Data(path.utf8), serverPath: path) }
        try store.save([
            "synced.md": VaultOpenNoteRecord(serverPath: "synced.md", baseETag: etag, state: .synced),
            "mod.md": VaultOpenNoteRecord(serverPath: "mod.md", baseETag: etag, state: .modified),
            "restored.md": VaultOpenNoteRecord(serverPath: "restored.md", baseETag: etag, baseModifiedNs: 1,
                                               baseSize: "restored.md".utf8.count, state: .synced, isOpenInTab: false),
        ])
        let syncedURL = try XCTUnwrap(store.noteURL(for: "synced.md"))
        let location = DocumentSnapshotLocation.file(path: syncedURL.standardizedFileURL.path)
        try snapshots.add(text: "x", name: "s", encodingName: "utf-8", location: location, keepLast: 5)
        try Data("{}".utf8).write(to: store.root.appendingPathComponent("requests.json"))
        let engine = makeEngine()
        await engine.cleanupAfterCrash(restoredPaths: ["restored.md"])
        XCTAssertEqual(tree(store.openDirectory), ["mod.md", "restored.md"])
        let records = await engine.records()
        XCTAssertEqual(Set(records.keys), ["mod.md", "restored.md"])
        XCTAssertEqual(records["mod.md"]?.isOpenInTab, false)
        XCTAssertEqual(records["restored.md"]?.isOpenInTab, true)
        XCTAssertTrue(snapshots.list(location: location).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("requests.json").path))
        XCTAssertEqual(tree(store.openStateDirectory).count, 2)
        // Восстановленная вкладка помечена для сверки: список папки не принимается на веру.
        server.put("restored.md", "restored.md", mtime: 1)
        _ = await engine.checkOpenNotes()
        XCTAssertEqual(server.requests(path: "/v1/vault/file").count, 1)
    }

    func testCleanupWithDamagedStateDeletesNothing() async throws {
        _ = try store.writeNote(Data("мои правки".utf8), serverPath: "a.md")
        try Data("мусор".utf8).write(to: store.stateFileURL)
        let engine = makeEngine()
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertEqual(tree(store.openDirectory), ["a.md"])
        do {
            _ = try await engine.open(serverPath: "b.md")
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(error as? VaultSyncError, .stateUnavailable)
        }
        let closed = await engine.noteClosed(serverPath: "a.md")
        XCTAssertFalse(closed)
        XCTAssertEqual(tree(store.openDirectory), ["a.md"])
    }

    func testCleanupDropsRecordWithoutFile() async throws {
        try store.save(["a.md": VaultOpenNoteRecord(serverPath: "a.md", baseETag: String(repeating: "1", count: 64), state: .modified)])
        let engine = makeEngine()
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertTrue(try store.load().isEmpty)
    }

    // MARK: Сверка

    func testCheckOpenNotesUsesTreePerFolder() async throws {
        for path in ["d1/a.md", "d1/b.md", "d2/c.md"] { server.put(path, path) }
        let engine = makeEngine()
        for path in ["d1/a.md", "d1/b.md", "d2/c.md"] { _ = try await engine.open(serverPath: path) }
        VaultStubProtocol.reset(); server.install()
        let changes = await engine.checkOpenNotes()
        XCTAssertTrue(changes.isEmpty)
        let trees = server.requests(path: "/v1/vault/tree")
        XCTAssertEqual(trees.count, 2)
        XCTAssertEqual(Set(trees.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "path" }!.value! }), ["d1", "d2"])
        XCTAssertTrue(trees.allSatisfy { $0.url!.query!.contains("depth=0") })
        XCTAssertTrue(server.requests(path: "/v1/vault/file").isEmpty)
    }

    func testCheckDetectsChangedByMTimeAndFetches() async throws {
        server.put("a.md", "v1", mtime: 1)
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        server.put("a.md", "v2", mtime: 2)
        let changes = await engine.checkOpenNotes()
        XCTAssertEqual(changes, [.updated(serverPath: "a.md", data: Data("v2".utf8), etag: VaultClient.sha256Hex(Data("v2".utf8)))])
        XCTAssertEqual(try Data(contentsOf: url), Data("v1".utf8))
        let fetched = server.requests(path: "/v1/vault/file").count
        let again = await engine.checkOpenNotes()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(server.requests(path: "/v1/vault/file").count, fetched)
    }

    func testCheckSameETagUpdatesBaseMetadata() async throws {
        server.put("a.md", "v1", mtime: 1)
        let engine = makeEngine()
        _ = try await engine.open(serverPath: "a.md")
        server.put("a.md", "v1", mtime: 9)
        var changes = await engine.checkOpenNotes()
        XCTAssertTrue(changes.isEmpty)
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.baseModifiedNs, 9)
        let fetched = server.requests(path: "/v1/vault/file").count
        changes = await engine.checkOpenNotes()
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(server.requests(path: "/v1/vault/file").count, fetched)
    }

    func testCheckMissingFromListingFetchesAndDoesNotDelete() async throws {
        server.put("a.md", "v1", mtime: 1)
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        // Список папки пуст, но сам файл отдаётся: удалённым заметка не становится.
        server.set(emptyTree: true)
        let changes = await engine.checkOpenNotes()
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(server.requests(path: "/v1/vault/file").count, 2)
        let state = await engine.records()["a.md"]?.state
        XCTAssertEqual(state, .synced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNotFoundOnFileMeansDeleted() async throws {
        server.put("a.md", "v1")
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        let log = collectEvents(engine)
        server.remove("a.md")
        let changes = await engine.checkOpenNotes()
        XCTAssertEqual(changes, [.deleted(serverPath: "a.md")])
        let state = await engine.records()["a.md"]?.state
        XCTAssertEqual(state, .deletedOnServer)
        XCTAssertEqual(try Data(contentsOf: url), Data("v1".utf8))
        let seen = await waitFor { log.all.contains(.noteState(serverPath: "a.md", .deletedOnServer)) }
        XCTAssertTrue(seen)
        let again = await engine.checkOpenNotes()
        XCTAssertTrue(again.isEmpty)
    }

    func testFolderNotFoundFallsBackToFileCheck() async throws {
        server.put("d/a.md", "v1", mtime: 1)
        let engine = makeEngine()
        _ = try await engine.open(serverPath: "d/a.md")
        server.set(treeStatus: 404, for: "d")
        server.put("d/a.md", "v2", mtime: 2)
        let changes = await engine.checkOpenNotes()
        XCTAssertEqual(changes.count, 1)
        server.remove("d/a.md")
        let deleted = await engine.checkOpenNotes()
        XCTAssertEqual(deleted, [.deleted(serverPath: "d/a.md")])
    }

    func testApplyServerVersionWritesFileBaseAndRecord() async throws {
        server.put("a.md", "v1", mtime: 1)
        server.put("b.md", "b1", mtime: 1)
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        let other = try await engine.open(serverPath: "b.md")
        server.put("a.md", "v2", mtime: 2)
        server.put("b.md", "b2", mtime: 2)
        _ = await engine.checkOpenNotes()
        let applied = try await engine.applyServerVersion(serverPath: "a.md")
        XCTAssertEqual(applied, url)
        XCTAssertEqual(try Data(contentsOf: url), Data("v2".utf8))
        XCTAssertEqual(try store.readBase(serverPath: "a.md"), Data("v2".utf8))
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.baseETag, VaultClient.sha256Hex(Data("v2".utf8)))
        XCTAssertEqual(record?.state, .synced)
        await engine.markNewerOnServer(serverPath: "b.md")
        let state = await engine.records()["b.md"]?.state
        XCTAssertEqual(state, .newerOnServer)
        XCTAssertEqual(try Data(contentsOf: other), Data("b1".utf8))
    }

    func testApplyServerVersionIgnoresModifiedRecord() async throws {
        server.put("a.md", "v1", mtime: 1)
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        try Data("мои правки".utf8).write(to: url)
        await engine.setState(.modified, for: "a.md")
        server.put("a.md", "v2", mtime: 2)
        _ = await engine.checkOpenNotes()
        _ = try await engine.applyServerVersion(serverPath: "a.md")
        XCTAssertEqual(try Data(contentsOf: url), Data("мои правки".utf8))
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.state, .modified)
    }

    // MARK: Связь

    func testOfflineAfterTwoConsecutiveNetworkErrors() async throws {
        server.put("a.md", "x")
        let engine = makeEngine(delays: [60])
        let log = collectEvents(engine)
        server.set(networkDown: true)
        await expectOpenFails(engine, "a.md")
        var online = await engine.isOnline()
        XCTAssertTrue(online)
        XCTAssertFalse(log.all.contains(.connection(isOnline: false)))
        await expectOpenFails(engine, "a.md")
        online = await engine.isOnline()
        XCTAssertFalse(online)
        let seen = await waitFor { log.all.contains(.connection(isOnline: false)) }
        XCTAssertTrue(seen)
        await expectOpenFails(engine, "a.md")
        XCTAssertEqual(log.all.filter { $0 == .connection(isOnline: false) }.count, 1)
    }

    func testSuccessBetweenErrorsResetsCounter() async throws {
        server.put("a.md", "x")
        let engine = makeEngine(delays: [60])
        server.set(networkDown: true)
        await expectOpenFails(engine, "a.md")
        server.set(networkDown: false)
        _ = try await engine.open(serverPath: "a.md")
        server.put("b.md", "y")
        server.set(networkDown: true)
        await expectOpenFails(engine, "b.md")
        let online = await engine.isOnline()
        XCTAssertTrue(online)
    }

    private func expectOpenFails(_ engine: VaultSyncEngine, _ path: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await engine.open(serverPath: path)
            XCTFail("ожидалась ошибка", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VaultClientError, .offline, file: file, line: line)
        }
    }

    func testServerErrorsDoNotMeanOffline() async {
        let engine = makeEngine(delays: [60])
        for status in [401, 404, 500, 401] {
            server.set(forcedStatus: status)
            _ = try? await engine.open(serverPath: "a.md")
        }
        let online = await engine.isOnline()
        XCTAssertTrue(online)
    }

    func testOnlineReturnsAfterHealthProbe() async {
        let engine = makeEngine(delays: [0.05, 0.05])
        let log = collectEvents(engine)
        server.set(healthFailures: 2)
        server.set(networkDown: true)
        await expectOpenFails(engine, "a.md")
        await expectOpenFails(engine, "a.md")
        let back = await waitFor { log.all.contains(.connection(isOnline: true)) }
        XCTAssertTrue(back)
        let online = await engine.isOnline()
        XCTAssertTrue(online)
    }

    func testConnectivityMayHaveChangedProbesImmediately() async {
        let engine = makeEngine(delays: [60])
        server.set(networkDown: true)
        await expectOpenFails(engine, "a.md")
        await expectOpenFails(engine, "a.md")
        var online = await engine.isOnline()
        XCTAssertFalse(online)
        server.set(networkDown: false)
        await engine.connectivityMayHaveChanged()
        let back = await waitFor(2) { await engine.isOnline() }
        XCTAssertTrue(back)
        online = await engine.isOnline()
        XCTAssertTrue(online)
    }

    func testCheckWhileOfflineReturnsEmptyWithoutRequests() async throws {
        server.put("a.md", "x")
        let engine = makeEngine(delays: [60])
        _ = try await engine.open(serverPath: "a.md")
        server.set(networkDown: true)
        server.put("b.md", "y")
        await expectOpenFails(engine, "b.md")
        await expectOpenFails(engine, "b.md")
        let before = VaultStubProtocol.requests.count
        let changes = await engine.checkOpenNotes()
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(VaultStubProtocol.requests.count, before)
    }

    func testShutdownStopsProbeAndFinishesEvents() async throws {
        let engine = makeEngine(delays: [0.05])
        server.set(networkDown: true)
        server.set(healthFailures: 1000)
        await expectOpenFails(engine, "a.md")
        await expectOpenFails(engine, "a.md")
        let stream = engine.events
        await engine.shutdown()
        var finished = false
        let consumer = Task { for await _ in stream {}; return true }
        finished = await consumer.value
        XCTAssertTrue(finished)
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = server.requests(path: "/healthz").count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.requests(path: "/healthz").count, count)
    }

    // MARK: Ревью этапа 3

    func testTwoLaunchesAfterDamagedStateKeepUnsent() async throws {
        _ = try store.writeNote(Data("мои правки".utf8), serverPath: "a.md")
        try Data("мусор".utf8).write(to: store.stateFileURL)
        let first = makeEngine()
        await first.cleanupAfterCrash(restoredPaths: [])
        await first.shutdown()
        // Второй запуск: state.json уже в карантине, но файлы без записей трогать нельзя.
        let second = makeEngine(store: VaultStateStore(vaultID: UUID(), root: store.root))
        await second.cleanupAfterCrash(restoredPaths: [])
        XCTAssertEqual(tree(store.openDirectory), ["a.md"])
        XCTAssertEqual(try Data(contentsOf: store.openDirectory.appendingPathComponent("a.md")), Data("мои правки".utf8))
    }

    func testShutdownDuringCheckDoesNotWriteState() async throws {
        server.put("a.md", "x", mtime: 100)
        let engine = makeEngine()
        _ = try await engine.open(serverPath: "a.md")
        let before = try Data(contentsOf: store.stateFileURL)
        server.put("a.md", "новое", mtime: 200)
        server.set(fileDelay: 0.3)
        let check = Task { await engine.checkOpenNotes() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await engine.shutdown()
        try FileManager.default.removeItem(at: store.root)
        _ = await check.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        _ = before
    }

    func testCloseSyncedWithChangedFileKeepsIt() async throws {
        server.put("a.md", "x")
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "a.md")
        try Data("правка".utf8).write(to: url)
        let removed = await engine.noteClosed(serverPath: "a.md")
        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: url), Data("правка".utf8))
        let record = await engine.records()["a.md"]
        XCTAssertEqual(record?.state, .modified)
        XCTAssertEqual(record?.isOpenInTab, false)
    }

    func testCloseWithoutRecordKeepsCollidingPath() async throws {
        server.put("\u{439}.md", "z")
        let engine = makeEngine()
        let url = try await engine.open(serverPath: "\u{439}.md")
        let removed = await engine.noteClosed(serverPath: "\u{438}\u{306}.md")
        XCTAssertFalse(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOpenDoesNotSilentlyOverwriteUnrecordedFile() async throws {
        server.put("a.md", "серверное")
        let local = try store.writeNote(Data("локальное".utf8), serverPath: "a.md")
        let engine = makeEngine()
        _ = try await engine.open(serverPath: "a.md")
        let location = DocumentSnapshotLocation.file(path: local.standardizedFileURL.path)
        XCTAssertEqual(snapshots.list(location: location).count, 1)
        XCTAssertEqual(try Data(contentsOf: local), Data("серверное".utf8))
    }

    func testOpenKeepsNonUTF8UnrecordedFile() async throws {
        server.put("a.md", "серверное")
        let bytes = Data([0xFF, 0xFE, 0x41])
        let local = try store.writeNote(bytes, serverPath: "a.md")
        let engine = makeEngine()
        do { _ = try await engine.open(serverPath: "a.md"); XCTFail("ожидалась ошибка") } catch {}
        XCTAssertEqual(try Data(contentsOf: local), bytes)
    }

    func testOpenKeepsFileWhenSnapshotFails() async throws {
        server.put("a.md", "серверное")
        let local = try store.writeNote(Data("локальное".utf8), serverPath: "a.md")
        // Файл вместо папки снимков: запись снимка не получится.
        try Data().write(to: tmp.appendingPathComponent("Snapshots", isDirectory: true))
        let engine = makeEngine()
        do { _ = try await engine.open(serverPath: "a.md"); XCTFail("ожидалась ошибка") } catch {}
        XCTAssertEqual(try Data(contentsOf: local), Data("локальное".utf8))
    }

    func testPreservedSnapshotSurvivesClose() async throws {
        server.put("a.md", "серверное")
        let local = try store.writeNote(Data("локальное".utf8), serverPath: "a.md")
        let engine = makeEngine()
        let log = collectEvents(engine)
        _ = try await engine.open(serverPath: "a.md")
        let removed = await engine.noteClosed(serverPath: "a.md")
        XCTAssertTrue(removed)
        let location = DocumentSnapshotLocation.file(path: local.standardizedFileURL.path)
        XCTAssertEqual(snapshots.list(location: location).count, 1)
        _ = await waitFor { log.all.contains(.localTextPreserved(serverPath: "a.md")) }
        XCTAssertTrue(log.all.contains(.localTextPreserved(serverPath: "a.md")))
    }

    func testAcknowledgeQuarantineUnblocksCleanup() async throws {
        _ = try store.writeNote(Data("старое".utf8), serverPath: "a.md")
        try Data("мусор".utf8).write(to: store.stateFileURL)
        let engine = makeEngine()
        let log = collectEvents(engine)
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertEqual(tree(store.openDirectory), ["a.md"])
        await engine.acknowledgeQuarantine()
        XCTAssertTrue(tree(store.root).contains("state.json.acknowledged"))
        XCTAssertFalse(tree(store.root).contains("state.json.corrupt"))
        // Снимок сделан сразу при решении: уборка в этом запуске может и не пройти.
        let location = DocumentSnapshotLocation.file(path: store.openDirectory.appendingPathComponent("a.md").standardizedFileURL.path)
        XCTAssertEqual(snapshots.list(location: location).count, 1)
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertEqual(tree(store.openDirectory), [])
        XCTAssertEqual(snapshots.list(location: location).count, 1)
        XCTAssertTrue(log.all.contains(.localTextPreserved(serverPath: "a.md")))
    }

    func testCleanupAfterAcknowledgeKeepsNonUTF8() async throws {
        _ = try store.writeNote(Data([0xFF, 0xFE]), serverPath: "b.md")
        try Data("мусор".utf8).write(to: store.stateFileURL)
        let engine = makeEngine()
        XCTAssertFalse(engine.hasQuarantinedState)
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertTrue(engine.hasQuarantinedState)
        await engine.acknowledgeQuarantine()
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertEqual(tree(store.openDirectory), ["b.md"])
    }

    func testCleanupSnapshotsOnlyEditedOrphans() async throws {
        _ = try store.writeNote(Data("как на сервере".utf8), serverPath: "same.md")
        try store.writeBase(Data("как на сервере".utf8), serverPath: "same.md")
        _ = try store.writeNote(Data("правки".utf8), serverPath: "edited.md")
        try store.writeBase(Data("было".utf8), serverPath: "edited.md")
        _ = try store.writeNote(Data("сирота".utf8), serverPath: "plain.md")
        // Одна запись в списке: пустой список при файлах в open/ блокирует уборку.
        _ = try store.writeNote(Data("моё".utf8), serverPath: "keep.md")
        try store.save(["keep.md": VaultOpenNoteRecord(serverPath: "keep.md", baseETag: String(repeating: "1", count: 64), state: .modified)])
        let engine = makeEngine()
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertEqual(tree(store.openDirectory), ["keep.md"])
        func count(_ name: String) -> Int {
            snapshots.list(location: .file(path: store.openDirectory.appendingPathComponent(name).standardizedFileURL.path)).count
        }
        XCTAssertEqual(count("same.md"), 0)
        XCTAssertEqual(count("plain.md"), 0)
        XCTAssertEqual(count("edited.md"), 1)
    }

    func testCleanupDoesNotReadSymlink() async throws {
        let outside = tmp.appendingPathComponent("outside.md")
        try Data("секрет".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: store.openDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.openDirectory.appendingPathComponent("link.md"), withDestinationURL: outside)
        try Data("мусор".utf8).write(to: store.stateFileURL)
        let engine = makeEngine()
        await engine.cleanupAfterCrash(restoredPaths: [])
        await engine.acknowledgeQuarantine()
        await engine.cleanupAfterCrash(restoredPaths: [])
        XCTAssertEqual(snapshots.list(location: .file(path: store.openDirectory.appendingPathComponent("link.md").standardizedFileURL.path)).count, 0)
        XCTAssertEqual(try Data(contentsOf: outside), Data("секрет".utf8))
    }

    // MARK: Пути

    func testPathCollisionIsRejected() async throws {
        server.put("A.md", "x")
        server.put("a.md", "y")
        server.put("\u{439}.md", "z")   // «й» одним знаком
        let engine = makeEngine()
        _ = try await engine.open(serverPath: "A.md")
        let downloads = server.requests(path: "/v1/vault/file").count
        do {
            _ = try await engine.open(serverPath: "a.md")
            XCTFail("ожидалась коллизия")
        } catch {
            XCTAssertEqual(error as? VaultSyncError, .pathCollision)
        }
        _ = try await engine.open(serverPath: "\u{439}.md")
        do {
            _ = try await engine.open(serverPath: "\u{438}\u{306}.md")   // «й» как «и» + краткая
            XCTFail("ожидалась коллизия")
        } catch {
            XCTAssertEqual(error as? VaultSyncError, .pathCollision)
        }
        XCTAssertEqual(server.requests(path: "/v1/vault/file").count, downloads + 1)
    }

    func testServerPathMappingNonisolated() async throws {
        server.put("daily/a.md", "x")
        let engine = makeEngine()
        let unopened = await engine.localURL(for: "daily/a.md")
        XCTAssertNil(unopened)
        let url = try await engine.open(serverPath: "daily/a.md")
        let local = await engine.localURL(for: "daily/a.md")
        XCTAssertEqual(local, url)
        let back = await engine.serverPath(for: url)
        XCTAssertEqual(back, "daily/a.md")
        XCTAssertEqual(engine.serverPath(forLocalPath: url.path), "daily/a.md")
        XCTAssertNil(engine.serverPath(forLocalPath: "/tmp/outside.md"))
        let stray = store.openDirectory.appendingPathComponent("stray.md")
        let known = await engine.serverPath(for: stray)
        XCTAssertNil(known)
        XCTAssertEqual(engine.openDirectory, store.openDirectory)
    }
}
