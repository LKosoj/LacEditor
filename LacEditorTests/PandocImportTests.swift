import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LacEditor

final class PandocImportTests: XCTestCase {
    private let imageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    private func recursiveEntries(at directory: URL) -> [String] {
        let entries = FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] ?? []
        return entries.sorted()
    }

    @MainActor
    func testImportedDocumentIsUnsavedMarkdown() {
        let text = "![image](data:image/png;base64,\(imageBase64))"
        let document = EditorDocument(text: text, language: .markdown, isDirty: true, requiresExplicitSave: true)
        XCTAssertNil(document.url)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.language, .markdown)
        XCTAssertEqual(document.synchronizedSnapshot().text, text)
    }

    func testSupportedReaders() {
        XCTAssertEqual(PandocImportService.readers["fb2"], "fb2")
        XCTAssertEqual(PandocImportService.readers["htm"], "html+raw_html")
        XCTAssertEqual(PandocImportService.readers["html"], "html+raw_html")
        XCTAssertEqual(PandocImportService.readers["tex"], "latex")
        XCTAssertEqual(PandocImportService.readers["ltx"], "latex")
        XCTAssertEqual(PandocImportService.readers["rst"], "rst")
        XCTAssertEqual(PandocImportService.readers["rest"], "rst")
        XCTAssertEqual(PandocImportService.readers["org"], "org")
        XCTAssertEqual(PandocImportService.readers["wiki"], "mediawiki")
        XCTAssertEqual(PandocImportService.readers["dokuwiki"], "dokuwiki")
        XCTAssertEqual(PandocImportService.readers["textile"], "textile")
        XCTAssertEqual(PandocImportService.readers["opml"], "opml")
        XCTAssertEqual(Set(PandocImportService.readers.keys), Set([
            "docx", "odt", "rtf", "epub", "html", "htm", "tex", "latex", "fb2",
            "ltx", "rst", "rest", "org", "wiki", "dokuwiki", "textile", "opml"
        ]))
        XCTAssertNil(PandocImportService.readers["pdf"])
        XCTAssertNil(PandocImportService.readers["txt"])
    }

    func testImportPanelTypesExistForDeclaredExtensions() {
        for ext in PandocImportService.extensions {
            XCTAssertNotNil(UTType(filenameExtension: ext), "The import panel cannot offer .\(ext) without a system type")
        }
    }

    func testPDFImportExtractsTextAndEmbeddedImageWithoutChangingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try makePDFWithTextAndImage(at: source)
        let original = try Data(contentsOf: source)

        let imported = try PDFImportService.convert(source: source)

        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(imported.text.contains("PDF text layer"))
        XCTAssertTrue(imported.text.contains("data:image/"))
        let html = MarkdownRenderer.render(imported.text, darkMode: false)
        XCTAssertTrue(html.contains("PDF text layer"))
        XCTAssertTrue(html.contains("<img"))
        XCTAssertTrue(html.contains("data:image/"))
    }

    private func makePDFWithTextAndImage(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 500)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("PDF text layer" as NSString).draw(
            at: NSPoint(x: 40, y: 420),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()

        let pixels = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: 6,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        context.draw(image, in: CGRect(x: 40, y: 300, width: 80, height: 80))
        context.endPDFPage()
        context.closePDF()
    }

    func testNewTextReadersProduceRenderableMarkdownAndPreserveSources() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let latex = "\\section{Heading}\n中文 😀 \\href{https://example.com}{Link}\n"
        let rst = "Heading\n=======\n\n中文 😀 `Link <https://example.com>`_\n\n+---+---+\n| A | B |\n+===+===+\n| 1 | 2 |\n+---+---+\n"
        let fixtures: [(String, String, Bool)] = [
            ("tex", latex, false), ("latex", latex, false), ("ltx", latex, false), ("rst", rst, true), ("rest", rst, true),
            ("org", "* Heading\n\n中文 😀 [[https://example.com][Link]]\n\n| A | B |\n|---+---|\n| 1 | 2 |\n", true),
            ("wiki", "== Heading ==\n\n中文 😀 [https://example.com Link]\n", false),
            ("dokuwiki", "====== Heading ======\n\n中文 😀 [[https://example.com|Link]]\n", false),
            ("textile", "h1. Heading\n\n中文 😀 \"Link\":https://example.com\n", false)
        ]
        for (ext, input, hasTable) in fixtures {
            let source = directory.appendingPathComponent("input.\(ext)")
            let bytes = Data(input.utf8)
            try bytes.write(to: source)
            let result = try PandocImportService.convert(source: source, executable: executable)
            XCTAssertEqual(try Data(contentsOf: source), bytes, ext)
            let html = MarkdownRenderer.render(result.text, darkMode: false)
            XCTAssertTrue(html.contains("Heading</h"), ext)
            XCTAssertTrue(html.contains("中文 😀"), ext)
            XCTAssertTrue(html.contains("href=\"https://example.com\""), ext)
            if hasTable { XCTAssertTrue(html.contains("<table>"), ext) }
        }
    }

    func testExistingRTFReaderProducesTextWithoutChangingSource() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.rtf")
        let bytes = Data(#"{\rtf1\ansi Plain \u20013?\u25991? text}"#.utf8)
        try bytes.write(to: source)
        let imported = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let html = MarkdownRenderer.render(imported.text, darkMode: false)
        XCTAssertTrue(html.contains("Plain"))
        XCTAssertTrue(html.contains("中文"))
    }

    func testOPMLImportPreservesNestedHeadingsAndSource() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("outline.opml")
        let input = "<?xml version=\"1.0\"?><opml version=\"2.0\"><head><title>Title</title></head><body><outline text=\"中文 😀 Parent\"><outline text=\"Child\"/></outline></body></opml>"
        let bytes = Data(input.utf8)
        try bytes.write(to: source)
        let result = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertNotNil(MarkdownPresentationParser.frontMatter(result.text))
        XCTAssertTrue(result.text.contains("title: Title"))
        let html = MarkdownRenderer.render(result.text, darkMode: false)
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("中文 😀 Parent</h1>"))
        XCTAssertTrue(html.contains("<h2"))
        XCTAssertTrue(html.contains("Child</h2>"))
        try Data("<opml><body><outline>".utf8).write(to: source)
        let broken = try Data(contentsOf: source)
        XCTAssertThrowsError(try PandocImportService.convert(source: source, executable: executable))
        XCTAssertEqual(try Data(contentsOf: source), broken)
    }

    func testNewReadersEmbedLocalImagesWithoutChangingSource() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(Data(base64Encoded: imageBase64))
        let imageURL = directory.appendingPathComponent("image.png")
        try image.write(to: imageURL)
        let fixtures = [
            ("rst", ".. image:: image.png\n"),
            ("org", "[[file:image.png]]\n"),
            ("wiki", "[[File:image.png]]\n"),
            ("dokuwiki", "{{image.png}}\n"),
            ("textile", "!image.png!\n")
        ]
        for (ext, input) in fixtures {
            let source = directory.appendingPathComponent("image.\(ext)")
            let bytes = Data(input.utf8)
            try bytes.write(to: source)
            let imported = try PandocImportService.convert(source: source, executable: executable)
            XCTAssertEqual(try Data(contentsOf: source), bytes, ext)
            XCTAssertEqual(try Data(contentsOf: imageURL), image, ext)
            XCTAssertTrue(imported.text.contains("data:image/png;base64,"), ext)
            let html = MarkdownRenderer.render(imported.text, darkMode: false)
            XCTAssertTrue(html.contains("<img"), ext)
            XCTAssertTrue(html.contains("data:image/png;base64,"), ext)
        }
        try FileManager.default.removeItem(at: imageURL)
        let orgSource = directory.appendingPathComponent("image.org")
        let original = try Data(contentsOf: orgSource)
        XCTAssertThrowsError(try PandocImportService.convert(source: orgSource, executable: executable))
        XCTAssertEqual(try Data(contentsOf: orgSource), original)
    }

    func testMediaWikiCaptionedFigureRendersImageAndCaption() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(Data(base64Encoded: imageBase64))
        let imageURL = directory.appendingPathComponent("image.png")
        try image.write(to: imageURL)
        let source = directory.appendingPathComponent("caption.wiki")
        let bytes = Data("[[File:image.png|thumb|中文 Caption 😀]]\n".utf8)
        try bytes.write(to: source)
        let imported = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: imageURL), image)
        let html = MarkdownRenderer.render(imported.text, darkMode: false)
        XCTAssertTrue(html.contains("<img"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("中文 Caption 😀"))
        XCTAssertFalse(imported.text.contains("<figure"))
    }

    func testRemoteFigureKeepsURLWithoutFetching() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("remote.html")
        let bytes = Data("<figure><img src=\"https://example.invalid/image.png\" alt=\"remote\"><figcaption>Remote caption</figcaption></figure>".utf8)
        try bytes.write(to: source)
        let imported = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(imported.diagnostics.contains("Could not fetch"))
        let html = MarkdownRenderer.render(imported.text, darkMode: false)
        XCTAssertTrue(html.contains("<img"))
        XCTAssertTrue(html.contains("https://example.invalid/image.png"))
        XCTAssertTrue(html.contains("Remote caption"))
    }

    func testSandboxSkipsIncludesWithoutWritingSourceDirectory() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = sourceDirectory.appendingPathComponent("input.rst")
        let input = "Before\n\n.. include:: nested/inside.txt\n\n.. include:: ../outside.txt\n\nAfter\n"
        try Data(input.utf8).write(to: source)
        try "INSIDE_INCLUDE".write(to: sourceDirectory.appendingPathComponent("nested/inside.txt"), atomically: true, encoding: .utf8)
        try "OUTSIDE_SECRET".write(to: directory.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        let originalEntries = recursiveEntries(at: sourceDirectory)

        let result = try PandocImportService.convert(source: source, executable: executable)

        XCTAssertTrue(result.text.contains("Before"))
        XCTAssertFalse(result.text.contains("INSIDE_INCLUDE"))
        XCTAssertTrue(result.text.contains("After"))
        XCTAssertFalse(result.text.contains("OUTSIDE_SECRET"))
        XCTAssertEqual(try Data(contentsOf: source), Data(input.utf8))
        XCTAssertEqual(recursiveEntries(at: sourceDirectory), originalEntries)
    }

    func testSandboxSkipsLaTeXIncludesWithoutWritingSourceDirectory() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = sourceDirectory.appendingPathComponent("input.tex")
        let input = "Before\n\n\\input{nested/inside.txt}\n\n\\input{../outside.txt}\n\nAfter\n"
        try Data(input.utf8).write(to: source)
        try "INSIDE_INCLUDE".write(to: sourceDirectory.appendingPathComponent("nested/inside.txt"), atomically: true, encoding: .utf8)
        try "OUTSIDE_SECRET".write(to: directory.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        let originalEntries = recursiveEntries(at: sourceDirectory)

        let result = try PandocImportService.convert(source: source, executable: executable)

        XCTAssertTrue(result.text.contains("Before"))
        XCTAssertFalse(result.text.contains("INSIDE_INCLUDE"))
        XCTAssertTrue(result.text.contains("After"))
        XCTAssertFalse(result.text.contains("OUTSIDE_SECRET"))
        XCTAssertEqual(try Data(contentsOf: source), Data(input.utf8))
        XCTAssertEqual(recursiveEntries(at: sourceDirectory), originalEntries)
    }

    func testImportImagePathSecurityMatrix() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
        let nested = sourceDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("deeper", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("encoded", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(Data(base64Encoded: imageBase64))
        let outside = directory.appendingPathComponent("outside.png")
        try image.write(to: outside)
        try image.write(to: nested.appendingPathComponent("deeper/image.png"))
        try image.write(to: nested.appendingPathComponent("Юникод пробел 100%.png"))
        try image.write(to: nested.appendingPathComponent("encoded/картинка %.png"))
        try FileManager.default.createSymbolicLink(atPath: nested.appendingPathComponent("internal.png").path, withDestinationPath: "deeper/image.png")
        try FileManager.default.createSymbolicLink(atPath: nested.appendingPathComponent("external.png").path, withDestinationPath: "../../outside.png")

        let allowed = [
            "nested/deeper/image.png",
            "nested/Юникод пробел 100%.png",
            "nested/encoded/%D0%BA%D0%B0%D1%80%D1%82%D0%B8%D0%BD%D0%BA%D0%B0%20%25.png",
            "nested/internal.png"
        ]
        let blocked = [
            "../outside.png",
            outside.path,
            "file://\(outside.path)",
            "%2e%2e/outside.png",
            "%2E%2E%2Foutside.png",
            "nested/external.png",
            "missing%00.png",
            "missing\0.png"
        ]
        for (index, reference) in (allowed + blocked).enumerated() {
            try Data("<img src=\"\(reference)\">".utf8).write(to: sourceDirectory.appendingPathComponent("input-\(index).html"))
        }
        let originalEntries = recursiveEntries(at: sourceDirectory)

        for (index, reference) in allowed.enumerated() {
            let source = sourceDirectory.appendingPathComponent("input-\(index).html")
            let result = try PandocImportService.convert(source: source, executable: executable)
            XCTAssertTrue(result.text.contains("](data:image/png;base64,\(imageBase64))"), reference)
        }
        for (offset, reference) in blocked.enumerated() {
            let source = sourceDirectory.appendingPathComponent("input-\(allowed.count + offset).html")
            XCTAssertThrowsError(try PandocImportService.convert(source: source, executable: executable), reference)
        }
        let remote = sourceDirectory.appendingPathComponent("remote.html")
        try "<img src=\"https://example.invalid/image.png\">".write(to: remote, atomically: true, encoding: .utf8)
        let originalRemoteEntries = recursiveEntries(at: sourceDirectory)
        let remoteResult = try PandocImportService.convert(source: remote, executable: executable)
        XCTAssertTrue(remoteResult.text.contains("https://example.invalid/image.png"))
        XCTAssertFalse(remoteResult.text.contains("data:image/"))

        XCTAssertEqual(try Data(contentsOf: outside), image)
        XCTAssertEqual(recursiveEntries(at: sourceDirectory), originalRemoteEntries)
        XCTAssertEqual(originalRemoteEntries, originalEntries + ["remote.html"])
    }

    func testImportImageEscapesCanonicalPercentPathExactlyOnce() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = directory.appendingPathComponent("source%20root", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("source root", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = Data("OUTSIDE_SECRET".utf8)
        let decoy = Data("DECOY_IMAGE".utf8)
        let literal = Data("LITERAL_PERCENT".utf8)
        let outsideURL = directory.appendingPathComponent("outside.png")
        try outside.write(to: outsideURL)
        try decoy.write(to: sourceDirectory.appendingPathComponent("%2e%2e%2foutside.png"))
        try literal.write(to: sourceDirectory.appendingPathComponent("literal%20.png"))
        let decoySource = sourceDirectory.appendingPathComponent("decoy.html")
        let literalSource = sourceDirectory.appendingPathComponent("literal.html")
        try Data("<img src=\"%252e%252e%252foutside.png\">".utf8).write(to: decoySource)
        try Data("<img src=\"literal%2520.png\">".utf8).write(to: literalSource)
        let originalEntries = recursiveEntries(at: sourceDirectory)

        let decoyResult = try PandocImportService.convert(source: decoySource, executable: executable)
        let literalResult = try PandocImportService.convert(source: literalSource, executable: executable)
        let imported = decoyResult.text + literalResult.text

        XCTAssertTrue(decoyResult.text.contains("data:image/png;base64,\(decoy.base64EncodedString())"))
        XCTAssertTrue(literalResult.text.contains("data:image/png;base64,\(literal.base64EncodedString())"))
        XCTAssertFalse(imported.contains(outside.base64EncodedString()))
        XCTAssertEqual(try Data(contentsOf: outsideURL), outside)
        XCTAssertEqual(recursiveEntries(at: sourceDirectory), originalEntries)
    }

    func testComplexFigureIsNotFlattened() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("complex.html")
        let bytes = Data("<figure><img src=\"https://example.invalid/one.png\"><img src=\"https://example.invalid/two.png\"><figcaption>Caption</figcaption></figure>".utf8)
        try bytes.write(to: source)
        let imported = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertTrue(imported.text.contains("<figure"))
        XCTAssertTrue(imported.text.contains("one.png"))
        XCTAssertTrue(imported.text.contains("two.png"))
        XCTAssertTrue(imported.text.contains("Caption"))
        XCTAssertTrue(imported.diagnostics.contains(L10n.tr("复杂图片结构已保留为原始 HTML，预览可能无法显示。")))
        XCTAssertFalse(imported.diagnostics.contains("LACEDITOR_UNSUPPORTED_FIGURE"))
        let attributed = Data("<figure data-owner=\"demo\"><img src=\"https://example.invalid/one.png\"><figcaption>Caption</figcaption></figure>".utf8)
        try attributed.write(to: source)
        let withAttribute = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertEqual(try Data(contentsOf: source), attributed)
        XCTAssertTrue(withAttribute.text.contains("<figure"))
        XCTAssertTrue(withAttribute.text.contains("data-owner=\"demo\""))
        XCTAssertTrue(withAttribute.diagnostics.contains(L10n.tr("复杂图片结构已保留为原始 HTML，预览可能无法显示。")))
    }

    func testHTMLIframeIsNotFetched() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.html")
        try "<p>outer</p><iframe src=\"http://127.0.0.1:1/private\"></iframe>".write(to: source, atomically: true, encoding: .utf8)
        let result = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertTrue(result.text.contains("<iframe"))
        XCTAssertFalse(result.diagnostics.contains("Could not fetch"))
        XCTAssertFalse(result.diagnostics.contains("127.0.0.1"))
    }

    func testProcessFailureReportsDiagnosticsAndPreservesInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("pandoc")
        let source = directory.appendingPathComponent("source.html")
        try "#!/bin/sh\nprintf 'conversion failed' >&2\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "original".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PandocImportService.convert(source: source, executable: executable)) { error in
            XCTAssertTrue(error.localizedDescription.contains("conversion failed"))
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }

    func testHTMLLocalImagesAndRemoteLinks() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try XCTUnwrap(Data(base64Encoded: imageBase64)).write(to: directory.appendingPathComponent("image.png"))
        let source = directory.appendingPathComponent("-source.html")
        let html = "<p>中文 русский 😀</p><img src=\"image.png\"><img src=\"https://example.invalid/image.png\">"
        try html.write(to: source, atomically: true, encoding: .utf8)
        let result = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertTrue(result.text.contains("中文 русский 😀"))
        XCTAssertTrue(result.text.contains("data:image/png;base64,"))
        XCTAssertTrue(result.text.contains("https://example.invalid/image.png"))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), html)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("image.png"))
        XCTAssertThrowsError(try PandocImportService.convert(source: source, executable: executable))
    }

    func testEmbeddedImagesFromOfficeAndEbookFormats() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try XCTUnwrap(Data(base64Encoded: imageBase64)).write(to: directory.appendingPathComponent("image.png"))
        let markdown = directory.appendingPathComponent("input.md")
        try "中文 русский 😀\n\n![image](image.png)".write(to: markdown, atomically: true, encoding: .utf8)
        for format in ["docx", "odt", "epub"] {
            let source = directory.appendingPathComponent("input.\(format)")
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = directory
            process.arguments = ["--from=gfm", "--to=\(format)", "--output", source.path, markdown.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, format)
            let result = try PandocImportService.convert(source: source, executable: executable)
            XCTAssertTrue(result.text.contains("中文 русский 😀"), format)
            XCTAssertTrue(result.text.contains("data:image/png;base64,"), format)
            XCTAssertTrue(result.text.contains("](data:image/png;base64,"), format)
        }
    }

    func testFB2EmbeddedImage() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.fb2")
        let fb2 = """
        <?xml version="1.0" encoding="utf-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
        <description><title-info><book-title>Test</book-title><lang>ru</lang></title-info></description>
        <body><section><p>中文 русский 😀</p><image l:href="#image.png"/></section></body>
        <binary id="image.png" content-type="image/png">\(imageBase64)</binary></FictionBook>
        """
        try fb2.write(to: source, atomically: true, encoding: .utf8)
        let result = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertTrue(result.text.contains("中文 русский 😀"))
        XCTAssertTrue(result.text.contains("data:image/png;base64,"))
        XCTAssertTrue(result.text.contains("](data:image/png;base64,"))
    }
    func testHTMLImportKeepsTitleAuthorAndReadableBody() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("document.html")
        let bytes = Data("<html><head><title>Unique title</title><meta name=\"author\" content=\"Alice Example\"></head><body><h1>中文 😀 Heading</h1><p>Body</p></body></html>".utf8)
        try bytes.write(to: source)
        let result = try PandocImportService.convert(source: source, executable: executable)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertNotNil(MarkdownPresentationParser.frontMatter(result.text))
        XCTAssertTrue(result.text.contains("title: Unique title"))
        XCTAssertTrue(result.text.contains("Alice Example"))
        let presentation = MarkdownPresentationParser.parse(result.text)
        XCTAssertTrue(presentation.headings.contains { $0.title.contains("中文 😀 Heading") })
        let html = MarkdownRenderer.render(result.text, darkMode: false)
        XCTAssertTrue(html.contains("中文 😀 Heading</h1>"))
        XCTAssertTrue(html.contains("Body"))
        XCTAssertFalse(html.contains("Alice Example"))
    }

}
