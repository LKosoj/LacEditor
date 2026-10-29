import Combine
import Foundation

@MainActor
final class FolderSearchController: ObservableObject {
    enum Mode: String, CaseIterable, Sendable { case files, text, tags }
    enum Message: Equatable { case stale, failed }
    enum QuickOpenItem: Equatable, Sendable {
        case file(FolderSearchService.File), folder(URL)
    }
    private enum Output: Sendable {
        case files(FolderSearchService.Result<FolderSearchService.File>)
        case text(FolderSearchService.Result<FolderSearchService.Match>)
        case quick([QuickOpenItem], [FolderSearchService.File], [FolderSearchService.Problem])
    }

    @Published private(set) var root: URL?
    @Published var query = "" { didSet { if query != oldValue { invalidate() } } }
    @Published var mode: Mode = .files {
        didSet {
            if mode != oldValue {
                if mode != .files { quickOpenRequest = nil }
                invalidate()
            }
        }
    }
    @Published private(set) var files: [FolderSearchService.File] = []
    @Published private(set) var matches: [FolderSearchService.Match] = []
    @Published private(set) var problems: [FolderSearchService.Problem] = []
    @Published private(set) var isWorking = false
    @Published private(set) var hasSearched = false
    @Published private(set) var message: Message?
    @Published private(set) var quickOpenRequest: UUID?
    @Published private(set) var quickOpenItems: [QuickOpenItem] = []

