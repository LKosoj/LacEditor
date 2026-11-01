import Foundation

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
import SwiftTreeSitter
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterPython
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterSwift
import TreeSitterBash
import TreeSitterYAML
import TreeSitterC
import TreeSitterCPP
import TreeSitterSQL
#endif

/// Символ файла для раздела «Символы» боковой панели. Диапазон — UTF-16 в файловом тексте.
struct OutlineSymbol: Equatable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case function, method, initializer, classType, structure, enumeration, interface, typeAlias,
             extensionType, namespace, property, selector, atRule, heading, element, key, table, view, index

        var title: String {
            switch self {
            case .function: L10n.tr("函数")
            case .method: L10n.tr("方法")
            case .initializer: L10n.tr("初始化器")
            case .classType: L10n.tr("类")
            case .structure: L10n.tr("结构体")
            case .enumeration: L10n.tr("枚举")
            case .interface: L10n.tr("接口或协议")
            case .typeAlias: L10n.tr("类型别名")
            case .extensionType: L10n.tr("扩展")
            case .namespace: L10n.tr("命名空间")
            case .property: L10n.tr("属性")
            case .selector: L10n.tr("CSS 选择器")
            case .atRule: L10n.tr("CSS @ 规则")
            case .heading: L10n.tr("HTML 标题")
            case .element: L10n.tr("HTML 元素")
            case .key: L10n.tr("键名")
            case .table: L10n.tr("数据表")
            case .view: L10n.tr("视图")
            case .index: L10n.tr("索引")
            }
        }
    }

    let id: Int
    let name: String
    let kind: Kind
    let level: Int
    let range: NSRange
}

/// Список символов файла по языкам: Tree-sitter для кода, собственный проход для JSON.
enum SymbolOutlineService {
    static let maximumUTF8Bytes = 20 * 1_024 * 1_024
    static let maximumDepth = 256
    static let maximumNameLength = 120

    static func supports(_ language: EditorLanguage) -> Bool {
        switch language {
        case .javascript, .typescript, .python, .swift, .cFamily, .shell, .css, .html, .yaml, .sql, .json: true
        case .markdown, .plainText: false
        }
    }

    /// nil — отменено или разбор недоступен. Пустой массив — символов нет.
    static func symbols(in text: String, language: EditorLanguage, isCancelled: @escaping () -> Bool) -> [OutlineSymbol]? {
        guard supports(language), !isCancelled() else { return nil }
        let drafts: [Draft]?
        if language == .json {
            drafts = jsonKeys(in: text, isCancelled: isCancelled)
        } else {
#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
            drafts = treeSymbols(in: text, language: language, isCancelled: isCancelled)
#else
            drafts = nil
#endif
        }
        guard let drafts, !isCancelled() else { return nil }
        return drafts.enumerated().map {
            OutlineSymbol(id: $0.offset, name: $0.element.name, kind: $0.element.kind, level: $0.element.level, range: $0.element.range)
        }
    }

    /// Последний символ, чей диапазон содержит позицию; внутренние идут позже внешних.
    static func currentIndex(in symbols: [OutlineSymbol], caret: Int) -> Int? {
        var low = 0
        var high = symbols.count
        while low < high {
            let middle = (low + high) / 2
            if symbols[middle].range.location <= caret { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        while index >= 0 {
            let range = symbols[index].range
            if NSLocationInRange(caret, range) || caret == NSMaxRange(range) { return index }
            index -= 1
        }
        return nil
    }

    /// Фильтр по подстроке без учёта регистра и диакритики; пустой запрос возвращает всё.
    static func filtered(_ symbols: [OutlineSymbol], query: String) -> [OutlineSymbol] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return symbols }
        return symbols.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: - Общее

    struct Draft {
        var name: String
        var kind: OutlineSymbol.Kind
        var level: Int
        var range: NSRange
    }

    /// Пробелы и переводы строк сжимаются в один пробел, длина ограничена.
    static func normalizedName(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(maximumNameLength))
    }

