import Foundation

/// Строит дерево карты из заголовков и списков Markdown. Читает построчно; диапазоны в UTF-16 исходной строки.
/// Это не индекс позиции курсора: нужны диапазоны названия и всего поддерева для правок текста.
enum MindMapDocumentParser {
    private struct Raw {
        var kind: MindMapNodeKind
        var level: Int
        var title: String
        var titleRange: NSRange
        var lineRange: NSRange
        var isSetext = false
        var indent = 0
        var content = 0
        var marker = "-"
    }

    private struct Marker {
        var length: Int
        var text: String
    }

    static func parse(_ text: String, fallbackTitle: String, limit: Int = MindMapLimits.documentNodes) -> MindMapTree {
        let ns = text as NSString
        var raws: [Raw] = []
        var truncated = false
        var position = 0
        if let front = MarkdownFrontMatter.frontMatter(text) { position = NSMaxRange(front.range) }

        var fence: (character: unichar, count: Int)?
        var headingLevel = 0
        var listStack: [(indent: Int, content: Int, level: Int)] = []
        var paragraph: (line: NSRange, content: NSRange)?
        var previousBlank = true
        var previousWasItem = false

        scan: while position < ns.length {
            let line = ns.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(line)
            var end = NSMaxRange(line)
            while end > line.location, isNewline(ns.character(at: end - 1)) { end -= 1 }
            let content = NSRange(location: line.location, length: end - line.location)
            let units = (0..<content.length).map { ns.character(at: content.location + $0) }
            guard let first = units.firstIndex(where: { !isSpace($0) }) else {
                previousBlank = true
                paragraph = nil
                previousWasItem = false
                continue
            }
            let indent = column(units, upTo: first)

            if let open = fence {
                if units[first] == open.character, run(units, first) >= open.count,
                   units[(first + run(units, first))...].allSatisfy(isSpace) {
                    fence = nil
                }
                continue
            }
            if units[first] == 96 || units[first] == 126 {
                let count = run(units, first)
                if count >= 3, units[first] == 126 || !units[(first + count)...].contains(96) {
                    fence = (units[first], count)
                    paragraph = nil
                    previousBlank = false
                    continue
                }
            }

            // Заголовок с подчёркиванием: читается как заголовок уровня 1 или 2.
            if indent <= 3, let candidate = paragraph, let level = setextLevel(units, first) {
                let range = trimmed(candidate.content, in: ns)
                if raws.count >= limit { truncated = true; break scan }
                raws.append(Raw(kind: .heading, level: level, title: ns.substring(with: range), titleRange: range,
                                lineRange: candidate.line, isSetext: true))
                headingLevel = level
                listStack = []
                paragraph = nil
                previousBlank = false
                previousWasItem = false
                continue
            }
            if isThematicBreak(units) {
                listStack = []
                paragraph = nil
                previousBlank = false
                previousWasItem = false
                continue
            }

            if indent <= 3, units[first] == 35 {
                let hashes = run(units, first)
                if hashes <= 6, first + hashes == units.count || isSpace(units[first + hashes]) {
                    var start = first + hashes
                    if start < units.count { start += 1 }
                    var titleEnd = units.count
                    while titleEnd > start, isSpace(units[titleEnd - 1]) { titleEnd -= 1 }
                    var closing = titleEnd
                    while closing > start, units[closing - 1] == 35 { closing -= 1 }
                    if closing < titleEnd, closing == start || isSpace(units[closing - 1]) {
                        titleEnd = closing
                        while titleEnd > start, isSpace(units[titleEnd - 1]) { titleEnd -= 1 }
                    }
                    while start < titleEnd, isSpace(units[start]) { start += 1 }
                    let range = NSRange(location: content.location + start, length: max(0, titleEnd - start))
                    if raws.count >= limit { truncated = true; break scan }
                    raws.append(Raw(kind: .heading, level: hashes, title: ns.substring(with: range), titleRange: range, lineRange: line))
                    headingLevel = hashes
                    listStack = []
                    paragraph = nil
                    previousBlank = false
                    previousWasItem = false
                    continue
                }
            }

            if !listStack.isEmpty || indent <= 3, let marker = listMarker(units, first) {
                while let last = listStack.last, last.content > indent { listStack.removeLast() }
                var start = first + marker.length
                var spaces = 0
                var cursor = start
                while cursor < units.count, isSpace(units[cursor]) { spaces += units[cursor] == 9 ? 4 : 1; cursor += 1 }
                if start >= units.count { spaces = 1 }
                let contentColumn = indent + marker.length + (spaces > 4 ? 1 : max(spaces, 1))
                start = cursor
                // Чекбокс `[ ]`, `[x]` в название не входит.
                if start + 2 < units.count, units[start] == 91, units[start + 2] == 93,
                   units[start + 1] == 32 || units[start + 1] == 120 || units[start + 1] == 88,
                   start + 3 == units.count || isSpace(units[start + 3]) {
                    start += 3
                    while start < units.count, isSpace(units[start]) { start += 1 }
                }
                var titleEnd = units.count
                while titleEnd > start, isSpace(units[titleEnd - 1]) { titleEnd -= 1 }
                let range = NSRange(location: content.location + min(start, titleEnd), length: max(0, titleEnd - start))
                let level = (listStack.last?.level ?? headingLevel) + 1
                if raws.count >= limit { truncated = true; break scan }
                listStack.append((indent, contentColumn, level))
                raws.append(Raw(kind: .listItem, level: level, title: ns.substring(with: range), titleRange: range, lineRange: line,
                                indent: indent, content: contentColumn, marker: marker.text))
                paragraph = nil
                previousBlank = false
                previousWasItem = true
                continue
            }

            // Обычная строка: после пустой строки менее вложенный текст заканчивает список.
            if previousBlank { while let last = listStack.last, last.content > indent { listStack.removeLast() } }
            if listStack.isEmpty, indent <= 3, !previousWasItem, units[first] != 62 {
                paragraph = (line, content)
            } else {
                paragraph = nil
            }
            previousBlank = false
            previousWasItem = false
        }

        return assemble(raws, text: ns, fallbackTitle: fallbackTitle, truncated: truncated)
    }

