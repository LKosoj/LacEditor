import Foundation
import XCTest
@testable import LacEditor

final class ManuscriptServiceTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/ms-root", isDirectory: true)

    private func part(_ text: String, _ path: String = "a.md") -> ManuscriptService.Part {
        .init(file: .init(url: root.appendingPathComponent(path), relativePath: path), text: text)
    }

    private func merge(_ parts: [ManuscriptService.Part]) throws -> ManuscriptService.Output {
        try ManuscriptService.merge(parts, skipped: [], syntax: .init())
    }

    func testSeparators() {
        XCTAssertEqual(ManuscriptService.join(["a", "b"]), "a\n\nb")
        XCTAssertEqual(ManuscriptService.join(["a\n", "b"]), "a\n\nb")
        XCTAssertEqual(ManuscriptService.join(["a\n\n", "b"]), "a\n\nb")
        XCTAssertEqual(ManuscriptService.join(["a\r\n", "b"]), "a\r\n\r\nb")
        XCTAssertEqual(ManuscriptService.join(["a\r", "b"]), "a\r\rb")
        XCTAssertEqual(ManuscriptService.join(["a\r\nx\ny", "b\n"]), "a\r\nx\ny\n\nb\n")
        XCTAssertEqual(ManuscriptService.join(["a\nx\r\n", "b"]), "a\nx\r\n\r\nb")
        XCTAssertEqual(ManuscriptService.join(["only"]), "only")
    }

    func testEmptyPartsAreSkipped() throws {
        let output = try merge([part("a"), part("\u{FEFF}", "b.md"), part("c", "c.md")])
        XCTAssertEqual(output.text, "a\n\nc")
        XCTAssertEqual(output.report.mergedFiles, 2)
    }

    func testBOMIsRemovedOnlyAtStart() throws {
        let output = try merge([part("\u{FEFF}a\n\u{FEFF}x"), part("\u{FEFF}b", "b.md")])
        XCTAssertEqual(output.text, "a\n\u{FEFF}x\n\nb")
    }

    func testFrontMatterKeptOnlyInFirstPart() throws {
        let output = try merge([part("---\ntitle: A\n---\nOne"), part("---\r\ntitle: B\r\n---\r\nTwo", "b.md"),
                                part("---\ntitle: C\n...\nThree", "c.md"), part("---\n---\nFour", "d.md")])
        XCTAssertEqual(output.text, "---\ntitle: A\n---\nOne\n\nTwo\n\nThree\n\nFour")
    }

    func testUnconfirmedFrontMatterStaysText() throws {
        let output = try merge([part("One"), part("---\njust text\n---\nTwo", "b.md"), part("---\nunclosed\nThree", "c.md")])
        XCTAssertEqual(output.text, "One\n\n---\njust text\n---\nTwo\n\n---\nunclosed\nThree")
    }

    func testFrontMatterOfFirstMergedPartWins() throws {
        let output = try merge([part("---\nt: 1\n---\nA"), part("B", "b.md")])
        XCTAssertTrue(output.text.hasPrefix("---\nt: 1\n---\nA"))
        let withoutFirst = try merge([part("---\nt: 2\n---\nB", "b.md")])
        XCTAssertTrue(withoutFirst.text.hasPrefix("---\nt: 2"))
    }

    func testImageAndLinkAddresses() throws {
        let base = root.standardizedFileURL.path
        let text = "😀 中文 ![a](img/x.png) [t](other.md#h) ![b](../x.png \"t\") ![c](<my pic.png>) ![d](my%20pic.png) [e](x.md?y=1#z) ![ф](Фото.png)"
        let output = try merge([part(text, "sub/ch.md")])
        XCTAssertEqual(output.text,
                       "😀 中文 ![a](\(base)/sub/img/x.png) [t](\(base)/sub/other.md#h) ![b](\(base)/x.png \"t\") ![c](<\(base)/sub/my%20pic.png>) ![d](\(base)/sub/my%20pic.png) [e](\(base)/sub/x.md?y=1#z) ![ф](\(base)/sub/Фото.png)")
        XCTAssertEqual(output.report.unconvertedAddresses, 0)
    }

    func testUntouchedAddresses() throws {
        let text = "![a](/abs/x.png) ![](#x) ![h](http://e.com/a.png) ![d](data:image/png;base64,AAAA) [f](file:///x.md) [m](mailto:a@b.c) [h](#h) [w](//host/x) [u](https://e.com/x.md)\n\n```\n![c](code.png)\n```"
        let output = try merge([part(text)])
        XCTAssertEqual(output.text, text)
        XCTAssertEqual(output.report.unconvertedAddresses, 0)
    }

    func testUnsupportedFormsAreCounted() throws {
        let text = "[t][r] ![a][i]\n\n[r]: x.md\n[i]: a.png\n\n<img src=a.png> [h](x&amp;y.md) [b](x\\_y.md)"
        let output = try merge([part(text)])
        XCTAssertEqual(output.text, text)
        XCTAssertGreaterThan(output.report.unconvertedAddresses, 0)
    }

    func testHTMLLinksAndMediaAreCountedButNotChanged() throws {
        let text = "<a href=\"x.md\">t</a> <video src='v.mp4'></video> <a href=\"https://e.com\">w</a> <a href=\"#h\">h</a> <a data-href=\"z.md\">d</a>"
        let output = try merge([part(text)])
        XCTAssertEqual(output.text, text)
        XCTAssertEqual(output.report.unconvertedAddresses, 2)
    }

    func testAddressEncodingKeepsNonASCIIAndHidesMarkup() {
        let file = URL(fileURLWithPath: "/tmp/book/ch.md")
        XCTAssertEqual(ManuscriptService.rewrite(path: "мой%20файл.png", from: file, paths: nil), .converted("/tmp/book/мой%20файл.png"))
        XCTAssertEqual(ManuscriptService.rewrite(path: "a%7Cb.png", from: file, paths: nil), .converted("/tmp/book/a%7Cb.png"))
        XCTAssertEqual(ManuscriptService.rewrite(path: "a*b~c.png", from: file, paths: nil), .converted("/tmp/book/a%2Ab%7Ec.png"))
    }

    func testHTMLImageWithQuotes() throws {
        let base = root.standardizedFileURL.path
        let output = try merge([part("<img src=\"a.png\" alt=\"x\">")])
        XCTAssertEqual(output.text, "<img src=\"\(base)/a.png\" alt=\"x\">")
    }

    func testTyporaRootURLInFirstPartBlocksConversion() throws {
        let text = "---\ntypora-root-url: /tmp/other\n---\n![a](x.png)"
        let output = try merge([part(text), part("![b](y.png)", "b.md")])
        XCTAssertTrue(output.report.blockedByRootURL)
        XCTAssertTrue(output.text.contains("![a](x.png)"))
        XCTAssertTrue(output.text.contains("![b](y.png)"))
    }

    func testTyporaRootURLInLaterPartResolvesSlashAddress() throws {
        let output = try merge([part("![a](/abs/x.png)"), part("---\ntypora-root-url: /tmp/other\n---\n![b](/img/a.png) ![c](c.png)", "b.md")])
        XCTAssertFalse(output.report.blockedByRootURL)
        XCTAssertTrue(output.text.hasPrefix("![a](/abs/x.png)\n\n![b](/tmp/other/img/a.png)"))
    }

    func testFootnoteLabels() throws {
        let output = try merge([part("a[^1] b[^A]\n\n[^1]: x\n\n[^A]: y"), part("c[^1] d[^a] e[^3]\n\n[^1]: x\n\n[^a]: y\n\n[^3]: z", "b.md")])
        XCTAssertEqual(output.report.duplicateFootnoteLabels, ["1", "A"])
        let single = try merge([part("`[^9]: x`\n\n    [^8]: y"), part("c[^1]\n\n[^1]: x", "b.md")])
        XCTAssertEqual(single.report.duplicateFootnoteLabels, [])
    }

    func testCancellation() {
        XCTAssertThrowsError(try ManuscriptService.merge([part("a")], skipped: [], syntax: .init(), isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testConvertedAddressesPointToExistingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub/img"), withIntermediateDirectories: true)
        try Data([0]).write(to: dir.appendingPathComponent("sub/img/my pic.png"))
        let file = ManuscriptService.Part(file: .init(url: dir.appendingPathComponent("sub/ch.md"), relativePath: "sub/ch.md"),
                                          text: "![a](img/my%20pic.png)")
        let output = try merge([file])
        let images = try MarkdownImageUploadService.images(in: output.text)
        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(string: images[0].address)?.path ?? images[0].address))
    }
}
