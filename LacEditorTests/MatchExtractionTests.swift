import Foundation
import XCTest
@testable import LacEditor

final class MatchExtractionTests: XCTestCase {
    private typealias Record = MatchExtractionService.Record

    private func request(_ query: String, _ mode: MatchExtractionService.Mode, _ options: TextSearchService.Options = .init(),
                         replacement: String = "", escapes: Bool = true, scope: NSRange? = nil) -> MatchExtractionService.Request {
        .init(query: query, options: options, interpretsEscapes: escapes, replacement: replacement, mode: mode, scope: scope)
    }

    private func records(_ text: String, _ request: MatchExtractionService.Request) throws -> [Record] {
        try MatchExtractionService.records(in: text, request: request)
    }

    private let regex = TextSearchService.Options(usesRegex: true)

    func testMatchModeReturnsEveryMatch() throws {
        let result = try records("cat dog cat\nbird\ncat", request("cat", .match))
        XCTAssertEqual(result, [Record(line: 1, text: "cat"), Record(line: 1, text: "cat"), Record(line: 3, text: "cat")])
    }

    func testLineModeReturnsOneRecordPerLine() throws {
        let result = try records("cat dog cat\nbird\ncat", request("cat", .line))
        XCTAssertEqual(result, [Record(line: 1, text: "cat dog cat"), Record(line: 3, text: "cat")])
    }

    func testWithoutMatchModeReturnsOtherLines() throws {
        XCTAssertEqual(try records("cat dog cat\nbird\ncat", request("cat", .withoutMatch)), [Record(line: 2, text: "bird")])
        XCTAssertEqual(try records("a\nb\n", request("a", .withoutMatch)), [Record(line: 2, text: "b")])
        XCTAssertEqual(try records("a\nb", request("a", .withoutMatch)), [Record(line: 2, text: "b")])
        XCTAssertEqual(try records("a\n\nb", request("a", .withoutMatch)), [Record(line: 2, text: ""), Record(line: 3, text: "b")])
    }

