import XCTest
@testable import LacEditor

final class MindMapLayoutTests: XCTestCase {
    private let measure: (String) -> CGSize = { CGSize(width: CGFloat($0.count) * 8, height: 16) }

    private func sampleTree() -> MindMapTree {
        MindMapDocumentParser.parse("# Root\n## A\n### A1\n### A2\n## B\n## C\n### C1\n", fallbackTitle: "Doc")
    }

    private func assertNoOverlaps(_ result: MindMapLayoutResult, file: StaticString = #filePath, line: UInt = #line) {
        let frames = result.placed.values.map(\.frame)
        for i in frames.indices {
            XCTAssertGreaterThanOrEqual(frames[i].minX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frames[i].minY, 0, file: file, line: line)
            for j in frames.indices where j > i {
                XCTAssertFalse(frames[i].intersects(frames[j]), file: file, line: line)
            }
        }
    }

    func testTreeLayoutHasNoOverlapsAndCentersParent() {
        let tree = sampleTree()
        let result = MindMapLayout.tree(tree, collapsed: [], measure: measure)
        XCTAssertEqual(result.placed.count, tree.nodes.count)
        assertNoOverlaps(result)
        let root = tree.node(tree.rootID)!
        let first = result.placed[root.childIDs.first!]!.frame
        let last = result.placed[root.childIDs.last!]!.frame
        XCTAssertEqual(result.placed[tree.rootID]!.frame.midY, (first.midY + last.midY) / 2, accuracy: 0.5)
    }

    func testCollapsedChildrenAreNotPlaced() {
        let tree = sampleTree()
        let a = tree.nodes.first { $0.title == "A" }!
        let result = MindMapLayout.tree(tree, collapsed: [a.id], measure: measure)
        for child in a.childIDs { XCTAssertNil(result.placed[child]) }
        XCTAssertNotNil(result.placed[a.id])
    }

    func testRadialLayoutHasNoOverlaps() {
        assertNoOverlaps(MindMapLayout.radial(sampleTree(), collapsed: [], measure: measure))
    }

    func testGraphLayoutIsDeterministic() {
        var nodes: [MindMapNode] = []
        for i in 0..<8 { nodes.append(MindMapNode(id: i, key: "k\(i)", title: "Card \(i)", level: 0, kind: .card, parentID: nil)) }
        let edges = (0..<7).map { MindMapEdge(from: $0, to: $0 + 1, style: .relation, weight: 1, label: nil) }
        let graph = MindMapGraph(nodes: nodes, edges: edges, hiddenNodeCount: 0)
        let first = MindMapLayout.graph(graph, measure: measure)
        let second = MindMapLayout.graph(graph, measure: measure)
        XCTAssertEqual(first, second)
        assertNoOverlaps(first)
    }

    func testWrapLimitsLinesAndWidth() {
        let text = String(repeating: "слово ", count: 80)
        let lines = MindMapLayout.wrap(text, maxWidth: 100, maxLines: 3, measure: measure)
        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertTrue(lines.last?.hasSuffix("…") == true)
        for line in lines { XCTAssertLessThanOrEqual(measure(line).width, 100 + 8) }
    }
}
