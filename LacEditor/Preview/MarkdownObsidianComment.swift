import Foundation

/// Комментарии Obsidian `%%…%%`: поиск, скрытие в предпросмотре и вырезание при экспорте.
enum MarkdownObsidianComment {
    /// Корень локальных копий заметок хранилища: `Application Support/<приложение>/Vaults/`.
    private static let vaultsRootPath: String = {
        VaultStateStore.defaultRoot(vaultID: UUID()).deletingLastPathComponent().standardizedFileURL.path + "/"
    }()

    /// Комментарии `%%…%%` скрываются только в заметках хранилища; в остальных документах `%%` остаётся обычным текстом.
    static func appliesTo(documentURL: URL?) -> Bool {
        documentURL.map { $0.standardizedFileURL.path.hasPrefix(vaultsRootPath) } ?? false
    }

    /// Быстрая проверка: есть ли в тексте хотя бы одна пара `%%` (без разбора).
    static func mayContainComment(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { (buffer: UnsafeBufferPointer<UInt8>) -> Bool in
            var index = 0
            let count = buffer.count
            while index + 1 < count {
                if buffer[index] == 0x25, buffer[index + 1] == 0x25 { return true }
                index += 1
            }
            return false
        }
    }

    static func mayContainComment(_ text: NSString) -> Bool {
        text.range(of: "%%", options: .literal).location != NSNotFound
    }

    /// Диапазоны комментариев (UTF-16, от первого `%` до последнего `%` закрывающей пары включительно).
    /// `excluded` — отсортированные диапазоны кода, формул и т. п.; открытие внутри них пропускается,
    /// закрытие внутри них не считается. Незакрытый `%%` и `\%%` комментарием не являются.
    /// Окно необязательно: с ним возвращаются только комментарии, пересекающие окно (поиск всё равно идёт с начала текста).
    static func ranges(in text: NSString, window: NSRange? = nil, excluded: [NSRange]) -> [NSRange] {
        let length = text.length
        var result: [NSRange] = []
        var position = 0
        /// Конец исключаемого диапазона, содержащего позицию; nil — позиция вне исключаемых диапазонов.
        func excludedEnd(containing location: Int) -> Int? {
            var low = 0, high = excluded.count
            while low < high {
                let middle = (low + high) / 2
                if excluded[middle].location <= location { low = middle + 1 } else { high = middle }
            }
            guard low > 0, NSMaxRange(excluded[low - 1]) > location else { return nil }
            return NSMaxRange(excluded[low - 1])
        }
        func nextPair(from start: Int) -> Int? {
            guard start + 1 < length else { return nil }
            let found = text.range(of: "%%", options: .literal, range: NSRange(location: start, length: length - start))
            return found.location == NSNotFound ? nil : found.location
        }
        while let open = nextPair(from: position) {
            if let end = excludedEnd(containing: open) { position = end; continue }
            var slashes = 0
            while open - slashes - 1 >= 0, text.character(at: open - slashes - 1) == 92 { slashes += 1 }
            if slashes % 2 == 1 { position = open + 2; continue }
            var search = open + 2
            var close: Int?
            while let candidate = nextPair(from: search) {
                if let end = excludedEnd(containing: candidate) { search = end; continue }
                close = candidate
                break
            }
            // Незакрытый `%%` остаётся текстом, дальше не ищем.
            guard let close else { break }
            let range = NSRange(location: open, length: close + 2 - open)
            if let window {
                if NSIntersectionRange(range, window).length > 0 || (window.length == 0 && NSLocationInRange(window.location, range)) {
                    result.append(range)
                }
            } else {
                result.append(range)
            }
            position = close + 2
        }
        return result
    }

    /// Исключаемые диапазоны полного разбора (код, строчный код, HTML-блоки, формулы, таблицы, front matter).
    /// Один разбор cmark; пусто, если `%%` в тексте нет.
    static func commentRanges(in text: String, syntax: MarkdownSyntaxOptions) -> [NSRange] {
        guard mayContainComment(text) else { return [] }
        let source = text as NSString
        let index = MarkdownPresentationParser.parse(text, syntax: syntax, isCancelled: { false }).elements
        guard index.textLength == source.length else { return [] }
        let excluded = index.excludedRanges(intersecting: NSRange(location: 0, length: source.length))
        return ranges(in: source, excluded: excluded)
    }

    /// Предпросмотр, HTML, PDF: текст комментария удаляется, переводы строки сохраняются (число строк прежнее).
    /// Строки внутри абзаца, целиком занятые комментарием, получают невидимый знак, чтобы абзац не разорвался.
    static func hidden(_ text: String, syntax: MarkdownSyntaxOptions) -> String {
        let found = commentRanges(in: text, syntax: syntax)
        return found.isEmpty ? text : hidden(text as NSString, ranges: found)
    }

    /// Экспорт Pandoc: комментарий вырезается целиком; строка, где кроме комментария только пробелы, удаляется с переводом строки.
    static func removed(_ text: String, syntax: MarkdownSyntaxOptions) -> String {
        let found = commentRanges(in: text, syntax: syntax)
        return found.isEmpty ? text : removed(text as NSString, ranges: found)
    }

