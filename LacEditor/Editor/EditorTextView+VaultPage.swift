import AppKit
import SwiftUI

/// Защита собранных сервером страниц хранилища: печатать можно только в разделе «Owner Notes».
extension EditorTextView.Coordinator {
    /// `true` — правку нужно отклонить. Звук, подсказка и озвучивание подаются не чаще раза в секунду.
    func vaultPageDenies(_ textView: NSTextView, range: NSRange, replacement: String) -> Bool {
        guard let pageGuard = document.vaultPageGuard, let text = textView.textStorage?.mutableString else { return false }
        let decision = pageGuard.decide(range: range, replacement: replacement, in: text)
        guard decision != .allow else { return false }
        giveVaultDenialFeedback(pageGuard, readOnly: decision == .denyReadOnly)
        return true
    }

    /// Для правок мимо делегата (Shift-Tab): `true` — можно менять.
    func vaultAllows(range: NSRange, replacement: String) -> Bool {
        guard document.vaultPageGuard != nil, let textView else { return true }
        return !vaultPageDenies(textView, range: range, replacement: replacement)
    }

    /// Диапазон целиком в разделе владельца (для действий, которые правят текст позже, чем начинаются: ячейка таблицы, вставка файла).
    func vaultAllowsRange(_ range: NSRange) -> Bool {
        guard let pageGuard = document.vaultPageGuard else { return true }
        if let zone = pageGuard.ownerZone, range.location >= zone.location, NSMaxRange(range) <= NSMaxRange(zone) { return true }
        giveVaultDenialFeedback(pageGuard, readOnly: pageGuard.isReadOnly)
        return false
    }

    /// Сообщение для отказа программной замены; `nil`, если страница обычная.
    func vaultPageDenialMessage() -> String? {
        guard let pageGuard = document.vaultPageGuard else { return nil }
        return Self.vaultDenialText(readOnly: pageGuard.isReadOnly)
    }

    private static func vaultDenialText(readOnly: Bool) -> String {
        readOnly ? L10n.tr("此页面不可编辑") : L10n.tr("这里只能编辑“Owner Notes”分区")
    }

    private func giveVaultDenialFeedback(_ pageGuard: VaultPageGuard, readOnly: Bool) {
        guard pageGuard.registerDenial(now: Date()) else { return }
        let text = Self.vaultDenialText(readOnly: readOnly)
        NSSound.beep()
        if document.statusMessage != text { document.statusMessage = text }
        AccessibilityNotification.Announcement(text).post()
    }
}
