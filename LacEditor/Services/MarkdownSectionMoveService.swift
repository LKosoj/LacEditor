import Foundation

/// Перенос разделов Markdown: раздел — от заголовка до следующего заголовка того же или более высокого уровня.
/// Чистый сервис: не читает документ и диск, не вызывает cmark. Диапазоны — UTF-16.
/// Границы строк только CR, LF, CRLF (U+2028/U+2029 остаются содержимым); переводы строк переносятся дословно.
enum MarkdownSectionMoveService {
    enum Direction { case up, down }
    /// `before(j)` — перед верхним заголовком с индексом `j` полного списка; `end` — в конец документа.
    enum Target: Equatable { case before(Int), end }
    enum Failure: Error, Equatable { case invalidInput, notTopLevel, insideSelf, unchanged, unsafeEnd }

    struct Move: Equatable {
        let range: NSRange
        let replacement: String
        let selectionRange: NSRange
    }

    /// Индекс заголовка, ограничивающего раздел `index` (следующий верхний с `level <=`); nil — раздел до конца текста.
    static func sectionEnd(of index: Int, in headings: [MarkdownHeading]) -> Int? {
        let level = headings[index].level
        return (index + 1..<headings.count).first { headings[$0].isTopLevel && headings[$0].level <= level }
    }

    /// Проверка места без текста (для показа индикатора при перетаскивании).
    static func validate(section: Int, target: Target, headings: [MarkdownHeading]) -> Failure? {
        guard headings.indices.contains(section), headings[section].isTopLevel else { return .notTopLevel }
        let end = sectionEnd(of: section, in: headings)
        switch target {
        case let .before(j):
            guard headings.indices.contains(j), headings[j].isTopLevel else { return .notTopLevel }
            if j == section || j == end { return .unchanged }
            if j > section, end == nil || j < end! { return .insideSelf }
            return nil
        case .end:
            return end == nil ? .unchanged : nil
        }
    }

    /// Место для «Вверх/Вниз» или nil, если соседа того же уровня в том же родителе нет.
    static func target(_ direction: Direction, section: Int, headings: [MarkdownHeading]) -> Target? {
        guard headings.indices.contains(section), headings[section].isTopLevel else { return nil }
        let level = headings[section].level
        let result: Target
        switch direction {
        case .up:
            var found: Int?
            for index in stride(from: section - 1, through: 0, by: -1) where headings[index].isTopLevel {
                if headings[index].level > level { continue }
                if headings[index].level == level { found = index }
                break
            }
            guard let neighbor = found else { return nil }
            result = .before(neighbor)
        case .down:
            guard let next = sectionEnd(of: section, in: headings), headings[next].level == level else { return nil }
            result = sectionEnd(of: next, in: headings).map(Target.before) ?? .end
        }
        return validate(section: section, target: result, headings: headings) == nil ? result : nil
    }

    static func move(in text: NSString, headings: [MarkdownHeading], section: Int, to target: Target) -> Result<Move, Failure> {
        if let failure = validate(section: section, target: target, headings: headings) { return .failure(failure) }
        guard let start = lineStart(of: headings[section], in: text) else { return .failure(.invalidInput) }
        var end = text.length
        if let next = sectionEnd(of: section, in: headings) {
            guard let value = lineStart(of: headings[next], in: text) else { return .failure(.invalidInput) }
            end = value
        }
        var insertion = text.length
        if case let .before(j) = target {
            guard let value = lineStart(of: headings[j], in: text) else { return .failure(.invalidInput) }
            insertion = value
        }
        // страховка от расхождения текста со списком заголовков
        guard start < end, insertion < start || insertion > end else { return .failure(.invalidInput) }

        // соседние блоки меняются местами: first = [lo, mid), second = [mid, hi)
        let movesDown = insertion > end
        let lo = movesDown ? start : insertion
        let mid = movesDown ? end : start
        let hi = movesDown ? insertion : end
        var firstText = text.substring(with: NSRange(location: lo, length: mid - lo))
        let secondText = text.substring(with: NSRange(location: mid, length: hi - mid))
        if hi == text.length, hasUnsafeEnd(secondText) { return .failure(.unsafeEnd) }

        // документ без перевода строки в конце: перевод первого блока остаётся между блоками
        var gap = ""
        if hi == text.length, let last = secondText.utf16.last, !isBreak(last) {
            let first = NSString(string: firstText)
            var cut = first.length
            while cut > 0, isBreak(first.character(at: cut - 1)) { cut -= 1 }
            gap = first.substring(from: cut)
            firstText = first.substring(to: cut)
        }

        let result = NSMutableString()
        var movedLocation = lo
        // стык не должен склеить абзац и setext-заголовок в один заголовок
        func append(_ block: String, moved: Bool, after left: NSString, end leftEnd: Int) {
            if startsWithSetext(NSString(string: block), at: 0) {
                let join = junction(left, end: leftEnd)
                if !join.safe { result.append(join.terminator) }
            }
            if moved { movedLocation = lo + result.length }
            result.append(block)
        }
        append(secondText, moved: !movesDown, after: text, end: lo)
        result.append(gap)
        append(firstText, moved: movesDown, after: result, end: result.length)
        if hi < text.length, startsWithSetext(text, at: hi) {
            let join = junction(result, end: result.length)
            if !join.safe { result.append(join.terminator) }
        }

        let range = NSRange(location: lo, length: hi - lo)
        let replacement = result as String
        if replacement == text.substring(with: range) { return .failure(.unchanged) }
        let moved = NSString(string: movesDown ? firstText : secondText)
        var titleLength = 0
        while titleLength < moved.length, !isBreak(moved.character(at: titleLength)) { titleLength += 1 }
        return .success(Move(range: range, replacement: replacement, selectionRange: NSRange(location: movedLocation, length: titleLength)))
    }

