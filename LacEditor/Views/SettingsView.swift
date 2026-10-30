import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case editor = "编辑器", images = "图片设置", appearance = "外观", files = "文件与恢复", associations = "文件关联", performance = "性能", export = "导出", ai = "人工智能", about = "关于"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .editor: "text.cursor"
        case .images: "photo"
        case .appearance: "circle.lefthalf.filled"
        case .files: "clock.arrow.circlepath"
        case .associations: "doc.badge.gearshape"
        case .performance: "gauge.with.dots.needle.33percent"
        case .export: "square.and.arrow.up"
        case .ai: "sparkles"
        case .about: "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .editor: L10n.tr("让文字的呈现和输入方式更合你的习惯。")
        case .images: L10n.tr("配置图片上传、复制位置和文档级图片规则。")
        case .appearance: L10n.tr("选择舒适的外观，让界面保持安静。")
        case .files: L10n.tr("离开之后，下次继续。")
        case .associations: L10n.tr("选择哪些文本格式默认使用 LacEditor 打开。")
        case .performance: L10n.tr("按文档大小自动管理，优先保持编辑顺畅。")
        case .export: L10n.tr("配置 Pandoc 导出项目。")
        case .ai: L10n.tr("配置文本、判断和图像服务。")
        case .about: L10n.tr("一款专注于文本与代码的 macOS 编辑器。")
        }
    }
}

extension SettingsSection {
    /// L10n keys of the row titles on each page. Maintained by hand next to the pages;
    /// the test checks every key exists in all three catalogs.
    var searchKeys: [String] {
        switch self {
        case .editor:
            ["文字排版", "文字字体", "代码字体", "Markdown 最大宽度", "字体大小", "额外行距", "连字", "标题小型大写字母", "标题转为大写", "居中标题",
             "Markdown 文本对齐", "从右向左书写", "划掉已完成的任务", "自动编号标题", "列表标记", "竖排 Markdown", "Markdown 段落间距",
             "输入与显示", "缩进方式", "Tab 宽度", "自动配对括号与引号", "自动配对 Markdown 符号", "智能引号", "智能破折号", "系统文本替换",
             "严格解析 Markdown", "行内公式", "使用旧版行内公式规则", "启用 Physics 数学扩展", "公式自动编号", "大纲最大标题级别",
             "统计显示单位", "阅读速度", "每日字数目标", "自动换行", "显示行号"]
        case .images:
            ["图片上传", "上传方式", "插入时上传本地图片", "插入时上传网络图片", "允许文档指定上传", "允许文档指定图片文件夹", "全局图片文件夹",
             "上传地址", "PicList 密钥", "程序路径", "程序参数", "测试图片上传"]
        case .appearance:
            ["界面主题", "外观", "语言", "界面语言", "窗口界面", "显示状态栏", "Markdown 浅色外观颜色", "Markdown 深色外观颜色"]
        case .files:
            ["离开与继续", "启动文件夹", "模板与每日笔记", "模板文件夹", "每日笔记文件夹", "每日笔记日期格式", "本地恢复", "异常关闭保护"]
        case .associations:
            ["当前应用位置", "文件格式", "设为默认"]
        case .performance:
            ["自动性能管理", "标准模式", "大文件模式", "加强保护"]
        case .export:
            ["HTML 导出附加内容", "导出时保留连续空格", "附加到 head", "附加到 body", "允许文档 YAML 覆盖 HTML 导出设置",
             "PDF 页面设置", "纸张", "纸张宽度（点）", "纸张高度（点）", "顶级标题和脚注前分页", "自定义页边距", "上边距（点）", "下边距（点）",
             "左边距（点）", "右边距（点）", "PDF 页眉", "PDF 页脚", "允许文档 YAML 覆盖页眉和页脚",
             "图像导出设置", "图像宽度（点）", "图像质量", "自定义图像字体大小", "图像字体大小（点）",
             "重置导出设置", "删除不支持的导出项目", "添加 Pandoc 导出项目", "添加自定义命令", "添加 PDF 引擎导出项目",
             "扩展名，以空格分隔", "自定义命令", "命令输出", "显示命令输出", "PDF 中间格式", "PDF 引擎路径", "额外参数",
             "Pandoc 输出格式", "原始类型", "模板", "样式参考文件", "EPUB 封面", "EPUB 目录深度"]
        case .ai:
            ["AI 功能", "文本模型", "判断模型", "图像模型", "文字识别模型", "语音转写模型", "API 密钥", "服务地址", "模型名称", "自定义检查",
             "Jina 搜索", "Jina 网页读取", "系统拼写检查", "系统语法检查", "接口格式", "完整接口地址",
             "检查名称", "为功能选择模型", "整理听写文字的模型", "添加检查"]
        case .about:
            []
        }
    }
}

