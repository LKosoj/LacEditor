import Foundation

/// Найденное в тексте заметки место отрывка: `found` — весь отрывок, `selection` — что выделить (слово запроса или начало отрывка).
struct VaultSnippetMatch: Equatable, Sendable {
    let found: NSRange
    let selection: NSRange
}

/// Поиск отрывка, который прислал сервер, в тексте открытой заметки. Номера строки сервер не даёт.
/// Все позиции — UTF-16, как в редакторе.
enum VaultSnippetLocator {
    /// Короче сниппет слишком неоднозначен.
    static let minSnippetLength = 4
    /// «Голова» и «хвост» берутся не короче этого числа символов.
    static let minPartLength = 12
    static let partLength = 64
    /// Длиннее текст не нормализуем (таблица смещений слишком велика): ищем отрывок как есть.
    static let maxNormalizedLength = 2_000_000
    static let maxSelectionLength = 120

    /// Сниппет без служебных строк `@@`, с одним пробелом между словами и без знаков усечения «…» по краям.
    /// nil — отрывок пуст или короче четырёх символов.
    static func cleanedSnippet(_ raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines).filter { !$0.hasPrefix("@@") }
        var text = collapse(lines.joined(separator: " "))
        if text.hasPrefix("…") { text.removeFirst() } else if text.hasPrefix("...") { text.removeFirst(3) }
        if text.hasSuffix("…") { text.removeLast() } else if text.hasSuffix("...") { text.removeLast(3) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.unicodeScalars.count < minSnippetLength ? nil : text
    }

    static func locate(snippet raw: String, in text: String, query: String) -> VaultSnippetMatch? {
        guard let snippet = cleanedSnippet(raw) else { return nil }
        let source = text as NSString
        guard let found = findRange(of: snippet, in: text, source: source) else { return nil }
        return VaultSnippetMatch(found: found, selection: selection(in: found, source: source, query: query))
    }

    // MARK: Поиск диапазона

    private static let exact: NSString.CompareOptions = [.literal]
    private static let loose: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func findRange(of snippet: String, in text: String, source: NSString) -> NSRange? {
        if source.length > maxNormalizedLength {
            for options in [exact, loose] {
                let range = source.range(of: snippet, options: options)
                if range.location != NSNotFound { return range }
            }
            return nil
        }
        let normalized = Normalized(text)
        let attempts: [(String, NSString.CompareOptions)] = [(snippet, exact), (snippet, loose)]
            + [head(of: snippet), tail(of: snippet)].compactMap { part in part.map { ($0, loose) } }
        for (needle, options) in attempts {
            let range = normalized.text.range(of: needle, options: options)
            if range.location != NSNotFound, let mapped = normalized.sourceRange(of: range) { return mapped }
        }
        return nil
    }

    /// Первые ~64 символа, обрезанные по границе слова; nil — отрывок целиком короче или часть слишком мала.
    private static func head(of snippet: String) -> String? {
        let characters = Array(snippet)
        guard characters.count > partLength else { return nil }
        var piece = characters[..<partLength]
        // Обрыв внутри слова: недописанное слово у края отбрасывается (если пробелов нет — языки без пробелов — берём как есть).
        if characters[partLength] != " ", let space = piece.lastIndex(of: " ") { piece = characters[..<space] }
        let part = String(piece).trimmingCharacters(in: .whitespaces)
        return part.count >= minPartLength ? part : nil
    }

    private static func tail(of snippet: String) -> String? {
        let characters = Array(snippet)
        guard characters.count > partLength else { return nil }
        let start = characters.count - partLength
        var piece = characters[start...]
        if characters[start - 1] != " ", let space = piece.firstIndex(of: " ") { piece = characters[(space + 1)...] }
        let part = String(piece).trimmingCharacters(in: .whitespaces)
        return part.count >= minPartLength ? part : nil
    }

    // MARK: Выделение

    /// Первое слово запроса внутри найденного; иначе первая строка найденного, но не длиннее 120 символов.
    private static func selection(in found: NSRange, source: NSString, query: String) -> NSRange {
        for word in query.split(whereSeparator: { $0.isWhitespace }) {
            let range = source.range(of: String(word), options: loose, range: found)
            if range.location != NSNotFound, range.length > 0 { return range }
        }
        let lineEnd = source.range(of: "\n", options: [], range: found)
        var end = lineEnd.location == NSNotFound ? NSMaxRange(found) : lineEnd.location
        end = min(end, found.location + maxSelectionLength)
        if end < NSMaxRange(found), end > found.location {
            // Не разрезаем суррогатную пару или составной знак.
            end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end - 1))
        }
        return NSRange(location: found.location, length: max(end - found.location, 0))
    }

    // MARK: Нормализация пробелов

    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.whitespacesAndNewlines.contains(scalar) }

    private static func collapse(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isBlank(scalar) { pendingSpace = !scalars.isEmpty; continue }
            if pendingSpace { scalars.append(" "); pendingSpace = false }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Копия текста с одним пробелом на любую пустую серию и таблица: для каждой UTF-16-единицы копии — смещение в исходнике.
    private struct Normalized {
        let text: NSString
        /// `starts[i]` — смещение в исходнике единицы `i` копии; последний элемент — длина исходника.
        private let starts: [Int]

        init(_ source: String) {
            var scalars = String.UnicodeScalarView()
            var starts: [Int] = []
            var offset = 0
            var inBlank = false
            for scalar in source.unicodeScalars {
                let width = scalar.utf16.count
                if VaultSnippetLocator.isBlank(scalar) {
                    if !inBlank {
                        inBlank = true
                        scalars.append(" ")
                        starts.append(offset)
                    }
                } else {
                    inBlank = false
                    scalars.append(scalar)
                    for _ in 0..<width { starts.append(offset) }
                }
                offset += width
            }
            starts.append(offset)
            text = String(scalars) as NSString
            self.starts = starts
        }

        /// Диапазон копии → диапазон исходника: конец — начало следующей единицы копии.
        func sourceRange(of range: NSRange) -> NSRange? {
            let end = NSMaxRange(range)
            guard range.length > 0, end < starts.count else { return nil }
            return NSRange(location: starts[range.location], length: starts[end] - starts[range.location])
        }
    }
}
