import Foundation
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
        XCTAssertNil(PandocImportService.readers["pdf"])
        XCTAssertNil(PandocImportService.readers["txt"])
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
}
