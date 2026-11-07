import Foundation

enum EmojiShortcodeResolver {
    enum ResolveError: Error { case invalidName, invalidOutput }

    private struct Entry: Decodable {
        let emoji: String
        let aliases: [String]
    }

    private static let catalogData: Result<Data, Error> = Result {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "emoji", withExtension: "json", subdirectory: "Gemoji") else {
            throw ResolveError.invalidOutput
        }
        return try Data(contentsOf: url)
    }

    private static let catalog: Result<[String: String], Error> = Result { try readCatalog(catalogData.get()) }

    static func readCatalog(_ data: Data) throws -> [String: String] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var values: [String: String] = [:]
        for entry in entries {
            guard !entry.emoji.isEmpty else { throw ResolveError.invalidOutput }
            for alias in entry.aliases {
                guard validName(alias), values[alias] == nil else { throw ResolveError.invalidOutput }
                values[alias] = entry.emoji
            }
        }
        guard !values.isEmpty else { throw ResolveError.invalidOutput }
        return values
    }

    private static func validName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-")
        return !name.isEmpty && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let sortedNames: Result<[String], Error> = Result { try catalog.get().keys.sorted() }

    static func completions(prefix: String) throws -> [String] {
        guard prefix.isEmpty || validName(prefix) else { return [] }
        let names = try sortedNames.get()
        var low = 0, high = names.count
        while low < high {
            let middle = (low + high) / 2
            if names[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        let start = low
        while low < names.count && names[low].hasPrefix(prefix) { low += 1 }
        return Array(names[start..<low])
    }

    // Most used emoji first (Unicode emoji frequency data), then the catalog order, which keeps faces and gestures early.
    private static let popular = ["joy", "heart", "rofl", "+1", "sob", "pray", "kissing_heart", "smiling_face_with_three_hearts",
        "heart_eyes", "blush", "tada", "grin", "two_hearts", "pleading_face", "sweat_smile", "fire", "relaxed", "facepalm",
        "hearts", "shrug", "roll_eyes", "laughing", "hugs", "wink", "birthday", "thinking", "clap", "slightly_smiling_face",
        "flushed", "partying_face", "sunglasses", "ok_hand", "purple_heart", "pensive", "muscle", "sparkles", "sparkling_heart",
        "eyes", "yum", "smirk", "cry", "point_right", "heartpulse", "weary", "100", "rose", "revolving_hearts", "balloon",
        "blue_heart", "smiley"]

    private static func readRanks(_ data: Data) throws -> [String: Int] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let order = Dictionary(uniqueKeysWithValues: popular.enumerated().map { ($0.element, $0.offset) })
        var ranks: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let rank = entry.aliases.compactMap { order[$0] }.min() ?? popular.count + index
            for alias in entry.aliases where ranks[alias] == nil { ranks[alias] = rank }
        }
        return ranks
    }

    private static let ranks: Result<[String: Int], Error> = Result { try readRanks(catalogData.get()) }

    /// Suggestions for the editor: matching names, most popular first, at most `limit`.
    static func popularCompletions(prefix: String, limit: Int = 20) throws -> [String] {
        let names = try completions(prefix: prefix), ranks = try ranks.get()
        return Array(names.sorted { (ranks[$0] ?? .max, $0) < (ranks[$1] ?? .max, $1) }.prefix(limit))
    }

    /// True when `text` contains a `:name:` spelling of a known emoji.
    static func containsShortcode(_ text: String) -> Bool {
        guard text.contains(":"), let values = try? catalog.get() else { return false }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return false }
        return parts.dropFirst().dropLast().contains { values[String($0)] != nil }
    }

    // Produces an export snapshot while leaving the original Markdown untouched.
    static func prepareMarkdown(_ markdown: String,
                                isCancelled: @escaping () -> Bool = { false }) throws -> String {
        if isCancelled() { throw CancellationError() }
        guard markdown.contains(":") else { return markdown }
        let model = MarkdownDocumentParser.parseOrEmpty(markdown, includes: [.emoji], isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        guard let queries = model.queries(.emoji, isCancelled: isCancelled), !isCancelled() else { throw CancellationError() }
        let candidates = queries.emojiCandidates
        guard !candidates.isEmpty else { return markdown }
        let values = try resolve(candidates.map(\.name), isCancelled: isCancelled)
        let result = NSMutableString(string: markdown)
        for candidate in candidates.reversed() {
            if isCancelled() { throw CancellationError() }
            guard let value = values[candidate.name], candidate.range.location >= 0,
                  NSMaxRange(candidate.range) <= result.length else { continue }
            result.replaceCharacters(in: candidate.range, with: value)
        }
        return result as String
    }

    // Call off the main thread. Names do not include their surrounding colons.
    static func resolve(_ names: [String], isCancelled: () -> Bool = { false }) throws -> [String: String] {
        if isCancelled() { throw CancellationError() }
        for name in names {
            if isCancelled() { throw CancellationError() }
            guard validName(name) else { throw ResolveError.invalidName }
        }
        guard !names.isEmpty else { return [:] }
        let values = try catalog.get()
        var result: [String: String] = [:]
        for name in names {
            if isCancelled() { throw CancellationError() }
            if let value = values[name] { result[name] = value }
        }
        return result
    }
}
