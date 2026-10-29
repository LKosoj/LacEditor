import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownLinkTableTests: XCTestCase {
    func testManyLinksInOneTableCellKeepExactRanges() {
        let items = (0..<400).map { "[x\($0)](file\($0).md)" }
        let source = "| A |\n|---|\n| 中\\|😀 " + items.joined(separator: " ") + " |"
        let parsed = MarkdownPresentationParser.parse(source)
        let raw = source as NSString
        XCTAssertEqual(parsed.links.count, items.count)
        XCTAssertEqual(parsed.links.map { raw.substring(with: $0.range) }, items)
    }

    func testTableLinkRunsMapToOriginalUTF16Ranges() throws {
        let source = "| A |\r\n|---|\r\n| 中\\|😀 **[one](a.md)** [two][id] |\r\n\r\n[id]: b.md"
        let parsed = MarkdownPresentationParser.parse(source)
        let cell = try XCTUnwrap(parsed.tables.first?.rows.last?.cells.first)
        let links = cell.displayRuns.filter { $0.kind == .link }
        XCTAssertEqual(links.count, 2)
        let raw = source as NSString
        XCTAssertEqual(links.compactMap { run -> String? in
            guard let relative = run.sourceRange else { return nil }
            return raw.substring(with: NSRange(location: cell.range.location + relative.location, length: relative.length))
        }, ["[one](a.md)", "[two][id]"])
        let display = try XCTUnwrap(cell.displayText) as NSString
        XCTAssertEqual(links.map { display.substring(with: $0.range) }, ["one", "two"])
    }

    func testVisibleTableLinkHitUsesRenderedFormulaAttachment() throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 [one](a.md) [$x$](b.md) |"
        let parsed = MarkdownPresentationParser.parse(source)
        let cell = try XCTUnwrap(parsed.tables.first?.rows.last?.cells.first)
        let formula = try XCTUnwrap(parsed.inlineFormulas.first)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        XCTAssertTrue(layout.setMarkdownInlineImage(image, for: formula.range))
        layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
        let frame = try XCTUnwrap(layout.markdownTableFrame(for: cell, in: container))
        var found = Set<NSRange>()
        for y in stride(from: frame.minY + 4, to: frame.maxY - 4, by: 2) {
            for x in stride(from: frame.minX + 4, to: frame.maxX - 4, by: 2) {
                if let range = layout.markdownTableLinkRange(at: NSPoint(x: x, y: y), in: container) { found.insert(range) }
            }
        }
        XCTAssertEqual(found, Set(parsed.links.map(\.range)))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testCommandClickInInactiveAndActiveCellNavigatesAndPreservesMarkedText() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n|---|---|\n| first | [click](#target) |\n\n# Target"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 500), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        manager.activate(windowID: id)
        window.makeFirstResponder(view)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let parsed = MarkdownPresentationParser.parse(source)
        let row = try XCTUnwrap(parsed.tables.first?.rows.last)
        let cell = try XCTUnwrap(row.cells.last)
        let link = try XCTUnwrap(parsed.links.first), heading = try XCTUnwrap(parsed.headings.first)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var frame: NSRect?, hit: NSPoint?
        for _ in 0..<100 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            if let candidate = layout.markdownTableFrame(for: cell, in: container) {
                frame = candidate
                for y in stride(from: candidate.minY + 4, to: candidate.maxY - 4, by: 2) {
                    for x in stride(from: candidate.minX + 4, to: candidate.maxX - 4, by: 2) {
                        let point = NSPoint(x: x, y: y)
                        if layout.markdownTableLinkRange(at: point, in: container) == link.range { hit = point; break }
                    }
                    if hit != nil { break }
                }
            }
            if hit != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        func event(_ target: NSView, point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: target.convert(point, to: nil), modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let cellPoint = try XCTUnwrap(hit)
        let point = NSPoint(x: cellPoint.x + view.textContainerOrigin.x, y: cellPoint.y + view.textContainerOrigin.y)
        view.mouseDown(with: try event(view, point: point))
        for _ in 0..<100 where view.selectedRange().location != heading.range.location { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(view.selectedRange(), NSRange(location: heading.range.location, length: 0))
        XCTAssertTrue(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty)
        let firstCell = try XCTUnwrap(row.cells.first)
        let firstFrame = try XCTUnwrap(layout.markdownTableFrame(for: firstCell, in: container))
        XCTAssertTrue(coordinator.beginTableCell(firstCell.range, frame: firstFrame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), cell: firstCell))
        let firstChild = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        firstChild.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        view.mouseDown(with: try event(view, point: point))
        XCTAssertTrue(firstChild.hasMarkedText())
        XCTAssertTrue(view.subviews.contains(firstChild))
        firstChild.unmarkText()
        XCTAssertEqual(firstChild.undoAction?(false), true)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        view.mouseDown(with: try event(view, point: point))
        for _ in 0..<100 where view.selectedRange().location != heading.range.location { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(view.selectedRange(), NSRange(location: heading.range.location, length: 0))
        XCTAssertFalse(view.subviews.contains(firstChild))
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: try XCTUnwrap(frame).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let childLayout = try XCTUnwrap(child.layoutManager), childContainer = try XCTUnwrap(child.textContainer)
        childLayout.ensureLayout(for: childContainer)
        let character = (child.string as NSString).range(of: "click").location
        let glyph = childLayout.glyphIndexForCharacter(at: character)
        let rect = childLayout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: childContainer)
        let childPoint = NSPoint(x: rect.midX + child.textContainerOrigin.x, y: rect.midY + child.textContainerOrigin.y)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        child.mouseDown(with: try event(child, point: childPoint))
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertTrue(view.subviews.contains(child))
        child.unmarkText()
        // Restore source before testing the normal click without an intervening edit.
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        childLayout.ensureLayout(for: childContainer)
        child.mouseDown(with: try event(child, point: childPoint))
        for _ in 0..<100 where view.subviews.contains(child) || view.selectedRange().location != heading.range.location { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(view.selectedRange(), NSRange(location: heading.range.location, length: 0))
        XCTAssertFalse(view.subviews.contains(child))
        XCTAssertEqual(view.string, source)
    }
}
