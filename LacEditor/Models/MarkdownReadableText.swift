import Foundation

struct MarkdownReadableText: Sendable {
    struct Piece: Equatable, Sendable {
        let sourceRange: NSRange
        let text: String
        let matchesSource: Bool
    }

    struct Fragment: Sendable {
        let sourceRange: NSRange
        let text: String
        let matchesSource: Bool
        let pieces: [Piece]?

        init(sourceRange: NSRange, text: String, matchesSource: Bool, pieces: [Piece]? = nil) {
            self.sourceRange = sourceRange
            self.text = text
            self.matchesSource = matchesSource
            self.pieces = pieces
        }
    }

    static func selected(_ pieces: [Piece], in selection: NSRange, isCancelled: () -> Bool = { false }) -> (String, NSRange?)? {
        var result = "", first: Int?, last: Int?
        for piece in pieces {
            if isCancelled() { return nil }
            let part = NSIntersectionRange(piece.sourceRange, selection)
            guard part.length > 0 else { continue }
            if part == piece.sourceRange { result += piece.text }
            else {
                guard piece.matchesSource else { return nil }
                result += (piece.text as NSString).substring(with: NSRange(location: part.location - piece.sourceRange.location, length: part.length))
            }
            if first == nil { first = part.location }
            last = NSMaxRange(part)
        }
        return (result, first.flatMap { start in last.map { NSRange(location: start, length: $0 - start) } })
    }

    let sourceLength: Int
    let fragments: [Fragment]
    let unsupportedRanges: [NSRange]

    func text(in selection: NSRange? = nil, source: NSString? = nil, isCancelled: () -> Bool = { false }) -> String? {
        guard !isCancelled() else { return nil }
        if let selection {
            guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
                  selection.location <= sourceLength, selection.length <= sourceLength - selection.location else { return nil }
            guard let source, source.length == sourceLength else { return nil }
            for boundary in [selection.location, NSMaxRange(selection)] where boundary > 0 && boundary < sourceLength {
                if (0xdc00...0xdfff).contains(source.character(at: boundary)),
                   (0xd800...0xdbff).contains(source.character(at: boundary - 1)) { return nil }
            }
            if selection.length == 0 { return "" }
            guard !unsupportedRanges.contains(where: { NSIntersectionRange($0, selection).length > 0 }) else { return nil }
        } else if !unsupportedRanges.isEmpty { return nil }
        var result = ""
        for fragment in fragments {
            guard !isCancelled() else { return nil }
            guard let selection else { result += fragment.text; continue }
            let range = fragment.sourceRange
            if range.length == 0 {
                if selection.location <= range.location && range.location < NSMaxRange(selection) { result += fragment.text }
                continue
            }
            let part = NSIntersectionRange(range, selection)
            guard part.length > 0 else { continue }
            if part == range { result += fragment.text }
            else if let pieces = fragment.pieces {
                guard let selected = Self.selected(pieces, in: selection, isCancelled: isCancelled) else { return nil }
                result += selected.0
            }
            else {
                guard fragment.matchesSource else { return nil }
                result += (fragment.text as NSString).substring(with: NSRange(location: part.location - range.location, length: part.length))
            }
        }
        return isCancelled() ? nil : result
    }
    func replacingEmojiText(_ replacements: [(range: NSRange, text: String)],
                            isCancelled: () -> Bool = { false }) -> MarkdownReadableText? {
        guard !isCancelled() else { return nil }
        if replacements.isEmpty { return self }
        let ordered = replacements.sorted { $0.range.location < $1.range.location }
        var previousEnd = 0
        for replacement in ordered {
            if isCancelled() { return nil }
            let range = replacement.range
            guard range.location >= previousEnd, range.location <= sourceLength, range.length > 0,
                  range.length <= sourceLength - range.location, !replacement.text.isEmpty else { return nil }
            previousEnd = NSMaxRange(range)
        }
        var output: [Fragment] = [], used = Set<Int>()
        for fragment in fragments {
            if isCancelled() { return nil }
            var low = 0, high = ordered.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(ordered[middle].range) <= fragment.sourceRange.location { low = middle + 1 }
                else { high = middle }
            }
            guard fragment.sourceRange.length > 0, low < ordered.count,
                  ordered[low].range.location < NSMaxRange(fragment.sourceRange) else { output.append(fragment); continue }
            let pieces: [Piece]
            if let mapped = fragment.pieces { pieces = mapped }
            else {
                guard fragment.matchesSource else { return nil }
                pieces = [Piece(sourceRange: fragment.sourceRange, text: fragment.text, matchesSource: true)]
            }
            var texts: [NSString] = []
            for piece in pieces {
                if isCancelled() { return nil }
                texts.append(piece.text as NSString)
            }
            var pieceIndex = 0, selectedPieces: [Piece] = []
            func appendOriginal(_ wanted: NSRange, emitting: Bool, requireContent: Bool = false) -> Bool {
                var hasContent = false
                while pieceIndex < pieces.count {
                    if isCancelled() { return false }
                    let piece = pieces[pieceIndex]
                    if NSMaxRange(piece.sourceRange) <= wanted.location { pieceIndex += 1; continue }
                    if piece.sourceRange.location >= NSMaxRange(wanted) { break }
                    let part = NSIntersectionRange(piece.sourceRange, wanted)
                    hasContent = true
                    if part == piece.sourceRange {
                        if emitting { selectedPieces.append(piece) }
                    } else {
                        guard piece.matchesSource else { return false }
                        if emitting {
                            let value = texts[pieceIndex].substring(with: NSRange(location: part.location - piece.sourceRange.location, length: part.length))
                            selectedPieces.append(Piece(sourceRange: part, text: value, matchesSource: true))
                        }
                    }
                    if NSMaxRange(piece.sourceRange) > NSMaxRange(wanted) { break }
                    pieceIndex += 1
                }
                return !requireContent || hasContent
            }
            var position = fragment.sourceRange.location
            while low < ordered.count, ordered[low].range.location < NSMaxRange(fragment.sourceRange) {
                let replacement = ordered[low]
                guard replacement.range.location >= position, NSMaxRange(replacement.range) <= NSMaxRange(fragment.sourceRange),
                      !used.contains(low),
                      appendOriginal(NSRange(location: position, length: replacement.range.location - position), emitting: true),
                      appendOriginal(replacement.range, emitting: false, requireContent: true) else { return nil }
                selectedPieces.append(Piece(sourceRange: replacement.range, text: replacement.text, matchesSource: false))
                used.insert(low)
                position = NSMaxRange(replacement.range)
                low += 1
            }
            guard appendOriginal(NSRange(location: position, length: NSMaxRange(fragment.sourceRange) - position), emitting: true) else { return nil }
            var text = ""
            for piece in selectedPieces {
                if isCancelled() { return nil }
                text += piece.text
            }
            output.append(Fragment(sourceRange: fragment.sourceRange, text: text, matchesSource: false, pieces: selectedPieces))
        }
        guard !isCancelled(), used.count == ordered.count else { return nil }
        return MarkdownReadableText(sourceLength: sourceLength, fragments: output, unsupportedRanges: unsupportedRanges)
    }

}
