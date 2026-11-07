import Foundation

extension MarkdownClipboardCopyService.ProjectionState {
    private typealias Style = MarkdownClipboardCopyService.Style
    private typealias Run = MarkdownClipboardCopyService.Run

    /// Блоки и контейнеры (U4.5.2): заголовок, цитата, выноска, список, пункт, код, формула-блок, таблица, hr, определение сноски.
    /// Правила допуска: `nil` при сомнении; результат — `html`/`text`/`runs`.
    func projectStructureBlock(_ block: MarkdownBlockNode, style: MarkdownClipboardCopyService.Style) {
        guard !invalid else { return }
        let isQuote = isQuoteKind(block.kind)
        if isQuote { sourceQuoteDepth += 1 }
        defer { if isQuote { sourceQuoteDepth -= 1 } }
        switch block.kind {
        case .heading: projectHeading(block, style: style)
        case .quote, .callout, .alert: projectQuote(block, style: style)
        case let .list(list): projectList(block, list: list, style: style)
        case let .listItem(item): projectListItem(block, item: item, style: style)
        case let .codeBlock(code): projectCodeBlock(block, code: code)
        case .mathBlock:
            // Блочная формула не копируется.
            if intersects(block.range) { invalid = true }
        case let .table(table): projectTable(block, table: table, style: style)
        case .thematicBreak: projectThematicBreak(block)
        case let .footnoteDefinition(label): projectFootnoteDefinition(block, label: label, style: style)
        default: invalid = true
        }
    }

    // MARK: - Абзац

    /// Абзац: проверка текстов, покрытие, определения ссылок перед текстом, обход строчных узлов.
    func projectParagraph(_ block: MarkdownBlockNode, style: MarkdownClipboardCopyService.Style) {
        // Ненадёжный лист (позиции cmark не подтверждены) не покрывается: выделение задевает его — `nil`.
        if block.isUnreliable {
            if intersects(block.range) { invalid = true }
            return
        }
        let prefix = referencePrefix(of: block)
        if intersects(block.range) {
            // Табы в тексте абзаца с определениями ссылок на верхнем уровне: соответствие позиций не доказано.
            if !textsAreProjectable(block.inlines, rejectTabs: prefix != nil && blockParents.isEmpty) { invalid = true; return }
        }
        covered.append(block.range)
        if let prefix {
            if prefix.length > 0 {
                // Разрыв между началом абзаца и первым узлом, не похожий на определение ссылки, не доказан.
                guard raw.character(at: prefix.location) == 91 else {
                    if intersects(block.range) { invalid = true }
                    return
                }
                var structural: [Int: (end: Int, tab: Int?, padding: Int)] = [:]
                if blockParents.contains(where: { if case .listItem = $0 { return true }; return false }), intersects(prefix) {
                    guard let continuation = block.containerPrefixes.first?.continuation,
                          let value = structuralPrefixes(for: prefix, continuation: Array(continuation.utf16)) else { invalid = true; return }
                    structural = value
                }
                emitUnrepresented(prefix, quotePrefixes: sourceQuoteDepth, structuralPrefixes: structural)
                if invalid { return }
            }
        }
        pendingSoftBreak = false
        defer { pendingSoftBreak = false }
        projectInlines(block.inlines, style: style)
    }

    /// Определения ссылок `[x]: …` перед текстом входят в диапазон абзаца: префикс — от начала абзаца (после флажка задачи) до первого
    /// строчного узла. `nil` — префикса нет.
    private func referencePrefix(of block: MarkdownBlockNode) -> NSRange? {
        guard let first = block.inlines.first, !first.isUnreliable else { return nil }
        var start = block.range.location
        var end = first.range.location
        if case let .listItem(item)? = blockParents.last, let task = item.task,
           task.markerRange.location >= start, task.markerRange.location < end {
            start = NSMaxRange(task.markerRange)
            while start < end, raw.character(at: start) == 32 || raw.character(at: start) == 9 { start += 1 }
        }
        guard end > start, start >= 0, end <= raw.length else { return nil }
        // Префикс кончается началом строки, с которой идёт текст абзаца: отступ и табы этой строки в него не входят.
        let textLine = raw.lineRange(for: NSRange(location: end, length: 0)).location
        if textLine > start { end = textLine }
        return NSRange(location: start, length: end - start)
    }

