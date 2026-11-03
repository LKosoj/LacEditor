import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LacEditor

/// Заглушка сети: обработчик возвращает (код, заголовки, тело) или бросает ошибку; запросы складываются в массив.
final class VaultStubProtocol: URLProtocol {
    typealias Response = (status: Int, headers: [String: String], body: Data)
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Response)?
    nonisolated(unsafe) private static var recorded: [(request: URLRequest, body: Data)] = []
    private static let lock = NSLock()

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.request) }
    static var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.body) }

    static func reset() {
        lock.lock()
        recorded = []
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.recorded.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let result = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers)!
            if (300..<400).contains(result.status), let location = result.headers["Location"], let target = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class VaultClientTests: XCTestCase {
    private let token = "test-token"
    private let base = URL(string: "http://127.0.0.1:8765")!

    override func setUp() {
        super.setUp()
        VaultStubProtocol.reset()
    }

    override func tearDown() {
        VaultStubProtocol.reset()
        super.tearDown()
    }

    private func makeClient(_ url: URL? = nil) -> VaultClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VaultStubProtocol.self]
        return VaultClient(baseURL: url ?? base, token: token, session: URLSession(configuration: configuration))
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func reply(_ status: Int = 200, _ object: Any = [String: Any](), headers: [String: String] = [:]) {
        VaultStubProtocol.handler = { _ in (status, headers, self.json(object)) }
    }

    private func assertThrows<T>(_ expected: VaultClientError, _ block: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await block()
            XCTFail("ожидалась ошибка \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VaultClientError, expected, file: file, line: line)
        }
    }

    private let etagA = String(repeating: "a", count: 64)

    // MARK: health, tree

    func testHealthSendsNoAuthorizationAndAcceptsOK() async throws {
        reply(200, ["status": "ok"])
        try await makeClient().health()
        let request = try XCTUnwrap(VaultStubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/healthz")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        reply(200, ["status": "bad"])
        await assertThrows(.invalidResponse) { try await self.makeClient().health() }
    }

    func testTreeParsesOldAndNewResponses() async throws {
        let entry: [String: Any] = ["path": "daily", "name": "daily", "kind": "directory", "size": 0, "mtime_ns": 1_793_369_100_123_456_789]
        reply(200, ["entries": [entry], "next_page_token": NSNull()])
        let old = try await makeClient().tree(path: "", depth: 0, pageSize: 10, pageToken: nil)
        XCTAssertNil(old.listingComplete)
        XCTAssertNil(old.nextPageToken)
        XCTAssertEqual(old.entries.first?.mtimeNs, 1_793_369_100_123_456_789)
        XCTAssertEqual(old.entries.first?.kind, .directory)
        reply(200, ["entries": [entry], "next_page_token": "t1", "listing_complete": false])
        let page = try await makeClient().tree(path: "daily", depth: 1, pageSize: 10, pageToken: "t0")
        XCTAssertEqual(page.listingComplete, false)
        XCTAssertEqual(page.nextPageToken, "t1")
        reply(200, ["entries": [], "listing_complete": true])
        let last = try await makeClient().tree(path: "", depth: 0, pageSize: 10, pageToken: nil)
        XCTAssertEqual(last.listingComplete, true)
        let request = try XCTUnwrap(VaultStubProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testQueryEncodingKeepsPathIntact() async throws {
        reply(200, ["entries": []])
        let path = "a b+c&d/ё#.md"
        _ = try await makeClient().tree(path: path, depth: 1, pageSize: 5, pageToken: nil)
        _ = try await makeClient().tree(path: "", depth: 0, pageSize: 5, pageToken: nil)
        let first = try XCTUnwrap(VaultStubProtocol.requests.first?.url?.absoluteString)
        XCTAssertTrue(first.contains("path=a%20b%2Bc%26d/%D1%91%23.md&depth=1&page_size=5"), first)
        XCTAssertFalse(first.contains("page_token"))
        let second = try XCTUnwrap(VaultStubProtocol.requests.last?.url?.absoluteString)
        XCTAssertTrue(second.contains("?path=&depth=0"), second)
        XCTAssertEqual(VaultClient.encode(path).removingPercentEncoding, path)
    }

    func testTreeStatusMapping() async throws {
        let client = makeClient()
        reply(409, ["error": "listing changed"])
        await assertThrows(.listingChanged) { try await client.tree(path: "", depth: 0, pageSize: 1, pageToken: nil) }
        reply(401)
        await assertThrows(.unauthorized) { try await client.tree(path: "", depth: 0, pageSize: 1, pageToken: nil) }
        reply(403)
        await assertThrows(.forbidden) { try await client.tree(path: "", depth: 0, pageSize: 1, pageToken: nil) }
        reply(404)
        await assertThrows(.notFound) { try await client.tree(path: "", depth: 0, pageSize: 1, pageToken: nil) }
        reply(500, ["error": "boom"])
        await assertThrows(.server(status: 500, message: "boom")) { try await client.tree(path: "", depth: 0, pageSize: 1, pageToken: nil) }
        reply(503, ["error": "busy"])
        await assertThrows(.server(status: 503, message: "busy")) { try await client.tree(path: "", depth: 0, pageSize: 1, pageToken: nil) }
    }

    // MARK: file

    private func fileReply(_ body: Data, etag: String? = nil, length: Int? = nil, modified: String? = "123", sendLength: Bool = true) {
        var headers: [String: String] = [:]
        if let length { headers["Content-Length"] = String(length) } else if sendLength { headers["Content-Length"] = String(body.count) }
        headers["ETag"] = "\"\((etag ?? VaultClient.sha256Hex(body)).uppercased())\""
        if let modified { headers["X-File-Modified-Ns"] = modified }
        VaultStubProtocol.handler = { _ in (200, headers, body) }
    }

    func testFileVerifiesLengthAndChecksum() async throws {
        let body = Data("# Заметка\n".utf8)
        fileReply(body)
        let file = try await makeClient().file(path: "daily/a.md")
        XCTAssertEqual(file.data, body)
        XCTAssertEqual(file.etag, VaultClient.sha256Hex(body))
        XCTAssertEqual(file.modifiedNs, 123)
        let request = try XCTUnwrap(VaultStubProtocol.requests.first)
        XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testFileWithWrongETagIsIncomplete() async {
        fileReply(Data("text".utf8), etag: etagA)
        await assertThrows(.incompleteResponse) { try await self.makeClient().file(path: "a.md") }
    }

    func testFileTruncatedBodyIsIncomplete() async {
        let body = Data(repeating: 0x61, count: 50)
        fileReply(body, etag: VaultClient.sha256Hex(Data(repeating: 0x61, count: 100)), length: 100)
        await assertThrows(.incompleteResponse) { try await self.makeClient().file(path: "a.md") }
        VaultStubProtocol.handler = { _ in (200, ["Content-Length": "50"], body) }
        await assertThrows(.invalidResponse) { try await self.makeClient().file(path: "a.md") }
    }

    func testFileWithoutContentLengthChecksOnlySHA() async throws {
        let body = Data("без длины".utf8)
        fileReply(body, sendLength: false)
        let file = try await makeClient().file(path: "a.md")
        XCTAssertEqual(file.data, body)
        fileReply(body, etag: etagA, sendLength: false)
        await assertThrows(.incompleteResponse) { try await self.makeClient().file(path: "a.md") }
    }

    func testIDsAreEncodedAsOnePathComponent() async throws {
        XCTAssertEqual(VaultClient.encodeComponent("a/b c"), "a%2Fb%20c")
        XCTAssertEqual(VaultClient.encodeComponent("."), "%2E")
        XCTAssertEqual(VaultClient.encodeComponent(".."), "%2E%2E")
        XCTAssertEqual(VaultClient.encodeComponent("a.b"), "a.b")
        reply(200, ["status": "ok"])
        _ = try? await makeClient().resolveConflict(id: "x/../y", decision: "keep")
        XCTAssertEqual(VaultStubProtocol.requests.last?.url?.path.contains("/conflicts/x%2F"), true)
    }

    func testDescriptionHasNoPathOrCredentials() {
        let text = String(describing: makeClient(URL(string: "https://vault.example.com:8443/")))
        XCTAssertEqual(text, "VaultClient(https://vault.example.com:8443)")
        XCTAssertFalse(text.contains("token"))
    }

    // MARK: put, resolve

    func testPutSendsConditionalHeaders() async throws {
        let body = Data([0x41, 0x00, 0xC3, 0xA9])
        reply(200, ["etag": etagA.uppercased(), "path": "a.md"])
        let result = try await makeClient().put(path: "a.md", data: body, ifMatch: etagA)
        XCTAssertEqual(result, .saved(etag: etagA))
        let request = try XCTUnwrap(VaultStubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"\(etagA)\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Content-SHA256"), VaultClient.sha256Hex(body))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(VaultStubProtocol.bodies.first, body)
        reply(200, ["etag": etagA])
        _ = try await makeClient().put(path: "a.md", data: body, ifMatch: "\"\(etagA)\"")
        XCTAssertEqual(VaultStubProtocol.requests.last?.value(forHTTPHeaderField: "If-Match"), "\"\(etagA)\"")
    }

    func testPutStatusMapping() async throws {
        let client = makeClient()
        let data = Data("x".utf8)
        reply(409, ["error": "conflict", "conflict_id": "c1", "current_etag": etagA])
        let conflict = try await client.put(path: "a.md", data: data, ifMatch: etagA)
        XCTAssertEqual(conflict, .conflict(conflictID: "c1", currentETag: etagA))
        reply(409, ["error": "conflict"])
        await assertThrows(.invalidResponse) { try await client.put(path: "a.md", data: data, ifMatch: self.etagA) }
        reply(413)
        await assertThrows(.tooLarge) { try await client.put(path: "a.md", data: data, ifMatch: self.etagA) }
        reply(422, ["error": "owner notes only", "reason": "outside_owner_notes"])
        await assertThrows(.ownerNotesOnly(reason: "outside_owner_notes")) { try await client.put(path: "a.md", data: data, ifMatch: self.etagA) }
        reply(428)
        await assertThrows(.preconditionRequired) { try await client.put(path: "a.md", data: data, ifMatch: self.etagA) }
        reply(400, ["error": "body checksum mismatch"])
        await assertThrows(.incompleteResponse) { try await client.put(path: "a.md", data: data, ifMatch: self.etagA) }
        reply(400, ["error": "incomplete request body"])
        await assertThrows(.incompleteResponse) { try await client.put(path: "a.md", data: data, ifMatch: self.etagA) }
        reply(400, ["error": "bad path"])
        await assertThrows(.server(status: 400, message: "bad path")) { try await client.put(path: "a.md", data: data, ifMatch: self.etagA) }
    }

    func testResolveConflict() async throws {
        let client = makeClient()
        reply(200, ["status": "replaced"])
        try await client.resolveConflict(id: "c 1", decision: "replace")
        let request = try XCTUnwrap(VaultStubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.absoluteString.hasSuffix("/v1/vault/conflicts/c%201/resolve") == true)
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(VaultStubProtocol.bodies.first)) as? [String: String]
        XCTAssertEqual(sent, ["decision": "replace"])
        reply(409, ["error": "conflict already resolved"])
        await assertThrows(.server(status: 409, message: "conflict already resolved")) { try await client.resolveConflict(id: "c1", decision: "cancel") }
        reply(404)
        await assertThrows(.notFound) { try await client.resolveConflict(id: "c1", decision: "cancel") }
    }

    // MARK: search, задачи

    func testSearchParsesHitsAndMapsUnavailable() async throws {
        let client = makeClient()
        reply(200, ["results": [["path": "a.md", "title": NSNull(), "snippet": "фрагмент"], ["path": "b.md", "title": "B"]]])
        let hits = try await client.search(query: "проект НПД")
        XCTAssertEqual(hits.count, 2)
        XCTAssertNil(hits[0].title)
        XCTAssertEqual(hits[0].snippet, "фрагмент")
        XCTAssertNil(hits[1].score)
        reply(503)
        await assertThrows(.searchUnavailable) { try await client.search(query: "x") }
    }

    func testSubmitAndJob() async throws {
        let client = makeClient()
        reply(202, ["job_id": "j1", "request_id": "r1", "status": "queued"])
        let jobID = try await client.submitRequest(requestID: "r1", text: "Что нового?")
        XCTAssertEqual(jobID, "j1")
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(VaultStubProtocol.bodies.first)) as? [String: String]
        XCTAssertEqual(sent, ["request_id": "r1", "text": "Что нового?", "client": "laceditor"])
        reply(200, ["status": "queued"])
        let queued = try await client.job(id: "j1")
        XCTAssertEqual(queued.state, .queued)
        reply(200, ["status": "completed", "result": ["report": "Готово", "artifacts": [
            ["id": "artifact-0", "name": "plan.md", "mime_type": "text/markdown", "download_url": "/v1/jobs/j1/artifacts/artifact-0"]]]])
        let done = try await client.job(id: "j1")
        XCTAssertEqual(done.state, .completed)
        XCTAssertEqual(done.report, "Готово")
        XCTAssertEqual(done.artifacts, ["/v1/jobs/j1/artifacts/artifact-0"])
        XCTAssertEqual(done.artifactItems.first?.name, "plan.md")
        reply(200, ["status": "failed", "error": "interrupted", "retryable": false])
        let interrupted = try await client.job(id: "j1")
        XCTAssertEqual(interrupted.state, .failed)
        XCTAssertEqual(interrupted.error, "interrupted")
        XCTAssertEqual(interrupted.retryable, false)
        reply(200, ["status": "failed", "result": ["error": "boom"]])
        let nested = try await client.job(id: "j1")
        XCTAssertEqual(nested.error, "boom")
        reply(200, ["status": "weird"])
        await assertThrows(.invalidResponse) { try await client.job(id: "j1") }
        reply(404)
        await assertThrows(.notFound) { try await client.job(id: "j1") }
        reply(409, ["error": "request_id reused with different text"])
        await assertThrows(.server(status: 409, message: "request_id reused with different text")) {
            try await client.submitRequest(requestID: "r1", text: "другое")
        }
    }

    // MARK: Безопасность и транспорт

    func testRedirectIsNotFollowed() async {
        // corelibs на Linux падает с fatalError при перенаправлении через URLProtocol: там проверяется только разбор кода 302.
        #if os(Linux)
        let headers: [String: String] = [:]
        #else
        let headers = ["Location": "http://evil.example/"]
        #endif
        VaultStubProtocol.handler = { _ in (302, headers, Data()) }
        await assertThrows(.server(status: 302, message: nil)) { try await self.makeClient().tree(path: "", depth: 0, pageSize: 1, pageToken: nil) }
        XCTAssertEqual(VaultStubProtocol.requests.count, 1)
        XCTAssertNotEqual(VaultStubProtocol.requests.last?.url?.host, "evil.example")
    }

    func testHTTPToNonLoopbackIsRejectedBeforeAnyRequest() async throws {
        let rejected = ["http://example.com", "http://192.168.1.5:8765", "http://127.0.0.1.evil.com", "http://user:pw@127.0.0.1", "ftp://127.0.0.1",
                        "http://localhost.", "http://[::ffff:127.0.0.1]:8765", "http://127.0.0.2:8765"]
        for text in rejected {
            reply(200, ["status": "ok"])
            await assertThrows(.insecureAddress) { try await self.makeClient(URL(string: text)).health() }
        }
        XCTAssertTrue(VaultStubProtocol.requests.isEmpty)
        for text in ["http://127.0.0.1:8765", "http://localhost:8765", "HTTP://LOCALHOST:8765", "http://[::1]:8765", "https://example.com"] {
            reply(200, ["status": "ok"])
            try await makeClient(URL(string: text)).health()
        }
        XCTAssertEqual(VaultStubProtocol.requests.count, 5)
    }

    func testTLSErrorsHaveOwnMessage() async {
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate] {
            VaultStubProtocol.handler = { _ in throw URLError(code) }
            await assertThrows(.secureConnectionFailed) { try await self.makeClient().health() }
        }
    }

    func testTransportErrorsMapping() async {
        let cases: [(URLError.Code, VaultClientError?)] = [(.timedOut, .timeout), (.notConnectedToInternet, .offline),
                                                           (.cannotConnectToHost, .offline), (.networkConnectionLost, .offline),
                                                           (.cancelled, nil)]
        for (code, expected) in cases {
            VaultStubProtocol.handler = { _ in throw URLError(code) }
            do {
                try await makeClient().health()
                XCTFail("ожидалась ошибка")
            } catch {
                if let expected { XCTAssertEqual(error as? VaultClientError, expected) } else { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    func testUserMessagesUseCatalog() {
        let expected: [(VaultClientError, String)] = [
            (.offline, "服务器没有响应"), (.timeout, "服务器响应超时"), (.unauthorized, "服务器不接受令牌"),
            (.forbidden, "服务器不允许访问此文件"), (.notFound, "文件已在服务器上删除"), (.tooLarge, "文件超过 16 MiB，服务器不接受"),
            (.preconditionRequired, "未能发送，请重试"), (.ownerNotesOnly(reason: nil), "服务器不接受“Owner Notes”分区之外的修改"),
            (.listingChanged, "服务器上的笔记列表已变化，请重试"), (.searchUnavailable, "服务器搜索不可用"),
            (.incompleteResponse, "服务器的响应不完整，请重试"), (.invalidResponse, "无法识别服务器的响应"),
            (.secureConnectionFailed, "无法与服务器建立安全连接"),
            (.insecureAddress, "未加密的 http:// 只能用于 127.0.0.1 或 localhost，其他地址请使用 https://")]
        for (error, key) in expected {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertEqual(error.userMessage, L10n.tr(key))
            XCTAssertEqual(error.errorDescription, error.userMessage)
        }
        XCTAssertTrue(VaultClientError.server(status: 502, message: "secret path").userMessage.contains("502"))
        XCTAssertFalse(VaultClientError.server(status: 502, message: "secret path").userMessage.contains("secret"))
    }

    func testClientDescriptionDoesNotLeakToken() {
        let client = makeClient()
        XCTAssertFalse(String(describing: client).contains(token))
        XCTAssertFalse(client.debugDescription.contains(token))
        XCTAssertFalse("\(client)".contains(token))
    }

    func testEtagParsing() {
        XCTAssertEqual(VaultAPIParser.etag(fromHeader: "\"\(etagA.uppercased())\""), etagA)
        XCTAssertNil(VaultAPIParser.etag(fromHeader: "\"abc\""))
        XCTAssertNil(VaultAPIParser.etag(fromHeader: nil))
    }
}
