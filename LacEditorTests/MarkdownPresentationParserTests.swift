import Foundation
import XCTest
@testable import LacEditor

final class MarkdownPresentationParserTests: XCTestCase {
    private func marked(_ span: MarkdownPresentationSpan, in text: String) -> [String] {
        span.markerRanges.map { (text as NSString).substring(with: $0) }
    }

    func testUnicodeAndInlineFormattingUseUTF16Ranges() throws {
        let text = "# 中文 😀 **жирный** and *italic* ~~old~~ `code`"
        let presentation = MarkdownPresentationParser.parse(text)
        let heading = try XCTUnwrap(presentation.spans.first { $0.kind == .heading(1) })
        let strong = try XCTUnwrap(presentation.spans.first { $0.kind == .strong })
        let emphasis = try XCTUnwrap(presentation.spans.first { $0.kind == .emphasis })
        let strike = try XCTUnwrap(presentation.spans.first { $0.kind == .strikethrough })
        let code = try XCTUnwrap(presentation.spans.first { $0.kind == .code })
        XCTAssertEqual(marked(heading, in: text), ["# "])
        XCTAssertEqual((text as NSString).substring(with: strong.range), "**жирный**")
        XCTAssertEqual(marked(strong, in: text), ["**", "**"])
        XCTAssertEqual(marked(emphasis, in: text), ["*", "*"])
        XCTAssertEqual(marked(strike, in: text), ["~~", "~~"])
        XCTAssertEqual((text as NSString).substring(with: code.range), "`code`")
        XCTAssertEqual(marked(code, in: text), ["`", "`"])
    }

    func testLongASCIIAndUnicodeBoundariesAcrossLineEndings() throws {
        let prefix = String(repeating: "a", count: 100_000)
        let text = prefix + "\r\n\r## é中😀e\u{301} **ж😀**\r\r*after*\n"
        let spans = MarkdownPresentationParser.parse(text).spans
        let strong = try XCTUnwrap(spans.first { $0.kind == .strong })
        let emphasis = try XCTUnwrap(spans.first { $0.kind == .emphasis })
        XCTAssertEqual((text as NSString).substring(with: strong.range), "**ж😀**")
        XCTAssertEqual(marked(strong, in: text), ["**", "**"])
        XCTAssertEqual((text as NSString).substring(with: emphasis.range), "*after*")
    }

    func testNestedLinkHidesOnlyBracketsAndDestination() throws {
        let text = "[x **bold**](https://example.com/a_(b))"
        let spans = MarkdownPresentationParser.parse(text).spans
        let link = try XCTUnwrap(spans.first { $0.kind == .link })
        let strong = try XCTUnwrap(spans.first { $0.kind == .strong })
        XCTAssertEqual(marked(link, in: text), ["[", "](https://example.com/a_(b))"])
        XCTAssertEqual(marked(strong, in: text), ["**", "**"])
    }

    func testQuoteAndFencesWithCRLF() throws {
        let text = "> first\r\n> second\r\n\r\n```swift\r\nlet value = 1\r\n```"
        let spans = MarkdownPresentationParser.parse(text).spans
        let quote = try XCTUnwrap(spans.first { $0.kind == .quote })
        let code = try XCTUnwrap(spans.first { $0.kind == .codeBlock })
        XCTAssertEqual(marked(quote, in: text), [">", ">"])
        XCTAssertEqual(marked(code, in: text), ["```", "```"])
    }

    func testUncertainMarkupRemainsVisible() {
        let text = "\\*escaped*\n\n[reference][name]\n\n[name]: https://example.com\n\n# tab\t**bold**\n\n![**image**](image.png)"
        let spans = MarkdownPresentationParser.parse(text).spans
        let links = spans.filter { $0.kind == .link }
        XCTAssertTrue(links.allSatisfy { $0.markerRanges.isEmpty })
        XCTAssertFalse(spans.contains { $0.kind == .strong })
        XCTAssertFalse(spans.contains { $0.kind == .heading(1) })
    }

    func testParsingLeavesSourceUnchangedAndMalformedMarkupVisible() {
        let text = "中文 😀 **unfinished and [broken]("
        let original = text
        let spans = MarkdownPresentationParser.parse(text).spans
        XCTAssertEqual(text, original)
        XCTAssertFalse(spans.contains { $0.kind == .strong || $0.kind == .link })
    }

    func testSetextAndUnclosedFenceDoNotHideGuessedMarkers() throws {
        let text = "Heading\n=======\n\n```swift\nno closing fence"
        let spans = MarkdownPresentationParser.parse(text).spans
        let heading = try XCTUnwrap(spans.first { $0.kind == .heading(1) })
        let code = try XCTUnwrap(spans.first { $0.kind == .codeBlock })
        XCTAssertTrue(heading.markerRanges.isEmpty)
        XCTAssertTrue(code.markerRanges.isEmpty)
    }

    func testOutlineUsesParsedLabelsAndUTF16Ranges() throws {
        let text = "前文 😀\n\n# 中文 **bold** [link](https://example.com) `code` ![alt](x.png)\n\nSecond *title*\n------------\n\n```\n# not a heading\n```\n\n> ### 引用"
        let headings = MarkdownPresentationParser.parse(text).headings
        XCTAssertEqual(headings.map(\.level), [1, 2, 3])
        XCTAssertEqual(headings.map(\.title), ["中文 bold link code alt", "Second title", "引用"])
        XCTAssertTrue((text as NSString).substring(with: headings[0].range).hasPrefix("# 中文"))
        XCTAssertTrue((text as NSString).substring(with: headings[1].range).hasPrefix("Second *title*"))
        XCTAssertTrue((text as NSString).substring(with: headings[2].range).contains("### 引用"))
    }


    func testOutlineCanNavigateToHeadingContainingTabs() throws {
        let text = "前文 😀\n\n# tab\t**bold**"
        let heading = try XCTUnwrap(MarkdownPresentationParser.parse(text).headings.first)
        XCTAssertEqual(heading.title, "tab bold")
        XCTAssertEqual(heading.range.location, ("前文 😀\n\n" as NSString).length)
    }

}
