import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @StateObject private var editorSessions = EditorSessionStore(
        limit: 3,
        inactiveMemoryBudget: 64 * 1_024 * 1_024,
        maximumCacheableSessionCost: 24 * 1_024 * 1_024
    )

    var body: some View {
        NativeSidebarSplitView(
            appState: appState,
            windowManager: windowManager,
            sidebar: SidebarView(),
            content: editorWorkspace
        )
        // AppKit owns the titlebar safe area inside the split view. Constraining
        // the entire controller below it prevents full-height sidebar material.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .lacEditorBackground))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: openDroppedFiles)
        .onChange(of: appState.documents.map(\.id)) { _, documentIDs in
            editorSessions.retainDocuments(Set(documentIDs))
        }
    }

    @ViewBuilder
    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            FindBarHost(state: appState.findReplace)

            if let selectedDocument = appState.selectedDocument {
                HSplitView {
                DocumentEditorPane(
                    document: selectedDocument,
                    sessionStore: editorSessions,
                    fontSize: appState.editorFontSize,
                    lineSpacing: appState.editorLineSpacing,
                    indentationStyle: appState.indentationStyle,
                    tabWidth: appState.tabWidth,
                    wordWrap: selectedDocument.effectiveWordWrap(
                        globalDefault: appState.isWordWrapEnabled
                    ),
                    showsLineNumbers: appState.isLineNumbersVisible && !appState.isDistractionFree,
                    editorTopInset: 12,
                    darkMode: colorScheme == .dark
                )
                .id(selectedDocument.id)
                .animation(nil, value: appState.selectedDocumentID)
                .overlay {
                    if !appState.isDistractionFree && !selectedDocument.isPreviewEffectivelyEnabled { EditorStartHints(document: selectedDocument) }
                }
                if appState.isAIWritingVisible && !appState.isDistractionFree {
                    AIWritingView(controller: appState.aiWriting, openSettings: { SettingsWindowController.shared.present(windowManager: windowManager) })
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
                }
                }

                if appState.isStatusBarVisible && !appState.isDistractionFree {
                    Divider()
                    StatusBarView(document: selectedDocument)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(
            reduceMotion ? nil : LacEditorDesign.structuralAnimation,
            value: appState.isStatusBarVisible
        )
        .overlay {
            if isDropTargeted {
                Rectangle().strokeBorder(LacEditorDesign.accent.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) { QuickOpenOverlay(controller: appState.folderSearch) }
        .background(
            // Cmd-= — привычный псевдоним Cmd-+ (на US-раскладке плюс — это Shift-=); пункт меню остаётся один.
            Button("") { appState.increaseFontSize() }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: openDroppedFiles)
        // The content is hosted by its own NSHostingController, which does not inherit these objects.
        .environmentObject(appState)
        .environmentObject(windowManager)
    }

    private func openDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        // Порядок не зависит от очерёдности loadItem: сначала первая папка, затем файлы в порядке броска.
        let urls = DropURLCollector(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? item as? URL
                urls.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let dropped = urls.values.compactMap { $0 }
                if let folder = dropped.first(where: DroppedURLKind.isDirectory) { appState.openFolder(folder) }
                for url in dropped where !DroppedURLKind.isDirectory(url) { appState.openFile(url) }
            }
        }
        return !providers.isEmpty
    }

}

/// Hints live above the empty canvas, without replacing its text view or
/// first responder. Typing/undo updates this small observed view only.
struct EditorStartHints: View {
    @ObservedObject var document: EditorDocument
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        if document.isDisposableBlank, document.text.isEmpty, document.ioState == .idle {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("从一行文字开始")).font(.title.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("直接输入，或打开一份文件。"))
                        .font(.callout).foregroundStyle(.secondary)
                }.allowsHitTesting(false)
                VStack(spacing: 4) {
                    startAction(L10n.tr("打开文件"), symbol: "doc.badge.plus", detail: "⌘O") { appState.openFiles() }
                    startAction(L10n.tr("打开文件夹…"), symbol: "folder", detail: "") { appState.openFolder() }
                    if windowManager.experimentSamples != nil {
                        startAction(L10n.tr("打开体验文档"), symbol: "text.book.closed", detail: L10n.tr("Markdown · 代码 · 长文本")) {
                            windowManager.openExperimentWelcome(in: appState)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    RecentHintsList(store: appState.recentFiles) { url in
                        startAction(url.lastPathComponent, symbol: "doc.text", detail: "") { appState.openFile(url) }
                            .help(url.path)
                    }
                }
                Text(L10n.tr("文件可以直接拖到窗口中"))
                    .font(.subheadline).foregroundStyle(.secondary).allowsHitTesting(false)
            }
            .frame(minWidth: 240, idealWidth: 310, maxWidth: 360)
            .padding(20)
            .accessibilityElement(children: .contain)
        }
    }

    private func startAction(_ title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(LacEditorDesign.accent).frame(width: 20)
                Text(title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).frame(height: 42).contentShape(Rectangle())
        }.buttonStyle(QuietActionButtonStyle())
    }
}

