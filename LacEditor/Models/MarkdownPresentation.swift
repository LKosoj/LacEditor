import Foundation

enum MarkdownPresentationKind: Equatable, Sendable {
    case heading(Int), strong, emphasis, strikethrough, code, keyboard, link, quote, codeBlock, highlight, yaml, alert(String), subscriptText, superscriptText, underline, inlineStyle(MarkdownInlineStyle), tableMath(NSRange), tableEmoji(NSRange), tableImage(NSRange)
}

struct MarkdownPresentationSpan: Equatable, Sendable {
    let range: NSRange
    let kind: MarkdownPresentationKind
    let markerRanges: [NSRange]
}

struct MarkdownParagraph: Equatable, Sendable {
    let range: NSRange
    let lastLine: NSRange
    var separatorAfter: NSRange? = nil
}

struct MarkdownListMarker: Equatable, Sendable {
    let range: NSRange
    let line: NSRange
    let text: String
    let ordinal: Int?
    let depth: Int

    init(range: NSRange, line: NSRange, text: String, ordinal: Int? = nil, depth: Int = 1) {
        self.range = range
        self.line = line
        self.text = text
        self.ordinal = ordinal
        self.depth = depth
    }
}

struct MarkdownNamedAnchor: Equatable, Sendable {
    let name: String
    let range: NSRange
}

struct MarkdownHeading: Identifiable, Equatable, Sendable {
    struct Emoji: Equatable, Sendable {
        let range: NSRange
        let name: String
    }
    struct UppercaseRun: Equatable, Sendable {
        enum Attachment: Equatable, Sendable { case image, formula }
        struct Emoji: Equatable, Sendable {
            let range: NSRange
            let name: String
        }
        let pieces: [MarkdownReadableText.Piece]
        let styles: [MarkdownPresentationKind]
        let emoji: [Emoji]
        let attachment: Attachment?

        init(pieces: [MarkdownReadableText.Piece], styles: [MarkdownPresentationKind], emoji: [Emoji] = [], attachment: Attachment? = nil) {
            self.pieces = pieces
            self.styles = styles
            self.emoji = emoji
            self.attachment = attachment
        }
    }
    let level: Int
    let title: String
    let range: NSRange
    let emoji: [Emoji]
    let displayTitle: String?
    let number: String?
    let plainTextRange: NSRange?
    let uppercaseRuns: [UppercaseRun]?
    var renderedTitle: String { displayTitle ?? title }
    var numberedTitle: String { (number ?? "") + renderedTitle }
    var id: Int { range.location }

    init(level: Int, title: String, range: NSRange, emoji: [Emoji] = [], displayTitle: String? = nil, number: String? = nil, plainTextRange: NSRange? = nil, uppercaseRuns: [UppercaseRun]? = nil) {
        self.level = level
        self.title = title
        self.range = range
        self.emoji = emoji
        self.displayTitle = displayTitle
        self.number = number
        self.plainTextRange = plainTextRange
        self.uppercaseRuns = uppercaseRuns
    }

    func sameSource(as other: MarkdownHeading) -> Bool {
        level == other.level && title == other.title && range == other.range
    }

    func resolvingEmoji(_ values: [String: String]) -> MarkdownHeading {
        let rendered = NSMutableString(string: title)
        var changed = false
        for item in emoji.reversed() {
            guard let value = values[item.name], item.range.location >= 0,
                  NSMaxRange(item.range) <= rendered.length,
                  rendered.substring(with: item.range) == ":\(item.name):" else { continue }
            rendered.replaceCharacters(in: item.range, with: value)
            changed = true
        }
        let updatedRuns = uppercaseRuns.flatMap { runs -> [UppercaseRun]? in
            var updated: [UppercaseRun] = []
            for run in runs {
                guard let first = run.pieces.first, let last = run.pieces.last else { return nil }
                let replacements = run.emoji.compactMap { item -> (range: NSRange, text: String)? in
                    values[item.name].map { (item.range, $0) }
                }
                if replacements.isEmpty { updated.append(run); continue }
                let content = run.pieces.map(\.text).joined()
                let fragment = MarkdownReadableText.Fragment(sourceRange: NSRange(location: first.sourceRange.location,
                    length: NSMaxRange(last.sourceRange) - first.sourceRange.location), text: content, matchesSource: false, pieces: run.pieces)
                let readable = MarkdownReadableText(sourceLength: NSMaxRange(range), fragments: [fragment], unsupportedRanges: [])
                guard let mapped = readable.replacingEmojiText(replacements), let pieces = mapped.fragments.first?.pieces else { return nil }
                updated.append(.init(pieces: pieces, styles: run.styles, emoji: run.emoji, attachment: run.attachment))
            }
            return updated
        }
        return MarkdownHeading(level: level, title: title, range: range, emoji: emoji,
                               displayTitle: changed ? rendered as String : nil, number: number, plainTextRange: plainTextRange, uppercaseRuns: updatedRuns)
    }
}

