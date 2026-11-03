import XCTest
@testable import LacEditor

final class StoryCardTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    private func card(_ text: String, name: String = "Anna.md") -> StoryCard? {
        StoryCardHeader.parse(text, url: root.appendingPathComponent("World/\(name)"), root: root)
    }

    func testParsesHeaderInThreeLanguages() throws {
        let en = try XCTUnwrap(card("---\ntype: character\naliases: [Annie]\n---\n\n# Anna Reed\n"))
        XCTAssertEqual(en.type, .character)
        XCTAssertEqual(en.title, "Anna Reed")
        XCTAssertEqual(en.aliases, ["Annie"])
        let ru = try XCTUnwrap(card("---\ntype: Place\naliases:\n  - Город\n---\n# Москва\n"))
        XCTAssertEqual(ru.type, .place)
        XCTAssertEqual(ru.allNames, ["Москва", "Город"])
        let zh = try XCTUnwrap(card("---\ntype: organization\n---\n# 青云门\n"))
        XCTAssertEqual(zh.title, "青云门")
    }

    func testNotACardWithoutKnownType() {
        XCTAssertNil(card("# Anna\n"))
        XCTAssertNil(card("---\ntitle: x\n---\n# Anna\n"))
        XCTAssertNil(card("---\ntype: dragon\n---\n# Anna\n"))
    }

    func testIDExcludeAndRelations() throws {
        let id = UUID()
        let parsed = try XCTUnwrap(card("---\ntype: character\nid: \(id.uuidString)\nai: exclude\nrelations:\n  - to: Boris\n    kind: friend\n  - kind: nobody\n---\n# Anna\n"))
        XCTAssertEqual(parsed.cardID, id)
        XCTAssertEqual(parsed.id, id.uuidString)
        XCTAssertTrue(parsed.excludedFromAI)
        XCTAssertEqual(parsed.relations, [StoryCardRelation(to: "Boris", kind: "friend")])
    }

    func testTitleFallsBackToFileNameAndSkipsCodeHeadings() throws {
        let parsed = try XCTUnwrap(card("---\ntype: item\n---\n```\n# Not a title\n```\n", name: "Sword.md"))
        XCTAssertEqual(parsed.title, "Sword")
    }

    func testProseRangesSkipHeaderAndCode() {
        let text = "---\ntype: item\n---\nOne\n```\ncode\n```\nTwo\n"
        let ns = text as NSString
        let prose = StoryCardText.proseRanges(in: text).map { ns.substring(with: $0) }.joined()
        XCTAssertTrue(prose.contains("One"))
        XCTAssertTrue(prose.contains("Two"))
        XCTAssertFalse(prose.contains("code"))
        XCTAssertFalse(prose.contains("type: item"))
    }
}
