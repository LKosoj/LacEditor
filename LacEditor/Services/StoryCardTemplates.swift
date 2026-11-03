import Foundation

/// Заготовки карточек и имена папок «Мир» на трёх языках. Поле `id` в заготовку не входит: его добавит первая правка шапки.
enum StoryCardTemplates {
    /// Папки, которые считаются папкой карточек, на любом из трёх языков.
    static let folderNames = ["设定", "World", "Мир"]

    static var folderName: String {
        switch L10n.languageCode {
        case "ru": "Мир"
        case "en": "World"
        default: "设定"
        }
    }

    static func fileName(for type: StoryCardType) -> String {
        switch L10n.languageCode {
        case "ru":
            switch type {
            case .character: "Персонаж.md"
            case .place: "Место.md"
            case .organization: "Организация.md"
            case .item: "Предмет.md"
            case .rule: "Правило.md"
            }
        case "en":
            switch type {
            case .character: "Character.md"
            case .place: "Place.md"
            case .organization: "Organization.md"
            case .item: "Item.md"
            case .rule: "Rule.md"
            }
        default:
            switch type {
            case .character: "人物.md"
            case .place: "地点.md"
            case .organization: "组织.md"
            case .item: "物品.md"
            case .rule: "规则.md"
            }
        }
    }

    /// Заготовка с `{{title}}`: название подставляет `NoteTemplateService.render`.
    static func skeleton(for type: StoryCardType) -> String {
        let head = "---\ntype: \(type.rawValue)\naliases: []\n---\n\n# {{title}}\n\n"
        switch L10n.languageCode {
        case "ru":
            switch type {
            case .character: return head + "## Внешность\n\n## Характер\n\n## Факты\n"
            case .place: return head + "## Описание\n\n## Факты\n"
            case .organization: return head + "## Цели\n\n## Факты\n"
            case .item: return head + "## Описание\n\n## Факты\n"
            case .rule: return head + "## Суть правила\n\n## Факты\n"
            }
        case "en":
            switch type {
            case .character: return head + "## Appearance\n\n## Personality\n\n## Facts\n"
            case .place: return head + "## Description\n\n## Facts\n"
            case .organization: return head + "## Goals\n\n## Facts\n"
            case .item: return head + "## Description\n\n## Facts\n"
            case .rule: return head + "## The Rule\n\n## Facts\n"
            }
        default:
            switch type {
            case .character: return head + "## 外貌\n\n## 性格\n\n## 事实\n"
            case .place: return head + "## 描述\n\n## 事实\n"
            case .organization: return head + "## 目标\n\n## 事实\n"
            case .item: return head + "## 描述\n\n## 事实\n"
            case .rule: return head + "## 规则内容\n\n## 事实\n"
            }
        }
    }

    /// Заголовок раздела фактов на языке интерфейса (для добавления фактов).
    static var factsHeading: String {
        switch L10n.languageCode {
        case "ru": "Факты"
        case "en": "Facts"
        default: "事实"
        }
    }

    /// Все названия раздела фактов, чтобы находить раздел, созданный на другом языке.
    static let factsHeadings = ["Факты", "Facts", "事实"]

    /// Копирует недостающие заготовки в папку шаблонов, существующие файлы не трогает. Возвращает число добавленных.
    static func installTemplates(into folder: URL) throws -> Int {
        var added = 0
        for type in StoryCardType.allCases {
            let url = folder.appendingPathComponent(fileName(for: type))
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try Data(skeleton(for: type).utf8).write(to: url, options: .withoutOverwriting)
            added += 1
        }
        return added
    }
}

/// Добавление фактов в раздел «Факты» карточки: одна вставка, остальной текст не меняется.
enum StoryCardFactsWriter {
    struct Insertion: Equatable {
        var range: NSRange
        var replacement: String
    }

    static func insertion(adding facts: [String], to text: String) -> Insertion? {
        let lines = facts.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { "- " + $0 + "\n" }
        guard !lines.isEmpty else { return nil }
        let bullets = lines.joined()
        let ns = text as NSString
        var headingLevel = 0
        var insertAt: Int?
        for prose in StoryCardText.proseRanges(in: text) {
            var position = prose.location
            while position < NSMaxRange(prose) {
                let line = ns.lineRange(for: NSRange(location: position, length: 0))
                position = NSMaxRange(line)
                let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes > 0, hashes <= 6, trimmed.dropFirst(hashes).first == " " {
                    if headingLevel > 0, hashes <= headingLevel { break }
                    var title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                    while title.hasSuffix("#") { title.removeLast() }
                    if headingLevel == 0, StoryCardTemplates.factsHeadings.contains(title.trimmingCharacters(in: .whitespaces)) {
                        headingLevel = hashes
                        insertAt = NSMaxRange(line)
                    }
                } else if headingLevel > 0, !trimmed.isEmpty {
                    insertAt = NSMaxRange(line)
                }
            }
            if headingLevel > 0 { break }
        }
        if let insertAt {
            let needsBreak = insertAt > 0 && !(ns.substring(with: NSRange(location: insertAt - 1, length: 1)) == "\n")
            return Insertion(range: NSRange(location: insertAt, length: 0), replacement: (needsBreak ? "\n" : "") + bullets)
        }
        var prefix = ""
        if ns.length > 0 {
            prefix = text.hasSuffix("\n") ? "\n" : "\n\n"
        }
        return Insertion(range: NSRange(location: ns.length, length: 0),
                         replacement: prefix + "## " + StoryCardTemplates.factsHeading + "\n\n" + bullets)
    }
}
