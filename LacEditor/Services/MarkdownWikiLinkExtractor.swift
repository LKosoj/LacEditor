import Foundation

/// Находит `[[цель#заголовок|текст]]` только в фрагментах обычного текста общего cmark-разбора.
enum MarkdownWikiLinkExtractor {
    /// Полный разбор документа: те же правила, что в редакторе (код, экранирование, HTML и т. п. исключены). Позиции в UTF-16.
    static func links(in markdown: String, syntax: MarkdownSyntaxOptions = .init(), isCancelled: @escaping () -> Bool = { false }) -> [MarkdownWikiLink] {
        guard markdown.contains("[[") else { return [] }
        return MarkdownPresentationParser.parse(markdown, includeWikiLinks: true, syntax: syntax, isCancelled: isCancelled).wikiLinks
    }

    /// `textRanges` — подтверждённые фрагменты текста, `excluded` — диапазоны, где ссылка запрещена.
    static func links(textRanges: [NSRange], excluded: [NSRange], text: NSString, isCancelled: () -> Bool = { false }) -> [MarkdownWikiLink] {
        let sortedRanges = textRanges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var series: [NSRange] = []
        for range in sortedRanges {
            if let last = series.last, NSMaxRange(last) == range.location {
                series[series.count - 1] = NSRange(location: last.location, length: last.length + range.length)
            } else { series.append(range) }
        }
        let blocked = merged(excluded)
        var result: [MarkdownWikiLink] = []
        for run in series where run.length >= 5 {
            if isCancelled() { return [] }
            guard run.location >= 0, NSMaxRange(run) <= text.length else { continue }
            let end = NSMaxRange(run)
            var index = run.location
            while index + 1 < end {
                if isCancelled() { return [] }
                guard text.character(at: index) == 91, text.character(at: index + 1) == 91 else { index += 1; continue }
                if index > 0, text.character(at: index - 1) == 33 { index += 2; continue }
                var close = index + 2
                var found = false
                while close + 1 < end {
                    let unit = text.character(at: close)
                    if unit == 93 { found = text.character(at: close + 1) == 93; break }
                    if unit == 91 || unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 { break }
                    close += 1
                }
                guard found, let link = parse(text: text, open: index, close: close) else { index += 1; continue }
                if !overlaps(link.range, blocked) { result.append(link) }
                index = NSMaxRange(link.range)
            }
        }
        return result
    }

    private static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Диапазон цели (до `#`/`|`, без краевых пробелов) подтверждённой ссылки; nil, если текст по `link.range` уже другой.
    static func targetRange(of link: MarkdownWikiLink, in text: NSString) -> NSRange? {
        let range = link.range
        guard range.location >= 0, range.length >= 4, NSMaxRange(range) <= text.length,
              text.character(at: range.location) == 91, text.character(at: range.location + 1) == 91,
              text.character(at: NSMaxRange(range) - 2) == 93, text.character(at: NSMaxRange(range) - 1) == 93,
              let parsed = parsed(text: text, open: range.location, close: NSMaxRange(range) - 2),
              parsed.link == link, parsed.target.length > 0 else { return nil }
        return parsed.target
    }

    private static func parse(text: NSString, open: Int, close: Int) -> MarkdownWikiLink? {
        parsed(text: text, open: open, close: close)?.link
    }

    private static func parsed(text: NSString, open: Int, close: Int) -> (link: MarkdownWikiLink, target: NSRange)? {
        let innerStart = open + 2
        var pipe: Int?
        var hash: Int?
        for position in innerStart..<close {
            let unit = text.character(at: position)
            if unit == 124 { pipe = position; break }
            if unit == 35, hash == nil { hash = position }
        }
        let leftEnd = pipe ?? close
        let targetRange = trimmed(NSRange(location: innerStart, length: (hash ?? leftEnd) - innerStart), in: text)
        var heading: String?
        if let hash {
            let range = trimmed(NSRange(location: hash + 1, length: leftEnd - hash - 1), in: text)
            if range.length > 0 { heading = text.substring(with: range) }
        }
        let target = text.substring(with: targetRange)
        if target.isEmpty && heading == nil { return nil }
        if target.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\0" }) { return nil }
        var alias: String?
        let display: NSRange
        if let pipe {
            display = trimmed(NSRange(location: pipe + 1, length: close - pipe - 1), in: text)
            if display.length == 0 { return nil }
            alias = text.substring(with: display)
        } else {
            display = trimmed(NSRange(location: innerStart, length: close - innerStart), in: text)
        }
        let opening = NSRange(location: open, length: display.location - open)
        let closing = NSRange(location: NSMaxRange(display), length: close + 2 - NSMaxRange(display))
        let link = MarkdownWikiLink(range: NSRange(location: open, length: close + 2 - open), displayRange: display,
                                    target: target, heading: heading, alias: alias, markerRanges: [opening, closing])
        return (link, targetRange)
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else { result.append(range) }
        }
        return result
    }

    private static func overlaps(_ range: NSRange, _ blocked: [NSRange]) -> Bool {
        var low = 0, high = blocked.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(blocked[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        return low < blocked.count && blocked[low].location < NSMaxRange(range)
    }
}
