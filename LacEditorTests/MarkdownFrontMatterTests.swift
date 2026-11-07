import Foundation
import XCTest
@testable import LacEditor

/// Границы front matter (YAML-шапки): сама функция `MarkdownFrontMatter.frontMatter`, модель документа и потребители шапки.
final class MarkdownFrontMatterTests: XCTestCase {
    private func model(_ text: String, includes: MarkdownDocumentModel.Includes = []) -> MarkdownDocumentModel {
        MarkdownDocumentParser.parseOrEmpty(text, includes: includes)
    }

    func testSimpleFrontMatterDoesNotBecomeHeadingsAndPreservesOffsets() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let front = ["---", "title: 中文😀", "author: A B", "---"].joined(separator: ending)
            let source = front + ending + ending + "# Heading"
            let parsed = model(source)
            let found = try XCTUnwrap(parsed.frontMatter)
            XCTAssertEqual((source as NSString).substring(with: found.range), front)
            XCTAssertEqual(found.markers.map { (source as NSString).substring(with: $0) }, ["---", "---"])
            let headings = parsed.headings
            XCTAssertEqual(headings.map(\.title), ["Heading"])
            XCTAssertEqual(headings.first?.range.location, (source as NSString).range(of: "# Heading").location)
        }
    }

    func testAmbiguousOrUnsupportedFrontMatterRemainsMarkdown() {
        for source in ["---", "---\ntitle: value", "text\n---\ntitle: ok\n---"] {
            XCTAssertNil(MarkdownFrontMatter.frontMatter(source), source)
            XCTAssertNil(model(source).frontMatter, source)
        }
    }

    func testFrontMatterBoundariesPreserveComplexContentAndLaterOffsets() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let front = ["---", "标题: 中文😀", "description: |", "  [toc]", "  # not a heading", "map: {one: 1, two: [x, y]}", "# comment", "---"].joined(separator: newline)
            let source = front + newline + newline + "[toc]" + newline + newline + "# After 😀"
            let parsed = model(source)
            let found = try XCTUnwrap(parsed.frontMatter)
            XCTAssertEqual((source as NSString).substring(with: found.range), front)
            XCTAssertEqual(found.range, try XCTUnwrap(MarkdownFrontMatter.frontMatter(source)).range, "модель берёт границы из той же функции")
            let queries = try XCTUnwrap(parsed.queries([.headings, .tableOfContents]))
            XCTAssertEqual(queries.headings.map(\.title), ["After 😀"])
            XCTAssertEqual(queries.headings.first?.range.location, (source as NSString).range(of: "# After 😀").location)
            XCTAssertEqual(queries.tableOfContentsRanges, [(source as NSString).range(of: "[toc]", options: .backwards)])
            let masked = MarkdownFrontMatter.maskedFrontMatter(source, frontMatter: MarkdownFrontMatter.frontMatter(source))
            XCTAssertEqual(masked.utf8.count, source.utf8.count)
        }
        XCTAssertNotNil(MarkdownFrontMatter.frontMatter("---\n---"))
    }

    func testFrontMatterBOMTrailingWhitespaceAndDotClose() throws {
        for newline in ["\n", "\r\n", "\r"] {
            for closing in ["--- \t", "... \t"] {
                let front = ["\u{feff}--- \t", "标题: 中文😀", "description: |", "  [toc]", closing].joined(separator: newline)
                let source = front + newline + newline + "# After"
                let parsed = model(source)
                let found = try XCTUnwrap(parsed.frontMatter)
                XCTAssertEqual((source as NSString).substring(with: found.range), front)
                XCTAssertEqual(found.markers.map { (source as NSString).substring(with: $0) }, ["---", String(closing.prefix(3))])
                let queries = try XCTUnwrap(parsed.queries([.headings, .tableOfContents]))
                XCTAssertEqual(queries.headings.map(\.title), ["After"])
                XCTAssertEqual(queries.headings.first?.range.location, (source as NSString).range(of: "# After").location)
                XCTAssertTrue(queries.tableOfContentsRanges.isEmpty)
                let masked = MarkdownFrontMatter.maskedFrontMatter(source, frontMatter: MarkdownFrontMatter.frontMatter(source))
                XCTAssertEqual(masked.utf8.count, source.utf8.count)
            }
        }
        for source in [" ---\ntitle: x\n---", "--- # open\ntitle: x\n---", "---\ntitle: x\n... # end"] {
            XCTAssertNil(MarkdownFrontMatter.frontMatter(source), source)
        }
    }

    // Потребители шапки: BOM, \r\n и кириллица не сдвигают границу.
    func testStoryCardProseSkipsFrontMatterWithBOMAndCRLF() {
        let text = "\u{feff}---\r\ntitle: Заголовок\r\n---\r\nТекст 😀\r\n"
        let ns = text as NSString
        let prose = StoryCardText.proseRanges(in: text).map { ns.substring(with: $0) }.joined()
        // Граница шапки — конец закрывающей строки без перевода строки (`MarkdownFrontMatter.range`), поэтому проза начинается с него.
        XCTAssertEqual(prose, "\r\nТекст 😀\r\n")
        XCTAssertFalse(prose.contains("Заголовок"))
    }

    func testMindMapParserSkipsFrontMatterWithBOMAndCRLF() {
        let text = "\u{feff}---\r\ntitle: Книга\r\n---\r\n- глава\r\n  - 第一章\r\n"
        let titles = MindMapDocumentParser.parse(text, fallbackTitle: "Doc").nodes.map(\.title)
        XCTAssertTrue(titles.contains("глава"))
        XCTAssertTrue(titles.contains("第一章"))
        XCTAssertFalse(titles.contains { $0.contains("title") })
    }
}
