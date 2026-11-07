import Foundation
import cmark_gfm

/// Дополнительные данные модели (U2.5b): читаемый текст, индекс блоков, эмодзи, участки верхнего регистра, wiki-ссылки.
/// Каждый вид считается только при своём флаге `Includes`; логика лежит в общих функциях (`MarkdownDocumentExtras`,
/// читаемый текст в этом файле), общие с остальным кодом. `unreliableRanges` и `looseIndents` ядро собирает само.
extension MarkdownDocumentParser {
    /// Участки верхнего регистра заголовка (`Includes.emoji` + `.uppercaseRuns`); nil — не запрошено или заголовок не подтверждён.
    static func uppercaseRuns(_ node: OpaquePointer, title: String, supported: Bool, ctx: Context) -> [MarkdownHeading.UppercaseRun]? {
        guard supported, ctx.options.includes.isSuperset(of: [.emoji, .uppercaseRuns]), let scan = ctx.textScan, let html = ctx.html, !ctx.stop(),
              let range = ctx.source.range(node) ?? ctx.source.headingAnchor(node) else { return nil }
        // `HARDBREAKS` влияет только на вывод cmark, не на дерево: softbreak и linebreak в ядре одни и те же.
        return MarkdownDocumentExtras.uppercaseHeadingRuns(
            node, range: range, title: title, source: ctx.source, text: ctx.text, mathInline: ctx.mathInline,
            confirmedHTML: html.confirmedInline, htmlImages: html.images, preserveSoftBreaks: ctx.options.syntax.preserveEditingSoftBreaks,
            emojiByNode: scan.byNode, isCancelled: ctx.isCancelled)
    }

    /// После обхода блоков, пока дерево cmark живо: `readableText`, `blockIndex`, `emoji` по флагам.
    static func fillExtras(_ model: inout MarkdownDocumentModel, root: OpaquePointer, ext: OpaquePointer, ctx: Context) {
        let includes = ctx.options.includes
        let wantsEmoji = includes.contains(.emoji), wantsBlocks = includes.contains(.blockIndex), wantsReadable = includes.contains(.readableText)
        guard wantsEmoji || wantsBlocks || wantsReadable, !ctx.stop() else { return }
        let html = ctx.html ?? HTMLConfirmation()
        var rawHTML: [NSRange]?
        var htmlAvailable = html.rangesAvailable
        // Нужен и `blockIndex`: если границы HTML не прослежены, `hasHTML` становится true.
        if wantsEmoji || wantsBlocks {
            rawHTML = MarkdownDocumentExtras.rawHTMLRanges(htmlRanges: html.ranges.sorted { $0.location < $1.location }, available: htmlAvailable,
                                                           contextText: html.contextText, text: ctx.masked, isCancelled: ctx.isCancelled)
            if rawHTML == nil { htmlAvailable = false }
        }
        // Заменители масок (`%%…%%`, служебные знаки CriticMarkup) не текст документа: из мест текста их вычитаем,
        // из читаемого текста выбрасываем целиком (выделение с ними копируется обычным путём).
        let maskParts = ctx.mask.segments.flatMap { segment -> [NSRange] in
            switch segment.kind {
            case .frontMatter: return []
            case .comment: return [segment.range]
            case .critic(let kind): return kind == .comment ? [segment.range] : segment.markerRanges
            }
        }.sorted { $0.location < $1.location }
        var readableEnds: [Int] = [], readableUnconfirmed: [Bool] = []
        if wantsReadable {
            let masked = ctx.mask.segments.filter { $0.kind != .frontMatter }.map(\.range)
            model.readableText = readableText(
                root: root, source: ctx.source, text: ctx.text, mathExtension: ext, inlineMath: Set(ctx.mathInline.keys),
                onTopLevelBlock: wantsBlocks ? { readableEnds.append($0); readableUnconfirmed.append($1) } : nil,
                extraUnsupported: masked, isCancelled: ctx.isCancelled)
            if ctx.stop() { return }
        }
        if wantsBlocks {
            model.blockIndex = MarkdownDocumentExtras.topLevelBlocks(
                root: root, source: ctx.source, text: ctx.masked, frontMatter: model.frontMatter != nil,
                hasHTML: !html.ranges.isEmpty || !htmlAvailable, readableEnds: wantsReadable ? readableEnds : nil,
                readableUnconfirmed: readableUnconfirmed)
        }
        if wantsEmoji, let scan = ctx.textScan {
            model.emoji = MarkdownDocumentModel.EmojiData(
                candidates: scan.candidates,
                completionRanges: subtracting(scan.completionRanges, masks: maskParts).sorted { $0.location < $1.location },
                smartTextRanges: subtracting(scan.smartRanges, masks: maskParts).sorted { $0.location < $1.location },
                smartRawHTMLRanges: rawHTML)
        }
    }

