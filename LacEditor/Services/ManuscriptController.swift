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
        /// Узел проекта (в проектном режиме), иначе nil.
        var node: ManuscriptNode? = nil
        var groupPath: [String] = []
        /// Файл узла не найден на диске.
        var isMissing = false
        /// Расширение вне `compileExtensions` (например `.fountain`): в сборку не берётся.
        var isUnsupported = false
        /// Одна из объемлющих групп выключена: отметка «выкл.» берётся из неё, а не из самого узла.
        var isInDisabledGroup = false
        var isSelectable: Bool { !isMissing && !isUnsupported }
    }

    /// Данные узла проекта для части книги.
    struct PartMeta: Equatable, Sendable {
        let title: String
        let synopsis: String?
        let groupPath: [String]
    }

    struct Request: Sendable {
        let root: URL
        /// Выбранные файлы в порядке рукописи.
        let files: [FolderSearchService.File]
        let documents: [FolderSearchService.OpenDocument]
        let syntax: MarkdownSyntaxOptions
        var options = ManuscriptService.Options()
        /// Данные узлов по относительному пути файла (пусто без проекта).
        var meta: [String: PartMeta] = [:]
        /// В проектном режиме берутся все `compileExtensions`, а не только Markdown.
        var markdownOnly = true
    }

    enum BuildError: Error { case nothingToMerge }

    @Published private(set) var items: [Item] = []
    @Published var selectedID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isBuilding = false
    @Published var options = ManuscriptService.Options()
    @Published private(set) var message: String?
    @Published private(set) var messageKind: StatusKind = .info
    private(set) var root: URL?
    /// Проект рукописи, по которому построен список; nil — обычная сборка папки.
    private(set) var store: ManuscriptProjectStore?

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
                                                                    openDocuments: request.documents,
                                                                    markdownOnly: request.markdownOnly, isCancelled: { Task.isCancelled })
            let parts = sources.values.map { source -> ManuscriptService.Part in
                let meta = request.meta[source.file.relativePath]
                return ManuscriptService.Part(file: source.file, text: source.text, title: meta?.title,
                                              synopsis: meta?.synopsis, groupPath: meta?.groupPath ?? [])
            }
            return try ManuscriptService.merge(parts, skipped: sources.problems, syntax: request.syntax,
                                               options: request.options, isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    var selectedCount: Int { items.filter(\.isOn).count }
    var canBuild: Bool { selectedCount > 0 && !isBuilding && !isLoading }

    /// Смена корня сбрасывает выбор; тот же корень сохраняет порядок и флажки.
    func attach(root newRoot: URL) {
        if store != nil {
            // Из проектного режима в обычный: список проекта не подходит.
            cancel()
            store = nil
            items = []
            selectedID = nil
            root = nil
        }
        if root != newRoot {
            cancel()
            items = []
            selectedID = nil
            root = newRoot
        }
        reload()
    }

    /// Проектный режим: порядок, включение и названия берутся из манифеста. Порядок в листе — выбор для одной сборки.
    func attachProject(_ projectStore: ManuscriptProjectStore) {
        cancel()
        store = projectStore
        root = projectStore.rootURL
        selectedID = nil
        message = nil
        var result: [Item] = []
        func walk(_ nodes: [ManuscriptNode], path: [String], parentOn: Bool) {
            for node in nodes {
                if node.kind == .group {
                    walk(node.children, path: path + [node.title], parentOn: parentOn && node.include)
                    continue
                }
                guard let relative = node.path, let url = projectStore.fileURL(for: node) else { continue }
                let supported = ManuscriptProjectFiles.compileExtensions.contains((relative as NSString).pathExtension.lowercased())
                let exists = FileManager.default.fileExists(atPath: url.path)
                var item = Item(file: FolderSearchService.File(url: url, relativePath: relative),
                                isOn: parentOn && node.include && supported && exists)
                item.node = node
                item.groupPath = path
                item.isMissing = !exists
                item.isUnsupported = !supported
                item.isInDisabledGroup = !parentOn
                result.append(item)
            }
        }
        walk(projectStore.project?.nodes ?? [], path: [], parentOn: true)
        items = result
    }

    /// Записывает отметки листа в поле «Включать в книгу» узлов. Недоступные файлы не затрагиваются.
    func rememberSelection() {
        guard let store else { return }
        // Выключенное через группу не записываем: иначе потомки потеряют собственную отметку.
        let states = items.filter { $0.isSelectable && !($0.isInDisabledGroup && !$0.isOn) }.compactMap { item in item.node.map { ($0.id, item.isOn) } }
        do {
            try store.update { project in
                for (id, on) in states { project.mutateNode(id: id) { $0.include = on } }
            }
            message = L10n.tr("已记住选择")
            messageKind = .success
        } catch {
            fail(error.localizedDescription)
        }
    }

    func reload() {
        guard store == nil, let root else { return }
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
        for index in items.indices { items[index].isOn = on && items[index].isSelectable }
    }

    func setItem(_ id: String, on: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isOn = on && items[index].isSelectable
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
        let selected = items.filter(\.isOn)
        var meta: [String: PartMeta] = [:]
        for item in selected {
            guard let node = item.node else { continue }
            meta[item.file.relativePath] = PartMeta(title: node.title, synopsis: node.synopsis, groupPath: item.groupPath)
        }
        let request = Request(root: root, files: selected.map(\.file), documents: documents, syntax: syntax(),
                              options: options, meta: meta, markdownOnly: store == nil)
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
