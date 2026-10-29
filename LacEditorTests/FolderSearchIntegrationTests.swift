import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class FolderSearchIntegrationTests: XCTestCase {
    func testMarkedNativeTableCellSearchRefusesRevealUntilCompositionCommits() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("table.md")
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let document = EditorDocument(text: source, url: file, language: .markdown)
        document.isMarkdownFormatted = true
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        window.makeKeyAndOrderFront(nil)
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        let rootTask = try XCTUnwrap(state.folderWorkspace.setRoot(root))
        await rootTask.value
        let range = (source as NSString).range(of: "one")
        XCTAssertTrue(coordinator.beginTableCell(range, frame: NSRect(x: 10, y: 10, width: 150, height: 40)))
        let child = try XCTUnwrap(view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
        child.setMarkedText("中文😀", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertTrue(window.firstResponder === child)
        let expected = (source as NSString).replacingCharacters(in: range, with: "中文😀")
        let snapshot = try XCTUnwrap(manager.folderSearchSnapshots(root: root)?.first)
        XCTAssertEqual(snapshot.snapshot.text, expected)
        let search = state.folderSearch
        search.mode = .text
        search.query = "中文😀"
        await search.start()?.value
        let match = try XCTUnwrap(search.matches.first)
        await search.select(match)?.value
        XCTAssertEqual(search.message, .stale)
        XCTAssertTrue(child.hasMarkedText())
        XCTAssertEqual(view.string, source)
        child.unmarkText()
        XCTAssertFalse(child.hasMarkedText())
        XCTAssertEqual(view.string, expected)
        await search.start()?.value
        let committed = try XCTUnwrap(search.matches.first)
        await search.select(committed)?.value
        XCTAssertNil(search.message)
        XCTAssertEqual(view.selectedRange(), (expected as NSString).range(of: "中文😀"))
    }

    func testOpenReturnsLoadedSnapshotAndReusesExistingDocument() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try "😀 needle".write(to: file, atomically: true, encoding: .utf8)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = WindowManager(recentFiles: RecentFilesStore(defaults: defaults))
        let state = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        defer { manager.unregister(windowID: id); window.close() }
        let firstResult = await manager.openFolderSearchFile(file, preferredState: state)
        let secondResult = await manager.openFolderSearchFile(file, preferredState: state)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        XCTAssertEqual(first.snapshot.text, "😀 needle")
        XCTAssertEqual(first.snapshot.documentID, second.snapshot.documentID)
        XCTAssertEqual(manager.openDocumentURLs.filter { $0.standardizedFileURL == file.standardizedFileURL }.count, 1)
    }

    func testSnapshotsAndRevealUseLiveDocumentAcrossWindows() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let document = EditorDocument(text: "disk", url: file, language: .markdown)
        let providerID = UUID()
        document.attachLiveTextProvider(id: providerID, provider: { "😀 needle" }, acknowledgement: { _ in })
        document.noteLiveEdit(isEmpty: false)
        defer { document.detachLiveTextProvider(id: providerID) }
        let manager = WindowManager()
        let owner = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let other = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        let firstID = UUID(), secondID = UUID()
        manager.register(windowID: firstID, state: owner, window: firstWindow)
        manager.register(windowID: secondID, state: other, window: secondWindow)
        defer { manager.unregister(windowID: secondID); manager.unregister(windowID: firstID); secondWindow.close(); firstWindow.close() }
        let snapshot = try XCTUnwrap(manager.folderSearchSnapshots(root: root)?.first)
        XCTAssertEqual(snapshot.snapshot.text, "😀 needle")
        let match = FolderSearchService.Match(file: .init(url: file, relativePath: "file.md"),
            range: NSRange(location: 3, length: 6), matchedText: "needle", contextRange: NSRange(location: 0, length: 9),
            context: "😀 needle", source: .open(documentID: document.id, revision: snapshot.snapshot.revision, identity: snapshot.identity))
        XCTAssertTrue(manager.revealFolderSearchMatch(match, expected: snapshot))
        XCTAssertEqual(document.selectionRange, match.range)
        document.text = "changed"
        XCTAssertFalse(manager.revealFolderSearchMatch(match, expected: snapshot))
    }

    func testOpenWaitsForActualReadAndCancellationCannotReveal() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let started = expectation(description: "read started")
        let release = DispatchSemaphore(value: 0)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = WindowManager(recentFiles: RecentFilesStore(defaults: defaults))
        let state = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences, readFile: { url in
            started.fulfill()
            release.wait()
            return try FileService.prepareRead(url)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        defer { manager.unregister(windowID: id); window.close() }
        let task = Task { await manager.openFolderSearchFile(file, preferredState: state) }
        await fulfillment(of: [started], timeout: 2)
        let placeholder = try XCTUnwrap(state.selectedDocument)
        XCTAssertTrue(state.isOpeningPlaceholder(placeholder))
        task.cancel()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
        release.signal()
    }
}
