import Foundation

/// Порядок обхода строк с клавиатуры: чистые функции, чтобы проверять без интерфейса.
enum SidebarKeyboardNavigation {
    /// Следующий элемент в плоском списке; на краях остаётся на месте.
    /// `current == nil` (или элемента уже нет) -> первый при +1, последний при -1.
    static func moved<ID: Equatable>(from current: ID?, offset: Int, in order: [ID]) -> ID? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return offset >= 0 ? order.first : order.last
        }
        return order[max(0, min(order.count - 1, index + offset))]
    }
}

/// Type-select: набор букв прыгает на следующую строку, имя которой начинается с набранного.
struct SidebarTypeSelect {
    static let resetInterval: TimeInterval = 1
    private(set) var buffer = ""
    private var lastInput: Date?

    /// Добавляет символы; через `resetInterval` после прошлого ввода буфер начинается заново.
    mutating func append(_ text: String, now: Date = Date()) {
        if let lastInput, now.timeIntervalSince(lastInput) > Self.resetInterval { buffer = "" }
        buffer += text
        lastInput = now
    }

    mutating func reset() { buffer = ""; lastInput = nil }

    /// Один печатный символ без Cmd/Ctrl/Opt (Shift допустим для заглавных).
    /// Пробел принимается лишь внутри уже начатого набора, иначе он остаётся кнопке (открыть строку).
    func accepts(_ characters: String, hasModifiers: Bool, now: Date = Date()) -> Bool {
        guard !hasModifiers, characters.count == 1, let scalar = characters.unicodeScalars.first else { return false }
        if scalar == " " {
            guard let lastInput else { return false }
            return !buffer.isEmpty && now.timeIntervalSince(lastInput) <= Self.resetInterval
        }
        // U+F700…U+F8FF — функциональные клавиши AppKit (стрелки, F1…), не текст.
        let isFunctionKey = (0xF700...0xF8FF).contains(scalar.value)
        let isControl = CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
        return !isFunctionKey && !isControl
    }

    /// Индекс совпадения. Один и тот же повторяемый символ ("aaa") переключает по кругу
    /// со следующей строки; расширяющийся префикс ("ab") остаётся на текущей, если она подходит.
    static func match(prefix: String, names: [String], current: Int?) -> Int? {
        guard !prefix.isEmpty, !names.isEmpty else { return nil }
        let cycling = Set(prefix.lowercased()).count == 1 && prefix.count > 1
        let key = cycling ? String(prefix.prefix(1)) : prefix
        let start = current.map { cycling || prefix.count == 1 ? $0 + 1 : $0 } ?? 0
        for step in 0..<names.count {
            let index = (start + step) % names.count
            if names[index].range(of: key, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                return index
            }
        }
        return nil
    }
}

/// Действие клавиш дерева папки.
enum FolderTreeKey { case left, right, `return` }
enum FolderTreeAction: Equatable {
    case toggle(URL)            // Return на каталоге в режиме дерева
    case showDirectory(URL)     // Return на каталоге в режиме списка
    case open(URL)              // Return на файле
    case expand(URL), collapse(URL)
    case focus(FolderWorkspaceVisibleRow.ID)
}

enum FolderTreeKeyResolver {
    /// `rows` — видимые строки в порядке показа; `row` должна быть строкой-записью.
    static func resolve(key: FolderTreeKey, row: FolderWorkspaceVisibleRow, rows: [FolderWorkspaceVisibleRow],
                        display: FolderWorkspaceStore.Display, isExpanded: Bool) -> FolderTreeAction? {
        guard case let .entry(entry) = row.content else { return nil }
        let isDirectory = entry.isDirectory && !entry.isSymbolicLink
        switch key {
        case .return:
            guard isDirectory else { return .open(entry.url) }
            return display == .tree ? .toggle(entry.url) : .showDirectory(entry.url)
        case .right:
            guard display == .tree, isDirectory else { return nil }
            if !isExpanded { return .expand(entry.url) }
            guard let index = rows.firstIndex(where: { $0.id == row.id }), index + 1 < rows.count,
                  case .entry = rows[index + 1].content, rows[index + 1].depth > row.depth else { return nil }
            return .focus(rows[index + 1].id)
        case .left:
            guard display == .tree else { return nil }
            if isDirectory && isExpanded { return .collapse(entry.url) }
            guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
            for candidate in rows[..<index].reversed() {
                if case .entry = candidate.content, candidate.depth < row.depth { return .focus(candidate.id) }
            }
            return nil
        }
    }
}

/// Quick Open: подписи строк результата.
enum QuickOpenRowText {
    static func title(_ item: FolderSearchController.QuickOpenItem) -> String {
        switch item {
        case let .folder(url): url.lastPathComponent
        case let .file(file): (file.relativePath as NSString).lastPathComponent
        }
    }
    static func subtitle(_ item: FolderSearchController.QuickOpenItem) -> String {
        switch item {
        case let .folder(url): url.path
        case let .file(file): file.relativePath
        }
    }
}

/// Текущий заголовок outline: последний, чей исходный диапазон начинается не позже каретки.
enum MarkdownOutlineCurrent {
    /// `headings` идут в порядке исходника; уже отфильтрованы по видимым уровням.
    static func headingID(in headings: [MarkdownHeading], caret: Int, isCurrent: Bool) -> Int? {
        guard isCurrent, caret >= 0 else { return nil }
        return headings.last(where: { $0.range.location <= caret })?.id
    }
}
