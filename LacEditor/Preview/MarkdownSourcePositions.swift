import Foundation
import cmark_gfm

struct MarkdownSourcePositions {
    let units: [UInt16]
    let bytes: [UInt8]
    let corrections: [(end: Int, delta: Int)]
    let lineStarts: [Int]
    let lineEnds: [Int]
    let lineHasTab: [Bool]
    private var recoveredRanges: [OpaquePointer: NSRange] = [:]
    private let looseHeadings: [OpaquePointer: Int]
    private let looseListRanges: [OpaquePointer: NSRange]
    private var paragraphLineShifts: [OpaquePointer: Int] = [:]
    private var paragraphColumnShifts: [OpaquePointer: [Int: Int]] = [:]
    private var paragraphRetainedStarts: [OpaquePointer: [Int: Int]] = [:]
    private var referencePrefixes: [OpaquePointer: NSRange] = [:]
    private var possibleReferenceNodes: Set<OpaquePointer> = []
    private var laggedNodes: Set<OpaquePointer> = []

    init(_ text: String, root: OpaquePointer? = nil, textOrigins: [MarkdownTextSourceCapture.Origin] = [], looseHeadings: [OpaquePointer: Int] = [:], looseListRanges: [OpaquePointer: NSRange] = [:], interruptIndexing: Bool = false, isCancelled: () -> Bool = { false }) {
        self.looseHeadings = looseHeadings
        self.looseListRanges = looseListRanges
        units = Array(text.utf16)
        bytes = Array(text.utf8)
        var corrections: [(end: Int, delta: Int)] = []
        var starts = [0], ends: [Int] = [], tabs: [Bool] = []
        var byte = 0, delta = 0
        var untilCancellationCheck = 0
        var hasTab = false, previousCR = false
        for scalar in text.unicodeScalars {
            if interruptIndexing {
                if untilCancellationCheck == 0 {
                    if isCancelled() { break }
                    untilCancellationCheck = 1024
                }
                untilCancellationCheck -= 1
            }
            let value = scalar.value
            if value == 10 && previousCR {
                byte += 1
                starts[starts.count - 1] = byte
                previousCR = false
                continue
            }
            previousCR = false
            if value == 10 || value == 13 {
                ends.append(byte)
                tabs.append(hasTab)
                byte += 1
                starts.append(byte)
                hasTab = false
                previousCR = value == 13
            } else {
                if value == 9 { hasTab = true }
                let byteLength = value < 0x80 ? 1 : (value < 0x800 ? 2 : (value < 0x10000 ? 3 : 4))
                byte += byteLength
                if byteLength > 1 {
                    delta += byteLength - (value < 0x10000 ? 1 : 2)
                    corrections.append((end: byte, delta: delta))
                }
            }
        }
        ends.append(byte)
        tabs.append(hasTab)
        self.corrections = corrections
        lineStarts = starts
        lineEnds = ends
        lineHasTab = tabs
        if let root { recoverReferenceParagraphs(root, text: text as NSString, isCancelled: isCancelled) }
        recoveredRanges.merge(MarkdownTextSourceCapture.ranges(textOrigins, source: self, isCancelled: isCancelled)) { _, new in new }
        recoveredRanges.merge(looseListRanges) { _, new in new }
        for (node, count) in looseHeadings {
            if isCancelled() { break }
            guard let content = range(node), content.location >= count, count > 0,
                  units[(content.location - count)..<content.location].allSatisfy({ $0 == 35 }) else { continue }
            let recovered = NSRange(location: content.location - count, length: content.length + count)
            recoveredRanges[node] = recovered
        }
    }

    // После переноса `\` cmark не увеличивает номер строки (handle_backslash), а следующий обычный перенос
    // сбрасывает столбец: позиции дальше выглядят правдоподобно, но отстают на число таких переносов.
    // Перенос `\` узнаётся по тому, что следующий узел остался на той же строке; отставшие узлы остаются без диапазона.
    private mutating func markLaggedNodes(_ blocks: Set<OpaquePointer>, isCancelled: () -> Bool) {
        for block in blocks {
            var lag = 0, sinceReset = 0, pendingBreak = false
            var line = Int(cmark_node_get_start_line(block))
            var pending: [OpaquePointer] = []
            var child = cmark_node_first_child(block)
            while let current = child { pending.append(current); child = cmark_node_next(current) }
            pending.reverse()
            while let node = pending.popLast() {
                if isCancelled() { return }
                var nested: [OpaquePointer] = [], item = cmark_node_first_child(node)
                while let current = item { nested.append(current); item = cmark_node_next(current) }
                pending.append(contentsOf: nested.reversed())
                let type = cmark_node_get_type(node)
                if type == CMARK_NODE_LINEBREAK { pendingBreak = true; continue }
                let start = Int(cmark_node_get_start_line(node))
                guard type != CMARK_NODE_SOFTBREAK, start > 0 else { continue }
                if pendingBreak && start == line { lag += 1; sinceReset += 1 }
                else if start != line { sinceReset = 0 }
                pendingBreak = false
                line = start
                if lag > sinceReset { laggedNodes.insert(node) }
            }
        }
    }

    // cmark removes leading reference definitions but keeps the old paragraph
    // line number. Recover only a complete, position-verified retained buffer.
    /// Содержимое абзаца в cmark совпадает с исходными строками (определение ссылки не съедено): позиции узлов верны,
    /// и абзац, начинающийся с `[` (например, `[!NOTE]`), не нужно считать возможным определением ссылки.
    /// После `[` метки идёт `]:`; метка может занимать несколько строк. `[!NOTE]` и подобные под защиту не попадают.
    private func firstLineMayStartDefinition(at start: Int, end: Int) -> Bool {
        var index = start + 1
        while index < end {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 93 { return index + 1 < end && bytes[index + 1] == 58 }
            index += 1
        }
        return false
    }

