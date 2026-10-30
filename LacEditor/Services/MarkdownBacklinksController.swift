import Combine
import Foundation

/// Обратные ссылки текущего Markdown-документа в рабочей папке окна. Результат не хранится в сессии.
@MainActor
final class MarkdownBacklinksController: ObservableObject {
    enum State: Equatable { case inactive, noFolder, unsaved, outsideFolder, loading, loaded, stale, failed }

    private struct Input: Equatable, Sendable {
        let root: URL
        let documentID: UUID
        let target: FolderSearchService.BacklinkTarget
    }

    @Published private(set) var state: State = .inactive
    @Published private(set) var matches: [FolderSearchService.Match] = []
    @Published private(set) var problemCount = 0

    private let snapshots: () -> [FolderSearchService.OpenDocument]?
    private let open: (URL) async -> FolderSearchService.OpenDocument?
    private let reveal: (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool
    private let syntax: () -> MarkdownSyntaxOptions
    private weak var document: EditorDocument?
    private var root: URL?
    private var isActive = false
    private var input: Input?
    private var generation: UInt = 0
    private var task: Task<Void, Never>?
    private var debounce: Task<Void, Never>?

    init(snapshots: @escaping () -> [FolderSearchService.OpenDocument]?,
         open: @escaping (URL) async -> FolderSearchService.OpenDocument?,
         reveal: @escaping (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool,
         syntax: @escaping () -> MarkdownSyntaxOptions = { .init() }) {
        self.snapshots = snapshots
        self.open = open
        self.reveal = reveal
        self.syntax = syntax
    }

    /// `isActive`: раздел раскрыт, боковая панель видна, документ в Markdown. Иначе работа останавливается, результат очищается.
    /// Адрес и идентичность документа читаются при запуске, после паузы: к этому времени `@Published` уже записан.
    func update(root: URL?, document: EditorDocument?, isActive: Bool) {
        self.document = document
        self.root = root
        self.isActive = isActive
        guard isActive, document != nil else { return reset(.inactive) }
        guard root != nil else { return reset(.noFolder) }
        refreshSoon(after: .zero)
    }

    /// Пауза склеивает серию событий (сохранение, события папки) в один запуск.
    func refreshSoon(after delay: Duration = .milliseconds(500)) {
        guard isActive, document != nil, root != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.start()
        }
    }

    func refreshNow() {
        debounce?.cancel()
        debounce = nil
        start()
    }

    func close() { isActive = false; reset(.inactive) }

    private func reset(_ value: State) {
        input = nil
        debounce?.cancel()
        debounce = nil
        invalidate()
        state = value
    }

    private func invalidate(keepingMatches: Bool = false) {
        generation &+= 1
        task?.cancel()
        task = nil
        if !keepingMatches {
            matches = []
            problemCount = 0
        }
    }

    private func start() {
        guard isActive, let document, let root else { return }
        guard let url = document.url else { return reset(.unsaved) }
        let rootPath = root.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard path.count > rootPath.count, path.starts(with: rootPath) else { return reset(.outsideFolder) }
        let input = Input(root: URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true), documentID: document.id,
                          target: .init(url: url, identity: document.fileIdentity ?? DocumentFileIdentity.resolve(url), syntax: syntax()))
        // Список остаётся до готового результата, пока документ и корень те же; иначе он относился бы к другой цели.
        invalidate(keepingMatches: self.input.map { $0.root == input.root && $0.documentID == input.documentID && $0.target.url == input.target.url } ?? false)
        self.input = input
        let generation = self.generation
        guard let documents = snapshots() else { matches = []; problemCount = 0; state = .stale; return }
        let others = documents.filter { $0.snapshot.documentID != input.documentID }
        state = .loading
        let worker = Task.detached(priority: .utility) {
            try FolderSearchService.backlinks(root: input.root, target: input.target, openDocuments: others, isCancelled: { Task.isCancelled })
        }
        task = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == generation, self.input == input else { return }
                guard let current = self.snapshots() else { self.matches = []; self.state = .stale; self.task = nil; return }
                guard self.generation == generation, self.input == input else { return }
                guard Self.unchanged(others, current.filter { $0.snapshot.documentID != input.documentID }, root: input.root) else {
                    self.matches = []; self.state = .stale; self.task = nil; return
                }
                self.matches = result.values
                self.problemCount = result.problems.count
                self.state = .loaded
                self.task = nil
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == generation else { return }
                self.matches = []
                self.state = .failed
                self.task = nil
            }
        }
    }

    /// Открытые документы папки те же, что видел поиск (по идентификатору и снимку).
    private static func unchanged(_ old: [FolderSearchService.OpenDocument], _ new: [FolderSearchService.OpenDocument], root: URL) -> Bool {
        let base = root.standardizedFileURL.pathComponents
        let relevantOld = old.filter { $0.url.standardizedFileURL.pathComponents.starts(with: base) }
        let relevantNew = new.filter { $0.url.standardizedFileURL.pathComponents.starts(with: base) }
        let byID = Dictionary(relevantNew.map { ($0.snapshot.documentID, $0) }, uniquingKeysWith: { first, _ in first })
        return relevantOld.count == relevantNew.count && byID.count == relevantNew.count &&
            Set(relevantOld.map { $0.snapshot.documentID }).count == relevantOld.count &&
            relevantOld.allSatisfy { old in byID[old.snapshot.documentID].map { FolderSearchController.sameSnapshot(old, $0) } == true }
    }

    @discardableResult
    func select(_ match: FolderSearchService.Match) -> Task<Void, Never>? {
        guard state == .loaded, matches.contains(match), let root = input?.root else { return nil }
        task?.cancel()
        let generation = self.generation
        let task = Task { [weak self] in
            guard let self else { return }
            switch match.source {
            case .open:
                guard let document = self.snapshots()?.first(where: { FolderSearchService.isCurrent(match, openDocument: $0) }),
                      self.isAdmitted(match, root: root, generation: generation), self.reveal(match, document) else {
                    if self.isAdmitted(match, root: root, generation: generation) { self.state = .stale }
                    return
                }
            case let .disk(expected):
                guard await FolderSearchController.diskCurrent(match, root: root), self.isAdmitted(match, root: root, generation: generation),
                      let opened = await self.open(match.file.url), self.isAdmitted(match, root: root, generation: generation),
                      await FolderSearchController.diskCurrent(match, root: root), self.isAdmitted(match, root: root, generation: generation),
                      expected.identity.matches(opened.identity),
                      let document = self.snapshots()?.first(where: { FolderSearchController.sameSnapshot(opened, $0) }),
                      FolderSearchController.containsFragment(match, in: document.snapshot.text),
                      self.isAdmitted(match, root: root, generation: generation), self.reveal(match, document) else {
                    if self.isAdmitted(match, root: root, generation: generation) { self.state = .stale }
                    return
                }
            }
        }
        self.task = task
        return task
    }

    private func isAdmitted(_ match: FolderSearchService.Match, root: URL, generation: UInt) -> Bool {
        !Task.isCancelled && self.generation == generation && input?.root == root && state == .loaded && matches.contains(match)
    }
}
