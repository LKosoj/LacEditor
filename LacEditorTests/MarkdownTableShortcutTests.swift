import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownTableShortcutTests: XCTestCase {
    func testRowShortcutDoesNotRunDuringMarkedInput() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let child = MarkdownTableCellEditor(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(child)
        window.makeFirstResponder(child)
        var commands = 0
        child.rowCommand = { _ in commands += 1; return true }
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        child.keyDown(with: event)
        XCTAssertEqual(commands, 0)
    }

    func testVirtualRowShortcutAndHeaderRefusal() throws {
        _ = NSApplication.shared
        let source = "| A | B | C |\r\n| --- | --- | --- |\r\n| x"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
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
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let header = try XCTUnwrap(table.rows.first?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(header.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: header))
        var child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        child.keyDown(with: delete)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(view.subviews.contains { $0 === child })
        let virtual = try XCTUnwrap(table.rows.last?.cells.last)
        XCTAssertEqual(virtual.virtualSeparators, 2)
        XCTAssertTrue(coordinator.beginTableCell(virtual.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: virtual))
        child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        child.keyDown(with: enter)
        XCTAssertEqual(view.string, source + "\r\n|   |   |   ")
        XCTAssertEqual(MarkdownPresentationParser.parse(view.string).tables.first?.rows.count, 3)
        XCTAssertNotNil(view.subviews.first { $0 is MarkdownTableCellEditor })
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }

    func testRowShortcutsUseActiveCellAndUndo() throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
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
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        func event(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }
        child.keyDown(with: try event(36, .command, "\r"))
        let inserted = source + "\n|   |   |"
        XCTAssertEqual(view.string, inserted)
        let newChild = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        newChild.keyDown(with: try event(51, [.command, .shift], "\u{7f}"))
        XCTAssertEqual(view.string, source)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, inserted)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }
}
