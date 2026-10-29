import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct MarkdownLinkInput: Equatable {
    let label: String
    let address: String
}

enum MarkdownLinkEditingService {
    struct Context {
        let range: NSRange
        let label: String
        let address: String
        let title: String
        let titleSuffix: String
    }

    private struct Node {
        let kind: String
        let range: NSRange
        let address: String
        let title: String
    }

    static func initial(in text: NSString, selection: NSRange) -> MarkdownLinkInput? {
        guard let context = context(in: text, selection: selection) else { return nil }
        return MarkdownLinkInput(label: context.label, address: context.address)
    }

    static func edit(in text: NSString, selection: NSRange, input: MarkdownLinkInput) -> MarkdownFormattingEdit? {
        guard !input.label.isEmpty, !input.address.isEmpty,
              input.label.rangeOfCharacter(from: .newlines) == nil,
              input.address.rangeOfCharacter(from: .newlines) == nil,
              input.address.rangeOfCharacter(from: .controlCharacters) == nil,
              let context = context(in: text, selection: selection) else { return nil }
        let escapedAddress = input.address.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>")
        let replacement = "[\(input.label)](<\(escapedAddress)>\(context.titleSuffix))"
        let candidate = text.replacingCharacters(in: context.range, with: replacement)
        let candidateRange = NSRange(location: context.range.location, length: (replacement as NSString).length)
        guard let nodes = nodes(in: candidate), nodes.contains(where: {
            $0.kind == "link" && $0.range == candidateRange && $0.address == input.address && $0.title == context.title
        }) else { return nil }
        return MarkdownFormattingEdit(range: context.range, replacement: replacement,
                                      selectionRange: NSRange(location: context.range.location + 1, length: (input.label as NSString).length))
    }

