import Foundation

enum CriticMarkupKind: Equatable, Sendable { case insertion, deletion, substitution, comment, highlight }

struct CriticMarkupItem: Equatable, Sendable {
    let kind: CriticMarkupKind
    /// От `{` до `}` включительно.
    let range: NSRange
    /// Между разделителями; для подмены — вся пара «было~>стало».
    let content: NSRange
    /// `~>` только у подмены.
    let separator: NSRange?
}

enum CriticMarkupCommand: Equatable {
    case suggestInsertion, suggestDeletion, addComment
    case accept, reject, acceptAll, rejectAll
    case next, previous

    /// Название действия отмены; для навигации не используется.
    var actionName: String {
        switch self {
        case .suggestInsertion: L10n.tr("建议插入")
        case .suggestDeletion: L10n.tr("建议删除")
        case .addComment: L10n.tr("添加批注")
        case .accept: L10n.tr("接受当前修订")
        case .reject: L10n.tr("拒绝当前修订")
        case .acceptAll: L10n.tr("接受全部修订")
        case .rejectAll: L10n.tr("拒绝全部修订")
        case .next: L10n.tr("下一处修订")
        case .previous: L10n.tr("上一处修订")
        }
    }
}

/// CriticMarkup: `{++вставка++}`, `{--удаление--}`, `{~~было~>стало~~}`, `{>>комментарий<<}`, `{==выделение==}`.
/// Границы строк — CR, LF, CRLF (U+2028/U+2029 остаются содержимым), координаты — UTF-16.
enum CriticMarkupService {
    private static let kinds: [(open: String, close: String, kind: CriticMarkupKind)] = [
        ("{++", "++}", .insertion), ("{--", "--}", .deletion), ("{~~", "~~}", .substitution),
        ("{>>", "<<}", .comment), ("{==", "==}", .highlight)
    ]

    private static let brace: UInt16 = 0x7B
    private static let backslash: UInt16 = 0x5C

    /// Правки, начинающиеся в окне (или во всём тексте). `excluded` — отсортированные объединённые запрещённые диапазоны.
    static func items(in text: NSString, window: NSRange? = nil, excluded: [NSRange]) -> [CriticMarkupItem] {
        let length = text.length
        let bounds = window.map { NSIntersectionRange($0, NSRange(location: 0, length: length)) } ?? NSRange(location: 0, length: length)
        let end = NSMaxRange(bounds)
        var result: [CriticMarkupItem] = []
        var position = bounds.location
        while position < end {
            let found = text.range(of: "{", options: .literal, range: NSRange(location: position, length: end - position))
            guard found.location != NSNotFound else { break }
            let open = found.location
            guard let spec = openSpec(at: open, in: text) else { position = open + 1; continue }
            if let blocked = blockingRange(containing: open, in: excluded) {
                position = max(open + 1, NSMaxRange(blocked))
                continue
            }
            switch body(of: spec, open: open, in: text) {
            case .nested(let location):
                position = location
            case .none:
                position = open + 1
            case .closed(let close):
                let range = NSRange(location: open, length: close + 3 - open)
                let content = NSRange(location: open + 3, length: close - open - 3)
                var separator: NSRange?
                if spec.kind == .substitution {
                    let found = text.range(of: "~>", options: .literal, range: content)
                    guard found.location != NSNotFound else { position = open + 1; continue }
                    separator = found
                }
                if intersects(range, excluded) { position = open + 1; continue }
                result.append(CriticMarkupItem(kind: spec.kind, range: range, content: content, separator: separator))
                position = NSMaxRange(range)
            }
        }
        return result
    }

