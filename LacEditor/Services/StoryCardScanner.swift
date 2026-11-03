import Foundation

struct StoryCardScanCache: Sendable {
    struct Entry: Sendable {
        let mtime: Date
        let size: Int
        let card: StoryCard?
    }

    var entries: [String: Entry] = [:]
}

enum StoryCardScanner {
    /// Сколько байт файла читается для разбора шапки и названия.
    static let headBytes = 16 * 1024

    /// Читает карточки из папки проекта. Файлы рукописи (`excluding` — их относительные пути) пропускаются.
    /// Файл, не менявшийся с прошлого раза (время и размер), берётся из кэша без чтения.
    static func scan(root: URL, excluding manuscriptPaths: Set<String>, cache: inout StoryCardScanCache,
                     isCancelled: () -> Bool = { false }) -> [StoryCard] {
        guard let listing = try? FolderSearchService.listing(root: root, isCancelled: isCancelled) else { return [] }
        var next: [String: StoryCardScanCache.Entry] = [:]
        var cards: [StoryCard] = []
        for listed in listing.values {
            if isCancelled() { return [] }
            let file = listed.file
            guard ["md", "markdown"].contains(file.url.pathExtension.lowercased()), !listed.isSymbolicLink,
                  !manuscriptPaths.contains(file.relativePath) else { continue }
            let mtime = listed.modificationDate ?? .distantPast
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let entry: StoryCardScanCache.Entry
            if let cached = cache.entries[file.relativePath], cached.mtime == mtime, cached.size == size {
                entry = cached
            } else {
                entry = StoryCardScanCache.Entry(mtime: mtime, size: size, card: readCard(file.url, root: listing.root))
            }
            next[file.relativePath] = entry
            if let card = entry.card { cards.append(card) }
        }
        cache.entries = next
        cards.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        // Скопированная карточка с тем же id не должна ломать список: у повтора остаётся ключ-путь.
        var ids = Set<UUID>()
        for index in cards.indices {
            if let id = cards[index].cardID, !ids.insert(id).inserted { cards[index].cardID = nil }
        }
        return cards
    }

    /// Начало файла разбирается как карточка; файл без шапки пропускается без разбора.
    static func readCard(_ url: URL, root: URL) -> StoryCard? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard text.hasPrefix("---") else { return nil }
        // Обрезанная строка в конце не должна давать неполное название.
        if data.count == headBytes, let cut = text.lastIndex(where: { $0 == "\n" || $0 == "\r" }) { text = String(text[...cut]) }
        return StoryCardHeader.parse(text, url: url, root: root)
    }
}
