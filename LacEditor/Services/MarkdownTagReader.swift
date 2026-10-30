import Foundation
import Yams

enum MarkdownTagReader {
    struct Input: Encodable, Sendable {
        let id: UUID
        let frontMatter: String
    }

    enum Outcome: Equatable, Sendable {
        case tags([String])
        case invalid(String)
    }

    enum ReadError: Error { case invalidResult }

    static func read(_ inputs: [Input], isCancelled: () -> Bool = { false }) throws -> [UUID: Outcome] {
        guard Set(inputs.map(\.id)).count == inputs.count else { throw ReadError.invalidResult }
        var output: [UUID: Outcome] = [:]
        for input in inputs {
            if isCancelled() { throw CancellationError() }
            do {
                guard let mapping = try PandocExportService.yamlFrontMatter(input.frontMatter), let node = mapping["tags"] else {
                    output[input.id] = .tags([])
                    continue
                }
                func string(_ value: Node) -> String? {
                    guard value.tag == Tag(.str) else { return nil }
                    return value.scalar?.string
                }
                if let values = node.sequence {
                    var tags: [String] = []
                    for value in values {
                        if isCancelled() { throw CancellationError() }
                        guard let tag = string(value) else { throw ReadError.invalidResult }
                        tags.append(tag)
                    }
                    output[input.id] = .tags(tags)
                } else if let tag = string(node) {
                    output[input.id] = .tags([tag])
                } else {
                    throw ReadError.invalidResult
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                output[input.id] = .invalid(L10n.tr("无法读取 YAML 标签"))
            }
            if isCancelled() { throw CancellationError() }
        }
        if isCancelled() { throw CancellationError() }
        return output
    }
}

/// Встроенные `#теги` из TEXT-узлов общего cmark-разбора: тот же алгоритм для поиска, списка и оформления.
extension MarkdownTagReader {
    /// `range` включает «#»; `name` — тело без него.
    struct Inline: Equatable, Sendable {
        let name: String
        let range: NSRange
    }

    struct Parsed: Sendable {
        let frontMatterRange: NSRange?
        let yaml: Outcome?
        let inline: [Inline]
    }

    /// Дешёвый предфильтр без разбора: `#` не после буквы/цифры/`_-/&\#`, а за ним буква, цифра, `_` или не-ASCII символ.
    /// Надмножество настоящего правила: файл без такого `#` не разбирается cmark вообще.
    static func hasCandidate(_ text: String, isCancelled: () -> Bool = { false }) throws -> Bool {
        var count = 0
        var afterHash = false
        var previous: UInt8 = 0x20
        for byte in text.utf8 {
            count += 1
            if count & 0xFFFF == 0, isCancelled() { throw CancellationError() }
            if afterHash {
                afterHash = false
                if byte >= 0x80 || byte == 0x5F || (byte >= 0x30 && byte <= 0x39) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) { return true }
            }
            if byte == 0x23 {
                let blocked = previous < 0x80 && (previous == 0x5F || previous == 0x2D || previous == 0x2F || previous == 0x26 || previous == 0x5C
                    || previous == 0x23 || (previous >= 0x30 && previous <= 0x39) || (previous | 0x20 >= 0x61 && previous | 0x20 <= 0x7A))
                afterHash = !blocked
            }
            previous = byte
        }
        return false
    }