    static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(max(NSMaxRange(range), start), length)
        return NSRange(location: start, length: end - start)
    }

    // MARK: - JSON

    /// Ключи двух верхних уровней объектов; массивы не заходят. Без разбора синтаксиса, один проход по UTF-16.
    static func jsonKeys(in text: String, isCancelled: () -> Bool) -> [Draft]? {
        struct Container { var isObject: Bool; var pending: Int? }
        let units = Array(text.utf16)
        var stack: [Container] = []
        var drafts: [Draft] = []
        var arrayCount = 0

        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09 }
        func closePending(_ index: Int?, before position: Int) {
            guard let index else { return }
            var end = position
            while end > drafts[index].range.location, isSpace(units[end - 1]) { end -= 1 }
            drafts[index].range.length = end - drafts[index].range.location
        }


        // Не закрытые до конца текста ключи тянутся до конца, лишние пробелы справа отрезаются.
        func recordedDrafts() -> [Draft] {
            for container in stack { closePending(container.pending, before: units.count) }
            return drafts
        }
        var position = 0
        while position < units.count {
            if position & 0xFFF == 0, isCancelled() { return nil }
            let unit = units[position]
            switch unit {
            case 0x7B: // {
                stack.append(Container(isObject: true, pending: nil))
                position += 1
            case 0x5B: // [
                stack.append(Container(isObject: false, pending: nil))
                arrayCount += 1
                position += 1
            case 0x7D, 0x5D: // } ]
                if let top = stack.popLast() {
                    closePending(top.pending, before: position)
                    if !top.isObject { arrayCount -= 1 }
                }
                position += 1
            case 0x2C: // ,
                if let top = stack.last, top.isObject {
                    closePending(top.pending, before: position)
                    stack[stack.count - 1].pending = nil
                }
                position += 1
            case 0x22: // "
                let start = position
                position += 1
                while position < units.count, units[position] != 0x22 {
                    position += units[position] == 0x5C ? 2 : 1
                }
                guard position < units.count else { return recordedDrafts() }
                let contentRange = NSRange(location: start + 1, length: position - start - 1)
                position += 1
                var next = position
                while next < units.count, isSpace(units[next]) { next += 1 }
                if next < units.count, units[next] == 0x3A, let top = stack.last, top.isObject,
                   arrayCount == 0, stack.count <= 2 {
                    let name = normalizedName(String(decoding: units[contentRange.location..<NSMaxRange(contentRange)], as: UTF16.self))
                    if !name.isEmpty {
                        drafts.append(Draft(name: name, kind: .key, level: stack.count - 1,
                                            range: NSRange(location: start, length: units.count - start)))
                        stack[stack.count - 1].pending = drafts.count - 1
                    }
                }
            default:
                position += 1
            }
        }
        return recordedDrafts()
    }
}

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
extension SymbolOutlineService {
    private static func grammar(for language: EditorLanguage) -> Language? {
        switch language {
        case .javascript: Language(language: tree_sitter_javascript())
        case .typescript: Language(language: tree_sitter_typescript())
        case .python: Language(language: tree_sitter_python())
        case .swift: Language(language: tree_sitter_swift())
        case .cFamily: Language(language: tree_sitter_cpp())
        case .shell: Language(language: tree_sitter_bash())
        case .css: Language(language: tree_sitter_css())
        case .html: Language(language: tree_sitter_html())
        case .yaml: Language(language: tree_sitter_yaml())
        case .sql: Language(language: tree_sitter_sql())
        case .json, .markdown, .plainText: nil
        }
    }

    fileprivate static func treeSymbols(in text: String, language: EditorLanguage, isCancelled: @escaping () -> Bool) -> [Draft]? {
        guard text.utf8.count <= maximumUTF8Bytes, let grammar = grammar(for: language) else { return nil }
        let parser = Parser()
        do { try parser.setLanguage(grammar) } catch { return nil }
        guard !isCancelled(), let tree = parser.parse(text), !isCancelled(), let root = tree.rootNode else { return nil }
        let walker = OutlineWalker(text: text, language: language, isCancelled: isCancelled)
        if language == .yaml {
            walker.visitYAML(root, level: 0, depth: 0)
        } else {
            walker.visit(root, level: 0, container: nil, depth: 0)
        }
        return walker.isStopped ? nil : walker.drafts
    }
}

/// Обход дерева Tree-sitter по таблице «язык, тип узла, вид, имя». Живёт один разбор, в одном потоке.
private final class OutlineWalker {
    /// Символ, найденный в узле. `content` — узел, чьи дочерние обходятся на уровень глубже (nil — внутрь не заходим).
    private struct Match {
        var kind: OutlineSymbol.Kind
        var name: String
        var range: NSRange
        var content: Node?
    }

