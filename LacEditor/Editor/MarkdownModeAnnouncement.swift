import SwiftUI

/// Объявление VoiceOver при явном переключении «исходник ↔ оформленный текст» (кнопка, меню, команда блока).
/// Смена вкладки, открытие файла и восстановление сессии не объявляются: туда эта функция не вызывается.
enum MarkdownModeAnnouncement {
    static func text(formatted: Bool) -> String {
        formatted ? L10n.tr("已切换到格式化文本") : L10n.tr("已切换到 Markdown 源码")
    }

    static func systemAnnounce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// `announce` по умолчанию — система; тесты подставляют свой приёмник.
    static func post(formatted: Bool, announce: (String) -> Void = MarkdownModeAnnouncement.systemAnnounce) {
        announce(text(formatted: formatted))
    }
}
