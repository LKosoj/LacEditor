import Foundation

enum MarkdownPresentationKind: Equatable, Sendable {
    case heading(Int), strong, emphasis, strikethrough, code, keyboard, link, quote, codeBlock, highlight, yaml, alert(String), subscriptText, superscriptText, underline, inlineStyle(MarkdownInlineStyle), tableMath(NSRange), tableEmoji(NSRange), tableImage(NSRange)
}

struct MarkdownPresentationSpan: Equatable, Sendable {
    var range: NSRange
    let kind: MarkdownPresentationKind
    var markerRanges: [NSRange]
}

struct MarkdownParagraph: Equatable, Sendable {
    var range: NSRange
    var lastLine: NSRange
    var separatorAfter: NSRange? = nil

    /// Абзац вместе с разделителем после него.
    var extent: NSRange { separatorAfter.map { NSUnionRange(range, $0) } ?? range }
}

struct MarkdownListMarker: Equatable, Sendable {
    var range: NSRange
    var line: NSRange
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
    var range: NSRange
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
    var range: NSRange
    let emoji: [Emoji]
    let displayTitle: String?
    let number: String?
    var plainTextRange: NSRange?
    let uppercaseRuns: [UppercaseRun]?
    /// Заголовок лежит прямо в документе: не в цитате, списке и не в определении сноски.
    let isTopLevel: Bool
    var renderedTitle: String { displayTitle ?? title }
    var numberedTitle: String { (number ?? "") + renderedTitle }
    var id: Int { range.location }

    init(level: Int, title: String, range: NSRange, emoji: [Emoji] = [], displayTitle: String? = nil, number: String? = nil, plainTextRange: NSRange? = nil, uppercaseRuns: [UppercaseRun]? = nil, isTopLevel: Bool = false) {
        self.level = level
        self.title = title
        self.range = range
        self.emoji = emoji
        self.displayTitle = displayTitle
        self.number = number
        self.plainTextRange = plainTextRange
        self.uppercaseRuns = uppercaseRuns
        self.isTopLevel = isTopLevel
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
                               displayTitle: changed ? rendered as String : nil, number: number, plainTextRange: plainTextRange, uppercaseRuns: updatedRuns, isTopLevel: isTopLevel)
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
                                   emoji: heading.emoji, displayTitle: heading.displayTitle, number: number, plainTextRange: heading.plainTextRange, uppercaseRuns: heading.uppercaseRuns, isTopLevel: heading.isTopLevel)
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

    static func slug(of title: String) -> String {
        var allocator = Allocator()
        return allocator.next(title).slug
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
    var range: NSRange
    let url: String
}

/// Wiki-ссылка `[[цель#заголовок|текст]]`; все диапазоны в UTF-16 исходника.
struct MarkdownWikiLink: Equatable, Sendable {
    var range: NSRange
    var displayRange: NSRange
    let target: String
    let heading: String?
    let alias: String?
    var markerRanges: [NSRange]
}

struct MarkdownImage: Equatable, Sendable {
    var range: NSRange
    var paragraphRange: NSRange
    let url: String
    let alt: String
    let title: String?
    var isInline: Bool = false
    var sizing: MarkdownImageSizing? = nil
}

struct MarkdownIframeBlock: Equatable, Sendable {
    var range: NSRange
    let html: String
    let width: String?
    let height: String?
    let title: String?
    var isInline: Bool = false
}

struct MarkdownAudioBlock: Equatable, Sendable {
    var range: NSRange
    let media: MarkdownEmbeddedMedia
    var isInline: Bool = false
    var source: String { media.sources[0] }
}

struct MarkdownDetailsBlock: Equatable, Sendable {
    var range: NSRange
    let summary: String
    let body: String
    var summaryHTML: String? = nil
    var bodyHTML: String? = nil
    var initiallyOpen: Bool = false
}

struct MarkdownHTMLBlock: Equatable, Sendable {
    var range: NSRange
    let html: String
}

struct MarkdownRubyBaseRun: Equatable, Sendable {
    let range: NSRange
    let bold: Bool
    let italic: Bool
    let foreground: MarkdownSRGBColor?
}

struct MarkdownRuby: Equatable, Sendable {
    var range: NSRange
    var baseRange: NSRange
    var readingRange: NSRange
    let base: String
    let reading: String
    var baseRuns: [MarkdownRubyBaseRun] = []
}

struct MarkdownDiagram: Equatable, Sendable {
    enum Kind: String, Sendable { case mermaid, flow, sequence }
    var range: NSRange
    let source: String
    let kind: Kind

    init(range: NSRange, source: String, kind: Kind = .mermaid) {
        self.range = range
        self.source = source
        self.kind = kind
    }
}

struct MarkdownCodeBlock: Equatable, Sendable {
    var range: NSRange
    var bodyRange: NSRange
    var bodySegments: [NSRange]
    let bodyPadding: [Int]
    var infoRange: NSRange
    var fenceMarkers: [NSRange]
    let continuationPrefix: String
    let isNested: Bool
    let isClosed: Bool
    let info: String
    let literal: String
}

struct MarkdownFormula: Equatable, Sendable {
    var range: NSRange
    let source: String
}

struct MarkdownTaskCheckbox: Equatable, Sendable {
    var markerRange: NSRange
    var stateRange: NSRange
    let state: UInt16
}

struct MarkdownFootnote: Equatable, Sendable {
    var referenceRange: NSRange
    var definitionRange: NSRange
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

extension MarkdownTableRow {
    /// Та же строка, возможно в другом месте текста: длины, колонки и показываемый текст равны, а позиции ячеек одинаковы относительно начала строки.
    func sameContent(as other: MarkdownTableRow) -> Bool {
        range.length == other.range.length && cells.count == other.cells.count
            && zip(cells, other.cells).allSatisfy { left, right in
                left.range.location - range.location == right.range.location - other.range.location
                    && left.range.length == right.range.length && left.column == right.column
                    && left.virtualSeparators == right.virtualSeparators
                    && left.displayText == right.displayText && left.displayRuns == right.displayRuns
            }
    }
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
    private(set) var range: NSRange
    private(set) var delimiterRange: NSRange
    let alignments: [MarkdownTableAlignment]
    private(set) var rows: MarkdownTableRows
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

    /// Таблица целиком правее правки: все позиции прибавляют дельту, строки не обходятся.
    mutating func shift(by delta: Int) {
        range.location += delta
        delimiterRange.location += delta
        rows = rows.shifted(by: delta)
    }
}

struct MarkdownFenceContainerLine: Equatable, Sendable {
    let line: NSRange
    let sourcePrefix: String
    let continuationPrefix: String
}

struct MarkdownEmojiCandidate: Equatable, Sendable {
    let name: String
    var range: NSRange
}

struct MarkdownTextReplacement: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case smart, spaces, softBreak }
    var range: NSRange
    let text: String
    let kind: Kind
}

