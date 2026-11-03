import Combine
import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LacEditor

@MainActor
final class VaultCatalogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VaultStubProtocol.reset()
    }

    override func tearDown() {
        VaultStubProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> VaultClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VaultStubProtocol.self]
        return VaultClient(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test-token", session: URLSession(configuration: configuration))
    }

    private func entry(_ path: String, directory: Bool = false) -> [String: Any] {
        ["path": path, "name": String(path.split(separator: "/").last ?? ""), "kind": directory ? "directory" : "file",
         "size": 3, "mtime_ns": 100]
    }

    private func page(_ entries: [[String: Any]], token: String? = nil, complete: Bool? = nil) -> VaultStubProtocol.Response {
        var object: [String: Any] = ["entries": entries, "next_page_token": token ?? NSNull()]
        if let complete { object["listing_complete"] = complete }
        return (200, [:], try! JSONSerialization.data(withJSONObject: object))
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func testLoadRootsSendsDepthZero() async throws {
        VaultStubProtocol.handler = { _ in self.page([self.entry("b", directory: true), self.entry("a.md")]) }
        let catalog = VaultCatalog(client: makeClient())
        try await catalog.loadRoots()
        let request = try XCTUnwrap(VaultStubProtocol.requests.first)
        XCTAssertEqual(query(request, "path"), "")
        XCTAssertEqual(query(request, "depth"), "0")
        XCTAssertEqual(query(request, "page_size"), "1000")
        XCTAssertEqual(catalog.roots.map(\.path), ["b", "a.md"])
    }

    func testLateLoadRootsDoesNotOverwriteNewer() async throws {
        let lock = NSLock()
        var calls = 0
        VaultStubProtocol.handler = { _ in
            lock.lock(); calls += 1; let number = calls; lock.unlock()
            if number == 1 {
                Thread.sleep(forTimeInterval: 0.3)
                return self.page([self.entry("old.md")])
            }
            return self.page([self.entry("new.md")])
        }
        let catalog = VaultCatalog(client: makeClient())
        let first = Task { try await catalog.loadRoots() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try await catalog.loadRoots()
        try await first.value
        XCTAssertEqual(catalog.roots.map(\.path), ["new.md"])
    }

    func testLoopingPageTokensFail() async throws {
        VaultStubProtocol.handler = { request in
            self.query(request, "page_token") == "a" ? self.page([self.entry("b.md")], token: "b") : self.page([self.entry("a.md")], token: "a")
        }
        let catalog = VaultCatalog(client: makeClient())
        do {
            try await catalog.loadRoots()
            XCTFail("ожидалась ошибка")
        } catch {}
    }

    func testLoadRootsFollowsPageTokens() async throws {
        VaultStubProtocol.handler = { request in
            self.query(request, "page_token") == nil ? self.page([self.entry("a.md")], token: "t1") : self.page([self.entry("b.md")])
        }
        let catalog = VaultCatalog(client: makeClient())
        try await catalog.loadRoots()
        XCTAssertEqual(catalog.roots.map(\.path), ["a.md", "b.md"])
        XCTAssertEqual(VaultStubProtocol.requests.count, 2)
        XCTAssertEqual(query(VaultStubProtocol.requests[1], "page_token"), "t1")
    }

    func testLoadChildrenStoresUnderPath() async throws {
        VaultStubProtocol.handler = { _ in
            self.page([self.entry("daily/a.md"), self.entry("other/b.md"), self.entry("daily/../x.md"), self.entry("daily/a.md"), self.entry("daily/c.md")])
        }
        let catalog = VaultCatalog(client: makeClient())
        try await catalog.loadChildren(of: "daily")
        XCTAssertEqual(catalog.childrenByPath["daily"]?.map(\.path), ["daily/a.md", "daily/c.md"])
        XCTAssertEqual(query(VaultStubProtocol.requests[0], "path"), "daily")
    }

    func testHiddenRootsAreHidden() async throws {
        VaultStubProtocol.handler = { request in
            if self.query(request, "depth") == "8" { return self.page([self.entry("private/x.md"), self.entry("open/y.md")]) }
            return self.page([self.entry("private", directory: true), self.entry("open", directory: true)])
        }
        let catalog = VaultCatalog(client: makeClient(), hiddenRoots: ["private"])
        try await catalog.loadRoots()
        XCTAssertEqual(catalog.roots.map(\.path), ["open"])
        let before = VaultStubProtocol.requests.count
        try await catalog.loadChildren(of: "private")
        XCTAssertEqual(VaultStubProtocol.requests.count, before)
        XCTAssertNil(catalog.childrenByPath["private"])
        let ok = await catalog.refreshFullListing()
        XCTAssertTrue(ok)
        XCTAssertEqual(catalog.allFiles.map(\.path), ["open/y.md"])
        XCTAssertEqual(catalog.wikiLinkPaths(), ["open/y.md"])
        let count = VaultStubProtocol.requests.count
        catalog.updateHiddenRoots([])
        XCTAssertEqual(catalog.roots.map(\.path), ["private", "open"])
        XCTAssertEqual(catalog.allFiles.map(\.path), ["private/x.md", "open/y.md"])
        XCTAssertEqual(VaultStubProtocol.requests.count, count)
    }

    func testFullListingUsesDepth8AndPages() async throws {
        VaultStubProtocol.handler = { request in
            self.query(request, "page_token") == nil
                ? self.page([self.entry("d", directory: true), self.entry("d/a.md")], token: "t")
                : self.page([self.entry("d/p.png")], complete: true)
        }
        let catalog = VaultCatalog(client: makeClient())
        let ok = await catalog.refreshFullListing()
        XCTAssertTrue(ok)
        XCTAssertEqual(query(VaultStubProtocol.requests[0], "depth"), "8")
        XCTAssertEqual(query(VaultStubProtocol.requests[0], "page_size"), "1000")
        XCTAssertEqual(catalog.allFiles.map(\.path), ["d/a.md", "d/p.png"])
        XCTAssertTrue(catalog.isFullListingLoaded)
        XCTAssertNotNil(catalog.lastFullListingDate)
    }

    func testIncompleteListingDoesNotChangeCatalog() async throws {
        VaultStubProtocol.handler = { _ in self.page([self.entry("a.md")], complete: true) }
        let catalog = VaultCatalog(client: makeClient())
        var ok = await catalog.refreshFullListing()
        XCTAssertTrue(ok)
        VaultStubProtocol.handler = { request in
            if self.query(request, "page_token") == nil { return self.page([self.entry("new.md")], token: "t") }
            throw URLError(.networkConnectionLost)
        }
        ok = await catalog.refreshFullListing()
        XCTAssertFalse(ok)
        XCTAssertEqual(catalog.allFiles.map(\.path), ["a.md"])
        VaultStubProtocol.handler = { _ in self.page([self.entry("new.md")], complete: false) }
        ok = await catalog.refreshFullListing()
        XCTAssertFalse(ok)
        XCTAssertEqual(catalog.allFiles.map(\.path), ["a.md"])
        XCTAssertTrue(catalog.isFullListingLoaded)
    }

    func testListingChangedRestartsAndIsBounded() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var calls = 0
        VaultStubProtocol.handler = { request in
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            if self.query(request, "page_token") == nil { return self.page([self.entry("a.md")], token: "t") }
            if n == 2 { return (409, [:], Data("{\"error\":\"listing changed\"}".utf8)) }
            return self.page([self.entry("b.md")])
        }
        let catalog = VaultCatalog(client: makeClient())
        var ok = await catalog.refreshFullListing()
        XCTAssertTrue(ok)
        XCTAssertEqual(catalog.allFiles.map(\.path), ["a.md", "b.md"])
        XCTAssertEqual(VaultStubProtocol.requests.count, 4)

        VaultStubProtocol.reset()
        VaultStubProtocol.handler = { _ in (409, [:], Data("{\"error\":\"listing changed\"}".utf8)) }
        let other = VaultCatalog(client: makeClient())
        ok = await other.refreshFullListing()
        XCTAssertFalse(ok)
        XCTAssertEqual(VaultStubProtocol.requests.count, 3)
        XCTAssertTrue(other.allFiles.isEmpty)
    }

    func testOldServerWithoutListingCompleteIsAccepted() async {
        VaultStubProtocol.handler = { _ in self.page([self.entry("a.md")]) }
        let catalog = VaultCatalog(client: makeClient())
        let ok = await catalog.refreshFullListing()
        XCTAssertTrue(ok)
        XCTAssertEqual(catalog.allFiles.count, 1)
    }

    func testInvalidServerPathsAreDroppedFromFullListing() async {
        VaultStubProtocol.handler = { _ in
            self.page([self.entry("/abs.md"), self.entry("a/../b.md"), self.entry("a\\b.md"), self.entry(".hid.md"), self.entry("ok.md")])
        }
        let catalog = VaultCatalog(client: makeClient())
        _ = await catalog.refreshFullListing()
        XCTAssertEqual(catalog.allFiles.map(\.path), ["ok.md"])
    }

    func testWikiLinkPathsOnlyMarkdown() async throws {
        VaultStubProtocol.handler = { request in
            if self.query(request, "depth") == "8" {
                return self.page([self.entry("a.md"), self.entry("b.MD"), self.entry("c.markdown"), self.entry("d.png"), self.entry("e.pdf")])
            }
            return self.page([self.entry("r.md"), self.entry("r.png"), self.entry("dir", directory: true)])
        }
        let catalog = VaultCatalog(client: makeClient())
        try await catalog.loadRoots()
        XCTAssertEqual(catalog.wikiLinkPaths(), ["r.md"])
        _ = await catalog.refreshFullListing()
        XCTAssertEqual(catalog.wikiLinkPaths(), ["a.md", "b.MD", "c.markdown"])
        XCTAssertEqual(catalog.allFiles.count, 5)
    }

    func testUnchangedRefreshDoesNotRepublish() async {
        VaultStubProtocol.handler = { _ in self.page([self.entry("a.md")]) }
        let catalog = VaultCatalog(client: makeClient())
        _ = await catalog.refreshFullListing()
        var changes = 0
        let cancellable = catalog.objectWillChange.sink { changes += 1 }
        let ok = await catalog.refreshFullListing()
        XCTAssertTrue(ok)
        XCTAssertEqual(changes, 0)
        cancellable.cancel()
    }

    func testClearDropsLateResult() async {
        VaultStubProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return self.page([self.entry("a.md")])
        }
        let catalog = VaultCatalog(client: makeClient())
        let task = Task { await catalog.refreshFullListing() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        catalog.clear()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertTrue(catalog.allFiles.isEmpty)
        XCTAssertFalse(catalog.isFullListingLoaded)
    }

    func testParallelRefreshIsSingleFlight() async {
        VaultStubProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return self.page([self.entry("a.md")])
        }
        let catalog = VaultCatalog(client: makeClient())
        async let first = catalog.refreshFullListing()
        async let second = catalog.refreshFullListing()
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(VaultStubProtocol.requests.count, 1)
    }
}
