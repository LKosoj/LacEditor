import Foundation

enum LineEditingCommand: Equatable {
    case duplicate, moveUp, moveDown, deleteLine, join, sortAscending, sortDescending, toggleComment

    var actionName: String {
        switch self {
        case .duplicate: L10n.tr("复制当前行")
        case .moveUp: L10n.tr("上移当前行")
        case .moveDown: L10n.tr("下移当前行")
        case .deleteLine: L10n.tr("删除当前行")
        case .join: L10n.tr("合并行")
        case .sortAscending: L10n.tr("升序排序行")
        case .sortDescending: L10n.tr("降序排序行")
        case .toggleComment: L10n.tr("切换注释")
        }
    }
}

struct LineEdit: Equatable {
    let range: NSRange
    let replacement: String
    let selectionRange: NSRange
}

/// Операции над строками в UTF-16. Границы строк — только CR, LF и CRLF; U+2028/U+2029 остаются содержимым.
enum LineEditingService {
    private struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    static func edit(in text: NSString, selection: NSRange, command: LineEditingCommand,
                     commentSyntax: CommentSyntax? = nil) -> LineEdit? {
        let length = text.length
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= length, selection.length <= length - selection.location else { return nil }
        let first = line(at: selection.location, in: text)
        var last = line(at: NSMaxRange(selection), in: text)
        if selection.length > 0, last.start > first.start, NSMaxRange(selection) == last.start {
            last = line(at: last.start - 1, in: text)
        }
        switch command {
        case .duplicate: return duplicate(text, selection, first, last)
        case .moveUp: return moveUp(text, selection, first, last)
        case .moveDown: return moveDown(text, selection, first, last)
        case .deleteLine: return deleteLine(text, first, last)
        case .join: return join(text, selection, first, last)
        case .sortAscending: return sort(text, first, last, ascending: true)
        case .sortDescending: return sort(text, first, last, ascending: false)
        case .toggleComment: return toggleComment(text, selection, first, last, syntax: commentSyntax)
        }
    }

    // MARK: Разбор строк

