import Foundation

/// Почему AI-функция сейчас недоступна (или доступна). Используется подсказкой «Включите AI, чтобы …».
enum AIAvailability: Equatable {
    case available, aiDisabled, featureDisabled, noModel
}
