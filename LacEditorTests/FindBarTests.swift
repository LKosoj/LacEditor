import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class FindBarTests: XCTestCase {
    private func ranges(_ text: String, _ query: String, _ options: TextSearchService.Options) throws -> [String] {
        let ns = text as NSString
        return try TextSearchService.allRanges(in: text, query: query, options: options).map { ns.substring(with: $0) }
    }

    func testRegexRangesAreUTF16AndSkipEmptyMatches() throws {
        let text = "a😀b 中文 ab"
        let options = TextSearchService.Options(usesRegex: true)
        let found = try TextSearchService.allRanges(in: text, query: #"中."#, options: options)
        XCTAssertEqual(found, [NSRange(location: 5, length: 2)])
        XCTAssertEqual((text as NSString).substring(with: found[0]), "中文")
        XCTAssertEqual(try TextSearchService.allRanges(in: text, query: "x*", options: options), [])
    }

    func testWholeWordPlainAndRegex() throws {
        let text = "cat concat cat_x cat. 猫猫"
        XCTAssertEqual(try ranges(text, "cat", .init(wholeWord: true)).count, 2)
        XCTAssertEqual(try ranges("a @foo b", "@foo", .init(wholeWord: true)), ["@foo"])
        XCTAssertEqual(try ranges(text, "c.t", .init(usesRegex: true, wholeWord: true)), ["cat", "cat"])
        XCTAssertEqual(try ranges("a.t cat", "a.t", .init(wholeWord: true)), ["a.t"])
    }

    func testInvalidRegexThrows() {
        let options = TextSearchService.Options(usesRegex: true)
        XCTAssertThrowsError(try TextSearchService.allRanges(in: "x", query: "(", options: options))
        XCTAssertThrowsError(try TextSearchService.replaceAll(
            in: "x", query: "(", replacement: "", options: options, interpretsEscapes: true))
        XCTAssertThrowsError(try TextSearchService.replacement(
            forSelection: NSRange(location: 0, length: 1), in: "x", query: "(", replacement: "",
            options: options, interpretsEscapes: true))
    }

    func testReplaceAllRegexTemplate() throws {
        let regex = TextSearchService.Options(usesRegex: true)
        let swapped = try TextSearchService.replaceAll(
            in: "ab@cd ef@gh", query: #"(\w+)@(\w+)"#, replacement: "$2:$1", options: regex, interpretsEscapes: true)
        XCTAssertEqual(swapped.text, "cd:ab gh:ef")
        XCTAssertEqual(swapped.count, 2)
        let newline = try TextSearchService.replaceAll(
            in: "a,b", query: ",", replacement: #"\n"#, options: regex, interpretsEscapes: false)
        XCTAssertEqual(newline.text, "a\nb")
        let dollar = try TextSearchService.replaceAll(
            in: "a", query: "a", replacement: #"\$"#, options: regex, interpretsEscapes: false)
        XCTAssertEqual(dollar.text, "$")
        let literal = try TextSearchService.replaceAll(
            in: "cat concat", query: "cat", replacement: "$1", options: .init(wholeWord: true), interpretsEscapes: true)
        XCTAssertEqual(literal.text, "$1 concat")
        let plain = try TextSearchService.replaceAll(
            in: "aXa", query: "a", replacement: "b", options: .init(), interpretsEscapes: true)
        XCTAssertEqual(plain.text, TextSearchService.replacingAll(in: "aXa", query: "a", replacement: "b", caseSensitive: false).text)
    }

    func testReplaceAllSkipsEmptyRegexMatchesLikeSearch() throws {
        let regex = TextSearchService.Options(usesRegex: true)
        XCTAssertEqual(try TextSearchService.allRanges(in: "ab\ncd", query: "^", options: regex), [])
        let result = try TextSearchService.replaceAll(
            in: "ab\ncd", query: "^", replacement: "> ", options: regex, interpretsEscapes: true)
        XCTAssertEqual(result.text, "ab\ncd")
        XCTAssertEqual(result.count, 0)
        let mixed = try TextSearchService.replaceAll(
            in: "axxb", query: "x*", replacement: "-", options: regex, interpretsEscapes: true)
        XCTAssertEqual(mixed.text, "a-b")
        XCTAssertEqual(mixed.count, 1)
    }

    func testReplacementForSelectionGreedy() throws {
        let regex = TextSearchService.Options(usesRegex: true)
        func replacement(_ range: NSRange, _ text: String, _ query: String) throws -> String? {
            try TextSearchService.replacement(forSelection: range, in: text, query: query, replacement: "X",
                                              options: regex, interpretsEscapes: true)
        }
        XCTAssertNil(try replacement(NSRange(location: 0, length: 1), "aaa", "a+"))
        XCTAssertEqual(try replacement(NSRange(location: 0, length: 3), "aaa", "a+"), "X")
        XCTAssertEqual(try replacement(NSRange(location: 1, length: 1), "xa", "(?<=x)a"), "X")
        XCTAssertEqual(try TextSearchService.replacement(
            forSelection: NSRange(location: 0, length: 1), in: "A", query: "a", replacement: #"\t"#,
            options: .init(), interpretsEscapes: true), "\t")
    }

    func testCacheKeyDistinguishesRegexAndWholeWord() {
        let base = TextSearchService.CacheKey(revision: 1, query: "a", caseSensitive: false)
        var regex = base
        regex.usesRegex = true
        var word = base
        word.wholeWord = true
        XCTAssertNotEqual(base, regex)
        XCTAssertNotEqual(base, word)
        var store = SearchMatchCacheStore()
        let id = UUID()
        store.insert(.init(key: base, matches: []), for: id)
        XCTAssertNil(store.value(for: id, key: regex))
        XCTAssertNotNil(store.value(for: id, key: base))
    }

    func testEscapedForInterpretationRoundTrip() {
        for value in ["a\\n", "line1\nline2", "\\s", "\0", "\t", "x\r\ny"] {
            let escaped = TextSearchService.escapedForInterpretation(value)
            XCTAssertEqual(TextSearchService.interpreted(escaped, enabled: true), value)
        }
    }

    func testCurrentIndexAndFirstIndexBinarySearch() {
        let matches = [NSRange(location: 2, length: 2), NSRange(location: 10, length: 3), NSRange(location: 20, length: 1)]
        XCTAssertEqual(TextSearchService.currentIndex(in: matches, selection: NSRange(location: 10, length: 3)), 2)
        XCTAssertNil(TextSearchService.currentIndex(in: matches, selection: NSRange(location: 10, length: 2)))
        XCTAssertNil(TextSearchService.currentIndex(in: [], selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(TextSearchService.firstIndex(in: matches, endingAfter: 0), 0)
        XCTAssertEqual(TextSearchService.firstIndex(in: matches, endingAfter: 4), 1)
        XCTAssertEqual(TextSearchService.firstIndex(in: matches, endingAfter: 13), 2)
        XCTAssertEqual(TextSearchService.firstIndex(in: matches, endingAfter: 21), 3)
    }

    func testLogicalLineIndexLocation() {
        let text = "a\r\nbc\nd\re\u{2028}f😀g\n"
        let ns = text as NSString
        let index = LogicalLineIndex(text: text)
        XCTAssertEqual(index.lineCount, 6)
        XCTAssertEqual(index.location(line: 1, column: 1, in: ns), 0)
        XCTAssertEqual(index.location(line: 1, column: 9, in: ns), 1)      // CRLF is not part of the line
        XCTAssertEqual(index.location(line: 2, column: 2, in: ns), 4)
        XCTAssertEqual(index.location(line: 2, column: 9, in: ns), 5)
        XCTAssertEqual(index.location(line: 3, column: 9, in: ns), 7)      // CR terminator
        XCTAssertEqual(index.location(line: 4, column: 9, in: ns), 9)      // U+2028 terminator
        XCTAssertEqual(index.location(line: 5, column: 4, in: ns), ns.length - 1)   // end of line
        XCTAssertEqual(index.location(line: 6, column: 1, in: ns), ns.length)       // empty last line
        XCTAssertNil(index.location(line: 0, column: 1, in: ns))
        XCTAssertNil(index.location(line: 7, column: 1, in: ns))
        XCTAssertEqual(LogicalLineIndex(text: "").location(line: 1, column: 1, in: "" as NSString), 0)
        for location in [0, 4, 5, 8] {
            let position = index.position(at: location, in: ns)
            XCTAssertEqual(index.location(line: position.line, column: position.column, in: ns), location)
        }
    }

    func testStateMessageKindResets() {
        let state = FindReplaceState()
        state.show("x", kind: .error)
        XCTAssertEqual(state.messageKind, .error)
        state.message = "y"
        XCTAssertEqual(state.messageKind, .info)
        state.show(nil, kind: .info)
        XCTAssertNil(state.message)
    }

    func testStatusMessageErrorFlag() {
        let document = EditorDocument(text: "", language: .plainText)
        document.setStatusError("bad")
        XCTAssertTrue(document.statusMessageIsError)
        document.statusMessage = "ok"
        XCTAssertFalse(document.statusMessageIsError)
    }
}
