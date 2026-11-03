import AppKit

extension AppState {
    /// Переключатель режима правок в панели сохранения; nil, если в тексте документа нет CriticMarkup.
    func criticExportAccessory(for document: EditorDocument, panel: NSSavePanel, formatSupportsTracked: Bool) -> CriticMarkupExportAccessory? {
        guard CriticMarkupPandoc.hasMarkup(in: document.text, syntax: preferences.markdownSyntax) else { return nil }
        let accessory = CriticMarkupExportAccessory(formatSupportsTracked: formatSupportsTracked)
        panel.accessoryView = accessory.view
        return accessory
    }
}
