import Combine
import Foundation
import SwiftUI

/// Состояние доски карточек: карточки открытого контейнера, правка описаний, порядок и предложения описаний.
/// Живёт столько же, сколько окно доски. Предложения хранятся только в памяти; в манифест попадает только принятое.
@MainActor
final class WriterBoardController: ObservableObject {
    struct Draft: Equatable {
        enum Source: Equatable { case algorithm, ai }
        var text: String
        var source: Source
    }

    struct Oversize: Equatable {
        let id: UUID
        let bytes: Int
    }

    typealias Generate = (AIFeature, String, String, AIModelProfile, String?) async throws -> AIWritingResult

    /// Просьба модели: короткое описание обычным текстом (остальное задаёт `AIWritingService` для `summary`).
    static let synopsisOption = "Result: 1-2 plain-text sentences without Markdown, in the language of the source text, at most 300 characters."

    let store: ManuscriptProjectStore
    /// nil — корень проекта.
    @Published private(set) var container: UUID?
    @Published private(set) var cards: [BoardCard] = []
    @Published var filter = BoardFilter()
    @Published var selection: UUID?
    /// Карточка в режиме правки описания; текст правки хранится здесь, а не в ячейке: ленивая сетка пересоздаёт ячейки.
    @Published private(set) var editingSynopsis: UUID?
    @Published var editingText = ""
    @Published private(set) var drafts: [UUID: Draft] = [:]
    @Published private(set) var busy: Set<UUID> = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorAction: AIMessageAction?
    @Published private(set) var lastErrorCard: UUID?
    /// Запрос к AI больше порога: ждёт подтверждения «Всё равно отправить».
    @Published private(set) var oversize: Oversize?

    /// Действия над живой вкладкой проекта: окно доски не держит вкладку, которая его открыла.
    var openSceneHandler: ((UUID) -> Void)?
    var createSceneHandler: ((UUID?) -> Void)?
    var openCombinedHandler: ((UUID) -> Void)?

    var isAIAvailable: Bool { aiAvailability() == .available }
    var preferencesWillChange: ObservableObjectPublisher { preferences.objectWillChange }

    private let wordCounts: () -> [UUID: Int]
    private let windowManager: WindowManager?
    private let preferences: AppPreferences
    private let aiAvailability: () -> AIAvailability
    private let loadKey: (AIRole, String) throws -> String?
    private let generate: Generate
    private var generation = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var projectCancellable: AnyCancellable?

    init(store: ManuscriptProjectStore,
         wordCounts: @escaping () -> [UUID: Int],
         windowManager: WindowManager?, preferences: AppPreferences,
         aiAvailability: @escaping () -> AIAvailability,
         loadKey: @escaping (AIRole, String) throws -> String? = { try AIKeychainStore().load(for: $0, baseURL: $1) },
         generate: @escaping Generate = { feature, input, option, profile, key in
             try await AIWritingService.generate(feature: feature, input: input, option: option, profile: profile, key: key)
         }) {
        self.store = store
        self.wordCounts = wordCounts
        self.windowManager = windowManager
        self.preferences = preferences
        self.aiAvailability = aiAvailability
        self.loadKey = loadKey
        self.generate = generate
        rebuild(project: store.project)
        // `@Published` сообщает до записи значения: берём новое значение из события, а не из `store.project`.
        projectCancellable = store.$project.dropFirst().sink { [weak self] project in
            MainActor.assumeIsolated { self?.rebuild(project: project) }
        }
    }

    // MARK: Карточки

    var visibleCards: [BoardCard] { cards.filter(filter.matches) }

    /// nil, если фильтр не включён.
    var filterSummary: (shown: Int, total: Int)? {
        filter.isActive ? (visibleCards.count, cards.count) : nil
    }

    var breadcrumb: [(id: UUID?, title: String)] {
        var chain: [(id: UUID?, title: String)] = [(nil, store.title)]
        guard let project = store.project else { return chain }
        var path: [(id: UUID?, title: String)] = []
        var current = container
        while let id = current, let node = project.node(id: id) {
            path.insert((id, node.title), at: 0)
            current = project.location(of: id)?.parent
        }
        chain.append(contentsOf: path)
        return chain
    }

    func refresh() { rebuild(project: store.project) }

