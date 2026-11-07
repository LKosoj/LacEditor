import Foundation
import XCTest
@testable import LacEditor

/// Карта «текст редактора ↔ видимый текст»: чистая модель без окон и AppKit.
final class MarkdownDisplayMapTests: XCTestCase {
    private typealias Map = MarkdownDisplayMap

    private func parsed(_ source: String, emoji: Bool = false) -> MarkdownPresentation {
        MarkdownPresentationBuilder.parse(source, includeEmojiCandidates: emoji)
    }

    private func built(_ source: String, reveal: Map.Reveal = .none, emoji: Bool = false) -> Map {
        Map(presentation: parsed(source, emoji: emoji), textLength: (source as NSString).length, reveal: reveal)
    }

    /// Диапазон подстроки в UTF-16.
    private func range(_ source: String, _ part: String, occurrence: Int = 0) -> NSRange {
        var found = NSRange(location: NSNotFound, length: 0)
        var search = NSRange(location: 0, length: (source as NSString).length)
        for _ in 0...occurrence {
            found = (source as NSString).range(of: part, options: [], range: search)
            guard found.location != NSNotFound else { break }
            search = NSRange(location: NSMaxRange(found), length: (source as NSString).length - NSMaxRange(found))
        }
        XCTAssertNotEqual(found.location, NSNotFound, part)
        return found
    }

    private func display(_ map: Map, _ location: Int, interior: Map.Interior = .fail) -> Int? {
        if case .success(let value) = map.displayLocation(forSource: location, interior: interior) { return value }
        return nil
    }

    private func source(_ map: Map, _ location: Int, _ affinity: Map.Affinity, interior: Map.Interior = .fail) -> Int? {
        if case .success(let value) = map.sourceLocation(forDisplay: location, affinity: affinity, interior: interior) { return value }
        return nil
    }

    private func sourceRange(_ map: Map, _ range: NSRange, _ coverage: Map.Coverage = .tight, caret: Map.Affinity = .leading) -> NSRange? {
        if case .success(let value) = map.sourceRange(forDisplay: range, coverage: coverage, caretAffinity: caret) { return value }
        return nil
    }

    private func hidden(_ map: Map) -> [NSRange] {
        map.entries.filter { $0.kind == .hiddenMarker }.map(\.source)
    }

    /// Наивная проверка: записи отсортированы и не пересекаются, длины сходятся, позиции монотонны и обратимы.
    private func bruteForce(_ map: Map, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        var end = 0, delta = 0
        for entry in map.entries {
            XCTAssertGreaterThan(entry.source.length, 0, "\(message): пустая запись", file: file, line: line)
            XCTAssertGreaterThanOrEqual(entry.source.location, end, "\(message): записи пересекаются", file: file, line: line)
            XCTAssertEqual(entry.displayStart, entry.source.location + delta, "\(message): displayStart", file: file, line: line)
            end = NSMaxRange(entry.source)
            delta += entry.displayLength - entry.source.length
        }
        XCTAssertLessThanOrEqual(end, map.sourceLength, message, file: file, line: line)
        XCTAssertEqual(map.displayLength, map.sourceLength + delta, "\(message): длина", file: file, line: line)
        var previous = -1
        for point in 0...map.sourceLength {
            guard let shown = display(map, point), map.unreliable.isEmpty else { continue }
            XCTAssertGreaterThanOrEqual(shown, previous, "\(message): монотонность p=\(point)", file: file, line: line)
            previous = shown
            guard let low = source(map, shown, .leading), let high = source(map, shown, .trailing) else {
                XCTFail("\(message): нет обратной позиции d=\(shown)", file: file, line: line)
                continue
            }
            XCTAssertLessThanOrEqual(low, high, "\(message): leading<=trailing d=\(shown)", file: file, line: line)
            XCTAssertTrue(point >= low && point <= high, "\(message): p=\(point) вне [\(low), \(high)]", file: file, line: line)
            XCTAssertEqual(display(map, low), shown, "\(message): display(source(d)) d=\(shown)", file: file, line: line)
            let nearHidden = [map.entry(atSource: point), point > 0 ? map.entry(atSource: point - 1) : nil]
                .compactMap { $0 }.contains { $0.displayLength == 0 }
            if !nearHidden { XCTAssertTrue(low == point && high == point, "\(message): обратимость p=\(point)", file: file, line: line) }
        }
    }

    // MARK: Скрытые маркеры

