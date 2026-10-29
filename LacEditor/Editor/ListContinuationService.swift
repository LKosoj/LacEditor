import Foundation

enum ListContinuationService {
    private static let continuationOrderedExpression = try! NSRegularExpression(
        pattern: #"^(\d+)([.)])\s+(.+)$"#
    )
    private static let continuationUnorderedExpression = try! NSRegularExpression(
        pattern: #"^([-*+])\s+(.+)$"#
    )
    private static let orderedItemExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)(\d+)([.)])\s+.*$"#
    )
    private static let emptyItemExpression = try! NSRegularExpression(
        pattern: #"^(?:\d+[.)]|[-*+])\s*$"#
    )
    struct ListEdit {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    private static let itemExpression = try! NSRegularExpression(
        pattern: #"^((?: {0,3}>[ \t]?)*)([ \t]*)([-*+]|[0-9]+[.)])([ \t]+)(?:\[([ xX])\](?:([ \t]+)|(?=\r|\n|$)))?"#
    )

    private static func markdownLine(in text: NSString, at position: Int) -> NSRange {
        var point = position
        if point > 0 && point < text.length && text.character(at: point) == 10 && text.character(at: point - 1) == 13 { point -= 1 }
        var start = point
        while start > 0 && text.character(at: start - 1) != 10 && text.character(at: start - 1) != 13 { start -= 1 }
        var end = point
        while end < text.length && text.character(at: end) != 10 && text.character(at: end) != 13 { end += 1 }
        if end < text.length {
            let cr = text.character(at: end) == 13
            end += 1
            if cr && end < text.length && text.character(at: end) == 10 { end += 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    private static func itemMatch(in line: NSString) -> NSTextCheckingResult? {
        itemExpression.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
    }

    private static func advanceColumns(_ value: String, from start: Int = 0) -> Int {
        value.reduce(start) { column, character in
            character == "\t" ? column + 4 - column % 4 : column + 1
        }
    }

    private static func indentationWidth(_ indentation: String) -> Int {
        advanceColumns(indentation)
    }

    private static func listColumns(_ raw: NSString, item: NSTextCheckingResult) -> (indent: Int, content: Int) {
        let quote = raw.substring(with: item.range(at: 1))
        let quoteColumn = advanceColumns(quote)
        let indentColumn = advanceColumns(raw.substring(with: item.range(at: 2)), from: quoteColumn)
        let markerColumn = indentColumn + item.range(at: 3).length
        let whitespaceEnd = advanceColumns(raw.substring(with: item.range(at: 4)), from: markerColumn)
        let padding = whitespaceEnd - markerColumn
        let afterWhitespace = NSMaxRange(item.range(at: 4))
        let blank = afterWhitespace == raw.length || raw.character(at: afterWhitespace) == 10 || raw.character(at: afterWhitespace) == 13
        let contentColumn = markerColumn + (padding > 4 || blank ? 1 : padding)
        return (indentColumn - quoteColumn, contentColumn - quoteColumn)
    }

    private static func quoteDepth(in raw: NSString) -> Int {
        var cursor = 0, depth = 0
        while cursor < raw.length {
            var next = cursor
            while next < raw.length && next - cursor < 3 && raw.character(at: next) == 32 { next += 1 }
            guard next < raw.length && raw.character(at: next) == 62 else { break }
            depth += 1
            cursor = next + 1
            if cursor < raw.length && (raw.character(at: cursor) == 32 || raw.character(at: cursor) == 9) { cursor += 1 }
        }
        return depth
    }

    private static func indentationAfterQuotes(in raw: NSString) -> Int {
        var cursor = 0
        while cursor < raw.length {
            var next = cursor
            while next < raw.length && next - cursor < 3 && raw.character(at: next) == 32 { next += 1 }
            guard next < raw.length && raw.character(at: next) == 62 else { break }
            cursor = next + 1
            if cursor < raw.length && (raw.character(at: cursor) == 32 || raw.character(at: cursor) == 9) { cursor += 1 }
        }
        let start = cursor
        while cursor < raw.length && (raw.character(at: cursor) == 32 || raw.character(at: cursor) == 9) { cursor += 1 }
        return indentationWidth(raw.substring(with: NSRange(location: start, length: cursor - start)))
    }

    private static func isInCode(in text: NSString, lineStart: Int, indentation: String) -> Bool {
        var location = 0
        var fence: (character: unichar, length: Int, quoteDepth: Int, listContent: Int?)?
        var parents: [(indent: Int, content: Int, quoteDepth: Int)] = []
        let targetLine = markdownLine(in: text, at: lineStart)
        let targetDepth = quoteDepth(in: text.substring(with: targetLine) as NSString)
        while location < lineStart {
            let line = markdownLine(in: text, at: location)
            let raw = text.substring(with: line) as NSString
            let depth = quoteDepth(in: raw)
            if let open = fence {
                if depth < open.quoteDepth { fence = nil }
                else if let content = open.listContent, depth == open.quoteDepth {
                    let prefix = itemMatch(in: raw)?.range(at: 1) ?? NSRange(location: 0, length: 0)
                    let start = NSMaxRange(prefix)
                    var end = start
                    while end < raw.length && (raw.character(at: end) == 32 || raw.character(at: end) == 9) { end += 1 }
                    let rest = raw.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines)
                    let width = indentationWidth(raw.substring(with: NSRange(location: start, length: end - start)))
                    if !rest.isEmpty && width < content { fence = nil }
                }
            }
            let match = itemMatch(in: raw)
            if fence == nil, let match {
                let columns = listColumns(raw, item: match)
                let indent = columns.indent
                while let parent = parents.last, depth != parent.quoteDepth || indent <= parent.indent { parents.removeLast() }
                if indent < 4 || parents.last.map({ indent >= $0.content && indent < $0.content + 4 }) == true {
                    parents.append((indent, columns.content, depth))
                }
            } else if fence == nil && match == nil {
                let content = (raw as String).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty && depth == 0 && raw.length > 0 && raw.character(at: 0) != 32 && raw.character(at: 0) != 9 { parents.removeAll() }
            }
            var cursor = match.map { NSMaxRange($0.range) } ?? 0
            if match == nil {
                while cursor < raw.length && (raw.character(at: cursor) == 32 || raw.character(at: cursor) == 9 || raw.character(at: cursor) == 62) { cursor += 1 }
            }
            if cursor < raw.length && (raw.character(at: cursor) == 96 || raw.character(at: cursor) == 126) {
                let character = raw.character(at: cursor)
                var count = 0
                while cursor + count < raw.length && raw.character(at: cursor + count) == character { count += 1 }
                if count >= 3 {
                    if let open = fence {
                        if open.character == character && count >= open.length {
                            let tail = raw.substring(from: cursor + count).trimmingCharacters(in: .whitespacesAndNewlines)
                            if tail.isEmpty { fence = nil }
                        }
                    } else {
                        let content = match.map { item in
                            listColumns(raw, item: item).content
                        } ?? parents.last(where: { parent in
                            let indent = indentationAfterQuotes(in: raw)
                            return parent.quoteDepth == depth && indent >= parent.content && indent < parent.content + 4
                        })?.content
                        fence = (character, count, depth, content)
                    }
                }
            }
            if NSMaxRange(line) <= location { break }
            location = NSMaxRange(line)
        }
        let targetRaw = text.substring(with: targetLine) as NSString
        let targetItem = itemMatch(in: targetRaw)
        let width = targetItem.map { listColumns(targetRaw, item: $0).indent } ?? indentationWidth(indentation)
        if let open = fence, targetDepth >= open.quoteDepth,
           open.listContent == nil || targetDepth > open.quoteDepth || width >= open.listContent! { return true }
        guard width >= 4 else { return false }
        return !parents.contains { $0.quoteDepth == targetDepth && width >= $0.content && width < $0.content + 4 }
    }

    static func isCodeContext(in text: NSString, at location: Int) -> Bool {
        guard location >= 0, location <= text.length else { return true }
        let line = markdownLine(in: text, at: location)
        let raw = text.substring(with: line) as NSString
        let indent = indentationAfterQuotes(in: raw)
        if isInCode(in: text, lineStart: line.location, indentation: String(repeating: " ", count: indent)) { return true }
        var cursor = itemMatch(in: raw).map { NSMaxRange($0.range) } ?? 0
        while cursor < raw.length && (raw.character(at: cursor) == 32 || raw.character(at: cursor) == 9 || raw.character(at: cursor) == 62) { cursor += 1 }
        if cursor < raw.length && (raw.character(at: cursor) == 96 || raw.character(at: cursor) == 126) {
            let marker = raw.character(at: cursor)
            var count = 0
            while cursor + count < raw.length && raw.character(at: cursor + count) == marker { count += 1 }
            if count >= 3 { return true }
        }
        return false
    }

    static func listNewlineEdit(in text: NSString, selection: NSRange, indentUnit: String) -> ListEdit? {
        guard selection.location != NSNotFound, selection.location <= text.length,
              selection.length <= text.length - selection.location else { return nil }
        let line = markdownLine(in: text, at: selection.location)
        var contentEnd = NSMaxRange(line)
        while contentEnd > line.location && (text.character(at: contentEnd - 1) == 10 || text.character(at: contentEnd - 1) == 13) { contentEnd -= 1 }
        let raw = text.substring(with: NSRange(location: line.location, length: contentEnd - line.location)) as NSString
        guard let item = itemMatch(in: raw) else { return nil }
        let contentStart = line.location + NSMaxRange(item.range)
        guard selection.location >= contentStart, NSMaxRange(selection) <= contentEnd else { return nil }
        let quote = raw.substring(with: item.range(at: 1))
        let indent = raw.substring(with: item.range(at: 2))
        guard !isInCode(in: text, lineStart: line.location, indentation: indent) else { return nil }
        let marker = raw.substring(with: item.range(at: 3))
        let task = item.range(at: 5).location != NSNotFound
        let newline: String
        if contentEnd < NSMaxRange(line) { newline = text.substring(with: NSRange(location: contentEnd, length: NSMaxRange(line) - contentEnd)) }
        else if line.location > 0 && text.character(at: line.location - 1) == 10 && line.location > 1 && text.character(at: line.location - 2) == 13 { newline = "\r\n" }
        else if line.location > 0 && text.character(at: line.location - 1) == 13 { newline = "\r" }
        else { newline = "\n" }
        let content = text.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
        if content.trimmingCharacters(in: .whitespaces).isEmpty && selection.length == 0 {
            let remove = indent.hasSuffix(indentUnit) ? String(indent.dropLast(indentUnit.count)) : indent
            let replacement = quote + remove
            return ListEdit(range: NSRange(location: line.location, length: contentEnd - line.location), replacement: replacement,
                            selection: NSRange(location: line.location + (replacement as NSString).length, length: 0))
        }
        var nextMarker = marker
        if marker.last == "." || marker.last == ")" {
            guard let number = Int(marker.dropLast()) else { return nil }
            let (next, overflow) = number.addingReportingOverflow(1)
            guard !overflow else { return nil }
            nextMarker = "\(next)\(marker.last!)"
        }
        let replacement = newline + quote + indent + nextMarker + " " + (task ? "[ ] " : "")
        return ListEdit(range: selection, replacement: replacement,
                        selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
    }

    static func isListOutsideCode(in text: NSString, at location: Int) -> Bool {
        guard location <= text.length else { return false }
        let line = markdownLine(in: text, at: location)
        let raw = text.substring(with: line) as NSString
        guard let item = itemMatch(in: raw) else { return false }
        let indent = raw.substring(with: item.range(at: 2))
        return !isInCode(in: text, lineStart: line.location, indentation: indent)
    }

    static func isUnorderedList(in text: NSString, at location: Int) -> Bool {
        guard location <= text.length else { return false }
        let line = markdownLine(in: text, at: location)
        let raw = text.substring(with: line) as NSString
        guard let item = itemMatch(in: raw) else { return false }
        let marker = raw.substring(with: item.range(at: 3))
        return marker == "-" || marker == "+" || marker == "*"
    }

    static func isUnorderedRoot(in text: NSString, at location: Int) -> Bool {
        guard isUnorderedList(in: text, at: location) else { return false }
        let line = markdownLine(in: text, at: location)
        let raw = text.substring(with: line) as NSString
        guard let item = itemMatch(in: raw) else { return false }
        return item.range(at: 2).length == 0
    }

    private static func hasPreviousSibling(in text: NSString, lineStart: Int, quote: String, indent: String, marker: String, unit: String) -> Bool {
        let quoteColumn = advanceColumns(quote)
        let width = advanceColumns(indent, from: quoteColumn) - quoteColumn
        let targetWidth = advanceColumns(indent + unit, from: quoteColumn) - quoteColumn
        var position = lineStart
        while position > 0 {
            let previous = markdownLine(in: text, at: position - 1)
            let raw = text.substring(with: previous) as NSString
            guard raw.hasPrefix(quote) else { return false }
            let offset = (quote as NSString).length
            var end = offset
            while end < raw.length && (raw.character(at: end) == 32 || raw.character(at: end) == 9) { end += 1 }
            let remainder = raw.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty { return false }
            let previousWidth = advanceColumns(raw.substring(with: NSRange(location: offset, length: end - offset)), from: quoteColumn) - quoteColumn
            if previousWidth < width { return false }
            if previousWidth == width {
                guard let item = itemMatch(in: raw), raw.substring(with: item.range(at: 3)) == marker else { return false }
                let content = listColumns(raw, item: item).content
                return targetWidth >= content && targetWidth < content + 4
            }
            if previous.location >= position { return false }
            position = previous.location
        }
        return false
    }

    static func unorderedIndentEdit(in text: NSString, selection: NSRange, indentUnit: String, outdent: Bool) -> ListEdit? {
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let line = markdownLine(in: text, at: selection.location)
        let raw = text.substring(with: line) as NSString
        guard let item = itemMatch(in: raw) else { return nil }
        let marker = raw.substring(with: item.range(at: 3))
        guard marker == "-" || marker == "+" || marker == "*" else { return nil }
        let quote = raw.substring(with: item.range(at: 1))
        let indentation = raw.substring(with: item.range(at: 2))
        guard !isInCode(in: text, lineStart: line.location, indentation: indentation) else { return nil }
        if outdent && indentation.isEmpty { return nil }
        if !outdent && !hasPreviousSibling(in: text, lineStart: line.location, quote: quote, indent: indentation, marker: marker, unit: indentUnit) { return nil }
        let unit = indentUnit as NSString
        let remove = outdent ? min(item.range(at: 2).length, unit.length) : 0
        let prefixLocation = line.location + item.range(at: 2).location
        var edits: [OrderedListEdit] = [OrderedListEdit(range: NSRange(location: prefixLocation, length: remove), replacement: outdent ? "" : indentUnit)]
        var end = NSMaxRange(line)
        var blankLines = 0
        while end < text.length {
            let next = markdownLine(in: text, at: end)
            let nextRaw = text.substring(with: next) as NSString
            guard nextRaw.hasPrefix(quote) else {
                if quote.isEmpty { break }
                return nil
            }
            let offset = (quote as NSString).length
            var spaces = 0
            while offset + spaces < nextRaw.length && (nextRaw.character(at: offset + spaces) == 32 || nextRaw.character(at: offset + spaces) == 9) { spaces += 1 }
            let remainder = nextRaw.substring(from: offset + spaces).trimmingCharacters(in: .newlines)
            if remainder.isEmpty {
                blankLines += 1
                if blankLines > 1 { return nil }
                if NSMaxRange(next) <= end { break }
                end = NSMaxRange(next)
                continue
            }
            blankLines = 0
            let nextIndent = indentationWidth(nextRaw.substring(with: NSRange(location: offset, length: spaces)))
            if nextIndent <= indentationWidth(indentation) { break }
            if outdent && (spaces < remove || nextRaw.substring(with: NSRange(location: offset, length: remove)) != (indentation as NSString).substring(to: remove)) { return nil }
            edits.append(OrderedListEdit(range: NSRange(location: end + offset, length: outdent ? remove : 0), replacement: outdent ? "" : indentUnit))
            if NSMaxRange(next) <= end { break }
            end = NSMaxRange(next)
        }
        let range = NSRange(location: line.location, length: end - line.location)
        let result = NSMutableString(string: text.substring(with: range))
        for edit in edits.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.range.location - range.location, length: edit.range.length), with: edit.replacement)
        }
        let delta = (outdent ? -remove : unit.length)
        return ListEdit(range: range, replacement: result as String,
                        selection: NSRange(location: max(prefixLocation, selection.location + delta), length: 0))
    }

    struct OrderedListEdit {
        let range: NSRange
        let replacement: String
    }

    static func indentationEdit(
        in text: NSString,
        at location: Int,
        indentUnit: String,
        outdent: Bool
    ) -> [OrderedListEdit]? {
        let safeLocation = min(max(location, 0), text.length)
        let lineRange = text.lineRange(for: NSRange(location: safeLocation, length: 0))
        let raw = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let item = orderedItem(in: raw, lineStart: lineRange.location) else { return nil }
        let prefixLength = (raw as NSString).range(of: "^[ \\t]*", options: .regularExpression).length
        let unitLength = (indentUnit as NSString).length
        var edits: [OrderedListEdit] = []
        if outdent {
            guard prefixLength > 0 else { return nil }
            let remove = min(prefixLength, unitLength)
            edits.append(OrderedListEdit(
                range: NSRange(location: lineRange.location, length: remove),
                replacement: ""
            ))
            let targetIndent = max(0, item.indentWidth - unitLength)
            var expectedNumber = 1
            var previousSiblingNumber: Int?
            var scanRange = previousLineRange(before: lineRange, in: text)
            while let candidateRange = scanRange {
                let candidateRaw = text.substring(with: candidateRange)
                    .trimmingCharacters(in: .newlines)
                if let previous = orderedItem(in: candidateRaw, lineStart: candidateRange.location),
                   previous.delimiter == item.delimiter {
                    if previous.indentWidth == targetIndent {
                        previousSiblingNumber = previous.number
                        break
                    }
                    if previous.indentWidth < targetIndent { break }
                }
                scanRange = previousLineRange(before: candidateRange, in: text)
            }
            if let previousSiblingNumber {
                let (next, overflow) = previousSiblingNumber.addingReportingOverflow(1)
                guard !overflow else { return edits }
                expectedNumber = next
            }
            edits.append(OrderedListEdit(
                range: item.numberRange,
                replacement: String(expectedNumber)
            ))
        } else {
            // Replace the indentation and marker in one operation. Keeping
            // both edits at the same location can otherwise turn `4.` into
            // `14.` when AppKit applies the edits in an unspecified order.
            let markerEnd = NSMaxRange(item.numberRange)
            let markerRange = NSRange(
                location: lineRange.location,
                length: markerEnd - lineRange.location
            )
            edits.append(OrderedListEdit(
                range: markerRange,
                replacement: indentUnit + "1"
            ))
        }
        return edits
    }

    static func normalizeNestedLists(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var counters: [Int: Int] = [:]
        var output: [String] = []
        for line in lines {
            guard let match = firstMatch(
                expression: orderedItemExpression,
                in: line
            ) else {
                counters.removeAll()
                output.append(line)
                continue
            }
            let indent = match[1]
            let width = indent.reduce(into: 0) { value, character in
                value += character == "\t" ? 4 : 1
            }
            counters = counters.filter { $0.key <= width }
            let expected = (counters[width] ?? 0) + 1
            counters[width] = expected
            let nsLine = line as NSString
            let numberRange = nsLine.range(
                of: match[2],
                options: [],
                range: NSRange(location: indent.utf16.count, length: nsLine.length - indent.utf16.count)
            )
            guard numberRange.location != NSNotFound else {
                output.append(line)
                continue
            }
            let prefix = nsLine.substring(to: numberRange.location)
            let suffix = nsLine.substring(from: NSMaxRange(numberRange))
            output.append(prefix + String(expected) + suffix)
        }
        return output.joined(separator: "\n")
    }

    struct OrderedListNormalization {
        let text: String
        let edits: [OrderedListEdit]

        func mappedLocation(for location: Int) -> Int {
            edits.reduce(location) { mappedLocation, edit in
                guard edit.range.location < location else { return mappedLocation }
                if NSMaxRange(edit.range) <= location {
                    return mappedLocation
                        + (edit.replacement as NSString).length
                        - edit.range.length
                }
                return edit.range.location + (edit.replacement as NSString).length
            }
        }
    }

    static func continuation(for linePrefix: String) -> String? {
        let content = linePrefix.drop { $0 == " " || $0 == "\t" }

        if let ordered = firstMatch(
            expression: continuationOrderedExpression,
            in: String(content)
        ), let number = Int(ordered[1]) {
            let (next, overflow) = number.addingReportingOverflow(1)
            guard !overflow else { return nil }
            return "\(next)\(ordered[2]) "
        }

        if let unordered = firstMatch(
            expression: continuationUnorderedExpression,
            in: String(content)
        ) {
            return "\(unordered[1]) "
        }

        return nil
    }

    static func isEmptyListItem(_ linePrefix: String) -> Bool {
        let content = linePrefix.drop { $0 == " " || $0 == "\t" }
        let value = String(content)
        return emptyItemExpression.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil
    }

    static func isManualOrderedMarkerEdit(
        in text: String,
        range: NSRange,
        replacement: String
    ) -> Bool {
        isManualOrderedMarkerEdit(
            in: text as NSString,
            range: range,
            replacement: replacement
        )
    }

    static func isManualOrderedMarkerEdit(
        in nsText: NSString,
        range: NSRange,
        replacement: String
    ) -> Bool {
        guard !replacement.contains("\n") else { return false }
        let safeRange = boundedRange(range, textLength: nsText.length)
        guard !nsText.substring(with: safeRange).contains("\n") else {
            return false
        }
        let safeLocation = min(range.location, nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
        let line = nsText.substring(with: lineRange)
            .trimmingCharacters(in: .newlines)
        guard let item = orderedItem(in: line, lineStart: lineRange.location) else {
            return false
        }

        let numberRange = item.numberRange
        if range.length == 0 {
            return range.location >= numberRange.location
                && range.location <= NSMaxRange(numberRange)
        }
        return NSIntersectionRange(range, numberRange).length > 0
    }

    static func shouldNormalizeOrderedListEdit(
        in text: String,
        range: NSRange,
        replacement: String
    ) -> Bool {
        shouldNormalizeOrderedListEdit(
            in: text as NSString,
            range: range,
            replacement: replacement
        )
    }

    static func shouldNormalizeOrderedListEdit(
        in nsText: NSString,
        range: NSRange,
        replacement: String
    ) -> Bool {
        let safeRange = boundedRange(range, textLength: nsText.length)
        let removedText = nsText.substring(with: safeRange)
        guard replacement.contains("\n") || removedText.contains("\n") else {
            return false
        }

        // A multi-line paste carries explicit numbering chosen by the user.
        // Preserve it instead of treating it as a single inserted list item.
        if replacement.contains("\n"), !replacement.hasPrefix("\n") {
            return false
        }

        // LacTextView already creates the correct next marker on Return. At the
        // end of the document there are no following items that need reflowing.
        if safeRange.length == 0,
           safeRange.location == nsText.length,
           replacement.hasPrefix("\n") {
            return false
        }

        return true
    }

    static func normalizeOrderedList(
        in text: String,
        aroundUTF16Location location: Int
    ) -> OrderedListNormalization? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        let boundedLocation = min(max(location, 0), nsText.length)
        let anchorLocation = min(boundedLocation, max(0, nsText.length - 1))
        let anchorRange = nsText.lineRange(
            for: NSRange(location: anchorLocation, length: 0)
        )
        let nearbyRanges = [
            anchorRange,
            nextLineRange(after: anchorRange, in: nsText),
            previousLineRange(before: anchorRange, in: nsText)
        ].compactMap { $0 }
        guard let candidate = nearbyRanges.compactMap({ range in
            orderedItem(in: nsText, lineRange: range)
        }).first else { return nil }

        var before: [OrderedItem] = []
        var range = previousLineRange(
            before: nsText.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: nsText
        )
        while let currentRange = range {
            let scan = scanLine(
                currentRange,
                in: nsText,
                matching: candidate
            )
            if let item = scan.item { before.append(item) }
            if scan.stopsSequence { break }
            range = previousLineRange(before: currentRange, in: nsText)
        }

        var after: [OrderedItem] = []
        range = nextLineRange(
            after: nsText.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: nsText
        )
        while let currentRange = range {
            let scan = scanLine(
                currentRange,
                in: nsText,
                matching: candidate
            )
            if let item = scan.item { after.append(item) }
            if scan.stopsSequence { break }
            range = nextLineRange(after: currentRange, in: nsText)
        }

        let sequence = Array(before.reversed()) + [candidate] + after
        guard sequence.count > 1 else { return nil }
        let startingNumber = sequence[0].number
        guard !startingNumber.addingReportingOverflow(sequence.count - 1).overflow else { return nil }
        let edits = sequence.enumerated().compactMap { index, item -> OrderedListEdit? in
            let expectedNumber = startingNumber + index
            guard item.number != expectedNumber else { return nil }
            return OrderedListEdit(
                range: item.numberRange,
                replacement: String(expectedNumber)
            )
        }
        guard !edits.isEmpty else { return nil }

        let mutableText = NSMutableString(string: text)
        for edit in edits.reversed() {
            mutableText.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return OrderedListNormalization(text: mutableText as String, edits: edits)
    }

    static func orderedListExceedsBackgroundThreshold(
        in text: NSString,
        aroundUTF16Location location: Int,
        threshold: Int = 500
    ) -> Bool {
        guard text.length > 0, threshold > 0 else { return false }
        let anchor = min(max(location, 0), text.length - 1)
        let anchorRange = text.lineRange(for: NSRange(location: anchor, length: 0))
        let nearbyRanges = [
            anchorRange,
            nextLineRange(after: anchorRange, in: text),
            previousLineRange(before: anchorRange, in: text)
        ].compactMap { $0 }
        guard let candidate = nearbyRanges.compactMap({ range in
            orderedItem(in: text, lineRange: range)
        }).first else { return false }

        var count = 1
        var range = previousLineRange(
            before: text.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: text
        )
        while let currentRange = range {
            let scan = scanLine(currentRange, in: text, matching: candidate)
            if scan.item != nil {
                count += 1
                if count > threshold { return true }
            }
            if scan.stopsSequence { break }
            range = previousLineRange(before: currentRange, in: text)
        }
        range = nextLineRange(
            after: text.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: text
        )
        while let currentRange = range {
            let scan = scanLine(currentRange, in: text, matching: candidate)
            if scan.item != nil {
                count += 1
                if count > threshold { return true }
            }
            if scan.stopsSequence { break }
            range = nextLineRange(after: currentRange, in: text)
        }
        return false
    }

    private static func orderedItem(
        in text: NSString,
        lineRange: NSRange
    ) -> OrderedItem? {
        let contentRange = text.lineRange(for: lineRange)
        let line = text.substring(with: contentRange)
            .trimmingCharacters(in: .newlines)
        return orderedItem(in: line, lineStart: contentRange.location)
    }

    private static func scanLine(
        _ lineRange: NSRange,
        in text: NSString,
        matching candidate: OrderedItem
    ) -> (item: OrderedItem?, stopsSequence: Bool) {
        let rawLine = text.substring(with: lineRange)
            .trimmingCharacters(in: .newlines)
        if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return (nil, false)
        }
        if let item = orderedItem(in: rawLine, lineStart: lineRange.location) {
            if item.indentWidth == candidate.indentWidth,
               item.delimiter == candidate.delimiter {
                return (item, false)
            }
            return (nil, item.indentWidth <= candidate.indentWidth)
        }
        let indentation = rawLine.prefix { $0 == " " || $0 == "\t" }
        let width = indentation.reduce(into: 0) { total, character in
            total += character == "\t" ? 4 : 1
        }
        return (nil, width <= candidate.indentWidth)
    }

    private static func previousLineRange(
        before lineRange: NSRange,
        in text: NSString
    ) -> NSRange? {
        guard lineRange.location > 0 else { return nil }
        return text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
    }

    private static func nextLineRange(
        after lineRange: NSRange,
        in text: NSString
    ) -> NSRange? {
        let nextLocation = NSMaxRange(lineRange)
        guard nextLocation < text.length else { return nil }
        return text.lineRange(for: NSRange(location: nextLocation, length: 0))
    }

    private struct OrderedItem {
        let lineIndex: Int
        let indentWidth: Int
        let number: Int
        let delimiter: String
        let numberRange: NSRange
    }

    private static func orderedItem(
        in line: String,
        lineStart: Int,
        lineIndex: Int = 0
    ) -> OrderedItem? {
        guard let match = firstMatch(
            expression: orderedItemExpression,
            in: line
        ), let number = Int(match[2]) else {
            return nil
        }

        let nsLine = line as NSString
        let searchStart = (match[1] as NSString).length
        let numberRangeInLine = nsLine.range(
            of: match[2],
            options: [],
            range: NSRange(location: searchStart, length: nsLine.length - searchStart)
        )
        guard numberRangeInLine.location != NSNotFound else { return nil }

        let indentWidth = match[1].reduce(into: 0) { width, character in
            width += character == "\t" ? 4 : 1
        }
        return OrderedItem(
            lineIndex: lineIndex,
            indentWidth: indentWidth,
            number: number,
            delimiter: match[3],
            numberRange: NSRange(
                location: lineStart + numberRangeInLine.location,
                length: numberRangeInLine.length
            )
        )
    }

    private static func boundedRange(
        _ range: NSRange,
        textLength: Int
    ) -> NSRange {
        let location = min(range.location, textLength)
        let length = min(range.length, textLength - location)
        return NSRange(location: location, length: length)
    }

    private static func firstMatch(
        expression: NSRegularExpression,
        in value: String
    ) -> [String]? {
        guard let match = expression.firstMatch(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length)
              ) else { return nil }

        let nsValue = value as NSString
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : nsValue.substring(with: range)
        }
    }
}
