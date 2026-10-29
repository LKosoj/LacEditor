import Foundation
import cmark_gfm
import cmark_gfm_extensions

enum MarkdownFormattingCommand: Equatable {
    case bold, italic, strikethrough, inlineCode, inlineMath, blockMath, heading(Int), quote
    case bulletList, numberedList, taskList, fencedCode, horizontalRule
    case table(MarkdownTableCommand)
    case link(MarkdownLinkInput)

    var actionName: String {
        switch self {
        case .bold: L10n.tr("加粗")
        case .italic: L10n.tr("斜体")
        case .strikethrough: L10n.tr("删除线")
        case .inlineCode: L10n.tr("行内代码")
        case .inlineMath: L10n.tr("行内公式")
        case .blockMath: L10n.tr("公式块")
        case .heading: L10n.tr("设置标题")
        case .quote: L10n.tr("引用")
        case .bulletList: L10n.tr("无序列表")
        case .numberedList: L10n.tr("有序列表")
        case .taskList: L10n.tr("任务列表")
        case .fencedCode: L10n.tr("代码块")
        case .horizontalRule: L10n.tr("分隔线")
        case .link: L10n.tr("链接")
        case let .table(command):
            switch command {
            case .create: L10n.tr("插入表格")
            case .insertRowBefore: L10n.tr("在上方插入行")
            case .insertRowAfter: L10n.tr("在下方插入行")
            case .deleteRow: L10n.tr("删除行")
            case .moveRowUp: L10n.tr("上移行")
            case .moveRowDown: L10n.tr("下移行")
            case .insertColumnBefore: L10n.tr("在左侧插入列")
            case .insertColumnAfter: L10n.tr("在右侧插入列")
            case .deleteColumn: L10n.tr("删除列")
            case .moveColumnLeft: L10n.tr("左移列")
            case .moveColumnRight: L10n.tr("右移列")
            case .align(.unspecified): L10n.tr("默认对齐")
            case .align(.left): L10n.tr("左对齐")
            case .align(.center): L10n.tr("居中对齐")
            case .align(.right): L10n.tr("右对齐")
            }
        }
    }
}

struct MarkdownFormattingEdit {
    let range: NSRange
    let replacement: String
    let selectionRange: NSRange
}

