import Foundation

/// Карточка доски: один прямой потомок открытой группы (или корня).
struct BoardCard: Identifiable, Equatable {
    let id: UUID
    let isGroup: Bool
    let title: String
    let synopsis: String
    /// Название статуса или nil.
    let status: String?
    let label: String?
    let tags: [String]
    let include: Bool
    /// Для группы — сумма по сценам внутри; nil, если слова ещё не посчитаны.
    let wordCount: Int?
    /// Сцены внутри группы (все уровни); у сцены nil.
    let sceneCount: Int?
    let isMissingFile: Bool
}

/// Фильтр доски: только скрывает карточки, порядок и манифест не меняет. Группы фильтром не скрываются.
struct BoardFilter: Equatable {
    /// nil — любой статус, "" — без статуса.
    var status: String?
    var tag: String?

    var isActive: Bool { status != nil || tag != nil }

    func matches(_ card: BoardCard) -> Bool {
        if card.isGroup { return true }
        if let status {
            if status.isEmpty {
                if let own = card.status, !own.isEmpty { return false }
            } else if card.status != status {
                return false
            }
        }
        if let tag, !card.tags.contains(tag) { return false }
        return true
    }
}

enum BoardOrdering {
    /// Индекс вставки в полном списке детей контейнера для `moveNode` (узел сначала изымается, потом вставляется).
    /// nil, если якоря нет среди детей или карточка переносится на себя.
    static func targetIndex(fullIDs: [UUID], moving: UUID, relativeTo anchor: UUID, placeAfter: Bool) -> Int? {
        guard moving != anchor else { return nil }
        let rest = fullIDs.filter { $0 != moving }
        guard let index = rest.firstIndex(of: anchor) else { return nil }
        return index + (placeAfter ? 1 : 0)
    }

    /// Соседняя видимая карточка на шаг -1 или +1; nil на границе или если карточки нет среди видимых.
    static func neighbor(visibleIDs: [UUID], of id: UUID, step: Int) -> UUID? {
        guard let index = visibleIDs.firstIndex(of: id) else { return nil }
        let target = index + step
        guard visibleIDs.indices.contains(target) else { return nil }
        return visibleIDs[target]
    }
}

enum BoardModel {
    /// Карточки детей контейнера (nil — корень). `counts` — слова по узлам, `missing` — узлы без файла.
    static func cards(project: ManuscriptProject, container: UUID?, counts: [UUID: Int], missing: Set<UUID>) -> [BoardCard] {
        project.children(of: container).map { node in
            if node.kind == .group {
                let scenes = descendantScenes(of: node)
                let known = scenes.compactMap { counts[$0.id] }
                return BoardCard(id: node.id, isGroup: true, title: node.title, synopsis: node.synopsis ?? "",
                                 status: nil, label: node.label, tags: node.tags, include: node.include,
                                 wordCount: known.isEmpty ? nil : known.reduce(0, +), sceneCount: scenes.count,
                                 isMissingFile: false)
            }
            return BoardCard(id: node.id, isGroup: false, title: node.title, synopsis: node.synopsis ?? "",
                             status: node.status.flatMap { $0.isEmpty ? nil : $0 }, label: node.label.flatMap { $0.isEmpty ? nil : $0 },
                             tags: node.tags, include: node.include, wordCount: counts[node.id], sceneCount: nil,
                             isMissingFile: missing.contains(node.id))
        }
    }

    static func availableTags(in cards: [BoardCard]) -> [String] {
        Array(Set(cards.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func descendantScenes(of group: ManuscriptNode) -> [ManuscriptNode] {
        group.children.flatMap { $0.kind == .text ? [$0] : descendantScenes(of: $0) }
    }
}
