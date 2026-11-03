import Foundation
import NaturalLanguage

/// Язык текста для разбора слов и стоп-слов. Только языки, для которых есть правила; остальные — `.other`.
enum TextLanguage: String, Codable, CaseIterable, Sendable { case zh, en, ru, other }

struct TextSegment: Equatable, Sendable {
    let text: String
    let range: NSRange        // UTF-16 в исходной строке; (text as NSString).substring(with: range) == text
}

/// Предложения и слова через `NLTokenizer`. Все диапазоны — UTF-16 в исходной строке (как у `NSRange` в TextKit).
enum TextSegmentation {
    static func sentences(in text: String, range: NSRange? = nil) -> [TextSegment] {
        tokens(unit: .sentence, in: text, range: range)
    }

    static func words(in text: String, range: NSRange? = nil) -> [TextSegment] {
        tokens(unit: .word, in: text, range: range)
    }

    /// Язык по `NLLanguageRecognizer` без ограничений (иначе французский стал бы одним из четырёх).
    /// Неуверенный результат (вероятность ниже 0,5) и любой язык кроме zh/en/ru дают `.other`.
    static func language(of text: String) -> TextLanguage {
        guard text.rangeOfCharacter(from: .letters) != nil else { return .other }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(5_000)))
        guard let dominant = recognizer.dominantLanguage else { return .other }
        let language: TextLanguage
        switch dominant {
        case .simplifiedChinese, .traditionalChinese: language = .zh
        case .english: language = .en
        case .russian: language = .ru
        default: return .other
        }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        return (hypotheses[dominant] ?? 0) < 0.5 ? .other : language
    }

    static func languageCode(for language: TextLanguage) -> String? {
        switch language {
        case .zh: "zh-CN"
        case .en: "en"
        case .ru: "ru"
        case .other: nil
        }
    }

    private static func tokens(unit: NLTokenUnit, in text: String, range: NSRange?) -> [TextSegment] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let work = range.map { NSIntersectionRange($0, full) } ?? full
        guard work.length > 0, let swiftRange = Range(work, in: text) else { return [] }
        // Строка задаётся целиком, диапазон — параметром: позиции относятся к исходной строке, а не к подстроке.
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.string = text
        let visible = CharacterSet.whitespacesAndNewlines.inverted
        var result: [TextSegment] = []
        tokenizer.enumerateTokens(in: swiftRange) { tokenRange, _ in
            let nsRange = NSRange(tokenRange, in: text)
            if unit == .sentence {
                // NL включает в предложение хвостовые пробелы и переводы строк: обрезаем оба края.
                let first = ns.rangeOfCharacter(from: visible, options: [], range: nsRange)
                guard first.location != NSNotFound else { return true }
                let last = ns.rangeOfCharacter(from: visible, options: .backwards, range: nsRange)
                let trimmed = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                result.append(TextSegment(text: ns.substring(with: trimmed), range: trimmed))
            } else {
                let word = String(text[tokenRange])
                if word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                    result.append(TextSegment(text: word, range: nsRange))
                }
            }
            return true
        }
        return result
    }
}
