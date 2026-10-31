import AppKit
import Network
import XCTest
@testable import LacEditor

private final class MarkdownDisplayURLProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var chunks: [Data] = []
        var headers: [String: String] = [:]
        var omitContentLength = false
        var hold = false
    }

    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) -> Stub)?
    static var stopped: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let stub = Self.handler?(request) else { return }
        if stub.hold { return }
        var headers = stub.headers
        if !stub.omitContentLength { headers["Content-Length"] = String(stub.chunks.reduce(0) { $0 + $1.count }) }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.stopped?() }
}

private final class MarkdownResolverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return hosts }
    func append(_ host: String) { lock.lock(); hosts.append(host); lock.unlock() }
}

private final class MarkdownRTFRequestServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "MarkdownRemoteImageDownloaderTests.rtf")
    private let lock = NSLock()
    private var count = 0

    init(ready: XCTestExpectation) throws {
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

    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] part, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = data
            if let part { request.append(part) }
            guard String(data: request, encoding: .utf8)?.contains("\r\n\r\n") == true else {
                if complete { connection.cancel() } else { self.receive(connection, data: request) }
                return
            }
            self.lock.lock(); self.count += 1; self.lock.unlock()
            let body = Data("not an image".utf8)
            let response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
final class MarkdownRemoteImageDownloaderTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    override func setUp() {
        super.setUp()
        MarkdownDisplayURLProtocol.requests = []
        MarkdownDisplayURLProtocol.handler = nil
        MarkdownDisplayURLProtocol.stopped = nil
    }

    override func tearDown() {
        MarkdownDisplayURLProtocol.requests = []
        MarkdownDisplayURLProtocol.handler = nil
        MarkdownDisplayURLProtocol.stopped = nil
        super.tearDown()
    }

    private func makeDownloader(limits: MarkdownRemoteImageDownloader.Limits = .init(), resolver: @escaping MarkdownRemoteImageDownloader.AddressResolver = { _ in ["8.8.8.8"] }) -> (MarkdownRemoteImageDownloader, URLSession) {
        let session = MarkdownRemoteImageDownloader.makeSession(protocolClasses: [MarkdownDisplayURLProtocol.self])
        return (MarkdownRemoteImageDownloader(session: session, limits: limits, resolver: resolver), session)
    }

    func testEphemeralConfigurationAndCookiesAreNotSent() async throws {
        let (downloader, session) = makeDownloader()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "secret", .domain: "example.invalid", .path: "/"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [self.png], headers: ["Content-Type": "image/png"]) }
        _ = try await downloader.download(URL(string: "https://example.invalid/image.png")!)
        let request = try XCTUnwrap(MarkdownDisplayURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testChunkedResponseUsesActualMIME() async throws {
        let (downloader, session) = makeDownloader()
        defer { session.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in
            .init(chunks: [Data(self.png.prefix(7)), Data(self.png.dropFirst(7))], headers: ["Content-Type": "text/plain"])
        }
        let payload = try await downloader.download(URL(string: "https://example.invalid/chunked.png")!)
        XCTAssertEqual(payload.data, png)
        XCTAssertEqual(payload.mime, "image/png")
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [Data("not an image".utf8)], headers: ["Content-Type": "image/png"]) }
        do {
            _ = try await downloader.download(URL(string: "https://example.invalid/fake.png")!)
            XCTFail("Expected actual MIME rejection")
        } catch MarkdownRemoteImageDownloader.DownloadError.invalidImage {}
    }

    func testChunkedUnknownLengthStreamsWithinLimits() async throws {
        let (downloader, session) = makeDownloader()
        defer { session.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in
            .init(chunks: [Data(self.png.prefix(3)), Data(self.png.dropFirst(3))], headers: ["Content-Type": "image/png"], omitContentLength: true)
        }
        let payload = try await downloader.download(URL(string: "https://example.invalid/unknown-length.png")!)
        XCTAssertEqual(payload.data, png)
        XCTAssertEqual(MarkdownDisplayURLProtocol.requests.count, 1)
    }

    func testPerImageLimitStopsChunkedBody() async throws {
        let (downloader, session) = makeDownloader(limits: .init(maximumImageBytes: 8, maximumBatchBytes: 1024, maximumImages: 2))
        defer { session.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [Data(self.png.prefix(4)), Data(self.png.dropFirst(4))]) }
        do {
            _ = try await downloader.download(URL(string: "https://example.invalid/large.png")!)
            XCTFail("Expected per-image limit")
        } catch MarkdownRemoteImageDownloader.DownloadError.limit {}
        XCTAssertEqual(MarkdownDisplayURLProtocol.requests.count, 1)
    }

    func testBatchByteAndImageLimits() async throws {
        let byteLimits = MarkdownRemoteImageDownloader.Limits(maximumImageBytes: 1024, maximumBatchBytes: png.count * 2, maximumImages: 10)
        let (byteDownloader, byteSession) = makeDownloader(limits: byteLimits)
        defer { byteSession.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [self.png]) }
        let addresses = (0..<3).map { "https://example.invalid/\($0).png" }
        let values = try await byteDownloader.dataURIs(for: addresses)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(MarkdownDisplayURLProtocol.requests.count, 3)

        MarkdownDisplayURLProtocol.requests = []
        let countLimits = MarkdownRemoteImageDownloader.Limits(maximumImageBytes: 1024, maximumBatchBytes: 4096, maximumImages: 2)
        let (countDownloader, countSession) = makeDownloader(limits: countLimits)
        defer { countSession.invalidateAndCancel() }
        let limited = try await countDownloader.dataURIs(for: addresses)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(MarkdownDisplayURLProtocol.requests.count, 2)
    }

    func testRedirectIsNotFollowed() async throws {
        let (downloader, session) = makeDownloader()
        defer { session.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { request in
            if request.url?.path == "/redirect" {
                return .init(status: 302, headers: ["Location": "https://example.invalid/final.png"])
            }
            return .init(chunks: [self.png])
        }
        do {
            _ = try await downloader.download(URL(string: "https://example.invalid/redirect")!)
            XCTFail("Expected redirect rejection")
        } catch {}
        XCTAssertEqual(MarkdownDisplayURLProtocol.requests.map { $0.url?.path }, ["/redirect"])
    }

    func testObviousPrivateAddressesMakeNoRequests() async throws {
        let (downloader, session) = makeDownloader()
        defer { session.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [self.png]) }
        let addresses = [
            "http://127.0.0.1/image.png", "http://localhost/image.png", "http://10.0.0.1/image.png",
            "http://172.16.0.1/image.png", "http://192.168.1.1/image.png", "http://169.254.169.254/image.png",
            "http://100.64.0.1/image.png", "http://[::1]/image.png", "http://[fc00::1]/image.png",
            "http://[fe80::1]/image.png", "http://[::ffff:127.0.0.1]/image.png"
        ]
        for address in addresses {
            do {
                _ = try await downloader.download(URL(string: address)!)
                XCTFail("Expected private address rejection: \(address)")
            } catch MarkdownRemoteImageDownloader.DownloadError.blockedAddress {}
        }
        XCTAssertTrue(MarkdownDisplayURLProtocol.requests.isEmpty)
        XCTAssertNoThrow(try MarkdownRemoteImageDownloader.validate(URL(string: "https://8.8.8.8/image.png")!))
    }

    func testHostnameResolutionRejectsAnyPrivateResultBeforeRequest() async throws {
        let recorder = MarkdownResolverRecorder()
        let (downloader, session) = makeDownloader(resolver: { host in
            recorder.append(host)
            return ["8.8.8.8", "10.0.0.1", "fd00::1"]
        })
        defer { session.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [self.png]) }
        do {
            _ = try await downloader.download(URL(string: "https://mixed.example/image.png")!)
            XCTFail("Expected private resolved address rejection")
        } catch MarkdownRemoteImageDownloader.DownloadError.blockedAddress {}
        XCTAssertEqual(recorder.values, ["mixed.example"])
        XCTAssertTrue(MarkdownDisplayURLProtocol.requests.isEmpty)
    }

    func testHostnameResolutionFailureMakesNoRequestAndPublicResultProceeds() async throws {
        let (blocked, blockedSession) = makeDownloader(resolver: { _ in [] })
        defer { blockedSession.invalidateAndCancel() }
        do {
            _ = try await blocked.download(URL(string: "https://unresolved.example/image.png")!)
            XCTFail("Expected resolution failure")
        } catch MarkdownRemoteImageDownloader.DownloadError.response {}
        XCTAssertTrue(MarkdownDisplayURLProtocol.requests.isEmpty)

        let (allowed, allowedSession) = makeDownloader(resolver: { _ in ["8.8.8.8", "2606:4700:4700::1111"] })
        defer { allowedSession.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [self.png]) }
        let payload = try await allowed.download(URL(string: "https://public.example/image.png")!)
        XCTAssertEqual(payload.data, png)
        XCTAssertEqual(MarkdownDisplayURLProtocol.requests.count, 1)
    }

    func testCancellationStopsStreamingRequest() async throws {
        let (downloader, session) = makeDownloader()
        defer { session.invalidateAndCancel() }
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request stopped")
        MarkdownDisplayURLProtocol.handler = { _ in
            started.fulfill()
            return .init(hold: true)
        }
        MarkdownDisplayURLProtocol.stopped = { stopped.fulfill() }
        let task = Task { try await downloader.download(URL(string: "https://example.invalid/held.png")!) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 5)
        let result = await task.result
        guard case .failure = result else { return XCTFail("Expected cancellation") }
    }

    func testRichCopyMixedImageAndRemoteMediaMakesNoRTFRequestsWithConsent() async throws {
        _ = NSApplication.shared
        let ready = expectation(description: "mixed RTF listener ready")
        let server = try MarkdownRTFRequestServer(ready: ready)
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 10)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let source = "![alt](https://8.8.8.8/image.png) <audio src='http://127.0.0.1:\(port)/private.wav'>fallback</audio>"
        let document = EditorDocument(text: source, language: .markdown)
        document.allowsRemoteImages = true
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MarkdownDisplayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        coordinator.clipboardCopySession = session
        defer { session.invalidateAndCancel() }
        MarkdownDisplayURLProtocol.handler = { _ in .init(chunks: [self.png], headers: ["Content-Type": "image/png"]) }
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<500 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(board.string(forType: .string), "old")
        XCTAssertTrue(board.string(forType: .html)?.contains("data:image/png;base64,") == true)
        XCTAssertNil(board.data(forType: .rtf))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.requests, 0)
    }

    func testRichCopyWithoutConsentMakesNoDownloaderOrRTFRequests() async throws {
        _ = NSApplication.shared
        let ready = expectation(description: "RTF listener ready")
        let server = try MarkdownRTFRequestServer(ready: ready)
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 10)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let source = "![alt](http://127.0.0.1:\(port)/private.png)"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        board.clearContents()
        board.setString("old", forType: .string)
        view.copy(nil)
        for _ in 0..<500 where board.string(forType: .string) == "old" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(board.string(forType: .string), "alt")
        XCTAssertTrue(board.string(forType: .html)?.contains("http://127.0.0.1:\(port)/private.png") == true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.requests, 0)
    }

    func testConsentIsPerDocumentAndOffByDefault() {
        let first = EditorDocument(text: "![x](https://example.invalid/x.png)", language: .markdown)
        let second = EditorDocument(text: first.text, language: .markdown)
        XCTAssertFalse(first.allowsRemoteImages)
        XCTAssertFalse(second.allowsRemoteImages)
        first.allowsRemoteImages = true
        XCTAssertFalse(second.allowsRemoteImages)
        let restored = EditorDocument(id: first.id, text: first.text, language: .markdown)
        XCTAssertFalse(restored.allowsRemoteImages)
    }
}
