import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class AIContextNavigationTests: XCTestCase {
    func testPendingReferenceIsAppliedWhenEditorBecomesReady() async {
        _ = NSApplication.shared
        let document = EditorDocument(text: "😀 中文 reference")
        let range = NSRange(location: 3, length: 2)
        document.pendingAIContextSelection = (range, document.textRevision)
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = document.text
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        let revealed = expectation(description: "Reference revealed after editor attachment")
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.revealSelection, object: nil, queue: .main) { notification in
            if (notification.object as? EditorSelectionRequest)?.documentID == document.id { revealed.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        coordinator.applyPendingContextSelection()
        await fulfillment(of: [revealed], timeout: 1)
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertNil(document.pendingAIContextSelection)
        XCTAssertTrue(coordinator.textView === view)
    }

    func testPendingReferenceForOldVersionDoesNotMoveSelection() {
        let document = EditorDocument(text: "changed")
        document.pendingAIContextSelection = (NSRange(location: 2, length: 2), document.textRevision &+ 1)
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: .zero)
        view.string = document.text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textView = view
        coordinator.updateActivity(true)
        coordinator.applyPendingContextSelection()
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertNil(document.pendingAIContextSelection)
    }
}
