import Foundation
import cmark_gfm

/// Контекст ограждений ядра (U2.5d): куда нельзя ставить ограждение кода и какие префиксы цитат и пунктов нужны на строках.
/// Считается проходом по узлам модели (диапазоны, `isUnreliable`, `CodeBlock.isClosed`).
extension MarkdownDocumentParser {
    /// `nil` — разбор отменён. `text` — исходный текст (до маски), позиции модели — его UTF-16.
    static func fence(of model: MarkdownDocumentModel, text: NSString, isCancelled: @escaping () -> Bool) -> MarkdownDocumentModel.FenceContext? {
        var pass = FencePass(text: text, isCancelled: isCancelled)
        if let front = model.frontMatter { pass.blocked.append(front.range) }
        pass.visit(model.blocks, stack: [], topLevel: true)
        if pass.cancelled || isCancelled() { return nil }
        return MarkdownDocumentModel.FenceContext(
            containerLines: pass.lines.sorted { $0.line.location < $1.line.location },
            blockedRanges: MarkdownDocumentExtras.mergedBlockedRanges(pass.blocked),
            blockedEOF: pass.blockedEOF, isAvailable: pass.available)
    }

    private struct FencePass {
        /// Контейнер на пути к блоку; у пункта хранится сам узел (для колонки продолжения).
        struct Container {
            var ancestor: MarkdownDocumentExtras.FenceAncestor
            var item: MarkdownBlockNode?
        }

        let text: NSString
        let isCancelled: () -> Bool
        var cancelled = false
        var lines: [MarkdownFenceContainerLine] = []
        var blocked: [NSRange] = []
        var blockedEOF = false
        var available = true
        var itemColumns: [Int: (Int, String)?] = [:]

        init(text: NSString, isCancelled: @escaping () -> Bool) {
            self.text = text
            self.isCancelled = isCancelled
        }

        // MARK: Обход

        mutating func visit(_ blocks: [MarkdownBlockNode], stack: [Container], topLevel: Bool) {
            for block in blocks {
                if cancelled { return }
                if isCancelled() { cancelled = true; return }
                collect(block, topLevel: topLevel)
                switch block.kind {
                case .quote, .callout, .alert:
                    let inner = stack + [Container(ancestor: .init(kind: .quote, firstPosition: nil), item: nil)]
                    if case .quote = block.kind, block.children.isEmpty { emptyContainer(block, stack: inner) }
                    // Первая строка выноски `> [!тип] заголовок` — начало текстового узла cmark, заголовок модели идёт после маркера: берём маркер.
                    if case let .callout(callout) = block.kind { addTextLine(at: callout.markerRange.location, stack: inner) }
                    textLines(block.inlines, stack: inner, prefixes: block.containerPrefixes)
                    visit(block.children, stack: inner, topLevel: false)
                case .list:
                    visit(block.children, stack: stack + [Container(ancestor: .init(kind: .list, firstPosition: nil), item: nil)],
                          topLevel: false)
                case .listItem:
                    let inner = stack + [Container(ancestor: .init(kind: .item, firstPosition: block.markerRanges.first?.location ?? block.range.location),
                                                   item: block)]
                    if block.children.isEmpty { emptyContainer(block, stack: inner) }
                    visit(block.children, stack: inner, topLevel: false)
                case .paragraph:
                    textLines(block.inlines, stack: stack, prefixes: block.containerPrefixes)
                default:
                    break
                }
            }
        }

        // MARK: Заблокированные диапазоны

