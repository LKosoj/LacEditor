import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class ToolbarDefaultsTests: XCTestCase {
    private func makeController() throws -> (EditorWindowToolbarController, AppState, () -> Void) {
        _ = NSApplication.shared
        let suite = "LacEditorTests.toolbarDefaults.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let state = AppState(initialDocument: EditorDocument(text: "", language: .plainText),
                             recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        return (EditorWindowToolbarController(appState: state), state, {
            state.closeAuxiliaryWindows()
            defaults.removePersistentDomain(forName: suite)
        })
    }

    func testDefaultToolbarItemIdentifiers() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let defaults = controller.toolbarDefaultItemIdentifiers(NSToolbar(identifier: NSToolbar.Identifier("t"))).map(\.rawValue)
        XCTAssertEqual(defaults, [
            NSToolbarItem.Identifier.flexibleSpace.rawValue, "LacEditor.Sidebar",
            NSToolbarItem.Identifier.sidebarTrackingSeparator.rawValue, "LacEditor.WindowTitle",
            NSToolbarItem.Identifier.flexibleSpace.rawValue, "LacEditor.Find", "LacEditor.Language",
            "LacEditor.MarkdownPresentation", "LacEditor.Preview"
        ])
    }

    func testEveryDefaultItemIsAllowedAndPaletteKeepsRemovedItems() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("t"))
        let allowed = Set(controller.toolbarAllowedItemIdentifiers(toolbar).map(\.rawValue))
        for item in controller.toolbarDefaultItemIdentifiers(toolbar) { XCTAssertTrue(allowed.contains(item.rawValue), item.rawValue) }
        for name in ["Open", "Save", "History", "NewDocument", "AIWriting", "Import", "Export"] {
            XCTAssertTrue(allowed.contains("LacEditor.\(name)"), name)
        }
    }
}
