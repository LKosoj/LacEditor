import XCTest
@testable import LacEditor

final class WriterCombinedPageTests: XCTestCase {
    func testPartURLRoundTrip() throws {
        let token = WriterCombinedPage.makeToken()
        let url = WriterCombinedPage.partURL(token: token, index: 3)
        XCTAssertEqual(WriterCombinedPage.partIndex(from: url, token: token), 3)
        XCTAssertNil(WriterCombinedPage.partIndex(from: url, token: "other"))
        XCTAssertNil(WriterCombinedPage.partIndex(from: try XCTUnwrap(URL(string: "https://a.b/3")), token: token))
    }

    func testHTMLContainsPartsAndLinks() {
        let token = "tok"
        let parts = [WriterCombinedPage.PartInput(title: "A <b>", text: "Hello", documentURL: URL(fileURLWithPath: "/tmp/a.md")),
                     WriterCombinedPage.PartInput(title: "B", text: "World", documentURL: URL(fileURLWithPath: "/tmp/b.md"))]
        let html = WriterCombinedPage.html(parts: parts, token: token, darkMode: false, syntax: MarkdownSyntaxOptions(), openLabel: "Open")
        XCTAssertTrue(html.contains("lacpart://tok/0"))
        XCTAssertTrue(html.contains("lacpart://tok/1"))
        XCTAssertTrue(html.contains("A &lt;b&gt; · Open"))
        XCTAssertTrue(html.contains("Hello"))
        XCTAssertTrue(html.contains("World"))
    }

    func testPageKeepsRestrictiveCSPAndOneSectionPerPart() {
        let parts = (0..<3).map { WriterCombinedPage.PartInput(title: "P\($0)", text: "Body \($0)", documentURL: URL(fileURLWithPath: "/tmp/p\($0).md")) }
        let html = WriterCombinedPage.html(parts: parts, token: "tok", darkMode: true, syntax: MarkdownSyntaxOptions(), openLabel: "Open")
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertEqual(html.components(separatedBy: "<section class=\"lac-part\">").count - 1, 3)
    }

    func testLinkFromMarkdownWithForeignTokenIsNotAPart() throws {
        let part = WriterCombinedPage.PartInput(title: "A", text: "[x](lacpart://other/0)", documentURL: URL(fileURLWithPath: "/tmp/a.md"))
        let html = WriterCombinedPage.html(parts: [part], token: "tok", darkMode: false, syntax: MarkdownSyntaxOptions(), openLabel: "Open")
        XCTAssertTrue(html.contains("lacpart://tok/0"))
        XCTAssertNil(WriterCombinedPage.partIndex(from: try XCTUnwrap(URL(string: "lacpart://other/0")), token: "tok"))
    }
}
