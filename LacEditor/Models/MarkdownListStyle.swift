import Foundation

enum MarkdownOrderedListStyle: String, CaseIterable, Codable, Sendable {
    case decimal, decimalLeadingZero = "decimal-leading-zero", cjkIdeographic = "cjk-ideographic"
    case hiragana, katakana, lowerAlpha = "lower-alpha", upperAlpha = "upper-alpha"
    case lowerGreek = "lower-greek", lowerRoman = "lower-roman", upperRoman = "upper-roman"

    func marker(_ ordinal: Int) -> String {
        let suffix = self == .cjkIdeographic || self == .hiragana || self == .katakana ? "、" : "."
        let value: String
        switch self {
        case .decimal:
            value = String(ordinal)
        case .decimalLeadingZero:
            let text = String(ordinal)
            if ordinal >= 0 && ordinal < 10 { value = "0" + text }
            else { value = text }
        case .cjkIdeographic:
            value = Self.chinese(ordinal)
        case .hiragana:
            value = Self.alphabetic(ordinal, symbols: Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわゐゑをん"))
        case .katakana:
            value = Self.alphabetic(ordinal, symbols: Array("アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヰヱヲン"))
        case .lowerAlpha:
            value = Self.alphabetic(ordinal, symbols: Array("abcdefghijklmnopqrstuvwxyz"))
        case .upperAlpha:
            value = Self.alphabetic(ordinal, symbols: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        case .lowerGreek:
            value = Self.alphabetic(ordinal, symbols: Array("αβγδεζηθικλμνξοπρστυφχψω"))
        case .lowerRoman, .upperRoman:
            value = Self.roman(ordinal, uppercase: self == .upperRoman)
        }
        return value + suffix
    }

    private static func alphabetic(_ ordinal: Int, symbols: [Character]) -> String {
        guard ordinal > 0 else { return String(ordinal) }
        var number = ordinal, result = ""
        while number > 0 {
            number -= 1
            result.insert(symbols[number % symbols.count], at: result.startIndex)
            number /= symbols.count
        }
        return result
    }

    private static func roman(_ ordinal: Int, uppercase: Bool) -> String {
        guard (1...3999).contains(ordinal) else { return String(ordinal) }
        let values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
        let symbols = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
        var number = ordinal, result = ""
        for (value, symbol) in zip(values, symbols) {
            while number >= value { result += symbol; number -= value }
        }
        return uppercase ? result : result.lowercased()
    }

    private static func chinese(_ ordinal: Int) -> String {
        let digits = Array("零一二三四五六七八九")
        if !(-9999...9999).contains(ordinal) {
            let decimalDigits = Array("〇一二三四五六七八九")
            return String(ordinal).map { character in
                character.wholeNumberValue.map { String(decimalDigits[$0]) } ?? String(character)
            }.joined()
        }
        if ordinal == 0 { return "零" }
        let number = abs(ordinal)
        let units = ["千", "百", "十", ""]
        let divisors = [1000, 100, 10, 1]
        var result = ordinal < 0 ? "負" : "", needsZero = false
        for (unit, divisor) in zip(units, divisors) {
            let digit = number / divisor % 10
            if digit == 0 {
                if !result.isEmpty && result != "負" { needsZero = true }
            } else {
                if needsZero { result += "零"; needsZero = false }
                if !(divisor == 10 && number >= 10 && number <= 19) { result.append(digits[digit]) }
                result += unit
            }
        }
        return result
    }
}

enum MarkdownUnorderedListStyle: String, CaseIterable, Codable, Sendable {
    case disc, circle, square, custom

    func marker(custom: String) -> String {
        switch self {
        case .disc: return "•"
        case .circle: return "◦"
        case .square: return "▪"
        case .custom: return custom.replacingOccurrences(of: "\0", with: "\u{fffd}")
        }
    }
}

struct MarkdownListStyles: Codable, Equatable, Sendable {
    var ordered: [Int: MarkdownOrderedListStyle] = [:]
    var unordered: [Int: MarkdownUnorderedListStyle] = [:]
    var customMarkers: [Int: String] = [:]

    func orderedStyle(at depth: Int) -> MarkdownOrderedListStyle? {
        var level = 0
        for key in ordered.keys where key > level && key <= depth { level = key }
        return level > 0 ? ordered[level] : nil
    }

    func unorderedMarker(at depth: Int) -> String? {
        var level = 0
        for key in unordered.keys where key > level && key <= depth { level = key }
        guard level > 0, let style = unordered[level] else { return nil }
        return style.marker(custom: customMarkers[level] ?? "")
    }

    func cssRules(depths: Set<Int>) -> String {
        var rules: [String] = []
        let resolved = MarkdownResolvedListStyles(self)
        for depth in depths.sorted() where depth > 0 {
            if let style = resolved.orderedStyle(at: depth) {
                rules.append("article li:has(>span[data-lac-list-depth=\"\(depth)\"][data-lac-list-kind=\"ordered\"]){list-style-type:\(style.rawValue)}")
            }
            if let (style, custom) = resolved.unorderedStyle(at: depth) {
                let value: String
                if style == .custom {
                    let escaped = custom.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
                    value = "\"" + escaped + "\""
                } else {
                    value = style.rawValue
                }
                rules.append("article li:has(>span[data-lac-list-depth=\"\(depth)\"][data-lac-list-kind=\"unordered\"]){list-style-type:\(value)}")
            }
        }
        return rules.joined(separator: "\n")
    }
}

struct MarkdownResolvedListStyles {
    private let ordered: [(Int, MarkdownOrderedListStyle)]
    private let unordered: [(Int, MarkdownUnorderedListStyle, String)]

    init(_ styles: MarkdownListStyles) {
        ordered = styles.ordered.filter { $0.key > 0 }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        unordered = styles.unordered.filter { $0.key > 0 }.map { ($0.key, $0.value, styles.customMarkers[$0.key] ?? "") }.sorted { $0.0 < $1.0 }
    }

    func orderedStyle(at depth: Int) -> MarkdownOrderedListStyle? {
        var low = 0, high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle].0 <= depth { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? ordered[low - 1].1 : nil
    }

    func unorderedStyle(at depth: Int) -> (MarkdownUnorderedListStyle, String)? {
        var low = 0, high = unordered.count
        while low < high {
            let middle = (low + high) / 2
            if unordered[middle].0 <= depth { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        return (unordered[low - 1].1, unordered[low - 1].2)
    }
}
