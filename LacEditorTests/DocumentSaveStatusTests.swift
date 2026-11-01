import Foundation
import XCTest
@testable import LacEditor

final class DocumentSaveStatusTests: XCTestCase {
    private func dirtyDocument() -> EditorDocument {
        let document = EditorDocument(text: "a", url: URL(fileURLWithPath: "/tmp/save-status.md"))
        document.text = "ab"
        document.refreshDirtyState()
        XCTAssertTrue(document.isDirty)
        return document
    }

    func testDirtyComparesLengthThenContent() {
        let document = EditorDocument(text: "abc", url: URL(fileURLWithPath: "/tmp/dirty-length.md"))
        document.text = "abd"
        document.refreshDirtyState()
        XCTAssertTrue(document.isDirty)
        document.text = "abcd"
        document.refreshDirtyState()
        XCTAssertTrue(document.isDirty)
        document.text = "abc"
        document.refreshDirtyState()
        XCTAssertFalse(document.isDirty)
    }

    func testCanonicallyEqualTextWithDifferentBytesIsDifferent() {
        let precomposed = "\u{0439}", decomposed = "\u{0438}\u{0306}"
        XCTAssertEqual(precomposed, decomposed)
        XCTAssertTrue(EditorDocument.textsDiffer(precomposed, decomposed))
        XCTAssertFalse(EditorDocument.textsDiffer(precomposed, precomposed))
        // Два диакритика в разном порядке: длина та же, строки канонически равны, байты разные.
        let orderA = "a\u{0323}\u{0301}", orderB = "a\u{0301}\u{0323}"
        XCTAssertEqual(orderA, orderB)
        XCTAssertEqual(orderA.utf8.count, orderB.utf8.count)
        XCTAssertTrue(EditorDocument.textsDiffer(orderA, orderB))
        let document = EditorDocument(text: precomposed, url: URL(fileURLWithPath: "/tmp/canonical.md"))
        document.markSaved(snapshot: decomposed, revision: document.textRevision)
        XCTAssertTrue(document.isDirty, "markSaved(snapshot:)")
        document.markSaved()
        XCTAssertFalse(document.isDirty)
        document.text = decomposed
        document.refreshDirtyState()
        XCTAssertTrue(document.isDirty, "refreshDirtyState")
        let id = UUID()
        document.markSaved()
        document.attachLiveTextProvider(id: id, provider: { nil }, acknowledgement: { _ in })
        document.text = precomposed
        document.detachLiveTextProvider(id: id)
        XCTAssertTrue(document.isDirty, "detachLiveTextProvider")
    }

    func testRenameToMarkdownRecomputesProfileWithoutMediaBytes() {
        let payload = String(repeating: "A", count: 21 * 1_048_576)
        let text = "![a](data:image/png;base64,\(payload))\n"
        let document = EditorDocument(text: text, url: URL(fileURLWithPath: "/tmp/media-rename.txt"))
        XCTAssertEqual(document.performanceProfile, .large)
        document.updateLocation(to: URL(fileURLWithPath: "/tmp/media-rename.md"))
        XCTAssertEqual(document.language, .markdown)
        XCTAssertEqual(document.performanceProfile, .standard)
    }

    func testCleanDocumentStatuses() {
        XCTAssertEqual(EditorDocument(text: "a", url: URL(fileURLWithPath: "/tmp/a.md")).saveStatus, .saved)
        XCTAssertEqual(EditorDocument(text: "").saveStatus, .newDocument)
        let busy = EditorDocument(text: "a", url: URL(fileURLWithPath: "/tmp/a.md"))
        busy.ioState = .saving
        XCTAssertEqual(busy.saveStatus, .busy)
    }

    func testDirtyWithoutStoreIsUntracked() {
        XCTAssertEqual(dirtyDocument().saveStatus, .unsavedUntracked)
    }

    func testAcknowledgeProtectsOnlyCurrentRevision() {
        let document = dirtyDocument()
        document.beginRecoveryTracking()
        XCTAssertEqual(document.saveStatus, .unsavedPending)
        document.acknowledgeRecoveryCopy(revision: document.textRevision &- 1, result: .written)
        XCTAssertEqual(document.saveStatus, .unsavedPending)
        document.acknowledgeRecoveryCopy(revision: document.textRevision, result: .written)
        XCTAssertEqual(document.saveStatus, .unsavedProtected)
    }

    func testEditInvalidatesProtectedCopy() {
        let document = dirtyDocument()
        document.beginRecoveryTracking()
        document.acknowledgeRecoveryCopy(revision: document.textRevision, result: .written)
        document.text = "abc"
        XCTAssertEqual(document.saveStatus, .unsavedPending)
    }

    func testLiveEditInvalidatesAndBlocksAcknowledgement() {
        let document = dirtyDocument()
        document.beginRecoveryTracking()
        document.acknowledgeRecoveryCopy(revision: document.textRevision, result: .written)
        document.noteLiveEdit(isEmpty: false)
        XCTAssertEqual(document.saveStatus, .unsavedPending)
        document.acknowledgeRecoveryCopy(revision: document.textRevision, result: .written)
        XCTAssertEqual(document.saveStatus, .unsavedPending)
    }

