import XCTest
@testable import LacEditor

@MainActor
final class WriterBoardControllerTests: XCTestCase {
    private var root: URL!
    private var store: ManuscriptProjectStore!
    private var preferences: AppPreferences!
    private var ids: [UUID] = []
    private var generateCalls = 0
    private var generateResult: Result<String, Error> = .success("AI text")
    private let prose = "The old river carried small boats toward the harbor every morning. Fishermen mended their nets on the quay. "
        + "Children ran along the water and watched the boats. The harbor master counted the catch at noon. "
        + "Gulls followed the boats back to the shore. Evening brought lanterns and quiet songs."

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] { try prose.write(to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8) }
        store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: ["a.md", "b.md", "c.md"])
        ids = store.project?.nodes.map(\.id) ?? []
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WriterBoardControllerTests-\(UUID().uuidString)"))
        preferences = AppPreferences(defaults: defaults)
        generateCalls = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(availability: AIAvailability = .available) -> WriterBoardController {
        WriterBoardController(
            store: store, wordCounts: { [:] }, windowManager: nil, preferences: preferences,
            aiAvailability: { availability }, loadKey: { _, _ in "key" },
            generate: { [unowned self] _, _, _, _, _ in
                self.generateCalls += 1
                switch self.generateResult {
                case let .success(text): return AIWritingResult(suggestions: [], report: text, image: nil)
                case let .failure(error): throw error
                }
            })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Условие не выполнилось вовремя", file: file, line: line)
    }

    private func order() -> [UUID] { store.project?.nodes.map(\.id) ?? [] }

    // MARK: Правка

    func testCommitEditingWritesSynopsisAndEmptyBecomesNil() {
        let controller = makeController()
        controller.beginEditing(ids[0])
        controller.editingText = "New synopsis"
        controller.commitEditing()
        XCTAssertNil(controller.editingSynopsis)
        XCTAssertEqual(store.node(id: ids[0])?.synopsis, "New synopsis")
        controller.beginEditing(ids[0])
        controller.editingText = ""
        controller.commitEditing()
        XCTAssertNil(store.node(id: ids[0])?.synopsis)
    }

    func testCancelEditingKeepsSynopsis() {
        let controller = makeController()
        controller.beginEditing(ids[0])
        controller.editingText = "Discarded"
        controller.cancelEditing()
        XCTAssertNil(controller.editingSynopsis)
        XCTAssertNil(store.node(id: ids[0])?.synopsis)
    }

    // MARK: Порядок

    func testMoveUsesVisibleNeighborWithFilter() throws {
        try store.update { project in
            _ = project.mutateNode(id: self.ids[0]) { $0.tags = ["x"] }
            _ = project.mutateNode(id: self.ids[2]) { $0.tags = ["x"] }
        }
        let controller = makeController()
        controller.filter.tag = "x"
        XCTAssertEqual(controller.visibleCards.map(\.id), [ids[0], ids[2]])
        controller.move(ids[0], step: 1)
        XCTAssertEqual(order(), [ids[1], ids[2], ids[0]])
        controller.move(ids[0], step: 1)
        XCTAssertEqual(order(), [ids[1], ids[2], ids[0]])
    }

    func testMoveByTwoStepsAndDrop() {
        let controller = makeController()
        controller.move(ids[0], step: 2)
        XCTAssertEqual(order(), [ids[1], ids[2], ids[0]])
        controller.drop(ids[0], onto: ids[1], placeAfter: false)
        XCTAssertEqual(order(), [ids[0], ids[1], ids[2]])
    }

    func testMoveIsBlockedWhileEditing() {
        let controller = makeController()
        controller.beginEditing(ids[1])
        controller.move(ids[0], step: 1)
        XCTAssertEqual(order(), ids)
    }

    // MARK: Описания

    func testAlgorithmDraftAcceptWritesToManifestOnlyOnAccept() async {
        let controller = makeController()
        controller.suggestSynopsis(for: ids[0])
        await waitUntil { controller.drafts[self.ids[0]] != nil }
        XCTAssertEqual(controller.drafts[ids[0]]?.source, .algorithm)
        XCTAssertNil(store.node(id: ids[0])?.synopsis)
        let text = controller.drafts[ids[0]]?.text
        controller.accept(ids[0])
        XCTAssertEqual(store.node(id: ids[0])?.synopsis, text)
        XCTAssertNil(controller.drafts[ids[0]])
    }

    func testRejectDropsDraftWithoutWriting() async {
        let controller = makeController()
        controller.suggestSynopsis(for: ids[1])
        await waitUntil { controller.drafts[self.ids[1]] != nil }
        controller.reject(ids[1])
        XCTAssertNil(controller.drafts[ids[1]])
        XCTAssertNil(store.node(id: ids[1])?.synopsis)
    }

    func testAIDraftIsMarkedAndTrimmed() async {
        generateResult = .success("  AI text \n")
        let controller = makeController()
        controller.suggestSynopsisWithAI(for: ids[0])
        await waitUntil { controller.drafts[self.ids[0]] != nil }
        XCTAssertEqual(controller.drafts[ids[0]], WriterBoardController.Draft(text: "AI text", source: .ai))
        XCTAssertEqual(generateCalls, 1)
    }

    func testAIUnavailableDoesNothing() {
        let controller = makeController(availability: .noModel)
        controller.suggestSynopsisWithAI(for: ids[0])
        XCTAssertTrue(controller.busy.isEmpty)
        XCTAssertEqual(generateCalls, 0)
    }

    func testAIErrorIsShownAndNoDraft() async {
        generateResult = .failure(AIError.invalidResponse)
        let controller = makeController()
        controller.suggestSynopsisWithAI(for: ids[0])
        await waitUntil { controller.lastError != nil }
        XCTAssertNil(controller.drafts[ids[0]])
        XCTAssertEqual(controller.lastErrorCard, ids[0])
        controller.clearError()
        XCTAssertNil(controller.lastError)
    }

    func testOversizeWaitsForConfirmation() async throws {
        let big = String(repeating: "The river ran slowly past the quiet village today. ", count: 1200)
        try big.write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let controller = makeController()
        controller.suggestSynopsisWithAI(for: ids[0])
        await waitUntil { controller.oversize != nil }
        XCTAssertEqual(generateCalls, 0)
        XCTAssertEqual(controller.oversize?.id, ids[0])
        controller.suggestSynopsisWithAI(for: ids[0], ignoreSize: true)
        await waitUntil { controller.drafts[self.ids[0]] != nil }
        XCTAssertEqual(generateCalls, 1)
        XCTAssertNil(controller.oversize)
    }

    func testDraftsOfDeletedNodesAreDropped() async throws {
        let controller = makeController()
        controller.suggestSynopsis(for: ids[1])
        await waitUntil { controller.drafts[self.ids[1]] != nil }
        try store.update { _ = $0.removeNode(id: self.ids[1]) }
        controller.refresh()
        XCTAssertNil(controller.drafts[ids[1]])
        XCTAssertEqual(controller.cards.map(\.id), [ids[0], ids[2]])
    }

    func testCancelAllDiscardsLateResult() async {
        let controller = makeController()
        controller.suggestSynopsis(for: ids[0])
        controller.cancelAll()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(controller.drafts[ids[0]])
        XCTAssertTrue(controller.busy.isEmpty)
    }
}
