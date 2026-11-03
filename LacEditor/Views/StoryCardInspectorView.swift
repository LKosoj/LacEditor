import SwiftUI

/// Правая панель для документа-карточки: тип, псевдонимы, связи, сцены с упоминаниями и AI-подсказки.
/// Шапка разбирается по живому тексту открытого документа; каталог видит правки только после сохранения.
struct StoryCardInspectorView: View {
    @ObservedObject var session: WriterSession
    @ObservedObject var world: StoryCardWorld
    @ObservedObject var appState: AppState
    let document: EditorDocument
    @EnvironmentObject private var windowManager: WindowManager
    @State private var card: StoryCard?
    @State private var aliasDraft = ""
    @State private var relationTarget = ""
    @State private var relationKind = ""
    @State private var scenes: [StoryCardSceneCount] = []
    @State private var scenesComplete = true
    @State private var editTick = 0
    @State private var showsAllScenes = false
    @State private var factChoices = Set<UUID>()
    @State private var relationChoices = Set<UUID>()

    init(session: WriterSession, appState: AppState, document: EditorDocument) {
        self.session = session
        self.world = session.world
        self.appState = appState
        self.document = document
    }

    private var catalog: StoryCardCatalog { world.catalog }
    private var ai: StoryCardAIController { world.ai }
    /// Результаты AI показываются и применяются только для документа, для которого запрос был сделан.
    private var aiIsMine: Bool { ai.documentID == document.id }

    private struct RefreshKey: Equatable {
        var documentID: UUID
        var savedAt: Date?
        var cardCount: Int
        var editTick: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let card {
                    Text(card.title).font(.headline).lineLimit(2)
                    typeRow(card)
                    aliasesSection(card)
                    relationsSection(card)
                    mentionsSection(card)
                    aiSection(card)
                } else {
                    Text(L10n.tr("无法读取此卡片的头部。")).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { reload() }
        .task(id: RefreshKey(documentID: document.id, savedAt: document.lastSavedAt, cardCount: catalog.cards.count, editTick: editTick)) {
            reload()
            await loadScenes()
        }
        .onDisappear { if aiIsMine { ai.clear() } }
        .accessibilityIdentifier("world.inspector")
    }

    // MARK: Разбор

    private func reload() {
        guard let url = document.url else { card = nil; return }
        card = StoryCardHeader.parse(document.synchronizedText(), url: url, root: session.rootURL)
    }

    private func loadScenes() async {
        guard let card else { return }
        let matcher = StoryCardMatcher(cards: catalog.cards.map { $0.url == card.url ? card : $0 })
        let result = await StoryCardMentionService.scenesResult(of: card, matcher: matcher, store: session.projectStore,
                                                                windowManager: windowManager, limit: 200)
        guard !Task.isCancelled else { return }
        scenes = result.scenes
        scenesComplete = result.isComplete
    }

    private func edit(_ edit: StoryCardHeaderEdit) {
        appState.applyStoryCardEdit(edit, documentID: document.id)
        reload()
        editTick += 1
    }

    // MARK: Разделы

    private func typeRow(_ card: StoryCard) -> some View {
        Picker(L10n.tr("卡片类型"), selection: Binding(get: { card.type }, set: { edit(.setType($0)) })) {
            ForEach(StoryCardType.allCases) { type in Label(type.title, systemImage: type.symbol).tag(type) }
        }
        .accessibilityIdentifier("world.inspector.type")
    }

    private func aliasesSection(_ card: StoryCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("别名")).font(.subheadline).foregroundStyle(.secondary)
            ForEach(card.aliases, id: \.self) { alias in
                HStack {
                    Text(alias).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { edit(.removeAlias(alias)) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.tr("删除别名 %@", alias))
                }
            }
            HStack {
                TextField(L10n.tr("别名"), text: $aliasDraft)
                    .onSubmit(addAlias)
                    .accessibilityIdentifier("world.inspector.alias")
                Button(L10n.tr("添加别名"), action: addAlias)
                    .disabled(aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addAlias() {
        let value = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        edit(.addAlias(value))
        aliasDraft = ""
    }

    private func relationsSection(_ card: StoryCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("关系")).font(.subheadline).foregroundStyle(.secondary)
            ForEach(Array(card.relations.enumerated()), id: \.offset) { _, relation in
                HStack {
                    if let target = catalog.resolve(reference: relation.to) {
                        Text(relation.kind.isEmpty ? "→" : relation.kind + " →").foregroundStyle(.secondary)
                        Button(target.title) { appState.openStoryCard(target) }.buttonStyle(.link)
                    } else {
                        Text((relation.kind.isEmpty ? "" : relation.kind + " → ") + relation.to).foregroundStyle(.tertiary)
                            .help(L10n.tr("未找到该卡片"))
                    }
                    Spacer(minLength: 0)
                    Button { edit(.removeRelation(relation)) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.tr("删除关系"))
                }
            }
            HStack {
                Picker(L10n.tr("目标卡片"), selection: $relationTarget) {
                    Text("—").tag("")
                    ForEach(catalog.cards.filter { $0.id != card.id }) { other in Text(other.title).tag(StoryCardCatalog.reference(for: other)) }
                }
                .labelsHidden()
                .accessibilityLabel(L10n.tr("目标卡片"))
                TextField(L10n.tr("关系类型"), text: $relationKind)
                Button(L10n.tr("添加关系")) {
                    edit(.addRelation(StoryCardRelation(to: relationTarget, kind: relationKind.trimmingCharacters(in: .whitespacesAndNewlines))))
                    relationTarget = ""
                    relationKind = ""
                }
                .disabled(relationTarget.isEmpty)
            }
        }
    }