    private mutating func recoverReferenceParagraphs(_ root: OpaquePointer, text: NSString, isCancelled: () -> Bool) {
        var nodes = [root], breakBlocks: Set<OpaquePointer> = []
        defer { markLaggedNodes(breakBlocks, isCancelled: isCancelled) }
        while let node = nodes.popLast() {
            if isCancelled() { return }
            var descendant = cmark_node_first_child(node)
            while let current = descendant {
                if isCancelled() { return }
                nodes.append(current); descendant = cmark_node_next(current)
            }
            if cmark_node_get_type(node) == CMARK_NODE_LINEBREAK {
                var block = cmark_node_parent(node)
                while let current = block, cmark_node_get_type(current) != CMARK_NODE_PARAGRAPH,
                      cmark_node_get_type(current) != CMARK_NODE_HEADING { block = cmark_node_parent(current) }
                if let block { breakBlocks.insert(block) }
            }
            guard cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH else { continue }
            let column = Int(cmark_node_get_start_column(node))
            let first = Int(cmark_node_get_start_line(node)) - 1
            let last = Int(cmark_node_get_end_line(node)) - 1
            if first >= 0, last > first, first < lineStarts.count, column > 0,
               lineStarts[first] + column - 1 < lineEnds[first], bytes[lineStarts[first] + column - 1] == 91,
               firstLineMayStartDefinition(at: lineStarts[first] + column - 1, end: lineEnds[last]) {
                var pending = [node]
                while let current = pending.popLast() {
                    if isCancelled() { return }
                    possibleReferenceNodes.insert(current)
                    var child = cmark_node_first_child(current)
                    while let next = child {
                        if isCancelled() { return }
                        pending.append(next)
                        child = cmark_node_next(next)
                    }
                }
            }
            guard let parent = cmark_node_parent(node), let pointer = cmark_node_get_string_content(node) else { continue }
            guard first >= 0, last > first, last < lineStarts.count, column > 0,
                  Int(cmark_node_get_end_column(node)) == lineEnds[last] - lineStarts[last],
                  lineStarts[first] + column - 1 < lineEnds[first],
                  bytes[lineStarts[first] + column - 1] == 91 else { continue }
            var hasTab = false
            for line in first...last {
                if isCancelled() { return }
                if lineHasTab[line] { hasTab = true; break }
            }
            guard !lineHasTab[first] else { continue }
            var retained = Array(String(cString: pointer).utf8)
            if retained.last == 10 { retained.removeLast() }
            guard !retained.isEmpty else { continue }
            let actualLine: Int
            let prefixByteStart: Int
            var columnShifts: [Int: Int] = [:]
            var retainedStarts: [Int: Int] = [:]
            if parent == root && !hasTab {
                guard column == 1 else { continue }
                var raw = lineEnds[last], index = retained.count, matches = true
                while index > 0 && raw > lineStarts[first] {
                    if isCancelled() { return }
                    raw -= 1; index -= 1
                    if retained[index] == 10 && bytes[raw] == 13 { continue }
                    if retained[index] == 10 && bytes[raw] == 10 && raw > lineStarts[first] && bytes[raw - 1] == 13 { raw -= 1; continue }
                    if bytes[raw] != retained[index] { matches = false; break }
                }
                var low = first, high = last + 1
                while low < high {
                    let middle = (low + high) / 2
                    if lineStarts[middle] < raw { low = middle + 1 } else { high = middle }
                }
                guard matches, index == 0, raw > lineStarts[first], low <= last, lineStarts[low] == raw else { continue }
                actualLine = low
                prefixByteStart = lineStarts[first]
            } else {
                guard parent != root || column == 1 else { continue }
                var ancestor: OpaquePointer? = parent, supported = true, quoteDepth = 0
                while let current = ancestor, current != root {
                    let kind = cmark_node_get_type(current)
                    if kind == CMARK_NODE_BLOCK_QUOTE { quoteDepth += 1 }
                    if kind != CMARK_NODE_BLOCK_QUOTE && kind != CMARK_NODE_LIST && kind != CMARK_NODE_ITEM {
                        supported = false; break
                    }
                    ancestor = cmark_node_parent(current)
                }
                guard supported, ancestor == root else { continue }
                var lines: [Range<Int>] = [], start = 0
                for index in retained.indices {
                    if isCancelled() { return }
                    if retained[index] == 10 { lines.append(start..<index); start = index + 1 }
                }
                lines.append(start..<retained.count)
                if hasTab {
                    var valid = true
                    for line in lines {
                        if isCancelled() { return }
                        if line.isEmpty || retained[line.lowerBound] == 32 || retained[line.lowerBound] == 9 { valid = false; break }
                        if !valid { break }
                    }
                    guard valid else { continue }
                }
                let candidate = last - lines.count + 1
                guard candidate > first else { continue }
                var matches = true, ambiguousTab = false
                for (offset, line) in lines.enumerated() {
                    if isCancelled() { return }
                    let physical = candidate + offset
                    let startByte = lineEnds[physical] - line.count
                    guard startByte >= lineStarts[physical] else { matches = false; break }
                    retainedStarts[physical] = startByte
                    if hasTab {
                        var quotes = 0
                        for index in lineStarts[physical]..<startByte {
                            if isCancelled() { return }
                            let byte = bytes[index]
                            if byte == 91 || byte >= 128 || (65...90).contains(byte) || (97...122).contains(byte) { break }
                            if byte == 62 { quotes += 1 }
                            else if byte != 32 && byte != 9 && byte != 45 && byte != 43 && byte != 42 && byte != 46 && byte != 41 && !(48...57).contains(byte) {
                                matches = false
                                break
                            }
                        }
                        if !matches || quotes != quoteDepth { matches = false; break }
                        // Табуляция внутри текста после частично поглощённой табуляции префикса: колонки cmark неоднозначны.
                        if retained[line].contains(9), (lineStarts[physical]..<startByte).contains(where: { index in
                            bytes[index] == 9 && (index == lineStarts[physical] || (bytes[index - 1] != 9 && bytes[index - 1] != 32))
                        }) { ambiguousTab = true }
                    }
                    columnShifts[physical] = startByte - lineStarts[physical] - (column - 1)
                    for index in line {
                        if isCancelled() { return }
                        if bytes[startByte + index - line.lowerBound] != retained[index] { matches = false; break }
                    }
                    if !matches { break }
                }
                guard matches else { continue }
                if ambiguousTab {
                    // Строки абзаца сдвинуты, но позиции не подтверждены: узлы остаются без диапазона.
                    var pending = [node]
                    while let current = pending.popLast() {
                        if isCancelled() { return }
                        paragraphLineShifts[current] = candidate - first
                        var child = cmark_node_first_child(current)
                        while let next = child { pending.append(next); child = cmark_node_next(next) }
                    }
                    continue
                }
                actualLine = candidate
                prefixByteStart = lineStarts[first] + column - 1
            }
            var ancestorRanges: [OpaquePointer: NSRange] = [:]
            if hasTab && parent != root {
                var ancestor: OpaquePointer? = parent, valid = true
                while let current = ancestor, current != root {
                    if isCancelled() { return }
                    let startLine = Int(cmark_node_get_start_line(current)) - 1
                    var endLine = Int(cmark_node_get_end_line(current)) - 1
                    let startColumn = Int(cmark_node_get_start_column(current))
                    var endColumn = Int(cmark_node_get_end_column(current))
                    if endColumn == 0, endLine > first, endLine <= lineStarts.count {
                        endLine -= 1
                        endColumn = lineEnds[endLine] - lineStarts[endLine]
                    }
                    guard startLine >= 0, startLine <= first, endLine >= last, startColumn > 0,
                          !lineHasTab[startLine], endLine > last || endColumn == lineEnds[last] - lineStarts[last],
                          lineStarts[startLine] + startColumn - 1 <= lineEnds[startLine],
                          let lower = utf16Offset(at: lineStarts[startLine] + startColumn - 1),
                          let upper = utf16Offset(at: lineEnds[last]), upper >= lower else { valid = false; break }
                    ancestorRanges[current] = NSRange(location: lower, length: upper - lower)
                    ancestor = cmark_node_parent(current)
                }
                guard valid, ancestor == root else { continue }
            }
            let shift = actualLine - first
            guard let prefixStart = utf16Offset(at: prefixByteStart), let prefixEnd = utf16Offset(at: lineStarts[actualLine]) else { continue }
            referencePrefixes[node] = NSRange(location: prefixStart, length: prefixEnd - prefixStart)
            recoveredRanges.merge(ancestorRanges) { existing, _ in existing }
            if hasTab, let lower = utf16Offset(at: lineStarts[first] + column - 1),
               let upper = utf16Offset(at: lineEnds[last]), upper >= lower {
                recoveredRanges[node] = NSRange(location: lower, length: upper - lower)
            }
            var stack: [OpaquePointer] = [], child = cmark_node_first_child(node)
            while let current = child {
                if isCancelled() { return }
                stack.append(current); child = cmark_node_next(current)
            }
            paragraphLineShifts[node] = shift
            paragraphColumnShifts[node] = columnShifts
            paragraphRetainedStarts[node] = retainedStarts
            while let current = stack.popLast() {
                if isCancelled() { return }
                paragraphLineShifts[current] = shift
                paragraphColumnShifts[current] = columnShifts
                paragraphRetainedStarts[current] = retainedStarts
                let startLine = Int(cmark_node_get_start_line(current)) - 1 + shift
                let endLine = Int(cmark_node_get_end_line(current)) - 1 + shift
                let startColumn = Int(cmark_node_get_start_column(current))
                let endColumn = Int(cmark_node_get_end_column(current))
                if startLine >= actualLine, endLine >= startLine, endLine <= last,
                   startColumn > 0, endColumn > 0 {
                    let start = lineStarts[startLine] + startColumn - 1 + (columnShifts[startLine] ?? 0)
                    let end = lineStarts[endLine] + endColumn + (columnShifts[endLine] ?? 0)
                    if start >= (retainedStarts[startLine] ?? lineStarts[startLine]), start <= lineEnds[startLine],
                       end >= (retainedStarts[endLine] ?? lineStarts[endLine]), end <= lineEnds[endLine], end >= start,
                       let lower = utf16Offset(at: start), let upper = utf16Offset(at: end) {
                        let range = NSRange(location: lower, length: upper - lower)
                        if hasTab && cmark_node_get_type(current) == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(current) {
                            let spelling = text.substring(with: range) as NSString
                            guard MarkdownInlineTextProjection.pieces(spelling: spelling, literal: String(cString: literal), sourceOffset: lower, isCancelled: isCancelled) != nil else { continue }
                        }
                        if hasTab && cmark_node_get_type(current) == CMARK_NODE_CODE, let literal = cmark_node_get_literal(current),
                           !text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) { continue }
                        recoveredRanges[current] = range
                    }
                }
                var nested = cmark_node_first_child(current)
                while let item = nested {
                    if isCancelled() { return }
                    stack.append(item); nested = cmark_node_next(item)
                }
            }
        }
    }

    func referencePrefix(_ node: OpaquePointer) -> NSRange? { referencePrefixes[node] }

    // cmark reports virtual container columns on lazy continuation lines.
    // Only expose leaves whose full retained paragraph buffer matches source.
    func lazyParagraphInlineRanges(_ paragraph: OpaquePointer, text: NSString, plainEditing: Bool = false,
                                   inlineMath: [OpaquePointer: MarkdownMathExtension.Inline] = [:], referenceLinks: Bool = false,
                                   isCancelled: @escaping () -> Bool = { false }) -> [OpaquePointer: NSRange]? {
        guard cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
              let parent = cmark_node_parent(paragraph), plainEditing || cmark_node_get_type(parent) != CMARK_NODE_DOCUMENT,
              cmark_node_get_start_line(paragraph) < cmark_node_get_end_line(paragraph),
              referencePrefix(paragraph) == nil, let position = firstPosition(paragraph),
              let pointer = cmark_node_get_string_content(paragraph) else { return nil }
        let first = Int(cmark_node_get_start_line(paragraph)) - 1, last = Int(cmark_node_get_end_line(paragraph)) - 1
        let column = Int(cmark_node_get_start_column(paragraph))
        guard first >= 0, last > first, last < lineStarts.count, column > 0,
              let end = utf16Offset(at: lineEnds[last]) else { return nil }
        let hasTabs = lineHasTab[first...last].contains(true)
        if hasTabs && !plainEditing { return nil }
        let whole: NSRange
        let prefix: (source: String, continuation: String)
        if plainEditing {
            guard end >= position else { return nil }
            whole = NSRange(location: position, length: end - position)
            if cmark_node_get_type(parent) == CMARK_NODE_DOCUMENT { prefix = ("", "") }
            else {
                guard let prefixes = MarkdownDocumentParser.containerPrefixes(paragraph, source: self, text: text, isCancelled: isCancelled),
                      !prefixes.source.contains("\t"), !prefixes.continuation.contains("\t") else { return nil }
                prefix = prefixes
            }
            var child = cmark_node_first_child(paragraph)
            while let node = child {
                if isCancelled() { return nil }
                let type = cmark_node_get_type(node)
                if hasTabs, let name = cmark_node_get_type_string(node),
                   !["text", "softbreak", "strong", "emph", "code", "link", "strikethrough", "html_inline"].contains(String(cString: name)) { return nil }
                if type != CMARK_NODE_SOFTBREAK {
                    var pending = [node]
                    while let item = pending.popLast() {
                        if isCancelled() { return nil }
                        guard let name = cmark_node_get_type_string(item),
                              ["text", "strong", "emph", "strikethrough", "link", "code", "image", "custom_inline", "html_inline", "softbreak"].contains(String(cString: name)) else { return nil }
                        let itemName = String(cString: name)
                        if hasTabs && !["text", "softbreak", "strong", "emph", "code", "link", "strikethrough", "html_inline"].contains(itemName) { return nil }
                        if hasTabs && itemName != "softbreak" && cmark_node_get_start_line(item) != cmark_node_get_end_line(item) { return nil }
                        if itemName == "custom_inline" && inlineMath[item] == nil { return nil }
                        if (itemName == "text" || itemName == "code" || itemName == "image" || itemName == "html_inline") && cmark_node_get_start_line(item) != cmark_node_get_end_line(item) { return nil }
                        if itemName == "image" {
                            guard let child = cmark_node_first_child(item), cmark_node_next(child) == nil,
                                  cmark_node_get_type(child) == CMARK_NODE_TEXT else { return nil }
                        }
                        var nested = cmark_node_first_child(item)
                        while let next = nested { if isCancelled() { return nil }; pending.append(next); nested = cmark_node_next(next) }
                    }
                }
                child = cmark_node_next(node)
            }
        } else {
            guard let range = editingTextRange(paragraph), position == range.location, end == NSMaxRange(range),
                  let prefixes = MarkdownDocumentParser.containerPrefixes(paragraph, source: self, text: text, isCancelled: isCancelled),
                  !prefixes.source.contains("\t"), !prefixes.continuation.contains("\t") else { return nil }
            whole = range; prefix = prefixes
        }
        var retained = Array(String(cString: pointer).utf8)
        if retained.last == 10 { retained.removeLast() }
        var lines: [Range<Int>] = [], start = 0
        for index in retained.indices {
            if isCancelled() { return nil }
            if retained[index] == 10 { lines.append(start..<index); start = index + 1 }
        }
        lines.append(start..<retained.count)
        guard lines.count == last - first + 1 else { return nil }
        var shifts: [Int: Int] = [:], starts: [Int: Int] = [:]
        let continuation = Array(prefix.continuation.utf8)
        for (offset, line) in lines.enumerated() {
            if isCancelled() { return nil }
            let physical = first + offset, position = lineEnds[physical] - line.count
            guard !line.isEmpty, position >= lineStarts[physical],
                  Array(bytes[position..<lineEnds[physical]]) == Array(retained[line]) else { return nil }
            if offset == 0 {
                guard utf16Offset(at: position) == whole.location else { return nil }
                if hasTabs && bytes[lineStarts[physical]..<position].contains(9) { return nil }
            } else if plainEditing {
                let physicalPrefix = bytes[lineStarts[physical]..<position]
                guard physicalPrefix.starts(with: continuation) else { return nil }
                let extra = physicalPrefix.dropFirst(continuation.count)
                if extra.contains(9) {
                    guard !retained[line].isEmpty,
                          retained[line.lowerBound] != 32, retained[line.lowerBound] != 9,
                          extra.allSatisfy({ $0 == 32 || $0 == 9 }) else { return nil }
                } else if !extra.allSatisfy({ $0 == 32 }) { return nil }
            } else if position != lineStarts[physical] {
                guard Array(bytes[lineStarts[physical]..<position]) == continuation else { return nil }
            }
            guard utf16Offset(at: position) != nil else { return nil }
            starts[physical] = position
            shifts[physical] = position - lineStarts[physical] - (column - 1)
        }
        var tabPositions: [Int: [Int: Set<Int>]] = [:]
        if hasTabs {
            for line in first...last where lineHasTab[line] {
                guard let start = starts[line] else { return nil }
                var positions: [Int: Set<Int>] = [:], offset = start
                var byteColumn = column - 1, scalarColumn = column - 1
                var visualColumn = column - 1, physicalColumn = 0
                for unit in bytes[lineStarts[line]..<start] {
                    if isCancelled() { return nil }
                    physicalColumn = unit == 9 ? (physicalColumn / 4 + 1) * 4 : physicalColumn + 1
                }
                var visualScalar = column - 1, physicalScalar = physicalColumn
                func record() {
                    for key in [byteColumn, scalarColumn, visualColumn, physicalColumn, visualScalar, physicalScalar] { positions[key, default: []].insert(offset) }
                }
                record()
                while offset < lineEnds[line] {
                    if isCancelled() { return nil }
                    let unit = bytes[offset]
                    let length = unit < 0x80 ? 1 : (unit < 0xe0 ? 2 : (unit < 0xf0 ? 3 : 4))
                    guard length <= lineEnds[line] - offset else { return nil }
                    byteColumn += length; scalarColumn += 1
                    visualColumn = unit == 9 ? (visualColumn / 4 + 1) * 4 : visualColumn + length
                    physicalColumn = unit == 9 ? (physicalColumn / 4 + 1) * 4 : physicalColumn + length
                    visualScalar = unit == 9 ? (visualScalar / 4 + 1) * 4 : visualScalar + 1
                    physicalScalar = unit == 9 ? (physicalScalar / 4 + 1) * 4 : physicalScalar + 1
                    offset += length
                    guard utf16Offset(at: offset) != nil else { return nil }
                    record()
                }
                tabPositions[line] = positions
            }
        }
        var pending = [paragraph], linkNodes: [OpaquePointer] = [], result: [OpaquePointer: NSRange] = [:], hasUnsupportedStyle = false, textCount = 0, mappedTextCount = 0, htmlCount = 0, mappedHTMLCount = 0, mathCount = 0
        var tabWrappers: [OpaquePointer] = []
        while let node = pending.popLast() {
            if isCancelled() { return nil }
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_TEXT { textCount += 1 }
            if type == CMARK_NODE_LINK { linkNodes.append(node) }
            if type == CMARK_NODE_HTML_INLINE { htmlCount += 1 }
            if plainEditing && possibleReferenceNodes.contains(node) { return nil }
            if plainEditing, let math = inlineMath[node] {
                mathCount += 1
                let line = math.line - 1
                guard line >= first, line <= last, let shift = shifts[line], let retainedStart = starts[line],
                      math.column > 0, math.byteLength > 0 else { return nil }
                let lower = lineStarts[line] + math.column - 1 + shift, upper = lower + math.byteLength
                guard lower >= retainedStart, upper >= lower, upper <= lineEnds[line],
                      let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { return nil }
                let range = NSRange(location: start, length: end - start)
                guard text.substring(with: range).utf16.elementsEqual(("$" + math.text + "$").utf16) else { return nil }
                result[node] = range
            } else if (type == CMARK_NODE_TEXT || type == CMARK_NODE_HTML_INLINE), let literal = cmark_node_get_literal(node) {
                let line = Int(cmark_node_get_start_line(node)) - 1
                let endLine = Int(cmark_node_get_end_line(node)) - 1
                let startColumn = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
                if plainEditing, let positions = tabPositions[line] {
                    guard line == endLine, startColumn > 0, endColumn >= startColumn,
                          let lowerOffsets = positions[startColumn - 1], let upperOffsets = positions[endColumn] else { return nil }
                    var matches: Set<NSRange> = []
                    for lower in lowerOffsets {
                        for upper in upperOffsets {
                            if isCancelled() { return nil }
                            guard lower <= upper, let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { continue }
                            let range = NSRange(location: start, length: end - start)
                            let spelling = text.substring(with: range), value = String(cString: literal)
                            if spelling.utf16.elementsEqual(value.utf16) {
                                matches.insert(range)
                            } else if type == CMARK_NODE_TEXT, let pieces = MarkdownInlineTextProjection.pieces(spelling: spelling as NSString,
                                literal: value, sourceOffset: start, isCancelled: isCancelled),
                                pieces.map(\.text).joined().utf16.elementsEqual(value.utf16) { matches.insert(range) }
                        }
                    }
                    guard matches.count == 1, let match = matches.first else { return nil }
                    result[node] = match
                    if type == CMARK_NODE_TEXT { mappedTextCount += 1 }
                    else {
                        mappedHTMLCount += 1
                        let tag = text.substring(with: match)
                        if MarkdownDocumentParser.isSpanOpening(tag), MarkdownHTMLMediaService.hasStyledSpan(in: tag, isCancelled: isCancelled),
                           MarkdownHTMLMediaService.inlineStyleOpening(tag, isCancelled: isCancelled) == nil { hasUnsupportedStyle = true }
                    }
                    continue
                }
                if line == endLine, let shift = shifts[line], let retainedStart = starts[line], startColumn > 0, endColumn >= startColumn {
                    let lower = lineStarts[line] + startColumn - 1 + shift, upper = lineStarts[line] + endColumn + shift
                    if lower >= retainedStart, upper <= lineEnds[line], lower <= upper,
                       let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) {
                        let range = NSRange(location: start, length: end - start)
                        let spelling = text.substring(with: range), value = String(cString: literal)
                        let exact = spelling.utf16.elementsEqual(value.utf16)
                        let projected: Bool
                        if type == CMARK_NODE_TEXT, !exact,
                           let pieces = MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: value,
                               sourceOffset: start, isCancelled: isCancelled) {
                            projected = pieces.map(\.text).joined().utf16.elementsEqual(value.utf16)
                        } else { projected = false }
                        guard exact || projected else { continue }
                        result[node] = range
                        if type == CMARK_NODE_TEXT { mappedTextCount += 1 }
                        if type == CMARK_NODE_HTML_INLINE { mappedHTMLCount += 1 }
                        if type == CMARK_NODE_HTML_INLINE {
                            let tag = text.substring(with: range)
                            if MarkdownDocumentParser.isSpanOpening(tag), MarkdownHTMLMediaService.hasStyledSpan(in: tag, isCancelled: isCancelled),
                               MarkdownHTMLMediaService.inlineStyleOpening(tag, isCancelled: isCancelled) == nil { hasUnsupportedStyle = true }
                        }
                    }
                }
            } else if plainEditing, type != CMARK_NODE_PARAGRAPH && type != CMARK_NODE_SOFTBREAK {
                let line = Int(cmark_node_get_start_line(node)) - 1
                if hasTabs && tabPositions[line] != nil {
                    guard Int(cmark_node_get_end_line(node)) - 1 == line,
                          let name = cmark_node_get_type_string(node),
                          ["strong", "emph", "code", "link", "strikethrough"].contains(String(cString: name)) else { return nil }
                    tabWrappers.append(node)
                    var child = cmark_node_first_child(node)
                    while let item = child { if isCancelled() { return nil }; pending.append(item); child = cmark_node_next(item) }
                    continue
                }
                let endLine = Int(cmark_node_get_end_line(node)) - 1
                let startColumn = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
                guard line >= 0, endLine >= line, endLine < lineStarts.count,
                      let shift = shifts[line], let endShift = shifts[endLine], let retainedStart = starts[line],
                      let retainedEnd = starts[endLine], startColumn > 0, endColumn > 0 else { return nil }
                let lower = lineStarts[line] + startColumn - 1 + shift, upper = lineStarts[endLine] + endColumn + endShift
                guard lower >= retainedStart, lower <= lineEnds[line], upper >= retainedEnd,
                      upper <= lineEnds[endLine], lower <= upper,
                      let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { return nil }
                result[node] = NSRange(location: start, length: end - start)
            }
            var child = cmark_node_first_child(node)
            while let item = child { if isCancelled() { return nil }; pending.append(item); child = cmark_node_next(item) }
        }
        for node in tabWrappers.reversed() {
            if isCancelled() { return nil }
            let line = Int(cmark_node_get_start_line(node)) - 1
            let startColumn = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
            guard startColumn > 0, endColumn >= startColumn, let positions = tabPositions[line],
                  let lowers = positions[startColumn - 1], let uppers = positions[endColumn] else { return nil }
            var matches: Set<NSRange> = []
            for lower in lowers {
                for upper in uppers {
                    if isCancelled() { return nil }
                    guard lower <= upper, let start = utf16Offset(at: lower), let end = utf16Offset(at: upper) else { continue }
                    guard let name = cmark_node_get_type_string(node) else { return nil }
                    let range = NSRange(location: start, length: end - start)
                    var valid = false
                    switch String(cString: name) {
                    case "strong": valid = pairedMarkers(range, characters: [42, 95], count: 2).count == 2
                    case "emph": valid = pairedMarkers(range, characters: [42, 95], count: 1).count == 2
                    case "strikethrough": valid = pairedMarkers(range, characters: [126], count: 2).count == 2
                    case "link": valid = !linkMarkers(range, node: node, mappedRange: { result[$0] }).isEmpty
                    case "code":
                        if let literal = cmark_node_get_literal(node), codeRange(range) != nil {
                            valid = text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16)
                        }
                    default: break
                    }
                    guard valid else { continue }
                    var child = cmark_node_first_child(node), previous = range.location
                    while let item = child {
                        guard let itemRange = result[item], itemRange.location >= previous,
                              NSMaxRange(itemRange) <= NSMaxRange(range) else { valid = false; break }
                        previous = NSMaxRange(itemRange)
                        child = cmark_node_next(item)
                    }
                    if valid { matches.insert(range) }
                }
            }
            guard matches.count == 1, let match = matches.first else { return nil }
            result[node] = match
        }
        if plainEditing {
            // Ссылка со ссылочной формой (`[текст]`, `[текст][метка]`) не раскладывается на маркеры: такой абзац остаётся на позициях отдельных узлов.
            // Правило срабатывает и на автоссылки `<https://a.b>` и голые URL (у них нет `](…)`): абзац тоже идёт по позициям узлов, они точны, пока у строк продолжения не срезан отступ. `[a]()` (пустой адрес) маркеры находит и под правило не попадает.
            for node in linkNodes where cmark_node_first_child(node) != nil {
                guard let range = result[node] else { return nil }
                if !linkMarkers(range, node: node, mappedRange: { result[$0] }).isEmpty { continue }
                // Единый разбор принимает и ссылочную форму: она заканчивается на `]`, границы проверяем по скобкам.
                guard referenceLinks, range.length >= 2, units[range.location] == 91, units[NSMaxRange(range) - 1] == 93 else { return nil }
            }
        }
        guard (plainEditing ? (textCount + mathCount > 0 && mappedTextCount == textCount && mappedHTMLCount == htmlCount) : hasUnsupportedStyle), !isCancelled() else { return nil }
        if plainEditing { result[paragraph] = whole }
        return result
    }

    func utf16Offset(at byte: Int) -> Int? {
        guard byte >= 0, byte <= bytes.count,
              byte == bytes.count || bytes[byte] & 0xc0 != 0x80 else { return nil }
        var low = 0, high = corrections.count
        while low < high {
            let middle = low + (high - low) / 2
            if corrections[middle].end <= byte { low = middle + 1 } else { high = middle }
        }
        return byte - (low == 0 ? 0 : corrections[low - 1].delta)
    }

    // cmark removes one escaping backslash before each table pipe before
    // assigning inline columns. Map those columns back to the raw cell.
    struct TableCellPositions {
        let line: Int
        let column: Int
        let offsets: [Int]
        /// Строка и столбец ячейки, как их видят вложенные узлы cmark (у заголовка прервавшей абзац таблицы они не совпадают с `line` и `column`).
        let nodeLine: Int
        let nodeColumn: Int
    }

    /// Ячейка заголовка таблицы, прервавшей абзац: cmark ставит её на первую строку абзаца, а столбец считает в байтах от начала текста абзаца
    /// (строки через `\n`). Конец строки заголовка (`end_column` строки таблицы) cmark считает так же, поэтому сдвиг берётся от него:
    /// возвращает строку заголовка и сдвиг столбцов, после которого они отсчитываются от начала этой строки.
    private func interruptedHeaderCellShift(_ cell: OpaquePointer, line: Int) -> (line: Int, columns: Int)? {
        guard let row = cmark_node_parent(cell), let table = cmark_node_parent(row),
              Int(cmark_node_get_start_line(table)) - 1 == line,
              let paragraph = cmark_node_previous(table), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH else { return nil }
        let header = tableFirstLine(table)
        guard header > line, header < lineStarts.count else { return nil }
        return (header, lineEnds[header] - lineStarts[header] - Int(cmark_node_get_end_column(row)))
    }

    func tableCellPositions(_ cell: OpaquePointer, isCancelled: () -> Bool = { false }) -> TableCellPositions? {
        var line = Int(cmark_node_get_start_line(cell)) - 1
        var cellColumn = Int(cmark_node_get_start_column(cell))
        let nodeLine = line, nodeColumn = cellColumn
        var endCellColumn = Int(cmark_node_get_end_column(cell))
        if let shift = interruptedHeaderCellShift(cell, line: line) {
            line = shift.line
            cellColumn += shift.columns
            endCellColumn += shift.columns
        }
        guard line >= 0, line < lineStarts.count, !lineHasTab[line], cellColumn > 0,
              endCellColumn >= cellColumn else { return nil }
        let rawStart = lineStarts[line] + cellColumn - 1
        let rawEnd = lineStarts[line] + endCellColumn
        guard rawStart <= rawEnd, rawEnd <= lineEnds[line] else { return nil }
        var offsets = [rawStart], index = rawStart
        while index < rawEnd {
            if isCancelled() { return nil }
            if bytes[index] == 92 {
                var end = index
                while end < rawEnd && bytes[end] == 92 { if isCancelled() { return nil }; end += 1 }
                if end < rawEnd && bytes[end] == 124 && (end - index) % 2 == 1 {
                    while index < end - 1 { if isCancelled() { return nil }; index += 1; offsets.append(index) }
                    index = end + 1
                    offsets.append(index)
                    continue
                }
                while index < end { if isCancelled() { return nil }; index += 1; offsets.append(index) }
                continue
            }
            index += 1
            offsets.append(index)
        }
        return TableCellPositions(line: line, column: cellColumn, offsets: offsets, nodeLine: nodeLine, nodeColumn: nodeColumn)
    }

    func tableRowCellSourceRanges(_ cell: OpaquePointer, text: NSString, isCancelled: () -> Bool = { false }) -> [OpaquePointer: NSRange]? {
        guard let row = cmark_node_parent(cell), let table = cmark_node_parent(row),
              cmark_node_get_type_string(table).map({ String(cString: $0) }) == "table",
              cmark_node_get_start_line(row) == cmark_node_get_end_line(row),
              let rowRange = range(row), rowRange.length > 0, NSMaxRange(rowRange) <= text.length,
              firstPosition(row) == rowRange.location,
              let prefix = MarkdownDocumentParser.fencePrefixes(table, source: self, text: text, position: rowRange.location),
              !prefix.source.contains("\t"), !isCancelled() else { return nil }
        let line = text.lineRange(for: NSRange(location: rowRange.location, length: 0))
        var lineEnd = NSMaxRange(line)
        while lineEnd > line.location && [10, 13].contains(Int(text.character(at: lineEnd - 1))) { lineEnd -= 1 }
        guard NSMaxRange(rowRange) == lineEnd, !text.substring(with: rowRange).contains("\t") else { return nil }
        var separators: [Int] = [], slashes = 0
        for index in rowRange.location..<NSMaxRange(rowRange) {
            if isCancelled() { return nil }
            let unit = text.character(at: index)
            if unit == 92 { slashes += 1; continue }
            if unit == 124 && slashes % 2 == 0 { separators.append(index) }
            slashes = 0
        }
        var starts = [rowRange.location], ends: [Int] = []
        for separator in separators { ends.append(separator); starts.append(separator + 1) }
        ends.append(NSMaxRange(rowRange))
        if separators.first == rowRange.location { starts.removeFirst(); ends.removeFirst() }
        if separators.last == NSMaxRange(rowRange) - 1 { starts.removeLast(); ends.removeLast() }
        guard starts.count == ends.count else { return nil }
        var index = 0, current = cmark_node_first_child(row), answer: [OpaquePointer: NSRange] = [:]
        while let item = current {
            if isCancelled() { return nil }
            guard index < starts.count, let positions = tableCellPositions(item, isCancelled: isCancelled),
                  let first = positions.offsets.first.flatMap(utf16Offset), let last = positions.offsets.last.flatMap(utf16Offset),
                  first == starts[index], last == ends[index], first < last else { return nil }
            answer[item] = NSRange(location: first, length: last - first)
            index += 1
            current = cmark_node_next(item)
        }
        guard index == starts.count, answer[cell] != nil, !isCancelled() else { return nil }
        return answer
    }

    func linkRange(_ node: OpaquePointer, tableCell: OpaquePointer?, tablePositions: TableCellPositions? = nil) -> NSRange? {
        if let recovered = recoveredRanges[node] { return recovered }
        if laggedNodes.contains(node) { return nil }
        if let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
           cmark_node_get_type(child) == CMARK_NODE_TEXT,
           cmark_node_get_start_line(node) == cmark_node_get_start_line(child),
           cmark_node_get_end_line(node) == cmark_node_get_end_line(child),
           cmark_node_get_start_column(node) == cmark_node_get_start_column(child),
           cmark_node_get_end_column(node) == cmark_node_get_end_column(child),
           let value = cmark_node_get_literal(child) {
            // GFM start columns are local to their inline buffer; derive the
            // start from the confirmed end and literal byte length instead.
            let literal = String(cString: value)
            guard cmark_node_get_start_line(node) == cmark_node_get_end_line(node),
                  let candidate = mathInlineRange(line: Int(cmark_node_get_start_line(node)),
                    column: Int(cmark_node_get_end_column(node)) - literal.utf8.count + 1, byteLength: literal.utf8.count, parent: node, tablePositions: tablePositions),
                  String(decoding: units[candidate.location..<NSMaxRange(candidate)], as: UTF16.self) == literal else { return nil }
            return candidate
        }
        let normal: NSRange?
        if let positions = tablePositions ?? tableCell.flatMap({ tableCellPositions($0) }) { normal = tableInlineRange(node, positions: positions) }
        else { normal = range(node) }
        guard let normal, normal.length > 0,
              units[normal.location] == 91 || (units[normal.location] == 60 && units[NSMaxRange(normal) - 1] == 62) else { return nil }
        return normal
    }

    func mathInlineRange(line: Int, column: Int, byteLength: Int, parent: OpaquePointer, tablePositions: TableCellPositions? = nil) -> NSRange? {
        let lineIndex = line - 1 + (paragraphLineShifts[parent] ?? 0)
        guard lineIndex >= 0, lineIndex < lineStarts.count,
              (!lineHasTab[lineIndex] || paragraphColumnShifts[parent]?[lineIndex] != nil),
              column > 0, byteLength > 0 else { return nil }
        let startByte: Int, endByte: Int
        var ancestor: OpaquePointer? = parent
        while let node = ancestor {
            if let name = cmark_node_get_type_string(node), String(cString: name) == "table_cell" { break }
            ancestor = cmark_node_parent(node)
        }
        if let cell = ancestor {
            guard let positions = tablePositions ?? tableCellPositions(cell), positions.nodeLine == lineIndex else { return nil }
            let lower = column - positions.nodeColumn, upper = lower + byteLength
            guard lower >= 0, upper >= lower, upper < positions.offsets.count else { return nil }
            startByte = positions.offsets[lower]; endByte = positions.offsets[upper]
        } else {
            startByte = lineStarts[lineIndex] + column - 1 + (paragraphColumnShifts[parent]?[lineIndex] ?? 0)
            endByte = startByte + byteLength
            guard startByte >= (paragraphRetainedStarts[parent]?[lineIndex] ?? lineStarts[lineIndex]), endByte <= lineEnds[lineIndex] else { return nil }
        }
        guard let start = utf16Offset(at: startByte), let end = utf16Offset(at: endByte), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func tableInlineRange(_ node: OpaquePointer, positions: TableCellPositions) -> NSRange? {
        if let recovered = recoveredRanges[node] { return recovered }
        let startColumn = Int(cmark_node_get_start_column(node))
        let endColumn = Int(cmark_node_get_end_column(node))
        let lower = startColumn - positions.nodeColumn, upper = endColumn - positions.nodeColumn + 1
        guard Int(cmark_node_get_start_line(node)) - 1 == positions.nodeLine,
              Int(cmark_node_get_end_line(node)) - 1 == positions.nodeLine,
              lower >= 0, upper >= lower, upper < positions.offsets.count,
              let start = utf16Offset(at: positions.offsets[lower]),
              let end = utf16Offset(at: positions.offsets[upper]), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func footnoteDefinitionMarker(_ node: OpaquePointer) -> NSRange? {
        let line = Int(cmark_node_get_start_line(node)) - 1
        let column = Int(cmark_node_get_start_column(node))
        guard line >= 0, line < lineStarts.count, column > 0, !lineHasTab[line],
              let start = utf16Offset(at: lineStarts[line]),
              let content = utf16Offset(at: lineStarts[line] + column - 1), content <= units.count else { return nil }
        var cursor = start
        while cursor < content && units[cursor] == 32 && cursor - start < 3 { cursor += 1 }
        let markerStart = cursor
        guard cursor + 3 < content, units[cursor] == 91, units[cursor + 1] == 94 else { return nil }
        cursor += 2
        let identifierStart = cursor
        while cursor < content && units[cursor] != 93 && units[cursor] != 92 { cursor += 1 }
        guard cursor > identifierStart, cursor + 1 < content, units[cursor] == 93, units[cursor + 1] == 58 else { return nil }
        let end = cursor + 1
        cursor += 2
        while cursor < content && units[cursor] == 32 { cursor += 1 }
        guard cursor == content else { return nil }
        return NSRange(location: markerStart, length: end - markerStart)
    }

    func taskCheckbox(_ node: OpaquePointer) -> MarkdownTaskCheckbox? {
        let line = Int(cmark_node_get_start_line(node)) - 1
        let column = Int(cmark_node_get_start_column(node))
        guard cmark_node_get_type(node) == CMARK_NODE_ITEM,
              line >= 0, line < lineStarts.count, column > 0,
              let lineStart = utf16Offset(at: lineStarts[line]),
              let start = utf16Offset(at: lineStarts[line] + column - 1),
              let end = utf16Offset(at: lineEnds[line]), start >= lineStart, start < end,
              units[lineStart..<start].allSatisfy({ $0 < 128 }) else { return nil }
        var cursor = start
        if units[cursor] == 45 || units[cursor] == 43 || units[cursor] == 42 {
            cursor += 1
        } else {
            while cursor < end && cursor - start < 9 && (48...57).contains(units[cursor]) { cursor += 1 }
            guard cursor > start, cursor < end, units[cursor] == 46 || units[cursor] == 41 else { return nil }
            cursor += 1
        }
        var visualColumn = 0
        for unit in units[lineStart..<cursor] {
            visualColumn = unit == 9 ? (visualColumn / 4 + 1) * 4 : visualColumn + 1
        }
        let paddingStart = visualColumn
        while cursor < end && (units[cursor] == 32 || units[cursor] == 9) {
            visualColumn = units[cursor] == 9 ? (visualColumn / 4 + 1) * 4 : visualColumn + 1
            cursor += 1
        }
        guard (1...4).contains(visualColumn - paddingStart), cursor + 2 < end,
              units[cursor] == 91, units[cursor + 2] == 93,
              units[cursor + 1] == 32 || units[cursor + 1] == 120 || units[cursor + 1] == 88,
              cursor + 3 == end || units[cursor + 3] == 32 || units[cursor + 3] == 9 else { return nil }
        return MarkdownTaskCheckbox(markerRange: NSRange(location: cursor, length: 3),
                                    stateRange: NSRange(location: cursor + 1, length: 1), state: units[cursor + 1])
    }

    func quotedTaskCheckbox(_ node: OpaquePointer) -> MarkdownTaskCheckbox? {
        guard cmark_node_get_type_string(node).map({ String(cString: $0) }) == "item",
              let checkbox = taskCheckbox(node) else { return nil }
        var parent = cmark_node_parent(node)
        while let current = parent {
            if cmark_node_get_type(current) == CMARK_NODE_BLOCK_QUOTE {
                let line = Int(cmark_node_get_start_line(node)) - 1
                if lineHasTab[line] {
                    guard let paragraph = cmark_node_first_child(node), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                          let first = cmark_node_first_child(paragraph), cmark_node_get_type(first) == CMARK_NODE_TEXT,
                          firstPosition(first) == checkbox.markerRange.location,
                          let literal = cmark_node_get_literal(first), let end = utf16Offset(at: lineEnds[line]) else { return nil }
                    var after = NSMaxRange(checkbox.markerRange)
                    while after < end && (units[after] == 32 || units[after] == 9) { after += 1 }
                    let prefix = units[checkbox.markerRange.location..<after]
                    guard String(cString: literal).utf16.starts(with: prefix) else { return nil }
                }
                return checkbox
            }
            parent = cmark_node_parent(current)
        }
        return nil
    }

    func firstPosition(_ node: OpaquePointer) -> Int? {
        if let range = looseListRanges[node] { return range.location }
        if looseHeadings[node] != nil, let recovered = recoveredRanges[node] { return recovered.location }
        let line = Int(cmark_node_get_start_line(node)) - 1
        let column = Int(cmark_node_get_start_column(node))
        guard line >= 0, line < lineStarts.count, column > 0 else { return nil }
        let byte = lineStarts[line] + column - 1
        guard byte <= lineEnds[line] else { return nil }
        return utf16Offset(at: byte)
    }

    func wholeLines(_ node: OpaquePointer, skipFirst: Bool = false) -> NSRange? {
        if let range = looseListRanges[node] {
            var start = range.location, end = NSMaxRange(range)
            guard start >= 0, end >= start, end <= units.count else { return nil }
            while start > 0 && units[start - 1] != 10 && units[start - 1] != 13 { start -= 1 }
            while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
            if end < units.count {
                let newline = units[end]; end += 1
                if newline == 13 && end < units.count && units[end] == 10 { end += 1 }
            }
            if skipFirst {
                while start < end && units[start] != 10 && units[start] != 13 { start += 1 }
                guard start < end else { return nil }
                let newline = units[start]; start += 1
                if newline == 13 && start < end && units[start] == 10 { start += 1 }
                guard start < end else { return nil }
            }
            return NSRange(location: start, length: end - start)
        }
        var first = Int(cmark_node_get_start_line(node)) - 1
        var last = Int(cmark_node_get_end_line(node)) - 1
        let endColumn = Int(cmark_node_get_end_column(node))
        guard first >= 0, last >= first, last <= lineStarts.count else { return nil }
        if endColumn == 0 && last > first { last -= 1 }
        if cmark_node_get_type_string(node).map({ String(cString: $0) }) == "table" { first = max(first, tableFirstLine(node)) }
        if skipFirst { first += 1 }
        guard first <= last, last < lineStarts.count, let start = utf16Offset(at: lineStarts[first]),
              let end = utf16Offset(at: last + 1 < lineStarts.count ? lineStarts[last + 1] : bytes.count), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func fenceRange(_ node: OpaquePointer) -> NSRange? {
        guard let start = firstPosition(node) else { return nil }
        let first = Int(cmark_node_get_start_line(node)) - 1
        var last = Int(cmark_node_get_end_line(node)) - 1
        var endColumn = Int(cmark_node_get_end_column(node))
        if endColumn == 0 && last > first && last <= lineStarts.count {
            last -= 1
            endColumn = lineEnds[last] - lineStarts[last]
        }
        guard last >= first, last < lineStarts.count,
              endColumn == lineEnds[last] - lineStarts[last],
              let end = utf16Offset(at: lineEnds[last]), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func range(_ node: OpaquePointer) -> NSRange? {
        if let recovered = recoveredRanges[node] { return recovered }
        if paragraphLineShifts[node] != nil && referencePrefixes[node] == nil { return nil }
        if laggedNodes.contains(node) { return nil }
        let first = Int(cmark_node_get_start_line(node)) - 1
        var last = Int(cmark_node_get_end_line(node)) - 1
        let startColumn = Int(cmark_node_get_start_column(node))
        var endColumn = Int(cmark_node_get_end_column(node))
        if endColumn == 0 && last > first && last <= lineStarts.count {
            last -= 1
            endColumn = lineEnds[last] - lineStarts[last]
        }
        guard first >= 0, last >= first, last < lineStarts.count,
              startColumn > 0, endColumn > 0,
              !lineHasTab[first...last].contains(true) ||
                (first == last && lineStarts[last] + endColumn <= lineEnds[last] &&
                 !bytes[lineStarts[last]..<(lineStarts[last] + endColumn)].contains(9)) else { return nil }
        var start = lineStarts[first] + startColumn - 1
        var end = lineStarts[last] + endColumn
        if first == last, start > lineEnds[first] || end > lineEnds[last] {
            var ancestor = cmark_node_parent(node)
            while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_PARAGRAPH,
                  cmark_node_get_type(current) != CMARK_NODE_HEADING {
                ancestor = cmark_node_parent(current)
            }
            guard let paragraph = ancestor else { return nil }
            var hasCode = false, hasBreak = false
            var child = cmark_node_first_child(paragraph)
            while let current = child {
                if cmark_node_get_type(current) == CMARK_NODE_CODE { hasCode = true }
                // После переноса `\` cmark не переходит на следующую строку (handle_backslash): позиция считается от прежней.
                if cmark_node_get_type(current) == CMARK_NODE_LINEBREAK { hasBreak = true }
                child = cmark_node_next(current)
            }
            var quoted = false
            var container = paragraph
            while let parent = cmark_node_parent(container) {
                if cmark_node_get_type(parent) == CMARK_NODE_BLOCK_QUOTE { quoted = true; break }
                container = parent
            }
            guard ((hasCode || hasBreak) && !quoted) || cmark_node_get_type(node) == CMARK_NODE_IMAGE || cmark_node_get_type(node) == CMARK_NODE_LINK else { return nil }
            last = Int(cmark_node_get_end_line(paragraph)) - 1
            let paragraphFirst = Int(cmark_node_get_start_line(paragraph)) - 1
            guard last >= first, last < lineStarts.count, paragraphFirst >= 0, paragraphFirst <= first else { return nil }
            guard let paragraphContent = cmark_node_get_string_content(paragraph) else { return nil }
            let retainedLines = String(cString: paragraphContent).components(separatedBy: "\n")
            // У заголовка с подчёркиванием последняя строка — само подчёркивание, его нет в содержимом.
            if hasBreak { last = min(last, paragraphFirst + retainedLines.count - 1) }
            func sourceByte(_ position: Int) -> Int? {
                var shift = 0
                for line in first..<last {
                    let next = line + 1
                    guard next - paragraphFirst < retainedLines.count else { return nil }
                    let retained = retainedLines[next - paragraphFirst]
                    let contentStart = lineEnds[next] - retained.utf8.count
                    let retainedBytes = Array(retained.utf8)
                    guard contentStart >= lineStarts[next], contentStart <= lineEnds[next],
                          contentStart + retainedBytes.count <= bytes.count,
                          Array(bytes[contentStart..<contentStart + retainedBytes.count]) == retainedBytes else { return nil }
                    let extra = contentStart - lineStarts[next] + lineStarts[next] - lineEnds[line] - 1
                    if position >= lineEnds[line] + 1 - shift { shift += extra }
                }
                return position + shift
            }
            guard let mappedStart = sourceByte(start), let mappedEnd = sourceByte(end) else { return nil }
            start = mappedStart
            end = mappedEnd
            if hasBreak, !hasCode {
                guard let line = lineStarts.lastIndex(where: { $0 < end }), line >= first, line <= last,
                      lineStarts[line] <= start else { return nil }
                last = line
            }
        }
        guard start >= lineStarts[first],
              end >= lineStarts[last], end <= lineEnds[last], end >= start,
              let startUTF16 = utf16Offset(at: start), let endUTF16 = utf16Offset(at: end) else { return nil }
        return NSRange(location: startUTF16, length: endUTF16 - startUTF16)
    }

    /// Первая строка таблицы по числу её строк (строки узла и разделитель): если таблица прервала абзац, cmark ставит начало на первую строку абзаца.
    func tableFirstLine(_ node: OpaquePointer) -> Int {
        let first = Int(cmark_node_get_start_line(node)) - 1
        var last = Int(cmark_node_get_end_line(node)) - 1
        if cmark_node_get_end_column(node) == 0 && last > first { last -= 1 }
        var rows = 0, child = cmark_node_first_child(node)
        while let row = child { rows += 1; child = cmark_node_next(row) }
        return rows > 0 ? max(first, last - rows) : first
    }

    /// Диапазон таблицы без строк абзаца перед ней. Если префиксы строк (цитата, отступ списка) расходятся, диапазон не подтверждается.
    func tableRange(_ node: OpaquePointer) -> NSRange? {
        guard let range = range(node) else { return nil }
        let first = Int(cmark_node_get_start_line(node)) - 1
        let header = tableFirstLine(node)
        guard header > first else { return range }
        let column = Int(cmark_node_get_start_column(node)) - 1
        guard header < lineStarts.count, column >= 0,
              lineStarts[first] + column <= lineEnds[first], lineStarts[header] + column <= lineEnds[header],
              bytes[lineStarts[first]..<(lineStarts[first] + column)] == bytes[lineStarts[header]..<(lineStarts[header] + column)],
              let start = utf16Offset(at: lineStarts[header] + column), NSMaxRange(range) >= start else { return nil }
        return NSRange(location: start, length: NSMaxRange(range) - start)
    }

    /// Строки узла (или объемлющего абзаца/заголовка) целиком: надёжны даже тогда, когда столбцы cmark не подтверждены.
    func lineRange(of node: OpaquePointer) -> NSRange? {
        var block: OpaquePointer = node
        var ancestor: OpaquePointer? = node
        while let current = ancestor {
            let type = cmark_node_get_type(current)
            if type == CMARK_NODE_PARAGRAPH || type == CMARK_NODE_HEADING { block = current; break }
            ancestor = cmark_node_parent(current)
        }
        let first = Int(cmark_node_get_start_line(block)) - 1
        var last = Int(cmark_node_get_end_line(block)) - 1
        if cmark_node_get_end_column(block) == 0 && last > first { last -= 1 }
        guard first >= 0, last >= first, last < lineStarts.count,
              let start = utf16Offset(at: lineStarts[first]), let end = utf16Offset(at: lineEnds[last]),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func editingTextRange(_ node: OpaquePointer) -> NSRange? {
        guard !possibleReferenceNodes.contains(node) || recoveredRanges[node] != nil else { return nil }
        // Пробелы абзаца после удалённого определения ссылки с табуляцией не подтверждаются для правки.
        if possibleReferenceNodes.contains(node) {
            var paragraph: OpaquePointer? = node
            while let current = paragraph, cmark_node_get_type(current) != CMARK_NODE_PARAGRAPH { paragraph = cmark_node_parent(current) }
            guard let paragraph else { return nil }
            let first = Int(cmark_node_get_start_line(paragraph)) - 1, last = Int(cmark_node_get_end_line(paragraph)) - 1
            guard first >= 0, last >= first, last < lineHasTab.count, !lineHasTab[first...last].contains(true) else { return nil }
        }
        return range(node)
    }

    /// Позиции (в байтах исходника) по колонкам cmark на строке с табом: колонка в байтах и колонка в знаках с шагом таба 4.
    func tabColumns(line: Int, isCancelled: () -> Bool = { false }) -> (bytes: [Int: Int], scalars: [Int: Int])? {
        guard line >= 0, line < lineStarts.count, lineHasTab[line] else { return nil }
        var position = lineStarts[line], byteColumn = 0, scalarColumn = 0
        var columns = (bytes: [0: position], scalars: [0: position])
        while position < lineEnds[line] {
            if isCancelled() { return nil }
            let unit = bytes[position]
            let length = unit < 0x80 ? 1 : (unit < 0xe0 ? 2 : (unit < 0xf0 ? 3 : 4))
            guard length <= lineEnds[line] - position else { return nil }
            if unit == 9 {
                byteColumn = (byteColumn / 4 + 1) * 4
                scalarColumn = (scalarColumn / 4 + 1) * 4
            } else {
                byteColumn += length
                scalarColumn += 1
            }
            position += length
            columns.bytes[byteColumn] = position
            columns.scalars[scalarColumn] = position
        }
        return columns
    }

    func tabbedTextCandidateRanges(_ node: OpaquePointer, byteColumns: [Int: Int], scalarColumns: [Int: Int]) -> [NSRange] {
        let line = Int(cmark_node_get_start_line(node)) - 1
        let start = Int(cmark_node_get_start_column(node)) - 1
        let end = Int(cmark_node_get_end_column(node))
        guard cmark_node_get_type(node) == CMARK_NODE_TEXT, recoveredRanges[node] == nil, !possibleReferenceNodes.contains(node),
              paragraphLineShifts[node] == nil, line >= 0, line < lineStarts.count, lineHasTab[line],
              cmark_node_get_start_line(node) == cmark_node_get_end_line(node), start >= 0, end > start else { return [] }
        var starts: Set<Int> = [], ends: Set<Int> = []
        if start <= lineEnds[line] - lineStarts[line] { starts.insert(lineStarts[line] + start) }
        if end <= lineEnds[line] - lineStarts[line] { ends.insert(lineStarts[line] + end) }
        if let value = byteColumns[start] { starts.insert(value) }
        if let value = scalarColumns[start] { starts.insert(value) }
        if let value = byteColumns[end] { ends.insert(value) }
        if let value = scalarColumns[end] { ends.insert(value) }
        var ranges: Set<NSRange> = []
        for first in starts {
            for last in ends where last > first {
                guard let lower = utf16Offset(at: first), let upper = utf16Offset(at: last), upper > lower else { continue }
                ranges.insert(NSRange(location: lower, length: upper - lower))
            }
        }
        return Array(ranges)
    }

    // cmark columns around container tabs can be byte or visual positions.
    // Accept only a unique, fully confirmed literal text range.
    func tabbedLiteralTextRange(_ node: OpaquePointer, text: NSString, isCancelled: () -> Bool = { false }) -> NSRange? {
        guard cmark_node_get_type(node) == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(node) else { return nil }
        let value = String(cString: literal), length = (value as NSString).length
        let line = Int(cmark_node_get_start_line(node)) - 1
        let column = Int(cmark_node_get_start_column(node)), endColumn = Int(cmark_node_get_end_column(node))
        guard line >= 0, line < lineStarts.count, lineHasTab[line],
              cmark_node_get_start_line(node) == cmark_node_get_end_line(node), column > 0, length > 0,
              !value.utf16.contains(9), endColumn == column + value.utf8.count - 1,
              let start = utf16Offset(at: lineStarts[line]), let end = utf16Offset(at: lineEnds[line]) else { return nil }
        var offsets: Set<Int> = []
        let byteOffset = lineStarts[line] + column - 1
        if byteOffset <= lineEnds[line], let rawOffset = utf16Offset(at: byteOffset) { offsets.insert(rawOffset) }
        var offset = start, visual = 0
        while offset < end && visual < column - 1 {
            if isCancelled() { return nil }
            let unit = text.character(at: offset)
            guard unit < 128 else { break }
            let next = unit == 9 ? (visual / 4 + 1) * 4 : visual + 1
            if next > column - 1 { break }
            visual = next
            offset += 1
        }
        if visual == column - 1 { offsets.insert(offset) }
        let matches = offsets.filter { candidate in
            candidate >= start && candidate <= end && length <= end - candidate &&
                text.substring(with: NSRange(location: candidate, length: length)) == value
        }
        guard !isCancelled(), matches.count == 1, let match = matches.first else { return nil }
        return NSRange(location: match, length: length)
    }

    func headingAnchor(_ node: OpaquePointer) -> NSRange? {
        let line = Int(cmark_node_get_start_line(node)) - 1
        guard line >= 0, line < lineStarts.count,
              let offset = utf16Offset(at: lineStarts[line]) else { return nil }
        return NSRange(location: offset, length: 0)
    }

    func mathBlockRange(_ node: OpaquePointer) -> NSRange? {
        if let range = range(node) { return range }
        let first = Int(cmark_node_get_start_line(node)) - 1
        let last = Int(cmark_node_get_end_line(node)) - 1
        let startColumn = Int(cmark_node_get_start_column(node))
        let endColumn = Int(cmark_node_get_end_column(node))
        guard first >= 0, last >= first, last < lineStarts.count, startColumn > 0, endColumn > 0 else { return nil }
        let start = lineStarts[first] + startColumn - 1, end = lineStarts[last] + endColumn
        guard start >= lineStarts[first], start + 2 <= lineEnds[first], end <= lineEnds[last], end >= start + 4,
              bytes[start] == 36, bytes[start + 1] == 36, bytes[end - 2] == 36, bytes[end - 1] == 36,
              let firstUTF16 = utf16Offset(at: start), let lastUTF16 = utf16Offset(at: end) else { return nil }
        return NSRange(location: firstUTF16, length: lastUTF16 - firstUTF16)
    }

    func pairedMarkers(_ range: NSRange, characters: [UInt16], count: Int) -> [NSRange] {
        let start = range.location, end = NSMaxRange(range)
        guard range.length > count * 2, end <= units.count,
              characters.contains(units[start]) else { return [] }
        let character = units[start]
        guard units[start..<start + count].allSatisfy({ $0 == character }),
              units[end - count..<end].allSatisfy({ $0 == character }),
              units[start + count] != character, units[end - count - 1] != character else { return [] }
        return [NSRange(location: start, length: count), NSRange(location: end - count, length: count)]
    }

    func headingMarkers(_ range: NSRange, allowNoSpace: Bool = false) -> [NSRange] {
        let start = range.location, end = NSMaxRange(range)
        var index = start
        while index < end && units[index] == 35 { index += 1 }
        guard index > start, index - start <= 6, index < end else { return [] }
        let separator = units[index] == 32 || units[index] == 9 ? 1 : 0
        guard separator == 1 || allowNoSpace else { return [] }
        return [NSRange(location: start, length: index - start + separator)]
    }

    func codeRange(_ range: NSRange) -> (NSRange, [NSRange])? {
        let start = range.location, end = NSMaxRange(range)
        guard start > 0, end < units.count else { return nil }
        var left = start, right = end
        while left > 0 && units[left - 1] == 96 { left -= 1 }
        while right < units.count && units[right] == 96 { right += 1 }
        guard start - left > 0, start - left == right - end else { return nil }
        return (NSRange(location: left, length: right - left),
                [NSRange(location: left, length: start - left), NSRange(location: end, length: right - end)])
    }

    func linkMarkers(_ range: NSRange, node: OpaquePointer, mappedRange: ((OpaquePointer) -> NSRange?)? = nil) -> [NSRange] {
        let start = range.location, end = NSMaxRange(range)
        guard range.length >= 5, units[start] == 91, units[end - 1] == 41 else { return [] }
        var child = cmark_node_first_child(node), last: OpaquePointer?
        while let current = child { last = current; child = cmark_node_next(current) }
        guard let last else { return [] }
        let candidate = mappedRange.map { $0(last) } ?? self.range(last)
        guard let lastRange = candidate, lastRange.location >= start, lastRange.location <= end, lastRange.length >= 0,
              lastRange.length <= end - lastRange.location else { return [] }
        let suffix = NSMaxRange(lastRange)
        guard suffix + 2 < end, units[suffix] == 93, units[suffix + 1] == 40 else { return [] }
        return [NSRange(location: start, length: 1), NSRange(location: suffix, length: end - suffix)]
    }

    func quoteMarkers(_ range: NSRange) -> [NSRange] {
        let end = NSMaxRange(range)
        var index = range.location, markers: [NSRange] = []
        while index < end {
            let lineStart = index
            while index < end && units[index] == 32 && index - lineStart < 3 { index += 1 }
            if index < end && units[index] == 62 {
                markers.append(NSRange(location: index, length: 1))
            }
            while index < end && units[index] != 10 && units[index] != 13 { index += 1 }
            while index < end && (units[index] == 10 || units[index] == 13) { index += 1 }
        }
        return markers
    }

    func fenceMarkers(_ range: NSRange) -> [NSRange] {
        let start = range.location, end = NSMaxRange(range)
        guard start < end, units[start] == 96 || units[start] == 126 else { return [] }
        let character = units[start]
        var openingEnd = start
        while openingEnd < end && units[openingEnd] == character { openingEnd += 1 }
        guard openingEnd - start >= 3 else { return [] }
        var closeStart = end
        while closeStart > openingEnd && units[closeStart - 1] == character { closeStart -= 1 }
        var lineStart = closeStart
        while lineStart > 0 && units[lineStart - 1] != 10 && units[lineStart - 1] != 13 { lineStart -= 1 }
        guard end - closeStart >= openingEnd - start, closeStart - lineStart <= 3,
              units[lineStart..<closeStart].allSatisfy({ $0 == 32 }) else { return [] }
        return [NSRange(location: start, length: openingEnd - start), NSRange(location: closeStart, length: end - closeStart)]
    }
}
