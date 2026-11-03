import XCTest
@testable import LacEditor

final class StoryCardAIServiceTests: XCTestCase {
    private func card(_ title: String, excluded: Bool = false, aliases: [String] = []) -> StoryCard {
        StoryCard(url: URL(fileURLWithPath: "/r/\(title).md"), relativePath: "\(title).md", type: .character, cardID: nil,
                  title: title, aliases: aliases, relations: [], excludedFromAI: excluded)
    }

    private let text = "Anna met Boris at the harbor. Boris smiled. The harbor was cold."

    func testCandidatesRequireUniqueLiteralQuote() throws {
        let response = """
        {"cards":[
          {"name":"Boris","type":"character","quote":"Anna met Boris"},
          {"name":"harbor","type":"place","quote":"harbor"},
          {"name":"Cora","type":"character","quote":"Cora is absent"},
          {"name":"Anna","type":"character","quote":"Anna met"}
        ]}
        """
        let parsed = try StoryCardAIService.parseCandidates(response: response, text: text, known: [card("Anna")])
        XCTAssertEqual(parsed.items.map(\.name), ["Boris"])
        XCTAssertEqual(parsed.skipped, 3)
        XCTAssertTrue(parsed.items[0].fromAI)
    }

    func testRelationsOnlyToKnownCards() throws {
        let response = "```json\n{\"relations\":[{\"to\":\"boris\",\"kind\":\"friend\",\"quote\":\"Anna met Boris\"},{\"to\":\"Nobody\",\"kind\":\"x\",\"quote\":\"Anna met Boris\"}]}\n```"
        let parsed = try StoryCardAIService.parseRelations(response: response, text: text, subject: card("Anna"), known: [card("Anna"), card("Boris"), card("Secret", excluded: true)])
        XCTAssertEqual(parsed.items.map(\.targetTitle), ["Boris"])
        XCTAssertEqual(parsed.skipped, 1)
    }

    func testFactsNeedUniqueQuote() throws {
        let response = "{\"facts\":[{\"fact\":\"Boris smiles\",\"quote\":\"Boris smiled\"},{\"fact\":\"x\",\"quote\":\"Boris\"}]}"
        let parsed = try StoryCardAIService.parseFacts(response: response, text: text)
        XCTAssertEqual(parsed.items.map(\.fact), ["Boris smiles"])
        XCTAssertEqual(parsed.skipped, 1)
    }

    func testLimitAndInvalidResponse() throws {
        let many = (0..<80).map { "{\"fact\":\"f\($0)\",\"quote\":\"Boris smiled\"}" }.joined(separator: ",")
        let parsed = try StoryCardAIService.parseFacts(response: "{\"facts\":[\(many)]}", text: text)
        XCTAssertEqual(parsed.items.count, StoryCardAIService.maxItems)
        XCTAssertEqual(parsed.skipped, 30)
        XCTAssertThrowsError(try StoryCardAIService.parseFacts(response: "not json", text: text))
    }

    func testExcludedCardsNeverEnterInput() {
        let cards = [card("Anna"), card("Secret", excluded: true, aliases: ["Hidden"])]
        let candidates = StoryCardAIService.candidatesInput(text: text, known: cards)
        XCTAssertTrue(candidates.contains("Anna"))
        XCTAssertFalse(candidates.contains("Secret"))
        XCTAssertFalse(candidates.contains("Hidden"))
        let relations = StoryCardAIService.relationsInput(subject: cards[0], known: cards, text: text)
        XCTAssertFalse(relations.contains("Secret"))
    }
}
