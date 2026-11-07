import AppKit
import XCTest
@testable import LacEditor

/// Раскрытие маркеров в раскладке: согласие с картой текста и стабильность высот строк.
@MainActor
final class MarkdownRevealLayoutTests: XCTestCase {
    private func makeLayout(_ source: String, width: CGFloat = 600) -> (NSTextStorage, FoldLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: width, height: 4_000))
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    private func y(_ layout: FoldLayoutManager, _ container: NSTextContainer, _ range: NSRange) -> CGFloat {
        layout.ensureLayout(for: container)
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil).minY
    }

    /// Две копии правила раскрытия (раскладка и `Reveal.hides`) не должны разойтись ни в одной позиции.
    func testHiddenStateMatchesMapForEveryPosition() {
        let source = "Привет **жирный 😀** и *курсив*\r\n## Заголовок 中文\r\n> цитата\r\n> вторая\r\n- пункт\r\n[ссылка](https://example.com) ~~зачёркнуто~~ `код`\r\n"
        let raw = source as NSString
        let presentation = MarkdownPresentationBuilder.parse(source)
        let map = MarkdownDisplayMap(presentation: presentation, textLength: raw.length)
        let (_, layout, _) = makeLayout(source)
        var reveals: [(revealed: NSRange?, inline: NSRange?)] = [(nil, nil)]
        for point in 0...raw.length {
            let caret = NSRange(location: point, length: 0)
            reveals.append((raw.lineRange(for: caret), caret))
            reveals.append((raw.lineRange(for: caret), nil))
        }
        let selection = NSRange(location: 3, length: 12)
        reveals.append((raw.lineRange(for: selection), selection))
        for (index, state) in reveals.enumerated() {
            layout.setMarkdownPresentation(presentation, revealedRange: state.revealed, inlineSelection: state.inline)
            XCTAssertEqual(layout.markdownRevealState.revealed, state.revealed)
            XCTAssertEqual(layout.markdownRevealState.inline, state.inline)
            let reveal = MarkdownDisplayMap.Reveal(revealedRange: state.revealed, inlineSelection: state.inline)
            for position in 0..<raw.length {
                let expected = map.entries.contains { NSLocationInRange(position, $0.source) && reveal.hides($0) }
                XCTAssertEqual(layout.isMarkdownMarkerHidden(at: position), expected, "раскрытие №\(index), позиция \(position)")
            }
        }
    }

    /// Раскрытие заголовка, цитаты, списка, кода и inline не двигает текст ниже: меняется только ширина строки.
    func testRevealKeepsLineHeightsForHeadingListQuoteCodeAndInline() {
        let source = "## Заголовок 中文\n\n> цитата\n\n- пункт\n\n```swift\nlet x = 1\n```\n\nСтрока **жирная** 😀\n\nконец"
        let raw = source as NSString
        let presentation = MarkdownPresentationBuilder.parse(source)
        let (_, layout, container) = makeLayout(source)
        let end = raw.range(of: "конец")
        layout.setMarkdownPresentation(presentation, revealedRange: nil)
        let collapsed = y(layout, container, end)
        for part in ["Заголовок", "цитата", "пункт", "let x", "жирная"] {
            let place = raw.range(of: part)
            layout.updateMarkdownInlineSelection(NSRange(location: place.location, length: 0))
            layout.updateMarkdownRevealedRange(raw.lineRange(for: place))
            XCTAssertEqual(y(layout, container, end), collapsed, accuracy: 0.5, "раскрыто: \(part)")
        }
    }

    /// Интервал между абзацами: раскрытие абзаца с одной пустой строкой не сдвигает текст ниже.
    func testRevealWithParagraphSpacingKeepsTextBelow() {
        let source = "первый абзац\n\nвторой абзац\n\nконец"
        let raw = source as NSString
        let presentation = MarkdownPresentationBuilder.parse(source)
        for spacing in [CGFloat(40), 24] {
            let (_, layout, container) = makeLayout(source)
            layout.markdownParagraphSpacing = spacing
            layout.setMarkdownPresentation(presentation, revealedRange: nil)
            let end = raw.range(of: "конец")
            let collapsed = y(layout, container, end)
            layout.updateMarkdownRevealedRange(raw.range(of: "первый абзац"))
            XCTAssertEqual(y(layout, container, end), collapsed, accuracy: 0.5, "интервал \(spacing)")
        }
    }

    /// Раскрытая строка-разделитель не ниже обычной строки при любом интервале (0, 4, 40): каретка на ней видна.
    func testRevealedSeparatorLineIsNotLowerThanTextLine() {
        let source = "первый абзац\n\nвторой абзац"
        let raw = source as NSString
        let presentation = MarkdownPresentationBuilder.parse(source)
        for spacing in [CGFloat(0), 4, 40] {
            let (_, layout, container) = makeLayout(source)
            layout.markdownParagraphSpacing = spacing
            layout.setMarkdownPresentation(presentation, revealedRange: nil)
            let separator = NSRange(location: raw.range(of: "\n\n").location + 1, length: 1)
            layout.updateMarkdownRevealedRange(raw.range(of: "первый абзац"))
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: separator.location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertGreaterThanOrEqual(rect.height + 0.01, layout.editorLineHeight, "интервал \(spacing)")
            let caret = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            XCTAssertGreaterThan(caret.height, 1, "каретка видна, интервал \(spacing)")
        }
    }

    /// Несколько пустых строк между абзацами — записанное исключение: раскрытый абзац показывает их полностью.
    func testRevealWithParagraphSpacingAndSeveralBlankLinesIsDocumentedException() {
        let source = "первый\n\n\nвторой\n\nконец"
        let raw = source as NSString
        let presentation = MarkdownPresentationBuilder.parse(source)
        let (_, layout, container) = makeLayout(source)
        layout.markdownParagraphSpacing = 4
        layout.setMarkdownPresentation(presentation, revealedRange: nil)
        let end = raw.range(of: "конец")
        let collapsed = y(layout, container, end)
        layout.updateMarkdownRevealedRange(raw.range(of: "первый"))
        XCTAssertGreaterThan(y(layout, container, end), collapsed + 1)
    }

    /// Перенос внутри раскрытого абзаца допустим, но текст ниже сдвигается только на целое число строк.
    func testRevealWrapChangeShiftsTextBelowOnlyByWholeLines() {
        let source = String(repeating: "слово ", count: 9) + "**жирный** " + String(repeating: "слово ", count: 6) + "\n\nконец"
        let raw = source as NSString
        let presentation = MarkdownPresentationBuilder.parse(source)
        let (_, layout, container) = makeLayout(source, width: 160)
        layout.setMarkdownPresentation(presentation, revealedRange: nil)
        let end = raw.range(of: "конец")
        let collapsed = y(layout, container, end)
        let lineHeight = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        let bold = raw.range(of: "жирный")
        layout.updateMarkdownInlineSelection(NSRange(location: bold.location, length: 0))
        layout.updateMarkdownRevealedRange(raw.lineRange(for: bold))
        let shift = (y(layout, container, end) - collapsed) / lineHeight
        XCTAssertEqual(shift, shift.rounded(), accuracy: 0.05, "сдвиг \(shift) строк")
    }
}
