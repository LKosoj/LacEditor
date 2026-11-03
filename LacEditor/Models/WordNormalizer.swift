import Foundation

/// Приведение слова к сравнимому виду: регистр, диакритика, основа (стемминг).
enum WordNormalizer {
    /// Стеммер не идемпотентен (основа основы может отличаться), поэтому нормализовать результат повторно нельзя.
    static func normalize(_ word: String, language: TextLanguage) -> String {
        switch language {
        case .en:
            let lower = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            let isPlain = lower.unicodeScalars.allSatisfy { ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "'" }
            return isPlain ? SnowballEnglishStemmer.stem(lower) : lower
        case .ru:
            let lower = word.lowercased().replacingOccurrences(of: "ё", with: "е")
            let isPlain = lower.unicodeScalars.allSatisfy { $0.value >= 0x430 && $0.value <= 0x44F }
            return isPlain ? SnowballRussianStemmer.stem(lower) : lower
        case .zh:
            return word.lowercased()
        case .other:
            return word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        }
    }
}
