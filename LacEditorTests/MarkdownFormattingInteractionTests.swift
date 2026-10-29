import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownFormattingInteractionTests: XCTestCase {
    func testLooseHeadingCommandPreservesUndoAndSourceUntilEdit() throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownStrictMode = false
        let source = "###中文😀"
        let document = EditorDocument(text: source, language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        coordinator.configureAIAssistance(preferences: preferences)
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        window.makeFirstResponder(view)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
        view.setSelectedRange(NSRange(location: 3, length: 0))
        NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: .heading(3)))
        XCTAssertEqual(view.string, "中文😀")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }

    func testChangingSyntaxWhileEditingTableDoesNotReuseOldCellPresentation() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "| A | B |\n|---|---|\n| edit | $x$ |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        coordinator.isMarkdownOutlineVisible = true
        coordinator.configureAIAssistance(preferences: preferences)
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        preferences.markdownInlineMath = false
        coordinator.updateMarkdownPresentation()
        child.unmarkText()
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        let expected = try XCTUnwrap(MarkdownPresentationParser.parse(view.string, syntax: preferences.markdownSyntax).tables.first?.rows.last?.cells.last)
        let frame = try XCTUnwrap(layout.markdownTableFrame(for: expected, in: container))
        let other = try XCTUnwrap(layout.markdownTableCellInfo(at: NSPoint(x: frame.midX, y: frame.midY), in: container)?.0)
        XCTAssertFalse(other.displayRuns.contains { if case .tableMath = $0.kind { return true }; return false })
        XCTAssertEqual(other.displayText?.trimmingCharacters(in: .whitespaces), "$x$")
    }
    func testMathPairInActiveTableCellUsesOneUndo() async throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| hello |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        coordinator.isMarkdownOutlineVisible = true
        view.delegate = coordinator
        view.autoPairMarkdownEnabled = true
        view.allowsUndo = true
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateMathPairContextEnabled(true)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        window.makeFirstResponder(child)
        child.setSelectedRange(NSRange(location: (child.string as NSString).length, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "$", charactersIgnoringModifiers: "$", isARepeat: false, keyCode: 21))
        child.keyDown(with: event)
        XCTAssertTrue(view.string.contains("hello$$"))
        child.keyDown(with: event)
        XCTAssertTrue(view.string.contains("hello$$"))
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        child.setSelectedRange(NSRange(location: (child.string as NSString).length, length: 0))
        child.keyDown(with: event)
        XCTAssertTrue(view.string.contains("hello$$"))
        child.deleteBackward(nil)
        XCTAssertEqual(view.string, source)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: (child.string as NSString).length, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        child.insertText("$", replacementRange: child.markedRange())
        XCTAssertFalse(child.string.contains("$$"))
    }
    func testTableChildStrikeUsesSnapshotBeforeBackgroundParseCompletes() throws {
        _ = NSApplication.shared
        let source = "- [x] done\n\n  | A |\n  |---|\n  | cell |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateStrikeCompletedTasks(true)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertNotNil(child.layoutManager?.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 0, effectiveRange: nil))
    }
    func testListMarkerSelectionAndMarkedInputUseEditor() async throws {
        _ = NSApplication.shared
        let source = "9. one\n1. two\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14)]), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        coordinator.isMarkdownOutlineVisible = true
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        view.setSelectedRange((source as NSString).range(of: "after"))
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        let marker = (source as NSString).range(of: "1.")
        func isControl() -> Bool {
            layout.ensureLayout(for: container)
            return layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: marker.location)).contains(.controlCharacter)
        }
        XCTAssertTrue(isControl())
        let body = (source as NSString).range(of: "two")
        view.setSelectedRange(NSRange(location: NSMaxRange(body), length: 0))
        XCTAssertFalse(isControl())
        view.undoManager?.removeAllActions()
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(isControl())
        view.unmarkText()
        XCTAssertTrue(view.string.contains("two中"))
        view.setSelectedRange((view.string as NSString).range(of: "after"))
        for _ in 0..<200 where !isControl() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(isControl())
        XCTAssertEqual(view.string, "9. one\n1. two中\n\nafter")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }
    func testSmartQuoteAtEmptyDocumentUsesCheckingAndOneUndo() async throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "", language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: ""), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        coordinator.isMarkdownOutlineVisible = true
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        view.insertText("\"", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "\"")
        let options = coordinator.beginSmartTextChecking([:])
        let quote = NSTextCheckingResult.quoteCheckingResult(range: NSRange(location: 0, length: 1), replacementString: "“")
        view.handleTextCheckingResults([quote], forRange: NSRange(location: 0, length: 1), types: NSTextCheckingResult.CheckingType.quote.rawValue,
            options: options, orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 0)
        XCTAssertEqual(view.string, "“")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "")
    }
    func testSmartSubstitutionFiltersCheckingResultsBySourceContext() async throws {
        _ = NSApplication.shared
        let source = "hello world `code`"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        coordinator.isMarkdownOutlineVisible = true
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        defer { coordinator.updateActivity(false); withExtendedLifetime(scroll) {} }
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        let plain = (source as NSString).range(of: "hello")
        let code = (source as NSString).range(of: "code")
        let quote = NSTextCheckingResult.quoteCheckingResult(range: plain, replacementString: "“")
        let dash = NSTextCheckingResult.dashCheckingResult(range: code, replacementString: "—")
        let spelling = NSTextCheckingResult.spellCheckingResult(range: code)
        let options = coordinator.beginSmartTextChecking([:])
        XCTAssertEqual(coordinator.filterSmartSubstitutions([quote, dash, spelling], options: options).map(\.resultType), [.quote, .spelling])
        _ = coordinator.beginSmartTextChecking([:])
        XCTAssertEqual(coordinator.filterSmartSubstitutions([quote, spelling], options: options).map(\.resultType), [.spelling])
        let oldOptions = coordinator.beginSmartTextChecking([:])
        view.insertText("x", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(coordinator.filterSmartSubstitutions([quote, spelling], options: oldOptions).map(\.resultType), [.spelling])
        document.isMarkdownFormatted = false
        coordinator.updateMarkdownPresentation()
        XCTAssertEqual(coordinator.filterSmartSubstitutions([quote, spelling], options: coordinator.beginSmartTextChecking([:])).map(\.resultType), [.spelling])
        XCTAssertEqual(storage.string, "hello xworld `code`")
    }
    func testEmojiCompletionDoesNotOpenInCodeOrURL() async throws {
        _ = NSApplication.shared
        for (source, position) in [("`sm`", 1), ("[link](https://example.com/sm)", 27)] {
            let document = EditorDocument(text: source, language: .markdown)
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            coordinator.textView = view
            coordinator.foldLayoutManager = layout
            coordinator.isMarkdownOutlineVisible = true
            view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll)
            coordinator.updateActivity(true)
            coordinator.updateMarkdownPresentation()
            defer { coordinator.updateActivity(false); window.close() }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(document.isMarkdownOutlineCurrent)
            view.setSelectedRange(NSRange(location: position, length: 0))
            let colon = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: ":", charactersIgnoringModifiers: ":", isARepeat: false, keyCode: 41))
            view.keyDown(with: colon)
            for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(document.isMarkdownOutlineCurrent)
            XCTAssertNil(view.emojiCompletionRange)
            XCTAssertTrue(view.emojiCompletionValues.isEmpty)
            XCTAssertFalse(coordinator.emojiCompletionRequested)
            XCTAssertEqual(view.string, (source as NSString).replacingCharacters(in: NSRange(location: position, length: 0), with: ":"))
        }
    }
    func testEmojiCompletionDiscardsLateResultAndEscapeClosesIt() async throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "hello ", language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: document.text), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
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
        coordinator.updateMarkdownPresentation()
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let started = expectation(description: "catalog started")
        let finished = expectation(description: "catalog result processed")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        coordinator.emojiCompletions = { _ in started.fulfill(); gate.wait(); return ["smile"] }
        coordinator.emojiCompletionDidFinish = { finished.fulfill() }
        let colon = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: ":", charactersIgnoringModifiers: ":", isARepeat: false, keyCode: 41))
        view.keyDown(with: colon)
        await fulfillment(of: [started], timeout: 5)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        gate.signal()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(view.emojiCompletionRange)
        XCTAssertTrue(view.emojiCompletionValues.isEmpty)
        XCTAssertEqual(view.string, "hello :")

        coordinator.emojiCompletionDidFinish = nil
        coordinator.emojiCompletions = { _ in ["smile"] }
        view.insertText("", replacementRange: NSRange(location: 6, length: 1))
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.keyDown(with: colon)
        for _ in 0..<200 where view.emojiCompletionRange == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(view.emojiCompletionRange)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: NSApp.keyWindow?.windowNumber ?? window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        XCTAssertNil(view.emojiCompletionRange)
        XCTAssertEqual(view.string, "hello :")
    }
    func testEmojiCompletionUsesEditorSnapshotAndOneUndo() async throws {
        _ = NSApplication.shared
        for (suffix, useTab) in [("", false), (":", false), ("", true)] {
            let source = "中文 " + suffix
            let document = EditorDocument(text: source, language: .markdown)
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
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
            coordinator.updateMarkdownPresentation()
            defer { coordinator.updateActivity(false); window.close() }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: ("中文 " as NSString).length, length: 0))
            for (character, key, shift) in [(":", UInt16(41), true), ("s", UInt16(1), false), ("m", UInt16(46), false)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: key))
                view.keyDown(with: event)
            }
            for _ in 0..<200 where !view.emojiCompletionValues.contains(":smile:") { try await Task.sleep(for: .milliseconds(20)) }
            let range = try XCTUnwrap(view.emojiCompletionRange)
            XCTAssertEqual(view.string, "中文 :sm" + suffix)
            XCTAssertTrue(view.emojiCompletionValues.contains(":smile:"))
            if !useTab {
                view.insertCompletion(":smile:", forPartialWordRange: range, movement: 0, isFinal: false)
                XCTAssertEqual(view.string, "中文 :sm" + suffix)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                XCTAssertFalse(view.acceptEmojiCompletion?(":smile:", range) ?? true)
                view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            }
            view.undoManager?.removeAllActions()
            let expected: String
            if useTab {
                expected = "中文 " + (try XCTUnwrap(view.emojiCompletionValues.first))
                let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: NSApp.keyWindow?.windowNumber ?? window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48))
                NSApp.sendEvent(tab)
                for _ in 0..<100 where view.string != expected { try await Task.sleep(for: .milliseconds(20)) }
            } else {
                view.insertCompletion(":smile:", forPartialWordRange: range, movement: 0, isFinal: true)
                expected = "中文 :smile:"
            }
            XCTAssertEqual(view.string, expected)
            try XCTUnwrap(view.undoManager).undo()
            XCTAssertEqual(view.string, "中文 :sm" + suffix)
        }
    }

    func testNestedFenceReturnAfterReplacingParagraphWithoutWaitingForParse() async throws {
        _ = NSApplication.shared
        for (source, beforeEnter, expected, cursor) in [
            ("> - old", "> - ```js", "> - ```js\n>   \n>   ```", "> - ```js\n>   "),
            ("- first\n  old", "- first\n  ```js", "- first\n  ```js\n  \n  ```", "- first\n  ```js\n  "),
            ("- first\n old", "- first\n ```js", "- first\n ```js\n ", "- first\n ```js\n "),
            ("> - first\n>   old", "> - first\n>   ```js", "> - first\n>   ```js\n>   \n>   ```", "> - first\n>   ```js\n>   "),
            ("> - first\n>  old", "> - first\n>  ```js", "> - first\n>  ```js\n", "> - first\n>  ```js\n"),
            ("> -\t中文😀\r\n> \told", "> -\t中文😀\r\n> \t```js", "> -\t中文😀\r\n> \t```js\r\n> \t\r\n> \t```", "> -\t中文😀\r\n> \t```js\r\n> \t"),
            ("> ", "> ```js", "> ```js\n> \n> ```", "> ```js\n> "),
            ("> - ", "> - ```js", "> - ```js\n>   \n>   ```", "> - ```js\n>   "),
            (">    ", ">    ```js", ">    ```js\n>    \n>    ```", ">    ```js\n>    "),
            ("> -    ", "> -    ```js", "> -    ```js\n>      \n>      ```", "> -    ```js\n>      "),
            ("-\t", "-\t```js", "-\t```js\n \t\n \t```", "-\t```js\n \t"),
            (">\t", ">\t```js", ">\t```js\n>\t\n>\t```", ">\t```js\n>\t"),
            ("> -\t", "> -\t```js", "> -\t```js\n>  \t\n>  \t```", "> -\t```js\n>  \t"),
            ("-     ", "-     ```js", "-     ```js\n- ", "-     ```js\n- ")
        ] {
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            view.allowsUndo = true
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            coordinator.textView = view
            coordinator.foldLayoutManager = layout
            coordinator.isMarkdownOutlineVisible = true
            view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll)
            coordinator.updateActivity(true)
            coordinator.updateMarkdownPresentation()
            defer { coordinator.updateActivity(false); window.close() }
            for _ in 0..<100 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(document.isMarkdownOutlineCurrent)
            let old = (source as NSString).range(of: "old")
            view.setSelectedRange(old.location == NSNotFound ? NSRange(location: (source as NSString).length, length: 0) : old)
            view.insertText("```js", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, beforeEnter)
            view.undoManager?.removeAllActions()
            view.insertNewline(nil)
            XCTAssertEqual(view.string, expected)
            XCTAssertEqual(view.selectedRange().location, (cursor as NSString).length)
            try XCTUnwrap(view.undoManager).undo()
            XCTAssertEqual(view.string, beforeEnter)
        }
    }

    func testNestedFenceReturnUsesContainerAndOneUndo() async throws {
        _ = NSApplication.shared
        for (source, continuation) in [("> ```js", "> "), ("- parent\r\n\r\n  ```js", "  "), ("> -\t```js", ">  \t")] {
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            view.allowsUndo = true
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            coordinator.textView = view
            coordinator.foldLayoutManager = layout
            coordinator.isMarkdownOutlineVisible = true
            view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll)
            coordinator.updateActivity(true)
            coordinator.updateMarkdownPresentation()
            defer { coordinator.updateActivity(false); window.close() }
            for _ in 0..<100 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(document.isMarkdownOutlineCurrent, source)
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            view.undoManager?.removeAllActions()
            view.insertNewline(nil)
            let newline = source.contains("\r\n") ? "\r\n" : "\n"
            XCTAssertEqual(view.string, source + newline + continuation + newline + continuation + "```", source)
            XCTAssertEqual(view.selectedRange().location, (source as NSString).length + (newline as NSString).length + (continuation as NSString).length, source)
            try XCTUnwrap(view.undoManager).undo()
            XCTAssertEqual(view.string, source)
        }
    }

    func testFenceReturnUsesConfirmedContextAfterTyping() async throws {
        _ = NSApplication.shared
        for insideCode in [false, true] {
            let source = insideCode ? "```js\ncode\n" : "before\r\n\r\n"
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            view.allowsUndo = true
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            coordinator.textView = view
            coordinator.foldLayoutManager = layout
            coordinator.isMarkdownOutlineVisible = true
            view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll)
            coordinator.updateActivity(true)
            coordinator.updateMarkdownPresentation()
            defer { coordinator.updateActivity(false); window.close() }
            for _ in 0..<100 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(document.isMarkdownOutlineCurrent)
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            view.insertText(insideCode ? "```" : "```js", replacementRange: view.selectedRange())
            let beforeEnter = view.string
            view.undoManager?.removeAllActions()
            view.insertNewline(nil)
            if insideCode {
                XCTAssertEqual(view.string, beforeEnter + "\n")
            } else {
                XCTAssertEqual(view.string, beforeEnter + "\r\n\r\n```")
                try XCTUnwrap(view.undoManager).undo()
                XCTAssertEqual(view.string, beforeEnter)
            }
        }
    }

    func testFenceReturnDoesNotCloseExistingCodeBlock() async throws {
        _ = NSApplication.shared
        for source in ["```js\nexisting\n```", "```js\nexisting"] {
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            coordinator.textView = view
            coordinator.foldLayoutManager = layout
            coordinator.isMarkdownOutlineVisible = true
            view.delegate = coordinator
            coordinator.installObservers(scrollView: scroll)
            coordinator.updateActivity(true)
            coordinator.updateMarkdownPresentation()
            defer { coordinator.updateActivity(false) }
            for _ in 0..<100 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(document.isMarkdownOutlineCurrent)
            view.setSelectedRange(NSRange(location: 5, length: 0))
            view.insertNewline(nil)
            XCTAssertEqual(view.string, "```js\n" + String(source.dropFirst(5)))
            withExtendedLifetime(scroll) {}
        }
    }

    func testOpeningFenceReturnCreatesBlockWithOneUndo() throws {
        _ = NSApplication.shared
        let source = "```swift"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = source
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "```swift\n\n```")
        XCTAssertEqual(view.selectedRange().location, (source as NSString).length + 1)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        document.isMarkdownFormatted = false
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, source + "\n")
        document.isMarkdownFormatted = true
        view.string = "```"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.codeFenceNewlineHandler?() ?? true)
        XCTAssertTrue(view.hasMarkedText())
    }

    func testCommandUsesActiveEditorAndOneUndo() async throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "中文😀", language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: document.text)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
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
        defer { coordinator.updateActivity(false); window.close() }
        window.makeFirstResponder(view)
        let selected = NSRange(location: 0, length: (document.text as NSString).length)
        view.setSelectedRange(selected)
        NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: .bold))
        XCTAssertEqual(view.string, "**中文😀**")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "中文😀")
        let undoManager = try XCTUnwrap(view.undoManager)
        undoManager.undo()
        XCTAssertEqual(view.string, "中文😀")
        undoManager.redo()
        XCTAssertEqual(view.string, "**中文😀**")
        let cases: [(MarkdownFormattingCommand, String)] = [
            (.bulletList, "- 中文😀"), (.numberedList, "1. 中文😀"),
            (.taskList, "- [ ] 中文😀"), (.fencedCode, "```\n中文😀\n```"),
            (.inlineMath, "$中文😀$"), (.blockMath, "$$\n中文😀\n$$"),
            (.horizontalRule, "中文😀\n\n---\n\n")
        ]
        for formatted in [false, true] {
            document.isMarkdownFormatted = formatted
            for (source, command, expected) in [
                ("- 中文😀\r\n- other", MarkdownFormattingCommand.taskList, "- [ ] 中文😀\r\n- other"),
                ("7) plain\n8) [x] 中文😀\n9) other", .numberedList, "7) plain\n8) 中文😀\n9) other"),
                ("> - [X] 中文😀\r\n> - other", .numberedList, "> 1. 中文😀\r\n> - other")
            ] {
                view.string = source
                view.setSelectedRange((source as NSString).range(of: "中文😀"))
                undoManager.removeAllActions()
                NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                    object: MarkdownFormattingRequest(documentID: document.id, command: command))
                XCTAssertEqual(view.string, expected)
                XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "中文😀")
                undoManager.undo()
                XCTAssertEqual(view.string, source)
                undoManager.redo()
                XCTAssertEqual(view.string, expected)
            }
        }
        for formatted in [false, true] {
            document.isMarkdownFormatted = formatted
            let source = "- 中文😀\r\n  continuation\r\n  - child\r\n- other"
            let expected = "1. 中文😀\r\n   continuation\r\n   - child\r\n- other"
            view.string = source
            let caret = (source as NSString).range(of: "continuation").location + 3
            view.setSelectedRange(NSRange(location: caret, length: 0))
            undoManager.removeAllActions()
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                object: MarkdownFormattingRequest(documentID: document.id, command: .numberedList))
            XCTAssertEqual(view.string, expected)
            XCTAssertEqual(view.selectedRange(), NSRange(location: caret + 2, length: 0))
            undoManager.undo()
            XCTAssertEqual(view.string, source)
            undoManager.redo()
            XCTAssertEqual(view.string, expected)
        }
        for formatted in [false, true] {
            document.isMarkdownFormatted = formatted
            for (prefix, continuation) in [("> ", "> "), ("- ", "  "), ("- [x] ", "  "), ("> - [x] ", ">   ")] {
                for body in ["", "中文😀\r\n" + continuation + "continued"] {
                    if prefix == "> - [x] " && body.isEmpty { continue }
                    let source = prefix + body
                    let newline = body.isEmpty ? "\n" : "\r\n"
                    let expected = prefix + "$$" + newline + continuation + body + newline + continuation + "$$"
                    view.string = source
                    view.setSelectedRange(body.isEmpty ? NSRange(location: (source as NSString).length, length: 0) : (source as NSString).range(of: body))
                    undoManager.removeAllActions()
                    NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                        object: MarkdownFormattingRequest(documentID: document.id, command: .blockMath))
                    XCTAssertEqual(view.string, expected)
                    XCTAssertEqual(view.selectedRange(), NSRange(location: (prefix as NSString).length + 2 + (newline as NSString).length + (continuation as NSString).length,
                                                                length: (body as NSString).length))
                    XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), body)
                    undoManager.undo()
                    XCTAssertEqual(view.string, source)
                    undoManager.redo()
                    XCTAssertEqual(view.string, expected)
                }
            }
        }
        for formatted in [false, true] {
            document.isMarkdownFormatted = formatted
            for (command, expected) in cases {
                let prefix = "**anchor**\n\n"
                let source = prefix + "中文😀"
                view.string = source
                let selected = (source as NSString).range(of: "中文😀")
                view.setSelectedRange(selected)
                undoManager.removeAllActions()
                let presentation = MarkdownPresentationController(textView: view, layout: layout)
                presentation.update(document: document, enabled: formatted, isActive: true, revision: 0, currentRevision: { 0 })
                if formatted {
                    for _ in 0..<20 {
                        if layout.isMarkdownMarkerHidden(at: 0) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0), "Formatting must be applied before the command")
                }
                NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: command))
                XCTAssertEqual(view.string, prefix + expected)
                XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "中文😀")
                undoManager.undo()
                XCTAssertEqual(view.string, source)
                undoManager.redo()
                XCTAssertEqual(view.string, prefix + expected)
                XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "中文😀")
                view.isEditable = false
                NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: command))
                XCTAssertEqual(view.string, prefix + expected)
                view.isEditable = true
                presentation.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
            }
        }
        for formatted in [false, true] {
            document.isMarkdownFormatted = formatted
            let prefix = "**anchor**\n\n"
            view.string = prefix
            view.setSelectedRange(NSRange(location: (prefix as NSString).length, length: 0))
            undoManager.removeAllActions()
            let presentation = MarkdownPresentationController(textView: view, layout: layout)
            var presentationRevision: UInt = 0
            presentation.update(document: document, enabled: formatted, isActive: true, revision: presentationRevision, currentRevision: { presentationRevision })
            if formatted {
                for _ in 0..<20 {
                    if layout.isMarkdownMarkerHidden(at: 0) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0), "Formatting must be applied before the table command")
            }
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: .table(.create(rows: 1, columns: 2))))
            let created = prefix + "|   |   |\n| --- | --- |\n|   |   |"
            XCTAssertEqual(view.string, created)
            XCTAssertEqual(view.selectedRange(), NSRange(location: (prefix as NSString).length + 2, length: 0))
            undoManager.undo()
            XCTAssertEqual(view.string, prefix)
            undoManager.redo()
            XCTAssertEqual(view.string, created)

            let table = prefix + "| A | B |\n| --- | --- |\n| 中文😀 | x |"
            presentation.beforeEdit(range: NSRange(location: 0, length: (view.string as NSString).length), replacementLength: (table as NSString).length)
            if formatted { XCTAssertFalse(layout.isMarkdownMarkerHidden(at: 0)) }
            view.string = table
            let caret = NSRange(location: (table as NSString).range(of: "中文😀").location, length: 0)
            view.setSelectedRange(caret)
            presentationRevision += 1
            presentation.edited(revision: presentationRevision)
            if formatted {
                for _ in 0..<20 {
                    if layout.isMarkdownMarkerHidden(at: 0) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0), "New text must be formatted before alignment")
            }
            undoManager.removeAllActions()
            let command = MarkdownFormattingCommand.table(.align(.center))
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: UUID(), command: command))
            XCTAssertEqual(view.string, table)
            view.isEditable = false
            let editableRequest = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: editableRequest)
            XCTAssertNil(editableRequest.result)
            let readRequest = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: readRequest)
            XCTAssertNotNil(readRequest.result)
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: command))
            XCTAssertEqual(view.string, table)
            view.isEditable = true
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: command))
            let aligned = prefix + "| A | B |\n| :---: | --- |\n| 中文😀 | x |"
            XCTAssertEqual(view.string, aligned)
            XCTAssertEqual(view.selectedRange().location, (aligned as NSString).range(of: "中文😀").location)
            undoManager.undo()
            XCTAssertEqual(view.string, table)
            undoManager.redo()
            XCTAssertEqual(view.string, aligned)

            let linkSource = prefix + "中文😀"
            presentation.beforeEdit(range: NSRange(location: 0, length: (view.string as NSString).length), replacementLength: (linkSource as NSString).length)
            view.string = linkSource
            let linkSelection = (linkSource as NSString).range(of: "中文😀")
            view.setSelectedRange(linkSelection)
            presentationRevision += 1
            presentation.edited(revision: presentationRevision)
            if formatted {
                for _ in 0..<20 {
                    if layout.isMarkdownMarkerHidden(at: 0) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0), "New text must be formatted before the link command")
            }
            undoManager.removeAllActions()
            let link = MarkdownFormattingCommand.link(MarkdownLinkInput(label: "中文😀", address: "https://example.com"))
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: link))
            let linked = prefix + "[中文😀](<https://example.com>)"
            XCTAssertEqual(view.string, linked)
            XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "中文😀")
            undoManager.undo()
            XCTAssertEqual(view.string, linkSource)
            undoManager.redo()
            XCTAssertEqual(view.string, linked)
            presentation.update(document: document, enabled: false, isActive: true, revision: presentationRevision, currentRevision: { presentationRevision })
        }
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        for (command, _) in cases {
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: command))
            XCTAssertEqual(view.string, "中")
            XCTAssertTrue(view.hasMarkedText())
        }
        NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: .table(.create(rows: 1, columns: 2))))
        XCTAssertEqual(view.string, "中")
        XCTAssertTrue(view.hasMarkedText())
        view.unmarkText()
        view.string = "**中文😀**"
        view.isEditable = false
        NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown, object: MarkdownFormattingRequest(documentID: document.id, command: .italic))
        XCTAssertEqual(view.string, "**中文😀**")
        layout.setFoldedRange(NSRange(location: 2, length: 4))
        let target = NSRange(location: 3, length: 0)
        NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                        object: EditorSelectionRequest(documentID: document.id, range: target))
        XCTAssertNil(layout.foldedRange)
        XCTAssertEqual(view.selectedRange(), target)
    }
}
