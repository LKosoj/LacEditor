import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownOutlineTests: XCTestCase {
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
