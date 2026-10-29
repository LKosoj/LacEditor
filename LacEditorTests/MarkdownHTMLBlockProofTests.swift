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
        XCTAssertEqual(view.accessibilityValue() as? String, source)
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
}
