import Foundation

struct DocumentStatistics: Equatable, Sendable {
    private static let hanCharacters = try! NSRegularExpression(pattern: "\\p{sc=Han}")
    let words: Int
    let characters: Int
    let charactersWithoutWhitespace: Int
    let lines: Int
    let readingMinutes: Int

    static func calculate(_ text: String, wordsPerMinute: Int = 200, readableText: String? = nil, isCancelled: () -> Bool = { false }) -> DocumentStatistics? {
        guard wordsPerMinute > 0 else { return nil }
        var characters = 0, withoutWhitespace = 0, lines = 1, scannedScalars = 0
        var previousWasCR = false
        for character in text {
            var whitespace = true
            for scalar in character.unicodeScalars {
                if scannedScalars.isMultiple(of: 4_096), isCancelled() { return nil }
                scannedScalars += 1
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { whitespace = false }
                let value = scalar.value
                if (value == 10 && !previousWasCR) || value == 13 || value == 0x2028 || value == 0x2029 { lines += 1 }
                previousWasCR = value == 13
            }
            characters += 1
            if !whitespace { withoutWhitespace += 1 }
        }
        guard let words = countWords(readableText ?? text, isCancelled: isCancelled) else { return nil }
        return DocumentStatistics(words: words, characters: characters, charactersWithoutWhitespace: withoutWhitespace,
                                  lines: lines, readingMinutes: words / wordsPerMinute + (words % wordsPerMinute == 0 ? 0 : 1))
    }

    private static func countWords(_ text: String, isCancelled: () -> Bool) -> Int? {
        let source = text as NSString
        var words = 0, cursor = 0
        func countBetweenIdeographs(_ range: NSRange) {
            guard range.length > 0, !isCancelled() else { return }
            let fragment = source.substring(with: range)
            fragment.enumerateSubstrings(in: fragment.startIndex..<fragment.endIndex, options: .byWords) { _, _, _, stop in
                if isCancelled() { stop = true } else { words += 1 }
            }
        }
        hanCharacters.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if isCancelled() { stop.pointee = true; return }
            guard let match else { return }
            countBetweenIdeographs(NSRange(location: cursor, length: match.range.location - cursor))
            words += 1
            cursor = NSMaxRange(match.range)
        }
        guard !isCancelled() else { return nil }
        countBetweenIdeographs(NSRange(location: cursor, length: source.length - cursor))
        return isCancelled() ? nil : words
    }
}
