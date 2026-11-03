import Foundation

extension AppState {
    /// Порядок проверки: подключение роли → функция → модель.
    /// Ключ из Keychain не читается: читать связку на главном потоке в `body` нельзя.
    /// Отсутствие ключа обрабатывает сам запуск функции (ошибки AIError).
    func aiAvailability(for feature: AIFeature) -> AIAvailability {
        let profile = preferences.aiProfile(for: feature)
        guard profile.isEnabled else { return .aiDisabled }
        guard preferences.aiFeatures.contains(feature) else { return .featureDisabled }
        guard !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noModel }
        return .available
    }
}