enum MarkdownHeadingNumbering {
    static func applying(to headings: [MarkdownHeading], enabled: Bool) -> [MarkdownHeading] {
        var counters = Array(repeating: 0, count: 6)
        return headings.map { heading in
            let level = min(6, max(1, heading.level))
            let number: String?
            if enabled {
                counters[level - 1] += 1
                if level < 6 {
                    for index in level..<6 { counters[index] = 0 }
                }
                number = counters.prefix(level).map { String($0) }.joined(separator: ".") + ". "
            } else {
                number = nil
            }
            return MarkdownHeading(level: heading.level, title: heading.title, range: heading.range,
                                   emoji: heading.emoji, displayTitle: heading.displayTitle, number: number, plainTextRange: heading.plainTextRange, uppercaseRuns: heading.uppercaseRuns)
        }
    }
}

struct MarkdownHeadingUppercaseProjection: Equatable {
    struct Piece: Equatable {
        let source: NSRange
        let display: NSRange
    }
    let text: String
    let pieces: [Piece]
    let sourceLength: Int
    private let sourcePieces: [Piece]
    private let insertionStops: [[Int]]

    init(_ source: String) {
        let raw = source as NSString
        if raw.length == 0 {
            self.text = ""
            self.pieces = []
            self.sourceLength = 0
            self.sourcePieces = []
            self.insertionStops = []
        } else {
            self = MarkdownHeadingUppercaseProjection(pieces: [.init(sourceRange: NSRange(location: 0, length: raw.length), text: source, matchesSource: true)],
                                                      sourceRange: NSRange(location: 0, length: raw.length))!
        }
    }

    init?(pieces input: [MarkdownReadableText.Piece], sourceRange: NSRange) {
        guard sourceRange.location != NSNotFound, sourceRange.location >= 0, sourceRange.length >= 0,
              sourceRange.length <= Int.max - sourceRange.location, !input.isEmpty else { return nil }
        var previousEnd = sourceRange.location
        for piece in input {
            let range = piece.sourceRange
            guard range.location >= previousEnd, range.location <= NSMaxRange(sourceRange), range.length > 0,
                  range.length <= NSMaxRange(sourceRange) - range.location, !piece.text.isEmpty,
                  !piece.matchesSource || range.length == (piece.text as NSString).length else { return nil }
            previousEnd = NSMaxRange(range)
        }
        let output = NSMutableString(), locale = Locale(identifier: "und")
        var result: [Piece] = []
        for item in input {
            let raw = item.text as NSString
            if !item.matchesSource {
                let value = item.text.uppercased(with: locale)
                let display = NSRange(location: output.length, length: (value as NSString).length)
                output.append(value)
                result.append(Piece(source: NSRange(location: item.sourceRange.location - sourceRange.location, length: item.sourceRange.length), display: display))
                continue
            }
            var offset = 0
            while offset < raw.length {
                let range = raw.rangeOfComposedCharacterSequence(at: offset)
                let value = raw.substring(with: range).uppercased(with: locale)
                let display = NSRange(location: output.length, length: (value as NSString).length)
                output.append(value)
                result.append(Piece(source: NSRange(location: item.sourceRange.location - sourceRange.location + range.location, length: range.length), display: display))
                offset = NSMaxRange(range)
            }
        }
        var groups: [Piece] = []
        for item in result {
            if let last = groups.last, output.rangeOfComposedCharacterSequence(at: item.display.location).location < item.display.location {
                groups[groups.count - 1] = Piece(source: NSUnionRange(last.source, item.source), display: NSUnionRange(last.display, item.display))
            } else { groups.append(item) }
        }
        var stops: [[Int]] = []
        for group in groups {
            var positions: [Int] = [], offset = group.display.location
            while offset < NSMaxRange(group.display) {
                positions.append(offset)
                offset = NSMaxRange(output.rangeOfComposedCharacterSequence(at: offset))
            }
            stops.append(positions)
        }
        self.text = output as String
        self.pieces = groups
        self.sourceLength = previousEnd - sourceRange.location
        self.sourcePieces = result
        self.insertionStops = stops
    }

    func sourcePosition(for displayPosition: Int, fraction: CGFloat = 0) -> Int? {
        guard displayPosition >= 0, displayPosition <= (text as NSString).length, fraction.isFinite else { return nil }
        if displayPosition == (text as NSString).length { return sourceLength }
        var low = 0, high = pieces.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(pieces[middle].display) <= displayPosition { low = middle + 1 } else { high = middle }
        }
        guard low < pieces.count else { return nil }
        let piece = pieces[low]
        let stops = insertionStops[low]
        var left = 0, right = stops.count
        while left < right {
            let middle = (left + right) / 2
            if stops[middle] <= displayPosition { left = middle + 1 } else { right = middle }
        }
        let interval = max(0, left - 1)
        let offset = CGFloat(interval) + min(1, max(0, fraction))
        return offset * 2 < CGFloat(stops.count) ? piece.source.location : NSMaxRange(piece.source)
    }

    func displayRange(for source: NSRange) -> NSRange? {
        guard source.location != NSNotFound, source.location >= 0, source.length > 0,
              source.length <= Int.max - source.location else { return nil }
        var low = 0, high = sourcePieces.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(sourcePieces[middle].source) <= source.location { low = middle + 1 } else { high = middle }
        }
        guard low < sourcePieces.count, sourcePieces[low].source.location >= source.location else { return nil }
        let start = low
        high = sourcePieces.count
        while low < high {
            let middle = (low + high) / 2
            if sourcePieces[middle].source.location < NSMaxRange(source) { low = middle + 1 } else { high = middle }
        }
        guard low > start, NSMaxRange(sourcePieces[low - 1].source) <= NSMaxRange(source) else { return nil }
        return NSRange(location: sourcePieces[start].display.location,
                       length: NSMaxRange(sourcePieces[low - 1].display) - sourcePieces[start].display.location)
    }
}

