import Foundation
import CoreGraphics

/// Перенесённый текст узла и размер его рамки.
struct MindMapNodeMetrics: Equatable, Sendable {
    var lines: [String]
    var size: CGSize
}

/// Раскладки карты: чистые функции без AppKit. Текст измеряет внедряемая `measure`; один вход всегда даёт одну раскладку.
enum MindMapLayout {
    static let maxTextWidth: CGFloat = 220
    static let maxLines = 3
    static let paddingX: CGFloat = 10
    static let paddingY: CGFloat = 6
    static let columnGap: CGFloat = 48
    static let rowGap: CGFloat = 10
    static let margin: CGFloat = 16

    // MARK: Перенос текста и размеры

    /// Перенос по словам, не больше `maxLines` строк; остаток обрезается знаком «…».
    static func wrap(_ text: String, maxWidth: CGFloat, maxLines: Int, measure: (String) -> CGSize) -> [String] {
        let source = String(text.replacingOccurrences(of: "\n", with: " ").prefix(max(1, maxLines) * 120))
        var lines: [String] = []
        var current = ""
        for character in source {
            if character == " ", current.isEmpty { continue }
            let candidate = current + String(character)
            if current.isEmpty || measure(candidate).width <= maxWidth {
                current = candidate
                continue
            }
            if character == " " {
                lines.append(current)
                current = ""
            } else if let space = current.lastIndex(of: " ") {
                lines.append(String(current[..<space]))
                current = String(current[current.index(after: space)...]) + String(character)
            } else {
                lines.append(current)
                current = String(character)
            }
        }
        if !current.isEmpty { lines.append(current) }
        if lines.isEmpty { return [""] }
        if lines.count > maxLines {
            var last = lines[maxLines - 1].trimmingCharacters(in: .whitespaces)
            while !last.isEmpty, measure(last + "…").width > maxWidth { last.removeLast() }
            lines = Array(lines.prefix(maxLines - 1)) + [last + "…"]
        }
        return lines
    }

    /// Строки и размер рамки каждого узла. Пустое название показывается как «未命名».
    static func metrics(for nodes: [MindMapNode], measure: (String) -> CGSize) -> [Int: MindMapNodeMetrics] {
        let lineHeight = ceil(measure("Ag").height)
        var result: [Int: MindMapNodeMetrics] = [:]
        for node in nodes {
            let title = node.title.trimmingCharacters(in: .whitespaces).isEmpty ? L10n.tr("未命名") : node.title
            let lines = wrap(title, maxWidth: maxTextWidth, maxLines: maxLines, measure: measure)
            var textWidth: CGFloat = 0
            for line in lines { textWidth = max(textWidth, ceil(measure(line).width)) }
            var extra: CGFloat = 0
            if node.statusColor != nil { extra += 14 }
            if let words = node.wordCount { extra += ceil(measure("\(words)").width * 0.8) + 10 }
            if node.isExcludedFromBook || node.isMissingFile { extra += 18 }
            if node.symbol != nil { extra += 20 }
            let width = max(56, textWidth + extra + paddingX * 2)
            let height = lineHeight * CGFloat(lines.count) + paddingY * 2
            result[node.id] = MindMapNodeMetrics(lines: lines, size: CGSize(width: width, height: height))
        }
        return result
    }

    // MARK: Дерево слева направо

    static func tree(_ tree: MindMapTree, collapsed: Set<Int>, measure: (String) -> CGSize) -> MindMapLayoutResult {
        self.tree(tree, collapsed: collapsed, metrics: metrics(for: tree.nodes, measure: measure))
    }