    func testTemplateModeUsesCaptureGroups() throws {
        let text = "ann@site bob@home"
        let query = #"(\w+)@(\w+)"#
        XCTAssertEqual(try records(text, request(query, .template, regex, replacement: "$2:$1")),
                       [Record(line: 1, text: "site:ann"), Record(line: 1, text: "home:bob")])
        XCTAssertEqual(try records(text, request(query, .template, regex, replacement: #"$1\n$2"#)).first?.text, "ann\nsite")
    }

    func testTemplateWithoutRegexIsLiteral() throws {
        XCTAssertEqual(try records("a1 a1", request("a1", .template, replacement: "$1")),
                       [Record(line: 1, text: "$1"), Record(line: 1, text: "$1")])
    }

    func testTemplateMatchesReplaceAllOutput() throws {
        let text = "ann@site bob@home x"
        let query = #"(\w+)@(\w+)"#
        let found = try records(text, request(query, .template, regex, replacement: "<$2:$1>"))
        let replaced = try TextSearchService.replaceAll(in: text, query: query, replacement: "<$2:$1>", options: regex, interpretsEscapes: true)
        XCTAssertEqual(found.map(\.text), ["<site:ann>", "<home:bob>"])
        XCTAssertEqual(replaced.text, found.map(\.text).joined(separator: " ") + " x")
    }

    func testEmptyRegexMatchesAreSkipped() throws {
        let text = "abc\ndef"
        XCTAssertEqual(try records(text, request("x*", .match, regex)), [])
        XCTAssertEqual(try records(text, request("x*", .line, regex)), [])
        XCTAssertEqual(try records(text, request("x*", .withoutMatch, regex)),
                       [Record(line: 1, text: "abc"), Record(line: 2, text: "def")])
    }

    func testMultilineMatchMarksAllTouchedLines() throws {
        let text = "a\nb\nc"
        XCTAssertEqual(try records(text, request(#"a\nb"#, .match, regex)), [Record(line: 1, text: "a\nb")])
        XCTAssertEqual(try records(text, request(#"a\nb"#, .line, regex)), [Record(line: 1, text: "a"), Record(line: 2, text: "b")])
        XCTAssertEqual(try records(text, request(#"a\nb"#, .withoutMatch, regex)), [Record(line: 3, text: "c")])
    }

    func testLineNumbersAreUTF16SafeWithEmojiAndCJK() throws {
        let text = "😀 中文\n😀😀 cat\n中文 cat"
        XCTAssertEqual(try records(text, request("cat", .match)), [Record(line: 2, text: "cat"), Record(line: 3, text: "cat")])
        XCTAssertEqual(try records(text, request("cat", .line)), [Record(line: 2, text: "😀😀 cat"), Record(line: 3, text: "中文 cat")])
    }

    func testLineEndingsLFCRLFCR() throws {
        let text = "a cat\r\nb\rcat\nz"
        XCTAssertEqual(try records(text, request("cat", .line)), [Record(line: 1, text: "a cat"), Record(line: 3, text: "cat")])
        XCTAssertEqual(try records(text, request("cat", .withoutMatch)), [Record(line: 2, text: "b"), Record(line: 4, text: "z")])
    }

    func testDataAddressesAreSkippedLikeSearch() throws {
        let address = "data:image/png;base64,Y2F0Y2F0"
        let text = "Y2F0 ![a](\(address))\nq"
        XCTAssertEqual(try records(text, request("Y2F0", .match)), [Record(line: 1, text: "Y2F0")])
        let lines = try records(text, request("q", .withoutMatch))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].text.contains("…"))
        XCTAssertFalse(lines[0].text.contains("base64"))
        let matched = try records(text, request("Y2F0", .line))
        XCTAssertEqual(matched.count, 1)
        XCTAssertFalse(matched[0].text.contains("base64"))
    }

    func testScopeIsRespected() throws {
        let text = "cat\ndog\ncat"
        let first = NSRange(location: 0, length: 3), middle = NSRange(location: 4, length: 3), last = NSRange(location: 8, length: 3)
        XCTAssertEqual(try records(text, request("cat", .match, scope: first)), [Record(line: 1, text: "cat")])
        XCTAssertEqual(try records(text, request("cat", .line, scope: last)), [Record(line: 3, text: "cat")])
        XCTAssertEqual(try records(text, request("cat", .match, scope: middle)), [])
        XCTAssertEqual(try records(text, request("cat", .withoutMatch, scope: middle)), [Record(line: 2, text: "dog")])
        XCTAssertEqual(try records(text, request("cat", .withoutMatch, scope: first)), [])
        XCTAssertEqual(try records(text, request("(c)at", .template, regex, replacement: "$1", scope: last)), [Record(line: 3, text: "c")])
    }

    func testEmptyQueryAndNoMatches() throws {
        for mode in [MatchExtractionService.Mode.match, .template, .line] {
            XCTAssertEqual(try records("abc", request("", mode)), [])
            XCTAssertEqual(try records("abc", request("zzz", mode, replacement: "x")), [])
        }
        XCTAssertEqual(try records("abc", request("", .withoutMatch)), [])
    }

    func testInvalidRegexThrows() {
        for mode in [MatchExtractionService.Mode.match, .template, .line, .withoutMatch] {
            XCTAssertThrowsError(try records("abc", request("(", mode, regex, replacement: "x"))) { error in
                XCTAssertEqual(error as? TextSearchService.SearchError, .invalidPattern)
            }
        }
    }

    func testCancellationThrows() {
        for mode in [MatchExtractionService.Mode.match, .template, .line, .withoutMatch] {
            XCTAssertThrowsError(try MatchExtractionService.records(in: "cat", request: request("cat", mode, replacement: "x"),
                                                                    isCancelled: { true })) { error in
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    func testTextJoining() {
        XCTAssertEqual(MatchExtractionService.text(of: []), "")
        XCTAssertEqual(MatchExtractionService.text(of: [Record(line: 1, text: "a"), Record(line: 2, text: "b")]), "a\nb\n")
    }
}
