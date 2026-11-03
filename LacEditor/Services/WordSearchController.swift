import Combine
import Foundation

/// Режим «По словам»: поиск по индексу SQLite FTS5 с ранжированием bm25, учётом несохранённых открытых документов
/// и необязательным расширением запроса ИИ. Каждый запуск и отмена увеличивают поколение: поздний результат отбрасывается.
@MainActor
final class WordSearchController: ObservableObject {
    static let resultLimit = 100

    @Published private(set) var hits: [SearchIndexHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    /// Идёт обновление индекса; поиск в это время разрешён и видит то, что уже проиндексировано.
    @Published private(set) var progress: SearchIndexProgress?
    @Published private(set) var message = ""
    /// «По смыслу (AI)»: запрос дополняется словами от модели.
    @Published var usesMeaning = false
    /// Слова ИИ в виде «чипов»: убираются в один клик, поиск перезапускается без нового обращения к модели.
    @Published private(set) var expansion: [String] = []
    /// Нормализованные слова запроса для подсветки.
    @Published private(set) var terms: Set<String> = []

    weak var appState: AppState?

    private let snapshots: () -> [FolderSearchService.OpenDocument]?
    private let open: (URL) async -> FolderSearchService.OpenDocument?
    private let reveal: (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool
    private let openFile: (URL) -> Void
    private let registry: SearchIndexRegistry
    private let cache = SearchLiveDocumentCache()
    private var root: URL?
    private var generation: UInt = 0
    private var task: Task<Void, Never>?
    private var indexGeneration: UInt = 0
    private var indexTask: Task<Void, Never>?
    private var lastQuery = ""

    init(snapshots: @escaping () -> [FolderSearchService.OpenDocument]?,
         open: @escaping (URL) async -> FolderSearchService.OpenDocument?,
         reveal: @escaping (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool,
         openFile: @escaping (URL) -> Void,
         registry: SearchIndexRegistry = .shared) {
        self.snapshots = snapshots
        self.open = open
        self.reveal = reveal
        self.openFile = openFile
        self.registry = registry
    }

    deinit {
        task?.cancel()
        indexTask?.cancel()
    }

    func setRoot(_ root: URL?) {
        let value = root.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        guard self.root != value else { return }
        self.root = value
        cancel()
        cancelIndexing()
    }

    /// Снимает поиск и результаты (индексация не прерывается).
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        hits = []
        isSearching = false
        hasSearched = false
        message = ""
        expansion = []
        terms = []
    }

    func start(query: String) {
        begin(query: query, fixedExpansion: nil)
    }

    /// Убирает слово ИИ и сразу повторяет поиск по последнему запросу.
    func removeExpansion(_ word: String) {
        guard expansion.contains(word), !lastQuery.isEmpty else { return }
        begin(query: lastQuery, fixedExpansion: expansion.filter { $0 != word })
    }

    private func begin(query: String, fixedExpansion: [String]?) {
        cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = query
        guard !query.isEmpty else { return }
        guard let root else { message = L10n.tr("按词搜索需要先打开文件夹。"); return }
        guard SearchDatabase.fts5Available() else { message = L10n.tr("此系统无法使用按词搜索。"); return }
        if let fixedExpansion { expansion = fixedExpansion }
        let generation = self.generation
        isSearching = true
        task = Task { [weak self] in
            await self?.run(query: query, root: root, generation: generation, fixedExpansion: fixedExpansion)
        }
    }

    private func isCurrent(_ generation: UInt, _ root: URL) -> Bool {
        !Task.isCancelled && self.generation == generation && self.root == root
    }

    private func run(query: String, root: URL, generation: UInt, fixedExpansion: [String]?) async {
        var words = fixedExpansion ?? []
        if fixedExpansion == nil, usesMeaning {
            let result = await expandedWords(for: query)
            guard isCurrent(generation, root) else { return }
            if let failure = result.failure { message = failure }
            words = result.words
            expansion = words
        }
        let searchQuery = SearchQuery(text: query, expansion: words)
        let index = registry.index(for: root)
        let cache = self.cache
        var attempts = 0
        var rebuilt = false
        while true {
            guard let documents = snapshots() else { finish(stale: true); return }
            guard isCurrent(generation, root) else { return }
            let live = await Task.detached(priority: .userInitiated) {
                SearchLiveDocuments.build(snapshots: documents, root: root, cache: cache)
            }.value
            let found: [SearchIndexHit]
            do { found = try await index.search(searchQuery, limit: Self.resultLimit, live: live) }
            catch {
                guard isCurrent(generation, root) else { return }
                // Порча базы во время работы: файл уже удалён, строим заново и повторяем поиск один раз.
                if let error = error as? SearchIndexError, error.isCorruption, !rebuilt {
                    rebuilt = true
                    let rebuiltOK = await rebuildAfterCorruption(root: root, index: index)
                    guard isCurrent(generation, root) else { return }
                    if rebuiltOK { continue }
                }
                if let error = error as? SearchIndexError, case .unavailable = error {
                    message = L10n.tr("此系统无法使用按词搜索。")
                } else {
                    message = L10n.tr("搜索失败")
                }
                isSearching = false
                task = nil
                return
            }
            guard isCurrent(generation, root) else { return }
            guard let current = snapshots() else { finish(stale: true); return }
            guard isCurrent(generation, root) else { return }
            // Открытые документы не должны измениться за время поиска; один повтор, дальше результат считается устаревшим.
            guard FolderSearchController.snapshotsStable(old: documents, current: current, root: root) else {
                attempts += 1
                if attempts > 1 { finish(stale: true); return }
                continue
            }
            hits = found
            terms = searchQuery.allTerms
            isSearching = false
            hasSearched = true
            task = nil
            return
        }
    }

    /// Пересоздаёт индекс после порчи и ждёт завершения обновления; true — индекс снова пригоден для поиска.
    private func rebuildAfterCorruption(root: URL, index: SearchIndex) async -> Bool {
        refreshIndex()
        await indexTask?.value
        return (try? await index.prepare()) != nil
    }

    private func finish(stale: Bool) {
        if stale { message = L10n.tr("结果已过期，请重新搜索") }
        isSearching = false
        task = nil
    }

    /// Слова ИИ. В модель уходит только текст запроса. Недоступный ИИ или ошибка модели: поиск идёт без расширения.
    /// Текст ошибки возвращается, а не пишется сам: его показывает только актуальный запрос.
    private func expandedWords(for query: String) async -> (words: [String], failure: String?) {
        guard let appState, appState.aiAvailability(for: .searchExpansion) == .available else { return ([], nil) }
        let profile = appState.preferences.aiProfile(for: .searchExpansion)
        guard profile.supports(.text) else { return ([], nil) }
        do {
            let key = try AIKeychainStore().load(for: .text, baseURL: profile.baseURL)
            let response = try await AIClient().generateText(input: SearchExpansionBuilder.input(request: query),
                                                             instructions: SearchExpansionBuilder.instructions,
                                                             profile: profile, key: key, mode: .reading)
            return (SearchExpansionBuilder.parse(response, query: query), nil)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return ([], nil) }
            return ([], error.localizedDescription)
        }
    }

    // MARK: Индекс

    func refreshIndex() { startIndexing(rebuild: false) }

    /// Удаляет индекс и строит заново.
    func rebuildIndex() { startIndexing(rebuild: true) }

    /// Удаляет индекс папки; новый строится при следующем входе в режим.
    func deleteIndex() {
        guard let root else { return }
        let previous = indexTask
        previous?.cancel()
        indexGeneration &+= 1
        let token = indexGeneration
        progress = nil
        cancel()
        let registry = self.registry
        indexTask = Task { [weak self] in
            await previous?.value
            try? await registry.index(for: root).destroy()
            registry.remove(root: root)
            guard let self, self.indexGeneration == token else { return }
            self.indexTask = nil
        }
    }

    private func cancelIndexing() {
        indexTask?.cancel()
        indexTask = nil
        indexGeneration &+= 1
        progress = nil
    }

    private func startIndexing(rebuild: Bool) {
        guard let root else { return }
        guard SearchDatabase.fts5Available() else { message = L10n.tr("此系统无法使用按词搜索。"); return }
        let previous = indexTask
        previous?.cancel()
        indexGeneration &+= 1
        let token = indexGeneration
        progress = SearchIndexProgress(done: 0, total: 0)
        if rebuild { cancel() }
        let registry = self.registry
        let onProgress: @Sendable (SearchIndexProgress) -> Void = { [weak self] value in
            Task { @MainActor in self?.indexProgress(value, token: token) }
        }
        indexTask = Task { [weak self] in
            // Предыдущая индексация должна закончиться: иначе она заново создаст только что удалённый файл.
            await previous?.value
            guard !Task.isCancelled else { return }
            var current = registry.index(for: root)
            if rebuild {
                try? await current.destroy()
                registry.remove(root: root)
                current = registry.index(for: root)
            }
            let index = current
            let worker = Task.detached(priority: .utility) { () -> Result<SearchIndexer.Report, Error> in
                do {
                    return .success(try await SearchIndexer.refresh(index, root: root, progress: onProgress,
                                                                    isCancelled: { Task.isCancelled }))
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, self.indexGeneration == token else { return }
            self.progress = nil
            self.indexTask = nil
            switch result {
            case let .success(report):
                // Результаты, показанные пока индекс строился, могут быть неполными: повторяем поиск, если что-то изменилось.
                if report.indexed > 0 || report.removed > 0, self.hasSearched, !self.lastQuery.isEmpty {
                    self.begin(query: self.lastQuery, fixedExpansion: self.expansion)
                }
            case let .failure(error):
                if error is CancellationError { return }
                if let error = error as? SearchIndexError, case .unavailable = error {
                    self.message = L10n.tr("此系统无法使用按词搜索。")
                } else {
                    self.message = L10n.tr("搜索失败")
                }
            }
        }
    }

    private func indexProgress(_ value: SearchIndexProgress, token: UInt) {
        guard indexGeneration == token else { return }
        progress = value
    }

    // MARK: Переход к результату

    /// Открывает файл и ставит курсор на первое найденное слово около строки результата.
    @discardableResult
    func select(_ hit: SearchIndexHit) -> Task<Void, Never>? {
        guard let root, hits.contains(hit) else { return nil }
        let generation = self.generation
        let url = hit.url(in: root)
        let terms = self.terms
        let task = Task { [weak self] in
            guard let self else { return }
            guard let opened = await self.open(url) else {
                if self.isAdmitted(hit, root: root, generation: generation) { self.openFile(url); self.message = Self.notFoundText }
                return
            }
            guard self.isAdmitted(hit, root: root, generation: generation),
                  let document = self.snapshots()?.first(where: { FolderSearchController.sameSnapshot(opened, $0) }) else {
                if self.isAdmitted(hit, root: root, generation: generation) { self.message = L10n.tr("结果已过期，请重新搜索") }
                return
            }
            guard let match = Self.match(for: hit, in: document, terms: terms) else {
                self.message = Self.notFoundText
                return
            }
            guard self.isAdmitted(hit, root: root, generation: generation) else { return }
            if !self.reveal(match, document) { self.message = L10n.tr("结果已过期，请重新搜索") }
        }
        return task
    }

    private static var notFoundText: String { L10n.tr("未在文本中找到该片段，已打开文件。") }

    private func isAdmitted(_ hit: SearchIndexHit, root: URL, generation: UInt) -> Bool {
        !Task.isCancelled && self.generation == generation && self.root == root && hits.contains(hit)
    }

    /// Синтетическое совпадение для перехода: первое слово запроса в строках результата, иначе начало строки.
    /// nil — строки результата в тексте уже нет.
    static func match(for hit: SearchIndexHit, in document: FolderSearchService.OpenDocument, terms: Set<String>) -> FolderSearchService.Match? {
        let text = document.snapshot.text
        let ns = text as NSString
        guard hit.line >= 1, let start = lineStart(hit.line, in: ns), start < ns.length || hit.line == 1 else { return nil }
        let lastLine = max(hit.endLine, hit.line)
        let fragmentEnd = lineStart(lastLine + 1, in: ns) ?? ns.length
        let window = NSRange(location: start, length: max(0, fragmentEnd - start))
        let word = TextSegmentation.words(in: text, range: window).first { segment in
            SearchTextNormalizer.term(for: segment.text).map { terms.contains($0) } == true
        }
        let range = word?.range ?? NSRange(location: start, length: 0)
        let file = FolderSearchService.File(url: URL(fileURLWithPath: document.url.standardizedFileURL.path), relativePath: hit.path)
        return FolderSearchService.Match(file: file, range: range, matchedText: ns.substring(with: range),
                                         contextRange: ns.lineRange(for: range), context: ns.substring(with: ns.lineRange(for: range)),
                                         source: .open(documentID: document.snapshot.documentID, revision: document.snapshot.revision,
                                                       identity: document.identity))
    }

    /// Смещение начала строки `line` (с единицы); nil — строк меньше. Строка сразу за последней даёт конец текста.
    /// Строки считаются как в `SearchIndexChunker`: разделители только `\n`, `\r\n` и `\r` (не U+2028, U+2029, U+0085).
    static func lineStart(_ line: Int, in text: NSString) -> Int? {
        var position = 0
        for _ in 1..<max(line, 1) {
            var index = position
            while index < text.length {
                let unit = text.character(at: index)
                if unit == 0x0A || unit == 0x0D { break }
                index += 1
            }
            guard index < text.length else { return nil }
            if text.character(at: index) == 0x0D, index + 1 < text.length, text.character(at: index + 1) == 0x0A { index += 1 }
            position = index + 1
        }
        return position
    }
}
