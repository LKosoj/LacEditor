import Foundation

/// Настройки проверки стиля: одна структура, один ключ в `UserDefaults`.
struct StyleCheckSettings: Codable, Equatable, Sendable {
    var windowWords = 30            // повтор слова: окно в словах (en/ru/other)
    var windowChars = 60            // повтор слова: окно в знаках (zh)
    var longSentenceWords = 35      // en/ru/other
    var longSentenceChars = 80      // zh
    var fixedLanguage: TextLanguage?        // nil = определять по предложению
    var customWords: [String] = []          // слова и фразы, которых надо избегать
    var customStopWords: [String] = []      // не учитываются при поиске повторов
    var disabledCategories: Set<String> = []   // rawValue StyleCategory; пусто = все включены
    var goal = ""                           // цель AI-проверки (аудитория, тон), не больше 500 знаков
    var autoCheck = true                    // локальная автопроверка после паузы набора

    static let `default` = StyleCheckSettings()

    init() {}

    func isEnabled(_ category: StyleCategory) -> Bool { !disabledCategories.contains(category.rawValue) }

    mutating func setEnabled(_ category: StyleCategory, _ enabled: Bool) {
        if enabled { disabledCategories.remove(category.rawValue) } else { disabledCategories.insert(category.rawValue) }
    }

    /// Границы: windowWords 5...100, windowChars 10...200, longSentenceWords 10...100, longSentenceChars 20...300; goal не длиннее 500 знаков.
    func clamped() -> StyleCheckSettings {
        var copy = self
        copy.windowWords = min(max(windowWords, 5), 100)
        copy.windowChars = min(max(windowChars, 10), 200)
        copy.longSentenceWords = min(max(longSentenceWords, 10), 100)
        copy.longSentenceChars = min(max(longSentenceChars, 20), 300)
        copy.goal = String(goal.prefix(500))
        return copy
    }

    /// Списки без пустых строк, trim, без дублей (без учёта регистра), не более 500 элементов, элемент не длиннее 100 знаков.
    static func parseList(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let item = String(line.trimmingCharacters(in: .whitespaces).prefix(100))
            guard !item.isEmpty, seen.insert(item.lowercased()).inserted else { continue }
            result.append(item)
            if result.count == 500 { break }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case windowWords, windowChars, longSentenceWords, longSentenceChars, fixedLanguage
        case customWords, customStopWords, disabledCategories, goal, autoCheck
    }

    /// Новые поля не ломают старые данные: каждое читается через `decodeIfPresent`.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StyleCheckSettings()
        windowWords = try values.decodeIfPresent(Int.self, forKey: .windowWords) ?? defaults.windowWords
        windowChars = try values.decodeIfPresent(Int.self, forKey: .windowChars) ?? defaults.windowChars
        longSentenceWords = try values.decodeIfPresent(Int.self, forKey: .longSentenceWords) ?? defaults.longSentenceWords
        longSentenceChars = try values.decodeIfPresent(Int.self, forKey: .longSentenceChars) ?? defaults.longSentenceChars
        fixedLanguage = try values.decodeIfPresent(TextLanguage.self, forKey: .fixedLanguage)
        customWords = try values.decodeIfPresent([String].self, forKey: .customWords) ?? []
        customStopWords = try values.decodeIfPresent([String].self, forKey: .customStopWords) ?? []
        disabledCategories = try values.decodeIfPresent(Set<String>.self, forKey: .disabledCategories) ?? []
        goal = try values.decodeIfPresent(String.self, forKey: .goal) ?? ""
        autoCheck = try values.decodeIfPresent(Bool.self, forKey: .autoCheck) ?? true
        self = clamped()
    }
}
