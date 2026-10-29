import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownAutoPairTests: XCTestCase {
    func testMathPairUsesCurrentEditorAndLocalSkip() async throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "hello", language: .markdown)
        document.featureOverrides.wordCount = false
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
        view.autoPairMarkdownEnabled = true
        view.allowsUndo = true
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateMathPairContextEnabled(true)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        for _ in 0..<200 where view.mathPairAllowed?(view.selectedRange()) != true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.mathPairAllowed?(view.selectedRange()), true)
        let letter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        view.keyDown(with: letter)
        XCTAssertEqual(view.string, "hellox")
        XCTAssertEqual(view.mathPairAllowed?(view.selectedRange()), true)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "$", charactersIgnoringModifiers: "$", isARepeat: false, keyCode: 21))
        view.keyDown(with: event)
        XCTAssertEqual(view.string, "hellox$$")
        XCTAssertEqual(view.selectedRange().location, 7)
        view.keyDown(with: event)
        XCTAssertEqual(view.string, "hellox$$")
        XCTAssertEqual(view.selectedRange().location, 8)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "hellox")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        for _ in 0..<200 where view.mathPairAllowed?(view.selectedRange()) != true { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(view.mathPairAllowed?(view.selectedRange()), true)
        view.keyDown(with: event)
        XCTAssertEqual(view.string, "hellox$$")
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "hellox")
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 6, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("$", replacementRange: view.markedRange())
        XCTAssertEqual(view.string, "hellox$")
    }
    private func action(_ source: String, _ character: String, range: NSRange) -> MarkdownAutoPairService.Action? {
        MarkdownAutoPairService.action(in: source as NSString, selection: range, character: character,
                                       brackets: true, markdown: true, pairs: [])
    }

    func testPairsAndUnicodeSelection() throws {
        let selection = ("中文😀" as NSString).range(of: "文😀")
        for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("*", "*"), ("_", "_"), ("`", "`"), ("~", "~"), ("^", "^"), ("=", "=")] {
            guard case let .replace(range, text, selected, _)? = action("中文😀", opening, range: selection) else {
                XCTFail("Missing pair for \(opening)"); continue
            }
            let result = ("中文😀" as NSString).replacingCharacters(in: range, with: text)
            XCTAssertEqual(result, "中" + opening + "文😀" + closing)
            XCTAssertEqual((result as NSString).substring(with: selected), "文😀")
        }
        XCTAssertNil(action("😀", "(", range: NSRange(location: 1, length: 0)))
        XCTAssertNil(action("e\u{301}", "(", range: NSRange(location: 1, length: 0)))
    }

    func testEscapesAndCodeContexts() {
        XCTAssertNil(action("\\", "(", range: NSRange(location: 1, length: 0)))
        XCTAssertNotNil(action("\\\\", "(", range: NSRange(location: 2, length: 0)))
        for source in ["```\ncode\n```", "- ```\n  code\n  ```", "    code", "`line\ncode`"] {
            let position = (source as NSString).range(of: "code").location + 1
            XCTAssertNil(action(source, "*", range: NSRange(location: position, length: 0)), source)
        }
        XCTAssertNil(action("- ```", "(", range: NSRange(location: 5, length: 0)))
        XCTAssertNil(action("a `code` b", "(", range: ("a `code` b" as NSString).range(of: "code` b")))
    }

    func testPreferencesGateTheirOwnPairs() {
        let empty = NSRange(location: 0, length: 0)
        XCTAssertNil(action("", "~", range: empty))
        XCTAssertNil(action("", "^", range: empty))
        XCTAssertNil(action("", "=", range: empty))
        XCTAssertNotNil(action("", "$", range: empty))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "$", brackets: true, markdown: false, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "word" as NSString, selection: NSRange(location: 0, length: 4), character: "~", brackets: true, markdown: false, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "word" as NSString, selection: NSRange(location: 0, length: 4), character: "^", brackets: true, markdown: false, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "word" as NSString, selection: NSRange(location: 0, length: 4), character: "=", brackets: true, markdown: false, pairs: []))
        XCTAssertNil(action("`word`", "~", range: NSRange(location: 1, length: 4)))
        XCTAssertNil(action("don", "'", range: NSRange(location: 3, length: 0)))
        XCTAssertNil(action("𝒜", "'", range: NSRange(location: 2, length: 0)))
        XCTAssertNil(action("𝒜", "'", range: NSRange(location: 0, length: 0)))
        XCTAssertNil(action("e\u{301}", "'", range: NSRange(location: 2, length: 0)))
        XCTAssertNotNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "{", brackets: true, markdown: false, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "'", brackets: false, markdown: true, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "(", brackets: false, markdown: true, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "*", brackets: true, markdown: false, pairs: []))
        XCTAssertNotNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "(", brackets: true, markdown: false, pairs: []))
        XCTAssertNotNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "*", brackets: false, markdown: true, pairs: []))
    }

    func testPreferencesAreIndependentAndDefaultOff() {
        let suite = "MarkdownAutoPairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.autoPairBracketsEnabled)
        XCTAssertFalse(preferences.autoPairMarkdownEnabled)
        preferences.autoPairBracketsEnabled = true
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.autoPairBracketsEnabled)
        XCTAssertFalse(reloaded.autoPairMarkdownEnabled)
    }

    func testSystemTextSubstitutionPreferencesPersistIndependently() {
        let suite = "MarkdownTextSubstitutionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.smartQuotesEnabled)
        XCTAssertFalse(preferences.smartDashesEnabled)
        XCTAssertFalse(preferences.systemTextReplacementEnabled)
        preferences.smartQuotesEnabled = true
        preferences.systemTextReplacementEnabled = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertTrue(restored.smartQuotesEnabled)
        XCTAssertFalse(restored.smartDashesEnabled)
        XCTAssertTrue(restored.systemTextReplacementEnabled)
    }

    func testActualInputSkipDeleteUndoAndGuards() throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "", language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: "")
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        view.autoPairBracketsEnabled = true
        view.autoPairMarkdownEnabled = true
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
        let input = NSRange(location: NSNotFound, length: 0)
        func type(_ character: String, keyCode: UInt16, shift: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: keyCode))
            view.keyDown(with: event)
        }
        view.insertText("(", replacementRange: input)
        XCTAssertEqual(view.string, "(")
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        try type("(", keyCode: 25, shift: true)
        XCTAssertEqual(view.string, "()")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        try type("x", keyCode: 7)
        try type(")", keyCode: 29, shift: true)
        XCTAssertEqual(view.string, "(x)")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        undo.undo()
        XCTAssertEqual(view.string, "()")
        undo.undo()
        XCTAssertEqual(view.string, "")
        undo.redo()
        XCTAssertEqual(view.string, "()")
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        undo.removeAllActions()
        try type("{", keyCode: 33, shift: true)
        XCTAssertEqual(view.string, "{}")
        try type("}", keyCode: 30, shift: true)
        XCTAssertEqual(view.string, "{}")
        XCTAssertEqual(view.selectedRange().location, 2)
        undo.undo()
        XCTAssertEqual(view.string, "")
        try type("{", keyCode: 33, shift: true)
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "")
        view.autoPairMarkdownEnabled = false
        for (character, key, shift) in [("{", UInt16(33), true), ("'", UInt16(39), false)] {
            view.string = ""
            view.setSelectedRange(NSRange(location: 0, length: 0))
            try type(character, keyCode: key, shift: shift)
            XCTAssertEqual(view.string.utf16.count, 2)
            view.deleteBackward(nil)
            XCTAssertEqual(view.string, "")
        }
        view.autoPairMarkdownEnabled = true
        view.string = "don"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        try type("'", keyCode: 39)
        XCTAssertEqual(view.string, "don'")
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        undo.removeAllActions()
        try type("*", keyCode: 28, shift: true)
        try type("*", keyCode: 28, shift: true)
        XCTAssertEqual(view.string, "****")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "**")
        undo.undo()
        XCTAssertEqual(view.string, "****")
        for marker in ["_", "`"] {
            view.string = ""
            view.setSelectedRange(NSRange(location: 0, length: 0))
            try type(marker, keyCode: marker == "_" ? 27 : 50, shift: marker == "_")
            try type(marker, keyCode: marker == "_" ? 27 : 50, shift: marker == "_")
            if marker == "_" {
                XCTAssertEqual(view.string, "____")
                view.deleteBackward(nil)
                XCTAssertEqual(view.string, "__")
            } else {
                try type(marker, keyCode: marker == "_" ? 27 : 50, shift: marker == "_")
                XCTAssertEqual(view.string, "```")
            }
        }
        view.string = "中文😀"
        let selected = (view.string as NSString).range(of: "文😀")
        view.setSelectedRange(selected)
        undo.removeAllActions()
        try type("[", keyCode: 33)
        XCTAssertEqual(view.string, "中[文😀]")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "文😀")
        undo.undo()
        XCTAssertEqual(view.string, "中文😀")
        undo.redo()
        XCTAssertEqual(view.string, "中[文😀]")
        view.string = "中文😀"
        view.setSelectedRange((view.string as NSString).range(of: "文😀"))
        undo.removeAllActions()
        try type("=", keyCode: 24)
        XCTAssertEqual(view.string, "中=文😀=")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "文😀")
        try type("=", keyCode: 24)
        XCTAssertEqual(view.string, "中==文😀==")
        undo.undo()
        XCTAssertEqual(view.string, "中=文😀=")
        undo.undo()
        XCTAssertEqual(view.string, "中文😀")
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try type("=", keyCode: 24)
        XCTAssertEqual(view.string, "=")
        view.string = "中文😀"
        view.setSelectedRange((view.string as NSString).range(of: "文😀"))
        undo.removeAllActions()
        try type("~", keyCode: 50, shift: true)
        XCTAssertEqual(view.string, "中~文😀~")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "文😀")
        undo.undo()
        XCTAssertEqual(view.string, "中文😀")
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try type("~", keyCode: 50, shift: true)
        XCTAssertEqual(view.string, "~")
        view.string = "中文😀"
        view.setSelectedRange((view.string as NSString).range(of: "文😀"))
        undo.removeAllActions()
        try type("^", keyCode: 22, shift: true)
        XCTAssertEqual(view.string, "中^文😀^")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "文😀")
        undo.undo()
        XCTAssertEqual(view.string, "中文😀")
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("(", replacementRange: view.markedRange())
        XCTAssertEqual(view.string, "(")
        view.string = "ab"
        view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 0)), NSValue(range: NSRange(location: 2, length: 0))])
        if view.selectedRanges.count == 2 {
            view.insertText("(", replacementRange: input)
            XCTAssertFalse(view.string.contains("()"))
        }
        coordinator.currentLanguage = .plainText
        view.string = ""
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("(", replacementRange: input)
        XCTAssertEqual(view.string, "(")
        coordinator.currentLanguage = .markdown
        view.isEditable = false
        view.insertText("[", replacementRange: input)
        XCTAssertEqual(view.string, "(")
    }
}
