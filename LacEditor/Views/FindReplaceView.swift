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
        .onChange(of: state.query) { queryOptionsChanged() }
        .onChange(of: state.isCaseSensitive) { queryOptionsChanged() }
        .onChange(of: state.usesRegex) { queryOptionsChanged() }
        .onChange(of: state.matchesWholeWord) { queryOptionsChanged() }
        .onChange(of: state.interpretsEscapes) { queryOptionsChanged() }
        .onChange(of: state.replacement) { appState.cancelFindReplaceTask() }
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
            TextField(L10n.tr("输入要查找的内容"), text: $state.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
                .focused($focusedField, equals: .query)
                .onKeyPress(keys: [.return], phases: .down) { press in handleReturn(press) }
                .onKeyPress(keys: [.escape], phases: .down) { _ in handleEscape() }
                .accessibilityIdentifier("find.query")
                .accessibilityLabel(L10n.tr("查找"))
            optionToggle("Aa", isOn: $state.isCaseSensitive, label: L10n.tr("区分大小写"))
            optionToggle(".*", isOn: $state.usesRegex, label: L10n.tr("正则表达式"))
            optionToggle("W", isOn: $state.matchesWholeWord, label: L10n.tr("全字匹配"))
            optionToggle("\\n", isOn: $state.interpretsEscapes, label: L10n.tr("解释转义字符"), help: escapeHelp)
                .disabled(state.usesRegex)
            resultLabel
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
            } else if let matches = state.matches, state.matchesDocumentID == document.id {
                if matches.isEmpty {
                    Text(L10n.tr("未找到匹配内容")).foregroundStyle(.red)
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
