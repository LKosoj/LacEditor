import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownOutlineTests: XCTestCase {
    func testHeadingNumbersPreserveTitlesAndResetLowerLevels() {
        let levels = [2, 1, 3, 3, 2, 3, 1]
        let headings = levels.enumerated().map { index, level in
            MarkdownHeading(level: level, title: "标题 \(index)", range: NSRange(location: index * 10, length: 5))
        }
        let numbered = MarkdownHeadingNumbering.applying(to: headings, enabled: true)
        XCTAssertEqual(numbered.map(\.number), ["0.1. ", "1. ", "1.0.1. ", "1.0.2. ", "1.1. ", "1.1.1. ", "2. "])
        XCTAssertEqual(numbered.map(\.title), headings.map(\.title))
        XCTAssertEqual(numbered.map(\.range), headings.map(\.range))
        XCTAssertEqual(MarkdownHeadingNumbering.applying(to: numbered, enabled: false).map(\.number), Array(repeating: nil, count: levels.count))
        let emoji = MarkdownHeading(level: 1, title: ":smile:", range: NSRange(location: 0, length: 7),
                                    emoji: [.init(range: NSRange(location: 0, length: 7), name: "smile")])
        let resolved = MarkdownHeadingNumbering.applying(to: [emoji], enabled: true)[0].resolvingEmoji(["smile": "😄"])
        XCTAssertEqual(resolved.numberedTitle, "1. 😄")
        XCTAssertTrue(resolved.sameSource(as: emoji))
    }

    func testHeadingNumberingExcludesFootnoteDefinitions() {
        for source in ["[^1]:\n    # Foot\n\n# Normal\n\nref [^1]\n",
                       "# Normal\n\nref [^1]\n\n[^1]:\n    # Foot\n"] {
            let numbered = MarkdownPresentationParser.parse(source).numberingHeadings(true)
            XCTAssertEqual(numbered.headings.map(\.title), ["Normal"])
            XCTAssertEqual(numbered.headings.map(\.number), ["1. "])
        }
    }

    func testHeadingUppercaseProjectionMapsExpandedAndComposedCharacters() throws {
        let source = "Straße iıİ e\u{301} 👩‍💻"
        let projection = MarkdownHeadingUppercaseProjection(source)
        XCTAssertEqual(projection.text, "STRASSE IIİ E\u{301} 👩‍💻")
        let original = source as NSString
        let display = projection.text as NSString
        let sharpS = original.range(of: "ß")
        let expanded = display.range(of: "SS")
        XCTAssertEqual(projection.sourcePosition(for: expanded.location), sharpS.location)
        XCTAssertEqual(projection.sourcePosition(for: expanded.location + 1), NSMaxRange(sharpS))
        let accent = original.range(of: "e\u{301}")
        let renderedAccent = display.range(of: "E\u{301}")
        XCTAssertEqual(projection.sourcePosition(for: renderedAccent.location), accent.location)
        XCTAssertEqual(projection.sourcePosition(for: renderedAccent.location, fraction: 0.75), NSMaxRange(accent))
        XCTAssertEqual(projection.sourcePosition(for: NSMaxRange(renderedAccent)), NSMaxRange(accent))
        let emoji = original.range(of: "👩‍💻")
        let renderedEmoji = display.range(of: "👩‍💻")
        XCTAssertEqual(projection.sourcePosition(for: renderedEmoji.location), emoji.location)
        XCTAssertEqual(projection.sourcePosition(for: renderedEmoji.location, fraction: 0.75), NSMaxRange(emoji))
        XCTAssertEqual(projection.sourcePosition(for: NSMaxRange(renderedEmoji)), NSMaxRange(emoji))
        XCTAssertNil(projection.sourcePosition(for: display.length + 1))
    }

    func testUppercaseProjectionMapsConfirmedPiecesAndSourceGaps() throws {
        let pieces: [MarkdownReadableText.Piece] = [
            .init(sourceRange: NSRange(location: 102, length: 1), text: "ß", matchesSource: true),
            .init(sourceRange: NSRange(location: 105, length: 5), text: "&", matchesSource: false),
            .init(sourceRange: NSRange(location: 111, length: 2), text: "e\u{301}", matchesSource: true)
        ]
        let projection = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: NSRange(location: 100, length: 20)))
        XCTAssertEqual(projection.text, "SS&E\u{301}")
        XCTAssertEqual(projection.sourcePosition(for: 0), 2)
        XCTAssertEqual(projection.sourcePosition(for: 1), 3)
        XCTAssertEqual(projection.sourcePosition(for: 2), 5)
        XCTAssertEqual(projection.sourcePosition(for: 2, fraction: 0.75), 10)
        XCTAssertEqual(projection.sourcePosition(for: 3), 11)
        XCTAssertEqual(projection.sourcePosition(for: 5), 13)
        XCTAssertEqual(projection.displayRange(for: NSRange(location: 2, length: 1)), NSRange(location: 0, length: 2))
        XCTAssertEqual(projection.displayRange(for: NSRange(location: 5, length: 5)), NSRange(location: 2, length: 1))
        XCTAssertNil(projection.displayRange(for: NSRange(location: 6, length: 3)))
        let splitAccent: [MarkdownReadableText.Piece] = [
            .init(sourceRange: NSRange(location: 0, length: 1), text: "e", matchesSource: true),
            .init(sourceRange: NSRange(location: 2, length: 1), text: "\u{301}", matchesSource: true)
        ]
        let accent = try XCTUnwrap(MarkdownHeadingUppercaseProjection(pieces: splitAccent, sourceRange: NSRange(location: 0, length: 3)))
        XCTAssertEqual(accent.text, "E\u{301}")
        XCTAssertEqual(accent.sourcePosition(for: 0, fraction: 0.25), 0)
        XCTAssertEqual(accent.sourcePosition(for: 0, fraction: 0.75), 3)
        XCTAssertEqual(accent.displayRange(for: NSRange(location: 0, length: 1)), NSRange(location: 0, length: 1))
        XCTAssertEqual(accent.displayRange(for: NSRange(location: 2, length: 1)), NSRange(location: 1, length: 1))
        XCTAssertNil(MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: NSRange(location: 105, length: 5)))
        let run = MarkdownHeading.UppercaseRun(pieces: pieces, styles: [.strong, .link])
        let heading = MarkdownHeading(level: 1, title: "ß&e\u{301}", range: NSRange(location: 100, length: 20), uppercaseRuns: [run])
        let numbered = MarkdownHeadingNumbering.applying(to: [heading], enabled: true)[0].resolvingEmoji([:])
        XCTAssertEqual(numbered.uppercaseRuns, [run])
    }
    func testNavigationRejectsStaleAndOtherDocumentHeadings() {
        let suite = "MarkdownOutlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "\n\n# Title", language: .markdown)
        let other = EditorDocument(text: "# Other", language: .markdown)
        let state = AppState(initialDocuments: [document, other], recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        state.selectedDocumentID = document.id
        let heading = MarkdownHeading(level: 1, title: "Title", range: NSRange(location: 2, length: 7))
        document.markdownHeadings = [heading]
        document.isMarkdownOutlineCurrent = true
        state.revealMarkdownHeading(heading, in: document)
        XCTAssertEqual(document.selectionRange, NSRange(location: 2, length: 0))
        document.selectionRange = NSRange(location: 0, length: 0)
        document.markdownHeadings = [MarkdownHeading(level: 1, title: "Title", range: heading.range, displayTitle: "Title 😄")]
        state.revealMarkdownHeading(heading, in: document)
        XCTAssertEqual(document.selectionRange, NSRange(location: 2, length: 0))
        document.selectionRange = NSRange(location: 0, length: 0)
        document.isMarkdownOutlineCurrent = false
        state.revealMarkdownHeading(heading, in: document)
        XCTAssertEqual(document.selectionRange.location, 0)
        document.isMarkdownOutlineCurrent = true
        state.selectedDocumentID = other.id
        state.revealMarkdownHeading(heading, in: document)
        XCTAssertEqual(document.selectionRange.location, 0)
        XCTAssertEqual(other.selectionRange.location, 0)
    }

    func testOutlineInSourceModeUpdatesAfterEditing() async throws {
        _ = NSApplication.shared
        let source = "# 中文 😀\n\nText"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
        view.font = lacEditorFont(size: 14)
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        controller.update(document: document, enabled: false, outlineVisible: true, isActive: true, revision: revision, currentRevision: { revision })
        let deadline = Date().addingTimeInterval(2)
        while !document.isMarkdownOutlineCurrent && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(document.markdownHeadings.map(\.title), ["中文 😀"])
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        XCTAssertEqual(view.string, source)
        let font = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, layout.textFont.pointSize)
        controller.update(document: document, enabled: true, outlineVisible: true, isActive: true, revision: revision, currentRevision: { revision })
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
        XCTAssertEqual(document.markdownHeadings.map(\.title), ["中文 😀"])
        controller.update(document: document, enabled: false, outlineVisible: true, isActive: true, revision: revision, currentRevision: { revision })
        XCTAssertEqual(view.string, source)

        let edit = NSRange(location: (source as NSString).length, length: 0)
        let addition = "\n\n## Next"
        controller.beforeEdit(range: edit, replacementLength: (addition as NSString).length)
        XCTAssertFalse(document.isMarkdownOutlineCurrent)
        storage.replaceCharacters(in: edit, with: addition)
        revision += 1
        controller.edited(revision: revision)
        let updatedDeadline = Date().addingTimeInterval(2)
        while !document.isMarkdownOutlineCurrent && Date() < updatedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(document.markdownHeadings.map(\.title), ["中文 😀", "Next"])
        XCTAssertEqual(view.string, source + addition)
    }
    func testExternalTextReplacementInvalidatesOutlineImmediately() {
        let document = EditorDocument(text: "# Old", language: .markdown)
        document.markdownHeadings = [MarkdownHeading(level: 1, title: "Old", range: NSRange(location: 0, length: 5))]
        document.isMarkdownOutlineCurrent = true
        document.text = "# New"
        XCTAssertFalse(document.isMarkdownOutlineCurrent)
    }

    func testInactiveOutlineWaitsUntilActivation() async throws {
        _ = NSApplication.shared
        let storage = NSTextStorage(string: "# Heading")
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let document = EditorDocument(text: "# Heading", language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        controller.update(document: document, enabled: false, outlineVisible: true, isActive: false, revision: 0, currentRevision: { 0 })
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(document.isMarkdownOutlineCurrent)
        controller.update(document: document, enabled: false, outlineVisible: true, isActive: true, revision: 0, currentRevision: { 0 })
        let deadline = Date().addingTimeInterval(2)
        while !document.isMarkdownOutlineCurrent && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(document.markdownHeadings.map(\.title), ["Heading"])
        XCTAssertTrue(document.isMarkdownOutlineCurrent)
    }

}
