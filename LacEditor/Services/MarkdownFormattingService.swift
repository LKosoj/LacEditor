import Foundation

enum MarkdownFormattingCommand: Equatable {
    case bold, italic, strikethrough, inlineCode, inlineMath, blockMath, heading(Int), quote
    case bulletList, numberedList, taskList, fencedCode, horizontalRule
    /// «Обычный текст»: снимает заголовок, цитату и список с выбранных строк.
    case plainText
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
        case .plainText: L10n.tr("普通文本")
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
    /// Та же правка отдельными вставками и удалениями (от конца к началу): токены и текст между маркерами остаются нетронутыми.
    /// `range`/`replacement` при этом — объединённая равнозначная замена. nil — правка одна.
    var parts: [MarkdownEditTransaction.Edit]? = nil
}

enum MarkdownFormattingService {
    static func edit(in text: NSString, selection: NSRange, command: MarkdownFormattingCommand, strictMode: Bool = true,
                     context: MarkdownInlineContext? = nil) -> MarkdownFormattingEdit? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location,
              isCharacterBoundary(selection.location, in: text),
              isCharacterBoundary(NSMaxRange(selection), in: text) else { return nil }
        switch command {
        case .inlineMath, .blockMath:
            return mathEdit(in: text, selection: selection, block: command == .blockMath, strictMode: strictMode)
        case .bold, .italic, .strikethrough, .inlineCode:
            guard let selected = inlineSelection(selection, in: text) else { return nil }
            if let context {
                switch inlineEdit(in: text, selection: selected, command: command, context: context) {
                case let .edit(edit): return edit
                case .refused: return nil
                case .fallback: break
                }
            }
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
        case .plainText:
            return plainTextEdit(in: text, selection: selection, strictMode: strictMode, blocked: context?.blocked)
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
        let presentation = MarkdownPresentationBuilder.presentation(of: text as String, syntax: .init(strictMode: strictMode))
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
        let checked = MarkdownPresentationBuilder.presentation(of: probe, syntax: .init(strictMode: strictMode))
        guard (block ? checked.formulas : checked.inlineFormulas).contains(where: { $0.range == expected }) else { return nil }
        let replacement = before + left + selected + right + after
        return MarkdownFormattingEdit(range: selection, replacement: replacement,
            selectionRange: NSRange(location: selection.location + ((before + left) as NSString).length, length: selection.length))
    }

    /// Плоский обход блоков модели: у блока модели нет ссылки на родителя, а командам нужно подниматься вверх.
    /// Узлы идут в порядке документа (родитель раньше детей).
    private struct BlockTree {
        struct Node {
            let block: MarkdownBlockNode
            let parent: Int?
            var children: [Int] = []
        }
        let nodes: [Node]

        init(_ model: MarkdownDocumentModel) {
            var nodes: [Node] = []
            func add(_ block: MarkdownBlockNode, parent: Int?) {
                let index = nodes.count
                nodes.append(Node(block: block, parent: parent))
                for child in block.children {
                    nodes[index].children.append(nodes.count)
                    add(child, parent: index)
                }
            }
            for block in model.blocks { add(block, parent: nil) }
            self.nodes = nodes
        }

        func hasQuoteAncestor(_ index: Int) -> Bool {
            var current = nodes[index].parent
            while let parent = current {
                if MarkdownFormattingService.isQuote(nodes[parent].block.kind) { return true }
                current = nodes[parent].parent
            }
            return false
        }
    }

    private static func isQuote(_ kind: MarkdownBlockNode.Kind) -> Bool {
        switch kind {
        case .quote, .callout, .alert: return true
        default: return false
        }
    }

    /// Контейнеры, в которых блок формулы нельзя ставить как в обычном тексте (цитата, пункт списка, задача, таблица).
    private static func isMathContainer(_ kind: MarkdownBlockNode.Kind) -> Bool {
        switch kind {
        case .quote, .callout, .alert, .listItem, .table: return true
        default: return false
        }
    }

