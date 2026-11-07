import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Строчные узлы ядра (U2.3b), которые строятся по тексту: wiki-ссылки и `![[…]]`, эмодзи, подсветка `==`,
/// верхний `^x^` и нижний `~x~` индексы, а также правки CriticMarkup и строчные комментарии `%%` из сегментов маски.
/// Всё работает над списком соседних узлов одного родителя (`refineInlines`), HTML-зависимые виды здесь не трогаются.
extension MarkdownDocumentParser {
    // MARK: - Общее состояние

    /// Данные, общие на весь разбор: сегменты маски, быстрые признаки текста, состояние сырого HTML.
    final class InlineState {
        let segments: [MarkdownSourceMask.Segment]
        /// `maxEnds[i]` — наибольший конец среди `segments[0...i]`: по нему находим первый сегмент, достающий до окна.
        private let maxEnds: [Int]
        let hasWikiBrackets: Bool
        let hasEmbedMarker: Bool
        let hasColon: Bool
        let hasDecorationMarks: Bool
        var mayRefineText: Bool { hasWikiBrackets || hasEmbedMarker || hasColon || hasDecorationMarks }
        /// Контекст сырого HTML (`<script>`, `<style>`, `<textarea>`) в порядке разбора: внутри него wiki и эмодзи не ищутся.
        var htmlContext = MarkdownImageUploadService.HTMLContext()
        /// Больше нуля, пока разбираются дети слитой пары HTML (`kbd`, `u`, `mark`…): правки в них принадлежат внешнему списку.
        var pairDepth = 0
        private var embedCache: [MarkdownNoteEmbedItem]?
        private var confirmedHTML: Set<OpaquePointer>?
        private var suppressedParents: [OpaquePointer: Bool] = [:]

        init(mask: MarkdownSourceMask.Result, masked: NSString, options: MarkdownDocumentModel.Options) {
            // Целые строки `%%` без абзаца стали блоками и залиты пробелами: в строчных узлах их нет.
            let inline = mask.segments.filter { segment in
                switch segment.kind {
                case .frontMatter: return false
                case .comment: return !segment.occupiesWholeLines || segment.keepsParagraph
                case .critic: return true
                }
            }
            segments = inline
            var ends: [Int] = []
            var current = 0
            for segment in inline { current = max(current, NSMaxRange(segment.range)); ends.append(current) }
            maxEnds = ends
            let includes = options.includes
            func has(_ token: String) -> Bool { masked.range(of: token, options: .literal).location != NSNotFound }
            hasWikiBrackets = includes.contains(.wikiLinks) && has("[[")
            hasEmbedMarker = includes.contains(.noteEmbeds) && has("![[")
            hasColon = includes.contains(.emoji) && has(":")
            hasDecorationMarks = has("==") || has("^")
        }

        /// Сегменты, пересекающие окно, по порядку в тексте.
        func segments(intersecting window: NSRange) -> [MarkdownSourceMask.Segment] {
            guard !segments.isEmpty, window.length > 0 else { return [] }
            var low = 0, high = maxEnds.count
            while low < high {
                let middle = (low + high) / 2
                if maxEnds[middle] <= window.location { low = middle + 1 } else { high = middle }
            }
            var result: [MarkdownSourceMask.Segment] = []
            var index = low
            while index < segments.count, segments[index].range.location < NSMaxRange(window) {
                if NSMaxRange(segments[index].range) > window.location { result.append(segments[index]) }
                index += 1
            }
            return result
        }

        /// `![[…]]` по всему тексту, как в рендере (`MarkdownNoteEmbed.items`); начало внутри кода или таблицы отсекает сама привязка к текстовому узлу.
        func embeds(intersecting window: NSRange, in text: NSString) -> [MarkdownNoteEmbedItem] {
            let all: [MarkdownNoteEmbedItem]
            if let embedCache { all = embedCache } else {
                all = MarkdownNoteEmbed.items(in: text, excluded: [])
                embedCache = all
            }
            var low = 0, high = all.count
            while low < high {
                let middle = (low + high) / 2
                if all[middle].range.location < window.location { low = middle + 1 } else { high = middle }
            }
            var result: [MarkdownNoteEmbedItem] = []
            while low < all.count, all[low].range.location < NSMaxRange(window) { result.append(all[low]); low += 1 }
            return result
        }