struct MarkdownLooseIndent: Sendable {
    var range: NSRange
    let replacement: String
}

/// Правка текста и правила сдвига диапазонов разбора при ней: по ним работают и проверка, и применение сдвига.
struct MarkdownTextEdit: Sendable {
    let range: NSRange
    let replacementLength: Int
    /// Длина текста до правки.
    let textLength: Int
    /// Вставлен один перевод строки (Enter), а не буква: на границе блока ничего не растёт, а новая пустая строка уходит в разделитель.
    var lineBreak = false
    /// Перевод строки вставлен в конец текста, где у последней строки ещё нет своего перевода: абзац растёт на него.
    var atOpenLine = false

    var delta: Int { replacementLength - range.length }
    var end: Int { NSMaxRange(range) }

    func holds(_ other: NSRange) -> Bool {
        other.location <= range.location && end <= NSMaxRange(other)
    }

    /// Неделимый диапазон: правка строго до него или строго после, любое касание отклоняется.
    func away(_ other: NSRange) -> NSRange? {
        if NSMaxRange(other) < range.location { return other }
        if other.location > end { return NSRange(location: other.location + delta, length: other.length) }
        return nil
    }

    /// Вставка из сырого HTML: между правкой и ею должен остаться хотя бы один символ сверх перевода строки, иначе соседняя строка меняет разбор.
    func spaced(_ other: NSRange) -> NSRange? {
        if NSMaxRange(other) + 1 < range.location { return other }
        if other.location > end + 1 { return NSRange(location: other.location + delta, length: other.length) }
        return nil
    }

    /// Правка, расширенная на `margin` символов с каждой стороны: окно поиска для `spaced`.
    func reaching(_ margin: Int) -> MarkdownTextEdit {
        let start = max(0, range.location - margin)
        return MarkdownTextEdit(range: NSRange(location: start, length: end + margin - start), replacementLength: replacementLength, textLength: textLength)
    }

    /// Граница, после которой допустима правка вплотную (разделитель абзацев).
    func after(_ other: NSRange) -> NSRange? {
        if lineBreak, range.length == 0, other.location <= range.location, range.location < NSMaxRange(other) {
            return NSRange(location: other.location, length: other.length + delta)
        }
        if NSMaxRange(other) <= range.location { return other }
        if other.location >= end { return NSRange(location: other.location + delta, length: other.length) }
        return nil
    }

    /// Встроенный элемент: правка строго внутри растягивает, касание границы отклоняется.
    func inline(_ other: NSRange) -> NSRange? {
        if let moved = away(other) { return moved }
        if other.location < range.location && end < NSMaxRange(other) && other.length + delta >= 0 {
            return NSRange(location: other.location, length: other.length + delta)
        }
        return nil
    }

    /// Блок: вставка в любой точке от начала до конца растягивает (набор в конце абзаца), остальное как у встроенного.
    func block(_ other: NSRange) -> NSRange? {
        if range.length == 0 && other.location <= range.location && range.location <= NSMaxRange(other) && !(lineBreak && range.location == NSMaxRange(other)) {
            return NSRange(location: other.location, length: other.length + delta)
        }
        if NSMaxRange(other) <= range.location { return other }
        if other.location >= end { return NSRange(location: other.location + delta, length: other.length) }
        if holds(other) && other.length + delta >= 0 {
            return NSRange(location: other.location, length: other.length + delta)
        }
        return nil
    }

    /// Абзац: как блок, но перевод строки в конце текста без перевода строки растит абзац.
    func paragraph(_ other: NSRange) -> NSRange? {
        if lineBreak && atOpenLine && range.location == NSMaxRange(other) { return NSRange(location: other.location, length: other.length + delta) }
        return block(other)
    }

    /// Строка пункта кончается переводом: вставка сразу за ним относится уже к следующей строке.
    func startsNextLine(_ line: NSRange) -> Bool {
        range.location == NSMaxRange(line) && range.location < textLength
    }

    func line(_ line: NSRange) -> NSRange? {
        startsNextLine(line) ? line : block(line)
    }

