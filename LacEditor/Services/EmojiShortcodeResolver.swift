import Foundation

enum EmojiShortcodeResolver {
    enum ResolveError: Error { case invalidName, invalidOutput }

    private struct Entry: Decodable {
        let emoji: String
        let aliases: [String]
    }

    private static let catalog: Result<[String: String], Error> = Result {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "emoji", withExtension: "json", subdirectory: "Gemoji") else {
            throw ResolveError.invalidOutput
        }
        return try readCatalog(Data(contentsOf: url))
    }

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

    // Produces an export snapshot while leaving the original Markdown untouched.
    static func prepareMarkdown(_ markdown: String,
                                isCancelled: @escaping () -> Bool = { false }) throws -> String {
        if isCancelled() { throw CancellationError() }
        guard markdown.contains(":") else { return markdown }
        let presentation = MarkdownPresentationParser.parse(markdown, includeEmojiCandidates: true, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        let candidates = presentation.emojiCandidates
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