    /// Начало содержимого каждой строки определения ссылок внутри пункта: `container` убирается по `continuation`, таб раскрывается до 4 колонок.
    private func structuralPrefixes(for prefix: NSRange, continuation: [UInt16]) -> [Int: (end: Int, tab: Int?, padding: Int)]? {
        var structural: [Int: (end: Int, tab: Int?, padding: Int)] = [:]
        let first = raw.lineRange(for: NSRange(location: prefix.location, length: 0))
        var position = NSMaxRange(first)
        while position < NSMaxRange(prefix) {
            if Task.isCancelled { return nil }
            let line = raw.lineRange(for: NSRange(location: position, length: 0))
            var offset = 0, cursor = position, column = 0, tab: Int?, padding = 0
            while offset < continuation.count {
                if Task.isCancelled { return nil }
                guard cursor < NSMaxRange(line) else { return nil }
                let unit = raw.character(at: cursor)
                if unit == 9 && continuation[offset] == 32 {
                    let next = (column / 4 + 1) * 4
                    let count = next - column
                    let available = min(count, continuation.count - offset)
                    guard continuation[offset..<(offset + available)].allSatisfy({ $0 == 32 }) else { return nil }
                    offset += available
                    if count > available { tab = cursor; padding = count - available }
                    column = next
                } else {
                    guard unit == continuation[offset] else { return nil }
                    offset += 1
                    column = unit == 9 ? (column / 4 + 1) * 4 : column + 1
                }
                cursor += 1
            }
            structural[position] = (cursor, tab, padding)
            position = NSMaxRange(line)
        }
        return structural
    }

