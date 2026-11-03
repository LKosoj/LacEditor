import Foundation

/// Одна замена в тексте документа: правка карты — всегда правка текста.
struct MindMapTextEdit: Equatable, Sendable {
    var range: NSRange
    var replacement: String
    /// Выделение в новом тексте после замены.
    var selection: NSRange
    /// Начало строки затронутого узла в новом тексте: по нему контроллер находит узел после перестроения.
    var focusLocation: Int
}

enum MindMapMoveOutcome: Equatable, Sendable {
    case edit(MindMapTextEdit)
    /// Узел и так стоит на этом месте.
    case unchanged
    /// Перенос невозможен: в собственное поддерево, несовместимые виды узлов, уровень вне 1…6.
    case refused
}

/// Чистые правки текста по дереву карты. Дерево должно быть разобрано из того же `text`: ничего вне нужных диапазонов не меняется.
enum MindMapEditor {
    // MARK: Переименование

    /// Название без переводов строк, управляющих символов и ведущих `#`.
    static func sanitized(_ title: String) -> String {
        let separators = CharacterSet.controlCharacters.union(.newlines)
        var result = title.components(separatedBy: separators).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        while result.hasPrefix("#") {
            let rest = result.dropFirst().drop { $0 == "#" }
            guard rest.isEmpty || rest.first == " " else { break }
            result = String(rest).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func rename(_ tree: MindMapTree, nodeID: Int, newTitle: String, in text: String) -> MindMapTextEdit? {
        let ns = text as NSString
        guard let node = tree.node(nodeID), let range = node.titleRange, node.kind == .heading || node.kind == .listItem,
              NSMaxRange(range) <= ns.length else { return nil }
        let title = sanitized(newTitle)
        guard !title.isEmpty, title != node.title else { return nil }
        var replacement = title
        if range.length == 0, range.location > 0, !isSpace(ns.character(at: range.location - 1)) {
            replacement = " " + title
        }
        return MindMapTextEdit(range: range, replacement: replacement,
                               selection: NSRange(location: range.location + replacement.utf16.count, length: 0),
                               focusLocation: node.subtreeRange?.location ?? range.location)
    }

    // MARK: Добавление

    static func addChild(_ tree: MindMapTree, nodeID: Int, in text: String, title: String = L10n.tr("新节点")) -> MindMapTextEdit? {
        appendChildren(tree, nodeID: nodeID, titles: [title], in: text)
    }

    /// Несколько детей одной вставкой (для принятия идей AI): один шаг отмены.
    static func appendChildren(_ tree: MindMapTree, nodeID: Int, titles: [String], in text: String) -> MindMapTextEdit? {
        let ns = text as NSString
        let cleaned = titles.map(sanitized).filter { !$0.isEmpty }
        guard !cleaned.isEmpty, let node = tree.node(nodeID), let slot = childSlot(tree, node: node, text: ns) else { return nil }
        return insertion(cleaned.map(slot.line), at: slot.location, in: ns)
    }

    static func addSibling(_ tree: MindMapTree, nodeID: Int, in text: String, title: String = L10n.tr("新节点")) -> MindMapTextEdit? {
        let ns = text as NSString
        guard let node = tree.node(nodeID) else { return nil }
        if node.parentID == nil { return addChild(tree, nodeID: nodeID, in: text, title: title) }
        let clean = sanitized(title)
        guard !clean.isEmpty else { return nil }
        switch node.kind {
        case .heading:
            guard let end = node.subtreeRange.map(NSMaxRange) else { return nil }
            return insertion([headingLine(level: node.level, title: clean)], at: end, in: ns)
        case .listItem:
            return insertion([itemLine(indent: node.indentColumn, marker: node.marker, title: clean)],
                             at: blockEnd(tree, node), in: ns)
        default:
            return nil
        }
    }

    // MARK: Удаление

    /// Удаляет узел вместе с поддеревом. У настоящего корня (единственный H1) удаляются только дети.
    static func delete(_ tree: MindMapTree, nodeID: Int, in text: String) -> MindMapTextEdit? {
        let ns = text as NSString
        guard let node = tree.node(nodeID), node.kind == .heading || node.kind == .listItem else { return nil }
        let range: NSRange
        if node.parentID == nil {
            guard let first = node.childIDs.first.flatMap({ tree.node($0)?.lineRange?.location }),
                  let end = node.subtreeRange.map(NSMaxRange), end > first else { return nil }
            range = NSRange(location: first, length: end - first)
        } else {
            guard let moved = removalRange(tree, node) else { return nil }
            range = moved
        }
        guard NSMaxRange(range) <= ns.length, range.length > 0 else { return nil }
        return MindMapTextEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0),
                               focusLocation: range.location)
    }

    // MARK: Перенос

