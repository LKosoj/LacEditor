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

    func testLeavingFormattedModeFoldsMediaBeforeDeferredTask() async throws {
        for length in [300, 20_000] {
            let payload = String(repeating: "A", count: length)
            let source = "before\n![image](data:image/png;base64,\(payload))\nafter"
            let document = EditorDocument(text: source, language: .markdown)
            let editor = makeEditor(document, formatted: true)
            defer { editor.close() }
            let selection = NSRange(location: 2, length: 3)
            editor.view.setSelectedRange(selection)
            let revision = document.textRevision
            document.isMarkdownFormatted = false
            editor.coordinator.updateMarkdownPresentation()
            let expected = [(source as NSString).range(of: payload)]
            XCTAssertEqual(editor.layout.automaticMediaFoldedRanges, expected)
            XCTAssertEqual(editor.view.string, source)
            XCTAssertEqual(editor.view.selectedRange(), selection)
            XCTAssertEqual(document.textRevision, revision)
            XCTAssertFalse(document.isDirty)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(editor.layout.automaticMediaFoldedRanges, expected)
        }
    }

    func testLeavingFormattedModeKeepsPayloadUnderCaretOpen() async throws {
        let payload = String(repeating: "A", count: 300)
        let other = String(repeating: "B", count: 300)
        let source = "![a](data:image/png;base64,\(payload))\n![b](data:image/png;base64,\(other))"
        let document = EditorDocument(text: source, language: .markdown)
        let editor = makeEditor(document, formatted: true)
        defer { editor.close() }
        let caret = NSRange(location: (source as NSString).range(of: payload).location + 5, length: 0)
        editor.view.setSelectedRange(caret)
        document.isMarkdownFormatted = false
        editor.coordinator.updateMarkdownPresentation()
        let expected = [(source as NSString).range(of: other)]
        XCTAssertEqual(editor.layout.automaticMediaFoldedRanges, expected)
        XCTAssertEqual(editor.view.selectedRange(), caret)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(editor.layout.automaticMediaFoldedRanges, expected)
    }

    func testLeavingFormattedModeRespectsDisabledFolding() async throws {
        let source = "![image](data:image/png;base64,\(String(repeating: "A", count: 300)))"
        let overridden = EditorDocument(text: source, language: .markdown)
        overridden.setOverride(false, for: .folding)
        let large = EditorDocument(text: source, language: .markdown, performanceProfile: .large)
        for document in [overridden, large] {
            let editor = makeEditor(document, formatted: true)
            defer { editor.close() }
            document.isMarkdownFormatted = false
            editor.coordinator.updateMarkdownPresentation()
            XCTAssertTrue(editor.layout.automaticMediaFoldedRanges.isEmpty)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(editor.layout.automaticMediaFoldedRanges.isEmpty)
        }
    }

    func testLeavingFormattedModeWaitsForMarkedTextToFinish() {
        let payload = String(repeating: "A", count: 300)
        let source = "![image](data:image/png;base64,\(payload))"
        let document = EditorDocument(text: source, language: .markdown)
        let editor = makeEditor(document, formatted: true)
        defer { editor.close() }
        editor.view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        document.isMarkdownFormatted = false
        editor.coordinator.updateMarkdownPresentation()
        XCTAssertTrue(editor.view.hasMarkedText())
        XCTAssertTrue(editor.layout.automaticMediaFoldedRanges.isEmpty)
        editor.view.unmarkText()
        editor.coordinator.updateMarkdownPresentation()
        XCTAssertEqual(editor.layout.automaticMediaFoldedRanges, [(editor.view.string as NSString).range(of: payload)])
    }

    func testSourceModeUpdateKeepsDeferredMediaFolds() async throws {
        let payload = String(repeating: "A", count: 300)
        let source = "![image](data:image/png;base64,\(payload))"
        let document = EditorDocument(text: source, language: .markdown)
        let editor = makeEditor(document, formatted: false)
        defer { editor.close() }
        XCTAssertTrue(editor.layout.automaticMediaFoldedRanges.isEmpty)
        let deadline = Date().addingTimeInterval(5)
        while editor.layout.automaticMediaFoldedRanges.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(editor.layout.automaticMediaFoldedRanges, [(source as NSString).range(of: payload)])
    }

    func testMediaPayloadRangesFollowEditsWithoutFullScan() {
        let payload = String(repeating: "QUJD", count: 100)
        let source = "text ![a](data:image/png;base64,\(payload)) middle ![b](data:image/png;base64,\(payload)) end"
        func edited(_ range: NSRange, _ replacement: String) -> (text: String, ranges: [NSRange]?) {
            let text = (source as NSString).replacingCharacters(in: range, with: replacement)
            return (text, FoldService.shiftedMediaPayloadRanges(
                FoldService.mediaPayloadRanges(in: source), editedRange: range,
                replacementLength: (replacement as NSString).length, in: text as NSString))
        }
        let raw = source as NSString
        for (range, replacement) in [
            (NSRange(location: 0, length: 0), "абв"),
            (raw.range(of: "middle"), "x"),
            (raw.range(of: "end"), ""),
            (raw.range(of: "image/png"), "image/jpeg"),
            (raw.range(of: "image/png"), "text/plain"),
            (raw.range(of: ";base64"), "")
        ] {
            let result = edited(range, replacement)
            XCTAssertEqual(result.ranges, FoldService.mediaPayloadRanges(in: result.text))
        }
        // Правка внутри данных и большая вставка оставляют ответ полному поиску.
        XCTAssertNil(edited(NSRange(location: raw.range(of: payload).location + 10, length: 0), "A").ranges)
        XCTAssertNil(edited(NSRange(location: 0, length: 0), String(repeating: "a", count: 5000)).ranges)
    }

    func testPlainEditKeepsAutomaticFoldListWithoutLayoutChange() async throws {
        let payload = String(repeating: "QUJD", count: 100)
        let source = "head\n![a](data:image/png;base64,\(payload))\ntail"
        let document = EditorDocument(text: source, language: .markdown)
        let editor = makeEditor(document, formatted: false)
        defer { editor.close() }
        for _ in 0..<100 where editor.layout.automaticMediaFoldedRanges.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let folded = try XCTUnwrap(editor.layout.automaticMediaFoldedRanges.first)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.insertText("абв", replacementRange: NSRange(location: 0, length: 0))
        // Сдвиг виден сразу, без ожидания отложенной задачи.
        XCTAssertEqual(editor.layout.automaticMediaFoldedRanges, [NSRange(location: folded.location + 3, length: folded.length)])
    }

    private struct Editor {
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let layout: FoldLayoutManager
        let scroll: NSScrollView

        func close() {
            coordinator.updateActivity(false)
            withExtendedLifetime(scroll) {}
        }
    }

    private func makeEditor(_ document: EditorDocument, formatted: Bool) -> Editor {
        _ = NSApplication.shared
        document.isMarkdownFormatted = formatted
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text))
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        return Editor(coordinator: coordinator, view: view, layout: layout, scroll: scroll)
    }
}
