import Combine
import Foundation

/// Список заметок сервера в памяти (на диск не пишется): корни, папки по запросу и полный обход для ссылок.
@MainActor
final class VaultCatalog: ObservableObject {
    @Published private(set) var roots: [VaultTreeEntry] = []
    @Published private(set) var childrenByPath: [String: [VaultTreeEntry]] = [:]
    /// Только файлы (любых расширений), полный обход.
    @Published private(set) var allFiles: [VaultTreeEntry] = []
    @Published private(set) var isFullListingLoaded = false
    private(set) var lastFullListingDate: Date?

    private static let pageSize = 1000
    private nonisolated static let maxAttempts = 3
    private static let fullDepth = 8

    private let client: VaultClient
    private var hidden: Set<String>
    /// Номер последней загрузки корней: поздний ответ прежней загрузки отбрасывается.
    private var rootsGeneration: UInt = 0
    /// Проверенные записи без учёта скрытых разделов: из них пересчитывается видимое.
    private var rawRoots: [VaultTreeEntry] = []
    private var rawChildren: [String: [VaultTreeEntry]] = [:]
    private var rawFiles: [VaultTreeEntry] = []
    private var markdownPaths: [String] = []
    /// Растёт при `clear()`: поздний ответ с прежним номером отбрасывается.
    private var epoch = 0
    private var folderGenerations: [String: Int] = [:]
    private var refreshTask: Task<Bool, Never>?
    private var refreshToken = 0

    init(client: VaultClient, hiddenRoots: [String] = []) {
        self.client = client
        self.hidden = Set(hiddenRoots)
    }

    /// Пересчитывает видимое из уже загруженного, без запросов.
    func updateHiddenRoots(_ roots: [String]) {
        hidden = Set(roots)
        publishRoots()
        publishChildren()
        publishFiles()
    }

    func loadRoots() async throws {
        let startEpoch = epoch
        rootsGeneration += 1
        let generation = rootsGeneration
        let client = self.client
        let result = try await Self.collectPages(client: client, path: "", depth: 0)
        guard result.isComplete else { throw VaultClientError.incompleteResponse }
        let entries = await Task.detached(priority: .utility) { Self.normalized(result.entries, under: "", hidden: []) }.value
        guard startEpoch == epoch, rootsGeneration == generation else { return }
        rawRoots = entries
        publishRoots()
    }

    func loadChildren(of path: String) async throws {
        guard VaultPath.validated(path) != nil else { throw VaultSyncError.invalidPath }
        if Self.isHidden(path, hidden) { return }
        let startEpoch = epoch
        let generation = (folderGenerations[path] ?? 0) + 1
        folderGenerations[path] = generation
        let client = self.client
        let result = try await Self.collectPages(client: client, path: path, depth: 0)
        guard result.isComplete else { throw VaultClientError.incompleteResponse }
        let entries = await Task.detached(priority: .utility) { Self.normalized(result.entries, under: path, hidden: []) }.value
        guard startEpoch == epoch, folderGenerations[path] == generation else { return }
        rawChildren[path] = entries
        publishChildren()
    }

    /// true — `allFiles` обновлён. Неполный обход, ошибка и отмена оставляют каталог прежним.
    @discardableResult
    func refreshFullListing() async -> Bool {
        if let task = refreshTask { return await task.value }
        let startEpoch = epoch
        let client = self.client
        refreshToken += 1
        let token = refreshToken
        let task = Task { () -> Bool in
            do {
                let result = try await Self.collectPages(client: client, path: "", depth: Self.fullDepth)
                guard result.isComplete else { return false }
                let files = await Task.detached(priority: .utility) {
                    Self.normalized(result.entries, under: "", hidden: [], allowsNested: true).filter { $0.kind == .file }
                }.value
                try Task.checkCancellation()
                guard startEpoch == self.epoch else { return false }
                self.rawFiles = files
                self.markdownPaths = Self.markdownPaths(in: files)
                if !self.isFullListingLoaded { self.isFullListingLoaded = true }
                self.lastFullListingDate = Date()
                self.publishFiles()
                return true
            } catch {
                return false
            }
        }
        refreshTask = task
        let result = await task.value
        if refreshToken == token { refreshTask = nil }
        return result
    }

