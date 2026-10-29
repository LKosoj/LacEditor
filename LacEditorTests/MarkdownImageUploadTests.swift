import AppKit
import cmark_gfm
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import LacEditor

private final class SVGForbiddenResourceHandler: NSObject, WKURLSchemeHandler {
    var requested = false
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        requested = true
        urlSchemeTask.didFailWithError(URLError(.cancelled))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class UploadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class DelayedUploadURLProtocol: URLProtocol {
    static var started: (() -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?() }
    override func stopLoading() { Self.stopped?() }
}

final class MarkdownImageUploadTests: XCTestCase {
    func testRemoteImagesKeepDistinctUnicodeAddressesAndFragments() async throws {
        let first = Data("<svg xmlns='http://www.w3.org/2000/svg'><rect fill='red'/></svg>".utf8)
        let second = Data("<svg xmlns='http://www.w3.org/2000/svg'><rect fill='blue'/></svg>".utf8)
        let composed = "https://example.invalid/é.svg", decomposed = "https://example.invalid/e\u{301}.svg"
        UploadURLProtocol.handler = { request in
            let address = try XCTUnwrap(request.url?.absoluteString)
            return (200, address.contains("%C3%A9") ? first : second)
        }
        defer { UploadURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let firstView = composed + "#é", secondView = composed + "#e\u{301}"
        let values = try await MarkdownImageUploadService.remoteImageDataURIs([composed, decomposed, firstView, secondView], session: session)
        XCTAssertEqual(values[Data(composed.utf8)], "data:image/svg+xml;base64," + first.base64EncodedString())
        XCTAssertEqual(values[Data(decomposed.utf8)], "data:image/svg+xml;base64," + second.base64EncodedString())
        XCTAssertTrue(try XCTUnwrap(values[Data(firstView.utf8)]).utf8.elementsEqual(("data:image/svg+xml;base64," + first.base64EncodedString() + MarkdownImageUploadService.fragmentSuffix(firstView)).utf8))
        XCTAssertTrue(try XCTUnwrap(values[Data(secondView.utf8)]).utf8.elementsEqual(("data:image/svg+xml;base64," + first.base64EncodedString() + MarkdownImageUploadService.fragmentSuffix(secondView)).utf8))
        XCTAssertEqual(values.count, 4)
    }
    func testHTMLImageScannerUsesExistingTree() throws {
        let source = "中文😀\n\nText <img src='a.png'>\n\n<script><img src='hidden.png'></script>\n\n<div><img src='b.png'></div>"
        let standalone = try MarkdownImageUploadService.images(in: source, allowSharedReference: true, htmlForExport: true)
        let reused = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, _, _ in
            let mapping = MarkdownPresentationParser.Source(source, root: root)
            return try? MarkdownImageUploadService.images(in: source, allowSharedReference: true, htmlForExport: true, root: root, sourceMapping: mapping)
        } ?? nil)
        XCTAssertEqual(reused.map(\.address), standalone.map(\.address))
        XCTAssertEqual(reused.map(\.range), standalone.map(\.range))
        let mixed = "[id]: /image.png\n\n![ref][id] $x <img src='inside.png'>$ <img src='outside.png'>"
        for inline in [false, true] {
            for legacy in [false, true] {
                let images = try XCTUnwrap(MarkdownMathExtension.withDocument(mixed, options: CMARK_OPT_TABLE_SPANS | CMARK_OPT_NOBREAKS, includeInline: inline, legacyInlineMath: legacy) { root, ext, _ in
                    let mapping = MarkdownPresentationParser.Source(mixed, root: root, textOrigins: MarkdownMathExtension.textOrigins(in: ext))
                    return try? MarkdownImageUploadService.images(in: mixed, allowSharedReference: true, htmlForExport: true, root: root, sourceMapping: mapping)
                } ?? nil)
                XCTAssertTrue(images.contains { $0.address == "outside.png" })
                XCTAssertFalse(images.contains { $0.address == "/image.png" })
            }
        }
    }
    func testImageAndRawMediaRangesAfterReferenceDefinition() throws {
        let imageSource = "[id]: https://example.invalid\n![图](image.png)" as NSString
        let images = try MarkdownImageUploadService.images(in: imageSource as String)
        XCTAssertEqual(images.count, 1)
        guard images.count == 1 else { return }
        XCTAssertEqual(images[0].range, imageSource.range(of: "![图](image.png)"))
        XCTAssertEqual(imageSource.substring(with: images[0].addressRange), "image.png")
        let mediaSource = "[id]: https://example.invalid\nbefore <video src='/movie.mp4'></video> after" as NSString
        let media = try MarkdownImageUploadService.mediaSources(in: mediaSource as String, isCancelled: { false })
        XCTAssertEqual(media.count, 1)
        guard media.count == 1 else { return }
        XCTAssertEqual(mediaSource.substring(with: media[0].addressRange), "/movie.mp4")
        let textarea = "[id]: https://example.invalid\nbefore <textarea>中文 &amp; value</textarea> after" as NSString
        let ranges = try MarkdownImageUploadService.textareaContents(in: textarea as String, isCancelled: { false })
        XCTAssertEqual(ranges, [textarea.range(of: "中文 &amp; value")])
    }
    func testStandaloneSVGDataRequiresSelfContainedShape() throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        XCTAssertEqual(MarkdownImageUploadService.standaloneSVGData(svg), Data(svg.utf8))
        let noNamespace = "<svg width='40' height='20'><circle cx='10' cy='10' r='8' fill='red'/></svg>"
        let data = try XCTUnwrap(MarkdownImageUploadService.standaloneSVGData(noNamespace))
        XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("xmlns=\"http://www.w3.org/2000/svg\""))
        for invalid in ["<svg width='40' height='20'><script/></svg>",
                        "<svg width='40' height='20' onload='x()'></svg>",
                        "<svg width='40' height='20'><image href='https://example.invalid/x'/></svg>",
                        "<svg width='40' height='20'><rect fill='currentColor'/></svg>",
                        "<svg width='40' height='20'><rect fill='not-a-color' stroke='none'/></svg>",
                        "<svg width='0x1p2' height='20'><rect fill='red' stroke='none'/></svg>",
                        "<svg width='100%' height='20'><rect/></svg>",
                        "<svg width='40' height='20'><rect></svg>",
                        "<!DOCTYPE svg><svg width='40' height='20'/>"] {
            XCTAssertNil(MarkdownImageUploadService.standaloneSVGData(invalid), invalid)
        }
        XCTAssertNil(MarkdownImageUploadService.standaloneSVGData(svg, isCancelled: { true }))
    }

    func testSVGPayloadKeepsBytesAndRejectsNonSVGOrMalformedXML() throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'><rect width='2' height='2'/></svg>".utf8)
        let payload = try MarkdownImageUploadService.payload(data: svg)
        XCTAssertEqual(payload.mime, "image/svg+xml")
        XCTAssertEqual(payload.data, svg)
        let uri = "data:image/svg+xml;base64," + svg.base64EncodedString()
        XCTAssertEqual(try MarkdownImageUploadService.payload(address: uri, document: nil).data, svg)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("image.svg")
        try svg.write(to: file)
        XCTAssertEqual(try MarkdownImageUploadService.payload(address: file.absoluteString, document: nil).data, svg)
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(data: Data("<svg xmlns='http://www.w3.org/2000/svg'><rect>".utf8)))
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(data: Data("<svg xmlns='https://example.invalid/not-svg'/>".utf8)))
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(data: Data("<html xmlns='http://www.w3.org/2000/svg'/>".utf8)))
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(address: "data:image/png;base64," + svg.base64EncodedString(), document: nil))
    }

    func testDownloadPreservesValidatedSVGBytes() async throws {
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'/>".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        UploadURLProtocol.handler = { _ in (200, data) }
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let result = try await MarkdownImageUploadService.download(URL(string: "https://example.invalid/image.svg")!, session: session)
        XCTAssertEqual(result.mime, "image/svg+xml")
        XCTAssertEqual(result.data, data)
    }

    func testUploadSendsOriginalSVGAndReportsProviderFailure() async throws {
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'/>".utf8)
        let payload = try MarkdownImageUploadService.payload(data: data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        var sent: Data?
        UploadURLProtocol.handler = { request in
            sent = request.httpBody
            return (200, Data(#"{"success":true,"result":["https://example.invalid/result.svg"]}"#.utf8))
        }
        let endpoint = URL(string: "https://example.invalid/upload")!
        let urls = try await MarkdownImageUploadService.uploadToPicGo([payload], endpoint: endpoint, session: session)
        XCTAssertEqual(urls.first?.absoluteString, "https://example.invalid/result.svg")
        XCTAssertNotNil(sent?.range(of: data))
        XCTAssertTrue(String(decoding: sent ?? Data(), as: UTF8.self).contains("Content-Type: image/svg+xml"))
        UploadURLProtocol.handler = { _ in (415, Data()) }
        do {
            _ = try await MarkdownImageUploadService.uploadToPicGo([payload], endpoint: endpoint, session: session)
            XCTFail("Expected provider failure")
        } catch { XCTAssertTrue(error is MarkdownImageUploadService.UploadError) }
    }

    @MainActor
    func testUploadedSVGFragmentIsPreservedOrReported() async throws {
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
        let payload = try MarkdownImageUploadService.payload(data: data)
        let source = "![x](sprite.svg#view)"
        let images = try MarkdownImageUploadService.images(in: source)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        for suffix in ["", "#view", "#other"] {
            let returned = "https://example.invalid/result.svg" + suffix
            UploadURLProtocol.handler = { _ in (200, try JSONSerialization.data(withJSONObject: ["success": true, "result": [returned]])) }
            let urls = try await MarkdownImageUploadService.uploadToPicGo([payload], endpoint: URL(string: "https://example.invalid/upload")!, session: session)
            if suffix == "#other" {
                do {
                    _ = try MarkdownImageUploadService.replacement(in: source, images: images, urls: urls, selection: NSRange(location: 0, length: 0))
                    XCTFail("Expected selector conflict")
                } catch let issue as MarkdownImageUploadService.UploadError {
                    XCTAssertTrue(issue.reportsUploadedResources)
                    XCTAssertTrue(issue.localizedDescription.contains(returned))
                    let document = EditorDocument(text: source, language: .markdown)
                    ClipboardSavedImagesNotice(documentID: document.id, message: issue.localizedDescription).deliver(to: document)
                    XCTAssertTrue(document.statusMessage?.contains(returned) == true)
                    XCTAssertEqual(document.text, source)
                }
            } else {
                let edit = try MarkdownImageUploadService.replacement(in: source, images: images, urls: urls, selection: NSRange(location: 0, length: 0))
                let changed = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                XCTAssertEqual(changed, "![x](https://example.invalid/result.svg#view)")
            }
        }
    }

    func testReplacementValidatesFinalAddressWithPreservedSVGFragments() throws {
        let destination = try XCTUnwrap(URL(string: "https://example.invalid/out%23v(1).svg?x=1&y=2"))
        for source in ["![x](sprite.svg#one)", "![x][ref]\n\n[ref]: sprite.svg#one", "<img src='sprite.svg#one'>"] {
            let images = try MarkdownImageUploadService.images(in: source, allowSharedReference: true)
            XCTAssertEqual(images.count, 1, source)
            let edit = try MarkdownImageUploadService.replacement(in: source, images: images, urls: [destination],
                selection: NSRange(location: 0, length: 0))
            let changed = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            let result = try MarkdownImageUploadService.images(in: changed, allowSharedReference: true)
            let expected = destination.absoluteString + "#one"
            if case .html = images[0].syntax {
                XCTAssertEqual(result.first?.address, expected, source)
            } else {
                XCTAssertEqual(result.first?.address, expected.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29"), source)
            }
            XCTAssertEqual(source.contains("sprite.svg#one"), true)
        }
        let multiple = "![a](sprite.svg#one) <img src='sprite.svg#two'>"
        let images = try MarkdownImageUploadService.images(in: multiple)
        let file = URL(fileURLWithPath: "/tmp/out #1(2).svg")
        let edit = try MarkdownImageUploadService.replacement(in: multiple, images: images, urls: [file, file],
            selection: NSRange(location: 0, length: 0), filePaths: true)
        let changed = (multiple as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        let result = try MarkdownImageUploadService.images(in: changed)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].address.hasSuffix("#one"))
        XCTAssertTrue(result[1].address.hasSuffix("#two"))
        XCTAssertTrue(result[0].address.contains("%23"))
        XCTAssertTrue(result[0].address.contains("%28"))
    }
    @MainActor
    func testSVGImageContextRendersViewBoxAndRejectsInvalidInput() async throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10"><rect width="10" height="10" fill="red"/><image href="lacprobe://outside/image" width="10" height="10"/><script>document.querySelector('rect').setAttribute('fill','blue')</script></svg>
        """
        let done = expectation(description: "SVG rendered")
        var result: NSImage?
        let handler = SVGForbiddenResourceHandler(), configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "lacprobe")
        let service = MarkdownSVGRenderService(encoded: Data(svg.utf8).base64EncodedString(), width: 100, configuration: configuration) { image in result = image; done.fulfill() }
        service.start()
        await fulfillment(of: [done], timeout: 10)
        let image = try XCTUnwrap(result)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let red = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let clear = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(red.redComponent, 0.8)
        XCTAssertLessThan(red.blueComponent, 0.2)
        XCTAssertLessThan(clear.alphaComponent, 0.1)
        XCTAssertFalse(handler.requested)
        let invalidDone = expectation(description: "invalid SVG rejected")
        let invalid = MarkdownSVGRenderService(encoded: Data("not an SVG".utf8).base64EncodedString(), width: 100) { image in XCTAssertNil(image); invalidDone.fulfill() }
        invalid.start()
        await fulfillment(of: [invalidDone], timeout: 10)
        let cancelled = expectation(description: "cancelled SVG completes once")
        let cancellation = MarkdownSVGRenderService(encoded: Data(svg.utf8).base64EncodedString(), width: 100) { image in XCTAssertNil(image); cancelled.fulfill() }
        cancellation.start()
        cancellation.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
    }

    @MainActor
    func testSVGFragmentSelectsView() async throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 10'><view id='right' viewBox='10 0 10 10'/><rect width='10' height='10' fill='red'/><rect x='10' width='10' height='10' fill='blue'/></svg>"
        let done = expectation(description: "SVG view")
        var result: NSImage?
        let service = MarkdownSVGRenderService(encoded: Data(svg.utf8).base64EncodedString(), fragment: MarkdownImageUploadService.fragmentSuffix("sprite%231.svg#right"), width: 100) { image in result = image; done.fulfill() }
        service.start()
        await fulfillment(of: [done], timeout: 10)
        let bitmap = try XCTUnwrap(try XCTUnwrap(result).tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, 0.8)
        XCTAssertLessThan(color.redComponent, 0.2)
    }

    @MainActor
    func testSVGReturnsIntrinsicSizeBeforeWidthFit() async throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><rect width='200' height='100' fill='red'/></svg>"
        let done = expectation(description: "SVG intrinsic size")
        var result: NSImage?
        let service = MarkdownSVGRenderService(encoded: Data(svg.utf8).base64EncodedString(), width: 80) { image in result = image; done.fulfill() }
        service.start()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(service.intrinsicSize, CGSize(width: 200, height: 100))
        XCTAssertEqual(try XCTUnwrap(result).size, CGSize(width: 80, height: 40))
    }
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    func testUploadPayloadUsesDocumentResourceRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("a#b.png")
        try png.write(to: image)
        let document = directory.appendingPathComponent("note.md")
        let paths = try MarkdownResourcePaths(text: "---\ntypora-root-url: .\n---\n", document: document)
        let payload = try MarkdownImageUploadService.payload(address: "/a%23b.png", document: document, paths: paths)
        XCTAssertEqual(payload.data, png)
        XCTAssertEqual(payload.localURL?.path, image.path)
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(address: "/a#b.png", document: document, paths: paths))
    }

    @MainActor
    func testUploadSettingsDefaultOffAndPersist() throws {
        let suite = "MarkdownImageUploadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.markdownImageUploadConfiguration.method, "disabled")
        XCTAssertFalse(preferences.markdownImageUploadConfiguration.automaticOnline)
        let config = MarkdownImageUploadConfiguration(method: "picgo", endpoint: "https://example.com/upload", executable: "", arguments: "")
        preferences.markdownImageUploadConfiguration = config
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownImageUploadConfiguration, config)
        XCTAssertFalse(AppPreferences(defaults: defaults).markdownImageUploadConfiguration.automaticLocal)
        let legacy = Data(#"{"method":"command","endpoint":"","executable":"/bin/sh","arguments":""}"#.utf8)
        let decoded = try JSONDecoder().decode(MarkdownImageUploadConfiguration.self, from: legacy)
        XCTAssertFalse(decoded.automaticLocal)
        XCTAssertFalse(decoded.allowDocumentCopy)
        XCTAssertTrue(decoded.copyFolder.isEmpty)
        preferences.markdownImageUploadConfiguration.allowDocumentCopy = true
        preferences.markdownImageUploadConfiguration.copyFolder = "/tmp/图片 folder"
        let restored = AppPreferences(defaults: defaults).markdownImageUploadConfiguration
        XCTAssertTrue(restored.allowDocumentCopy)
        XCTAssertEqual(restored.copyFolder, "/tmp/图片 folder")
    }

    func testHTMLAttributeExportPreparationDoesNotRunForUpload() throws {
        let source = "Text <img src=photo.png alt='&copy;'>"
        let upload = try MarkdownImageUploadService.images(in: source)
        let export = try MarkdownImageUploadService.images(in: source, htmlForExport: true)
        XCTAssertNil(try XCTUnwrap(upload.first).htmlXML)
        XCTAssertNotNil(try XCTUnwrap(export.first).htmlXML)
        XCTAssertEqual(upload.first?.address, export.first?.address)
        let simple = try MarkdownImageUploadService.images(in: "Text <img src=\"data:image/png;base64,AAAA\" alt=\"ok\">", htmlForExport: true)
        XCTAssertNil(try XCTUnwrap(simple.first).htmlXML)
    }

    func testHTMLImageScanHonorsCancellationWithinLongAttribute() {
        let source = "Text <img src=\"" + String(repeating: "a", count: 5000) + ".png\">"
        var checks = 0
        let limit = (source as NSString).length + 30
        XCTAssertThrowsError(try MarkdownImageUploadService.images(in: source, isCancelled: {
            checks += 1
            return checks > limit
        }, htmlForExport: true)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThan(checks, limit)
    }

    func testHTMLTagNameWithColonDoesNotStartScriptContext() throws {
        let source = "<div><script:example></script:example><img src='actual.png'></div>\n"
        let images = try MarkdownImageUploadService.images(in: source)
        XCTAssertEqual(images.map(\.address), ["actual.png"])
        let afterScript = "<div><script>hidden</script/><img src='after.png'></div>\n"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: afterScript).map(\.address), ["after.png"])
    }

    func testScriptDoubleEscapingDoesNotExposeHiddenImage() throws {
        let source = "<div><script><!--<script></script><img src='hidden.png'></script><img src='real.png'></div>\n"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: source).map(\.address), ["real.png"])
        let split = "before <script><!--<script></script><img src='hidden.png'></script> after\n\nText <img src='real.png'>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: split).map(\.address), ["real.png"])
    }

    func testHTMLContextFollowsScriptAcrossConfirmedNodesAndInvalidation() {
        let source = "😀<script><!--<script></script><iframe src='https://hidden.example'></iframe></script><iframe src='https://visible.example'></iframe>" as NSString
        let opening = source.range(of: "<script>")
        let firstClose = source.range(of: "</script>")
        let hidden = source.range(of: "<iframe src='https://hidden.example'></iframe>")
        let secondClose = source.range(of: "</script>", options: [], range: NSRange(location: NSMaxRange(hidden), length: source.length - NSMaxRange(hidden)))
        let visible = source.range(of: "<iframe src='https://visible.example'></iframe>")
        var context = MarkdownImageUploadService.HTMLContext()
        XCTAssertFalse(context.inRawContext)
        XCTAssertFalse(context.consume(source: source, range: opening))
        XCTAssertTrue(context.inRawContext)
        XCTAssertFalse(context.consume(source: source, range: firstClose))
        XCTAssertFalse(context.consume(source: source, range: hidden))
        XCTAssertFalse(context.consume(source: source, range: secondClose))
        XCTAssertFalse(context.inRawContext)
        XCTAssertTrue(context.consume(source: source, range: visible))
        context.invalidate()
        XCTAssertTrue(context.inRawContext)
        XCTAssertFalse(context.consume(source: source, range: visible))
    }

    func testHTMLContextReportsExactTagsOutsideRawText() {
        let source = "😀<div><!-- <a id='comment'> --><script><a id='hidden'></script><a id='中>文'></a></div>" as NSString
        var context = MarkdownImageUploadService.HTMLContext()
        var tags: [(String, String, Bool)] = []
        XCTAssertTrue(context.consume(source: source, range: NSRange(location: 2, length: source.length - 2), confirmedTag: { range, name, closing in
            tags.append((source.substring(with: range), name, closing))
        }))
        XCTAssertEqual(tags.map { $0.0 }, ["<div>", "<script>", "<a id='中>文'>", "</a>", "</div>"])
        XCTAssertEqual(tags.map { $0.1 }, ["div", "script", "a", "a", "div"])
        XCTAssertEqual(tags.map { $0.2 }, [false, false, false, true, true])
    }

    func testImagesAfterHTMLCommentClosuresRemainVisible() throws {
        for comment in ["<!-->", "<!--->", "<!-- text --!>"] {
            let source = "<div>\(comment)<img src='visible.png'></div>\n"
            XCTAssertEqual(try MarkdownImageUploadService.images(in: source).map(\.address), ["visible.png"], comment)
        }
    }

    func testLongScriptContextHonorsCancellation() {
        let source = "<script><!--" + String(repeating: "x", count: 5000) + "</script>\n\n<img src='real.png'>"
        var checks = 0
        let limit = (source as NSString).length + 100
        XCTAssertThrowsError(try MarkdownImageUploadService.images(in: source, isCancelled: {
            checks += 1
            return checks > limit
        }, htmlForExport: true)) { XCTAssertTrue($0 is CancellationError) }
    }

    @MainActor
    func testSettingsUploaderTestRunsOnlyOnButton() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("ran")
        let suite = "MarkdownImageUploadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "command", executable: "/bin/sh",
            arguments: "-c\ntouch \"$1\"; printf 'https://example.com/test.png\\n'\nupload\n\(marker.path)")
        let state = AppState(initialDocument: EditorDocument(), recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(state))
        window.makeKeyAndOrderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        func button(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == L10n.tr("测试") { return button }
            return view.subviews.compactMap(button).first
        }
        let testButton = try XCTUnwrap(window.contentView.flatMap(button))
        testButton.performClick(nil)
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        func containsURL(_ view: NSView) -> Bool {
            if let field = view as? NSTextField, field.stringValue.contains("https://example.com/test.png") { return true }
            return view.subviews.contains(where: containsURL)
        }
        for _ in 0..<150 where !(window.contentView.map(containsURL) ?? false) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(window.contentView.map(containsURL) ?? false)
        let started = directory.appendingPathComponent("started")
        let late = directory.appendingPathComponent("late")
        preferences.markdownImageUploadConfiguration.arguments = "-c\ntouch \"$1\"; sleep 1; touch \"$2\"; printf 'https://example.com/test.png\\n'\nupload\n\(started.path)\n\(late.path)"
        try await Task.sleep(for: .milliseconds(100))
        try XCTUnwrap(window.contentView.flatMap(button)).performClick(nil)
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        preferences.markdownImageUploadConfiguration.endpoint = "changed"
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }
    func testPicGoSendsBytesAndRejectsPartialResults() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "中.png", mime: "image/png")
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/upload"))
        UploadURLProtocol.handler = { request in
            XCTAssertEqual(request.url, endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertNotNil(body.range(of: payload.data))
            XCTAssertNotNil(body.range(of: Data("name=\"files\"".utf8)))
            return (200, Data(#"{"success":true,"result":["https://example.com/a","https://example.com/b"]}"#.utf8))
        }
        let urls = try await MarkdownImageUploadService.uploadToPicGo([payload, payload], endpoint: endpoint, session: session)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/a", "https://example.com/b"])
        UploadURLProtocol.handler = { _ in (200, Data(#"{"success":true,"result":["https://example.com/a"]}"#.utf8)) }
        do {
            _ = try await MarkdownImageUploadService.uploadToPicGo([payload, payload], endpoint: endpoint, session: session)
            XCTFail("Expected partial response to fail")
        } catch { XCTAssertEqual(error as? MarkdownImageUploadService.UploadError, .invalidResult) }
    }

    @MainActor
    func testUploadNoticeKeepsExistingDocumentStatusWithoutManager() {
        let document = EditorDocument(text: "source", language: .markdown)
        document.statusMessage = "newer action"
        let notice = ClipboardSavedImagesNotice(documentID: document.id, message: "uploaded URL")
        notice.deliver(to: document)
        XCTAssertEqual(document.statusMessage, "newer action\nuploaded URL")
        notice.deliver(to: document)
        XCTAssertEqual(document.statusMessage, "newer action\nuploaded URL")
        XCTAssertEqual(document.synchronizedText(), "source")
    }

    func testPicListEndpointRejectsMalformedURLAndSeparatesKey() throws {
        XCTAssertNil(PicListKeychainStore.endpointWithoutKey("http://[bad?key=secret"))
        let value = try XCTUnwrap(PicListKeychainStore.endpointWithoutKey("https://example.com/upload?configName=Docs&key=secret%20value"))
        XCTAssertEqual(value.endpoint, "https://example.com/upload?configName=Docs")
        XCTAssertEqual(value.key, "secret value")
        var previous = MarkdownImageUploadConfiguration(method: "picgo", endpoint: "https://example.com/upload?key=old-secret")
        previous.method = "piclist"
        let migrated = try XCTUnwrap(PicListKeychainStore.endpointWithoutKey(previous.endpoint))
        previous.endpoint = migrated.endpoint
        XCTAssertEqual(previous.endpoint, "https://example.com/upload")
        XCTAssertEqual(migrated.key, "old-secret")
    }

    func testPicListKeychainSeparatesEndpointsAndNamespaces() throws {
        let namespace = UUID().uuidString
        let first = PicListKeychainStore(namespace: namespace)
        let other = PicListKeychainStore(namespace: namespace + "-other")
        let endpoint = "https://example.com/upload"
        defer { try? first.save("", endpoint: endpoint) }
        try first.save("secret", endpoint: endpoint)
        XCTAssertEqual(try first.load(endpoint: endpoint), "secret")
        XCTAssertNil(try first.load(endpoint: "https://other.example.com/upload"))
        XCTAssertNil(try other.load(endpoint: endpoint))
        try first.save("changed", endpoint: endpoint)
        XCTAssertEqual(try first.load(endpoint: endpoint), "changed")
        try first.save("", endpoint: endpoint)
        XCTAssertNil(try first.load(endpoint: endpoint))
    }

    func testPicListUploadsEachFileAndKeepsOrder() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let first = MarkdownImageUploadService.Payload(data: png, filename: "one.png", mime: "image/png")
        let second = MarkdownImageUploadService.Payload(data: png, filename: "two.png", mime: "image/png")
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/upload?configName=Docs"))
        var seen: [String] = []
        UploadURLProtocol.handler = { request in
            let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "configName", value: "Docs")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "key", value: "secret & more")))
            let body = try XCTUnwrap(request.httpBody)
            let text = try XCTUnwrap(String(data: body, encoding: .isoLatin1))
            XCTAssertTrue(text.contains("name=\"file\""))
            XCTAssertFalse(text.contains("name=\"files\""))
            XCTAssertNotNil(body.range(of: self.png))
            let filename = text.contains("one.png") ? "one" : "two"
            seen.append(filename)
            return (200, Data("{\"success\":true,\"result\":[\"https://example.com/\(filename)\"]}".utf8))
        }
        let urls = try await MarkdownImageUploadService.uploadToPicList([first, second], endpoint: endpoint, key: "secret & more", session: session)
        XCTAssertEqual(seen, ["one", "two"])
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/one", "https://example.com/two"])
    }

    func testPicListPreservesSuccessfulURLsWhenLaterUploadFails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        var requests = 0
        UploadURLProtocol.handler = { _ in
            requests += 1
            return requests == 1
                ? (200, Data(#"{"success":true,"result":["https://example.com/first.png"]}"#.utf8))
                : (500, Data())
        }
        do {
            _ = try await MarkdownImageUploadService.uploadToPicList([payload, payload], endpoint: URL(string: "https://example.com/upload")!, key: nil, session: session)
            XCTFail("Expected partial upload")
        } catch let MarkdownImageUploadService.UploadError.picListPartial(urls, _) {
            XCTAssertEqual(urls, ["https://example.com/first.png"])
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 2)
    }

    func testPicListFinishesUploadedFileWithoutSendingItAgain() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/upload"))
        var requests = 0
        UploadURLProtocol.handler = { request in
            requests += 1
            if requests == 1 {
                XCTAssertNotNil(request.httpBody?.range(of: payload.data))
                return (200, Data(#"{"success":false,"stage":"finalization","finalizationId":"job-123"}"#.utf8))
            }
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertTrue((components.queryItems ?? []).contains(URLQueryItem(name: "finalizationId", value: "job-123")))
            XCTAssertNil(request.httpBody)
            return (200, Data(#"{"success":true,"result":["https://example.com/image.png"]}"#.utf8))
        }
        let result = try await MarkdownImageUploadService.uploadToPicList([payload], endpoint: endpoint, key: nil, session: session)
        XCTAssertEqual(result.map(\.absoluteString), ["https://example.com/image.png"])
        XCTAssertEqual(requests, 2)
        requests = 0
        UploadURLProtocol.handler = { _ in
            requests += 1
            return requests == 1
                ? (200, Data(#"{"success":false,"stage":"finalization","finalizationId":"job-456"}"#.utf8))
                : (500, Data())
        }
        do {
            _ = try await MarkdownImageUploadService.uploadToPicList([payload], endpoint: endpoint, key: nil, session: session)
            XCTFail("Expected finalization failure")
        } catch { XCTAssertEqual(error as? MarkdownImageUploadService.UploadError, .picListFinalization("job-456")) }
        XCTAssertEqual(requests, 2)
    }

    func testPicListCancellationKeepsAlreadyUploadedFinalizationID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        var cancelled = false, requests = 0
        UploadURLProtocol.handler = { _ in
            requests += 1
            cancelled = true
            return (200, Data(#"{"success":false,"stage":"finalization","finalizationId":"job-cancelled"}"#.utf8))
        }
        do {
            _ = try await MarkdownImageUploadService.uploadToPicList([payload], endpoint: URL(string: "https://example.com/upload")!, key: nil,
                session: session, isCancelled: { cancelled })
            XCTFail("Expected pending finalization")
        } catch { XCTAssertEqual(error as? MarkdownImageUploadService.UploadError, .picListFinalization("job-cancelled")) }
        XCTAssertEqual(requests, 1)
    }

    func testUPicUsesOneFilePerCommandAndPreservesPartialResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("first")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let executable = directory.appendingPathComponent("upic-fixture")
        let script = """
        #!/bin/sh
        [ "$1" = --output ] && [ "$2" = url ] && [ "$3" = --upload ] || exit 3
        case "$4" in /*literal%2520name.png) ;; *) exit 4 ;; esac
        if [ -e \(quoted) ]; then exit 1; fi
        touch \(quoted)
        printf 'https://example.com/first.png\\n'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let original = directory.appendingPathComponent("literal%20name.png")
        try png.write(to: original)
        let encoded = try XCTUnwrap(URLComponents(url: original, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        XCTAssertEqual(encoded.removingPercentEncoding, original.path)
        let payload = MarkdownImageUploadService.Payload(data: png, filename: original.lastPathComponent, mime: "image/png", localURL: original)
        do {
            _ = try await MarkdownImageUploadService.upload([payload, payload], method: "upic", endpoint: "", executable: executable.path,
                arguments: "", document: nil, isCancelled: { false })
            XCTFail("Expected partial upload")
        } catch let MarkdownImageUploadService.UploadError.uPicPartial(urls, _) {
            XCTAssertEqual(urls, ["https://example.com/first.png"])
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: original), png)
    }

    @MainActor
    func testIPicUsesSequentialCallbacksAndPreservesLateResult() async throws {
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        var callbacks: [(String?, NSError?) -> Void] = []
        let start: IPicImageUploadService.Start = { _, callback in callbacks.append(callback) }
        let first = Task { try await MarkdownImageUploadService.uploadToIPic([payload], start: start) }
        for _ in 0..<100 where callbacks.isEmpty { await Task.yield() }
        XCTAssertEqual(callbacks.count, 1)
        guard callbacks.count == 1 else { first.cancel(); return }
        let second = Task { try await MarkdownImageUploadService.uploadToIPic([payload], start: start) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks.count, 1)
        first.cancel()
        callbacks[0]("https://example.com/first.png", nil)
        do { _ = try await first.value; XCTFail("Expected partial result") }
        catch let MarkdownImageUploadService.UploadError.iPicPartial(urls, _) {
            XCTAssertEqual(urls, ["https://example.com/first.png"])
        } catch { XCTFail("Unexpected: \(error)") }
        for _ in 0..<100 where callbacks.count < 2 { await Task.yield() }
        XCTAssertEqual(callbacks.count, 2)
        guard callbacks.count == 2 else { second.cancel(); return }
        callbacks[1]("https://example.com/second.png", nil)
        let urls = try await second.value
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/second.png"])
    }

    @MainActor
    func testIPicKeepsFirstURLWhenSecondUploadFails() async throws {
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        var calls = 0
        let start: IPicImageUploadService.Start = { _, callback in
            calls += 1
            if calls == 1 { callback("https://example.com/first.png", nil) }
            else { callback(nil, NSError(domain: "test", code: 1)) }
        }
        do { _ = try await MarkdownImageUploadService.uploadToIPic([payload, payload], start: start); XCTFail("Expected partial result") }
        catch let MarkdownImageUploadService.UploadError.iPicPartial(urls, _) {
            XCTAssertEqual(urls, ["https://example.com/first.png"])
        } catch { XCTFail("Unexpected: \(error)") }
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testIPicRejectsInvalidCallbackAddresses() async throws {
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        for address in ["https://example.com/has space.png", "file://"] {
            do {
                _ = try await MarkdownImageUploadService.uploadToIPic([payload], start: { _, callback in callback(address, nil) })
                XCTFail("Expected invalid address")
            } catch { XCTAssertEqual(error as? MarkdownImageUploadService.UploadError, .invalidResult) }
        }
    }

    @MainActor
    func testIPicTimeoutDoesNotClaimUploadWasStopped() async throws {
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        do {
            _ = try await MarkdownImageUploadService.uploadToIPic([payload], start: { _, callback in callback(nil, iPicUploadError.TimeOut) })
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? MarkdownImageUploadService.UploadError, .iPicTimedOut)
            XCTAssertEqual(error.localizedDescription, L10n.tr("iPic 未返回结果；上传可能仍在进行。"))
        }
    }

    @MainActor
    func testIPicLateTimeoutRequiresNoticeAfterCancellation() async throws {
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        var callback: ((String?, NSError?) -> Void)?
        let task = Task {
            try await MarkdownImageUploadService.uploadToIPic([payload], start: { _, finish in callback = finish })
        }
        for _ in 0..<100 where callback == nil { await Task.yield() }
        guard let callback else { task.cancel(); return XCTFail("iPic request did not start") }
        task.cancel()
        callback(nil, iPicUploadError.TimeOut)
        do { _ = try await task.value; XCTFail("Expected timeout") }
        catch let error as MarkdownImageUploadService.UploadError {
            XCTAssertEqual(error, .iPicTimedOut)
            XCTAssertTrue(error.reportsUploadedResources)
        }
    }

    @MainActor
    func testIPicDoesNotStartCancelledQueuedUpload() async throws {
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        var callbacks: [(String?, NSError?) -> Void] = [], cancelled = false, secondStarted = false
        let start: IPicImageUploadService.Start = { _, callback in callbacks.append(callback) }
        let first = Task { try await MarkdownImageUploadService.uploadToIPic([payload], start: start) }
        for _ in 0..<100 where callbacks.isEmpty { await Task.yield() }
        XCTAssertEqual(callbacks.count, 1)
        guard callbacks.count == 1 else { first.cancel(); return }
        let second = Task { try await MarkdownImageUploadService.uploadToIPic([payload], start: start, isCancelled: { secondStarted = true; return cancelled }) }
        for _ in 0..<100 where !secondStarted { await Task.yield() }
        XCTAssertTrue(secondStarted)
        cancelled = true
        callbacks[0]("https://example.com/first.png", nil)
        _ = try await first.value
        do { _ = try await second.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(callbacks.count, 1)
    }

    func testPicseeUsesLiteralPathAndKeepsPartialResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("first")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let executable = directory.appendingPathComponent("picsee-fixture")
        let script = """
        #!/bin/sh
        [ "$1" = -u ] || exit 3
        case "$2" in /*literal%20name.png) ;; *) exit 4 ;; esac
        if [ -e \(quoted) ]; then printf 'Output URL:\\nInvalid path\\n'; exit 1; fi
        touch \(quoted)
        printf 'Output URL:\\nhttps://example.com/first.png\\n'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let original = directory.appendingPathComponent("literal%20name.png")
        try png.write(to: original)
        let payload = MarkdownImageUploadService.Payload(data: png, filename: original.lastPathComponent, mime: "image/png", localURL: original)
        do {
            _ = try await MarkdownImageUploadService.upload([payload, payload], method: "picsee", endpoint: "", executable: executable.path,
                arguments: "", document: nil, isCancelled: { false })
            XCTFail("Expected partial upload")
        } catch let MarkdownImageUploadService.UploadError.picseePartial(urls, _) {
            XCTAssertEqual(urls, ["https://example.com/first.png"])
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: original), png)
        try "#!/bin/sh\nprintf 'https://example.com/help\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await MarkdownImageUploadService.upload([payload], method: "picsee", endpoint: "", executable: executable.path,
                arguments: "", document: nil, isCancelled: { false })
            XCTFail("Expected missing result marker to fail")
        } catch { XCTAssertEqual(error as? MarkdownImageUploadService.UploadError, .invalidResult) }
        try "#!/bin/sh\nprintf 'Output URL:\\nhttps://example.com/finished.png\\n'\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await MarkdownImageUploadService.upload([payload], method: "picsee", endpoint: "", executable: executable.path,
                arguments: "", document: nil, isCancelled: { false })
            XCTFail("Expected partial result")
        } catch let MarkdownImageUploadService.UploadError.picseePartial(urls, _) {
            XCTAssertEqual(urls, ["https://example.com/finished.png"])
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUPicCancellationPreservesConfirmedFinalOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("printed")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let executable = directory.appendingPathComponent("upic-fixture")
        let script = """
        #!/bin/sh
        printf 'Output URL:\\nhttps://example.com/uploaded.png\\n'
        touch \(quoted)
        sleep 3
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        XCTAssertThrowsError(try MarkdownImageUploadService.uploadWithCommand([payload], executable: executable,
            arguments: ["--output", "url", "--upload"], document: nil,
            isCancelled: { FileManager.default.fileExists(atPath: marker.path) }, percentEncodedPaths: true)) { error in
            guard case let MarkdownImageUploadService.UploadError.uPicPartial(urls, _) = error else { return XCTFail("Unexpected: \(error)") }
            XCTAssertEqual(urls, ["https://example.com/uploaded.png"])
        }
    }

    func testPicseeCancellationPreservesConfirmedFinalOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("printed")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let executable = directory.appendingPathComponent("picsee-fixture")
        let script = "#!/bin/sh\nprintf 'Output URL:\\nhttps://example.com/uploaded.png\\n'\ntouch \(quoted)\nsleep 3\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "image.png", mime: "image/png")
        XCTAssertThrowsError(try MarkdownImageUploadService.uploadWithCommand([payload], executable: executable,
            arguments: ["-u"], document: nil, isCancelled: { FileManager.default.fileExists(atPath: marker.path) }, picsee: true)) { error in
            guard case let MarkdownImageUploadService.UploadError.picseePartial(urls, _) = error else { return XCTFail("Unexpected: \(error)") }
            XCTAssertEqual(urls, ["https://example.com/uploaded.png"])
        }
    }

    func testCancellingPicGoCancelsURLSessionRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedUploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); DelayedUploadURLProtocol.started = nil; DelayedUploadURLProtocol.stopped = nil }
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request stopped")
        DelayedUploadURLProtocol.started = { started.fulfill() }
        DelayedUploadURLProtocol.stopped = { stopped.fulfill() }
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "a.png", mime: "image/png")
        let task = Task { try await MarkdownImageUploadService.uploadToPicGo([payload], endpoint: URL(string: "https://example.com/upload")!, session: session) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
    }

    func testOnlineDownloadUsesActualImageBytes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UploadURLProtocol.handler = nil }
        let url = URL(string: "https://example.com/image.png")!
        let png = self.png
        UploadURLProtocol.handler = { request in
            XCTAssertEqual(request.url, url)
            return (200, png)
        }
        let payload = try await MarkdownImageUploadService.download(url, session: session)
        XCTAssertEqual(payload.data, png)
        XCTAssertEqual(payload.mime, "image/png")
        UploadURLProtocol.handler = { _ in (200, Data("not an image".utf8)) }
        do { _ = try await MarkdownImageUploadService.download(url, session: session); XCTFail("Expected image validation failure") }
        catch { XCTAssertEqual(error as? MarkdownImageUploadService.UploadError, .invalidInput) }
    }

    @MainActor
    func testRemotePasteboardPreservesTextPriority() {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        board.declareTypes([.URL], owner: nil)
        board.setString("https://example.com/image.png", forType: .URL)
        XCTAssertNil(view.imageTransfer(from: board))
        view.remoteImageTransferEnabled = true
        guard case let .remote(url)? = view.imageTransfer(from: board) else { return XCTFail("Expected URL transfer") }
        XCTAssertEqual(url.absoluteString, "https://example.com/image.png")
        board.addTypes([.string], owner: nil)
        board.setString("https://example.com/image.png", forType: .string)
        guard case .some(.remote(_)) = view.imageTransfer(from: board, preferText: false) else { return XCTFail("Expected URL drag") }
        XCTAssertNil(view.imageTransfer(from: board, preferText: true))
        board.setString("ordinary text", forType: .string)
        XCTAssertNil(view.imageTransfer(from: board, preferText: true))
        XCTAssertNil(view.imageTransfer(from: board, preferText: false))
    }

    func testInlineAddressesUseUTF16AndPreserveSource() throws {
        let source = "中文😀\r\n\r\n![alt](<images/a%20中.png> 'title') and ![b](path(a).png)\r\n\r\n`![no](code.png)`"
        let images = try MarkdownImageUploadService.images(in: source)
        XCTAssertEqual(images.map(\.rawAddress), ["images/a%20中.png", "path(a).png"])
        XCTAssertEqual(images.map { (source as NSString).substring(with: $0.addressRange) }, images.map(\.rawAddress))
        XCTAssertTrue((source as NSString).substring(with: images[0].range).hasSuffix(" 'title')"))
        let selected = try MarkdownImageUploadService.images(in: source, selection: NSRange(location: images[1].range.location, length: 0))
        XCTAssertEqual(selected, [images[1]])
    }

    func testHTMLImagesAndUnsupportedCasesAreNotSilentlySkipped() throws {
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src=\"local.png\">").first?.address, "local.png")
        XCTAssertNoThrow(try MarkdownImageUploadService.images(in: "```html\n<img src=\"local.png\">\n```"))
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<imginary>text</imginary>\n\n![x](a.png)").count, 1)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<IMG src='a.png'>").first?.address, "a.png")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<!-- <img src='x'> -->\n\n![x](a.png)").count, 1)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "---\ntitle: '![fake](a.png)'\n---\n\n$$\n![fake](b.png)\n$$\n\n![real](c.png)").map(\.address), ["c.png"])
    }

    func testReferenceImagesChangeOnlyUnsharedDefinition() throws {
        let source = "😀 ![one][ID] and ![two][]\r\n\r\n[id]: <a.png> 'title'\r\n[two]: b.png\r\n"
        let images = try MarkdownImageUploadService.images(in: source)
        XCTAssertEqual(images.map(\.address), ["a.png", "b.png"])
        let urls = [URL(string: "https://example.com/a.png")!, URL(string: "https://example.com/b.png")!]
        let edit = try MarkdownImageUploadService.replacement(in: source, images: images, urls: urls, selection: NSRange(location: 0, length: 0))
        let changed = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(changed, "😀 ![one][ID] and ![two][]\r\n\r\n[id]: <https://example.com/a.png> 'title'\r\n[two]: https://example.com/b.png\r\n")
        let shared = "![one][id] ![two][id]\n\n[id]: a.png"
        let sharedImages = try MarkdownImageUploadService.images(in: shared)
        XCTAssertEqual(sharedImages.count, 1)
        let second = (shared as NSString).range(of: "![two][id]")
        let selected = try MarkdownImageUploadService.images(in: shared, selection: second)
        let selectedEdit = try MarkdownImageUploadService.replacement(in: shared, images: selected,
            urls: [URL(string: "https://example.com/one.png")!], selection: second)
        XCTAssertEqual((shared as NSString).replacingCharacters(in: selectedEdit.range, with: selectedEdit.replacement),
                       "![one][id] ![two](<https://example.com/one.png>)\n\n[id]: a.png")
        let sharedEdit = try MarkdownImageUploadService.replacement(in: shared, images: sharedImages,
            urls: [URL(string: "https://example.com/shared.png")!], selection: NSRange(location: 0, length: 0))
        let sharedResult = (shared as NSString).replacingCharacters(in: sharedEdit.range, with: sharedEdit.replacement)
        XCTAssertEqual(sharedResult, "![one][id] ![two][id]\n\n[id]: https://example.com/shared.png")
        let sharedLink = "![one][id] [ordinary][id]\n\n[id]: a.png"
        let linkedImages = try MarkdownImageUploadService.images(in: sharedLink)
        let linkedEdit = try MarkdownImageUploadService.replacement(in: sharedLink, images: linkedImages,
            urls: [URL(string: "https://example.com/one.png")!], selection: NSRange(location: 0, length: 0))
        XCTAssertEqual((sharedLink as NSString).replacingCharacters(in: linkedEdit.range, with: linkedEdit.replacement),
                       "![one](<https://example.com/one.png>) [ordinary][id]\n\n[id]: a.png")
        XCTAssertThrowsError(try MarkdownImageUploadService.images(in: source, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        let before = "[id]: a.png\n\n![one][id] tail"
        let beforeImages = try MarkdownImageUploadService.images(in: before)
        let tail = (before as NSString).range(of: "tail")
        let beforeEdit = try MarkdownImageUploadService.replacement(in: before, images: beforeImages, urls: [urls[0]], selection: tail)
        let beforeResult = (before as NSString).replacingCharacters(in: beforeEdit.range, with: beforeEdit.replacement) as NSString
        XCTAssertEqual(beforeResult.substring(with: beforeEdit.selectionRange), "tail")
    }

    func testManyReferenceImagesResolveAndReplaceAsOneBatch() throws {
        let count = 100
        let body = (0..<count).map { "![image\($0)][id\($0)]" }.joined(separator: "\n")
        let definitions = (0..<count).map { "[id\($0)]: image\($0).png" }.joined(separator: "\n")
        let source = body + "\n\n" + definitions
        let images = try MarkdownImageUploadService.images(in: source)
        XCTAssertEqual(images.count, count)
        let urls = (0..<count).map { URL(string: "https://example.com/\($0).png")! }
        let edit = try MarkdownImageUploadService.replacement(in: source, images: images, urls: urls, selection: NSRange(location: 0, length: 0))
        let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertTrue(result.contains("[id0]: https://example.com/0.png"))
        XCTAssertTrue(result.contains("[id99]: https://example.com/99.png"))
    }

    func testSharedReferenceKeepsRawTitleAndOtherLinks() throws {
        for title in ["'a &amp; b'", "\"a \\\" b\"", "'a \\' b'"] {
            let source = "😀 ![one][id] ![two][id] [link][id]\r\n\r\n[id]: <a.png> " + title + "\r\n"
            let images = try MarkdownImageUploadService.images(in: source)
            XCTAssertEqual(images.count, 1)
            let url = URL(string: "https://example.com/new.png?x=1&copy=2")!
            let edit = try MarkdownImageUploadService.replacement(in: source, images: images, urls: [url], selection: NSRange(location: 0, length: 0))
            let changed = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            XCTAssertEqual(changed, "😀 ![one](<https://example.com/new.png?x=1&amp;copy=2> " + title + ") ![two](<https://example.com/new.png?x=1&amp;copy=2> " + title + ") [link][id]\r\n\r\n[id]: <a.png> " + title + "\r\n")
        }
        let mixed = "![a][one] ![b][two] ![c][one] [ordinary][one]\n\n[one]: a.png 'A'\n[two]: b.png\n"
        let images = try MarkdownImageUploadService.images(in: mixed)
        XCTAssertEqual(images.count, 2)
        let urls = [URL(string: "https://example.com/a.png")!, URL(string: "https://example.com/b.png")!]
        let edit = try MarkdownImageUploadService.replacement(in: mixed, images: images, urls: urls, selection: NSRange(location: 0, length: 0))
        let changed = (mixed as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(changed, "![a](<https://example.com/a.png> 'A') ![b][two] ![c](<https://example.com/a.png> 'A') [ordinary][one]\n\n[one]: a.png 'A'\n[two]: https://example.com/b.png\n")
        let nextLine = "![a][id] [link][id]\n\n[id]: a.png\n  'next &amp; title'\n"
        let nextImages = try MarkdownImageUploadService.images(in: nextLine)
        let nextEdit = try MarkdownImageUploadService.replacement(in: nextLine, images: nextImages,
            urls: [URL(string: "https://example.com/a.png")!], selection: NSRange(location: 0, length: 0))
        XCTAssertEqual((nextLine as NSString).replacingCharacters(in: nextEdit.range, with: nextEdit.replacement),
                       "![a](<https://example.com/a.png> 'next &amp; title') [link][id]\n\n[id]: a.png\n  'next &amp; title'\n")
        let multiline = "![a][id] [link][id]\n\n[id]: a.png 'first\nsecond'\n"
        let multilineImages = try MarkdownImageUploadService.images(in: multiline)
        let multilineEdit = try MarkdownImageUploadService.replacement(in: multiline, images: multilineImages,
            urls: [URL(string: "https://example.com/a.png")!], selection: NSRange(location: 0, length: 0))
        XCTAssertEqual((multiline as NSString).replacingCharacters(in: multilineEdit.range, with: multilineEdit.replacement),
                       "![a](<https://example.com/a.png> 'first\nsecond') [link][id]\n\n[id]: a.png 'first\nsecond'\n")
        let empty = "![a][id] [link][id]\n\n[id]: a.png\n  \"\"\n"
        let emptyImages = try MarkdownImageUploadService.images(in: empty)
        let emptyEdit = try MarkdownImageUploadService.replacement(in: empty, images: emptyImages,
            urls: [URL(string: "https://example.com/a.png")!], selection: NSRange(location: 0, length: 0))
        XCTAssertEqual((empty as NSString).replacingCharacters(in: emptyEdit.range, with: emptyEdit.replacement),
                       "![a](<https://example.com/a.png> \"\") [link][id]\n\n[id]: a.png\n  \"\"\n")
    }

    func testReferenceDefinitionsInQuotesListsAndEscapedLabels() throws {
        let samples = [
            "> ![x][a\\!b]\n>\n> [a\\!b]: image.png",
            "- ![x][id]\n\n  [id]: image.png",
            "![x][a&amp;b]\n\n[a&amp;b]: image.png",
            "![x][long\n label]\n\n[long\n label]:\n  image.png",
            "> ![x][long\n> label]\n>\n> [long\n> label]:\n> image.png"
        ]
        for source in samples {
            let images = try MarkdownImageUploadService.images(in: source)
            XCTAssertEqual(images.count, 1)
            XCTAssertEqual(images.first?.address, "image.png")
            let edit = try MarkdownImageUploadService.replacement(in: source, images: images,
                urls: [URL(string: "https://example.com/image.png")!], selection: NSRange(location: 0, length: 0))
            let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            XCTAssertTrue(result.contains("https://example.com/image.png"))
        }
    }

    func testHTMLImageAddressReplacementPreservesOtherAttributes() throws {
        let samples = [
            "😀 <img alt='x > y' src=\"images/a&amp;b.png\" title='keep'>",
            "😀 <IMG title='keep' src='images/a&amp;b.png'>",
            "😀 <img src=images/a&amp;b.png alt=test>"
        ]
        for source in samples {
            let image = try XCTUnwrap(MarkdownImageUploadService.images(in: source).first)
            XCTAssertEqual(image.address, "images/a&b.png")
            let url = try XCTUnwrap(URL(string: "https://example.com/a.png?x=1&y=2"))
            let edit = try MarkdownImageUploadService.replacement(in: source, images: [image], urls: [url], selection: NSRange(location: 0, length: 0))
            let changed = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            XCTAssertEqual(try MarkdownImageUploadService.images(in: changed).first?.address, url.absoluteString)
            XCTAssertTrue(changed.contains("&amp;"))
            if source.contains("title='keep'") { XCTAssertTrue(changed.contains("title='keep'")) }
        }
        XCTAssertThrowsError(try MarkdownImageUploadService.images(in: "<img src='a.png' src='b.png'>"))
        let block = "<div>\n<img src='a.png'>\n<img src=\"b.png\">\n</div>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: block).map(\.address), ["a.png", "b.png"])
        let script = "<div><script>const x = \"<img src='ignored.png'>\";</script><img src='shown.png'></div>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: script).map(\.address), ["shown.png"])
        let inlineScript = "prefix <script><img src='fake.png'> ![fake](also-fake.png)</script> <img src='real.png'>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: inlineScript).map(\.address), ["real.png"])
        let inlineStyle = "prefix <style><img src='fake.png'></style> <img src='real.png'>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: inlineStyle).map(\.address), ["real.png"])
        let emptyTemplate = "prefix <template>text</template> <img src='real.png'>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: emptyTemplate).map(\.address), ["real.png"])
        let template = "<template><template><img src='a.png'></template><img src='b.png'></template>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: template).map(\.address), ["a.png", "b.png"])
        let sourceReferences = "before <select> text <img src='in-select.png'> text </select> <template><img src='in-template.png'></template> <script><img src='in-script.png'></script> <img src='visible.png'>"
        XCTAssertEqual(try MarkdownImageUploadService.images(in: sourceReferences).map(\.address), ["in-select.png", "in-template.png", "visible.png"])
        let ambiguous = "<img src='a&copy.png'>"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try png.write(to: directory.appendingPathComponent("a&copy.png"))
        try png.write(to: directory.appendingPathComponent("a©.png"))
        let resolved = try XCTUnwrap(MarkdownImageUploadService.images(in: ambiguous).first)
        XCTAssertEqual(resolved.address, "a©.png")
        let payload = try MarkdownImageUploadService.payload(address: resolved.address, document: directory.appendingPathComponent("note.md"))
        XCTAssertEqual(payload.localURL?.lastPathComponent, "a©.png")
        XCTAssertEqual(ambiguous, "<img src='a&copy.png'>")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("a&copy.png")), png)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("a©.png")), png)
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src='https://example.com/a?x=1&y=2'>").first?.address,
                       "https://example.com/a?x=1&y=2")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src='a&#169.png'>").first?.address, "a©.png")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src='a&#128;.png'>").first?.address, "a€.png")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src='a&#x80.png'>").first?.address, "a€.png")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src='a&#0.png'>").first?.address, "a�.png")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src='a&copy=2.png'>").first?.address, "a&copy=2.png")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: "<img src='a&notit.png'>").first?.address, "a&notit.png")
    }

    func testUnresolvedHTMLRangeDoesNotRejectUnrelatedSelectedImage() throws {
        let source = "![ok](ok.png)\n\n<img src='other.png' title='a\tb'>"
        let selected = (source as NSString).range(of: "![ok](ok.png)")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: source, selection: selected).map(\.address), ["ok.png"])
        XCTAssertThrowsError(try MarkdownImageUploadService.images(in: source))
        let html = (source as NSString).range(of: "<img src='other.png' title='a\tb'>")
        XCTAssertThrowsError(try MarkdownImageUploadService.images(in: source, selection: html))
    }

    func testTableImageAfterEscapedPipeUsesOriginalUTF16Positions() throws {
        let source = "| header |\n| --- |\n| 😀 a\\|b ![x](p.png) |"
        let expected = (source as NSString).range(of: "![x](p.png)")
        let selected = try MarkdownImageUploadService.images(in: source, selection: NSRange(location: NSMaxRange(expected) - 1, length: 0))
        XCTAssertEqual(selected.first?.range, expected)
        XCTAssertEqual(selected.first?.rawAddress, "p.png")
        XCTAssertEqual(try MarkdownImageUploadService.images(in: source, selection: expected), selected)
    }

    func testReplacementChangesOnlyAddressesAndMapsSelection() throws {
        let source = "😀 ![a](first.png 'title') and ![b](<second.png>) tail"
        let images = try MarkdownImageUploadService.images(in: source)
        let selection = (source as NSString).range(of: "tail")
        let urls = [URL(string: "https://example.com/a(b).png")!, URL(string: "https://example.com/二.png")!]
        let edit = try MarkdownImageUploadService.replacement(in: source, images: images, urls: urls, selection: selection)
        XCTAssertThrowsError(try MarkdownImageUploadService.replacement(in: source, images: images, urls: urls,
            selection: NSRange(location: NSNotFound, length: 0)))
        let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        XCTAssertTrue((result as String).contains("![a](https://example.com/a%28b%29.png 'title')"))
        XCTAssertEqual(result.substring(with: edit.selectionRange), "tail")
    }

    func testLocalAndDataPayloadKeepBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = png
        try bytes.write(to: directory.appendingPathComponent("中 文.png"))
        let payload = try MarkdownImageUploadService.payload(address: "%E4%B8%AD%20%E6%96%87.png", document: directory.appendingPathComponent("doc.md"))
        XCTAssertEqual(payload.data, bytes)
        XCTAssertEqual(payload.mime, "image/png")
        let embedded = try MarkdownImageUploadService.payload(address: "data:image/png;base64,\(bytes.base64EncodedString())", document: nil)
        XCTAssertEqual(embedded.data, bytes)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        XCTAssertEqual(try MarkdownImageUploadService.payload(data: tiff).mime, "image/tiff")
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(address: "relative.png", document: nil))
        try Data("not an image".utf8).write(to: directory.appendingPathComponent("invalid.png"))
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(address: "invalid.png", document: directory.appendingPathComponent("doc.md")))
        try bytes.write(to: directory.appendingPathComponent("wrong.jpg"))
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(address: "wrong.jpg", document: directory.appendingPathComponent("doc.md")))
        XCTAssertEqual(try MarkdownImageUploadService.payload(address: directory.appendingPathComponent("中 文.png").path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!, document: nil).data, bytes)
        try bytes.write(to: directory.appendingPathComponent("a"))
        try bytes.write(to: directory.appendingPathComponent("a#b.png"))
        XCTAssertThrowsError(try MarkdownImageUploadService.payload(address: "a#b.png", document: directory.appendingPathComponent("doc.md")))
        XCTAssertEqual(try MarkdownImageUploadService.payload(address: "a%23b.png", document: directory.appendingPathComponent("doc.md")).data, bytes)
        XCTAssertEqual(try MarkdownImageUploadService.payload(address: "%E4%B8%AD%20%E6%96%87.png?version=1", document: directory.appendingPathComponent("doc.md")).data, bytes)
    }

    func testYAMLReadsDocumentImagePolicyLiterally() throws {
        let cases: [(String, MarkdownImageUploadService.DocumentPolicy)] = [
            ("---\ntypora-copy-images-to: upload\n---\n\ntext", .upload),
            ("---\ntypora-copy-images-to: 'upload'\n---\n", .upload),
            ("---\ntypora-copy-images-to: |-\n  upload\n---\n", .upload),
            ("---\ntitle: 中文😀\n---\n", .absent),
            ("---\ntypora-copy-images-to: '图片 folder'\n---\n", .other("图片 folder")),
            ("---\ntypora-copy-images-to: '**upload**'\n---\n", .other("**upload**")),
            ("---\ntypora-copy-images-to: 'assets/_private_ *images*'\n---\n", .other("assets/_private_ *images*")),
            ("no YAML", .absent)
        ]
        for (source, expected) in cases {
            XCTAssertEqual(try MarkdownImageUploadService.documentPolicy(in: source, isCancelled: { false }), expected)
        }
        XCTAssertThrowsError(try MarkdownImageUploadService.documentPolicy(in: "---\ntypora-copy-images-to: [upload, other]\n---\n", isCancelled: { false }))
        XCTAssertThrowsError(try MarkdownImageUploadService.documentPolicy(in: "---\ntypora-copy-images-to: [\n---\n", isCancelled: { false }))
    }

    func testDocumentPolicyCancellation() {
        XCTAssertThrowsError(try MarkdownImageUploadService.documentPolicy(in: "---\ntypora-copy-images-to: upload\n---\n", isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCommandReceivesLiteralArgumentsAndOrderedImagePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("args")
        let script = "printf '%s\\n' \"$@\" > \"$1\"; printf 'log\\nhttps://example.com/one.png\\nhttps://example.com/two.png\\n'"
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "中.png", mime: "image/png")
        let document = directory.appendingPathComponent("文 件.md")
        let original = directory.appendingPathComponent("原图.png")
        try png.write(to: original)
        let local = try MarkdownImageUploadService.payload(address: original.absoluteString, document: document)
        let result = try MarkdownImageUploadService.uploadWithCommand([local, payload], executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "upload", output.path, "${filename}", "${filepath}"], document: document, isCancelled: { false })
        XCTAssertEqual(result.map(\.absoluteString), ["https://example.com/one.png", "https://example.com/two.png"])
        let args = try String(contentsOf: output, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(args[1], "文 件.md")
        XCTAssertEqual(args[2], document.path)
        XCTAssertEqual(args[3], original.path)
        XCTAssertTrue(args[4].hasSuffix("/1.png"))
        XCTAssertEqual(try Data(contentsOf: original), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: args[4]))
    }

    func testCommandCancellationCleansTemporaryImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let late = directory.appendingPathComponent("late")
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "test.png", mime: "image/png")
        let task = Task.detached {
            try MarkdownImageUploadService.uploadWithCommand([payload], executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' \"$3\" > \"$1\"; /bin/sh -c 'sleep 1; touch \"$1\"' nested \"$2\" & wait", "upload", marker.path, late.path],
                document: nil, isCancelled: { Task.isCancelled })
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let path = try String(contentsOf: marker, encoding: .utf8)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    func testCommandRejectsFailureAndPartialOutput() {
        let payload = MarkdownImageUploadService.Payload(data: png, filename: "a.png", mime: "image/png")
        XCTAssertThrowsError(try MarkdownImageUploadService.uploadWithCommand([payload], executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 1"], document: nil, isCancelled: { false }))
        XCTAssertThrowsError(try MarkdownImageUploadService.uploadWithCommand([payload, payload], executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'https://example.com/only\\n'"], document: nil, isCancelled: { false }))
    }

    @MainActor
    func testManualUploadUsesEditorAndUndo() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try png.write(to: directory.appendingPathComponent("a.png"))
        let suite = "MarkdownImageUploadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "command", endpoint: "", executable: "/bin/sh",
            arguments: "-c\nprintf 'https://example.com/new.png\\n'\nupload")
        let source = "![alt](a.png 'title')\n\n![second](a.png)"
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.uploadMarkdownImages(selectedOnly: true)
        for _ in 0..<150 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, "![alt](https://example.com/new.png 'title')\n\n![second](a.png)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        let picsee = directory.appendingPathComponent("picsee-fixture")
        try "#!/bin/sh\n[ \"$1\" = -u ] || exit 1\nprintf 'Output URL:\\nhttps://example.com/picsee.png\\n'\n".write(to: picsee, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: picsee.path)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "picsee", executable: picsee.path)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.uploadMarkdownImages(selectedOnly: true)
        for _ in 0..<150 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, "![alt](https://example.com/picsee.png 'title')\n\n![second](a.png)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "command", executable: "/bin/sh")
        preferences.markdownImageUploadConfiguration.arguments = "-c\nprintf 'https://example.com/one.png\\nhttps://example.com/two.png\\n'\nupload"
        state.uploadMarkdownImages(selectedOnly: false)
        for _ in 0..<150 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, "![alt](https://example.com/one.png 'title')\n\n![second](https://example.com/two.png)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        preferences.markdownImageUploadConfiguration.arguments = "-c\nsleep 0.2; printf 'https://example.com/late.png\\n'\nupload"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.uploadMarkdownImages(selectedOnly: true)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(document.statusMessage, L10n.tr("文档已变化，未应用上传结果"))
        view.isEditable = false
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.uploadMarkdownImages(selectedOnly: true)
        XCTAssertEqual(document.statusMessage, L10n.tr("文档已变化，未应用上传结果"))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(document.statusMessage, L10n.tr("文档已变化，未应用上传结果"))
        view.isEditable = true
        let editedStart = directory.appendingPathComponent("edit-started")
        let editedLate = directory.appendingPathComponent("edit-late")
        preferences.markdownImageUploadConfiguration.arguments = "-c\ntouch \"$1\"; sleep 1; touch \"$2\"; printf 'https://example.com/late.png\\n'\nupload\n\(editedStart.path)\n\(editedLate.path)"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.uploadMarkdownImages(selectedOnly: true)
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: editedStart.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: editedStart.path))
        let end = NSRange(location: (source as NSString).length, length: 0)
        XCTAssertTrue(view.shouldChangeText(in: end, replacementString: "x"))
        view.textStorage?.replaceCharacters(in: end, with: "x")
        view.didChangeText()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: editedLate.path))
        XCTAssertEqual(view.string, source + "x")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        let started = directory.appendingPathComponent("started")
        let late = directory.appendingPathComponent("late")
        preferences.markdownImageUploadConfiguration.arguments = "-c\ntouch \"$1\"; sleep 1; touch \"$2\"; printf 'https://example.com/late.png\\n'\nupload\n\(started.path)\n\(late.path)"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        state.uploadMarkdownImages(selectedOnly: true)
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertNotNil(state.takeDocumentForTransfer(document))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
        XCTAssertEqual(view.string, source)
    }

    @MainActor
    func testUploadRefusesUnfinishedInputInRealTableCell() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try png.write(to: directory.appendingPathComponent("a.png"))
        let marker = directory.appendingPathComponent("ran")
        let suite = "MarkdownImageUploadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "command", endpoint: "", executable: "/bin/sh",
            arguments: "-c\ntouch \"$1\"; printf 'https://example.com/a.png\\n'\nupload\n\(marker.path)")
        let source = "| A |\n| --- |\n| ![x](a.png) |"
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
        document.isMarkdownFormatted = true
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        let marked = child.string
        let status = document.statusMessage
        state.uploadMarkdownImages(selectedOnly: false)
        XCTAssertEqual(document.statusMessage, status)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(child.string, marked)
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testAutomaticUploadOfPastedDataUsesExistingInsertionAndUndo() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MarkdownImageUploadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "command", executable: "/bin/sh",
            arguments: "-c\nprintf 'https://example.com/upload.png\\n'\nupload", automaticLocal: true)
        let document = EditorDocument(text: "before", url: directory.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: "before"), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        var confirmed = false, finished = false
        defer { finished = true; if NSApp.modalWindow != nil { NSApp.abortModal() } }
        func confirm(_ remaining: Int) {
            guard !finished else { return }
            if NSApp.modalWindow != nil { confirmed = true; NSApp.stopModal(withCode: .alertFirstButtonReturn); return }
            if remaining > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { confirm(remaining - 1) } }
            else { document.text = "dialog timed out" }
        }
        confirm(250)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .data(png)))
        for _ in 0..<200 where view.string == "before" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(view.string, "before![](<https://example.com/upload.png>)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "before")
        preferences.markdownImageUploadConfiguration.automaticLocal = false
        preferences.markdownImageUploadConfiguration.automaticOnline = false
        preferences.markdownImageUploadConfiguration.copyFolder = directory.appendingPathComponent("assets").path
        confirmed = false
        view.setSelectedRange(NSRange(location: 6, length: 0))
        confirm(250)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .data(png)))
        for _ in 0..<200 where view.string == "before" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(view.string, "before![](<assets/image.png>)")
        let copied = directory.appendingPathComponent("assets/image.png")
        XCTAssertEqual(try Data(contentsOf: copied), png)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "before")
        XCTAssertEqual(try Data(contentsOf: copied), png)
        let staleFolder = directory.appendingPathComponent("stale-assets")
        preferences.markdownImageUploadConfiguration.copyFolder = staleFolder.path
        let copyFinished = expectation(description: "copy finished before document changes")
        let releaseCopy = DispatchSemaphore(value: 0)
        defer { releaseCopy.signal() }
        confirmed = false
        view.setSelectedRange(NSRange(location: 6, length: 0))
        confirm(250)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .data(png), copyImage: { payload, folder, name, cancelled in
            let result = try MarkdownImageCopyService.copy(payload, to: folder, name: name, isCancelled: cancelled)
            copyFinished.fulfill()
            releaseCopy.wait()
            return result
        }))
        await fulfillment(of: [copyFinished], timeout: 5)
        let end = NSRange(location: 6, length: 0)
        XCTAssertTrue(view.shouldChangeText(in: end, replacementString: "x"))
        view.textStorage?.replaceCharacters(in: end, with: "x")
        view.didChangeText()
        releaseCopy.signal()
        let staleFile = staleFolder.appendingPathComponent("image.png")
        for _ in 0..<150 where !(document.statusMessage ?? "").contains(staleFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, "beforex")
        XCTAssertEqual(try Data(contentsOf: staleFile), png)
        XCTAssertTrue((document.statusMessage ?? "").contains(staleFile.path))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "before")
        preferences.markdownImageUploadConfiguration.copyFolder = ""
        preferences.markdownImageUploadConfiguration.automaticLocal = true
        preferences.markdownImageUploadConfiguration.arguments = "-c\nprintf 'failed' >&2; exit 1\nupload"
        confirmed = false
        view.setSelectedRange(NSRange(location: 6, length: 0))
        confirm(250)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .data(png)))
        for _ in 0..<200 where !(document.statusMessage ?? "").contains("failed") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(confirmed)
        XCTAssertTrue((document.statusMessage ?? "").contains("failed"))
        XCTAssertEqual(view.string, "before")
        let file = directory.appendingPathComponent("local.png")
        try png.write(to: file)
        preferences.markdownImageUploadConfiguration.arguments = "-c\nprintf 'https://example.com/upload.png\\n'\nupload"
        confirmed = false
        view.setSelectedRange(NSRange(location: 6, length: 0))
        confirm(250)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .file(file)))
        for _ in 0..<200 where view.string == "before" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(view.string, "before![](<https://example.com/upload.png>)")
        XCTAssertEqual(try Data(contentsOf: file), png)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "before")
        let started = directory.appendingPathComponent("auto-started")
        preferences.markdownImageUploadConfiguration.arguments = "-c\ntouch \"$1\"; sleep 0.3; printf 'https://example.com/late.png\\n'\nupload\n\(started.path)"
        confirmed = false
        view.setSelectedRange(NSRange(location: 6, length: 0))
        confirm(250)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .data(png)))
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<100 where document.statusMessage != L10n.tr("文档已变化，未应用上传结果") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(document.statusMessage, L10n.tr("文档已变化，未应用上传结果"))
        XCTAssertEqual(view.string, "before")
        preferences.markdownImageUploadConfiguration.arguments = "-c\nprintf 'https://example.com/upload.png\\n'\nupload"
        preferences.markdownImageUploadConfiguration.automaticOnline = true
        let remotePNG = png
        UploadURLProtocol.handler = { _ in (200, remotePNG) }
        URLProtocol.registerClass(UploadURLProtocol.self)
        defer { URLProtocol.unregisterClass(UploadURLProtocol.self); UploadURLProtocol.handler = nil }
        confirmed = false
        view.setSelectedRange(NSRange(location: 6, length: 0))
        confirm(250)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .remote(URL(string: "https://example.com/source.png")!)))
        for _ in 0..<200 where view.string == "before" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(view.string, "before![](<https://example.com/upload.png>)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "before")
    }

    @MainActor
    func testSlowImageReadDoesNotRetainClosedWindowState() async throws {
        _ = NSApplication.shared
        let manager = WindowManager()
        let primary = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let primaryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        primaryWindow.isReleasedWhenClosed = false
        let primaryID = UUID()
        manager.register(windowID: primaryID, state: primary, window: primaryWindow)
        let document = EditorDocument(text: "before", language: .markdown)
        var state: AppState? = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        weak var weakState = state
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: "before"), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: try XCTUnwrap(state), window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        manager.activate(windowID: id)
        defer { coordinator.updateActivity(false); window.close(); primaryWindow.close() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let started = expectation(description: "image read started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        XCTAssertTrue(try XCTUnwrap(state).presentMarkdownImage(transfer: .data(png), identify: { _ in
            started.fulfill()
            release.wait()
            return nil
        }))
        await fulfillment(of: [started], timeout: 5)
        manager.unregister(windowID: id)
        state = nil
        XCTAssertNil(weakState)
    }

    @MainActor
    func testDocumentYAMLCanEnableAutomaticUpload() async throws {
        _ = NSApplication.shared
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "MarkdownImageUploadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "command", executable: "/bin/sh",
            arguments: "-c\nprintf 'https://example.com/yaml.png\\n'\nupload", allowDocumentPolicy: true)
        let source = "---\ntypora-copy-images-to: upload\n---\n\nbefore"
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var confirmed = false, finished = false
        defer { finished = true; if NSApp.modalWindow != nil { NSApp.abortModal() } }
        func confirm(_ remaining: Int) {
            guard !finished else { return }
            if NSApp.modalWindow != nil { confirmed = true; NSApp.stopModal(withCode: .alertFirstButtonReturn); return }
            if remaining > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { confirm(remaining - 1) } }
            else { document.text = "dialog timed out" }
        }
        confirm(400)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .data(png)))
        for _ in 0..<350 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(view.string, source + "![](<https://example.com/yaml.png>)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        let copySource = "---\ntypora-copy-images-to: ./assets\n---\n\nbefore"
        let full = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertTrue(view.shouldChangeText(in: full, replacementString: copySource))
        view.textStorage?.replaceCharacters(in: full, with: copySource)
        view.didChangeText()
        preferences.markdownImageUploadConfiguration.allowDocumentPolicy = false
        preferences.markdownImageUploadConfiguration.allowDocumentCopy = true
        preferences.markdownImageUploadConfiguration.automaticLocal = true
        view.setSelectedRange(NSRange(location: (copySource as NSString).length, length: 0))
        confirmed = false
        confirm(400)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .data(png)))
        for _ in 0..<350 where view.string == copySource { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(view.string, copySource + "![](<assets/image.png>)")
        let copied = directory.appendingPathComponent("assets/image.png")
        XCTAssertEqual(try Data(contentsOf: copied), png)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, copySource)
        XCTAssertEqual(try Data(contentsOf: copied), png)
    }

    @MainActor
    func testSharedReferenceUploadUsesOneEditorUndo() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try png.write(to: directory.appendingPathComponent("a.png"))
        let suite = "MarkdownImageUploadTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownImageUploadConfiguration = MarkdownImageUploadConfiguration(method: "command", executable: "/bin/sh",
            arguments: "-c\nprintf 'https://example.com/new.png\\n'\nupload")
        let source = "![a][id] ![b][id] [link][id]\n\n[id]: a.png 'title'"
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        state.uploadMarkdownImages(selectedOnly: false)
        for _ in 0..<200 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.string, "![a](<https://example.com/new.png> 'title') ![b](<https://example.com/new.png> 'title') [link][id]\n\n[id]: a.png 'title'")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }
}
