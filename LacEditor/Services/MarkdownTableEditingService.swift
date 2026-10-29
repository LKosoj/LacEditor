import Foundation
import cmark_gfm
import cmark_gfm_extensions

enum MarkdownTableCommand: Equatable {
    case create(rows: Int, columns: Int)
    case insertRowBefore, insertRowAfter, deleteRow, moveRowUp, moveRowDown
    case insertColumnBefore, insertColumnAfter, deleteColumn, moveColumnLeft, moveColumnRight
    case align(MarkdownTableAlignment)
}

enum MarkdownTableEditingService {
    static func move(in text: NSString, selection: NSRange, rows: Bool, positions: Int) -> MarkdownFormattingEdit? {
        guard positions != 0, positions != Int.min else { return nil }
        let command: MarkdownTableCommand = rows
            ? (positions < 0 ? .moveRowUp : .moveRowDown)
            : (positions < 0 ? .moveColumnLeft : .moveColumnRight)
        var current = text as String, selected = selection
        var originalRange: NSRange?
        for _ in 0..<abs(positions) {
            let value = current as NSString
            guard let edit = Self.edit(in: value, selection: selected, command: command) else { return nil }
            if originalRange == nil { originalRange = edit.range }
            current = value.replacingCharacters(in: edit.range, with: edit.replacement)
            selected = edit.selectionRange
        }
        guard let range = originalRange else { return nil }
        let updated = current as NSString
        let length = range.length + updated.length - text.length
        guard length >= 0, range.location <= updated.length, length <= updated.length - range.location else { return nil }
        return MarkdownFormattingEdit(range: range, replacement: updated.substring(with: NSRange(location: range.location, length: length)),
                                      selectionRange: selected)
    }

    private struct Line {
        var content: String
        var ending: String
        let start: Int
    }

    private struct Row {
        var leading: String
        var trailing: String
        var cells: [String]
        var ending: String

        var text: String { leading + cells.joined(separator: "|") + trailing }
    }

    private struct TableBounds {
        let first: Int
        let last: Int
        let selected: Int
        let firstPrefix: Int
        let quoteDepth: Int
        let nestedList: Bool
    }

