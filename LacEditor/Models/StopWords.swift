import Foundation

/// Стоп-слова: частые служебные слова, которые не считаются содержательными (повторы, статистика).
enum StopWords {
    /// `normalizedWord` — уже нормализованное слово (`WordNormalizer.normalize`). Для `.other` всегда `false`.
    static func contains(_ normalizedWord: String, language: TextLanguage) -> Bool {
        sets[language]?.contains(normalizedWord) ?? false
    }

    // Набор строится из слов списка, прогнанных через ту же нормализацию, что и слова текста: основа «был» и слово из списка совпадают.
    private static let sets: [TextLanguage: Set<String>] = [
        .en: Set(StopWordLists.en.map { WordNormalizer.normalize($0, language: .en) }),
        .ru: Set(StopWordLists.ru.map { WordNormalizer.normalize($0, language: .ru) }),
        .zh: Set(StopWordLists.zh.map { WordNormalizer.normalize($0, language: .zh) })
    ]
}
