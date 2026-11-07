import XCTest
@testable import LacEditor

/// Строчные команды и «Обычный текст» на контексте разбора: чистая логика без окна.
final class MarkdownInlineFormattingTests: XCTestCase {
    /// Применяет правку так же, как транзакция: части от конца к началу или одна замена.
    private func apply(_ text: String, _ selection: NSRange, _ command: MarkdownFormattingCommand) -> String? {
        let presentation = MarkdownPresentationBuilder.parse(text, syntax: .init(strictMode: false))
        let context = MarkdownInlineContext(presentation: presentation, strictMode: false)
        guard let edit = MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command,
                                                        strictMode: false, context: context) else { return nil }
        var result = text as NSString
        if let parts = edit.parts {
            XCTAssertNil(MarkdownEditTransaction.geometryRefusal(parts, textLength: text.utf16.count),
                         "части правки должны идти от конца к началу без пересечений: \(text.debugDescription)")
            for part in parts.sorted(by: { $0.range.location > $1.range.location }) {
                result = result.replacingCharacters(in: part.range, with: part.replacement) as NSString
            }
        } else {
            result = result.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        }
        return result as String
    }

    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

    func testBoldWrapsSelectionAndRemovesItWhenRepeated() {
        XCTAssertEqual(apply("привет мир", range(0, 6), .bold), "**привет** мир")
        XCTAssertEqual(apply("**привет** мир", range(2, 6), .bold), "привет мир")
    }

    func testBoldOverMixedSelectionLeavesOneOuterSpan() {
        XCTAssertEqual(apply("a **b** c", range(0, 9), .bold), "**a b c**")
    }

    func testPartialUnboldSplitsSpanAtWordBoundary() {
        XCTAssertEqual(apply("**привет мир**", range(2, 3), .bold), "при**вет мир**")
    }

    func testEdgeOfSpanNextToSpaceIsRefusedBecauseResultWouldNotParse() {
        XCTAssertNil(apply("**привет мир**", range(5, 3), .bold))
    }

    func testItalicRemovesStarsOfSelectedEmphasis() {
        XCTAssertEqual(apply("*курсив* x", range(1, 6), .italic), "курсив x")
    }

    func testEmojiSelectionIsWrappedWholly() {
        XCTAssertEqual(apply("😀 ok", range(0, 2), .bold), "**😀** ok")
    }

    func testRefusalsInCodeCodeBlockAndAcrossBlocks() {
        XCTAssertNil(apply("`код` x", range(1, 3), .bold))
        XCTAssertNil(apply("```\nкод\n```", range(5, 3), .bold))
        XCTAssertNil(apply("abc\n\ndef", range(1, 6), .bold))
    }

    func testLinkAddressIsNotFormatted() {
        XCTAssertNil(apply("[текст](url) т", range(8, 2), .bold))
    }

    func testTableCellFormatsButSelectionAcrossCellsIsRefused() {
        let table = "| a | b |\n|---|---|\n| c | d |"
        XCTAssertEqual(apply(table, range(2, 1), .bold), "| **a** | b |\n|---|---|\n| c | d |")
        XCTAssertNil(apply(table, range(2, 6), .bold))
    }

    func testCaretInsideSameStyleIsRefused() {
        XCTAssertNil(apply("**слово**", range(4, 0), .bold))
    }

    func testPlainTextStripsHeadingQuoteAndListMarkers() {
        XCTAssertEqual(apply("# Заголовок", range(3, 0), .plainText), "Заголовок")
        XCTAssertEqual(apply("> - пункт\r\n> - два", range(0, 17), .plainText), "пункт\r\nдва")
        XCTAssertEqual(apply("- [ ] задача", range(2, 0), .plainText), "задача")
        XCTAssertEqual(apply("> # h", range(0, 5), .plainText), "h")
        XCTAssertEqual(apply("1. один\n   продолжение\n2. два", range(0, 28), .plainText), "один\nпродолжение\nдва")
    }

    func testPlainTextRefusesCodeBlockAndKeepsPlainLineUnchanged() {
        XCTAssertNil(apply("```\n- x\n```", range(6, 0), .plainText))
        XCTAssertEqual(apply("просто текст", range(2, 0), .plainText), "просто текст")
    }

    func testPartialUnboldFromMiddleMakesTwoSpans() {
        XCTAssertEqual(apply("a **bcd** e", range(5, 1), .bold), "a **b**c**d** e")
    }

    func testItalicInsideBoldKeepsBold() {
        XCTAssertEqual(apply("a **bcd** e", range(5, 1), .italic), "a **b*c*d** e")
    }

    func testWrapRemovesInnerSpansOfSameKind() {
        XCTAssertEqual(apply("x **a** y **b** z", range(0, 17), .bold), "**x a y b z**")
    }

    func testInlineCodeUnwrapAndPartialCodeRefusal() {
        XCTAssertEqual(apply("a `код` b", range(3, 3), .inlineCode), "a код b")
        XCTAssertNil(apply("a `код` b", range(4, 1), .inlineCode))
    }

    func testLinkTextIsFormattedButAddressIsRefused() {
        XCTAssertEqual(apply("[текст](url) т", range(1, 5), .bold), "[**текст**](url) т")
        XCTAssertNil(apply("[текст](url) т", range(8, 2), .bold))
    }

    func testCRLFSelectionOnSecondLine() {
        XCTAssertEqual(apply("line1\r\nline2 word", range(13, 4), .bold), "line1\r\nline2 **word**")
    }

    func testPlainTextOnNestedListAndCaretInMiddleOfLine() {
        XCTAssertEqual(apply("- а\n  - б\n  - в", range(8, 0), .plainText), "- а\nб\n  - в")
        let text = "## Заголовок слов"
        let edit = MarkdownFormattingService.plainTextEdit(in: text as NSString, selection: range(8, 0), strictMode: false)
        XCTAssertEqual(edit?.replacement, "Заголовок слов")
        XCTAssertEqual(edit?.selectionRange, range(5, 0))
    }

    func testPlainTextRefusesInsideFormulaHTMLAndFrontMatter() {
        XCTAssertNil(apply("$$\n# x\n$$", range(3, 0), .plainText))
        XCTAssertNil(apply("$$\n- x\n$$", range(3, 0), .plainText))
        XCTAssertNil(apply("<div>\n# x\n</div>", range(7, 0), .plainText))
        XCTAssertNil(apply("---\n# x\n---\n\nтекст", range(5, 0), .plainText))
    }

    func testPlainTextHasActionName() {
        XCTAssertEqual(MarkdownFormattingCommand.plainText.actionName, L10n.tr("普通文本"))
    }
}
