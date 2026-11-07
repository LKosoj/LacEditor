import Foundation

/// Виды правок CriticMarkup и типы выносок Obsidian: общие для оформления редактора (`MarkdownPresentationKind`), разбора и вывода HTML.
enum CriticMarkupKind: Equatable, Sendable { case insertion, deletion, substitution, comment, highlight }

/// Тип выноски Obsidian. Канонические типы и синонимы Obsidian; неизвестный тип — `.note` с собственной подписью.
enum MarkdownCalloutKind: String, CaseIterable, Sendable {
    case note, abstract, info, todo, tip, success, question, warning, failure, danger, bug, example, quote

    private static let synonyms: [String: MarkdownCalloutKind] = [
        "summary": .abstract, "tldr": .abstract, "hint": .tip, "important": .tip, "check": .success, "done": .success,
        "help": .question, "faq": .question, "caution": .warning, "attention": .warning, "fail": .failure, "missing": .failure,
        "error": .danger, "cite": .quote
    ]

    /// Синонимы Obsidian (без учёта регистра): summary/tldr → abstract; hint/important → tip; check/done → success;
    /// help/faq → question; caution/attention → warning; fail/missing → failure; error → danger; cite → quote.
    static func kind(forType type: String) -> MarkdownCalloutKind? {
        let key = type.lowercased()
        return MarkdownCalloutKind(rawValue: key) ?? synonyms[key]
    }

    /// Знак (текстовый, с селектором U+FE0E там, где возможна цветная картинка); в HTML всегда `aria-hidden`.
    var symbol: String {
        switch self {
        case .note: "\u{270E}"
        case .abstract: "\u{2261}"
        case .info: "\u{24D8}"
        case .todo: "\u{2610}"
        case .tip: "\u{2726}"
        case .success: "\u{2713}"
        case .question: "?"
        case .warning: "\u{26A0}\u{FE0E}"
        case .failure: "\u{2717}"
        case .danger: "\u{26A1}\u{FE0E}"
        case .bug: "\u{2731}"
        case .example: "\u{25A4}"
        case .quote: "\u{275D}"
        }
    }

    /// Группа цвета: ссылка на уже существующие переменные `--alert-*` (note/info/todo → note; tip/abstract/success → tip;
    /// question/warning → warning; example → important; failure/danger/bug → caution; quote → нейтральная).
    var colorGroup: String {
        switch self {
        case .note, .info, .todo: "note"
        case .tip, .abstract, .success: "tip"
        case .question, .warning: "warning"
        case .example: "important"
        case .failure, .danger, .bug: "caution"
        case .quote: "quote"
        }
    }

    /// Локализованная подпись (L10n.tr, ключи с приставкой `标注·`).
    var label: String {
        switch self {
        case .note: L10n.tr("标注·笔记")
        case .abstract: L10n.tr("标注·摘要")
        case .info: L10n.tr("标注·信息")
        case .todo: L10n.tr("标注·待办")
        case .tip: L10n.tr("标注·技巧")
        case .success: L10n.tr("标注·成功")
        case .question: L10n.tr("标注·疑问")
        case .warning: L10n.tr("标注·警告")
        case .failure: L10n.tr("标注·失败")
        case .danger: L10n.tr("标注·危险")
        case .bug: L10n.tr("标注·缺陷")
        case .example: L10n.tr("标注·示例")
        case .quote: L10n.tr("标注·引文")
        }
    }
}