    /// Переносит узел с поддеревом к новому родителю. `index` считается среди детей родителя без самого узла.
    static func move(_ tree: MindMapTree, nodeID: Int, toParent parentID: Int, index: Int, in text: String) -> MindMapMoveOutcome {
        let ns = text as NSString
        guard let node = tree.node(nodeID), node.parentID != nil, let target = tree.node(parentID),
              !tree.isDescendant(parentID, of: nodeID),
              let source = removalRange(tree, node), NSMaxRange(source) <= ns.length else { return .refused }
        let isItem = node.kind == .listItem
        switch (node.kind, target.kind) {
        case (.heading, .heading), (.heading, .virtualRoot), (.listItem, .heading), (.listItem, .virtualRoot), (.listItem, .listItem): break
        default: return .refused
        }
        let remaining = target.childIDs.compactMap { $0 == nodeID ? nil : tree.node($0) }
        let sameKind = remaining.filter { ($0.kind == .listItem) == isItem }
        let position = max(0, min(index, sameKind.count))
        let insertAt: Int
        if position < sameKind.count {
            guard let start = sameKind[position].lineRange?.location else { return .refused }
            insertAt = start
        } else if isItem {
            if let last = sameKind.last { insertAt = blockEnd(tree, last) }
            else if target.kind == .listItem { insertAt = blockEnd(tree, target) }
            else if let heading = remaining.first(where: { $0.kind == .heading })?.lineRange?.location { insertAt = heading }
            else if let end = target.subtreeRange.map(NSMaxRange) { insertAt = end }
            else { return .refused }
        } else {
            guard let end = target.subtreeRange.map(NSMaxRange) else { return .refused }
            insertAt = end
        }
        guard insertAt >= 0, insertAt <= ns.length else { return .refused }

        let original = ns.substring(with: source)
        guard let moved = transformed(original, node: node, source: source, target: target, tree: tree) else { return .refused }

        let eol = lineEnding(of: ns)
        var block = moved
        if !endsWithNewline(block) { block += eol }
        if insertAt >= source.location, insertAt <= NSMaxRange(source) {
            if moved == original { return .unchanged }
            return .edit(MindMapTextEdit(range: source, replacement: block, selection: NSRange(location: source.location, length: 0),
                                         focusLocation: source.location))
        }
        if insertAt > NSMaxRange(source) {
            var between = ns.substring(with: NSRange(location: NSMaxRange(source), length: insertAt - NSMaxRange(source)))
            if !endsWithNewline(between) { between += eol }
            let start = source.location + between.utf16.count
            return .edit(MindMapTextEdit(range: NSRange(location: source.location, length: insertAt - source.location),
                                         replacement: between + block, selection: NSRange(location: start, length: 0), focusLocation: start))
        }
        let between = ns.substring(with: NSRange(location: insertAt, length: source.location - insertAt))
        return .edit(MindMapTextEdit(range: NSRange(location: insertAt, length: NSMaxRange(source) - insertAt),
                                     replacement: block + between, selection: NSRange(location: insertAt, length: 0), focusLocation: insertAt))
    }

    /// Добавляет блок Markdown в конец текста через пустую строку.
    static func appendMarkdown(_ block: String, to text: String) -> MindMapTextEdit {
        let ns = text as NSString
        let eol = lineEnding(of: ns)
        var prefix = ""
        if ns.length > 0 {
            if !endsWithNewline(text) { prefix += eol }
            prefix += eol
        }
        let body = block.replacingOccurrences(of: "\n", with: eol)
        let replacement = prefix + body + (endsWithNewline(body) ? "" : eol)
        let start = ns.length + prefix.utf16.count
        return MindMapTextEdit(range: NSRange(location: ns.length, length: 0), replacement: replacement,
                               selection: NSRange(location: start, length: 0), focusLocation: start)
    }

    // MARK: Вспомогательное

    private static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    private static func lineEnding(of text: NSString) -> String {
        text.range(of: "\r\n").location != NSNotFound ? "\r\n" : "\n"
    }

    private static func endsWithNewline(_ text: String) -> Bool {
        guard let last = text.utf16.last else { return false }
        return last == 10 || last == 13
    }

    private static func headingLine(level: Int, title: String) -> String {
        String(repeating: "#", count: max(1, min(level, 6))) + " " + title
    }

    private static func itemLine(indent: Int, marker: String, title: String) -> String {
        String(repeating: " ", count: max(0, indent)) + marker + " " + title
    }

    /// Конец блока пункта списка: его строка и строки его детей (без пустых строк и абзацев после).
    private static func blockEnd(_ tree: MindMapTree, _ node: MindMapNode) -> Int {
        if let last = node.childIDs.last.flatMap({ tree.node($0) }), last.kind == .listItem { return blockEnd(tree, last) }
        return node.lineRange.map(NSMaxRange) ?? 0
    }

