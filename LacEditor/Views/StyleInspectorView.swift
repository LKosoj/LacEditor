import SwiftUI

/// Сегмент «Стиль»: локальные правила и AI-замечания. Подчёркивания в тексте рисует редактор.
struct StyleInspectorView: View {
    @ObservedObject var controller: StyleCheckController
    var openSettings: () -> Void = {}
    @EnvironmentObject private var appState: AppState
    @State private var customWordsText = ""
    @State private var stopWordsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if controller.availability != .ready {
                unavailable
            } else {
                if controller.messageAction != nil || !controller.message.isEmpty {
                    AIPanelMessageView(kind: controller.messageKind, text: controller.message, action: controller.messageAction,
                                       openSettings: openSettings, retry: { controller.retry() }, sendAnyway: { controller.sendAnyway() })
                        .padding(.horizontal, 12)
                }
                list
                if let suggestion = controller.suggestion { suggestionBlock(suggestion) }
                actions
                settingsSection
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            controller.panelAppeared()
            syncLists()
        }
        .onDisappear { controller.panelDisappeared() }
        .focusable()
        .onKeyPress(.upArrow) { controller.select(next: false); return .handled }
        .onKeyPress(.downArrow) { controller.select(next: true); return .handled }
    }

    // MARK: Шапка

    private var header: some View {
        HStack {
            Menu {
                Button(L10n.tr("自动")) { controller.setFixedLanguage(nil) }
                Button(L10n.tr("中文")) { controller.setFixedLanguage(.zh) }
                Button(L10n.tr("英语")) { controller.setFixedLanguage(.en) }
                Button(L10n.tr("俄语")) { controller.setFixedLanguage(.ru) }
                Button(L10n.tr("其他语言")) { controller.setFixedLanguage(.other) }
            } label: {
                Text(languageTitle)
            }
            .fixedSize()
            .accessibilityLabel(L10n.tr("语言"))
            Spacer()
            if controller.isChecking { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
    }

    private var languageTitle: String {
        if let fixed = controller.settings.fixedLanguage { return name(fixed) }
        if let detected = controller.detectedLanguage { return L10n.tr("自动") + " (" + name(detected) + ")" }
        return L10n.tr("自动")
    }

    private func name(_ language: TextLanguage) -> String {
        switch language {
        case .zh: L10n.tr("中文")
        case .en: L10n.tr("英语")
        case .ru: L10n.tr("俄语")
        case .other: L10n.tr("其他语言")
        }
    }

    private var unavailable: some View {
        let text: String
        switch controller.availability {
        case .noDocument: text = L10n.tr("没有打开的文档")
        case .unsupportedType: text = L10n.tr("文风检查仅适用于 Markdown 和纯文本")
        case .largeFile: text = L10n.tr("大文件模式下不检查文风")
        case .ready: text = ""
        }
        return ContentUnavailableView(text, systemImage: "text.magnifyingglass")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Список

    @ViewBuilder private var list: some View {
        if controller.isStale {
            Text(L10n.tr("文本已变化，结果可能过时"))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
        }
        if controller.findings.isEmpty {
            if controller.hasChecked || controller.isReviewing {
                Text(controller.isReviewing ? L10n.tr("AI 正在检查…") : L10n.tr("暂无文风检查结果"))
                    .foregroundStyle(.secondary).padding(.horizontal, 12)
            } else {
                Text(L10n.tr("暂无文风检查结果")).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(controller.groups, id: \.category) { group in
                        Section(group.category.title) {
                            ForEach(group.findings) { finding in
                                row(finding)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: controller.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ finding: StyleFinding) -> some View {
        let location = controller.lineNumbers[finding.id].map { L10n.tr("第 %lld 行", $0) }
        return FindingRow(source: finding.source, fragment: finding.fragment, explanation: finding.explanation,
                          location: location, category: finding.category.title)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .background(controller.selectedID == finding.id ? Color.accentColor.opacity(0.15) : Color.clear)
            .onTapGesture { controller.select(finding.id) }
            .contextMenu {
                Button(L10n.tr("跳过")) { controller.skip(finding.id) }
            }
            .id(finding.id)
            .accessibilityAddTraits(controller.selectedID == finding.id ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { controller.select(finding.id) }
    }

    // MARK: Правка

    private func suggestionBlock(_ suggestion: StyleCheckController.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextDiffRow(change: .init(kind: .removed, line: suggestion.line, text: suggestion.shownBefore))
            TextDiffRow(change: .init(kind: .added, line: suggestion.line, text: suggestion.shownAfter))
            HStack {
                Button(L10n.tr("接受")) { controller.accept() }
                    .keyboardShortcut(.defaultAction)
                Button(L10n.tr("拒绝")) { controller.reject() }
            }
        }
        .padding(.horizontal, 12)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(L10n.tr("检查文风")) { controller.checkNow() }
                    .disabled(controller.isChecking)
                if controller.isReviewing {
                    Button(L10n.tr("停止")) { controller.cancelReview() }
                } else if appState.aiAvailability(for: .styleReview) == .available {
                    Button(L10n.tr("AI 检查")) { controller.runReview() }
                }
            }
            if appState.aiAvailability(for: .styleReview) != .available {
                AIRecommendationHint(feature: .styleReview, message: L10n.tr("启用 AI 后可检查套话、官腔和歧义"))
            }
            if let finding = controller.selectedFinding, controller.suggestion == nil {
                HStack {
                    Button(finding.replacement == nil ? L10n.tr("建议修改") : L10n.tr("查看修改")) { controller.suggestEdit() }
                        .disabled(controller.isStale || controller.isSuggesting)
                    Button(L10n.tr("跳过")) { controller.skip(finding.id) }
                    if controller.isSuggesting { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Настройки

    private var settingsSection: some View {
        DisclosureGroup(L10n.tr("文风检查设置")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(StyleCategory.allCases, id: \.self) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { controller.settings.isEnabled(category) },
                        set: { controller.setCategory(category, enabled: $0) }))
                }
                Toggle(L10n.tr("停顿后自动检查"), isOn: binding(\.autoCheck))
                Stepper(L10n.tr("重复词范围：%lld 词", controller.settings.windowWords), value: binding(\.windowWords), in: 5...100)
                Stepper(L10n.tr("重复字范围：%lld 字", controller.settings.windowChars), value: binding(\.windowChars), in: 10...200)
                Stepper(L10n.tr("长句：%lld 词", controller.settings.longSentenceWords), value: binding(\.longSentenceWords), in: 10...100)
                Stepper(L10n.tr("长句：%lld 字", controller.settings.longSentenceChars), value: binding(\.longSentenceChars), in: 20...300)
                Text(L10n.tr("避免使用的词（每行一个）")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $customWordsText)
                    .frame(height: 60)
                    .accessibilityLabel(L10n.tr("避免使用的词（每行一个）"))
                    .onChange(of: customWordsText) { _, value in
                        var next = controller.settings
                        next.customWords = StyleCheckSettings.parseList(value)
                        controller.settings = next
                    }
                Text(L10n.tr("不计入重复的词（每行一个）")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $stopWordsText)
                    .frame(height: 60)
                    .accessibilityLabel(L10n.tr("不计入重复的词（每行一个）"))
                    .onChange(of: stopWordsText) { _, value in
                        var next = controller.settings
                        next.customStopWords = StyleCheckSettings.parseList(value)
                        controller.settings = next
                    }
                Text(L10n.tr("AI 检查的目标（读者、语气）")).font(.caption).foregroundStyle(.secondary)
                TextField("", text: binding(\.goal))
                    .accessibilityLabel(L10n.tr("AI 检查的目标（读者、语气）"))
                Button(L10n.tr("恢复默认")) {
                    controller.resetSettings()
                    syncLists()
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<StyleCheckSettings, Value>) -> Binding<Value> {
        Binding(get: { controller.settings[keyPath: keyPath] },
                set: { value in
                    var next = controller.settings
                    next[keyPath: keyPath] = value
                    controller.settings = next
                })
    }

    private func syncLists() {
        customWordsText = controller.settings.customWords.joined(separator: "\n")
        stopWordsText = controller.settings.customStopWords.joined(separator: "\n")
    }
}
