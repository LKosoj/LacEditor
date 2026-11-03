import Foundation
import SwiftUI

/// Отрывок фрагмента для списка результатов: окно вокруг первого найденного слова и подсветка слов запроса.
enum SearchHighlight {
    /// Окно около `limit` символов с «…» по краям. `ranges` — UTF-16 относительно возвращённого текста (с учётом «…»).
    /// Слово подсвечивается, если его нормализованная форма входит в `terms`.
    static func excerpt(from raw: String, terms: Set<String>, limit: Int = 240) -> (text: String, ranges: [NSRange]) {
        let ns = raw as NSString
        let words = TextSegmentation.words(in: raw)
        guard let firstWord = words.first else { return (flatten(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)), []) }
        let matching = words.filter { word in SearchTextNormalizer.term(for: word.text).map { terms.contains($0) } == true }
        let anchor = matching.first ?? firstWord
        var start = max(0, anchor.range.location - limit / 4)
        if start > 0 {
            start = words.first { $0.range.location >= start }?.range.location ?? anchor.range.location
        }
        var end = min(ns.length, start + limit)
        if end < ns.length {
            end = words.last { $0.range.location >= start && NSMaxRange($0.range) <= end }.map { NSMaxRange($0.range) } ?? end
        }
        end = max(end, NSMaxRange(anchor.range))
        let prefix = start > 0 ? "…" : ""
        let suffix = end < ns.length ? "…" : ""
        let window = flatten(ns.substring(with: NSRange(location: start, length: end - start)))
        let shift = (prefix as NSString).length - start
        let ranges = matching.filter { $0.range.location >= start && NSMaxRange($0.range) <= end }
            .map { NSRange(location: $0.range.location + shift, length: $0.range.length) }
        return (prefix + window + suffix, ranges)
    }

    /// Выделение жирным и фоном, а не только цветом: так видно и при настройках доступности.
    static func attributed(_ excerpt: (text: String, ranges: [NSRange])) -> AttributedString {
        let ns = excerpt.text as NSString
        var result = AttributedString()
        var cursor = 0
        for range in excerpt.ranges.sorted(by: { $0.location < $1.location })
        where range.location >= cursor && NSMaxRange(range) <= ns.length {
            result += AttributedString(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            var piece = AttributedString(ns.substring(with: range))
            piece.inlinePresentationIntent = .stronglyEmphasized
            piece.swiftUI.backgroundColor = Color.accentColor.opacity(0.25)
            result += piece
            cursor = NSMaxRange(range)
        }
        result += AttributedString(ns.substring(from: cursor))
        return result
    }

    /// Переводы строк становятся пробелами; длина в UTF-16 не меняется.
    private static func flatten<S: StringProtocol>(_ text: S) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == "\n" || $0 == "\r" ? " " : $0 }))
    }
}
