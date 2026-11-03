import XCTest
@testable import LacEditor

@MainActor
final class WriterCombinedViewControllerTests: XCTestCase {
    private var root: URL!
    private var store: ManuscriptProjectStore!
    private var preferences: AppPreferences!
    private var ids: [UUID] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try "Text of \(name)".write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8) }
        store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: ["a.md", "b.md", "c.md"])
        ids = store.project?.nodes.map(\.id) ?? []
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WriterCombinedViewControllerTests-\(UUID().uuidString)"))
        preferences = AppPreferences(defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(scope: WriterCombinedViewController.Scope = .wholeBook) -> WriterCombinedViewController {
        WriterCombinedViewController(store: store, windowManager: nil, preferences: preferences, scope: scope, isDark: { false })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Условие не выполнилось вовремя", file: file, line: line)
    }

    func testOnlyIncludedScenesAreShown() async throws {
        try store.update { _ = $0.mutateNode(id: self.ids[1]) { $0.include = false } }
        let controller = makeController()
        controller.reload()
        await waitUntil { !controller.isLoading && controller.partCount > 0 }
        XCTAssertEqual(controller.partCount, 2)
        XCTAssertTrue(controller.html.contains("Text of a"))
        XCTAssertFalse(controller.html.contains("Text of b"))
        XCTAssertTrue(controller.html.contains("Text of c"))
        XCTAssertFalse(controller.token.isEmpty)
    }

    func testOpenPartReportsNodeAndIgnoresBadIndex() async throws {
        try store.update { _ = $0.mutateNode(id: self.ids[0]) { $0.include = false } }
        let controller = makeController()
        var opened: [UUID] = []
        controller.openNodeHandler = { opened.append($0) }
        controller.reload()
        await waitUntil { !controller.isLoading && controller.partCount > 0 }
        controller.openPart(index: 0)
        controller.openPart(index: 9)
        controller.openPart(index: -1)
        XCTAssertEqual(opened, [ids[1]])
    }

    func testStaleBannerAppearsAfterTextChangeAndReloadClearsIt() async throws {
        let controller = makeController()
        controller.reload()
        await waitUntil { !controller.isLoading && controller.partCount > 0 }
        controller.checkStale()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(controller.isStale)
        try "Changed text".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        controller.checkStale()
        await waitUntil { controller.isStale }
        controller.reload()
        await waitUntil { !controller.isLoading && !controller.isStale }
        XCTAssertTrue(controller.html.contains("Changed text"))
    }

    func testGroupScopeSkipsDisabledBranchesAndMissingGroup() async throws {
        var group = ManuscriptNode(kind: .group, title: "G")
        var inner: ManuscriptNode?
        try store.update { project in
            inner = project.removeNode(id: self.ids[1])?.node
            var off = project.removeNode(id: self.ids[2])?.node
            off?.include = false
            group.children = [inner, off].compactMap { $0 }
            _ = project.insertNode(group, parent: nil, index: 0)
        }
        let innerID = try XCTUnwrap(inner?.id)
        let controller = makeController(scope: .group(group.id))
        XCTAssertEqual(controller.currentNodes().map(\.id), [innerID])
        XCTAssertTrue(makeController(scope: .group(UUID())).currentNodes().isEmpty)
    }
}
