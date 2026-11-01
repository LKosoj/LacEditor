import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class InvisibleCharactersTests: XCTestCase {
    private func marks(_ text: String, _ range: NSRange? = nil) -> [(index: Int, symbol: String)] {
        let string = text as NSString
        return InvisibleCharacters.marks(in: string, range: range ?? NSRange(location: 0, length: string.length))
    }

    func testMarksSpaceTabNoBreakSpaceAndNewline() {
        let result = marks("a b\tc\u{00A0}d\n")
        XCTAssertEqual(result.map(\.index), [1, 3, 5, 7])
        XCTAssertEqual(result.map(\.symbol), ["·", "→", "°", "¶"])
    }

    func testCRLFGivesOneMark() {
        let pair = marks("a\r\nb")
        XCTAssertEqual(pair.map(\.index), [1])
        XCTAssertEqual(pair.map(\.symbol), ["¶"])
        XCTAssertTrue(marks("a\r\nb", NSRange(location: 2, length: 2)).isEmpty)
        XCTAssertEqual(marks("\r").map(\.index), [0])
        XCTAssertEqual(marks("\n").map(\.index), [0])
    }

    func testUnicodeLineSeparators() {
        XCTAssertEqual(marks("a\u{2028}b\u{2029}").map(\.symbol), ["¶", "¶"])
        XCTAssertTrue(marks("\u{0085}\u{3000}\u{200B}\u{202F}").isEmpty)
    }

    func testIndexesAreUTF16() {
        let text = "😀 中 x"
        XCTAssertEqual(marks(text).map(\.index), [2, 4])
        XCTAssertEqual(marks(text, NSRange(location: 3, length: 3)).map(\.index), [4])
    }

    func testRangeIsClampedAndEmptyInputsAreSafe() {
        XCTAssertTrue(marks("").isEmpty)
        XCTAssertTrue(marks("a b", NSRange(location: 1, length: 0)).isEmpty)
        XCTAssertTrue(marks("a b", NSRange(location: 10, length: 5)).isEmpty)
        XCTAssertEqual(marks("a b", NSRange(location: 0, length: 100)).map(\.index), [1])
    }

    func testSettingDefaultsToOffAndPersists() throws {
        let suite = "LacEditorInvisibles.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.showsInvisibles)
        XCTAssertNil(defaults.object(forKey: "isShowsInvisibles"))
        let lineNumbers = preferences.lineNumbersVisible
        preferences.showsInvisibles = true
        XCTAssertEqual(defaults.object(forKey: "isShowsInvisibles") as? Bool, true)
        XCTAssertTrue(AppPreferences(defaults: defaults).showsInvisibles)
        XCTAssertEqual(AppPreferences(defaults: defaults).lineNumbersVisible, lineNumbers)
    }

    func testShowsInvisiblesRule() {
        XCTAssertFalse(EditorTextView.showsInvisibles(setting: false, language: .plainText, isMarkdownFormatted: false))
        XCTAssertFalse(EditorTextView.showsInvisibles(setting: true, language: .markdown, isMarkdownFormatted: true))
        XCTAssertTrue(EditorTextView.showsInvisibles(setting: true, language: .markdown, isMarkdownFormatted: false))
        XCTAssertTrue(EditorTextView.showsInvisibles(setting: true, language: .json, isMarkdownFormatted: true))
        let document = EditorDocument(text: "a b", language: .markdown)
        document.isMarkdownFormatted = false
        document.setReadingMode(true)
        XCTAssertFalse(EditorTextView.showsInvisibles(setting: true, language: document.language, isMarkdownFormatted: document.isMarkdownFormatted))
        document.setReadingMode(false)
        XCTAssertTrue(EditorTextView.showsInvisibles(setting: true, language: document.language, isMarkdownFormatted: document.isMarkdownFormatted))
    }

    private func makeLayout(_ text: String) -> (NSTextStorage, FoldLayoutManager, NSTextContainer, NSTextView) {
        _ = NSApplication.shared
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), textContainer: container)
        layout.ensureLayout(for: container)
        return (storage, layout, container, view)
    }

    private func pixels(_ layout: FoldLayoutManager, _ container: NSTextContainer) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    func testToggleDoesNotChangeTextOrLayout() {
        let document = EditorDocument(text: "a b\tc\n", language: .plainText)
        let (storage, layout, container, _) = makeLayout(document.text)
        let before = layout.usedRect(for: container)
        layout.showsInvisibles = true
        XCTAssertEqual(layout.usedRect(for: container), before)
        layout.showsInvisibles = false
        XCTAssertEqual(layout.usedRect(for: container), before)
        XCTAssertEqual(storage.string, "a b\tc\n")
        XCTAssertEqual(document.text, "a b\tc\n")
        XCTAssertFalse(document.isDirty)
    }

    func testDrawingMarksOnlyUnfoldedMissingMarkedText() throws {
        let (_, layout, container, view) = makeLayout("a b")
        let plain = try pixels(layout, container)
        layout.showsInvisibles = true
        let shown = try pixels(layout, container)
        XCTAssertNotEqual(shown, plain)
        layout.setFoldedRange(NSRange(location: 1, length: 1))
        let folded = try pixels(layout, container)
        layout.showsInvisibles = false
        let foldedOff = try pixels(layout, container)
        XCTAssertEqual(folded, foldedOff)
        layout.setFoldedRange(nil)
        layout.showsInvisibles = true
        view.setMarkedText(" ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 1))
        XCTAssertTrue(view.hasMarkedText())
        let marked = try pixels(layout, container)
        layout.showsInvisibles = false
        XCTAssertEqual(marked, try pixels(layout, container))
    }
}