enum SettingsSearch {
    /// Sections whose title or any row title contains `query` (case/diacritic-insensitive,
    /// compared as localized text). Empty query keeps all sections.
    static func sections(matching query: String,
                         localize: (String) -> String = { L10n.tr($0) }) -> [SettingsSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            ([section.rawValue] + section.searchKeys).contains {
                localize($0).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

extension SettingsSearch {
    /// Localized title of the first row on the section page that matches `query`; nil when the query is empty
    /// or only the section title matched.
    static func firstMatchingTitle(in section: SettingsSection, query: String,
                                   localize: (String) -> String = { L10n.tr($0) }) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return section.searchKeys.map(localize).first {
            $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

enum SettingsNumberInput {
    /// Parses by the given locale; nil when not a number, not finite or outside `range`.
    static func parse(_ text: String, range: ClosedRange<Double>, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = formatter(locale).number(from: trimmed)?.doubleValue,
              value.isFinite, range.contains(value) else { return nil }
        return value
    }

    static func string(_ value: Double, locale: Locale = .current) -> String {
        formatter(locale).string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func formatter(_ locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter
    }
}

enum PicListEndpointInput {
    /// nil when the address is unusable (unparsable or not http(s) with a host). An empty string is allowed.
    static func parse(_ text: String) -> (endpoint: String, key: String?)? {
        guard let parsed = PicListKeychainStore.endpointWithoutKey(text) else { return nil }
        if !parsed.endpoint.isEmpty {
            guard let url = URL(string: parsed.endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        }
        return parsed
    }
}

private struct SettingsScrollRequest: Equatable {
    let section: SettingsSection
    let title: String
    let token = UUID()
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(L10n.languageKey) private var appLanguage = "system"
    @State private var selection: SettingsSection
    @State private var visited: Set<SettingsSection>
    @State private var listStyleDepth = 1
    @State private var query = ""
    @State private var scrollRequest: SettingsScrollRequest?
    @State private var highlightedTitle: String?

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    init(initialSection: SettingsSection = .editor) {
        _selection = State(initialValue: initialSection)
        _visited = State(initialValue: [initialSection])
    }

    private func orderedListStyleName(_ style: MarkdownOrderedListStyle) -> String {
        switch style {
        case .decimal: return L10n.tr("数字")
        case .decimalLeadingZero: return L10n.tr("数字（前导零）")
        case .cjkIdeographic: return L10n.tr("中文数字")
        case .hiragana: return L10n.tr("平假名")
        case .katakana: return L10n.tr("片假名")
        case .lowerAlpha: return L10n.tr("小写字母")
        case .upperAlpha: return L10n.tr("大写字母")
        case .lowerGreek: return L10n.tr("希腊字母")
        case .lowerRoman: return L10n.tr("小写罗马数字")
        case .upperRoman: return L10n.tr("大写罗马数字")
        }
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
        .environment(\.settingsHighlightedTitle, highlightedTitle)
    }

    private func select(_ section: SettingsSection) {
        visited.insert(section)
        selection = section
        scrollRequest = SettingsSearch.firstMatchingTitle(in: section, query: query).map { SettingsScrollRequest(section: section, title: $0) }
        highlightedTitle = nil
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("设置")).font(.title.weight(.semibold))
                .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 12)
            TextField(L10n.tr("搜索设置"), text: $query)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .padding(.horizontal, 12).padding(.bottom, 10)
                .accessibilityIdentifier("settings.search")
                .onExitCommand { if !query.isEmpty { query = "" } }
                .onSubmit {
                    if let first = SettingsSearch.sections(matching: query).first { select(first) }
                }
            let matches = SettingsSearch.sections(matching: query)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(matches) { section in
                        SettingsNavigationRow(section: section, selected: selection == section) { select(section) }
                    }
                    if matches.isEmpty {
                        Text(L10n.tr("没有匹配的设置")).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 5) {
                Text(AppEnvironment.displayName).font(.subheadline.weight(.medium))
                Text(AppEnvironment.isExperiment ? L10n.tr("界面实验 · %@", String(describing: AppEnvironment.experimentIteration)) : L10n.tr("本地编辑，专注文字"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(width: 240)
        .background(SidebarMaterialBackground())
    }

    private func page(_ section: SettingsSection) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.tr(section.rawValue)).font(.title.weight(.semibold))
                        Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
                    }.padding(.bottom, 3)
                    pageContents(section)
                    Spacer(minLength: 0)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(NativeScrollViewConfigurator())
            }
            .scrollContentBackground(.hidden)
            .task(id: scrollRequest) {
                defer { if Task.isCancelled || scrollRequest == nil { highlightedTitle = nil } }
                guard let request = scrollRequest, request.section == section else { return }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                proxy.scrollTo(request.title, anchor: .top)
                highlightedTitle = request.title
                try? await Task.sleep(for: .milliseconds(1600))
                guard !Task.isCancelled, highlightedTitle == request.title else { return }
                if reduceMotion { highlightedTitle = nil } else { withAnimation(.easeOut(duration: 0.3)) { highlightedTitle = nil } }
            }
        }
    }

    @ViewBuilder private func pageContents(_ section: SettingsSection) -> some View {
        switch section {
        case .editor: editorSettings
        case .images: MarkdownImageUploadSettingsView(preferences: appState.preferences, isActive: selection == .images)
        case .appearance: appearanceSettings
        case .files: fileSettings
        case .associations: FileAssociationSettingsView()
        case .performance: performanceSettings
        case .export: MarkdownExportSettingsView(preferences: appState.preferences)
        case .ai: AISettingsView(preferences: appState.preferences, isActive: selection == .ai)
        case .about: aboutSettings
        }
    }

    private var editorSettings: some View {
        VStack(spacing: 20) {
            PreferenceGroup(title: L10n.tr("文字排版")) {
                PreferenceRow(title: L10n.tr("文字字体"), detail: L10n.tr("用于正文和编辑器。")) {
                    fontFamilyPicker(Binding(get: { appState.preferences.editorTextFontFamily },
                                             set: { appState.preferences.editorTextFontFamily = $0 }))
                }
                rowDivider
                PreferenceRow(title: L10n.tr("代码字体"), detail: L10n.tr("用于 Markdown 代码。")) {
                    fontFamilyPicker(Binding(get: { appState.preferences.editorCodeFontFamily },
                                             set: { appState.preferences.editorCodeFontFamily = $0 }))
                }
                rowDivider
                PreferenceRow(title: L10n.tr("Markdown 最大宽度"), detail: L10n.tr("自动换行时居中显示，默认限制为 %d 点。", Int(AppPreferences.defaultMarkdownMaximumWidth))) {
                    HStack {
                        Toggle(L10n.tr("限制 Markdown 宽度"), isOn: Binding(
                            get: { appState.preferences.markdownMaximumWidth != nil },
                            set: { appState.preferences.markdownMaximumWidth = $0 ? AppPreferences.defaultMarkdownMaximumWidth : nil }
                        )).labelsHidden().toggleStyle(.switch)
                        if appState.preferences.markdownMaximumWidth != nil {
                            VStack(alignment: .trailing, spacing: 4) {
                                TextField(L10n.tr("宽度（点）"), value: Binding(
                                    get: { appState.preferences.markdownMaximumWidth ?? AppPreferences.defaultMarkdownMaximumWidth },
                                    set: { appState.preferences.markdownMaximumWidth = $0 }
                                ), format: .number).frame(width: 80)
                                Text(L10n.tr("须大于 0")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("字体大小"), detail: L10n.tr("所有标签共用，默认 14 pt。")) {
                    HStack(spacing: 12) {
                        Stepper(L10n.tr("%d pt", Int(appState.editorFontSize)), value: $appState.editorFontSize, in: 9...32)
                            .monospacedDigit().accessibilityLabel(L10n.tr("字体大小"))
                        resetButton(disabled: appState.isUsingDefaultFontSize, help: L10n.tr("恢复默认字体大小（⌘0）"), action: appState.resetFontSize)
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("额外行距"), detail: L10n.tr("在固定行高之外增加间距，默认 4 pt。")) {
                    HStack(spacing: 12) {
                        Stepper(L10n.tr("%d pt", Int(appState.editorLineSpacing)), value: $appState.editorLineSpacing, in: 0...10)
                            .monospacedDigit().accessibilityLabel(L10n.tr("额外行距"))
                        resetButton(disabled: appState.isUsingDefaultLineSpacing, help: L10n.tr("恢复默认行距"), action: appState.resetLineSpacing)
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("连字"), detail: L10n.tr("控制字体支持的字符连写。")) {
                    Picker(L10n.tr("连字"), selection: Binding(
                        get: { appState.preferences.editorLigatures ?? -1 },
                        set: { appState.preferences.editorLigatures = $0 < 0 ? nil : $0 }
                    )) {
                        Text(L10n.tr("保持原样")).tag(-1)
                        Text(L10n.tr("关闭")).tag(0)
                        Text(L10n.tr("标准")).tag(1)
                        Text(L10n.tr("全部可用")).tag(2)
                    }.labelsHidden().frame(width: 156)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("标题小型大写字母"), detail: L10n.tr("仅对选中的标题级别启用；编辑器字体不支持时保持原样，预览可能合成字形。")) {
                    HStack(spacing: 8) {
                        ForEach(1...6, id: \.self) { level in
                            Toggle("H\(level)", isOn: Binding(
                                get: { appState.preferences.markdownSmallCapsLevels.contains(level) },
                                set: { enabled in
                                    if enabled { appState.preferences.markdownSmallCapsLevels.insert(level) }
                                    else { appState.preferences.markdownSmallCapsLevels.remove(level) }
                                }
                            )).toggleStyle(.checkbox)
                        }
                        if !appState.preferences.markdownSmallCapsLevels.isEmpty && !FoldLayoutManager.supportsSmallCaps(
                            NSFontManager.shared.convert(AppPreferences.textFont(family: appState.preferences.editorTextFontFamily,
                                                                                  size: appState.preferences.editorFontSize), toHaveTrait: .boldFontMask)
                        ) {
                            Image(systemName: "exclamationmark.triangle")
                                .help(L10n.tr("当前字体不支持小型大写字母"))
                                .accessibilityLabel(L10n.tr("当前字体不支持小型大写字母"))
                        }
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("标题转为大写"), detail: L10n.tr("仅改变选中标题级别的显示，不修改原文。")) {
                    HStack(spacing: 8) {
                        ForEach(1...6, id: \.self) { level in
                            Toggle("H\(level)", isOn: Binding(
                                get: { appState.preferences.markdownUppercaseHeadingLevels.contains(level) },
                                set: { enabled in
                                    if enabled { appState.preferences.markdownUppercaseHeadingLevels.insert(level) }
                                    else { appState.preferences.markdownUppercaseHeadingLevels.remove(level) }
                                }
                            )).toggleStyle(.checkbox)
                        }
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("居中标题"), detail: L10n.tr("将选中的标题级别居中。")) {
                    HStack(spacing: 8) {
                        ForEach(1...6, id: \.self) { level in
                            Toggle("H\(level)", isOn: Binding(
                                get: { appState.preferences.markdownCenteredHeadingLevels.contains(level) },
                                set: { enabled in
                                    if enabled { appState.preferences.markdownCenteredHeadingLevels.insert(level) }
                                    else { appState.preferences.markdownCenteredHeadingLevels.remove(level) }
                                }
                            )).toggleStyle(.checkbox)
                        }
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("Markdown 文本对齐"), detail: L10n.tr("控制文档的水平对齐方式。")) {
                    Picker(L10n.tr("Markdown 文本对齐"), selection: Binding(
                        get: { appState.preferences.markdownTextAlignment?.rawValue ?? "" },
                        set: { appState.preferences.markdownTextAlignment = MarkdownTextAlignment(rawValue: $0) }
                    )) {
                        Text(L10n.tr("保持原样")).tag("")
                        Text(L10n.tr("左对齐")).tag("left")
                        Text(L10n.tr("居中")).tag("center")
                        Text(L10n.tr("右对齐")).tag("right")
                        Text(L10n.tr("两端对齐")).tag("justify")
                    }.labelsHidden().frame(width: 156)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("从右向左书写"), detail: L10n.tr("设置 Markdown 的基础书写方向。")) {
                    Toggle(L10n.tr("从右向左书写"), isOn: Binding(
                        get: { appState.preferences.markdownRightToLeft },
                        set: { appState.preferences.markdownRightToLeft = $0 }
                    ))
                        .labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("划掉已完成的任务"), detail: L10n.tr("自动为已完成的任务添加删除线。")) {
                    Toggle(L10n.tr("划掉已完成的任务"), isOn: Binding(
                        get: { appState.preferences.markdownStrikeCompletedTasks },
                        set: { appState.preferences.markdownStrikeCompletedTasks = $0 }
                    ))
                        .labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("自动编号标题"), detail: L10n.tr("在标题、目录和大纲中显示层级编号。")) {
                    Toggle(L10n.tr("自动编号标题"), isOn: Binding(
                        get: { appState.preferences.markdownNumberHeadings },
                        set: { appState.preferences.markdownNumberHeadings = $0 }
                    ))
                        .labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("列表标记"), detail: L10n.tr("设置指定嵌套层级；未设置的层级继承较浅层级。")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.tr("层级"))
                            TextField(L10n.tr("层级"), value: Binding(
                                get: { listStyleDepth }, set: { listStyleDepth = max(1, $0) }
                            ), format: .number).frame(width: 64)
                        }
                        Picker(L10n.tr("有序列表"), selection: Binding(
                            get: { appState.preferences.markdownListStyles.ordered[listStyleDepth]?.rawValue ?? "" },
                            set: { appState.preferences.markdownListStyles.ordered[listStyleDepth] = MarkdownOrderedListStyle(rawValue: $0) }
                        )) {
                            Text(L10n.tr("继承")).tag("")
                            ForEach(MarkdownOrderedListStyle.allCases, id: \.self) { style in
                                Text(orderedListStyleName(style)).tag(style.rawValue)
                            }
                        }
                        Picker(L10n.tr("无序列表"), selection: Binding(
                            get: { appState.preferences.markdownListStyles.unordered[listStyleDepth]?.rawValue ?? "" },
                            set: { appState.preferences.markdownListStyles.unordered[listStyleDepth] = MarkdownUnorderedListStyle(rawValue: $0) }
                        )) {
                            Text(L10n.tr("继承")).tag("")
                            Text(L10n.tr("实心圆")).tag(MarkdownUnorderedListStyle.disc.rawValue)
                            Text(L10n.tr("空心圆")).tag(MarkdownUnorderedListStyle.circle.rawValue)
                            Text(L10n.tr("方块")).tag(MarkdownUnorderedListStyle.square.rawValue)
                            Text(L10n.tr("自定义文本")).tag(MarkdownUnorderedListStyle.custom.rawValue)
                        }
                        if appState.preferences.markdownListStyles.unordered[listStyleDepth] == .custom {
                            TextField(L10n.tr("标记文本"), text: Binding(
                                get: { appState.preferences.markdownListStyles.customMarkers[listStyleDepth] ?? "" },
                                set: { appState.preferences.markdownListStyles.customMarkers[listStyleDepth] = $0 }
                            ))
                        }
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("竖排 Markdown"), detail: L10n.tr("在排版视图中竖排显示文本。")) {
                    Toggle(L10n.tr("竖排 Markdown"), isOn: Binding(
                        get: { appState.preferences.markdownVerticalWriting },
                        set: { appState.preferences.markdownVerticalWriting = $0 }
                    ))
                        .labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("Markdown 段落间距"), detail: L10n.tr("设置普通段落之间的间距。")) {
                    HStack {
                        Toggle(L10n.tr("设置段落间距"), isOn: Binding(
                            get: { appState.preferences.markdownParagraphSpacing != nil },
                            set: { appState.preferences.markdownParagraphSpacing = $0 ? 12 : nil }
                        )).labelsHidden().toggleStyle(.switch)
                        if appState.preferences.markdownParagraphSpacing != nil {
                            VStack(alignment: .trailing, spacing: 4) {
                                TextField(L10n.tr("间距（点）"), value: Binding(
                                    get: { appState.preferences.markdownParagraphSpacing ?? 0 },
                                    set: { appState.preferences.markdownParagraphSpacing = $0 }
                                ), format: .number).frame(width: 80)
                                Text(L10n.tr("不能为负数")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
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
                PreferenceRow(title: L10n.tr("自动配对括号与引号"), detail: L10n.tr("在 Markdown 中自动配对括号与引号。")) {
                    Toggle(L10n.tr("自动配对括号与引号"), isOn: Binding(get: { appState.preferences.autoPairBracketsEnabled }, set: { appState.preferences.autoPairBracketsEnabled = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("自动配对 Markdown 符号"), detail: L10n.tr("在 Markdown 中自动配对标记符号。")) {
                    Toggle(L10n.tr("自动配对 Markdown 符号"), isOn: Binding(get: { appState.preferences.autoPairMarkdownEnabled }, set: { appState.preferences.autoPairMarkdownEnabled = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("智能引号"), detail: L10n.tr("使用 macOS 的智能引号。")) {
                    Toggle(L10n.tr("智能引号"), isOn: Binding(get: { appState.preferences.smartQuotesEnabled }, set: { appState.preferences.smartQuotesEnabled = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("智能破折号"), detail: L10n.tr("使用 macOS 的智能破折号。")) {
                    Toggle(L10n.tr("智能破折号"), isOn: Binding(get: { appState.preferences.smartDashesEnabled }, set: { appState.preferences.smartDashesEnabled = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("系统文本替换"), detail: L10n.tr("使用 macOS 键盘设置中的文本替换。")) {
                    Toggle(L10n.tr("系统文本替换"), isOn: Binding(get: { appState.preferences.systemTextReplacementEnabled }, set: { appState.preferences.systemTextReplacementEnabled = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("严格解析 Markdown"), detail: L10n.tr("要求标题标记后有空格，列表内容使用完整缩进。")) {
                    Toggle(L10n.tr("严格解析 Markdown"), isOn: Binding(get: { appState.preferences.markdownStrictMode }, set: { appState.preferences.markdownStrictMode = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("行内公式"), detail: L10n.tr("识别 $…$ 行内公式；独立公式不受影响。")) {
                    Toggle(L10n.tr("行内公式"), isOn: Binding(get: { appState.preferences.markdownInlineMath }, set: { appState.preferences.markdownInlineMath = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("使用旧版行内公式规则"), detail: L10n.tr("使用兼容旧版的行内公式边界规则。")) {
                    Toggle(L10n.tr("使用旧版行内公式规则"), isOn: Binding(get: { appState.preferences.markdownLegacyInlineMath }, set: { appState.preferences.markdownLegacyInlineMath = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("启用 Physics 数学扩展"), detail: L10n.tr("自动加载 Physics 命令；公式仍可显式加载。")) {
                    Toggle(L10n.tr("启用 Physics 数学扩展"), isOn: Binding(get: { appState.preferences.mathPhysicsEnabled }, set: { appState.preferences.mathPhysicsEnabled = $0 })).labelsHidden().toggleStyle(.switch)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("公式自动编号"), detail: L10n.tr("选择独立公式的自动编号方式。")) {
                    Picker(L10n.tr("公式自动编号"), selection: Binding(get: { appState.preferences.mathNumbering }, set: { appState.preferences.mathNumbering = $0 })) {
                        Text(L10n.tr("不自动编号")).tag(MarkdownMathNumbering.none)
                        Text(L10n.tr("AMS 编号")).tag(MarkdownMathNumbering.ams)
                        Text(L10n.tr("所有公式编号")).tag(MarkdownMathNumbering.all)
                    }.labelsHidden().frame(width: 156)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("大纲最大标题级别"), detail: L10n.tr("选择大纲中显示的标题级别。")) {
                    Picker(L10n.tr("大纲最大标题级别"), selection: Binding(
                        get: { appState.preferences.markdownTOCMaxLevel },
                        set: { appState.preferences.markdownTOCMaxLevel = $0 }
                    )) {
                        ForEach(1...6, id: \.self) { Text("H\($0)").tag($0) }
                    }.labelsHidden().frame(width: 156)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("统计显示单位"), detail: L10n.tr("选择状态栏显示的统计值。")) {
                    Picker(L10n.tr("统计显示单位"), selection: Binding(get: { appState.preferences.statisticsDisplayUnit }, set: { appState.preferences.statisticsDisplayUnit = $0 })) {
                        ForEach(StatisticsDisplayUnit.allCases) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(width: 156)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("阅读速度"), detail: L10n.tr("用于估计阅读时间，单位为词每分钟。")) {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField(L10n.tr("阅读速度"), value: Binding(get: { appState.preferences.readingWordsPerMinute }, set: { appState.preferences.readingWordsPerMinute = $0 }), format: .number)
                            .labelsHidden().frame(width: 156)
                        Text(L10n.tr("须为大于 0 的整数")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("每日字数目标"), detail: L10n.tr("在状态栏显示今天已写的词数。0 表示关闭。")) {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField(L10n.tr("每日字数目标"), value: Binding(get: { appState.preferences.dailyWordGoal }, set: { appState.preferences.dailyWordGoal = $0 }), format: .number)
                            .labelsHidden().frame(width: 156)
                        Text(L10n.tr("0 至 1000000 的整数")).font(.caption).foregroundStyle(.secondary)
                    }
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
                    Text(L10n.tr("外观")).font(.body.weight(.medium))
                    HStack(spacing: 12) {
                        ForEach(AppTheme.allCases) { theme in
                            ThemeChoice(theme: theme, selected: appState.theme == theme) { appState.theme = theme }
                        }
                    }
                    Text(L10n.tr("跟随系统时，界面会随 macOS 的浅色与深色设置切换。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(16)
            }
            markdownColorSettings(darkMode: false)
            markdownColorSettings(darkMode: true)
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
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdownColorSettings(darkMode: Bool) -> some View {
        PreferenceGroup(title: L10n.tr(darkMode ? "Markdown 深色外观颜色" : "Markdown 浅色外观颜色")) {
            ForEach(MarkdownColorOverrides.Field.allCases) { field in
                HStack(spacing: 12) {
                    Text(L10n.tr(field.label)).font(.body.weight(.medium))
                    Spacer()
                    ColorPicker(L10n.tr(field.label), selection: Binding(
                        get: { Color(nsColor: appState.preferences.markdownColors(darkMode: darkMode)[field]?.nsColor ?? defaultMarkdownColor(field, darkMode: darkMode)) },
                        set: { if let color = MarkdownSRGBColor(NSColor($0)) { updateMarkdownColor(color, field: field, darkMode: darkMode) } }
                    )).labelsHidden()
                    Button { updateMarkdownColor(nil, field: field, darkMode: darkMode) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }.buttonStyle(.plain).help(L10n.tr("恢复默认颜色"))
                        .accessibilityLabel(L10n.tr("恢复默认颜色"))
                        .disabled(appState.preferences.markdownColors(darkMode: darkMode)[field] == nil)
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private func updateMarkdownColor(_ color: MarkdownSRGBColor?, field: MarkdownColorOverrides.Field, darkMode: Bool) {
        var colors = appState.preferences.markdownColors(darkMode: darkMode)
        colors[field] = color
        if darkMode { appState.preferences.markdownDarkColors = colors }
        else { appState.preferences.markdownLightColors = colors }
    }

    private func defaultMarkdownColor(_ field: MarkdownColorOverrides.Field, darkMode: Bool) -> NSColor {
        let base: NSColor
        switch field {
        case .text: base = .labelColor
        case .background: base = .lacEditorBackground
        case .link: base = .linkColor
        case .codeBackground, .quoteBackground: base = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        }
        var resolved = base
        NSAppearance(named: darkMode ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = base.usingColorSpace(.sRGB) ?? base
        }
        return resolved
    }

    private var fileSettings: some View {
        VStack(spacing: 20) {
            PreferenceGroup(title: L10n.tr("离开与继续")) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.tr("退出应用时")).font(.body.weight(.medium))
                    Picker(L10n.tr("退出应用时"), selection: $appState.workspaceExitBehavior) {
                        ForEach(WorkspaceExitBehavior.allCases) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(maxWidth: 310)
                    Text(L10n.tr("保留工作区会在本机记录窗口、标签和未保存内容，下次启动继续恢复。不会因此覆盖磁盘中的原文件。"))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
                rowDivider
                PreferenceRow(title: L10n.tr("启动文件夹"), detail: L10n.tr("留空时启动不打开默认文件夹。")) {
                    HStack {
                        TextField(L10n.tr("未设置"), text: Binding(
                            get: { appState.preferences.startupFolderPath },
                            set: { appState.preferences.startupFolderPath = $0 }
                        )).frame(width: 180).accessibilityLabel(L10n.tr("启动文件夹"))
                        Button(L10n.tr("选择…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { appState.preferences.startupFolderPath = url.path }
                        }
                    }
                }
            }
            PreferenceGroup(title: L10n.tr("模板与每日笔记")) {
                PreferenceRow(title: L10n.tr("模板文件夹"), detail: L10n.tr("留空时无法使用“从模板新建笔记”。")) {
                    HStack {
                        TextField(L10n.tr("未设置"), text: Binding(
                            get: { appState.preferences.templatesFolderPath },
                            set: { appState.preferences.templatesFolderPath = $0 }
                        )).frame(width: 180).accessibilityLabel(L10n.tr("模板文件夹"))
                        Button(L10n.tr("选择…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { appState.preferences.templatesFolderPath = url.path }
                        }
                    }
                }
                rowDivider
                PreferenceRow(title: L10n.tr("每日笔记文件夹"), detail: L10n.tr("相对于工作文件夹；留空表示工作文件夹根目录。")) {
                    TextField(L10n.tr("未设置"), text: Binding(
                        get: { appState.preferences.dailyNotesFolder },
                        set: { appState.preferences.dailyNotesFolder = $0 }
                    )).frame(width: 180).accessibilityLabel(L10n.tr("每日笔记文件夹"))
                }
                rowDivider
                PreferenceRow(title: L10n.tr("每日笔记日期格式"), detail: L10n.tr("用于文件名，默认 yyyy-MM-dd；不能包含 / 或 :。")) {
                    TextField(NoteTemplateService.defaultDateFormat, text: Binding(
                        get: { appState.preferences.dailyNoteDateFormat },
                        set: { appState.preferences.dailyNoteDateFormat = $0 }
                    )).frame(width: 180).accessibilityLabel(L10n.tr("每日笔记日期格式"))
                }
            }
            PreferenceGroup(title: L10n.tr("本地恢复")) {
                PreferenceRow(title: L10n.tr("异常关闭保护"), detail: L10n.tr("未保存内容保留在本机恢复目录。恢复副本与主动保存文件是两回事。")) {
                    Label(L10n.tr("本地保留"), systemImage: "internaldrive").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if AppEnvironment.isExperiment {
                Label(L10n.tr("实验版的工作区、收藏和设置与正式版分别存放。"), systemImage: "square.stack.3d.up")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private static let largeThresholdMB = DocumentPerformanceProfile.largeFileByteThreshold / (1_024 * 1_024)
    private static let extremeThresholdMB = DocumentPerformanceProfile.extremeFileByteThreshold / (1_024 * 1_024)
    private static var largeThresholdLines: String {
        DocumentPerformanceProfile.largeFileLineThreshold.formatted(.number.locale(Locale(identifier: L10n.languageCode)))
    }

    private var performanceSettings: some View {
        VStack(spacing: 20) {
            PreferenceGroup(title: L10n.tr("自动性能管理")) {
                PreferenceRow(title: L10n.tr("标准模式"), detail: L10n.tr("日常文档保持完整编辑、预览和高亮能力。")) {
                    Text(L10n.tr("默认")).font(.subheadline).foregroundStyle(.secondary)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("大文件模式"), detail: L10n.tr("超过 %d MB 或 %@ 行时自动启用，暂停换行、预览、折叠和实时字数统计。", Self.largeThresholdMB, Self.largeThresholdLines)) {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(LacEditorDesign.accent).accessibilityHidden(true)
                }
                rowDivider
                PreferenceRow(title: L10n.tr("加强保护"), detail: L10n.tr("超过 %d MB 时额外暂停语法高亮，仍可继续打开与编辑。", Self.extremeThresholdMB)) {
                    Text(L10n.tr("%d MB 以上", Self.extremeThresholdMB)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(L10n.tr("这些阈值由应用自动管理。可从当前文档的「大文件模式」菜单临时恢复功能，不会改写全局设置。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 7) {
                    Text(AppEnvironment.displayName).font(.title2.weight(.semibold))
                    Text(versionDescription).font(.callout).foregroundStyle(.secondary)
                    Text(L10n.tr("macOS 26 及以上 · Apple Silicon")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            PreferenceGroup(title: L10n.tr("关于这款编辑器")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("打开即写，轻装编辑。暂无登录、云同步或文档内容采集。"))
                    Text(L10n.tr("界面基于 SwiftUI 与 AppKit；编辑使用 TextKit，语法解析使用 Tree-sitter，Markdown 使用 cmark-gfm。"))
                        .foregroundStyle(.secondary)
                    Link(L10n.tr("查看项目与开源说明 ↗"), destination: URL(string: "https://github.com/LKosoj/LacEditor")!)
                }.font(.callout).padding(16)
            }
        }
    }

    private var rowDivider: some View { Divider().padding(.horizontal, 16).opacity(0.5) }
    private func fontFamilyPicker(_ family: Binding<String?>) -> some View {
        let families = Self.fontFamilies
        return Picker(L10n.tr("字体"), selection: Binding(get: { family.wrappedValue ?? "" }, set: { family.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text(L10n.tr("系统默认")).tag("")
            if let current = family.wrappedValue, !families.contains(current) {
                Text(L10n.tr("不可用：%@", current)).tag(current)
            }
            ForEach(families, id: \.self) { name in Text(name).tag(name) }
        }.labelsHidden().frame(width: 180)
    }
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
                Text(L10n.tr(section.rawValue))
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
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
                }.font(.subheadline.weight(selected ? .medium : .regular))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.tr(theme.rawValue))
            .focused($focused).editorFocusRing(focused)
            .accessibilityIdentifier("settings.theme.\(theme.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MarkdownImageUploadSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let isActive: Bool
    @State private var validationTask: Task<Void, Never>?
    @State private var validationID: UUID?
    @State private var validationStatus: StatusMessage?
    @State private var picListKey = ""
    @State private var picListDraft = ""
    @State private var picListEndpointError = false
    @FocusState private var picListEndpointFocused: Bool

    var body: some View {
        PreferenceGroup(title: L10n.tr("图片上传")) {
            PreferenceRow(title: L10n.tr("上传方式"), detail: L10n.tr("选择使用的图片上传程序或服务。")) {
                Picker(L10n.tr("上传方式"), selection: $preferences.markdownImageUploadConfiguration.method) {
                    Text(L10n.tr("关闭")).tag("disabled")
                    Text("PicGo").tag("picgo")
                    Text("PicList").tag("piclist")
                    Text("uPic").tag("upic")
                    Text("iPic").tag("ipic")
                    Text("Picsee").tag("picsee")
                    Text(L10n.tr("自定义程序")).tag("command")
                }.labelsHidden().frame(width: 156)
            }
            Divider().padding(.horizontal, 16).opacity(0.5)
            PreferenceRow(title: L10n.tr("插入时上传本地图片"), detail: L10n.tr("选择文件、粘贴或拖入图片时自动上传。")) {
                Toggle(L10n.tr("插入时上传本地图片"), isOn: $preferences.markdownImageUploadConfiguration.automaticLocal).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.horizontal, 16).opacity(0.5)
            PreferenceRow(title: L10n.tr("插入时上传网络图片"), detail: L10n.tr("重新下载并上传通过 URL 插入的图片。")) {
                Toggle(L10n.tr("插入时上传网络图片"), isOn: $preferences.markdownImageUploadConfiguration.automaticOnline).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.horizontal, 16).opacity(0.5)
            PreferenceRow(title: L10n.tr("允许文档指定上传"), detail: L10n.tr("允许文档的 YAML 设置决定插入时上传图片。")) {
                Toggle(L10n.tr("允许文档指定上传"), isOn: $preferences.markdownImageUploadConfiguration.allowDocumentPolicy).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.horizontal, 16).opacity(0.5)
            PreferenceRow(title: L10n.tr("允许文档指定图片文件夹"), detail: L10n.tr("允许文档的 YAML 设置决定图片复制位置。")) {
                Toggle(L10n.tr("允许文档指定图片文件夹"), isOn: $preferences.markdownImageUploadConfiguration.allowDocumentCopy).labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.horizontal, 16).opacity(0.5)
            PreferenceRow(title: L10n.tr("全局图片文件夹"), detail: L10n.tr("留空时不复制；全局自动上传优先。")) {
                HStack {
                    TextField(L10n.tr("未设置"), text: $preferences.markdownImageUploadConfiguration.copyFolder).frame(width: 180)
                        .accessibilityLabel(L10n.tr("全局图片文件夹"))
                    Button(L10n.tr("选择…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { preferences.markdownImageUploadConfiguration.copyFolder = url.path }
                    }
                }
            }
            if preferences.markdownImageUploadConfiguration.method == "picgo" {
                Divider().padding(.horizontal, 16).opacity(0.5)
                PreferenceRow(title: L10n.tr("上传地址"), detail: L10n.tr("填写已运行的 PicGo 上传地址。")) {
                    TextField("https://…/upload", text: $preferences.markdownImageUploadConfiguration.endpoint).frame(width: 220)
                        .accessibilityLabel(L10n.tr("上传地址"))
                }
            } else if preferences.markdownImageUploadConfiguration.method == "piclist" {
                Divider().padding(.horizontal, 16).opacity(0.5)
                PreferenceRow(title: L10n.tr("上传地址"), detail: L10n.tr("填写已运行的 PicList 上传地址，不含密钥。")) {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("https://…/upload", text: $picListDraft).frame(width: 220)
                            .focused($picListEndpointFocused)
                            .accessibilityLabel(L10n.tr("上传地址"))
                            .onSubmit { commitPicListEndpoint() }
                            .onChange(of: picListEndpointFocused) { _, focused in if !focused { commitPicListEndpoint() } }
                        if picListEndpointError {
                            StatusMessageView(kind: .error, text: L10n.tr("图片或上传设置无效"))
                                .frame(width: 220, alignment: .leading)
                        }
                    }
                }
                Divider().padding(.horizontal, 16).opacity(0.5)
                PreferenceRow(title: L10n.tr("PicList 密钥"), detail: L10n.tr("远程服务的密钥保存在系统钥匙串中。")) {
                    HStack {
                        SecureField(L10n.tr("可选密钥"), text: $picListKey).frame(width: 160)
                        Button(L10n.tr("保存密钥")) { commitPicListEndpoint(); if !picListEndpointError { savePicListKey() } }.disabled(picListEndpointError)
                    }
                }
            } else if preferences.markdownImageUploadConfiguration.method == "ipic" {
                Text(L10n.tr("iPic 必须已安装并配置。取消不会停止 iPic 中已开始的上传。"))
                    .font(.subheadline).foregroundStyle(.secondary).padding(16)
            } else if preferences.markdownImageUploadConfiguration.method == "upic" {
                Divider().padding(.horizontal, 16).opacity(0.5)
                PreferenceRow(title: L10n.tr("程序路径"), detail: L10n.tr("填写 uPic 可执行文件路径。")) {
                    TextField("/Applications/uPic.app/Contents/MacOS/uPic", text: $preferences.markdownImageUploadConfiguration.executable).frame(width: 220)
                        .accessibilityLabel(L10n.tr("程序路径"))
                }
            } else if preferences.markdownImageUploadConfiguration.method == "picsee" {
                Divider().padding(.horizontal, 16).opacity(0.5)
                PreferenceRow(title: L10n.tr("程序路径"), detail: L10n.tr("填写 Picsee 可执行文件路径。")) {
                    TextField("/Applications/Picsee.app/Contents/MacOS/Picsee", text: $preferences.markdownImageUploadConfiguration.executable).frame(width: 220)
                        .accessibilityLabel(L10n.tr("程序路径"))
                }
            } else if preferences.markdownImageUploadConfiguration.method == "command" {
                Divider().padding(.horizontal, 16).opacity(0.5)
                PreferenceRow(title: L10n.tr("程序路径"), detail: L10n.tr("程序以当前用户权限运行。")) {
                    TextField("/path/to/program", text: $preferences.markdownImageUploadConfiguration.executable).frame(width: 220)
                        .accessibilityLabel(L10n.tr("程序路径"))
                }
                Divider().padding(.horizontal, 16).opacity(0.5)
                PreferenceRow(title: L10n.tr("程序参数"), detail: L10n.tr("每行一个参数；图片路径会追加在最后。")) {
                    TextEditor(text: $preferences.markdownImageUploadConfiguration.arguments).settingsMultilineField(minHeight: 80).frame(width: 220, height: 80)
                        .accessibilityLabel(L10n.tr("程序参数"))
                }
            }
            Divider().padding(.horizontal, 16).opacity(0.5)
            PreferenceRow(title: L10n.tr("测试图片上传"), detail: L10n.tr("发送一张测试图片并显示返回地址。")) {
                HStack {
                    if validationTask != nil {
                        Button(L10n.tr("取消")) { cancelValidation() }
                    } else {
                        Button(L10n.tr("测试")) { validateUploader() }
                            .disabled(!["picgo", "piclist", "upic", "ipic", "picsee", "command"].contains(preferences.markdownImageUploadConfiguration.method))
                    }
                }
            }
            if let validationStatus {
                StatusMessageView(kind: validationStatus.kind, text: validationStatus.text)
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { normalizePicListEndpoint(); loadPicListKey() }
        .onChange(of: preferences.markdownImageUploadConfiguration.endpoint) { _, endpoint in
            if !picListEndpointFocused { picListDraft = endpoint }
            loadPicListKey()
        }
        .onChange(of: preferences.markdownImageUploadConfiguration.method) { _, _ in normalizePicListEndpoint(); loadPicListKey() }
        .onChange(of: preferences.markdownImageUploadConfiguration) { _, _ in cancelValidation() }
        .onChange(of: isActive) { _, active in if !active { cancelValidation() } }
        .onDisappear {
            cancelValidation()
            if preferences.markdownImageUploadConfiguration.method == "piclist", PicListEndpointInput.parse(picListDraft) != nil { commitPicListEndpoint() }
        }
    }

    private func normalizePicListEndpoint() {
        let endpoint = preferences.markdownImageUploadConfiguration.endpoint
        picListDraft = endpoint
        picListEndpointError = false
        guard preferences.markdownImageUploadConfiguration.method == "piclist" else { return }
        if PicListEndpointInput.parse(endpoint) == nil { picListEndpointError = true; return }
        commitPicListEndpoint()
    }

    private func commitPicListEndpoint() {
        guard let parsed = PicListEndpointInput.parse(picListDraft), parsed.key == nil || !parsed.endpoint.isEmpty else {
            picListEndpointError = true
            return
        }
        picListEndpointError = false
        if parsed.endpoint != preferences.markdownImageUploadConfiguration.endpoint {
            preferences.markdownImageUploadConfiguration.endpoint = parsed.endpoint
        }
        picListDraft = parsed.endpoint
        if let key = parsed.key {
            picListKey = key
            savePicListKey()
        }
    }

    private func loadPicListKey() {
        guard preferences.markdownImageUploadConfiguration.method == "piclist" else { picListKey = ""; return }
        picListKey = (try? PicListKeychainStore().load(endpoint: preferences.markdownImageUploadConfiguration.endpoint)) ?? ""
    }

    private func savePicListKey() {
        do {
            try PicListKeychainStore().save(picListKey, endpoint: preferences.markdownImageUploadConfiguration.endpoint)
            validationStatus = StatusMessage(kind: .success, text: L10n.tr("密钥已保存"))
        } catch { validationStatus = StatusMessage(kind: .error, text: error.localizedDescription) }
    }

    private func cancelValidation() {
        validationID = nil
        validationTask?.cancel()
        validationTask = nil
        validationStatus = nil
    }

    private func validateUploader() {
        if preferences.markdownImageUploadConfiguration.method == "piclist" {
            commitPicListEndpoint()
            guard !picListEndpointError else { return }
        }
        cancelValidation()
        let config = preferences.markdownImageUploadConfiguration, id = UUID()
        validationID = id
        validationStatus = StatusMessage(kind: .info, text: L10n.tr("正在测试…"))
        validationTask = Task.detached {
            let result: Result<[URL], Error>
            do {
                guard let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC") else { throw MarkdownImageUploadService.UploadError.invalidInput }
                let payload = try MarkdownImageUploadService.payload(data: data)
                result = .success(try await MarkdownImageUploadService.upload([payload], method: config.method, endpoint: config.endpoint,
                    executable: config.executable, arguments: config.arguments, document: nil, isCancelled: { Task.isCancelled }))
            } catch { result = .failure(error) }
            await MainActor.run {
                if validationID != id, ["piclist", "upic", "ipic", "picsee"].contains(config.method) {
                    let message: String?
                    switch result {
                    case let .success(urls):
                        message = (config.method == "ipic"
                            ? MarkdownImageUploadService.UploadError.iPicPartial(urls.map(\.absoluteString), L10n.tr("取消")) : config.method == "picsee"
                            ? MarkdownImageUploadService.UploadError.picseePartial(urls.map(\.absoluteString), L10n.tr("取消")) : config.method == "upic"
                            ? MarkdownImageUploadService.UploadError.uPicPartial(urls.map(\.absoluteString), L10n.tr("取消"))
                            : MarkdownImageUploadService.UploadError.picListPartial(urls.map(\.absoluteString), L10n.tr("取消"))).localizedDescription
                    case let .failure(error):
                        if let issue = error as? MarkdownImageUploadService.UploadError, issue.reportsUploadedResources { message = error.localizedDescription }
                        else { message = nil }
                    }
                    if let message {
                        let notice = ClipboardSavedImagesNotice(documentID: UUID(), message: message)
                        NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
                    }
                    return
                }
                guard validationID == id else { return }
                validationTask = nil
                switch result {
                case let .success(urls):
                    if let first = urls.first { validationStatus = StatusMessage(kind: .success, text: first.absoluteString) }
                    else { validationStatus = StatusMessage(kind: .error, text: L10n.tr("上传结果不完整或地址无效")) }
                case let .failure(error): validationStatus = StatusMessage(kind: .error, text: L10n.tr("图片上传失败：%@", error.localizedDescription))
                }
            }
        }
    }
}

private struct MarkdownExportSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @State private var profileToDelete: String?
    @State private var confirmReset = false
    @State private var confirmRemoveUnsupported = false
    @Environment(\.settingsHighlightedTitle) private var highlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PreferenceGroup(title: L10n.tr("HTML 导出附加内容")) {
                PreferenceRow(title: L10n.tr("导出时保留连续空格"), detail: L10n.tr("支持 HTML、应用内 PDF、DOCX、ODT、RTF、EPUB 和 LaTeX。其他格式的效果取决于导出程序。")) {
                    Toggle(L10n.tr("导出时保留连续空格"), isOn: $preferences.markdownExportWhitespace)
                        .labelsHidden().toggleStyle(.switch)
                }
                exportDivider
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("附加脚本可能在打开导出文件的应用中运行。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(L10n.tr("附加到 head")).font(.body.weight(.medium)).id(L10n.tr("附加到 head"))
                    TextEditor(text: $preferences.markdownHTMLExportOptions.appendHead).settingsMultilineField(minHeight: 60)
                        .accessibilityLabel(L10n.tr("附加到 head"))
                    Text(L10n.tr("附加到 body")).font(.body.weight(.medium)).id(L10n.tr("附加到 body"))
                    TextEditor(text: $preferences.markdownHTMLExportOptions.appendBody).settingsMultilineField(minHeight: 60)
                        .accessibilityLabel(L10n.tr("附加到 body"))
                }.padding(16)
                exportDivider
                Toggle(L10n.tr("允许文档 YAML 覆盖 HTML 导出设置"), isOn: $preferences.markdownHTMLExportOptions.allowDocumentOverrides)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .id(L10n.tr("允许文档 YAML 覆盖 HTML 导出设置"))
            }
            PreferenceGroup(title: L10n.tr("PDF 页面设置")) {
                exportRow(L10n.tr("纸张")) {
                    Picker(L10n.tr("纸张"), selection: $preferences.markdownNativeExportOptions.paper) {
                        Text(L10n.tr("系统默认")).tag("system")
                        Text("A4").tag("a4")
                        Text("A5").tag("a5")
                        Text("Letter").tag("letter")
                        Text(L10n.tr("自定义")).tag("custom")
                    }.labelsHidden()
                }
                if preferences.markdownNativeExportOptions.paper == "custom" {
                    exportDivider
                    exportNumberRow(L10n.tr("纸张宽度（点）"), $preferences.markdownNativeExportOptions.paperWidth, range: 72...14400)
                    exportDivider
                    exportNumberRow(L10n.tr("纸张高度（点）"), $preferences.markdownNativeExportOptions.paperHeight, range: 72...14400)
                }
                exportDivider
                Toggle(L10n.tr("顶级标题和脚注前分页"), isOn: Binding(
                    get: { preferences.markdownNativeExportOptions.pageBreakTopHeadings ?? false },
                    set: { preferences.markdownNativeExportOptions.pageBreakTopHeadings = $0 }
                )).padding(.horizontal, 16).padding(.vertical, 10).id(L10n.tr("顶级标题和脚注前分页"))
                exportDivider
                Toggle(L10n.tr("自定义页边距"), isOn: $preferences.markdownNativeExportOptions.customMargins)
                    .padding(.horizontal, 16).padding(.vertical, 10).id(L10n.tr("自定义页边距"))
                if preferences.markdownNativeExportOptions.customMargins {
                    exportDivider
                    exportNumberRow(L10n.tr("上边距（点）"), $preferences.markdownNativeExportOptions.marginTop, range: 0...720)
                    exportDivider
                    exportNumberRow(L10n.tr("下边距（点）"), $preferences.markdownNativeExportOptions.marginBottom, range: 0...720)
                    exportDivider
                    exportNumberRow(L10n.tr("左边距（点）"), $preferences.markdownNativeExportOptions.marginLeft, range: 0...720)
                    exportDivider
                    exportNumberRow(L10n.tr("右边距（点）"), $preferences.markdownNativeExportOptions.marginRight, range: 0...720)
                }
                exportDivider
                exportRow(L10n.tr("PDF 页眉")) {
                    TextField("", text: $preferences.markdownPDFHeaderFooterOptions.header)
                        .frame(width: 220).accessibilityLabel(L10n.tr("PDF 页眉"))
                }
                exportDivider
                exportRow(L10n.tr("PDF 页脚")) {
                    TextField("", text: $preferences.markdownPDFHeaderFooterOptions.footer)
                        .frame(width: 220).accessibilityLabel(L10n.tr("PDF 页脚"))
                }
                exportDivider
                Toggle(L10n.tr("允许文档 YAML 覆盖页眉和页脚"), isOn: $preferences.markdownPDFHeaderFooterOptions.allowDocumentOverrides)
                    .padding(.horizontal, 16).padding(.vertical, 10).id(L10n.tr("允许文档 YAML 覆盖页眉和页脚"))
            }
            PreferenceGroup(title: L10n.tr("图像导出设置")) {
                exportNumberRow(L10n.tr("图像宽度（点）"), $preferences.markdownNativeExportOptions.imageWidth)
                exportDivider
                exportRow(L10n.tr("图像质量")) {
                    Picker(L10n.tr("图像质量"), selection: Binding(
                        get: { preferences.markdownNativeExportOptions.imageQuality ?? "auto" },
                        set: { preferences.markdownNativeExportOptions.imageQuality = $0 == "auto" ? nil : $0 }
                    )) {
                        Text(L10n.tr("自动")).tag("auto")
                        Text(L10n.tr("中等")).tag("medium")
                        Text(L10n.tr("高")).tag("high")
                        Text(L10n.tr("最佳")).tag("best")
                    }.labelsHidden()
                }
                exportDivider
                Toggle(L10n.tr("自定义图像字体大小"), isOn: $preferences.markdownNativeExportOptions.customImageFontSize)
                    .padding(.horizontal, 16).padding(.vertical, 10).id(L10n.tr("自定义图像字体大小"))
                if preferences.markdownNativeExportOptions.customImageFontSize {
                    exportDivider
                    exportNumberRow(L10n.tr("图像字体大小（点）"), $preferences.markdownNativeExportOptions.imageFontSize)
                }
            }
            Divider()
            if preferences.invalidMarkdownExportConfiguration {
                Text(L10n.tr("导出设置无法读取；原始设置未被覆盖。"))
                Button(L10n.tr("重置导出设置")) { confirmReset = true }
                    .confirmationDialog(L10n.tr("重置导出设置？"), isPresented: $confirmReset, titleVisibility: .visible) {
                        Button(L10n.tr("重置导出设置"), role: .destructive) { preferences.resetMarkdownExportConfiguration() }
                        Button(L10n.tr("取消"), role: .cancel) {}
                    } message: {
                        Text(L10n.tr("导出项目将恢复为默认列表，自定义项目和无法读取的原始设置会被替换。"))
                    }
            } else {
                if preferences.unsupportedMarkdownExportEntryCount > 0 {
                    Text(L10n.tr("保留了不支持的导出项目：%d", preferences.unsupportedMarkdownExportEntryCount))
                    Button(L10n.tr("删除不支持的导出项目")) { confirmRemoveUnsupported = true }
                        .confirmationDialog(L10n.tr("删除不支持的导出项目？"), isPresented: $confirmRemoveUnsupported, titleVisibility: .visible) {
                            Button(L10n.tr("删除不支持的导出项目"), role: .destructive) { preferences.removeUnsupportedMarkdownExportEntries() }
                            Button(L10n.tr("取消"), role: .cancel) {}
                        } message: {
                            Text(L10n.tr("这些项目当前版本无法使用，删除后无法恢复。"))
                        }
                }
                ForEach($preferences.markdownExportConfiguration.profiles) { $profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: $profile.enabled).labelsHidden()
                                .accessibilityLabel(profile.name.isEmpty ? L10n.tr("启用导出项目") : L10n.tr("启用导出项目：%@", profile.name))
                            TextField(L10n.tr("名称"), text: $profile.name).accessibilityLabel(L10n.tr("名称"))
                            Button { move(profile.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).help(L10n.tr("上移")).accessibilityLabel(L10n.tr("上移"))
                                .disabled(profile.id == preferences.markdownExportConfiguration.profiles.first?.id)
                            Button { move(profile.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).help(L10n.tr("下移")).accessibilityLabel(L10n.tr("下移"))
                                .disabled(profile.id == preferences.markdownExportConfiguration.profiles.last?.id)
                            Button(L10n.tr("删除"), role: .destructive) { profileToDelete = profile.id }
                        }
                        MarkdownExportExtensionsField(extensions: $profile.extensions)
                        if profile.kind == "command" {
                            Text(L10n.tr("命令以当前用户权限运行，可以读取和修改文件。"))
                                .foregroundStyle(.secondary)
                            Text(L10n.tr("使用 ${inputPath} 读取当前文本，${outputPath} 指向输出。"))
                                .foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { profile.command ?? "" }, set: { profile.command = $0 }))
                                .settingsMultilineField(minHeight: 70)
                                .accessibilityLabel(L10n.tr("自定义命令"))
                            Picker(L10n.tr("命令输出"), selection: Binding(
                                get: { profile.commandDestination ?? "file" }, set: { profile.commandDestination = $0 }
                            )) {
                                Text(L10n.tr("文件")).tag("file")
                                Text(L10n.tr("文件夹")).tag("folder")
                                Text(L10n.tr("无输出路径")).tag("none")
                            }
                            Toggle(L10n.tr("显示命令输出"), isOn: Binding(
                                get: { profile.showCommandOutput ?? false }, set: { profile.showCommandOutput = $0 }
                            ))
                        } else if profile.kind == "pdf-engine" {
                            Text(L10n.tr("PDF 引擎以当前用户权限运行，可以读取和修改文件。"))
                                .foregroundStyle(.secondary)
                            Picker(L10n.tr("PDF 中间格式"), selection: $profile.writer) {
                                Text("LaTeX").tag("latex")
                                Text("ConTeXt").tag("context")
                                Text("HTML").tag("html")
                                Text("roff ms").tag("ms")
                                Text("Typst").tag("typst")
                            }
                            TextField(L10n.tr("PDF 引擎路径"), text: Binding(
                                get: { profile.pdfEngine ?? "" }, set: { profile.pdfEngine = $0 }
                            )).accessibilityLabel(L10n.tr("PDF 引擎路径"))
                            fileRow(L10n.tr("模板"), path: $profile.templatePath)
                            TextField(L10n.tr("额外参数"), text: $profile.arguments).accessibilityLabel(L10n.tr("额外参数"))
                        } else {
                            TextField(L10n.tr("Pandoc 输出格式"), text: $profile.writer).accessibilityLabel(L10n.tr("Pandoc 输出格式"))
                            TextField(L10n.tr("原始类型"), text: $profile.rawType).accessibilityLabel(L10n.tr("原始类型"))
                            TextField(L10n.tr("额外参数"), text: $profile.arguments).accessibilityLabel(L10n.tr("额外参数"))
                            Text(L10n.tr("筛选器和其他程序以当前用户权限运行，可以读取和修改文件。"))
                                .foregroundStyle(.secondary)
                            fileRow(L10n.tr("模板"), path: $profile.templatePath)
                            fileRow(L10n.tr("样式参考文件"), path: $profile.referenceDocumentPath)
                            fileRow(L10n.tr("EPUB 封面"), path: $profile.epubCoverPath)
                            HStack {
                                Toggle(L10n.tr("EPUB 目录深度"), isOn: Binding(
                                    get: { profile.epubTOCDepth != nil }, set: { profile.epubTOCDepth = $0 ? 3 : nil }
                                ))
                                if profile.epubTOCDepth != nil {
                                    Stepper(L10n.tr("深度 %d", profile.epubTOCDepth ?? 3), value: Binding(
                                        get: { profile.epubTOCDepth ?? 3 }, set: { profile.epubTOCDepth = $0 }
                                    ), in: 1...20)
                                }
                            }
                        }
                    }
                    .padding(12)
                    Divider()
                }
                Button(L10n.tr("添加 Pandoc 导出项目")) {
                    var profile = MarkdownExportProfile.standard(.text)
                    profile.id = UUID().uuidString
                    profile.name = L10n.tr("自定义 Pandoc")
                    profile.writer = ""
                    profile.extensions = []
                    preferences.markdownExportConfiguration.profiles.append(profile)
                }
                Button(L10n.tr("添加自定义命令")) {
                    preferences.markdownExportConfiguration.profiles.append(.customCommand())
                }
                Button(L10n.tr("添加 PDF 引擎导出项目")) {
                    preferences.markdownExportConfiguration.profiles.append(.pdfEngineProfile())
                }
            }
        }
        .confirmationDialog(
            L10n.tr("删除此导出项目？"),
            isPresented: Binding(get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("删除"), role: .destructive) {
                if let id = profileToDelete { preferences.markdownExportConfiguration.profiles.removeAll { $0.id == id } }
                profileToDelete = nil
            }
            Button(L10n.tr("取消"), role: .cancel) { profileToDelete = nil }
        } message: {
            let name = preferences.markdownExportConfiguration.profiles.first { $0.id == profileToDelete }?.name ?? ""
            Text(L10n.tr("「%@」将被删除。", name))
        }
    }

    private var exportDivider: some View { Divider().padding(.horizontal, 16).opacity(0.5) }

    private func exportRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        LabeledContent(title, content: control).padding(.horizontal, 16).padding(.vertical, 10)
            .background(highlighted == title ? LacEditorDesign.selectionFill : Color.clear)
            .id(title)
    }

    private func exportNumberRow(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double>? = nil) -> some View {
        exportRow(title) {
            if let range {
                RangedNumberField(title: title, value: value, range: range)
            } else {
                TextField("", value: value, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing).accessibilityLabel(title)
            }
        }
    }

    private func move(_ id: String, by offset: Int) {
        var profiles = preferences.markdownExportConfiguration.profiles
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles.indices.contains(index + offset) else { return }
        profiles.swapAt(index, index + offset)
        preferences.markdownExportConfiguration.profiles = profiles
    }

    private func fileRow(_ title: String, path: Binding<String?>) -> some View {
        HStack {
            Text(title)
            Text(path.wrappedValue ?? L10n.tr("未选择"))
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Button(L10n.tr("选择…")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { path.wrappedValue = panel.url?.path }
            }
            if path.wrappedValue != nil { Button(L10n.tr("清除")) { path.wrappedValue = nil } }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct MarkdownExportExtensionsField: View {
    @Binding var extensions: [String]
    @State private var text: String

    init(extensions: Binding<[String]>) {
        _extensions = extensions
        _text = State(initialValue: extensions.wrappedValue.joined(separator: " "))
    }

    private func parse(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        TextField(L10n.tr("扩展名，以空格分隔"), text: $text)
            .accessibilityLabel(L10n.tr("扩展名，以空格分隔"))
            .onChange(of: text) { _, value in extensions = parse(value) }
            .onChange(of: extensions) { _, value in
                if parse(text) != value { text = value.joined(separator: " ") }
            }
    }
}

private struct RangedNumberField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField("", text: $text)
                .focused($focused)
                .frame(width: 90).multilineTextAlignment(.trailing).accessibilityLabel(title)
                .onSubmit { commit() }
            if invalid {
                StatusMessageView(kind: .error, text: L10n.tr("请输入 %@ 到 %@ 之间的数字",
                    String(describing: SettingsNumberInput.string(range.lowerBound)), String(describing: SettingsNumberInput.string(range.upperBound))))
                    .frame(width: 220, alignment: .trailing)
            }
        }
        .onAppear { text = SettingsNumberInput.string(value) }
        .onChange(of: value) { _, new in
            if !focused { text = SettingsNumberInput.string(new); invalid = false }
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        if text == SettingsNumberInput.string(value) { invalid = false; return }
        if let parsed = SettingsNumberInput.parse(text, range: range) {
            value = parsed
            invalid = false
            text = SettingsNumberInput.string(parsed)
        } else {
            invalid = true
        }
    }
}

extension View {
    /// Единый вид многострочных полей настроек (TextEditor): системный фон текста и тонкая рамка.
    func settingsMultilineField(minHeight: CGFloat) -> some View {
        self.scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LacEditorDesign.outline, lineWidth: 0.5))
    }
}
