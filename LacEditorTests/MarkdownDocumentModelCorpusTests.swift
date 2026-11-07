import Foundation
import XCTest
import cmark_gfm
import cmark_gfm_extensions
@testable import LacEditor

/// Корпус (702 примера GFM и 38 документов, LF и CRLF) против модели единого разбора (U2.6): тест сам разбирает текст через cmark,
/// обходит дерево и сравнивает найденное с модель-значениями. Ядро для эталона не используется, исключений нет.
final class MarkdownDocumentModelCorpusTests: XCTestCase {
    // MARK: - Нижние планки (первый прогон стенда lac-writer-check; пропуск не должен превращаться в тихое «всё проходит»)

    /// Блоки кода на spec+ext (U2.4: 91 блок в 702 примерах), пропущено всегда 0.
    private static let minSpecCodeBlocks = 91
    /// Блоки кода в документах корпуса на один набор настроек (LF и CRLF вместе).
    private static let minDocumentCodeBlocks = 48
    /// Маркеры узлов, проверенные на «внутри узла и без пересечений» (3 набора, LF и CRLF суммарно).
    /// Многострочные фрагменты кода читаемого текста, сверенные LF и CRLF (3 набора настроек суммарно).
    private static let minMultilineCodeFragments = 86
    private static let minMarkers = 9212
    /// Образцы с непустой маской на один набор настроек (LF и CRLF вместе): editor и editorLoose 14, minimal 6 (там нет CriticMarkup); планка по минимальному.
    private static let minMaskedSamples = 6
    /// Сравнено на корпусе (3 набора настроек, LF и CRLF суммарно): значения первого прогона на стенде lac-writer-check (пропущено: ячеек 70, остальных 0).
    private static let minHeadings = 682
    private static let minLinks = 992
    private static let minImages = 158
    private static let minTables = 214
    private static let minCells = 1352

    // MARK: - Наборы настроек и образцы

    private enum CorpusModelSet: String, CaseIterable {
        case editor, editorLoose, minimal

        var includesSpec: Bool { self != .minimal }
        var options: MarkdownDocumentModel.Options {
            switch self {
            case .editor:
                return .init(syntax: MarkdownSyntaxOptions(), includes: Self.allIncludes, isVaultNote: true, detectsFrontMatter: true)
            case .editorLoose:
                return .init(syntax: MarkdownSyntaxOptions(strictMode: false, legacyInlineMath: true, smartPunctuation: false),
                             includes: Self.allIncludes, isVaultNote: true, detectsFrontMatter: true)
            case .minimal:
                return .init(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: true)
            }
        }
        var maskOptions: MarkdownSourceMask.Options {
            MarkdownSourceMask.Options(syntax: options.syntax, isVaultNote: options.isVaultNote, detectsFrontMatter: options.detectsFrontMatter,
                                       includesCritic: options.includes.contains(.criticMarkup))
        }
        static let allIncludes: MarkdownDocumentModel.Includes = [.wikiLinks, .noteEmbeds, .criticMarkup, .emoji, .uppercaseRuns, .readableText,
                                                                  .elementIndex, .blockIndex, .editorContext]
    }

    private struct Sample {
        let id: String
        let text: String
        let isCRLF: Bool
        var label: String { id + (isCRLF ? " [CRLF]" : " [LF]") }
    }

    private func specSamples() throws -> [Sample] {
        try (BaselineCorpus.spec() + BaselineCorpus.extensions()).flatMap { item -> [Sample] in
            [Sample(id: item.id, text: BaselineCorpus.lf(item.text), isCRLF: false), Sample(id: item.id, text: BaselineCorpus.crlf(item.text), isCRLF: true)]
        }
    }

    private func documentSamples() throws -> [Sample] {
        try BaselineCorpus.documents().flatMap { item -> [Sample] in
            [Sample(id: item.id, text: BaselineCorpus.lf(item.text), isCRLF: false), Sample(id: item.id, text: BaselineCorpus.crlf(item.text), isCRLF: true)]
        }
    }

    private func samples(for set: CorpusModelSet) throws -> [Sample] {
        (set.includesSpec ? try specSamples() : []) + (try documentSamples())
    }

    // MARK: - Значения cmark

    private struct CodeValue: Equatable { var info: String; var isFenced: Bool; var literal: String }
    private struct HeadingValue: Equatable { var level: Int; var title: String }
    private struct LinkValue: Equatable { var url: String; var title: String }
    private struct ImageValue: Equatable { var url: String; var alt: String; var title: String }
    private struct CellValue: Equatable { var text: String?; var colspan: Int; var rowspan: Int }
    private struct TableValue: Equatable {
        var alignments: [MarkdownTableAlignment]
        var isHeader: [Bool]
        var rows: [[CellValue]]
    }
    private struct Entry<Value> {
        var value: Value
        /// Узел лежит на строке с участком маски: значения cmark взяты из маскированного текста.
        var skipped: Bool
        /// Внутри определения сноски: заголовок без id.
        var inFootnote = false
    }

