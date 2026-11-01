import AppKit
import SwiftUI

/// Observes FindReplaceState itself: AppState does not republish its nested state object.
struct FindBarHost: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: FindReplaceState

    var body: some View {
        if state.isBarVisible, let document = appState.selectedDocument {
            VStack(spacing: 0) {
                FindBarView(state: state, document: document)
                Divider()
            }
            .id(document.id)
        }
    }
}

struct FindBarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: FindReplaceState
    @ObservedObject var document: EditorDocument
    @FocusState private var focusedField: Field?
    private enum Field { case query, replacement, line }

    var body: some View {
        VStack(spacing: 6) {
            if state.mode == .goToLine {
                goToLineRow
            } else {
                findRow
                aiRegexMessage
                if state.mode == .replace { replaceRow }
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(LacEditorDesign.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("查找栏"))
        .onAppear { focusRequestedField() }
        .onChange(of: state.focusRequestID) { focusRequestedField() }
        .onChange(of: state.mode) { focusRequestedField() }
        .onChange(of: state.query) {
            appState.aiRegex.queryEdited(state.query, target: .findBar)
            queryOptionsChanged()
        }
        .onChange(of: state.isCaseSensitive) { queryOptionsChanged() }
        .onChange(of: state.usesRegex) { queryOptionsChanged() }
        .onChange(of: state.matchesWholeWord) { queryOptionsChanged() }
        .onChange(of: state.interpretsEscapes) { queryOptionsChanged() }
        .onChange(of: state.replacement) { appState.cancelFindReplaceTask() }
    }

    private var queryField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.tr("输入要查找的内容"), text: $state.query)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .query)
                .onKeyPress(keys: [.return], phases: .down) { press in handleReturn(press) }
                .onKeyPress(keys: [.escape], phases: .down) { _ in handleEscape() }
                .accessibilityIdentifier("find.query")
                .accessibilityLabel(L10n.tr("查找"))
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                    focusedField = .query
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("清除"))
                .accessibilityLabel(L10n.tr("清除"))
                .accessibilityIdentifier("find.clear")
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 160, minHeight: 22)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
        .editorFocusRing(focusedField == .query, radius: 5)
    }

    private var findRow: some View {
        HStack(spacing: 6) {
            Button {
                state.mode = state.mode == .replace ? .find : .replace
            } label: {
                Image(systemName: state.mode == .replace ? "chevron.down" : "chevron.right")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .help(L10n.tr("替换"))
            .accessibilityLabel(L10n.tr("替换"))
            .accessibilityAddTraits(state.mode == .replace ? .isSelected : [])
            .accessibilityIdentifier("find.toggleReplace")
            queryField
            aiRegexButton
            optionToggle("Aa", isOn: $state.isCaseSensitive, label: L10n.tr("区分大小写"))
            optionToggle(".*", isOn: $state.usesRegex, label: L10n.tr("正则表达式"))
            optionToggle("W", isOn: $state.matchesWholeWord, label: L10n.tr("全字匹配"))
            optionToggle("\\n", isOn: $state.interpretsEscapes, label: L10n.tr("解释转义字符"), help: escapeHelp)
                .disabled(state.usesRegex)
            Picker(L10n.tr("查找范围"), selection: Binding(get: { state.area }, set: { appState.setFindScope($0) })) {
                ForEach(FindScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
            .help(state.area == .selection ? L10n.tr("仅在启用时选中的文本范围内查找和替换") : L10n.tr("查找范围"))
            .accessibilityLabel(L10n.tr("查找范围"))
            .accessibilityIdentifier("find.scope")
            resultLabel
            extractMenu
            Spacer(minLength: 0)
            Button { appState.findPrevious(keepFocusInBar: true) } label: { Image(systemName: "chevron.up") }
                .disabled(actionsDisabled)
                .help(L10n.tr("查找上一处（⇧⌘G）"))
                .accessibilityLabel(L10n.tr("上一个"))
            Button { appState.findNext(keepFocusInBar: true) } label: { Image(systemName: "chevron.down") }
                .disabled(actionsDisabled)
                .help(L10n.tr("查找下一处（⌘G）"))
                .accessibilityLabel(L10n.tr("下一个"))
            closeButton
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var extractMenu: some View {
        Menu {
            Button(L10n.tr("匹配内容")) { appState.extractMatches(.match) }
            Button(L10n.tr("按模板提取")) { appState.extractMatches(.template) }
                .disabled(state.mode != .replace || state.replacement.isEmpty)
                .help(L10n.tr("使用“替换为”中的模板，例如 $1"))
            Button(L10n.tr("匹配所在的行")) { appState.extractMatches(.line) }
            Button(L10n.tr("不含匹配的行")) { appState.extractMatches(.withoutMatch) }
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(actionsDisabled)
        .help(L10n.tr("提取")).accessibilityLabel(L10n.tr("提取")).accessibilityIdentifier("find.extract")
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 16).accessibilityHidden(true)
            TextField(L10n.tr("输入替换内容，留空表示删除"), text: $state.replacement)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
                .focused($focusedField, equals: .replacement)
                .onKeyPress(keys: [.return], phases: .down) { press in handleReturn(press) }
                .onKeyPress(keys: [.escape], phases: .down) { _ in handleEscape() }
                .help(state.usesRegex ? L10n.tr("替换模板：$1 表示第 1 个捕获组") : "")
                .accessibilityLabel(L10n.tr("替换为"))
            Button(L10n.tr("替换")) { appState.replaceCurrentMatch(keepFocusInBar: true) }
                .disabled(actionsDisabled)
            Button(L10n.tr("全部替换")) { appState.replaceAllMatches() }
                .buttonStyle(.borderedProminent)
                .disabled(actionsDisabled)
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var goToLineRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.to.line").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.tr("行号[:列号]"), text: $state.goToLineText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($focusedField, equals: .line)
                .onKeyPress(keys: [.return], phases: .down) { _ in
                    appState.goToLine(state.goToLineText)
                    return .handled
                }
                .onKeyPress(keys: [.escape], phases: .down) { _ in handleEscape() }
                .accessibilityIdentifier("find.goToLine")
                .accessibilityLabel(L10n.tr("跳转到行…"))
            Button(L10n.tr("跳转")) { appState.goToLine(state.goToLineText) }
                .controlSize(.small)
            if let message = state.message {
                Text(message)
                    .foregroundStyle(state.messageKind == .error ? Color.red : Color.secondary)
                    .lineLimit(1).help(message)
                    .accessibilityIdentifier("find.result.message")
            }
            Spacer(minLength: 0)
            closeButton
        }
    }

    /// Кнопка видна при включённом текстовом профиле; в модель уходит только фраза из поля, не документ.
    @ViewBuilder private var aiRegexButton: some View {
        if AIRegexController.isAvailable(preferences: appState.preferences) {
            if appState.aiRegex.isWorking && appState.aiRegex.target == .findBar {
                ProgressView().controlSize(.small)
                Button { appState.aiRegex.cancel() } label: { Image(systemName: "xmark.circle") }
                    .help(L10n.tr("取消生成"))
                    .accessibilityLabel(L10n.tr("取消生成"))
                    .accessibilityIdentifier("find.aiRegex.cancel")
            } else {
                Button {
                    appState.aiRegex.start(phrase: state.query, target: .findBar) { applyAIRegex($0) }
                } label: { Image(systemName: "sparkles") }
                    .disabled(state.query.isEmpty || appState.aiRegex.isWorking)
                    .help(L10n.tr("把查找框里的描述交给 AI 生成正则表达式；只发送这段描述，不发送文档内容"))
                    .accessibilityLabel(L10n.tr("用 AI 生成正则表达式"))
                    .accessibilityIdentifier("find.aiRegex")
            }
        }
    }

    @ViewBuilder private var aiRegexMessage: some View {
        if appState.aiRegex.target == .findBar, let message = appState.aiRegex.message {
            StatusMessageView(kind: message.kind, text: message.text)
                .lineLimit(2).help(message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("find.aiRegex.message")
        }
    }

    /// Сначала параметры, потом текст: «全字匹配» оборачивает выражение и меняет его смысл, поэтому выключается.
    private func applyAIRegex(_ result: AIRegexBuilder.Result) {
        state.matchesWholeWord = false
        state.isCaseSensitive = result.caseSensitive
        state.usesRegex = true
        state.query = result.pattern
    }

    private var closeButton: some View {
        Button { appState.dismissFindReplace(returnFocus: true) } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .help(L10n.tr("关闭"))
            .accessibilityLabel(L10n.tr("关闭"))
    }

    private func optionToggle(_ title: String, isOn: Binding<Bool>, label: String, help: String? = nil) -> some View {
        Toggle(isOn: isOn) { Text(title).font(.subheadline.monospaced()) }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(help ?? label)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var resultLabel: some View {
        Group {
            if state.isWorking {
                ProgressView().controlSize(.small)
                Button(L10n.tr("取消任务")) { appState.cancelFindReplaceTask() }.buttonStyle(.borderless)
            } else if let message = state.message {
                HStack(spacing: 4) {
                    if state.messageKind == .success { Image(systemName: "checkmark.circle").accessibilityHidden(true) }
                    Text(message).foregroundStyle(state.messageKind == .error ? Color.red : Color.secondary)
                }
                .lineLimit(1).help(message)
                .accessibilityIdentifier("find.result.message")
            } else if state.searchesOpenDocuments {
                if let summary = state.openDocumentsSummary { openDocumentsText(summary) }
            } else if let matches = state.matches, state.matchesDocumentID == document.id {
                if matches.isEmpty {
                    Text(L10n.tr("未找到匹配内容")).foregroundStyle(.secondary)
                } else if let index = TextSearchService.currentIndex(in: matches, selection: document.selectionRange) {
                    Text(L10n.tr("第 %@ 个，共 %@ 个", String(index), String(matches.count))).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("共 %@ 个匹配", String(matches.count))).foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .lineLimit(1)
    }

    @ViewBuilder private func openDocumentsText(_ summary: OpenDocumentsSummary) -> some View {
        let skipped = summary.skippedTitles.joined(separator: ", ")
        Group {
            if summary.matchCount == 0 {
                Text(L10n.tr("未找到匹配内容"))
            } else if summary.skippedTitles.isEmpty {
                Text(L10n.tr("共 %@ 个匹配，%@ 个文档", String(summary.matchCount), String(summary.documentCount)))
            } else {
                Text(L10n.tr("共 %@ 个匹配，%@ 个文档，跳过 %@ 个", String(summary.matchCount), String(summary.documentCount),
                             String(summary.skippedTitles.count)))
            }
        }
        .foregroundStyle(.secondary)
        .help(skipped.isEmpty ? "" : L10n.tr("已跳过：%@", skipped))
        .accessibilityIdentifier("find.result.openDocuments")
    }

    private var actionsDisabled: Bool { state.query.isEmpty || state.isWorking }

    private var escapeHelp: String {
        L10n.tr(#"可用转义字符：\n 换行，\r 回车，\t 制表符，\s 空格，\0 空字符，\\ 反斜杠。查找与替换内容均适用。"#)
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        guard !actionsDisabled else { return .handled }
        if press.modifiers.contains(.shift) { appState.findPrevious(keepFocusInBar: true) }
        else { appState.findNext(keepFocusInBar: true) }
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        appState.dismissFindReplace(returnFocus: true)
        return .handled
    }

    private func queryOptionsChanged() {
        appState.cancelFindReplaceTask()
        appState.scheduleFindRefresh()
    }

    private func focusRequestedField() {
        DispatchQueue.main.async {
            switch state.mode {
            case .goToLine: focusedField = .line
            case .replace: focusedField = state.query.isEmpty ? .query : .replacement
            case .find: focusedField = .query
            }
        }
    }
}

private extension FindScope {
    var title: String {
        switch self {
        case .document: L10n.tr("当前文档")
        case .selection: L10n.tr("在选区内")
        case .openDocuments: L10n.tr("全部打开的文档")
        }
    }
}
