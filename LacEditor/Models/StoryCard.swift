import Foundation
import Yams

/// Тип карточки мира. В файле хранится как `type: character` (регистр при чтении не важен).
enum StoryCardType: String, CaseIterable, Identifiable, Sendable {
    case character, place, organization, item, rule

    var id: String { rawValue }

    /// Формы различаются, цвет смысла не несёт (17.5).
    var symbol: String {
        switch self {
        case .character: "person"
        case .place: "mappin.and.ellipse"
        case .organization: "building.2"
        case .item: "cube"
        case .rule: "book.closed"
        }
    }

    var title: String {
        switch self {
        case .character: L10n.tr("人物")
        case .place: L10n.tr("地点")
        case .organization: L10n.tr("组织")
        case .item: L10n.tr("物品")
        case .rule: L10n.tr("规则")
        }
    }

    static func parse(_ raw: String) -> StoryCardType? {
        StoryCardType(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Связь карточки. `to` — id карточки-цели или её название/псевдоним; `kind` — подпись связи (может быть пустой).
struct StoryCardRelation: Equatable, Sendable {
    var to: String
    var kind: String
}

struct StoryCard: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    var type: StoryCardType
    var cardID: UUID?
    var title: String
    var aliases: [String]
    var relations: [StoryCardRelation]
    /// `ai: exclude`: карточка не отправляется в AI ни как контекст, ни как известная сущность.
    var excludedFromAI: Bool

    /// Стабильный ключ для интерфейса и карты связей: id из шапки, а без него — путь.
    var id: String { cardID?.uuidString ?? relativePath }
    var allNames: [String] { [title] + aliases }
}

enum StoryCardHeader {
    /// nil, если файл не карточка: нет шапки, нет `type` или тип неизвестен.
    static func parse(_ text: String, url: URL, root: URL) -> StoryCard? {
        guard let mapping = try? PandocExportService.yamlFrontMatter(text) else { return nil }
        var values: [String: Yams.Node] = [:]
        for item in mapping {
            if let key = item.key.scalar?.string { values[key] = item.value }
        }
        guard let rawType = values["type"]?.scalar?.string, let type = StoryCardType.parse(rawType) else { return nil }
        var seen = Set<String>()
        let aliases = strings(values["aliases"]).filter { seen.insert($0).inserted }
        let id = values["id"]?.scalar.flatMap { UUID(uuidString: $0.string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let relativePath = FolderSearchService.relativePath(url, root: root) ?? url.lastPathComponent
        let title = StoryCardText.firstHeading(in: text)
            ?? (url.lastPathComponent as NSString).deletingPathExtension
        let excluded = values["ai"]?.scalar?.string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "exclude"
        return StoryCard(url: url, relativePath: relativePath, type: type, cardID: id, title: title, aliases: aliases,
                         relations: relations(values["relations"]), excludedFromAI: excluded)
    }

    /// Скаляр или список скаляров; пустые значения отбрасываются, повторы остаются (их убирает вызывающий).
    static func strings(_ node: Yams.Node?) -> [String] {
        guard let node else { return [] }
        func value(_ item: Yams.Node) -> String? {
            let text = item.scalar?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        if let sequence = node.sequence { return sequence.compactMap(value) }
        return value(node).map { [$0] } ?? []
    }

    /// Список отображений `{to, kind}`; элемент без `to` пропускается.
    static func relations(_ node: Yams.Node?) -> [StoryCardRelation] {
        node?.sequence?.compactMap(relation) ?? []
    }

    static func relation(_ item: Yams.Node) -> StoryCardRelation? {
        guard let mapping = item.mapping else { return nil }
        var to = "", kind = ""
        for pair in mapping {
            let value = pair.value.scalar?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch pair.key.scalar?.string {
            case "to": to = value
            case "kind": kind = value
            default: break
            }
        }
        return to.isEmpty ? nil : StoryCardRelation(to: to, kind: kind)
    }
}

/// Разбор текста Markdown для карточек и упоминаний: шапка и блоки кода в обычный текст не входят.
enum StoryCardText {
    /// Диапазоны UTF-16 без шапки и без блоков кода (``` и ~~~).
    static func proseRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var proseStart = 0
        if let front = MarkdownFrontMatter.frontMatter(text) { proseStart = NSMaxRange(front.range) }
        var result: [NSRange] = []
        var fence: (character: Character, count: Int)?
        var position = proseStart
        while position < ns.length {
            let line = ns.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(line)
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fence {
                let run = trimmed.prefix { $0 == open.character }
                if run.count >= open.count, trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    proseStart = NSMaxRange(line)
                }
            } else if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }
                if run.count >= 3 {
                    fence = (first, run.count)
                    if line.location > proseStart { result.append(NSRange(location: proseStart, length: line.location - proseStart)) }
                }
            }
        }
        if fence == nil, ns.length > proseStart { result.append(NSRange(location: proseStart, length: ns.length - proseStart)) }
        return result
    }

    /// Первый заголовок `# ` вне блоков кода.
    static func firstHeading(in text: String) -> String? {
        let ns = text as NSString
        for range in proseRanges(in: text) {
            var found: String?
            ns.enumerateSubstrings(in: range, options: .byLines) { line, _, _, stop in
                guard let line, line.hasPrefix("# ") else { return }
                var title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                while title.hasSuffix("#") { title.removeLast() }
                title = title.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { found = title; stop.pointee = true }
            }
            if let found { return found }
        }
        return nil
    }
}
