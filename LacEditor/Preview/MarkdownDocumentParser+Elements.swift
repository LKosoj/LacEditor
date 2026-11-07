import Foundation

/// Индекс элементов модели (U2.5c, `Includes.elementIndex`): проход по узлам модели, а не по дереву cmark.
/// Правила: блоки — целые строки, внутри таблиц и определений сносок
/// записей нет (кроме формул), строчные записи только у узлов с подтверждённой позицией. Строчные теги `<b>`, `<em>`, `<s>`, `<a>`
/// модель хранит как `rawHTML`, их пары берутся из подтверждения HTML (`HTMLConfirmation.pairs`).
extension MarkdownDocumentParser {
    /// `nil` — разбор отменён.
    static func elementIndex(of model: MarkdownDocumentModel, text: NSString, htmlPairs: [InlineHTMLPair],
                             isCancelled: () -> Bool) -> MarkdownElementIndex? {
        var blocks: [(NSRange, MarkdownElement.Kind)] = [], inlines: [(NSRange, MarkdownElement.Kind)] = []
        let length = text.length
        if let front = model.frontMatter {
            // Закрывающий разделитель стоит без перевода строки: диапазон продлевается до конца строки.
            var end = NSMaxRange(front.range)
            if end < length && text.character(at: end) == 13 { end += 1 }
            if end < length && text.character(at: end) == 10 { end += 1 }
            blocks.append((NSRange(location: front.range.location, length: end - front.range.location), .frontMatter))
        }

        /// Диапазон, расширенный до границ строк вместе с переводом строки в конце (`MarkdownSourcePositions.wholeLines`).
        func wholeLines(_ range: NSRange) -> NSRange? {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= length else { return nil }
            var start = range.location, end = NSMaxRange(range)
            while start > 0, text.character(at: start - 1) != 10, text.character(at: start - 1) != 13 { start -= 1 }
            while end < length, text.character(at: end) != 10, text.character(at: end) != 13 { end += 1 }
            if end < length {
                let newline = text.character(at: end)
                end += 1
                if newline == 13, end < length, text.character(at: end) == 10 { end += 1 }
            }
            return NSRange(location: start, length: end - start)
        }

        // Неподтверждённые теги: оформление (strong, ссылки, код, формулы) внутри них отбрасывается (wiki-ссылки тоже: убираются их текстовые места); картинки и сноски нет.
        var blockedRanges: [NSRange] = []
        for range in model.blockedHTML.sorted(by: { $0.location < $1.location }) {
            if let last = blockedRanges.last, range.location <= NSMaxRange(last) { blockedRanges[blockedRanges.count - 1] = NSUnionRange(last, range) }
            else { blockedRanges.append(range) }
        }
        func isBlocked(_ range: NSRange) -> Bool {
            var low = 0, high = blockedRanges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(blockedRanges[middle]) <= range.location { low = middle + 1 } else { high = middle }
            }
            return low < blockedRanges.count && blockedRanges[low].location < NSMaxRange(range)
        }
        func addStyled(_ range: NSRange, _ kind: MarkdownElement.Kind) {
            if !isBlocked(range) { inlines.append((range, kind)) }
        }

        /// Пары `<b>…</b>` записываются ниже по `htmlPairs`, в обход узлов, чтобы не задваивать.
        func isHTMLPair(_ node: MarkdownInlineNode) -> Bool {
            switch node.kind { case .strong, .emphasis, .strikethrough: break; default: return false }
            return node.hasHTMLTagMarker(in: text)
        }

        /// `formulasOnly` — внутри таблиц и определений сносок: формулы записываются, остальное нет.
        func visit(_ nodes: [MarkdownInlineNode], formulasOnly: Bool = false) {
            for node in nodes {
                if formulasOnly {
                    if case .formula = node.kind, !node.isUnreliable { addStyled(node.range, .formula) }
                } else if !node.isUnreliable, !isHTMLPair(node) {
                    switch node.kind {
                    case .strong: addStyled(node.range, .strong)
                    case .emphasis: addStyled(node.range, .emphasis)
                    case .strikethrough: addStyled(node.range, .strikethrough)
                    case .code: addStyled(node.range, .code)
                    case .link(let link) where link.form != .html: addStyled(node.range, .link)
                    case .wikiLink: addStyled(node.range, .link)
                    case .image(let image) where image.syntax != .html: inlines.append((node.range, .image))
                    case .formula: addStyled(node.range, .formula)
                    case .footnoteReference: inlines.append((node.range, .footnoteReference))
                    default: break
                    }
                }
                visit(node.children, formulasOnly: formulasOnly)
            }
        }

        func visit(_ nodes: [MarkdownBlockNode], formulasOnly: Bool = false) {
            for block in nodes {
                var element: MarkdownElement.Kind?
                var inside = true
                switch block.kind {
                case .heading(let heading): element = .heading(heading.level)
                case .quote, .callout: element = .quote
                case .alert: element = .alert
                case .listItem(let item): element = item.task == nil ? .listItem : .task
                case .table: element = .table; inside = false
                case .html: element = .htmlBlock
                case .codeBlock(let code): element = .codeBlock(code.info.split(whereSeparator: \.isWhitespace).first.map(String.init))
                case .mathBlock: element = .mathBlock
                case .footnoteDefinition: element = .footnoteDefinition; inside = false
                default: break
                }
                // Диапазон неподтверждённого блока взят по строкам cmark.
                if !formulasOnly, let element, let lines = wholeLines(block.range) { blocks.append((lines, element)) }
                let only = formulasOnly || !inside
                visit(block.inlines, formulasOnly: only)
                visit(block.children, formulasOnly: only)
                if case let .table(table) = block.kind {
                    for row in table.rows { for cell in row.cells { visit(cell.inlines, formulasOnly: true) } }
                }
            }
        }
        visit(model.blocks)
        for pair in htmlPairs {
            switch pair.kind {
            case .strong: addStyled(NSUnionRange(pair.openingRange, pair.closingRange), .strong)
            case .emphasis: addStyled(NSUnionRange(pair.openingRange, pair.closingRange), .emphasis)
            case .strikethrough: addStyled(NSUnionRange(pair.openingRange, pair.closingRange), .strikethrough)
            case .link: addStyled(NSUnionRange(pair.openingRange, pair.closingRange), .link)
            default: break
            }
        }
        if isCancelled() { return nil }
        let lastUnit = length > 0 ? text.character(at: length - 1) : 0
        return MarkdownElementIndex(textLength: length, blocks: blocks, inlines: inlines, endsWithLineBreak: lastUnit == 0x0A || lastUnit == 0x0D)
    }
}
