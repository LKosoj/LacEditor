import AppKit
import Network
import WebKit
import XCTest
@testable import LacEditor

private final class PreviewFrameServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "MarkdownPreviewTests.frame")
    private let lock = NSLock()
    private var paths: [String] = []
    private var held: NWConnection?
    private let heldStarted: XCTestExpectation

    init(ready: XCTestExpectation, heldStarted: XCTestExpectation) throws {
        self.heldStarted = heldStarted
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] part, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = data
            if let part { request.append(part) }
            guard let string = String(data: request, encoding: .utf8), string.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, data: request) }
                return
            }
            let path = string.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.lock(); self.paths.append(path); self.lock.unlock()
            if path == "/hold" {
                self.lock.lock(); self.held = connection; self.lock.unlock()
                self.heldStarted.fulfill()
                return
            }
            let body: String
            if path == "/frame" {
                body = """
                <!doctype html><script>
                let denied = false;
                try { void parent.document.body; } catch (_) { denied = true; }
                fetch('file:///etc/passwd').then(() => false, () => true).then(fileDenied =>
                    parent.postMessage({lacChild: true, parentDenied: denied, fileDenied}, '*'));
                </script>child
                """
            } else { body = "document.documentElement.dataset.externalRan='yes';" }
            let bytes = Data(body.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: " + (path == "/frame" ? "text/html" : "application/javascript") + "\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func release(_ finished: XCTestExpectation) {
        lock.lock(); let connection = held; held = nil; lock.unlock()
        guard let connection else { finished.fulfill(); return }
        let body = Data("<!doctype html><p>late frame</p>".utf8)
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel(); finished.fulfill() })
    }
    func stop() { lock.lock(); let connection = held; held = nil; lock.unlock(); connection?.cancel(); listener.cancel() }
}

