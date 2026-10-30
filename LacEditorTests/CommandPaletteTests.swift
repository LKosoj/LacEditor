import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class CommandPaletteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private final class Target: NSObject {
        var count = 0
        @objc func ping() { count += 1 }
    }

    private func item(_ title: String, _ target: Target, key: String = "", mask: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Target.ping), keyEquivalent: key)
        item.target = target
        item.keyEquivalentModifierMask = mask
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private func mainMenu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: "main")
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    func testCollectBuildsPathsAndSkipsNoise() {
        let target = Target()
        let hidden = item("Hidden", target); hidden.isHidden = true
        let disabled = item("Disabled", target); disabled.isEnabled = false
        let noAction = NSMenuItem(title: "NoAction", action: nil, keyEquivalent: "")
        let empty = item("", target)
        let alternate = item("Alt", target); alternate.isAlternate = true
        let hiddenMenu = submenu("HiddenMenu", [item("Inner", target)]); hiddenMenu.isHidden = true
        let menu = mainMenu([
            submenu("App", [item("About", target)]),
            submenu("View", [
                item("First", target), .separator(), hidden, disabled, noAction, empty, alternate,
                submenu("Search", [item("Deep", target, key: "p", mask: [.command, .shift])])
            ]),
            hiddenMenu
        ])
        let commands = CommandPaletteService.collect(from: menu)
        XCTAssertEqual(commands.map(\.path), [
            [AppEnvironment.displayName, "About"], ["View", "First"], ["View", "Search", "Deep"]
        ])
        XCTAssertEqual(commands.last?.shortcut, "⇧⌘P")
        XCTAssertEqual(commands.last?.subtitle, "View › Search")
    }

    func testCollectSkipsServicesAndWindowsMenus() {
        let target = Target()
        let services = submenu("Services", [item("Service", target)])
        let windows = submenu("Window", [item("Minimize", target)])
        let savedServices = NSApp.servicesMenu, savedWindows = NSApp.windowsMenu
        defer { NSApp.servicesMenu = savedServices; NSApp.windowsMenu = savedWindows }
        NSApp.servicesMenu = services.submenu
        NSApp.windowsMenu = windows.submenu
        let menu = mainMenu([submenu("App", [item("About", target), services]), windows, submenu("File", [item("Open", target)])])
        XCTAssertEqual(CommandPaletteService.collect(from: menu).map(\.title), ["About", "Open"])
    }

    func testShortcutText() {
        let target = Target()
        XCTAssertEqual(CommandPaletteService.shortcutText(for: item("a", target, key: "p", mask: [.command, .shift])), "⇧⌘P")
        XCTAssertEqual(CommandPaletteService.shortcutText(for: item("a", target, key: "b", mask: [.command, .control])), "⌃⌘B")
        XCTAssertEqual(CommandPaletteService.shortcutText(for: item("a", target, key: "1", mask: [.command, .option])), "⌥⌘1")
        XCTAssertEqual(CommandPaletteService.shortcutText(for: item("a", target, key: "\r", mask: [])), "↩")
        let arrow = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        XCTAssertEqual(CommandPaletteService.shortcutText(for: item("a", target, key: arrow, mask: [.command])), "⌘↑")
        XCTAssertEqual(CommandPaletteService.shortcutText(for: item("a", target)), "")
    }

    func testRankingUsesNameQueryOrder() {
        func command(_ path: [String]) -> PaletteCommand { PaletteCommand(path: path, indexPath: [path.count], shortcut: "") }
        let letters = command(["File", "Share A Video Edit"])
        let inPath = command(["Save Menu", "Close"])
        let exact = command(["File", "Save"])
        let other = command(["File", "Print"])
        let all = [letters, inPath, other, exact]
        XCTAssertEqual(CommandPaletteService.ranked(all, query: "save"), [exact, inPath, letters])
        XCTAssertEqual(CommandPaletteService.ranked(all, query: "  "), all)
        XCTAssertFalse(CommandPaletteService.ranked(all, query: "sve").contains(other))
        let chinese = command(["文件", "保存文档"])
        XCTAssertEqual(CommandPaletteService.ranked([other, chinese], query: "保存"), [chinese])
    }

    func testResolveRejectsRemovedDisabledOrRenamedItem() {
        let target = Target()
        let first = item("First", target), second = item("Second", target)
        let menu = mainMenu([submenu("View", [first, second])])
        let command = CommandPaletteService.collect(from: menu)[1]
        XCTAssertNotNil(CommandPaletteService.resolve(command, in: menu))
        second.title = "Renamed"
        XCTAssertNil(CommandPaletteService.resolve(command, in: menu))
        XCTAssertFalse(CommandPaletteService.perform(command, menu: menu))
        second.title = "Second"
        second.isEnabled = false
        XCTAssertNil(CommandPaletteService.resolve(command, in: menu))
        second.isEnabled = true
        menu.items[0].submenu?.removeItem(second)
        XCTAssertNil(CommandPaletteService.resolve(command, in: menu))
        XCTAssertEqual(target.count, 0)
    }

    func testPerformInvokesActionOnce() {
        let target = Target()
        let menu = mainMenu([submenu("View", [item("Go", target)])])
        let command = CommandPaletteService.collect(from: menu)[0]
        XCTAssertTrue(CommandPaletteService.perform(command, menu: menu))
        XCTAssertEqual(target.count, 1)
    }

    func testRunDefersActionUntilPerformPending() {
        let target = Target()
        let menu = mainMenu([submenu("View", [item("Go", target)])])
        let controller = CommandPaletteController()
        controller.present(menu: menu)
        XCTAssertTrue(controller.isPresented)
        controller.run(controller.commands[0])
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(target.count, 0)
        XCTAssertTrue(controller.performPending(menu: menu))
        XCTAssertEqual(target.count, 1)
        XCTAssertFalse(controller.performPending(menu: menu))

        controller.present(menu: menu)
        controller.run(controller.commands[0])
        controller.dismiss()
        XCTAssertFalse(controller.performPending(menu: menu))
        XCTAssertEqual(target.count, 1)
    }

    func testPaletteItemIsExcluded() {
        let target = Target()
        let menu = mainMenu([submenu("View", [item(L10n.tr("命令面板…"), target, key: "a", mask: [.command, .shift]), item("Other", target)])])
        let controller = CommandPaletteController()
        controller.present(menu: menu)
        XCTAssertEqual(controller.commands.map(\.title), ["Other"])
    }

    func testPaletteAndQuickOpenAreMutuallyExclusive() {
        let suite = "CommandPaletteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        state.hostWindow = window
        state.showCommandPalette()
        XCTAssertTrue(state.commandPalette.isPresented)
        state.showQuickOpen()
        XCTAssertFalse(state.commandPalette.isPresented)
        state.showCommandPalette()
        state.showCommandPalette()
        XCTAssertFalse(state.commandPalette.isPresented)
    }

    // MARK: Закреплённые и недавние

    private func cmd(_ title: String, _ index: Int) -> PaletteCommand {
        PaletteCommand(path: ["Menu", title], indexPath: [0, index], shortcut: "")
    }

    private func isolatedPreferences() -> (AppPreferences, UserDefaults, String) {
        let suite = "CommandPaletteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    func testEntriesWithEmptyQueryOrderPinnedRecentRest() {
        let all = (0..<6).map { cmd("C\($0)", $0) }
        let entries = CommandPaletteService.entries(all, query: "", pinned: [all[4].path, all[1].path], recent: [all[3].path, all[0].path])
        XCTAssertEqual(entries.map(\.command), [all[4], all[1], all[3], all[0], all[2], all[5]])
        XCTAssertEqual(entries.map(\.section), [.pinned, .pinned, .recent, .recent, .all, .all])
        XCTAssertEqual(entries.map(\.startsSection), [true, false, true, false, true, false])
        XCTAssertEqual(entries.map(\.isPinned), [true, true, false, false, false, false])
    }

    func testEntriesNeverShowCommandTwice() {
        let all = (0..<4).map { cmd("C\($0)", $0) }
        let entries = CommandPaletteService.entries(all, query: "", pinned: [all[2].path], recent: [all[2].path, all[1].path])
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(Set(entries.map(\.command.id)).count, 4)
        XCTAssertEqual(entries.first?.section, .pinned)
    }

    func testEntriesWithoutPinsOrRecentsHaveNoSections() {
        let all = (0..<3).map { cmd("C\($0)", $0) }
        let entries = CommandPaletteService.entries(all, query: " ", pinned: [], recent: [])
        XCTAssertEqual(entries.map(\.command), all)
        XCTAssertTrue(entries.allSatisfy { $0.section == nil && !$0.startsSection })
    }

    func testEntriesSkipStalePaths() {
        let all = (0..<3).map { cmd("C\($0)", $0) }
        let stale = ["Меню", "Нет"]
        let entries = CommandPaletteService.entries(all, query: "", pinned: [stale], recent: [stale, all[1].path])
        XCTAssertEqual(entries.map(\.command), [all[1], all[0], all[2]])
        XCTAssertEqual(entries.map(\.section), [.recent, .all, .all])
        let (preferences, defaults, suite) = isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.commandPalettePinned = [stale]
        let controller = CommandPaletteController()
        let menu = mainMenu([submenu("Menu", [item("C0", Target())])])
        controller.present(menu: menu, preferences: preferences)
        XCTAssertEqual(controller.entries.count, 1)
        XCTAssertEqual(preferences.commandPalettePinned, [stale])
    }

    func testEntriesRecentLimitKeepsOverflowInRest() {
        let all = (0..<9).map { cmd("C\($0)", $0) }
        let entries = CommandPaletteService.entries(all, query: "", pinned: [], recent: (0..<7).map { all[$0].path })
        XCTAssertEqual(entries.filter { $0.section == .recent }.count, 5)
        XCTAssertEqual(entries.filter { $0.section == .all }.map(\.command), [all[5], all[6], all[7], all[8]])
    }

    func testEntriesWithQueryIgnoresSectionsButMarksPins() {
        let all = [cmd("Save", 0), cmd("Save All", 1), cmd("Print", 2)]
        let entries = CommandPaletteService.entries(all, query: "save", pinned: [all[1].path], recent: [all[0].path])
        XCTAssertEqual(entries.map(\.command), CommandPaletteService.ranked(all, query: "save"))
        XCTAssertTrue(entries.allSatisfy { $0.section == nil && !$0.startsSection })
        XCTAssertEqual(entries.first { $0.command == all[1] }?.isPinned, true)
        XCTAssertEqual(entries.first { $0.command == all[0] }?.isPinned, false)
    }

    func testRecordingMovesDuplicateToFrontAndCapsAtFive() {
        let paths = (0..<5).map { ["M", "\($0)"] }
        XCTAssertEqual(CommandPaletteService.recording(paths[3], recent: paths, pinned: []), [paths[3], paths[0], paths[1], paths[2], paths[4]])
        XCTAssertEqual(CommandPaletteService.recording(["M", "new"], recent: paths, pinned: []), [["M", "new"]] + Array(paths.prefix(4)))
    }

    func testRecordingSkipsPinned() {
        let recent = [["M", "a"]]
        XCTAssertEqual(CommandPaletteService.recording(["M", "p"], recent: recent, pinned: [["M", "p"]]), recent)
    }

    func testTogglingPinAddsAtEndRemovesFromRecentAndUnpins() {
        let a = ["M", "a"], b = ["M", "b"]
        let pinned = CommandPaletteService.togglingPin(b, pinned: [a], recent: [b, a])
        XCTAssertEqual(pinned.pinned, [a, b])
        XCTAssertEqual(pinned.recent, [a])
        let unpinned = CommandPaletteService.togglingPin(a, pinned: [a, b], recent: [])
        XCTAssertEqual(unpinned.pinned, [b])
        XCTAssertEqual(unpinned.recent, [])
    }

    func testPerformPendingRecordsOnlyAfterRun() {
        let (preferences, defaults, suite) = isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = Target()
        let go = item("Go", target)
        let menu = mainMenu([submenu("View", [go, item("Pinned", target)])])
        let controller = CommandPaletteController()
        controller.present(menu: menu, preferences: preferences)
        let command = controller.commands[0]
        let pinnedCommand = controller.commands[1]
        controller.run(command)
        controller.dismiss()
        XCTAssertFalse(controller.performPending(menu: menu))
        XCTAssertEqual(preferences.commandPaletteRecent, [])

        controller.present(menu: menu, preferences: preferences)
        controller.run(command)
        go.isEnabled = false
        XCTAssertFalse(controller.performPending(menu: menu))
        XCTAssertEqual(preferences.commandPaletteRecent, [])
        go.isEnabled = true

        controller.present(menu: menu, preferences: preferences)
        controller.run(command)
        XCTAssertTrue(controller.performPending(menu: menu))
        XCTAssertEqual(target.count, 1)
        XCTAssertEqual(preferences.commandPaletteRecent, [command.path])

        preferences.commandPalettePinned = [pinnedCommand.path]
        controller.present(menu: menu, preferences: preferences)
        controller.run(pinnedCommand)
        XCTAssertTrue(controller.performPending(menu: menu))
        XCTAssertEqual(preferences.commandPaletteRecent, [command.path])
    }

    func testPinnedSurvivesNewPreferencesAndStaleAfterRename() {
        let (preferences, defaults, suite) = isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = Target()
        let second = item("Second", target)
        let menu = mainMenu([submenu("View", [item("First", target), second])])
        let controller = CommandPaletteController()
        controller.present(menu: menu, preferences: preferences)
        controller.togglePin(controller.commands[1])
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.commandPalettePinned, [[AppEnvironment.displayName, "Second"]])
        second.title = "Renamed"
        controller.dismiss()
        controller.present(menu: menu, preferences: reloaded)
        XCTAssertEqual(controller.entries.count, 2)
        XCTAssertTrue(controller.entries.allSatisfy { $0.section == nil && !$0.isPinned })
        XCTAssertEqual(reloaded.commandPalettePinned, [[AppEnvironment.displayName, "Second"]])
    }

    func testTogglePinViaControllerKeepsPreferencesAfterClose() {
        let (preferences, defaults, suite) = isolatedPreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = Target()
        let menu = mainMenu([submenu("View", [item("A", target), item("B", target)])])
        let controller = CommandPaletteController()
        controller.present(menu: menu, preferences: preferences)
        let a = controller.commands[0], b = controller.commands[1]
        controller.run(b)
        controller.togglePin(a)
        XCTAssertEqual(preferences.commandPalettePinned, [a.path])
        XCTAssertTrue(controller.performPending(menu: menu))
        XCTAssertEqual(preferences.commandPaletteRecent, [b.path])
    }
}
