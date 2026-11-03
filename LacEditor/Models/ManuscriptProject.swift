import Foundation

/// Минимальное JSON-значение для хранения неизвестных ключей без потерь.
/// Числа хранятся как `Double`: целые больше 2^53 теряют точность (для служебных полей допустимо).
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// Ключ кодирования с произвольным именем: нужен, чтобы читать известные поля и собирать остальные.
private struct ManuscriptAnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Статус сцены: название и цвет точки. В манифесте читается строкой или объектом, пишется объектом.
struct ManuscriptStatus: Codable, Equatable, Sendable {
    var title: String
    var color: StatusColor
    /// Неизвестные ключи объекта статуса: пишутся обратно без потерь.
    var extra: [String: JSONValue] = [:]

    /// Цвета для статусов, записанных строкой: по индексу из этой палитры.
    static let fallbackPalette: [StatusColor] = [.gray, .orange, .green, .blue, .purple, .teal]

    init(title: String, color: StatusColor, extra: [String: JSONValue] = [:]) {
        self.title = title
        self.color = color
        self.extra = extra
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: ManuscriptAnyKey.self) {
            title = (try? object.decode(String.self, forKey: ManuscriptAnyKey("title"))) ?? ""
            let raw = try? object.decode(String.self, forKey: ManuscriptAnyKey("color"))
            color = raw.flatMap { StatusColor(rawValue: $0) } ?? .gray
            var rest: [String: JSONValue] = [:]
            for key in object.allKeys where key.stringValue != "title" && key.stringValue != "color" {
                rest[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
            }
            extra = rest
        } else {
            title = try decoder.singleValueContainer().decode(String.self)
            color = .gray
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManuscriptAnyKey.self)
        for (key, value) in extra where key != "title" && key != "color" {
            try container.encode(value, forKey: ManuscriptAnyKey(key))
        }
        try container.encode(title, forKey: ManuscriptAnyKey("title"))
        try container.encode(color.rawValue, forKey: ManuscriptAnyKey("color"))
    }
}

struct ManuscriptNode: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case group, text }

    var id: UUID
    var kind: Kind
    var title: String
    var path: String?
    var include: Bool
    var status: String?
    var synopsis: String?
    var label: String?
    var tags: [String]
    var children: [ManuscriptNode]
    /// Неизвестные ключи узла: возвращаются в файл при записи.
    var extra: [String: JSONValue]

    init(id: UUID = UUID(), kind: Kind, title: String, path: String? = nil, include: Bool = true,
         status: String? = nil, synopsis: String? = nil, label: String? = nil, tags: [String] = [],
         children: [ManuscriptNode] = [], extra: [String: JSONValue] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = kind == .group ? nil : path
        self.include = include
        self.status = status
        self.synopsis = synopsis
        self.label = label
        self.tags = tags
        self.children = children
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["id", "kind", "title", "path", "include", "status", "synopsis", "label", "tags", "children"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ManuscriptAnyKey.self)
        id = try container.decode(UUID.self, forKey: ManuscriptAnyKey("id"))
        let rawKind = try container.decode(String.self, forKey: ManuscriptAnyKey("kind"))
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(forKey: ManuscriptAnyKey("kind"), in: container, debugDescription: "Unknown node kind")
        }
        self.kind = kind
        title = try container.decodeIfPresent(String.self, forKey: ManuscriptAnyKey("title")) ?? ""
        let rawPath = try container.decodeIfPresent(String.self, forKey: ManuscriptAnyKey("path"))
        path = kind == .group ? nil : rawPath
        include = try container.decodeIfPresent(Bool.self, forKey: ManuscriptAnyKey("include")) ?? true
        status = try container.decodeIfPresent(String.self, forKey: ManuscriptAnyKey("status"))
        synopsis = try container.decodeIfPresent(String.self, forKey: ManuscriptAnyKey("synopsis"))
        label = try container.decodeIfPresent(String.self, forKey: ManuscriptAnyKey("label"))
        tags = try container.decodeIfPresent([String].self, forKey: ManuscriptAnyKey("tags")) ?? []
        children = try container.decodeIfPresent([ManuscriptNode].self, forKey: ManuscriptAnyKey("children")) ?? []
        var rest: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            rest[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        extra = rest
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManuscriptAnyKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: ManuscriptAnyKey(key))
        }
        try container.encode(id, forKey: ManuscriptAnyKey("id"))
        try container.encode(kind, forKey: ManuscriptAnyKey("kind"))
        try container.encode(title, forKey: ManuscriptAnyKey("title"))
        if kind == .text { try container.encodeIfPresent(path, forKey: ManuscriptAnyKey("path")) }
        try container.encode(include, forKey: ManuscriptAnyKey("include"))
        try container.encodeIfPresent(status, forKey: ManuscriptAnyKey("status"))
        try container.encodeIfPresent(synopsis, forKey: ManuscriptAnyKey("synopsis"))
        try container.encodeIfPresent(label, forKey: ManuscriptAnyKey("label"))
        if !tags.isEmpty { try container.encode(tags, forKey: ManuscriptAnyKey("tags")) }
        if kind == .group || !children.isEmpty { try container.encode(children, forKey: ManuscriptAnyKey("children")) }
    }
}

