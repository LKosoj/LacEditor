import Foundation
import XCTest
import cmark_gfm
@testable import LacEditor

final class MarkdownEmojiCandidateExtractorTests: XCTestCase {
    private func extract(_ text: String, cancelled: Bool = false) throws -> [MarkdownEmojiCandidateExtractor.Candidate] {
        let options = CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES
        return try XCTUnwrap(MarkdownMathExtension.withDocument(text, options: options) { root, math, _ in
            let source = MarkdownPresentationParser.Source(text, textOrigins: MarkdownMathExtension.textOrigins(in: math))
            return MarkdownEmojiCandidateExtractor.candidates(in: root, source: source, text: text as NSString, isCancelled: { cancelled })
        })
    }

    func testPresentationCollectsCandidatesFromItsDocumentAndInvalidatesEditedTable() throws {
        let text = "中😀 :smile:\r\n\r\n| H |\r\n|---|\r\n| :heart: |\r\n\r\n:smile:"
        let raw = text as NSString
        XCTAssertTrue(MarkdownPresentationParser.parse(text).emojiCandidates.isEmpty)
        let presentation = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true)
        XCTAssertEqual(presentation.emojiCandidates.map(\.name), ["smile", "heart", "smile"])
        XCTAssertEqual(presentation.emojiCandidates.map { raw.substring(with: $0.range) }, [":smile:", ":heart:", ":smile:"])
        let table = try XCTUnwrap(presentation.tables.first)
        let edit = raw.range(of: ":heart:")
        let updated = presentation.replacingTable(table, oldTable: table.range, edit: edit, replacementLength: edit.length + 1)
        XCTAssertEqual(updated.emojiCandidates.map(\.name), ["smile", "smile"])
        XCTAssertEqual(updated.emojiCandidates.last?.range.location, presentation.emojiCandidates.last!.range.location + 1)
    }

    func testPresentationCandidatesFollowSourceOrderWithFootnotes() {
        let text = "[^1]: :heart:\n\n:smile: [^1]"
        let result = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true)
        XCTAssertEqual(result.emojiCandidates.map(\.name), ["heart", "smile"])
        let locations = result.emojiCandidates.map { $0.range.location }
        XCTAssertEqual(locations, locations.sorted())
    }

    func testTableDisplayMapsEmojiAfterEscapedPipeAndFormatting() throws {
        let text = "| H |\r\n|---|\r\n| 中😀\\|x **:smile:** :heart: |"
        let result = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true)
        let cell = try XCTUnwrap(result.tables.first?.rows.last?.cells.first)
        let display = try XCTUnwrap(cell.displayText) as NSString
        let raw = text as NSString
        let mapped = cell.displayRuns.compactMap { run -> (NSRange, NSRange)? in
            guard case let .tableEmoji(relative) = run.kind else { return nil }
            return (run.range, NSRange(location: cell.range.location + relative.location, length: relative.length))
        }
        XCTAssertEqual(mapped.map { display.substring(with: $0.0) }, [":smile:", ":heart:"])
        XCTAssertEqual(mapped.map { raw.substring(with: $0.1) }, [":smile:", ":heart:"])
        XCTAssertEqual(mapped.map { $0.1 }, result.emojiCandidates.map(\.range))
    }

    func testHeadingEmojiRangesKeepCodeAndAnchorsUnchanged() throws {
        let text = "# 中😀 :smile: `:smile:` **:heart:**\r\n"
        let presentation = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true)
        let heading = try XCTUnwrap(presentation.headings.first)
        XCTAssertEqual(heading.title, "中😀 :smile: :smile: :heart:")
        XCTAssertEqual(heading.emoji.map(\.name), ["smile", "heart"])
        let title = heading.title as NSString
        XCTAssertEqual(heading.emoji.map { title.substring(with: $0.range) }, [":smile:", ":heart:"])
        let updated = presentation.resolvingHeadingEmoji(["smile": "😄", "heart": "❤️"])
        let resolved = try XCTUnwrap(updated.headings.first)
        XCTAssertEqual(resolved.renderedTitle, "中😀 😄 :smile: ❤️")
        XCTAssertEqual(resolved.title, heading.title)
        XCTAssertTrue(resolved.sameSource(as: heading))
        XCTAssertEqual(resolved.id, heading.id)
    }

    func testConfirmedUnderlineAllowsEmojiButAmbiguousHTMLDoesNot() throws {
        let text = ":smile: <u>:heart:</u> :smile:\n\n:smile: <span>:heart:</span>"
        let candidates = try extract(text)
        XCTAssertEqual(candidates.map(\.name), ["smile", "heart", "smile"])
        let raw = text as NSString
        XCTAssertEqual(candidates.map { raw.substring(with: $0.range) }, [":smile:", ":heart:", ":smile:"])
    }

    func testConfirmedTextRangesExcludeEscapesCodeAndURLs() throws {
        let text = "中😀 a:smile:b \\:heart: :unknown: `:smile:` [ok :heart:](https://example.com/:smile:) <https://example.com/:smile:>\r\n\r\n| H |\r\n|---|\r\n| a\\|b :+1: |\r\n\r\noutside <span>:heart:</span>"
        let raw = text as NSString
        let candidates = try extract(text)
        XCTAssertEqual(candidates.map(\.name), ["smile", "unknown", "heart", "+1"])
        XCTAssertEqual(candidates.map { raw.substring(with: $0.range) }, [":smile:", ":unknown:", ":heart:", ":+1:"])
        XCTAssertEqual(candidates.first?.range.location, raw.range(of: ":smile:").location)
        XCTAssertTrue(try extract(text, cancelled: true).isEmpty)
    }

    func testAdjacentAndBackslashParityUseOriginalSource() throws {
        let text = "::smile:: :heart::smile: \\\\:smile: \\:smile:"
        let raw = text as NSString
        let candidates = try extract(text)
        XCTAssertEqual(candidates.map(\.name), ["smile", "heart", "smile", "smile"])
        XCTAssertTrue(candidates.allSatisfy { raw.substring(with: $0.range) == ":\($0.name):" })
    }

    func testLongTableCellMappingRespondsToCancellation() throws {
        let text = "| H |\n|---|\n| " + String(repeating: "a", count: 10_000) + " |"
        let options = CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS
        let stopped = try XCTUnwrap(MarkdownMathExtension.withDocument(text, options: options) { root, math, _ -> Bool in
            guard let table = cmark_node_first_child(root), let header = cmark_node_first_child(table),
                  let row = cmark_node_next(header), let cell = cmark_node_first_child(row) else { return false }
            let source = MarkdownPresentationParser.Source(text, textOrigins: MarkdownMathExtension.textOrigins(in: math))
            var checks = 0
            return source.tableCellPositions(cell, isCancelled: { checks += 1; return checks > 50 }) == nil && checks > 50
        })
        XCTAssertTrue(stopped)
    }
}
