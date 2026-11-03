import XCTest
@testable import LacEditor

final class WriterBoardModelTests: XCTestCase {
    private func makeProject() -> (ManuscriptProject, [UUID]) {
        let a = ManuscriptNode(kind: .text, title: "A", path: "a.md", status: "Draft", synopsis: "sa", tags: ["x"])
        let b = ManuscriptNode(kind: .text, title: "B", path: "b.md", tags: ["y"])
        let c = ManuscriptNode(kind: .text, title: "C", path: "c.md", status: "Done")
        let g = ManuscriptNode(kind: .group, title: "G", children: [c])
        return (ManuscriptProject(title: "P", nodes: [a, b, g]), [a.id, b.id, g.id, c.id])
    }

    func testCardsAndGroupWordSum() {
        let (project, ids) = makeProject()
        let cards = BoardModel.cards(project: project, container: nil, counts: [ids[0]: 10, ids[3]: 5], missing: [ids[1]])
        XCTAssertEqual(cards.map(\.title), ["A", "B", "G"])
        XCTAssertEqual(cards[0].wordCount, 10)
        XCTAssertTrue(cards[1].isMissingFile)
        XCTAssertEqual(cards[2].wordCount, 5)
        XCTAssertEqual(cards[2].sceneCount, 1)
    }

    func testFilterKeepsGroups() {
        let (project, ids) = makeProject()
        let cards = BoardModel.cards(project: project, container: nil, counts: [:], missing: [])
        XCTAssertEqual(cards.filter(BoardFilter(status: "Draft").matches).map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(cards.filter(BoardFilter(status: "").matches).map(\.id), [ids[1], ids[2]])
        XCTAssertEqual(cards.filter(BoardFilter(tag: "y").matches).map(\.id), [ids[1], ids[2]])
        XCTAssertEqual(BoardModel.availableTags(in: cards), ["x", "y"])
    }

    func testTargetIndexAndNeighbor() {
        let ids = (0..<4).map { _ in UUID() }
        XCTAssertEqual(BoardOrdering.targetIndex(fullIDs: ids, moving: ids[0], relativeTo: ids[2], placeAfter: true), 2)
        XCTAssertEqual(BoardOrdering.targetIndex(fullIDs: ids, moving: ids[3], relativeTo: ids[1], placeAfter: false), 1)
        XCTAssertNil(BoardOrdering.targetIndex(fullIDs: ids, moving: ids[0], relativeTo: ids[0], placeAfter: true))
        XCTAssertEqual(BoardOrdering.neighbor(visibleIDs: ids, of: ids[1], step: 1), ids[2])
        XCTAssertNil(BoardOrdering.neighbor(visibleIDs: ids, of: ids[0], step: -1))
    }
}
