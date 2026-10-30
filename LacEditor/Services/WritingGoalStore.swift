import Foundation

/// Прогресс цели письма за локальный календарный день.
/// Хранит по документу базовое (первое увиденное за день) и последнее число слов; прогресс = сумма max(0, последнее − базовое).
@MainActor
final class WritingGoalStore: ObservableObject {
    struct Entry: Codable, Equatable {
        var base: Int
        var last: Int
        /// Закрытый документ оставляет вклад до конца дня, но не переносится на следующий.
        var closed: Bool? = nil
    }

    private enum Keys {
        static let day = "writingGoalDay"
        static let entries = "writingGoalEntries"
    }

    /// Увеличивается при каждом изменении записей или смене дня.
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private var day: String
    private var entries: [String: Entry]

    init(defaults: UserDefaults, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        // Запись прошлого дня читается тоже: первый `record` перенесёт базы открытых документов.
        if let storedDay = defaults.string(forKey: Keys.day),
           let data = defaults.data(forKey: Keys.entries),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            day = storedDay
            entries = stored
        } else {
            day = Self.dayKey(calendar: calendar, date: now())
            entries = [:]
        }
    }

    /// Для показа: 0, если сохранённый день не сегодняшний. Ничего не пишет и не публикует (вызывается из body).
    func progress() -> Int {
        guard dayKey() == day else { return 0 }
        return entries.values.reduce(0) { $0 + max(0, $1.last - $1.base) }
    }

    /// Фиксирует число слов всего документа. Возвращает true, если значение изменилось.
    @discardableResult
    func record(words: Int, documentID: UUID) -> Bool {
        guard words >= 0 else { return false }
        let today = dayKey()
        let rolledOver = today != day
        let key = documentID.uuidString
        // Новый день продолжает с последнего значения: иначе слова до первой статистики войдут в базу.
        var updated = rolledOver
            ? entries.filter { $0.value.closed != true }.mapValues { Entry(base: $0.last, last: $0.last) }
            : entries
        if var entry = updated[key] {
            guard entry.last != words || entry.closed == true else {
                if rolledOver { commit(day: today, entries: updated) }
                return rolledOver
            }
            entry.last = words
            entry.closed = nil
            updated[key] = entry
        } else {
            updated[key] = Entry(base: words, last: words)
        }
        commit(day: today, entries: updated)
        return true
    }

    /// Смена способа подсчёта (например, языка документа): новое число слов не считается написанным, прогресс сохраняется.
    func rebase(words: Int, documentID: UUID) {
        let key = documentID.uuidString
        guard words >= 0, dayKey() == day, var entry = entries[key], entry.last != words else {
            record(words: words, documentID: documentID)
            return
        }
        entry.base += words - entry.last
        entry.last = words
        var updated = entries
        updated[key] = entry
        commit(day: day, entries: updated)
    }

    /// Документ закрыт: его вклад остаётся до конца дня.
    func markClosed(documentID: UUID) {
        let key = documentID.uuidString
        guard var entry = entries[key], entry.closed != true else { return }
        entry.closed = true
        var updated = entries
        updated[key] = entry
        commit(day: day, entries: updated)
    }

    private func commit(day newDay: String, entries newEntries: [String: Entry]) {
        objectWillChange.send()
        day = newDay
        entries = newEntries
        revision += 1
        defaults.set(newDay, forKey: Keys.day)
        if let data = try? JSONEncoder().encode(newEntries) {
            defaults.set(data, forKey: Keys.entries)
        }
    }

    private func dayKey() -> String {
        Self.dayKey(calendar: calendar, date: now())
    }

    private static func dayKey(calendar: Calendar, date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