private final class PendingPreviewImageURLProtocol: URLProtocol {
    static var started: XCTestExpectation?
    static var stopped: XCTestExpectation?
    static var pending: PendingPreviewImageURLProtocol?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.pending = self; Self.started?.fulfill() }
    override func stopLoading() { Self.stopped?.fulfill() }
    func finish(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private final class HeldPreviewNavigation: NSObject, WKNavigationDelegate {
    weak var coordinator: MarkdownPreview.Coordinator?
    var first: XCTestExpectation?
    var second: XCTestExpectation?
    var navigations: [WKNavigation] = []
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigations.append(navigation)
        if navigations.count == 1 { first?.fulfill() }
        if navigations.count == 2 { second?.fulfill() }
    }
    func release(in webView: WKWebView) {
        for navigation in navigations { coordinator?.webView(webView, didFinish: navigation) }
        navigations.removeAll()
    }
}

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    func testPreviewCSPBlocksParentScriptsButAllowsSandboxedFrame() async throws {
        let ready = expectation(description: "local frame server ready")
        let held = expectation(description: "old frame request held")
        let server = try PreviewFrameServer(ready: ready, heldStarted: held)
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 10)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let listener = """
        window.addEventListener('message', e => {
            if (e.data && e.data.lacChild) {
                document.documentElement.dataset.childRan = 'yes';
                document.documentElement.dataset.parentDenied = String(e.data.parentDenied);
                document.documentElement.dataset.fileDenied = String(e.data.fileDenied);
            }
        });
        """
        fixture.webView.configuration.userContentController.addUserScript(WKUserScript(source: listener, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        let source = "before\n\n<script>document.documentElement.dataset.sourceRan='yes'</script>\n\n<iframe src='http://127.0.0.1:\(port)/frame' width='300' height='120'></iframe>\n\nafter"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.documentElement.dataset.childRan === 'yes'")
        let sandbox: String = try await fixture.value("document.querySelector('article iframe').getAttribute('sandbox')")
        XCTAssertEqual(sandbox, "allow-scripts")
        let denied: Bool = try await fixture.value("document.documentElement.dataset.parentDenied === 'true' && document.documentElement.dataset.fileDenied === 'true'")
        XCTAssertTrue(denied)
        let appScript: Bool = try await fixture.value("""
        (() => {
            document.documentElement.dataset.appRan = 'yes';
            const inline = document.createElement('script'); inline.textContent = "document.documentElement.dataset.inlineRan='yes'"; document.body.appendChild(inline);
            const external = document.createElement('script'); external.src = 'http://127.0.0.1:\(port)/evil.js'; document.body.appendChild(external);
            const button = document.createElement('button'); button.setAttribute('onclick', "document.documentElement.dataset.eventRan='yes'"); document.body.appendChild(button); button.click();
            const link = document.createElement('a'); link.href = "javascript:document.documentElement.dataset.urlRan='yes'"; document.body.appendChild(link); link.click();
            return document.documentElement.dataset.appRan === 'yes';
        })()
        """)
        XCTAssertTrue(appScript)
        try await Task.sleep(for: .milliseconds(200))
        let blocked: Bool = try await fixture.value("!document.documentElement.dataset.sourceRan && !document.documentElement.dataset.inlineRan && !document.documentElement.dataset.externalRan && !document.documentElement.dataset.eventRan && !document.documentElement.dataset.urlRan")
        XCTAssertTrue(blocked)
        XCTAssertFalse(server.requests().contains("/evil.js"))
        let old = "<iframe src='http://127.0.0.1:\(port)/hold' width='300' height='120'></iframe>"
        fixture.coordinator.render(markdown: old, revision: 2, darkMode: false, immediately: true)
        await fulfillment(of: [held], timeout: 10)
        fixture.coordinator.render(markdown: "NEW REVISION", revision: 3, darkMode: false, immediately: true)
        try await fixture.waitForRevision(3)
        let released = expectation(description: "old frame response released")
        server.release(released)
        await fulfillment(of: [released], timeout: 10)
        let current: Bool = try await fixture.value("document.querySelector('article').innerText.includes('NEW REVISION') && !document.querySelector('article iframe')")
        XCTAssertTrue(current)
    }

    func testStandaloneSVGPreviewUsesIsolatedVectorImage() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "before\n\n<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>\n\nafter"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article img')?.naturalWidth === 40")
        let pixel: [Int] = try await fixture.value("(() => { const c = document.createElement('canvas'); c.width = 40; c.height = 20; const x = c.getContext('2d'); x.drawImage(document.querySelector('article img'), 0, 0); return Array.from(x.getImageData(20, 10, 1, 1).data); })()")
        XCTAssertEqual(pixel.count, 4)
        if pixel.count == 4 { XCTAssertGreaterThan(pixel[0], 200); XCTAssertLessThan(pixel[2], 30) }
        let visible: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(visible.contains("before"))
        XCTAssertTrue(visible.contains("after"))
    }

    func testDisplayNoneIsHiddenInPreview() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "before 中文 <span style='display:none;color:red'>hidden <span style='background:yellow'>nested</span></span> after 😀"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article span[style*=display]') !== null")
        let display: String = try await fixture.value("getComputedStyle(document.querySelector('article span[style*=display]')).display")
        let visible: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertEqual(display, "none")
        XCTAssertTrue(visible.contains("before 中文"))
        XCTAssertTrue(visible.contains("after 😀"))
        XCTAssertFalse(visible.contains("hidden"))
        XCTAssertFalse(visible.contains("nested"))
    }

    func testDetailsPreviewTogglesWithoutChangingSource() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "before 中文\n\n<details><summary>More</summary>Body 😀</details>\n\nafter"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article details') !== null")
        let closed: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(closed.contains("More"))
        XCTAssertFalse(closed.contains("Body 😀"))
        let opened: Bool = try await fixture.value("(() => { const d = document.querySelector('article details'); d.querySelector('summary').click(); return d.open; })()")
        XCTAssertTrue(opened)
        let visible: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(visible.contains("Body 😀"))
        fixture.coordinator.render(markdown: source, revision: 2, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article details') !== null && !document.querySelector('article details').open")
        let reset: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertFalse(reset.contains("Body 😀"))
    }

    func testHTMLCommentsStayInvisibleInPreviewButCodeRemainsText() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "before 中文\n\n<!-- COMMENT_SECRET\ncontinued -->\n\n<script><!-- SCRIPT_SECRET --></script>\n\n<template><!-- TEMPLATE_SECRET --></template>\n\n```html\n<!-- CODE_LITERAL -->\n```\n\nafter 😀"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article code') !== null")
        let visible: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(visible.contains("before 中文"))
        XCTAssertTrue(visible.contains("after 😀"))
        XCTAssertTrue(visible.contains("<!-- CODE_LITERAL -->"))
        XCTAssertFalse(visible.contains("COMMENT_SECRET"))
        XCTAssertFalse(visible.contains("SCRIPT_SECRET"))
        XCTAssertFalse(visible.contains("TEMPLATE_SECRET"))
        let unclosed = "NEWCOMMENTSTART\n\n<!-- UNCLOSED_SECRET\nafter"
        fixture.coordinator.render(markdown: unclosed, revision: 2, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article').innerText.includes('NEWCOMMENTSTART')")
        let current: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertFalse(current.contains("UNCLOSED_SECRET"))
        XCTAssertFalse(current.contains("after"))
    }

    func testListStylesUpdateWithoutChangingContent() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "1. one\n   - nested\n2. two"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('li > span[data-lac-list-depth]') !== null")
        let before: String = try await fixture.value("document.querySelector('article').textContent")
        var styles = MarkdownListStyles()
        styles.ordered[1] = .upperRoman
        styles.unordered[2] = .circle
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 14, lineHeight: 20, listStyles: styles), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.querySelector('ol > li')).listStyleType === 'upper-roman'")
        let nested: String = try await fixture.value("getComputedStyle(document.querySelector('ul > li')).listStyleType")
        let after: String = try await fixture.value("document.querySelector('article').textContent")
        XCTAssertEqual(nested, "circle")
        XCTAssertEqual(before, after)
    }

    func testViewMagnificationKeepsPreviewContents() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "# Title\n\nHello 😀", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('h1') !== null")
        let before: String = try await fixture.value("document.querySelector('article').textContent")
        let headingID: String = try await fixture.value("document.querySelector('h1').id")
        fixture.webView.setMagnification(2, centeredAt: NSPoint(x: 200, y: 200))
        XCTAssertEqual(fixture.webView.magnification, 2, accuracy: 0.001)
        let after: String = try await fixture.value("document.querySelector('article').textContent")
        let afterID: String = try await fixture.value("document.querySelector('h1').id")
        XCTAssertEqual(before, after)
        XCTAssertEqual(headingID, afterID)
        fixture.webView.setMagnification(1, centeredAt: NSPoint(x: 200, y: 200))
        XCTAssertEqual(fixture.webView.magnification, 1, accuracy: 0.001)
    }

    func testHeadingNumberingUpdatesWithoutChangingTitleOrAnchor() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "[toc]\n\n# Title :smile:\n\n### Child"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('h1 span[data-lac-heading-number]') !== null")
        let before: String = try await fixture.value("document.querySelector('h1').textContent")
        let anchor: String = try await fixture.value("document.querySelector('nav a').getAttribute('href')")
        let hidden: String = try await fixture.value("getComputedStyle(document.querySelector('h1 span[data-lac-heading-number]'), '::before').content")
        XCTAssertEqual(hidden, "none")
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 14, lineHeight: 20, numberHeadings: true), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.querySelector('h1 span[data-lac-heading-number]'), '::before').content !== 'none'")
        let after: String = try await fixture.value("document.querySelector('h1').textContent")
        let afterAnchor: String = try await fixture.value("document.querySelector('nav a').getAttribute('href')")
        let tocContent: String = try await fixture.value("getComputedStyle(document.querySelector('nav span[data-lac-heading-number]'), '::before').content")
        XCTAssertEqual(before, after)
        XCTAssertTrue(after.contains("😄"))
        XCTAssertEqual(anchor, afterAnchor)
        XCTAssertNotEqual(tocContent, "none")
    }

    func testRemoteImageDoesNotDelayTextAndOldResultIsDiscarded() async throws {
        let started = expectation(description: "remote request started")
        let stopped = expectation(description: "old request cancelled")
        PendingPreviewImageURLProtocol.started = started
        PendingPreviewImageURLProtocol.stopped = stopped
        defer { PendingPreviewImageURLProtocol.started = nil; PendingPreviewImageURLProtocol.stopped = nil; PendingPreviewImageURLProtocol.pending = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingPreviewImageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = PreviewFixture(imageSession: session)
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "old text ![image](https://example.invalid/slow.png)", revision: 1, darkMode: false, immediately: true)
        await fulfillment(of: [started], timeout: 5)
        try await fixture.waitUntil("document.querySelector('article')?.textContent.includes('old text') && document.querySelector('article img')?.getAttribute('src') === 'data:,'")
        fixture.coordinator.render(markdown: "new text", revision: 2, darkMode: false, immediately: true)
        await fulfillment(of: [stopped], timeout: 5)
        try await fixture.waitUntil("document.querySelector('article')?.textContent.includes('new text')")
        PendingPreviewImageURLProtocol.pending?.finish(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!)
        let noOldImage: Bool = try await fixture.value("document.querySelector('article').textContent.includes('new text') && !document.querySelector('article img')")
        XCTAssertTrue(noOldImage)
    }

    func testLocalAudioPlaysInPreviewAndDisappearsAfterRevision() async throws {
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
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.document.url = folder.appendingPathComponent("note.md")
        fixture.coordinator.render(markdown: "[before <audio controls src='sound.wav#t=1'></audio> after](#target)\n\n# Target", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article audio')?.readyState >= 2")
        let source: String = try await fixture.value("document.querySelector('article audio source').getAttribute('src')")
        XCTAssertTrue(source.hasPrefix("data:audio/"))
        XCTAssertTrue(source.hasSuffix("#t=1"))
        let text: String = try await fixture.value("document.querySelector('article').textContent")
        XCTAssertTrue(text.contains("before"))
        XCTAssertTrue(text.contains("after"))
        let oneAnchor: Bool = try await fixture.value("document.querySelectorAll('article a').length === 1 && !!document.querySelector('article a audio')")
        XCTAssertTrue(oneAnchor)
        _ = try await fixture.webView.callAsyncJavaScript("const a = document.querySelector('article audio'); a.muted = true; await a.play(); return !a.paused;", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await fixture.waitUntil("document.querySelector('article audio')?.paused === false")
        fixture.coordinator.render(markdown: "new text", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article')?.textContent.includes('new text') && !document.querySelector('article audio')")
    }

    func testHTMLImageSizingUsesActualPreviewGeometry() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let source = "before <img src='data:image/png;base64,\(png)' width='80' height='20' style='zoom:50%'> after"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article img')?.naturalWidth === 1")
        let width: Double = try await fixture.value("document.querySelector('article img').getBoundingClientRect().width")
        let height: Double = try await fixture.value("document.querySelector('article img').getBoundingClientRect().height")
        XCTAssertEqual(width, 40, accuracy: 0.5)
        XCTAssertEqual(height, 10, accuracy: 0.5)
        let text: String = try await fixture.value("document.querySelector('article').textContent")
        XCTAssertTrue(text.contains("before"))
        XCTAssertTrue(text.contains("after"))
    }

    func testRemoteHTMLImageIsCancelledWhenPreviewChanges() async throws {
        let started = expectation(description: "HTML image request started")
        let stopped = expectation(description: "HTML image request cancelled")
        PendingPreviewImageURLProtocol.started = started
        PendingPreviewImageURLProtocol.stopped = stopped
        defer { PendingPreviewImageURLProtocol.started = nil; PendingPreviewImageURLProtocol.stopped = nil; PendingPreviewImageURLProtocol.pending = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingPreviewImageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = PreviewFixture(imageSession: session)
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "old <img src='https://example.invalid/slow.png' width='50%'>", revision: 1, darkMode: false, immediately: true)
        await fulfillment(of: [started], timeout: 5)
        try await fixture.waitUntil("document.querySelector('article')?.textContent.includes('old') && document.querySelector('article img')?.getAttribute('src') === 'data:,'")
        fixture.coordinator.render(markdown: "new text", revision: 2, darkMode: false, immediately: true)
        await fulfillment(of: [stopped], timeout: 5)
        try await fixture.waitUntil("document.querySelector('article')?.textContent.includes('new text')")
        PendingPreviewImageURLProtocol.pending?.finish(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!)
        let unchanged: Bool = try await fixture.value("document.querySelector('article').textContent.includes('new text') && !document.querySelector('article img')")
        XCTAssertTrue(unchanged)
    }

    func testFallbackNavigationUsesCompletedRemotePageAndRejectsOldRevision() async throws {
        let started = expectation(description: "remote request started")
        PendingPreviewImageURLProtocol.started = started
        defer { PendingPreviewImageURLProtocol.started = nil; PendingPreviewImageURLProtocol.stopped = nil; PendingPreviewImageURLProtocol.pending = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingPreviewImageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = PreviewFixture(imageSession: session)
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "initial", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let held = HeldPreviewNavigation()
        held.coordinator = fixture.coordinator
        held.first = expectation(description: "placeholder fallback navigation finished")
        held.second = expectation(description: "completed fallback navigation finished")
        fixture.webView.navigationDelegate = held
        let _: Bool = try await fixture.value("document.querySelector('article').remove(); true")
        fixture.coordinator.render(markdown: "remote ![image](https://example.invalid/slow.png)", revision: 2, darkMode: false, immediately: true)
        await fulfillment(of: [started, try XCTUnwrap(held.first)], timeout: 10)
        PendingPreviewImageURLProtocol.pending?.finish(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!)
        await fulfillment(of: [try XCTUnwrap(held.second)], timeout: 10)
        held.release(in: fixture.webView)
        try await fixture.waitUntil("document.querySelector('article img')?.naturalWidth === 1")
        fixture.webView.navigationDelegate = fixture.coordinator
        fixture.coordinator.render(markdown: "new revision", revision: 3, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article')?.textContent.includes('new revision') && !document.querySelector('article img')")
        let staleStarted = expectation(description: "second remote request started")
        let staleStopped = expectation(description: "second remote request cancelled")
        PendingPreviewImageURLProtocol.started = staleStarted
        PendingPreviewImageURLProtocol.stopped = staleStopped
        PendingPreviewImageURLProtocol.pending = nil
        let staleNavigation = HeldPreviewNavigation()
        staleNavigation.coordinator = fixture.coordinator
        staleNavigation.first = expectation(description: "old revision navigation held")
        staleNavigation.second = expectation(description: "new revision navigation held")
        fixture.webView.navigationDelegate = staleNavigation
        fixture.coordinator.render(markdown: "old ![image](https://example.invalid/again.png)", revision: 4, darkMode: false, immediately: true)
        await fulfillment(of: [staleStarted, try XCTUnwrap(staleNavigation.first)], timeout: 10)
        fixture.coordinator.render(markdown: "latest revision", revision: 5, darkMode: false, immediately: true)
        await fulfillment(of: [staleStopped, try XCTUnwrap(staleNavigation.second)], timeout: 10)
        PendingPreviewImageURLProtocol.pending?.finish(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=")!)
        staleNavigation.release(in: fixture.webView)
        try await fixture.waitUntil("document.querySelector('article')?.textContent.includes('latest revision') && !document.querySelector('article img')")
    }
    func testSyntaxChangeRerendersSameRevision() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "first\nsecond $x$"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article br') !== null")
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   syntax: .init(inlineMath: false, preserveEditingSoftBreaks: false), immediately: true)
        try await fixture.waitUntil("document.querySelector('article br') === null && document.querySelector('article').textContent.includes('$x$')")
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   syntax: .init(inlineMath: false, preserveEditingWhitespace: true, preserveEditingSoftBreaks: false), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.querySelector('article span[data-lac-whitespace]')).whiteSpace === 'break-spaces'")
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   syntax: .init(inlineMath: false, preserveEditingWhitespace: false, preserveEditingSoftBreaks: false), immediately: true)
        try await fixture.waitUntil("document.querySelector('article span[data-lac-whitespace]') === null")
    }

    func testPreservedWhitespaceDoesNotRenderSerializerNewlines() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "a\nb  \nc\n\n- one\n  - two\n\n```\ncode  here\n```"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   syntax: .init(preserveEditingWhitespace: true, preserveEditingSoftBreaks: true), immediately: true)
        try await fixture.waitUntil("document.querySelectorAll('article p span[data-lac-whitespace]').length === 3")
        let positions: [Double] = try await fixture.value("Array.from(document.querySelectorAll('article p span[data-lac-whitespace]'), e => e.getBoundingClientRect().top)")
        XCTAssertEqual(positions.count, 3)
        if positions.count == 3 {
            XCTAssertGreaterThan(positions[1], positions[0])
            XCTAssertGreaterThan(positions[2], positions[1])
        }
        let listText: String = try await fixture.value("document.querySelector('article ul').innerText")
        XCTAssertFalse(listText.contains("\n\n"))
        let codeWhitespace: String = try await fixture.value("getComputedStyle(document.querySelector('article pre code')).whiteSpace")
        XCTAssertEqual(codeWhitespace, "pre")
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   syntax: .init(preserveEditingWhitespace: true, preserveEditingSoftBreaks: false), immediately: true)
        try await fixture.waitUntil("document.querySelectorAll('article p span[data-lac-whitespace]').length === 3 && document.querySelectorAll('article p br').length === 1")
        let merged: [Double] = try await fixture.value("Array.from(document.querySelectorAll('article p span[data-lac-whitespace]'), e => e.getBoundingClientRect().top)")
        XCTAssertEqual(merged.count, 3)
        if merged.count == 3 {
            XCTAssertEqual(merged[0], merged[1], accuracy: 0.5)
            XCTAssertGreaterThan(merged[2], merged[1])
        }
    }
    func testVerticalWritingWrapsAndScrollsAcrossColumns() async throws {
        let fixture = PreviewFixture(width: 320)
        defer { fixture.dispose() }
        let source = String(repeating: "中文", count: 2_000)
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 15, lineHeight: 22, verticalWriting: true), immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("(() => { const a=document.querySelector('article'), p=a.querySelector('p'); return getComputedStyle(a).writingMode === 'vertical-rl' && p.getBoundingClientRect().width > 44 && a.scrollWidth > a.clientWidth; })()")
        let moved: Bool = try await fixture.value("(() => { const a=document.querySelector('article'); a.scrollLeft = -100; return a.scrollLeft < 0; })()")
        XCTAssertTrue(moved)
        let before: Double = try await fixture.value("(() => { const a=document.querySelector('article'); return a.scrollLeft / (a.scrollWidth-a.clientWidth); })()")
        fixture.coordinator.render(markdown: source + "末尾", revision: 2, darkMode: true,
                                   typography: MarkdownTypography(fontSize: 15, lineHeight: 22, verticalWriting: true), immediately: true)
        try await fixture.waitForRevision(2)
        try await fixture.waitUntil("(() => { const a=document.querySelector('article'); return Math.abs(a.scrollLeft / (a.scrollWidth-a.clientWidth) - (\(before))) < 0.03; })()")
        let after: Double = try await fixture.value("(() => { const a=document.querySelector('article'); return a.scrollLeft / (a.scrollWidth-a.clientWidth); })()")
        XCTAssertEqual(after, before, accuracy: 0.03)
        let origin: Double = try await fixture.value("performance.timeOrigin")
        _ = fixture.webView.reload()
        try await fixture.waitUntil("performance.timeOrigin !== \(origin)")
        try await fixture.waitForRevision(2)
        try await fixture.waitUntil("(() => { const a=document.querySelector('article'); return Math.abs(a.scrollLeft / (a.scrollWidth-a.clientWidth) - (\(before))) < 0.03; })()")
        let reloaded: Double = try await fixture.value("(() => { const a=document.querySelector('article'); return a.scrollLeft / (a.scrollWidth-a.clientWidth); })()")
        XCTAssertEqual(reloaded, before, accuracy: 0.03)
    }

    func testCompletedTaskStyleUpdatesLive() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "- [x] done\n  - [ ] nested\n- [ ] pending"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 14, lineHeight: 20, strikeCompletedTasks: true), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.querySelectorAll('li')[0]).textDecorationLine.includes('line-through')")
        let nested: Bool = try await fixture.value("document.querySelector('li input:checked').parentElement.querySelector('ul li input:not(:checked)') !== null")
        XCTAssertTrue(nested)
        let incomplete: String = try await fixture.value("getComputedStyle(document.querySelectorAll('article > ul > li')[1]).textDecorationLine")
        XCTAssertFalse(incomplete.contains("line-through"))
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, typography: nil, immediately: true)
        try await fixture.waitUntil("!getComputedStyle(document.querySelectorAll('li')[0]).textDecorationLine.includes('line-through')")
    }

    func testPreviewNamedAnchorIsPlacedBesideItsHTMLTarget() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "[jump](#inside)\n\n<div>before <a id='inside'>target</a> after</div>"
        fixture.document.text = source
        let revision = fixture.document.textRevision
        fixture.coordinator.render(markdown: source, revision: revision, darkMode: false, immediately: true)
        try await fixture.waitForRevision(revision)
        let correct: Bool = try await fixture.value("(() => { const link = document.querySelector('article a[href^=\"#lac-anchor-\"]'); const target = link && document.getElementById(link.getAttribute('href').slice(1)); return !!target && target.nextElementSibling?.textContent === 'target'; })()")
        XCTAssertTrue(correct)
    }

    func testPreviewRoutesRelativeLinksFromCurrentDOM() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.window.makeKeyAndOrderFront(nil)
        let source = "[local](other%20file.md#part)\n\n[jump](#heading)\n\n# Heading"
        fixture.document.url = URL(fileURLWithPath: "/tmp/source.md")
        fixture.document.text = source
        let revision = fixture.document.textRevision
        let delivered = expectation(description: "preview link request")
        var captured: MarkdownLinkNavigationRequest?
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.navigateMarkdownLink, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                if let request = notification.object as? MarkdownLinkNavigationRequest, request.snapshot.documentID == fixture.document.id {
                    captured = request
                    delivered.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.coordinator.render(markdown: source, revision: revision, darkMode: false, immediately: true)
        try await fixture.waitForRevision(revision)
        for _ in 0..<200 where fixture.coordinator.visibleRevision != revision { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.coordinator.visibleRevision, revision)
        let prevented: Bool = try await fixture.value("!document.querySelector('a[href^=other]').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,button:0}))")
        XCTAssertTrue(prevented)
        await fulfillment(of: [delivered], timeout: 5)
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.link.url, "other%20file.md#part")
        XCTAssertTrue(request.isCurrent())
        let internalDefault: Bool = try await fixture.value("document.querySelector('a[href^=\\\"#lac-heading-\\\"]').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,button:0}))")
        XCTAssertTrue(internalDefault)
        let originalURL = fixture.document.url
        fixture.document.url = URL(fileURLWithPath: "/tmp/moved.md")
        XCTAssertFalse(request.isCurrent())
        fixture.document.url = originalURL
        fixture.document.text = source + " changed"
        XCTAssertFalse(request.isCurrent())
    }

    func testPreviewRejectsMessageFromPreviousDOM() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.document.text = "[old](old.md)"
        let oldRevision = fixture.document.textRevision
        fixture.coordinator.render(markdown: fixture.document.text, revision: oldRevision, darkMode: false, immediately: true)
        try await fixture.waitUntil("Boolean(document.documentElement.dataset.mathDOMID)")
        let oldID: String = try await fixture.value("document.documentElement.dataset.mathDOMID")
        fixture.document.text = "[new](new.md)"
        let revision = fixture.document.textRevision
        fixture.coordinator.render(markdown: fixture.document.text, revision: revision, darkMode: false, immediately: true)
        try await fixture.waitForRevision(revision)
        for _ in 0..<200 where fixture.coordinator.visibleRevision != revision { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.coordinator.visibleRevision, revision)
        let delivered = expectation(description: "current DOM message")
        var addresses: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.navigateMarkdownLink, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                if let request = notification.object as? MarkdownLinkNavigationRequest, request.snapshot.documentID == fixture.document.id {
                    addresses.append(request.link.url)
                    if request.link.url == "new.md" { delivered.fulfill() }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let encodedID = try XCTUnwrap(String(data: JSONEncoder().encode(oldID), encoding: .utf8))
        let _: Bool = try await fixture.value("window.webkit.messageHandlers.lacLink.postMessage({href:'old.md',domID:\(encodedID)}); document.querySelector('a[href=\"new.md\"]').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,button:0})); true")
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(addresses, ["new.md"])
    }

    func testPreviewRoutesExternalLinksWithOriginalAddresses() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.document.text = "[web](https://example.com/a?q=1) [mail](mailto:user@example.com)"
        let revision = fixture.document.textRevision
        let delivered = expectation(description: "external link requests")
        delivered.expectedFulfillmentCount = 2
        var addresses: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.navigateMarkdownLink, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                if let request = notification.object as? MarkdownLinkNavigationRequest, request.snapshot.documentID == fixture.document.id {
                    addresses.append(request.link.url)
                    delivered.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        fixture.coordinator.render(markdown: fixture.document.text, revision: revision, darkMode: false, immediately: true)
        try await fixture.waitForRevision(revision)
        for _ in 0..<200 where fixture.coordinator.visibleRevision != revision { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.coordinator.visibleRevision, revision)
        let _: Bool = try await fixture.value("document.querySelectorAll('article a').forEach(a => a.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,button:0}))); true")
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(addresses, ["https://example.com/a?q=1", "mailto:user@example.com"])
    }
    func testLocalImageUsesRootAndRefreshesWhenDocumentURLChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = directory.appendingPathComponent("first", isDirectory: true), second = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (folder, width) in [(first, 2), (second, 3)] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("image.png"))
        }
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.document.url = first.appendingPathComponent("note.md")
        let source = "---\ntypora-root-url: .\n---\n\n![x](/image.png)"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article img')?.naturalWidth === 2")
        fixture.document.url = second.appendingPathComponent("note.md")
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('article img')?.naturalWidth === 3")
    }
    func testSourcePositionsOnlyWhenRequested() {
        let source = "# T\n\ntext\n\n| a |\n|---|\n| b |\n\n```\ncode\n```"
        let with = MarkdownRenderer.renderPage(source, darkMode: false, includeSourcePositions: true).body
        XCTAssertTrue(with.contains("data-sourcepos=\"1:1-1:3\""))
        XCTAssertTrue(with.contains("class=\"table-scroll\""))
        XCTAssertTrue(with.contains("<table data-sourcepos=\""))
        XCTAssertTrue(with.contains("<pre tabindex=\"0\""))
        let without = MarkdownRenderer.renderPage(source, darkMode: false).body
        XCTAssertFalse(without.contains("data-sourcepos"))
        XCTAssertTrue(without.contains("<table>"))
        XCTAssertTrue(without.contains("<pre tabindex=\"0\""))
        let export = MarkdownRenderer.renderPage(source, darkMode: false, forExport: true, includeSourcePositions: true).body
        XCTAssertFalse(export.contains("data-sourcepos"))
        XCTAssertFalse(MarkdownRenderer.render(source, darkMode: false).contains("data-sourcepos"))
    }

    func testRenderActorDefaultEmitsSourcePositions() async {
        let coordinator = DocumentTaskCoordinator()
        let generation = coordinator.begin(.preview)
        let page = await MarkdownRenderActor().render("a\n\nb", darkMode: false, coordinator: coordinator, generation: generation)
        XCTAssertTrue(page?.body.contains("data-sourcepos") == true)
    }

    func testRelayAttachesOnlyWhileActive() {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.attachScrollRelay()
        XCTAssertTrue(fixture.document.previewScrollRelay.isListening)
        fixture.coordinator.setActive(false)
        XCTAssertFalse(fixture.document.previewScrollRelay.isListening)
        fixture.coordinator.setActive(true)
        XCTAssertTrue(fixture.document.previewScrollRelay.isListening)
    }

    func testScrollToEditorLineInterpolatesBetweenBlocks() async throws {
        let text = (1...80).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.attachScrollRelay()
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        // Абзац k стоит на строке 2k - 1: строка 79 — абзац 40.
        fixture.coordinator.scrollToEditorPosition(.init(line: 79, atBottom: false))
        try await fixture.waitUntil("scrollY > 0")
        let top: Double = try await fixture.value("document.querySelectorAll('article p')[39].getBoundingClientRect().top")
        XCTAssertEqual(top, 0, accuracy: 4)
        fixture.coordinator.scrollToEditorPosition(.init(line: 80, atBottom: false))
        try await fixture.waitUntil("document.querySelectorAll('article p')[39].getBoundingClientRect().top < -1")
        let below: Double = try await fixture.value("document.querySelectorAll('article p')[40].getBoundingClientRect().top")
        XCTAssertGreaterThan(below, 0)
        fixture.coordinator.scrollToEditorPosition(.init(line: 1, atBottom: false))
        try await fixture.waitUntil("scrollY === 0")
        fixture.coordinator.scrollToEditorPosition(.init(line: 1, atBottom: true))
        try await fixture.waitUntil("Math.abs(scrollY - (document.documentElement.scrollHeight - innerHeight)) < 1")
    }

    func testRenderActorSerializesAndSkipsCancelledWaitingWork() async {
        let gate = RenderGate()
        let started = expectation(description: "first render started")
        let waiting = expectation(description: "second render queued")
        let rendererActor = MarkdownRenderActor { text, darkMode, _, _ in
            gate.render(text, darkMode: darkMode, started: started)
        }
        let firstCoordinator = DocumentTaskCoordinator()
        let secondCoordinator = DocumentTaskCoordinator()
        let thirdCoordinator = DocumentTaskCoordinator()
        let firstGeneration = firstCoordinator.begin(.preview)
        let secondGeneration = secondCoordinator.begin(.preview)
        let thirdGeneration = thirdCoordinator.begin(.preview)
        let first = Task.detached {
            await rendererActor.render("first", darkMode: false, coordinator: firstCoordinator, generation: firstGeneration)
        }
        await fulfillment(of: [started], timeout: 5)
        let second = Task.detached {
            waiting.fulfill()
            return await rendererActor.render("second", darkMode: false, coordinator: secondCoordinator, generation: secondGeneration)
        }
        await fulfillment(of: [waiting], timeout: 5)
        second.cancel()
        let third = Task.detached {
            await rendererActor.render("third", darkMode: false, coordinator: thirdCoordinator, generation: thirdGeneration)
        }
        gate.release.signal()
        let firstPage = await first.value
        let secondPage = await second.value
        let thirdPage = await third.value
        XCTAssertNotNil(firstPage)
        XCTAssertNil(secondPage)
        XCTAssertNotNil(thirdPage)
        XCTAssertEqual(gate.calls, ["first", "third"])
        XCTAssertEqual(gate.maximumActive, 1)
    }

    func testEditsAndThemePatchExistingPageAndPreserveScroll() async throws {
        let text = String(repeating: "## 标题\n\n中英文 Mixed text，阅读与编辑。\n\n", count: 250)
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let time: Double = try await fixture.value("performance.timeOrigin")
        let _: Bool = try await fixture.value("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * .6); true")
        try await Task.sleep(for: .milliseconds(80))
        fixture.coordinator.render(markdown: text + "\n最新内容", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        let after: Double = try await fixture.value("performance.timeOrigin")
        XCTAssertEqual(time, after, "Editing must not navigate/reload the preview")
        let ratio: Double = try await fixture.value("scrollY / (document.documentElement.scrollHeight - innerHeight)")
        XCTAssertEqual(ratio, 0.6, accuracy: 0.025)
        fixture.coordinator.render(markdown: text + "\n最新内容", revision: 2, darkMode: true, immediately: true)
        try await fixture.waitUntil("document.documentElement.dataset.theme === 'dark'")
        let themed: Double = try await fixture.value("performance.timeOrigin")
        let color: String = try await fixture.value("getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(time, themed, "Appearance changes must reuse the page")
        XCTAssertEqual(color, "rgb(27, 27, 27)")
        XCTAssertTrue(fixture.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }


    func testTypographyUpdatesWithoutReplacingContentAndKeepsLatestPendingValue() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let text = "# Heading\n\n中文 `code` text\n\nend"
        let first = MarkdownTypography(fontSize: 18, lineHeight: 25)
        let latest = MarkdownTypography(fontSize: 23, lineHeight: 32)
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false, typography: first, immediately: true)
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false, typography: latest, immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("getComputedStyle(document.body).fontSize === '23px'")
        let firstOrigin: Double = try await fixture.value("performance.timeOrigin")
        let _: Bool = try await fixture.value("document.querySelector('article').firstElementChild.dataset.typographyTest = 'kept'; true")
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 16, lineHeight: 22), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.body).fontSize === '16px'")
        let secondOrigin: Double = try await fixture.value("performance.timeOrigin")
        let marker: String = try await fixture.value("document.querySelector('article').firstElementChild.dataset.typographyTest")
        let lineHeight: String = try await fixture.value("getComputedStyle(document.body).lineHeight")
        XCTAssertEqual(firstOrigin, secondOrigin)
        XCTAssertEqual(marker, "kept")
        XCTAssertEqual(lineHeight, "22px")
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 16, lineHeight: 22,
                                                                  textFamily: "Times New Roman", codeFamily: "Menlo"), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.body).fontFamily.includes('Times New Roman') && getComputedStyle(document.querySelector('code')).fontFamily.includes('Menlo')")
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 16, lineHeight: 22, ligatures: 0), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.body).fontVariantLigatures === 'none' && getComputedStyle(document.querySelector('code')).fontVariantLigatures === 'none'")
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 16, lineHeight: 22, smallCapsLevels: [1]), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.querySelector('h1')).fontVariantCaps === 'small-caps'")
        let kept: String = try await fixture.value("document.querySelector('article').firstElementChild.dataset.typographyTest")
        XCTAssertEqual(kept, "kept")
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 16, lineHeight: 22, centeredHeadingLevels: [1], textAlignment: "justify", rightToLeft: true, verticalWriting: true, paragraphSpacing: 12, uppercaseHeadingLevels: [1]), immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.querySelector('article')).textAlign === 'justify' && getComputedStyle(document.querySelector('article')).direction === 'rtl' && getComputedStyle(document.querySelector('article')).writingMode === 'vertical-rl' && getComputedStyle(document.querySelector('p')).marginBlockEnd === '12px' && getComputedStyle(document.querySelector('h1')).textAlign === 'center' && getComputedStyle(document.querySelector('h1')).textTransform === 'uppercase'")
        fixture.coordinator.render(markdown: text, revision: 1, darkMode: false, typography: nil, immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.body).fontSize === '15px'")
        try await fixture.waitUntil("getComputedStyle(document.querySelector('h1')).fontVariantCaps === 'normal'")
        try await fixture.waitUntil("getComputedStyle(document.querySelector('article')).textAlign !== 'justify'")
        try await fixture.waitUntil("getComputedStyle(document.querySelector('article')).direction === 'ltr'")
        try await fixture.waitUntil("getComputedStyle(document.querySelector('article')).writingMode === 'horizontal-tb'")
        try await fixture.waitUntil("getComputedStyle(document.querySelector('h1')).textAlign !== 'center'")
        try await fixture.waitUntil("getComputedStyle(document.querySelector('h1')).textTransform === 'none'")
        let restoredLigatures: String = try await fixture.value("getComputedStyle(document.body).fontVariantLigatures")
        XCTAssertNotEqual(restoredLigatures, "none")
    }

    func testReloadKeepsLatestContentAndScrollWithoutFurtherEdits() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: String(repeating: "段落内容\n\n", count: 300),
                                   revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let time: Double = try await fixture.value("performance.timeOrigin")
        let _: Bool = try await fixture.value("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * .45); true")
        _ = fixture.webView.reload()
        try await fixture.waitUntil("performance.timeOrigin !== \(time)")
        try await fixture.waitForRevision(1)
        let ratio: Double = try await fixture.value("scrollY / (document.documentElement.scrollHeight - innerHeight)")
        XCTAssertEqual(ratio, 0.45, accuracy: 0.025)
        let body: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(body.contains("段落内容"))
    }

    func testHiddenPreviewPausesAndOnlyLatestRevisionIsApplied() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "旧内容", revision: 1, darkMode: false, immediately: true)
        fixture.coordinator.render(markdown: "最新内容", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        fixture.coordinator.setActive(false)
        fixture.coordinator.render(markdown: "隐藏时修改", revision: 3, darkMode: false, immediately: true)
        try await Task.sleep(for: .milliseconds(300))
        let body: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(body.contains("最新内容"))
        XCTAssertFalse(body.contains("隐藏时修改"))
        fixture.coordinator.setActive(true)
        fixture.coordinator.render(markdown: "恢复后的内容", revision: 4, darkMode: false, immediately: true)
        try await fixture.waitForRevision(4)
        let resumed: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(resumed.contains("恢复后的内容"))
    }

    func testStoppingCancelsDeferredRender() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "Исходный текст", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        fixture.coordinator.render(markdown: "Отложенный текст", revision: 2, darkMode: false)
        fixture.coordinator.stop()
        try await Task.sleep(for: .milliseconds(700))
        let body: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(body.contains("Исходный текст"))
        XCTAssertFalse(body.contains("Отложенный текст"))
        fixture.coordinator.render(markdown: "Новый текст", revision: 3, darkMode: false, immediately: true)
        try await fixture.waitForRevision(3)
    }

    func testNewRenderReplacesDeferredRender() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "Исходный текст", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        fixture.coordinator.render(markdown: "Старый текст", revision: 2, darkMode: false)
        fixture.coordinator.render(markdown: "Последний текст", revision: 3, darkMode: false, immediately: true)
        try await fixture.waitForRevision(3)
        try await Task.sleep(for: .milliseconds(700))
        let body: String = try await fixture.value("document.querySelector('article').innerText")
        XCTAssertTrue(body.contains("Последний текст"))
        XCTAssertFalse(body.contains("Старый текст"))
    }

    func testMermaidDiagramsRenderAndThemeChangesKeepSource() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let markdown = """
        ```mermaid
        flowchart LR
          A[Start] --> B[End]
        ```

        ```mermaid
        not a valid diagram
        ```

        ```swift
        let x = 1
        ```
        """
        fixture.coordinator.render(markdown: markdown, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelectorAll('.mermaid-diagram svg').length === 1 && document.querySelectorAll('.mermaid-diagram[role=alert]').length === 1")
        let original: String = try await fixture.value("document.querySelector('code.language-mermaid').textContent")
        XCTAssertTrue(original.contains("flowchart LR"))
        let error: String = try await fixture.value("document.querySelector('.mermaid-diagram[role=alert]').textContent")
        XCTAssertEqual(error, L10n.tr("无法显示 Mermaid 图表"))
        let codeVisible: Bool = try await fixture.value("!document.querySelector('code.language-swift').parentElement.hidden")
        XCTAssertTrue(codeVisible)
        let firstID: String = try await fixture.value("document.querySelector('.mermaid-diagram svg').id")
        fixture.coordinator.render(markdown: markdown, revision: 1, darkMode: true, immediately: true)
        try await fixture.waitUntil("document.documentElement.dataset.theme === 'dark' && document.querySelector('.mermaid-diagram svg')?.id !== '\(firstID)'")
        let retained: String = try await fixture.value("document.querySelector('code.language-mermaid').textContent")
        XCTAssertEqual(retained, original)
        XCTAssertTrue(fixture.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func testMermaidKeepsLatestRevisionAfterHideAndShow() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let first = "```mermaid\nflowchart LR\n  A[Old] --> B[Old end]\n```"
        let latest = "```mermaid\nflowchart LR\n  A[New] --> B[New end]\n```"
        fixture.coordinator.render(markdown: first, revision: 1, darkMode: false, immediately: true)
        fixture.coordinator.render(markdown: latest, revision: 2, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('.mermaid-diagram svg')?.textContent.includes('New end')")
        fixture.coordinator.setActive(false)
        fixture.coordinator.render(markdown: first, revision: 3, darkMode: false, immediately: true)
        try await Task.sleep(for: .milliseconds(300))
        let whileHidden: String = try await fixture.value("document.querySelector('code.language-mermaid').textContent")
        XCTAssertTrue(whileHidden.contains("New end"))
        fixture.coordinator.setActive(true)
        fixture.coordinator.render(markdown: latest, revision: 4, darkMode: true, immediately: true)
        try await fixture.waitUntil("document.documentElement.dataset.revision === '4' && document.querySelector('.mermaid-diagram svg')?.textContent.includes('New end')")
    }

    func testMermaidDiagramCannotOverrideLibraryLimits() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let markdown = """
        ```mermaid
        %%{init: {'maxTextSize': 1, 'maxEdges': 0, 'suppressErrorRendering': false}}%%
        flowchart LR
          A[First] --> B[Second]
        ```
        """
        fixture.coordinator.render(markdown: markdown, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitUntil("document.querySelector('.mermaid-diagram svg')?.textContent.includes('Second')")
        let secured: Bool = try await fixture.value("['maxTextSize', 'maxEdges', 'suppressErrorRendering'].every(k => mermaid.mermaidAPI.getConfig().secure.includes(k))")
        XCTAssertTrue(secured)
    }

    func testFlowAndSequencePreviewRendersAndRejectsStaleResults() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\n```sequence\nAlice->Bob: Hello\n```"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("document.querySelectorAll('[data-lac-diagram] img').length === 2 && Array.from(document.querySelectorAll('[data-lac-diagram] img')).every(i => i.complete && i.naturalWidth > 0)")
        let correct: Bool = try await fixture.value("Array.from(document.querySelectorAll('[data-lac-diagram] img')).every(i => i.src.startsWith('data:image/png;base64,') && i.alt.length > 0)")
        XCTAssertTrue(correct)
        fixture.coordinator.render(markdown: "Latest text", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        let none: Bool = try await fixture.value("document.querySelector('[data-lac-diagram]') === null")
        XCTAssertTrue(none)
    }

    func testColorsUpdateWithoutReloadingOrChangingFontAndResetByAppearance() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "plain [link](https://example.com)", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let origin: Double = try await fixture.value("performance.timeOrigin")
        let font: String = try await fixture.value("getComputedStyle(document.body).font")
        let red = try XCTUnwrap(MarkdownSRGBColor(red: 1, green: 0, blue: 0))
        let blue = try XCTUnwrap(MarkdownSRGBColor(red: 0, green: 0, blue: 1))
        let typography = MarkdownTypography(fontSize: 30, lineHeight: 50, usesCustomFontMetrics: false,
            lightColors: MarkdownColorOverrides(text: red), darkColors: MarkdownColorOverrides(text: blue))
        fixture.coordinator.render(markdown: "plain [link](https://example.com)", revision: 1, darkMode: false, typography: typography, immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.body).color === 'rgb(255, 0, 0)'")
        let updatedFont: String = try await fixture.value("getComputedStyle(document.body).font")
        let updatedOrigin: Double = try await fixture.value("performance.timeOrigin")
        XCTAssertEqual(updatedFont, font)
        XCTAssertEqual(updatedOrigin, origin)
        fixture.coordinator.render(markdown: "plain [link](https://example.com)", revision: 1, darkMode: true, typography: typography, immediately: true)
        try await fixture.waitUntil("getComputedStyle(document.body).color === 'rgb(0, 0, 255)'")
        fixture.coordinator.render(markdown: "plain [link](https://example.com)", revision: 1, darkMode: true, typography: nil, immediately: true)
        try await fixture.waitUntil("document.documentElement.style.getPropertyValue('--text') === ''")
    }

    func testWidthOnlyUpdatesPreviewWithoutChangingFontOrReloading() async throws {
        let fixture = PreviewFixture(width: 1000)
        defer { fixture.dispose() }
        fixture.coordinator.render(markdown: "# Heading\n\nText", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let font: String = try await fixture.value("getComputedStyle(document.body).font")
        let origin: Double = try await fixture.value("performance.timeOrigin")
        let width = MarkdownTypography(fontSize: 30, lineHeight: 50, textFamily: "Menlo", codeFamily: "Menlo",
                                       maximumWidth: 420, usesCustomFontMetrics: false)
        fixture.coordinator.render(markdown: "# Heading\n\nText", revision: 1, darkMode: false, typography: width, immediately: true)
        try await fixture.waitUntil("document.querySelector('article').clientWidth === 420")
        let updatedFont: String = try await fixture.value("getComputedStyle(document.body).font")
        let updatedOrigin: Double = try await fixture.value("performance.timeOrigin")
        XCTAssertEqual(updatedFont, font)
        XCTAssertEqual(updatedOrigin, origin)
        fixture.coordinator.render(markdown: "# Heading\n\nText", revision: 1, darkMode: false, typography: nil, immediately: true)
        try await fixture.waitUntil("document.querySelector('article').clientWidth === 760")
    }

    func testTOCLevelUpdatesWithoutReparseAndKeepsAnchors() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "[toc]\n\n# 中文😀\n\n### Deep\n\n## Second\n\n# 中文😀"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let origin: Double = try await fixture.value("performance.timeOrigin")
        let ids: [String] = try await fixture.value("Array.from(document.querySelectorAll('article span[id]'), e => e.id)")
        let typography = MarkdownTypography(fontSize: 16, lineHeight: 24, usesCustomFontMetrics: false, tocMaxLevel: 1)
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, typography: typography, immediately: true)
        try await fixture.waitUntil("document.querySelectorAll('nav[data-lac-toc] li:not([hidden])').length === 2")
        let hidden: Int = try await fixture.value("document.querySelectorAll('nav[data-lac-toc] li[hidden]').length")
        let after: [String] = try await fixture.value("Array.from(document.querySelectorAll('article span[id]'), e => e.id)")
        let newOrigin: Double = try await fixture.value("performance.timeOrigin")
        XCTAssertEqual(hidden, 2)
        XCTAssertEqual(ids, after)
        XCTAssertEqual(newOrigin, origin)
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, typography: nil, immediately: true)
        try await fixture.waitUntil("document.querySelectorAll('nav[data-lac-toc] li[hidden]').length === 0")
    }

    func testPreviewRendersConfirmedEmojiAndLatestRevision() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "中😀 :smile: \\:heart: `:smile:`\n\n<u>:heart:</u>\n\n| A |\n|---|\n| a\\|b **:heart:** |"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let text: String = try await fixture.value("document.querySelector('article').textContent")
        XCTAssertTrue(text.contains("中😀 😄"))
        XCTAssertTrue(text.contains(":heart:"))
        XCTAssertTrue(text.contains(":smile:"))
        XCTAssertTrue(text.contains("a|b ❤️"))
        let underline: String = try await fixture.value("document.querySelector('u').textContent")
        XCTAssertEqual(underline, "❤️")
        fixture.coordinator.render(markdown: "new :smile:", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        let latest: String = try await fixture.value("document.querySelector('article').textContent")
        XCTAssertTrue(latest.contains("new 😄"))
        XCTAssertFalse(latest.contains("中😀"))
    }

    func testMathPreviewUsesLocalImagesAndLatestRevision() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "Inline $x^2$\n\n$$\n\\frac{a}{b}\n$$"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("document.querySelectorAll('[data-lac-math] img').length === 2 && Array.from(document.querySelectorAll('[data-lac-math] img')).every(i => i.complete && i.naturalWidth > 0)")
        let alt: String = try await fixture.value("document.querySelector('[data-lac-math=\"0\"] img').alt")
        XCTAssertEqual(alt, "$x^2$")
        let local: Bool = try await fixture.value("Array.from(document.querySelectorAll('[data-lac-math] img')).every(i => i.src.startsWith('data:image/png;base64,'))")
        XCTAssertTrue(local)
        let math: Bool = try await fixture.value("(() => { const f=document.querySelector('[data-lac-math=\"1\"]'); return !!f.querySelector('math mfrac') && f.querySelector('img').getAttribute('aria-hidden') !== 'true' && !f.querySelector('math [data-latex], math [href], math script'); })()")
        XCTAssertTrue(math)
        fixture.coordinator.render(markdown: "Latest $z$", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        try await fixture.waitUntil("document.querySelectorAll('[data-lac-math] img').length === 1 && document.querySelector('[data-lac-math] img').alt === '$z$'")
        XCTAssertTrue(fixture.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func testMathPreviewRespondsToArticleWidthAndFontSize() async throws {
        let fixture = PreviewFixture(width: 1000)
        defer { fixture.dispose() }
        let source = "$$\n\\frac{a}{b}\\tag{1}\n$$"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 16, lineHeight: 22), immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("document.querySelector('[data-lac-math] img')?.naturalWidth > 0")
        let wide: String = try await fixture.value("document.querySelector('[data-lac-math] img').src")
        let articleWidth: Double = try await fixture.value("document.querySelector('article').clientWidth")
        XCTAssertLessThanOrEqual(articleWidth, 760)
        fixture.webView.setFrameSize(NSSize(width: 500, height: 500))
        try await fixture.waitUntil("document.querySelector('article').clientWidth < 500 && document.querySelector('[data-lac-math] img')?.src !== \(String(reflecting: wide))")
        let beforeHeight: Double = try await fixture.value("document.querySelector('[data-lac-math] img').naturalHeight")
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false,
                                   typography: MarkdownTypography(fontSize: 32, lineHeight: 44), immediately: true)
        try await fixture.waitUntil("document.querySelector('[data-lac-math] img')?.naturalHeight > \(beforeHeight)")
        let alt: String = try await fixture.value("document.querySelector('[data-lac-math] img').alt")
        XCTAssertTrue(alt.contains("\\frac{a}{b}"))
        let accessible: Bool = try await fixture.value("!!document.querySelector('[data-lac-math] math mfrac') && document.querySelector('[data-lac-math] img').getAttribute('aria-hidden') !== 'true'")
        XCTAssertTrue(accessible)
    }

    func testMathOptionsRefreshPreviewWithoutEditingSource() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        let source = "$$\nx\n$$"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("document.querySelector('[data-lac-math] img')?.naturalWidth > 0")
        let before: String = try await fixture.value("document.querySelector('[data-lac-math] img').src")
        fixture.coordinator.setMathOptions(.init(physics: true, numbering: .all))
        try await fixture.waitUntil("document.querySelector('[data-lac-math] img')?.src !== \(String(reflecting: before))")
        let alt: String = try await fixture.value("document.querySelector('[data-lac-math] img').alt")
        XCTAssertTrue(alt.contains("x"))
        let revision: String = try await fixture.value("document.documentElement.dataset.revision")
        XCTAssertEqual(revision, "1")
    }

    func testMathOptionFailureRestoresSourceInsteadOfOldImage() async throws {
        let fixture = PreviewFixture()
        defer { fixture.dispose() }
        fixture.coordinator.setMathOptions(.init(physics: false, numbering: .none))
        fixture.coordinator.render(markdown: "$\\dv$", revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("document.querySelector('[data-lac-math] img')?.naturalWidth > 0")
        fixture.coordinator.setMathOptions(.init(physics: true, numbering: .none))
        try await fixture.waitUntil("document.querySelector('[data-lac-math]') && !document.querySelector('[data-lac-math] img')")
        let text: String = try await fixture.value("document.querySelector('[data-lac-math]').textContent")
        XCTAssertEqual(text, "$\\dv$")
    }

    func testMathReferenceScrollsToTargetAndSurvivesResize() async throws {
        let fixture = PreviewFixture(width: 500)
        defer { fixture.dispose() }
        let source = "$$\n\\ref{eq:a}\\tag{ref}\n$$\n\n" + String(repeating: "paragraph\n\n", count: 80) + "$$\nx\\tag{1}\\label{eq:a}\n$$"
        fixture.coordinator.render(markdown: source, revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        try await fixture.waitUntil("document.querySelector('[data-lac-math=\"0\"] button') !== null")
        let label: String = try await fixture.value("document.querySelector('[data-lac-math=\"0\"] button').getAttribute('aria-label')")
        XCTAssertTrue(label.contains("\\label{eq:a}"))
        let valid: Bool = try await fixture.value("(() => { const b=document.querySelector('[data-lac-math=\"0\"] button').getBoundingClientRect(); const i=document.querySelector('[data-lac-math=\"0\"] img').getBoundingClientRect(); return b.width>0 && b.height>0 && b.left>=i.left && b.right<=i.right && b.top>=i.top && b.bottom<=i.bottom; })()")
        XCTAssertTrue(valid)
        let _: Bool = try await fixture.value("document.querySelector('[data-lac-math=\"0\"] button').click(); true")
        try await fixture.waitUntil("(() => { const r=document.querySelector('[data-lac-math=\"1\"]').getBoundingClientRect(); return r.top < innerHeight && r.bottom > 0; })()")
        let previous: String = try await fixture.value("document.querySelector('[data-lac-math=\"0\"] img').src")
        fixture.webView.setFrameSize(NSSize(width: 350, height: 500))
        try await fixture.waitUntil("document.querySelector('[data-lac-math=\"0\"] button') !== null && document.querySelector('[data-lac-math=\"0\"] img').src !== \(String(reflecting: previous))")
        fixture.coordinator.render(markdown: "No formulas", revision: 2, darkMode: false, immediately: true)
        try await fixture.waitForRevision(2)
        let noOldButtons: Bool = try await fixture.value("document.querySelector('[data-lac-math] button') === null")
        XCTAssertTrue(noOldButtons)
    }

    func testNarrowPreviewContainsWideTablesAndCode() async throws {
        let fixture = PreviewFixture(width: 240)
        defer { fixture.dispose() }
        let columns = (1...12).map { "列\($0)" }.joined(separator: " | ")
        let separator = Array(repeating: "---", count: 12).joined(separator: " | ")
        let row = Array(repeating: "字段内容", count: 12).joined(separator: " | ")
        fixture.coordinator.render(markdown: "# 中文与 English\n\n| \(columns) |\n| \(separator) |\n| \(row) |\n\n```\n\(String(repeating: "long_code_", count: 100))\n```\n\n- 一级\n  - 二级\n    - 三级",
                                   revision: 1, darkMode: false, immediately: true)
        try await fixture.waitForRevision(1)
        let pageFits: Bool = try await fixture.value("document.documentElement.scrollWidth <= innerWidth + 1")
        let tableScrolls: Bool = try await fixture.value("document.querySelector('.table-scroll').scrollWidth > document.querySelector('.table-scroll').clientWidth")
        let codeScrolls: Bool = try await fixture.value("document.querySelector('pre').scrollWidth > document.querySelector('pre').clientWidth")
        let nested: String = try await fixture.value("getComputedStyle(document.querySelector('ul ul ul')).listStyleType")
        XCTAssertTrue(pageFits)
        XCTAssertTrue(tableScrolls)
        XCTAssertTrue(codeScrolls)
        XCTAssertEqual(nested, "square")
    }
}

private final class RenderGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var active = 0
    private var peak = 0

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recordedCalls }
    var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return peak }

    func render(_ text: String, darkMode: Bool, started: XCTestExpectation) -> MarkdownRenderedPage {
        lock.lock()
        recordedCalls.append(text)
        active += 1
        peak = max(peak, active)
        lock.unlock()
        if text == "first" {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        lock.lock()
        active -= 1
        lock.unlock()
        return MarkdownRenderedPage(body: text, darkMode: darkMode)
    }
}

