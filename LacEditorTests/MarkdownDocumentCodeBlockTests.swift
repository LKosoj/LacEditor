import Foundation
import XCTest
import cmark_gfm
@testable import LacEditor

/// Блоки кода единого разбора (U2.4): число строк тела задаёт литерал cmark, конец узла ненадёжен.
final class MarkdownDocumentCodeBlockTests: XCTestCase {
    private struct Found {
        let node: MarkdownBlockNode
        let code: MarkdownBlockNode.CodeBlock
    }

    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> MarkdownDocumentModel {
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: false)
        guard let model = MarkdownDocumentParser.parse(text, options: options) else {
            XCTFail("разбор вернул nil", file: file, line: line)
            return MarkdownDocumentParser.parse("", options: options)!
        }
        return model
    }

    private func codeBlocks(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [Found] {
        func collect(_ blocks: [MarkdownBlockNode]) -> [Found] {
            blocks.flatMap { node -> [Found] in
                var result: [Found] = []
                if case let .codeBlock(code) = node.kind { result.append(Found(node: node, code: code)) }
                return result + collect(node.children)
            }
        }
        return collect(parse(text, file: file, line: line).blocks)
    }

    private func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

    /// Позиция из текста с LF в тексте с CRLF: перед ней каждый `\n` даёт лишний `\r`.
    private func shifted(_ offset: Int, in text: String) -> Int {
        offset + text.utf16.prefix(offset).filter { $0 == 10 }.count
    }

    private func shifted(_ range: NSRange, in text: String) -> NSRange {
        let start = shifted(range.location, in: text), end = shifted(NSMaxRange(range), in: text)
        return NSRange(location: start, length: end - start)
    }

    /// Склейка отрезков с пробелами раскрытых табов и `\n` должна быть равна литералу cmark.
    private func glued(_ found: Found, in text: String) -> String {
        let source = text as NSString
        return zip(found.code.bodySegments, found.code.bodyPadding).map {
            String(repeating: " ", count: $1) + source.substring(with: $0) + "\n"
        }.joined()
    }

    private func r(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

    private struct Expectation {
        let markers: [NSRange]
        let info: NSRange
        let segments: [NSRange]
        let literal: String
        let isClosed: Bool
        let range: NSRange
    }

    /// Ожидания заданы в тексте с LF; для CRLF позиции переводятся.
    private func assertBlock(_ found: Found, _ expected: Expectation, in text: String, lineEnding: Bool, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        func map(_ range: NSRange) -> NSRange { lineEnding ? shifted(range, in: text) : range }
        XCTAssertEqual(found.node.markerRanges, expected.markers.map(map), "\(message): ограждения", file: file, line: line)
        XCTAssertEqual(found.code.infoRange, map(expected.info), "\(message): info", file: file, line: line)
        XCTAssertEqual(found.code.bodySegments, expected.segments.map(map), "\(message): отрезки тела", file: file, line: line)
        XCTAssertEqual(found.code.literal, expected.literal, "\(message): литерал", file: file, line: line)
        XCTAssertEqual(found.code.isClosed, expected.isClosed, "\(message): закрыт", file: file, line: line)
        XCTAssertEqual(found.node.range, map(expected.range), "\(message): диапазон", file: file, line: line)
        XCTAssertFalse(found.node.isUnreliable, "\(message): ненадёжный", file: file, line: line)
        XCTAssertTrue(found.code.isFenced, "\(message): ограждённый", file: file, line: line)
    }

    // MARK: - Шесть примеров GFM

    private let sixExamples: [(name: String, text: String, blocks: [Expectation])] = [
        ("96", "```\n", [Expectation(markers: [NSRange(location: 0, length: 3)], info: NSRange(location: 3, length: 0), segments: [], literal: "",
                                     isClosed: false, range: NSRange(location: 0, length: 3))]),
        ("97", "`````\n\n```\naaa\n", [Expectation(markers: [NSRange(location: 0, length: 5)], info: NSRange(location: 5, length: 0),
                                                  segments: [NSRange(location: 6, length: 0), NSRange(location: 7, length: 3), NSRange(location: 11, length: 3)],
                                                  literal: "\n```\naaa\n", isClosed: false, range: NSRange(location: 0, length: 14))]),
        ("98", "> ```\n> aaa\n\nbbb\n", [Expectation(markers: [NSRange(location: 2, length: 3)], info: NSRange(location: 5, length: 0),
                                                    segments: [NSRange(location: 8, length: 3)], literal: "aaa\n", isClosed: false,
                                                    range: NSRange(location: 2, length: 9))]),
        ("109", "~~~~~~\naaa\n~~~ ~~\n", [Expectation(markers: [NSRange(location: 0, length: 6)], info: NSRange(location: 6, length: 0),
                                                      segments: [NSRange(location: 7, length: 3), NSRange(location: 11, length: 6)],
                                                      literal: "aaa\n~~~ ~~\n", isClosed: false, range: NSRange(location: 0, length: 17))]),
        ("215", "> ```\nfoo\n```\n", [Expectation(markers: [NSRange(location: 2, length: 3)], info: NSRange(location: 5, length: 0), segments: [],
                                                  literal: "", isClosed: false, range: NSRange(location: 2, length: 3)),
                                      Expectation(markers: [NSRange(location: 10, length: 3)], info: NSRange(location: 13, length: 0), segments: [],
                                                  literal: "", isClosed: false, range: NSRange(location: 10, length: 3))]),
        ("241", "1.  foo\n\n    ```\n    bar\n    ```\n\n    baz\n\n    > bam\n",
         [Expectation(markers: [NSRange(location: 13, length: 3), NSRange(location: 29, length: 3)], info: NSRange(location: 16, length: 0),
                      segments: [NSRange(location: 21, length: 3)], literal: "bar\n", isClosed: true, range: NSRange(location: 13, length: 19))]),
    ]

    func testSpecExamplesProduceExactBodySegments() {
        for example in sixExamples {
            let blocks = codeBlocks(example.text)
            XCTAssertEqual(blocks.count, example.blocks.count, "пример \(example.name): число блоков")
            for (found, expected) in zip(blocks, example.blocks) {
                assertBlock(found, expected, in: example.text, lineEnding: false, "пример \(example.name) LF")
            }
        }
    }

    func testSpecExamplesProduceExactBodySegmentsWithCRLF() {
        for example in sixExamples {
            let text = crlf(example.text)
            let blocks = codeBlocks(text)
            XCTAssertEqual(blocks.count, example.blocks.count, "пример \(example.name) CRLF: число блоков")
            for (found, expected) in zip(blocks, example.blocks) {
                assertBlock(found, expected, in: example.text, lineEnding: true, "пример \(example.name) CRLF")
                for segment in found.code.bodySegments {
                    let units = Array(text.utf16)
                    XCTAssertFalse(units[segment.location..<NSMaxRange(segment)].contains { $0 == 10 || $0 == 13 },
                                   "пример \(example.name): отрезок не включает перевод строки")
                }
            }
        }
    }

    // MARK: - Дополнение из U2.2

    func testFenceInQuotedListItemEndsWithItem() {
        let text = "> - ```\n>   {++x++}\n> {++y++}\n"
        let blocks = codeBlocks(text)
        XCTAssertEqual(blocks.count, 1)
        guard let found = blocks.first else { return }
        XCTAssertEqual(found.code.literal, "{++x++}\n")
        XCTAssertFalse(found.code.isClosed)
        XCTAssertEqual(found.code.bodySegments, [r(12, 7)])
        XCTAssertEqual(found.node.range, r(4, 15))
        XCTAssertFalse(found.node.isUnreliable)
        XCTAssertEqual(glued(found, in: text), found.code.literal)
    }

    func testFenceEndsWithQuoteOrItemContainerWithCRLF() {
        let text = "- > ```\r\n  > {++a++}\r\n  > b\r\n{++c++}\r\n"
        let blocks = codeBlocks(text)
        XCTAssertEqual(blocks.count, 1)
        guard let found = blocks.first else { return }
        XCTAssertEqual(found.code.literal, "{++a++}\nb\n")
        XCTAssertFalse(found.code.isClosed)
        XCTAssertEqual(found.code.bodySegments, [r(13, 7), r(26, 1)])
        XCTAssertEqual(found.node.range, r(4, 23))
        XCTAssertEqual(glued(found, in: text), found.code.literal)
    }

    // MARK: - Табы, юникод, контейнеры

    func testTabbedContainersReportPaddingAndExactSegments() {
        let cases: [(String, [NSRange], [Int])] = [
            ("- foo\n\n\t\tbar", [r(9, 3)], [2]),
            (">\t\tfoo", [r(3, 3)], [2]),
            (">\t```js\n>\tlet x = 1\n>\t```", [r(10, 9)], [1]),
            ("- ```\n\ta\n  b", [r(7, 1), r(11, 1)], [2, 0]),
        ]
        for (text, segments, padding) in cases {
            let blocks = codeBlocks(text)
            XCTAssertEqual(blocks.count, 1, text)
            guard let found = blocks.first else { continue }
            XCTAssertEqual(found.code.bodySegments, segments, text)
            XCTAssertEqual(found.code.bodyPadding, padding, text)
            XCTAssertFalse(found.node.isUnreliable, text)
            XCTAssertEqual(glued(found, in: text), found.code.literal, text)
        }
        let afterMarker: [(String, [NSRange], [Int])] = [
            ("-\t\tfoo", [r(3, 3)], [2]),
            ("-\t```js\n\tlet y = 2\n\t```", [r(9, 9)], [0]),
        ]
        for (text, segments, padding) in afterMarker {
            let blocks = codeBlocks(text)
            XCTAssertEqual(blocks.count, 1, text)
            guard let found = blocks.first else { continue }
            XCTAssertFalse(found.node.isUnreliable, text)
            XCTAssertEqual(found.code.bodySegments, segments, text)
            XCTAssertEqual(found.code.bodyPadding, padding, text)
            XCTAssertEqual(glued(found, in: text), found.code.literal, text)
        }
    }

    func testCyrillicCjkEmojiBodiesUseUTF16Offsets() {
        let quoted = "> ```жук\n> привет😀\n> мир\n\nабв\n"
        let blocks = codeBlocks(quoted)
        XCTAssertEqual(blocks.count, 1)
        if let found = blocks.first {
            XCTAssertEqual(found.code.info, "жук")
            XCTAssertEqual(found.code.infoRange, r(5, 3))
            XCTAssertEqual(found.code.bodySegments, [r(11, 8), r(22, 3)])
            XCTAssertEqual(glued(found, in: quoted), found.code.literal)
        }
        let listed = "- ```\n  中文\n- x\n"
        let listBlocks = codeBlocks(listed)
        XCTAssertEqual(listBlocks.count, 1)
        if let found = listBlocks.first {
            XCTAssertEqual(found.code.bodySegments, [r(8, 2)])
            XCTAssertFalse(found.code.isClosed)
            XCTAssertEqual(glued(found, in: listed), found.code.literal)
        }
        let closed = crlf("```😀\r\nжук 中\r\n```\r\n")
        let closedBlocks = codeBlocks(closed)
        XCTAssertEqual(closedBlocks.count, 1)
        for found in closedBlocks {
            XCTAssertTrue(found.code.isClosed)
            XCTAssertEqual(found.code.info, "😀")
            XCTAssertEqual(glued(found, in: closed), found.code.literal)
        }
    }

    // Конец текста без перевода строки: закрытый и незакрытый блок.
    func testFenceAtEndOfTextWithoutNewline() {
        let closed = codeBlocks("```\na\n```")
        XCTAssertEqual(closed.count, 1)
        if let found = closed.first {
            XCTAssertTrue(found.code.isClosed)
            XCTAssertEqual(found.code.bodySegments, [r(4, 1)])
            XCTAssertFalse(found.node.isUnreliable)
        }
        let open = codeBlocks("```\na")
        XCTAssertEqual(open.count, 1)
        if let found = open.first {
            XCTAssertFalse(found.code.isClosed)
            XCTAssertEqual(found.code.bodySegments, [r(4, 1)])
            XCTAssertFalse(found.node.isUnreliable)
        }
    }

    // Закрывающее ограждение длиннее открывающего в цитате и в пункте; суррогатная пара в теле.
    func testLongerClosingFenceInContainersAndSurrogatePairBody() {
        let cases: [(String, [NSRange])] = [
            ("> ```\n> a\n> `````\n", [r(8, 1)]),
            ("- ```\n  a\n  `````\n", [r(8, 1)]),
            ("```\n😀x\n```\n", [r(4, 3)]),
        ]
        for (text, segments) in cases {
            let blocks = codeBlocks(text)
            XCTAssertEqual(blocks.count, 1, text)
            guard let found = blocks.first else { continue }
            XCTAssertTrue(found.code.isClosed, text)
            XCTAssertFalse(found.node.isUnreliable, text)
            XCTAssertEqual(found.code.bodySegments, segments, text)
            XCTAssertEqual(glued(found, in: text), found.code.literal, text)
        }
    }

    func testUnclosedFenceInListEndsWithItem() {
        for text in ["- ```\n```\n", "> ```\n```\n"] {
            let blocks = codeBlocks(text)
            XCTAssertEqual(blocks.count, 2, text)
            XCTAssertEqual(blocks.map(\.code.isClosed), [false, false], text)
            XCTAssertEqual(blocks.map(\.code.bodySegments), [[], []], text)
        }
        let nested = "- - ```\n    a\n  - x\n"
        let blocks = codeBlocks(nested)
        XCTAssertEqual(blocks.count, 1)
        if let found = blocks.first {
            XCTAssertEqual(found.code.literal, "a\n")
            XCTAssertFalse(found.code.isClosed)
            XCTAssertEqual(found.code.bodySegments, [r(12, 1)])
        }
    }

    func testIndentedCodeUsesLiteralLinesAndSkipsTrailingBlankLines() {
        let text = "    a\n\n\n    b\n\n\nx\n"
        let blocks = codeBlocks(text)
        XCTAssertEqual(blocks.count, 1)
        guard let found = blocks.first else { return }
        XCTAssertEqual(found.code.bodySegments, [r(4, 1), r(6, 0), r(7, 0), r(12, 1)])
        XCTAssertFalse(found.code.isFenced)
        XCTAssertNil(found.code.infoRange)
        XCTAssertEqual(found.node.markerRanges, [])
        XCTAssertEqual(found.node.range, r(4, 9))
        XCTAssertFalse(found.node.isUnreliable)
        XCTAssertEqual(glued(found, in: text), found.code.literal)
    }

    func testLineSeparatorsOtherThanCRAndLFDoNotSplitBody() {
        let text = "```\na\u{2028}b\u{85}c\n```\n"
        let blocks = codeBlocks(text)
        XCTAssertEqual(blocks.count, 1)
        guard let found = blocks.first else { return }
        XCTAssertEqual(found.code.bodySegments, [r(4, 5)])
        XCTAssertTrue(found.code.isClosed)
        XCTAssertFalse(found.node.isUnreliable)
    }

    func testClosingFenceNeedsAtLeastOpeningLengthAndKeepsTrailingSpaces() {
        let text = "````\na\n```\n`````  \nb\n"
        let blocks = codeBlocks(text)
        XCTAssertEqual(blocks.count, 1)
        guard let found = blocks.first else { return }
        XCTAssertTrue(found.code.isClosed)
        XCTAssertEqual(found.code.literal, "a\n```\n")
        XCTAssertEqual(found.node.markerRanges, [r(0, 4), r(11, 5)])
        XCTAssertEqual(found.node.range, r(0, 18))
        XCTAssertEqual(found.code.bodySegments, [r(5, 1), r(7, 3)])
    }

    // MARK: - Отмена и ненадёжные блоки

    private func layout(_ text: String, isCancelled: () -> Bool = { false }) -> MarkdownDocumentParser.CodeBlockLayout? {
        let bytes = Array(text.utf8)
        let typedRoot = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { cmark_parse_document($0, buffer.count, CMARK_OPT_SOURCEPOS)! }
        }
        defer { cmark_node_free(typedRoot) }
        let root = OpaquePointer(typedRoot)
        guard let node = cmark_node_first_child(root) else { return nil }
        return MarkdownDocumentParser.codeBlockLayout(node, source: MarkdownSourcePositions(text, root: root), isCancelled: isCancelled)
    }

    func testCancellationReturnsNil() {
        let text = "```\na\nb\n```\n"
        XCTAssertNotNil(layout(text))
        XCTAssertNil(layout(text, isCancelled: { true }))
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: false)
        XCTAssertNil(MarkdownDocumentParser.parse(text, options: options, isCancelled: { true }))
    }

    func testNulInBodyIsUnreliable() {
        // cmark заменяет NUL на U+FFFD, а в исходнике он остаётся: строка не находится, позиции не выдумываются.
        XCTAssertNil(layout("```\na\u{0}b\n```\n"))
        XCTAssertNotNil(layout("```\nab\n```\n"))
    }

    // MARK: - Корпус

    func testSpecCorpusBodySegmentsEqualLiteral() throws {
        var checked = 0
        for (corpus, cases) in [("spec", try GFMSpecReader.spec()), ("ext", try GFMSpecReader.extensions())] {
            for example in cases {
                for (variant, text) in [("LF", example.markdown), ("CRLF", crlf(example.markdown))] {
                    let name = "\(corpus)#\(example.number) \(variant)"
                    let blocks = codeBlocks(text)
                    // В HTML спецификации каждому блоку кода (кроме внутри сырого HTML-блока) соответствует `<pre><code`.
                    if !example.markdown.contains("<pre") {
                        XCTAssertEqual(blocks.count, example.html.components(separatedBy: "<pre><code").count - 1, "\(name): число блоков")
                    }
                    for found in blocks {
                        checked += 1
                        XCTAssertFalse(found.node.isUnreliable, "\(name): ненадёжный блок")
                        XCTAssertEqual(glued(found, in: text), found.code.literal, "\(name): склейка отрезков")
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 180)
    }
}
