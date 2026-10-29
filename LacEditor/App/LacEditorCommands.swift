import AppKit
import SwiftUI

struct LacEditorCommands: Commands {
    @ObservedObject private var windowManager: WindowManager

    init(windowManager: WindowManager) {
        _windowManager = ObservedObject(wrappedValue: windowManager)
    }

    private var appState: AppState? {
        windowManager.activeState
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                SettingsWindowController.shared.present(windowManager: windowManager)
            } label: {
                Label(L10n.tr("设置…"), systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button {
                windowManager.openNewWindow()
            } label: {
                Label(L10n.tr("新建窗口"), systemImage: "macwindow.badge.plus")
            }
                .keyboardShortcut("n", modifiers: .command)
            Button {
                appState?.newDocument()
            } label: {
                Label(L10n.tr("新建标签页"), systemImage: "plus.square.on.square")
            }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(appState == nil)
            Divider()
            Button {
                appState?.openFiles()
            } label: {
                Label(L10n.tr("打开…"), systemImage: "doc")
            }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.openFolder()
            } label: {
                Label(L10n.tr("打开文件夹…"), systemImage: "folder")
            }
                .disabled(appState == nil)
            Button(L10n.tr("快速打开…")) {
                guard let appState else { return }
                if !appState.isSidebarEffectivelyVisible { appState.toggleSidebar() }
                appState.folderSearch.requestQuickOpen()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(appState == nil || (appState?.folderWorkspace.rootURL == nil &&
                windowManager.recentFiles.folderURLs.isEmpty && windowManager.sidebarLibrary.pinnedFolderPaths.isEmpty))
            Menu(L10n.tr("文件夹位置")) {
                ForEach(windowManager.sidebarLibrary.pinnedFolderURLs, id: \.self) { url in
                    Button { appState?.openFolder(url) } label: { Label(url.path, systemImage: "pin") }
                }
                ForEach(windowManager.recentFiles.folderURLs.filter { !windowManager.sidebarLibrary.isPinnedFolder($0) }, id: \.self) { url in
                    Button { appState?.openFolder(url) } label: { Label(url.path, systemImage: "folder") }
                }
                if !windowManager.recentFiles.folderURLs.isEmpty {
                    Divider()
                    Button(L10n.tr("清除最近文件夹")) { windowManager.recentFiles.clearFolders() }
                }
            }
            .disabled(appState == nil)
            Button {
                appState?.importDocument()
            } label: {
                Label(L10n.tr("导入…"), systemImage: "square.and.arrow.down")
            }
                .disabled(appState == nil)
            Menu {
                if windowManager.recentFiles.urls.isEmpty {
                    Text(L10n.tr("无最近文件"))
                } else {
                    ForEach(windowManager.recentFiles.urls, id: \.self) { url in
                        Button {
                            appState?.openFile(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "doc.text")
                        }
                    }
                    Divider()
                    Button {
                        windowManager.requestClearRecentFiles()
                    } label: {
                        Label(L10n.tr("清除菜单"), systemImage: "trash")
                    }
                }
            } label: {
                Label(L10n.tr("最近打开的文件"), systemImage: "clock")
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button {
                appState?.save()
            } label: {
                Label(L10n.tr("保存"), systemImage: "square.and.arrow.down")
            }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.saveAs()
            } label: {
                Label(L10n.tr("另存为…"), systemImage: "square.and.arrow.down.on.square")
            }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState == nil)
            Menu(L10n.tr("导出")) {
                Button("HTML") { appState?.exportMarkdown(as: .html) }
                Button(L10n.tr("HTML（无样式）")) { appState?.exportMarkdown(as: .htmlPlain) }
                Button("PDF") { appState?.exportMarkdown(as: .pdf) }
                Button("PNG") { appState?.exportMarkdownImage() }
                if let profiles = appState?.preferences.markdownExportConfiguration.profiles {
                    ForEach(profiles.filter(\.enabled)) { profile in
                        Button(profile.name) { appState?.exportMarkdown(profile: profile) }
                    }
                }
                Divider()
                Button(L10n.tr("使用上次设置导出")) { appState?.repeatMarkdownExport(overwrite: false) }
                    .disabled(appState?.hasPreviousMarkdownExport != true)
                Button(L10n.tr("使用上次设置导出并覆盖")) { appState?.repeatMarkdownExport(overwrite: true) }
                    .disabled(appState?.hasPreviousMarkdownExport != true)
            }
            .disabled(appState?.selectedDocument?.language != .markdown)
            Button(L10n.tr("打印 Markdown…")) { appState?.printMarkdown() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(appState?.selectedDocument?.language != .markdown)
            Divider()
            Button {
                if let keyWindow = NSApp.keyWindow,
                   keyWindow !== appState?.hostWindow {
                    keyWindow.performClose(nil)
                } else {
                    appState?.closeSelectedDocument()
                }
            } label: {
                Label(L10n.tr("关闭标签页"), systemImage: "xmark.square")
            }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState == nil)
        }

