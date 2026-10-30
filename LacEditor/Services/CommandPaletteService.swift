import AppKit

/// Пункт главного меню в палитре команд: путь по меню и путь индексов для повторной проверки перед выполнением.
struct PaletteCommand: Identifiable, Equatable {
    let path: [String]
    let indexPath: [Int]
    let shortcut: String

    var id: String { indexPath.map(String.init).joined(separator: ".") }
    var title: String { path.last ?? "" }
    var subtitle: String { path.dropLast().joined(separator: " › ") }
    var fullTitle: String { path.joined(separator: " › ") }
}

@MainActor
enum CommandPaletteService {
    /// Обходит меню в порядке показа; недоступные, скрытые, служебные и системные подменю пропускаются.
    static func collect(from menu: NSMenu?, excluding: (NSMenuItem) -> Bool = { _ in false }) -> [PaletteCommand] {
        guard let menu else { return [] }
        var result: [PaletteCommand] = []
        walk(menu, path: [], indexPath: [], excluding: excluding, into: &result)
        return result
    }

    private static func walk(_ menu: NSMenu, path: [String], indexPath: [Int],
                             excluding: (NSMenuItem) -> Bool, into result: inout [PaletteCommand]) {
        // SwiftUI и AppKit обновляют доступность пунктов лениво
        menu.update()
        for (index, item) in menu.items.enumerated() {
            // меню приложения SwiftUI может создать с пустым названием
            let title = path.isEmpty && index == 0 ? AppEnvironment.displayName : item.title
            guard isCandidate(item, title: title), !excluding(item) else { continue }
            if let submenu = item.submenu {
                if submenu === NSApplication.shared.servicesMenu || submenu === NSApplication.shared.windowsMenu { continue }
                walk(submenu, path: path + [title], indexPath: indexPath + [index], excluding: excluding, into: &result)
            } else if item.action != nil {
                result.append(PaletteCommand(path: path + [title], indexPath: indexPath + [index],
                                             shortcut: shortcutText(for: item)))
            }
        }
    }

    private static func isCandidate(_ item: NSMenuItem, title: String) -> Bool {
        !item.isSeparatorItem && !item.isHidden && !item.isHiddenOrHasHiddenAncestor && !item.isAlternate
            && item.isEnabled && !title.isEmpty
    }

