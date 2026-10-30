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

final class AITextComparisonChangesTests: XCTestCase {
    func testEqualTextsHaveNoChanges() {
        XCTAssertTrue(AITextComparison.changes(before: "a\nb\n", after: "a\nb\n").isEmpty)
        XCTAssertTrue(AITextComparison.changes(before: "", after: "").isEmpty)
    }

    func testChangesFollowDocumentOrderWithLineNumbers() {
        let changes = AITextComparison.changes(before: "a\nb\nc\n", after: "a\nB\nc\nd\n")
        XCTAssertEqual(changes, [
            .init(kind: .removed, line: 2, text: "b\n"),
            .init(kind: .added, line: 2, text: "B\n"),
            .init(kind: .added, line: 4, text: "d\n")
        ])
    }

    func testLineEndingsEmojiAndNormalizationDiffer() {
        XCTAssertEqual(AITextComparison.changes(before: "a\r\n", after: "a\n").count, 2)
        XCTAssertEqual(AITextComparison.changes(before: "😀 你好", after: "😀 你好\n").map(\.kind), [.removed, .added])
        XCTAssertEqual(AITextComparison.changes(before: "é", after: "e\u{301}").count, 2)
    }

    func testInsertionIntoEmptyText() {
        XCTAssertEqual(AITextComparison.changes(before: "", after: "x"), [.init(kind: .added, line: 1, text: "x")])
    }
}
