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
        static let readingMode = NSToolbarItem.Identifier("LacEditor.ReadingMode")
        static let dictation = NSToolbarItem.Identifier("LacEditor.Dictation")
        static let writerMode = NSToolbarItem.Identifier("LacEditor.WriterMode")
        static let vault = NSToolbarItem.Identifier("LacEditor.Vault")
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
        let dictationState: AIDictationController.State
        let dictationEnabled: Bool
        let dictationToolTip: String
        let writerTitle: String?
        /// Режим хранилища: заголовок «Хранилище › папка», символ состояния связи и подпись для VoiceOver; nil — вкладка обычная.
        let vaultTitle: String?
        let vaultSymbol: String?
        let vaultLabel: String?
    }
    private let titleField = TitlePathField(labelWithString: "LacEditor")
    private let languageButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var sidebarItem: NSToolbarItem?
    private weak var historyItem: NSToolbarItemGroup?
    private weak var previewItem: NSToolbarItem?
    private weak var saveItem: NSToolbarItem?
    private weak var findItem: NSToolbarItem?
    private weak var markdownPresentationItem: NSToolbarItem?
    private weak var readingModeItem: NSToolbarItem?
    private weak var dictationItem: NSToolbarItem?
    private weak var writerModeItem: NSMenuToolbarItem?
    private let writerModeMenu = NSMenu()
    private weak var vaultItem: NSMenuToolbarItem?
    private let vaultMenu = NSMenu()
    private weak var aiWritingItem: NSToolbarItem?
    private weak var exportItem: NSMenuToolbarItem?
    private let exportMenu = NSMenu()
    private let dictationMenu = NSMenu()

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureTitleField()
        configureLanguageButton()
        exportMenu.delegate = self
        dictationMenu.delegate = self
        writerModeMenu.delegate = self
        vaultMenu.delegate = self
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
        addSavedToolbarItem(
            ItemIdentifier.readingMode,
            after: ItemIdentifier.markdownPresentation,
            flag: "LacEditor.ToolbarReadingModeAdded"
        )
        addSavedToolbarItem(
            ItemIdentifier.dictation,
            after: ItemIdentifier.readingMode,
            flag: "LacEditor.ToolbarDictationAdded"
        )
        addSavedToolbarItem(
            ItemIdentifier.writerMode,
            after: ItemIdentifier.dictation,
            flag: "LacEditor.ToolbarWriterModeAdded"
        )
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

    /// Элемент мог появиться после последнего update(), например из палитры настройки панели.
    private func refreshAfterItemCreation() {
        lastPresentation = nil
        DispatchQueue.main.async { [weak self] in self?.update() }
    }

    func update(appState: AppState? = nil) {
        if let appState {
            self.appState = appState
        }
        guard let appState = self.appState else { return }

        let document = appState.selectedDocument
        let manager = appState.hostWindow?.firstResponder?.undoManager
        let dictation = appState.aiDictation
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
            readingMode: document?.isReadingMode == true,
            dictationState: dictation.state,
            dictationEnabled: dictation.isButtonEnabled,
            dictationToolTip: dictation.buttonToolTip,
            writerTitle: appState.writerWindowTitlePrefix,
            vaultTitle: appState.vaultTitlePrefix,
            vaultSymbol: appState.vaultSession?.status.symbolName,
            vaultLabel: appState.vaultTabAccessibilityLabel
        )
        guard presentation != lastPresentation else { return }
        // Items are materialized after makeToolbar returns. Do not cache an
        // unrendered presentation or the first real update would be skipped.
        if previewItem != nil { lastPresentation = presentation }
        titleField.stringValue = presentation.writerTitle.map { "\($0) › \(presentation.title)" }
            ?? presentation.vaultTitle.map { "\($0) › \(presentation.title)" } ?? presentation.title
        titleField.toolTip = document?.url?.path ?? L10n.tr("未命名文档")
        titleField.pathURL = document?.url
        if let window = appState.hostWindow {
            if window.title != appState.windowTitle { window.title = appState.windowTitle }
            if window.tab.title != presentation.title { window.tab.title = presentation.title }
            // Значок пера у вкладки писательского режима; заголовок вкладки остаётся именем документа.
            if let writerTitle = presentation.writerTitle {
                let label = L10n.tr("写作模式：%@", writerTitle)
                if let view = window.tab.accessoryView {
                    // Название проекта могло смениться: обновляем подпись.
                    if view.accessibilityLabel() != label { view.setAccessibilityLabel(label) }
                } else {
                    window.tab.accessoryView = WriterTabAccessory.make(projectTitle: writerTitle)
                }
            } else if let symbol = presentation.vaultSymbol, let label = presentation.vaultLabel, presentation.vaultTitle != nil {
                // Значок облака у вкладки заметки хранилища; форма значка и подпись VoiceOver отражают состояние связи.
                if let view = window.tab.accessoryView as? NSImageView, view.identifier == VaultTabAccessory.identifier {
                    VaultTabAccessory.update(view, symbol: symbol, label: label)
                } else {
                    window.tab.accessoryView = VaultTabAccessory.make(symbol: symbol, label: label)
                }
            } else if window.tab.accessoryView != nil {
                window.tab.accessoryView = nil
            }
            if window.isDocumentEdited != presentation.dirty { window.isDocumentEdited = presentation.dirty }
            if window.representedURL != presentation.url { window.representedURL = presentation.url }
        }
        undoItem?.isEnabled = presentation.canUndo
        redoItem?.isEnabled = presentation.canRedo
        saveItem?.isEnabled = document != nil
        findItem?.isEnabled = document != nil
        readingModeItem?.isEnabled = document != nil
        dictationItem?.isEnabled = presentation.dictationEnabled
        dictationItem?.image = NSImage(
            systemSymbolName: dictation.buttonSymbol,
            accessibilityDescription: dictation.buttonAccessibility
        )
        dictationItem?.toolTip = presentation.dictationToolTip
        writerModeItem?.image = NSImage(
            systemSymbolName: presentation.writerTitle == nil ? "pencil.and.outline" : "pencil.circle.fill",
            accessibilityDescription: L10n.tr("写作模式")
        )
        // Без действия клик по кнопке открывает меню (выход и закрытие проекта).
        writerModeItem?.action = presentation.writerTitle == nil ? #selector(toggleWriterMode) : nil
        writerModeItem?.toolTip = presentation.writerTitle == nil
            ? L10n.tr("写作模式")
            : L10n.tr("写作模式：%@", presentation.writerTitle ?? "")
        let vaultName = appState.vaultSession.map { L10n.tr("笔记库“%@”", $0.connection.name) } ?? L10n.tr("笔记库")
        let vaultSpoken = appState.vaultSession.map { "\(vaultName)：\($0.statusText)" }
        vaultItem?.image = NSImage(systemSymbolName: presentation.vaultSymbol ?? "cloud", accessibilityDescription: vaultSpoken ?? vaultName)
        vaultItem?.toolTip = vaultSpoken ?? L10n.tr("笔记库")
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
        markdownPresentationItem?.isEnabled = document.language == .markdown
        let presentationTip = document.isMarkdownFormatted
            ? L10n.tr("显示 Markdown 源码")
            : L10n.tr("显示格式化文本")
        markdownPresentationItem?.image = NSImage(
            systemSymbolName: document.isMarkdownFormatted ? "chevron.left.forwardslash.chevron.right" : "textformat",
            accessibilityDescription: presentationTip
        )
        markdownPresentationItem?.toolTip = presentationTip
        readingModeItem?.image = NSImage(
            systemSymbolName: document.isReadingMode ? "book.fill" : "book",
            accessibilityDescription: L10n.tr("阅读模式")
        )
        readingModeItem?.toolTip = document.isReadingMode
            ? L10n.tr("退出阅读模式（⌥⌘R）")
            : L10n.tr("进入阅读模式（⌥⌘R）")
        aiWritingItem?.image = NSImage(
            systemSymbolName: appState.isAIWritingVisible ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack",
            accessibilityDescription: L10n.tr("显示或隐藏检查器（⌥⌘0）")
        )
        aiWritingItem?.toolTip = L10n.tr("显示或隐藏检查器（⌥⌘0）")
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
            ItemIdentifier.readingMode,
            ItemIdentifier.dictation,
            ItemIdentifier.writerMode,
            ItemIdentifier.vault,
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
            ItemIdentifier.readingMode,
            ItemIdentifier.dictation,
            ItemIdentifier.writerMode,
            ItemIdentifier.vault,
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
                label: L10n.tr("检查器"),
                symbol: "sparkles.rectangle.stack",
                toolTip: L10n.tr("显示或隐藏检查器（⌥⌘0）"),
                action: #selector(toggleAIWriting)
            )
            aiWritingItem = item
            return item
        case ItemIdentifier.markdownPresentation:
            return makeMarkdownPresentationItem()
        case ItemIdentifier.readingMode:
            let item = makeActionItem(
                identifier: itemIdentifier,
                label: L10n.tr("阅读模式"),
                symbol: "book",
                toolTip: L10n.tr("进入阅读模式（⌥⌘R）"),
                action: #selector(toggleReadingMode)
            )
            item.autovalidates = false
            readingModeItem = item
            refreshAfterItemCreation()
            return item
        case ItemIdentifier.dictation:
            // Значок запускает запись, стрелка открывает меню последних диктовок.
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = AIFeature.voiceDraft.title
            item.paletteLabel = AIFeature.voiceDraft.title
            item.image = NSImage(
                systemSymbolName: "mic",
                accessibilityDescription: AIFeature.voiceDraft.title
            )
            item.toolTip = AIFeature.voiceDraft.title
            item.target = self
            item.action = #selector(toggleDictation)
            item.menu = dictationMenu
            item.showsIndicator = true
            item.autovalidates = false
            rebuildDictationMenu()
            dictationItem = item
            refreshAfterItemCreation()
            return item
        case ItemIdentifier.writerMode:
            // Значок включает или выключает режим, стрелка открывает меню проекта.
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.tr("写作模式")
            item.paletteLabel = L10n.tr("写作模式")
            item.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: L10n.tr("写作模式"))
            item.toolTip = L10n.tr("写作模式")
            item.target = self
            item.action = #selector(toggleWriterMode)
            item.menu = writerModeMenu
            item.showsIndicator = true
            item.autovalidates = false
            writerModeItem = item
            refreshAfterItemCreation()
            return item
        case ItemIdentifier.vault:
            // Без действия клик по кнопке открывает меню: подключение, «Сегодня», проверка, закрытие.
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = L10n.tr("笔记库")
            item.paletteLabel = L10n.tr("笔记库")
            item.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: L10n.tr("笔记库"))
            item.toolTip = L10n.tr("笔记库")
            item.menu = vaultMenu
            item.showsIndicator = true
            item.autovalidates = false
            vaultItem = item
            refreshAfterItemCreation()
            return item
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

    /// Один раз добавляет новую кнопку в уже сохранённую пользователем конфигурацию панели.
    /// Пометка `flag` хранится в UserDefaults, поэтому убранную пользователем кнопку повторно не возвращаем.
    func addSavedToolbarItem(
        _ item: NSToolbarItem.Identifier,
        after anchor: NSToolbarItem.Identifier,
        flag: String,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        let key = "NSToolbar Configuration LacEditor.EditorToolbar"
        guard var configuration = defaults.dictionary(forKey: key) else { return }
        var changed = false
        for listKey in ["TB Default Item Identifiers", "TB Item Identifiers"] {
            guard var identifiers = configuration[listKey] as? [String],
                  !identifiers.contains(item.rawValue) else { continue }
            let index = identifiers.firstIndex(of: anchor.rawValue).map { $0 + 1 } ?? identifiers.count
            identifiers.insert(item.rawValue, at: index)
            configuration[listKey] = identifiers
            changed = true
        }
        if changed { defaults.set(configuration, forKey: key) }
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
        if menu === dictationMenu {
            rebuildDictationMenu()
            return
        }
        if menu === writerModeMenu {
            rebuildWriterModeMenu()
            return
        }
        if menu === vaultMenu {
            rebuildVaultMenu()
            return
        }
        guard menu === exportMenu else { return }
        rebuildExportMenu()
    }

    private func rebuildExportMenu() {
        exportMenu.removeAllItems()
        addExportItem(title: "HTML", action: #selector(exportHTML))
        addExportItem(title: L10n.tr("HTML（无样式）"), action: #selector(exportPlainHTML))
        addExportItem(title: "PDF", action: #selector(exportPDF))
        addExportItem(title: "PNG", action: #selector(exportPNG))
        addExportItem(title: L10n.tr("Fountain 剧本…"), action: #selector(exportFountain))

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

    private func rebuildWriterModeMenu() {
        writerModeMenu.removeAllItems()
        if appState?.writerSession == nil {
            addWriterMenuItem(title: L10n.tr("写作模式"), action: #selector(toggleWriterMode))
        } else {
            addWriterMenuItem(title: L10n.tr("退出写作模式"), action: #selector(exitWriterMode))
            addWriterMenuItem(title: L10n.tr("关闭项目"), action: #selector(closeWriterProject))
            writerModeMenu.addItem(.separator())
            addWriterMenuItem(title: L10n.tr("制作快照…"), action: #selector(makeWriterSnapshot))
            writerModeMenu.items.last?.isEnabled = appState?.canMakeSnapshot == true
            addWriterMenuItem(title: L10n.tr("导图…"), action: #selector(openMindMap))
            writerModeMenu.items.last?.isEnabled = appState?.mindMapUnavailableReason(for: .document) == nil
        }
        // Доступность пунктов задаём сами, без автопроверки по цели.
        writerModeMenu.autoenablesItems = false
    }

    private func rebuildVaultMenu() {
        vaultMenu.removeAllItems()
        vaultMenu.autoenablesItems = false
        let manager = appState?.windowManager
        if appState?.vaultSession != nil {
            addVaultMenuItem(title: L10n.tr("打开“今天”"), action: #selector(openVaultToday))
            addVaultMenuItem(title: L10n.tr("记录想法…"), action: #selector(openVaultCapture))
            vaultMenu.addItem(.separator())
            addVaultMenuItem(title: L10n.tr("立即检查更新"), action: #selector(checkVaultNow))
            vaultMenu.addItem(.separator())
            addVaultMenuItem(title: L10n.tr("笔记库设置…"), action: #selector(openVaultSettings))
            addVaultMenuItem(title: L10n.tr("关闭笔记库"), action: #selector(closeVault))
        } else if let active = manager?.activeVaultSession {
            // Сессия уже идёт (другая вкладка): эта вкладка присоединяется к ней.
            addVaultMenuItem(title: L10n.tr("在此标签页打开笔记库“%@”", active.connection.name), action: #selector(joinActiveVault))
            addVaultMenuItem(title: L10n.tr("关闭笔记库"), action: #selector(closeVault))
        } else {
            for connection in VaultConnectionStore.shared.connections {
                let item = NSMenuItem(title: connection.name, action: #selector(connectVault(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = connection.id
                vaultMenu.addItem(item)
            }
            if !VaultConnectionStore.shared.connections.isEmpty { vaultMenu.addItem(.separator()) }
            addVaultMenuItem(title: L10n.tr("连接笔记库…"), action: #selector(newVaultConnection))
        }
    }

    private func addVaultMenuItem(title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        vaultMenu.addItem(item)
    }

    @objc private func openVaultToday() { appState?.windowManager?.openVaultDailyNote(from: appState) }
    @objc private func openVaultCapture() { appState?.presentVaultCapture() }
    @objc private func checkVaultNow() { appState?.checkVaultNow() }
    @objc private func openVaultSettings() {
        guard let appState, let id = appState.vaultSession?.connection.id else { return }
        appState.presentVaultConnectionSheet(preselectedID: id)
    }
    @objc private func closeVault() {
        guard let manager = appState?.windowManager else { return }
        Task { @MainActor in await manager.leaveVault() }
    }
    @objc private func joinActiveVault() {
        guard let appState, let manager = appState.windowManager, let session = manager.activeVaultSession else { return }
        manager.attachVault(session, to: appState)
        appState.isSidebarVisible = true
    }
    @objc private func connectVault(_ sender: NSMenuItem) {
        guard let appState, let id = sender.representedObject as? UUID,
              let connection = VaultConnectionStore.shared.connections.first(where: { $0.id == id }) else { return }
        appState.windowManager?.enterVault(connection, from: appState)
    }
    @objc private func newVaultConnection() { appState?.presentVaultConnectionSheet() }

    private func addWriterMenuItem(title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        writerModeMenu.addItem(item)
    }

    @objc private func toggleWriterMode() {
        guard let appState else { return }
        // В писательской вкладке клик только открывает меню (выход — пункт меню), поэтому действие здесь лишь включает режим.
        if appState.writerSession == nil { appState.enableWriterMode() }
    }

    @objc private func exitWriterMode() {
        appState?.exitWriterMode()
    }

    @objc private func makeWriterSnapshot() {
        appState?.makeSnapshot()
    }

    @objc private func openMindMap() {
        appState?.presentMindMap(kind: .document)
    }

    @objc private func closeWriterProject() {
        appState?.closeWriterProject()
    }

    private func rebuildDictationMenu() {
        dictationMenu.removeAllItems()
        let parent = NSMenuItem(title: L10n.tr("最近的听写"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let entries = appState?.aiDictation.history.recent() ?? []
        if entries.isEmpty {
            let empty = NSMenuItem(title: L10n.tr("暂无听写"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for entry in entries {
            let item = NSMenuItem(title: Self.dictationMenuTitle(entry), action: nil, keyEquivalent: "")
            let choices = NSMenu()
            choices.autoenablesItems = false
            let cleaned = NSMenuItem(
                title: L10n.tr("插入整理后的文字"),
                action: #selector(insertDictationFromHistory(_:)),
                keyEquivalent: ""
            )
            cleaned.target = self
            cleaned.representedObject = DictationHistoryChoice(id: entry.id, variant: .cleaned)
            cleaned.isEnabled = entry.cleanedText != nil
            let raw = NSMenuItem(
                title: L10n.tr("插入原始识别文字"),
                action: #selector(insertDictationFromHistory(_:)),
                keyEquivalent: ""
            )
            raw.target = self
            raw.representedObject = DictationHistoryChoice(id: entry.id, variant: .raw)
            choices.addItem(cleaned)
            choices.addItem(raw)
            item.submenu = choices
            submenu.addItem(item)
        }
        parent.submenu = submenu
        dictationMenu.addItem(parent)
    }

    /// «Дата и время · первые 40 знаков» (очищенный текст, иначе исходный; переводы строк заменены пробелами).
    private static func dictationMenuTitle(_ entry: DictationHistoryEntry) -> String {
        let source = (entry.cleanedText ?? entry.rawText).split(whereSeparator: \.isNewline).joined(separator: " ")
        let preview = source.count > 40 ? String(source.prefix(40)) + "…" : source
        return "\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(preview)"
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

    @objc private func exportFountain() {
        appState?.presentFountainExport(scope: .document)
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

    @objc private func toggleReadingMode() {
        appState?.toggleReadingMode()
        update()
    }

    @objc private func toggleDictation() {
        appState?.aiDictation.toggle()
    }

    @objc private func insertDictationFromHistory(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DictationHistoryChoice else { return }
        appState?.aiDictation.insertFromHistory(id: choice.id, variant: choice.variant)
    }

    @objc private func toggleMarkdownPresentation() {
        guard let document = appState?.selectedDocument,
              document.language == .markdown else { return }
        if document.isReadingMode {
            appState?.exitReadingModeToSource()
        } else {
            document.isMarkdownFormatted.toggle()
        }
        update()
    }
}

/// Что вставить из истории диктовок; хранится в `representedObject` пункта меню.
private struct DictationHistoryChoice {
    let id: UUID
    let variant: AIDictationController.HistoryVariant
}

private final class EditorWindowToolbar: NSToolbar {
    var controller: EditorWindowToolbarController?
}

@MainActor
// Defensive fix: always ensure toolbar is assigned before showing/manipulation (prevents nil toolbar error).
func configureEditorWindowToolbar(_ window: NSWindow, appState: AppState) {
    // Ensure toolbar is not nil before showing/manipulation
    if window.toolbar == nil {
        let controller = EditorWindowToolbarController(appState: appState)
        let toolbar = controller.makeToolbar()
        window.toolbar = toolbar
        controller.update()
        DispatchQueue.main.async {
            localizeNativeToolbarItems(in: toolbar)
        }
        return
    }

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
