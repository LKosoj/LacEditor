import Foundation
import cmark_gfm

/// Общие функции дополнительных данных документа: их вызывает ядро модели.
enum MarkdownDocumentExtras {
    /// Результат обхода текстовых узлов: кандидаты эмодзи, места автодополнения, подтверждённый текст для умных замен и wiki-ссылок.
    struct TextScan {
        var candidates: [MarkdownEmojiCandidate] = []
        var completionRanges: [NSRange] = []
        var smartRanges: [NSRange] = []
        var wikiTextRanges: [NSRange] = []
        var byNode: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]] = [:]
    }

    /// Обход текстовых узлов: `emoji` собирает кандидатов, места и умные диапазоны, `wiki` — только подтверждённые текстовые диапазоны.
    static func textScan(root: OpaquePointer, source: MarkdownSourcePositions, text: NSString, emoji: Bool, wiki: Bool,
                         isCancelled: () -> Bool) -> TextScan {
        var scan = TextScan()
        guard emoji || wiki else { return scan }
        var smart: [NSRange] = [], wikiRanges: [NSRange] = [], completion: [NSRange] = []
        var byNode: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]] = [:]
        let found = MarkdownEmojiCandidateExtractor.candidates(in: root, source: source, text: text, isCancelled: isCancelled, onSmartRange: { range in
            if emoji { smart.append(range) }
            if wiki { wikiRanges.append(range) }
        }, onTextRange: { _, range in if emoji { completion.append(range) } }) { node, offset, candidate in
            if emoji { byNode[node, default: []].append((offset, candidate)) }
        }
        scan.wikiTextRanges = wikiRanges
        guard emoji else { return scan }
        scan.candidates = found.map { MarkdownEmojiCandidate(name: $0.name, range: $0.range) }.sorted { $0.range.location < $1.range.location }
        scan.completionRanges = completion
        scan.smartRanges = smart
        scan.byNode = byNode
        return scan
    }

    /// Строки узла, где позиции cmark не подтверждены: элемент без диапазона не получает span, а карта текста должна знать об этом.
    /// Заголовок не помечаем: без span его маркер «#» не скрывается, позиции остаются верными.
    static func unreliableLines(node: OpaquePointer, type: String, source: MarkdownSourcePositions) -> NSRange? {
        guard ["strong", "emph", "strikethrough", "link", "code", "block_quote", "item"].contains(type) else { return nil }
        return source.lineRange(of: node)
    }

    /// Контейнер на пути к строке: цитата, список или пункт (`firstPosition` — начало пункта, у остальных не нужно).
    struct FenceAncestor {
        enum Kind { case quote, list, item }
        var kind: Kind
        var firstPosition: Int?
    }

    /// Префикс контейнеров перед `position` на его строке: исходный текст префикса, чем он заменяется на строках продолжения и вложен ли блок.
    /// `ancestors` — от ближайшего к внешнему (без документа). `itemStartColumn` получает индекс пункта в `ancestors`.
    /// `nil`, если в префиксе не только ASCII-пробелы, `>` и маркеры пунктов, число `>` не равно глубине цитат или ранний пункт не подтверждён.
    static func fencePrefix(ancestors: [FenceAncestor], text: NSString, position: Int, allowEarlierItem: Bool,
                            itemStartColumn: (Int) -> (Int, String)?) -> (line: NSRange, source: String, continuation: String, nested: Bool)? {
        guard position >= 0, position <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: position, length: 0))
        let original = text.substring(with: NSRange(location: line.location, length: position - line.location))
        var prefix = Array(original.utf16)
        guard prefix.allSatisfy({ $0 < 128 }) else { return nil }
        var quoteDepth = 0, earlierItems: [Int] = []
        for (index, ancestor) in ancestors.enumerated() {
            if ancestor.kind == .quote { quoteDepth += 1 }
            if ancestor.kind == .item {
                guard let item = ancestor.firstPosition, item < position else { return nil }
                if item < line.location {
                    if !allowEarlierItem { earlierItems.append(index) }
                    continue
                }
                var i = item - line.location
                if prefix[i] == 45 || prefix[i] == 43 || prefix[i] == 42 {
                    prefix[i] = 32
                } else {
                    let begin = i
                    while i < prefix.count && prefix[i] >= 48 && prefix[i] <= 57 { i += 1 }
                    guard i > begin, i < prefix.count, prefix[i] == 46 || prefix[i] == 41 else { return nil }
                    for index in begin...i { prefix[index] = 32 }
                }
            }
        }
        guard prefix.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 62 }),
              prefix.filter({ $0 == 62 }).count == quoteDepth else { return nil }
        if !earlierItems.isEmpty {
            func column(_ units: [UInt16]) -> Int {
                units.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
            }
            let currentColumn = column(prefix)
            func quotePrefix(_ units: [UInt16]) -> String {
                guard let last = units.lastIndex(of: 62) else { return "" }
                var end = last + 1
                if end < units.count && (units[end] == 32 || units[end] == 9) { end += 1 }
                return String(decoding: units[..<end], as: UTF16.self)
            }
            let currentQuotes = quotePrefix(prefix)
            for index in earlierItems {
                guard let (required, initialQuotes) = itemStartColumn(index), currentColumn >= required,
                      currentQuotes == initialQuotes else { return nil }
            }
        }
        return (line, original, String(decoding: prefix, as: UTF16.self), !ancestors.isEmpty)
    }

    /// Слияние пересекающихся и соприкасающихся диапазонов блоков ограждений (сортирует по началу).
    static func mergedBlockedRanges(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
            } else { merged.append(range) }
        }
        return merged
    }

    /// Диапазоны сырого HTML-контекста (`<script>`, `<style>` и т. п.) по подтверждённым тегам; nil, если HTML-диапазоны недоступны или не по порядку.
    /// `htmlRanges` должны быть отсортированы по началу.
    static func rawHTMLRanges(htmlRanges: [NSRange], available: Bool, contextText: NSString?, text: NSString,
                              isCancelled: () -> Bool) -> [NSRange]? {
        guard available else { return nil }
        var rawHTMLRanges: [NSRange] = []
        var rawHTMLContext = MarkdownImageUploadService.HTMLContext()
        var rawStart: Int?, previousEnd = 0
        for range in htmlRanges {
            if isCancelled() || range.location < previousEnd { return nil }
            let wasRaw = rawHTMLContext.inRawContext
            _ = rawHTMLContext.consume(source: contextText ?? text, range: range, isCancelled: isCancelled)
            if !wasRaw && rawHTMLContext.inRawContext { rawStart = range.location }
            if wasRaw && !rawHTMLContext.inRawContext, let start = rawStart {
                rawHTMLRanges.append(NSRange(location: start, length: NSMaxRange(range) - start))
                rawStart = nil
            }
            previousEnd = NSMaxRange(range)
        }
        if let start = rawStart { rawHTMLRanges.append(NSRange(location: start, length: text.length - start)) }
        return rawHTMLRanges
    }

    /// Замены по кусочкам текстового узла: умные кавычки, тире, многоточие (`.smart`) и серии пробелов (`.spaces`).
    static func textReplacements(pieces: [MarkdownReadableText.Piece], text sourceText: NSString, syntax: MarkdownSyntaxOptions,
                                 isCancelled: () -> Bool) -> [MarkdownTextReplacement] {
        var textReplacements: [MarkdownTextReplacement] = []
        for (pieceIndex, piece) in pieces.enumerated() {
            if isCancelled() { return textReplacements }
            if !piece.matchesSource, syntax.smartPunctuation ?? true {
                let spelling = sourceText.substring(with: piece.sourceRange)
                if ["\"", "'", "--", "---", "..."].contains(spelling),
                   ["“", "”", "‘", "’", "–", "—", "…"].contains(piece.text) {
                    let end = NSMaxRange(piece.sourceRange)
                    let composed = sourceText.rangeOfComposedCharacterSequence(at: end - 1)
                    let extra = NSMaxRange(composed) - end
                    if extra > 0 {
                        guard pieceIndex + 1 < pieces.count, pieces[pieceIndex + 1].matchesSource,
                              pieces[pieceIndex + 1].sourceRange.location == end,
                              pieces[pieceIndex + 1].sourceRange.length >= extra else { continue }
                    }
                    let suffix = sourceText.substring(with: NSRange(location: end, length: extra))
                    textReplacements.append(.init(range: NSRange(location: piece.sourceRange.location, length: piece.sourceRange.length + extra), text: piece.text + suffix, kind: .smart))
                }
            } else if piece.matchesSource, !(syntax.preserveEditingWhitespace ?? false) {
                var cursor = piece.sourceRange.location
                while cursor < NSMaxRange(piece.sourceRange) {
                    if isCancelled() { return textReplacements }
                    guard sourceText.character(at: cursor) == 32 || sourceText.character(at: cursor) == 9 else { cursor += 1; continue }
                    let start = cursor
                    var hasTab = false
                    while cursor < NSMaxRange(piece.sourceRange) && (sourceText.character(at: cursor) == 32 || sourceText.character(at: cursor) == 9) {
                        if isCancelled() { return textReplacements }
                        if sourceText.character(at: cursor) == 9 { hasTab = true }
                        cursor += 1
                    }
                    guard cursor - start > 1 || hasTab else { continue }
                    let last = sourceText.rangeOfComposedCharacterSequence(at: cursor - 1)
                    guard NSMaxRange(last) <= NSMaxRange(piece.sourceRange) else { continue }
                    let suffix = sourceText.substring(with: NSRange(location: cursor, length: NSMaxRange(last) - cursor))
                    cursor = NSMaxRange(last)
                    textReplacements.append(.init(range: NSRange(location: start, length: cursor - start), text: " " + suffix, kind: .spaces))
                }
            }
        }
        return textReplacements
    }

    /// Верхнеуровневые блоки документа для локального разбора; nil, если границы блоков не подтверждены (тогда локальный разбор не применяется).
    static func topLevelBlocks(root: OpaquePointer, source: MarkdownSourcePositions, text: NSString, frontMatter: Bool, hasHTML: Bool, readableEnds: [Int]?, readableUnconfirmed: [Bool] = []) -> MarkdownBlockIndex? {
        func isBlank(_ range: NSRange) -> Bool {
            (range.location..<NSMaxRange(range)).allSatisfy { [32, 9, 10, 13].contains(Int(text.character(at: $0))) }
        }
        var blocks: [MarkdownBlockIndex.Block] = []
        var child = cmark_node_first_child(root), previousEnd = 0
        while let node = child {
            // Между блоками допустимы только пробелы и пустые строки: иначе есть текст, которого нет ни в одном узле (определения ссылок и т. п.).
            guard let range = source.wholeLines(node), range.location >= previousEnd, NSMaxRange(range) <= text.length,
                  isBlank(NSRange(location: previousEnd, length: range.location - previousEnd)) else { return nil }
            let type = cmark_node_get_type(node)
            let kind: MarkdownBlockIndex.Kind
            if type == CMARK_NODE_PARAGRAPH { kind = .paragraph }
            else if type == CMARK_NODE_HEADING { kind = .heading }
            else if type == CMARK_NODE_BLOCK_QUOTE { kind = .quote }
            else if type == CMARK_NODE_LIST { kind = .list }
            else if type == CMARK_NODE_THEMATIC_BREAK { kind = .thematicBreak }
            else if type == CMARK_NODE_CODE_BLOCK {
                // Отступный код (без ограждения) в локальный разбор не берём.
                var position = range.location
                while position < NSMaxRange(range), position - range.location < 3, text.character(at: position) == 32 { position += 1 }
                let first = position < NSMaxRange(range) ? text.character(at: position) : 0
                kind = first == 96 || first == 126 ? .codeFence : .other
            }
            else if let name = cmark_node_get_type_string(node), String(cString: name) == "table" { kind = .table }
            else { kind = .other }
            blocks.append(.init(range: range, kind: kind, readableEnd: 0))
            previousEnd = NSMaxRange(range)
            child = cmark_node_next(node)
        }
        guard isBlank(NSRange(location: previousEnd, length: text.length - previousEnd)) else { return nil }
        if let readableEnds {
            guard readableEnds.count == blocks.count else { return nil }
            for index in blocks.indices {
                blocks[index].readableEnd = readableEnds[index]
                if index < readableUnconfirmed.count, readableUnconfirmed[index] { blocks[index].kind = .other }
            }
        }
        return MarkdownBlockIndex(blocks: blocks, textLength: text.length, hasHTML: hasHTML, hasFrontMatter: frontMatter,
                                  hasUnconfirmedReadable: readableUnconfirmed.contains(true))
    }

    /// Участки верхнего регистра в заголовке: текст заголовка по подтверждённым узлам и стили каждого участка.
    static func uppercaseHeadingRuns(_ node: OpaquePointer, range: NSRange, title: String,
                                     source: MarkdownSourcePositions, text: NSString,
                                     mathInline: [OpaquePointer: MarkdownMathExtension.Inline],
                                     confirmedHTML: Set<OpaquePointer>, htmlImages: Set<NSRange>,
                                     preserveSoftBreaks: Bool,
                                     emojiByNode: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]],
                                     isCancelled: @escaping () -> Bool) -> [MarkdownHeading.UppercaseRun]? {
        var runs: [MarkdownHeading.UppercaseRun] = []
        var pendingBreak: (styles: [MarkdownPresentationKind], hard: Bool)?
        let titleText = NSMutableString()
        func appendRun(_ run: MarkdownHeading.UppercaseRun) -> Bool {
            if let pending = pendingBreak {
                guard let previous = runs.last?.pieces.last, let next = run.pieces.first,
                      NSMaxRange(previous.sourceRange) <= next.sourceRange.location else { return false }
                var position = NSMaxRange(previous.sourceRange), found: NSRange?
                while position < next.sourceRange.location {
                    if isCancelled() { return false }
                    let unit = text.character(at: position)
                    if unit == 10 || unit == 13 {
                        guard found == nil else { return false }
                        let length = unit == 13 && position + 1 < next.sourceRange.location && text.character(at: position + 1) == 10 ? 2 : 1
                        found = NSRange(location: position, length: length)
                        position += length
                    } else { position += 1 }
                }
                guard let found else { return false }
                runs.append(.init(pieces: [.init(sourceRange: found, text: pending.hard || preserveSoftBreaks ? "\n" : " ", matchesSource: false)], styles: pending.styles))
                pendingBreak = nil
            }
            runs.append(run)
            return true
        }
        func appendImageTitle(_ current: OpaquePointer) -> Bool {
            guard !isCancelled(), let name = cmark_node_get_type_string(current) else { return false }
            let type = String(cString: name)
            if (type == "text" || type == "code"), let literal = cmark_node_get_literal(current) {
                titleText.append(String(cString: literal))
            } else if type == "softbreak" || type == "linebreak" { titleText.append(" ") }
            else if let formula = mathInline[current] { titleText.append("$" + formula.text + "$") }
            var child = cmark_node_first_child(current)
            while let next = child {
                if !appendImageTitle(next) { return false }
                child = cmark_node_next(next)
            }
            return true
        }
        func visit(_ current: OpaquePointer, styles: [MarkdownPresentationKind]) -> Bool {
            guard !isCancelled(), let name = cmark_node_get_type_string(current) else { return false }
            let type = String(cString: name)
            if type == "softbreak" || type == "linebreak" {
                guard pendingBreak == nil, !runs.isEmpty else { return false }
                titleText.append(" ")
                pendingBreak = (styles, type == "linebreak")
                return true
            }
            if type == "html_inline", confirmedHTML.contains(current), let imageRange = source.range(current), htmlImages.contains(imageRange) {
                return appendRun(.init(pieces: [.init(sourceRange: imageRange, text: "\u{fffc}", matchesSource: false)],
                                       styles: styles, attachment: .image))
            }
            if type == "html_inline", confirmedHTML.contains(current), let breakRange = source.range(current),
               breakRange.location >= 0, breakRange.location <= text.length,
               breakRange.length <= text.length - breakRange.location,
               ["<br>", "<br/>", "<br />"].contains(text.substring(with: breakRange).lowercased()) {
                return appendRun(.init(pieces: [.init(sourceRange: breakRange, text: "\n", matchesSource: false)], styles: styles))
            }
            if type == "image" {
                guard let imageRange = source.range(current), imageRange.location >= 0, imageRange.length >= 4,
                      imageRange.location <= text.length, imageRange.length <= text.length - imageRange.location,
                      text.substring(with: NSRange(location: imageRange.location, length: 2)) == "![",
                      cmark_node_get_url(current) != nil else { return false }
                guard appendImageTitle(current) else { return false }
                return appendRun(.init(pieces: [.init(sourceRange: imageRange, text: "\u{fffc}", matchesSource: false)],
                                       styles: styles, attachment: .image))
            }
            if let formula = mathInline[current], let parent = cmark_node_parent(current) {
                guard let formulaRange = source.mathInlineRange(line: formula.line, column: formula.column,
                                                                 byteLength: formula.byteLength, parent: parent),
                      formulaRange.location <= text.length, formulaRange.length <= text.length - formulaRange.location,
                      text.substring(with: formulaRange).utf16.elementsEqual(("$" + formula.text + "$").utf16) else { return false }
                titleText.append("$" + formula.text + "$")
                return appendRun(.init(pieces: [.init(sourceRange: formulaRange, text: "\u{fffc}", matchesSource: false)],
                                       styles: styles, attachment: .formula))
            }
            if type == "text" || type == "code" {
                guard var range = source.range(current), range.location >= 0, range.length > 0,
                      range.location <= text.length, range.length <= text.length - range.location,
                      let pointer = cmark_node_get_literal(current) else { return false }
                // Перед жёстким переносом из пробелов cmark включает их в диапазон текста, но не в literal.
                if type == "text", let next = cmark_node_next(current), cmark_node_get_type(next) == CMARK_NODE_LINEBREAK {
                    while range.length > 0 && text.character(at: NSMaxRange(range) - 1) == 32 { range.length -= 1 }
                }
                let literal = String(cString: pointer), spelling = text.substring(with: range)
                let pieces: [MarkdownReadableText.Piece]
                if type == "code" {
                    guard source.codeRange(range) != nil, spelling.utf16.elementsEqual(literal.utf16) else { return false }
                    pieces = [.init(sourceRange: range, text: literal, matchesSource: true)]
                } else {
                    guard let mapped = MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: literal,
                                                                             sourceOffset: range.location, isCancelled: isCancelled) else { return false }
                    pieces = mapped
                }
                guard !pieces.isEmpty else { return false }
                titleText.append(literal)
                let emoji = (emojiByNode[current] ?? []).map { MarkdownHeading.UppercaseRun.Emoji(range: $0.1.range, name: $0.1.name) }
                return appendRun(.init(pieces: pieces, styles: type == "code" ? styles + [.code] : styles, emoji: emoji))
            }
            let nextStyles: [MarkdownPresentationKind]
            switch type {
            case "heading": nextStyles = styles
            case "strong": nextStyles = styles + [.strong]
            case "emph": nextStyles = styles + [.emphasis]
            case "strikethrough": nextStyles = styles + [.strikethrough]
            case "link": nextStyles = styles + [.link]
            default: return false
            }
            let pairs = MarkdownDocumentParser.inlineHTMLPairs(in: current, confirmed: confirmedHTML, source: source, text: text, isCancelled: isCancelled)
            let openings = Dictionary(uniqueKeysWithValues: pairs.map { ($0.opening, $0) })
            let closings = Dictionary(uniqueKeysWithValues: pairs.map { ($0.closing, $0) })
            var active = nextStyles, htmlStack: [MarkdownDocumentParser.InlineHTMLPair] = []
            var child = cmark_node_first_child(current), sawChild = false
            while let next = child {
                if isCancelled() { return false }
                if let pair = openings[next] {
                    htmlStack.append(pair); active.append(pair.kind)
                } else if let pair = closings[next] {
                    guard htmlStack.last?.opening == pair.opening else { return false }
                    htmlStack.removeLast(); active.removeLast()
                } else if !visit(next, styles: active) { return false }
                sawChild = true
                child = cmark_node_next(next)
            }
            return sawChild && htmlStack.isEmpty
        }
        guard visit(node, styles: []), pendingBreak == nil, !isCancelled() else { return nil }
        let pieces = runs.flatMap(\.pieces)
        guard (titleText as String).trimmingCharacters(in: .whitespacesAndNewlines).utf16.elementsEqual(title.utf16),
              MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: range) != nil else { return nil }
        return runs
    }
}