    func testStrongMarkersAreHiddenAndPositionsCollapse() {
        let text = "**bold** text"
        let map = built(text)
        XCTAssertEqual(hidden(map), [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
        XCTAssertEqual(map.displayLength, 9)
        XCTAssertEqual(display(map, 2), 0)
        XCTAssertEqual(display(map, 6), 4)
        XCTAssertEqual(display(map, 8), 4)
        XCTAssertEqual(source(map, 0, .leading), 0)
        XCTAssertEqual(source(map, 0, .trailing), 2)
        XCTAssertEqual(source(map, 4, .leading), 6)
        XCTAssertEqual(source(map, 4, .trailing), 8)
        XCTAssertEqual(sourceRange(map, NSRange(location: 0, length: 4)), NSRange(location: 2, length: 4))
        XCTAssertEqual(sourceRange(map, NSRange(location: 0, length: 4), .covering), NSRange(location: 0, length: 8))
        XCTAssertEqual(sourceRange(map, NSRange(location: 4, length: 0), caret: .leading), NSRange(location: 6, length: 0))
        XCTAssertEqual(sourceRange(map, NSRange(location: 4, length: 0), caret: .trailing), NSRange(location: 8, length: 0))
        bruteForce(map, text)
    }

    func testHeadingAndQuoteMarkersRevealWhenCaretTouchesBlock() {
        let text = "# Заголовок\n\n> цитата"
        let hiddenBlocks = hidden(built(text))
        XCTAssertTrue(hiddenBlocks.contains(NSRange(location: 0, length: 2)), "# скрыт")
        XCTAssertTrue(hiddenBlocks.contains { $0.location == range(text, "> ").location }, "> скрыт")
        let revealed = built(text, reveal: Map.Reveal(revealedRange: NSRange(location: 2, length: 0)))
        XCTAssertFalse(hidden(revealed).contains(NSRange(location: 0, length: 2)), "# раскрыт")
        XCTAssertTrue(hidden(revealed).contains { $0.location == range(text, "> ").location }, "> остаётся скрытым")
        XCTAssertEqual(revealed.displayLength, built(text).displayLength + 2)
    }

    func testNestedInlineMarkersMapTightAndCoveringRanges() {
        let text = "**bold *it* end**"
        let map = built(text)
        XCTAssertEqual(hidden(map), [NSRange(location: 0, length: 2), NSRange(location: 7, length: 1),
                                     NSRange(location: 10, length: 1), NSRange(location: 15, length: 2)])
        XCTAssertEqual(map.displayLength, 11)
        XCTAssertEqual(sourceRange(map, NSRange(location: 5, length: 2)), NSRange(location: 8, length: 2))
        XCTAssertEqual(sourceRange(map, NSRange(location: 5, length: 2), .covering), NSRange(location: 7, length: 4))
        // Выделение, захватившее маркер, расширяется до элемента; чистое содержимое не меняется.
        XCTAssertEqual(map.expandToElement(NSRange(location: 7, length: 2)), NSRange(location: 7, length: 4))
        XCTAssertEqual(map.expandToElement(NSRange(location: 1, length: 3)), NSRange(location: 0, length: 17))
        XCTAssertEqual(map.expandToElement(NSRange(location: 2, length: 4)), NSRange(location: 2, length: 4))
        // Курсор внутри курсива касается и жирного: раскрыто всё. Курсор в жирном вне курсива раскрывает только жирный.
        let inItalic = self.built(text, reveal: Map.Reveal(inlineSelection: NSRange(location: 8, length: 1)))
        XCTAssertTrue(hidden(inItalic).isEmpty, "выделение внутри касается обоих элементов")
        let inStrong = self.built(text, reveal: Map.Reveal(inlineSelection: NSRange(location: 3, length: 0)))
        XCTAssertEqual(hidden(inStrong), [NSRange(location: 7, length: 1), NSRange(location: 10, length: 1)])
        bruteForce(map, text)
    }

    func testAstralAndCombiningCharactersKeepUTF16Lengths() {
        let emoji = "**😀** x"
        let map = built(emoji)
        XCTAssertEqual(hidden(map), [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        XCTAssertEqual(map.displayLength, 4)
        XCTAssertEqual(sourceRange(map, NSRange(location: 0, length: 2)), NSRange(location: 2, length: 2))
        for text in ["**Привет** мир", "中文 **粗体** 日本語", "**e\u{301}** x", emoji] {
            let current = self.built(text)
            XCTAssertEqual(current.sourceLength, (text as NSString).length)
            XCTAssertEqual(current.displayLength, (text as NSString).length - 4, text)
            bruteForce(current, text)
        }
    }

    func testCRLFKeepsLineBreaksOneToOne() {
        for text in ["**a**\r\n**b**", "**a**\n**b**"] {
            let map = built(text)
            let crlf = text.contains("\r") ? 1 : 0
            XCTAssertEqual(hidden(map).count, 4, text.debugDescription)
            XCTAssertEqual(map.displayLength, 3 + crlf, text.debugDescription)
            XCTAssertEqual(display(map, 5), 1, "\\r или \\n: один символ")
            XCTAssertEqual(display(map, 6), 2)
            XCTAssertEqual(display(map, 6 + crlf), 2 + crlf)
            bruteForce(map, text.debugDescription)
        }
    }

    // MARK: Замены

    func testBlockImageIsAtomicReplacement() {
        let text = "![alt](a.png)"
        let presentation = parsed(text)
        XCTAssertEqual(presentation.images.count, 1)
        let map = Map(presentation: presentation, textLength: 13)
        XCTAssertEqual(map.entries.map(\.kind), [.replacement(.blockImage)])
        XCTAssertEqual(map.displayLength, 1)
        XCTAssertEqual(map.displayLocation(forSource: 6), .failure(.insideReplacement(NSRange(location: 0, length: 13))))
        XCTAssertEqual(display(map, 6, interior: .snapDown), 0)
        XCTAssertEqual(display(map, 6, interior: .snapUp), 1)
        XCTAssertEqual(sourceRange(map, NSRange(location: 0, length: 1)), NSRange(location: 0, length: 13))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 6, length: 0)),
                       .forbidden(.insideReplacement(.blockImage, NSRange(location: 0, length: 13))))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 0, length: 13)), .allowed)
        // Картинка ещё не установлена: ссылка видна как текст.
        let shown = Map(presentation: presentation, textLength: 13, isReplacementShown: { _, _ in false })
        XCTAssertTrue(shown.entries.isEmpty)
        XCTAssertEqual(shown.displayLength, 13)
        bruteForce(shown, text)
    }

    func testInlineImageKeepsSurroundingText() {
        let text = "text ![a](b.png) more"
        let map = built(text)
        XCTAssertEqual(map.entries.map(\.kind), [.replacement(.inlineImage)])
        XCTAssertEqual(map.entries.first?.source, NSRange(location: 5, length: 11))
        XCTAssertEqual(map.displayLength, (text as NSString).length - 10)
        XCTAssertEqual(display(map, 16), 6)
        bruteForce(map, text)
    }

    func testTaskCheckboxIsReplacedUnlessSelectionTouchesIt() {
        let text = "- [ ] task"
        XCTAssertEqual(built(text).entries.filter { $0.kind == .replacement(.checkbox) }.count, 1)
        XCTAssertEqual(built(text).entries.first { $0.kind == .replacement(.checkbox) }?.displayLength, 1)
        let touching = built(text, reveal: Map.Reveal(selection: NSRange(location: 2, length: 1)))
        XCTAssertTrue(touching.entries.filter { $0.kind == .replacement(.checkbox) }.isEmpty)
        let caret = built(text, reveal: Map.Reveal(selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(caret.entries.filter { $0.kind == .replacement(.checkbox) }.count, 1)
    }

    func testEmojiCandidateIsAtomicOnlyWhenIncluded() {
        let text = ":smile: text"
        XCTAssertTrue(built(text).entries.filter { $0.kind == .replacement(.emoji) }.isEmpty)
        let map = built(text, emoji: true)
        let emoji = map.entries.filter { $0.kind == .replacement(.emoji) }
        XCTAssertEqual(emoji.count, 1)
        XCTAssertEqual(emoji.first?.displayLength, 1)
        bruteForce(map, text)
    }

    func testListMarkersUseReportedLengthAndRevealOnLine() {
        let text = "- one\n- two"
        let presentation = parsed(text)
        let map = Map(presentation: presentation, textLength: 11, listMarkerLength: { _ in 3 })
        let markers = map.entries.filter { $0.kind == .replacement(.listMarker) }
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers.map(\.displayLength), [3, 3])
        let revealed = Map(presentation: presentation, textLength: 11, reveal: Map.Reveal(revealedRange: NSRange(location: 3, length: 0)))
        XCTAssertEqual(revealed.entries.filter { $0.kind == .replacement(.listMarker) }.count, 1)
    }

    func testNestedListAndQuoteMarkersDoNotOverlap() {
        for text in ["> - **a** x\n>   - **b**", "- > **q**\n  > text", "1. one\n   - **two**"] {
            let map = built(text)
            XCTAssertFalse(map.entries.isEmpty, text)
            bruteForce(map, text.debugDescription)
        }
    }

    // MARK: Таблицы

    func testTableCellsReplaceStructureAndForbidInnerEditing() {
        let text = "| a | **b** |\n|---|---|\n| 1 | 2 |"
        let presentation = parsed(text)
        XCTAssertEqual(presentation.tables.count, 1)
        let table = presentation.tables[0]
        let length = (text as NSString).length
        let map = Map(presentation: presentation, textLength: length)
        let cells = table.rows.flatMap(\.cells).filter { $0.range.length > 0 }
        XCTAssertEqual(map.entries.filter { $0.kind == .replacement(.tableCell) }.count, cells.count)
        let shownText = cells.reduce(0) { $0 + ($1.displayText?.utf16.count ?? $1.range.length) }
        XCTAssertEqual(map.displayLength, length - table.range.length + shownText)
        let inside = NSRange(location: table.range.location + 3, length: 0)
        XCTAssertEqual(map.editability(ofSource: inside), .forbidden(.tableCell(table: table.range)))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: table.range.location, length: 0)), .allowed)
        XCTAssertEqual(map.editability(ofSource: NSRange(location: NSMaxRange(table.range), length: 0)), .allowed)
        XCTAssertEqual(map.editability(ofSource: table.range), .allowed)
        XCTAssertEqual(map.editability(ofSource: NSRange(location: table.range.location, length: table.range.length / 2)),
                       .forbidden(.tableCell(table: table.range)))
        XCTAssertEqual(map.expandToElement(NSRange(location: table.range.location + 2, length: 4)), table.range)
    }

    func testTableWithEmptyCellAndEscapedPipeBuildsConsistentMap() {
        for text in ["| a | b |\n|---|---|\n|   | x |", "| a \\| b | c |\n|---|---|\n| 1 | 2 |"] {
            let map = built(text)
            XCTAssertFalse(map.entries.isEmpty, text.debugDescription)
            XCTAssertEqual(map.entries.filter { $0.kind == .tableStructure }.isEmpty, false)
            bruteForce(map, text.debugDescription)
        }
    }

    // MARK: Правка и ненадёжные участки

    func testEditabilityAroundInlineMarkers() {
        let map = built("a **b** c")
        for caret in [0, 2, 4, 5, 7, 9] {
            XCTAssertEqual(map.editability(ofSource: NSRange(location: caret, length: 0)), .allowed, "каретка \(caret)")
        }
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 3, length: 0)), .forbidden(.insideHiddenSyntax(owner: NSRange(location: 2, length: 5))))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 2, length: 2)), .forbidden(.splitsElement(owner: NSRange(location: 2, length: 5))))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 2, length: 5)), .allowed)
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 4, length: 1)), .allowed)
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 3, length: 2)), .forbidden(.insideHiddenSyntax(owner: NSRange(location: 2, length: 5))))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 8, length: 5)), .forbidden(.outOfBounds))
    }

    func testReasonPriorityTableBeforeUnreliableBeforeEntries() {
        // Таблица и ненадёжный участок накладываются; каретка внутри обоих — отказ по таблице.
        let table = NSRange(location: 10, length: 20)
        let candidates = [Map.Candidate(source: NSRange(location: 12, length: 4), kind: .replacement(.tableCell), displayLength: 1, owner: table),
                          Map.Candidate(source: NSRange(location: 16, length: 2), kind: .tableStructure, displayLength: 0, owner: table)]
        let map = Map(candidates: candidates, textLength: 40, unreliable: [NSRange(location: 14, length: 10), NSRange(location: 34, length: 4)])
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 17, length: 0)), .forbidden(.tableCell(table: table)))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 36, length: 0)), .forbidden(.unreliableRegion(NSRange(location: 34, length: 4))))
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 5, length: 0)), .allowed)
        XCTAssertEqual(map.editability(ofSource: NSRange(location: 34, length: 4)), .allowed)
    }

    func testUnreliableBoundaryIsTrustedAndInteriorFails() {
        let region = NSRange(location: 4, length: 6)
        let map = Map(candidates: [], textLength: 20, unreliable: [region])
        XCTAssertEqual(display(map, 4), 4)
        XCTAssertEqual(display(map, 10), 10)
        XCTAssertEqual(map.displayLocation(forSource: 7), .failure(.unreliableRegion(region)))
        XCTAssertEqual(map.sourceLocation(forDisplay: 7, affinity: .leading), .failure(.unreliableRegion(region)))
    }

    /// Главный критерий: каждый strong/emph/link либо получил span со скрытыми маркерами, либо строки покрыты `unreliableRanges`.
    private func assertEveryInlineIsMappedOrFlagged(_ text: String, inlines: Int, file: StaticString = #filePath, line: UInt = #line) {
        let presentation = parsed(text)
        let map = Map(presentation: presentation, textLength: (text as NSString).length)
        let mapped = presentation.spans.filter { span in
            switch span.kind { case .strong, .emphasis, .link: return !span.markerRanges.isEmpty; default: return false }
        }.count
        if mapped >= inlines {
            XCTAssertGreaterThanOrEqual(hidden(map).count, inlines, "\(text.debugDescription): span есть, а скрытых маркеров меньше", file: file, line: line)
            return
        }
        // Нет span: первый видимый маркер (`*` или `[`), который карта не скрыла, обязан лежать в ненадёжном участке.
        let raw = text as NSString
        var position = 0
        while position < raw.length, !([42, 91].contains(raw.character(at: position)) && map.entry(atSource: position) == nil) { position += 1 }
        guard position < raw.length else { return XCTFail("\(text.debugDescription): нет видимого маркера", file: file, line: line) }
        guard let region = presentation.unreliableRanges.first(where: { NSLocationInRange(position, $0) }) else {
            return XCTFail("\(text.debugDescription): span \(mapped) из \(inlines), маркер в \(position) не покрыт unreliableRanges \(presentation.unreliableRanges)", file: file, line: line)
        }
        XCTAssertGreaterThan(region.length, 1, text.debugDescription, file: file, line: line)
        if position > region.location {
            let inner = NSRange(location: position, length: 0)
            XCTAssertEqual(map.editability(ofSource: inner), .forbidden(.unreliableRegion(region)), text.debugDescription, file: file, line: line)
        }
    }

    func testTabsMultilineBackslashAndLinksNeverLoseBothSpanAndFlag() {
        let cases: [(String, Int)] = [("-\t**bold** item", 1), ("> -\t**x**", 1), ("1.\t*em*", 1),
                                      ("a\\\nx`**c**`\nxy**c**", 1), ("[multi\nline](http://x.com/中文)", 1),
                                      ("> - **a** x\n>   - **b**", 2), ("- > **q**\n  > text", 1)]
        for (text, inlines) in cases { assertEveryInlineIsMappedOrFlagged(text, inlines: inlines) }
        // У ссылочной формы `[a][ref]` маркеров нет (скобки видны, как у автоссылки): не теряться должна сама подсветка ссылки либо пометка участка.
        let reference = "[a][ref]\n\n[ref]: http://x.com\n  \"t\""
        let presentation = parsed(reference)
        let linkRange = range(reference, "[a][ref]")
        XCTAssertTrue(presentation.spans.contains { $0.kind == .link && $0.range == linkRange }
                      || presentation.unreliableRanges.contains { NSLocationInRange(linkRange.location, $0) }, reference.debugDescription)
    }

    func testPlainDocumentHasNoUnreliableRanges() {
        for text in ["one\n**two**", "# Title\n\nplain *text* and **bold**\n\n- item\n- item", "**a**\r\n**b**"] {
            XCTAssertTrue(parsed(text).unreliableRanges.isEmpty, text.debugDescription)
        }
    }

    func testUnreliableRangesSurviveShiftAndCopies() throws {
        let head = "plain head\n\n"
        let text = head + "a\\\nx`**c**`\nxy**c**\n\nplain tail"
        var presentation = parsed(text, emoji: true)
        let flagged = presentation.unreliableRanges
        XCTAssertFalse(flagged.isEmpty, "ожидался ненадёжный участок")
        XCTAssertEqual(presentation.numberingHeadings(false).unreliableRanges, flagged)
        XCTAssertEqual(presentation.resolvingHeadingEmoji([:]).unreliableRanges, flagged)
        // Набор буквы внутри обычного абзаца быстрый путь принимает: перед участком он сдвигает его, после участка не трогает.
        let length = (text as NSString).length
        func shiftedCopy(_ edit: NSRange) -> MarkdownPresentation? {
            var copy = presentation
            copy.prepareForEditing()
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: length)
            guard copy.canShift(change) else { return nil }
            copy.shift(change)
            return copy
        }
        let shifted = try XCTUnwrap(shiftedCopy(NSRange(location: 5, length: 0)))
        XCTAssertEqual(shifted.unreliableRanges, flagged.map { NSRange(location: $0.location + 1, length: $0.length) })
        let appended = try XCTUnwrap(shiftedCopy(NSRange(location: length - 2, length: 0)))
        XCTAssertEqual(appended.unreliableRanges, flagged)
        presentation.prepareForEditing()
        XCTAssertEqual(presentation.unreliableRanges, flagged)
    }

    // MARK: Чистая модель

    func testOuterEntryWinsAndPartialOverlapIsFlagged() {
        let outer = Map.Candidate(source: NSRange(location: 2, length: 10), kind: .replacement(.blockImage), displayLength: 1, owner: NSRange(location: 2, length: 10))
        let inner = Map.Candidate(source: NSRange(location: 4, length: 2), kind: .hiddenMarker, displayLength: 0, owner: NSRange(location: 3, length: 4))
        let crossing = Map.Candidate(source: NSRange(location: 10, length: 5), kind: .hiddenMarker, displayLength: 0, owner: NSRange(location: 10, length: 5))
        let map = Map(candidates: [crossing, inner, outer], textLength: 20)
        XCTAssertEqual(map.entries.map(\.source), [NSRange(location: 2, length: 10)])
        XCTAssertEqual(map.unreliable, [NSRange(location: 10, length: 5)])
        XCTAssertEqual(map.displayLength, 11)
    }

    func testTypographyOverHiddenMarkerIsFlagged() {
        let typography = Map.Candidate(source: NSRange(location: 2, length: 6), kind: .replacement(.typography), displayLength: 1, owner: NSRange(location: 2, length: 6))
        let marker = Map.Candidate(source: NSRange(location: 4, length: 1), kind: .hiddenMarker, displayLength: 0, owner: NSRange(location: 0, length: 12))
        let map = Map(candidates: [marker, typography], textLength: 12)
        XCTAssertEqual(map.unreliable, [NSRange(location: 2, length: 6)])
    }

    func testIdentityAndEmptyText() {
        let identity = Map.identity(textLength: 5)
        XCTAssertTrue(identity.entries.isEmpty)
        XCTAssertEqual(identity.displayLength, 5)
        XCTAssertEqual(display(identity, 3), 3)
        let empty = Map.identity(textLength: 0)
        XCTAssertEqual(display(empty, 0), 0)
        XCTAssertEqual(empty.displayLocation(forSource: 1), .failure(.outOfBounds))
        XCTAssertEqual(empty.sourceLocation(forDisplay: 1, affinity: .leading), .failure(.outOfBounds))
    }

    func testFullyHiddenRangeGivesEmptyDisplayRange() {
        let map = built("**bold**")
        XCTAssertEqual(map.displayRange(forSource: NSRange(location: 0, length: 2)), .success(NSRange(location: 0, length: 0)))
        XCTAssertEqual(map.displayRange(forSource: NSRange(location: 0, length: 8), coverage: .covering), .success(NSRange(location: 0, length: 4)))
    }

    /// Нет квадратичного роста: 50 000 маркеров строятся и опрашиваются быстро.
    func testManyMarkersBuildAndQueryWithoutQuadraticCost() {
        var candidates: [Map.Candidate] = []
        let count = 50_000
        for index in 0..<count {
            let owner = NSRange(location: index * 6, length: 5)
            candidates.append(Map.Candidate(source: NSRange(location: index * 6, length: 1), kind: .hiddenMarker, displayLength: 0, owner: owner))
            candidates.append(Map.Candidate(source: NSRange(location: index * 6 + 4, length: 1), kind: .hiddenMarker, displayLength: 0, owner: owner))
        }
        let map = Map(candidates: candidates, textLength: count * 6)
        XCTAssertEqual(map.displayLength, count * 6 - count * 2)
        for step in 0..<10_000 {
            let point = (step * 29) % (count * 6)
            if case .success(let shown) = map.displayLocation(forSource: point) {
                XCTAssertNotNil(source(map, shown, .leading))
            } else { XCTFail("позиция \(point)") }
        }
        XCTAssertEqual(map.expandToElement(NSRange(location: 6 * 100, length: 2)), NSRange(location: 6 * 100, length: 5))
    }
}