        /// Правило `MarkdownEmojiCandidateExtractor` и рендера: если среди html_inline у узла или его предков есть тег, не подтверждённый
        /// как пара `<u>` или `<a>`, весь текст под ним не ищется.
        func isSuppressedByHTML(_ parent: OpaquePointer?, html: HTMLConfirmation?) -> Bool {
            var current = parent
            while let node = current {
                if let known = suppressedParents[node] { if known { return true } } else {
                    var found = false
                    var child = cmark_node_first_child(node)
                    while let item = child, !found {
                        if cmark_node_get_type(item) == CMARK_NODE_HTML_INLINE {
                            if confirmedHTML == nil {
                                var set = Set<OpaquePointer>()
                                for pair in html?.pairs.values ?? [:].values where pair.kind == .underline || pair.kind == .link {
                                    set.insert(pair.opening); set.insert(pair.closing)
                                }
                                confirmedHTML = set
                            }
                            if !(confirmedHTML?.contains(item) ?? false) { found = true }
                        }
                        child = cmark_node_next(item)
                    }
                    suppressedParents[node] = found
                    if found { return true }
                }
                current = cmark_node_parent(node)
            }
            return false
        }
    }

    // MARK: - Вход

    /// Дорабатывает список соседей одного родителя: wiki-ссылки, встраивания, подсветка, индексы, эмодзи, затем правки и комментарии.
    /// `nodes` — узлы cmark, из которых получены `items` (по порядку, один к одному).
    static func refineInlines(_ items: [MarkdownInlineNode], nodes: [OpaquePointer], container: NSRange, ctx: Context) -> [MarkdownInlineNode] {
        guard !items.isEmpty, items.count == nodes.count, !ctx.stop() else { return items }
        let state = ctx.inlineState
        guard state.mayRefineText || !state.segments.isEmpty || !ctx.mask.isIdentity else { return items }
        let parent = cmark_node_parent(nodes[0])
        var result = items
        if state.mayRefineText { result = decorate(result, nodes: nodes, parent: parent, container: container, ctx: ctx) }
        if !state.segments.isEmpty { result = cut(result, container: container, nested: isInlineContainer(parent) || state.pairDepth > 0, ctx: ctx) }
        if !ctx.mask.isIdentity { result = result.map { scrub($0, ctx: ctx) } }
        return result
    }

    private static func isInlineContainer(_ node: OpaquePointer?) -> Bool {
        guard let node else { return false }
        let type = cmark_node_get_type(node)
        if type == CMARK_NODE_EMPH || type == CMARK_NODE_STRONG || type == CMARK_NODE_LINK || type == CMARK_NODE_IMAGE { return true }
        return cmark_node_get_type_string(node).map { String(cString: $0) == "strikethrough" } ?? false
    }

    /// Убирает заменители маски из текстов, которые остались целиком вне сегментов (и в детях узлов, созданных здесь).
    private static func scrub(_ node: MarkdownInlineNode, ctx: Context) -> MarkdownInlineNode {
        var node = node
        switch node.kind {
        case .text(let value) where value.contains(ctx.placeholder):
            node.kind = .text(ctx.clean(value))
        case .critic, .highlight, .superscriptText:
            node.children = node.children.map { scrub($0, ctx: ctx) }
        default: break
        }
        return node
    }

    // MARK: - Предки

    private struct Ancestry {
        var inLink = false, inImage = false, inTable = false, inHeading = false
        var inFootnoteDefinition = false, inStrikethrough = false, inCodeBlock = false
        var isAutolink = false

