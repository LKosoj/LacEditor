import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Per-parser cmark hooks. Positions are cmark's one-based byte columns;
/// callers must translate them with the shared Markdown source mapping.
final class MarkdownMathExtension {
    struct Inline {
        let node: OpaquePointer
        let parent: OpaquePointer
        let line: Int
        let column: Int
        let byteLength: Int
        let text: String
    }

    private final class Context {
        let closingLines: [Int: Int]
        let quoteOffsets: [Int: Int]
        let listOffsets: [Int: Int]
        let taskOffsets: [Int: (checkboxEnd: Int, math: Int, checked: Bool)]
        var inline: [Inline] = []
        var textOrigins: [MarkdownTextSourceCapture.Origin] = []
        var looseHeadings: [OpaquePointer: Int] = [:]
        var looseListRanges: [OpaquePointer: NSRange] = [:]
        var looseIndents: [MarkdownLooseIndent] = []
        let capturesText: Bool
        let legacyInlineMath: Bool

        init(_ source: String, legacyInlineMath: Bool) {
            self.legacyInlineMath = legacyInlineMath
            let bytes = Array(source.utf8)
            capturesText = bytes.contains { $0 == 64 || $0 == 38 }
            var delimiters: [Int] = [], line = 1, start = 0, i = 0
            var quoteClosing: [Int: Int] = [:], quoteOffsets: [Int: Int] = [:]
            var previousQuoteDepth = 0, previousQuoteDelimiter: Int?
            var listClosing: [Int: Int] = [:], listOffsets: [Int: Int] = [:]
            var taskOffsets: [Int: (checkboxEnd: Int, math: Int, checked: Bool)] = [:]
            var pendingList: (line: Int, column: Int, quoteDepth: Int)?
            while i <= bytes.count {
                if i == bytes.count || bytes[i] == 10 || bytes[i] == 13 {
                    if i - start == 2, bytes[start] == 36, bytes[start + 1] == 36 { delimiters.append(line) }
                    var cursor = start, quoteDepth = 0
                    while cursor < i, cursor - start < 3, bytes[cursor] == 32 { cursor += 1 }
                    if cursor == i || bytes[cursor] != 62 { cursor = start }
                    while cursor < i, bytes[cursor] == 62 {
                        quoteDepth += 1
                        cursor += 1
                        if cursor < i, bytes[cursor] == 32 { cursor += 1 }
                    }
                    if quoteDepth == 0 || quoteDepth != previousQuoteDepth { previousQuoteDelimiter = nil }
                    previousQuoteDepth = quoteDepth
                    if quoteDepth > 0, i - cursor == 2, bytes[cursor] == 36, bytes[cursor + 1] == 36 {
                        if let previousQuoteDelimiter { quoteClosing[previousQuoteDelimiter] = line }
                        previousQuoteDelimiter = line
                        quoteOffsets[line] = cursor - start
                    }
                    let listBase = quoteDepth > 0 ? cursor : start
                    if let pending = pendingList {
                        var content = listBase
                        var column = listBase - start
                        while content < i, column < pending.column, bytes[content] == 32 || bytes[content] == 9 {
                            column = bytes[content] == 9 ? (column / 4 + 1) * 4 : column + 1
                            content += 1
                        }
                        if column < pending.column { content = listBase }
                        if quoteDepth == pending.quoteDepth, bytes[listBase..<i].allSatisfy({ $0 == 32 || $0 == 9 }) {
                            // cmark keeps an item open across blank lines.
                        } else if quoteDepth == pending.quoteDepth, content > listBase {
                            if i - content == 2, bytes[content] == 36, bytes[content + 1] == 36 {
                                listClosing[pending.line] = line
                                pendingList = nil
                            }
                        } else { pendingList = nil }
                    }
                    if pendingList == nil {
                        var markerEnd = listBase
                        var markerColumn = listBase - start
                        while markerEnd < i, bytes[markerEnd] == 32 || bytes[markerEnd] == 9 {
                            if bytes[markerEnd] == 9 { markerColumn = (markerColumn / 4 + 1) * 4 }
                            else { markerColumn += 1 }
                            markerEnd += 1
                        }
                        let markerStart = markerEnd
                        if markerEnd < i, [UInt8(45), 43, 42].contains(bytes[markerEnd]) { markerEnd += 1 }
                        else {
                            while markerEnd < i, (48...57).contains(bytes[markerEnd]), markerEnd - markerStart < 9 { markerEnd += 1 }
                            if markerEnd == markerStart || markerEnd >= i || (bytes[markerEnd] != 46 && bytes[markerEnd] != 41) { markerEnd = markerStart }
                            else { markerEnd += 1 }
                        }
                        var content = markerEnd
                        while content < i, bytes[content] == 32, content - markerEnd < 4 { content += 1 }
                        let contentColumn = markerColumn + content - markerStart
                        if markerEnd > markerStart, content > markerEnd, content + 6 == i,
                           bytes[content] == 91, [UInt8(32), 88, 120].contains(bytes[content + 1]),
                           bytes[content + 2] == 93, bytes[content + 3] == 32,
                           bytes[content + 4] == 36, bytes[content + 5] == 36 {
                            pendingList = (line, contentColumn, quoteDepth)
                            listOffsets[line] = content + 4 - start
                            taskOffsets[line] = (content + 3 - start, content + 4 - start, bytes[content + 1] != 32)
                        } else if markerEnd > markerStart, content > markerEnd, content + 2 == i,
                           bytes[content] == 36, bytes[content + 1] == 36 {
                            pendingList = (line, contentColumn, quoteDepth)
                            listOffsets[line] = content - start
                        } else if markerEnd > markerStart,
                                  content - markerEnd + 4 - contentColumn % 4 <= 4, content + 3 == i,
                                  bytes[content] == 9, bytes[content + 1] == 36, bytes[content + 2] == 36 {
                            pendingList = (line, (contentColumn / 4 + 1) * 4, quoteDepth)
                            listOffsets[line] = content + 1 - start
                        }
                    }
                    if i == bytes.count { break }
                    if bytes[i] == 13 && i + 1 < bytes.count && bytes[i + 1] == 10 { i += 1 }
                    i += 1; start = i; line += 1
                } else { i += 1 }
            }
            var result: [Int: Int] = [:]
            if delimiters.count > 1 {
                for index in 0..<(delimiters.count - 1) { result[delimiters[index]] = delimiters[index + 1] }
            }
            closingLines = result.merging(quoteClosing) { current, _ in current }.merging(listClosing) { current, _ in current }
            self.quoteOffsets = quoteOffsets
            self.listOffsets = listOffsets
            self.taskOffsets = taskOffsets
        }
    }

