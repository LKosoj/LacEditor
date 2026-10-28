import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownPresentationTests: XCTestCase {
    func testFormattingAndReturningToSourcePreserveTextAndSelection() async throws {
        _ = NSApplication.shared
        let source = "# Заголовок\n\n**中文 😀** and *text*"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), textContainer: container)
        view.font = lacEditorFont(size: 14)
        let selection = NSRange(location: 2, length: 3)
        view.setSelectedRange(selection)
        layout.ensureLayout(for: container)
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        var geometryChanges = 0
        controller.geometryDidChange = { geometryChanges += 1 }
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        let headingFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(headingFont.pointSize, layout.textFont.pointSize)
        var attributeEdits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in attributeEdits += 1 }
        let previousGeometryChanges = geometryChanges
        for _ in 0..<5 { controller.viewportChanged() }
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(attributeEdits, 0)
        XCTAssertEqual(geometryChanges, previousGeometryChanges)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        controller.selectionChanged()
        XCTAssertGreaterThan(geometryChanges, previousGeometryChanges)
        let selectionGeometryChanges = geometryChanges
        controller.selectionChanged()
        XCTAssertEqual(geometryChanges, selectionGeometryChanges)
        let insertion = NSRange(location: 0, length: 0)
        controller.beforeEdit(range: insertion, replacementLength: 1)
        storage.replaceCharacters(in: insertion, with: "x")
        revision += 1
        controller.edited(revision: revision)
        try await Task.sleep(for: .milliseconds(500))
        var typing = view.typingAttributes
        typing[.font] = layout.markdownHeadingFont(level: 1)
        view.typingAttributes = typing
        controller.update(document: document, enabled: false, isActive: true, revision: revision, currentRevision: { revision })
        XCTAssertEqual(view.string, "x" + source)
        let restoredFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(restoredFont.pointSize, layout.textFont.pointSize)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("z", replacementRange: view.selectedRange())
        let insertedFont = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(insertedFont.pointSize, layout.textFont.pointSize)
        XCTAssertEqual(view.string, "zx" + source)
    }

    func testInactiveEditorWaitsUntilActivationToApplyFormatting() async throws {
        _ = NSApplication.shared
        let source = "# Heading"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.font = lacEditorFont(size: 14)
        layout.ensureLayout(for: container)
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        controller.update(document: document, enabled: true, isActive: false, revision: 0, currentRevision: { 0 })
        try await Task.sleep(for: .milliseconds(300))
        let inactiveFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(inactiveFont.pointSize, layout.textFont.pointSize)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        try await Task.sleep(for: .milliseconds(500))
        let activeFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(activeFont.pointSize, layout.textFont.pointSize)
        XCTAssertEqual(view.string, source)
    }

    func testFormattingTogglePreservesUndoAndRedo() async throws {
        _ = NSApplication.shared
        let source = "# Heading\nbody"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.font = lacEditorFont(size: 14)
        view.isRichText = false
        view.allowsUndo = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.makeFirstResponder(view)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        undo.beginUndoGrouping()
        view.insertText("!", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(view.string, source + "!")
        XCTAssertTrue(undo.canUndo)

        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        XCTAssertFalse(document.isDirty)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont,
               font.pointSize > layout.textFont.pointSize { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let formattedFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(formattedFont.pointSize, layout.textFont.pointSize)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(view.string, source + "!")
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(view.string, source + "!")
    }

}
