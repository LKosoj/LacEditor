import Foundation

/// Projects a confirmed code-block body into document UTF-16 coordinates.
enum MarkdownCodeHighlightService {
    private static let pseudocodePattern = try? NSRegularExpression(
        pattern: #"(?im)//[^\r\n]*|#[^\r\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:if|then|else|elseif|endif|for|each|to|downto|while|do|endwhile|repeat|until|return|function|procedure|begin|end|and|or|not|true|false)\b|\b\d+(?:\.\d+)?\b|<--|<->|-->|<-|->|:=|<=|>=|!=|=="#
    )

    private static func pseudocodeTokens(_ text: String, isCancelled: () -> Bool) -> [SyntaxHighlighter.Token]? {
        guard let pattern = pseudocodePattern, !isCancelled() else { return nil }
        let source = text as NSString
        var result: [SyntaxHighlighter.Token] = []
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if isCancelled() { stop.pointee = true; return }
            guard let match else { return }
            let value = source.substring(with: match.range)
            let kind: SyntaxHighlighter.TokenKind
            if value.hasPrefix("//") || value.hasPrefix("#") { kind = .comment }
            else if value.hasPrefix("\"") || value.hasPrefix("'") { kind = .string }
            else if value.first?.isNumber == true { kind = .number }
            else if value.first?.isLetter == true { kind = .keyword }
            else { kind = .punctuation }
            result.append(SyntaxHighlighter.Token(range: match.range, kind: kind))
        }
        return isCancelled() ? nil : result
    }

    struct Segment {
        let sourceLocation: Int
        let text: String
        var leadingSpaces: Int = 0
    }

    private struct Mapping {
        let localRange: NSRange
        let sourceLocation: Int
        let boundaries: [Int]
        let raw: NSString
    }
    static func language(for info: String) -> EditorLanguage? {
        let name = info.split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
        switch name {
        case "markdown", "md", "gfm": return .markdown
        case "json": return .json
        case "html", "htm", "htmlmixed": return .html
        case "javascript", "js", "mjs", "cjs", "text/javascript": return .javascript
        case "typescript", "ts", "tsx": return .typescript
        case "css": return .css
        case "python", "py": return .python
        case "swift": return .swift
        case "shell", "sh", "bash", "zsh": return .shell
        case "yaml", "yml": return .yaml
        case "c", "h", "clike", "cpp", "c++", "cc", "cxx", "hpp": return .cFamily
        case "sql": return .sql
        default: return nil
        }
    }

    static func tokens(rawBody: String, sourceLocation: Int, literal: String, info: String,
                       visible: NSRange, isCancelled: @escaping () -> Bool = { false }) -> [SyntaxHighlighter.Token]? {
        tokens(segments: [Segment(sourceLocation: sourceLocation, text: rawBody)], literal: literal,
               info: info, visible: visible, isCancelled: isCancelled)
    }

    static func tokens(segments: [Segment], literal: String, info: String, visible: NSRange,
                       isCancelled: @escaping () -> Bool = { false }) -> [SyntaxHighlighter.Token]? {
        guard !isCancelled() else { return nil }
        var units: [UInt16] = [], mappings: [Mapping] = [], previousEnd = 0
        for segment in segments {
            let raw = segment.text as NSString
            guard segment.sourceLocation >= previousEnd, segment.leadingSpaces >= 0 else { return nil }
            let start = units.count
            var boundaries = [0], position = 0
            for _ in 0..<segment.leadingSpaces { units.append(32); boundaries.append(0) }
            while position < raw.length {
                if isCancelled() { return nil }
                let unit = raw.character(at: position)
                if unit == 13 {
                    position += 1
                    if position < raw.length && raw.character(at: position) == 10 { position += 1 }
                    units.append(10)
                } else {
                    position += 1
                    units.append(unit)
                }
                boundaries.append(position)
            }
            if units.count > start {
                mappings.append(Mapping(localRange: NSRange(location: start, length: units.count - start),
                                        sourceLocation: segment.sourceLocation, boundaries: boundaries, raw: raw))
            }
            previousEnd = segment.sourceLocation + raw.length
        }
        let sourceText = String(decoding: units, as: UTF16.self)
        // cmark adds a final line feed to an unterminated last source line.
        guard (sourceText == literal || (!sourceText.hasSuffix("\n") && sourceText + "\n" == literal)),
              !isCancelled() else { return nil }
        let local: [SyntaxHighlighter.Token]
        if let language = language(for: info) {
            local = SyntaxHighlighter.tokens(in: sourceText, language: language, documentID: nil, isCancelled: isCancelled)
        } else {
            let name = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            let tokens = name.lowercased() == "pseudocode"
                ? pseudocodeTokens(sourceText, isCancelled: isCancelled)
                : MarkdownLanguageHighlightService.tokens(in: sourceText, language: name, isCancelled: isCancelled)
            guard let tokens else { return nil }
            local = tokens
        }
        guard !isCancelled() else { return nil }
        var result: [SyntaxHighlighter.Token] = []
        for token in local {
            if isCancelled() { return nil }
            let range = token.range
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= units.count else { return nil }
            var low = 0, high = mappings.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(mappings[middle].localRange) <= range.location { low = middle + 1 } else { high = middle }
            }
            while low < mappings.count && mappings[low].localRange.location < NSMaxRange(range) {
                if isCancelled() { return nil }
                let mapping = mappings[low], part = NSIntersectionRange(range, mapping.localRange)
                let start = mapping.boundaries[part.location - mapping.localRange.location]
                let end = mapping.boundaries[NSMaxRange(part) - mapping.localRange.location]
                let absolute = NSRange(location: mapping.sourceLocation + start, length: end - start)
                var clipped = NSIntersectionRange(absolute, visible)
                let localStart = clipped.location - mapping.sourceLocation
                if clipped.length > 0, localStart > 0, localStart < mapping.raw.length,
                   (0xd800...0xdbff).contains(mapping.raw.character(at: localStart - 1)),
                   (0xdc00...0xdfff).contains(mapping.raw.character(at: localStart)) {
                    clipped.location += 1; clipped.length -= 1
                }
                let localEnd = NSMaxRange(clipped) - mapping.sourceLocation
                if clipped.length > 0, localEnd > 0, localEnd < mapping.raw.length,
                   (0xd800...0xdbff).contains(mapping.raw.character(at: localEnd - 1)),
                   (0xdc00...0xdfff).contains(mapping.raw.character(at: localEnd)) { clipped.length -= 1 }
                if clipped.length > 0 { result.append(SyntaxHighlighter.Token(range: clipped, kind: token.kind)) }
                low += 1
            }
        }
        return result
    }
}
