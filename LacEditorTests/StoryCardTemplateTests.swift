import XCTest
@testable import LacEditor

final class StoryCardTemplateTests: XCTestCase {
    func testSkeletonsAreCardsWithoutID() throws {
        let root = URL(fileURLWithPath: "/r")
        for type in StoryCardType.allCases {
            let text = NoteTemplateService.render(StoryCardTemplates.skeleton(for: type), title: "Name", date: Date())
            let card = try XCTUnwrap(StoryCardHeader.parse(text, url: root.appendingPathComponent("Name.md"), root: root))
            XCTAssertEqual(card.type, type)
            XCTAssertEqual(card.title, "Name")
            XCTAssertNil(card.cardID)
        }
    }

    func testInstallDoesNotOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StoryCardTemplateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent(StoryCardTemplates.fileName(for: .character))
        try "mine".write(to: existing, atomically: true, encoding: .utf8)
        XCTAssertEqual(try StoryCardTemplates.installTemplates(into: folder), StoryCardType.allCases.count - 1)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "mine")
        XCTAssertEqual(try StoryCardTemplates.installTemplates(into: folder), 0)
    }

    func testFactsAreAddedToExistingSection() throws {
        let text = "---\ntype: character\n---\n# A\n\n## Facts\n- one\n\n## Other\ntext\n"
        let insertion = try XCTUnwrap(StoryCardFactsWriter.insertion(adding: ["two"], to: text))
        let result = (text as NSString).replacingCharacters(in: insertion.range, with: insertion.replacement)
        XCTAssertEqual(result, "---\ntype: character\n---\n# A\n\n## Facts\n- one\n- two\n\n## Other\ntext\n")
    }

    func testFactsCreateSectionAtEnd() throws {
        let text = "---\ntype: character\n---\n# A\nbody\n"
        let insertion = try XCTUnwrap(StoryCardFactsWriter.insertion(adding: ["one", "two"], to: text))
        XCTAssertEqual(insertion.range, NSRange(location: (text as NSString).length, length: 0))
        XCTAssertTrue(insertion.replacement.contains("- one\n- two\n"))
        XCTAssertTrue(insertion.replacement.hasPrefix("\n## "))
        XCTAssertNil(StoryCardFactsWriter.insertion(adding: ["  "], to: text))
    }
}