    private func rebuild(project: ManuscriptProject?) {
        guard let project else {
            container = nil
            cards = []
            drafts = [:]
            return
        }
        if let current = container, project.node(id: current)?.kind != .group { container = nil }
        let existing = drafts.filter { project.node(id: $0.key) != nil }
        if existing.count != drafts.count { drafts = existing }
        let children = project.children(of: container)
        var missing = Set<UUID>()
        for node in children where node.kind == .text {
            if let url = store.fileURL(for: node), FileManager.default.fileExists(atPath: url.path) { continue }
            missing.insert(node.id)
        }
        let rebuilt = BoardModel.cards(project: project, container: container, counts: wordCounts(), missing: missing)
        if rebuilt != cards { cards = rebuilt }
        if let selection, !rebuilt.contains(where: { $0.id == selection }) { self.selection = nil }
        if let editing = editingSynopsis, !rebuilt.contains(where: { $0.id == editing }) { editingSynopsis = nil }
        if let oversize, project.node(id: oversize.id) == nil { self.oversize = nil }
    }

    func enter(_ groupID: UUID) {
        guard cards.contains(where: { $0.id == groupID && $0.isGroup }) else { return }
        commitEditing()
        container = groupID
        selection = nil
        rebuild(project: store.project)
    }

    func goUp() {
        guard let current = container else { return }
        goTo(store.project?.location(of: current)?.parent)
    }

    func goTo(_ id: UUID?) {
        commitEditing()
        container = id
        selection = nil
        rebuild(project: store.project)
    }

    func resetFilter() { filter = BoardFilter() }

    func dismissOversize() { oversize = nil }

    func clearError() {
        lastError = nil
        lastErrorAction = nil
        lastErrorCard = nil
    }

    // MARK: Правка

    func beginEditing(_ id: UUID) {
        guard editingSynopsis != id, let node = store.node(id: id), node.kind == .text else { return }
        commitEditing()
        editingText = node.synopsis ?? ""
        editingSynopsis = id
    }

    func commitEditing() {
        guard let id = editingSynopsis else { return }
        editingSynopsis = nil
        guard let node = store.node(id: id), (node.synopsis ?? "") != editingText else { return }
        let text = editingText
        mutate(id) { $0.synopsis = text.isEmpty ? nil : text }
    }

    func cancelEditing() { editingSynopsis = nil }

    func setStatus(_ title: String?, for id: UUID) {
        mutate(id) { $0.status = title }
    }

