import Foundation

enum L10n {
    static let languageKey = "appLanguage"

    static func resolvedLanguage(selection: String, preferredLanguages: [String]) -> String {
        if ["zh-Hans", "en", "ru"].contains(selection) { return selection }
        for language in preferredLanguages {
            let normalized = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if normalized == "zh" || normalized.hasPrefix("zh-hans") || normalized.hasPrefix("zh-cn") || normalized.hasPrefix("zh-sg") { return "zh-Hans" }
            if normalized == "en" || normalized.hasPrefix("en-") { return "en" }
            if normalized == "ru" || normalized.hasPrefix("ru-") { return "ru" }
        }
        return "en"
    }

    static func saveLanguageSelection(_ selection: String, defaults: UserDefaults = .standard) {
        defaults.set(selection, forKey: languageKey)
        if ["zh-Hans", "en", "ru"].contains(selection) {
            defaults.set([selection], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    static func configure(defaults: UserDefaults = .standard) {
        let systemLanguages = (defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]) ?? Locale.preferredLanguages
        let language = resolvedLanguage(selection: defaults.string(forKey: languageKey) ?? "system", preferredLanguages: systemLanguages)
        activeLanguage = language
    }

    private static var activeLanguage = "en"
    static var languageCode: String { activeLanguage }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        let bundle = resources.path(forResource: activeLanguage, ofType: "lproj").flatMap(Bundle.init(path:)) ?? resources
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? format : String(format: format, arguments: arguments)
    }
}

extension L10n {
    /// Стабильный ключ показанного названия (не зависит от языка интерфейса) либо nil, если название неизвестно или неоднозначно.
    static func stableKey(forDisplayed title: String) -> String? {
        keyIndex.key(for: title)
    }

    private static let keyIndex: L10nKeyIndex = {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        let catalogs = ["zh-Hans", "en", "ru"].compactMap { language -> [String: String]? in
            resources.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
                .flatMap { $0.url(forResource: "Localizable", withExtension: "strings") }
                .flatMap { NSDictionary(contentsOf: $0) as? [String: String] }
        }
        return L10nKeyIndex(catalogs: catalogs)
    }()
}

/// Обратный поиск «показанное название → ключ каталога» по каталогам всех языков.
struct L10nKeyIndex {
    private var canonical: [String: String] = [:]
    private var byValue: [String: Set<String>] = [:]

    /// Каталоги в любом порядке; ключ, которого нет в каталоге, считается его собственным значением.
    init(catalogs: [[String: String]]) {
        var keys = Set<String>()
        for catalog in catalogs { keys.formUnion(catalog.keys) }
        // ключи с одинаковыми переводами на всех языках — один смысл, канонический — наименьший
        var groups: [[String]: String] = [:]
        for key in keys {
            let values = catalogs.map { $0[key] ?? key }
            if let current = groups[values], current <= key { continue }
            groups[values] = key
        }
        for key in keys {
            let values = catalogs.map { $0[key] ?? key }
            guard let root = groups[values] else { continue }
            canonical[key] = root
            for value in values { byValue[value, default: []].insert(root) }
        }
    }

    /// Канонический ключ либо nil, если название не найдено или подходит к разным смыслам.
    func key(for title: String) -> String? {
        if let root = canonical[title] { return root }
        if let roots = byValue[title], roots.count == 1 { return roots.first }
        return nil
    }
}
