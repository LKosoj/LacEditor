import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class SidebarSelectionTests: XCTestCase {
    func testSelectionRangeAndListBoundary() {
        let selection = SidebarSelection()
        let urls = ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        selection.select(urls[0], in: .favorites, urls: urls, command: false, shift: false)
        selection.select(urls[2], in: .favorites, urls: urls, command: false, shift: true)
        XCTAssertEqual(selection.paths, Set(urls.map(\.path)))
        selection.select(urls[1], in: .favorites, urls: urls, command: true, shift: false)
        XCTAssertEqual(selection.paths, Set([urls[0].path, urls[2].path]))
        selection.select(urls[1], in: .recent, urls: urls, command: true, shift: false)
        XCTAssertEqual(selection.paths, [urls[1].path])
        XCTAssertEqual(selection.location, .recent)
    }

    func testSelectAllAndFilterRemovesHiddenSelection() {
        let selection = SidebarSelection()
        let urls = ["a", "b"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        selection.select(urls[0], in: .favorites, urls: urls, command: false, shift: false)
        selection.selectAll(in: .favorites, urls: urls, focused: urls[0])
        selection.reconcile(in: .favorites, urls: [urls[1]])
        XCTAssertEqual(selection.paths, [urls[1].path])
        selection.reconcile(in: .favorites, urls: [])
        XCTAssertTrue(selection.paths.isEmpty)
    }
    func testSelectAllUsesFocusedRowForRangeInNewList() {
        let selection = SidebarSelection()
        let urls = ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        selection.select(urls[0], in: .favorites, urls: urls, command: false, shift: false)
        selection.selectAll(in: .recent, urls: urls, focused: urls[1])
        selection.select(urls[2], in: .recent, urls: urls, command: false, shift: true)
        XCTAssertEqual(selection.paths, Set([urls[1].path, urls[2].path]))
        let fresh = SidebarSelection()
        fresh.selectAll(in: .recent, urls: urls, focused: urls[1])
        fresh.select(urls[0], in: .recent, urls: urls, command: false, shift: true)
        XCTAssertEqual(fresh.paths, Set([urls[0].path, urls[1].path]))
    }

    func testBatchUndoAndLaterChanges() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LacEditorTests.sidebar.selection.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let library = SidebarLibraryStore(storageURL: directory.appendingPathComponent("sidebar.json"))
        let recent = RecentFilesStore(defaults: defaults)
        let manager = WindowManager(preferences: AppPreferences(defaults: defaults), recentFiles: recent, sidebarLibrary: library)
        let state = manager.openNewWindow(with: EditorDocument(text: "", language: .plainText))
        defer { state.closeAuxiliaryWindows(); state.hostWindow?.delegate = nil; state.hostWindow?.close() }
        let urls = ["a", "b", "c"].map { directory.appendingPathComponent($0) }
        state.addSidebarFavorites(Array(urls.prefix(2)))
        XCTAssertEqual(library.favoriteURLs, Array(urls.prefix(2)))
        state.sidebarFeedback.undo()
        XCTAssertTrue(library.favoriteURLs.isEmpty)
        state.addSidebarFavorites(Array(urls.prefix(2)))
        library.toggleFavorite(urls[2])
        state.sidebarFeedback.undo()
        XCTAssertEqual(library.favoriteURLs, urls)
        XCTAssertEqual(state.sidebarFeedback.item?.title, L10n.tr("列表已变化，未撤销"))
        let group = try XCTUnwrap(library.createGroup(named: "test"))
        state.addSidebarFiles(Array(urls.prefix(2)), toGroup: group)
        XCTAssertEqual(library.groups[0].urls, Array(urls.prefix(2)))
        state.sidebarFeedback.undo()
        XCTAssertTrue(library.groups[0].urls.isEmpty)
        state.addSidebarFiles(Array(urls.prefix(2)), toGroup: group)
        library.add(urls[2], toGroup: group)
        state.sidebarFeedback.undo()
        XCTAssertEqual(library.groups[0].urls, urls)
        for url in urls { recent.record(url) }
        let before = recent.urls
        state.removeSidebarFiles(Array(before.prefix(2)), location: .recent)
        state.sidebarFeedback.undo()
        XCTAssertEqual(recent.urls, before)
        state.removeSidebarFiles(Array(before.prefix(2)), location: .recent)
        recent.record(directory.appendingPathComponent("later"))
        let later = recent.urls
        state.sidebarFeedback.undo()
        XCTAssertEqual(recent.urls, later)
    }

    func testActualFocusDoesNotChangeSelectionAndArrowCanReturnToSelection() {
        let selection = SidebarSelection()
        let urls = ["a", "b"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        selection.select(urls[0], in: .favorites, urls: urls, command: false, shift: false)
        selection.focused = SidebarSelection.Focus(location: .favorites, path: urls[1].path)
        XCTAssertEqual(selection.paths, [urls[0].path])
        selection.select(urls[0], in: .favorites, urls: urls, command: false, shift: false)
        XCTAssertEqual(selection.focused, SidebarSelection.Focus(location: .favorites, path: urls[0].path))
        let group = SidebarFileLocation.group(UUID())
        selection.focused = SidebarSelection.Focus(location: group, path: urls[0].path)
        XCTAssertEqual(selection.paths, [urls[0].path])
        XCTAssertNotEqual(selection.focused, SidebarSelection.Focus(location: .favorites, path: urls[0].path))
        selection.reconcile(in: .favorites, urls: [])
        XCTAssertEqual(selection.focused, SidebarSelection.Focus(location: group, path: urls[0].path))
    }

}
