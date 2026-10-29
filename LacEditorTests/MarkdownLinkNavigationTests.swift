import XCTest
@testable import LacEditor

@MainActor
final class MarkdownLinkNavigationTests: XCTestCase {
    func testExtensionlessTargetPrefersExactThenMarkdownVariants() {
        let base = URL(fileURLWithPath: "/tmp/a #b")
        let md = base.appendingPathExtension("md"), markdown = base.appendingPathExtension("markdown")
        XCTAssertEqual(MarkdownLinkNavigationService.fileTarget(base, exists: { [base, md, markdown].contains($0) }).url, base)
        XCTAssertEqual(MarkdownLinkNavigationService.fileTarget(base, exists: { [md, markdown].contains($0) }).url, md)
        XCTAssertEqual(MarkdownLinkNavigationService.fileTarget(base, exists: { $0 == markdown }).url, markdown)
        let missing = MarkdownLinkNavigationService.fileTarget(base, exists: { _ in false })
        XCTAssertEqual(missing.url, md)
        XCTAssertFalse(missing.exists)
        let other = base.appendingPathExtension("pdf")
        XCTAssertEqual(MarkdownLinkNavigationService.fileTarget(other, exists: { _ in false }).url, other)
    }

    func testCreateLinkedMarkdownDoesNotOverwriteOrCreateParents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("中文 #.md")
        let service = FileService()
        try service.createLinkedMarkdownFile(at: file)
        XCTAssertEqual(try Data(contentsOf: file), Data())
        try Data("existing".utf8).write(to: file)
        XCTAssertThrowsError(try service.createLinkedMarkdownFile(at: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("existing".utf8))
        XCTAssertThrowsError(try service.createLinkedMarkdownFile(at: directory.appendingPathComponent("missing/file.md")))
        XCTAssertThrowsError(try service.createLinkedMarkdownFile(at: directory.appendingPathComponent("file.pdf")))
    }
    func testClassifiesURLsWithoutDecodingPathsOrFragmentsTwice() throws {
        let document = URL(fileURLWithPath: "/tmp/folder/document.md")
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "#%E4%B8%AD%2520", documentURL: nil), .fragment("中%20"))
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "#", documentURL: nil), .fragment(""))
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "../a%23b%2520.md#chapter", documentURL: document),
                       .file(URL(fileURLWithPath: "/tmp/a#b%20.md"), fragment: "chapter"))
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "a%20中.md?view=1#part", documentURL: document),
                       .file(URL(fileURLWithPath: "/tmp/folder/a 中.md"), fragment: "part"))
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "?view=1#part", documentURL: document),
                       .file(document, fragment: "part"))
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "/tmp/a%23b.md", documentURL: nil),
                       .file(URL(fileURLWithPath: "/tmp/a#b.md"), fragment: nil))
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "file:///tmp/a.md#part", documentURL: nil),
                       .file(URL(fileURLWithPath: "/tmp/a.md"), fragment: "part"))
        for address in ["https://example.com/a?q=中#part", "mailto:a@example.com"] {
            guard case .external(let url) = try MarkdownLinkNavigationService.destination(for: address, documentURL: document) else {
                return XCTFail("Expected an external URL")
            }
            XCTAssertNotNil(url.scheme)
        }
        for address in ["", "javascript:alert(1)", "data:text/html,x", "https:///missing-host", "file://remote/tmp/a.md", "file:relative.md"] {
            XCTAssertThrowsError(try MarkdownLinkNavigationService.destination(for: address, documentURL: document), address)
        }
        XCTAssertThrowsError(try MarkdownLinkNavigationService.destination(for: "relative.md", documentURL: nil))
    }

    func testSharedHeadingAnchorsKeepRendererIDsAndDuplicateAliases() throws {
        let source = "# A\n# A\n# A-1\n# 中文 😀\n# !!!\n# é\n# É"
        let headings = MarkdownPresentationParser.parse(source).headings
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertEqual(page.headingIDs, ["lac-heading-a", "lac-heading-a-1", "lac-heading-a-1-1", "lac-heading-中文", "lac-heading-section", "lac-heading-é", "lac-heading-é-1"])
        XCTAssertEqual(MarkdownHeadingAnchors.target(for: "a-1", in: headings), headings[1])
        XCTAssertEqual(MarkdownHeadingAnchors.target(for: "a-1-1", in: headings), headings[2])
        XCTAssertEqual(MarkdownHeadingAnchors.target(for: "中文", in: headings), headings[3])
        XCTAssertEqual(MarkdownHeadingAnchors.target(for: "lac-heading-é-1", in: headings), headings[6])
        XCTAssertNil(MarkdownHeadingAnchors.target(for: "missing", in: headings))
    }

    func testSharedParserConfirmsInlineReferenceAndAutolinks() {
        let source = "😀 [**label**](https://example.com/a 'title') [ref][id] <a@example.com> `code [x](bad)` ![picture](image.png)\r\n\r\n[id]: other.md#part"
        let links = MarkdownPresentationParser.parse(source).links
        XCTAssertEqual(links.map(\.url), ["https://example.com/a", "other.md#part", "mailto:a@example.com"])
        XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) },
                       ["[**label**](https://example.com/a 'title')", "[ref][id]", "<a@example.com>"])
    }

    func testGFMPlainAutolinksNeverIncludeAdjacentWhitespace() {
        let cases: [(String, [String], [String])] = [
            ("www.example.com and https://example.com!", ["www.example.com", "https://example.com"], ["http://www.example.com", "https://example.com"]),
            ("😀 https://example.com!", ["https://example.com"], ["https://example.com"]),
            ("| A |\n|---|\n| 中\\|😀 https://example.com |", ["https://example.com"], ["https://example.com"])
        ]
        for (source, expectedRanges, expectedURLs) in cases {
            let links = MarkdownPresentationParser.parse(source).links
            XCTAssertEqual(links.map { (source as NSString).substring(with: $0.range) }, expectedRanges)
            XCTAssertEqual(links.map(\.url), expectedURLs)
        }
    }

    func testTableLinkRangeUsesEscapedPipeByteMap() throws {
        let source = "| A |\r\n|---|\r\n| 中\\|😀 **[link](other.md#part)** |"
        let link = try XCTUnwrap(MarkdownPresentationParser.parse(source).links.first)
        XCTAssertEqual(link.url, "other.md#part")
        XCTAssertEqual((source as NSString).substring(with: link.range), "[link](other.md#part)")
    }
}