    private static func isBreak(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    private static func line(at location: Int, in text: NSString) -> Line {
        let length = text.length
        var position = location
        if position > 0, position < length, text.character(at: position - 1) == 13, text.character(at: position) == 10 {
            position -= 1
        }
        var start = position
        while start > 0, !isBreak(text.character(at: start - 1)) { start -= 1 }
        var contentEnd = position
        while contentEnd < length, !isBreak(text.character(at: contentEnd)) { contentEnd += 1 }
        var end = contentEnd
        if contentEnd < length {
            end += text.character(at: contentEnd) == 13 && contentEnd + 1 < length
                && text.character(at: contentEnd + 1) == 10 ? 2 : 1
        }
        return Line(start: start, contentEnd: contentEnd, end: end)
    }

    /// После финального перевода строки есть пустая строка: курсор в ней допустим.
    private static func next(after line: Line, in text: NSString) -> Line? {
        if line.end == text.length {
            return line.end > line.contentEnd ? Line(start: line.end, contentEnd: line.end, end: line.end) : nil
        }
        return Self.line(at: line.end, in: text)
    }

    private static func previous(before line: Line, in text: NSString) -> Line? {
        line.start == 0 ? nil : Self.line(at: line.start - 1, in: text)
    }

    private static func lines(from first: Line, to last: Line, in text: NSString) -> [Line] {
        var result = [first]
        while let current = result.last, current.start < last.start, let following = next(after: current, in: text) {
            result.append(following)
        }
        return result
    }

    private static func substring(_ text: NSString, _ from: Int, _ to: Int) -> String {
        text.substring(with: NSRange(location: from, length: to - from))
    }

    private static func terminator(_ line: Line, in text: NSString) -> String {
        substring(text, line.contentEnd, line.end)
    }

    private static func clamp(_ range: NSRange, to limit: Int) -> NSRange {
        let location = min(range.location, limit)
        return NSRange(location: location, length: min(range.length, limit - location))
    }

    // MARK: Операции

    private static func duplicate(_ text: NSString, _ selection: NSRange, _ first: Line, _ last: Line) -> LineEdit {
        let hasTerminator = last.end > last.contentEnd
        let replacement: String
        let copyStart: Int
        if hasTerminator {
            replacement = substring(text, first.start, last.end)
            copyStart = last.end
        } else {
            let eol = previous(before: last, in: text).map { terminator($0, in: text) } ?? "\n"
            replacement = eol + substring(text, first.start, last.contentEnd)
            copyStart = last.end + eol.utf16.count
        }
        let shift = copyStart - first.start
        return LineEdit(range: NSRange(location: last.end, length: 0), replacement: replacement,
                        selectionRange: NSRange(location: selection.location + shift, length: selection.length))
    }

    private static func moveUp(_ text: NSString, _ selection: NSRange, _ first: Line, _ last: Line) -> LineEdit? {
        guard let above = previous(before: first, in: text) else { return nil }
        let aboveTerminator = terminator(above, in: text)
        let body = substring(text, first.start, last.contentEnd) + aboveTerminator
        let replacement = body + substring(text, above.start, above.contentEnd) + terminator(last, in: text)
        let limit = above.start + body.utf16.count
        let shifted = NSRange(location: selection.location + above.start - first.start, length: selection.length)
        return LineEdit(range: NSRange(location: above.start, length: last.end - above.start),
                        replacement: replacement, selectionRange: clamp(shifted, to: limit))
    }

    private static func moveDown(_ text: NSString, _ selection: NSRange, _ first: Line, _ last: Line) -> LineEdit? {
        guard let below = next(after: last, in: text), below.start < text.length else { return nil }
        let belowContent = substring(text, below.start, below.contentEnd)
        let lastTerminator = terminator(last, in: text)
        let replacement = belowContent + lastTerminator + substring(text, first.start, last.contentEnd)
            + terminator(below, in: text)
        let shift = belowContent.utf16.count + lastTerminator.utf16.count
        let limit = first.start + replacement.utf16.count
        let shifted = NSRange(location: selection.location + shift, length: selection.length)
        return LineEdit(range: NSRange(location: first.start, length: below.end - first.start),
                        replacement: replacement, selectionRange: clamp(shifted, to: limit))
    }

    private static func deleteLine(_ text: NSString, _ first: Line, _ last: Line) -> LineEdit? {
        guard text.length > 0 else { return nil }
        var start = first.start
        if last.end == last.contentEnd, let above = previous(before: first, in: text) {
            start = above.contentEnd
        }
        return LineEdit(range: NSRange(location: start, length: last.end - start), replacement: "",
                        selectionRange: NSRange(location: start, length: 0))
    }

    private static func join(_ text: NSString, _ selection: NSRange, _ first: Line, _ last: Line) -> LineEdit? {
        var block = lines(from: first, to: last, in: text)
        let isBlock = block.count > 1
        if !isBlock {
            guard let below = next(after: first, in: text), below.start < text.length else { return nil }
            block.append(below)
        }
        var joined = substring(text, first.start, first.contentEnd)
        var firstJoint = joined.utf16.count
        for (index, line) in block.enumerated().dropFirst() {
            let right = String(substring(text, line.start, line.contentEnd).drop { $0 == " " || $0 == "\t" })
            if index == 1 { firstJoint = joined.utf16.count }
            if !joined.isEmpty && !right.isEmpty { joined += " " }
            joined += right
        }
        let range = NSRange(location: first.start, length: block[block.count - 1].contentEnd - first.start)
        let selectionRange = isBlock
            ? NSRange(location: first.start, length: joined.utf16.count)
            : NSRange(location: first.start + firstJoint, length: 0)
        return LineEdit(range: range, replacement: joined, selectionRange: selectionRange)
    }

    private static func sort(_ text: NSString, _ first: Line, _ last: Line, ascending: Bool) -> LineEdit? {
        var first = first
        var last = last
        if first.start == last.start {
            first = line(at: 0, in: text)
            last = line(at: text.length, in: text)
            if last.start == text.length, let above = previous(before: last, in: text) { last = above }
        }
        let block = lines(from: first, to: last, in: text)
        guard block.count > 1 else { return nil }
        let contents = block.map { substring(text, $0.start, $0.contentEnd) }
        let order = contents.indices.sorted { left, right in
            let result = contents[left].localizedStandardCompare(contents[right])
            if result == .orderedSame { return left < right }
            return result == (ascending ? .orderedAscending : .orderedDescending)
        }
        var replacement = ""
        for (position, source) in order.enumerated() {
            replacement += contents[source]
            if position < block.count - 1 { replacement += terminator(block[position], in: text) }
        }
        let range = NSRange(location: first.start, length: last.contentEnd - first.start)
        guard replacement != text.substring(with: range) else { return nil }
        return LineEdit(range: range, replacement: replacement,
                        selectionRange: NSRange(location: range.location, length: replacement.utf16.count))
    }

    // MARK: Комментарии

    private struct Piece {
        let position: Int
        let remove: Int
        let insert: String
    }

    private static func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    private static func toggleComment(_ text: NSString, _ selection: NSRange, _ first: Line, _ last: Line,
                                      syntax: CommentSyntax?) -> LineEdit? {
        guard let syntax else { return nil }
        let (open, close): (String, String?) = switch syntax {
        case let .line(marker): (marker, nil)
        case let .block(openMarker, closeMarker): (openMarker, closeMarker)
        }
        let openLength = open.utf16.count
        let closeLength = close?.utf16.count ?? 0
        // (строка, конец отступа) для непустых строк
        var targets: [(line: Line, indentEnd: Int)] = []
        for line in lines(from: first, to: last, in: text) {
            var indentEnd = line.start
            while indentEnd < line.contentEnd, isBlank(text.character(at: indentEnd)) { indentEnd += 1 }
            if indentEnd < line.contentEnd { targets.append((line, indentEnd)) }
        }
        guard let firstTarget = targets.first else { return nil }

        func trimmedEnd(_ line: Line) -> Int {
            var end = line.contentEnd
            while end > line.start, isBlank(text.character(at: end - 1)) { end -= 1 }
            return end
        }
        func hasText(_ marker: String, at position: Int, before limit: Int) -> Bool {
            let count = marker.utf16.count
            return position >= 0 && position + count <= limit && substring(text, position, position + count) == marker
        }
        let allCommented = targets.allSatisfy { target in
            guard hasText(open, at: target.indentEnd, before: target.line.contentEnd) else { return false }
            guard let close else { return true }
            let end = trimmedEnd(target.line)
            return end - closeLength >= target.indentEnd + openLength && hasText(close, at: end - closeLength, before: end)
        }

        var pieces: [Piece] = []
        if allCommented {
            for target in targets {
                var openRemove = openLength
                if target.indentEnd + openLength < target.line.contentEnd,
                   text.character(at: target.indentEnd + openLength) == 32 { openRemove += 1 }
                pieces.append(Piece(position: target.indentEnd, remove: openRemove, insert: ""))
                if close != nil {
                    var closeStart = trimmedEnd(target.line) - closeLength
                    var closeRemove = closeLength
                    if closeStart - 1 >= target.indentEnd + openRemove, text.character(at: closeStart - 1) == 32 {
                        closeStart -= 1
                        closeRemove += 1
                    }
                    pieces.append(Piece(position: closeStart, remove: closeRemove, insert: ""))
                }
            }
        } else {
            var commonLength = firstTarget.indentEnd - firstTarget.line.start
            for target in targets {
                var count = 0
                let indent = target.indentEnd - target.line.start
                while count < min(commonLength, indent),
                      text.character(at: target.line.start + count)
                        == text.character(at: firstTarget.line.start + count) {
                    count += 1
                }
                commonLength = count
            }
            for target in targets {
                pieces.append(Piece(position: target.line.start + commonLength, remove: 0, insert: open + " "))
                if let close {
                    pieces.append(Piece(position: target.line.contentEnd, remove: 0, insert: " " + close))
                }
            }
        }

        var replacement = ""
        var cursor = first.start
        for piece in pieces {
            replacement += substring(text, cursor, piece.position) + piece.insert
            cursor = piece.position + piece.remove
        }
        let rangeEnd = last.contentEnd
        replacement += substring(text, cursor, rangeEnd)
        let range = NSRange(location: first.start, length: rangeEnd - first.start)
        guard replacement != text.substring(with: range) else { return nil }

        func map(_ position: Int) -> Int {
            var shift = 0
            for piece in pieces {
                if position <= piece.position { break }
                let insertLength = piece.insert.utf16.count
                if position >= piece.position + piece.remove {
                    shift += insertLength - piece.remove
                } else {
                    return piece.position + insertLength + shift
                }
            }
            return position + shift
        }
        let start = map(selection.location)
        let end = map(NSMaxRange(selection))
        return LineEdit(range: range, replacement: replacement,
                        selectionRange: NSRange(location: start, length: end - start))
    }
}
