import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Состояние окна ментальной карты. Карта документа — вид текста: любая правка идёт правкой текста через редактор.
/// Живёт столько же, сколько окно. На диск ничего не пишет, кроме выбора раскладки и вида в `UserDefaults`.
@MainActor
final class MindMapController: ObservableObject {
    enum Presentation: String { case diagram, list }
    enum Direction { case up, down, left, right }
    enum AIOperation: Equatable { case build, expand(Int) }
    enum AIState: Equatable { case idle, working, needsConfirm(bytes: Int) }

    struct IdeasPreview: Equatable {
        var nodeID: Int
        var ideas: [String]
        var selected: Set<Int>
    }

    private enum Keys {
        static let layout = "LacEditor.mindMap.layout"
        static let presentation = "LacEditor.mindMap.presentation"
        static let minShared = "LacEditor.mindMap.minSharedScenes"
    }

    private static let zoomRange: ClosedRange<CGFloat> = 0.25...3
    private static let maxPNGSide: CGFloat = 8192

    weak var appState: AppState?
    weak var windowManager: WindowManager?
    /// Название окна зависит от вида и документа.
    var titleChanged: ((String) -> Void)?

    @Published private(set) var kind: MindMapKind
    @Published private(set) var tree = MindMapTree.empty
    @Published private(set) var graph = MindMapGraph.empty
    @Published private(set) var layout = MindMapLayoutResult.empty
    @Published private(set) var edges: [MindMapEdge] = []
    @Published private(set) var unavailableMessage: String?
    @Published private(set) var selectedID: Int?
    @Published private(set) var collapsed: Set<Int> = []
    @Published var renamingID: Int?
    @Published var pendingDelete: Int?
    @Published var zoomLevel: CGFloat = 1
    @Published var showAllCards = false {
        didSet { if oldValue != showAllCards { refreshLinks(recompute: false) } }
    }
    @Published var layoutStyle: MindMapLayoutStyle {
        didSet {
            guard oldValue != layoutStyle else { return }
            UserDefaults.standard.set(layoutStyle.rawValue, forKey: Keys.layout)
            relayout()
        }
    }
    @Published var presentation: Presentation {
        didSet {
            guard oldValue != presentation else { return }
            UserDefaults.standard.set(presentation.rawValue, forKey: Keys.presentation)
            presentationChosen = true
        }
    }
    @Published var minSharedScenes: Int {
        didSet {
            guard oldValue != minSharedScenes else { return }
            UserDefaults.standard.set(minSharedScenes, forKey: Keys.minShared)
            refreshLinks(recompute: false)
        }
    }
    @Published private(set) var aiState: AIState = .idle
    @Published private(set) var aiMessage = ""
    @Published private(set) var aiMessageKind: StatusKind = .info
    @Published private(set) var aiMessageAction: AIMessageAction?
    @Published private(set) var mapPreview: MindMapAIMap?
    @Published var ideas: IdeasPreview?
    let feedback = InlineFeedbackState()

    var renameSeed: String?
    /// Размер видимой области: нужен для «Подогнать».
    var viewport = CGSize.zero

    private var presentationChosen: Bool
    private var treeRevision: UInt = 0
    private var parseGeneration = 0
    private var layoutGeneration = 0
    private var layoutTask: Task<Void, Never>?
    private var projectTask: Task<Void, Never>?
    private var linksTask: Task<Void, Never>?
    private var linksInputs: (co: [StoryCardPair: Int], wiki: [String: [String]])?
    private var collapsedKeys: Set<String> = []
    private var selectedKey: String?
    private var didAutoCollapse = false
    private var pendingRename = false
    private var aiGeneration = 0
    private var aiTask: Task<Void, Never>?
    private var pendingAI: AIOperation?
    private var cancellables: Set<AnyCancellable> = []
    private var sessionCancellables: Set<AnyCancellable> = []
    private var boundSessionID: ObjectIdentifier?
    private var sessionBoundOnce = false
    private var documentTask: Task<Void, Never>?
    private var requestedBytes = 0
    private var approvedBytes = 0
    private var documentCancellable: AnyCancellable?
    private var observedDocumentID: UUID?

    init(appState: AppState, windowManager: WindowManager, kind: MindMapKind) {
        self.appState = appState
        self.windowManager = windowManager
        self.kind = kind
        let defaults = UserDefaults.standard
        layoutStyle = defaults.string(forKey: Keys.layout).flatMap(MindMapLayoutStyle.init(rawValue:)) ?? .tree
        if let stored = defaults.string(forKey: Keys.presentation).flatMap(Presentation.init(rawValue:)) {
            presentation = stored
            presentationChosen = true
        } else {
            presentation = NSWorkspace.shared.isVoiceOverEnabled ? .list : .diagram
            presentationChosen = false
        }
        let shared = defaults.integer(forKey: Keys.minShared)
        minSharedScenes = shared > 0 ? shared : 2
        bind()
        refresh()
    }

    // MARK: Подписки

