import Foundation

/// Фрагмент текста для индекса: абзацы одного раздела, склеенные до `maxChunkUnits`.
struct SearchChunk: Equatable, Sendable {
    var line: Int           // 1-based, первая строка
    var endLine: Int
    var title: String       // «A › B»: путь заголовков для показа
    var heading: String     // нормализованные термы ближайшего заголовка
    var raw: String         // исходный текст фрагмента
    var body: String        // нормализованные термы через пробел
    var tokenCount: Int
}

/// Нарезка текста на фрагменты. Чистая логика без SQLite.
enum SearchIndexChunker {
    static let maxChunkUnits = 1000      // UTF-16
    private static let titleSeparator = " › "

    static func chunks(in text: String, fileTitle: String) -> [SearchChunk] {
        var builder = Builder(fileTitle: fileTitle)
        for line in lines(of: text) { builder.add(line) }
        return builder.finish()
    }

    /// Строки по `\n`, `\r\n` и `\r`; других разделителей нет.
    private static func lines(of text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasCR { previousWasCR = false; continue }
                result.append(String(current)); current = String.UnicodeScalarView()
            } else if scalar == "\r" {
                result.append(String(current)); current = String.UnicodeScalarView()
                previousWasCR = true
            } else {
                previousWasCR = false
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    // MARK: Разбор строк

    fileprivate struct Heading { let level: Int; let text: String }
    fileprivate struct Fence { let marker: Character; let count: Int }

    fileprivate static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Открывающий забор кода: до трёх пробелов, затем три и больше ``` или ~~~.
    fileprivate static func fenceOpen(_ line: String) -> Fence? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3, let marker = line.dropFirst(indent).first, marker == "`" || marker == "~" else { return nil }
        let rest = line.dropFirst(indent)
        let count = rest.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        // Для ``` строка информации не может содержать обратную кавычку: иначе это обычный код в строке.
        if marker == "`", rest.dropFirst(count).contains("`") { return nil }
        return Fence(marker: marker, count: count)
    }