@MainActor
private final class PreviewFixture {
    let document = EditorDocument(text: "", language: .markdown)
    let coordinator: MarkdownPreview.Coordinator
    let webView: MarkdownWebView
    let window: NSWindow

    init(width: CGFloat = 480, imageSession: URLSession = .shared) {
        _ = NSApplication.shared
        coordinator = MarkdownPreview.Coordinator(document: document, imageSession: imageSession)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        MarkdownPreview.configureLinkRouting(config, coordinator: coordinator)
        webView = MarkdownWebView(frame: NSRect(x: 0, y: 0, width: width, height: 500), configuration: config)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        webView.reloadRenderedContent = { [weak coordinator, weak webView] in
            guard let coordinator, let webView else { return }
            coordinator.reloadLastRenderedHTML(in: webView)
        }
        window.orderFront(nil)
    }

    func value<T>(_ script: String) async throws -> T {
        let value = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(value as? T, "Unexpected JavaScript result for \(script)")
    }

    func waitForRevision(_ revision: UInt) async throws {
        try await waitUntil("document.documentElement.dataset.revision === '\(revision)'")
    }

    func waitUntil(_ condition: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ready: Bool = try? await value(condition), ready { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Preview did not become ready: \(condition)")
        throw NSError(domain: "PreviewFixture", code: 1)
    }

    func dispose() {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lacLink", contentWorld: .defaultClient)
        webView.reloadRenderedContent = nil
        window.contentView = nil
        window.close()
    }
}
