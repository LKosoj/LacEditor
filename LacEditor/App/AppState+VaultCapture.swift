import AppKit
import Foundation

extension AppState {
    /// Из меню «Файл» (⌃⌥⌘N), меню «Хранилище», кнопки «Записать» и палитры команд.
    func presentVaultCapture() {
        vaultCapture.present()
    }

    /// Краткое сообщение о ходе запроса к серверу: строка состояния выбранной вкладки.
    func showVaultStatus(_ text: String, isError: Bool = false) {
        showVaultNotice(text, isError: isError)
    }

    /// Результат сервера открывается несохранённой вкладкой Markdown: на диске Mac следов нет.
    func openVaultArtifactText(_ text: String, name: String) {
        let document = EditorDocument(text: text, language: .markdown, isDirty: true, requiresExplicitSave: true)
        document.statusMessage = name
        guard let manager = windowManager, let window = hostWindow, manager.ownsVisibleState(self, window: window) else { return }
        manager.openNativeTab(from: self, with: document)
    }

    /// Пустое состояние панели: лист подключения; после подключения панель открывается снова.
    func presentVaultConnectionFromCapture() {
        presentVaultConnectionSheet(onConnect: { [weak self] _ in
            // Лист закрывается сам сразу после подключения; панель открываем следом.
            DispatchQueue.main.async { self?.vaultCapture.present() }
        })
    }
}
