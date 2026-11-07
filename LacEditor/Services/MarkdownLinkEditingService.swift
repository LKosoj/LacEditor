import Foundation

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
        guard let model = MarkdownEditingNode.model(of: text) else { return nil }
        let ns = text as NSString
        return model.editingNodes(in: ns).map { item in
            guard !item.isUnreliable else {
                return Node(kind: "unresolved", range: item.unresolvedLines(in: ns), address: "", title: "")
            }
            return Node(kind: item.kind, range: item.range, address: item.address, title: item.title)
        }
    }
}

/// Узел модели, который нужен сервисам ссылок и картинок: ссылка, картинка, код в строке или блок кода.
/// `gap` — промежуток вокруг неподтверждённого узла (между подтверждёнными соседями или краями блока); его строки сервис помечает «unresolved».
struct MarkdownEditingNode {
    enum Content {
        case inline(MarkdownInlineNode)
        case codeBlock
    }

    /// Только то, что влияет на блоки и строчные узлы в редакторе (без индексов, эмодзи и данных TextKit).
    static let includes: MarkdownDocumentModel.Includes = [.noteEmbeds, .criticMarkup]

    /// Модель для сервисов правки; `nil` — в тексте NUL или разбор не удался. Типографские замены (`'` в `’`) выключены:
    /// сервисам нужен буквальный текст исходника.
    static func model(of text: String) -> MarkdownDocumentModel? {
        guard !text.utf8.contains(0) else { return nil }
        return MarkdownPresentationBuilder.model(of: text, syntax: MarkdownSyntaxOptions(smartPunctuation: false), includes: includes)
    }

    let content: Content
    let range: NSRange
    let gap: NSRange
    let isUnreliable: Bool

    var kind: String {
        switch content {
        case .codeBlock: "code_block"
        case let .inline(node):
            switch node.kind {
            case .link: "link"
            case .image: "image"
            default: "code"
            }
        }
    }

    var address: String {
        guard case let .inline(node) = content else { return "" }
        switch node.kind {
        case let .link(link): return link.url
        case let .image(image): return image.url
        default: return ""
        }
    }

    var title: String {
        guard case let .inline(node) = content else { return "" }
        switch node.kind {
        case let .link(link): return link.title ?? ""
        case let .image(image): return image.title ?? ""
        default: return ""
        }
    }

    /// Строки промежутка целиком (с переводом строки в конце); не подошло — весь текст.
    func unresolvedLines(in text: NSString) -> NSRange {
        guard gap.location != NSNotFound, gap.location >= 0, gap.length >= 0,
              gap.location <= text.length, gap.length <= text.length - gap.location else {
            return NSRange(location: 0, length: text.length)
        }
        return text.lineRange(for: gap)
    }
}

extension MarkdownDocumentModel {
    /// Ссылки, картинки, код в строке и блоки кода документа в порядке обхода (родитель раньше вложенных).
    /// HTML-формы (`<a>`, `<img>`) не берутся: cmark видит в них только сырой HTML.
    /// Неподтверждённым считается сам узел (или блок кода); соседи с подтверждённой позицией остаются доступными.
    func editingNodes(in text: NSString) -> [MarkdownEditingNode] {
        var result: [MarkdownEditingNode] = []
        // Абзац с неподтверждёнными позициями помечается целиком, а узлы в нём модель считает подтверждёнными. Узел недоступен,
        // если его строки с табуляцией (как прежде: позиция cmark в такой строке не разбиралась); остальные строки правятся.
        func inUnconfirmedLines(_ range: NSRange) -> Bool {
            guard range.location >= 0, NSMaxRange(range) <= text.length,
                  unreliableRanges.contains(where: { NSIntersectionRange($0, range).length > 0 || NSLocationInRange(range.location, $0) }) else { return false }
            return text.substring(with: text.lineRange(for: range)).contains("\t")
        }
        func visit(_ inlines: [MarkdownInlineNode], owner: NSRange) {
            for (index, node) in inlines.enumerated() {
                var accepted = false
                switch node.kind {
                case let .link(link): accepted = link.form != .html
                case let .image(image): accepted = image.syntax != .html
                case .code: accepted = true
                default: break
                }
                if accepted {
                    var gap = node.range
                    if node.isUnreliable {
                        let before = inlines[..<index].last(where: { !$0.isUnreliable && $0.range.length > 0 })
                        let after = inlines[(index + 1)...].first(where: { !$0.isUnreliable && $0.range.length > 0 })
                        let lower = before.map { NSMaxRange($0.range) } ?? owner.location
                        let upper = after.map { $0.range.location } ?? NSMaxRange(owner)
                        gap = NSRange(location: lower, length: max(0, upper - lower))
                    }
                    result.append(MarkdownEditingNode(content: .inline(node), range: node.range, gap: gap,
                                                      isUnreliable: node.isUnreliable || inUnconfirmedLines(node.range)))
                }
                visit(node.children, owner: owner)
            }
        }
        func visit(_ blocks: [MarkdownBlockNode]) {
            for block in blocks {
                if case .codeBlock = block.kind {
                    result.append(MarkdownEditingNode(content: .codeBlock, range: block.range, gap: block.range, isUnreliable: block.isUnreliable || inUnconfirmedLines(block.range)))
                }
                visit(block.inlines, owner: block.range)
                if case let .table(table) = block.kind {
                    for row in table.rows { for cell in row.cells { visit(cell.inlines, owner: row.range) } }
                }
                visit(block.children)
            }
        }
        visit(blocks)
        return result
    }
}
