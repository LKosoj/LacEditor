import AppKit

/// Три переключателя режима правок для панели сохранения.
@MainActor
final class CriticMarkupExportAccessory: NSObject {
    static let defaultsKey = "criticExportMode"

    let view: NSView
    private(set) var mode: CriticMarkupExportMode

    /// Последний выбор пользователя; по умолчанию чистая версия.
    static func lastChoice() -> CriticMarkupExportMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CriticMarkupExportMode.init(rawValue:)) ?? .clean
    }

    init(formatSupportsTracked: Bool) {
        let stack = NSStackView()
        view = stack
        mode = Self.lastChoice()
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let heading = L10n.tr("修订导出")
        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(title)
        let titles: [CriticMarkupExportMode: String] = [
            .clean: L10n.tr("干净版本（接受所有修订）"),
            .original: L10n.tr("原文（拒绝所有修订）"),
            .tracked: L10n.tr("带修订（Word 修订与批注）")
        ]
        for (index, option) in CriticMarkupExportMode.allCases.enumerated() {
            let optionTitle = titles[option] ?? option.rawValue
            let button = NSButton(radioButtonWithTitle: optionTitle, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.state = option == mode ? .on : .off
            stack.addArrangedSubview(button)
            if option == .tracked, !formatSupportsTracked {
                let warning = L10n.tr("此格式不支持修订，将保留原始标记")
                let note = NSTextField(labelWithString: warning)
                note.font = NSFont.preferredFont(forTextStyle: .subheadline)
                note.textColor = .secondaryLabelColor
                stack.addArrangedSubview(note)
                button.setAccessibilityLabel(optionTitle + ". " + warning)
            } else {
                button.setAccessibilityLabel(optionTitle)
            }
        }
        stack.setAccessibilityRole(.radioGroup)
        stack.setAccessibilityLabel(heading)
        stack.setFrameSize(stack.fittingSize)
    }

    @objc private func choose(_ sender: NSButton) {
        guard CriticMarkupExportMode.allCases.indices.contains(sender.tag) else { return }
        mode = CriticMarkupExportMode.allCases[sender.tag]
        UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}
