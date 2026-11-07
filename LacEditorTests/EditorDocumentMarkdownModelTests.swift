import XCTest
@testable import LacEditor

/// Слот единой модели Markdown в документе: установка, сброс и выдача по версии текста.
@MainActor
final class EditorDocumentMarkdownModelTests: XCTestCase {
    private func makeModel(_ source: String) -> MarkdownDocumentModel {
        MarkdownDocumentModel(
            revision: nil, textLength: (source as NSString).length,
            options: .init(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: true),
            blocks: [], frontMatter: nil, unreliableRanges: [], headingIDs: [], namedAnchors: [], footnotes: [],
            looseIndents: [], smartReplacements: [], fence: nil, emoji: nil, readableText: nil, blockIndex: nil, elements: nil)
    }

    func testInstallsModelWhenSourceMatchesAndReturnsItForCurrentRevision() {
        let source = "# Заголовок 😀\r\nтекст"
        let document = EditorDocument(text: source, language: .markdown)
        XCTAssertTrue(document.installMarkdownModel(makeModel(source), source: source))
        let model = document.markdownModel(forRevision: document.textRevision)
        XCTAssertEqual(model?.revision, document.textRevision)
        XCTAssertEqual(model?.textLength, (source as NSString).length)
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision &+ 1))
    }

    func testRejectsModelWithDifferentSource() {
        let document = EditorDocument(text: "hello", language: .markdown)
        XCTAssertFalse(document.installMarkdownModel(makeModel("stale"), source: "stale"))
        XCTAssertFalse(document.installMarkdownModel(makeModel("hello"), source: "hellx"))
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision))
    }

    // Сброс слота при правке text отдельно не доказать: textRevision меняется там же, так что nil даёт и смена версии.
    func testTextEditResetsModelAndOldRevisionIsNotReturned() {
        let document = EditorDocument(text: "hello", language: .markdown)
        XCTAssertTrue(document.installMarkdownModel(makeModel("hello"), source: "hello"))
        let oldRevision = document.textRevision
        document.text = "hello!"
        XCTAssertNil(document.markdownModel(forRevision: oldRevision))
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision))
    }

    // Версия текста при смене языка не меняется, поэтому nil здесь доказывает именно сброс слота.
    func testLanguageChangeResetsModel() {
        let document = EditorDocument(text: "hello", language: .markdown)
        XCTAssertTrue(document.installMarkdownModel(makeModel("hello"), source: "hello"))
        document.language = .plainText
        document.language = .markdown
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision))
    }

    // Сброс слота в noteLiveEdit отдельно не доказать: пока есть живые правки, markdownModel(forRevision:) отдаёт nil,
    // а после синхронизации версия текста меняется.
    func testLiveEditResetsModel() {
        let document = EditorDocument(text: "hello", language: .markdown)
        XCTAssertTrue(document.installMarkdownModel(makeModel("hello"), source: "hello"))
        document.noteLiveEdit(isEmpty: false)
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision))
        document.cancelMetricsRefresh()
    }

    func testRejectsModelInLargeFileMode() {
        let document = EditorDocument(text: "hello", language: .markdown)
        document.performanceProfile = .large
        XCTAssertFalse(document.installMarkdownModel(makeModel("hello"), source: "hello"))
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision))
    }

    func testRejectsModelForNonMarkdownLanguage() {
        let document = EditorDocument(text: "hello", language: .plainText)
        XCTAssertFalse(document.installMarkdownModel(makeModel("hello"), source: "hello"))
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision))
    }

    func testRejectsModelWhileLiveEditsArePending() {
        let document = EditorDocument(text: "hello", language: .markdown)
        document.noteLiveEdit(isEmpty: false)
        XCTAssertFalse(document.installMarkdownModel(makeModel("hello"), source: "hello"))
        document.cancelMetricsRefresh()
    }
}
