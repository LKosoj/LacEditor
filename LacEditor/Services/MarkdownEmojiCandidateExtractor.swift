import Foundation
import cmark_gfm

/// Finds literal shortcode spellings only in text nodes of the current cmark tree.
enum MarkdownEmojiCandidateExtractor {
    struct Candidate: Equatable, Sendable {
        let name: String
        let range: NSRange
    }

    static func candidates(in root: OpaquePointer, source: MarkdownPresentationParser.Source,
                           text: NSString, isCancelled: () -> Bool = { false },
                           onSmartRange: ((NSRange) -> Void)? = nil,
                           onTextRange: ((OpaquePointer, NSRange) -> Void)? = nil,
                           onCandidate: ((OpaquePointer, Int, Candidate) -> Void)? = nil) -> [Candidate] {
        var result: [Candidate] = []
        var tablePositions: [OpaquePointer: MarkdownPresentationParser.Source.TableCellPositions] = [:]
        var failedTablePositions: Set<OpaquePointer> = []
        var htmlContext = MarkdownImageUploadService.HTMLContext()
        func positions(_ node: OpaquePointer) -> (OpaquePointer?, MarkdownPresentationParser.Source.TableCellPositions?) {
            var current = cmark_node_parent(node)
            while let item = current {
                if isCancelled() { return (nil, nil) }
                if let name = cmark_node_get_type_string(item), String(cString: name) == "table_cell" {
                    if let cached = tablePositions[item] { return (item, cached) }
                    if failedTablePositions.contains(item) { return (item, nil) }
                    guard let value = source.tableCellPositions(item, isCancelled: isCancelled) else { failedTablePositions.insert(item); return (item, nil) }
                    tablePositions[item] = value
                    return (item, value)
                }
                current = cmark_node_parent(item)
            }
            return (nil, nil)
        }
        func isName(_ unit: unichar) -> Bool {
            (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 43 || unit == 45
        }
        func escaped(_ location: Int) -> Bool {
            var index = location, count = 0
            while index > 0 && text.character(at: index - 1) == 92 {
                if isCancelled() { return true }
                index -= 1; count += 1
            }
            return count % 2 != 0
        }
        func visit(_ node: OpaquePointer, suppress: Bool = false) {
            if isCancelled() { return }
            guard let rawType = cmark_node_get_type_string(node) else { return }
            let type = String(cString: rawType)
            if type == "html_inline" || type == "html_block" {
                let (cell, map) = positions(node)
                let range = cell != nil ? map.flatMap { source.tableInlineRange(node, positions: $0) } : source.range(node)
                if let range { _ = htmlContext.consume(source: text, range: range, isCancelled: isCancelled) }
                else { htmlContext.invalidate() }
                return
            }
            if type == "code" || type == "code_block" || type == "image" || type == "custom_inline" || type == "custom_block" { return }
            if type == "link" {
                let (cell, map) = positions(node)
                guard let range = source.linkRange(node, tableCell: cell, tablePositions: map),
                      range.location < text.length, text.character(at: range.location) == 91 else { return }
            }
            if type == "text", let literal = cmark_node_get_literal(node) {
                guard !suppress && !htmlContext.inRawContext else { return }
                let (cell, map) = positions(node)
                let range: NSRange?
                if cell != nil, let map { range = source.tableInlineRange(node, positions: map) }
                else if cell != nil { range = nil }
                else { range = source.range(node) }
                guard let range, range.location <= text.length, range.length <= text.length - range.location,
                      let pieces = MarkdownInlineTextProjection.pieces(spelling: text.substring(with: range) as NSString,
                          literal: String(cString: literal), sourceOffset: range.location, isCancelled: isCancelled) else { return }
                var displayOffset = 0
                var smartRun: NSRange?
                func flushSmartRun() {
                    if let smartRun { onSmartRange?(smartRun) }
                    smartRun = nil
                }
                for piece in pieces {
                    if isCancelled() { return }
                    let value = piece.text as NSString
                    defer { displayOffset += value.length }
                    let confirmedSmart: Bool
                    if !piece.matchesSource && onSmartRange != nil && piece.sourceRange.length <= 3 {
                        let sourcePiece = text.substring(with: piece.sourceRange)
                        confirmedSmart = (sourcePiece == "\"" && (piece.text == "“" || piece.text == "”")) ||
                            (sourcePiece == "'" && (piece.text == "‘" || piece.text == "’")) ||
                            (sourcePiece == "--" && piece.text == "–") || (sourcePiece == "---" && piece.text == "—") ||
                            (sourcePiece == "..." && piece.text == "…")
                    } else { confirmedSmart = false }
                    if piece.matchesSource || confirmedSmart {
                        if let run = smartRun, NSMaxRange(run) == piece.sourceRange.location {
                            smartRun = NSRange(location: run.location, length: run.length + piece.sourceRange.length)
                        } else { flushSmartRun(); smartRun = piece.sourceRange }
                    } else { flushSmartRun() }
                    guard piece.matchesSource else { continue }
                    onTextRange?(node, piece.sourceRange)
                    var position = 0
                    while position < value.length {
                        if isCancelled() { return }
                        guard value.character(at: position) == 58 else { position += 1; continue }
                        var end = position + 1
                        while end < value.length && isName(value.character(at: end)) {
                            if isCancelled() { return }
                            end += 1
                        }
                        if end > position + 1 && end < value.length && value.character(at: end) == 58 {
                            let start = piece.sourceRange.location + position
                            if !escaped(start) {
                                let candidate = Candidate(name: value.substring(with: NSRange(location: position + 1, length: end - position - 1)),
                                                          range: NSRange(location: start, length: end - position + 1))
                                result.append(candidate)
                                onCandidate?(node, displayOffset + position, candidate)
                            }
                            position = end + 1
                        } else { position += 1 }
                    }
                }
                flushSmartRun()
                return
            }
            // Accept only HTML siblings already confirmed as a simple underline pair.
            var htmlNodes: [OpaquePointer] = [], probe = cmark_node_first_child(node)
            while let item = probe {
                if isCancelled() { return }
                if let name = cmark_node_get_type_string(item), String(cString: name) == "html_inline" { htmlNodes.append(item) }
                probe = cmark_node_next(item)
            }
            var suppressChildren = suppress
            if !htmlNodes.isEmpty {
                let pairs = MarkdownPresentationParser.underlines(in: node, source: source, text: text, isCancelled: isCancelled)
                let confirmed = Set(pairs.flatMap { [$0.0, $0.1] })
                if isCancelled() { return }
                if !htmlNodes.allSatisfy({ confirmed.contains($0) }) { suppressChildren = true }
            }
            var child = cmark_node_first_child(node)
            while let item = child {
                if isCancelled() { return }
                visit(item, suppress: suppressChildren)
                child = cmark_node_next(item)
            }
        }
        visit(root)
        return isCancelled() ? [] : result
    }
}
