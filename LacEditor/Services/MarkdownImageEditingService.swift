import Foundation
import cmark_gfm
import cmark_gfm_extensions
import Yams
import SwiftTreeSitter
import TreeSitterYAML

struct MarkdownResourcePaths: Sendable {
    static func requiresRoot(_ address: String) -> Bool {
        address.hasPrefix("/") && !address.hasPrefix("//") && URL(string: address)?.scheme == nil
    }
    enum PathError: LocalizedError {
        case invalidRoot
        var errorDescription: String? { L10n.tr("图片资源根路径无效") }
    }
    let document: URL?
    let root: URL?

    init(text: String, document: URL?) throws {
        self.document = document
        guard let metadata = try PandocExportService.yamlFrontMatter(text),
              let field = metadata.first(where: { $0.key.scalar?.string == "typora-root-url" })?.value else {
            root = nil
            return
        }
        guard field.tag == Tag(.str), let value = field.scalar?.string, !value.isEmpty else { throw PathError.invalidRoot }
        var path = value
        if path.contains("${filename}") {
            guard let document, document.isFileURL else { throw PathError.invalidRoot }
            path = path.replacingOccurrences(of: "${filename}", with: document.lastPathComponent)
        }
        if let url = URL(string: path), url.scheme != nil {
            guard url.isFileURL else { throw PathError.invalidRoot }
            root = url.standardizedFileURL
        } else if path.hasPrefix("/") {
            root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            guard let document, document.isFileURL else { throw PathError.invalidRoot }
            root = URL(fileURLWithPath: path, isDirectory: true, relativeTo: document.deletingLastPathComponent()).standardizedFileURL
        }
    }

    func resolve(_ address: String) -> URL? {
        if let absolute = URL(string: address), absolute.scheme != nil { return absolute }
        let base: URL?
        let path: String
        if Self.requiresRoot(address), let root {
            base = root.appendingPathComponent("", isDirectory: true)
            path = String(address.dropFirst())
        } else {
            base = address.hasPrefix("/") ? URL(fileURLWithPath: "/", isDirectory: true) : document?.deletingLastPathComponent()
            path = address
        }
        guard let base else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }
}

struct MarkdownImageInput: Equatable {
    let alt: String
    let address: String
    let title: String
}

enum MarkdownImageEditingService {
    private struct Node {
        let kind: String
        let range: NSRange
        let address: String
        let alt: String
        let title: String
        var complexAlt = false
    }