    private struct Reference {
        var mask: MarkdownSourceMask.Result
        var model: MarkdownDocumentModel
        var codes: [Entry<CodeValue>] = []
        var headings: [Entry<HeadingValue>] = []
        var links: [Entry<LinkValue>] = []
        var images: [Entry<ImageValue>] = []
        var tables: [Entry<TableValue>] = []
    }

    /// У определения сноски имя типа cmark — `<unknown>`, поэтому по типу узла.
    private func isFootnoteDefinition(_ node: OpaquePointer) -> Bool { cmark_node_get_type(node) == CMARK_NODE_FOOTNOTE_DEFINITION }
    private func typeName(_ node: OpaquePointer) -> String { cmark_node_get_type_string(node).map { String(cString: $0) } ?? "" }
    private func children(_ node: OpaquePointer) -> [OpaquePointer] {
        var result: [OpaquePointer] = []
        var child = cmark_node_first_child(node)
        while let current = child { result.append(current); child = cmark_node_next(current) }
        return result
    }

    /// Номер строки cmark (с 1) для каждой позиции UTF-16: `\r\n` и одиночные `\r` — один перевод строки.
    private func lineNumbers(_ units: [UInt16]) -> [Int] {
        var result = [Int](repeating: 1, count: units.count + 1)
        var line = 1
        for (index, unit) in units.enumerated() {
            if unit == 10, index > 0, units[index - 1] == 13 { result[index] = line - 1; continue }
            result[index] = line
            if unit == 10 || unit == 13 { line += 1 }
        }
        result[units.count] = line
        return result
    }

