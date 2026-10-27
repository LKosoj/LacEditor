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