struct ManuscriptProject: Codable, Equatable, Sendable {
    var version: Int
    var projectID: UUID
    var title: String
    var language: String?
    var statuses: [ManuscriptStatus]
    var nodes: [ManuscriptNode]
    /// Неизвестные ключи корня: возвращаются в файл при записи.
    var extra: [String: JSONValue]

    init(version: Int = 1, projectID: UUID = UUID(), title: String, language: String? = nil,
         statuses: [ManuscriptStatus] = ManuscriptProject.defaultStatuses(), nodes: [ManuscriptNode] = [],
         extra: [String: JSONValue] = [:]) {
        self.version = version
        self.projectID = projectID
        self.title = title
        self.language = language
        self.statuses = statuses
        self.nodes = nodes
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["version", "projectID", "title", "language", "statuses", "nodes"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ManuscriptAnyKey.self)
        version = try container.decode(Int.self, forKey: ManuscriptAnyKey("version"))
        projectID = try container.decode(UUID.self, forKey: ManuscriptAnyKey("projectID"))
        title = try container.decodeIfPresent(String.self, forKey: ManuscriptAnyKey("title")) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: ManuscriptAnyKey("language"))
        statuses = try Self.decodeStatuses(container)
        nodes = try container.decodeIfPresent([ManuscriptNode].self, forKey: ManuscriptAnyKey("nodes")) ?? []
        var rest: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.knownKeys.contains(key.stringValue) {
            rest[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        extra = rest
    }

    /// Статус-строка получает цвет по индексу из палитры по умолчанию, статус-объект — свой.
    private static func decodeStatuses(_ container: KeyedDecodingContainer<ManuscriptAnyKey>) throws -> [ManuscriptStatus] {
        let key = ManuscriptAnyKey("statuses")
        guard container.contains(key) else { return [] }
        var statuses = try container.decode([ManuscriptStatus].self, forKey: key)
        let raw = try container.decode([JSONValue].self, forKey: key)
        for index in statuses.indices where index < raw.count {
            if case .string = raw[index] {
                statuses[index].color = ManuscriptStatus.fallbackPalette[index % ManuscriptStatus.fallbackPalette.count]
            }
        }
        return statuses
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ManuscriptAnyKey.self)
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: ManuscriptAnyKey(key))
        }
        try container.encode(version, forKey: ManuscriptAnyKey("version"))
        try container.encode(projectID, forKey: ManuscriptAnyKey("projectID"))
        try container.encode(title, forKey: ManuscriptAnyKey("title"))
        try container.encodeIfPresent(language, forKey: ManuscriptAnyKey("language"))
        try container.encode(statuses, forKey: ManuscriptAnyKey("statuses"))
        try container.encode(nodes, forKey: ManuscriptAnyKey("nodes"))
    }

    /// Статусы по умолчанию на языке интерфейса в момент создания; дальше это обычный текст проекта.
    static func defaultStatuses() -> [ManuscriptStatus] {
        [ManuscriptStatus(title: L10n.tr("草稿"), color: .gray),
         ManuscriptStatus(title: L10n.tr("修改"), color: .orange),
         ManuscriptStatus(title: L10n.tr("完成"), color: .green)]
    }

    /// Код языка проекта по языку интерфейса; для китайского всегда `zh-CN`.
    static func bcp47Language(forInterface code: String) -> String {
        switch code {
        case "zh-Hans", "zh": return "zh-CN"
        case "ru": return "ru"
        default: return "en"
        }
    }
}

// MARK: - Обход дерева

extension ManuscriptProject {
    /// Все узлы в глубину, в порядке книги.
    func allNodes() -> [ManuscriptNode] {
        var result: [ManuscriptNode] = []
        func walk(_ list: [ManuscriptNode]) {
            for node in list { result.append(node); walk(node.children) }
        }
        walk(nodes)
        return result
    }