    static func tree(_ tree: MindMapTree, collapsed: Set<Int>, metrics: [Int: MindMapNodeMetrics]) -> MindMapLayoutResult {
        guard tree.node(tree.rootID) != nil else { return .empty }
        func children(_ id: Int) -> [Int] { collapsed.contains(id) ? [] : tree.nodes[id].childIDs }
        func size(_ id: Int) -> CGSize { metrics[id]?.size ?? CGSize(width: 56, height: 24) }

        var order: [(id: Int, depth: Int)] = []
        var stack = [(id: tree.rootID, depth: 0)]
        while let item = stack.popLast() {
            order.append(item)
            for child in children(item.id).reversed() { stack.append((child, item.depth + 1)) }
        }
        var columnWidth: [CGFloat] = []
        for item in order {
            if columnWidth.count <= item.depth { columnWidth.append(0) }
            columnWidth[item.depth] = max(columnWidth[item.depth], size(item.id).width)
        }
        var columnX: [CGFloat] = [margin]
        for depth in 1..<max(columnWidth.count, 1) { columnX.append(columnX[depth - 1] + columnWidth[depth - 1] + columnGap) }

        // Высота поддерева: не меньше самого узла и не меньше стопки детей.
        var slot: [Int: CGFloat] = [:]
        for item in order.reversed() {
            let kids = children(item.id)
            let stacked = kids.reduce(CGFloat(0)) { $0 + (slot[$1] ?? 0) } + CGFloat(max(0, kids.count - 1)) * rowGap
            slot[item.id] = max(size(item.id).height, stacked)
        }
        var top: [Int: CGFloat] = [tree.rootID: margin]
        for item in order {
            let kids = children(item.id)
            guard !kids.isEmpty else { continue }
            let stacked = kids.reduce(CGFloat(0)) { $0 + (slot[$1] ?? 0) } + CGFloat(kids.count - 1) * rowGap
            var y = (top[item.id] ?? margin) + ((slot[item.id] ?? 0) - stacked) / 2
            for kid in kids {
                top[kid] = y
                y += (slot[kid] ?? 0) + rowGap
            }
        }
        // Родитель по центру своих детей, но не выходит за свой отрезок: перекрытий нет.
        var centerY: [Int: CGFloat] = [:]
        for item in order.reversed() {
            let own = size(item.id).height
            let upper = top[item.id] ?? margin
            let lower = upper + (slot[item.id] ?? own)
            var center = upper + (slot[item.id] ?? own) / 2
            let kids = children(item.id)
            if let first = kids.first, let last = kids.last, let a = centerY[first], let b = centerY[last] { center = (a + b) / 2 }
            centerY[item.id] = min(max(center, upper + own / 2), lower - own / 2)
        }
        var placed: [Int: MindMapPlacedNode] = [:]
        var right: CGFloat = 0
        var bottom: CGFloat = 0
        for item in order {
            let box = size(item.id)
            let frame = CGRect(x: columnX[item.depth], y: (centerY[item.id] ?? margin) - box.height / 2, width: box.width, height: box.height)
            placed[item.id] = MindMapPlacedNode(id: item.id, frame: frame, lines: metrics[item.id]?.lines ?? [])
            right = max(right, frame.maxX)
            bottom = max(bottom, frame.maxY)
        }
        return MindMapLayoutResult(placed: placed, size: CGSize(width: right + margin, height: max(bottom, (top[tree.rootID] ?? margin) + (slot[tree.rootID] ?? 0)) + margin))
    }

    // MARK: Радиальная

    static func radial(_ tree: MindMapTree, collapsed: Set<Int>, measure: (String) -> CGSize) -> MindMapLayoutResult {
        radial(tree, collapsed: collapsed, metrics: metrics(for: tree.nodes, measure: measure))
    }

