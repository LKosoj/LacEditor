import Foundation

private final class MarkdownRubyBaseParseState {
    var isValid = true
    var isStyled = false
}
import cmark_gfm
import cmark_gfm_extensions
import SwiftSoup

enum MarkdownPresentationParser {
    // The two non-strict list forms use existing nodes and source positions.
    static func recoverLooseLists(_ root: OpaquePointer, text: String, isCancelled: () -> Bool) -> (ranges: [OpaquePointer: NSRange], indents: [MarkdownLooseIndent])? {
        let source = Source(text, interruptIndexing: true, isCancelled: isCancelled)
        let raw = text as NSString
        var ranges: [OpaquePointer: NSRange] = [:]
        var indents: [MarkdownLooseIndent] = []
        var adjacentLists: [(OpaquePointer, OpaquePointer)] = []

        func plainParagraph(_ node: OpaquePointer) -> NSRange? {
            guard cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH,
                  let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
                  cmark_node_get_type(child) == CMARK_NODE_TEXT,
                  let literal = cmark_node_get_literal(child), let range = source.range(child),
                  let paragraph = source.range(node), range == paragraph,
                  range.location >= 0, range.length <= raw.length - range.location,
                  raw.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) else { return nil }
            return range
        }

        func marker(_ item: OpaquePointer) -> (start: Int, width: Int, number: Int)? {
            guard let start = source.firstPosition(item), start >= 0, start < raw.length else { return nil }
            var end = start
            while end < raw.length, (48...57).contains(raw.character(at: end)), end - start < 9 { end += 1 }
            guard end > start, end + 1 < raw.length, raw.character(at: end) == 46,
                  raw.character(at: end + 1) == 32,
                  let number = Int(raw.substring(with: NSRange(location: start, length: end - start))) else { return nil }
            return (start, end + 2 - start, number)
        }

        func gap(from start: Int, to end: Int, breaks: Int) -> NSRange? {
            guard start >= 0, end >= start, end <= raw.length else { return nil }
            var position = start
            for _ in 0..<breaks {
                guard position < end else { return nil }
                let unit = raw.character(at: position)
                guard unit == 10 || unit == 13 else { return nil }
                position += 1
                if unit == 13, position < end, raw.character(at: position) == 10 { position += 1 }
            }
            let indent = position
            while position < end, raw.character(at: position) == 32 {
                if isCancelled() { return nil }
                position += 1
            }
            return position == end ? NSRange(location: indent, length: end - indent) : nil
        }

