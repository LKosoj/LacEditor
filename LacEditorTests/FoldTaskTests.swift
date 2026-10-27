import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class FoldTaskTests: XCTestCase {
    func testRangesAndCancellationForMarkdownAndJSON() {
        let markdown = "# 标题😀\n正文\n# следующий\n"
        let body = (markdown as NSString).range(of: "正文\n")
        XCTAssertEqual(FoldService.foldableRange(in: markdown, at: 0, language: .markdown), body)
        let json = "{\"中😀\": [1, 2]}"
        XCTAssertEqual(FoldService.foldableRange(in: json, at: 0, language: .json),
                       NSRange(location: 1, length: (json as NSString).length - 2))
        for language in [EditorLanguage.markdown, .json] {
            let text = language == .markdown ? "# heading\n" + String(repeating: "body\n", count: 100) : "[" + String(repeating: "1,", count: 5_000) + "1]"
            var checks = 0
            XCTAssertNil(FoldService.foldableRange(in: text, at: 0, language: language, isCancelled: {
                checks += 1
                return checks > 1
            }))
            XCTAssertGreaterThan(checks, 1)
        }
    }

    func testSelectionAndEditBeforeResultPreventFolding() async {
        _ = NSApplication.shared
        let source = "# heading\n" + String(repeating: "body\n", count: 10_000)
        let document = EditorDocument(text: source, language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = textView
        coordinator.foldLayoutManager = layout
        textView.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NotificationCenter.default.post(name: EditorCommandNotification.toggleFold, object: document.id)
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.selectionDidChangeDuringTracking()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        let selectionSettled = expectation(description: "selection change cancels fold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selectionSettled.fulfill() }
        await fulfillment(of: [selectionSettled], timeout: 2)
        XCTAssertNil(layout.foldedRange)
        NotificationCenter.default.post(name: EditorCommandNotification.toggleFold, object: document.id)
        _ = coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "x")
        let settled = expectation(description: "old task cannot apply")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertNil(layout.foldedRange)
        NotificationCenter.default.post(name: EditorCommandNotification.toggleFold, object: document.id)
        document.setOverride(false, for: .folding)
        coordinator.updatePerformanceFeatures()
        let disabled = expectation(description: "disabled fold cannot apply")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { disabled.fulfill() }
        await fulfillment(of: [disabled], timeout: 2)
        XCTAssertNil(layout.foldedRange)
        document.setOverride(true, for: .folding)
        NotificationCenter.default.post(name: EditorCommandNotification.toggleFold, object: document.id)
        NotificationCenter.default.post(name: EditorCommandNotification.toggleFold, object: document.id)
        let deadline = Date().addingTimeInterval(5)
        while layout.foldedRange == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(layout.foldedRange, NSRange(location: 10, length: (source as NSString).length - 10))
        coordinator.updateActivity(false)
        window.close()
    }
}
