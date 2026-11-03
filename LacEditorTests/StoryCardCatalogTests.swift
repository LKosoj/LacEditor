import XCTest
@testable import LacEditor

@MainActor
final class StoryCardCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StoryCardCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("World"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testScannerFindsCardsAndSkipsManuscriptFiles() throws {
        try write("World/Anna.md", "---\ntype: character\n---\n# Anna\n")
        try write("Chapter.md", "---\ntype: character\n---\n# Scene\n")
        try write("notes.md", "# Plain\n")
        var cache = StoryCardScanCache()
        let cards = StoryCardScanner.scan(root: root, excluding: ["Chapter.md"], cache: &cache)
        XCTAssertEqual(cards.map(\.title), ["Anna"])
        // Файлы рукописи в кэш не попадают: только Anna.md и notes.md.
        XCTAssertEqual(cache.entries.count, 2)
    }

    func testDuplicateIDKeepsFirstCardID() throws {
        let id = UUID().uuidString
        try write("World/A.md", "---\ntype: character\nid: \(id)\n---\n# A\n")
        try write("World/B.md", "---\ntype: place\nid: \(id)\n---\n# B\n")
        var cache = StoryCardScanCache()
        let cards = StoryCardScanner.scan(root: root, excluding: [], cache: &cache)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.filter { $0.cardID != nil }.count, 1)
    }

    func testCatalogRefreshAndResolve() async throws {
        let id = UUID()
        try write("World/Anna.md", "---\ntype: character\nid: \(id.uuidString)\naliases: [Annie]\n---\n# Anna\n")
        let catalog = StoryCardCatalog()
        catalog.refresh(root: root, manuscriptPaths: [])
        for _ in 0..<100 where catalog.cards.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(catalog.cards.count, 1)
        XCTAssertEqual(catalog.resolve(reference: id.uuidString)?.title, "Anna")
        XCTAssertEqual(catalog.resolve(reference: "annie")?.title, "Anna")
        XCTAssertNil(catalog.resolve(reference: "Boris"))
        let card = try XCTUnwrap(catalog.cards.first)
        XCTAssertEqual(StoryCardCatalog.reference(for: card), id.uuidString)
        XCTAssertNotNil(catalog.card(forURL: card.url))
    }
}
