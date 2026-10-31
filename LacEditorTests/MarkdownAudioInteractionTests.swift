import AppKit
import AVKit
import WebKit
import XCTest
@testable import LacEditor

private final class MarkdownImageURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

}

private final class MarkdownSVGURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><rect width='10' height='10' fill='red'/></svg>".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DelayedMarkdownImageURLProtocol: URLProtocol {
    static var started: (() -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started?() }
    override func stopLoading() { Self.stopped?() }
}

@MainActor
final class MarkdownAudioInteractionTests: XCTestCase {
    func testTwitterWidgetUsesExistingIframeAndRevealsSource() async throws {
        _ = NSApplication.shared
        let markup = "<blockquote class='twitter-tweet'><p>Sunsets 中文</p><a href='https://x.com/Interior/status/463440424141459456'>Post</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>"
        let source = markup + "\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange(raw.range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = try XCTUnwrap(MarkdownPresentationParser.parse(source).iframeBlocks.first?.range)
        for _ in 0..<100 where view.subviews.compactMap({ $0 as? WKWebView }).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let web = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30)); view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        view.setSelectedRange(range); controller.selectionChanged()
        XCTAssertTrue(web.superview === view)
        child.unmarkText(); child.removeFromSuperview()
        controller.compositionFinished(revision: 0); controller.selectionChanged()
        XCTAssertNil(web.superview)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testStandaloneSelfClosingMediaRequiresConfirmedWholeBlock() {
        for newline in ["\n", "\r\n"] {
            for tag in ["<audio src='https://example.invalid/a/b.wav' />", "<video src='clip.mp4' width='120' height='80' />"] {
                for prefix in ["", "> ", "- "] {
                    let source = "😀" + newline + newline + prefix + tag + newline + newline + "after"
                    let raw = source as NSString
                    let parsed = MarkdownPresentationParser.parse(source)
                    XCTAssertEqual(parsed.audioBlocks.count, 1, source)
                    if let media = parsed.audioBlocks.first {
                        XCTAssertEqual(raw.substring(with: media.range), tag)
                        XCTAssertFalse(media.isInline)
                    }
                }
            }
        }
        for source in ["<audio src='x.wav' onclick='evil()' />", "<audio src='x.wav' src='y.wav' />", "<script><audio src='x.wav' /></script>",
                       "before <audio src='x.wav' /> after", "<audio src='x.wav'>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).audioBlocks.isEmpty, source)
        }
        for source in ["<audio src='x.wav'>fallback<br/>", "<video src='x.mp4'><source src='y.mp4'/>"] {
            XCTAssertEqual(MarkdownPresentationParser.parse(source).audioBlocks.count, 1, source)
        }
    }

    func testStandaloneSelfClosingAudioPlaysAndRevealsSource() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var sound = Data("RIFF".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        func half(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        word(24036); sound.append(Data("WAVEfmt ".utf8)); word(16)
        half(1); half(1); word(8000); word(8000); half(1); half(8)
        sound.append(Data("data".utf8)); word(24000); sound.append(Data(repeating: 128, count: 24000))
        try sound.write(to: folder.appendingPathComponent("sound.wav"))
        let tag = "<audio src='sound.wav' />"
        let source = "before 😀\r\n\r\n" + tag + "\r\n\r\nafter"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("note.md"), language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 600)); layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        view.setSelectedRange((source as NSString).range(of: "after"))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<100 where view.subviews.compactMap({ $0 as? AVPlayerView }).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let playerView = try XCTUnwrap(view.subviews.compactMap { $0 as? AVPlayerView }.first)
        let player = try XCTUnwrap(playerView.player)
        player.play()
        for _ in 0..<100 where player.rate == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(player.rate, 0)
        view.setSelectedRange((source as NSString).range(of: tag)); controller.selectionChanged()
        XCTAssertNil(playerView.superview)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testInlineAudioKeepsTextAndStopsOnRevealAndResize() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var sound = Data("RIFF".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        func half(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        word(24036); sound.append(Data("WAVEfmt ".utf8)); word(16)
        half(1); half(1); word(8000); word(8000); half(1); half(8)
        sound.append(Data("data".utf8)); word(24000); sound.append(Data(repeating: 128, count: 24000))
        try sound.write(to: folder.appendingPathComponent("sound.wav"))
        let source = "before <audio controls src='sound.wav'>fallback</audio> after\n\nend"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("document.md"), language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).audioBlocks.first)
        XCTAssertTrue(block.isInline)
        for _ in 0..<100 {
            if !view.subviews.compactMap({ $0 as? AVPlayerView }).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let player = try XCTUnwrap(view.subviews.compactMap { $0 as? AVPlayerView }.first)
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [block.range], in: container)[block.range])
        XCTAssertEqual(player.frame.origin.x, rect.minX + view.textContainerOrigin.x, accuracy: 1)
        XCTAssertEqual(player.frame.origin.y, rect.minY + view.textContainerOrigin.y, accuracy: 1)
        for word in ["before", "after"] {
            let range = (source as NSString).range(of: word)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let textRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            XCTAssertFalse(textRect.intersects(rect), word)
        }
        let avPlayer = try XCTUnwrap(player.player)
        avPlayer.play()
        for _ in 0..<100 {
            if avPlayer.rate > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(avPlayer.rate, 0)
        view.setSelectedRange(block.range); controller.selectionChanged()
        XCTAssertNil(player.superview)
        XCTAssertEqual(avPlayer.rate, 0)
        view.setSelectedRange((source as NSString).range(of: "end")); controller.selectionChanged()
        for _ in 0..<100 {
            if !view.subviews.compactMap({ $0 as? AVPlayerView }).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(view.subviews.compactMap { $0 as? AVPlayerView }.first)
        scroll.setFrameSize(NSSize(width: 300, height: 600)); view.setFrameSize(NSSize(width: 300, height: 600))
        container.containerSize = NSSize(width: 300, height: 600); controller.viewportChanged()
        layout.ensureLayout(for: container)
        let resized = try XCTUnwrap(layout.markdownRenderedImageRects(for: [block.range], in: container)[block.range])
        XCTAssertLessThan(resized.width, rect.width)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testInlineIframeKeepsTextThroughRevealVerticalAndZoom() async throws {
        _ = NSApplication.shared
        let source = "before <iframe src='https://example.invalid' width='50%' height='60'>fallback</iframe> after\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.allowsMagnification = true
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).iframeBlocks.first)
        XCTAssertTrue(block.isInline)
        for _ in 0..<100 {
            if !view.subviews.compactMap({ $0 as? WKWebView }).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let frame = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [block.range], in: container)[block.range])
        for word in ["before", "after"] {
            let range = (source as NSString).range(of: word)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            XCTAssertFalse(layout.boundingRect(forGlyphRange: glyphs, in: container).intersects(rect), word)
        }
        XCTAssertEqual(frame.frame.origin.x, rect.minX + view.textContainerOrigin.x, accuracy: 1)
        XCTAssertEqual(frame.frame.origin.y, rect.minY + view.textContainerOrigin.y, accuracy: 1)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        view.setSelectedRange(block.range); controller.selectionChanged()
        XCTAssertTrue(frame.superview === view)
        child.unmarkText(); child.removeFromSuperview()
        controller.compositionFinished(revision: 0); controller.selectionChanged()
        XCTAssertNil(frame.superview)
        view.setSelectedRange((source as NSString).range(of: "end")); controller.selectionChanged()
        for _ in 0..<100 {
            if !view.subviews.compactMap({ $0 as? WKWebView }).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        view.setLayoutOrientation(.vertical)
        scroll.magnification = 1.5
        controller.viewportChanged()
        layout.ensureLayout(for: container)
        let vertical = try XCTUnwrap(layout.markdownRenderedImageRects(for: [block.range], in: container)[block.range])
        let current = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        let expected = scroll.contentView.convert(vertical.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        let actual = scroll.contentView.convert(current.bounds, from: current)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testLinkedIframeDefersRevealDuringMarkedTextAndKeepsGeometry() async throws {
        _ = NSApplication.shared
        let source = "[before <iframe src='https://example.invalid' width='50%' height='60'>fallback</iframe> after](https://example.invalid/page)\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.allowsMagnification = true; scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end"))
        let revision: UInt = 0
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).iframeBlocks.first)
        for _ in 0..<100 where view.subviews.compactMap({ $0 as? WKWebView }).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        let frame = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        view.setSelectedRange(block.range); controller.selectionChanged()
        XCTAssertTrue(frame.superview === view)
        child.unmarkText(); child.removeFromSuperview()
        controller.compositionFinished(revision: revision); controller.selectionChanged()
        XCTAssertNil(frame.superview)
        view.setSelectedRange((source as NSString).range(of: "end")); controller.selectionChanged()
        for _ in 0..<100 where view.subviews.compactMap({ $0 as? WKWebView }).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        view.setLayoutOrientation(.vertical); scroll.magnification = 1.5; controller.viewportChanged()
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [block.range], in: container)[block.range])
        let current = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        let expected = scroll.contentView.convert(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        let actual = scroll.contentView.convert(current.bounds, from: current)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }

    func testMissingInlineAudioLeavesSourceVisible() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "before <audio src='missing.wav'></audio> after\n\nend"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("document.md"), language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        let completed = expectation(description: "missing media checked")
        controller.audioLoadDidComplete = { _, loaded in XCTAssertFalse(loaded); completed.fulfill() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertTrue(view.subviews.compactMap { $0 as? AVPlayerView }.isEmpty)
        XCTAssertTrue(layout.markdownRenderedImageRects(for: [(source as NSString).range(of: "<audio src='missing.wav'></audio>")], in: container).isEmpty)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }

    func testCancelledInlineAudioDoesNotInstallLatePlayer() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "[before <audio src='sound.wav'></audio> after](https://example.invalid/page)\n\nend"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("document.md"), language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        let started = expectation(description: "inline media check started")
        let finished = expectation(description: "cancelled media check finished")
        var pending: CheckedContinuation<Bool, Never>?
        defer { pending?.resume(returning: false) }
        controller.audioAssetIsPlayable = { _ in
            await withCheckedContinuation { continuation in pending = continuation; started.fulfill() }
        }
        controller.audioJobDidFinish = { _ in finished.fulfill() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [started], timeout: 10)
        let range = (source as NSString).range(of: "<audio src='sound.wav'></audio>")
        view.setSelectedRange(range); controller.selectionChanged()
        let continuation = try XCTUnwrap(pending)
        pending = nil
        continuation.resume(returning: true)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertTrue(view.subviews.compactMap { $0 as? AVPlayerView }.isEmpty)
        XCTAssertTrue(layout.markdownRenderedImageRects(for: [range], in: container).isEmpty)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }
    func testStaleLinkedAudioDoesNotInstallLatePlayer() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "[before <audio src='sound.wav'></audio> after](https://example.invalid/page)\n\nend"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("document.md"), language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 400)); layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        let started = expectation(description: "linked media check started")
        let finished = expectation(description: "stale linked media check finished")
        var pending: CheckedContinuation<Bool, Never>?
        defer { pending?.resume(returning: false) }
        controller.audioAssetIsPlayable = { _ in await withCheckedContinuation { pending = $0; started.fulfill() } }
        controller.audioJobDidFinish = { _ in finished.fulfill() }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        await fulfillment(of: [started], timeout: 10)
        revision += 1
        let continuation = try XCTUnwrap(pending); pending = nil; continuation.resume(returning: true)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertTrue(view.subviews.compactMap { $0 as? AVPlayerView }.isEmpty)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }

    func testLocalAndRemoteSVGUseImageContextWithoutEditingSource() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><rect width='10' height='10' fill='red'/></svg>"
            .write(to: directory.appendingPathComponent("local.svg"), atomically: true, encoding: .utf8)
        let source = "before ![local](local.svg) after ![remote](https://8.8.8.8/image.svg)\n\nend"
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("note.md"), language: .markdown)
        document.allowsRemoteImages = true
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MarkdownSVGURLProtocol.self]
        let session = URLSession(configuration: configuration)
        controller.imageSession = session
        defer { controller.cancel(); session.invalidateAndCancel(); withExtendedLifetime(scroll) {} }
        let images = MarkdownPresentationParser.parse(source).images
        XCTAssertEqual(images.count, 2)
        let local = expectation(description: "local SVG"), remote = expectation(description: "remote SVG")
        controller.imageLoadDidComplete = { range, success in
            guard success else { return }
            if range == images.first?.range { local.fulfill() }
            if range == images.last?.range { remote.fulfill() }
        }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [local, remote], timeout: 15)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }
    func testAnimatedGIFUsesTwoFramesAndStopsShowingDuringSourceReveal() async throws {
        _ = NSApplication.shared
        let gif = "R0lGODlhBAAEAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAAEAAAICQABCBxIsCCAgAAh+QQBCgABACwAAAAABAAEAIEAAP8AAAAAAAAAAAAICQABCBxIsCCAgAA7"
        let uri = "data:image/gif;base64," + gif
        let source = "before\n\n![block](\(uri))\n\ninline ![inline](\(uri))\n\n| A | B |\n|---|---|\n| x | ![table](\(uri)) |\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func imageViews() -> [NSImageView] { view.subviews.compactMap { $0 as? NSImageView } }
        for _ in 0..<200 where imageViews().count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(imageViews().count, 3)
        let animated = try XCTUnwrap(imageViews().first)
        XCTAssertTrue(animated.animates)
        func pixel() -> NSColor? {
            guard let bitmap = animated.bitmapImageRepForCachingDisplay(in: animated.bounds) else { return nil }
            animated.cacheDisplay(in: animated.bounds, to: bitmap)
            return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        }
        let first = try XCTUnwrap(pixel())
        var changed = false
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            if let next = pixel(), abs(next.redComponent - first.redComponent) > 0.5 && abs(next.blueComponent - first.blueComponent) > 0.5 { changed = true; break }
        }
        XCTAssertTrue(changed)
        let priorViews = imageViews()
        view.setSelectedRange((source as NSString).range(of: "![block]"))
        controller.selectionChanged()
        XCTAssertLessThan(imageViews().count, 3)
        let blockView = try XCTUnwrap(priorViews.first { $0.superview == nil && !$0.animates })
        view.setSelectedRange((source as NSString).range(of: "end"))
        controller.selectionChanged()
        for _ in 0..<200 where imageViews().count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(imageViews().count, 3)
        XCTAssertTrue(imageViews().allSatisfy(\.animates))
        let imageRange = (source as NSString).range(of: "![block](\(uri))")
        layout.setFoldedRange(imageRange)
        controller.foldGeometryChanged()
        XCTAssertNil(blockView.superview)
        XCTAssertFalse(blockView.animates)
        layout.setFoldedRange(nil)
        controller.foldGeometryChanged()
        XCTAssertNotNil(blockView.superview)
        XCTAssertTrue(blockView.animates)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }
    func testTableImageUsesCellAttachmentWithoutChangingSource() async throws {
        _ = NSApplication.shared
        let uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let source = "before\n\n| 中文 | Picture |\n|---|---|\n| 😀 | ![a\\|b](\(uri)) |\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        let presentation = MarkdownPresentationParser.parse(source)
        let cell = try XCTUnwrap(presentation.tables.first?.rows.last?.cells.last)
        let image = try XCTUnwrap(presentation.images.first)
        let installed = expectation(description: "table image installed")
        controller.imageLoadDidComplete = { range, success in if range == image.range && success { installed.fulfill() } }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [installed], timeout: 4)
        let value = layout.tableCellAttributedText(cell, text: storage.mutableString)
        var found = false
        value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, _ in
            if attachment is NSTextAttachment { found = true }
        }
        XCTAssertTrue(found)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }
    func testInlineAndListImagesKeepSourceAndReserveGlyphs() async throws {
        _ = NSApplication.shared
        let uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let source = "before 😀 ![one](\(uri)) and ![two](\(uri))\n\n- [ ] ![task](\(uri))\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "![one]"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        let images = MarkdownPresentationParser.parse(source).images
        XCTAssertEqual(images.count, 3)
        guard images.count == 3 else { return }
        let rejected = expectation(description: "revealed image is not installed")
        controller.imageLoadDidComplete = { range, installed in
            if range == images[0].range && !installed { rejected.fulfill() }
        }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func imageIsVisible(_ range: NSRange) -> Bool {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layout.location(forGlyphAt: glyph)
            return layout.markdownImageLocation(at: NSPoint(x: line.minX + location.x + 0.5, y: line.minY + location.y - 0.5), in: container) == range.location
        }
        await fulfillment(of: [rejected], timeout: 4)
        XCTAssertFalse(imageIsVisible(images[0].range))
        view.setSelectedRange((source as NSString).range(of: "end"))
        controller.selectionChanged()
        for _ in 0..<200 where !images.allSatisfy({ imageIsVisible($0.range) }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(images.allSatisfy { imageIsVisible($0.range) })
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }
    func testRemoteImageRequestIsCancelledWhenPresentationStops() async throws {
        _ = NSApplication.shared
        let source = "before\n\n![x](https://8.8.8.8/image.png)"
        let document = EditorDocument(text: source, language: .markdown)
        document.allowsRemoteImages = true
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedMarkdownImageURLProtocol.self]
        let session = URLSession(configuration: config)
        controller.imageSession = session
        let started = expectation(description: "request started"), stopped = expectation(description: "request stopped")
        DelayedMarkdownImageURLProtocol.started = { started.fulfill() }
        DelayedMarkdownImageURLProtocol.stopped = { stopped.fulfill() }
        defer {
            controller.cancel(); session.invalidateAndCancel()
            DelayedMarkdownImageURLProtocol.started = nil; DelayedMarkdownImageURLProtocol.stopped = nil
            withExtendedLifetime(scroll) {}
        }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [started], timeout: 4)
        controller.cancel()
        await fulfillment(of: [stopped], timeout: 4)
        XCTAssertEqual(storage.string, source)
    }

    func testVisibleRemoteImageUsesExistingDownloader() async throws {
        _ = NSApplication.shared
        let source = "---\ninvalid: [\n---\n\n![x](https://8.8.8.8/image.png)"
        let document = EditorDocument(text: source, language: .markdown)
        document.allowsRemoteImages = true
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MarkdownImageURLProtocol.self]
        let session = URLSession(configuration: config)
        controller.imageSession = session
        defer { controller.cancel(); session.invalidateAndCancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = (source as NSString).range(of: "![x](https://8.8.8.8/image.png)")
        func imageLocation() -> Int? {
            layout.ensureLayout(for: container)
            let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            return layout.markdownImageLocation(at: NSPoint(x: line.minX + container.lineFragmentPadding + 0.5, y: line.minY + 0.5), in: container)
        }
        for _ in 0..<200 where imageLocation() == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(imageLocation(), range.location)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }
    func testDocumentURLChangeDefersImageCleanupDuringChildComposition() async throws {
        _ = NSApplication.shared
        let source = "before\n\n![x](/image.png)"
        let document = EditorDocument(text: source, url: URL(fileURLWithPath: "/tmp/one.md"), language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        let range = (source as NSString).range(of: "![x](/image.png)")
        layout.setMarkdownImage(NSImage(size: NSSize(width: 80, height: 40)), for: range)
        layout.ensureLayout(for: container)
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        let point = NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 1)
        XCTAssertEqual(layout.markdownImageLocation(at: point, in: container), range.location)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        document.url = URL(fileURLWithPath: "/tmp/two.md")
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertEqual(layout.markdownImageLocation(at: point, in: container), range.location)
        child.unmarkText()
        controller.compositionFinished(revision: 0)
        XCTAssertNil(layout.markdownImageLocation(at: point, in: container))
        XCTAssertEqual(storage.string, source)
    }
    func testVideoDragUsesEditorReplacementAndUndo() throws {
        _ = NSApplication.shared
        let source = "before 😀 after"
        let document = EditorDocument(text: source, url: URL(fileURLWithPath: "/tmp/project/note.md"), language: .markdown)
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let file = URL(fileURLWithPath: "/tmp/project/影片 #.mp4")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        XCTAssertEqual(view.videoTransfer(from: board), file)
        view.setSelectedRange(NSRange(location: 9, length: 0))
        XCTAssertTrue(view.videoTransferHandler?(file) == true)
        XCTAssertTrue(view.string.contains("<video src=\"%E5%BD%B1%E7%89%87%20%23.mp4\" />"))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        view.isEditable = false
        XCTAssertFalse(view.videoTransferHandler?(file) ?? true)
        XCTAssertEqual(view.string, source)
    }
    func testSharedParserExcludesCodeAndKeepsUTF16Range() throws {
        let source = "😀\r\n\r\n<audio src='声音.mp3' />\r\n\r\n`<audio src='inline.mp3' />`\r\n\r\n```html\r\n<audio src='code.mp3' />\r\n```\r\n\r\n> <audio src='quoted.mp3' />\r\n"
        let blocks = MarkdownPresentationParser.parse(source).audioBlocks
        XCTAssertEqual(blocks.count, 2)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.source, "声音.mp3")
        XCTAssertEqual((source as NSString).substring(with: block.range), "<audio src='声音.mp3' />")
        XCTAssertEqual(blocks.last?.source, "quoted.mp3")
    }

    func testQuoteAndListMediaUseConfirmedContainerLines() throws {
        let source = "😀\r\n\r\n> <video controls\r\n> width='50%'>\r\n> <source src='movie>file.mp4'>\r\n> </video>\r\n\r\n- <audio controls>\r\n  <source src='sound.mp3'>\r\n  </audio>\r\n\r\n> <iframe src='https://example.invalid/page' title='A > B'></iframe>\r\n\r\n> <script>\r\n> <iframe src='https://example.invalid/hidden'></iframe>\r\n> </script>\r\n"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.audioBlocks.count, 2)
        XCTAssertEqual(parsed.audioBlocks.first?.media.sources, ["movie>file.mp4"])
        XCTAssertEqual(parsed.audioBlocks.last?.media.sources, ["sound.mp3"])
        XCTAssertEqual(parsed.iframeBlocks.count, 1)
        if let video = parsed.audioBlocks.first {
            let raw = (source as NSString).substring(with: video.range)
            XCTAssertTrue(raw.hasPrefix("<video"))
            XCTAssertTrue(raw.contains("> <source"))
        }
        let tabbed = "> \t<audio src='x.mp3' />\n"
        XCTAssertTrue(MarkdownPresentationParser.parse(tabbed).audioBlocks.isEmpty)
        let inert = "> before <script>\n>\n> <iframe src='https://example.invalid/hidden'></iframe>\n>\n> </script>\n\n> before <template>\n>\n> <iframe src='https://example.invalid/inert'></iframe>\n>\n> </template>\n"
        XCTAssertTrue(MarkdownPresentationParser.parse(inert).iframeBlocks.isEmpty)
        let splitScript = "> before <script><!--<script\n>\n> </script\n>\n> <iframe src='https://example.invalid/hidden'></iframe>\n> -->\n> </script>"
        XCTAssertTrue(MarkdownPresentationParser.parse(splitScript).iframeBlocks.isEmpty)
        let escapedQuote = "> before <script><!--<script\n>\n> </script\n>\n<iframe src='https://example.invalid/hidden'></iframe>"
        XCTAssertTrue(MarkdownPresentationParser.parse(escapedQuote).iframeBlocks.isEmpty)
        let closedScript = "> <script>safe</script>\n>\n> <iframe src='https://example.invalid/visible'></iframe>"
        XCTAssertEqual(MarkdownPresentationParser.parse(closedScript).iframeBlocks.count, 1)
        let topLevel = "before <script>safe\n\nmore </script>\n\n<iframe src='https://example.invalid/visible'></iframe>"
        XCTAssertEqual(MarkdownPresentationParser.parse(topLevel).iframeBlocks.count, 1)
        let provenGap = "> before <script>\n> plain text\n> </script>\n>\n> <iframe src='https://example.invalid/visible'></iframe>"
        XCTAssertEqual(MarkdownPresentationParser.parse(provenGap).iframeBlocks.count, 1)
        let listGap = "- before <script>\n  plain\n  </script>\n\n- <iframe src='https://example.invalid/visible'></iframe>"
        XCTAssertEqual(MarkdownPresentationParser.parse(listGap).iframeBlocks.count, 1)
        let referenceGap = "> before <script>\n>\n> [id]: /literal\n>\n> </script>\n>\n> <iframe src='https://example.invalid/visible'></iframe>"
        XCTAssertTrue(MarkdownPresentationParser.parse(referenceGap).iframeBlocks.isEmpty)
        let lazyGap = "> before <script>\ncontinued\n> </script>\n>\n> <iframe src='https://example.invalid/visible'></iframe>"
        XCTAssertTrue(MarkdownPresentationParser.parse(lazyGap).iframeBlocks.isEmpty)
    }

    func testListMediaGeometryKeepsMarkerAndRevealsSource() throws {
        let source = "- <audio src='sound.mp3' />\n\nafter"
        let parsed = MarkdownPresentationParser.parse(source)
        let block = try XCTUnwrap(parsed.audioBlocks.first)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        layout.setMarkdownMediaSize(NSSize(width: 300, height: 64), for: block.range)
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownMediaRect(for: block.range, in: container))
        XCTAssertGreaterThan(rect.minX, container.lineFragmentPadding)
        layout.updateMarkdownRevealedRange(block.range)
        XCTAssertNil(layout.markdownMediaRect(for: block.range, in: container))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testSharedParserRecognizesHTML5AudioAndVideo() throws {
        let source = "😀\r\n\r\n<audio controls>\r\n<source src='one.ogg'><source src='two.mp3'>\r\n</audio>\r\n\r\n<video src='movie.mp4' controls width='50%' height='240'></video>"
        let blocks = MarkdownPresentationParser.parse(source).audioBlocks
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].media.sources, ["one.ogg", "two.mp3"])
        XCTAssertEqual(blocks[1].media.kind, .video)
        XCTAssertEqual(blocks[1].media.width, "50%")
        XCTAssertTrue((source as NSString).substring(with: blocks[1].range).hasPrefix("<video"))
    }

    func testVerticalIframeKeepsPhysicalSizeAndRevealsSource() async throws {
        _ = NSApplication.shared
        let source = "before\n\n<iframe src=\"http://127.0.0.1:9/test\" width=\"50%\" height=\"100\"></iframe>\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        view.setLayoutOrientation(.vertical)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where view.subviews.compactMap({ $0 as? WKWebView }).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let iframeView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        let frame = try XCTUnwrap(MarkdownPresentationParser.parse(source).iframeBlocks.first)
        let logical = try XCTUnwrap(layout.markdownMediaRect(for: frame.range, in: container))
        let expected = scroll.contentView.convert(logical.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        let actual = scroll.contentView.convert(iframeView.bounds, from: iframeView)
        XCTAssertEqual(actual.width, scroll.contentView.bounds.width / 2, accuracy: 1)
        XCTAssertEqual(actual.height, 100, accuracy: 1)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
        view.setSelectedRange(frame.range)
        controller.selectionChanged()
        XCTAssertNil(iframeView.superview)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testIframeUsesIsolatedViewAndRevealsSource() async throws {
        _ = NSApplication.shared
        let source = "before\n\n<iframe src=\"http://127.0.0.1:9/test\" width=\"50%\" height=\"240\" title=\"Example\"></iframe>\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where view.subviews.compactMap({ $0 as? WKWebView }).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let iframeView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertFalse(iframeView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(iframeView.frame.width, (container.size.width - 2 * container.lineFragmentPadding) / 2, accuracy: 0.5)
        XCTAssertEqual(iframeView.frame.height, 240, accuracy: 0.5)
        container.containerSize = NSSize(width: 600, height: 1000)
        controller.viewportChanged()
        XCTAssertEqual(iframeView.frame.width, (container.size.width - 2 * container.lineFragmentPadding) / 2, accuracy: 0.5)
        let frame = try XCTUnwrap(MarkdownPresentationParser.parse(source).iframeBlocks.first)
        for _ in 0..<200 {
            if let value = try? await iframeView.evaluateJavaScript("document.querySelector('iframe') === null && document.querySelector('a')?.getAttribute('href') === 'http://127.0.0.1:9/test'") as? Bool,
               value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let isolated = try await iframeView.evaluateJavaScript("document.querySelector('iframe') === null && document.querySelector('a')?.getAttribute('href') === 'http://127.0.0.1:9/test'") as? Bool
        XCTAssertEqual(isolated, true)
        iframeView.removeFromSuperview()
        controller.viewportChanged()
        XCTAssertTrue(iframeView.superview === view)
        view.setSelectedRange(frame.range)
        controller.selectionChanged()
        XCTAssertNil(iframeView.superview)
        XCTAssertNil(layout.markdownMediaRect(for: frame.range, in: container))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        controller.selectionChanged()
        let unfolded = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        layout.setFoldedRange(frame.range)
        controller.viewportChanged()
        XCTAssertNil(unfolded.superview)
        layout.setFoldedRange(nil)
        controller.viewportChanged()
        let active = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
        controller.update(document: document, enabled: true, isActive: false, revision: 0, currentRevision: { 0 })
        XCTAssertNil(active.superview)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }

    func testLocalPlayerRevealsSourceAndStopsOnDeactivation() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var sound = Data("RIFF".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        func half(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        word(836); sound.append(Data("WAVEfmt ".utf8)); word(16)
        half(1); half(1); word(8000); word(8000); half(1); half(8)
        sound.append(Data("data".utf8)); word(800); sound.append(Data(repeating: 128, count: 800))
        try sound.write(to: folder.appendingPathComponent("声音.wav"))
        let source = "---\ntypora-root-url: .\n---\n\n## before\n\n<audio controls><source src='/missing.wav'><source src='/声音.wav'></audio>\n\nafter"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("document.md"), language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func currentPlayer() async throws -> AVPlayerView {
            for _ in 0..<100 {
                if let player = view.subviews.compactMap({ $0 as? AVPlayerView }).first { return player }
                try await Task.sleep(for: .milliseconds(100))
            }
            return try XCTUnwrap(view.subviews.compactMap { $0 as? AVPlayerView }.first)
        }
        let player = try await currentPlayer()
        XCTAssertNotNil(player.player)
        XCTAssertEqual(player.player?.rate, 0)
        let selectedAsset = try XCTUnwrap(player.player?.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(selectedAsset.url.standardizedFileURL, folder.appendingPathComponent("声音.wav").standardizedFileURL)
        player.removeFromSuperview()
        controller.viewportChanged()
        XCTAssertTrue(player.superview === view)
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).audioBlocks.first)
        XCTAssertNotNil(layout.markdownMediaRect(for: block.range, in: container))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        layout.textFont = NSFont.systemFont(ofSize: 24)
        controller.metricsChanged()
        let moved = try XCTUnwrap(layout.markdownMediaRect(for: block.range, in: container))
        XCTAssertEqual(player.frame, moved.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y))
        view.setSelectedRange(block.range)
        controller.selectionChanged()
        XCTAssertNil(player.superview)
        XCTAssertNil(player.player)
        XCTAssertNil(layout.markdownMediaRect(for: block.range, in: container))
        XCTAssertEqual(storage.string, source)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        controller.selectionChanged()
        let foldedPlayer = try await currentPlayer()
        layout.setFoldedRange(block.range)
        controller.viewportChanged()
        XCTAssertNil(foldedPlayer.superview)
        XCTAssertNil(foldedPlayer.player)
        layout.setFoldedRange(nil)
        controller.viewportChanged()
        let activePlayer = try await currentPlayer()
        controller.update(document: document, enabled: true, isActive: false, revision: 0, currentRevision: { 0 })
        XCTAssertNil(activePlayer.player)
        XCTAssertNil(activePlayer.superview)
        XCTAssertTrue(view.subviews.compactMap { $0 as? AVPlayerView }.isEmpty)
        XCTAssertFalse(document.isDirty)

        let videoSource = "before\n\n<video src='声音.wav' controls width='50%' height='240'></video>\n\nafter"
        let videoDocument = EditorDocument(text: videoSource, url: folder.appendingPathComponent("video.md"), language: .markdown)
        let videoStorage = NSTextStorage(string: videoSource), videoLayout = FoldLayoutManager()
        videoStorage.addLayoutManager(videoLayout)
        let videoContainer = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        videoLayout.addTextContainer(videoContainer)
        let videoView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: videoContainer)
        let videoScroll = NSScrollView(frame: videoView.frame)
        videoScroll.documentView = videoView
        videoView.setSelectedRange(NSRange(location: 0, length: 0))
        let videoController = MarkdownPresentationController(textView: videoView, layout: videoLayout)
        defer { videoController.cancel() }
        videoController.update(document: videoDocument, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<100 where videoView.subviews.compactMap({ $0 as? AVPlayerView }).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        let videoPlayer = try XCTUnwrap(videoView.subviews.compactMap { $0 as? AVPlayerView }.first)
        XCTAssertEqual(videoPlayer.frame.width, (videoContainer.size.width - 2 * videoContainer.lineFragmentPadding) / 2, accuracy: 0.5)
        XCTAssertEqual(videoPlayer.frame.height, 240, accuracy: 0.5)
        XCTAssertEqual(videoPlayer.controlsStyle, .inline)
        XCTAssertEqual(videoStorage.string, videoSource)
        withExtendedLifetime(videoScroll) {}

        let listSource = "before\n\n- <audio controls>\n  <source src='声音.wav'>\n  </audio>\n\nafter"
        let listDocument = EditorDocument(text: listSource, url: folder.appendingPathComponent("list.md"), language: .markdown)
        let listStorage = NSTextStorage(string: listSource), listLayout = FoldLayoutManager()
        listStorage.addLayoutManager(listLayout)
        let listContainer = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        listLayout.addTextContainer(listContainer)
        let listView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: listContainer)
        let listScroll = NSScrollView(frame: listView.frame)
        listScroll.documentView = listView
        listView.setSelectedRange(NSRange(location: 0, length: 0))
        let listController = MarkdownPresentationController(textView: listView, layout: listLayout)
        defer { listController.cancel() }
        listController.update(document: listDocument, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<100 where listView.subviews.compactMap({ $0 as? AVPlayerView }).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        let listPlayer = try XCTUnwrap(listView.subviews.compactMap { $0 as? AVPlayerView }.first)
        let listBlock = try XCTUnwrap(MarkdownPresentationParser.parse(listSource).audioBlocks.first)
        let listRect = try XCTUnwrap(listLayout.markdownMediaRect(for: listBlock.range, in: listContainer))
        XCTAssertGreaterThan(listRect.minX, listContainer.lineFragmentPadding)
        XCTAssertEqual(listPlayer.frame, listRect.offsetBy(dx: listView.textContainerOrigin.x, dy: listView.textContainerOrigin.y))
        listView.setSelectedRange(listBlock.range)
        listController.selectionChanged()
        XCTAssertNil(listPlayer.superview)
        XCTAssertEqual(listStorage.string, listSource)
        XCTAssertFalse(listDocument.isDirty)
        withExtendedLifetime(listScroll) {}
    }

    func testNestedMediaUsesOnlyConfirmedOuterRange() throws {
        for (source, inline) in [
            ("<video src='outer.mp4'>\nfallback <audio src='inner.wav'></audio>\n</video>", false),
            ("> <video src='outer.mp4'>\n> fallback <audio src='inner.wav'></audio>\n> </video>", false),
            ("- <video src='outer.mp4'>\n  fallback <audio src='inner.wav'></audio>\n  </video>", false),
            ("before <video src='outer.mp4'>fallback <audio src='inner.wav'></audio></video> after", true),
            ("<div>before <video src='outer.mp4'><img src='fallback.png'><audio src='inner.wav'></audio></video> after</div>", true)
        ] {
            let document = EditorDocument(text: source, language: .markdown)
            let presentation = MarkdownPresentationParser.parse(source)
            XCTAssertEqual(presentation.audioBlocks.count, 1)
            guard let outer = presentation.audioBlocks.first else { continue }
            XCTAssertEqual(outer.media.sources, ["outer.mp4"])
            XCTAssertEqual(outer.isInline, inline)
            XCTAssertTrue((source as NSString).substring(with: outer.range).hasPrefix("<video"))
            XCTAssertTrue(presentation.images.isEmpty)
            XCTAssertEqual(document.synchronizedText(), source)
            XCTAssertFalse(document.isDirty)
        }
        for source in ["**before <video src='x.mp4'>** fallback </video> after",
                       "before <video src='x.mp4'><audio src='y.wav'></video></audio> after",
                       "before <template><video src='x.mp4'><audio src='y.wav'></audio></video></template> after",
                       "before <script><video src='x.mp4'><audio src='y.wav'></audio></video></script> after"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).audioBlocks.isEmpty)
        }
        for source in ["**before <video src='x.mp4'>fallback</video> after**",
                       "*before <video src='x.mp4'>fallback</video> after*",
                       "~~before <video src='x.mp4'>fallback</video> after~~"] {
            let blocks = MarkdownPresentationParser.parse(source).audioBlocks
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks.first?.media.sources, ["x.mp4"])
            XCTAssertEqual(blocks.first?.isInline, true)
        }
        let linked = "[before <video src='x.mp4'>fallback</video> after](https://example.invalid)"
        let linkedPresentation = MarkdownPresentationParser.parse(linked)
        XCTAssertEqual(linkedPresentation.audioBlocks.count, 1)
        XCTAssertEqual(linkedPresentation.audioBlocks.first?.media.sources, ["x.mp4"])
        XCTAssertEqual(linkedPresentation.links.count, 1)
    }


    /// Каталог с настоящим wav: плеер должен реально играть.
    private func makeSoundFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sound = Data("RIFF".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        func half(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        word(24036); sound.append(Data("WAVEfmt ".utf8)); word(16)
        half(1); half(1); word(8000); word(8000); half(1); half(8)
        sound.append(Data("data".utf8)); word(24000); sound.append(Data(repeating: 128, count: 24000))
        try sound.write(to: folder.appendingPathComponent("sound.wav"))
        return folder
    }

    @MainActor
    func testTypingOutsideKeepsPlayingAudio() async throws {
        let folder = try makeSoundFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = MarkdownHTMLBlockProofTests.InsertShiftFixture("intro words\n\n<audio src='sound.wav' />\n\nend words\n",
                                                                     url: folder.appendingPathComponent("note.md"), selecting: "end words")
        defer { fixture.close() }
        try await fixture.wait { !fixture.view.subviews.compactMap { $0 as? AVPlayerView }.isEmpty }
        let playerView = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? AVPlayerView }.first)
        let player = try XCTUnwrap(playerView.player)
        player.play()
        try await fixture.wait { player.rate > 0 }
        var completions = 0
        fixture.controller.audioLoadDidComplete = { _, _ in completions += 1 }
        for marker in ["intro wor", "end wor"] {
            fixture.type(after: marker)
            try await fixture.settle()
            let current = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? AVPlayerView }.first, marker)
            XCTAssertTrue(current === playerView, marker)
            XCTAssertTrue(current.player === player, marker)
            XCTAssertGreaterThan(player.rate, 0, marker)
        }
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(fixture.view.subviews.compactMap { $0 as? AVPlayerView }.count, 1)
    }

    @MainActor
    func testTypingOutsideCancelsPendingAudioLoadAndStartsOnePlayer() async throws {
        let folder = try makeSoundFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "intro words\n\n<audio src='sound.wav' />\n\nend words\n"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("note.md"), language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 800)); layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end words"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        let started = expectation(description: "audio check started")
        var pending: CheckedContinuation<Bool, Never>?
        defer { pending?.resume(returning: false) }
        controller.audioAssetIsPlayable = { _ in await withCheckedContinuation { pending = $0; started.fulfill() } }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { revision })
        await fulfillment(of: [started], timeout: 10)
        // Правка вне блока: идущая загрузка отменяется, а не доживает со старым диапазоном.
        let finished = expectation(description: "old audio job finished")
        finished.assertForOverFulfill = false
        controller.audioJobDidFinish = { _ in finished.fulfill() }
        let edit = NSRange(location: NSMaxRange((source as NSString).range(of: "intro wor")), length: 0)
        revision += 1
        controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        storage.replaceCharacters(in: edit, with: "x")
        controller.edited(revision: revision)
        let old = try XCTUnwrap(pending); pending = nil; old.resume(returning: true)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertTrue(view.subviews.compactMap { $0 as? AVPlayerView }.isEmpty)
        // Загрузка запускается заново по новому диапазону, плеер появляется один.
        controller.audioAssetIsPlayable = { _ in true }
        controller.viewportChanged()
        for _ in 0..<100 where view.subviews.compactMap({ $0 as? AVPlayerView }).isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(view.subviews.compactMap { $0 as? AVPlayerView }.count, 1)
        XCTAssertEqual(storage.string, source.replacingOccurrences(of: "intro wor", with: "intro worx"))
        withExtendedLifetime(scroll) {}
    }

    @MainActor
    func testTypingOutsideKeepsIframeWebView() async throws {
        let fixture = MarkdownHTMLBlockProofTests.InsertShiftFixture(
            "intro words\n\n<iframe src='https://example.invalid' width='50%' height='60'>fallback</iframe>\n\nend words\n", selecting: "end words")
        defer { fixture.close() }
        try await fixture.wait { !fixture.view.subviews.compactMap { $0 as? WKWebView }.isEmpty }
        let web = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? WKWebView }.first)
        for marker in ["intro wor", "end wor"] {
            fixture.type(after: marker)
            try await fixture.settle()
            let current = try XCTUnwrap(fixture.view.subviews.compactMap { $0 as? WKWebView }.first, marker)
            XCTAssertTrue(current === web, marker)
            XCTAssertNotNil(web.superview, marker)
        }
        XCTAssertEqual(fixture.view.subviews.compactMap { $0 as? WKWebView }.count, 1)
    }
}
