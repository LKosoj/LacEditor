import Foundation

enum AITextComparison {
    private struct Line: Hashable {
        let text: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            for byte in text.utf8 { hasher.combine(byte) }
        }
    }

    static func compare(before: String, after: String) -> String {
        guard !before.utf8.elementsEqual(after.utf8) else { return L10n.tr("文本相同。") }
        let old = lines(before)
        let new = lines(after)
        let changes = new.difference(from: old)
        return changes.map { change in
            let prefix: String
            let line: String
            switch change {
            case .remove(_, let value, _): prefix = "-"; line = value.text
            case .insert(_, let value, _): prefix = "+"; line = value.text
            }
            let encoded = (try? JSONEncoder().encode(line)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            return "\(prefix) \(encoded)"
        }.joined(separator: "\n")
    }

    struct Change: Equatable, Sendable {
        enum Kind: Sendable { case removed, added }
        let kind: Kind
        /// Номер строки с единицы: в старом тексте для удалённой, в новом для добавленной.
        let line: Int
        let text: String
    }

    /// Те же изменённые строки, что и в `compare`, но структурой и в порядке документа.
    static func changes(before: String, after: String) -> [Change] {
        let old = lines(before)
        let new = lines(after)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Change] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                result.append(Change(kind: .removed, line: oldIndex + 1, text: old[oldIndex].text))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                result.append(Change(kind: .added, line: newIndex + 1, text: new[newIndex].text))
                newIndex += 1
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
        return result
    }

    private static func lines(_ text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        var result: [Line] = []
        var position = 0
        while position < source.length {
            let range = source.lineRange(for: NSRange(location: position, length: 0))
            result.append(Line(text: source.substring(with: range)))
            position = NSMaxRange(range)
        }
        return result
    }
}
