import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownImageTests: XCTestCase {
    func testRawSVGIsNotAFileImageReference() throws {
        let source = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20'/></svg>" as NSString
        let selection = NSRange(location: 0, length: source.length)
        XCTAssertTrue(try MarkdownImageUploadService.images(in: source as String, selection: selection).isEmpty)
        let input = try XCTUnwrap(MarkdownImageEditingService.initial(in: source, selection: selection))
        XCTAssertEqual(input.alt, source as String)
        XCTAssertEqual(input.address, "")
    }

    func testHTMLImagesUseConfirmedSourceAndTableRun() {
        let source = "中文😀\r\n\r\n<img src='block.png' width='40'>\r\n\r\ntext <img src=inline.png style='height:20px'> tail\r\n\r\n| H |\r\n|---|\r\n| <img src='cell.png' width='50%'> |\r\n\r\n<script><img src='hidden.png'></script>"
        let text = source as NSString
        let result = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(result.images.map(\.url), ["block.png", "inline.png", "cell.png"])
        XCTAssertEqual(result.images.map { text.substring(with: $0.range) }, ["<img src='block.png' width='40'>", "<img src=inline.png style='height:20px'>", "<img src='cell.png' width='50%'>"])
        guard let table = result.tables.first, table.rows.count > 1, let cell = table.rows[1].cells.first else { return XCTFail("missing table cell") }
        XCTAssertTrue(cell.displayRuns.contains { if case .tableImage = $0.kind { return true }; return false })
        let nested = MarkdownPresentationParser.parse("| H |\n|---|\n| **<img src='x.png'>** |")
        guard let nestedTable = nested.tables.first, nestedTable.rows.count > 1,
              let nestedCell = nestedTable.rows[1].cells.first else { return XCTFail("missing nested table cell") }
        XCTAssertEqual(nested.images.map(\.url), ["x.png"])
        XCTAssertTrue(nestedCell.displayRuns.contains { if case .tableImage = $0.kind { return true }; return false })
        for mixed in ["<div><select><img src='hidden.png'></select></div>", "<table><img src='misplaced.png'></table>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(mixed).images.isEmpty)
        }
        let block = "<div>text<img src='first.png'><template><img src='hidden.png'></template><img src='second.png'></div>"
        let blockImages = MarkdownPresentationParser.parse(block).images
        XCTAssertEqual(blockImages.map(\.url), ["first.png", "second.png"])
        XCTAssertTrue(blockImages.allSatisfy(\.isInline))
        let quoted = "> <div>\r\n> text<img src='quoted.png'>\r\n> </div>"
        let quoteImages = MarkdownPresentationParser.parse(quoted).images
        XCTAssertEqual(quoteImages.map(\.url), ["quoted.png"])
        if let image = quoteImages.first { XCTAssertEqual((quoted as NSString).substring(with: image.range), "<img src='quoted.png'>") }
        let split = "before <select> text <img src='hidden.png'> text </select> after <img src='visible.png'>"
        XCTAssertEqual(MarkdownPresentationParser.parse(split).images.map(\.url), ["visible.png"])
        let heading = "# 中文 <img src='heading.png' width='50%'>\n\nend"
        let parsedHeading = MarkdownPresentationParser.parse(heading)
        XCTAssertEqual(parsedHeading.images.map(\.url), ["heading.png"])
        XCTAssertEqual(parsedHeading.images.first?.isInline, true)
        XCTAssertEqual(parsedHeading.images.first?.paragraphRange, parsedHeading.headings.first?.range)
        XCTAssertEqual(parsedHeading.images.first?.sizing?.width, .percent(50))
    }
    func testDataImageIsDisplayedWithoutChangingSourceAndClearsAfterEdit() async throws {
        _ = NSApplication.shared
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let source = "before\n\n![图](data:image/png;base64,\(png.base64EncodedString()))\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        let range = (source as NSString).range(of: "![图](data:")
        func point() -> NSPoint {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return NSPoint(x: rect.minX + container.lineFragmentPadding + 0.5, y: rect.minY + 0.5)
        }
        for _ in 0..<30 {
            if layout.markdownImageLocation(at: point(), in: container) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), range.location)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        controller.update(document: document, enabled: true, isActive: false, revision: revision, currentRevision: { revision })
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        for _ in 0..<30 {
            if layout.markdownImageLocation(at: point(), in: container) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), range.location)
        XCTAssertEqual(storage.string, source)
        revision += 1
        controller.beforeEdit(range: NSRange(location: 0, length: 0), replacementLength: 1)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        controller.edited(revision: revision)
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        controller.cancel()
    }

    func testRemoteAndMissingRelativeImageRemainSource() async throws {
        _ = NSApplication.shared
        for address in ["https://example.invalid/a.png", "missing.png"] {
            let source = "before\n\n![image](\(address))"
            let document = EditorDocument(text: source, language: .markdown)
            let storage = NSTextStorage(string: source)
            let layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let controller = MarkdownPresentationController(textView: view, layout: layout)
            controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(storage.string, source)
            let range = (source as NSString).range(of: "![image]")
            layout.ensureLayout(for: container)
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            XCTAssertNil(layout.markdownImageLocation(at: NSPoint(x: rect.minX + 1, y: rect.minY + 1), in: container))
            controller.cancel()
        }
    }
    func testLocalImageAndCancelledRevision() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        try png.write(to: directory.appendingPathComponent("图 1.png"))
        let source = "before\n\n![image](%E5%9B%BE%201.png)"
        let document = EditorDocument(text: source, url: directory.appendingPathComponent("doc.md"), language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        let imageLocation = (source as NSString).range(of: "![image]").location
        func point() -> NSPoint {
            layout.ensureLayout(for: container)
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: imageLocation), effectiveRange: nil)
            return NSPoint(x: rect.minX + container.lineFragmentPadding + 0.5, y: rect.minY + 0.5)
        }
        for _ in 0..<30 {
            if layout.markdownImageLocation(at: point(), in: container) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), imageLocation)
        revision += 1
        controller.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        XCTAssertEqual(storage.string, source)
    }
    func testStaleRevisionBeforeParseDoesNotDisplayImage() async throws {
        _ = NSApplication.shared
        let source = "before\n\n![image](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC)"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        revision += 1
        try await Task.sleep(for: .milliseconds(500))
        let location = (source as NSString).range(of: "![image]").location
        layout.ensureLayout(for: container)
        let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
        XCTAssertNil(layout.markdownImageLocation(at: NSPoint(x: rect.minX + 1, y: rect.minY + 1), in: container))
        XCTAssertEqual(storage.string, source)
        controller.cancel()
    }
    func testTaskImageRemainsSourceBesideCheckbox() async throws {
        _ = NSApplication.shared
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let source = "before\n\n- [ ] ![a](data:image/png;base64,\(png))"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let marker = (source as NSString).range(of: "[ ]")
        func checkboxPoint() -> NSPoint {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        for _ in 0..<30 {
            if layout.markdownTaskCheckbox(at: checkboxPoint(), in: container) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(layout.markdownTaskCheckbox(at: checkboxPoint(), in: container))
        XCTAssertNil(layout.markdownImageLocation(at: checkboxPoint(), in: container))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        controller.cancel()
    }

}
