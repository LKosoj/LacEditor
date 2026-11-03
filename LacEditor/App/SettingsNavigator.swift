import Foundation

/// Запрос «открыть раздел настроек (и страницу AI)». Окно настроек читает его при открытии и при изменении.
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    struct Request: Equatable {
        let id = UUID()
        let section: SettingsSection
        let aiPage: AISettingsPage?
    }

    @Published private(set) var request: Request?

    func open(_ section: SettingsSection, aiPage: AISettingsPage? = nil) {
        request = Request(section: section, aiPage: aiPage)
    }

    func clear() {
        request = nil
    }
}
