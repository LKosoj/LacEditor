import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownImageInteractionTests: XCTestCase {
    func testUppercaseHeadingGIFSurvivesRevealAndResize() async throws {
        _ = NSApplication.shared
        let gif = "R0lGODlhBAAEAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAAEAAAICQABCBxIsCCAgAAh+QQBCgABACwAAAAABAAEAIEAAP8AAAAAAAAAAAAICQABCBxIsCCAgAA7"
        let source = "# 中文 mixed words before the picture and more words before ![icon](data:image/gif;base64,\(gif)) heading\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close() }
        controller.setUppercaseHeadingLevels([1])
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = try XCTUnwrap(MarkdownPresentationParser.parse(source).images.first?.range)
        func imageView() -> NSImageView? { view.subviews.compactMap { $0 as? NSImageView }.first }
        func imageRect() -> NSRect? {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [range], in: container)[range]
        }
        for _ in 0..<200 {
            if imageView()?.animates == true, imageRect() != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let animated = try XCTUnwrap(imageView())
        XCTAssertTrue(animated.animates)
        let rect = try XCTUnwrap(imageRect())
        XCTAssertNotNil(layout.uppercaseHeadingSourcePosition(at: NSPoint(x: rect.midX, y: rect.midY), in: container))
        view.setSelectedRange(range)
        controller.selectionChanged()
        XCTAssertNil(animated.superview)
        XCTAssertFalse(animated.animates)
        view.setSelectedRange((source as NSString).range(of: "end"))
        controller.selectionChanged()
        for _ in 0..<200 {
            if imageView()?.animates == true, imageRect() != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(try XCTUnwrap(imageView()).animates)
        let beforeResize = try XCTUnwrap(imageRect())
        scroll.setFrameSize(NSSize(width: 250, height: 400))
        view.setFrameSize(NSSize(width: 250, height: 400))
        container.containerSize = NSSize(width: 250, height: 400)
        controller.viewportChanged()
        for _ in 0..<200 {
            if imageView()?.animates == true, let current = imageRect(), current != beforeResize { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let afterResize = try XCTUnwrap(imageRect())
        XCTAssertNotEqual(afterResize, beforeResize)
        let finalView = try XCTUnwrap(imageView())
        XCTAssertTrue(finalView.animates)
        XCTAssertTrue(view.visibleRect.intersects(afterResize.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)))
        XCTAssertEqual(finalView.frame.origin.x, afterResize.minX + view.textContainerOrigin.x, accuracy: 1)
        XCTAssertEqual(finalView.frame.origin.y, afterResize.minY + view.textContainerOrigin.y, accuracy: 1)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }
    func testRawSVGLoadsResizesAndRevealsSource() async throws {
        _ = NSApplication.shared
        let svg = "<svg width='200' height='100'><rect width='200' height='100' fill='red'/></svg>"
        let source = svg + "\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange(raw.range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let image = try XCTUnwrap(MarkdownPresentationParser.parse(source).images.first)
        func rect() -> NSRect? {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [image.paragraphRange], in: container)[image.paragraphRange]
        }
        for _ in 0..<100 where rect() == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(try XCTUnwrap(rect()).width, 200, accuracy: 1)
        scroll.setFrameSize(NSSize(width: 100, height: 500)); view.setFrameSize(NSSize(width: 100, height: 500))
        container.containerSize = NSSize(width: 100, height: 500); controller.viewportChanged()
        for _ in 0..<100 where (rect()?.width ?? .infinity) > 100 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertLessThanOrEqual(try XCTUnwrap(rect()).width, 100)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        view.setSelectedRange(image.range); controller.selectionChanged()
        XCTAssertNotNil(rect())
        child.unmarkText(); child.removeFromSuperview()
        controller.compositionFinished(revision: 0)
        view.setSelectedRange(image.range); controller.selectionChanged()
        XCTAssertNil(rect())
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testInlineSVGRevealsOnlyItsSource() async throws {
        _ = NSApplication.shared
        let svg = "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let source = "前😀 " + svg + " after", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        let image = try XCTUnwrap(MarkdownPresentationParser.parse(source).images.first)
        XCTAssertTrue(image.isInline)
        let selection = raw.range(of: "after")
        view.setSelectedRange(selection)
        let undoBefore = view.undoManager?.canUndo
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func rect() -> NSRect? {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [image.range], in: container)[image.range]
        }
        for _ in 0..<100 where rect() == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(rect())
        XCTAssertEqual(view.selectedRange(), selection)
        view.setSelectedRange(image.range); controller.selectionChanged()
        XCTAssertNil(rect())
        XCTAssertEqual(view.selectedRange(), image.range)
        XCTAssertEqual(storage.string, source)
        XCTAssertEqual(view.undoManager?.canUndo, undoBefore)
        XCTAssertFalse(document.isDirty)
    }

    func testHTMLImagePercentageUpdatesAfterResize() async throws {
        _ = NSApplication.shared
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let source = "before <img src='data:image/png;base64,\(png)' width='50%'> after\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = try XCTUnwrap(MarkdownPresentationParser.parse(source).images.first?.range)
        func measured() -> CGFloat? {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [range], in: container)[range]?.width
        }
        for _ in 0..<30 {
            if measured() != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try XCTUnwrap(measured()), (400 - 2 * container.lineFragmentPadding) / 2, accuracy: 1)
        scroll.setFrameSize(NSSize(width: 200, height: 400))
        view.setFrameSize(NSSize(width: 200, height: 400))
        container.containerSize = NSSize(width: 200, height: 400)
        controller.viewportChanged()
        for _ in 0..<30 {
            if let width = measured(), width < 150 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try XCTUnwrap(measured()), (200 - 2 * container.lineFragmentPadding) / 2, accuracy: 1)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }
    func testVerticalListHTMLImagePercentageUsesPhysicalWidth() async throws {
        _ = NSApplication.shared
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let source = "before\n\n- <img src='data:image/png;base64,\(png)' width='50%'>\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        view.setLayoutOrientation(.vertical)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let image = try XCTUnwrap(MarkdownPresentationParser.parse(source).images.first)
        let key = image.isInline ? image.range : image.paragraphRange
        var rect: NSRect?
        for _ in 0..<30 {
            layout.ensureLayout(for: container)
            rect = layout.markdownRenderedImageRects(for: [key], in: container)[key]
            if rect != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let local = try XCTUnwrap(rect).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let physical = scroll.contentView.convert(local, from: view)
        let expected = max(1, scroll.contentView.bounds.width - layout.markdownMediaIndent(for: image.paragraphRange)) / 2
        XCTAssertEqual(physical.width, expected, accuracy: 1)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }
    func testZeroSizedInlineImageKeepsSourceAndHasNoHitArea() throws {
        let source = "before <img src='x.png' width='0'> after"
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let range = (source as NSString).range(of: "<img src='x.png' width='0'>")
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.size = .zero
        XCTAssertTrue(layout.setMarkdownInlineImage(image, for: range))
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [range], in: container)[range])
        XCTAssertEqual(rect.size, .zero)
        XCTAssertNil(layout.markdownImageLocation(at: rect.origin, in: container))
        XCTAssertEqual(storage.string, source)
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: range)
        XCTAssertNil(layout.markdownRenderedImageRects(for: [range], in: container)[range])
        withExtendedLifetime(view) {}
    }

    func testZeroSizedHTMLImageInTableKeepsSource() throws {
        let source = "| H |\n|---|\n| <img src='x.png' width='0'> |"
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let result = MarkdownPresentationParser.parse(source)
        let range = try XCTUnwrap(result.images.first?.range)
        let cell = try XCTUnwrap(result.tables.first?.rows.last?.cells.first)
        XCTAssertTrue(cell.displayRuns.contains { if case .tableImage = $0.kind { return true }; return false })
        layout.setMarkdownPresentation(result, revealedRange: nil)
        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.size = .zero
        XCTAssertTrue(layout.setMarkdownInlineImage(image, for: range))
        layout.ensureLayout(for: container)
        if let rect = layout.markdownRenderedImageRects(for: [range], in: container)[range] {
            XCTAssertTrue(rect.width == 0 || rect.height == 0)
        }
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }
    func testStandaloneImagesAreCenteredWithinAvailableWidthAndHitTest() throws {
        let source = "![a](a.png)\n\n- ![b](b.png)\n\nend"
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 600))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        let first = (source as NSString).range(of: "![a](a.png)")
        let second = (source as NSString).range(of: "![b](b.png)")
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        layout.setMarkdownImage(NSImage(size: NSSize(width: 100, height: 40)), for: first)
        layout.setMarkdownImage(NSImage(size: NSSize(width: 100, height: 40)), for: second)
        layout.ensureLayout(for: container)
        let rectangles = layout.markdownRenderedImageRects(for: [first, second], in: container)
        let firstRect = try XCTUnwrap(rectangles[first]), secondRect = try XCTUnwrap(rectangles[second])
        XCTAssertEqual(firstRect.midX, 200, accuracy: 1)
        XCTAssertGreaterThan(secondRect.midX, firstRect.midX)
        XCTAssertEqual(layout.markdownImageLocation(at: NSPoint(x: firstRect.midX, y: firstRect.midY), in: container), first.location)
        XCTAssertEqual(layout.markdownImageLocation(at: NSPoint(x: secondRect.midX, y: secondRect.midY), in: container), second.location)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }
    func testVirtualCellImageDialogCancelAndConfirm() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try png.write(to: file)
        let source = "| A | B | C |\n| --- | --- | --- |\n| x"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("note.md"), language: .markdown)
        document.isMarkdownFormatted = true
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
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
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.last)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: cell))
        var generation = 0, attempts = 0
        var completed = false, timedOut = false
        var finished = false
        defer {
            generation += 1
            if !finished {
                document.text = "dialog interrupted"
                if NSApp.modalWindow != nil { NSApp.abortModal() }
            }
        }
        func scheduleDialog(confirm: Bool) {
            generation += 1
            let current = generation
            attempts = 0
            completed = false
            func act() {
                guard current == generation, !completed else { return }
                attempts += 1
                if let modal = NSApp.modalWindow {
                    if !confirm { completed = true; NSApp.abortModal(); return }
                    func button(in view: NSView) -> NSButton? {
                        if let button = view as? NSButton, button.title == L10n.tr("应用") { return button }
                        return view.subviews.compactMap { button(in: $0) }.first
                    }
                    if let content = modal.contentView, let apply = button(in: content) {
                        completed = true
                        apply.performClick(nil)
                        return
                    }
                }
                if attempts < 100 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() } }
                else {
                    timedOut = true; completed = true
                    document.text = "dialog timed out"
                    if NSApp.modalWindow != nil { NSApp.abortModal() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }
        }
        scheduleDialog(confirm: false)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .file(file)))
        for _ in 0..<150 where !completed { try await Task.sleep(for: .milliseconds(20)) }
        guard completed, !timedOut else { XCTFail("Cancel dialog did not complete"); return }
        XCTAssertEqual(view.string, source)
        XCTAssertNotNil(view.subviews.first { $0 is MarkdownTableCellEditor })
        scheduleDialog(confirm: true)
        XCTAssertTrue(state.presentMarkdownImage(transfer: .file(file)))
        for _ in 0..<150 where view.string == source { try await Task.sleep(for: .milliseconds(20)) }
        generation += 1
        guard completed, !timedOut, view.string == source + "||![](<image.png>)" else {
            XCTFail("Image dialog did not insert into the selected cell"); return
        }
        finished = true
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: file), png)
    }

    func testVirtualCellLinkDialogCancelAndConfirm() throws {
        _ = NSApplication.shared
        let source = "| A | B | C |\n| --- | --- | --- |\n| x"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
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
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.last)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: cell))
        var timedOut = false
        var waitingForDialog = false
        var dialogGeneration = 0
        var didCancelDialog = false
        func scheduleDialog(confirm: Bool) {
            waitingForDialog = true
            dialogGeneration += 1
            let generation = dialogGeneration
            var attempts = 0
            func act() {
                guard waitingForDialog, generation == dialogGeneration else { return }
                attempts += 1
                if let modal = NSApp.modalWindow {
                    if !confirm { didCancelDialog = true; NSApp.abortModal(); return }
                    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                    let controls = modal.contentView.map(descendants) ?? []
                    let fields = controls.compactMap { $0 as? NSTextField }.filter(\.isEditable)
                    let button = controls.compactMap { $0 as? NSButton }.first { $0.title == L10n.tr("应用") }
                    if fields.count == 2, let button {
                        fields[0].stringValue = "中文"
                        fields[1].stringValue = "https://example.com"
                        button.performClick(nil)
                        return
                    }
                }
                if attempts < 100 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() } }
                else { timedOut = true; if NSApp.modalWindow != nil { NSApp.abortModal() } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { act() }
        }
        scheduleDialog(confirm: false)
        state.presentMarkdownLink()
        waitingForDialog = false
        XCTAssertFalse(timedOut)
        XCTAssertTrue(didCancelDialog)
        XCTAssertEqual(view.string, source)
        XCTAssertNotNil(view.subviews.first { $0 is MarkdownTableCellEditor })
        scheduleDialog(confirm: true)
        state.presentMarkdownLink()
        waitingForDialog = false
        XCTAssertFalse(timedOut)
        XCTAssertEqual(view.string, source + "||[中文](<https://example.com>)")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
    }

    func testVirtualCellRequestPreservesTargetUntilConfirmedAndRejectsStale() throws {
        _ = NSApplication.shared
        let source = "| A | B | C |\n| --- | --- | --- |\n| x"
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
        let cells = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells)
        func selection() -> EditorTextSelectionSnapshot? {
            let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        func open(_ cell: MarkdownTableCell) {
            XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: cell))
        }
        open(cells[1])
        let first = try XCTUnwrap(selection())
        XCTAssertEqual(first.virtualTableTarget?.column, 1)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(first.matches(try XCTUnwrap(selection())))
        open(cells[2])
        let second = try XCTUnwrap(selection())
        XCTAssertEqual(second.virtualTableTarget?.column, 2)
        XCTAssertFalse(first.matches(second))
        let stale = EditorRangeReplacementRequest(documentID: document.id, range: first.range, originalText: "",
            replacementText: "|![a](<img.png>)", expectedEditorRevision: first.editorRevision, actionName: "Image")
        stale.virtualTableTarget = first.virtualTableTarget
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: stale)
        XCTAssertFalse(stale.wasHandled)
        XCTAssertEqual(view.string, source)
        let target = try XCTUnwrap(second.virtualTableTarget)
        let candidate = (source as NSString).replacingCharacters(in: target.range, with: "||") as NSString
        let candidateSelection = NSRange(location: target.range.location + 2, length: 0)
        let edit = try XCTUnwrap(MarkdownImageEditingService.edit(in: candidate, selection: candidateSelection,
            input: MarkdownImageInput(alt: "😀", address: "img.png", title: "")))
        let request = EditorRangeReplacementRequest(documentID: document.id, range: target.range, originalText: "",
            replacementText: "||" + edit.replacement, expectedEditorRevision: second.editorRevision, actionName: "Image")
        request.virtualTableTarget = target
        request.resultingSelection = edit.selectionRange
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertTrue(request.wasHandled)
        XCTAssertEqual(view.string, source + "||![😀](<img.png>)")
        XCTAssertEqual(view.selectedRange(), edit.selectionRange)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        try XCTUnwrap(view.undoManager).redo()
        XCTAssertEqual(view.string, source + "||![😀](<img.png>)")
    }

    func testCellPasteRoutesImageAtMappedCaretAndPreservesMarkedText() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let source = "| A | B |\n| --- | --- |\n| a\\|b<br>😀 | x |"
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
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: cell))
        var child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let emoji = (child.string as NSString).range(of: "😀")
        child.setSelectedRange(NSRange(location: NSMaxRange(emoji), length: 0))
        var receivedRange: NSRange?
        let token = NotificationCenter.default.addObserver(forName: EditorCommandNotification.insertMarkdownImage, object: nil, queue: nil) { notification in
            MainActor.assumeIsolated {
                guard let request = notification.object as? MarkdownImageTransferRequest else { return }
                receivedRange = view.selectedRange()
                request.handled = true
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        board.clearContents()
        board.setData(Data([137, 80, 78, 71]), forType: .png)
        child.paste(nil)
        XCTAssertEqual(receivedRange, NSRange(location: NSMaxRange((source as NSString).range(of: "😀")), length: 0))
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty)

        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: cell))
        child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        receivedRange = nil
        child.paste(nil)
        XCTAssertNil(receivedRange)
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertEqual(view.string, source)
    }

    func testCellPastePrefersTextInMixedPasteboard() {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let parent = LacTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let child = MarkdownTableCellEditor(frame: parent.frame)
        child.isRichText = false
        child.string = "a"
        child.setSelectedRange(NSRange(location: 1, length: 0))
        var imageCalls = 0
        child.imageTransfer = { pasteboard, preferText in
            guard parent.imageTransfer(from: pasteboard, preferText: preferText) != nil else { return false }
            imageCalls += 1
            return true
        }
        let item = NSPasteboardItem()
        item.setString(" text", forType: .string)
        item.setString(URL(fileURLWithPath: "/tmp/image.png").absoluteString, forType: .fileURL)
        board.clearContents()
        board.writeObjects([item])
        child.paste(nil)
        XCTAssertEqual(child.string, "a text")
        XCTAssertEqual(imageCalls, 0)
    }

    func testExtractionMapsCellSelectionAcrossEscapesAndUnicode() throws {
        _ = NSApplication.shared
        let source = "| A | B |\n| --- | --- |\n| a\\|b<br>😀 | x |"
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
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange((child.string as NSString).range(of: "😀"))
        let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
        XCTAssertEqual(request.result?.range, (source as NSString).range(of: "😀"))
        XCTAssertEqual(request.result?.text, "😀")
        XCTAssertEqual(view.string, source)
    }
    func testImageDragTypesSurviveSystemRegistrationChanges() {
        _ = NSApplication.shared
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.isRichText = false
        view.isEditable = true
        view.updateDragTypeRegistration()
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] {
            XCTAssertTrue(view.registeredDraggedTypes.contains(type))
        }
        view.isEditable = false
        view.updateDragTypeRegistration()
        XCTAssertFalse(view.registeredDraggedTypes.contains(.fileURL))
        view.isEditable = true
        view.updateDragTypeRegistration()
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(view.registeredDraggedTypes.contains(.png))
    }

    func testImageCommandsUseCellCaretAndRefuseMarkedText() throws {
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
        XCTAssertTrue(coordinator.beginTableCell(cell, frame: NSRect(x: 0, y: 0, width: 100, height: 30)))
        var child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setSelectedRange(NSRange(location: 1, length: 0))
        func extraction() -> EditorTextExtractionRequest {
            let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request
        }
        XCTAssertEqual(extraction().result?.range, NSRange(location: cell.location + 1, length: 0))
        XCTAssertTrue(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty)
        XCTAssertTrue(coordinator.beginTableCell(cell, frame: NSRect(x: 0, y: 0, width: 100, height: 30)))
        child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertNil(extraction().result)
        let request = EditorRangeReplacementRequest(documentID: document.id, range: cell, originalText: "one",
            replacementText: "![x](x.png)", expectedEditorRevision: 0, actionName: "Image")
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertFalse(request.wasHandled)
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(child.hasMarkedText())
    }
    func testChosenFileRunsRealImageDialogAndInsertsSource() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        try await checkImageDialog(name: "图 (1).png", data: png, expected: "%E5%9B%BE%20%281%29.png")
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'/>".utf8)
        try await checkImageDialog(name: "figure.svg", data: svg, expected: "figure.svg")
    }

    private func checkImageDialog(name: String, data: Data, expected: String) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try data.write(to: file)
        let document = EditorDocument(text: "", url: folder.appendingPathComponent("note.md"), language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: "")
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
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        var attempts = 0
        var dialogTimedOut = false
        func acceptDialog() {
            attempts += 1
            if let modal = NSApp.modalWindow {
                func findButton(_ view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == L10n.tr("应用") { return button }
                    return view.subviews.compactMap(findButton).first
                }
                if let content = modal.contentView, let button = findButton(content) { button.performClick(nil); return }
            }
            if attempts < 100 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { acceptDialog() }
            } else {
                dialogTimedOut = true
                document.text = "dialog timed out"
                if NSApp.modalWindow != nil { NSApp.abortModal() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { acceptDialog() }
        XCTAssertTrue(state.presentMarkdownImage(transfer: .file(file)))
        for _ in 0..<100 where view.string.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(dialogTimedOut)
        XCTAssertTrue(view.string.contains(expected))
        XCTAssertEqual(try Data(contentsOf: file), data)
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testImageReplacementUndoDoesNotDeleteFile() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("图 (1).png")
        let data = Data([1, 2, 3])
        try data.write(to: file)
        let source = "text 中文😀"
        let document = EditorDocument(text: source, url: folder.appendingPathComponent("note.md"), language: .markdown)
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
        let selected = (source as NSString).range(of: "中文😀")
        view.setSelectedRange(selected)
        let extract = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extract)
        let snapshot = try XCTUnwrap(extract.result)
        let address = try XCTUnwrap(MarkdownImageEditingService.address(for: file, document: document.url))
        let edit = try XCTUnwrap(MarkdownImageEditingService.edit(in: source as NSString, selection: selected,
            input: MarkdownImageInput(alt: "中文😀", address: address, title: "title")))
        let request = EditorRangeReplacementRequest(documentID: document.id, range: edit.range, originalText: snapshot.text,
            replacementText: edit.replacement, expectedEditorRevision: snapshot.editorRevision, actionName: "Image")
        request.resultingSelection = edit.selectionRange
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertTrue(request.wasHandled)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "中文😀")
        let inserted = view.string
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(try Data(contentsOf: file), data)
        undo.redo()
        XCTAssertEqual(view.string, inserted)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testActualPasteRoutesImageAndLeavesTextPasteToEditor() {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.isEditable = true
        view.string = "before"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        var received: Data?
        var calls = 0
        view.imageTransferHandler = { transfer in
            calls += 1
            if case let .data(data) = transfer { received = data; return true }
            return false
        }
        let png = Data([137, 80, 78, 71])
        board.clearContents()
        board.setData(png, forType: .png)
        view.paste(nil)
        XCTAssertEqual(received, png)
        XCTAssertEqual(view.string, "before")
        board.clearContents()
        board.setString(" text", forType: .string)
        view.paste(nil)
        XCTAssertEqual(view.string, "before text")
        XCTAssertEqual(received, png)
        received = nil
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(" pasted text", forType: .string)
        item.setString(URL(fileURLWithPath: "/tmp/image.png").absoluteString, forType: .fileURL)
        board.writeObjects([item])
        view.paste(nil)
        XCTAssertEqual(view.string, "before text pasted text")
        XCTAssertNil(received)
        XCTAssertEqual(calls, 1)
    }
}
