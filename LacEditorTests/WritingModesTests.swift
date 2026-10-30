import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class WritingModesTests: XCTestCase {
    private func editor(_ source: String) -> (EditorDocument, EditorTextView.Coordinator, LacTextView, NSScrollView, NSWindow) {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14), .foregroundColor: NSColor.systemRed])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.isVerticallyResizable = true
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        window.makeFirstResponder(view)
        return (document, coordinator, view, scroll, window)
    }

    func testWindowFlagsAreIndependent() throws {
        let suite = "LacEditorWritingModes.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let recent = RecentFilesStore(defaults: defaults)
        let first = AppState(initialDocument: EditorDocument(), recentFiles: recent, preferences: preferences)
        let second = AppState(initialDocument: EditorDocument(), recentFiles: recent, preferences: preferences)
        first.toggleFocusMode()
        XCTAssertTrue(first.isFocusMode)
        XCTAssertFalse(first.isTypewriterMode)
        XCTAssertFalse(second.isFocusMode)
        first.toggleTypewriterMode()
        XCTAssertTrue(first.isFocusMode)
        XCTAssertTrue(first.isTypewriterMode)
        first.resetClosedWindow()
        XCTAssertFalse(first.isFocusMode)
        XCTAssertFalse(first.isTypewriterMode)
    }

    func testViewMagnificationIsTemporaryAndIndependentOfFontSize() throws {
        let suite = "LacEditorViewMagnification.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let recent = RecentFilesStore(defaults: defaults)
        let first = AppState(initialDocument: EditorDocument(), recentFiles: recent, preferences: preferences)
        let second = AppState(initialDocument: EditorDocument(), recentFiles: recent, preferences: preferences)
        let fontSize = first.editorFontSize
        first.increaseViewMagnification()
        XCTAssertEqual(first.viewMagnification, 1.2, accuracy: 0.0001)
        XCTAssertEqual(second.viewMagnification, 1)
        XCTAssertEqual(first.editorFontSize, fontSize)
        first.decreaseViewMagnification()
        XCTAssertEqual(first.viewMagnification, 1, accuracy: 0.0001)
        first.setViewMagnification(20)
        XCTAssertEqual(first.viewMagnification, 4)
        first.setViewMagnification(0.01)
        XCTAssertEqual(first.viewMagnification, 0.25)
        first.setViewMagnification(.nan)
        XCTAssertEqual(first.viewMagnification, 0.25)
        first.resetViewMagnification()
        XCTAssertEqual(first.viewMagnification, 1)
        first.increaseViewMagnification()
        first.resetClosedWindow()
        XCTAssertEqual(first.viewMagnification, 1)
    }

    func testEditorMagnificationPreservesTextAndDefersDuringComposition() async throws {
        let source = "first line\nsecond line"
        let (document, coordinator, view, scroll, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        scroll.allowsMagnification = true
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(scroll.allowsMagnification)
        let selection = NSRange(location: 2, length: 0)
        view.setSelectedRange(selection)
        coordinator.updateViewMagnification(1.5)
        XCTAssertEqual(scroll.magnification, 1.5, accuracy: 0.001)
        coordinator.updateLayout(wordWrap: true, force: true)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, scroll.contentView.bounds.width - 2 * EditorTextView.minimumHorizontalInset, accuracy: 1)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 2, length: 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            let point = NSPoint(x: rect.minX + rect.width * 0.25, y: rect.midY)
            let physical = scroll.contentView.convert(point, from: view)
            let local = view.convert(physical, from: scroll.contentView)
            let hit = layout.characterIndex(for: NSPoint(x: local.x - view.textContainerOrigin.x, y: local.y - view.textContainerOrigin.y),
                                            in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            XCTAssertEqual(hit, 2)
            let windowPoint = view.convert(point, to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            view.setSelectedRange(NSRange(location: 0, length: 0))
            NSApp.postEvent(up, atStart: false)
            view.mouseDown(with: down)
            XCTAssertEqual(view.selectedRange().location, 2)
        } else { XCTFail("Missing text layout") }
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(document.isDirty)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: selection)
        XCTAssertFalse(scroll.allowsMagnification)
        coordinator.updateViewMagnification(2)
        XCTAssertEqual(scroll.magnification, 1.5, accuracy: 0.001)
        view.unmarkText()
        let applied = expectation(description: "deferred magnification")
        DispatchQueue.main.async { applied.fulfill() }
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(scroll.magnification, 2, accuracy: 0.001)
        coordinator.updateLayout(wordWrap: true, force: true)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, scroll.contentView.bounds.width - 2 * EditorTextView.minimumHorizontalInset, accuracy: 1)
        view.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        coordinator.updateViewMagnification(1.5)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: view.markedRange())
        let emptied = expectation(description: "empty composition")
        DispatchQueue.main.async { emptied.fulfill() }
        await fulfillment(of: [emptied], timeout: 2)
        XCTAssertEqual(scroll.magnification, 1.5, accuracy: 0.001)
        XCTAssertTrue(scroll.allowsMagnification)
        coordinator.updateViewMagnification(1)
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        coordinator.updateViewMagnification(0.5)
        scroll.frame.size = NSSize(width: 300, height: 320)
        coordinator.updateLayout(wordWrap: true, force: true)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, scroll.contentView.bounds.width - 2 * EditorTextView.minimumHorizontalInset, accuracy: 1)
        coordinator.updateMarkdownVerticalWriting(true)
        coordinator.updateLayout(wordWrap: true, force: true)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, scroll.contentView.bounds.height, accuracy: 1)
        coordinator.updateLineNumbersVisibility(true)
        coordinator.updateLayout(wordWrap: true, force: true)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0,
                       scroll.contentView.bounds.height - (scroll.horizontalRulerView?.ruleThickness ?? 0) / scroll.magnification, accuracy: 1)
        coordinator.updateMarkdownVerticalWriting(false)
        coordinator.updateLayout(wordWrap: true, force: true)
        XCTAssertNotNil(scroll.verticalRulerView)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0,
                       scroll.contentView.bounds.width - (scroll.verticalRulerView?.ruleThickness ?? 0) / scroll.magnification - 2 * EditorTextView.minimumHorizontalInset, accuracy: 1)
    }

    func testFocusRectsRespectSelectionAndKeepAttributes() throws {
        let source = "first\r\nsecond\nthird"
        let (_, coordinator, view, _, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateWritingModes(focus: true, typewriter: false)
        let range = (source as NSString).range(of: "second")
        view.setSelectedRange(NSRange(location: range.location + 1, length: 0))
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let activeRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let rects = view.focusDimmedRects(in: view.bounds)
        XCTAssertGreaterThanOrEqual(rects.count, 2)
        XCTAssertFalse(rects.contains { $0.intersects(activeRect) })
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        let across = NSRange(location: 1, length: NSMaxRange(range) - 1)
        view.setSelectedRange(across)
        XCTAssertEqual(view.focusDimmedRects(in: view.bounds).count, 1)
    }

    private static let sentenceSource = "Short one. Middle sentence that is deliberately long enough to wrap across several lines in the narrow editor width of four hundred points for sure, and then some more words to be safe. Tail end.\nSecond paragraph stays dimmed."

    func testSentenceFocusRectsSplitLinesAndKeepAttributes() throws {
        let source = Self.sentenceSource
        let (_, coordinator, view, _, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateWritingModes(focus: true, focusScope: .sentence, typewriter: false)
        XCTAssertEqual(view.focusScope, .sentence)
        let middle = (source as NSString).range(of: "deliberately")
        view.setSelectedRange(NSRange(location: middle.location, length: 0))
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let sentence = try XCTUnwrap(FocusSentenceService.activeRange(in: source as NSString, selection: view.selectedRange()))
        let origin = view.textContainerOrigin
        let rects = view.focusDimmedRects(in: view.bounds)
        var firstLine: NSRect?
        var middleLines: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard NSIntersectionRange(characters, sentence).length > 0 else { return }
            let shifted = rect.offsetBy(dx: origin.x, dy: origin.y)
            if firstLine == nil { firstLine = shifted } else { middleLines.append(shifted) }
        }
        let lastLine = middleLines.popLast()
        let first = try XCTUnwrap(firstLine)
        let last = try XCTUnwrap(lastLine)
        // Первая строка: кусок слева от предложения и нет куска справа до конца строки.
        let firstRects = rects.filter { $0.intersects(first) }
        XCTAssertTrue(firstRects.contains { $0.minX <= origin.x + 1 })
        XCTAssertFalse(firstRects.contains { $0.maxX >= first.maxX - 1 })
        // Последняя строка: кусок справа и нет куска слева.
        let lastRects = rects.filter { $0.intersects(last) }
        XCTAssertTrue(lastRects.contains { $0.maxX >= last.maxX - 1 })
        XCTAssertFalse(lastRects.contains { $0.minX <= origin.x + 1 })
        for line in middleLines { XCTAssertFalse(rects.contains { $0.intersects(line) }) }
        // Второй абзац приглушён целиком.
        let second = (source as NSString).range(of: "Second")
        let secondRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: second.location), effectiveRange: nil)
            .offsetBy(dx: origin.x, dy: origin.y)
        XCTAssertTrue(rects.contains { $0.contains(NSPoint(x: secondRect.midX, y: secondRect.midY)) })
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
    }

    func testParagraphScopeAfterSentenceRestoresRectsAndSelectionChangesSentence() throws {
        let source = Self.sentenceSource
        let (_, coordinator, view, _, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateWritingModes(focus: true, typewriter: false)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "deliberately").location, length: 0))
        let paragraphRects = view.focusDimmedRects(in: view.bounds)
        coordinator.updateWritingModes(focus: true, focusScope: .sentence, typewriter: false)
        let inMiddle = view.focusDimmedRects(in: view.bounds)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertNotEqual(view.focusDimmedRects(in: view.bounds), inMiddle)
        coordinator.updateWritingModes(focus: true, typewriter: false)
        XCTAssertEqual(view.focusScope, .paragraph)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "deliberately").location, length: 0))
        XCTAssertEqual(view.focusDimmedRects(in: view.bounds), paragraphRects)
    }

    func testSentenceScopeIsDeferredDuringComposition() async throws {
        let (_, coordinator, view, _, window) = editor("Раз. Два.")
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        coordinator.updateWritingModes(focus: true, focusScope: .sentence, typewriter: false)
        XCTAssertEqual(view.focusScope, .paragraph)
        XCTAssertFalse(view.focusModeEnabled)
        view.unmarkText()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(view.focusModeEnabled)
        XCTAssertEqual(view.focusScope, .sentence)
    }

    func testFocusScopeToggleIsPerWindowAndTemporary() throws {
        let suite = "LacEditorFocusScope.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let recent = RecentFilesStore(defaults: defaults)
        let first = AppState(initialDocument: EditorDocument(), recentFiles: recent, preferences: preferences)
        let second = AppState(initialDocument: EditorDocument(), recentFiles: recent, preferences: preferences)
        first.toggleFocusScope(.sentence)
        XCTAssertTrue(first.isFocusMode)
        XCTAssertEqual(first.focusScope, .sentence)
        XCTAssertFalse(second.isFocusMode)
        XCTAssertEqual(second.focusScope, .paragraph)
        first.toggleFocusScope(.paragraph)
        XCTAssertTrue(first.isFocusMode)
        XCTAssertEqual(first.focusScope, .paragraph)
        first.toggleFocusScope(.sentence)
        first.toggleFocusScope(.sentence)
        XCTAssertFalse(first.isFocusMode)
        first.toggleFocusScope(.sentence)
        first.resetClosedWindow()
        XCTAssertFalse(first.isFocusMode)
        XCTAssertEqual(first.focusScope, .paragraph)
    }

    func testInsetHasSingleOwnerAndDefersDuringComposition() async throws {
        let (_, coordinator, view, scroll, window) = editor("text")
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateTopInset(4)
        coordinator.updateWritingModes(focus: false, typewriter: true)
        XCTAssertEqual(view.textContainerInset.height, scroll.contentView.bounds.height / 2, accuracy: 0.5)
        coordinator.updateTopInset(12)
        XCTAssertEqual(view.textContainerInset.height, scroll.contentView.bounds.height / 2, accuracy: 0.5)
        coordinator.updateWritingModes(focus: false, typewriter: false)
        XCTAssertEqual(view.textContainerInset.height, 12, accuracy: 0.5)
        XCTAssertEqual(view.textContainerInset.width, 16, accuracy: 0.5)
        coordinator.updateWritingModes(focus: false, typewriter: true)
        scroll.frame.size.height = 300
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertEqual(view.textContainerInset.height, max(12, scroll.contentView.bounds.height / 2), accuracy: 0.5)
        coordinator.updateWritingModes(focus: false, typewriter: false)
        XCTAssertEqual(view.textContainerInset.height, 12, accuracy: 0.5)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        coordinator.updateWritingModes(focus: true, typewriter: true)
        XCTAssertEqual(view.textContainerInset.height, 12, accuracy: 0.5)
        XCTAssertFalse(view.focusModeEnabled)
        view.unmarkText()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(view.focusModeEnabled)
        XCTAssertEqual(view.textContainerInset.height, scroll.contentView.bounds.height / 2, accuracy: 0.5)
    }

    func testManualScrollCancelsPendingCentering() async throws {
        let source = String(repeating: "line\n", count: 150)
        let (_, coordinator, view, scroll, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateWritingModes(focus: false, typewriter: true)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        coordinator.writingUserDidScroll()
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 0))
        let before = scroll.contentView.bounds.origin
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, before.y, accuracy: 1)
    }
    func testTypingCentersCurrentLineAndDisablingRestoresInset() async throws {
        let source = String(repeating: "line\n", count: 150)
        let (_, coordinator, view, scroll, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateTopInset(12)
        coordinator.updateWritingModes(focus: false, typewriter: true)
        let position = (source as NSString).range(of: "line", options: .backwards).location
        view.setSelectedRange(NSRange(location: position, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        try await Task.sleep(for: .milliseconds(300))
        let layout = try XCTUnwrap(view.layoutManager)
        let glyph = layout.glyphIndexForCharacter(at: view.selectedRange().location)
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let lineCenter = rect.midY + view.textContainerOrigin.y
        XCTAssertEqual(lineCenter, scroll.contentView.bounds.midY, accuracy: 2)
        XCTAssertEqual(view.textContainerInset.height, scroll.contentView.bounds.height / 2, accuracy: 0.5)
        coordinator.updateWritingModes(focus: false, typewriter: false)
        XCTAssertEqual(view.textContainerInset.height, 12, accuracy: 0.5)
    }
    func testSelectionChangeBeforeCenteringDoesNotFollowNewCaret() async throws {
        let source = String(repeating: "line\n", count: 150)
        let (_, coordinator, view, scroll, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateWritingModes(focus: false, typewriter: true)
        let end = (source as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        scroll.contentView.scroll(to: .zero)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
    }

    func testTrailingNewlineUsesCurrentExtraFragmentInLargeDocument() async throws {
        let source = String(repeating: "line\n", count: 110_000)
        let (_, coordinator, view, scroll, window) = editor(source)
        defer { coordinator.updateActivity(false); window.close() }
        let layout = try XCTUnwrap(view.layoutManager)
        EditorLayoutPolicy.configure(layout, textLength: (source as NSString).length)
        coordinator.updateWritingModes(focus: false, typewriter: true)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        try await Task.sleep(for: .milliseconds(500))
        let extra = layout.extraLineFragmentRect
        XCTAssertFalse(extra.isEmpty)
        XCTAssertGreaterThan(extra.minY, 0)
        XCTAssertEqual(extra.midY + view.textContainerOrigin.y, scroll.contentView.bounds.midY, accuracy: 2)
    }
    func testLargeDocumentEndUsesWholeComposedCharacter() async throws {
        let prefix = String(repeating: "line\n", count: 110_000)
        for suffix in ["😀", "👨‍👩‍👧‍👦", "e\u{301}"] {
            let (_, coordinator, view, scroll, window) = editor(prefix)
            let layout = try XCTUnwrap(view.layoutManager)
            EditorLayoutPolicy.configure(layout, textLength: (prefix as NSString).length)
            coordinator.updateWritingModes(focus: false, typewriter: true)
            view.setSelectedRange(NSRange(location: (prefix as NSString).length, length: 0))
            view.insertText(suffix, replacementRange: view.selectedRange())
            try await Task.sleep(for: .milliseconds(500))
            let text = view.string as NSString
            let composed = text.rangeOfComposedCharacterSequence(at: text.length - 1)
            XCTAssertEqual(text.substring(with: composed), suffix)
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: composed.location), effectiveRange: nil)
            XCTAssertFalse(rect.isEmpty)
            XCTAssertGreaterThan(rect.minY, 0)
            XCTAssertEqual(rect.midY + view.textContainerOrigin.y, scroll.contentView.bounds.midY, accuracy: 2)
            coordinator.updateActivity(false)
            window.close()
        }
    }
}