    static func edit(in text: NSString, selection: NSRange, command: MarkdownTableCommand, columnOverride: Int? = nil) -> MarkdownFormattingEdit? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location,
              validBoundary(selection.location, text), validBoundary(NSMaxRange(selection), text) else { return nil }
        let lines = sourceLines(text)
        if case let .create(rows, columns) = command {
            guard rows >= 0, columns > 0, selection.length == 0,
                  let index = lines.firstIndex(where: { selection.location >= $0.start && selection.location <= $0.start + ($0.content as NSString).length }) else { return nil }
            let line = lines[index]
            guard line.content.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.content.contains("\t"), (line.content as NSString).length < 4,
                  isOutsideBlocks(text as String, line: index + 1) else { return nil }
            let newline = line.ending.isEmpty ? (lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n") : line.ending
            let header = "|" + String(repeating: "   |", count: columns)
            let delimiter = "|" + String(repeating: " --- |", count: columns)
            let body = Array(repeating: header, count: rows)
            let before = index > 0 && !lines[index - 1].content.trimmingCharacters(in: .whitespaces).isEmpty ? newline : ""
            let after = index + 1 < lines.count && !lines[index + 1].content.trimmingCharacters(in: .whitespaces).isEmpty ? newline : ""
            let replacement = before + ([header, delimiter] + body).joined(separator: newline) + after
            let range = NSRange(location: line.start, length: (line.content as NSString).length)
            let caret = NSRange(location: line.start + (before as NSString).length + 2, length: 0)
            let candidate = text.replacingCharacters(in: range, with: replacement)
            guard tableLines(candidate, selection: caret, lines: sourceLines(candidate as NSString)) != nil else { return nil }
            return MarkdownFormattingEdit(range: range, replacement: replacement, selectionRange: caret)
        }
        guard let bounds = tableLines(text as String, selection: selection, lines: lines),
              bounds.last > bounds.first + 0 else { return nil }
        var rows: [Row] = []
        for index in bounds.first...bounds.last {
            guard let row = parseTableRow(lines[index], prefix: index == bounds.first ? bounds.firstPrefix : nil,
                                          quoteDepth: bounds.quoteDepth, nestedList: bounds.nestedList) else { return nil }
            rows.append(row)
        }
        guard rows.count >= 2, rows[0].cells.count == rows[1].cells.count else { return nil }
        let columnCount = rows[0].cells.count
        guard columnCount > 0 else { return nil }
        let selectedLine = bounds.selected - bounds.first
        guard selectedLine != 1 else { return nil }
        let rowStart = lines[bounds.selected].start
        let localSelection = selection.location - rowStart
        guard let column = columnOverride ?? selectedColumn(in: rows[selectedLine], at: localSelection),
              column >= 0, column < columnCount else { return nil }
        let row = rows[selectedLine]
        let cellStart: Int
        let withinCell: Int
        if column < row.cells.count {
            cellStart = cellOffset(row, column)
            guard localSelection >= cellStart,
                  localSelection + selection.length <= cellStart + (row.cells[column] as NSString).length else { return nil }
            withinCell = localSelection - cellStart
        } else {
            guard selection.length == 0, let last = row.cells.indices.last else { return nil }
            cellStart = cellOffset(row, last) + (row.cells[last] as NSString).length
            guard localSelection == cellStart else { return nil }
            withinCell = 0
        }
        var targetRow = selectedLine, targetColumn = column, targetOffset = withinCell, targetLength = selection.length
        func transformColumns(_ transform: (inout [String?], Int) -> Void) -> Bool {
            var transformed: [[String]] = []
            for (index, row) in rows.enumerated() {
                if row.cells.count != columnCount && row.cells.contains(where: { hasUnmatchedBackticks($0 as NSString) }) { return false }
                let existing = Array(row.cells.prefix(columnCount))
                let extra = Array(row.cells.dropFirst(columnCount))
                var visible: [String?] = existing.map { Optional($0) }
                visible.append(contentsOf: repeatElement(nil, count: columnCount - existing.count))
                transform(&visible, index)
                if extra.isEmpty {
                    while visible.last == .some(nil) { visible.removeLast() }
                }
                if visible.isEmpty {
                    guard row.leading.contains("|") || !row.trailing.isEmpty else { return false }
                    visible = [""]
                }
                transformed.append(visible.map { $0 ?? "" } + extra)
            }
            for index in rows.indices { rows[index].cells = transformed[index] }
            return true
        }
        switch command {
        case .create: return nil
        case .insertRowBefore, .insertRowAfter:
            guard selectedLine >= 2 || (selectedLine == 0 && rows.count == 2 && isAfter(command)) else { return nil }
            let position = selectedLine == 0 ? 2 : selectedLine + (isAfter(command) ? 1 : 0)
            let template = selectedLine == 0 && (bounds.quoteDepth > 0 || bounds.nestedList) ? rows[1] : rows[selectedLine]
            var inserted = Row(leading: template.leading, trailing: template.trailing,
                               cells: Array(repeating: "   ", count: columnCount), ending: preferredEnding(lines, first: bounds.first, last: bounds.last))
            if columnCount == 1 && !inserted.leading.contains("|") && inserted.trailing.isEmpty {
                inserted.leading += "|"
                inserted.trailing = "|"
            }
            if position == rows.count && rows[rows.count - 1].ending.isEmpty {
                rows[rows.count - 1].ending = preferredEnding(lines, first: bounds.first, last: bounds.last)
                inserted.ending = ""
            }
            rows.insert(inserted, at: position)
            targetRow = position; targetOffset = 1; targetLength = 0
        case .deleteRow:
            guard selectedLine >= 2 else { return nil }
            let removed = rows.remove(at: selectedLine)
            if selectedLine == rows.count, removed.ending.isEmpty { rows[rows.count - 1].ending = "" }
            targetRow = selectedLine < rows.count ? selectedLine : (rows.count > 2 ? rows.count - 1 : 0)
            targetOffset = 0; targetLength = 0
        case .moveRowUp, .moveRowDown:
            guard selectedLine >= 2 else { return nil }
            let other = selectedLine + (isUp(command) ? -1 : 1)
            guard other >= 2, other < rows.count else { return nil }
            let firstEnding = rows[selectedLine].ending, secondEnding = rows[other].ending
            rows.swapAt(selectedLine, other)
            rows[selectedLine].ending = firstEnding; rows[other].ending = secondEnding
            targetRow = other
        case .insertColumnBefore, .insertColumnAfter:
            let position = column + (isAfter(command) ? 1 : 0)
            guard transformColumns({ $0.insert($1 == 1 ? " --- " : "   ", at: position) }) else { return nil }
            targetColumn = position; targetOffset = 1; targetLength = 0
        case .deleteColumn:
            guard columnCount > 1 else { return nil }
            guard transformColumns({ cells, _ in _ = cells.remove(at: column) }) else { return nil }
            if columnCount == 2 {
                for i in rows.indices where !rows[i].leading.contains("|") && rows[i].trailing.isEmpty {
                    rows[i].trailing = "|"
                }
            }
            targetColumn = min(column, columnCount - 2); targetOffset = 0; targetLength = 0
        case .moveColumnLeft, .moveColumnRight:
            let other = column + (isLeft(command) ? -1 : 1)
            guard other >= 0, other < columnCount else { return nil }
            guard transformColumns({ $0.swapAt(column, other) }) else { return nil }
            targetColumn = other
        case let .align(alignment):
            let marker: String
            switch alignment {
            case .unspecified: marker = "---"
            case .left: marker = ":---"
            case .center: marker = ":---:"
            case .right: marker = "---:"
            }
            let old = rows[1].cells[column] as NSString
            var start = 0, end = old.length
            while start < end && (old.character(at: start) == 32 || old.character(at: start) == 9) { start += 1 }
            while end > start && (old.character(at: end - 1) == 32 || old.character(at: end - 1) == 9) { end -= 1 }
            rows[1].cells[column] = old.substring(to: start) + marker + old.substring(from: end)
        }
        let tableStart = lines[bounds.first].start
        let lastLine = lines[bounds.last]
        let tableEnd = lastLine.start + (lastLine.content as NSString).length + (lastLine.ending as NSString).length
        let replacement = rows.map { $0.text + $0.ending }.joined()
        let preceding = rows.prefix(targetRow).reduce(0) { $0 + (($1.text + $1.ending) as NSString).length }
        targetColumn = min(targetColumn, rows[targetRow].cells.count - 1)
        let targetStart = tableStart + preceding + cellOffset(rows[targetRow], targetColumn)
        let length = (rows[targetRow].cells[targetColumn] as NSString).length
        let offset = min(targetOffset, length)
        return MarkdownFormattingEdit(range: NSRange(location: tableStart, length: tableEnd - tableStart), replacement: replacement,
                                      selectionRange: NSRange(location: targetStart + offset, length: min(targetLength, length - offset)))
    }

