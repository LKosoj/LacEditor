import Combine
import Foundation

@MainActor
final class FolderSearchController: ObservableObject {
    enum Mode: String, CaseIterable, Sendable { case files, text, tags }
    enum Message: Equatable { case stale, failed, invalidPattern }
    enum QuickOpenItem: Equatable, Sendable {
        case file(FolderSearchService.File), folder(URL)
    }
    struct ReplaceFilePlan: Equatable, Sendable {
        let file: FolderSearchService.File
        let source: FolderSearchService.Source
        let matches: [FolderSearchService.Match]
        var isOpen: Bool { if case .open = source { true } else { false } }
    }
    struct ReplacePlan: Equatable, Sendable {
        let request: FolderReplaceService.Request
        let files: [ReplaceFilePlan]
        var matchCount: Int { files.reduce(0) { $0 + $1.matches.count } }
        var openCount: Int { files.filter(\.isOpen).count }
    }
    /// Что показать в подтверждении.
    struct ReplaceSummary: Equatable, Sendable {
        let matchCount: Int
        let fileCount: Int
        let openCount: Int
    }
    struct OpenReplace: Sendable {
        let plan: ReplaceFilePlan
        let request: FolderReplaceService.Request
    }
    struct ReplaceReport: Equatable {
        struct Replaced: Equatable { let file: FolderSearchService.File; let count: Int; let isOpen: Bool }
        struct Skipped: Equatable { let file: FolderSearchService.File; let reason: FolderReplaceService.SkipReason; let count: Int }
        var replaced: [Replaced] = []
        var skipped: [Skipped] = []
        var isCancelled = false
        var replacedCount: Int { replaced.reduce(0) { $0 + $1.count } }
    }
    enum ReplaceState: Equatable { case idle, confirming, applying }

    private enum Output: Sendable {
        case files(FolderSearchService.Result<FolderSearchService.File>)
        case text(FolderSearchService.Result<FolderSearchService.Match>)
        case quick([QuickOpenItem], [FolderSearchService.File], [FolderSearchService.Problem])
    }

