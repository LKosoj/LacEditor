import XCTest
@testable import LacEditor

@MainActor
final class MarkdownSectionMoveTests: XCTestCase {
    private typealias Service = MarkdownSectionMoveService

    // MARK: Вспомогательное

    /// Построчный разбор для чистых тестов: ATX и setext-заголовки на верхнем уровне, front matter пропускается.
    private func headings(_ text: String) -> [MarkdownHeading] {
        let ns = text as NSString
        var lines: [(text: String, start: Int)] = []
        var start = 0
        var index = 0
        while index < ns.length {
            let unit = ns.character(at: index)
            if unit == 10 || unit == 13 {
                lines.append((ns.substring(with: NSRange(location: start, length: index - start)), start))
                if unit == 13, index + 1 < ns.length, ns.character(at: index + 1) == 10 { index += 1 }
                start = index + 1
            }
            index += 1
        }
        if start < ns.length { lines.append((ns.substring(from: start), start)) }
        var current = 0
        if text.hasPrefix("---\n"), let close = lines.dropFirst().firstIndex(where: { $0.text == "---" }) { current = close + 1 }
        var result: [MarkdownHeading] = []
        while current < lines.count {
            let line = lines[current].text
            let leading = line.prefix { $0 == " " }.count
            let body = line.dropFirst(leading)
            let hashes = body.prefix { $0 == "#" }.count
            if leading <= 3, (1...6).contains(hashes), body.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) ?? true {
                result.append(MarkdownHeading(
                    level: hashes, title: body.dropFirst(hashes).trimmingCharacters(in: .whitespaces),
                    range: NSRange(location: lines[current].start + leading, length: line.utf16.count - leading), isTopLevel: true))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, current + 1 < lines.count {
                let under = lines[current + 1].text.trimmingCharacters(in: .whitespaces)
                if let mark = under.first, mark == "=" || mark == "-", under.allSatisfy({ $0 == mark }) {
                    result.append(MarkdownHeading(
                        level: mark == "=" ? 1 : 2, title: line, range: NSRange(location: lines[current].start, length: line.utf16.count),
                        isTopLevel: true))
                    current += 1
                }
            }
            current += 1
        }
        return result
    }

    private func apply(_ move: Service.Move, to text: String) -> String {
        (text as NSString).replacingCharacters(in: move.range, with: move.replacement)
    }

    private func result(_ text: String, section: Int, target: Service.Target) -> Result<Service.Move, Service.Failure> {
        Service.move(in: text as NSString, headings: headings(text), section: section, to: target)
    }

    private func moved(_ text: String, section: Int, to target: Service.Target, file: StaticString = #filePath, line: UInt = #line) -> String? {
        switch result(text, section: section, target: target) {
        case let .success(move): return apply(move, to: text)
        case let .failure(failure):
            XCTFail("перенос отклонён: \(failure)", file: file, line: line)
            return nil
        }
    }

    private func failure(_ text: String, section: Int, target: Service.Target) -> Service.Failure? {
        if case let .failure(value) = result(text, section: section, target: target) { return value }
        return nil
    }