    /// Диапазоны без участков `masks` (отсортированы по началу, не пересекаются).
    private static func subtracting(_ ranges: [NSRange], masks: [NSRange]) -> [NSRange] {
        guard !masks.isEmpty else { return ranges }
        var result: [NSRange] = []
        for range in ranges {
            var start = range.location
            let end = NSMaxRange(range)
            // Первая маска, которая заканчивается правее начала диапазона.
            var low = 0, high = masks.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(masks[middle]) > start { high = middle } else { low = middle + 1 }
            }
            var index = low
            while index < masks.count, masks[index].location < end {
                if masks[index].location > start { result.append(NSRange(location: start, length: masks[index].location - start)) }
                start = max(start, NSMaxRange(masks[index]))
                index += 1
            }
            if start < end { result.append(NSRange(location: start, length: end - start)) }
        }
        return result
    }
}

// Читаемый текст по готовому дереву cmark.
extension MarkdownDocumentParser {
    static func readableText(root: OpaquePointer, source: MarkdownSourcePositions, text raw: NSString,
                             mathExtension: OpaquePointer, inlineMath: Set<OpaquePointer>,
                             onTopLevelBlock: ((Int, Bool) -> Void)? = nil,
                             extraUnsupported: [NSRange] = [],
                             isCancelled: () -> Bool = { false }) -> MarkdownReadableText? {
        var fragments: [MarkdownReadableText.Fragment] = []
        // Ядро модели: участки масок (`%%…%%`, CriticMarkup) в тексте cmark заменены, копировать их как читаемые нельзя.
        var unsupported: [NSRange] = extraUnsupported
        // Узел без подтверждённой позиции получает диапазон контейнера (зависит от всего документа): такой блок локальный разбор не берёт.
        var unconfirmed = false
        func separator(_ position: Int) {
            fragments.append(.init(sourceRange: NSRange(location: position, length: 0), text: "\n", matchesSource: false))
        }
        func append(_ value: String, range: NSRange, mapInline: Bool = false) {
            guard !value.isEmpty else { return }
            let spelling = raw.substring(with: range)
            let matches = spelling == value
            let pieces = mapInline && !matches
                ? MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: value, sourceOffset: range.location, isCancelled: isCancelled)
                : nil
            fragments.append(.init(sourceRange: range, text: value, matchesSource: matches, pieces: pieces))
        }
        func visit(_ node: OpaquePointer, container: NSRange, cellPositions: MarkdownSourcePositions.TableCellPositions?) {
            guard !isCancelled() else { return }
            guard let pointer = cmark_node_get_type_string(node) else { return }
            let kind = String(cString: pointer)
            let positions = kind == "table_cell" ? source.tableCellPositions(node) : cellPositions
            let confirmed = positions.flatMap { source.tableInlineRange(node, positions: $0) } ?? source.range(node)
            // Корень документа позиции не имеет по определению: его запасной диапазон весь текст, а зависящие от него потомки помечаются сами.
            if confirmed == nil && cmark_node_get_type(node) != CMARK_NODE_DOCUMENT { unconfirmed = true }
            let range = confirmed ?? container
            if inlineMath.contains(node) || cmark_node_get_syntax_extension(node) == mathExtension {
                separator(range.location)
                return
            }
            if kind == "paragraph", let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
               let literal = cmark_node_get_literal(child), String(cString: literal) == "[toc]",
               raw.substring(with: range) == "[toc]" { separator(range.location); return }
            let block = ["paragraph", "heading", "table_row", "table_header", "table_cell", "code_block", "thematic_break"].contains(kind)
            if block || kind == "image" { separator(range.location) }
            switch kind {
            case "text":
                if let literal = cmark_node_get_literal(node) { append(String(cString: literal), range: range, mapInline: true) }
            case "code":
                if let literal = cmark_node_get_literal(node) {
                    let value = String(cString: literal)
                    var body = range, ticks = 0
                    let includesDelimiters = raw.substring(with: range) != value
                    while includesDelimiters, ticks < range.length, raw.character(at: range.location + ticks) == 96 {
                        if isCancelled() { return }
                        ticks += 1
                    }
                    if ticks > 0, ticks * 2 <= range.length,
                       (0..<ticks).allSatisfy({ !isCancelled() && raw.character(at: NSMaxRange(range) - 1 - $0) == 96 }) {
                        body = NSRange(location: range.location + ticks, length: range.length - ticks * 2)
                    }
                    if body.length >= 2, raw.character(at: body.location) == 32, raw.character(at: NSMaxRange(body) - 1) == 32 {
                        let trimmed = NSRange(location: body.location + 1, length: body.length - 2)
                        if raw.substring(with: trimmed) == value { body = trimmed }
                    }
                    append(value, range: body)
                }
            case "code_block":
                let language = cmark_node_get_fence_info(node).map { String(cString: $0).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "" } ?? ""
                if !["mermaid", "flow", "sequence"].contains(language), let literal = cmark_node_get_literal(node) {
                    let value = String(cString: literal)
                    let block = raw.substring(with: range) as NSString
                    // В тексте с `\r\n` cmark отдаёт литерал с `\n`: ищем его в исходной записи и режем на куски построчно.
                    let crlf = value.contains("\n") && block.contains("\r\n")
                    let needle = crlf ? value.replacingOccurrences(of: "\n", with: "\r\n") : value
                    let match = block.range(of: needle, options: .literal)
                    if !value.isEmpty, match.location != NSNotFound {
                        let remaining = NSRange(location: NSMaxRange(match), length: block.length - NSMaxRange(match))
                        if block.range(of: needle, options: .literal, range: remaining).location == NSNotFound {
                            let found = NSRange(location: range.location + match.location, length: match.length)
                            if crlf {
                                var pieces: [MarkdownReadableText.Piece] = [], position = found.location
                                let lines = value.components(separatedBy: "\n")
                                for (index, line) in lines.enumerated() {
                                    let length = (line as NSString).length
                                    if length > 0 { pieces.append(.init(sourceRange: NSRange(location: position, length: length), text: line, matchesSource: true)) }
                                    position += length
                                    if index < lines.count - 1 {
                                        pieces.append(.init(sourceRange: NSRange(location: position, length: 2), text: "\n", matchesSource: false))
                                        position += 2
                                    }
                                }
                                fragments.append(.init(sourceRange: found, text: value, matchesSource: false, pieces: pieces))
                            } else { append(value, range: found) }
                        } else { append(value, range: range) }
                    } else { append(value, range: range) }
                }
            case "softbreak", "linebreak":
                separator(fragments.last.map { NSMaxRange($0.sourceRange) } ?? range.location)
            case "html_block":
                let value = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
                let commentOnly: Bool
                if value.hasPrefix("<!--"), let close = value.range(of: "-->") {
                    commentOnly = value[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } else { commentOnly = false }
                if !commentOnly && MarkdownHTMLMediaService.audioSource(in: value) == nil {
                    unsupported.append(range)
                }
            case "html_inline":
                let value = cmark_node_get_literal(node).map { String(cString: $0).lowercased() } ?? ""
                if ["<br>", "<br/>", "<br />"].contains(value) { separator(range.location) }
                else if value.contains("<script") || value.contains("<style") { unsupported.append(container) }
                else if value.contains("<img") { unsupported.append(range) }
            case "footnote_reference": break
            default:
                var child = cmark_node_first_child(node)
                while let current = child, !isCancelled() {
                    visit(current, container: range, cellPositions: positions)
                    // Локальный разбор берёт фрагменты читаемого текста по блокам: после каждого верхнеуровневого блока сообщаем их число.
                    if cmark_node_get_type(node) == CMARK_NODE_DOCUMENT { onTopLevelBlock?(fragments.count, unconfirmed); unconfirmed = false }
                    child = cmark_node_next(current)
                }
            }
            if block || kind == "image" { separator(NSMaxRange(range)) }
        }
        visit(root, container: NSRange(location: 0, length: raw.length), cellPositions: nil)
        guard !isCancelled() else { return nil }
        return MarkdownReadableText(sourceLength: raw.length, fragments: fragments, unsupportedRanges: unsupported)
    }
}
