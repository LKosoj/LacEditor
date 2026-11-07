import Foundation

/// Умные замены ядра (U2.5e, `Includes.editorContext`): где редактор показывает другой текст вместо исходного
/// (кавычки, тире, серии пробелов, перенос строки, отступы абзацев). Чистая часть (куски текста) идёт общей функцией
/// `MarkdownDocumentExtras.textReplacements`, структурная считается новым проходом по узлам модели
/// (`inlines`, `containerPrefixes`, `isUnreliable`): узел без `isUnreliable` считается подтверждённым.
/// Отсев картинок, таблиц, формул и неподтверждённого HTML — не здесь, а в адаптере (U5.1): список полный.
extension MarkdownDocumentParser {
    /// Заполняет `smartReplacements`; вызывается после обхода блоков, когда `html` уже подтверждён.
    static func fillReplacements(_ model: inout MarkdownDocumentModel, ctx: Context) {
        guard ctx.options.includes.contains(.editorContext), !ctx.stop() else { return }
        let html = ctx.html ?? HTMLConfirmation()
        let rawHTML = MarkdownDocumentExtras.rawHTMLRanges(htmlRanges: html.ranges.sorted { $0.location < $1.location }, available: html.rangesAvailable,
                                                           contextText: html.contextText, text: ctx.masked, isCancelled: ctx.isCancelled)
        model.smartReplacements = smartReplacements(of: model, text: ctx.masked, rawHTML: rawHTML, isCancelled: ctx.isCancelled) ?? []
    }

    /// `text` — замаскированный текст (позиции те же, что у исходного); `rawHTML` — места сырого HTML (`<script>`, `<style>`),
    /// `nil` — HTML-контекст не прослежен: тогда замены после первого HTML-узла не считаются (весь остаток после неподтверждённого тега
    /// считается сырым). `nil` в ответе — разбор отменён.
    static func smartReplacements(of model: MarkdownDocumentModel, text: NSString, rawHTML: [NSRange]?,
                                  isCancelled: @escaping () -> Bool) -> [MarkdownTextReplacement]? {
        var pass = ReplacementPass(text: text, syntax: model.options.syntax, rawHTML: rawHTML, isCancelled: isCancelled)
        if rawHTML == nil { pass.opaqueFrom = firstHTMLLocation(model.blocks) }
        pass.visit(model.blocks, stack: [])
        if pass.cancelled || isCancelled() { return nil }
        return pass.result.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
    }

    /// Начало первого HTML-узла модели (блока или строчного).
    private static func firstHTMLLocation(_ blocks: [MarkdownBlockNode]) -> Int? {
        var best: Int?
        func note(_ location: Int) { best = min(best ?? location, location) }
        func visit(_ inlines: [MarkdownInlineNode]) {
            for node in inlines {
                switch node.kind {
                case .rawHTML, .media, .iframe, .svg, .ruby, .underline, .keyboard, .inlineStyle: note(node.range.location)
                case .image(let image) where image.syntax == .html: note(node.range.location)
                case .link(let link) where link.form == .html: note(node.range.location)
                default: break
                }
                visit(node.children)
            }
        }
        func visit(_ blocks: [MarkdownBlockNode]) {
            for block in blocks {
                if case .html = block.kind { note(block.range.location) }
                visit(block.inlines)
                visit(block.children)
            }
        }
        visit(blocks)
        return best
    }

    private struct ReplacementPass {
        /// `column` у пункта — колонка содержимого и префикс цитат на его первой строке; `nil`, если вычислить нельзя.
        enum Ancestor { case quote, list, item(task: MarkdownTaskCheckbox?, marker: Int?, column: (Int, String)?) }

        let text: NSString
        let syntax: MarkdownSyntaxOptions
        let rawHTML: [NSRange]?
        let isCancelled: () -> Bool
        var opaqueFrom: Int?
        var cancelled = false
        var result: [MarkdownTextReplacement] = []
        var breakCache: [Int: NSRange?] = [:]
        let wantsText: Bool, wantsBreaks: Bool, wantsSpaces: Bool

        init(text: NSString, syntax: MarkdownSyntaxOptions, rawHTML: [NSRange]?, isCancelled: @escaping () -> Bool) {
            self.text = text
            self.syntax = syntax
            self.rawHTML = rawHTML
            self.isCancelled = isCancelled
            let keepsWhitespace = syntax.preserveEditingWhitespace ?? false
            wantsText = (syntax.smartPunctuation ?? true) || !keepsWhitespace
            wantsBreaks = !syntax.preserveEditingSoftBreaks || !keepsWhitespace
            wantsSpaces = !keepsWhitespace
        }

