import Foundation

/// Категория замечания. Первые пять — локальные правила, остальные — AI.
enum StyleCategory: String, Codable, CaseIterable, Sendable {
    case repeatedWord, repeatedStart, longSentence, customWord, spacing   // правила
    case cliche, bureaucratese, ambiguity, rhythm, tense, other           // AI

    static let ruleCategories: [StyleCategory] = [.repeatedWord, .repeatedStart, .longSentence, .customWord, .spacing]
    static let aiCategories: [StyleCategory] = [.cliche, .bureaucratese, .ambiguity, .rhythm, .tense, .other]

    var source: FindingSource { Self.ruleCategories.contains(self) ? .rule : .ai }

    var title: String {
        switch self {
        case .repeatedWord: L10n.tr("词语重复")
        case .repeatedStart: L10n.tr("句首重复")
        case .longSentence: L10n.tr("长句")
        case .customWord: L10n.tr("自定义词表")
        case .spacing: L10n.tr("空格")
        case .cliche: L10n.tr("套话")
        case .bureaucratese: L10n.tr("官腔")
        case .ambiguity: L10n.tr("歧义")
        case .rhythm: L10n.tr("节奏")
        case .tense: L10n.tr("时态")
        case .other: L10n.tr("其他")
        }
    }

    /// Ответ модели: принимаются только AI-категории по `rawValue` после trim и lowercased, всё остальное даёт `.other`.
    static func ai(from raw: String) -> StyleCategory {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aiCategories.first { $0.rawValue.lowercased() == value } ?? .other
    }
}

/// Одно замечание. Диапазон — UTF-16 в координатах исходника по снимку `revision`.
struct StyleFinding: Identifiable, Equatable, Sendable {
    let id: UUID
    let category: StyleCategory
    var range: NSRange          // меняется только при сдвиге после принятой правки
    let fragment: String        // текст для показа; для AI — цитата
    let explanation: String     // готовая локализованная фраза
    /// Диапазоны, с которыми связано замечание (первое вхождение повторяемого слова, предыдущее начало). Только для показа.
    let related: [NSRange]
    /// Готовая замена без AI (двойной пробел, пробел перед знаком). У остальных локальных — nil.
    let replacement: String?

    var source: FindingSource { category.source }

    init(id: UUID = UUID(), category: StyleCategory, range: NSRange, fragment: String, explanation: String,
         related: [NSRange] = [], replacement: String? = nil) {
        self.id = id
        self.category = category
        self.range = range
        self.fragment = fragment
        self.explanation = explanation
        self.related = related
        self.replacement = replacement
    }
}

/// Результат одного прохода локальных правил.
struct StyleCheckResult: Equatable, Sendable {
    let documentID: UUID
    let revision: UInt                    // DocumentTextSnapshot.revision
    let textLength: Int                   // UTF-16 длина проверенного текста
    let language: TextLanguage            // преобладающий язык (для показа «Авто (русский)»)
    let findings: [StyleFinding]          // по возрастанию range.location
}

extension StyleFinding {
    /// Ключ группировки и пропуска в тестах: категория + положение.
    var key: String { "\(category.rawValue):\(range.location):\(range.length)" }

    /// Сдвиг после замены `replaced`, изменившей длину текста на `delta`.
    /// nil, если замечание пересекается с заменённым диапазоном (вызывающий его удаляет).
    func shifted(after replaced: NSRange, delta: Int) -> StyleFinding? {
        if NSMaxRange(range) <= replaced.location { return self }
        guard range.location >= NSMaxRange(replaced) else { return nil }
        var copy = self
        copy.range = NSRange(location: range.location + delta, length: range.length)
        return StyleFinding(id: id, category: category, range: copy.range, fragment: fragment, explanation: explanation,
                            related: related.map { $0.location >= NSMaxRange(replaced) ? NSRange(location: $0.location + delta, length: $0.length) : $0 },
                            replacement: replacement)
    }
}
