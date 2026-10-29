import AppKit
import SwiftUI
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownNativeTableInteractionTests: XCTestCase {
    func testAnimatedTableImagePausesWhileCellEditorIsOpen() async throws {
        _ = NSApplication.shared
        let gif = "R0lGODlhBAAEAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAAEAAAICQABCBxIsCCAgAAh+QQBCgABACwAAAAABAAEAIEAAP8AAAAAAAAAAAAICQABCBxIsCCAgAA7"
        let source = "before\n\n| A | B |\n|---|---|\n| ![x](data:image/gif;base64,\(gif)) | ![y](data:image/gif;base64,\(gif)) |\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 400), textContainer: container)
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
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        for _ in 0..<200 where view.subviews.compactMap({ $0 as? NSImageView }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let frame = try XCTUnwrap(layout.markdownTableFrame(for: cell, in: container)).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let gifViews = view.subviews.compactMap { $0 as? NSImageView }
        XCTAssertEqual(gifViews.count, 2)
        let gifView = try XCTUnwrap(gifViews.first { $0.frame.intersects(frame) })
        let neighbor = try XCTUnwrap(gifViews.first { $0 !== gifView })
        var opened = false
        for _ in 0..<200 {
            if coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell) { opened = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(opened)
        XCTAssertNil(gifView.superview)
        XCTAssertFalse(gifView.animates)
        XCTAssertNotNil(neighbor.superview)
        XCTAssertTrue(neighbor.animates)
        coordinator.finishTableCell()
        for _ in 0..<200 where gifView.superview == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(gifView.superview)
        XCTAssertTrue(gifView.animates)
        XCTAssertEqual(storage.string, source)
    }
    func testSmartSubstitutionUsesActiveTableCellSourceRange() async throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 hello `code` |\n"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 400), textContainer: container)
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
        defer { coordinator.updateActivity(false); window.close() }
        window.makeKeyAndOrderFront(nil)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 250, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        let text = child.string as NSString
        let plain = NSTextCheckingResult.quoteCheckingResult(range: text.range(of: "hello"), replacementString: "“")
        let code = NSTextCheckingResult.dashCheckingResult(range: text.range(of: "code"), replacementString: "—")
        let options = try XCTUnwrap(child.beginTextChecking?([:]))
        XCTAssertEqual(child.filterTextCheckingResults?([plain, code], options).map(\.resultType), [.quote])
        child.insertText("x", replacementRange: NSRange(location: (child.string as NSString).length, length: 0))
        XCTAssertTrue(child.filterTextCheckingResults?([plain], options).isEmpty == true)
        for _ in 0..<200 where !document.isMarkdownOutlineCurrent { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        let newOptions = try XCTUnwrap(child.beginTextChecking?([:]))
        XCTAssertEqual(child.filterTextCheckingResults?([plain], newOptions).map(\.resultType), [.quote])
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: child.selectedRange())
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertTrue(child.filterTextCheckingResults?([plain], newOptions).isEmpty == true)
        child.unmarkText()
    }
    func testEmojiCompletionInActiveTableCellKeepsSourceAndUndo() async throws {
        _ = NSApplication.shared
        for (marked, virtual) in [(false, false), (true, false), (false, true)] {
            let source = virtual ? "| A | B | C |\n| --- | --- | --- |\n| 中文😀 |" : "| A |\n|---|\n| 中\\|😀  |\n\nafter"
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 400), textContainer: container)
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
            window.makeKeyAndOrderFront(nil)
            let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.last)
            var opened = false
            for _ in 0..<200 {
                if coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell) { opened = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(opened)
            let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
            child.setSelectedRange(NSRange(location: (child.string as NSString).length, length: 0))
            for (character, key, shift) in [(":", UInt16(41), true), ("s", UInt16(1), false), ("m", UInt16(46), false)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: key))
                child.keyDown(with: event)
            }
            for _ in 0..<200 where !child.emojiCompletionValues.contains(":smile:") { try await Task.sleep(for: .milliseconds(20)) }
            let range = try XCTUnwrap(child.emojiCompletionRange)
            let before = view.string
            if marked {
                child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: child.selectedRange())
                XCTAssertTrue(child.hasMarkedText())
                XCTAssertNil(child.emojiCompletionRange)
                XCTAssertFalse(child.acceptEmojiCompletion?(":smile:", range) ?? true)
                child.unmarkText()
                XCTAssertNil(child.emojiCompletionRange)
                continue
            }
            child.insertCompletion(":smile:", forPartialWordRange: range, movement: 0, isFinal: true)
            if virtual { XCTAssertTrue(view.string.contains("| 中文😀 ||:smile:|")) }
            else { XCTAssertTrue(view.string.contains("中\\|😀  :smile:")) }
            XCTAssertEqual(child.undoAction?(false), true)
            XCTAssertEqual(view.string, before)
        }
    }

    func testEmojiTableCellEditingAndUndoRestoresRenderedAttachment() async throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 :smile: |\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        document.markSaved()
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 400), textContainer: container)
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
        coordinator.attachLiveTextProvider()
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source, includeEmojiCandidates: true).tables.first?.rows.last?.cells.first)
        func hasAttachment() -> Bool {
            layout.tableCellAttributedText(cell, text: storage.mutableString).string.contains("\u{fffc}")
        }
        for _ in 0..<200 where !hasAttachment() { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(hasAttachment())
        layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
        let table = try XCTUnwrap(view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first)
        let row = try XCTUnwrap(table.accessibilityRows()?.last as? MarkdownTableAccessibilityRow)
        let accessibleCell = try XCTUnwrap(row.accessibilityChildren()?.first as? NSAccessibilityElement)
        let label = try XCTUnwrap(accessibleCell.accessibilityLabel())
        XCTAssertTrue(label.contains("😄"))
        XCTAssertFalse(label.contains(":smile:"))
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 180, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertTrue(child.string.contains(":smile:"))
        let insertion = NSRange(location: (child.string as NSString).length, length: 0)
        child.insertText("!", replacementRange: insertion)
        XCTAssertTrue(view.string.contains(":smile: !"))
        XCTAssertFalse(hasAttachment())
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        coordinator.finishTableCell()
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        for _ in 0..<200 where !hasAttachment() { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(hasAttachment())
        XCTAssertEqual(storage.string, source)
    }

    func testLazyTableRowsShiftOnlyFollowingRanges() {
        let rows = (0..<10_000).map { index in
            MarkdownTableRow(range: NSRange(location: index * 10, length: 5),
                cells: [MarkdownTableCell(range: NSRange(location: index * 10 + 1, length: 2), column: 0, displayText: "ab")])
        }
        let original = MarkdownTableRows(rows)
        let changed = MarkdownTableRow(range: NSRange(location: 50_000, length: 7),
            cells: [MarkdownTableCell(range: NSRange(location: 50_001, length: 4), column: 0, displayText: "abcd")])
        let first = original.replacing(5_000, row: changed, delta: 2)
        XCTAssertEqual(first[4_999], original[4_999])
        XCTAssertEqual(first[5_000], changed)
        XCTAssertEqual(first.range(at: 9_999).location, original.range(at: 9_999).location + 2)
        XCTAssertEqual(first[9_999].cells[0].displayText, "ab")
        let second = first.replacing(5_000, row: rows[5_000], delta: -2)
        XCTAssertEqual(second.range(at: 9_999), original.range(at: 9_999))
        XCTAssertEqual(second, original)
        let other = MarkdownTableRow(range: NSRange(location: 100, length: 8),
            cells: [MarkdownTableCell(range: NSRange(location: 101, length: 5), column: 0, displayText: "abcde")])
        let switched = first.replacing(10, row: other, delta: 3)
        XCTAssertEqual(switched[10], other)
        XCTAssertEqual(switched[5_000].range.location, changed.range.location + 3)
        XCTAssertEqual(switched.range(at: 9_999).location, original.range(at: 9_999).location + 5)
    }

    func testMeasureTypingInOneLargeTable() throws {
        _ = NSApplication.shared
        let line = "| " + String(repeating: "x", count: 100) + " | y |\n"
        let source = "| A | B |\n| --- | --- |\n" + String(repeating: line, count: 5_000)
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
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows[1].cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 150, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        measure {
            for _ in 0..<10 {
                child.insertText("z", replacementRange: NSRange(location: 1, length: 0))
                XCTAssertEqual(child.undoAction?(false), true)
            }
        }
        XCTAssertEqual(view.string, source)
    }
    func testAccessibilityCellCannotActivateAfterScrollingAway() async throws {
        _ = NSApplication.shared
        let source = "| A | B | C |\n| --- | --- | --- |\n" + String(repeating: "| one | two | three |\n", count: 299) + "| x"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 10000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 10000), textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "one").location, length: 0))
        var table: MarkdownTableAccessibilityTable?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            table = view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first
            if table != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let row = try XCTUnwrap(try XCTUnwrap(table?.accessibilityVisibleRows()).last as? MarkdownTableAccessibilityRow)
        let cell = try XCTUnwrap(try XCTUnwrap(row.accessibilityChildren()).first as? NSAccessibilityElement)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2500))
        scroll.reflectScrolledClipView(scroll.contentView)
        layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
        XCTAssertTrue(table?.accessibilityRows()?.isEmpty == true)
        XCTAssertEqual(row.accessibilityFrame(), .zero)
        XCTAssertFalse(cell.accessibilityPerformPress())
        let current = try XCTUnwrap(view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first)
        let selectedRow = try XCTUnwrap(current.accessibilitySelectedRows()?.first as? MarkdownTableAccessibilityRow)
        XCTAssertEqual(selectedRow.accessibilityIndex(), 1)
        XCTAssertEqual((current.accessibilitySelectedCells()?.first as? NSAccessibilityElement)?.accessibilityLabel(), "one")
        let allRows = try XCTUnwrap(current.accessibilityRows())
        XCTAssertEqual(allRows.count, 301)
        let farRow = try XCTUnwrap(allRows.last as? MarkdownTableAccessibilityRow)
        XCTAssertEqual(farRow.accessibilityFrame(), .zero)
        let farCells = try XCTUnwrap(farRow.accessibilityChildren())
        XCTAssertEqual(farCells.count, 3)
        let farCell = try XCTUnwrap(farCells.last as? NSAccessibilityElement)
        XCTAssertEqual(farCell.accessibilityLabel(), "")
        XCTAssertEqual(farCell.accessibilityColumnIndexRange(), NSRange(location: 2, length: 1))
        let reveal = try XCTUnwrap(farCell.accessibilityCustomActions()?.first { $0.name == L10n.tr("定位") })
        XCTAssertEqual(reveal.handler?(), true)
        XCTAssertGreaterThan(view.visibleRect.minY, 1000)
        XCTAssertTrue(current.accessibilityRows()?.isEmpty == true)
        let revealed = try XCTUnwrap(view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first)
        let revealedCell = try XCTUnwrap(revealed.accessibilitySelectedCells()?.first as? NSAccessibilityElement)
        XCTAssertEqual(revealedCell.accessibilityColumnIndexRange(), NSRange(location: 2, length: 1))
        XCTAssertTrue(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty)
    }
    func testVisibleTableAccessibilityCellOpensEditorAndRejectsStale() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| **中😀** | [link](https://example.com) |\n\noutside"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 250))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 250), textContainer: container)
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
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var table: MarkdownTableAccessibilityTable?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            table = view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first
            if table != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let accessibleTable = try XCTUnwrap(table)
        XCTAssertEqual(accessibleTable.accessibilityRowCount(), 2)
        XCTAssertEqual(accessibleTable.accessibilityColumnCount(), 2)
        let headers = try XCTUnwrap(accessibleTable.accessibilityColumnHeaderUIElements())
        XCTAssertEqual(headers.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }, ["A", "B"])
        let rows = try XCTUnwrap(accessibleTable.accessibilityRows())
        XCTAssertEqual(rows.count, 2)
        let row = try XCTUnwrap(rows.last as? MarkdownTableAccessibilityRow)
        let cells = try XCTUnwrap(row.accessibilityChildren())
        XCTAssertEqual(cells.count, 2)
        let cell = try XCTUnwrap(cells.first as? NSAccessibilityElement)
        XCTAssertEqual(cell.accessibilityLabel(), "中😀")
        XCTAssertEqual(cell.accessibilityRowIndexRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(cell.accessibilityColumnIndexRange(), NSRange(location: 0, length: 1))
        XCTAssertTrue(cell.accessibilityPerformPress())
        XCTAssertNotNil(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertTrue(accessibleTable.accessibilityRows()?.isEmpty == true)
        let selectedTable = try XCTUnwrap(view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first)
        XCTAssertEqual(selectedTable.accessibilitySelectedRows()?.count, 1)
        XCTAssertEqual(selectedTable.accessibilitySelectedCells()?.count, 1)
        let selectedRow = try XCTUnwrap(selectedTable.accessibilitySelectedRows()?.first as? MarkdownTableAccessibilityRow)
        let selected = try XCTUnwrap(selectedTable.accessibilitySelectedCells()?.first as? NSAccessibilityElement)
        XCTAssertTrue(selected.isAccessibilitySelected())
        XCTAssertTrue(selectedRow.isAccessibilitySelected())
        coordinator.finishTableCell()
        XCTAssertFalse(selected.isAccessibilitySelected())
        XCTAssertEqual(selected.accessibilityFrame(), .zero)
        XCTAssertFalse(selectedRow.isAccessibilitySelected())
        let refreshed = try XCTUnwrap(view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first)
        let refreshedRow = try XCTUnwrap(refreshed.accessibilityRows()?.last as? MarkdownTableAccessibilityRow)
        let refreshedCell = try XCTUnwrap(refreshedRow.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertTrue(refreshedCell.accessibilityPerformPress())
        let active = try XCTUnwrap(view.accessibilityChildren()?.compactMap { $0 as? MarkdownTableAccessibilityTable }.first)
        let activeCell = try XCTUnwrap(active.accessibilitySelectedCells()?.first as? NSAccessibilityElement)
        let action = try XCTUnwrap(activeCell.accessibilityCustomActions()?.first { $0.name == L10n.tr("右移列") })
        XCTAssertEqual(action.handler?(), true)
        XCTAssertFalse(selected.isAccessibilitySelected())
        XCTAssertEqual(selected.accessibilityFrame(), .zero)
        XCTAssertFalse(selectedRow.isAccessibilitySelected())
        XCTAssertTrue(view.string.contains("| B | A |"))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        coordinator.updateActivity(false)
        XCTAssertFalse(cell.accessibilityPerformPress())
    }
    func testDragDoesNotApplyAfterSourceChanges() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | x |\n| two | y |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let first = table.rows[1].cells[0], last = table.rows[2].cells[0]
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
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
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var firstFrame: NSRect?, lastFrame: NSRect?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            firstFrame = layout.markdownTableFrame(for: first, in: container)
            lastFrame = layout.markdownTableFrame(for: last, in: container)
            if firstFrame != nil && lastFrame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let startRect = try XCTUnwrap(firstFrame), endRect = try XCTUnwrap(lastFrame)
        XCTAssertTrue(coordinator.beginTableCell(first.range, frame: startRect, cell: first))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            let inView = NSPoint(x: point.x + view.textContainerOrigin.x, y: point.y + view.textContainerOrigin.y)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, NSPoint(x: startRect.minX - 6, y: startRect.midY)))
        XCTAssertTrue(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty)
        view.insertText("!", replacementRange: NSRange(location: (source as NSString).length, length: 0))
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: endRect.midX, y: endRect.midY)))
        XCTAssertEqual(view.string, source + "!")
    }
    func testClickOtherCellKeepsMarkedComposition() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |\n\noutside"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let first = table.rows.last!.cells[0], second = table.rows.last!.cells[1]
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var target: NSRect?, firstFrame: NSRect?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            target = layout.markdownTableFrame(for: second, in: container)
            firstFrame = layout.markdownTableFrame(for: first, in: container)
            if target != nil && firstFrame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let rect = try XCTUnwrap(target)
        XCTAssertTrue(coordinator.beginTableCell(first.range, frame: try XCTUnwrap(firstFrame), cell: first))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        let childText = child.string, childSelection = child.selectedRange(), parentSelection = view.selectedRange()
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertEqual(child.string, childText)
        XCTAssertEqual(child.selectedRange(), childSelection)
        XCTAssertEqual(view.selectedRange(), parentSelection)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(view.subviews.contains(child))
        var navigations = 0
        view.footnoteNavigationHandler = { _ in navigations += 1; return true }
        let outside = (source as NSString).range(of: "outside")
        let glyph = layout.glyphRange(forCharacterRange: outside, actualCharacterRange: nil)
        let outsideRect = layout.boundingRect(forGlyphRange: glyph, in: container)
        let outsidePoint = NSPoint(x: outsideRect.midX + view.textContainerOrigin.x, y: outsideRect.midY + view.textContainerOrigin.y)
        let commandClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(outsidePoint, to: nil), modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        view.mouseDown(with: commandClick)
        XCTAssertEqual(navigations, 0)
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertEqual(view.string, source)
        child.unmarkText()
        view.mouseDown(with: commandClick)
        XCTAssertEqual(navigations, 1)
        XCTAssertFalse(view.subviews.contains(child))
    }
    func testLeavingTableClosesCellAndHidesHandles() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |\n\noutside"
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 250))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 250), textContainer: container)
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
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var frame: NSRect?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            frame = layout.markdownTableFrame(for: cell, in: container)
            if frame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let rect = try XCTUnwrap(frame)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: rect, cell: cell))
        let handlePoint = NSPoint(x: rect.minX - 6, y: rect.midY)
        XCTAssertNotNil(layout.tableDragHandle(at: handlePoint, in: container))
        let outside = (source as NSString).range(of: "outside")
        let glyph = layout.glyphRange(forCharacterRange: outside, actualCharacterRange: nil)
        let outsideRect = layout.boundingRect(forGlyphRange: glyph, in: container)
        let point = NSPoint(x: outsideRect.midX + view.textContainerOrigin.x, y: outsideRect.midY + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(mouseUp, atStart: false)
        view.mouseDown(with: event)
        XCTAssertTrue(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty)
        XCTAssertNil(layout.tableDragHandle(at: handlePoint, in: container))
        XCTAssertEqual(view.string, source)
    }
    func testRowHandleDragMovesTwoRowsWithOneUndo() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | x |\n| two | y |\n| three | z |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let first = table.rows[1].cells[0], target = table.rows[3].cells[0]
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
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
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var firstFrame: NSRect?, targetFrame: NSRect?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            firstFrame = layout.markdownTableFrame(for: first, in: container)
            targetFrame = layout.markdownTableFrame(for: target, in: container)
            if firstFrame != nil && targetFrame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let startRect = try XCTUnwrap(firstFrame), endRect = try XCTUnwrap(targetFrame)
        XCTAssertTrue(coordinator.beginTableCell(first.range, frame: startRect, cell: first))
        let start = NSPoint(x: startRect.minX - 6, y: startRect.midY)
        XCTAssertNotNil(layout.tableDragHandle(at: start, in: container))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            let inView = NSPoint(x: point.x + view.textContainerOrigin.x, y: point.y + view.textContainerOrigin.y)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, start))
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: endRect.midX, y: endRect.midY)))
        let expected = "| A | B |\n| --- | --- |\n| two | y |\n| three | z |\n| one | x |"
        XCTAssertEqual(view.string, expected)
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, source)
        undo.redo()
        XCTAssertEqual(view.string, expected)
    }

    func testColumnHandleDragAndCancellation() async throws {
        _ = NSApplication.shared
        let source = "| A | B | C |\n| --- | --- | --- |\n| x | y | z |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let first = table.rows[0].cells[0], last = table.rows[0].cells[2]
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
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var firstFrame: NSRect?, lastFrame: NSRect?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            firstFrame = layout.markdownTableFrame(for: first, in: container)
            lastFrame = layout.markdownTableFrame(for: last, in: container)
            if firstFrame != nil && lastFrame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let startRect = try XCTUnwrap(firstFrame), endRect = try XCTUnwrap(lastFrame)
        XCTAssertTrue(coordinator.beginTableCell(first.range, frame: startRect, cell: first))
        let start = NSPoint(x: startRect.midX, y: startRect.minY - 6)
        XCTAssertNotNil(layout.tableDragHandle(at: start, in: container))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            let inView = NSPoint(x: point.x + view.textContainerOrigin.x, y: point.y + view.textContainerOrigin.y)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, start))
        view.cancelTableDrag()
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: endRect.midX, y: endRect.midY)))
        XCTAssertEqual(view.string, source)
        view.mouseDown(with: try event(.leftMouseDown, start))
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: endRect.midX, y: endRect.midY)))
        let expected = "| B | C | A |\n| --- | --- | --- |\n| y | z | x |"
        XCTAssertEqual(view.string, expected)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }
    func testInactiveCellUsesCmarkTextAndAttributes() throws {
        let source = "| A |\n| --- |\n| **bold** *italic* ~~strike~~ `code` [label](https://example.com) a\\|b<br>中😀 |"
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertEqual(cell.displayText, "bold italic strike code label a|b\n中😀")
        let layout = FoldLayoutManager()
        let attributed = layout.tableCellAttributedText(cell, text: source as NSString)
        XCTAssertEqual(attributed.string, cell.displayText)
        let text = attributed.string as NSString
        let bold = try XCTUnwrap(attributed.attribute(.font, at: text.range(of: "bold").location, effectiveRange: nil) as? NSFont)
        let italic = try XCTUnwrap(attributed.attribute(.font, at: text.range(of: "italic").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        XCTAssertNotNil(attributed.attribute(.strikethroughStyle, at: text.range(of: "strike").location, effectiveRange: nil))
        XCTAssertNotNil(attributed.attribute(.underlineStyle, at: text.range(of: "label").location, effectiveRange: nil))
        let code = try XCTUnwrap(attributed.attribute(.font, at: text.range(of: "code").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(code.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual((source as NSString).substring(with: cell.range), " **bold** *italic* ~~strike~~ `code` [label](https://example.com) a\\|b<br>中😀 ")
    }

    func testLocalCellRefreshMatchesInitialSmartTextAndAutolink() throws {
        let source = "| A | B |\n| --- | --- |\n| \"test\" -- https://example.com | **unchanged** |"
        let initial = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let row = try XCTUnwrap(initial.rows.last)
        let raw = try XCTUnwrap(MarkdownTableEditingService.presentationTable(in: source as NSString, range: initial.range))
        let refreshed = MarkdownPresentationParser.tableDisplay(raw, text: source as NSString, previous: initial,
                                                                 changedRow: row.range.location, changedColumn: 0)
        XCTAssertEqual(refreshed.rows.last?.cells, initial.rows.last?.cells)
        let cell = try XCTUnwrap(refreshed.rows.last?.cells.first)
        XCTAssertTrue(cell.displayText?.contains("“test” –") == true)
        XCTAssertTrue(cell.displayRuns.contains { $0.kind == .link })
        XCTAssertTrue(refreshed.rows.last?.cells.last?.displayRuns.contains { $0.kind == .strong } == true)
    }

    func testLocalCellRefreshKeepsConfirmedReferenceLink() throws {
        let source = "| A | B |\n| --- | --- |\n| [текст][id] | **other** |\n\n[id]: https://example.com"
        let initial = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        XCTAssertEqual(initial.referenceLabels, ["id"])
        let changed = source.replacingOccurrences(of: "текст", with: "текст!")
        let changedTable = try XCTUnwrap(MarkdownPresentationParser.parse(changed).tables.first)
        let raw = try XCTUnwrap(MarkdownTableEditingService.presentationTable(in: changed as NSString, range: changedTable.range))
        let refreshed = MarkdownPresentationParser.tableDisplay(raw, text: changed as NSString, previous: initial,
            changedRow: changedTable.rows.last?.range.location, changedColumn: 0)
        XCTAssertEqual(refreshed.rows.last?.cells, changedTable.rows.last?.cells)
        XCTAssertEqual(refreshed.rows.last?.cells.first?.displayText, "текст!")
        XCTAssertTrue(refreshed.rows.last?.cells.first?.displayRuns.contains { $0.kind == .link } == true)
        XCTAssertEqual(refreshed.rows.last?.cells.last?.displayText, "other")
    }

    func testOpeningInlineCellDoesNotChangeRawMarkdown() throws {
        _ = NSApplication.shared
        let source = "| A |\n| --- |\n| **中文😀** [label](https://example.com) `code` |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        document.markSaved()
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertEqual(child.string, " **中文😀** [label](https://example.com) `code` ")
        coordinator.finishTableCell()
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }
    func testMultilineCellSnapshotCommitUndoAndReopen() throws {
        _ = NSApplication.shared
        let source = "| A | B |\r\n| --- | --- |\r\n| a\\|b<br>中😀 | end |"
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 80), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertEqual(child.string, " a|b\n中😀 ")
        let insertion = (child.string as NSString).range(of: "中").location
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: insertion, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        let expected = source.replacingOccurrences(of: "<br>中", with: "<br>文中")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(document.synchronizedSnapshot().text, expected)
        child.unmarkText()
        XCTAssertEqual(view.string, expected)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(child.undoAction?(true), true)
        XCTAssertEqual(view.string, expected)
        coordinator.finishTableCell()
        let updated = try XCTUnwrap(MarkdownPresentationParser.parse(expected).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(updated.range, frame: NSRect(x: 0, y: 0, width: 100, height: 80), cell: updated))
        let reopened = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertEqual(reopened.string, " a|b\n文中😀 ")
        reopened.insertText("<br><BR/>", replacementRange: NSRange(location: 0, length: (reopened.string as NSString).length))
        XCTAssertTrue(view.string.contains("\\<br>\\<BR/>"))
        XCTAssertEqual(reopened.string, "<br><BR/>")
    }

    func testCellProjectionMapsBreaksPipesAndUnicodeBoundaries() {
        let raw = "中😀a\\|b<br>e\u{301} \\<br> `<br>` `a\\|b`"
        let projection = MarkdownTableCellEditor.projection(raw)
        XCTAssertEqual(projection.text, "中😀a|b\ne\u{301} <br> `<br>` `a\\|b`")
        let display = projection.text as NSString
        let original = raw as NSString
        let pipe = display.range(of: "|")
        let rawPipe = NSRange(location: projection.rawBoundaries[pipe.location],
                              length: projection.rawBoundaries[NSMaxRange(pipe)] - projection.rawBoundaries[pipe.location])
        XCTAssertEqual(original.substring(with: rawPipe), "\\|")
        let newline = display.range(of: "\n")
        let rawBreak = NSRange(location: projection.rawBoundaries[newline.location],
                               length: projection.rawBoundaries[NSMaxRange(newline)] - projection.rawBoundaries[newline.location])
        XCTAssertEqual(original.substring(with: rawBreak), "<br>")
        XCTAssertEqual(projection.rawBoundaries.count, display.length + 1)
    }

    func testCellSourceTextKeepsUnchangedRawAndMapsEdits() throws {
        let raw = "中😀a\\|b<br/>end"
        let visible = "中😀a|b\nend"
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: raw, display: visible), raw)
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: raw, display: "中😃a|b\nend"), "中😃a\\|b<br/>end")
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: raw, display: "中😀a|b\nnew\nend"), "中😀a\\|b<br/>new<br>end")
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: raw, display: "中😀a|bend"), "中😀a\\|bend")
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: "a\\", display: "a\\\n"), "a\\\\<br>")
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: "a<br>", display: "a\\\n"), "a\\\\<br>")
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: "a<br", display: "a<br>"), "a\\<br>")
        XCTAssertEqual(MarkdownTableCellEditor.sourceText(raw: "", display: "<br><BR/>"), "\\<br>\\<BR/>")
    }

    func testCellEnterAfterBackslashAndUndo() throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| a\\"
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
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
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 80), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange(NSRange(location: (child.string as NSString).length, length: 0))
        child.insertNewline(nil)
        XCTAssertEqual(view.string, "| A | B |\n| --- | --- |\n| a\\\\<br>")
        XCTAssertEqual(child.string, " a\\\n")
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(child.undoAction?(true), true)
        XCTAssertEqual(child.string, " a\\\n")
    }
    func testVirtualCellUndoKeepsEnclosingQuoteMarkers() async throws {
        _ = NSApplication.shared
        let source = "> | A | B |\n> | --- | --- |\n> x\n\noutside"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.last)
        XCTAssertEqual(cell.virtualSeparators, 1)
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let marker = (source as NSString).range(of: "> | A").location
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            if layout.isMarkdownMarkerHidden(at: marker) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker))
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.insertText("中😀", replacementRange: NSRange(location: 0, length: 0))
        let expected = "> | A | B |\n> | --- | --- |\n> x|中😀\n\noutside"
        XCTAssertEqual(view.string, expected)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker))
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker))
        XCTAssertEqual(child.undoAction?(true), true)
        XCTAssertEqual(view.string, expected)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker))
    }

    func testNestedTableGridClickAndEditingPreserveQuote() async throws {
        _ = NSApplication.shared
        let source = "> before\n>\n> | A | B |\n> | --- | --- |\n> | one | two |\n>\n> after\n\noutside"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var frame: NSRect?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            frame = layout.markdownTableFrame(for: cell, in: container)
            if frame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let rect = try XCTUnwrap(frame)
        let beforeMarker = (source as NSString).range(of: "> before").location
        let afterMarker = (source as NSString).range(of: "> after").location
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: beforeMarker))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: afterMarker))
        XCTAssertGreaterThan(rect.minX, container.lineFragmentPadding)
        XCTAssertEqual(layout.markdownTableCellInfo(at: NSPoint(x: rect.midX, y: rect.midY), in: container)?.0, cell)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange(NSRange(location: 1, length: 3))
        child.insertText("中😀", replacementRange: child.selectedRange())
        let expected = (source as NSString).replacingCharacters(in: (source as NSString).range(of: "one"), with: "中😀")
        XCTAssertEqual(view.string, expected)
        XCTAssertEqual(document.synchronizedSnapshot().text, view.string)
        let updatedAfter = (expected as NSString).range(of: "> after").location
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: beforeMarker))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: updatedAfter))
        let updated = try XCTUnwrap(MarkdownPresentationParser.parse(view.string).tables.first?.rows.last?.cells.first)
        XCTAssertNotNil(layout.markdownTableFrame(for: updated, in: container))
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: beforeMarker))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: afterMarker))
        XCTAssertEqual(child.undoAction?(true), true)
        XCTAssertEqual(view.string, expected)
    }

    func testTableMenuTargetsVirtualColumnAndUndo() throws {
        _ = NSApplication.shared
        let source = "| A | B | C |\n| --- | --- | --- |\n| x |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.last)
        XCTAssertEqual(cell.virtualSeparators, 2)
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
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 120, height: 30), cell: cell))
        NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                                        object: MarkdownFormattingRequest(documentID: document.id, command: .table(.deleteColumn)))
        XCTAssertEqual(view.string, "| A | B |\n| --- | --- |\n| x |")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }

    func testFormattingUsesActiveCellSelectionAndUndo() throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        for (command, selection, expected) in [
            (MarkdownFormattingCommand.bold, NSRange(location: 0, length: 3), "| A | B |\n| --- | --- |\n| **one** | two |"),
            (.table(.insertRowAfter), NSRange(location: 1, length: 0), source + "\n|   |   |")
        ] {
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
            view.setSelectedRange((source as NSString).range(of: "A"))
            XCTAssertTrue(coordinator.beginTableCell((source as NSString).range(of: "one"), frame: NSRect(x: 0, y: 0, width: 120, height: 30)))
            let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
            child.setSelectedRange(selection)
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                                            object: MarkdownFormattingRequest(documentID: document.id, command: command))
            XCTAssertEqual(view.string, expected)
            XCTAssertFalse(view.subviews.contains(child))
            try XCTUnwrap(view.undoManager).undo()
            XCTAssertEqual(view.string, source)
            coordinator.updateActivity(false)
            window.close()
        }
    }

    func testFormattingCommandsRefuseMarkedCellInput() throws {
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
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let cell = (source as NSString).range(of: "one")
        view.setSelectedRange((source as NSString).range(of: "A"))
        let parentSelection = view.selectedRange()
        XCTAssertTrue(coordinator.beginTableCell(cell, frame: NSRect(x: 0, y: 0, width: 120, height: 30)))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange(NSRange(location: 1, length: 0))
        let commands: [MarkdownFormattingCommand] = [.bold, .table(.insertRowAfter), .table(.deleteColumn)]
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        let marked = child.string
        let markedSelection = child.selectedRange()
        for command in commands {
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                                            object: MarkdownFormattingRequest(documentID: document.id, command: command))
        }
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertEqual(child.string, marked)
        XCTAssertEqual(child.selectedRange(), markedSelection)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), parentSelection)
    }

    func testTabAfterLastShortOrExtraRowInsertsRow() throws {
        _ = NSApplication.shared
        for (header, delimiter, lastRow, inserted) in [
            ("| A | B |", "| --- | --- |", "| x |", "|   |   |"),
            ("| A | B |", "| --- | --- |", "| x | y | extra |", "|   |   |"),
            ("A|", "---|", "x", "|   |")
        ] {
            let source = [header, delimiter, lastRow].joined(separator: "\r\n")
            let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
            let cell = try XCTUnwrap(table.rows.last?.cells.last)
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
            XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
            let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
            child.doCommand(by: #selector(NSTextView.insertTab(_:)))
            XCTAssertEqual(view.string, source + "\r\n" + inserted)
            XCTAssertEqual(MarkdownPresentationParser.parse(view.string).tables.first?.rows.count, 3)
            let next = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
            XCTAssertFalse(next === child)
            XCTAssertEqual(next.string, "   ")
            coordinator.updateActivity(false)
            window.close()
        }
    }

    func testShortAndExtraRowsMatchVisibleColumns() throws {
        let source = "| A | B | C |\n| --- | --- | --- |\n| 中 |\n| a | b | c | hidden |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        XCTAssertEqual(table.rows.map { $0.cells.count }, [3, 3, 3])
        let short = table.rows[1].cells
        XCTAssertEqual(short.map(\.virtualSeparators), [0, 1, 2])
        XCTAssertEqual(short[1].range.location, NSMaxRange(short[0].range))
        XCTAssertEqual(short[1].range, short[2].range)
        let last = try XCTUnwrap(table.rows.last)
        XCTAssertEqual(last.cells.map { (source as NSString).substring(with: $0.range) }, [" a ", " b ", " c "])
        XCTAssertTrue((source as NSString).substring(with: last.range).contains(" hidden "))
        let html = MarkdownRenderer.renderPage(source, darkMode: false).body
        XCTAssertFalse(html.contains("hidden"))
    }

    func testVirtualCellInputAndUndoPreserveShortRow() throws {
        _ = NSApplication.shared
        for newline in ["\n", "\r\n"] {
          for marked in [false, true] {
            let source = ["| A | B | C |", "| --- | --- | --- |", "| 中文😀 |"].joined(separator: newline)
            let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
            let row = try XCTUnwrap(table.rows.last)
            XCTAssertEqual(row.cells.count, 3)
            let cell = row.cells[2]
            XCTAssertEqual(cell.virtualSeparators, 2)
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
            coordinator.attachLiveTextProvider()
            coordinator.updateActivity(true)
            let previous = row.cells[1]
            XCTAssertTrue(coordinator.beginTableCell(previous.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: previous))
            let firstChild = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                                            object: MarkdownFormattingRequest(documentID: document.id, command: .bold))
            XCTAssertEqual(view.string, source)
            XCTAssertTrue(view.subviews.contains(firstChild))
            firstChild.doCommand(by: #selector(NSTextView.insertTab(_:)))
            let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
            XCTAssertFalse(child === firstChild)
            XCTAssertEqual(view.string, source)
            let expected = ["| A | B | C |", "| --- | --- | --- |", "| 中文😀 ||X|"].joined(separator: newline)
            if marked {
                child.setMarkedText("X", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
                XCTAssertTrue(child.hasMarkedText())
                XCTAssertEqual(view.string, source)
                XCTAssertEqual(document.synchronizedSnapshot().text, expected)
                child.unmarkText()
            } else {
                child.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            }
            XCTAssertEqual(view.string, expected)
            XCTAssertEqual(document.synchronizedSnapshot().text, expected)
            XCTAssertEqual(MarkdownPresentationParser.parse(expected).tables.first?.rows.last?.cells.count, 3)
            child.undoAction?(false)
            XCTAssertEqual(view.string, source)
            child.undoAction?(true)
            XCTAssertEqual(view.string, expected)
            coordinator.updateActivity(false)
            window.close()
          }
        }
    }
    func testVisibleGridClickTypingAndTab() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |\n\n# **Title**\n\n- [x] Task\n\n[toc]\n\n| C | D |\n| --- | --- |\n| three | four |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        var target: (NSRange, NSRect)?
        let point = NSPoint(x: container.lineFragmentPadding + 20, y: 12 + layout.editorLineHeight / 2)
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 400, height: 200), in: container)
            target = layout.markdownTableCell(at: point, in: container)
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let first = try XCTUnwrap(target)
        XCTAssertEqual((source as NSString).substring(with: first.0), " A ")
        let viewPoint = NSPoint(x: point.x + view.textContainerOrigin.x, y: point.y + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange(NSRange(location: 1, length: 1))
        child.insertText("中", replacementRange: child.selectedRange())
        XCTAssertTrue(view.string.contains("| 中 | B |"))
        XCTAssertEqual(document.synchronizedSnapshot().text, view.string)
        let visibleCell = try XCTUnwrap(layout.markdownTableCell(at: point, in: container))
        XCTAssertEqual((view.string as NSString).substring(with: visibleCell.0), " 中 ")
        let current = MarkdownPresentationParser.parse(view.string)
        XCTAssertEqual(current.tables.count, 2)
        let secondCell = try XCTUnwrap(current.tables.last?.rows.first?.cells.first)
        XCTAssertNotNil(layout.markdownTableFrame(for: secondCell.range, in: container))
        let titleMarker = (view.string as NSString).range(of: "**Title**").location
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: titleMarker))
        let checkbox = try XCTUnwrap(current.taskCheckboxes.first)
        let checkboxGlyphs = layout.glyphRange(forCharacterRange: checkbox.markerRange, actualCharacterRange: nil)
        let checkboxPoint = layout.boundingRect(forGlyphRange: checkboxGlyphs, in: container)
        XCTAssertEqual(layout.markdownTaskCheckbox(at: NSPoint(x: checkboxPoint.midX, y: checkboxPoint.midY), in: container), checkbox)
        let toc = try XCTUnwrap(current.tableOfContents.first)
        let tocLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: toc.location), effectiveRange: nil)
        XCTAssertNotNil(layout.markdownTOC(at: NSPoint(x: container.lineFragmentPadding + 1, y: tocLine.minY + layout.editorLineHeight / 2), in: container))
        child.setSelectedRange(NSRange(location: 2, length: 0))
        child.insertText("|😀", replacementRange: child.selectedRange())
        XCTAssertTrue(view.string.contains("中\\|😀"))
        child.insertText("\nother", replacementRange: child.selectedRange())
        child.insertNewline(nil)
        XCTAssertTrue(view.string.contains("中\\|😀<br>other<br>"))
        XCTAssertTrue(child.string.contains("中|😀\nother\n"))
        XCTAssertEqual(MarkdownPresentationParser.parse(view.string).tables.first?.rows.first?.cells.count, 2)
        XCTAssertEqual(child.selectedRange().location, 12)
        XCTAssertTrue(MarkdownRenderer.render(view.string, darkMode: false).contains("中|"))
        let oldWidth = child.frame.width
        scroll.frame.size.width = 240
        coordinator.updateLayout(wordWrap: true, force: true)
        XCTAssertLessThan(child.frame.width, oldWidth)
        child.doCommand(by: #selector(NSTextView.insertTab(_:)))
        let next = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        XCTAssertEqual(next.string, " B ")
    }

    func testPipeKeepsTableStructureAndSelection() throws {
        let value = try XCTUnwrap(MarkdownTableCellEditor.sourceText(raw: "中😀ab", display: "中😀|ab"))
        XCTAssertEqual(value, "中😀\\|ab")
        let projection = MarkdownTableCellEditor.projection(value)
        XCTAssertEqual(projection.text, "中😀|ab")
        XCTAssertEqual((value as NSString).substring(from: projection.rawBoundaries[4]), "ab")
        let document = "| A | B |\n| --- | --- |\n| " + value + " | end |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(document).tables.first)
        XCTAssertEqual(table.rows.last?.cells.count, 2)
        let html = MarkdownRenderer.render(document, darkMode: false)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("中😀|a"))
    }

    func testHostingUpdateDuringMarkedSnapshotKeepsCell() async throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let store = EditorSessionStore(limit: 1)
        func editor(family: String? = nil) -> EditorTextView {
            EditorTextView(document: document, sessionStore: store, fontSize: 14, lineSpacing: 2,
                           indentationStyle: .spaces, tabWidth: 4, wordWrap: true, showsLineNumbers: false,
                           topInset: 0, isActive: true, requestTextTransformation: { _ in }, textFontFamily: family)
        }
        let host = NSHostingView(rootView: editor())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let coordinator = store.coordinator(for: document)
        let view = try XCTUnwrap(coordinator.textView)
        let originalFont = try XCTUnwrap(view.font)
        let family = try XCTUnwrap(NSFontManager.shared.availableFontFamilies.first {
            $0 != originalFont.familyName && AppPreferences.availableFont(family: $0, size: 14) != nil
        })
        let selectedFont = AppPreferences.textFont(family: family, size: 14)
        let cell = (source as NSString).range(of: "one")
        XCTAssertTrue(coordinator.beginTableCell(cell, frame: NSRect(x: 10, y: 10, width: 150, height: 40)))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中文😀", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 3))
        let expected = (source as NSString).replacingCharacters(in: cell, with: "中文😀")
        XCTAssertEqual(document.synchronizedSnapshot().text, expected)
        host.rootView = editor(family: family)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertTrue(view.subviews.contains(child))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.font, originalFont)
        XCTAssertEqual(child.font, originalFont)
        child.unmarkText()
        XCTAssertEqual(view.string, expected)
        XCTAssertEqual(document.synchronizedSnapshot().text, expected)
        XCTAssertEqual(view.font, selectedFont)
        XCTAssertEqual(child.font, selectedFont)
    }

    func testMarkedCellSnapshotThenCommitAndUndo() throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        document.markSaved()
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let range = (source as NSString).range(of: "one")
        XCTAssertTrue(coordinator.beginTableCell(range, frame: NSRect(x: 0, y: 0, width: 100, height: 30)))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange(NSRange(location: 0, length: 3))
        child.setMarkedText("中文😀", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(child.hasMarkedText())
        let expected = (source as NSString).replacingCharacters(in: range, with: "中文😀")
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(document.synchronizedSnapshot().text, expected)
        XCTAssertTrue(child.hasMarkedText())
        child.unmarkText()
        XCTAssertEqual(view.string, expected)
        XCTAssertEqual(document.synchronizedSnapshot().text, expected)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        coordinator.finishTableCell()
        XCTAssertTrue(coordinator.beginTableCell(range, frame: NSRect(x: 0, y: 0, width: 100, height: 30)))
        let cancelled = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        cancelled.setSelectedRange(NSRange(location: 0, length: 3))
        cancelled.setMarkedText("临时", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertEqual(document.synchronizedSnapshot().text, (source as NSString).replacingCharacters(in: range, with: "临时"))
        cancelled.insertText("one", replacementRange: cancelled.markedRange())
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(document.synchronizedSnapshot().text, source)
        XCTAssertFalse(document.isDirty)
        coordinator.finishTableCell()
        view.isEditable = false
        XCTAssertFalse(coordinator.beginTableCell(range, frame: .zero))
        view.isEditable = true
        XCTAssertTrue(coordinator.beginTableCell(range, frame: NSRect(x: 0, y: 0, width: 100, height: 30)))
        view.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty)
        XCTAssertEqual(view.string, "!" + source)
        document.isMarkdownFormatted = false
        XCTAssertFalse(coordinator.beginTableCell(NSRange(location: range.location + 1, length: range.length), frame: .zero))
    }
}