    /// Текст, записанный иначе, чем в исходнике, должен иметь доказанное соответствие.
    func textsAreProjectable(_ nodes: [MarkdownInlineNode], rejectTabs: Bool = false) -> Bool {
        for node in nodes {
            if Task.isCancelled { return false }
            // Узлы вне выделения ничего не пишут: их соответствие исходнику не проверяется.
            if node.range.location >= 0, NSMaxRange(node.range) <= raw.length, !intersects(node.range) { continue }
            if case let .text(literal) = node.kind {
                guard node.range.location >= 0, NSMaxRange(node.range) <= raw.length else { return false }
                let spelling = raw.substring(with: node.range)
                if rejectTabs, spelling.contains("\t") { return false }
                if spelling != literal, MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: literal,
                    sourceOffset: node.range.location, isCancelled: { Task.isCancelled }) == nil { return false }
            }
            if !textsAreProjectable(node.children, rejectTabs: rejectTabs) { return false }
        }
        return true
    }

    // MARK: - Помощники

    /// Ненадёжный блок, которого выделение не касается, не мешает копированию соседей (диапазон проверен и лежит вне выделения).
    private func skipsUnselectedUnreliable(_ block: MarkdownBlockNode) -> Bool {
        block.isUnreliable && isValid(block.range) && !intersects(block.range)
    }

    private func intersects(_ range: NSRange) -> Bool { NSIntersectionRange(range, selection).length > 0 }

    private func covers(_ range: NSRange) -> Bool { selection.location <= range.location && NSMaxRange(selection) >= NSMaxRange(range) }

    private func isValid(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= raw.length
    }

    private func isQuoteKind(_ kind: MarkdownBlockNode.Kind) -> Bool {
        switch kind {
        case .quote, .callout, .alert: return true
        default: return false
        }
    }

    /// Родитель — корень, цитата (выноска, алерт) или пункт: там допустимы цитата, заголовок и `hr`.
    private var parentAllowsBlocks: Bool {
        guard let parent = blockParents.last else { return true }
        if isQuoteKind(parent) { return true }
        if case .listItem = parent { return true }
        return false
    }

    private var parentIsItem: Bool {
        if case .listItem? = blockParents.last { return true }
        return false
    }

    /// Переводы строк между последним записанным куском и началом блока.
    private func appendBreaksBefore(_ location: Int) {
        let precedingEnd = lastEnd ?? selection.location
        if location > precedingEnd { appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: location - precedingEnd))) }
    }

    /// Дочерний блок: на время обхода родитель лежит в `blockParents`.
    private func projectChildBlock(_ child: MarkdownBlockNode, parent: MarkdownBlockNode, style: Style) {
        blockParents.append(parent.kind)
        defer { blockParents.removeLast() }
        projectBlock(child, style: style)
    }

    /// Дети контейнера по порядку, зазоры между ними — через `emitUnrepresented` (пробелы, `>`, видимый текст как код).
    /// Ненадёжный лист или нарушенный порядок диапазонов: дети обходятся без зазоров.
    private func projectContainerChildren(_ block: MarkdownBlockNode, container: NSRange, skipInitialMarker: Bool, style: Style) {
        var nodes: [(MarkdownBlockNode, NSRange)] = []
        var valid = true
        for child in block.children {
            if Task.isCancelled { invalid = true; return }
            let range = child.range
            guard isContainer(child.kind) || !child.isUnreliable, isValid(range), range.location >= container.location,
                  NSMaxRange(range) <= NSMaxRange(container), nodes.last.map({ NSMaxRange($0.1) <= range.location }) ?? true else { valid = false; break }
            nodes.append((child, range))
        }
        if !valid {
            _ = projectCalloutHead(block, from: container.location, style: style)
            if invalid { return }
            for child in block.children {
                if Task.isCancelled { invalid = true; return }
                projectChildBlock(child, parent: block, style: style)
            }
            return
        }
        var cursor = container.location
        if skipInitialMarker {
            let firstChild = nodes.first?.1.location ?? NSMaxRange(container)
            guard let marker = block.markerRanges.first, marker.location >= container.location, marker.location < firstChild,
                  isValid(marker) else { invalid = true; return }
            cursor = NSMaxRange(marker)
            while cursor < firstChild && (raw.character(at: cursor) == 32 || raw.character(at: cursor) == 9) {
                if Task.isCancelled { invalid = true; return }
                cursor += 1
            }
            if case let .listItem(item) = block.kind, item.task != nil, cursor + 2 < firstChild,
               raw.character(at: cursor) == 91, raw.character(at: cursor + 2) == 93,
               [32, 88, 120].contains(Int(raw.character(at: cursor + 1))) {
                cursor += 3
                if cursor < firstChild && (raw.character(at: cursor) == 32 || raw.character(at: cursor) == 9) { cursor += 1 }
            }
        }
        if let end = projectCalloutHead(block, from: cursor, style: style) { cursor = end }
        if invalid { return }
        for (child, range) in nodes {
            if Task.isCancelled { invalid = true; return }
            if cursor < range.location { emitUnrepresented(NSRange(location: cursor, length: range.location - cursor), quotePrefixes: sourceQuoteDepth) }
            projectChildBlock(child, parent: block, style: style)
            cursor = NSMaxRange(range)
        }
        if cursor < NSMaxRange(container) { emitUnrepresented(NSRange(location: cursor, length: NSMaxRange(container) - cursor), quotePrefixes: sourceQuoteDepth) }
    }

    /// Первая строка выноски `[!тип]± Заголовок` — не ребёнок: если выделение её задевает, она (целиком или срезом
    /// маркера/заголовка) копируется обычным текстом исходника. Возвращает конец строки.
    private func projectCalloutHead(_ block: MarkdownBlockNode, from cursor: Int, style: Style) -> Int? {
        guard case let .callout(callout) = block.kind else { return nil }
        let head = callout.titleRange.map { NSUnionRange(callout.markerRange, $0) } ?? callout.markerRange
        guard isValid(head) else { invalid = true; return nil }
        guard intersects(head) else { return nil }
        let textEnd = callout.titleRange?.location ?? NSMaxRange(callout.markerRange)
        guard head.location >= cursor, textEnd >= callout.markerRange.location,
              block.inlines.allSatisfy({ NSIntersectionRange($0.range, head).length == $0.range.length }) else { invalid = true; return nil }
        if cursor < head.location { emitUnrepresented(NSRange(location: cursor, length: head.location - cursor), quotePrefixes: sourceQuoteDepth) }
        // Срез маркера идёт обычным текстом; узлы заголовка сами режутся по выделению.
        let lead = NSIntersectionRange(selection, NSRange(location: callout.markerRange.location, length: textEnd - callout.markerRange.location))
        if lead.length > 0 { bufferText(raw.substring(with: lead), sourceRange: lead, style: style) }
        projectInlines(block.inlines, style: style)
        covered.append(head)
        return NSMaxRange(head)
    }

    // MARK: - Заголовок и hr

    private func projectHeading(_ block: MarkdownBlockNode, style: Style) {
        guard case let .heading(heading) = block.kind else { invalid = true; return }
        if skipsUnselectedUnreliable(block) { return }
        guard !block.isUnreliable, isValid(block.range) else { invalid = true; return }
        let range = block.range
        covered.append(range)
        guard intersects(range) else { return }
        if covers(range) {
            guard parentAllowsBlocks, (1...6).contains(heading.level) else { invalid = true; return }
            appendBreaksBefore(range.location)
            if parentIsItem && output.hasSuffix("\n") { output += String(repeating: "  ", count: listDepth) }
            html += "<h\(heading.level)>"
            headingLevel = heading.level
            record("", kind: .headingStart)
            lastEnd = range.location
            projectInlines(block.inlines, style: style)
            record("", kind: .headingEnd)
            headingLevel = nil
            html += "</h\(heading.level)>"
            hasStructuralOutput = true
            lastEnd = min(NSMaxRange(range), NSMaxRange(selection))
            return
        }
        projectInlines(block.inlines, style: style)
    }

    private func projectThematicBreak(_ block: MarkdownBlockNode) {
        if skipsUnselectedUnreliable(block) { return }
        guard !block.isUnreliable, isValid(block.range) else { invalid = true; return }
        covered.append(block.range)
        var range = block.range
        if let parent = blockParents.last, isQuoteKind(parent) {
            // В цитате позиция cmark может обрываться раньше конца строки.
            var end = range.location
            while end < raw.length && raw.character(at: end) != 10 && raw.character(at: end) != 13 {
                if Task.isCancelled { invalid = true; return }
                end += 1
            }
            range = NSRange(location: range.location, length: end - range.location)
        }
        guard intersects(range) else { return }
        guard parentAllowsBlocks, covers(range) else { invalid = true; return }
        appendBreaksBefore(range.location)
        if parentIsItem && output.hasSuffix("\n") { output += String(repeating: "  ", count: listDepth) }
        output += "---"
        html += "<hr>"
        record("", kind: .thematicBreak)
        hasStructuralOutput = true
        lastEnd = NSMaxRange(range)
    }

    // MARK: - Цитата

    private func projectQuote(_ block: MarkdownBlockNode, style: Style) {
        let range = block.range
        guard isValid(range), !block.isUnreliable || (range.location < raw.length && raw.character(at: range.location) == 62) else { invalid = true; return }
        quoteRanges.append(range)
        guard intersects(range) else { return }
        guard covers(range) else {
            projectContainerChildren(block, container: range, skipInitialMarker: false, style: style)
            return
        }
        guard parentAllowsBlocks else { invalid = true; return }
        for child in block.children {
            switch child.kind {
            case .paragraph, .quote, .callout, .alert, .list, .heading, .codeBlock, .mathBlock, .thematicBreak, .table: break
            default: invalid = true; return
            }
        }
        appendBreaksBefore(range.location)
        let indentation = parentIsItem ? String(repeating: "  ", count: listDepth) : ""
        if !indentation.isEmpty && output.hasSuffix("\n") { output += indentation }
        output += "> "
        html += "<blockquote>"
        quoteDepth += 1
        record("", kind: .quoteStart)
        lastEnd = range.location
        let outputStart = (output as NSString).length, runStart = runs.count
        projectContainerChildren(block, container: range, skipInitialMarker: false, style: style)
        record("", kind: .quoteEnd)
        quoteDepth -= 1
        let original = output as NSString
        let quoteText = original.substring(from: outputStart) as NSString
        var breaks: [Int] = []
        for index in 0..<quoteText.length where quoteText.character(at: index) == 10 { breaks.append(index) }
        func extra(before offset: Int) -> Int {
            var low = 0, high = breaks.count
            while low < high { let middle = (low + high) / 2; if breaks[middle] < offset { low = middle + 1 } else { high = middle } }
            return low * (2 + indentation.utf16.count)
        }
        // Перед каждой строкой цитаты в тексте добавлено «> » (с отступом): диапазоны runs сдвигаются на столько же.
        for index in runStart..<runs.count {
            let run = runs[index], start = run.range.location - outputStart, end = NSMaxRange(run.range) - outputStart
            runs[index] = Run(range: NSRange(location: run.range.location + extra(before: start),
                                            length: run.range.length + extra(before: end) - extra(before: start)),
                              bold: run.bold, italic: run.italic, strike: run.strike, underline: run.underline, highlight: run.highlight, script: run.script, code: run.code, link: run.link, inlineStyle: run.inlineStyle)
        }
        output = original.substring(to: outputStart) + (quoteText as String).replacingOccurrences(of: "\n", with: "\n" + indentation + "> ")
        html += "</blockquote>"
        lastEnd = min(NSMaxRange(range), NSMaxRange(selection))
    }

    // MARK: - Список

    private func projectList(_ block: MarkdownBlockNode, list: MarkdownBlockNode.ListBlock, style: Style) {
        let listRange = block.range
        guard isValid(listRange) else { invalid = true; return }
        guard intersects(listRange) else { return }
        if insideTable { invalid = true; return }
        let wholeList = covers(listRange)
        var items: [(MarkdownBlockNode, Int)] = []
        for (index, item) in block.children.enumerated() {
            if Task.isCancelled { invalid = true; return }
            guard isValid(item.range) else { invalid = true; return }
            if wholeList || intersects(item.range) { items.append((item, index)) }
        }
        guard wholeList || items.count > 1 else {
            // Выделен один пункт целиком или его часть: списка в результате нет, пункт пишет только своё содержимое.
            for item in block.children { projectChildBlock(item, parent: block, style: style) }
            return
        }
        let precedingEnd = lastEnd ?? selection.location
        if listRange.location > precedingEnd {
            let previousHTML = html
            let previousPartCount = structuralParts.count
            appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: listRange.location - precedingEnd)))
            // Внутри другого списка переводы строк остаются в тексте, но не в html и не в структуре.
            if listDepth > 0 {
                html = previousHTML
                structuralParts.removeSubrange(previousPartCount..<structuralParts.count)
            }
        }
        let ordered: Bool, start: Int
        switch list.marker {
        case let .ordered(first, _): ordered = true; start = first
        case .bullet: ordered = false; start = 0
        }
        html += ordered ? "<ol start=\"\(start + (items.first?.1 ?? 0))\">" : "<ul>"
        listDepth += 1
        for (position, item) in items.enumerated() {
            if Task.isCancelled { invalid = true; return }
            if position > 0 { output += "\n" }
            output += String(repeating: "  ", count: listDepth - 1)
            output += ordered ? "\(start + item.1). " : "• "
            html += "<li>"
            record("", kind: .listItemStart)
            lastEnd = max(item.0.range.location, selection.location)
            if case let .listItem(data) = item.0.kind, let task = data.task {
                let checked = task.state != 32
                output += checked ? "☑ " : "☐ "
                html += checked ? "<input type=\"checkbox\" disabled checked> " : "<input type=\"checkbox\" disabled> "
                record(checked ? "☑ " : "☐ ", kind: .taskMarker)
            }
            let partCount = structuralParts.count
            projectChildBlock(item.0, parent: block, style: style)
            if structuralParts.count == partCount { record("", kind: .emptyListItem) }
            record("", kind: .listItemEnd)
            html += "</li>"
        }
        listDepth -= 1
        html += ordered ? "</ol>" : "</ul>"
        lastEnd = min(NSMaxRange(listRange), NSMaxRange(selection))
    }

    private func projectListItem(_ block: MarkdownBlockNode, item: MarkdownBlockNode.ListItem, style: Style) {
        let range = block.range
        guard isValid(range) else { invalid = true; return }
        // Маркер пункта и флажок задачи покрыты узлом: остальное выделение должно быть пробелами или текстом детей.
        if let marker = block.markerRanges.first, isValid(marker) {
            covered.append(marker)
            if item.task != nil {
                var end = NSMaxRange(marker)
                while end < raw.length && (raw.character(at: end) == 32 || raw.character(at: end) == 9) { end += 1 }
                if end + 2 < raw.length, raw.character(at: end) == 91, raw.character(at: end + 2) == 93,
                   [32, 88, 120].contains(Int(raw.character(at: end + 1))) {
                    covered.append(NSRange(location: end, length: 3))
                }
            }
        }
        guard intersects(range) else { return }
        projectContainerChildren(block, container: range, skipInitialMarker: true, style: style)
    }

    // MARK: - Код

    private func projectCodeBlock(_ block: MarkdownBlockNode, code: MarkdownBlockNode.CodeBlock) {
        guard isValid(block.range) else { invalid = true; return }
        covered.append(block.range)
        guard intersects(block.range) else { return }
        guard !block.isUnreliable, code.bodySegments.count == code.bodyPadding.count else { invalid = true; return }
        func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        // Сегмент модели — строка без перевода строки.
        let segments = code.bodySegments.map { segment -> NSRange in
            var end = NSMaxRange(segment)
            if end < raw.length, raw.character(at: end) == 13 {
                end += 1
                if end < raw.length, raw.character(at: end) == 10 { end += 1 }
            } else if end < raw.length, raw.character(at: end) == 10 { end += 1 }
            return NSRange(location: segment.location, length: end - segment.location)
        }
        let parts = zip(segments, code.bodyPadding).compactMap { segment, padding -> (NSRange, Int)? in
            let part = NSIntersectionRange(selection, segment)
            let tabSelected = padding > 0 && segment.location > 0 && selection.location <= segment.location - 1 && NSMaxRange(selection) >= segment.location
            return part.length > 0 || tabSelected ? (part, tabSelected ? padding : 0) : nil
        }
        let whole = covers(block.range)
        guard !parts.isEmpty || whole else { return }
        // Граница выделения не должна разрезать `\r\n`.
        for (part, _) in parts where part.length > 0 {
            let start = part.location, end = NSMaxRange(part)
            if (start > 0 && raw.character(at: start - 1) == 13 && raw.character(at: start) == 10) ||
               (end < raw.length && raw.character(at: end - 1) == 13 && raw.character(at: end) == 10) { invalid = true; return }
        }
        appendBreaksBefore(block.range.location)
        let value = parts.map { part, padding in String(repeating: " ", count: padding) + (part.length > 0 ? normalized(raw.substring(with: part)) : "") }.joined()
        let resultRange = NSRange(location: (output as NSString).length, length: (value as NSString).length)
        output += value
        record("", kind: .codeStart)
        record(value)
        record("", kind: .codeEnd)
        if resultRange.length > 0 { runs.append(Run(range: resultRange, bold: false, italic: false, strike: false, underline: false, highlight: false, script: 0, code: true, link: nil, inlineStyle: nil)) }
        let language = code.info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        let attribute = language.map { " class=\"language-" + escape($0) + "\"" } ?? ""
        html += "<pre><code" + attribute + ">" + escape(value) + "</code></pre>"
        hasStructuralOutput = true
        lastEnd = whole ? min(NSMaxRange(block.range), NSMaxRange(selection)) : parts.last.map { $0.0.length > 0 ? NSMaxRange($0.0) : selection.location + selection.length }
    }

    // MARK: - Таблица

    private func projectTable(_ block: MarkdownBlockNode, table: MarkdownBlockNode.Table, style: Style) {
        if skipsUnselectedUnreliable(block) { return }
        guard !block.isUnreliable, isValid(block.range) else { invalid = true; return }
        let range = block.range
        covered.append(range)
        guard intersects(range) else { return }
        for row in table.rows {
            for cell in row.cells where !textsAreProjectable(cell.inlines) { invalid = true; return }
        }
        let wholeTable = covers(range)
        var selectedRows: [(isHeader: Bool, cells: [(cell: MarkdownBlockNode.Table.Cell, column: Int)])] = []
        for row in table.rows {
            if Task.isCancelled { invalid = true; return }
            if !wholeTable, isValid(row.range), !intersects(row.range) { continue }
            var cells: [(cell: MarkdownBlockNode.Table.Cell, column: Int)] = []
            for (column, cell) in row.cells.enumerated() {
                // Ячейка выбрана, если выделение задевает её место между `|` (вместе с пробелами по краям).
                // Ячейка без своего диапазона (добор до числа столбцов) в частичном выделении не участвует.
                if wholeTable || (!cell.isPadding && cell.colspan != 0 && isValid(cell.range) && intersects(cell.range)) {
                    cells.append((cell, column))
                } else if !cell.isPadding, cell.colspan != 0, !isValid(cell.range) {
                    // Ячейка с данными, но без доказанного диапазона: это `nil`.
                    invalid = true
                    return
                }
            }
            if !cells.isEmpty { selectedRows.append((row.isHeader, cells)) }
        }
        let selectedCellCount = selectedRows.reduce(0) { $0 + $1.cells.count }
        guard wholeTable || selectedCellCount > 1 else {
            // Одна ячейка: таблицы в результате нет, пишется только содержимое ячейки.
            for selected in selectedRows.flatMap(\.cells) { projectInlines(selected.cell.inlines, style: style) }
            return
        }
        appendBreaksBefore(range.location)
        html += "<table>"
        let tableIndex = tableCount
        tableCount += 1
        record("", kind: .tableStart)
        hasStructuralOutput = true
        insideTable = true
        for (rowIndex, selectedRow) in selectedRows.enumerated() {
            if rowIndex > 0 { output += "\n" }
            html += "<tr>"
            for (column, selected) in selectedRow.cells.enumerated() {
                if Task.isCancelled { invalid = true; insideTable = false; return }
                if column > 0 { output += "\t" }
                let tag = selectedRow.isHeader ? "th" : "td"
                let alignment: String
                if selected.column < table.alignments.count {
                    switch table.alignments[selected.column] {
                    case .left: alignment = " align=\"left\""
                    case .center: alignment = " align=\"center\""
                    case .right: alignment = " align=\"right\""
                    case .unspecified: alignment = ""
                    }
                } else { alignment = "" }
                html += "<\(tag)\(alignment)>"
                tableCell = .init(table: tableIndex, row: rowIndex, column: column)
                record("", kind: .cellStart)
                let partCount = structuralParts.count
                projectInlines(selected.cell.inlines, style: style)
                if structuralParts.count == partCount { record("") }
                record("", kind: .cellEnd)
                tableCell = nil
                html += selectedRow.isHeader ? "</th>" : "</td>"
            }
            html += "</tr>"
        }
        insideTable = false
        record("", kind: .tableEnd)
        html += "</table>"
        lastEnd = min(NSMaxRange(range), NSMaxRange(selection))
    }

    // MARK: - Определение сноски

    private func projectFootnoteDefinition(_ block: MarkdownBlockNode, label: String, style: Style) {
        guard let marker = block.markerRanges.first, isValid(marker), isValid(block.range), let number = footnoteNumbers[marker],
              NSMaxRange(marker) < raw.length, NSMaxRange(block.range) >= NSMaxRange(marker) + 1,
              raw.character(at: NSMaxRange(marker)) == 58 else {
            if intersects(block.range) { invalid = true }
            return
        }
        let whole = NSUnionRange(marker, block.range)
        guard intersects(whole) else { return }
        guard covers(whole) else { invalid = true; return }
        let prefix = NSRange(location: marker.location, length: marker.length + 1)
        covered.append(prefix)
        emit("[\(number)] ", sourceRange: prefix, style: style)
        for child in block.children {
            if Task.isCancelled { invalid = true; return }
            projectChildBlock(child, parent: block, style: style)
        }
    }
}
