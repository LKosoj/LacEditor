import Foundation
import XCTest
@testable import LacEditor

/// Контекст ограждений модели (U2.5d): поле `fence`, флаг `editorContext` и отмена.
final class MarkdownDocumentFenceTests: XCTestCase {
    private func options(_ includes: MarkdownDocumentModel.Includes, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions()) -> MarkdownDocumentModel.Options {
        MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: false, detectsFrontMatter: true)
    }

    private func fence(_ text: String, _ includes: MarkdownDocumentModel.Includes = [.editorContext],
                       file: StaticString = #filePath, line: UInt = #line) -> MarkdownDocumentModel.FenceContext? {
        guard let model = MarkdownDocumentParser.parse(text, options: options(includes)) else {
            XCTFail("разбор вернул nil", file: file, line: line)
            return nil
        }
        return model.fence
    }

    private func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Характерные входы: незакрытые блоки (в том числе в цитате и пункте), HTML-блоки, таблицы, сноски, пустые контейнеры,
    /// кириллица, CJK, эмодзи, `\r\n`, табы, ленивое продолжение, выноски.
    private let samples: [String] = [
        "```\n", "```", "```swift", "```\nкод\n", "```\nкод\n```\n\nТекст\n", "~~~\nx\n", "````\n```\nx\n",
        "Абзац\n\n```\n", "Абзац\n\n```\n\nещё\n", "    отступный код\n\nТекст\n", "Текст\n\n    код без конца",
        "> ```\n> aaa\n\nbbb\n", "> ```\nfoo\n```\n", "- ```\n  a\n- x\n", "- ```\n```\n", "> ```\n```\n",
        "- - ```\n    a\n  - x\n", "> ```жук\n> привет😀\n> мир\n\nабв\n", "- ```\n  中文\n- x\n",
        "- ```\r\n  > a\r\n  > b\r\n", "> - ```\n>   a\n",
        "> цитата\n> вторая строка\n\nТекст после\n", "> цитата\nленивое продолжение\n\nконец", "> один\n>\n> два\n",
        "> > вложенная\n> > цитата\n> внешняя\n", ">\n", "> \n", "- \n- x\n", "- \n", "> - \n", "1. \n2. два\n", "-   \n",
        "- пункт\n  продолжение пункта\n- второй пункт\n   - вложенный\n     текст вложенного\n",
        "1. один\n   вложено\n2. два\n\n   абзац в пункте\n",
        "- [ ] задача\n  продолжение\n- [x] готово\n", "- a\n\n  b\n\n- c\n",
        "> - пункт в цитате\n>   продолжение\n> - второй\n", "- > цитата в пункте\n  > вторая строка\n",
        "<div>\nHTML-блок\n</div>\n\nТекст\n", "Текст\n\n<div>\nнезакрытый HTML-блок", "> <div>\n> внутри цитаты\n> </div>\n",
        "<!-- комментарий -->\n\nТекст\n", "<details><summary>S</summary>\n\nтекст\n\n</details>\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n\nТекст\n", "Абзац\n\n| a |\n|---|\n| 1 |", "> | a |\n> |---|\n> | 1 |\n",
        "Текст[^1]\n\n[^1]: сноска\n    продолжение\n\nконец\n", "[^1]: сноска с кодом\n\n    код\n",
        "---\ntitle: Тест\n---\n\n```\nкод", "---\ntitle: Тест\n---\n\nТекст\n",
        "> [!note] Заголовок\n> тело выноски\n> вторая строка\n", "> [!NOTE]\n> текст алерта\n", "> [!tip]\n",
        "$$\nx = 1\n$$\n\nТекст\n", "$$\nx = 1\n", "- $$\n  x\n  $$\n",
        "\tтаб\n\n- пункт\n\tпродолжение\n", "> \tцитата с табом\n", "-\tпункт с табом\n  продолжение\n",
        "> \t**a** *b*\n", "- \t**a** *b*\n", "> a\t**b** *c*\n",
        "> \t2024 год\n", "- \t5 яблок\n", "> \t-3 градуса\n", "> \t.5 литра\n",
        "> \t**a**,**b**,**c**,**d**,**e**\n> \tследующая\n", "> \ta*b*c*d*e*f*g*h*i\n> \tследующая\n",
        "> \tA &amp; B\n> \tследующая\n", "> \t&copy; 2024\n> \tдалее\n", "> \tцена\\*5\n> \tдалее\n",
        "Строка с `кодом` и *курсивом*\n> *курсив в начале*\n> text\n", "- &amp; сущность\n  продолжение\n",
        "- \"кавычки\" в начале\n  \"вторая\" строка\n", "- :smile: эмодзи\n  :tada: вторая\n", "- ==выделение== в начале\n  и текст\n",
        "- [[Ссылка]] в начале\n  текст\n", "- ![картинка](a.png) в начале\n  текст\n",
        "Абзац\n\n***\n\n> цитата\n\n- пункт\n\n```\nкод\n```\n\n<hr>\n\n| a |\n|---|\n",
        "", "\n\n\n", "текст без перевода строки", "# Заголовок\n\n> цитата",
    ]

    private func corpus() throws -> [(id: String, text: String)] {
        var items = try BaselineCorpus.documents().map { ($0.id, $0.text) }
        items += try BaselineCorpus.crlfDocuments().map { ($0.id, $0.text) }
        items += samples.enumerated().map { ("sample\($0.offset)", $0.element) }
        items += samples.enumerated().map { ("sample\($0.offset)[crlf]", crlf($0.element)) }
        return items
    }

    // MARK: - Характерные входы

    func testUnclosedTopLevelFenceWithoutBodySkipsOpeningLine() {
        let text = "Абзац\n\n```swift\n"
        let result = fence(text)
        XCTAssertEqual(result?.blockedRanges, [], "блок без тела: открывающая строка остаётся доступной")
        XCTAssertEqual(result?.blockedEOF, true)
        XCTAssertEqual(result?.isAvailable, true)
    }

    func testUnclosedFenceWithBodyBlocksWholeBlock() {
        let text = "Абзац\n\n```\nкод 😀\n"
        let result = fence(text)
        XCTAssertEqual(result?.blockedRanges, [NSRange(location: 7, length: (text as NSString).length - 7)])
        XCTAssertEqual(result?.blockedEOF, true)
    }

    func testClosedFenceInTheMiddleDoesNotReachEOF() {
        let result = fence("```\nкод\n```\n\nТекст\n")
        XCTAssertEqual(result?.blockedRanges, [NSRange(location: 0, length: 12)])
        XCTAssertEqual(result?.blockedEOF, false)
    }

    func testFrontMatterIsBlocked() {
        let text = "---\ntitle: Тест\n---\n\nТекст\n"
        XCTAssertEqual(fence(text)?.blockedRanges.first?.location, 0)
        XCTAssertEqual(fence(text)?.blockedRanges.first, MarkdownFrontMatter.frontMatter(text)?.range)
    }

    func testEmptyContainersGiveConfirmedPrefix() {
        let result = fence("> \n\n- \n")
        XCTAssertEqual(result?.containerLines.map(\.sourcePrefix), ["> ", "- "])
        XCTAssertEqual(result?.containerLines.map(\.continuationPrefix), ["> ", "  "])
    }

    func testParagraphLinesInQuoteAndListGivePrefixes() {
        let text = "> цитата 😀\n> вторая\n\n- пункт\n  продолжение\n"
        let result = fence(text)
        XCTAssertEqual(result?.containerLines.map(\.sourcePrefix), ["> ", "> ", "- ", "  "])
        XCTAssertEqual(result?.containerLines.map(\.continuationPrefix), ["> ", "> ", "  ", "  "])
        XCTAssertEqual(result?.containerLines.first?.line, NSRange(location: 0, length: 12))
    }

    func testCRLFKeepsLineRanges() {
        let text = "> цитата\r\n> вторая\r\n"
        XCTAssertEqual(fence(text)?.containerLines.map(\.line), [NSRange(location: 0, length: 10), NSRange(location: 10, length: 10)])
    }

    // MARK: - Ограждения в контейнерах

    private func assertFence(_ text: String, blocked: [NSRange], eof: Bool, lines: [MarkdownFenceContainerLine], available: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) {
        let result = fence(text, file: file, line: line)
        XCTAssertEqual(result?.blockedRanges, blocked, "blockedRanges: \(text.debugDescription)", file: file, line: line)
        XCTAssertEqual(result?.blockedEOF, eof, "blockedEOF: \(text.debugDescription)", file: file, line: line)
        XCTAssertEqual(result?.containerLines, lines, "containerLines: \(text.debugDescription)", file: file, line: line)
        XCTAssertEqual(result?.isAvailable, available, "isAvailable: \(text.debugDescription)", file: file, line: line)
    }

    private func containerLine(_ location: Int, _ length: Int, _ prefix: String, _ continuation: String) -> MarkdownFenceContainerLine {
        MarkdownFenceContainerLine(line: NSRange(location: location, length: length), sourcePrefix: prefix, continuationPrefix: continuation)
    }

    /// Незакрытое ограждение в цитате или пункте кончается вместе с контейнером: строка `foo` после цитаты ему не принадлежит
    /// (границу блока даёт контейнер из модели, а не `end_line` cmark).
    /// Следом идёт новое ограждение без тела: его открывающая строка не блокируется, но блок доходит до конца текста.
    func testUnclosedFenceInContainerBlocksOnlyContainerLines() {
        for text in ["> ```\nfoo\n```\n", "- ```\n```\n", "> ```\n```\n"] {
            assertFence(text, blocked: [NSRange(location: 0, length: 6)], eof: true, lines: [])
        }
    }

    /// Продолжение пункта подтверждается по тексту: префикс строки известен и там, где позиция cmark не подтверждена.
    func testContinuationLinesOfTaskAndTabbedItemsGivePrefixes() {
        let task = "- [ ] задача\n  продолжение\n- [x] готово\n"
        assertFence(task, blocked: [NSRange(location: 0, length: (task as NSString).length)], eof: true,
                    lines: [containerLine(13, 14, "  ", "  ")])
        let tabbed = "\tтаб\n\n- пункт\n\tпродолжение\n"
        assertFence(tabbed, blocked: [NSRange(location: 0, length: 5), NSRange(location: 6, length: (tabbed as NSString).length - 6)], eof: true,
                    lines: [containerLine(6, 8, "- ", "  "), containerLine(14, 13, "\t", "\t")])
    }

    /// Таб внутри текста цитаты (не в префиксе): единый слой подтверждает текст по таб-колонкам и отдаёт префикс `> `.
    func testTabInsideQuoteTextGivesQuotePrefix() {
        let quote = "> a\t**b** *c*\n"
        assertFence(quote, blocked: [NSRange(location: 0, length: 14)], eof: true, lines: [containerLine(0, 14, "> ", "> ")])
    }

    /// Таб в префиксе строки: позицию текста ядро не подтверждает, строка берётся по литералу в строках абзаца (как `tabbedLiteralTextRange`).
    func testTabInContainerPrefixKeepsLine() {
        let quote = "> \tцитата с табом\n"
        assertFence(quote, blocked: [NSRange(location: 0, length: 18)], eof: true, lines: [containerLine(0, 18, "> \t", "> \t")])
        let item = "-\tпункт с табом\n  продолжение\n"
        assertFence(item, blocked: [NSRange(location: 0, length: 30)], eof: true, lines: [containerLine(0, 16, "-\t", " \t")])
    }

    /// Плотные первые строки не сбивают сопоставление: последняя строка цитаты с табом всё равно получает запись.
    func testDenseFirstLineDoesNotLoseNextTabbedLine() {
        for first in ["> \t**a**,**b**,**c**,**d**,**e**\n", "> \ta*b*c*d*e*f*g*h*i\n", "> \tA &amp; B\n", "> \t&copy; 2024\n", "> \tцена\\*5\n"] {
            for newline in ["\n", "\r\n"] {
                let head = first.replacingOccurrences(of: "\n", with: newline)
                let text = head + "> \tследующая" + newline
                let location = (head as NSString).length
                let lines = fence(text)?.containerLines ?? []
                XCTAssertTrue(lines.contains { $0.line.location == location && $0.sourcePrefix == "> \t" }, "\(text.debugDescription)")
            }
        }
    }

    /// Большой абзац цитаты со строками с табом: каждая строка получает запись (сопоставление значений со строками по порядку).
    func testLargeQuoteParagraphWithTabsGivesLineForEveryRow() {
        let rows = (0..<2000).map { "> \tстрока \($0)\n" }
        let text = rows.joined()
        guard let result = fence(text) else { return XCTFail("нет контекста") }
        XCTAssertEqual(result.containerLines.count, 2000)
        var location = 0
        for (index, row) in rows.enumerated() {
            let length = (row as NSString).length
            XCTAssertEqual(result.containerLines.count > index ? result.containerLines[index].line : nil, NSRange(location: location, length: length), "строка \(index)")
            location += length
        }
    }

    /// Неподтверждённая цитата во всём тексте без перевода строки в конце: строки блока известны, доступность не теряется.
    func testUnconfirmedQuoteCoveringWholeTextStaysAvailable() {
        for text in ["> \tцитата", ">\tx", "> > \tx"] {
            let result = fence(text)
            XCTAssertEqual(result?.isAvailable, true, text.debugDescription)
            XCTAssertEqual(result?.blockedRanges, [NSRange(location: 0, length: (text as NSString).length)], text.debugDescription)
            XCTAssertEqual(result?.blockedEOF, true, text.debugDescription)
        }
    }

    // MARK: - Флаг и отмена

    func testFenceIsNilWithoutEditorContext() throws {
        for (id, text) in try corpus() {
            XCTAssertNil(MarkdownDocumentParser.parse(text, options: options([]))?.fence, "\(id): fence без флага")
        }
    }

    func testCancellationGivesNilForFence() {
        let text = "> цитата\n\n- пункт\n\n```\nкод\n"
        var total = 0
        XCTAssertNotNil(MarkdownDocumentParser.parse(text, options: options([.editorContext]), isCancelled: { total += 1; return false }))
        for cancelAt in [total / 2, total - 1, total] {
            var calls = 0
            let result = MarkdownDocumentParser.parse(text, options: options([.editorContext]), isCancelled: { calls += 1; return calls >= cancelAt })
            XCTAssertNil(result, "отмена на вызове \(cancelAt) из \(total)")
        }
        let model = MarkdownDocumentParser.parse(text, options: options([]))!
        XCTAssertNil(MarkdownDocumentParser.fence(of: model, text: text as NSString, isCancelled: { true }), "прямой вызов с отменой")
        XCTAssertNotNil(MarkdownDocumentParser.fence(of: model, text: text as NSString, isCancelled: { false }))
    }
}