        mutating func stop() -> Bool {
            if cancelled { return true }
            if isCancelled() { cancelled = true }
            return cancelled
        }

        // MARK: Обход блоков

        mutating func visit(_ blocks: [MarkdownBlockNode], stack: [Ancestor]) {
            for block in blocks {
                if stop() { return }
                var inner = stack
                switch block.kind {
                case .table, .footnoteDefinition:
                    continue
                case .quote, .callout, .alert:
                    inner.append(.quote)
                case .list:
                    inner.append(.list)
                case .listItem(let item):
                    inner.append(.item(task: item.task, marker: block.markerRanges.first?.location, column: itemColumn(block, item: item)))
                default:
                    break
                }
                let paragraph: MarkdownBlockNode? = { if case .paragraph = block.kind { return block } else { return nil } }()
                breakCache.removeAll(keepingCapacity: true)
                // Признак простого абзаца нужен только когда переносы сохраняются, а отступы прячутся.
                let plain = syntax.preserveEditingSoftBreaks && wantsSpaces && (paragraph.map { isPlainMultiline($0) } ?? false)
                inlines(block.inlines, paragraph: paragraph, plain: plain, stack: stack)
                if paragraph != nil, wantsSpaces { paragraphSpaces(block, stack: stack) }
                visit(block.children, stack: inner)
            }
        }

        /// Колонку содержимого пункта можно вычислить, только если пункт начинается с абзаца,
        /// чей первый узел — текст, совпадающий с исходником, а перед ним на строке одни ASCII-знаки.
        func itemColumn(_ block: MarkdownBlockNode, item: MarkdownBlockNode.ListItem) -> (Int, String)? {
            guard let marker = block.markerRanges.first?.location, marker >= 0, marker < text.length,
                  let paragraph = block.children.first, case .paragraph = paragraph.kind,
                  let first = paragraph.inlines.first, !first.isUnreliable, first.range.length > 0, NSMaxRange(first.range) <= text.length,
                  first.range.location >= marker else { return nil }
            switch first.kind {
            case .text(let value): guard text.substring(with: first.range) == value else { return nil }
            case .emoji, .wikiLink, .noteEmbed, .critic, .comment, .highlight, .superscriptText: break
            default: return nil
            }
            let line = text.lineRange(for: NSRange(location: marker, length: 0))
            // Отметка задачи входит в содержимое пункта: колонка продолжения считается от «[».
            var contentStart = first.range.location
            if let task = item.task, task.markerRange.location >= marker, task.markerRange.location < first.range.location { contentStart = task.markerRange.location }
            guard first.range.location < NSMaxRange(line), contentStart >= line.location else { return nil }
            let initial = Array(text.substring(with: NSRange(location: line.location, length: contentStart - line.location)).utf16)
            guard initial.allSatisfy({ $0 < 128 }) else { return nil }
            let column = initial.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
            var quoteEnd = initial.lastIndex(of: 62).map { $0 + 1 } ?? 0
            if quoteEnd > 0 && quoteEnd < initial.count && (initial[quoteEnd] == 32 || initial[quoteEnd] == 9) { quoteEnd += 1 }
            return (column, String(decoding: initial[..<quoteEnd], as: UTF16.self))
        }

        /// Префикс контейнеров перед `position` (общая проверка с ядром ограждений).
        func containerPrefix(_ stack: [Ancestor], at position: Int) -> (line: NSRange, source: String, continuation: String, nested: Bool)? {
            let nearest = Array(stack.reversed())
            let ancestors = nearest.map { ancestor -> MarkdownDocumentExtras.FenceAncestor in
                switch ancestor {
                case .quote: return .init(kind: .quote, firstPosition: nil)
                case .list: return .init(kind: .list, firstPosition: nil)
                case .item(_, let marker, _): return .init(kind: .item, firstPosition: marker)
                }
            }
            return MarkdownDocumentExtras.fencePrefix(ancestors: ancestors, text: text, position: position, allowEarlierItem: false, itemStartColumn: { index in
                if case .item(_, _, let column) = nearest[index] { return column } else { return nil }
            })
        }