enum MarkdownHeadingAnchors {
    struct Entry {
        let slug: String
        let id: String
    }

    struct Allocator {
        private var used = Set<String>()
        private var nextSuffix: [String: Int] = [:]

        mutating func next(_ title: String) -> Entry {
            let normalized = title.precomposedStringWithCanonicalMapping.lowercased()
            var value = ""
            for scalar in normalized.unicodeScalars {
                if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ||
                    CharacterSet.nonBaseCharacters.contains(scalar) || scalar == "_" || scalar == "-" {
                    value.unicodeScalars.append(scalar)
                } else if CharacterSet.whitespacesAndNewlines.contains(scalar), !value.hasSuffix("-") {
                    value += "-"
                }
            }
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let base = trimmed.isEmpty ? "section" : trimmed
            var id = "lac-heading-" + base, number = nextSuffix[base, default: 1]
            while used.contains(id) { id = "lac-heading-\(base)-\(number)"; number += 1 }
            used.insert(id)
            nextSuffix[base] = number
            return Entry(slug: base, id: id)
        }
    }

    static func aliases(_ entries: [Entry]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            if result[entry.slug] == nil { result[entry.slug] = entry.id }
            let unique = String(entry.id.dropFirst("lac-heading-".count))
            if result[unique] == nil { result[unique] = entry.id }
        }
        return result
    }

    static func target(for fragment: String, in headings: [MarkdownHeading]) -> MarkdownHeading? {
        var allocator = Allocator()
        let entries = headings.map { allocator.next($0.title) }
        let id = aliases(entries)[fragment] ?? fragment
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return headings[index]
    }
}

struct MarkdownLink: Equatable, Sendable {
    let range: NSRange
    let url: String
}

struct MarkdownImage: Equatable, Sendable {
    let range: NSRange
    let paragraphRange: NSRange
    let url: String
    let alt: String
    let title: String?
    var isInline: Bool = false
    var sizing: MarkdownImageSizing? = nil
}

struct MarkdownIframeBlock: Equatable, Sendable {
    let range: NSRange
    let html: String
    let width: String?
    let height: String?
    let title: String?
    var isInline: Bool = false
}

struct MarkdownAudioBlock: Equatable, Sendable {
    let range: NSRange
    let media: MarkdownEmbeddedMedia
    var isInline: Bool = false
    var source: String { media.sources[0] }
}

struct MarkdownDetailsBlock: Equatable, Sendable {
    let range: NSRange
    let summary: String
    let body: String
    var summaryHTML: String? = nil
    var bodyHTML: String? = nil
    var initiallyOpen: Bool = false
}

struct MarkdownHTMLBlock: Equatable, Sendable {
    let range: NSRange
    let html: String
}

struct MarkdownRubyBaseRun: Equatable, Sendable {
    let range: NSRange
    let bold: Bool
    let italic: Bool
    let foreground: MarkdownSRGBColor?
}

struct MarkdownRuby: Equatable, Sendable {
    let range: NSRange
    let baseRange: NSRange
    let readingRange: NSRange
    let base: String
    let reading: String
    var baseRuns: [MarkdownRubyBaseRun] = []
}

struct MarkdownDiagram: Equatable, Sendable {
    enum Kind: String, Sendable { case mermaid, flow, sequence }
    let range: NSRange
    let source: String
    let kind: Kind

    init(range: NSRange, source: String, kind: Kind = .mermaid) {
        self.range = range
        self.source = source
        self.kind = kind
    }
}

struct MarkdownCodeBlock: Equatable, Sendable {
    let range: NSRange
    let bodyRange: NSRange
    let bodySegments: [NSRange]
    let bodyPadding: [Int]
    let infoRange: NSRange
    let fenceMarkers: [NSRange]
    let continuationPrefix: String
    let isNested: Bool
    let isClosed: Bool
    let info: String
    let literal: String
}

struct MarkdownFormula: Equatable, Sendable {
    let range: NSRange
    let source: String
}

struct MarkdownTaskCheckbox: Equatable, Sendable {
    let markerRange: NSRange
    let stateRange: NSRange
    let state: UInt16
}

