import Foundation

/// Таблицы оформления (U5.1.b): таблица модели → `MarkdownTable` с показом ячеек (`displayText`, `displayRuns`).
/// Здесь же то, что нужно правке одной ячейки без дерева документа: `projection`, `tableRowDisplay`, `tableCellBreaks`.
extension MarkdownPresentationBuilder {
    struct Projection {
        let text: String
        let rawBoundaries: [Int]
    }

    /// `nil` — таблицу редактор не оформляет (как `MarkdownTableEditingService.presentationTable == nil`).
    /// `block` — узел таблицы (диапазон), `table` — её строки и ячейки с `inlines`, `context` — цитаты и списки вокруг,
    /// `emojiCandidates` — кандидаты `:имя:` документа (для показа эмодзи в ячейках).
    static func presentationTable(_ block: MarkdownBlockNode, table: MarkdownBlockNode.Table, context: TableContext, text: NSString,
                                  emojiCandidates: [MarkdownEmojiCandidate], syntax: MarkdownSyntaxOptions,
                                  isCancelled: @escaping () -> Bool) -> MarkdownTable? {
        guard let base = MarkdownTableEditingService.presentationTable(in: text, range: block.range, containerPrefix: context.containerPrefix,
                                                                      quoteDepth: context.quoteDepth, nestedList: context.nestedList) else { return nil }
        var labels = Set(base.referenceLabels)
        func collect(_ nodes: [MarkdownInlineNode]) {
            for node in nodes {
                if case .link(let link) = node.kind, link.form != .html, !node.isUnreliable, node.range.location >= 0,
                   NSMaxRange(node.range) <= text.length, let label = referenceLabel(text.substring(with: node.range)) { labels.insert(label) }
                collect(node.children)
            }
        }
        for row in table.rows { for cell in row.cells { collect(cell.inlines) } }
        let referenceLabels = labels.sorted()
        let rows = base.rows.enumerated().map { rowIndex, row in
            let cells = row.cells.map { cell -> MarkdownTableCell in
                let display: (String, [MarkdownTableTextRun])
                if rowIndex < table.rows.count, cell.column < table.rows[rowIndex].cells.count {
                    display = renderedCell(inlines: table.rows[rowIndex].cells[cell.column].inlines, cellRange: cell.range, text: text,
                                           emojiCandidates: emojiCandidates, confirmsHTML: true, syntax: syntax, isCancelled: isCancelled)
                } else {
                    display = renderedCell(raw: text.substring(with: cell.range), referenceLabels: referenceLabels, syntax: syntax)
                }
                return MarkdownTableCell(range: cell.range, column: cell.column, virtualSeparators: cell.virtualSeparators,
                                         displayText: display.0, displayRuns: display.1)
            }
            return MarkdownTableRow(range: row.range, cells: cells)
        }
        return MarkdownTable(range: base.range, delimiterRange: base.delimiterRange, alignments: base.alignments,
                             rows: rows, containerPrefix: base.containerPrefix, quoteDepth: base.quoteDepth, nestedList: base.nestedList,
                             referenceLabels: referenceLabels)
    }

    static func projection(_ raw: String) -> Projection {
        let source = raw as NSString
        let transforms = tableCellTransforms(raw)
        var units: [UInt16] = [], boundaries = [0], cursor = 0
        for transform in transforms {
            guard transform.range.location >= cursor, NSMaxRange(transform.range) <= source.length else { continue }
            while cursor < transform.range.location {
                units.append(source.character(at: cursor))
                cursor += 1
                boundaries.append(cursor)
            }
            let replacement = Array(transform.replacement.utf16)
            guard replacement.count == 1 else { continue }
            units.append(replacement[0])
            cursor = NSMaxRange(transform.range)
            boundaries.append(cursor)
        }
        while cursor < source.length {
            units.append(source.character(at: cursor))
            cursor += 1
            boundaries.append(cursor)
        }
        return Projection(text: String(decoding: units, as: UTF16.self), rawBoundaries: boundaries)
    }

    static func referenceLabel(_ raw: String) -> String? {
        let value = raw as NSString
        guard value.length >= 3, value.character(at: 0) == 91 else { return nil }
        func close(_ start: Int) -> Int? {
            var depth = 1, index = start + 1
            while index < value.length {
                let unit = value.character(at: index)
                if unit == 92 && index + 1 < value.length { index += 2; continue }
                if unit == 91 { depth += 1 }
                if unit == 93 { depth -= 1; if depth == 0 { return index } }
                index += 1
            }
            return nil
        }
        guard let firstEnd = close(0) else { return nil }
        let labelRange: NSRange
        if firstEnd == value.length - 1 {
            labelRange = NSRange(location: 1, length: firstEnd - 1)
        } else {
            let secondStart = firstEnd + 1
            guard value.character(at: secondStart) == 91, let secondEnd = close(secondStart), secondEnd == value.length - 1 else { return nil }
            labelRange = secondEnd == secondStart + 1 ? NSRange(location: 1, length: firstEnd - 1) :
                NSRange(location: secondStart + 1, length: secondEnd - secondStart - 1)
        }
        guard labelRange.length > 0 else { return nil }
        return value.substring(with: labelRange)
    }

