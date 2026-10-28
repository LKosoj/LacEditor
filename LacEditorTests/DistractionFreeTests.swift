import AppKit
import SwiftUI
import XCTest
@testable import LacEditor

@MainActor
final class DistractionFreeTests: XCTestCase {
    func testFocusModeRestoresToolbarAndDoesNotChangeOtherWindowOrSettings() throws {
        _ = NSApplication.shared
        let suite = "LacEditorDistractionFree.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalSidebar = UserDefaults.standard.object(forKey: "isSidebarVisible")
        defer { UserDefaults.standard.set(originalSidebar, forKey: "isSidebarVisible") }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "# Heading", language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let other = AppState(initialDocument: EditorDocument(text: "other"), recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        defer { window.close(); otherWindow.close() }
        let identifier = NSToolbar.Identifier("LacEditor.Test.Focus.\(UUID())")
        let toolbar = NSToolbar(identifier: identifier)
        let otherToolbar = NSToolbar(identifier: identifier)
        window.toolbar = toolbar
        otherWindow.toolbar = otherToolbar
        state.hostWindow = window
        other.hostWindow = otherWindow
        state.isSidebarVisible = true
        preferences.lineNumbersVisible = true
        preferences.statusBarVisible = true
        document.isPreviewVisible = true
        document.selectionRange = NSRange(location: 2, length: 3)
        toolbar.isVisible = true
        otherToolbar.isVisible = true

        state.toggleDistractionFree()
        XCTAssertTrue(state.isDistractionFree)
        XCTAssertFalse(state.isSidebarEffectivelyVisible)
        XCTAssertTrue(state.isSidebarVisible)
        XCTAssertFalse(toolbar.isVisible)
        XCTAssertTrue(otherToolbar.isVisible)
        XCTAssertFalse(other.isDistractionFree)
        XCTAssertTrue(preferences.lineNumbersVisible)
        XCTAssertTrue(preferences.statusBarVisible)
        XCTAssertTrue(document.isPreviewVisible)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.text, "# Heading")
        XCTAssertEqual(document.selectionRange, NSRange(location: 2, length: 3))

        state.toggleDistractionFree()
        XCTAssertFalse(state.isDistractionFree)
        XCTAssertTrue(state.isSidebarEffectivelyVisible)
        XCTAssertTrue(toolbar.isVisible)
        toolbar.isVisible = false
        state.toggleDistractionFree()
        state.toggleDistractionFree()
        XCTAssertFalse(toolbar.isVisible)
        state.isSidebarVisible = false
        state.toggleDistractionFree()
        state.toggleSidebar()
        XCTAssertFalse(state.isDistractionFree)
        XCTAssertTrue(state.isSidebarVisible)
        XCTAssertTrue(state.isSidebarEffectivelyVisible)
        toolbar.isVisible = true
        state.toggleDistractionFree()
        XCTAssertFalse(toolbar.isVisible)
        state.hostWindow = otherWindow
        XCTAssertFalse(state.isDistractionFree)
        XCTAssertTrue(toolbar.isVisible)
        XCTAssertTrue(otherToolbar.isVisible)
    }

    func testSidebarSplitClosesForFocusAndReopensWithoutChangingPreference() async throws {
        _ = NSApplication.shared
        let suite = "LacEditorDistractionFreeSplit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalSidebar = UserDefaults.standard.object(forKey: "isSidebarVisible")
        defer { UserDefaults.standard.set(originalSidebar, forKey: "isSidebarVisible") }
        let preferences = AppPreferences(defaults: defaults)
        let manager = WindowManager(preferences: preferences, recentFiles: RecentFilesStore(defaults: defaults))
        let state = AppState(initialDocument: EditorDocument(text: "content"), recentFiles: manager.recentFiles, preferences: preferences)
        state.isSidebarVisible = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state.hostWindow = window
        window.contentViewController = NSHostingController(rootView: EditorWindowRoot(appState: state, windowManager: manager, windowID: UUID()))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150))
        func findSplit(_ view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               controller.splitViewItems.first?.behavior == .sidebar { return controller }
            return view.subviews.lazy.compactMap(findSplit).first
        }
        let split = try XCTUnwrap(findSplit(try XCTUnwrap(window.contentView)))
        let sidebar = split.splitViewItems[0]
        XCTAssertFalse(sidebar.isCollapsed)
        state.toggleDistractionFree()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(sidebar.isCollapsed)
        XCTAssertTrue(state.isSidebarVisible)
        state.toggleSidebar()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertFalse(state.isDistractionFree)
        XCTAssertTrue(state.isSidebarVisible)
    }

    func testFocusTogglePreservesEditorSelectionAndUndo() throws {
        _ = NSApplication.shared
        let suite = "LacEditorDistractionFreeUndo.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(initialDocument: EditorDocument(text: "text"), recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = LacTextView(frame: window.contentView!.bounds)
        view.allowsUndo = true
        view.string = "text"
        window.contentView = view
        state.hostWindow = window
        window.makeFirstResponder(view)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        view.setSelectedRange(NSRange(location: 4, length: 0))
        undo.beginUndoGrouping()
        view.insertText("!", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        let selection = view.selectedRange()
        state.toggleDistractionFree()
        state.toggleDistractionFree()
        XCTAssertEqual(view.string, "text!")
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(view.string, "text")
    }

}
