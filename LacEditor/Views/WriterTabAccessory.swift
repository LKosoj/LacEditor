import AppKit

/// Значок пера в заголовке вкладки писательского режима (`NSWindowTab.accessoryView`).
enum WriterTabAccessory {
    @MainActor
    static func make(projectTitle: String) -> NSView {
        let label = L10n.tr("写作模式：%@", projectTitle)
        let image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: label)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.imageScaling = .scaleProportionallyDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 14),
            view.heightAnchor.constraint(equalToConstant: 14)
        ])
        view.setAccessibilityLabel(label)
        return view
    }
}
