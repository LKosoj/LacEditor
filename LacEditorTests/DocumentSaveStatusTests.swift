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
}