    @Published private(set) var root: URL?
    @Published var query = "" { didSet { if query != oldValue { report = nil; invalidate() } } }
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue { invalidate() } } }
    @Published var usesRegex = false { didSet { if usesRegex != oldValue { invalidate() } } }
    @Published var wholeWord = false { didSet { if wholeWord != oldValue { invalidate() } } }
    @Published var isReplaceEnabled = false { didSet { if isReplaceEnabled != oldValue { schedulePreviews() } } }
    @Published var replacement = "" { didSet { if replacement != oldValue { schedulePreviews() } } }
    @Published var mode: Mode = .files {
        didSet {
            if mode != oldValue {
                if mode != .files { quickOpenRequest = nil }
                report = nil
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
    /// Новый запрос из списка тегов: боковая панель раскрывает результаты поиска.
    @Published private(set) var revealRequest: UUID?
    @Published private(set) var quickOpenItems: [QuickOpenItem] = []
    /// Снятые флажки: по умолчанию выбраны все совпадения нового поиска.
    @Published private(set) var excluded: Set<FolderSearchService.MatchKey> = []
    @Published private(set) var previews: [FolderSearchService.MatchKey: String] = [:]
    @Published private(set) var replaceState: ReplaceState = .idle
    @Published private(set) var report: ReplaceReport?

    private let snapshots: () -> [FolderSearchService.OpenDocument]?
    private let open: (URL) async -> FolderSearchService.OpenDocument?
    private let reveal: (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool
    private let openFile: (URL) -> Void
    private let folderLocations: () -> [URL]
    private let openFolder: (URL) -> Void
    private let confirmReplace: (ReplaceSummary) -> Bool
    private let interpretsEscapes: () -> Bool
    private let applyOpen: (OpenReplace) async -> FolderReplaceService.Outcome
    private var previewTask: Task<Void, Never>?
    private var replaceTask: Task<Void, Never>?
    private var quickFolderSnapshot: [URL]?
    private var generation: UInt = 0
    private var task: Task<Void, Never>?

    init(snapshots: @escaping () -> [FolderSearchService.OpenDocument]?,
         open: @escaping (URL) async -> FolderSearchService.OpenDocument?,
         reveal: @escaping (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool,
         openFile: @escaping (URL) -> Void,
         folderLocations: @escaping () -> [URL] = { [] }, openFolder: @escaping (URL) -> Void = { _ in },
         confirmReplace: @escaping (ReplaceSummary) -> Bool = { _ in false },
         interpretsEscapes: @escaping () -> Bool = { true },
         applyOpen: @escaping (OpenReplace) async -> FolderReplaceService.Outcome = { _ in .skipped(.openInEditorFailed) }) {
        self.snapshots = snapshots
        self.open = open
        self.reveal = reveal
        self.openFile = openFile
        self.folderLocations = folderLocations
        self.openFolder = openFolder
        self.confirmReplace = confirmReplace
        self.interpretsEscapes = interpretsEscapes
        self.applyOpen = applyOpen
    }

    func setRoot(_ root: URL?) {
        let value = root.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        guard self.root != value else { return }
        self.root = value
        quickOpenRequest = nil
        report = nil
        cancelReplace()
        invalidate()
    }

    func close() { cancelReplace(); invalidate(); quickOpenRequest = nil; report = nil; root = nil }

    /// Esc / клик вне панели: снимает запрос и результаты быстрого вызова, корень не трогает.
    func cancelQuickOpen() {
        guard quickOpenRequest != nil else { return }
        invalidate()
        quickOpenRequest = nil
    }

    /// Поиск по тегу из раздела «Теги»: тот же режим тегов и тот же запуск, что при ручном вводе.
    @discardableResult
    func searchTag(_ tag: String) -> Task<Void, Never>? {
        mode = .tags
        query = tag
        revealRequest = UUID()
        return start()
    }

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
        // панель остаётся открытой до выбора результата: при пустом результате она покажет «нет совпадений»
        let folders = folderLocations()
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
        excluded = []
        previews = [:]
        previewTask?.cancel()
        previewTask = nil
    }

    @discardableResult
    func start(quickLocations: [URL]? = nil) -> Task<Void, Never>? {
        let locations = quickLocations ?? (quickOpenRequest != nil ? folderLocations() : nil)
        invalidate()
        let root = self.root
        guard (mode == .files && locations != nil) || (root != nil && !query.isEmpty) else { return nil }
        let generation = self.generation, query = self.query, mode = self.mode
        let options = TextSearchService.Options(caseSensitive: caseSensitive, usesRegex: usesRegex, wholeWord: wholeWord)
        guard let documents = mode != .files ? snapshots() : [] else {
            message = .stale
            return nil
        }
        guard generation == self.generation, self.root == root, self.query == query, self.mode == mode else { return nil }
        // Неверный шаблон виден сразу, даже если в папке нет файлов.
        if mode == .text, options.usesRegex, (try? TextSearchService.regularExpression(query: query, options: options)) == nil {
            message = .invalidPattern
            return nil
        }
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
                    kind: mode == .tags ? .tags : .text, options: mode == .text ? options : nil, isCancelled: { Task.isCancelled }))
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
                    guard Self.snapshotsStable(old: documents, current: current, root: root) else {
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
                self.schedulePreviews()
            } catch is CancellationError { }
            catch is TextSearchService.SearchError {
                guard let self, self.generation == generation else { return }
                self.isWorking = false; self.message = .invalidPattern; self.task = nil
            }
            catch {
                guard let self, self.generation == generation else { return }
                self.isWorking = false; self.message = .failed; self.task = nil
            }
        }
        self.task = task
        return task
    }

    /// Открытые документы папки не изменились и не поменялись местами за время фоновой работы.
    static func snapshotsStable(old: [FolderSearchService.OpenDocument], current: [FolderSearchService.OpenDocument], root: URL) -> Bool {
        let base = root.standardizedFileURL.pathComponents
        let relevant = old.filter { $0.url.standardizedFileURL.pathComponents.starts(with: base) }
        let currentRelevant = current.filter { $0.url.standardizedFileURL.pathComponents.starts(with: base) }
        let currentByID = Dictionary(currentRelevant.map { ($0.snapshot.documentID, $0) }, uniquingKeysWith: { first, _ in first })
        return relevant.count == currentRelevant.count && currentByID.count == currentRelevant.count &&
            Set(relevant.map { $0.snapshot.documentID }).count == relevant.count &&
            relevant.allSatisfy { old in currentByID[old.snapshot.documentID].map { sameSnapshot(old, $0) } == true }
    }

    // MARK: Замена

    var selectedMatches: [FolderSearchService.Match] { matches.filter { !excluded.contains($0.key) } }

    private var canBuildPlan: Bool {
        mode == .text && isReplaceEnabled && hasSearched && !isWorking && message == nil && root != nil &&
            !query.isEmpty && matches.contains { !excluded.contains($0.key) }
    }

    var canReplace: Bool { canBuildPlan && replaceState == .idle }

    func isSelected(_ match: FolderSearchService.Match) -> Bool { !excluded.contains(match.key) }

    /// true — выбраны все совпадения файла, false — ни одного, nil — часть.
    func selection(of file: FolderSearchService.File) -> Bool? {
        let own = matches.filter { $0.file == file }
        let chosen = own.filter { !excluded.contains($0.key) }.count
        return chosen == own.count ? true : (chosen == 0 ? false : nil)
    }

    func toggle(_ match: FolderSearchService.Match) {
        guard replaceState == .idle else { return }
        if !excluded.insert(match.key).inserted { excluded.remove(match.key) }
    }

    func toggle(_ file: FolderSearchService.File) {
        guard replaceState == .idle else { return }
        let keys = matches.filter { $0.file == file }.map(\.key)
        if selection(of: file) == true { excluded.formUnion(keys) } else { excluded.subtract(keys) }
    }

    func setAllSelected(_ selected: Bool) {
        guard replaceState == .idle else { return }
        excluded = selected ? [] : Set(matches.map(\.key))
    }

    private var currentRequest: FolderReplaceService.Request {
        // Значение берётся из панели поиска окна: при включённом \n, \t в тексте замены становятся управляющими символами.
        FolderReplaceService.Request(query: query, replacement: replacement,
            options: TextSearchService.Options(caseSensitive: caseSensitive, usesRegex: usesRegex, wholeWord: wholeWord),
            interpretsEscapes: interpretsEscapes())
    }

    /// Предпросмотр «станет» по полному тексту файла: открытый документ берётся из снимка, закрытый перечитывается.
    private func schedulePreviews() {
        previewTask?.cancel()
        previewTask = nil
        previews = [:]
        guard isReplaceEnabled, mode == .text, hasSearched, let root, !matches.isEmpty else { return }
        let generation = self.generation, request = currentRequest, matches = self.matches
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.generation == generation, let documents = self.snapshots() else { return }
            let openTexts = Dictionary(documents.map { ($0.snapshot.documentID, $0.snapshot.text) }, uniquingKeysWith: { first, _ in first })
            let worker = Task.detached(priority: .utility) { () -> [FolderSearchService.MatchKey: String] in
                var result: [FolderSearchService.MatchKey: String] = [:]
                for group in Dictionary(grouping: matches, by: { $0.file.url }).values {
                    if Task.isCancelled { return [:] }
                    guard let first = group.first else { continue }
                    let text: String
                    switch first.source {
                    case let .open(id, _, _):
                        guard let value = openTexts[id] else { continue }
                        text = value
                    case let .disk(expected):
                        guard let value = try? FolderSearchService.readForReplace(url: first.file.url, root: root, expected: expected,
                                                                                  isCancelled: { Task.isCancelled }) else { continue }
                        text = value
                    }
                    guard let edits = try? FolderReplaceService.edits(in: text, request: request, only: Set(group.map(\.range)),
                                                                      isCancelled: { Task.isCancelled }) else { continue }
                    for edit in edits {
                        result[FolderSearchService.MatchKey(url: first.file.url, location: edit.range.location, length: edit.range.length)] = edit.replacement
                    }
                }
                return result
            }
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, self.generation == generation else { return }
            self.previews = value
            self.previewTask = nil
        }
    }

    private func makePlan() -> ReplacePlan? {
        guard canBuildPlan else { return nil }
        var order: [URL] = []
        var groups: [URL: [FolderSearchService.Match]] = [:]
        for match in selectedMatches {
            if groups[match.file.url] == nil { order.append(match.file.url) }
            groups[match.file.url, default: []].append(match)
        }
        let files = order.compactMap { url -> ReplaceFilePlan? in
            guard let first = groups[url]?.first else { return nil }
            return ReplaceFilePlan(file: first.file, source: first.source, matches: groups[url] ?? [])
        }
        return files.isEmpty ? nil : ReplacePlan(request: currentRequest, files: files)
    }

    /// Открытые документы должны остаться теми же, что видел поиск.
    private func openDocumentsAreCurrent(_ plan: ReplacePlan) -> Bool {
        guard let documents = snapshots() else { return false }
        return plan.files.allSatisfy { file in
            guard case let .open(id, revision, _) = file.source else { return true }
            return documents.contains { $0.snapshot.documentID == id && $0.snapshot.revision == revision }
        }
    }

    @discardableResult
    func replaceSelected() -> Task<Void, Never>? {
        guard replaceState == .idle, let plan = makePlan(), let root else { return nil }
        guard openDocumentsAreCurrent(plan) else { message = .stale; return nil }
        let generation = self.generation, query = self.query
        replaceState = .confirming
        let task = Task { [weak self] in
            guard let self else { return }
            let summary = ReplaceSummary(matchCount: plan.matchCount, fileCount: plan.files.count, openCount: plan.openCount)
            guard self.confirmReplace(summary) else { self.replaceState = .idle; self.replaceTask = nil; return }
            guard !Task.isCancelled, self.generation == generation, self.root == root, self.query == query,
                  self.makePlan() == plan, self.openDocumentsAreCurrent(plan) else {
                self.replaceState = .idle; self.replaceTask = nil
                if self.generation == generation { self.message = .stale }
                return
            }
            await self.apply(plan, root: root)
        }
        replaceTask = task
        return task
    }

    /// Прекращает замену после текущего файла: запущенная атомарная запись не прерывается, уже записанное остаётся.
    func cancelReplace() { replaceTask?.cancel() }

    func dismissReport() { report = nil }

    private func apply(_ plan: ReplacePlan, root: URL) async {
        replaceState = .applying
        let query = self.query, mode = self.mode
        var result = ReplaceReport()
        func record(_ file: ReplaceFilePlan, _ outcome: FolderReplaceService.Outcome) {
            switch outcome {
            case let .replaced(count): result.replaced.append(.init(file: file.file, count: count, isOpen: file.isOpen))
            case let .skipped(reason): result.skipped.append(.init(file: file.file, reason: reason, count: file.matches.count))
            }
        }
        for file in plan.files where file.isOpen {
            if Task.isCancelled { result.isCancelled = true; break }
            let outcome = await applyOpen(OpenReplace(plan: file, request: plan.request))
            // Пропуск из-за отмены — не «файл изменился».
            if Task.isCancelled, case .skipped = outcome { result.isCancelled = true; break }
            record(file, outcome)
        }
        for file in plan.files where !file.isOpen {
            if Task.isCancelled { result.isCancelled = true; break }
            guard case let .disk(expected) = file.source else { continue }
            // Файл мог открыться в окне, пока шёл диалог: под открытым документом на диск не пишем.
            guard let documents = snapshots(), !documents.contains(where: { Self.refers($0, to: file.file.url) }) else {
                record(file, .skipped(.changed)); continue
            }
            let worker = Task.detached(priority: .userInitiated) { () throws -> FolderReplaceService.Outcome in
                try FolderReplaceService.replaceOnDisk(file: file.file, expected: expected, matches: file.matches,
                                                       request: plan.request, root: root, isCancelled: { Task.isCancelled })
            }
            do {
                record(file, try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }))
            } catch { result.isCancelled = true; break }
        }
        // Корень сменился или контроллер закрыт: отчёт относится к прежнему поиску и отбрасывается.
        if self.root == root { report = result }
        replaceState = .idle
        replaceTask = nil
        if self.root == root, self.query == query, self.mode == mode { start() }
    }

    private static func refers(_ document: FolderSearchService.OpenDocument, to url: URL) -> Bool {
        document.url.standardizedFileURL == url.standardizedFileURL || document.identity.matches(DocumentFileIdentity.resolve(url))
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

    static func sameSnapshot(_ first: FolderSearchService.OpenDocument, _ second: FolderSearchService.OpenDocument) -> Bool {
        first.url.standardizedFileURL == second.url.standardizedFileURL && first.identity.matches(second.identity) && first.snapshot == second.snapshot
    }

    static func containsFragment(_ match: FolderSearchService.Match, in text: String) -> Bool {
        let text = text as NSString, range = match.range
        return range.location >= 0 && range.location <= text.length && range.length >= 0 && range.length <= text.length - range.location &&
            text.substring(with: range) == match.matchedText
    }

    static func diskCurrent(_ match: FolderSearchService.Match, root: URL) async -> Bool {
        let worker = Task.detached(priority: .userInitiated) {
            (try? FolderSearchService.isCurrent(match, root: root, isCancelled: { Task.isCancelled })) == true
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
}
