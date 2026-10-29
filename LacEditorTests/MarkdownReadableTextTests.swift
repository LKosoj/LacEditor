import XCTest
import cmark_gfm
@testable import LacEditor

final class MarkdownReadableTextTests: XCTestCase {
    func testSharedPresentationBuildsReadableTextOnlyWhenRequested() throws {
        let source = "# 中文\n\n**hello** [world](https://example.com)"
        XCTAssertNil(MarkdownPresentationParser.parse(source).readableText)
        let presentation = MarkdownPresentationParser.parse(source, includeReadableText: true)
        let readable = try XCTUnwrap(presentation.readableText?.text())
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate(readable)).words, 4)
        XCTAssertFalse(readable.contains("example.com"))
        XCTAssertEqual(presentation.headings.count, 1)
    }

    func testTableReplacementInvalidatesReadableText() throws {
        let source = "| A |\n|---|\n| B |"
        let presentation = MarkdownPresentationParser.parse(source, includeReadableText: true)
        XCTAssertNotNil(presentation.readableText)
        let table = try XCTUnwrap(presentation.tables.first)
        let replacement = presentation.replacingTable(table, oldTable: table.range,
            edit: NSRange(location: table.range.location, length: 0), replacementLength: 1)
        XCTAssertNil(replacement.readableText)
    }

    private func projection(_ text: String) throws -> MarkdownReadableText {
        let frontMatter = MarkdownPresentationParser.frontMatter(text)
        let input = MarkdownPresentationParser.maskedFrontMatter(text, frontMatter: frontMatter)
        let result = MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_FOOTNOTES) { root, ext, inline in
            MarkdownReadableTextParser.build(root: root, source: MarkdownPresentationParser.Source(text), text: text as NSString,
                mathExtension: ext, inlineMath: Set(inline.map(\.node)))
        }
        return try XCTUnwrap(result ?? nil)
    }

    func testWordsExcludeMarkupAddressesAndYAMLButKeepInlineWordBoundaries() throws {
        let source = "---\ntitle: not counted\n---\n\n# Hello\n\nhel**lo** [world](https://address.example/hidden)\n\n1. 中文\n2. `code`"
        let readable = try XCTUnwrap(try projection(source).text())
        XCTAssertFalse(readable.contains("title"))
        XCTAssertFalse(readable.contains("address.example"))
        XCTAssertTrue(readable.contains("hello world"))
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate(readable)).words, 6)
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate(source)).characters, source.count)
    }

    func testPartialSelectionUsesOriginalUTF16Ranges() throws {
        let source = "😀 **hello** [world](https://example.com)"
        let readable = try projection(source), raw = source as NSString
        XCTAssertEqual(readable.text(in: raw.range(of: "ell"), source: raw), "ell")
        XCTAssertEqual(readable.text(in: raw.range(of: "https://example.com"), source: raw), "")
        XCTAssertEqual(readable.text(in: NSRange(location: 3, length: 2), source: raw), "")
        XCTAssertNil(readable.text(in: NSRange(location: NSNotFound, length: 0), source: raw))
        XCTAssertNil(readable.text(in: NSRange(location: raw.length, length: 1), source: raw))
    }

    func testTableCellsRemainSeparateAndCodeContentCountsWithoutFences() throws {
        let source = "| A | B |\n|---|---|\n| 中 | 文 |\n\n```swift\nalpha beta\n```"
        let readable = try XCTUnwrap(try projection(source).text())
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate(readable)).words, 6)
        XCTAssertFalse(readable.contains("swift"))
        XCTAssertFalse(readable.contains("```"))
    }

    func testGeneratedMarkupDoesNotBecomeProseAndUnsupportedHTMLIsExplicit() throws {
        let source = "before $x$ after\n\n$$\n\\frac{a}{b}\n$$\n\n```mermaid\nflowchart TD\nA-->B\n```\n\n<!-- ignored words -->"
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate(try XCTUnwrap(try projection(source).text()))).words, 2)
        XCTAssertNil(try projection("<div>visible HTML words</div>").text())
        XCTAssertNil(try projection("<!-- comment --><div>visible</div>").text())
    }

    func testDecodedEntityCountsWholeButDoesNotGuessPartialSourceMapping() throws {
        let source = "&#x4E2D;"
        let readable = try projection(source)
        XCTAssertEqual(readable.text()?.trimmingCharacters(in: .whitespacesAndNewlines), "中")
        XCTAssertEqual(readable.text(in: NSRange(location: 0, length: source.utf16.count), source: source as NSString)?.trimmingCharacters(in: .whitespacesAndNewlines), "中")
        XCTAssertNil(readable.text(in: NSRange(location: 1, length: 3), source: source as NSString))
    }

    func testPartialMappedInlineTextUsesConfirmedSourceTokens() throws {
        let source = "中😀 \\*word\\* &amp; \"hello\" -- end"
        let raw = source as NSString, readable = try projection(source)
        XCTAssertEqual(readable.text(in: raw.range(of: "word"), source: raw), "word")
        XCTAssertEqual(readable.text(in: raw.range(of: "\\*"), source: raw), "*")
        XCTAssertEqual(readable.text(in: raw.range(of: "&amp;"), source: raw), "&")
        XCTAssertEqual(readable.text(in: raw.range(of: "word\\* &amp;"), source: raw), "word* &")
        XCTAssertNil(readable.text(in: NSRange(location: raw.range(of: "&amp;").location, length: 2), source: raw))
        XCTAssertEqual(readable.text(in: raw.range(of: "hello"), source: raw), "hello")
        XCTAssertEqual(readable.text(in: raw.range(of: "--"), source: raw), "–")
        XCTAssertNil(readable.text(in: NSRange(location: raw.range(of: "--").location, length: 1), source: raw))
        XCTAssertNil(readable.text(in: NSRange(location: 1, length: 1), source: raw))
        XCTAssertNil(MarkdownInlineTextProjection.pieces(spelling: "abc" as NSString, literal: "xyz", sourceOffset: 0))
        XCTAssertNil(MarkdownInlineTextProjection.pieces(spelling: "abc" as NSString, literal: "abc", sourceOffset: 0, isCancelled: { true }))
    }
    func testInlineCodeSelectionExcludesDelimiters() throws {
        let source = "x `code` and `` `中` ``"
        let raw = source as NSString, readable = try projection(source)
        XCTAssertEqual(readable.text(in: raw.range(of: "od"), source: raw), "od")
        XCTAssertEqual(readable.text(in: raw.range(of: "`"), source: raw), "")
        XCTAssertEqual(readable.text(in: raw.range(of: "`中`"), source: raw), "`中`")
    }

    func testScriptAndStyleContentsAreNotCountedAsOrdinaryProse() throws {
        for tag in ["script", "style"] {
            let source = "before <\(tag)>hidden words</\(tag)> after\n\nVisible paragraph"
            let raw = source as NSString, readable = try projection(source)
            XCTAssertNil(readable.text())
            XCTAssertNil(readable.text(in: raw.range(of: "hidden words"), source: raw))
            XCTAssertEqual(readable.text(in: raw.range(of: "Visible paragraph"), source: raw), "Visible paragraph")
        }
    }

    func testSelectionCannotSplitSurrogatePairAndProjectionCanBeCancelled() throws {
        let source = "😀 e\u{301} words"
        let raw = source as NSString, readable = try projection(source)
        XCTAssertNil(readable.text(in: NSRange(location: 0, length: 1), source: raw))
        XCTAssertNil(readable.text(in: NSRange(location: 1, length: 1), source: raw))
        XCTAssertEqual(readable.text(in: NSRange(location: 0, length: 2), source: raw), "😀")
        XCTAssertEqual(readable.text(in: NSRange(location: 3, length: 1), source: raw), "e")
        var checks = 0
        XCTAssertNil(readable.text(isCancelled: { checks += 1; return checks > 2 }))
        XCTAssertGreaterThan(checks, 2)
    }

    func testLongInlineDelimiterKeepsBodyWithoutRepeatedRangeCopies() throws {
        let ticks = String(repeating: "`", count: 2048)
        let body = String(repeating: "中a", count: 4096)
        let source = ticks + body + ticks
        XCTAssertEqual(try projection(source).text()?.trimmingCharacters(in: .whitespacesAndNewlines), body)
    }

}
