import Combine
import SwiftUI

/// Панель форматирования над текстом: видна только у оформленного Markdown, который можно править.
struct MarkdownFormattingBarHost: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let document = appState.selectedDocument {
            MarkdownFormattingBar(document: document)
                .id(document.id)
        }
    }
}

struct MarkdownFormattingBar: View {
    @EnvironmentObject private var appState: AppState
    let document: EditorDocument
    /// Панели нужно только состояние оформления: подписка на весь документ перерисовывала бы её на каждый символ.
    @State private var formattingState = MarkdownFormattingState()

    /// Показывать ли панель: Markdown в оформленном виде, не режим чтения и не большой файл, документ не занят вводом-выводом.
    static func isVisible(document: EditorDocument, isDistractionFree: Bool) -> Bool {
        document.language == .markdown && document.isMarkdownFormatted && !document.isReadingMode
            && !document.isLargeFileMode && document.ioState == .idle && !isDistractionFree
    }

    private var state: MarkdownFormattingState { formattingState }

    private func toggle(_ title: String, _ symbol: String, id: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .background(isOn ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Повторное нажатие кнопки вида списка, который уже стоит, снимает список.
    private func list(_ command: MarkdownFormattingCommand, active: Bool) {
        appState.formatMarkdown(active ? .plainText : command)
    }

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button(L10n.tr("普通文本")) { appState.formatMarkdown(.plainText) }
                ForEach(1...6, id: \.self) { level in
                    Button(L10n.tr("标题 %@ 级", String(level))) { appState.formatMarkdown(.heading(level)) }
                }
                Button(L10n.tr("代码块")) { appState.formatMarkdown(.fencedCode) }
            } label: {
                Text(L10n.tr("段落样式"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("markdownFormat.paragraph")
            Divider().frame(height: 16)
            toggle(L10n.tr("加粗"), "bold", id: "markdownFormat.bold", isOn: state.bold) { appState.formatMarkdown(.bold) }
            toggle(L10n.tr("斜体"), "italic", id: "markdownFormat.italic", isOn: state.italic) { appState.formatMarkdown(.italic) }
            toggle(L10n.tr("删除线"), "strikethrough", id: "markdownFormat.strikethrough", isOn: state.strikethrough) {
                appState.formatMarkdown(.strikethrough)
            }
            toggle(L10n.tr("链接…"), "link", id: "markdownFormat.link", isOn: state.link) { appState.presentMarkdownLink() }
            Divider().frame(height: 16)
            toggle(L10n.tr("无序列表"), "list.bullet", id: "markdownFormat.bulletList", isOn: state.paragraph == .bulletList) {
                list(.bulletList, active: state.paragraph == .bulletList)
            }
            toggle(L10n.tr("有序列表"), "list.number", id: "markdownFormat.numberedList", isOn: state.paragraph == .numberedList) {
                list(.numberedList, active: state.paragraph == .numberedList)
            }
            toggle(L10n.tr("任务列表"), "checklist", id: "markdownFormat.taskList", isOn: state.paragraph == .taskList) {
                list(.taskList, active: state.paragraph == .taskList)
            }
            Menu {
                Button(L10n.tr("代码块")) { appState.formatMarkdown(.fencedCode) }
                Button(L10n.tr("插入表格")) { appState.formatMarkdown(.table(.create(rows: 1, columns: 2))) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.tr("插入块"))
            .accessibilityLabel(L10n.tr("插入块"))
            .accessibilityIdentifier("markdownFormat.insert")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear { formattingState = document.markdownFormattingState ?? MarkdownFormattingState() }
        .onReceive(document.$markdownFormattingState.map { $0 ?? MarkdownFormattingState() }.removeDuplicates()) { formattingState = $0 }
    }
}
