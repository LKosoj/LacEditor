import Foundation
import XCTest
@testable import LacEditor

final class LineEditingServiceTests: XCTestCase {
    /// Применяет правку к копии текста; возвращает новый текст и выделение.
    private func apply(_ text: String, _ selection: NSRange, _ command: LineEditingCommand,
                       syntax: CommentSyntax? = nil) -> (String, NSRange)? {
        guard let edit = LineEditingService.edit(in: text as NSString, selection: selection, command: command,
                                                 commentSyntax: syntax) else { return nil }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        return (result as String, edit.selectionRange)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    func testDuplicateLineKeepsEolAndMovesCaret() throws {
        var result = try XCTUnwrap(apply("a\nb", caret(2), .duplicate))
        XCTAssertEqual(result.0, "a\nb\nb")
        XCTAssertEqual(result.1, caret(4))
        result = try XCTUnwrap(apply("a\r\nb\r\n", caret(0), .duplicate))
        XCTAssertEqual(result.0, "a\r\na\r\nb\r\n")
        XCTAssertEqual(result.1, caret(3))
        result = try XCTUnwrap(apply("a\nb\nc", NSRange(location: 0, length: 3), .duplicate))
        XCTAssertEqual(result.0, "a\nb\na\nb\nc")
        result = try XCTUnwrap(apply("", caret(0), .duplicate))
        XCTAssertEqual(result.0, "\n")
    }

    func testDuplicateLastLineWithoutNewlineUsesDocumentEol() throws {
        let result = try XCTUnwrap(apply("a\r\nb", caret(3), .duplicate))
        XCTAssertEqual(result.0, "a\r\nb\r\nb")
    }

    func testMoveUpDown() throws {
        var result = try XCTUnwrap(apply("a\nb\nc", caret(2), .moveUp))
        XCTAssertEqual(result.0, "b\na\nc")
        XCTAssertEqual(result.1, caret(0))
        result = try XCTUnwrap(apply("a\nb\nc", caret(0), .moveDown))
        XCTAssertEqual(result.0, "b\na\nc")
        XCTAssertEqual(result.1, caret(2))
        XCTAssertNil(apply("a\nb", caret(0), .moveUp))
        XCTAssertNil(apply("a\nb", caret(2), .moveDown))
        XCTAssertEqual(try XCTUnwrap(apply("a\nb", caret(2), .moveUp)).0, "b\na")
        XCTAssertEqual(try XCTUnwrap(apply("b\na", caret(0), .moveDown)).0, "a\nb")
        XCTAssertNil(apply("a\nb\n", caret(4), .moveDown))
        XCTAssertEqual(try XCTUnwrap(apply("a\r\nb\r\nc", caret(0), .moveDown)).0, "b\r\na\r\nc")
        XCTAssertEqual(try XCTUnwrap(apply("a\rb\rc", caret(2), .moveUp)).0, "b\ra\rc")
        XCTAssertEqual(try XCTUnwrap(apply("a\r\nb\nc", caret(3), .moveUp)).0, "b\r\na\nc")
        result = try XCTUnwrap(apply("x\na\nb\ny", NSRange(location: 2, length: 3), .moveUp))
        XCTAssertEqual(result.0, "a\nb\nx\ny")
        XCTAssertEqual(result.1, NSRange(location: 0, length: 3))
    }

    func testSelectionEndingAtColumnZeroExcludesNextLine() throws {
        let selection = NSRange(location: 0, length: 2)
        XCTAssertEqual(try XCTUnwrap(apply("a\nb\nc", selection, .deleteLine)).0, "b\nc")
        XCTAssertEqual(try XCTUnwrap(apply("a\nb\nc", selection, .moveDown)).0, "b\na\nc")
    }

    func testDeleteLine() throws {
        var result = try XCTUnwrap(apply("a\nb\nc", caret(2), .deleteLine))
        XCTAssertEqual(result.0, "a\nc")
        XCTAssertEqual(result.1, caret(2))
        XCTAssertEqual(try XCTUnwrap(apply("a\nb\nc", caret(0), .deleteLine)).0, "b\nc")
        result = try XCTUnwrap(apply("a\nb", caret(2), .deleteLine))
        XCTAssertEqual(result.0, "a")
        XCTAssertEqual(result.1, caret(1))
        XCTAssertEqual(try XCTUnwrap(apply("a", caret(1), .deleteLine)).0, "")
        XCTAssertNil(apply("", caret(0), .deleteLine))
        XCTAssertEqual(try XCTUnwrap(apply("a\r\nb\r\nc", caret(3), .deleteLine)).0, "a\r\nc")
    }

    func testJoinLines() throws {
        var result = try XCTUnwrap(apply("a\n   b\nc", caret(0), .join))
        XCTAssertEqual(result.0, "a b\nc")
        XCTAssertEqual(result.1, caret(1))
        result = try XCTUnwrap(apply("a\n b\n c", NSRange(location: 0, length: 7), .join))
        XCTAssertEqual(result.0, "a b c")
        XCTAssertEqual(try XCTUnwrap(apply("a\n\nb", caret(0), .join)).0, "a\nb")
        XCTAssertNil(apply("a\nb", caret(2), .join))
        XCTAssertEqual(try XCTUnwrap(apply("a\nb\n", caret(0), .join)).0, "a b\n")
    }

    func testSortAscendingDescending() throws {
        XCTAssertEqual(try XCTUnwrap(apply("b\na\nc", caret(0), .sortAscending)).0, "a\nb\nc")
        XCTAssertEqual(try XCTUnwrap(apply("b\na\nc", caret(0), .sortDescending)).0, "c\nb\na")
        XCTAssertEqual(try XCTUnwrap(apply("file10\nfile2", caret(0), .sortAscending)).0, "file2\nfile10")
        XCTAssertEqual(try XCTUnwrap(apply("b\r\na\nc", caret(0), .sortAscending)).0, "a\r\nb\nc")
        XCTAssertEqual(try XCTUnwrap(apply("b\na\n", caret(0), .sortAscending)).0, "a\nb\n")
        let partial = try XCTUnwrap(apply("z\nc\nb\na", NSRange(location: 2, length: 3), .sortAscending))
        XCTAssertEqual(partial.0, "z\nb\nc\na")
        XCTAssertNil(apply("a\nb\nc", caret(0), .sortAscending))
        XCTAssertNil(apply("a", caret(0), .sortAscending))
    }

    func testSortIsStableForEqualLines() throws {
        let text = "b\na\nb\na"
        let ascending = try XCTUnwrap(apply(text, NSRange(location: 0, length: text.utf16.count), .sortAscending))
        XCTAssertEqual(ascending.0, "a\na\nb\nb")
    }

    func testUnicodeLinesUseUTF16() throws {
        var result = try XCTUnwrap(apply("😀中文\nb", caret(2), .duplicate))
        XCTAssertEqual(result.0, "😀中文\n😀中文\nb")
        XCTAssertEqual(result.1, caret(2 + 5))
        result = try XCTUnwrap(apply("😀中文\nb", caret(2), .moveDown))
        XCTAssertEqual(result.0, "b\n😀中文")
        XCTAssertEqual(try XCTUnwrap(apply("😀中文\nb", caret(1), .deleteLine)).0, "b")
        // U+2028 остаётся содержимым строки
        XCTAssertEqual(try XCTUnwrap(apply("a\u{2028}b\nc", caret(3), .duplicate)).0, "a\u{2028}b\na\u{2028}b\nc")
    }

    func testToggleLineComment() throws {
        let swift = EditorLanguage.swift.commentSyntax
        var result = try XCTUnwrap(apply("foo\n  bar", NSRange(location: 0, length: 9), .toggleComment, syntax: swift))
        XCTAssertEqual(result.0, "// foo\n//   bar")
        result = try XCTUnwrap(apply("  foo\n  bar", NSRange(location: 0, length: 11), .toggleComment, syntax: swift))
        XCTAssertEqual(result.0, "  // foo\n  // bar")
        XCTAssertEqual(try XCTUnwrap(apply("// foo\n//bar", NSRange(location: 0, length: 12), .toggleComment, syntax: swift)).0,
                       "foo\nbar")
        XCTAssertEqual(try XCTUnwrap(apply("// a\n\n// b", NSRange(location: 0, length: 9), .toggleComment, syntax: swift)).0,
                       "a\n\nb")
        XCTAssertEqual(try XCTUnwrap(apply("// a\nb", NSRange(location: 0, length: 6), .toggleComment, syntax: swift)).0,
                       "// // a\n// b")
        XCTAssertNil(apply("\n  \n", NSRange(location: 0, length: 4), .toggleComment, syntax: swift))
        XCTAssertEqual(try XCTUnwrap(apply("\tfoo", caret(2), .toggleComment, syntax: swift)).0, "\t// foo")
        result = try XCTUnwrap(apply("foo", caret(3), .toggleComment, syntax: swift))
        XCTAssertEqual(result.1, caret(6))
        XCTAssertEqual(try XCTUnwrap(apply("x", caret(0), .toggleComment, syntax: .line("#"))).0, "# x")
        XCTAssertEqual(try XCTUnwrap(apply("x", caret(0), .toggleComment, syntax: .line("--"))).0, "-- x")
        XCTAssertNil(apply("x", caret(0), .toggleComment, syntax: nil))
    }

    func testToggleBlockComment() throws {
        let html = EditorLanguage.html.commentSyntax
        let text = "a\n\nb"
        let commented = try XCTUnwrap(apply(text, NSRange(location: 0, length: 4), .toggleComment, syntax: html))
        XCTAssertEqual(commented.0, "<!-- a -->\n\n<!-- b -->")
        let restored = try XCTUnwrap(apply(commented.0, NSRange(location: 0, length: commented.0.utf16.count),
                                           .toggleComment, syntax: html))
        XCTAssertEqual(restored.0, text)
        let css = EditorLanguage.css.commentSyntax
        XCTAssertEqual(try XCTUnwrap(apply("a: b;", caret(0), .toggleComment, syntax: css)).0, "/* a: b; */")
        let spaced = try XCTUnwrap(apply("a  ", caret(0), .toggleComment, syntax: css))
        XCTAssertEqual(try XCTUnwrap(apply(spaced.0, caret(0), .toggleComment, syntax: css)).0, "a  ")
    }

    func testCommentSyntaxPerLanguage() {
        for language in EditorLanguage.allCases {
            switch language {
            case .swift, .javascript, .typescript, .cFamily: XCTAssertEqual(language.commentSyntax, .line("//"))
            case .python, .shell, .yaml: XCTAssertEqual(language.commentSyntax, .line("#"))
            case .sql: XCTAssertEqual(language.commentSyntax, .line("--"))
            case .html, .markdown: XCTAssertEqual(language.commentSyntax, .block(open: "<!--", close: "-->"))
            case .css: XCTAssertEqual(language.commentSyntax, .block(open: "/*", close: "*/"))
            case .json, .plainText: XCTAssertNil(language.commentSyntax)
            }
        }
    }

    func testInvalidSelectionReturnsNil() {
        XCTAssertNil(apply("a", NSRange(location: NSNotFound, length: 0), .duplicate))
        XCTAssertNil(apply("a", NSRange(location: 5, length: 0), .duplicate))
        XCTAssertNil(apply("a", NSRange(location: 0, length: 5), .deleteLine))
    }

    func testServiceDoesNotMutateInputAndDuplicateThenDeleteRoundTrips() throws {
        let source = NSMutableString(string: "a\nb")
        _ = LineEditingService.edit(in: source, selection: caret(0), command: .duplicate)
        XCTAssertEqual(source as String, "a\nb")
        let duplicated = try XCTUnwrap(apply("a\nb", caret(0), .duplicate))
        XCTAssertEqual(try XCTUnwrap(apply(duplicated.0, duplicated.1, .deleteLine)).0, "a\nb")
    }

    func testActionNamesAreLocalized() {
        XCTAssertEqual(LineEditingCommand.toggleComment.actionName, L10n.tr("切换注释"))
    }
}
