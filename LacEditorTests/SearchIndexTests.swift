import XCTest
@testable import LacEditor

final class SearchIndexTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(SearchDatabase.fts5Available(), "FTS5 недоступен")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("root"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SearchDatabase.fts5Override = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var root: URL { directory.appendingPathComponent("root", isDirectory: true) }

    private func makeIndex() -> SearchIndex {
        SearchIndex(databaseURL: directory.appendingPathComponent("db/index.sqlite"), root: root)
    }

    @discardableResult
    private func write(_ name: String, _ text: String, mtime: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
        return url
    }

    private func refresh(_ index: SearchIndex) async throws -> SearchIndexer.Report {
        try await SearchIndexer.refresh(index, root: root, progress: { _ in }, isCancelled: { false })
    }

    private func paths(_ hits: [SearchIndexHit]) -> [String] { hits.map(\.path) }

    // MARK: Формы слов в трёх языках

    func testEnglishWordForms() async throws {
        try write("a.md", "She wrote a long letter yesterday.")
        let index = makeIndex()
        _ = try await refresh(index)
        let hits = try await index.search("writing letters", limit: 10)
        XCTAssertEqual(paths(hits), ["a.md"])
    }

    func testRussianWordForms() async throws {
        try write("r.md", "Он писал письма по вечерам.")
        let index = makeIndex()
        _ = try await refresh(index)
        let hits = try await index.search("письмо", limit: 10)
        XCTAssertEqual(paths(hits), ["r.md"])
    }

    func testChineseWords() async throws {
        try write("z.md", "他昨天写了一封很长的信。")
        let index = makeIndex()
        _ = try await refresh(index)
        let hits = try await index.search("写", limit: 10)
        XCTAssertEqual(paths(hits), ["z.md"])
    }

    // MARK: Обновление

    func testDeletedFileDisappearsAfterRefresh() async throws {
        let url = try write("gone.md", "unique banana text")
        let index = makeIndex()
        _ = try await refresh(index)
        let before = try await index.search("banana", limit: 10)
        XCTAssertEqual(paths(before), ["gone.md"])
        try FileManager.default.removeItem(at: url)
        _ = try await refresh(index)
        let after = try await index.search("banana", limit: 10)
        XCTAssertTrue(after.isEmpty)
    }

    func testChangedFileIsReindexed() async throws {
        try write("c.md", "apple orchard", mtime: Date(timeIntervalSince1970: 1_000_000))
        let index = makeIndex()
        _ = try await refresh(index)
        try write("c.md", "cherry orchard here", mtime: Date(timeIntervalSince1970: 2_000_000))
        _ = try await refresh(index)
        let apple = try await index.search("apple", limit: 10)
        let cherry = try await index.search("cherry", limit: 10)
        XCTAssertTrue(apple.isEmpty)
        XCTAssertEqual(paths(cherry), ["c.md"])
    }

    func testSymlinkIsNotIndexed() async throws {
        let outside = directory.appendingPathComponent("outside.md")
        try "secret pineapple".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside)
        let index = makeIndex()
        _ = try await refresh(index)
        let hits = try await index.search("pineapple", limit: 10)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: Ранжирование и открытые документы

    func testBm25PrefersDenserMatch() async throws {
        try write("many.md", "tiger tiger tiger hunts at night")
        try write("few.md", "A long story about a village, a river, a bridge, a market and finally one tiger appears.")
        let index = makeIndex()
        _ = try await refresh(index)
        let hits = try await index.search("tiger", limit: 10)
        XCTAssertEqual(paths(hits).first, "many.md")
        XCTAssertEqual(Set(paths(hits)), ["many.md", "few.md"])
    }

    func testLiveDocumentOverridesDisk() async throws {
        try write("l.md", "old content about oranges")
        let index = makeIndex()
        _ = try await refresh(index)
        let chunks = SearchIndexChunker.chunks(in: "new content about lemons", fileTitle: "l.md")
        let live = [SearchLiveDocument(path: "l.md", documentID: UUID(), revision: 1, chunks: chunks)]
        let lemons = try await index.search(SearchQuery(text: "lemons"), limit: 10, live: live)
        let oranges = try await index.search(SearchQuery(text: "oranges"), limit: 10, live: live)
        XCTAssertEqual(paths(lemons), ["l.md"])
        XCTAssertTrue(lemons.first?.isLive == true)
        XCTAssertTrue(oranges.isEmpty)
    }

    func testLateWriterIsRejected() async throws {
        let index = makeIndex()
        try await index.prepare()
        let started = Date().timeIntervalSince1970
        let fresh = try await index.replace(path: "f.md", stamp: SearchIndexFileStamp(mtime: 200, size: 10),
                                            chunks: SearchIndexChunker.chunks(in: "alpha beta", fileTitle: "f.md"), readStarted: started)
        // Чтение начато раньше записи в индекс: этот писатель опоздал.
        let late = try await index.replace(path: "f.md", stamp: SearchIndexFileStamp(mtime: 100, size: 10),
                                           chunks: SearchIndexChunker.chunks(in: "gamma", fileTitle: "f.md"), readStarted: started - 10)
        XCTAssertTrue(fresh)
        XCTAssertFalse(late)
        let stale = try await index.search("gamma", limit: 10)
        XCTAssertTrue(stale.isEmpty)
    }

    func testFileReplacedWithOlderDateIsReindexed() async throws {
        let url = try write("old.md", "first version pears", mtime: Date(timeIntervalSince1970: 2_000_000))
        let index = makeIndex()
        _ = try await refresh(index)
        // Как после `cp -p`: новый текст, но дата старше прежней.
        try "second version plums".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        _ = try await refresh(index)
        let pears = try await index.search("pears", limit: 10)
        let plums = try await index.search("plums", limit: 10)
        XCTAssertTrue(pears.isEmpty)
        XCTAssertEqual(paths(plums), ["old.md"])
    }

    // MARK: Запрос

    func testMatchEscaping() async throws {
        try write("e.md", "plain words and AND near things")
        let index = makeIndex()
        _ = try await refresh(index)
        for raw in ["\"", "*", "AND", "NEAR(", "(", "a\"b", "word OR", "col:x", "-x"] {
            _ = try await index.search(raw, limit: 10)
        }
        let query = SearchQuery(text: "a\"b AND NEAR(")
        XCTAssertFalse(query.matchExpression(joiner: .and).contains("NEAR("))
    }

    func testExpansionGoesIntoMatchViaOr() {
        let query = SearchQuery(text: "joy", expansion: ["gladness", "delight"])
        let expression = query.matchExpression(joiner: .and)
        XCTAssertTrue(expression.hasPrefix("(\"joy\") OR "))
        // Расширение сводится к основе так же, как индекс: «gladness» → «glad».
        XCTAssertTrue(expression.contains("\"glad\""))
        XCTAssertEqual(query.allTerms.count, 3)
    }

    func testAndFallsBackToOr() async throws {
        try write("o.md", "only mango here")
        let index = makeIndex()
        _ = try await refresh(index)
        let hits = try await index.search("mango kiwi", limit: 10)
        XCTAssertEqual(paths(hits), ["o.md"])
    }

    func testExpansionFindsRelatedWord() async throws {
        try write("x.md", "pure gladness filled the room")
        let index = makeIndex()
        _ = try await refresh(index)
        let plain = try await index.search(SearchQuery(text: "joy"), limit: 10, live: [])
        let expanded = try await index.search(SearchQuery(text: "joy", expansion: ["gladness"]), limit: 10, live: [])
        XCTAssertTrue(plain.isEmpty)
        XCTAssertEqual(paths(expanded), ["x.md"])
    }

    // MARK: Нарезка

    func testChunkerHeadingsAndFences() {
        let text = "# Part\n\nHello world.\n\n## Sub\n\n```\n# not heading\n```\n\nTail text."
        let chunks = SearchIndexChunker.chunks(in: text, fileTitle: "f.md")
        XCTAssertTrue(chunks.contains { $0.title == "Part › Sub" })
        XCTAssertFalse(chunks.contains { $0.title.contains("not heading") })
        XCTAssertEqual(chunks.first?.line, 1)
    }

    func testChunkerSplitsLongTextWithinLimit() {
        let text = String(repeating: "word. ", count: 800)
        let chunks = SearchIndexChunker.chunks(in: text, fileTitle: "f.md")
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks { XCTAssertLessThanOrEqual((chunk.raw as NSString).length, SearchIndexChunker.maxChunkUnits + 50) }
    }

    func testChunkerCRLFLines() {
        let chunks = SearchIndexChunker.chunks(in: "# Title\r\n\r\nfirst line\r\nsecond line\r\n\r\nnext paragraph", fileTitle: "f.md")
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.last?.endLine, 6)
        XCTAssertFalse(chunks.contains { $0.raw.contains("\r") })
    }

    func testChunkerChineseWithoutSpaces() {
        let chunks = SearchIndexChunker.chunks(in: "# 标题\n\n他昨天写了一封很长的信，然后寄给了远方的朋友。", fileTitle: "f.md")
        XCTAssertTrue(chunks.contains { $0.title == "标题" })
        XCTAssertTrue(chunks.contains { !$0.body.isEmpty && $0.tokenCount > 0 })
    }

    @MainActor
    func testControllerLineNumbersMatchChunker() {
        // U+2028, U+2029 и U+0085 не разделители строк: номера строк должны совпасть с нарезкой.
        let text = "one\u{2028}two\u{2029}three\u{85}four\r\nfive\rsix\nseven" as NSString
        XCTAssertEqual(WordSearchController.lineStart(1, in: text), 0)
        XCTAssertEqual(WordSearchController.lineStart(2, in: text), text.range(of: "five").location)
        XCTAssertEqual(WordSearchController.lineStart(3, in: text), text.range(of: "six").location)
        XCTAssertEqual(WordSearchController.lineStart(4, in: text), text.range(of: "seven").location)
        XCTAssertNil(WordSearchController.lineStart(5, in: text))
        let chunks = SearchIndexChunker.chunks(in: text as String, fileTitle: "f.md")
        XCTAssertEqual(chunks.last?.endLine, 4)
    }

    func testChunkerEmptyText() {
        XCTAssertTrue(SearchIndexChunker.chunks(in: "", fileTitle: "f.md").isEmpty)
    }

    // MARK: Расширение запроса и подсветка

    func testExpansionParse() {
        let json = #"{"words": ["gladness", "happy joy", "joy", "радость", "delight", "delight", "mirth!"]}"#
        let words = SearchExpansionBuilder.parse(json, query: "joy")
        XCTAssertEqual(words, ["gladness", "delight"])
        XCTAssertTrue(SearchExpansionBuilder.parse("not json", query: "joy").isEmpty)
    }

    func testExcerptHighlightsTerms() {
        let raw = String(repeating: "filler ", count: 60) + "the tiger runs " + String(repeating: "more ", count: 60)
        let excerpt = SearchHighlight.excerpt(from: raw, terms: ["tiger"], limit: 80)
        XCTAssertTrue(excerpt.text.hasPrefix("…"))
        XCTAssertEqual(excerpt.ranges.count, 1)
        let range = excerpt.ranges[0]
        XCTAssertEqual((excerpt.text as NSString).substring(with: range), "tiger")
    }

    // MARK: Отказоустойчивость

    func testSchemaV1MigratesToV2() async throws {
        let url = directory.appendingPathComponent("db/index.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let old = try SearchDatabase(url: url)
            try old.exec("""
                CREATE TABLE files(path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL, chunk_count INTEGER NOT NULL, \
                token_count INTEGER NOT NULL, first_rowid INTEGER NOT NULL, last_rowid INTEGER NOT NULL) WITHOUT ROWID
                """)
            try old.exec("PRAGMA user_version = 1")
        }
        let index = SearchIndex(databaseURL: url, root: root)
        try await index.prepare()
        let written = try await index.replace(path: "m.md", stamp: SearchIndexFileStamp(mtime: 1, size: 5),
                                              chunks: SearchIndexChunker.chunks(in: "migrated text", fileTitle: "m.md"),
                                              readStarted: Date().timeIntervalSince1970)
        XCTAssertTrue(written)
        let hits = try await index.search("migrated", limit: 10)
        XCTAssertEqual(paths(hits), ["m.md"])
    }

    func testUnavailableFTS5ThrowsUnavailable() async throws {
        SearchDatabase.fts5Override = false
        XCTAssertFalse(SearchDatabase.fts5Available())
        let index = makeIndex()
        do {
            try await index.prepare()
            XCTFail("prepare должен бросить ошибку")
        } catch let error as SearchIndexError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        }
        do {
            _ = try await index.search("word", limit: 10)
            XCTFail("search должен бросить ошибку")
        } catch let error as SearchIndexError {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: WordSearchController

    @MainActor
    private func makeController(registry: SearchIndexRegistry, text: String, url: URL,
                                revealed: @escaping (FolderSearchService.Match) -> Void = { _ in }) -> WordSearchController {
        let document = FolderSearchService.OpenDocument(
            url: url, identity: DocumentFileIdentity.resolve(url),
            snapshot: DocumentTextSnapshot(documentID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, revision: 1, text: text))
        let controller = WordSearchController(
            snapshots: { [document] },
            open: { _ in document },
            reveal: { match, _ in revealed(match); return true },
            openFile: { _ in },
            registry: registry)
        controller.setRoot(root)
        return controller
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 25_000_000) }
    }

    @MainActor
    func testControllerDiscardsLateResult() async throws {
        let text = "tiger in the grass"
        let url = try write("late.md", text)
        let registry = SearchIndexRegistry(directory: directory.appendingPathComponent("registry"))
        _ = try await SearchIndexer.refresh(registry.index(for: root), root: root, progress: { _ in }, isCancelled: { false })
        let controller = makeController(registry: registry, text: text, url: url)
        controller.start(query: "tiger")
        controller.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(controller.hits.isEmpty)
        XCTAssertFalse(controller.hasSearched)
    }

    @MainActor
    func testControllerSelectCallsReveal() async throws {
        let text = "intro\n\nthe tiger sleeps"
        let url = try write("reveal.md", text)
        let registry = SearchIndexRegistry(directory: directory.appendingPathComponent("registry"))
        _ = try await SearchIndexer.refresh(registry.index(for: root), root: root, progress: { _ in }, isCancelled: { false })
        var revealed: FolderSearchService.Match?
        let controller = makeController(registry: registry, text: text, url: url) { revealed = $0 }
        controller.start(query: "tiger")
        await waitUntil { controller.hasSearched }
        let hit = try XCTUnwrap(controller.hits.first)
        await controller.select(hit)?.value
        XCTAssertEqual(revealed?.matchedText, "tiger")
    }

    func testLocalizationKeysExistInAllLanguages() throws {
        let keys = ["按词", "按含义（AI）", "索引更新中：%d / %d 个文件", "重建索引", "删除索引…", "选取来源",
                    "已添加 %d 个来源文件。", "未找到相关文件。", "此系统无法使用按词搜索。", "移除扩展词 %@"]
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = base.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                if language != "zh-Hans" {
                    XCTAssertNil(value.range(of: "\\p{Han}", options: .regularExpression), "\(language): \(key)")
                }
            }
        }
    }
}

/// Отдельный класс без пропуска по FTS5: на сборке без FTS5 этот тест должен падать, а не молча пропускаться.
final class SearchIndexAvailabilityTests: XCTestCase {
    func testFTS5IsAvailableOnThisBuild() {
        SearchDatabase.fts5Override = nil
        XCTAssertTrue(SearchDatabase.fts5Available())
    }
}
