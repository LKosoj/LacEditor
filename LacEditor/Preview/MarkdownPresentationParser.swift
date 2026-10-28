import Foundation
import cmark_gfm
import cmark_gfm_extensions

enum MarkdownPresentationParser {
    static func parse(_ text: String) -> MarkdownPresentation {
        guard !text.utf8.contains(0) else { return MarkdownPresentation(spans: []) }
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS
        guard let parser = cmark_parser_new(options) else { return MarkdownPresentation(spans: []) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink", "tagfilter"] {
            name.withCString { value in
                if let ext = cmark_find_syntax_extension(value) {
                    cmark_parser_attach_syntax_extension(parser, ext)
                }
            }
        }
        text.withCString { cmark_parser_feed(parser, $0, text.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return MarkdownPresentation(spans: []) }
        defer { cmark_node_free(root) }

        let source = Source(text)
        var spans: [MarkdownPresentationSpan] = []
        var headings: [MarkdownHeading] = []
        func headingText(_ node: OpaquePointer) -> String {
            var result = ""
            func append(_ current: OpaquePointer) {
                if let name = cmark_node_get_type_string(current) {
                    switch String(cString: name) {
                    case "text", "code":
                        if let literal = cmark_node_get_literal(current) { result += String(cString: literal) }
                    case "softbreak", "linebreak": result += " "
                    default: break
                    }
                }
                var child = cmark_node_first_child(current)
                while let next = child {
                    append(next)
                    child = cmark_node_next(next)
                }
            }
            append(node)
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func visit(_ node: OpaquePointer, inUnsupportedContainer: Bool) {
            guard let typePointer = cmark_node_get_type_string(node) else { return }
            let type = String(cString: typePointer)
            let unsupported = inUnsupportedContainer || type == "image" || type == "table"
            if !unsupported, type == "heading", let range = source.range(node) ?? source.headingAnchor(node) {
                headings.append(MarkdownHeading(
                    level: Int(cmark_node_get_heading_level(node)), title: headingText(node), range: range
                ))
            }
            if !unsupported, let range = source.range(node) {
                var span: MarkdownPresentationSpan?
                switch type {
                case "heading":
                    let level = Int(cmark_node_get_heading_level(node))
                    span = MarkdownPresentationSpan(range: range, kind: .heading(level), markerRanges: source.headingMarkers(range))
                case "strong":
                    span = MarkdownPresentationSpan(range: range, kind: .strong, markerRanges: source.pairedMarkers(range, characters: [42, 95], count: 2))
                case "emph":
                    span = MarkdownPresentationSpan(range: range, kind: .emphasis, markerRanges: source.pairedMarkers(range, characters: [42, 95], count: 1))
                case "strikethrough":
                    span = MarkdownPresentationSpan(range: range, kind: .strikethrough, markerRanges: source.pairedMarkers(range, characters: [126], count: 2))
                case "code":
                    let expanded = source.codeRange(range)
                    span = MarkdownPresentationSpan(range: expanded?.0 ?? range, kind: .code, markerRanges: expanded?.1 ?? [])
                case "link":
                    span = MarkdownPresentationSpan(range: range, kind: .link, markerRanges: source.linkMarkers(range, node: node))
                case "block_quote":
                    span = MarkdownPresentationSpan(range: range, kind: .quote, markerRanges: source.quoteMarkers(range))
                case "code_block":
                    span = MarkdownPresentationSpan(range: range, kind: .codeBlock, markerRanges: source.fenceMarkers(range))
                default: break
                }
                if let span { spans.append(span) }
            }
            var child = cmark_node_first_child(node)
            while let current = child {
                visit(current, inUnsupportedContainer: unsupported)
                child = cmark_node_next(current)
            }
        }
        visit(root, inUnsupportedContainer: false)
        return MarkdownPresentation(spans: spans, headings: headings)
    }

    private struct Source {
        let units: [UInt16]
        let bytes: [UInt8]
        let corrections: [(end: Int, delta: Int)]
        let lineStarts: [Int]
        let lineEnds: [Int]
        let lineHasTab: [Bool]

        init(_ text: String) {
            units = Array(text.utf16)
            bytes = Array(text.utf8)
            var corrections: [(end: Int, delta: Int)] = []
            var starts = [0], ends: [Int] = [], tabs: [Bool] = []
            var byte = 0, delta = 0
            var hasTab = false, previousCR = false
            for scalar in text.unicodeScalars {
                let value = scalar.value
                if value == 10 && previousCR {
                    byte += 1
                    starts[starts.count - 1] = byte
                    previousCR = false
                    continue
                }
                previousCR = false
                if value == 10 || value == 13 {
                    ends.append(byte)
                    tabs.append(hasTab)
                    byte += 1
                    starts.append(byte)
                    hasTab = false
                    previousCR = value == 13
                } else {
                    if value == 9 { hasTab = true }
                    let byteLength = value < 0x80 ? 1 : (value < 0x800 ? 2 : (value < 0x10000 ? 3 : 4))
                    byte += byteLength
                    if byteLength > 1 {
                        delta += byteLength - (value < 0x10000 ? 1 : 2)
                        corrections.append((end: byte, delta: delta))
                    }
                }
            }
            ends.append(byte)
            tabs.append(hasTab)
            self.corrections = corrections
            lineStarts = starts
            lineEnds = ends
            lineHasTab = tabs
        }

        private func utf16Offset(at byte: Int) -> Int? {
            guard byte >= 0, byte <= bytes.count,
                  byte == bytes.count || bytes[byte] & 0xc0 != 0x80 else { return nil }
            var low = 0, high = corrections.count
            while low < high {
                let middle = low + (high - low) / 2
                if corrections[middle].end <= byte { low = middle + 1 } else { high = middle }
            }
            return byte - (low == 0 ? 0 : corrections[low - 1].delta)
        }

        func range(_ node: OpaquePointer) -> NSRange? {
            let first = Int(cmark_node_get_start_line(node)) - 1
            var last = Int(cmark_node_get_end_line(node)) - 1
            let startColumn = Int(cmark_node_get_start_column(node))
            var endColumn = Int(cmark_node_get_end_column(node))
            if endColumn == 0 && last > first && last <= lineStarts.count {
                last -= 1
                endColumn = lineEnds[last] - lineStarts[last]
            }
            guard first >= 0, last >= first, last < lineStarts.count,
                  startColumn > 0, endColumn > 0,
                  !lineHasTab[first...last].contains(true) else { return nil }
            let start = lineStarts[first] + startColumn - 1
            let end = lineStarts[last] + endColumn
            guard start >= lineStarts[first], start <= lineEnds[first],
                  end >= lineStarts[last], end <= lineEnds[last], end >= start,
                  let startUTF16 = utf16Offset(at: start), let endUTF16 = utf16Offset(at: end) else { return nil }
            return NSRange(location: startUTF16, length: endUTF16 - startUTF16)
        }

        func headingAnchor(_ node: OpaquePointer) -> NSRange? {
            let line = Int(cmark_node_get_start_line(node)) - 1
            guard line >= 0, line < lineStarts.count,
                  let offset = utf16Offset(at: lineStarts[line]) else { return nil }
            return NSRange(location: offset, length: 0)
        }

        func pairedMarkers(_ range: NSRange, characters: [UInt16], count: Int) -> [NSRange] {
            let start = range.location, end = NSMaxRange(range)
            guard range.length > count * 2, end <= units.count,
                  characters.contains(units[start]) else { return [] }
            let character = units[start]
            guard units[start..<start + count].allSatisfy({ $0 == character }),
                  units[end - count..<end].allSatisfy({ $0 == character }),
                  units[start + count] != character, units[end - count - 1] != character else { return [] }
            return [NSRange(location: start, length: count), NSRange(location: end - count, length: count)]
        }

        func headingMarkers(_ range: NSRange) -> [NSRange] {
            let start = range.location, end = NSMaxRange(range)
            var index = start
            while index < end && units[index] == 35 { index += 1 }
            guard index > start, index - start <= 6, index < end,
                  units[index] == 32 || units[index] == 9 else { return [] }
            return [NSRange(location: start, length: index - start + 1)]
        }

        func codeRange(_ range: NSRange) -> (NSRange, [NSRange])? {
            let start = range.location, end = NSMaxRange(range)
            guard start > 0, end < units.count else { return nil }
            var left = start, right = end
            while left > 0 && units[left - 1] == 96 { left -= 1 }
            while right < units.count && units[right] == 96 { right += 1 }
            guard start - left > 0, start - left == right - end else { return nil }
            return (NSRange(location: left, length: right - left),
                    [NSRange(location: left, length: start - left), NSRange(location: end, length: right - end)])
        }

        func linkMarkers(_ range: NSRange, node: OpaquePointer) -> [NSRange] {
            let start = range.location, end = NSMaxRange(range)
            guard range.length >= 5, units[start] == 91, units[end - 1] == 41 else { return [] }
            var child = cmark_node_first_child(node), last: OpaquePointer?
            while let current = child { last = current; child = cmark_node_next(current) }
            guard let last, let lastRange = self.range(last) else { return [] }
            let suffix = NSMaxRange(lastRange)
            guard suffix + 2 < end, units[suffix] == 93, units[suffix + 1] == 40 else { return [] }
            return [NSRange(location: start, length: 1), NSRange(location: suffix, length: end - suffix)]
        }

        func quoteMarkers(_ range: NSRange) -> [NSRange] {
            let end = NSMaxRange(range)
            var index = range.location, markers: [NSRange] = []
            while index < end {
                let lineStart = index
                while index < end && units[index] == 32 && index - lineStart < 3 { index += 1 }
                if index < end && units[index] == 62 {
                    markers.append(NSRange(location: index, length: 1))
                }
                while index < end && units[index] != 10 && units[index] != 13 { index += 1 }
                while index < end && (units[index] == 10 || units[index] == 13) { index += 1 }
            }
            return markers
        }

        func fenceMarkers(_ range: NSRange) -> [NSRange] {
            let start = range.location, end = NSMaxRange(range)
            guard start < end, units[start] == 96 || units[start] == 126 else { return [] }
            let character = units[start]
            var openingEnd = start
            while openingEnd < end && units[openingEnd] == character { openingEnd += 1 }
            guard openingEnd - start >= 3 else { return [] }
            var closeStart = end
            while closeStart > openingEnd && units[closeStart - 1] == character { closeStart -= 1 }
            var lineStart = closeStart
            while lineStart > 0 && units[lineStart - 1] != 10 && units[lineStart - 1] != 13 { lineStart -= 1 }
            guard end - closeStart >= openingEnd - start, closeStart - lineStart <= 3,
                  units[lineStart..<closeStart].allSatisfy({ $0 == 32 }) else { return [] }
            return [NSRange(location: start, length: openingEnd - start), NSRange(location: closeStart, length: end - closeStart)]
        }
    }
}
