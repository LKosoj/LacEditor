import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case editor = "编辑器", appearance = "外观", files = "文件与恢复", associations = "文件关联", performance = "性能", ai = "人工智能", about = "关于"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .editor: "text.cursor"
        case .appearance: "circle.lefthalf.filled"
        case .files: "clock.arrow.circlepath"
        case .associations: "doc.badge.gearshape"
        case .performance: "gauge.with.dots.needle.33percent"
        case .ai: "sparkles"
        case .about: "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .editor: L10n.tr("让文字的呈现和输入方式更合你的习惯。")
        case .appearance: L10n.tr("选择舒适的外观，让界面保持安静。")
        case .files: L10n.tr("离开之后，下次继续。")
        case .associations: L10n.tr("选择哪些文本格式默认使用 LacEditor 打开。")
        case .performance: L10n.tr("按文档大小自动管理，优先保持编辑顺畅。")
        case .ai: L10n.tr("配置文本、判断和图像服务。")
        case .about: L10n.tr("一款专注于文本与代码的 macOS 编辑器。")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(L10n.languageKey) private var appLanguage = "system"
    @State private var selection: SettingsSection
    @State private var visited: Set<SettingsSection>

    init(initialSection: SettingsSection = .editor) {
        _selection = State(initialValue: initialSection)
        _visited = State(initialValue: [initialSection])
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Divider()
            ZStack {
                ForEach(SettingsSection.allCases) { section in
                    if visited.contains(section) {
                        page(section)
                            .opacity(selection == section ? 1 : 0)
                            .allowsHitTesting(selection == section)
                            .disabled(selection != section)
                            .accessibilityHidden(selection != section)
                            .zIndex(selection == section ? 1 : 0)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(LacEditorDesign.canvas)
        .tint(LacEditorDesign.accent)
        .foregroundStyle(.primary)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("设置")).font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 20)
            ForEach(SettingsSection.allCases) { section in
                SettingsNavigationRow(section: section, selected: selection == section) {
                    visited.insert(section)
                    selection = section
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Text(AppEnvironment.displayName).font(.system(size: 11, weight: .medium))
                Text(AppEnvironment.isExperiment ? L10n.tr("界面实验 · %@", String(describing: AppEnvironment.experimentIteration)) : L10n.tr("本地编辑，专注文字"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(12)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(width: 176)
        .background(SidebarMaterialBackground())
    }

    private func page(_ section: SettingsSection) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr(section.rawValue)).font(.system(size: 22, weight: .semibold))
                    Text(section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.bottom, 3)
                pageContents(section)
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(NativeScrollViewConfigurator())
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func pageContents(_ section: SettingsSection) -> some View {
        switch section {
        case .editor: editorSettings
        case .appearance: appearanceSettings
        case .files: fileSettings
        case .associations: FileAssociationSettingsView()
        case .performance: performanceSettings
        case .ai: AISettingsView(preferences: appState.preferences, isActive: selection == .ai)
        case .about: aboutSettings
        }
    }

    private var editorSettings: some View {
        VStack(spacing: 20) {
            PreferenceGroup(title: L10n.tr("文字排版")) {
                PreferenceRow(title: L10n.tr("字体大小"), detail: L10n.tr("所有标签共用，默认 14 pt。")) {
                    HStack(spacing: 12) {
                        Stepper("\(Int(appState.editorFontSize)) pt", value: $appState.editorFontSize, in: 9...32)
                            .monospacedDigit().accessibilityLabel(L10n.tr("字体大小"))
                        resetButton(disabled: appState.isUsingDefaultFontSize, help: L10n.tr("恢复默认字体大小（⌘0）"), action: appState.resetFontSize)
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("额外行距"), detail: L10n.tr("在固定行高之外增加间距，默认 4 pt。")) {
                    HStack(spacing: 12) {
                        Stepper("\(Int(appState.editorLineSpacing)) pt", value: $appState.editorLineSpacing, in: 0...10)
                            .monospacedDigit().accessibilityLabel(L10n.tr("额外行距"))
                        resetButton(disabled: appState.isUsingDefaultLineSpacing, help: L10n.tr("恢复默认行距"), action: appState.resetLineSpacing)
                    }
                }
            }
            PreferenceGroup(title: L10n.tr("输入与显示")) {
                PreferenceRow(title: L10n.tr("缩进方式"), detail: L10n.tr("按 Tab 时插入的内容。")) {
                    Picker(L10n.tr("缩进方式"), selection: $appState.indentationStyle) {
                        ForEach(IndentationStyle.allCases) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(width: 156)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("Tab 宽度"), detail: L10n.tr("统一显示文档中全部 Tab 字符。")) {
                    Picker(L10n.tr("Tab 宽度"), selection: $appState.tabWidth) {
                        ForEach([2, 4, 8], id: \.self) { Text(L10n.tr("%@ 个字符", String(describing: $0))).tag($0) }
                    }.labelsHidden().frame(width: 156)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("自动换行"), detail: L10n.tr("长行在编辑区域内折行。")) {
                    Toggle(L10n.tr("自动换行"), isOn: $appState.isWordWrapEnabled).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("显示行号"), detail: L10n.tr("在正文左侧显示行标尺。")) {
                    Toggle(L10n.tr("显示行号"), isOn: $appState.isLineNumbersVisible).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(spacing: 20) {
            PreferenceGroup(title: L10n.tr("界面主题")) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.tr("外观")).font(.system(size: 13, weight: .medium))
                    HStack(spacing: 12) {
                        ForEach(AppTheme.allCases) { theme in
                            ThemeChoice(theme: theme, selected: appState.theme == theme) { appState.theme = theme }
                        }
                    }
                    Text(L10n.tr("跟随系统时，界面会随 macOS 的浅色与深色设置切换。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(16)
            }
            PreferenceGroup(title: L10n.tr("语言")) {
                PreferenceRow(title: L10n.tr("界面语言"), detail: L10n.tr("更改语言后请重新启动应用。")) {
                    Picker(L10n.tr("界面语言"), selection: $appLanguage) {
                        Text(L10n.tr("跟随系统")).tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                        Text("Русский").tag("ru")
                    }.labelsHidden().frame(width: 156)
                        .onChange(of: appLanguage) { _, selection in
                            L10n.saveLanguageSelection(selection)
                        }
                }
            }
            PreferenceGroup(title: L10n.tr("窗口界面")) {
                PreferenceRow(title: L10n.tr("显示状态栏"), detail: L10n.tr("在窗口底部显示保存状态与行列位置。")) {
                    Toggle(L10n.tr("显示状态栏"), isOn: $appState.isStatusBarVisible).labelsHidden().toggleStyle(.switch)
                }
            }
            Label(L10n.tr("动态效果与透明度遵循 macOS 辅助功能设置。"), systemImage: "accessibility")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fileSettings: some View {
        VStack(spacing: 20) {
            PreferenceGroup(title: L10n.tr("离开与继续")) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.tr("退出应用时")).font(.system(size: 13, weight: .medium))
                    Picker(L10n.tr("退出应用时"), selection: $appState.workspaceExitBehavior) {
                        ForEach(WorkspaceExitBehavior.allCases) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(maxWidth: 310)
                    Text(L10n.tr("保留工作区会在本机记录窗口、标签和未保存内容，下次启动继续恢复。不会因此覆盖磁盘中的原文件。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            }
            PreferenceGroup(title: L10n.tr("本地恢复")) {
                PreferenceRow(title: L10n.tr("异常关闭保护"), detail: L10n.tr("未保存内容保留在本机恢复目录。恢复副本与主动保存文件是两回事。")) {
                    Label(L10n.tr("本地保留"), systemImage: "internaldrive").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if AppEnvironment.isExperiment {
                Label(L10n.tr("实验版的工作区、收藏和设置与正式版分别存放。"), systemImage: "square.stack.3d.up")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var performanceSettings: some View {
        VStack(spacing: 20) {
            PreferenceGroup(title: L10n.tr("自动性能管理")) {
                PreferenceRow(title: L10n.tr("标准模式"), detail: L10n.tr("日常文档保持完整编辑、预览和高亮能力。")) {
                    Text(L10n.tr("默认")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("大文件模式"), detail: L10n.tr("超过 20 MB 或 250,000 行时自动启用，暂停换行、预览、折叠和实时字数统计。")) {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(LacEditorDesign.accent)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("加强保护"), detail: L10n.tr("超过 50 MB 时额外暂停语法高亮，仍可继续打开与编辑。")) {
                    Text("50 MB+").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(L10n.tr("这些阈值由应用自动管理。可从当前文档的「大文件模式」菜单临时恢复功能，不会改写全局设置。"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 7) {
                    Text(AppEnvironment.displayName).font(.system(size: 20, weight: .semibold))
                    Text(versionDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(L10n.tr("macOS 26 及以上 · Apple Silicon")).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            PreferenceGroup(title: L10n.tr("关于这款编辑器")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("打开即写，轻装编辑。暂无登录、云同步或文档内容采集。"))
                    Text(L10n.tr("界面基于 SwiftUI 与 AppKit；编辑使用 TextKit，语法解析使用 Tree-sitter，Markdown 使用 cmark-gfm。"))
                        .foregroundStyle(.secondary)
                    Link(L10n.tr("查看项目与开源说明 ↗"), destination: URL(string: "https://github.com/kolmh/LacEditor")!)
                }.font(.system(size: 12)).padding(16)
            }
        }
    }

    private var rowDivider: some View { Divider().padding(.horizontal, 16).opacity(0.5) }
    private func resetButton(disabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "arrow.counterclockwise").frame(width: 20, height: 20) }
            .buttonStyle(.borderless).disabled(disabled).stableHelp(help).accessibilityLabel(help)
    }

    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return L10n.tr("开发版本") }
        let iteration = (info?["LacEditorExperimentIteration"] as? String).map { " · \($0)" } ?? ""
        let stage = (info?["LacEditorReleaseStage"] as? String).flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        let build = (info?["CFBundleVersion"] as? String).map { L10n.tr("（构建 %@）", String(describing: $0)) } ?? ""
        return L10n.tr("版本 %@%@%@%@", String(describing: version), String(describing: iteration), String(describing: stage), String(describing: build))
    }
}

private struct SettingsNavigationRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(selected ? LacEditorDesign.accent : .secondary)
                Text(L10n.tr(section.rawValue)).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }.padding(.horizontal, 12).frame(height: 38).contentShape(Rectangle())
                .background(selected ? LacEditorDesign.selectionFill : (hovering ? LacEditorDesign.hoverFill : .clear),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(SoftRowButtonStyle()).onHover { hovering = $0 }
        .focused($focused).editorFocusRing(focused)
        .accessibilityIdentifier("settings.section.\(section.id)")
        .accessibilityLabel(L10n.tr(section.rawValue)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ThemeChoice: View {
    let theme: AppTheme
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool
    private var dark: Bool { theme == .dark }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                HStack(spacing: 0) {
                    Rectangle().fill(dark ? Color(white: 0.23) : Color(white: 0.9)).frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(LacEditorDesign.accent.opacity(0.6)).frame(width: 30, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.3)).frame(height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.3)).frame(width: 20, height: 3)
                    }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(dark ? Color(white: 0.12) : .white)
                }
                .frame(height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? LacEditorDesign.accent : LacEditorDesign.outline, lineWidth: selected ? 2 : 1))
                HStack(spacing: 4) {
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(LacEditorDesign.accent) }
                    Text(L10n.tr(theme.rawValue))
                }.font(.system(size: 11, weight: selected ? .medium : .regular))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.tr(theme.rawValue))
            .focused($focused).editorFocusRing(focused)
            .accessibilityIdentifier("settings.theme.\(theme.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