        /// Абзац из подряд идущих строчных узлов простых видов (без жёстких переносов и сносок), каждая строка внутри которых целая.
        func isPlainMultiline(_ block: MarkdownBlockNode) -> Bool {
            guard (block.range.location..<NSMaxRange(block.range)).contains(where: { isBreak($0) }) else { return false }
            func plain(_ node: MarkdownInlineNode) -> Bool {
                switch node.kind {
                case .hardBreak, .footnoteReference: return false
                case .code, .image, .rawHTML, .media, .iframe, .svg, .ruby, .underline, .keyboard, .inlineStyle:
                    guard NSMaxRange(node.range) <= text.length, !(node.range.location..<NSMaxRange(node.range)).contains(where: { isBreak($0) }) else { return false }
                default: break
                }
                return node.children.allSatisfy { plain($0) }
            }
            return block.inlines.allSatisfy { plain($0) }
        }

        // MARK: Строчные узлы

        func inRaw(_ location: Int) -> Bool {
            if let opaqueFrom, location >= opaqueFrom { return true }
            guard let rawHTML else { return false }
            return rawHTML.contains { $0.location <= location && location < NSMaxRange($0) }
        }

        mutating func inlines(_ items: [MarkdownInlineNode], paragraph: MarkdownBlockNode?, plain: Bool, stack: [Ancestor]) {
            for (index, node) in items.enumerated() {
                if stop() { return }
                switch node.kind {
                case .image:
                    continue
                case .text(let value):
                    guard wantsText, !node.isUnreliable, node.range.length > 0, NSMaxRange(node.range) <= text.length, !inRaw(node.range.location),
                          let pieces = MarkdownInlineTextProjection.pieces(spelling: text.substring(with: node.range) as NSString, literal: value,
                                                                           sourceOffset: node.range.location, isCancelled: isCancelled) else { continue }
                    result += MarkdownDocumentExtras.textReplacements(pieces: pieces, text: text, syntax: syntax, isCancelled: isCancelled)
                case .softBreak:
                    guard wantsBreaks, !node.isUnreliable, !inRaw(node.range.location), let paragraph, index > 0, index + 1 < items.count,
                          let range = breakRange(previous: items[index - 1], next: items[index + 1], stack: stack) else { continue }
                    if !syntax.preserveEditingSoftBreaks {
                        result.append(.init(range: range, text: " ", kind: .softBreak))
                    } else if wantsSpaces, plain, let first = paragraph.containerPrefixes.first ?? (stack.isEmpty ? .init(line: .init(), prefixLength: 0, continuation: "") : nil) {
                        // Перенос сохраняется, но отступ после префикса контейнера на новой строке прячется.
                        let after = items[index + 1].range.location
                        let line = text.lineRange(for: NSRange(location: after, length: 0))
                        let structuralEnd = line.location + first.prefixLength
                        let leading = NSRange(location: structuralEnd, length: after - structuralEnd)
                        if structuralEnd < after, leading.location >= range.location, NSMaxRange(leading) <= NSMaxRange(range),
                           (leading.location..<NSMaxRange(leading)).allSatisfy({ text.character(at: $0) == 32 || text.character(at: $0) == 9 }) {
                            result.append(.init(range: leading, text: "", kind: .spaces))
                        }
                    }
                default:
                    break
                }
                inlines(node.children, paragraph: paragraph, plain: plain, stack: stack)
            }
        }

        /// Узел, положение которого подтверждается: обычный текст, код, выделение, ссылка с адресом `[текст](адрес)`.
        /// `strict == false` (соседи переноса строки) добавляет то, что подтверждается отдельно: картинки, формулы, парные теги HTML, `<br>`.
        /// Внутри абзаца (`strict`) HTML, картинки, формулы, сноски и жёсткие переносы подтверждения не имеют (абзац с ними не трогается).
        func isProvable(_ node: MarkdownInlineNode, strict: Bool) -> Bool {
            guard !node.isUnreliable else { return false }
            // Парный тег HTML (`<em>…</em>`) модель отдаёт как обычное выделение; в абзаце он не подтверждён, отличают его маркеры `<`.
            if strict, let marker = node.markerRanges.first, marker.location < text.length, text.character(at: marker.location) == 60 { return false }
            switch node.kind {
            case .text, .code, .strong, .emphasis, .strikethrough, .subscriptText, .superscriptText, .highlight,
                 .emoji, .wikiLink, .noteEmbed, .critic, .comment:
                break
            case .link(let link):
                if link.form == .html { guard !strict else { return false }; return true }
                guard link.form == .inline else { return false }
            case .image, .formula, .underline, .keyboard, .inlineStyle:
                return !strict
            case .rawHTML(let value):
                return !strict && ["<br>", "<br/>", "<br />"].contains(value.lowercased())
            default:
                return false
            }
            return node.children.allSatisfy { isProvable($0, strict: strict) }
        }

