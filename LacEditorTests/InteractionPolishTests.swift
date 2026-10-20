import AppKit
import Combine
import XCTest
@testable import LacEditor

@MainActor
final class InteractionPolishTests: XCTestCase {
    func testFeedbackExpiryReplacementPauseUndoAndRelease() async throws {
        var state: InlineFeedbackState? = InlineFeedbackState(duration: .milliseconds(100))
        weak var released = state
        state?.show("旧消息")
        try await Task.sleep(for: .milliseconds(60))
        state?.show("新消息")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(state?.item?.title, "新消息", "Old expiry must not clear a newer result")
        state?.setInteracting(true)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(state?.item?.title, "新消息", "Pointer/key focus must keep the action available")
        var undoCount = 0
        state?.show("已移除") { undoCount += 1; return true }
        state?.undo()
        state?.undo()
        XCTAssertEqual(undoCount, 1)
        XCTAssertEqual(state?.item?.title, "已撤销上次操作")
        state?.setInteracting(false)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(state?.item)
        state?.show("待清理")
        state = nil
        XCTAssertNil(released, "An expiry task must not retain the window-local state")
    }

    func testGuardedSidebarUndoPreservesOtherGroupsAndRejectsLaterEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("sidebar.json")
        let library = SidebarLibraryStore(storageURL: storage)
        let a = directory.appendingPathComponent("a.md")
        let b = directory.appendingPathComponent("b.md")
        let group = try XCTUnwrap(library.createGroup(named: "原分组"))
        let other = try XCTUnwrap(library.createGroup(named: "其他分组"))
        library.add(a, toGroup: group)
        library.add(b, toGroup: group)
        let before = library.groups[0].paths
        library.remove(a, fromGroup: group)
        let expected = library.groups[0].paths
        library.add(a, toGroup: other)
        library.setExpanded(false, for: group)
        XCTAssertTrue(library.restoreGroupFiles(before, in: group, ifUnchanged: expected))
        XCTAssertEqual(library.groups[0].paths, before)
        XCTAssertFalse(library.groups[0].isExpanded)
        XCTAssertEqual(library.groups[1].urls, [a])
        library.remove(a, fromGroup: group)
        library.add(a, toGroup: group)
        XCTAssertFalse(library.restoreGroupFiles(before, in: group, ifUnchanged: expected))
        library.toggleFavorite(a)
        let favorites = library.favoritePaths
        library.toggleFavorite(a)
        library.toggleFavorite(b)
        XCTAssertFalse(library.restoreFavorites(favorites, ifUnchanged: []))
        XCTAssertEqual(library.favoriteURLs, [b])
        XCTAssertEqual(SidebarLibraryStore(storageURL: storage).groups, library.groups)
    }

    func testRecentUndoDoesNotOverwriteLaterOpenedFiles() throws {
        let suite = "LacEditorTests.ui8.recent.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentFilesStore(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")
        recent.record(a)
        let before = recent.urls
        recent.remove(a)
        XCTAssertTrue(recent.restore(before, ifUnchanged: []))
        recent.remove(a)
        recent.record(b)
        XCTAssertFalse(recent.restore(before, ifUnchanged: []))
        XCTAssertEqual(RecentFilesStore(defaults: defaults).urls, [b])
    }

    func testWindowLocalSidebarFeedbackUndoDoesNotTouchDocument() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LacEditorTests.ui8.actions.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let library = SidebarLibraryStore(storageURL: directory.appendingPathComponent("sidebar.json"))
        let manager = WindowManager(preferences: AppPreferences(defaults: defaults),
                                    recentFiles: RecentFilesStore(defaults: defaults), sidebarLibrary: library)
        let document = EditorDocument(text: "保留正文", language: .plainText)
        let state = manager.openNewWindow(with: document)
        defer { state.closeAuxiliaryWindows(); state.hostWindow?.delegate = nil; state.hostWindow?.close() }
        let file = directory.appendingPathComponent("a.txt")
        state.toggleSidebarFavorite(file)
        XCTAssertTrue(library.isFavorite(file))
        XCTAssertTrue(state.sidebarFeedback.item?.canUndo == true)
        state.sidebarFeedback.undo()
        XCTAssertFalse(library.isFavorite(file))
        let group = try XCTUnwrap(library.createGroup(named: "测试组"))
        state.addSidebarFile(file, toGroup: group)
        state.sidebarFeedback.undo()
        XCTAssertTrue(library.groups[0].paths.isEmpty)
        state.addSidebarFile(file, toGroup: group)
        state.removeSidebarFile(file, fromGroup: group)
        state.sidebarFeedback.undo()
        XCTAssertEqual(library.groups[0].urls, [file])
        manager.recentFiles.record(file)
        state.removeRecentSidebarFile(file)
        manager.recentFiles.record(directory.appendingPathComponent("later.txt"))
        state.sidebarFeedback.undo()
        XCTAssertEqual(state.sidebarFeedback.item?.title, "列表已变化，未撤销")
        XCTAssertEqual(document.text, "保留正文")
        XCTAssertFalse(document.isDirty)
        state.closeAuxiliaryWindows()
        XCTAssertNil(state.sidebarFeedback.item)
    }

    func testDocumentChangesOnlyPublishMeaningfulChromeUpdates() throws {
        let suite = "LacEditorTests.ui8.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "测试", language: .plainText)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows() }
        document.isDirty = true
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        for index in 1...100 {
            document.cursorColumn = index
            document.selectionRange = NSRange(location: index, length: 0)
            document.isDirty = true
        }
        print("UI8_REFRESH repeated_dirty_and_cursor_updates=100 app_state_notifications=\(changes)")
        if ProcessInfo.processInfo.environment["LACEDITOR_UI8_BASELINE"] != "1" {
            XCTAssertEqual(changes, 0)
            document.isDirty = false
            XCTAssertEqual(changes, 1, "The actual saved-state transition must still reach chrome")
            document.language = .markdown
            XCTAssertEqual(changes, 2)
        }
        withExtendedLifetime(subscription) {}
    }

    func testCopyFeedbackDoesNotOverwriteStalePreviewMessageOrUserPasteboard() throws {
        let suite = "LacEditorTests.ui8.copy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows() }
        let document = try XCTUnwrap(state.selectedDocument)
        state.textTransformation.present(TextTransformationPreview(
            documentID: document.id, range: NSRange(location: 0, length: 3), input: "%41", output: "A",
            editorRevision: 0, operation: .smartDecode, detectedKind: nil))
        state.textTransformation.invalidate(documentID: document.id)
        let staleMessage = state.textTransformation.message
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        state.copyTextTransformationResult(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "A")
        XCTAssertEqual(state.textTransformation.copyFeedback.item?.title, "结果已复制")
        XCTAssertEqual(state.textTransformation.message, staleMessage)
        XCTAssertFalse(state.textTransformation.canReplace)
        state.textTransformation.clear()
        XCTAssertNil(state.textTransformation.copyFeedback.item)
    }
}