        init(parent: OpaquePointer?, container: NSRange, ctx: Context) {
            var current = parent
            var first = true
            while let node = current {
                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_LINK {
                    inLink = true
                    // У автоссылки `<…>` и голого адреса в тексте нет `[`: эмодзи в ней не ищем (как `MarkdownEmojiCandidateExtractor`).
                    if first, container.location < ctx.source.units.count, ctx.source.units[container.location] != 91 { isAutolink = true }
                }
                else if type == CMARK_NODE_IMAGE { inImage = true }
                else if type == CMARK_NODE_HEADING { inHeading = true }
                else if type == CMARK_NODE_FOOTNOTE_DEFINITION { inFootnoteDefinition = true }
                else if type == CMARK_NODE_CODE_BLOCK { inCodeBlock = true }
                else if let name = cmark_node_get_type_string(node).map({ String(cString: $0) }) {
                    if name == "table" { inTable = true } else if name == "strikethrough" { inStrikethrough = true }
                }
                first = false
                current = cmark_node_parent(node)
            }
        }

        /// В этих местах подсветка и верхний индекс не ищутся.
        var excludesDecorations: Bool { inFootnoteDefinition || inLink || inImage || inTable || inCodeBlock || inStrikethrough }
        /// Wiki-ссылки не ищутся в ссылках, картинках, таблицах и заголовках.
        var excludesWiki: Bool { inLink || inImage || inTable || inHeading }
    }

    // MARK: - Текстовые узлы

    private typealias Piece = MarkdownReadableText.Piece

    private static func pieces(of node: MarkdownInlineNode, value: String, ctx: Context) -> [Piece]? {
        let range = node.range
        guard !node.isUnreliable, range.location >= 0, NSMaxRange(range) <= ctx.masked.length else { return nil }
        return MarkdownInlineTextProjection.pieces(spelling: ctx.masked.substring(with: range) as NSString, literal: value,
                                                   sourceOffset: range.location, isCancelled: ctx.isCancelled)
    }

    private static func textNode(_ value: String, _ range: NSRange) -> MarkdownInlineNode {
        MarkdownInlineNode(kind: .text(value), range: range, markerRanges: [], children: [], isUnreliable: false)
    }

    /// Часть текстового узла по диапазону исходника. Кусок не режет «умные» замены и сущности: берутся куски, начало которых внутри диапазона.
    private static func sliceText(_ node: MarkdownInlineNode, _ sub: NSRange, pieces: [Piece]?, ctx: Context) -> MarkdownInlineNode? {
        guard case .text(let value) = node.kind else { return nil }
        let sub = NSIntersectionRange(sub, node.range)
        guard sub.length > 0 else { return nil }
        if sub == node.range { return node }
        if let pieces {
            // Кусок совпадения с исходником режется ровно по границам диапазона; «умная» замена и сущность неделимы: берутся по началу.
            var text = "", start: Int?, end = 0
            for piece in pieces {
                let source = piece.sourceRange
                let part: String
                let covered: NSRange
                if piece.matchesSource {
                    covered = NSIntersectionRange(source, sub)
                    guard covered.length > 0 else { continue }
                    part = (piece.text as NSString).substring(with: NSRange(location: covered.location - source.location, length: covered.length))
                } else {
                    guard source.location >= sub.location, source.location < NSMaxRange(sub) else { continue }
                    covered = source
                    part = piece.text
                }
                if start == nil { start = covered.location }
                end = NSMaxRange(covered)
                text += part
            }
            guard let start else { return nil }
            return textNode(text, NSRange(location: start, length: end - start))
        }
        // Куски не получились: годится, только если текст узла совпадает с исходником по длине.
        let utf16 = value as NSString
        guard utf16.length == node.range.length else { return node }
        return textNode(utf16.substring(with: NSRange(location: sub.location - node.range.location, length: sub.length)), sub)
    }

    // MARK: - wiki, встраивания, подсветка, индексы, эмодзи