        // MARK: Перенос строки

        /// Перенос считается один раз на абзац: его просят и обход строчных узлов, и `paragraphSpaces`.
        mutating func breakRange(previous: MarkdownInlineNode, next: MarkdownInlineNode, stack: [Ancestor]) -> NSRange? {
            if let cached = breakCache[next.range.location] { return cached }
            let found = softBreakRange(previous: previous, next: next, stack: stack)
            breakCache[next.range.location] = .some(found)
            return found
        }

        /// Диапазон от конца предыдущего узла до начала следующего: пробелы, перевод строки и префикс контейнера на новой строке.
        /// Рендер показывает любой мягкий перенос пробелом, поэтому ограничения по позициям (перенос перед жёстким переносом,
        /// отступ после него, «>» без пробела) не применяются: это принятые расхождения, см. docs/unified-model/U2.5-plan.md, раздел 6.
        func softBreakRange(previous: MarkdownInlineNode, next: MarkdownInlineNode, stack: [Ancestor]) -> NSRange? {
            guard isProvable(previous, strict: false), isProvable(next, strict: false) else { return nil }
            let before = NSMaxRange(previous.range), after = next.range.location
            guard before < after, after <= text.length else { return nil }
            var cursor = before
            while cursor < after && text.character(at: cursor) == 32 { cursor += 1 }
            guard cursor < after, text.character(at: cursor) == 10 || text.character(at: cursor) == 13 else { return nil }
            let newline = text.character(at: cursor)
            cursor += 1
            if newline == 13 && cursor < after && text.character(at: cursor) == 10 { cursor += 1 }
            // Между переводом строки и следующим узлом — ровно префикс контейнеров этой строки (в документе без контейнеров — отступ).
            guard let prefix = containerPrefix(stack, at: after), prefix.line.location == cursor else { return nil }
            guard stack.isEmpty || wholeContainerTabs(NSRange(location: cursor, length: after - cursor)) else { return nil }
            return NSRange(location: before, length: after - before)
        }

        /// Табуляция в начале строки или сразу после маркера контейнера частично входит в его отступ: такая строка остаётся исходником.
        func wholeContainerTabs(_ prefix: NSRange) -> Bool {
            (prefix.location..<NSMaxRange(prefix)).allSatisfy { position in
                text.character(at: position) != 9 || (position > prefix.location && [9, 32].contains(text.character(at: position - 1)))
            }
        }

        // MARK: Пробелы у абзацев и пунктов

        func isBreak(_ index: Int) -> Bool { let unit = text.character(at: index); return unit == 10 || unit == 13 }

        /// Целые строки диапазона вместе с переводом строки в конце (`wholeLines` позиций).
        func wholeLines(_ range: NSRange) -> NSRange? {
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
            var start = range.location, end = NSMaxRange(range)
            while end > start && isBreak(end - 1) { end -= 1 }
            while start > 0 && !isBreak(start - 1) { start -= 1 }
            while end < text.length && !isBreak(end) { end += 1 }
            if end < text.length {
                let unit = text.character(at: end)
                end += 1
                if unit == 13 && end < text.length && text.character(at: end) == 10 { end += 1 }
            }
            return NSRange(location: start, length: end - start)
        }

