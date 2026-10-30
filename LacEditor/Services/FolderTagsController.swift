import Combine
import Foundation

/// Список тегов рабочей папки для раздела боковой панели: читается по явному действию, не хранится в сессии.
@MainActor
final class FolderTagsController: ObservableObject {
    enum Message: Equatable { case stale, failed }

    @Published private(set) var root: URL?
    @Published private(set) var tags: [FolderSearchService.TagEntry] = []
    @Published private(set) var isWorking = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var hasProblems = false
    @Published private(set) var message: Message?

    private let snapshots: () -> [FolderSearchService.OpenDocument]?
    private var generation: UInt = 0
    private var task: Task<Void, Never>?

    init(snapshots: @escaping () -> [FolderSearchService.OpenDocument]?) {
        self.snapshots = snapshots
    }

    func setRoot(_ root: URL?) {
        let value = root.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        guard self.root != value else { return }
        self.root = value
        invalidate()
    }

    /// Отменяет работу и сбрасывает список: скрытый раздел ничего не считает.
    func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        tags = []
        isWorking = false
        hasLoaded = false
        hasProblems = false
        message = nil
    }

    @discardableResult
    func reload() -> Task<Void, Never>? {
        invalidate()
        guard let root else { return nil }
        guard let documents = snapshots() else {
            message = .stale
            return nil
        }
        let generation = self.generation
        isWorking = true
        let worker = Task.detached(priority: .userInitiated) { () throws -> FolderSearchService.Result<FolderSearchService.TagEntry> in
            try FolderSearchService.tagListing(root: root, openDocuments: documents, isCancelled: { Task.isCancelled })
        }
        let task = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == generation, self.root == root else { return }
                guard let current = self.snapshots(), FolderSearchController.snapshotsStable(old: documents, current: current, root: root) else {
                    self.isWorking = false; self.message = .stale; self.task = nil; return
                }
                self.tags = result.values
                self.hasProblems = !result.problems.isEmpty
                self.isWorking = false
                self.hasLoaded = true
                self.task = nil
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == generation else { return }
                self.isWorking = false; self.message = .failed; self.task = nil
            }
        }
        self.task = task
        return task
    }
}
