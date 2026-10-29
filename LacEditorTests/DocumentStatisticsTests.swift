import Foundation
import XCTest
@testable import LacEditor

final class DocumentStatisticsTests: XCTestCase {
    func testEmptyAndCompositeCharacters() throws {
        let empty = try XCTUnwrap(DocumentStatistics.calculate(""))
        XCTAssertEqual(empty.words, 0)
        XCTAssertEqual(empty.characters, 0)
        XCTAssertEqual(empty.charactersWithoutWhitespace, 0)
        XCTAssertEqual(empty.lines, 1)
        XCTAssertEqual(empty.readingMinutes, 0)
        let text = "e\u{301} 👨‍👩‍👧‍👦\r\n中"
        let result = try XCTUnwrap(DocumentStatistics.calculate(text))
        XCTAssertEqual(result.characters, 5)
        XCTAssertEqual(result.charactersWithoutWhitespace, 3)
        XCTAssertEqual(result.lines, 2)
    }

    func testLinesAndWords() throws {
        let result = try XCTUnwrap(DocumentStatistics.calculate("Hello world\r\nПривет мир\r中\n\u{2028}\u{2029}"))
        XCTAssertEqual(result.lines, 6)
        XCTAssertEqual(result.lines, EditorDocument.countLines(in: "Hello world\r\nПривет мир\r中\n\u{2028}\u{2029}"))
        XCTAssertGreaterThanOrEqual(result.words, 5)
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate("Hello world Привет мир")).words, 4)
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate("中文测试")).words, 4)
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate("**hello**")).characters, 9)
    }

    func testHanCharactersAreSeparateWordsInMixedText() throws {
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate("中文English中文")).words, 5)
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate("中文 Привет world")).words, 4)
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate("é 👨‍👩‍👧‍👦 中\u{E0100}文")).words, 3)
        XCTAssertEqual(try XCTUnwrap(DocumentStatistics.calculate("𠀀中文")).words, 3)
    }

    func testReadingSpeedDoesNotChangeOtherCounts() throws {
        let text = Array(repeating: "word", count: 201).joined(separator: " ")
        let slower = try XCTUnwrap(DocumentStatistics.calculate(text, wordsPerMinute: 200))
        let faster = try XCTUnwrap(DocumentStatistics.calculate(text, wordsPerMinute: 201))
        XCTAssertEqual(slower.readingMinutes, 2)
        XCTAssertEqual(faster.readingMinutes, 1)
        XCTAssertEqual(slower.words, faster.words)
        XCTAssertEqual(slower.characters, faster.characters)
        XCTAssertNil(DocumentStatistics.calculate(text, wordsPerMinute: 0))
    }

    func testReadingEstimateAndCancellation() throws {
        for (words, minutes) in [(0, 0), (200, 1), (201, 2)] {
            let text = Array(repeating: "word", count: words).joined(separator: " ")
            let result = try XCTUnwrap(DocumentStatistics.calculate(text))
            XCTAssertEqual(result.words, words)
            XCTAssertEqual(result.readingMinutes, minutes)
        }
        XCTAssertNil(DocumentStatistics.calculate("hello", isCancelled: { true }))
        var checks = 0
        XCTAssertNil(DocumentStatistics.calculate(String(repeating: "a", count: 8_200), isCancelled: {
            checks += 1
            return checks == 2
        }))
        XCTAssertEqual(checks, 2)
    }
}
