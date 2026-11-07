import Foundation
import XCTest
@testable import LacEditor

/// Единый разбор Markdown (U2.3a): блоки и базовые строчные узлы, позиции в UTF-16 исходника, отмена.
final class MarkdownDocumentParserTests: XCTestCase {
    private let allIncludes: MarkdownDocumentModel.Includes = [.wikiLinks, .noteEmbeds, .criticMarkup, .emoji, .uppercaseRuns, .readableText, .elementIndex, .blockIndex, .editorContext]

    private func options(_ includes: MarkdownDocumentModel.Includes, vault: Bool = false, front: Bool = true,
                         syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions()) -> MarkdownDocumentModel.Options {
        MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: vault, detectsFrontMatter: front)
    }

    private func parse(_ text: String, includes: MarkdownDocumentModel.Includes = [.noteEmbeds], vault: Bool = false, front: Bool = true,
                       syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(), file: StaticString = #filePath, line: UInt = #line) -> MarkdownDocumentModel {
        guard let model = MarkdownDocumentParser.parse(text, options: options(includes, vault: vault, front: front, syntax: syntax)) else {
            XCTFail("разбор вернул nil", file: file, line: line)
            return MarkdownDocumentParser.parse("", options: options(includes))!
        }
        return model
    }

    private func range(of part: String, in text: String, occurrence: Int = 0) -> NSRange {
        var search = NSRange(location: 0, length: (text as NSString).length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = (text as NSString).range(of: part, options: [], range: search)
            if found.location == NSNotFound { break }
            search = NSRange(location: NSMaxRange(found), length: (text as NSString).length - NSMaxRange(found))
        }
        XCTAssertNotEqual(found.location, NSNotFound, "в тексте нет «\(part)»")
        return found
    }

    // MARK: - Инварианты

    private func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    private func checkMarkers(_ markers: [NSRange], in range: NSRange, _ message: String, file: StaticString, line: UInt) {
        var previousEnd = range.location
        for marker in markers {
            XCTAssertTrue(contains(range, marker), "\(message): маркер \(marker) вне узла \(range)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(marker.location, previousEnd, "\(message): маркеры пересекаются или не по порядку", file: file, line: line)
            previousEnd = NSMaxRange(marker)
        }
    }

    private func checkInlines(_ inlines: [MarkdownInlineNode], parent: NSRange, _ message: String, file: StaticString, line: UInt) {
        for node in inlines {
            XCTAssertTrue(contains(parent, node.range), "\(message): строчный узел \(node.kind) \(node.range) вне \(parent)", file: file, line: line)
            checkMarkers(node.markerRanges, in: node.range, "\(message) \(node.kind)", file: file, line: line)
            checkInlines(node.children, parent: node.range, message, file: file, line: line)
        }
    }

    private func checkBlocks(_ blocks: [MarkdownBlockNode], parent: NSRange, _ message: String, file: StaticString, line: UInt) {
        var previousEnd = parent.location
        for block in blocks {
            XCTAssertTrue(contains(parent, block.range), "\(message): блок \(block.kind) \(block.range) вне \(parent)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(block.range.location, previousEnd, "\(message): блок \(block.kind) пересекает предыдущий", file: file, line: line)
            previousEnd = NSMaxRange(block.range)
            checkMarkers(block.markerRanges, in: block.range, "\(message) \(block.kind)", file: file, line: line)
            checkInlines(block.inlines, parent: block.range, message, file: file, line: line)
            checkBlocks(block.children, parent: block.range, message, file: file, line: line)
            if case let .table(table) = block.kind {
                for row in table.rows {
                    XCTAssertTrue(contains(block.range, row.range), "\(message): строка таблицы вне таблицы", file: file, line: line)
                    for cell in row.cells {
                        XCTAssertTrue(contains(row.range, cell.range), "\(message): ячейка вне строки", file: file, line: line)
                        XCTAssertTrue(contains(cell.range, cell.contentRange), "\(message): содержимое ячейки вне ячейки", file: file, line: line)
                        checkInlines(cell.inlines, parent: cell.range, message, file: file, line: line)
                    }
                }
            }
        }
    }

    private func assertInvariants(_ text: String, _ model: MarkdownDocumentModel, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertEqual(model.textLength, whole.length, message, file: file, line: line)
        checkBlocks(model.blocks, parent: whole, message, file: file, line: line)
        for range in model.unreliableRanges { XCTAssertTrue(contains(whole, range), "\(message): неподтверждённая строка вне текста", file: file, line: line) }
    }

    /// Вид и позиции всех узлов; `map` переводит позиции из LF в CRLF.
    private func shape(_ blocks: [MarkdownBlockNode], map: (Int) -> Int) -> [String] {
        func name(_ value: Any) -> String { String(String(describing: value).prefix { $0.isLetter }) }
        func span(_ range: NSRange) -> String { "\(map(range.location))+\(map(NSMaxRange(range)) - map(range.location))" }
        func inlineShape(_ nodes: [MarkdownInlineNode], _ depth: Int) -> [String] {
            nodes.flatMap { node -> [String] in
                var text = ""
                if case let .text(value) = node.kind { text = value }
                return ["\(depth)i \(name(node.kind)) \(span(node.range)) m\(node.markerRanges.map(span)) \(text) \(node.isUnreliable)"] + inlineShape(node.children, depth + 1)
            }
        }
        func blockShape(_ nodes: [MarkdownBlockNode], _ depth: Int) -> [String] {
            nodes.flatMap { node -> [String] in
                var lines = ["\(depth)b \(name(node.kind)) \(span(node.range)) m\(node.markerRanges.map(span)) \(node.isUnreliable)"]
                lines += inlineShape(node.inlines, depth + 1)
                if case let .table(table) = node.kind {
                    for row in table.rows {
                        lines.append("\(depth)r \(span(row.range)) \(row.isHeader)")
                        for cell in row.cells {
                            lines.append("\(depth)c \(span(cell.range)) \(span(cell.contentRange)) \(cell.colspan) \(cell.rowspan)")
                            lines += inlineShape(cell.inlines, depth + 1)
                        }
                    }
                }
                return lines + blockShape(node.children, depth + 1)
            }
        }
        return blockShape(blocks, 0)
    }

    // MARK: - Корпус

    func testCorpusParsesWithoutFailuresAndKeepsInvariants() throws {
        for item in try BaselineCorpus.documents() {
            guard let model = MarkdownDocumentParser.parse(item.text, options: options(allIncludes, vault: true)) else {
                XCTFail("nil для \(item.id)")
                continue
            }
            assertInvariants(item.text, model, item.id)
        }
    }

    func testCorpusKeepsInvariantsWithCRLF() throws {
        for item in try BaselineCorpus.crlfDocuments() {
            guard let model = MarkdownDocumentParser.parse(item.text, options: options(allIncludes, vault: true)) else {
                XCTFail("nil для \(item.id)")
                continue
            }
            assertInvariants(item.text, model, item.id)
        }
    }

    /// Те же документы с `\r\n`: те же узлы, позиции сдвинуты на число переводов строки перед ними.
    func testCRLFGivesSameNodesWithShiftedRanges() throws {
        for item in try BaselineCorpus.documents() {
            let lf = Array(item.text.utf16)
            var shifts = [0]
            for unit in lf { shifts.append(shifts.last! + (unit == 10 ? 1 : 0)) }
            let crlfText = BaselineCorpus.crlf(item.text)
            guard let plain = MarkdownDocumentParser.parse(item.text, options: options(allIncludes, vault: true)),
                  let crlf = MarkdownDocumentParser.parse(crlfText, options: options(allIncludes, vault: true)) else {
                XCTFail("nil для \(item.id)")
                continue
            }
            let expected = shape(plain.blocks) { $0 + shifts[min($0, lf.count)] }
            let actual = shape(crlf.blocks) { $0 }
            XCTAssertEqual(actual.count, expected.count, "число узлов \(item.id)")
            for (index, pair) in zip(expected, actual).enumerated() where pair.0 != pair.1 {
                XCTFail("\(item.id): узел \(index) отличается: LF \(pair.0), CRLF \(pair.1)")
                break
            }
        }
    }

    // MARK: - Отмена и опции

    func testCancellationReturnsNil() {
        let text = "# Заголовок\n\nТекст *важный* и **жирный**\n\n| а | б |\n|---|---|\n| 1 | 2 |\n"
        XCTAssertNil(MarkdownDocumentParser.parse(text, options: options(allIncludes), isCancelled: { true }))
        guard let finished = MarkdownDocumentParser.parse(text, options: options(allIncludes), isCancelled: { false }) else { return XCTFail("без отмены результат обязателен") }
        assertInvariants(text, finished, "без отмены")
    }

    func testNULIsReplacedWithReplacementCharacterAndTextStaysParsed() {
        let text = "a\u{0}b\n\n# Заголовок\u{0}\n"
        let model = parse(text)
        XCTAssertEqual(model.textLength, (text as NSString).length)
        XCTAssertEqual(model.blocks.count, 2)
        XCTAssertEqual(model.blocks.first?.inlines.map(\.kind), [.text("a\u{FFFD}b")])
        XCTAssertEqual(model.blocks.first?.range, NSRange(location: 0, length: 3))
    }

    func testDisabledIncludesDoNotProduceOptionalNodes() {
        let text = "![[Заметка]]\n\n%% скрыто %%\n"
        XCTAssertEqual(parse(text, includes: [], vault: true).blocks.filter { if case .noteEmbed = $0.kind { return true } else { return false } }.count, 0)
        let loose = "10. 中文😀\n  1. ccc"
        let relaxed = MarkdownSyntaxOptions(strictMode: false)
        XCTAssertEqual(parse(loose, includes: [.editorContext], syntax: relaxed).looseIndents.count, 1, "с editorContext отступ найден")
        XCTAssertTrue(parse(loose, includes: [], syntax: relaxed).looseIndents.isEmpty)
    }

    // MARK: - Блоки

    func testParagraphWithNonASCIIKeepsUTF16Range() {
        let text = "Привет, мир 😀 漢字\r\nвторая строка\r\n"
        let model = parse(text)
        XCTAssertEqual(model.blocks.count, 1)
        guard let block = model.blocks.first else { return }
        XCTAssertEqual(block.kind, .paragraph)
        XCTAssertEqual(block.range, NSRange(location: 0, length: (text as NSString).length - 2))
        XCTAssertEqual(block.inlines.map(\.kind), [.text("Привет, мир 😀 漢字"), .softBreak, .text("вторая строка")])
        XCTAssertEqual(block.inlines[1].range, range(of: "\r\n", in: text))
        XCTAssertEqual(block.inlines[2].range, range(of: "вторая строка", in: text))
    }

    func testHeadingsAtxAndSetextHaveIDsMarkersAndContent() {
        let text = "## Привет 😀 ##\n\nЗаголовок\n=====\n\n# Привет 😀\n"
        let model = parse(text)
        XCTAssertEqual(model.blocks.count, 3)
        guard model.blocks.count == 3, case let .heading(atx) = model.blocks[0].kind, case let .heading(setext) = model.blocks[1].kind,
              case let .heading(again) = model.blocks[2].kind else { return XCTFail("ожидались три заголовка") }
        XCTAssertEqual(atx.level, 2)
        XCTAssertEqual(atx.style, .atx)
        XCTAssertEqual(atx.title, "Привет 😀")
        XCTAssertEqual(atx.id, "lac-heading-привет")
        XCTAssertEqual(again.id, "lac-heading-привет-1", "повтор получает числовой суффикс")
        XCTAssertEqual(atx.contentRange, range(of: "Привет 😀", in: text))
        XCTAssertEqual(model.blocks[0].markerRanges, [NSRange(location: 0, length: 3), range(of: "##", in: text, occurrence: 1)])
        XCTAssertEqual(setext.style, .setext)
        XCTAssertEqual(setext.level, 1)
        XCTAssertEqual(model.blocks[1].markerRanges, [range(of: "=====", in: text)])
        XCTAssertEqual(setext.contentRange, range(of: "Заголовок", in: text))
        XCTAssertTrue(atx.isTopLevel)
        XCTAssertEqual(model.headingIDs, [atx.id, setext.id, again.id])
    }

    func testHeadingInsideFootnoteDefinitionHasNoID() {
        let text = "# Раз\n\nтекст[^a]\n\n[^a]: # Внутри\n"
        let model = parse(text)
        XCTAssertEqual(model.headingIDs, ["lac-heading-раз"])
    }

    func testQuoteHasMarkersAndPrefixesOnLeafBlocks() {
        let text = "> Первая строка\n> вторая\n>\n> # Заголовок\n"
        let model = parse(text)
        guard let quote = model.blocks.first else { return XCTFail("нет цитаты") }
        XCTAssertEqual(quote.kind, .quote)
        XCTAssertEqual(quote.markerRanges.map(\.location), [0, 16, 25, 27])
        XCTAssertEqual(quote.children.count, 2)
        let paragraph = quote.children[0]
        XCTAssertEqual(paragraph.containerPrefixes.map(\.prefixLength), [2, 2])
        XCTAssertEqual(paragraph.containerPrefixes.map(\.continuation), ["> ", "> "])
        XCTAssertEqual(paragraph.containerPrefixes[0].line, range(of: "> Первая строка", in: text))
        XCTAssertTrue(quote.containerPrefixes.isEmpty, "у контейнера префиксов нет")
        XCTAssertEqual(parse("Текст\n").blocks[0].containerPrefixes.count, 0, "вне контейнеров префиксов нет")
    }

    func testCalloutFollowsContractR4() {
        let text = "> [!warning]- Осторожно 😀\n> Тело строки\n> ещё\n>\n> Другой абзац\n"
        let model = parse(text)
        guard let block = model.blocks.first, case let .callout(callout) = block.kind else { return XCTFail("ожидалась выноска: \(model.blocks.map(\.kind))") }
        XCTAssertEqual(callout.type, "warning")
        XCTAssertEqual(callout.kind, .warning)
        XCTAssertEqual(callout.fold, .collapsed)
        XCTAssertEqual(callout.markerRange, range(of: "[!warning]-", in: text))
        XCTAssertEqual(callout.titleRange, range(of: "Осторожно 😀", in: text))
        XCTAssertEqual(block.inlines.map(\.kind), [.text("Осторожно 😀")])
        XCTAssertEqual(block.inlines.first?.range, range(of: "Осторожно 😀", in: text))
        XCTAssertEqual(block.children.count, 2)
        guard block.children.count == 2 else { return }
        XCTAssertEqual(block.children[0].kind, .paragraph)
        XCTAssertEqual(block.children[0].range.location, range(of: "Тело строки", in: text).location, "остаток первого абзаца начинается на первой строке тела")
        XCTAssertEqual(block.children[0].inlines.map(\.kind), [.text("Тело строки"), .softBreak, .text("ещё")])
        XCTAssertEqual(block.children[1].inlines.map(\.kind), [.text("Другой абзац")])
    }

    func testCalloutWithoutTitleAndBodyHasNilTitleRange() {
        let text = "> [!tip]\n"
        guard let block = parse(text).blocks.first, case let .callout(callout) = block.kind else { return XCTFail("ожидалась выноска") }
        XCTAssertNil(callout.titleRange)
        XCTAssertEqual(callout.fold, .none)
        XCTAssertEqual(callout.kind, .tip)
        XCTAssertTrue(block.inlines.isEmpty)
        XCTAssertTrue(block.children.isEmpty)
    }

    func testAlertFollowsContractR5() {
        let text = "> [!NOTE]\n> Текст 漢字\n"
        let model = parse(text)
        guard let block = model.blocks.first, case let .alert(kind) = block.kind else { return XCTFail("ожидался алерт: \(model.blocks.map(\.kind))") }
        XCTAssertEqual(kind, .note)
        XCTAssertEqual(block.children.count, 1)
        let inlines = block.children.first?.inlines ?? []
        XCTAssertEqual(inlines.map(\.kind), [.text("[!NOTE]"), .softBreak, .text("Текст 漢字")])
        XCTAssertEqual(inlines.first?.range, range(of: "[!NOTE]", in: text))
    }

    func testListItemsTasksAndMarkers() {
        let text = "1. раз\n2. два 😀\n\n- [x] готово\n- [ ] нет\n"
        let model = parse(text)
        XCTAssertEqual(model.blocks.count, 2)
        guard model.blocks.count == 2, case let .list(ordered) = model.blocks[0].kind, case let .list(bullets) = model.blocks[1].kind else { return XCTFail("ожидались два списка") }
        XCTAssertEqual(ordered.marker, .ordered(start: 1, delimiter: 46))
        XCTAssertEqual(ordered.depth, 1)
        XCTAssertEqual(bullets.marker, .bullet(45))
        let items = model.blocks[0].children
        XCTAssertEqual(items.compactMap { item -> Int? in if case let .listItem(value) = item.kind { return value.ordinal } else { return nil } }, [1, 2])
        XCTAssertEqual(items[0].markerRanges, [NSRange(location: 0, length: 2)])
        XCTAssertEqual(items[1].markerRanges, [range(of: "2.", in: text)])
        let tasks = model.blocks[1].children
        guard tasks.count == 2, case let .listItem(done) = tasks[0].kind, case let .listItem(open) = tasks[1].kind else { return XCTFail("ожидались две задачи") }
        XCTAssertEqual(done.task?.state, 120)
        XCTAssertEqual(open.task?.state, 32)
        XCTAssertEqual(done.task?.markerRange, range(of: "[x]", in: text))
        XCTAssertEqual(tasks[0].markerRanges, [NSRange(location: range(of: "- [x]", in: text).location, length: 1)])
    }

    func testNestedListHasDepthAndItemPrefixes() {
        let text = "- внешний\n  - внутренний\n    продолжение\n"
        let model = parse(text)
        guard let outer = model.blocks.first, case let .list(outerList) = outer.kind, let item = outer.children.first,
              let inner = item.children.first(where: { if case .list = $0.kind { return true } else { return false } }),
              case let .list(innerList) = inner.kind else { return XCTFail("ожидался вложенный список") }
        XCTAssertEqual(outerList.depth, 1)
        XCTAssertEqual(innerList.depth, 2)
        guard let paragraph = inner.children.first?.children.first else { return XCTFail("нет абзаца пункта") }
        XCTAssertEqual(paragraph.containerPrefixes.count, 2)
        XCTAssertEqual(paragraph.containerPrefixes.first?.prefixLength, 4)
        XCTAssertEqual(paragraph.containerPrefixes.first?.continuation, "    ")
    }

    func testTableHasAlignmentsCellsAndSpans() {
        let text = "| а | 漢字 |\n|:--|--:|\n| 😀 | b |\n"
        let model = parse(text)
        guard let block = model.blocks.first, case let .table(table) = block.kind else { return XCTFail("ожидалась таблица") }
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows.map(\.isHeader), [true, false])
        XCTAssertEqual(table.delimiterRange, range(of: "|:--|--:|", in: text))
        let header = table.rows[0].cells
        XCTAssertEqual(header.map(\.column), [0, 1])
        XCTAssertEqual(header[0].range, NSRange(location: 1, length: 3))
        XCTAssertEqual(header[0].contentRange, range(of: "а", in: text))
        XCTAssertEqual(header[1].contentRange, range(of: "漢字", in: text))
        XCTAssertEqual(header[0].inlines.map(\.kind), [.text("а")])
        XCTAssertEqual(header[0].inlines.first?.range, range(of: "а", in: text))
        XCTAssertEqual(table.rows[1].cells[0].inlines.map(\.kind), [.text("😀")])
        XCTAssertEqual(table.rows[1].cells[0].inlines.first?.range, range(of: "😀", in: text))
        XCTAssertEqual(header.map(\.colspan), [1, 1])
        XCTAssertEqual(header.map(\.virtualSeparators), [0, 0])
    }

    /// Таблица прерывает абзац без пустой строки: cmark отдаёт абзацу и заголовку строки до конца таблицы, ядро их уточняет.
    func testTableInterruptingParagraphKeepsParagraphAndHeaderRanges() {
        for newline in ["\n", "\r\n"] {
            let text = ["абв 😀", "漢字", "| а | б |", "| - | - |", "| в | г |"].joined(separator: newline) + newline
            let model = parse(text)
            XCTAssertEqual(model.blocks.count, 2, "абзац и таблица, перенос \(newline.debugDescription)")
            guard model.blocks.count == 2, case let .table(table) = model.blocks[1].kind else { return XCTFail("ожидались абзац и таблица") }
            let paragraphEnd = range(of: "漢字", in: text)
            XCTAssertEqual(model.blocks[0].range, NSRange(location: 0, length: NSMaxRange(paragraphEnd)), "абзац \(newline.debugDescription)")
            let header = range(of: "| а | б |", in: text)
            XCTAssertEqual(model.blocks[1].range.location, header.location, "начало таблицы \(newline.debugDescription)")
            XCTAssertEqual(NSMaxRange(model.blocks[1].range), (text as NSString).length - newline.utf16.count, "конец таблицы \(newline.debugDescription)")
            XCTAssertEqual(table.rows[0].range, header, "заголовок \(newline.debugDescription)")
            XCTAssertEqual(table.rows[0].cells.map(\.contentRange), [NSRange(location: header.location + 2, length: 1), NSRange(location: header.location + 6, length: 1)],
                           "ячейки заголовка \(newline.debugDescription)")
            XCTAssertEqual(table.rows[1].range, range(of: "| в | г |", in: text), "строка \(newline.debugDescription)")
            XCTAssertEqual(table.delimiterRange, range(of: "| - | - |", in: text), "разделитель \(newline.debugDescription)")
        }
    }

    /// Заголовок таблицы, прервавшей абзац: хвостовые пробелы, `\|`, заголовок без внешних `|`, отступы, цитата, список, несколько строк абзаца.
    /// Ячейки считаются от строки заголовка: диапазон ячейки — текст между `|` строки заголовка.
    func testInterruptedTableHeaderCellsAreExact() {
        let cases = ["abc  \n| а | б |\n|-|-|\n", "а\\|😀\n| а | б |\n|-|-|\n", "   abc\n| а | б |\n|-|-|\n",
                     "- abc\n  | а | б |\n  |-|-|\n", "  abc\n   | 漢 | б |\n   |-|-|\n", "abc\n| а | б |  \n|-|-|\n",
                     "abc\nа | б\n-|-\n", "abc\n| а \\| 😀 | б |\n|-|-|\n", "> abc\n> | а | б |\n> |-|-|\n",
                     "один\nдва 😀\nтри\n| а | б |\n|-|-|\n", "abc\n   | a | b |\n   |-|-|\n"]
        func table(in blocks: [MarkdownBlockNode]) -> MarkdownBlockNode.Table? {
            for block in blocks {
                if case let .table(found) = block.kind { return found }
                if let found = table(in: block.children) { return found }
            }
            return nil
        }
        for source in cases {
            for newline in ["\n", "\r\n"] {
                let text = source.replacingOccurrences(of: "\n", with: newline)
                let nsText = text as NSString
                let label = text.debugDescription
                guard let found = table(in: parse(text).blocks), let header = found.rows.first else { XCTFail("нет таблицы: \(label)"); continue }
                // Строки заголовка и разделителя: без префикса цитаты и отступа в начале.
                var lines: [NSRange] = []
                var cursor = 0
                while cursor < nsText.length {
                    let line = nsText.lineRange(for: NSRange(location: cursor, length: 0))
                    var end = NSMaxRange(line)
                    while end > line.location, [10, 13].contains(nsText.character(at: end - 1)) { end -= 1 }
                    var start = line.location
                    while start < end, [32, 9, 62].contains(nsText.character(at: start)) { start += 1 }
                    lines.append(NSRange(location: start, length: end - start))
                    cursor = NSMaxRange(line)
                }
                guard let delimiterIndex = lines.firstIndex(where: { nsText.substring(with: $0).hasPrefix("|-") || nsText.substring(with: $0).hasPrefix("-|") }) else { XCTFail("нет разделителя: \(label)"); continue }
                let headerLine = lines[delimiterIndex - 1]
                XCTAssertEqual(header.range, headerLine, "заголовок \(label)")
                // Разделитель — вся строка, с префиксом цитаты и отступом (по ней редактор прячет строку).
                let delimiterLine = nsText.lineRange(for: NSRange(location: lines[delimiterIndex].location, length: 0))
                var delimiterEnd = NSMaxRange(delimiterLine)
                while delimiterEnd > delimiterLine.location, [10, 13].contains(nsText.character(at: delimiterEnd - 1)) { delimiterEnd -= 1 }
                XCTAssertEqual(found.delimiterRange, NSRange(location: delimiterLine.location, length: delimiterEnd - delimiterLine.location), "разделитель \(label)")
                // Ячейки: сегменты между неэкранированными `|`, внешние пустые отброшены.
                var segments: [NSRange] = []
                var segmentStart = headerLine.location
                var index = headerLine.location
                var slashes = 0
                while index < NSMaxRange(headerLine) {
                    let unit = nsText.character(at: index)
                    if unit == 92 { slashes += 1 } else {
                        if unit == 124, slashes % 2 == 0 {
                            segments.append(NSRange(location: segmentStart, length: index - segmentStart))
                            segmentStart = index + 1
                        }
                        slashes = 0
                    }
                    index += 1
                }
                segments.append(NSRange(location: segmentStart, length: NSMaxRange(headerLine) - segmentStart))
                if segments.first?.length == 0 { segments.removeFirst() }
                if segments.last.map({ nsText.substring(with: $0).trimmingCharacters(in: .whitespaces).isEmpty }) == true { segments.removeLast() }
                XCTAssertEqual(header.cells.map(\.range), segments, "ячейки \(label)")
                XCTAssertEqual(header.cells.map { nsText.substring(with: $0.contentRange) },
                               segments.map { nsText.substring(with: $0).trimmingCharacters(in: .whitespaces) }, "содержимое ячеек \(label)")
            }
        }
    }

    /// Ссылка, код и формула в заголовке таблицы, прервавшей абзац, получают точные позиции строки заголовка.
    func testInterruptedTableHeaderInlinesHaveExactRanges() throws {
        for newline in ["\n", "\r\n"] {
            let text = "абв 😀\n| [x](u) | `c` $m$ |\n|-|-|\n".replacingOccurrences(of: "\n", with: newline)
            let model = parse(text, includes: [.noteEmbeds, .elementIndex])
            guard model.blocks.count == 2, case let .table(table) = model.blocks[1].kind, let header = table.rows.first else { return XCTFail("ожидались абзац и таблица") }
            let kinds = header.cells.flatMap { $0.inlines }
            let link = kinds.first { if case .link = $0.kind { return true } else { return false } }
            let code = kinds.first { if case .code = $0.kind { return true } else { return false } }
            XCTAssertEqual(link?.range, range(of: "[x](u)", in: text), "ссылка \(newline.debugDescription)")
            XCTAssertEqual(code?.range, range(of: "`c`", in: text), "код \(newline.debugDescription)")
            let formula = try XCTUnwrap(kinds.first { if case .formula = $0.kind { return true } else { return false } }, "формула \(newline.debugDescription)")
            XCTAssertEqual(formula.range, range(of: "$m$", in: text), "формула \(newline.debugDescription)")
        }
        // В цитате: префикс `> ` строки заголовка не входит в позиции.
        for newline in ["\n", "\r\n"] {
            let text = "> абв\n> | [x](u) | `c` |\n> |-|-|\n".replacingOccurrences(of: "\n", with: newline)
            guard let quote = parse(text).blocks.first, case .quote = quote.kind,
                  let tableNode = quote.children.last, case let .table(table) = tableNode.kind, let header = table.rows.first else { return XCTFail("ожидалась таблица в цитате") }
            let kinds = header.cells.flatMap { $0.inlines }
            let link = try XCTUnwrap(kinds.first { if case .link = $0.kind { return true } else { return false } })
            let code = try XCTUnwrap(kinds.first { if case .code = $0.kind { return true } else { return false } })
            XCTAssertEqual(link.range, range(of: "[x](u)", in: text), "ссылка в цитате \(newline.debugDescription)")
            XCTAssertEqual(code.range, range(of: "`c`", in: text), "код в цитате \(newline.debugDescription)")
        }
    }

    func testTableSpansComeFromCMark() {
        let text = "| а || б |\n|---|---|---|\n| в | г | д |\n| ^ | е | ж |\n"
        guard let block = parse(text).blocks.first, case let .table(table) = block.kind else { return XCTFail("ожидалась таблица") }
        let header = table.rows[0].cells
        XCTAssertEqual(header.first?.colspan, 2)
        XCTAssertEqual(header.first?.virtualSeparators, 1)
        XCTAssertEqual(header.dropFirst().first?.colspan, 0, "ячейка-заполнитель")
        XCTAssertEqual(table.rows[1].cells[0].rowspan, 2)
        XCTAssertEqual(table.rows[2].cells[0].rowspan, 0)
    }

    func testThematicBreakAndCodeBlockWithDiagram() {
        let text = "---\n\n```swift\nlet a = \"😀\"\n```\n\n```mermaid\ngraph TD\n```\n"
        let model = parse(text, front: false)
        XCTAssertEqual(model.blocks.map(\.kind).count, 3)
        guard model.blocks.count == 3 else { return }
        XCTAssertEqual(model.blocks[0].kind, .thematicBreak)
        guard case let .codeBlock(code) = model.blocks[1].kind, case let .codeBlock(diagram) = model.blocks[2].kind else { return XCTFail("ожидались блоки кода") }
        XCTAssertTrue(code.isFenced)
        XCTAssertTrue(code.isClosed)
        XCTAssertEqual(code.info, "swift")
        XCTAssertEqual(code.literal, "let a = \"😀\"\n")
        XCTAssertEqual(model.blocks[1].markerRanges.count, 2)
        XCTAssertNil(code.diagram)
        XCTAssertEqual(diagram.diagram, .mermaid)
    }

    /// Метка ссылки на сноску — метка определения, а не порядковый номер cmark (продолжение абзаца, список, цитата, `[^7]` перед `[^1]:`).
    func testFootnoteReferenceLabelIsDefinitionLabel() {
        func labels(_ text: String) -> [String] {
            func walk(_ blocks: [MarkdownBlockNode]) -> [String] {
                blocks.flatMap { block -> [String] in
                    let own = block.inlines.compactMap { node -> String? in
                        if case .footnoteReference(let label) = node.kind { return label } else { return nil }
                    }
                    return own + walk(block.children)
                }
            }
            return walk(parse(text).blocks)
        }
        XCTAssertEqual(labels("Первая строка.\nВторая[^б]\n\n[^б]: Сноска.\n"), ["б"])
        XCTAssertEqual(labels("- пункт[^б]\n\n[^б]: Сноска.\n"), ["б"])
        XCTAssertEqual(labels("> цитата\n> ещё[^б]\n\n[^б]: Сноска.\n"), ["б"])
        XCTAssertEqual(labels("Текст[^7] и [^1].\n\n[^1]: Один.\n[^7]: Семь.\n"), ["7", "1"])
        XCTAssertEqual(labels("Текст[^7].\n\n[^1]: Один.\n[^7]: Семь.\n"), ["7"])
        XCTAssertEqual(labels("Текст[^Б].\n\n[^б]: Сноска.\n"), ["б"])
    }

    /// Номер сноски — номер cmark: порядок первых ссылок в документе, ссылка в теле определения тоже считается.
    func testFootnoteNumbersFollowCmarkOrderIncludingReferencesInsideDefinitions() {
        let text = "X[^1]\n\n[^1]: n[^3]\n\nY[^2] и ещё [^2]\n\n[^2]: p\n\n[^3]: q"
        let model = parse(text)
        let one = range(of: "[^1]", in: text, occurrence: 1), two = range(of: "[^2]", in: text, occurrence: 2), three = range(of: "[^3]", in: text, occurrence: 1)
        XCTAssertEqual(model.footnoteNumbers[one], 1)
        XCTAssertEqual(model.footnoteNumbers[three], 2)
        XCTAssertEqual(model.footnoteNumbers[two], 3)
        XCTAssertEqual(model.footnoteNumbers.count, 3)
        XCTAssertTrue(parse("Просто текст").footnoteNumbers.isEmpty)
    }

    func testFootnotesCollectReferenceDefinitionAndText() {
        let text = "Текст[^1] и ещё.\n\n[^1]: Сноска 😀\n"
        let model = parse(text)
        XCTAssertEqual(model.footnotes.count, 1)
        XCTAssertEqual(model.footnotes.first?.text, "Сноска 😀")
        XCTAssertEqual(model.footnotes.first?.referenceRange, range(of: "[^1]", in: text))
        XCTAssertEqual(model.footnotes.first?.definitionRange, range(of: "[^1]", in: text, occurrence: 1))
        guard let paragraph = model.blocks.first, let reference = paragraph.inlines.first(where: { if case .footnoteReference = $0.kind { return true } else { return false } }) else { return XCTFail("нет ссылки на сноску") }
        XCTAssertEqual(reference.kind, .footnoteReference(label: "1"))
        XCTAssertEqual(reference.markerRanges, [NSRange(location: 5, length: 2), NSRange(location: 8, length: 1)])
        guard model.blocks.count == 2 else { return XCTFail("ожидались абзац и определение") }
        XCTAssertEqual(model.blocks[1].kind, .footnoteDefinition(label: "1"))
        XCTAssertEqual(model.blocks[1].markerRanges, [range(of: "[^1]", in: text, occurrence: 1)])
        XCTAssertEqual(model.blocks[1].range.location, range(of: "[^1]", in: text, occurrence: 1).location, "определение начинается с метки")
    }

    func testTableOfContentsParagraph() {
        let model = parse("[toc]\n\n# Раз\n")
        XCTAssertEqual(model.blocks.first?.kind, .tableOfContents)
        XCTAssertEqual(parse("- [toc]\n").blocks.first?.children.first?.children.first?.kind, .paragraph, "в списке это обычный абзац")
    }

    func testFrontMatterBlockAndModelField() {
        let text = "---\ntitle: Привет\n---\n\n# Тело\n"
        let model = parse(text)
        XCTAssertEqual(model.blocks.first?.kind, .frontMatter)
        XCTAssertEqual(model.frontMatter?.range, range(of: "---\ntitle: Привет\n---", in: text))
        XCTAssertEqual(model.frontMatter?.markers.count, 2)
        XCTAssertEqual(model.blocks.first?.range, model.frontMatter?.range)
        XCTAssertEqual(model.blocks.first?.markerRanges, model.frontMatter?.markers)
        XCTAssertEqual(parse(text, front: false).frontMatter, nil)
        XCTAssertEqual(model.headingIDs, ["lac-heading-тело"])
    }

    func testBlockCommentFollowsContractR8() {
        let text = "Раз\n\n%%\nкомментарий 😀\n%%\n\nДва\n"
        let model = parse(text, vault: true)
        XCTAssertEqual(model.blocks.map { $0.kind == .comment }, [false, true, false])
        guard model.blocks.count == 3 else { return }
        XCTAssertEqual(model.blocks[1].range, range(of: "%%\nкомментарий 😀\n%%", in: text))
        XCTAssertEqual(model.blocks[1].markerRanges.count, 2)
        XCTAssertTrue(model.blocks[1].children.isEmpty)
        XCTAssertEqual(parse(text, vault: false).blocks.filter { $0.kind == .comment }.count, 0, "вне заметки хранилища комментариев нет")
    }

    func testBlockCommentInsideQuoteStaysInsideQuote() {
        let text = "> Раз\n>\n> %% скрыто %%\n>\n> Два\n"
        let model = parse(text, vault: true)
        guard let quote = model.blocks.first else { return XCTFail("нет цитаты") }
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(quote.children.map { $0.kind == .comment }, [false, true, false])
    }

    func testNoteEmbedBlockFollowsContractR6() {
        let text = "![[Заметка#Раздел|псевдоним]]\n\nТекст ![[Другая]] внутри\n"
        let model = parse(text)
        guard model.blocks.count == 2 else { return XCTFail("ожидалось два блока: \(model.blocks.map(\.kind))") }
        XCTAssertEqual(model.blocks[0].kind, .noteEmbed(MarkdownBlockNode.NoteEmbed(target: "Заметка", heading: "Раздел", alias: "псевдоним", kind: .note)))
        XCTAssertTrue(model.blocks[0].children.isEmpty)
        XCTAssertTrue(model.blocks[0].inlines.isEmpty)
        XCTAssertEqual(model.blocks[1].kind, .paragraph, "встраивание внутри строки остаётся строчным (подзадача b)")
        XCTAssertEqual(parse(text, includes: []).blocks.first?.kind, .paragraph)
    }

    func testHTMLBlockIsConfirmedWithDisplayHTML() {
        let text = "<div>\nпривет\n</div>\n"
        guard let block = parse(text).blocks.first, case let .html(html) = block.kind else { return XCTFail("ожидался HTML-блок") }
        XCTAssertEqual(html.literal, "<div>\nпривет\n</div>\n")
        XCTAssertEqual(html.kind, .confirmed(displayHTML: "<div>\nпривет\n</div>\n"))
    }

    func testMathBlockAndInlineFormula() {
        let text = "$$\nx^2\n$$\n\nТекст $a+b$ конец\n"
        let model = parse(text)
        guard model.blocks.count == 2 else { return XCTFail("ожидалось два блока: \(model.blocks.map(\.kind))") }
        XCTAssertEqual(model.blocks[0].kind, .mathBlock(source: "x^2\n"))
        XCTAssertEqual(model.blocks[0].range, range(of: "$$\nx^2\n$$", in: text))
        let formula = model.blocks[1].inlines.first { if case .formula = $0.kind { return true } else { return false } }
        XCTAssertEqual(formula?.kind, .formula(source: "a+b"))
        XCTAssertEqual(formula?.range, range(of: "$a+b$", in: text))
    }

    // MARK: - Строчные узлы

    private func inlines(_ text: String) -> [MarkdownInlineNode] { parse(text).blocks.first?.inlines ?? [] }

    func testEmphasisStrongAndStrikethroughMarkers() {
        let text = "*курс* **жир** ~~зач~~ _под_ ***оба***"
        let nodes = inlines(text)
        let kinds = nodes.map(\.kind).filter { $0 != .text(" ") }
        XCTAssertEqual(kinds, [.emphasis, .strong, .strikethrough, .emphasis, .emphasis])
        let emphasis = nodes[0]
        XCTAssertEqual(emphasis.range, range(of: "*курс*", in: text))
        XCTAssertEqual(emphasis.markerRanges, [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1)])
        XCTAssertEqual(emphasis.children.map(\.kind), [.text("курс")])
        let strong = nodes[2]
        XCTAssertEqual(strong.range, range(of: "**жир**", in: text))
        XCTAssertEqual(strong.markerRanges.map(\.length), [2, 2])
        XCTAssertEqual(nodes[4].markerRanges.map(\.length), [2, 2])
        XCTAssertEqual(nodes[4].markerRanges.first?.location, range(of: "~~зач~~", in: text).location)
    }

    func testCodeSpanHasBackticksAsMarkers() {
        let text = "до ``a ` b`` после"
        let code = inlines(text).first { if case .code = $0.kind { return true } else { return false } }
        XCTAssertEqual(code?.kind, .code("a ` b"))
        XCTAssertEqual(code?.range, range(of: "``a ` b``", in: text))
        XCTAssertEqual(code?.markerRanges.map(\.length), [2, 2])
    }

    func testLinkFormsAndDestinations() {
        let text = "[ссылка](https://example.com/ы \"т\") <https://a.b> [ref][r] https://c.d\n\n[r]: https://e.f\n"
        let links = inlines(text).compactMap { node -> (MarkdownInlineNode, MarkdownInlineNode.Link)? in
            if case let .link(link) = node.kind { return (node, link) } else { return nil }
        }
        XCTAssertEqual(links.map { $0.1.form }, [.inline, .autolink, .reference, .autolink])
        guard let inline = links.first else { return }
        XCTAssertEqual(inline.1.title, "т")
        XCTAssertEqual(inline.1.url, "https://example.com/ы")
        XCTAssertEqual(inline.0.range, range(of: "[ссылка](https://example.com/ы \"т\")", in: text))
        XCTAssertEqual(inline.1.destinationRange, range(of: "https://example.com/ы", in: text))
        XCTAssertEqual(inline.0.markerRanges.count, 2)
        XCTAssertEqual(inline.0.children.map(\.kind), [.text("ссылка")])
        XCTAssertEqual(links[1].0.markerRanges, [NSRange(location: range(of: "<https://a.b>", in: text).location, length: 1), NSRange(location: NSMaxRange(range(of: "<https://a.b>", in: text)) - 1, length: 1)])
        XCTAssertNil(links[2].1.destinationRange)
        XCTAssertEqual(links[3].0.markerRanges, [])
    }

    func testImageMarkersAltAndBlockFlag() {
        let text = "![Картинка 😀](a.png \"подпись\")\n\nтекст ![x](y.png) ещё\n"
        let model = parse(text)
        guard model.blocks.count == 2, let block = model.blocks[0].inlines.first, case let .image(image) = block.kind else { return XCTFail("ожидалось изображение") }
        XCTAssertEqual(image.alt, "Картинка 😀")
        XCTAssertEqual(image.title, "подпись")
        XCTAssertEqual(image.syntax, .markdown)
        XCTAssertTrue(image.isBlock)
        XCTAssertTrue(block.children.isEmpty)
        XCTAssertEqual(block.markerRanges.first, NSRange(location: 0, length: 2))
        XCTAssertEqual(block.markerRanges.last?.length, (text as NSString).range(of: "](a.png \"подпись\")").length)
        let inline = model.blocks[1].inlines.first { if case .image = $0.kind { return true } else { return false } }
        guard case let .image(second)? = inline?.kind else { return XCTFail("нет второго изображения") }
        XCTAssertFalse(second.isBlock)
    }

    func testBreaksCoverOnlyLineEnding() {
        let text = "раз\\\nдва  \nтри\nчетыре"
        let nodes = inlines(text)
        XCTAssertEqual(nodes.map(\.kind), [.text("раз"), .hardBreak, .text("два"), .hardBreak, .text("три"), .softBreak, .text("четыре")])
        XCTAssertEqual(nodes[1].range, range(of: "\\\n", in: text))
        XCTAssertEqual(nodes[3].range, range(of: "  \n", in: text))
        XCTAssertEqual(nodes[5].range, range(of: "\n", in: text, occurrence: 2))
    }

    func testMaskedCommentKeepsSourceTextInParagraph() {
        let text = "Слово %% скрыто %% дальше\n"
        let model = parse(text, vault: true)
        guard let paragraph = model.blocks.first else { return XCTFail("нет абзаца") }
        let joined = paragraph.inlines.compactMap { node -> String? in if case let .text(value) = node.kind { return value } else { return nil } }.joined()
        XCTAssertFalse(joined.contains("\u{FFFF}"))
        // С подзадачи b комментарий — отдельный узел, а текст вне него остаётся литералом cmark.
        XCTAssertEqual(joined, "Слово  дальше")
        XCTAssertEqual(paragraph.inlines.filter { $0.kind == .comment }.map(\.range), [range(of: "%% скрыто %%", in: text)])
    }

    func testInlinesInsideQuoteAndTableCellHaveRanges() {
        let text = "> один **два**\n> три\n\n| **а** |\n|---|\n| `б` |\n"
        let model = parse(text)
        guard model.blocks.count == 2, let quoteParagraph = model.blocks[0].children.first else { return XCTFail("ожидались цитата и таблица") }
        let strong = quoteParagraph.inlines.first { $0.kind == .strong }
        XCTAssertEqual(strong?.range, range(of: "**два**", in: text))
        XCTAssertFalse(strong?.isUnreliable ?? true)
        XCTAssertEqual(quoteParagraph.inlines.last?.range, range(of: "три", in: text))
        guard case let .table(table) = model.blocks[1].kind else { return XCTFail("нет таблицы") }
        XCTAssertEqual(table.rows[0].cells[0].inlines.first?.range, range(of: "**а**", in: text))
        XCTAssertEqual(table.rows[1].cells[0].inlines.first?.range, range(of: "`б`", in: text))
    }

    func testAtxTailIsIncludedOnlyWithClosingHashes() {
        let text = "# а   \n\n# б ##  \n"
        let model = parse(text)
        XCTAssertEqual(model.blocks.count, 2)
        guard model.blocks.count == 2 else { return }
        XCTAssertEqual(model.blocks[0].range, range(of: "# а", in: text), "пробелы без # в узел не входят")
        XCTAssertEqual(model.blocks[0].markerRanges, [NSRange(location: 0, length: 2)])
        XCTAssertEqual(model.blocks[1].range, range(of: "# б ##  ", in: text))
        XCTAssertEqual(model.blocks[1].markerRanges.count, 2)
    }

    func testCalloutTitleKeepsCMarkValueAndSourceRange() {
        let text = "> [!note] Тема &amp; «x» \"q\"\n> тело\n"
        guard let block = parse(text).blocks.first, case let .callout(callout) = block.kind else { return XCTFail("ожидалась выноска") }
        let joined = block.inlines.compactMap { node -> String? in if case let .text(value) = node.kind { return value } else { return nil } }.joined()
        XCTAssertEqual(joined, "Тема & «x» \u{201C}q\u{201D}", "значение — из cmark: сущность раскрыта, кавычки умные")
        XCTAssertEqual(callout.titleRange, range(of: "Тема &amp; «x» \"q\"", in: text), "диапазон — из исходника")
    }

    func testSmartPunctuationCanBeDisabled() {
        let text = "\"а\" -- б\n"
        let on = parse(text).blocks.first?.inlines.compactMap { node -> String? in if case let .text(value) = node.kind { return value } else { return nil } }.joined()
        let off = parse(text, syntax: MarkdownSyntaxOptions(smartPunctuation: false)).blocks.first?.inlines
            .compactMap { node -> String? in if case let .text(value) = node.kind { return value } else { return nil } }.joined()
        XCTAssertEqual(on, "\u{201C}а\u{201D} \u{2013} б")
        XCTAssertEqual(off, "\"а\" -- б")
    }

    func testHeadingIDsMatchRenderer() {
        let texts = ["# Привет\n\n## Привет\n\n# Привет\n\n### Hello, World!\n\n# Hello World\n",
                     "Заголовок\n====\n\n# Заголовок 😀\n\n# 漢字\n\n# 漢字\n",
                     "> # В цитате\n\n- # В списке\n\n# В цитате\n"]
        for text in texts {
            let ids = parse(text).headingIDs
            let html = MarkdownHTMLRenderer.renderPage(text, darkMode: false).html
            let regex = try! NSRegularExpression(pattern: "<span id=\"(lac-heading-[^\"]*)\"></span>")
            let rendered = regex.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length)).map { (html as NSString).substring(with: $0.range(at: 1)) }
            XCTAssertFalse(ids.isEmpty, text)
            XCTAssertEqual(ids, rendered, "id заголовков расходятся с рендером: \(text.debugDescription)")
        }
    }

    func testLazyContinuationInQuoteKeepsRanges() {
        let text = "> первая 😀\nлениво\n"
        guard let quote = parse(text).blocks.first, let paragraph = quote.children.first else { return XCTFail("нет цитаты") }
        XCTAssertEqual(paragraph.inlines.map(\.kind), [.text("первая 😀"), .softBreak, .text("лениво")])
        XCTAssertEqual(paragraph.inlines.last?.range, range(of: "лениво", in: text))
        XCTAssertEqual(paragraph.inlines.last?.isUnreliable, false)
        XCTAssertEqual(paragraph.containerPrefixes.map(\.prefixLength), [2, 0])
    }

    /// Абзац алерта начинается с `[`, но совпал с исходником побайтно: позиции cmark верны, умные кавычки
    /// (литерал cmark не равен исходнику) остаются надёжными, а диапазон узла лежит на исходном тексте.
    func testFallbackLiteralSearchFindsMatchesAndMarksMismatchUnreliable() {
        let alertText = "> [!NOTE]\n> Текст 😀\n"
        let alert = parse(alertText)
        guard let second = alert.blocks.first?.children.first?.inlines.last, case .text("Текст 😀") = second.kind else { return XCTFail("нет текста второй строки") }
        XCTAssertFalse(second.isUnreliable, "литерал найден сразу за переносом строки")
        XCTAssertEqual(second.range, range(of: "Текст 😀", in: alertText))

        let quoted = "> [!note]\n> say \"hi\" 😀\n"
        let trusted = parse(quoted)
        assertInvariants(quoted, trusted, "совпавший абзац")
        XCTAssertEqual(trusted.blocks.first?.children.first?.inlines.map(\.kind), [.text("say \u{201C}hi\u{201D} 😀")])
        XCTAssertEqual(trusted.blocks.first?.children.first?.inlines.first?.isUnreliable, false)
        XCTAssertEqual(trusted.blocks.first?.children.first?.inlines.first?.range, range(of: "say \"hi\" 😀", in: quoted))
    }

    func testCRLFAndEmojiInCalloutAlertAndQuote() {
        let samples = ["> [!tip] Совет 😀\n> тело 漢字\n> ещё\n", "> [!NOTE]\n> Текст 😀\n", "> один 😀\n> два\n>\n> три **жирный**\n"]
        for lf in samples {
            let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
            let model = parse(crlf)
            assertInvariants(crlf, model, "CRLF: \(lf.debugDescription)")
            XCTAssertTrue(model.unreliableRanges.isEmpty, "CRLF: \(lf.debugDescription): ненадёжных диапазонов нет")
            func texts(_ blocks: [MarkdownBlockNode]) -> [(String, NSRange)] {
                blocks.flatMap { block in
                    block.inlines.compactMap { node -> (String, NSRange)? in if case let .text(value) = node.kind { return (value, node.range) } else { return nil } } + texts(block.children)
                }
            }
            for (value, textRange) in texts(model.blocks) {
                XCTAssertEqual((crlf as NSString).substring(with: textRange), value, "CRLF: текст узла совпадает с исходником: \(lf.debugDescription)")
            }
        }
    }

    func testTableOfContentsMarkerForms() {
        XCTAssertEqual(parse("  [toc]\n").blocks.first?.kind, .tableOfContents)
        XCTAssertEqual(parse("[toc]  \n").blocks.first?.kind, .tableOfContents)
        XCTAssertEqual(parse("\\[toc\\]\n").blocks.first?.kind, .paragraph, "с экранированием это обычный текст")
        XCTAssertEqual(parse("[toc] текст\n").blocks.first?.kind, .paragraph)
    }

    func testPlaceholdersNeverReachModelData() {
        let text = "![a {++b++}](x \"т {++z++}\")\n\n[ссылка](y \"п {++q++}\")\n\nСноска[^1]\n\n[^1]: текст {++в++} сноски\n"
        let model = parse(text, includes: [.criticMarkup])
        func isPlaceholder(_ scalar: Unicode.Scalar) -> Bool { (0xE000...0xF8FF).contains(scalar.value) || scalar.value == 0xFFFF }
        func check(_ value: String, _ what: String) { XCTAssertFalse(value.unicodeScalars.contains(where: isPlaceholder), "заменитель маски в \(what): \(value.debugDescription)") }
        func walk(_ nodes: [MarkdownInlineNode]) {
            for node in nodes {
                switch node.kind {
                case let .image(image): check(image.alt, "alt"); check(image.url, "url картинки"); check(image.title ?? "", "title картинки"); XCTAssertEqual(image.alt, "a b")
                case let .link(link): check(link.url, "url ссылки"); check(link.title ?? "", "title ссылки")
                case let .formula(source): check(source, "формуле")
                default: break
                }
                walk(node.children)
            }
        }
        func walkBlocks(_ blocks: [MarkdownBlockNode]) { for block in blocks { walk(block.inlines); walkBlocks(block.children) } }
        walkBlocks(model.blocks)
        for note in model.footnotes { check(note.text, "тексте сноски") }
        XCTAssertEqual(model.footnotes.first?.text, "текст в сноски")
    }

    func testFootnoteDefinitionStaysInSourcePosition() {
        let text = "Раз[^a]\n\n[^a]: сноска\n\nДва\n"
        let model = parse(text)
        XCTAssertEqual(model.blocks.map { String(describing: $0.kind).prefix(8) }, ["paragrap", "footnote", "paragrap"], "сноска стоит по позиции, а не в конце")
    }

    func testSetextHeadingStartingWithHashIsNotAtx() {
        for (text, level) in [("#тег\n====\n", 1), ("#тег\r\n---\r\n", 2)] {
            guard let block = parse(text).blocks.first, case let .heading(heading) = block.kind else { return XCTFail("ожидался заголовок: \(text.debugDescription)") }
            XCTAssertEqual(heading.style, .setext, text.debugDescription)
            XCTAssertEqual(heading.level, level)
            XCTAssertEqual(block.markerRanges, [range(of: level == 1 ? "====" : "---", in: text)], "маркер — подчёркивание")
        }
        guard let atx = parse("# тег\n").blocks.first, case let .heading(plain) = atx.kind else { return XCTFail("нет заголовка") }
        XCTAssertEqual(plain.style, .atx)
    }

    /// Узел строки абзаца в цитате начинается с пробела (` текст` после `*а*`): литерал ищется прямо за предыдущим узлом.
    func testFollowingTextStartingWithSpaceIsFoundInPlace() {
        let text = "> [!NOTE]\n> *а* текст\n"
        let model = parse(text)
        assertInvariants(text, model, "литерал с пробелом")
        guard let paragraph = model.blocks.first?.children.first else { return XCTFail("нет абзаца") }
        let tail = paragraph.inlines.last
        XCTAssertEqual(tail?.kind, .text(" текст"))
        XCTAssertEqual(tail?.range, range(of: " текст", in: text))
        XCTAssertEqual(tail?.isUnreliable, false)
    }

    /// Символ U+E000 в исходнике: маска берёт другой заменитель, поэтому `clean` его не трогает.
    func testSourceCharacterE000NextToCriticMarkupSurvives() {
        let text = "![\u{E000}a {++b++}](x)\n"
        let model = parse(text, includes: [.criticMarkup])
        guard let node = model.blocks.first?.inlines.first, case let .image(image) = node.kind else { return XCTFail("ожидалось изображение") }
        XCTAssertEqual(image.alt, "\u{E000}a b", "символ из исходника остался, заменители маски убраны")
    }

    /// Абзац алерта начинается с `[`, но определение ссылки не съедено: позиции строчных узлов верны, ссылка — inline.
    func testLinksAndEmphasisInAlertParagraphKeepPositionsAndInlineForm() {
        let text = "> [!NOTE]\n> [l](u) текст\n> у *а* и [](u)\n"
        let model = parse(text)
        assertInvariants(text, model, "абзац алерта")
        guard let paragraph = model.blocks.first?.children.first else { return XCTFail("нет абзаца") }
        let links = paragraph.inlines.compactMap { node -> (MarkdownInlineNode, MarkdownInlineNode.Link)? in
            if case let .link(link) = node.kind { return (node, link) } else { return nil }
        }
        XCTAssertEqual(links.map { $0.1.form }, [.inline, .inline])
        XCTAssertEqual(links.first?.0.range, range(of: "[l](u)", in: text))
        XCTAssertEqual(links.first?.1.destinationRange, range(of: "u", in: text))
        XCTAssertEqual(links.last?.0.range, range(of: "[](u)", in: text))
        let emphasis = paragraph.inlines.first { $0.kind == .emphasis }
        XCTAssertEqual(emphasis?.range, range(of: "*а*", in: text))
        XCTAssertEqual(emphasis?.isUnreliable, false)
        XCTAssertFalse(paragraph.inlines.contains { $0.isUnreliable })
    }

    /// Защита сохраняется: если cmark съел определение ссылки в начале абзаца, узлы остаются на настоящих строках исходника.
    func testEatenReferenceDefinitionKeepsPositionsGuard() {
        let text = "[a]: /u\nтекст *б*\nещё\n"
        let model = parse(text)
        assertInvariants(text, model, "съеденное определение")
        let nodes = model.blocks.flatMap(\.inlines)
        XCTAssertFalse(nodes.contains { $0.kind == .text("[a]: /u") }, "определение в текст не попало")
        for node in nodes where !node.isUnreliable {
            XCTAssertFalse(range(of: "[a]: /u", in: text).location == node.range.location, "надёжный узел не может лежать на съеденном определении")
        }
        let quoted = "[a]: /u\nsay \"hi\"\n😀\n"
        let quotedNodes = parse(quoted).blocks.flatMap(\.inlines)
        XCTAssertEqual(quotedNodes.first?.kind, .text("say \u{201C}hi\u{201D}"))
        XCTAssertEqual(quotedNodes.first?.range, range(of: "say \"hi\"", in: quoted), "диапазон лежит на строке после определения")
        XCTAssertEqual(quotedNodes.first?.isUnreliable, false)
    }

    /// Ссылки в многострочном абзаце, начинающемся с `[` (примеры 186, 551 и 560 спецификации): ссылочная форма,
    /// диапазоны на исходных скобках, адреса и места ссылок совпадают с `<a>` из рендера.
    func testReferenceLinksInMultilineParagraphsMatchRenderer() {
        let samples: [(text: String, links: [String])] = [
            ("[foo]: /foo-url \"foo\"\n[bar]: /bar-url\n  \"bar\"\n[baz]: /baz-url\n\n[foo],\n[bar],\n[baz]", ["[foo]", "[bar]", "[baz]"]),
            ("[foo]\n[bar]\n\n[bar]: /url \"title\"\n", ["[bar]"]),
            ("[\n ]\n\n[\n ]: /uri\n", []),
            // CRLF, кириллица, CJK и эмодзи: позиции считаются в UTF-16
            ("[метка 😀]: /u\r\n\r\n[метка 😀],\r\n[ключ] 中文", ["[метка 😀]"]),
            ("[я\n ]: /u\n\n[я\n ],\n[ключ] 中文", ["[я\n ]"]),
            ("[я\r\n ]: /u\r\n\r\n[я\r\n ],\r\n[ключ] 中文", ["[я\r\n ]"]),
            ("[ключ 😀]: /k\r\n[中文]: /z\r\n\r\n[ключ 😀],\r\n[中文] и [ключ 😀]", ["[ключ 😀]", "[中文]", "[ключ 😀]"])
        ]
        for sample in samples {
            let model = parse(sample.text)
            assertInvariants(sample.text, model, "ссылочные ссылки")
            func links(_ blocks: [MarkdownBlockNode]) -> [(MarkdownInlineNode, MarkdownInlineNode.Link)] {
                func inline(_ nodes: [MarkdownInlineNode]) -> [(MarkdownInlineNode, MarkdownInlineNode.Link)] {
                    nodes.flatMap { node -> [(MarkdownInlineNode, MarkdownInlineNode.Link)] in
                        if case let .link(link) = node.kind { return [(node, link)] + inline(node.children) }
                        return inline(node.children)
                    }
                }
                return blocks.flatMap { inline($0.inlines) + links($0.children) }
            }
            let found = links(model.blocks)
            XCTAssertEqual(found.map { (sample.text as NSString).substring(with: $0.0.range) }, sample.links, "диапазоны ссылок: \(sample.text.debugDescription)")
            XCTAssertEqual(found.map { $0.1.form }, sample.links.map { _ in .reference }, "форма: \(sample.text.debugDescription)")
            XCTAssertFalse(model.unreliableRanges.contains { range in found.contains { NSIntersectionRange($0.0.range, range).length > 0 } }, "ссылки надёжны")
            let html = MarkdownHTMLRenderer.renderPage(sample.text, darkMode: false).html
            // Перенос строки внутри текста ссылки рендер выводит как `<br />`: убираем его и сводим пробелы, сравнивается только текст.
            let regex = try! NSRegularExpression(pattern: "<a href=\"([^\"]*)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
            func plain(_ value: String) -> String {
                value.replacingOccurrences(of: "<br />", with: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
            let rendered = regex.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
                .map { ((html as NSString).substring(with: $0.range(at: 1)), (html as NSString).substring(with: $0.range(at: 2))) }
            XCTAssertEqual(found.map { $0.1.url }, rendered.map { $0.0 }, "адреса совпадают с рендером: \(sample.text.debugDescription)")
            XCTAssertEqual(sample.links.map { plain(String($0.dropFirst().dropLast())) }, rendered.map { plain($0.1) }, "тексты ссылок совпадают с рендером: \(sample.text.debugDescription)")
        }
    }

    /// Автоссылка и `[a]()` в многострочном абзаце: правило «ссылка без `](…)`» их не касается, диапазоны точные.
    func testAutolinkAndEmptyDestinationInMultilineParagraphKeepRanges() {
        let text = "см. <https://a.b>\nещё [a]() строка 😀\nи [中文](u)"
        let model = parse(text)
        assertInvariants(text, model, "автоссылка и пустой адрес")
        XCTAssertTrue(model.unreliableRanges.isEmpty, "ненадёжных диапазонов нет")
        func collect(_ nodes: [MarkdownInlineNode]) -> [MarkdownInlineNode] {
            nodes.flatMap { node -> [MarkdownInlineNode] in
                if case .link = node.kind { return [node] + collect(node.children) }
                return collect(node.children)
            }
        }
        let links = collect(model.blocks.flatMap(\.inlines))
        XCTAssertEqual(links.map { (text as NSString).substring(with: $0.range) }, ["<https://a.b>", "[a]()", "[中文](u)"])
        XCTAssertFalse(links.contains { $0.isUnreliable })
    }

    /// Сужение защиты: абзац с `[`, где после метки нет `]:`, сохраняет точные позиции; настоящее определение ссылки — под защитой.
    func testReferenceGuardIsNarrowedToPossibleDefinitions() {
        func emphasisRange(_ text: String) -> (MarkdownInlineNode?, [MarkdownInlineNode], MarkdownDocumentModel) {
            let model = parse(text)
            assertInvariants(text, model, text.debugDescription)
            func all(_ nodes: [MarkdownInlineNode]) -> [MarkdownInlineNode] { nodes.flatMap { [$0] + all($0.children) } }
            func blocks(_ list: [MarkdownBlockNode]) -> [MarkdownInlineNode] { list.flatMap { all($0.inlines) + blocks($0.children) } }
            let nodes = blocks(model.blocks)
            return (nodes.first { $0.kind == .emphasis }, nodes, model)
        }
        for text in ["> [!NOTE]\n> текст *б*\n> ещё", "[a] text *б*\nb", "[a] text\nb *б* 😀", "[a\nb] *б*\nc"] {
            let (emphasis, _, model) = emphasisRange(text)
            XCTAssertEqual(emphasis.map { (text as NSString).substring(with: $0.range) }, "*б*", "точная позиция: \(text.debugDescription)")
            XCTAssertEqual(emphasis?.isUnreliable, false, "узел надёжен: \(text.debugDescription)")
            XCTAssertTrue(model.unreliableRanges.isEmpty, "ненадёжных диапазонов нет: \(text.debugDescription)")
        }
        // Определение внутри абзаца (cmark его съедает): защита срабатывает, надёжный узел не лежит на определении.
        for text in ["[x]: text\nб *в*\nещё", "[x]: /u\r\nб *в*\r\nещё"] {
            let (_, nodes, _) = emphasisRange(text)
            let definition = range(of: "[x]:", in: text)
            for node in nodes where !node.isUnreliable {
                XCTAssertNotEqual(node.range.location, definition.location, "надёжный узел не на определении: \(text.debugDescription)")
            }
        }
    }

    // MARK: - Контракт R9 и дополнения U3.1 (U2.3d)

    /// R9: у заголовка внутри определения сноски `id` и `slug` пустые, `headingIDs` его не содержит, а нумерация следующих не сбивается.
    func testHeadingInFootnoteDefinitionHasEmptyIDAndDoesNotShiftNumbering() {
        let text = "# Раз 😀\r\n\r\nтекст[^a]\r\n\r\n[^a]: # Раз 😀\r\n\r\n# Раз 😀\r\n"
        let model = parse(text)
        func headings(_ blocks: [MarkdownBlockNode]) -> [MarkdownBlockNode.Heading] {
            blocks.flatMap { block -> [MarkdownBlockNode.Heading] in
                var found: [MarkdownBlockNode.Heading] = []
                if case let .heading(data) = block.kind { found.append(data) }
                return found + headings(block.children)
            }
        }
        let found = headings(model.blocks)
        XCTAssertEqual(found.count, 3)
        guard found.count == 3 else { return }
        XCTAssertEqual(found[1].id, "")
        XCTAssertEqual(found[1].slug, "")
        XCTAssertTrue(found[1].inUnsupportedContainer)
        XCTAssertFalse(found[1].isTopLevel)
        XCTAssertEqual(model.headingIDs, [found[0].id, found[2].id])
        XCTAssertEqual(found[2].id, "lac-heading-раз-1", "заголовок в сноске не занимает номер")
        XCTAssertEqual(model.headingIDs.count, Set(model.headingIDs).count)
    }

    /// Дополнение U3.1: `alt` картинки — как `plain`-вывод cmark (текст потомков, разрыв строки — пробел), сверка с рендером.
    func testImageAltIsPlainTextOfDescendantsAndMatchesRenderer() {
        let text = "![Привет **жирный** 😀 `код` [ссылка](u) 漢字\r\nвторая строка](a.png)\r\n"
        let model = parse(text)
        guard let node = model.blocks.first?.inlines.first, case let .image(image) = node.kind else { return XCTFail("ожидалось изображение") }
        XCTAssertEqual(image.alt, "Привет жирный 😀 код ссылка 漢字 вторая строка")
        let html = MarkdownHTMLRenderer.renderPage(text, darkMode: false).html
        XCTAssertTrue(html.contains("alt=\"\(image.alt)\""), "alt в рендере: \(html)")
    }

    // MARK: - U4.5.0: голые ссылки и определения ссылок перед текстом

    /// Тексты и ссылки первого абзаца: (вид, подстрока исходника по диапазону, ненадёжность).
    private func firstParagraphParts(_ text: String, _ model: MarkdownDocumentModel) -> [String] {
        let ns = text as NSString
        guard let paragraph = model.blocks.first(where: { $0.kind == .paragraph }) else { return ["нет абзаца"] }
        return paragraph.inlines.map { node in
            let label: String
            switch node.kind {
            case let .text(value): label = "text(\(value))"
            case .link: label = "link"
            default: label = "\(node.kind)"
            }
            let part = NSMaxRange(node.range) <= ns.length ? ns.substring(with: node.range) : "?"
            return "\(label)=\(part)\(node.isUnreliable ? "!" : "")"
        }
    }

    /// Голая ссылка в середине абзаца с кириллицей и эмодзи: текст до неё не заходит на ссылку, ничего не ненадёжно.
    func testBareLinkInMiddleKeepsTextRangeShortWithCyrillicAndEmoji() {
        let text = "Привет 😀 https://a.com/x конец 中文\n"
        let model = parse(text)
        assertInvariants(text, model, "голая ссылка в середине")
        XCTAssertTrue(model.unreliableRanges.isEmpty)
        let ns = text as NSString
        let texts = model.blocks.flatMap(\.inlines)
        XCTAssertEqual(texts.first?.range, NSRange(location: 0, length: 10))
        XCTAssertEqual(ns.substring(with: texts[0].range), "Привет 😀 ")
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(ns.substring(with: texts[1].range), "https://a.com/x")
        XCTAssertEqual(ns.substring(with: texts[2].range), " конец 中文")
        XCTAssertFalse(texts.contains { $0.isUnreliable })
    }

    /// Ссылка в начале и в конце абзаца, `\n` и `\r\n`: пустого текста нет, абзац надёжен.
    func testBareLinkAtParagraphStartAndEndHasNoEmptyTextAndStaysReliable() {
        for eol in ["\n", "\r\n"] {
            for (text, expected) in [
                ("https://auto.com после 😀\(eol)", ["link=https://auto.com", "text( после 😀)= после 😀"]),
                ("до https://auto.com\(eol)", ["text(до )=до ", "link=https://auto.com"]),
                ("https://auto.com\(eol)", ["link=https://auto.com"]),
                ("до https://auto.com\(eol)вторая 中文 строка\(eol)", ["text(до )=до ", "link=https://auto.com", "text(вторая 中文 строка)=вторая 中文 строка"])
            ] {
                let model = parse(text)
                assertInvariants(text, model, "ссылка у края абзаца \(text.debugDescription)")
                XCTAssertTrue(model.unreliableRanges.isEmpty, "\(text.debugDescription): ненадёжных диапазонов нет, а есть \(model.unreliableRanges), узлы \(firstParagraphParts(text, model))")
                let parts = firstParagraphParts(text, model).map { $0.replacingOccurrences(of: eol, with: "\n") }
                XCTAssertEqual(parts.filter { !$0.hasPrefix("softBreak") }, expected, "\(text.debugDescription)")
                XCTAssertFalse(model.blocks.flatMap(\.inlines).contains { if case .text("") = $0.kind { return true } else { return false } })
            }
        }
    }

    /// `www.…` и адрес почты: текст до них короткий, после почты нет пустого узла, диапазоны идут по порядку.
    func testWwwAndEmailAutolinksKeepNeighbourTextRanges() {
        let text = "см www.example.com/путь. и mail@ex.com\n"
        let model = parse(text)
        assertInvariants(text, model, "www и почта")
        XCTAssertTrue(model.unreliableRanges.isEmpty)
        let nodes = model.blocks.flatMap(\.inlines)
        let ns = text as NSString
        XCTAssertEqual(nodes.map { ns.substring(with: $0.range) }, ["см ", "www.example.com/путь", ". и ", "mail@ex.com"])
        XCTAssertFalse(nodes.contains { $0.isUnreliable })
        for (previous, next) in zip(nodes, nodes.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(previous.range), next.range.location, "узлы не пересекаются")
        }
    }

    /// Списки соседних строчных узлов всех блоков, включая ячейки таблиц и детей узлов.
    private func siblingLists(_ model: MarkdownDocumentModel) -> [[MarkdownInlineNode]] {
        var lists: [[MarkdownInlineNode]] = []
        func inlineLists(_ nodes: [MarkdownInlineNode]) {
            lists.append(nodes)
            for node in nodes { inlineLists(node.children) }
        }
        func walk(_ blocks: [MarkdownBlockNode]) {
            for block in blocks {
                inlineLists(block.inlines)
                if case let .table(table) = block.kind { for row in table.rows { for cell in row.cells { inlineLists(cell.inlines) } } }
                walk(block.children)
            }
        }
        walk(model.blocks)
        return lists
    }

    /// Соседние надёжные узлы не пересекаются, пустых текстовых узлов нет; ненадёжный узел допустим только вместе с ненадёжным участком.
    private func assertNoOverlap(_ text: String, _ model: MarkdownDocumentModel, file: StaticString = #filePath, line: UInt = #line) {
        for list in siblingLists(model) {
            for node in list {
                if case .text("") = node.kind { XCTFail("\(text.debugDescription): пустой текстовый узел", file: file, line: line) }
                if node.isUnreliable { XCTAssertFalse(model.unreliableRanges.isEmpty, "\(text.debugDescription): ненадёжный узел вне unreliableRanges", file: file, line: line) }
            }
            let reliable = list.filter { !$0.isUnreliable }
            for (previous, next) in zip(reliable, reliable.dropFirst()) {
                XCTAssertLessThanOrEqual(NSMaxRange(previous.range), next.range.location, "\(text.debugDescription): \(previous.range) пересекается с \(next.range)", file: file, line: line)
            }
        }
    }

    private func substrings(_ text: String, _ nodes: [MarkdownInlineNode]) -> [String] {
        nodes.map { (text as NSString).substring(with: $0.range) }
    }

    /// Голая ссылка в пункте списка с определением ссылки: текст и дочерний текст ссылки точные.
    func testBareLinkInListItemAfterReferenceDefinitionKeepsRanges() {
        let text = "- пункт\n  [x]: http://a.com\n  текст [x] https://b.com 中文\n"
        let model = parse(text)
        assertInvariants(text, model, "ссылка в пункте")
        assertNoOverlap(text, model)
        XCTAssertTrue(model.unreliableRanges.isEmpty, "\(model.unreliableRanges), \(model.blocks.map { $0.kind })")
        let lists = siblingLists(model).filter { !$0.isEmpty }
        let flat = lists.flatMap { $0 }
        let pieces = substrings(text, flat)
        XCTAssertTrue(pieces.contains("https://b.com"), "\(pieces)")
        XCTAssertTrue(pieces.contains(" 中文"), "\(pieces)")
        XCTAssertTrue(pieces.contains("пункт"), "\(pieces)")
        XCTAssertTrue(pieces.contains("текст [x] "), "\(pieces)")
        XCTAssertFalse(flat.contains { $0.isUnreliable })
        XCTAssertEqual(pieces.filter { $0 == "http://a.com" }.count, 2, "ссылка и её дочерний текст целиком: \(pieces)")
        XCTAssertEqual(pieces.filter { $0 == "https://b.com" }.count, 2, "ссылка и её дочерний текст целиком: \(pieces)")
    }

    /// Ссылка со скобкой или `<…>` после текста с сущностью: диапазон текста остаётся целым, обрезка касается только голых ссылок.
    func testTextWithEntityBeforeBracketLinkKeepsFullRange() {
        for (text, expectedText) in [("a&amp;[x](u)\n", "a&amp;"), ("AT&amp;<https://x.com>\n", "AT&amp;"), ("&amp;[x](u)\n", "&amp;")] {
            let model = parse(text)
            assertInvariants(text, model, text)
            assertNoOverlap(text, model)
            let nodes = model.blocks.flatMap(\.inlines)
            XCTAssertEqual(substrings(text, nodes).first, expectedText, text.debugDescription)
            XCTAssertFalse(nodes.contains { $0.isUnreliable }, text.debugDescription)
            XCTAssertTrue(model.unreliableRanges.isEmpty, text.debugDescription)
        }
    }

    /// Текст, литерал которого отличается от исходника (SMART, `\*`, сущности), перед голой ссылкой кончается ровно там, где начинается ссылка.
    func testTextWithChangedLiteralEndsWhereBareLinkStarts() {
        for text in ["say \"hi\" https://x.com z\n", "it's -- https://x.com z\n", "a \\* https://x.com b\n", "x&nbsp;https://x.com\n"] {
            let model = parse(text)
            assertInvariants(text, model, text)
            assertNoOverlap(text, model)
            let nodes = model.blocks.flatMap(\.inlines)
            guard let linkIndex = nodes.firstIndex(where: { if case .link = $0.kind { return true } else { return false } }), linkIndex > 0 else {
                XCTFail("нет ссылки после текста: \(text.debugDescription)"); continue
            }
            let link = nodes[linkIndex], before = nodes[linkIndex - 1]
            XCTAssertEqual(substrings(text, [link]).first, "https://x.com", text.debugDescription)
            XCTAssertFalse(before.isUnreliable, text.debugDescription)
            XCTAssertFalse(link.isUnreliable, text.debugDescription)
            XCTAssertTrue(model.unreliableRanges.isEmpty, text.debugDescription)
            XCTAssertEqual(NSMaxRange(before.range), link.range.location, "конец текста — начало ссылки: \(text.debugDescription)")
        }
    }

    /// Голая ссылка в ячейке, заголовке, цитате, внутри `*…*`; две ссылки подряд, `)` и `.` после адреса, `&` в адресе.
    func testBareLinksInVariousContainersKeepNonOverlappingRanges() {
        let cases: [(String, [String])] = [
            ("| а | б |\n| - | - |\n| до https://a.com 中文 | www.b.com |\n", ["а", "б", "до ", "https://a.com", " 中文", "www.b.com"]),
            ("# Заголовок https://a.com конец\n", ["Заголовок ", "https://a.com", " конец"]),
            ("> цитата 😀 https://a.com конец\n", ["цитата 😀 ", "https://a.com", " конец"]),
            ("*до https://a.com после*\n", ["до ", "https://a.com", " после"]),
            ("https://a.com https://b.com\n", ["https://a.com", " ", "https://b.com"]),
            ("(см. https://a.com).\n", ["(см. ", "https://a.com", ")."]),
            ("до https://a.com/x?a=1&b=2 после\n", ["до ", "https://a.com/x?a=1&b=2", " после"])
        ]
        for (text, expected) in cases {
            let model = parse(text)
            assertInvariants(text, model, text)
            assertNoOverlap(text, model)
            XCTAssertTrue(model.unreliableRanges.isEmpty, "\(text.debugDescription): \(model.unreliableRanges)")
            var found: [String] = []
            func collect(_ nodes: [MarkdownInlineNode]) {
                for node in nodes {
                    if case .link = node.kind { found.append((text as NSString).substring(with: node.range)); continue }
                    if case .text = node.kind { found.append((text as NSString).substring(with: node.range)) }
                    collect(node.children)
                }
            }
            func collectBlocks(_ blocks: [MarkdownBlockNode]) {
                for block in blocks {
                    collect(block.inlines)
                    if case let .table(table) = block.kind { table.rows.flatMap(\.cells).forEach { collect($0.inlines) } }
                    collectBlocks(block.children)
                }
            }
            collectBlocks(model.blocks)
            XCTAssertEqual(found, expected, text.debugDescription)
        }
    }

    /// Определения ссылок перед текстом: title на следующей строке, несколько подряд, многострочное в цитате и в пункте.
    func testReferenceDefinitionVariantsKeepFirstTextExact() {
        for eol in ["\n", "\r\n"] {
            for (template, expected) in [
                ("[a]: /url{E}  \"Титул 😀\"{E}Привет мир{E}", "Привет мир"),
                ("[a]: /u1{E}[b]: /u2 \"t\"{E}[c]: <中文>{E}текст [a] [b]{E}", "текст "),
                ("> [a]: /url{E}> \"title\"{E}> Привет 😀 мир{E}", "Привет 😀 мир"),
                ("- [a]: /url{E}  \"title\"{E}  Привет 😀 мир{E}", "Привет 😀 мир")
            ] {
                let text = template.replacingOccurrences(of: "{E}", with: eol)
                let model = parse(text)
                assertInvariants(text, model, text)
                assertNoOverlap(text, model)
                let nodes = siblingLists(model).flatMap { $0 }
                guard let node = nodes.first(where: { if case .text = $0.kind { return true } else { return false } }) else { XCTFail("нет текста: \(text.debugDescription)"); continue }
                XCTAssertFalse(node.isUnreliable, text.debugDescription)
                XCTAssertEqual((text as NSString).substring(with: node.range), expected, text.debugDescription)
            }
        }
    }

    /// Определения ссылок и строка с табом: первый текст после них точный и надёжный (LF, CRLF, CR).
    func testTextAfterReferenceDefinitionsWithTabContinuationIsReliable() {
        for eol in ["\n", "\r\n", "\r"] {
            for (template, expected) in [
                ("[id]: /url{E}\thello{E}", "hello"),
                ("- [id]: /url{E}\t中文 hello{E}", "中文 hello"),
                ("> [id]: /url{E}>\t中文 hello 😀{E}", "中文 hello 😀")
            ] {
                let text = template.replacingOccurrences(of: "{E}", with: eol)
                let model = parse(text)
                func firstText(_ blocks: [MarkdownBlockNode]) -> MarkdownInlineNode? {
                    for block in blocks {
                        if let node = block.inlines.first(where: { if case .text = $0.kind { return true } else { return false } }) { return node }
                        if let node = firstText(block.children) { return node }
                    }
                    return nil
                }
                guard let node = firstText(model.blocks), case let .text(value) = node.kind else { XCTFail("нет текста: \(text.debugDescription)"); continue }
                XCTAssertEqual(value, expected, text.debugDescription)
                XCTAssertFalse(node.isUnreliable, "текст надёжен: \(text.debugDescription)")
                XCTAssertEqual((text as NSString).substring(with: node.range), expected, "диапазон текста: \(text.debugDescription)")
            }
        }
    }
}