struct MarkdownFootnote: Equatable, Sendable {
    let referenceRange: NSRange
    let definitionRange: NSRange
    let text: String
}

enum MarkdownTableAlignment: Equatable, Sendable {
    case unspecified, left, center, right
}

struct MarkdownTableCell: Equatable, Sendable {
    let range: NSRange
    let column: Int
    let virtualSeparators: Int
    let displayText: String?
    let displayRuns: [MarkdownTableTextRun]

    init(range: NSRange, column: Int, virtualSeparators: Int = 0, displayText: String? = nil,
         displayRuns: [MarkdownTableTextRun] = []) {
        self.range = range
        self.column = column
        self.virtualSeparators = virtualSeparators
        self.displayText = displayText
        self.displayRuns = displayRuns
    }
}

struct MarkdownTableTextRun: Equatable, Sendable {
    let range: NSRange
    let kind: MarkdownPresentationKind
    let sourceRange: NSRange?

    init(range: NSRange, kind: MarkdownPresentationKind, sourceRange: NSRange? = nil) {
        self.range = range
        self.kind = kind
        self.sourceRange = sourceRange
    }
}

struct MarkdownTableRow: Equatable, Sendable {
    let range: NSRange
    let cells: [MarkdownTableCell]
}

struct MarkdownTableRows: RandomAccessCollection, Equatable, Sendable {
    private let base: [MarkdownTableRow]
    private let baseShift: Int
    private let changedIndex: Int?
    private let changedRow: MarkdownTableRow?
    private let followingShift: Int

    init(_ rows: [MarkdownTableRow]) {
        base = rows; baseShift = 0; changedIndex = nil; changedRow = nil; followingShift = 0
    }

    private init(base: [MarkdownTableRow], baseShift: Int, changedIndex: Int?, changedRow: MarkdownTableRow?, followingShift: Int) {
        self.base = base; self.baseShift = baseShift; self.changedIndex = changedIndex
        self.changedRow = changedRow; self.followingShift = followingShift
    }

    var startIndex: Int { base.startIndex }
    var endIndex: Int { base.endIndex }

    static func == (left: MarkdownTableRows, right: MarkdownTableRows) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { pair in pair.0 == pair.1 }
    }

    subscript(index: Int) -> MarkdownTableRow {
        if index == changedIndex, let changedRow { return changedRow }
        let delta = baseShift + (changedIndex.map { index > $0 ? followingShift : 0 } ?? 0)
        return Self.shift(base[index], by: delta)
    }

    func range(at index: Int) -> NSRange {
        if index == changedIndex, let changedRow { return changedRow.range }
        let delta = baseShift + (changedIndex.map { index > $0 ? followingShift : 0 } ?? 0)
        let range = base[index].range
        return NSRange(location: range.location + delta, length: range.length)
    }

    func replacing(_ index: Int, row: MarkdownTableRow, delta: Int) -> MarkdownTableRows {
        if changedIndex == nil || changedIndex == index {
            return MarkdownTableRows(base: base, baseShift: baseShift, changedIndex: index,
                                     changedRow: row, followingShift: followingShift + delta)
        }
        return MarkdownTableRows(Array(self)).replacing(index, row: row, delta: delta)
    }

    func shifted(by delta: Int) -> MarkdownTableRows {
        MarkdownTableRows(base: base, baseShift: baseShift + delta, changedIndex: changedIndex,
                          changedRow: changedRow.map { Self.shift($0, by: delta) }, followingShift: followingShift)
    }

    private static func shift(_ row: MarkdownTableRow, by delta: Int) -> MarkdownTableRow {
        guard delta != 0 else { return row }
        let cells = row.cells.map { cell in
            MarkdownTableCell(range: NSRange(location: cell.range.location + delta, length: cell.range.length),
                              column: cell.column, virtualSeparators: cell.virtualSeparators,
                              displayText: cell.displayText, displayRuns: cell.displayRuns)
        }
        return MarkdownTableRow(range: NSRange(location: row.range.location + delta, length: row.range.length), cells: cells)
    }
}

struct MarkdownTable: Equatable, Sendable {
    let range: NSRange
    let delimiterRange: NSRange
    let alignments: [MarkdownTableAlignment]
    let rows: MarkdownTableRows
    let containerPrefix: String
    let quoteDepth: Int
    let nestedList: Bool
    let referenceLabels: [String]

    init(range: NSRange, delimiterRange: NSRange, alignments: [MarkdownTableAlignment], rows: [MarkdownTableRow],
         containerPrefix: String = "", quoteDepth: Int = 0, nestedList: Bool = false, referenceLabels: [String] = []) {
        self.range = range
        self.delimiterRange = delimiterRange
        self.alignments = alignments
        self.rows = MarkdownTableRows(rows)
        self.containerPrefix = containerPrefix
        self.quoteDepth = quoteDepth
        self.nestedList = nestedList
        self.referenceLabels = referenceLabels
    }