        /// Целые строки блоков, куда ограждение вставлять нельзя.
        mutating func collect(_ block: MarkdownBlockNode, topLevel: Bool) {
            var closedFence = false, openFenceWithoutBody = false
            switch block.kind {
            case .codeBlock(let code):
                closedFence = code.isFenced && code.isClosed && !block.isUnreliable
                openFenceWithoutBody = topLevel && code.isFenced && !code.isClosed && !block.isUnreliable && code.infoRange != nil && code.bodySegments.isEmpty
            case .mathBlock, .html, .quote, .callout, .alert, .list, .table, .footnoteDefinition:
                break
            default:
                return
            }
            // Строки узла cmark не нашлись: только у кода, у него тогда пустой диапазон. У остальных блоков запасной диапазон
            // (строки или объемлющий блок) от настоящего не отличить, а строки блока почти всегда известны.
            var lost = false
            if case .codeBlock = block.kind { lost = block.isUnreliable && block.range.length == 0 }
            if openFenceWithoutBody, let all = wholeLines(block.range, skipFirst: false), NSMaxRange(all) == text.length { blockedEOF = true }
            if !lost, let lines = wholeLines(block.range, skipFirst: openFenceWithoutBody) {
                blocked.append(lines)
                if NSMaxRange(lines) == text.length && !closedFence { blockedEOF = true }
            } else if !openFenceWithoutBody {
                available = false
            }
        }

        /// Целые строки диапазона вместе с переводом строки в конце; `skipFirst` отбрасывает первую строку (`nil`, если тела нет).
        func wholeLines(_ range: NSRange, skipFirst: Bool) -> NSRange? {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= text.length else { return nil }
            func isBreak(_ index: Int) -> Bool { let unit = text.character(at: index); return unit == 10 || unit == 13 }
            var start = range.location, end = NSMaxRange(range)
            while end > start && isBreak(end - 1) { end -= 1 }
            while start > 0 && !isBreak(start - 1) { start -= 1 }
            while end < text.length && !isBreak(end) { end += 1 }
            if end < text.length {
                let unit = text.character(at: end)
                end += 1
                if unit == 13 && end < text.length && text.character(at: end) == 10 { end += 1 }
            }
            if skipFirst {
                while start < end && !isBreak(start) { start += 1 }
                guard start < end else { return nil }
                let unit = text.character(at: start)
                start += 1
                if unit == 13 && start < end && text.character(at: start) == 10 { start += 1 }
                guard start < end else { return nil }
            }
            return NSRange(location: start, length: end - start)
        }

        // MARK: Строки с префиксом контейнера

        /// Пустая цитата или пункт на одной строке с пробелом в конце: туда можно вписать ограждение после префикса.
        mutating func emptyContainer(_ block: MarkdownBlockNode, stack: [Container]) {
            let start = block.markerRanges.first?.location ?? block.range.location
            guard start >= 0, start < text.length,
                  !text.substring(with: block.range).contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return }
            let line = text.lineRange(for: NSRange(location: start, length: 0))
            var end = NSMaxRange(line)
            while end > line.location && (text.character(at: end - 1) == 10 || text.character(at: end - 1) == 13) { end -= 1 }
            guard end > line.location, text.character(at: end - 1) == 32 || text.character(at: end - 1) == 9,
                  let prefix = prefix(stack, position: end), prefix.nested, simpleEmptyFencePrefix(prefix.source) else { return }
            lines.append(MarkdownFenceContainerLine(line: prefix.line, sourcePrefix: prefix.source, continuationPrefix: prefix.continuation))
        }