    private static func context(in text: NSString, selection: NSRange) -> Context? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location,
              let nodes = nodes(in: text as String) else { return nil }
        let end = NSMaxRange(selection)
        func intersects(_ range: NSRange) -> Bool {
            selection.length == 0
                ? selection.location >= range.location && selection.location < NSMaxRange(range)
                : selection.location < NSMaxRange(range) && end > range.location
        }
        guard !nodes.contains(where: { ["code", "code_block", "image", "unresolved"].contains($0.kind) && intersects($0.range) }) else { return nil }
        for node in nodes {
            guard intersects(node.range) else { continue }
            if node.kind == "link" {
                guard selection.length == 0 || selection == node.range,
                      let parts = inlineParts(text.substring(with: node.range)) else { return nil }
                return Context(range: node.range, label: parts.label, address: node.address, title: node.title, titleSuffix: parts.suffix)
            }
        }
        let selected = text.substring(with: selection)
        guard selected.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return Context(range: selection, label: selected, address: "", title: "", titleSuffix: "")
    }

    private static func inlineParts(_ source: String) -> (label: String, suffix: String)? {
        let units = Array(source.utf16)
        guard units.first == 91, !units.contains(96) else { return nil }
        var depth = 1, index = 1
        while index < units.count {
            if units[index] == 92 && index + 1 < units.count { index += 2; continue }
            if units[index] == 91 { depth += 1 }
            if units[index] == 93 {
                depth -= 1
                if depth == 0 {
                    guard index + 1 < units.count, units[index + 1] == 40 else { return nil }
                    let label = (source as NSString).substring(with: NSRange(location: 1, length: index - 1))
                    var cursor = index + 2
                    while cursor < units.count && (units[cursor] == 32 || units[cursor] == 9) { cursor += 1 }
                    guard cursor < units.count - 1 else { return nil }
                    if units[cursor] == 60 {
                        cursor += 1
                        while cursor < units.count && units[cursor] != 62 {
                            if units[cursor] == 92 && cursor + 1 < units.count { cursor += 1 }
                            cursor += 1
                        }
                        guard cursor < units.count else { return nil }
                        cursor += 1
                    } else {
                        var parentheses = 0
                        while cursor < units.count - 1 {
                            if units[cursor] == 92 && cursor + 1 < units.count { cursor += 2; continue }
                            if units[cursor] == 40 { parentheses += 1 }
                            if units[cursor] == 41 {
                                if parentheses == 0 { break }
                                parentheses -= 1
                            }
                            if parentheses == 0 && (units[cursor] == 32 || units[cursor] == 9) { break }
                            cursor += 1
                        }
                        guard parentheses == 0 else { return nil }
                    }
                    guard units.last == 41, cursor <= units.count - 1 else { return nil }
                    let suffix = (source as NSString).substring(with: NSRange(location: cursor, length: units.count - 1 - cursor))
                    return (label, suffix)
                }
            }
            index += 1
        }
        return nil
    }

    private static func nodes(in text: String) -> [Node]? {
        guard !text.utf8.contains(0), let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return nil }
        defer { cmark_parser_free(parser) }
        cmark_gfm_core_extensions_ensure_registered()
        "table".withCString { if let ext = cmark_find_syntax_extension($0) { cmark_parser_attach_syntax_extension(parser, ext) } }
        text.withCString { cmark_parser_feed(parser, $0, text.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }
        let ns = text as NSString
        var lines: [(start: Int, text: String)] = [], start = 0, offset = 0
        while offset < ns.length {
            if ns.character(at: offset) == 10 || ns.character(at: offset) == 13 {
                if ns.character(at: offset) == 13 && offset + 1 < ns.length && ns.character(at: offset + 1) == 10 { offset += 1 }
                offset += 1
                lines.append((start, ns.substring(with: NSRange(location: start, length: offset - start))))
                start = offset
            } else { offset += 1 }
        }
        lines.append((start, ns.substring(from: start)))
        func position(_ line: Int, _ column: Int) -> Int? {
            guard line > 0, line <= lines.count, column >= 0 else { return nil }
            let item = lines[line - 1]
            guard !item.text.contains("\t"), column <= item.text.utf8.count,
                  let byte = item.text.utf8.index(item.text.utf8.startIndex, offsetBy: column, limitedBy: item.text.utf8.endIndex),
                  let index = String.Index(byte, within: item.text) else { return nil }
            return item.start + item.text[..<index].utf16.count
        }
        var result: [Node] = []
        func visit(_ node: UnsafeMutablePointer<cmark_node>) {
            if let name = cmark_node_get_type_string(node) {
                let kind = String(cString: name)
                if ["link", "image", "code", "code_block"].contains(kind) {
                    func unresolved() {
                        let first = Int(cmark_node_get_start_line(node)) - 1
                        let last = Int(cmark_node_get_end_line(node)) - 1
                        if first >= 0, last >= first, last < lines.count {
                            let end = lines[last].start + (lines[last].text as NSString).length
                            result.append(Node(kind: "unresolved", range: NSRange(location: lines[first].start, length: end - lines[first].start), address: "", title: ""))
                        } else {
                            result.append(Node(kind: "unresolved", range: NSRange(location: 0, length: ns.length), address: "", title: ""))
                        }
                    }
                    guard let start = position(Int(cmark_node_get_start_line(node)), Int(cmark_node_get_start_column(node)) - 1),
                          cmark_node_get_end_column(node) > 0,
                          let end = position(Int(cmark_node_get_end_line(node)), Int(cmark_node_get_end_column(node))), end >= start else {
                        unresolved()
                        return
                    }
                    var range = NSRange(location: start, length: end - start)
                    if kind == "code" {
                        var left = start, right = end
                        while left > 0 && ns.character(at: left - 1) == 96 { left -= 1 }
                        while right < ns.length && ns.character(at: right) == 96 { right += 1 }
                        guard start - left > 0, start - left == right - end else { unresolved(); return }
                        range = NSRange(location: left, length: right - left)
                    }
                    let address = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                    let title = cmark_node_get_title(node).map { String(cString: $0) } ?? ""
                    result.append(Node(kind: kind, range: range, address: address, title: title))
                }
            }
            var child = cmark_node_first_child(node)
            while let current = child { visit(current); child = cmark_node_next(current) }
        }
        visit(root)
        return result
    }
}