    static func rootPathEdit(in text: String, path: String, selection: NSRange) -> MarkdownFormattingEdit? {
        let raw = text as NSString
        guard !path.isEmpty, selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= raw.length, selection.length <= raw.length - selection.location,
              let encoded = try? JSONEncoder().encode(path), let quoted = String(data: encoded, encoding: .utf8) else { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : (text.contains("\n") ? "\n" : (text.contains("\r") ? "\r" : "\n"))
        let editRange: NSRange, replacement: String
        if let block = MarkdownPresentationParser.frontMatter(text), block.markers.count == 2 {
            let start = NSMaxRange(block.markers[0]), end = block.markers[1].location
            guard end >= start else { return nil }
            let yaml = raw.substring(with: NSRange(location: start, length: end - start))
            let yamlText = yaml as NSString
            let parsed: Yams.Node?
            do { parsed = try Yams.compose(yaml: yaml, PandocExportService.yaml12Resolver()) }
            catch { return nil }
            guard parsed == nil || parsed?.mapping != nil else { return nil }
            let parser = SwiftTreeSitter.Parser()
            do { try parser.setLanguage(Language(language: tree_sitter_yaml())) }
            catch { return nil }
            guard let tree = parser.parse(yaml), let root = tree.rootNode, !root.hasError else { return nil }
            func range(_ node: SwiftTreeSitter.Node) -> NSRange? {
                let bytes = node.byteRange
                guard bytes.lowerBound % 2 == 0, bytes.upperBound % 2 == 0 else { return nil }
                let location = Int(bytes.lowerBound / 2), length = Int((bytes.upperBound - bytes.lowerBound) / 2)
                guard location <= yamlText.length, length <= yamlText.length - location else { return nil }
                return NSRange(location: location, length: length)
            }
            func topMapping(_ node: SwiftTreeSitter.Node) -> SwiftTreeSitter.Node? {
                if ["block_mapping", "flow_mapping"].contains(node.nodeType ?? "") { return node }
                guard ["stream", "document", "block_node", "flow_node"].contains(node.nodeType ?? "") else { return nil }
                for index in 0..<node.namedChildCount {
                    if let child = node.namedChild(at: index), let found = topMapping(child) { return found }
                }
                return nil
            }
            let mapping = topMapping(root)
            var valueNode: SwiftTreeSitter.Node?, emptyValueLocation: Int?, pairCount = 0
            if let mapping {
                for index in 0..<mapping.namedChildCount {
                    guard let pair = mapping.namedChild(at: index), ["block_mapping_pair", "flow_pair"].contains(pair.nodeType ?? ""),
                          let key = pair.child(byFieldName: "key"), let keyRange = range(key) else { continue }
                    pairCount += 1
                    guard let keyNode = try? Yams.compose(yaml: yamlText.substring(with: keyRange), PandocExportService.yaml12Resolver()),
                          keyNode.scalar?.string == "typora-root-url" else { continue }
                    guard valueNode == nil, emptyValueLocation == nil else { return nil }
                    if let value = pair.child(byFieldName: "value") { valueNode = value }
                    else {
                        guard let colon = (0..<pair.childCount).compactMap({ pair.child(at: $0) }).first(where: { $0.nodeType == ":" }),
                              let position = range(colon) else { return nil }
                        emptyValueLocation = start + NSMaxRange(position)
                    }
                }
            } else if parsed != nil { return nil }
            if let valueNode {
                var target = valueNode
                if ["flow_node", "block_node"].contains(valueNode.nodeType ?? "") {
                    let allowed: Set<String> = ["plain_scalar", "single_quote_scalar", "double_quote_scalar", "block_scalar", "alias"]
                    guard let scalar = (0..<valueNode.namedChildCount).compactMap({ valueNode.namedChild(at: $0) })
                        .first(where: { allowed.contains($0.nodeType ?? "") }) else { return nil }
                    target = scalar
                }
                guard let local = range(target) else { return nil }
                editRange = NSRange(location: start + local.location, length: local.length)
                replacement = quoted
            } else if let position = emptyValueLocation {
                editRange = NSRange(location: position, length: 0)
                replacement = " " + quoted
            } else if let mapping, mapping.nodeType == "flow_mapping" {
                guard let local = range(mapping), local.length > 0 else { return nil }
                editRange = NSRange(location: start + NSMaxRange(local) - 1, length: 0)
                let finalToken = (0..<mapping.childCount).reversed().compactMap { mapping.child(at: $0) }
                    .first(where: { !$0.isExtra && $0.nodeType != "}" })?.nodeType
                replacement = (pairCount == 0 || finalToken == "," ? "" : ", ") + "typora-root-url: " + quoted
            } else {
                editRange = NSRange(location: end, length: 0)
                replacement = "typora-root-url: " + quoted + newline
            }
        } else {
            let offset = raw.length > 0 && raw.character(at: 0) == 0xfeff ? 1 : 0
            let remainder = raw.substring(from: offset)
            if remainder.hasPrefix("---\n") || remainder.hasPrefix("---\r") { return nil }
            editRange = NSRange(location: offset, length: 0)
            replacement = "---" + newline + "typora-root-url: " + quoted + newline + "---" + newline + newline
        }
        let candidate = raw.replacingCharacters(in: editRange, with: replacement)
        guard let metadata = try? PandocExportService.yamlFrontMatter(candidate),
              let root = metadata["typora-root-url"], root.tag == Tag(.str), root.scalar?.string == path else { return nil }
        func shifted(_ position: Int) -> Int {
            if position < editRange.location { return position }
            if position >= NSMaxRange(editRange) { return position + (replacement as NSString).length - editRange.length }
            return editRange.location + (replacement as NSString).length
        }
        let first = shifted(selection.location), last = shifted(NSMaxRange(selection))
        return MarkdownFormattingEdit(range: editRange, replacement: replacement,
                                      selectionRange: NSRange(location: first, length: max(0, last - first)))
    }

    static func address(for image: URL, document: URL?) -> String? {
        guard image.isFileURL else { return nil }
        let file = image.standardizedFileURL
        guard let document else { return file.absoluteString }
        guard document.isFileURL else { return nil }
        let base = document.standardizedFileURL.deletingLastPathComponent().pathComponents
        let path = file.pathComponents
        var common = 0
        while common < min(base.count, path.count) && base[common] == path[common] { common += 1 }
        guard common > 0 else { return file.absoluteString }
        let segments = Array(repeating: "..", count: base.count - common) + Array(path.dropFirst(common))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        guard encoded.count == segments.count, !encoded.isEmpty else { return nil }
        return encoded.joined(separator: "/")
    }

    static func initial(in text: NSString, selection: NSRange) -> MarkdownImageInput? {
        guard let context = context(in: text, selection: selection) else { return nil }
        if let image = context.image { return MarkdownImageInput(alt: image.alt, address: image.address, title: image.title) }
        return MarkdownImageInput(alt: text.substring(with: selection), address: "", title: "")
    }

    static func edit(in text: NSString, selection: NSRange, input: MarkdownImageInput) -> MarkdownFormattingEdit? {
        guard !input.address.isEmpty,
              [input.alt, input.address, input.title].allSatisfy({ $0.rangeOfCharacter(from: .newlines) == nil && $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              let context = context(in: text, selection: selection) else { return nil }
        let punctuation = CharacterSet(charactersIn: "\\`*_{}[]<>!#()~|&")
        let alt = input.alt.unicodeScalars.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
        let address = input.address.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<").replacingOccurrences(of: ">", with: "\\>")
        let title = input.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let replacement = "![\(alt)](<\(address)>\(title.isEmpty ? "" : " \"\(title)\""))"
        let candidate = text.replacingCharacters(in: context.range, with: replacement)
        let range = NSRange(location: context.range.location, length: (replacement as NSString).length)
        guard let result = nodes(in: candidate), result.contains(where: {
            $0.kind == "image" && $0.range == range && $0.address == input.address && $0.title == input.title && $0.alt == input.alt
        }) else { return nil }
        return MarkdownFormattingEdit(range: context.range, replacement: replacement,
            selectionRange: NSRange(location: context.range.location + 2, length: (alt as NSString).length))
    }

    private static func context(in text: NSString, selection: NSRange) -> (range: NSRange, image: Node?)? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location,
              boundary(text, selection.location), boundary(text, NSMaxRange(selection)),
              let nodes = nodes(in: text as String) else { return nil }
        func intersects(_ range: NSRange) -> Bool {
            selection.length == 0 ? selection.location >= range.location && selection.location < NSMaxRange(range)
                : NSIntersectionRange(selection, range).length > 0
        }
        guard !nodes.contains(where: { ["code", "code_block", "link", "unresolved"].contains($0.kind) && intersects($0.range) }) else { return nil }
        if let image = nodes.first(where: { $0.kind == "image" && intersects($0.range) }) {
            guard !image.complexAlt, selection.length == 0 || selection == image.range else { return nil }
            let raw = text.substring(with: image.range) as NSString
            guard isInlineImage(raw) else { return nil }
            return (image.range, image)
        }
        guard text.substring(with: selection).rangeOfCharacter(from: .newlines) == nil else { return nil }
        return (selection, nil)
    }

