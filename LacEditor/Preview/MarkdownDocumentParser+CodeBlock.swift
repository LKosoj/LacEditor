import Foundation
import cmark_gfm

/// Блоки кода ядра (U2.4): точные отрезки тела, ограждения и признак закрытия.
/// Число строк тела задаёт `literal` cmark, а не конец узла: у ограждённого блока `end_line` cmark всегда стоит на строке,
/// где блок закрыт, даже если его оборвал конец цитаты, пункта или документа (тогда это чужая строка).
extension MarkdownDocumentParser {
    struct CodeBlockLayout: Equatable, Sendable {
        /// От первого знака ограждения (у отступного — от начала первого отрезка тела); у закрытого до конца закрывающей строки,
        /// у незакрытого до конца последней строки тела вместе с её переводом строки.
        var range: NSRange
        /// `[открывающее]` или `[открывающее, закрывающее]`; у отступного пусто.
        var markers: [NSRange]
        /// От конца открывающего ограждения до конца строки, пробелы сохраняются; `nil` у отступного.
        var infoRange: NSRange?
        var isClosed: Bool
        /// Тело по строкам без префиксов контейнеров, ограждений и перевода строки.
        var bodySegments: [NSRange]
        /// Сколько пробелов у каждого отрезка дало раскрытие табов.
        var bodyPadding: [Int]
        /// У ограждённого — от начала строки после открывающей до начала закрывающей (у незакрытого до конца последней строки тела).
        var bodyRange: NSRange
    }

