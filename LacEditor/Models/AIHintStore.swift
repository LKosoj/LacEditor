import Foundation

/// Запоминает, какие подсказки «Включите AI, чтобы …» пользователь закрыл крестиком.
struct AIHintStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ feature: AIFeature) -> String { "aiHintDismissed.\(feature.rawValue)" }

    func isDismissed(_ feature: AIFeature) -> Bool {
        defaults.bool(forKey: Self.key(feature))
    }

    func dismiss(_ feature: AIFeature) {
        defaults.set(true, forKey: Self.key(feature))
    }

    func resetAll() {
        for feature in AIFeature.allCases { defaults.removeObject(forKey: Self.key(feature)) }
    }
}
