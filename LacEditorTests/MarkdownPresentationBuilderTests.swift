import Foundation
import XCTest
@testable import LacEditor

/// TextKit-адаптер (U5.1): оформление, которое `MarkdownPresentationBuilder` строит из модели ядра. Малые случаи с позициями в UTF-16.
final class MarkdownPresentationBuilderTests: XCTestCase {
    /// Та же цепочка, что у `PresentationBaselineSet.parse`: ядро, затем адаптер.
    private func build(_ text: String, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(),
                       isCancelled: @escaping () -> Bool = { false },
                       file: StaticString = #filePath, line: UInt = #line) -> MarkdownPresentation {
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: [.elementIndex, .editorContext], isVaultNote: false, detectsFrontMatter: true)
        guard let model = MarkdownDocumentParser.parse(text, options: options) else {
            XCTFail("разбор вернул nil", file: file, line: line)
            return MarkdownPresentation(spans: [])
        }
        return MarkdownPresentationBuilder.build(model, text: text as NSString, options: .init(syntax: syntax), isCancelled: isCancelled)
    }

    private func range(of part: String, in text: String, file: StaticString = #filePath, line: UInt = #line) -> NSRange {
        let found = (text as NSString).range(of: part)
        XCTAssertNotEqual(found.location, NSNotFound, "в тексте нет «\(part)»", file: file, line: line)
        return found
    }

    func testClosingHashesAreMarkersAndCyrillicEmojiHeadingKeepsUTF16RangesWithCRLF() {
        let text = "## Привет 😀 мир ##\r\nТекст"
        let presentation = build(text)
        let line = range(of: "## Привет 😀 мир ##", in: text)
        XCTAssertEqual(presentation.headings.count, 1)
        XCTAssertEqual(presentation.headings.first?.level, 2)
        XCTAssertEqual(presentation.headings.first?.title, "Привет 😀 мир", "закрывающие # не входят в название")
        XCTAssertEqual(presentation.headings.first?.range, line, "диапазон — строка без \\r\\n")
        let span = presentation.spans.first { $0.kind == .heading(2) }
        XCTAssertEqual(span?.range, line)
        XCTAssertEqual(span?.markerRanges, [range(of: "## ", in: text), NSRange(location: line.length - 2, length: 2)],
                       "маркеры: открывающие «## » и закрывающие «##»")
        XCTAssertEqual(presentation.paragraphs.map(\.range), [range(of: "Текст", in: text)], "абзац после \\r\\n начинается с \"Т\"")
    }

    // Диаграмма оформляется только закрытым блоком верхнего уровня: в цитате, пункте списка и с незакрытым ограждением — нет.
    func testDiagramOnlyForClosedTopLevelFence() {
        let fence = "```mermaid\nA --> B\n```"
        XCTAssertEqual(build("Привет 中😀\r\n\r\n" + fence.replacingOccurrences(of: "\n", with: "\r\n")).diagrams.count, 1)
        XCTAssertEqual(build("> " + fence.replacingOccurrences(of: "\n", with: "\n> ")).diagrams.count, 0, "в цитате")
        XCTAssertEqual(build("- " + fence.replacingOccurrences(of: "\n", with: "\n  ")).diagrams.count, 0, "в пункте списка")
        XCTAssertEqual(build("```mermaid\nA --> B\n").diagrams.count, 0, "незакрытое ограждение")
    }

    func testCJKHeadingWithClosingHash() {
        let text = "# 汉字 #\n"
        let presentation = build(text)
        let span = presentation.spans.first { $0.kind == .heading(1) }
        XCTAssertEqual(span?.range, NSRange(location: 0, length: 6))
        XCTAssertEqual(span?.markerRanges, [NSRange(location: 0, length: 2), NSRange(location: 5, length: 1)])
        XCTAssertEqual(presentation.headings.first?.title, "汉字")
    }

    func testStrongAfterEmojiUsesSurrogatePairLengths() {
        let text = "😀 **жир** 汉字"
        let presentation = build(text)
        let strong = presentation.spans.first { $0.kind == .strong }
        XCTAssertEqual(strong?.range, range(of: "**жир**", in: text))
        XCTAssertEqual(strong?.range.location, 3, "эмодзи занимает две единицы UTF-16")
        XCTAssertEqual(strong?.markerRanges, [NSRange(location: 3, length: 2), NSRange(location: 8, length: 2)])
    }

    func testListMarkersWithCRLFAndEmojiLines() {
        let text = "- 😀 раз\r\n- 汉字\r\n- три"
        let presentation = build(text)
        let markers = presentation.listMarkers
        XCTAssertEqual(markers.map(\.range.location), [0, (text as NSString).range(of: "- 汉字").location, (text as NSString).range(of: "- три").location])
        XCTAssertEqual(markers.map(\.range.length), [1, 1, 1], "оформляется только символ маркера")
        XCTAssertEqual(markers.map(\.depth), [1, 1, 1])
        XCTAssertEqual(markers.map(\.text), ["•", "•", "•"])
    }

    func testQuoteInsideListItemGetsQuoteSpanAtItsOwnMarker() {
        let text = "- пункт\n  > цитата 汉字\n"
        let presentation = build(text)
        let quoteLine = range(of: "> цитата 汉字", in: text)
        XCTAssertEqual(presentation.listMarkers.map(\.range), [NSRange(location: 0, length: 1)])
        let quote = presentation.spans.first { $0.kind == .quote }
        XCTAssertEqual(quote?.range, quoteLine)
        XCTAssertEqual(quote?.markerRanges, [NSRange(location: quoteLine.location, length: 1)], "маркер цитаты — только «>»")
    }

    func testTableCellWithInlineMathHasFormulaRunAndInlineFormula() {
        let text = "| a | b |\n|---|---|\n| $x$ | Я |\n"
        let presentation = build(text)
        XCTAssertEqual(presentation.tables.count, 1)
        let table = presentation.tables[0]
        XCTAssertEqual(table.range.location, 0)
        XCTAssertEqual(table.delimiterRange, range(of: "|---|---|", in: text))
        XCTAssertEqual(table.rows.count, 2)
        let cells = table.rows[1].cells
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].displayText, "$x$")
        XCTAssertEqual(cells[0].displayRuns.count, 1, "в ячейке один прогон-формула")
        XCTAssertEqual(cells[0].displayRuns.first?.kind, .tableMath(NSRange(location: 1, length: 3)))
        XCTAssertEqual(cells[0].range, range(of: " $x$ ", in: text))
        XCTAssertEqual(cells[1].displayText, "Я")
        XCTAssertEqual(cells[1].range, range(of: " Я ", in: text))
        let formula = presentation.inlineFormulas.first
        XCTAssertEqual(formula?.source, "x")
        XCTAssertEqual(formula?.range, range(of: "$x$", in: text))
    }

    func testInlineMathDisabledGivesNoFormulaInTableCell() {
        let text = "| a | b |\n|---|---|\n| $x$ | Я |\n"
        let presentation = build(text, syntax: MarkdownSyntaxOptions(inlineMath: false))
        XCTAssertTrue(presentation.inlineFormulas.isEmpty)
        let runs = presentation.tables.first?.rows[1].cells[0].displayRuns ?? []
        XCTAssertFalse(runs.contains { if case .tableMath = $0.kind { return true } else { return false } })
    }

    func testCancellationReturnsEmptyPresentation() {
        let text = "# Заголовок\n\n- пункт\n\n| a |\n|---|\n| b |\n"
        XCTAssertFalse(build(text).spans.isEmpty, "без отмены оформление есть")
        let cancelled = build(text, isCancelled: { true })
        XCTAssertTrue(cancelled.spans.isEmpty)
        XCTAssertTrue(cancelled.headings.isEmpty)
        XCTAssertTrue(cancelled.listMarkers.isEmpty)
        XCTAssertTrue(cancelled.tables.isEmpty)
    }
}