    private let snapshots: () -> [FolderSearchService.OpenDocument]?
    private let open: (URL) async -> FolderSearchService.OpenDocument?
    private let reveal: (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool
    private let openFile: (URL) -> Void
    private let folderLocations: () -> [URL]
    private let openFolder: (URL) -> Void
    private var quickFolderSnapshot: [URL]?
    private var generation: UInt = 0
    private var task: Task<Void, Never>?

    init(snapshots: @escaping () -> [FolderSearchService.OpenDocument]?,
         open: @escaping (URL) async -> FolderSearchService.OpenDocument?,
         reveal: @escaping (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool,
         openFile: @escaping (URL) -> Void,
         folderLocations: @escaping () -> [URL] = { [] }, openFolder: @escaping (URL) -> Void = { _ in }) {
        self.snapshots = snapshots
        self.open = open
        self.reveal = reveal
        self.openFile = openFile
        self.folderLocations = folderLocations
        self.openFolder = openFolder
    }

    func setRoot(_ root: URL?) {
        let value = root.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        guard self.root != value else { return }
        self.root = value
        quickOpenRequest = nil
        invalidate()
    }

    func close() { invalidate(); quickOpenRequest = nil; root = nil }

    func requestQuickOpen() {
        guard root != nil || !folderLocations().isEmpty else { return }
        mode = .files
        invalidate()
        quickOpenRequest = UUID()
    }

    @discardableResult
    func submit() -> Task<Void, Never>? {
        guard quickOpenRequest != nil, mode == .files else { return start() }
        if let first = quickOpenItems.first, hasSearched {
            select(first)
            return nil
        }
        let folders = folderLocations()
        quickOpenRequest = nil
        guard let search = start(quickLocations: folders) else { return nil }
        let expectedGeneration = generation
        return Task { [weak self] in
            await search.value
            guard let self, !Task.isCancelled, self.generation == expectedGeneration,
                  self.hasSearched, let first = self.quickOpenItems.first else { return }
            self.select(first)
        }
    }

    private func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        files = []
        matches = []
        problems = []
        isWorking = false
        hasSearched = false
        message = nil
        quickOpenItems = []
        quickFolderSnapshot = nil
    }

    @discardableResult
    func start(quickLocations: [URL]? = nil) -> Task<Void, Never>? {
        let locations = quickLocations ?? (quickOpenRequest != nil ? folderLocations() : nil)
        invalidate()
        let root = self.root
        guard (mode == .files && locations != nil) || (root != nil && !query.isEmpty) else { return nil }
        let generation = self.generation, query = self.query, mode = self.mode
        guard let documents = mode != .files ? snapshots() : [] else {
            message = .stale
            return nil
        }
        guard generation == self.generation, self.root == root, self.query == query, self.mode == mode else { return nil }
        isWorking = true
        let worker = Task.detached(priority: .userInitiated) { () throws -> Output in
            switch mode {
            case .files:
                let output = try root.map { try FolderSearchService.files(root: $0, query: query, caseSensitive: false, isCancelled: { Task.isCancelled }) }
                if let locations {
                    let matcher = FolderSearchService.NameQuery(query, caseSensitive: false)
                    var ranked: [(QuickOpenItem, Int, Int)] = []
                    var seen: Set<String> = []
                    for url in locations {
                        if Task.isCancelled { throw CancellationError() }
                        guard seen.insert(url.standardizedFileURL.path).inserted,
                              let rank = try matcher.rank(path: url.path, name: url.lastPathComponent, isCancelled: { Task.isCancelled }) else { continue }
                        ranked.append((.folder(url), rank, ranked.count))
                    }
                    for file in output?.values ?? [] {
                        if let rank = try matcher.rank(path: file.relativePath, name: file.url.lastPathComponent, isCancelled: { Task.isCancelled }) {
                            ranked.append((.file(file), rank, ranked.count))
                        }
                    }
                    ranked.sort { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }
                    return .quick(ranked.map { $0.0 }, output?.values ?? [], output?.problems ?? [])
                }
                guard let output else { throw CancellationError() }
                return .files(output)
            case .text, .tags:
                guard let root else { throw CancellationError() }
                return .text(try FolderSearchService.search(root: root, query: query, caseSensitive: false, openDocuments: documents,
                    kind: mode == .tags ? .tags : .text, isCancelled: { Task.isCancelled }))
            }
        }
        let task = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.generation == generation, self.root == root,
                      self.query == query, self.mode == mode else { return }
                if let locations, self.folderLocations() != locations {
                    self.isWorking = false; self.message = .stale; self.task = nil; return
                }
                if mode != .files, let root {
                    guard let current = self.snapshots() else {
                        self.isWorking = false; self.message = .stale; self.task = nil; return
                    }
                    guard self.generation == generation, self.root == root, self.query == query, self.mode == mode else { return }
                    let base = root.standardizedFileURL.pathComponents
                    let relevant = documents.filter { $0.url.standardizedFileURL.pathComponents.starts(with: base) }
                    let currentRelevant = current.filter { $0.url.standardizedFileURL.pathComponents.starts(with: base) }
                    let currentByID = Dictionary(currentRelevant.map { ($0.snapshot.documentID, $0) }, uniquingKeysWith: { first, _ in first })
                    guard relevant.count == currentRelevant.count, currentByID.count == currentRelevant.count,
                          Set(relevant.map { $0.snapshot.documentID }).count == relevant.count,
                          relevant.allSatisfy({ old in currentByID[old.snapshot.documentID].map { Self.sameSnapshot(old, $0) } == true }) else {
                        self.isWorking = false; self.message = .stale; return
                    }
                }
                switch result {
                case let .files(output): self.files = output.values; self.problems = output.problems
                case let .text(output): self.matches = output.values; self.problems = output.problems
                case let .quick(items, files, problems):
                    self.quickOpenItems = items; self.files = files; self.problems = problems
                    self.quickFolderSnapshot = locations
                }
                self.isWorking = false
                self.hasSearched = true
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

    func select(_ file: FolderSearchService.File) {
        guard mode == .files, hasSearched, files.contains(file), root != nil else { return }
        quickOpenRequest = nil
        openFile(file.url)
    }

    func select(_ item: QuickOpenItem) {
        guard hasSearched, mode == .files, quickOpenItems.contains(item),
              let expected = quickFolderSnapshot else { return }
        guard folderLocations() == expected else { invalidate(); message = .stale; return }
        quickOpenRequest = nil
        switch item {
        case let .file(file): select(file)
        case let .folder(url): openFolder(url)
        }
    }

    @discardableResult
    func select(_ match: FolderSearchService.Match) -> Task<Void, Never>? {
        guard mode != .files, hasSearched, matches.contains(match), let root else { return nil }
        task?.cancel()
        let generation = self.generation
        let task = Task { [weak self] in
            guard let self else { return }
            switch match.source {
            case .open:
                guard let document = self.snapshots()?.first(where: { FolderSearchService.isCurrent(match, openDocument: $0) }),
                      self.isAdmitted(match, root: root, generation: generation), self.revealResult(match, document) else {
                    if self.isAdmitted(match, root: root, generation: generation) { self.message = .stale }
                    return
                }
            case let .disk(expected):
                guard await Self.diskCurrent(match, root: root), self.isAdmitted(match, root: root, generation: generation),
                      let opened = await self.open(match.file.url), self.isAdmitted(match, root: root, generation: generation),
                      await Self.diskCurrent(match, root: root), self.isAdmitted(match, root: root, generation: generation),
                      expected.identity.matches(opened.identity),
                      let document = self.snapshots()?.first(where: { Self.sameSnapshot(opened, $0) }),
                      Self.containsFragment(match, in: document.snapshot.text),
                      self.isAdmitted(match, root: root, generation: generation), self.revealResult(match, document) else {
                    if self.isAdmitted(match, root: root, generation: generation) { self.message = .stale }
                    return
                }
            }
        }
        self.task = task
        return task
    }

    private func isAdmitted(_ match: FolderSearchService.Match, root: URL, generation: UInt) -> Bool {
        !Task.isCancelled && self.generation == generation && self.root == root && mode != .files && hasSearched && matches.contains(match)
    }

    private func revealResult(_ match: FolderSearchService.Match, _ document: FolderSearchService.OpenDocument) -> Bool {
        guard mode == .tags else { return reveal(match, document) }
        let target = FolderSearchService.Match(file: match.file, range: NSRange(location: match.range.location, length: 0),
            matchedText: "", contextRange: match.contextRange, context: match.context, source: match.source)
        return reveal(target, document)
    }

    private static func sameSnapshot(_ first: FolderSearchService.OpenDocument, _ second: FolderSearchService.OpenDocument) -> Bool {
        first.url.standardizedFileURL == second.url.standardizedFileURL && first.identity.matches(second.identity) && first.snapshot == second.snapshot
    }

    private static func containsFragment(_ match: FolderSearchService.Match, in text: String) -> Bool {
        let text = text as NSString, range = match.range
        return range.location >= 0 && range.location <= text.length && range.length >= 0 && range.length <= text.length - range.location &&
            text.substring(with: range) == match.matchedText
    }

    private static func diskCurrent(_ match: FolderSearchService.Match, root: URL) async -> Bool {
        let worker = Task.detached(priority: .userInitiated) {
            (try? FolderSearchService.isCurrent(match, root: root, isCancelled: { Task.isCancelled })) == true
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
}
