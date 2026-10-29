import Foundation
import XCTest
@testable import LacEditor

final class MarkdownTableEditingTests: XCTestCase {
    func testMoveMultiplePositionsUsesOneReplacementAndKeepsContainer() throws {
        let source = "> | A | B | C |\r\n> | --- | --- | --- |\r\n> | one | x | p |\r\n> | two | y | q |\r\n> | three | z | r |\r\n\r\nafter"
        let text = source as NSString
        let row = try XCTUnwrap(MarkdownTableEditingService.move(in: text, selection: NSRange(location: text.range(of: "one").location, length: 0), rows: true, positions: 2))
        let moved = text.replacingCharacters(in: row.range, with: row.replacement)
        XCTAssertEqual(moved, "> | A | B | C |\r\n> | --- | --- | --- |\r\n> | two | y | q |\r\n> | three | z | r |\r\n> | one | x | p |\r\n\r\nafter")
        XCTAssertTrue(NSLocationInRange(row.selectionRange.location, (moved as NSString).range(of: "one")))
        let column = try XCTUnwrap(MarkdownTableEditingService.move(in: text, selection: NSRange(location: text.range(of: "A").location, length: 0), rows: false, positions: 2))
        let movedColumn = text.replacingCharacters(in: column.range, with: column.replacement)
        XCTAssertTrue(movedColumn.contains("> | B | C | A |"))
        XCTAssertTrue(movedColumn.contains("> | x | p | one |"))
        XCTAssertTrue(movedColumn.hasSuffix("\r\n\r\nafter"))
        XCTAssertNil(MarkdownTableEditingService.move(in: text, selection: NSRange(location: text.range(of: "one").location, length: 0), rows: true, positions: -1))
        let uneven = "| A | B | C |\n| --- | --- | --- |\n| x |\n| p | q | r | extra |" as NSString
        let unevenMove = try XCTUnwrap(MarkdownTableEditingService.move(in: uneven,
            selection: NSRange(location: uneven.range(of: "A").location, length: 0), rows: false, positions: 2))
        let unevenResult = uneven.replacingCharacters(in: unevenMove.range, with: unevenMove.replacement)
        XCTAssertEqual(unevenResult, "| B | C | A |\n| --- | --- | --- |\n||| x |\n| q | r | p | extra |")
        XCTAssertFalse(MarkdownRenderer.renderPage(unevenResult, darkMode: false).body.contains("extra"))
    }
    func testNestedTableOperationsKeepContainerPrefixesAndSibling() throws {
        for newline in ["\n", "\r\n"] {
            let quote = ["> > | A | B |", "> > | --- | --- |", "> > | 中文😀 | x |"].joined(separator: newline)
            let quoted = try apply(quote, at: "中文", command: .insertColumnAfter).0
            XCTAssertEqual(quoted, ["> > | A |   | B |", "> > | --- | --- | --- |", "> > | 中文😀 |   | x |"].joined(separator: newline))
            XCTAssertTrue(MarkdownRenderer.renderPage(quoted, darkMode: false).body.contains("<table>"))
            let source = ["- | A | B |", "  | --- | --- |", "  | 中文😀 | x |", "- sibling"].joined(separator: newline)
            let inserted = try apply(source, at: "中文", command: .insertRowAfter).0
            XCTAssertEqual(inserted, ["- | A | B |", "  | --- | --- |", "  | 中文😀 | x |", "  |   |   |", "- sibling"].joined(separator: newline))
            XCTAssertTrue(MarkdownRenderer.renderPage(inserted, darkMode: false).body.contains("<table>"))
        }
    }
    func testIrregularRowsKeepSourceDuringRowOperationsAndAlignment() throws {
        for newline in ["\n", "\r\n"] {
            let header = ["| A | B |", "| --- | --- |"].joined(separator: newline)
            let short = "| 中文😀 |"
            let extra = "| x | y | hidden |"
            let source = [header, short, extra].joined(separator: newline)
            XCTAssertEqual(try apply(source, at: "中文", command: .moveRowDown).0,
                           [header, extra, short].joined(separator: newline))
            XCTAssertEqual(try apply(source, at: "中文", command: .deleteRow).0,
                           [header, extra].joined(separator: newline))
            XCTAssertEqual(try apply(source, at: "中文", command: .insertRowBefore).0,
                           [header, "|   |   |", short, extra].joined(separator: newline))
            XCTAssertEqual(try apply(source, at: "中文", command: .align(.right)).0,
                           ["| A | B |", "| ---: | --- |", short, extra].joined(separator: newline))
        }
    }

