import Foundation
import XCTest
@testable import LacEditor

final class MarkdownNativeTableParserTests: XCTestCase {
    func testQuoteRangeTracksInsertionAtItsEndAndUndo() throws {
        let source = "> | A | B |\n> | --- | --- |\n> x"
        let original = MarkdownPresentationParser.parse(source)
        let table = try XCTUnwrap(original.tables.first)
        let quote = try XCTUnwrap(original.spans.first { $0.kind == .quote })
        let edit = NSRange(location: (source as NSString).length, length: 0)
        let changed = source + "|中😀"
        let updatedTable = try XCTUnwrap(MarkdownPresentationParser.parse(changed).tables.first)
        let updated = original.replacingTable(updatedTable, oldTable: table.range, edit: edit, replacementLength: ("|中😀" as NSString).length)
        let updatedQuote = try XCTUnwrap(updated.spans.first { $0.kind == .quote })
        XCTAssertEqual(NSMaxRange(updatedQuote.range), (changed as NSString).length)
        XCTAssertEqual(updatedQuote.markerRanges, quote.markerRanges)
        let undo = updated.replacingTable(table, oldTable: updatedTable.range,
            edit: NSRange(location: edit.location, length: ("|中😀" as NSString).length), replacementLength: 0)
        XCTAssertEqual(undo.spans.first { $0.kind == .quote }, quote)
        let redo = undo.replacingTable(updatedTable, oldTable: table.range, edit: edit, replacementLength: ("|中😀" as NSString).length)
        XCTAssertEqual(redo.spans.first { $0.kind == .quote }, updatedQuote)
    }
    func testTablesInQuotesAndListsKeepCellSourceRanges() throws {
        for newline in ["\n", "\r\n"] {
            let quote = ["> | A | B |", "> | --- | --- |", "> | 中😀 | x |"].joined(separator: newline)
            let list = ["- | C | D |", "  | --- | --- |", "  | u | v |", "- next"].joined(separator: newline)
            let source = "before" + newline + newline + quote + newline + newline + list
            let tables = MarkdownPresentationParser.parse(source).tables
            XCTAssertEqual(tables.count, 2)
            guard tables.count == 2 else { continue }
            XCTAssertEqual(tables[0].rows.flatMap(\.cells).map { (source as NSString).substring(with: $0.range) },
                           [" A ", " B ", " 中😀 ", " x "])
            XCTAssertEqual(tables[1].rows.flatMap(\.cells).map { (source as NSString).substring(with: $0.range) },
                           [" C ", " D ", " u ", " v "])
            XCTAssertFalse((source as NSString).substring(with: tables[1].range).contains("next"))
        }
    }
    func testConfirmedTableRangesPreserveUnicodeAndLineEndings() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let table = ["| 中文😀 | B |", "| :--- | ---: |", "| `a\\|b` | e\u{301} |"].joined(separator: ending)
            let source = "before" + ending + ending + table + ending + ending + "after"
            let text = source as NSString
            let result = MarkdownPresentationParser.parse(source)
            let parsed = try XCTUnwrap(result.tables.first)
            XCTAssertEqual(result.tables.count, 1)
            XCTAssertEqual(text.substring(with: parsed.range), table)
            XCTAssertEqual(text.substring(with: parsed.delimiterRange), "| :--- | ---: |")
            XCTAssertEqual(parsed.alignments, [.left, .right])
            XCTAssertEqual(parsed.rows.count, 2)
            XCTAssertEqual(parsed.rows.map { $0.cells.count }, [2, 2])
            XCTAssertEqual(parsed.rows.flatMap(\.cells).map { text.substring(with: $0.range) },
                           [" 中文😀 ", " B ", " `a\\|b` ", " e\u{301} "])
            XCTAssertEqual(parsed.rows.flatMap(\.cells).map(\.column), [0, 1, 0, 1])
            XCTAssertTrue(MarkdownRenderer.render(source, darkMode: false).contains("<table>"))
        }
    }

    func testUnsupportedShapesAndCodeStayUnmapped() {
        for source in ["```\n| A | B |\n| --- | --- |\n| x | y |\n```",
                       "| A | B |\n| --- | --- |\n| x\t | y |"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).tables.isEmpty, source)
        }
    }

    func testWideTablePreservesEveryCellRange() throws {
        let columns = 400
        let header = "|" + (0..<columns).map { " H\($0) |" }.joined()
        let separator = "|" + String(repeating: " --- |", count: columns)
        let data = "|" + (0..<columns).map { " 中😀\($0) |" }.joined()
        let source = [header, separator, data].joined(separator: "\r\n")
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        XCTAssertEqual(table.rows.map { $0.cells.count }, [columns, columns])
        let text = source as NSString
        for index in 0..<columns {
            XCTAssertEqual(text.substring(with: table.rows[1].cells[index].range), " 中😀\(index) ")
        }
    }

    func testHeaderOnlyAndAbsentOuterPipes() throws {
        let source = "A | B\n--- | :---:\n"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.alignments, [.unspecified, .center])
        XCTAssertEqual(table.rows[0].cells.map { (source as NSString).substring(with: $0.range) }, ["A ", " B"])
    }
}
