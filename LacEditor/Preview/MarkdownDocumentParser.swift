import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Единый разбор Markdown (U2.3a): один проход cmark по замаскированному тексту строит `MarkdownDocumentModel`.
/// Здесь блоки и базовые строчные узлы (text, переносы, code, emph, strong, link, image, strikethrough, сноски).
/// Точки подключения: строчные виды (wiki-ссылки, emoji, critic, подсветка, подстрочные и т. п.) — подзадача b,
/// HTML (блоки и теги) — подзадача c; пока они отдают обычный разбор cmark как text/rawHTML.
enum MarkdownDocumentParser {
    static func parse(_ text: String, options: MarkdownDocumentModel.Options, isCancelled: @escaping () -> Bool = { false }) -> MarkdownDocumentModel? {
        // NUL заменяем на U+FFFD (длина в UTF-16 та же), чтобы не ронять разбор.
        let text = text.utf8.contains(0) ? text.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}") : text
        let sourceText = text as NSString
        var model = MarkdownDocumentModel(revision: nil, textLength: sourceText.length, options: options, blocks: [], frontMatter: nil,
                                          unreliableRanges: [], headingIDs: [], namedAnchors: [], footnotes: [], looseIndents: [],
                                          smartReplacements: [], fence: nil, emoji: nil, readableText: nil, blockIndex: nil, elements: nil)
        let syntax = options.syntax
        let mask = MarkdownSourceMask.mask(text, options: MarkdownSourceMask.Options(
            syntax: syntax, isVaultNote: options.isVaultNote, detectsFrontMatter: options.detectsFrontMatter,
            includesCritic: options.includes.contains(.criticMarkup)), isCancelled: isCancelled)
        if isCancelled() { return nil }
        let cmarkOptions = ((syntax.smartPunctuation ?? true) ? CMARK_OPT_SMART : 0) | CMARK_OPT_TABLE_SPANS | CMARK_OPT_FOOTNOTES
        let result: MarkdownDocumentModel?? = MarkdownMathExtension.withDocument(
            mask.text, options: cmarkOptions, includeInline: syntax.inlineMath, legacyInlineMath: syntax.legacyInlineMath,
            strictMode: syntax.strictMode, sourceForPositions: mask.text, isCancelled: isCancelled
        ) { (root: OpaquePointer, ext: OpaquePointer, inline: [MarkdownMathExtension.Inline], _: OpaquePointer) -> MarkdownDocumentModel? in
            let positions = MarkdownSourcePositions(mask.text, root: root, textOrigins: MarkdownMathExtension.textOrigins(in: ext),
                                                    looseHeadings: MarkdownMathExtension.looseHeadings(in: ext),
                                                    looseListRanges: MarkdownMathExtension.looseListRanges(in: ext), isCancelled: isCancelled)
            if isCancelled() { return nil }
            let context = Context(text: sourceText, mask: mask, source: positions, ext: ext,
                                  mathInline: inline.reduce(into: [OpaquePointer: MarkdownMathExtension.Inline]()) { $0[$1.node] = $1 },
                                  options: options, isCancelled: isCancelled)
            context.html = confirmHTML(root: root, cmarkOptions: cmarkOptions, ctx: context)
            if context.stop() { return nil }
            if options.includes.contains(.emoji) {
                context.textScan = MarkdownDocumentExtras.textScan(root: root, source: positions, text: context.masked, emoji: true, wiki: false, isCancelled: isCancelled)
                if context.stop() { return nil }
            }
            let whole = NSRange(location: 0, length: sourceText.length)
            var top = convertBlocks(childNodes(of: root), container: whole, inContainer: false, listDepth: 0, ctx: context)
            // cmark переносит определения сносок в конец документа: возвращаем их на место по позиции в тексте.
            let definitions = top.filter { if case .footnoteDefinition = $0.kind { return !$0.isUnreliable } else { return false } }
            if !definitions.isEmpty {
                top.removeAll { block in definitions.contains { $0.range == block.range && $0.kind == block.kind } }
                for definition in definitions {
                    let index = top.firstIndex { !$0.isUnreliable && $0.range.location > definition.range.location } ?? top.count
                    top.insert(definition, at: index)
                }
            }
            if context.stop() { return nil }
            if let front = mask.segments.first(where: { $0.kind == .frontMatter }) {
                model.frontMatter = MarkdownDocumentModel.FrontMatter(range: front.range, markers: front.markerRanges)
                top.insert(MarkdownBlockNode(kind: .frontMatter, range: front.range, markerRanges: front.markerRanges, containerPrefixes: [],
                                             children: [], inlines: [], isUnreliable: false), at: 0)
            }
            for segment in mask.segments where segment.kind == .comment && segment.occupiesWholeLines {
                if context.stop() { return nil }
                insertComment(segment, into: &top)
            }
            model.blocks = top
            model.headingIDs = context.headingIDs
            model.footnotes = context.footnotes
            model.footnoteNumbers = context.footnoteNumbers
            model.blockedHTML = context.html?.blocked ?? []
            if let html = context.html, html.rangesAvailable {
                model.namedAnchors = confirmedNamedAnchors(
                    in: html.contextText ?? sourceText, ranges: html.ranges.sorted { $0.location < $1.location }, isCancelled: context.stop)
            }
            model.unreliableRanges = context.mergedUnreliable()
            if options.includes.contains(.editorContext) { model.looseIndents = MarkdownMathExtension.looseIndents(in: ext) }
            fillExtras(&model, root: root, ext: ext, ctx: context)
            if options.includes.contains(.elementIndex) { model.elements = elementIndex(of: model, text: sourceText, htmlPairs: context.html.map { Array($0.pairs.values) } ?? [],
                                                                                 isCancelled: context.stop) }
            if options.includes.contains(.editorContext) { model.fence = fence(of: model, text: sourceText, isCancelled: context.stop) }
            fillReplacements(&model, ctx: context)
            return context.stop() ? nil : model
        }
        if isCancelled() { return nil }
        return result ?? nil
    }

    // MARK: - Состояние разбора

    final class Context {
        let text: NSString
        let mask: MarkdownSourceMask.Result
        let masked: NSString
        let source: MarkdownSourcePositions
        let ext: OpaquePointer
        let mathInline: [OpaquePointer: MarkdownMathExtension.Inline]
        let options: MarkdownDocumentModel.Options
        let isCancelled: () -> Bool
        let placeholder: String
        let mayContainEmbed: Bool
        var cancelled = false
        var allocator = MarkdownHeadingAnchors.Allocator()
        var headingIDs: [String] = []
        var footnotes: [MarkdownFootnote] = []
        var footnoteNumbers: [NSRange: Int] = [:]
        var unreliable: [NSRange] = []
        /// Итог подтверждения HTML (подзадача c): считается один раз до обхода блоков.
        var html: HTMLConfirmation?
        /// Обход текстовых узлов (`Includes.emoji`): считается до обхода блоков, нужен заголовкам и `EmojiData`.
        var textScan: MarkdownDocumentExtras.TextScan?
        /// Больше нуля внутри таблицы и определения сноски: заголовки без id, сноски не собираются.
        var unsupportedDepth = 0
        /// Позиции `>`, уже занятые маркерами внешних цитат.
        var claimedQuoteMarkers = Set<Int>()
        var cellPositions: [OpaquePointer: MarkdownSourcePositions.TableCellPositions?] = [:]
        lazy var inlineState = InlineState(mask: mask, masked: masked, options: options)

        /// Убирает из строки заменители маски (комментарии и метки правок), чтобы они не попадали в данные модели.
        func clean(_ value: String) -> String {
            mask.isIdentity || !value.contains(placeholder) ? value : value.replacingOccurrences(of: placeholder, with: "")
        }

        init(text: NSString, mask: MarkdownSourceMask.Result, source: MarkdownSourcePositions, ext: OpaquePointer,
             mathInline: [OpaquePointer: MarkdownMathExtension.Inline], options: MarkdownDocumentModel.Options, isCancelled: @escaping () -> Bool) {
            self.text = text
            self.mask = mask
            self.masked = mask.text as NSString
            self.source = source
            self.ext = ext
            self.mathInline = mathInline
            self.options = options
            self.isCancelled = isCancelled
            self.placeholder = String(Character(UnicodeScalar(mask.placeholder) ?? "\u{FFFF}"))
            self.mayContainEmbed = options.includes.contains(.noteEmbeds) && MarkdownNoteEmbed.mayContainEmbed(text as String)
        }

        func stop() -> Bool {
            if !cancelled && isCancelled() { cancelled = true }
            return cancelled
        }

        func substring(_ range: NSRange) -> String? {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= text.length else { return nil }
            return text.substring(with: range)
        }

        private var tabColumns: [Int: (bytes: [Int: Int], scalars: [Int: Int])?] = [:]

        /// Диапазон обрывает сущность (`&` перед `amp;`): такое совпадение с литералом неверно.
        func splitsEntity(_ range: NSRange) -> Bool {
            let units = source.units, end = NSMaxRange(range)
            guard range.length > 0, end <= units.count, units[end - 1] == 38 else { return false }
            var index = end
            while index < units.count, (units[index] >= 48 && units[index] <= 57) || (units[index] >= 65 && units[index] <= 90) || (units[index] >= 97 && units[index] <= 122) || units[index] == 35 { index += 1 }
            return index > end && index < units.count && units[index] == 59
        }

        /// Литерал, совпавший с началом сущности (`a&` перед `amp;`), даёт диапазон до `;`, если исходник декодируется в литерал (общий разбор `MarkdownInlineTextProjection`).
        func entityExtended(_ range: NSRange, literal: String) -> NSRange? {
            guard splitsEntity(range) else { return range }
            var end = NSMaxRange(range)
            while end < source.units.count, source.units[end] != 59 { end += 1 }
            let extended = NSRange(location: range.location, length: end + 1 - range.location)
            guard NSMaxRange(extended) <= source.units.count, let spelling = substring(extended),
                  MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: literal, sourceOffset: extended.location) != nil else { return nil }
            return extended
        }

        /// Текст на строке с табом: позицию cmark не подтверждает, но если из кандидатов по колонкам ровно один совпадает с литералом
        /// (с учётом сущностей, экранирования и умных замен), он и берётся.
        func tabbedTextRange(_ node: OpaquePointer, literal: String) -> NSRange? {
            let line = Int(cmark_node_get_start_line(node)) - 1
            let columns: (bytes: [Int: Int], scalars: [Int: Int])?
            if let cached = tabColumns[line] { columns = cached } else {
                columns = source.tabColumns(line: line, isCancelled: isCancelled)
                tabColumns[line] = .some(columns)
            }
            guard let columns else { return nil }
            var found: NSRange?
            for range in source.tabbedTextCandidateRanges(node, byteColumns: columns.bytes, scalarColumns: columns.scalars) {
                if stop() { return nil }
                guard range.location >= 0, range.length > 0, NSMaxRange(range) <= masked.length,
                      !splitsEntity(range),
                      MarkdownInlineTextProjection.pieces(spelling: masked.substring(with: range) as NSString, literal: literal,
                                                          sourceOffset: range.location, isCancelled: isCancelled) != nil else { continue }
                if found != nil { return nil }
                found = range
            }
            return found
        }

        /// Строки узла без подтверждённой позиции cmark (`strong`, `emph`, `strikethrough`, `link`, `code`,
        /// `block_quote`, `item`; не в таблице, сноске и картинке): элемент без диапазона не получает оформления, а карта текста должна об этом знать.
        func flagUnreliable(_ node: OpaquePointer) {
            guard unsupportedDepth == 0, source.range(node) == nil, let name = cmark_node_get_type_string(node),
                  let lines = MarkdownDocumentExtras.unreliableLines(node: node, type: String(cString: name), source: source) else { return }
            unreliable.append(lines)
        }

        /// Строки, где позиции не подтверждены: отсортированы, пересекающиеся слиты.
        func mergedUnreliable() -> [NSRange] {
            var result: [NSRange] = []
            for range in unreliable.sorted(by: { $0.location < $1.location }) {
                if let last = result.last, range.location <= NSMaxRange(last) {
                    result[result.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
                } else { result.append(range) }
            }
            return result
        }

        func tablePositions(_ cell: OpaquePointer) -> MarkdownSourcePositions.TableCellPositions? {
            if let cached = cellPositions[cell] { return cached }
            let positions = source.tableCellPositions(cell, isCancelled: isCancelled)
            cellPositions[cell] = .some(positions)
            return positions
        }
    }

    // MARK: - Помощники над cmark

    private static func cmarkType(_ node: OpaquePointer) -> cmark_node_type { cmark_node_get_type(node) }

    /// Перенос строки где-либо внутри узла (в том числе в `*…*` внутри зачёркивания).
    private static func containsLineBreak(_ node: OpaquePointer) -> Bool {
        childNodes(of: node).contains { child in
            let type = cmarkType(child)
            return type == CMARK_NODE_SOFTBREAK || type == CMARK_NODE_LINEBREAK || containsLineBreak(child)
        }
    }

    private static func typeName(_ node: OpaquePointer) -> String {
        cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
    }

    private static func literal(_ node: OpaquePointer) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    private static func childNodes(of parent: OpaquePointer) -> [OpaquePointer] {
        var result: [OpaquePointer] = []
        var child = cmark_node_first_child(parent)
        while let current = child { result.append(current); child = cmark_node_next(current) }
        return result
    }

    private static func isDocumentChild(_ node: OpaquePointer) -> Bool {
        cmark_node_parent(node).map { cmarkType($0) == CMARK_NODE_DOCUMENT } == true
    }

    /// Вписывает диапазон в объемлющий; `nil` — не пересекается с ним вовсе.
    private static func fit(_ range: NSRange, in container: NSRange) -> (range: NSRange, exact: Bool)? {
        if range.location >= container.location && NSMaxRange(range) <= NSMaxRange(container) { return (range, true) }
        let clipped = NSIntersectionRange(range, container)
        return clipped.length > 0 ? (clipped, false) : nil
    }

    // MARK: - Блоки

    private static func convertBlocks(_ nodes: [OpaquePointer], container: NSRange, inContainer: Bool, listDepth: Int, ctx: Context) -> [MarkdownBlockNode] {
        var result: [MarkdownBlockNode] = []
        for node in nodes {
            if ctx.stop() { return result }
            if let converted = block(node, container: container, inContainer: inContainer, listDepth: listDepth, ctx: ctx) { result.append(converted) }
        }
        return result
    }

    private static func blockRange(_ node: OpaquePointer, container: NSRange, ctx: Context, preferred: NSRange? = nil) -> (range: NSRange, unreliable: Bool) {
        if let range = preferred ?? ctx.source.range(node), let fitted = fit(range, in: container), fitted.exact { return (fitted.range, false) }
        if let lines = ctx.source.lineRange(of: node), let fitted = fit(lines, in: container) { return (fitted.range, true) }
        return (container, true)
    }

    /// Границы абзаца по первому и последнему подтверждённому строчному узлу; до первого узла на его строке только префикс контейнера,
    /// после последнего до конца строк только пробелы и табы (определения ссылок и флажок задачи сюда не попадают).
    private static func confirmedParagraphRange(_ lines: NSRange, _ inlines: [MarkdownInlineNode], ctx: Context) -> NSRange? {
        guard let first = inlines.first, let last = inlines.last, !first.isUnreliable, !last.isUnreliable, first.range.length > 0, last.range.length > 0,
              first.range.location >= lines.location, NSMaxRange(last.range) <= NSMaxRange(lines), NSMaxRange(last.range) >= first.range.location else { return nil }
        let units = ctx.source.units
        guard NSMaxRange(lines) <= units.count else { return nil }
        for index in lines.location..<first.range.location {
            let unit = units[index]
            let allowed = unit == 32 || unit == 9 || unit == 62 || unit == 45 || unit == 43 || unit == 42 || unit == 46 || unit == 41 || (unit >= 48 && unit <= 57)
            guard allowed else { return nil }
        }
        for index in NSMaxRange(last.range)..<NSMaxRange(lines) where units[index] != 32 && units[index] != 9 { return nil }
        return NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
    }

    private static func block(_ node: OpaquePointer, container: NSRange, inContainer: Bool, listDepth: Int, ctx: Context) -> MarkdownBlockNode? {
        let nodeType = cmarkType(node)
        if nodeType == CMARK_NODE_BLOCK_QUOTE { ctx.flagUnreliable(node) }
        let source = ctx.source
        func finish(_ kind: MarkdownBlockNode.Kind, _ range: NSRange, _ unreliable: Bool, _ markers: [NSRange], _ children: [MarkdownBlockNode],
                    _ inlines: [MarkdownInlineNode], _ leaf: Bool) -> MarkdownBlockNode {
            var prefixRange = range
            // Диапазон абзаца на строках с табом — целые строки, включая префикс контейнера: префикс считается до первого подтверждённого узла.
            if unreliable, leaf, let first = inlines.first, !first.isUnreliable, first.range.location > range.location, first.range.location < NSMaxRange(range) {
                prefixRange = NSRange(location: first.range.location, length: NSMaxRange(range) - first.range.location)
            }
            let prefixes = leaf && inContainer ? containerPrefixes(node, range: prefixRange, ctx: ctx) : []
            return MarkdownBlockNode(kind: kind, range: range, markerRanges: markers, containerPrefixes: prefixes, children: children,
                                     inlines: inlines, isUnreliable: unreliable)
        }

        if nodeType == CMARK_NODE_PARAGRAPH {
            let (initialRange, unreliable) = blockRange(node, container: container, ctx: ctx)
            var range = initialRange
            // Таблица, прервавшая абзац, забирает его строки у cmark: абзац заканчивается перед строкой заголовка таблицы.
            if let table = cmark_node_next(node), typeName(table) == "table", let tableStart = ctx.source.tableRange(table)?.location,
               tableStart > range.location, tableStart < NSMaxRange(range) {
                range.length = lineEnd(before: tableStart, ctx: ctx) - range.location
            }
            if isDocumentChild(node) {
                // Как в рендере: один текстовый узел `[toc]`, занимающий пять знаков строки (не `\[toc\]`).
                if ctx.unsupportedDepth == 0, let child = cmark_node_first_child(node), cmark_node_next(child) == nil, cmarkType(child) == CMARK_NODE_TEXT,
                   literal(child) == "[toc]", cmark_node_get_start_line(child) == cmark_node_get_end_line(child),
                   cmark_node_get_end_column(child) - cmark_node_get_start_column(child) == 4 {
                    return finish(.tableOfContents, range, unreliable, [], [], [], false)
                }
                if ctx.mayContainEmbed, !unreliable, let embed = noteEmbed(range: range, ctx: ctx) {
                    return finish(.noteEmbed(embed), range, false, [], [], [], false)
                }
            }
            let scope = paragraphScope(node, ctx: ctx)
            // Определения ссылок перед текстом входят в абзац: первый текст ищем после них (иначе табовая строка делает его ненадёжным).
            let prefixEnd = ctx.source.referencePrefix(node).map { NSMaxRange($0) }
            let converted = inlines(of: childNodes(of: node), container: range, scope: scope, imageBlock: isDocumentChild(node), ctx: ctx,
                                    previousEnd: prefixEnd.flatMap { $0 >= range.location && $0 <= NSMaxRange(range) ? $0 : nil })
            // Позиция абзаца на строке с табом не подтверждена cmark, но крайние строчные узлы подтверждены по тексту: границы берутся по ним.
            if unreliable, let confirmed = confirmedParagraphRange(range, converted, ctx: ctx) {
                return finish(.paragraph, confirmed, false, [], [], converted, true)
            }
            return finish(.paragraph, range, unreliable, [], [], converted, true)
        }

        if nodeType == CMARK_NODE_HEADING {
            let (range, unreliable) = blockRange(node, container: container, ctx: ctx)
            return heading(node, range: range, unreliable: unreliable, inContainer: inContainer, ctx: ctx)
        }

        if nodeType == CMARK_NODE_BLOCK_QUOTE {
            let (range, unreliable) = blockRange(node, container: container, ctx: ctx)
            let markers = quoteMarkers(range, ctx: ctx)
            if let alert = alert(node, source: source, text: ctx.text), let kind = MarkdownBlockNode.Alert(rawValue: alert.label) {
                let children = convertBlocks(childNodes(of: node), container: range, inContainer: true, listDepth: listDepth, ctx: ctx)
                return finish(.alert(kind), range, unreliable, markers, children, [], false)
            }
            if let callout = callout(node, range: range, listDepth: listDepth, ctx: ctx) {
                return finish(.callout(callout.callout), range, unreliable, markers, callout.children, callout.title, false)
            }
            let children = convertBlocks(childNodes(of: node), container: range, inContainer: true, listDepth: listDepth, ctx: ctx)
            return finish(.quote, range, unreliable, markers, children, [], false)
        }

        if nodeType == CMARK_NODE_LIST {
            let (range, unreliable) = blockRange(node, container: container, ctx: ctx)
            let items = childNodes(of: node)
            let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
            let marker: MarkdownBlockNode.ListBlock.Marker
            if ordered {
                marker = .ordered(start: Int(cmark_node_get_list_start(node)), delimiter: cmark_node_get_list_delim(node) == CMARK_PAREN_DELIM ? 41 : 46)
            } else {
                let unit = items.first.flatMap { source.firstPosition($0) }.flatMap { $0 < source.units.count ? source.units[$0] : nil }
                marker = .bullet(unit ?? 45)
            }
            let start = ordered ? Int(cmark_node_get_list_start(node)) : nil
            var children: [MarkdownBlockNode] = []
            for (index, item) in items.enumerated() {
                if ctx.stop() { break }
                children.append(listItem(item, container: range, ordinal: start.map { $0 + index }, listDepth: listDepth + 1, ctx: ctx))
            }
            let list = MarkdownBlockNode.ListBlock(marker: marker, isTight: cmark_node_get_list_tight(node) != 0, depth: listDepth + 1)
            return finish(.list(list), range, unreliable, [], children, [], false)
        }

        if nodeType == CMARK_NODE_CODE_BLOCK {
            if cmark_node_get_syntax_extension(node) == ctx.ext {
                let fallback = blockRange(node, container: container, ctx: ctx, preferred: source.mathBlockRange(node))
                return finish(.mathBlock(source: ctx.clean(literal(node))), fallback.range, fallback.unreliable, [], [], [], true)
            }
            return codeBlock(node, container: container, ctx: ctx, finish: finish)
        }

        if nodeType == CMARK_NODE_HTML_BLOCK {
            let (range, unreliable) = blockRange(node, container: container, ctx: ctx)
            return finish(.html(MarkdownBlockNode.HTMLBlock(literal: literal(node), kind: ctx.html?.blocks[node] ?? .raw)), range, unreliable, [], [], [], true)
        }

        if nodeType == CMARK_NODE_THEMATIC_BREAK {
            let (range, unreliable) = blockRange(node, container: container, ctx: ctx)
            return finish(.thematicBreak, range, unreliable, [], [], [], true)
        }

        if nodeType == CMARK_NODE_FOOTNOTE_DEFINITION {
            var (range, unreliable) = blockRange(node, container: container, ctx: ctx)
            let marker = source.footnoteDefinitionMarker(node).map { [$0] } ?? []
            // cmark начинает определение сноски после метки, а узел должен включать и саму метку.
            if !unreliable, let first = marker.first, first.location < range.location, first.location >= container.location {
                range = NSRange(location: first.location, length: NSMaxRange(range) - first.location)
            }
            ctx.unsupportedDepth += 1
            defer { ctx.unsupportedDepth -= 1 }
            let children = convertBlocks(childNodes(of: node), container: range, inContainer: inContainer, listDepth: listDepth, ctx: ctx)
            return finish(.footnoteDefinition(label: literal(node)), range, unreliable, marker, children, [], false)
        }

        if typeName(node) == "table" {
            let (range, unreliable) = blockRange(node, container: container, ctx: ctx, preferred: source.tableRange(node))
            ctx.unsupportedDepth += 1
            defer { ctx.unsupportedDepth -= 1 }
            return finish(.table(tableBlock(node, range: range, ctx: ctx)), range, unreliable, [], [], [], true)
        }
        return nil
    }

    private static func listItem(_ node: OpaquePointer, container: NSRange, ordinal: Int?, listDepth: Int, ctx: Context) -> MarkdownBlockNode {
        ctx.flagUnreliable(node)
        let (range, unreliable) = blockRange(node, container: container, ctx: ctx)
        let source = ctx.source
        var markers: [NSRange] = []
        if let start = source.firstPosition(node), start < source.units.count {
            var end = start
            if (48...57).contains(source.units[start]) {
                while end < source.units.count && (48...57).contains(source.units[end]) { end += 1 }
            }
            if end < source.units.count { end += 1 }
            if end <= NSMaxRange(range) { markers = [NSRange(location: start, length: end - start)] }
        }
        let task = source.taskCheckbox(node)
        let children = convertBlocks(childNodes(of: node), container: range, inContainer: true, listDepth: listDepth, ctx: ctx)
        return MarkdownBlockNode(kind: .listItem(MarkdownBlockNode.ListItem(ordinal: ordinal, task: task)), range: range, markerRanges: markers,
                                 containerPrefixes: [], children: children, inlines: [], isUnreliable: unreliable || markers.isEmpty)
    }

    // MARK: Заголовок

    private static func heading(_ node: OpaquePointer, range initialRange: NSRange, unreliable: Bool, inContainer: Bool, ctx: Context) -> MarkdownBlockNode {
        let source = ctx.source
        var range = initialRange
        let headingInfo = headingData(node, mathInline: ctx.mathInline, emojiByNode: ctx.textScan?.byNode ?? [:])
        let rawTitle = headingInfo.title
        let title = ctx.clean(rawTitle)
        // Заменители масок убраны из названия: диапазоны эмодзи сдвигаем на число убранных знаков перед ними.
        var headingEmoji = headingInfo.emoji
        if title != rawTitle {
            let raw = rawTitle as NSString
            headingEmoji = headingEmoji.map { item in
                let removed = raw.substring(to: item.range.location).utf16.filter { $0 == ctx.mask.placeholder }.count
                return MarkdownHeading.Emoji(range: NSRange(location: item.range.location - removed, length: item.range.length), name: item.name)
            }
        }
        let supported = ctx.unsupportedDepth == 0
        var slug = "", id = ""
        if supported {
            let entry = ctx.allocator.next(title)
            slug = entry.slug
            id = entry.id
            ctx.headingIDs.append(id)
        }
        // ATX занимает одну строку; многострочный заголовок — setext (даже если начинается с `#`, например `#тег` над `====`).
        let isATX = cmark_node_get_end_line(node) <= cmark_node_get_start_line(node) && range.location < source.units.count && source.units[range.location] == 35
        var markers: [NSRange] = []
        if isATX {
            // cmark заканчивает заголовок до закрывающих `#`: если дальше до конца строки только они, включаем их.
            var tail = NSMaxRange(range), sawHash = false
            while tail < source.units.count, source.units[tail] == 32 || source.units[tail] == 9 || source.units[tail] == 35 {
                if source.units[tail] == 35 { sawHash = true }
                tail += 1
            }
            if sawHash, tail == source.units.count || source.units[tail] == 10 || source.units[tail] == 13 {
                range = NSRange(location: range.location, length: tail - range.location)
            }
            markers = source.headingMarkers(range, allowNoSpace: true)
            let opening = markers.first.map { NSMaxRange($0) } ?? range.location
            var end = NSMaxRange(range)
            while end > opening, source.units[end - 1] == 32 || source.units[end - 1] == 9 { end -= 1 }
            var closing = end
            while closing > opening, source.units[closing - 1] == 35 { closing -= 1 }
            if closing < end, closing > opening, source.units[closing - 1] == 32 || source.units[closing - 1] == 9 {
                markers.append(NSRange(location: closing, length: end - closing))
            }
        } else if let underline = underlineRange(range, ctx: ctx) {
            markers = [underline]
        }
        let converted = inlines(of: childNodes(of: node), container: range, scope: InlineScope(lazy: nil, positions: nil), imageBlock: false, ctx: ctx)
        var content = NSRange(location: markers.first.map { NSMaxRange($0) } ?? range.location, length: 0)
        if let first = converted.first, let last = converted.last, !first.isUnreliable, !last.isUnreliable, NSMaxRange(last.range) >= first.range.location {
            content = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        }
        let data = MarkdownBlockNode.Heading(level: Int(cmark_node_get_heading_level(node)), style: isATX ? .atx : .setext, title: title, id: id, slug: slug,
                                             contentRange: content, emoji: supported ? headingEmoji : [],
                                             uppercaseRuns: uppercaseRuns(node, title: rawTitle, supported: supported, ctx: ctx), isTopLevel: isDocumentChild(node),
                                             inUnsupportedContainer: !supported)
        let prefixes = inContainer ? containerPrefixes(node, range: range, ctx: ctx) : []
        return MarkdownBlockNode(kind: .heading(data), range: range, markerRanges: markers, containerPrefixes: prefixes, children: [],
                                 inlines: converted, isUnreliable: unreliable)
    }

    /// Строка подчёркивания setext-заголовка: последняя строка диапазона из `=` или `-` (без пробелов по краям).
    private static func underlineRange(_ range: NSRange, ctx: Context) -> NSRange? {
        let units = ctx.source.units
        guard NSMaxRange(range) <= units.count, range.length > 0 else { return nil }
        var end = NSMaxRange(range)
        while end > range.location, units[end - 1] == 32 || units[end - 1] == 9 { end -= 1 }
        var start = end
        while start > range.location, units[start - 1] == 61 || units[start - 1] == 45 { start -= 1 }
        guard start < end else { return nil }
        // Подчёркивание стоит на отдельной строке: до него на этой строке только пробелы.
        var cursor = start
        while cursor > range.location, units[cursor - 1] == 32 || units[cursor - 1] == 9 { cursor -= 1 }
        guard cursor > range.location, units[cursor - 1] == 10 || units[cursor - 1] == 13 else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Выноска и встраивание

    private static func callout(_ node: OpaquePointer, range: NSRange, listDepth: Int, ctx: Context)
        -> (callout: MarkdownBlockNode.Callout, title: [MarkdownInlineNode], children: [MarkdownBlockNode])? {
        guard let paragraph = cmark_node_first_child(node), cmarkType(paragraph) == CMARK_NODE_PARAGRAPH,
              let first = cmark_node_first_child(paragraph), cmarkType(first) == CMARK_NODE_TEXT else { return nil }
        let value = literal(first)
        guard let parsed = MarkdownCalloutRender.marker(in: Substring(value)) else { return nil }
        let markerText = String(value.prefix(parsed.length))
        let rest = String(value.dropFirst(parsed.length))
        let siblings = childNodes(of: paragraph)
        if rest.isEmpty, siblings.count > 1 {
            let next = siblings[1]
            let allowed = cmarkType(next) == CMARK_NODE_SOFTBREAK || cmarkType(next) == CMARK_NODE_LINEBREAK ||
                (cmarkType(next) == CMARK_NODE_HTML_INLINE && literal(next).hasPrefix("<br"))
            guard allowed else { return nil }
        }
        let markerLength = (markerText as NSString).length
        var textRange = ctx.source.editingTextRange(first)
        if let known = textRange, ctx.substring(NSRange(location: known.location, length: min(markerLength, known.length))) != markerText { textRange = nil }
        if textRange == nil {
            let line = ctx.text.lineRange(for: NSRange(location: range.location, length: 0))
            let found = ctx.text.range(of: "[!", options: [], range: NSIntersectionRange(line, range))
            guard found.location != NSNotFound else { return nil }
            textRange = NSRange(location: found.location, length: NSMaxRange(line) - found.location)
        }
        guard let known = textRange, ctx.substring(NSRange(location: known.location, length: markerLength)) == markerText else { return nil }
        let markerRange = NSRange(location: known.location, length: markerLength)
        // Заголовок: остаток первого текста после маркера и пробелов, затем узлы до первого переноса строки.
        let restUnits = Array(rest.utf16)
        var skipped = 0
        while skipped < restUnits.count, restUnits[skipped] == 32 || restUnits[skipped] == 9 { skipped += 1 }
        let line = ctx.text.lineRange(for: NSRange(location: known.location, length: 0))
        var lineEnd = NSMaxRange(line)
        while lineEnd > line.location, ctx.text.character(at: lineEnd - 1) == 10 || ctx.text.character(at: lineEnd - 1) == 13 { lineEnd -= 1 }
        var breakIndex = siblings.count
        for (index, sibling) in siblings.enumerated() where index > 0 {
            if cmarkType(sibling) == CMARK_NODE_SOFTBREAK || cmarkType(sibling) == CMARK_NODE_LINEBREAK { breakIndex = index; break }
        }
        var titleNodes: [MarkdownInlineNode] = []
        let titleStart = NSMaxRange(markerRange) + skipped
        let hasTitleText = skipped < restUnits.count
        if hasTitleText {
            let textEnd = max(titleStart, min(lineEnd, NSMaxRange(known)))
            let titleRange = NSRange(location: titleStart, length: textEnd - titleStart)
            titleNodes.append(MarkdownInlineNode(kind: .text(ctx.clean(String(rest.dropFirst(skipped)))), range: titleRange,
                                                 markerRanges: [], children: [], isUnreliable: false))
        }
        let scope = paragraphScope(paragraph, ctx: ctx)
        let paragraphRange = blockRange(paragraph, container: range, ctx: ctx).range
        let titleFrom: Int? = titleNodes.last.map { NSMaxRange($0.range) } ?? NSMaxRange(markerRange)
        titleNodes += inlines(of: Array(siblings[1..<breakIndex]), container: paragraphRange, scope: scope, imageBlock: false, ctx: ctx, previousEnd: titleFrom)
        var children: [MarkdownBlockNode] = []
        if breakIndex + 1 < siblings.count {
            // Тело начинается на следующей строке после заголовка: пропускаем её префикс цитаты.
            var bodyStart: Int?
            if cmarkType(siblings[breakIndex]) != CMARK_NODE_HTML_INLINE {
                let units = ctx.source.units
                var index = lineEnd
                while index < NSMaxRange(paragraphRange), units[index] == 10 || units[index] == 13 { index += 1 }
                while index < NSMaxRange(paragraphRange), units[index] == 32 || units[index] == 9 || units[index] == 62 { index += 1 }
                if index > lineEnd, index < NSMaxRange(paragraphRange) { bodyStart = index }
            }
            let scanned = bodyStart != nil
            let provisional = bodyStart.map { NSRange(location: $0, length: NSMaxRange(paragraphRange) - $0) } ?? paragraphRange
            let body = inlines(of: Array(siblings[(breakIndex + 1)...]), container: provisional, scope: scope, imageBlock: false, ctx: ctx,
                               previousEnd: scanned ? provisional.location : titleFrom)
            var bodyRange = paragraphRange
            var unreliable = true
            if scanned { bodyRange = provisional; unreliable = false }
            else if let start = body.first(where: { !$0.isUnreliable })?.range.location, start >= paragraphRange.location, start <= NSMaxRange(paragraphRange) {
                bodyRange = NSRange(location: start, length: NSMaxRange(paragraphRange) - start)
                unreliable = false
            }
            children.append(MarkdownBlockNode(kind: .paragraph, range: bodyRange, markerRanges: [],
                                              containerPrefixes: containerPrefixes(paragraph, range: bodyRange, ctx: ctx), children: [],
                                              inlines: body, isUnreliable: unreliable))
        }
        children += convertBlocks(Array(childNodes(of: node).dropFirst()), container: range, inContainer: true, listDepth: listDepth, ctx: ctx)
        var titleRange: NSRange?
        if let last = titleNodes.last, NSMaxRange(last.range) > titleStart { titleRange = NSRange(location: titleStart, length: NSMaxRange(last.range) - titleStart) }
        let fold: MarkdownBlockNode.Callout.Fold
        switch parsed.marker.fold {
        case .none: fold = .none
        case .open: fold = .expanded
        case .closed: fold = .collapsed
        }
        let data = MarkdownBlockNode.Callout(type: parsed.marker.type, kind: MarkdownCalloutKind.kind(forType: parsed.marker.type), fold: fold,
                                             markerRange: markerRange, titleRange: titleRange)
        return (data, titleNodes, children)
    }

    private static func noteEmbed(range: NSRange, ctx: Context) -> MarkdownBlockNode.NoteEmbed? {
        guard let value = ctx.substring(range), value.contains("![[") else { return nil }
        var excluded: [NSRange] = []
        if range.location > 0 { excluded.append(NSRange(location: 0, length: range.location)) }
        if NSMaxRange(range) < ctx.text.length { excluded.append(NSRange(location: NSMaxRange(range), length: ctx.text.length - NSMaxRange(range))) }
        guard let item = MarkdownNoteEmbed.items(in: ctx.text, excluded: excluded).first(where: { $0.isBlock && $0.range == range }) else { return nil }
        return MarkdownBlockNode.NoteEmbed(target: item.target, heading: item.heading, alias: item.alias, kind: item.kind)
    }

    // MARK: Код

    private static func codeBlock(_ node: OpaquePointer, container: NSRange, ctx: Context,
                                  finish: (MarkdownBlockNode.Kind, NSRange, Bool, [NSRange], [MarkdownBlockNode], [MarkdownInlineNode], Bool) -> MarkdownBlockNode) -> MarkdownBlockNode {
        let source = ctx.source
        let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
        let body = literal(node)
        var fenceLength: Int32 = 0, fenceOffset: Int32 = 0, fenceCharacter: CChar = 0
        let isFenced = cmark_node_get_fenced(node, &fenceLength, &fenceOffset, &fenceCharacter) != 0
        // Тело и отрезки по литералу cmark; не подтвердилось — блок без позиций тела (`isUnreliable`), строки целиком.
        if let layout = codeBlockLayout(node, source: source, isCancelled: ctx.isCancelled), let fitted = fit(trimmedRange(layout, units: source.units), in: container), fitted.exact {
            let diagram: MarkdownDiagram.Kind? = isDocumentChild(node) && layout.markers.count == 2
                ? MarkdownDiagram.Kind(rawValue: info.trimmingCharacters(in: .whitespaces)) : nil
            let code = MarkdownBlockNode.CodeBlock(isFenced: isFenced, info: info, infoRange: layout.infoRange, isClosed: layout.isClosed,
                                                   bodySegments: layout.bodySegments, bodyPadding: layout.bodyPadding, literal: body, diagram: diagram)
            return finish(.codeBlock(code), fitted.range, false, layout.markers, [], [], true)
        }
        var range = NSRange(location: source.firstPosition(node) ?? container.location, length: 0)
        if let lines = source.wholeLines(node), let fitted = fit(lines, in: container) { range = fitted.range }
        let code = MarkdownBlockNode.CodeBlock(isFenced: isFenced, info: info, infoRange: nil, isClosed: false, bodySegments: [], bodyPadding: [],
                                               literal: body, diagram: nil)
        return finish(.codeBlock(code), range, true, [], [], [], true)
    }

    /// Как у остальных листовых блоков, диапазон узла не включает перевод строки в конце; в раскладке у незакрытого блока он входит.
    private static func trimmedRange(_ layout: CodeBlockLayout, units: [UInt16]) -> NSRange {
        var range = layout.range
        guard !layout.isClosed, range.length > 0 else { return range }
        let last = NSMaxRange(range) - 1
        if units[last] == 10 || units[last] == 13 {
            range.length -= units[last] == 10 && last > range.location && units[last - 1] == 13 ? 2 : 1
        }
        return range
    }

    // MARK: Таблица

    private static func tableBlock(_ node: OpaquePointer, range: NSRange, ctx: Context) -> MarkdownBlockNode.Table {
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
        var rows: [MarkdownBlockNode.Table.Row] = []
        var delimiter = NSRange(location: range.location, length: 0)
        var delimiterFound = false
        for rowNode in childNodes(of: node) {
            if ctx.stop() { break }
            let isHeader = cmark_gfm_extensions_get_table_row_is_header(UnsafeMutablePointer<cmark_node>(rowNode)) != 0
            var rowRange = blockRange(rowNode, container: range, ctx: ctx).range
            // У заголовка таблицы, прервавшей абзац, cmark ставит позиции абзаца и конец таблицы: строка заголовка одна, отступ у неё свой.
            if isHeader, Int(cmark_node_get_start_line(rowNode)) - 1 < ctx.source.tableFirstLine(node) {
                let source = ctx.source
                let line = source.tableFirstLine(node)
                if line < source.lineStarts.count, var start = source.utf16Offset(at: source.lineStarts[line]), let stop = source.utf16Offset(at: source.lineEnds[line]) {
                    while start < stop, source.units[start] == 32 || source.units[start] == 9 { start += 1 }
                    if range.location >= start, range.location < stop { start = range.location }
                    rowRange = NSRange(location: start, length: max(0, stop - start))
                }
            }
            if isHeader, !delimiterFound {
                delimiterFound = true
                if let found = delimiterRange(header: rowNode, ctx: ctx), let fitted = fit(found, in: range), fitted.exact { delimiter = found } else { delimiterFound = false }
            }
            var cells: [MarkdownBlockNode.Table.Cell] = []
            for (column, cellNode) in childNodes(of: rowNode).enumerated() {
                let positions = ctx.tablePositions(cellNode)
                var cellRange = rowRange
                if let positions, let first = positions.offsets.first.flatMap(ctx.source.utf16Offset), let last = positions.offsets.last.flatMap(ctx.source.utf16Offset),
                   last >= first, let fitted = fit(NSRange(location: first, length: last - first), in: rowRange), fitted.exact {
                    cellRange = fitted.range
                }
                let colspan = cmark_gfm_extensions_get_table_cell_colspan(UnsafeMutablePointer<cmark_node>(cellNode))
                let rowspan = cmark_gfm_extensions_get_table_cell_rowspan(UnsafeMutablePointer<cmark_node>(cellNode))
                let columnSpan = colspan == UInt32.max ? 1 : Int(colspan)
                let rowSpan = rowspan == UInt32.max ? 1 : Int(rowspan)
                let converted = inlines(of: childNodes(of: cellNode), container: cellRange, scope: InlineScope(lazy: nil, positions: positions), imageBlock: false, ctx: ctx)
                cells.append(MarkdownBlockNode.Table.Cell(range: cellRange, contentRange: trimmed(cellRange, ctx: ctx), column: column,
                                                          virtualSeparators: max(0, columnSpan - 1), colspan: columnSpan, rowspan: rowSpan,
                                                          isPadding: cmark_node_get_start_column(cellNode) == 0, inlines: converted))
            }
            rows.append(MarkdownBlockNode.Table.Row(range: rowRange, isHeader: isHeader, cells: cells))
        }
        return MarkdownBlockNode.Table(alignments: alignments, delimiterRange: delimiter, rows: rows)
    }

    /// Конец строки (без перевода строки), в которой стоит позиция.
    private static func lineEnd(after position: Int, ctx: Context) -> Int {
        let units = ctx.source.units
        var end = min(max(position, 0), units.count)
        while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
        return end
    }

    /// Конец строки перед той, в которой стоит позиция (без перевода строки; `\r\n` целиком вне диапазона).
    private static func lineEnd(before position: Int, ctx: Context) -> Int {
        let units = ctx.source.units
        var end = min(max(position, 0), units.count)
        while end > 0, units[end - 1] != 10, units[end - 1] != 13 { end -= 1 }
        while end > 0, units[end - 1] == 10 || units[end - 1] == 13 { end -= 1 }
        return end
    }

    /// Строка-разделитель таблицы: следующая за заголовком, от столбца заголовка до конца строки.
    private static func delimiterRange(header: OpaquePointer, ctx: Context) -> NSRange? {
        let source = ctx.source
        // Разделитель идёт за строкой заголовка; у заголовка таблицы, прервавшей абзац, начало узла стоит на строке абзаца.
        let line = max(Int(cmark_node_get_start_line(header)), cmark_node_parent(header).map { source.tableFirstLine($0) + 1 } ?? 0)
        guard line >= 1, line < source.lineStarts.count,
              let start = source.utf16Offset(at: source.lineStarts[line]), let end = source.utf16Offset(at: source.lineEnds[line]), end >= start else { return nil }
        // Вся строка, с префиксом цитаты и отступом: редактор прячет строку разделителя по этому диапазону.
        return NSRange(location: start, length: end - start)
    }

    private static func trimmed(_ range: NSRange, ctx: Context) -> NSRange {
        let units = ctx.source.units
        guard range.location >= 0, NSMaxRange(range) <= units.count else { return range }
        var start = range.location, end = NSMaxRange(range)
        while start < end, units[start] == 32 || units[start] == 9 { start += 1 }
        while end > start, units[end - 1] == 32 || units[end - 1] == 9 { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Префиксы контейнеров

    /// По строке на каждую строку листового блока внутри цитаты или пункта: сколько знаков занимает префикс
    /// (`> `, отступ пункта) и чем он заменяется на строках продолжения.
    private static func containerPrefixes(_ node: OpaquePointer, range: NSRange, ctx: Context) -> [MarkdownBlockNode.ContainerPrefix] {
        let units = ctx.source.units
        guard range.location >= 0, range.location <= units.count, NSMaxRange(range) <= units.count else { return [] }
        var first = range.location
        while first > 0 && units[first - 1] != 10 && units[first - 1] != 13 { first -= 1 }
        var prefixEnd = range.location
        // Первый абзац задачи: флажок `[ ]` не префикс.
        if let parent = cmark_node_parent(node), cmarkType(parent) == CMARK_NODE_ITEM, cmark_node_first_child(parent) == node,
           let checkbox = ctx.source.taskCheckbox(parent), checkbox.markerRange.location >= first, checkbox.markerRange.location < prefixEnd {
            prefixEnd = checkbox.markerRange.location
        }
        let prefix = Array(units[first..<prefixEnd])
        let continuation = String(decoding: prefix.map { $0 == 62 || $0 == 32 || $0 == 9 ? $0 : 32 }, as: UTF16.self)
        let quotes = prefix.filter { $0 == 62 }.count
        var result: [MarkdownBlockNode.ContainerPrefix] = []
        var lineStart = first
        var isFirst = true
        while lineStart <= units.count, isFirst || lineStart < NSMaxRange(range) {
            var lineEnd = lineStart
            while lineEnd < units.count && units[lineEnd] != 10 && units[lineEnd] != 13 { lineEnd += 1 }
            var length = 0
            if isFirst { length = prefixEnd - lineStart } else {
                var cursor = lineStart, seen = 0
                while cursor < lineEnd, cursor - lineStart < prefix.count {
                    if units[cursor] == 62, seen < quotes { seen += 1 } else if units[cursor] != 32 && units[cursor] != 9 { break }
                    cursor += 1
                }
                length = cursor - lineStart
            }
            result.append(MarkdownBlockNode.ContainerPrefix(line: NSRange(location: lineStart, length: lineEnd - lineStart), prefixLength: length, continuation: continuation))
            isFirst = false
            var next = lineEnd
            if next < units.count { next += (units[next] == 13 && next + 1 < units.count && units[next + 1] == 10) ? 2 : 1 }
            if next <= lineStart || next >= units.count { break }
            lineStart = next
        }
        return result
    }

    // MARK: Комментарии `%%…%%` на целых строках

    private static func insertComment(_ segment: MarkdownSourceMask.Segment, into nodes: inout [MarkdownBlockNode]) {
        let range = segment.range
        for index in nodes.indices {
            guard NSLocationInRange(range.location, nodes[index].range), NSMaxRange(range) <= NSMaxRange(nodes[index].range) else { continue }
            switch nodes[index].kind {
            case .quote, .callout, .alert, .list, .listItem, .footnoteDefinition:
                insertComment(segment, into: &nodes[index].children)
            default:
                // Внутри листового блока комментарий строчный: остаётся текстом узла (подзадача b).
                break
            }
            return
        }
        let block = MarkdownBlockNode(kind: .comment, range: range, markerRanges: segment.markerRanges, containerPrefixes: [], children: [], inlines: [], isUnreliable: false)
        let position = nodes.firstIndex(where: { $0.range.location > range.location }) ?? nodes.count
        nodes.insert(block, at: position)
    }

    // MARK: - Строчные узлы

    /// Откуда брать диапазоны строчных узлов: ячейка таблицы или абзац с ленивым продолжением в контейнере.
    private struct InlineScope {
        var lazy: [OpaquePointer: NSRange]?
        var positions: MarkdownSourcePositions.TableCellPositions?
        /// В абзаце есть определения ссылок перед текстом: позиций строчных узлов у cmark нет, границы ищутся по маркерам и литералам.
        var afterReferences = false
    }

    private static func paragraphScope(_ paragraph: OpaquePointer, ctx: Context) -> InlineScope {
        InlineScope(lazy: ctx.source.lazyParagraphInlineRanges(paragraph, text: ctx.masked, plainEditing: true, inlineMath: ctx.mathInline,
                                                               referenceLinks: true, isCancelled: ctx.isCancelled), positions: nil,
                    afterReferences: ctx.source.referencePrefix(paragraph) != nil)
    }

    private static func inlineRange(_ node: OpaquePointer, scope: InlineScope, ctx: Context) -> NSRange? {
        if let range = scope.lazy?[node] { return range }
        let source = ctx.source
        if let math = ctx.mathInline[node], let parent = cmark_node_parent(node) {
            return source.mathInlineRange(line: math.line, column: math.column, byteLength: math.byteLength, parent: parent, tablePositions: scope.positions)
        }
        if let positions = scope.positions {
            // Голая ссылка в ячейке: её колонки у cmark-gfm локальны, диапазон берётся по концу и литералу.
            if cmarkType(node) == CMARK_NODE_LINK, let range = source.linkRange(node, tableCell: nil, tablePositions: positions) { return range }
            return source.tableInlineRange(node, positions: positions)
        }
        if cmarkType(node) == CMARK_NODE_LINK, let range = source.linkRange(node, tableCell: nil) { return range }
        // Код в абзаце после определений ссылок с табом: правка текста там не подтверждена, но позиция кода восстановлена.
        if let range = source.editingTextRange(node) { return range }
        return cmarkType(node) == CMARK_NODE_CODE ? source.range(node) : nil
    }

    /// Строчные узлы списка соседей одного родителя. `previousEnd` — конец узла перед первым (для переносов строк).
    private static func inlines(of nodes: [OpaquePointer], container: NSRange, scope: InlineScope, imageBlock: Bool, ctx: Context,
                                previousEnd: Int? = nil) -> [MarkdownInlineNode] {
        var result: [MarkdownInlineNode] = []
        var lastEnd = previousEnd
        // Слитые теги HTML (пары, media, svg, ruby) занимают несколько соседей: в `kept` остаётся открывающий узел.
        var kept: [OpaquePointer] = [], index = 0
        let positions = ctx.html == nil ? [:] : Dictionary(nodes.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        while index < nodes.count {
            if ctx.stop() { return result }
            let node = nodes[index]
            // Пустой текст остаётся от голой ссылки в начале абзаца: узла в исходнике у него нет.
            if cmarkType(node) == CMARK_NODE_TEXT, literal(node).isEmpty { index += 1; continue }
            let converted: MarkdownInlineNode
            if let merged = htmlInline(nodes, positions: positions, at: index, ctx: ctx, children: { ctx.inlineState.pairDepth += 1; defer { ctx.inlineState.pairDepth -= 1 }
                return inlines(of: $0, container: $1, scope: scope, imageBlock: false, ctx: ctx, previousEnd: $2) }) {
                converted = merged.node
                index = merged.next
            } else {
                converted = inline(node, container: container, scope: scope, previousEnd: lastEnd, imageBlock: imageBlock && nodes.count == 1, ctx: ctx)
                index += 1
            }
            result.append(converted)
            kept.append(node)
            if !converted.isUnreliable { lastEnd = NSMaxRange(converted.range) }
        }
        return refineInlines(result, nodes: kept, container: container, ctx: ctx)
    }

    private static func inline(_ node: OpaquePointer, container: NSRange, scope: InlineScope, previousEnd: Int?, imageBlock: Bool, ctx: Context) -> MarkdownInlineNode {
        let source = ctx.source
        let nodeType = cmarkType(node)
        if nodeType == CMARK_NODE_SOFTBREAK || nodeType == CMARK_NODE_LINEBREAK {
            ctx.flagUnreliable(node)
            return lineBreak(hard: nodeType == CMARK_NODE_LINEBREAK, container: container, previousEnd: previousEnd, ctx: ctx)
        }
        var fitted = inlineRange(node, scope: scope, ctx: ctx).flatMap { fit($0, in: container) }
        // Зачёркивание на нескольких строках: cmark-gfm даёт ему конец первой строки, и дети вышли бы за границы. Позиции нет, дети берут границы родителя.
        if fitted != nil, nodeType != CMARK_NODE_TEXT, nodeType != CMARK_NODE_CODE, nodeType != CMARK_NODE_EMPH, nodeType != CMARK_NODE_STRONG,
           nodeType != CMARK_NODE_LINK, typeName(node) == "strikethrough", containsLineBreak(node) { fitted = nil }
        if nodeType == CMARK_NODE_TEXT {
            if let current = fitted, current.exact { fitted = (trimmedText(current.range, literal: literal(node), ctx: ctx), true) }
            // Позиции cmark на следующих строках абзаца бывают недоступны: ищем литерал сразу за предыдущим узлом.
            else if let found = followingText(literal(node), from: previousEnd ?? container.location, in: container, ctx: ctx) { fitted = (found, true) }
            if !(fitted?.exact ?? false), let found = ctx.tabbedTextRange(node, literal: literal(node)).flatMap({ fit($0, in: container) }), found.exact { fitted = found }
        }
        // Текст перед голой ссылкой (автоссылка GFM): cmark оставляет ему старый конец внутри ссылки. Границей служит подтверждённое
        // начало ссылки: между текстом и ссылкой ничего нет, значит, конец текста — начало ссылки (так же в MarkdownTextSourceCapture).
        if nodeType == CMARK_NODE_TEXT, let current = fitted, current.exact, let next = cmark_node_next(node), cmarkType(next) == CMARK_NODE_LINK,
           let linkRange = inlineRange(next, scope: scope, ctx: ctx).flatMap({ fit($0, in: container) }), linkRange.exact, isBareLink(linkRange.range, ctx: ctx),
           linkRange.range.location >= current.range.location, linkRange.range.location < NSMaxRange(current.range) {
            fitted = (NSRange(location: current.range.location, length: linkRange.range.location - current.range.location), true)
        }
        // Выделение без позиции cmark (абзац с определениями ссылок и табами): границы берём по маркерам от конца предыдущего узла.
        var recoveredChildren: [MarkdownInlineNode]?
        if scope.afterReferences, !(fitted?.exact ?? false), nodeType == CMARK_NODE_EMPH || nodeType == CMARK_NODE_STRONG, let start = previousEnd,
           let found = emphasisAfter(node, strong: nodeType == CMARK_NODE_STRONG, start: start, container: container, scope: scope, ctx: ctx) {
            recoveredChildren = found.children
            if let range = found.range { fitted = (range, true) }
        }
        let reliable = fitted?.exact ?? false
        let range = fitted?.range ?? container
        // Голая ссылка (автоссылка GFM) с точным диапазоном в начале абзаца не получает позицию от cmark, но границы известны.
        if nodeType != CMARK_NODE_TEXT, !(nodeType == CMARK_NODE_LINK && reliable && isBareLink(range, ctx: ctx)) { ctx.flagUnreliable(node) }

        func make(_ kind: MarkdownInlineNode.Kind, markers: [NSRange] = [], children: [MarkdownInlineNode] = [], track: Bool = false) -> MarkdownInlineNode {
            return MarkdownInlineNode(kind: kind, range: range, markerRanges: reliable ? markers : [], children: children, isUnreliable: !reliable)
        }
        func converted() -> [MarkdownInlineNode] { recoveredChildren ?? inlines(of: childNodes(of: node), container: range, scope: scope, imageBlock: false, ctx: ctx) }

        if nodeType == CMARK_NODE_TEXT {
            var value = literal(node)
            // Сознательное упрощение подзадачи a: при заменителе берём подстроку исходника. В b текстовые узлы
            // режутся по сегментам маски, и вне сегментов текст — литерал cmark, так что заменителя в .text не останется.
            if !ctx.mask.isIdentity, value.contains(ctx.placeholder) {
                value = reliable ? (ctx.substring(range) ?? ctx.clean(value)) : ctx.clean(value)
            }
            return make(.text(value), track: true)
        }
        if nodeType == CMARK_NODE_CODE {
            let value = literal(node)
            guard reliable else { return make(.code(value), track: true) }
            if let (outer, markers) = source.codeRange(range), outer.location >= container.location, NSMaxRange(outer) <= NSMaxRange(container) {
                return MarkdownInlineNode(kind: .code(value), range: outer, markerRanges: markers, children: [], isUnreliable: false)
            }
            return make(.code(value), markers: ticks(range, ctx: ctx))
        }
        if nodeType == CMARK_NODE_EMPH || nodeType == CMARK_NODE_STRONG {
            let strong = nodeType == CMARK_NODE_STRONG
            let made = make(strong ? .strong : .emphasis, markers: edgeMarkers(range, characters: [42, 95], counts: strong ? [2] : [1], ctx: ctx),
                            children: converted(), track: true)
            if let parent = cmark_node_parent(node), cmarkType(parent) == CMARK_NODE_EMPH || cmarkType(parent) == CMARK_NODE_STRONG { return made }
            return separatingEmphasisEdges(made)
        }
        if nodeType == CMARK_NODE_LINK { return link(node, range: range, reliable: reliable, scope: scope, ctx: ctx) }
        if nodeType == CMARK_NODE_IMAGE { return image(node, range: range, reliable: reliable, imageBlock: imageBlock, ctx: ctx) }
        if nodeType == CMARK_NODE_FOOTNOTE_REFERENCE {
            var markers: [NSRange] = []
            if reliable, range.length >= 4, ctx.substring(NSRange(location: range.location, length: 2)) == "[^", ctx.substring(NSRange(location: NSMaxRange(range) - 1, length: 1)) == "]" {
                markers = [NSRange(location: range.location, length: 2), NSRange(location: NSMaxRange(range) - 1, length: 1)]
            }
            let definition = cmark_node_parent_footnote_def(node)
            let definitionMarker = definition.flatMap { source.footnoteDefinitionMarker($0) }
            // Номер сноски cmark (до подмены метки ниже): порядок первых ссылок в документе, ссылки в телах определений тоже считаются.
            if reliable, let definitionMarker, ctx.footnoteNumbers[definitionMarker] == nil, let number = Int(literal(node)) {
                ctx.footnoteNumbers[definitionMarker] = number
            }
            if reliable, ctx.unsupportedDepth == 0, let definition, let definitionMarker {
                ctx.footnotes.append(MarkdownFootnote(referenceRange: range, definitionRange: definitionMarker, text: ctx.clean(footnoteText(definition))))
            }
            // cmark подменяет метку ссылки порядковым номером: настоящая метка — у определения, иначе срез `[^метка]` при надёжной позиции.
            var label = literal(node)
            if let definition { label = literal(definition) }
            else if markers.count == 2 { label = ctx.substring(NSRange(location: range.location + 2, length: range.length - 3)) ?? label }
            return make(.footnoteReference(label: label), markers: markers, track: true)
        }
        if nodeType == CMARK_NODE_HTML_INLINE {
            // Подтверждённые пары и слитые теги собирает `inlines(of:)`; здесь остаётся одиночный тег.
            return make(.rawHTML(literal(node)))
        }
        if nodeType == CMARK_NODE_CUSTOM_INLINE, let math = ctx.mathInline[node] {
            return make(.formula(source: ctx.clean(math.text)), track: true)
        }
        if typeName(node) == "strikethrough" {
            // Нижний индекс определяется по сырым детям cmark: эмодзи и другие правки в детях его не отменяют.
            let isSubscript = reliable && subscriptRange(node, source: source, text: ctx.masked, mappedRange: range,
                                                         mappedChild: NSRange(location: range.location + 1, length: range.length - 2)) != nil
            let kids = converted()
            if isSubscript {
                return make(.subscriptText, markers: edgeMarkers(range, characters: [126], counts: [1], ctx: ctx), children: kids, track: true)
            }
            return make(.strikethrough, markers: edgeMarkers(range, characters: [126], counts: [2, 1], ctx: ctx), children: kids, track: true)
        }
        // Неизвестный строчный узел: теряем только вид, а не текст.
        return make(.text(ctx.substring(range) ?? literal(node)), children: converted())
    }

    /// `*…*`/`**…**` (или `_`), начинающееся в `start` (после отступа и переносов строк): дети разбираются от маркера, закрывающий маркер ищется за последним ребёнком.
    /// `range == nil` — маркера нет или он не закрыт: дети всё равно возвращаются (их нельзя разбирать дважды).
    private static func emphasisAfter(_ node: OpaquePointer, strong: Bool, start origin: Int, container: NSRange, scope: InlineScope,
                                      ctx: Context) -> (range: NSRange?, children: [MarkdownInlineNode])? {
        let units = ctx.source.units, count = strong ? 2 : 1
        guard origin >= container.location else { return nil }
        // Маркер может стоять после отступа, `>` цитаты и переноса строки (как ищет литерал `followingText`).
        let start = skippingLinePrefix(from: origin, end: min(NSMaxRange(container), units.count), ctx: ctx)
        guard start + count < min(NSMaxRange(container), units.count),
              units[start] == 42 || units[start] == 95, (0..<count).allSatisfy({ units[start + $0] == units[start] }) else { return nil }
        let children = inlines(of: childNodes(of: node), container: container, scope: scope, imageBlock: false, ctx: ctx, previousEnd: start + count)
        guard let last = children.last, !last.isUnreliable else { return (nil, children) }
        let end = NSMaxRange(last.range)
        guard end + count <= min(NSMaxRange(container), units.count), (0..<count).allSatisfy({ units[end + $0] == units[start] }) else { return (nil, children) }
        return (NSRange(location: start, length: end + count - start), children)
    }

    private static func isBareLink(_ range: NSRange, ctx: Context) -> Bool {
        guard range.length > 0, range.location < ctx.source.units.count else { return false }
        let first = ctx.source.units[range.location]
        return first != 91 && first != 60
    }

    /// cmark иногда включает в текст пробелы перед жёстким переносом: оставляем ровно литерал.
    private static func trimmedText(_ range: NSRange, literal: String, ctx: Context) -> NSRange {
        let length = (literal as NSString).length
        guard length > 0, range.length > length, ctx.substring(NSRange(location: range.location, length: length)) == literal else { return range }
        let tail = ctx.source.units[(range.location + length)..<NSMaxRange(range)]
        guard tail.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }) else { return range }
        return NSRange(location: range.location, length: length)
    }

    /// Текст, который идёт сразу после `from` через пробелы, переводы строк и `>` цитат (только в начале строки).
    private static func followingText(_ literal: String, from: Int, in container: NSRange, ctx: Context) -> NSRange? {
        let units = ctx.source.units, length = (literal as NSString).length
        guard length > 0, from >= container.location else { return nil }
        // Перенос строки перед `from` уже пройден предыдущим узлом (softBreak), значит, мы в начале строки.
        // Литерал может начинаться с пробела (` текст` после `*а*`): сначала проверяем совпадение прямо в `from`.
        if from + length <= min(NSMaxRange(container), units.count), ctx.substring(NSRange(location: from, length: length)) == literal,
           let found = ctx.entityExtended(NSRange(location: from, length: length), literal: literal), NSMaxRange(found) <= min(NSMaxRange(container), units.count) {
            return found
        }
        let end = min(NSMaxRange(container), units.count)
        let index = skippingLinePrefix(from: from, end: end, ctx: ctx)
        guard index + length <= end, ctx.substring(NSRange(location: index, length: length)) == literal,
              let found = ctx.entityExtended(NSRange(location: index, length: length), literal: literal), NSMaxRange(found) <= end else { return nil }
        return found
    }

    /// Позиция за пробелами, табами, переводами строк и `>` цитат (только в начале строки), начиная с `from`.
    private static func skippingLinePrefix(from: Int, end: Int, ctx: Context) -> Int {
        let units = ctx.source.units
        var index = from, atLineStart = from > 0 && from <= units.count && (units[from - 1] == 10 || units[from - 1] == 13)
        while index < end {
            let unit = units[index]
            if unit == 10 || unit == 13 { atLineStart = true }
            else if unit == 32 || unit == 9 {}
            else if unit == 62 && atLineStart {}
            else { break }
            index += 1
        }
        return index
    }

    /// Перенос строки: только символ(ы) конца строки; у жёсткого — вместе с пробелами или `\` перед ним.
    private static func lineBreak(hard: Bool, container: NSRange, previousEnd: Int?, ctx: Context) -> MarkdownInlineNode {
        let units = ctx.source.units
        let kind: MarkdownInlineNode.Kind = hard ? .hardBreak : .softBreak
        if let previousEnd, previousEnd >= container.location, NSMaxRange(container) <= units.count {
            var newline = previousEnd
            while newline < NSMaxRange(container) && units[newline] != 10 && units[newline] != 13 {
                if units[newline] != 32 && units[newline] != 9 && units[newline] != 92 { break }
                newline += 1
            }
            if newline < NSMaxRange(container), units[newline] == 10 || units[newline] == 13 {
                var end = newline + 1
                if units[newline] == 13, end < units.count, units[end] == 10 { end += 1 }
                var start = newline
                if hard {
                    while start > previousEnd, units[start - 1] == 32 || units[start - 1] == 9 { start -= 1 }
                    if start > previousEnd, units[start - 1] == 92 { start -= 1 }
                }
                return MarkdownInlineNode(kind: kind, range: NSRange(location: start, length: end - start), markerRanges: [], children: [], isUnreliable: false)
            }
        }
        return MarkdownInlineNode(kind: kind, range: NSRange(location: container.location, length: 0), markerRanges: [], children: [], isUnreliable: true)
    }

    private static func ticks(_ range: NSRange, ctx: Context) -> [NSRange] {
        let units = ctx.source.units
        guard range.location >= 0, NSMaxRange(range) <= units.count else { return [] }
        var open = 0
        while open < range.length, units[range.location + open] == 96 { open += 1 }
        var close = 0
        while close < range.length - open, units[NSMaxRange(range) - 1 - close] == 96 { close += 1 }
        guard open > 0, open == close else { return [] }
        return [NSRange(location: range.location, length: open), NSRange(location: NSMaxRange(range) - close, length: close)]
    }

    /// Своя функция, а не `pairedMarkers` позиций: та отвергает `***a***` (знак сразу за краем), а в cmark это emph вокруг strong
    /// с общим диапазоном из семи знаков, и маркеры эмфазы должны остаться.
    /// Парные знаки по краям диапазона (`**`, `_`, `~~`): подряд идущих по краям ровно столько, сколько у вида.
    /// cmark отдаёт вложенному `*`/`_` край родителя (`***a***`, `*a **b***`): маркеры совпадали бы. Диапазон узла остаётся,
    /// маркеры ребёнка сдвигаются внутрь, за маркеры родителя.
    private static func separatingEmphasisEdges(_ node: MarkdownInlineNode) -> MarkdownInlineNode {
        guard node.markerRanges.count == 2 else { return node }
        var node = node
        for index in node.children.indices {
            var child = node.children[index]
            switch child.kind {
            case .strong, .emphasis: break
            default: continue
            }
            guard child.markerRanges.count == 2 else { continue }
            var opening = child.markerRanges[0], closing = child.markerRanges[1]
            if child.range.location == node.range.location { opening.location = NSMaxRange(node.markerRanges[0]) }
            if NSMaxRange(child.range) == NSMaxRange(node.range) { closing.location = node.markerRanges[1].location - closing.length }
            if (opening != child.markerRanges[0] || closing != child.markerRanges[1]), opening.location >= child.range.location,
               NSMaxRange(opening) <= closing.location, NSMaxRange(closing) <= NSMaxRange(child.range) {
                child.markerRanges = [opening, closing]
            }
            node.children[index] = separatingEmphasisEdges(child)
        }
        return node
    }

    private static func edgeMarkers(_ range: NSRange, characters: [UInt16], counts: [Int], ctx: Context) -> [NSRange] {
        let units = ctx.source.units
        guard range.location >= 0, NSMaxRange(range) <= units.count else { return [] }
        for count in counts {
            guard range.length > count * 2, characters.contains(units[range.location]) else { continue }
            let character = units[range.location]
            let opening = units[range.location..<range.location + count], closing = units[NSMaxRange(range) - count..<NSMaxRange(range)]
            guard opening.allSatisfy({ $0 == character }), closing.allSatisfy({ $0 == character }) else { continue }
            return [NSRange(location: range.location, length: count), NSRange(location: NSMaxRange(range) - count, length: count)]
        }
        return []
    }

    /// Маркеры `>` цитаты: у вложенной цитаты на строке продолжения первый `>` уже занят внешней, берётся следующий (если его нет — ленивое продолжение).
    private static func quoteMarkers(_ range: NSRange, ctx: Context) -> [NSRange] {
        let units = ctx.source.units, end = NSMaxRange(range)
        var result: [NSRange] = []
        for var marker in ctx.source.quoteMarkers(range) {
            var found = true
            while ctx.claimedQuoteMarkers.contains(marker.location) {
                var next = NSMaxRange(marker)
                while next < end, units[next] == 32 || units[next] == 9 { next += 1 }
                guard next < end, units[next] == 62 else { found = false; break }
                marker = NSRange(location: next, length: 1)
            }
            if found { ctx.claimedQuoteMarkers.insert(marker.location); result.append(marker) }
        }
        return result
    }

    // MARK: Ссылка и изображение

    private static func link(_ node: OpaquePointer, range: NSRange, reliable: Bool, scope: InlineScope, ctx: Context) -> MarkdownInlineNode {
        let url = ctx.clean(cmark_node_get_url(node).map { String(cString: $0) } ?? "")
        let title = cmark_node_get_title(node).map { ctx.clean(String(cString: $0)) }.flatMap { $0.isEmpty ? nil : $0 }
        // Текст ссылки `[…]` идёт сразу за скобкой: от неё его ищут, когда у cmark нет позиции (абзац с определениями ссылок).
        let opensWithBracket = scope.afterReferences && reliable && range.length > 0 && ctx.source.units.count > range.location && ctx.source.units[range.location] == 91
        var children = inlines(of: childNodes(of: node), container: range, scope: scope, imageBlock: false, ctx: ctx,
                               previousEnd: opensWithBracket ? range.location + 1 : nil)
        // У голой ссылки текст ребёнка и есть вся ссылка; колонки cmark-gfm у него локальны, поэтому берём диапазон ссылки.
        if reliable, isBareLink(range, ctx: ctx), children.count == 1, case let .text(value) = children[0].kind, ctx.substring(range) == value {
            children[0].range = range
            children[0].isUnreliable = false
        }
        var form = MarkdownInlineNode.Link.Form.autolink
        var markers: [NSRange] = []
        var destination: NSRange?
        if reliable, let first = ctx.substring(NSRange(location: range.location, length: 1)) {
            let units = ctx.source.units
            if first == "[" {
                let found = ctx.source.linkMarkers(range, node: node) { child in
                    scope.positions.flatMap { ctx.source.tableInlineRange(child, positions: $0) } ?? ctx.source.editingTextRange(child)
                }
                if found.count == 2 {
                    form = .inline
                    markers = found
                    destination = destinationRange(in: found[1], ctx: ctx)
                } else {
                    form = .reference
                    if let close = closingBracket(from: range.location, end: NSMaxRange(range), ctx: ctx) {
                        markers = [NSRange(location: range.location, length: 1), NSRange(location: close, length: NSMaxRange(range) - close)]
                        // Страховка: у `[](u)` нет текстового ребёнка, и `linkMarkers` маркеры не находит, а форма всё равно inline.
                        if close + 1 < NSMaxRange(range), units[close + 1] == 40, units[NSMaxRange(range) - 1] == 41 {
                            form = .inline
                            destination = destinationRange(in: markers[1], ctx: ctx)
                        }
                    }
                }
            } else if first == "<", NSMaxRange(range) <= units.count, units[NSMaxRange(range) - 1] == 62 {
                markers = [NSRange(location: range.location, length: 1), NSRange(location: NSMaxRange(range) - 1, length: 1)]
            }
        }
        let data = MarkdownInlineNode.Link(url: url, title: title, form: form, destinationRange: destination)
        return MarkdownInlineNode(kind: .link(data), range: range, markerRanges: markers, children: children, isUnreliable: !reliable)
    }

    private static func image(_ node: OpaquePointer, range: NSRange, reliable: Bool, imageBlock: Bool, ctx: Context) -> MarkdownInlineNode {
        let url = ctx.clean(cmark_node_get_url(node).map { String(cString: $0) } ?? "")
        let title = cmark_node_get_title(node).map { ctx.clean(String(cString: $0)) }.flatMap { $0.isEmpty ? nil : $0 }
        var markers: [NSRange] = []
        var address: NSRange?
        var syntax = MarkdownInlineNode.Image.Syntax.markdown
        if reliable, range.length >= 4, ctx.substring(NSRange(location: range.location, length: 2)) == "![",
           let close = closingBracket(from: range.location + 1, end: NSMaxRange(range), ctx: ctx) {
            let suffix = NSRange(location: close, length: NSMaxRange(range) - close)
            markers = [NSRange(location: range.location, length: 2), suffix]
            if ctx.substring(NSRange(location: close, length: min(2, suffix.length))) == "](" { address = destinationRange(in: suffix, ctx: ctx) } else { syntax = .reference }
        }
        let data = MarkdownInlineNode.Image(url: url, alt: ctx.clean(plainText(node)), title: title, syntax: syntax, addressRange: address, sizing: nil, isBlock: imageBlock)
        return MarkdownInlineNode(kind: .image(data), range: range, markerRanges: markers, children: [], isUnreliable: !reliable)
    }

    /// Позиция `]`, парной `[` в начале (знаки с `\` перед ними пропускаются).
    private static func closingBracket(from open: Int, end: Int, ctx: Context) -> Int? {
        let units = ctx.source.units
        guard open >= 0, end <= units.count, open < end, units[open] == 91 else { return nil }
        var depth = 0, index = open
        while index < end {
            let unit = units[index]
            if unit == 92 { index += 2; continue }
            if unit == 91 { depth += 1 } else if unit == 93 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Адрес в хвосте `](адрес "название")`: как написан, без `<>` у адреса в угловых скобках.
    private static func destinationRange(in suffix: NSRange, ctx: Context) -> NSRange? {
        let units = ctx.source.units
        guard suffix.length >= 3, NSMaxRange(suffix) <= units.count, units[suffix.location + 1] == 40, units[NSMaxRange(suffix) - 1] == 41 else { return nil }
        var start = suffix.location + 2
        let limit = NSMaxRange(suffix) - 1
        while start < limit, units[start] == 32 || units[start] == 9 || units[start] == 10 || units[start] == 13 { start += 1 }
        var end = start
        if start < limit, units[start] == 60 {
            start += 1
            end = start
            while end < limit, units[end] != 62 { end += 1 }
        } else {
            var depth = 0
            while end < limit {
                let unit = units[end]
                if unit == 92 { end += 2; continue }
                if unit == 32 || unit == 9 || unit == 10 || unit == 13 { break }
                if unit == 40 { depth += 1 } else if unit == 41 { if depth == 0 { break }; depth -= 1 }
                end += 1
            }
            end = min(end, limit)
        }
        return end >= start ? NSRange(location: start, length: end - start) : nil
    }

    /// Описание изображения как plain-вывод cmark: text, code, html_inline; переносы — пробел, остальное пусто.
    private static func plainText(_ node: OpaquePointer) -> String {
        var result = ""
        func append(_ current: OpaquePointer) {
            let currentType = cmarkType(current)
            if currentType == CMARK_NODE_TEXT || currentType == CMARK_NODE_CODE || currentType == CMARK_NODE_HTML_INLINE { result += literal(current) }
            else if currentType == CMARK_NODE_SOFTBREAK || currentType == CMARK_NODE_LINEBREAK { result += " " }
            for child in childNodes(of: current) { append(child) }
        }
        for child in childNodes(of: node) { append(child) }
        return result
    }

    // MARK: - Общие правила
    static func alert(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString) -> (range: NSRange, marker: NSRange, label: String)? {
        guard let type = cmark_node_get_type_string(node), String(cString: type) == "block_quote",
              let parent = cmark_node_parent(node), let parentType = cmark_node_get_type_string(parent), String(cString: parentType) == "document",
              let paragraph = cmark_node_first_child(node), let paragraphType = cmark_node_get_type_string(paragraph), String(cString: paragraphType) == "paragraph",
              let marker = cmark_node_first_child(paragraph), let markerType = cmark_node_get_type_string(marker), String(cString: markerType) == "text",
              let next = cmark_node_next(marker), let nextType = cmark_node_get_type_string(next), String(cString: nextType) == "softbreak",
              cmark_node_next(next) != nil, let markerRange = source.range(marker), let blockRange = source.range(node) else { return nil }
        let raw = text.substring(with: markerRange)
        guard raw.hasPrefix("[!"), raw.hasSuffix("]"), raw.count >= 4 else { return nil }
        let label = String(raw.dropFirst(2).dropLast())
        guard ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"].contains(label) else { return nil }
        let line = text.lineRange(for: NSRange(location: markerRange.location, length: 0))
        let prefix = text.substring(with: NSRange(location: line.location, length: markerRange.location - line.location))
        guard prefix == "> " || prefix == ">" else { return nil }
        let remainder = text.substring(with: NSRange(location: NSMaxRange(markerRange), length: NSMaxRange(line) - NSMaxRange(markerRange)))
        guard remainder == "\n" || remainder == "\r" || remainder == "\r\n", NSMaxRange(line) < text.length else { return nil }
        let nextLine = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        let nextRaw = text.substring(with: nextLine)
        guard nextRaw.hasPrefix(">") else { return nil }
        return (blockRange, markerRange, label)
    }

    static func headingText(_ node: OpaquePointer, mathInline: [OpaquePointer: MarkdownMathExtension.Inline] = [:]) -> String {
        headingData(node, mathInline: mathInline, emojiByNode: [:]).title
    }

    static func headingData(_ node: OpaquePointer, mathInline: [OpaquePointer: MarkdownMathExtension.Inline],
                                    emojiByNode: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]]) -> (title: String, emoji: [MarkdownHeading.Emoji]) {
        let result = NSMutableString(string: "")
        var emoji: [MarkdownHeading.Emoji] = []
        func append(_ current: OpaquePointer) {
            if let name = cmark_node_get_type_string(current) {
                switch String(cString: name) {
                case "text", "code":
                    if let literal = cmark_node_get_literal(current) {
                        let start = result.length
                        result.append(String(cString: literal).replacingOccurrences(of: "\t", with: " "))
                        for (offset, candidate) in emojiByNode[current] ?? [] {
                            emoji.append(.init(range: NSRange(location: start + offset, length: candidate.range.length), name: candidate.name))
                        }
                    }
                case "softbreak", "linebreak": result.append(" ")
                case "custom_inline":
                    if let math = mathInline[current] { result.append("$" + math.text + "$") }
                default: break
                }
            }
            var child = cmark_node_first_child(current)
            while let next = child { append(next); child = cmark_node_next(next) }
        }
        append(node)
        let title = (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return (title, []) }
        let trimmed = result.range(of: title)
        guard trimmed.location != NSNotFound else { return (title, []) }
        let mapped = emoji.compactMap { item -> MarkdownHeading.Emoji? in
            guard item.range.location >= trimmed.location, NSMaxRange(item.range) <= NSMaxRange(trimmed) else { return nil }
            return .init(range: NSRange(location: item.range.location - trimmed.location, length: item.range.length), name: item.name)
        }
        return (title, mapped)
    }

    static func footnoteText(_ node: OpaquePointer) -> String {
        var result = ""
        func append(_ current: OpaquePointer) {
            guard let name = cmark_node_get_type_string(current) else { return }
            let type = String(cString: name)
            if ["paragraph", "heading", "code_block"].contains(type), !result.isEmpty, !result.hasSuffix("\n") {
                result += "\n"
            }
            switch type {
            case "text", "code", "code_block":
                if let literal = cmark_node_get_literal(current) { result += String(cString: literal) }
            case "softbreak", "linebreak": result += " "
            default: break
            }
            var child = cmark_node_first_child(current)
            while let next = child {
                append(next)
                child = cmark_node_next(next)
            }
        }
        append(node)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
