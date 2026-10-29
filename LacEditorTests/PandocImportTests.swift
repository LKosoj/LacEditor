import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LacEditor

final class PandocImportTests: XCTestCase {
    private let imageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

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