    // MARK: Сборка дерева

    private static func assemble(_ raws: [Raw], text: NSString, fallbackTitle: String, truncated: Bool) -> MindMapTree {
        let hasRealRoot: Bool = {
            guard let head = raws.first, head.kind == .heading, head.level == 1 else { return false }
            return !raws.dropFirst().contains { $0.kind == .heading && $0.level == 1 }
        }()
        var nodes: [MindMapNode] = []
        var stack: [Int] = []
        if !hasRealRoot {
            var root = MindMapNode(id: 0, key: "n0", title: fallbackTitle, level: 0, kind: .virtualRoot, parentID: nil)
            root.subtreeRange = NSRange(location: 0, length: text.length)
            nodes.append(root)
            stack = [0]
        }
        func close(_ id: Int, at end: Int) {
            guard let start = nodes[id].lineRange?.location else { return }
            nodes[id].subtreeRange = NSRange(location: start, length: max(0, end - start))
        }
        for raw in raws {
            let id = nodes.count
            while let top = stack.last, nodes[top].level >= raw.level {
                close(top, at: raw.lineRange.location)
                stack.removeLast()
            }
            let parent = stack.last
            var node = MindMapNode(id: id, key: "n\(id)", title: raw.title, level: raw.level, kind: raw.kind, parentID: parent,
                                   titleRange: raw.titleRange, lineRange: raw.lineRange)
            node.isSetext = raw.isSetext
            node.indentColumn = raw.indent
            node.contentColumn = raw.content
            node.marker = raw.marker
            nodes.append(node)
            if let parent { nodes[parent].childIDs.append(id) }
            stack.append(id)
        }
        for id in stack where nodes[id].kind != .virtualRoot { close(id, at: text.length) }
        return MindMapTree(nodes: nodes, rootID: 0, truncated: truncated)
    }

    // MARK: Разбор строки

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }

    private static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 }

    /// Колонка, на которую попадает символ с индексом `index` (табуляция шире на шаг в 4 колонки).
    private static func column(_ units: [unichar], upTo index: Int) -> Int {
        var result = 0
        for unit in units[0..<index] { result += unit == 9 ? 4 - result % 4 : 1 }
        return result
    }

    /// Длина серии одинаковых символов с позиции `index`.
    private static func run(_ units: [unichar], _ index: Int) -> Int {
        var count = 0
        while index + count < units.count, units[index + count] == units[index] { count += 1 }
        return count
    }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, isSpace(text.character(at: start)) { start += 1 }
        while end > start, isSpace(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Строка `===` или `--` под текстом. Нужны хотя бы два дефиса: одиночный `-` читается как пункт списка.
    private static func setextLevel(_ units: [unichar], _ first: Int) -> Int? {
        let mark = units[first]
        guard mark == 61 || mark == 45 else { return nil }
        let count = run(units, first)
        guard units[(first + count)...].allSatisfy(isSpace) else { return nil }
        if mark == 61 { return 1 }
        return count >= 2 ? 2 : nil
    }

    private static func isThematicBreak(_ units: [unichar]) -> Bool {
        let marks = units.filter { !isSpace($0) }
        guard marks.count >= 3, let mark = marks.first, mark == 45 || mark == 42 || mark == 95 else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func listMarker(_ units: [unichar], _ first: Int) -> Marker? {
        let unit = units[first]
        let after = first + 1
        if unit == 45 || unit == 42 || unit == 43 {
            guard after >= units.count || isSpace(units[after]) else { return nil }
            return Marker(length: 1, text: String(utf16CodeUnits: [unit], count: 1))
        }
        var digits = 0
        while first + digits < units.count, units[first + digits] >= 48, units[first + digits] <= 57, digits < 9 { digits += 1 }
        guard digits > 0, first + digits < units.count, units[first + digits] == 46 || units[first + digits] == 41 else { return nil }
        let next = first + digits + 1
        guard next >= units.count || isSpace(units[next]) else { return nil }
        return Marker(length: digits + 1, text: String(utf16CodeUnits: Array(units[first...(first + digits)]), count: digits + 1))
    }
}

extension MindMapTree {
    /// В тексте есть хотя бы один заголовок или пункт списка.
    var hasStructure: Bool { nodes.contains { $0.kind != .virtualRoot } }
}
