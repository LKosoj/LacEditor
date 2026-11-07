import Foundation
import XCTest
@testable import LacEditor

/// Привязка каретки к цепочке скрытых маркеров и правило скрытия `Reveal.hides` (чистая модель, без окон и AppKit).
final class MarkdownDisplayMapCaretTests: XCTestCase {
    private typealias Map = MarkdownDisplayMap

    private func parsed(_ source: String) -> MarkdownPresentation {
        MarkdownPresentationBuilder.parse(source)
    }

    /// Карта с `Reveal.none`: все маркеры на месте, текущее раскрытие приходит отдельно (как в контроллере).
    private func built(_ source: String) -> Map {
        Map(presentation: parsed(source), textLength: (source as NSString).length)
    }

    private func caret(_ map: Map, _ point: Int, reveal: Map.Reveal = .none) -> Int? {
        map.settledCaret(atSource: point, reveal: reveal)
    }

    private func range(_ source: String, _ part: String) -> NSRange {
        let found = (source as NSString).range(of: part)
        XCTAssertNotEqual(found.location, NSNotFound, part)
        return found
    }

    private func hiddenMarkers(_ map: Map) -> [NSRange] {
        map.entries.filter { $0.kind == .hiddenMarker }.map(\.source)
    }

    func testSettledCaretOutsideBoldAtLineStartAndEnd() {
        let source = "**жирный** текст\n"
        let map = built(source)
        // Перед `**` и после первых `**` каретка встаёт снаружи, внутри содержимого цепочки нет.
        XCTAssertEqual(caret(map, 0), 0)
        XCTAssertEqual(caret(map, 1), 0)
        XCTAssertEqual(caret(map, 2), 0)
        XCTAssertNil(caret(map, 5), "середина слова вне цепочки")
        // Справа от слова: позиция перед закрывающими `**` переезжает за них.
        XCTAssertEqual(caret(map, 8), 10)
        XCTAssertEqual(caret(map, 9), 10)
        XCTAssertEqual(caret(map, 10), 10)
        XCTAssertNil(caret(map, 12), "после цепочки, внутри обычного текста")
    }

    func testSettledCaretInsideNestedMarkersChoosesOutermost() {
        let source = "**_а_** б\n"
        let map = built(source)
        XCTAssertEqual(hiddenMarkers(map).count, 4, "две пары маркеров")
        XCTAssertEqual(caret(map, 3), 0, "после `**_` — снаружи обоих")
        XCTAssertEqual(caret(map, 2), 0)
        XCTAssertEqual(caret(map, 4), 7, "перед `_**` — за обоими")
    }

    func testSettledCaretAfterHeadingPrefixIsContentStart() {
        let source = "## Заголовок 中文\r\nтекст\r\n"
        let map = built(source)
        let prefix = hiddenMarkers(map)[0]
        XCTAssertEqual(prefix.location, 0)
        XCTAssertEqual(caret(map, 0), NSMaxRange(prefix), "блочный префикс не inline-владелец: каретка после него")
        XCTAssertEqual(caret(map, NSMaxRange(prefix)), NSMaxRange(prefix))
    }

    func testSettledCaretAfterQuotePrefix() {
        let source = "> цитата\r\n> вторая 😀\r\n\r\nконец\r\n"
        let map = built(source)
        let markers = hiddenMarkers(map)
        XCTAssertEqual(markers.count, 2)
        for marker in markers {
            XCTAssertEqual(caret(map, marker.location), NSMaxRange(marker), "цитата \(marker)")
        }
    }

    func testSettledCaretInHeadingWithInlinePlacesBetweenPrefixAndInline() {
        let source = "# **ж** x\n"
        let map = built(source)
        // Цепочка `# ` + `**`: у позиции после префикса глубина 0, после `**` — 1.
        XCTAssertEqual(caret(map, 0), 2)
        XCTAssertEqual(caret(map, 4), 2)
        XCTAssertEqual(caret(map, 2), 2)
    }

    func testSettledCaretBetweenAdjacentElements() {
        let source = "**а** __б__\n"
        // Без пробела соседние элементы cmark трактует по-разному; пробел оставляет пару цепочек раздельными.
        let map = built(source)
        let markers = hiddenMarkers(map)
        XCTAssertEqual(markers.count, 4)
        XCTAssertEqual(caret(map, NSMaxRange(markers[1])), NSMaxRange(markers[1]))
        XCTAssertEqual(caret(map, markers[2].location), markers[2].location)
    }

