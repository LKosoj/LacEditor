import XCTest
@testable import LacEditor

final class VaultUnsentSummaryTests: XCTestCase {
    private func record(_ path: String, _ state: VaultNoteSyncState, at second: Double? = nil,
                        open: Bool = true, issue: VaultUploadIssue? = nil) -> VaultOpenNoteRecord {
        VaultOpenNoteRecord(serverPath: path, baseETag: "e", state: state,
                            queuedAt: second.map { Date(timeIntervalSince1970: $0) }, isOpenInTab: open, uploadIssue: issue)
    }

    private func summary(_ records: [VaultOpenNoteRecord], online: Bool = true) -> VaultUnsentSummary {
        VaultUnsentSummary(records: Dictionary(uniqueKeysWithValues: records.map { ($0.serverPath, $0) }), isOnline: online)
    }

    func testSplitsUnsentAndConflictsInSaveOrder() {
        let s = summary([record("b.md", .modified, at: 2), record("a.md", .modified, at: 1),
                         record("c.md", .conflict, at: 3), record("d.md", .synced)])
        XCTAssertEqual(s.unsent.map(\.serverPath), ["a.md", "b.md"])
        XCTAssertEqual(s.conflicts.map(\.serverPath), ["c.md"])
        XCTAssertEqual(s.unsentCount, 2)
        XCTAssertEqual(s.conflictCount, 1)
    }

    func testOfflineAndDeletedRows() {
        let off = summary([record("a.md", .modified, at: 1)], online: false)
        XCTAssertEqual(off.unsent[0].kind, .offline)
        let gone = summary([record("x/n.md", .deletedOnServer, open: false), record("y.md", .deletedOnServer, open: true)])
        XCTAssertEqual(gone.unsent.map(\.serverPath), ["x/n.md"])
        XCTAssertEqual(gone.unsent[0].folder, "x")
        XCTAssertFalse(gone.unsent[0].canSendNow)
    }

    func testQuitPrompt() {
        XCTAssertNil(VaultUnsentSummary.empty.quitPrompt())
        let many = summary((0..<10).map { record("n\($0).md", .modified, at: Double($0)) })
        let prompt = many.quitPrompt()
        XCTAssertEqual(prompt?.count, 10)
        XCTAssertEqual(prompt?.listed.count, VaultUnsentSummary.maxListed)
        XCTAssertEqual(prompt?.moreCount, 2)
        XCTAssertEqual(prompt?.offersSend, true)
        let conflictOnly = summary([record("c.md", .conflict)]).quitPrompt()
        XCTAssertEqual(conflictOnly?.offersSend, false)
        XCTAssertEqual(conflictOnly?.conflictCount, 1)
        let offline = summary([record("a.md", .modified)], online: false).quitPrompt()
        XCTAssertEqual(offline?.offersSend, false)
        XCTAssertEqual(offline?.isOffline, true)
    }

    func testFreshSaveDoesNotAskForAttentionButRejectionAndOldWaitingDo() {
        let now = Date()
        let fresh = summary([record("a.md", .modified, at: now.timeIntervalSince1970 - 1)])
        XCTAssertTrue(fresh.attentionUnsent(now: now).isEmpty)
        XCTAssertNotNil(fresh.nextAttentionDelay(now: now))
        let old = summary([record("a.md", .modified, at: now.timeIntervalSince1970 - 60)])
        XCTAssertEqual(old.attentionUnsent(now: now).count, 1)
        let rejected = summary([record("b.md", .modified, at: now.timeIntervalSince1970, issue: .forbidden)])
        XCTAssertEqual(rejected.attentionUnsent(now: now).count, 1)
    }

    func testQuitPromptSeparatesBlockedFromSendable() {
        let onlyBlocked = summary([record("a.md", .modified, at: 1, issue: .forbidden), record("b.md", .deletedOnServer, open: false)]).quitPrompt()
        XCTAssertEqual(onlyBlocked?.offersSend, false)
        XCTAssertEqual(onlyBlocked?.blockedCount, 2)
        XCTAssertEqual(onlyBlocked?.conflictCount, 0)
        let mixed = summary([record("a.md", .modified, at: 1, issue: .forbidden), record("c.md", .modified, at: 2)]).quitPrompt()
        XCTAssertEqual(mixed?.offersSend, true)
        XCTAssertEqual(mixed?.blockedCount, 1)
    }
}
