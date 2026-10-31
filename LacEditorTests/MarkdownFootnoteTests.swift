import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownFootnoteTests: XCTestCase {
    func testTableOfContentsLevelChangesHeightAndHitTargets() throws {
        _ = NSApplication.shared
        let source = "[toc]\n\n# 中文😀\n\n### Deep\n\n## Second\n\n# 中文😀"
        let parsed = MarkdownPresentationParser.parse(source)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        let toc = try XCTUnwrap(parsed.tableOfContents.first)
        func height() -> CGFloat {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: toc.location)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height
        }
        let fullHeight = height()
        layout.markdownTOCMaxLevel = 1
        let filteredHeight = height()
        XCTAssertLessThan(filteredHeight, fullHeight)
        let second = NSPoint(x: container.lineFragmentPadding + 1, y: layout.editorLineHeight * 1.5)
        XCTAssertEqual(layout.markdownTOC(at: second, in: container)?.heading?.range.location,
                       (source as NSString).range(of: "# 中文😀", options: .backwards).location)
        layout.markdownTOCMaxLevel = 6
        XCTAssertEqual(height(), fullHeight, accuracy: 0.5)
        XCTAssertEqual(parsed.headings.count, 4)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testTableOfContentsClickUsesCurrentHeadingWithoutEditing() async throws {
        _ = NSApplication.shared
        let source = "[toc]\n\n# First\n\n## Second"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
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
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let point = NSPoint(x: container.lineFragmentPadding + 1, y: layout.editorLineHeight / 2)
        var entry: (range: NSRange, heading: MarkdownHeading?)?
        for _ in 0..<30 {
            layout.ensureLayout(for: container)
            entry = layout.markdownTOC(at: point, in: container)
            if entry != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(entry?.heading?.title, "First")
        let viewPoint = NSPoint(x: point.x + view.textContainerOrigin.x, y: point.y + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(view.selectedRange().location, (source as NSString).range(of: "# First").location)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
        let oldEntry = try XCTUnwrap(entry)
        view.insertText("!", replacementRange: NSRange(location: (source as NSString).length, length: 0))
        XCTAssertFalse(view.tableOfContentsHandler?(oldEntry.range, oldEntry.heading) ?? true)
        var updated = false
        for _ in 0..<30 {
            layout.ensureLayout(for: container)
            let secondPoint = NSPoint(x: container.lineFragmentPadding + layout.textFont.pointSize + 1,
                                      y: layout.editorLineHeight * 1.5)
            if layout.markdownTOC(at: secondPoint, in: container)?.heading?.title == "Second!" { updated = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(updated)
        layout.ensureLayout(for: container)
        let currentEntry = try XCTUnwrap(layout.markdownTOC(at: point, in: container))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.tableOfContentsHandler?(currentEntry.range, currentEntry.heading) ?? true)
        view.unmarkText()
        coordinator.updateActivity(false)
        XCTAssertFalse(view.tableOfContentsHandler?(oldEntry.range, oldEntry.heading) ?? true)
    }
    func testReferencePositionsAndDefinitionAssociation() throws {
        let source = "中文😀 [^id] and [^id] [^missing]\r\n\r\n[^id]: first\r\n    second\r\n\r\n[^id]: duplicate\r\n\r\n`[^id]`"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.footnotes.count, 2)
        let text = source as NSString
        let first = text.range(of: "[^id]")
        let second = text.range(of: "[^id]", options: [], range: NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first)))
        let definition = text.range(of: "[^id]:")
        XCTAssertEqual(parsed.footnotes.map(\.referenceRange), [first, second])
        XCTAssertEqual(parsed.footnotes.map(\.definitionRange), [NSRange(location: definition.location, length: 5), NSRange(location: definition.location, length: 5)])
        XCTAssertEqual(parsed.footnotes.first?.text, "first second")
        XCTAssertEqual(source, text as String)
    }

    func testHTMLReferencesAndSafeLinks() {
        let body = MarkdownRenderer.renderPage("Text[^a] [^missing]\n\n[^a]: note", darkMode: false).body
        XCTAssertTrue(body.contains("href=\"#fn-a\""))
        XCTAssertTrue(body.contains("href=\"#fnref-a\""))
        XCTAssertTrue(body.contains("[^missing]"))
        let code = MarkdownRenderer.renderPage("`[^a]`\n\n[^a]: note", darkMode: false).body
        XCTAssertFalse(code.contains("class=\"footnote-ref\""))
    }

    func testUnicodeIdentifierAndBlockText() throws {
        let source = "Text[^中文😀]\n\n[^中文😀]: first\n\n    second\n\n    ```\n    fenced\n    ```\n\n        indented\n"
        let note = try XCTUnwrap(MarkdownPresentationParser.parse(source).footnotes.first)
        let text = source as NSString
        XCTAssertEqual(note.referenceRange, text.range(of: "[^中文😀]"))
        let definition = text.range(of: "[^中文😀]:")
        XCTAssertEqual(note.definitionRange, NSRange(location: definition.location, length: definition.length - 1))
        XCTAssertEqual(note.text, "first\nsecond\nfenced\nindented")
    }

    func testPresentationTransitionAndStaleNavigation() async throws {
        _ = NSApplication.shared
        let source = "before[^a] after\n\n[^a]: note"
        let document = EditorDocument(text: source, language: .markdown)
        let other = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        defer { window.close() }
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        func update(_ document: EditorDocument, enabled: Bool) {
            controller.update(document: document, enabled: enabled, outlineVisible: true, isActive: true,
                              revision: revision, currentRevision: { revision })
        }
        let reference = (source as NSString).range(of: "[^a]")
        let definition = (source as NSString).range(of: "[^a]:")
        func point(_ range: NSRange) -> NSPoint {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        }
        update(document, enabled: true)
        var target: NSRange?
        for _ in 0..<30 {
            target = controller.footnoteTarget(at: point(reference), document: document, revision: revision)
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(target?.location, definition.location)
        update(document, enabled: false)
        XCTAssertNil(controller.footnoteTarget(at: point(reference), document: document, revision: revision))
        update(document, enabled: true)
        XCTAssertNil(controller.footnoteTarget(at: point(definition), document: document, revision: revision))
        XCTAssertNotNil(controller.footnoteTarget(at: point(reference), document: document, revision: revision))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: (source as NSString).length, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertNil(controller.footnoteTarget(at: point(reference), document: document, revision: revision))
        view.unmarkText()
        update(other, enabled: true)
        XCTAssertNil(controller.footnoteTarget(at: point(reference), document: document, revision: revision))
        var otherTarget: NSRange?
        for _ in 0..<30 {
            otherTarget = controller.footnoteTarget(at: point(reference), document: other, revision: revision)
            if otherTarget != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(otherTarget)
        let edit = NSRange(location: 0, length: 0)
        controller.beforeEdit(range: edit, replacementLength: 1)
        storage.replaceCharacters(in: edit, with: "x")
        revision += 1
        controller.edited(revision: revision)
        XCTAssertNil(controller.footnoteTarget(at: point(reference), document: other, revision: revision))
        controller.cancel()
    }

    func testFootnoteNavigationSurvivesFastPathEdit() async throws {
        _ = NSApplication.shared
        let source = "before[^a] after\n\n[^a]: note"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        defer { window.close() }
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        controller.update(document: document, enabled: true, outlineVisible: true, isActive: true,
                          revision: revision, currentRevision: { revision })
        func point(_ range: NSRange) -> NSPoint {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        }
        let definition = (source as NSString).range(of: "[^a]:")
        var target: NSRange?
        for _ in 0..<30 {
            target = controller.footnoteTarget(at: point((source as NSString).range(of: "[^a]")), document: document, revision: revision)
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(target?.location, definition.location)
        // Буква в начале абзаца идёт быстрым путём: оформление и сноски сдвигаются, разбор не нужен.
        let edit = NSRange(location: 2, length: 0)
        controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        storage.replaceCharacters(in: edit, with: "x")
        revision += 1
        controller.edited(revision: revision)
        let shifted = (storage.string as NSString)
        XCTAssertNotNil(controller.footnoteTarget(at: point(shifted.range(of: "[^a]")), document: document, revision: revision))
        XCTAssertEqual(controller.footnoteTarget(at: point(shifted.range(of: "[^a]")), document: document, revision: revision)?.location,
                       definition.location + 1)
        var settled: NSRange?
        for _ in 0..<30 {
            settled = controller.footnoteTarget(at: point(shifted.range(of: "[^a]")), document: document, revision: revision)
            if settled?.location == definition.location + 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(settled?.location, definition.location + 1)
        controller.cancel()
    }

    func testFootnoteTooltipsCoverVisibleTextAndWaitForParseAfterTyping() async throws {
        _ = NSApplication.shared
        let source = (0..<80).map { "line\($0)[^a]\n\n" }.joined() + "[^a]: note"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 100_000))
        layout.addTextContainer(container)
        let frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let view = LacTextView(frame: frame, textContainer: container)
        let scroll = NSScrollView(frame: frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        defer { window.close() }
        view.setFrameSize(NSSize(width: 500, height: 5000))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        controller.update(document: document, enabled: true, outlineVisible: true, isActive: true,
                          revision: revision, currentRevision: { revision })
        let references = try NSRegularExpression(pattern: "\\[\\^a\\](?!:)")
        func visibleReferences() -> Int {
            layout.ensureLayout(for: container)
            let rect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: container)
            return references.numberOfMatches(in: storage.string, range: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        for _ in 0..<30 {
            if !controller.footnoteTooltipRects.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(controller.footnoteTooltipRects.count, visibleReferences())
        // Часть строк уже оформлена: подсказки на них не теряются ни при частичной, ни при полностью готовой области.
        view.scroll(NSPoint(x: 0, y: 120))
        controller.viewportChanged()
        XCTAssertGreaterThan(visibleReferences(), 0)
        XCTAssertEqual(controller.footnoteTooltipRects.count, visibleReferences())
        view.scroll(.zero)
        controller.viewportChanged()
        XCTAssertEqual(controller.footnoteTooltipRects.count, visibleReferences())
        // Быстрый путь не трогает подсказки: новые места приходят с разбором после паузы.
        let before = controller.footnoteTooltipRects
        let edit = NSRange(location: 2, length: 0)
        controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        storage.replaceCharacters(in: edit, with: "x")
        revision += 1
        controller.edited(revision: revision)
        XCTAssertEqual(controller.footnoteTooltipRects, before)
        for _ in 0..<30 {
            if controller.footnoteTooltipRects != before { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotEqual(controller.footnoteTooltipRects, before)
        XCTAssertEqual(controller.footnoteTooltipRects.count, visibleReferences())
        controller.cancel()
    }

    func testCommandClickGoesToDefinitionAndBackWithoutEditing() async throws {
        _ = NSApplication.shared
        let source = "before[^a] after\n\n[^a]: note"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500), textContainer: container)
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
        let reference = (source as NSString).range(of: "[^a]")
        let definition = (source as NSString).range(of: "[^a]:")
        func point(_ range: NSRange) -> NSPoint {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        }
        var jumped = false
        for _ in 0..<30 {
            if view.footnoteNavigationHandler?(point(reference)) == true { jumped = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(jumped)
        XCTAssertEqual(view.selectedRange(), NSRange(location: definition.location, length: 0))
        XCTAssertTrue(view.footnoteNavigationHandler?(point(NSRange(location: definition.location, length: 4))) ?? false)
        XCTAssertEqual(view.selectedRange(), NSRange(location: reference.location, length: 0))
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(document.isDirty)
        coordinator.updateActivity(false)
        XCTAssertFalse(view.footnoteNavigationHandler?(point(reference)) ?? true)
    }
}
