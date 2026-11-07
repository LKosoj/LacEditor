import Foundation

/// Front matter (YAML-блок в начале текста): границы и маскировка для разбора.
struct MarkdownFrontMatter {
    let range: NSRange
    let markers: [NSRange]

    static func frontMatter(_ text: String) -> MarkdownFrontMatter? {
        let source = text as NSString
        var position = 0
        func nextLine() -> (NSRange, Bool)? {
            guard position < source.length else { return nil }
            let start = position
            while position < source.length && source.character(at: position) != 10 && source.character(at: position) != 13 { position += 1 }
            let range = NSRange(location: start, length: position - start)
            let hasEnding = position < source.length
            if hasEnding {
                if source.character(at: position) == 13 && position + 1 < source.length && source.character(at: position + 1) == 10 { position += 1 }
                position += 1
            }
            return (range, hasEnding)
        }
        func marker(in line: NSRange, opening: Bool) -> NSRange? {
            var start = line.location
            let end = NSMaxRange(line)
            if opening && start == 0 && start < end && source.character(at: start) == 0xfeff { start += 1 }
            guard end - start >= 3 else { return nil }
            let first = source.character(at: start)
            guard first == 45 || (!opening && first == 46),
                  source.character(at: start + 1) == first, source.character(at: start + 2) == first else { return nil }
            for index in (start + 3)..<end where source.character(at: index) != 32 && source.character(at: index) != 9 { return nil }
            return NSRange(location: start, length: 3)
        }
        guard let (openingLine, hasEnding) = nextLine(), hasEnding,
              let opening = marker(in: openingLine, opening: true) else { return nil }
        while let (line, _) = nextLine() {
            if let closing = marker(in: line, opening: false) {
                return MarkdownFrontMatter(range: NSRange(location: 0, length: NSMaxRange(line)), markers: [opening, closing])
            }
        }
        return nil
    }

    static func maskedFrontMatter(_ text: String, frontMatter: MarkdownFrontMatter?) -> String {
        guard let frontMatter else { return text }
        let source = text as NSString
        let byteCount = source.substring(with: frontMatter.range).utf8.count
        var bytes = Array(text.utf8)
        for i in 0..<byteCount where bytes[i] != 10 && bytes[i] != 13 { bytes[i] = 32 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
