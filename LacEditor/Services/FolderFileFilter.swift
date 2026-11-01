import Foundation

/// Маска файлов поиска по папке: «*.md, docs/**, !node_modules».
/// Без `/` правило сравнивается с именем, с `/` — с относительным путём; `!` исключает.
struct FolderFileFilter: Equatable, @unchecked Sendable {
    private struct Rule {
        let source: String
        let isExclusion: Bool
        let hasSlash: Bool
        let regex: NSRegularExpression
    }

    private let rules: [Rule]

    init(_ mask: String) {
        rules = mask.split(separator: ",", omittingEmptySubsequences: true).compactMap { Self.rule(String($0)) }
    }

    static func == (lhs: FolderFileFilter, rhs: FolderFileFilter) -> Bool {
        lhs.rules.map { "\($0.isExclusion)|\($0.source)" } == rhs.rules.map { "\($0.isExclusion)|\($0.source)" }
    }

    var isEmpty: Bool { rules.isEmpty }

    /// Файл проходит, если его не задело ни одно исключение и (при наличии положительных правил) сработало хотя бы одно из них.
    func includes(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return true }
        let directories = Array(components.dropLast())
        for rule in rules where rule.isExclusion {
            if rule.hasSlash {
                if Self.matches(rule, relativePath) || Self.matchesPrefix(rule, directories) { return false }
            } else if Self.matches(rule, name) || directories.contains(where: { Self.matches(rule, $0) }) {
                return false
            }
        }
        let positives = rules.filter { !$0.isExclusion }
        if positives.isEmpty { return true }
        return positives.contains { Self.matches($0, $0.hasSlash ? relativePath : name) }
    }

    /// Каталог исключён целиком: его не нужно обходить.
    func excludesDirectory(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        for rule in rules where rule.isExclusion {
            if rule.hasSlash {
                if Self.matchesPrefix(rule, components) { return true }
            } else if components.contains(where: { Self.matches(rule, $0) }) {
                return true
            }
        }
        return false
    }

    /// Правило с `/` против каждого начального отрезка цепочки каталогов.
    private static func matchesPrefix(_ rule: Rule, _ directories: [String]) -> Bool {
        guard !directories.isEmpty else { return false }
        for count in 1...directories.count where matches(rule, directories.prefix(count).joined(separator: "/")) {
            return true
        }
        return false
    }

    private static func matches(_ rule: Rule, _ value: String) -> Bool {
        rule.regex.firstMatch(in: value, options: [], range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private static func rule(_ raw: String) -> Rule? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        let isExclusion = text.hasPrefix("!")
        if isExclusion { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        while text.hasPrefix("./") { text.removeFirst(2) }
        while text.hasPrefix("/") { text.removeFirst() }
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        var pattern = "^"
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        pattern += "(?:.*/)?"
                        index += 3
                    } else {
                        pattern += ".*"
                        index += 2
                    }
                } else {
                    pattern += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                pattern += "[^/]"
                index += 1
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }
        pattern += "$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return Rule(source: text, isExclusion: isExclusion, hasSlash: text.contains("/"), regex: regex)
    }
}