    fileprivate static func isFenceClose(_ line: String, _ fence: Fence) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let count = rest.prefix(while: { $0 == fence.marker }).count
        return count >= fence.count && isBlank(String(rest.dropFirst(count)))
    }

    /// Только ATX-заголовки: `#`…`######` и пробел (или конец строки).
    fileprivate static func heading(in line: String) -> Heading? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var title = after.trimmingCharacters(in: .whitespaces)
        if let closing = title.range(of: #"(^|[ \t])#+$"#, options: .regularExpression) {
            title.removeSubrange(closing)
            title = title.trimmingCharacters(in: .whitespaces)
        }
        return Heading(level: level, text: title)
    }

    // MARK: Длинные абзацы

    /// Куски не длиннее `maxChunkUnits`: по предложениям, а слишком длинное предложение — по границе символа.
    /// `offset` — UTF-16 смещение куска в абзаце.
    static func pieces(of text: String) -> [(text: String, offset: Int)] {
        let ns = text as NSString
        var result: [(text: String, offset: Int)] = []
        var start: Int?
        var end = 0
        for sentence in TextSegmentation.sentences(in: text) {
            let sentenceStart = sentence.range.location, sentenceEnd = NSMaxRange(sentence.range)
            if let current = start, sentenceEnd - current <= maxChunkUnits {
                end = sentenceEnd
                continue
            }
            if let current = start {
                result.append((ns.substring(with: NSRange(location: current, length: end - current)), current))
                start = nil
            }
            if sentenceEnd - sentenceStart <= maxChunkUnits {
                start = sentenceStart
                end = sentenceEnd
            } else {
                result += hardSplit(ns, from: sentenceStart, to: sentenceEnd)
            }
        }
        if let current = start {
            result.append((ns.substring(with: NSRange(location: current, length: end - current)), current))
        }
        return result.isEmpty ? hardSplit(ns, from: 0, to: ns.length) : result
    }

    /// Жёсткая нарезка без разрыва составного символа (суррогатной пары, эмодзи с модификаторами).
    private static func hardSplit(_ ns: NSString, from: Int, to: Int) -> [(text: String, offset: Int)] {
        var result: [(text: String, offset: Int)] = []
        var location = from
        while location < to {
            var next = min(location + maxChunkUnits, to)
            if next < to {
                let sequence = ns.rangeOfComposedCharacterSequence(at: next)
                if sequence.location < next { next = sequence.location > location ? sequence.location : NSMaxRange(sequence) }
            }
            result.append((ns.substring(with: NSRange(location: location, length: next - location)), location))
            location = next
        }
        return result
    }

    fileprivate static func newlines(in text: String, before offset: Int) -> Int {
        text.utf16.prefix(offset).reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    // MARK: Сборка

    fileprivate struct Builder {
        let fileTitle: String
        var chunks: [SearchChunk] = []
        var headings: [Heading] = []
        var paragraph: [String] = []
        var paragraphStart = 0
        var parts: [String] = []
        var partsUnits = 0
        var partsStart = 0
        var partsEnd = 0
        /// Строка ближайшего заголовка; первый фрагмент раздела начинается с неё.
        var headingLine: Int?
        var startOverride: Int?
        var headingHasChunk = true
        var fence: Fence?
        var lineNumber = 0

        init(fileTitle: String) { self.fileTitle = fileTitle }

        mutating func add(_ line: String) {
            lineNumber += 1
            if let open = fence {
                if SearchIndexChunker.isFenceClose(line, open) { flushParagraph(); fence = nil }
                else if SearchIndexChunker.isBlank(line) { flushParagraph() }
                else { addText(line) }
                return
            }
            if let opened = SearchIndexChunker.fenceOpen(line) {
                flushParagraph()
                fence = opened
                return
            }
            if let heading = SearchIndexChunker.heading(in: line) {
                startHeading(heading)
                return
            }
            if SearchIndexChunker.isBlank(line) { flushParagraph() } else { addText(line) }
        }

        mutating func finish() -> [SearchChunk] {
            flushParagraph()
            flushParts()
            emitHeadingOnly()
            return chunks
        }

        private mutating func addText(_ line: String) {
            if paragraph.isEmpty { paragraphStart = lineNumber }
            paragraph.append(line)
        }

        private mutating func startHeading(_ heading: Heading) {
            flushParagraph()
            flushParts()
            emitHeadingOnly()
            while let last = headings.last, last.level >= heading.level { headings.removeLast() }
            headings.append(heading)
            headingLine = lineNumber
            startOverride = lineNumber
            headingHasChunk = false
        }

        private mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            let start = paragraphStart
            let lineCount = paragraph.count
            paragraph = []
            let units = (text as NSString).length
            if units > SearchIndexChunker.maxChunkUnits {
                flushParts()
                for piece in SearchIndexChunker.pieces(of: text) {
                    let first = start + SearchIndexChunker.newlines(in: text, before: piece.offset)
                    let last = first + SearchIndexChunker.newlines(in: piece.text, before: piece.text.utf16.count)
                    emit(raw: piece.text, start: startOverride ?? first, end: last)
                    startOverride = nil
                }
                return
            }
            if !parts.isEmpty, partsUnits + units + 2 > SearchIndexChunker.maxChunkUnits { flushParts() }
            if parts.isEmpty {
                partsStart = startOverride ?? start
                startOverride = nil
                partsUnits = 0
            } else {
                partsUnits += 2
            }
            parts.append(text)
            partsUnits += units
            partsEnd = start + lineCount - 1
        }

        private mutating func flushParts() {
            guard !parts.isEmpty else { return }
            emit(raw: parts.joined(separator: "\n\n"), start: partsStart, end: partsEnd)
            parts = []
            partsUnits = 0
        }

        /// Раздел без собственного текста (например, только подзаголовки) остаётся находимым по заголовку.
        private mutating func emitHeadingOnly() {
            guard !headingHasChunk, let heading = headings.last, let line = headingLine else { return }
            emit(raw: heading.text, start: line, end: line)
            headingHasChunk = true
        }

        private mutating func emit(raw: String, start: Int, end: Int) {
            let terms = SearchTextNormalizer.terms(in: raw)
            guard !terms.isEmpty else { return }
            let title = headings.isEmpty ? fileTitle : headings.map(\.text).joined(separator: SearchIndexChunker.titleSeparator)
            let headingTerms = headings.last.map { SearchTextNormalizer.terms(in: $0.text) } ?? []
            chunks.append(SearchChunk(line: start, endLine: end, title: title, heading: headingTerms.joined(separator: " "),
                                      raw: raw, body: terms.joined(separator: " "), tokenCount: terms.count))
            headingHasChunk = true
        }
    }
}