    static func radial(_ tree: MindMapTree, collapsed: Set<Int>, metrics: [Int: MindMapNodeMetrics]) -> MindMapLayoutResult {
        guard tree.node(tree.rootID) != nil else { return .empty }
        func children(_ id: Int) -> [Int] { collapsed.contains(id) ? [] : tree.nodes[id].childIDs }
        func size(_ id: Int) -> CGSize { metrics[id]?.size ?? CGSize(width: 56, height: 24) }

        var order: [(id: Int, depth: Int)] = []
        var stack = [(id: tree.rootID, depth: 0)]
        while let item = stack.popLast() {
            order.append(item)
            for child in children(item.id).reversed() { stack.append((child, item.depth + 1)) }
        }
        var leaves: [Int: Int] = [:]
        for item in order.reversed() {
            let kids = children(item.id)
            leaves[item.id] = kids.isEmpty ? 1 : kids.reduce(0) { $0 + (leaves[$1] ?? 1) }
        }
        // Сектор узла пропорционален числу листьев его поддерева.
        var sector: [Int: (start: Double, end: Double)] = [tree.rootID: (-Double.pi / 2, Double.pi * 1.5)]
        for item in order {
            guard let range = sector[item.id] else { continue }
            let kids = children(item.id)
            var cursor = range.start
            let total = Double(leaves[item.id] ?? 1)
            for kid in kids {
                let span = (range.end - range.start) * Double(leaves[kid] ?? 1) / total
                sector[kid] = (cursor, cursor + span)
                cursor += span
            }
        }
        let depths = (order.map(\.depth).max() ?? 0) + 1
        var diagonal = [Double](repeating: 0, count: depths)
        var angles = [[Double]](repeating: [], count: depths)
        for item in order {
            let box = size(item.id)
            diagonal[item.depth] = max(diagonal[item.depth], Double(hypot(box.width, box.height)))
            if let range = sector[item.id] { angles[item.depth].append((range.start + range.end) / 2) }
        }
        let gap = 24.0
        var radius = [Double](repeating: 0, count: depths)
        for depth in 1..<max(depths, 1) {
            var value = radius[depth - 1] + (diagonal[depth - 1] + diagonal[depth]) / 2 + gap
            let ring = angles[depth]
            if ring.count > 1 {
                var smallest = ring[0] + 2 * Double.pi - ring[ring.count - 1]
                for index in 1..<ring.count { smallest = min(smallest, ring[index] - ring[index - 1]) }
                smallest = min(max(smallest, 0.0001), Double.pi)
                value = max(value, (diagonal[depth] + gap) / (2 * sin(smallest / 2)))
            }
            radius[depth] = min(value, 20_000)
        }
        var ids: [Int] = []
        var rects: [CGRect] = []
        for item in order {
            let box = size(item.id)
            let angle = item.depth == 0 ? 0 : ((sector[item.id].map { ($0.start + $0.end) / 2 }) ?? 0)
            let center = CGPoint(x: radius[item.depth] * cos(angle), y: radius[item.depth] * sin(angle))
            ids.append(item.id)
            rects.append(CGRect(x: center.x - box.width / 2, y: center.y - box.height / 2, width: box.width, height: box.height))
        }
        resolveOverlaps(&rects)
        return finish(ids: ids, rects: rects, metrics: metrics)
    }

    // MARK: Связи (физическая раскладка Фрюхтермана–Рейнгольда)

    static func graph(_ graph: MindMapGraph, measure: (String) -> CGSize) -> MindMapLayoutResult {
        self.graph(graph, metrics: metrics(for: graph.nodes, measure: measure))
    }

    /// Узлы отталкиваются, связи стягивают. Без случайных чисел: начальные позиции — по кругу в порядке ключей.
    static func graph(_ graph: MindMapGraph, metrics: [Int: MindMapNodeMetrics]) -> MindMapLayoutResult {
        let count = graph.nodes.count
        guard count > 0 else { return .empty }
        func size(_ id: Int) -> CGSize { metrics[id]?.size ?? CGSize(width: 56, height: 24) }
        let ids = graph.nodes.map(\.id)
        var diagonalMax = 0.0
        for id in ids { diagonalMax = max(diagonalMax, Double(hypot(size(id).width, size(id).height))) }
        let k = diagonalMax + 60
        var xs = [Double](repeating: 0, count: count)
        var ys = [Double](repeating: 0, count: count)
        let byKey = ids.indices.sorted { graph.nodes[$0].key != graph.nodes[$1].key ? graph.nodes[$0].key < graph.nodes[$1].key : $0 < $1 }
        let ring = max(k, k * Double(count) / (2 * Double.pi))
        for (place, index) in byKey.enumerated() {
            let angle = 2 * Double.pi * Double(place) / Double(count)
            xs[index] = ring * cos(angle)
            ys[index] = ring * sin(angle)
        }
        let indexOfID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let links: [(Int, Int, Double)] = graph.edges.compactMap { edge in
            guard let a = indexOfID[edge.from], let b = indexOfID[edge.to], a != b else { return nil }
            return (a, b, sqrt(Double(min(max(edge.weight, 1), 9))))
        }
        let iterations = count > 300 ? 80 : 200
        let startTemperature = ring / 4
        for step in 0..<iterations {
            var dx = [Double](repeating: 0, count: count)
            var dy = [Double](repeating: 0, count: count)
            for i in 0..<count {
                for j in (i + 1)..<count where j < count {
                    var deltaX = xs[i] - xs[j], deltaY = ys[i] - ys[j]
                    var distance = hypot(deltaX, deltaY)
                    if distance < 0.01 {
                        deltaX = Double(i - j) * 0.01
                        deltaY = 0.01
                        distance = hypot(deltaX, deltaY)
                    }
                    let push = k * k / distance
                    dx[i] += deltaX / distance * push
                    dy[i] += deltaY / distance * push
                    dx[j] -= deltaX / distance * push
                    dy[j] -= deltaY / distance * push
                }
            }
            for (a, b, weight) in links {
                let deltaX = xs[a] - xs[b], deltaY = ys[a] - ys[b]
                let distance = max(hypot(deltaX, deltaY), 0.01)
                let pull = distance * distance / k * weight
                dx[a] -= deltaX / distance * pull
                dy[a] -= deltaY / distance * pull
                dx[b] += deltaX / distance * pull
                dy[b] += deltaY / distance * pull
            }
            let temperature = startTemperature * (1 - Double(step) / Double(iterations))
            for i in 0..<count {
                dx[i] -= xs[i] * 0.05
                dy[i] -= ys[i] * 0.05
                let length = max(hypot(dx[i], dy[i]), 0.0001)
                let move = min(length, temperature)
                xs[i] += dx[i] / length * move
                ys[i] += dy[i] / length * move
            }
        }
        var rects: [CGRect] = ids.indices.map { index in
            let box = size(ids[index])
            return CGRect(x: xs[index] - box.width / 2, y: ys[index] - box.height / 2, width: box.width, height: box.height)
        }
        resolveOverlaps(&rects)
        return finish(ids: ids, rects: rects, metrics: metrics)
    }