    func testInsertRowAfterSingleColumnWithoutOuterPipe() throws {
        let source = "A|\r\n---|\r\nx"
        let (result, selection) = try apply(source, at: "x", command: .insertRowAfter)
        XCTAssertEqual(result, source + "\r\n|   |")
        XCTAssertEqual(selection.location, (source as NSString).length + 4)
        XCTAssertEqual(MarkdownPresentationParser.parse(result).tables.first?.rows.count, 3)
        XCTAssertTrue(MarkdownRenderer.renderPage(result, darkMode: false).body.contains("<tbody>"))
    }

    func testIrregularColumnOperationsPreserveExtraTail() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["| A | B |", "| --- | --- |", "| 中文😀 |", "| p | q | hidden |"].joined(separator: newline)
            let cases: [(MarkdownTableCommand, [String])] = [
                (.insertColumnAfter, ["| A |   | B |", "| --- | --- | --- |", "| 中文😀 |   |", "| p |   | q | hidden |"]),
                (.deleteColumn, ["| B |", "| --- |", "||", "| q | hidden |"]),
                (.moveColumnRight, ["| B | A |", "| --- | --- |", "|| 中文😀 |", "| q | p | hidden |"])
            ]
            for (command, expected) in cases {
                let (result, selection) = try apply(source, at: "A", command: command)
                XCTAssertEqual(result, expected.joined(separator: newline))
                XCTAssertLessThanOrEqual(NSMaxRange(selection), (result as NSString).length)
                let body = MarkdownRenderer.renderPage(result, darkMode: false).body
                XCTAssertTrue(body.contains("<table>"))
                XCTAssertFalse(body.contains("hidden"))
            }
        }
    }

    private func apply(_ source: String, at needle: String, command: MarkdownTableCommand) throws -> (String, NSRange) {
        let text = source as NSString
        let selected = text.range(of: needle)
        XCTAssertNotEqual(selected.location, NSNotFound)
        let edit = try XCTUnwrap(MarkdownTableEditingService.edit(in: text, selection: NSRange(location: selected.location, length: 0), command: command))
        let result = text.replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertLessThanOrEqual(NSMaxRange(edit.selectionRange), (result as NSString).length)
        return (result, edit.selectionRange)
    }

    func testCreateSeparateTableAtDocumentBoundaries() throws {
        for newline in ["\n", "\r\n"] {
            let table = ["|   |   |", "| --- | --- |", "|   |   |"].joined(separator: newline)
            let cases: [(String, Int, String)] = [
                ("", 0, table),
                (newline + "after", 0, table + newline + newline + "after"),
                ("before" + newline, (("before" + newline) as NSString).length, "before" + newline + newline + table),
                ("before" + newline + newline + "after", (("before" + newline) as NSString).length, "before" + newline + newline + table + newline + newline + "after")
            ]
            for (source, location, expected) in cases {
                let text = source as NSString
                let edit = try XCTUnwrap(MarkdownTableEditingService.edit(in: text, selection: NSRange(location: location, length: 0), command: .create(rows: 1, columns: 2)))
                let result = text.replacingCharacters(in: edit.range, with: edit.replacement)
                XCTAssertEqual(result, expected)
                XCTAssertTrue(MarkdownRenderer.render(result, darkMode: false).contains("<table>"))
            }
        }
    }

    func testCreateRejectsExistingBlockContexts() {
        for source in ["```\n\n```", "- item\n\n  continued", "> text\n> \n> more", "    code\n    \n    code"] {
            let text = source as NSString
            let firstBreak = text.range(of: "\n")
            let location = firstBreak.location + 1
            XCTAssertNil(MarkdownTableEditingService.edit(in: text, selection: NSRange(location: location, length: 0), command: .create(rows: 1, columns: 2)), source)
        }
    }

    func testRowOperationsAndLastRow() throws {
        let source = "| A | B |\n| --- | --- |\n| one | two |\n| three | four |"
        let inserted = try apply(source, at: "one", command: .insertRowAfter).0
        XCTAssertEqual(inserted, "| A | B |\n| --- | --- |\n| one | two |\n|   |   |\n| three | four |")
        XCTAssertEqual(try apply(source, at: "three", command: .moveRowUp).0,
                       "| A | B |\n| --- | --- |\n| three | four |\n| one | two |")
        XCTAssertEqual(try apply(source, at: "one", command: .moveRowDown).0,
                       "| A | B |\n| --- | --- |\n| three | four |\n| one | two |")
        let oneRow = "| A | B |\r\n| --- | --- |\r\n| one | two |"
        XCTAssertEqual(try apply(oneRow, at: "one", command: .deleteRow).0, "| A | B |\r\n| --- | --- |")
        XCTAssertEqual(try apply(oneRow, at: "one", command: .insertRowBefore).0,
                       "| A | B |\r\n| --- | --- |\r\n|   |   |\r\n| one | two |")
    }

    func testInsertFirstBodyRowAfterHeader() throws {
        for ending in ["\n", "\r\n"] {
            let source = "| A | B |" + ending + "| --- | --- |"
            let (result, selection) = try apply(source, at: "A", command: .insertRowAfter)
            XCTAssertEqual(result, source + ending + "|   |   |")
            XCTAssertEqual(selection.location, (source as NSString).length + (ending as NSString).length + 2)
            XCTAssertTrue(MarkdownRenderer.render(result, darkMode: false).contains("<tbody>"))
        }
    }

    func testColumnOperationsAndAlignment() throws {
        let source = "A | B\n--- | :---:\n中😀 | **two**\n"
        XCTAssertEqual(try apply(source, at: "中", command: .insertColumnAfter).0,
                       "A |   | B\n--- | --- | :---:\n中😀 |   | **two**\n")
        XCTAssertEqual(try apply(source, at: "two", command: .insertColumnBefore).0,
                       "A |   | B\n--- | --- | :---:\n中😀 |   | **two**\n")
        XCTAssertEqual(try apply(source, at: "中", command: .deleteColumn).0,
                       " B|\n :---:|\n **two**|\n")
        XCTAssertEqual(try apply(source, at: "中", command: .moveColumnRight).0,
                       " B|A \n :---:|--- \n **two**|中😀 \n")
        XCTAssertEqual(try apply(source, at: "two", command: .moveColumnLeft).0,
                       " B|A \n :---:|--- \n **two**|中😀 \n")
        XCTAssertEqual(try apply(source, at: "中", command: .align(.right)).0,
                       "A | B\n---: | :---:\n中😀 | **two**\n")
        XCTAssertEqual(try apply(source, at: "中", command: .align(.left)).0,
                       "A | B\n:--- | :---:\n中😀 | **two**\n")
        XCTAssertEqual(try apply(source, at: "two", command: .align(.unspecified)).0,
                       "A | B\n--- | ---\n中😀 | **two**\n")
        let single = "| A |\n| --- |\n| x |" as NSString
        XCTAssertNil(MarkdownTableEditingService.edit(in: single, selection: NSRange(location: single.range(of: "x").location, length: 0), command: .deleteColumn))
    }

    func testEscapedPipesAndInlineCodeFollowTableSyntax() throws {
        let source = "| A | B |\n| --- | --- |\n| `a\\|b` | `x|y` |"
        // GFM splits the unescaped pipe even inside a code span; this uneven row is not rewritten.
        let text = source as NSString
        let location = text.range(of: "a").location
        XCTAssertNil(MarkdownTableEditingService.edit(in: text, selection: NSRange(location: location, length: 0), command: .deleteColumn))
        let valid = "| A | B |\n| --- | --- |\n| `a\\|b` | x |"
        XCTAssertEqual(try apply(valid, at: "x", command: .align(.center)).0,
                       "| A | B |\n| --- | :---: |\n| `a\\|b` | x |")
    }

    func testUnsupportedContextAndBoundary() {
        let fenced = "```\n| A | B |\n| --- | --- |\n| x | y |\n```" as NSString
        XCTAssertNil(MarkdownTableEditingService.edit(in: fenced, selection: NSRange(location: fenced.range(of: "x").location, length: 0), command: .deleteRow))
        let source = "| A | B |\n| --- | --- |\n| 😀 | y |" as NSString
        let emoji = source.range(of: "😀")
        XCTAssertNil(MarkdownTableEditingService.edit(in: source, selection: NSRange(location: emoji.location + 1, length: 0), command: .deleteRow))
    }
}