    static func tableRowDisplay(_ row: MarkdownTableRow, text: NSString, previous: MarkdownTableRow,
                                changedColumn: Int, referenceLabels: [String], syntax: MarkdownSyntaxOptions = .init()) -> MarkdownTableRow {
        let cells = row.cells.map { cell in
            let old = cell.column < previous.cells.count ? previous.cells[cell.column] : nil
            let reusable = cell.column != changedColumn && old?.virtualSeparators == cell.virtualSeparators ? old : nil
            let display: (String, [MarkdownTableTextRun])
            if let reusable, let value = reusable.displayText { display = (value, reusable.displayRuns) }
            else { display = renderedCell(raw: text.substring(with: cell.range), referenceLabels: referenceLabels, syntax: syntax) }
            return MarkdownTableCell(range: cell.range, column: cell.column, virtualSeparators: cell.virtualSeparators,
                                     displayText: display.0, displayRuns: display.1)
        }
        return MarkdownTableRow(range: row.range, cells: cells)
    }

    // MARK: - Ячейка одной строкой

    private static let cellPrefix = "|H|\n|---|\n|"

    /// Ячейка из строки: текст оборачивается в таблицу, чтобы разбор применил экранирование GFM, а позиции остались местными.
    /// Разбирает ядро (`MarkdownDocumentParser`), строчные узлы первой ячейки второй строки берутся из модели.
    private static func parsedCell(_ wrapped: String, syntax: MarkdownSyntaxOptions) -> MarkdownBlockNode.Table.Cell? {
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: [], isVaultNote: false, detectsFrontMatter: false)
        guard let model = MarkdownDocumentParser.parse(wrapped, options: options), let block = model.blocks.first,
              case .table(let table) = block.kind, table.rows.count >= 2, let cell = table.rows[1].cells.first else { return nil }
        return cell
    }

    /// Показ ячейки из строки без дерева документа (правка ячейки). Теги HTML, которых документ не подтверждал, не оформляются:
    /// `<kbd>` и `<span style>` показывают ячейку исходником, `<img>` пропадает.
    static func renderedCell(raw: String, referenceLabels: [String], syntax: MarkdownSyntaxOptions) -> (String, [MarkdownTableTextRun]) {
        guard !raw.utf8.contains(0), !raw.contains("\n"), !raw.contains("\r") else { return (raw, []) }
        let definitions = referenceLabels.map { "[\($0)]: /" }.joined(separator: "\n")
        let wrapped = cellPrefix + raw + "|\n\n" + definitions
        guard let cell = parsedCell(wrapped, syntax: syntax) else { return (raw, []) }
        let range = NSRange(location: (cellPrefix as NSString).length, length: (raw as NSString).length)
        return renderedCell(inlines: cell.inlines, cellRange: range, text: wrapped as NSString, emojiCandidates: [],
                            confirmsHTML: false, syntax: syntax, isCancelled: { false })
    }

    // The wrapper makes the parser apply GFM table escaping while keeping offsets local to one cell.
    static func tableCellBreaks(_ raw: String) -> [NSRange] {
        tableCellTransforms(raw).filter { $0.replacement == "\n" }.map(\.range)
    }

    static func tableCellTransforms(_ raw: String) -> [(range: NSRange, replacement: String)] {
        guard raw.contains("<") || raw.contains("\\"),
              !raw.utf8.contains(0), !raw.contains("\n"), !raw.contains("\r") else { return [] }
        let wrapped = cellPrefix + raw + "|"
        // Разбор идёт без умных знаков и формул: `\|` внутри `$…$` тоже считался экранированием.
        guard let cell = parsedCell(wrapped, syntax: MarkdownSyntaxOptions(inlineMath: false, smartPunctuation: false)) else { return [] }
        let nsText = wrapped as NSString, base = (cellPrefix as NSString).length, rawLength = (raw as NSString).length
        var transforms: [(range: NSRange, replacement: String)] = []
        func visit(_ nodes: [MarkdownInlineNode], flat: Bool) {
            for node in nodes {
                switch node.kind {
                case .rawHTML(let literal):
                    if flat, let range = trustedRange(node, in: nsText), range.location >= base, NSMaxRange(range) <= base + rawLength,
                       isBreakTag(literal, nsText.substring(with: range)) {
                        transforms.append((NSRange(location: range.location - base, length: range.length), "\n"))
                    }
                    continue
                case .code:
                    continue
                case .text:
                    if let range = trustedRange(node, in: nsText), range.location >= base, NSMaxRange(range) <= base + rawLength {
                        var index = range.location
                        while index < NSMaxRange(range) {
                            guard nsText.character(at: index) == 92 else { index += 1; continue }
                            var end = index
                            while end < NSMaxRange(range) && nsText.character(at: end) == 92 { end += 1 }
                            if end < NSMaxRange(range), (nsText.character(at: end) == 124 || nsText.character(at: end) == 60), (end - index) % 2 == 1 {
                                var pair = index
                                while pair + 1 < end {
                                    transforms.append((NSRange(location: pair - base, length: 2), "\\"))
                                    pair += 2
                                }
                                transforms.append((NSRange(location: end - 1 - base, length: 2), nsText.character(at: end) == 124 ? "|" : "<"))
                                index = end + 1
                            } else {
                                var pair = index
                                while pair + 1 < end {
                                    transforms.append((NSRange(location: pair - base, length: 2), "\\"))
                                    pair += 2
                                }
                                index = end
                            }
                        }
                    }
                default: break
                }
                visit(node.children, flat: flat && isHTMLPair(node, in: nsText))
            }
        }
        visit(cell.inlines, flat: true)
        return transforms.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Показ ячейки по строчным узлам модели

    /// Диапазон узла, если позиция подтверждена и лежит в тексте.
    private static func trustedRange(_ node: MarkdownInlineNode, in text: NSString) -> NSRange? {
        guard !node.isUnreliable, node.range.location >= 0, NSMaxRange(node.range) <= text.length else { return nil }
        return node.range
    }

    private static func isBreakTag(_ literal: String, _ source: String) -> Bool {
        source == literal && ["<br>", "<br/>", "<br />"].contains(source.lowercased())
    }

    /// Узла нет в дереве cmark: пара тегов HTML (`<b>`, `<u>`, `<kbd>`, `<span style>`, `<a>`) или расширение без узла cmark
    /// (`==`, `^`). `<br>` внутри такого узла для cmark остаётся на верхнем уровне ячейки.
    /// Шире `MarkdownInlineNode.hasHTMLTagMarker(in:)`: тот отвечает только за `.strong/.emphasis/.strikethrough`.
    private static func isHTMLPair(_ node: MarkdownInlineNode, in text: NSString) -> Bool {
        switch node.kind {
        case .underline, .highlight, .superscriptText, .keyboard, .inlineStyle: return true
        case .link(let link): return link.form == .html
        case .strong, .emphasis, .strikethrough, .subscriptText:
            return node.hasHTMLTagMarker(in: text)
        default: return false
        }
    }

    /// `displayText` и `displayRuns` ячейки по её строчным узлам. `cellRange` — ячейка в `text`, от неё считаются местные диапазоны.
    /// `confirmsHTML == false`: парные теги `<kbd>`, `<span style>` и `<img>` не подтверждены (разбор строки без документа).
    static func renderedCell(inlines: [MarkdownInlineNode], cellRange: NSRange, text: NSString, emojiCandidates: [MarkdownEmojiCandidate],
                             confirmsHTML: Bool, syntax: MarkdownSyntaxOptions, isCancelled: @escaping () -> Bool) -> (String, [MarkdownTableTextRun]) {
        let output = NSMutableString(string: "")
        var runs: [MarkdownTableTextRun] = []
        var invalidKeyboard = false
        var invalidInlineStyle = false
        var previousSpace = false
        let preservesWhitespace = syntax.preserveEditingWhitespace ?? false

        func inside(_ range: NSRange) -> Bool {
            range.location >= cellRange.location && NSMaxRange(range) <= NSMaxRange(cellRange)
        }
        func local(_ range: NSRange) -> NSRange {
            NSRange(location: range.location - cellRange.location, length: range.length)
        }
        func hasEmoji(at range: NSRange) -> Bool {
            var low = 0, high = emojiCandidates.count
            while low < high {
                let middle = (low + high) / 2
                if emojiCandidates[middle].range.location < range.location { low = middle + 1 } else { high = middle }
            }
            while low < emojiCandidates.count, emojiCandidates[low].range.location == range.location {
                if emojiCandidates[low].range == range { return true }
                low += 1
            }
            return false
        }
        /// Вид с оформлением, если Markdown-разметка; у тегов HTML (`<b>`, `<sub>`) оформления в ячейке нет.
        func decoration(_ node: MarkdownInlineNode) -> MarkdownPresentationKind? {
            if isHTMLPair(node, in: text) { return nil }
            switch node.kind {
            case .strong: return .strong
            case .emphasis: return .emphasis
            case .strikethrough, .subscriptText: return .strikethrough
            default: return nil
            }
        }
        func visit(_ nodes: [MarkdownInlineNode], flat: Bool) {
            for node in nodes {
                if isCancelled() { return }
                let start = output.length
                switch node.kind {
                case .text(let value):
                    let raw = value as NSString
                    let pieces = trustedRange(node, in: text).flatMap {
                        MarkdownInlineTextProjection.pieces(spelling: text.substring(with: $0) as NSString, literal: value,
                                                            sourceOffset: $0.location, isCancelled: isCancelled)
                    }
                    if !preservesWhitespace, pieces != nil {
                        var runStart = 0
                        for index in 0..<raw.length {
                            let unit = raw.character(at: index)
                            let space = unit == 32 || unit == 9
                            if space && (previousSpace || unit == 9) {
                                if index > runStart { output.append(raw.substring(with: NSRange(location: runStart, length: index - runStart))) }
                                if !previousSpace { output.append(" ") }
                                runStart = index + 1
                            }
                            previousSpace = space
                        }
                        if raw.length > runStart { output.append(raw.substring(with: NSRange(location: runStart, length: raw.length - runStart))) }
                    } else {
                        output.append(value)
                        previousSpace = false
                    }
                case .code(let value):
                    output.append(value)
                    previousSpace = false
                    if output.length > start { runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .code)) }
                case .emoji:
                    previousSpace = false
                    guard let range = trustedRange(node, in: text) else { continue }
                    output.append(text.substring(with: range))
                    if inside(range), hasEmoji(at: range) {
                        runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .tableEmoji(local(range))))
                    }
                case .softBreak, .hardBreak:
                    previousSpace = false
                    output.append("\n")
                case .image(let image):
                    previousSpace = false
                    // `<img>` подтверждён, только если документ признал его картинкой с размерами.
                    if image.syntax == .html && !(confirmsHTML && image.sizing != nil) { continue }
                    guard let range = trustedRange(node, in: text), inside(range) else {
                        if image.syntax != .html { output.append(image.alt) }
                        continue
                    }
                    if image.syntax != .html, range.length < 4 || text.substring(with: NSRange(location: range.location, length: 2)) != "![" {
                        output.append(image.alt)
                        continue
                    }
                    output.append(text.substring(with: range))
                    runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .tableImage(local(range))))
                case .formula(let source):
                    previousSpace = false
                    output.append("$" + source + "$")
                    if let range = trustedRange(node, in: text), inside(range) {
                        runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .tableMath(local(range))))
                    }
                case .rawHTML(let literal):
                    let tag = literal.lowercased()
                    if tag.hasPrefix("<kbd") || tag.hasPrefix("</kbd") { invalidKeyboard = true }
                    if MarkdownDocumentParser.isSpanOpening(tag) && MarkdownHTMLMediaService.hasStyledSpan(in: literal, isCancelled: isCancelled) { invalidInlineStyle = true }
                    if flat, let range = trustedRange(node, in: text), isBreakTag(literal, text.substring(with: range)) {
                        previousSpace = false
                        output.append("\n")
                    }
                case .keyboard:
                    visit(node.children, flat: flat)
                    if !confirmsHTML { invalidKeyboard = true }
                    else if output.length > start { runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .keyboard)) }
                case .inlineStyle(let style):
                    visit(node.children, flat: flat)
                    guard confirmsHTML, let range = trustedRange(node, in: text), inside(range) else { invalidInlineStyle = true; continue }
                    if output.length > start {
                        runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .inlineStyle(style),
                                                         sourceRange: local(range)))
                    }
                case .strong, .emphasis, .strikethrough, .subscriptText, .underline, .highlight, .superscriptText:
                    visit(node.children, flat: flat && isHTMLPair(node, in: text))
                    if let kind = decoration(node), output.length > start {
                        runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: kind))
                    }
                case .link(let link):
                    visit(node.children, flat: flat && link.form == .html)
                    if link.form != .html, output.length > start {
                        var relative: NSRange?
                        if let range = trustedRange(node, in: text), inside(range) { relative = local(range) }
                        runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .link, sourceRange: relative))
                    }
                case .footnoteReference:
                    previousSpace = false
                case .ruby(let ruby):
                    previousSpace = false
                    output.append(ruby.base + (ruby.openingParenthesis ?? "") + ruby.reading + (ruby.closingParenthesis ?? ""))
                case .media, .iframe, .svg:
                    break
                case .wikiLink, .noteEmbed, .critic, .comment:
                    previousSpace = false
                    if let range = trustedRange(node, in: text) { output.append(text.substring(with: range)) }
                }
            }
        }
        visit(inlines, flat: true)
        if invalidKeyboard || invalidInlineStyle { return (text.substring(with: cellRange), []) }
        return (output as String, runs)
    }
}
