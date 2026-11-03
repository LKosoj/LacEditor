import Combine
import Foundation

/// Состояние окна сводного просмотра: тексты включённых сцен проекта одной страницей.
/// Страница строится по кнопке «Обновить»; правки сцен её сами не перерисовывают, а лишь включают плашку «Текст изменился».
@MainActor
final class WriterCombinedViewController: ObservableObject {
    enum Scope: Equatable { case wholeBook, group(UUID) }

    /// Отпечаток состава и текстов: сравнивается в пределах одного запуска, на диск не пишется.
    struct Fingerprint: Equatable, Sendable {
        let ids: [UUID]
        let hashes: [Int]
    }

    @Published private(set) var html = ""
    @Published private(set) var token = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isStale = false
    /// Относительные пути не прочитанных файлов.
    @Published private(set) var problems: [String] = []
    @Published private(set) var partCount = 0
    @Published private(set) var errorMessage: String?
    let store: ManuscriptProjectStore
    var scope: Scope
    var openNodeHandler: ((UUID) -> Void)?

    private let windowManager: WindowManager?
    private let preferences: AppPreferences
    private let isDark: () -> Bool
    private var partNodeIDs: [UUID] = []
    private var fingerprint: Fingerprint?
    private var generation = 0
    private var staleGeneration = 0
    private var task: Task<Void, Never>?
    private var staleTask: Task<Void, Never>?

    init(store: ManuscriptProjectStore, windowManager: WindowManager?, preferences: AppPreferences,
         scope: Scope = .wholeBook, isDark: @escaping () -> Bool) {
        self.store = store
        self.windowManager = windowManager
        self.preferences = preferences
        self.scope = scope
        self.isDark = isDark
    }

    deinit {
        task?.cancel()
        staleTask?.cancel()
    }

    /// Сцены для просмотра: только включённые; выключенная группа внутри скрывает свою ветку.
    func currentNodes() -> [ManuscriptNode] {
        switch scope {
        case .wholeBook:
            return store.orderedTextNodes(includedOnly: true)
        case let .group(id):
            guard let group = store.node(id: id), group.kind == .group else { return [] }
            var result: [ManuscriptNode] = []
            func walk(_ list: [ManuscriptNode]) {
                for node in list where node.include {
                    if node.kind == .text { result.append(node) } else { walk(node.children) }
                }
            }
            walk(group.children)
            return result
        }
    }

    func reload() {
        generation += 1
        let current = generation
        task?.cancel()
        isLoading = true
        errorMessage = nil
        let nodes = currentNodes()
        let dark = isDark()
        let syntax = preferences.markdownSyntax
        let label = L10n.tr("打开")
        task = Task { [weak self] in
            guard let self else { return }
            let output = await WriterNodeTextLoader.load(nodes: nodes, store: self.store, windowManager: self.windowManager)
            guard !Task.isCancelled, self.generation == current else { return }
            if output.snapshotsUnavailable {
                self.errorMessage = L10n.tr("无法读取打开的文档，请稍后重试")
                self.isLoading = false
                return
            }
            let newToken = WriterCombinedPage.makeToken()
            let inputs = output.parts.map { WriterCombinedPage.PartInput(title: $0.node.title, text: $0.text, documentURL: $0.url) }
            let ids = output.parts.map(\.node.id)
            let texts = output.parts.map(\.text)
            let rendered = await Self.runDetached { () -> (String, Fingerprint) in
                let page = inputs.isEmpty ? "" : WriterCombinedPage.html(parts: inputs, token: newToken, darkMode: dark, syntax: syntax, openLabel: label)
                return (page, Fingerprint(ids: ids, hashes: texts.map(\.hashValue)))
            }
            guard !Task.isCancelled, self.generation == current else { return }
            self.html = rendered.0
            self.token = newToken
            self.partNodeIDs = ids
            self.partCount = ids.count
            self.problems = output.problems
            self.fingerprint = rendered.1
            self.isStale = false
            self.isLoading = false
        }
    }

    /// Дёшево сверяет тексты с теми, по которым построена страница; страницу не перерисовывает.
    func checkStale() {
        guard let known = fingerprint, !isLoading else { return }
        staleGeneration += 1
        let current = staleGeneration
        staleTask?.cancel()
        let nodes = currentNodes()
        staleTask = Task { [weak self] in
            guard let self else { return }
            let output = await WriterNodeTextLoader.load(nodes: nodes, store: self.store, windowManager: self.windowManager)
            guard !Task.isCancelled, self.staleGeneration == current, !output.snapshotsUnavailable else { return }
            let ids = output.parts.map(\.node.id)
            let texts = output.parts.map(\.text)
            let now = await Self.runDetached { Fingerprint(ids: ids, hashes: texts.map(\.hashValue)) }
            guard !Task.isCancelled, self.staleGeneration == current, !self.isLoading else { return }
            if now != known { self.isStale = true }
        }
    }

    func openPart(index: Int) {
        guard partNodeIDs.indices.contains(index) else { return }
        openNodeHandler?(partNodeIDs[index])
    }

    func cancel() {
        generation += 1
        staleGeneration += 1
        task?.cancel()
        staleTask?.cancel()
        isLoading = false
    }

    private nonisolated static func runDetached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let job = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }
}
