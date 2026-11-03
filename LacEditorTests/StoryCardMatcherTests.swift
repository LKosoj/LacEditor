import XCTest
@testable import LacEditor

final class StoryCardMatcherTests: XCTestCase {
    private func card(_ title: String, aliases: [String] = [], type: StoryCardType = .character) -> StoryCard {
        StoryCard(url: URL(fileURLWithPath: "/r/\(title).md"), relativePath: "\(title).md", type: type, cardID: nil,
                  title: title, aliases: aliases, relations: [], excludedFromAI: false)
    }

    func testEnglishNameWithAliasAndCapitalRule() {
        let matcher = StoryCardMatcher(cards: [card("Anna Reed", aliases: ["Annie"])])
        XCTAssertEqual(matcher.counts(in: "Annie smiled. Anna Reed left. anna reed?")["Anna Reed.md"], 2)
    }

    func testRussianWordFormsAndCapitalRule() {
        let matcher = StoryCardMatcher(cards: [card("Вера")])
        let counts = matcher.counts(in: "Он увидел Веру. Вере стало легче. Это вера в чудо.")
        XCTAssertEqual(counts["Вера.md"], 2)
    }

    func testChineseLiteralMatch() {
        let matcher = StoryCardMatcher(cards: [card("青云门", type: .organization)])
        XCTAssertEqual(matcher.counts(in: "他加入了青云门，青云门很大。")["青云门.md"], 2)
    }

    func testLongestMatchWins() {
        let matcher = StoryCardMatcher(cards: [card("Anna"), card("Anna Reed")])
        let counts = matcher.counts(in: "Anna Reed came.")
        XCTAssertEqual(counts["Anna Reed.md"], 1)
        XCTAssertNil(counts["Anna.md"])
    }

    func testSkipsHeaderAndCode() {
        let matcher = StoryCardMatcher(cards: [card("Anna")])
        let text = "---\ntype: character\naliases: [Anna]\n---\n```\nAnna\n```\nAnna here.\n"
        XCTAssertEqual(matcher.counts(in: text)["Anna.md"], 1)
    }

    func testStopWordNamesAndShortNamesAreIgnored() {
        let matcher = StoryCardMatcher(cards: [card("The"), card("A")])
        XCTAssertTrue(matcher.counts(in: "The cat and A dog.").isEmpty)
    }

    func testRangesAreUTF16() {
        let matcher = StoryCardMatcher(cards: [card("Anna")])
        let text = "😀 Anna"
        let mention = matcher.mentions(in: text).first
        XCTAssertEqual(mention.map { (text as NSString).substring(with: $0.range) }, "Anna")
    }
}