    private func firstIndex(_ count: Int, where test: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if test(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Элементы, которых может коснуться правка, для списка по порядку без пересечений: левее окна все кончаются раньше правки, правее все начинаются позже её конца.
    func window<T>(_ items: [T], extent: (T) -> NSRange) -> Range<Int> {
        let tail = firstIndex(items.count) { extent(items[$0]).location > end }
        var start = firstIndex(tail) { extent(items[$0]).location > range.location }
        while start > 0, NSMaxRange(extent(items[start - 1])) >= range.location { start -= 1 }
        return start..<tail
    }

    /// То же для списка по началу диапазонов с префиксными максимумами концов (диапазоны могут вкладываться).
    func window<T>(_ items: [T], ends: [Int], location: (T) -> Int) -> Range<Int> {
        let tail = firstIndex(items.count) { location(items[$0]) > end }
        return firstIndex(tail) { ends[$0] >= range.location }..<tail
    }
}

struct MarkdownPresentation: Sendable {
    private(set) var spans: [MarkdownPresentationSpan]
    private(set) var headings: [MarkdownHeading]
    private(set) var namedAnchors: [MarkdownNamedAnchor]
    private(set) var images: [MarkdownImage]
    private(set) var diagrams: [MarkdownDiagram]
    private(set) var audioBlocks: [MarkdownAudioBlock]
    private(set) var iframeBlocks: [MarkdownIframeBlock]
    private(set) var detailsBlocks: [MarkdownDetailsBlock]
    private(set) var htmlBlocks: [MarkdownHTMLBlock]
    private(set) var pageBreaks: [NSRange]
    private(set) var ruby: [MarkdownRuby]
    private(set) var links: [MarkdownLink]
    private(set) var formulas: [MarkdownFormula]
    private(set) var inlineFormulas: [MarkdownFormula]
    private(set) var emojiCandidates: [MarkdownEmojiCandidate]
    let emojiCandidatesIncluded: Bool
    private(set) var emojiCompletionRanges: [NSRange]
    private(set) var smartTextRanges: [NSRange]
    private(set) var smartRawHTMLRanges: [NSRange]?
    private(set) var textReplacements: [MarkdownTextReplacement]
    private(set) var paragraphs: [MarkdownParagraph]
    private(set) var completedTaskRanges: [NSRange]
    private(set) var taskCheckboxes: [MarkdownTaskCheckbox]
    private(set) var listMarkers: [MarkdownListMarker]
    private(set) var looseIndents: [MarkdownLooseIndent]
    private(set) var footnotes: [MarkdownFootnote]
    private(set) var tableOfContents: [NSRange]
    private(set) var tables: [MarkdownTable]
    private(set) var codeBlocks: [MarkdownCodeBlock]
    private(set) var fenceContainerLines: [MarkdownFenceContainerLine]
    private(set) var fenceBlockedRanges: [NSRange]
    private(set) var fenceBlockedEOF: Bool
    private(set) var fenceContextAvailable: Bool
    private(set) var readableText: MarkdownReadableText?
    private(set) var wikiLinks: [MarkdownWikiLink] = []
    private(set) var elements: MarkdownElementIndex = .empty
    /// Префиксные максимумы концов `spans` и `completedTaskRanges`; считает `prepareForEditing`, держит `shift`.
    private(set) var spanEnds: [Int] = []
    private(set) var completedEnds: [Int] = []
    private(set) var isReadyForShift = false
    /// Итог `hasOnlyTextStructure` на момент разбора: `shift` заголовки только убирает, поэтому на каждую правку он не считается.
    private var isTextStructureOnly = false

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
    func withWikiLinks(_ links: [MarkdownWikiLink]) -> MarkdownPresentation {
        var copy = self
        copy.wikiLinks = links
        return copy
    }

    func withElements(_ index: MarkdownElementIndex) -> MarkdownPresentation {
        var copy = self
        copy.elements = index
        return copy
    }

    func resolvingHeadingEmoji(_ values: [String: String], readableText: MarkdownReadableText? = nil) -> MarkdownPresentation {
        MarkdownPresentation(spans: spans, headings: headings.map { $0.resolvingEmoji(values) }, namedAnchors: namedAnchors, images: images,
            audioBlocks: audioBlocks, iframeBlocks: iframeBlocks, detailsBlocks: detailsBlocks, htmlBlocks: htmlBlocks, pageBreaks: pageBreaks, ruby: ruby, links: links, diagrams: diagrams, formulas: formulas, inlineFormulas: inlineFormulas,
            emojiCandidates: emojiCandidates, emojiCandidatesIncluded: emojiCandidatesIncluded, emojiCompletionRanges: emojiCompletionRanges, smartTextRanges: smartTextRanges, smartRawHTMLRanges: smartRawHTMLRanges, textReplacements: textReplacements, paragraphs: paragraphs, completedTaskRanges: completedTaskRanges,
            taskCheckboxes: taskCheckboxes, listMarkers: listMarkers, looseIndents: looseIndents, footnotes: footnotes, tableOfContents: tableOfContents, tables: tables,
            codeBlocks: codeBlocks, fenceContainerLines: fenceContainerLines, fenceBlockedRanges: fenceBlockedRanges, fenceBlockedEOF: fenceBlockedEOF,
            fenceContextAvailable: fenceContextAvailable, readableText: readableText ?? self.readableText).withWikiLinks(wikiLinks).withElements(elements)
    }

    func numberingHeadings(_ enabled: Bool) -> MarkdownPresentation {
        MarkdownPresentation(spans: spans, headings: MarkdownHeadingNumbering.applying(to: headings, enabled: enabled), namedAnchors: namedAnchors, images: images,
            audioBlocks: audioBlocks, iframeBlocks: iframeBlocks, detailsBlocks: detailsBlocks, htmlBlocks: htmlBlocks, pageBreaks: pageBreaks, ruby: ruby, links: links, diagrams: diagrams, formulas: formulas, inlineFormulas: inlineFormulas,
            emojiCandidates: emojiCandidates, emojiCandidatesIncluded: emojiCandidatesIncluded, emojiCompletionRanges: emojiCompletionRanges, smartTextRanges: smartTextRanges, smartRawHTMLRanges: smartRawHTMLRanges, textReplacements: textReplacements, paragraphs: paragraphs, completedTaskRanges: completedTaskRanges,
            taskCheckboxes: taskCheckboxes, listMarkers: listMarkers, looseIndents: looseIndents, footnotes: footnotes, tableOfContents: tableOfContents, tables: tables,
            codeBlocks: codeBlocks, fenceContainerLines: fenceContainerLines, fenceBlockedRanges: fenceBlockedRanges, fenceBlockedEOF: fenceBlockedEOF,
            fenceContextAvailable: fenceContextAvailable, readableText: readableText).withWikiLinks(wikiLinks).withElements(elements)
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
                                   plainTextRange: heading.plainTextRange.flatMap(shift), uppercaseRuns: runs, isTopLevel: heading.isTopLevel)
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
        let newWikiLinks = wikiLinks.compactMap { link -> MarkdownWikiLink? in
            let markers = link.markerRanges.compactMap(shift)
            guard let range = shift(link.range), let display = shift(link.displayRange), markers.count == link.markerRanges.count else { return nil }
            return MarkdownWikiLink(range: range, displayRange: display, target: link.target, heading: link.heading, alias: link.alias, markerRanges: markers)
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
                                    tableOfContents: tableOfContents.compactMap(shift), tables: newTables, codeBlocks: newCodeBlocks).withWikiLinks(newWikiLinks)
    }

    /// Нет элементов, чьё установленное состояние (оглавление, якоря, разрывы страниц) сдвигом не переносится, и нет заголовков с номером или заглавными буквами.
    /// Сноски пропускаются: их ссылки и определения сдвигаются правилом `away`.
    /// Картинки, формулы и эмодзи (в том числе в ячейках таблиц), блоки кода, диаграммы, вставки (аудио, iframe, HTML-блоки, details) и ruby пропускаются: их готовые объекты переезжают вместе с ними.
    var hasOnlyTextStructure: Bool {
        pageBreaks.isEmpty && emojiCandidatesIncluded && tableOfContents.isEmpty
            && namedAnchors.isEmpty
            && headings.allSatisfy { $0.number == nil && $0.uppercaseRuns == nil }
    }

    /// Правило сдвига для вида оформления. nil: правка задевает границу или вид не поддерживается.
    private static func shiftedRange(of span: MarkdownPresentationSpan, _ edit: MarkdownTextEdit) -> NSRange? {
        switch span.kind {
        case .heading, .quote:
            return edit.block(span.range)
        case .strong, .emphasis, .strikethrough, .code, .highlight, .subscriptText, .superscriptText:
            return edit.inline(span.range)
        case .tableMath, .tableEmoji, .tableImage:
            return nil
        default:
            return edit.away(span.range)
        }
    }

    private static func isUnshiftable(_ kind: MarkdownPresentationKind) -> Bool {
        switch kind {
        case .tableMath, .tableEmoji, .tableImage: return true
        default: return false
        }
    }

    private static func isOrdered<T>(_ items: [T], _ extent: (T) -> NSRange) -> Bool {
        var end = 0
        for item in items {
            let range = extent(item)
            guard range.location >= end else { return false }
            end = NSMaxRange(range)
        }
        return true
    }

    /// Картинки одного абзаца делят его `paragraphRange`, разные абзацы не пересекаются; сам `range` лежит внутри абзаца.
    private static func isOrdered(_ images: [MarkdownImage]) -> Bool {
        var end = 0, group = NSRange(location: 0, length: 0)
        for image in images {
            guard image.range.location >= end, NSUnionRange(image.range, image.paragraphRange) == image.paragraphRange,
                  image.paragraphRange == group || image.paragraphRange.location >= NSMaxRange(group) else { return false }
            end = NSMaxRange(image.range)
            group = image.paragraphRange
        }
        return true
    }

    /// Ни один элемент из `inner` (по порядку) не лежит в таблице: установленное в таблицах хранится по абсолютным диапазонам и сдвигом не переносится.
    private static func isOutside(_ inner: [NSRange], tables: [MarkdownTable]) -> Bool {
        var table = 0
        for range in inner {
            while table < tables.count, NSMaxRange(tables[table].range) <= range.location { table += 1 }
            guard table < tables.count else { return true }
            if tables[table].range.location < NSMaxRange(range) { return false }
        }
        return true
    }

    /// Наименьшее начало оформления, охватывающего правку или касающегося её; без такого оформления — место правки. Читает до `shift`.
    func firstAffectedLocation(_ edit: MarkdownTextEdit) -> Int {
        let window = edit.window(spans, ends: spanEnds, location: { $0.range.location })
        let covering = spans[window].first { $0.range.location <= edit.range.location && NSMaxRange($0.range) >= edit.range.location }
        return covering?.range.location ?? edit.range.location
    }

    /// Готовит оформление к сдвигу на месте: сортирует `spans`, считает префиксные максимумы концов и проверяет порядок списков,
    /// на котором держатся двоичные поиски. Не на горячем пути: вызывается один раз после разбора.
    mutating func prepareForEditing() {
        isTextStructureOnly = hasOnlyTextStructure
        if zip(spans, spans.dropFirst()).contains(where: { $1.range.location < $0.range.location }) {
            spans.sort { $0.range.location < $1.range.location }
        }
        var peak = 0
        spanEnds = spans.map { peak = max(peak, NSMaxRange($0.range)); return peak }
        peak = 0
        completedEnds = completedTaskRanges.map { peak = max(peak, NSMaxRange($0)); return peak }
        isReadyForShift = !spans.contains(where: { Self.isUnshiftable($0.kind) })
            && !zip(completedTaskRanges, completedTaskRanges.dropFirst()).contains(where: { $1.location < $0.location })
            && Self.isOrdered(paragraphs, { $0.extent }) && Self.isOrdered(listMarkers, { $0.line })
            && Self.isOrdered(links, { $0.range }) && Self.isOrdered(wikiLinks, { $0.range })
            && Self.isOrdered(textReplacements, { $0.range }) && Self.isOrdered(looseIndents, { $0.range })
            && Self.isOrdered(taskCheckboxes, { NSUnionRange($0.markerRange, $0.stateRange) })
            && Self.isOrdered(emojiCompletionRanges, { $0 })
            && Self.isOrdered(tables, { $0.range }) && Self.isOrdered(codeBlocks, { $0.range })
            && Self.isOrdered(images) && Self.isOrdered(formulas, { $0.range }) && Self.isOrdered(inlineFormulas, { $0.range })
            && Self.isOrdered(emojiCandidates, { $0.range }) && Self.isOrdered(headings, { $0.range })
            && Self.isOrdered(namedAnchors, { $0.range }) && Self.isOrdered(pageBreaks, { $0 }) && Self.isOrdered(tableOfContents, { $0 })
            && Self.isOrdered(ruby, { $0.range }) && Self.isOrdered(diagrams, { $0.range }) && Self.isOrdered(audioBlocks, { $0.range })
            && Self.isOrdered(iframeBlocks, { $0.range }) && Self.isOrdered(detailsBlocks, { $0.range }) && Self.isOrdered(htmlBlocks, { $0.range })
            && (tables.isEmpty || Self.isOutside((ruby.map(\.range) + audioBlocks.filter(\.isInline).map(\.range) + iframeBlocks.filter(\.isInline).map(\.range))
                .sorted { $0.location < $1.location }, tables: tables))
    }

    /// Правку можно провести сдвигом на месте. Только чтение: при отказе ничего не изменено.
    func canShift(_ edit: MarkdownTextEdit) -> Bool {
        isTextStructureOnly && canShiftElements(edit)
    }

    /// Все проверки `canShift`, кроме `hasOnlyTextStructure`: по ним решается, выдержат ли сдвиг сами диапазоны элементов (стенд проверяет их отдельно).
    /// Отказ, если правка задевает маркер, ссылку или границу элемента либо лежит вне блока: тогда оформление придётся снять.
    /// Работает только после `prepareForEditing`; смотрит элементы возле правки, остальные по порядку списков заведомо не задеты.
    func canShiftElements(_ edit: MarkdownTextEdit) -> Bool {
        guard isReadyForShift else { return false }
        var covered = false
        for index in edit.window(spans, ends: spanEnds, location: { $0.range.location }) {
            let span = spans[index]
            guard Self.shiftedRange(of: span, edit) != nil, span.markerRanges.allSatisfy({ edit.away($0) != nil }) else { return false }
            switch span.kind {
            case .heading, .quote: if edit.holds(span.range) { covered = true }
            default: break
            }
        }
        for index in edit.window(paragraphs, extent: { $0.extent }) {
            let item = paragraphs[index]
            guard edit.paragraph(item.range) != nil, edit.paragraph(item.lastLine) != nil,
                  item.separatorAfter.map({ edit.after($0) != nil }) ?? true else { return false }
            if edit.holds(item.range) { covered = true }
        }
        for index in edit.window(listMarkers, extent: { $0.line }) {
            let item = listMarkers[index]
            guard edit.away(item.range) != nil, edit.line(item.line) != nil else { return false }
            if edit.holds(item.line) { covered = true }
        }
        guard covered else { return false }
        for index in edit.window(links, extent: { $0.range }) where edit.away(links[index].range) == nil { return false }
        for index in edit.window(wikiLinks, extent: { $0.range }) {
            let item = wikiLinks[index]
            guard edit.away(item.range) != nil, edit.away(item.displayRange) != nil,
                  item.markerRanges.allSatisfy({ edit.away($0) != nil }) else { return false }
        }
        for index in edit.window(emojiCompletionRanges, extent: { $0 }) where edit.block(emojiCompletionRanges[index]) == nil { return false }
        for index in edit.window(textReplacements, extent: { $0.range }) where edit.away(textReplacements[index].range) == nil { return false }
        for index in edit.window(completedTaskRanges, ends: completedEnds, location: { $0.location }) where edit.block(completedTaskRanges[index]) == nil { return false }
        for index in edit.window(taskCheckboxes, extent: { NSUnionRange($0.markerRange, $0.stateRange) }) {
            let item = taskCheckboxes[index]
            guard edit.away(item.markerRange) != nil, edit.away(item.stateRange) != nil else { return false }
        }
        for index in edit.window(looseIndents, extent: { $0.range }) where edit.away(looseIndents[index].range) == nil { return false }
        // Правка в таблице или вплотную к ней: таблицу пересобирает разбор. Вне окна таблицы только сдвигаются.
        guard edit.window(tables, extent: { $0.range }).isEmpty else { return false }
        // Само ограждение проверяют `spans` с метками; блок без своего `span` здесь не проскочит.
        for index in edit.window(codeBlocks, extent: { $0.range }) where edit.away(codeBlocks[index].range) == nil { return false }
        for index in edit.window(images, extent: { $0.paragraphRange }) {
            guard edit.away(images[index].range) != nil, edit.block(images[index].paragraphRange) != nil else { return false }
            // Enter в конце текста без перевода строки: правило блока растит абзац картинки на него, а полный разбор его не включает.
            if edit.lineBreak && edit.atOpenLine && NSMaxRange(images[index].paragraphRange) == edit.range.location { return false }
        }
        for index in edit.window(formulas, extent: { $0.range }) where edit.away(formulas[index].range) == nil { return false }
        for index in edit.window(inlineFormulas, extent: { $0.range }) where edit.away(inlineFormulas[index].range) == nil { return false }
        for index in edit.window(emojiCandidates, extent: { $0.range }) where edit.away(emojiCandidates[index].range) == nil { return false }
        for index in edit.window(namedAnchors, extent: { $0.range }) where edit.away(namedAnchors[index].range) == nil { return false }
        for index in edit.window(pageBreaks, extent: { $0 }) where edit.away(pageBreaks[index]) == nil { return false }
        for index in edit.window(tableOfContents, extent: { $0 }) where edit.away(tableOfContents[index]) == nil { return false }
        for index in edit.window(ruby, extent: { $0.range }) {
            guard edit.away(ruby[index].range) != nil, edit.away(ruby[index].baseRange) != nil, edit.away(ruby[index].readingRange) != nil else { return false }
        }
        // Блоки HTML и диаграммы целиком берут из текста строки (`html`, `body`, `source`): правка внутри устарила бы их, поэтому только `away`.
        for index in edit.window(diagrams, extent: { $0.range }) where edit.away(diagrams[index].range) == nil { return false }
        // Вставки из сырого HTML кончаются пустой строкой: буква на соседней строке впритык меняет разбор, поэтому нужен зазор (`spaced`).
        let reach = edit.reaching(1)
        for index in reach.window(audioBlocks, extent: { $0.range }) where edit.spaced(audioBlocks[index].range) == nil { return false }
        for index in reach.window(iframeBlocks, extent: { $0.range }) where edit.spaced(iframeBlocks[index].range) == nil { return false }
        for index in reach.window(detailsBlocks, extent: { $0.range }) where edit.spaced(detailsBlocks[index].range) == nil { return false }
        for index in reach.window(htmlBlocks, extent: { $0.range }) where edit.spaced(htmlBlocks[index].range) == nil { return false }
        // Определение сноски может стоять где угодно: порядок со ссылками не гарантирован, поэтому проход по всем.
        // Правка в теле определения сюда не доходит: его не покрывает ни один блок текста (`covered`), а `text` сноски от него зависит.
        for note in footnotes where edit.away(note.referenceRange) == nil || edit.away(note.definitionRange) == nil { return false }
        return true
    }

    /// Сдвигает диапазоны на месте, без копий и сортировок. Условие: `canShift(edit)` вернул true.
    /// Сдвигаются и элементы, которые `hasOnlyTextStructure` пока не пропускает; задетый правкой заголовок убирается из списка.
    /// Умный текст, читаемый текст, `elements` и контекст ограждений сбрасываются.
    mutating func shift(_ edit: MarkdownTextEdit) {
        func move(_ range: inout NSRange, _ rule: (NSRange) -> NSRange?) {
            if let value = rule(range) { range = value }
        }
        let first = edit.window(spans, ends: spanEnds, location: { $0.range.location }).lowerBound
        var peak = first > 0 ? spanEnds[first - 1] : 0
        for index in first..<spans.count {
            if let range = Self.shiftedRange(of: spans[index], edit) { spans[index].range = range }
            for marker in spans[index].markerRanges.indices { move(&spans[index].markerRanges[marker], edit.away) }
            peak = max(peak, NSMaxRange(spans[index].range))
            spanEnds[index] = peak
        }
        for index in edit.window(paragraphs, extent: { $0.extent }).lowerBound..<paragraphs.count {
            move(&paragraphs[index].range, edit.paragraph)
            move(&paragraphs[index].lastLine, edit.paragraph)
            if var separator = paragraphs[index].separatorAfter {
                move(&separator, edit.after)
                paragraphs[index].separatorAfter = separator
            }
        }
        for index in edit.window(listMarkers, extent: { $0.line }).lowerBound..<listMarkers.count {
            move(&listMarkers[index].range, edit.away)
            move(&listMarkers[index].line, edit.line)
        }
        for index in edit.window(links, extent: { $0.range }).lowerBound..<links.count { move(&links[index].range, edit.away) }
        for index in edit.window(wikiLinks, extent: { $0.range }).lowerBound..<wikiLinks.count {
            move(&wikiLinks[index].range, edit.away)
            move(&wikiLinks[index].displayRange, edit.away)
            for marker in wikiLinks[index].markerRanges.indices { move(&wikiLinks[index].markerRanges[marker], edit.away) }
        }
        for index in edit.window(emojiCompletionRanges, extent: { $0 }).lowerBound..<emojiCompletionRanges.count {
            move(&emojiCompletionRanges[index], edit.block)
        }
        for index in edit.window(textReplacements, extent: { $0.range }).lowerBound..<textReplacements.count {
            move(&textReplacements[index].range, edit.away)
        }
        let firstCompleted = edit.window(completedTaskRanges, ends: completedEnds, location: { $0.location }).lowerBound
        peak = firstCompleted > 0 ? completedEnds[firstCompleted - 1] : 0
        for index in firstCompleted..<completedTaskRanges.count {
            move(&completedTaskRanges[index], edit.block)
            peak = max(peak, NSMaxRange(completedTaskRanges[index]))
            completedEnds[index] = peak
        }
        for index in edit.window(taskCheckboxes, extent: { NSUnionRange($0.markerRange, $0.stateRange) }).lowerBound..<taskCheckboxes.count {
            move(&taskCheckboxes[index].markerRange, edit.away)
            move(&taskCheckboxes[index].stateRange, edit.away)
        }
        for index in edit.window(looseIndents, extent: { $0.range }).lowerBound..<looseIndents.count { move(&looseIndents[index].range, edit.away) }
        if edit.delta != 0 {
            let firstTable = edit.window(tables, extent: { $0.range }).upperBound
            for index in firstTable..<tables.count { tables[index].shift(by: edit.delta) }
        }
        for index in edit.window(codeBlocks, extent: { $0.range }).lowerBound..<codeBlocks.count {
            move(&codeBlocks[index].range, edit.away)
            move(&codeBlocks[index].bodyRange, edit.away)
            move(&codeBlocks[index].infoRange, edit.away)
            for segment in codeBlocks[index].bodySegments.indices { move(&codeBlocks[index].bodySegments[segment], edit.away) }
            for marker in codeBlocks[index].fenceMarkers.indices { move(&codeBlocks[index].fenceMarkers[marker], edit.away) }
        }
        var heading = edit.window(headings, extent: { $0.range }).lowerBound
        while heading < headings.count {
            guard edit.away(headings[heading].range) != nil else { headings.remove(at: heading); continue }
            move(&headings[heading].range, edit.away)
            if var plain = headings[heading].plainTextRange {
                move(&plain, edit.away)
                headings[heading].plainTextRange = plain
            }
            heading += 1
        }
        for index in edit.window(images, extent: { $0.paragraphRange }).lowerBound..<images.count {
            move(&images[index].range, edit.away)
            move(&images[index].paragraphRange, edit.block)
        }
        for index in edit.window(formulas, extent: { $0.range }).lowerBound..<formulas.count { move(&formulas[index].range, edit.away) }
        for index in edit.window(inlineFormulas, extent: { $0.range }).lowerBound..<inlineFormulas.count { move(&inlineFormulas[index].range, edit.away) }
        for index in edit.window(emojiCandidates, extent: { $0.range }).lowerBound..<emojiCandidates.count { move(&emojiCandidates[index].range, edit.away) }
        for index in edit.window(namedAnchors, extent: { $0.range }).lowerBound..<namedAnchors.count { move(&namedAnchors[index].range, edit.away) }
        for index in edit.window(pageBreaks, extent: { $0 }).lowerBound..<pageBreaks.count { move(&pageBreaks[index], edit.away) }
        for index in edit.window(tableOfContents, extent: { $0 }).lowerBound..<tableOfContents.count { move(&tableOfContents[index], edit.away) }
        for index in edit.window(ruby, extent: { $0.range }).lowerBound..<ruby.count {
            move(&ruby[index].range, edit.away)
            move(&ruby[index].baseRange, edit.away)
            move(&ruby[index].readingRange, edit.away)
        }
        for index in edit.window(diagrams, extent: { $0.range }).lowerBound..<diagrams.count { move(&diagrams[index].range, edit.away) }
        for index in edit.window(audioBlocks, extent: { $0.range }).lowerBound..<audioBlocks.count { move(&audioBlocks[index].range, edit.away) }
        for index in edit.window(iframeBlocks, extent: { $0.range }).lowerBound..<iframeBlocks.count { move(&iframeBlocks[index].range, edit.away) }
        for index in edit.window(detailsBlocks, extent: { $0.range }).lowerBound..<detailsBlocks.count { move(&detailsBlocks[index].range, edit.away) }
        for index in edit.window(htmlBlocks, extent: { $0.range }).lowerBound..<htmlBlocks.count { move(&htmlBlocks[index].range, edit.away) }
        if edit.delta != 0 {
            for index in footnotes.indices {
                move(&footnotes[index].referenceRange, edit.away)
                move(&footnotes[index].definitionRange, edit.away)
            }
        }
        smartTextRanges = []
        smartRawHTMLRanges = nil
        readableText = nil
        elements = .empty
        fenceContainerLines = []
        fenceBlockedRanges = []
        fenceBlockedEOF = false
        fenceContextAvailable = false
    }

    mutating func shiftMediaOnly(_ edit: MarkdownTextEdit) {
        guard edit.delta != 0 else { return }
        func move(_ range: inout NSRange, _ rule: (NSRange) -> NSRange?) {
            if let value = rule(range) { range = value }
        }
        for index in edit.window(images, extent: { $0.paragraphRange }).lowerBound..<images.count {
            move(&images[index].range, edit.away)
            move(&images[index].paragraphRange, edit.block)
        }
        for index in edit.window(formulas, extent: { $0.range }).lowerBound..<formulas.count { move(&formulas[index].range, edit.away) }
        for index in edit.window(inlineFormulas, extent: { $0.range }).lowerBound..<inlineFormulas.count { move(&inlineFormulas[index].range, edit.away) }
        for index in edit.window(diagrams, extent: { $0.range }).lowerBound..<diagrams.count { move(&diagrams[index].range, edit.away) }
        for index in edit.window(audioBlocks, extent: { $0.range }).lowerBound..<audioBlocks.count { move(&audioBlocks[index].range, edit.away) }
        for index in edit.window(iframeBlocks, extent: { $0.range }).lowerBound..<iframeBlocks.count { move(&iframeBlocks[index].range, edit.away) }
        for index in edit.window(detailsBlocks, extent: { $0.range }).lowerBound..<detailsBlocks.count { move(&detailsBlocks[index].range, edit.away) }
        for index in edit.window(htmlBlocks, extent: { $0.range }).lowerBound..<htmlBlocks.count { move(&htmlBlocks[index].range, edit.away) }
    }


    /// Копия с оформлением, сдвинутым под правку; nil, если `canShift` отказал. Для тестов и проверок: экран сдвигает `canShift` и `shift` на месте.
    func shiftedForTextEdit(_ edit: NSRange, replacementLength: Int, textLength: Int) -> MarkdownPresentation? {
        var copy = self
        copy.prepareForEditing()
        let change = MarkdownTextEdit(range: edit, replacementLength: replacementLength, textLength: textLength)
        guard copy.canShift(change) else { return nil }
        copy.shift(change)
        return copy
    }

    /// Enter в конце обычного абзаца: дальше пустая строка или конец текста, абзац начинается с начала строки.
    /// Возвращает правку для `canShift` или nil. Позиция правки берётся после уже стоящего перевода строки: текст тот же.
    func paragraphBreakEdit(in text: NSString, at location: Int) -> MarkdownTextEdit? {
        let length = text.length
        guard location > 0, location <= length else { return nil }
        if location < length {
            guard text.character(at: location) == 10, text.character(at: location - 1) != 13,
                  location + 1 == length || text.character(at: location + 1) == 10 else { return nil }
        }
        let before = text.character(at: location - 1)
        guard before != 10, before != 32, before != 9,
              Self.allowsTypingEdit(in: text, range: NSRange(location: location, length: 0), replacement: "a") else { return nil }
        // Заголовок, цитата и пункт списка: перенос в них ведут прежним путём.
        let probe = MarkdownTextEdit(range: NSRange(location: location, length: 0), replacementLength: 1, textLength: length)
        for index in probe.window(spans, ends: spanEnds, location: { $0.range.location }) {
            switch spans[index].kind {
            case .heading, .quote: if probe.holds(spans[index].range) { return nil }
            default: break
            }
        }
        for index in probe.window(listMarkers, extent: { $0.line }) where probe.holds(listMarkers[index].line) { return nil }
        let point = location < length ? location + 1 : location
        let edit = MarkdownTextEdit(range: NSRange(location: point, length: 0), replacementLength: 1, textLength: length,
                                    lineBreak: true, atOpenLine: text.character(at: point - 1) != 10)
        guard let paragraph = paragraphs[edit.window(paragraphs, extent: { $0.extent })].first(where: { edit.holds($0.range) }),
              NSMaxRange(paragraph.range) == point, NSMaxRange(paragraph.lastLine) == point,
              text.lineRange(for: NSRange(location: paragraph.range.location, length: 0)).location == paragraph.range.location,
              text.character(at: paragraph.range.location) != 32, text.character(at: paragraph.range.location) != 9,
              paragraph.separatorAfter?.location == (point < length ? point : nil) else { return nil }
        return canShift(edit) ? edit : nil
    }

    private static let typingPunctuation: Set<Character> = [",", ".", ";", "!", "?", ":", "(", ")", "-", "«", "»", "“", "”", "‘", "’", "–", "—", "…"]

    private static func isTypingCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == " " || typingPunctuation.contains(character)
            || (character.unicodeScalars.first?.properties.isEmojiPresentation ?? false)
    }