    /// The extension and its context outlive the parser and returned tree.
    /// The closure must not retain cmark pointers beyond its invocation.
    static func withDocument<T>(_ source: String, options: Int32 = CMARK_OPT_DEFAULT, includeInline: Bool = true, legacyInlineMath: Bool = false, strictMode: Bool = true, sourceForPositions: String? = nil, isCancelled: () -> Bool = { false }, _ body: (OpaquePointer, OpaquePointer, [Inline]) -> T) -> T? {
        withDocument(source, options: options, includeInline: includeInline, legacyInlineMath: legacyInlineMath, strictMode: strictMode, sourceForPositions: sourceForPositions, isCancelled: isCancelled) { root, ext, inline, _ in
            body(root, ext, inline)
        }
    }

    static func withDocument<T>(_ source: String, options: Int32 = CMARK_OPT_DEFAULT, includeInline: Bool = true, legacyInlineMath: Bool = false, strictMode: Bool = true, sourceForPositions: String? = nil, isCancelled: () -> Bool = { false }, _ body: (OpaquePointer, OpaquePointer, [Inline], OpaquePointer) -> T) -> T? {
        let context = Context(source, legacyInlineMath: legacyInlineMath)
        guard let parser = cmark_parser_new(options) else { return nil }
        guard let ext = cmark_syntax_extension_new("lac-math") else { cmark_parser_free(parser); return nil }
        guard let capture = cmark_syntax_extension_new("lac-text-source") else {
            cmark_parser_free(parser)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), ext)
            return nil
        }
        cmark_syntax_extension_set_private(capture, Unmanaged.passUnretained(context).toOpaque(), nil)
        cmark_syntax_extension_set_postprocess_func(capture, captureText)
        cmark_syntax_extension_set_private(ext, Unmanaged.passUnretained(context).toOpaque(), nil)
        let loose = strictMode ? nil : cmark_syntax_extension_new("lac-loose-heading")
        if !strictMode && loose == nil {
            cmark_parser_free(parser)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), ext)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), capture)
            return nil
        }
        if let loose {
            cmark_syntax_extension_set_private(loose, Unmanaged.passUnretained(context).toOpaque(), nil)
            cmark_syntax_extension_set_open_block_func(loose, openLooseHeading)
        }
        cmark_syntax_extension_set_open_block_func(ext, openBlock)
        cmark_syntax_extension_set_match_block_func(ext, matchBlock)
        if includeInline {
            cmark_syntax_extension_set_match_inline_func(ext, matchInline)
            let characters = cmark_llist_append(cmark_get_default_mem_allocator(), nil, UnsafeMutableRawPointer(bitPattern: 36))
            cmark_syntax_extension_set_special_inline_chars(ext, characters)
        }
        defer {
            cmark_parser_free(parser)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), ext)
            cmark_syntax_extension_free(cmark_get_default_mem_allocator(), capture)
            if let loose { cmark_syntax_extension_free(cmark_get_default_mem_allocator(), loose) }
        }
        cmark_gfm_core_extensions_ensure_registered()
        guard cmark_parser_attach_syntax_extension(parser, capture) != 0 else { return nil }
        for name in ["table", "strikethrough", "tasklist", "autolink", "tagfilter"] {
            name.withCString { if let existing = cmark_find_syntax_extension($0) { cmark_parser_attach_syntax_extension(parser, existing) } }
        }
        if let loose, cmark_parser_attach_syntax_extension(parser, loose) == 0 { return nil }
        guard cmark_parser_attach_syntax_extension(parser, ext) != 0 else { return nil }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }
        if !strictMode {
            guard let changes = recoverLooseLists(OpaquePointer(root), text: sourceForPositions ?? source, isCancelled: isCancelled) else { return nil }
            if isCancelled() { return nil }
            context.looseListRanges = changes.ranges
            context.looseIndents = changes.indents
        }
        return body(OpaquePointer(root), OpaquePointer(ext), context.inline, OpaquePointer(parser))
    }

    // The two non-strict list forms use existing nodes and source positions.
    private static func recoverLooseLists(_ root: OpaquePointer, text: String, isCancelled: () -> Bool) -> (ranges: [OpaquePointer: NSRange], indents: [MarkdownLooseIndent])? {
        let source = MarkdownSourcePositions(text, interruptIndexing: true, isCancelled: isCancelled)
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

    static func textOrigins(in extensionPointer: OpaquePointer) -> [MarkdownTextSourceCapture.Origin] {
        guard let pointer = cmark_syntax_extension_get_private(extensionPointer) else { return [] }
        return Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue().textOrigins
    }

    static func looseHeadings(in extensionPointer: OpaquePointer) -> [OpaquePointer: Int] {
        guard let pointer = cmark_syntax_extension_get_private(extensionPointer) else { return [:] }
        return Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue().looseHeadings
    }

    static func looseListRanges(in extensionPointer: OpaquePointer) -> [OpaquePointer: NSRange] {
        guard let pointer = cmark_syntax_extension_get_private(extensionPointer) else { return [:] }
        return Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue().looseListRanges
    }

    static func looseIndents(in extensionPointer: OpaquePointer) -> [MarkdownLooseIndent] {
        guard let pointer = cmark_syntax_extension_get_private(extensionPointer) else { return [] }
        return Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue().looseIndents
    }

    private static let openLooseHeading: cmark_open_block_func = { ext, indented, parser, parent, input, length in
        guard let ext, let parser, let parent, let input, indented == 0,
              let privateData = cmark_syntax_extension_get_private(ext) else { return nil }
        let first = Int(cmark_parser_get_first_nonspace(parser)), end = Int(length)
        guard first >= 0, first < end else { return nil }
        for index in 0..<end where input[index] == 9 { return nil }
        var count = 0
        while first + count < end && input[first + count] == 35 { count += 1 }
        guard count > 0, count <= 6, first + count < end,
              ![0, 9, 10, 13, 32].contains(Int(input[first + count])) else { return nil }
        let offset = Int(cmark_parser_get_offset(parser))
        guard first + count >= offset else { return nil }
        cmark_parser_advance_offset(parser, UnsafeRawPointer(input).assumingMemoryBound(to: CChar.self), Int32(first + count - offset), 0)
        guard let node = cmark_parser_add_child(parser, parent, CMARK_NODE_HEADING, Int32(first + count + 1)),
              cmark_node_set_heading_level(node, Int32(count)) != 0 else { return nil }
        Unmanaged<Context>.fromOpaque(privateData).takeUnretainedValue().looseHeadings[OpaquePointer(node)] = count
        return node
    }

    private static let captureText: cmark_postprocess_func = { extensionPointer, _, root in
        guard let extensionPointer, let root,
              let pointer = cmark_syntax_extension_get_private(extensionPointer) else { return root }
        let context = Unmanaged<Context>.fromOpaque(pointer).takeUnretainedValue()
        if context.capturesText { context.textOrigins = MarkdownTextSourceCapture.origins(in: OpaquePointer(root)) }
        return root
    }

    private static let openBlock: cmark_open_block_func = { ext, indented, parser, parent, input, length in
        guard let ext, let parser, let parent, let input, indented == 0,
              let privateData = cmark_syntax_extension_get_private(ext) else { return nil }
        let context = Unmanaged<Context>.fromOpaque(privateData).takeUnretainedValue()
        let line = Int(cmark_parser_get_line_number(parser))
        guard context.closingLines[line] != nil else { return nil }
        var offset = cmark_parser_get_offset(parser)
        let parentType = cmark_node_get_type(parent)
        let topLevel = offset == 0 && (parentType == CMARK_NODE_DOCUMENT || parentType == CMARK_NODE_PARAGRAPH)
        let quoted = parentType == CMARK_NODE_BLOCK_QUOTE && context.quoteOffsets[line] == Int(offset)
        var listed = parentType == CMARK_NODE_ITEM && context.listOffsets[line] == Int(offset)
        if !listed, parentType == CMARK_NODE_ITEM, let task = context.taskOffsets[line], task.checkboxEnd == Int(offset),
           cmark_node_get_type_string(parent).map({ String(cString: $0) }) == "tasklist",
           cmark_gfm_extensions_get_tasklist_item_checked(parent) == task.checked,
           task.math == task.checkboxEnd + 1, task.math + 2 <= Int(length), input[task.math - 1] == 32,
           input[task.math] == 36, input[task.math + 1] == 36 {
            cmark_parser_advance_offset(parser, UnsafeRawPointer(input).assumingMemoryBound(to: CChar.self), 1, 0)
            offset = cmark_parser_get_offset(parser)
            listed = Int(offset) == task.math
        }
        if !listed, parentType == CMARK_NODE_ITEM, let task = context.taskOffsets[line],
           cmark_node_get_type_string(parent).map({ String(cString: $0) }) == "item",
           task.checkboxEnd == Int(offset) + 3, task.math == task.checkboxEnd + 1,
           task.math + 2 <= Int(length), input[Int(offset)] == 91,
           [UInt8(32), 88, 120].contains(input[Int(offset) + 1]), input[Int(offset) + 2] == 93,
           (input[Int(offset) + 1] != 32) == task.checked, input[task.math - 1] == 32,
           input[task.math] == 36, input[task.math + 1] == 36,
           !(0..<task.math).contains(where: { input[$0] == 9 }) {
            var ancestor = cmark_node_parent(parent), inQuote = false
            while let node = ancestor {
                if cmark_node_get_type(node) == CMARK_NODE_BLOCK_QUOTE { inQuote = true; break }
                ancestor = cmark_node_parent(node)
            }
            if inQuote {
                cmark_parser_advance_offset(parser, UnsafeRawPointer(input).assumingMemoryBound(to: CChar.self), 4, 0)
                offset = cmark_parser_get_offset(parser)
                listed = Int(offset) == task.math
            }
        }
        guard (topLevel || quoted || listed), offset + 2 <= length, input[Int(offset)] == 36, input[Int(offset) + 1] == 36,
              let node = cmark_parser_add_child(parser, parent, CMARK_NODE_CODE_BLOCK, offset + 1) else { return nil }
        cmark_node_set_syntax_extension(node, ext)
        cmark_parser_advance_offset(parser, UnsafeRawPointer(input).assumingMemoryBound(to: CChar.self), length - offset, 0)
        return node
    }

    private static let matchBlock: cmark_match_block_func = { ext, parser, input, length, node in
        guard let ext, let parser, let input, let node,
              let privateData = cmark_syntax_extension_get_private(ext) else { return 0 }
        if cmark_node_get_user_data(node) != nil { return 0 }
        let context = Unmanaged<Context>.fromOpaque(privateData).takeUnretainedValue()
        let start = Int(cmark_node_get_start_line(node)), line = Int(cmark_parser_get_line_number(parser))
        if context.closingLines[start] == line {
            cmark_node_set_user_data(node, UnsafeMutableRawPointer(bitPattern: 1))
            cmark_parser_advance_offset(parser, UnsafeRawPointer(input).assumingMemoryBound(to: CChar.self), length - cmark_parser_get_offset(parser), 0)
        }
        return 1
    }

    private static let matchInline: cmark_match_inline_func = { ext, _, parent, character, parser in
        guard character == 36, let ext, let parent, let parser,
              let privateData = cmark_syntax_extension_get_private(ext) else { return nil }
        guard let name = cmark_node_get_type_string(parent),
              ["paragraph", "heading", "table_cell"].contains(String(cString: name)),
              cmark_inline_parser_in_bracket(parser, 1) == 0 else { return nil }
        let start = cmark_inline_parser_get_offset(parser)
        let next = cmark_inline_parser_peek_at(parser, start + 1)
        let context = Unmanaged<Context>.fromOpaque(privateData).takeUnretainedValue()
        guard start == 0 || cmark_inline_parser_peek_at(parser, start - 1) != 36 else { return nil }
        guard next != 0, next != 36, next != 10, next != 13,
              context.legacyInlineMath || (next != 32 && next != 9) else { return nil }
        let inLink = cmark_inline_parser_in_bracket(parser, 0) != 0
        var end = start + 1, previous: UInt8 = 0, backslashes = 0, bracketDepth = 0, text: [UInt8] = []
        while true {
            let byte = cmark_inline_parser_peek_at(parser, end)
            guard byte != 0, byte != 10, byte != 13 else { return nil }
            if inLink && backslashes % 2 == 0 {
                if byte == 91 { bracketDepth += 1 }
                if byte == 93 {
                    guard bracketDepth > 0 else { return nil }
                    bracketDepth -= 1
                }
            }
            if byte == 36 && previous != 92 {
                let after = cmark_inline_parser_peek_at(parser, end + 1)
                guard after != 36, context.legacyInlineMath || (previous != 32 && previous != 9 && !(48...57).contains(after)) else { return nil }
                break
            }
            text.append(byte); previous = byte; backslashes = byte == 92 ? backslashes + 1 : 0; end += 1
        }
        guard let semantic = String(bytes: text, encoding: .utf8),
              let node = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { return nil }
        context.inline.append(Inline(node: OpaquePointer(node), parent: OpaquePointer(parent), line: Int(cmark_inline_parser_get_line(parser)),
                                     column: Int(cmark_inline_parser_get_column(parser)), byteLength: Int(end - start + 1), text: semantic))
        cmark_inline_parser_set_offset(parser, end + 1)
        return node
    }
}
