import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownLayoutTests: XCTestCase {
    func testRubyBaselineReservesSpaceWithAdjacentImage() throws {
        _ = NSApplication.shared
        let source = "before <ruby>漢<rt>kan</rt></ruby> ![x](x.png) after\nnext", raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source)
        let ruby = try XCTUnwrap(parsed.ruby.first)
        let image = try XCTUnwrap(parsed.images.first)
        layout.setMarkdownPresentation(parsed, revealedRange: raw.range(of: "next"))
        XCTAssertTrue(layout.setMarkdownInlineImage(NSImage(size: NSSize(width: 50, height: 30)), for: ruby.range,
                                                     rubyBaseline: NSPoint(x: 2, y: 21)))
        XCTAssertTrue(layout.setMarkdownInlineImage(NSImage(size: NSSize(width: 25, height: 18)), for: image.range))
        layout.ensureLayout(for: container)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [ruby.range], in: container)[ruby.range])
        let glyph = layout.glyphIndexForCharacter(at: ruby.range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = line.minY + layout.location(forGlyphAt: glyph).y
        XCTAssertEqual(rect.minY + 21, baseline, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(line.height, 30)
        layout.updateMarkdownRevealedRange(ruby.range)
        layout.ensureLayout(for: container)
        XCTAssertNil(layout.markdownRenderedImageRects(for: [ruby.range], in: container)[ruby.range])
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testRubyDisplayReflowsAndRevealsSource() async throws {
        _ = NSApplication.shared
        let source = "before <ruby>漢<rt>kan</rt></ruby> after\n\nend" + String(repeating: "\nline", count: 40)
        let raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 400, height: 1000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.appearance = NSAppearance(named: .aqua)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setFrameSize(NSSize(width: 400, height: 1000))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(raw.range(of: "end"))
        let accessibilityChildren = view.accessibilityChildren()?.count ?? 0
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = raw.range(of: "<ruby>漢<rt>kan</rt></ruby>")
        func rendered() -> NSRect? {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [range], in: container)[range]
        }
        for _ in 0..<200 where rendered() == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(rendered())
        XCTAssertEqual(view.accessibilityValue(), source)
        XCTAssertEqual(view.accessibilityChildren()?.count ?? 0, accessibilityChildren)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), raw.range(of: "end"))
        let lightImage = try XCTUnwrap(layout.markdownInlineImage(for: range)?.tiffRepresentation)
        view.appearance = NSAppearance(named: .darkAqua); controller.metricsChanged()
        for _ in 0..<200 {
            if let current = layout.markdownInlineImage(for: range)?.tiffRepresentation, current != lightImage { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let darkImage = try XCTUnwrap(layout.markdownInlineImage(for: range)?.tiffRepresentation)
        XCTAssertNotEqual(darkImage, lightImage)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); scroll.reflectScrolledClipView(scroll.contentView)
        controller.viewportChanged()
        XCTAssertEqual(view.accessibilityValue(), source)
        XCTAssertEqual(view.accessibilityChildren()?.count ?? 0, accessibilityChildren)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        controller.viewportChanged()
        for _ in 0..<200 where rendered() == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(rendered())
        scroll.setFrameSize(NSSize(width: 1, height: 300)); view.setFrameSize(NSSize(width: 1, height: 300))
        container.containerSize = NSSize(width: 1, height: 1000); controller.viewportChanged()
        XCTAssertNil(rendered())
        scroll.setFrameSize(NSSize(width: 250, height: 300)); view.setFrameSize(NSSize(width: 250, height: 300))
        container.containerSize = NSSize(width: 250, height: 1000); controller.viewportChanged()
        for _ in 0..<200 where rendered() == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(rendered())
        let beforeComposition = try XCTUnwrap(rendered())
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        controller.selectionChanged()
        XCTAssertEqual(storage.string, source)
        XCTAssertEqual(rendered(), beforeComposition)
        child.unmarkText(); child.removeFromSuperview()
        controller.compositionFinished(revision: 0)
        view.setSelectedRange(range); controller.selectionChanged()
        XCTAssertNil(rendered())
        XCTAssertEqual(view.accessibilityValue(), source)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), range)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertEqual(view.accessibilityValue(), source)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), range)
        XCTAssertEqual(view.accessibilityChildren()?.count ?? 0, accessibilityChildren)
    }

    func testStyledRubyDisplaysAndRevealsOriginalSource() async throws {
        _ = NSApplication.shared
        let ruby = "<ruby><strong>漢</strong><span style='color:red'>字</span><rt>kan</rt></ruby>"
        let source = "before <strong><span style='color:red'>" + ruby + "</span></strong> after\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(raw.range(of: "end"))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = raw.range(of: ruby)
        func rendered() -> NSRect? {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [range], in: container)[range]
        }
        for _ in 0..<200 where rendered() == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(rendered())
        let image = try XCTUnwrap(layout.markdownInlineImage(for: range))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var redAbove = 0
        for y in 0..<max(1, bitmap.pixelsHigh / 3) {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.2 else { continue }
                if pixel.redComponent > 0.7 && pixel.greenComponent < 0.3 && pixel.blueComponent < 0.3 { redAbove += 1 }
            }
        }
        XCTAssertGreaterThan(redAbove, 0)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
        view.setSelectedRange(range); controller.selectionChanged()
        XCTAssertNil(rendered())
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
    }

    func testSpacedRubyDisplaysAndRevealsOriginalSource() async throws {
        _ = NSApplication.shared
        let ruby = "<ruby> 漢 <rt> ㄏㄢˋ </rt> </ruby>"
        let source = ruby + "\n\nend", raw = source as NSString
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        view.setSelectedRange(raw.range(of: "end"))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let range = raw.range(of: ruby)
        func rendered() -> NSRect? {
            layout.ensureLayout(for: container)
            return layout.markdownRenderedImageRects(for: [range], in: container)[range]
        }
        for _ in 0..<200 where rendered() == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(rendered())
        XCTAssertEqual(storage.string, source)
        view.setSelectedRange(range); controller.selectionChanged()
        XCTAssertNil(rendered())
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testHTMLCommentRemainsVisibleInNativeEditor() {
        _ = NSApplication.shared
        let source = "before 中文\n\n<!-- COMMENT_SECRET\nsecond line -->\n\nafter 😀"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let presentation = MarkdownPresentationParser.parse(source)
        let selected = (source as NSString).range(of: "after")
        layout.setMarkdownPresentation(presentation, revealedRange: selected, inlineSelection: selected)
        layout.ensureLayout(for: container)
        let range = (source as NSString).range(of: "COMMENT_SECRET")
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    private final class SoftBreakProbe: NSObject, NSLayoutManagerDelegate {
        let range: NSRange
        var join = false
        init(range: NSRange) { self.range = range }
        func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                           forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
            join && NSLocationInRange(charIndex, range) ? .whitespace : action
        }
        func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                           for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                           glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
            guard join, NSLocationInRange(characterIndex, range) else { return .zero }
            return NSRect(x: 0, y: 0, width: characterIndex == range.location ? 4 : 0, height: 16)
        }
    }

    func testTextKitCanLayOutConfirmedSoftBreakAsWhitespace() {
        _ = NSApplication.shared
        for newline in ["\n", "\r", "\r\n"] {
            let source = "left" + newline + "right"
            let raw = source as NSString
            let storage = NSTextStorage(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 400))
            layout.addTextContainer(container)
            let probe = SoftBreakProbe(range: raw.range(of: newline))
            layout.delegate = probe
            func lineY(_ character: Int) -> CGFloat {
                layout.ensureLayout(for: container)
                return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
            }
            let right = raw.range(of: "right").location
            XCTAssertGreaterThan(lineY(right), lineY(0), source)
            probe.join = true
            layout.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: raw.length), changeInLength: 0, actualCharacterRange: nil)
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: raw.length), actualCharacterRange: nil)
            XCTAssertEqual(lineY(right), lineY(0), accuracy: 0.5, source)
            XCTAssertEqual(storage.string, source)
        }
    }

    func testEditingTextReplacementsUseControlGlyphsAndRevealSource() throws {
        _ = NSApplication.shared
        let source = "hello --  world\n\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let presentation = MarkdownPresentationParser.parse(source, syntax: .init(smartPunctuation: true, preserveEditingWhitespace: false))
        let smart = try XCTUnwrap(presentation.textReplacements.first { $0.kind == .smart })
        let spaces = try XCTUnwrap(presentation.textReplacements.first { $0.kind == .spaces })
        let end = (source as NSString).range(of: "end")
        layout.setMarkdownPresentation(presentation, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        for replacement in [smart, spaces] {
            let glyph = layout.glyphIndexForCharacter(at: replacement.range.location)
            XCTAssertTrue(layout.propertyForGlyph(at: glyph).contains(.controlCharacter))
            let bounds = layout.layoutManager(layout, boundingBoxForControlGlyphAt: glyph, for: container,
                proposedLineFragment: .zero, glyphPosition: .zero, characterIndex: replacement.range.location)
            XCTAssertGreaterThan(bounds.width, 0)
        }
        layout.updateMarkdownInlineSelection(smart.range)
        layout.ensureLayout(for: container)
        XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: smart.range.location)).contains(.controlCharacter))
        XCTAssertTrue(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: spaces.range.location)).contains(.controlCharacter))
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        layout.ensureLayout(for: container)
        XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: spaces.range.location)).contains(.controlCharacter))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testEditingWhitespaceEdgesHaveZeroWidthAndRevealSource() throws {
        _ = NSApplication.shared
        let source = "  中文 😀  \n\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let presentation = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
        let edges = presentation.textReplacements.filter { $0.kind == .spaces && $0.text.isEmpty }
        XCTAssertEqual(edges.count, 2)
        let end = (source as NSString).range(of: "end")
        layout.setMarkdownPresentation(presentation, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        for edge in edges {
            let glyph = layout.glyphIndexForCharacter(at: edge.range.location)
            XCTAssertTrue(layout.propertyForGlyph(at: glyph).contains(.controlCharacter))
            let bounds = layout.layoutManager(layout, boundingBoxForControlGlyphAt: glyph, for: container,
                proposedLineFragment: .zero, glyphPosition: .zero, characterIndex: edge.range.location)
            XCTAssertEqual(bounds.width, 0, accuracy: 0.01)
            let actualGlyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
            XCTAssertEqual(layout.boundingRect(forGlyphRange: actualGlyphs, in: container).width, 0, accuracy: 0.5)
        }
        if let edge = edges.first {
            layout.updateMarkdownInlineSelection(edge.range)
            layout.ensureLayout(for: container)
            if let checkbox = presentation.taskCheckboxes.first {
                let markerGlyphs = layout.glyphRange(forCharacterRange: checkbox.markerRange, actualCharacterRange: nil)
                let markerRect = layout.boundingRect(forGlyphRange: markerGlyphs, in: container)
                XCTAssertEqual(layout.markdownTaskCheckbox(at: NSPoint(x: markerRect.midX, y: markerRect.midY), in: container), checkbox)
            }
            XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: edge.range.location)).contains(.controlCharacter))
            let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
            XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0)
        }
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        layout.ensureLayout(for: container)
        if let edge = edges.last {
            let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
            XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0)
        }
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testEditingWhitespaceTrailingTabsHaveZeroWidthAndReveal() throws {
        _ = NSApplication.shared
        let source = "中文😀\t \t\r\n\r\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
        let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty })
        let end = (source as NSString).range(of: "end")
        layout.setMarkdownPresentation(parsed, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertEqual(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0, accuracy: 0.5)
        layout.updateMarkdownInlineSelection(edge.range)
        layout.ensureLayout(for: container)
        let revealed = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: revealed, in: container).width, 0)
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testPlainMultilineBodyTabUsesConfirmedGlyphAndReveal() throws {
        _ = NSApplication.shared
        let source = "first\r\n   中文\ttext --\r\n\r\nend", raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: true))
        let tab = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && raw.substring(with: $0.range) == "\t" })
        let end = raw.range(of: "end")
        layout.setMarkdownPresentation(parsed, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: tab.range.location)
        XCTAssertTrue(layout.propertyForGlyph(at: glyph).contains(.controlCharacter))
        layout.updateMarkdownInlineSelection(tab.range)
        layout.ensureLayout(for: container)
        XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: tab.range.location)).contains(.controlCharacter))
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testContainerContinuationTabKeepsStructuralPrefix() throws {
        _ = NSApplication.shared
        let source = "> first\r\n> \t中文😀\r\n\r\nend", raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: true))
        let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty })
        XCTAssertEqual(raw.substring(with: edge.range), "\t")
        let end = raw.range(of: "end")
        layout.setMarkdownPresentation(parsed, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertEqual(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0, accuracy: 0.5)
        layout.updateMarkdownInlineSelection(edge.range)
        layout.ensureLayout(for: container)
        let revealed = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: revealed, in: container).width, 0)
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testEditingWhitespaceKeepsStructuralSpaceAfterMarker() throws {
        _ = NSApplication.shared
        for source in [">    中文😀\n\nend", "> \t中文😀\n\nend", "> >    中文😀\n\nend", ">> \t中文😀\n\nend", "-    中文😀\n\nend", "> -   中文😀\n\nend", "- [ ]    中文😀\n\nend"] {
            let raw = source as NSString
            let (storage, layout, container) = makeLayout(source)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
            let presentation = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false))
            let edge = try XCTUnwrap(presentation.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty })
            let end = raw.range(of: "end")
            layout.setMarkdownPresentation(presentation, revealedRange: end, inlineSelection: end)
            layout.ensureLayout(for: container)
            if let checkbox = presentation.taskCheckboxes.first {
                let markerGlyphs = layout.glyphRange(forCharacterRange: checkbox.markerRange, actualCharacterRange: nil)
                let markerRect = layout.boundingRect(forGlyphRange: markerGlyphs, in: container)
                XCTAssertEqual(layout.markdownTaskCheckbox(at: NSPoint(x: markerRect.midX, y: markerRect.midY), in: container), checkbox)
            }
            XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: edge.range.location - 1)).contains(.controlCharacter))
            let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
            XCTAssertEqual(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0, accuracy: 0.5)
            let textGlyph = layout.glyphIndexForCharacter(at: NSMaxRange(edge.range))
            let textRect = layout.boundingRect(forGlyphRange: NSRange(location: textGlyph, length: 1), in: container)
            for x in [textRect.minX - 0.5, textRect.minX + 0.5] {
                var fraction: CGFloat = 0
                let position = layout.characterIndex(for: NSPoint(x: x, y: textRect.midY), in: container,
                    fractionOfDistanceBetweenInsertionPoints: &fraction)
                XCTAssertGreaterThanOrEqual(position, edge.range.location - 1)
                XCTAssertLessThanOrEqual(position, NSMaxRange(edge.range) + 1)
            }
            layout.updateMarkdownInlineSelection(edge.range)
            layout.ensureLayout(for: container)
            let revealed = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
            XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: revealed, in: container).width, 0)
            layout.setMarkdownPresentation(nil, revealedRange: nil)
            XCTAssertEqual(storage.string, source)
            withExtendedLifetime(view) {}
        }
    }

    func testEditingSoftBreakJoinsAndRevealsPhysicalLines() throws {
        _ = NSApplication.shared
        for newline in ["\n", "\r", "\r\n"] {
            let source = "one" + newline + "two" + newline + newline + "end"
            let raw = source as NSString
            let (storage, layout, container) = makeLayout(source)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
            let presentation = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingSoftBreaks: false))
            let replacement = try XCTUnwrap(presentation.textReplacements.first { $0.kind == .softBreak })
            let end = raw.range(of: "end")
            layout.setMarkdownPresentation(presentation, revealedRange: end, inlineSelection: end)
            func lineY(_ character: Int) -> CGFloat {
                layout.ensureLayout(for: container)
                return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
            }
            XCTAssertEqual(lineY(raw.range(of: "one").location), lineY(raw.range(of: "two").location), accuracy: 0.5)
            layout.updateMarkdownInlineSelection(replacement.range)
            XCTAssertGreaterThan(lineY(raw.range(of: "two").location), lineY(raw.range(of: "one").location))
            layout.setMarkdownPresentation(nil, revealedRange: nil)
            XCTAssertGreaterThan(lineY(raw.range(of: "two").location), lineY(raw.range(of: "one").location))
            XCTAssertEqual(storage.string, source)
            withExtendedLifetime(view) {}
        }
    }

    func testPlainMultilineIndentUsesRetainedMappingInLayout() throws {
        _ = NSApplication.shared
        let source = "first\r\n   中文😀\r\n\r\nend", raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: true))
        let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty })
        XCTAssertEqual(raw.substring(with: edge.range), "   ")
        let end = raw.range(of: "end")
        layout.setMarkdownPresentation(parsed, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertEqual(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0, accuracy: 0.5)
        layout.updateMarkdownInlineSelection(edge.range)
        layout.ensureLayout(for: container)
        let revealed = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: revealed, in: container).width, 0)
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testWrappedMultilineStyleKeepsSourceDuringReveal() throws {
        _ = NSApplication.shared
        let source = "> **one\r\n>   中文 --** after\r\n\r\nend", raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: true))
        let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty })
        let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong }), marker = try XCTUnwrap(strong.markerRanges.first)
        let end = raw.range(of: "end")
        layout.setMarkdownPresentation(parsed, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker.location))
        let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertEqual(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0, accuracy: 0.5)
        layout.updateMarkdownInlineSelection(strong.range)
        layout.ensureLayout(for: container)
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: marker.location))
        let revealed = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: revealed, in: container).width, 0)
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testContainerMultilineStyledIndentUsesRetainedMappingInLayout() throws {
        _ = NSApplication.shared
        let source = "> first\r\n>   **中文 --**\r\n\r\nend", raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source, syntax: .init(preserveEditingWhitespace: false, preserveEditingSoftBreaks: true))
        let edge = try XCTUnwrap(parsed.textReplacements.first { $0.kind == .spaces && $0.text.isEmpty })
        XCTAssertEqual(raw.substring(with: edge.range), "  ")
        let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong })
        let marker = try XCTUnwrap(strong.markerRanges.first)
        let end = raw.range(of: "end")
        layout.setMarkdownPresentation(parsed, revealedRange: end, inlineSelection: end)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertEqual(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 0, accuracy: 0.5)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker.location))
        layout.updateMarkdownInlineSelection(edge.range)
        layout.ensureLayout(for: container)
        let revealed = layout.glyphRange(forCharacterRange: edge.range, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: revealed, in: container).width, 0)
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testMathPairWarmSnapshotSurvivesClosingEmojiCompletion() async throws {
        _ = NSApplication.shared
        let source = "hello"
        let document = EditorDocument(text: source, language: .markdown)
        let (_, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.setMathPairContextEnabled(true)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        controller.beginEmojiCompletion()
        let pending = try XCTUnwrap(controller.work)
        controller.endEmojiCompletion()
        XCTAssertTrue(controller.work === pending)
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: 0, range: NSRange(location: 2, length: 0)))
    }

    func testMathPairUsesSourceSnapshotAndSafeEdits() async throws {
        _ = NSApplication.shared
        let source = "---\ntitle: yamlword\n---\n\n中文 plain `code $5` aftercode [link](https://example.com/$id/url) afterurl\n\n$x$ aftermath \\$ escaped\n\n$unfinished\n\n| A |\n|---|\n| cell |"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        var revision: UInt = 0
        controller.setMathPairContextEnabled(true)
        controller.update(document: document, enabled: false, isActive: true, revision: revision, currentRevision: { revision })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: revision))
        let raw = source as NSString
        let plain = raw.range(of: "plain")
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: plain))
        for token in ["yamlword", "code", "url", "x", "unfinished"] {
            let range = raw.range(of: token, options: token == "x" ? .backwards : [])
            XCTAssertFalse(controller.allowsMathPair(document: document, revision: revision, range: range), token)
        }
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: raw.range(of: "cell")))
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: raw.range(of: "aftercode")))
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: raw.range(of: "afterurl")))
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: raw.range(of: "aftermath")))
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: raw.range(of: "escaped")))
        XCTAssertFalse(controller.allowsMathPair(document: document, revision: revision + 1, range: plain))
        let edit = NSRange(location: NSMaxRange(plain), length: 0)
        revision += 1
        controller.noteFenceContextEdit(range: edit, replacement: "文", in: storage.mutableString, revision: revision)
        controller.beforeEdit(range: edit, replacementLength: 1)
        storage.replaceCharacters(in: edit, with: "文")
        controller.edited(revision: revision)
        XCTAssertNil(controller.work)
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: NSRange(location: NSMaxRange(plain) + 1, length: 0)))
        let cell = storage.mutableString.range(of: "cell")
        view.setSelectedRange(cell)
        controller.selectionChanged()
        XCTAssertNotNil(controller.work)
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.allowsMathPair(document: document, revision: revision, range: cell))
        let syntax = NSRange(location: NSMaxRange(plain) + 1, length: 0)
        revision += 1
        controller.noteFenceContextEdit(range: syntax, replacement: "`", in: storage.mutableString, revision: revision)
        controller.beforeEdit(range: syntax, replacementLength: 1)
        storage.replaceCharacters(in: syntax, with: "`")
        controller.edited(revision: revision)
        XCTAssertFalse(controller.allowsMathPair(document: document, revision: revision, range: syntax))
        XCTAssertNotNil(controller.work)
    }

    func testMathPairAllowsOnlyConfirmedEmptyTopLevelLines() async throws {
        _ = NSApplication.shared
        for (source, expected) in [("", true), ("text\r\n\r\n", true), ("```\n\n", false), ("before <script>\n\n", false), ("> ", false), ("\t", false)] {
            let document = EditorDocument(text: source, language: .markdown)
            let (storage, layout, container) = makeLayout(source)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let controller = MarkdownPresentationController(textView: view, layout: layout)
            controller.setMathPairContextEnabled(true)
            controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
            for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0), source)
            XCTAssertEqual(controller.allowsMathPair(document: document, revision: 0, range: NSRange(location: storage.length, length: 0)), expected, source)
            controller.cancel()
            withExtendedLifetime(scroll) {}
        }
    }

    func testCompletedTaskStrikethroughIncludesRenderedTableText() throws {
        let source = "- [x] task\n\n  | A | B |\n  |---|---|\n  | one | two |"
        let parsed = MarkdownPresentationParser.parse(source)
        let table = try XCTUnwrap(parsed.tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        let (storage, layout, _) = makeLayout(source)
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        layout.markdownStrikeCompletedTasks = true
        let content = layout.tableCellAttributedText(cell, text: storage.mutableString)
        XCTAssertEqual((content.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? NSNumber)?.intValue,
                       NSUnderlineStyle.single.rawValue)
        layout.markdownStrikeCompletedTasks = false
        XCTAssertNil(layout.tableCellAttributedText(cell, text: storage.mutableString).attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
    }

    func testHeadingNumberingRestoresSourceAndKeepsSetextUnderline() async throws {
        _ = NSApplication.shared
        let source = "# First\n\nSecond\n======\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.setHeadingNumbering(true)
        controller.update(document: document, enabled: true, outlineVisible: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try XCTUnwrap(controller.navigationPresentation(document: document, revision: 0))
        XCTAssertEqual(result.headings.map(\.number), ["1. ", "2. "])
        let first = (source as NSString).range(of: "First")
        let second = (source as NSString).range(of: "Second")
        let underline = (source as NSString).range(of: "======")
        func indent(_ range: NSRange) -> CGFloat {
            (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        }
        XCTAssertGreaterThan(indent(first), 0)
        XCTAssertGreaterThan(indent(second), 0)
        XCTAssertEqual(indent(underline), 0)
        view.setSelectedRange(first)
        controller.selectionChanged()
        XCTAssertEqual(indent(first), 0)
        view.setSelectedRange((source as NSString).range(of: "end"))
        controller.selectionChanged()
        XCTAssertGreaterThan(indent(first), 0)
        controller.setHeadingNumbering(false)
        XCTAssertEqual(indent(first), 0)
        XCTAssertNil(storage.attribute(.paragraphStyle, at: first.location, effectiveRange: nil))
        let existing = NSMutableParagraphStyle()
        existing.firstLineHeadIndent = 28
        existing.headIndent = 28
        let firstLine = (source as NSString).lineRange(for: first)
        storage.addAttribute(.paragraphStyle, value: existing, range: firstLine)
        container.containerSize.width = 30
        controller.setHeadingNumbering(true)
        XCTAssertEqual(indent(first), 28, accuracy: 0.5)
        controller.setHeadingNumbering(false)
        XCTAssertEqual(indent(first), 28, accuracy: 0.5)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testUppercaseHeadingPrototypeReservesWrappedBlockAndRevealsSource() throws {
        _ = NSApplication.shared
        let title = "Straße " + String(repeating: "long title ", count: 8)
        let source = "# \(title)\n\nend"
        let projection = MarkdownHeadingUppercaseProjection(title)
        let (storage, layout, container) = makeLayout(source)
        let display = NSTextStorage(string: projection.text, attributes: [.font: layout.markdownHeadingFont(level: 1), .paragraphStyle: NSMutableParagraphStyle()])
        let displayLayout = NSLayoutManager()
        display.addLayoutManager(displayLayout)
        let displayContainer = NSTextContainer(containerSize: NSSize(width: 90, height: 2_000))
        displayContainer.lineFragmentPadding = 0
        displayLayout.addTextContainer(displayContainer)
        displayLayout.ensureLayout(for: displayContainer)
        let height = ceil(displayLayout.usedRect(for: displayContainer).height)
        XCTAssertGreaterThan(height, 30)
        container.containerSize = NSSize(width: 100, height: 2_000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let presentation = MarkdownPresentationParser.parse(source)
        let heading = try XCTUnwrap(presentation.headings.first)
        layout.setMarkdownPresentation(presentation, revealedRange: (source as NSString).range(of: "end"))
        let sourceTitle = (source as NSString).range(of: title)
        XCTAssertTrue(layout.setPlainUppercaseHeading(heading.range, source: sourceTitle, text: title, width: 90, level: 1))
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: heading.range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertGreaterThanOrEqual(line.height, height)
        XCTAssertEqual(layout.markdownImageLocation(at: NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 1), in: container), heading.range.location)
        let expanded = (projection.text as NSString).range(of: "SS")
        let sharpS = (source as NSString).range(of: "ß")
        for offset in 0..<2 {
            layout.updateMarkdownRevealedRange((source as NSString).range(of: "end"))
            layout.ensureLayout(for: container)
            let glyphs = displayLayout.glyphRange(forCharacterRange: NSRange(location: expanded.location + offset, length: 1), actualCharacterRange: nil)
            let rect = displayLayout.boundingRect(forGlyphRange: glyphs, in: displayContainer)
            let displayPoint = NSPoint(x: rect.minX + rect.width * 0.25, y: rect.midY)
            let blockPoint = NSPoint(x: line.minX + container.lineFragmentPadding + displayPoint.x, y: line.minY + displayPoint.y)
            XCTAssertEqual(layout.markdownImageLocation(at: blockPoint, in: container), heading.range.location)
            let viewPoint = NSPoint(x: blockPoint.x + view.textContainerOrigin.x, y: blockPoint.y + view.textContainerOrigin.y)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: view.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: false)
            view.mouseDown(with: event)
            XCTAssertEqual(view.selectedRange().location, offset == 0 ? sharpS.location : NSMaxRange(sharpS))
        }
        func sourcePoint(_ position: Int) -> NSPoint {
            layout.updateMarkdownRevealedRange(heading.range)
            layout.ensureLayout(forCharacterRange: heading.range)
            let caret = view.firstRect(forCharacterRange: NSRange(location: position, length: 0), actualRange: nil)
            return window.convertPoint(fromScreen: NSPoint(x: caret.midX, y: caret.midY))
        }
        let sourceEnd = sourcePoint(NSMaxRange(sharpS))
        func click(_ offset: Int, modifiers: NSEvent.ModifierFlags = [], count: Int = 1, drag: NSPoint? = nil) throws {
            layout.updateMarkdownRevealedRange((source as NSString).range(of: "end"))
            layout.ensureLayout(for: container)
            let glyphs = displayLayout.glyphRange(forCharacterRange: NSRange(location: expanded.location + offset, length: 1), actualCharacterRange: nil)
            let rect = displayLayout.boundingRect(forGlyphRange: glyphs, in: displayContainer)
            let point = NSPoint(x: line.minX + container.lineFragmentPadding + rect.minX + rect.width * 0.25 + view.textContainerOrigin.x,
                                y: line.minY + rect.midY + view.textContainerOrigin.y)
            let windowPoint = view.convert(point, to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 1))
            if let drag {
                let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: drag, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 1))
                NSApp.postEvent(moved, atStart: false)
            }
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: drag ?? windowPoint, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 0))
            NSApp.postEvent(up, atStart: false)
            view.mouseDown(with: down)
        }
        view.setSelectedRange(NSRange(location: sourceTitle.location, length: 0))
        try click(1, modifiers: .shift)
        XCTAssertEqual(view.selectedRange(), NSRange(location: sourceTitle.location, length: NSMaxRange(sharpS) - sourceTitle.location))
        try click(0, count: 2)
        XCTAssertEqual((source as NSString).substring(with: view.selectedRange()), "Straße")
        try click(0, count: 3)
        XCTAssertEqual(view.selectedRange(), (source as NSString).lineRange(for: sharpS))
        try click(0, drag: sourceEnd)
        XCTAssertEqual(view.selectedRange(), sharpS)
        layout.updateMarkdownRevealedRange(heading.range)
        layout.ensureLayout(for: container)
        XCTAssertNil(layout.markdownImageLocation(at: NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 1), in: container))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testUppercaseHeadingControllerUsesCurrentSnapshotAndReveal() async throws {
        _ = NSApplication.shared
        let source = "# Straße\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 300, height: 2000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.setUppercaseHeadingLevels([1])
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let parsed = try XCTUnwrap(controller.navigationPresentation(document: document, revision: 0))
        let heading = try XCTUnwrap(parsed.headings.first)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: heading.range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let point = NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 4)
        XCTAssertNotNil(layout.uppercaseHeadingSourcePosition(at: point, in: container))
        view.setSelectedRange(NSRange(location: heading.range.location + 3, length: 0))
        controller.selectionChanged()
        XCTAssertNil(layout.uppercaseHeadingSourcePosition(at: point, in: container))
        view.setSelectedRange((source as NSString).range(of: "end"))
        controller.selectionChanged()
        controller.setUppercaseHeadingLevels([])
        XCTAssertNil(layout.uppercaseHeadingSourcePosition(at: point, in: container))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testUppercaseHeadingUsesResolvedEmoji() async throws {
        _ = NSApplication.shared
        let source = "# :smile:\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (_, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        let done = expectation(description: "emoji resolution")
        controller.emojiResolver = { _, _ in ["smile": "😄"] }
        controller.emojiResolutionDidComplete = { done.fulfill() }
        controller.setUppercaseHeadingLevels([1])
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [done], timeout: 5)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: 0)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = layout.uppercaseHeadingSourcePosition(at: NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 4), in: container)
        XCTAssertNotNil(position)
        let token = (source as NSString).range(of: ":smile:")
        XCTAssertTrue(position == token.location || position == NSMaxRange(token))
        XCTAssertEqual(view.string, source)
    }

    func testUppercaseHeadingWaitsForSuccessfulEmojiResolution() async throws {
        _ = NSApplication.shared
        let source = "# :smile:\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (_, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        let done = expectation(description: "failed emoji resolution")
        controller.emojiResolver = { _, _ in nil }
        controller.emojiResolutionDidComplete = { done.fulfill() }
        controller.setUppercaseHeadingLevels([1])
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [done], timeout: 5)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: 0)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertNil(layout.uppercaseHeadingSourcePosition(at: NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 4), in: container))
        XCTAssertEqual(view.string, source)
    }

    func testUppercaseHeadingPrototypeMapsStyledRuns() throws {
        _ = NSApplication.shared
        let source = "# **Straße** &amp; `hi`\n\nend"
        let raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 300, height: 2000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let parsed = MarkdownPresentationParser.parse(source)
        let heading = try XCTUnwrap(parsed.headings.first)
        let word = raw.range(of: "Straße"), entity = raw.range(of: "&amp;"), code = raw.range(of: "hi")
        let runs: [MarkdownHeading.UppercaseRun] = [
            .init(pieces: [.init(sourceRange: word, text: "Straße", matchesSource: true)], styles: [.strong]),
            .init(pieces: [.init(sourceRange: entity, text: "&", matchesSource: false)], styles: []),
            .init(pieces: [.init(sourceRange: code, text: "hi", matchesSource: true)], styles: [.code])
        ]
        layout.setMarkdownPresentation(parsed, revealedRange: raw.range(of: "end"))
        XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: runs, width: 220, level: 1))
        layout.ensureLayout(for: container)
        let imageGlyph = layout.glyphIndexForCharacter(at: heading.range.location)
        let line = layout.lineFragmentRect(forGlyphAt: imageGlyph, effectiveRange: nil)
        let display = NSTextStorage(string: "STRASSE&HI", attributes: [.font: layout.markdownHeadingFont(level: 1)])
        let manager = NSFontManager.shared
        display.addAttribute(.font, value: manager.convert(layout.markdownHeadingFont(level: 1), toHaveTrait: .boldFontMask), range: NSRange(location: 0, length: 7))
        display.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: layout.markdownHeadingFont(level: 1).pointSize, weight: .regular), range: NSRange(location: 8, length: 2))
        let displayLayout = NSLayoutManager(), displayContainer = NSTextContainer(containerSize: NSSize(width: 220, height: 2000))
        displayContainer.lineFragmentPadding = 0
        display.addLayoutManager(displayLayout)
        displayLayout.addTextContainer(displayContainer)
        displayLayout.ensureLayout(for: displayContainer)
        for (displayOffset, sourceOffset) in [(4, raw.range(of: "ß").location), (7, entity.location), (8, code.location)] {
            let glyph = displayLayout.glyphRange(forCharacterRange: NSRange(location: displayOffset, length: 1), actualCharacterRange: nil)
            let rect = displayLayout.boundingRect(forGlyphRange: glyph, in: displayContainer)
            let point = NSPoint(x: line.minX + container.lineFragmentPadding + rect.minX + rect.width * 0.25, y: line.minY + rect.midY)
            XCTAssertEqual(layout.uppercaseHeadingSourcePosition(at: point, in: container), sourceOffset)
        }
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testUppercaseHeadingPrototypeWaitsForAttachmentImages() throws {
        _ = NSApplication.shared
        let source = "# $x$ ![alt](image.png)\n\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let heading = try XCTUnwrap(parsed.headings.first)
        let runs = try XCTUnwrap(heading.uppercaseRuns)
        layout.setMarkdownPresentation(parsed, revealedRange: (source as NSString).range(of: "end"))
        XCTAssertFalse(layout.setUppercaseHeading(heading.range, runs: runs, width: 200, level: 1))
        let attachments = runs.filter { $0.attachment != nil }
        XCTAssertEqual(attachments.count, 2)
        let images = Dictionary(uniqueKeysWithValues: attachments.compactMap { run in
            run.pieces.first.map { ($0.sourceRange, NSImage(size: NSSize(width: 20, height: 10))) }
        })
        XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: runs, width: 200, level: 1, attachmentImages: images))
        layout.ensureLayout(for: container)
        let formula = try XCTUnwrap(attachments.first { $0.attachment == .formula }?.pieces.first?.sourceRange)
        let image = try XCTUnwrap(attachments.first { $0.attachment == .image }?.pieces.first?.sourceRange)
        let rects = layout.markdownRenderedImageRects(for: [formula, image], in: container)
        let formulaRect = try XCTUnwrap(rects[formula])
        XCTAssertNotNil(rects[image])
        let target = NSRange(location: (source as NSString).range(of: "end").location, length: 3)
        layout.setMarkdownMathReferences([(rect: CGRect(x: 0, y: 0, width: 1, height: 1), target: target)], for: formula)
        let hit = layout.markdownMathReference(at: NSPoint(x: formulaRect.midX, y: formulaRect.midY), in: container)
        XCTAssertEqual(hit?.source, formula)
        XCTAssertEqual(hit?.target, target)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testVerticalUppercasePrototypeUsesAttachmentAndSourceCoordinates() throws {
        _ = NSApplication.shared
        let source = "# Straße 中文 $x$ ![alt](image.png)\n\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.setLayoutOrientation(.vertical)
        scroll.magnification = 1.5
        container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let heading = try XCTUnwrap(parsed.headings.first)
        let runs = try XCTUnwrap(heading.uppercaseRuns)
        view.setSelectedRange((source as NSString).range(of: "end"))
        layout.setMarkdownPresentation(parsed, revealedRange: (source as NSString).range(of: "end"))
        let attachments = runs.filter { $0.attachment != nil }
        let images = Dictionary(uniqueKeysWithValues: attachments.compactMap { run in
            run.pieces.first.map { ($0.sourceRange, NSImage(size: NSSize(width: 40, height: 20))) }
        })
        XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: runs, width: 200, level: 1, attachmentImages: images))
        layout.ensureLayout(for: container)
        let formula = try XCTUnwrap(attachments.first { $0.attachment == .formula }?.pieces.first?.sourceRange)
        let rect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [formula], in: container)[formula])
        let target = (source as NSString).range(of: "end")
        layout.setMarkdownMathReferences([(rect: CGRect(x: 0, y: 0, width: 1, height: 1), target: target)], for: formula)
        XCTAssertEqual(layout.markdownMathReference(at: NSPoint(x: rect.midX, y: rect.midY), in: container)?.target, target)
        let glyph = layout.glyphIndexForCharacter(at: heading.range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let local = NSPoint(x: line.minX + container.lineFragmentPadding + 1, y: line.minY + 4)
        let expected = try XCTUnwrap(layout.uppercaseHeadingSourcePosition(at: local, in: container))
        let point = NSPoint(x: local.x + view.textContainerOrigin.x, y: local.y + view.textContainerOrigin.y)
        let windowPoint = view.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
        XCTAssertEqual(view.selectedRange().location, expected)
        let word = (source as NSString).range(of: "Straße")
        guard expected >= word.location, expected <= NSMaxRange(word) else {
            return XCTFail("Uppercase hit did not map to the first word")
        }
        func clickAgain(modifiers: NSEvent.ModifierFlags = [], count: Int = 1, drag: NSPoint? = nil) throws {
            layout.updateMarkdownRevealedRange((source as NSString).range(of: "end"))
            XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: runs, width: 200, level: 1, attachmentImages: images))
            layout.ensureLayout(for: container)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: count, pressure: 1))
            if let drag {
                let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: drag, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: count, pressure: 1))
                NSApp.postEvent(moved, atStart: false)
            }
            let released = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: drag ?? windowPoint, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: count, pressure: 0))
            NSApp.postEvent(released, atStart: false)
            view.mouseDown(with: event)
        }
        view.setSelectedRange(NSRange(location: NSMaxRange(word), length: 0))
        try clickAgain(modifiers: .shift)
        XCTAssertEqual(view.selectedRange(), NSRange(location: expected, length: NSMaxRange(word) - expected))
        try clickAgain(count: 2)
        XCTAssertEqual((source as NSString).substring(with: view.selectedRange()), "Straße")
        try clickAgain(count: 3)
        XCTAssertEqual(view.selectedRange(), (source as NSString).lineRange(for: word))
        layout.updateMarkdownRevealedRange(heading.range)
        layout.ensureLayout(forCharacterRange: heading.range)
        let caret = view.firstRect(forCharacterRange: NSRange(location: NSMaxRange(word), length: 0), actualRange: nil)
        let dragEnd = window.convertPoint(fromScreen: NSPoint(x: caret.midX, y: caret.midY))
        try clickAgain(drag: dragEnd)
        XCTAssertEqual(view.selectedRange(), NSRange(location: expected, length: NSMaxRange(word) - expected))
        XCTAssertEqual(storage.string, source)
    }

    func testTableSpanPreservesFontTraitsAndNestedColors() throws {
        _ = NSApplication.shared
        let source = "| H |\n|---|\n| <span style='color:red;font-size:2rem'>**bold <span style='background:yellow'>inner</span>**</span> |"
        let (storage, layout, _) = makeLayout(source)
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        let content = layout.tableCellAttributedText(cell, text: storage.mutableString)
        let bold = (content.string as NSString).range(of: "bold"), inner = (content.string as NSString).range(of: "inner")
        let font = try XCTUnwrap(content.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 32, accuracy: 0.1)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let foreground = try XCTUnwrap(content.attribute(.foregroundColor, at: inner.location, effectiveRange: nil) as? NSColor)
        let background = try XCTUnwrap(content.attribute(.backgroundColor, at: inner.location, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(foreground.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(background.usingColorSpace(.sRGB)?.greenComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(storage.string, source)
        let nested = "| H |\n|---|\n| <span style='color:red;background:red;font-size:2rem'><span style='color:yellow;background:yellow;font-size:1rem'>x</span></span> |"
        let nestedCell = try XCTUnwrap(MarkdownPresentationParser.parse(nested).tables.first?.rows.last?.cells.first)
        let nestedDisplay = layout.tableCellAttributedText(nestedCell, text: nested as NSString)
        let nestedColor = try XCTUnwrap(nestedDisplay.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let nestedBackground = try XCTUnwrap(nestedDisplay.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let nestedFont = try XCTUnwrap(nestedDisplay.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(nestedColor.usingColorSpace(.sRGB)?.greenComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(nestedBackground.usingColorSpace(.sRGB)?.greenComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(nestedFont.pointSize, 16, accuracy: 0.1)
    }

    func testInlineSpanAppliesNestedStyleAndRestoresSource() async throws {
        _ = NSApplication.shared
        let source = "<span style='color:red;font-size:2rem'>**bold <span style='background:yellow'>inner</span>**</span>\n\nend"
        let raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(raw.range(of: "end"))
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let bold = raw.range(of: "bold"), inner = raw.range(of: "inner")
        let font = try XCTUnwrap(storage.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 32, accuracy: 0.1)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let foreground = try XCTUnwrap(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: inner.location, effectiveRange: nil) as? NSColor)
        let background = try XCTUnwrap(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: inner.location, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(foreground.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(background.usingColorSpace(.sRGB)?.greenComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        let changed = "ordinary\n\nend", whole = NSRange(location: 0, length: storage.length)
        controller.beforeEdit(range: whole, replacementLength: (changed as NSString).length)
        storage.replaceCharacters(in: whole, with: changed)
        revision += 1
        controller.edited(revision: revision)
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: revision))
        XCTAssertNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
        controller.update(document: document, enabled: false, isActive: true, revision: revision, currentRevision: { revision })
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, changed)
    }

    func testUppercaseHeadingKeepsInlineSpanSizeAndTraits() throws {
        _ = NSApplication.shared
        let source = "# <span style='color:red;font-size:2rem'>**Straße**</span>\n\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let heading = try XCTUnwrap(presentation.headings.first), runs = try XCTUnwrap(heading.uppercaseRuns)
        layout.setMarkdownPresentation(presentation, revealedRange: (source as NSString).range(of: "end"))
        XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: runs, width: 300, level: heading.level))
        let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: runs.flatMap(\.pieces), sourceRange: heading.range))
        let word = (projection.text as NSString).range(of: "STRASSE")
        guard word.location != NSNotFound else { return XCTFail("Missing uppercase heading") }
        let font = try XCTUnwrap(layout.uppercaseHeadingFont(at: word.location, in: heading.range))
        XCTAssertEqual(font.pointSize, 32, accuracy: 0.1)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testKeyboardKeepsNestedFontTraitsInEditorAndUppercaseHeading() async throws {
        _ = NSApplication.shared
        let source = "**<kbd>bold</kbd>** and *<kbd>italic</kbd>*\n\n# **<kbd>bold</kbd>** *<kbd>italic</kbd>*\n\nend"
        let raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(raw.range(of: "end"))
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let bold = raw.range(of: "bold"), italic = raw.range(of: "italic")
        let manager = NSFontManager.shared
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        let boldFont = try XCTUnwrap(storage.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        let italicFont = try XCTUnwrap(storage.attribute(.font, at: italic.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(manager.traits(of: boldFont).contains(.boldFontMask))
        XCTAssertTrue(manager.traits(of: italicFont).contains(.italicFontMask))
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let heading = try XCTUnwrap(parsed.headings.first), runs = try XCTUnwrap(heading.uppercaseRuns)
        layout.setMarkdownPresentation(parsed, revealedRange: raw.range(of: "end"), inlineSelection: raw.range(of: "end"))
        XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: runs, width: 350, level: heading.level))
        let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: runs.flatMap(\.pieces), sourceRange: heading.range))
        let uppercaseBold = (projection.text as NSString).range(of: "BOLD")
        let uppercaseItalic = (projection.text as NSString).range(of: "ITALIC")
        let boldDisplayFont = try XCTUnwrap(layout.uppercaseHeadingFont(at: uppercaseBold.location, in: heading.range))
        let italicDisplayFont = try XCTUnwrap(layout.uppercaseHeadingFont(at: uppercaseItalic.location, in: heading.range))
        XCTAssertTrue(manager.traits(of: boldDisplayFont).contains(.boldFontMask))
        XCTAssertTrue(manager.traits(of: italicDisplayFont).contains(.italicFontMask))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testUppercaseHeadingDisplaysComposedCharacterAcrossStyles() throws {
        _ = NSApplication.shared
        let source = "# **e**\u{301} end\n\nrest"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let heading = try XCTUnwrap(presentation.headings.first)
        let runs = try XCTUnwrap(heading.uppercaseRuns)
        let base = try XCTUnwrap(runs.first { $0.pieces.map(\.text).joined() == "e" })
        let accent = try XCTUnwrap(runs.first { $0.pieces.map(\.text).joined().hasPrefix("\u{301}") })
        XCTAssertTrue(base.styles.contains(.strong))
        XCTAssertFalse(accent.styles.contains(.strong))
        layout.setMarkdownPresentation(presentation, revealedRange: (source as NSString).range(of: "rest"))
        XCTAssertTrue(layout.setUppercaseHeading(heading.range, runs: runs, width: 200, level: 1))
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: heading.range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertGreaterThan(line.height, 0)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testUppercaseHeadingPrototypeRejectsCanonicallyEquivalentDifferentSource() throws {
        let title = "e\u{301}\u{327}"
        let reordered = "e\u{327}\u{301}"
        XCTAssertEqual(title, reordered)
        let source = "# \(title)\n\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let heading = try XCTUnwrap(MarkdownPresentationParser.parse(source).headings.first)
        let titleRange = (source as NSString).range(of: title)
        XCTAssertFalse(layout.setPlainUppercaseHeading(heading.range, source: titleRange, text: reordered, width: 200, level: 1))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testUppercaseHeadingProjectionWrapsAndMapsGlyphHits() throws {
        _ = NSApplication.shared
        let source = "Straße e\u{301} 👩‍💻 " + String(repeating: "long heading ", count: 8)
        let projection = MarkdownHeadingUppercaseProjection(source)
        let expanded = (projection.text as NSString).range(of: "SS")
        let sharpS = (source as NSString).range(of: "ß")
        for vertical in [false, true] {
            for rightToLeft in [false, true] {
                let style = NSMutableParagraphStyle()
                style.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
                var attributes: [NSAttributedString.Key: Any] = [.font: lacEditorFont(size: 14), .paragraphStyle: style]
                if vertical { attributes[.verticalGlyphForm] = 1 }
                let storage = NSTextStorage(string: projection.text, attributes: attributes)
                let layout = NSLayoutManager()
                storage.addLayoutManager(layout)
                let container = NSTextContainer(containerSize: NSSize(width: 100, height: 2_000))
                layout.addTextContainer(container)
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
                let scroll = NSScrollView(frame: view.frame)
                scroll.documentView = view
                if vertical { view.setLayoutOrientation(.vertical) }
                container.containerSize = NSSize(width: 100, height: 2_000)
                layout.ensureLayout(for: container)
                let firstLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: 0), effectiveRange: nil)
                let lastLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: storage.length - 1), effectiveRange: nil)
                XCTAssertGreaterThan(lastLine.minY, firstLine.minY)
                for offset in 0..<2 {
                    let glyph = layout.glyphRange(forCharacterRange: NSRange(location: expanded.location + offset, length: 1), actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
                    let local = NSPoint(x: rect.minX + rect.width * 0.25 + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
                    let physical = scroll.contentView.convert(local, from: view)
                    let restored = view.convert(physical, from: scroll.contentView)
                    let point = NSPoint(x: restored.x - view.textContainerOrigin.x, y: restored.y - view.textContainerOrigin.y)
                    var fraction: CGFloat = 0
                    let position = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
                    XCTAssertEqual(projection.sourcePosition(for: position, fraction: fraction), offset == 0 ? sharpS.location : NSMaxRange(sharpS))
                }
                for value in ["e\u{301}", "👩‍💻"] {
                    let sourceRange = (source as NSString).range(of: value)
                    let displayRange = (projection.text as NSString).range(of: value.uppercased(with: Locale(identifier: "und")))
                    let glyphs = layout.glyphRange(forCharacterRange: displayRange, actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    var sides: [Bool] = []
                    for x in [CGFloat(0.2), CGFloat(0.8)] {
                        let point = NSPoint(x: rect.minX + rect.width * x, y: rect.midY)
                        var fraction: CGFloat = 0
                        let position = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
                        let after = position >= NSMaxRange(displayRange) || (position >= displayRange.location && fraction >= 0.5)
                        sides.append(after)
                        XCTAssertEqual(projection.sourcePosition(for: position, fraction: fraction), after ? NSMaxRange(sourceRange) : sourceRange.location)
                    }
                    XCTAssertEqual(Set(sides), Set([false, true]))
                }
                XCTAssertEqual(source, "Straße e\u{301} 👩‍💻 " + String(repeating: "long heading ", count: 8))
                withExtendedLifetime(scroll) {}
            }
        }
    }

    func testNumberedQuoteHeadingKeepsDirectionAndSource() async throws {
        _ = NSApplication.shared
        for vertical in [false, true] {
            let source = "> # 标题\r\n\r\nend"
            let document = EditorDocument(text: source, language: .markdown)
            let (storage, layout, container) = makeLayout(source)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            if vertical { view.setLayoutOrientation(.vertical) }
            layout.markdownRightToLeft = true
            view.setSelectedRange((source as NSString).range(of: "end"))
            let controller = MarkdownPresentationController(textView: view, layout: layout)
            controller.setHeadingNumbering(true)
            controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
            for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let heading = try XCTUnwrap(controller.navigationPresentation(document: document, revision: 0)?.headings.first)
            XCTAssertEqual(heading.number, "1. ")
            let position = (source as NSString).range(of: "标题").location
            let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: position, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.baseWritingDirection, .rightToLeft)
            XCTAssertGreaterThan(style.firstLineHeadIndent, 0)
            layout.ensureLayout(for: container)
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: position), effectiveRange: nil)
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            controller.setHeadingNumbering(false)
            controller.cancel()
            XCTAssertEqual(storage.string, source)
            withExtendedLifetime(scroll) {}
        }
    }

    func testCompletedTaskStrikethroughFollowsConfirmedItems() async throws {
        _ = NSApplication.shared
        let source = "- [x] done\n  - [ ] nested\n- [ ] pending"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.setStrikeCompletedTasks(true)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        func strike(_ text: String) -> Int? {
            let position = (source as NSString).range(of: text).location
            return (layout.temporaryAttributes(atCharacterIndex: position, effectiveRange: nil)[.strikethroughStyle] as? NSNumber)?.intValue
        }
        XCTAssertEqual(strike("done"), NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(strike("nested"), NSUnderlineStyle.single.rawValue)
        XCTAssertNil(strike("pending"))
        controller.setStrikeCompletedTasks(false)
        XCTAssertNil(strike("done"))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testVerticalTableUsesVerticalGlyphsAndPhysicalCellHit() throws {
        _ = NSApplication.shared
        let source = "| 中文 | $x$ |\n|---|---|\n| 甲 | B |"
        let result = MarkdownPresentationParser.parse(source)
        let table = try XCTUnwrap(result.tables.first)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setLayoutOrientation(.vertical)
        layout.setMarkdownPresentation(result, revealedRange: nil)
        layout.ensureLayout(for: container)
        let first = try XCTUnwrap(table.rows.first?.cells.first)
        let second = try XCTUnwrap(table.rows.first?.cells.last)
        let formula = try XCTUnwrap(result.inlineFormulas.first)
        XCTAssertTrue(layout.setMarkdownInlineImage(NSImage(size: NSSize(width: 80, height: 30)), for: formula.range))
        let target = (source as NSString).range(of: "中文")
        layout.setMarkdownMathReferences([(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), target: target)], for: formula.range)
        let content = layout.tableCellAttributedText(first, text: storage.mutableString)
        XCTAssertEqual((content.attribute(.verticalGlyphForm, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 1)
        let firstRect = try XCTUnwrap(layout.markdownTableFrame(for: first, in: container))
        let secondRect = try XCTUnwrap(layout.markdownTableFrame(for: second, in: container))
        let firstPhysical = scroll.contentView.convert(firstRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        let secondPhysical = scroll.contentView.convert(secondRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        XCTAssertNotEqual(firstPhysical.midY, secondPhysical.midY, accuracy: 0.5)
        let pointInView = view.convert(NSPoint(x: secondPhysical.midX, y: secondPhysical.midY), from: scroll.contentView)
        let point = NSPoint(x: pointInView.x - view.textContainerOrigin.x, y: pointInView.y - view.textContainerOrigin.y)
        XCTAssertEqual(layout.markdownTableCellInfo(at: point, in: container)?.0.range, second.range)
        let formulaRect = try XCTUnwrap(layout.markdownRenderedImageRects(for: [formula.range], in: container)[formula.range])
        let formulaPhysical = scroll.contentView.convert(formulaRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
        XCTAssertEqual(formulaPhysical.width, 80, accuracy: 0.5)
        XCTAssertEqual(formulaPhysical.height, 30, accuracy: 0.5)
        let formulaPoint = view.convert(NSPoint(x: formulaPhysical.minX + formulaPhysical.width * 0.25, y: formulaPhysical.minY + formulaPhysical.height * 0.25), from: scroll.contentView)
        let hitPoint = NSPoint(x: formulaPoint.x - view.textContainerOrigin.x, y: formulaPoint.y - view.textContainerOrigin.y)
        XCTAssertEqual(layout.markdownMathReference(at: hitPoint, in: container)?.target, target)
        let outside = view.convert(NSPoint(x: formulaPhysical.minX + formulaPhysical.width * 0.25, y: formulaPhysical.minY + formulaPhysical.height * 0.75), from: scroll.contentView)
        XCTAssertNil(layout.markdownMathReference(at: NSPoint(x: outside.x - view.textContainerOrigin.x, y: outside.y - view.textContainerOrigin.y), in: container))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testRightToLeftReversesTableColumnsAndCellDirection() throws {
        let source = "| العربية | English |\n|---|---|\n| مرحبا | hello |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let ordinary = layout.markdownTableGeometry(table, text: storage.mutableString, width: 400)
        layout.markdownRightToLeft = true
        let rtl = layout.markdownTableGeometry(table, text: storage.mutableString, width: 400)
        XCTAssertEqual(ordinary.count, rtl.count)
        guard ordinary.count >= 2, rtl.count >= 2 else { XCTFail("Missing table cells"); return }
        XCTAssertLessThan(ordinary[0].rect.minX, ordinary[1].rect.minX)
        XCTAssertGreaterThan(rtl[0].rect.minX, rtl[1].rect.minX)
        let style = layout.tableCellAttributedText(rtl[0].cell, text: storage.mutableString)
            .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft)
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        layout.ensureLayout(for: container)
        let first = try XCTUnwrap(layout.markdownTableFrame(for: rtl[0].cell, in: container))
        let hit = try XCTUnwrap(layout.markdownTableCellInfo(at: NSPoint(x: first.midX, y: first.midY), in: container))
        XCTAssertEqual(hit.0.range, rtl[0].cell.range)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testRightToLeftPlacesListMarkerWithItsText() async throws {
        _ = NSApplication.shared
        let source = "- مرحبا\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (_, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        layout.markdownRightToLeft = true
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        layout.ensureLayout(for: container)
        let marker = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
        let text = layout.glyphRange(forCharacterRange: (source as NSString).range(of: "مرحبا"), actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: marker, in: container).midX,
                             layout.boundingRect(forGlyphRange: text, in: container).midX)
        XCTAssertEqual(view.string, source)
    }

    func testRightToLeftPreservesAlignmentAndRestoresSource() async throws {
        _ = NSApplication.shared
        let source = "مرحبا English 😀\n\nsecond"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        layout.markdownRightToLeft = true
        layout.markdownTextAlignment = .center
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testCenteredHeadingLevelsOverrideGeneralAlignment() async throws {
        _ = NSApplication.shared
        let source = "# 中文😀\r\n\r\n## second\r\n\r\nbody"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        layout.markdownTextAlignment = .right
        layout.markdownCenteredHeadingLevels = [1]
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        func alignment(_ text: String) -> NSTextAlignment? {
            let position = (source as NSString).range(of: text).location
            return (storage.attribute(.paragraphStyle, at: position, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        XCTAssertEqual(alignment("中文"), .center)
        XCTAssertEqual(alignment("second"), .right)
        XCTAssertEqual(alignment("body"), .right)
        layout.markdownCenteredHeadingLevels = []
        controller.metricsChanged()
        XCTAssertEqual(alignment("中文"), .right)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testParagraphAlignmentChangesVisibleTextAndRestoresSource() async throws {
        _ = NSApplication.shared
        let source = "first\n\n中文😀 second"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        layout.markdownTextAlignment = .center
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        func alignment(_ location: Int) -> NSTextAlignment? {
            (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        XCTAssertEqual(alignment(0), .center)
        XCTAssertEqual(alignment((source as NSString).range(of: "中文").location), .center)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where alignment(0) != .center { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(alignment(0), .center)
        let refreshed = expectation(description: "paragraph style chunk reapplied")
        view.paragraphStylesChangedHandler = { range in
            controller.paragraphStylesDidChange(in: range)
            refreshed.fulfill()
        }
        view.configureTabStops()
        view.scheduleParagraphStyleRefresh()
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(alignment(0), .center)
        view.paragraphStylesChangedHandler = nil
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNotEqual(alignment(0), .center)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testInlineSpanRestoresVisitedOffscreenColors() async throws {
        _ = NSApplication.shared
        let source = "<span style='color:red'>first</span>\n\n" + String(repeating: "plain 中文\n\n", count: 600) + "<span style='color:red'>last</span>\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 30_000), textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        let first = (source as NSString).range(of: "first").location
        let last = (source as NSString).range(of: "last").location
        XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: first, effectiveRange: nil))
        layout.ensureLayout(forCharacterRange: NSRange(location: last, length: 1))
        let y = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: last), effectiveRange: nil).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.viewportChanged()
        XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: last, effectiveRange: nil))
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: first, effectiveRange: nil))
        XCTAssertNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: last, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
    }

    func testHeadingNumberingRestoresVisitedOffscreenHeadings() async throws {
        _ = NSApplication.shared
        let source = "# first\n\n" + String(repeating: "plain 中文\n\n", count: 600) + "# last\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 30_000), textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.setHeadingNumbering(true)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        let first = (source as NSString).range(of: "first").location
        let last = (source as NSString).range(of: "last").location
        func indent(_ location: Int) -> CGFloat {
            (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        }
        XCTAssertGreaterThan(indent(first), 0)
        layout.ensureLayout(forCharacterRange: NSRange(location: last, length: 1))
        let y = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: last), effectiveRange: nil).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.viewportChanged()
        XCTAssertGreaterThan(indent(last), 0)
        controller.setHeadingNumbering(false)
        XCTAssertNil(storage.attribute(.paragraphStyle, at: first, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.paragraphStyle, at: last, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
    }

    func testParagraphAlignmentFollowsScrollingAndRestoresVisitedText() async throws {
        _ = NSApplication.shared
        let source = String(repeating: "office 中文\n", count: 600)
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 20_000), textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = view
        layout.markdownTextAlignment = .right
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        func alignment(_ index: Int) -> NSTextAlignment? {
            (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.alignment
        }
        XCTAssertEqual(alignment(0), .right)
        let distant = (source as NSString).range(of: "office", options: .backwards).location
        layout.ensureLayout(forCharacterRange: NSRange(location: distant, length: 1))
        let glyph = layout.glyphIndexForCharacter(at: distant)
        let y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.viewportChanged()
        XCTAssertEqual(alignment(distant), .right)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.paragraphStyle, at: distant, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
    }

    func testParagraphSpacingReplacesBlankSeparatorAndRevealsSource() throws {
        _ = NSApplication.shared
        let source = "first\r\nsecond\r\n\r\n \r\nnext"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let parsed = MarkdownPresentationParser.parse(source)
        let separator = try XCTUnwrap(parsed.paragraphs.first?.separatorAfter)
        let next = (source as NSString).range(of: "next")
        func y(_ range: NSRange) -> CGFloat {
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        layout.markdownParagraphSpacing = 0
        layout.setMarkdownPresentation(parsed, revealedRange: next)
        layout.ensureLayout(for: container)
        let compact = y(next)
        layout.markdownParagraphSpacing = 40
        layout.invalidateMarkdownLayout(in: NSRange(location: 0, length: storage.length))
        layout.ensureLayout(for: container)
        XCTAssertEqual(y(next) - compact, 40, accuracy: 1)
        layout.updateMarkdownRevealedRange(separator)
        layout.ensureLayout(for: container)
        XCTAssertGreaterThan(y(next), compact + layout.editorLineHeight)
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        layout.ensureLayout(for: container)
        XCTAssertGreaterThan(y(next), compact + layout.editorLineHeight)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testParagraphSpacingRestoresSourceModeThroughController() async throws {
        _ = NSApplication.shared
        let source = "first\n\nnext"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let next = (source as NSString).range(of: "next")
        view.setSelectedRange(next)
        layout.markdownParagraphSpacing = 0
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: next.location)
        let formattedY = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        layout.ensureLayout(for: container)
        XCTAssertGreaterThan(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY, formattedY + layout.editorLineHeight / 2)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testParagraphSpacingIsAppliedOnceAfterWrappedLine() {
        _ = NSApplication.shared
        let source = String(repeating: "long words ", count: 30) + "\n\nnext"
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 160, height: CGFloat.greatestFiniteMagnitude)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 1000), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let next = (source as NSString).range(of: "next")
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: next)
        func nextY() -> CGFloat {
            layout.ensureLayout(for: container)
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: next.location), effectiveRange: nil).minY
        }
        layout.markdownParagraphSpacing = 0
        layout.invalidateMarkdownLayout(in: NSRange(location: 0, length: storage.length))
        let withoutGap = nextY()
        layout.markdownParagraphSpacing = 40
        layout.invalidateMarkdownLayout(in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(nextY() - withoutGap, 40, accuracy: 1)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testListMarkerStylesFollowDeepScrollAndReset() async throws {
        _ = NSApplication.shared
        let source = "9. first\n\n" + String(repeating: "plain 中文\n\n", count: 600) + "9. last\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 30_000), textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = view
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let parsed = try XCTUnwrap(controller.navigationPresentation(document: document, revision: 0))
        let first = try XCTUnwrap(parsed.listMarkers.first)
        let last = try XCTUnwrap(parsed.listMarkers.last)
        var styles = MarkdownListStyles()
        styles.ordered[1] = .upperRoman
        layout.markdownListStyles = styles
        controller.metricsChanged()
        func markerWidth(_ marker: MarkdownListMarker) -> CGFloat {
            layout.ensureLayout(forCharacterRange: marker.range)
            let glyph = layout.glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyph, in: container).width
        }
        let font = (storage.attribute(.font, at: first.range.location, effectiveRange: nil) as? NSFont) ?? layout.textFont
        let roman = ("IX." as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(markerWidth(first), roman, accuracy: 1)
        layout.ensureLayout(forCharacterRange: last.range)
        let y = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: last.range.location), effectiveRange: nil).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.viewportChanged()
        XCTAssertEqual(markerWidth(last), roman, accuracy: 1)
        layout.markdownListStyles = .init()
        controller.metricsChanged()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        controller.viewportChanged()
        let decimal = ("9." as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(markerWidth(first), decimal, accuracy: 1)
        XCTAssertEqual(storage.string, source)
    }

    func testListMarkerStyleChangesWidthWithoutEditingSource() throws {
        _ = NSApplication.shared
        let source = "9. one\n1. two\n   - nested\n\nafter"
        let (storage, layout, container) = makeLayout(source)
        let presentation = MarkdownPresentationParser.parse(source)
        let ordered = try XCTUnwrap(presentation.listMarkers.first { $0.ordinal == 10 })
        let nested = try XCTUnwrap(presentation.listMarkers.first { $0.depth == 2 })
        var styles = MarkdownListStyles()
        styles.ordered[1] = .upperRoman
        styles.unordered[2] = .custom
        styles.customMarkers[2] = "😀"
        layout.markdownListStyles = styles
        layout.setMarkdownPresentation(presentation, revealedRange: (source as NSString).range(of: "after"))
        layout.ensureLayout(for: container)
        for (marker, expected) in [(ordered, "X."), (nested, "😀")] {
            let glyph = layout.glyphIndexForCharacter(at: marker.range.location)
            let actual = layout.layoutManager(layout, boundingBoxForControlGlyphAt: glyph, for: container,
                                              proposedLineFragment: .zero, glyphPosition: .zero, characterIndex: marker.range.location)
            let font = (storage.attribute(.font, at: marker.range.location, effectiveRange: nil) as? NSFont) ?? layout.textFont
            XCTAssertEqual(actual.width, (expected as NSString).size(withAttributes: [.font: font]).width, accuracy: 0.5)
        }
        layout.updateMarkdownRevealedRange(ordered.line)
        layout.ensureLayout(for: container)
        XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: ordered.range.location)).contains(.controlCharacter))
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(storage.string, source)
    }

    func testListMarkerGlyphRevealsSourceAndSurvivesMarkedText() throws {
        _ = NSApplication.shared
        let source = "9. one\n1. two\n\nafter"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let parsed = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(parsed.listMarkers.map(\.text), ["9.", "10."])
        let marker = try XCTUnwrap(parsed.listMarkers.last)
        layout.setMarkdownPresentation(parsed, revealedRange: (source as NSString).range(of: "after"))
        layout.ensureLayout(for: container)
        func markerIsControl() -> Bool {
            layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: marker.range.location)).contains(.controlCharacter)
        }
        XCTAssertTrue(markerIsControl())
        let glyphs = layout.glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
        let markerRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertGreaterThan(markerRect.width, 0)
        let hit = layout.characterIndex(for: NSPoint(x: markerRect.midX, y: markerRect.midY), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        XCTAssertGreaterThanOrEqual(hit, marker.range.location)
        XCTAssertLessThanOrEqual(hit, NSMaxRange(marker.range))
        layout.updateMarkdownRevealedRange((source as NSString).range(of: "two"))
        layout.ensureLayout(for: container)
        XCTAssertFalse(markerIsControl())
        layout.updateMarkdownRevealedRange((source as NSString).range(of: "after"))
        layout.ensureLayout(for: container)
        XCTAssertTrue(markerIsControl())
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.addSubview(child)
        child.setMarkedText("文", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertTrue(markerIsControl())
        XCTAssertEqual(storage.string, source)
        child.unmarkText()
        child.removeFromSuperview()
        let body = (source as NSString).range(of: "two")
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSMaxRange(body), length: 0))
        XCTAssertTrue(view.hasMarkedText())
        layout.ensureLayout(for: container)
        XCTAssertTrue(markerIsControl())
        XCTAssertTrue(view.string.contains("two中"))
        view.unmarkText()
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        layout.ensureLayout(for: container)
        XCTAssertFalse(markerIsControl())
        withExtendedLifetime(scroll) {}
    }
    func testSmallCapsFallsBackForFontWithoutFeature() throws {
        _ = NSApplication.shared
        let unsupported = NSFontManager.shared.availableFonts.lazy.compactMap { NSFont(name: $0, size: 14) }
            .first { !FoldLayoutManager.supportsSmallCaps($0) }
        guard let unsupported else { throw XCTSkip("Every installed font advertises small caps") }
        let (_, layout, _) = makeLayout("text")
        XCTAssertNil(layout.smallCapsFont(unsupported))
    }

    func testSmallCapsUsesSupportedFontOnlyForSelectedHeadings() async throws {
        _ = NSApplication.shared
        let supported = NSFontManager.shared.availableFonts.lazy.compactMap { NSFont(name: $0, size: 14) }
            .first { FoldLayoutManager.supportsSmallCaps(NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask)) }
        guard let supported else { throw XCTSkip("No installed font advertises small caps") }
        let source = "# First\n\n## Second"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        layout.textFont = supported
        layout.markdownSmallCapsLevels = [1]
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        let first = try XCTUnwrap(storage.attribute(.font, at: (source as NSString).range(of: "First").location, effectiveRange: nil) as? NSFont)
        let second = try XCTUnwrap(storage.attribute(.font, at: (source as NSString).range(of: "Second").location, effectiveRange: nil) as? NSFont)
        XCTAssertNotNil(first.fontDescriptor.object(forKey: .featureSettings))
        XCTAssertEqual(second, layout.markdownHeadingFont(level: 2))
        XCTAssertEqual(storage.string, source)
    }

    func testSmartQuoteAtConfirmedBlankLineExcludesOpaqueContexts() async throws {
        _ = NSApplication.shared
        for (source, allowed) in [("", true), ("text\n\n", true), ("text\r\n\r\n", true), ("   ", true),
                                  ("```\n\n", false), ("```\r\n\r\n", false), ("before <script>\n\n", false),
                                  ("\t", false), ("> ", false)] {
            let document = EditorDocument(text: source, language: .markdown)
            let (storage, layout, container) = makeLayout(source)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let controller = MarkdownPresentationController(textView: view, layout: layout)
            var revision: UInt = 0
            controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
            for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(controller.navigationPresentation(document: document, revision: revision), source)
            let insertion = NSRange(location: storage.length, length: 0)
            revision += 1
            controller.noteFenceContextEdit(range: insertion, replacement: "\"", in: storage.mutableString, revision: revision)
            storage.replaceCharacters(in: insertion, with: "\"")
            XCTAssertEqual(controller.allowsSmartSubstitution(document: document, revision: revision,
                range: NSRange(location: insertion.location, length: 1)), allowed, source)
            controller.cancel()
            withExtendedLifetime(scroll) {}
        }
    }

    func testTableCellUsesLigatureSettingWithoutChangingSource() throws {
        let source = "| A |\n|---|\n| office ffi |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let cell = try XCTUnwrap(table.rows.last?.cells.first)
        let (storage, layout, _) = makeLayout(source)
        XCTAssertNil(layout.tableCellAttributedText(cell, text: storage.mutableString).attribute(.ligature, at: 0, effectiveRange: nil))
        layout.markdownLigatures = 0
        XCTAssertEqual((layout.tableCellAttributedText(cell, text: storage.mutableString).attribute(.ligature, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 0)
        layout.markdownLigatures = 2
        XCTAssertEqual((layout.tableCellAttributedText(cell, text: storage.mutableString).attribute(.ligature, at: 0, effectiveRange: nil) as? NSNumber)?.intValue, 2)
        layout.markdownLigatures = nil
        XCTAssertNil(layout.tableCellAttributedText(cell, text: storage.mutableString).attribute(.ligature, at: 0, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
    }

    func testSmartTextRangesIncludeConfirmedPunctuationButExcludeEntitiesAndEscapes() {
        let source = "say \"hello\" -- world &amp; \\-- end"
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
        let raw = source as NSString
        func contains(_ range: NSRange) -> Bool {
            parsed.smartTextRanges.contains { $0.location <= range.location && NSMaxRange(range) <= NSMaxRange($0) }
        }
        XCTAssertTrue(contains(raw.range(of: "\"hello\" -- world")))
        XCTAssertFalse(contains(raw.range(of: "&amp;")))
        XCTAssertFalse(contains(raw.range(of: "\\--")))
    }

    func testSmartSubstitutionRequiresCurrentPlainTextRange() async throws {
        _ = NSApplication.shared
        let source = "start 中文 hello world `code` [link](https://example.com/path)"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: revision))
        XCTAssertTrue(controller.allowsSmartSubstitution(document: document, revision: revision, range: storage.mutableString.range(of: "start")))
        XCTAssertFalse(controller.allowsSmartSubstitution(document: document, revision: revision, range: NSRange(location: 0, length: 0)))
        let word = storage.mutableString.range(of: "hello")
        XCTAssertTrue(controller.allowsSmartSubstitution(document: document, revision: revision, range: word))
        for value in ["code", "https://example.com/path"] {
            XCTAssertFalse(controller.allowsSmartSubstitution(document: document, revision: revision, range: storage.mutableString.range(of: value)))
        }
        XCTAssertFalse(controller.allowsSmartSubstitution(document: document, revision: revision + 1, range: word))
        let insertion = NSRange(location: NSMaxRange(word), length: 0)
        revision += 1
        controller.noteFenceContextEdit(range: insertion, replacement: "x", in: storage.mutableString, revision: revision)
        storage.replaceCharacters(in: insertion, with: "x")
        XCTAssertTrue(controller.allowsSmartSubstitution(document: document, revision: revision, range: NSRange(location: word.location, length: word.length + 1)))
        revision += 1
        controller.noteFenceContextEdit(range: NSRange(location: insertion.location + 1, length: 0), replacement: "`", in: storage.mutableString, revision: revision)
        XCTAssertFalse(controller.allowsSmartSubstitution(document: document, revision: revision, range: word))
    }

    func testEmojiCompletionExcludesTextInsideRawHTML() {
        for tag in ["script", "style", "textarea"] {
            let source = "before <\(tag)>\n\ninside :smile:\n\n</\(tag)>\n\nafter :smile:"
            let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
            let raw = source as NSString
            let inside = raw.range(of: "inside :smile:")
            let after = raw.range(of: "after :smile:")
            XCTAssertFalse(parsed.emojiCompletionRanges.contains { NSIntersectionRange($0, inside).length > 0 }, tag)
            XCTAssertTrue(parsed.emojiCompletionRanges.contains { NSIntersectionRange($0, after).length > 0 }, tag)
            XCTAssertEqual(parsed.emojiCandidates.map(\.range), [raw.range(of: ":smile:", options: .backwards)], tag)
        }
    }

    func testEmojiCompletionUsesCurrentTextSnapshotAndSafeEdits() async throws {
        _ = NSApplication.shared
        let source = "中文 hello `:code` [link](https://example.com/:url)"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        var revision: UInt = 0
        controller.update(document: document, enabled: false, isActive: true, revision: revision, currentRevision: { revision })
        XCTAssertNil(controller.navigationPresentation(document: document, revision: revision))
        let sentinel = document.taskCoordinator.begin(.markdownPresentation)
        revision += 1
        controller.noteFenceContextEdit(range: NSRange(location: 0, length: 0), replacement: "x", in: storage.mutableString, revision: revision)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        controller.edited(revision: revision)
        XCTAssertNil(controller.work)
        XCTAssertTrue(document.taskCoordinator.isCurrent(sentinel, for: .markdownPresentation))
        let position = NSMaxRange(storage.mutableString.range(of: "hello"))
        controller.beginEmojiCompletion()
        revision += 1
        controller.noteFenceContextEdit(range: NSRange(location: position, length: 0), replacement: ":", in: storage.mutableString, revision: revision)
        storage.replaceCharacters(in: NSRange(location: position, length: 0), with: ":")
        controller.edited(revision: revision)
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: revision))
        for word in [":code", ":url"] {
            XCTAssertFalse(controller.allowsEmojiCompletion(document: document, revision: revision, prefixRange: storage.mutableString.range(of: word)))
        }
        XCTAssertTrue(controller.allowsEmojiCompletion(document: document, revision: revision, prefixRange: NSRange(location: position, length: 1)))
        revision += 1
        controller.noteFenceContextEdit(range: NSRange(location: position + 1, length: 0), replacement: "sm", in: storage.mutableString, revision: revision)
        storage.replaceCharacters(in: NSRange(location: position + 1, length: 0), with: "sm")
        XCTAssertTrue(controller.allowsEmojiCompletion(document: document, revision: revision, prefixRange: NSRange(location: position, length: 3)))
        revision += 1
        controller.noteFenceContextEdit(range: NSRange(location: position + 3, length: 0), replacement: "`", in: storage.mutableString, revision: revision)
        XCTAssertFalse(controller.allowsEmojiCompletion(document: document, revision: revision, prefixRange: NSRange(location: position, length: 3)))
    }

    func testWikiCompletionAllowedOnlyInConfirmedText() async throws {
        _ = NSApplication.shared
        let source = "中文 hello `[[code` [link](https://example.com/[[url)"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); withExtendedLifetime(scroll) {} }
        var revision: UInt = 0
        controller.update(document: document, enabled: false, isActive: true, revision: revision, currentRevision: { revision })
        let position = NSMaxRange(storage.mutableString.range(of: "hello"))
        controller.beginWikiCompletion()
        revision += 1
        controller.noteFenceContextEdit(range: NSRange(location: position, length: 0), replacement: "[[", in: storage.mutableString, revision: revision)
        storage.replaceCharacters(in: NSRange(location: position, length: 0), with: "[[")
        controller.edited(revision: revision)
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: revision))
        XCTAssertTrue(controller.allowsWikiCompletion(document: document, revision: revision, range: NSRange(location: position, length: 2)))
        for word in ["[[code", "[[url"] {
            XCTAssertFalse(controller.allowsWikiCompletion(document: document, revision: revision, range: storage.mutableString.range(of: word)))
        }
    }

    func testConfirmedEmptyNestedFenceProvidesContinuationPrefix() async throws {
        _ = NSApplication.shared
        for (source, prefix, continuation) in [
            ("> ```js", "> ", "> "),
            ("> - ```js", "> - ", ">   "),
            ("- parent\r\n\r\n  ```js", "  ", "  "),
            ("> -\t```js", "> -\t", ">  \t")
        ] {
            let document = EditorDocument(text: source, language: .markdown)
            let (storage, layout, container) = makeLayout(source)
            let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
            let scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            let controller = MarkdownPresentationController(textView: view, layout: layout)
            var revision: UInt = 0
            controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
            for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            let line = storage.mutableString.lineRange(for: NSRange(location: storage.length, length: 0))
            let opening = try XCTUnwrap(controller.fenceContainerOpening(document: document, revision: 0, lineRange: line), source)
            XCTAssertEqual(opening.sourcePrefix, prefix, source)
            XCTAssertEqual(opening.continuationPrefix, continuation, source)
            XCTAssertNil(controller.fenceContainerOpening(document: document, revision: 1, lineRange: line))
            let edit = NSRange(location: storage.length, length: 0)
            revision += 1
            controller.noteFenceContextEdit(range: edit, replacement: "x", in: storage.mutableString, revision: revision)
            storage.replaceCharacters(in: edit, with: "x")
            let changedLine = storage.mutableString.lineRange(for: NSRange(location: storage.length, length: 0))
            XCTAssertEqual(controller.fenceContainerOpening(document: document, revision: revision, lineRange: changedLine)?.continuationPrefix, continuation)
            revision += 1
            let prefixEdit = NSRange(location: changedLine.location, length: 1)
            controller.noteFenceContextEdit(range: prefixEdit, replacement: "", in: storage.mutableString, revision: revision)
            storage.replaceCharacters(in: prefixEdit, with: "")
            let altered = storage.mutableString.lineRange(for: NSRange(location: storage.length, length: 0))
            XCTAssertNil(controller.fenceContainerOpening(document: document, revision: revision, lineRange: altered))
            controller.cancel()
            withExtendedLifetime(scroll) {}
        }
    }

    func testEmojiWordCountWaitsForResolverAndUsesDisplayedText() async throws {
        _ = NSApplication.shared
        let source = "hello :smile:"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let started = expectation(description: "emoji resolver started")
        let gate = DispatchSemaphore(value: 0)
        controller.emojiResolver = { _, _ in started.fulfill(); gate.wait(); return ["smile": "😄"] }
        defer { gate.signal(); controller.cancel(); document.cancelMetricsRefresh() }
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [started], timeout: 10)
        XCTAssertNil(document.statistics)
        gate.signal()
        for _ in 0..<200 where document.statistics == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(document.statistics?.words, 1)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testEmojiWordCountIsUnavailableOnResolverFailure() async throws {
        _ = NSApplication.shared
        let source = "hello :smile:"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); document.cancelMetricsRefresh() }
        let completed = expectation(description: "failed emoji resolver published")
        controller.emojiResolver = { _, _ in nil }
        controller.emojiResolutionDidComplete = { completed.fulfill() }
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [completed], timeout: 10)
        for _ in 0..<200 where !document.statisticsUnavailable { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.statisticsUnavailable)
        XCTAssertNil(document.statistics)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testSourceOutlinePublishesResolvedEmojiWithoutChangingHeadingIdentity() async throws {
        _ = NSApplication.shared
        let source = "# 中😀 :smile: `:smile:`"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.emojiResolver = { _, _ in ["smile": "😄"] }
        controller.update(document: document, enabled: false, outlineVisible: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where document.markdownHeadings.first?.renderedTitle != "中😀 😄 :smile:" {
            try await Task.sleep(for: .milliseconds(20))
        }
        let heading = try XCTUnwrap(document.markdownHeadings.first)
        XCTAssertEqual(heading.renderedTitle, "中😀 😄 :smile:")
        XCTAssertEqual(heading.title, "中😀 :smile: :smile:")
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }

    func testNestedParagraphSnapshotSurvivesReplacingContentWithFence() async throws {
        _ = NSApplication.shared
        let source = "> - old"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let edit = storage.mutableString.range(of: "old")
        revision += 1
        controller.noteFenceContextEdit(range: edit, replacement: "```js", in: storage.mutableString, revision: revision)
        storage.replaceCharacters(in: edit, with: "```js")
        let line = storage.mutableString.lineRange(for: NSRange(location: storage.length, length: 0))
        let opening = try XCTUnwrap(controller.fenceContainerOpening(document: document, revision: revision, lineRange: line))
        XCTAssertEqual(opening.sourcePrefix, "> - ")
        XCTAssertEqual(opening.continuationPrefix, ">   ")
        XCTAssertEqual(storage.string, "> - ```js")
        withExtendedLifetime(scroll) {}
    }

    func testFenceContextSurvivesOnlySameLineEdits() async throws {
        _ = NSApplication.shared
        let source = "before\n\ntext\n\n```js\ninside\n```\n"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        var revision: UInt = 0
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: revision) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let line = storage.mutableString.lineRange(for: storage.mutableString.range(of: "text"))
        XCTAssertTrue(controller.allowsFenceOpening(document: document, revision: revision, lineRange: line))
        let inside = storage.mutableString.lineRange(for: storage.mutableString.range(of: "inside"))
        XCTAssertFalse(controller.allowsFenceOpening(document: document, revision: revision, lineRange: inside))
        let insertion = NSRange(location: NSMaxRange(storage.mutableString.range(of: "text")), length: 0)
        revision += 1
        controller.noteFenceContextEdit(range: insertion, replacement: "x", in: storage.mutableString, revision: revision)
        storage.replaceCharacters(in: insertion, with: "x")
        let changedLine = storage.mutableString.lineRange(for: insertion)
        XCTAssertTrue(controller.allowsFenceOpening(document: document, revision: revision, lineRange: changedLine))
        revision += 1
        controller.noteFenceContextEdit(range: NSRange(location: 0, length: 0), replacement: "x", in: storage.mutableString, revision: revision)
        XCTAssertFalse(controller.allowsFenceOpening(document: document, revision: revision, lineRange: changedLine))
        withExtendedLifetime(scroll) {}
    }

    func testCodeHighlightFailureDoesNotRepeatOnScroll() async throws {
        _ = NSApplication.shared
        let source = "```js\nlet x = 1\n```\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        let completed = expectation(description: "first unsuccessful highlight completed")
        let lock = NSLock()
        var attempts = 0
        controller.codeHighlighter = { _, _, _, _, _ in
            lock.withLock { attempts += 1 }
            return nil
        }
        controller.codeHighlightDidComplete = { _ in completed.fulfill() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [completed], timeout: 10)
        controller.viewportChanged()
        controller.viewportChanged()
        try await Task.sleep(for: .milliseconds(200))
        let count = lock.withLock { attempts }
        XCTAssertEqual(count, 1)
        withExtendedLifetime((scroll, storage)) {}
    }

    func testNestedCodeHighlightKeepsContainerPrefixColors() async throws {
        _ = NSApplication.shared
        let source = "> - ```js\r\n>   let value = 42;\r\n>   ```\r\n\r\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        let prefix = (source as NSString).range(of: ">   let")
        let prefixRange = NSRange(location: prefix.location, length: 4)
        layout.addTemporaryAttribute(.foregroundColor, value: NSColor.magenta, forCharacterRange: prefixRange)
        let completed = expectation(description: "nested code highlighted")
        controller.codeHighlightDidComplete = { _ in completed.fulfill() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [completed], timeout: 10)
        let number = (source as NSString).range(of: "42").location
        XCTAssertNotNil(layout.temporaryAttributes(atCharacterIndex: number, effectiveRange: nil)[.foregroundColor])
        XCTAssertEqual(layout.temporaryAttributes(atCharacterIndex: prefixRange.location, effectiveRange: nil)[.foregroundColor] as? NSColor, .magenta)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testCodeHighlightRetriesAfterResultArrivesDuringMarkedText() async throws {
        _ = NSApplication.shared
        let source = "```js\nlet x = 42;\n```\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let started = expectation(description: "first code job started")
        let finished = expectation(description: "first code job finished")
        let rejected = expectation(description: "completion during marked input")
        let retried = expectation(description: "code job retried")
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var count = 0
        controller.codeHighlightDidComplete = { _ in
            if view.hasMarkedText() { rejected.fulfill() }
        }
        controller.codeHighlighter = { segments, literal, info, visible, operation in
            lock.lock(); count += 1; let number = count; lock.unlock()
            if number == 1 { started.fulfill(); gate.wait() }
            else if number == 2 { retried.fulfill() }
            let tokens = MarkdownCodeHighlightService.tokens(segments: segments, literal: literal,
                info: info, visible: visible, isCancelled: { operation.isCancelled })
            if number == 1 { finished.fulfill() }
            return tokens
        }
        defer { gate.signal(); controller.cancel() }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        await fulfillment(of: [started], timeout: 10)
        let after = (source as NSString).range(of: "after")
        view.setMarkedText("after", selectedRange: NSRange(location: 5, length: 0), replacementRange: after)
        XCTAssertTrue(view.hasMarkedText())
        gate.signal()
        await fulfillment(of: [finished], timeout: 10)
        await fulfillment(of: [rejected], timeout: 10)
        view.unmarkText()
        controller.metricsChanged()
        await fulfillment(of: [retried], timeout: 10)
        for _ in 0..<100 {
            if layout.temporaryAttributes(atCharacterIndex: (source as NSString).range(of: "42").location, effectiveRange: nil)[.foregroundColor] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(layout.temporaryAttributes(atCharacterIndex: (source as NSString).range(of: "42").location, effectiveRange: nil)[.foregroundColor])
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testCodeBlockColorsSurviveMarkdownHighlightAndRestoreSourceColors() async throws {
        _ = NSApplication.shared
        let source = "中文😀\n\n```js\nlet x = 42;\n```\n\n```js\nlet y = 17;\n```\n\nafter"
        let document = EditorDocument(text: source, language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false) }
        let positions = ["42", "17"].map { (source as NSString).range(of: $0).location }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        coordinator.updateMarkdownPresentation()
        coordinator.scheduleHighlight(delay: 0)
        for _ in 0..<100 {
            if positions.allSatisfy({ layout.temporaryAttributes(atCharacterIndex: $0, effectiveRange: nil)[.foregroundColor] != nil }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let original = try positions.map { try XCTUnwrap(layout.temporaryAttributes(atCharacterIndex: $0, effectiveRange: nil)[.foregroundColor] as? NSColor) }
        document.isMarkdownFormatted = true
        coordinator.updateMarkdownPresentation()
        for _ in 0..<200 {
            let colors = positions.map { layout.temporaryAttributes(atCharacterIndex: $0, effectiveRange: nil)[.foregroundColor] as? NSColor }
            if zip(colors, original).allSatisfy({ color, old in color != nil && color != old }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for (index, position) in positions.enumerated() {
            XCTAssertNotEqual(layout.temporaryAttributes(atCharacterIndex: position, effectiveRange: nil)[.foregroundColor] as? NSColor, original[index])
        }
        coordinator.scheduleHighlight(delay: 0)
        try await Task.sleep(for: .milliseconds(300))
        for (index, position) in positions.enumerated() {
            XCTAssertNotEqual(layout.temporaryAttributes(atCharacterIndex: position, effectiveRange: nil)[.foregroundColor] as? NSColor, original[index])
        }
        document.isMarkdownFormatted = false
        coordinator.updateMarkdownPresentation()
        for _ in 0..<100 {
            if positions.enumerated().allSatisfy({ index, position in
                (layout.temporaryAttributes(atCharacterIndex: position, effectiveRange: nil)[.foregroundColor] as? NSColor) == original[index]
            }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for (index, position) in positions.enumerated() {
            XCTAssertEqual(layout.temporaryAttributes(atCharacterIndex: position, effectiveRange: nil)[.foregroundColor] as? NSColor, original[index])
        }
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }
    func testSourceModeEnablesReadableStatisticsWithoutFormatting() async throws {
        _ = NSApplication.shared
        let source = "# 中文\n\n**hello** [world](https://example.com)"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let document = EditorDocument(text: source, language: .markdown)
        document.setOverride(false, for: .wordCount)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel() }
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(document.statistics)
        document.setOverride(true, for: .wordCount)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<100 {
            if document.statistics != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(document.statistics?.words, 4)
        XCTAssertEqual(document.statistics?.characters, source.count)
        XCTAssertEqual(storage.string, source)
        XCTAssertNil(layout.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)[.foregroundColor])
        XCTAssertFalse(document.isDirty)
        document.language = .plainText
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        document.language = .markdown
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<100 {
            if document.statistics?.words == 4 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(document.statistics?.words, 4)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testUnchangedMarkedTableCellRestoresReadableStatistics() async throws {
        _ = NSApplication.shared
        let source = "| A |\n|---|\n| one |"
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
        document.markSaved()
        let coordinator = EditorTextView.Coordinator(document: document)
        let (storage, layout, container) = makeLayout(source)
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
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); window.close() }
        coordinator.updateMarkdownPresentation()
        for _ in 0..<100 {
            if document.hasCurrentMarkdownReadableText && document.statistics != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(document.hasCurrentMarkdownReadableText)
        let range = (source as NSString).range(of: "one")
        XCTAssertTrue(coordinator.beginTableCell(range, frame: NSRect(x: 0, y: 0, width: 100, height: 30)))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("one", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertFalse(document.hasCurrentMarkdownReadableText)
        child.unmarkText()
        for _ in 0..<100 {
            if document.hasCurrentMarkdownReadableText && document.statistics != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(document.hasCurrentMarkdownReadableText)
        XCTAssertEqual(document.statistics?.words, 2)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testCodeFontUpdatesInlineAndBlockWithoutEditingSource() async throws {
        _ = NSApplication.shared
        let source = "`inline中文`\n\n```\nblock😀\n```\n\nnext"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let selection = NSRange(location: (source as NSString).length, length: 0)
        view.setSelectedRange(selection)
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let codeFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: layout.textFont.pointSize))
        layout.markdownCodeFont = codeFont
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let inline = (source as NSString).range(of: "inline中文").location
        let block = (source as NSString).range(of: "block😀").location
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            if (storage.attribute(.font, at: inline, effectiveRange: nil) as? NSFont)?.familyName == codeFont.familyName,
               (storage.attribute(.font, at: block, effectiveRange: nil) as? NSFont)?.familyName == codeFont.familyName { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        for location in [inline, block] {
            XCTAssertEqual((storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.familyName, codeFont.familyName)
        }
        layout.markdownCodeFont = nil
        controller.metricsChanged()
        let fallback = NSFont.monospacedSystemFont(ofSize: layout.textFont.pointSize, weight: .regular)
        for location in [inline, block] {
            XCTAssertEqual((storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.fontName, fallback.fontName)
        }
        XCTAssertEqual(storage.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
        withExtendedLifetime(scroll) {}
    }

    func testTableCodeFontUsesSelectionAndRestoresDefault() throws {
        let source = "| header |\n| --- |\n| `code中文` |"
        let cell = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first?.rows.last?.cells.first)
        let layout = FoldLayoutManager()
        let selected = try XCTUnwrap(NSFont(name: "TimesNewRomanPSMT", size: layout.textFont.pointSize))
        layout.markdownCodeFont = selected
        let rendered = layout.tableCellAttributedText(cell, text: source as NSString)
        let location = (rendered.string as NSString).range(of: "code中文").location
        XCTAssertNotEqual(location, NSNotFound)
        XCTAssertEqual((rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.familyName, selected.familyName)
        layout.markdownCodeFont = nil
        let restored = layout.tableCellAttributedText(cell, text: source as NSString)
        let fallback = NSFont.monospacedSystemFont(ofSize: layout.textFont.pointSize, weight: .regular)
        XCTAssertEqual((restored.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.fontName, fallback.fontName)
    }

    func testUnderlineAttributeRestoresInSourceMode() async throws {
        _ = NSApplication.shared
        let source = "<u>中文😀</u>\n\nnext"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let location = (source as NSString).range(of: "中文").location
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            if layout.temporaryAttributes(atCharacterIndex: location, effectiveRange: nil)[.underlineStyle] != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(layout.temporaryAttributes(atCharacterIndex: location, effectiveRange: nil)[.underlineStyle])
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(layout.temporaryAttributes(atCharacterIndex: location, effectiveRange: nil)[.underlineStyle])
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }
    func testInlineMarkersRevealOnlySelectedElements() async throws {
        _ = NSApplication.shared
        let source = "中文 😀 **one** and *two*\r\n\r\nend"
        let raw = source as NSString
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let first = raw.range(of: "**one**"), second = raw.range(of: "*two*")
        view.setSelectedRange(raw.range(of: "one"))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: second.location))
        view.setSelectedRange(raw.range(of: "two"))
        controller.selectionChanged()
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: second.location))
        view.setSelectedRange(raw.range(of: "and"))
        controller.selectionChanged()
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: second.location))
        view.setSelectedRange(NSRange(location: first.location, length: NSMaxRange(second) - first.location))
        controller.selectionChanged()
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: second.location))
        view.setSelectedRange(NSRange(location: first.location, length: NSMaxRange(raw.range(of: "end")) - first.location))
        controller.selectionChanged()
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: second.location))
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }

    func testInlineRevealHandlesNestedOwnersAndBoundaries() throws {
        _ = NSApplication.shared
        let source = "**outer *inner*** and `code`"
        let presentation = MarkdownPresentationParser.parse(source)
        let outer = try XCTUnwrap(presentation.spans.first { $0.kind == .strong })
        let inner = try XCTUnwrap(presentation.spans.first { $0.kind == .emphasis })
        let code = try XCTUnwrap(presentation.spans.first { $0.kind == .code })
        let outerMarker = try XCTUnwrap(outer.markerRanges.first), innerMarker = try XCTUnwrap(inner.markerRanges.first)
        let codeMarker = try XCTUnwrap(code.markerRanges.first)
        let (storage, layout, _) = makeLayout(source)
        let line = NSRange(location: 0, length: (source as NSString).length)
        layout.setMarkdownPresentation(presentation, revealedRange: line,
            inlineSelection: (source as NSString).range(of: "inner"))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: outerMarker.location))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: innerMarker.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: codeMarker.location))
        layout.updateMarkdownInlineSelection(NSRange(location: NSMaxRange(outer.range), length: 0))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: outerMarker.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: innerMarker.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: codeMarker.location))
        XCTAssertEqual(storage.string, source)
    }

    func testUnderlineTagsRevealWithoutChangingSource() {
        let source = "中文😀 <u>plain</u>"
        let (storage, layout, container) = makeLayout(source)
        let opening = (source as NSString).range(of: "<u>")
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        layout.ensureLayout(for: container)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: opening.location))
        layout.updateMarkdownRevealedRange((source as NSString).range(of: "plain"))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: opening.location))
        XCTAssertEqual(storage.string, source)
    }
    func testIndexBaselineAndFontRestoreInSourceMode() async throws {
        _ = NSApplication.shared
        let source = "H~2~O X^2^\n\nnext"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let sub = (source as NSString).range(of: "~2~").location + 1
        let sup = (source as NSString).range(of: "^2^").location + 1
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            if storage.attribute(.baselineOffset, at: sub, effectiveRange: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertLessThan((storage.attribute(.baselineOffset, at: sub, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertGreaterThan((storage.attribute(.baselineOffset, at: sup, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertLessThan((storage.attribute(.font, at: sub, effectiveRange: nil) as? NSFont)?.pointSize ?? layout.textFont.pointSize, layout.textFont.pointSize)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(storage.attribute(.baselineOffset, at: sub, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.baselineOffset, at: sup, effectiveRange: nil))
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }
    func testSubscriptAndSuperscriptMarkersReveal() {
        let source = "H~2~O X^2^"
        let (storage, layout, container) = makeLayout(source)
        let parsed = MarkdownPresentationParser.parse(source)
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        layout.ensureLayout(for: container)
        let sub = (source as NSString).range(of: "~2~"), sup = (source as NSString).range(of: "^2^")
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: sub.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: sup.location))
        layout.updateMarkdownRevealedRange(NSRange(location: 0, length: (source as NSString).length))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: sub.location))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: sup.location))
        XCTAssertEqual(storage.string, source)
    }
    func testAlertMarkerRevealsWithSelection() throws {
        let source = "> [!NOTE]\n> content\n\nnext"
        let (storage, layout, container) = makeLayout(source)
        let marker = (source as NSString).range(of: "[!NOTE]")
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: NSRange(location: (source as NSString).length, length: 0))
        layout.ensureLayout(for: container)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker.location))
        layout.updateMarkdownRevealedRange((source as NSString).range(of: "content"))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: marker.location))
        XCTAssertEqual(storage.string, source)
    }
    func testFrontMatterMarkersRevealWithoutChangingDocument() {
        let source = "---\ntitle: 中文😀\n---\n\n# Heading"
        let (storage, layout, container) = makeLayout(source)
        let result = MarkdownPresentationParser.parse(source)
        layout.setMarkdownPresentation(result, revealedRange: NSRange(location: (source as NSString).length, length: 0))
        layout.ensureLayout(for: container)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0))
        layout.updateMarkdownRevealedRange((source as NSString).range(of: "title"))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: 0))
        XCTAssertEqual(storage.string, source)
    }
    func testHighlightBackgroundRestoresAfterSourceMode() async throws {
        _ = NSApplication.shared
        let source = "==中文😀==\n\nnext"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        var background: Any?
        for _ in 0..<30 {
            layout.ensureLayout(forBoundingRect: view.visibleRect, in: container)
            background = layout.temporaryAttributes(atCharacterIndex: 2, effectiveRange: nil)[.backgroundColor]
            if background != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(background)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0))
        controller.restoreBackground(in: [NSRange(location: 2, length: 1)])
        XCTAssertEqual(layout.temporaryAttributes(atCharacterIndex: 2, effectiveRange: nil)[.backgroundColor] as? NSColor,
                       NSColor.systemYellow.withAlphaComponent(0.3))
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertNil(layout.temporaryAttributes(atCharacterIndex: 2, effectiveRange: nil)[.backgroundColor])
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
        withExtendedLifetime(scroll) {}
    }
    func testHighlightMarkersRevealWithoutChangingSource() {
        let source = "==中文😀=="
        let (storage, layout, container) = makeLayout(source)
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        layout.ensureLayout(for: container)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: (source as NSString).length - 1))
        layout.updateMarkdownRevealedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: 0))
        XCTAssertEqual(storage.string, source)
    }
    func testNativeTableGeometryFitsRowsAndPreservesSource() throws {
        let source = "| A | B |\n| --- | --- |\n| short | a long cell that wraps across several lines |"
        let table = try XCTUnwrap(MarkdownPresentationParser.parse(source).tables.first)
        let (storage, layout, _) = makeLayout(source)
        let wide = layout.markdownTableGeometry(table, text: storage.mutableString, width: 500)
        let narrow = layout.markdownTableGeometry(table, text: storage.mutableString, width: 120)
        XCTAssertEqual(wide.count, 4)
        XCTAssertEqual(narrow.count, 4)
        XCTAssertEqual(narrow[0].rect.maxX, narrow[1].rect.minX, accuracy: 0.001)
        XCTAssertEqual(narrow[2].rect.minY, narrow[0].rect.maxY, accuracy: 0.001)
        XCTAssertEqual(narrow[2].rect.height, narrow[3].rect.height, accuracy: 0.001)
        XCTAssertGreaterThan(narrow[3].rect.height, wide[3].rect.height)
        XCTAssertEqual(storage.string, source)
    }

    func testVerticalTOCAndListMarkerHitUsingPhysicalCoordinates() throws {
        _ = NSApplication.shared
        let source = "[toc]\n\n# 标题\n\n9. one\n1. two\n\nend"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        view.setLayoutOrientation(.vertical)
        let presentation = MarkdownPresentationParser.parse(source).numberingHeadings(true)
        let toc = try XCTUnwrap(presentation.tableOfContents.first)
        let marker = try XCTUnwrap(presentation.listMarkers.last)
        layout.setMarkdownPresentation(presentation, revealedRange: (source as NSString).range(of: "end"))
        layout.ensureLayout(for: container)
        let tocLine = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: toc.location), effectiveRange: nil)
        let tocPoint = NSPoint(x: tocLine.minX + container.lineFragmentPadding + 1, y: tocLine.minY + layout.editorLineHeight / 2)
        let clip = scroll.contentView
        let tocPhysical = clip.convert(NSPoint(x: tocPoint.x + view.textContainerOrigin.x, y: tocPoint.y + view.textContainerOrigin.y), from: view)
        let tocView = view.convert(tocPhysical, from: clip)
        let tocLocal = NSPoint(x: tocView.x - view.textContainerOrigin.x, y: tocView.y - view.textContainerOrigin.y)
        XCTAssertEqual(layout.markdownTOC(at: tocLocal, in: container)?.heading?.numberedTitle, "1. 标题")
        let glyphs = layout.glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
        let markerRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertGreaterThan(markerRect.width, 0)
        let physical = clip.convert(NSPoint(x: markerRect.midX + view.textContainerOrigin.x, y: markerRect.midY + view.textContainerOrigin.y), from: view)
        let local = view.convert(physical, from: clip)
        let hit = layout.characterIndex(for: NSPoint(x: local.x - view.textContainerOrigin.x, y: local.y - view.textContainerOrigin.y), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        XCTAssertGreaterThanOrEqual(hit, marker.range.location)
        XCTAssertLessThanOrEqual(hit, NSMaxRange(marker.range))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }

    func testTableOfContentsHeightHitTestingAndSourceReveal() throws {
        let source = "[toc]\n\n# First heading with a long title\n\n## Second"
        let (storage, layout, container) = makeLayout(source)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 2_000), textContainer: container)
        let presentation = MarkdownPresentationParser.parse(source)
        let toc = try XCTUnwrap(presentation.tableOfContents.first)
        layout.setMarkdownPresentation(presentation, revealedRange: nil)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: toc.location)
        let wide = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertGreaterThanOrEqual(wide.height, layout.editorLineHeight * 2)
        let hit = try XCTUnwrap(layout.markdownTOC(at: NSPoint(x: container.lineFragmentPadding + 1, y: wide.minY + layout.editorLineHeight / 2), in: container))
        XCTAssertEqual(hit.heading?.title, "First heading with a long title")
        container.containerSize = NSSize(width: 100, height: 2_000)
        layout.invalidateMarkdownLayout(in: toc)
        layout.ensureLayout(for: container)
        let narrow = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: toc.location), effectiveRange: nil)
        XCTAssertGreaterThan(narrow.height, wide.height)
        layout.updateMarkdownRevealedRange(toc)
        layout.ensureLayout(for: container)
        let revealed = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: toc.location), effectiveRange: nil)
        XCTAssertLessThan(revealed.height, narrow.height)
        XCTAssertNil(layout.markdownTOC(at: NSPoint(x: container.lineFragmentPadding + 1, y: revealed.midY), in: container))
        layout.updateMarkdownRevealedRange(nil)
        layout.setFoldedRange(toc)
        XCTAssertNil(layout.markdownTOC(at: NSPoint(x: container.lineFragmentPadding + 1, y: revealed.midY), in: container))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testTableOfContentsHitTestingDoesNotLayOutDistantMarkers() {
        let source = "start\n\n# Heading\n\n" + String(repeating: "paragraph\n\n", count: 10_000) + "[toc]"
        let (storage, layout, container) = makeLayout(source)
        layout.backgroundLayoutEnabled = false
        layout.allowsNonContiguousLayout = false
        container.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300_000), textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        scroll.documentView = view
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil,
                                       invalidating: NSRange(location: 0, length: 1))
        let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let before = layout.firstUnlaidCharacterIndex()
        XCTAssertLessThan(before, storage.length / 2)
        XCTAssertNil(layout.markdownTOC(at: NSPoint(x: visible.midX, y: visible.midY), in: container))
        XCTAssertLessThan(layout.firstUnlaidCharacterIndex(), storage.length / 2)
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(scroll) {}
    }
    private func makeLayout(_ source: String) -> (NSTextStorage, FoldLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: 2_000))
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    func testMarkersHaveNoWidthAndRevealWithoutChangingSource() {
        let source = "**bold**"
        let (storage, layout, container) = makeLayout(source)
        func width() -> CGFloat {
            layout.ensureLayout(for: container)
            return layout.boundingRect(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs), in: container).width
        }
        let originalWidth = width()
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        XCTAssertLessThan(width(), originalWidth)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: 2))
        layout.updateMarkdownRevealedRange(NSRange(location: 0, length: (source as NSString).length))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: 0))
        XCTAssertEqual(width(), originalWidth, accuracy: 0.5)
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(width(), originalWidth, accuracy: 0.5)
        XCTAssertEqual(storage.string, source)
    }

    func testIndentedAndQuotedHeadingsUseHeadingLineHeight() {
        for source in ["# Heading\nbody", "  # Heading\nbody", "> # Heading\n\nbody"] {
            let (storage, layout, container) = makeLayout(source)
            layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: NSRange(location: 0, length: 1))
            layout.ensureLayout(for: container)
            let heading = (source as NSString).range(of: "Heading")
            let body = (source as NSString).range(of: "body")
            let headingRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: heading.location), effectiveRange: nil)
            let bodyRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: body.location), effectiveRange: nil)
            XCTAssertGreaterThan(headingRect.height, bodyRect.height, source)
            XCTAssertGreaterThanOrEqual(bodyRect.minY, headingRect.maxY, source)
            XCTAssertEqual(storage.string, source)
        }
    }

    func testFoldingAndMarkerVisibilityAreIndependent() {
        let source = "**first**\nbody\n**last**"
        let (storage, layout, _) = makeLayout(source)
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        let body = (source as NSString).range(of: "body\n")
        layout.setFoldedRange(body)
        XCTAssertTrue(layout.isCharacterFolded(body.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: 0))
        layout.updateMarkdownRevealedRange(NSRange(location: 0, length: 9))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: 0))
        XCTAssertTrue(layout.isCharacterFolded(body.location))
        layout.setFoldedRange(nil)
        XCTAssertFalse(layout.isCharacterFolded(body.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: (source as NSString).range(of: "**last**").location))
        XCTAssertEqual(storage.string, source)
    }

    func testReturningToSourceAfterPartialResetRestoresOffscreenGlyphs() {
        let source = "**first**\n\n**last**"
        let (storage, layout, container) = makeLayout(source)
        let last = (source as NSString).range(of: "**last**")
        func lastWidth() -> CGFloat {
            layout.ensureLayout(for: container)
            return layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: last, actualCharacterRange: nil), in: container).width
        }
        let width = lastWidth()
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        XCTAssertLessThan(lastWidth(), width)
        layout.setMarkdownPresentation(nil, revealedRange: nil, invalidating: NSRange(location: 0, length: 9))
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertEqual(lastWidth(), width, accuracy: 0.5)
        XCTAssertEqual(storage.string, source)
    }
    func testPlainDetailsUsesEditorParagraphSettings() async throws {
        _ = NSApplication.shared
        let source = "<details><summary>Title</summary>Body text</details>\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 300, height: 2000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end", options: .backwards))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func button() -> NSButton? {
            view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.bezelStyle == .disclosure }
        }
        for _ in 0..<200 where button() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let disclosure = try XCTUnwrap(button()), details = try XCTUnwrap(disclosure.superview)
        disclosure.performClick(nil)
        layout.markdownTextAlignment = .right
        layout.markdownRightToLeft = true
        layout.editorLineSpacing = 9
        controller.metricsChanged()
        for text in ["Title", "Body text"] {
            let field = try XCTUnwrap(details.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == text })
            let style = try XCTUnwrap(field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.alignment, .right)
            XCTAssertEqual(style.baseWritingDirection, .rightToLeft)
            XCTAssertEqual(style.lineSpacing, 9)
        }
        XCTAssertEqual(disclosure.state, .on)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testHTMLBlockUpdatesWithEditorTextSettings() async throws {
        _ = NSApplication.shared
        let source = "<div><code>Sample</code></div>\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (_, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 300, height: 2000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end", options: .backwards))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func block() -> MarkdownHTMLBlockView? { view.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.first }
        for _ in 0..<200 where block() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let first = try XCTUnwrap(block())
        layout.markdownTextAlignment = .right
        layout.markdownRightToLeft = true
        layout.markdownCodeFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 18))
        controller.metricsChanged()
        let second = try XCTUnwrap(block())
        XCTAssertFalse(first === second)
        XCTAssertNil(first.superview)
        layout.editorLineSpacing += 3
        controller.metricsChanged()
        let third = try XCTUnwrap(block())
        XCTAssertFalse(second === third)
        XCTAssertNil(second.superview)
        XCTAssertEqual(view.string, source)
    }

    func testRichDetailsUsesNativeTextAndKeepsTransientOpenState() async throws {
        _ = NSApplication.shared
        let source = "<details open><summary><a href='relative.md'>More</a></summary><strong>Body 中文</strong></details>\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 300, height: 2000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end", options: .backwards))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        var link: String?
        var revision: UInt = 0
        controller.htmlBlockLink = { address, _ in link = address }
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        func button() -> NSButton? {
            view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.bezelStyle == .disclosure }
        }
        for _ in 0..<200 where button() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let disclosure = try XCTUnwrap(button()), detailsView = try XCTUnwrap(disclosure.superview)
        XCTAssertEqual(disclosure.state, .on)
        let summary = try XCTUnwrap(detailsView.subviews.compactMap { $0 as? MarkdownHTMLBlockView }.first { !$0.isHidden })
        func click(_ modifiers: NSEvent.ModifierFlags) throws {
            let point = summary.convert(NSPoint(x: 3, y: 8), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            summary.mouseDown(with: event)
        }
        try click([.command]); XCTAssertEqual(link, "relative.md")
        try click([]); XCTAssertEqual(disclosure.state, .off)
        controller.viewportChanged(); XCTAssertEqual(disclosure.state, .off)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30)); view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        disclosure.performClick(nil); XCTAssertEqual(disclosure.state, .off)
        child.unmarkText(); child.removeFromSuperview(); controller.compositionFinished(revision: 0)
        scroll.setFrameSize(NSSize(width: 200, height: 300)); view.setFrameSize(NSSize(width: 200, height: 300))
        controller.viewportChanged(); XCTAssertEqual(disclosure.state, .off)
        view.insertText("!", replacementRange: NSRange(location: (source as NSString).length, length: 0))
        revision = 1; controller.edited(revision: revision)
        for _ in 0..<200 where button()?.state != .on { try await Task.sleep(for: .milliseconds(20)) }
        let refreshed = try XCTUnwrap(button())
        XCTAssertEqual(refreshed.state, .on)
        let range = try XCTUnwrap(MarkdownPresentationParser.parse(source).detailsBlocks.first?.range)
        view.setSelectedRange(range); controller.selectionChanged()
        XCTAssertNil(detailsView.superview)
        XCTAssertEqual(storage.string, source + "!")
        view.undoManager?.undo()
        XCTAssertEqual(storage.string, source)
    }

    func testDetailsDisplaysAndRevealsSourceInVerticalLayout() async throws {
        _ = NSApplication.shared
        let source = "<details>\n<summary>More</summary>\nA longer body that wraps when the viewport becomes narrower.\n</details>\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 400, height: 2000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.allowsMagnification = true
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setLayoutOrientation(.vertical)
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func button() -> NSButton? {
            view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.bezelStyle == .disclosure }
        }
        for _ in 0..<200 where button() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let disclosure = try XCTUnwrap(button())
        let detailsView = try XCTUnwrap(disclosure.superview)
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).detailsBlocks.first)
        func assertGeometry() throws {
            layout.ensureLayout(for: container)
            let rect = try XCTUnwrap(layout.markdownMediaRect(for: block.range, in: container))
            let expected = scroll.contentView.convert(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
            let actual = scroll.contentView.convert(detailsView.bounds, from: detailsView)
            XCTAssertGreaterThan(actual.width, 0); XCTAssertGreaterThan(actual.height, 0)
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 1)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 1)
            XCTAssertEqual(actual.width, expected.width, accuracy: 1)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1)
        }
        try assertGeometry()
        disclosure.performClick(nil)
        XCTAssertEqual(disclosure.state, .on)
        try assertGeometry()
        XCTAssertFalse(view.undoManager?.canUndo ?? false)
        let ending = (source as NSString).range(of: "end", options: .backwards)
        view.setMarkedText("end", selectedRange: NSRange(location: ending.length, length: 0), replacementRange: ending)
        XCTAssertTrue(view.hasMarkedText())
        let parentMarkedFrame = detailsView.frame
        disclosure.performClick(nil); controller.viewportChanged()
        XCTAssertEqual(disclosure.state, .on)
        XCTAssertEqual(detailsView.frame, parentMarkedFrame)
        XCTAssertEqual(storage.string, source)
        view.unmarkText(); controller.compositionFinished(revision: 0)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        let markedFrame = detailsView.frame
        disclosure.performClick(nil)
        controller.viewportChanged()
        XCTAssertEqual(disclosure.state, .on)
        XCTAssertEqual(detailsView.frame, markedFrame)
        child.unmarkText(); child.removeFromSuperview()
        controller.compositionFinished(revision: 0)
        view.setLayoutOrientation(.horizontal); controller.viewportChanged()
        XCTAssertEqual(disclosure.state, .on)
        view.setLayoutOrientation(.vertical)
        scroll.setFrameSize(NSSize(width: 250, height: 400)); view.setFrameSize(NSSize(width: 250, height: 400))
        scroll.magnification = 1.5; controller.viewportChanged()
        XCTAssertEqual(disclosure.state, .on)
        try assertGeometry()
        view.setSelectedRange(block.range); controller.selectionChanged()
        XCTAssertNil(detailsView.superview)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testDetailsKeepsStateAcrossSettingsAndDefersMarkedInput() async throws {
        _ = NSApplication.shared
        let source = "# Heading\n\n<details>\n<summary>More</summary>\nA longer body of text that wraps when the editor becomes narrower.\n</details>\n\nend"
        let document = EditorDocument(text: source, language: .markdown)
        let (storage, layout, container) = makeLayout(source)
        container.containerSize = NSSize(width: 300, height: 2000)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll; window.makeKeyAndOrderFront(nil)
        view.setSelectedRange((source as NSString).range(of: "end"))
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        defer { controller.cancel(); window.close(); withExtendedLifetime(scroll) {} }
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        func button() -> NSButton? {
            view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.bezelStyle == .disclosure }
        }
        for _ in 0..<200 where button() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let disclosure = try XCTUnwrap(button())
        let detailsView = try XCTUnwrap(disclosure.superview)
        let collapsedHeight = detailsView.frame.height
        disclosure.performClick(nil)
        XCTAssertEqual(disclosure.state, .on)
        XCTAssertGreaterThan(detailsView.frame.height, collapsedHeight)
        controller.setUppercaseHeadingLevels([1])
        for _ in 0..<200 where controller.navigationPresentation(document: document, revision: 0)?.headings.first?.uppercaseRuns == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.navigationPresentation(document: document, revision: 0)?.headings.first?.uppercaseRuns)
        disclosure.performClick(nil)
        XCTAssertEqual(disclosure.state, .off)
        let child = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        view.addSubview(child)
        child.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(child.hasMarkedText())
        disclosure.performClick(nil)
        XCTAssertEqual(disclosure.state, .off)
        child.unmarkText(); child.removeFromSuperview()
        controller.compositionFinished(revision: 0)
        disclosure.performClick(nil)
        XCTAssertEqual(disclosure.state, .on)
        let wideHeight = detailsView.frame.height
        scroll.setFrameSize(NSSize(width: 150, height: 300)); view.setFrameSize(NSSize(width: 150, height: 300))
        container.containerSize = NSSize(width: 150, height: 2000); controller.viewportChanged()
        XCTAssertGreaterThan(detailsView.frame.height, wideHeight)
        XCTAssertEqual(disclosure.state, .on)
        view.setSelectedRange((source as NSString).range(of: "<details>")); controller.selectionChanged()
        XCTAssertNil(detailsView.superview)
        XCTAssertEqual(storage.string, source)
        XCTAssertFalse(document.isDirty)
    }

    func testNativeImageReservesSpaceAndRevealRestoresSource() {
        let source = "before\n\n![图](a.png)\n\nafter"
        let (storage, layout, container) = makeLayout(source)
        let range = (source as NSString).range(of: "![图](a.png)")
        let after = (source as NSString).range(of: "after")
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        layout.ensureLayout(for: container)
        let original = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: after.location), effectiveRange: nil).minY
        layout.setMarkdownImage(NSImage(size: NSSize(width: 120, height: 100)), for: range)
        layout.ensureLayout(for: container)
        let shifted = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: after.location), effectiveRange: nil).minY
        XCTAssertGreaterThan(shifted, original)
        layout.updateMarkdownRevealedRange(range)
        layout.ensureLayout(for: container)
        let restored = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: after.location), effectiveRange: nil).minY
        XCTAssertEqual(restored, original, accuracy: 1)
        XCTAssertEqual(storage.string, source)
    }
}
