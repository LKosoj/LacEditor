import Foundation

enum MarkdownFormattingCommand: Equatable {
    case bold, italic, strikethrough, inlineCode, heading(Int), quote

    var actionName: String {
        switch self {
        case .bold: L10n.tr("加粗")
        case .italic: L10n.tr("斜体")
        case .strikethrough: L10n.tr("删除线")
        case .inlineCode: L10n.tr("行内代码")
        case .heading: L10n.tr("设置标题")
        case .quote: L10n.tr("引用")
        }
    }
}

struct MarkdownFormattingEdit {
    let range: NSRange
    let replacement: String
    let selectionRange: NSRange
}

enum MarkdownFormattingService {
    static func edit(in text: NSString, selection: NSRange, command: MarkdownFormattingCommand) -> MarkdownFormattingEdit? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location,
              isCharacterBoundary(selection.location, in: text),
              isCharacterBoundary(NSMaxRange(selection), in: text) else { return nil }
        switch command {
        case .bold, .italic, .strikethrough, .inlineCode:
            guard let selected = inlineSelection(selection, in: text) else { return nil }
            switch command {
            case .bold: return inlineEdit(in: text, selection: selected, marker: "**")
            case .italic: return inlineEdit(in: text, selection: selected, marker: "*")
            case .strikethrough: return inlineEdit(in: text, selection: selected, marker: "~~")
            case .inlineCode: return codeEdit(in: text, selection: selected)
            default: return nil
            }
        case let .heading(level):
            guard (1...6).contains(level) else { return nil }
            return blockEdit(in: text, selection: selection, heading: level)
        case .quote: return blockEdit(in: text, selection: selection, heading: nil)
        }
    }

    private static func inlineSelection(_ selection: NSRange, in text: NSString) -> NSRange? {
        guard selection.length > 0 else { return selection }
        var start = selection.location, end = NSMaxRange(selection)
        func whitespace(_ index: Int) -> Bool {
            guard let scalar = UnicodeScalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while start < end && whitespace(start) { start += 1 }
        while end > start && whitespace(end - 1) { end -= 1 }
        guard start < end else { return nil }
        var lineBreaks = 0, index = start
        while index < end {
            let character = text.character(at: index)
            if character == 13 || character == 10 {
                lineBreaks += 1
                if lineBreaks > 1 { return nil }
                if character == 13 && index + 1 < end && text.character(at: index + 1) == 10 { index += 1 }
            } else if !whitespace(index) {
                lineBreaks = 0
            }
            index += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isEscaped(_ location: Int, in text: NSString) -> Bool {
        var index = location, count = 0
        while index > 0 && text.character(at: index - 1) == 92 { index -= 1; count += 1 }
        return count % 2 == 1
    }

    private static func isCharacterBoundary(_ location: Int, in text: NSString) -> Bool {
        guard location > 0, location < text.length else { return true }
        let before = text.character(at: location - 1), after = text.character(at: location)
        return !(0xd800...0xdbff).contains(before) || !(0xdc00...0xdfff).contains(after)
    }

    private static func inlineEdit(in text: NSString, selection: NSRange, marker: String) -> MarkdownFormattingEdit? {
        let selected = text.substring(with: selection)
        let size = (marker as NSString).length
        let end = NSMaxRange(selection)
        if selection.length > 0, selection.location >= size, end + size <= text.length,
           text.substring(with: NSRange(location: selection.location - size, length: size)) == marker,
           text.substring(with: NSRange(location: end, length: size)) == marker,
           (selection.location == size || text.character(at: selection.location - size - 1) != (marker as NSString).character(at: 0)),
           (end + size == text.length || text.character(at: end + size) != (marker as NSString).character(at: 0)) {
            guard !isEscaped(selection.location - size, in: text), !isEscaped(end, in: text) else { return nil }
            let range = NSRange(location: selection.location - size, length: selection.length + 2 * size)
            return MarkdownFormattingEdit(range: range, replacement: selected,
                                          selectionRange: NSRange(location: range.location, length: selection.length))
        }
        guard !isEscaped(selection.location, in: text), !isEscaped(end, in: text) else { return nil }
        return MarkdownFormattingEdit(range: selection, replacement: marker + selected + marker,
                                      selectionRange: NSRange(location: selection.location + size, length: selection.length))
    }

    private static func codeEdit(in text: NSString, selection: NSRange) -> MarkdownFormattingEdit? {
        let selected = text.substring(with: selection) as NSString
        var maxRun = 0, run = 0
        for index in 0..<selected.length {
            if selected.character(at: index) == 96 { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
        }
        let marker = String(repeating: "`", count: maxRun + 1)
        let markerLength = maxRun + 1
        let needsPadding = selected.length > 0 && (
            selected.character(at: 0) == 96 || selected.character(at: selected.length - 1) == 96 ||
            (selected.character(at: 0) == 32 && selected.character(at: selected.length - 1) == 32 &&
             (0..<selected.length).contains { selected.character(at: $0) != 32 })
        )
        let padding = needsPadding ? " " : ""
        let wrapper = marker + padding
        let wrapperLength = markerLength + (needsPadding ? 1 : 0)
        let end = NSMaxRange(selection)
        if selection.length > 0, selection.location >= wrapperLength, end + wrapperLength <= text.length,
           text.substring(with: NSRange(location: selection.location - wrapperLength, length: wrapperLength)) == wrapper,
           text.substring(with: NSRange(location: end, length: wrapperLength)) == padding + marker,
           (selection.location == wrapperLength || text.character(at: selection.location - wrapperLength - 1) != 96),
           (end + wrapperLength == text.length || text.character(at: end + wrapperLength) != 96) {
            guard !isEscaped(selection.location - wrapperLength, in: text),
                  !isEscaped(end + (needsPadding ? 1 : 0), in: text) else { return nil }
            let range = NSRange(location: selection.location - wrapperLength, length: selection.length + 2 * wrapperLength)
            return MarkdownFormattingEdit(range: range, replacement: selected as String,
                                          selectionRange: NSRange(location: range.location, length: selection.length))
        }
        guard !isEscaped(selection.location, in: text) else { return nil }
        return MarkdownFormattingEdit(range: selection, replacement: wrapper + (selected as String) + padding + marker,
                                      selectionRange: NSRange(location: selection.location + wrapperLength, length: selection.length))
    }

    private struct LinePrefix {
        let range: NSRange
        let replacement: String
    }

    private static func intersectsCodeBlock(in text: NSString, from first: Int, through last: Int) -> Bool {
        var location = 0, fence: (character: unichar, length: Int, quoteDepth: Int)?
        while location <= last && location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let end = NSMaxRange(line)
            var cursor = location, spaces = 0
            while cursor < end && text.character(at: cursor) == 32 { cursor += 1; spaces += 1 }
            if location >= first && (spaces >= 4 || (cursor < end && text.character(at: cursor) == 9)) { return true }
            // Fences inside quotes or lists are treated as code too; their
            // markers are not rewritten by a block formatting command.
            var quoteDepth = 0
            while cursor < end && text.character(at: cursor) == 62 {
                quoteDepth += 1
                cursor += 1
                if cursor < end && text.character(at: cursor) == 32 { cursor += 1 }
            }
            if let open = fence, quoteDepth < open.quoteDepth { fence = nil }
            if cursor + 1 < end && (text.character(at: cursor) == 45 || text.character(at: cursor) == 43 || text.character(at: cursor) == 42) && text.character(at: cursor + 1) == 32 { cursor += 2 }
            var digitEnd = cursor
            while digitEnd < end && (48...57).contains(text.character(at: digitEnd)) { digitEnd += 1 }
            if digitEnd > cursor && digitEnd + 1 < end && (text.character(at: digitEnd) == 46 || text.character(at: digitEnd) == 41) && text.character(at: digitEnd + 1) == 32 { cursor = digitEnd + 2 }
            while cursor < end && text.character(at: cursor) == 32 { cursor += 1 }
            var fenceLength = 0
            if cursor < end && (text.character(at: cursor) == 96 || text.character(at: cursor) == 126) {
                let character = text.character(at: cursor)
                while cursor + fenceLength < end && text.character(at: cursor + fenceLength) == character { fenceLength += 1 }
                if fenceLength >= 3 {
                    if location >= first { return true }
                    if let open = fence {
                        var tail = cursor + fenceLength
                        while tail < end && (text.character(at: tail) == 32 || text.character(at: tail) == 9 || text.character(at: tail) == 10 || text.character(at: tail) == 13) { tail += 1 }
                        if character == open.character && fenceLength >= open.length && tail == end { fence = nil }
                    } else {
                        fence = (character, fenceLength, quoteDepth)
                    }
                }
            }
            if location >= first && fence != nil { return true }
            if end <= location { break }
            location = end
        }
        return false
    }

    private static func blockEdit(in text: NSString, selection: NSRange, heading: Int?) -> MarkdownFormattingEdit? {
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let lastLocation = selection.length == 0 ? selection.location : NSMaxRange(selection) - 1
        let lastLine = text.lineRange(for: NSRange(location: lastLocation, length: 0))
        let end = NSMaxRange(lastLine)
        guard !intersectsCodeBlock(in: text, from: first, through: lastLine.location) else { return nil }
        var locations: [Int] = []
        var location = first
        repeat {
            locations.append(location)
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(line)
            if next <= location || next >= end { break }
            location = next
        } while location <= text.length

        var existing: [(location: Int, length: Int, level: Int)] = []
        for lineStart in locations {
            let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
            var cursor = lineStart
            while cursor < NSMaxRange(line), cursor - lineStart < 3, text.character(at: cursor) == 32 { cursor += 1 }
            if cursor < NSMaxRange(line), text.character(at: cursor) == 96 || text.character(at: cursor) == 126 {
                let character = text.character(at: cursor)
                var fenceEnd = cursor
                while fenceEnd < NSMaxRange(line), text.character(at: fenceEnd) == character { fenceEnd += 1 }
                if fenceEnd - cursor >= 3 { return nil }
            }
            if heading != nil {
                if cursor < NSMaxRange(line) {
                    let firstCharacter = text.character(at: cursor)
                    if firstCharacter == 62 { return nil }
                    if (firstCharacter == 45 || firstCharacter == 43 || firstCharacter == 42),
                       cursor + 1 < text.length, text.character(at: cursor + 1) == 32 { return nil }
                    var numberEnd = cursor
                    while numberEnd < NSMaxRange(line), (48...57).contains(text.character(at: numberEnd)) { numberEnd += 1 }
                    if numberEnd > cursor, numberEnd + 1 < text.length,
                       (text.character(at: numberEnd) == 46 || text.character(at: numberEnd) == 41),
                       text.character(at: numberEnd + 1) == 32 { return nil }
                }
                var markerEnd = cursor
                while markerEnd < NSMaxRange(line), text.character(at: markerEnd) == 35 { markerEnd += 1 }
                let count = markerEnd - cursor
                if (1...6).contains(count), markerEnd == text.length || text.character(at: markerEnd) == 32 || text.character(at: markerEnd) == 9 || text.character(at: markerEnd) == 10 || text.character(at: markerEnd) == 13 {
                    let space = markerEnd < text.length && (text.character(at: markerEnd) == 32 || text.character(at: markerEnd) == 9) ? 1 : 0
                    existing.append((cursor, count + space, count))
                } else {
                    existing.append((cursor, 0, 0))
                }
            } else if cursor < NSMaxRange(line), text.character(at: cursor) == 62 {
                let space = cursor + 1 < text.length && text.character(at: cursor + 1) == 32 ? 1 : 0
                existing.append((cursor, 1 + space, 1))
            } else {
                existing.append((cursor, 0, 0))
            }
        }
        let remove = existing.allSatisfy { $0.level == (heading ?? 1) }
        let replacementPrefix = heading.map { String(repeating: "#", count: $0) + " " } ?? "> "
        let prefixes = existing.map { item in
            LinePrefix(range: NSRange(location: item.location, length: heading == nil && !remove ? 0 : item.length),
                       replacement: remove ? "" : replacementPrefix)
        }
        let affected = NSRange(location: first, length: end - first)
        let result = NSMutableString(string: text.substring(with: affected))
        for prefix in prefixes.reversed() {
            result.replaceCharacters(in: NSRange(location: prefix.range.location - first, length: prefix.range.length), with: prefix.replacement)
        }
        func mapped(_ point: Int) -> Int {
            var adjustment = 0
            for prefix in prefixes {
                let start = prefix.range.location, finish = NSMaxRange(prefix.range)
                let length = (prefix.replacement as NSString).length
                if point < start { break }
                if point < finish { return start + adjustment + min(point - start, length) }
                adjustment += length - prefix.range.length
            }
            return point + adjustment
        }
        let start = mapped(selection.location), finish = mapped(NSMaxRange(selection))
        return MarkdownFormattingEdit(range: affected, replacement: result as String,
                                      selectionRange: NSRange(location: start, length: finish - start))
    }
}
