import Foundation

struct StoryCardMention: Equatable, Sendable {
    let cardKey: String
    let range: NSRange
}

/// Поиск имён карточек в тексте без AI. Не-CJK имена сравниваются по нормализованным словам (формы слов совпадают),
/// китайские — буквально. Имя с заглавной буквы совпадает только со словом с заглавной («Вера» не равна «вера»).
struct StoryCardMatcher: Sendable {
    private struct Entry: Sendable {
        let cardKey: String
        let order: Int
        let terms: [String]
        let requiresCapital: Bool
    }

    private struct Literal: Sendable {
        let cardKey: String
        let order: Int
        let name: String
    }

    private let byFirstTerm: [String: [Entry]]
    private let literals: [Literal]

    init(cards: [StoryCard]) {
        var words: [String: [Entry]] = [:]
        var literals: [Literal] = []
        var order = 0
        for card in cards {
            var seen = Set<String>()
            for raw in card.allNames {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                order += 1
                if name.unicodeScalars.contains(where: { SearchTextNormalizer.scriptLanguage(of: String($0)) == .zh }) {
                    if name.count >= 2 { literals.append(Literal(cardKey: card.id, order: order, name: name)) }
                    continue
                }
                let segments = TextSegmentation.words(in: name)
                let terms = segments.compactMap { SearchTextNormalizer.term(for: $0.text) }
                guard !terms.isEmpty, terms.count == segments.count else { continue }
                let onlyStopWords = zip(segments, terms).allSatisfy {
                    StopWords.contains($1, language: SearchTextNormalizer.scriptLanguage(of: $0.text))
                }
                guard !onlyStopWords else { continue }
                if terms.count == 1, segments[0].text.count < 2 { continue }
                words[terms[0], default: []].append(Entry(cardKey: card.id, order: order, terms: terms,
                                                         requiresCapital: name.first?.isUppercase == true))
            }
        }
        byFirstTerm = words
        self.literals = literals
    }

    /// Все упоминания карточек в тексте; перекрытия разрешаются в пользу самого длинного совпадения.
    func mentions(in text: String) -> [StoryCardMention] {
        guard !byFirstTerm.isEmpty || !literals.isEmpty else { return [] }
        let ns = text as NSString
        var found: [(mention: StoryCardMention, order: Int)] = []
        for prose in StoryCardText.proseRanges(in: text) {
            if !byFirstTerm.isEmpty { collectWords(in: text, ns: ns, range: prose, into: &found) }
            for literal in literals {
                var search = prose
                while search.length > 0 {
                    let hit = ns.range(of: literal.name, options: [.caseInsensitive], range: search)
                    guard hit.location != NSNotFound else { break }
                    found.append((StoryCardMention(cardKey: literal.cardKey, range: hit), literal.order))
                    search = NSRange(location: NSMaxRange(hit), length: NSMaxRange(prose) - NSMaxRange(hit))
                }
            }
        }
        found.sort {
            if $0.mention.range.location != $1.mention.range.location { return $0.mention.range.location < $1.mention.range.location }
            if $0.mention.range.length != $1.mention.range.length { return $0.mention.range.length > $1.mention.range.length }
            return $0.order < $1.order
        }
        var result: [StoryCardMention] = []
        var end = 0
        for item in found where item.mention.range.location >= end {
            result.append(item.mention)
            end = NSMaxRange(item.mention.range)
        }
        return result
    }

    /// Число упоминаний по карточкам.
    func counts(in text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for mention in mentions(in: text) { result[mention.cardKey, default: 0] += 1 }
        return result
    }

    private struct Token {
        let term: String
        let range: NSRange
        let isCapitalized: Bool
    }

    private func collectWords(in text: String, ns: NSString, range: NSRange, into found: inout [(mention: StoryCardMention, order: Int)]) {
        var tokens: [Token] = []
        for segment in TextSegmentation.words(in: text, range: range) {
            // Китайские слова ищутся буквально, поэтому в словарный проход не входят.
            if SearchTextNormalizer.scriptLanguage(of: segment.text) == .zh { tokens.append(Token(term: "", range: segment.range, isCapitalized: false)); continue }
            tokens.append(Token(term: SearchTextNormalizer.term(for: segment.text) ?? "", range: segment.range,
                                isCapitalized: segment.text.first?.isUppercase == true))
        }
        for index in tokens.indices {
            guard !tokens[index].term.isEmpty, let entries = byFirstTerm[tokens[index].term] else { continue }
            for entry in entries {
                if entry.requiresCapital, !tokens[index].isCapitalized { continue }
                let last = index + entry.terms.count - 1
                guard last < tokens.count else { continue }
                var matches = true
                for offset in 1..<max(1, entry.terms.count) {
                    let token = tokens[index + offset]
                    let previous = tokens[index + offset - 1]
                    let gap = NSRange(location: NSMaxRange(previous.range), length: token.range.location - NSMaxRange(previous.range))
                    guard token.term == entry.terms[offset], Self.isJoiner(ns.substring(with: gap)) else { matches = false; break }
                }
                guard matches else { continue }
                let span = NSRange(location: tokens[index].range.location, length: NSMaxRange(tokens[last].range) - tokens[index].range.location)
                found.append((StoryCardMention(cardKey: entry.cardKey, range: span), entry.order))
            }
        }
    }

    /// Между словами имени допустимы только пробелы, дефис и апостроф (не конец предложения и не перевод строки).
    private static func isJoiner(_ gap: String) -> Bool {
        !gap.isEmpty && gap.unicodeScalars.allSatisfy { " \u{00A0}\t-\u{2010}\u{2011}'\u{2019}".unicodeScalars.contains($0) }
    }
}