    private static func isBreak(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    /// Начало строки заголовка; nil, если перед `range.location` в строке не только 0–3 пробела.
    private static func lineStart(of heading: MarkdownHeading, in text: NSString) -> Int? {
        let location = heading.range.location
        guard location >= 0, location <= text.length else { return nil }
        var start = location
        while start > 0, !isBreak(text.character(at: start - 1)) { start -= 1 }
        guard location - start <= 3 else { return nil }
        for index in start..<location where text.character(at: index) != 32 { return nil }
        return start
    }

    private static func isBlank(_ line: String) -> Bool {
        line.utf16.allSatisfy { $0 == 32 || $0 == 9 }
    }

    private static func isATX(_ line: String) -> Bool {
        let units = Array(line.utf16)
        var index = 0
        while index < units.count, index < 3, units[index] == 32 { index += 1 }
        var count = 0
        while index < units.count, units[index] == 35 { index += 1; count += 1 }
        return (1...6).contains(count) && (index == units.count || units[index] == 32 || units[index] == 9)
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let units = Array(line.utf16)
        var index = 0
        while index < units.count, index < 3, units[index] == 32 { index += 1 }
        guard index < units.count, units[index] == 61 || units[index] == 45 else { return false }
        let marker = units[index]
        while index < units.count, units[index] == marker { index += 1 }
        return units[index...].allSatisfy { $0 == 32 || $0 == 9 }
    }

    /// Конец строки, начинающейся в `start`: индекс перевода строки или длина текста.
    private static func lineEnd(_ text: NSString, from start: Int) -> Int {
        var index = start
        while index < text.length, !isBreak(text.character(at: index)) { index += 1 }
        return index
    }

    /// Блок с `start` начинается с setext-заголовка: строка с текстом и подчёркивание `===`/`---`.
    private static func startsWithSetext(_ text: NSString, at start: Int) -> Bool {
        guard start < text.length else { return false }
        let firstEnd = lineEnd(text, from: start)
        guard firstEnd < text.length else { return false }
        let first = text.substring(with: NSRange(location: start, length: firstEnd - start))
        if isBlank(first) || isATX(first) { return false }
        let crlf = text.character(at: firstEnd) == 13 && firstEnd + 1 < text.length && text.character(at: firstEnd + 1) == 10
        let secondStart = firstEnd + (crlf ? 2 : 1)
        guard secondStart < text.length else { return false }
        let secondEnd = lineEnd(text, from: secondStart)
        return isSetextUnderline(text.substring(with: NSRange(location: secondStart, length: secondEnd - secondStart)))
    }

    /// Стык после `end`: безопасен, если слева пустая строка или ATX-заголовок; `terminator` — последний перевод строки слева.
    private static func junction(_ text: NSString, end: Int) -> (safe: Bool, terminator: String) {
        guard end > 0, isBreak(text.character(at: end - 1)) else { return (true, "") }
        var index = end - 1
        var terminator = text.substring(with: NSRange(location: index, length: 1))
        if text.character(at: index) == 10, index > 0, text.character(at: index - 1) == 13 {
            index -= 1
            terminator = "\r\n"
        }
        guard index > 0, !isBreak(text.character(at: index - 1)) else { return (true, terminator) }
        var start = index - 1
        while start > 0, !isBreak(text.character(at: start - 1)) { start -= 1 }
        let line = text.substring(with: NSRange(location: start, length: index - start))
        return (isBlank(line) || isATX(line), terminator)
    }

    private static func lines(of text: String) -> [String] {
        let ns = NSString(string: text)
        var result: [String] = []
        var start = 0
        var index = 0
        while index < ns.length {
            let unit = ns.character(at: index)
            if isBreak(unit) {
                result.append(ns.substring(with: NSRange(location: start, length: index - start)))
                if unit == 13, index + 1 < ns.length, ns.character(at: index + 1) == 10 { index += 1 }
                start = index + 1
            }
            index += 1
        }
        if start < ns.length { result.append(ns.substring(from: start)) }
        return result
    }

    /// Блок на конце документа кончается незакрытой оградой, формулой `$$` или HTML: после него нельзя ставить другой текст.
    private static func hasUnsafeEnd(_ block: String) -> Bool {
        var fence: (marker: unichar, count: Int)?
        var dollars = 0
        var groupFirst: String?
        for line in lines(of: block) {
            if isBlank(line) {
                groupFirst = nil
                continue
            }
            if groupFirst == nil { groupFirst = line }
            let units = Array(line.utf16)
            var index = 0
            while index < units.count, index < 3, units[index] == 32 { index += 1 }
            var count = 0
            if index < units.count, units[index] == 96 || units[index] == 126 {
                let marker = units[index]
                while index < units.count, units[index] == marker { index += 1; count += 1 }
                let rest = String(decoding: units[index...], as: UTF16.self)
                if let open = fence {
                    if marker == open.marker, count >= open.count, isBlank(rest) { fence = nil }
                    continue
                }
                if count >= 3, marker != 96 || !rest.contains("`") {
                    fence = (marker, count)
                    continue
                }
            } else if fence != nil {
                continue
            }
            if fence == nil, line.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) == "$$" { dollars += 1 }
        }
        let html = groupFirst.map { $0.drop { $0 == " " }.hasPrefix("<") } ?? false
        return fence != nil || dollars % 2 == 1 || html
    }
}