    /// Пути `.md`/`.markdown` для подсказок `[[`: из полного обхода, а до него — из корней и загруженных папок.
    func wikiLinkPaths() -> [String] {
        if isFullListingLoaded { return hidden.isEmpty ? markdownPaths : visible(markdownPaths) }
        var seen = Set<String>()
        var result: [String] = []
        for entry in roots + childrenByPath.values.flatMap({ $0 }) where entry.kind == .file && Self.isMarkdown(entry.path) {
            if seen.insert(entry.path).inserted { result.append(entry.path) }
        }
        return result
    }

    func clear() {
        // Обход не отменяем: поздний результат отбросит проверка `epoch`.
        epoch += 1
        refreshTask = nil
        folderGenerations = [:]
        rawRoots = []
        rawChildren = [:]
        rawFiles = []
        markdownPaths = []
        lastFullListingDate = nil
        if isFullListingLoaded { isFullListingLoaded = false }
        publishRoots()
        publishChildren()
        publishFiles()
    }

    // MARK: Публикация (присваивается только изменившееся: подписчики зря не просыпаются)

    private func publishRoots() {
        let value = rawRoots.filter { !Self.isHidden($0.path, hidden) }
        if roots != value { roots = value }
    }

    private func publishChildren() {
        var value: [String: [VaultTreeEntry]] = [:]
        for (path, entries) in rawChildren where !Self.isHidden(path, hidden) {
            value[path] = entries.filter { !Self.isHidden($0.path, hidden) }
        }
        if childrenByPath != value { childrenByPath = value }
    }

    private func publishFiles() {
        let value = rawFiles.filter { !Self.isHidden($0.path, hidden) }
        if allFiles != value { allFiles = value }
    }

    private func visible(_ paths: [String]) -> [String] {
        paths.filter { !Self.isHidden($0, hidden) }
    }

    // MARK: Чистые помощники

    /// Скрыт ли путь: первый компонент входит в список (сравнение точное, как отдаёт сервер).
    nonisolated private static func isHidden(_ path: String, _ hidden: Set<String>) -> Bool {
        guard !hidden.isEmpty else { return false }
        let first = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return hidden.contains(first)
    }

    nonisolated private static func isMarkdown(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    nonisolated private static func markdownPaths(in files: [VaultTreeEntry]) -> [String] {
        files.filter { isMarkdown($0.path) }.map(\.path)
    }

    /// Отбрасывает записи с небезопасным путём, не лежащие строго внутри `parent` (для `""` — любые), повторы
    /// и записи скрытых разделов. Порядок сервера сохраняется.
    nonisolated static func normalized(_ entries: [VaultTreeEntry], under parent: String, hidden: Set<String>,
                                       allowsNested: Bool = false) -> [VaultTreeEntry] {
        var seen = Set<String>()
        var result: [VaultTreeEntry] = []
        let prefix = parent.isEmpty ? "" : parent + "/"
        for entry in entries {
            guard VaultPath.validated(entry.path) != nil, entry.path.hasPrefix(prefix),
                  allowsNested || !entry.path.dropFirst(prefix.count).contains("/"),
                  !isHidden(entry.path, hidden), seen.insert(entry.path).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    /// Все страницы подряд. `409 listingChanged` — обход заново, не больше трёх попыток.
    /// Полным обход считается, если у последней страницы нет токена и `listingComplete != false`.
    nonisolated static func collectPages(client: VaultClient, path: String, depth: Int) async throws
        -> (entries: [VaultTreeEntry], isComplete: Bool) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                var entries: [VaultTreeEntry] = []
                var token: String?
                var seenTokens = Set<String>()
                var isComplete = true
                repeat {
                    try Task.checkCancellation()
                    let page = try await client.tree(path: path, depth: depth, pageSize: pageSize, pageToken: token)
                    entries += page.entries
                    // Токен уже был (в том числе A→B→A) или страниц слишком много — сервер зациклил обход.
                    if let next = page.nextPageToken {
                        guard seenTokens.insert(next).inserted, seenTokens.count <= 10_000 else { throw VaultClientError.invalidResponse }
                    }
                    token = page.nextPageToken
                    if token == nil { isComplete = page.listingComplete != false }
                } while token != nil
                return (entries, isComplete)
            } catch VaultClientError.listingChanged {
                if attempt >= maxAttempts { throw VaultClientError.listingChanged }
            }
        }
    }
}
