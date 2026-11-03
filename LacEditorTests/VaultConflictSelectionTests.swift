import XCTest
@testable import LacEditor

final class VaultConflictSelectionTests: XCTestCase {
    /// Два конфликтных куска: строки 2 и 4 изменены и здесь, и на сервере.
    private func twoPieces() throws -> VaultConflictSelection {
        let base = "a\nb\nc\nd\ne\n"
        let mine = "a\nB1\nc\nD1\ne\n"
        let server = "a\nB2\nc\nD2\ne\n"
        guard case .conflict(let conflict) = VaultMerge.merge(base: base, mine: mine, server: server) else {
            XCTFail("ожидался конфликт")
            throw CancellationError()
        }
        return VaultConflictSelection(conflict: conflict)
    }

    func testCompleteOnlyWhenAllChosen() throws {
        var selection = try twoPieces()
        XCTAssertEqual(selection.total, 2)
        XCTAssertFalse(selection.isComplete)
        XCTAssertNil(selection.resolvedText)
        let ids = selection.conflictIDs
        selection.choose(.mine, for: ids[0])
        XCTAssertFalse(selection.isComplete)
        XCTAssertEqual(selection.nextUnresolved(after: ids[0]), ids[1])
        selection.choose(.server, for: ids[1])
        XCTAssertTrue(selection.isComplete)
        XCTAssertEqual(selection.resolvedText, "a\nB1\nc\nD2\ne\n")
        XCTAssertNil(selection.nextUnresolved(after: nil))
    }

    func testBothIsOfferedOnlyForPureAdditions() throws {
        let selection = try twoPieces()
        XCTAssertEqual(selection.availableSides(for: selection.conflictIDs[0]), [.mine, .server])
        var copy = selection
        copy.choose(.both, for: selection.conflictIDs[0])
        XCTAssertNil(copy.choice(for: selection.conflictIDs[0]))
    }

    func testStepAndNavigationDoNotWrap() throws {
        var selection = try twoPieces()
        let ids = selection.conflictIDs
        selection.step(-1, from: ids[0])
        XCTAssertEqual(selection.choice(for: ids[0]), .mine)
        selection.step(1, from: ids[0])
        XCTAssertEqual(selection.choice(for: ids[0]), .server)
        selection.step(1, from: ids[0])
        XCTAssertEqual(selection.choice(for: ids[0]), .server)
        XCTAssertEqual(selection.next(after: nil), ids[0])
        XCTAssertEqual(selection.next(after: ids[0]), ids[1])
        XCTAssertNil(selection.next(after: ids[1]))
        XCTAssertNil(selection.previous(before: ids[0]))
        XCTAssertEqual(selection.previous(before: ids[1]), ids[0])
    }

    func testLineRanges() throws {
        let selection = try twoPieces()
        XCTAssertEqual(selection.lineRange(of: selection.conflictIDs[0], side: .mine), 2...2)
        XCTAssertEqual(selection.lineRange(of: selection.conflictIDs[1], side: .server), 4...4)
        XCTAssertEqual(VaultConflictSelection.lineCount("x\ny\n"), 2)
        XCTAssertEqual(VaultConflictSelection.lineCount("x\ny"), 2)
        XCTAssertEqual(VaultConflictSelection.lineCount(""), 0)
    }
}
