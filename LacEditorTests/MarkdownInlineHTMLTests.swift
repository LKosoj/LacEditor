import AppKit
import cmark_gfm
import Foundation
import XCTest
@testable import LacEditor

final class MarkdownInlineHTMLTests: XCTestCase {
    func testPairRejectsSourceThatDoesNotMatchParsedHTML() throws {
        let source = "before <u>text</u> after"
        let result = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, _, _ -> Bool in
            guard let paragraph = cmark_node_first_child(root) else { return false }
            var nodes = Set<OpaquePointer>(), child = cmark_node_first_child(paragraph)
            while let current = child {
                if cmark_node_get_type(current) == CMARK_NODE_HTML_INLINE { nodes.insert(current) }
                child = cmark_node_next(current)
            }
            let mapping = MarkdownPresentationParser.Source(source, root: root)
            let changed = source.replacingOccurrences(of: "<u>", with: "<x>") as NSString
            return MarkdownPresentationParser.inlineHTMLPairs(in: paragraph, confirmed: nodes, source: mapping, text: changed).isEmpty
        })
        XCTAssertTrue(result)
    }
    func testConfirmedPairsAndNestedMarkdownKeepSourceRanges() {
        let source = "😀 <strong>bold <em>中文</em><u>underline</u></strong> <b>one</b> <i>two</i> <s>three</s> <del>four</del> <mark>five</mark> <sub>six</sub> <sup>seven</sup>\r\n"
        let raw = source as NSString
        let presentation = MarkdownPresentationParser.parse(source)
        for (kind, marker) in [(MarkdownPresentationKind.strong, "<strong>"), (.strong, "<b>"), (.emphasis, "<em>"),
                               (.emphasis, "<i>"), (.underline, "<u>"), (.strikethrough, "<s>"), (.strikethrough, "<del>"),
                               (.highlight, "<mark>"), (.subscriptText, "<sub>"), (.superscriptText, "<sup>")] {
            let expected = raw.range(of: marker)
            XCTAssertTrue(presentation.spans.contains { $0.kind == kind && $0.markerRanges.contains(expected) }, marker)
        }
    }

    func testKeyboardPairsKeepTheirSemanticKindAcrossFormatting() throws {
        let source = "<kbd>Ctrl</kbd>+<kbd>F9</kbd>\n\n# <kbd>中文😀</kbd>\n\n**<kbd>bold</kbd>** [<kbd>link</kbd>](https://example.invalid)"
        let parsed = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeUppercaseRuns: true)
        let keyboards = parsed.spans.filter { $0.kind == .keyboard }
        XCTAssertEqual(keyboards.count, 5)
        let raw = source as NSString
        for keyboard in keyboards {
            XCTAssertEqual(keyboard.markerRanges.map { raw.substring(with: $0) }, ["<kbd>", "</kbd>"])
        }
        XCTAssertTrue(try XCTUnwrap(parsed.headings.first?.uppercaseRuns).contains { $0.styles.contains(.keyboard) })
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertTrue(page.body.contains("<kbd>Ctrl</kbd>+<kbd>F9</kbd>"))
        XCTAssertTrue(page.body.contains("<strong><kbd>bold</kbd></strong>"))
        XCTAssertTrue(page.body.contains("<kbd>link</kbd></a>"))
        XCTAssertTrue(page.html.contains("code, kbd"))
    }

    func testKeyboardRejectsAttributesUnmatchedAndInertSource() {
        for source in ["<kbd title='x'>key</kbd>", "<kbd>unclosed", "<script><kbd>hidden</kbd></script>",
                       "<template><kbd>hidden</kbd></template>", "`<kbd>code</kbd>`"] {
            XCTAssertFalse(MarkdownPresentationParser.parse(source).spans.contains { $0.kind == .keyboard }, source)
        }
    }

    @MainActor
    func testKeyboardRevealKeepsItsNeighborFormattedWithoutChangingText() {
        _ = NSApplication.shared
        let source = "<kbd>Ctrl</kbd>+<kbd>F9</kbd>"
        let raw = source as NSString
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source)
        let first = raw.range(of: "<kbd>"), second = raw.range(of: "<kbd>", options: .backwards)
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: second.location))
        layout.updateMarkdownInlineSelection(raw.range(of: "Ctrl"))
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: first.location))
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: second.location))
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: second.location))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }

    func testUnsafeUnmatchedAndInertTagsRemainSource() {
        let source = "<strong title='x'>unsafe</strong> <em>unclosed\n\n<script><strong>script</strong></script>\n\n<template><b>inert</b></template>"
        let raw = source as NSString
        let presentation = MarkdownPresentationParser.parse(source)
        for marker in ["<strong title='x'>", "<em>", "<strong>script", "<b>inert"] {
            let range = raw.range(of: marker)
            XCTAssertFalse(presentation.spans.contains { span in span.markerRanges.contains { NSIntersectionRange($0, range).length > 0 } }, marker)
        }
    }

    func testPairsInsideMarkdownStylesHeadingsAndLinks() {
        let source = "# <b>heading</b>\n\n**<em>nested</em>** [<strong>link</strong>](https://example.invalid)"
        let raw = source as NSString
        let presentation = MarkdownPresentationParser.parse(source)
        for (kind, marker) in [(MarkdownPresentationKind.strong, "<b>"), (.emphasis, "<em>"), (.strong, "<strong>")] {
            let expected = raw.range(of: marker)
            XCTAssertTrue(presentation.spans.contains { $0.kind == kind && $0.markerRanges.contains(expected) }, marker)
        }
    }

    @MainActor
    func testConfirmedMarkersRevealSourceWithoutEditingIt() {
        _ = NSApplication.shared
        let source = "before\n\n<strong>中文 <em>bold</em></strong>\n\nafter"
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        let parsed = MarkdownPresentationParser.parse(source)
        let marker = (source as NSString).range(of: "<strong>")
        layout.setMarkdownPresentation(parsed, revealedRange: nil)
        XCTAssertTrue(layout.isMarkdownMarkerHidden(at: marker.location))
        layout.updateMarkdownRevealedRange(marker)
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: marker.location))
        layout.setMarkdownPresentation(nil, revealedRange: nil)
        XCTAssertFalse(layout.isMarkdownMarkerHidden(at: marker.location))
        XCTAssertEqual(storage.string, source)
        withExtendedLifetime(view) {}
    }
}