    private static func documentModel(of text: String, strictMode: Bool) -> MarkdownDocumentModel? {
        MarkdownPresentationBuilder.model(of: text, syntax: .init(strictMode: strictMode))
    }

    /// Строки текста целиком (с переводом строки в конце), которые затрагивает диапазон.
    private static func wholeLines(_ range: NSRange, in text: NSString) -> NSRange {
        let start = markdownLineRange(in: text, at: min(range.location, text.length)).location
        let last = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        let end = NSMaxRange(markdownLineRange(in: text, at: min(last, text.length)))
        return NSRange(location: start, length: max(end, start) - start)
    }

    /// Что стоит в строке левее маркера пункта и чем это заменяется на строках продолжения:
    /// `>`, пробелы и табы остаются, остальное становится пробелом.
    private static func itemPrefix(before marker: Int, in text: NSString) -> (source: String, continuation: String) {
        let line = markdownLineRange(in: text, at: marker)
        let source = text.substring(with: NSRange(location: line.location, length: max(marker - line.location, 0)))
        let continuation = String(decoding: source.utf16.map { $0 == 62 || $0 == 32 || $0 == 9 ? $0 : 32 }, as: UTF16.self)
        return (source, continuation)
    }

    private struct QuotedTaskContent {
        let checkbox: MarkdownTaskCheckbox
        let paragraph: Int
        let prefix: String
        let bodyRange: NSRange
    }

    private static func taskCheckbox(_ block: MarkdownBlockNode) -> MarkdownTaskCheckbox? {
        if case let .listItem(item) = block.kind { return item.task }
        return nil
    }

    /// Первый абзац пункта, в тексте которого стоит сам флажок `[ ]`: у настоящей задачи разбор снимает флажок с текста абзаца.
    private static func checkboxParagraph(_ tree: BlockTree, item: Int) -> Int? {
        guard let checkbox = taskCheckbox(tree.nodes[item].block), let paragraph = tree.nodes[item].children.first,
              case .paragraph = tree.nodes[paragraph].block.kind,
              tree.nodes[paragraph].block.range.location == checkbox.markerRange.location else { return nil }
        return paragraph
    }

    private static func quotedTaskContent(_ tree: BlockTree, item: Int, text: NSString) -> QuotedTaskContent? {
        guard let checkbox = taskCheckbox(tree.nodes[item].block), tree.hasQuoteAncestor(item),
              let paragraph = checkboxParagraph(tree, item: item), !tree.nodes[paragraph].block.isUnreliable else { return nil }
        let block = tree.nodes[paragraph].block
        guard let first = block.inlines.first, case .text = first.kind, first.range.location == block.range.location else { return nil }
        // Ведущие текстовые узлы склеиваются: cmark может отдать `[` отдельным узлом.
        var literal = ""
        for inline in block.inlines {
            guard case let .text(value) = inline.kind else { break }
            literal += value
        }
        var after = NSMaxRange(checkbox.markerRange)
        let end = NSMaxRange(block.range)
        while after < end, text.character(at: after) == 32 { after += 1 }
        guard after > NSMaxRange(checkbox.markerRange), after < end else { return nil }
        let prefix = text.substring(with: NSRange(location: block.range.location, length: after - block.range.location))
        guard literal.utf16.starts(with: prefix.utf16) else { return nil }
        return QuotedTaskContent(checkbox: checkbox, paragraph: paragraph, prefix: prefix,
            bodyRange: NSRange(location: after, length: end - after))
    }