    func testSettledCaretIgnoresRevealedOwners() {
        let source = "**жирный** текст\n"
        let map = built(source)
        // Каретка внутри элемента: маркеры раскрыты, цепочки нет, привязывать нечего.
        for point in 0...10 {
            let reveal = Map.Reveal(revealedRange: NSRange(location: point, length: 0), inlineSelection: NSRange(location: point, length: 0))
            XCTAssertNil(caret(map, point, reveal: reveal), "каретка \(point) раскрывает элемент")
        }
        // Раскрыто в другом месте: цепочка скрыта.
        let far = Map.Reveal(revealedRange: NSRange(location: 14, length: 0), inlineSelection: NSRange(location: 14, length: 0))
        XCTAssertEqual(caret(map, 2, reveal: far), 0)
    }

    func testSettledCaretOfQuoteFollowsLineReveal() {
        let source = "> цитата\n\nконец\n"
        let map = built(source)
        let marker = hiddenMarkers(map)[0]
        let onQuote = Map.Reveal(revealedRange: NSRange(location: 4, length: 0), inlineSelection: NSRange(location: 4, length: 0))
        XCTAssertNil(caret(map, marker.location, reveal: onQuote), "цитата раскрыта строкой")
        let elsewhere = Map.Reveal(revealedRange: range(source, "конец"), inlineSelection: range(source, "конец"))
        XCTAssertEqual(caret(map, marker.location, reveal: elsewhere), NSMaxRange(marker))
    }

    func testSettledCaretKeepsPositionInUnreliableRegion() {
        let owner = NSRange(location: 0, length: 10)
        let map = Map(candidates: [
            .init(source: NSRange(location: 0, length: 3), kind: .hiddenMarker, displayLength: 0, owner: owner, isInline: true),
            .init(source: NSRange(location: 7, length: 3), kind: .hiddenMarker, displayLength: 0, owner: owner, isInline: true),
        ], textLength: 10, unreliable: [NSRange(location: 1, length: 4)])
        XCTAssertNil(caret(map, 2), "строго внутри ненадёжного участка")
        XCTAssertEqual(caret(map, 10), 10, "вне участка работает как обычно")
    }

    func testSettledCaretWithEmojiCjkAndCrLf() {
        let source = "😀 **中文** тест\r\n## Заг 😀\r\n> цитата\r\n"
        let map = built(source)
        let strong = range(source, "**中文**")
        XCTAssertEqual(caret(map, strong.location + 2), strong.location, "суррогатная пара перед маркером не сбивает позиции")
        XCTAssertEqual(caret(map, NSMaxRange(strong) - 2), NSMaxRange(strong))
        let heading = range(source, "## ")
        XCTAssertEqual(caret(map, heading.location), NSMaxRange(heading))
        let quote = range(source, "> ")
        // У цитаты markerRanges содержит только `>`; следующий пробел остаётся
        // обычной исходной позицией, в отличие от полного префикса заголовка.
        XCTAssertEqual(caret(map, quote.location), quote.location + 1)
        // `\r\n` между строками не входит в цепочку: позиция перед переводом строки — обычная.
        XCTAssertNil(caret(map, range(source, "\r\n## ").location))
    }

    /// Правило скрытия `Reveal.hides` должно совпадать с составом записей, который строит конструктор при том же раскрытии.
    func testHidesMatchesConstructorForManyReveals() {
        let sources = [
            "Привет **жирный 😀** и *курсив*\r\n## Заголовок 中文\r\n> цитата\r\n> вторая\r\n- пункт\r\n[ссылка](https://example.com) ~~зачёркнуто~~ `код`\r\n",
            "# **ж** x\n\n> **а** _б_\n\n1. один\n2. два **три**\n",
        ]
        for source in sources {
            let length = (source as NSString).length
            let presentation = parsed(source)
            let all = Map(presentation: presentation, textLength: length)
            var reveals: [Map.Reveal] = [.none]
            for point in stride(from: 0, through: length, by: 1) {
                let caret = NSRange(location: point, length: 0)
                let line = (source as NSString).lineRange(for: caret)
                reveals.append(Map.Reveal(revealedRange: line, inlineSelection: caret))
            }
            for chunk in [NSRange(location: 3, length: 9), NSRange(location: 0, length: length)] {
                reveals.append(Map.Reveal(revealedRange: (source as NSString).lineRange(for: chunk), inlineSelection: chunk))
            }
            for (index, reveal) in reveals.enumerated() {
                let direct = Map(presentation: presentation, textLength: length, reveal: reveal)
                let expected = Set(direct.entries.filter { $0.kind == .hiddenMarker }.map { "\($0.source.location),\($0.source.length)" })
                let actual = Set(all.entries.filter { reveal.hides($0) }.map { "\($0.source.location),\($0.source.length)" })
                XCTAssertEqual(actual, expected, "раскрытие №\(index) \(reveal)")
            }
        }
    }
}
