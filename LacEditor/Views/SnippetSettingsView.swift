import SwiftUI

/// Черновик правки сниппета: на диск попадает только по кнопке «保存».
private struct SnippetDraft: Identifiable {
    let id: UUID
    let isNew: Bool
    var name: String
    var text: String
}

struct SnippetSettingsView: View {
    @ObservedObject var store: SnippetStore
    @State private var editing: SnippetDraft?
    @State private var snippetToDelete: UUID?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let message = store.issueMessage {
                StatusMessageView(kind: .error, text: message)
            }
            if let errorText {
                StatusMessageView(kind: .error, text: errorText)
            }
            PreferenceGroup(title: L10n.tr("文本片段列表")) {
                PreferenceRow(title: L10n.tr("添加文本片段"),
                              detail: L10n.tr("可用占位符：{{selection}} 所选文字，{{date}} 日期（yyyy-MM-dd），{{time}} 时间（HH:mm），{{cursor}} 插入后的光标位置。")) {
                    Button(L10n.tr("添加文本片段")) {
                        errorText = nil
                        editing = SnippetDraft(id: UUID(), isNew: true, name: "", text: "")
                    }
                    .disabled(store.isReadOnly)
                }
                SettingsRowDivider()
                if store.snippets.isEmpty {
                    Text(L10n.tr("尚未添加文本片段。")).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else {
                    ForEach(store.snippets) { snippet in
                        row(snippet)
                        if snippet.id != store.snippets.last?.id { SettingsRowDivider() }
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            SnippetEditSheet(draft: draft, store: store) { editing = nil }
        }
        .confirmationDialog(
            L10n.tr("删除此文本片段？"),
            isPresented: Binding(get: { snippetToDelete != nil }, set: { if !$0 { snippetToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("删除"), role: .destructive) {
                if let id = snippetToDelete {
                    do { try store.remove(id: id); errorText = nil }
                    catch { errorText = error.localizedDescription }
                }
                snippetToDelete = nil
            }
            Button(L10n.tr("取消"), role: .cancel) { snippetToDelete = nil }
        } message: {
            Text(L10n.tr("此操作无法撤销。"))
        }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.name).font(.body.weight(.medium)).lineLimit(1)
                Text(snippet.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("编辑文本片段")) {
                errorText = nil
                editing = SnippetDraft(id: snippet.id, isNew: false, name: snippet.name, text: snippet.text)
            }
            .disabled(store.isReadOnly)
            .accessibilityLabel("\(L10n.tr("编辑文本片段")) \(snippet.name)")
            Button(L10n.tr("删除"), role: .destructive) { snippetToDelete = snippet.id }
                .disabled(store.isReadOnly)
                .accessibilityLabel("\(L10n.tr("删除")) \(snippet.name)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct SnippetEditSheet: View {
    @State var draft: SnippetDraft
    @ObservedObject var store: SnippetStore
    let close: () -> Void
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr(draft.isNew ? "添加文本片段" : "编辑文本片段")).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("名称")).font(.caption).foregroundStyle(.secondary)
                TextField(L10n.tr("名称"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.tr("名称"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("内容")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.text)
                    .settingsMultilineField(minHeight: 140)
                    .accessibilityLabel(L10n.tr("内容"))
            }
            Text(L10n.tr("可用占位符：{{selection}} 所选文字，{{date}} 日期（yyyy-MM-dd），{{time}} 时间（HH:mm），{{cursor}} 插入后的光标位置。"))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText { StatusMessageView(kind: .error, text: errorText) }
            HStack {
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        do {
            if draft.isNew { try store.add(name: draft.name, text: draft.text) }
            else { try store.update(Snippet(id: draft.id, name: draft.name, text: draft.text)) }
            close()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
