import Foundation
import XCTest
@testable import LacEditor

final class AIWritingServiceTests: XCTestCase {
    func testUniqueUTF16Ranges() throws {
        let input = "😀 中文 текст"
        let json = #"{"suggestions":[{"original":"中文","replacement":"文字","explanation":"clarity"}],"report":""}"#
        let result = try AIWritingService.parse(response: json, input: input, feature: .clarity)
        XCTAssertEqual(result.suggestions.first?.range, NSRange(location: 3, length: 2))
        XCTAssertEqual((input as NSString).substring(with: result.suggestions[0].range), "中文")
    }

    func testAmbiguousAndOverlappingSuggestionsAreRejected() {
        let duplicate = #"{"suggestions":[{"original":"aba","replacement":"x","explanation":""}]}"#
        XCTAssertThrowsError(try AIWritingService.parse(response: duplicate, input: "ababa", feature: .clarity))
        let overlap = #"{"suggestions":[{"original":"abc","replacement":"x","explanation":""},{"original":"cde","replacement":"y","explanation":""}]}"#
        XCTAssertThrowsError(try AIWritingService.parse(response: overlap, input: "abcde", feature: .clarity))
    }

    func testMarkdownReplacementAndCompletion() throws {
        let input = "[链接](https://example.com) 😀\n```\nx\n```"
        let result = try AIWritingService.parse(response: #"{"replacement":"new","report":""}"#, input: input, feature: .translation)
        XCTAssertEqual(result.suggestions[0].original, input)
        XCTAssertEqual(result.suggestions[0].range, NSRange(location: 0, length: (input as NSString).length))
        let completion = try AIWritingService.parse(response: #"{"replacement":" more"}"#, input: input, feature: .completion)
        XCTAssertEqual(completion.suggestions[0].range, NSRange(location: (input as NSString).length, length: 0))
        XCTAssertEqual(completion.suggestions[0].original, "")
    }

    func testFindingsRequireActualQuotes() throws {
        let valid = #"{"findings":[{"first":"first","second":"second","explanation":"check"}]}"#
        let result = try AIWritingService.parse(response: valid, input: "first and second", feature: .contradictions)
        XCTAssertTrue(result.report.contains("first ↔ second"))
        XCTAssertEqual(result.references.map(\.quote), ["first", "second"])
        XCTAssertEqual(result.references.map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 10, length: 6)])
        XCTAssertThrowsError(try AIWritingService.parse(response: valid, input: "first only", feature: .contradictions))
        XCTAssertThrowsError(try AIWritingService.parse(response: valid, input: "first first second", feature: .contradictions))
        let unicode = try AIWritingService.parse(response: valid, input: "😀 first 中文 second", feature: .terminology)
        XCTAssertEqual(unicode.references.map(\.range), [NSRange(location: 3, length: 5), NSRange(location: 12, length: 6)])
        XCTAssertThrowsError(try AIWritingService.parse(response: "not JSON", input: "x", feature: .clarity))
    }
    func testSourcesRequireRealClaimQuoteAndIndex() throws {
        let page = JinaPage(title: "Page", url: URL(string: "https://example.org/a")!, content: "verified passage")
        let valid = #"{"findings":[{"claim":"a claim","sourceIndex":0,"quote":"verified passage","explanation":"relevant"}]}"#
        let report = try AIWritingService.sourceReport(response: valid, input: "a claim", pages: [page])
        XCTAssertTrue(report.contains("https://example.org/a"))
        XCTAssertThrowsError(try AIWritingService.sourceReport(response: valid, input: "different", pages: [page]))
        XCTAssertThrowsError(try AIWritingService.sourceReport(response: valid.replacingOccurrences(of: "verified passage", with: "invented"), input: "a claim", pages: [page]))
        XCTAssertThrowsError(try AIWritingService.sourceReport(response: valid.replacingOccurrences(of: "\"sourceIndex\":0", with: "\"sourceIndex\":1"), input: "a claim", pages: [page]))
    }

}

private final class AITranslationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

extension AIWritingServiceTests {
    func testTranslationSendsSelectedLanguageAndOriginalText() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AITranslationURLProtocol.self]
        let client = AIClient(session: URLSession(configuration: configuration))
        let input = "# Hello 😀\n[link](https://example.com) `code` 42"
        let replacement = "# 你好 😀\n[链接](https://example.com) `code` 42"
        for api in [AIAPIProtocol.responses, .chatCompletions] {
            var profile = AIModelProfile(api: api)
            profile.isEnabled = true
            profile.modelID = "translation-model"
            profile.baseURL = "https://example.com/v1"
            AITranslationURLProtocol.handler = { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertEqual(body["model"] as? String, "translation-model")
                let instruction: String
                if api == .responses {
                    XCTAssertEqual(request.url?.path, "/v1/responses")
                    XCTAssertEqual(body["input"] as? String, input)
                    instruction = try XCTUnwrap(body["instructions"] as? String)
                } else {
                    XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                    let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
                    XCTAssertEqual(messages.last?["content"], input)
                    instruction = try XCTUnwrap(messages.first?["content"])
                }
                for value in ["Traditional Chinese", "Markdown structure", "link URLs", "code", "formulas", "numbers", "names", "identifiers", "Do not summarize, add or omit"] {
                    XCTAssertTrue(instruction.contains(value), "Missing instruction: \(value)")
                }
                let json = try JSONSerialization.data(withJSONObject: ["replacement": replacement, "report": ""])
                let text = try XCTUnwrap(String(data: json, encoding: .utf8))
                let response: [String: Any] = api == .responses
                    ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
                    : ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
                return try JSONSerialization.data(withJSONObject: response)
            }
            let result = try await AIWritingService.generate(feature: .translation, input: input, option: "Traditional Chinese", profile: profile, key: nil, client: client)
            XCTAssertEqual(result.suggestions.first?.original, input)
            XCTAssertEqual(result.suggestions.first?.replacement, replacement)
        }
    }
}