    func testFailureNoSessionAndInvalidate() {
        let document = dirtyDocument()
        document.beginRecoveryTracking()
        document.acknowledgeRecoveryCopy(revision: document.textRevision, result: .failed("m"))
        XCTAssertEqual(document.saveStatus, .unsavedCopyFailed("m"))
        document.text = "abcd"
        document.beginRecoveryTracking()
        XCTAssertEqual(document.saveStatus, .unsavedCopyFailed("m"))
        document.acknowledgeRecoveryCopy(revision: document.textRevision, result: .noSession)
        XCTAssertEqual(document.saveStatus, .unsavedUntracked)
    }

    func testInvalidateKeepsUntrackedAndResetClears() {
        let document = dirtyDocument()
        document.invalidateRecoveryCopy()
        XCTAssertEqual(document.recoveryCopy, .untracked)
        document.beginRecoveryTracking()
        document.resetRecoveryCopy()
        XCTAssertEqual(document.recoveryCopy, .untracked)
    }

    func testNoteSavedToDisk() {
        let document = EditorDocument(text: "")
        let date = Date()
        document.noteSavedToDisk(at: date)
        XCTAssertEqual(document.lastSavedAt, date)
    }

    private func diskSnapshot(_ number: Int) -> FileRevisionSnapshot {
        FileRevisionSnapshot(
            identity: DocumentFileIdentity(canonicalPath: "/tmp/disk", resourceIdentifier: "id\(number)"),
            modificationDate: Date(timeIntervalSince1970: Double(number)),
            fileSize: number
        )
    }

    func testNoteDiskStateLogic() {
        let document = EditorDocument(text: "a", url: URL(fileURLWithPath: "/tmp/disk.md"), fileRevisionSnapshot: diskSnapshot(1))
        document.noteDiskState(nil)
        XCTAssertNil(document.externalChange)
        document.noteDiskState(.present(diskSnapshot(1)))
        XCTAssertNil(document.externalChange)
        document.noteDiskState(.present(diskSnapshot(2)))
        XCTAssertEqual(document.externalChange, .present(diskSnapshot(2)))
        document.noteDiskState(nil)
        XCTAssertEqual(document.externalChange, .present(diskSnapshot(2)))
        document.noteDiskState(.present(diskSnapshot(3)))
        XCTAssertEqual(document.externalChange, .present(diskSnapshot(3)))
        document.noteDiskState(.missing)
        XCTAssertEqual(document.externalChange, .missing)
        document.keepMyVersion()
        XCTAssertNil(document.externalChange)
        document.noteDiskState(.missing)
        XCTAssertNil(document.externalChange)
        document.noteDiskState(.present(diskSnapshot(3)))
        XCTAssertEqual(document.externalChange, .present(diskSnapshot(3)))
        document.noteDiskState(.present(diskSnapshot(1)))
        XCTAssertNil(document.externalChange)
        // Возврат к baseline сбрасывает и «оставить мою версию».
        document.noteDiskState(.missing)
        XCTAssertEqual(document.externalChange, .missing)
        XCTAssertEqual(document.text, "a")
    }

    func testUpdateFileRevisionSnapshotClearsBannerAndDismissal() {
        let document = EditorDocument(text: "a", url: URL(fileURLWithPath: "/tmp/disk2.md"), fileRevisionSnapshot: diskSnapshot(1))
        document.noteDiskState(.present(diskSnapshot(2)))
        document.updateFileRevisionSnapshot(diskSnapshot(2))
        XCTAssertNil(document.externalChange)
        document.noteDiskState(.present(diskSnapshot(3)))
        document.keepMyVersion()
        document.updateFileRevisionSnapshot(diskSnapshot(4))
        document.noteDiskState(.present(diskSnapshot(3)))
        XCTAssertEqual(document.externalChange, .present(diskSnapshot(3)), "отказ относился к прежнему baseline")
    }

    func testExternalReplacementMarkerIsOneShotAndTiedToRevision() {
        let document = EditorDocument(text: "a", url: URL(fileURLWithPath: "/tmp/disk3.md"))
        XCTAssertFalse(document.consumeExternalReplacement())
        document.text = "b"
        document.markExternalReplacement()
        XCTAssertTrue(document.consumeExternalReplacement())
        XCTAssertFalse(document.consumeExternalReplacement())
        document.markExternalReplacement()
        document.text = "c"
        XCTAssertFalse(document.consumeExternalReplacement(), "отметка устарела после новой правки")
    }

    func testSaveStatusUnchangedByBanner() {
        let document = EditorDocument(text: "a", url: URL(fileURLWithPath: "/tmp/disk4.md"), fileRevisionSnapshot: diskSnapshot(1))
        let before = (document.saveStatus, document.isDirty)
        document.noteDiskState(.present(diskSnapshot(2)))
        XCTAssertEqual(document.saveStatus, before.0)
        XCTAssertEqual(document.isDirty, before.1)
        document.noteDiskState(.missing)
        XCTAssertEqual(document.saveStatus, before.0)
        XCTAssertEqual(document.isDirty, before.1)
    }
}