    /// Тот же расчёт на готовых диапазонах (чистая часть для тестов).
    static func hidden(_ text: NSString, ranges: [NSRange]) -> String {
        guard !ranges.isEmpty else { return text as String }
        let sorted = ranges.sorted(by: { $0.location < $1.location })
        func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }
        func insideComment(_ index: Int) -> Bool { sorted.contains { NSLocationInRange(index, $0) } }
        /// Первая позиция после префикса строки: пробелы, `>` цитаты и маркеры списка (`-`, `*`, `+`, `1.`, `1)`).
        func afterPrefix(_ start: Int, _ end: Int) -> Int {
            var index = start
            while index < end {
                let unit = text.character(at: index)
                if isBlank(unit) || unit == 62 { index += 1; continue }
                if unit == 45 || unit == 42 || unit == 43, index + 1 >= end || isBlank(text.character(at: index + 1)) { index += 1; continue }
                var digits = index
                while digits < end, text.character(at: digits) >= 48, text.character(at: digits) <= 57 { digits += 1 }
                if digits > index, digits < end, text.character(at: digits) == 46 || text.character(at: digits) == 41,
                   digits + 1 >= end || isBlank(text.character(at: digits + 1)) { index = digits + 1; continue }
                break
            }
            return index
        }
        /// Строка, где нет ничего кроме пробелов и префикса цитаты или списка (или её нет совсем).
        func isBlankLine(at location: Int) -> Bool {
            guard location >= 0, location < text.length else { return true }
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: line.location, length: 0))
            return afterPrefix(line.location, contentsEnd) == contentsEnd
        }
        /// Комментарий занимает строки целиком и стоит внутри абзаца: пустая строка разорвала бы абзац.
        func isInsideParagraph(_ range: NSRange) -> Bool {
            let startLine = text.lineRange(for: NSRange(location: range.location, length: 0))
            let endLine = text.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: endLine.location, length: 0))
            let before = (afterPrefix(startLine.location, range.location)..<range.location).allSatisfy { isBlank(text.character(at: $0)) || insideComment($0) }
            let after = (NSMaxRange(range)..<max(NSMaxRange(range), contentsEnd)).allSatisfy { isBlank(text.character(at: $0)) || insideComment($0) }
            guard before, after, startLine.location > 0, NSMaxRange(endLine) < text.length else { return false }
            return !isBlankLine(at: startLine.location - 1) && !isBlankLine(at: NSMaxRange(endLine))
        }
        let result = NSMutableString()
        var position = 0
        for range in sorted {
            guard range.location >= position, NSMaxRange(range) <= text.length else { continue }
            result.append(text.substring(with: NSRange(location: position, length: range.location - position)))
            // Невидимый знак на каждой строке комментария не даёт строке стать пустой; на вид и в тексте абзаца он ничего не меняет.
            let keepsParagraph = isInsideParagraph(range)
            if keepsParagraph { result.append("\u{200B}") }
            // CRLF остаётся парой, одиночные CR и LF — как были.
            for index in range.location..<NSMaxRange(range) {
                let unit = text.character(at: index)
                guard unit == 10 || unit == 13 else { continue }
                result.append(unit == 10 ? "\n" : "\r")
                let isCRBeforeLF = unit == 13 && index + 1 < NSMaxRange(range) && text.character(at: index + 1) == 10
                if keepsParagraph, !isCRBeforeLF { result.append("\u{200B}") }
            }
            position = NSMaxRange(range)
        }
        result.append(text.substring(from: position))
        return result as String
    }

    static func removed(_ text: NSString, ranges: [NSRange]) -> String {
        let valid = ranges.filter { $0.location >= 0 && NSMaxRange($0) <= text.length }.sorted { $0.location < $1.location }
        guard !valid.isEmpty else { return text as String }
        func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }
        func insideComment(_ index: Int) -> Bool { valid.contains { NSLocationInRange(index, $0) } }
        var cuts: [NSRange] = []
        for range in valid {
            let startLine = text.lineRange(for: NSRange(location: range.location, length: 0))
            let endLine = text.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: endLine.location, length: 0))
            let before = (startLine.location..<range.location).allSatisfy { isBlank(text.character(at: $0)) || insideComment($0) }
            let after = (NSMaxRange(range)..<max(NSMaxRange(range), contentsEnd)).allSatisfy { isBlank(text.character(at: $0)) || insideComment($0) }
            if before && after {
                cuts.append(NSRange(location: startLine.location, length: NSMaxRange(endLine) - startLine.location))
            } else {
                var cut = range
                // Пробелы по обе стороны комментария: лишний убираем, чтобы не оставалось «дыры».
                if range.location > 0, NSMaxRange(range) < text.length,
                   isBlank(text.character(at: range.location - 1)), isBlank(text.character(at: NSMaxRange(range))) {
                    cut.length += 1
                }
                cuts.append(cut)
            }
        }
        cuts.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for cut in cuts {
            if let last = merged.last, cut.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(cut)) - last.location)
            } else {
                merged.append(cut)
            }
        }
        let result = NSMutableString()
        var position = 0
        for cut in merged {
            result.append(text.substring(with: NSRange(location: position, length: cut.location - position)))
            position = NSMaxRange(cut)
        }
        result.append(text.substring(from: position))
        return result as String
    }
}