        /// Отступ в начале, пробелы в конце и лишние пробелы после маркера у абзаца, чьи узлы целиком подтверждены.
        mutating func paragraphSpaces(_ block: MarkdownBlockNode, stack: [Ancestor]) {
            guard let line = wholeLines(block.range) else { return }
            let topLevel = stack.isEmpty
            var end = NSMaxRange(line)
            if end > line.location, text.character(at: end - 1) == 10 { end -= 1 }
            if end > line.location, text.character(at: end - 1) == 13 { end -= 1 }
            var first = line.location, last = end
            while first < end && text.character(at: first) == 32 { first += 1 }
            while last > first && (text.character(at: last - 1) == 32 || text.character(at: last - 1) == 9) { last -= 1 }
            if !topLevel {
                guard let firstNode = block.inlines.first, !firstNode.isUnreliable, firstNode.range.length > 0 else { return }
                first = firstNode.range.location
                var isTask = false
                if case .item(let task, _, _)? = stack.last, task != nil { isTask = true }
                if !isTask { guard let prefix = containerPrefix(stack, at: first), prefix.nested else { return } }
            }
            var position = line.location, prefixHasTab = false
            while position < last {
                if stop() { return }
                if text.character(at: position) == 9 {
                    if position < first { prefixHasTab = true } else { return }
                }
                position += 1
            }
            if topLevel && prefixHasTab { return }
            let singleLine = !(block.range.location..<NSMaxRange(block.range)).contains { isBreak($0) }
            if prefixHasTab {
                guard wholeContainerTabs(NSRange(location: line.location, length: first - line.location)), singleLine else { return }
            }
            guard !topLevel || first - line.location <= 3, last > first,
                  !(last < end && text.character(at: last - 1) == 92) else { return }
            // Узлы абзаца должны подряд покрывать [first, last): переносы строк считаются вместе с пробелами и префиксом.
            var cursor = first
            for (index, child) in block.inlines.enumerated() {
                if stop() { return }
                var range = child.range
                if case .softBreak = child.kind {
                    guard index > 0, index + 1 < block.inlines.count,
                          let found = breakRange(previous: block.inlines[index - 1], next: block.inlines[index + 1], stack: stack)
                    else { return }
                    range = found
                } else if !isProvable(child, strict: true) { return }
                guard range.location == cursor, NSMaxRange(range) <= last else { return }
                cursor = NSMaxRange(range)
            }
            guard cursor == last else { return }
            if !topLevel, singleLine, let found = markerPosition(stack: stack, line: line, first: first, prefixHasTab: prefixHasTab) {
                let markerEnd = found.end, columnStart = found.columnStart
                var column = 0, index = columnStart
                while index < first {
                    column = text.character(at: index) == 9 ? (column / 4 + 1) * 4 : column + 1
                    index += 1
                }
                var markerColumn = 0
                for index in columnStart..<markerEnd {
                    markerColumn = text.character(at: index) == 9 ? (markerColumn / 4 + 1) * 4 : markerColumn + 1
                }
                if (1...4).contains(column - markerColumn) {
                    result.append(.init(range: NSRange(location: markerEnd + 1, length: first - markerEnd - 1), text: "", kind: .spaces))
                }
            }
            if topLevel && first > line.location {
                result.append(.init(range: NSRange(location: line.location, length: first - line.location), text: "", kind: .spaces))
            }
            if last < end {
                result.append(.init(range: NSRange(location: last, length: end - last), text: "", kind: .spaces))
            }
        }

        /// Конец маркера контейнера перед отступом однострочного абзаца (`>`, `-`, `1.`, `[ ]`) и место, от которого считаются колонки.
        func markerPosition(stack: [Ancestor], line: NSRange, first: Int, prefixHasTab: Bool) -> (end: Int, columnStart: Int)? {
            guard let parent = stack.last else { return nil }
            let outer = stack.dropLast()
            var markerEnd: Int?, columnStart = line.location
            switch parent {
            case .quote:
                // Только цепочка цитат до документа; маркер — последний `>` строки перед текстом.
                guard outer.allSatisfy({ if case .quote = $0 { return true } else { return false } }) else { return nil }
                var position = line.location
                while position < first {
                    if text.character(at: position) == 62 { markerEnd = position + 1 }
                    position += 1
                }
            case .item(let task, let marker, _):
                guard case .list? = outer.last, let start = marker, start >= line.location, start < first,
                      outer.dropLast().allSatisfy({ ancestor in
                          switch ancestor {
                          case .quote, .list: return true
                          case .item(let task, _, _): return task == nil
                          }
                      }) else { return nil }
                if let task {
                    // Отступ после отметки задачи считается от маркера пункта: отступ контейнера не сдвигает tab stop.
                    markerEnd = NSMaxRange(task.markerRange)
                    columnStart = start
                } else {
                    var position = start
                    if [42, 43, 45].contains(Int(text.character(at: position))) { position += 1 }
                    else {
                        while position < first && (48...57).contains(text.character(at: position)) { position += 1 }
                        if position > start && position - start <= 9 && position < first && [41, 46].contains(Int(text.character(at: position))) { position += 1 }
                        else { position = start }
                    }
                    if position > start { markerEnd = position }
                }
            case .list:
                return nil
            }
            guard let markerEnd, markerEnd < first,
                  !prefixHasTab || (line.location..<markerEnd).allSatisfy({ text.character(at: $0) != 9 }),
                  text.character(at: markerEnd) == 32,
                  (markerEnd..<first).allSatisfy({ text.character(at: $0) == 32 || (prefixHasTab && text.character(at: $0) == 9) }),
                  first - markerEnd > 1 else { return nil }
            return (markerEnd, columnStart)
        }
    }
}