enum MarkdownFormattingService {
    static func edit(in text: NSString, selection: NSRange, command: MarkdownFormattingCommand, strictMode: Bool = true) -> MarkdownFormattingEdit? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location,
              isCharacterBoundary(selection.location, in: text),
              isCharacterBoundary(NSMaxRange(selection), in: text) else { return nil }
        switch command {
        case .inlineMath, .blockMath:
            return mathEdit(in: text, selection: selection, block: command == .blockMath, strictMode: strictMode)
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
            return blockEdit(in: text, selection: selection, heading: level, strictMode: strictMode)
        case .quote: return blockEdit(in: text, selection: selection, heading: nil, strictMode: strictMode)
        case .bulletList, .numberedList, .taskList:
            let existing = existingListEdit(in: text, selection: selection, command: command, strictMode: strictMode)
            return existing.handled ? existing.edit : newBlockEdit(in: text, selection: selection, command: command)
        case .fencedCode, .horizontalRule:
            return newBlockEdit(in: text, selection: selection, command: command)
        case let .table(command):
            return MarkdownTableEditingService.edit(in: text, selection: selection, command: command)
        case let .link(input):
            return MarkdownLinkEditingService.edit(in: text, selection: selection, input: input)
        }
    }

    private static func mathEdit(in text: NSString, selection: NSRange, block: Bool, strictMode: Bool) -> MarkdownFormattingEdit? {
        let end = NSMaxRange(selection)
        guard !isEscaped(selection.location, in: text), !isEscaped(end, in: text) else { return nil }
        let selected = text.substring(with: selection)
        if !block && selected.rangeOfCharacter(from: .newlines) != nil { return nil }
        let presentation = MarkdownPresentationParser.parse(text as String, syntax: .init(strictMode: strictMode))
        func intersects(_ range: NSRange) -> Bool {
            selection.length == 0 ? selection.location >= range.location && selection.location < NSMaxRange(range)
                : NSIntersectionRange(selection, range).length > 0
        }
        guard !presentation.spans.contains(where: { ($0.kind == .code || $0.kind == .codeBlock || $0.kind == .yaml) && intersects($0.range) }),
              !presentation.inlineFormulas.contains(where: { intersects($0.range) }),
              !presentation.formulas.contains(where: { intersects($0.range) }) else { return nil }
        if block {
            let container = containerMathEdit(in: text, selection: selection, strictMode: strictMode)
            if container.handled { return container.edit }
        }
        let whole = text as String
        let newline = whole.contains("\r\n") ? "\r\n" : (whole.contains("\n") ? "\n" : (whole.contains("\r") ? "\r" : "\n"))
        let preceding = text.substring(to: selection.location), following = text.substring(from: end)
        let before = !block || preceding.isEmpty || preceding.hasSuffix(newline + newline) ? ""
            : (preceding.hasSuffix(newline) ? newline : newline + newline)
        let after = !block || following.isEmpty || following.hasPrefix(newline + newline) ? ""
            : (following.hasPrefix(newline) ? newline : newline + newline)
        let left = block ? "$$" + newline : "$"
        let right = block ? newline + "$$" : "$"
        let probeBody = selection.length == 0 ? "x" : selected
        let probeReplacement = before + left + probeBody + right + after
        let probe = text.replacingCharacters(in: selection, with: probeReplacement)
        let expected = NSRange(location: selection.location + (before as NSString).length,
                               length: ((left + probeBody + right) as NSString).length)
        let checked = MarkdownPresentationParser.parse(probe, syntax: .init(strictMode: strictMode))
        guard (block ? checked.formulas : checked.inlineFormulas).contains(where: { $0.range == expected }) else { return nil }
        let replacement = before + left + selected + right + after
        return MarkdownFormattingEdit(range: selection, replacement: replacement,
            selectionRange: NSRange(location: selection.location + ((before + left) as NSString).length, length: selection.length))
    }

    private struct QuotedTaskContent {
        let checkbox: MarkdownTaskCheckbox
        let paragraph: OpaquePointer
        let textNode: OpaquePointer
        let prefix: String
        let bodyRange: NSRange
    }

    private static func quotedTaskContent(_ item: OpaquePointer, source: MarkdownPresentationParser.Source, text: NSString) -> QuotedTaskContent? {
        guard let checkbox = source.quotedTaskCheckbox(item),
              let paragraph = cmark_node_first_child(item), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
              let first = cmark_node_first_child(paragraph), cmark_node_get_type(first) == CMARK_NODE_TEXT,
              let range = source.range(paragraph), range.location == checkbox.markerRange.location,
              source.firstPosition(first) == range.location,
              let rawLiteral = cmark_node_get_literal(first) else { return nil }
        var after = NSMaxRange(checkbox.markerRange)
        while after < NSMaxRange(range), text.character(at: after) == 32 { after += 1 }
        guard after > NSMaxRange(checkbox.markerRange), after < NSMaxRange(range) else { return nil }
        let prefix = text.substring(with: NSRange(location: range.location, length: after - range.location))
        guard String(cString: rawLiteral).utf16.starts(with: prefix.utf16) else { return nil }
        return QuotedTaskContent(checkbox: checkbox, paragraph: paragraph, textNode: first, prefix: prefix,
            bodyRange: NSRange(location: after, length: NSMaxRange(range) - after))
    }

    private static func containerMathEdit(in text: NSString, selection: NSRange, strictMode: Bool) -> (handled: Bool, edit: MarkdownFormattingEdit?) {
        MarkdownMathExtension.withDocument(text as String, strictMode: strictMode) { root, mathExtension, _ in
            let source = MarkdownPresentationParser.Source(text as String, root: root, looseHeadings: MarkdownMathExtension.looseHeadings(in: mathExtension), looseListRanges: MarkdownMathExtension.looseListRanges(in: mathExtension))
            var target: OpaquePointer?, emptyContainer: OpaquePointer?, handled = false
            func intersects(_ range: NSRange) -> Bool {
                if selection.length > 0 { return NSIntersectionRange(selection, range).length > 0 }
                let end = NSMaxRange(range)
                return selection.location >= range.location && (selection.location < end ||
                    (selection.location == end && end > 0 && ![10, 13].contains(text.character(at: end - 1))))
            }
            func visit(_ node: OpaquePointer, contained: Bool) {
                let kind = cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
                let container = ["block_quote", "item", "tasklist", "table"].contains(kind)
                if container, let range = source.wholeLines(node), intersects(range) {
                    handled = true
                    if cmark_node_first_child(node) == nil { emptyContainer = node }
                }
                if kind == "paragraph", contained {
                    if source.range(node) == selection { target = node }
                    else if let parent = cmark_node_parent(node), let task = quotedTaskContent(parent, source: source, text: text),
                            task.paragraph == node, task.bodyRange == selection { target = node }
                }
                var child = cmark_node_first_child(node)
                while let current = child { visit(current, contained: contained || container); child = cmark_node_next(current) }
            }
            visit(root, contained: false)
            guard handled else { return (false, nil) }
            let body: String, continuation: String
            var leading = ""
            if let target, selection.length > 0,
               let prefixes = MarkdownPresentationParser.containerPrefixes(target, source: source, text: text),
               !prefixes.continuation.isEmpty {
                body = text.substring(with: selection)
                continuation = prefixes.continuation
            } else if selection.length == 0, selection.location == text.length,
                      let emptyContainer, let parent = cmark_node_parent(emptyContainer) {
                let line = markdownLineRange(in: text, at: selection.location)
                let raw = text.substring(with: line)
                let kind = cmark_node_get_type_string(emptyContainer).map { String(cString: $0) } ?? ""
                if kind == "block_quote", parent == root, raw == "> " || raw == ">" {
                    continuation = "> "
                    if raw == ">" { leading = " " }
                } else if (kind == "item" || kind == "tasklist"),
                          cmark_node_get_type(parent) == CMARK_NODE_LIST,
                          let start = source.firstPosition(emptyContainer), start >= line.location,
                          let prefixes = MarkdownPresentationParser.listContainerPrefixes(emptyContainer, source: source, text: text),
                          text.substring(with: NSRange(location: line.location, length: start - line.location)) == prefixes.source {
                    let suffix = text.substring(from: start)
                    let pattern = kind == "tasklist" ? #"^([-+*]|[0-9]{1,9}[.)])( {1,4})\[[ xX]\] $"# : #"^([-+*]|[0-9]{1,9}[.)])( {1,4})$"#
                    let expression = try! NSRegularExpression(pattern: pattern)
                    guard let match = expression.firstMatch(in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length)) else { return (true, nil) }
                    if kind == "tasklist" {
                        guard let checkbox = source.taskCheckbox(emptyContainer),
                              (checkbox.state != 32) == cmark_gfm_extensions_get_tasklist_item_checked(emptyContainer) else { return (true, nil) }
                    }
                    continuation = prefixes.continuation + String(repeating: " ", count: match.range(at: 1).length + match.range(at: 2).length)
                } else { return (true, nil) }
                body = ""
            } else { return (true, nil) }
            let raw = body as NSString, expectedBody = NSMutableString()
            let prefix = continuation as NSString
            var cursor = 0
            while cursor < raw.length {
                let line = markdownLineRange(in: raw, at: cursor)
                var end = NSMaxRange(line)
                while end > cursor && [10, 13].contains(raw.character(at: end - 1)) { end -= 1 }
                var start = cursor
                if cursor > 0 {
                    guard end - cursor >= prefix.length,
                          raw.substring(with: NSRange(location: cursor, length: prefix.length)) == continuation else { return (true, nil) }
                    start += prefix.length
                }
                expectedBody.append(raw.substring(with: NSRange(location: start, length: end - start)))
                if end < NSMaxRange(line) { expectedBody.append("\n") }
                guard NSMaxRange(line) > cursor else { return (true, nil) }
                cursor = NSMaxRange(line)
            }
            let whole = text as String
            let newline = whole.contains("\r\n") ? "\r\n" : (whole.contains("\n") ? "\n" : (whole.contains("\r") ? "\r" : "\n"))
            let before = leading + "$$" + newline + continuation
            let replacement = before + body + newline + continuation + "$$"
            let expectedRange = NSRange(location: selection.location + (leading as NSString).length,
                                        length: (replacement as NSString).length - (leading as NSString).length)
            let probe = text.replacingCharacters(in: selection, with: replacement)
            let expectedLiteral = (expectedBody as String) + "\n"
            guard let expected = formattingStructure(root, omitting: target, source: source, text: text) else { return (true, nil) }
            let verified = MarkdownMathExtension.withDocument(probe, strictMode: strictMode) { candidate, mathExtension, _ in
                let candidateSource = MarkdownPresentationParser.Source(probe, root: candidate, looseHeadings: MarkdownMathExtension.looseHeadings(in: mathExtension), looseListRanges: MarkdownMathExtension.looseListRanges(in: mathExtension))
                var formula: OpaquePointer?
                func find(_ node: OpaquePointer) {
                    if cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK,
                       cmark_node_get_syntax_extension(node) == mathExtension,
                       candidateSource.mathBlockRange(node) == expectedRange,
                       cmark_node_get_literal(node).map({ String(cString: $0).utf16.elementsEqual(expectedLiteral.utf16) }) == true { formula = node }
                    var child = cmark_node_first_child(node)
                    while let current = child { find(current); child = cmark_node_next(current) }
                }
                find(candidate)
                guard let formula else { return false }
                return formattingStructure(candidate, omitting: formula, source: candidateSource, text: probe as NSString) == expected
            }
            guard verified == true else { return (true, nil) }
            return (true, MarkdownFormattingEdit(range: selection, replacement: replacement,
                selectionRange: NSRange(location: selection.location + (before as NSString).length, length: selection.length)))
        } ?? (true, nil)
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

    // cmark recognises CR, LF and CRLF as line endings; U+2028/U+2029 are content.
    private static func markdownLineRange(in text: NSString, at location: Int) -> NSRange {
        var position = location
        if position < text.length && position > 0 && text.character(at: position) == 10 && text.character(at: position - 1) == 13 { position -= 1 }
        var start = position
        while start > 0 && text.character(at: start - 1) != 10 && text.character(at: start - 1) != 13 { start -= 1 }
        var end = position
        while end < text.length && text.character(at: end) != 10 && text.character(at: end) != 13 { end += 1 }
        if end < text.length {
            let isCR = text.character(at: end) == 13
            end += 1
            if isCR && end < text.length && text.character(at: end) == 10 { end += 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    private static func intersectsCodeBlock(in text: NSString, from first: Int, through last: Int) -> Bool {
        var location = 0, fence: (character: unichar, length: Int, quoteDepth: Int)?
        while location <= last && location < text.length {
            let line = markdownLineRange(in: text, at: location)
            let end = NSMaxRange(line)
            let intersects = location >= first || end > first
            var cursor = location, spaces = 0
            while cursor < end && text.character(at: cursor) == 32 { cursor += 1; spaces += 1 }
            if intersects && (spaces >= 4 || (cursor < end && text.character(at: cursor) == 9)) { return true }
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
                    if intersects { return true }
                    if let open = fence {
                        var tail = cursor + fenceLength
                        while tail < end && (text.character(at: tail) == 32 || text.character(at: tail) == 9 || text.character(at: tail) == 10 || text.character(at: tail) == 13) { tail += 1 }
                        if character == open.character && fenceLength >= open.length && tail == end { fence = nil }
                    } else {
                        fence = (character, fenceLength, quoteDepth)
                    }
                }
            }
            if intersects && fence != nil { return true }
            if end <= location { break }
            location = end
        }
        return first == text.length && fence != nil
    }

    private static func existingListEdit(in text: NSString, selection: NSRange, command: MarkdownFormattingCommand, strictMode: Bool) -> (handled: Bool, edit: MarkdownFormattingEdit?) {
        let first = markdownLineRange(in: text, at: selection.location)
        let last = markdownLineRange(in: text, at: selection.length == 0 ? selection.location : NSMaxRange(selection) - 1)
        let selectedLines = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        struct Item {
            let node: OpaquePointer
            let parent: OpaquePointer
            let line: NSRange
            let whole: NSRange
            let prefix: NSRange
            let blockWidth: Int
            let marker: String
            let ordinal: Int
            let ordered: Bool
            let task: Bool
        }
        func convert(_ root: OpaquePointer, mathExtension: OpaquePointer) -> (handled: Bool, edit: MarkdownFormattingEdit?) {
            let source = MarkdownPresentationParser.Source(text as String, root: root, looseHeadings: MarkdownMathExtension.looseHeadings(in: mathExtension), looseListRanges: MarkdownMathExtension.looseListRanges(in: mathExtension))
            let marker = try! NSRegularExpression(pattern: #"^([-+*]|[0-9]{1,9}[.)])([ \t]+|$)"#)
            var nodes: [OpaquePointer] = []
            func visit(_ node: OpaquePointer) {
                let kind = cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
                if ["item", "tasklist"].contains(kind) { nodes.append(node) }
                var child = cmark_node_first_child(node)
                while let current = child { visit(current); child = cmark_node_next(current) }
            }
            visit(root)
            var ordinals: [OpaquePointer: Int] = [:], nextOrdinal: [OpaquePointer: Int] = [:]
            for node in nodes {
                guard let parent = cmark_node_parent(node) else { return (true, nil) }
                let ordinal = nextOrdinal[parent] ?? Int(cmark_node_get_list_start(parent))
                ordinals[node] = ordinal
                nextOrdinal[parent] = ordinal + 1
            }
            // Choose the deepest item at the first selected line, then its siblings.
            // Descendants of a selected parent move with that parent.
            let containing = nodes.filter { node in
                guard let whole = source.wholeLines(node) else { return false }
                return first.location >= whole.location && first.location < NSMaxRange(whole)
            }
            let starting = containing.filter { source.firstPosition($0).map { markdownLineRange(in: text, at: $0).location == first.location } ?? false }
            let anchor = starting.last(where: { (source.firstPosition($0) ?? Int.max) <= selection.location }) ?? starting.first ?? containing.last
            guard let anchor, let parent = cmark_node_parent(anchor) else {
                return (nodes.contains { source.wholeLines($0).map { NSIntersectionRange($0, selectedLines).length > 0 } ?? false }, nil)
            }
            var items: [Item] = []
            for node in nodes where cmark_node_parent(node) == parent {
                guard let whole = source.wholeLines(node), NSIntersectionRange(whole, selectedLines).length > 0 else { continue }
                guard let start = source.firstPosition(node) else { return (true, nil) }
                let line = markdownLineRange(in: text, at: start)
                var end = NSMaxRange(line)
                while end > line.location && [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
                let raw = text.substring(with: NSRange(location: start, length: end - start)) as NSString
                guard let match = marker.firstMatch(in: raw as String, range: NSRange(location: 0, length: raw.length)) else { return (true, nil) }
                let beforeMarker = text.substring(with: NSRange(location: line.location, length: start - line.location))
                guard beforeMarker.utf16.allSatisfy({ $0 < 128 }) else { return (true, nil) }
                if text.substring(with: whole).contains("\t") {
                    guard let prefix = MarkdownPresentationParser.listContainerPrefixes(node, source: source, text: text),
                          prefix.source.utf16.elementsEqual(beforeMarker.utf16) else { return (true, nil) }
                }
                let markerColumn = beforeMarker.utf16.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
                var column = markerColumn
                for unit in raw.substring(with: match.range).utf16 {
                    column = unit == 9 ? (column / 4 + 1) * 4 : column + 1
                }
                let blockWidth = column - markerColumn
                let tokenWidth = match.range(at: 1).length
                guard blockWidth - tokenWidth <= 4 else { return (true, nil) }
                let ordered = cmark_node_get_list_type(parent) == CMARK_ORDERED_LIST
                let token = raw.substring(with: match.range(at: 1))
                guard ordered == (token.first?.isNumber == true) else { return (true, nil) }
                var prefix = NSRange(location: start, length: match.range.length)
                let kind = cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
                let quotedTask = quotedTaskContent(node, source: source, text: text)
                if kind != "tasklist", source.taskCheckbox(node) != nil, quotedTask == nil { return (true, nil) }
                let task = kind == "tasklist" || quotedTask != nil
                if task {
                    guard let checkbox = quotedTask?.checkbox ?? source.taskCheckbox(node), checkbox.markerRange.location == NSMaxRange(prefix),
                          kind != "tasklist" || (checkbox.state != 32) == cmark_gfm_extensions_get_tasklist_item_checked(node) else { return (true, nil) }
                    var after = NSMaxRange(checkbox.markerRange)
                    while after < end && (text.character(at: after) == 32 || text.character(at: after) == 9) { after += 1 }
                    prefix.length = after - start
                }
                if selection.length > 0 {
                    let selectedPrefix = NSIntersectionRange(prefix, selection)
                    if selectedPrefix.length > 0 && selectedPrefix != prefix { return (true, nil) }
                }
                items.append(Item(node: node, parent: parent, line: line, whole: whole, prefix: prefix,
                                  blockWidth: blockWidth, marker: raw.substring(with: match.range), ordinal: ordinals[node]!, ordered: ordered, task: task))
            }
            guard let firstItem = items.first, let lastItem = items.last,
                  first.location >= firstItem.whole.location, first.location < NSMaxRange(firstItem.whole),
                  last.location >= lastItem.whole.location, last.location < NSMaxRange(lastItem.whole) else { return (true, nil) }
            for index in items.indices.dropFirst() {
                guard cmark_node_next(items[index - 1].node) == items[index].node else { return (true, nil) }
            }
            var replacements: [(NSRange, String)] = []
            for (index, item) in items.enumerated() {
                let same = command == .taskList ? item.task : !item.task && (item.ordered == (command == .numberedList))
                if same { continue }
                let prefix = command == .taskList ? "- [ ] " : command == .bulletList ? "- " : item.ordered ? item.marker : "\(index + 1). "
                replacements.append((item.prefix, prefix))
                let newWidth = command == .numberedList ? (item.ordered ? item.blockWidth : (prefix as NSString).length) : 2
                let delta = newWidth - item.blockWidth
                if delta != 0, NSMaxRange(item.line) < NSMaxRange(item.whole) {
                    guard let containers = MarkdownPresentationParser.listContainerPrefixes(item.node, source: source, text: text) else { return (true, nil) }
                    let ancestor = containers.continuation as NSString
                    var cursor = NSMaxRange(item.line)
                    while cursor < NSMaxRange(item.whole) {
                        let line = markdownLineRange(in: text, at: cursor)
                        var end = NSMaxRange(line)
                        while end > cursor && [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
                        let content = text.substring(with: NSRange(location: cursor, length: end - cursor))
                        if !content.trimmingCharacters(in: .whitespaces).isEmpty,
                           end - cursor >= ancestor.length,
                           text.substring(with: NSRange(location: cursor, length: ancestor.length)) == containers.continuation {
                            let start = cursor + ancestor.length
                            var after = start
                            var column = containers.continuation.utf16.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
                            let target = column + item.blockWidth
                            while after < end && column < target {
                                let unit = text.character(at: after)
                                guard unit == 32 || unit == 9 else { break }
                                column = unit == 9 ? (column / 4 + 1) * 4 : column + 1
                                after += 1
                            }
                            if column >= target {
                                replacements.append((NSRange(location: start, length: after - start),
                                    String(repeating: " ", count: newWidth + column - target)))
                            }
                        }
                        guard NSMaxRange(line) > cursor else { return (true, nil) }
                        cursor = NSMaxRange(line)
                    }
                }
            }
            guard let beginning = replacements.first, let ending = replacements.last else { return (true, nil) }
            let affected = NSRange(location: beginning.0.location, length: NSMaxRange(ending.0) - beginning.0.location)
            let changed = NSMutableString(string: text.substring(with: affected))
            for (range, value) in replacements.reversed() {
                changed.replaceCharacters(in: NSRange(location: range.location - affected.location, length: range.length), with: value)
            }
            let probe = text.replacingCharacters(in: affected, with: changed as String)
            let selectedNodes = Set(items.map(\.node))
            let selectedItems = Set(nodes.indices.filter { selectedNodes.contains(nodes[$0]) })
            let nodeIndices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
            var targetOrdinals: [Int: Int] = [:]
            if command == .numberedList {
                for (index, item) in items.enumerated() { targetOrdinals[nodeIndices[item.node]!] = item.ordered ? item.ordinal : index + 1 }
            }
            guard let expected = formattingStructure(root, selectedItems: selectedItems, command: command, source: source, text: text) else { return (true, nil) }
            let verified = MarkdownMathExtension.withDocument(probe, strictMode: strictMode) { candidate, mathExtension, _ in
                let candidateSource = MarkdownPresentationParser.Source(probe, root: candidate, looseHeadings: MarkdownMathExtension.looseHeadings(in: mathExtension), looseListRanges: MarkdownMathExtension.looseListRanges(in: mathExtension))
                return formattingStructure(candidate, selectedItems: selectedItems, command: command, validateTarget: true,
                                           targetOrdinals: targetOrdinals, source: candidateSource, text: probe as NSString) == expected
            }
            guard verified == true else { return (true, nil) }
            func mapped(_ position: Int) -> Int {
                var delta = 0
                for (range, value) in replacements {
                    if position <= range.location { break }
                    let length = (value as NSString).length
                    if position < NSMaxRange(range) { return range.location + delta + length }
                    delta += length - range.length
                }
                return position + delta
            }
            let start = mapped(selection.location), end = mapped(NSMaxRange(selection))
            return (true, MarkdownFormattingEdit(range: affected, replacement: changed as String,
                                                 selectionRange: NSRange(location: start, length: end - start)))
        }
        return MarkdownMathExtension.withDocument(text as String, strictMode: strictMode) { root, mathExtension, _ in convert(root, mathExtension: mathExtension) } ?? (true, nil)
    }

    // Compare content and item ancestry, allowing only the requested outer markers to change.
    private static func formattingStructure(_ root: OpaquePointer, selectedItems: Set<Int> = [],
                                            command: MarkdownFormattingCommand = .blockMath, validateTarget: Bool = false,
                                            targetOrdinals: [Int: Int] = [:], omitting omitted: OpaquePointer? = nil,
                                            source: MarkdownPresentationParser.Source? = nil, text: NSString? = nil) -> [[String]]? {
        var result: [[String]] = [], nextItem = 0, valid = true
        var listOrdinals: [OpaquePointer: Int] = [:]
        var taskPrefixes: [OpaquePointer: String] = [:]
        func visit(_ node: OpaquePointer, owner: Int?) {
            if node == omitted { return }
            let kind = cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
            var literal = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
            if let prefix = taskPrefixes[node] {
                literal = (literal as NSString).substring(from: (prefix as NSString).length)
                if literal.isEmpty { return }
            }
            var currentOwner = owner
            if kind == "item" || kind == "tasklist" {
                let index = nextItem
                nextItem += 1
                currentOwner = index
                guard let list = cmark_node_parent(node) else { valid = false; return }
                let ordered = cmark_node_get_list_type(list) == CMARK_ORDERED_LIST
                let quotedCheckbox = source?.quotedTaskCheckbox(node)
                if let source, let text, let quoted = quotedTaskContent(node, source: source, text: text) {
                    taskPrefixes[quoted.textNode] = quoted.prefix
                }
                let task = kind == "tasklist" || quotedCheckbox != nil
                let checked = quotedCheckbox.map { $0.state != 32 } ?? cmark_gfm_extensions_get_tasklist_item_checked(node)
                let tight = String(cmark_node_get_list_tight(list))
                let ordinal = listOrdinals[list] ?? Int(cmark_node_get_list_start(list))
                listOrdinals[list] = ordinal + 1
                if selectedItems.contains(index) {
                    if validateTarget, let expectedOrdinal = targetOrdinals[index], ordinal != expectedOrdinal { valid = false }
                    if validateTarget && (command == .taskList ? !task : task || ordered != (command == .numberedList)) { valid = false }
                    result.append(["item", String(owner ?? -1), "selected", tight])
                } else {
                    result.append(["item", String(owner ?? -1), String(ordered), String(task), tight,
                                   ordered ? String(ordinal) : "", ordered ? String(cmark_node_get_list_delim(list).rawValue) : "",
                                   task ? String(checked) : ""])
                }
            } else if kind != "list" {
                result.append([kind, String(owner ?? -1), literal,
                    cmark_node_get_url(node).map { String(cString: $0) } ?? "",
                    cmark_node_get_title(node).map { String(cString: $0) } ?? "",
                    cmark_node_get_fence_info(node).map { String(cString: $0) } ?? "",
                    String(cmark_node_get_heading_level(node))])
            }
            var child = cmark_node_first_child(node)
            while let current = child { visit(current, owner: currentOwner); child = cmark_node_next(current) }
            // The close marker distinguishes nested paragraph/inline structures with equal literals.
            if kind != "list" { result.append(["end", kind == "tasklist" ? "item" : kind]) }
        }
        visit(root, owner: nil)
        return valid ? result : nil
    }

    private static func newBlockEdit(in text: NSString, selection: NSRange, command: MarkdownFormattingCommand) -> MarkdownFormattingEdit? {
        let first = markdownLineRange(in: text, at: selection.location).location
        let lastLocation = selection.length == 0 ? selection.location : NSMaxRange(selection) - 1
        let last = markdownLineRange(in: text, at: lastLocation)
        guard !intersectsCodeBlock(in: text, from: first, through: last.location) else { return nil }
        var lines: [(start: Int, contentEnd: Int, end: Int)] = []
        var location = first
        repeat {
            let line = markdownLineRange(in: text, at: location)
            let end = NSMaxRange(line)
            var contentEnd = end
            while contentEnd > location && (text.character(at: contentEnd - 1) == 10 || text.character(at: contentEnd - 1) == 13) { contentEnd -= 1 }
            lines.append((location, contentEnd, end))
            if end <= location || end >= NSMaxRange(last) { break }
            location = end
        } while location <= text.length

        for line in lines {
            let content = text.substring(with: NSRange(location: line.start, length: line.contentEnd - line.start))
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && (lines.count > 1 || selection.length > 0) { return nil }
            if trimmed.hasPrefix("\\") || trimmed.hasPrefix(">") || trimmed.hasPrefix("#") ||
                trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") ||
                trimmed.hasPrefix("~") || trimmed.hasPrefix("`") { return nil }
            if trimmed.range(of: #"^\d+[.)](?:\s|$)"#, options: .regularExpression) != nil { return nil }
        }
        let affected = NSRange(location: first, length: NSMaxRange(last) - first)
        let newline: String = {
            for line in lines where line.end > line.contentEnd {
                return text.substring(with: NSRange(location: line.contentEnd, length: line.end - line.contentEnd))
            }
            let whole = text as String
            if whole.contains("\r\n") { return "\r\n" }
            if whole.contains("\n") { return "\n" }
            if whole.contains("\r") { return "\r" }
            return "\n"
        }()
        switch command {
        case .bulletList, .numberedList, .taskList:
            let result = NSMutableString(string: text.substring(with: affected))
            var startAdjustment = 0, endAdjustment = 0
            for (index, line) in lines.enumerated().reversed() {
                let prefix = command == .bulletList ? "- " : command == .taskList ? "- [ ] " : "\(index + 1). "
                let length = (prefix as NSString).length
                result.insert(prefix, at: line.start - first)
                if line.start <= selection.location { startAdjustment += length }
                if line.start < NSMaxRange(selection) || (selection.length == 0 && line.start == selection.location) { endAdjustment += length }
            }
            return MarkdownFormattingEdit(range: affected, replacement: result as String,
                selectionRange: NSRange(location: selection.location + startAdjustment, length: selection.length == 0 ? 0 : selection.length + endAdjustment - startAdjustment))
        case .fencedCode:
            let contentEnd = lines.last!.contentEnd
            let content = text.substring(with: NSRange(location: first, length: contentEnd - first))
            var longest = 0, run = 0
            for unit in content.utf16 {
                if unit == 96 { run += 1; longest = max(longest, run) } else { run = 0 }
            }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let prefix = fence + newline
            let ending = text.substring(with: NSRange(location: contentEnd, length: NSMaxRange(last) - contentEnd))
            let suffix = ending.isEmpty ? newline + fence : ending + fence + ending
            return MarkdownFormattingEdit(range: affected, replacement: prefix + content + suffix,
                selectionRange: NSRange(location: selection.location + (prefix as NSString).length, length: selection.length))
        case .horizontalRule:
            let lastLine = lines.last!
            if lines.count == 1 && text.substring(with: NSRange(location: lastLine.start, length: lastLine.contentEnd - lastLine.start)).allSatisfy({ $0 == " " || $0 == "\t" }) {
                let beforeNeedsBlank: Bool = {
                    guard lastLine.start > 0 else { return false }
                    let previous = markdownLineRange(in: text, at: lastLine.start - 1)
                    return !text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }()
                let afterNeedsBlank: Bool = {
                    guard lastLine.end < text.length else { return false }
                    let next = markdownLineRange(in: text, at: lastLine.end)
                    return !text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }()
                let before = beforeNeedsBlank ? newline : ""
                let after = afterNeedsBlank ? newline : ""
                return MarkdownFormattingEdit(range: NSRange(location: lastLine.start, length: 0), replacement: before + "---" + after,
                    selectionRange: NSRange(location: lastLine.start + (before as NSString).length + 3, length: 0))
            }
            let after = lastLine.end
            let hasBlankAfter: Bool = {
                guard after < text.length else { return false }
                let next = markdownLineRange(in: text, at: after)
                return text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }()
            let addition = (lastLine.end > lastLine.contentEnd ? newline : newline + newline) + "---" + newline + (hasBlankAfter ? "" : newline)
            return MarkdownFormattingEdit(range: NSRange(location: after, length: 0), replacement: addition, selectionRange: selection)
        default: return nil
        }
    }

    private static func blockEdit(in text: NSString, selection: NSRange, heading: Int?, strictMode: Bool) -> MarkdownFormattingEdit? {
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

        let looseHeadings: Set<Int>
        if !strictMode && heading != nil {
            let presentation = MarkdownPresentationParser.parse(text as String, syntax: .init(strictMode: false))
            looseHeadings = Set(presentation.spans.compactMap { span in
                guard case .heading = span.kind, let marker = span.markerRanges.first,
                      marker.length > 0, NSMaxRange(marker) < text.length,
                      text.substring(with: marker).utf16.allSatisfy({ $0 == 35 }),
                      ![9, 10, 13, 32].contains(Int(text.character(at: NSMaxRange(marker)))) else { return nil }
                return marker.location
            })
        } else { looseHeadings = [] }
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
                if (1...6).contains(count), markerEnd == text.length || text.character(at: markerEnd) == 32 || text.character(at: markerEnd) == 9 || text.character(at: markerEnd) == 10 || text.character(at: markerEnd) == 13 || looseHeadings.contains(cursor) {
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