final class DropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL?]

    init(count: Int) { items = Array(repeating: nil, count: count) }

    func set(_ url: URL?, at index: Int) {
        lock.lock(); defer { lock.unlock() }
        items[index] = url
    }

    var values: [URL?] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// Наблюдает хранилище недавних файлов отдельно, чтобы подсказка обновлялась при его изменении.
private struct RecentHintsList<Row: View>: View {
    @ObservedObject var store: RecentFilesStore
    let row: (URL) -> Row

    var body: some View {
        let urls = RecentHints.urls(store.urls)
        if !urls.isEmpty {
            Text(L10n.tr("最近文件")).font(.subheadline).foregroundStyle(.secondary).allowsHitTesting(false)
            VStack(spacing: 4) {
                ForEach(urls, id: \.self) { url in row(url) }
            }
        }
    }
}

enum DroppedURLKind {
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

enum RecentHints {
    static func urls(_ all: [URL], limit: Int = 3, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        Array(all.filter(exists).prefix(limit))
    }
}

/// Hosts the editor in AppKit's native sidebar split controller. Keeping the
/// sidebar as a real split-view item avoids the fragile overlay/offset model:
/// AppKit owns divider geometry, collapse behavior and window resizing.
private struct NativeSidebarSplitView: NSViewControllerRepresentable {
    @ObservedObject var appState: AppState
    @ObservedObject var windowManager: WindowManager
    let sidebar: SidebarView
    let content: AnyView

    init(
        appState: AppState,
        windowManager: WindowManager,
        sidebar: SidebarView,
        content: some View
    ) {
        self.appState = appState
        self.windowManager = windowManager
        self.sidebar = sidebar
        self.content = AnyView(content)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        let sidebarController = NSHostingController(
            rootView: AnyView(
                sidebar
                    .environmentObject(appState)
                    .environmentObject(windowManager)
            )
        )
        let contentController = NSHostingController(rootView: content)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        // Scroll views extend underneath the system toolbar. Their content
        // insets reserve the safe area; the preview divider clips separately.
        let contentBoundary = NSViewController()
        contentBoundary.view = NSView()
        contentBoundary.view.wantsLayer = true
        contentBoundary.view.layer?.masksToBounds = true
        contentBoundary.addChild(contentController)
        contentController.safeAreaRegions = []
        let hosted = contentController.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        contentBoundary.view.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: contentBoundary.view.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: contentBoundary.view.bottomAnchor),
            hosted.leadingAnchor.constraint(equalTo: contentBoundary.view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: contentBoundary.view.trailingAnchor)
        ])
        // AppKit owns the titlebar backdrop, as in NT2. Do not place an
        // additional material over the scrolling content.
        let contentItem = NSSplitViewItem(viewController: contentBoundary)
        contentItem.minimumThickness = 420
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(contentItem)
        controller.splitView.dividerStyle = .thin
        controller.splitView.isVertical = true
        controller.view.wantsLayer = true
        DispatchQueue.main.async { [weak controller] in
            guard let controller,
                  controller.splitViewItems.first?.isCollapsed == false else { return }
            controller.splitView.setPosition(
                LacEditorDesign.sidebarWidth,
                ofDividerAt: 0
            )
        }

        context.coordinator.sidebarController = sidebarController
        context.coordinator.contentController = contentController
        context.coordinator.sidebarItem = sidebarItem
        context.coordinator.applyCollapseState(
            isVisible: appState.isSidebarEffectivelyVisible
        )
        context.coordinator.observeCollapseState(appState: appState)
        return controller
    }

    func updateNSViewController(
        _ controller: NSSplitViewController,
        context: Context
    ) {
        context.coordinator.sidebarController?.rootView = AnyView(
            sidebar
                .environmentObject(appState)
                .environmentObject(windowManager)
        )
        context.coordinator.contentController?.rootView = content
        context.coordinator.applyCollapseState(
            isVisible: appState.isSidebarEffectivelyVisible
        )
    }

    static func dismantleNSViewController(
        _ controller: NSSplitViewController,
        coordinator: Coordinator
    ) {
        coordinator.stopObservingCollapseState()
    }

    @MainActor
    final class Coordinator {
        var sidebarController: NSHostingController<AnyView>?
        var contentController: NSHostingController<AnyView>?
        weak var sidebarItem: NSSplitViewItem?
        private var collapseObservation: NSKeyValueObservation?
        private var splitResizeObservation: NSObjectProtocol?
        private var isApplyingCollapseState = false
        private var isDismantling = false

        func observeCollapseState(appState: AppState) {
            // The system toolbar button changes NSSplitViewItem directly.
            // Reflect that change before SwiftUI next reconciles the layout.
            collapseObservation = sidebarItem?.observe(\.isCollapsed, options: [.new]) {
                [weak self, weak appState] item, _ in
                MainActor.assumeIsolated {
                    self?.synchronizeCollapseState(item: item, appState: appState)
                }
            }
            if let splitView = sidebarItem?.viewController.parent?.view as? NSSplitView {
                splitResizeObservation = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: splitView,
                    queue: .main
                ) { [weak self, weak appState] _ in
                    MainActor.assumeIsolated {
                        guard let sidebarItem = self?.sidebarItem else { return }
                        self?.synchronizeCollapseState(item: sidebarItem, appState: appState)
                    }
                }
            }
        }

        private func synchronizeCollapseState(item: NSSplitViewItem, appState: AppState?) {
            guard let appState, !isDismantling, !isApplyingCollapseState,
                  !appState.isDistractionFree else { return }
            let isVisible = !item.isCollapsed
            if appState.isSidebarVisible != isVisible {
                appState.isSidebarVisible = isVisible
            }
        }

        func stopObservingCollapseState() {
            isDismantling = true
            collapseObservation?.invalidate()
            collapseObservation = nil
            if let splitResizeObservation {
                NotificationCenter.default.removeObserver(splitResizeObservation)
                self.splitResizeObservation = nil
            }
        }

        func applyCollapseState(isVisible: Bool) {
            guard let sidebarItem else { return }
            if sidebarItem.isCollapsed == !isVisible { return }
            isApplyingCollapseState = true
            sidebarItem.isCollapsed = !isVisible
            isApplyingCollapseState = false
        }
    }

}