    private func bind() {
        guard let appState else { return }
        appState.$selectedDocumentID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.documentChanged() }
            .store(in: &cancellables)
        appState.$writerSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.bindSession() }
            .store(in: &cancellables)
        bindSession()
    }

    /// Подписки на проект, счётчик слов и каталог карточек привязаны к текущей писательской сессии и пересоздаются при её смене.
    private func bindSession() {
        let session = appState?.writerSession
        let identifier = session.map(ObjectIdentifier.init)
        guard identifier != boundSessionID else { return }
        let initial = !sessionBoundOnce
        sessionBoundOnce = true
        boundSessionID = identifier
        sessionCancellables.removeAll()
        linksInputs = nil
        guard let session else { return }
        session.projectStore.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.projectChanged() }
            .store(in: &sessionCancellables)
        session.wordCounter.$counts
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in if self?.kind == .project { self?.refreshProject() } }
            .store(in: &sessionCancellables)
        session.world.catalog.$cards
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in if self?.kind == .links { self?.refreshLinks(recompute: true) } }
            .store(in: &sessionCancellables)
        if !initial { projectChanged() }
    }

    private func projectChanged() {
        switch kind {
        case .project: refreshProject()
        case .links: refreshLinks(recompute: true)
        case .document: break
        }
    }

    private func documentChanged() {
        cancelAI()
        mapPreview = nil
        ideas = nil
        collapsedKeys = []
        selectedKey = nil
        didAutoCollapse = false
        observeDocument()
        if kind == .document { refresh() }
        titleChanged?(windowSubject)
    }

    private func observeDocument() {
        guard let document, document.id != observedDocumentID else { return }
        observedDocumentID = document.id
        documentCancellable = document.textEdits
            .debounce(for: .seconds(EditorDocument.typingPause), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in if self?.kind == .document { self?.refreshDocument() } }
    }

    // MARK: Общее

    var document: EditorDocument? { appState?.selectedDocument }

    var windowSubject: String {
        switch kind {
        case .document: document?.displayName ?? L10n.tr("未命名")
        case .project, .links: appState?.writerSession?.title ?? L10n.tr("未命名")
        }
    }

    static func unavailableReason(of document: EditorDocument) -> String? {
        if document.language != .markdown { return L10n.tr("导图仅适用于 Markdown 文档") }
        if document.isLargeFileMode { return L10n.tr("文件过大，无法生成导图") }
        return nil
    }

    var nodes: [MindMapNode] { kind == .links ? graph.nodes : tree.nodes }

    func node(_ id: Int) -> MindMapNode? { nodes.indices.contains(id) ? nodes[id] : nil }

    /// Узлы по порядку обхода для режима «Список» и перехода стрелками.
    var visibleIDs: [Int] {
        switch kind {
        case .links: graph.nodes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.id)
        default: tree.visibleIDs(collapsed: collapsed)
        }
    }

    var emptyMessage: String? {
        switch kind {
        case .document: tree.hasStructure ? nil : L10n.tr("此文档还没有标题或列表，无法生成导图。")
        case .project: tree.nodes.count > 1 ? nil : L10n.tr("当前书稿还没有内容。")
        case .links: graph.nodes.isEmpty ? L10n.tr("还没有设定卡片，无法生成关系图。") : nil
        }
    }

    /// Структурные правки текста (кроме переименования) в усечённой карте отключены: пропущенные узлы нельзя перенести.
    var canEditStructure: Bool {
        kind == .document && unavailableMessage == nil && !tree.truncated && document?.isReadingMode == false
    }

    var canRename: Bool {
        kind == .document && unavailableMessage == nil && document?.isReadingMode == false
    }

    var canUseAI: Bool { kind == .document && unavailableMessage == nil && appState?.aiAvailability(for: .mindMap) == .available }

    var isAIVisible: Bool { kind == .document && unavailableMessage == nil }

    var shownCountText: String? {
        guard kind == .links, !graph.nodes.isEmpty || graph.hiddenNodeCount > 0 else { return nil }
        return L10n.tr("显示 %lld / %lld 个条目", graph.nodes.count, graph.nodes.count + graph.hiddenNodeCount)
    }

    var truncationText: String? {
        kind == .document && tree.truncated ? L10n.tr("结构过大，仅显示前 %lld 个节点", MindMapLimits.documentNodes) : nil
    }

    func setKind(_ newKind: MindMapKind) {
        guard newKind != kind else { return }
        if newKind != .document, appState?.writerSession == nil { return }
        cancelAI()
        mapPreview = nil
        ideas = nil
        kind = newKind
        selectedKey = nil
        selectedID = nil
        renamingID = nil
        refresh()
        titleChanged?(windowSubject)
    }

    func refresh() {
        observeDocument()
        switch kind {
        case .document: refreshDocument()
        case .project: refreshProject()
        case .links: refreshLinks(recompute: true)
        }
    }

    func stop() {
        cancelAI()
        layoutTask?.cancel()
        projectTask?.cancel()
        linksTask?.cancel()
        documentTask?.cancel()
        parseGeneration &+= 1
        cancellables.removeAll()
        sessionCancellables.removeAll()
        boundSessionID = nil
        documentCancellable = nil
        observedDocumentID = nil
    }

    // MARK: Документ

    private func fallbackTitle(_ document: EditorDocument) -> String {
        let name = (document.displayName as NSString).deletingPathExtension
        return name.isEmpty ? L10n.tr("未命名") : name
    }

    func refreshDocument(focusLocation: Int? = nil) {
        guard kind == .document else { return }
        parseGeneration &+= 1
        let generation = parseGeneration
        guard let document else {
            unavailableMessage = L10n.tr("导图仅适用于 Markdown 文档")
            install(tree: .empty, focusLocation: nil)
            return
        }
        if let reason = Self.unavailableReason(of: document) {
            unavailableMessage = reason
            install(tree: .empty, focusLocation: nil)
            return
        }
        unavailableMessage = nil
        let snapshot = document.synchronizedSnapshot()
        let fallback = fallbackTitle(document)
        if snapshot.utf16Length <= 300_000 {
            treeRevision = snapshot.revision
            install(tree: MindMapDocumentParser.parse(snapshot.text, fallbackTitle: fallback), focusLocation: focusLocation)
            return
        }
        documentTask?.cancel()
        documentTask = Task { [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) {
                MindMapDocumentParser.parse(snapshot.text, fallbackTitle: fallback)
            }.value
            guard let self, self.parseGeneration == generation else { return }
            self.treeRevision = snapshot.revision
            self.install(tree: parsed, focusLocation: focusLocation)
        }
    }

    /// Ключ узла, переживающий перестроение: путь названий у документа, id у проекта и карточек.
    private func stableKey(_ id: Int, in tree: MindMapTree) -> String? {
        guard let node = tree.node(id) else { return nil }
        if kind != .document { return node.key }
        var parts = [node.title]
        var current = node.parentID
        while let parent = current, let up = tree.node(parent) {
            parts.append(up.title)
            current = up.parentID
        }
        return parts.reversed().joined(separator: "\u{1F}")
    }

    private func install(tree newTree: MindMapTree, focusLocation: Int?) {
        let previousSelection = selectedID.flatMap { stableKey($0, in: tree) } ?? selectedKey
        tree = newTree
        var byKey: [String: Int] = [:]
        for node in newTree.nodes {
            if let key = stableKey(node.id, in: newTree), byKey[key] == nil { byKey[key] = node.id }
        }
        // Большая карта открывается свёрнутой глубже второго уровня; дальше выбор пользователя сохраняется.
        if !didAutoCollapse, newTree.nodes.count > MindMapLimits.collapseDeepThreshold {
            didAutoCollapse = true
            collapsedKeys = Set(newTree.nodes.filter { !$0.childIDs.isEmpty && newTree.depth(of: $0.id) >= 2 }
                .compactMap { stableKey($0.id, in: newTree) })
        }
        collapsed = Set(collapsedKeys.compactMap { byKey[$0] })
        var selection = previousSelection.flatMap { byKey[$0] }
        if let focusLocation, kind == .document {
            let target = newTree.nodes.filter { ($0.lineRange?.location ?? Int.max) <= focusLocation && $0.kind != .virtualRoot }
                .max { ($0.lineRange?.location ?? 0) < ($1.lineRange?.location ?? 0) }
            if let target { selection = target.id }
        }
        if selection == nil, newTree.node(newTree.rootID) != nil { selection = newTree.rootID }
        if let selection, !isVisible(selection, in: newTree) { selection = newTree.rootID }
        selectedID = selection
        selectedKey = selection.flatMap { stableKey($0, in: newTree) }
        if pendingRename, let selection, newTree.node(selection)?.kind != .virtualRoot {
            renamingID = selection
        } else if let renamingID, newTree.node(renamingID) == nil {
            self.renamingID = nil
        }
        pendingRename = false
        relayout()
    }

    private func isVisible(_ id: Int, in tree: MindMapTree) -> Bool {
        var current = tree.node(id)?.parentID
        while let parent = current {
            if collapsed.contains(parent) { return false }
            current = tree.node(parent)?.parentID
        }
        return true
    }

    // MARK: Проект

    func refreshProject() {
        guard kind == .project, let appState, let session = appState.writerSession, let project = session.projectStore.project else {
            unavailableMessage = nil
            install(tree: .empty, focusLocation: nil)
            return
        }
        unavailableMessage = nil
        let counter = session.wordCounter
        if counter.counts.isEmpty, !counter.isCounting, session.projectStore.state == .loaded {
            counter.refresh(store: session.projectStore, openDocuments: windowManager?.folderSearchSnapshots(root: session.rootURL))
        }
        let counts = counter.counts
        var urls: [UUID: URL] = [:]
        for node in project.allNodes() where node.kind == .text {
            if let url = session.projectStore.fileURL(for: node) { urls[node.id] = url }
        }
        parseGeneration &+= 1
        let generation = parseGeneration
        projectTask?.cancel()
        projectTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { () -> MindMapTree in
                let missing = Set(urls.filter { !FileManager.default.fileExists(atPath: $0.value.path) }.keys)
                return MindMapProjectBuilder.build(project: project, wordCounts: counts, missing: missing)
            }.value
            guard let self, !Task.isCancelled, self.parseGeneration == generation, self.kind == .project else { return }
            self.install(tree: built, focusLocation: nil)
        }
    }

    // MARK: Связи

    func refreshLinks(recompute: Bool) {
        guard kind == .links else { return }
        guard let appState, let session = appState.writerSession else {
            unavailableMessage = nil
            graph = .empty
            relayout()
            return
        }
        unavailableMessage = nil
        let catalog = session.world.catalog
        if catalog.cards.isEmpty, !catalog.isLoading { appState.refreshWorld() }
        let cards = catalog.cards
        if !recompute, let inputs = linksInputs {
            installGraph(cards: cards, co: inputs.co, wiki: inputs.wiki)
            return
        }
        parseGeneration &+= 1
        let generation = parseGeneration
        linksTask?.cancel()
        let manager = windowManager
        let store = session.projectStore
        linksTask = Task { [weak self] in
            let index = await StoryCardMentionService.buildIndex(cards: cards, store: store, windowManager: manager)
            let wiki = await Task.detached(priority: .userInitiated) { Self.wikiTargets(of: cards) }.value
            guard let self, !Task.isCancelled, self.parseGeneration == generation, self.kind == .links else { return }
            let co = index.coMentions()
            self.linksInputs = (co, wiki)
            self.installGraph(cards: cards, co: co, wiki: wiki)
        }
    }

    private func installGraph(cards: [StoryCard], co: [StoryCardPair: Int], wiki: [String: [String]]) {
        guard let catalog = appState?.writerSession?.world.catalog else { return }
        let limit = showAllCards ? MindMapLimits.graphHard : MindMapLimits.graphDefault
        let built = MindMapLinksBuilder.build(cards: cards, resolve: { catalog.resolve(reference: $0) }, coMentions: co,
                                              wikiLinks: wiki, minSharedScenes: minSharedScenes, limit: limit)
        let previous = selectedKey
        graph = built
        let index = built.nodes.first { $0.key == previous }?.id ?? built.nodes.first?.id
        selectedID = index
        selectedKey = index.flatMap { built.nodes[$0].key }
        relayout()
    }

    /// Цели wiki-ссылок в тексте карточек. Читаются файлы карточек (не больше 512 КБ каждый).
    nonisolated private static func wikiTargets(of cards: [StoryCard]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for card in cards {
            if Task.isCancelled { break }
            guard let handle = try? FileHandle(forReadingFrom: card.url) else { continue }
            let data = try? handle.read(upToCount: 512 * 1_024)
            try? handle.close()
            guard let data else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let targets = MarkdownWikiLinkExtractor.links(in: text).map(\.target).filter { !$0.isEmpty }
            if !targets.isEmpty { result[card.id] = targets }
        }
        return result
    }

    // MARK: Раскладка

    private static let measureFont = NSFont.preferredFont(forTextStyle: .title3)

    private static func measure(_ text: String) -> CGSize {
        (text as NSString).size(withAttributes: [.font: measureFont])
    }

    private func relayout() {
        layoutGeneration &+= 1
        let generation = layoutGeneration
        layoutTask?.cancel()
        switch kind {
        case .links:
            let current = graph
            let metrics = MindMapLayout.metrics(for: current.nodes, measure: Self.measure)
            layoutTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { MindMapLayout.graph(current, metrics: metrics) }.value
                guard let self, !Task.isCancelled, self.layoutGeneration == generation else { return }
                self.layout = result
                self.edges = current.edges
            }
        case .document, .project:
            let current = tree
            let hidden = collapsed
            let metrics = MindMapLayout.metrics(for: current.nodes, measure: Self.measure)
            let useTree = kind == .project || layoutStyle == .tree
            let newEdges: [MindMapEdge] = current.visibleIDs(collapsed: hidden).compactMap { id in
                guard let parent = current.node(id)?.parentID else { return nil }
                return MindMapEdge(from: parent, to: id, style: .relation, weight: 1)
            }
            layoutTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    useTree ? MindMapLayout.tree(current, collapsed: hidden, metrics: metrics)
                        : MindMapLayout.radial(current, collapsed: hidden, metrics: metrics)
                }.value
                guard let self, !Task.isCancelled, self.layoutGeneration == generation else { return }
                self.layout = result
                self.edges = newEdges
            }
        }
    }

    // MARK: Выбор и свёртка

    func select(_ id: Int?) {
        selectedID = id
        selectedKey = id.flatMap { kind == .links ? graph.nodes[safe: $0]?.key : stableKey($0, in: tree) }
    }

    func isCollapsed(_ id: Int) -> Bool { collapsed.contains(id) }

    func toggleCollapse(_ id: Int) {
        guard kind != .links, let node = tree.node(id), !node.childIDs.isEmpty, let key = stableKey(id, in: tree) else { return }
        if collapsed.contains(id) {
            collapsed.remove(id)
            collapsedKeys.remove(key)
        } else {
            collapsed.insert(id)
            collapsedKeys.insert(key)
            if let selectedID, selectedID != id, tree.isDescendant(selectedID, of: id) { select(id) }
        }
        relayout()
        announce(collapsed.contains(id) ? L10n.tr("折叠") : L10n.tr("展开节点"))
    }

    func expandAll() {
        collapsed = []
        collapsedKeys = []
        relayout()
    }

    func moveSelection(_ direction: Direction) {
        guard let current = selectedID else { select(visibleIDs.first); return }
        if kind == .links {
            let order = visibleIDs
            guard let position = order.firstIndex(of: current) else { return }
            switch direction {
            case .up, .left: if position > 0 { select(order[position - 1]) }
            case .down, .right: if position + 1 < order.count { select(order[position + 1]) }
            }
            return
        }
        guard let node = tree.node(current) else { return }
        switch direction {
        case .up:
            if let sibling = tree.sibling(of: current, offset: -1) { select(sibling) }
        case .down:
            if let sibling = tree.sibling(of: current, offset: 1) { select(sibling) }
        case .left:
            if let parent = node.parentID { select(parent) }
        case .right:
            guard let first = node.childIDs.first else { return }
            if collapsed.contains(current) { toggleCollapse(current) }
            select(first)
        }
    }

    // MARK: Правки документа

    /// Правка текста по актуальному дереву. Узлы сверяются с текстом редактора; расхождение — «Текст изменился».
    private func editDocument(announce message: String, action: String, build: @escaping (MindMapTree, String) -> MindMapTextEdit?) {
        guard kind == .document, let appState, let document, unavailableMessage == nil else { pendingRename = false; return }
        let snapshot = tree
        let fallback = fallbackTitle(document)
        var stale = false
        let result = appState.applyMindMapEdit(documentID: document.id, expectedTextRevision: treeRevision, actionName: action) { text in
            let parsed = MindMapDocumentParser.parse(text, fallbackTitle: fallback)
            guard parsed.nodes.count == snapshot.nodes.count,
                  zip(parsed.nodes, snapshot.nodes).allSatisfy({ $0.title == $1.title && $0.titleRange == $1.titleRange }) else {
                stale = true
                return nil
            }
            return build(parsed, text)
        }
        switch result {
        case let .applied(edit):
            feedback.show(message, undo: { [weak self] in self?.undo(); return true })
            announce(message)
            refreshDocument(focusLocation: edit.focusLocation)
        case let .failed(reason):
            pendingRename = false
            feedback.show(stale ? L10n.tr("文本已变化") : reason, symbol: "exclamationmark.triangle")
            refreshDocument()
        }
    }

    func rename(_ id: Int, to title: String) {
        renamingID = nil
        let clean = MindMapEditor.sanitized(title)
        guard canRename, let node = tree.node(id), node.kind != .virtualRoot, !clean.isEmpty, clean != node.title else { return }
        editDocument(announce: L10n.tr("已重命名节点"), action: L10n.tr("重命名")) { parsed, text in
            MindMapEditor.rename(parsed, nodeID: id, newTitle: clean, in: text)
        }
    }

    func addChild(_ id: Int) {
        guard canEditStructure else { return }
        pendingRename = true
        editDocument(announce: L10n.tr("已添加节点"), action: L10n.tr("添加子节点")) { parsed, text in
            MindMapEditor.addChild(parsed, nodeID: id, in: text)
        }
    }

    func addSibling(_ id: Int) {
        guard canEditStructure, let node = tree.node(id), node.parentID != nil else { return }
        pendingRename = true
        editDocument(announce: L10n.tr("已添加节点"), action: L10n.tr("添加同级节点")) { parsed, text in
            MindMapEditor.addSibling(parsed, nodeID: id, in: text)
        }
    }

    /// Переименование на месте. `seed` — напечатанный символ, с которого начинается новое название.
    func beginRename(_ id: Int, seed: String? = nil) {
        guard canRename, let node = tree.node(id), node.kind != .virtualRoot else { return }
        renameSeed = seed
        select(id)
        renamingID = id
    }

    func requestDelete(_ id: Int) {
        guard canEditStructure, let node = tree.node(id), node.parentID != nil else { return }
        if tree.subtreeCount(of: id) > 1 { pendingDelete = id } else { performDelete(id) }
    }

    func performDelete(_ id: Int) {
        pendingDelete = nil
        guard canEditStructure else { return }
        let parent = tree.node(id)?.parentID
        editDocument(announce: L10n.tr("已删除节点"), action: L10n.tr("删除节点")) { parsed, text in
            MindMapEditor.delete(parsed, nodeID: id, in: text)
        }
        if let parent, selectedID == nil { select(parent) }
    }

    /// Узел `id` становится последним ребёнком `target` (перетаскивание). Документ — правка текста, проект — порядок в манифесте.
    func move(_ id: Int, onto target: Int) {
        switch kind {
        case .document:
            guard canEditStructure, id != target, let parent = tree.node(target) else { return }
            moveInDocument(id, toParent: target, index: parent.childIDs.filter { $0 != id }.count)
        case .project:
            guard let state = appState, let moving = tree.node(id), let destination = tree.node(target),
                  moving.parentID != nil, !tree.isDescendant(target, of: id),
                  destination.kind == .group || destination.kind == .virtualRoot,
                  let movingID = UUID(uuidString: moving.key) else {
                feedback.show(L10n.tr("无法移动到此处"), symbol: "exclamationmark.triangle")
                return
            }
            let parentID = destination.kind == .virtualRoot ? nil : UUID(uuidString: destination.key)
            state.moveManuscriptNode(movingID, toParent: parentID, index: destination.childIDs.filter { $0 != id }.count)
            feedback.show(L10n.tr("已移动节点"))
            announce(L10n.tr("已移动节点"))
        case .links:
            break
        }
    }

    /// Перенос узла документа: узел `id` встаёт под `parent` на позицию `index` (без учёта самого узла).
    private func moveInDocument(_ id: Int, toParent target: Int, index: Int) {
        var refused = false
        var unchanged = false
        if let document {
            let text = document.synchronizedSnapshot().text
            switch MindMapEditor.move(tree, nodeID: id, toParent: target, index: index, in: text) {
            case .refused: refused = true
            case .unchanged: unchanged = true
            case .edit: break
            }
        }
        if refused { feedback.show(L10n.tr("无法移动到此处"), symbol: "exclamationmark.triangle"); return }
        if unchanged { return }
        editDocument(announce: L10n.tr("已移动节点"), action: L10n.tr("已移动节点")) { parsed, text in
            if case let .edit(edit) = MindMapEditor.move(parsed, nodeID: id, toParent: target, index: index, in: text) { return edit }
            return nil
        }
    }

    /// Есть ли у узла документа предыдущий брат (для «Сделать дочерним предыдущему»).
    func canIndent(_ id: Int) -> Bool {
        kind == .document && canEditStructure && tree.node(id)?.parentID != nil && tree.sibling(of: id, offset: -1) != nil
    }

    /// Есть ли у узла документа дедушка (для «Поднять на уровень»).
    func canOutdent(_ id: Int) -> Bool {
        guard kind == .document, canEditStructure, let parent = tree.node(id)?.parentID else { return false }
        return tree.node(parent)?.parentID != nil
    }

    /// «Сделать дочерним предыдущему»: узел становится последним ребёнком предыдущего брата.
    func indent(_ id: Int) {
        guard canIndent(id), let previous = tree.sibling(of: id, offset: -1), let target = tree.node(previous) else { return }
        moveInDocument(id, toParent: previous, index: target.childIDs.count)
    }

    /// «Поднять на уровень»: узел встаёт сразу после своего родителя.
    func outdent(_ id: Int) {
        guard canOutdent(id), let parent = tree.node(id)?.parentID, let grand = tree.node(parent)?.parentID,
              let siblings = tree.node(grand)?.childIDs, let position = siblings.firstIndex(of: parent) else { return }
        moveInDocument(id, toParent: grand, index: position + 1)
    }

    /// «提前» и «延后» для проекта.
    func shiftProject(_ id: Int, by delta: Int) {
        guard kind == .project, let state = appState, let node = tree.node(id), node.parentID != nil,
              let uuid = UUID(uuidString: node.key) else { return }
        if delta < 0 { state.moveManuscriptNodeUp(uuid) } else { state.moveManuscriptNodeDown(uuid) }
    }

    func goToText(_ id: Int) {
        guard let state = appState, let node = node(id) else { return }
        switch kind {
        case .document:
            guard let document, let range = node.titleRange ?? node.lineRange else { return }
            state.jump(to: NSRange(location: range.location, length: 0), in: document)
        case .project:
            guard let uuid = UUID(uuidString: node.key) else { return }
            if node.kind == .scene { state.openManuscriptNode(uuid) } else if node.kind == .group { state.presentWriterCombinedView(scope: .group(uuid)) }
        case .links:
            if let card = state.writerSession?.world.catalog.cards.first(where: { $0.id == node.key }) { state.openStoryCard(card) }
        }
    }

    func undo() { postEditorCommand(EditorCommandNotification.undo) }
    func redo() { postEditorCommand(EditorCommandNotification.redo) }

    private func postEditorCommand(_ name: Notification.Name) {
        guard kind == .document, let document else { return }
        NotificationCenter.default.post(name: name, object: document.id)
        refreshDocument()
    }

    // MARK: Масштаб

    func zoom(_ action: MindMapZoomRouter.Action) {
        switch action {
        case .zoomIn: zoomLevel = min(Self.zoomRange.upperBound, zoomLevel * 1.25)
        case .zoomOut: zoomLevel = max(Self.zoomRange.lowerBound, zoomLevel / 1.25)
        case .reset: zoomLevel = 1
        }
    }

    func fitToWindow() {
        guard layout.size.width > 0, layout.size.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        let fit = min(viewport.width / layout.size.width, viewport.height / layout.size.height)
        zoomLevel = max(Self.zoomRange.lowerBound, min(Self.zoomRange.upperBound, fit))
    }

    func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Для списка и подсказок

    func level(of id: Int) -> Int { kind == .links ? 0 : tree.depth(of: id) }

    func childCount(of id: Int) -> Int {
        kind == .links ? graph.edges(of: id).count : (tree.node(id)?.childIDs.count ?? 0)
    }

    /// Связанные карточки с видом связи.
    func neighbors(of id: Int) -> [(node: MindMapNode, style: MindMapEdgeStyle, label: String?)] {
        graph.edges(of: id).compactMap { edge in
            let other = edge.from == id ? edge.to : edge.from
            guard let node = graph.nodes[safe: other] else { return nil }
            return (node, edge.style, edge.label)
        }.sorted { $0.node.title.localizedStandardCompare($1.node.title) == .orderedAscending }
    }

    func accessibilityValue(for id: Int) -> String {
        L10n.tr("第 %lld 级，%lld 个子节点", level(of: id) + 1, childCount(of: id))
    }

    // MARK: Экспорт

    private func renderEdges() -> [(Int, Int, MindMapEdgeStyle)] {
        edges.filter { layout.placed[$0.from] != nil && layout.placed[$0.to] != nil }.map { ($0.from, $0.to, $0.style) }
    }

    func exportSVG() {
        let svg = MindMapSVGExporter.svg(layout: layout, nodes: nodes, edges: renderEdges(), curved: kind != .links)
        save(data: Data(svg.utf8), type: .svg, fileExtension: "svg")
    }

    func exportPNG() {
        let side = max(layout.size.width, layout.size.height)
        guard side > 0, side <= Self.maxPNGSide else {
            feedback.show(L10n.tr("地图过大，无法导出为 PNG，请改用 SVG"), symbol: "exclamationmark.triangle")
            return
        }
        let renderer = ImageRenderer(content: MindMapExportImage(layout: layout, nodes: nodes, edges: renderEdges(), curved: kind != .links))
        renderer.scale = min(2, Self.maxPNGSide / side)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            feedback.show(L10n.tr("无法导出"), symbol: "exclamationmark.triangle")
            return
        }
        save(data: data, type: .png, fileExtension: "png")
    }

    private func save(data: Data, type: UTType, fileExtension: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (windowSubject as NSString).deletingPathExtension + "." + fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            feedback.show(L10n.tr("导出完成"))
            announce(L10n.tr("导出完成"))
        } catch {
            feedback.show(L10n.tr("无法导出") + "：" + error.localizedDescription, symbol: "exclamationmark.triangle")
        }
    }

    // MARK: AI

    private func postAI(_ text: String, _ kind: StatusKind = .error, action: AIMessageAction? = nil) {
        aiMessage = text
        aiMessageKind = kind
        aiMessageAction = action
        announce(text)
    }

    func clearAIMessage() {
        aiMessage = ""
        aiMessageAction = nil
    }

    func cancelAI() {
        aiGeneration &+= 1
        aiTask?.cancel()
        aiTask = nil
        document?.taskCoordinator.cancel(.mindMap)
        aiState = .idle
        pendingAI = nil
        clearAIMessage()
    }

    func discardPreview() {
        mapPreview = nil
        ideas = nil
    }

    func retryAI() {
        guard let operation = pendingAI else { return }
        runAI(operation, approved: false)
    }

    func sendAnyway() {
        guard let operation = pendingAI else { return }
        approvedBytes = requestedBytes
        runAI(operation, approved: true)
    }

    func generateFromText() { runAI(.build, approved: false) }
    func expandNode(_ id: Int) { runAI(.expand(id), approved: false) }

    private func runAI(_ operation: AIOperation, approved: Bool) {
        guard canUseAI, let appState, let document, aiState != .working else { return }
        pendingAI = operation
        clearAIMessage()
        let instructions: String
        let input: String
        let label: String
        let language: String
        switch operation {
        case .build:
            let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: true)
            extraction.space = .display
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
            guard let selection = extraction.result, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                postAI(L10n.tr("文本已变化，请重新检查"), .info)
                return
            }
            language = TextSegmentation.languageCode(for: TextSegmentation.language(of: selection.text)) ?? "unknown"
            instructions = MindMapAIService.buildInstructions(language: language)
            input = MindMapAIService.buildInput(text: selection.text)
            label = AIRequestSize.label(selection)
        case let .expand(id):
            guard let node = tree.node(id) else { return }
            let snapshot = document.synchronizedSnapshot()
            guard snapshot.revision == treeRevision, let range = node.subtreeRange,
                  NSMaxRange(range) <= snapshot.utf16Length else {
                postAI(L10n.tr("文本已变化，请重新检查"), .info)
                return
            }
            let subtree = (snapshot.text as NSString).substring(with: range)
            var path: [String] = []
            var current = node.parentID
            while let parent = current, let up = tree.node(parent) {
                if up.kind != .virtualRoot { path.insert(up.title, at: 0) }
                current = up.parentID
            }
            language = TextSegmentation.languageCode(for: TextSegmentation.language(of: subtree)) ?? "unknown"
            instructions = MindMapAIService.expandInstructions(language: language)
            input = MindMapAIService.expandInput(path: path, title: node.title, subtreeText: subtree,
                                                 existing: node.childIDs.compactMap { tree.node($0)?.title })
            label = L10n.tr("所选文本")
        }
        let bytes = AIRequestSize.bytes(instructions, input)
        if bytes > AIRequestSize.threshold, !(approved && bytes <= approvedBytes) {
            requestedBytes = bytes
            aiState = .needsConfirm(bytes: bytes)
            postAI(AIRequestSize.warning(label: label, bytes: bytes), .info, action: .sendAnyway)
            return
        }
        let profile = appState.preferences.aiProfile(for: .mindMap)
        let key: String?
        do { key = try AIKeychainStore().load(for: AIFeature.mindMap.role, baseURL: profile.baseURL) } catch {
            postAI(error.localizedDescription, .error, action: AIMessageAction.forError(error))
            return
        }
        aiGeneration &+= 1
        let generation = aiGeneration
        aiTask?.cancel()
        let taskGeneration = document.taskCoordinator.begin(.mindMap)
        let sentRevision = document.textRevision
        aiState = .working
        let task = Task { [weak self, weak document] in
            defer {
                document?.taskCoordinator.finish(.mindMap, generation: taskGeneration)
                if let self, self.aiGeneration == generation { self.aiState = .idle }
            }
            do {
                let response = try await AIClient().generateText(input: input, instructions: instructions, profile: profile, key: key, mode: .reading)
                guard let self, let document, !Task.isCancelled, self.aiGeneration == generation, self.document === document,
                      document.taskCoordinator.isCurrent(taskGeneration, for: .mindMap) else { return }
                guard document.textRevision == sentRevision else {
                    self.postAI(L10n.tr("文本已变化，请重新检查"), .info, action: .retry)
                    return
                }
                try self.receive(response, for: operation)
            } catch {
                guard let self, !Task.isCancelled, self.aiGeneration == generation else { return }
                self.postAI(error.localizedDescription, .error, action: AIMessageAction.forError(error))
            }
        }
        aiTask = task
        document.taskCoordinator.attachTask(task, kind: .mindMap, generation: taskGeneration)
    }

    private func receive(_ response: String, for operation: AIOperation) throws {
        switch operation {
        case .build:
            mapPreview = try MindMapAIService.parseMap(response)
            announce(L10n.tr("导图（AI 建议）"))
        case let .expand(id):
            guard let node = tree.node(id) else { return }
            let found = try MindMapAIService.parseIdeas(response, existing: node.childIDs.compactMap { tree.node($0)?.title })
            guard !found.isEmpty else { throw AIError.invalidResponse }
            ideas = IdeasPreview(nodeID: id, ideas: found, selected: Set(found.indices))
        }
    }

    /// Предпросмотр AI пишется в текст только по кнопке пользователя.
    func putPreviewInNewDocument() {
        guard let appState, let map = mapPreview, let document else { return }
        let markdown = MindMapAIService.markdown(for: map, fallbackTitle: fallbackTitle(document))
        let created = EditorDocument(text: markdown, language: .markdown, isDirty: true, requiresExplicitSave: true)
        windowManager?.openNativeTab(from: appState, with: created, inheritsWriter: appState.writerSession != nil)
        mapPreview = nil
    }

    func appendPreviewToDocument() {
        guard let map = mapPreview, let document else { return }
        let markdown = MindMapAIService.markdown(for: map, fallbackTitle: fallbackTitle(document))
        editDocument(announce: L10n.tr("追加到文档末尾"), action: L10n.tr("生成导图")) { _, text in
            MindMapEditor.appendMarkdown(markdown, to: text)
        }
        mapPreview = nil
    }

    func addSelectedIdeas() {
        guard let preview = ideas else { return }
        let titles = preview.ideas.enumerated().filter { preview.selected.contains($0.offset) }.map(\.element)
        ideas = nil
        guard !titles.isEmpty else { return }
        editDocument(announce: L10n.tr("已添加节点"), action: L10n.tr("添加所选")) { parsed, text in
            MindMapEditor.appendChildren(parsed, nodeID: preview.nodeID, titles: titles, in: text)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
