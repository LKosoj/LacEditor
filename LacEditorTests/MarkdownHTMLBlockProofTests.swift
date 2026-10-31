import AppKit
import XCTest
@testable import LacEditor

final class MarkdownHTMLBlockProofTests: XCTestCase {
    func testConfirmedHTMLBlocksPreserveSourceAndSafeStyle() throws {
        for block in ["<div><p>中文 😀</p><p>second</p></div>",
                      "<table><tr><th>head</th><td>cell</td></tr></table>",
                      "<details><summary>More</summary><p>first</p><p>second</p></details>",
                      "<div><span style='display:none;color:red'>visible</span></div>"] {
            for prefix in ["", "> "] {
                let source = ("before\r\n\r\n" + prefix + block + "\r\n\r\nafter") as NSString
                let result = MarkdownPresentationParser.parse(source as String)
                let candidate = try XCTUnwrap(result.htmlBlocks.first, source as String)
                XCTAssertEqual(source.substring(with: candidate.range), block)
                XCTAssertFalse(candidate.html.contains("display:none"))
                XCTAssertTrue(result.detailsBlocks.isEmpty)
            }
        }
    }

    func testUnsupportedHTMLBlockRemainsSource() {
        for block in ["<div class='x'>text</div>", "<div><img src='x'></div>",
                      "<div onclick='evil()'>text</div>", "<div><span style='position:fixed'>text</span></div>",
                      "<div><script>bad()</script></div>", "<div><p>bad</div></p>",
                      "<div><a href='javascript:alert(1)'>bad</a></div>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(block).htmlBlocks.isEmpty, block)
        }
    }

