import Foundation
import XCTest
@testable import LacEditor

final class MarkdownWikiLinkRewriterTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)

    private func context(document: String = "/tmp/vault/doc.md") -> MarkdownWikiLinkContext {
        MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: base, paths: ["a.md", "sub/c.md", "x.md", "sub/x.md"]),
                                documentURL: URL(fileURLWithPath: document))
    }

    private func rewrite(_ text: String, document: String = "/tmp/vault/doc.md") -> String {
        MarkdownWikiLinkRewriter.rewrite(text, links: MarkdownWikiLinkExtractor.links(in: text),
                                         context: context(document: document))
    }

    func testResolvedLinkBecomesRelativeMarkdownLink() {
        XCTAssertEqual(rewrite("[[a]]"), "[a](a.md)")
        XCTAssertEqual(rewrite("[[sub/c|Cee]]"), "[Cee](sub/c.md)")
        let slug = MarkdownHeadingAnchors.slug(of: "My Head")
        XCTAssertEqual(rewrite("[[a#My Head]]"), "[a\\#My Head](a.md#\(slug))")
    }

    func testPathIsRelativeToDocumentDirectory() {
        XCTAssertEqual(rewrite("[[a]]", document: "/tmp/vault/sub/d.md"), "[a](../a.md)")
    }

    func testMissingAndAmbiguousFallBackToTextAndCurrentDocumentKeepsFragment() {
        XCTAssertEqual(rewrite("[[nope]]"), "nope")
        XCTAssertEqual(rewrite("[[x]]"), "x")
        XCTAssertEqual(rewrite("[[#Head]]"), "[\\#Head](#\(MarkdownHeadingAnchors.slug(of: "Head")))")
    }

    func testLineCountAndSurroundingTextAreKept() {
        let text = "one [[a]]\n\n```\n[[a]]\n```\ntwo [[nope|Name]] end\n"
        let result = rewrite(text)
        XCTAssertEqual(result, "one [a](a.md)\n\n```\n[[a]]\n```\ntwo Name end\n")
        XCTAssertEqual(result.components(separatedBy: "\n").count, text.components(separatedBy: "\n").count)
    }

    func testTextWithoutLinksIsReturnedAsIs() {
        let text = "plain `[[a]]` text"
        XCTAssertEqual(rewrite(text), text)
    }

    func testPreviewRendersLinkAndPlainText() {
        let html = MarkdownRenderer.renderPage("[[a]] and [[nope]]", darkMode: false, wiki: context()).html
        XCTAssertTrue(html.contains("<a href=\"a.md\">a</a>"))
        XCTAssertTrue(html.contains("and nope"))
        XCTAssertFalse(html.contains("[["))
        let untouched = MarkdownRenderer.renderPage("[[a]]", darkMode: false).html
        XCTAssertTrue(untouched.contains("[[a]]"))
    }

    func testExportSnapshotMergesWithEmojiAndFormulasAndKeepsOverlapsAsText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("a.md"))
        let source = MarkdownWikiLinkSource(root: directory, documentURL: directory.appendingPathComponent("doc.md"))
        let merged = try PandocExportService.markedExportSnapshot(":smile: [[a]] $x$ [[nope]]", syntax: .init(), includeTOC: false, wiki: source, isCancelled: { false })
        XCTAssertTrue(merged.text.contains("[a](a.md)"))
        XCTAssertTrue(merged.text.contains("nope"))
        XCTAssertFalse(merged.text.contains("[["))
        XCTAssertFalse(merged.text.contains(":smile:"))
        XCTAssertEqual(merged.math.count, 1)
        let overlapping = try PandocExportService.markedExportSnapshot("[[a:smile:]]", syntax: .init(), includeTOC: false, wiki: source, isCancelled: { false })
        XCTAssertTrue(overlapping.text.contains("[[a"))
        XCTAssertFalse(overlapping.text.contains("a.md"))
        let without = try PandocExportService.markedExportSnapshot("[[a]]", syntax: .init(), includeTOC: false, isCancelled: { false })
        XCTAssertTrue(without.text.contains("[[a]]"))
    }
}