        /// Строка абзаца, которая начинается с текста: префикс контейнера подтверждён (по прямым текстовым детям).
        mutating func textLines(_ inlines: [MarkdownInlineNode], stack: [Container], prefixes: [MarkdownBlockNode.ContainerPrefix]) {
            guard !stack.isEmpty else { return }
            for node in inlines where !node.isUnreliable && node.range.length > 0 && NSMaxRange(node.range) <= text.length {
                switch node.kind {
                case .text(let value):
                    guard text.substring(with: node.range) == value else { continue }
                case .emoji, .wikiLink, .noteEmbed, .highlight, .superscriptText, .critic, .comment:
                    // Эти узлы ядро режет из текстового узла cmark: до них стоял тот же текст.
                    break
                default:
                    continue
                }
                addTextLine(at: node.range.location, stack: stack)
            }
            // Позицию текста на строке с табом ядро не подтверждает (`isUnreliable`); берётся `tabbedLiteralTextRange`.
            // Узлы абзаца между переводами строки — одна строка, k-я группа относится к k-му префиксу. Если групп не столько, сколько
            // префиксов (ленивые строки и т. п.), запасной путь не применяется. Строка без текста в начале или с недословным значением
            // (сущность, экранирование) записи не получает, остальные строки это не затрагивает.
            var groups: [[MarkdownInlineNode]] = [[]]
            for node in inlines {
                switch node.kind {
                case .softBreak, .hardBreak: groups.append([])
                default: groups[groups.count - 1].append(node)
                }
            }
            guard groups.count == prefixes.count else { return }
            let added = Set(lines.map(\.line.location))
            for (group, prefix) in zip(groups, prefixes) where !added.contains(prefix.line.location) {
                guard let node = group.first, node.isUnreliable, case .text(let value) = node.kind, let first = value.first,
                      !first.isWhitespace, !value.contains("\t") else { continue }
                let literal = value as NSString
                let end = NSMaxRange(prefix.line)
                // Текст должен стоять сразу после префикса строки. `prefixLength` на строке с табом не подтверждён, поэтому границы
                // перебираются в ведущей полосе символов префикса (начало текста тоже может быть цифрой или `-`): берётся первая,
                // где совпал литерал и префикс до неё принят `fencePrefix`.
                var band = prefix.line.location
                while band < end, [32, 9, 62, 45, 43, 42, 46, 41].contains(text.character(at: band)) || (48...57).contains(text.character(at: band)) { band += 1 }
                var start = prefix.line.location
                while start <= band {
                    if matches(literal, at: start, end: end) {
                        let before = lines.count
                        addTextLine(at: start, stack: stack)
                        if lines.count > before { break }
                    }
                    start += 1
                }
            }
        }

        /// Совпадение литерала с текстом в позиции без выделения временных строк.
        func matches(_ value: NSString, at start: Int, end: Int) -> Bool {
            guard start + value.length <= end else { return false }
            for offset in 0..<value.length where text.character(at: start + offset) != value.character(at: offset) { return false }
            return true
        }

        mutating func addTextLine(at position: Int, stack: [Container]) {
            guard let prefix = prefix(stack, position: position), prefix.nested, !prefix.source.isEmpty else { return }
            lines.append(MarkdownFenceContainerLine(line: prefix.line, sourcePrefix: prefix.source, continuationPrefix: prefix.continuation))
        }

        mutating func prefix(_ stack: [Container], position: Int) -> (line: NSRange, source: String, continuation: String, nested: Bool)? {
            let chain = Array(stack.reversed())
            var columns: [Int: (Int, String)?] = itemColumns
            let result = MarkdownDocumentExtras.fencePrefix(
                ancestors: chain.map(\.ancestor), text: text, position: position, allowEarlierItem: false,
                itemStartColumn: { index in
                    guard let item = chain[index].item, let key = chain[index].ancestor.firstPosition else { return nil }
                    if let known = columns[key] { return known }
                    let value = itemStartColumn(item)
                    columns[key] = .some(value)
                    return value
                })
            itemColumns = columns
            return result
        }