    // The parser has already confirmed a top-level table with cmark.
    static func presentationTable(in source: NSString, range: NSRange, containerPrefix: String = "",
                                  quoteDepth: Int = 0, nestedList: Bool = false) -> MarkdownTable? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let lines = sourceLines(source.substring(with: range) as NSString)
        guard lines.count >= 2, !lines.contains(where: { $0.content.contains("\t") }) else { return nil }
        let rows = lines.enumerated().compactMap { index, line in
            parseTableRow(line, prefix: index == 0 ? 0 : nil, quoteDepth: quoteDepth, nestedList: nestedList)
        }
        guard rows.count == lines.count, rows[0].cells.count == rows[1].cells.count,
              !rows[0].cells.isEmpty else { return nil }
        let alignments: [MarkdownTableAlignment] = rows[1].cells.map { cell in
            let marker = cell.trimmingCharacters(in: .whitespaces)
            if marker.hasPrefix(":") && marker.hasSuffix(":") { return .center }
            if marker.hasPrefix(":") { return .left }
            if marker.hasSuffix(":") { return .right }
            return .unspecified
        }
        let mapped = rows.indices.filter { $0 != 1 }.map { index in
            let line = lines[index]
            let start = range.location + line.start
            var offset = (rows[index].leading as NSString).length
            var cells = rows[index].cells.indices.prefix(alignments.count).map { column in
                let length = (rows[index].cells[column] as NSString).length
                let cell = MarkdownTableCell(range: NSRange(location: start + offset, length: length), column: column)
                offset += length + 1
                return cell
            }
            if cells.count < alignments.count, let last = cells.last {
                let insertion = NSMaxRange(last.range)
                let actualCount = cells.count
                for column in actualCount..<alignments.count {
                    cells.append(MarkdownTableCell(range: NSRange(location: insertion, length: 0),
                                                   column: column, virtualSeparators: column - actualCount + 1))
                }
            }
            let contentStart = index == 0 ? 0 : (containerPrefixLength(in: line, quoteDepth: quoteDepth, nestedList: nestedList) ?? 0)
            return MarkdownTableRow(range: NSRange(location: start + contentStart,
                                                   length: (line.content as NSString).length - contentStart), cells: cells)
        }
        let delimiter = lines[1]
        return MarkdownTable(range: range,
                             delimiterRange: NSRange(location: range.location + delimiter.start, length: (delimiter.content as NSString).length),
                             alignments: alignments, rows: mapped, containerPrefix: containerPrefix,
                             quoteDepth: quoteDepth, nestedList: nestedList)
    }

    static func presentationRow(in source: NSString, range: NSRange, columns: Int) -> MarkdownTableRow? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= source.length, range.length <= source.length - range.location, columns > 0 else { return nil }
        let content = source.substring(with: range)
        guard !content.contains("\t"), let row = parseRow(Line(content: content, ending: "", start: 0)) else { return nil }
        var offset = (row.leading as NSString).length
        var cells = row.cells.indices.prefix(columns).map { column in
            let length = (row.cells[column] as NSString).length
            let cell = MarkdownTableCell(range: NSRange(location: range.location + offset, length: length), column: column)
            offset += length + 1
            return cell
        }
        if cells.count < columns, let last = cells.last {
            let actualCount = cells.count
            for column in actualCount..<columns {
                cells.append(MarkdownTableCell(range: NSRange(location: NSMaxRange(last.range), length: 0),
                                               column: column, virtualSeparators: column - actualCount + 1))
            }
        }
        return MarkdownTableRow(range: range, cells: cells)
    }

    private static func hasUnmatchedBackticks(_ text: NSString) -> Bool {
        var index = 0, opening = 0
        while index < text.length {
            if text.character(at: index) == 92 && opening == 0 {
                index += min(2, text.length - index)
                continue
            }
            guard text.character(at: index) == 96 else { index += 1; continue }
            var end = index + 1
            while end < text.length && text.character(at: end) == 96 { end += 1 }
            let length = end - index
            if opening == 0 { opening = length }
            else if opening == length { opening = 0 }
            index = end
        }
        return opening != 0
    }

    private static func validBoundary(_ position: Int, _ text: NSString) -> Bool {
        guard position > 0, position < text.length else { return true }
        return !(0xd800...0xdbff).contains(text.character(at: position - 1)) || !(0xdc00...0xdfff).contains(text.character(at: position))
    }

    private static func sourceLines(_ text: NSString) -> [Line] {
        var result: [Line] = [], start = 0, index = 0
        while index < text.length {
            if text.character(at: index) == 10 || text.character(at: index) == 13 {
                let end = index
                if text.character(at: index) == 13 && index + 1 < text.length && text.character(at: index + 1) == 10 { index += 1 }
                index += 1
                result.append(Line(content: text.substring(with: NSRange(location: start, length: end - start)),
                                   ending: text.substring(with: NSRange(location: end, length: index - end)), start: start))
                start = index
            } else { index += 1 }
        }
        result.append(Line(content: text.substring(from: start), ending: "", start: start))
        return result
    }

    private static func tableLines(_ text: String, selection: NSRange, lines: [Line]) -> TableBounds? {
        guard !text.utf8.contains(0), let selected = lines.firstIndex(where: {
            selection.location >= $0.start && NSMaxRange(selection) <= $0.start + ($0.content as NSString).length
        }) else { return nil }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return nil }
        defer { cmark_parser_free(parser) }
        "table".withCString { if let ext = cmark_find_syntax_extension($0) { cmark_parser_attach_syntax_extension(parser, ext) } }
        text.withCString { cmark_parser_feed(parser, $0, text.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }
        func find(_ current: OpaquePointer, quotes: Int, nestedList: Bool) -> TableBounds? {
            guard let name = cmark_node_get_type_string(current) else { return nil }
            let type = String(cString: name)
            if type == "table" {
                let first = Int(cmark_node_get_start_line(current)) - 1
                let last = Int(cmark_node_get_end_line(current)) - 1
                guard first >= 0, last >= first, last < lines.count, selected >= first, selected <= last,
                      !lines[first...last].contains(where: { $0.content.contains("\t") }) else { return nil }
                let column = Int(cmark_node_get_start_column(current)) - 1
                let bytes = Array(lines[first].content.utf8)
                guard column >= 0, column <= bytes.count,
                      let prefix = String(bytes: bytes.prefix(column), encoding: .utf8) else { return nil }
                return TableBounds(first: first, last: last, selected: selected,
                                   firstPrefix: (prefix as NSString).length, quoteDepth: quotes, nestedList: nestedList)
            }
            guard ["document", "block_quote", "list", "item"].contains(type) else { return nil }
            let nextQuotes = quotes + (type == "block_quote" ? 1 : 0)
            let nextList = nestedList || type == "list" || type == "item"
            var child = cmark_node_first_child(current)
            while let node = child {
                if let found = find(node, quotes: nextQuotes, nestedList: nextList) { return found }
                child = cmark_node_next(node)
            }
            return nil
        }
        return find(root, quotes: 0, nestedList: false)
    }

    private static func parseTableRow(_ line: Line, prefix: Int?, quoteDepth: Int, nestedList: Bool) -> Row? {
        let text = line.content as NSString
        guard let offset = prefix ?? containerPrefixLength(in: line, quoteDepth: quoteDepth, nestedList: nestedList),
              offset <= text.length,
              var row = parseRow(Line(content: text.substring(from: offset), ending: line.ending, start: line.start + offset)) else { return nil }
        row.leading = text.substring(to: offset) + row.leading
        return row
    }

    private static func containerPrefixLength(in line: Line, quoteDepth: Int, nestedList: Bool) -> Int? {
        let text = line.content as NSString
        var offset = 0
        if quoteDepth > 0 || nestedList {
            for _ in 0..<quoteDepth {
                while offset < text.length && text.character(at: offset) == 32 { offset += 1 }
                guard offset < text.length && text.character(at: offset) == 62 else { return nil }
                offset += 1
            }
            while offset < text.length && text.character(at: offset) == 32 { offset += 1 }
        }
        return offset
    }

    private static func isOutsideBlocks(_ text: String, line: Int) -> Bool {
        guard !text.utf8.contains(0), let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return false }
        defer { cmark_parser_free(parser) }
        cmark_gfm_core_extensions_ensure_registered()
        "table".withCString { if let ext = cmark_find_syntax_extension($0) { cmark_parser_attach_syntax_extension(parser, ext) } }
        text.withCString { cmark_parser_feed(parser, $0, text.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return false }
        defer { cmark_node_free(root) }
        var node = cmark_node_first_child(root)
        while let current = node {
            if Int(cmark_node_get_start_line(current)) <= line && line <= Int(cmark_node_get_end_line(current)) { return false }
            node = cmark_node_next(current)
        }
        return true
    }

    private static func parseRow(_ line: Line) -> Row? {
        let value = line.content as NSString
        var start = 0
        while start < value.length && value.character(at: start) == 32 { start += 1 }
        guard start < value.length, value.character(at: start) != 9 else { return nil }
        let leadingPipe = value.character(at: start) == 124
        let leading = value.substring(to: start + (leadingPipe ? 1 : 0))
        var cells: [String] = [], cellStart = start + (leadingPipe ? 1 : 0), i = cellStart
        var trailing = ""
        var lastNonWhitespace = value.length
        while lastNonWhitespace > 0, let scalar = UnicodeScalar(value.character(at: lastNonWhitespace - 1)), CharacterSet.whitespaces.contains(scalar) { lastNonWhitespace -= 1 }
        while i < value.length {
            if value.character(at: i) == 92 && i + 1 < value.length {
                let next = value.character(at: i + 1)
                if next == 124 || next == 92 { i += 2; continue }
            }
            if value.character(at: i) == 124 {
                cells.append(value.substring(with: NSRange(location: cellStart, length: i - cellStart)))
                cellStart = i + 1
                if cellStart >= lastNonWhitespace {
                    trailing = value.substring(from: i); cellStart = value.length; break
                }
            }
            i += 1
        }
        if cellStart < value.length || trailing.isEmpty { cells.append(value.substring(from: cellStart)) }
        guard !cells.isEmpty else { return nil }
        return Row(leading: leading, trailing: trailing, cells: cells, ending: line.ending)
    }

    private static func cellOffset(_ row: Row, _ column: Int) -> Int {
        (row.leading as NSString).length + row.cells.prefix(column).reduce(0) { $0 + ($1 as NSString).length + 1 }
    }

    private static func selectedColumn(in row: Row, at location: Int) -> Int? {
        for index in row.cells.indices {
            let start = cellOffset(row, index), end = start + (row.cells[index] as NSString).length
            if location >= start && location <= end { return index }
        }
        return nil
    }

    private static func preferredEnding(_ lines: [Line], first: Int, last: Int) -> String {
        lines[first...last].first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
    }
    private static func isAfter(_ command: MarkdownTableCommand) -> Bool {
        switch command { case .insertRowAfter, .insertColumnAfter: true; default: false }
    }
    private static func isUp(_ command: MarkdownTableCommand) -> Bool {
        if case .moveRowUp = command { return true }; return false
    }
    private static func isLeft(_ command: MarkdownTableCommand) -> Bool {
        if case .moveColumnLeft = command { return true }; return false
    }
}
