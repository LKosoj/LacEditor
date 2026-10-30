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
            "LacEditor.MarkdownPresentation", "LacEditor.ReadingMode", "LacEditor.Dictation", "LacEditor.Preview"
        ])
    }

    func testEveryDefaultItemIsAllowedAndPaletteKeepsRemovedItems() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("t"))
        let allowed = Set(controller.toolbarAllowedItemIdentifiers(toolbar).map(\.rawValue))
        for item in controller.toolbarDefaultItemIdentifiers(toolbar) { XCTAssertTrue(allowed.contains(item.rawValue), item.rawValue) }
        for name in ["Open", "Save", "History", "NewDocument", "AIWriting", "Import", "Export", "ReadingMode", "Dictation"] {
            XCTAssertTrue(allowed.contains("LacEditor.\(name)"), name)
        }
    }

    func testAddSavedToolbarItemInsertsOnceAfterAnchor() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let suite = "LacEditorTests.toolbarSaved.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "NSToolbar Configuration LacEditor.EditorToolbar"
        let item = NSToolbarItem.Identifier("LacEditor.ReadingMode")
        let anchor = NSToolbarItem.Identifier("LacEditor.MarkdownPresentation")
        let list = ["A", anchor.rawValue, "LacEditor.Preview"]
        defaults.set(["TB Default Item Identifiers": list, "TB Item Identifiers": list], forKey: key)
        controller.addSavedToolbarItem(item, after: anchor, flag: "f", defaults: defaults)
        let expected = ["A", anchor.rawValue, item.rawValue, "LacEditor.Preview"]
        var saved = try XCTUnwrap(defaults.dictionary(forKey: key))
        XCTAssertEqual(saved["TB Default Item Identifiers"] as? [String], expected)
        XCTAssertEqual(saved["TB Item Identifiers"] as? [String], expected)
        // The flag keeps a button removed by the user from coming back.
        defaults.set(["TB Default Item Identifiers": list, "TB Item Identifiers": list], forKey: key)
        controller.addSavedToolbarItem(item, after: anchor, flag: "f", defaults: defaults)
        saved = try XCTUnwrap(defaults.dictionary(forKey: key))
        XCTAssertEqual(saved["TB Item Identifiers"] as? [String], list)
        // Missing anchor appends to the end; an existing item is not duplicated.
        defaults.set(["TB Item Identifiers": ["A"]], forKey: key)
        controller.addSavedToolbarItem(item, after: anchor, flag: "g", defaults: defaults)
        saved = try XCTUnwrap(defaults.dictionary(forKey: key))
        XCTAssertEqual(saved["TB Item Identifiers"] as? [String], ["A", item.rawValue])
        defaults.set(["TB Item Identifiers": ["A", item.rawValue]], forKey: key)
        controller.addSavedToolbarItem(item, after: anchor, flag: "h", defaults: defaults)
        saved = try XCTUnwrap(defaults.dictionary(forKey: key))
        XCTAssertEqual(saved["TB Item Identifiers"] as? [String], ["A", item.rawValue])
    }

    func testAddSavedToolbarItemWithoutConfigurationOnlySetsFlag() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let suite = "LacEditorTests.toolbarSaved.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.addSavedToolbarItem(
            NSToolbarItem.Identifier("LacEditor.ReadingMode"),
            after: NSToolbarItem.Identifier("LacEditor.MarkdownPresentation"),
            flag: "f",
            defaults: defaults
        )
        XCTAssertTrue(defaults.bool(forKey: "f"))
        XCTAssertNil(defaults.dictionary(forKey: "NSToolbar Configuration LacEditor.EditorToolbar"))
    }

    func testReadingModeToolbarItemIsCreated() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let item = controller.toolbar(
            NSToolbar(identifier: NSToolbar.Identifier("t")),
            itemForItemIdentifier: NSToolbarItem.Identifier("LacEditor.ReadingMode"),
            willBeInsertedIntoToolbar: false
        )
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.autovalidates, false)
        XCTAssertTrue(item?.target === controller)
    }

    func testDictationToolbarItemIsCreated() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let item = controller.toolbar(
            NSToolbar(identifier: NSToolbar.Identifier("t")),
            itemForItemIdentifier: NSToolbarItem.Identifier("LacEditor.Dictation"),
            willBeInsertedIntoToolbar: false
        )
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.autovalidates, false)
        XCTAssertTrue(item?.target === controller)
    }
}
