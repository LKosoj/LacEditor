import XCTest
@testable import LacEditor

/// Состояние оформления для панели форматирования: вид абзаца и строчные стили под выделением.
final class MarkdownFormattingStateTests: XCTestCase {
    private func state(_ text: String, _ location: Int, _ length: Int = 0) -> MarkdownFormattingState {
        MarkdownFormattingState(presentation: MarkdownPresentationBuilder.parse(text, syntax: .init(strictMode: false)),
                                selection: NSRange(location: location, length: length))
    }

    func testParagraphKinds() {
        XCTAssertEqual(state("# Заг", 3).paragraph, .heading(1))
        XCTAssertEqual(state("- а\n- б", 5).paragraph, .bulletList)
        XCTAssertEqual(state("1. а\n2. б", 6).paragraph, .numberedList)
        XCTAssertEqual(state("- [ ] а", 7).paragraph, .taskList)
        XCTAssertEqual(state("> ц", 3).paragraph, .quote)
        XCTAssertEqual(state("```\nx\n```", 5).paragraph, .codeBlock)
        XCTAssertEqual(state("| a | b |\n|---|---|\n| c | d |", 2).paragraph, .table)
        XCTAssertEqual(state("обычный", 2).paragraph, .plain)
    }

    func testInlineStylesNeedSpanAroundSelection() {
        XCTAssertTrue(state("a **жир *кур* сив** b", 6).bold)
        XCTAssertTrue(state("a **жир** b", 4, 3).bold)
        XCTAssertFalse(state("a **жир** b", 0, 6).bold, "выделение выходит за элемент")
        XCTAssertTrue(state("a [л](u) b", 3).link)
        XCTAssertFalse(state("a **жир** b", 0).bold)
    }

    func testOutOfRangeSelectionGivesEmptyState() {
        XCTAssertEqual(state("текст", 99), MarkdownFormattingState())
    }
}