private struct DocumentEditorPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument
    let sessionStore: EditorSessionStore
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let indentationStyle: IndentationStyle
    let tabWidth: Int
    let wordWrap: Bool
    let showsLineNumbers: Bool
    let editorTopInset: CGFloat
    let darkMode: Bool

    var body: some View {
        ZStack {
            NativeEditorSplit(
                editor: AnyView(editor),
                preview: document.isPreviewEffectivelyEnabled && !appState.isDistractionFree ? AnyView(
                    MarkdownPreview(
                        markdown: document.text,
                        revision: document.textRevision,
                        darkMode: darkMode,
                        typography: appState.preferences.markdownTypography,
                        mathOptions: .init(physics: appState.preferences.mathPhysicsEnabled, numbering: appState.preferences.mathNumbering),
                        syntax: appState.preferences.markdownSyntax,
                        viewMagnification: appState.viewMagnification,
                        magnificationDidChange: appState.setViewMagnification,
                        document: document
                    )
                ) : nil
            )
            if document.ioState == .opening {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.tr("正在打开“%@”", String(describing: document.displayName)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(L10n.tr("取消")) {
                        appState.cancelOpening(document)
                    }
                }
            }
        }
    }

    private var editor: some View {
        EditorTextView(
            document: document,
            sessionStore: sessionStore,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            indentationStyle: indentationStyle,
            tabWidth: tabWidth,
            wordWrap: wordWrap,
            showsLineNumbers: showsLineNumbers,
            topInset: editorTopInset,
            isActive: true,
            requestTextTransformation: appState.presentTextTransformation,
            isOutlineVisible: appState.isSidebarEffectivelyVisible && appState.isMarkdownOutlineExpanded,
            spellingEnabled: appState.preferences.systemSpellingEnabled,
            grammarEnabled: appState.preferences.systemGrammarEnabled,
            aiPreferences: appState.preferences,
            isFocusMode: appState.isFocusMode,
            isTypewriterMode: appState.isTypewriterMode,
            textFontFamily: appState.preferences.editorTextFontFamily,
            codeFontFamily: appState.preferences.editorCodeFontFamily,
            remoteImageTransferEnabled: appState.preferences.markdownImageUploadConfiguration.automaticOnline,
            maximumTextWidth: document.language == .markdown ? appState.preferences.markdownMaximumWidth : nil,
            colorOverrides: document.language == .markdown ? appState.preferences.markdownColors(darkMode: darkMode) : .init(),
            markdownTOCMaxLevel: appState.preferences.markdownTOCMaxLevel,
            viewMagnification: appState.viewMagnification,
            magnificationDidChange: appState.setViewMagnification,
            requestAIImageEdit: { request in appState.aiWriting.prepareImageEdit(request) }
        )
        .disabled(appState.isOpeningPlaceholder(document))
    }
}

