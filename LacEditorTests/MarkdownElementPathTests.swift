import AppKit
import Combine
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownElementPathTests: XCTestCase {
    private typealias Kind = MarkdownElement.Kind

    private func kinds(_ path: MarkdownElementPath) -> [Kind] { path.elements.map(\.kind) }

    /// Позиция в UTF-16: начало подстроки плюс смещение.
    private func location(_ source: String, _ marker: String, offset: Int = 0) -> Int {
        let range = (source as NSString).range(of: marker)
        XCTAssertNotEqual(range.location, NSNotFound, marker)
        return range.location + offset
    }

    private func path(_ source: String, _ marker: String, offset: Int = 0, wiki: Bool = false) -> [Kind] {
        let result = MarkdownPresentationParser.parse(source, includeWikiLinks: wiki)
        return kinds(result.elements.path(at: location(source, marker, offset: offset)))
    }

    // MARK: Чистый индекс

    func testNestedOrderOuterBeforeInner() {
        let index = MarkdownElementIndex(textLength: 100, blocks: [
            (NSRange(location: 10, length: 10), .listItem),
            (NSRange(location: 10, length: 40), .quote),
            (NSRange(location: 10, length: 10), .table)
        ], inlines: [])
        XCTAssertEqual(kinds(index.path(at: 12)), [.quote, .listItem, .table])
        XCTAssertEqual(kinds(index.path(at: 30)), [.quote])
    }

    func testBlockBoundariesAreHalfOpenWithEOFException() {
        let index = MarkdownElementIndex(textLength: 20, blocks: [(NSRange(location: 5, length: 10), .quote)], inlines: [])
        XCTAssertTrue(index.path(at: 4).isEmpty)
        XCTAssertFalse(index.path(at: 5).isEmpty)
        XCTAssertFalse(index.path(at: 14).isEmpty)
        XCTAssertTrue(index.path(at: 15).isEmpty)
        let afterBreak = MarkdownElementIndex(textLength: 20, blocks: [(NSRange(location: 15, length: 5), .quote)], inlines: [],
                                              endsWithLineBreak: true)
        XCTAssertTrue(afterBreak.path(at: 20).isEmpty)
        let tail = MarkdownElementIndex(textLength: 20, blocks: [(NSRange(location: 15, length: 5), .quote)], inlines: [])
        XCTAssertFalse(tail.path(at: 20).isEmpty)
        XCTAssertTrue(tail.path(at: 21).isEmpty)
    }

    func testInlineBoundariesAreStrict() {
        let index = MarkdownElementIndex(textLength: 30, blocks: [], inlines: [
            (NSRange(location: 5, length: 10), .strong), (NSRange(location: 7, length: 4), .code)
        ])
        XCTAssertTrue(index.path(at: 5).isEmpty)
        XCTAssertEqual(kinds(index.path(at: 6)), [.strong])
        XCTAssertEqual(kinds(index.path(at: 8)), [.strong, .code])
        XCTAssertEqual(kinds(index.path(at: 11)), [.strong])
        XCTAssertEqual(kinds(index.path(at: 14)), [.strong])
        XCTAssertTrue(index.path(at: 15).isEmpty)
    }

    func testSameFamilyBlocksCollapseWithLevel() {
        let nested = MarkdownElementIndex(textLength: 100, blocks: [
            (NSRange(location: 0, length: 90), .listItem), (NSRange(location: 5, length: 60), .listItem),
            (NSRange(location: 10, length: 20), .listItem)
        ], inlines: [])
        XCTAssertEqual(nested.path(at: 12).elements, [MarkdownElement(kind: .listItem, level: 3)])
        let mixed = MarkdownElementIndex(textLength: 100, blocks: [
            (NSRange(location: 0, length: 90), .quote), (NSRange(location: 5, length: 60), .listItem),
            (NSRange(location: 10, length: 20), .quote)
        ], inlines: [])
        XCTAssertEqual(kinds(mixed.path(at: 12)), [.quote, .listItem, .quote])
        let alert = MarkdownElementIndex(textLength: 100, blocks: [
            (NSRange(location: 0, length: 90), .quote), (NSRange(location: 5, length: 60), .alert)
        ], inlines: [])
        XCTAssertEqual(alert.path(at: 12).elements, [MarkdownElement(kind: .alert, level: 2)])
    }

    func testInvalidAndOverlappingEntriesAreIgnoredSafely() {
        let index = MarkdownElementIndex(textLength: 50, blocks: [
            (NSRange(location: 5, length: 0), .quote), (NSRange(location: -3, length: 10), .quote),
            (NSRange(location: 45, length: 10), .quote), (NSRange(location: NSNotFound, length: 1), .quote),
            (NSRange(location: 0, length: 20), .table), (NSRange(location: 10, length: 20), .htmlBlock)
        ], inlines: [])
        XCTAssertEqual(kinds(index.path(at: 5)), [.table])
        XCTAssertEqual(kinds(index.path(at: 25)), [.htmlBlock])
        XCTAssertTrue(index.path(at: 47).isEmpty)
        XCTAssertTrue(index.path(at: 60).isEmpty)
        XCTAssertTrue(index.path(at: -1).isEmpty)
        XCTAssertTrue(MarkdownElementIndex.empty.path(at: 0).isEmpty)
    }

    func testLargeIndexLookup() {
        let count = 50_000
        let blocks = (0..<count).map { (NSRange(location: $0 * 10, length: 9), Kind.listItem) }
        let index = MarkdownElementIndex(textLength: count * 10, blocks: blocks, inlines: [])
        var generator = SystemRandomNumberGenerator()
        let positions = [0, 5, count * 5, count * 10 - 2] + (0..<5_000).map { _ in Int.random(in: 0..<(count * 10), using: &generator) }
        let started = Date()
        for position in positions {
            let expected = position % 10 < 9
            XCTAssertEqual(index.path(at: position).isEmpty, !expected, "\(position)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    // MARK: Разбор

    func testHeadingWithBoldAndLink() {
        let source = "## Заголовок **жирный** [ссылка](https://example.com)\n\nтекст\n"
        XCTAssertEqual(path(source, "жирный"), [.heading(2), .strong])
        XCTAssertEqual(path(source, "ссылка"), [.heading(2), .link])
        XCTAssertEqual(path(source, "Заголовок"), [.heading(2)])
        let newline = (source as NSString).range(of: "\n").location
        XCTAssertEqual(kinds(MarkdownPresentationParser.parse(source).elements.path(at: newline)), [.heading(2)])
        XCTAssertEqual(path(source, "\n\nтекст", offset: 1), [])
        XCTAssertEqual(path(source, "текст"), [])
    }

    func testQuoteListTaskCodeTableFootnoteMath() {
        let source = """
        ---
        title: x
        ---

        > quote text

        > [!NOTE]
        > alert text

        - item one
          - nested item

        - [x] done task

        ```swift
        let a = 1
        ```

        ```
        plain code
        ```

        | a | b |
        | - | - |
        | 1 | 2 |

        $$
        x^2
        $$

        <div>html block</div>

        Footnote ref[^1].

        [^1]: footnote text
        """
        XCTAssertEqual(path(source, "title"), [.frontMatter])
        XCTAssertEqual(path(source, "quote text"), [.quote])
        XCTAssertEqual(path(source, "alert text"), [.alert])
        XCTAssertEqual(path(source, "item one"), [.listItem])
        XCTAssertEqual(path(source, "nested item"), [.listItem])
        XCTAssertEqual(path(source, "done task"), [.task])
        XCTAssertEqual(path(source, "let a"), [.codeBlock("swift")])
        XCTAssertEqual(path(source, "plain code"), [.codeBlock(nil)])
        XCTAssertEqual(path(source, "| 1 | 2 |", offset: 2), [.table])
        XCTAssertEqual(path(source, "x^2"), [.mathBlock])
        XCTAssertEqual(path(source, "html block"), [.htmlBlock])
        XCTAssertEqual(path(source, "footnote text"), [.footnoteDefinition])
        XCTAssertEqual(path(source, "Footnote ref"), [])
    }

    func testFootnoteReferenceIsNotLink() {
        let source = "Text[^1] end.\n\n[^1]: note\n"
        let found = path(source, "[^1]", offset: 2)
        XCTAssertEqual(found, [.footnoteReference])
    }

    func testUTF16CoordinatesWithEmojiAndChinese() {
        let source = "你好 😀 **加粗** 😀 tail"
        XCTAssertEqual(path(source, "加粗"), [.strong])
        XCTAssertEqual(path(source, "😀 tail"), [])
        XCTAssertEqual(path(source, "你好"), [])
    }

    func testCRLFAndTabLines() {
        let source = "# Title **bold**\r\n\r\n> quote\twith tab\r\n\r\n- item\twith tab\r\n"
        XCTAssertEqual(path(source, "bold"), [.heading(1), .strong])
        XCTAssertEqual(path(source, "quote"), [.quote])
        XCTAssertEqual(path(source, "item"), [.listItem])
    }

    func testNoInlinesInsideTableCellsAndFootnoteDefinitions() {
        let source = "| a |\n| - |\n| **cell** |\n\nRef[^1]\n\n[^1]: **note**\n"
        XCTAssertEqual(path(source, "cell"), [.table])
        XCTAssertEqual(path(source, "note"), [.footnoteDefinition])
    }

    func testResultSurvivesHeadingNumberingAndEmojiResolution() {
        let source = "# Title **b**\n"
        let parsed = MarkdownPresentationParser.parse(source)
        let at = location(source, "b**")
        XCTAssertEqual(kinds(parsed.elements.path(at: at)), [.heading(1), .strong])
        XCTAssertEqual(kinds(parsed.numberingHeadings(true).elements.path(at: at)), [.heading(1), .strong])
        XCTAssertEqual(kinds(parsed.resolvingHeadingEmoji([:]).elements.path(at: at)), [.heading(1), .strong])
        XCTAssertEqual(kinds(parsed.withWikiLinks([]).elements.path(at: at)), [.heading(1), .strong])
    }

    func testWikiLinkAppearsAsLink() {
        let source = "See [[Файл]] here\n"
        XCTAssertEqual(path(source, "Файл", wiki: true), [.link])
    }

    // MARK: Документ

    func testSetMarkdownElementPathDoesNotPublishEqualValue() {
        let document = EditorDocument(text: "x", language: .markdown)
        var publishes = 0
        let cancellable = document.$markdownElementPath.dropFirst().sink { _ in publishes += 1 }
        let path = MarkdownElementPath(elements: [MarkdownElement(kind: .quote)])
        document.setMarkdownElementPath(path)
        document.setMarkdownElementPath(path)
        XCTAssertEqual(publishes, 1)
        document.setMarkdownElementPath(MarkdownElementPath(elements: []))
        XCTAssertNil(document.markdownElementPath)
        XCTAssertEqual(publishes, 2)
        document.setMarkdownElementPath(nil)
        XCTAssertEqual(publishes, 2)
        cancellable.cancel()
    }

    func testPathClearedByLanguageButNotByTyping() {
        let document = EditorDocument(text: "x", language: .markdown)
        document.setMarkdownElementPath(MarkdownElementPath(elements: [MarkdownElement(kind: .quote)]))
        document.noteLiveEdit(isEmpty: false)
        XCTAssertNotNil(document.markdownElementPath)
        document.language = .json
        XCTAssertNil(document.markdownElementPath)
    }

    // MARK: Контроллер

    private var keptAlive: [AnyObject] = []

    private func makeController(_ source: String) -> (LacTextView, NSTextStorage, FoldLayoutManager, MarkdownPresentationController) {
        _ = NSApplication.shared
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
        view.font = lacEditorFont(size: 14)
        keptAlive += [storage, layout, container]
        return (view, storage, layout, MarkdownPresentationController(textView: view, layout: layout))
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testControllerPublishesPathInSourceModeWhenEnabled() async throws {
        let source = "# Title\n\nSome **bold** text\n"
        let (view, storage, _, controller) = makeController(source)
        let document = EditorDocument(text: source, language: .markdown)
        view.setSelectedRange(NSRange(location: location(source, "bold", offset: 1), length: 0))
        controller.setElementPathEnabled(true)
        controller.update(document: document, enabled: false, outlineVisible: false, isActive: true, revision: 0, currentRevision: { 0 })
        try await waitUntil { document.markdownElementPath != nil }
        XCTAssertEqual(document.markdownElementPath?.elements.map(\.kind), [.strong])
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(storage.string, source)
    }

    func testControllerDisabledByDefaultDoesNotParse() {
        let source = "Some **bold** text"
        let (_, _, _, controller) = makeController(source)
        let document = EditorDocument(text: source, language: .markdown)
        controller.update(document: document, enabled: false, outlineVisible: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(controller.work)
    }

    func testPathStaysWhileTypingAndUpdatesAfterReparse() async throws {
        let source = "Some **bold** text"
        let (view, storage, _, controller) = makeController(source)
        let document = EditorDocument(text: source, language: .markdown)
        view.setSelectedRange(NSRange(location: location(source, "bold", offset: 1), length: 0))
        controller.setElementPathEnabled(true)
        var revision: UInt = 0
        controller.update(document: document, enabled: false, outlineVisible: false, isActive: true, revision: revision, currentRevision: { revision })
        try await waitUntil { document.markdownElementPath != nil }
        XCTAssertNotNil(document.markdownElementPath)

        let edit = NSRange(location: (source as NSString).length, length: 0)
        controller.beforeEdit(range: edit, replacementLength: 1)
        storage.replaceCharacters(in: edit, with: "!")
        revision += 1
        controller.edited(revision: revision)
        XCTAssertNotNil(document.markdownElementPath)
        view.setSelectedRange(NSRange(location: edit.location + 1, length: 0))
        controller.selectionChanged()
        XCTAssertNotNil(document.markdownElementPath, "до готовности нового разбора показанный путь остаётся")
        try await waitUntil { document.markdownElementPath == nil }
        XCTAssertNil(document.markdownElementPath)
    }

    func testSelectionRangeAndMultipleSelectionsHidePath() async throws {
        let source = "Some **bold** text and *it*"
        let (view, _, _, controller) = makeController(source)
        let document = EditorDocument(text: source, language: .markdown)
        let inside = location(source, "bold", offset: 1)
        view.setSelectedRange(NSRange(location: inside, length: 0))
        controller.setElementPathEnabled(true)
        controller.update(document: document, enabled: false, outlineVisible: false, isActive: true, revision: 0, currentRevision: { 0 })
        try await waitUntil { document.markdownElementPath != nil }
        XCTAssertNotNil(document.markdownElementPath)

        view.setSelectedRange(NSRange(location: inside, length: 2))
        controller.selectionChanged()
        XCTAssertNil(document.markdownElementPath)
        view.setSelectedRange(NSRange(location: inside, length: 0))
        controller.selectionChanged()
        XCTAssertNotNil(document.markdownElementPath)
        view.setSelectedRanges([NSValue(range: NSRange(location: inside, length: 0)),
                                NSValue(range: NSRange(location: location(source, "it", offset: 1), length: 0))],
                               affinity: .downstream, stillSelecting: false)
        controller.selectionChanged()
        XCTAssertNil(document.markdownElementPath)
    }

    func testNonMarkdownAndLargeProfileNeverPublish() async throws {
        let source = "Some **bold** text"
        let (view, _, _, controller) = makeController(source)
        let document = EditorDocument(text: source, language: .json)
        view.setSelectedRange(NSRange(location: location(source, "bold", offset: 1), length: 0))
        controller.setElementPathEnabled(true)
        controller.update(document: document, enabled: false, outlineVisible: false, isActive: true, revision: 0, currentRevision: { 0 })
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(document.markdownElementPath)

        // Большой профиль: координатор передаёт false, показанный путь снимается.
        let markdown = EditorDocument(text: source, language: .markdown)
        markdown.setMarkdownElementPath(MarkdownElementPath(elements: [MarkdownElement(kind: .strong)]))
        controller.update(document: markdown, enabled: false, outlineVisible: false, isActive: true, revision: 0, currentRevision: { 0 })
        controller.setElementPathEnabled(false)
        try await waitUntil { markdown.markdownElementPath == nil }
        XCTAssertNil(markdown.markdownElementPath)
    }

    // MARK: Подписи

    func testElementTitlesUseL10n() {
        XCTAssertEqual(MarkdownElement(kind: .heading(2)).title, L10n.tr("标题 %@ 级", "2"))
        XCTAssertEqual(MarkdownElement(kind: .listItem, level: 3).title, L10n.tr("%@（第 %@ 层）", L10n.tr("列表项"), "3"))
        XCTAssertEqual(MarkdownElement(kind: .codeBlock("swift")).title, L10n.tr("代码块（%@）", "swift"))
        XCTAssertEqual(MarkdownElement(kind: .codeBlock(nil)).title, L10n.tr("代码块"))
        let elements = [Kind.quote, .listItem, .codeBlock(nil), .table, .strong].map { MarkdownElement(kind: $0) }
        let text = MarkdownElementPath(elements: elements).displayText
        XCTAssertTrue(text.hasPrefix("… › "))
        XCTAssertFalse(text.contains(L10n.tr("引用")))
        XCTAssertEqual(MarkdownElementPath(elements: Array(elements.suffix(2))).displayText,
                       elements.suffix(2).map(\.title).joined(separator: " › "))
    }
}