    func node(id: UUID) -> ManuscriptNode? {
        func find(_ list: [ManuscriptNode]) -> ManuscriptNode? {
            for node in list {
                if node.id == id { return node }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return find(nodes)
    }

    /// Родитель узла: `.some(nil)` — узел в корне, `nil` — узла нет.
    func parentID(of id: UUID) -> UUID?? {
        func find(_ list: [ManuscriptNode], parent: UUID?) -> UUID?? {
            for node in list {
                if node.id == id { return .some(parent) }
                if let found = find(node.children, parent: node.id) { return found }
            }
            return nil
        }
        return find(nodes, parent: nil)
    }

    /// Применяет правку к узлу на месте; false — узла нет.
    @discardableResult
    mutating func mutateNode(id: UUID, _ change: (inout ManuscriptNode) -> Void) -> Bool {
        func apply(_ list: inout [ManuscriptNode]) -> Bool {
            for index in list.indices {
                if list[index].id == id { change(&list[index]); return true }
                if apply(&list[index].children) { return true }
            }
            return false
        }
        return apply(&nodes)
    }

    /// Вынимает узел вместе с поддеревом. Возвращает узел, родителя и прежний индекс.
    mutating func removeNode(id: UUID) -> (node: ManuscriptNode, parent: UUID?, index: Int)? {
        func remove(_ list: inout [ManuscriptNode], parent: UUID?) -> (ManuscriptNode, UUID?, Int)? {
            for index in list.indices {
                if list[index].id == id { return (list.remove(at: index), parent, index) }
                if let found = remove(&list[index].children, parent: list[index].id) { return found }
            }
            return nil
        }
        return remove(&nodes, parent: nil).map { (node: $0.0, parent: $0.1, index: $0.2) }
    }

    /// Вставляет узел в родителя (nil — корень); индекс ограничивается диапазоном. false — родителя нет или это не группа.
    @discardableResult
    mutating func insertNode(_ node: ManuscriptNode, parent: UUID?, index: Int) -> Bool {
        guard let parent else {
            nodes.insert(node, at: min(max(index, 0), nodes.count))
            return true
        }
        guard self.node(id: parent)?.kind == .group else { return false }
        return mutateNode(id: parent) { target in
            target.children.insert(node, at: min(max(index, 0), target.children.count))
        }
    }

    /// Место узла: родитель (nil — корень) и индекс среди соседей.
    func location(of id: UUID) -> (parent: UUID?, index: Int)? {
        func find(_ list: [ManuscriptNode], parent: UUID?) -> (UUID?, Int)? {
            for (index, node) in list.enumerated() {
                if node.id == id { return (parent, index) }
                if let found = find(node.children, parent: node.id) { return found }
            }
            return nil
        }
        return find(nodes, parent: nil).map { (parent: $0.0, index: $0.1) }
    }

    /// Соседи под одним родителем (nil — корень).
    func children(of parent: UUID?) -> [ManuscriptNode] {
        guard let parent else { return nodes }
        return node(id: parent)?.children ?? []
    }

    /// Путь файла узла (без `.laceditor`) → узел: для поиска «этот файл уже в проекте».
    func node(forRelativePath path: String) -> ManuscriptNode? {
        allNodes().first { $0.kind == .text && $0.path == path }
    }
}

// MARK: - Проверка

struct ManuscriptProjectIssue: Equatable, Sendable {
    enum Severity: Sendable { case error, warning }
    let severity: Severity
    let message: String
    let nodeID: UUID?
}

enum ManuscriptProjectValidation {
    /// Чистая проверка модели. Символические ссылки проверяет `ManuscriptProjectStore` (нужна файловая система).
    static func validate(_ project: ManuscriptProject) -> [ManuscriptProjectIssue] {
        var issues: [ManuscriptProjectIssue] = []
        var ids = Set<UUID>()
        var paths = Set<String>()
        let statusTitles = Set(project.statuses.map(\.title))
        for node in project.allNodes() {
            if !ids.insert(node.id).inserted {
                issues.append(.init(severity: .error, message: "duplicate id \(node.id.uuidString)", nodeID: node.id))
            }
            if node.kind == .group {
                if node.path != nil { issues.append(.init(severity: .error, message: "group has a path", nodeID: node.id)) }
            } else if let path = node.path {
                if !isSafeRelativePath(path) {
                    issues.append(.init(severity: .error, message: "unsafe path \(path)", nodeID: node.id))
                } else {
                    if !paths.insert(path).inserted {
                        issues.append(.init(severity: .error, message: "duplicate path \(path)", nodeID: node.id))
                    }
                    let ext = (path as NSString).pathExtension.lowercased()
                    if !ManuscriptProjectFiles.textExtensions.contains(ext) {
                        issues.append(.init(severity: .warning, message: "unsupported extension \(path)", nodeID: node.id))
                    }
                }
            } else {
                issues.append(.init(severity: .warning, message: "text node without path", nodeID: node.id))
            }
            if let status = node.status, !statusTitles.contains(status) {
                issues.append(.init(severity: .warning, message: "unknown status \(status)", nodeID: node.id))
            }
        }
        return issues
    }

    /// Относительный путь без `..`, `.`, пустых компонентов, абсолютной формы и служебной папки.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return components.first != ".laceditor"
    }
}