    private static func isInlineImage(_ source: NSString) -> Bool {
        guard source.length >= 4, source.character(at: 0) == 33, source.character(at: 1) == 91 else { return false }
        var depth = 1, index = 2
        while index < source.length {
            let unit = source.character(at: index)
            if unit == 92 && index + 1 < source.length { index += 2; continue }
            if unit == 91 { depth += 1 }
            if unit == 93 {
                depth -= 1
                if depth == 0 { return index + 1 < source.length && source.character(at: index + 1) == 40 }
            }
            index += 1
        }
        return false
    }

    private static func boundary(_ text: NSString, _ index: Int) -> Bool {
        index == 0 || index == text.length || text.rangeOfComposedCharacterSequence(at: index).location == index
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
        var lines: [(Int, String)] = [], start = 0, offset = 0
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
            guard !item.1.contains("\t"), column <= item.1.utf8.count,
                  let byte = item.1.utf8.index(item.1.utf8.startIndex, offsetBy: column, limitedBy: item.1.utf8.endIndex),
                  let index = String.Index(byte, within: item.1) else { return nil }
            return item.0 + item.1[..<index].utf16.count
        }
        var result: [Node] = []
        func visit(_ node: OpaquePointer) {
            if let name = cmark_node_get_type_string(node) {
                let kind = String(cString: name)
                if ["image", "link", "code", "code_block"].contains(kind) {
                    let first = Int(cmark_node_get_start_line(node)), last = Int(cmark_node_get_end_line(node))
                    guard let start = position(first, Int(cmark_node_get_start_column(node)) - 1),
                          cmark_node_get_end_column(node) > 0, let end = position(last, Int(cmark_node_get_end_column(node))), end >= start else {
                        let lo = max(0, min(first - 1, lines.count - 1)), hi = max(lo, min(last - 1, lines.count - 1))
                        let end = lines[hi].0 + (lines[hi].1 as NSString).length
                        result.append(Node(kind: "unresolved", range: NSRange(location: lines[lo].0, length: end - lines[lo].0), address: "", alt: "", title: ""))
                        return
                    }
                    var left = start, right = end
                    if kind == "code" {
                        while left > 0 && ns.character(at: left - 1) == 96 { left -= 1 }
                        while right < ns.length && ns.character(at: right) == 96 { right += 1 }
                        if start - left == 0 || start - left != right - end {
                            result.append(Node(kind: "unresolved", range: NSRange(location: lines[first - 1].0, length: (lines[first - 1].1 as NSString).length), address: "", alt: "", title: "")); return
                        }
                    }
                    var alt = ""
                    func append(_ current: OpaquePointer) {
                        if let nodeType = cmark_node_get_type_string(current), String(cString: nodeType) == "text",
                           let value = cmark_node_get_literal(current) { alt += String(cString: value) }
                        var child = cmark_node_first_child(current)
                        while let next = child { append(next); child = cmark_node_next(next) }
                    }
                    if kind == "image" { append(node) }
                    var value = Node(kind: kind, range: NSRange(location: left, length: right - left),
                        address: cmark_node_get_url(node).map { String(cString: $0) } ?? "", alt: alt,
                        title: cmark_node_get_title(node).map { String(cString: $0) } ?? "")
                    if kind == "image" {
                        var child = cmark_node_first_child(node)
                        while let next = child {
                            if let childName = cmark_node_get_type_string(next), String(cString: childName) != "text" { value.complexAlt = true }
                            child = cmark_node_next(next)
                        }
                    }
                    result.append(value)
                }
            }
            var child = cmark_node_first_child(node)
            while let next = child { visit(next); child = cmark_node_next(next) }
        }
        visit(root)
        return result
    }
}
