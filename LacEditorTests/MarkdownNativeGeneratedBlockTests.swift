import AppKit
import XCTest
@testable import LacEditor

private final class InlineMathGlyphProbe: NSObject, NSLayoutManagerDelegate {
    var requestedBounds = false
    func layoutManager(_ manager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange range: NSRange) -> Int {
        var properties = Array(UnsafeBufferPointer(start: properties, count: range.length))
        var changed = false
        for i in properties.indices {
            switch characterIndexes[i] {
            case 1: properties[i] = .controlCharacter; changed = true
            case 2, 3: properties[i] = .null; changed = true
            default: break
            }
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { manager.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: range) }
        return range.length
    }
    func layoutManager(_ manager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
        index == 1 ? .whitespace : action
    }
    func layoutManager(_ manager: NSLayoutManager, boundingBoxForControlGlyphAt glyph: Int, for container: NSTextContainer,
                       proposedLineFragment rect: NSRect, glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
        requestedBounds = true
        return NSRect(x: 0, y: 0, width: 80, height: 32)
    }
}

@MainActor
final class MarkdownNativeGeneratedBlockTests: XCTestCase {
    func testControllerRendersEmojiInTableWithoutChangingSource() async throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 **:smile:** |\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
        let cell = try XCTUnwrap(parsed.tables.first?.rows.last?.cells.first)
        let candidate = try XCTUnwrap(parsed.emojiCandidates.first)
        for _ in 0..<200 {
            if layout.tableCellAttributedText(cell, text: storage.mutableString).string.contains("\u{fffc}") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(layout.tableCellAttributedText(cell, text: storage.mutableString).string.contains("\u{fffc}"))
        let font = try XCTUnwrap(layout.markdownTableEmojiFonts(for: [candidate.range])[candidate.range])
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }

