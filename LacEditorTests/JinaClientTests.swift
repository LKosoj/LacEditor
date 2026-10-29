import Foundation
import XCTest
@testable import LacEditor

private final class JinaTestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class JinaClientTests: XCTestCase {
    private func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testSearchAndReadUseConfiguredEndpoints() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [JinaTestProtocol.self]
        let client = JinaClient(session: URLSession(configuration: sessionConfig))
        var config = JinaConfiguration()
        config.searchEnabled = true
        config.readerEnabled = true
        config.searchEndpoint = "https://custom.example/find"
        config.readerEndpoint = "https://custom.example/read"
        JinaTestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.body(request)) as? [String: String])
            if request.url?.path == "/find" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer search-key")
                XCTAssertEqual(body["q"], "claim")
                return (200, Data(#"{"data":[{"title":"Page","url":"https://example.org/a","description":"snippet"}]}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/read")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(body["url"], "https://example.org/a")
            return (200, Data(#"{"data":{"title":"Page","url":"https://example.org/a","content":"page text"}}"#.utf8))
        }
        let found = try await client.search(query: "claim", configuration: config, key: "search-key")
        XCTAssertEqual(found.first?.content, "snippet")
        let page = try await client.read(url: try XCTUnwrap(found.first?.url), configuration: config, key: nil)
        XCTAssertEqual(page.content, "page text")
    }

    func testDisabledAndInvalidURLs() async throws {
        let client = JinaClient()
        var config = JinaConfiguration()
        do { _ = try await client.search(query: "x", configuration: config, key: nil); XCTFail("Expected disabled") }
        catch AIError.disabled {} catch { XCTFail("Unexpected error") }
        config.searchEnabled = true
        config.searchEndpoint = "https://user:secret@example.org/"
        do { _ = try await client.search(query: "x", configuration: config, key: nil); XCTFail("Expected invalid URL") }
        catch AIError.invalidConfiguration {} catch { XCTFail("Unexpected error") }
    }
    func testSourceSearchContinuesAfterReaderFailure() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [JinaTestProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        var config = JinaConfiguration()
        config.searchEnabled = true
        config.readerEnabled = true
        var profile = AIModelProfile(api: .responses)
        profile.isEnabled = true
        profile.modelID = "test"
        JinaTestProtocol.handler = { request in
            if request.url?.host == "s.jina.ai" {
                return (200, Data(#"{"data":[{"title":"Broken","url":"https://example.org/broken"},{"title":"Good","url":"https://example.org/good"}]}"#.utf8))
            }
            if request.url?.host == "r.jina.ai" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.body(request)) as? [String: String])
                if body["url"] == "https://example.org/broken" { return (503, Data()) }
                XCTAssertEqual(body["url"], "https://example.org/good")
                return (200, Data(#"{"data":{"title":"Good","url":"https://example.org/good","content":"source quote"}}"#.utf8))
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any])
            let input = try XCTUnwrap(body["input"] as? String)
            let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let sources = try XCTUnwrap(evidence["sources"] as? [[String: Any]])
            XCTAssertEqual(sources.count, 1)
            XCTAssertEqual(sources.first?["index"] as? Int, 0)
            XCTAssertEqual(sources.first?["text"] as? String, "source quote")
            let text = #"{"findings":[{"claim":"claim","sourceIndex":0,"quote":"source quote","explanation":"relevant"}]}"#
            let response: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        let result = try await AIWritingService.generate(feature: .sources, input: "claim", option: "", profile: profile, key: nil, client: AIClient(session: session), jinaConfiguration: config, jinaClient: JinaClient(session: session))
        XCTAssertTrue(result.report.contains("https://example.org/good"))
        XCTAssertFalse(result.report.contains("https://example.org/broken"))
    }

    func testSourceReaderCancellationStopsOperation() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [JinaTestProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        var config = JinaConfiguration()
        config.searchEnabled = true
        config.readerEnabled = true
        JinaTestProtocol.handler = { request in
            if request.url?.host == "s.jina.ai" {
                return (200, Data(#"{"data":[{"title":"Page","url":"https://example.org/a"}]}"#.utf8))
            }
            throw URLError(.cancelled)
        }
        do {
            _ = try await AIWritingService.generate(feature: .sources, input: "claim", option: "", profile: AIModelProfile(api: .responses), key: nil, client: AIClient(session: session), jinaConfiguration: config, jinaClient: JinaClient(session: session))
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    }

    func testAllReaderFailuresReturnUnverifiedCandidates() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [JinaTestProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        var config = JinaConfiguration()
        config.searchEnabled = true
        config.readerEnabled = true
        JinaTestProtocol.handler = { request in
            if request.url?.host == "s.jina.ai" {
                return (200, Data(#"{"data":[{"title":"Page","url":"https://example.org/a"}]}"#.utf8))
            }
            XCTAssertEqual(request.url?.host, "r.jina.ai")
            return (503, Data())
        }
        let result = try await AIWritingService.generate(feature: .sources, input: "claim", option: "", profile: AIModelProfile(api: .responses), key: nil, client: AIClient(session: session), jinaConfiguration: config, jinaClient: JinaClient(session: session))
        XCTAssertTrue(result.report.contains("https://example.org/a"))
        XCTAssertTrue(result.report.contains(L10n.tr("搜索结果尚未读取，以下链接仅供参考。")))
    }

}
