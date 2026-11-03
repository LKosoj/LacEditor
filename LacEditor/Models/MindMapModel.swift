import Foundation
import CoreGraphics

/// Что показывает карта: заголовки и списки документа, дерево рукописи или связи карточек мира.
enum MindMapKind: String, Sendable { case document, project, links }
enum MindMapLayoutStyle: String, Sendable { case tree, radial }

enum MindMapNodeKind: Sendable { case heading, listItem, group, scene, card, virtualRoot }
/// Вид линии между карточками: явная связь, совместные сцены, wiki-ссылка. Порядок = приоритет при слиянии пар.
enum MindMapEdgeStyle: Int, Sendable, Comparable {
    case relation = 0, coMention = 1, wikiLink = 2
    static func < (lhs: MindMapEdgeStyle, rhs: MindMapEdgeStyle) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct MindMapNode: Identifiable, Equatable, Sendable {
    /// Порядковый номер в обходе; для дерева совпадает с индексом в `MindMapTree.nodes`.
    let id: Int
    /// Стабильный ключ: UUID узла рукописи, `StoryCard.id` либо "n<id>".
    var key: String
    var title: String
    /// Уровень Markdown: число `#` у заголовка, у пункта списка — уровень родителя + 1. Корень без заголовка — 0.
    var level: Int
    var kind: MindMapNodeKind
    var parentID: Int?
    var childIDs: [Int] = []
    /// UTF-16, только для документа.
    var titleRange: NSRange?
    /// От начала строки узла до начала следующего узла того же или меньшего уровня.
    var subtreeRange: NSRange?
    var lineRange: NSRange?
    /// Заголовок подчёркнут строкой `===`/`---`: читается, но при переносе уровень не пересчитывается.
    var isSetext = false
    /// Отступ пункта списка в колонках и колонка, с которой начинается его текст.
    var indentColumn = 0
    var contentColumn = 0
    /// Маркер пункта списка как в файле ("-", "*", "1.").
    var marker = "-"
    var statusTitle: String?
    var statusColor: StatusColor?
    var wordCount: Int?
    /// Проект: `include == false`.
    var isExcludedFromBook = false
    /// Проект: файла нет на диске.
    var isMissingFile = false
    /// Связи: символ типа карточки.
    var symbol: String?
}

struct MindMapTree: Equatable, Sendable {
    var nodes: [MindMapNode]
    var rootID: Int
    /// Достигнут предел числа узлов: структурные правки отключены.
    var truncated: Bool

    static let empty = MindMapTree(nodes: [], rootID: 0, truncated: false)

    func node(_ id: Int) -> MindMapNode? { nodes.indices.contains(id) ? nodes[id] : nil }

    /// Расстояние до корня (у корня 0).
    func depth(of id: Int) -> Int {
        var depth = 0
        var current = node(id)?.parentID
        while let parent = current {
            depth += 1
            current = node(parent)?.parentID
        }
        return depth
    }

    func isDescendant(_ id: Int, of ancestor: Int) -> Bool {
        var current: Int? = id
        while let value = current {
            if value == ancestor { return true }
            current = node(value)?.parentID
        }
        return false
    }

    /// Число узлов поддерева, включая сам узел.
    func subtreeCount(of id: Int) -> Int {
        guard let node = node(id) else { return 0 }
        return 1 + node.childIDs.reduce(0) { $0 + subtreeCount(of: $1) }
    }

    /// Узлы в порядке обхода (корень первым); потомки свёрнутых узлов не входят.
    func visibleIDs(collapsed: Set<Int>) -> [Int] {
        guard node(rootID) != nil else { return [] }
        var result: [Int] = []
        var stack = [rootID]
        while let id = stack.popLast() {
            result.append(id)
            guard !collapsed.contains(id), let node = node(id) else { continue }
            stack.append(contentsOf: node.childIDs.reversed())
        }
        return result
    }

    /// Следующий и предыдущий брат.
    func sibling(of id: Int, offset: Int) -> Int? {
        guard let parent = node(id)?.parentID, let siblings = node(parent)?.childIDs,
              let index = siblings.firstIndex(of: id), siblings.indices.contains(index + offset) else { return nil }
        return siblings[index + offset]
    }
}

struct MindMapEdge: Equatable, Sendable {
    var from: Int
    var to: Int
    var style: MindMapEdgeStyle
    var weight: Int
    var label: String?
    /// Другие виды связи этой же пары (в линии показан самый сильный).
    var alsoStyles: [MindMapEdgeStyle] = []
}

/// Ссылка из `relations`, у которой нет карточки-цели.
struct MindMapUnresolvedLink: Equatable, Sendable {
    var from: Int
    var reference: String
    var kind: String
}

struct MindMapGraph: Equatable, Sendable {
    /// Все узлы — карточки (`kind == .card`), `id` = индекс.
    var nodes: [MindMapNode]
    var edges: [MindMapEdge]
    /// Скрыто из-за предела.
    var hiddenNodeCount: Int
    var unresolved: [MindMapUnresolvedLink] = []

    static let empty = MindMapGraph(nodes: [], edges: [], hiddenNodeCount: 0)

    func edges(of id: Int) -> [MindMapEdge] { edges.filter { $0.from == id || $0.to == id } }
}

struct MindMapPlacedNode: Equatable, Sendable {
    var id: Int
    var frame: CGRect
    var lines: [String]
}

struct MindMapLayoutResult: Equatable, Sendable {
    var placed: [Int: MindMapPlacedNode]
    var size: CGSize

    static let empty = MindMapLayoutResult(placed: [:], size: .zero)
}

/// Пределы числа узлов (плановые значения, 12 и 15 плана-описания).
enum MindMapLimits {
    static let documentNodes = 1500
    static let collapseDeepThreshold = 300
    static let graphDefault = 150
    static let graphHard = 600
}
