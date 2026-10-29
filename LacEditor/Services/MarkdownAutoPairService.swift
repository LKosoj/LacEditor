import Foundation

enum MarkdownAutoPairService {
    struct Pair: Equatable {
        var open: Int
        var close: Int
        let opener: UInt16
        let closer: UInt16
        var count: Int
    }

    enum Action {
        case replace(range: NSRange, text: String, selection: NSRange, pair: Pair)
        case skip(Int)
    }

    static func action(in text: NSString, selection: NSRange, character: String,
                       brackets: Bool, markdown: Bool, pairs: [Pair]) -> Action? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              selection.location <= text.length, selection.length <= text.length - selection.location,
              character.utf16.count == 1, let unit = character.utf16.first else { return nil }
        if (unit == 126 || unit == 94 || unit == 61) && selection.length == 0 { return nil }
        let closes: [UInt16: UInt16] = [40: 41, 91: 93, 123: 125, 34: 34, 39: 39, 42: 42, 95: 95, 96: 96, 126: 126, 94: 94, 61: 61, 36: 36]
        guard let opener = closes[unit] != nil ? unit : closes.first(where: { $0.value == unit })?.key,
              let closer = closes[opener], (opener == 40 || opener == 91 || opener == 123 || opener == 34 || opener == 39 ? brackets : markdown),
              !isEscaped(text, at: selection.location),
              isBoundary(text, at: selection.location), isBoundary(text, at: NSMaxRange(selection)) else { return nil }
        if selection.length == 0, let existing = pairs.last(where: { $0.close == selection.location && $0.closer == unit }),
           existing.close + existing.count <= text.length,
           text.substring(with: NSRange(location: existing.open, length: existing.count)) == String(repeating: String(UnicodeScalar(existing.opener)!), count: existing.count),
           text.substring(with: NSRange(location: existing.close, length: existing.count)) == String(repeating: String(UnicodeScalar(existing.closer)!), count: existing.count) {
            if (unit == 42 || unit == 95), existing.count == 1, existing.close == existing.open + 1 {
                let value = String(repeating: character, count: 4)
                let pair = Pair(open: existing.open, close: existing.open + 2, opener: unit, closer: unit, count: 2)
                return .replace(range: NSRange(location: existing.open, length: 2), text: value,
                                selection: NSRange(location: existing.open + 2, length: 0), pair: pair)
            }
            return .skip(selection.location + 1)
        }
        guard !ListContinuationService.isCodeContext(in: text, at: selection.location),
              !intersectsInlineCode(in: text, selection: selection), unit == opener else { return nil }
        if selection.length == 0 && selection.location > 0 && (unit == 95 || unit == 42 || unit == 34 || unit == 39) {
            let previous = text.substring(with: text.rangeOfComposedCharacterSequence(at: selection.location - 1))
            if previous.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { return nil }
        }
        if unit == 96, selection.length == 0, selection.location > 0, text.character(at: selection.location - 1) == 96 { return nil }
        if selection.length == 0, selection.location < text.length {
            let next = text.substring(with: text.rangeOfComposedCharacterSequence(at: selection.location))
            if next.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { return nil }
        }
        let selected = text.substring(with: selection)
        guard selected.rangeOfCharacter(from: .newlines) == nil else { return nil }
        let left = String(UnicodeScalar(opener)!), right = String(UnicodeScalar(closer)!)
        let pair = Pair(open: selection.location, close: selection.location + 1 + selection.length, opener: opener, closer: closer, count: 1)
        return .replace(range: selection, text: left + selected + right,
                        selection: NSRange(location: selection.location + 1, length: selection.length), pair: pair)
    }

    private static func isBoundary(_ text: NSString, at position: Int) -> Bool {
        guard position > 0, position < text.length else { return true }
        return text.rangeOfComposedCharacterSequence(at: position).location == position
    }

    private static func isEscaped(_ text: NSString, at location: Int) -> Bool {
        var i = location, count = 0
        while i > 0 && text.character(at: i - 1) == 92 { count += 1; i -= 1 }
        return count % 2 == 1
    }

    private static func intersectsInlineCode(in text: NSString, selection: NSRange) -> Bool {
        // Inline code can span lines of the same paragraph.
        var start = selection.location
        while start > 0 {
            let c = text.character(at: start - 1)
            if c == 10 || c == 13 {
                var previous = start - 1
                if c == 10 && previous > 0 && text.character(at: previous - 1) == 13 { previous -= 1 }
                if previous == 0 || text.character(at: previous - 1) == 10 || text.character(at: previous - 1) == 13 { break }
            }
            start -= 1
        }
        var cursor = start, run = 0
        let end = NSMaxRange(selection)
        while cursor < end {
            if cursor >= selection.location && run != 0 { return true }
            if text.character(at: cursor) == 96 && !isEscaped(text, at: cursor) {
                var count = 0
                while cursor + count < text.length && text.character(at: cursor + count) == 96 { count += 1 }
                if cursor + count > selection.location && cursor < end { return true }
                if run == 0 { run = count } else if run == count { run = 0 }
                cursor += count
            } else { cursor += 1 }
        }
        return run != 0
    }
}
