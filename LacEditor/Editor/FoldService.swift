import Foundation

enum FoldService {
    static func foldableRange(in text: String, at cursor: Int, language: EditorLanguage,
                              isCancelled: () -> Bool = { false }) -> NSRange? {
        guard !isCancelled() else { return nil }
        switch language {
        case .markdown:
            return markdownRange(in: text, at: cursor, isCancelled: isCancelled)
        case .json:
            return jsonRange(in: text, at: cursor, isCancelled: isCancelled)
        default:
            return nil
        }
    }

    private static func markdownRange(in text: String, at cursor: Int, isCancelled: () -> Bool) -> NSRange? {
        let nsText = text as NSString
        guard cursor <= nsText.length else { return nil }
        let currentLine = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let mediaRanges = mediaPayloadRanges(in: nsText, searchRange: currentLine)
        if let media = mediaRanges.first(where: {
            cursor >= $0.location && cursor <= NSMaxRange($0)
        }) ?? mediaRanges.first {
            return media
        }
        let line = nsText.substring(with: currentLine)
        guard let match = line.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) else { return nil }
        let level = line[match].prefix { $0 == "#" }.count
        var end = NSMaxRange(currentLine)

        while end < nsText.length {
            if isCancelled() { return nil }
            let candidateRange = nsText.lineRange(for: NSRange(location: end, length: 0))
            let candidate = nsText.substring(with: candidateRange)
            if let heading = candidate.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) {
                let candidateLevel = candidate[heading].prefix { $0 == "#" }.count
                if candidateLevel <= level { break }
            }
            end = NSMaxRange(candidateRange)
        }
        let bodyStart = NSMaxRange(currentLine)
        guard end > bodyStart else { return nil }
        return NSRange(location: bodyStart, length: end - bodyStart)
    }

    static func mediaPayloadRanges(in text: String, isCancelled: () -> Bool = { false }) -> [NSRange] {
        let source = text as NSString
        return mediaPayloadRanges(in: source, searchRange: NSRange(location: 0, length: source.length), isCancelled: isCancelled)
    }

    static func mediaPayloadRange(in text: String, at cursor: Int) -> NSRange? {
        let source = text as NSString
        guard cursor >= 0, cursor <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: cursor, length: 0))
        let ranges = mediaPayloadRanges(in: source, searchRange: line)
        return ranges.first(where: { cursor >= $0.location && cursor <= NSMaxRange($0) }) ?? ranges.first
    }

    private static func mediaPayloadRanges(in text: NSString, searchRange: NSRange,
                                           isCancelled: () -> Bool = { false }) -> [NSRange] {
        let minimumPayloadLength = 256
        var search = searchRange
        var result: [NSRange] = []
        while search.length > 0 {
            if isCancelled() { return [] }
            let marker = text.range(of: "data:", options: .caseInsensitive, range: search)
            guard marker.location != NSNotFound else { break }
            let headerStart = NSMaxRange(marker)
            let remaining = NSRange(location: headerStart, length: NSMaxRange(searchRange) - headerStart)
            let comma = text.range(of: ",", range: remaining)
            if comma.location != NSNotFound, comma.location - headerStart <= 128 {
                let header = text.substring(with: NSRange(location: headerStart, length: comma.location - headerStart)).lowercased()
                let isMedia = header.hasPrefix("image/") || header.hasPrefix("audio/")
                    || header.hasPrefix("video/") || header.hasPrefix("application/pdf")
                if isMedia, header.split(separator: ";").dropFirst().contains("base64") {
                    let payloadStart = NSMaxRange(comma)
                    var payloadEnd = payloadStart
                    while payloadEnd < NSMaxRange(searchRange), isBase64(text.character(at: payloadEnd)) {
                        payloadEnd += 1
                        if (payloadEnd - payloadStart).isMultiple(of: 16_384), isCancelled() { return [] }
                    }
                    let payload = NSRange(location: payloadStart, length: payloadEnd - payloadStart)
                    if payload.length >= minimumPayloadLength { result.append(payload) }
                }
            }
            let next = NSMaxRange(marker)
            search = NSRange(location: next, length: NSMaxRange(searchRange) - next)
        }
        return result
    }

    private static func isBase64(_ value: unichar) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
            || value == 43 || value == 47 || value == 61 || value == 45 || value == 95
    }

    private static func jsonRange(in text: String, at cursor: Int, isCancelled: () -> Bool) -> NSRange? {
        let characters = text as NSString
        guard characters.length > 0 else { return nil }
        let safeCursor = min(max(cursor, 0), characters.length - 1)
        var stack: [(index: Int, delimiter: UInt16)] = []
        var isInString = false
        var isEscaped = false

        func consume(at position: Int) {
            let value = characters.character(at: position)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if value == 92 {
                    isEscaped = true
                } else if value == 34 {
                    isInString = false
                }
            } else if value == 34 {
                isInString = true
            } else if value == 123 || value == 91 {
                stack.append((position, value))
            } else if value == 125 || value == 93,
                      let last = stack.last {
                let matches = (last.delimiter == 123 && value == 125)
                    || (last.delimiter == 91 && value == 93)
                if matches {
                    stack.removeLast()
                }
            }
        }

        if safeCursor > 0 {
            for position in 0..<safeCursor {
                if position.isMultiple(of: 4096), isCancelled() { return nil }
                consume(at: position)
            }
        }
        let cursorCharacter = characters.character(at: safeCursor)
        if cursorCharacter == 123 || cursorCharacter == 91 {
            consume(at: safeCursor)
        }

        guard let container = stack.last else { return nil }
        let start = container.index
        var scanStack: [UInt16] = []
        isInString = false
        isEscaped = false
        for position in start..<characters.length {
            if (position - start).isMultiple(of: 4096), isCancelled() { return nil }
            let value = characters.character(at: position)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if value == 92 {
                    isEscaped = true
                } else if value == 34 {
                    isInString = false
                }
            } else if value == 34 {
                isInString = true
            } else if value == 123 || value == 91 {
                scanStack.append(value)
            } else if value == 125 || value == 93,
                      let opening = scanStack.last {
                let matches = (opening == 123 && value == 125)
                    || (opening == 91 && value == 93)
                guard matches else { return nil }
                scanStack.removeLast()
                if scanStack.isEmpty, position > start + 1 {
                    return NSRange(
                        location: start + 1,
                        length: position - start - 1
                    )
                }
            }
        }
        return nil
    }
}
