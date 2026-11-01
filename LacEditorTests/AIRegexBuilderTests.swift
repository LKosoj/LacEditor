import XCTest
@preconcurrency @testable import LacEditor

final class AIRegexBuilderTests: XCTestCase {
    private func assertInvalidResponse(_ response: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AIRegexBuilder.parse(response), file: file, line: line) {
            XCTAssertEqual(($0 as? AIError)?.errorDescription, AIError.invalidResponse.errorDescription, file: file, line: line)
        }
    }

    private func assertFailure(_ response: String, _ expected: AIRegexBuilder.Failure, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AIRegexBuilder.parse(response), file: file, line: line) {
            XCTAssertEqual($0 as? AIRegexBuilder.Failure, expected, file: file, line: line)
        }
    }

    func testParsesPlainJSON() throws {
        let result = try AIRegexBuilder.parse(#"{"pattern":"\\d+","caseSensitive":true,"explanation":"Числа"}"#)
        XCTAssertEqual(result, AIRegexBuilder.Result(pattern: #"\d+"#, caseSensitive: true, explanation: "Числа"))
    }

    func testParsesFencedJSON() throws {
        let json = #"{"pattern":"\\d+","caseSensitive":true,"explanation":"Числа"}"#
        let expected = AIRegexBuilder.Result(pattern: #"\d+"#, caseSensitive: true, explanation: "Числа")
        XCTAssertEqual(try AIRegexBuilder.parse("```json\n\(json)\n```"), expected)
        XCTAssertEqual(try AIRegexBuilder.parse("```\n\(json)\n```"), expected)
    }

    func testCaseSensitiveDefaultsToFalse() throws {
        XCTAssertFalse(try AIRegexBuilder.parse(#"{"pattern":"abc"}"#).caseSensitive)
    }

    func testCaseSensitiveWrongTypeThrows() {
        assertInvalidResponse(#"{"pattern":"abc","caseSensitive":"yes"}"#)
        assertInvalidResponse(#"{"pattern":"abc","caseSensitive":1}"#)
        assertInvalidResponse(#"{"pattern":"abc","caseSensitive":null}"#)
    }

    func testMissingExplanationBecomesEmpty() throws {
        XCTAssertEqual(try AIRegexBuilder.parse(#"{"pattern":"abc"}"#).explanation, "")
        XCTAssertEqual(try AIRegexBuilder.parse(#"{"pattern":"abc","explanation":5}"#).explanation, "")
        XCTAssertEqual(try AIRegexBuilder.parse(#"{"pattern":"abc","explanation":"  Слово \n"}"#).explanation, "Слово")
    }

    func testInvalidJSONThrowsInvalidResponse() {
        assertInvalidResponse("not JSON")
        assertInvalidResponse("[1]")
        assertInvalidResponse("```json\n{\"pattern\":\"a\"")
    }

    func testMissingOrNonStringPatternThrows() {
        assertInvalidResponse(#"{"caseSensitive":false}"#)
        assertInvalidResponse(#"{"pattern":5}"#)
        assertInvalidResponse(#"{"pattern":null}"#)
    }

    func testEmptyPatternIsDeclinedWithExplanation() {
        assertFailure(#"{"pattern":"","explanation":"Нельзя"}"#, .declined("Нельзя"))
        assertFailure(#"{"pattern":"   ","explanation":"Нельзя"}"#, .declined("Нельзя"))
        assertFailure(#"{"pattern":""}"#, .declined(""))
    }

    func testInvalidRegexThrowsInvalidPattern() {
        assertFailure(#"{"pattern":"(abc"}"#, .invalidPattern)
        assertFailure(#"{"pattern":"[a-"}"#, .invalidPattern)
        assertFailure(#"{"pattern":"*x"}"#, .invalidPattern)
        assertFailure(#"{"pattern":"\\"}"#, .invalidPattern)
    }

    func testPatternWithSurroundingSpacesIsKept() throws {
        XCTAssertEqual(try AIRegexBuilder.parse(#"{"pattern":" a "}"#).pattern, " a ")
    }

    func testUnicodeClassesCompile() throws {
        let text = "a😀中文b"
        let han = try AIRegexBuilder.parse(#"{"pattern":"\\p{Han}+"}"#)
        let options = TextSearchService.Options(caseSensitive: han.caseSensitive, usesRegex: true, wholeWord: false)
        XCTAssertEqual(try TextSearchService.allRanges(in: text, query: han.pattern, options: options), [NSRange(location: 3, length: 2)])
        let intersection = try AIRegexBuilder.parse(#"{"pattern":"[\\p{L}&&[^a-z]]"}"#)
        XCTAssertEqual(try TextSearchService.allRanges(in: text, query: intersection.pattern, options: options),
                       [NSRange(location: 3, length: 1), NSRange(location: 4, length: 1)])
    }

    func testResultMatchesCaseOption() throws {
        let sensitive = try AIRegexBuilder.parse(#"{"pattern":"abc","caseSensitive":true}"#)
        let insensitive = try AIRegexBuilder.parse(#"{"pattern":"abc","caseSensitive":false}"#)
        func ranges(_ result: AIRegexBuilder.Result) throws -> [NSRange] {
            try TextSearchService.allRanges(
                in: "ABC", query: result.pattern,
                options: .init(caseSensitive: result.caseSensitive, usesRegex: true, wholeWord: false))
        }
        XCTAssertTrue(try ranges(sensitive).isEmpty)
        XCTAssertEqual(try ranges(insensitive), [NSRange(location: 0, length: 3)])
    }

    func testInputWrapsPhraseInTags() {
        XCTAssertEqual(AIRegexBuilder.input("фраза"), "<request>\nфраза\n</request>")
    }

    func testInstructionsMentionContract() {
        for word in ["pattern", "caseSensitive", "explanation", "ICU", "<request>"] {
            XCTAssertTrue(AIRegexBuilder.instructions.contains(word), word)
        }
    }

    func testParseDoesNotRunSearch() throws {
        let start = Date()
        let result = try AIRegexBuilder.parse(#"{"pattern":"(a+)+$"}"#)
        XCTAssertEqual(result.pattern, "(a+)+$")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