    @MainActor
    func testConfirmedHTMLBlockDisplaysAndRevealsSource() async throws {
        _ = NSApplication.shared
        let block = "<div><p>中文 😀</p><p>second</p></div>"
        let source = block + "\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500)); layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(raw.range(of: "end"))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where !view.subviews.contains(where: { $0 is MarkdownHTMLBlockView && $0.alphaValue == 1 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        var blockView = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.first { $0.alphaValue == 1 })
        XCTAssertGreaterThan(blockView.frame.height, 0)
        XCTAssertEqual(storage.string, source)
        XCTAssertEqual(view.accessibilityValue(), source)
        scroll.setFrameSize(NSSize(width: 1, height: 300)); view.setFrameSize(NSSize(width: 1, height: 300))
        container.containerSize = NSSize(width: 1, height: 500); controller.viewportChanged()
        XCTAssertNil(blockView.superview)
        scroll.setFrameSize(NSSize(width: 400, height: 300)); view.setFrameSize(NSSize(width: 400, height: 300))
        container.containerSize = NSSize(width: 400, height: 500); controller.viewportChanged()
        for _ in 0..<200 where !view.subviews.contains(where: { $0 is MarkdownHTMLBlockView && $0.alphaValue == 1 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        blockView = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.first { $0.alphaValue == 1 })
        view.setLayoutOrientation(.vertical); scroll.magnification = 1.5; controller.viewportChanged()
        for _ in 0..<200 where !view.subviews.contains(where: { $0 is MarkdownHTMLBlockView && $0.alphaValue == 1 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        blockView = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.first { $0.alphaValue == 1 })
        layout.ensureLayout(for: container)
        let geometry = try XCTUnwrap(layout.markdownMediaRect(for: raw.range(of: block), in: container))
        let expected = scroll.contentView.convert(geometry.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        let actual = scroll.contentView.convert(blockView.bounds, from: blockView)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
        let beforeComposition = blockView.frame
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30)); view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        controller.selectionChanged()
        XCTAssertEqual(blockView.frame, beforeComposition)
        XCTAssertEqual(storage.string, source)
        child.unmarkText(); child.removeFromSuperview(); controller.compositionFinished(revision: 0)
        view.setSelectedRange(raw.range(of: block)); controller.selectionChanged()
        XCTAssertNil(blockView.superview)
        XCTAssertEqual(storage.string, source)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), raw.range(of: block))
        XCTAssertFalse(document.isDirty)
    }

    @MainActor
    func testHTMLBlockResumesAfterMarkedInput() async throws {
        _ = NSApplication.shared
        let source = "<div><p>中文</p></div>\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500)); layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(raw.range(of: "end"))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30)); view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(view.subviews.contains { $0 is MarkdownHTMLBlockView && $0.alphaValue == 1 })
        child.unmarkText(); child.removeFromSuperview(); controller.compositionFinished(revision: 0)
        for _ in 0..<200 where !view.subviews.contains(where: { $0 is MarkdownHTMLBlockView && $0.alphaValue == 1 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(view.subviews.contains { $0 is MarkdownHTMLBlockView && $0.alphaValue == 1 })
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    /// Редактор в окне: живые вью вставок после набора вне их должны остаться теми же объектами.
    @MainActor
    final class InsertShiftFixture {
        let storage: NSTextStorage
        let layout = FoldLayoutManager()
        let container: NSTextContainer
        let view: LacTextView
        let scroll: NSScrollView
        let window: NSWindow
        let controller: MarkdownPresentationController
        let document: EditorDocument
        var revision: UInt = 0

        init(_ source: String, url: URL? = nil, selecting marker: String) {
            _ = NSApplication.shared
            document = EditorDocument(text: source, url: url, language: .markdown)
            storage = NSTextStorage(string: source)
            storage.addLayoutManager(layout)
            container = NSTextContainer(containerSize: NSSize(width: 500, height: 800))
            layout.addTextContainer(container)
            view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 800), textContainer: container)
            scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            controller = MarkdownPresentationController(textView: view, layout: layout)
            view.setSelectedRange((source as NSString).range(of: marker))
            controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { [unowned self] in revision })
        }

        func close() { controller.cancel(); window.close() }

        /// Печатает один символ после `marker` так же, как редактор: `beforeEdit`, правка текста, `edited`.
        func type(after marker: String, _ text: String = "x") {
            let edit = NSRange(location: NSMaxRange(storage.mutableString.range(of: marker)), length: 0)
            revision += 1
            controller.beforeEdit(range: edit, replacementLength: (text as NSString).length, replacement: text)
            storage.replaceCharacters(in: edit, with: text)
            controller.edited(revision: revision)
        }

        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        }

        /// Даёт отложенному пересчёту рамок и разбору отработать.
        func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }

        /// Раскрывает details нажатием на стрелку (сама вью закрытая, находим её по имени класса).
        func openDetails() -> Bool {
            guard let button = detailsButton() else { return false }
            button.performClick(nil)
            return true
        }

        func detailsView() -> NSView? {
            view.subviews.first(where: { String(describing: type(of: $0)).hasSuffix("MarkdownDetailsView") })
        }

        /// Стрелка раскрытия: её состояние показывает, открыт ли блок на экране.
        func detailsButton() -> NSButton? { detailsView()?.subviews.compactMap { $0 as? NSButton }.first }

        func htmlViews() -> [MarkdownHTMLBlockView] { view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.filter { $0.alphaValue == 1 } }
    }

    @MainActor
    func testTypingOutsideKeepsHTMLBlockView() async throws {
        let fixture = InsertShiftFixture("intro words\n\n<div><p>中文 😀</p><p>second</p></div>\n\nend words\n", selecting: "end words")
        defer { fixture.close() }
        try await fixture.wait { !fixture.htmlViews().isEmpty }
        let before = try XCTUnwrap(fixture.htmlViews().first)
        for marker in ["intro wor", "end wor"] {
            fixture.type(after: marker)
            try await fixture.settle()
            let after = try XCTUnwrap(fixture.htmlViews().first, marker)
            XCTAssertTrue(after === before, marker)
            XCTAssertNotNil(before.superview, marker)
        }
        // Вью следует за блоком: рамка совпадает с местом блока в слое.
        let range = (fixture.storage.string as NSString).range(of: "<div><p>")
        XCTAssertNotNil(fixture.layout.markdownMediaRect(for: NSRange(location: range.location, length: ("<div><p>中文 😀</p><p>second</p></div>" as NSString).length), in: fixture.container))
    }

    @MainActor
    func testTypingOutsideKeepsDetailsOpenState() async throws {
        let source = "intro words\n\n<details>\n<summary>Sum</summary>\n\nbody words\n</details>\n\nend words\n"
        let fixture = InsertShiftFixture(source, selecting: "end words")
        defer { fixture.close() }
        let raw = source as NSString
        let block = raw.range(of: "<details>\n<summary>Sum</summary>\n\nbody words\n</details>")
        try await fixture.wait { fixture.layout.canDisplayMarkdownMedia(block) && fixture.controller.detailsOpenOverrides.isEmpty }
        XCTAssertTrue(fixture.openDetails())
        XCTAssertEqual(fixture.controller.detailsOpenOverrides, [block: true])
        let before = try XCTUnwrap(fixture.detailsView())
        XCTAssertEqual(fixture.detailsButton()?.state, .on)
        fixture.type(after: "intro wor")
        try await fixture.settle()
        let moved = NSRange(location: block.location + 1, length: block.length)
        XCTAssertEqual(fixture.controller.detailsOpenOverrides, [moved: true])
        // Вью та же, а не созданная заново закрытой.
        XCTAssertTrue(try XCTUnwrap(fixture.detailsView()) === before)
        XCTAssertEqual(fixture.detailsButton()?.state, .on)
    }

    @MainActor
    func testUnconfirmedEditDropsInsertsAndDetailsState() async throws {
        let source = "intro words\n\n<details>\n<summary>Sum</summary>\n\nbody words\n</details>\n\n<div><p>中文</p></div>\n\nend words\n"
        let fixture = InsertShiftFixture(source, selecting: "end words")
        defer { fixture.close() }
        try await fixture.wait { !fixture.htmlViews().isEmpty }
        let htmlView = try XCTUnwrap(fixture.htmlViews().first)
        XCTAssertTrue(fixture.openDetails())
        // Правка внутри блока HTML быстрым путём не принимается: готовое снимается, состояние details сбрасывается.
        fixture.type(after: "<div><p>中")
        XCTAssertNil(htmlView.superview)
        XCTAssertTrue(fixture.controller.detailsOpenOverrides.isEmpty)
    }

    @MainActor
    func testTypingOutsideKeepsRenderedDiagram() async throws {
        let source = "intro words\n\n```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\nend words\n"
        let fixture = InsertShiftFixture(source, selecting: "end words")
        defer { fixture.close() }
        func resource() -> MarkdownPresentationController.DiagramResource? {
            let text = fixture.storage.string as NSString
            let block = text.range(of: "```flow\ns=>start: Start\ne=>end: End\ns->e\n```")
            fixture.layout.ensureLayout(for: fixture.container)
            guard let rect = fixture.layout.markdownRenderedImageRects(for: [block], in: fixture.container)[block] else { return nil }
            let origin = fixture.view.textContainerOrigin
            return fixture.controller.diagramResource(at: NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y))
        }
        try await fixture.wait { resource() != nil }
        let before = try XCTUnwrap(resource())
        for marker in ["intro wor", "end wor"] {
            fixture.type(after: marker)
            try await fixture.settle()
            let after = try XCTUnwrap(resource(), marker)
            XCTAssertTrue(after.image === before.image, marker)
        }
    }

    @MainActor
    func testTypingOutsideKeepsRubyImage() async throws {
        let source = "intro words\n\nRuby <ruby>漢字<rt>kanji</rt></ruby> end\n\nend words\n"
        let fixture = InsertShiftFixture(source, selecting: "end words")
        defer { fixture.close() }
        try await fixture.wait { !(fixture.layout.markdownListsSnapshot["inlineImages"] ?? []).isEmpty }
        let before = try XCTUnwrap(fixture.layout.markdownListsSnapshot["inlineImages"])
        XCTAssertFalse(before.isEmpty)
        fixture.type(after: "intro wor")
        let shifted = try XCTUnwrap(fixture.layout.markdownListsSnapshot["inlineImages"])
        XCTAssertEqual(shifted, [before[0] + 1, before[1]])
        try await fixture.settle()
        XCTAssertEqual(fixture.layout.markdownListsSnapshot["inlineImages"], shifted)
        XCTAssertEqual(fixture.layout.markdownListsSnapshot["rubyBaselines"]?.first, shifted.first)
    }
}