    private static func decorate(_ items: [MarkdownInlineNode], nodes: [OpaquePointer], parent: OpaquePointer?, container: NSRange, ctx: Context) -> [MarkdownInlineNode] {
        let state = ctx.inlineState
        // Контекст сырого HTML идёт по порядку документа; неподтверждённый тег (rawHTML) запрещает поиск во всём списке.
        let suppress = state.isSuppressedByHTML(parent, html: ctx.html)
        var inRaw = [Bool](repeating: false, count: items.count)
        for (index, item) in items.enumerated() {
            switch item.kind {
            case .rawHTML:
                if item.isUnreliable { state.htmlContext.invalidate() }
                else { _ = state.htmlContext.consume(source: ctx.masked, range: item.range, isCancelled: ctx.isCancelled) }
            case .text: inRaw[index] = state.htmlContext.inRawContext
            default: break
            }
        }
        guard items.contains(where: { if case .text = $0.kind { return !$0.isUnreliable } else { return false } }) else { return items }
        let ancestry = Ancestry(parent: parent, container: container, ctx: ctx)
        let wikiOn = state.hasWikiBrackets && !suppress && !ancestry.excludesWiki
        let embedOn = state.hasEmbedMarker && !ancestry.inTable
        let emojiOn = state.hasColon && !suppress && !ancestry.isAutolink
        let decorationsOn = state.hasDecorationMarks && !ancestry.excludesDecorations

        var pieceCache: [Int: [Piece]?] = [:]
        func cached(_ index: Int) -> [Piece]? {
            if let value = pieceCache[index] { return value }
            guard case .text(let value) = items[index].kind else { return nil }
            let found = pieces(of: items[index], value: value, ctx: ctx)
            pieceCache[index] = .some(found)
            return found
        }

        var specials: [MarkdownInlineNode] = []
        if wikiOn {
            var ranges: [NSRange] = []
            for (index, item) in items.enumerated() {
                guard case .text = item.kind, !item.isUnreliable, !inRaw[index], let list = cached(index) else { continue }
                for piece in list {
                    if piece.matchesSource || isConfirmedSmart(piece, ctx: ctx) { ranges.append(piece.sourceRange) }
                }
            }
            if wikiOn {
                for link in MarkdownWikiLinkExtractor.links(textRanges: ranges, excluded: [], text: ctx.masked, isCancelled: ctx.isCancelled) {
                    let data = MarkdownInlineNode.WikiLink(target: link.target, heading: link.heading, alias: link.alias, displayRange: link.displayRange)
                    specials.append(MarkdownInlineNode(kind: .wikiLink(data), range: link.range, markerRanges: link.markerRanges, children: [], isUnreliable: false))
                }
            }
            specials.sort { $0.range.location < $1.range.location }
        }
        if decorationsOn {
            var found: [MarkdownInlineNode] = []
            for (index, item) in items.enumerated() {
                guard case .text(let value) = item.kind, !item.isUnreliable, value.contains("=") || value.contains("^"),
                      item.range.location >= 0, NSMaxRange(item.range) <= ctx.masked.length else { continue }
                for (range, kind) in inlineDecorations(nodes[index], source: ctx.source, text: ctx.masked, mappedRange: item.range)
                where !specials.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                    let length = kind == .highlight ? 2 : 1
                    let inner = NSRange(location: range.location + length, length: range.length - length * 2)
                    var child = textNode(ctx.masked.substring(with: inner), inner)
                    if inner.length == 0 { child.kind = .text("") }
                    var children = emojiOn && !inRaw[index] ? emojify(child, ctx: ctx) : [child]
                    if !state.segments.isEmpty { children = cut(children, container: inner, nested: true, ctx: ctx) }
                    let markers = [NSRange(location: range.location, length: length), NSRange(location: NSMaxRange(range) - length, length: length)]
                    found.append(MarkdownInlineNode(kind: kind == .highlight ? .highlight : .superscriptText, range: range, markerRanges: markers,
                                                    children: children, isUnreliable: false))
                }
            }
            specials = (specials + found).sorted { $0.range.location < $1.range.location }
        }
        if specials.isEmpty && !emojiOn { return embedOn ? embedPass(items, ctx: ctx) : items }

