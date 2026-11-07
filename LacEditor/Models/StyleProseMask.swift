import Foundation

/// Маска прозы для проверки стиля. Всё, что не проза (код, ссылки, разметка, формулы, таблицы, адреса),
/// заменяется пробелами; длина UTF-16 и положение знаков сохраняются, поэтому диапазоны остаются исходными.
struct StyleProseMask: Sendable {
    /// Текст той же длины UTF-16: непроза заменена пробелами U+0020, переводы строк сохранены.
    let masked: String
    /// Абзацы прозы (диапазоны исходника): без начальных маркеров, без пустых строк.
    let paragraphs: [NSRange]
    /// Непроза, упорядочена и не пересекается.
    let nonProse: [NSRange]

    init(text: String, isMarkdown: Bool) {
        var builder = Builder(units: Array(text.utf16))
        builder.maskAddresses()
        if isMarkdown { builder.maskMarkdown(text: text) }
        let maskedUnits = builder.maskedUnits()
        masked = String(decoding: maskedUnits, as: UTF16.self)
        paragraphs = builder.paragraphs(in: maskedUnits)
        nonProse = builder.nonProseRanges()
    }

    /// true, если ни один знак диапазона не лежит в непрозе (бинарный поиск по `nonProse`).
    func isProse(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return true }
        var low = 0, high = nonProse.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(nonProse[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        return low >= nonProse.count || nonProse[low].location >= NSMaxRange(range)
    }

    fileprivate static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0 || unit == 0x3000
    }

