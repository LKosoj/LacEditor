import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownWidthTests: XCTestCase {
    func testNativeLigatureSettingChangesAttributesWithoutEditingText() throws {
        _ = NSApplication.shared
        let source = "office 中文 😀 affinity"
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        layout.ensureLayout(for: container)
        coordinator.updateEditorLigatures(0)
        XCTAssertEqual((storage.attribute(.ligature, at: 1, effectiveRange: nil) as? NSNumber)?.intValue, 0)
        coordinator.updateEditorLigatures(2)
        XCTAssertEqual((storage.attribute(.ligature, at: 1, effectiveRange: nil) as? NSNumber)?.intValue, 2)
        coordinator.updateEditorLigatures(nil)
        XCTAssertNil(storage.attribute(.ligature, at: 1, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
        withExtendedLifetime(scroll) {}
    }
    private final class Options: ObservableObject {
        @Published var width: Double? = 300
        @Published var wrap = true
        @Published var tocLevel = 6
    }

    private struct Host: View {
        let document: EditorDocument
        let sessions: EditorSessionStore
        @ObservedObject var options: Options
        var body: some View {
            EditorTextView(document: document, sessionStore: sessions, fontSize: 14, lineSpacing: 4,
                indentationStyle: .spaces, tabWidth: 4, wordWrap: options.wrap, showsLineNumbers: true,
                topInset: 8, isActive: true, requestTextTransformation: { _ in }, isOutlineVisible: options.width == 200 || options.tocLevel == 1,
                maximumTextWidth: options.width, markdownTOCMaxLevel: options.tocLevel)
        }
    }

    private struct LigatureHost: View {
        let document: EditorDocument
        let sessions: EditorSessionStore
        @ObservedObject var preferences: AppPreferences
        var body: some View {
            EditorTextView(document: document, sessionStore: sessions, fontSize: 14, lineSpacing: 4,
                indentationStyle: .spaces, tabWidth: 4, wordWrap: true, showsLineNumbers: true,
                topInset: 8, isActive: true, requestTextTransformation: { _ in },
                isOutlineVisible: preferences.editorLigatures == 2, aiPreferences: preferences)
        }
    }

    private struct SmallCapsHost: View {
        let document: EditorDocument
        let sessions: EditorSessionStore
        @ObservedObject var preferences: AppPreferences
        var body: some View {
            EditorTextView(document: document, sessionStore: sessions, fontSize: 14, lineSpacing: 4,
                indentationStyle: .spaces, tabWidth: 4, wordWrap: true, showsLineNumbers: true,
                topInset: 8, isActive: true, requestTextTransformation: { _ in },
                isOutlineVisible: preferences.markdownSmallCapsLevels.contains(1), aiPreferences: preferences,
                textFontFamily: preferences.editorTextFontFamily)
        }
    }

    func testSmallCapsWaitForParentAndChildComposition() async throws {
        _ = NSApplication.shared
        let family = NSFontManager.shared.availableFontFamilies.first { family in
            guard let font = AppPreferences.availableFont(family: family, size: 14) else { return false }
            return FoldLayoutManager.supportsSmallCaps(NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask))
        }
        guard let family else { throw XCTSkip("No installed font advertises small caps") }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.editorTextFontFamily = family
        let source = "# office\n\n| A |\n|---|\n| affinity |\n"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: SmallCapsHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView != nil }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        window.makeFirstResponder(view)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: (source as NSString).length, length: 0))
        preferences.markdownSmallCapsLevels = [1]
        let parentDelivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(parentDelivered)
        XCTAssertTrue(layout.markdownSmallCapsLevels.isEmpty)
        view.unmarkText()
        let parentApplied = await waitFor { layout.markdownSmallCapsLevels == [1] }
        XCTAssertTrue(parentApplied)
        let heading = (view.string as NSString).range(of: "office")
        let styled = await waitFor { (view.textStorage?.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont)?.fontDescriptor.object(forKey: .featureSettings) != nil }
        XCTAssertTrue(styled)
        let afterParent = view.string
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(afterParent).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let beforeSetting = view.string
        let undoBeforeSetting = view.undoManager?.canUndo
        preferences.markdownSmallCapsLevels = []
        let childDelivered = await waitFor { !coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(childDelivered)
        XCTAssertEqual(layout.markdownSmallCapsLevels, [1])
        XCTAssertEqual(view.string, beforeSetting)
        XCTAssertEqual(view.undoManager?.canUndo, undoBeforeSetting)
        child.unmarkText()
        let childApplied = await waitFor { layout.markdownSmallCapsLevels.isEmpty }
        XCTAssertTrue(childApplied)
        let restoredFont = await waitFor {
            (view.textStorage?.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont) == layout.markdownHeadingFont(level: 1)
        }
        XCTAssertTrue(restoredFont)
        XCTAssertTrue(view.string.hasPrefix("# office"))
    }

    func testAlignmentRestoresInsertedTextAfterParentAndChildComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownTextAlignment = .center
        let document = EditorDocument(text: "alpha\n\n| A |\n|---|\n| cell |\n", language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView != nil }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), storage = try XCTUnwrap(view.textStorage)
        func alignment(_ index: Int) -> NSTextAlignment? {
            (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        let centered = await waitFor { alignment(1) == .center }
        XCTAssertTrue(centered)
        window.makeFirstResponder(view)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 1))
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: view.markedRange())
        view.unmarkText()
        let stillCentered = await waitFor { alignment(1) == .center }
        XCTAssertTrue(stillCentered)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        child.setMarkedText("文字", selectedRange: NSRange(location: 2, length: 0), replacementRange: child.markedRange())
        child.unmarkText()
        coordinator.finishTableCell()
        let childPosition = (view.string as NSString).range(of: "文字").location
        guard childPosition != NSNotFound else { XCTFail("Child composition was not committed"); return }
        document.isMarkdownFormatted = false
        coordinator.updateMarkdownPresentation()
        let restored = await waitFor {
            alignment(1) != .center && alignment(2) != .center &&
                alignment(childPosition) != .center && alignment(childPosition + 1) != .center
        }
        XCTAssertTrue(restored)
        XCTAssertTrue(view.string.contains("中文"))
        XCTAssertTrue(view.string.contains("文字"))
    }

    func testHeadingNumberingPreferenceUpdatesNativePresentationWithoutEditingText() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "# First\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView)
        let first = (source as NSString).range(of: "First")
        view.setSelectedRange((source as NSString).range(of: "end"))
        preferences.markdownNumberHeadings = true
        let numbered = await waitFor { coordinator.foldLayoutManager?.markdownNumberedHeading(at: 0)?.number == "1. " }
        XCTAssertTrue(numbered)
        let storage = try XCTUnwrap(view.textStorage)
        func indent() -> CGFloat {
            (storage.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        }
        XCTAssertGreaterThan(indent(), 0)
        view.setSelectedRange(first)
        let revealed = await waitFor { indent() == 0 }
        XCTAssertTrue(revealed)
        preferences.markdownNumberHeadings = false
        let disabled = await waitFor { !coordinator.headingNumbering }
        XCTAssertTrue(disabled)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testUppercaseHeadingPreferenceWaitsForComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "# Straße\n\n| A |\n|---|\n| cell |\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView)
        window.makeFirstResponder(view)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: (source as NSString).length, length: 0))
        preferences.markdownUppercaseHeadingLevels = [1]
        preferences.editorLigatures = 2
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertTrue(coordinator.uppercaseHeadingLevels.isEmpty)
        let composing = view.string
        view.unmarkText()
        let applied = await waitFor { coordinator.uppercaseHeadingLevels == [1] }
        XCTAssertTrue(applied)
        XCTAssertEqual(view.string, composing)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        preferences.markdownUppercaseHeadingLevels = []
        preferences.editorLigatures = nil
        let childDelivered = await waitFor { !coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(childDelivered)
        XCTAssertEqual(coordinator.uppercaseHeadingLevels, [1])
        child.unmarkText()
        let reset = await waitFor { coordinator.uppercaseHeadingLevels.isEmpty }
        XCTAssertTrue(reset)
        XCTAssertTrue(view.string.hasPrefix("# Straße"))
    }

    func testEditingSyntaxPreferencesUpdateNativeGlyphsWithoutEditingSource() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "hello --  world\n\nend"
        let raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        view.setSelectedRange(raw.range(of: "end"))
        let dash = raw.range(of: "--").location, spaces = raw.range(of: "  ").location
        func control(_ position: Int) -> Bool {
            layout.ensureLayout(for: container)
            return layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: position)).contains(.controlCharacter)
        }
        let initial = await waitFor { control(dash) && control(spaces) }
        XCTAssertTrue(initial)
        preferences.markdownSmartPunctuation = false
        preferences.markdownEditingWhitespace = true
        let restored = await waitFor { !control(dash) && !control(spaces) }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testNativePageBreakGeometryAndReveal() throws {
        _ = NSApplication.shared
        let markup = "<div style='page-break-after:always'></div>"
        let source = "before\n\n> " + markup + "\n\nafter", raw = source as NSString
        for orientation in [NSLayoutManager.TextLayoutOrientation.horizontal, .vertical] {
            let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
            let layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1_000))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            scroll.documentView = view
            view.setLayoutOrientation(orientation)
            let parsed = MarkdownPresentationParser.parse(source)
            let range = try XCTUnwrap(parsed.pageBreaks.first)
            XCTAssertEqual(raw.substring(with: range), markup)
            let after = raw.range(of: "after")
            layout.setMarkdownPresentation(parsed, revealedRange: after, inlineSelection: after)
            layout.ensureLayout(for: container)
            let rect = try XCTUnwrap(layout.markdownPageBreakRect(for: range, in: container))
            let physical = scroll.contentView.convert(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
            let local = scroll.contentView.convert(NSPoint(x: physical.midX, y: physical.midY), to: view)
            let hit = NSPoint(x: local.x - view.textContainerOrigin.x, y: local.y - view.textContainerOrigin.y)
            XCTAssertEqual(layout.markdownPageBreak(at: hit, in: container), range)
            layout.updateMarkdownRevealedRange(range)
            XCTAssertNil(layout.markdownPageBreakRect(for: range, in: container))
            layout.setMarkdownPresentation(nil, revealedRange: nil)
            XCTAssertEqual(storage.string, source)
            withExtendedLifetime(scroll) {}
        }
    }

    func testNativePageBreakClickCompositionAndUndo() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let markup = "<div style='page-break-after:always'></div>"
        let source = "before\n\n> " + markup + "\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer), range = raw.range(of: markup)
        view.setSelectedRange(raw.range(of: "end"))
        let ready = await waitFor { layout.ensureLayout(for: container); return layout.markdownPageBreakRect(for: range, in: container) != nil }
        XCTAssertTrue(ready)
        if let scroll = view.enclosingScrollView {
            scroll.allowsMagnification = true
            scroll.setMagnification(1.5, centeredAt: NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY))
        }
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownPageBreakRect(for: range, in: container))
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(view.selectedRange().location, range.location)
        XCTAssertNil(layout.markdownPageBreakRect(for: range, in: container))
        view.insertText("x", replacementRange: NSRange(location: range.location, length: 0))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        view.setSelectedRange(raw.range(of: "end"))
        let restored = await waitFor { layout.ensureLayout(for: container); return layout.markdownPageBreakRect(for: range, in: container) != nil }
        XCTAssertTrue(restored)
        let beforeMarked = try XCTUnwrap(layout.markdownPageBreakRect(for: range, in: container))
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        let selection = view.selectedRange()
        XCTAssertFalse(view.pageBreakHandler?(range) ?? true)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(layout.markdownPageBreakRect(for: range, in: container), beforeMarked)
        child.unmarkText(); child.removeFromSuperview()
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: raw.range(of: "end"))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.pageBreakHandler?(range) ?? true)
        XCTAssertEqual(layout.markdownPageBreakRect(for: range, in: container), beforeMarked)
        XCTAssertEqual((view.string as NSString).substring(with: range), markup)
        view.unmarkText()
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }

    func testNativePageBreakRequiresConfirmedHTMLContext() {
        let markup = "<div style='page-break-after:always'></div>"
        for source in ["`" + markup + "`", "<script>" + markup + "</script>", "<template>" + markup + "</template>", "<select>" + markup + "</select>", "<div style='page-break-after:always' onclick='x'></div>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).pageBreaks.isEmpty, source)
        }
        let source = "😀\r\n\r\n" + markup + "\r\n\r\n" + markup
        let ranges = MarkdownPresentationParser.parse(source).pageBreaks
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ranges.allSatisfy { (source as NSString).substring(with: $0) == markup })
    }

    func testMultilineStyledTabRevealsAndPreservesUndo() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownEditingWhitespace = false
        let source = "> first\r\n>   **中文\ttext** after\r\n\r\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer), tab = raw.range(of: "\t"), bold = raw.range(of: "**中文\ttext**")
        view.setSelectedRange(raw.range(of: "end"))
        func hidden() -> Bool {
            layout.ensureLayout(for: container)
            return layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: tab.location)).contains(.controlCharacter)
        }
        let formatted = await waitFor { hidden() }
        XCTAssertTrue(formatted)
        view.setSelectedRange(bold)
        let revealed = await waitFor { !hidden() }
        XCTAssertTrue(revealed)
        view.insertText("x", replacementRange: raw.range(of: "中文"))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        view.setSelectedRange(raw.range(of: "end"))
        let restored = await waitFor { hidden() }
        XCTAssertTrue(restored)
    }

    func testMultilineHTMLTabRevealsAndPreservesSource() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownEditingWhitespace = false
        let source = "> first\r\n>   <strong>中文\ttext</strong> after\r\n\r\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer), tab = raw.range(of: "\t"), strong = raw.range(of: "<strong>中文\ttext</strong>")
        view.setSelectedRange(raw.range(of: "end"))
        func hidden() -> Bool {
            layout.ensureLayout(for: container)
            return layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: tab.location)).contains(.controlCharacter)
        }
        let formatted = await waitFor { hidden() }
        XCTAssertTrue(formatted)
        view.setSelectedRange(strong)
        let revealed = await waitFor { !hidden() }
        XCTAssertTrue(revealed)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testMultilineMappedHTMLRevealsAndPreservesUndo() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "> first\r\n>   **<u>中文</u>** after\r\n\r\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let marked = raw.range(of: "**<u>中文</u>**")
        view.setSelectedRange(raw.range(of: "end"))
        let formatted = await waitFor { layout.isMarkdownMarkerHidden(at: marked.location) }
        XCTAssertTrue(formatted)
        view.setSelectedRange(marked)
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: marked.location))
        view.insertText("x", replacementRange: raw.range(of: "中文"))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        view.setSelectedRange(raw.range(of: "end"))
        let restored = await waitFor { layout.isMarkdownMarkerHidden(at: marked.location) }
        XCTAssertTrue(restored)
    }

    func testMultilineHTMLImageWithTabLoadsAndRevealsSource() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownEditingWhitespace = false
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let markup = "<img src='data:image/png;base64,\(png)' alt='中文'>"
        let source = "> first\r\n>   😀\t" + markup + " after\r\n\r\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer), range = raw.range(of: markup)
        view.setSelectedRange(raw.range(of: "end"))
        func imageVisible() -> Bool {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [range], in: container)[range] != nil
        }
        let loaded = await waitFor { imageVisible() }
        XCTAssertTrue(loaded)
        view.setSelectedRange(range)
        let revealed = await waitFor { !imageVisible() }
        XCTAssertTrue(revealed)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testMultilineMappedImageLoadsAndRevealsSource() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let markup = "![中文](data:image/png;base64,\(png))"
        let source = "first\r\n   " + markup + " after\r\n\r\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer), raw = source as NSString, image = raw.range(of: markup)
        view.setSelectedRange(raw.range(of: "end"))
        func imageVisible() -> Bool {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [image], in: container)[image] != nil
        }
        let loaded = await waitFor { imageVisible() }
        XCTAssertTrue(loaded)
        view.setSelectedRange(image)
        let revealed = await waitFor { !imageVisible() }
        XCTAssertTrue(revealed)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testStructuralWhitespaceRevealTypingAndComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "- [ ]    中文😀\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer), edge = NSRange(location: 6, length: 3)
        view.setSelectedRange((source as NSString).range(of: "end"))
        func hidden() -> Bool {
            layout.ensureLayout(for: container)
            return layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: edge.location)).contains(.controlCharacter)
        }
        let ready = await waitFor { hidden() }
        XCTAssertTrue(ready)
        view.setSelectedRange(edge)
        XCTAssertFalse(hidden())
        view.insertText(" ", replacementRange: edge)
        XCTAssertTrue(try XCTUnwrap(view.undoManager).canUndo)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, source)
        view.setSelectedRange(edge)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: edge)
        XCTAssertTrue(view.hasMarkedText())
        let composing = view.string
        view.unmarkText()
        XCTAssertEqual(view.string, composing)
    }

    func testDisplayNoneSpanStaysVisibleWhileEditing() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "before <span style='display:none;color:red'>**中文😀**</span> after\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer), text = raw.range(of: "中文😀"), marker = raw.range(of: "<span")
        view.setSelectedRange(raw.range(of: "end"))
        let formatted = await waitFor { layout.isMarkdownMarkerHidden(at: marker.location) }
        XCTAssertTrue(formatted)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: text, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0)
        view.setSelectedRange(text)
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: marker.location))
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testUnsupportedSpanKeepsSourceUntilStyleIsConfirmed() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.editorLigatures = 2
        let source = "before <span style='position:fixed'>**hidden**</span> after\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let raw = source as NSString, marker = raw.range(of: "**hidden**").location
        view.setSelectedRange(raw.range(of: "end"))
        let parsed = await waitFor { document.isMarkdownOutlineCurrent }
        XCTAssertTrue(parsed)
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: marker))
        let css = raw.range(of: "position:fixed")
        view.insertText("color:red", replacementRange: css)
        let changed = view.string as NSString
        view.setSelectedRange(changed.range(of: "end"))
        let updatedMarker = changed.range(of: "**hidden**").location
        let formatted = await waitFor { layout.isMarkdownMarkerHidden(at: updatedMarker) }
        XCTAssertTrue(formatted)
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, source)
        view.setSelectedRange(raw.range(of: "end"))
        let restored = await waitFor { document.isMarkdownOutlineCurrent && !layout.isMarkdownMarkerHidden(at: marker) }
        XCTAssertTrue(restored)
    }

    func testTableWhitespaceUpdatesWithoutChangingSource() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "| H | Other |\n|---|---|\n| 中文  **bold  text** | unchanged |\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        view.setSelectedRange((source as NSString).range(of: "end"))
        func cell(_ column: Int) -> FoldLayoutManager.TableAccessibilityCell? {
            layout.ensureLayout(for: container)
            return layout.visibleTableAccessibilityCells(in: container).first { $0.row == 1 && $0.cell.column == column }
        }
        let collapsed = await waitFor { cell(0)?.cell.displayText == "中文 bold text" }
        XCTAssertTrue(collapsed)
        preferences.markdownEditingWhitespace = true
        let preserved = await waitFor { cell(0)?.cell.displayText == "中文  bold  text" }
        XCTAssertTrue(preserved)
        let first = try XCTUnwrap(cell(0))
        XCTAssertTrue(coordinator.beginTableCell(first.cell.range, frame: first.frame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), cell: first.cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        preferences.markdownEditingWhitespace = false
        XCTAssertEqual(cell(0)?.cell.displayText, "中文  bold  text")
        child.unmarkText()
        XCTAssertEqual(cell(1)?.cell.displayText, "unchanged")
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        let restored = await waitFor { cell(0)?.cell.displayText == "中文 bold text" }
        XCTAssertTrue(restored)
    }

    func testTableKeyboardProofIsInvalidatedByHTMLContextEdit() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "| A | B | C | D |\n|---|---|---|---|\n| <span title='>'>edit</span> | <kbd>key</kbd> | [link](https://example.com) | <span style='color:red'>red</span> |\n\nbefore <iframe src='https://example.invalid' height='60'>fallback</iframe> after\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        window.makeFirstResponder(view)
        view.setSelectedRange((source as NSString).range(of: "end"))
        func cell(_ column: Int) -> FoldLayoutManager.TableAccessibilityCell? {
            layout.ensureLayout(for: container)
            return layout.visibleTableAccessibilityCells(in: container).first { $0.row == 1 && $0.cell.column == column }
        }
        let ready = await waitFor { cell(1)?.cell.displayRuns.contains(where: { $0.kind == .keyboard }) == true }
        XCTAssertTrue(ready)
        XCTAssertTrue(cell(3)?.cell.displayRuns.contains { if case .inlineStyle = $0.kind { return true }; return false } == true)
        let mediaReady = await waitFor { view.subviews.contains { $0 is WKWebView } }
        XCTAssertTrue(mediaReady)
        let first = try XCTUnwrap(cell(0))
        XCTAssertTrue(coordinator.beginTableCell(first.cell.range, frame: first.frame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), cell: first.cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let quote = (child.string as NSString).range(of: "'>'")
        guard quote.location != NSNotFound else { return XCTFail("Missing quoted attribute") }
        child.insertText("\"", replacementRange: NSRange(location: quote.location + 2, length: 1))
        let quoteOther = try XCTUnwrap(cell(1)?.cell)
        XCTAssertFalse(quoteOther.displayRuns.contains { $0.kind == .keyboard })
        XCTAssertTrue(quoteOther.displayText?.contains("<kbd>key</kbd>") == true)
        let rawLink = try XCTUnwrap(cell(2)?.cell)
        XCTAssertTrue(rawLink.displayRuns.isEmpty)
        XCTAssertTrue(rawLink.displayText?.contains("[link](https://example.com)") == true)
        XCTAssertTrue(try XCTUnwrap(cell(3)?.cell).displayRuns.isEmpty)
        XCTAssertTrue(view.subviews.contains { $0 === child })
        XCTAssertFalse(view.subviews.contains { $0 is WKWebView })
        XCTAssertFalse(child.frame.isEmpty)
        XCTAssertFalse(document.isMarkdownOutlineCurrent)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        let quoteRestored = await waitFor { cell(1)?.cell.displayRuns.contains(where: { $0.kind == .keyboard }) == true }
        XCTAssertTrue(quoteRestored)
        XCTAssertTrue(cell(3)?.cell.displayRuns.contains { if case .inlineStyle = $0.kind { return true }; return false } == true)
        child.insertText("<script>", replacementRange: NSRange(location: 0, length: 0))
        let other = try XCTUnwrap(cell(1)?.cell)
        XCTAssertFalse(other.displayRuns.contains { $0.kind == .keyboard })
        XCTAssertTrue(other.displayText?.contains("<kbd>key</kbd>") == true)
        XCTAssertTrue(view.string.contains("<script>"))
        child.insertText("x", replacementRange: NSRange(location: 8, length: 0))
        XCTAssertTrue(try XCTUnwrap(cell(2)?.cell).displayRuns.isEmpty)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        let restored = await waitFor { cell(1)?.cell.displayRuns.contains(where: { $0.kind == .keyboard }) == true }
        XCTAssertTrue(restored)
        let beforeComposition = view.string
        child.setMarkedText("<script>", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertEqual(view.string, beforeComposition)
        XCTAssertTrue(try XCTUnwrap(cell(1)?.cell).displayRuns.contains { $0.kind == .keyboard })
        child.unmarkText()
        XCTAssertTrue(view.string.contains("<script>"))
        XCTAssertTrue(try XCTUnwrap(cell(1)?.cell).displayRuns.isEmpty)
        XCTAssertTrue(view.subviews.contains { $0 === child })
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        let compositionRestored = await waitFor { cell(1)?.cell.displayRuns.contains(where: { $0.kind == .keyboard }) == true }
        XCTAssertTrue(compositionRestored)
    }

    func testInlineRevealPreservesTypingAndUndo() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "中文 **one** and *two*\n\nend"
        let raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        window.makeFirstResponder(view)
        let first = raw.range(of: "**one**"), second = raw.range(of: "*two*")
        let position = raw.range(of: "one").location + 1
        view.setSelectedRange(NSRange(location: position, length: 0))
        let ready = await waitFor { !layout.isMarkdownMarkerHidden(at: first.location) && layout.isMarkdownMarkerHidden(at: second.location) }
        XCTAssertTrue(ready)
        view.insertText("X", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, raw.replacingCharacters(in: NSRange(location: position, length: 0), with: "X"))
        let undo = try XCTUnwrap(view.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(view.string, source)
        view.setSelectedRange(NSRange(location: position, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        XCTAssertTrue(view.hasMarkedText())
        let composing = view.string
        view.unmarkText()
        let restored = await waitFor { layout.isMarkdownMarkerHidden(at: second.location + 1) }
        XCTAssertTrue(restored)
        XCTAssertEqual(view.string, composing)
    }

    func testDiagramContextMenuCopiesCurrentImageAndRejectsStaleSelection() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "```mermaid\nflowchart TD\nA[Start] --> B[End]\n```\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        window.makeFirstResponder(view)
        view.setSelectedRange((source as NSString).range(of: "end"))
        var hit: NSPoint?
        for _ in 0..<1500 {
            layout.ensureLayout(for: container)
            for y in stride(from: 10, through: 300, by: 10) {
                for x in stride(from: 10, through: 500, by: 20) {
                    let point = NSPoint(x: CGFloat(x), y: CGFloat(y))
                    if layout.markdownImageLocation(at: point, in: container) == 0 { hit = point; break }
                }
                if hit != nil { break }
            }
            if hit != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let point = try XCTUnwrap(hit)
        let viewPoint = NSPoint(x: point.x + view.textContainerOrigin.x, y: point.y + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        let item = try XCTUnwrap(menu.items.first { $0.title == L10n.tr("复制图表为图片") })
        board.clearContents()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let png = try XCTUnwrap(board.data(forType: .png))
        XCTAssertNotNil(NSBitmapImageRep(data: png))
        let save = try XCTUnwrap(menu.items.first { $0.title == L10n.tr("图表另存为…") })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, type) in [("diagram.svg", UTType.svg), ("diagram.png", UTType.png), ("diagram.jpg", UTType.jpeg)] {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
            let opened = await waitFor { window.attachedSheet is NSSavePanel }
            XCTAssertTrue(opened)
            let panel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
            panel.allowedContentTypes = [type]
            panel.directoryURL = directory
            panel.nameFieldStringValue = name
            try XCTUnwrap(panel.defaultButtonCell).performClick(nil)
            let url = directory.appendingPathComponent(name)
            let written = await waitFor { FileManager.default.fileExists(atPath: url.path) }
            XCTAssertTrue(written)
            let data = try Data(contentsOf: url)
            if type == .svg { XCTAssertTrue(XMLParser(data: data).parse()) }
            else { XCTAssertNotNil(NSBitmapImageRep(data: data)) }
        }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
        let cancelOpened = await waitFor { window.attachedSheet is NSSavePanel }
        XCTAssertTrue(cancelOpened)
        let cancelPanel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        cancelPanel.directoryURL = directory
        cancelPanel.nameFieldStringValue = "cancelled.png"
        window.endSheet(cancelPanel, returnCode: .cancel)
        let cancelClosed = await waitFor { window.attachedSheet == nil }
        XCTAssertTrue(cancelClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled.png").path))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(save.action), to: save.target, from: save))
        let opened = await waitFor { window.attachedSheet is NSSavePanel }
        XCTAssertTrue(opened)
        let panel = try XCTUnwrap(window.attachedSheet as? NSSavePanel)
        panel.directoryURL = directory
        panel.nameFieldStringValue = "stale.png"
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        try XCTUnwrap(panel.defaultButtonCell).performClick(nil)
        let closed = await waitFor { window.attachedSheet == nil }
        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stale.png").path))
        board.clearContents()
        board.setString("old", forType: .string)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testVerticalWritingWaitsForCompositionAndRestoresSourceLayout() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = String(repeating: "Latin 中文 ", count: 400) + "\nsecond line"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 2, length: 1))
        preferences.markdownVerticalWriting = true
        preferences.editorLigatures = 2
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertFalse(coordinator.markdownVerticalWriting)
        view.unmarkText()
        let enabled = await waitFor { coordinator.markdownVerticalWriting }
        XCTAssertTrue(enabled)
        XCTAssertEqual(view.layoutOrientation, .vertical)
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        let secondLine = (view.string as NSString).range(of: "second line")
        guard secondLine.location != NSNotFound else { return XCTFail("Missing second line") }
        layout.ensureLayout(for: container)
        let firstRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: 0), effectiveRange: nil)
        let secondRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: secondLine.location), effectiveRange: nil)
        let firstPhysical = scroll.contentView.convert(firstRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        let secondPhysical = scroll.contentView.convert(secondRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        XCTAssertNotEqual(firstPhysical.midX, secondPhysical.midX, accuracy: 0.5)
        let wrappedRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: secondLine.location - 2), effectiveRange: nil)
        let wrappedPhysical = scroll.contentView.convert(wrappedRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        XCTAssertNotEqual(firstPhysical.midX, wrappedPhysical.midX, accuracy: 0.5)
        let clip = scroll.contentView
        let documentRect = clip.convert(view.bounds, from: view)
        let extent = documentRect.width - clip.bounds.width
        XCTAssertGreaterThan(extent, 10)
        if extent > 10 {
            let target = documentRect.minX + extent * 0.75
            clip.scroll(to: NSPoint(x: target, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(clip)
            coordinator.prepareForEviction()
            let recorded = document.scrollPositionRatio
            XCTAssertGreaterThan(recorded, 0.5)
            clip.scroll(to: NSPoint(x: documentRect.minX, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(clip)
            coordinator.restoreViewportState()
            let restored = await waitFor { abs(clip.bounds.minX - target) < 2 }
            XCTAssertTrue(restored)
        }
        let edited = view.string
        let selection = view.selectedRange()
        document.isMarkdownFormatted = false
        let reset = await waitFor { !coordinator.markdownVerticalWriting }
        XCTAssertTrue(reset)
        XCTAssertEqual(view.layoutOrientation, .horizontal)
        XCTAssertEqual(view.string, edited)
        XCTAssertEqual(view.selectedRange(), selection)
    }

    func testVerticalSubviewCounterRotationKeepsPhysicalRectAndHit() throws {
        _ = NSApplication.shared
        let storage = NSTextStorage(string: "中文 Latin")
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: 1_000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        view.setLayoutOrientation(.vertical)
        let child = NSView(frame: .zero)
        view.addSubview(child)
        let sourceRect = NSRect(x: 20, y: 30, width: 80, height: 140)
        let clip = scroll.contentView
        let expected = clip.convert(sourceRect, from: view)
        view.placeMarkdownSubview(child, in: sourceRect)
        let actual = clip.convert(child.bounds, from: child)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
        let start = clip.convert(NSPoint(x: child.bounds.minX, y: child.bounds.minY), from: child)
        let right = clip.convert(NSPoint(x: child.bounds.minX + 10, y: child.bounds.minY), from: child)
        XCTAssertGreaterThan(right.x, start.x)
        XCTAssertEqual(right.y, start.y, accuracy: 0.5)
        let point = view.convert(NSPoint(x: expected.midX, y: expected.midY), from: clip)
        XCTAssertTrue(child.hitTest(point) === child)
        view.setLayoutOrientation(.horizontal)
        view.placeMarkdownSubview(child, in: sourceRect)
        XCTAssertEqual(child.frameRotation, 0, accuracy: 0.001)
        XCTAssertEqual(child.frame, sourceRect)
        XCTAssertTrue(child.hitTest(NSPoint(x: sourceRect.midX, y: sourceRect.midY)) === child)
        XCTAssertEqual(storage.string, "中文 Latin")
    }

    func testVerticalWritingImageUsesRenderedGeometryForHit() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownVerticalWriting = true
        let source = "before\n\n![图](a.png)\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.markdownVerticalWriting }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView)
        let layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let range = (source as NSString).range(of: "![图](a.png)")
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        layout.setMarkdownImage(NSImage(size: NSSize(width: 120, height: 80)), for: range)
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [range], in: container)[range])
        let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
        let physicalRect = clip.convert(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        XCTAssertEqual(physicalRect.width, 120, accuracy: 0.5)
        XCTAssertEqual(physicalRect.height, 80, accuracy: 0.5)
        let local = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        let physical = view.convert(local, to: nil)
        let restored = view.convert(physical, from: nil)
        let point = NSPoint(x: restored.x - view.textContainerOrigin.x, y: restored.y - view.textContainerOrigin.y)
        XCTAssertEqual(layout.markdownImageLocation(at: point, in: container), range.location)
        for orientation in [NSLayoutManager.TextLayoutOrientation.vertical, .horizontal] {
            view.setLayoutOrientation(orientation)
            container.containerSize.width = .greatestFiniteMagnitude
            layout.invalidateMarkdownLayout(in: range)
            layout.ensureLayout(for: container)
            let noWrap = try XCTUnwrap(layout.markdownRenderedImageRects(for: [range], in: container)[range])
            let frame = noWrap.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            XCTAssertTrue(frame.intersects(view.visibleRect))
        }
        XCTAssertEqual(view.string, source)
    }

    func testMultilineMappedFormulasKeepDistinctSourceAndReveal() throws {
        _ = NSApplication.shared
        let source = "> first\r\n>   中文 $x$ then $x$\r\n\r\nend", raw = source as NSString
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: container)
        let result = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(result.inlineFormulas.count, 2)
        let ranges = result.inlineFormulas.map(\.range)
        XCTAssertNotEqual(ranges.first, ranges.last)
        let end = raw.range(of: "end")
        layout.setMarkdownPresentation(result, revealedRange: end, inlineSelection: end)
        for range in ranges {
            XCTAssertEqual(raw.substring(with: range), "$x$")
            XCTAssertTrue(layout.setMarkdownInlineImage(NSImage(size: NSSize(width: 30, height: 20)), for: range))
        }
        layout.ensureLayout(for: container)
        XCTAssertEqual(layout.markdownRenderedImageRects(for: ranges, in: container).count, 2)
        if let first = ranges.first {
            layout.updateMarkdownRevealedRange(first)
            layout.ensureLayout(for: container)
            XCTAssertNil(layout.markdownRenderedImageRects(for: [first], in: container)[first])
        }
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testVerticalInlineFormulaKeepsPhysicalSizeAndReferenceHit() throws {
        _ = NSApplication.shared
        let source = "before $x$ after"
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1_000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        view.setLayoutOrientation(.vertical)
        view.setSelectedRange((source as NSString).range(of: "after"))
        let result = MarkdownPresentationParser.parse(source)
        layout.setMarkdownPresentation(result, revealedRange: (source as NSString).range(of: "after"))
        let formula = try XCTUnwrap(result.inlineFormulas.first)
        XCTAssertTrue(layout.setMarkdownInlineImage(NSImage(size: NSSize(width: 80, height: 30)), for: formula.range))
        let target = (source as NSString).range(of: "before")
        layout.setMarkdownMathReferences([(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), target: target)], for: formula.range)
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [formula.range], in: container)[formula.range])
        let clip = scroll.contentView
        let physical = clip.convert(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        XCTAssertEqual(physical.width, 80, accuracy: 0.5)
        XCTAssertEqual(physical.height, 30, accuracy: 0.5)
        let viewPoint = view.convert(NSPoint(x: physical.minX + physical.width * 0.25, y: physical.midY), from: clip)
        let point = NSPoint(x: viewPoint.x - view.textContainerOrigin.x, y: viewPoint.y - view.textContainerOrigin.y)
        XCTAssertEqual(layout.markdownMathReference(at: point, in: container)?.target, target)
        XCTAssertEqual(storage.string, source)
    }

    func testListStylesWaitForParentAndTableComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "1. item\n\n| A |\n|---|\n| cell |\n\nend", language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView)
        let location = (view.string as NSString).range(of: "end").location
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: location, length: 0))
        preferences.markdownListStyles.ordered[1] = .upperRoman
        preferences.editorLigatures = 2
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertNil(coordinator.listStyles.orderedStyle(at: 1))
        view.unmarkText()
        let parentApplied = await waitFor { coordinator.listStyles.orderedStyle(at: 1) == .upperRoman }
        XCTAssertTrue(parentApplied)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        preferences.markdownListStyles.ordered[1] = .lowerAlpha
        preferences.editorLigatures = 0
        let childDelivered = await waitFor { !coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(childDelivered)
        XCTAssertEqual(coordinator.listStyles.orderedStyle(at: 1), .upperRoman)
        child.unmarkText()
        let childApplied = await waitFor { coordinator.listStyles.orderedStyle(at: 1) == .lowerAlpha }
        XCTAssertTrue(childApplied)
        XCTAssertTrue(view.string.contains("1. item"))
        XCTAssertTrue(view.string.contains("文"))
    }

    func testMagnificationWaitsForTableCellComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "| A |\n|---|\n| cell |\n\nend", language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView)
        let scroll = try XCTUnwrap(coordinator.scrollView)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        XCTAssertFalse(scroll.allowsMagnification)
        coordinator.updateViewMagnification(1.5)
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        child.unmarkText()
        let applied = await waitFor { abs(scroll.magnification - 1.5) < 0.001 }
        XCTAssertTrue(applied)
        XCTAssertTrue(scroll.allowsMagnification)
        XCTAssertTrue(view.string.contains("中"))
    }

    func testVerticalWritingWaitsForTableCellComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "| A |\n|---|\n| cell |\n\nend", language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        preferences.markdownVerticalWriting = true
        preferences.editorLigatures = 2
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertFalse(coordinator.markdownVerticalWriting)
        XCTAssertNil(child.textStorage?.attribute(.verticalGlyphForm, at: 0, effectiveRange: nil))
        child.unmarkText()
        let enabled = await waitFor { coordinator.markdownVerticalWriting }
        XCTAssertTrue(enabled)
        XCTAssertEqual(view.layoutOrientation, .vertical)
        XCTAssertEqual((child.textStorage?.attribute(.verticalGlyphForm, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 1)
        XCTAssertTrue(view.string.contains("中"))
        let beforeEdit = view.string
        child.insertText("Z", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertNotEqual(view.string, beforeEdit)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, beforeEdit)
        coordinator.finishTableCell()
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        let layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let updatedCell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        let ready = await waitFor { layout.markdownTableFrame(for: updatedCell, in: container) != nil }
        XCTAssertTrue(ready)
        let frame = try XCTUnwrap(layout.markdownTableFrame(for: updatedCell, in: container))
        XCTAssertEqual(layout.markdownTableCellInfo(at: NSPoint(x: frame.midX, y: frame.midY), in: container)?.0.range, updatedCell.range)
        let point = NSPoint(x: frame.midX + view.textContainerOrigin.x, y: frame.midY + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        let active = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertEqual((active.textStorage?.attribute(.verticalGlyphForm, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 1)
        document.isMarkdownFormatted = false
        let reset = await waitFor { !coordinator.markdownVerticalWriting }
        XCTAssertTrue(reset)
        XCTAssertNil(active.textStorage?.attribute(.verticalGlyphForm, at: 0, effectiveRange: nil))
    }

    func testTableChildWritingDirectionWaitsForCompositionAndResetsInSourceMode() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownRightToLeft = true
        let document = EditorDocument(text: "| A |\n|---|\n| cell |", language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.foldLayoutManager?.markdownRightToLeft == true }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertEqual(child.defaultParagraphStyle?.baseWritingDirection, .rightToLeft)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        preferences.markdownRightToLeft = false
        preferences.editorLigatures = 2
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertEqual(child.defaultParagraphStyle?.baseWritingDirection, .rightToLeft)
        child.unmarkText()
        let restored = await waitFor { child.defaultParagraphStyle?.baseWritingDirection == .natural }
        XCTAssertTrue(restored)
        preferences.markdownRightToLeft = true
        let enabled = await waitFor { child.defaultParagraphStyle?.baseWritingDirection == .rightToLeft }
        XCTAssertTrue(enabled)
        document.isMarkdownFormatted = false
        coordinator.updateMarkdownPresentation()
        XCTAssertEqual(child.defaultParagraphStyle?.baseWritingDirection, .natural)
    }

    func testCompletedTaskStrikeWaitsForChildComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let source = "- [x] done\n- [ ] pending\n\n| A |\n|---|\n| cell |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView != nil }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        let parsed = await waitFor { coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell) }
        XCTAssertTrue(parsed)
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        preferences.markdownStrikeCompletedTasks = true
        preferences.editorLigatures = 2
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertFalse(coordinator.strikeCompletedTasks)
        child.unmarkText()
        let done = (view.string as NSString).range(of: "done").location
        guard done != NSNotFound else { XCTFail("Completed task disappeared"); return }
        let applied = await waitFor {
            coordinator.strikeCompletedTasks && layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: done, effectiveRange: nil) != nil
        }
        XCTAssertTrue(applied)
        let pending = (view.string as NSString).range(of: "pending").location
        guard pending != NSNotFound else { XCTFail("Pending task disappeared"); return }
        XCTAssertNil(layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: pending, effectiveRange: nil))
    }

    func testCompletedTaskStrikeAppliesToActiveTableCell() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.markdownStrikeCompletedTasks = true
        let source = "- [x] done\n\n  | A |\n  |---|\n  | cell |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.strikeCompletedTasks && coordinator.textView != nil }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let layout = try XCTUnwrap(child.layoutManager)
        XCTAssertNotNil(layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 0, effectiveRange: nil))
        child.insertText("Z", replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(view.string.contains("cZell"))
        XCTAssertNotNil(layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 1, effectiveRange: nil))
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        preferences.markdownStrikeCompletedTasks = false
        preferences.editorLigatures = 2
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertTrue(coordinator.strikeCompletedTasks)
        child.unmarkText()
        let cleared = await waitFor {
            !coordinator.strikeCompletedTasks && layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: 0, effectiveRange: nil) == nil
        }
        XCTAssertTrue(cleared)
        XCTAssertTrue(view.string.contains("中Zell"))
    }

    func testLigaturesWaitForParentAndChildComposition() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.editorLigatures = 0
        let source = "office\n\n| A |\n|---|\n| affinity |\n"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.editorLigatures == 0 }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView)
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertEqual((storage.attribute(.ligature, at: 1, effectiveRange: nil) as? NSNumber)?.intValue, 0)
        window.makeFirstResponder(view)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        preferences.editorLigatures = 2
        let parentDelivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(parentDelivered)
        XCTAssertEqual(coordinator.editorLigatures, 0)
        XCTAssertEqual((storage.attribute(.ligature, at: 2, effectiveRange: nil) as? NSNumber)?.intValue, 0)
        view.unmarkText()
        let parentApplied = await waitFor { coordinator.editorLigatures == 2 }
        XCTAssertTrue(parentApplied)
        XCTAssertEqual((storage.attribute(.ligature, at: 2, effectiveRange: nil) as? NSNumber)?.intValue, 2)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let childStorage = try XCTUnwrap(child.textStorage)
        XCTAssertEqual((childStorage.attribute(.ligature, at: 1, effectiveRange: nil) as? NSNumber)?.intValue, 2)
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        preferences.editorLigatures = 0
        let childDelivered = await waitFor { !coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(childDelivered)
        XCTAssertEqual(coordinator.editorLigatures, 2)
        XCTAssertEqual((childStorage.attribute(.ligature, at: 2, effectiveRange: nil) as? NSNumber)?.intValue, 2)
        child.unmarkText()
        let childApplied = await waitFor { coordinator.editorLigatures == 0 }
        XCTAssertTrue(childApplied)
        XCTAssertEqual((childStorage.attribute(.ligature, at: 2, effectiveRange: nil) as? NSNumber)?.intValue, 0)
    }

    func testLigaturesFollowScrollingAndResetVisibleText() async throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.editorLigatures = 2
        let source = String(repeating: "office affinity 中文\n", count: 600)
        let document = EditorDocument(text: source, language: .markdown)
        let sessions = EditorSessionStore(limit: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); window.close() }
        window.contentViewController = NSHostingController(rootView: LigatureHost(document: document, sessions: sessions, preferences: preferences))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.editorLigatures == 2 }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), storage = try XCTUnwrap(view.textStorage)
        let layout = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        func visibleEnd() -> Int {
            let rect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
            return NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        let oldEnd = visibleEnd()
        window.setContentSize(NSSize(width: 500, height: 500))
        let expanded = await waitFor { visibleEnd() > oldEnd && (storage.attribute(.ligature, at: visibleEnd() - 1, effectiveRange: nil) as? NSNumber)?.intValue == 2 }
        XCTAssertTrue(expanded)
        let end = (source as NSString).length - 5
        view.scrollRangeToVisible(NSRange(location: end, length: 1))
        let scrolled = await waitFor { (storage.attribute(.ligature, at: end, effectiveRange: nil) as? NSNumber)?.intValue == 2 }
        XCTAssertTrue(scrolled)
        preferences.editorLigatures = nil
        let resetEnd = await waitFor { storage.attribute(.ligature, at: end, effectiveRange: nil) == nil }
        XCTAssertTrue(resetEnd)
        view.scrollRangeToVisible(NSRange(location: 0, length: 1))
        let resetStart = await waitFor { storage.attribute(.ligature, at: 0, effectiveRange: nil) == nil }
        XCTAssertTrue(resetStart)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testNativeWidthCentresResizesAndKeepsHorizontalScrolling() async throws {
        _ = NSApplication.shared
        let source = "# 中😀\n\n" + String(repeating: "words ", count: 120)
        let document = EditorDocument(text: source, language: .markdown)
        let sessions = EditorSessionStore(limit: 1), options = Options()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); document.cancelMetricsRefresh(); window.close() }
        window.contentViewController = NSHostingController(rootView: Host(document: document, sessions: sessions, options: options))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView?.textContainer?.containerSize.width == 300 }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), scroll = try XCTUnwrap(view.enclosingScrollView)
        XCTAssertGreaterThan(view.textContainerInset.width, 100)
        XCTAssertEqual(view.textContainerInset.height, 8)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)

        window.setContentSize(NSSize(width: 240, height: 400))
        let narrowed = await waitFor { (view.textContainer?.containerSize.width ?? 1000) < 240 }
        XCTAssertTrue(narrowed)
        XCTAssertEqual(view.textContainerInset.width, 0, accuracy: 0.5)
        options.wrap = false
        let unwrapped = await waitFor { scroll.hasHorizontalScroller && view.textContainer?.containerSize.width == CGFloat.greatestFiniteMagnitude }
        XCTAssertTrue(unwrapped)
        XCTAssertEqual(view.textContainerInset.width, 0)
        window.setContentSize(NSSize(width: 800, height: 400))
        options.width = nil
        options.wrap = true
        let reset = await waitFor { !scroll.hasHorizontalScroller && (view.textContainer?.containerSize.width ?? 0) > 600 }
        XCTAssertTrue(reset)
        XCTAssertEqual(view.textContainerInset.width, 0)
        XCTAssertEqual(view.string, source)
    }

    func testWidthChangeWaitsForMarkedInput() async throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "text", language: .markdown)
        let sessions = EditorSessionStore(limit: 1), options = Options()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); document.cancelMetricsRefresh(); window.close() }
        window.contentViewController = NSHostingController(rootView: Host(document: document, sessions: sessions, options: options))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView?.textContainer?.containerSize.width == 300 }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView)
        window.makeFirstResponder(view)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        options.width = 200
        // Wait for SwiftUI to deliver the request while the composition is active.
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertEqual(view.textContainer?.containerSize.width, 300)
        view.unmarkText()
        let applied = await waitFor { view.textContainer?.containerSize.width == 200 }
        XCTAssertTrue(applied)
        XCTAssertTrue(view.string.contains("中"))
    }

    func testTOCLevelWaitsForParentAndTableComposition() async throws {
        _ = NSApplication.shared
        let source = "[toc]\n\n# One\n\n## Two\n\n| A |\n|---|\n| cell |\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1), options = Options()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); document.cancelMetricsRefresh(); window.close() }
        window.contentViewController = NSHostingController(rootView: Host(document: document, sessions: sessions, options: options))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let ready = await waitFor { coordinator.textView != nil && coordinator.foldLayoutManager != nil }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView), layout = try XCTUnwrap(coordinator.foldLayoutManager)
        window.makeFirstResponder(view)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: (source as NSString).length, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        options.tocLevel = 1
        let parentDelivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(parentDelivered)
        XCTAssertEqual(layout.markdownTOCMaxLevel, 6)
        view.unmarkText()
        let parentApplied = await waitFor { layout.markdownTOCMaxLevel == 1 }
        XCTAssertTrue(parentApplied)
        let current = view.string
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(current).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        options.tocLevel = 6
        let childDelivered = await waitFor { !coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(childDelivered)
        XCTAssertEqual(layout.markdownTOCMaxLevel, 1)
        child.unmarkText()
        let childApplied = await waitFor { layout.markdownTOCMaxLevel == 6 }
        XCTAssertTrue(childApplied)
        coordinator.finishTableCell()
        XCTAssertTrue(view.string.contains("文"))
    }

    func testWidthPreferenceDoesNotChangeFontOverridesAndRejectsInvalidValues() throws {
        let suite = "LacEditorTests.MarkdownWidth.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertNil(preferences.markdownMaximumWidth)
        preferences.markdownMaximumWidth = 450
        XCTAssertEqual(preferences.markdownTypography?.maximumWidth, 450)
        XCTAssertEqual(preferences.markdownTypography?.usesCustomFontMetrics, false)
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownMaximumWidth, 450)
        for value in [0.0, -1, .infinity, .nan] {
            preferences.markdownMaximumWidth = value
            XCTAssertEqual(preferences.markdownMaximumWidth, 450)
        }
        preferences.markdownMaximumWidth = nil
        XCTAssertNil(AppPreferences(defaults: defaults).markdownMaximumWidth)
        XCTAssertNil(preferences.markdownTypography)
    }

    func testTOCPreferencePersistsAndDoesNotEnableCustomFonts() throws {
        let suite = "LacEditorTests.MarkdownTOC.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.markdownTOCMaxLevel, 6)
        XCTAssertNil(preferences.markdownTypography)
        preferences.markdownTOCMaxLevel = 2
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownTOCMaxLevel, 2)
        XCTAssertEqual(preferences.markdownTypography?.tocMaxLevel, 2)
        XCTAssertEqual(preferences.markdownTypography?.usesCustomFontMetrics, false)
        for value in [0, -1, 7] {
            preferences.markdownTOCMaxLevel = value
            XCTAssertEqual(preferences.markdownTOCMaxLevel, 2)
        }
        preferences.markdownTOCMaxLevel = 6
        XCTAssertNil(preferences.markdownTypography)
        defaults.set(9, forKey: "markdownTOCMaxLevel")
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownTOCMaxLevel, 6)
    }

    func testTableCellCompositionDefersWidthAndKeepsHitGeometry() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let sessions = EditorSessionStore(limit: 1), options = Options()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { sessions.coordinator(for: document).updateActivity(false); document.cancelMetricsRefresh(); window.close() }
        window.contentViewController = NSHostingController(rootView: Host(document: document, sessions: sessions, options: options))
        window.makeKeyAndOrderFront(nil)
        let coordinator = sessions.coordinator(for: document)
        let range = (source as NSString).range(of: "one")
        let ready = await waitFor {
            guard let view = coordinator.textView, let container = view.textContainer,
                  let layout = coordinator.foldLayoutManager else { return false }
            return container.containerSize.width == 300 && layout.markdownTableFrame(for: range, in: container) != nil
        }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(coordinator.textView)
        let container = try XCTUnwrap(view.textContainer)
        let layout = try XCTUnwrap(coordinator.foldLayoutManager)
        let frame = try XCTUnwrap(layout.markdownTableFrame(for: range, in: container))
        XCTAssertTrue(coordinator.beginTableCell(range, frame: frame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        window.makeFirstResponder(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(child.hasMarkedText())
        options.width = 200
        let delivered = await waitFor { coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(delivered)
        XCTAssertEqual(container.containerSize.width, 300)
        child.unmarkText()
        let applied = await waitFor { container.containerSize.width == 200 }
        XCTAssertTrue(applied)
        let newRange = (view.string as NSString).range(of: "中")
        let updated = try XCTUnwrap(layout.markdownTableFrame(for: newRange, in: container))
        let expectedFrame = updated.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertEqual(child.frame.minX, expectedFrame.minX, accuracy: 0.5)
        XCTAssertEqual(child.frame.width, expectedFrame.width, accuracy: 0.5)
        coordinator.finishTableCell()
        let hit = try XCTUnwrap(layout.markdownTableCellInfo(at: NSPoint(x: updated.midX, y: updated.midY), in: container))
        XCTAssertEqual(hit.0.range, newRange)
        XCTAssertGreaterThan(view.textContainerInset.width, 0)
        XCTAssertTrue(coordinator.beginTableCell(newRange, frame: expectedFrame))
        let cancelled = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        window.makeFirstResponder(cancelled)
        cancelled.setMarkedText("临时", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 1))
        XCTAssertTrue(cancelled.hasMarkedText())
        options.width = 260
        let cancelDelivered = await waitFor { !coordinator.isMarkdownOutlineVisible }
        XCTAssertTrue(cancelDelivered)
        XCTAssertEqual(container.containerSize.width, 200)
        cancelled.insertText("中", replacementRange: cancelled.markedRange())
        let cancelApplied = await waitFor { container.containerSize.width == 260 }
        XCTAssertTrue(cancelApplied)
        XCTAssertEqual(view.string, (source as NSString).replacingCharacters(in: range, with: "中"))
    }
}
