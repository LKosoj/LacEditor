import Foundation

/// Страницы хранилища, которые собирает сервер: править можно только раздел «Owner Notes».
extension AppState {
    /// Вызывается после того, как документ получил текст заметки хранилища и до показа редактора.
    /// Для обычных заметок (`serverPath` не `compiled/**/*.md` и не отчёт) охранник не создаётся.
    func attachVaultPageGuard(to document: EditorDocument, serverPath: String) {
        document.setVaultPageGuard(VaultPageGuard.make(serverPath: serverPath, text: NSString(string: document.synchronizedText())))
    }

    /// При «Сохранить как…», закрытии вкладки и смене привязки: файл вне хранилища становится обычным.
    func detachVaultPageGuard(from document: EditorDocument) {
        document.setVaultPageGuard(nil)
    }

    /// Есть ли у выбранной вкладки рабочий раздел «Owner Notes».
    var canGoToOwnerNotes: Bool {
        selectedDocument?.vaultPageMode == .ownerZone
    }

    /// Каретка в конец раздела «Owner Notes», фокус в редакторе. Один полный проход по тексту на нажатие.
    func goToOwnerNotes() {
        guard let document = selectedDocument, document.vaultPageGuard != nil else { return }
        guard case .editable(let zone) = VaultOwnerZone.state(of: document.synchronizedText()) else {
            document.statusMessage = L10n.tr("此页面没有“Owner Notes”分区")
            return
        }
        reveal(NSRange(location: NSMaxRange(zone), length: 0), in: document, focusEditor: true)
    }
}
