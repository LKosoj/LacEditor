import XCTest
@testable import LacEditor

final class MindMapLinksTests: XCTestCase {
    private func card(_ title: String, aliases: [String] = [], relations: [StoryCardRelation] = [], exclude: Bool = false) -> StoryCard {
        StoryCard(url: URL(fileURLWithPath: "/tmp/world/\(title).md"), relativePath: "world/\(title).md", type: .character,
                  cardID: UUID(), title: title, aliases: aliases, relations: relations, excludedFromAI: exclude)
    }

    private func build(_ cards: [StoryCard], co: [StoryCardPair: Int] = [:], wiki: [String: [String]] = [:],
                       min: Int = 2, limit: Int = 150) -> MindMapGraph {
        MindMapLinksBuilder.build(cards: cards, resolve: { ref in
            cards.first { $0.allNames.contains { $0.lowercased() == ref.lowercased() } }
        }, coMentions: co, wikiLinks: wiki, minSharedScenes: min, limit: limit)
    }

    func testRelationEdgeAndUnresolved() {
        let cards = [card("Анна", relations: [StoryCardRelation(to: "Борис", kind: "друг"), StoryCardRelation(to: "Нет", kind: "враг")]),
                     card("Борис")]
        let graph = build(cards)
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges.first?.style, .relation)
        XCTAssertEqual(graph.edges.first?.label, "друг")
        XCTAssertEqual(graph.unresolved.map(\.reference), ["Нет"])
    }

    func testCoMentionThreshold() {
        let cards = [card("Alice"), card("Bob"), card("林")]
        let co = [StoryCardPair(cards[0].id, cards[1].id): 3, StoryCardPair(cards[1].id, cards[2].id): 1]
        let graph = build(cards, co: co, min: 2)
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges.first?.style, .coMention)
        XCTAssertEqual(graph.edges.first?.weight, 3)
    }

    func testWikiLinkByAliasAndPairPriority() {
        let cards = [card("Alice", relations: [StoryCardRelation(to: "Bob", kind: "")]), card("Bob", aliases: ["Боб"])]
        let wiki = [cards[0].id: ["Боб"]]
        let graph = build(cards, wiki: wiki)
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges.first?.style, .relation)
        XCTAssertTrue(graph.edges.first?.alsoStyles.contains(.wikiLink) == true)
    }

    func testLimitHidesCards() {
        let cards = (0..<10).map { card("C\($0)") }
        let graph = build(cards, limit: 4)
        XCTAssertEqual(graph.nodes.count, 4)
        XCTAssertEqual(graph.hiddenNodeCount, 6)
    }

    func testExcludedCardStaysInGraph() {
        let graph = build([card("Secret", exclude: true), card("Open")])
        XCTAssertEqual(graph.nodes.count, 2)
    }

    // MARK: Карта проекта

    func testProjectBuilder() {
        let scene = ManuscriptNode(id: UUID(), kind: .text, title: "Сцена 1", path: "s1.md", include: false, status: "草稿", children: [])
        let lost = ManuscriptNode(id: UUID(), kind: .text, title: "Lost", path: "s2.md", include: true, status: nil, children: [])
        let group = ManuscriptNode(id: UUID(), kind: .group, title: "Part", path: nil, include: true, status: nil, children: [scene, lost])
        let project = ManuscriptProject(title: "Book", nodes: [group])
        let tree = MindMapProjectBuilder.build(project: project, wordCounts: [scene.id: 120], missing: [lost.id])
        XCTAssertEqual(tree.nodes.map(\.title), ["Book", "Part", "Сцена 1", "Lost"])
        XCTAssertEqual(tree.nodes[1].wordCount, 120)
        XCTAssertTrue(tree.nodes[2].isExcludedFromBook)
        XCTAssertEqual(tree.nodes[2].statusTitle, "草稿")
        XCTAssertTrue(tree.nodes[3].isMissingFile)
    }
}
