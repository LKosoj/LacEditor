import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownLayoutTests: XCTestCase {
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
}
