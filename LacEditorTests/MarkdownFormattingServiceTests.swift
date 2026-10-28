import Foundation
import XCTest
@testable import LacEditor

final class MarkdownFormattingServiceTests: XCTestCase {
    private func apply(_ edit: MarkdownFormattingEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testInlineCommandsPreserveUnicodeSelectionAndToggle() throws {
        let text = "before 中文😀e\u{301} after"
        let selected = (text as NSString).range(of: "中文😀e\u{301}")
        for (command, marker) in [(MarkdownFormattingCommand.bold, "**"), (.italic, "*"), (.strikethrough, "~~")] {
            let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selected, command: command))
            let formatted = apply(insert, to: text)
            XCTAssertEqual(formatted, "before \(marker)中文😀e\u{301}\(marker) after")
            XCTAssertEqual((formatted as NSString).substring(with: insert.selectionRange), "中文😀e\u{301}")
            let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: command))
            XCTAssertEqual(apply(remove, to: formatted), text)
            XCTAssertEqual(remove.selectionRange, selected)
        }
    }

    func testEmptySelectionInsertsMarkersWithCaretInside() throws {
        let text = "ab😀cd"
        let selection = NSRange(location: 2, length: 0)
        for (command, marker) in [(MarkdownFormattingCommand.bold, "**"), (.italic, "*"), (.strikethrough, "~~"), (.inlineCode, "`")] {
            let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command))
            XCTAssertEqual(apply(edit, to: text), "ab\(marker)\(marker)😀cd")
            XCTAssertEqual(edit.selectionRange, NSRange(location: 2 + (marker as NSString).length, length: 0))
        }
    }

    func testCodeChoosesLongerFenceAndPreservesSpaces() throws {
        for selected in ["a`b", "`edge`", "text"] {
            let text = "x" + selected + "y"
            let range = NSRange(location: 1, length: (selected as NSString).length)
            let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: range, command: .inlineCode))
            let formatted = apply(insert, to: text)
            XCTAssertEqual((formatted as NSString).substring(with: insert.selectionRange), selected)
            let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: .inlineCode))
            XCTAssertEqual(apply(remove, to: formatted), text)
        }
    }

    func testOuterWhitespaceStaysOutsideAndMultipleParagraphsAreRejected() throws {
        let text = "left  word  right"
        let selection = (text as NSString).range(of: "  word  ")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .bold))
        let result = apply(edit, to: text)
        XCTAssertEqual(result, "left  **word**  right")
        XCTAssertTrue(MarkdownRenderer.render(result, darkMode: false).contains("<strong>word</strong>"))
        XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), "word")
        XCTAssertNil(MarkdownFormattingService.edit(in: "   " as NSString, selection: NSRange(location: 0, length: 3), command: .bold))
        let paragraphs = "first\r\n \r\nsecond"
        XCTAssertNil(MarkdownFormattingService.edit(in: paragraphs as NSString, selection: NSRange(location: 0, length: (paragraphs as NSString).length), command: .italic))
    }

    func testEscapedMarkersAreNeverRemoved() {
        for (text, command) in [("\\**word**", MarkdownFormattingCommand.bold), ("\\`word`", .inlineCode)] {
            let selection = (text as NSString).range(of: "word")
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command))
        }
    }

    func testEscapedInsertionBoundaryDoesNotChangeText() {
        let text = "\\word"
        let selection = (text as NSString).range(of: "word")
        for command in [MarkdownFormattingCommand.bold, .italic, .strikethrough, .inlineCode] {
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: command))
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: NSRange(location: selection.location, length: 0), command: command))
        }
        XCTAssertEqual(text, "\\word")
    }

    func testInlineClosingDelimiterAfterBackslashes() throws {
        let odd = "word\\"
        let oddRange = NSRange(location: 0, length: (odd as NSString).length)
        for command in [MarkdownFormattingCommand.bold, .italic, .strikethrough] {
            XCTAssertNil(MarkdownFormattingService.edit(in: odd as NSString, selection: oddRange, command: command))
        }
        XCTAssertNotNil(MarkdownFormattingService.edit(in: odd as NSString, selection: oddRange, command: .inlineCode))
        let even = "word\\\\"
        let evenRange = NSRange(location: 0, length: (even as NSString).length)
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: even as NSString, selection: evenRange, command: .bold))
        XCTAssertTrue(MarkdownRenderer.render(apply(edit, to: even), darkMode: false).contains("<strong>word\\</strong>"))
    }

    func testUnclosedQuotedFenceEndsWhenQuoteEnds() throws {
        let text = "> ```\n> inside\n\nafter"
        let inside = (text as NSString).range(of: "inside")
        let after = (text as NSString).range(of: "after")
        for command in [MarkdownFormattingCommand.heading(1), .quote] {
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: inside, command: command))
            XCTAssertNotNil(MarkdownFormattingService.edit(in: text as NSString, selection: after, command: command))
        }
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: after, command: .heading(1)))
        let rendered = MarkdownRenderer.render(apply(edit, to: text), darkMode: false)
        XCTAssertTrue(rendered.contains("<code>inside"))
        XCTAssertTrue(rendered.contains("<h1>after</h1>"))
    }

    func testBlockCommandsDoNotModifyFencedOrIndentedCode() throws {
        let text = "````swift\ninside\n```\nstill inside\n````\nafter"
        for line in ["inside", "still inside", "````"] {
            let selection = (text as NSString).range(of: line)
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(1)))
            XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .quote))
        }
        let after = (text as NSString).range(of: "after")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: after, command: .heading(1)))
        XCTAssertTrue(apply(edit, to: text).hasSuffix("# after"))
        XCTAssertNil(MarkdownFormattingService.edit(in: "    code" as NSString, selection: NSRange(location: 4, length: 0), command: .quote))
    }

    func testAmbiguousAdjacentMarkersAreNotRemoved() throws {
        let text = "***word***"
        let selection = (text as NSString).range(of: "word")
        let edit = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .bold))
        XCTAssertEqual(apply(edit, to: text), "*****word*****")
    }

    func testHeadingsToggleMultipleLinesAndPreserveLineEndings() throws {
        let text = "first\r\nsecond\rthird\nrest"
        let selection = NSRange(location: 0, length: ("first\r\nsecond\r" as NSString).length)
        let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(2)))
        let formatted = apply(insert, to: text)
        XCTAssertEqual(formatted, "## first\r\n## second\rthird\nrest")
        let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: .heading(2)))
        XCTAssertEqual(apply(remove, to: formatted), text)
    }

    func testHeadingMarkerFollowedByTabIsReplacedOrRemoved() throws {
        let text = "#\tTitle"
        let selection = (text as NSString).range(of: "Title")
        let change = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(2)))
        XCTAssertEqual(apply(change, to: text), "## Title")
        let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .heading(1)))
        XCTAssertEqual(apply(remove, to: text), "Title")
        XCTAssertTrue(MarkdownRenderer.render(text, darkMode: false).contains("<h1>Title</h1>"))
    }

    func testQuoteAddsAndRemovesOneLevelIncludingMixedLines() throws {
        let text = "> existing\nplain"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let insert = try XCTUnwrap(MarkdownFormattingService.edit(in: text as NSString, selection: selection, command: .quote))
        let formatted = apply(insert, to: text)
        XCTAssertEqual(formatted, "> > existing\n> plain")
        let remove = try XCTUnwrap(MarkdownFormattingService.edit(in: formatted as NSString, selection: insert.selectionRange, command: .quote))
        XCTAssertEqual(apply(remove, to: formatted), text)
    }

    func testRejectsInvalidRangesFenceLinesAndNestedHeadingChanges() {
        let text = "😀"
        XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: NSRange(location: 1, length: 0), command: .bold))
        XCTAssertNil(MarkdownFormattingService.edit(in: text as NSString, selection: NSRange(location: 4, length: 0), command: .bold))
        XCTAssertNil(MarkdownFormattingService.edit(in: "```swift" as NSString, selection: NSRange(location: 1, length: 0), command: .heading(1)))
        XCTAssertNil(MarkdownFormattingService.edit(in: "- item" as NSString, selection: NSRange(location: 3, length: 0), command: .heading(1)))
        XCTAssertNil(MarkdownFormattingService.edit(in: "text" as NSString, selection: NSRange(location: 0, length: 0), command: .heading(7)))
    }
}
