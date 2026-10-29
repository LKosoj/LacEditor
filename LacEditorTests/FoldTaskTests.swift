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

    func testLongEmbeddedMediaPayloadCanBeFoldedWithoutHidingMarkdown() {
        let payload = String(repeating: "QUJD", count: 100)
        let source = "before ![image](data:image/png;base64,\(payload)) after\n<audio src=\"data:audio/mpeg;base64,\(payload)\"></audio>"
        let text = source as NSString
        let first = text.range(of: payload)
        let second = text.range(of: payload, range: NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first)))
        let expected = [first, second]
        XCTAssertEqual(FoldService.mediaPayloadRanges(in: source), expected)
        XCTAssertEqual(FoldService.foldableRange(in: source, at: 0, language: .markdown), expected[0])
        XCTAssertEqual(FoldService.foldableRange(in: source, at: expected[1].location + 20, language: .markdown), expected[1])

        let short = "![image](data:image/png;base64,QUJD)"
        XCTAssertNil(FoldService.foldableRange(in: short, at: 0, language: .markdown))
        let unrelated = "[file](data:text/plain;base64,\(payload))"
        XCTAssertNil(FoldService.foldableRange(in: unrelated, at: 0, language: .markdown))

        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        layout.setAutomaticMediaFoldedRanges(expected)
        XCTAssertTrue(layout.isCharacterFolded(first.location + 1))
        XCTAssertTrue(layout.isCharacterFolded(second.location + 1))
        XCTAssertFalse(layout.isCharacterFolded(first.location - 1))
        XCTAssertTrue(layout.removeAutomaticMediaFold(containing: first.location + 1))
        XCTAssertFalse(layout.isCharacterFolded(first.location + 1))
        XCTAssertTrue(layout.isCharacterFolded(second.location + 1))
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
