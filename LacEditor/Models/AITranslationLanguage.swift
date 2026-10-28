import Foundation

enum AITranslationLanguage: String, CaseIterable, Identifiable {
    case english, russian, simplifiedChinese, traditionalChinese, german, french, spanish, portuguese, italian, ukrainian, japanese, korean, arabic, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: L10n.tr("英语")
        case .russian: L10n.tr("俄语")
        case .simplifiedChinese: L10n.tr("简体中文")
        case .traditionalChinese: L10n.tr("繁体中文")
        case .german: L10n.tr("德语")
        case .french: L10n.tr("法语")
        case .spanish: L10n.tr("西班牙语")
        case .portuguese: L10n.tr("葡萄牙语")
        case .italian: L10n.tr("意大利语")
        case .ukrainian: L10n.tr("乌克兰语")
        case .japanese: L10n.tr("日语")
        case .korean: L10n.tr("韩语")
        case .arabic: L10n.tr("阿拉伯语")
        case .custom: L10n.tr("其他语言")
        }
    }

    func targetName(customName: String) -> String {
        switch self {
        case .english: "English"
        case .russian: "Russian"
        case .simplifiedChinese: "Simplified Chinese"
        case .traditionalChinese: "Traditional Chinese"
        case .german: "German"
        case .french: "French"
        case .spanish: "Spanish"
        case .portuguese: "Portuguese"
        case .italian: "Italian"
        case .ukrainian: "Ukrainian"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .arabic: "Arabic"
        case .custom: customName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
