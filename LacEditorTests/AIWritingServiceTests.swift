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

    func testAmbiguousAndOverlappingSuggestionsAreSkipped() throws {
        let duplicate = #"{"suggestions":[{"original":"aba","replacement":"x","explanation":""}]}"#
        let first = try AIWritingService.parse(response: duplicate, input: "ababa", feature: .clarity)
        XCTAssertTrue(first.suggestions.isEmpty)
        XCTAssertEqual(first.skipped, 1)
        let overlap = #"{"suggestions":[{"original":"abc","replacement":"x","explanation":""},{"original":"cde","replacement":"y","explanation":""}]}"#
        let second = try AIWritingService.parse(response: overlap, input: "abcde", feature: .clarity)
        XCTAssertEqual(second.suggestions.count, 1)
        XCTAssertEqual(second.skipped, 1)
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
        let valid = #"{"findings":[{"kind":"contradiction","first":"first","second":"second","explanation":"check"}]}"#
        let result = try AIWritingService.parse(response: valid, input: "first and second", feature: .consistency)
        XCTAssertTrue(result.report.contains("first ↔ second"))
        XCTAssertEqual(result.references.map(\.quote), ["first", "second"])
        XCTAssertEqual(result.references.map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 10, length: 6)])
        let missing = try AIWritingService.parse(response: valid, input: "first only", feature: .consistency)
        XCTAssertTrue(missing.references.isEmpty)
        XCTAssertEqual(missing.skipped, 1)
        let repeated = try AIWritingService.parse(response: valid, input: "first first second", feature: .consistency)
        XCTAssertTrue(repeated.references.isEmpty)
        XCTAssertEqual(repeated.skipped, 1)
        let unicode = try AIWritingService.parse(response: valid, input: "😀 first 中文 second", feature: .consistency)
        XCTAssertEqual(unicode.references.map(\.range), [NSRange(location: 3, length: 5), NSRange(location: 12, length: 6)])
        XCTAssertThrowsError(try AIWritingService.parse(response: "not JSON", input: "x", feature: .clarity))
    }
    func testSourcesRequireRealClaimQuoteAndIndex() throws {
        let page = JinaPage(title: "Page", url: URL(string: "https://example.org/a")!, content: "verified passage")
        let valid = #"{"findings":[{"claim":"a claim","sourceIndex":0,"quote":"verified passage","explanation":"relevant"}]}"#
        let report = try AIWritingService.sourceReport(response: valid, input: "a claim", pages: [page])
        XCTAssertTrue(report.report.contains("https://example.org/a"))
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.accepted, 1)
        let partial = valid.dropLast(3) + #"},{"claim":"a claim","sourceIndex":0,"quote":"invented","explanation":"x"}]}"#
        let mixed = try AIWritingService.sourceReport(response: String(partial), input: "a claim", pages: [page])
        XCTAssertEqual(mixed.accepted, 1)
        XCTAssertEqual(mixed.skipped, 1)
        let invalid = [
            (valid, "different"),
            (valid.replacingOccurrences(of: "verified passage", with: "invented"), "a claim"),
            (valid.replacingOccurrences(of: "\"sourceIndex\":0", with: "\"sourceIndex\":1"), "a claim")
        ]
        for (response, input) in invalid {
            let result = try AIWritingService.sourceReport(response: response, input: input, pages: [page])
            XCTAssertEqual(result.skipped, 1)
            XCTAssertEqual(result.report, L10n.tr("未找到可引用的来源。"))
        }
    }

    func testPartialClarityKeepsValidSuggestions() throws {
        let json = #"{"suggestions":[{"original":"one","replacement":"1","explanation":"x"},{"original":"missing","replacement":"2","explanation":"x"},{"original":"two","replacement":5,"explanation":"x"}]}"#
        let result = try AIWritingService.parse(response: json, input: "one two", feature: .clarity)
        XCTAssertEqual(result.suggestions.map(\.original), ["one"])
        XCTAssertEqual(result.skipped, 2)
    }

    func testAllItemsDroppedIsNotAnError() throws {
        let json = #"{"suggestions":[{"original":"x","replacement":"y","explanation":"z"},{"original":"","replacement":"y","explanation":"z"}]}"#
        let result = try AIWritingService.parse(response: json, input: "abc", feature: .clarity)
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertThrowsError(try AIWritingService.parse(response: #"{"other":[]}"#, input: "abc", feature: .clarity))
    }

    func testFindingsDropPairAtomically() throws {
        let json = #"{"findings":[{"kind":"terminology","first":"alpha","second":"absent","explanation":"x"},{"kind":"terminology","first":"alpha","second":"beta","explanation":"y"}]}"#
        let result = try AIWritingService.parse(response: json, input: "alpha beta", feature: .consistency)
        XCTAssertEqual(result.references.map(\.quote), ["alpha", "beta"])
        XCTAssertEqual(result.skipped, 1)
    }

    func testFencedResponsesAreAccepted() throws {
        let fenced = "```json\n" + #"{"suggestions":[{"original":"one","replacement":"1","explanation":"x"}]}"# + "\n```"
        XCTAssertEqual(try AIWritingService.parse(response: fenced, input: "one", feature: .clarity).suggestions.count, 1)
        let page = JinaPage(title: "Page", url: URL(string: "https://example.org/a")!, content: "verified passage")
        let sources = "```\n" + #"{"findings":[{"claim":"a claim","sourceIndex":0,"quote":"verified passage","explanation":"relevant"}]}"# + "\n```"
        XCTAssertEqual(try AIWritingService.sourceReport(response: sources, input: "a claim", pages: [page]).skipped, 0)
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

    func testConsistencyReportHasTwoSectionsAndOrderedReferences() throws {
        let json = #"{"findings":[{"kind":"contradiction","first":"always","second":"never","explanation":"c"},{"kind":"terminology","first":"😀 file","second":"文档","explanation":"t"}]}"#
        let input = "always 😀 file 文档 never"
        let result = try AIWritingService.parse(response: json, input: input, feature: .consistency)
        XCTAssertTrue(result.report.hasPrefix("**\(L10n.tr("术语不一致"))**"))
        let terms = try XCTUnwrap(result.report.range(of: "**\(L10n.tr("术语不一致"))**"))
        let contradictions = try XCTUnwrap(result.report.range(of: "**\(L10n.tr("矛盾"))**"))
        XCTAssertLessThan(terms.lowerBound, contradictions.lowerBound)
        XCTAssertEqual(result.references.map(\.quote), ["😀 file", "文档", "always", "never"])
        for reference in result.references { XCTAssertEqual((input as NSString).substring(with: reference.range), reference.quote) }
        XCTAssertEqual(result.skipped, 0)
    }

    func testConsistencySkipsUnknownKindAndNonUniqueQuotes() throws {
        let json = #"{"findings":[{"kind":"style","first":"a1","second":"b2","explanation":"x"},{"first":"a1","second":"b2","explanation":"x"},{"kind":"terminology","first":"a1","second":"a1","explanation":"x"},{"kind":"terminology","first":"a1","second":"b2","explanation":"ok"}]}"#
        let result = try AIWritingService.parse(response: json, input: "a1 b2", feature: .consistency)
        XCTAssertEqual(result.references.map(\.quote), ["a1", "b2"])
        XCTAssertEqual(result.skipped, 3)
        XCTAssertFalse(result.report.contains(L10n.tr("矛盾")))
    }

    func testConsistencyEmptyFindingsGivesEmptyReport() throws {
        let result = try AIWritingService.parse(response: #"{"findings":[]}"#, input: "text", feature: .consistency)
        XCTAssertTrue(result.report.isEmpty)
        XCTAssertTrue(result.references.isEmpty)
        XCTAssertEqual(result.skipped, 0)
    }

    func testRewriteParsesReplacement() throws {
        let result = try AIWritingService.parse(response: #"{"replacement":"new","report":""}"#, input: "old 😀", feature: .rewrite)
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions[0].range, NSRange(location: 0, length: ("old 😀" as NSString).length))
    }

    func testRewriteModeTasks() {
        XCTAssertTrue(AIRewriteMode.rephrase.task.hasPrefix("Rephrase"))
        XCTAssertTrue(AIRewriteMode.shorten.task.hasPrefix("Shorten"))
        XCTAssertTrue(AIRewriteMode.expand.task.hasPrefix("Expand"))
        XCTAssertTrue(AIRewriteMode.tone.task.contains("tone"))
        XCTAssertEqual(AIRewriteMode.allCases.filter(\.requiresOption), [.tone])
        XCTAssertEqual(AIRewriteMode.allCases.map(\.rawValue), ["rephrase", "shorten", "expand", "tone"])
    }
}
