import Foundation

/// Извлечение найденного в список записей для новой вкладки. Только чтение: текст не меняется.
enum MatchExtractionService {
    enum Mode: Equatable, Sendable { case match, template, line, withoutMatch }

    struct Request: Equatable, Sendable {
        var query: String
        var options: TextSearchService.Options
        var interpretsEscapes: Bool
        var replacement: String        // шаблон для .template, как в «Заменить на»
        var mode: Mode
        var scope: NSRange? = nil
    }

    struct Record: Equatable, Sendable {
        let line: Int                  // с 1
        let text: String
    }

    static func records(in text: String, request: Request, isCancelled: () -> Bool = { false }) throws -> [Record] {
        guard !request.query.isEmpty else { return [] }
        let source = text as NSString
        if request.mode == .template {
            let edits = try FolderReplaceService.edits(
                in: text,
                request: .init(query: request.query, replacement: request.replacement,
                               options: request.options, interpretsEscapes: request.interpretsEscapes),
                scope: request.scope, isCancelled: isCancelled)
            if isCancelled() { throw CancellationError() }
            guard !edits.isEmpty else { return [] }
            let lines = try Lines(source, isCancelled: isCancelled)
            return edits.map { Record(line: lines.index(of: $0.range.location) + 1, text: $0.replacement) }
        }

        let ranges = try TextSearchService.allRanges(in: text, query: request.query, options: request.options,
                                                     scope: request.scope, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        switch request.mode {
        case .match:
            guard !ranges.isEmpty else { return [] }
            let lines = try Lines(source, isCancelled: isCancelled)
            return ranges.map { Record(line: lines.index(of: $0.location) + 1, text: source.substring(with: $0)) }
        case .line:
            guard !ranges.isEmpty else { return [] }
            let lines = try Lines(source, isCancelled: isCancelled)
            var touched: [Int] = []
            for range in ranges {
                let first = lines.index(of: range.location)
                let last = lines.index(of: max(range.location, NSMaxRange(range) - 1))
                let from = max(first, (touched.last ?? -1) + 1)
                if from <= last { touched.append(contentsOf: from...last) }
            }
            return try records(for: touched, lines: lines, text: text, isCancelled: isCancelled)
        case .withoutMatch:
            let lines = try Lines(source, isCancelled: isCancelled)
            var skipped = Set<Int>()
            for range in ranges {
                let first = lines.index(of: range.location)
                let last = lines.index(of: max(range.location, NSMaxRange(range) - 1))
                skipped.formUnion(first...last)
            }
            var bounds: NSRange?
            if let scope = request.scope {
                bounds = NSIntersectionRange(scope, NSRange(location: 0, length: source.length))
                if bounds?.length == 0 { return [] }
            }
            var wanted: [Int] = []
            for index in 0..<lines.starts.count where !skipped.contains(index) {
                if let bounds, !(lines.starts[index] < NSMaxRange(bounds) && lines.ends[index] > bounds.location) { continue }
                wanted.append(index)
            }
            return try records(for: wanted, lines: lines, text: text, isCancelled: isCancelled)
        case .template:
            return []
        }
    }

    /// Записи через "\n", в конце "\n"; пустой список даёт пустую строку.
    static func text(of records: [Record]) -> String {
        records.isEmpty ? "" : records.map(\.text).joined(separator: "\n") + "\n"
    }

    /// Границы строк текста (CR, LF, CRLF и другие разделители `NSString.lineRange`), один проход.
    private struct Lines {
        var starts: [Int] = []
        var contentEnds: [Int] = []
        var ends: [Int] = []

        init(_ source: NSString, isCancelled: () -> Bool) throws {
            var location = 0
            while location < source.length {
                if starts.count.isMultiple(of: 4096), isCancelled() { throw CancellationError() }
                var end = 0, contentsEnd = 0
                source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                starts.append(location)
                contentEnds.append(contentsEnd)
                ends.append(end)
                location = max(end, location + 1)
            }
        }

        /// Индекс строки (с 0), содержащей позицию.
        func index(of position: Int) -> Int {
            var low = 0
            var high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= position { low = mid + 1 } else { high = mid }
            }
            return max(0, low - 1)
        }
    }

    /// Текст строк без перевода строки; адреса `data:` заменяются на «…», чтобы base64 не попал в результат.
    private static func records(for indices: [Int], lines: Lines, text: String, isCancelled: () -> Bool) throws -> [Record] {
        guard !indices.isEmpty else { return [] }
        let source = text as NSString
        let addresses = MarkdownMediaTable.addressRanges(in: text)
        var addressIndex = 0
        var result: [Record] = []
        result.reserveCapacity(indices.count)
        for (count, index) in indices.enumerated() {
            if count.isMultiple(of: 512), isCancelled() { throw CancellationError() }
            let start = lines.starts[index], end = lines.contentEnds[index]
            while addressIndex < addresses.count, NSMaxRange(addresses[addressIndex]) <= start { addressIndex += 1 }
            var line = ""
            var cursor = start
            var probe = addressIndex
            while probe < addresses.count, addresses[probe].location < end {
                let address = addresses[probe]
                let from = max(address.location, start), to = min(NSMaxRange(address), end)
                if to > from {
                    if from > cursor { line += source.substring(with: NSRange(location: cursor, length: from - cursor)) }
                    line += "…"
                    cursor = to
                }
                probe += 1
            }
            if end > cursor { line += source.substring(with: NSRange(location: cursor, length: end - cursor)) }
            result.append(Record(line: index + 1, text: line))
        }
        return result
    }
}
