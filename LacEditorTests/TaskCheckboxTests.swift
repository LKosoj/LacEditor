import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class TaskCheckboxTests: XCTestCase {
    func testParserFindsOnlyConfirmedMarkers() {
        let text = "中文😀\r\n\r\n- [ ] a\r\n  - [x] b\r\n> - [X] c\r\n\r\n`- [x] code`\r\n\\- [x] escaped"
        let boxes = MarkdownPresentationParser.parse(text).taskCheckboxes
        XCTAssertEqual(boxes.count, 3)
        let source = text as NSString
        XCTAssertEqual(boxes.map { source.substring(with: $0.markerRange) }, ["[ ]", "[x]", "[X]"])
        XCTAssertEqual(boxes.map { source.substring(with: $0.stateRange) }, [" ", "x", "X"])
        XCTAssertEqual(MarkdownPresentationParser.parse("-\t[x] tabs").taskCheckboxes.first?.markerRange, NSRange(location: 2, length: 3))
        let uppercase = MarkdownPresentationParser.parse("- [X] completed").taskCheckboxes
        XCTAssertEqual(uppercase.first?.state, 88)
        let quoted = "> - [x] quoted" as NSString
        let quotedBox = MarkdownPresentationParser.parse(quoted as String).taskCheckboxes.first
        XCTAssertEqual(quotedBox?.markerRange, quoted.range(of: "[x]"))
        XCTAssertEqual(quotedBox?.state, MarkdownPresentationParser.parse("- [x] plain").taskCheckboxes.first?.state)
        let nested = "> > - [ ] nested\r\n> >   - [X] child" as NSString
        let nestedBoxes = MarkdownPresentationParser.parse(nested as String).taskCheckboxes
        XCTAssertEqual(nestedBoxes.map(\.markerRange), [nested.range(of: "[ ]"), nested.range(of: "[X]")])
        XCTAssertEqual(nestedBoxes.map(\.state), [32, 88])
        for text in ["> - \\[x] escaped", "> - [q] other", "> - [x]word", "> ```\n> - [x] code\n> ```"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(text).taskCheckboxes.isEmpty, text)
        }
    }

    func testTaskTabsKeepExactSourceRangesAndRejectCodePadding() {
        for source in ["-\t[ ] 中文😀", "> -\t[x] 中文😀", "- parent\r\n\t- [X] 中文😀",
                       "- [x] 中文\tbody", "- [ ]\tbody", "> - [x]\tbody"] {
            let raw = source as NSString
            let boxes = MarkdownPresentationParser.parse(source).taskCheckboxes
            XCTAssertEqual(boxes.count, 1, source)
            guard let checkbox = boxes.first else { continue }
            let marker = ["[ ]", "[x]", "[X]"].map { raw.range(of: $0) }.first { $0.location != NSNotFound }!
            XCTAssertEqual(checkbox.markerRange, marker, source)
            XCTAssertEqual(checkbox.stateRange, NSRange(location: marker.location + 1, length: 1), source)
            XCTAssertEqual(checkbox.state, raw.character(at: marker.location + 1), source)
        }
        for source in ["-\t  [x] code", "> -\t    [x] code", "> -     [x] code", "> -\t[q] other", "> -\t[x]word"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).taskCheckboxes.isEmpty, source)
        }
    }

    func testClickUsesCurrentSourceAndUndo() async throws {
        _ = NSApplication.shared
        let source = "before\n\n-\t[ ] item\n\n![image](data:image/png;base64,AA==)"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
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
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let marker = (source as NSString).range(of: "[ ]")
        func point() -> NSPoint {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        for _ in 0..<30 {
            if layout.markdownTaskCheckbox(at: point(), in: container) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let checkbox = try XCTUnwrap(layout.markdownTaskCheckbox(at: point(), in: container))
        let viewPoint = NSPoint(x: point().x + view.textContainerOrigin.x, y: point().y + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        view.isEditable = false
        XCTAssertFalse(view.taskCheckboxHandler?(checkbox) ?? true)
        XCTAssertEqual(view.string, source)
        view.isEditable = true
        view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 3, length: 1))], affinity: .downstream, stillSelecting: false)
        let multipleSelections = view.selectedRanges
        XCTAssertEqual(multipleSelections.count, 2)
        view.mouseDown(with: event)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRanges, multipleSelections)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let initialSelection = view.selectedRange()
        view.mouseDown(with: event)
        XCTAssertEqual(view.string, source.replacingOccurrences(of: "[ ]", with: "[x]"))
        XCTAssertEqual(view.selectedRange(), initialSelection)
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, source)
        undo.redo()
        XCTAssertEqual(view.string, source.replacingOccurrences(of: "[ ]", with: "[x]"))
        XCTAssertFalse(view.taskCheckboxHandler?(checkbox) ?? true)
        for _ in 0..<30 {
            if layout.markdownTaskCheckbox(at: point(), in: container)?.state == 120 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let checked = try XCTUnwrap(layout.markdownTaskCheckbox(at: point(), in: container))
        XCTAssertEqual(checked.state, 120)
        XCTAssertTrue(view.taskCheckboxHandler?(checked) ?? false)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), initialSelection)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let duringInput = view.string
        XCTAssertFalse(view.taskCheckboxHandler?(checked) ?? true)
        XCTAssertEqual(view.string, duringInput)
        view.unmarkText()
    }
}
