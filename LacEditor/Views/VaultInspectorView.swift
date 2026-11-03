import SwiftUI

/// Общая оболочка вкладок панели хранилища: держит модель и привязывает её к текущей вкладке.
private struct VaultInspectorHost<Content: View>: View {
    @ObservedObject var appState: AppState
    @StateObject private var model = VaultInspectorModel()
    @ViewBuilder var content: (VaultInspectorModel, EditorDocument, String) -> Content

    var body: some View {
        Group {
            if let document = appState.vaultDocument, let path = appState.vaultNote?.path {
                ScrollView {
                    content(model, document, path)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { bind(document, path) }
                .onChange(of: document.id) { _, _ in bind(document, path) }
                .onChange(of: path) { _, _ in bind(document, path) }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.tr("请打开一篇笔记库笔记")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func bind(_ document: EditorDocument, _ path: String) {
        model.updates = appState.vaultServerUpdates
        model.bind(document: document, session: appState.vaultSession, serverPath: path)
    }
}

/// «Заметка»: свойства и состояние синхронизации.
struct VaultNoteInspectorView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VaultInspectorHost(appState: appState) { model, document, path in
            VaultNoteBody(appState: appState, model: model, document: document, path: path)
        }
    }
}

/// Отдельный вид, чтобы панель следила за документом: режим чтения, занятость и режим страницы меняют форму сразу.
private struct VaultNoteBody: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: VaultInspectorModel
    @ObservedObject var document: EditorDocument
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if document.language == .markdown {
                VaultPropertiesForm(appState: appState, model: model, documentID: document.id,
                                    isReadOnly: document.vaultPageMode != nil,
                                    isLocked: document.isReadingMode || document.isLargeFileMode || document.ioState != .idle)
                if document.vaultPageMode != nil {
                    Text(L10n.tr("此页面由服务器生成，只能查看")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.tr("只有 Markdown 笔记有属性")).foregroundStyle(.secondary)
            }
            Divider()
            VaultSyncStatusView(appState: appState, model: model, serverPath: path)
        }
    }
}

/// «Связи»: ссылки `[[…]]` из текста заметки и их состояние.
struct VaultLinksInspectorView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VaultInspectorHost(appState: appState) { model, document, _ in
            VaultLinksList(appState: appState, model: model, documentID: document.id)
        }
    }
}

private struct VaultLinksList: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: VaultInspectorModel
    let documentID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("出链")).font(.headline).accessibilityAddTraits(.isHeader)
            if model.isLinksTooLarge {
                Text(L10n.tr("文档过大，无法列出链接")).foregroundStyle(.secondary)
            } else if model.links.isEmpty {
                Text(model.isListingLoading ? L10n.tr("正在加载笔记列表…") : L10n.tr("此笔记没有链接"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.links) { link in row(link) }
            }
            Divider()
            Label(L10n.tr("服务器暂不提供反向链接"), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ link: VaultOutgoingLink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                icon(link.status)
                Text(link.title + (link.heading.map { " › " + $0 } ?? ""))
                    .lineLimit(2)
                if link.count > 1 { Text("×\(link.count)").foregroundStyle(.secondary).font(.caption) }
                Spacer(minLength: 0)
                if case let .resolved(path) = link.status {
                    Button(L10n.tr("打开")) { open(path, newTab: false) }.buttonStyle(.link)
                        .accessibilityLabel(L10n.tr("打开") + " " + link.title)
                }
            }
            switch link.status {
            case let .resolved(path):
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            case let .ambiguous(paths):
                Text(L10n.tr("有多个同名笔记")).font(.caption).foregroundStyle(.orange)
                ForEach(paths, id: \.self) { path in
                    Button(path) { open(path, newTab: false) }.buttonStyle(.link).font(.caption)
                }
            case .missing:
                Text(L10n.tr("未找到")).font(.caption).foregroundStyle(.orange)
                Button(L10n.tr("查找相似")) { model.findSimilar(for: link) }.buttonStyle(.link).font(.caption)
                ForEach(model.similar[link.id] ?? [], id: \.self) { path in
                    Button(path) { open(path, newTab: false) }.buttonStyle(.link).font(.caption)
                }
                if let found = model.similar[link.id], found.isEmpty {
                    Text(L10n.tr("未找到相似的笔记")).font(.caption).foregroundStyle(.secondary)
                }
            case .checking:
                Text(L10n.tr("正在检查…")).font(.caption).foregroundStyle(.secondary)
            }
            Button(L10n.tr("在文本中显示")) { appState.revealVaultRange(link.firstRange, documentID: documentID) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if case let .resolved(path) = link.status {
                Button(L10n.tr("在新标签页打开")) { open(path, newTab: true) }
            }
            Button(L10n.tr("复制")) { copy(link.target) }
        }
    }

    @ViewBuilder
    private func icon(_ status: VaultOutgoingLink.Status) -> some View {
        switch status {
        case .resolved: Image(systemName: "link").foregroundStyle(.secondary)
        case .ambiguous: Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange)
        case .missing: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .checking: Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
    }

    private func open(_ path: String, newTab: Bool) {
        appState.windowManager?.openVaultNote(path: path, from: appState, inNewTab: newTab)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// «Спросить»: вопрос по хранилищу; путь из ответа открывается, только если он есть в каталоге.
struct VaultAskInspectorView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let session = appState.vaultSession {
            VaultAskView(model: appState.vaultAsk,
                         isKnownPath: { path in session.catalog.wikiLinkPaths().contains(path) },
                         isOnline: session.isOnline)
        } else {
            Text(L10n.tr("请打开一篇笔记库笔记")).foregroundStyle(.secondary).padding(16)
        }
    }
}
