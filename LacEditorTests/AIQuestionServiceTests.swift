import XCTest
@testable import LacEditor

final class AIQuestionServiceTests: XCTestCase {
    private func source(_ name: String, _ text: String, selection: NSRange? = nil) -> AIQuestionSource {
        AIQuestionSource(snapshot: AIContextSnapshot(input: .document(UUID()), name: name, text: text, document: nil, documentRevision: 1, fileRevision: nil), selectionRange: selection)
    }

    private func turn(_ question: String, _ answer: String) -> AIQuestionTurn {
        AIQuestionTurn(id: UUID(), question: question, answer: answer, citations: [], skippedCitations: 0, sourceSummary: "", sentBytes: 0)
    }

    func testParseResolvesCitationsAcrossSources() throws {
        let sources = [source("a.md", "Alpha beta."), source("b.md", "Gamma delta.")]
        let reply = try AIQuestionService.parse(#"{"answer":"ok","citations":[{"sourceIndex":0,"quote":"beta"},{"sourceIndex":1,"quote":"delta"}]}"#, sources: sources)
        XCTAssertEqual(reply.answer, "ok")
        XCTAssertEqual(reply.skipped, 0)
        XCTAssertEqual(reply.citations.map(\.range), [NSRange(location: 6, length: 4), NSRange(location: 6, length: 5)])
        XCTAssertEqual(reply.citations.map(\.sourceName), ["a.md", "b.md"])
        XCTAssertEqual(reply.citations[0].stamp.text, "")
        XCTAssertEqual(reply.citations[0].stamp.documentRevision, 1)
    }

    func testParseUnwrapsFenceAndUsesUTF16AndSelectionOffset() throws {
        let sources = [source("a.md", "😀 你好 world", selection: NSRange(location: 10, length: 11))]
        let reply = try AIQuestionService.parse("```json\n{\"answer\":\"ok\",\"citations\":[{\"sourceIndex\":0,\"quote\":\"你好\"}]}\n```", sources: sources)
        XCTAssertEqual(reply.citations.first?.range, NSRange(location: 13, length: 2))
    }

    func testParseSkipsInvalidCitationsAndDropsDuplicatesSilently() throws {
        let sources = [source("a.md", "one two two")]
        let json = #"{"answer":"ok","citations":[{"sourceIndex":0,"quote":"missing"},{"sourceIndex":0,"quote":"two"},{"sourceIndex":0,"quote":" "},{"sourceIndex":1,"quote":"one"},{"sourceIndex":true,"quote":"one"},{"sourceIndex":0.5,"quote":"one"},{"sourceIndex":-1,"quote":"one"},{"sourceIndex":0,"quote":"one"},{"sourceIndex":0,"quote":"one"}]}"#
        let reply = try AIQuestionService.parse(json, sources: sources)
        XCTAssertEqual(reply.citations.count, 1)
        XCTAssertEqual(reply.citations.first?.quote, "one")
        XCTAssertEqual(reply.skipped, 7)
    }

    func testParseAllowsMissingOrEmptyCitationsButRejectsBadShape() throws {
        let sources = [source("a.md", "text")]
        XCTAssertTrue(try AIQuestionService.parse(#"{"answer":"none"}"#, sources: sources).citations.isEmpty)
        XCTAssertTrue(try AIQuestionService.parse(#"{"answer":"none","citations":[]}"#, sources: sources).citations.isEmpty)
        for bad in [#"{"answer":" "}"#, #"{"citations":[]}"#, "not json", #"{"answer":"x","citations":"y"}"#, #"{"answer":3}"#] {
            XCTAssertThrowsError(try AIQuestionService.parse(bad, sources: sources), bad) {
                guard case AIError.invalidResponse = $0 else { return XCTFail("Unexpected error") }
            }
        }
    }

    func testMessagesPutSourcesOnlyInLatestUserMessage() throws {
        let sources = [source("a.md", "Alpha")]
        let first = AIQuestionService.messages(history: [], question: "q1", sources: sources)
        XCTAssertEqual(first.count, 1)
        guard case .user(let text) = first[0] else { return XCTFail("Expected user message") }
        XCTAssertTrue(text.hasPrefix("Sources (JSON):\n"))
        XCTAssertTrue(text.contains(#""index":0"#))
        XCTAssertTrue(text.contains(#""scope":"document""#))
        XCTAssertTrue(text.hasSuffix("Question:\nq1"))
        let second = AIQuestionService.messages(history: [turn("q1", "a1")], question: "q2", sources: [source("a.md", "Alpha", selection: NSRange(location: 0, length: 5))])
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(second[0], .user("q1"))
        XCTAssertEqual(second[1], .assistant(#"{"answer":"a1"}"#))
        guard case .user(let last) = second[2] else { return XCTFail("Expected user message") }
        XCTAssertTrue(last.contains(#""scope":"selection""#))
        XCTAssertTrue(last.hasSuffix("Question:\nq2"))
    }

    func testSizeCountsUTF8ReplacesMediaAndSeparatesHistory() {
        let media = "data:image/png;base64," + String(repeating: "A", count: 3_000_000)
        let light = AIQuestionService.sizeBytes(history: [], question: "q", sources: [source("a", "![](\(media))")])
        XCTAssertLessThan(light.total, AIRequestSize.threshold)
        let sized = AIQuestionService.sizeBytes(history: [turn("你好", "ok")], question: "q", sources: [source("n", "你")])
        XCTAssertEqual(sized.sources, 4)
        XCTAssertEqual(sized.history, 8)
        XCTAssertEqual(sized.total, 13)
        let large = AIQuestionService.sizeBytes(history: [], question: "q", sources: [source("a", String(repeating: "x", count: AIRequestSize.threshold + 1))])
        XCTAssertGreaterThan(large.total, AIRequestSize.threshold)
    }
}
