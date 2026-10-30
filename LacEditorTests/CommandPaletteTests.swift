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
}
