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
                appState?.toggleSidebar()
            } label: {
                Label(
                    appState?.isSidebarVisible == true ? L10n.tr("隐藏侧边栏") : L10n.tr("显示侧边栏"),
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut("b", modifiers: [.command, .control])
            .disabled(appState == nil)
            Divider()
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

        CommandGroup(after: .toolbar) {
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