    /// `nil` — позицию подтвердить не удалось (склейка отрезков не равна `literal`, неожиданный `end_line`, закрытие не сошлось).
    static func codeBlockLayout(_ node: OpaquePointer, source: MarkdownSourcePositions, isCancelled: () -> Bool) -> CodeBlockLayout? {
        let units = source.units
        var fenceLength: Int32 = 0, fenceOffset: Int32 = 0, fenceCharacter: CChar = 0
        let isFenced = cmark_node_get_fenced(node, &fenceLength, &fenceOffset, &fenceCharacter) != 0
        // Строки литерала; пустой литерал — тела нет.
        let literalUnits = cmark_node_get_literal(node).map { Array(String(cString: $0).utf16) } ?? []
        var literalLines = literalUnits.split(separator: 10, omittingEmptySubsequences: false)
        if literalLines.last?.isEmpty == true { literalLines.removeLast() }
        let count = literalLines.count
        guard let position = source.firstPosition(node), position < units.count else { return nil }
        // Строки только по `\n`, `\r`, `\r\n` (как у cmark), а не по `NSString.lineRange`.
        func lineStart(of offset: Int) -> Int {
            var start = offset
            while start > 0 && units[start - 1] != 10 && units[start - 1] != 13 { start -= 1 }
            return start
        }
        /// Конец строки без перевода и начало следующей; `next == nil` — перевода нет, следующей строки нет.
        func bounds(_ start: Int) -> (end: Int, next: Int?) {
            var end = start
            while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
            guard end < units.count else { return (end, nil) }
            let next = end + (units[end] == 13 && end + 1 < units.count && units[end + 1] == 10 ? 2 : 1)
            return (end, next)
        }
        var quotes = 0
        var ancestor = cmark_node_parent(node)
        while let current = ancestor {
            if cmark_node_get_type(current) == CMARK_NODE_BLOCK_QUOTE { quotes += 1 }
            ancestor = cmark_node_parent(current)
        }
        let startLine = Int(cmark_node_get_start_line(node))
        let endLine = Int(cmark_node_get_end_line(node))
        let firstLineStart = lineStart(of: position)

        // Слева от тела могут стоять только пробелы, табы и `>` (по числу цитат); в первой строке отступного ещё маркер пункта.
        func isValidPrefix(_ range: Range<Int>, first: Bool) -> Bool {
            var marks = 0
            for index in range {
                let unit = units[index]
                if unit == 62 { marks += 1 } else if unit != 32 && unit != 9 {
                    guard first, unit == 45 || unit == 43 || unit == 42 || unit == 46 || unit == 41 || (48...57).contains(unit) else { return false }
                }
            }
            return first ? marks >= quotes : marks == quotes
        }

        var openingEnd = 0, infoRange: NSRange?, markers: [NSRange] = []
        var cursor: Int? = firstLineStart
        var bodyStart = firstLineStart
        if isFenced {
            let character = UInt16(UInt8(bitPattern: fenceCharacter))
            guard units[position] == character else { return nil }
            openingEnd = position
            while openingEnd < units.count && units[openingEnd] == character { openingEnd += 1 }
            guard openingEnd - position >= 3, Int(fenceLength) == (openingEnd - position) % 256 else { return nil }
            let opening = bounds(firstLineStart)
            guard openingEnd <= opening.end else { return nil }
            markers = [NSRange(location: position, length: openingEnd - position)]
            infoRange = NSRange(location: openingEnd, length: opening.end - openingEnd)
            cursor = opening.next
            bodyStart = opening.next ?? units.count
        }

        var segments: [NSRange] = [], padding: [Int] = []
        var lastLineNext = bodyStart
        for index in 0..<count {
            if isCancelled() { return nil }
            guard let start = cursor else { return nil }
            let line = bounds(start)
            let text = literalLines[index]
            var found: (Int, Int)?
            // Таб, наполовину попавший в отступ контейнера, cmark раскрывает: у литерала до трёх лишних пробелов.
            var missing = 0
            while missing <= text.count && missing <= 3 {
                let tail = text.dropFirst(missing)
                let from = line.end - tail.count
                if from >= start, units[from..<line.end].elementsEqual(tail),
                   isValidPrefix(start..<from, first: !isFenced && index == 0),
                   missing == 0 || (from > start && units[from - 1] == 9) {
                    found = (from, missing)
                    break
                }
                guard missing < text.count, text[text.startIndex + missing] == 32 else { break }
                missing += 1
            }
            guard let found else { return nil }
            segments.append(NSRange(location: found.0, length: line.end - found.0))
            padding.append(found.1)
            lastLineNext = line.next ?? units.count
            cursor = line.next
        }

        guard isFenced else {
            guard let first = segments.first, let last = segments.last else { return nil }
            let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            return CodeBlockLayout(range: whole, markers: [], infoRange: nil, isClosed: false, bodySegments: segments, bodyPadding: padding, bodyRange: whole)
        }

        // Закрытие: строка после тела должна быть последней строкой узла, лежать внутри контейнера и содержать ограждение.
        var closed = false
        let candidateLine = startLine + count + 1
        let parentEnd = cmark_node_parent(node).map { parent in
            cmark_node_get_type(parent) == CMARK_NODE_DOCUMENT ? Int.max : Int(cmark_node_get_end_line(parent))
        } ?? Int.max
        var closingMarker = NSRange(location: 0, length: 0), closingStart = 0, closingEnd = 0
        if endLine == candidateLine, parentEnd >= candidateLine {
            guard let start = cursor else { return nil }
            let line = bounds(start)
            var markerEnd = line.end
            while markerEnd > start && (units[markerEnd - 1] == 32 || units[markerEnd - 1] == 9) { markerEnd -= 1 }
            var markerStart = markerEnd
            while markerStart > start && units[markerStart - 1] == units[position] { markerStart -= 1 }
            // Противоречие cmark и текста: закрытие не подтверждено.
            guard markerEnd - markerStart >= openingEnd - position, isValidPrefix(start..<markerStart, first: false) else { return nil }
            closed = true
            closingMarker = NSRange(location: markerStart, length: markerEnd - markerStart)
            closingStart = start
            closingEnd = line.end
        } else if endLine != startLine + count && endLine != candidateLine {
            return nil
        }
        if closed {
            return CodeBlockLayout(range: NSRange(location: position, length: closingEnd - position), markers: markers + [closingMarker],
                                   infoRange: infoRange, isClosed: true, bodySegments: segments, bodyPadding: padding,
                                   bodyRange: NSRange(location: bodyStart, length: closingStart - bodyStart))
        }
        return CodeBlockLayout(range: NSRange(location: position, length: lastLineNext - position), markers: markers, infoRange: infoRange,
                               isClosed: false, bodySegments: segments, bodyPadding: padding,
                               bodyRange: NSRange(location: bodyStart, length: lastLineNext - bodyStart))
    }
}
