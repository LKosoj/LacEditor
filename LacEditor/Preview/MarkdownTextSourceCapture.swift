import Foundation
import cmark_gfm

// GFM's email postprocessor splits text without preserving source positions.
// Capture its input in the same parse, then map only exactly verified splits.
enum MarkdownTextSourceCapture {
    struct Origin {
        let node: OpaquePointer
        let next: OpaquePointer?
        let literal: String
    }

    static func origins(in root: OpaquePointer) -> [Origin] {
        var result: [Origin] = []
        func visit(_ node: OpaquePointer, inLink: Bool) {
            let isLink = cmark_node_get_type(node) == CMARK_NODE_LINK
            if !inLink, !isLink, cmark_node_get_type(node) == CMARK_NODE_TEXT,
               let pointer = cmark_node_get_literal(node) {
                let literal = String(cString: pointer)
                if literal.contains("@") { result.append(Origin(node: node, next: cmark_node_next(node), literal: literal)) }
            }
            var child = cmark_node_first_child(node)
            while let current = child {
                visit(current, inLink: inLink || isLink)
                child = cmark_node_next(current)
            }
        }
        visit(root, inLink: false)
        return result
    }

    static func ranges(_ origins: [Origin], source: MarkdownPresentationParser.Source,
                       isCancelled: () -> Bool = { false }) -> [OpaquePointer: NSRange] {
        var recovered: [OpaquePointer: NSRange] = [:]
        var cellPositions: [OpaquePointer: MarkdownPresentationParser.Source.TableCellPositions?] = [:]
        for origin in origins {
            if isCancelled() { return [:] }
            guard cmark_node_next(origin.node) != origin.next else { continue }
            var cell = cmark_node_parent(origin.node)
            while let parent = cell, String(cString: cmark_node_get_type_string(parent)) != "table_cell" { cell = cmark_node_parent(parent) }
            let positions: MarkdownPresentationParser.Source.TableCellPositions?
            if let cell {
                if let cached = cellPositions[cell] { positions = cached }
                else {
                    positions = source.tableCellPositions(cell)
                    cellPositions[cell] = .some(positions)
                }
            } else { positions = nil }
            guard var rawRange = positions.flatMap({ source.tableInlineRange(origin.node, positions: $0) }) ?? source.range(origin.node) else { continue }
            // A preceding GFM web autolink can leave the text's old end column
            // inside the following link. Its confirmed start is the boundary.
            if let next = origin.next, cmark_node_get_type(next) == CMARK_NODE_LINK,
               let following = source.linkRange(next, tableCell: cell, tablePositions: positions),
               following.location >= rawRange.location, following.location < NSMaxRange(rawRange) {
                rawRange.length = following.location - rawRange.location
            }
            let spelling = String(decoding: source.units[rawRange.location..<NSMaxRange(rawRange)], as: UTF16.self) as NSString
            guard let pieces = MarkdownInlineTextProjection.pieces(spelling: spelling, literal: origin.literal,
                sourceOffset: rawRange.location, isCancelled: isCancelled) else { continue }
            let literal = origin.literal as NSString
            var offsets = [0]
            for piece in pieces { offsets.append(offsets.last! + (piece.text as NSString).length) }
            var pieceCursor = 0
            var semantic = 0, current: OpaquePointer? = origin.node
            var mapped: [OpaquePointer: NSRange] = [:], valid = true
            while let node = current, node != origin.next {
                if isCancelled() { return [:] }
                let value: String, child: OpaquePointer?
                if cmark_node_get_type(node) == CMARK_NODE_TEXT, let pointer = cmark_node_get_literal(node) {
                    value = String(cString: pointer); child = nil
                } else if cmark_node_get_type(node) == CMARK_NODE_LINK,
                          cmark_node_get_start_line(node) == 0, let text = cmark_node_first_child(node),
                          cmark_node_next(text) == nil, cmark_node_get_type(text) == CMARK_NODE_TEXT,
                          let pointer = cmark_node_get_literal(text) {
                    value = String(cString: pointer); child = text
                } else { valid = false; break }
                let length = (value as NSString).length
                guard semantic <= literal.length, length <= literal.length - semantic,
                      literal.substring(with: NSRange(location: semantic, length: length)).utf16.elementsEqual(value.utf16),
                      let range = sourceRange(for: NSRange(location: semantic, length: length), pieces: pieces, offsets: offsets, cursor: &pieceCursor, emptyAt: rawRange.location, isCancelled: isCancelled) else {
                    valid = false; break
                }
                mapped[node] = range
                if let child { mapped[child] = range }
                semantic += length
                current = cmark_node_next(node)
            }
            if valid, current == origin.next, semantic == literal.length { recovered.merge(mapped) { _, new in new } }
        }
        return recovered
    }

    private static func sourceRange(for selection: NSRange, pieces: [MarkdownReadableText.Piece], offsets: [Int],
                                    cursor: inout Int, emptyAt: Int, isCancelled: () -> Bool) -> NSRange? {
        if selection.length == 0 { return NSRange(location: emptyAt, length: 0) }
        var first: Int?, end = 0
        while cursor < pieces.count {
            if isCancelled() { return nil }
            let offset = offsets[cursor], length = offsets[cursor + 1] - offset
            if offset >= NSMaxRange(selection) { break }
            if offsets[cursor + 1] <= selection.location { cursor += 1; continue }
            let piece = pieces[cursor]
            let part = NSIntersectionRange(selection, NSRange(location: offset, length: length))
            let range: NSRange
            if part.length == length { range = piece.sourceRange }
            else {
                guard piece.matchesSource else { return nil }
                range = NSRange(location: piece.sourceRange.location + part.location - offset, length: part.length)
            }
            if first == nil { first = range.location }
            end = NSMaxRange(range)
            if offsets[cursor + 1] > NSMaxRange(selection) { break }
            cursor += 1
        }
        return first.map { NSRange(location: $0, length: end - $0) }
    }
}