    private func lineMultiset(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init).sorted()
    }

    // MARK: Соседние разделы

    func testSwapsAdjacentSiblingsDownAndUp() {
        let text = "# A\ntext\n# B\ntext2\n"
        let list = headings(text)
        XCTAssertEqual(Service.target(.down, section: 0, headings: list), .end)
        XCTAssertEqual(moved(text, section: 0, to: .end), "# B\ntext2\n# A\ntext\n")
        XCTAssertEqual(Service.target(.up, section: 1, headings: list), .before(0))
        XCTAssertEqual(moved(text, section: 1, to: .before(0)), "# B\ntext2\n# A\ntext\n")
    }

    func testSectionIncludesNestedSubsections() {
        let text = "# A\n## A1\n### A11\n# B\n"
        let list = headings(text)
        XCTAssertEqual(Service.sectionEnd(of: 0, in: list), 3)
        XCTAssertEqual(Service.sectionEnd(of: 1, in: list), 3)
        XCTAssertEqual(moved(text, section: 0, to: .end), "# B\n# A\n## A1\n### A11\n")
        XCTAssertNil(Service.target(.down, section: 1, headings: list))
    }

    func testSectionEndsAtSameOrHigherLevel() {
        let list = headings("## X\n### Y\n## Z\n# W\n")
        XCTAssertEqual(Service.sectionEnd(of: 0, in: list), 2)
        XCTAssertEqual(Service.sectionEnd(of: 1, in: list), 2)
        XCTAssertEqual(Service.sectionEnd(of: 2, in: list), 3)
        XCTAssertNil(Service.sectionEnd(of: 3, in: list))
    }

    func testRejectsTargetInsideOwnSectionAndUnchangedPlaces() {
        let text = "# A\n## A1\n# B\n"
        XCTAssertEqual(failure(text, section: 0, target: .before(1)), .insideSelf)
        XCTAssertEqual(failure(text, section: 0, target: .before(0)), .unchanged)
        XCTAssertEqual(failure(text, section: 0, target: .before(2)), .unchanged)
        XCTAssertEqual(failure(text, section: 2, target: .end), .unchanged)
        XCTAssertEqual(failure(text, section: 0, target: .before(9)), .notTopLevel)
    }

    func testPreambleStays() {
        let text = "---\ntitle: x\n---\n\nintro\n\n# A\na\n# B\nb\n"
        let prefix = "---\ntitle: x\n---\n\nintro\n\n"
        guard case let .success(move) = result(text, section: 1, target: .before(0)) else { return XCTFail() }
        XCTAssertEqual(move.range.location, (prefix as NSString).length)
        XCTAssertEqual(apply(move, to: text), prefix + "# B\nb\n# A\na\n")
    }

    // MARK: Конец документа и переводы строк

    func testLastLineWithoutTerminator() {
        let text = "# A\nx\n# B\ny"
        XCTAssertEqual(moved(text, section: 1, to: .before(0)), "# B\ny\n# A\nx")
        XCTAssertEqual(moved(text, section: 0, to: .end), "# B\ny\n# A\nx")
    }

    func testLastLineWithoutTerminatorKeepsBlankSeparator() {
        XCTAssertEqual(moved("# A\n\nx\n\n# B\n\ny", section: 1, to: .before(0)), "# B\n\ny\n\n# A\n\nx")
    }

    func testCRLFPreserved() {
        let text = "# A\r\nx\r\n# B\r\ny"
        let value = moved(text, section: 1, to: .before(0))
        XCTAssertEqual(value, "# B\r\ny\r\n# A\r\nx")
        XCTAssertEqual(value?.components(separatedBy: "\r\n").count, value?.components(separatedBy: "\n").count)
    }

    func testMixedTerminatorsPreservedVerbatim() {
        let text = "# A\rx\r\n# B\ny\n# C\r\nz\r"
        let value = moved(text, section: 1, to: .end)
        XCTAssertEqual(value, "# A\rx\r\n# C\r\nz\r# B\ny\n")
        XCTAssertEqual(lineMultiset(value ?? ""), lineMultiset(text))
    }

    // MARK: Setext

    func testSetextHeadingMovesTwoLines() {
        let text = "Title\n=====\ntext\n\n# B\n"
        guard case let .success(move) = result(text, section: 0, target: .end) else { return XCTFail() }
        let value = apply(move, to: text)
        XCTAssertEqual(value, "# B\nTitle\n=====\ntext\n\n")
        XCTAssertEqual((value as NSString).substring(with: move.selectionRange), "Title")
    }

    func testSetextAfterParagraphGetsBlankLine() {
        XCTAssertEqual(moved("Title\n=====\nbody\n# A\npara\n# B\nq\n", section: 0, to: .before(2)),
                       "# A\npara\n\nTitle\n=====\nbody\n# B\nq\n")
        XCTAssertEqual(moved("Title\n=====\nbody\n# A\n# B\nq\n", section: 0, to: .before(2)),
                       "# A\nTitle\n=====\nbody\n# B\nq\n")
        XCTAssertEqual(moved("Title\n=====\nbody\n# A\npara\n\n# B\nq\n", section: 0, to: .before(2)),
                       "# A\npara\n\nTitle\n=====\nbody\n# B\nq\n")
    }

    // MARK: Хвост документа

    func testFootnoteAndReferenceDefinitionsTravelWithLastSection() {
        let text = "# A\nx\n# B\ny\n\n[^1]: note\n"
        XCTAssertEqual(moved(text, section: 1, to: .before(0)), "# B\ny\n\n[^1]: note\n# A\nx\n")
        XCTAssertEqual(moved(text, section: 0, to: .end), "# B\ny\n\n[^1]: note\n# A\nx\n")
    }

    func testUnsafeEndRefused() {
        let fence = "# A\nx\n# B\n```\ncode\n"
        XCTAssertEqual(failure(fence, section: 1, target: .before(0)), .unsafeEnd)
        XCTAssertEqual(failure(fence, section: 0, target: .end), .unsafeEnd)
        XCTAssertNotNil(moved("# A\nx\n# B\n```\ncode\n```\n", section: 1, to: .before(0)))
        XCTAssertEqual(failure("# A\nx\n# B\n$$\nx\n", section: 1, target: .before(0)), .unsafeEnd)
        XCTAssertEqual(failure("# A\nx\n# B\n\n<div>\nx\n", section: 1, target: .before(0)), .unsafeEnd)
    }

    // MARK: Вложенные заголовки

    func testNestedHeadingsAreNotBoundaries() {
        let list = [MarkdownHeading(level: 1, title: "A", range: NSRange(location: 0, length: 3), isTopLevel: true),
                    MarkdownHeading(level: 1, title: "Q", range: NSRange(location: 6, length: 3)),
                    MarkdownHeading(level: 1, title: "B", range: NSRange(location: 12, length: 3), isTopLevel: true)]
        XCTAssertEqual(Service.sectionEnd(of: 0, in: list), 2)
        XCTAssertEqual(Service.validate(section: 1, target: .end, headings: list), .notTopLevel)
        XCTAssertEqual(Service.validate(section: 0, target: .before(1), headings: list), .notTopLevel)
    }

    func testParserMarksTopLevelHeadings() {
        let parsed = MarkdownPresentationParser.parse("> # Q\n\n- # L\n\n# T\n").headings
        XCTAssertEqual(parsed.map(\.isTopLevel), [false, false, true])
        let numbered = MarkdownPresentationParser.parse("> # Q\n\n# T\n").numberingHeadings(true).headings
        XCTAssertEqual(numbered.map(\.isTopLevel), [false, true])
    }

    // MARK: Направления

    func testDirectionTargets() {
        let list = headings("# A\n## a1\n### deep\n## a2\n# B\n")
        XCTAssertEqual(Service.target(.down, section: 1, headings: list), .before(4))
        XCTAssertEqual(Service.target(.up, section: 3, headings: list), .before(1))
        XCTAssertNil(Service.target(.up, section: 1, headings: list))
        XCTAssertNil(Service.target(.down, section: 3, headings: list))
        XCTAssertNil(Service.target(.up, section: 0, headings: list))
        XCTAssertNil(Service.target(.down, section: 4, headings: list))
        let text = "## a\n### deep\n## b\n"
        XCTAssertEqual(Service.target(.down, section: 0, headings: headings(text)), .end)
        XCTAssertEqual(moved(text, section: 0, to: .end), "## b\n## a\n### deep\n")
    }

    // MARK: UTF-16 и диапазоны

    func testUTF16Ranges() {
        let text = "# 你好🙂\n正文👨‍👩‍👧\n# 世界\n再见\n"
        guard case let .success(move) = result(text, section: 0, target: .end) else { return XCTFail() }
        let value = apply(move, to: text)
        XCTAssertEqual(value, "# 世界\n再见\n# 你好🙂\n正文👨‍👩‍👧\n")
        XCTAssertEqual(move.range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual((value as NSString).substring(with: move.selectionRange), "# 你好🙂")
    }

    func testSelectionAndRangeAreMinimalAndAbsolute() {
        let text = "# A\na\n# B\nb\n# C\nc\n"
        guard case let .success(move) = result(text, section: 1, target: .end) else { return XCTFail() }
        XCTAssertEqual(move.range, NSRange(location: 6, length: 12))
        XCTAssertEqual(apply(move, to: text), "# A\na\n# C\nc\n# B\nb\n")
        XCTAssertEqual(((apply(move, to: text)) as NSString).substring(with: move.selectionRange), "# B")
    }

    func testAllPairsKeepLinesAndOrder() {
        let text = (0..<5).map { "# S\($0)\nt\($0)\n" }.joined()
        let list = headings(text)
        let targets: [Service.Target] = (0..<5).map { .before($0) } + [.end]
        for section in 0..<5 {
            for target in targets {
                switch result(text, section: section, target: target) {
                case let .success(move):
                    var order = Array(0..<5)
                    order.remove(at: section)
                    if case let .before(j) = target { order.insert(section, at: order.firstIndex(of: j)!) } else { order.append(section) }
                    XCTAssertEqual(apply(move, to: text), order.map { "# S\($0)\nt\($0)\n" }.joined(), "\(section) -> \(target)")
                    XCTAssertEqual(move.replacement.utf16.count, move.range.length)
                case let .failure(failure):
                    XCTAssertEqual(failure, .unchanged, "\(section) -> \(target)")
                    XCTAssertNotNil(Service.validate(section: section, target: target, headings: list))
                }
            }
        }
    }

    func testStaleHeadingRejected() {
        let list = [MarkdownHeading(level: 1, title: "A", range: NSRange(location: 4, length: 3), isTopLevel: true),
                    MarkdownHeading(level: 1, title: "B", range: NSRange(location: 8, length: 3), isTopLevel: true)]
        let result = Service.move(in: "    # A\n# B\n" as NSString, headings: list, section: 0, to: .end)
        XCTAssertEqual(result, .failure(.invalidInput))
    }
}
