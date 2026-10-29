import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct MarkdownSyntaxOptions: Equatable, Sendable {
    let strictMode: Bool
    let inlineMath: Bool
    let legacyInlineMath: Bool
    let smartPunctuation: Bool?
    let preserveEditingWhitespace: Bool?
    let preserveExportWhitespace: Bool
    let preserveEditingSoftBreaks: Bool
    let preserveExportSoftBreaks: Bool?

    init(strictMode: Bool = true, inlineMath: Bool = true, legacyInlineMath: Bool = false, smartPunctuation: Bool? = nil,
         preserveEditingWhitespace: Bool? = nil, preserveExportWhitespace: Bool = false,
         preserveEditingSoftBreaks: Bool = true, preserveExportSoftBreaks: Bool? = nil) {
        self.strictMode = strictMode
        self.inlineMath = inlineMath
        self.legacyInlineMath = legacyInlineMath
        self.smartPunctuation = smartPunctuation
        self.preserveEditingWhitespace = preserveEditingWhitespace
        self.preserveExportWhitespace = preserveExportWhitespace
        self.preserveEditingSoftBreaks = preserveEditingSoftBreaks
        self.preserveExportSoftBreaks = preserveExportSoftBreaks
    }
}

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
            guard let changes = MarkdownPresentationParser.recoverLooseLists(OpaquePointer(root), text: sourceForPositions ?? source, isCancelled: isCancelled) else { return nil }
            if isCancelled() { return nil }
            context.looseListRanges = changes.ranges
            context.looseIndents = changes.indents
        }
        return body(OpaquePointer(root), OpaquePointer(ext), context.inline, OpaquePointer(parser))
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