        /// Колонка, с которой начинается содержимое пункта, и префикс цитаты на его первой строке.
        func itemStartColumn(_ item: MarkdownBlockNode) -> (Int, String)? {
            guard let marker = item.markerRanges.first?.location, case let .listItem(data) = item.kind,
                  let paragraph = item.children.first, case .paragraph = paragraph.kind, let first = paragraph.inlines.first,
                  !first.isUnreliable, first.range.length > 0, NSMaxRange(first.range) <= text.length else { return nil }
            switch first.kind {
            case .text(let value): guard text.substring(with: first.range) == value else { return nil }
            case .emoji, .wikiLink, .noteEmbed, .highlight, .superscriptText, .critic, .comment: break
            default: return nil
            }
            guard marker >= 0, marker <= text.length else { return nil }
            let firstLine = text.lineRange(for: NSRange(location: marker, length: 0))
            guard first.range.location >= marker, first.range.location < NSMaxRange(firstLine) else { return nil }
            // Отметка задачи входит в содержимое пункта: колонка продолжения считается от «[».
            var contentStart = first.range.location
            if let checkbox = data.task, checkbox.markerRange.location >= marker, checkbox.markerRange.location < first.range.location {
                contentStart = checkbox.markerRange.location
            }
            let initial = Array(text.substring(with: NSRange(location: firstLine.location, length: contentStart - firstLine.location)).utf16)
            guard initial.allSatisfy({ $0 < 128 }) else { return nil }
            let column = initial.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
            var quoteEnd = initial.lastIndex(of: 62).map { $0 + 1 } ?? 0
            if quoteEnd > 0 && quoteEnd < initial.count && (initial[quoteEnd] == 32 || initial[quoteEnd] == 9) { quoteEnd += 1 }
            return (column, String(decoding: initial[..<quoteEnd], as: UTF16.self))
        }
    }
}

// MARK: - Префиксы контейнеров
extension MarkdownDocumentParser {
    static func fencePrefixes(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString,
                                      position: Int, allowEarlierItem: Bool = true, includeNode: Bool = false,
                                      itemStartColumn: ((OpaquePointer) -> (Int, String)?)? = nil) -> (line: NSRange, source: String, continuation: String, nested: Bool)? {
        // Предки от ближайшего к внешнему; сама проверка префикса общая с ядром модели (`MarkdownDocumentExtras.fencePrefix`).
        var chain: [OpaquePointer] = [], ancestors: [MarkdownDocumentExtras.FenceAncestor] = []
        var ancestor = includeNode ? node : cmark_node_parent(node)
        while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
            let type = cmark_node_get_type(current)
            if type == CMARK_NODE_BLOCK_QUOTE { ancestors.append(.init(kind: .quote, firstPosition: nil)) }
            else if type == CMARK_NODE_LIST { ancestors.append(.init(kind: .list, firstPosition: nil)) }
            else if type == CMARK_NODE_ITEM { ancestors.append(.init(kind: .item, firstPosition: source.firstPosition(current))) }
            else { return nil }
            chain.append(current)
            ancestor = cmark_node_parent(current)
        }
        guard ancestor != nil else { return nil }
        return MarkdownDocumentExtras.fencePrefix(ancestors: ancestors, text: text, position: position, allowEarlierItem: allowEarlierItem,
                                                  itemStartColumn: { index in itemStartColumn?(chain[index]) })
    }

    static func simpleEmptyFencePrefix(_ source: String) -> Bool {
        let units = Array(source.utf16)
        var position = 0, column = 0, quoteBaseline = 0, quotes = 0
        func advance(_ unit: UInt16) { column = unit == 9 ? (column / 4 + 1) * 4 : column + 1 }
        while position < units.count && units[position] == 62 {
            advance(units[position]); position += 1; quotes += 1
            quoteBaseline = column
            if position < units.count && (units[position] == 32 || units[position] == 9) {
                quoteBaseline += 1
                advance(units[position]); position += 1
            }
        }
        while position < units.count && (units[position] == 32 || units[position] == 9) {
            advance(units[position]); position += 1
        }
        let indent = column - (quotes > 0 ? quoteBaseline : 0)
        guard indent <= 3 else { return false }
        if position == units.count { return quotes > 0 }
        let start = position
        if [42, 43, 45].contains(units[position]) { advance(units[position]); position += 1 }
        else {
            while position < units.count && (48...57).contains(units[position]) { advance(units[position]); position += 1 }
            guard position > start, position - start <= 9, position < units.count,
                  units[position] == 46 || units[position] == 41 else { return false }
            advance(units[position]); position += 1
        }
        let markerEnd = column
        while position < units.count && (units[position] == 32 || units[position] == 9) {
            advance(units[position]); position += 1
        }
        return position == units.count && (1...4).contains(column - markerEnd)
    }
}
