import Foundation

/// Выбор пользователя в листе конфликта: что взято в каждом конфликтном куске, навигация и «всё ли решено».
/// Чистая модель: клавиатура листа и проверка «можно применять» работают без SwiftUI.
struct VaultConflictSelection: Equatable, Sendable {
    let conflict: VaultMergeConflict
    /// Номера конфликтных кусков по порядку текста.
    let conflictIDs: [Int]
    private(set) var choices: [Int: VaultMergeSide] = [:]

    init(conflict: VaultMergeConflict) {
        self.conflict = conflict
        conflictIDs = conflict.chunks.compactMap {
            if case .conflict(let id, _, _, _) = $0 { return id }
            return nil
        }
    }

    var total: Int { conflictIDs.count }
    var resolvedCount: Int { conflictIDs.filter { choices[$0] != nil }.count }
    var isComplete: Bool { total > 0 && resolvedCount == total }
    var firstUnresolved: Int? { conflictIDs.first { choices[$0] == nil } }

    /// Заметка слишком большая для показа по кускам: один кусок «весь текст» и больше `wholeTextLineLimit` строк в трёх версиях.
    var isWholeTextOnly: Bool {
        guard conflict.chunks.count == 1, case .conflict(_, let mine, let server, let base) = conflict.chunks[0] else { return false }
        return Self.lineCount(mine) + Self.lineCount(server) + Self.lineCount(base) > Self.wholeTextLineLimit
    }

    static let wholeTextLineLimit = 3_000

    func choice(for id: Int) -> VaultMergeSide? { choices[id] }

    /// Варианты куска: «Оба» только там, где у куска пустая основа и обе стороны что-то дописали (иначе при правке одной
    /// и той же строки получился бы дубль).
    func availableSides(for id: Int) -> [VaultMergeSide] {
        guard let parts = parts(of: id) else { return [] }
        var sides: [VaultMergeSide] = [.mine, .server]
        if parts.base.isEmpty, !parts.mine.isEmpty, !parts.server.isEmpty { sides.append(.both) }
        return sides
    }

    mutating func choose(_ side: VaultMergeSide, for id: Int) {
        guard availableSides(for: id).contains(side) else { return }
        choices[id] = side
    }

    mutating func clear(_ id: Int) { choices[id] = nil }

    /// ←/→: без выбора ← берёт «Ваш вариант», → берёт «С сервера»; с выбором двигает по доступным вариантам без зацикливания.
    mutating func step(_ direction: Int, from id: Int) {
        let sides = availableSides(for: id)
        guard !sides.isEmpty, direction != 0 else { return }
        guard let current = choices[id], let index = sides.firstIndex(of: current) else {
            choices[id] = direction < 0 ? sides[0] : sides[1]
            return
        }
        let target = min(max(index + (direction < 0 ? -1 : 1), 0), sides.count - 1)
        choices[id] = sides[target]
    }

    /// ↓ (без зацикливания). С nil — первый кусок.
    func next(after id: Int?) -> Int? {
        guard let id else { return conflictIDs.first }
        guard let index = conflictIDs.firstIndex(of: id), index + 1 < conflictIDs.count else { return nil }
        return conflictIDs[index + 1]
    }

    /// ↑ (без зацикливания). С nil — первый кусок.
    func previous(before id: Int?) -> Int? {
        guard let id else { return conflictIDs.first }
        guard let index = conflictIDs.firstIndex(of: id), index > 0 else { return nil }
        return conflictIDs[index - 1]
    }

    /// Ближайший нерешённый кусок после `id`, с переходом через конец; nil — всё решено.
    func nextUnresolved(after id: Int?) -> Int? {
        guard !conflictIDs.isEmpty else { return nil }
        let start = id.flatMap { conflictIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for offset in 0..<conflictIDs.count {
            let candidate = conflictIDs[(start + offset) % conflictIDs.count]
            if choices[candidate] == nil { return candidate }
        }
        return nil
    }

    /// Итоговый текст; nil, пока выбраны не все куски.
    var resolvedText: String? { conflict.resolved(choices: choices) }

    /// Номер строки (с 1), с которой кусок начинается в тексте стороны. Для `.both` берётся текст сервера.
    func lineStart(of id: Int, side: VaultMergeSide) -> Int {
        var lines = 0
        for chunk in conflict.chunks {
            switch chunk {
            case .stable(let text):
                lines += Self.lineCount(text)
            case .conflict(let chunkID, let mine, let server, _):
                if chunkID == id { return lines + 1 }
                lines += Self.lineCount(side == .mine ? mine : server)
            }
        }
        return lines + 1
    }

    /// Число строк текста: последний перевод строки не открывает новую строку.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let breaks = text.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        return text.utf8.last == 10 ? breaks : breaks + 1
    }

    /// Номера строк куска в тексте стороны: от начала до конца (включительно); у пустой стороны конец равен началу.
    func lineRange(of id: Int, side: VaultMergeSide) -> ClosedRange<Int> {
        let start = lineStart(of: id, side: side)
        guard let parts = parts(of: id) else { return start...start }
        let count = Self.lineCount(side == .mine ? parts.mine : parts.server)
        return start...max(start, start + count - 1)
    }

    func parts(of id: Int) -> (mine: String, server: String, base: String)? {
        for chunk in conflict.chunks {
            if case .conflict(let chunkID, let mine, let server, let base) = chunk, chunkID == id { return (mine, server, base) }
        }
        return nil
    }
}
