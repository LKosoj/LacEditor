import AppKit
import Combine
import XCTest
@testable import LacEditor

@MainActor
final class WindowNavigationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let suite = "LacEditorTests.nav.\(UUID().uuidString)"
        let defaults: UserDefaults
        let directory: URL
        let manager: WindowManager
        var windows: [(id: UUID, window: NSWindow)] = []

        init() throws {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            manager = WindowManager(preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults),
                                    sidebarLibrary: SidebarLibraryStore(storageURL: directory.appendingPathComponent("library.json")))
        }

        /// Окно с собственным состоянием; первое зарегистрированное становится активным.
        func addWindow(text: String, url: URL? = nil, language: EditorLanguage = .plainText) -> (state: AppState, document: EditorDocument, id: UUID) {
            let document = EditorDocument(text: text, url: url, language: language)
            let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let id = UUID()
            manager.register(windowID: id, state: state, window: window)
            windows.append((id, window))
            return (state, document, id)
        }

        func dispose() {
            for entry in windows.reversed() { manager.unregister(windowID: entry.id); entry.window.close() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testGoToLineRecordsOriginAndBackReturns() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "a\nb\nc\n")
        first.document.selectionRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(first.state.goToLine("3"))
        XCTAssertEqual(first.document.selectionRange.location, 4)
        fixture.manager.navigateBack()
        XCTAssertEqual(first.document.selectionRange, NSRange(location: 0, length: 0))
        fixture.manager.navigateForward()
        XCTAssertEqual(first.document.selectionRange, NSRange(location: 4, length: 0))
    }

    func testInvalidGoToLineDoesNotRecord() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "a\nb\n")
        XCTAssertFalse(first.state.goToLine("99"))
        XCTAssertFalse(fixture.manager.navigationHistory.canGoBack)
    }

    func testFindNextDoesNotRecord() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "x a x a x")
        first.state.findReplace.query = "x"
        first.state.findNext()
        XCTAssertFalse(fixture.manager.navigationHistory.canGoBack)
    }

    func testOutlineHeadingRecordsOrigin() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "\n\n# Title", language: .markdown)
        let heading = MarkdownHeading(level: 1, title: "Title", range: NSRange(location: 2, length: 7))
        first.document.markdownHeadings = [heading]
        first.document.isMarkdownOutlineCurrent = false
        first.state.revealMarkdownHeading(heading, in: first.document)
        XCTAssertFalse(fixture.manager.navigationHistory.canGoBack)
        first.document.isMarkdownOutlineCurrent = true
        first.state.revealMarkdownHeading(heading, in: first.document)
        XCTAssertTrue(fixture.manager.navigationHistory.canGoBack)
        fixture.manager.navigateBack()
        XCTAssertEqual(first.document.selectionRange.location, 0)
    }

    private func match(in document: EditorDocument, url: URL, snapshot: FolderSearchService.OpenDocument, range: NSRange, text: String) -> FolderSearchService.Match {
        FolderSearchService.Match(file: .init(url: url, relativePath: url.lastPathComponent),
            range: range, matchedText: text, contextRange: range, context: text,
            source: .open(documentID: document.id, revision: snapshot.snapshot.revision, identity: snapshot.identity))
    }

    /// Два документа в разных окнах, оба с файлом на диске (нужен адрес для поиска по папке).
    private func twoFileWindows(_ fixture: Fixture) throws -> (a: (state: AppState, document: EditorDocument, id: UUID), b: (state: AppState, document: EditorDocument, id: UUID), snapshots: [FolderSearchService.OpenDocument]) {
        let fileA = fixture.directory.appendingPathComponent("a.txt")
        let fileB = fixture.directory.appendingPathComponent("b.txt")
        try "alpha\nbeta".write(to: fileA, atomically: true, encoding: .utf8)
        try "needle here".write(to: fileB, atomically: true, encoding: .utf8)
        let a = fixture.addWindow(text: "alpha\nbeta", url: fileA)
        let b = fixture.addWindow(text: "needle here", url: fileB)
        fixture.manager.activate(windowID: a.id)
        let snapshots = try XCTUnwrap(fixture.manager.folderSearchSnapshots(root: fixture.directory))
        return (a, b, snapshots)
    }

    func testRevealFolderSearchMatchRecordsOriginBeforeFocus() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let pair = try twoFileWindows(fixture)
        pair.a.document.selectionRange = NSRange(location: 6, length: 0)
        let snapshot = try XCTUnwrap(pair.snapshots.first { $0.snapshot.documentID == pair.b.document.id })
        let found = match(in: pair.b.document, url: snapshot.url, snapshot: snapshot, range: NSRange(location: 0, length: 6), text: "needle")
        XCTAssertTrue(fixture.manager.revealFolderSearchMatch(found, expected: snapshot))
        XCTAssertTrue(fixture.manager.navigationHistory.canGoBack)
        pair.a.document.selectionRange = NSRange(location: 0, length: 0)
        fixture.manager.activate(windowID: pair.b.id)
        fixture.manager.navigateBack()
        XCTAssertEqual(pair.a.document.selectionRange, NSRange(location: 6, length: 0))
    }

    func testFailedRevealDoesNotRecord() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let pair = try twoFileWindows(fixture)
        let snapshot = try XCTUnwrap(pair.snapshots.first { $0.snapshot.documentID == pair.b.document.id })
        let found = match(in: pair.b.document, url: snapshot.url, snapshot: snapshot, range: NSRange(location: 0, length: 6), text: "needle")
        pair.b.document.text = "changed"
        XCTAssertFalse(fixture.manager.revealFolderSearchMatch(found, expected: snapshot))
        XCTAssertFalse(fixture.manager.navigationHistory.canGoBack)
    }

    func testBackAcrossWindowsFocusesOtherDocument() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "a\nb\nc")
        let second = fixture.addWindow(text: "x\ny\nz")
        fixture.manager.activate(windowID: first.id)
        first.document.selectionRange = NSRange(location: 2, length: 0)
        fixture.manager.recordNavigationOrigin(from: first.document)
        first.document.selectionRange = NSRange(location: 0, length: 0)
        fixture.manager.activate(windowID: second.id)
        fixture.manager.navigateBack()
        XCTAssertEqual(first.document.selectionRange, NSRange(location: 2, length: 0))
        XCTAssertFalse(fixture.manager.navigationHistory.canGoBack)
    }

    func testClosedDocumentIsSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "a\nb\nc")
        let second = fixture.addWindow(text: "x\ny\nz")
        let third = fixture.addWindow(text: "1\n2\n3")
        fixture.manager.activate(windowID: first.id)
        first.document.selectionRange = NSRange(location: 2, length: 0)
        fixture.manager.recordNavigationOrigin(from: first.document)
        first.document.selectionRange = NSRange(location: 0, length: 0)
        fixture.manager.activate(windowID: second.id)
        fixture.manager.recordNavigationOrigin(from: second.document)
        fixture.manager.activate(windowID: third.id)
        fixture.manager.unregister(windowID: second.id)
        fixture.windows.removeAll { $0.id == second.id }
        fixture.manager.activate(windowID: third.id)
        fixture.manager.navigateBack()
        XCTAssertEqual(first.document.selectionRange, NSRange(location: 2, length: 0))
        XCTAssertFalse(fixture.manager.navigationHistory.canGoBack)
    }

    func testBackWithMarkedTextDoesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "a\nb\nc")
        XCTAssertTrue(first.state.goToLine("3"))
        let window = try XCTUnwrap(first.state.hostWindow)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        guard view.hasMarkedText() else { throw XCTSkip("Незавершённый ввод создаётся только в окне Mac") }
        let before = fixture.manager.navigationHistory.back
        fixture.manager.navigateBack()
        XCTAssertEqual(fixture.manager.navigationHistory.back, before)
        XCTAssertEqual(first.document.selectionRange.location, 4)
    }

    func testHistoryPublishesChanges() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let first = fixture.addWindow(text: "a\nb")
        var changes = 0
        let token = fixture.manager.objectWillChange.sink { changes += 1 }
        defer { token.cancel() }
        fixture.manager.recordNavigationOrigin(from: first.document)
        XCTAssertGreaterThan(changes, 0)
    }

    func testPendingOriginUsedOnlyForDisk() throws {
        let fixture = try Fixture()
        defer { fixture.dispose() }
        let pair = try twoFileWindows(fixture)
        pair.a.document.selectionRange = NSRange(location: 6, length: 0)
        // Ожидающее место от прежнего открытия файла b не должно подменить место активного окна.
        let snapshot = try XCTUnwrap(pair.snapshots.first { $0.snapshot.documentID == pair.b.document.id })
        let found = match(in: pair.b.document, url: snapshot.url, snapshot: snapshot, range: NSRange(location: 0, length: 6), text: "needle")
        XCTAssertTrue(fixture.manager.revealFolderSearchMatch(found, expected: snapshot))
        let back = fixture.manager.navigationHistory.back
        XCTAssertEqual(back.last?.documentID, pair.a.document.id)
        XCTAssertEqual(back.last?.line, 2)
    }
}
