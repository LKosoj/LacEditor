import XCTest
@testable import LacEditor

final class MarkdownCodeHighlightServiceTests: XCTestCase {
    func testPseudocodeHighlightsKeywordsArrowsAndNumbers() throws {
        let raw = "Merge(A, p, q, r)\r\n  n_1 <-- q - p + 1\r\n  do L[i] <-- A[p + i - 1]\r\n"
        let literal = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let text = ("😀 " + raw) as NSString
        let tokens = try XCTUnwrap(MarkdownCodeHighlightService.tokens(rawBody: raw, sourceLocation: 3, literal: literal,
            info: "PSEUDOCODE", visible: NSRange(location: 3, length: (raw as NSString).length)))
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && text.substring(with: $0.range) == "do" })
        XCTAssertTrue(tokens.contains { $0.kind == .punctuation && text.substring(with: $0.range) == "<--" })
        XCTAssertTrue(tokens.contains { $0.kind == .number && text.substring(with: $0.range) == "1" })
    }

    func testSupportedLanguagesAndAliasesProduceTokens() throws {
        let examples: [(names: [String], code: String)] = [
            (["markdown", "md", "gfm"], "# heading\n"),
            (["json"], "{\"key\": 42}\n"),
            (["html", "htm", "htmlmixed"], "<div>text</div>\n"),
            (["javascript", "js", "mjs", "cjs", "text/javascript"], "const value = 42;\n"),
            (["typescript", "ts", "tsx"], "const value: number = 42;\n"),
            (["css"], "a { color: red; }\n"),
            (["python", "py"], "def value():\n    return 42\n"),
            (["swift"], "let value = 42\n"),
            (["shell", "sh", "bash", "zsh"], "echo \"hello\"\n"),
            (["yaml", "yml"], "key: value\n"),
            (["c", "h", "clike", "cpp", "c++", "cc", "cxx", "hpp"], "int value = 42;\n"),
            (["sql"], "SELECT value FROM items;\n")
        ]
        for example in examples {
            for name in example.names {
                let tokens = try XCTUnwrap(MarkdownCodeHighlightService.tokens(rawBody: example.code, sourceLocation: 0,
                    literal: example.code, info: name, visible: NSRange(location: 0, length: (example.code as NSString).length)), name)
                XCTAssertFalse(tokens.isEmpty, name)
            }
        }
    }

    func testNestedParserSegmentsHighlightWithoutContainerMarkers() throws {
        let source = "> - ```js\r\n>   /* 中文\r\n>   😀 end */\r\n>   ```\r\n"
        let raw = source as NSString
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).codeBlocks.first)
        let segments = block.bodySegments.map { MarkdownCodeHighlightService.Segment(sourceLocation: $0.location, text: raw.substring(with: $0)) }
        let tokens = try XCTUnwrap(MarkdownCodeHighlightService.tokens(segments: segments, literal: block.literal,
            info: block.info, visible: block.bodyRange))
        let comments = tokens.filter { $0.kind == .comment }
        XCTAssertGreaterThanOrEqual(comments.count, 2)
        XCTAssertTrue(comments.allSatisfy { !raw.substring(with: $0.range).contains(">") })
    }
    func testPartiallyConsumedTabMapsOnlyRealCodeCharacters() throws {
        let source = ">\t```js\n>\tlet x = 42\n>\t```\n"
        let raw = source as NSString
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).codeBlocks.first)
        let segments = zip(block.bodySegments, block.bodyPadding).map {
            MarkdownCodeHighlightService.Segment(sourceLocation: $0.0.location, text: raw.substring(with: $0.0), leadingSpaces: $0.1)
        }
        let tokens = try XCTUnwrap(MarkdownCodeHighlightService.tokens(segments: segments, literal: block.literal,
            info: block.info, visible: block.bodyRange))
        XCTAssertTrue(tokens.contains { raw.substring(with: $0.range).contains("42") })
        XCTAssertTrue(tokens.allSatisfy { !raw.substring(with: $0.range).contains("\t") })
    }

    func testMappedLinesSplitTokensAroundContainerPrefixes() throws {
        let source = "> /* 中文\r\n> 😀 end */\r\n" as NSString
        let first = source.range(of: "/* 中文\r\n"), second = source.range(of: "😀 end */\r\n")
        let segments = [MarkdownCodeHighlightService.Segment(sourceLocation: first.location, text: source.substring(with: first)),
                        MarkdownCodeHighlightService.Segment(sourceLocation: second.location, text: source.substring(with: second))]
        let visible = NSRange(location: 0, length: source.length)
        let tokens = try XCTUnwrap(MarkdownCodeHighlightService.tokens(segments: segments, literal: "/* 中文\n😀 end */\n",
                                                                        info: "js", visible: visible))
        let comments = tokens.filter { $0.kind == .comment }
        XCTAssertGreaterThanOrEqual(comments.count, 2)
        XCTAssertTrue(comments.allSatisfy { !source.substring(with: $0.range).contains(">") })
        let emoji = source.range(of: "😀")
        let clipped = try XCTUnwrap(MarkdownCodeHighlightService.tokens(segments: segments, literal: "/* 中文\n😀 end */\n",
            info: "js", visible: NSRange(location: emoji.location, length: 1)))
        XCTAssertTrue(clipped.isEmpty)
    }
    func testIndependentBlocksMapCRLFAndUnicodeToDocument() throws {
        let raw = "let 中文 = \"😀\"\r\nlet next = 42\r\n"
        let literal = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let source = ("prefix\n" + raw) as NSString
        let visible = NSRange(location: 7, length: (raw as NSString).length)
        let first = try XCTUnwrap(MarkdownCodeHighlightService.tokens(rawBody: raw, sourceLocation: 7, literal: literal,
            info: "javascript", visible: visible))
        let second = try XCTUnwrap(MarkdownCodeHighlightService.tokens(rawBody: "const value = 3\n", sourceLocation: 100,
            literal: "const value = 3\n", info: "js", visible: NSRange(location: 100, length: 16)))
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertTrue(first.contains { source.substring(with: $0.range).contains("42") })
        XCTAssertTrue(first.allSatisfy { NSIntersectionRange($0.range, visible) == $0.range })
        XCTAssertTrue(second.allSatisfy { $0.range.location >= 100 })
    }

    func testRejectsUnprovenBodyUnknownLanguageAndCancellation() {
        XCTAssertNil(MarkdownCodeHighlightService.tokens(rawBody: "a\r\nb", sourceLocation: 0, literal: "a b", info: "js", visible: NSRange(location: 0, length: 4)))
        XCTAssertNil(MarkdownCodeHighlightService.tokens(rawBody: "x", sourceLocation: 0, literal: "x", info: "unknown", visible: NSRange(location: 0, length: 1)))
        XCTAssertNil(MarkdownCodeHighlightService.tokens(rawBody: "x", sourceLocation: 0, literal: "x", info: "js", visible: NSRange(location: 0, length: 1), isCancelled: { true }))
        XCTAssertEqual(MarkdownCodeHighlightService.language(for: "Py linenos"), .python)
    }

    func testFinalUnterminatedLineUsesOnlySourceCharacters() throws {
        let raw = "let value = 42"
        let tokens = try XCTUnwrap(MarkdownCodeHighlightService.tokens(rawBody: raw, sourceLocation: 8,
            literal: raw + "\n", info: "js", visible: NSRange(location: 8, length: (raw as NSString).length)))
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.allSatisfy { NSMaxRange($0.range) <= 8 + (raw as NSString).length })
    }
}
