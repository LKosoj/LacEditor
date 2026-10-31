import AppKit
import PDFKit
import WebKit
import XCTest
@testable import LacEditor

private final class PDFImageURLProtocol: URLProtocol {
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class MarkdownPDFExportTests: XCTestCase {
    func testPDFAndPlainHTMLHideCommentsButKeepCodeText() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "BEFORE 中文\n\n<!-- COMMENT_SECRET\ncontinued -->\n\n<script><!-- SCRIPT_SECRET --></script>\n\n<template><!-- TEMPLATE_SECRET --></template>\n\n```html\n<!-- CODE_LITERAL -->\n```\n\nAFTER 😀"
        let document = EditorDocument(text: source, language: .markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func export(_ mode: MarkdownPDFExportService.Mode, ext: String) async throws -> Data {
            let done = expectation(description: "comment export")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + "." + ext), mode: mode, window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
            await fulfillment(of: [done], timeout: 30)
            let url = try XCTUnwrap(output)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let data = try Data(contentsOf: url)
            withExtendedLifetime(service) {}
            return data
        }
        let pdfData = try await export(.pdf, ext: "pdf")
        let pdf = try XCTUnwrap(PDFDocument(data: pdfData))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("BEFORE"))
        XCTAssertTrue(text.contains("中文"))
        XCTAssertTrue(text.contains("AFTER"))
        XCTAssertTrue(text.contains("CODE_LITERAL"))
        XCTAssertFalse(text.contains("COMMENT_SECRET"))
        XCTAssertFalse(text.contains("SCRIPT_SECRET"))
        XCTAssertFalse(text.contains("TEMPLATE_SECRET"))
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = directory.appendingPathComponent("printed.pdf") as NSURL
        let printedData = try await export(.printJob(info), ext: "pdf")
        let printed = try XCTUnwrap(PDFDocument(data: printedData))
        let printedText = (0..<printed.pageCount).compactMap { printed.page(at: $0)?.string }.joined()
        XCTAssertTrue(printedText.contains("BEFORE"))
        XCTAssertTrue(printedText.contains("AFTER"))
        XCTAssertTrue(printedText.contains("CODE_LITERAL"))
        XCTAssertFalse(printedText.contains("COMMENT_SECRET"))
        let htmlData = try await export(.htmlPlain, ext: "html")
        let html = try XCTUnwrap(String(data: htmlData, encoding: .utf8))
        let outsideComments = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        XCTAssertFalse(outsideComments.contains("COMMENT_SECRET"))
        XCTAssertFalse(outsideComments.contains("SCRIPT_SECRET"))
        XCTAssertFalse(outsideComments.contains("TEMPLATE_SECRET"))
        XCTAssertTrue(html.contains("CODE_LITERAL"))
        XCTAssertEqual(document.text, source)
    }

    func testPlainHTMLRestoresRawRootBlocksOnlyAfterSerialization() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "before 中文\r\n\r\n<div id='keep' class='class' data-x='value'>\r\ninside\r\n</div>\r\n\r\n<script>window.RAW_SENTINEL=1</script>\r\n\r\n<style>.class{color:red}</style>\r\n\r\nafter 😀"
        let document = EditorDocument(text: source, language: .markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = expectation(description: "plain HTML raw blocks")
        var prepared: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("out.html"), mode: .htmlPlain, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { prepared = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let html = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(html.contains("<div id='keep' class='class' data-x='value'>\r\ninside\r\n</div>"))
        XCTAssertTrue(html.contains("<script>window.RAW_SENTINEL=1</script>"))
        XCTAssertTrue(html.contains("<style>.class{color:red}</style>"))
        XCTAssertTrue(html.contains("before 中文")); XCTAssertTrue(html.contains("after 😀"))
        XCTAssertFalse(html.contains("<!--LACRAW"))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testPlainHTMLRestoresContainerBlocksWithoutPrefixes() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for (first, continuation, wrapper) in [("> ", "> ", "blockquote"), ("- ", "  ", "li")] {
            let source = first + "<div id='keep'>\r\n" + continuation + "中文\r\n" + continuation + "</div>\r\n\r\nafter"
            let document = EditorDocument(text: source, language: .markdown)
            let done = expectation(description: "container raw HTML")
            var prepared: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + ".html"), mode: .htmlPlain, window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { prepared = file.preparedURL }
                done.fulfill()
            }
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
            await fulfillment(of: [done], timeout: 30)
            let file = try XCTUnwrap(prepared)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let html = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(html.contains("<" + wrapper))
            XCTAssertTrue(html.contains("<div id='keep'>\r\n中文\r\n</div>"))
            XCTAssertTrue(html.contains("after"))
            XCTAssertEqual(document.text, source)
            withExtendedLifetime(service) {}
        }
    }

    func testPlainHTMLRestoresInlineHTMLAroundMarkdown() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "Before <span class='keep' data-x='value'>**bold**</span> <script>const a=\"**x** ==y== :smile:\";</script> <textarea>**x** ==y== :smile:</textarea> after"
        let document = EditorDocument(text: source, language: .markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = expectation(description: "inline raw HTML")
        var prepared: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("out.html"), mode: .htmlPlain, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { prepared = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let html = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(html.contains("<span class='keep' data-x='value'><strong>bold</strong></span>"))
        XCTAssertTrue(html.contains("<script>const a=\"**x** ==y== :smile:\";</script>"))
        XCTAssertTrue(html.contains("<textarea>**x** ==y== :smile:</textarea>"))
        XCTAssertTrue(html.contains("Before ")); XCTAssertTrue(html.contains(" after"))
        XCTAssertFalse(html.contains("<!--LACRAW"))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testPlainHTMLPreservesMixedMediaNeighbours() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let site = directory.appendingPathComponent("site", isDirectory: true)
        let posts = directory.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: site.appendingPathComponent("movie.mp4"))
        let source = "---\ntypora-root-url: ../site\n---\n\n<div data-x='keep'>\r\n<video src='/movie.mp4'>Видео &amp; 中文</video><video><source src='/movie.mp4'>Запас &amp; 😀</video>\r\n<script>window.example=1</script><style>.x{color:red}</style>\r\n</div>"
        let document = EditorDocument(text: source, url: posts.appendingPathComponent("note.md"), language: .markdown)
        let destination = directory.appendingPathComponent("out.html")
        try Data("sentinel".utf8).write(to: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = expectation(description: "mixed raw media")
        var prepared: URL?
        let service = MarkdownPDFExportService(destination: destination, mode: .htmlPlain, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { prepared = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let html = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(html.contains("<div data-x='keep'>\r\n"))
        XCTAssertTrue(html.contains("data:video/mp4;base64," + bytes.base64EncodedString()))
        XCTAssertTrue(html.contains("Видео &amp; 中文</video>"))
        XCTAssertTrue(html.contains("Запас &amp; 😀</video>"))
        XCTAssertEqual(html.components(separatedBy: "data:video/mp4;base64,").count - 1, 2)
        XCTAssertTrue(html.contains("<script>window.example=1</script><style>.x{color:red}</style>"))
        XCTAssertFalse(html.contains("LACLOCALMEDIA"))
        XCTAssertEqual(try Data(contentsOf: destination), Data("sentinel".utf8))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testPlainHTMLRestoresInlineTagsInsideTableAndAnchor() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "| A |\n|---|\n| <span id='here' data-x='keep'>**bold**</span> |\n\n[jump](#here)"
        let document = EditorDocument(text: source, language: .markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = expectation(description: "table inline raw HTML")
        var prepared: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("out.html"), mode: .htmlPlain, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { prepared = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let html = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(html.contains("<span id='here' data-x='keep'><strong>bold</strong></span>"))
        XCTAssertTrue(html.contains("<table")); XCTAssertTrue(html.contains("href=\"#here\""))
        XCTAssertFalse(html.contains("<!--LACRAW"))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testPlainHTMLUnprovedSourceDoesNotOverwriteDestination() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.html")
        try Data("sentinel".utf8).write(to: destination)
        let source = "<div>\tunconfirmed</div>"
        let document = EditorDocument(text: source, language: .markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = expectation(description: "unproved source rejected")
        var failed = false
        let service = MarkdownPDFExportService(destination: destination, mode: .htmlPlain, window: window, isCurrent: { true }) { result in
            if case .failure = result { failed = true }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertTrue(failed)
        XCTAssertEqual(try Data(contentsOf: destination), Data("sentinel".utf8))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testTwitterWidgetUsesStaticTextInPDF() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "BEFORE\n\n<blockquote class='twitter-tweet'><p>Sunsets 中文</p><a href='https://x.com/Interior/status/463440424141459456'>Post</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>\n\nAFTER"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "Twitter static PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("twitter.pdf"), window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let url = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        for text in ["BEFORE", "Sunsets", "AFTER"] { XCTAssertFalse(pdf.findString(text, withOptions: []).isEmpty, text) }
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testStandaloneSVGAppearsInPDF() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "BEFORE\n\n<svg width='100' height='60'><rect width='100' height='60' fill='red'/></svg>\n\nAFTER"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "SVG PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("svg.pdf"), window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let url = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: url)), page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertFalse(pdf.findString("BEFORE", withOptions: []).isEmpty)
        XCTAssertFalse(pdf.findString("AFTER", withOptions: []).isEmpty)
        let thumbnail = page.thumbnail(of: NSSize(width: 600, height: 800), for: .mediaBox)
        let bitmap = try XCTUnwrap(thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var red = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 { red = true }
            }
        }
        XCTAssertTrue(red)
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testRubyPDFKeepsBaseAndReadingWithoutFallback() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for ruby in ["<ruby>漢<rp>(</rp><rt>READING</rt><rp>)</rp></ruby>",
                     "<ruby><strong>漢</strong><rt>READING</rt></ruby>"] {
            let source = "BEFORE " + ruby + " AFTER"
            let document = EditorDocument(text: source, language: .markdown)
            let done = expectation(description: "ruby PDF")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("ruby.pdf"), window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
            await fulfillment(of: [done], timeout: 30)
            let url = try XCTUnwrap(output)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let pdf = try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
            for value in ["BEFORE", "漢", "READING", "AFTER"] { XCTAssertTrue(text.contains(value), value) }
            XCTAssertFalse(text.contains("("))
            XCTAssertFalse(text.contains(")"))
            XCTAssertEqual(document.text, source)
            withExtendedLifetime(service) {}
        }
    }

    func testDisplayNoneIsAbsentFromPDF() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "BEFORE <span style='display:none'>HIDDEN <span style='color:red'>NESTED</span></span> AFTER"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "hidden span PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("hidden.pdf"), window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let url = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("BEFORE"))
        XCTAssertTrue(text.contains("AFTER"))
        XCTAssertFalse(text.contains("HIDDEN"))
        XCTAssertFalse(text.contains("NESTED"))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testClosedDetailsPrintsSummaryWithoutBody() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "BEFORE\n\n<details><summary><strong>SUMMARY</strong></summary><em>HIDDENBODY</em></details>\n\nAFTER"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "details PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("details.pdf"), window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let url = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("BEFORE"))
        XCTAssertTrue(text.contains("SUMMARY"))
        XCTAssertTrue(text.contains("AFTER"))
        XCTAssertFalse(text.contains("HIDDENBODY"))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testOpenRichDetailsPrintsSummaryAndBody() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "BEFORE\n\n<details open><summary><strong>SUMMARY</strong></summary><em>VISIBLEBODY</em></details>\n\nAFTER"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "open rich details PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("details.pdf"), window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let url = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("BEFORE")); XCTAssertTrue(text.contains("SUMMARY"))
        XCTAssertTrue(text.contains("VISIBLEBODY")); XCTAssertTrue(text.contains("AFTER"))
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testManualPageBreakMovesFollowingTextToNextPDFPage() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func export(_ source: String) async throws -> PDFDocument {
            let document = EditorDocument(text: source, language: .markdown)
            let done = expectation(description: "page-break PDF")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + ".pdf"), window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
            await fulfillment(of: [done], timeout: 30)
            let url = try XCTUnwrap(output)
            let pdf = try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            XCTAssertEqual(document.text, source)
            withExtendedLifetime(service) {}
            return pdf
        }
        let control = try await export("BEFOREBREAK\n\nAFTERBREAK")
        XCTAssertEqual(control.pageCount, 1)
        for tag in ["<div style=\"page-break-after:always\"></div>", "<div style=\"page-break-after: always; break-after: page;\"></div>"] {
            let pdf = try await export("BEFOREBREAK\n\n" + tag + "\n\nAFTERBREAK")
            XCTAssertEqual(pdf.pageCount, 2)
            XCTAssertTrue(pdf.page(at: 0)?.string?.contains("BEFOREBREAK") == true)
            XCTAssertTrue(pdf.page(at: 1)?.string?.contains("AFTERBREAK") == true)
        }
        func imageHeight(_ tag: String) async throws -> Int {
            let document = EditorDocument(text: "BEFOREBREAK\n\n" + tag + "\n\nAFTERBREAK", language: .markdown)
            let done = expectation(description: "page-break PNG")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + ".png"), mode: .png, window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
            await fulfillment(of: [done], timeout: 30)
            let url = try XCTUnwrap(output)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            withExtendedLifetime(service) {}
            return bitmap.pixelsHigh
        }
        let emptyHeight = try await imageHeight("<div></div>")
        let breakHeight = try await imageHeight("<div style=\"page-break-after:always\"></div>")
        XCTAssertEqual(breakHeight, emptyHeight)
    }

    func testPDFRendersConfirmedSpanStyle() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "before <span style='color:red;background:yellow;font-size:2rem'>COLORFUL</span> after"
        let document = EditorDocument(text: source, language: .markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let finished = expectation(description: "styled PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("output.pdf"), window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            finished.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [finished], timeout: 30)
        let url = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: url)), page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertFalse(pdf.findString("COLORFUL", withOptions: []).isEmpty)
        let bounds = page.bounds(for: .mediaBox), width = Int(ceil(bounds.width)), height = Int(ceil(bounds.height))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.setFillColor(NSColor.white.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        page.draw(with: .mediaBox, to: context.cgContext)
        var red = false, yellow = false
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 { red = true }
                if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent < 0.2 { yellow = true }
            }
        }
        XCTAssertTrue(red)
        XCTAssertTrue(yellow)
        XCTAssertEqual(document.text, source)
        withExtendedLifetime(service) {}
    }

    func testPDFKeepsStaticLocalAudioAndSurroundingText() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sound = Data("RIFF".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        func half(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        word(836); sound.append(Data("WAVEfmt ".utf8)); word(16)
        half(1); half(1); word(8000); word(8000); half(1); half(8)
        sound.append(Data("data".utf8)); word(800); sound.append(Data(repeating: 128, count: 800))
        try sound.write(to: directory.appendingPathComponent("sound.wav"))
        let sourceURL = directory.appendingPathComponent("note.md")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func distance(_ text: String) async throws -> CGFloat {
            let document = EditorDocument(text: text, url: sourceURL, language: .markdown)
            let done = expectation(description: "PDF media layout")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + ".pdf"), window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, sourceURL: sourceURL)
            await fulfillment(of: [done], timeout: 30)
            let url = try XCTUnwrap(output)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let pdf = try XCTUnwrap(PDFDocument(url: url))
            let page = try XCTUnwrap(pdf.page(at: 0))
            let before = try XCTUnwrap(pdf.findString("BEFOREMEDIA", withOptions: []).first).bounds(for: page)
            let after = try XCTUnwrap(pdf.findString("AFTERMEDIA", withOptions: []).first).bounds(for: page)
            withExtendedLifetime(service) {}
            return before.midY - after.midY
        }
        let baseline = try await distance("BEFOREMEDIA\n\nAFTERMEDIA")
        let withAudio = try await distance("BEFOREMEDIA\n\n<audio controls src='sound.wav'></audio>\n\nAFTERMEDIA")
        XCTAssertGreaterThan(withAudio, baseline)

    }

    func testPDFUsesParagraphAlignmentAndSpacingSnapshot() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let document = EditorDocument(text: "FIRSTALPHA\n\nSECONDOMEGA", language: .markdown)
        let snapshot = document.synchronizedSnapshot()
        func render(_ typography: MarkdownTypography) async throws -> (PDFDocument, URL) {
            let done = expectation(description: "PDF paragraph typography")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + ".pdf"),
                                                   window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            service.start(snapshot: snapshot, darkMode: false, typography: typography)
            await fulfillment(of: [done], timeout: 30)
            let url = try XCTUnwrap(output)
            let pdf = try XCTUnwrap(PDFDocument(url: url))
            withExtendedLifetime(service) {}
            return (pdf, url)
        }
        let left = try await render(MarkdownTypography(fontSize: 14, lineHeight: 20, usesCustomFontMetrics: false,
                                                       textAlignment: "left", paragraphSpacing: 0))
        defer { try? FileManager.default.removeItem(at: left.1.deletingLastPathComponent()) }
        let centered = try await render(MarkdownTypography(fontSize: 14, lineHeight: 20, usesCustomFontMetrics: false,
                                                           textAlignment: "center", paragraphSpacing: 80))
        defer { try? FileManager.default.removeItem(at: centered.1.deletingLastPathComponent()) }
        func positions(_ pdf: PDFDocument) throws -> (NSRect, NSRect) {
            let page = try XCTUnwrap(pdf.page(at: 0))
            let first = try XCTUnwrap(pdf.findString("FIRSTALPHA", withOptions: []).first).bounds(for: page)
            let second = try XCTUnwrap(pdf.findString("SECONDOMEGA", withOptions: []).first).bounds(for: page)
            XCTAssertGreaterThan(first.width, 0)
            XCTAssertGreaterThan(second.width, 0)
            return (first, second)
        }
        let leftBounds = try positions(left.0), centeredBounds = try positions(centered.0)
        XCTAssertGreaterThan(centeredBounds.0.minX, leftBounds.0.minX + 20)
        XCTAssertGreaterThan(centeredBounds.0.minY - centeredBounds.1.minY,
                             leftBounds.0.minY - leftBounds.1.minY + 40)
        XCTAssertEqual(document.text, "FIRSTALPHA\n\nSECONDOMEGA")
    }

    func testNativePDFUsesSnapshotAndLeavesDestinationUntouchedUntilInstall() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("output.pdf")
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        let document = EditorDocument(text: "[toc]\n\n# Contents heading\n\n" + String(repeating: "中文 and text\n\n", count: 200), language: .markdown)
        let snapshot = document.synchronizedSnapshot()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let finished = expectation(description: "native PDF")
        var output: URL?
        var exportError: Error?
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination as NSURL
        let service = MarkdownPDFExportService(destination: destination, mode: .printJob(info), window: window, isCurrent: { true }) { result in
            switch result {
            case let .success(.file(prepared)): output = prepared.preparedURL
            case .success(.printed): XCTFail("Expected a file")
            case let .failure(error): exportError = error
            }
            finished.fulfill()
        }
        service.start(snapshot: snapshot, darkMode: false)
        document.text = "later edit"
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertNil(exportError)
        let prepared = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
        let pdf = try XCTUnwrap(PDFDocument(url: prepared))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue((pdf.string ?? "").contains("中文"))
        XCTAssertGreaterThanOrEqual((pdf.string ?? "").components(separatedBy: "Contents heading").count, 3)
        XCTAssertEqual(document.text, "later edit")
    }

    func testConfiguredPaperAndMarginsProducePaginatedPDF() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.pdf")
        try Data("previous".utf8).write(to: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let document = EditorDocument(text: String(repeating: "Visible paragraph content.\n\n", count: 160), language: .markdown)
        let done = expectation(description: "configured PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        var options = MarkdownNativeExportOptions()
        options.paper = "custom"
        options.paperWidth = 400
        options.paperHeight = 500
        options.customMargins = true
        options.marginLeft = 50
        options.marginRight = 50
        options.marginTop = 50
        options.marginBottom = 50
        var headers = MarkdownPDFHeaderFooterOptions()
        headers.header = "Page ${pageNo} / ${pageCount}"
        headers.footer = "Document footer"
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, options: options, headers: headers)
        options.paperWidth = 700
        headers.header = "changed later"
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 400, accuracy: 1)
        XCTAssertEqual(bounds.height, 500, accuracy: 1)
        XCTAssertTrue((pdf.string ?? "").contains("Visible paragraph content"))
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            XCTAssertTrue(page.annotations.contains { $0.contents == "Page \(index + 1) / \(pdf.pageCount)" && $0.shouldPrint })
            XCTAssertTrue(page.annotations.contains { $0.contents == "Document footer" && $0.shouldPrint })
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
    }

    func testImageWidthAndFontSizeAffectCompleteOutput() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let document = EditorDocument(text: String(repeating: "Beginning and ending content.\n\n", count: 20), language: .markdown)
        func render(width: Double, font: Double, quality: String? = nil, colored: Bool = false) async throws -> NSBitmapImageRep {
            let done = expectation(description: "configured image")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + ".png"), mode: .png, window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            var options = MarkdownNativeExportOptions()
            options.imageWidth = width
            options.imageQuality = quality
            options.customImageFontSize = true
            options.imageFontSize = font
            var colors = MarkdownColorOverrides()
            if colored { colors.background = MarkdownSRGBColor(red: 1, green: 0, blue: 0) }
            let typography = MarkdownTypography(fontSize: 16, lineHeight: 24, lightColors: colors)
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, typography: typography, options: options)
            options.imageWidth = 100
            await fulfillment(of: [done], timeout: 30)
            let file = try XCTUnwrap(output)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        }
        let small = try await render(width: 400, font: 14)
        let wide = try await render(width: 600, font: 14)
        let largeText = try await render(width: 400, font: 24)
        let high = try await render(width: 400, font: 14, quality: "high")
        let best = try await render(width: 400, font: 14, quality: "best")
        let colored = try await render(width: 400, font: 14, colored: true)
        let pixel = try XCTUnwrap(colored.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.8)
        XCTAssertLessThan(pixel.greenComponent, 0.2)
        XCTAssertLessThan(pixel.blueComponent, 0.2)
        for bitmap in [high, best] {
            func containsText(_ rows: Range<Int>) -> Bool {
                for y in rows {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if color.redComponent < 0.5 && color.greenComponent < 0.5 && color.blueComponent < 0.5 { return true }
                    }
                }
                return false
            }
            XCTAssertTrue(containsText(0..<(bitmap.pixelsHigh / 2)))
            XCTAssertTrue(containsText((bitmap.pixelsHigh / 2)..<bitmap.pixelsHigh))
        }
        XCTAssertEqual(Double(best.pixelsWide) / Double(high.pixelsWide), 2, accuracy: 0.02)
        XCTAssertEqual(Double(best.pixelsHigh) / Double(high.pixelsHigh), 2, accuracy: 0.02)
        XCTAssertEqual(Double(high.pixelsWide) / Double(small.pixelsWide), 2, accuracy: 0.02)
        XCTAssertEqual(Double(high.pixelsHigh) / Double(small.pixelsHigh), 2, accuracy: 0.02)
        XCTAssertEqual(Double(wide.pixelsWide) / Double(small.pixelsWide), 1.5, accuracy: 0.02)
        XCTAssertEqual(small.pixelsWide, largeText.pixelsWide)
        XCTAssertGreaterThan(largeText.pixelsHigh, small.pixelsHigh)
    }

    func testPNGCustomFontKeepsHeadingNumberingSnapshot() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let document = EditorDocument(text: "# Heading\n\ntext", language: .markdown)
        func render(numbered: Bool) async throws -> NSBitmapImageRep {
            let done = expectation(description: "heading image")
            var output: URL?
            let service = MarkdownPDFExportService(destination: directory.appendingPathComponent(UUID().uuidString + ".png"), mode: .png, window: window, isCurrent: { true }) { result in
                if case let .success(.file(file)) = result { output = file.preparedURL }
                done.fulfill()
            }
            var options = MarkdownNativeExportOptions()
            options.imageWidth = 400
            options.customImageFontSize = true
            options.imageFontSize = 20
            let typography = MarkdownTypography(fontSize: 14, lineHeight: 20, numberHeadings: numbered)
            service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, typography: typography, options: options)
            await fulfillment(of: [done], timeout: 30)
            let file = try XCTUnwrap(output)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        }
        let plain = try await render(numbered: false)
        let numbered = try await render(numbered: true)
        XCTAssertEqual(plain.pixelsWide, numbered.pixelsWide)
        XCTAssertEqual(plain.pixelsHigh, numbered.pixelsHigh)
        var differentPixels = 0
        for y in 0..<min(plain.pixelsHigh, numbered.pixelsHigh) {
            for x in 0..<min(plain.pixelsWide, numbered.pixelsWide) {
                guard let first = plain.colorAt(x: x, y: y), let second = numbered.colorAt(x: x, y: y) else { continue }
                if !first.isEqual(second) { differentPixels += 1 }
            }
        }
        XCTAssertGreaterThan(differentPixels, 0)
        XCTAssertEqual(document.synchronizedSnapshot().text, "# Heading\n\ntext")
    }

    func testInvalidImageOptionsDoNotWriteDestination() throws {
        _ = NSApplication.shared
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var rejected = false
        let service = MarkdownPDFExportService(destination: destination, mode: .png, window: window, isCurrent: { true }) { result in
            if case let .failure(error as MarkdownPDFExportService.ExportError) = result, case .invalidOptions = error { rejected = true }
        }
        var options = MarkdownNativeExportOptions()
        options.imageWidth = 0
        service.start(snapshot: EditorDocument(text: "hello").synchronizedSnapshot(), darkMode: false, options: options)
        XCTAssertTrue(rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testImmediateCancellationSkipsMetadataStartup() async {
        _ = NSApplication.shared
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var currentChecks = 0
        var completions = 0
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: {
            currentChecks += 1
            return true
        }) { _ in completions += 1 }
        service.start(snapshot: EditorDocument(text: "---\ntitle: Test\n---\n\nbody").synchronizedSnapshot(), darkMode: false)
        service.cancel()
        await Task.yield()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(currentChecks, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testOnlyPDFFileJobsReadMetadata() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        XCTAssertFalse(MarkdownPDFExportService.Mode.printJob(info).requiresMetadata)
        info.jobDisposition = .save
        XCTAssertTrue(MarkdownPDFExportService.Mode.printJob(info).requiresMetadata)
        XCTAssertTrue(MarkdownPDFExportService.Mode.pdf.requiresMetadata)
        XCTAssertFalse(MarkdownPDFExportService.Mode.png.requiresMetadata)
    }

    func testPDFContainsYAMLMetadataAndTagsFallback() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("metadata.pdf")
        try Data("original".utf8).write(to: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "---\ntitle: \"**中文** title\"\nauthor: [Alice, Bob]\ncreator: LacEditor\nsubject: Test\ntags: [one, 中文]\ntypora-header: ''\ntypora-footer: '${title}'\n---\n\n# Heading\n\nBody"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "PDF metadata")
        var output: URL?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        var headers = MarkdownPDFHeaderFooterOptions()
        headers.header = "Should be empty"
        headers.allowDocumentOverrides = true
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, headers: headers)
        document.text = "later"
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        let attributes = try XCTUnwrap(pdf.documentAttributes)
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "中文 title")
        XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "Alice, Bob")
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "LacEditor")
        XCTAssertEqual(attributes[PDFDocumentAttribute.subjectAttribute] as? String, "Test")
        XCTAssertEqual(attributes[PDFDocumentAttribute.keywordsAttribute] as? [String], ["one", "中文"])
        XCTAssertEqual(pdf.outlineRoot?.child(at: 0)?.label, "Heading")
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertTrue(page.annotations.contains { $0.contents == "中文 title" && $0.shouldPrint })
        XCTAssertFalse(page.annotations.contains { $0.contents == "Should be empty" })
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertEqual(document.text, "later")
    }

    func testPageBreaksSeparateTopHeadingsAndFootnotes() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("output.pdf")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let document = EditorDocument(text: "# FirstHeading\n\nText.\n\n# SecondHeading\n\nReference[^a].\n\n[^a]: FootnoteContents", language: .markdown)
        let done = expectation(description: "page breaks")
        var output: URL?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL }
            done.fulfill()
        }
        var options = MarkdownNativeExportOptions()
        options.pageBreakTopHeadings = true
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, options: options)
        options.pageBreakTopHeadings = false
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        let root = try XCTUnwrap(pdf.outlineRoot)
        let first = try XCTUnwrap(root.child(at: 0)?.destination?.page)
        let second = try XCTUnwrap(root.child(at: 1)?.destination?.page)
        XCTAssertLessThan(pdf.index(for: first), pdf.index(for: second))
        let notePage = try XCTUnwrap((0..<pdf.pageCount).first { pdf.page(at: $0)?.string?.contains("FootnoteContents") == true })
        XCTAssertGreaterThan(notePage, pdf.index(for: second))
    }

    func testHTMLAppendFieldsPreserveLiteralYAML() throws {
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let source = "---\ntitle: 'Test *_literal_*'\ncurrentPath: fake\ntypora-append-head: |-\n  <meta name=\"description\" content=\"A &amp; B *_literal_*\">\nappend-body: '<script>const value = \"**literal**\";</script>'\n---\n\ntext"
        let metadata = try MarkdownPDFMetadataReader.read(source, includeHTMLFragments: true, isCancelled: { false })
        XCTAssertEqual(metadata.variables["typora-append-head"], "<meta name=\"description\" content=\"A &amp; B *_literal_*\">")
        XCTAssertEqual(metadata.variables["title"], "Test *_literal_*")
        XCTAssertNil(metadata.variables["currentPath"])
        XCTAssertEqual(metadata.variables["append-body"], "<script>const value = \"**literal**\";</script>")
    }

    func testUnstyledHTMLUsesRenderedMathDiagramAndPreservesSource() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md"), destination = directory.appendingPathComponent("result.html")
        let png = try XCTUnwrap(NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let markdown = "---\ntitle: 'A & B'\nappend-head: |\n  <meta name=\"description\" content=\"${title}\">\nappend-body-extra: |\n  <script>console.log('configured')</script>\n---\n\n[toc]\n\n# Heading 中文\n\n## Hidden heading\n\n- [x] done\n\n[link](https://example.com) and $x^2$ and :smile:\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n![picture](data:image/png;base64,\(data.base64EncodedString()))\n\n```mermaid\nflowchart LR\nA[Alpha] --> B[Beta]\n```\n\n<audio src=\"sound.mp3\"/>\n\n<video src=\"movie.mp4\" />\n\n<details><summary>Question?</summary><input type=checkbox checked> Answer</details>\n\n<iframe src=\"https://example.invalid/embed\" title=\"Example\">fallback</iframe>\n\nText <img src=\"photo.png\" alt=\"中文 &amp; emoji\" width=\"50\"> two  spaces\n\n<script>alert(1)</script>\n\n<style>body {color:red}</style>"
        try Data(markdown.utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let document = EditorDocument(text: markdown + "\n\n1. one", language: .markdown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = expectation(description: "unstyled HTML")
        var output: URL?
        var diagnostics = ""
        let service = MarkdownPDFExportService(destination: destination, mode: .htmlPlain, window: window, isCurrent: { true }) { result in
            if case let .success(.file(file)) = result { output = file.preparedURL; diagnostics = file.diagnostics }
            done.fulfill()
        }
        var htmlOptions = MarkdownHTMLExportOptions()
        htmlOptions.appendHead = "<meta name=\"global\" content=\"fallback\">"
        htmlOptions.appendBody = "<p>global footer</p>"
        htmlOptions.allowDocumentOverrides = true
        var listStyles = MarkdownListStyles()
        listStyles.ordered[1] = .upperRoman
        let typography = MarkdownTypography(fontSize: 16, lineHeight: 24, usesCustomFontMetrics: false, tocMaxLevel: 1, ligatures: 0, smallCapsLevels: [1], centeredHeadingLevels: [1], textAlignment: "justify", rightToLeft: true, verticalWriting: true, strikeCompletedTasks: true, numberHeadings: true, paragraphSpacing: 12, listStyles: listStyles, uppercaseHeadingLevels: [1])
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, typography: typography, htmlOptions: htmlOptions, syntax: .init(preserveExportWhitespace: true))
        htmlOptions.appendBody = "changed after start"
        await fulfillment(of: [done], timeout: 60)
        let file = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let html = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(html.contains("Heading 中文"))
        XCTAssertFalse(html.contains("font-variant-ligatures"))
        XCTAssertFalse(html.contains("font-variant:small-caps"))
        XCTAssertFalse(html.contains("text-align:justify"))
        XCTAssertFalse(html.contains("text-align:center"))
        XCTAssertFalse(html.contains("text-transform:uppercase"))
        XCTAssertFalse(html.contains("direction:rtl"))
        XCTAssertFalse(html.contains("writing-mode:vertical-rl"))
        XCTAssertFalse(html.contains("li:has(>span[data-lac-checked-task])"))
        XCTAssertFalse(html.contains("data-lac-checked-task"))
        XCTAssertFalse(html.contains("data-lac-heading-number"))
        XCTAssertFalse(html.contains("data-lac-list-depth"))
        XCTAssertFalse(html.contains("list-style-type:upper-roman"))
        XCTAssertTrue(html.contains("one"))
        XCTAssertTrue(html.contains("white-space:break-spaces"))
        XCTAssertTrue(html.contains("two  spaces"))
        XCTAssertFalse(html.contains("margin:0 0 12.0px"))
        XCTAssertTrue(html.contains("data-level=\"2\" hidden"))
        XCTAssertTrue(html.contains("Hidden heading"))
        XCTAssertTrue(html.contains("😄"))
        XCTAssertFalse(html.contains(":smile:"))
        XCTAssertTrue(html.contains("https://example.com"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("data-lac-math"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertTrue(html.contains("Alpha"))
        XCTAssertTrue(html.contains("Beta"))
        XCTAssertTrue(html.contains("<audio"))
        XCTAssertTrue(html.contains("sound.mp3"))
        XCTAssertTrue(html.contains("<video"))
        XCTAssertTrue(html.contains("movie.mp4"))
        XCTAssertTrue(html.contains("<details>"))
        XCTAssertTrue(html.contains("<summary>Question?</summary>"))
        XCTAssertTrue(html.contains("type=checkbox checked"))
        XCTAssertTrue(html.contains("<iframe"))
        XCTAssertTrue(html.contains("sandbox=\"allow-scripts\""))
        XCTAssertTrue(html.contains("https://example.invalid/embed"))
        XCTAssertTrue(html.contains("photo.png"))
        XCTAssertTrue(html.contains("中文 &amp; emoji"))
        XCTAssertTrue(html.contains("width=\"50\""))
        XCTAssertFalse(html.contains("flowchart LR"))
        XCTAssertTrue(html.contains("<title>A &amp; B</title>"))
        XCTAssertTrue(html.contains("name=\"description\" content=\"A &amp; B\""))
        XCTAssertTrue(html.contains("global footer"))
        XCTAssertFalse(html.contains("changed after start"))
        XCTAssertTrue(html.contains("console.log('configured')"))
        XCTAssertFalse(html.contains("fallback"))
        XCTAssertTrue(html.contains("alert(1)"))
        XCTAssertTrue(html.contains("body {color:red}"))
        XCTAssertEqual(diagnostics, L10n.tr("部分 HTML 内容无法包含在导出中。"))
        XCTAssertEqual(try Data(contentsOf: source), Data(markdown.utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testCancellationBeforeRenderingDoesNotWriteDestination() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("output.pdf")
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let finished = expectation(description: "cancelled")
        var cancelled = false
        var completions = 0
        var service: MarkdownPDFExportService? = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            completions += 1
            if case let .failure(error) = result, let error = error as? MarkdownPDFExportService.ExportError, case .cancelled = error { cancelled = true }
            finished.fulfill()
        }
        weak var weakService = service
        weakService = service
        service?.start(snapshot: EditorDocument(text: "text").synchronizedSnapshot(), darkMode: false)
        service?.cancel()
        service?.cancel()
        service = nil
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(weakService)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
    }

    func testWebProcessFailureIsReportedOnce() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var completions = 0
        var renderingFailure = false
        let service = MarkdownPDFExportService(destination: FileManager.default.temporaryDirectory.appendingPathComponent("output.pdf"), window: window, isCurrent: { true }) { result in
            completions += 1
            if case let .failure(error) = result, let error = error as? MarkdownPDFExportService.ExportError, case .rendering = error { renderingFailure = true }
        }
        let webView = WKWebView(frame: .zero)
        service.webViewWebContentProcessDidTerminate(webView)
        service.webViewWebContentProcessDidTerminate(webView)
        XCTAssertTrue(renderingFailure)
        XCTAssertEqual(completions, 1)
    }

    func testLocalMermaidAndEmbeddedImageAreReadyBeforePDF() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("output.pdf")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<32 {
            for x in 0..<32 { image.setColor(.red, atX: x, y: y) }
        }
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:])).base64EncodedString()
        for y in 0..<32 { for x in 0..<32 { image.setColor(.yellow, atX: x, y: y) } }
        PDFImageURLProtocol.data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        for y in 0..<32 { for x in 0..<32 { image.setColor(.orange, atX: x, y: y) } }
        let htmlPNG = try XCTUnwrap(image.representation(using: .png, properties: [:])).base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PDFImageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for y in 0..<32 { for x in 0..<32 { image.setColor(.magenta, atX: x, y: y) } }
        let site = directory.appendingPathComponent("site", isDirectory: true)
        let posts = directory.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: site.appendingPathComponent("local.png"))
        try "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='#00ffff'/></svg>"
            .write(to: site.appendingPathComponent("local.svg"), atomically: true, encoding: .utf8)
        let markdown = """
            ---
            typora-root-url: ../site
            ---

            # Heading

            ![red square](data:image/png;base64,\(png))

            ![local magenta square](/local.png)

            ![local cyan square](/local.svg)

            ![remote yellow square](https://8.8.8.8/yellow.png)

            <img src="data:image/png;base64,\(htmlPNG)" width="48" height="12">

            ```mermaid
            flowchart TD
            A[AlphaNode] --> B[BetaNode]
            style A fill:#00ff00,stroke:#00ff00
            style B fill:#0000ff,stroke:#0000ff,color:#ffffff
            ```
            """
        let document = EditorDocument(text: markdown, url: posts.appendingPathComponent("note.md"), language: .markdown)
        let finished = expectation(description: "resources and PDF")
        var output: URL?
        var exportError: Error?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }, imageSession: session) { result in
            switch result {
            case let .success(.file(prepared)): output = prepared.preparedURL
            case .success(.printed): XCTFail("Expected a file")
            case let .failure(error): exportError = error
            }
            finished.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, sourceURL: document.url, allowRemoteImages: true)
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertNil(exportError)
        let prepared = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: prepared))
        XCTAssertEqual(pdf.pageCount, 1)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width)), height = Int(ceil(bounds.height))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        context.cgContext.setFillColor(NSColor.white.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        page.draw(with: .mediaBox, to: context.cgContext)

        // Only the fixture image is red; the two Mermaid nodes are green and blue.
        // Check raster colors rather than PDF text because WebKit may draw SVG text as paths.
        // Pixel coordinates start at the top left; the image precedes both nodes in the document.
        var redY: Int?, greenY: Int?, blueY: Int?, magentaY: Int?, cyanY: Int?, yellowY: Int?, orangeY: Int?
        var orangeMinX = width, orangeMaxX = 0, orangeMinY = height, orangeMaxY = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 { redY = redY ?? y }
                if color.greenComponent > 0.8 && color.redComponent < 0.2 && color.blueComponent < 0.2 { greenY = greenY ?? y }
                if color.blueComponent > 0.8 && color.redComponent < 0.2 && color.greenComponent < 0.2 { blueY = blueY ?? y }
                if color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.2 { magentaY = magentaY ?? y }
                if color.greenComponent > 0.8 && color.blueComponent > 0.8 && color.redComponent < 0.2 { cyanY = cyanY ?? y }
                if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent < 0.2 { yellowY = yellowY ?? y }
                if color.redComponent > 0.8 && color.greenComponent > 0.3 && color.greenComponent < 0.7 && color.blueComponent < 0.2 {
                    orangeY = orangeY ?? y
                    orangeMinX = min(orangeMinX, x); orangeMaxX = max(orangeMaxX, x)
                    orangeMinY = min(orangeMinY, y); orangeMaxY = max(orangeMaxY, y)
                }
            }
        }
        let imageY = try XCTUnwrap(redY, "Embedded red image is missing from the PDF")
        XCTAssertNotNil(magentaY, "Root-relative local image is missing from the PDF")
        XCTAssertNotNil(cyanY, "Root-relative SVG is missing from the PDF")
        XCTAssertNotNil(yellowY, "Remote image is missing from the PDF")
        XCTAssertNotNil(orangeY, "HTML image is missing from the PDF")
        if orangeY != nil { XCTAssertEqual(Double(orangeMaxX - orangeMinX + 1) / Double(orangeMaxY - orangeMinY + 1), 4, accuracy: 0.6) }
        let firstNodeY = try XCTUnwrap(greenY, "First Mermaid node is missing from the PDF")
        let secondNodeY = try XCTUnwrap(blueY, "Second Mermaid node is missing from the PDF")
        XCTAssertLessThan(imageY, firstNodeY)
        XCTAssertLessThan(firstNodeY, secondNodeY)
        let pngDone = expectation(description: "root image in PNG")
        var pngOutput: URL?
        let pngService = MarkdownPDFExportService(destination: directory.appendingPathComponent("output.png"), mode: .png, window: window, isCurrent: { true }, imageSession: session) { result in
            if case let .success(.file(file)) = result { pngOutput = file.preparedURL }
            pngDone.fulfill()
        }
        pngService.start(snapshot: document.synchronizedSnapshot(), darkMode: false, sourceURL: document.url, allowRemoteImages: true)
        await fulfillment(of: [pngDone], timeout: 30)
        let pngFile = try XCTUnwrap(pngOutput)
        defer { try? FileManager.default.removeItem(at: pngFile.deletingLastPathComponent()) }
        let rendered = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: pngFile)))
        var foundMagenta = false, foundCyan = false, foundYellow = false, foundOrange = false
        var pngOrangeMinX = rendered.pixelsWide, pngOrangeMaxX = 0, pngOrangeMinY = rendered.pixelsHigh, pngOrangeMaxY = 0
        for y in 0..<rendered.pixelsHigh {
            for x in 0..<rendered.pixelsWide {
                guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.blueComponent > 0.8 && color.greenComponent < 0.2 { foundMagenta = true }
                if color.greenComponent > 0.8 && color.blueComponent > 0.8 && color.redComponent < 0.2 { foundCyan = true }
                if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent < 0.2 { foundYellow = true }
                if color.redComponent > 0.8 && color.greenComponent > 0.3 && color.greenComponent < 0.7 && color.blueComponent < 0.2 {
                    foundOrange = true
                    pngOrangeMinX = min(pngOrangeMinX, x); pngOrangeMaxX = max(pngOrangeMaxX, x)
                    pngOrangeMinY = min(pngOrangeMinY, y); pngOrangeMaxY = max(pngOrangeMaxY, y)
                }
            }
        }
        XCTAssertTrue(foundMagenta, "Root-relative local image is missing from the PNG")
        XCTAssertTrue(foundCyan, "Root-relative SVG is missing from the PNG")
        XCTAssertTrue(foundYellow, "Remote image is missing from the PNG")
        XCTAssertTrue(foundOrange, "HTML image is missing from the PNG")
        if foundOrange { XCTAssertEqual(Double(pngOrangeMaxX - pngOrangeMinX + 1) / Double(pngOrangeMaxY - pngOrangeMinY + 1), 4, accuracy: 0.6) }
    }
    func testPNGExportContainsRenderedFormulaPixels() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("math.png")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "before $\\color{red}{x}$\n\n$$\n\\color{blue}{\\frac{a}{b}}\n$$\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "formula PNG")
        var result: URL?
        let service = MarkdownPDFExportService(destination: destination, mode: .png, window: window, isCurrent: { true }) {
            if case let .success(.file(file)) = $0 { result = file.preparedURL }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(result)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        var red = false, blue = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.7 && color.greenComponent < 0.4 && color.blueComponent < 0.4 { red = true }
                if color.blueComponent > 0.7 && color.redComponent < 0.4 && color.greenComponent < 0.4 { blue = true }
            }
        }
        XCTAssertTrue(red)
        XCTAssertTrue(blue)
        XCTAssertEqual(document.text, source)
    }

    func testPNGExportUsesMathOptionsCapturedAtStart() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let document = EditorDocument(text: "$$\n\\dv{x}{t}\n$$", language: .markdown)
        let done = expectation(description: "PNG math options")
        var result: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("math.png"), mode: .png, window: window, isCurrent: { true }) {
            if case let .success(.file(file)) = $0 { result = file.preparedURL }
            done.fulfill()
        }
        var options = MathJaxRenderService.Options(physics: false, numbering: .none)
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false, mathOptions: options)
        options.physics = true
        await fulfillment(of: [done], timeout: 30)
        let file = try XCTUnwrap(result)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        var red = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.7 && color.greenComponent < 0.3 && color.blueComponent < 0.3 { red = true; break }
            }
            if red { break }
        }
        XCTAssertTrue(red, "The output must use the Physics setting captured at start")
    }

    func testPNGContainsBeginningAndEndAndPreservesDestination() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.png")
        try Data("old".utf8).write(to: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func image(_ color: NSColor) throws -> String {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            for y in 0..<20 { for x in 0..<20 { bitmap.setColor(color, atX: x, y: y) } }
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
        }
        let red = try image(.red), blue = try image(.blue)
        let source = "![start](data:image/png;base64,\(red))\n\n" + String(repeating: "middle paragraph\n\n", count: 120) + "![end](data:image/png;base64,\(blue))"
        let document = EditorDocument(text: source, language: .markdown)
        let finished = expectation(description: "continuous PNG")
        var output: URL?
        let service = MarkdownPDFExportService(destination: destination, mode: .png, window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { output = prepared.preparedURL }
            else { XCTFail("PNG export failed: \(result)") }
            finished.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        document.text = "later"
        await fulfillment(of: [finished], timeout: 30)
        let prepared = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: prepared)))
        XCTAssertGreaterThan(bitmap.pixelsHigh, bitmap.pixelsWide)
        var redY: Int?, blueY: Int?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 { redY = redY ?? y }
                if color.blueComponent > 0.8 && color.redComponent < 0.2 && color.greenComponent < 0.2 { blueY = blueY ?? y }
            }
        }
        XCTAssertLessThan(try XCTUnwrap(redY), try XCTUnwrap(blueY))
        XCTAssertEqual(document.text, "later")
    }

    func testUnsupportedPrintDestinationDoesNotStartPrintJob() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .preview
        let finished = expectation(description: "unsupported destination")
        var rejected = false
        let service = MarkdownPDFExportService(destination: nil, mode: .printJob(info), window: window, isCurrent: { true }) { result in
            if case let .failure(error) = result, let error = error as? MarkdownPDFExportService.ExportError,
               case .unsupportedPrintDestination = error { rejected = true }
            finished.fulfill()
        }
        service.start(snapshot: EditorDocument(text: "text").synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertTrue(rejected)
    }

    func testPDFBookmarksUsePrintedHeadingPositionsAndPreserveLinks() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.pdf")
        try Data("old".utf8).write(to: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let markdown = "# Same 中文\n\n## Child [link](https://example.com)\n\n" + String(repeating: "Filler paragraph\n\n", count: 200) + "# Same 中文\n\nEnd"
        let document = EditorDocument(text: markdown, language: .markdown)
        let done = expectation(description: "PDF bookmarks")
        var output: URL?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { output = prepared.preparedURL }
            else { XCTFail("PDF export failed: \(result)") }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let prepared = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: prepared))
        let root = try XCTUnwrap(pdf.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 2)
        let first = try XCTUnwrap(root.child(at: 0))
        let last = try XCTUnwrap(root.child(at: 1))
        XCTAssertEqual(first.label, "Same 中文")
        XCTAssertEqual(last.label, "Same 中文")
        let child = try XCTUnwrap(first.child(at: 0))
        XCTAssertEqual(child.label, "Child link")
        let firstDestination = try XCTUnwrap(first.destination)
        let lastDestination = try XCTUnwrap(last.destination)
        let firstPage = try XCTUnwrap(firstDestination.page)
        let lastPage = try XCTUnwrap(lastDestination.page)
        XCTAssertLessThan(pdf.index(for: firstPage), pdf.index(for: lastPage))
        XCTAssertTrue(firstPage.bounds(for: .mediaBox).contains(firstDestination.point))
        XCTAssertTrue(lastPage.bounds(for: .mediaBox).contains(lastDestination.point))
        let annotations = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.flatMap(\.annotations)
        XCTAssertTrue(annotations.contains { $0.url?.absoluteString == "https://example.com" })
        XCTAssertFalse(annotations.contains { $0.url?.host == "laceditor.invalid" })
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }


    func testPDFBookmarksEmptyLinkAndImageOnlyHeadings() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.pdf")
        try Data("old".utf8).write(to: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let markdown = "#\n\n## [only link](https://example.com)\n\n### ![image title](data:image/png;base64,\(png))"
        let done = expectation(description: "non-text heading bookmarks")
        var output: URL?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { output = prepared.preparedURL }
            else { XCTFail("PDF export failed: \(result)") }
            done.fulfill()
        }
        service.start(snapshot: EditorDocument(text: markdown, language: .markdown).synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 30)
        let prepared = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: prepared))
        let first = try XCTUnwrap(pdf.outlineRoot?.child(at: 0))
        XCTAssertEqual(first.label ?? "", "")
        let link = try XCTUnwrap(first.child(at: 0))
        XCTAssertEqual(link.label, "only link")
        XCTAssertEqual(link.child(at: 0)?.label, "image title")
        XCTAssertNotNil(first.destination?.page)
        XCTAssertNotNil(link.destination?.page)
        let annotations = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.flatMap(\.annotations)
        XCTAssertTrue(annotations.contains { $0.url?.absoluteString == "https://example.com" })
        XCTAssertFalse(annotations.contains { $0.url?.host == "laceditor.invalid" })
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testPDFIncludesRenderedFlowAndSequence() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.pdf")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = "```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\n```sequence\nAlice->Bob: Hello\n```"
        let document = EditorDocument(text: source, language: .markdown)
        let done = expectation(description: "diagram PDF")
        var output: URL?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { output = prepared.preparedURL }
            else { XCTFail("PDF failed: \(result)") }
            done.fulfill()
        }
        service.start(snapshot: document.synchronizedSnapshot(), darkMode: false)
        await fulfillment(of: [done], timeout: 60)
        let prepared = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: prepared))
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertFalse((page.string ?? "").contains("Alice->Bob"))
        XCTAssertFalse((page.string ?? "").contains("s=>start"))
        let image = page.thumbnail(of: NSSize(width: 600, height: 800), for: .mediaBox)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var darkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5,
                   color.redComponent < 0.7, color.greenComponent < 0.7, color.blueComponent < 0.7 { darkPixels += 1 }
            }
        }
        XCTAssertGreaterThan(darkPixels, 100)
        XCTAssertEqual(document.text, source)
    }

    func testPDFMathReferenceHasInternalDestinationAndRespectsPageRange() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.pdf")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let text = "---\ntitle: PDF math\n---\n\n# Source\n\n$$\n\\ref{eq:target} + \\ref{eq:target}\n$$\n\n[external](https://example.com)\n\n" +
            String(repeating: "Paragraph between formulas.\n\n", count: 150) +
            "# Target\n\n$$\nx=1\\tag{1}\\label{eq:target}\n$$\n"
        let document = EditorDocument(text: text, language: .markdown)
        let snapshot = document.synchronizedSnapshot()
        let complete = expectation(description: "math reference PDF")
        var fullURL: URL?
        let service = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { fullURL = prepared.preparedURL }
            else { XCTFail("PDF export failed: \(result)") }
            complete.fulfill()
        }
        var headers = MarkdownPDFHeaderFooterOptions()
        headers.header = "Page ${pageNo}"
        service.start(snapshot: snapshot, darkMode: false, headers: headers)
        await fulfillment(of: [complete], timeout: 60)
        let full = try XCTUnwrap(fullURL)
        defer { try? FileManager.default.removeItem(at: full.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: full))
        let root = try XCTUnwrap(pdf.outlineRoot)
        let sourcePage = try XCTUnwrap(root.child(at: 0)?.destination?.page)
        let targetPage = try XCTUnwrap(root.child(at: 1)?.destination?.page)
        let sourceIndex = pdf.index(for: sourcePage)
        XCTAssertLessThan(sourceIndex, pdf.index(for: targetPage))
        let targetIndex = pdf.index(for: targetPage)
        let mathLinks = sourcePage.annotations.filter { annotation in
            guard let page = annotation.destination?.page else { return false }
            return pdf.index(for: page) == targetIndex
        }
        XCTAssertEqual(mathLinks.count, 2)
        let link = try XCTUnwrap(mathLinks.first)
        XCTAssertGreaterThan(link.bounds.width, 2)
        XCTAssertGreaterThan(link.bounds.height, 2)
        XCTAssertTrue(targetPage.bounds(for: .mediaBox).contains(try XCTUnwrap(link.destination).point))
        XCTAssertTrue(sourcePage.annotations.contains { $0.url?.absoluteString == "https://example.com" })
        XCTAssertTrue(sourcePage.annotations.contains { $0.contents == "Page 1" && $0.shouldPrint })
        XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "PDF math")
        for index in 0..<pdf.pageCount {
            XCTAssertFalse(try XCTUnwrap(pdf.page(at: index)).annotations.contains { $0.url?.host == "laceditor.invalid" })
        }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = NSNumber(value: false)
        info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = NSNumber(value: sourceIndex + 1)
        info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = NSNumber(value: sourceIndex + 1)
        let selected = expectation(description: "source page only")
        var selectedURL: URL?
        let partialService = MarkdownPDFExportService(destination: destination, mode: .printJob(info), window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { selectedURL = prepared.preparedURL }
            else { XCTFail("Partial PDF failed: \(result)") }
            selected.fulfill()
        }
        partialService.start(snapshot: snapshot, darkMode: false)
        await fulfillment(of: [selected], timeout: 60)
        let partial = try XCTUnwrap(selectedURL)
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent()) }
        let selectedPDF = try XCTUnwrap(PDFDocument(url: partial))
        XCTAssertEqual(selectedPDF.pageCount, 1)
        let selectedPage = try XCTUnwrap(selectedPDF.page(at: 0))
        XCTAssertFalse(selectedPage.annotations.contains { $0.destination != nil || $0.url?.host == "laceditor.invalid" })
        XCTAssertTrue(selectedPage.annotations.contains { $0.url?.absoluteString == "https://example.com" })
        XCTAssertEqual(document.text, text)
    }

    func testPDFPageRangeRetainsOnlyBookmarksOnSelectedPage() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.pdf")
        try Data("old".utf8).write(to: destination)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let filler = String(repeating: "Paragraph before next heading\n\n", count: 100)
        let document = EditorDocument(text: "# First\n\n" + filler + "# Middle\n\n" + filler + "# Last\n", language: .markdown)
        let snapshot = document.synchronizedSnapshot()
        let complete = expectation(description: "all pages")
        var fullURL: URL?
        let fullService = MarkdownPDFExportService(destination: destination, window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { fullURL = prepared.preparedURL }
            else { XCTFail("Full PDF failed: \(result)") }
            complete.fulfill()
        }
        fullService.start(snapshot: snapshot, darkMode: false)
        await fulfillment(of: [complete], timeout: 30)
        let full = try XCTUnwrap(fullURL)
        defer { try? FileManager.default.removeItem(at: full.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: full))
        let root = try XCTUnwrap(pdf.outlineRoot)
        let first = try XCTUnwrap(root.child(at: 0)?.destination?.page)
        let middle = try XCTUnwrap(root.child(at: 1)?.destination?.page)
        let last = try XCTUnwrap(root.child(at: 2)?.destination?.page)
        let selectedPage = pdf.index(for: middle) + 1
        XCTAssertLessThan(pdf.index(for: first), pdf.index(for: middle))
        XCTAssertLessThan(pdf.index(for: middle), pdf.index(for: last))
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = NSNumber(value: false)
        info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = NSNumber(value: selectedPage)
        info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = NSNumber(value: selectedPage)
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination as NSURL
        let selected = expectation(description: "selected page")
        var selectedURL: URL?
        let service = MarkdownPDFExportService(destination: destination, mode: .printJob(info), window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { selectedURL = prepared.preparedURL }
            else { XCTFail("Selected PDF failed: \(result)") }
            selected.fulfill()
        }
        service.start(snapshot: snapshot, darkMode: false)
        await fulfillment(of: [selected], timeout: 30)
        let prepared = try XCTUnwrap(selectedURL)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        let result = try XCTUnwrap(PDFDocument(url: prepared))
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.outlineRoot?.numberOfChildren, 1)
        XCTAssertEqual(result.outlineRoot?.child(at: 0)?.label, "Middle")
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testPDFKeepsTypographySnapshotAfterPreferencesChange() async throws {
        _ = NSApplication.shared
        let suite = "MarkdownPDFTypographyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.editorFontSize = 28
        preferences.editorCodeFontFamily = "Menlo"
        preferences.markdownNumberHeadings = true
        let typography = try XCTUnwrap(preferences.markdownTypography)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let done = expectation(description: "PDF typography snapshot")
        var output: URL?
        let service = MarkdownPDFExportService(destination: directory.appendingPathComponent("result.pdf"), window: window, isCurrent: { true }) { result in
            if case let .success(.file(prepared)) = result { output = prepared.preparedURL }
            else { XCTFail("PDF export failed: \(result)") }
            done.fulfill()
        }
        service.start(snapshot: EditorDocument(text: "# Typography snapshot `CodeSentinel`").synchronizedSnapshot(), darkMode: false, typography: typography)
        preferences.editorFontSize = 9
        preferences.editorCodeFontFamily = nil
        preferences.markdownNumberHeadings = false
        await fulfillment(of: [done], timeout: 30)
        let prepared = try XCTUnwrap(output)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: prepared))
        let text = try XCTUnwrap(pdf.page(at: 0)?.attributedString)
        XCTAssertTrue(text.string.contains("1."))
        let range = (text.string as NSString).range(of: "Typography")
        XCTAssertNotEqual(range.location, NSNotFound)
        let font = try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(font.pointSize, 12)
        let codeRange = (text.string as NSString).range(of: "CodeSentinel")
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        let codeFont = try XCTUnwrap(text.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(codeFont.familyName, "Menlo")
        XCTAssertEqual(preferences.editorFontSize, 9)
    }

}