    /// Пустой запрос сохраняет порядок меню; иначе ранг общей функции быстрого открытия, при равенстве — порядок меню.
    static func ranked(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commands }
        let matcher = FolderSearchService.NameQuery(trimmed, caseSensitive: false)
        var scored: [(PaletteCommand, Int, Int)] = []
        for (index, command) in commands.enumerated() {
            if let rank = try? matcher.rank(path: command.fullTitle, name: command.title) {
                scored.append((command, rank, index))
            }
        }
        scored.sort { ($0.1, $0.2) < ($1.1, $1.2) }
        return scored.map(\.0)
    }

    static let recentLimit = 5

    enum Section { case pinned, recent, all }

    /// Строка списка: команда, её секция (nil при поиске или без секций) и признаки для отрисовки.
    struct Entry: Equatable {
        let command: PaletteCommand
        let section: Section?
        let isPinned: Bool
        let startsSection: Bool
    }

    /// Пустой запрос: закреплённые, недавние, остальные (без повторов). Устаревшие пути молча пропускаются.
    /// Непустой запрос: обычный `ranked` без секций.
    static func entries(_ commands: [PaletteCommand], query: String, pinned: [[String]], recent: [[String]]) -> [Entry] {
        let pinnedSet = Set(pinned)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else {
            return ranked(commands, query: query).map {
                Entry(command: $0, section: nil, isPinned: pinnedSet.contains($0.path), startsSection: false)
            }
        }
        var byPath: [[String]: PaletteCommand] = [:]
        for command in commands where byPath[command.path] == nil { byPath[command.path] = command }
        var pinnedCommands: [PaletteCommand] = []
        var shown = Set<String>()
        for path in pinned {
            if let command = byPath[path], shown.insert(command.id).inserted { pinnedCommands.append(command) }
        }
        var recentCommands: [PaletteCommand] = []
        for path in recent where recentCommands.count < recentLimit {
            if let command = byPath[path], shown.insert(command.id).inserted { recentCommands.append(command) }
        }
        let others = commands.filter { !shown.contains($0.id) }
        let hasHeaders = !pinnedCommands.isEmpty || !recentCommands.isEmpty
        func make(_ list: [PaletteCommand], _ section: Section) -> [Entry] {
            list.enumerated().map { index, command in
                Entry(command: command, section: hasHeaders ? section : nil, isPinned: pinnedSet.contains(command.path),
                      startsSection: hasHeaders && index == 0)
            }
        }
        return make(pinnedCommands, .pinned) + make(recentCommands, .recent) + make(others, .all)
    }

    /// Недавние после запуска: закреплённая не записывается, дубль поднимается наверх, не больше `recentLimit`.
    static func recording(_ path: [String], recent: [[String]], pinned: [[String]]) -> [[String]] {
        guard !pinned.contains(path) else { return recent }
        return Array(([path] + recent.filter { $0 != path }).prefix(recentLimit))
    }

    /// Закрепляет (в конец) либо открепляет; при закреплении убирает запись из недавних.
    static func togglingPin(_ path: [String], pinned: [[String]], recent: [[String]]) -> (pinned: [[String]], recent: [[String]]) {
        if pinned.contains(path) { return (pinned.filter { $0 != path }, recent) }
        return (pinned + [path], recent.filter { $0 != path })
    }

    /// Порядок символов как в меню macOS: ⌃⌥⇧⌘ и клавиша.
    static func shortcutText(for item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        let arrows: [Int: String] = [NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓",
                                     NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→"]
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, let arrow = arrows[Int(scalar.value)] {
            return text + arrow
        }
        switch key {
        case "\r", "\u{3}": return text + "↩"
        case "\u{8}", "\u{7F}": return text + "⌫"
        case "\t": return text + "⇥"
        case "\u{1B}": return text + "⎋"
        case " ": return text + "Space"
        default: return text + key.uppercased()
        }
    }

    /// Тот же пункт в актуальном меню: на месте, виден, доступен и с прежним названием; иначе nil.
    static func resolve(_ command: PaletteCommand, in menu: NSMenu?) -> NSMenuItem? {
        guard var current = menu, !command.indexPath.isEmpty else { return nil }
        var item: NSMenuItem?
        for index in command.indexPath {
            current.update()
            guard current.items.indices.contains(index) else { return nil }
            let next = current.items[index]
            item = next
            if let submenu = next.submenu { current = submenu }
        }
        guard let item, isCandidate(item, title: item.title), item.submenu == nil, item.action != nil,
              item.menu != nil, item.title == command.title else { return nil }
        return item
    }

    @MainActor
    static func perform(_ command: PaletteCommand, menu: NSMenu?) -> Bool {
        guard let item = resolve(command, in: menu), let owner = item.menu else { return false }
        let index = owner.index(of: item)
        guard index >= 0 else { return false }
        owner.performActionForItem(at: index)
        return true
    }

    /// Сам пункт палитры в списке не нужен.
    static func isPaletteItem(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent.lowercased() == "a"
            && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
    }
}

/// Состояние палитры окна: снимок команд на момент открытия и отложенный выбор.
@MainActor
final class CommandPaletteController: ObservableObject {
    @Published private(set) var request: UUID?
    @Published var query = ""
    @Published private(set) var commands: [PaletteCommand] = []
    private var pending: PaletteCommand?
    /// Общие настройки для закреплённых и недавних; при `close()` не сбрасываются, т.к. `performPending` идёт после закрытия.
    private var preferences: AppPreferences?

    var isPresented: Bool { request != nil }
    var entries: [CommandPaletteService.Entry] {
        CommandPaletteService.entries(commands, query: query,
                                      pinned: preferences?.commandPalettePinned ?? [],
                                      recent: preferences?.commandPaletteRecent ?? [])
    }
    var results: [PaletteCommand] { entries.map(\.command) }

    func present(menu: NSMenu?, preferences: AppPreferences? = nil,
                 excluding: (NSMenuItem) -> Bool = CommandPaletteService.isPaletteItem) {
        self.preferences = preferences
        commands = CommandPaletteService.collect(from: menu, excluding: excluding)
        query = ""
        pending = nil
        request = UUID()
    }

    func dismiss() {
        pending = nil
        close()
    }

    /// Закрывает панель; действие выполнит `performPending` уже после возврата фокуса.
    func run(_ command: PaletteCommand) {
        pending = command
        close()
    }

    @discardableResult
    func performPending(menu: NSMenu?) -> Bool {
        guard let command = pending else { return false }
        pending = nil
        guard CommandPaletteService.perform(command, menu: menu) else { return false }
        if let preferences {
            preferences.commandPaletteRecent = CommandPaletteService.recording(
                command.path, recent: preferences.commandPaletteRecent, pinned: preferences.commandPalettePinned)
        }
        return true
    }

    func togglePin(_ command: PaletteCommand) {
        guard let preferences else { return }
        let updated = CommandPaletteService.togglingPin(command.path, pinned: preferences.commandPalettePinned,
                                                        recent: preferences.commandPaletteRecent)
        preferences.commandPalettePinned = updated.pinned
        preferences.commandPaletteRecent = updated.recent
    }

    private func close() {
        guard request != nil else { return }
        request = nil
        commands = []
        query = ""
    }
}