    init(range: NSRange, delimiterRange: NSRange, alignments: [MarkdownTableAlignment], rows: MarkdownTableRows,
         containerPrefix: String = "", quoteDepth: Int = 0, nestedList: Bool = false, referenceLabels: [String] = []) {
        self.range = range; self.delimiterRange = delimiterRange; self.alignments = alignments; self.rows = rows
        self.containerPrefix = containerPrefix; self.quoteDepth = quoteDepth; self.nestedList = nestedList
        self.referenceLabels = referenceLabels
    }
}

struct MarkdownFenceContainerLine: Equatable, Sendable {
    let line: NSRange
    let sourcePrefix: String
    let continuationPrefix: String
}

struct MarkdownEmojiCandidate: Equatable, Sendable {
    let name: String
    let range: NSRange
}

struct MarkdownTextReplacement: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case smart, spaces, softBreak }
    let range: NSRange
    let text: String
    let kind: Kind
}

struct MarkdownLooseIndent: Sendable {
    let range: NSRange
    let replacement: String
}

struct MarkdownPresentation: Sendable {
    let spans: [MarkdownPresentationSpan]
    let headings: [MarkdownHeading]
    let namedAnchors: [MarkdownNamedAnchor]
    let images: [MarkdownImage]
    let diagrams: [MarkdownDiagram]
    let audioBlocks: [MarkdownAudioBlock]
    let iframeBlocks: [MarkdownIframeBlock]
    let detailsBlocks: [MarkdownDetailsBlock]
    let htmlBlocks: [MarkdownHTMLBlock]
    let pageBreaks: [NSRange]
    let ruby: [MarkdownRuby]
    let links: [MarkdownLink]
    let formulas: [MarkdownFormula]
    let inlineFormulas: [MarkdownFormula]
    let emojiCandidates: [MarkdownEmojiCandidate]
    let emojiCandidatesIncluded: Bool
    let emojiCompletionRanges: [NSRange]
    let smartTextRanges: [NSRange]
    let smartRawHTMLRanges: [NSRange]?
    let textReplacements: [MarkdownTextReplacement]
    let paragraphs: [MarkdownParagraph]
    let completedTaskRanges: [NSRange]
    let taskCheckboxes: [MarkdownTaskCheckbox]
    let listMarkers: [MarkdownListMarker]
    let looseIndents: [MarkdownLooseIndent]
    let footnotes: [MarkdownFootnote]
    let tableOfContents: [NSRange]
    let tables: [MarkdownTable]
    let codeBlocks: [MarkdownCodeBlock]
    let fenceContainerLines: [MarkdownFenceContainerLine]
    let fenceBlockedRanges: [NSRange]
    let fenceBlockedEOF: Bool
    let fenceContextAvailable: Bool
    let readableText: MarkdownReadableText?

