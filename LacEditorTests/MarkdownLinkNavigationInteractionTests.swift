import AppKit
import AVKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownLinkNavigationInteractionTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let manager: WindowManager
        let state: AppState
        let window: NSWindow
        let editor: LacTextView
        let defaults: UserDefaults
        let suite: String

        func close() {
            state.closeAuxiliaryWindows()
            window.delegate = nil
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func findEditor(in view: NSView) -> LacTextView? {
        if let editor = view as? LacTextView { return editor }
        for child in view.subviews { if let editor = findEditor(in: child) { return editor } }
        return nil
    }

    private func fixture(_ document: EditorDocument) async throws -> Fixture {
        _ = NSApplication.shared
        let suite = "MarkdownLinkNavigationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = WindowManager(preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults))
        let state = manager.openNewWindow(with: document)
        let window = try XCTUnwrap(state.hostWindow)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 {
            if let content = window.contentView, let editor = findEditor(in: content),
               editor.string == document.text, window.isKeyWindow {
                window.makeFirstResponder(editor)
                return Fixture(manager: manager, state: state, window: window, editor: editor, defaults: defaults, suite: suite)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(findEditor(in: content))
        XCTAssertTrue(window.isKeyWindow)
        return Fixture(manager: manager, state: state, window: window, editor: editor, defaults: defaults, suite: suite)
    }

    private func click(_ editor: LacTextView, character: Int, command: Bool) throws {
        let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(forBoundingRect: editor.visibleRect, in: container)
        let glyph = layout.glyphIndexForCharacter(at: character)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(point, to: nil),
            modifierFlags: command ? .command : [], timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        editor.mouseDown(with: event)
    }

    func testMediaInsideLinkReceivesClicksAndNearbyLinksStillNavigate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var sound = Data("RIFF".utf8)
        func word(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        func half(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { sound.append(contentsOf: $0) } }
        word(24036); sound.append(Data("WAVEfmt ".utf8)); word(16)
        half(1); half(1); word(8000); word(8000); half(1); half(8)
        sound.append(Data("data".utf8)); word(24000); sound.append(Data(repeating: 128, count: 24000))
        try sound.write(to: folder.appendingPathComponent("sound.wav"))
        let source = "[before <audio controls src='sound.wav'>fallback</audio> after](#outer) [next](#target)\n\n# Outer\n\n# Target\n\nend"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("note.md"), language: .markdown)
        document.isMarkdownFormatted = true
        let fixture = try await fixture(document)
        defer { fixture.close() }
        fixture.editor.setSelectedRange((source as NSString).range(of: "end"))
        for _ in 0..<100 where fixture.editor.subviews.compactMap({ $0 as? AVPlayerView }).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        let player = try XCTUnwrap(fixture.editor.subviews.compactMap { $0 as? AVPlayerView }.first)
        let originalHandler = fixture.editor.markdownLinkHandler
        var navigations = 0
        fixture.editor.markdownLinkHandler = { point in navigations += 1; return originalHandler?(point) ?? false }
        let point = player.convert(NSPoint(x: player.bounds.midX, y: player.bounds.midY), to: nil)
        let viewPoint = fixture.editor.convert(point, from: nil)
        let hit = try XCTUnwrap(fixture.editor.hitTest(fixture.editor.convert(viewPoint, to: fixture.editor.superview)))
        XCTAssertTrue(hit === player || hit.isDescendant(of: player))
        for modifiers in [NSEvent.ModifierFlags(rawValue: 0), .command] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                fixture.window.sendEvent(event)
            }
        }
        XCTAssertEqual(navigations, 0)
        let headings = MarkdownPresentationParser.parse(source).headings
        try click(fixture.editor, character: (source as NSString).range(of: "before").location, command: true)
        for _ in 0..<100 where fixture.editor.selectedRange().location != headings.first?.range.location {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fixture.editor.selectedRange().location, headings.first?.range.location)
        try click(fixture.editor, character: (source as NSString).range(of: "next").location, command: true)
        for _ in 0..<100 where fixture.editor.selectedRange().location != headings.last?.range.location {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fixture.editor.selectedRange().location, headings.last?.range.location)
        XCTAssertEqual(fixture.editor.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testCommandClickUsesUppercaseHeadingSourcePosition() async throws {
        let source = "# [Go](#target)\n\n# Target\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let fixture = try await fixture(document)
        defer { fixture.close() }
        let view = fixture.editor
        let layout = try XCTUnwrap(view.layoutManager as? FoldLayoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let parsed = MarkdownPresentationParser.parse(source)
        let heading = try XCTUnwrap(parsed.headings.first)
        let word = (source as NSString).range(of: "Go")
        let run = MarkdownHeading.UppercaseRun(pieces: [.init(sourceRange: word, text: "Go", matchesSource: true)], styles: [.link])
        view.setSelectedRange((source as NSString).range(of: "end"))
        layout.setMarkdownPresentation(parsed, revealedRange: (source as NSString).range(of: "end"))
        XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: [run], width: 200, level: 1))
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: heading.range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = layout.markdownHeadingFont(level: 1)
        let width = ("G" as NSString).size(withAttributes: [.font: font]).width
        let point = NSPoint(x: line.minX + container.lineFragmentPadding + width * 0.25 + view.textContainerOrigin.x,
                            y: line.minY + font.ascender * 0.5 + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
            modifierFlags: .command, timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        let target = try XCTUnwrap(parsed.headings.last)
        for _ in 0..<100 {
            if view.selectedRange().location == target.range.location { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(view.selectedRange(), NSRange(location: target.range.location, length: 0))
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testCommandClickNavigatesInBothViewsAndOrdinaryClickEdits() async throws {
        for formatted in [false, true] {
            let source = "[jump](#target)\n\n# Target\n\nend"
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = formatted
            let fixture = try await fixture(document)
            defer { fixture.close() }
            fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
            try click(fixture.editor, character: 2, command: true)
            let heading = try XCTUnwrap(MarkdownPresentationParser.parse(source).headings.first)
            for _ in 0..<100 {
                if fixture.editor.selectedRange().location == heading.range.location { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(fixture.editor.selectedRange(), NSRange(location: heading.range.location, length: 0))
            XCTAssertEqual(fixture.editor.string, source)
            XCTAssertFalse(document.isDirty)
            try click(fixture.editor, character: 2, command: false)
            XCTAssertLessThan(fixture.editor.selectedRange().location, heading.range.location)
        }
    }

    func testSelectionAwayAndBackRejectsDelayedParse() async throws {
        let source = "[jump](#target)\n\n# Target"
        let document = EditorDocument(text: source, language: .markdown)
        let fixture = try await fixture(document)
        defer { fixture.close() }
        let coordinator = try XCTUnwrap(fixture.editor.delegate as? EditorTextView.Coordinator)
        let started = expectation(description: "link parse started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        coordinator.markdownLinkParse = { text in
            started.fulfill()
            release.wait()
            return MarkdownPresentationParser.parse(text)
        }
        fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try click(fixture.editor, character: 2, command: true)
        let pending = try XCTUnwrap(coordinator.markdownLinkTask)
        await fulfillment(of: [started], timeout: 5)
        fixture.editor.setSelectedRange(NSRange(location: 1, length: 0))
        fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
        release.signal()
        await pending.value
        XCTAssertEqual(fixture.editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(fixture.editor.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testOpeningAndClosingCellCancelsDelayedLinkParse() async throws {
        let source = "[jump](#target)\n\n# Target\n\n| A |\n|---|\n| x |"
        let document = EditorDocument(text: source, language: .markdown)
        let fixture = try await fixture(document)
        defer { fixture.close() }
        let coordinator = try XCTUnwrap(fixture.editor.delegate as? EditorTextView.Coordinator)
        let started = expectation(description: "link parse started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        coordinator.markdownLinkParse = { text in
            started.fulfill()
            release.wait()
            return MarkdownPresentationParser.parse(text)
        }
        fixture.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try click(fixture.editor, character: 2, command: true)
        let pending = try XCTUnwrap(coordinator.markdownLinkTask)
        await fulfillment(of: [started], timeout: 5)
        document.isMarkdownFormatted = true
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 30), cell: cell))
        coordinator.finishTableCell()
        release.signal()
        await pending.value
        XCTAssertEqual(fixture.editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(fixture.editor.string, source)
    }

    func testFileAnchorUsesExistingOpenDocument() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = "[jump](target.md#target)", target = "intro\n\n# Target\n\nend"
        let sourceURL = folder.appendingPathComponent("source.md"), targetURL = folder.appendingPathComponent("target.md")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try target.write(to: targetURL, atomically: true, encoding: .utf8)
        let document = EditorDocument(text: source, url: sourceURL, language: .markdown)
        let fixture = try await fixture(document)
        defer { fixture.close() }
        let targetDocument = EditorDocument(text: target, url: targetURL, language: .markdown)
        let targetState = fixture.manager.openNewWindow(with: targetDocument)
        let targetWindow = try XCTUnwrap(targetState.hostWindow)
        defer { targetState.closeAuxiliaryWindows(); targetWindow.delegate = nil; targetWindow.contentViewController = nil; targetWindow.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.makeFirstResponder(fixture.editor)
        for _ in 0..<100 {
            if fixture.manager.activeState === fixture.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try click(fixture.editor, character: 2, command: true)
        let heading = try XCTUnwrap(MarkdownPresentationParser.parse(target).headings.first)
        for _ in 0..<100 {
            if targetDocument.selectionRange.location == heading.range.location { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fixture.manager.activeState?.selectedDocument?.id, targetDocument.id)
        XCTAssertEqual(targetDocument.selectionRange, NSRange(location: heading.range.location, length: 0))
        XCTAssertEqual(fixture.manager.documentsForAI.filter { $0.id == targetDocument.id }.count, 1)
        XCTAssertEqual(document.synchronizedText(), source)
        XCTAssertFalse(document.isDirty)
    }
}