    func testEmojiUsesHeadingFontSize() async throws {
        _ = NSApplication.shared
        let source = "# :smile:\n\n:smile:\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 800))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
        XCTAssertEqual(parsed.emojiCandidates.count, 2)
        guard parsed.emojiCandidates.count == 2 else { return }
        func imageAt(_ range: NSRange) -> Bool {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layout.location(forGlyphAt: glyph)
            return layout.markdownImageLocation(at: NSPoint(x: line.minX + position.x + 1, y: line.minY + position.y - 1), in: container) == range.location
        }
        for _ in 0..<200 {
            if parsed.emojiCandidates.allSatisfy({ imageAt($0.range) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(parsed.emojiCandidates.allSatisfy { imageAt($0.range) })
        let headingGlyph = layout.glyphIndexForCharacter(at: parsed.emojiCandidates[0].range.location)
        let bodyGlyph = layout.glyphIndexForCharacter(at: parsed.emojiCandidates[1].range.location)
        let heading = layout.boundingRect(forGlyphRange: NSRange(location: headingGlyph, length: 1), in: container)
        let body = layout.boundingRect(forGlyphRange: NSRange(location: bodyGlyph, length: 1), in: container)
        XCTAssertGreaterThan(heading.width, body.width)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testEmojiResolutionDoesNotApplyAfterDocumentSwitch() async throws {
        _ = NSApplication.shared
        let first = "before :smile: after\n\nend", second = "before :other: after\n\nend"
        let firstDocument = EditorDocument(text: first, language: .markdown)
        let secondDocument = EditorDocument(text: second, language: .markdown)
        let storage = NSTextStorage(string: first), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 800))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (first as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let started = expectation(description: "first emoji resolution started")
        let finished = expectation(description: "first emoji resolution finished")
        let secondFinished = expectation(description: "second emoji resolution published on main")
        controller.emojiResolutionDidComplete = { secondFinished.fulfill() }
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var calls = 0
        controller.emojiResolver = { _, _ in
            lock.lock(); calls += 1; let call = calls; lock.unlock()
            if call == 1 { started.fulfill(); gate.wait(); finished.fulfill(); return ["smile": "😄", "other": "😄"] }
            return [:]
        }
        defer { gate.signal(); controller.cancel() }
        controller.update(document: firstDocument, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [started], timeout: 10)
        view.string = second
        controller.update(document: secondDocument, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        gate.signal()
        await fulfillment(of: [finished, secondFinished], timeout: 10)
        let range = (second as NSString).range(of: ":other:")
        layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
        let glyph = layout.glyphIndexForCharacter(at: range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = layout.location(forGlyphAt: glyph)
        let point = NSPoint(x: line.minX + position.x + 1, y: line.minY + position.y - 1)
        XCTAssertNil(layout.markdownImageLocation(at: point, in: container))
        XCTAssertEqual(storage.string, second)
        withExtendedLifetime(scroll) {}
    }

    func testTableEmojiFontsCoverManyRunsInOneCell() throws {
        let source = "| A |\n|---|\n| **" + Array(repeating: ":smile:", count: 200).joined(separator: " ") + "** |"
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        let ranges = parsed.emojiCandidates.map(\.range)
        XCTAssertEqual(ranges.count, 200)
        let fonts = layout.markdownTableEmojiFonts(for: ranges)
        XCTAssertEqual(fonts.count, 200)
        XCTAssertTrue(fonts.values.allSatisfy { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) })
    }

    func testTableEmojiFontsFindWideRowCells() throws {
        let header = "| " + Array(repeating: "A", count: 100).joined(separator: " | ") + " |"
        let separator = "| " + Array(repeating: "---", count: 100).joined(separator: " | ") + " |"
        let row = "| " + Array(repeating: ":smile:", count: 100).joined(separator: " | ") + " |"
        let source = [header, separator, row].joined(separator: "\n")
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        let ranges = parsed.emojiCandidates.map(\.range)
        XCTAssertEqual(ranges.count, 100)
        XCTAssertEqual(layout.markdownTableEmojiFonts(for: ranges).count, 100)
    }

    func testTableEmojiAttachmentPreservesLinkHitAfterReplacement() throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 :smile: [link](page.md) |"
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
        let cell = try XCTUnwrap(parsed.tables.first?.rows.last?.cells.first)
        let candidate = try XCTUnwrap(parsed.emojiCandidates.first)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 450, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        XCTAssertTrue(layout.setMarkdownInlineImage(image, for: candidate.range))
        let display = layout.tableCellAttributedText(cell, text: storage.mutableString)
        XCTAssertTrue(display.string.contains("\u{fffc}"))
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

    func testEmojiRendersRevealsAndClearsAfterMarkedEdit() async throws {
        _ = NSApplication.shared
        let source = "中😀 :smile: text\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 800))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        let range = (source as NSString).range(of: ":smile:")
        func point() -> NSPoint {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layout.location(forGlyphAt: glyph)
            return NSPoint(x: line.minX + position.x + 1, y: line.minY + position.y - 1)
        }
        for _ in 0..<200 {
            if layout.markdownImageLocation(at: point(), in: container) == range.location { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), range.location)
        view.setSelectedRange(range)
        controller.selectionChanged()
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        controller.selectionChanged()
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), range.location)
        let end = (source as NSString).range(of: "end")
        view.setMarkedText("changed", selectedRange: NSRange(location: 7, length: 0), replacementRange: end)
        XCTAssertTrue(view.hasMarkedText())
        controller.beforeEdit(range: end, replacementLength: 7)
        revision += 1
        view.unmarkText()
        controller.compositionFinished(revision: revision)
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        XCTAssertEqual(storage.string, "中😀 :smile: text\n\nchanged")
        withExtendedLifetime(scroll) {}
    }

    func testInlineControlGlyphCanReserveFormulaWidth() {
        let source = "A$x$B"
        let storage = NSTextStorage(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layout = NSLayoutManager()
        let probe = InlineMathGlyphProbe()
        layout.delegate = probe
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let startGlyph = layout.glyphIndexForCharacter(at: 1)
        let endGlyph = layout.glyphIndexForCharacter(at: 4)
        let start = layout.location(forGlyphAt: startGlyph)
        let end = layout.location(forGlyphAt: endGlyph)
        XCTAssertTrue(probe.requestedBounds)
        XCTAssertGreaterThanOrEqual(end.x - start.x, 79)
        XCTAssertEqual(storage.string, source)
    }

    func testListBlockImageDoesNotCoverListMarker() {
        _ = NSApplication.shared
        let source = "- $$\n  x\n  $$\n\nafter"
        let range = (source as NSString).range(of: "$$\n  x\n  $$")
        let storage = NSTextStorage(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 240, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 300), textContainer: container)
        let image = NSImage(size: NSSize(width: 60, height: 30), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        layout.setMarkdownBlockImage(image, for: range)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let marker = NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 1)
        let content = NSPoint(x: line.minX + layout.location(forGlyphAt: glyph).x + 1, y: line.minY + 1)
        XCTAssertNil(layout.markdownImageLocation(at: marker, in: container))
        XCTAssertEqual(layout.markdownImageLocation(at: content, in: container), range.location)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testInlineImageReservesSpaceAndRevealsSource() {
        _ = NSApplication.shared
        let source = "A$x$B\n\nafter"
        let storage = NSTextStorage(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let formula = NSRange(location: 1, length: 3)
        let image = NSImage(size: NSSize(width: 80, height: 30), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        XCTAssertTrue(layout.setMarkdownInlineImage(image, for: formula))
        layout.ensureLayout(for: container)
        let start = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 1))
        let end = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 4))
        XCTAssertGreaterThanOrEqual(end.x - start.x, 79)
        layout.updateMarkdownRevealedRange(formula)
        layout.ensureLayout(for: container)
        let revealed = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 4))
        XCTAssertLessThan(revealed.x - start.x, 79)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testFormulaUsesSharedCmarkAndLeavesUnclosedMarkdown() throws {
        let source = "😀\n\n$$\n# fake\n[id]: https://example.invalid\n$$\n\n# real\n\n$$\n\n# still real"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.headings.map(\.title), ["real", "still real"])
        let formula = try XCTUnwrap(parsed.formulas.first)
        XCTAssertEqual(parsed.formulas.count, 1)
        XCTAssertEqual((source as NSString).substring(with: formula.range), "$$\n# fake\n[id]: https://example.invalid\n$$")
        XCTAssertTrue(formula.source.contains("# fake"))
        XCTAssertFalse(parsed.spans.contains { $0.kind == .codeBlock && $0.range == formula.range })
    }

    func testInlineFormulaRangesIncludeEscapedTablePipes() {
        let source = "😀 $x$ `code $bad$` \\$z$\r\n\r\n> 中文 $q$\r\n\r\n| A |\r\n|---|\r\n| a\\|b $c\\|d$ |"
        let formulas = MarkdownPresentationParser.parse(source).inlineFormulas
        XCTAssertEqual(formulas.map(\.source), ["x", "q", "c|d"])
        let raw = source as NSString
        XCTAssertEqual(formulas.map { raw.substring(with: $0.range) }, ["$x$", "$q$", "$c\\|d$"])
    }

    func testHeadingKeepsInlineFormulaInOutlineAndSource() {
        let source = "# 中文😀 $x^2$ and `code $y$`\r\n"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.headings.map(\.title), ["中文😀 $x^2$ and code $y$"])
        XCTAssertEqual(parsed.inlineFormulas.map(\.source), ["x^2"])
        XCTAssertEqual(parsed.inlineFormulas.map { (source as NSString).substring(with: $0.range) }, ["$x^2$"])
    }

    func testInlineFormulaInLinkLabelKeepsLinkAndImageAlt() {
        let source = "# [中文 $x$](https://example.com)\n\n[ref $y$][id] ![alt $z$](image.png)\n\n[id]: https://example.com\n"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.headings.map(\.title), ["中文 $x$"])
        XCTAssertEqual(parsed.inlineFormulas.map(\.source), ["x", "y"])
        XCTAssertEqual(parsed.inlineFormulas.map { (source as NSString).substring(with: $0.range) }, ["$x$", "$y$"])
        XCTAssertEqual(parsed.spans.filter { $0.kind == .link }.count, 2)
    }

    func testUnclosedMathCannotConsumeLinkBoundary() {
        let source = "[foo $x](https://example.com) and $y$\n\n[ok $a[1] + \\]b$](https://example.com)"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.inlineFormulas.map(\.source), ["y", "a[1] + \\]b"])
        XCTAssertEqual(parsed.spans.filter { $0.kind == .link }.count, 2)
        XCTAssertEqual(parsed.inlineFormulas.map { (source as NSString).substring(with: $0.range) }, ["$y$", "$a[1] + \\]b$"])
    }

    func testTableFormulaSourceRemainsVisibleBeforeNativeCellRendering() throws {
        let source = "| A |\r\n|---|\r\n| 中文\\|😀 **$x$** |"
        let parsed = MarkdownPresentationParser.parse(source)
        let table = try XCTUnwrap(parsed.tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        XCTAssertEqual(cell.displayText, "中文|😀 $x$")
        XCTAssertEqual(parsed.inlineFormulas.map(\.source), ["x"])
        let rebuilt = MarkdownPresentationParser.tableDisplay(table, text: source as NSString)
        XCTAssertEqual(rebuilt.rows.last?.cells.first?.displayText, cell.displayText)
    }

    func testTableFormulaImagesUseExactCellRangesWithoutChangingSource() throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 $x$ and $x$ |"
        let presentation = MarkdownPresentationParser.parse(source)
        let table = try XCTUnwrap(presentation.tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        XCTAssertEqual(presentation.inlineFormulas.count, 2)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        layout.setMarkdownPresentation(presentation, revealedRange: nil)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        for formula in presentation.inlineFormulas { XCTAssertTrue(layout.setMarkdownInlineImage(image, for: formula.range)) }
        let shown = layout.tableCellAttributedText(cell, text: source as NSString)
        XCTAssertEqual(shown.string, "中|😀 \u{fffc} and \u{fffc}")
        var attachments = 0
        shown.enumerateAttribute(.attachment, in: NSRange(location: 0, length: shown.length)) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        XCTAssertEqual(attachments, 2)
        layout.clearMarkdownInlineImages()
        XCTAssertEqual(layout.tableCellAttributedText(cell, text: source as NSString).string, "中|😀 $x$ and $x$")
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testEditedTableCellRebuildsMathRangesLocally() throws {
        let source = "| A | B |\r\n|---|---|\r\n| 中 $x$ | $z$ |"
        let changed = source.replacingOccurrences(of: "中 $x$", with: "中\\|😀 $y$")
        let initial = MarkdownPresentationParser.parse(source)
        let oldTable = try XCTUnwrap(initial.tables.first)
        let oldRow = try XCTUnwrap(oldTable.rows.last)
        let oldCell = try XCTUnwrap(oldRow.cells.first)
        let full = MarkdownPresentationParser.parse(changed)
        let fullTable = try XCTUnwrap(full.tables.first)
        let raw = try XCTUnwrap(MarkdownTableEditingService.presentationTable(in: changed as NSString, range: fullTable.range))
        let local = MarkdownPresentationParser.tableDisplay(raw, text: changed as NSString, previous: oldTable,
                                                            changedRow: oldRow.range.location, changedColumn: 0)
        let newCell = try XCTUnwrap(local.rows.last?.cells.first)
        let updated = initial.replacingTable(local, oldTable: oldTable.range, edit: oldCell.range, replacementLength: newCell.range.length)
        XCTAssertEqual(updated.inlineFormulas, full.inlineFormulas)
        XCTAssertEqual(local.rows.last?.cells, fullTable.rows.last?.cells)
        XCTAssertEqual(updated.inlineFormulas.map(\.source), ["y", "z"])
    }

    func testVirtualTableCellMathEditAndUndoKeepsLocalRanges() throws {
        _ = NSApplication.shared
        let source = "| A | B | C |\n|---|---|---|\n| 中 $x$ |"
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
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let virtual = try XCTUnwrap(table.rows.last?.cells.last)
        XCTAssertTrue(coordinator.beginTableCell(virtual.range, frame: NSRect(x: 0, y: 0, width: 100, height: 40), cell: virtual))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.insertText("$y$", replacementRange: NSRange(location: 0, length: 0))
        let changed = view.string
        let changedTable = try XCTUnwrap(MarkdownPresentationParser.parse(changed).tables.first)
        let actual = try XCTUnwrap(layout.accessibilityTableModel(changedTable.range))
        XCTAssertEqual(actual.rows.last?.cells, changedTable.rows.last?.cells)
        XCTAssertEqual(child.undoAction?(false), true)
        XCTAssertEqual(view.string, source)
        let restored = try XCTUnwrap(layout.accessibilityTableModel(table.range))
        XCTAssertEqual(restored.rows.last?.cells, table.rows.last?.cells)
    }

    func testInlineFormulaInTableEmphasisUsesCellByteMap() {
        let source = "| A |\r\n|---|\r\n| 中\\|😀\\| **$c$** |"
        let formulas = MarkdownPresentationParser.parse(source).inlineFormulas
        XCTAssertEqual(formulas.map(\.source), ["c"])
        XCTAssertEqual(formulas.map { (source as NSString).substring(with: $0.range) }, ["$c$"])
    }

    func testInlineFormulaAppearsBetweenTextAndRevealsSource() async throws {
        _ = NSApplication.shared
        let source = "before $x^2$ after\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = (source as NSString).range(of: "$x^2$")
        func point() -> NSPoint {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layout.location(forGlyphAt: glyph)
            return NSPoint(x: line.minX + position.x + 1, y: line.minY + position.y - 1)
        }
        for _ in 0..<200 {
            if layout.markdownImageLocation(at: point(), in: container) == range.location { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), range.location)
        view.setSelectedRange(range)
        controller.selectionChanged()
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testVisibleBlockMathReferenceUsesCurrentSnapshot() async throws {
        _ = NSApplication.shared
        let source = "$$\n\\ref{eq:a}\n$$\n\n$$\nx\\tag{1}\\label{eq:a}\n$$\n\nafter"
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.formulas.count, 2)
        guard parsed.formulas.count == 2 else { return }
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        var hit: NSPoint?
        for _ in 0..<200 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: parsed.formulas[0].range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            for y in stride(from: line.minY, to: line.maxY, by: 2) {
                for x in stride(from: line.minX, to: line.maxX, by: 2) {
                    let point = NSPoint(x: x, y: y)
                    if controller.mathReference(at: point, document: document, revision: revision) == parsed.formulas[1].range { hit = point; break }
                }
                if hit != nil { break }
            }
            if hit != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let point = try XCTUnwrap(hit)
        revision += 1
        XCTAssertNil(controller.mathReference(at: point, document: document, revision: revision))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testCommandClickMathReferenceRevealsFoldedTarget() async throws {
        _ = NSApplication.shared
        for kind in 0...2 {
            let prefix = kind == 0 ? "$$\n\\ref{eq:a}\n$$" : (kind == 1 ? "See $\\ref{eq:a}$ here." : "| A |\n|---|\n| $\\ref{eq:a}$ |")
            let source = prefix + "\n\n$$\nx\\tag{1}\\label{eq:a}\n$$\n\nafter"
            let parsed = MarkdownPresentationParser.parse(source)
            let from = try XCTUnwrap(kind == 0 ? parsed.formulas.first : parsed.inlineFormulas.first)
            let target = try XCTUnwrap(parsed.formulas.last)
            let document = EditorDocument(text: source, language: .markdown)
            document.isMarkdownFormatted = true
            let coordinator = EditorTextView.Coordinator(document: document)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
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
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            defer { coordinator.updateActivity(false); window.close() }
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            coordinator.updateMarkdownPresentation()
            var hit: NSPoint?
            for _ in 0..<200 {
                layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
                if kind == 2, let cell = parsed.tables.first?.rows.last?.cells.first {
                    let text = layout.tableCellAttributedText(cell, text: storage.mutableString)
                    var hasAttachment = false
                    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                        if value is NSTextAttachment { hasAttachment = true }
                    }
                    if !hasAttachment { try await Task.sleep(for: .milliseconds(100)); continue }
                }
                let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: from.range.location), effectiveRange: nil)
                for y in stride(from: line.minY, to: line.maxY, by: 2) {
                    for x in stride(from: line.minX, to: line.maxX, by: 2) {
                        let point = NSPoint(x: x, y: y)
                        if layout.markdownMathReference(at: point, in: container)?.target == target.range { hit = point; break }
                    }
                    if hit != nil { break }
                }
                if hit != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let point = try XCTUnwrap(hit)
            layout.setFoldedRange(target.range)
            let viewPoint = NSPoint(x: point.x + view.textContainerOrigin.x, y: point.y + view.textContainerOrigin.y)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(viewPoint, to: nil),
                modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
            XCTAssertEqual(view.selectedRange(), NSRange(location: target.range.location, length: 0))
            XCTAssertNil(layout.foldedRange)
            XCTAssertEqual(view.string, source)
            XCTAssertFalse(document.isDirty)
        }
    }

    func testInlineMathReferenceUsesRenderedImageAndCurrentRevision() async throws {
        _ = NSApplication.shared
        let source = "See $\\ref{eq:a}$ here.\n\n$$\nx\\tag{1}\\label{eq:a}\n$$\n\nafter"
        let parsed = MarkdownPresentationParser.parse(source)
        let inline = try XCTUnwrap(parsed.inlineFormulas.first), target = try XCTUnwrap(parsed.formulas.first)
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        var hit: NSPoint?
        for _ in 0..<200 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: inline.range.location), effectiveRange: nil)
            for y in stride(from: line.minY, to: line.maxY, by: 1) {
                for x in stride(from: line.minX, to: line.maxX, by: 1) {
                    let point = NSPoint(x: x, y: y)
                    if controller.mathReference(at: point, document: document, revision: revision) == target.range { hit = point; break }
                }
                if hit != nil { break }
            }
            if hit != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let point = try XCTUnwrap(hit)
        let sourceOffset = (source as NSString).range(of: "\\ref{eq:a}").location
        XCTAssertEqual(controller.mathReference(atSourceOffset: sourceOffset, document: document, revision: revision), target.range)
        XCTAssertNil(controller.mathReference(atSourceOffset: sourceOffset - 1, document: document, revision: revision))
        revision += 1
        XCTAssertNil(controller.mathReference(at: point, document: document, revision: revision))
        XCTAssertNil(controller.mathReference(atSourceOffset: sourceOffset, document: document, revision: revision))
        XCTAssertEqual(view.string, source)
    }

    func testTableMathReferenceUsesAttachmentGeometry() async throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 $\\ref{eq:a}+\\eqref{eq:b}+\\ref{eq:a}$ |\n\n$$\nx\\tag{1}\\label{eq:a}\n$$\n\n$$\ny\\tag{2}\\label{eq:b}\n$$\n\nafter"
        let parsed = MarkdownPresentationParser.parse(source)
        let target = try XCTUnwrap(parsed.formulas.first)
        let secondTarget = try XCTUnwrap(parsed.formulas.last)
        let cell = try XCTUnwrap(parsed.tables.first?.rows.last?.cells.first)
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        var hit: NSPoint?
        for _ in 0..<200 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let text = layout.tableCellAttributedText(cell, text: storage.mutableString)
            var hasAttachment = false
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if value is NSTextAttachment { hasAttachment = true }
            }
            if hasAttachment, let frame = layout.markdownTableFrame(for: cell, in: container) {
                for y in stride(from: frame.minY, to: frame.maxY, by: 2) {
                    for x in stride(from: frame.minX, to: frame.maxX, by: 2) {
                        let point = NSPoint(x: x, y: y)
                        if controller.mathReference(at: point, document: document, revision: revision) == target.range { hit = point; break }
                    }
                    if hit != nil { break }
                }
                break
            }
            if hit != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let point = try XCTUnwrap(hit)
        let cellSourceOffset = (source as NSString).range(of: "\\ref{eq:a}").location
        XCTAssertEqual(controller.mathReference(atSourceOffset: cellSourceOffset, document: document, revision: revision), target.range)
        let secondOffset = (source as NSString).range(of: "\\eqref{eq:b}").location
        XCTAssertEqual(controller.mathReference(atSourceOffset: secondOffset, document: document, revision: revision), secondTarget.range)
        let repeatedOffset = (source as NSString).range(of: "\\ref{eq:a}", options: .backwards).location
        XCTAssertEqual(controller.mathReference(atSourceOffset: repeatedOffset, document: document, revision: revision), target.range)
        XCTAssertNil(controller.mathReference(atSourceOffset: secondOffset - 1, document: document, revision: revision))
        revision += 1
        XCTAssertNil(controller.mathReference(at: point, document: document, revision: revision))
        XCTAssertNil(controller.mathReference(atSourceOffset: cellSourceOffset, document: document, revision: revision))
        XCTAssertEqual(view.string, source)
    }

    func testActiveTableCellCommandClickMathReference() async throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| 中\\|😀 $\\ref{eq:a}$ |\n\n$$\nx\\tag{1}\\label{eq:a}\n$$\n\nafter"
        let parsed = MarkdownPresentationParser.parse(source)
        let cell = try XCTUnwrap(parsed.tables.first?.rows.last?.cells.first)
        let target = try XCTUnwrap(parsed.formulas.first)
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
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
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.updateMarkdownPresentation()
        var frame: NSRect?
        var ready = false
        for _ in 0..<200 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            frame = layout.markdownTableFrame(for: cell, in: container)
            let attributed = layout.tableCellAttributedText(cell, text: storage.mutableString)
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                if value is NSTextAttachment { ready = true }
            }
            if ready && frame != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: try XCTUnwrap(frame).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), cell: cell))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        let childLayout = try XCTUnwrap(child.layoutManager), childContainer = try XCTUnwrap(child.textContainer)
        childLayout.ensureLayout(for: childContainer)
        let character = (child.string as NSString).range(of: "\\ref{eq:a}").location
        let glyph = childLayout.glyphIndexForCharacter(at: character)
        let rect = childLayout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: childContainer)
        let point = NSPoint(x: rect.midX + child.textContainerOrigin.x, y: rect.midY + child.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: child.convert(point, to: nil), modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        child.mouseDown(with: event)
        XCTAssertFalse(view.subviews.contains(child))
        XCTAssertEqual(view.selectedRange(), NSRange(location: target.range.location, length: 0))
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(coordinator.beginTableCell(cell.range, frame: try XCTUnwrap(frame).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), cell: cell))
        let markedChild = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        markedChild.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let markedEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: markedChild.convert(point, to: nil), modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        markedChild.mouseDown(with: markedEvent)
        XCTAssertTrue(markedChild.hasMarkedText())
        XCTAssertTrue(view.subviews.contains(markedChild))
    }

    func testMathNumberingChangeRefreshesVisibleBlock() async throws {
        _ = NSApplication.shared
        let source = "$$\nx\n$$\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func point(_ x: CGFloat) -> NSPoint {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: 0)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return NSPoint(x: line.minX + container.lineFragmentPadding + x, y: line.minY + 1)
        }
        for _ in 0..<200 {
            if layout.markdownImageLocation(at: point(1), in: container) == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(1), in: container), 0)
        XCTAssertNil(layout.markdownImageLocation(at: point(200), in: container))
        controller.setMathOptions(.init(physics: true, numbering: .all))
        for _ in 0..<200 {
            if layout.markdownImageLocation(at: point(200), in: container) == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(200), in: container), 0)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testMathOptionsWaitForMarkedTextToFinish() async throws {
        _ = NSApplication.shared
        let source = "$$\nx\n$$\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        XCTAssertTrue(view.hasMarkedText())
        let markedText = view.string
        controller.setMathOptions(.init(physics: true, numbering: .all))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.string, markedText)
        view.unmarkText()
        controller.metricsChanged()
        func point() -> NSPoint {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: 0), effectiveRange: nil)
            return NSPoint(x: line.minX + container.lineFragmentPadding + 200, y: line.minY + 1)
        }
        for _ in 0..<200 {
            if layout.markdownImageLocation(at: point(), in: container) == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), 0)
        XCTAssertEqual(view.string, markedText)
    }

    func testListFormulaAppearsAfterMarkerAndRevealsSource() async throws {
        _ = NSApplication.shared
        for (before, marker, indent, newline) in [("", "- ", "  ", "\n"), ("", "12. ", "    ", "\r\n"), ("- parent\n", "  - ", "    ", "\n"), ("", "> - ", ">   ", "\r\n"), ("", "-\t", "\t", "\n"), ("", "- \t", "    ", "\r\n"), ("", "> -\t", ">   ", "\r\n"), ("- parent\r\n", "  -\t", "    ", "\r\n")] {
            let source = before + [marker + "$$", indent + "\\frac{a}{b}", indent + "$$", "", "after"].joined(separator: newline)
            let parsed = MarkdownPresentationParser.parse(source)
            let formula = try XCTUnwrap(parsed.formulas.first)
            XCTAssertEqual(formula.source, "\\frac{a}{b}\n")
            let document = EditorDocument(text: source, language: .markdown)
            let storage = NSTextStorage(string: source)
            let layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            let controller = MarkdownPresentationController(textView: view, layout: layout)
            defer { controller.cancel() }
            controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
            func points() -> (NSPoint, NSPoint) {
                layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
                let glyph = layout.glyphIndexForCharacter(at: formula.range.location)
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let markerGlyph = layout.glyphIndexForCharacter(at: formula.range.location - 2)
                let markerX = layout.location(forGlyphAt: markerGlyph).x
                let markerPoint = NSPoint(x: line.minX + markerX + 1, y: line.minY + 1)
                let imagePoint = NSPoint(x: line.minX + layout.location(forGlyphAt: glyph).x + 1, y: line.minY + 1)
                return (markerPoint, imagePoint)
            }
            for _ in 0..<200 {
                if layout.markdownImageLocation(at: points().1, in: container) == formula.range.location { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(layout.markdownImageLocation(at: points().0, in: container))
            XCTAssertEqual(layout.markdownImageLocation(at: points().1, in: container), formula.range.location)
            view.setSelectedRange(NSRange(location: formula.range.location + 1, length: 0))
            controller.selectionChanged()
            XCTAssertNil(layout.markdownImageLocation(at: points().1, in: container))
            XCTAssertEqual(storage.string, source)
            XCTAssertFalse(document.isDirty)
        }
    }

    func testQuotedFormulaAppearsRevealsAndFoldsWithoutChangingSource() async throws {
        _ = NSApplication.shared
        let source = "> $$\n> \\frac{a}{b}\n> $$\n\nafter"
        let parsed = MarkdownPresentationParser.parse(source)
        let formula = try XCTUnwrap(parsed.formulas.first)
        XCTAssertEqual(formula.source, "\\frac{a}{b}\n")
        XCTAssertEqual((source as NSString).substring(with: formula.range), "$$\n> \\frac{a}{b}\n> $$")
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func point() -> NSPoint {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: formula.range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 1)
        }
        for _ in 0..<200 {
            if layout.markdownImageLocation(at: point(), in: container) == formula.range.location { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), formula.range.location)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0))
        layout.setFoldedRange(formula.range)
        controller.viewportChanged()
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        layout.setFoldedRange(nil)
        controller.viewportChanged()
        view.setSelectedRange(NSRange(location: formula.range.location + 1, length: 0))
        controller.selectionChanged()
        XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testFlowAndSequenceShowAndRevealOriginalSource() async throws {
        _ = NSApplication.shared
        for (language, code) in [("flow", "s=>start: Start\ne=>end: End\ns->e"),
                                 ("sequence", "Alice->Bob: Hello\nBob-->Alice: Done")] {
            let source = "中文😀\n\n```\(language)\n\(code)\n```\n\nafter"
            let document = EditorDocument(text: source, language: .markdown)
            let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 500))
            layout.addTextContainer(container)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
            let controller = MarkdownPresentationController(textView: view, layout: layout)
            defer { controller.cancel() }
            controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
            let diagram = try XCTUnwrap(MarkdownPresentationParser.parse(source).diagrams.first)
            func point() -> NSPoint {
                layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
                let glyph = layout.glyphIndexForCharacter(at: diagram.range.location)
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                return NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 1)
            }
            for _ in 0..<200 {
                if layout.markdownImageLocation(at: point(), in: container) == diagram.range.location { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(layout.markdownImageLocation(at: point(), in: container), diagram.range.location)
            view.setSelectedRange(NSRange(location: diagram.range.location + 3, length: 0))
            controller.selectionChanged()
            XCTAssertNil(layout.markdownImageLocation(at: point(), in: container))
            XCTAssertEqual(storage.string, source)
            XCTAssertFalse(document.isDirty)
            withExtendedLifetime(scroll) {}
        }
    }

    func testDiagramStaysRenderedWhenTypingOutsideAndShiftsRange() async throws {
        _ = NSApplication.shared
        let source = "prefix words\n\n```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 800))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        let original = try XCTUnwrap(MarkdownPresentationParser.parse(source).diagrams.first)

        func imagePoint(for range: NSRange) -> NSPoint {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 1)
        }

        for _ in 0..<200 where layout.markdownImageLocation(at: imagePoint(for: original), in: container) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: imagePoint(for: original), in: container), original.range.location)

        let edit = NSRange(location: NSMaxRange((source as NSString).range(of: "prefix wor")), length: 0)
        let inserted = "x"
        revision += 1
        controller.beforeEdit(range: edit, replacementLength: (inserted as NSString).length, replacement: inserted)
        storage.replaceCharacters(in: edit, with: inserted)
        controller.edited(revision: revision)

        let shifted = NSRange(location: original.range.location + (inserted as NSString).length, length: original.range.length)
        // До завершения нового разбора блок уже должен оставаться рендером, а не исходным текстом.
        XCTAssertEqual(layout.markdownImageLocation(at: imagePoint(for: shifted), in: container), shifted.location)
        XCTAssertEqual(storage.string, "prefix worxds\n\n```flow\ns=>start: Start\ne=>end: End\ns->e\n```\n\nafter")

        for _ in 0..<100 where layout.markdownImageLocation(at: imagePoint(for: shifted), in: container) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: imagePoint(for: shifted), in: container), shifted.location)
    }

    func testGeneratedBlocksAppearAndRestoreSourceOnSelection() async throws {
        _ = NSApplication.shared
        let source = "before $\\def\\lacfrac{\\frac{a}{b}}$\n\n```mermaid\nflowchart TD\nA --> B\n```\n\n$$\n\\lacfrac\n$$\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 1000))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 800), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.inlineFormulas.map(\.source), ["\\def\\lacfrac{\\frac{a}{b}}"])
        let diagram = try XCTUnwrap(parsed.diagrams.first)
        let formula = try XCTUnwrap(parsed.formulas.first)
        func point(_ range: NSRange) -> NSPoint {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return NSPoint(x: rect.minX + container.lineFragmentPadding + 1, y: rect.minY + 1)
        }
        for _ in 0..<200 {
            if layout.markdownImageLocation(at: point(diagram.range), in: container) == diagram.range.location,
               layout.markdownImageLocation(at: point(formula.range), in: container) == formula.range.location { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(layout.markdownImageLocation(at: point(diagram.range), in: container), diagram.range.location)
        XCTAssertEqual(layout.markdownImageLocation(at: point(formula.range), in: container), formula.range.location)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        view.setSelectedRange(NSRange(location: diagram.range.location + 3, length: 0))
        controller.selectionChanged()
        XCTAssertNil(layout.markdownImageLocation(at: point(diagram.range), in: container))
        XCTAssertEqual(storage.string, source)
        revision += 1
        controller.edited(revision: revision)
        XCTAssertNil(layout.markdownImageLocation(at: point(formula.range), in: container))
        controller.cancel()
    }
}