    /// Диапазон, который уходит при удалении и переносе: у заголовка всё поддерево, у пункта — его блок.
    private static func removalRange(_ tree: MindMapTree, _ node: MindMapNode) -> NSRange? {
        guard let start = node.lineRange?.location else { return nil }
        switch node.kind {
        case .heading:
            return node.subtreeRange
        case .listItem:
            return NSRange(location: start, length: max(0, blockEnd(tree, node) - start))
        default:
            return nil
        }
    }

    /// Куда и какой строкой встаёт новый ребёнок узла.
    private static func childSlot(_ tree: MindMapTree, node: MindMapNode, text: NSString) -> (location: Int, line: (String) -> String)? {
        switch node.kind {
        case .listItem:
            let items = node.childIDs.compactMap { tree.node($0) }.filter { $0.kind == .listItem }
            let indent = items.first?.indentColumn ?? node.contentColumn
            let marker = items.first?.marker ?? "-"
            return (blockEnd(tree, node), { itemLine(indent: indent, marker: marker, title: $0) })
        case .heading, .virtualRoot:
            let children = node.childIDs.compactMap { tree.node($0) }
            let items = children.filter { $0.kind == .listItem }
            guard let end = node.subtreeRange.map(NSMaxRange) else { return nil }
            if node.kind == .heading, node.level >= 6 || !items.isEmpty {
                let marker = items.first?.marker ?? "-"
                let location = items.last.map { blockEnd(tree, $0) } ?? end
                return (location, { itemLine(indent: 0, marker: marker, title: $0) })
            }
            let level = node.level + 1
            return (end, { headingLine(level: level, title: $0) })
        default:
            return nil
        }
    }

    /// Вставка строк в начало строки `location` (или в конец текста без перевода строки).
    private static func insertion(_ lines: [String], at location: Int, in text: NSString) -> MindMapTextEdit? {
        guard !lines.isEmpty, location >= 0, location <= text.length else { return nil }
        let eol = lineEnding(of: text)
        let needsBreak = location > 0 && !isNewlineUnit(text.character(at: location - 1))
        let prefix = needsBreak ? eol : ""
        let joined = lines.joined(separator: eol)
        let replacement = prefix + joined + (needsBreak ? "" : eol)
        let start = location + prefix.utf16.count
        return MindMapTextEdit(range: NSRange(location: location, length: 0), replacement: replacement,
                               selection: NSRange(location: start + lines[0].utf16.count, length: 0), focusLocation: start)
    }

    private static func isNewlineUnit(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    /// Переписывает уровни заголовков или отступы блока под нового родителя. nil — невозможно.
    private static func transformed(_ original: String, node: MindMapNode, source: NSRange, target: MindMapNode, tree: MindMapTree) -> String? {
        let text = NSMutableString(string: original)
        switch node.kind {
        case .heading:
            let delta = target.level + 1 - node.level
            guard delta != 0 else { return original }
            let headings = descendants(of: node, in: tree).filter { $0.kind == .heading }
            if headings.contains(where: { $0.isSetext }) { return nil }
            for heading in headings.reversed() {
                guard let line = heading.lineRange else { return nil }
                let level = heading.level + delta
                guard level >= 1, level <= 6 else { return nil }
                let local = NSRange(location: line.location - source.location, length: line.length)
                guard local.location >= 0, NSMaxRange(local) <= text.length else { return nil }
                var start = local.location
                while start < NSMaxRange(local), text.character(at: start) == 32 { start += 1 }
                var end = start
                while end < NSMaxRange(local), text.character(at: end) == 35 { end += 1 }
                text.replaceCharacters(in: NSRange(location: start, length: end - start), with: String(repeating: "#", count: level))
            }
            return text as String
        case .listItem:
            let newIndent = target.kind == .listItem ? target.contentColumn : 0
            let shift = newIndent - node.indentColumn
            guard shift != 0 else { return original }
            var result = ""
            original.enumerateSubstrings(in: original.startIndex..., options: .byLines) { _, _, enclosing, _ in
                let line = String(original[enclosing])
                result += reindented(line, by: shift)
            }
            return result
        default:
            return nil
        }
    }

    private static func descendants(of node: MindMapNode, in tree: MindMapTree) -> [MindMapNode] {
        var result = [node]
        var index = 0
        while index < result.count {
            result.append(contentsOf: result[index].childIDs.compactMap { tree.node($0) })
            index += 1
        }
        return result
    }

    /// Сдвигает отступ непустой строки; табуляции в отступе заменяются пробелами.
    static func reindented(_ line: String, by shift: Int) -> String {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let head = body.first, !head.isNewline else { return line }
        var width = 0
        for character in line.prefix(line.count - body.count) { width += character == "\t" ? 4 - width % 4 : 1 }
        return String(repeating: " ", count: max(0, width + shift)) + body
    }
}