    /// Строка остаётся прозой: есть буква или цифра, отступ меньше 4, начало (если правка рядом) не похоже на разметку блока.
    private static func isProseLine(_ unit: (Int) -> unichar, _ count: Int, head: Bool) -> Bool {
        var first = 0, width = 0
        while first < count, unit(first) == 32 || unit(first) == 9 { width += unit(first) == 9 ? 4 : 1; first += 1 }
        func content(_ value: unichar) -> Bool {
            if value < 128 { return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) }
            return (0xD800...0xDFFF).contains(value) || (Unicode.Scalar(value).map { CharacterSet.alphanumerics.contains($0) } ?? false)
        }
        guard first < count, width < 4, (first..<count).contains(where: { content(unit($0)) }) else { return false }
        guard head else { return true }
        let start = first, lead = unit(start)
        func run() -> Int { var n = 0; while start + n < count, unit(start + n) == lead { n += 1 }; return n }
        func blank(_ index: Int) -> Bool { index >= count || unit(index) == 32 || unit(index) == 9 }
        switch lead {
        case 35, 36, 58, 60, 62, 92, 124: return false
        case 42, 43, 45: return run() < 3 && !blank(start + 1)
        case 95, 96, 126: return run() < 3
        case 91: return !(start + 1 < count && unit(start + 1) == 94)
        case 48...57:
            var index = start
            while index < count, (48...57).contains(unit(index)) { index += 1 }
            return index >= count || (unit(index) != 46 && unit(index) != 41)
        default: return true
        }
    }

    /// Правку обычного текста можно вести быстрым путём по одной строке: она остаётся прозой и не создаёт и не рвёт разметку.
    /// Проверяется только текст до правки; многострочные конструкции (например `$` через строки) эта проверка не видит.
    static func allowsTypingEdit(in text: NSString, range: NSRange, replacement: String) -> Bool {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= text.length,
              replacement.allSatisfy(isTypingCharacter) else { return false }
        let end = NSMaxRange(range)
        // Границы правки лежат на границах составных символов (эмодзи, суррогаты).
        if range.location < text.length, text.rangeOfComposedCharacterSequence(at: range.location).location != range.location { return false }
        if end > 0, end < text.length, text.rangeOfComposedCharacterSequence(at: end).location != end { return false }
        if range.length > 0, !text.substring(with: range).allSatisfy(isTypingCharacter) { return false }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        var contentEnd = NSMaxRange(line)
        while contentEnd > line.location && [10, 13, 0x85, 0x2028, 0x2029].contains(Int(text.character(at: contentEnd - 1))) { contentEnd -= 1 }
        guard end <= contentEnd else { return false }
        let column = range.location - line.location, preCount = contentEnd - line.location
        let inserted = Array(replacement.utf16), postCount = preCount - range.length + inserted.count
        let pre: (Int) -> unichar = { text.character(at: line.location + $0) }
        let post: (Int) -> unichar = { index in
            index < column ? pre(index) : index < column + inserted.count ? inserted[index - column]
                : text.character(at: end + index - column - inserted.count)
        }
        var first = 0
        while first < preCount, pre(first) == 32 || pre(first) == 9 { first += 1 }
        var headLimit = first
        while headLimit < preCount, pre(headLimit) != 32, pre(headLimit) != 9 { headLimit += 1 }
        while headLimit < preCount, pre(headLimit) == 32 || pre(headLimit) == 9 { headLimit += 1 }
        let lineRange = NSRange(location: line.location, length: preCount)
        let head = column <= headLimit
        // HTML в начале содержимого, в том числе после `>` или маркера пункта: правка в теге меняет разбор всего блока.
        let opening = text.range(of: "<", options: [], range: lineRange).location
        if opening != NSNotFound, !text.substring(with: NSRange(location: line.location, length: opening - line.location)).contains(where: \.isLetter) { return false }
        // `]:` — определение ссылки, в том числе внутри цитаты или пункта: адрес из него разбор хранит отдельно.
        guard column >= first, isProseLine(pre, preCount, head: head), isProseLine(post, postCount, head: head),
              text.range(of: "$", options: [], range: lineRange).location == NSNotFound,
              text.range(of: "]:", options: [], range: lineRange).location == NSNotFound else { return false }
        if replacement.contains(where: { "()".contains($0) }), text.range(of: "](", options: [], range: lineRange).location != NSNotFound { return false }
        // Соседи правки: разметочные знаки рядом и склейки `..`, `--` дают умные замены или меняют разбор.
        let lower = max(0, column - 2), upper = min(postCount, column + inserted.count + 2)
        for index in lower..<upper {
            if [42, 95, 126, 61, 94, 96, 91, 93, 60, 62, 124, 36, 92, 38].contains(post(index)) { return false }
            if index > lower, post(index) == post(index - 1), post(index) == 46 || post(index) == 45 { return false }
        }
        // Слово вокруг правки не должно быть адресом, почтой, `:имя:`, сущностью или началом ссылки.
        func tokenIsSafe(_ unit: (Int) -> unichar, _ count: Int, _ from: Int, _ to: Int) -> Bool {
            var start = from, stop = to
            while start > 0, unit(start - 1) != 32, unit(start - 1) != 9 { start -= 1; if from - start > 200 { return false } }
            while stop < count, unit(stop) != 32, unit(stop) != 9 { stop += 1; if stop - to > 200 { return false } }
            let token = String(decoding: (start..<stop).map(unit), as: UTF16.self).lowercased()
            return !["@", "&", "www.", "://", "]("].contains(where: token.contains) && token.filter { $0 == ":" }.count < 2
        }
        guard tokenIsSafe(pre, preCount, column, column + range.length),
              tokenIsSafe(post, postCount, column, column + inserted.count) else { return false }
        // Два пробела подряд сворачиваются отдельной заменой, а отступ строки не должен меняться.
        var postFirst = 0
        while postFirst < postCount, post(postFirst) == 32 || post(postFirst) == 9 { postFirst += 1 }
        if postFirst != first { return false }
        for index in max(first + 1, lower - 1)..<max(first + 1, min(postCount, upper + 1)) where (post(index) == 32 || post(index) == 9) && (post(index - 1) == 32 || post(index - 1) == 9) { return false }
        // Хвостовые пробелы строки прячутся отдельной заменой: правка, оставляющая пробел в конце строки, ведёт старым путём.
        if postCount > 0, post(postCount - 1) == 32 || post(postCount - 1) == 9 { return false }
        // Пробел рядом с пробелом или табуляцией может дать отступ, а сразу после маркера без слов (`#`, `-`, `1.`) — заголовок или список.
        if replacement.contains(" ") {
            guard column > first, range.location > 0 else { return false }
            let before = text.character(at: range.location - 1)
            let hasWord = text.substring(with: NSRange(location: line.location, length: column)).contains { $0.isLetter }
            guard hasWord, before != 32 && before != 9,
                  end >= contentEnd || (text.character(at: end) != 32 && text.character(at: end) != 9) else { return false }
        }
        return true
    }

}

