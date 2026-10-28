import XCTest
@testable import LacEditor

final class AITextComparisonTests: XCTestCase {
    func testLineEndingsAndFinalNewlineAreVisible() {
        let difference = AITextComparison.compare(before: "a\r\n😀", after: "a\n😀\n")
        XCTAssertTrue(difference.contains("a\\r\\n"))
        XCTAssertTrue(difference.contains("a\\n"))
        XCTAssertTrue(difference.contains("😀\\n"))
        XCTAssertTrue(difference.contains("😀\""))
    }

    func testUnicodeNormalizationDifferencesAreRetained() {
        XCTAssertTrue(AITextComparison.compare(before: "é", after: "e\u{301}").contains("+ "))
    }

    func testEmptyAndEqual() {
        XCTAssertTrue(AITextComparison.compare(before: "", after: "x").contains("+ \"x\""))
        XCTAssertFalse(AITextComparison.compare(before: "x", after: "x").contains("+ "))
    }
}