    let source: NSString
    let language: EditorLanguage
    let isCancelled: () -> Bool
    private(set) var drafts: [SymbolOutlineService.Draft] = []
    private(set) var isStopped = false
    private var visited = 0

    init(text: String, language: EditorLanguage, isCancelled: @escaping () -> Bool) {
        self.source = text as NSString
        self.language = language
        self.isCancelled = isCancelled
    }

    // MARK: Обход

    func visit(_ node: Node, level: Int, container: OutlineSymbol.Kind?, depth: Int) {
        guard proceed(depth: depth) else { return }
        if let match = classify(node, container: container) {
            if !match.name.isEmpty {
                drafts.append(.init(name: match.name, kind: match.kind, level: level, range: match.range))
                if let content = match.content {
                    visitChildren(of: content, level: level + 1, container: match.kind, depth: depth + 1)
                }
                return
            }
            // Без имени символа нет; тела классов и пространств имён всё равно просматриваем.
            if let content = match.content {
                visitChildren(of: content, level: level, container: container, depth: depth + 1)
            }
            return
        }
        visitChildren(of: node, level: level, container: container, depth: depth + 1)
    }

    /// YAML: ключи верхнего уровня и вложенные на один уровень; последовательности и глубже не смотрим.
    func visitYAML(_ node: Node, level: Int, depth: Int) {
        guard proceed(depth: depth) else { return }
        switch node.nodeType {
        case "block_mapping":
            for index in 0..<node.childCount {
                guard let pair = node.child(at: index), pair.nodeType == "block_mapping_pair" else { continue }
                let name = text(of: pair.child(byFieldName: "key"))
                if !name.isEmpty {
                    drafts.append(.init(name: name, kind: .key, level: level, range: clamp(pair.range)))
                }
                if level == 0, let value = pair.child(byFieldName: "value") {
                    visitYAML(value, level: 1, depth: depth + 1)
                }
            }
        case "stream", "document", "block_node":
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visitYAML(child, level: level, depth: depth + 1)
            }
        default:
            break
        }
    }

    private func visitChildren(of node: Node, level: Int, container: OutlineSymbol.Kind?, depth: Int) {
        for index in 0..<node.childCount {
            if isStopped { return }
            guard let child = node.child(at: index) else { continue }
            visit(child, level: level, container: container, depth: depth)
        }
    }

    /// Отмена проверяется каждые 1024 узла; глубже `maximumDepth` поддерево пропускается.
    private func proceed(depth: Int) -> Bool {
        if isStopped { return false }
        visited += 1
        if visited & 0x3FF == 0, isCancelled() {
            isStopped = true
            return false
        }
        return depth <= SymbolOutlineService.maximumDepth
    }

    // MARK: Текст

    private func clamp(_ range: NSRange) -> NSRange {
        SymbolOutlineService.clamped(range, length: source.length)
    }

    private func rawText(_ range: NSRange) -> String {
        source.substring(with: clamp(range))
    }

    private func text(of node: Node?) -> String {
        guard let node else { return "" }
        return SymbolOutlineService.normalizedName(rawText(node.range))
    }

    private func firstChild(of node: Node, type: String) -> Node? {
        for index in 0..<node.childCount {
            if let child = node.child(at: index), child.nodeType == type { return child }
        }
        return nil
    }

    private func isTypeContainer(_ kind: OutlineSymbol.Kind?) -> Bool {
        switch kind {
        case .classType, .structure, .enumeration, .extensionType: true
        default: false
        }
    }

    // MARK: Таблица типов узлов

    private func classify(_ node: Node, container: OutlineSymbol.Kind?) -> Match? {
        guard let type = node.nodeType else { return nil }
        switch language {
        case .javascript, .typescript: return classifyScript(node, type: type)
        case .python: return classifyPython(node, type: type, container: container)
        case .swift: return classifySwift(node, type: type, container: container)
        case .cFamily: return classifyC(node, type: type, container: container)
        case .shell:
            guard type == "function_definition" else { return nil }
            return Match(kind: .function, name: text(of: node.child(byFieldName: "name")), range: clamp(node.range), content: nil)
        case .css: return classifyCSS(node, type: type)
        case .html: return classifyHTML(node, type: type)
        case .sql: return classifySQL(node, type: type)
        case .yaml, .json, .markdown, .plainText: return nil
        }
    }

    private func named(_ kind: OutlineSymbol.Kind, _ node: Node, enters: Bool = false) -> Match {
        Match(kind: kind, name: text(of: node.child(byFieldName: "name")), range: clamp(node.range), content: enters ? node : nil)
    }

    private func classifyScript(_ node: Node, type: String) -> Match? {
        switch type {
        case "function_declaration", "generator_function_declaration": return named(.function, node)
        case "class_declaration", "abstract_class_declaration": return named(.classType, node, enters: true)
        case "method_definition":
            guard node.parent?.nodeType == "class_body" else { return nil }
            return named(.method, node)
        case "variable_declarator":
            guard let value = node.child(byFieldName: "value"),
                  let valueType = value.nodeType,
                  ["arrow_function", "function_expression", "generator_function", "function"].contains(valueType),
                  let name = node.child(byFieldName: "name"), name.nodeType == "identifier" else { return nil }
            return Match(kind: .function, name: text(of: name), range: clamp(node.range), content: nil)
        case "interface_declaration": return named(.interface, node)
        case "type_alias_declaration": return named(.typeAlias, node)
        case "enum_declaration": return named(.enumeration, node)
        case "internal_module", "module": return named(.namespace, node, enters: true)
        default: return nil
        }
    }

    private func classifyPython(_ node: Node, type: String, container: OutlineSymbol.Kind?) -> Match? {
        switch type {
        case "function_definition":
            return named(container == .classType ? .method : .function, node)
        case "class_definition":
            return named(.classType, node, enters: true)
        case "decorated_definition":
            // Вместе с декораторами; вложенное определение отдельно не обходится
            guard let definition = node.child(byFieldName: "definition"),
                  var match = classifyPython(definition, type: definition.nodeType ?? "", container: container) else { return nil }
            match.range = clamp(node.range)
            return match
        default: return nil
        }
    }

    private func classifySwift(_ node: Node, type: String, container: OutlineSymbol.Kind?) -> Match? {
        switch type {
        case "class_declaration":
            let kind: OutlineSymbol.Kind
            switch node.child(byFieldName: "declaration_kind")?.nodeType {
            case "class", "actor": kind = .classType
            case "struct": kind = .structure
            case "enum": kind = .enumeration
            case "extension": kind = .extensionType
            default: return nil
            }
            return named(kind, node, enters: true)
        case "protocol_declaration": return named(.interface, node)
        case "typealias_declaration": return named(.typeAlias, node)
        case "function_declaration":
            return named(isTypeContainer(container) ? .method : .function, node)
        case "init_declaration":
            let name = text(of: node.child(byFieldName: "name"))
            return Match(kind: .initializer, name: name.isEmpty ? "init" : name, range: clamp(node.range), content: nil)
        case "property_declaration":
            guard let pattern = node.child(byFieldName: "name") else { return nil }
            let name = text(of: pattern.child(byFieldName: "bound_identifier") ?? pattern)
            return Match(kind: .property, name: name, range: clamp(node.range), content: nil)
        default: return nil
        }
    }

    private func classifyC(_ node: Node, type: String, container: OutlineSymbol.Kind?) -> Match? {
        switch type {
        case "function_definition":
            let kind: OutlineSymbol.Kind = container == .classType || container == .structure ? .method : .function
            return Match(kind: kind, name: text(of: declaratorName(node)), range: clamp(node.range), content: nil)
        case "struct_specifier", "union_specifier", "class_specifier":
            // Без тела это упоминание типа или предварительное объявление
            guard let body = node.child(byFieldName: "body") else { return nil }
            return Match(kind: type == "class_specifier" ? .classType : .structure,
                         name: text(of: node.child(byFieldName: "name")), range: clamp(node.range), content: body)
        case "enum_specifier":
            guard node.child(byFieldName: "body") != nil else { return nil }
            return named(.enumeration, node)
        case "type_definition":
            // typedef struct {…} Name;
            guard let specifier = node.child(byFieldName: "type"), let specifierType = specifier.nodeType,
                  ["struct_specifier", "union_specifier", "enum_specifier"].contains(specifierType),
                  specifier.child(byFieldName: "body") != nil,
                  specifier.child(byFieldName: "name") == nil else { return nil }
            return Match(kind: specifierType == "enum_specifier" ? .enumeration : .structure,
                         name: text(of: node.child(byFieldName: "declarator")), range: clamp(node.range), content: nil)
        case "namespace_definition":
            return Match(kind: .namespace, name: text(of: node.child(byFieldName: "name")),
                         range: clamp(node.range), content: node.child(byFieldName: "body") ?? node)
        default: return nil
        }
    }

    /// Имя функции C/C++: вниз по `declarator` через обёртки до первого другого узла.
    private func declaratorName(_ function: Node) -> Node? {
        let wrappers: Set<String> = ["pointer_declarator", "reference_declarator", "parenthesized_declarator",
                                     "function_declarator", "array_declarator", "attributed_declarator"]
        var current = function.child(byFieldName: "declarator")
        while let node = current, let type = node.nodeType, wrappers.contains(type) {
            // у reference/parenthesized/attributed поля нет: берём последний именованный дочерний
            current = node.child(byFieldName: "declarator")
                ?? (node.namedChildCount > 0 ? node.namedChild(at: node.namedChildCount - 1) : nil)
        }
        return current
    }

    private func classifyCSS(_ node: Node, type: String) -> Match? {
        switch type {
        case "rule_set":
            guard let selectors = firstChild(of: node, type: "selectors") else { return nil }
            return Match(kind: .selector, name: text(of: selectors), range: clamp(node.range), content: nil)
        case "media_statement":
            let block = firstChild(of: node, type: "block")
            let end = block?.range.location ?? NSMaxRange(node.range)
            let header = NSRange(location: node.range.location, length: max(0, end - node.range.location))
            return Match(kind: .atRule, name: SymbolOutlineService.normalizedName(rawText(header)),
                         range: clamp(node.range), content: block)
        case "keyframes_statement":
            guard let name = firstChild(of: node, type: "keyframes_name") else { return nil }
            return Match(kind: .atRule, name: "@keyframes " + text(of: name), range: clamp(node.range), content: nil)
        default: return nil
        }
    }

    private func classifyHTML(_ node: Node, type: String) -> Match? {
        guard type == "element", let start = firstChild(of: node, type: "start_tag"),
              let tagNode = firstChild(of: start, type: "tag_name") else { return nil }
        let tag = rawText(tagNode.range).lowercased()
        if tag.count == 2, tag.first == "h", let digit = tag.last, ("1"..."6").contains(digit) {
            // Видимый текст: между открывающим и закрывающим тегом, без вложенных тегов
            let from = NSMaxRange(start.range)
            let to = firstChild(of: node, type: "end_tag")?.range.location ?? NSMaxRange(node.range)
            let inner = rawText(NSRange(location: from, length: max(0, to - from)))
            let visible = SymbolOutlineService.normalizedName(strippingTags(inner))
            return Match(kind: .heading, name: visible.isEmpty ? "" : tag + " " + visible, range: clamp(node.range), content: nil)
        }
        guard let id = idValue(of: start), !id.isEmpty else { return nil }
        return Match(kind: .element, name: SymbolOutlineService.normalizedName(tag + "#" + id), range: clamp(node.range), content: node)
    }

    private func strippingTags(_ html: String) -> String {
        var result = ""
        var insideTag = false
        for character in html {
            if character == "<" { insideTag = true } else if character == ">" && insideTag { insideTag = false } else if !insideTag {
                result.append(character)
            }
        }
        return result
    }

    private func idValue(of startTag: Node) -> String? {
        for index in 0..<startTag.childCount {
            guard let attribute = startTag.child(at: index), attribute.nodeType == "attribute",
                  let nameNode = firstChild(of: attribute, type: "attribute_name"),
                  rawText(nameNode.range).lowercased() == "id" else { continue }
            if let quoted = firstChild(of: attribute, type: "quoted_attribute_value") {
                return text(of: firstChild(of: quoted, type: "attribute_value"))
            }
            return text(of: firstChild(of: attribute, type: "attribute_value"))
        }
        return nil
    }

    private func classifySQL(_ node: Node, type: String) -> Match? {
        let kind: OutlineSymbol.Kind
        switch type {
        case "create_table": kind = .table
        case "create_view", "create_materialized_view": kind = .view
        case "create_function": kind = .function
        case "create_index": kind = .index
        default: return nil
        }
        let nameNode: Node?
        if type == "create_index" {
            nameNode = node.child(byFieldName: "name")
                ?? firstChild(of: node, type: "identifier") ?? firstChild(of: node, type: "object_reference")
        } else {
            nameNode = firstChild(of: node, type: "object_reference")
        }
        return Match(kind: kind, name: text(of: nameNode), range: clamp(node.range), content: nil)
    }
}
#endif