    /// Буква, цифра или иероглиф. Суррогатные пары считаются знаками слова.
    fileprivate static func isWordUnit(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) }
        if unit >= 0xD800 && unit <= 0xDFFF { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private struct Builder {
        let units: [UInt16]
        var skip: [Bool]
        var lines: [(start: Int, end: Int)] = []
        var startsBlock: [Bool] = []
        var endsBlock: [Bool] = []

        init(units: [UInt16]) {
            self.units = units
            skip = Array(repeating: false, count: units.count)
            var start = 0, index = 0
            while index < units.count {
                let unit = units[index]
                if unit == 0x0A || unit == 0x0D {
                    lines.append((start, index))
                    if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                    start = index + 1
                }
                index += 1
            }
            if start < units.count { lines.append((start, units.count)) }
            startsBlock = Array(repeating: false, count: lines.count)
            endsBlock = Array(repeating: false, count: lines.count)
        }

        mutating func mark(_ from: Int, _ to: Int) {
            guard from < to else { return }
            for index in max(from, 0)..<min(to, skip.count) { skip[index] = true }
        }

        func maskedUnits() -> [UInt16] {
            var result = units
            for index in 0..<units.count where skip[index] && units[index] != 0x0A && units[index] != 0x0D { result[index] = 0x20 }
            return result
        }

        func nonProseRanges() -> [NSRange] {
            var result: [NSRange] = []
            var start: Int?
            for index in 0..<skip.count {
                if skip[index] { if start == nil { start = index } }
                else if let from = start { result.append(NSRange(location: from, length: index - from)); start = nil }
            }
            if let from = start { result.append(NSRange(location: from, length: skip.count - from)) }
            return result
        }

        func paragraphs(in masked: [UInt16]) -> [NSRange] {
            var result: [NSRange] = []
            var start = -1, end = -1
            func flush() {
                if start >= 0 { result.append(NSRange(location: start, length: end - start)) }
                start = -1
            }
            for (index, line) in lines.enumerated() {
                if startsBlock[index] { flush() }
                var first = -1, last = -1, hasWord = false
                for position in line.start..<line.end {
                    let unit = masked[position]
                    if StyleProseMask.isSpace(unit) { continue }
                    if first < 0 { first = position }
                    last = position
                    if StyleProseMask.isWordUnit(unit) { hasWord = true }
                }
                guard hasWord else { flush(); continue }
                if start < 0 { start = first }
                end = last + 1
                if endsBlock[index] { flush() }
            }
            flush()
            return result
        }

        // MARK: Адреса (для любого типа документа)

        private static let httpPrefix = Array("http://".utf16)
        private static let httpsPrefix = Array("https://".utf16)
        private static let wwwPrefix = Array("www.".utf16)
        private static let mailtoPrefix = Array("mailto:".utf16)
        private static let mediaPrefix = Array("lac-media-".utf16)
        private static let dataPrefix = Array("data:image".utf16)

        private func lower(_ unit: UInt16) -> UInt16 { unit >= 0x41 && unit <= 0x5A ? unit + 32 : unit }

        private func has(_ prefix: [UInt16], at index: Int) -> Bool {
            guard index + prefix.count <= units.count else { return false }
            for offset in 0..<prefix.count where lower(units[index + offset]) != prefix[offset] { return false }
            return true
        }

        private func isEmailUnit(_ unit: UInt16) -> Bool {
            StyleProseMask.isWordUnit(unit) || unit == 0x2E || unit == 0x5F || unit == 0x2D || unit == 0x2B || unit == 0x25
        }

        /// Конец адреса: пробел, перевод строки или один из знаков `)>]"`.
        private func addressEnd(from index: Int) -> Int {
            var end = index
            while end < units.count {
                let unit = units[end]
                if StyleProseMask.isSpace(unit) || unit == 0x29 || unit == 0x3E || unit == 0x5D || unit == 0x22 { break }
                end += 1
            }
            return end
        }

        mutating func maskAddresses() {
            var index = 0
            while index < units.count {
                let unit = units[index]
                let previousIsWord = index > 0 && StyleProseMask.isWordUnit(units[index - 1])
                if has(Self.httpsPrefix, at: index) || has(Self.httpPrefix, at: index) || has(Self.mailtoPrefix, at: index)
                    || has(Self.mediaPrefix, at: index) || has(Self.dataPrefix, at: index)
                    || (has(Self.wwwPrefix, at: index) && !previousIsWord) {
                    let end = addressEnd(from: index)
                    mark(index, end)
                    index = max(end, index + 1)
                    continue
                }
                if unit == 0x40, index > 0, index + 1 < units.count, isEmailUnit(units[index - 1]) {
                    var left = index, right = index + 1, hasDot = false
                    while left > 0, isEmailUnit(units[left - 1]) { left -= 1 }
                    while right < units.count, isEmailUnit(units[right]) {
                        if units[right] == 0x2E, right + 1 < units.count, StyleProseMask.isWordUnit(units[right + 1]) { hasDot = true }
                        right += 1
                    }
                    if hasDot { mark(left, right); index = right; continue }
                }
                index += 1
            }
        }

        // MARK: Markdown

        private func firstNonBlank(_ from: Int, _ end: Int) -> Int {
            var index = from
            while index < end, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
            return index
        }

        /// Открывающее ограждение кода: до трёх пробелов отступа и три или больше одинаковых `` ` `` либо `~`.
        private func fenceOpening(_ line: (start: Int, end: Int)) -> (unit: UInt16, length: Int)? {
            let first = firstNonBlank(line.start, line.end)
            guard first - line.start <= 3, first < line.end, units[first] == 0x60 || units[first] == 0x7E else { return nil }
            var length = 0
            while first + length < line.end, units[first + length] == units[first] { length += 1 }
            guard length >= 3 else { return nil }
            // Строка информации у ограждения из `` ` `` не может содержать `` ` ``: так отличается однострочный код.
            if units[first] == 0x60, units[(first + length)..<line.end].contains(0x60) { return nil }
            return (units[first], length)
        }

        private func isFenceClosing(_ line: (start: Int, end: Int), _ fence: (unit: UInt16, length: Int)) -> Bool {
            let first = firstNonBlank(line.start, line.end)
            guard first - line.start <= 3 else { return false }
            var length = 0
            while first + length < line.end, units[first + length] == fence.unit { length += 1 }
            guard length >= fence.length else { return false }
            return firstNonBlank(first + length, line.end) == line.end
        }

        private func contains(_ pattern: [UInt16], from: Int, to end: Int) -> Int? {
            guard !pattern.isEmpty, end - from >= pattern.count else { return nil }
            var index = from
            while index + pattern.count <= end {
                if units[index] == pattern[0], (1..<pattern.count).allSatisfy({ units[index + $0] == pattern[$0] }) { return index }
                index += 1
            }
            return nil
        }

        mutating func maskMarkdown(text: String) {
            var frontEnd = 0
            if let front = MarkdownFrontMatter.frontMatter(text) {
                frontEnd = NSMaxRange(front.range)
                mark(0, frontEnd)
            }
            var fence: (unit: UInt16, length: Int)?
            var math: [UInt16]?   // закрывающий разделитель открытого блока формулы
            for index in 0..<lines.count {
                let line = lines[index]
                if line.start < frontEnd { continue }
                if let open = fence {
                    mark(line.start, line.end)
                    if isFenceClosing(line, open) { fence = nil }
                    continue
                }
                if let closing = math {
                    mark(line.start, line.end)
                    if contains(closing, from: line.start, to: line.end) != nil { math = nil }
                    continue
                }
                if let open = fenceOpening(line) {
                    fence = open
                    mark(line.start, line.end)
                    continue
                }
                let first = firstNonBlank(line.start, line.end)
                if first + 1 < line.end {
                    let pair = (units[first], units[first + 1])
                    if pair == (0x24, 0x24) || pair == (0x5C, 0x5B) {
                        let closing: [UInt16] = pair.0 == 0x24 ? [0x24, 0x24] : [0x5C, 0x5D]
                        mark(line.start, line.end)
                        if contains(closing, from: first + 2, to: line.end) == nil { math = closing }
                        continue
                    }
                }
                maskLine(index, line)
            }
        }

        private mutating func maskLine(_ index: Int, _ line: (start: Int, end: Int)) {
            let first = firstNonBlank(line.start, line.end)
            guard first < line.end else { return }
            let unit = units[first]
            // Таблицы: строка с вертикальной чертой в начале либо строка-разделитель.
            if unit == 0x7C { mark(line.start, line.end); return }
            let separatorChars: Set<UInt16> = [0x7C, 0x2D, 0x3A, 0x20, 0x09]
            let rest = units[line.start..<line.end]
            if rest.contains(0x7C), rest.contains(0x2D), rest.allSatisfy({ separatorChars.contains($0) }) { mark(line.start, line.end); return }
            // Горизонтальная линия и setext-подчёркивание
            if unit == 0x2D || unit == 0x2A || unit == 0x5F || unit == 0x3D {
                var count = 0, pure = true
                for position in first..<line.end {
                    if units[position] == unit { count += 1 } else if units[position] != 0x20 && units[position] != 0x09 { pure = false; break }
                }
                if pure, count >= (unit == 0x3D ? 2 : 3) { mark(line.start, line.end); return }
            }
            // HTML-блок
            if unit == 0x3C, first + 1 < line.end {
                let next = units[first + 1]
                if next == 0x2F || next == 0x21 || (next | 0x20 >= 0x61 && next | 0x20 <= 0x7A) { mark(line.start, line.end); return }
            }
            // Определение сноски `[^1]:`
            if unit == 0x5B, first + 1 < line.end, units[first + 1] == 0x5E,
               let close = contains([0x5D, 0x3A], from: first, to: line.end) {
                mark(first, close + 2)
                startsBlock[index] = true
                inlineStart(close + 2, line)
                return
            }
            // Заголовок
            if first - line.start <= 3, unit == 0x23 {
                var count = 0
                while first + count < line.end, units[first + count] == 0x23 { count += 1 }
                if count <= 6, first + count == line.end || units[first + count] == 0x20 || units[first + count] == 0x09 {
                    let content = firstNonBlank(first + count, line.end)
                    mark(first, content)
                    startsBlock[index] = true
                    endsBlock[index] = true
                    inlineStart(content, line)
                    return
                }
            }
            // Цитата и элемент списка
            var position = first
            while position < line.end, units[position] == 0x3E {
                position += 1
                position = firstNonBlank(position, line.end)
            }
            mark(first, position)
            if position < line.end, let content = listContent(at: position, end: line.end) {
                mark(position, content)
                startsBlock[index] = true
                position = content
            }
            inlineStart(position, line)
        }

        /// Конец маркера списка (вместе с пробелами и `[ ]`/`[x]`) либо nil, если маркера нет.
        private func listContent(at position: Int, end: Int) -> Int? {
            var marker = position
            let unit = units[position]
            if unit == 0x2D || unit == 0x2A || unit == 0x2B { marker += 1 }
            else {
                var digits = 0
                while position + digits < end, units[position + digits] >= 0x30, units[position + digits] <= 0x39 { digits += 1 }
                guard digits >= 1, digits <= 9, position + digits < end, units[position + digits] == 0x2E || units[position + digits] == 0x29 else { return nil }
                marker = position + digits + 1
            }
            guard marker < end, units[marker] == 0x20 || units[marker] == 0x09 else { return nil }
            var content = firstNonBlank(marker, end)
            if content + 2 < end, units[content] == 0x5B, units[content + 2] == 0x5D,
               units[content + 1] == 0x20 || units[content + 1] == 0x78 || units[content + 1] == 0x58,
               content + 3 == end || units[content + 3] == 0x20 {
                content = firstNonBlank(content + 3, end)
            }
            return content
        }

        private mutating func inlineStart(_ from: Int, _ line: (start: Int, end: Int)) {
            maskInline(from, line.end)
        }

        // MARK: Внутристрочная разметка

        private func bracketClose(_ open: Int, _ end: Int) -> Int? {
            var depth = 0, index = open
            while index < end {
                let unit = units[index]
                if unit == 0x5C { index += 2; continue }
                if unit == 0x5B { depth += 1 }
                else if unit == 0x5D { depth -= 1; if depth == 0 { return index } }
                index += 1
            }
            return nil
        }

        /// Конец хвоста ссылки после `]`: `(адрес)` или `[ссылка]`.
        private func linkTail(_ closeBracket: Int, _ end: Int) -> Int? {
            let next = closeBracket + 1
            guard next < end else { return nil }
            if units[next] == 0x28 {
                var depth = 0, index = next
                while index < end {
                    let unit = units[index]
                    if unit == 0x5C { index += 2; continue }
                    if unit == 0x28 { depth += 1 }
                    else if unit == 0x29 { depth -= 1; if depth == 0 { return index + 1 } }
                    index += 1
                }
                return nil
            }
            if units[next] == 0x5B, let close = bracketClose(next, end) { return close + 1 }
            return nil
        }

        /// Начало серии из `count` одинаковых знаков, не длиннее и не короче.
        private func findRun(_ unit: UInt16, _ count: Int, from: Int, end: Int) -> Int? {
            var index = from
            while index < end {
                if units[index] == unit {
                    var length = 0
                    while index + length < end, units[index + length] == unit { length += 1 }
                    if length == count { return index }
                    index += length
                } else { index += 1 }
            }
            return nil
        }

        private mutating func maskInline(_ from: Int, _ end: Int) {
            var index = from
            var jumps: [Int: Int] = [:]
            let criticClosers: [UInt16: [UInt16]] = [0x3E: [0x3C, 0x3C, 0x7D], 0x2D: [0x2D, 0x2D, 0x7D],
                                                      0x2B: [0x2B, 0x2B, 0x7D], 0x7E: [0x7E, 0x7E, 0x7D], 0x3D: [0x3D, 0x3D, 0x7D]]
            while index < end {
                if let target = jumps[index] { index = target; continue }
                let unit = units[index]
                switch unit {
                case 0x5C:
                    index += 2
                case 0x60:
                    var count = 1
                    while index + count < end, units[index + count] == 0x60 { count += 1 }
                    if let close = findRun(0x60, count, from: index + count, end: end) { mark(index, close + count); index = close + count }
                    else { index += count }
                case 0x21 where index + 1 < end && units[index + 1] == 0x5B:
                    if let close = bracketClose(index + 1, end), let tail = linkTail(close, end) { mark(index, tail); index = tail }
                    else { index += 1 }
                case 0x5B:
                    if index + 1 < end, units[index + 1] == 0x5E {
                        if let close = bracketClose(index, end) { mark(index, close + 1); index = close + 1 } else { index += 1 }
                    } else if index + 1 < end, units[index + 1] == 0x5B {
                        if let close = contains([0x5D, 0x5D], from: index + 2, to: end) { mark(index, close + 2); index = close + 2 } else { index += 1 }
                    } else if let close = bracketClose(index, end), let tail = linkTail(close, end) {
                        mark(index, index + 1)
                        mark(close, tail)
                        jumps[close] = tail
                        index += 1
                    } else { index += 1 }
                case 0x3C:
                    guard index + 1 < end else { index += 1; continue }
                    let next = units[index + 1]
                    guard next == 0x2F || next == 0x21 || (next | 0x20 >= 0x61 && next | 0x20 <= 0x7A) else { index += 1; continue }
                    let comment: [UInt16] = [0x2D, 0x2D, 0x3E]
                    if next == 0x21, index + 3 < end, units[index + 2] == 0x2D, units[index + 3] == 0x2D {
                        if let close = contains(comment, from: index + 4, to: end) { mark(index, close + 3); index = close + 3 } else { index += 1 }
                    } else if let close = contains([0x3E], from: index + 1, to: end) { mark(index, close + 1); index = close + 1 }
                    else { index += 1 }
                case 0x2A:
                    mark(index, index + 1); index += 1
                case 0x7E:
                    if index + 1 < end, units[index + 1] == 0x7E { mark(index, index + 2); index += 2 } else { index += 1 }
                case 0x3D:
                    if index + 1 < end, units[index + 1] == 0x3D { mark(index, index + 2); index += 2 } else { index += 1 }
                case 0x5F:
                    let left = index > 0 ? units[index - 1] : 0
                    let right = index + 1 < units.count ? units[index + 1] : 0
                    if !(StyleProseMask.isWordUnit(left) && StyleProseMask.isWordUnit(right)) { mark(index, index + 1) }
                    index += 1
                case 0x7B:
                    guard index + 2 < end, units[index + 1] == units[index + 2], let closer = criticClosers[units[index + 1]],
                          let close = contains(closer, from: index + 3, to: end) else { index += 1; continue }
                    let kind = units[index + 1]
                    if kind == 0x3E || kind == 0x2D { mark(index, close + 3); index = close + 3; continue }
                    mark(index, index + 3)
                    mark(close, close + 3)
                    if kind == 0x7E, let arrow = contains([0x7E, 0x3E], from: index + 3, to: close) { mark(arrow, arrow + 2) }
                    jumps[close] = close + 3
                    index += 3
                case 0x24:
                    if index + 1 < end, units[index + 1] == 0x24 {
                        if let close = contains([0x24, 0x24], from: index + 2, to: end) { mark(index, close + 2); index = close + 2 } else { index += 2 }
                    } else if index + 1 < end, units[index + 1] != 0x20 {
                        var close = index + 2
                        while close < end, !(units[close] == 0x24 && units[close - 1] != 0x20) { close += 1 }
                        if close < end { mark(index, close + 1); index = close + 1 } else { index += 1 }
                    } else { index += 1 }
                default:
                    index += 1
                }
            }
        }
    }
}
