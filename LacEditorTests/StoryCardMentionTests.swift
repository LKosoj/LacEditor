import XCTest
@testable import LacEditor

final class StoryCardMentionTests: XCTestCase {
    private func card(_ title: String) -> StoryCard {
        StoryCard(url: URL(fileURLWithPath: "/r/\(title).md"), relativePath: "\(title).md", type: .character, cardID: nil,
                  title: title, aliases: [], relations: [], excludedFromAI: false)
    }

    func testIndexScenesCardsAndCoMentions() {
        let a = UUID(), b = UUID(), c = UUID()
        let index = StoryCardMentionIndex(byScene: [
            a: ["Anna.md": 3, "Boris.md": 1],
            b: ["Anna.md": 1],
            c: ["Anna.md": 2, "Boris.md": 2, "Cora.md": 1],
        ])
        XCTAssertEqual(index.scenes(ofCard: "Anna.md").map(\.nodeID), [a, c, b])
        XCTAssertEqual(index.cards(inScene: c), ["Anna.md", "Boris.md", "Cora.md"])
        let pairs = index.coMentions()
        XCTAssertEqual(pairs[StoryCardPair("Boris.md", "Anna.md")], 2)
        XCTAssertEqual(pairs[StoryCardPair("Anna.md", "Cora.md")], 1)
        XCTAssertNil(pairs[StoryCardPair("Anna.md", "Anna.md")])
    }

    func testPairIsOrdered() {
        XCTAssertEqual(StoryCardPair("b", "a"), StoryCardPair("a", "b"))
        XCTAssertEqual(StoryCardPair("b", "a").a, "a")
    }

    func testCardsInText() {
        let matcher = StoryCardMatcher(cards: [card("Anna"), card("Boris")])
        XCTAssertEqual(StoryCardMentionService.cards(in: "Anna met Anna.", matcher: matcher), ["Anna.md": 2])
    }

    func testCandidatesExcludeKnownAndNeedRepeats() {
        let text = "Zorgon came. Then Zorgon left, and later Zorgon returned. Anna waved. Anna smiled. Anna sat."
        let found = StoryCardCandidateFinder.find(in: text, known: [card("Anna")])
        XCTAssertFalse(found.contains { $0.name == "Anna" })
        XCTAssertTrue(found.allSatisfy { $0.occurrences >= StoryCardCandidateFinder.minOccurrences })
    }

    func testCandidateFormsOfOneNameAreGrouped() {
        let text = "We met. Then Zorgon came. Later Zorgon left. Soon Zorgon returned. Zorgons horn sounded."
        let found = StoryCardCandidateFinder.find(in: text, known: [])
        XCTAssertLessThanOrEqual(found.filter { $0.name.hasPrefix("Zorgon") }.count, 1)
    }

    func testIndexIsCompleteByDefault() {
        XCTAssertTrue(StoryCardMentionIndex(byScene: [:]).isComplete)
    }

    func testChineseTextGivesNoLocalCandidates() {
        XCTAssertTrue(StoryCardCandidateFinder.find(in: "李明去了北京。李明回来了。李明笑了。", known: []).isEmpty)
    }
}
