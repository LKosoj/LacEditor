import Foundation

/// Каталог карточек проекта: фоновое чтение папки с кэшем по (время, размер).
@MainActor
final class StoryCardCatalog: ObservableObject {
    @Published private(set) var cards: [StoryCard] = [] {
        didSet { rebuildNames() }
    }
    @Published private(set) var isLoading = false

    private var cache = StoryCardScanCache()
    private var cacheRoot: URL?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var byName: [String: StoryCard] = [:]

    /// Перечитывает папку. Повторные вызовы с задержкой схлопываются; поздний результат отбрасывается.
    func refresh(root: URL, manuscriptPaths: Set<String>, delay: TimeInterval = 0) {
        generation &+= 1
        let current = generation
        task?.cancel()
        if cacheRoot != root {
            cache = StoryCardScanCache()
            cacheRoot = root
            cards = []
        }
        isLoading = true
        let snapshot = cache
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { () -> ([StoryCard], StoryCardScanCache)? in
                var local = snapshot
                let found = StoryCardScanner.scan(root: root, excluding: manuscriptPaths, cache: &local,
                                                  isCancelled: { Task.isCancelled })
                return Task.isCancelled ? nil : (found, local)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, self.generation == current else { return }
            self.isLoading = false
            guard let result else { return }
            self.cache = result.1
            if self.cards != result.0 { self.cards = result.0 }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isLoading = false
    }

    func card(forURL url: URL) -> StoryCard? {
        let path = url.standardizedFileURL.path
        return cards.first { $0.url.standardizedFileURL.path == path }
    }

    func card(forKey key: String) -> StoryCard? {
        cards.first { $0.id == key }
    }

    /// Ссылка из `relations`: сначала по id, затем по названию или псевдониму (без учёта регистра и форм слов).
    func resolve(reference: String) -> StoryCard? {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = UUID(uuidString: text), let card = cards.first(where: { $0.cardID == id }) { return card }
        return byName[Self.nameKey(text)]
    }

    /// Что записывать в `relations.to`: id, если он есть, иначе название.
    static func reference(for card: StoryCard) -> String {
        card.cardID?.uuidString ?? card.title
    }

    private static func nameKey(_ name: String) -> String {
        SearchTextNormalizer.terms(in: name).joined(separator: " ")
    }

    private func rebuildNames() {
        var names: [String: StoryCard] = [:]
        for card in cards {
            for name in card.allNames {
                let key = Self.nameKey(name)
                if !key.isEmpty, names[key] == nil { names[key] = card }
            }
        }
        byName = names
    }
}