        var result: [MarkdownInlineNode] = []
        var cursorEnd = 0
        for (index, item) in items.enumerated() {
            guard case .text = item.kind, !item.isUnreliable else { result.append(item); continue }
            let range = item.range
            var cursor = max(range.location, min(cursorEnd, NSMaxRange(range)))
            var pending: [MarkdownInlineNode] = []
            func gap(to end: Int) {
                guard end > cursor, let part = sliceText(item, NSRange(location: cursor, length: end - cursor), pieces: cached(index), ctx: ctx) else { return }
                pending.append(part)
            }
            func flushGap() {
                for part in pending { result.append(contentsOf: emojiOn && !inRaw[index] ? emojify(part, ctx: ctx) : [part]) }
                pending = []
            }
            for special in specials where special.range.location >= cursor && special.range.location < NSMaxRange(range) {
                gap(to: special.range.location)
                flushGap()
                result.append(special)
                cursor = max(cursor, NSMaxRange(special.range))
                cursorEnd = max(cursorEnd, cursor)
                if cursor >= NSMaxRange(range) { break }
            }
            gap(to: NSMaxRange(range))
            flushGap()
        }
        return embedOn ? embedPass(result, ctx: ctx) : result
    }

    /// `![[…]]` по правилу рендера: поиск по исходнику, а не по тексту cmark, поэтому `<b>![[a.png]]</b>` и `![[a*b*c]]` работают.
    /// Начало и конец лежат в текстовых узлах списка, всё между ними входит в узел; если край попадает внутрь другого узла — не встраивание.
    private static func embedPass(_ items: [MarkdownInlineNode], ctx: Context) -> [MarkdownInlineNode] {
        guard let first = items.first, let last = items.last else { return items }
        let window = NSRange(location: first.range.location, length: max(0, NSMaxRange(last.range) - first.range.location))
        var result = items
        for embed in ctx.inlineState.embeds(intersecting: window, in: ctx.masked) {
            let embedEnd = NSMaxRange(embed.range)
            let hit = result.indices.filter { NSIntersectionRange(result[$0].range, embed.range).length > 0 }
            guard let head = hit.first, let tail = hit.last, hit == Array(head...tail) else { continue }
            func isText(_ node: MarkdownInlineNode) -> Bool { if case .text = node.kind { return !node.isUnreliable } else { return false } }
            guard isText(result[head]), isText(result[tail]), result[head].range.location <= embed.range.location,
                  NSMaxRange(result[tail].range) >= embedEnd else { continue }
            let inside = hit.dropFirst().dropLast()
            guard inside.allSatisfy({ NSIntersectionRange(result[$0].range, embed.range) == result[$0].range }) else { continue }
            var replacement: [MarkdownInlineNode] = []
            func part(_ node: MarkdownInlineNode, _ sub: NSRange) -> MarkdownInlineNode? {
                guard case .text(let value) = node.kind else { return nil }
                return sliceText(node, sub, pieces: pieces(of: node, value: value, ctx: ctx), ctx: ctx)
            }
            if result[head].range.location < embed.range.location,
               let before = part(result[head], NSRange(location: result[head].range.location, length: embed.range.location - result[head].range.location)) {
                replacement.append(before)
            }
            let data = MarkdownBlockNode.NoteEmbed(target: embed.target, heading: embed.heading, alias: embed.alias, kind: embed.kind)
            replacement.append(MarkdownInlineNode(kind: .noteEmbed(data), range: embed.range,
                                                  markerRanges: [NSRange(location: embed.range.location, length: 3), NSRange(location: embedEnd - 2, length: 2)],
                                                  children: [], isUnreliable: false))
            if NSMaxRange(result[tail].range) > embedEnd,
               let after = part(result[tail], NSRange(location: embedEnd, length: NSMaxRange(result[tail].range) - embedEnd)) {
                replacement.append(after)
            }
            result.replaceSubrange(head...tail, with: replacement)
        }
        return result
    }

    /// «Умная» замена (`"`, `'`, `--`, `---`, `...`) считается обычным текстом ссылки: её исходный вид подтверждён.
    private static func isConfirmedSmart(_ piece: Piece, ctx: Context) -> Bool {
        guard !piece.matchesSource, piece.sourceRange.length <= 3, NSMaxRange(piece.sourceRange) <= ctx.masked.length else { return false }
        let source = ctx.masked.substring(with: piece.sourceRange)
        return (source == "\"" && (piece.text == "“" || piece.text == "”")) || (source == "'" && (piece.text == "‘" || piece.text == "’")) ||
            (source == "--" && piece.text == "–") || (source == "---" && piece.text == "—") || (source == "..." && piece.text == "…")
    }

    /// `:имя:` в тексте узла: те же правила, что у `MarkdownEmojiCandidateExtractor` (имя из букв, цифр, `_`, `+`, `-`; не после нечётного числа `\`).
    private static func emojify(_ node: MarkdownInlineNode, ctx: Context) -> [MarkdownInlineNode] {
        guard case .text(let nodeValue) = node.kind, nodeValue.contains(":"), !node.isUnreliable,
              let list = pieces(of: node, value: nodeValue, ctx: ctx) else { return [node] }
        func isName(_ unit: unichar) -> Bool {
            (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 43 || unit == 45
        }
        func escaped(_ location: Int) -> Bool {
            var index = location, count = 0
            while index > 0 && ctx.masked.character(at: index - 1) == 92 { index -= 1; count += 1 }
            return count % 2 != 0
        }
        var found: [(range: NSRange, name: String)] = []
        for piece in list where piece.matchesSource {
            let value = piece.text as NSString
            var position = 0
            while position < value.length {
                guard value.character(at: position) == 58 else { position += 1; continue }
                var end = position + 1
                while end < value.length && isName(value.character(at: end)) { end += 1 }
                if end > position + 1 && end < value.length && value.character(at: end) == 58 {
                    let start = piece.sourceRange.location + position
                    if !escaped(start) {
                        found.append((NSRange(location: start, length: end - position + 1), value.substring(with: NSRange(location: position + 1, length: end - position - 1))))
                    }
                    position = end + 1
                } else { position += 1 }
            }
        }
        guard !found.isEmpty else { return [node] }
        var result: [MarkdownInlineNode] = []
        var cursor = node.range.location
        for item in found {
            if item.range.location > cursor,
               let part = sliceText(node, NSRange(location: cursor, length: item.range.location - cursor), pieces: list, ctx: ctx) { result.append(part) }
            result.append(MarkdownInlineNode(kind: .emoji(name: item.name), range: item.range, markerRanges: [], children: [], isUnreliable: false))
            cursor = NSMaxRange(item.range)
        }
        if cursor < NSMaxRange(node.range), let part = sliceText(node, NSRange(location: cursor, length: NSMaxRange(node.range) - cursor), pieces: list, ctx: ctx) {
            result.append(part)
        }
        return result
    }

    // MARK: - Правки CriticMarkup и комментарии `%%` (R1–R3, R8)

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// Режет список соседей по сегментам маски: каждый сегмент даёт по одному узлу на каждый непрерывный кусок внутри этого списка.
    private static func cut(_ items: [MarkdownInlineNode], container: NSRange, nested: Bool, ctx: Context) -> [MarkdownInlineNode] {
        let relevant = ctx.inlineState.segments(intersecting: container)
        guard !relevant.isEmpty else { return items }
        func isLeaf(_ segment: MarkdownSourceMask.Segment) -> Bool {
            if case .comment = segment.kind { return true }
            if case .critic(.comment) = segment.kind { return true }
            return false
        }
        // Комментарии вырезаем первыми: они могут лежать внутри содержимого правки.
        var result = items
        for segment in relevant.filter(isLeaf) + relevant.filter({ !isLeaf($0) }) {
            if ctx.stop() { return result }
            result = apply(segment, leaf: isLeaf(segment), to: result, container: container, nested: nested, ctx: ctx)
        }
        return result
    }

    private static func apply(_ segment: MarkdownSourceMask.Segment, leaf: Bool, to items: [MarkdownInlineNode], container: NSRange,
                              nested: Bool, ctx: Context) -> [MarkdownInlineNode] {
        let markers = segment.markerRanges
        func touchesMarker(_ range: NSRange) -> Bool { markers.contains { NSIntersectionRange($0, range).length > 0 } }
        // Вложенный список (внутри `**`, ссылки): если сегмент накрывает его целиком, узел заберёт родительский список.
        if nested, contains(segment.range, container), !touchesMarker(container) { return items }
        var parts: [(node: MarkdownInlineNode, inside: Bool)] = []
        for item in items {
            if case .text = item.kind, !item.isUnreliable {
                let overlap = NSIntersectionRange(item.range, segment.range)
                if overlap.length == 0 { parts.append((item, false)); continue }
                let list: [Piece]? = { if case .text(let value) = item.kind { return pieces(of: item, value: value, ctx: ctx) } else { return nil } }()
                if overlap.location > item.range.location,
                   let before = sliceText(item, NSRange(location: item.range.location, length: overlap.location - item.range.location), pieces: list, ctx: ctx) {
                    parts.append((before, false))
                }
                if let middle = sliceText(item, overlap, pieces: list, ctx: ctx) { parts.append((middle, true)) }
                if NSMaxRange(overlap) < NSMaxRange(item.range),
                   let after = sliceText(item, NSRange(location: NSMaxRange(overlap), length: NSMaxRange(item.range) - NSMaxRange(overlap)), pieces: list, ctx: ctx) {
                    parts.append((after, false))
                }
            } else {
                let inside = !item.isUnreliable && item.range.length > 0 && contains(segment.range, item.range) && !touchesMarker(item.range)
                parts.append((item, inside))
            }
        }
        guard parts.contains(where: { $0.inside }) else { return items }

        let kind: MarkdownInlineNode.Kind
        switch segment.kind {
        case .critic(let value): kind = .critic(value)
        default: kind = .comment
        }
        var output: [MarkdownInlineNode] = []
        var run: [MarkdownInlineNode] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let own = markers.filter { contains(range, $0) }
            var children: [MarkdownInlineNode] = []
            if !leaf {
                for node in run { children.append(contentsOf: carve(node, removing: own, ctx: ctx)) }
            }
            output.append(MarkdownInlineNode(kind: kind, range: range, markerRanges: own, children: children, isUnreliable: false))
            run = []
        }
        for part in parts {
            if part.inside { run.append(part.node) } else { flush(); output.append(part.node) }
        }
        flush()
        return output
    }

    /// Текстовый узел без служебных знаков правки: остаются куски между ними.
    private static func carve(_ node: MarkdownInlineNode, removing markers: [NSRange], ctx: Context) -> [MarkdownInlineNode] {
        guard case .text(let value) = node.kind, markers.contains(where: { NSIntersectionRange($0, node.range).length > 0 }) else { return [node] }
        let list = pieces(of: node, value: value, ctx: ctx)
        var result: [MarkdownInlineNode] = []
        var cursor = node.range.location
        for marker in markers.sorted(by: { $0.location < $1.location }) {
            let overlap = NSIntersectionRange(marker, node.range)
            guard overlap.length > 0 else { continue }
            if overlap.location > cursor,
               let part = sliceText(node, NSRange(location: cursor, length: overlap.location - cursor), pieces: list, ctx: ctx) { result.append(part) }
            cursor = max(cursor, NSMaxRange(overlap))
        }
        if cursor < NSMaxRange(node.range),
           let part = sliceText(node, NSRange(location: cursor, length: NSMaxRange(node.range) - cursor), pieces: list, ctx: ctx) { result.append(part) }
        return result
    }

    // MARK: - Верхний, нижний индекс и подсветка

    /// Нижний индекс `~x~`: узел strikethrough с одним словом без пробелов внутри. Правило общее с рендером.
    static func subscriptRange(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString, mappedRange: NSRange? = nil, mappedChild: NSRange? = nil) -> NSRange? {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "strikethrough",
              !isExcludedInline(node), cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
              let range = mappedRange ?? source.range(node), range.length >= 3,
              text.character(at: range.location) == 126, text.character(at: NSMaxRange(range) - 1) == 126,
              text.character(at: range.location + 1) != 126, text.character(at: NSMaxRange(range) - 2) != 126,
              let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
              let childType = cmark_node_get_type_string(child), String(cString: childType) == "text",
              let literal = cmark_node_get_literal(child) else { return nil }
        let content = text.substring(with: NSRange(location: range.location + 1, length: range.length - 2))
        if mappedRange != nil && mappedChild != NSRange(location: range.location + 1, length: range.length - 2) { return nil }
        guard content.utf16.elementsEqual(String(cString: literal).utf16), content.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !content.contains("~"), !content.contains("^"), !content.contains("==") else { return nil }
        return range
    }

    static func superscriptRanges(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString, mappedRange: NSRange? = nil) -> [NSRange] {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "text", !isExcludedInline(node),
              cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
              let range = mappedRange ?? source.range(node), let literal = cmark_node_get_literal(node),
              text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) else { return [] }
        let value = text.substring(with: range) as NSString
        var result: [NSRange] = [], i = 0
        while i + 2 < value.length {
            guard value.character(at: i) == 94, (i == 0 || value.character(at: i - 1) != 94), value.character(at: i + 1) != 94 else { i += 1; continue }
            var end = i + 1
            while end < value.length && value.character(at: end) != 94 { end += 1 }
            guard end < value.length else { break }
            let content = value.substring(with: NSRange(location: i + 1, length: end - i - 1))
            if !content.isEmpty, content.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
               (end + 1 == value.length || value.character(at: end + 1) != 94) {
                result.append(NSRange(location: range.location + i, length: end - i + 1))
            }
            i = end + 1
        }
        return result
    }

    static func inlineDecorations(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString, mappedRange: NSRange? = nil) -> [(NSRange, MarkdownPresentationKind)] {
        let values = (highlightRanges(node, source: source, text: text, mappedRange: mappedRange).map { ($0, MarkdownPresentationKind.highlight) } +
                      superscriptRanges(node, source: source, text: text, mappedRange: mappedRange).map { ($0, MarkdownPresentationKind.superscriptText) })
            .sorted { $0.0.location < $1.0.location }
        var result: [(NSRange, MarkdownPresentationKind)] = [], previousEnd = 0
        for (index, value) in values.enumerated() {
            let overlapsPrevious = previousEnd > value.0.location
            let overlapsNext = index + 1 < values.count && values[index + 1].0.location < NSMaxRange(value.0)
            previousEnd = max(previousEnd, NSMaxRange(value.0))
            if !overlapsPrevious && !overlapsNext { result.append(value) }
        }
        return result
    }

    static func highlightRanges(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString, mappedRange: NSRange? = nil) -> [NSRange] {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "text",
              cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
              let range = mappedRange ?? source.range(node), let literal = cmark_node_get_literal(node),
              text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) else { return [] }
        guard !isExcludedInline(node) else { return [] }
        let value = text.substring(with: range) as NSString
        func whitespace(_ unit: UInt16) -> Bool {
            UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var results: [NSRange] = [], i = 0
        while i + 4 < value.length {
            guard value.character(at: i) == 61, value.character(at: i + 1) == 61,
                  (i == 0 || value.character(at: i - 1) != 61), value.character(at: i + 2) != 61,
                  !whitespace(value.character(at: i + 2)) else { i += 1; continue }
            var end = i + 3
            while end + 1 < value.length {
                if value.character(at: end) == 61, value.character(at: end + 1) == 61,
                   value.character(at: end - 1) != 61, !whitespace(value.character(at: end - 1)),
                   (end + 2 == value.length || value.character(at: end + 2) != 61) { break }
                end += 1
            }
            guard end + 1 < value.length else { break }
            results.append(NSRange(location: range.location + i, length: end + 2 - i))
            i = end + 2
        }
        return results
    }

    static func isExcludedInline(_ node: OpaquePointer) -> Bool {
        var parent = cmark_node_parent(node)
        while let current = parent {
            if cmark_node_get_type(current) == CMARK_NODE_FOOTNOTE_DEFINITION { return true }
            if let kind = cmark_node_get_type_string(current), ["link", "image", "table", "code_block", "strikethrough"].contains(String(cString: kind)) { return true }
            parent = cmark_node_parent(current)
        }
        return false
    }
}