/// Only the scrolling panes underlap the toolbar, never the divider between
/// them. A real split view also preserves the user's split ratio on updates.
struct NativeEditorSplit: NSViewControllerRepresentable {
    let editor: AnyView
    let preview: AnyView?

    func makeNSViewController(context: Context) -> NativeEditorSplitController {
        let controller = NativeEditorSplitController()
        controller.update(editor: editor, preview: preview)
        return controller
    }

    func updateNSViewController(_ controller: NativeEditorSplitController, context: Context) {
        controller.update(editor: editor, preview: preview)
    }
}

final class NativeEditorSplitController: NSSplitViewController {
    private let editorHost = NSHostingController(rootView: AnyView(EmptyView()))
    private var previewHost: NSHostingController<AnyView>?
    private var previewItem: NSSplitViewItem?
    private var retainedPreview: AnyView?
    private var previewIsVisible = false
    private var editorFraction: CGFloat = 0.5
    private var needsRatioRestore = false

    override func loadView() {
        splitView = ContentDividerSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        view = splitView
        editorHost.safeAreaRegions = []
        let item = NSSplitViewItem(viewController: editorHost)
        item.minimumThickness = 300
        addSplitViewItem(item)
    }

    func update(editor: AnyView, preview: AnyView?) {
        _ = view
        editorHost.rootView = editor
        if let preview {
            retainedPreview = preview
            let root = AnyView(preview.environment(\.markdownPreviewActive, true))
            if let previewHost {
                previewHost.rootView = root
            } else {
                let host = NSHostingController(rootView: root)
                host.safeAreaRegions = []
                let item = NSSplitViewItem(viewController: host)
                item.minimumThickness = 240
                item.canCollapse = true
                item.canCollapseFromWindowResize = false
                previewHost = host
                previewItem = item
                addSplitViewItem(item)
            }
            if !previewIsVisible {
                previewIsVisible = true
                needsRatioRestore = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.previewIsVisible else { return }
                    self.previewItem?.isCollapsed = false
                    self.view.needsLayout = true
                }
            }
        } else if previewIsVisible {
            rememberRatio()
            previewIsVisible = false
            needsRatioRestore = false
            if let retainedPreview {
                previewHost?.rootView = AnyView(retainedPreview.environment(\.markdownPreviewActive, false))
            }
            // Keep one native pane/WebView, suspend its work while collapsed.
            // A width animation would force repeated TextKit reflow. Preserve
            // immediate geometry and the native scroll pockets instead.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.previewIsVisible else { return }
                self.previewItem?.isCollapsed = true
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard previewIsVisible, view.window != nil, splitView.bounds.width > 1 else { return }
        if needsRatioRestore {
            needsRatioRestore = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewIsVisible, self.view.window != nil,
                      self.splitView.bounds.width > 1 else { return }
                let width = self.splitView.bounds.width - self.splitView.dividerThickness
                let position = min(max(300, width * self.editorFraction), max(300, width - 240))
                self.splitView.setPosition(position, ofDividerAt: 0)
            }
        } else {
            rememberRatio()
        }
    }

    private func rememberRatio() {
        let width = splitView.bounds.width - splitView.dividerThickness
        guard previewIsVisible, width > 1, !needsRatioRestore else { return }
        editorFraction = min(0.9, max(0.1, editorHost.view.frame.width / width))
    }
}

final class ContentDividerSplitView: NSSplitView {
    // Prevent AppKit's layer-backed divider from extending through the chrome.
    override var dividerColor: NSColor { .clear }

    override func drawDivider(in rect: NSRect) {
        let contentRect = window.map { convert($0.contentLayoutRect, from: nil) } ?? bounds
        let visible = rect.intersection(contentRect)
        guard !visible.isEmpty else { return }
        NSColor.separatorColor.setFill()
        visible.fill()
    }
}
