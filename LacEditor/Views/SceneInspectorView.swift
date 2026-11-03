import SwiftUI

/// Сегмент «Сцена» правой панели: описание, статус, метка, теги и включение в книгу для документа вкладки.
struct SceneInspectorView: View {
    @ObservedObject var session: WriterSession
    @ObservedObject var appState: AppState
    /// Каталог карточек: подписка нужна, чтобы панель обновлялась и при скрытой боковой панели.
    @ObservedObject private var world: StoryCardWorld
    @State private var synopsisDraft = ""
    @State private var labelDraft = ""
    @State private var tagsDraft = ""
    @State private var loadedID: UUID?
    @FocusState private var focus: Field?

    private enum Field { case synopsis, label, tags }

    init(session: WriterSession, appState: AppState) {
        self.session = session
        self.appState = appState
        self.world = session.world
    }

    private var store: ManuscriptProjectStore { session.projectStore }

    private var node: ManuscriptNode? {
        guard let url = appState.selectedDocument?.url else { return nil }
        return store.node(forFileURL: url)
    }

    var body: some View {
        Group {
            if let document = appState.selectedDocument, let url = document.url, world.catalog.card(forURL: url) != nil {
                StoryCardInspectorView(session: session, appState: appState, document: document)
                    .id(document.id)
            } else if store.state != .loaded {
                message(stateText)
            } else if appState.selectedDocument?.url == nil {
                message(L10n.tr("请先保存文档，再将其加入项目。"))
            } else if let node {
                form(node)
            } else {
                VStack(spacing: 10) {
                    message(L10n.tr("此文档不在书稿项目中。"))
                    Button(L10n.tr("纳入书稿")) { appState.addCurrentDocumentToProject() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.projectID) {
            if world.catalog.cards.isEmpty, !world.catalog.isLoading { appState.refreshWorld() }
        }
    }

    private var stateText: String {
        switch store.state {
        case .readOnlyNewerVersion: ManuscriptProjectError.readOnly.localizedDescription
        case .unreadable: L10n.tr("项目文件已损坏，无法读取。")
        default: L10n.tr("项目文件 .laceditor/project.json 不存在。")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
    }

    private func form(_ node: ManuscriptNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(node.title).font(.headline).lineLimit(2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("梗概")).font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $synopsisDraft)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 130)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        .focused($focus, equals: .synopsis)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            commit(node.id)
                            return .handled
                        }
                        .accessibilityLabel(L10n.tr("梗概"))
                        .accessibilityIdentifier("writer.scene.synopsis")
                }

                Picker(L10n.tr("状态"), selection: Binding(
                    get: { node.status ?? "" },
                    set: { setStatus($0.isEmpty ? nil : $0, id: node.id) }
                )) {
                    Text(L10n.tr("无状态")).tag("")
                    ForEach(store.project?.statuses ?? [], id: \.title) { status in
                        HStack { StatusDot(color: status.color, title: status.title); Text(status.title) }.tag(status.title)
                    }
                    if let current = node.status, !(store.project?.statuses.contains { $0.title == current } ?? false) {
                        Text(current).tag(current)
                    }
                }
                .accessibilityIdentifier("writer.scene.status")

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("标记")).font(.subheadline).foregroundStyle(.secondary)
                    TextField("", text: $labelDraft)
                        .focused($focus, equals: .label)
                        .onSubmit { commit(node.id) }
                        .accessibilityLabel(L10n.tr("标记"))
                        .accessibilityIdentifier("writer.scene.label")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("标签")).font(.subheadline).foregroundStyle(.secondary)
                    TextField(L10n.tr("用逗号分隔"), text: $tagsDraft)
                        .focused($focus, equals: .tags)
                        .onSubmit { commit(node.id) }
                        .accessibilityLabel(L10n.tr("标签"))
                        .accessibilityIdentifier("writer.scene.tags")
                }

                Toggle(L10n.tr("纳入书稿"), isOn: Binding(
                    get: { node.include },
                    set: { _ in appState.toggleManuscriptInclude(node.id) }
                ))
                .accessibilityIdentifier("writer.scene.include")

                StoryCardMentionsSection(session: session, appState: appState, node: node)

                Divider()
                SnapshotsSectionView(appState: appState)
            }
            .padding(12)
        }
        .onAppear { load(node) }
        .onChange(of: node.id) { old, _ in
            // Несохранённые правки уходят прежней сцене, затем поля заполняются новой.
            commit(old)
            load(node)
        }
        .onChange(of: node) { _, changed in
            // Манифест изменён извне: поля, которые сейчас не редактируются, перечитываются.
            if focus == nil, loadedID == changed.id { load(changed) }
        }
        .onChange(of: focus) { old, _ in
            if old != nil { commit(node.id) }
        }
        .onDisappear { commit(node.id) }
    }

    private func load(_ node: ManuscriptNode?) {
        loadedID = node?.id
        synopsisDraft = node?.synopsis ?? ""
        labelDraft = node?.label ?? ""
        tagsDraft = (node?.tags ?? []).joined(separator: ", ")
    }

    private func parsedTags() -> [String] {
        var seen = Set<String>()
        return tagsDraft.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Сохраняет поля сцены `id`, если они менялись.
    private func commit(_ id: UUID) {
        guard loadedID == id, let current = store.node(id: id) else { return }
        let synopsis = synopsisDraft.isEmpty ? nil : synopsisDraft
        let label = labelDraft.trimmingCharacters(in: .whitespaces).isEmpty ? nil : labelDraft.trimmingCharacters(in: .whitespaces)
        let tags = parsedTags()
        guard synopsis != current.synopsis || label != current.label || tags != current.tags else { return }
        do {
            try store.update { project in
                project.mutateNode(id: id) {
                    $0.synopsis = synopsis
                    $0.label = label
                    $0.tags = tags
                }
            }
        } catch {
            appState.sidebarFeedback.show(error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    private func setStatus(_ status: String?, id: UUID) {
        do {
            try store.update { $0.mutateNode(id: id) { $0.status = status } }
        } catch {
            appState.sidebarFeedback.show(error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }
}
