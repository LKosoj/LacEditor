import XCTest
@testable import LacEditor

final class StoryCardHeaderEditorTests: XCTestCase {
    private let fixedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func apply(_ edit: StoryCardHeaderEdit, to text: String) throws -> String {
        let patch = try StoryCardHeaderEditor.patch(for: edit, in: text, newID: { self.fixedID })
        return (text as NSString).replacingCharacters(in: patch.range, with: patch.replacement)
    }

    private let sample = "---\ntype: character\n# keep this comment\ncustom: value\naliases:\n  - Annie\n---\n\n# Anna\nBody\n"

    func testAddAliasKeepsUnknownFieldsCommentsAndBody() throws {
        let result = try apply(.addAlias("Ann"), to: sample)
        XCTAssertTrue(result.contains("# keep this comment"))
        XCTAssertTrue(result.contains("custom: value"))
        XCTAssertTrue(result.hasSuffix("# Anna\nBody\n"))
        let card = try XCTUnwrap(StoryCardHeader.parse(result, url: URL(fileURLWithPath: "/r/a.md"), root: URL(fileURLWithPath: "/r")))
        XCTAssertEqual(card.aliases, ["Annie", "Ann"])
    }

    func testFirstEditAddsID() throws {
        let patch = try StoryCardHeaderEditor.patch(for: .addAlias("Ann"), in: sample, newID: { self.fixedID })
        XCTAssertEqual(patch.addedID, fixedID)
        let result = (sample as NSString).replacingCharacters(in: patch.range, with: patch.replacement)
        XCTAssertTrue(result.contains("id: \(fixedID.uuidString)"))
    }

    func testIDIsNotChangedWhenPresent() throws {
        let text = "---\ntype: character\nid: \(fixedID.uuidString)\n---\n# A\n"
        let patch = try StoryCardHeaderEditor.patch(for: .setType(.place), in: text, newID: { UUID() })
        XCTAssertNil(patch.addedID)
        let result = (text as NSString).replacingCharacters(in: patch.range, with: patch.replacement)
        XCTAssertTrue(result.contains("type: place"))
        XCTAssertTrue(result.contains(fixedID.uuidString))
    }

    func testRemoveAliasAndDuplicateAlias() throws {
        let removed = try apply(.removeAlias("Annie"), to: sample)
        XCTAssertFalse(removed.contains("Annie"))
        XCTAssertThrowsError(try apply(.addAlias("annie"), to: sample)) {
            XCTAssertEqual($0 as? StoryCardHeaderEditError, .duplicateAlias)
        }
        XCTAssertThrowsError(try apply(.addAlias("  "), to: sample)) {
            XCTAssertEqual($0 as? StoryCardHeaderEditError, .emptyValue)
        }
    }

    func testRelationsAddAndRemove() throws {
        let relation = StoryCardRelation(to: "Boris: the \"Bear\"", kind: "friend")
        let added = try apply(.addRelation(relation), to: sample)
        let url = URL(fileURLWithPath: "/r/a.md"), root = URL(fileURLWithPath: "/r")
        XCTAssertEqual(StoryCardHeader.parse(added, url: url, root: root)?.relations, [relation])
        let removed = try apply(.removeRelation(relation), to: added)
        XCTAssertEqual(StoryCardHeader.parse(removed, url: url, root: root)?.relations, [])
    }

    func testRefusesFlowHeaderAndMissingHeader() {
        XCTAssertThrowsError(try apply(.addAlias("x"), to: "# no header\n")) {
            XCTAssertEqual($0 as? StoryCardHeaderEditError, .noHeader)
        }
        XCTAssertThrowsError(try apply(.addRelation(StoryCardRelation(to: "B", kind: "")), to: "---\ntype: character\nrelations: [{to: A}]\n---\n")) {
            XCTAssertEqual($0 as? StoryCardHeaderEditError, .flowStyle)
        }
    }

    func testPreservesCRLF() throws {
        let text = "---\r\ntype: character\r\n---\r\n# A\r\n"
        let result = try apply(.addAlias("Al"), to: text)
        XCTAssertFalse(result.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testBatchRelationsAreOnePatchWithoutDuplicates() throws {
        let one = StoryCardRelation(to: "Boris.md", kind: "friend")
        let two = StoryCardRelation(to: "Clara.md", kind: "rival")
        let patch = try XCTUnwrap(StoryCardHeaderEditor.patch(for: [.addRelation(one), .addRelation(two), .addRelation(one)],
                                                              in: sample, newID: { self.fixedID }))
        let result = (sample as NSString).replacingCharacters(in: patch.range, with: patch.replacement)
        let card = try XCTUnwrap(StoryCardHeader.parse(result, url: URL(fileURLWithPath: "/r/a.md"), root: URL(fileURLWithPath: "/r")))
        XCTAssertEqual(card.relations, [one, two])
        XCTAssertTrue(result.contains("# keep this comment"))
        XCTAssertEqual(patch.addedID, fixedID)
        // Повтор уже записанных связей ничего не меняет.
        XCTAssertNil(try StoryCardHeaderEditor.patch(for: [.addRelation(one), .addRelation(two)], in: result, newID: { UUID() }))
    }

    func testQuotedValues() {
        XCTAssertEqual(StoryCardHeaderEditor.quoted("Anna"), "Anna")
        XCTAssertEqual(StoryCardHeaderEditor.quoted("yes"), "\"yes\"")
        XCTAssertEqual(StoryCardHeaderEditor.quoted("a: b"), "\"a: b\"")
        XCTAssertEqual(StoryCardHeaderEditor.quoted("12"), "\"12\"")
    }
}
