import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class RecentFolderTests: XCTestCase {
    func testFolderHistoryIsSeparateAndConditionalUndoPreservesNewerChanges() throws {
        let suite = "LacEditorTests.RecentFolders.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/tmp/old.md"], forKey: "recentFilePaths")
        let store = RecentFilesStore(defaults: defaults)
        XCTAssertTrue(store.folderURLs.isEmpty)
        let first = URL(fileURLWithPath: "/tmp/first", isDirectory: true).resolvingSymlinksInPath()
        let second = URL(fileURLWithPath: "/tmp/second", isDirectory: true).resolvingSymlinksInPath()
        store.recordFolder(first)
        store.recordFolder(second)
        store.recordFolder(first.appendingPathComponent("."))
        XCTAssertEqual(store.folderURLs.map(\.path), [first.path, second.path])
        XCTAssertEqual(store.urls.map(\.path), ["/tmp/old.md"])
        XCTAssertEqual(RecentFilesStore(defaults: defaults).folderURLs, store.folderURLs)
        let previous = store.folderURLs
        store.removeFolder(first)
        let expected = store.folderURLs
        store.recordFolder(URL(fileURLWithPath: "/tmp/later", isDirectory: true))
        XCTAssertFalse(store.restoreFolders(previous, ifUnchanged: expected))
        XCTAssertEqual(store.folderURLs.first?.lastPathComponent, "later")
        store.clearFolders()
        XCTAssertTrue(store.folderURLs.isEmpty)
        XCTAssertEqual(store.urls.map(\.path), ["/tmp/old.md"])
    }

    func testPinnedFoldersReadOldJSONAndPersistSeparatelyFromFavoriteFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("library.json")
        try Data("{\"favoritePaths\":[\"/tmp/old.md\"],\"groups\":[]}".utf8).write(to: storage)
        let store = SidebarLibraryStore(storageURL: storage)
        XCTAssertTrue(store.pinnedFolderPaths.isEmpty)
        let folder = root.appendingPathComponent("中文😀", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store.togglePinnedFolder(folder)
        XCTAssertTrue(SidebarLibraryStore(storageURL: storage).isPinnedFolder(folder))
        XCTAssertEqual(store.favoritePaths, ["/tmp/old.md"])
        let old = store.pinnedFolderPaths
        store.togglePinnedFolder(folder)
        let expected = store.pinnedFolderPaths
        store.togglePinnedFolder(root)
        XCTAssertFalse(store.restorePinnedFolders(old, ifUnchanged: expected))
        XCTAssertTrue(store.isPinnedFolder(root))
    }

    func testExplicitFolderOpenRecordsHistoryAndMissingFolderKeepsDocumentAndRoot() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LacEditorTests.OpenRecentFolder.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentFilesStore(defaults: defaults)
        let document = EditorDocument(text: "unsaved 中😀", language: .markdown, isDirty: true)
        let state = AppState(initialDocument: document, recentFiles: recent, preferences: AppPreferences(defaults: defaults))
        defer { state.folderWorkspace.setRoot(nil); state.folderSearch.close(); document.cancelMetricsRefresh() }
        XCTAssertTrue(state.openFolder(root))
        XCTAssertEqual(recent.folderURLs.map(\.path), [root.resolvingSymlinksInPath().path])
        XCTAssertFalse(state.openFolder(root.appendingPathComponent("missing")))
        XCTAssertEqual(state.folderWorkspace.rootURL?.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(recent.folderURLs.count, 1)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertTrue(state.selectedDocument === document)
        XCTAssertEqual(document.text, "unsaved 中😀")
        XCTAssertTrue(document.isDirty)
    }
}
