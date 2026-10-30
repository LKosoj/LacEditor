import AppKit
import Combine

/// Components for the title's path menu: the file first, then each parent up to the volume root (same order as the standard proxy-icon menu).
enum TitlePathMenu {
    static func components(for url: URL?) -> [URL] {
        guard let url, url.isFileURL else { return [] }
        var result: [URL] = []
        var current = url.standardizedFileURL
        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == "/" { break }
            current = parent
        }
        return result
    }
}

/// The window title is hidden, so the system proxy-icon menu is not drawn; Cmd-click or right-click on the title shows the path instead.
@MainActor
final class TitlePathField: NSTextField {
    var pathURL: URL?

    private func pathMenu() -> NSMenu? {
        let urls = TitlePathMenu.components(for: pathURL)
        guard !urls.isEmpty else { return nil }
        let menu = NSMenu()
        for url in urls {
            let item = NSMenuItem(
                title: FileManager.default.displayName(atPath: url.path),
                action: #selector(revealPathItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? { pathMenu() ?? super.menu(for: event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let menu = pathMenu() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc private func revealPathItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Owns the editor window's toolbar as a native AppKit toolbar. Keeping all
/// titlebar controls in one toolbar lets macOS provide a single active/inactive
/// surface and align the sidebar boundary with the split view divider.
@MainActor
final class EditorWindowToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private enum ItemIdentifier {
        static let sidebar = NSToolbarItem.Identifier("LacEditor.Sidebar")
        static let title = NSToolbarItem.Identifier("LacEditor.WindowTitle")
        static let history = NSToolbarItem.Identifier("LacEditor.History")
        static let language = NSToolbarItem.Identifier("LacEditor.Language")
        static let preview = NSToolbarItem.Identifier("LacEditor.Preview")
        static let newDocument = NSToolbarItem.Identifier("LacEditor.NewDocument")
        static let open = NSToolbarItem.Identifier("LacEditor.Open")
        static let save = NSToolbarItem.Identifier("LacEditor.Save")
        static let find = NSToolbarItem.Identifier("LacEditor.Find")
        static let markdownPresentation = NSToolbarItem.Identifier("LacEditor.MarkdownPresentation")
        static let aiWriting = NSToolbarItem.Identifier("LacEditor.AIWriting")
        static let importDocument = NSToolbarItem.Identifier("LacEditor.Import")
        static let export = NSToolbarItem.Identifier("LacEditor.Export")
    }

    private weak var appState: AppState?
    private var stateObservation: AnyCancellable?
    private var updateScheduled = false
    private var lastPresentation: Presentation?
    private weak var undoItem: NSToolbarItem?
    private weak var redoItem: NSToolbarItem?

    private struct Presentation: Equatable {
        let documentID: UUID?
        let url: URL?
        let title: String
        let language: EditorLanguage?
        let sidebar: Bool
        let dirty: Bool
        let preview: Bool
        let markdownFormatted: Bool
        let aiWritingVisible: Bool
        let canUndo: Bool
        let canRedo: Bool
        let readingMode: Bool
    }
    private let titleField = TitlePathField(labelWithString: "LacEditor")
    private let languageButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var sidebarItem: NSToolbarItem?
    private weak var historyItem: NSToolbarItemGroup?
    private weak var previewItem: NSToolbarItem?
    private weak var saveItem: NSToolbarItem?
    private weak var findItem: NSToolbarItem?
    private weak var markdownPresentationItem: NSToolbarItem?
    private weak var aiWritingItem: NSToolbarItem?
    private weak var exportItem: NSMenuToolbarItem?
    private let exportMenu = NSMenu()

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureTitleField()
        configureLanguageButton()
        exportMenu.delegate = self
        stateObservation = appState.objectWillChange.sink { [weak self, weak appState] in
            guard let self, !self.updateScheduled else { return }
            self.updateScheduled = true
            DispatchQueue.main.async {
                self.updateScheduled = false
                guard let appState else { return }
                self.update(appState: appState)
            }
        }
    }

    func makeToolbar() -> NSToolbar {
        migrateSidebarItemIdentifier()
        let toolbar = EditorWindowToolbar(
            identifier: NSToolbar.Identifier("LacEditor.EditorToolbar")
        )
        toolbar.controller = self
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        update()
        return toolbar
    }

    func update(appState: AppState? = nil) {
        if let appState {
            self.appState = appState
        }
        guard let appState = self.appState else { return }

        let document = appState.selectedDocument
        let manager = appState.hostWindow?.firstResponder?.undoManager
        let presentation = Presentation(
            documentID: document?.id,
            url: document?.url,
            title: document?.displayName ?? L10n.tr("未命名"),
            language: document?.language,
            sidebar: appState.isSidebarVisible,
            dirty: document?.isDirty == true,
            preview: document?.isPreviewEffectivelyEnabled == true,
            markdownFormatted: document?.isMarkdownFormatted == true,
            aiWritingVisible: appState.isAIWritingVisible,
            canUndo: manager?.canUndo == true && document?.isReadingMode != true,
            canRedo: manager?.canRedo == true && document?.isReadingMode != true,
            readingMode: document?.isReadingMode == true
        )
        guard presentation != lastPresentation else { return }
        // Items are materialized after makeToolbar returns. Do not cache an
        // unrendered presentation or the first real update would be skipped.
        if previewItem != nil { lastPresentation = presentation }
        titleField.stringValue = presentation.title
        titleField.toolTip = document?.url?.path ?? L10n.tr("未命名文档")
        titleField.pathURL = document?.url
        if let window = appState.hostWindow {
            if window.title != appState.windowTitle { window.title = appState.windowTitle }
            if window.tab.title != presentation.title { window.tab.title = presentation.title }
            if window.isDocumentEdited != presentation.dirty { window.isDocumentEdited = presentation.dirty }
            if window.representedURL != presentation.url { window.representedURL = presentation.url }
        }
        undoItem?.isEnabled = presentation.canUndo
        redoItem?.isEnabled = presentation.canRedo
        saveItem?.isEnabled = document != nil
        findItem?.isEnabled = document != nil
        sidebarItem?.toolTip = appState.isSidebarVisible
            ? L10n.tr("隐藏侧边栏（⌃⌘B）")
            : L10n.tr("显示侧边栏（⌃⌘B）")
        // AppKit synchronizes item insertion/removal across toolbars sharing
        // an identifier. Native isHidden is explicitly local to each instance,
        // so Markdown and code tabs can safely show different controls.
        previewItem?.isHidden = document?.language != .markdown
        markdownPresentationItem?.isHidden = document?.language != .markdown
        exportItem?.isEnabled = document?.language == .markdown

        guard let document = appState.selectedDocument else {
            historyItem?.isEnabled = false
            languageButton.isEnabled = false
            previewItem?.isEnabled = false
            markdownPresentationItem?.isEnabled = false
            return
        }

        historyItem?.isEnabled = true
        languageButton.isEnabled = true
        if let index = EditorLanguage.allCases.firstIndex(of: document.language) {
            languageButton.selectItem(at: index)
        }
        updateLanguageButton(for: document.language)

        previewItem?.isEnabled = document.language == .markdown
        previewItem?.image = NSImage(
            systemSymbolName: document.isPreviewEffectivelyEnabled
                ? "rectangle.split.2x1.fill"
                : "rectangle.split.2x1",
            accessibilityDescription: document.isPreviewEffectivelyEnabled
                ? L10n.tr("隐藏 Markdown 预览")
                : L10n.tr("显示 Markdown 预览")
        )
        previewItem?.toolTip = document.isPreviewEffectivelyEnabled
            ? L10n.tr("隐藏 Markdown 预览（⌥⌘P）")
            : L10n.tr("显示 Markdown 预览（⌥⌘P）")
        markdownPresentationItem?.isEnabled = document.language == .markdown && !document.isReadingMode
        let presentationTip = document.isMarkdownFormatted
            ? L10n.tr("显示 Markdown 源码")
            : L10n.tr("显示格式化文本")
        markdownPresentationItem?.image = NSImage(
            systemSymbolName: document.isMarkdownFormatted ? "chevron.left.forwardslash.chevron.right" : "textformat",
            accessibilityDescription: presentationTip
        )
        markdownPresentationItem?.toolTip = presentationTip
        aiWritingItem?.image = NSImage(
            systemSymbolName: appState.isAIWritingVisible ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack",
            accessibilityDescription: L10n.tr("显示或隐藏 AI 助手")
        )
        aiWritingItem?.toolTip = L10n.tr("显示或隐藏 AI 助手")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            ItemIdentifier.sidebar,
            .sidebarTrackingSeparator,
            ItemIdentifier.title,
            .flexibleSpace,
            ItemIdentifier.find,
            ItemIdentifier.language,
            ItemIdentifier.markdownPresentation,
            ItemIdentifier.preview
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemIdentifier.sidebar,
            .sidebarTrackingSeparator,
            ItemIdentifier.title,
            ItemIdentifier.newDocument,
            ItemIdentifier.open,
            ItemIdentifier.save,
            ItemIdentifier.history,
            ItemIdentifier.find,
            ItemIdentifier.language,
            ItemIdentifier.aiWriting,
            ItemIdentifier.markdownPresentation,
            ItemIdentifier.preview,
            ItemIdentifier.importDocument,
            ItemIdentifier.export,
            .space,
            .flexibleSpace
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemIdentifier.sidebar:
            return makeSidebarItem()
        case ItemIdentifier.title:
            return makeTitleItem()
        case ItemIdentifier.history:
            return makeHistoryItem()
        case ItemIdentifier.language:
            return makeLanguageItem()
        case ItemIdentifier.preview:
            return makePreviewItem()
        case ItemIdentifier.newDocument:
            return makeActionItem(
                identifier: itemIdentifier,
                label: L10n.tr("新建标签页"),
                symbol: "plus.square.on.square",
                toolTip: L10n.tr("新建标签页"),
                action: #selector(newDocument)
            )
        case ItemIdentifier.open:
            return makeActionItem(
                identifier: itemIdentifier,
                label: L10n.tr("打开…"),
                symbol: "folder",
                toolTip: L10n.tr("打开…"),
                action: #selector(openDocument)
            )
        case ItemIdentifier.save:
            let item = makeActionItem(
                identifier: itemIdentifier,
                label: L10n.tr("保存"),
                symbol: "tray.and.arrow.down",
                toolTip: L10n.tr("保存"),
                action: #selector(saveDocument)
            )
            saveItem = item
            return item
        case ItemIdentifier.find:
            let item = makeActionItem(
                identifier: itemIdentifier,
                label: L10n.tr("查找…"),
                symbol: "magnifyingglass",
                toolTip: L10n.tr("查找…"),
                action: #selector(find)
            )
            findItem = item
            return item
        case ItemIdentifier.aiWriting:
            let item = makeActionItem(
                identifier: itemIdentifier,
                label: L10n.tr("AI 写作助手"),
                symbol: "sparkles.rectangle.stack",
                toolTip: L10n.tr("显示或隐藏 AI 助手"),
                action: #selector(toggleAIWriting)
            )
            aiWritingItem = item
            return item
        case ItemIdentifier.markdownPresentation:
            return makeMarkdownPresentationItem()
        case ItemIdentifier.importDocument:
            return makeActionItem(
                identifier: itemIdentifier,
                label: L10n.tr("导入…"),
                symbol: "square.and.arrow.down",
                toolTip: L10n.tr("导入…"),
                action: #selector(importDocument)
            )
        case ItemIdentifier.export:
            return makeExportItem()
        default:
            // AppKit supplies flexible space and the sidebar tracking
            // separator. The latter discovers the native split view and keeps
            // the toolbar boundary aligned while the sidebar is resized.
            return nil
        }
    }

    private func makeSidebarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.sidebar)
        item.label = L10n.tr("侧边栏")
        item.paletteLabel = L10n.tr("侧边栏")
        item.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: L10n.tr("切换侧边栏")
        )
        item.target = self
        item.action = #selector(toggleSidebar)
        item.isNavigational = true
        sidebarItem = item
        return item
    }

    private func migrateSidebarItemIdentifier() {
        let key = "NSToolbar Configuration LacEditor.EditorToolbar"
        guard var configuration = UserDefaults.standard.dictionary(forKey: key) else { return }
        let oldIdentifier = NSToolbarItem.Identifier.toggleSidebar.rawValue
        let newIdentifier = ItemIdentifier.sidebar.rawValue
        var changed = false
        for listKey in ["TB Default Item Identifiers", "TB Item Identifiers"] {
            guard let identifiers = configuration[listKey] as? [String],
                  identifiers.contains(oldIdentifier) else { continue }
            configuration[listKey] = identifiers.map { $0 == oldIdentifier ? newIdentifier : $0 }
            changed = true
        }
        if changed { UserDefaults.standard.set(configuration, forKey: key) }
    }

    private func makeTitleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.title)
        item.label = L10n.tr("文档标题")
        item.view = titleField
        item.visibilityPriority = .high
        return item
    }

    private func makeHistoryItem() -> NSToolbarItem {
        let undoImage = NSImage(
            systemSymbolName: "arrow.uturn.backward",
            accessibilityDescription: L10n.tr("撤销")
        ) ?? NSImage()
        let redoImage = NSImage(
            systemSymbolName: "arrow.uturn.forward",
            accessibilityDescription: L10n.tr("重做")
        ) ?? NSImage()
        let undoItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("LacEditor.Undo"))
        undoItem.label = L10n.tr("撤销")
        undoItem.image = undoImage
        undoItem.target = self
        undoItem.action = #selector(performUndo)
        undoItem.toolTip = L10n.tr("撤销（⌘Z）")
        self.undoItem = undoItem

        let redoItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("LacEditor.Redo"))
        redoItem.label = L10n.tr("重做")
        redoItem.image = redoImage
        redoItem.target = self
        redoItem.action = #selector(performRedo)
        redoItem.toolTip = L10n.tr("重做（⇧⌘Z）")
        self.redoItem = redoItem

        let item = NSToolbarItemGroup(itemIdentifier: ItemIdentifier.history)
        item.subitems = [undoItem, redoItem]
        item.label = L10n.tr("编辑历史")
        item.controlRepresentation = .expanded
        historyItem = item
        return item
    }

    private func makeLanguageItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.language)
        item.label = L10n.tr("语言模式")
        item.view = languageButton
        item.visibilityPriority = .high
        return item
    }

    private func makePreviewItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.preview)
        item.label = L10n.tr("Markdown 预览")
        item.image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: L10n.tr("切换 Markdown 预览")
        )
        item.target = self
        item.action = #selector(togglePreview)
        item.isHidden = appState?.selectedDocument?.language != .markdown
        previewItem = item
        return item
    }

    private func makeMarkdownPresentationItem() -> NSToolbarItem {
        let item = makeActionItem(
            identifier: ItemIdentifier.markdownPresentation,
            label: L10n.tr("Markdown 编辑方式"),
            symbol: "textformat",
            toolTip: L10n.tr("显示格式化文本"),
            action: #selector(toggleMarkdownPresentation)
        )
        item.isHidden = appState?.selectedDocument?.language != .markdown
        markdownPresentationItem = item
        return item
    }

    private func makeExportItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: ItemIdentifier.export)
        item.label = L10n.tr("导出")
        item.paletteLabel = L10n.tr("导出")
        item.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: L10n.tr("导出")
        )
        item.toolTip = L10n.tr("导出")
        item.menu = exportMenu
        item.showsIndicator = true
        item.isEnabled = appState?.selectedDocument?.language == .markdown
        exportItem = item
        rebuildExportMenu()
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === exportMenu else { return }
        rebuildExportMenu()
    }

    private func rebuildExportMenu() {
        exportMenu.removeAllItems()
        addExportItem(title: "HTML", action: #selector(exportHTML))
        addExportItem(title: L10n.tr("HTML（无样式）"), action: #selector(exportPlainHTML))
        addExportItem(title: "PDF", action: #selector(exportPDF))
        addExportItem(title: "PNG", action: #selector(exportPNG))

        let profiles = appState?.preferences.markdownExportConfiguration.profiles.filter(\.enabled) ?? []
        if !profiles.isEmpty {
            exportMenu.addItem(.separator())
            for profile in profiles {
                let item = NSMenuItem(
                    title: profile.name,
                    action: #selector(exportProfile(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profile
                exportMenu.addItem(item)
            }
        }

        exportMenu.addItem(.separator())
        let repeatItem = NSMenuItem(
            title: L10n.tr("使用上次设置导出"),
            action: #selector(repeatExport),
            keyEquivalent: ""
        )
        repeatItem.target = self
        repeatItem.isEnabled = appState?.hasPreviousMarkdownExport == true
        exportMenu.addItem(repeatItem)
    }

    private func addExportItem(title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        exportMenu.addItem(item)
    }

    private func makeActionItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        toolTip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.toolTip = toolTip
        item.target = self
        item.action = action
        return item
    }

    private func configureTitleField() {
        titleField.font = NSFont.preferredFont(forTextStyle: .headline)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        ])
    }

    private func configureLanguageButton() {
        languageButton.bezelStyle = .toolbar
        languageButton.controlSize = .regular
        languageButton.font = NSFont.preferredFont(forTextStyle: .callout)
        languageButton.imagePosition = .imageLeading
        languageButton.target = self
        languageButton.action = #selector(selectLanguage(_:))
        languageButton.toolTip = L10n.tr("语言模式")
        languageButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            languageButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 122),
            languageButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        for language in EditorLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(
                systemSymbolName: language.icon,
                accessibilityDescription: language.displayName
            )
            languageButton.menu?.addItem(item)
        }
    }

    private func updateLanguageButton(for language: EditorLanguage) {
        languageButton.image = NSImage(
            systemSymbolName: language.icon,
            accessibilityDescription: language.displayName
        )
        languageButton.setAccessibilityLabel(L10n.tr("语言模式：%@", String(describing: language.displayName)))
    }

    @objc private func toggleSidebar() {
        appState?.toggleSidebar()
    }

    @objc private func newDocument() {
        appState?.newDocument()
    }

    @objc private func openDocument() {
        appState?.openFiles()
    }

    @objc private func saveDocument() {
        appState?.save()
    }

    @objc private func find() {
        appState?.presentFindReplace(mode: .find)
    }

    @objc private func toggleAIWriting() {
        guard let appState else { return }
        if appState.isDistractionFree { appState.toggleDistractionFree() }
        appState.isAIWritingVisible.toggle()
        update()
    }

    @objc private func importDocument() {
        appState?.importDocument()
    }

    @objc private func exportHTML() {
        appState?.exportMarkdown(as: .html)
    }

    @objc private func exportPlainHTML() {
        appState?.exportMarkdown(as: .htmlPlain)
    }

    @objc private func exportPDF() {
        appState?.exportMarkdown(as: .pdf)
    }

    @objc private func exportPNG() {
        appState?.exportMarkdownImage()
    }

    @objc private func exportProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? MarkdownExportProfile else { return }
        appState?.exportMarkdown(profile: profile)
    }

    @objc private func repeatExport() {
        appState?.repeatMarkdownExport(overwrite: false)
    }

    @objc private func performUndo() {
        guard let documentID = appState?.selectedDocument?.id else { return }
        NotificationCenter.default.post(
            name: EditorCommandNotification.undo,
            object: documentID
        )
    }

    @objc private func performRedo() {
        guard let documentID = appState?.selectedDocument?.id else { return }
        NotificationCenter.default.post(
            name: EditorCommandNotification.redo,
            object: documentID
        )
    }

    @objc private func selectLanguage(_ sender: NSPopUpButton) {
        guard EditorLanguage.allCases.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        appState?.setLanguage(EditorLanguage.allCases[sender.indexOfSelectedItem])
        update()
    }

    @objc private func togglePreview() {
        appState?.togglePreview()
        update()
    }

    @objc private func toggleMarkdownPresentation() {
        guard let document = appState?.selectedDocument,
              document.language == .markdown, !document.isReadingMode else { return }
        document.isMarkdownFormatted.toggle()
        update()
    }
}

