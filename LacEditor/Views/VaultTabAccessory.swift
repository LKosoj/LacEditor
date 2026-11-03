import AppKit

/// Значок облака у вкладки заметки хранилища (`NSWindowTab.accessoryView`); форма значка показывает состояние связи.
enum VaultTabAccessory {
    static let identifier = NSUserInterfaceItemIdentifier("LacEditor.VaultTabAccessory")

    @MainActor
    static func make(symbol: String, label: String) -> NSView {
        let view = NSImageView()
        view.identifier = identifier
        view.contentTintColor = .secondaryLabelColor
        view.imageScaling = .scaleProportionallyDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 14),
            view.heightAnchor.constraint(equalToConstant: 14)
        ])
        update(view, symbol: symbol, label: label)
        return view
    }

    @MainActor
    static func update(_ view: NSImageView, symbol: String, label: String) {
        if view.accessibilityLabel() != label {
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            view.setAccessibilityLabel(label)
        }
    }
}