    private func mentionsSection(_ card: StoryCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("提及")).font(.subheadline).foregroundStyle(.secondary)
            if scenes.isEmpty {
                Text(scenesComplete ? L10n.tr("暂无提及") : L10n.tr("提及结果不完整")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(showsAllScenes ? scenes : Array(scenes.prefix(5)), id: \.nodeID) { scene in
                    if let node = session.projectStore.node(id: scene.nodeID) {
                        Button("\(node.title) (\(scene.count))") {
                            if let url = session.projectStore.fileURL(for: node) { appState.openFile(url) }
                        }
                        .buttonStyle(.link)
                    }
                }
                if scenes.count > 5, !showsAllScenes {
                    Button(L10n.tr("还有 %lld 个", scenes.count - 5)) { showsAllScenes = true }.buttonStyle(.link)
                }
                if !scenesComplete { Text(L10n.tr("提及结果不完整")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: AI

    @ViewBuilder private func aiSection(_ card: StoryCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("AI 建议")).font(.subheadline).foregroundStyle(.secondary)
                AIBadge()
            }
            if appState.aiAvailability(for: .worldCards) == .available {
                HStack {
                    Button(L10n.tr("用 AI 补充")) { Task { await askFacts(card) } }
                        .disabled(ai.isRunning || scenes.isEmpty)
                        .accessibilityIdentifier("world.inspector.facts")
                    Button(L10n.tr("用 AI 建议关系")) { Task { await askRelations(card) } }
                        .disabled(ai.isRunning || scenes.isEmpty)
                        .accessibilityIdentifier("world.inspector.relations")
                    if ai.isRunning { ProgressView().controlSize(.small) }
                }
            } else {
                AIRecommendationHint(feature: .worldCards, message: L10n.tr("开启 AI 后可从场景中补充卡片内容"))
            }
            if aiIsMine, !ai.message.isEmpty {
                AIPanelMessageView(kind: ai.messageKind, text: ai.message, action: ai.messageAction,
                                   openSettings: openAISettings, retry: { Task { await retryLast(card) } }, sendAnyway: { ai.sendAnyway() })
            }
            if aiIsMine, !ai.facts.isEmpty {
                ForEach(ai.facts) { fact in
                    choice(fact.id, set: $factChoices, text: fact.fact, quote: fact.quote)
                }
                Button(L10n.tr("应用所选")) {
                    let chosen = ai.facts.filter { !factChoices.contains($0.id) }.map(\.fact)
                    appState.applyStoryCardFacts(chosen, documentID: document.id)
                    ai.facts = []
                    factChoices = []
                    reload()
                }
            }
            if aiIsMine, !ai.relations.isEmpty {
                ForEach(ai.relations) { relation in
                    choice(relation.id, set: $relationChoices,
                           text: (relation.kind.isEmpty ? "" : relation.kind + " → ") + relation.targetTitle, quote: relation.quote)
                }
                Button(L10n.tr("应用所选")) {
                    // Все связи одним патчем: один шаг отмены, повторы пропускаются.
                    let edits = ai.relations.filter { !relationChoices.contains($0.id) }.compactMap { relation -> StoryCardHeaderEdit? in
                        catalog.card(forKey: relation.targetKey).map {
                            StoryCardHeaderEdit.addRelation(StoryCardRelation(to: StoryCardCatalog.reference(for: $0), kind: relation.kind))
                        }
                    }
                    appState.applyStoryCardEdits(edits, documentID: document.id)
                    reload()
                    editTick += 1
                    ai.relations = []
                    relationChoices = []
                }
            }
        }
    }

    /// `set` хранит снятые флажки: по умолчанию предложение выбрано.
    private func choice(_ id: UUID, set: Binding<Set<UUID>>, text: String, quote: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Toggle(text, isOn: Binding(
                get: { !set.wrappedValue.contains(id) },
                set: { if $0 { set.wrappedValue.remove(id) } else { set.wrappedValue.insert(id) } }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                Text(quote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceText() async -> String {
        await StoryCardMentionService.sourceText(of: scenes, limit: 10, store: session.projectStore, windowManager: windowManager)
    }

    /// Повтор последнего запроса: «факты» или «связи» (по умолчанию факты).
    private func retryLast(_ card: StoryCard) async {
        if ai.lastMode == .relations { await askRelations(card) } else { await askFacts(card) }
    }

    private func askFacts(_ card: StoryCard) async {
        ai.suggestFacts(for: card, document: document, sourceText: await sourceText())
    }

    private func askRelations(_ card: StoryCard) async {
        ai.suggestRelations(for: card, document: document, known: catalog.cards, sourceText: await sourceText())
    }

    private func openAISettings() {
        SettingsNavigator.shared.open(.ai, aiPage: appState.aiAvailability(for: .worldCards) == .featureDisabled ? .features : .connections)
        SettingsWindowController.shared.present(windowManager: windowManager)
    }
}