    init(spans: [MarkdownPresentationSpan], headings: [MarkdownHeading] = [], namedAnchors: [MarkdownNamedAnchor] = [], images: [MarkdownImage] = [], audioBlocks: [MarkdownAudioBlock] = [], iframeBlocks: [MarkdownIframeBlock] = [], detailsBlocks: [MarkdownDetailsBlock] = [], htmlBlocks: [MarkdownHTMLBlock] = [], pageBreaks: [NSRange] = [], ruby: [MarkdownRuby] = [], links: [MarkdownLink] = [], diagrams: [MarkdownDiagram] = [], formulas: [MarkdownFormula] = [], inlineFormulas: [MarkdownFormula] = [], emojiCandidates: [MarkdownEmojiCandidate] = [], emojiCandidatesIncluded: Bool = false, emojiCompletionRanges: [NSRange] = [], smartTextRanges: [NSRange] = [], smartRawHTMLRanges: [NSRange]? = nil, textReplacements: [MarkdownTextReplacement] = [], paragraphs: [MarkdownParagraph] = [], completedTaskRanges: [NSRange] = [], taskCheckboxes: [MarkdownTaskCheckbox] = [], listMarkers: [MarkdownListMarker] = [], looseIndents: [MarkdownLooseIndent] = [], footnotes: [MarkdownFootnote] = [], tableOfContents: [NSRange] = [], tables: [MarkdownTable] = [], codeBlocks: [MarkdownCodeBlock] = [], fenceContainerLines: [MarkdownFenceContainerLine] = [], fenceBlockedRanges: [NSRange] = [], fenceBlockedEOF: Bool = false, fenceContextAvailable: Bool = false, readableText: MarkdownReadableText? = nil) {
        self.spans = spans
        self.headings = headings
        self.namedAnchors = namedAnchors
        self.images = images
        self.diagrams = diagrams
        self.audioBlocks = audioBlocks
        self.iframeBlocks = iframeBlocks
        self.detailsBlocks = detailsBlocks
        self.htmlBlocks = htmlBlocks
        self.pageBreaks = pageBreaks
        self.ruby = ruby
        self.links = links
        self.formulas = formulas
        self.inlineFormulas = inlineFormulas
        self.emojiCandidates = emojiCandidates
        self.emojiCandidatesIncluded = emojiCandidatesIncluded
        self.emojiCompletionRanges = emojiCompletionRanges
        self.smartTextRanges = smartTextRanges
        self.smartRawHTMLRanges = smartRawHTMLRanges
        self.textReplacements = textReplacements
        self.paragraphs = paragraphs
        self.completedTaskRanges = completedTaskRanges
        self.taskCheckboxes = taskCheckboxes
        self.listMarkers = listMarkers
        self.looseIndents = looseIndents
        self.footnotes = footnotes
        self.tables = tables
        self.codeBlocks = codeBlocks
        self.fenceContainerLines = fenceContainerLines
        self.fenceBlockedRanges = fenceBlockedRanges
        self.fenceBlockedEOF = fenceBlockedEOF
        self.fenceContextAvailable = fenceContextAvailable
        self.tableOfContents = tableOfContents
        self.readableText = readableText
    }
    func resolvingHeadingEmoji(_ values: [String: String], readableText: MarkdownReadableText? = nil) -> MarkdownPresentation {
        MarkdownPresentation(spans: spans, headings: headings.map { $0.resolvingEmoji(values) }, namedAnchors: namedAnchors, images: images,
            audioBlocks: audioBlocks, iframeBlocks: iframeBlocks, detailsBlocks: detailsBlocks, htmlBlocks: htmlBlocks, pageBreaks: pageBreaks, ruby: ruby, links: links, diagrams: diagrams, formulas: formulas, inlineFormulas: inlineFormulas,
            emojiCandidates: emojiCandidates, emojiCandidatesIncluded: emojiCandidatesIncluded, emojiCompletionRanges: emojiCompletionRanges, smartTextRanges: smartTextRanges, smartRawHTMLRanges: smartRawHTMLRanges, textReplacements: textReplacements, paragraphs: paragraphs, completedTaskRanges: completedTaskRanges,
            taskCheckboxes: taskCheckboxes, listMarkers: listMarkers, looseIndents: looseIndents, footnotes: footnotes, tableOfContents: tableOfContents, tables: tables,
            codeBlocks: codeBlocks, fenceContainerLines: fenceContainerLines, fenceBlockedRanges: fenceBlockedRanges, fenceBlockedEOF: fenceBlockedEOF,
            fenceContextAvailable: fenceContextAvailable, readableText: readableText ?? self.readableText)
    }

    func numberingHeadings(_ enabled: Bool) -> MarkdownPresentation {
        MarkdownPresentation(spans: spans, headings: MarkdownHeadingNumbering.applying(to: headings, enabled: enabled), namedAnchors: namedAnchors, images: images,
            audioBlocks: audioBlocks, iframeBlocks: iframeBlocks, detailsBlocks: detailsBlocks, htmlBlocks: htmlBlocks, pageBreaks: pageBreaks, ruby: ruby, links: links, diagrams: diagrams, formulas: formulas, inlineFormulas: inlineFormulas,
            emojiCandidates: emojiCandidates, emojiCandidatesIncluded: emojiCandidatesIncluded, emojiCompletionRanges: emojiCompletionRanges, smartTextRanges: smartTextRanges, smartRawHTMLRanges: smartRawHTMLRanges, textReplacements: textReplacements, paragraphs: paragraphs, completedTaskRanges: completedTaskRanges,
            taskCheckboxes: taskCheckboxes, listMarkers: listMarkers, looseIndents: looseIndents, footnotes: footnotes, tableOfContents: tableOfContents, tables: tables,
            codeBlocks: codeBlocks, fenceContainerLines: fenceContainerLines, fenceBlockedRanges: fenceBlockedRanges, fenceBlockedEOF: fenceBlockedEOF,
            fenceContextAvailable: fenceContextAvailable, readableText: readableText)
    }

