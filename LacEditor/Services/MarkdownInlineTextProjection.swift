import Foundation
import cmark_gfm

// Maps only transformations confirmed by cmark's complete literal.
enum MarkdownInlineTextProjection {
    private static let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf16)

    private static func entity(_ spelling: NSString, at index: Int, isCancelled: () -> Bool) -> (String, Int)? {
        guard spelling.character(at: index) == 38 else { return nil }
        var end = index + 1
        while end < spelling.length {
            if isCancelled() { return nil }
            let unit = spelling.character(at: end)
            if unit == 59 { break }
            guard (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 35 else { return nil }
            end += 1
        }
        guard end < spelling.length, spelling.character(at: end) == 59 else { return nil }
        let bytes = Array(spelling.substring(with: NSRange(location: index + 1, length: end - index)).utf8)
        guard bytes.count <= Int(Int32.max) else { return nil }
        var buffer = cmark_strbuf()
        cmark_strbuf_init(cmark_get_default_mem_allocator(), &buffer, 0)
        defer { cmark_strbuf_free(&buffer) }
        let consumed = bytes.withUnsafeBufferPointer { houdini_unescape_ent(&buffer, $0.baseAddress, Int32($0.count)) }
        guard Int(consumed) == bytes.count, let pointer = buffer.ptr,
              let value = String(bytes: UnsafeBufferPointer(start: pointer, count: Int(buffer.size)), encoding: .utf8) else { return nil }
        return (value, end - index + 1)
    }

    static func pieces(spelling: NSString, literal: String, sourceOffset: Int,
                       isCancelled: () -> Bool = { false }) -> [MarkdownReadableText.Piece]? {
        let decoded = literal as NSString
        var result: [MarkdownReadableText.Piece] = [], sourceIndex = 0, decodedIndex = 0
        var runStart: Int?, runEnd = 0
        func flush() {
            guard let start = runStart else { return }
            let range = NSRange(location: start, length: runEnd - start)
            result.append(.init(sourceRange: NSRange(location: sourceOffset + start, length: range.length),
                                text: spelling.substring(with: range), matchesSource: true))
            runStart = nil
        }
        while sourceIndex < spelling.length && decodedIndex < decoded.length {
            if isCancelled() { return nil }
            let unit = spelling.character(at: sourceIndex), rendered = decoded.character(at: decodedIndex)
            var smartLength = 0
            if unit == 34 && (rendered == 0x201c || rendered == 0x201d) { smartLength = 1 }
            else if unit == 39 && (rendered == 0x2018 || rendered == 0x2019) { smartLength = 1 }
            else if unit == 45 && rendered == 0x2013 && sourceIndex + 1 < spelling.length && spelling.character(at: sourceIndex + 1) == 45 { smartLength = 2 }
            else if unit == 45 && rendered == 0x2014 && sourceIndex + 2 < spelling.length && spelling.character(at: sourceIndex + 1) == 45 && spelling.character(at: sourceIndex + 2) == 45 { smartLength = 3 }
            else if unit == 46 && rendered == 0x2026 && sourceIndex + 2 < spelling.length && spelling.character(at: sourceIndex + 1) == 46 && spelling.character(at: sourceIndex + 2) == 46 { smartLength = 3 }
            if smartLength > 0 {
                flush()
                result.append(.init(sourceRange: NSRange(location: sourceOffset + sourceIndex, length: smartLength),
                                    text: decoded.substring(with: NSRange(location: decodedIndex, length: 1)), matchesSource: false))
                sourceIndex += smartLength; decodedIndex += 1
                continue
            }
            if unit == 38, let (value, length) = entity(spelling, at: sourceIndex, isCancelled: isCancelled) {
                let size = (value as NSString).length
                guard decodedIndex + size <= decoded.length,
                      decoded.substring(with: NSRange(location: decodedIndex, length: size)) == value else { return nil }
                flush()
                result.append(.init(sourceRange: NSRange(location: sourceOffset + sourceIndex, length: length), text: value, matchesSource: false))
                sourceIndex += length; decodedIndex += size
                continue
            }
            var visible = sourceIndex
            if unit == 92, sourceIndex + 1 < spelling.length, punctuation.contains(spelling.character(at: sourceIndex + 1)),
               spelling.character(at: sourceIndex + 1) == rendered { visible += 1 }
            guard spelling.character(at: visible) == rendered else { return nil }
            if runStart == nil || visible != runEnd { flush(); runStart = visible }
            runEnd = visible + 1
            sourceIndex = visible + 1; decodedIndex += 1
        }
        guard !isCancelled(), sourceIndex == spelling.length, decodedIndex == decoded.length else { return nil }
        flush()
        return result
    }
}