    func setLabel(_ label: String?, for id: UUID) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { $0.label = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    @discardableResult
    private func mutate(_ id: UUID, _ change: @escaping (inout ManuscriptNode) -> Void) -> Bool {
        do {
            try store.update { $0.mutateNode(id: id, change) }
            return true
        } catch {
            lastError = error.localizedDescription
            lastErrorAction = nil
            lastErrorCard = nil
            return false
        }
    }

    // MARK: Порядок

    /// -1 — раньше, +1 — позже; сосед выбирается среди видимых карточек, так что фильтр не мешает.
    func move(_ id: UUID, step: Int) {
        guard editingSynopsis == nil, let project = store.project,
              let anchor = BoardOrdering.neighbor(visibleIDs: visibleCards.map(\.id), of: id, step: step) else { return }
        place(id, relativeTo: anchor, placeAfter: step > 0, project: project)
    }

    func drop(_ moving: UUID, onto target: UUID, placeAfter: Bool) {
        guard editingSynopsis == nil, let project = store.project else { return }
        place(moving, relativeTo: target, placeAfter: placeAfter, project: project)
    }

    private func place(_ moving: UUID, relativeTo anchor: UUID, placeAfter: Bool, project: ManuscriptProject) {
        let full = project.children(of: container).map(\.id)
        guard full.contains(moving),
              let index = BoardOrdering.targetIndex(fullIDs: full, moving: moving, relativeTo: anchor, placeAfter: placeAfter) else { return }
        do {
            try store.moveNode(id: moving, toParent: container, index: index)
        } catch {
            lastError = error.localizedDescription
            lastErrorAction = nil
            lastErrorCard = nil
        }
    }

    // MARK: Описания

    /// Описание алгоритмом (без сети). Результат — черновик в памяти.
    func suggestSynopsis(for id: UUID) {
        guard !busy.contains(id), let node = store.node(id: id), node.kind == .text else { return }
        busy.insert(id)
        let current = generation
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.finishTask(id, generation: current) }
            let output = await WriterNodeTextLoader.load(nodes: [node], store: self.store, windowManager: self.windowManager)
            guard self.isLive(id, generation: current) else { return }
            if output.snapshotsUnavailable { self.fail(L10n.tr("无法读取打开的文档，请稍后重试"), card: id); return }
            guard let text = output.parts.first?.text else { self.fail(L10n.tr("场景没有可用文本"), card: id); return }
            let draft = await Self.runDetached { SceneSynopsisDrafter.draft(from: text, isCancelled: { Task.isCancelled }) }
            guard self.isLive(id, generation: current) else { return }
            guard let draft else { self.fail(L10n.tr("场景没有可用文本"), card: id); return }
            self.drafts[id] = Draft(text: draft.text, source: .algorithm)
            Self.announce(L10n.tr("建议梗概") + ": " + draft.text)
        }
    }

    /// Описание через модель `summary`. Текст предварительно очищается от картинок и разметки, большой запрос ждёт подтверждения.
    func suggestSynopsisWithAI(for id: UUID, ignoreSize: Bool = false) {
        guard aiAvailability() == .available, !busy.contains(id), let node = store.node(id: id), node.kind == .text else { return }
        let feature = AIFeature.summary
        let profile = preferences.aiProfile(for: feature)
        let key: String?
        do { key = try loadKey(feature.role, profile.baseURL) } catch { fail(error, card: id); return }
        oversize = nil
        busy.insert(id)
        let current = generation
        let generate = self.generate
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.finishTask(id, generation: current) }
            let output = await WriterNodeTextLoader.load(nodes: [node], store: self.store, windowManager: self.windowManager)
            guard self.isLive(id, generation: current) else { return }
            if output.snapshotsUnavailable { self.fail(L10n.tr("无法读取打开的文档，请稍后重试"), card: id); return }
            guard let text = output.parts.first?.text else { self.fail(L10n.tr("场景没有可用文本"), card: id); return }
            let prose = SceneSynopsisDrafter.plainProse(from: text)
            guard !prose.isEmpty else { self.fail(L10n.tr("场景没有可用文本"), card: id); return }
            let bytes = AIRequestSize.bytes(prose, Self.synopsisOption)
            if bytes > AIRequestSize.threshold, !ignoreSize {
                self.oversize = Oversize(id: id, bytes: bytes)
                return
            }
            do {
                let result = try await generate(feature, prose, Self.synopsisOption, profile, key)
                guard self.isLive(id, generation: current), self.preferences.aiProfile(for: feature) == profile else { return }
                let report = result.report.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !report.isEmpty else { self.fail(AIError.invalidResponse, card: id); return }
                self.drafts[id] = Draft(text: report, source: .ai)
                Self.announce(L10n.tr("建议梗概") + ": " + report)
            } catch is CancellationError {
                return
            } catch {
                guard self.isLive(id, generation: current) else { return }
                self.fail(error, card: id)
            }
        }
    }

    /// Записывает предложенное описание в манифест. При ошибке записи предложение остаётся.
    func accept(_ id: UUID) {
        guard let draft = drafts[id] else { return }
        if mutate(id, { $0.synopsis = draft.text }) { drafts[id] = nil }
    }

    func reject(_ id: UUID) { drafts[id] = nil }

    func openScene(_ id: UUID) { openSceneHandler?(id) }

    /// Закрытие окна: сохраняет начатую правку и отменяет фоновые запросы; поздние результаты отбрасываются.
    func cancelAll() {
        commitEditing()
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        busy = []
        oversize = nil
    }

    // MARK: Служебное

    private func isLive(_ id: UUID, generation current: Int) -> Bool {
        !Task.isCancelled && generation == current && store.node(id: id) != nil
    }

    private func finishTask(_ id: UUID, generation current: Int) {
        guard generation == current else { return }
        busy.remove(id)
        tasks[id] = nil
    }

    private func fail(_ message: String, card: UUID) {
        lastError = message
        lastErrorAction = nil
        lastErrorCard = card
        Self.announce(message)
    }

    private func fail(_ error: Error, card: UUID) {
        lastError = error.localizedDescription
        lastErrorAction = AIMessageAction.forError(error)
        lastErrorCard = card
        Self.announce(error.localizedDescription)
    }

    /// Озвучивает результат фоновой работы для VoiceOver.
    private static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// Работа на фоне с отменой вместе с вызывающей задачей.
    private nonisolated static func runDetached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