        CommandGroup(after: .pasteboard) {
            Button {
                appState?.presentFindReplace(mode: .find)
            } label: {
                Label(L10n.tr("查找…"), systemImage: "magnifyingglass")
            }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.presentFindReplace(mode: .replace)
            } label: {
                Label(L10n.tr("查找并替换…"), systemImage: "arrow.triangle.2.circlepath")
            }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.findNext()
            } label: {
                Label(L10n.tr("查找下一个"), systemImage: "chevron.down")
            }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.findPrevious()
            } label: {
                Label(L10n.tr("查找上一个"), systemImage: "chevron.up")
            }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState == nil)
            Divider()
            Menu {
                Button {
                    appState?.presentTextTransformation(.smartDecode)
                } label: {
                    Label(L10n.tr("智能解码"), systemImage: "wand.and.stars")
                }
                .keyboardShortcut("d", modifiers: [.control, .option])
                Divider()
                Menu("URL") {
                    transformationButton(.urlEncodeComponent)
                    transformationButton(.urlDecode)
                    transformationButton(.formURLDecode)
                }
                Menu("Base64") {
                    transformationButton(.base64Encode)
                    transformationButton(.base64Decode)
                    transformationButton(.base64URLEncode)
                    transformationButton(.base64URLDecode)
                }
                Menu(L10n.tr("HTML 实体")) {
                    transformationButton(.htmlEncode)
                    transformationButton(.htmlDecode)
                }
                Menu(L10n.tr("Unicode/JSON 转义")) {
                    transformationButton(.unicodeEncode)
                    transformationButton(.unicodeDecode)
                }
            } label: {
                Label(L10n.tr("编码与解码"), systemImage: "arrow.left.arrow.right")
            }
            .disabled(appState == nil)
            Divider()
            Button {
                appState?.formatJSON()
            } label: {
                Label(L10n.tr("格式化 JSON"), systemImage: "text.alignleft")
            }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.formatJSON(pretty: false)
            } label: {
                Label(L10n.tr("压缩 JSON"), systemImage: "arrow.down.right.and.arrow.up.left")
            }
                .disabled(appState == nil)
        }

        // Suppress SwiftUI's automatic sidebar titlebar control. macOS 26
        // renders it as an accent-colored capsule; LacEditor owns a native
        // AppKit button beside the traffic lights instead.
        CommandGroup(replacing: .sidebar) {}

        CommandMenu(L10n.tr("AI 写作助手")) {
            Button(L10n.tr("显示或隐藏 AI 助手")) {
                if appState?.isDistractionFree == true { appState?.toggleDistractionFree() }
                appState?.isAIWritingVisible.toggle()
            }
            .disabled(appState == nil)
            Divider()
            ForEach(AIFeature.allCases) { feature in
                Button(feature.title) {
                    if appState?.isDistractionFree == true { appState?.toggleDistractionFree() }
                    appState?.isAIWritingVisible = true
                    if feature.isDocumentTool || feature == .translation || feature == .toneRewrite || feature == .audienceReview {
                        appState?.aiWriting.prepare(feature)
                    } else if feature == .imageDescription {
                        appState?.isAIWritingVisible = true
                        appState?.aiWriting.describeImage()
                    } else {
                        appState?.aiWriting.run(feature)
                    }
                }
                .disabled(appState?.selectedDocument == nil || appState?.preferences.aiFeatures.contains(feature) != true)
            }
        }

        CommandGroup(after: .toolbar) {
            Button {
                appState?.toggleSidebar()
            } label: {
                Label(
                    appState?.isSidebarEffectivelyVisible == true ? L10n.tr("隐藏侧边栏") : L10n.tr("显示侧边栏"),
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut("b", modifiers: [.command, .control])
            .disabled(appState == nil)
            Divider()
            Button {
                appState?.toggleDistractionFree()
            } label: {
                Label(
                    appState?.isDistractionFree == true ? L10n.tr("退出专注模式") : L10n.tr("进入专注模式"),
                    systemImage: "rectangle.inset.filled"
                )
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(appState?.hostWindow == nil)
            Divider()
            Toggle(L10n.tr("聚焦当前段落"), isOn: Binding(
                get: { appState?.isFocusMode ?? false },
                set: { _ in appState?.toggleFocusMode() }
            ))
            .disabled(appState?.hostWindow == nil)
            Toggle(L10n.tr("打字机模式"), isOn: Binding(
                get: { appState?.isTypewriterMode ?? false },
                set: { _ in appState?.toggleTypewriterMode() }
            ))
            .disabled(appState?.hostWindow == nil)
            Divider()
            Picker(L10n.tr("Markdown 编辑方式"), selection: Binding(
                get: { appState?.selectedDocument?.isMarkdownFormatted ?? false },
                set: { appState?.selectedDocument?.isMarkdownFormatted = $0 }
            )) {
                Text(L10n.tr("Markdown 源码")).tag(false)
                Text(L10n.tr("格式化文本")).tag(true)
            }
            .disabled(appState?.selectedDocument?.language != .markdown)
            Button {
                appState?.togglePreview()
            } label: {
                Label(L10n.tr("切换 Markdown 预览"), systemImage: "rectangle.split.2x1")
            }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.toggleWordWrap()
            } label: {
                Label(
                    currentWordWrapEnabled ? L10n.tr("关闭自动换行") : L10n.tr("开启自动换行"),
                    systemImage: "text.justify.left"
                )
            }
            .disabled(appState == nil)
            Menu {
                largeFileFeatureItem(
                    L10n.tr("自动换行"),
                    feature: .wordWrap,
                    enabled: currentWordWrapEnabled
                )
                largeFileFeatureItem(
                    L10n.tr("Markdown 预览"),
                    feature: .preview,
                    enabled: appState?.selectedDocument?.isPreviewEffectivelyEnabled == true
                )
                largeFileFeatureItem(
                    L10n.tr("语法高亮"),
                    feature: .syntaxHighlighting,
                    enabled: appState?.selectedDocument?.isSyntaxHighlightingEnabled == true
                )
                largeFileFeatureItem(
                    L10n.tr("代码折叠"),
                    feature: .folding,
                    enabled: appState?.selectedDocument?.isFoldingEnabled == true
                )
                largeFileFeatureItem(
                    L10n.tr("实时字数统计"),
                    feature: .wordCount,
                    enabled: appState?.selectedDocument?.isWordCountEnabled == true
                )
            } label: {
                Label(L10n.tr("大文件模式"), systemImage: "gauge.with.dots.needle.33percent")
            }
            .disabled(appState?.selectedDocument?.isLargeFileMode != true)
            Button {
                appState?.isLineNumbersVisible.toggle()
            } label: {
                Label(
                    appState?.isLineNumbersVisible == true ? L10n.tr("隐藏行号") : L10n.tr("显示行号"),
                    systemImage: "list.number"
                )
            }
            .disabled(appState == nil)
            Button {
                appState?.isStatusBarVisible.toggle()
            } label: {
                Label(
                    appState?.isStatusBarVisible == true ? L10n.tr("隐藏状态栏") : L10n.tr("显示状态栏"),
                    systemImage: "rectangle.bottomthird.inset.filled"
                )
            }
            .disabled(appState == nil)
            Divider()
            Button {
                appState?.increaseFontSize()
            } label: {
                Label(L10n.tr("增大字体"), systemImage: "plus.magnifyingglass")
            }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.decreaseFontSize()
            } label: {
                Label(L10n.tr("减小字体"), systemImage: "minus.magnifyingglass")
            }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.resetFontSize()
            } label: {
                Label(L10n.tr("恢复默认字体大小"), systemImage: "textformat.size")
            }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState == nil)
            Divider()
            Button(L10n.tr("放大视图")) { appState?.increaseViewMagnification() }
                .disabled(appState == nil)
            Button(L10n.tr("缩小视图")) { appState?.decreaseViewMagnification() }
                .disabled(appState == nil)
            Button(L10n.tr("实际大小")) { appState?.resetViewMagnification() }
                .disabled(appState == nil)
            Divider()
            Picker(
                selection: Binding(
                    get: { appState?.theme ?? .system },
                    set: { appState?.theme = $0 }
                ),
                label: Label(L10n.tr("外观"), systemImage: "circle.lefthalf.filled")
            ) {
                Label(L10n.tr(AppTheme.system.rawValue), systemImage: "circle.lefthalf.filled")
                    .tag(AppTheme.system)
                Label(L10n.tr(AppTheme.light.rawValue), systemImage: "sun.max")
                    .tag(AppTheme.light)
                Label(L10n.tr(AppTheme.dark.rawValue), systemImage: "moon")
                    .tag(AppTheme.dark)
            }
            .disabled(appState == nil)
        }

        CommandMenu(L10n.tr("Markdown 格式")) {
            Group {
                Button(L10n.tr("复制 Markdown")) { appState?.markdownClipboard(.copyMarkdown) }
                Button(L10n.tr("复制 HTML 代码")) { appState?.markdownClipboard(.copyHTML) }
                Button(L10n.tr("粘贴为源文本")) { appState?.markdownClipboard(.pasteSource) }
                Button(L10n.tr("复制代码块内容")) { appState?.markdownClipboard(.copyCodeBlock) }
                Button(L10n.tr("设置代码块语言")) { appState?.markdownClipboard(.setCodeLanguage) }
                Divider()
                Button(L10n.tr("加粗")) { appState?.formatMarkdown(.bold) }
                    .keyboardShortcut("b", modifiers: .command)
                Button(L10n.tr("斜体")) { appState?.formatMarkdown(.italic) }
                    .keyboardShortcut("i", modifiers: .command)
                Button(L10n.tr("删除线")) { appState?.formatMarkdown(.strikethrough) }
                Button(L10n.tr("行内代码")) { appState?.formatMarkdown(.inlineCode) }
                Button(L10n.tr("行内公式")) { appState?.formatMarkdown(.inlineMath) }
                Button(L10n.tr("链接…")) { appState?.presentMarkdownLink() }
                Button(L10n.tr("图片…")) { _ = appState?.presentMarkdownImage() }
                Button(L10n.tr("设置图片资源根路径…")) { appState?.presentMarkdownResourceRoot() }
                Button(L10n.tr("复制选中图片到…")) { appState?.copyMarkdownImages(selectedOnly: true, remoteOnly: false) }
                Button(L10n.tr("复制全部图片到…")) { appState?.copyMarkdownImages(selectedOnly: false, remoteOnly: false) }
                Button(L10n.tr("下载全部网络图片到…")) { appState?.copyMarkdownImages(selectedOnly: false, remoteOnly: true) }
                Button(L10n.tr("移动或重命名图片…")) { appState?.moveOrDeleteMarkdownImage(deleteOriginal: false) }
                Button(L10n.tr("移动全部图片到…")) { appState?.moveAllMarkdownImages() }
                Button(L10n.tr("删除图片及原文件…")) { appState?.moveOrDeleteMarkdownImage(deleteOriginal: true) }
                Button(L10n.tr("上传选中图片")) { appState?.uploadMarkdownImages(selectedOnly: true) }
                Button(L10n.tr("上传全部本地图片")) { appState?.uploadMarkdownImages(selectedOnly: false) }
                Divider()
                ForEach(1...6, id: \.self) { level in
                    Button(L10n.tr("标题 %@ 级", String(level))) {
                        appState?.formatMarkdown(.heading(level))
                    }
                }
                Button(L10n.tr("引用")) { appState?.formatMarkdown(.quote) }
                Divider()
                Button(L10n.tr("无序列表")) { appState?.formatMarkdown(.bulletList) }
                Button(L10n.tr("有序列表")) { appState?.formatMarkdown(.numberedList) }
                Button(L10n.tr("任务列表")) { appState?.formatMarkdown(.taskList) }
                Button(L10n.tr("代码块")) { appState?.formatMarkdown(.fencedCode) }
                Button(L10n.tr("公式块")) { appState?.formatMarkdown(.blockMath) }
                Button(L10n.tr("分隔线")) { appState?.formatMarkdown(.horizontalRule) }
                Menu(L10n.tr("表格")) {
                    Button(L10n.tr("插入表格")) { appState?.formatMarkdown(.table(.create(rows: 1, columns: 2))) }
                    Divider()
                    Button(L10n.tr("在上方插入行")) { appState?.formatMarkdown(.table(.insertRowBefore)) }
                    Button(L10n.tr("在下方插入行")) { appState?.formatMarkdown(.table(.insertRowAfter)) }
                    Button(L10n.tr("删除行")) { appState?.formatMarkdown(.table(.deleteRow)) }
                    Button(L10n.tr("上移行")) { appState?.formatMarkdown(.table(.moveRowUp)) }
                    Button(L10n.tr("下移行")) { appState?.formatMarkdown(.table(.moveRowDown)) }
                    Divider()
                    Button(L10n.tr("在左侧插入列")) { appState?.formatMarkdown(.table(.insertColumnBefore)) }
                    Button(L10n.tr("在右侧插入列")) { appState?.formatMarkdown(.table(.insertColumnAfter)) }
                    Button(L10n.tr("删除列")) { appState?.formatMarkdown(.table(.deleteColumn)) }
                    Button(L10n.tr("左移列")) { appState?.formatMarkdown(.table(.moveColumnLeft)) }
                    Button(L10n.tr("右移列")) { appState?.formatMarkdown(.table(.moveColumnRight)) }
                    Menu(L10n.tr("列对齐")) {
                        Button(L10n.tr("默认对齐")) { appState?.formatMarkdown(.table(.align(.unspecified))) }
                        Button(L10n.tr("左对齐")) { appState?.formatMarkdown(.table(.align(.left))) }
                        Button(L10n.tr("居中对齐")) { appState?.formatMarkdown(.table(.align(.center))) }
                        Button(L10n.tr("右对齐")) { appState?.formatMarkdown(.table(.align(.right))) }
                    }
                }
            }
            .disabled(appState?.selectedDocument?.language != .markdown || appState?.selectedDocument?.ioState != .idle)
        }

        CommandMenu(L10n.tr("标签页")) {
            Button {
                appState?.selectPreviousTab()
            } label: {
                Label(L10n.tr("上一个标签页"), systemImage: "chevron.left")
            }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.selectNextTab()
            } label: {
                Label(L10n.tr("下一个标签页"), systemImage: "chevron.right")
            }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.selectNextTab()
            } label: {
                Label(L10n.tr("切换到下一个标签页"), systemImage: "arrow.right.to.line")
            }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(appState == nil)
            Button {
                appState?.selectPreviousTab()
            } label: {
                Label(L10n.tr("切换到上一个标签页"), systemImage: "arrow.left.to.line")
            }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(appState == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button {
                    appState?.selectTab(at: number - 1)
                } label: {
                    Label(
                        L10n.tr("切换到第 %@ 个标签页", String(number)),
                        systemImage: "\(number).square"
                    )
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(number))),
                    modifiers: .command
                )
                // NSWindow.tabGroup may create a native group and lay out the
                // hosting view. Never invoke it while SwiftUI evaluates menus.
                // selectTab(at:) validates the index when the command runs.
                .disabled(appState == nil)
            }
            Divider()
            Button {
                guard let documentID = appState?.selectedDocumentID else { return }
                NotificationCenter.default.post(
                    name: EditorCommandNotification.toggleFold,
                    object: documentID
                )
            } label: {
                Label(L10n.tr("折叠/展开当前区块"), systemImage: "chevron.up.chevron.down")
            }
            .disabled(appState == nil)
        }
    }

    private var currentWordWrapEnabled: Bool {
        guard let appState, let document = appState.selectedDocument else { return false }
        return document.effectiveWordWrap(globalDefault: appState.isWordWrapEnabled)
    }

    private func largeFileFeatureItem(
        _ title: String,
        feature: DocumentManagedFeature,
        enabled: Bool
    ) -> some View {
        Button {
            appState?.toggleLargeFileFeature(feature)
        } label: {
            Label(title, systemImage: enabled ? "checkmark" : "minus")
        }
    }

    private func transformationButton(
        _ operation: TextTransformationOperation
    ) -> some View {
        Button(operation.title) {
            appState?.presentTextTransformation(operation)
        }
    }

}