    static func read(text: String, isCancelled: () -> Bool = { false }) throws -> Parsed {
        if isCancelled() { throw CancellationError() }
        let frontMatter = MarkdownPresentationParser.frontMatter(text)
        var yaml: Outcome?
        if let frontMatter {
            let id = UUID()
            let raw = (text as NSString).substring(with: frontMatter.range)
            yaml = try read([Input(id: id, frontMatter: raw)], isCancelled: isCancelled)[id]
        }
        var inline: [Inline] = []
        if try hasCandidate(text, isCancelled: isCancelled) {
            let presentation = withoutActuallyEscaping(isCancelled) { escaping in
                MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeWikiLinks: true, isCancelled: escaping)
            }
            // При отмене разбор возвращает пустую презентацию: это не «тегов нет».
            if isCancelled() { throw CancellationError() }
            inline = try inlineTags(in: text as NSString, textRanges: presentation.emojiCompletionRanges,
                                    excluding: presentation.links.map(\.range) + presentation.wikiLinks.map(\.range), isCancelled: isCancelled)
        }
        return Parsed(frontMatterRange: frontMatter?.range, yaml: yaml, inline: inline)
    }

    /// Один ведущий «#» у запроса и YAML-значения не учитывается.
    static func normalized(_ query: String) -> String {
        query.hasPrefix("#") ? String(query.dropFirst()) : query
    }

    /// Целый тег без учёта регистра; `a` находит `a` и `a/b`, но не `ab` и не `b/a`.
    static func matches(tag: String, query: String) -> Bool {
        let query = normalized(query) as NSString, tag = normalized(tag) as NSString
        guard query.length > 0 else { return false }
        let found = tag.range(of: query as String, options: [.anchored, .caseInsensitive, .literal])
        guard found.location != NSNotFound else { return false }
        return NSMaxRange(found) == tag.length || tag.character(at: NSMaxRange(found)) == 0x2F
    }

    /// `textRanges` — куски TEXT, совпадающие с исходником один в один; `excluding` — ссылки.
    static func inlineTags(in text: NSString, textRanges: [NSRange], excluding: [NSRange],
                           isCancelled: () -> Bool = { false }) throws -> [Inline] {
        let blocked = excluding.sorted { $0.location < $1.location }
        var blockedEnds: [Int] = []
        var maximum = 0
        for range in blocked { maximum = max(maximum, NSMaxRange(range)); blockedEnds.append(maximum) }
        func isBlocked(_ range: NSRange) -> Bool {
            var low = 0, high = blockedEnds.count
            while low < high {
                let middle = (low + high) / 2
                if blockedEnds[middle] <= range.location { low = middle + 1 } else { high = middle }
            }
            while low < blocked.count && blocked[low].location < NSMaxRange(range) {
                if NSIntersectionRange(blocked[low], range).length > 0 { return true }
                low += 1
            }
            return false
        }
        var output: [Inline] = []
        for piece in textRanges {
            if isCancelled() { throw CancellationError() }
            guard piece.location >= 0, piece.length > 0, NSMaxRange(piece) <= text.length else { continue }
            var position = piece.location
            let end = NSMaxRange(piece)
            while position < end {
                guard text.character(at: position) == 0x23 else { position += 1; continue }
                if let tag = inlineTag(at: position, pieceEnd: end, in: text), !isBlocked(tag.range) {
                    output.append(tag)
                    position = NSMaxRange(tag.range)
                } else {
                    position += 1
                }
            }
        }
        return output
    }

    private static func scalar(in text: NSString, at index: Int, limit: Int) -> (value: Unicode.Scalar, length: Int)? {
        let unit = text.character(at: index)
        if UTF16.isLeadSurrogate(unit) {
            guard index + 1 < limit else { return nil }
            let low = text.character(at: index + 1)
            guard UTF16.isTrailSurrogate(low) else { return nil }
            let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
            return Unicode.Scalar(value).map { ($0, 2) }
        }
        return Unicode.Scalar(UInt32(unit)).map { ($0, 1) }
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Han, кана и хангыль пишутся без пробелов между словами: перед `#` они допустимы.
    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    private static func leftAllows(_ text: NSString, before start: Int) -> Bool {
        guard start > 0 else { return true }
        let sequence = text.rangeOfComposedCharacterSequence(at: start - 1)
        guard let first = scalar(in: text, at: sequence.location, limit: start)?.value else { return false }
        if first.properties.isWhitespace { return true }
        if "#/-_&\\".unicodeScalars.contains(first) { return false }
        if isUnspacedScript(first) { return true }
        switch first.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
        default: return false
        }
    }

    private static func inlineTag(at start: Int, pieceEnd: Int, in text: NSString) -> Inline? {
        guard leftAllows(text, before: start) else { return nil }
        var position = start + 1
        var keptEnd = position
        var hasLetter = false
        var previousSlash = false
        var isFirst = true
        while position < pieceEnd, let (value, length) = scalar(in: text, at: position, limit: pieceEnd) {
            let isUnderscore = value == "_", isDash = value == "-", isSlash = value == "/"
            if isFirst {
                guard isLetterOrNumber(value) || isUnderscore else { return nil }
            } else if !(isLetterOrNumber(value) || isMark(value) || isUnderscore || isDash || isSlash) {
                break
            }
            if isSlash {
                if previousSlash { return nil }
            } else if isLetter(value) || isUnderscore {
                hasLetter = true
            }
            previousSlash = isSlash
            isFirst = false
            position += length
            if !isDash && !isSlash { keptEnd = position }
        }
        guard keptEnd > start + 1, hasLetter else { return nil }
        // Исходник продолжается экранированием, сущностью или словом, которых нет в куске: тег не угадываем.
        if position < text.length {
            let next = text.character(at: position)
            if next == 0x5C || next == 0x26 || next == 0x23 { return nil }
            if position == pieceEnd, let (value, _) = scalar(in: text, at: position, limit: text.length),
               isLetterOrNumber(value) || isMark(value) || value == "_" || value == "-" || value == "/" { return nil }
        }
        let range = NSRange(location: start, length: keptEnd - start)
        return Inline(name: text.substring(with: NSRange(location: start + 1, length: keptEnd - start - 1)), range: range)
    }
}
