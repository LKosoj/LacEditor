import Foundation
import cmark_gfm

enum MarkdownReadableTextParser {
    // Uses the caller's existing cmark tree; no second Markdown parse.
    static func build(root: OpaquePointer, source: MarkdownPresentationParser.Source, text raw: NSString,
                      mathExtension: OpaquePointer, inlineMath: Set<OpaquePointer>,
                      isCancelled: () -> Bool = { false }) -> MarkdownReadableText? {
        var fragments: [MarkdownReadableText.Fragment] = []
        var unsupported: [NSRange] = []
        func separator(_ position: Int) {
            fragments.append(.init(sourceRange: NSRange(location: position, length: 0), text: "\n", matchesSource: false))
        }
        func append(_ value: String, range: NSRange, mapInline: Bool = false) {
            guard !value.isEmpty else { return }
            let spelling = raw.substring(with: range)
            let matches = spelling == value
            let pieces = mapInline && !matches
                ? MarkdownInlineTextProjection.pieces(spelling: spelling as NSString, literal: value, sourceOffset: range.location, isCancelled: isCancelled)
                : nil
            fragments.append(.init(sourceRange: range, text: value, matchesSource: matches, pieces: pieces))
        }
        func visit(_ node: OpaquePointer, container: NSRange, cellPositions: MarkdownPresentationParser.Source.TableCellPositions?) {
            guard !isCancelled() else { return }
            guard let pointer = cmark_node_get_type_string(node) else { return }
            let kind = String(cString: pointer)
            let positions = kind == "table_cell" ? source.tableCellPositions(node) : cellPositions
            let confirmed = positions.flatMap { source.tableInlineRange(node, positions: $0) } ?? source.range(node)
            let range = confirmed ?? container
            if inlineMath.contains(node) || cmark_node_get_syntax_extension(node) == mathExtension {
                separator(range.location)
                return
            }
            if kind == "paragraph", let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
               let literal = cmark_node_get_literal(child), String(cString: literal) == "[toc]",
               raw.substring(with: range) == "[toc]" { separator(range.location); return }
            let block = ["paragraph", "heading", "table_row", "table_header", "table_cell", "code_block", "thematic_break"].contains(kind)
            if block || kind == "image" { separator(range.location) }
            switch kind {
            case "text":
                if let literal = cmark_node_get_literal(node) { append(String(cString: literal), range: range, mapInline: true) }
            case "code":
                if let literal = cmark_node_get_literal(node) {
                    let value = String(cString: literal)
                    var body = range, ticks = 0
                    let includesDelimiters = raw.substring(with: range) != value
                    while includesDelimiters, ticks < range.length, raw.character(at: range.location + ticks) == 96 {
                        if isCancelled() { return }
                        ticks += 1
                    }
                    if ticks > 0, ticks * 2 <= range.length,
                       (0..<ticks).allSatisfy({ !isCancelled() && raw.character(at: NSMaxRange(range) - 1 - $0) == 96 }) {
                        body = NSRange(location: range.location + ticks, length: range.length - ticks * 2)
                    }
                    if body.length >= 2, raw.character(at: body.location) == 32, raw.character(at: NSMaxRange(body) - 1) == 32 {
                        let trimmed = NSRange(location: body.location + 1, length: body.length - 2)
                        if raw.substring(with: trimmed) == value { body = trimmed }
                    }
                    append(value, range: body)
                }
            case "code_block":
                let language = cmark_node_get_fence_info(node).map { String(cString: $0).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "" } ?? ""
                if !["mermaid", "flow", "sequence"].contains(language), let literal = cmark_node_get_literal(node) {
                    let value = String(cString: literal)
                    let block = raw.substring(with: range) as NSString
                    let match = block.range(of: value, options: .literal)
                    if !value.isEmpty, match.location != NSNotFound {
                        let remaining = NSRange(location: NSMaxRange(match), length: block.length - NSMaxRange(match))
                        if block.range(of: value, options: .literal, range: remaining).location == NSNotFound {
                            append(value, range: NSRange(location: range.location + match.location, length: match.length))
                        } else { append(value, range: range) }
                    } else { append(value, range: range) }
                }
            case "softbreak", "linebreak":
                separator(fragments.last.map { NSMaxRange($0.sourceRange) } ?? range.location)
            case "html_block":
                let value = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
                let commentOnly: Bool
                if value.hasPrefix("<!--"), let close = value.range(of: "-->") {
                    commentOnly = value[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                } else { commentOnly = false }
                if !commentOnly && MarkdownHTMLMediaService.audioSource(in: value) == nil {
                    unsupported.append(range)
                }
            case "html_inline":
                let value = cmark_node_get_literal(node).map { String(cString: $0).lowercased() } ?? ""
                if ["<br>", "<br/>", "<br />"].contains(value) { separator(range.location) }
                else if value.contains("<script") || value.contains("<style") { unsupported.append(container) }
                else if value.contains("<img") { unsupported.append(range) }
            case "footnote_reference": break
            default:
                var child = cmark_node_first_child(node)
                while let current = child, !isCancelled() {
                    visit(current, container: range, cellPositions: positions)
                    child = cmark_node_next(current)
                }
            }
            if block || kind == "image" { separator(NSMaxRange(range)) }
        }
        visit(root, container: NSRange(location: 0, length: raw.length), cellPositions: nil)
        guard !isCancelled() else { return nil }
        return MarkdownReadableText(sourceLength: raw.length, fragments: fragments, unsupportedRanges: unsupported)
    }
}
