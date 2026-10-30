import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class ReadingModeTests: XCTestCase {
    private func editor(_ source: String, language: EditorLanguage = .markdown) -> (EditorDocument, EditorTextView.Coordinator, LacTextView, NSWindow) {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: language)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source, attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.isVerticallyResizable = true
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
        coordinator.updateActivity(true)
        window.makeFirstResponder(view)
        return (document, coordinator, view, window)
    }

    private func appState(_ document: EditorDocument, suite: String) throws -> (AppState, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let state = AppState(
            initialDocument: document,
            recentFiles: RecentFilesStore(defaults: defaults),
            preferences: AppPreferences(defaults: defaults)
        )
        return (state, defaults)
    }

    func testEnteringRestoresMarkdownPresentation() {
        for initial in [false, true] {
            let document = EditorDocument(text: "# a", language: .markdown)
            document.isMarkdownFormatted = initial
            let revision = document.textRevision
            document.setReadingMode(true)
            XCTAssertTrue(document.isReadingMode)
            XCTAssertTrue(document.isMarkdownFormatted)
            document.setReadingMode(false)
            XCTAssertFalse(document.isReadingMode)
            XCTAssertEqual(document.isMarkdownFormatted, initial)
            XCTAssertEqual(document.text, "# a")
            XCTAssertEqual(document.textRevision, revision)
            XCTAssertFalse(document.isDirty)
        }
    }

    func testNonMarkdownKeepsPresentationFlag() {
        let document = EditorDocument(text: "{}", language: .json)
        document.setReadingMode(true)
        XCTAssertTrue(document.isReadingMode)
        XCTAssertFalse(document.isMarkdownFormatted)
        document.setReadingMode(false)
        XCTAssertFalse(document.isReadingMode)
        XCTAssertFalse(document.isMarkdownFormatted)
    }

    func testRepeatedSetIsIdempotent() {
        let document = EditorDocument(text: "a", language: .markdown)
        document.setReadingMode(true)
        document.setReadingMode(true)
        document.setReadingMode(false)
        XCTAssertFalse(document.isMarkdownFormatted)
    }

    func testToggleIsPerDocument() throws {
        let first = EditorDocument(text: "a", language: .markdown)
        let second = EditorDocument(text: "b", language: .markdown)
        let (state, _) = try appState(first, suite: "LacEditorReading.\(UUID())")
                state.documents.append(second)
        state.selectedDocumentID = first.id
        state.toggleReadingMode()
        XCTAssertTrue(first.isReadingMode)
        XCTAssertFalse(second.isReadingMode)
        state.toggleReadingMode()
        XCTAssertFalse(first.isReadingMode)
        first.ioState = .saving
        state.toggleReadingMode()
        XCTAssertFalse(first.isReadingMode)
    }

    func testReadingModeChangeNotifiesAppState() throws {
        let document = EditorDocument(text: "a", language: .markdown)
        let (state, _) = try appState(document, suite: "LacEditorReading.\(UUID())")
        var changes = 0
        let token = state.objectWillChange.sink { changes += 1 }
        defer { token.cancel() }
        document.setReadingMode(true)
        XCTAssertGreaterThan(changes, 0)
    }

    func testRangeReplacementIsRefused() {
        let (document, coordinator, view, window) = editor("abc")
        defer { window.close(); _ = coordinator }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        let editorRevision = extraction.result?.editorRevision ?? 0
        let request = { EditorRangeReplacementRequest(
            documentID: document.id, range: NSRange(location: 0, length: 1), originalText: "a",
            replacementText: "z", expectedEditorRevision: editorRevision, actionName: "t"
        ) }
        document.setReadingMode(true)
        view.isEditable = false
        let refused = request()
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: refused)
        XCTAssertFalse(refused.wasHandled)
        XCTAssertEqual(refused.failureMessage, L10n.tr("阅读模式下无法修改"))
        XCTAssertEqual(view.string, "abc")
        document.setReadingMode(false)
        view.isEditable = true
        let accepted = request()
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: accepted)
        XCTAssertTrue(accepted.wasHandled)
        XCTAssertEqual(view.string, "zbc")
    }

    func testLineEditingIsRefused() {
        let (document, coordinator, view, window) = editor("abc")
        defer { window.close(); _ = coordinator }
        document.setReadingMode(true)
        view.isEditable = false
        view.setSelectedRange(NSRange(location: 0, length: 0))
        NotificationCenter.default.post(
            name: EditorCommandNotification.editLines,
            object: LineEditingRequest(documentID: document.id, command: .duplicate)
        )
        XCTAssertEqual(view.string, "abc")
    }

    func testUndoRedoNotificationsAreIgnored() {
        let (document, coordinator, view, window) = editor("abc")
        defer { window.close(); _ = coordinator }
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("d", replacementRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(view.string, "abcd")
        document.setReadingMode(true)
        NotificationCenter.default.post(name: EditorCommandNotification.undo, object: document.id)
        XCTAssertEqual(view.string, "abcd")
        document.setReadingMode(false)
        NotificationCenter.default.post(name: EditorCommandNotification.undo, object: document.id)
        XCTAssertEqual(view.string, "abc")
    }

    func testValidateUserInterfaceItemBlocksUndoWhenReadOnly() {
        let (_, coordinator, view, window) = editor("abc")
        defer { window.close(); _ = coordinator }
        view.isEditable = false
        let item = NSMenuItem(title: "", action: Selector(("undo:")), keyEquivalent: "")
        XCTAssertFalse(view.validateUserInterfaceItem(item))
    }

    func testFindReplaceDoesNotFallBackToModel() throws {
        let document = EditorDocument(text: "aaa", language: .markdown)
        let (state, _) = try appState(document, suite: "LacEditorReading.\(UUID())")
        state.findReplace.query = "a"
        state.findReplace.replacement = "b"
        document.setReadingMode(true)
        state.replaceCurrentMatch()
        XCTAssertEqual(document.text, "aaa")
        XCTAssertEqual(state.findReplace.message, L10n.tr("阅读模式下无法修改"))
        state.findReplace.message = nil
        state.replaceAllMatches()
        XCTAssertEqual(document.text, "aaa")
        XCTAssertEqual(state.findReplace.message, L10n.tr("阅读模式下无法修改"))
    }

    func testFormatJSONIsRefused() throws {
        let document = EditorDocument(text: "{\"a\":1}", language: .json)
        let (state, _) = try appState(document, suite: "LacEditorReading.\(UUID())")
        document.setReadingMode(true)
        state.formatJSON()
        XCTAssertEqual(document.text, "{\"a\":1}")
        XCTAssertTrue(document.statusMessageIsError)
        XCTAssertEqual(document.statusMessage, L10n.tr("阅读模式下无法修改"))
    }
}