    // MARK: Общее

    /// Раздвигает перекрывшиеся рамки вдоль оси с меньшим перекрытием. Порядок обхода фиксирован: результат детерминирован.
    static func resolveOverlaps(_ rects: inout [CGRect], iterations: Int = 40) {
        let count = rects.count
        guard count > 1 else { return }
        for _ in 0..<iterations {
            var moved = false
            let order = (0..<count).sorted { rects[$0].minX != rects[$1].minX ? rects[$0].minX < rects[$1].minX : $0 < $1 }
            for first in 0..<count {
                for second in (first + 1)..<count where second < count {
                    let i = order[first], j = order[second]
                    if rects[j].minX >= rects[i].maxX { break }
                    let overlapX = min(rects[i].maxX, rects[j].maxX) - max(rects[i].minX, rects[j].minX)
                    let overlapY = min(rects[i].maxY, rects[j].maxY) - max(rects[i].minY, rects[j].minY)
                    guard overlapX > 0.5, overlapY > 0.5 else { continue }
                    moved = true
                    if overlapX < overlapY {
                        let shift = overlapX / 2 + 1
                        let sign: CGFloat = rects[i].midX <= rects[j].midX ? -1 : 1
                        rects[i].origin.x += sign * shift
                        rects[j].origin.x -= sign * shift
                    } else {
                        let shift = overlapY / 2 + 1
                        let sign: CGFloat = rects[i].midY <= rects[j].midY ? -1 : 1
                        rects[i].origin.y += sign * shift
                        rects[j].origin.y -= sign * shift
                    }
                }
            }
            if !moved { break }
        }
    }

    /// Сдвигает всё в положительную область и собирает результат.
    private static func finish(ids: [Int], rects: [CGRect], metrics: [Int: MindMapNodeMetrics]) -> MindMapLayoutResult {
        guard let first = rects.first else { return .empty }
        var minX = first.minX, minY = first.minY, maxX = first.maxX, maxY = first.maxY
        for rect in rects {
            minX = min(minX, rect.minX); minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX); maxY = max(maxY, rect.maxY)
        }
        var placed: [Int: MindMapPlacedNode] = [:]
        for (index, id) in ids.enumerated() {
            let frame = rects[index].offsetBy(dx: margin - minX, dy: margin - minY)
            placed[id] = MindMapPlacedNode(id: id, frame: frame, lines: metrics[id]?.lines ?? [])
        }
        return MindMapLayoutResult(placed: placed, size: CGSize(width: maxX - minX + margin * 2, height: maxY - minY + margin * 2))
    }
}