        var node = cmark_node_first_child(root)
        while let list = node {
            if isCancelled() { break }
            let next = cmark_node_next(list)
            node = next
            guard cmark_node_get_type(list) == CMARK_NODE_LIST,
                  cmark_node_get_list_type(list) == CMARK_ORDERED_LIST,
                  let first = cmark_node_first_child(list), cmark_node_get_type(first) == CMARK_NODE_ITEM,
                  let firstMarker = marker(first), firstMarker.number == Int(cmark_node_get_list_start(list)),
                  let paragraph = cmark_node_first_child(first), cmark_node_next(paragraph) == nil,
                  let firstText = plainParagraph(paragraph), firstText.location == firstMarker.start + firstMarker.width,
                  let firstRange = source.range(first), let listRange = source.range(list) else { continue }

            if let second = cmark_node_next(first), cmark_node_next(second) == nil,
               cmark_node_get_type(second) == CMARK_NODE_ITEM, let secondMarker = marker(second),
               let secondParagraph = cmark_node_first_child(second), cmark_node_next(secondParagraph) == nil,
               let secondText = plainParagraph(secondParagraph), secondText.location == secondMarker.start + secondMarker.width,
               let secondRange = source.range(second),
               let indent = gap(from: NSMaxRange(firstText), to: secondMarker.start, breaks: 1),
               indent.length >= 2, indent.length < firstMarker.width,
               let nested = cmark_node_new(CMARK_NODE_LIST) {
                guard cmark_node_set_list_type(nested, CMARK_ORDERED_LIST) != 0,
                      cmark_node_set_list_delim(nested, CMARK_PERIOD_DELIM) != 0,
                      cmark_node_set_list_start(nested, Int32(secondMarker.number)) != 0,
                      cmark_node_set_list_tight(nested, 1) != 0 else { cmark_node_free(nested); continue }
                cmark_node_unlink(second)
                guard cmark_node_append_child(nested, second) != 0 else {
                    _ = cmark_node_insert_after(first, second); cmark_node_free(nested); continue
                }
                guard cmark_node_append_child(first, nested) != 0 else {
                    cmark_node_unlink(second); _ = cmark_node_insert_after(first, second); cmark_node_free(nested); continue
                }
                ranges[first] = NSRange(location: firstRange.location, length: NSMaxRange(secondRange) - firstRange.location)
                ranges[OpaquePointer(nested)] = secondRange
                indents.append(.init(range: indent, replacement: String(repeating: " ", count: firstMarker.width)))
            } else if cmark_node_next(first) == nil, let next,
                      let secondText = plainParagraph(next),
                      let indent = gap(from: NSMaxRange(firstText), to: secondText.location, breaks: 2),
                      indent.length >= 2, indent.length < firstMarker.width {
                let after = cmark_node_next(next)
                var adjacent: OpaquePointer?
                if let after, cmark_node_get_type(after) == CMARK_NODE_LIST,
                   cmark_node_get_list_type(after) == cmark_node_get_list_type(list),
                   cmark_node_get_list_delim(after) == cmark_node_get_list_delim(list) {
                    guard let afterRange = source.range(after), afterRange.location >= NSMaxRange(secondText) else { continue }
                    var position = NSMaxRange(secondText), hasNewline = false, valid = true
                    while position < afterRange.location {
                        if isCancelled() { return nil }
                        let unit = raw.character(at: position)
                        if unit == 10 || unit == 13 { hasNewline = true }
                        else if unit != 32 && unit != 9 { valid = false; break }
                        position += 1
                    }
                    if valid && hasNewline {
                        var candidate = cmark_node_first_child(after), confirmed = candidate != nil
                        var previousEnd = afterRange.location
                        while let current = candidate {
                            if isCancelled() { return nil }
                            guard cmark_node_get_type(current) == CMARK_NODE_ITEM,
                                  cmark_node_get_type_string(current).map({ String(cString: $0) == "item" }) == true,
                                  let range = source.range(current), range.location >= previousEnd,
                                  NSMaxRange(range) <= NSMaxRange(afterRange) else { confirmed = false; break }
                            previousEnd = NSMaxRange(range)
                            candidate = cmark_node_next(current)
                        }
                        guard confirmed else { continue }
                        adjacent = after
                    }
                }
                cmark_node_unlink(next)
                guard cmark_node_append_child(first, next) != 0 else { _ = cmark_node_insert_after(list, next); continue }
                _ = cmark_node_set_list_tight(list, 0)
                ranges[first] = NSRange(location: firstRange.location, length: NSMaxRange(secondText) - firstRange.location)
                ranges[list] = NSRange(location: listRange.location, length: NSMaxRange(secondText) - listRange.location)
                indents.append(.init(range: indent, replacement: String(repeating: " ", count: firstMarker.width)))
                if let adjacent { adjacentLists.append((list, adjacent)) }
                node = after
            }
        }
        for (list, adjacent) in adjacentLists.reversed() {
            if isCancelled() { return nil }
            guard cmark_node_next(list) == adjacent,
                  let listRange = ranges[list], let adjacentRange = ranges[adjacent] ?? source.range(adjacent),
                  adjacentRange.location >= NSMaxRange(listRange) else { return nil }
            var item = cmark_node_first_child(adjacent)
            while let current = item {
                if isCancelled() { return nil }
                item = cmark_node_next(current)
                guard cmark_node_get_type(current) == CMARK_NODE_ITEM,
                      let range = ranges[current] ?? source.range(current),
                      range.location >= adjacentRange.location, NSMaxRange(range) <= NSMaxRange(adjacentRange) else { return nil }
                cmark_node_unlink(current)
                guard cmark_node_append_child(list, current) != 0 else { cmark_node_free(current); return nil }
            }
            ranges[list] = NSRange(location: listRange.location, length: NSMaxRange(adjacentRange) - listRange.location)
            ranges.removeValue(forKey: adjacent)
            cmark_node_unlink(adjacent)
            cmark_node_free(adjacent)
        }
        return (ranges, indents)
    }

    private static func fencePrefixes(_ node: OpaquePointer, source: Source, text: NSString,
                                      position: Int, allowEarlierItem: Bool = true, includeNode: Bool = false,
                                      itemStartColumn: ((OpaquePointer) -> (Int, String)?)? = nil) -> (line: NSRange, source: String, continuation: String, nested: Bool)? {
        guard position >= 0, position <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: position, length: 0))
        let original = text.substring(with: NSRange(location: line.location, length: position - line.location))
        var prefix = Array(original.utf16)
        guard prefix.allSatisfy({ $0 < 128 }) else { return nil }
        var ancestor = includeNode ? node : cmark_node_parent(node)
        var quoteDepth = 0, earlierItems: [OpaquePointer] = []
        let nested = ancestor.map { cmark_node_get_type($0) != CMARK_NODE_DOCUMENT } ?? false
        while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
            let type = cmark_node_get_type(current)
            guard type == CMARK_NODE_BLOCK_QUOTE || type == CMARK_NODE_LIST || type == CMARK_NODE_ITEM else { return nil }
            if type == CMARK_NODE_BLOCK_QUOTE { quoteDepth += 1 }
            if type == CMARK_NODE_ITEM {
                guard let item = source.firstPosition(current), item < position else { return nil }
                if item < line.location {
                    if !allowEarlierItem { earlierItems.append(current) }
                    ancestor = cmark_node_parent(current)
                    continue
                }
                var i = item - line.location
                if prefix[i] == 45 || prefix[i] == 43 || prefix[i] == 42 {
                    prefix[i] = 32
                } else {
                    let begin = i
                    while i < prefix.count && prefix[i] >= 48 && prefix[i] <= 57 { i += 1 }
                    guard i > begin, i < prefix.count, prefix[i] == 46 || prefix[i] == 41 else { return nil }
                    for index in begin...i { prefix[index] = 32 }
                }
            }
            ancestor = cmark_node_parent(current)
        }
        guard ancestor != nil, prefix.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 62 }),
              prefix.filter({ $0 == 62 }).count == quoteDepth else { return nil }
        if !earlierItems.isEmpty {
            func column(_ units: [UInt16]) -> Int {
                units.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
            }
            let currentColumn = column(prefix)
            func quotePrefix(_ units: [UInt16]) -> String {
                guard let last = units.lastIndex(of: 62) else { return "" }
                var end = last + 1
                if end < units.count && (units[end] == 32 || units[end] == 9) { end += 1 }
                return String(decoding: units[..<end], as: UTF16.self)
            }
            let currentQuotes = quotePrefix(prefix)
            for item in earlierItems {
                guard let (required, initialQuotes) = itemStartColumn?(item), currentColumn >= required,
                      currentQuotes == initialQuotes else { return nil }
            }
        }
        return (line, original, String(decoding: prefix, as: UTF16.self), nested)
    }

    static func containerHTMLPrefixes(_ node: OpaquePointer, range: NSRange, source: Source, sourceText: NSString, isCancelled: () -> Bool) -> [NSRange]? {
        guard let literalPointer = cmark_node_get_literal(node), range.length > 0,
              NSMaxRange(range) <= sourceText.length else { return nil }
        let literal = String(cString: literalPointer) as NSString
        var offset = 0, cursor = range.location, prefixes: [NSRange] = [], first = true
        while offset < literal.length {
            if isCancelled() { return nil }
            let remaining = NSRange(location: offset, length: literal.length - offset)
            let newline = literal.range(of: "\n", options: .literal, range: remaining)
            let end = newline.location == NSNotFound ? literal.length : newline.location
            let length = end - offset
            let line = sourceText.lineRange(for: NSRange(location: cursor, length: 0))
            var contentEnd = min(NSMaxRange(line), NSMaxRange(range))
            while contentEnd > cursor && [10, 13].contains(Int(sourceText.character(at: contentEnd - 1))) { contentEnd -= 1 }
            let start = contentEnd - length
            guard start >= cursor, (!first || start == range.location),
                  let proof = fencePrefixes(node, source: source, text: sourceText, position: start), proof.nested,
                  sourceText.substring(with: NSRange(location: start, length: length)).utf16
                    .elementsEqual(literal.substring(with: NSRange(location: offset, length: length)).utf16) else { return nil }
            if !first && start > line.location { prefixes.append(NSRange(location: line.location, length: start - line.location)) }
            first = false
            if newline.location == NSNotFound { return contentEnd == NSMaxRange(range) ? prefixes : nil }
            offset = newline.location + 1
            if offset == literal.length { return contentEnd == NSMaxRange(range) ? prefixes : nil }
            guard NSMaxRange(line) > cursor, NSMaxRange(line) <= NSMaxRange(range) else { return nil }
            cursor = NSMaxRange(line)
        }
        return nil
    }

    static func containerPrefixes(_ node: OpaquePointer, source: Source, text: NSString, isCancelled: @escaping () -> Bool = { false }) -> (source: String, continuation: String)? {
        var cached: [OpaquePointer: (Int, String)] = [:]
        func itemColumn(_ item: OpaquePointer) -> (Int, String)? {
            if isCancelled() { return nil }
            if let result = cached[item] { return result }
            guard let marker = source.firstPosition(item), marker < text.length,
                  let ancestors = fencePrefixes(item, source: source, text: text, position: marker,
                                                allowEarlierItem: false, itemStartColumn: itemColumn) else { return nil }
            var end = marker
            let first = text.character(at: end)
            if first == 45 || first == 43 || first == 42 { end += 1 }
            else {
                while end < text.length && text.character(at: end) >= 48 && text.character(at: end) <= 57 {
                    if isCancelled() { return nil }
                    end += 1
                }
                guard end > marker, end < text.length, text.character(at: end) == 46 || text.character(at: end) == 41 else { return nil }
                end += 1
            }
            let prefix = Array(ancestors.continuation.utf16)
            var column = prefix.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
            column += end - marker
            let padding = column
            while end < text.length && (text.character(at: end) == 32 || text.character(at: end) == 9) {
                if isCancelled() { return nil }
                column = text.character(at: end) == 9 ? (column / 4 + 1) * 4 : column + 1
                end += 1
            }
            guard (1...4).contains(column - padding), end < text.length,
                  text.character(at: end) != 10, text.character(at: end) != 13 else { return nil }
            var quoteEnd = prefix.lastIndex(of: 62).map { $0 + 1 } ?? 0
            if quoteEnd > 0 && quoteEnd < prefix.count && (prefix[quoteEnd] == 32 || prefix[quoteEnd] == 9) { quoteEnd += 1 }
            let result = (column, String(decoding: prefix[..<quoteEnd], as: UTF16.self))
            cached[item] = result
            return result
        }
        guard let position = source.firstPosition(node) else { return nil }
        var prefixPosition = position
        if cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH, let parent = cmark_node_parent(node),
           let name = cmark_node_get_type_string(parent), String(cString: name) == "tasklist" {
            guard let checkbox = source.taskCheckbox(parent), itemColumn(parent) != nil,
                  (checkbox.state != 32) == cmark_gfm_extensions_get_tasklist_item_checked(parent),
                  NSMaxRange(checkbox.markerRange) < position else { return nil }
            var cursor = NSMaxRange(checkbox.markerRange)
            while cursor < position && (text.character(at: cursor) == 32 || text.character(at: cursor) == 9) {
                if isCancelled() { return nil }
                cursor += 1
            }
            guard cursor == position else { return nil }
            prefixPosition = checkbox.markerRange.location
        }
        guard let prefixes = fencePrefixes(node, source: source, text: text, position: prefixPosition,
                                           allowEarlierItem: false, itemStartColumn: itemColumn), !isCancelled() else { return nil }
        return (prefixes.source, prefixes.continuation)
    }

    static func listContainerPrefixes(_ item: OpaquePointer, source: Source, text: NSString) -> (source: String, continuation: String)? {
        guard cmark_node_get_type(item) == CMARK_NODE_ITEM else { return nil }
        return containerPrefixes(item, source: source, text: text)
    }

    private static func simpleEmptyFencePrefix(_ source: String) -> Bool {
        let units = Array(source.utf16)
        var position = 0, column = 0, quoteBaseline = 0, quotes = 0
        func advance(_ unit: UInt16) { column = unit == 9 ? (column / 4 + 1) * 4 : column + 1 }
        while position < units.count && units[position] == 62 {
            advance(units[position]); position += 1; quotes += 1
            quoteBaseline = column
            if position < units.count && (units[position] == 32 || units[position] == 9) {
                quoteBaseline += 1
                advance(units[position]); position += 1
            }
        }
        while position < units.count && (units[position] == 32 || units[position] == 9) {
            advance(units[position]); position += 1
        }
        let indent = column - (quotes > 0 ? quoteBaseline : 0)
        guard indent <= 3 else { return false }
        if position == units.count { return quotes > 0 }
        let start = position
        if [42, 43, 45].contains(units[position]) { advance(units[position]); position += 1 }
        else {
            while position < units.count && (48...57).contains(units[position]) { advance(units[position]); position += 1 }
            guard position > start, position - start <= 9, position < units.count,
                  units[position] == 46 || units[position] == 41 else { return false }
            advance(units[position]); position += 1
        }
        let markerEnd = column
        while position < units.count && (units[position] == 32 || units[position] == 9) {
            advance(units[position]); position += 1
        }
        return position == units.count && (1...4).contains(column - markerEnd)
    }

    static func fencedCodeBlock(_ node: OpaquePointer, source: Source, text: NSString,
                                        range: NSRange, info: String, literal: String,
                                        isCancelled: () -> Bool) -> MarkdownCodeBlock? {
        guard let prefixes = fencePrefixes(node, source: source, text: text, position: range.location) else { return nil }
        let openingLine = prefixes.line
        let prefix = Array(prefixes.continuation.utf16)
        let quoteCount = prefix.filter { $0 == 62 }.count
        func validPrefix(_ value: NSString) -> Bool {
            var quotes = 0
            for i in 0..<value.length {
                let unit = value.character(at: i)
                if unit == 62 { quotes += 1 }
                else if unit != 32 && unit != 9 { return false }
            }
            return quotes == quoteCount
        }
        let marker = text.character(at: range.location)
        guard marker == 96 || marker == 126 else { return nil }
        var openingEnd = range.location
        while openingEnd < text.length && text.character(at: openingEnd) == marker { openingEnd += 1 }
        guard openingEnd - range.location >= 3 else { return nil }
        var infoEnd = openingEnd
        while infoEnd < NSMaxRange(openingLine) && text.character(at: infoEnd) != 10 && text.character(at: infoEnd) != 13 { infoEnd += 1 }
        let infoRange = NSRange(location: openingEnd, length: infoEnd - openingEnd)
        let lastLine = text.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
        var closed = false
        var markers = [NSRange(location: range.location, length: openingEnd - range.location)]
        if lastLine.location > openingLine.location {
            var end = NSMaxRange(lastLine)
            while end > lastLine.location && (text.character(at: end - 1) == 10 || text.character(at: end - 1) == 13) { end -= 1 }
            let line = text.substring(with: NSRange(location: lastLine.location, length: end - lastLine.location)) as NSString
            var i = line.length
            while i > 0 && (line.character(at: i - 1) == 32 || line.character(at: i - 1) == 9) { i -= 1 }
            let markerEnd = i
            while i > 0 && line.character(at: i - 1) == marker { i -= 1 }
            closed = markerEnd - i >= openingEnd - range.location && validPrefix(line.substring(to: i) as NSString)
            if closed { markers.append(NSRange(location: lastLine.location + i, length: markerEnd - i)) }
        }
        let bodyStart = NSMaxRange(openingLine)
        let bodyEnd = closed ? lastLine.location : min(text.length, NSMaxRange(lastLine))
        guard bodyEnd >= bodyStart else { return nil }
        var lines = literal.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var segments: [NSRange] = [], padding: [Int] = [], parts: [String] = [], position = bodyStart, lineIndex = 0
        while position < bodyEnd {
            if isCancelled() { return nil }
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            guard line.location == position, NSMaxRange(line) <= bodyEnd, lineIndex < lines.count else { return nil }
            var contentEnd = NSMaxRange(line)
            while contentEnd > position && (text.character(at: contentEnd - 1) == 10 || text.character(at: contentEnd - 1) == 13) { contentEnd -= 1 }
            let content = lines[lineIndex] as NSString
            var missing = 0, contentStart: Int?
            // A partially consumed four-column tab can contribute at most three spaces.
            while missing <= content.length && missing <= 3 {
                let length = content.length - missing
                if length <= contentEnd - position {
                    let start = contentEnd - length
                    let prefix = text.substring(with: NSRange(location: position, length: start - position)) as NSString
                    if text.substring(with: NSRange(location: start, length: length)) == content.substring(from: missing),
                       validPrefix(prefix),
                       (missing == 0 || (prefix.length > 0 && prefix.character(at: prefix.length - 1) == 9)) {
                        contentStart = start
                        break
                    }
                }
                guard missing < content.length && content.character(at: missing) == 32 else { break }
                missing += 1
            }
            guard let contentStart else { return nil }
            let segment = NSRange(location: contentStart, length: NSMaxRange(line) - contentStart)
            segments.append(segment)
            padding.append(missing)
            parts.append(String(repeating: " ", count: missing) + text.substring(with: segment))
            position = NSMaxRange(line)
            lineIndex += 1
        }
        guard lineIndex == lines.count else { return nil }
        let raw = parts.joined().replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard raw == literal || (!raw.hasSuffix("\n") && raw + "\n" == literal) else { return nil }
        let end = max(NSMaxRange(range), bodyEnd)
        return MarkdownCodeBlock(range: NSRange(location: range.location, length: end - range.location),
                                 bodyRange: NSRange(location: bodyStart, length: bodyEnd - bodyStart),
                                 bodySegments: segments, bodyPadding: padding, infoRange: infoRange, fenceMarkers: markers, continuationPrefix: prefixes.continuation, isNested: prefixes.nested, isClosed: closed, info: info, literal: literal)
    }

    struct Projection {
        let text: String
        let rawBoundaries: [Int]
    }

    static func projection(_ raw: String) -> Projection {
        let source = raw as NSString
        let transforms = tableCellTransforms(raw)
        var units: [UInt16] = [], boundaries = [0], cursor = 0
        for transform in transforms {
            guard transform.range.location >= cursor, NSMaxRange(transform.range) <= source.length else { continue }
            while cursor < transform.range.location {
                units.append(source.character(at: cursor))
                cursor += 1
                boundaries.append(cursor)
            }
            let replacement = Array(transform.replacement.utf16)
            guard replacement.count == 1 else { continue }
            units.append(replacement[0])
            cursor = NSMaxRange(transform.range)
            boundaries.append(cursor)
        }
        while cursor < source.length {
            units.append(source.character(at: cursor))
            cursor += 1
            boundaries.append(cursor)
        }
        return Projection(text: String(decoding: units, as: UTF16.self), rawBoundaries: boundaries)
    }

    static func tableDisplay(_ table: MarkdownTable, text: NSString, previous: MarkdownTable? = nil,
                             changedRow: Int? = nil, changedColumn: Int? = nil,
                             node: OpaquePointer? = nil, source: Source? = nil,
                             mathInline: [OpaquePointer: MarkdownMathExtension.Inline] = [:],
                             emojiCandidates: [MarkdownEmojiCandidate] = [], confirmedHTMLImages: Set<NSRange> = [], confirmedInlineHTML: Set<OpaquePointer> = [], syntax: MarkdownSyntaxOptions = .init(), isCancelled: @escaping () -> Bool = { false }) -> MarkdownTable {
        var nodeRows: [[OpaquePointer]] = []
        if let node {
            var row = cmark_node_first_child(node)
            while let current = row {
                var cells: [OpaquePointer] = [], cell = cmark_node_first_child(current)
                while let item = cell { cells.append(item); cell = cmark_node_next(item) }
                nodeRows.append(cells)
                row = cmark_node_next(current)
            }
        }
        var labels = Set(previous?.referenceLabels ?? table.referenceLabels)
        if let source {
            for row in nodeRows {
                for cell in row {
                    guard let positions = source.tableCellPositions(cell) else { continue }
                    func collect(_ node: OpaquePointer) {
                        if let name = cmark_node_get_type_string(node), String(cString: name) == "link",
                           let range = source.tableInlineRange(node, positions: positions),
                           let label = referenceLabel(text.substring(with: range)) { labels.insert(label) }
                        var child = cmark_node_first_child(node)
                        while let next = child { collect(next); child = cmark_node_next(next) }
                    }
                    collect(cell)
                }
            }
        }
        let referenceLabels = labels.sorted()
        let rows = table.rows.enumerated().map { rowIndex, row in
            let cells = row.cells.map { cell in
                let isChanged = row.range.location == changedRow && cell.column == changedColumn
                let old: MarkdownTableCell? = previous.flatMap { old in
                    guard rowIndex < old.rows.count, cell.column < old.rows[rowIndex].cells.count else { return nil }
                    return old.rows[rowIndex].cells[cell.column]
                }
                let reusable = !isChanged && old?.virtualSeparators == cell.virtualSeparators ? old : nil
                let display: (String, [MarkdownTableTextRun])
                if let reusable, let value = reusable.displayText {
                    display = (value, reusable.displayRuns)
                } else if let source, rowIndex < nodeRows.count, cell.column < nodeRows[rowIndex].count {
                    display = renderedCell(nodeRows[rowIndex][cell.column], source: source, text: text, mathInline: mathInline, cellRange: cell.range, emojiCandidates: emojiCandidates, confirmedHTMLImages: confirmedHTMLImages, confirmedInlineHTML: confirmedInlineHTML, syntax: syntax, isCancelled: isCancelled)
                } else {
                    display = renderedCell(text.substring(with: cell.range), referenceLabels: referenceLabels, syntax: syntax)
                }
                return MarkdownTableCell(range: cell.range, column: cell.column, virtualSeparators: cell.virtualSeparators,
                                         displayText: display.0, displayRuns: display.1)
            }
            return MarkdownTableRow(range: row.range, cells: cells)
        }
        return MarkdownTable(range: table.range, delimiterRange: table.delimiterRange, alignments: table.alignments,
                             rows: rows, containerPrefix: table.containerPrefix, quoteDepth: table.quoteDepth, nestedList: table.nestedList,
                             referenceLabels: referenceLabels)
    }

    private static func referenceLabel(_ raw: String) -> String? {
        let value = raw as NSString
        guard value.length >= 3, value.character(at: 0) == 91 else { return nil }
        func close(_ start: Int) -> Int? {
            var depth = 1, index = start + 1
            while index < value.length {
                let unit = value.character(at: index)
                if unit == 92 && index + 1 < value.length { index += 2; continue }
                if unit == 91 { depth += 1 }
                if unit == 93 { depth -= 1; if depth == 0 { return index } }
                index += 1
            }
            return nil
        }
        guard let firstEnd = close(0) else { return nil }
        let labelRange: NSRange
        if firstEnd == value.length - 1 {
            labelRange = NSRange(location: 1, length: firstEnd - 1)
        } else {
            let secondStart = firstEnd + 1
            guard value.character(at: secondStart) == 91, let secondEnd = close(secondStart), secondEnd == value.length - 1 else { return nil }
            labelRange = secondEnd == secondStart + 1 ? NSRange(location: 1, length: firstEnd - 1) :
                NSRange(location: secondStart + 1, length: secondEnd - secondStart - 1)
        }
        guard labelRange.length > 0 else { return nil }
        return value.substring(with: labelRange)
    }

    static func tableRowDisplay(_ row: MarkdownTableRow, text: NSString, previous: MarkdownTableRow,
                                changedColumn: Int, referenceLabels: [String], syntax: MarkdownSyntaxOptions = .init()) -> MarkdownTableRow {
        let cells = row.cells.map { cell in
            let old = cell.column < previous.cells.count ? previous.cells[cell.column] : nil
            let reusable = cell.column != changedColumn && old?.virtualSeparators == cell.virtualSeparators ? old : nil
            let display: (String, [MarkdownTableTextRun])
            if let reusable, let value = reusable.displayText { display = (value, reusable.displayRuns) }
            else { display = renderedCell(text.substring(with: cell.range), referenceLabels: referenceLabels, syntax: syntax) }
            return MarkdownTableCell(range: cell.range, column: cell.column, virtualSeparators: cell.virtualSeparators,
                                     displayText: display.0, displayRuns: display.1)
        }
        return MarkdownTableRow(range: row.range, cells: cells)
    }

    private static func renderedCell(_ cell: OpaquePointer, source: Source, text: NSString,
                                     mathInline: [OpaquePointer: MarkdownMathExtension.Inline] = [:], cellRange: NSRange? = nil,
                                     emojiCandidates: [MarkdownEmojiCandidate] = [], confirmedHTMLImages: Set<NSRange> = [],
                                     confirmedInlineHTML: Set<OpaquePointer> = [], syntax: MarkdownSyntaxOptions = .init(), isCancelled: @escaping () -> Bool = { false }) -> (String, [MarkdownTableTextRun]) {
        let output = NSMutableString(string: ""), positions = source.tableCellPositions(cell)
        var runs: [MarkdownTableTextRun] = []
        var invalidKeyboard = false
        var invalidInlineStyle = false
        var previousSpace = false
        func visit(_ node: OpaquePointer) {
            guard !isCancelled(), let pointer = cmark_node_get_type_string(node) else { return }
            let type = String(cString: pointer), start = output.length
            switch type {
            case "text", "code":
                if let literal = cmark_node_get_literal(node) {
                    let value = String(cString: literal)
                    let raw = value as NSString
                    let range = positions.flatMap { source.tableInlineRange(node, positions: $0) }
                    let pieces = range.flatMap { range in
                        MarkdownInlineTextProjection.pieces(spelling: text.substring(with: range) as NSString,
                            literal: value, sourceOffset: range.location, isCancelled: isCancelled)
                    }
                    var boundaries = [Int](repeating: 0, count: raw.length + 1)
                    if type == "text", !(syntax.preserveEditingWhitespace ?? false), pieces != nil {
                        var runStart = 0
                        for index in 0..<raw.length {
                            if isCancelled() { return }
                            let unit = raw.character(at: index)
                            let space = unit == 32 || unit == 9
                            if space && (previousSpace || unit == 9) {
                                if index > runStart { output.append(raw.substring(with: NSRange(location: runStart, length: index - runStart))) }
                                if !previousSpace { output.append(" ") }
                                runStart = index + 1
                            }
                            previousSpace = space
                            boundaries[index + 1] = output.length - start + index + 1 - runStart
                        }
                        if raw.length > runStart { output.append(raw.substring(with: NSRange(location: runStart, length: raw.length - runStart))) }
                    } else {
                        output.append(value)
                        for index in 0...raw.length { boundaries[index] = index }
                        previousSpace = false
                    }
                    if type == "text", !emojiCandidates.isEmpty, let cellRange, let pieces {
                        var displayOffset = start
                        for piece in pieces {
                            if isCancelled() { return }
                            if piece.matchesSource {
                                var low = 0, high = emojiCandidates.count
                                while low < high {
                                    let middle = (low + high) / 2
                                    if emojiCandidates[middle].range.location < piece.sourceRange.location { low = middle + 1 } else { high = middle }
                                }
                                while low < emojiCandidates.count {
                                    if isCancelled() { return }
                                    let candidate = emojiCandidates[low]
                                    if candidate.range.location >= NSMaxRange(piece.sourceRange) { break }
                                    if NSMaxRange(candidate.range) <= NSMaxRange(piece.sourceRange),
                                       candidate.range.location >= cellRange.location, NSMaxRange(candidate.range) <= NSMaxRange(cellRange) {
                                        let first = displayOffset + candidate.range.location - piece.sourceRange.location - start
                                        let last = first + candidate.range.length
                                        if first >= 0, last < boundaries.count {
                                            let display = NSRange(location: start + boundaries[first], length: boundaries[last] - boundaries[first])
                                            let relative = NSRange(location: candidate.range.location - cellRange.location, length: candidate.range.length)
                                            runs.append(MarkdownTableTextRun(range: display, kind: .tableEmoji(relative)))
                                        }
                                    }
                                    low += 1
                                }
                            }
                            displayOffset += (piece.text as NSString).length
                        }
                    }
                }
            case "softbreak", "linebreak": previousSpace = false; output.append("\n")
            case "image":
                previousSpace = false
                if let positions, let cellRange, let range = source.tableInlineRange(node, positions: positions),
                   range.length >= 4, range.location >= cellRange.location, NSMaxRange(range) <= NSMaxRange(cellRange),
                   text.substring(with: NSRange(location: range.location, length: 2)) == "![" {
                    output.append(text.substring(with: range))
                    let local = NSRange(location: range.location - cellRange.location, length: range.length)
                    runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .tableImage(local)))
                } else {
                    var child = cmark_node_first_child(node)
                    while let next = child { visit(next); child = cmark_node_next(next) }
                }
            case "custom_inline":
                previousSpace = false
                if let math = mathInline[node] {
                    output.append("$" + math.text + "$")
                    if let parent = cmark_node_parent(node),
                       let range = source.mathInlineRange(line: math.line, column: math.column, byteLength: math.byteLength, parent: parent),
                       let cellRange, range.location >= cellRange.location, NSMaxRange(range) <= NSMaxRange(cellRange) {
                        let local = NSRange(location: range.location - cellRange.location, length: range.length)
                        runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .tableMath(local)))
                    }
                }
            case "html_inline":
                if let literal = cmark_node_get_literal(node) {
                    let tag = String(cString: literal).lowercased()
                    if tag.hasPrefix("<kbd") || tag.hasPrefix("</kbd") { invalidKeyboard = true }
                    if isSpanOpening(tag) && MarkdownHTMLMediaService.hasStyledSpan(in: String(cString: literal), isCancelled: isCancelled) { invalidInlineStyle = true }
                }
                if let positions,
                   let range = source.tableInlineRange(node, positions: positions),
                   let literal = cmark_node_get_literal(node) {
                    let raw = text.substring(with: range)
                    if confirmedHTMLImages.contains(range), let cellRange {
                        previousSpace = false
                        output.append(raw)
                        let local = NSRange(location: range.location - cellRange.location, length: range.length)
                        runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: .tableImage(local)))
                    } else if cmark_node_parent(node) == cell, raw == String(cString: literal), ["<br>", "<br/>", "<br />"].contains(raw.lowercased()) { previousSpace = false; output.append("\n") }
                }
            default:
                let pairs = confirmedInlineHTML.isEmpty ? [] : inlineHTMLPairs(in: node, confirmed: confirmedInlineHTML, source: source, text: text,
                                            tablePositions: positions, isCancelled: isCancelled).filter {
                    if $0.kind == .keyboard { return true }
                    if case .inlineStyle = $0.kind { return true }
                    return false
                }
                let openings = Dictionary(uniqueKeysWithValues: pairs.map { ($0.opening, $0) })
                let closings = Dictionary(uniqueKeysWithValues: pairs.map { ($0.closing, $0) })
                var starts: [OpaquePointer: Int] = [:]
                var child = cmark_node_first_child(node)
                while let next = child {
                    if isCancelled() { return }
                    if let pair = openings[next] { starts[pair.opening] = output.length }
                    else if let pair = closings[next], let beginning = starts[pair.opening], output.length > beginning {
                        let sourceRange = cellRange.flatMap { cell -> NSRange? in
                            guard case .inlineStyle = pair.kind else { return nil }
                            guard pair.openingRange.location >= cell.location, NSMaxRange(pair.closingRange) <= NSMaxRange(cell) else { return nil }
                            return NSRange(location: pair.openingRange.location - cell.location, length: NSMaxRange(pair.closingRange) - pair.openingRange.location)
                        }
                        if case .inlineStyle = pair.kind, sourceRange == nil { invalidInlineStyle = true }
                        else { runs.append(MarkdownTableTextRun(range: NSRange(location: beginning, length: output.length - beginning), kind: pair.kind, sourceRange: sourceRange)) }
                    } else if closings[next] == nil { visit(next) }
                    child = cmark_node_next(next)
                }
            }
            let kind: MarkdownPresentationKind?
            switch type {
            case "strong": kind = .strong
            case "emph": kind = .emphasis
            case "strikethrough": kind = .strikethrough
            case "code": kind = .code
            case "link": kind = .link
            default: kind = nil
            }
            if let kind, output.length > start {
                var relative: NSRange?
                if kind == .link, let cellRange, let range = source.linkRange(node, tableCell: cell, tablePositions: positions),
                   range.location >= cellRange.location, NSMaxRange(range) <= NSMaxRange(cellRange) {
                    relative = NSRange(location: range.location - cellRange.location, length: range.length)
                }
                runs.append(MarkdownTableTextRun(range: NSRange(location: start, length: output.length - start), kind: kind, sourceRange: relative))
            }
        }
        visit(cell)
        if invalidKeyboard || invalidInlineStyle, let cellRange { return (text.substring(with: cellRange), []) }
        return (output as String, runs)
    }

    private static func renderedCell(_ raw: String, referenceLabels: [String], syntax: MarkdownSyntaxOptions) -> (String, [MarkdownTableTextRun]) {
        guard !raw.utf8.contains(0), !raw.contains("\n"), !raw.contains("\r") else { return (raw, []) }
        let definitions = referenceLabels.map { "[\($0)]: /" }.joined(separator: "\n")
        let prefix = "|H|\n|---|\n|"
        let text = prefix + raw + "|\n\n" + definitions
        let options = ((syntax.smartPunctuation ?? true) ? CMARK_OPT_SMART : 0) | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES
        return MarkdownMathExtension.withDocument(text, options: options, includeInline: syntax.inlineMath, legacyInlineMath: syntax.legacyInlineMath, strictMode: syntax.strictMode) { root, mathExtension, inline in
            guard let table = cmark_node_first_child(root), let header = cmark_node_first_child(table),
                  let row = cmark_node_next(header), let cell = cmark_node_first_child(row) else { return (raw, []) }
            let map = Dictionary(uniqueKeysWithValues: inline.map { ($0.node, $0) })
            let range = NSRange(location: (prefix as NSString).length, length: (raw as NSString).length)
            return renderedCell(cell, source: Source(text, textOrigins: MarkdownMathExtension.textOrigins(in: mathExtension)), text: text as NSString, mathInline: map, cellRange: range, syntax: syntax)
        } ?? (raw, [])
    }

    // The wrapper makes cmark apply GFM table escaping while keeping offsets local to one cell.
    static func tableCellBreaks(_ raw: String) -> [NSRange] {
        tableCellTransforms(raw).filter { $0.replacement == "\n" }.map(\.range)
    }

    static func tableCellTransforms(_ raw: String) -> [(range: NSRange, replacement: String)] {
        guard raw.contains("<") || raw.contains("\\"),
              !raw.utf8.contains(0), !raw.contains("\n"), !raw.contains("\r") else { return [] }
        let prefix = "|H|\n|---|\n|"
        let text = prefix + raw + "|"
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return [] }
        defer { cmark_parser_free(parser) }
        "table".withCString { if let ext = cmark_find_syntax_extension($0) { cmark_parser_attach_syntax_extension(parser, ext) } }
        text.withCString { cmark_parser_feed(parser, $0, text.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }
        guard let table = cmark_node_first_child(OpaquePointer(root)), let header = cmark_node_first_child(table),
              let row = cmark_node_next(header), let cell = cmark_node_first_child(row) else { return [] }
        let source = Source(text), nsText = text as NSString, base = (prefix as NSString).length
        guard let positions = source.tableCellPositions(cell) else { return [] }
        var transforms: [(range: NSRange, replacement: String)] = []
        func visit(_ node: OpaquePointer) {
            guard let pointer = cmark_node_get_type_string(node) else { return }
            let type = String(cString: pointer)
            if type == "html_inline", cmark_node_parent(node) == cell,
               let literal = cmark_node_get_literal(node), let range = source.tableInlineRange(node, positions: positions),
               range.location >= base, NSMaxRange(range) <= base + (raw as NSString).length {
                let value = nsText.substring(with: range)
                if value == String(cString: literal), ["<br>", "<br/>", "<br />"].contains(value.lowercased()) {
                    transforms.append((NSRange(location: range.location - base, length: range.length), "\n"))
                }
            } else if type == "text", let range = source.tableInlineRange(node, positions: positions),
                      range.location >= base, NSMaxRange(range) <= base + (raw as NSString).length {
                var index = range.location
                while index < NSMaxRange(range) {
                    guard nsText.character(at: index) == 92 else { index += 1; continue }
                    var end = index
                    while end < NSMaxRange(range) && nsText.character(at: end) == 92 { end += 1 }
                    if end < NSMaxRange(range), (nsText.character(at: end) == 124 || nsText.character(at: end) == 60), (end - index) % 2 == 1 {
                        var pair = index
                        while pair + 1 < end {
                            transforms.append((NSRange(location: pair - base, length: 2), "\\"))
                            pair += 2
                        }
                        transforms.append((NSRange(location: end - 1 - base, length: 2), nsText.character(at: end) == 124 ? "|" : "<"))
                        index = end + 1
                    } else {
                        var pair = index
                        while pair + 1 < end {
                            transforms.append((NSRange(location: pair - base, length: 2), "\\"))
                            pair += 2
                        }
                        index = end
                    }
                }
            }
            guard type != "code" && type != "html_inline" else { return }
            var child = cmark_node_first_child(node)
            while let next = child { visit(next); child = cmark_node_next(next) }
        }
        visit(cell)
        return transforms.sorted { $0.range.location < $1.range.location }
    }
    private static func underline(_ node: OpaquePointer, source: Source, text: NSString) -> (range: NSRange, opening: NSRange, closing: NSRange)? {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "html_inline", !isExcludedInline(node),
              let parent = cmark_node_parent(node), let parentType = cmark_node_get_type_string(parent),
              String(cString: parentType) == "paragraph",
              let opening = source.range(node), text.substring(with: opening) == "<u>",
              let middle = cmark_node_next(node), let middleType = cmark_node_get_type_string(middle), String(cString: middleType) == "text",
              let content = source.range(middle), let literal = cmark_node_get_literal(middle),
              content.length > 0, text.substring(with: content) == String(cString: literal),
              let close = cmark_node_next(middle), let closeType = cmark_node_get_type_string(close), String(cString: closeType) == "html_inline",
              let closing = source.range(close), text.substring(with: closing) == "</u>",
              cmark_node_get_start_line(node) == cmark_node_get_end_line(close),
              NSMaxRange(opening) == content.location, NSMaxRange(content) == closing.location else { return nil }
        let raw = text.substring(with: content)
        guard !raw.contains("=="), !raw.contains("^") else { return nil }
        return (NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location), opening, closing)
    }

    struct InlineHTMLPair {
        let opening: OpaquePointer
        let closing: OpaquePointer
        let openingRange: NSRange
        let closingRange: NSRange
        let kind: MarkdownPresentationKind
        let href: String?
    }

    private static func inlineAnchorHref(_ tag: String, isCancelled: () -> Bool) -> String? {
        let raw = tag as NSString
        guard raw.length >= 8, raw.substring(with: NSRange(location: 0, length: 2)).lowercased() == "<a" else { return nil }
        func whitespace(_ value: unichar) -> Bool { value == 32 || value == 9 || value == 10 || value == 13 }
        var cursor = 2
        guard whitespace(raw.character(at: cursor)) else { return nil }
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor + 4 <= raw.length, raw.substring(with: NSRange(location: cursor, length: 4)).lowercased() == "href" else { return nil }
        cursor += 4
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor < raw.length, raw.character(at: cursor) == 61 else { return nil }
        cursor += 1
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor < raw.length else { return nil }
        let quote = raw.character(at: cursor)
        if quote == 34 || quote == 39 {
            cursor += 1
            while cursor < raw.length && raw.character(at: cursor) != quote { if isCancelled() { return nil }; cursor += 1 }
            guard cursor < raw.length else { return nil }
            cursor += 1
        } else {
            let start = cursor
            while cursor < raw.length && !whitespace(raw.character(at: cursor)) && raw.character(at: cursor) != 62 {
                if isCancelled() { return nil }
                guard ![34, 39, 60, 61, 96].contains(Int(raw.character(at: cursor))) else { return nil }
                cursor += 1
            }
            guard cursor > start else { return nil }
        }
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor == raw.length - 1, raw.character(at: cursor) == 62, !isCancelled() else { return nil }
        do {
            let document = try SwiftSoup.parseBodyFragment(tag + "</a>")
            guard let body = document.body(), body.children().size() == 1, let anchor = body.children().first(),
                  anchor.tagName() == "a", anchor.getAttributes()?.asList().count == 1, anchor.hasAttr("href") else { return nil }
            let href = try anchor.attr("href")
            guard !href.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 92 }),
                  let components = URLComponents(string: href),
                  components.scheme.map({ ["http", "https", "mailto"].contains($0.lowercased()) }) ?? true else { return nil }
            return href
        } catch { return nil }
    }

    private static func isSpanOpening(_ tag: String) -> Bool {
        let raw = tag.lowercased() as NSString
        guard raw.length > 5, raw.substring(to: 5) == "<span" else { return false }
        return [9, 10, 12, 13, 32, 62].contains(Int(raw.character(at: 5)))
    }

    static func filterInlineHTMLForStyles(_ nodes: [(OpaquePointer, NSRange?)], confirmed: Set<OpaquePointer>, text: NSString,
                                          isCancelled: @escaping () -> Bool = { false }) -> (confirmed: Set<OpaquePointer>, blocked: [NSRange]) {
        var hasSpan = false
        for (node, _) in nodes {
            if isCancelled() { return ([], []) }
            if let literal = cmark_node_get_literal(node), isSpanOpening(String(cString: literal)) { hasSpan = true; break }
        }
        if !hasSpan { return (confirmed, []) }
        var ordered: [(OpaquePointer, NSRange)] = []
        for (node, candidate) in nodes {
            if isCancelled() { return ([], []) }
            guard let range = candidate, htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else { return ([], [NSRange(location: 0, length: text.length)]) }
            ordered.append((node, range))
        }
        ordered.sort { $0.1.location < $1.1.location }
        var result: Set<OpaquePointer> = [], blockedParents: [OpaquePointer] = [], blocked: [NSRange] = [], blockedStart = 0, previousEnd = 0
        for (node, range) in ordered {
            if isCancelled() { return ([], []) }
            guard range.location >= previousEnd else { return ([], [NSRange(location: 0, length: text.length)]) }
            previousEnd = NSMaxRange(range)
            let raw = text.substring(with: range), tag = raw.lowercased()
            let opening = isSpanOpening(tag)
            let parent = cmark_node_parent(node)
            if !blockedParents.isEmpty {
                if opening, let parent { blockedParents.append(parent) }
                else if tag == "</span>", confirmed.contains(node), parent == blockedParents.last {
                    blockedParents.removeLast()
                    if blockedParents.isEmpty { blocked.append(NSRange(location: blockedStart, length: NSMaxRange(range) - blockedStart)) }
                }
                continue
            }
            if opening && MarkdownHTMLMediaService.hasStyledSpan(in: raw, isCancelled: isCancelled) &&
                (!confirmed.contains(node) || MarkdownHTMLMediaService.inlineStyleOpening(raw, isCancelled: isCancelled) == nil) {
                guard let parent else { return ([], [NSRange(location: 0, length: text.length)]) }
                blockedStart = range.location
                blockedParents.append(parent)
                continue
            }
            if confirmed.contains(node) { result.insert(node) }
        }
        if !blockedParents.isEmpty { blocked.append(NSRange(location: blockedStart, length: text.length - blockedStart)) }
        return (result, blocked)
    }

    static func inlineHTMLPairs(in parent: OpaquePointer, confirmed: Set<OpaquePointer>, source: Source,
                                text: NSString, tablePositions: Source.TableCellPositions? = nil,
                                mappedRange: ((OpaquePointer) -> NSRange?)? = nil, ignoreRubyTags: Bool = false, isCancelled: @escaping () -> Bool = { false }) -> [InlineHTMLPair] {
        let kinds: [String: MarkdownPresentationKind] = ["strong": .strong, "b": .strong, "em": .emphasis, "i": .emphasis, "u": .underline,
            "s": .strikethrough, "del": .strikethrough, "mark": .highlight, "sub": .subscriptText, "sup": .superscriptText, "kbd": .keyboard]
        var stack: [(node: OpaquePointer, name: String, range: NSRange, kind: MarkdownPresentationKind, href: String?, pairStart: Int)] = []
        var pairs: [InlineHTMLPair] = []
        var rejectedSpanDepth = 0
        func rejectOpenPairs() {
            if let first = stack.first, first.pairStart < pairs.count { pairs.removeSubrange(first.pairStart..<pairs.count) }
            stack.removeAll()
        }
        var child = cmark_node_first_child(parent)
        while let node = child {
            if isCancelled() { return [] }
            defer { child = cmark_node_next(node) }
            if cmark_node_get_type(node) != CMARK_NODE_HTML_INLINE {
                if stack.contains(where: { $0.kind == .link }) {
                    var pending = [node], found = false
                    while let current = pending.popLast() {
                        if isCancelled() { return [] }
                        if cmark_node_get_type(current) == CMARK_NODE_LINK { found = true; break }
                        if cmark_node_get_type(current) == CMARK_NODE_HTML_INLINE, let literal = cmark_node_get_literal(current),
                           String(cString: literal).lowercased().hasPrefix("<a") { found = true; break }
                        var nested = cmark_node_first_child(current)
                        while let item = nested { if isCancelled() { return [] }; pending.append(item); nested = cmark_node_next(item) }
                    }
                    if found { rejectOpenPairs() }
                }
                continue
            }
            let candidate: NSRange?
            if let tablePositions { candidate = source.tableInlineRange(node, positions: tablePositions) }
            else if let mappedRange { candidate = mappedRange(node) }
            else { candidate = source.range(node) }
            guard confirmed.contains(node), let range = candidate,
                  htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            let tag = text.substring(with: range).lowercased()
            if ignoreRubyTags && ["<ruby>", "</ruby>", "<rt>", "</rt>", "<rp>", "</rp>", "<br>", "<br/>", "<br />"].contains(tag) { continue }
            let spanOpening = isSpanOpening(tag)
            if rejectedSpanDepth > 0 {
                if spanOpening { rejectedSpanDepth += 1 }
                else if tag == "</span>" { rejectedSpanDepth -= 1 }
                continue
            }
            let closing = tag.hasPrefix("</")
            let name = String(tag.dropFirst(closing ? 2 : 1).dropLast())
            let href = !closing ? inlineAnchorHref(text.substring(with: range), isCancelled: isCancelled) : nil
            let anchor = href != nil || tag == "</a>"
            let spanStyle = spanOpening ? MarkdownHTMLMediaService.inlineStyleOpening(text.substring(with: range), isCancelled: isCancelled) : nil
            if spanOpening && !MarkdownHTMLMediaService.hasStyledSpan(in: text.substring(with: range), isCancelled: isCancelled) {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            if spanOpening && spanStyle == nil {
                if !stack.isEmpty { rejectOpenPairs() }
                rejectedSpanDepth = 1
                continue
            }
            let closingSpan = tag == "</span>"
            let kind: MarkdownPresentationKind? = anchor ? .link : (spanStyle.map { .inlineStyle($0) } ?? (closingSpan ? stack.last?.kind : kinds[name]))
            guard let kind, anchor || spanStyle != nil || closingSpan || (range.length <= 9 && tag == "<" + (closing ? "/" : "") + name + ">") else {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            if !closing {
                if kind == .link {
                    var ancestor: OpaquePointer? = parent, nested = stack.contains { $0.kind == .link }
                    while let current = ancestor { if isCancelled() { return [] }; if cmark_node_get_type(current) == CMARK_NODE_LINK { nested = true; break }; ancestor = cmark_node_parent(current) }
                    if nested { rejectOpenPairs(); continue }
                }
                stack.append((node, anchor ? "a" : (spanStyle != nil ? "span" : name), range, kind, href, pairs.count)); continue
            }
            guard let opening = stack.last, opening.name == (anchor ? "a" : name) else {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            stack.removeLast()
            pairs.append(InlineHTMLPair(opening: opening.node, closing: node, openingRange: opening.range,
                                        closingRange: range, kind: opening.kind, href: opening.href))
        }
        if !stack.isEmpty { rejectOpenPairs() }
        return pairs
    }

    static func underlines(in parent: OpaquePointer, source: Source, text: NSString, isCancelled: () -> Bool = { false }) -> [(OpaquePointer, OpaquePointer, NSRange, NSRange, NSRange)] {
        var result: [(OpaquePointer, OpaquePointer, NSRange, NSRange, NSRange)] = []
        var depth = 0, child = cmark_node_first_child(parent)
        while let node = child {
            if isCancelled() { return [] }
            defer { child = cmark_node_next(node) }
            guard let kind = cmark_node_get_type_string(node), String(cString: kind) == "html_inline",
                  let range = source.range(node) else { continue }
            let raw = text.substring(with: range)
            let lower = raw.lowercased() as NSString
            func tagBoundary(_ index: Int) -> Bool {
                guard index < lower.length else { return false }
                let unit = lower.character(at: index)
                return unit == 62 || unit == 47 || unit == 32 || unit == 9 || unit == 10 || unit == 13
            }
            if lower.hasPrefix("<u"), tagBoundary(2) {
                if depth == 0, let item = underline(node, source: source, text: text),
                   let middle = cmark_node_next(node), let close = cmark_node_next(middle) {
                    result.append((node, close, item.range, item.opening, item.closing))
                }
                depth += 1
            } else if lower.hasPrefix("</u"), tagBoundary(3) { depth = max(0, depth - 1) }
        }
        return result
    }

    private static func isExcludedInline(_ node: OpaquePointer) -> Bool {
        var parent = cmark_node_parent(node)
        while let current = parent {
            if cmark_node_get_type(current) == CMARK_NODE_FOOTNOTE_DEFINITION { return true }
            if let kind = cmark_node_get_type_string(current), ["link", "image", "table", "code_block", "strikethrough"].contains(String(cString: kind)) { return true }
            parent = cmark_node_parent(current)
        }
        return false
    }

    static func subscriptRange(_ node: OpaquePointer, source: Source, text: NSString, mappedRange: NSRange? = nil, mappedChild: NSRange? = nil) -> NSRange? {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "strikethrough",
              !isExcludedInline(node), cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
              let range = mappedRange ?? source.range(node), range.length >= 3,
              text.character(at: range.location) == 126, text.character(at: NSMaxRange(range) - 1) == 126,
              text.character(at: range.location + 1) != 126, text.character(at: NSMaxRange(range) - 2) != 126,
              let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
              let childType = cmark_node_get_type_string(child), String(cString: childType) == "text",
              let literal = cmark_node_get_literal(child) else { return nil }
        let content = text.substring(with: NSRange(location: range.location + 1, length: range.length - 2))
        if mappedRange != nil && mappedChild != NSRange(location: range.location + 1, length: range.length - 2) { return nil }
        guard content.utf16.elementsEqual(String(cString: literal).utf16), content.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !content.contains("~"), !content.contains("^"), !content.contains("==") else { return nil }
        return range
    }

    static func superscriptRanges(_ node: OpaquePointer, source: Source, text: NSString, mappedRange: NSRange? = nil) -> [NSRange] {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "text", !isExcludedInline(node),
              cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
              let range = mappedRange ?? source.range(node), let literal = cmark_node_get_literal(node),
              text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) else { return [] }
        let value = text.substring(with: range) as NSString
        var result: [NSRange] = [], i = 0
        while i + 2 < value.length {
            guard value.character(at: i) == 94, (i == 0 || value.character(at: i - 1) != 94), value.character(at: i + 1) != 94 else { i += 1; continue }
            var end = i + 1
            while end < value.length && value.character(at: end) != 94 { end += 1 }
            guard end < value.length else { break }
            let content = value.substring(with: NSRange(location: i + 1, length: end - i - 1))
            if !content.isEmpty, content.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
               (end + 1 == value.length || value.character(at: end + 1) != 94) {
                result.append(NSRange(location: range.location + i, length: end - i + 1))
            }
            i = end + 1
        }
        return result
    }

    static func inlineDecorations(_ node: OpaquePointer, source: Source, text: NSString, mappedRange: NSRange? = nil) -> [(NSRange, MarkdownPresentationKind)] {
        let values = (highlightRanges(node, source: source, text: text, mappedRange: mappedRange).map { ($0, MarkdownPresentationKind.highlight) } +
                      superscriptRanges(node, source: source, text: text, mappedRange: mappedRange).map { ($0, MarkdownPresentationKind.superscriptText) })
            .sorted { $0.0.location < $1.0.location }
        var result: [(NSRange, MarkdownPresentationKind)] = [], previousEnd = 0
        for (index, value) in values.enumerated() {
            let overlapsPrevious = previousEnd > value.0.location
            let overlapsNext = index + 1 < values.count && values[index + 1].0.location < NSMaxRange(value.0)
            previousEnd = max(previousEnd, NSMaxRange(value.0))
            if !overlapsPrevious && !overlapsNext { result.append(value) }
        }
        return result
    }

    static func alert(_ node: OpaquePointer, source: Source, text: NSString) -> (range: NSRange, marker: NSRange, label: String)? {
        guard let type = cmark_node_get_type_string(node), String(cString: type) == "block_quote",
              let parent = cmark_node_parent(node), let parentType = cmark_node_get_type_string(parent), String(cString: parentType) == "document",
              let paragraph = cmark_node_first_child(node), let paragraphType = cmark_node_get_type_string(paragraph), String(cString: paragraphType) == "paragraph",
              let marker = cmark_node_first_child(paragraph), let markerType = cmark_node_get_type_string(marker), String(cString: markerType) == "text",
              let next = cmark_node_next(marker), let nextType = cmark_node_get_type_string(next), String(cString: nextType) == "softbreak",
              cmark_node_next(next) != nil, let markerRange = source.range(marker), let blockRange = source.range(node) else { return nil }
        let raw = text.substring(with: markerRange)
        guard raw.hasPrefix("[!"), raw.hasSuffix("]"), raw.count >= 4 else { return nil }
        let label = String(raw.dropFirst(2).dropLast())
        guard ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"].contains(label) else { return nil }
        let line = text.lineRange(for: NSRange(location: markerRange.location, length: 0))
        let prefix = text.substring(with: NSRange(location: line.location, length: markerRange.location - line.location))
        guard prefix == "> " || prefix == ">" else { return nil }
        let remainder = text.substring(with: NSRange(location: NSMaxRange(markerRange), length: NSMaxRange(line) - NSMaxRange(markerRange)))
        guard remainder == "\n" || remainder == "\r" || remainder == "\r\n", NSMaxRange(line) < text.length else { return nil }
        let nextLine = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        let nextRaw = text.substring(with: nextLine)
        guard nextRaw.hasPrefix(">") else { return nil }
        return (blockRange, markerRange, label)
    }

    struct FrontMatter {
        let range: NSRange
        let markers: [NSRange]
    }

    static func frontMatter(_ text: String) -> FrontMatter? {
        let source = text as NSString
        var position = 0
        func nextLine() -> (NSRange, Bool)? {
            guard position < source.length else { return nil }
            let start = position
            while position < source.length && source.character(at: position) != 10 && source.character(at: position) != 13 { position += 1 }
            let range = NSRange(location: start, length: position - start)
            let hasEnding = position < source.length
            if hasEnding {
                if source.character(at: position) == 13 && position + 1 < source.length && source.character(at: position + 1) == 10 { position += 1 }
                position += 1
            }
            return (range, hasEnding)
        }
        func marker(in line: NSRange, opening: Bool) -> NSRange? {
            var start = line.location
            let end = NSMaxRange(line)
            if opening && start == 0 && start < end && source.character(at: start) == 0xfeff { start += 1 }
            guard end - start >= 3 else { return nil }
            let first = source.character(at: start)
            guard first == 45 || (!opening && first == 46),
                  source.character(at: start + 1) == first, source.character(at: start + 2) == first else { return nil }
            for index in (start + 3)..<end where source.character(at: index) != 32 && source.character(at: index) != 9 { return nil }
            return NSRange(location: start, length: 3)
        }
        guard let (openingLine, hasEnding) = nextLine(), hasEnding,
              let opening = marker(in: openingLine, opening: true) else { return nil }
        while let (line, _) = nextLine() {
            if let closing = marker(in: line, opening: false) {
                return FrontMatter(range: NSRange(location: 0, length: NSMaxRange(line)), markers: [opening, closing])
            }
        }
        return nil
    }

    static func maskedFrontMatter(_ text: String, frontMatter: FrontMatter?) -> String {
        guard let frontMatter else { return text }
        let source = text as NSString
        let byteCount = source.substring(with: frontMatter.range).utf8.count
        var bytes = Array(text.utf8)
        for i in 0..<byteCount where bytes[i] != 10 && bytes[i] != 13 { bytes[i] = 32 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func highlightRanges(_ node: OpaquePointer, source: Source, text: NSString, mappedRange: NSRange? = nil) -> [NSRange] {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "text",
              cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
              let range = mappedRange ?? source.range(node), let literal = cmark_node_get_literal(node),
              text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) else { return [] }
        guard !isExcludedInline(node) else { return [] }
        let value = text.substring(with: range) as NSString
        func whitespace(_ unit: UInt16) -> Bool {
            UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var results: [NSRange] = [], i = 0
        while i + 4 < value.length {
            guard value.character(at: i) == 61, value.character(at: i + 1) == 61,
                  (i == 0 || value.character(at: i - 1) != 61), value.character(at: i + 2) != 61,
                  !whitespace(value.character(at: i + 2)) else { i += 1; continue }
            var end = i + 3
            while end + 1 < value.length {
                if value.character(at: end) == 61, value.character(at: end + 1) == 61,
                   value.character(at: end - 1) != 61, !whitespace(value.character(at: end - 1)),
                   (end + 2 == value.length || value.character(at: end + 2) != 61) { break }
                end += 1
            }
            guard end + 1 < value.length else { break }
            results.append(NSRange(location: range.location + i, length: end + 2 - i))
            i = end + 2
        }
        return results
    }

    static func headingText(_ node: OpaquePointer, mathInline: [OpaquePointer: MarkdownMathExtension.Inline] = [:]) -> String {
        headingData(node, mathInline: mathInline, emojiByNode: [:]).title
    }

    private static func headingData(_ node: OpaquePointer, mathInline: [OpaquePointer: MarkdownMathExtension.Inline],
                                    emojiByNode: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]]) -> (title: String, emoji: [MarkdownHeading.Emoji]) {
        let result = NSMutableString(string: "")
        var emoji: [MarkdownHeading.Emoji] = []
        func append(_ current: OpaquePointer) {
            if let name = cmark_node_get_type_string(current) {
                switch String(cString: name) {
                case "text", "code":
                    if let literal = cmark_node_get_literal(current) {
                        let start = result.length
                        result.append(String(cString: literal))
                        for (offset, candidate) in emojiByNode[current] ?? [] {
                            emoji.append(.init(range: NSRange(location: start + offset, length: candidate.range.length), name: candidate.name))
                        }
                    }
                case "softbreak", "linebreak": result.append(" ")
                case "custom_inline":
                    if let math = mathInline[current] { result.append("$" + math.text + "$") }
                default: break
                }
            }
            var child = cmark_node_first_child(current)
            while let next = child { append(next); child = cmark_node_next(next) }
        }
        append(node)
        let title = (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return (title, []) }
        let trimmed = result.range(of: title)
        guard trimmed.location != NSNotFound else { return (title, []) }
        let mapped = emoji.compactMap { item -> MarkdownHeading.Emoji? in
            guard item.range.location >= trimmed.location, NSMaxRange(item.range) <= NSMaxRange(trimmed) else { return nil }
            return .init(range: NSRange(location: item.range.location - trimmed.location, length: item.range.length), name: item.name)
        }
        return (title, mapped)
    }

    private static func uppercaseHeadingRuns(_ node: OpaquePointer, range: NSRange, title: String,
                                             source: Source, text: NSString,
                                             mathInline: [OpaquePointer: MarkdownMathExtension.Inline],
                                             confirmedHTML: Set<OpaquePointer>, htmlImages: Set<NSRange>,
                                             preserveSoftBreaks: Bool,
                                             emojiByNode: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]],
                                             isCancelled: @escaping () -> Bool) -> [MarkdownHeading.UppercaseRun]? {
        var runs: [MarkdownHeading.UppercaseRun] = []
        var pendingBreak: (styles: [MarkdownPresentationKind], hard: Bool)?
        let titleText = NSMutableString()
        func appendRun(_ run: MarkdownHeading.UppercaseRun) -> Bool {
            if let pending = pendingBreak {
                guard let previous = runs.last?.pieces.last, let next = run.pieces.first,
                      NSMaxRange(previous.sourceRange) <= next.sourceRange.location else { return false }
                var position = NSMaxRange(previous.sourceRange), found: NSRange?
                while position < next.sourceRange.location {
                    if isCancelled() { return false }
                    let unit = text.character(at: position)
                    if unit == 10 || unit == 13 {
                        guard found == nil else { return false }
                        let length = unit == 13 && position + 1 < next.sourceRange.location && text.character(at: position + 1) == 10 ? 2 : 1
                        found = NSRange(location: position, length: length)
                        position += length
                    } else { position += 1 }
                }
                guard let found else { return false }
                runs.append(.init(pieces: [.init(sourceRange: found, text: pending.hard || preserveSoftBreaks ? "\n" : " ", matchesSource: false)], styles: pending.styles))
                pendingBreak = nil
            }
            runs.append(run)
            return true
        }
        func appendImageTitle(_ current: OpaquePointer) -> Bool {
            guard !isCancelled(), let name = cmark_node_get_type_string(current) else { return false }
            let type = String(cString: name)
            if (type == "text" || type == "code"), let literal = cmark_node_get_literal(current) {
                titleText.append(String(cString: literal))
            } else if type == "softbreak" || type == "linebreak" { titleText.append(" ") }
            else if let formula = mathInline[current] { titleText.append("$" + formula.text + "$") }
            var child = cmark_node_first_child(current)
            while let next = child {
                if !appendImageTitle(next) { return false }
                child = cmark_node_next(next)
            }
            return true
        }
        func visit(_ current: OpaquePointer, styles: [MarkdownPresentationKind]) -> Bool {
            guard !isCancelled(), let name = cmark_node_get_type_string(current) else { return false }
            let type = String(cString: name)
            if type == "softbreak" || type == "linebreak" {
                guard pendingBreak == nil, !runs.isEmpty else { return false }
                titleText.append(" ")
                pendingBreak = (styles, type == "linebreak")
                return true
            }
            if type == "html_inline", confirmedHTML.contains(current), let imageRange = source.range(current), htmlImages.contains(imageRange) {
                return appendRun(.init(pieces: [.init(sourceRange: imageRange, text: "\u{fffc}", matchesSource: false)],
                                       styles: styles, attachment: .image))
            }
            if type == "html_inline", confirmedHTML.contains(current), let breakRange = source.range(current),
               breakRange.location >= 0, breakRange.location <= text.length,
               breakRange.length <= text.length - breakRange.location,
               ["<br>", "<br/>", "<br />"].contains(text.substring(with: breakRange).lowercased()) {
                return appendRun(.init(pieces: [.init(sourceRange: breakRange, text: "\n", matchesSource: false)], styles: styles))
            }
            if type == "image" {
                guard let imageRange = source.range(current), imageRange.location >= 0, imageRange.length >= 4,
                      imageRange.location <= text.length, imageRange.length <= text.length - imageRange.location,
                      text.substring(with: NSRange(location: imageRange.location, length: 2)) == "![",
                      cmark_node_get_url(current) != nil else { return false }
                guard appendImageTitle(current) else { return false }
                return appendRun(.init(pieces: [.init(sourceRange: imageRange, text: "\u{fffc}", matchesSource: false)],
                                       styles: styles, attachment: .image))
            }
            if let formula = mathInline[current], let parent = cmark_node_parent(current) {
                guard let formulaRange = source.mathInlineRange(line: formula.line, column: formula.column,
                                                                 byteLength: formula.byteLength, parent: parent),
                      formulaRange.location <= text.length, formulaRange.length <= text.length - formulaRange.location,
                      text.substring(with: formulaRange).utf16.elementsEqual(("$" + formula.text + "$").utf16) else { return false }
                titleText.append("$" + formula.text + "$")
                return appendRun(.init(pieces: [.init(sourceRange: formulaRange, text: "\u{fffc}", matchesSource: false)],
                                       styles: styles, attachment: .formula))
            }
            if type == "text" || type == "code" {
                guard let range = source.range(current), range.location >= 0, range.length > 0,
                      range.location <= text.length, range.length <= text.length - range.location,
                      let pointer = cmark_node_get_literal(current) else { return false }
                let literal = String(cString: pointer), spelling = text.substring(with: range)
                let pieces: [MarkdownReadableText.Piece]
                if type == "code" {
                    guard source.codeRange(range) != nil, spelling.utf16.elementsEqual(literal.utf16) else { return false }
                    pieces = [.init(sourceRange: range, text: literal, matchesSource: true)]
                } else {
                    guard let mapped = MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: literal,
                                                                             sourceOffset: range.location, isCancelled: isCancelled) else { return false }
                    pieces = mapped
                }
                guard !pieces.isEmpty else { return false }
                titleText.append(literal)
                let emoji = (emojiByNode[current] ?? []).map { MarkdownHeading.UppercaseRun.Emoji(range: $0.1.range, name: $0.1.name) }
                return appendRun(.init(pieces: pieces, styles: type == "code" ? styles + [.code] : styles, emoji: emoji))
            }
            let nextStyles: [MarkdownPresentationKind]
            switch type {
            case "heading": nextStyles = styles
            case "strong": nextStyles = styles + [.strong]
            case "emph": nextStyles = styles + [.emphasis]
            case "strikethrough": nextStyles = styles + [.strikethrough]
            case "link": nextStyles = styles + [.link]
            default: return false
            }
            let pairs = inlineHTMLPairs(in: current, confirmed: confirmedHTML, source: source, text: text, isCancelled: isCancelled)
            let openings = Dictionary(uniqueKeysWithValues: pairs.map { ($0.opening, $0) })
            let closings = Dictionary(uniqueKeysWithValues: pairs.map { ($0.closing, $0) })
            var active = nextStyles, htmlStack: [InlineHTMLPair] = []
            var child = cmark_node_first_child(current), sawChild = false
            while let next = child {
                if isCancelled() { return false }
                if let pair = openings[next] {
                    htmlStack.append(pair); active.append(pair.kind)
                } else if let pair = closings[next] {
                    guard htmlStack.last?.opening == pair.opening else { return false }
                    htmlStack.removeLast(); active.removeLast()
                } else if !visit(next, styles: active) { return false }
                sawChild = true
                child = cmark_node_next(next)
            }
            return sawChild && htmlStack.isEmpty
        }
        guard visit(node, styles: []), pendingBreak == nil, !isCancelled() else { return nil }
        let pieces = runs.flatMap(\.pieces)
        guard (titleText as String).trimmingCharacters(in: .whitespacesAndNewlines).utf16.elementsEqual(title.utf16),
              MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: range) != nil else { return nil }
        return runs
    }

    struct PairedMediaCollector {
        private var pending: [(name: String, node: OpaquePointer, parent: OpaquePointer, tag: NSRange, offset: Int)] = []
        private(set) var candidates: [(proof: MarkdownHTMLMediaService.MediaProofCandidate, range: NSRange, isInline: Bool)] = []

        mutating func cancelPending() { pending.removeAll() }

        mutating func consume(node: OpaquePointer, range: NSRange, tags: [(NSRange, String, Bool)],
                              sourceText: NSString, isCancelled: () -> Bool) {
            guard let parent = cmark_node_parent(node), let typePointer = cmark_node_get_type_string(node), !tags.isEmpty else { return }
            let type = String(cString: typePointer)
            if let first = pending.first, first.parent != parent { pending.removeAll() }
            let parentType = cmark_node_get_type_string(parent).map { String(cString: $0) }
            let supportedParent = type == "html_block" || ["paragraph", "heading", "strong", "emph", "strikethrough", "link"].contains(parentType ?? "")
            let positions = tags.flatMap { [$0.0, NSRange(location: NSMaxRange($0.0) - 1, length: 1)] }.sorted { $0.location < $1.location }
            let offsets = type == "html_block" ? MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: positions, sourceText: sourceText, isCancelled: isCancelled) : nil
            for (tag, name, closing) in tags {
                if isCancelled() { return }
                guard supportedParent, let start = type == "html_block" ? offsets?[tag.location] : 0,
                      let last = type == "html_block" ? offsets?[NSMaxRange(tag) - 1] : tag.length - 1 else { pending.removeAll(); continue }
                if !closing {
                    pending.append((name, node, parent, tag, start))
                    continue
                }
                guard let pending = self.pending.last, pending.name == name, pending.parent == parent,
                      (type != "html_block" || pending.node == node), pending.tag.location <= tag.location else { self.pending.removeAll(); continue }
                self.pending.removeLast()
                if !self.pending.isEmpty { continue }
                let whole = NSRange(location: pending.tag.location, length: NSMaxRange(tag) - pending.tag.location)
                let html: String
                var isInline = true
                if type == "html_block" {
                    guard let pointer = cmark_node_get_literal(node) else { continue }
                    let literal = String(cString: pointer) as NSString
                    guard pending.offset <= last, last < literal.length else { continue }
                    html = literal.substring(with: NSRange(location: pending.offset, length: last - pending.offset + 1))
                    let before = NSRange(location: 0, length: pending.offset)
                    let after = NSRange(location: last + 1, length: literal.length - last - 1)
                    isInline = !(literal.substring(with: before).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        literal.substring(with: after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else { html = sourceText.substring(with: whole) }
                let expected: MarkdownHTMLMediaService.ProvenMedia
                if name == "iframe", let frame = MarkdownHTMLMediaService.iframe(in: html) { expected = .frame(frame) }
                else if name != "iframe", let media = MarkdownHTMLMediaService.embeddedMedia(in: html) { expected = .media(media) }
                else { continue }
                let proof = MarkdownHTMLMediaService.MediaProofCandidate(openingNode: pending.node, openingOffset: pending.offset,
                    closingNode: node, closingOffset: last + 1, expected: expected)
                candidates.append((proof, whole, isInline))
            }
        }
    }

    struct StandaloneSVG {
        let proof: MarkdownHTMLMediaService.SVGProofCandidate
        let range: NSRange
        let data: Data
        let paragraph: OpaquePointer?
        var isInline: Bool = false
    }

    static func standaloneSVGBlockCandidate(_ node: OpaquePointer, range: NSRange, text: NSString,
                                            isCancelled: () -> Bool) -> StandaloneSVG? {
        guard cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK, let pointer = cmark_node_get_literal(node) else { return nil }
        let literal = String(cString: pointer) as NSString
        var start = 0, end = literal.length
        while start < end && [9, 10, 12, 13, 32].contains(Int(literal.character(at: start))) { if isCancelled() { return nil }; start += 1 }
        while end > start && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { if isCancelled() { return nil }; end -= 1 }
        guard end - start >= 4, literal.substring(with: NSRange(location: start, length: 4)) == "<svg" else { return nil }
        let svg = literal.substring(with: NSRange(location: start, length: end - start))
        guard let data = MarkdownImageUploadService.standaloneSVGData(svg, isCancelled: isCancelled),
              MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: text, isCancelled: isCancelled) != nil else { return nil }
        return StandaloneSVG(proof: .init(opening: node, openingOffset: start, closing: node, closingOffset: end, literal: svg),
                             range: range, data: data, paragraph: nil)
    }

    static func standaloneSVGInlineCandidates(parents: [OpaquePointer], confirmed: Set<OpaquePointer>, source: Source,
                                              text: NSString, isCancelled: () -> Bool) -> [StandaloneSVG] {
        var candidates: [StandaloneSVG] = []
        for parent in parents where cmark_node_get_type(parent) == CMARK_NODE_PARAGRAPH {
            if isCancelled() { return [] }
            guard let paragraphRange = source.range(parent), paragraphRange.location >= 0,
                  NSMaxRange(paragraphRange) <= text.length else { continue }
            var child = cmark_node_first_child(parent)
            while let first = child {
                if isCancelled() { return [] }
                child = cmark_node_next(first)
                guard cmark_node_get_type(first) == CMARK_NODE_HTML_INLINE, confirmed.contains(first),
                      let firstRange = source.range(first), firstRange.length >= 4,
                      firstRange.location >= paragraphRange.location, NSMaxRange(firstRange) <= NSMaxRange(paragraphRange),
                      htmlSourceMatches(first, range: firstRange, text: text, isCancelled: isCancelled),
                      text.substring(with: NSRange(location: firstRange.location, length: 4)) == "<svg" else { continue }
                var cursor = NSMaxRange(firstRange), next = cmark_node_next(first), closing: OpaquePointer?
                while let node = next {
                    if isCancelled() { return [] }
                    let kind = cmark_node_get_type(node)
                    guard let childRange = source.range(node), childRange.location == cursor,
                          childRange.length <= NSMaxRange(paragraphRange) - cursor, let pointer = cmark_node_get_literal(node) else { break }
                    if kind == CMARK_NODE_HTML_INLINE {
                        guard confirmed.contains(node), htmlSourceMatches(node, range: childRange, text: text, isCancelled: isCancelled) else { break }
                    } else if kind == CMARK_NODE_TEXT {
                        let value = String(cString: pointer)
                        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              text.substring(with: childRange).utf16.elementsEqual(value.utf16) else { break }
                    } else { break }
                    cursor = NSMaxRange(childRange)
                    next = cmark_node_next(node)
                    if kind == CMARK_NODE_HTML_INLINE && text.substring(with: childRange).lowercased() == "</svg>" { closing = node; break }
                }
                guard let last = closing, let lastLiteral = cmark_node_get_literal(last) else { child = next; continue }
                child = next
                let range = NSRange(location: firstRange.location, length: cursor - firstRange.location)
                let svg = text.substring(with: range)
                guard let data = MarkdownImageUploadService.standaloneSVGData(svg, isCancelled: isCancelled) else { continue }
                let inline = range != paragraphRange
                candidates.append(StandaloneSVG(proof: .init(opening: first, openingOffset: 0, closing: last,
                    closingOffset: (String(cString: lastLiteral) as NSString).length, literal: svg), range: range, data: data, paragraph: parent, isInline: inline))
            }
        }
        return candidates
    }

    static func unconfirmedRubyRanges(tags: [(parent: OpaquePointer, range: NSRange, closing: Bool)],
                                      accepted: Set<NSRange>, sourceLength: Int,
                                      parentRange: (OpaquePointer) -> NSRange?, isCancelled: () -> Bool) -> [NSRange] {
        var open: [(OpaquePointer, Int)] = [], blocked: [NSRange] = []
        for tag in tags {
            if isCancelled() { return [] }
            if !tag.closing { open.append((tag.parent, tag.range.location)); continue }
            guard let opening = open.last, opening.0 == tag.parent, NSMaxRange(tag.range) >= opening.1 else { continue }
            open.removeLast()
            let range = NSRange(location: opening.1, length: NSMaxRange(tag.range) - opening.1)
            if !accepted.contains(range) { blocked.append(range) }
        }
        for opening in open {
            if isCancelled() { return [] }
            let parentEnd = parentRange(opening.0).map { min(sourceLength, NSMaxRange($0)) } ?? sourceLength
            let end = parentEnd > opening.1 ? parentEnd : sourceLength
            blocked.append(NSRange(location: opening.1, length: end - opening.1))
        }
        return blocked
    }

    static func inlineRubyCandidates(parents: [OpaquePointer], confirmed: Set<OpaquePointer>, source: Source, text: NSString,
                                     sourceRange: (OpaquePointer) -> NSRange?, isCancelled: @escaping () -> Bool) -> [(proof: MarkdownHTMLMediaService.RubyProofCandidate, value: MarkdownRuby)] {
        var candidates: [(proof: MarkdownHTMLMediaService.RubyProofCandidate, value: MarkdownRuby)] = []
        for parent in parents where cmark_node_get_type(parent) == CMARK_NODE_PARAGRAPH {
            if isCancelled() { break }
            let outerPairs = withoutActuallyEscaping(sourceRange) { mappedRange in
                inlineHTMLPairs(in: parent, confirmed: confirmed, source: source, text: text,
                                mappedRange: mappedRange, ignoreRubyTags: true, isCancelled: isCancelled)
            }
            var pairedNodes: Set<OpaquePointer> = []
            for pair in outerPairs {
                if isCancelled() { return [] }
                pairedNodes.insert(pair.opening); pairedNodes.insert(pair.closing)
            }
            var sibling = cmark_node_first_child(parent), unpairedStyle = false
            while let node = sibling {
                if isCancelled() { return [] }
                sibling = cmark_node_next(node)
                guard cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE, confirmed.contains(node),
                      let range = sourceRange(node), htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else { continue }
                let raw = text.substring(with: range), tag = raw.lowercased()
                let styles = ["strong", "b", "em", "i", "u", "s", "del", "mark", "sub", "sup", "kbd"]
                let styleTag = styles.contains { tag == "<" + $0 + ">" || tag == "</" + $0 + ">" }
                    || MarkdownHTMLMediaService.inlineStyleOpening(raw, isCancelled: isCancelled) != nil
                    || tag == "</span>" || inlineAnchorHref(raw, isCancelled: isCancelled) != nil || tag == "</a>"
                if styleTag && !pairedNodes.contains(node) { unpairedStyle = true; break }
            }
            if unpairedStyle { continue }
            var child = cmark_node_first_child(parent)
            while let opening = child {
                if isCancelled() { break }
                child = cmark_node_next(opening)
                func tag(_ node: OpaquePointer?, _ expected: String) -> NSRange? {
                    guard let node, cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE, confirmed.contains(node),
                          let range = sourceRange(node),
                          htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled),
                          text.substring(with: range).lowercased() == expected else { return nil }
                    return range
                }
                func textNode(_ node: OpaquePointer?) -> (NSRange, String)? {
                    guard let node, cmark_node_get_type(node) == CMARK_NODE_TEXT,
                          let range = sourceRange(node), range.location >= 0, range.location <= text.length,
                          range.length > 0, range.length <= text.length - range.location,
                          let literal = cmark_node_get_literal(node) else { return nil }
                    let value = String(cString: literal)
                    guard let pieces = MarkdownInlineTextProjection.pieces(spelling: text.substring(with: range) as NSString, literal: value, sourceOffset: range.location, isCancelled: isCancelled), !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil,
                          pieces.map(\.text).joined().utf16.elementsEqual(value.utf16),
                          inlineDecorations(node, source: source, text: text, mappedRange: range).isEmpty else { return nil }
                    return (range, value)
                }
                guard let openRange = tag(opening, "<ruby>"), let baseNode = cmark_node_next(opening) else { continue }
                var base = "", baseHTML = "", editingBaseHTML = "", baseRuns: [MarkdownRubyBaseRun] = []
                var cursor = NSMaxRange(openRange), baseNext: OpaquePointer? = baseNode
                let baseState = MarkdownRubyBaseParseState()
                struct BaseStyle { var bold = false; var italic = false; var foreground: MarkdownSRGBColor? }
                var style = BaseStyle(), styleStack: [(String, BaseStyle)] = []
                func escape(_ value: String) -> String {
                    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                }
                func walkBase(_ node: OpaquePointer, floor: Int) {
                    guard baseState.isValid, !isCancelled(), let range = sourceRange(node), range.location == cursor,
                          range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length else { baseState.isValid = false; return }
                    let type = cmark_node_get_type(node)
                    if type == CMARK_NODE_TEXT {
                        guard let (_, value) = textNode(node) else { baseState.isValid = false; return }
                        let start = (base as NSString).length
                        base += value; baseHTML += escape(value); editingBaseHTML += escape(value)
                        baseRuns.append(.init(range: NSRange(location: start, length: (value as NSString).length), bold: style.bold, italic: style.italic, foreground: style.foreground))
                        cursor = NSMaxRange(range); return
                    }
                    if type == CMARK_NODE_STRONG || type == CMARK_NODE_EMPH {
                        let strong = type == CMARK_NODE_STRONG, count = strong ? 2 : 1
                        let markers = source.pairedMarkers(range, characters: [42, 95], count: count)
                        guard markers.count == 2 else { baseState.isValid = false; return }
                        let name = strong ? "strong" : "em", previous = style, depth = styleStack.count
                        if strong { style.bold = true } else { style.italic = true }
                        baseState.isStyled = true; baseHTML += "<" + name + ">"; editingBaseHTML += "<" + name + ">"
                        cursor = NSMaxRange(markers[0])
                        var child = cmark_node_first_child(node)
                        while let current = child { walkBase(current, floor: depth); child = cmark_node_next(current) }
                        guard baseState.isValid, styleStack.count == depth, cursor == markers[1].location else { baseState.isValid = false; return }
                        cursor = NSMaxRange(markers[1]); style = previous
                        baseHTML += "</" + name + ">"; editingBaseHTML += "</" + name + ">"
                        return
                    }
                    guard type == CMARK_NODE_HTML_INLINE, confirmed.contains(node),
                          htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else { baseState.isValid = false; return }
                    let spelling = text.substring(with: range), lower = spelling.lowercased()
                    if ["<strong>", "<em>"].contains(lower) {
                        let name = lower == "<strong>" ? "strong" : "em"
                        styleStack.append((name, style)); if name == "strong" { style.bold = true } else { style.italic = true }
                        baseHTML += lower; editingBaseHTML += lower
                    } else if ["</strong>", "</em>", "</span>"].contains(lower) {
                        let name = String(lower.dropFirst(2).dropLast())
                        guard styleStack.count > floor, let previous = styleStack.popLast(), previous.0 == name else { baseState.isValid = false; return }
                        style = previous.1; baseHTML += lower; editingBaseHTML += lower
                    } else if let inlineStyle = MarkdownHTMLMediaService.inlineStyleOpening(spelling, isCancelled: isCancelled),
                              inlineStyle.background == nil, inlineStyle.fontSizeRem == nil {
                        styleStack.append(("span", style))
                        if let color = inlineStyle.foreground { style.foreground = color }
                        baseHTML += spelling
                        editingBaseHTML += inlineStyle.editingCSS.isEmpty ? "<span>" : "<span style=\"" + escape(inlineStyle.editingCSS) + "\">"
                    } else { baseState.isValid = false; return }
                    baseState.isStyled = true; cursor = NSMaxRange(range)
                }
                while let node = baseNext, tag(node, "<rt>") == nil, tag(node, "<rp>") == nil {
                    walkBase(node, floor: 0)
                    if !baseState.isValid { break }
                    baseNext = cmark_node_next(node)
                }
                guard baseState.isValid, styleStack.isEmpty, !base.isEmpty else { continue }
                let baseRange = NSRange(location: NSMaxRange(openRange), length: cursor - NSMaxRange(openRange))
                if baseState.isStyled, MarkdownHTMLMediaService.rubyNeedsWhitespaceProjection(base, isCancelled: isCancelled) != false { continue }
                var next = baseNext, before: String?, after: String?
                func fallback(_ node: inout OpaquePointer?, cursor: inout Int) -> String? {
                    guard let begin = tag(node, "<rp>"), begin.location == cursor, let open = node,
                          let content = cmark_node_next(open), let (range, value) = textNode(content), range.location == NSMaxRange(begin),
                          let closeNode = cmark_node_next(content), let close = tag(closeNode, "</rp>"), close.location == NSMaxRange(range) else { return nil }
                    cursor = NSMaxRange(close); node = cmark_node_next(closeNode)
                    return value
                }
                if tag(next, "<rp>") != nil { guard let value = fallback(&next, cursor: &cursor) else { continue }; before = value }
                guard let rt = next, let rtRange = tag(rt, "<rt>"), rtRange.location == cursor,
                      let readingNode = cmark_node_next(rt), let (readingRange, reading) = textNode(readingNode),
                      readingRange.location == NSMaxRange(rtRange), let rtCloseNode = cmark_node_next(readingNode),
                      let rtClose = tag(rtCloseNode, "</rt>"), rtClose.location == NSMaxRange(readingRange) else { continue }
                guard !base.utf16.contains(where: { [9, 10, 12, 13].contains(Int($0)) }),
                      !reading.utf16.contains(where: { [9, 10, 12, 13].contains(Int($0)) }),
                      let displayBase = MarkdownHTMLMediaService.rubyDisplayText(base, isCancelled: isCancelled), !displayBase.isEmpty,
                      let displayReading = MarkdownHTMLMediaService.rubyDisplayText(reading, isCancelled: isCancelled), !displayReading.isEmpty else { continue }
                cursor = NSMaxRange(rtClose); next = cmark_node_next(rtCloseNode)
                if tag(next, "<rp>") != nil { guard let value = fallback(&next, cursor: &cursor) else { continue }; after = value }
                var trailing: String?
                if let node = next, cmark_node_get_type(node) == CMARK_NODE_TEXT {
                    guard let (range, value) = textNode(node), range.location == cursor,
                          value.utf16.allSatisfy({ $0 == 32 }) else { continue }
                    trailing = value; cursor = NSMaxRange(range); next = cmark_node_next(node)
                }
                guard let closing = next, let closeRange = tag(closing, "</ruby>"), closeRange.location == cursor else { continue }
                let range = NSRange(location: openRange.location, length: NSMaxRange(closeRange) - openRange.location)
                var unsupportedOuterStyle = false
                for pair in outerPairs where NSMaxRange(pair.openingRange) <= range.location && NSMaxRange(range) <= pair.closingRange.location {
                    if isCancelled() { return [] }
                    switch pair.kind {
                    case .strong, .emphasis: break
                    case .inlineStyle(let style):
                        if style.background != nil || style.fontSizeRem != nil { unsupportedOuterStyle = true }
                    default: unsupportedOuterStyle = true
                    }
                }
                if unsupportedOuterStyle { continue }
                guard let baseWhitespace = MarkdownHTMLMediaService.rubyNeedsWhitespaceProjection(base, isCancelled: isCancelled),
                      let readingWhitespace = MarkdownHTMLMediaService.rubyNeedsWhitespaceProjection(reading, isCancelled: isCancelled) else { continue }
                let needsWhitespaceProjection = baseWhitespace || readingWhitespace || trailing != nil
                if needsWhitespaceProjection {
                    guard cmark_node_first_child(parent) == opening, cmark_node_next(closing) == nil,
                          let paragraphRange = sourceRange(parent), paragraphRange == range else { continue }
                }
                candidates.append((.init(opening: opening, closing: closing, closingOffset: closeRange.length,
                                             base: base, reading: reading, before: before, after: after, trailing: trailing,
                                             baseHTML: baseState.isStyled ? baseHTML : nil, editingBaseHTML: baseState.isStyled ? editingBaseHTML : nil),
                                       MarkdownRuby(range: range, baseRange: baseRange, readingRange: readingRange, base: base, reading: reading,
                                                    baseRuns: baseState.isStyled ? baseRuns : [])))
                child = cmark_node_next(closing)
            }
        }
        return isCancelled() ? [] : candidates
    }

    static func parse(_ text: String, includeReadableText: Bool = false, includeEmojiCandidates: Bool = false, includeUppercaseRuns: Bool = false, syntax: MarkdownSyntaxOptions = .init(), isCancelled: @escaping () -> Bool = { false }) -> MarkdownPresentation {
        guard !text.utf8.contains(0) else { return MarkdownPresentation(spans: []) }
        let options = ((syntax.smartPunctuation ?? true) ? CMARK_OPT_SMART : 0) | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES
        let frontMatter = frontMatter(text)
        let input = maskedFrontMatter(text, frontMatter: frontMatter)
        return MarkdownMathExtension.withDocument(input, options: options, includeInline: syntax.inlineMath, legacyInlineMath: syntax.legacyInlineMath, strictMode: syntax.strictMode, sourceForPositions: text, isCancelled: isCancelled) { root, mathExtension, mathInline in
        let source = Source(text, root: root, textOrigins: MarkdownMathExtension.textOrigins(in: mathExtension), looseHeadings: MarkdownMathExtension.looseHeadings(in: mathExtension), looseListRanges: MarkdownMathExtension.looseListRanges(in: mathExtension), isCancelled: isCancelled)
        let sourceText = text as NSString
        var spans: [MarkdownPresentationSpan] = []
        if let frontMatter { spans.append(MarkdownPresentationSpan(range: frontMatter.range, kind: .yaml, markerRanges: frontMatter.markers)) }
        var headings: [MarkdownHeading] = []
        var uppercaseHeadingNodes: [OpaquePointer] = []
        var images: [MarkdownImage] = []
        var htmlImageCandidates: [(node: OpaquePointer, image: MarkdownImage, source: String, offset: Int)] = []
        var mediaCollector = PairedMediaCollector()
        var standaloneMediaCandidates: [(node: OpaquePointer, range: NSRange, media: MarkdownHTMLMediaService.StandaloneMedia)] = []
        var detailsCandidates: [(node: OpaquePointer, range: NSRange, offset: Int, summary: String, body: String)] = []
        var detailsBlocks: [MarkdownDetailsBlock] = []
        var twitterCandidates: [(range: NSRange, proof: MarkdownHTMLMediaService.TwitterProofCandidate)] = []
        var htmlBlockCandidates: [(range: NSRange, proof: MarkdownHTMLMediaService.HTMLBlockCandidate, display: String)] = []
        var htmlBlocks: [MarkdownHTMLBlock] = []
        var svgCandidates: [StandaloneSVG] = []
        var pageBreakCandidates: [(node: OpaquePointer, range: NSRange, offset: Int, style: String)] = []
        var pageBreaks: [NSRange] = []
        var ruby: [MarkdownRuby] = []
        var audioBlocks: [MarkdownAudioBlock] = []
        var htmlContext = MarkdownImageUploadService.HTMLContext()
        var htmlRanges: [NSRange] = []
        var htmlRangesAvailable = true
        var iframeBlocks: [MarkdownIframeBlock] = []
        var links: [MarkdownLink] = []
        var linkCellPositions: [OpaquePointer: Source.TableCellPositions?] = [:]
        var diagrams: [MarkdownDiagram] = []
        var formulas: [MarkdownFormula] = []
        var inlineFormulas: [MarkdownFormula] = []
        var emojiByNode: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]] = [:]
        var emojiCompletionRanges: [NSRange] = []
        var smartTextRanges: [NSRange] = []
        var textReplacements: [MarkdownTextReplacement] = []
        var plainMultilineNodes: Set<OpaquePointer> = []
        var plainMultilineParagraphs: Set<OpaquePointer> = []
        var plainMultilineRanges: [OpaquePointer: NSRange] = [:]
        var plainMultilinePrefixes: [OpaquePointer: String] = [:]
        var tabColumns: [Int: (bytes: [Int: Int], scalars: [Int: Int])] = [:]
        func columnsForTabbedLine(_ line: Int) -> (bytes: [Int: Int], scalars: [Int: Int])? {
            if let cached = tabColumns[line] { return cached }
            guard line >= 0, line < source.lineStarts.count, source.lineHasTab[line] else { return nil }
            var position = source.lineStarts[line], byteColumn = 0, scalarColumn = 0
            var bytes = [0: position], scalars = [0: position]
            while position < source.lineEnds[line] {
                if isCancelled() { return nil }
                let unit = source.bytes[position]
                let length = unit < 0x80 ? 1 : (unit < 0xe0 ? 2 : (unit < 0xf0 ? 3 : 4))
                guard length <= source.lineEnds[line] - position else { return nil }
                if unit == 9 {
                    byteColumn = (byteColumn / 4 + 1) * 4
                    scalarColumn = (scalarColumn / 4 + 1) * 4
                } else {
                    byteColumn += length
                    scalarColumn += 1
                }
                position += length
                bytes[byteColumn] = position
                scalars[scalarColumn] = position
            }
            let value = (bytes: bytes, scalars: scalars)
            tabColumns[line] = value
            return value
        }
        func confirmedText(_ node: OpaquePointer) -> (NSRange, [MarkdownReadableText.Piece])? {
            guard cmark_node_get_type(node) == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(node) else { return nil }
            let value = String(cString: literal)
            func project(_ range: NSRange?) -> (NSRange, [MarkdownReadableText.Piece])? {
                guard let range, range.location >= 0, range.length > 0, NSMaxRange(range) <= sourceText.length,
                      let pieces = MarkdownInlineTextProjection.pieces(spelling: sourceText.substring(with: range) as NSString,
                          literal: value, sourceOffset: range.location, isCancelled: isCancelled) else { return nil }
                return (range, pieces)
            }
            if plainMultilineNodes.contains(node) { return project(plainMultilineRanges[node]) }
            if let direct = project(source.editingTextRange(node)) { return direct }
            let line = Int(cmark_node_get_start_line(node)) - 1
            guard let columns = columnsForTabbedLine(line) else { return nil }
            let candidates = source.tabbedTextCandidateRanges(node, byteColumns: columns.bytes, scalarColumns: columns.scalars)
            var matches: [(NSRange, [MarkdownReadableText.Piece])] = []
            for range in candidates {
                if isCancelled() { return nil }
                if let result = project(range) { matches.append(result) }
            }
            return matches.count == 1 ? matches[0] : nil
        }
        var confirmedInlineRanges: [OpaquePointer: NSRange] = [:]
        var unconfirmedInlineRanges: Set<OpaquePointer> = []
        var confirmedInlineAttachments: [OpaquePointer: NSRange] = [:]
        var confirmedHTMLImageNodes: [OpaquePointer: NSRange] = [:]
        var softBreakNodes: [OpaquePointer] = []
        var delayedMappedSpans: [(OpaquePointer, String, NSRange)] = []
        var delayedMappedLinks: [(OpaquePointer, NSRange, String)] = []
        func confirmedEditingImageRange(_ node: OpaquePointer) -> NSRange? {
            guard let range = plainMultilineRanges[node], range.location >= 0, NSMaxRange(range) <= sourceText.length,
                  let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
                  cmark_node_get_type(child) == CMARK_NODE_TEXT, let childRange = plainMultilineRanges[child],
                  let literal = cmark_node_get_literal(child), let url = cmark_node_get_url(node) else { return nil }
            let title = cmark_node_get_title(node).map { String(cString: $0) } ?? ""
            let alt = String(cString: literal), address = String(cString: url)
            guard title.isEmpty, childRange.location == range.location + 2, childRange.length == (alt as NSString).length,
                  NSMaxRange(childRange) <= NSMaxRange(range),
                  sourceText.substring(with: childRange).utf16.elementsEqual(alt.utf16),
                  sourceText.substring(with: range).utf16.elementsEqual(("![" + alt + "](" + address + ")").utf16) else { return nil }
            return range
        }
        func confirmedInlineRange(_ node: OpaquePointer) -> NSRange? {
            if isCancelled() { return nil }
            if let range = confirmedInlineAttachments[node] { return range }
            if let cached = confirmedInlineRanges[node] { return cached }
            if unconfirmedInlineRanges.contains(node) { return nil }
            func prove() -> NSRange? {
                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_TEXT { return confirmedText(node)?.0 }
                if type == CMARK_NODE_SOFTBREAK { return confirmedSoftBreak(node) }
                let mapped = plainMultilineNodes.contains(node) ? plainMultilineRanges[node] : source.editingTextRange(node)
                guard let name = cmark_node_get_type_string(node), let range = mapped,
                      range.location >= 0, range.length > 0, NSMaxRange(range) <= sourceText.length else { return nil }
                switch String(cString: name) {
                case "code":
                    guard let literal = cmark_node_get_literal(node), let expanded = source.codeRange(range),
                          sourceText.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) else { return nil }
                    return expanded.0
                case "strong":
                    guard source.pairedMarkers(range, characters: [42, 95], count: 2).count == 2 else { return nil }
                case "emph":
                    guard source.pairedMarkers(range, characters: [42, 95], count: 1).count == 2 else { return nil }
                case "strikethrough":
                    if plainMultilineNodes.contains(node),
                       let child = cmark_node_first_child(node),
                       let subscriptRange = subscriptRange(node, source: source, text: sourceText, mappedRange: range,
                                                           mappedChild: plainMultilineRanges[child]) { return subscriptRange }
                    guard source.pairedMarkers(range, characters: [126], count: 2).count == 2 else { return nil }
                case "link":
                    let markers = plainMultilineNodes.contains(node)
                        ? source.linkMarkers(range, node: node, mappedRange: { confirmedInlineRange($0) })
                        : source.linkMarkers(range, node: node)
                    guard !markers.isEmpty else { return nil }
                default: return nil
                }
                var child = cmark_node_first_child(node), last = range.location, found = false
                while let current = child {
                    if isCancelled() { return nil }
                    guard let item = confirmedInlineRange(current), item.location >= last,
                          NSMaxRange(item) <= NSMaxRange(range) else { return nil }
                    last = NSMaxRange(item)
                    found = true
                    child = cmark_node_next(current)
                }
                return found ? range : nil
            }
            let result = prove()
            if let result { confirmedInlineRanges[node] = result }
            else if !isCancelled() { unconfirmedInlineRanges.insert(node) }
            return result
        }
        var emojiCandidates = includeEmojiCandidates ? MarkdownEmojiCandidateExtractor.candidates(in: root, source: source, text: sourceText, isCancelled: isCancelled, onSmartRange: { smartTextRanges.append($0) }, onTextRange: { _, range in emojiCompletionRanges.append(range) }) { node, offset, candidate in
            emojiByNode[node, default: []].append((offset, candidate))
        }.map { MarkdownEmojiCandidate(name: $0.name, range: $0.range) }.sorted { $0.range.location < $1.range.location } : []
        let inlineByNode = mathInline.reduce(into: [OpaquePointer: MarkdownMathExtension.Inline]()) { $0[$1.node] = $1 }
        var taskCheckboxes: [MarkdownTaskCheckbox] = []
        var completedTaskRanges: [NSRange] = []
        var listMarkers: [MarkdownListMarker] = []
        var footnotes: [MarkdownFootnote] = []
        var tableOfContents: [NSRange] = []
        var tables: [MarkdownTable] = []
        var tableNodes: [OpaquePointer] = []
        var htmlImageTableIndices: Set<Int> = []
        var htmlKeyboardTableIndices: Set<Int> = []
        var codeBlocks: [MarkdownCodeBlock] = []
        var fenceContainerLines: [MarkdownFenceContainerLine] = []
        var paragraphs: [MarkdownParagraph] = []
        var paragraphNodes: [OpaquePointer: Int] = [:]
        var fenceBlockedRanges: [NSRange] = frontMatter.map { [$0.range] } ?? []
        var fenceBlockedEOF = false, fenceContextAvailable = true
        func footnoteText(_ node: OpaquePointer) -> String {
            var result = ""
            func append(_ current: OpaquePointer) {
                guard let name = cmark_node_get_type_string(current) else { return }
                let type = String(cString: name)
                if ["paragraph", "heading", "code_block"].contains(type), !result.isEmpty, !result.hasSuffix("\n") {
                    result += "\n"
                }
                switch type {
                case "text", "code", "code_block":
                    if let literal = cmark_node_get_literal(current) { result += String(cString: literal) }
                case "softbreak", "linebreak": result += " "
                default: break
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
        var itemStartColumns: [OpaquePointer: (Int, String)] = [:]
        var failedItemStartColumns: Set<OpaquePointer> = []
        func itemStartColumn(_ item: OpaquePointer) -> (Int, String)? {
            if let cached = itemStartColumns[item] { return cached }
            if failedItemStartColumns.contains(item) { return nil }
            func calculate() -> (Int, String)? {
                guard !isCancelled(), let marker = source.firstPosition(item),
                      let paragraph = cmark_node_first_child(item), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                      let first = cmark_node_first_child(paragraph), cmark_node_get_type(first) == CMARK_NODE_TEXT,
                      let literal = cmark_node_get_literal(first), let range = source.range(first) ?? source.tabbedLiteralTextRange(first, text: sourceText, isCancelled: isCancelled), range.length > 0,
                      NSMaxRange(range) <= sourceText.length,
                      sourceText.substring(with: range) == String(cString: literal), !isCancelled() else { return nil }
                let firstLine = sourceText.lineRange(for: NSRange(location: marker, length: 0))
                guard range.location >= marker, range.location < NSMaxRange(firstLine) else { return nil }
                let initial = Array(sourceText.substring(with: NSRange(location: firstLine.location, length: range.location - firstLine.location)).utf16)
                guard initial.allSatisfy({ $0 < 128 }), !isCancelled() else { return nil }
                let column = initial.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
                var quoteEnd = initial.lastIndex(of: 62).map { $0 + 1 } ?? 0
                if quoteEnd > 0 && quoteEnd < initial.count && (initial[quoteEnd] == 32 || initial[quoteEnd] == 9) { quoteEnd += 1 }
                return (column, String(decoding: initial[..<quoteEnd], as: UTF16.self))
            }
            guard let value = calculate() else { failedItemStartColumns.insert(item); return nil }
            itemStartColumns[item] = value
            return value
        }
        var htmlContextText: NSMutableString?
        var htmlTemplateDepth = 0
        var confirmedInlineHTML = Set<OpaquePointer>()
        var allInlineHTML: [(OpaquePointer, NSRange?)] = []
        var rubyTags: [(parent: OpaquePointer, range: NSRange, closing: Bool)] = []
        var inlineHTMLParents: [OpaquePointer] = []
        let inlineHTMLContainerTypes: Set<String> = ["paragraph", "heading", "strong", "emph", "link", "strikethrough"]
        var lastHTMLRangeEnd = 0
        var scriptStartedInContainer = false
        var scriptOpeningNode: OpaquePointer?
        var scriptGapText: [(range: NSRange, node: OpaquePointer)] = []
        var scriptGapUnproven = false
        func htmlInsideContainer(_ node: OpaquePointer) -> Bool {
            var ancestor = cmark_node_parent(node)
            while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
                if isCancelled() { return false }
                let kind = cmark_node_get_type(current)
                if kind == CMARK_NODE_BLOCK_QUOTE || kind == CMARK_NODE_ITEM || kind == CMARK_NODE_LIST { return true }
                ancestor = cmark_node_parent(current)
            }
            return false
        }
        func containerProofNode(_ node: OpaquePointer) -> OpaquePointer? {
            var current = node
            while let parent = cmark_node_parent(current) {
                if isCancelled() { return nil }
                let kind = cmark_node_get_type(parent)
                if kind == CMARK_NODE_DOCUMENT || kind == CMARK_NODE_BLOCK_QUOTE || kind == CMARK_NODE_ITEM || kind == CMARK_NODE_LIST { return current }
                guard let name = cmark_node_get_type_string(parent),
                      ["paragraph", "heading", "strong", "emph", "link", "strikethrough"].contains(String(cString: name)) else { return nil }
                current = parent
            }
            return nil
        }
        func scriptGapPrefixes(before node: OpaquePointer, range: NSRange) -> [NSRange]? {
            guard !scriptGapUnproven, let opening = scriptOpeningNode, lastHTMLRangeEnd <= range.location else { return nil }
            let end = range.location
            var cursor = lastHTMLRangeEnd, index = 0, prefixes: [NSRange] = []
            while cursor < end {
                if isCancelled() { return nil }
                let line = sourceText.lineRange(for: NSRange(location: cursor, length: 0))
                var contentEnd = min(NSMaxRange(line), end)
                while contentEnd > cursor && [10, 13].contains(Int(sourceText.character(at: contentEnd - 1))) { contentEnd -= 1 }
                while index < scriptGapText.count && NSMaxRange(scriptGapText[index].range) <= cursor { index += 1 }
                var content = cursor
                if line.location >= lastHTMLRangeEnd {
                    let first = index < scriptGapText.count && scriptGapText[index].range.location < contentEnd ? scriptGapText[index] : nil
                    let currentHTML = range.location < NSMaxRange(line)
                    let prefixEnd = first?.range.location ?? (currentHTML ? range.location : contentEnd)
                    guard let proofNode = containerProofNode(first?.node ?? (currentHTML ? node : opening)) else { return nil }
                    guard prefixEnd >= line.location, prefixEnd <= contentEnd,
                          fencePrefixes(proofNode, source: source, text: sourceText, position: prefixEnd) != nil else { return nil }
                    if prefixEnd > line.location { prefixes.append(NSRange(location: line.location, length: prefixEnd - line.location)) }
                    content = prefixEnd
                }
                while content < contentEnd {
                    if isCancelled() { return nil }
                    while index < scriptGapText.count && NSMaxRange(scriptGapText[index].range) <= content { index += 1 }
                    if index < scriptGapText.count, scriptGapText[index].range.location <= content,
                       NSMaxRange(scriptGapText[index].range) > content {
                        content = min(contentEnd, NSMaxRange(scriptGapText[index].range))
                    } else if [9, 32].contains(Int(sourceText.character(at: content))) { content += 1 }
                    else { return nil }
                }
                let next = min(end, NSMaxRange(line))
                guard next > cursor else { return nil }
                cursor = next
            }
            return prefixes
        }
        func visit(_ node: OpaquePointer, inUnsupportedContainer: Bool, listDepth: Int) {
            guard let typePointer = cmark_node_get_type_string(node) else { return }
            let type = String(cString: typePointer)
            let nodeType = cmark_node_get_type(node)
            if nodeType == CMARK_NODE_PARAGRAPH, cmark_node_get_start_line(node) < cmark_node_get_end_line(node),
               let parent = cmark_node_parent(node) {
                var child = cmark_node_first_child(node), candidates: [OpaquePointer] = [], plain = true
                while let current = child {
                    if isCancelled() { plain = false; break }
                    let kind = cmark_node_get_type(current)
                    if kind != CMARK_NODE_SOFTBREAK {
                        var pending = [current]
                        while let item = pending.popLast() {
                            if isCancelled() { plain = false; break }
                            guard let name = cmark_node_get_type_string(item),
                                  ["text", "strong", "emph", "strikethrough", "link", "code", "image", "custom_inline", "html_inline", "softbreak"].contains(String(cString: name)) else { plain = false; break }
                            let itemName = String(cString: name)
                            if itemName == "custom_inline" && (syntax.legacyInlineMath || inlineByNode[item] == nil) { plain = false; break }
                            if (itemName == "text" || itemName == "code" || itemName == "image" || itemName == "html_inline") && cmark_node_get_start_line(item) != cmark_node_get_end_line(item) { plain = false; break }
                            if itemName == "image" {
                                guard let child = cmark_node_first_child(item), cmark_node_next(child) == nil,
                                      cmark_node_get_type(child) == CMARK_NODE_TEXT else { plain = false; break }
                            }
                            if itemName != "softbreak" { candidates.append(item) }
                            var nested = cmark_node_first_child(item)
                            while let next = nested { if isCancelled() { plain = false; break }; pending.append(next); nested = cmark_node_next(next) }
                        }
                        if !plain { break }
                    }
                    child = cmark_node_next(current)
                }
                if plain {
                    plainMultilineParagraphs.insert(node)
                    plainMultilineNodes.formUnion(candidates)
                    if let ranges = source.lazyParagraphInlineRanges(node, text: sourceText, plainEditing: true,
                                                                    inlineMath: inlineByNode, isCancelled: isCancelled) {
                        plainMultilineRanges.merge(ranges) { first, _ in first }
                        for current in candidates {
                            if inlineByNode[current] != nil, let range = ranges[current] { confirmedInlineAttachments[current] = range }
                            else if cmark_node_get_type(current) == CMARK_NODE_IMAGE, let range = confirmedEditingImageRange(current) {
                                confirmedInlineAttachments[current] = range
                            }
                        }
                        if cmark_node_get_type(parent) == CMARK_NODE_DOCUMENT { plainMultilinePrefixes[node] = "" }
                        else if let prefix = containerPrefixes(node, source: source, text: sourceText, isCancelled: isCancelled) {
                            plainMultilinePrefixes[node] = prefix.continuation
                        }
                    }
                }
            }
            let currentListDepth = nodeType == CMARK_NODE_LIST ? listDepth + 1 : listDepth
            if nodeType == CMARK_NODE_TEXT && htmlContext.inScriptContext {
                if let range = source.range(node), let literal = cmark_node_get_literal(node),
                   range.location >= lastHTMLRangeEnd,
                   (scriptGapText.last.map { NSMaxRange($0.range) <= range.location } ?? true),
                   NSMaxRange(range) <= sourceText.length,
                   sourceText.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) {
                    scriptGapText.append((range, node))
                } else { scriptGapUnproven = true }
            }
            let unsupported = inUnsupportedContainer || type == "image" || type == "table" || nodeType == CMARK_NODE_FOOTNOTE_DEFINITION
            if !unsupported, type == "softbreak", (!syntax.preserveEditingSoftBreaks || !(syntax.preserveEditingWhitespace ?? false)), !htmlContext.inRawContext {
                softBreakNodes.append(node)
            }
            if !unsupported, nodeType == CMARK_NODE_TEXT, !htmlContext.inRawContext,
               ((syntax.smartPunctuation ?? true) || !(syntax.preserveEditingWhitespace ?? false)),
               let (_, pieces) = confirmedText(node) {
                for (pieceIndex, piece) in pieces.enumerated() {
                    if isCancelled() { return }
                    if !piece.matchesSource, syntax.smartPunctuation ?? true {
                        let spelling = sourceText.substring(with: piece.sourceRange)
                        if ["\"", "'", "--", "---", "..."].contains(spelling),
                           ["“", "”", "‘", "’", "–", "—", "…"].contains(piece.text) {
                            let end = NSMaxRange(piece.sourceRange)
                            let composed = sourceText.rangeOfComposedCharacterSequence(at: end - 1)
                            let extra = NSMaxRange(composed) - end
                            if extra > 0 {
                                guard pieceIndex + 1 < pieces.count, pieces[pieceIndex + 1].matchesSource,
                                      pieces[pieceIndex + 1].sourceRange.location == end,
                                      pieces[pieceIndex + 1].sourceRange.length >= extra else { continue }
                            }
                            let suffix = sourceText.substring(with: NSRange(location: end, length: extra))
                            textReplacements.append(.init(range: NSRange(location: piece.sourceRange.location, length: piece.sourceRange.length + extra), text: piece.text + suffix, kind: .smart))
                        }
                    } else if piece.matchesSource, !(syntax.preserveEditingWhitespace ?? false) {
                        var cursor = piece.sourceRange.location
                        while cursor < NSMaxRange(piece.sourceRange) {
                            if isCancelled() { return }
                            guard sourceText.character(at: cursor) == 32 || sourceText.character(at: cursor) == 9 else { cursor += 1; continue }
                            let start = cursor
                            var hasTab = false
                            while cursor < NSMaxRange(piece.sourceRange) && (sourceText.character(at: cursor) == 32 || sourceText.character(at: cursor) == 9) {
                                if isCancelled() { return }
                                if sourceText.character(at: cursor) == 9 { hasTab = true }
                                cursor += 1
                            }
                            guard cursor - start > 1 || hasTab else { continue }
                            let last = sourceText.rangeOfComposedCharacterSequence(at: cursor - 1)
                            guard NSMaxRange(last) <= NSMaxRange(piece.sourceRange) else { continue }
                            let suffix = sourceText.substring(with: NSRange(location: cursor, length: NSMaxRange(last) - cursor))
                            cursor = NSMaxRange(last)
                            textReplacements.append(.init(range: NSRange(location: start, length: cursor - start), text: " " + suffix, kind: .spaces))
                        }
                    }
                }
            }
            if !unsupported && inlineHTMLContainerTypes.contains(type) { inlineHTMLParents.append(node) }
            if !inUnsupportedContainer, nodeType == CMARK_NODE_LIST {
                let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
                let startNumber = Int(cmark_node_get_list_start(node))
                var item = cmark_node_first_child(node), index = 0
                while let current = item {
                    if isCancelled() { return }
                    defer { item = cmark_node_next(current); index += 1 }
                    guard let name = cmark_node_get_type_string(current), String(cString: name) != "tasklist",
                          source.taskCheckbox(current) == nil, let start = source.firstPosition(current), start < sourceText.length else { continue }
                    let line = sourceText.lineRange(for: NSRange(location: start, length: 0))
                    var end = start
                    if ordered {
                        while end < NSMaxRange(line), (48...57).contains(sourceText.character(at: end)), end - start < 9 { end += 1 }
                        guard end > start, end < NSMaxRange(line), [46, 41].contains(Int(sourceText.character(at: end))) else { continue }
                        end += 1
                    } else {
                        guard [42, 43, 45].contains(Int(sourceText.character(at: start))) else { continue }
                        end += 1
                    }
                    guard end == NSMaxRange(line) || [9, 10, 13, 32].contains(Int(sourceText.character(at: end))) else { continue }
                    let (ordinal, overflow) = startNumber.addingReportingOverflow(index)
                    guard !ordered || !overflow else { continue }
                    listMarkers.append(MarkdownListMarker(range: NSRange(location: start, length: end - start), line: line,
                                                          text: ordered ? "\(ordinal)." : "•", ordinal: ordered ? ordinal : nil,
                                                          depth: currentListDepth))
                }
            }
            var safeHTML = false
            if type == "html_inline" || type == "html_block" {
                var ancestor = cmark_node_parent(node), cell: OpaquePointer?
                while let current = ancestor {
                    if isCancelled() { return }
                    if let name = cmark_node_get_type_string(current), String(cString: name) == "table_cell" { cell = current; break }
                    ancestor = cmark_node_parent(current)
                }
                if type == "html_inline", let cell, let table = tables.last, let cellRange = source.range(cell),
                   NSLocationInRange(cellRange.location, table.range), let literal = cmark_node_get_literal(node) {
                    let tag = String(cString: literal).lowercased()
                    if tag.hasPrefix("<kbd") || tag.hasPrefix("</kbd") || isSpanOpening(tag) || tag == "</span>" { htmlKeyboardTableIndices.insert(tables.count - 1) }
                }
                let range: NSRange?
                if let cell {
                    let positions: Source.TableCellPositions?
                    if let cached = linkCellPositions[cell] { positions = cached }
                    else {
                        positions = source.tableCellPositions(cell, isCancelled: isCancelled)
                        linkCellPositions[cell] = .some(positions)
                    }
                    range = positions.flatMap { source.tableInlineRange(node, positions: $0) }
                } else { range = plainMultilineNodes.contains(node) ? plainMultilineRanges[node] : source.range(node) }
                if nodeType == CMARK_NODE_HTML_INLINE { allInlineHTML.append((node, range)) }
                var confirmed = range.map { htmlSourceMatches(node, range: $0, text: sourceText, isCancelled: isCancelled) } ?? false
                if !confirmed, type == "html_block", let range, let prefixes = containerHTMLPrefixes(node, range: range, source: source, sourceText: sourceText, isCancelled: isCancelled) {
                    if htmlContextText == nil { htmlContextText = NSMutableString(string: sourceText as String) }
                    for prefix in prefixes { htmlContextText?.replaceCharacters(in: prefix, with: String(repeating: " ", count: prefix.length)) }
                    confirmed = true
                }
                if let range, confirmed {
                    var unconfirmedContainerGap = false
                    if htmlContext.inScriptContext, lastHTMLRangeEnd < range.location {
                        if scriptStartedInContainer || htmlInsideContainer(node) {
                            for position in lastHTMLRangeEnd..<range.location {
                                if isCancelled() { return }
                                if sourceText.character(at: position) == 10 || sourceText.character(at: position) == 13 {
                                    unconfirmedContainerGap = true; break
                                }
                            }
                        }
                    }
                    if unconfirmedContainerGap, let prefixes = scriptGapPrefixes(before: node, range: range) {
                        if htmlContextText == nil { htmlContextText = NSMutableString(string: sourceText as String) }
                        for prefix in prefixes { htmlContextText?.replaceCharacters(in: prefix, with: String(repeating: " ", count: prefix.length)) }
                        unconfirmedContainerGap = false
                    }
                    if unconfirmedContainerGap {
                        htmlRangesAvailable = false
                        htmlContext.invalidate()
                    } else {
                        htmlRanges.append(range)
                        let outsideTemplate = htmlTemplateDepth == 0
                        var imageTags: [NSRange] = []
                        var mediaTags: [(NSRange, String, Bool)] = []
                        let outside = htmlContext.consume(source: (htmlContextText as NSString?) ?? sourceText, range: range, isCancelled: isCancelled,
                            confirmedTag: { tag, name, closing in
                                if name == "img", !closing, htmlTemplateDepth == 0 { imageTags.append(tag) }
                                if ["audio", "video", "iframe"].contains(name), htmlTemplateDepth == 0 { mediaTags.append((tag, name, closing)) }
                                if name == "ruby", type == "html_inline", htmlTemplateDepth == 0,
                                   let parent = cmark_node_parent(node) { rubyTags.append((parent, tag, closing)) }
                                if name == "template" { mediaCollector.cancelPending(); htmlTemplateDepth = closing ? max(0, htmlTemplateDepth - 1) : htmlTemplateDepth + 1 }
                                if name == "script" && !closing {
                                    scriptStartedInContainer = htmlInsideContainer(node)
                                    scriptOpeningNode = node
                                }
                            }, confirmedRawClose: { tag, name in
                                if name == "iframe", htmlTemplateDepth == 0 { mediaTags.append((tag, name, true)) }
                            })
                        safeHTML = outside && outsideTemplate && htmlTemplateDepth == 0
                        if !inUnsupportedContainer {
                            mediaCollector.consume(node: node, range: range, tags: mediaTags, sourceText: sourceText, isCancelled: isCancelled)
                            if isCancelled() { return }
                        }
                        if safeHTML && (!unsupported || cell != nil) {
                            let htmlText = (htmlContextText as NSString?) ?? sourceText
                            let offsets = type == "html_block" ? MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: imageTags, sourceText: sourceText, isCancelled: isCancelled) : nil
                            for tag in imageTags {
                                if isCancelled() { return }
                                guard let verified = MarkdownImageUploadService.confirmedHTMLImage(in: htmlText, range: tag, isCancelled: isCancelled),
                                      let image = MarkdownHTMLMediaService.displayImage(in: htmlText.substring(with: tag)) else { continue }
                                if type == "html_block" {
                                    guard let offset = offsets?[tag.location] else { continue }
                                    let before = NSRange(location: range.location, length: tag.location - range.location)
                                    let after = NSRange(location: NSMaxRange(tag), length: NSMaxRange(range) - NSMaxRange(tag))
                                    let standalone = htmlText.substring(with: before).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                        htmlText.substring(with: after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    htmlImageCandidates.append((node, MarkdownImage(range: tag, paragraphRange: range, url: verified.address,
                                        alt: image.alt, title: image.title, isInline: !standalone, sizing: image.sizing), image.source, offset))
                                } else {
                                    if cell != nil {
                                        guard let table = tables.last, NSLocationInRange(tag.location, table.range) else { continue }
                                        htmlImageTableIndices.insert(tables.count - 1)
                                    }
                                    var parent = cmark_node_parent(node), paragraph: OpaquePointer?
                                    while let current = parent {
                                        if cmark_node_get_type(current) == CMARK_NODE_PARAGRAPH || cmark_node_get_type(current) == CMARK_NODE_HEADING { paragraph = current; break }
                                        parent = cmark_node_parent(current)
                                    }
                                    guard let owner = cell.flatMap({ source.range($0) }) ?? paragraph.flatMap({
                                        plainMultilineParagraphs.contains($0) ? plainMultilineRanges[$0] : source.range($0)
                                    }), tag.location >= owner.location, NSMaxRange(tag) <= NSMaxRange(owner) else { continue }
                                    htmlImageCandidates.append((node, MarkdownImage(range: tag, paragraphRange: owner, url: verified.address,
                                        alt: image.alt, title: image.title, isInline: true, sizing: image.sizing), image.source, 0))
                                }
                            }
                        }
                        if safeHTML && nodeType == CMARK_NODE_HTML_INLINE { confirmedInlineHTML.insert(node) }
                        scriptGapText.removeAll(keepingCapacity: true)
                        scriptGapUnproven = false
                        if !htmlContext.inScriptContext { scriptStartedInContainer = false; scriptOpeningNode = nil }
                        lastHTMLRangeEnd = NSMaxRange(range)
                    }
                } else { htmlRangesAvailable = false; htmlContext.invalidate() }
            }
            if !unsupported, (type == "block_quote" || nodeType == CMARK_NODE_ITEM), cmark_node_first_child(node) == nil,
               cmark_node_get_start_line(node) == cmark_node_get_end_line(node), let start = source.firstPosition(node),
               start < sourceText.length {
                let line = sourceText.lineRange(for: NSRange(location: start, length: 0))
                var end = NSMaxRange(line)
                while end > line.location && (sourceText.character(at: end - 1) == 10 || sourceText.character(at: end - 1) == 13) { end -= 1 }
                if end > line.location && (sourceText.character(at: end - 1) == 32 || sourceText.character(at: end - 1) == 9),
                   let prefixes = fencePrefixes(node, source: source, text: sourceText, position: end,
                                                allowEarlierItem: false, includeNode: true, itemStartColumn: itemStartColumn),
                   prefixes.nested, simpleEmptyFencePrefix(prefixes.source) {
                    fenceContainerLines.append(MarkdownFenceContainerLine(line: prefixes.line, sourcePrefix: prefixes.source,
                                                                            continuationPrefix: prefixes.continuation))
                }
            }
            if !unsupported, type == "paragraph" {
                var hasConfirmedText = false
                func confirmedText(_ current: OpaquePointer) -> Bool {
                    if isCancelled() { return false }
                    if cmark_node_get_type(current) == CMARK_NODE_TEXT {
                        guard let literal = cmark_node_get_literal(current),
                              let range = plainMultilineNodes.contains(current) ? plainMultilineRanges[current] :
                                (source.range(current) ?? source.tabbedLiteralTextRange(current, text: sourceText, isCancelled: isCancelled)),
                              NSMaxRange(range) <= sourceText.length else { return false }
                        let spelling = sourceText.substring(with: range), value = String(cString: literal)
                        if spelling != value && MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: value,
                            sourceOffset: range.location, isCancelled: isCancelled) == nil { return false }
                        hasConfirmedText = true
                    } else if cmark_node_get_type(current) == CMARK_NODE_CODE {
                        guard let literal = cmark_node_get_literal(current),
                              let range = plainMultilineNodes.contains(current) ? plainMultilineRanges[current] : source.range(current),
                              NSMaxRange(range) <= sourceText.length,
                              sourceText.substring(with: range) == String(cString: literal) else { return false }
                        hasConfirmedText = true
                    } else if cmark_node_get_type(current) == CMARK_NODE_IMAGE {
                        guard let range = source.range(current), range.length >= 2,
                              NSMaxRange(range) <= sourceText.length,
                              sourceText.substring(with: NSRange(location: range.location, length: 2)) == "![" else { return false }
                        hasConfirmedText = true
                    } else if cmark_node_get_type(current) == CMARK_NODE_HTML_INLINE {
                        guard let literal = cmark_node_get_literal(current),
                              let range = plainMultilineNodes.contains(current) ? plainMultilineRanges[current] : source.range(current),
                              NSMaxRange(range) <= sourceText.length,
                              sourceText.substring(with: range) == String(cString: literal) else { return false }
                        hasConfirmedText = true
                    } else if let kind = cmark_node_get_type_string(current),
                              ["custom_inline", "custom_block"].contains(String(cString: kind)) {
                        return false
                    }
                    var child = cmark_node_first_child(current)
                    while let next = child {
                        if !confirmedText(next) { return false }
                        child = cmark_node_next(next)
                    }
                    return true
                }
                if confirmedText(node), hasConfirmedText, var range = source.wholeLines(node), range.length > 0 {
                    if let prefix = source.referencePrefix(node), NSMaxRange(prefix) <= NSMaxRange(range) {
                        range.length = NSMaxRange(range) - NSMaxRange(prefix)
                        range.location = NSMaxRange(prefix)
                    }
                    if range.length > 0 {
                        let lastLine = sourceText.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
                        paragraphNodes[node] = paragraphs.count
                        paragraphs.append(MarkdownParagraph(range: range, lastLine: lastLine))
                    }
                }
                var child = cmark_node_first_child(node)
                while let current = child {
                    if isCancelled() { return }
                    if cmark_node_get_type(current) == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(current),
                       let range = source.range(current) ?? source.tabbedLiteralTextRange(current, text: sourceText, isCancelled: isCancelled), range.length > 0, NSMaxRange(range) <= sourceText.length,
                       sourceText.substring(with: range) == String(cString: literal),
                       let prefixes = fencePrefixes(node, source: source, text: sourceText, position: range.location, allowEarlierItem: false, itemStartColumn: itemStartColumn),
                       prefixes.nested, !prefixes.source.isEmpty {
                        fenceContainerLines.append(MarkdownFenceContainerLine(line: prefixes.line, sourcePrefix: prefixes.source,
                                                                                continuationPrefix: prefixes.continuation))
                    }
                    child = cmark_node_next(current)
                }
            }
            if type == "table", !inUnsupportedContainer, let range = source.range(node) {
                var parent = cmark_node_parent(node), quotes = 0, nestedList = false, supported = true
                while let current = parent, let name = cmark_node_get_type_string(current) {
                    switch String(cString: name) {
                    case "block_quote": quotes += 1
                    case "item", "list": nestedList = true
                    case "document": break
                    default: supported = false
                    }
                    parent = cmark_node_parent(current)
                }
                var start = range.location
                while start > 0 && sourceText.character(at: start - 1) != 10 && sourceText.character(at: start - 1) != 13 { start -= 1 }
                let prefix = quotes > 0 || nestedList ? sourceText.substring(with: NSRange(location: start, length: range.location - start)) : ""
                if supported, let table = MarkdownTableEditingService.presentationTable(in: sourceText, range: range,
                        containerPrefix: prefix, quoteDepth: quotes, nestedList: nestedList) {
                    tables.append(tableDisplay(table, text: sourceText, node: node, source: source, mathInline: inlineByNode, emojiCandidates: emojiCandidates, syntax: syntax, isCancelled: isCancelled))
                    tableNodes.append(node)
                }
            }
            if type == "link", let url = cmark_node_get_url(node) {
                var ancestor = cmark_node_parent(node), cell: OpaquePointer?, insideImage = false
                while let current = ancestor {
                    if let name = cmark_node_get_type_string(current) {
                        let name = String(cString: name)
                        if name == "table_cell" { cell = current }
                        if name == "image" { insideImage = true }
                    }
                    ancestor = cmark_node_parent(current)
                }
                var positions: Source.TableCellPositions?
                if let cell {
                    if let cached = linkCellPositions[cell] { positions = cached }
                    else {
                        positions = source.tableCellPositions(cell)
                        linkCellPositions[cell] = .some(positions)
                    }
                }
                let range: NSRange?
                if plainMultilineNodes.contains(node) {
                    range = plainMultilineRanges[node].flatMap {
                        source.linkMarkers($0, node: node, mappedRange: { confirmedInlineRange($0) }).isEmpty ? nil : $0
                    }
                    if range == nil, let pending = plainMultilineRanges[node] {
                        delayedMappedLinks.append((node, pending, String(cString: url)))
                    }
                } else { range = source.linkRange(node, tableCell: cell, tablePositions: positions) }
                if !insideImage, let range, range.length > 0 {
                    links.append(MarkdownLink(range: range, url: String(cString: url)))
                }
            }
            if !inUnsupportedContainer, safeHTML, type == "html_block", let range = source.range(node),
               let pointer = cmark_node_get_literal(node) {
                let literal = String(cString: pointer) as NSString
                if let widget = MarkdownHTMLMediaService.twitterWidget(literal as String, isCancelled: isCancelled),
                   MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: sourceText, isCancelled: isCancelled) != nil {
                    var start = 0, end = literal.length
                    while start < end && [9, 10, 12, 13, 32].contains(Int(literal.character(at: start))) { if isCancelled() { break }; start += 1 }
                    while end > start && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { if isCancelled() { break }; end -= 1 }
                    if !isCancelled() { twitterCandidates.append((range, .init(node: node, start: start, end: end, widget: widget))) }
                }
                if MarkdownHTMLMediaService.plainDetails(literal as String, isCancelled: isCancelled) == nil,
                   let display = MarkdownHTMLMediaService.editingHTMLBlock(literal as String, isCancelled: isCancelled),
                   MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: sourceText, isCancelled: isCancelled) != nil {
                    var start = 0, end = literal.length
                    while start < end && [9, 10, 12, 13, 32].contains(Int(literal.character(at: start))) { start += 1 }
                    while end > start && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { end -= 1 }
                    htmlBlockCandidates.append((range, .init(node: node, start: start, end: end, html: literal as String), display))
                }
                if let media = MarkdownHTMLMediaService.standaloneMedia(literal as String, isCancelled: isCancelled),
                   MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: sourceText, isCancelled: isCancelled) != nil {
                    standaloneMediaCandidates.append((node, range, media))
                }
                if let candidate = standaloneSVGBlockCandidate(node, range: range, text: sourceText, isCancelled: isCancelled) { svgCandidates.append(candidate) }
                if let style = MarkdownHTMLMediaService.pageBreakStyle(literal as String, isCancelled: isCancelled),
                   MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: sourceText, isCancelled: isCancelled) != nil {
                    var offset = 0
                    while offset < literal.length && [9, 10, 12, 13, 32].contains(Int(literal.character(at: offset))) { offset += 1 }
                    pageBreakCandidates.append((node, range, offset, style))
                }
                if let details = MarkdownHTMLMediaService.plainDetails(literal as String, isCancelled: isCancelled),
                   MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: sourceText, isCancelled: isCancelled) != nil {
                    var offset = 0
                    while offset < literal.length && [9, 10, 12, 13, 32].contains(Int(literal.character(at: offset))) { offset += 1 }
                    detailsCandidates.append((node, range, offset, details.summary, details.body))
                }
            }
            if !inUnsupportedContainer, safeHTML, type == "html_block", let range = source.range(node),
               let pointer = cmark_node_get_literal(node) {
                let literal = String(cString: pointer) as NSString
                var context = MarkdownImageUploadService.HTMLContext(), tags: [NSRange] = []
                _ = context.consume(source: literal, range: NSRange(location: 0, length: literal.length), isCancelled: isCancelled,
                                    confirmedTag: { tag, _, _ in tags.append(tag) })
                var start = 0, end = literal.length
                while start < end && [9, 10, 12, 13, 32].contains(Int(literal.character(at: start))) { start += 1 }
                while end > start && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { end -= 1 }
                let standalone = tags.count == 1 && tags[0] == NSRange(location: start, length: end - start) &&
                    end >= start + 2 && literal.character(at: end - 2) == 47 && literal.character(at: end - 1) == 62
                if !standalone, let media = MarkdownHTMLMediaService.embeddedMedia(in: literal as String) {
                    audioBlocks.append(MarkdownAudioBlock(range: range, media: media))
                }
            }
            if !inUnsupportedContainer, safeHTML, type == "html_block", let range = source.range(node),
               let literal = cmark_node_get_literal(node),
               let frame = MarkdownHTMLMediaService.iframe(in: String(cString: literal)) {
                iframeBlocks.append(MarkdownIframeBlock(range: range, html: MarkdownHTMLMediaService.iframeHTML(frame),
                                                        width: frame.width, height: frame.height, title: frame.title))
            }
            if !unsupported, let alert = alert(node, source: source, text: sourceText) {
                spans.append(MarkdownPresentationSpan(range: alert.range, kind: .alert(alert.label), markerRanges: [alert.marker]))
            }
            if !inUnsupportedContainer, type == "paragraph", let parent = cmark_node_parent(node),
               let parentName = cmark_node_get_type_string(parent), String(cString: parentName) == "document",
               let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
               let childName = cmark_node_get_type_string(child), String(cString: childName) == "text",
               let range = source.range(node), (text as NSString).substring(with: range) == "[toc]" {
                tableOfContents.append(range)
            }
            if !inUnsupportedContainer, nodeType == CMARK_NODE_FOOTNOTE_REFERENCE,
               let reference = source.range(node), let definition = cmark_node_parent_footnote_def(node),
               let definitionRange = source.footnoteDefinitionMarker(definition) {
                footnotes.append(MarkdownFootnote(referenceRange: reference, definitionRange: definitionRange,
                                                  text: footnoteText(definition)))
                spans.append(MarkdownPresentationSpan(range: reference, kind: .link, markerRanges: []))
            }
            if !inUnsupportedContainer, type == "tasklist",
               let checkbox = source.taskCheckbox(node),
               (checkbox.state != 32) == cmark_gfm_extensions_get_tasklist_item_checked(node) {
                taskCheckboxes.append(checkbox)
                if checkbox.state != 32, let range = source.range(node),
                   range.location <= checkbox.markerRange.location, NSMaxRange(range) >= NSMaxRange(checkbox.markerRange) {
                    completedTaskRanges.append(range)
                }
            } else if !inUnsupportedContainer, type == "item" {
                if let checkbox = source.quotedTaskCheckbox(node) { taskCheckboxes.append(checkbox) }
            }
            if !inUnsupportedContainer, type == "paragraph", let parent = cmark_node_parent(node),
               let parentName = cmark_node_get_type_string(parent), String(cString: parentName) == "document",
               let child = cmark_node_first_child(node),
               cmark_node_next(child) == nil, let name = cmark_node_get_type_string(child),
               String(cString: name) == "image", let imageRange = source.range(child),
               let paragraphRange = source.range(node), let url = cmark_node_get_url(child) {
                let title = cmark_node_get_title(child).map { String(cString: $0) }
                images.append(MarkdownImage(range: imageRange, paragraphRange: paragraphRange,
                    url: String(cString: url), alt: headingText(child), title: title))
            }
            if !inUnsupportedContainer, type == "image",
               let range = plainMultilineNodes.contains(node) ? confirmedEditingImageRange(node) : source.range(node), let url = cmark_node_get_url(node),
               range.length >= 4, NSMaxRange(range) <= sourceText.length,
               sourceText.substring(with: NSRange(location: range.location, length: 2)) == "![" {
                var ancestor = cmark_node_parent(node), paragraph: OpaquePointer?
                while let current = ancestor {
                    if cmark_node_get_type(current) == CMARK_NODE_PARAGRAPH || cmark_node_get_type(current) == CMARK_NODE_HEADING { paragraph = current; break }
                    ancestor = cmark_node_parent(current)
                }
                if let paragraph, let paragraphRange = plainMultilineNodes.contains(node) ? source.wholeLines(paragraph) : source.range(paragraph),
                   range.location >= paragraphRange.location, NSMaxRange(range) <= NSMaxRange(paragraphRange) {
                    let onlyChild = cmark_node_first_child(paragraph) == node && cmark_node_next(node) == nil
                    let parent = cmark_node_parent(paragraph)
                    if cmark_node_get_type(paragraph) == CMARK_NODE_HEADING || !onlyChild || parent.map({ cmark_node_get_type($0) != CMARK_NODE_DOCUMENT }) == true {
                        let title = cmark_node_get_title(node).map { String(cString: $0) }
                        images.append(MarkdownImage(range: range, paragraphRange: paragraphRange,
                            url: String(cString: url), alt: headingText(node), title: title, isInline: true))
                        confirmedInlineAttachments[node] = range
                    }
                }
            }
            if type == "image", let url = cmark_node_get_url(node) {
                var ancestor = cmark_node_parent(node), cell: OpaquePointer?, nestedImage = false
                while let current = ancestor {
                    if let name = cmark_node_get_type_string(current) {
                        if String(cString: name) == "table_cell" { cell = current; break }
                        if String(cString: name) == "image" { nestedImage = true }
                    }
                    ancestor = cmark_node_parent(current)
                }
                if !nestedImage, let cell {
                    let positions: Source.TableCellPositions?
                    if let cached = linkCellPositions[cell] { positions = cached }
                    else {
                        positions = source.tableCellPositions(cell, isCancelled: isCancelled)
                        linkCellPositions[cell] = .some(positions)
                    }
                    if let positions, let range = source.tableInlineRange(node, positions: positions),
                       let cellRange = source.range(cell), range.length >= 4,
                       range.location >= cellRange.location, NSMaxRange(range) <= NSMaxRange(cellRange),
                       NSMaxRange(range) <= sourceText.length,
                       let table = tables.last, NSLocationInRange(range.location, table.range),
                       sourceText.substring(with: NSRange(location: range.location, length: 2)) == "![" {
                        var low = 0, high = table.rows.count
                        while low < high {
                            let middle = (low + high) / 2
                            if NSMaxRange(table.rows[middle].range) <= range.location { low = middle + 1 } else { high = middle }
                        }
                        let cells = low < table.rows.count ? table.rows[low].cells : []
                        var first = 0, last = cells.count
                        while first < last {
                            let middle = (first + last) / 2
                            if NSMaxRange(cells[middle].range) <= range.location { first = middle + 1 } else { last = middle }
                        }
                        if first < cells.count, range.location >= cells[first].range.location, NSMaxRange(range) <= NSMaxRange(cells[first].range) {
                            let title = cmark_node_get_title(node).map { String(cString: $0) }
                            images.append(MarkdownImage(range: range, paragraphRange: cellRange,
                                url: String(cString: url), alt: headingText(node), title: title, isInline: true))
                        }
                    }
                }
            }
            if let inline = inlineByNode[node], let parent = cmark_node_parent(node),
               let range = plainMultilineNodes.contains(node) ? plainMultilineRanges[node] :
                    source.mathInlineRange(line: inline.line, column: inline.column, byteLength: inline.byteLength, parent: parent),
               range.length >= 2, NSMaxRange(range) <= sourceText.length,
               sourceText.substring(with: range).utf16.elementsEqual(("$" + inline.text + "$").utf16) {
                inlineFormulas.append(MarkdownFormula(range: range, source: inline.text))
                confirmedInlineAttachments[node] = range
            }
            if type == "code_block", cmark_node_get_syntax_extension(node) == mathExtension,
               let range = source.mathBlockRange(node), let literal = cmark_node_get_literal(node) {
                formulas.append(MarkdownFormula(range: range, source: String(cString: literal)))
            }
            if !unsupported, type == "code_block", let parent = cmark_node_parent(node),
               cmark_node_get_type(parent) == CMARK_NODE_DOCUMENT,
               let range = source.range(node), source.fenceMarkers(range).count == 2,
               let info = cmark_node_get_fence_info(node),
               let kind = MarkdownDiagram.Kind(rawValue: String(cString: info).trimmingCharacters(in: .whitespaces)),
               let literal = cmark_node_get_literal(node) {
                diagrams.append(MarkdownDiagram(range: range, source: String(cString: literal), kind: kind))
            }
            var confirmedCodeBlock: MarkdownCodeBlock?
            if !unsupported, type == "code_block", cmark_node_get_syntax_extension(node) != mathExtension,
               let range = source.fenceRange(node), let info = cmark_node_get_fence_info(node),
               let literal = cmark_node_get_literal(node),
               let block = fencedCodeBlock(node, source: source, text: sourceText, range: range,
                                           info: String(cString: info), literal: String(cString: literal), isCancelled: isCancelled) {
                codeBlocks.append(block)
                confirmedCodeBlock = block
            }
            if type == "code_block" || type == "html_block" || type == "block_quote" || type == "list" ||
                type == "table" || nodeType == CMARK_NODE_FOOTNOTE_DEFINITION {
                let topLevelFence = type == "code_block" && confirmedCodeBlock?.isClosed == false &&
                    confirmedCodeBlock?.bodyRange.length == 0 &&
                    cmark_node_parent(node).map { cmark_node_get_type($0) == CMARK_NODE_DOCUMENT } == true
                if topLevelFence, let block = confirmedCodeBlock,
                   NSMaxRange(block.range) == sourceText.length { fenceBlockedEOF = true }
                if let lines = source.wholeLines(node, skipFirst: topLevelFence) {
                    fenceBlockedRanges.append(lines)
                    if NSMaxRange(lines) == sourceText.length &&
                        (type != "code_block" || confirmedCodeBlock?.isClosed != true) { fenceBlockedEOF = true }
                } else if !topLevelFence {
                    fenceContextAvailable = false
                }
            }
            if !unsupported, type == "heading", let range = source.range(node) ?? source.headingAnchor(node) {
                let heading = headingData(node, mathInline: inlineByNode, emojiByNode: emojiByNode)
                var plainTextRange: NSRange?
                if includeEmojiCandidates, heading.emoji.isEmpty, let child = cmark_node_first_child(node),
                   cmark_node_next(child) == nil, cmark_node_get_type(child) == CMARK_NODE_TEXT,
                   let literal = cmark_node_get_literal(child), let textRange = source.range(child),
                   textRange.location >= range.location, NSMaxRange(textRange) <= NSMaxRange(range),
                   NSMaxRange(textRange) <= sourceText.length {
                    let text = String(cString: literal)
                    if text.utf16.elementsEqual(heading.title.utf16),
                       sourceText.substring(with: textRange).utf16.elementsEqual(text.utf16) {
                        plainTextRange = textRange
                    }
                }
                headings.append(MarkdownHeading(
                    level: Int(cmark_node_get_heading_level(node)), title: heading.title, range: range, emoji: heading.emoji,
                    plainTextRange: plainTextRange
                ))
                if includeUppercaseRuns && includeEmojiCandidates { uppercaseHeadingNodes.append(node) }
            }
            let spanRange = !unsupported ? (plainMultilineNodes.contains(node) ? plainMultilineRanges[node] : source.range(node)) : nil
            let deferred = !unsupported && plainMultilineNodes.contains(node) && nodeType != CMARK_NODE_TEXT &&
                spanRange != nil && confirmedInlineRange(node) == nil
            if deferred, let range = spanRange, ["strong", "emph", "strikethrough", "link", "code"].contains(type) {
                delayedMappedSpans.append((node, type, range))
            }
            if !unsupported, let range = spanRange, !deferred {
                if !inlineHTMLContainerTypes.contains(type) {
                    for (_, _, underline, opening, closing) in underlines(in: node, source: source, text: sourceText) {
                        spans.append(MarkdownPresentationSpan(range: underline, kind: .underline, markerRanges: [opening, closing]))
                    }
                }
                if type == "text" {
                    for (item, kind) in inlineDecorations(node, source: source, text: sourceText,
                                                          mappedRange: plainMultilineNodes.contains(node) ? range : nil) {
                        let length = kind == .highlight ? 2 : 1
                        spans.append(MarkdownPresentationSpan(range: item, kind: kind,
                            markerRanges: [NSRange(location: item.location, length: length), NSRange(location: NSMaxRange(item) - length, length: length)]))
                    }
                }
                var span: MarkdownPresentationSpan?
                switch type {
                case "heading":
                    let level = Int(cmark_node_get_heading_level(node))
                    span = MarkdownPresentationSpan(range: range, kind: .heading(level), markerRanges: source.headingMarkers(range, allowNoSpace: MarkdownMathExtension.looseHeadings(in: mathExtension)[node] != nil))
                case "strong":
                    span = MarkdownPresentationSpan(range: range, kind: .strong, markerRanges: source.pairedMarkers(range, characters: [42, 95], count: 2))
                case "emph":
                    span = MarkdownPresentationSpan(range: range, kind: .emphasis, markerRanges: source.pairedMarkers(range, characters: [42, 95], count: 1))
                case "strikethrough":
                    let childRange = cmark_node_first_child(node).flatMap { plainMultilineRanges[$0] }
                    if let subscriptRange = subscriptRange(node, source: source, text: sourceText,
                        mappedRange: plainMultilineNodes.contains(node) ? range : nil, mappedChild: childRange) {
                        span = MarkdownPresentationSpan(range: subscriptRange, kind: .subscriptText,
                            markerRanges: [NSRange(location: subscriptRange.location, length: 1), NSRange(location: NSMaxRange(subscriptRange) - 1, length: 1)])
                    } else {
                        span = MarkdownPresentationSpan(range: range, kind: .strikethrough, markerRanges: source.pairedMarkers(range, characters: [126], count: 2))
                    }
                case "code":
                    let expanded = source.codeRange(range)
                    span = MarkdownPresentationSpan(range: expanded?.0 ?? range, kind: .code, markerRanges: expanded?.1 ?? [])
                case "link":
                    let markers = plainMultilineNodes.contains(node)
                        ? source.linkMarkers(range, node: node, mappedRange: { confirmedInlineRange($0) })
                        : source.linkMarkers(range, node: node)
                    span = MarkdownPresentationSpan(range: range, kind: .link, markerRanges: markers)
                case "block_quote":
                    span = MarkdownPresentationSpan(range: range, kind: .quote, markerRanges: source.quoteMarkers(range))
                case "code_block" where cmark_node_get_syntax_extension(node) != mathExtension:
                    span = MarkdownPresentationSpan(range: confirmedCodeBlock?.range ?? range, kind: .codeBlock,
                                                    markerRanges: confirmedCodeBlock?.fenceMarkers ?? source.fenceMarkers(range))
                default: break
                }
                if let span { spans.append(span) }
            } else if let block = confirmedCodeBlock {
                spans.append(MarkdownPresentationSpan(range: block.range, kind: .codeBlock, markerRanges: block.fenceMarkers))
            }
            var child = cmark_node_first_child(node)
            while let current = child {
                visit(current, inUnsupportedContainer: unsupported, listDepth: currentListDepth)
                child = cmark_node_next(current)
            }
        }
        visit(root, inUnsupportedContainer: false, listDepth: 0)
        if !twitterCandidates.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenTwitter(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: twitterCandidates.map(\.proof), isCancelled: isCancelled)
            for index in accepted.sorted() {
                if isCancelled() { break }
                let candidate = twitterCandidates[index]
                guard let frame = MarkdownHTMLMediaService.twitterFrame(candidate.proof.widget) else { continue }
                iframeBlocks.append(MarkdownIframeBlock(range: candidate.range, html: MarkdownHTMLMediaService.iframeHTML(frame),
                    width: frame.width, height: frame.height, title: frame.title))
            }
            iframeBlocks.sort { $0.range.location < $1.range.location }
        }
        if !htmlBlockCandidates.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenHTMLBlocks(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: htmlBlockCandidates.map(\.proof), isCancelled: isCancelled)
            for index in accepted.sorted() {
                if isCancelled() { break }
                let candidate = htmlBlockCandidates[index]
                if let details = MarkdownHTMLMediaService.richDetails(candidate.proof.html, isCancelled: isCancelled) {
                    detailsBlocks.append(MarkdownDetailsBlock(range: candidate.range, summary: details.summary, body: "",
                                                              summaryHTML: details.summaryHTML, bodyHTML: details.bodyHTML,
                                                              initiallyOpen: details.initiallyOpen))
                } else {
                    htmlBlocks.append(MarkdownHTMLBlock(range: candidate.range, html: candidate.display))
                }
            }
        }
        if !standaloneMediaCandidates.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenStandaloneMedia(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: standaloneMediaCandidates.map { ($0.node, $0.media) }, isCancelled: isCancelled)
            for index in accepted.sorted() {
                if isCancelled() { break }
                let candidate = standaloneMediaCandidates[index]
                audioBlocks.append(MarkdownAudioBlock(range: candidate.range, media: candidate.media.media))
            }
        }
        if !pageBreakCandidates.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenPageBreaks(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: pageBreakCandidates.map { ($0.node, $0.offset, $0.style) }, isCancelled: isCancelled)
            pageBreaks = pageBreakCandidates.filter { accepted.contains($0.node) }.map(\.range)
        }
        if !detailsCandidates.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenDetails(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: detailsCandidates.map { ($0.node, $0.offset, $0.summary, $0.body) }, isCancelled: isCancelled)
            for candidate in detailsCandidates where accepted.contains(candidate.node) {
                if isCancelled() { break }
                if let summary = MarkdownHTMLMediaService.detailsDisplayText(candidate.summary, isCancelled: isCancelled),
                   let body = MarkdownHTMLMediaService.detailsDisplayText(candidate.body, isCancelled: isCancelled) {
                    detailsBlocks.append(MarkdownDetailsBlock(range: candidate.range, summary: summary, body: body))
                }
            }
        }
        if !htmlImageCandidates.isEmpty && !isCancelled() {
            let proof = htmlImageCandidates.map { MarkdownHTMLMediaService.ImageProofCandidate(node: $0.node, offset: $0.offset, source: $0.source) }
            let accepted = MarkdownHTMLMediaService.provenImageIndices(root: root, mathExtension: mathExtension, options: options, text: sourceText,
                                                                       candidates: proof, isCancelled: isCancelled)
            for index in accepted.keys {
                if isCancelled() { break }
                let candidate = htmlImageCandidates[index]
                images.append(candidate.image)
                if cmark_node_get_type(candidate.node) == CMARK_NODE_HTML_INLINE,
                   plainMultilineNodes.contains(candidate.node), plainMultilineRanges[candidate.node] == candidate.image.range {
                    confirmedHTMLImageNodes[candidate.node] = candidate.image.range
                }
            }
            images.sort { $0.range.location < $1.range.location }
        }
        let pairedMedia = mediaCollector.candidates
        if !pairedMedia.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenMediaIndices(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: pairedMedia.map(\.proof), isCancelled: isCancelled)
            let selected: [(proof: MarkdownHTMLMediaService.MediaProofCandidate, range: NSRange, isInline: Bool)] = accepted.map { pairedMedia[$0] }
            let ordered = selected.sorted {
                $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location
            }
            let existing = (audioBlocks.map(\.range) + iframeBlocks.map(\.range)).sorted { $0.location < $1.location }
            var existingEnds: [Int] = [], maximumEnd = 0
            for range in existing {
                if isCancelled() { break }
                maximumEnd = max(maximumEnd, NSMaxRange(range)); existingEnds.append(maximumEnd)
            }
            var lastEnd = 0
            for candidate in ordered {
                if isCancelled() || existingEnds.count != existing.count { break }
                var low = 0, high = existing.count
                while low < high {
                    let middle = (low + high) / 2
                    if existing[middle].location < NSMaxRange(candidate.range) { low = middle + 1 } else { high = middle }
                }
                guard candidate.range.location >= lastEnd,
                      !(low > 0 && existingEnds[low - 1] > candidate.range.location) else { continue }
                lastEnd = NSMaxRange(candidate.range)
                switch candidate.proof.expected {
                case .media(let media): audioBlocks.append(MarkdownAudioBlock(range: candidate.range, media: media, isInline: candidate.isInline))
                case .frame(let frame): iframeBlocks.append(MarkdownIframeBlock(range: candidate.range, html: MarkdownHTMLMediaService.iframeHTML(frame),
                    width: frame.width, height: frame.height, title: frame.title, isInline: candidate.isInline))
                }
            }
            audioBlocks.sort { $0.range.location < $1.range.location }
            iframeBlocks.sort { $0.range.location < $1.range.location }
        }
        if !audioBlocks.isEmpty || !iframeBlocks.isEmpty {
            let mediaRanges = (audioBlocks.map(\.range) + iframeBlocks.map(\.range)).sorted { $0.location < $1.location }
            var ends: [Int] = [], maximumEnd = 0
            for range in mediaRanges {
                if isCancelled() { break }
                maximumEnd = max(maximumEnd, NSMaxRange(range)); ends.append(maximumEnd)
            }
            func overlapsMedia(_ range: NSRange) -> Bool {
                var low = 0, high = mediaRanges.count
                while low < high {
                    let middle = (low + high) / 2
                    if mediaRanges[middle].location < NSMaxRange(range) { low = middle + 1 } else { high = middle }
                }
                return low > 0 && ends[low - 1] > range.location
            }
            if !isCancelled(), ends.count == mediaRanges.count {
                var keptImages: [MarkdownImage] = [], keptFormulas: [MarkdownFormula] = [], keptEmoji: [MarkdownEmojiCandidate] = []
                for image in images { if isCancelled() { break }; if !overlapsMedia(image.range) { keptImages.append(image) } }
                for formula in inlineFormulas { if isCancelled() { break }; if !overlapsMedia(formula.range) { keptFormulas.append(formula) } }
                for candidate in emojiCandidates { if isCancelled() { break }; if !overlapsMedia(candidate.range) { keptEmoji.append(candidate) } }
                if !isCancelled() { images = keptImages; inlineFormulas = keptFormulas; emojiCandidates = keptEmoji }
            }
        }
        let filteredHTML = filterInlineHTMLForStyles(allInlineHTML, confirmed: confirmedInlineHTML, text: sourceText, isCancelled: isCancelled)
        confirmedInlineHTML = filteredHTML.confirmed
        let rubyCandidates = inlineRubyCandidates(parents: inlineHTMLParents, confirmed: confirmedInlineHTML, source: source, text: sourceText, sourceRange: { node in
            if plainMultilineNodes.contains(node) { return plainMultilineRanges[node] }
            return cmark_node_get_type(node) == CMARK_NODE_TEXT ? source.editingTextRange(node) : source.range(node)
        }, isCancelled: isCancelled)
        if !rubyCandidates.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenRuby(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: rubyCandidates.map(\.proof), isCancelled: isCancelled)
            for index in accepted.sorted() {
                if isCancelled() { break }
                let value = rubyCandidates[index].value
                var low = 0, high = emojiCandidates.count
                while low < high {
                    if isCancelled() { break }
                    let middle = (low + high) / 2
                    if NSMaxRange(emojiCandidates[middle].range) <= value.range.location { low = middle + 1 } else { high = middle }
                }
                if !isCancelled() && (low == emojiCandidates.count || emojiCandidates[low].range.location >= NSMaxRange(value.range)) { ruby.append(value) }
            }
        }
        let rubyBlocked = unconfirmedRubyRanges(tags: rubyTags, accepted: Set(ruby.map(\.range)), sourceLength: sourceText.length,
            parentRange: { source.range($0) }, isCancelled: isCancelled)
        var blockedHTML: [NSRange] = []
        for range in (filteredHTML.blocked + rubyBlocked).sorted(by: { $0.location < $1.location }) {
            if isCancelled() { break }
            if let last = blockedHTML.last, range.location <= NSMaxRange(last) {
                blockedHTML[blockedHTML.count - 1] = NSUnionRange(last, range)
            } else { blockedHTML.append(range) }
        }
        svgCandidates.append(contentsOf: standaloneSVGInlineCandidates(parents: inlineHTMLParents, confirmed: confirmedInlineHTML,
            source: source, text: sourceText, isCancelled: isCancelled))
        if !svgCandidates.isEmpty && !isCancelled() {
            let accepted = MarkdownHTMLMediaService.provenSVG(root: root, mathExtension: mathExtension, options: options,
                text: sourceText, candidates: svgCandidates.map(\.proof), isCancelled: isCancelled)
            for index in accepted.sorted() {
                if isCancelled() { break }
                let candidate = svgCandidates[index]
                var low = 0, high = blockedHTML.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(blockedHTML[middle]) <= candidate.range.location { low = middle + 1 } else { high = middle }
                }
                if low < blockedHTML.count && blockedHTML[low].location < NSMaxRange(candidate.range) { continue }
                let paragraphRange = candidate.isInline ? candidate.paragraph.flatMap { source.range($0) } : candidate.range
                guard let paragraphRange else { continue }
                images.append(MarkdownImage(range: candidate.range, paragraphRange: paragraphRange,
                    url: "data:image/svg+xml;base64," + candidate.data.base64EncodedString(), alt: "", title: nil, isInline: candidate.isInline))
            }
            images.sort { $0.range.location < $1.range.location }
        }
        let confirmedHTMLImages = Set(images.filter { $0.sizing != nil && $0.isInline }.map(\.range))
        let htmlTableIndices = htmlImageTableIndices.union(htmlKeyboardTableIndices)
        if !htmlTableIndices.isEmpty {
            for index in htmlTableIndices.sorted() {
                if isCancelled() { break }
                tables[index] = tableDisplay(tables[index], text: sourceText, node: tableNodes[index], source: source,
                    mathInline: inlineByNode, emojiCandidates: emojiCandidates, confirmedHTMLImages: confirmedHTMLImages, confirmedInlineHTML: confirmedInlineHTML,
                    syntax: syntax, isCancelled: isCancelled)
            }
        }
        for (node, range) in confirmedHTMLImageNodes where confirmedInlineHTML.contains(node) {
            if isCancelled() { break }
            var low = 0, high = blockedHTML.count
            while low < high {
                if isCancelled() { break }
                let middle = (low + high) / 2
                if NSMaxRange(blockedHTML[middle]) <= range.location { low = middle + 1 } else { high = middle }
            }
            if isCancelled() { break }
            guard low == blockedHTML.count || blockedHTML[low].location >= NSMaxRange(range) else { continue }
            confirmedInlineAttachments[node] = range
        }
        for node in confirmedInlineHTML {
            if isCancelled() { break }
            guard let range = plainMultilineNodes.contains(node) ? plainMultilineRanges[node] : source.range(node),
                  htmlSourceMatches(node, range: range, text: sourceText, isCancelled: isCancelled),
                  ["<br>", "<br/>", "<br />"].contains(sourceText.substring(with: range).lowercased()) else { continue }
            confirmedInlineAttachments[node] = range
        }
        var htmlPairsByParent: [OpaquePointer: [InlineHTMLPair]] = [:]
        let acceptedRubyRanges = Set(ruby.map(\.range))
        let rubyParents = Set(rubyCandidates.compactMap { acceptedRubyRanges.contains($0.value.range) ? cmark_node_parent($0.proof.opening) : nil })
        for parent in inlineHTMLParents {
            if isCancelled() { break }
            let mapped: ((OpaquePointer) -> NSRange?)? = plainMultilineNodes.contains(parent) || plainMultilineParagraphs.contains(parent)
                ? { plainMultilineRanges[$0] } : nil
            let pairs = inlineHTMLPairs(in: parent, confirmed: confirmedInlineHTML, source: source, text: sourceText,
                                        mappedRange: mapped, ignoreRubyTags: rubyParents.contains(parent), isCancelled: isCancelled)
            htmlPairsByParent[parent] = pairs
            for pair in pairs {
                let range = NSUnionRange(pair.openingRange, pair.closingRange)
                spans.append(MarkdownPresentationSpan(range: range, kind: pair.kind,
                                                      markerRanges: [pair.openingRange, pair.closingRange]))
                if let href = pair.href { links.append(MarkdownLink(range: range, url: href)) }
            }
        }
        unconfirmedInlineRanges.removeAll()
        for parent in inlineHTMLParents.reversed() {
            if isCancelled() { break }
            guard let pairs = htmlPairsByParent[parent], !pairs.isEmpty else { continue }
            let openings = Dictionary(pairs.map { ($0.opening, $0) }, uniquingKeysWith: { first, _ in first })
            let closings = Dictionary(pairs.map { ($0.closing, $0) }, uniquingKeysWith: { first, _ in first })
            var stack: [(pair: InlineHTMLPair, cursor: Int, valid: Bool)] = []
            var child = cmark_node_first_child(parent)
            while let current = child {
                if isCancelled() { break }
                defer { child = cmark_node_next(current) }
                if let pair = openings[current] {
                    if !stack.isEmpty && stack[stack.count - 1].cursor != pair.openingRange.location { stack[stack.count - 1].valid = false }
                    stack.append((pair, NSMaxRange(pair.openingRange), true))
                } else if let pair = closings[current], let top = stack.last, top.pair.opening == pair.opening {
                    stack.removeLast()
                    let valid = top.valid && top.cursor == pair.closingRange.location
                    if valid {
                        confirmedInlineAttachments[pair.opening] = pair.openingRange
                        confirmedInlineAttachments[pair.closing] = pair.closingRange
                    }
                    if !stack.isEmpty {
                        stack[stack.count - 1].valid = stack[stack.count - 1].valid && valid
                        stack[stack.count - 1].cursor = NSMaxRange(pair.closingRange)
                    }
                } else if !stack.isEmpty {
                    if let range = confirmedInlineRange(current), range.location == stack[stack.count - 1].cursor {
                        stack[stack.count - 1].cursor = NSMaxRange(range)
                    } else { stack[stack.count - 1].valid = false }
                }
            }
        }
        unconfirmedInlineRanges.removeAll()
        for (node, type, range) in delayedMappedSpans {
            if isCancelled() { break }
            guard confirmedInlineRange(node) != nil else { continue }
            let kind: MarkdownPresentationKind, markers: [NSRange]
            switch type {
            case "strong": kind = .strong; markers = source.pairedMarkers(range, characters: [42, 95], count: 2)
            case "emph": kind = .emphasis; markers = source.pairedMarkers(range, characters: [42, 95], count: 1)
            case "strikethrough":
                let childRange = cmark_node_first_child(node).flatMap { plainMultilineRanges[$0] }
                if let subscriptRange = subscriptRange(node, source: source, text: sourceText, mappedRange: range, mappedChild: childRange) {
                    kind = .subscriptText
                    markers = [NSRange(location: subscriptRange.location, length: 1), NSRange(location: NSMaxRange(subscriptRange) - 1, length: 1)]
                } else { kind = .strikethrough; markers = source.pairedMarkers(range, characters: [126], count: 2) }
            case "link": kind = .link; markers = source.linkMarkers(range, node: node, mappedRange: { confirmedInlineRange($0) })
            case "code":
                guard let expanded = source.codeRange(range) else { continue }
                spans.append(MarkdownPresentationSpan(range: expanded.0, kind: .code, markerRanges: expanded.1))
                continue
            default: continue
            }
            spans.append(MarkdownPresentationSpan(range: range, kind: kind, markerRanges: markers))
        }
        for (node, range, url) in delayedMappedLinks {
            if isCancelled() { break }
            guard confirmedInlineRange(node) != nil,
                  !source.linkMarkers(range, node: node, mappedRange: { confirmedInlineRange($0) }).isEmpty else { continue }
            links.append(MarkdownLink(range: range, url: url))
        }
        func confirmedSoftBreak(_ node: OpaquePointer) -> NSRange? {
            guard let previous = cmark_node_previous(node), let next = cmark_node_next(node),
                  let before = confirmedInlineRange(previous), let after = confirmedInlineRange(next),
                  NSMaxRange(before) < after.location else { return nil }
            var paragraph = cmark_node_parent(node)
            while let current = paragraph, cmark_node_get_type(current) != CMARK_NODE_PARAGRAPH {
                if isCancelled() { return nil }
                paragraph = cmark_node_parent(current)
            }
            guard let paragraph, let prefix = fencePrefixes(paragraph, source: source, text: sourceText, position: after.location,
                      allowEarlierItem: false, itemStartColumn: itemStartColumn) else { return nil }
            var cursor = NSMaxRange(before)
            while cursor < after.location && sourceText.character(at: cursor) == 32 {
                if isCancelled() { return nil }
                cursor += 1
            }
            if cursor < after.location, sourceText.character(at: cursor) == 10 || sourceText.character(at: cursor) == 13 {
                let newline = sourceText.character(at: cursor)
                cursor += 1
                if newline == 13 && cursor < after.location && sourceText.character(at: cursor) == 10 { cursor += 1 }
                let tail = NSRange(location: cursor, length: after.location - cursor)
                if sourceText.substring(with: tail).utf16.elementsEqual(prefix.source.utf16) {
                    return NSRange(location: NSMaxRange(before), length: after.location - NSMaxRange(before))
                }
            }
            return nil
        }
        for node in softBreakNodes {
            if isCancelled() { break }
            guard let range = confirmedSoftBreak(node) else { continue }
            if !syntax.preserveEditingSoftBreaks {
                textReplacements.append(.init(range: range, text: " ", kind: .softBreak))
            } else if !(syntax.preserveEditingWhitespace ?? false), let next = cmark_node_next(node),
                      plainMultilineNodes.contains(next), let nextRange = confirmedInlineRange(next),
                      let parent = cmark_node_parent(node) {
                var paragraph: OpaquePointer? = parent
                while let current = paragraph, cmark_node_get_type(current) != CMARK_NODE_PARAGRAPH {
                    if isCancelled() { break }
                    paragraph = cmark_node_parent(current)
                }
                guard let paragraph, let prefix = plainMultilinePrefixes[paragraph] else { continue }
                let line = sourceText.lineRange(for: NSRange(location: nextRange.location, length: 0))
                let structuralEnd = line.location + (prefix as NSString).length
                if structuralEnd < nextRange.location {
                    let leading = NSRange(location: structuralEnd, length: nextRange.location - structuralEnd)
                    if leading.location >= range.location, NSMaxRange(leading) <= NSMaxRange(range),
                       (leading.location..<NSMaxRange(leading)).allSatisfy({ sourceText.character(at: $0) == 32 || sourceText.character(at: $0) == 9 }) {
                        textReplacements.append(.init(range: leading, text: "", kind: .spaces))
                    }
                }
            }
        }
        if !(syntax.preserveEditingWhitespace ?? false) {
            for node in paragraphNodes.keys {
                if isCancelled() { break }
                guard let parent = cmark_node_parent(node), source.referencePrefix(node) == nil,
                      let line = source.wholeLines(node), NSMaxRange(line) <= sourceText.length else { continue }
                let topLevel = cmark_node_get_type(parent) == CMARK_NODE_DOCUMENT
                var end = NSMaxRange(line)
                if end > line.location, sourceText.character(at: end - 1) == 10 { end -= 1 }
                if end > line.location, sourceText.character(at: end - 1) == 13 { end -= 1 }
                var first = line.location, last = end
                while first < end && sourceText.character(at: first) == 32 { first += 1 }
                while last > first && (sourceText.character(at: last - 1) == 32 || sourceText.character(at: last - 1) == 9) { last -= 1 }
                if !topLevel {
                    guard let firstNode = cmark_node_first_child(node), let range = confirmedInlineRange(firstNode) else { continue }
                    if cmark_node_get_type_string(parent).map({ String(cString: $0) }) == "tasklist" {
                        guard containerPrefixes(node, source: source, text: sourceText, isCancelled: isCancelled) != nil else { continue }
                    } else {
                        guard let prefix = fencePrefixes(node, source: source, text: sourceText, position: range.location,
                            allowEarlierItem: false, itemStartColumn: itemStartColumn), prefix.nested else { continue }
                    }
                    first = range.location
                }
                var position = line.location, prefixHasTab = false, invalidTab = false
                while position < last {
                    if isCancelled() { invalidTab = true; break }
                    if sourceText.character(at: position) == 9 {
                        if position < first { prefixHasTab = true } else { invalidTab = true; break }
                    }
                    position += 1
                }
                if invalidTab || (topLevel && prefixHasTab) { continue }
                if prefixHasTab {
                    guard cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
                          let pointer = cmark_node_get_string_content(node) else { continue }
                    var retained = String(cString: pointer)
                    if retained.hasSuffix("\n") { retained.removeLast() }
                    guard retained.utf8.elementsEqual(sourceText.substring(with: NSRange(location: first, length: end - first)).utf8) else { continue }
                }
                guard (!topLevel || first - line.location <= 3), last > first,
                      !(last < end && sourceText.character(at: last - 1) == 92) else { continue }
                var child = cmark_node_first_child(node), cursor = first, proven = true
                while let current = child {
                    if isCancelled() { proven = false; break }
                    var pending = [current]
                    while let item = pending.popLast() {
                        if isCancelled() { proven = false; break }
                        let type = cmark_node_get_type(item)
                        if type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_IMAGE || type == CMARK_NODE_CUSTOM_INLINE || type == CMARK_NODE_LINEBREAK { proven = false; break }
                        var nested = cmark_node_first_child(item)
                        while let next = nested {
                            if isCancelled() { proven = false; break }
                            pending.append(next); nested = cmark_node_next(next)
                        }
                    }
                    if !proven { break }
                    let range = cmark_node_get_type(current) == CMARK_NODE_SOFTBREAK ? confirmedSoftBreak(current) : confirmedInlineRange(current)
                    guard let range, range.location == cursor, NSMaxRange(range) <= last else { proven = false; break }
                    cursor = NSMaxRange(range)
                    child = cmark_node_next(current)
                }
                guard proven, cursor == last else { continue }
                if !topLevel, cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
                   let container = cmark_node_parent(parent) {
                    var markerEnd: Int?
                    if cmark_node_get_type(parent) == CMARK_NODE_BLOCK_QUOTE {
                        var ancestor: OpaquePointer? = container
                        while let current = ancestor, cmark_node_get_type(current) == CMARK_NODE_BLOCK_QUOTE {
                            if isCancelled() { break }
                            ancestor = cmark_node_parent(current)
                        }
                        if let ancestor, cmark_node_get_type(ancestor) == CMARK_NODE_DOCUMENT {
                            var position = line.location
                            while position < first {
                                if isCancelled() { break }
                                if sourceText.character(at: position) == 62 { markerEnd = position + 1 }
                                position += 1
                            }
                        }
                    } else if cmark_node_get_type_string(parent).map({ String(cString: $0) }) == "tasklist",
                              cmark_node_get_type(container) == CMARK_NODE_LIST,
                              let start = source.firstPosition(parent), start >= line.location, start < first,
                              let checkbox = source.taskCheckbox(parent),
                              (checkbox.state != 32) == cmark_gfm_extensions_get_tasklist_item_checked(parent) {
                        var ancestor: OpaquePointer? = container, valid = true
                        while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
                            if isCancelled() { valid = false; break }
                            let type = cmark_node_get_type(current)
                            if type != CMARK_NODE_BLOCK_QUOTE && type != CMARK_NODE_LIST && type != CMARK_NODE_ITEM { valid = false; break }
                            if type == CMARK_NODE_ITEM &&
                                (cmark_node_get_type_string(current).map({ String(cString: $0) == "tasklist" }) == true || source.taskCheckbox(current) != nil) { valid = false; break }
                            ancestor = cmark_node_parent(current)
                        }
                        if valid && ancestor != nil { markerEnd = NSMaxRange(checkbox.markerRange) }
                    } else if cmark_node_get_type(parent) == CMARK_NODE_ITEM,
                              cmark_node_get_type(container) == CMARK_NODE_LIST,
                              let start = source.firstPosition(parent), start >= line.location, start < first,
                              source.taskCheckbox(parent) == nil, source.quotedTaskCheckbox(parent) == nil,
                              cmark_node_get_type_string(parent).map({ String(cString: $0) == "item" }) == true {
                        var ancestor: OpaquePointer? = container, valid = true
                        while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
                            if isCancelled() { valid = false; break }
                            let type = cmark_node_get_type(current)
                            if type != CMARK_NODE_BLOCK_QUOTE && type != CMARK_NODE_LIST && type != CMARK_NODE_ITEM { valid = false; break }
                            if type == CMARK_NODE_ITEM &&
                                (cmark_node_get_type_string(current).map({ String(cString: $0) == "tasklist" }) == true || source.taskCheckbox(current) != nil) { valid = false; break }
                            ancestor = cmark_node_parent(current)
                        }
                        if ancestor == nil { valid = false }
                        var position = start
                        if [42, 43, 45].contains(Int(sourceText.character(at: position))) { position += 1 }
                        else {
                            while position < first && (48...57).contains(sourceText.character(at: position)) { position += 1 }
                            if position > start && position - start <= 9 && position < first &&
                                [41, 46].contains(Int(sourceText.character(at: position))) { position += 1 }
                            else { position = start }
                        }
                        if valid && position > start { markerEnd = position }
                    }
                    if let markerEnd, markerEnd < first,
                       (!prefixHasTab || (line.location..<markerEnd).allSatisfy({ sourceText.character(at: $0) != 9 })),
                       sourceText.character(at: markerEnd) == 32,
                       (markerEnd..<first).allSatisfy({ sourceText.character(at: $0) == 32 || (prefixHasTab && sourceText.character(at: $0) == 9) }),
                       first - markerEnd > 1 {
                        var column = 0, cursor = line.location
                        while cursor < first {
                            let unit = sourceText.character(at: cursor)
                            column = unit == 9 ? (column / 4 + 1) * 4 : column + 1
                            cursor += 1
                        }
                        var markerColumn = 0
                        for index in line.location..<markerEnd {
                            let unit = sourceText.character(at: index)
                            markerColumn = unit == 9 ? (markerColumn / 4 + 1) * 4 : markerColumn + 1
                        }
                        if (1...4).contains(column - markerColumn) {
                            textReplacements.append(.init(range: NSRange(location: markerEnd + 1, length: first - markerEnd - 1), text: "", kind: .spaces))
                        }
                    }
                }
                if topLevel && first > line.location {
                    textReplacements.append(.init(range: NSRange(location: line.location, length: first - line.location), text: "", kind: .spaces))
                }
                if last < end {
                    textReplacements.append(.init(range: NSRange(location: last, length: end - last), text: "", kind: .spaces))
                }
            }
        }
        if includeUppercaseRuns && includeEmojiCandidates && !isCancelled(), uppercaseHeadingNodes.count == headings.count {
            for index in headings.indices {
                if isCancelled() { break }
                let heading = headings[index]
                let runs = uppercaseHeadingRuns(uppercaseHeadingNodes[index], range: heading.range, title: heading.title,
                    source: source, text: sourceText, mathInline: inlineByNode, confirmedHTML: confirmedInlineHTML,
                    htmlImages: confirmedHTMLImages, preserveSoftBreaks: syntax.preserveEditingSoftBreaks,
                    emojiByNode: emojiByNode, isCancelled: isCancelled)
                headings[index] = MarkdownHeading(level: heading.level, title: heading.title, range: heading.range, emoji: heading.emoji,
                    displayTitle: heading.displayTitle, number: heading.number, plainTextRange: heading.plainTextRange, uppercaseRuns: runs)
            }
        }
        var quoteDepths: [OpaquePointer: Int] = [:]
        for (node, index) in paragraphNodes {
            if isCancelled() { break }
            guard let next = cmark_node_next(node), let nextIndex = paragraphNodes[next] else { continue }
            let start = NSMaxRange(paragraphs[index].range), end = paragraphs[nextIndex].range.location
            guard start < end, end <= sourceText.length else { continue }
            var quoteDepth = 0, parent = cmark_node_parent(node), ancestors: [OpaquePointer] = []
            while let ancestor = parent {
                if isCancelled() { break }
                if let known = quoteDepths[ancestor] { quoteDepth = known; break }
                ancestors.append(ancestor)
                parent = cmark_node_parent(ancestor)
            }
            for ancestor in ancestors.reversed() {
                if let name = cmark_node_get_type_string(ancestor), String(cString: name) == "block_quote" { quoteDepth += 1 }
                quoteDepths[ancestor] = quoteDepth
            }
            var position = start, blank = !isCancelled(), markers = 0
            while position < end {
                if isCancelled() { blank = false; break }
                let character = sourceText.character(at: position)
                if character == 62 { markers += 1 }
                else if character == 10 || character == 13 {
                    if markers != quoteDepth { blank = false; break }
                    markers = 0
                    if character == 13 && position + 1 < end && sourceText.character(at: position + 1) == 10 { position += 1 }
                } else if character != 32 && character != 9 { blank = false; break }
                position += 1
            }
            if blank && markers == 0 { paragraphs[index].separatorAfter = NSRange(location: start, length: end - start) }
        }
        fenceBlockedRanges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in fenceBlockedRanges {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
            } else { merged.append(range) }
        }
        htmlRanges.sort { $0.location < $1.location }
        var rawHTMLRanges: [NSRange] = []
        var rawHTMLContext = MarkdownImageUploadService.HTMLContext()
        var rawStart: Int?, previousEnd = 0
        for range in htmlRanges {
            if isCancelled() || range.location < previousEnd { htmlRangesAvailable = false; break }
            let wasRaw = rawHTMLContext.inRawContext
            _ = rawHTMLContext.consume(source: (htmlContextText as NSString?) ?? sourceText, range: range, isCancelled: isCancelled)
            if !wasRaw && rawHTMLContext.inRawContext { rawStart = range.location }
            if wasRaw && !rawHTMLContext.inRawContext, let start = rawStart {
                rawHTMLRanges.append(NSRange(location: start, length: NSMaxRange(range) - start))
                rawStart = nil
            }
            previousEnd = NSMaxRange(range)
        }
        if let start = rawStart { rawHTMLRanges.append(NSRange(location: start, length: sourceText.length - start)) }
        let readableText = includeReadableText ? MarkdownReadableTextParser.build(root: root, source: source, text: sourceText, mathExtension: mathExtension, inlineMath: Set(mathInline.map(\.node)), isCancelled: isCancelled) : nil
        var namedAnchors = htmlRangesAvailable ? confirmedNamedAnchors(in: (htmlContextText as NSString?) ?? sourceText, ranges: htmlRanges, isCancelled: isCancelled) : []
        var safeText: [MarkdownTextReplacement] = []
        if !textReplacements.isEmpty {
            let blockedText = (images.map(\.range) + audioBlocks.map(\.range) + iframeBlocks.map(\.range) + detailsBlocks.map(\.range) + htmlBlocks.map(\.range) + ruby.map(\.range) + diagrams.map(\.range)
                + formulas.map(\.range) + inlineFormulas.map(\.range) + emojiCandidates.map(\.range) + tables.map(\.range) + tableOfContents).sorted { $0.location < $1.location }
            var blockedEnd = 0
            var blockedEnds: [Int] = []
            for range in blockedText {
                if isCancelled() { return MarkdownPresentation(spans: []) }
                blockedEnd = max(blockedEnd, NSMaxRange(range))
                blockedEnds.append(blockedEnd)
            }
            for replacement in textReplacements {
                if isCancelled() { return MarkdownPresentation(spans: []) }
                var low = 0, high = blockedEnds.count
                while low < high {
                    let middle = (low + high) / 2
                    if blockedEnds[middle] <= replacement.range.location { low = middle + 1 } else { high = middle }
                }
                if low == blockedText.count || blockedText[low].location >= NSMaxRange(replacement.range) { safeText.append(replacement) }
            }
            safeText.sort { $0.range.location < $1.range.location }
        }
        if !blockedHTML.isEmpty {
            func blocked(_ range: NSRange) -> Bool {
                if isCancelled() { return true }
                var low = 0, high = blockedHTML.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(blockedHTML[middle]) <= range.location { low = middle + 1 } else { high = middle }
                }
                return low < blockedHTML.count && blockedHTML[low].location < NSMaxRange(range)
            }
            spans.removeAll { blocked($0.range) }
            links.removeAll { blocked($0.range) }
            namedAnchors.removeAll { blocked($0.range) }
            images.removeAll { blocked($0.range) }
            audioBlocks.removeAll { blocked($0.range) }
            iframeBlocks.removeAll { blocked($0.range) }
            detailsBlocks.removeAll { blocked($0.range) }
            htmlBlocks.removeAll { blocked($0.range) }
            pageBreaks.removeAll { blocked($0) }
            ruby.removeAll { blocked($0.range) }
            diagrams.removeAll { blocked($0.range) }
            formulas.removeAll { blocked($0.range) }
            inlineFormulas.removeAll { blocked($0.range) }
            emojiCandidates.removeAll { blocked($0.range) }
            emojiCompletionRanges.removeAll { blocked($0) }
            smartTextRanges.removeAll { blocked($0) }
            safeText.removeAll { blocked($0.range) }
            paragraphs.removeAll { blocked($0.range) }
            completedTaskRanges.removeAll { blocked($0) }
            taskCheckboxes.removeAll { blocked($0.markerRange) }
            listMarkers.removeAll { blocked($0.line) }
            footnotes.removeAll { blocked($0.referenceRange) || blocked($0.definitionRange) }
            tableOfContents.removeAll { blocked($0) }
            codeBlocks.removeAll { blocked($0.range) }
            headings = headings.map { heading in
                guard blocked(heading.range) else { return heading }
                return MarkdownHeading(level: heading.level, title: heading.title, range: heading.range, emoji: heading.emoji,
                    displayTitle: heading.displayTitle, number: nil, plainTextRange: nil, uppercaseRuns: nil)
            }
            tables = tables.map { table in
                guard blocked(table.range) else { return table }
                let rows = table.rows.map { row in
                    MarkdownTableRow(range: row.range, cells: row.cells.map { cell in
                        guard blocked(cell.range), cell.range.location >= 0, NSMaxRange(cell.range) <= sourceText.length else { return cell }
                        return MarkdownTableCell(range: cell.range, column: cell.column, virtualSeparators: cell.virtualSeparators,
                            displayText: sourceText.substring(with: cell.range), displayRuns: [])
                    })
                }
                return MarkdownTable(range: table.range, delimiterRange: table.delimiterRange, alignments: table.alignments,
                    rows: rows, containerPrefix: table.containerPrefix, quoteDepth: table.quoteDepth,
                    nestedList: table.nestedList, referenceLabels: table.referenceLabels)
            }
            if isCancelled() { return MarkdownPresentation(spans: []) }
        }
        return MarkdownPresentation(spans: spans, headings: headings, namedAnchors: namedAnchors, images: images, audioBlocks: audioBlocks, iframeBlocks: iframeBlocks, detailsBlocks: detailsBlocks, htmlBlocks: htmlBlocks, pageBreaks: pageBreaks, ruby: ruby, links: links, diagrams: diagrams, formulas: formulas, inlineFormulas: inlineFormulas, emojiCandidates: emojiCandidates, emojiCandidatesIncluded: includeEmojiCandidates, emojiCompletionRanges: emojiCompletionRanges.sorted { $0.location < $1.location }, smartTextRanges: smartTextRanges.sorted { $0.location < $1.location }, smartRawHTMLRanges: htmlRangesAvailable ? rawHTMLRanges : nil, textReplacements: safeText, paragraphs: paragraphs.sorted { $0.range.location < $1.range.location }, completedTaskRanges: completedTaskRanges.sorted { $0.location < $1.location }, taskCheckboxes: taskCheckboxes, listMarkers: listMarkers.sorted { $0.range.location < $1.range.location }, looseIndents: MarkdownMathExtension.looseIndents(in: mathExtension), footnotes: footnotes, tableOfContents: tableOfContents, tables: tables, codeBlocks: codeBlocks, fenceContainerLines: fenceContainerLines.sorted { $0.line.location < $1.line.location }, fenceBlockedRanges: merged, fenceBlockedEOF: fenceBlockedEOF, fenceContextAvailable: fenceContextAvailable, readableText: readableText)
        } ?? MarkdownPresentation(spans: [])
    }

    static func confirmedNamedAnchors(in source: NSString, ranges: [NSRange], isCancelled: () -> Bool = { false }) -> [MarkdownNamedAnchor] {
        var context = MarkdownImageUploadService.HTMLContext()
        var suppressed: [String] = [], anchors: [MarkdownNamedAnchor] = []
        var previousEnd = 0
        for range in ranges {
            guard !isCancelled(), range.location >= previousEnd else { return [] }
            _ = context.consume(source: source, range: range, isCancelled: isCancelled) { tag, name, closing in
                if ["template", "pre", "code"].contains(name) {
                    if closing {
                        if suppressed.last == name { suppressed.removeLast() }
                    } else { suppressed.append(name) }
                } else if suppressed.isEmpty && name == "a" && !closing {
                    for value in MarkdownHTMLMediaService.anchorNames(inOpeningTag: source.substring(with: tag)) {
                        anchors.append(MarkdownNamedAnchor(name: value, range: tag))
                    }
                }
            }
            previousEnd = NSMaxRange(range)
        }
        return isCancelled() ? [] : anchors
    }

    static func htmlSourceMatches(_ node: OpaquePointer, range: NSRange, text: NSString,
                                  isCancelled: () -> Bool = { false }) -> Bool {
        guard let literal = cmark_node_get_literal(node), range.location >= 0,
              NSMaxRange(range) <= text.length else { return false }
        let value = String(cString: literal) as NSString
        var sourceIndex = range.location, literalIndex = 0
        while sourceIndex < NSMaxRange(range) && literalIndex < value.length {
            if isCancelled() { return false }
            var unit = text.character(at: sourceIndex)
            sourceIndex += 1
            if unit == 13 {
                if sourceIndex < NSMaxRange(range), text.character(at: sourceIndex) == 10 { sourceIndex += 1 }
                unit = 10
            }
            guard unit == value.character(at: literalIndex) else { return false }
            literalIndex += 1
        }
        guard sourceIndex == NSMaxRange(range) else { return false }
        if literalIndex == value.length { return !isCancelled() }
        guard cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK,
              literalIndex + 1 == value.length, value.character(at: literalIndex) == 10 else { return false }
        return !isCancelled() && (sourceIndex == text.length || [10, 13].contains(Int(text.character(at: sourceIndex))))
    }

    struct Source {
        let units: [UInt16]
        let bytes: [UInt8]
        let corrections: [(end: Int, delta: Int)]
        let lineStarts: [Int]
        let lineEnds: [Int]
        let lineHasTab: [Bool]
        private var recoveredRanges: [OpaquePointer: NSRange] = [:]
        private let looseHeadings: [OpaquePointer: Int]
        private let looseListRanges: [OpaquePointer: NSRange]
        private var paragraphLineShifts: [OpaquePointer: Int] = [:]
        private var paragraphColumnShifts: [OpaquePointer: [Int: Int]] = [:]
        private var paragraphRetainedStarts: [OpaquePointer: [Int: Int]] = [:]
        private var referencePrefixes: [OpaquePointer: NSRange] = [:]
        private var possibleReferenceNodes: Set<OpaquePointer> = []

        init(_ text: String, root: OpaquePointer? = nil, textOrigins: [MarkdownTextSourceCapture.Origin] = [], looseHeadings: [OpaquePointer: Int] = [:], looseListRanges: [OpaquePointer: NSRange] = [:], interruptIndexing: Bool = false, isCancelled: () -> Bool = { false }) {
            self.looseHeadings = looseHeadings
            self.looseListRanges = looseListRanges
            units = Array(text.utf16)
            bytes = Array(text.utf8)
            var corrections: [(end: Int, delta: Int)] = []
            var starts = [0], ends: [Int] = [], tabs: [Bool] = []
            var byte = 0, delta = 0
            var untilCancellationCheck = 0
            var hasTab = false, previousCR = false
            for scalar in text.unicodeScalars {
                if interruptIndexing {
                    if untilCancellationCheck == 0 {
                        if isCancelled() { break }
                        untilCancellationCheck = 1024
                    }
                    untilCancellationCheck -= 1
                }
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
            if let root { recoverReferenceParagraphs(root, text: text as NSString, isCancelled: isCancelled) }
            recoveredRanges.merge(MarkdownTextSourceCapture.ranges(textOrigins, source: self, isCancelled: isCancelled)) { _, new in new }
            recoveredRanges.merge(looseListRanges) { _, new in new }
            for (node, count) in looseHeadings {
                if isCancelled() { break }
                guard let content = range(node), content.location >= count, count > 0,
                      units[(content.location - count)..<content.location].allSatisfy({ $0 == 35 }) else { continue }
                let recovered = NSRange(location: content.location - count, length: content.length + count)
                recoveredRanges[node] = recovered
            }
        }

        // cmark removes leading reference definitions but keeps the old paragraph
        // line number. Recover only a complete, position-verified retained buffer.
        private mutating func recoverReferenceParagraphs(_ root: OpaquePointer, text: NSString, isCancelled: () -> Bool) {
            var nodes = [root]
            while let node = nodes.popLast() {
                if isCancelled() { return }
                var descendant = cmark_node_first_child(node)
                while let current = descendant {
                    if isCancelled() { return }
                    nodes.append(current); descendant = cmark_node_next(current)
                }
                guard cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH else { continue }
                let column = Int(cmark_node_get_start_column(node))
                let first = Int(cmark_node_get_start_line(node)) - 1
                let last = Int(cmark_node_get_end_line(node)) - 1
                if first >= 0, last > first, first < lineStarts.count, column > 0,
                   lineStarts[first] + column - 1 < lineEnds[first], bytes[lineStarts[first] + column - 1] == 91 {
                    var pending = [node]
                    while let current = pending.popLast() {
                        if isCancelled() { return }
                        possibleReferenceNodes.insert(current)
                        var child = cmark_node_first_child(current)
                        while let next = child {
                            if isCancelled() { return }
                            pending.append(next)
                            child = cmark_node_next(next)
                        }
                    }
                }
                guard let parent = cmark_node_parent(node), let pointer = cmark_node_get_string_content(node) else { continue }
                guard first >= 0, last > first, last < lineStarts.count, column > 0,
                      Int(cmark_node_get_end_column(node)) == lineEnds[last] - lineStarts[last],
                      lineStarts[first] + column - 1 < lineEnds[first],
                      bytes[lineStarts[first] + column - 1] == 91 else { continue }
                var hasTab = false
                for line in first...last {
                    if isCancelled() { return }
                    if lineHasTab[line] { hasTab = true; break }
                }
                guard !lineHasTab[first] else { continue }
                var retained = Array(String(cString: pointer).utf8)
                if retained.last == 10 { retained.removeLast() }
                guard !retained.isEmpty else { continue }
                let actualLine: Int
                let prefixByteStart: Int
                var columnShifts: [Int: Int] = [:]
                var retainedStarts: [Int: Int] = [:]
                if parent == root && !hasTab {
                    guard column == 1 else { continue }
                    var raw = lineEnds[last], index = retained.count, matches = true
                    while index > 0 && raw > lineStarts[first] {
                        if isCancelled() { return }
                        raw -= 1; index -= 1
                        if retained[index] == 10 && bytes[raw] == 13 { continue }
                        if retained[index] == 10 && bytes[raw] == 10 && raw > lineStarts[first] && bytes[raw - 1] == 13 { raw -= 1; continue }
                        if bytes[raw] != retained[index] { matches = false; break }
                    }
                    var low = first, high = last + 1
                    while low < high {
                        let middle = (low + high) / 2
                        if lineStarts[middle] < raw { low = middle + 1 } else { high = middle }
                    }
                    guard matches, index == 0, raw > lineStarts[first], low <= last, lineStarts[low] == raw else { continue }
                    actualLine = low
                    prefixByteStart = lineStarts[first]
                } else {
                    guard parent != root || column == 1 else { continue }
                    var ancestor: OpaquePointer? = parent, supported = true, quoteDepth = 0
                    while let current = ancestor, current != root {
                        let kind = cmark_node_get_type(current)
                        if kind == CMARK_NODE_BLOCK_QUOTE { quoteDepth += 1 }
                        if kind != CMARK_NODE_BLOCK_QUOTE && kind != CMARK_NODE_LIST && kind != CMARK_NODE_ITEM {
                            supported = false; break
                        }
                        ancestor = cmark_node_parent(current)
                    }
                    guard supported, ancestor == root else { continue }
                    var lines: [Range<Int>] = [], start = 0
                    for index in retained.indices {
                        if isCancelled() { return }
                        if retained[index] == 10 { lines.append(start..<index); start = index + 1 }
                    }
                    lines.append(start..<retained.count)
                    if hasTab {
                        var valid = true
                        for line in lines {
                            if isCancelled() { return }
                            if line.isEmpty || retained[line.lowerBound] == 32 || retained[line.lowerBound] == 9 { valid = false; break }
                            if !valid { break }
                        }
                        guard valid else { continue }
                    }
                    let candidate = last - lines.count + 1
                    guard candidate > first else { continue }
                    var matches = true
                    for (offset, line) in lines.enumerated() {
                        if isCancelled() { return }
                        let physical = candidate + offset
                        let startByte = lineEnds[physical] - line.count
                        guard startByte >= lineStarts[physical] else { matches = false; break }
                        retainedStarts[physical] = startByte
                        if hasTab {
                            var quotes = 0
                            for index in lineStarts[physical]..<startByte {
                                if isCancelled() { return }
                                let byte = bytes[index]
                                if byte == 62 { quotes += 1 }
                                else if byte != 32 && byte != 9 { matches = false; break }
                            }
                            if !matches || quotes != quoteDepth { matches = false; break }
                        }
                        columnShifts[physical] = startByte - lineStarts[physical] - (column - 1)
                        for index in line {
                            if isCancelled() { return }
                            if bytes[startByte + index - line.lowerBound] != retained[index] { matches = false; break }
                        }
                        if !matches { break }
                    }
                    guard matches else { continue }
                    actualLine = candidate
                    prefixByteStart = lineStarts[first] + column - 1
                }
                var ancestorRanges: [OpaquePointer: NSRange] = [:]
                if hasTab && parent != root {
                    var ancestor: OpaquePointer? = parent, valid = true
                    while let current = ancestor, current != root {
                        if isCancelled() { return }
                        let startLine = Int(cmark_node_get_start_line(current)) - 1
                        let endLine = Int(cmark_node_get_end_line(current)) - 1
                        let startColumn = Int(cmark_node_get_start_column(current))
                        let endColumn = Int(cmark_node_get_end_column(current))
                        guard startLine >= 0, startLine <= first, endLine == last, startColumn > 0,
                              !lineHasTab[startLine], endColumn == lineEnds[last] - lineStarts[last],
                              lineStarts[startLine] + startColumn - 1 <= lineEnds[startLine],
                              let lower = utf16Offset(at: lineStarts[startLine] + startColumn - 1),
                              let upper = utf16Offset(at: lineEnds[last]), upper >= lower else { valid = false; break }
                        ancestorRanges[current] = NSRange(location: lower, length: upper - lower)
                        ancestor = cmark_node_parent(current)
                    }
                    guard valid, ancestor == root else { continue }
                }
                let shift = actualLine - first
                guard let prefixStart = utf16Offset(at: prefixByteStart), let prefixEnd = utf16Offset(at: lineStarts[actualLine]) else { continue }
                referencePrefixes[node] = NSRange(location: prefixStart, length: prefixEnd - prefixStart)
                recoveredRanges.merge(ancestorRanges) { existing, _ in existing }
                if hasTab, let lower = utf16Offset(at: lineStarts[first] + column - 1),
                   let upper = utf16Offset(at: lineEnds[last]), upper >= lower {
                    recoveredRanges[node] = NSRange(location: lower, length: upper - lower)
                }
                var stack: [OpaquePointer] = [], child = cmark_node_first_child(node)
                while let current = child {
                    if isCancelled() { return }
                    stack.append(current); child = cmark_node_next(current)
                }
                paragraphLineShifts[node] = shift
                paragraphColumnShifts[node] = columnShifts
                paragraphRetainedStarts[node] = retainedStarts
                while let current = stack.popLast() {
                    if isCancelled() { return }
                    paragraphLineShifts[current] = shift
                    paragraphColumnShifts[current] = columnShifts
                    paragraphRetainedStarts[current] = retainedStarts
                    let startLine = Int(cmark_node_get_start_line(current)) - 1 + shift
                    let endLine = Int(cmark_node_get_end_line(current)) - 1 + shift
                    let startColumn = Int(cmark_node_get_start_column(current))
                    let endColumn = Int(cmark_node_get_end_column(current))
                    if startLine >= actualLine, endLine >= startLine, endLine <= last,
                       startColumn > 0, endColumn > 0 {
                        let start = lineStarts[startLine] + startColumn - 1 + (columnShifts[startLine] ?? 0)
                        let end = lineStarts[endLine] + endColumn + (columnShifts[endLine] ?? 0)
                        if start >= (retainedStarts[startLine] ?? lineStarts[startLine]), start <= lineEnds[startLine],
                           end >= (retainedStarts[endLine] ?? lineStarts[endLine]), end <= lineEnds[endLine], end >= start,
                           let lower = utf16Offset(at: start), let upper = utf16Offset(at: end) {
                            let range = NSRange(location: lower, length: upper - lower)
                            if hasTab && cmark_node_get_type(current) == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(current) {
                                let spelling = text.substring(with: range) as NSString
                                guard MarkdownInlineTextProjection.pieces(spelling: spelling, literal: String(cString: literal), sourceOffset: lower, isCancelled: isCancelled) != nil else { continue }
                            }
                            if hasTab && cmark_node_get_type(current) == CMARK_NODE_CODE, let literal = cmark_node_get_literal(current),
                               !text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) { continue }
                            recoveredRanges[current] = range
                        }
                    }
                    var nested = cmark_node_first_child(current)
                    while let item = nested {
                        if isCancelled() { return }
                        stack.append(item); nested = cmark_node_next(item)
                    }
                }
            }
        }

        func referencePrefix(_ node: OpaquePointer) -> NSRange? { referencePrefixes[node] }

        // cmark reports virtual container columns on lazy continuation lines.
        // Only expose leaves whose full retained paragraph buffer matches source.
        func lazyParagraphInlineRanges(_ paragraph: OpaquePointer, text: NSString, plainEditing: Bool = false,
                                       inlineMath: [OpaquePointer: MarkdownMathExtension.Inline] = [:], isCancelled: @escaping () -> Bool = { false }) -> [OpaquePointer: NSRange]? {
            guard cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                  let parent = cmark_node_parent(paragraph), plainEditing || cmark_node_get_type(parent) != CMARK_NODE_DOCUMENT,
                  cmark_node_get_start_line(paragraph) < cmark_node_get_end_line(paragraph),
                  referencePrefix(paragraph) == nil, let position = firstPosition(paragraph),
                  let pointer = cmark_node_get_string_content(paragraph) else { return nil }
            let first = Int(cmark_node_get_start_line(paragraph)) - 1, last = Int(cmark_node_get_end_line(paragraph)) - 1
            let column = Int(cmark_node_get_start_column(paragraph))
            guard first >= 0, last > first, last < lineStarts.count, column > 0,
                  let end = utf16Offset(at: lineEnds[last]) else { return nil }
            let hasTabs = lineHasTab[first...last].contains(true)
            if hasTabs && !plainEditing { return nil }
            let whole: NSRange
            let prefix: (source: String, continuation: String)
            if plainEditing {
                guard end >= position else { return nil }
                whole = NSRange(location: position, length: end - position)
                if cmark_node_get_type(parent) == CMARK_NODE_DOCUMENT { prefix = ("", "") }
                else {
                    guard let prefixes = MarkdownPresentationParser.containerPrefixes(paragraph, source: self, text: text, isCancelled: isCancelled),
                          !prefixes.source.contains("\t"), !prefixes.continuation.contains("\t") else { return nil }
                    prefix = prefixes
                }
                var child = cmark_node_first_child(paragraph)
                while let node = child {
                    if isCancelled() { return nil }
                    let type = cmark_node_get_type(node)
                    if hasTabs, let name = cmark_node_get_type_string(node),
                       !["text", "softbreak", "strong", "emph", "code", "link", "strikethrough", "html_inline"].contains(String(cString: name)) { return nil }
                    if type != CMARK_NODE_SOFTBREAK {
                        var pending = [node]
                        while let item = pending.popLast() {
                            if isCancelled() { return nil }
                            guard let name = cmark_node_get_type_string(item),
                                  ["text", "strong", "emph", "strikethrough", "link", "code", "image", "custom_inline", "html_inline", "softbreak"].contains(String(cString: name)) else { return nil }
                            let itemName = String(cString: name)
                            if hasTabs && !["text", "softbreak", "strong", "emph", "code", "link", "strikethrough", "html_inline"].contains(itemName) { return nil }
                            if hasTabs && itemName != "softbreak" && cmark_node_get_start_line(item) != cmark_node_get_end_line(item) { return nil }
                            if itemName == "custom_inline" && inlineMath[item] == nil { return nil }
                            if (itemName == "text" || itemName == "code" || itemName == "image" || itemName == "html_inline") && cmark_node_get_start_line(item) != cmark_node_get_end_line(item) { return nil }
                            if itemName == "image" {
                                guard let child = cmark_node_first_child(item), cmark_node_next(child) == nil,
                                      cmark_node_get_type(child) == CMARK_NODE_TEXT else { return nil }
                            }
                            var nested = cmark_node_first_child(item)
                            while let next = nested { if isCancelled() { return nil }; pending.append(next); nested = cmark_node_next(next) }
                        }
                    }
                    child = cmark_node_next(node)
                }
            } else {
                guard let range = editingTextRange(paragraph), position == range.location, end == NSMaxRange(range),
                      let prefixes = MarkdownPresentationParser.containerPrefixes(paragraph, source: self, text: text, isCancelled: isCancelled),
                      !prefixes.source.contains("\t"), !prefixes.continuation.contains("\t") else { return nil }
                whole = range; prefix = prefixes
            }
            var retained = Array(String(cString: pointer).utf8)
            if retained.last == 10 { retained.removeLast() }
            var lines: [Range<Int>] = [], start = 0
            for index in retained.indices {
                if isCancelled() { return nil }
                if retained[index] == 10 { lines.append(start..<index); start = index + 1 }
            }
            lines.append(start..<retained.count)
            guard lines.count == last - first + 1 else { return nil }
            var shifts: [Int: Int] = [:], starts: [Int: Int] = [:]
            let continuation = Array(prefix.continuation.utf8)
            for (offset, line) in lines.enumerated() {
                if isCancelled() { return nil }
                let physical = first + offset, position = lineEnds[physical] - line.count
                guard !line.isEmpty, position >= lineStarts[physical],
                      Array(bytes[position..<lineEnds[physical]]) == Array(retained[line]) else { return nil }
                if offset == 0 {
                    guard utf16Offset(at: position) == whole.location else { return nil }
                    if hasTabs && bytes[lineStarts[physical]..<position].contains(9) { return nil }
                } else if plainEditing {
                    let physicalPrefix = bytes[lineStarts[physical]..<position]
                    guard physicalPrefix.starts(with: continuation) else { return nil }
                    let extra = physicalPrefix.dropFirst(continuation.count)
                    if extra.contains(9) {
                        guard !retained[line].isEmpty,
                              retained[line.lowerBound] != 32, retained[line.lowerBound] != 9,
                              extra.allSatisfy({ $0 == 32 || $0 == 9 }) else { return nil }
                    } else if !extra.allSatisfy({ $0 == 32 }) { return nil }
                } else if position != lineStarts[physical] {
                    guard Array(bytes[lineStarts[physical]..<position]) == continuation else { return nil }
                }
                guard utf16Offset(at: position) != nil else { return nil }
                starts[physical] = position
                shifts[physical] = position - lineStarts[physical] - (column - 1)
            }
            var tabPositions: [Int: [Int: Set<Int>]] = [:]
            if hasTabs {
                for line in first...last where lineHasTab[line] {
                    guard let start = starts[line] else { return nil }
                    var positions: [Int: Set<Int>] = [:], offset = start
                    var byteColumn = column - 1, scalarColumn = column - 1
                    var visualColumn = column - 1, physicalColumn = 0
                    for unit in bytes[lineStarts[line]..<start] {
                        if isCancelled() { return nil }
                        physicalColumn = unit == 9 ? (physicalColumn / 4 + 1) * 4 : physicalColumn + 1
                    }
                    var visualScalar = column - 1, physicalScalar = physicalColumn
                    func record() {
                        for key in [byteColumn, scalarColumn, visualColumn, physicalColumn, visualScalar, physicalScalar] { positions[key, default: []].insert(offset) }
                    }
                    record()
                    while offset < lineEnds[line] {
                        if isCancelled() { return nil }
                        let unit = bytes[offset]
                        let length = unit < 0x80 ? 1 : (unit < 0xe0 ? 2 : (unit < 0xf0 ? 3 : 4))
                        guard length <= lineEnds[line] - offset else { return nil }
                        byteColumn += length; scalarColumn += 1
                        visualColumn = unit == 9 ? (visualColumn / 4 + 1) * 4 : visualColumn + length
                        physicalColumn = unit == 9 ? (physicalColumn / 4 + 1) * 4 : physicalColumn + length
                        visualScalar = unit == 9 ? (visualScalar / 4 + 1) * 4 : visualScalar + 1
                        physicalScalar = unit == 9 ? (physicalScalar / 4 + 1) * 4 : physicalScalar + 1
                        offset += length
                        guard utf16Offset(at: offset) != nil else { return nil }
                        record()
                    }
                    tabPositions[line] = positions
                }
            }
            var pending = [paragraph], result: [OpaquePointer: NSRange] = [:], hasUnsupportedStyle = false, textCount = 0, mappedTextCount = 0, htmlCount = 0, mappedHTMLCount = 0, mathCount = 0
            var tabWrappers: [OpaquePointer] = []
            while let node = pending.popLast() {
                if isCancelled() { return nil }
                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_TEXT { textCount += 1 }
                if type == CMARK_NODE_HTML_INLINE { htmlCount += 1 }
                if plainEditing && possibleReferenceNodes.contains(node) { return nil }
                if plainEditing, let math = inlineMath[node] {
                    mathCount += 1
                    let line = math.line - 1
                    guard line >= first, line <= last, let shift = shifts[line], let retainedStart = starts[line],
                          math.column > 0, math.byteLength > 0 else { return nil }
                    let lower = lineStarts[line] + math.column - 1 + shift, upper = lower + math.byteLength
                    guard lower >= retainedStart, upper >= lower, upper <= lineEnds[line],
                          let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { return nil }
                    let range = NSRange(location: start, length: end - start)
                    guard text.substring(with: range).utf16.elementsEqual(("$" + math.text + "$").utf16) else { return nil }
                    result[node] = range
                } else if (type == CMARK_NODE_TEXT || type == CMARK_NODE_HTML_INLINE), let literal = cmark_node_get_literal(node) {
                    let line = Int(cmark_node_get_start_line(node)) - 1
                    let endLine = Int(cmark_node_get_end_line(node)) - 1
                    let startColumn = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
                    if plainEditing, let positions = tabPositions[line] {
                        guard line == endLine, startColumn > 0, endColumn >= startColumn,
                              let lowerOffsets = positions[startColumn - 1], let upperOffsets = positions[endColumn] else { return nil }
                        var matches: Set<NSRange> = []
                        for lower in lowerOffsets {
                            for upper in upperOffsets {
                                if isCancelled() { return nil }
                                guard lower <= upper, let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { continue }
                                let range = NSRange(location: start, length: end - start)
                                let spelling = text.substring(with: range), value = String(cString: literal)
                                if spelling.utf16.elementsEqual(value.utf16) {
                                    matches.insert(range)
                                } else if type == CMARK_NODE_TEXT, let pieces = MarkdownInlineTextProjection.pieces(spelling: spelling as NSString,
                                    literal: value, sourceOffset: start, isCancelled: isCancelled),
                                    pieces.map(\.text).joined().utf16.elementsEqual(value.utf16) { matches.insert(range) }
                            }
                        }
                        guard matches.count == 1, let match = matches.first else { return nil }
                        result[node] = match
                        if type == CMARK_NODE_TEXT { mappedTextCount += 1 }
                        else {
                            mappedHTMLCount += 1
                            let tag = text.substring(with: match)
                            if MarkdownPresentationParser.isSpanOpening(tag), MarkdownHTMLMediaService.hasStyledSpan(in: tag, isCancelled: isCancelled),
                               MarkdownHTMLMediaService.inlineStyleOpening(tag, isCancelled: isCancelled) == nil { hasUnsupportedStyle = true }
                        }
                        continue
                    }
                    if line == endLine, let shift = shifts[line], let retainedStart = starts[line], startColumn > 0, endColumn >= startColumn {
                        let lower = lineStarts[line] + startColumn - 1 + shift, upper = lineStarts[line] + endColumn + shift
                        if lower >= retainedStart, upper <= lineEnds[line], lower <= upper,
                           let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) {
                            let range = NSRange(location: start, length: end - start)
                            let spelling = text.substring(with: range), value = String(cString: literal)
                            let exact = spelling.utf16.elementsEqual(value.utf16)
                            let projected: Bool
                            if type == CMARK_NODE_TEXT, !exact,
                               let pieces = MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: value,
                                   sourceOffset: start, isCancelled: isCancelled) {
                                projected = pieces.map(\.text).joined().utf16.elementsEqual(value.utf16)
                            } else { projected = false }
                            guard exact || projected else { continue }
                            result[node] = range
                            if type == CMARK_NODE_TEXT { mappedTextCount += 1 }
                            if type == CMARK_NODE_HTML_INLINE { mappedHTMLCount += 1 }
                            if type == CMARK_NODE_HTML_INLINE {
                                let tag = text.substring(with: range)
                                if MarkdownPresentationParser.isSpanOpening(tag), MarkdownHTMLMediaService.hasStyledSpan(in: tag, isCancelled: isCancelled),
                                   MarkdownHTMLMediaService.inlineStyleOpening(tag, isCancelled: isCancelled) == nil { hasUnsupportedStyle = true }
                            }
                        }
                    }
                } else if plainEditing, type != CMARK_NODE_PARAGRAPH && type != CMARK_NODE_SOFTBREAK {
                    let line = Int(cmark_node_get_start_line(node)) - 1
                    if hasTabs && tabPositions[line] != nil {
                        guard Int(cmark_node_get_end_line(node)) - 1 == line,
                              let name = cmark_node_get_type_string(node),
                              ["strong", "emph", "code", "link", "strikethrough"].contains(String(cString: name)) else { return nil }
                        tabWrappers.append(node)
                        var child = cmark_node_first_child(node)
                        while let item = child { if isCancelled() { return nil }; pending.append(item); child = cmark_node_next(item) }
                        continue
                    }
                    let endLine = Int(cmark_node_get_end_line(node)) - 1
                    let startColumn = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
                    guard line >= 0, endLine >= line, endLine < lineStarts.count,
                          let shift = shifts[line], let endShift = shifts[endLine], let retainedStart = starts[line],
                          let retainedEnd = starts[endLine], startColumn > 0, endColumn > 0 else { return nil }
                    let lower = lineStarts[line] + startColumn - 1 + shift, upper = lineStarts[endLine] + endColumn + endShift
                    guard lower >= retainedStart, lower <= lineEnds[line], upper >= retainedEnd,
                          upper <= lineEnds[endLine], lower <= upper,
                          let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { return nil }
                    result[node] = NSRange(location: start, length: end - start)
                }
                var child = cmark_node_first_child(node)
                while let item = child { if isCancelled() { return nil }; pending.append(item); child = cmark_node_next(item) }
            }
            for node in tabWrappers.reversed() {
                if isCancelled() { return nil }
                let line = Int(cmark_node_get_start_line(node)) - 1
                let startColumn = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
                guard startColumn > 0, endColumn >= startColumn, let positions = tabPositions[line],
                      let lowers = positions[startColumn - 1], let uppers = positions[endColumn] else { return nil }
                var matches: Set<NSRange> = []
                for lower in lowers {
                    for upper in uppers {
                        if isCancelled() { return nil }
                        guard lower <= upper, let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { continue }
                        guard let name = cmark_node_get_type_string(node) else { return nil }
                        let range = NSRange(location: start, length: end - start)
                        var valid = false
                        switch String(cString: name) {
                        case "strong": valid = pairedMarkers(range, characters: [42, 95], count: 2).count == 2
                        case "emph": valid = pairedMarkers(range, characters: [42, 95], count: 1).count == 2
                        case "strikethrough": valid = pairedMarkers(range, characters: [126], count: 2).count == 2
                        case "link": valid = !linkMarkers(range, node: node, mappedRange: { result[$0] }).isEmpty
                        case "code":
                            if let literal = cmark_node_get_literal(node), codeRange(range) != nil {
                                valid = text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16)
                            }
                        default: break
                        }
                        guard valid else { continue }
                        var child = cmark_node_first_child(node), previous = range.location
                        while let item = child {
                            guard let itemRange = result[item], itemRange.location >= previous,
                                  NSMaxRange(itemRange) <= NSMaxRange(range) else { valid = false; break }
                            previous = NSMaxRange(itemRange)
                            child = cmark_node_next(item)
                        }
                        if valid { matches.insert(range) }
                    }
                }
                guard matches.count == 1, let match = matches.first else { return nil }
                result[node] = match
            }
            guard (plainEditing ? (textCount + mathCount > 0 && mappedTextCount == textCount && mappedHTMLCount == htmlCount) : hasUnsupportedStyle), !isCancelled() else { return nil }
            if plainEditing { result[paragraph] = whole }
            return result
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

        // cmark removes one escaping backslash before each table pipe before
        // assigning inline columns. Map those columns back to the raw cell.
        struct TableCellPositions {
            let line: Int
            let column: Int
            let offsets: [Int]
        }

        func tableCellPositions(_ cell: OpaquePointer, isCancelled: () -> Bool = { false }) -> TableCellPositions? {
            let line = Int(cmark_node_get_start_line(cell)) - 1
            let cellColumn = Int(cmark_node_get_start_column(cell))
            let endCellColumn = Int(cmark_node_get_end_column(cell))
            guard line >= 0, line < lineStarts.count, !lineHasTab[line], cellColumn > 0,
                  endCellColumn >= cellColumn else { return nil }
            let rawStart = lineStarts[line] + cellColumn - 1
            let rawEnd = lineStarts[line] + endCellColumn
            guard rawStart <= rawEnd, rawEnd <= lineEnds[line] else { return nil }
            var offsets = [rawStart], index = rawStart
            while index < rawEnd {
                if isCancelled() { return nil }
                if bytes[index] == 92 {
                    var end = index
                    while end < rawEnd && bytes[end] == 92 { if isCancelled() { return nil }; end += 1 }
                    if end < rawEnd && bytes[end] == 124 && (end - index) % 2 == 1 {
                        while index < end - 1 { if isCancelled() { return nil }; index += 1; offsets.append(index) }
                        index = end + 1
                        offsets.append(index)
                        continue
                    }
                    while index < end { if isCancelled() { return nil }; index += 1; offsets.append(index) }
                    continue
                }
                index += 1
                offsets.append(index)
            }
            return TableCellPositions(line: line, column: cellColumn, offsets: offsets)
        }

        func tableRowCellSourceRanges(_ cell: OpaquePointer, text: NSString, isCancelled: () -> Bool = { false }) -> [OpaquePointer: NSRange]? {
            guard let row = cmark_node_parent(cell), let table = cmark_node_parent(row),
                  cmark_node_get_type_string(table).map({ String(cString: $0) }) == "table",
                  cmark_node_get_start_line(row) == cmark_node_get_end_line(row),
                  let rowRange = range(row), rowRange.length > 0, NSMaxRange(rowRange) <= text.length,
                  firstPosition(row) == rowRange.location,
                  let prefix = MarkdownPresentationParser.fencePrefixes(table, source: self, text: text, position: rowRange.location),
                  !prefix.source.contains("\t"), !isCancelled() else { return nil }
            let line = text.lineRange(for: NSRange(location: rowRange.location, length: 0))
            var lineEnd = NSMaxRange(line)
            while lineEnd > line.location && [10, 13].contains(Int(text.character(at: lineEnd - 1))) { lineEnd -= 1 }
            guard NSMaxRange(rowRange) == lineEnd, !text.substring(with: rowRange).contains("\t") else { return nil }
            var separators: [Int] = [], slashes = 0
            for index in rowRange.location..<NSMaxRange(rowRange) {
                if isCancelled() { return nil }
                let unit = text.character(at: index)
                if unit == 92 { slashes += 1; continue }
                if unit == 124 && slashes % 2 == 0 { separators.append(index) }
                slashes = 0
            }
            var starts = [rowRange.location], ends: [Int] = []
            for separator in separators { ends.append(separator); starts.append(separator + 1) }
            ends.append(NSMaxRange(rowRange))
            if separators.first == rowRange.location { starts.removeFirst(); ends.removeFirst() }
            if separators.last == NSMaxRange(rowRange) - 1 { starts.removeLast(); ends.removeLast() }
            guard starts.count == ends.count else { return nil }
            var index = 0, current = cmark_node_first_child(row), answer: [OpaquePointer: NSRange] = [:]
            while let item = current {
                if isCancelled() { return nil }
                guard index < starts.count, let positions = tableCellPositions(item, isCancelled: isCancelled),
                      let first = positions.offsets.first.flatMap(utf16Offset), let last = positions.offsets.last.flatMap(utf16Offset),
                      first == starts[index], last == ends[index], first < last else { return nil }
                answer[item] = NSRange(location: first, length: last - first)
                index += 1
                current = cmark_node_next(item)
            }
            guard index == starts.count, answer[cell] != nil, !isCancelled() else { return nil }
            return answer
        }

        func linkRange(_ node: OpaquePointer, tableCell: OpaquePointer?, tablePositions: TableCellPositions? = nil) -> NSRange? {
            if let recovered = recoveredRanges[node] { return recovered }
            if let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
               cmark_node_get_type(child) == CMARK_NODE_TEXT,
               cmark_node_get_start_line(node) == cmark_node_get_start_line(child),
               cmark_node_get_end_line(node) == cmark_node_get_end_line(child),
               cmark_node_get_start_column(node) == cmark_node_get_start_column(child),
               cmark_node_get_end_column(node) == cmark_node_get_end_column(child),
               let value = cmark_node_get_literal(child) {
                // GFM start columns are local to their inline buffer; derive the
                // start from the confirmed end and literal byte length instead.
                let literal = String(cString: value)
                guard cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
                      let candidate = mathInlineRange(line: Int(cmark_node_get_start_line(node)),
                        column: Int(cmark_node_get_end_column(node)) - literal.utf8.count + 1, byteLength: literal.utf8.count, parent: node, tablePositions: tablePositions),
                      String(decoding: units[candidate.location..<NSMaxRange(candidate)], as: UTF16.self) == literal else { return nil }
                return candidate
            }
            let normal: NSRange?
            if let tableCell, let positions = tablePositions ?? tableCellPositions(tableCell) { normal = tableInlineRange(node, positions: positions) }
            else { normal = range(node) }
            guard let normal, normal.length > 0,
                  units[normal.location] == 91 || (units[normal.location] == 60 && units[NSMaxRange(normal) - 1] == 62) else { return nil }
            return normal
        }

        func mathInlineRange(line: Int, column: Int, byteLength: Int, parent: OpaquePointer, tablePositions: TableCellPositions? = nil) -> NSRange? {
            let lineIndex = line - 1 + (paragraphLineShifts[parent] ?? 0)
            guard lineIndex >= 0, lineIndex < lineStarts.count,
                  (!lineHasTab[lineIndex] || paragraphColumnShifts[parent]?[lineIndex] != nil),
                  column > 0, byteLength > 0 else { return nil }
            let startByte: Int, endByte: Int
            var ancestor: OpaquePointer? = parent
            while let node = ancestor {
                if let name = cmark_node_get_type_string(node), String(cString: name) == "table_cell" { break }
                ancestor = cmark_node_parent(node)
            }
            if let cell = ancestor {
                guard let positions = tablePositions ?? tableCellPositions(cell), positions.line == lineIndex else { return nil }
                let lower = column - positions.column, upper = lower + byteLength
                guard lower >= 0, upper >= lower, upper < positions.offsets.count else { return nil }
                startByte = positions.offsets[lower]; endByte = positions.offsets[upper]
            } else {
                startByte = lineStarts[lineIndex] + column - 1 + (paragraphColumnShifts[parent]?[lineIndex] ?? 0)
                endByte = startByte + byteLength
                guard startByte >= (paragraphRetainedStarts[parent]?[lineIndex] ?? lineStarts[lineIndex]), endByte <= lineEnds[lineIndex] else { return nil }
            }
            guard let start = utf16Offset(at: startByte), let end = utf16Offset(at: endByte), end >= start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        func tableInlineRange(_ node: OpaquePointer, positions: TableCellPositions) -> NSRange? {
            if let recovered = recoveredRanges[node] { return recovered }
            let startColumn = Int(cmark_node_get_start_column(node))
            let endColumn = Int(cmark_node_get_end_column(node))
            let lower = startColumn - positions.column, upper = endColumn - positions.column + 1
            guard Int(cmark_node_get_start_line(node)) - 1 == positions.line,
                  Int(cmark_node_get_end_line(node)) - 1 == positions.line,
                  lower >= 0, upper >= lower, upper < positions.offsets.count,
                  let start = utf16Offset(at: positions.offsets[lower]),
                  let end = utf16Offset(at: positions.offsets[upper]), end >= start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        func footnoteDefinitionMarker(_ node: OpaquePointer) -> NSRange? {
            let line = Int(cmark_node_get_start_line(node)) - 1
            let column = Int(cmark_node_get_start_column(node))
            guard line >= 0, line < lineStarts.count, column > 0, !lineHasTab[line],
                  let start = utf16Offset(at: lineStarts[line]),
                  let content = utf16Offset(at: lineStarts[line] + column - 1), content <= units.count else { return nil }
            var cursor = start
            while cursor < content && units[cursor] == 32 && cursor - start < 3 { cursor += 1 }
            let markerStart = cursor
            guard cursor + 3 < content, units[cursor] == 91, units[cursor + 1] == 94 else { return nil }
            cursor += 2
            let identifierStart = cursor
            while cursor < content && units[cursor] != 93 && units[cursor] != 92 { cursor += 1 }
            guard cursor > identifierStart, cursor + 1 < content, units[cursor] == 93, units[cursor + 1] == 58 else { return nil }
            let end = cursor + 1
            cursor += 2
            while cursor < content && units[cursor] == 32 { cursor += 1 }
            guard cursor == content else { return nil }
            return NSRange(location: markerStart, length: end - markerStart)
        }

        func taskCheckbox(_ node: OpaquePointer) -> MarkdownTaskCheckbox? {
            let line = Int(cmark_node_get_start_line(node)) - 1
            let column = Int(cmark_node_get_start_column(node))
            guard cmark_node_get_type(node) == CMARK_NODE_ITEM,
                  line >= 0, line < lineStarts.count, column > 0,
                  let lineStart = utf16Offset(at: lineStarts[line]),
                  let start = utf16Offset(at: lineStarts[line] + column - 1),
                  let end = utf16Offset(at: lineEnds[line]), start >= lineStart, start < end,
                  units[lineStart..<start].allSatisfy({ $0 < 128 }) else { return nil }
            var cursor = start
            if units[cursor] == 45 || units[cursor] == 43 || units[cursor] == 42 {
                cursor += 1
            } else {
                while cursor < end && cursor - start < 9 && (48...57).contains(units[cursor]) { cursor += 1 }
                guard cursor > start, cursor < end, units[cursor] == 46 || units[cursor] == 41 else { return nil }
                cursor += 1
            }
            var visualColumn = 0
            for unit in units[lineStart..<cursor] {
                visualColumn = unit == 9 ? (visualColumn / 4 + 1) * 4 : visualColumn + 1
            }
            let paddingStart = visualColumn
            while cursor < end && (units[cursor] == 32 || units[cursor] == 9) {
                visualColumn = units[cursor] == 9 ? (visualColumn / 4 + 1) * 4 : visualColumn + 1
                cursor += 1
            }
            guard (1...4).contains(visualColumn - paddingStart), cursor + 2 < end,
                  units[cursor] == 91, units[cursor + 2] == 93,
                  units[cursor + 1] == 32 || units[cursor + 1] == 120 || units[cursor + 1] == 88,
                  cursor + 3 == end || units[cursor + 3] == 32 || units[cursor + 3] == 9 else { return nil }
            return MarkdownTaskCheckbox(markerRange: NSRange(location: cursor, length: 3),
                                        stateRange: NSRange(location: cursor + 1, length: 1), state: units[cursor + 1])
        }

        func quotedTaskCheckbox(_ node: OpaquePointer) -> MarkdownTaskCheckbox? {
            guard cmark_node_get_type_string(node).map({ String(cString: $0) }) == "item",
                  let checkbox = taskCheckbox(node) else { return nil }
            var parent = cmark_node_parent(node)
            while let current = parent {
                if cmark_node_get_type(current) == CMARK_NODE_BLOCK_QUOTE {
                    let line = Int(cmark_node_get_start_line(node)) - 1
                    if lineHasTab[line] {
                        guard let paragraph = cmark_node_first_child(node), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                              let first = cmark_node_first_child(paragraph), cmark_node_get_type(first) == CMARK_NODE_TEXT,
                              firstPosition(first) == checkbox.markerRange.location,
                              let literal = cmark_node_get_literal(first), let end = utf16Offset(at: lineEnds[line]) else { return nil }
                        var after = NSMaxRange(checkbox.markerRange)
                        while after < end && (units[after] == 32 || units[after] == 9) { after += 1 }
                        let prefix = units[checkbox.markerRange.location..<after]
                        guard String(cString: literal).utf16.starts(with: prefix) else { return nil }
                    }
                    return checkbox
                }
                parent = cmark_node_parent(current)
            }
            return nil
        }

        func firstPosition(_ node: OpaquePointer) -> Int? {
            if let range = looseListRanges[node] { return range.location }
            if looseHeadings[node] != nil, let recovered = recoveredRanges[node] { return recovered.location }
            let line = Int(cmark_node_get_start_line(node)) - 1
            let column = Int(cmark_node_get_start_column(node))
            guard line >= 0, line < lineStarts.count, column > 0 else { return nil }
            let byte = lineStarts[line] + column - 1
            guard byte <= lineEnds[line] else { return nil }
            return utf16Offset(at: byte)
        }

        func wholeLines(_ node: OpaquePointer, skipFirst: Bool = false) -> NSRange? {
            if let range = looseListRanges[node] {
                var start = range.location, end = NSMaxRange(range)
                guard start >= 0, end >= start, end <= units.count else { return nil }
                while start > 0 && units[start - 1] != 10 && units[start - 1] != 13 { start -= 1 }
                while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
                if end < units.count {
                    let newline = units[end]; end += 1
                    if newline == 13 && end < units.count && units[end] == 10 { end += 1 }
                }
                if skipFirst {
                    while start < end && units[start] != 10 && units[start] != 13 { start += 1 }
                    guard start < end else { return nil }
                    let newline = units[start]; start += 1
                    if newline == 13 && start < end && units[start] == 10 { start += 1 }
                    guard start < end else { return nil }
                }
                return NSRange(location: start, length: end - start)
            }
            var first = Int(cmark_node_get_start_line(node)) - 1
            var last = Int(cmark_node_get_end_line(node)) - 1
            let endColumn = Int(cmark_node_get_end_column(node))
            guard first >= 0, last >= first, last <= lineStarts.count else { return nil }
            if endColumn == 0 && last > first { last -= 1 }
            if skipFirst { first += 1 }
            guard first <= last, last < lineStarts.count, let start = utf16Offset(at: lineStarts[first]),
                  let end = utf16Offset(at: last + 1 < lineStarts.count ? lineStarts[last + 1] : bytes.count), end >= start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        func fenceRange(_ node: OpaquePointer) -> NSRange? {
            guard let start = firstPosition(node) else { return nil }
            let first = Int(cmark_node_get_start_line(node)) - 1
            var last = Int(cmark_node_get_end_line(node)) - 1
            var endColumn = Int(cmark_node_get_end_column(node))
            if endColumn == 0 && last > first && last <= lineStarts.count {
                last -= 1
                endColumn = lineEnds[last] - lineStarts[last]
            }
            guard last >= first, last < lineStarts.count,
                  endColumn == lineEnds[last] - lineStarts[last],
                  let end = utf16Offset(at: lineEnds[last]), end >= start else { return nil }
            return NSRange(location: start, length: end - start)
        }

        func range(_ node: OpaquePointer) -> NSRange? {
            if let recovered = recoveredRanges[node] { return recovered }
            if paragraphLineShifts[node] != nil && referencePrefixes[node] == nil { return nil }
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

        func editingTextRange(_ node: OpaquePointer) -> NSRange? {
            guard !possibleReferenceNodes.contains(node) || recoveredRanges[node] != nil else { return nil }
            return range(node)
        }

        func tabbedTextCandidateRanges(_ node: OpaquePointer, byteColumns: [Int: Int], scalarColumns: [Int: Int]) -> [NSRange] {
            let line = Int(cmark_node_get_start_line(node)) - 1
            let start = Int(cmark_node_get_start_column(node)) - 1
            let end = Int(cmark_node_get_end_column(node))
            guard cmark_node_get_type(node) == CMARK_NODE_TEXT, recoveredRanges[node] == nil, !possibleReferenceNodes.contains(node),
                  paragraphLineShifts[node] == nil, line >= 0, line < lineStarts.count, lineHasTab[line],
                  cmark_node_get_start_line(node) == cmark_node_get_end_line(node), start >= 0, end > start else { return [] }
            var starts: Set<Int> = [], ends: Set<Int> = []
            if start <= lineEnds[line] - lineStarts[line] { starts.insert(lineStarts[line] + start) }
            if end <= lineEnds[line] - lineStarts[line] { ends.insert(lineStarts[line] + end) }
            if let value = byteColumns[start] { starts.insert(value) }
            if let value = scalarColumns[start] { starts.insert(value) }
            if let value = byteColumns[end] { ends.insert(value) }
            if let value = scalarColumns[end] { ends.insert(value) }
            var ranges: Set<NSRange> = []
            for first in starts {
                for last in ends where last > first {
                    guard let lower = utf16Offset(at: first), let upper = utf16Offset(at: last), upper > lower else { continue }
                    ranges.insert(NSRange(location: lower, length: upper - lower))
                }
            }
            return Array(ranges)
        }

        // cmark columns around container tabs can be byte or visual positions.
        // Accept only a unique, fully confirmed literal text range.
        func tabbedLiteralTextRange(_ node: OpaquePointer, text: NSString, isCancelled: () -> Bool = { false }) -> NSRange? {
            guard cmark_node_get_type(node) == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(node) else { return nil }
            let value = String(cString: literal), length = (value as NSString).length
            let line = Int(cmark_node_get_start_line(node)) - 1
            let column = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
            guard line >= 0, line < lineStarts.count, lineHasTab[line],
                  cmark_node_get_start_line(node) == cmark_node_get_end_line(node), column > 0, length > 0,
                  !value.utf16.contains(9), endColumn == column + value.utf8.count - 1,
                  let start = utf16Offset(at: lineStarts[line]), let end = utf16Offset(at: lineEnds[line]) else { return nil }
            var offsets: Set<Int> = []
            let byteOffset = lineStarts[line] + column - 1
            if byteOffset <= lineEnds[line], let rawOffset = utf16Offset(at: byteOffset) { offsets.insert(rawOffset) }
            var offset = start, visual = 0
            while offset < end && visual < column - 1 {
                if isCancelled() { return nil }
                let unit = text.character(at: offset)
                guard unit < 128 else { break }
                let next = unit == 9 ? (visual / 4 + 1) * 4 : visual + 1
                if next > column - 1 { break }
                visual = next
                offset += 1
            }
            if visual == column - 1 { offsets.insert(offset) }
            let matches = offsets.filter { candidate in
                candidate >= start && candidate <= end && length <= end - candidate &&
                    text.substring(with: NSRange(location: candidate, length: length)) == value
            }
            guard !isCancelled(), matches.count == 1, let match = matches.first else { return nil }
            return NSRange(location: match, length: length)
        }

        func headingAnchor(_ node: OpaquePointer) -> NSRange? {
            let line = Int(cmark_node_get_start_line(node)) - 1
            guard line >= 0, line < lineStarts.count,
                  let offset = utf16Offset(at: lineStarts[line]) else { return nil }
            return NSRange(location: offset, length: 0)
        }

        func mathBlockRange(_ node: OpaquePointer) -> NSRange? {
            if let range = range(node) { return range }
            let first = Int(cmark_node_get_start_line(node)) - 1
            let last = Int(cmark_node_get_end_line(node)) - 1
            let startColumn = Int(cmark_node_get_start_column(node))
            let endColumn = Int(cmark_node_get_end_column(node))
            guard first >= 0, last >= first, last < lineStarts.count, startColumn > 0, endColumn > 0 else { return nil }
            let start = lineStarts[first] + startColumn - 1, end = lineStarts[last] + endColumn
            guard start >= lineStarts[first], start + 2 <= lineEnds[first], end <= lineEnds[last], end >= start + 4,
                  bytes[start] == 36, bytes[start + 1] == 36, bytes[end - 2] == 36, bytes[end - 1] == 36,
                  let firstUTF16 = utf16Offset(at: start), let lastUTF16 = utf16Offset(at: end) else { return nil }
            return NSRange(location: firstUTF16, length: lastUTF16 - firstUTF16)
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

        func headingMarkers(_ range: NSRange, allowNoSpace: Bool = false) -> [NSRange] {
            let start = range.location, end = NSMaxRange(range)
            var index = start
            while index < end && units[index] == 35 { index += 1 }
            guard index > start, index - start <= 6, index < end else { return [] }
            let separator = units[index] == 32 || units[index] == 9 ? 1 : 0
            guard separator == 1 || allowNoSpace else { return [] }
            return [NSRange(location: start, length: index - start + separator)]
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

        func linkMarkers(_ range: NSRange, node: OpaquePointer, mappedRange: ((OpaquePointer) -> NSRange?)? = nil) -> [NSRange] {
            let start = range.location, end = NSMaxRange(range)
            guard range.length >= 5, units[start] == 91, units[end - 1] == 41 else { return [] }
            var child = cmark_node_first_child(node), last: OpaquePointer?
            while let current = child { last = current; child = cmark_node_next(current) }
            guard let last else { return [] }
            let candidate = mappedRange.map { $0(last) } ?? self.range(last)
            guard let lastRange = candidate, lastRange.location >= start, lastRange.location <= end, lastRange.length >= 0,
                  lastRange.length <= end - lastRange.location else { return [] }
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
