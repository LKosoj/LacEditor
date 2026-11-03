import XCTest
@testable import LacEditor

final class StyleReviewParsingTests: XCTestCase {
    private let text = "Это в целом неплохо. Но это в целом лишнее. Конец."

    private func parse(_ response: String, text: String? = nil, offset: Int = 0) throws -> StyleReviewResult {
        try StyleReviewService.parse(response: response, text: text ?? self.text, offset: offset)
    }

    func testAcceptsUniqueQuote() throws {
        let result = try parse(#"{"findings":[{"quote":"неплохо","category":"cliche","explanation":"e","replacement":"хорошо"}]}"#)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.skipped, 0)
        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual((text as NSString).substring(with: finding.range), "неплохо")
        XCTAssertEqual(finding.category, .cliche)
        XCTAssertEqual(finding.replacement, "хорошо")
        XCTAssertEqual(finding.source, .ai)
    }

    func testQuoteWithTwoOccurrencesIsSkipped() throws {
        let result = try parse(#"{"findings":[{"quote":"в целом","category":"cliche","explanation":"e"}]}"#)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.skipped, 1)
    }

    func testMissingQuoteIsSkipped() throws {
        let result = try parse(#"{"findings":[{"quote":"нет такого","category":"other","explanation":"e"}]}"#)
        XCTAssertEqual(result.skipped, 1)
    }

    func testEmptyQuoteIsSkipped() throws {
        let result = try parse(#"{"findings":[{"quote":"","category":"other","explanation":"e"}]}"#)
        XCTAssertEqual(result.skipped, 1)
    }

    func testUnknownCategoryBecomesOther() throws {
        let result = try parse(#"{"findings":[{"quote":"Конец","category":"repeatedWord","explanation":"e"}]}"#)
        XCTAssertEqual(result.findings.first?.category, .other)
    }

    func testCategoryIsCaseInsensitive() throws {
        let result = try parse(#"{"findings":[{"quote":"Конец","category":" Rhythm ","explanation":"e"}]}"#)
        XCTAssertEqual(result.findings.first?.category, .rhythm)
    }

    func testOffsetShiftsRange() throws {
        let result = try parse(#"{"findings":[{"quote":"Конец","category":"other","explanation":"e"}]}"#, offset: 100)
        XCTAssertEqual(result.findings.first?.range.location, 100 + (text as NSString).range(of: "Конец").location)
    }

    func testOverlappingFindingIsSkipped() throws {
        let result = try parse(#"{"findings":[{"quote":"неплохо","category":"other","explanation":"e"},{"quote":"плохо","category":"other","explanation":"e"}]}"#)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.skipped, 1)
    }

    func testReplacementEqualToQuoteIsDropped() throws {
        let result = try parse(#"{"findings":[{"quote":"Конец","category":"other","explanation":"e","replacement":"Конец"}]}"#)
        XCTAssertNil(result.findings.first?.replacement)
    }

    func testEmptyFindings() throws {
        let result = try parse(#"{"findings":[]}"#)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.skipped, 0)
    }

    func testInvalidResponseThrows() {
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse(#"{"other":1}"#))
    }

    func testResultIsSortedByPosition() throws {
        let result = try parse(#"{"findings":[{"quote":"Конец","category":"other","explanation":"e"},{"quote":"неплохо","category":"other","explanation":"e"}]}"#)
        XCTAssertEqual(result.findings.map(\.range.location), result.findings.map(\.range.location).sorted())
    }

    func testInputContainsTextBetweenDelimitersAndKnownRemarks() {
        let known = StyleFinding(category: .customWord, range: NSRange(location: 0, length: 3), fragment: "abc", explanation: "")
        let input = StyleReviewService.input(text: "Body", languageCode: "en", known: [known], goal: "")
        XCTAssertTrue(input.contains("TEXT:\n<<<\nBody\n>>>"))
        XCTAssertTrue(input.contains("KNOWN LOCAL REMARKS:"))
        XCTAssertTrue(input.hasPrefix("LANGUAGE: en"))
    }

    func testInstructionsAppendGoalAsData() {
        let text = StyleReviewService.instructions(languageCode: "ru", goal: " для школьников ")
        XCTAssertTrue(text.contains("для школьников"))
        XCTAssertFalse(StyleReviewService.instructions(languageCode: nil, goal: "").contains("Review goal"))
    }
}
