import Foundation

/// Связи карточек мира: явные `relations`, совместные сцены и wiki-ссылки. Всё считается без AI.
enum MindMapLinksBuilder {
    private struct PairKey: Hashable {
        let low: Int
        let high: Int
        init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
    }

    /// - Parameters:
    ///   - resolve: цель ссылки (id, название или псевдоним) -> карточка.
    ///   - coMentions: число общих сцен для пары ключей карточек.
    ///   - wikiLinks: ключ карточки -> цели её wiki-ссылок (как написаны в тексте).
    ///   - limit: сколько самых связанных карточек оставить; остальные считаются в `hiddenNodeCount`.
    static func build(cards: [StoryCard], resolve: (String) -> StoryCard?, coMentions: [StoryCardPair: Int],
                      wikiLinks: [String: [String]], minSharedScenes: Int, limit: Int) -> MindMapGraph {
        var indexOfKey: [String: Int] = [:]
        var fileNames: [String: Int] = [:]
        var nodes: [MindMapNode] = []
        for (index, card) in cards.enumerated() {
            if indexOfKey[card.id] == nil { indexOfKey[card.id] = index }
            for name in fileNameKeys(of: card) where fileNames[name] == nil { fileNames[name] = index }
            var node = MindMapNode(id: index, key: card.id, title: card.title, level: 0, kind: .card, parentID: nil)
            node.symbol = card.type.symbol
            nodes.append(node)
        }

        var pairs: [PairKey: MindMapEdge] = [:]
        func add(_ from: Int, _ to: Int, _ style: MindMapEdgeStyle, weight: Int, label: String?) {
            guard from != to else { return }
            let key = PairKey(from, to)
            guard var existing = pairs[key] else {
                pairs[key] = MindMapEdge(from: from, to: to, style: style, weight: weight, label: label)
                return
            }
            if style < existing.style {
                var stronger = MindMapEdge(from: from, to: to, style: style, weight: max(weight, existing.weight), label: label)
                stronger.alsoStyles = ([existing.style] + existing.alsoStyles).filter { $0 != style }
                pairs[key] = stronger
            } else {
                if style != existing.style, !existing.alsoStyles.contains(style) { existing.alsoStyles.append(style) }
                existing.weight = max(existing.weight, weight)
                pairs[key] = existing
            }
        }

        var unresolved: [MindMapUnresolvedLink] = []
        for (index, card) in cards.enumerated() {
            for relation in card.relations {
                if let target = resolve(relation.to), let other = indexOfKey[target.id] {
                    add(index, other, .relation, weight: 1, label: relation.kind.isEmpty ? nil : relation.kind)
                } else {
                    unresolved.append(MindMapUnresolvedLink(from: index, reference: relation.to, kind: relation.kind))
                }
            }
        }
        for (pair, shared) in coMentions.sorted(by: { ($0.key.a, $0.key.b) < ($1.key.a, $1.key.b) }) where shared >= minSharedScenes {
            if let a = indexOfKey[pair.a], let b = indexOfKey[pair.b] { add(a, b, .coMention, weight: shared, label: nil) }
        }
        for (key, targets) in wikiLinks.sorted(by: { $0.key < $1.key }) {
            guard let from = indexOfKey[key] else { continue }
            for target in targets {
                let name = fileNameKey(target)
                if let card = resolve(target), let other = indexOfKey[card.id] { add(from, other, .wikiLink, weight: 1, label: nil) }
                else if let other = fileNames[name] { add(from, other, .wikiLink, weight: 1, label: nil) }
            }
        }
        let edges = pairs.values.sorted {
            ($0.from, $0.to, $0.style.rawValue) < ($1.from, $1.to, $1.style.rawValue)
        }
        let full = MindMapGraph(nodes: nodes, edges: edges, hiddenNodeCount: 0, unresolved: unresolved)
        return trimmed(full, limit: limit)
    }

    /// Оставляет `limit` самых связанных карточек (по сумме весов, затем по названию) и перенумеровывает узлы.
    static func trimmed(_ graph: MindMapGraph, limit: Int) -> MindMapGraph {
        guard graph.nodes.count > limit, limit > 0 else { return graph }
        var score = [Int](repeating: 0, count: graph.nodes.count)
        for edge in graph.edges {
            score[edge.from] += edge.weight
            score[edge.to] += edge.weight
        }
        let ranked = graph.nodes.indices.sorted { a, b in
            if score[a] != score[b] { return score[a] > score[b] }
            let first = graph.nodes[a], second = graph.nodes[b]
            if first.title != second.title { return first.title < second.title }
            return first.key < second.key
        }
        let kept = Array(ranked.prefix(limit)).sorted()
        var newID: [Int: Int] = [:]
        for (position, old) in kept.enumerated() { newID[old] = position }
        var nodes: [MindMapNode] = []
        for old in kept {
            let source = graph.nodes[old]
            var node = MindMapNode(id: nodes.count, key: source.key, title: source.title, level: 0, kind: .card, parentID: nil)
            node.symbol = source.symbol
            nodes.append(node)
        }
        let edges: [MindMapEdge] = graph.edges.compactMap { edge in
            guard let from = newID[edge.from], let to = newID[edge.to] else { return nil }
            var copy = edge
            copy.from = from
            copy.to = to
            return copy
        }
        let unresolved: [MindMapUnresolvedLink] = graph.unresolved.compactMap { link in
            guard let from = newID[link.from] else { return nil }
            return MindMapUnresolvedLink(from: from, reference: link.reference, kind: link.kind)
        }
        return MindMapGraph(nodes: nodes, edges: edges, hiddenNodeCount: graph.nodes.count - nodes.count, unresolved: unresolved)
    }

    // MARK: Имена файлов

    /// Цель wiki-ссылки без пути, расширения и регистра.
    static func fileNameKey(_ target: String) -> String {
        var name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        let lower = name.lowercased()
        for suffix in [".md", ".markdown"] where lower.hasSuffix(suffix) { return String(lower.dropLast(suffix.count)) }
        return lower
    }

    private static func fileNameKeys(of card: StoryCard) -> [String] {
        [fileNameKey(card.url.lastPathComponent)]
    }
}
