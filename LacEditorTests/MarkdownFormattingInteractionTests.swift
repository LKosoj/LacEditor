import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownFormattingInteractionTests: XCTestCase {
    func testCommandUsesActiveEditorAndOneUndo() throws {
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
