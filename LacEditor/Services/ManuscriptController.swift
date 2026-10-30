import Combine
import Foundation

/// Состояние листа «Собрать рукопись»: список файлов папки, порядок, флажки и фоновая сборка.
/// Живёт столько же, сколько окно; в сессию не пишется, смена корня сбрасывает выбор.
@MainActor
final class ManuscriptController: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String { file.relativePath }
        let file: FolderSearchService.File
        var isOn: Bool
    }

    struct Request: Sendable {
        let root: URL
        /// Выбранные файлы в порядке рукописи.
        let files: [FolderSearchService.File]
        let documents: [FolderSearchService.OpenDocument]
        let syntax: MarkdownSyntaxOptions
    }

    enum BuildError: Error { case nothingToMerge }

    @Published private(set) var items: [Item] = []
    @Published var selectedID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isBuilding = false
    @Published private(set) var message: String?
    @Published private(set) var messageKind: StatusKind = .info
    private(set) var root: URL?

    private let snapshots: () -> [FolderSearchService.OpenDocument]?
    private let syntax: () -> MarkdownSyntaxOptions
    private let onBuilt: (ManuscriptService.Output) -> Void
    private let builder: @Sendable (Request) async throws -> ManuscriptService.Output
    private var listTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private var listGeneration = 0
    private var buildGeneration = 0

    init(snapshots: @escaping () -> [FolderSearchService.OpenDocument]?,
         syntax: @escaping () -> MarkdownSyntaxOptions,
         onBuilt: @escaping (ManuscriptService.Output) -> Void,
         build: @escaping @Sendable (Request) async throws -> ManuscriptService.Output = ManuscriptController.defaultBuild) {
        self.snapshots = snapshots
        self.syntax = syntax
        self.onBuilt = onBuilt
        builder = build
    }

    deinit {
        listTask?.cancel()
        buildTask?.cancel()
    }

    /// Чтение и склейка в одном фоновом задании; отмена внешней задачи отменяет и его.
    nonisolated static let defaultBuild: @Sendable (Request) async throws -> ManuscriptService.Output = { request in
        let work = Task.detached(priority: .userInitiated) { () throws -> ManuscriptService.Output in
            let sources = try FolderSearchService.manuscriptSources(root: request.root, files: request.files,
                                                                    openDocuments: request.documents, isCancelled: { Task.isCancelled })
            let parts = sources.values.map { ManuscriptService.Part(file: $0.file, text: $0.text) }
            return try ManuscriptService.merge(parts, skipped: sources.problems, syntax: request.syntax,
                                               isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    var selectedCount: Int { items.filter(\.isOn).count }
    var canBuild: Bool { selectedCount > 0 && !isBuilding && !isLoading }

    /// Смена корня сбрасывает выбор; тот же корень сохраняет порядок и флажки.
    func attach(root newRoot: URL) {
        if root != newRoot {
            cancel()
            items = []
            selectedID = nil
            root = newRoot
        }
        reload()
    }

    func reload() {
        guard let root else { return }
        listGeneration += 1
        let current = listGeneration
        listTask?.cancel()
        isLoading = true
        message = nil
        listTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> FolderSearchService.Result<FolderSearchService.File>? in
                try? FolderSearchService.markdownFiles(root: root, isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.listGeneration == current, self.root == root else { return }
            self.isLoading = false
            guard let result else {
                self.fail(L10n.tr("无法读取"))
                return
            }
            self.merge(result.values)
        }
    }

    /// Старый порядок и флажки сохраняются, исчезнувшие файлы выпадают, новые дописываются отмеченными, кроме скрытых.
    private func merge(_ files: [FolderSearchService.File]) {
        let fresh = files.sorted {
            let order = $0.relativePath.localizedStandardCompare($1.relativePath)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
        let byPath = Dictionary(fresh.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = items.compactMap { old in byPath[old.id].map { Item(file: $0, isOn: old.isOn) } }
        let known = Set(merged.map(\.id))
        merged += fresh.filter { !known.contains($0.relativePath) }.map {
            Item(file: $0, isOn: !$0.relativePath.split(separator: "/").contains { $0.hasPrefix(".") })
        }
        items = merged
        if let selectedID, !merged.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    /// Для `.onMove`: `destination` в координатах исходного списка.
    func move(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty, source.allSatisfy({ items.indices.contains($0) }) else { return }
        let moving = source.sorted().map { items[$0] }
        let target = min(max(destination, 0), items.count) - source.filter { $0 < destination }.count
        items = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        items.insert(contentsOf: moving, at: min(max(target, 0), items.count))
    }

    func moveSelected(by delta: Int) {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }),
              items.indices.contains(index + delta) else { return }
        items.swapAt(index, index + delta)
    }

    func setAll(_ on: Bool) {
        for index in items.indices { items[index].isOn = on }
    }

    func setItem(_ id: String, on: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isOn = on
    }

    func build() {
        guard canBuild, let root else { return }
        guard let documents = snapshots() else {
            fail(L10n.tr("无法读取打开的文档，请稍后重试"))
            return
        }
        buildGeneration += 1
        let current = buildGeneration
        buildTask?.cancel()
        isBuilding = true
        message = nil
        let request = Request(root: root, files: items.filter(\.isOn).map(\.file), documents: documents, syntax: syntax())
        let builder = builder
        buildTask = Task { [weak self] in
            let outcome: Result<ManuscriptService.Output, Error>
            do { outcome = .success(try await builder(request)) } catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled, self.buildGeneration == current, self.root == root else { return }
            self.isBuilding = false
            switch outcome {
            case let .success(output):
                if output.report.mergedFiles == 0 { self.fail(L10n.tr("没有可合并的文件")) } else { self.onBuilt(output) }
            case let .failure(error):
                if error is CancellationError { return }
                self.fail(error is BuildError ? L10n.tr("没有可合并的文件") : L10n.tr("无法读取"))
            }
        }
    }

    /// Отменяет чтение списка и сборку; позднее завершение работы результата не применит.
    func cancel() {
        listGeneration += 1
        buildGeneration += 1
        listTask?.cancel()
        buildTask?.cancel()
        listTask = nil
        buildTask = nil
        isLoading = false
        isBuilding = false
    }

    private func fail(_ text: String) {
        message = text
        messageKind = .error
    }
}
