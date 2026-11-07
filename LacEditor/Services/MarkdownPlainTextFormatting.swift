import Foundation

extension MarkdownFormattingService {
    /// «Обычный текст»: с каждой выбранной строки снимаются заголовок, все уровни цитаты и маркер списка с чекбоксом.
    /// Продолжения пункта внутри выбора сдвигаются влево на ширину маркера. Строки вне выбора и вложенные пункты ниже них не меняются.
    /// Если снимать нечего, возвращается правка, равная тексту (координатор молча её отклоняет как `.unchanged`).
    /// nil — выбор в блоке кода или результат при проверке разбором остался заголовком, цитатой, списком или кодом.
    static func plainTextEdit(in text: NSString, selection: NSRange, strictMode: Bool, blocked: [NSRange]? = nil) -> MarkdownFormattingEdit? {
        let first = markdownLineRange(in: text, at: selection.location)
        let last = markdownLineRange(in: text, at: selection.length == 0 ? selection.location : NSMaxRange(selection) - 1)
        var affected = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        // Готовый разбор отличает код от допустимого отступа вложенного пункта.
        if blocked == nil, intersectsCodeBlock(in: text, from: first.location, through: last.location) { return nil }
        // Формулы, HTML, front matter и код по разбору: те же блоки, где отказывают строчные команды.
        guard !(blocked ?? []).contains(where: { NSIntersectionRange($0, affected).length > 0 || NSLocationInRange(affected.location, $0) }) else { return nil }
        // Разбор только по окну «верхнего блока» вокруг затронутых строк, а не по всему документу.
        let window = topLevelWindow(in: text, around: affected)

        guard let model = MarkdownPresentationBuilder.model(of: text.substring(with: window), syntax: .init(strictMode: strictMode)) else { return nil }
        var removals: [NSRange] = []
        // Заголовки без пробела после `#` и закрывающие маркеры берём только из подтверждённого разбора.
        var looseHeadings: Set<Int> = []
        func headings(_ blocks: [MarkdownBlockNode]) {
            for block in blocks {
                if case let .heading(heading) = block.kind, !block.isUnreliable {
                    let range = NSRange(location: block.range.location + window.location, length: block.range.length)
                    if NSIntersectionRange(range, affected).length > 0 {
                        let markers = block.markerRanges.map { NSRange(location: $0.location + window.location, length: $0.length) }
                        if heading.style == .setext, let marker = markers.first {
                            affected = NSUnionRange(affected, text.lineRange(for: range))
                            removals.append(marker)
                        } else if let opening = markers.first {
                            looseHeadings.insert(opening.location)
                            var closing = markers.dropFirst().first
                            // У пустого заголовка модель может отдать только открывающий маркер.
                            if closing == nil, block.inlines.isEmpty {
                                var end = NSMaxRange(range)
                                while end > NSMaxRange(opening), text.character(at: end - 1) == 32 || text.character(at: end - 1) == 9 { end -= 1 }
                                if end > NSMaxRange(opening) { closing = NSRange(location: NSMaxRange(opening), length: end - NSMaxRange(opening)) }
                            }
                            if let closing {
                                var start = closing.location
                                while start > NSMaxRange(opening), text.character(at: start - 1) == 32 || text.character(at: start - 1) == 9 { start -= 1 }
                                removals.append(NSRange(location: start, length: NSMaxRange(closing) - start))
                            }
                        }
                    }
                }
                headings(block.children)
            }
        }
        headings(model.blocks)

        var itemIndent = 0
        var location = affected.location
        while location < NSMaxRange(affected) {
            let line = markdownLineRange(in: text, at: location)
            var contentEnd = NSMaxRange(line)
            while contentEnd > line.location, text.character(at: contentEnd - 1) == 10 || text.character(at: contentEnd - 1) == 13 { contentEnd -= 1 }
            func character(_ index: Int) -> unichar? { index < contentEnd ? text.character(at: index) : nil }
            func spaces(from index: Int) -> Int {
                var count = 0
                while character(index + count) == 32 { count += 1 }
                return count
            }

            // Все уровни цитаты: до трёх пробелов, `>` и один необязательный пробел.
            var cursor = line.location
            while true {
                let indent = spaces(from: cursor)
                guard indent <= 3, character(cursor + indent) == 62 else { break }
                cursor += indent + 1
                if character(cursor) == 32 { cursor += 1 }
            }
            let lead = spaces(from: cursor)
            let body = cursor + lead
            var prefixEnd = cursor
            var hashes = 0
            while character(body + hashes) == 35 { hashes += 1 }
            let afterHashes = character(body + hashes)
            if (1...6).contains(hashes), afterHashes == nil || afterHashes == 32 || afterHashes == 9 || looseHeadings.contains(body) {
                prefixEnd = body + hashes + (afterHashes == 32 || afterHashes == 9 ? 1 : 0)
                itemIndent = 0
            } else if let marker = listMarkerLength(in: text, at: body, end: contentEnd) {
                var after = body + marker
                // Чекбокс `[ ]`, `[x]`, `[X]` и пробелы после него.
                if character(after) == 91, let mark = character(after + 1), mark == 32 || mark == 120 || mark == 88,
                   character(after + 2) == 93, character(after + 3) == nil || character(after + 3) == 32 {
                    after += 3
                    after += spaces(from: after)
                }
                prefixEnd = after
                itemIndent = lead + marker
            } else if body < contentEnd, itemIndent > 0 {
                // Продолжение пункта: сдвиг влево на ширину маркера; строка без отступа заканчивает пункт.
                prefixEnd = cursor + min(lead, itemIndent)
                if lead < itemIndent { itemIndent = 0 }
            }
            if prefixEnd > line.location { removals.append(NSRange(location: line.location, length: prefixEnd - line.location)) }
            let next = NSMaxRange(line)
            if next <= location { break }
            location = next
        }

        var merged: [NSRange] = []
        for removal in removals.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, removal.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, removal)
            } else { merged.append(removal) }
        }
        removals = merged
        func mapped(_ point: Int) -> Int {
            var result = point
            for removal in removals {
                if point >= NSMaxRange(removal) { result -= removal.length }
                else if point > removal.location { result -= point - removal.location }
            }
            return result
        }
        let result = NSMutableString(string: text.substring(with: affected))
        for removal in removals.reversed() {
            result.replaceCharacters(in: NSRange(location: removal.location - affected.location, length: removal.length), with: "")
        }
        let start = mapped(selection.location), finish = mapped(NSMaxRange(selection))
        let edit = MarkdownFormattingEdit(range: affected, replacement: result as String,
                                          selectionRange: NSRange(location: start, length: finish - start))
        if removals.isEmpty { return edit }

        // Проверка: в изменённых строках не осталось ни заголовка, ни цитаты, ни списка, ни кода (разбор окна, не документа).
        let changedWindow = (text.substring(with: window) as NSString)
            .replacingCharacters(in: NSRange(location: affected.location - window.location, length: affected.length), with: edit.replacement)
        let after = NSRange(location: affected.location - window.location, length: (edit.replacement as NSString).length)
        let checked = MarkdownPresentationBuilder.parse(changedWindow, syntax: .init(strictMode: strictMode))
        func touches(_ range: NSRange) -> Bool { NSIntersectionRange(range, after).length > 0 }
        let leftover = checked.spans.contains { span in
            switch span.kind {
            case .heading, .quote, .alert, .codeBlock, .yaml: return touches(span.range)
            default: return false
            }
        }
        guard !leftover, !checked.listMarkers.contains(where: { touches($0.range) }) else { return nil }
        return edit
    }

    /// Длина маркера списка в точке вместе с пробелами после него (`-`, `+`, `*`, `1.`, `1)`); nil — это не пункт.
    /// Пробелов после маркера считается не больше четырёх: дальше начинается код внутри пункта.
    private static func listMarkerLength(in text: NSString, at index: Int, end: Int) -> Int? {
        guard index < end else { return nil }
        var length = 1
        let first = text.character(at: index)
        if first == 45 || first == 43 || first == 42 {
            // `* * *` и `- - -` — разделитель, а не пункт.
            var marks = 0, others = false
            for position in index..<end {
                let character = text.character(at: position)
                if character == first { marks += 1 } else if character != 32 && character != 9 { others = true }
            }
            if marks >= 3 && !others { return nil }
        } else {
            var digits = 0
            while index + digits < end, (48...57).contains(text.character(at: index + digits)) { digits += 1 }
            guard (1...9).contains(digits), index + digits < end,
                  text.character(at: index + digits) == 46 || text.character(at: index + digits) == 41 else { return nil }
            length = digits + 1
        }
        let after = index + length
        guard after >= end || text.character(at: after) == 32 || text.character(at: after) == 9 else { return nil }
        if after >= end { return length }
        if text.character(at: after) == 9 { return length + 1 }
        var spaces = 0
        while after + spaces < end, text.character(at: after + spaces) == 32 { spaces += 1 }
        return length + (spaces > 4 ? 1 : spaces)
    }
}