/// Элемент Markdown под курсором для пути в строке состояния.
struct MarkdownElement: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case frontMatter, heading(Int), quote, alert, listItem, task
        case codeBlock(String?), mathBlock, table, footnoteDefinition, htmlBlock
        case strong, emphasis, strikethrough, code, link, footnoteReference, image, formula

        /// Однородные блоки, идущие подряд, в пути схлопываются в один с уровнем.
        fileprivate var family: Int? {
            switch self {
            case .listItem, .task: return 1
            case .quote, .alert: return 2
            default: return nil
            }
        }
    }

    let kind: Kind
    /// Сколько однородных блоков (пункт списка, цитата) идут подряд; у остальных 1.
    var level = 1
}

struct MarkdownElementPath: Equatable, Sendable {
    let elements: [MarkdownElement]
    var isEmpty: Bool { elements.isEmpty }
}

/// Отсортированный индекс элементов одного разбора: поиск по позиции двоичный, без обхода всех элементов.
struct MarkdownElementIndex: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        let range: NSRange
        let kind: MarkdownElement.Kind
        let parent: Int
    }

    let textLength: Int
    private let endsWithLineBreak: Bool
    private let blocks: [Entry]
    private let inlines: [Entry]

    static let empty = MarkdownElementIndex(textLength: 0, blocks: [], inlines: [])

    init(textLength: Int, blocks: [(NSRange, MarkdownElement.Kind)], inlines: [(NSRange, MarkdownElement.Kind)],
         endsWithLineBreak: Bool = false) {
        self.textLength = textLength
        self.endsWithLineBreak = endsWithLineBreak
        self.blocks = Self.nest(blocks, textLength: textLength)
        self.inlines = Self.nest(inlines, textLength: textLength)
    }

    /// Порядок «внешний раньше внутреннего»; записи с неверным или пересекающимся без вложенности диапазоном не становятся потомками.
    private static func nest(_ items: [(NSRange, MarkdownElement.Kind)], textLength: Int) -> [Entry] {
        var valid: [(offset: Int, range: NSRange, kind: MarkdownElement.Kind)] = []
        valid.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let range = item.0
            guard range.location != NSNotFound, range.location >= 0, range.length > 0,
                  range.location <= textLength, range.length <= textLength - range.location else { continue }
            valid.append((offset, range, item.1))
        }
        valid.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.offset < $1.offset
        }
        var result: [Entry] = []
        result.reserveCapacity(valid.count)
        var stack: [Int] = []
        for item in valid {
            let end = NSMaxRange(item.range)
            while let top = stack.last, NSMaxRange(result[top].range) < end { stack.removeLast() }
            result.append(Entry(range: item.range, kind: item.kind, parent: stack.last ?? -1))
            stack.append(result.count - 1)
        }
        return result
    }

    /// Записи, содержащие позицию, от внешней к внутренней.
    private static func chain(_ entries: [Entry], at location: Int, contains: (NSRange) -> Bool) -> [MarkdownElement.Kind] {
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].range.location <= location { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        while index >= 0 && !contains(entries[index].range) { index = entries[index].parent }
        var kinds: [MarkdownElement.Kind] = []
        while index >= 0 {
            kinds.append(entries[index].kind)
            index = entries[index].parent
        }
        return kinds.reversed()
    }

    /// Блоки включают позицию в `[начало, конец)` (в конце текста без перевода строки — и конец), строчные — только строго внутри.
    func path(at location: Int, blocksOnly: Bool = false) -> MarkdownElementPath {
        guard textLength > 0, location >= 0, location <= textLength else { return MarkdownElementPath(elements: []) }
        var kinds = Self.chain(blocks, at: location) { range in
            range.location <= location && (location < NSMaxRange(range) || (!endsWithLineBreak && location == textLength && NSMaxRange(range) == textLength))
        }
        if !blocksOnly {
            kinds += Self.chain(inlines, at: location) { range in range.location < location && location < NSMaxRange(range) }
        }
        var elements: [MarkdownElement] = []
        for kind in kinds {
            if let family = kind.family, let last = elements.last, last.kind.family == family {
                elements[elements.count - 1] = MarkdownElement(kind: kind, level: last.level + 1)
            } else {
                elements.append(MarkdownElement(kind: kind))
            }
        }
        return MarkdownElementPath(elements: elements)
    }

    /// Диапазоны кода, HTML-блоков, формул, таблиц и front matter, пересекающие окно; целые, отсортированные и объединённые.
    func excludedRanges(intersecting window: NSRange) -> [NSRange] {
        func isExcluded(_ kind: MarkdownElement.Kind) -> Bool {
            switch kind {
            case .frontMatter, .codeBlock, .mathBlock, .table, .htmlBlock, .code, .formula: return true
            default: return false
            }
        }
        var found: [NSRange] = []
        for entries in [blocks, inlines] {
            var low = 0, high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if entries[middle].range.location < window.location { low = middle + 1 } else { high = middle }
            }
            // Раньше окна могут начинаться только предки записи перед ним.
            var index = low - 1
            while index >= 0 {
                let entry = entries[index]
                if NSMaxRange(entry.range) > window.location, isExcluded(entry.kind) { found.append(entry.range) }
                index = entry.parent
            }
            index = low
            while index < entries.count, entries[index].range.location < NSMaxRange(window) {
                if isExcluded(entries[index].kind) { found.append(entries[index].range) }
                index += 1
            }
        }
        found.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in found {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
