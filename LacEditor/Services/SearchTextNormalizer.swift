import Foundation

/// Одинаковая нормализация слов для индекса и для запроса: иначе слова не найдутся по формам.
/// Язык определяется по письменности самого слова, а не по файлу, поэтому короткие запросы работают.
enum SearchTextNormalizer {
    /// Иероглифы дают zh, кириллица — ru, слово из одной ASCII-латиницы и цифр — en, остальное — other.
    static func scriptLanguage(of word: String) -> TextLanguage {
        var hasCyrillic = false
        var isASCII = true
        for scalar in word.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: return .zh
            case 0x0400...0x04FF: hasCyrillic = true
            case 0x00...0x7F: break
            default: isASCII = false
            }
        }
        if hasCyrillic { return .ru }
        return isASCII ? .en : .other
    }

    /// Нормализованная форма одного слова; nil, если после нормализации ничего не осталось.
    static func term(for word: String) -> String? {
        let normalized = WordNormalizer.normalize(word, language: scriptLanguage(of: word))
        return normalized.isEmpty ? nil : normalized
    }

    /// Термы текста в порядке появления, с повторами и со стоп-словами (для индекса).
    static func terms(in text: String) -> [String] {
        TextSegmentation.words(in: text).compactMap { term(for: $0.text) }
    }

    /// Термы запроса без повторов; стоп-слова отброшены, если запрос не состоит из них целиком.
    static func queryTerms(_ query: String) -> [String] {
        var all: [String] = []
        var content: [String] = []
        for word in TextSegmentation.words(in: query) {
            let language = scriptLanguage(of: word.text)
            let normalized = WordNormalizer.normalize(word.text, language: language)
            guard !normalized.isEmpty, !all.contains(normalized) else { continue }
            all.append(normalized)
            if !StopWords.contains(normalized, language: language) { content.append(normalized) }
        }
        return content.isEmpty ? all : content
    }
}