    func replacingTable(_ table: MarkdownTable, oldTable: NSRange, edit: NSRange, replacementLength: Int) -> MarkdownPresentation {
        let delta = replacementLength - edit.length
        func shift(_ range: NSRange) -> NSRange? {
            if NSMaxRange(range) <= edit.location { return range }
            if range.location >= NSMaxRange(edit) { return NSRange(location: range.location + delta, length: range.length) }
            return nil
        }
        let newSpans = spans.compactMap { span -> MarkdownPresentationSpan? in
            let markers = span.markerRanges.compactMap(shift)
            guard markers.count == span.markerRanges.count else { return nil }
            let range: NSRange
            let isContainer: Bool
            switch span.kind { case .quote, .alert: isContainer = true; default: isContainer = false }
            if isContainer && edit.length == 0 && NSMaxRange(span.range) == edit.location {
                range = NSRange(location: span.range.location, length: span.range.length + replacementLength)
            } else if let shifted = shift(span.range) {
                range = shifted
            } else {
                guard isContainer, span.range.location <= edit.location, NSMaxRange(edit) <= NSMaxRange(span.range),
                      span.range.length + delta >= 0 else { return nil }
                range = NSRange(location: span.range.location, length: span.range.length + delta)
            }
            return MarkdownPresentationSpan(range: range, kind: span.kind, markerRanges: markers)
        }
        let newHeadings = headings.compactMap { heading -> MarkdownHeading? in
            guard let range = shift(heading.range) else { return nil }
            let runs = heading.uppercaseRuns.flatMap { runs -> [MarkdownHeading.UppercaseRun]? in
                var shifted: [MarkdownHeading.UppercaseRun] = []
                for run in runs {
                    let pieces = run.pieces.compactMap { piece -> MarkdownReadableText.Piece? in
                        guard let sourceRange = shift(piece.sourceRange) else { return nil }
                        return .init(sourceRange: sourceRange, text: piece.text, matchesSource: piece.matchesSource)
                    }
                    guard pieces.count == run.pieces.count else { return nil }
                    let emoji = run.emoji.compactMap { item -> MarkdownHeading.UppercaseRun.Emoji? in
                        guard let range = shift(item.range) else { return nil }
                        return .init(range: range, name: item.name)
                    }
                    guard emoji.count == run.emoji.count else { return nil }
                    shifted.append(.init(pieces: pieces, styles: run.styles, emoji: emoji, attachment: run.attachment))
                }
                return shifted
            }
            return MarkdownHeading(level: heading.level, title: heading.title, range: range, emoji: heading.emoji, displayTitle: heading.displayTitle, number: heading.number,
                                   plainTextRange: heading.plainTextRange.flatMap(shift), uppercaseRuns: runs)
        }
        let newImages = images.compactMap { image -> MarkdownImage? in
            guard let range = shift(image.range), let paragraph = shift(image.paragraphRange) else { return nil }
            return MarkdownImage(range: range, paragraphRange: paragraph, url: image.url, alt: image.alt, title: image.title, isInline: image.isInline, sizing: image.sizing)
        }
        let newLinks = links.compactMap { link -> MarkdownLink? in
            guard let range = shift(link.range) else { return nil }
            return MarkdownLink(range: range, url: link.url)
        }
        let newIframes = iframeBlocks.compactMap { block -> MarkdownIframeBlock? in
            guard let range = shift(block.range) else { return nil }
            return MarkdownIframeBlock(range: range, html: block.html, width: block.width, height: block.height, title: block.title, isInline: block.isInline)
        }
        let newAudio = audioBlocks.compactMap { block -> MarkdownAudioBlock? in
            guard let range = shift(block.range) else { return nil }
            return MarkdownAudioBlock(range: range, media: block.media, isInline: block.isInline)
        }
        let newDetails = detailsBlocks.compactMap { block -> MarkdownDetailsBlock? in
            guard let range = shift(block.range) else { return nil }
            return MarkdownDetailsBlock(range: range, summary: block.summary, body: block.body, summaryHTML: block.summaryHTML, bodyHTML: block.bodyHTML, initiallyOpen: block.initiallyOpen)
        }
        let newHTMLBlocks = htmlBlocks.compactMap { block -> MarkdownHTMLBlock? in
            guard let range = shift(block.range) else { return nil }
            return MarkdownHTMLBlock(range: range, html: block.html)
        }
        let newRuby = ruby.compactMap { item -> MarkdownRuby? in
            guard let range = shift(item.range), let base = shift(item.baseRange), let reading = shift(item.readingRange) else { return nil }
            return MarkdownRuby(range: range, baseRange: base, readingRange: reading, base: item.base, reading: item.reading, baseRuns: item.baseRuns)
        }
        let newDiagrams = diagrams.compactMap { diagram -> MarkdownDiagram? in
            guard let range = shift(diagram.range) else { return nil }
            return MarkdownDiagram(range: range, source: diagram.source, kind: diagram.kind)
        }
        let newFormulas = formulas.compactMap { formula -> MarkdownFormula? in
            guard let range = shift(formula.range) else { return nil }
            return MarkdownFormula(range: range, source: formula.source)
        }
        var newInlineFormulas = inlineFormulas.compactMap { formula -> MarkdownFormula? in
            guard let range = shift(formula.range) else { return nil }
            return MarkdownFormula(range: range, source: formula.source)
        }
        var low = 0, high = table.rows.count
        while low < high {
            let middle = (low + high) / 2
            if table.rows[middle].range.location <= edit.location { low = middle + 1 } else { high = middle }
        }
        if low > 0 {
            let row = table.rows[low - 1]
            if edit.location <= NSMaxRange(row.range) {
                newInlineFormulas.removeAll { NSIntersectionRange($0.range, row.range).length > 0 }
                var rowFormulas: [MarkdownFormula] = []
                for cell in row.cells {
                    guard let display = cell.displayText as NSString? else { continue }
                    for run in cell.displayRuns {
                        guard case let .tableMath(relative) = run.kind, relative.location >= 0,
                              NSMaxRange(relative) <= cell.range.length, run.range.length >= 2,
                              run.range.location >= 0, NSMaxRange(run.range) <= display.length else { continue }
                        let body = NSRange(location: run.range.location + 1, length: run.range.length - 2)
                        rowFormulas.append(MarkdownFormula(
                            range: NSRange(location: cell.range.location + relative.location, length: relative.length),
                            source: display.substring(with: body)))
                    }
                }
                let insertion = newInlineFormulas.firstIndex { $0.range.location >= NSMaxRange(row.range) } ?? newInlineFormulas.endIndex
                newInlineFormulas.insert(contentsOf: rowFormulas, at: insertion)
            }
        }
        let newCheckboxes = taskCheckboxes.compactMap { checkbox -> MarkdownTaskCheckbox? in
            guard let marker = shift(checkbox.markerRange), let state = shift(checkbox.stateRange) else { return nil }
            return MarkdownTaskCheckbox(markerRange: marker, stateRange: state, state: checkbox.state)
        }
        let newFootnotes = footnotes.compactMap { footnote -> MarkdownFootnote? in
            guard let reference = shift(footnote.referenceRange), let definition = shift(footnote.definitionRange) else { return nil }
            return MarkdownFootnote(referenceRange: reference, definitionRange: definition, text: footnote.text)
        }
        let newTables = tables.compactMap { original -> MarkdownTable? in
            if original.range == oldTable { return table }
            guard let range = shift(original.range), let delimiter = shift(original.delimiterRange) else { return nil }
            let rows = original.rows.shifted(by: range.location - original.range.location)
            return MarkdownTable(range: range, delimiterRange: delimiter, alignments: original.alignments, rows: rows,
                                 containerPrefix: original.containerPrefix, quoteDepth: original.quoteDepth, nestedList: original.nestedList,
                                 referenceLabels: original.referenceLabels)
        }
        let newCodeBlocks = codeBlocks.compactMap { block -> MarkdownCodeBlock? in
            guard let range = shift(block.range), let body = shift(block.bodyRange), let info = shift(block.infoRange) else { return nil }
            let segments = block.bodySegments.compactMap(shift)
            let markers = block.fenceMarkers.compactMap(shift)
            guard segments.count == block.bodySegments.count, markers.count == block.fenceMarkers.count else { return nil }
            return MarkdownCodeBlock(range: range, bodyRange: body, bodySegments: segments, bodyPadding: block.bodyPadding, infoRange: info, fenceMarkers: markers, continuationPrefix: block.continuationPrefix, isNested: block.isNested, isClosed: block.isClosed, info: block.info, literal: block.literal)
        }
        return MarkdownPresentation(spans: newSpans, headings: newHeadings, namedAnchors: namedAnchors.compactMap { anchor in
                                        shift(anchor.range).map { MarkdownNamedAnchor(name: anchor.name, range: $0) }
                                    }, images: newImages, audioBlocks: newAudio, iframeBlocks: newIframes, detailsBlocks: newDetails, htmlBlocks: newHTMLBlocks, pageBreaks: pageBreaks.compactMap(shift), ruby: newRuby, links: newLinks, diagrams: newDiagrams, formulas: newFormulas, inlineFormulas: newInlineFormulas, emojiCandidates: emojiCandidates.compactMap { candidate in
                                        guard NSIntersectionRange(candidate.range, oldTable).length == 0 else { return nil }
                                        return shift(candidate.range).map { MarkdownEmojiCandidate(name: candidate.name, range: $0) }
                                    },
                                    textReplacements: textReplacements.compactMap { replacement in
                                        guard NSIntersectionRange(replacement.range, oldTable).length == 0, let range = shift(replacement.range) else { return nil }
                                        return MarkdownTextReplacement(range: range, text: replacement.text, kind: replacement.kind)
                                    }, paragraphs: paragraphs.compactMap { paragraph in
                                        guard let range = shift(paragraph.range), let lastLine = shift(paragraph.lastLine) else { return nil }
                                        let separator = paragraph.separatorAfter.flatMap(shift)
                                        if paragraph.separatorAfter != nil && separator == nil { return nil }
                                        return MarkdownParagraph(range: range, lastLine: lastLine, separatorAfter: separator)
                                    }, completedTaskRanges: completedTaskRanges.compactMap { range in
                                        if range.location <= oldTable.location && NSMaxRange(oldTable) <= NSMaxRange(range),
                                           range.length + delta >= 0 {
                                            return NSRange(location: range.location, length: range.length + delta)
                                        }
                                        return shift(range)
                                    }, taskCheckboxes: newCheckboxes, listMarkers: listMarkers.compactMap { marker in
                                        guard let range = shift(marker.range), let line = shift(marker.line) else { return nil }
                                        return MarkdownListMarker(range: range, line: line, text: marker.text, ordinal: marker.ordinal, depth: marker.depth)
                                    }, looseIndents: looseIndents.compactMap { indent in
                                        shift(indent.range).map { MarkdownLooseIndent(range: $0, replacement: indent.replacement) }
                                    }, footnotes: newFootnotes,
                                    tableOfContents: tableOfContents.compactMap(shift), tables: newTables, codeBlocks: newCodeBlocks)
    }

}
