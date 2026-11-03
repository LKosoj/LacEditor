import Foundation
import NaturalLanguage

/// Кандидат в карточку: имя, найденное в тексте, но ещё не заведённое как карточка.
struct StoryCardCandidate: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var type: StoryCardType
    var occurrences: Int
    /// Короткая цитата из текста, где имя встретилось.
    var quote: String
    var fromAI: Bool
}

/// Поиск кандидатов без AI: NLTagger (имена людей, места, организации), а без него — слова с заглавной буквы.
enum StoryCardCandidateFinder {
    static let minOccurrences = 3

    static func find(in text: String, known: [StoryCard]) -> [StoryCardCandidate] {
        let matcher = StoryCardMatcher(cards: known)
        let knownNames = Set(known.flatMap(\.allNames).map { $0.lowercased() })
        let ns = text as NSString
        var found: [String: (type: StoryCardType, count: Int, first: NSRange)] = [:]
        // Один разборщик и один разбор слов/предложений на весь документ, а не на каждый абзац.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let fallback = Fallback(text: text)
        for prose in StoryCardText.proseRanges(in: text) {
            for item in names(in: text, ns: ns, range: prose, tagger: tagger, fallback: fallback) {
                let name = ns.substring(with: item.range)
                guard !knownNames.contains(name.lowercased()), matcher.mentions(in: name).isEmpty else { continue }
                // Формы одного слова («Zorgon», «Zorgon's») считаются вместе: ключ — нормализованная основа.
                let key = SearchTextNormalizer.terms(in: name).joined(separator: " ")
                let groupKey = key.isEmpty ? name.lowercased() : key
                if var entry = found[groupKey] {
                    entry.count += 1
                    found[groupKey] = entry
                } else {
                    found[groupKey] = (item.type, 1, item.range)
                }
            }
        }
        return found.values
            .filter { $0.count >= minOccurrences }
            .map { entry in
                StoryCardCandidate(name: ns.substring(with: entry.first), type: entry.type, occurrences: entry.count,
                                   quote: quote(around: entry.first, in: ns), fromAI: false)
            }
            .sorted { $0.occurrences != $1.occurrences ? $0.occurrences > $1.occurrences : $0.name < $1.name }
    }

    /// Слова и начала предложений всего текста: считаются один раз, дальше только отбор по диапазону абзаца.
    private final class Fallback {
        let words: [(text: String, range: NSRange)]
        let sentenceStarts: Set<Int>

        init(text: String) {
            words = TextSegmentation.words(in: text).map { ($0.text, $0.range) }
            sentenceStarts = Set(TextSegmentation.sentences(in: text).compactMap { sentence in
                TextSegmentation.words(in: text, range: sentence.range).first?.range.location
            })
        }
    }

    private static func names(in text: String, ns: NSString, range: NSRange, tagger: NLTagger,
                              fallback: Fallback) -> [(range: NSRange, type: StoryCardType)] {
        // Китайский локально не разбирается: имена в нём ищет AI (см. план этапа 9).
        if TextSegmentation.language(of: ns.substring(with: range)) == .zh { return [] }
        var result: [(range: NSRange, type: StoryCardType)] = []
        guard let swiftRange = Range(range, in: text) else { return [] }
        var tagged = false
        tagger.enumerateTags(in: swiftRange, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, tokenRange in
            if let tag {
                let type: StoryCardType? = switch tag {
                case .personalName: .character
                case .placeName: .place
                case .organizationName: .organization
                default: nil
                }
                if let type { tagged = true; result.append((range: NSRange(tokenRange, in: text), type: type)) }
            }
            return true
        }
        if tagged { return result.filter { isPlausible(ns.substring(with: $0.range)) } }
        return capitalizedWords(ns: ns, range: range, fallback: fallback)
    }

    /// Запасной путь: слово с заглавной буквы не в начале предложения.
    private static func capitalizedWords(ns: NSString, range: NSRange, fallback: Fallback) -> [(range: NSRange, type: StoryCardType)] {
        var result: [(range: NSRange, type: StoryCardType)] = []
        for word in fallback.words where NSLocationInRange(word.range.location, range) && NSMaxRange(word.range) <= NSMaxRange(range) {
            guard word.text.first?.isUppercase == true, !fallback.sentenceStarts.contains(word.range.location),
                  isPlausible(word.text) else { continue }
            result.append((range: word.range, type: .character))
        }
        return result
    }

    private static func isPlausible(_ name: String) -> Bool {
        guard name.count >= 2, name.first?.isUppercase == true else { return false }
        guard let term = SearchTextNormalizer.term(for: name) else { return false }
        return !StopWords.contains(term, language: SearchTextNormalizer.scriptLanguage(of: name))
    }

    private static func quote(around range: NSRange, in ns: NSString) -> String {
        let start = max(0, range.location - 40)
        let end = min(ns.length, NSMaxRange(range) + 40)
        let slice = NSRange(location: start, length: end - start)
        let adjusted = ns.rangeOfComposedCharacterSequences(for: slice)
        return ns.substring(with: adjusted).replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