    private static func containerMathEdit(in text: NSString, selection: NSRange, strictMode: Bool) -> (handled: Bool, edit: MarkdownFormattingEdit?) {
        guard let model = documentModel(of: text as String, strictMode: strictMode) else { return (true, nil) }
        let tree = BlockTree(model)
        var target: Int?, emptyContainer: Int?, handled = false
        func intersects(_ range: NSRange) -> Bool {
            if selection.length > 0 { return NSIntersectionRange(selection, range).length > 0 }
            let end = NSMaxRange(range)
            return selection.location >= range.location && (selection.location < end ||
                (selection.location == end && end > 0 && ![10, 13].contains(text.character(at: end - 1))))
        }
        var contained = [Bool](repeating: false, count: tree.nodes.count)
        for (index, node) in tree.nodes.enumerated() {
            let block = node.block
            if let parent = node.parent { contained[index] = contained[parent] || isMathContainer(tree.nodes[parent].block.kind) }
            if isMathContainer(block.kind), intersects(wholeLines(block.range, in: text)) {
                handled = true
                if case .table = block.kind {} else if node.children.isEmpty { emptyContainer = index }
            }
            if case .paragraph = block.kind, contained[index], !block.isUnreliable {
                if block.range == selection { target = index }
                else if let parent = node.parent, let task = quotedTaskContent(tree, item: parent, text: text),
                        task.paragraph == index, task.bodyRange == selection { target = index }
            }
        }
        guard handled else { return (false, nil) }
        let body: String, continuation: String
        var leading = ""
        if let target, selection.length > 0,
           let prefix = tree.nodes[target].block.containerPrefixes.first?.continuation, !prefix.isEmpty {
            body = text.substring(with: selection)
            continuation = prefix
        } else if selection.length == 0, selection.location == text.length, let emptyContainer {
            let block = tree.nodes[emptyContainer].block
            let line = markdownLineRange(in: text, at: selection.location)
            let raw = text.substring(with: line)
            if case .quote = block.kind, tree.nodes[emptyContainer].parent == nil, raw == "> " || raw == ">" {
                continuation = "> "
                if raw == ">" { leading = " " }
            } else if case let .listItem(item) = block.kind,
                      let start = block.markerRanges.first?.location, start >= line.location {
                let prefixes = itemPrefix(before: start, in: text)
                let suffix = text.substring(from: start)
                let pattern = item.task != nil ? #"^([-+*]|[0-9]{1,9}[.)])( {1,4})\[[ xX]\] $"# : #"^([-+*]|[0-9]{1,9}[.)])( {1,4})$"#
                let expression = try! NSRegularExpression(pattern: pattern)
                guard let match = expression.firstMatch(in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length)) else { return (true, nil) }
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
        let expected = formattingStructure(tree, text: text, omitting: target)
        // Проверка пробой: в тексте с правкой на нужном месте должна появиться формула с тем же телом, а остальная структура не измениться.
        guard let candidateModel = documentModel(of: probe, strictMode: strictMode) else { return (true, nil) }
        let candidate = BlockTree(candidateModel)
        let formula = candidate.nodes.indices.first { index in
            guard case let .mathBlock(source) = candidate.nodes[index].block.kind else { return false }
            return candidate.nodes[index].block.range == expectedRange && source.utf16.elementsEqual(expectedLiteral.utf16)
        }
        guard let formula else { return (true, nil) }
        if let expected {
            guard formattingStructure(candidate, text: probe as NSString, omitting: formula) == expected else { return (true, nil) }
        }
        return (true, MarkdownFormattingEdit(range: selection, replacement: replacement,
            selectionRange: NSRange(location: selection.location + (before as NSString).length, length: selection.length)))
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

    static func isEscaped(_ location: Int, in text: NSString) -> Bool {
        var index = location, count = 0
        while index > 0 && text.character(at: index - 1) == 92 { index -= 1; count += 1 }
        return count % 2 == 1
    }

    private static func isCharacterBoundary(_ location: Int, in text: NSString) -> Bool {
        guard location > 0, location < text.length else { return true }
        let before = text.character(at: location - 1), after = text.character(at: location)
        return !(0xd800...0xdbff).contains(before) || !(0xdc00...0xdfff).contains(after)
    }

    static func inlineEdit(in text: NSString, selection: NSRange, marker: String) -> MarkdownFormattingEdit? {
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

    static func codeEdit(in text: NSString, selection: NSRange) -> MarkdownFormattingEdit? {
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
    static func markdownLineRange(in text: NSString, at location: Int) -> NSRange {
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

    static func intersectsCodeBlock(in text: NSString, from first: Int, through last: Int) -> Bool {
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
            let node: Int
            let parent: Int
            let line: NSRange
            let whole: NSRange
            let prefix: NSRange
            let blockWidth: Int
            let marker: String
            let ordinal: Int
            let ordered: Bool
            let task: Bool
        }
        guard let model = documentModel(of: text as String, strictMode: strictMode) else { return (true, nil) }
        let tree = BlockTree(model)
        let marker = try! NSRegularExpression(pattern: #"^([-+*]|[0-9]{1,9}[.)])([ \t]+|$)"#)
        let nodes = tree.nodes.indices.filter { if case .listItem = tree.nodes[$0].block.kind { return true } else { return false } }
        func nodeLines(_ node: Int) -> NSRange { wholeLines(tree.nodes[node].block.range, in: text) }
        func listBlock(of node: Int) -> MarkdownBlockNode.ListBlock? {
            guard let parent = tree.nodes[node].parent, case let .list(list) = tree.nodes[parent].block.kind else { return nil }
            return list
        }
        func ordinal(of node: Int) -> Int {
            if case let .listItem(item) = tree.nodes[node].block.kind { return item.ordinal ?? 0 }
            return 0
        }
        // Choose the deepest item at the first selected line, then its siblings.
        // Descendants of a selected parent move with that parent.
        let containing = nodes.filter { node in
            let range = nodeLines(node)
            return first.location >= range.location && first.location < NSMaxRange(range)
        }
        let starting = containing.filter { tree.nodes[$0].block.markerRanges.first.map { markdownLineRange(in: text, at: $0.location).location == first.location } ?? false }
        let anchor = starting.last(where: { (tree.nodes[$0].block.markerRanges.first?.location ?? Int.max) <= selection.location }) ?? starting.first ?? containing.last
        guard let anchor, let parent = tree.nodes[anchor].parent, let parentList = listBlock(of: anchor) else {
            return (nodes.contains { NSIntersectionRange(nodeLines($0), selectedLines).length > 0 }, nil)
        }
        var items: [Item] = []
        for node in nodes where tree.nodes[node].parent == parent {
            let whole = nodeLines(node)
            guard NSIntersectionRange(whole, selectedLines).length > 0 else { continue }
            guard let start = tree.nodes[node].block.markerRanges.first?.location else { return (true, nil) }
            let line = markdownLineRange(in: text, at: start)
            var end = NSMaxRange(line)
            while end > line.location && [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
            let raw = text.substring(with: NSRange(location: start, length: end - start)) as NSString
            guard let match = marker.firstMatch(in: raw as String, range: NSRange(location: 0, length: raw.length)) else { return (true, nil) }
            let beforeMarker = text.substring(with: NSRange(location: line.location, length: start - line.location))
            guard beforeMarker.utf16.allSatisfy({ $0 < 128 }) else { return (true, nil) }
            let markerColumn = beforeMarker.utf16.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
            var column = markerColumn
            for unit in raw.substring(with: match.range).utf16 {
                column = unit == 9 ? (column / 4 + 1) * 4 : column + 1
            }
            let blockWidth = column - markerColumn
            let tokenWidth = match.range(at: 1).length
            guard blockWidth - tokenWidth <= 4 else { return (true, nil) }
            let ordered: Bool
            if case .ordered = parentList.marker { ordered = true } else { ordered = false }
            let token = raw.substring(with: match.range(at: 1))
            guard ordered == (token.first?.isNumber == true) else { return (true, nil) }
            var prefix = NSRange(location: start, length: match.range.length)
            let quotedTask = quotedTaskContent(tree, item: node, text: text)
            let checkbox = taskCheckbox(tree.nodes[node].block)
            // Флажок, который разбор не признал задачей (и не флажок в цитате): такой пункт не трогаем.
            if checkbox != nil, quotedTask == nil, checkboxParagraph(tree, item: node) != nil { return (true, nil) }
            let task = checkbox != nil
            if task {
                guard let checkbox, checkbox.markerRange.location == NSMaxRange(prefix) else { return (true, nil) }
                var after = NSMaxRange(checkbox.markerRange)
                while after < end && (text.character(at: after) == 32 || text.character(at: after) == 9) { after += 1 }
                prefix.length = after - start
            }
            if selection.length > 0 {
                let selectedPrefix = NSIntersectionRange(prefix, selection)
                if selectedPrefix.length > 0 && selectedPrefix != prefix { return (true, nil) }
            }
            items.append(Item(node: node, parent: parent, line: line, whole: whole, prefix: prefix,
                              blockWidth: blockWidth, marker: raw.substring(with: match.range), ordinal: ordinal(of: node), ordered: ordered, task: task))
        }
        guard let firstItem = items.first, let lastItem = items.last,
              first.location >= firstItem.whole.location, first.location < NSMaxRange(firstItem.whole),
              last.location >= lastItem.whole.location, last.location < NSMaxRange(lastItem.whole) else { return (true, nil) }
        let siblings = tree.nodes[parent].children
        for index in items.indices.dropFirst() {
            guard let previous = siblings.firstIndex(of: items[index - 1].node), previous + 1 < siblings.count,
                  siblings[previous + 1] == items[index].node else { return (true, nil) }
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
                guard let markerStart = tree.nodes[item.node].block.markerRanges.first?.location else { return (true, nil) }
                let containers = itemPrefix(before: markerStart, in: text)
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
        guard let expected = formattingStructure(tree, text: text, selectedItems: selectedItems, command: command) else { return (true, nil) }
        // Проверка пробой: в тексте с правкой структура должна совпасть с прежней, кроме выбранных пунктов.
        guard let candidateModel = documentModel(of: probe, strictMode: strictMode),
              formattingStructure(BlockTree(candidateModel), text: probe as NSString, selectedItems: selectedItems, command: command,
                                  validateTarget: true, targetOrdinals: targetOrdinals) == expected else { return (true, nil) }
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

    /// Подпись структуры (вид, номер, разделитель, плотность, флажок, адрес, заголовок, info ограждения, уровень) без позиций.
    /// Сравнивается до и после правки: меняться могут только внешние маркеры выбранных пунктов.
    private static func formattingStructure(_ tree: BlockTree, text: NSString, selectedItems: Set<Int> = [],
                                            command: MarkdownFormattingCommand = .blockMath, validateTarget: Bool = false,
                                            targetOrdinals: [Int: Int] = [:], omitting omitted: Int? = nil) -> [[String]]? {
        var result: [[String]] = [], nextItem = 0, valid = true
        var taskPrefixes: [Int: String] = [:]
        func entry(_ name: String, owner: Int?, literal: String = "", url: String = "", title: String = "", info: String = "", level: Int = 0) {
            result.append([name, String(owner ?? -1), literal, url, title, info, String(level)])
        }
        // Соседние текстовые узлы склеиваются: деление на узлы зависит от соседних символов, а не от содержимого.
        func inlines(_ nodes: [MarkdownInlineNode], owner: Int?, stripping prefix: String?) {
            var pending = "", stripped = prefix == nil
            func flush() {
                guard !pending.isEmpty else { return }
                var literal = pending
                pending = ""
                if !stripped, let prefix {
                    stripped = true
                    literal = (literal as NSString).substring(from: min((prefix as NSString).length, (literal as NSString).length))
                }
                if !literal.isEmpty { entry("text", owner: owner, literal: literal) }
            }
            for node in nodes {
                if case let .text(value) = node.kind { pending += value; continue }
                flush()
                stripped = true
                var name = Mirror(reflecting: node.kind).children.first?.label ?? String(describing: node.kind)
                var literal = "", url = "", title = ""
                switch node.kind {
                case let .code(value), let .rawHTML(value), let .formula(source: value): literal = value
                case let .link(link): url = link.url; title = link.title ?? ""
                case let .image(image): url = image.url; title = image.title ?? ""; literal = image.alt
                case let .footnoteReference(label: label): literal = label
                case let .emoji(name: emoji): literal = emoji
                default: break
                }
                if name.isEmpty { name = "inline" }
                entry(name, owner: owner, literal: literal, url: url, title: title)
                inlines(node.children, owner: owner, stripping: nil)
                result.append(["end", name])
            }
            flush()
        }
        func visit(_ index: Int, owner: Int?) {
            if index == omitted { return }
            let block = tree.nodes[index].block
            var currentOwner = owner
            var endName = ""
            switch block.kind {
            case let .listItem(item):
                let itemIndex = nextItem
                nextItem += 1
                currentOwner = itemIndex
                guard let listIndex = tree.nodes[index].parent, case let .list(list) = tree.nodes[listIndex].block.kind else { valid = false; return }
                var ordered = false, delimiter = ""
                if case let .ordered(_, unit) = list.marker { ordered = true; delimiter = String(unit) }
                let quoted = quotedTaskContent(tree, item: index, text: text)
                if let quoted { taskPrefixes[quoted.paragraph] = quoted.prefix }
                // Флажок в тексте абзаца считается задачей только в цитате; иначе это обычный текст `[ ]`.
                let task = item.task != nil && (checkboxParagraph(tree, item: index) == nil || tree.hasQuoteAncestor(index))
                let checked = (item.task?.state ?? 32) != 32
                let tight = String(list.isTight)
                let ordinal = item.ordinal ?? -1
                if selectedItems.contains(itemIndex) {
                    if validateTarget, let expectedOrdinal = targetOrdinals[itemIndex], ordinal != expectedOrdinal { valid = false }
                    if validateTarget && (command == .taskList ? !task : task || ordered != (command == .numberedList)) { valid = false }
                    result.append(["item", String(owner ?? -1), "selected", tight])
                } else {
                    result.append(["item", String(owner ?? -1), String(ordered), String(task), tight,
                                   ordered ? String(ordinal) : "", ordered ? delimiter : "",
                                   task ? String(checked) : ""])
                }
                endName = "item"
            case .list:
                break
            default:
                var name = Mirror(reflecting: block.kind).children.first?.label ?? String(describing: block.kind)
                var literal = "", info = "", level = 0
                switch block.kind {
                case let .heading(heading): level = heading.level
                case let .callout(callout): literal = callout.type
                case let .alert(alert): literal = alert.rawValue
                case let .codeBlock(code): literal = code.literal; info = code.info
                case let .mathBlock(source): literal = source
                case let .html(html): literal = html.literal
                case let .footnoteDefinition(label): literal = label
                case .frontMatter, .comment, .noteEmbed:
                    if block.range.location >= 0, NSMaxRange(block.range) <= text.length { literal = text.substring(with: block.range) }
                default: break
                }
                if name.isEmpty { name = "block" }
                entry(name, owner: owner, literal: literal, info: info, level: level)
                endName = name
                inlines(block.inlines, owner: currentOwner, stripping: taskPrefixes[index])
                if case let .table(table) = block.kind {
                    for row in table.rows {
                        for cell in row.cells {
                            entry("cell", owner: currentOwner)
                            inlines(cell.inlines, owner: currentOwner, stripping: nil)
                            result.append(["end", "cell"])
                        }
                        result.append(["end", "row"])
                    }
                }
            }
            for child in tree.nodes[index].children { visit(child, owner: currentOwner) }
            // The close marker distinguishes nested paragraph/inline structures with equal literals.
            if !endName.isEmpty { result.append(["end", endName]) }
        }
        for index in tree.nodes.indices where tree.nodes[index].parent == nil { visit(index, owner: nil) }
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
            let presentation = MarkdownPresentationBuilder.presentation(of: text as String, syntax: .init(strictMode: false))
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