    /// Правило видимого текста заголовка и `alt` (как `headingData`, но своё: тест не вызывает код ядра).
    private func visibleText(_ node: OpaquePointer, math: [OpaquePointer: String]) -> String {
        var result = ""
        func append(_ current: OpaquePointer) {
            switch typeName(current) {
            case "text", "code":
                if let literal = cmark_node_get_literal(current) { result += String(cString: literal).replacingOccurrences(of: "\t", with: " ") }
            case "softbreak", "linebreak": result += " "
            case "custom_inline": if let text = math[current] { result += "$" + text + "$" }
            default: break
            }
            children(current).forEach(append)
        }
        append(node)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Текст ячейки из простого набора узлов; другие виды — `nil` (ячейка пропускается).
    private func simpleCellText(_ node: OpaquePointer) -> String? {
        var result = ""
        for child in children(node) {
            switch typeName(child) {
            case "text", "code": result += cmark_node_get_literal(child).map { String(cString: $0) } ?? ""
            case "softbreak", "linebreak": result += "\n"
            case "emph", "strong", "strikethrough":
                guard let inner = simpleCellText(child) else { return nil }
                result += inner
            default: return nil
            }
        }
        return result
    }

    private func reference(_ text: String, _ set: CorpusModelSet, message: String, file: StaticString = #filePath, line: UInt = #line) -> Reference? {
        guard !text.utf8.contains(0) else { XCTFail("\(message): в корпусе NUL", file: file, line: line); return nil }
        guard let model = MarkdownDocumentParser.parse(text, options: set.options) else { XCTFail("\(message): разбор вернул nil", file: file, line: line); return nil }
        let mask = MarkdownSourceMask.mask(text, options: set.maskOptions)
        var result = Reference(mask: mask, model: model)
        let syntax = set.options.syntax
        let cmarkOptions = ((syntax.smartPunctuation ?? true) ? CMARK_OPT_SMART : 0) | CMARK_OPT_TABLE_SPANS | CMARK_OPT_FOOTNOTES
        let lines = lineNumbers(Array(text.utf16))
        var maskLines = Set<Int>()
        for segment in mask.segments {
            let first = lines[min(segment.range.location, lines.count - 1)]
            let last = lines[min(max(segment.range.location, NSMaxRange(segment.range) - 1), lines.count - 1)]
            maskLines.formUnion(first...last)
        }
        let found: Reference? = MarkdownMathExtension.withDocument(
            mask.text, options: cmarkOptions, includeInline: syntax.inlineMath, legacyInlineMath: syntax.legacyInlineMath,
            strictMode: syntax.strictMode, sourceForPositions: mask.text
        ) { (root: OpaquePointer, ext: OpaquePointer, inline: [MarkdownMathExtension.Inline]) -> Reference in
            var out = result
            var math: [OpaquePointer: String] = [:]
            for item in inline { math[item.node] = item.text }
            func isSkipped(_ node: OpaquePointer) -> Bool {
                if maskLines.isEmpty { return false }
                var current = node
                while !["paragraph", "heading", "table", "code_block"].contains(typeName(current)), let parent = cmark_node_parent(current) { current = parent }
                let start = Int(cmark_node_get_start_line(current)), end = Int(cmark_node_get_end_line(current))
                return start <= end && (start...end).contains { maskLines.contains($0) }
            }
            func visit(_ node: OpaquePointer, inImage: Bool, inFootnote: Bool) {
                let name = typeName(node)
                switch name {
                case "code_block" where cmark_node_get_syntax_extension(node) != ext:
                    var length: Int32 = 0, offset: Int32 = 0, character: CChar = 0
                    let fenced = cmark_node_get_fenced(node, &length, &offset, &character) != 0
                    out.codes.append(Entry(value: CodeValue(info: cmark_node_get_fence_info(node).map { String(cString: $0) } ?? "", isFenced: fenced,
                                                            literal: cmark_node_get_literal(node).map { String(cString: $0) } ?? ""), skipped: false))
                case "heading":
                    out.headings.append(Entry(value: HeadingValue(level: Int(cmark_node_get_heading_level(node)), title: visibleText(node, math: math)),
                                              skipped: isSkipped(node), inFootnote: inFootnote))
                case "link" where !inImage:
                    out.links.append(Entry(value: LinkValue(url: cmark_node_get_url(node).map { String(cString: $0) } ?? "",
                                                            title: cmark_node_get_title(node).map { String(cString: $0) } ?? ""), skipped: isSkipped(node)))
                case "image" where !inImage:
                    out.images.append(Entry(value: ImageValue(url: cmark_node_get_url(node).map { String(cString: $0) } ?? "", alt: visibleText(node, math: math),
                                                              title: cmark_node_get_title(node).map { String(cString: $0) } ?? ""), skipped: isSkipped(node)))
                case "table":
                    let columns = Int(cmark_gfm_extensions_get_table_columns(node))
                    var alignments: [MarkdownTableAlignment] = []
                    if let raw = cmark_gfm_extensions_get_table_alignments(node) {
                        for index in 0..<columns {
                            switch raw[index] {
                            case 108: alignments.append(.left)
                            case 99: alignments.append(.center)
                            case 114: alignments.append(.right)
                            default: alignments.append(.unspecified)
                            }
                        }
                    }
                    var headers: [Bool] = []
                    var rows: [[CellValue]] = []
                    for row in children(node) {
                        headers.append(cmark_gfm_extensions_get_table_row_is_header(UnsafeMutablePointer<cmark_node>(row)) != 0)
                        rows.append(children(row).map { cell in
                            let colspan = cmark_gfm_extensions_get_table_cell_colspan(UnsafeMutablePointer<cmark_node>(cell))
                            let rowspan = cmark_gfm_extensions_get_table_cell_rowspan(UnsafeMutablePointer<cmark_node>(cell))
                            return CellValue(text: simpleCellText(cell), colspan: colspan == UInt32.max ? 1 : Int(colspan),
                                             rowspan: rowspan == UInt32.max ? 1 : Int(rowspan))
                        })
                    }
                    out.tables.append(Entry(value: TableValue(alignments: alignments, isHeader: headers, rows: rows), skipped: isSkipped(node)))
                default: break
                }
                for child in children(node) {
                    visit(child, inImage: inImage || name == "image", inFootnote: inFootnote || isFootnoteDefinition(child))
                }
            }
            // cmark переносит определения сносок в конец документа; возвращаем их на место по номеру строки.
            // Порядок определений у cmark — по первому использованию, у модели — по тексту; строка берётся у первого узла с позицией.
            func firstLine(_ node: OpaquePointer) -> Int {
                let own = Int(cmark_node_get_start_line(node))
                if own > 0 { return own }
                for child in children(node) { let line = firstLine(child); if line > 0 { return line } }
                return 0
            }
            let tops = children(root)
            var ordered = tops.filter { !isFootnoteDefinition($0) }
            for definition in tops.filter({ isFootnoteDefinition($0) }).sorted(by: { firstLine($0) < firstLine($1) }) {
                let index = ordered.firstIndex { firstLine($0) > firstLine(definition) } ?? ordered.count
                ordered.insert(definition, at: index)
            }
            ordered.forEach { visit($0, inImage: false, inFootnote: isFootnoteDefinition($0)) }
            return out
        }
        guard let found else { XCTFail("\(message): cmark не разобрал текст", file: file, line: line); return nil }
        result = found
        return result
    }

    // MARK: - Обход модели

    private func walkBlocks(_ blocks: [MarkdownBlockNode], block: (MarkdownBlockNode) -> Void, inline: (MarkdownInlineNode) -> Void) {
        func walkInlines(_ nodes: [MarkdownInlineNode]) {
            for node in nodes { inline(node); walkInlines(node.children) }
        }
        func walk(_ nodes: [MarkdownBlockNode]) {
            for node in nodes {
                block(node)
                walkInlines(node.inlines)
                if case let .table(table) = node.kind { for row in table.rows { for cell in row.cells { walkInlines(cell.inlines) } } }
                walk(node.children)
            }
        }
        walk(blocks)
    }

    private func modelBlocks(_ model: MarkdownDocumentModel) -> [MarkdownBlockNode] {
        var result: [MarkdownBlockNode] = []
        walkBlocks(model.blocks, block: { result.append($0) }, inline: { _ in })
        return result
    }

    private func modelInlines(_ model: MarkdownDocumentModel) -> [MarkdownInlineNode] {
        var result: [MarkdownInlineNode] = []
        walkBlocks(model.blocks, block: { _ in }, inline: { result.append($0) })
        return result
    }

    private func modelCellText(_ nodes: [MarkdownInlineNode]) -> String? {
        var result = ""
        for node in nodes {
            switch node.kind {
            case .text(let text), .code(let text): result += text
            case .softBreak, .hardBreak: result += "\n"
            case .strong, .emphasis, .strikethrough:
                guard let inner = modelCellText(node.children) else { return nil }
                result += inner
            default: return nil
            }
        }
        return result
    }

    // MARK: - Помощники

    private func glued(_ code: MarkdownBlockNode.CodeBlock, in text: String) -> String {
        let source = text as NSString
        return zip(code.bodySegments, code.bodyPadding).map { String(repeating: " ", count: $1) + source.substring(with: $0) + "\n" }.joined()
    }

    private func intersects(_ a: NSRange, _ b: NSRange) -> Bool { a.location < NSMaxRange(b) && b.location < NSMaxRange(a) }

    /// Один образец: подготовить значения cmark и модель; `nil` — уже записано падение.
    private func forEach(_ samples: [Sample], _ set: CorpusModelSet, file: StaticString = #filePath, line: UInt = #line,
                         _ body: (Sample, String, Reference) -> Void) {
        for sample in samples {
            let message = "\(sample.label) \(set.rawValue)"
            if let reference = reference(sample.text, set, message: message, file: file, line: line) { body(sample, message, reference) }
        }
    }

    private struct Counts { var compared = 0, skipped = 0 }

    // MARK: - 1. Блоки кода

    private func checkCodeBlocks(_ samples: [Sample], _ set: CorpusModelSet, counts: inout Counts) {
        var counter = counts
        forEach(samples, set) { sample, message, reference in
            var models: [(node: MarkdownBlockNode, code: MarkdownBlockNode.CodeBlock)] = []
            for node in modelBlocks(reference.model) { if case let .codeBlock(code) = node.kind { models.append((node, code)) } }
            XCTAssertEqual(models.count, reference.codes.count, "\(message): число блоков кода")
            guard models.count == reference.codes.count else { return }
            for (index, pair) in zip(models, reference.codes).enumerated() {
                let (model, cmark) = pair
                let step = "\(message): блок кода \(index)"
                XCTAssertEqual(model.code.info, cmark.value.info, "\(step): info")
                XCTAssertEqual(model.code.isFenced, cmark.value.isFenced, "\(step): isFenced")
                XCTAssertEqual(model.code.literal, cmark.value.literal, "\(step): литерал модели и cmark")
                XCTAssertEqual(glued(model.code, in: sample.text), cmark.value.literal, "\(step): отрезки тела и литерал cmark")
                XCTAssertFalse(model.node.isUnreliable, "\(step): ненадёжный")
                for segment in model.code.bodySegments {
                    XCTAssertFalse(reference.mask.segments.contains { intersects($0.range, segment) }, "\(step): отрезок тела пересекает маску")
                }
                counter.compared += 1
            }
        }
        counts = counter
    }

    func testCodeBlockBodiesEqualCmarkLiteralAndInfoOnSpecAndExtensions() throws {
        let samples = try specSamples()
        for set in [CorpusModelSet.editor, .editorLoose] {
            var setCounts = Counts()
            checkCodeBlocks(samples, set, counts: &setCounts)
            print("U2.6 код spec+ext \(set.rawValue): сравнено \(setCounts.compared), пропущено \(setCounts.skipped)")
            XCTAssertEqual(setCounts.skipped, 0, "блоки кода не пропускаются")
            XCTAssertGreaterThanOrEqual(setCounts.compared / 2, Self.minSpecCodeBlocks, "нижняя планка блоков кода (LF и CRLF вместе)")
        }
    }

    func testCodeBlockBodiesEqualCmarkLiteralOnDocuments() throws {
        let samples = try documentSamples()
        for set in CorpusModelSet.allCases {
            var counts = Counts()
            checkCodeBlocks(samples, set, counts: &counts)
            print("U2.6 код документы \(set.rawValue): сравнено \(counts.compared), пропущено \(counts.skipped)")
            XCTAssertEqual(counts.skipped, 0, "блоки кода не пропускаются")
            XCTAssertGreaterThanOrEqual(counts.compared, Self.minDocumentCodeBlocks, "нижняя планка блоков кода документов (LF и CRLF вместе)")
        }
    }

    // MARK: - 2–4. Заголовки, адреса, ячейки

    func testHeadingTitlesLinkAddressesImagesAndTableCellsEqualCmarkValues() throws {
        var heading = Counts(), link = Counts(), image = Counts(), table = Counts(), cell = Counts()
        for set in CorpusModelSet.allCases {
            forEach(try samples(for: set), set) { sample, message, reference in
                // Заголовки.
                var headings: [MarkdownBlockNode.Heading] = []
                for node in modelBlocks(reference.model) { if case let .heading(value) = node.kind { headings.append(value) } }
                XCTAssertEqual(headings.count, reference.headings.count, "\(message): число заголовков")
                if headings.count == reference.headings.count {
                    var allocator = MarkdownHeadingAnchors.Allocator()
                    var expectedIDs: [String] = []
                    for (index, pair) in zip(headings, reference.headings).enumerated() {
                        let (model, cmark) = pair
                        XCTAssertEqual(model.inUnsupportedContainer, cmark.inFootnote, "\(message): заголовок \(index) в сноске")
                        if cmark.skipped { heading.skipped += 1 } else {
                            XCTAssertEqual(model.level, cmark.value.level, "\(message): заголовок \(index) уровень")
                            XCTAssertEqual(model.title, cmark.value.title, "\(message): заголовок \(index) текст")
                            heading.compared += 1
                        }
                        if model.inUnsupportedContainer {
                            XCTAssertEqual(model.id, "", "\(message): заголовок \(index) без id")
                        } else {
                            let entry = allocator.next(cmark.value.title)
                            expectedIDs.append(entry.id)
                            XCTAssertEqual(model.id, entry.id, "\(message): заголовок \(index) id")
                        }
                    }
                    XCTAssertEqual(reference.model.headingIDs, expectedIDs, "\(message): headingIDs")
                }
                // Ссылки.
                var links: [MarkdownInlineNode.Link] = []
                var images: [MarkdownInlineNode.Image] = []
                for node in modelInlines(reference.model) {
                    switch node.kind {
                    case .link(let value) where value.form != .html: links.append(value)
                    case .image(let value) where value.syntax != .html: images.append(value)
                    default: break
                    }
                }
                XCTAssertEqual(links.count, reference.links.count, "\(message): число ссылок")
                if links.count == reference.links.count {
                    for (index, pair) in zip(links, reference.links).enumerated() {
                        if pair.1.skipped { link.skipped += 1; continue }
                        XCTAssertEqual(LinkValue(url: pair.0.url, title: pair.0.title ?? ""), pair.1.value, "\(message): ссылка \(index)")
                        link.compared += 1
                    }
                }
                XCTAssertEqual(images.count, reference.images.count, "\(message): число картинок")
                if images.count == reference.images.count {
                    for (index, pair) in zip(images, reference.images).enumerated() {
                        if pair.1.skipped { image.skipped += 1; continue }
                        XCTAssertEqual(ImageValue(url: pair.0.url, alt: pair.0.alt, title: pair.0.title ?? ""), pair.1.value, "\(message): картинка \(index)")
                        image.compared += 1
                    }
                }
                // Таблицы.
                var tables: [MarkdownBlockNode.Table] = []
                for node in modelBlocks(reference.model) { if case let .table(value) = node.kind { tables.append(value) } }
                XCTAssertEqual(tables.count, reference.tables.count, "\(message): число таблиц")
                guard tables.count == reference.tables.count else { return }
                for (index, pair) in zip(tables, reference.tables).enumerated() {
                    if pair.1.skipped { table.skipped += 1; continue }
                    let step = "\(message): таблица \(index)"
                    XCTAssertEqual(pair.0.alignments, pair.1.value.alignments, "\(step): выравнивание")
                    XCTAssertEqual(pair.0.rows.map(\.isHeader), pair.1.value.isHeader, "\(step): строки-заголовки")
                    XCTAssertEqual(pair.0.rows.map { $0.cells.count }, pair.1.value.rows.map(\.count), "\(step): число ячеек")
                    guard pair.0.rows.count == pair.1.value.rows.count else { continue }
                    table.compared += 1
                    for (rowIndex, rows) in zip(pair.0.rows, pair.1.value.rows).enumerated() {
                        guard rows.0.cells.count == rows.1.count else { continue }
                        for (columnIndex, cells) in zip(rows.0.cells, rows.1).enumerated() {
                            let place = "\(step) ячейка \(rowIndex):\(columnIndex)"
                            XCTAssertEqual(cells.0.column, columnIndex, "\(place): столбец")
                            XCTAssertEqual(cells.0.colspan, cells.1.colspan, "\(place): colspan")
                            XCTAssertEqual(cells.0.rowspan, cells.1.rowspan, "\(place): rowspan")
                            XCTAssertEqual(cells.0.virtualSeparators, max(0, cells.1.colspan - 1), "\(place): поглощённые разделители")
                            let expected = cells.1.text, actual = modelCellText(cells.0.inlines)
                            // Без включённых индексов (`minimal`) узлы ячейки те же: простота ячейки у cmark и модели совпадает.
                            if set == .minimal { XCTAssertEqual(expected == nil, actual == nil, "\(place): простота ячейки") }
                            guard let expected, let actual else { cell.skipped += 1; continue }
                            XCTAssertEqual(actual, expected, "\(place): текст")
                            cell.compared += 1
                        }
                    }
                }
            }
        }
        print("U2.6 заголовки \(heading.compared)/\(heading.skipped), ссылки \(link.compared)/\(link.skipped), картинки \(image.compared)/\(image.skipped), таблицы \(table.compared)/\(table.skipped), ячейки \(cell.compared)/\(cell.skipped) (сравнено/пропущено)")
        XCTAssertGreaterThanOrEqual(heading.compared, Self.minHeadings)
        XCTAssertGreaterThanOrEqual(link.compared, Self.minLinks)
        XCTAssertGreaterThanOrEqual(image.compared, Self.minImages)
        XCTAssertGreaterThanOrEqual(table.compared, Self.minTables)
        XCTAssertGreaterThanOrEqual(cell.compared, Self.minCells)
    }

    // MARK: - 5. Маркеры

    func testMarkersLieInsideNodeAndDoNotOverlap() throws {
        var checkedMarkers = 0
        for set in CorpusModelSet.allCases {
            forEach(try samples(for: set), set) { sample, message, reference in
                let length = reference.model.textLength
                func check(_ range: NSRange, _ markers: [NSRange], childMarkers: [NSRange], _ step: String) {
                    for marker in markers {
                        checkedMarkers += 1
                        XCTAssertTrue(marker.location >= 0 && NSMaxRange(marker) <= length, "\(step): маркер \(marker) вне текста")
                        XCTAssertTrue(marker.location >= range.location && NSMaxRange(marker) <= NSMaxRange(range), "\(step): маркер \(marker) вне узла \(range)")
                    }
                    for (index, a) in markers.enumerated() {
                        for b in markers[(index + 1)...] { XCTAssertFalse(intersects(a, b), "\(step): маркеры \(a) и \(b) пересекаются") }
                        for b in childMarkers { XCTAssertFalse(intersects(a, b), "\(step): маркер \(a) пересекает маркер ребёнка \(b)") }
                    }
                }
                func inlines(_ nodes: [MarkdownInlineNode], _ path: String) {
                    for (index, node) in nodes.enumerated() {
                        check(node.range, node.markerRanges, childMarkers: node.children.flatMap(\.markerRanges), "\(path)/i\(index) \(node.kind)")
                        inlines(node.children, "\(path)/i\(index)")
                    }
                }
                func blocks(_ nodes: [MarkdownBlockNode], _ path: String) {
                    for (index, node) in nodes.enumerated() {
                        let here = "\(message) \(path)/b\(index)"
                        check(node.range, node.markerRanges, childMarkers: node.children.flatMap(\.markerRanges) + node.inlines.flatMap(\.markerRanges), here)
                        inlines(node.inlines, here)
                        if case let .table(table) = node.kind {
                            for row in table.rows { for cell in row.cells { inlines(cell.inlines, here + "/cell") } }
                        }
                        blocks(node.children, here)
                    }
                }
                blocks(reference.model.blocks, "")
            }
        }
        print("U2.6 маркеры: проверено \(checkedMarkers)")
        XCTAssertGreaterThanOrEqual(checkedMarkers, Self.minMarkers, "нижняя планка маркеров")
    }

    // MARK: - 6. LF и CRLF с точностью до сдвига

    func testModelOfCRLFTextEqualsLFModelUpToShift() throws {
        var multilineCode = 0
        defer {
            print("U2.6 CRLF: многострочных фрагментов кода в читаемом тексте \(multilineCode)")
            XCTAssertGreaterThanOrEqual(multilineCode, Self.minMultilineCodeFragments, "нижняя планка многострочных фрагментов кода при CRLF")
        }
        for set in CorpusModelSet.allCases {
            let items = (set.includesSpec ? try BaselineCorpus.spec() + BaselineCorpus.extensions() : []) + (try BaselineCorpus.documents())
            for item in items {
                let lf = BaselineCorpus.lf(item.text), crlf = BaselineCorpus.crlf(item.text)
                let message = "\(item.id) \(set.rawValue)"
                guard let a = MarkdownDocumentParser.parse(lf, options: set.options), let b = MarkdownDocumentParser.parse(crlf, options: set.options) else {
                    XCTFail("\(message): разбор вернул nil"); continue
                }
                // shift(p) = p + число `\n` строго левее p.
                var before = [Int](repeating: 0, count: lf.utf16.count + 2)
                for (index, unit) in lf.utf16.enumerated() { before[index + 1] = before[index] + (unit == 10 ? 1 : 0) }
                before[lf.utf16.count + 1] = before[lf.utf16.count]
                func shift(_ position: Int) -> Int { position + before[min(max(position, 0), lf.utf16.count)] }
                XCTAssertEqual(b.textLength, shift(a.textLength), "\(message): длина текста")
                XCTAssertEqual(before[lf.utf16.count], lf.utf16.filter { $0 == 10 }.count, "\(message): таблица сдвигов")
                var left = a, right = b
                // Читаемый текст сравнивается отдельно (ниже): у многострочного кода при CRLF куски построчно, у LF их нет.
                left.readableText = nil
                right.readableText = nil
                let leftDump = BaselineDump(), rightDump = BaselineDump()
                leftDump.mapRange = { NSRange(location: shift($0.location), length: shift(NSMaxRange($0)) - shift($0.location)) }
                var markersA = BaselineMarkers(), markersB = BaselineMarkers()
                // cmark нормализует `\r\n` в литералах, но не обязан в HTML-фрагментах: строки сравниваются без `\r`.
                var leftText = leftDump.line(left)
                // `textLength` индекса элементов — длина исходника целым числом, а не `NSRange`: сдвигается здесь.
                let lengthPattern = try NSRegularExpression(pattern: "textLength([:=] ?)([0-9]+)")
                for match in lengthPattern.matches(in: leftText, range: NSRange(location: 0, length: (leftText as NSString).length)).reversed() {
                    let value = Int((leftText as NSString).substring(with: match.range(at: 2)))!
                    leftText = (leftText as NSString).replacingCharacters(in: match.range(at: 2), with: String(shift(value)))
                }
                let x = markersA.apply(leftText).replacingOccurrences(of: "\\r\\n", with: "\\n")
                let y = markersB.apply(rightDump.line(right)).replacingOccurrences(of: "\\r\\n", with: "\\n")
                XCTAssertEqual(leftDump.problems, [], "\(message): неподдерживаемые типы в дампе LF")
                XCTAssertEqual(rightDump.problems, [], "\(message): неподдерживаемые типы в дампе CRLF")
                if x != y {
                    let xs = x.split(separator: "\n", omittingEmptySubsequences: false), ys = y.split(separator: "\n", omittingEmptySubsequences: false)
                    var report = "\(message): модели LF и CRLF различаются"
                    var shown = 0
                    for index in 0..<max(xs.count, ys.count) {
                        let l = index < xs.count ? xs[index] : "<конец>", r = index < ys.count ? ys[index] : "<конец>"
                        if l != r {
                            report += (shown == 0 ? ", строки:" : "") + "\n  \(index + 1) LF:   \(String(l.prefix(300)))\n  \(index + 1) CRLF: \(String(r.prefix(300)))"
                            shown += 1
                            if shown == 4 { break }
                        }
                    }
                    XCTFail(report)
                }
                func mapped(_ range: NSRange) -> NSRange { NSRange(location: shift(range.location), length: shift(NSMaxRange(range)) - shift(range.location)) }
                XCTAssertEqual(a.readableText == nil, b.readableText == nil, "\(message): наличие читаемого текста")
                if let x = a.readableText, let y = b.readableText {
                    XCTAssertEqual(y.sourceLength, shift(x.sourceLength), "\(message): читаемый текст, длина")
                    XCTAssertEqual(y.unsupportedRanges, x.unsupportedRanges.map(mapped), "\(message): читаемый текст, неподдерживаемые участки")
                    XCTAssertEqual(y.fragments.count, x.fragments.count, "\(message): читаемый текст, число фрагментов")
                    if y.fragments.count == x.fragments.count {
                        // Фрагмент кода: его диапазон пересекает блок кода LF-модели (литерал кончается переводом строки, диапазон узла его не включает).
                        var codeRanges: [NSRange] = []
                        for node in modelBlocks(a) { if case .codeBlock = node.kind { codeRanges.append(node.range) } }
                        for (index, pair) in zip(x.fragments, y.fragments).enumerated() {
                            let step = "\(message): читаемый текст, фрагмент \(index)"
                            XCTAssertEqual(pair.1.text.replacingOccurrences(of: "\r\n", with: "\n"), pair.0.text, "\(step): текст")
                            // Многострочный фрагмент кода при CRLF не совпадает с исходником побуквенно (`\r\n` против `\n`):
                            // `matchesSource == false`, куски построчно (строка совпадает с исходником, `\r\n` одним куском-заменой `\n`).
                            if pair.0.matchesSource, pair.0.text.contains("\n"),
                               codeRanges.contains(where: { intersects($0, pair.0.sourceRange) }) {
                                multilineCode += 1
                                var expected: [MarkdownReadableText.Piece] = []
                                var position = mapped(pair.0.sourceRange).location
                                let lines = pair.0.text.components(separatedBy: "\n")
                                for (lineIndex, line) in lines.enumerated() {
                                    let length = (line as NSString).length
                                    if length > 0 { expected.append(.init(sourceRange: NSRange(location: position, length: length), text: line, matchesSource: true)) }
                                    position += length
                                    if lineIndex < lines.count - 1 { expected.append(.init(sourceRange: NSRange(location: position, length: 2), text: "\n", matchesSource: false)); position += 2 }
                                }
                                XCTAssertEqual(pair.1.sourceRange, mapped(pair.0.sourceRange), "\(step): диапазон")
                                XCTAssertFalse(pair.1.matchesSource, "\(step): matchesSource")
                                XCTAssertEqual(pair.1.pieces, expected, "\(step): куски")
                                continue
                            }
                            XCTAssertEqual(pair.1.sourceRange, mapped(pair.0.sourceRange), "\(step): диапазон")
                            XCTAssertEqual(pair.1.matchesSource, pair.0.matchesSource, "\(step): matchesSource")
                            XCTAssertEqual(pair.1.pieces, pair.0.pieces.map { $0.map { MarkdownReadableText.Piece(sourceRange: mapped($0.sourceRange), text: $0.text, matchesSource: $0.matchesSource) } },
                                           "\(step): куски")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 7. Маска

    func testMaskedTextKeepsLengthAndLineBreaks() throws {
        for set in CorpusModelSet.allCases {
            var maskedSamples = 0
            defer {
                print("U2.6 маска \(set.rawValue): образцов с непустой маской \(maskedSamples)")
                XCTAssertGreaterThanOrEqual(maskedSamples, Self.minMaskedSamples, "нижняя планка образцов с маской (\(set.rawValue))")
            }
            forEach(try samples(for: set), set) { sample, message, reference in
                if !reference.mask.isIdentity { maskedSamples += 1 }
                let source = Array(sample.text.utf16), masked = Array(reference.mask.text.utf16)
                XCTAssertEqual(masked.count, source.count, "\(message): длина маскированного текста")
                XCTAssertEqual(reference.model.textLength, source.count, "\(message): textLength")
                guard masked.count == source.count else { return }
                XCTAssertEqual(masked.indices.filter { masked[$0] == 10 || masked[$0] == 13 }, source.indices.filter { source[$0] == 10 || source[$0] == 13 },
                               "\(message): позиции переводов строк")
                var covered = [Bool](repeating: false, count: source.count)
                for segment in reference.mask.segments {
                    XCTAssertTrue(segment.range.location >= 0 && NSMaxRange(segment.range) <= source.count, "\(message): участок маски вне текста")
                    for index in max(0, segment.range.location)..<min(source.count, NSMaxRange(segment.range)) { covered[index] = true }
                }
                for index in source.indices where !covered[index] {
                    if masked[index] != source[index] { XCTFail("\(message): текст вне участков маски изменён в позиции \(index)"); break }
                }
                XCTAssertEqual(reference.mask.isIdentity, reference.mask.segments.isEmpty, "\(message): isIdentity")
                if reference.mask.isIdentity { XCTAssertEqual(masked, source, "\(message): тождественная маска") }
            }
        }
    }

    // MARK: - Размер корпуса

    func testCorpusSizeLowerBounds() throws {
        XCTAssertEqual(try BaselineCorpus.spec().count, 672)
        XCTAssertEqual(try BaselineCorpus.extensions().count, 30)
        XCTAssertEqual(try BaselineCorpus.documents().count, 38)
        XCTAssertEqual(try BaselineCorpus.crlfDocuments().count, 38)
        var blocks = 0
        forEach(try specSamples().filter { !$0.isCRLF }, .editor) { _, _, reference in blocks += reference.codes.count }
        XCTAssertGreaterThanOrEqual(blocks, Self.minSpecCodeBlocks, "блоки кода в spec+ext")
    }
}
