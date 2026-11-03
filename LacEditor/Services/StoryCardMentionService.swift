import Foundation

struct StoryCardSceneCount: Equatable, Sendable {
    let nodeID: UUID
    let count: Int
}

/// Пара карточек для связи по совместным упоминаниям: всегда `a < b`.
struct StoryCardPair: Hashable, Sendable {
    let a: String
    let b: String

    init(_ first: String, _ second: String) {
        a = min(first, second)
        b = max(first, second)
    }
}

/// Полный индекс упоминаний для карты связей (этап 10).
struct StoryCardMentionIndex: Sendable {
    /// Сцена -> ключ карточки -> число упоминаний.
    var byScene: [UUID: [String: Int]]
    /// `false`, если часть сцен не удалось прочитать: отсутствие упоминаний тогда не доказано.
    var isComplete = true

    func scenes(ofCard key: String) -> [StoryCardSceneCount] {
        byScene.compactMap { scene, counts in counts[key].map { StoryCardSceneCount(nodeID: scene, count: $0) } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.nodeID.uuidString < $1.nodeID.uuidString }
    }

    func cards(inScene nodeID: UUID) -> [String] {
        (byScene[nodeID] ?? [:]).keys.sorted()
    }

    /// Вес пары — число сцен, где упомянуты обе карточки.
    func coMentions() -> [StoryCardPair: Int] {
        var result: [StoryCardPair: Int] = [:]
        for counts in byScene.values {
            let keys = counts.keys.sorted()
            for first in keys.indices {
                for second in keys.indices where second > first {
                    result[StoryCardPair(keys[first], keys[second]), default: 0] += 1
                }
            }
        }
        return result
    }
}

enum StoryCardMentionService {
    /// Прямой проход по одному тексту («сцена -> карточки»).
    static func cards(in text: String, matcher: StoryCardMatcher) -> [String: Int] {
        matcher.counts(in: text)
    }

    /// «Карточка -> сцены»: индекс слов лишь сужает круг сцен, каждую кандидатуру проверяет матчер.
    /// Сцены идут в порядке книги.
    @MainActor
    static func scenes(of card: StoryCard, matcher: StoryCardMatcher, store: ManuscriptProjectStore,
                       windowManager: WindowManager?, limit: Int) async -> [StoryCardSceneCount] {
        await scenesResult(of: card, matcher: matcher, store: store, windowManager: windowManager, limit: limit).scenes
    }

    /// То же, но с признаком полноты: часть сцен не прочиталась — «нигде не упомянут» утверждать нельзя.
    @MainActor
    static func scenesResult(of card: StoryCard, matcher: StoryCardMatcher, store: ManuscriptProjectStore,
                             windowManager: WindowManager?, limit: Int) async -> (scenes: [StoryCardSceneCount], isComplete: Bool) {
        let all = store.orderedTextNodes(includedOnly: true)
        let nodes = await candidateNodes(for: card, among: all, store: store, windowManager: windowManager)
        let loaded = await WriterNodeTextLoader.load(nodes: nodes, store: store, windowManager: windowManager)
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        let texts = loaded.parts.sorted { (order[$0.node.id] ?? 0) < (order[$1.node.id] ?? 0) }.map { ($0.node.id, $0.text) }
        let key = card.id
        let worker = Task.detached(priority: .userInitiated) { () -> [StoryCardSceneCount] in
            var result: [StoryCardSceneCount] = []
            for (id, text) in texts {
                if Task.isCancelled { break }
                if let count = matcher.counts(in: text)[key], count > 0 { result.append(StoryCardSceneCount(nodeID: id, count: count)) }
            }
            return result
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        return (Array(result.prefix(limit)), loaded.problems.isEmpty && !loaded.snapshotsUnavailable)
    }

    /// Полный индекс: прямой проход по всем включённым сценам.
    @MainActor
    static func buildIndex(cards: [StoryCard], store: ManuscriptProjectStore, windowManager: WindowManager?) async -> StoryCardMentionIndex {
        let matcher = StoryCardMatcher(cards: cards)
        let loaded = await WriterNodeTextLoader.load(nodes: store.orderedTextNodes(includedOnly: true), store: store, windowManager: windowManager)
        let texts = loaded.parts.map { ($0.node.id, $0.text) }
        let worker = Task.detached(priority: .userInitiated) { () -> StoryCardMentionIndex in
            var byScene: [UUID: [String: Int]] = [:]
            for (id, text) in texts {
                if Task.isCancelled { break }
                let counts = matcher.counts(in: text)
                if !counts.isEmpty { byScene[id] = counts }
            }
            return StoryCardMentionIndex(byScene: byScene)
        }
        var index = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        index.isComplete = loaded.problems.isEmpty && !loaded.snapshotsUnavailable
        return index
    }

    /// Сцены, где имя карточки может встречаться. Нет индекса, устаревшая запись, китайское имя или переполненная выдача — все сцены.
    @MainActor
    private static func candidateNodes(for card: StoryCard, among nodes: [ManuscriptNode], store: ManuscriptProjectStore,
                                       windowManager: WindowManager?) async -> [ManuscriptNode] {
        let hasChinese = card.allNames.contains { name in
            name.unicodeScalars.contains { SearchTextNormalizer.scriptLanguage(of: String($0)) == .zh }
        }
        guard !hasChinese, let index = SearchIndexRegistry.shared.existingIndex(for: store.rootURL),
              let stamps = try? await index.fileStamps() else { return nodes }
        let limit = 50
        var paths = Set<String>()
        for name in card.allNames {
            guard let hits = try? await index.search(name, limit: limit), hits.count < limit else { return nodes }
            paths.formUnion(hits.map(\.path))
        }
        let openPaths = Set((windowManager?.folderSearchSnapshots(root: store.rootURL) ?? []).map { $0.url.standardizedFileURL.path })
        return nodes.filter { node in
            guard let path = node.path, let url = store.fileURL(for: node) else { return false }
            if paths.contains(path) || openPaths.contains(url.standardizedFileURL.path) { return true }
            // Файл новее записи индекса или вовсе не проиндексирован.
            return stamps[path] != SearchIndexer.stamp(of: url)
        }
    }
}

extension StoryCardMentionService {
    /// Текст сцен для запроса к AI: заголовок сцены и её текст, сначала сцены с наибольшим числом упоминаний.
    @MainActor
    static func sourceText(of scenes: [StoryCardSceneCount], limit: Int, store: ManuscriptProjectStore,
                           windowManager: WindowManager?) async -> String {
        let nodes = scenes.prefix(limit).compactMap { store.node(id: $0.nodeID) }
        let loaded = await WriterNodeTextLoader.load(nodes: nodes, store: store, windowManager: windowManager)
        let byID = Dictionary(uniqueKeysWithValues: loaded.parts.map { ($0.node.id, $0) })
        return nodes.compactMap { node in byID[node.id].map { "[\(node.title)]\n\($0.text)" } }.joined(separator: "\n\n")
    }
}