private final class EditorWindowToolbar: NSToolbar {
    var controller: EditorWindowToolbarController?
}

@MainActor
func configureEditorWindowToolbar(_ window: NSWindow, appState: AppState) {
    if let toolbar = window.toolbar as? EditorWindowToolbar,
       let controller = toolbar.controller {
        controller.update(appState: appState)
        localizeNativeToolbarItems(in: toolbar)
        return
    }

    let controller = EditorWindowToolbarController(appState: appState)
    let toolbar = controller.makeToolbar()
    window.toolbar = toolbar
    controller.update()
    // AppKit may materialize the system items one run-loop turn after the
    // toolbar is assigned. Normalize them again after that materialization so
    // the accessibility label and tooltip never fall back to English.
    DispatchQueue.main.async {
        localizeNativeToolbarItems(in: toolbar)
    }
}

@MainActor
private func localizeNativeToolbarItems(in toolbar: NSToolbar) {
    for item in toolbar.items {
        guard item.itemIdentifier.rawValue == "LacEditor.Sidebar" else { continue }
        item.label = L10n.tr("侧边栏")
        item.paletteLabel = L10n.tr("侧边栏")
        item.toolTip = L10n.tr("显示或隐藏侧边栏（⌃⌘B）")
        item.view?.setAccessibilityLabel(L10n.tr("侧边栏"))
        item.view?.setAccessibilityHelp(L10n.tr("显示或隐藏侧边栏"))
    }
}
