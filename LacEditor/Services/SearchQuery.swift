import Foundation

/// Запрос режима «По словам»: слова пользователя и отдельно слова-расширения от ИИ.
/// В выражение MATCH попадают только нормализованные термы в кавычках, сырой ввод не используется никогда.
struct SearchQuery: Equatable, Sendable {
    enum Joiner: Sendable { case and, or }

    /// Термы запроса пользователя (между ними AND или OR).
    var terms: [String]
    /// Слова ИИ: добавляются через OR ко всему базовому запросу.
    var expansion: [String]

    init(text: String, expansion: [String] = []) {
        terms = SearchTextNormalizer.queryTerms(text)
        var seen = Set(terms)
        var extra: [String] = []
        for word in expansion {
            for segment in TextSegmentation.words(in: word) {
                guard let term = SearchTextNormalizer.term(for: segment.text), seen.insert(term).inserted else { continue }
                extra.append(term)
            }
        }
        self.expansion = extra
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Все термы для подсветки и оценки.
    var allTerms: Set<String> { Set(terms + expansion) }

    /// Термы для сопоставления: слова пользователя и расширение.
    var matchedTerms: [String] { terms + expansion }

    static func quote(_ term: String) -> String {
        "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Пустой запрос не должен доходить до MATCH.
    func matchExpression(joiner: Joiner) -> String {
        let base = terms.map(Self.quote).joined(separator: joiner == .and ? " AND " : " OR ")
        guard !expansion.isEmpty else { return base }
        let extra = expansion.map(Self.quote).joined(separator: " OR ")
        return base.isEmpty ? extra : "(" + base + ") OR " + extra
    }
}