    /// Абзацы, пересекающие `range`: вверх и вниз до пустой строки или края текста.
    static func paragraphRange(containing range: NSRange, in text: NSString) -> NSRange {
        let length = text.length
        var start = lineStart(min(range.location, length), in: text)
        while start > 0 {
            let terminatorEnd = start - 1
            let previousEnd = terminatorEnd >= 1 && text.character(at: terminatorEnd) == 10 && text.character(at: terminatorEnd - 1) == 13
                ? terminatorEnd - 1 : terminatorEnd
            let previousStart = lineStart(previousEnd, in: text)
            if isBlankLine(at: previousStart, in: text) { break }
            start = previousStart
        }
        var end = lineEnd(min(NSMaxRange(range), length), in: text)
        while end < length {
            let nextStart = end + (text.character(at: end) == 13 && end + 1 < length && text.character(at: end + 1) == 10 ? 2 : 1)
            if isBlankLine(at: nextStart, in: text) { break }
            end = lineEnd(nextStart, in: text)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Результат принятия или отклонения одной правки: заменяет её целиком, включая `{` и `}`.
    static func resolution(of item: CriticMarkupItem, accept: Bool, in text: NSString) -> String {
        let content = text.substring(with: item.content)
        switch item.kind {
        case .insertion: return accept ? content : ""
        case .deletion: return accept ? "" : content
        case .comment: return ""
        case .highlight: return content
        case .substitution:
            guard let separator = item.separator else { return content }
            let before = text.substring(with: NSRange(location: item.content.location, length: separator.location - item.content.location))
            let after = text.substring(with: NSRange(location: NSMaxRange(separator), length: NSMaxRange(item.content) - NSMaxRange(separator)))
            return accept ? after : before
        }
    }

    /// Правка под выделением: выделение целиком внутри правки либо каретка сразу после `}`.
    static func item(at selection: NSRange, in items: [CriticMarkupItem]) -> CriticMarkupItem? {
        if let item = items.first(where: { $0.range.location <= selection.location && selection.location < NSMaxRange($0.range) }) {
            return NSMaxRange(selection) <= NSMaxRange(item.range) ? item : nil
        }
        guard selection.length == 0 else { return nil }
        return items.first { NSMaxRange($0.range) == selection.location }
    }

    static func next(after selection: NSRange, in items: [CriticMarkupItem]) -> CriticMarkupItem? {
        items.first { $0.range.location > selection.location }
    }

    static func previous(before selection: NSRange, in items: [CriticMarkupItem]) -> CriticMarkupItem? {
        items.last { $0.range.location < selection.location && selection.location >= NSMaxRange($0.range) }
    }

    /// Замены для принятия или отклонения всех правок, от конца к началу.
    static func resolutions(of items: [CriticMarkupItem], accept: Bool, in text: NSString) -> [(range: NSRange, replacement: String)] {
        items.reversed().map { (range: $0.range, replacement: resolution(of: $0, accept: accept, in: text)) }
    }

    /// Оборачивание выделения; nil — нельзя.
    static func suggestion(_ command: CriticMarkupCommand, in text: NSString, selection: NSRange,
                           items: [CriticMarkupItem], excluded: [NSRange]) -> MarkdownFormattingEdit? {
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return nil }
        let selected = text.substring(with: selection)
        let hasSelection = selection.length > 0
        let replacement: String
        let caret: NSRange
        let expected: [(CriticMarkupKind, NSRange)]
        switch command {
        case .suggestInsertion:
            replacement = "{++" + selected + "++}"
            caret = NSRange(location: 3, length: selection.length)
            expected = [(.insertion, NSRange(location: 0, length: replacement.utf16.count))]
        case .suggestDeletion:
            guard hasSelection else { return nil }
            replacement = "{--" + selected + "--}"
            caret = NSRange(location: 3, length: selection.length)
            expected = [(.deletion, NSRange(location: 0, length: replacement.utf16.count))]
        case .addComment:
            if hasSelection {
                let highlight = "{==" + selected + "==}"
                replacement = highlight + "{>><<}"
                let highlightLength = highlight.utf16.count
                caret = NSRange(location: highlightLength + 3, length: 0)
                expected = [(.highlight, NSRange(location: 0, length: highlightLength)),
                            (.comment, NSRange(location: highlightLength, length: 6))]
            } else {
                replacement = "{>><<}"
                caret = NSRange(location: 3, length: 0)
                expected = [(.comment, NSRange(location: 0, length: 6))]
            }
        default:
            return nil
        }
        if hasSelection {
            if intersects(selection, excluded) { return nil }
        } else if excluded.contains(where: { $0.location < selection.location && selection.location < NSMaxRange($0) }) {
            return nil
        }
        // Вложенность запрещена: выделение, задевающее правку (с запасом в один символ), не оборачивается.
        let touched = hasSelection
            ? NSIntersectionRange(NSRange(location: max(0, selection.location - 1), length: selection.length + 2), NSRange(location: 0, length: text.length))
            : selection
        if items.contains(where: { hasSelection
            ? NSIntersectionRange(touched, $0.range).length > 0
            : $0.range.location < touched.location && touched.location < NSMaxRange($0.range) }) { return nil }
        if hasSelection, paragraphRange(containing: NSRange(location: NSMaxRange(selection), length: 0), in: text).location > selection.location { return nil }
        if backslashRun(before: selection.location, in: text) % 2 == 1 { return nil }
        // Результат отдельно должен разбираться ровно как задумано (внутри нет закрытия своего вида и вложенных разделителей).
        let probe = CriticMarkupService.items(in: replacement as NSString, excluded: [])
        guard probe.count == expected.count,
              zip(probe, expected).allSatisfy({ $0.kind == $1.0 && $0.range == $1.1 }),
              probe.first.map({ !hasSelection || $0.content == NSRange(location: 3, length: selection.length) }) == true else { return nil }
        return MarkdownFormattingEdit(range: selection, replacement: replacement,
                                      selectionRange: NSRange(location: selection.location + caret.location, length: caret.length))
    }

    // MARK: - Разбор

    private enum Body {
        case closed(Int)
        case nested(Int)
        case none
    }

    private static func openSpec(at index: Int, in text: NSString) -> (close: String, kind: CriticMarkupKind)? {
        guard index + 3 <= text.length, text.character(at: index) == brace, backslashRun(before: index, in: text) % 2 == 0 else { return nil }
        let second = text.character(at: index + 1), third = text.character(at: index + 2)
        guard second == third else { return nil }
        for spec in kinds where spec.open.utf16.dropFirst().first == second { return (spec.close, spec.kind) }
        return nil
    }

    /// Один проход вперёд: закрытие своего вида, вложенное открытие либо пустая строка и конец текста.
    private static func body(of spec: (close: String, kind: CriticMarkupKind), open: Int, in text: NSString) -> Body {
        let length = text.length
        let close = Array(spec.close.utf16)
        var index = open + 3
        while index < length {
            let character = text.character(at: index)
            if character == close[0], index + 3 <= length, text.character(at: index + 1) == close[1], text.character(at: index + 2) == close[2] {
                return .closed(index)
            }
            if character == brace, openSpec(at: index, in: text) != nil { return .nested(index) }
            if character == 10 || character == 13 {
                let next = index + (character == 13 && index + 1 < length && text.character(at: index + 1) == 10 ? 2 : 1)
                if isBlankLine(at: next, in: text) { return .none }
                index = next
                continue
            }
            index += 1
        }
        return .none
    }

    private static func backslashRun(before index: Int, in text: NSString) -> Int {
        var count = 0
        var position = index - 1
        while position >= 0, text.character(at: position) == backslash { count += 1; position -= 1 }
        return count
    }

    private static func lineStart(_ index: Int, in text: NSString) -> Int {
        var position = index
        while position > 0 {
            let character = text.character(at: position - 1)
            if character == 10 || character == 13 { break }
            position -= 1
        }
        return position
    }

    private static func lineEnd(_ index: Int, in text: NSString) -> Int {
        var position = index
        while position < text.length {
            let character = text.character(at: position)
            if character == 10 || character == 13 { break }
            position += 1
        }
        return position
    }

    /// Пустая строка: только пробелы, табуляции и `>` (до перевода строки или конца текста).
    private static func isBlankLine(at start: Int, in text: NSString) -> Bool {
        var position = start
        while position < text.length {
            let character = text.character(at: position)
            if character == 10 || character == 13 { return true }
            guard character == 32 || character == 9 || character == 0x3E else { return false }
            position += 1
        }
        return true
    }

    // MARK: - Запрещённые диапазоны

    /// Первый запрещённый диапазон, у которого `location < index < max` либо `location <= index < max`.
    private static func blockingRange(containing index: Int, in excluded: [NSRange]) -> NSRange? {
        guard let candidate = firstEnding(after: index, in: excluded) else { return nil }
        return excluded[candidate].location <= index ? excluded[candidate] : nil
    }

    private static func intersects(_ range: NSRange, _ excluded: [NSRange]) -> Bool {
        guard let candidate = firstEnding(after: range.location, in: excluded) else { return false }
        return excluded[candidate].location < NSMaxRange(range) || (range.length == 0 && excluded[candidate].location <= range.location)
    }

    /// Индекс первого диапазона с `max > index` (диапазоны отсортированы и не пересекаются).
    private static func firstEnding(after index: Int, in excluded: [NSRange]) -> Int? {
        var low = 0, high = excluded.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(excluded[middle]) <= index { low = middle + 1 } else { high = middle }
        }
        return low < excluded.count ? low : nil
    }
}
