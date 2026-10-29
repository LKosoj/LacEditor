import XCTest
@testable import LacEditor

final class MarkdownEmailSourceTests: XCTestCase {
    func testRepeatedEmailsAreMappedByTheirParsedTextWithoutSearchingOtherNodes() {
        let source = "a@example.com and **a@example.com** `a@example.com` [a@example.com](other.md) a@example.com"
        let links = MarkdownPresentationParser.parse(source).links
        XCTAssertEqual(links.map(\.url), ["mailto:a@example.com", "mailto:a@example.com", "other.md", "mailto:a@example.com"])
        XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) },
                       ["a@example.com", "a@example.com", "[a@example.com](other.md)", "a@example.com"])
        XCTAssertEqual(links.first?.range.location, 0)
        XCTAssertEqual(links.last?.range.location, (source as NSString).range(of: "a@example.com", options: .backwards).location)
    }

    func testEmailsNextToWebAutolinksKeepBothRanges() {
        let source = "😀 a@example.com https://example.com z b@example.com **end**"
        let links = MarkdownPresentationParser.parse(source).links
        XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) },
                       ["a@example.com", "https://example.com", "b@example.com"])
    }

    func testTableQuoteAndEntityKeepOriginalUTF16Spelling() {
        for source in [
            "| A |\r\n|---|\r\n| 中\\|😀 a@example.com and b@example.com |",
            "> 中😀 a@example.com and b@example.com",
            "- 中😀 a@example.com and b@example.com"
        ] {
            let links = MarkdownPresentationParser.parse(source).links
            XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) }, ["a@example.com", "b@example.com"])
        }
        for spelling in ["a&#64;example.com", "a&commat;example.com"] {
            let source = "before " + spelling + " after"
            let links = MarkdownPresentationParser.parse(source).links
            XCTAssertEqual(links.map(\.url), ["mailto:a@example.com"])
            XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) }, [spelling])
        }
    }

    func testReadableSelectionAfterEmailUsesItsOwnRange() throws {
        let source = "before a@example.com after b@example.com end"
        let presentation = MarkdownPresentationParser.parse(source, includeReadableText: true)
        let readable = try XCTUnwrap(presentation.readableText), raw = source as NSString
        for selected in ["before", "a@example.com", "after", "b@example.com", "end"] {
            XCTAssertEqual(readable.text(in: raw.range(of: selected), source: raw), selected)
        }
        XCTAssertEqual(readable.text(in: raw.range(of: "after b@example.com"), source: raw), "after b@example.com")
    }

    func testManyEmailsAndEscapesKeepOrder() {
        let values = (0..<400).map { "name\($0)@example.com" }
        let source = values.joined(separator: " &amp; ")
        let links = MarkdownPresentationParser.parse(source).links
        XCTAssertEqual(links.count, values.count)
        XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) }, values)
        XCTAssertEqual(links.map(\.url), values.map { "mailto:" + $0 })
    }
    func testManySeparateEmailOriginsShareOneTableMap() {
        let values = (0..<400).map { "name\($0)@example.com" }
        let source = "| A |\n|---|\n| " + values.map { "**" + $0 + "**" }.joined(separator: " &amp; ") + " |"
        let links = MarkdownPresentationParser.parse(source).links
        XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) }, values)
    }

}
