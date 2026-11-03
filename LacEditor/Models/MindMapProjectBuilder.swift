import Foundation

/// Дерево рукописи (группы и сцены манифеста) для карты проекта. Названия в карте не правятся: только порядок.
enum MindMapProjectBuilder {
    static func build(project: ManuscriptProject, wordCounts: [UUID: Int], missing: Set<UUID>) -> MindMapTree {
        var nodes = [MindMapNode(id: 0, key: "n0", title: project.title, level: 0, kind: .virtualRoot, parentID: nil)]
        let statuses = project.statuses

        @discardableResult
        func add(_ source: ManuscriptNode, parent: Int, level: Int) -> Int {
            let id = nodes.count
            var node = MindMapNode(id: id, key: source.id.uuidString, title: source.title, level: level,
                                   kind: source.kind == .group ? .group : .scene, parentID: parent)
            node.isExcludedFromBook = !source.include
            node.isMissingFile = missing.contains(source.id)
            if let status = source.status {
                node.statusTitle = status
                node.statusColor = statuses.first { $0.title == status }?.color ?? .gray
            }
            nodes.append(node)
            nodes[parent].childIDs.append(id)
            var total = source.kind == .text ? (wordCounts[source.id] ?? 0) : 0
            for child in source.children { total += add(child, parent: id, level: level + 1) }
            nodes[id].wordCount = total > 0 ? total : nil
            return total
        }
        for node in project.nodes { add(node, parent: 0, level: 1) }
        return MindMapTree(nodes: nodes, rootID: 0, truncated: false)
    }
}
