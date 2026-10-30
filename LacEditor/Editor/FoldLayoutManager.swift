import AppKit
import CoreText

enum EditorLayoutPolicy {
    static let viewportLayoutThreshold = 500_000

    static func usesViewportLayout(textLength: Int) -> Bool {
        textLength > viewportLayoutThreshold
    }

    static func configure(
        _ layoutManager: NSLayoutManager,
        textLength: Int
    ) {
        // TextKit 1 otherwise lays out continuously from the beginning of the
        // document. That makes deep scrolling and width changes progressively
        // more expensive even for files below the large-file threshold.
        let usesViewportLayout = usesViewportLayout(textLength: textLength)
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.backgroundLayoutEnabled = !usesViewportLayout
    }
}

final class FoldLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    static let defaultLineSpacing: CGFloat = 4

    /// The font selected by the user, not the fallback font AppKit may return
    /// for the first glyph in the document. Keeping these metrics independent
    /// of document contents prevents mixed CJK/Latin input from moving a line.
    var textFont = NSFont(name: "Menlo-Regular", size: 14)
        ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet {
            guard textFont != oldValue else { return }
            updateFontMetrics()
            invalidateEditorLayout()
        }
    }

    var editorLineSpacing = FoldLayoutManager.defaultLineSpacing {
        didSet {
            guard editorLineSpacing != oldValue else { return }
            invalidateEditorLayout()
        }
    }

    var markdownCodeFont: NSFont? {
        didSet {
            guard markdownCodeFont != oldValue else { return }
            for table in tableLines.tables { invalidateMarkdownLayout(in: table.range) }
        }
    }

    var markdownLigatures: Int? {
        didSet {
            guard markdownLigatures != oldValue else { return }
            for table in tableLines.tables { invalidateMarkdownLayout(in: table.range) }
        }
    }

    var markdownSmallCapsLevels: Set<Int> = []
    var markdownParagraphSpacing: CGFloat?
    var markdownTextAlignment: NSTextAlignment?
    var markdownRightToLeft = false
    var markdownStrikeCompletedTasks = false
    var markdownListStyles = MarkdownListStyles() {
        didSet { resolvedListStyles = MarkdownResolvedListStyles(markdownListStyles) }
    }
    private var resolvedListStyles = MarkdownResolvedListStyles(.init())
    var markdownCenteredHeadingLevels: Set<Int> = []
    private var smallCapsFonts: [NSFont: NSFont] = [:]
    private var fontsWithoutSmallCaps: Set<NSFont> = []

    static func supportsSmallCaps(_ font: NSFont) -> Bool {
        let coreFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
        guard let features = CTFontCopyFeatures(coreFont) as? [[String: Any]] else { return false }
        return features.contains { feature in
            guard (feature[kCTFontFeatureTypeIdentifierKey as String] as? NSNumber)?.intValue == kLowerCaseType,
                  let selectors = feature[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] else { return false }
            return selectors.contains { ($0[kCTFontFeatureSelectorIdentifierKey as String] as? NSNumber)?.intValue == kLowerCaseSmallCapsSelector }
        }
    }

    func smallCapsFont(_ font: NSFont) -> NSFont? {
        if let cached = smallCapsFonts[font] { return cached }
        if fontsWithoutSmallCaps.contains(font) { return nil }
        guard Self.supportsSmallCaps(font) else { fontsWithoutSmallCaps.insert(font); return nil }
        let feature: [NSFontDescriptor.FeatureKey: Int] = [
            .typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        guard let result = NSFont(descriptor: descriptor, size: font.pointSize) else {
            fontsWithoutSmallCaps.insert(font)
            return nil
        }
        smallCapsFonts[font] = result
        return result
    }

    var markdownColors = MarkdownColorOverrides()

    private var cachedDefaultLineHeight: CGFloat = 1
    private var cachedDefaultBaselineOffset: CGFloat = 0
    private var groupsTemporaryAttributeUpdates = false
    private var pendingTemporaryDisplayRange: NSRange?
    private var pendingViewportDisplayRange: NSRange?
    private var viewportDisplayScheduled = false

    var editorLineHeight: CGFloat {
        max(1, cachedDefaultLineHeight + editorLineSpacing)
    }

    private(set) var foldedRange: NSRange?
    private(set) var automaticMediaFoldedRanges: [NSRange] = []
    private struct MarkdownMarker {
        let range: NSRange
        let owner: NSRange
        let inline: Bool
    }
    private var markdownMarkers: [MarkdownMarker] = []
    private var markdownMarkerEnds: [Int] = []
    private var markdownContainers: [NSRange] = []
    private var markdownContainerEnds: [Int] = []
    private var markdownHeadings: [MarkdownPresentationSpan] = []
    private var markdownHeadingNumberWidths: [Int: CGFloat] = [:]
    private var markdownNumberedHeadingsBySource: [MarkdownHeading] = []
    private var markdownAlerts: [MarkdownPresentationSpan] = []
    private var markdownRevealedRange: NSRange?
    private var markdownInlineSelection: NSRange?
    private var markdownTextReplacements: [MarkdownTextReplacement] = []
    private var markdownImages: [(range: NSRange, image: NSImage)] = []
    private var markdownMedia: [(range: NSRange, size: NSSize)] = []
    private var markdownBlockImages: [(range: NSRange, image: NSImage)] = []
    private struct UppercaseHeadingVisual {
        let sourceRange: NSRange
        let projection: MarkdownHeadingUppercaseProjection
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        let size: NSSize
        let image: NSImage
        let attachments: [(source: NSRange, display: NSRange)]
        let orientation: NSLayoutManager.TextLayoutOrientation
    }
    private var uppercaseHeadingVisuals: [NSRange: UppercaseHeadingVisual] = [:]
    private var markdownMathReferences: [NSRange: [(rect: CGRect, target: NSRange)]] = [:]
    private var markdownInlineImages: [(range: NSRange, image: NSImage)] = []
    private var markdownRubyBaselines: [NSRange: NSPoint] = [:]
    private var markdownTableMathImages: [NSRange: NSImage] = [:]
    private var markdownEmojiAccessibility: [NSRange: String] = [:]
    private var markdownTaskCheckboxes: [MarkdownTaskCheckbox] = []
    private var markdownListMarkers: [MarkdownListMarker] = []
    private var markdownParagraphs: [MarkdownParagraph] = []
    private var markdownCompletedTasks: [NSRange] = []
    private var markdownCompletedTaskEnds: [Int] = []
    private var markdownParagraphSeparators: [(range: NSRange, owner: NSRange)] = []
    private var markdownTOCRanges: [NSRange] = []
    private var markdownPageBreaks: [NSRange] = []
    private var markdownTOCHeadings: [MarkdownHeading] = []
    private var visibleTOCHeadings: [MarkdownHeading] = []
    var markdownTOCMaxLevel: Int = 6 {
        didSet {
            guard oldValue != markdownTOCMaxLevel else { return }
            visibleTOCHeadings = markdownTOCHeadings.filter { $0.level <= markdownTOCMaxLevel }
            for range in markdownTOCRanges { invalidateMarkdownLayout(in: range) }
        }
    }
    private struct TableLine {
        let range: NSRange
        let row: MarkdownTableRow?
        let columns: Int
        let containerPrefix: String
        let tableRange: NSRange
        let rowIndex: Int
        let rowCount: Int
    }
    private struct TableLines: RandomAccessCollection {
        let tables: [MarkdownTable]
        let ends: [Int]
        init(_ tables: [MarkdownTable] = []) {
            let sorted = tables.sorted { $0.range.location < $1.range.location }
            self.tables = sorted
            var count = 0
            ends = sorted.map { count += $0.rows.count + 1; return count }
        }
        var startIndex: Int { 0 }
        var endIndex: Int { ends.last ?? 0 }
        private func item(_ index: Int) -> (MarkdownTable, Int) {
            var low = 0, high = ends.count
            while low < high {
                let mid = low + (high - low) / 2
                if ends[mid] <= index { low = mid + 1 } else { high = mid }
            }
            return (tables[low], index - (low == 0 ? 0 : ends[low - 1]))
        }
        func location(at index: Int) -> Int {
            let (table, local) = item(index)
            return local == 1 ? table.delimiterRange.location : table.rows.range(at: local == 0 ? 0 : local - 1).location
        }
        subscript(index: Int) -> TableLine {
            let (table, local) = item(index)
            let rowIndex = local == 1 ? -1 : (local == 0 ? 0 : local - 1)
            let row = rowIndex < 0 ? nil : table.rows[rowIndex]
            return TableLine(range: row?.range ?? table.delimiterRange, row: row, columns: table.alignments.count,
                             containerPrefix: table.containerPrefix, tableRange: table.range,
                             rowIndex: rowIndex, rowCount: table.rows.count)
        }
    }
    private var tableLines = TableLines()
    func accessibilityTableModel(_ range: NSRange) -> MarkdownTable? {
        tableLines.tables.first { $0.range == range }
    }
    private var activeTableRange: NSRange?

    enum TableDragAxis: Equatable { case row, column }
    struct TableDragHandle {
        let tableRange: NSRange
        let cell: MarkdownTableCell
        let row: Int
        let column: Int
        let axis: TableDragAxis
    }

    struct TableAccessibilityCell {
        let tableRange: NSRange
        let row: Int
        let rowCount: Int
        let columnCount: Int
        let cell: MarkdownTableCell
        let frame: NSRect
    }

    func visibleTableAccessibilityCells(in container: NSTextContainer) -> [TableAccessibilityCell] {
        guard let view = container.textView, !tableLines.isEmpty else { return [] }
        let visibleRect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        let visible = characterRange(forGlyphRange: glyphRange(forBoundingRect: visibleRect, in: container), actualGlyphRange: nil)
        var index = upperBound(visible.location, count: tableLines.count) { tableLines.location(at: $0) }
        if index > 0 { index -= 1 }
        var result: [TableAccessibilityCell] = []
        while index < tableLines.count {
            let line = tableLines[index]
            index += 1
            if line.range.location >= NSMaxRange(visible) { break }
            guard line.row != nil, NSIntersectionRange(line.range, visible).length > 0,
                  tableLine(at: line.range.location) != nil else { continue }
            let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
            let (indent, width) = tableHorizontalGeometry(line, container: container)
            for item in tableLineGeometry(line, width: width) {
                let frame = item.rect.offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent, dy: fragment.minY)
                guard frame.intersects(visibleRect) else { continue }
                result.append(TableAccessibilityCell(tableRange: line.tableRange, row: line.rowIndex,
                    rowCount: line.rowCount, columnCount: line.columns, cell: item.cell, frame: frame))
            }
        }
        return result
    }

    func setActiveTableRange(_ range: NSRange?) {
        activeTableRange = range
        textContainers.first?.textView?.needsDisplay = true
    }

    @discardableResult
    func clearActiveTableIfSelectionOutside(_ selection: NSRange) -> Bool {
        guard let activeTableRange else { return false }
        if selection.location < activeTableRange.location || selection.location > NSMaxRange(activeTableRange) {
            setActiveTableRange(nil)
            return true
        }
        return false
    }

    private func tableLine(at location: Int) -> TableLine? {
        let index = upperBound(location, count: tableLines.count) { tableLines.location(at: $0) }
        guard index > 0 else { return nil }
        let line = tableLines[index - 1]
        guard NSLocationInRange(location, line.range),
              !intersectsFoldedRange(line.range),
              textContainers.first?.textView?.hasMarkedText() != true else { return nil }
        return line
    }

    private func tableLine(intersecting range: NSRange) -> TableLine? {
        let index = upperBound(range.location, count: tableLines.count) { tableLines.location(at: $0) }
        if index > 0, let line = tableLine(at: range.location), NSIntersectionRange(line.range, range).length > 0 { return line }
        guard index < tableLines.count, tableLines[index].range.location < NSMaxRange(range) else { return nil }
        return tableLine(at: tableLines[index].range.location)
    }

    /// Таблица или блочное изображение/медиа внутри диапазона: их нельзя делить на предложения.
    func containsAtomicBlock(in range: NSRange) -> Bool {
        if tableLine(intersecting: range) != nil { return true }
        return markdownBlockImages.contains { NSIntersectionRange($0.range, range).length > 0 }
            || markdownMedia.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    func markdownTableFrame(for cellRange: NSRange, in container: NSTextContainer) -> NSRect? {
        guard let line = tableLine(at: cellRange.location), let row = line.row,
              row.cells.contains(where: { $0.range == cellRange }),
              line.range.location < (textStorage?.length ?? 0) else { return nil }
        let (indent, width) = tableHorizontalGeometry(line, container: container)
        let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
        return tableLineGeometry(line, width: width).first(where: { $0.cell.range == cellRange })?.rect
            .offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent, dy: fragment.minY)
    }

    func markdownTableFrame(for cell: MarkdownTableCell, in container: NSTextContainer) -> NSRect? {
        let line = tableLine(at: cell.range.location) ?? (cell.range.location > 0 ? tableLine(at: cell.range.location - 1) : nil)
        guard let line, let row = line.row, row.cells.contains(where: { $0.range == cell.range && $0.column == cell.column && $0.virtualSeparators == cell.virtualSeparators }),
              line.range.location < (textStorage?.length ?? 0) else { return nil }
        let (indent, width) = tableHorizontalGeometry(line, container: container)
        let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
        return tableLineGeometry(line, width: width).first(where: { $0.cell.range == cell.range && $0.cell.column == cell.column && $0.cell.virtualSeparators == cell.virtualSeparators })?.rect
            .offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent, dy: fragment.minY)
    }

    func markdownTableFrame(containing range: NSRange, in container: NSTextContainer) -> NSRect? {
        guard let row = tableLine(at: range.location)?.row else { return nil }
        var low = 0, high = row.cells.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(row.cells[middle].range) <= range.location { low = middle + 1 } else { high = middle }
        }
        guard low < row.cells.count, range.location >= row.cells[low].range.location,
              NSMaxRange(range) <= NSMaxRange(row.cells[low].range) else { return nil }
        return markdownTableFrame(for: row.cells[low], in: container)
    }

    private func tableHorizontalGeometry(_ line: TableLine, container: NSTextContainer) -> (CGFloat, CGFloat) {
        let indent = (line.containerPrefix as NSString).size(withAttributes: [.font: textFont]).width
        return (markdownRightToLeft ? 0 : indent + 12, max(1, container.size.width - 2 * container.lineFragmentPadding - indent - 12))
    }

    private func tableLineGeometry(_ line: TableLine, width: CGFloat) -> [TableCellGeometry] {
        guard let row = line.row, line.columns > 0, let text = textStorage?.mutableString else { return [] }
        let table = MarkdownTable(range: line.range, delimiterRange: NSRange(location: 0, length: 0),
            alignments: Array(repeating: .unspecified, count: line.columns), rows: [row])
        return markdownTableGeometry(table, text: text, width: width).map { item in
            TableCellGeometry(cell: item.cell, rect: item.rect.offsetBy(dx: 0, dy: line.rowIndex == 0 ? 12 : 0))
        }
    }

    func markdownTableCell(at point: NSPoint, in container: NSTextContainer) -> (NSRange, NSRect)? {
        guard let (cell, frame) = markdownTableCellInfo(at: point, in: container) else { return nil }
        return (cell.range, frame)
    }

    func markdownTableCellInfo(at point: NSPoint, in container: NSTextContainer) -> (MarkdownTableCell, NSRect)? {
        guard let view = container.textView, !tableLines.isEmpty else { return nil }
        let visibleRect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        guard visibleRect.contains(point) else { return nil }
        let visible = characterRange(forGlyphRange: glyphRange(forBoundingRect: visibleRect, in: container), actualGlyphRange: nil)
        var index = upperBound(visible.location, count: tableLines.count) { tableLines.location(at: $0) }
        if index > 0 { index -= 1 }
        while index < tableLines.count {
            let line = tableLines[index]
            index += 1
            if line.range.location >= NSMaxRange(visible) { break }
            guard NSIntersectionRange(line.range, visible).length > 0, tableLine(at: line.range.location) != nil,
                  line.row != nil, line.range.location < (textStorage?.length ?? 0) else { continue }
            let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
            let (indent, width) = tableHorizontalGeometry(line, container: container)
            for cell in tableLineGeometry(line, width: width) {
                let frame = cell.rect.offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent, dy: fragment.minY)
                if frame.contains(point) { return (cell.cell, frame) }
            }
        }
        return nil
    }

    func markdownTableLinkRange(at point: NSPoint, in container: NSTextContainer) -> NSRange? {
        guard let (cell, frame) = markdownTableCellInfo(at: point, in: container),
              cell.virtualSeparators == 0, let text = textStorage?.mutableString else { return nil }
        let inset = frame.insetBy(dx: 4, dy: 4)
        guard inset.contains(point) else { return nil }
        let textLayout = tableTextLayout(tableCellAttributedText(cell, text: text), width: inset.width)
        defer { withExtendedLifetime(textLayout.0) {} }
        let layout = textLayout.1, cellContainer = textLayout.2
        let local = NSPoint(x: point.x - inset.minX, y: point.y - inset.minY)
        let glyph = layout.glyphIndex(for: local, in: cellContainer)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: cellContainer).contains(local) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        let replacements = cell.displayRuns.compactMap { run -> NSRange? in
            guard let relative = tableImageSource(run.kind),
                  markdownTableMathImages[NSRange(location: cell.range.location + relative.location, length: relative.length)] != nil else { return nil }
            return run.range
        }.sorted { $0.location < $1.location }
        func mapped(_ offset: Int) -> Int? {
            var delta = 0
            for range in replacements {
                if offset < range.location { break }
                if offset > range.location && offset < NSMaxRange(range) { return nil }
                if offset >= NSMaxRange(range) { delta += range.length - 1 }
            }
            return offset - delta
        }
        let matches = cell.displayRuns.compactMap { run -> NSRange? in
            guard run.kind == .link, let raw = run.sourceRange, raw.location >= 0,
                  NSMaxRange(raw) <= cell.range.length,
                  let start = mapped(run.range.location), let end = mapped(NSMaxRange(run.range)),
                  end > start, NSLocationInRange(character, NSRange(location: start, length: end - start)) else { return nil }
            return NSRange(location: cell.range.location + raw.location, length: raw.length)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func tableDragHandle(at point: NSPoint, in container: NSTextContainer) -> TableDragHandle? {
        guard let activeTableRange, let view = container.textView else { return nil }
        let visibleRect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        guard visibleRect.contains(point) else { return nil }
        let visible = characterRange(forGlyphRange: glyphRange(forBoundingRect: visibleRect, in: container), actualGlyphRange: nil)
        var index = upperBound(visible.location, count: tableLines.count) { tableLines.location(at: $0) }
        if index > 0 { index -= 1 }
        while index < tableLines.count {
            let line = tableLines[index]
            index += 1
            if line.range.location >= NSMaxRange(visible) { break }
            guard line.tableRange == activeTableRange, line.row != nil,
                  NSIntersectionRange(line.range, visible).length > 0, tableLine(at: line.range.location) != nil else { continue }
            let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
            let (indent, width) = tableHorizontalGeometry(line, container: container)
            for item in tableLineGeometry(line, width: width) {
                let frame = item.rect.offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent, dy: fragment.minY)
                let axis: TableDragAxis
                let handle: NSRect
                if line.rowIndex == 0 {
                    axis = .column
                    handle = NSRect(x: frame.midX - 6, y: frame.minY - 12, width: 12, height: 12)
                } else if item.cell.column == 0 {
                    axis = .row
                    handle = NSRect(x: markdownRightToLeft ? frame.maxX : frame.minX - 12, y: frame.midY - 6, width: 12, height: 12)
                } else { continue }
                if handle.contains(point) {
                    return TableDragHandle(tableRange: line.tableRange, cell: item.cell,
                                           row: line.rowIndex, column: item.cell.column, axis: axis)
                }
            }
        }
        return nil
    }

    func tableDragTarget(at point: NSPoint, in container: NSTextContainer, axis: TableDragAxis) -> TableDragHandle? {
        guard let (cell, _) = markdownTableCellInfo(at: point, in: container),
              let line = tableLine(at: cell.range.location) ?? (cell.range.location > 0 ? tableLine(at: cell.range.location - 1) : nil),
              line.tableRange == activeTableRange, line.row?.cells.contains(cell) == true,
              axis == .column || line.rowIndex > 0 else { return nil }
        return TableDragHandle(tableRange: line.tableRange, cell: cell, row: line.rowIndex, column: cell.column, axis: axis)
    }

    struct TableCellGeometry {
        let cell: MarkdownTableCell
        let rect: NSRect
    }

    private func tableTextLayout(_ text: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return (storage, layout, container)
    }

    private func tableImageSource(_ kind: MarkdownPresentationKind) -> NSRange? {
        switch kind {
        case let .tableMath(range), let .tableEmoji(range), let .tableImage(range): return range
        default: return nil
        }
    }

    func markdownTableEmojiFonts(for ranges: [NSRange]) -> [NSRange: NSFont] {
        guard let text = textStorage?.mutableString else { return [:] }
        var cells: [NSRange: (NSAttributedString, [NSRange: Int])] = [:]
        var result: [NSRange: NSFont] = [:]
        for range in ranges {
            guard let row = tableLine(at: range.location)?.row else { continue }
            var low = 0, high = row.cells.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(row.cells[middle].range) <= range.location { low = middle + 1 } else { high = middle }
            }
            guard low < row.cells.count else { continue }
            let cell = row.cells[low]
            guard range.location >= cell.range.location, NSMaxRange(range) <= NSMaxRange(cell.range) else { continue }
            if cells[cell.range] == nil {
                var offsets: [NSRange: Int] = [:]
                for run in cell.displayRuns {
                    guard case let .tableEmoji(relative) = run.kind else { continue }
                    offsets[NSRange(location: cell.range.location + relative.location, length: relative.length)] = run.range.location
                }
                cells[cell.range] = (tableCellAttributedText(cell, text: text, includeImages: false), offsets)
            }
            guard let (display, offsets) = cells[cell.range], let offset = offsets[range],
                  offset >= 0, offset < display.length,
                  let font = display.attribute(.font, at: offset, effectiveRange: nil) as? NSFont else { continue }
            result[range] = font
        }
        return result
    }

    func setMarkdownEmojiAccessibility(_ value: String, for range: NSRange) {
        markdownEmojiAccessibility[range] = value
    }

    func markdownTableAccessibleText(_ cell: MarkdownTableCell) -> String? {
        guard let text = cell.displayText as NSString? else { return nil }
        let result = NSMutableString(string: "")
        var offset = 0
        for run in cell.displayRuns {
            guard let relative = tableImageSource(run.kind),
                  relative.location >= 0, NSMaxRange(relative) <= cell.range.length,
                  run.range.location >= offset, NSMaxRange(run.range) <= text.length else { continue }
            let range = NSRange(location: cell.range.location + relative.location, length: relative.length)
            guard markdownTableMathImages[range] != nil else { continue }
            let replacement: String
            if case .tableEmoji = run.kind {
                guard let value = markdownEmojiAccessibility[range] else { continue }
                replacement = value
            } else { replacement = "\u{fffc}" }
            result.append(text.substring(with: NSRange(location: offset, length: run.range.location - offset)))
            result.append(replacement)
            offset = NSMaxRange(run.range)
        }
        result.append(text.substring(from: offset))
        return result as String
    }

    func tableCellAttributedText(_ cell: MarkdownTableCell, text: NSString, includeImages: Bool = true) -> NSAttributedString {
        let value = cell.displayText ?? text.substring(with: cell.range)
        let result = NSMutableAttributedString(string: value, attributes: [.font: textFont, .foregroundColor: markdownColors.text?.nsColor ?? NSColor.textColor])
        if markdownRightToLeft, result.length > 0 {
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = .rightToLeft
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        }
        if let markdownLigatures, result.length > 0 {
            result.addAttribute(.ligature, value: markdownLigatures, range: NSRange(location: 0, length: result.length))
        }
        if markdownStrikeCompletedTasks, result.length > 0 {
            let index = upperBound(cell.range.location, count: markdownCompletedTaskEnds.count) { markdownCompletedTaskEnds[$0] }
            if index < markdownCompletedTasks.count && NSIntersectionRange(markdownCompletedTasks[index], cell.range).length > 0 {
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: result.length))
            }
        }
        for run in cell.displayRuns {
            guard run.range.location >= 0, run.range.length > 0, run.range.location <= result.length,
                  run.range.length <= result.length - run.range.location else { continue }
            switch run.kind {
            case .strong, .emphasis, .code, .keyboard:
                var segments: [(NSRange, NSFont)] = []
                result.enumerateAttribute(.font, in: run.range) { value, range, _ in
                    segments.append((range, value as? NSFont ?? self.textFont))
                }
                for (range, font) in segments {
                    var updated: NSFont
                    switch run.kind {
                    case .strong: updated = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    case .emphasis: updated = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    default:
                        updated = markdownCodeFont.map { NSFontManager.shared.convert($0, toSize: font.pointSize) }
                            ?? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                    }
                    if run.kind == .keyboard {
                        let traits = NSFontManager.shared.traits(of: font)
                        if traits.contains(.boldFontMask) { updated = NSFontManager.shared.convert(updated, toHaveTrait: .boldFontMask) }
                        if traits.contains(.italicFontMask) { updated = NSFontManager.shared.convert(updated, toHaveTrait: .italicFontMask) }
                    }
                    result.addAttribute(.font, value: updated, range: range)
                }
            case .strikethrough: result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            case .link:
                result.addAttribute(.foregroundColor, value: markdownColors.link?.nsColor ?? NSColor.linkColor, range: run.range)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run.range)
            default: break
            }
        }
        let inlineStyles = cell.displayRuns.filter { if case .inlineStyle = $0.kind { return true }; return false }
            .sorted {
                if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
                if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
                return ($0.sourceRange?.location ?? Int.max) < ($1.sourceRange?.location ?? Int.max)
            }
        for run in inlineStyles {
            guard case .inlineStyle(let style) = run.kind, run.range.location >= 0, run.range.length > 0,
                  NSMaxRange(run.range) <= result.length else { continue }
            if let size = style.fontSize {
                var fonts: [(NSRange, NSFont)] = []
                result.enumerateAttribute(.font, in: run.range) { value, range, _ in
                    fonts.append((range, value as? NSFont ?? self.textFont))
                }
                for (range, font) in fonts {
                    result.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: CGFloat(size)), range: range)
                }
            }
            if let color = style.foreground { result.addAttribute(.foregroundColor, value: color.nsColor, range: run.range) }
            if let color = style.background { result.addAttribute(.backgroundColor, value: color.nsColor, range: run.range) }
        }
        if includeImages {
            for run in cell.displayRuns.reversed() {
                guard let relative = tableImageSource(run.kind),
                      run.range.location >= 0, NSMaxRange(run.range) <= result.length,
                      relative.location >= 0, NSMaxRange(relative) <= cell.range.length else { continue }
                let sourceRange = NSRange(location: cell.range.location + relative.location, length: relative.length)
                guard let image = markdownTableMathImages[sourceRange] else { continue }
                let attachment = NSTextAttachment()
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: tableAttachmentImage(image))
                result.replaceCharacters(in: run.range, with: NSAttributedString(attachment: attachment))
            }
        }
        if textContainers.first?.layoutOrientation == .vertical, result.length > 0 {
            result.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    private func tableAttachmentImage(_ image: NSImage) -> NSImage {
        guard let view = textContainers.first?.textView, view.layoutOrientation == .vertical else { return image }
        let size = NSSize(width: image.size.height, height: image.size.width)
        let rotation = view.boundsRotation
        return NSImage(size: size, flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: Double(rect.midX), yBy: Double(rect.midY))
            transform.rotate(byDegrees: Double(rotation))
            transform.concat()
            image.draw(in: NSRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    // Only called for a table whose geometry is needed in the current viewport.
    func markdownTableGeometry(_ table: MarkdownTable, text: NSString, width: CGFloat) -> [TableCellGeometry] {
        guard !table.alignments.isEmpty, width > 0 else { return [] }
        let columnWidth = width / CGFloat(table.alignments.count)
        var y: CGFloat = 0
        var result: [TableCellGeometry] = []
        for row in table.rows {
            var height = editorLineHeight
            for cell in row.cells {
                guard cell.range.location <= text.length,
                      cell.range.length <= text.length - cell.range.location else { return [] }
                let content = tableCellAttributedText(cell, text: text)
                let textLayout = tableTextLayout(content, width: columnWidth - 8)
                defer { withExtendedLifetime(textLayout.0) {} }
                let measured = textLayout.1.usedRect(for: textLayout.2)
                height = max(height, ceil(measured.height) + 8)
            }
            for cell in row.cells {
                let column = markdownRightToLeft ? table.alignments.count - 1 - cell.column : cell.column
                result.append(TableCellGeometry(cell: cell, rect: NSRect(x: CGFloat(column) * columnWidth,
                                                                         y: y, width: columnWidth, height: height)))
            }
            y += height
        }
        return result
    }

    private func tocRows(width: CGFloat) -> [(MarkdownHeading, NSRect)] {
        var y: CGFloat = 0
        var attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        if textContainers.first?.layoutOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
        return visibleTOCHeadings.map { heading in
            let indent = CGFloat(max(0, heading.level - 1)) * textFont.pointSize
            let available = max(1, width - indent)
            let bounds = (heading.numberedTitle as NSString).boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            let height = max(editorLineHeight, ceil(bounds.height))
            let rect = NSRect(x: indent, y: y, width: available, height: height)
            y += height
            return (heading, rect)
        }
    }

    func markdownTOC(at point: NSPoint, in container: NSTextContainer) -> (range: NSRange, heading: MarkdownHeading?)? {
        guard let view = container.textView, !markdownTOCRanges.isEmpty else { return nil }
        let visibleRect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        guard visibleRect.contains(point) else { return nil }
        let glyphs = glyphRange(forBoundingRect: visibleRect, in: container)
        let visible = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = upperBound(visible.location, count: markdownTOCRanges.count) { markdownTOCRanges[$0].location }
        if index > 0 { index -= 1 }
        while index < markdownTOCRanges.count {
            let range = markdownTOCRanges[index]
            if range.location >= NSMaxRange(visible) { break }
            index += 1
            guard NSIntersectionRange(range, visible).length > 0, imageIsVisible(range),
                  range.location < (textStorage?.length ?? 0) else { continue }
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let width = max(1, container.size.width - 2 * container.lineFragmentPadding)
            let area = NSRect(x: line.minX + container.lineFragmentPadding, y: line.minY, width: width, height: line.height)
            guard area.contains(point) else { continue }
            let relative = NSPoint(x: point.x - area.minX, y: point.y - area.minY)
            return (range, tocRows(width: width).first { $0.1.contains(relative) }?.0)
        }
        return nil
    }

    private func pageBreak(containing location: Int) -> NSRange? {
        let index = upperBound(location, count: markdownPageBreaks.count) { markdownPageBreaks[$0].location }
        guard index > 0 else { return nil }
        let range = markdownPageBreaks[index - 1]
        guard NSLocationInRange(location, range),
              !intersectsFoldedRange(range),
              !(markdownRevealedRange.map { touches(range, $0) } ?? false) else { return nil }
        return range
    }

    func markdownPageBreakRect(for range: NSRange, in container: NSTextContainer) -> NSRect? {
        guard pageBreak(containing: range.location) == range, range.location < (textStorage?.length ?? 0) else { return nil }
        let glyph = glyphIndexForCharacter(at: range.location)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let start = line.minX + location(forGlyphAt: glyph).x
        return NSRect(x: start, y: line.minY, width: max(1, container.size.width - start - container.lineFragmentPadding), height: line.height)
    }

    func markdownPageBreak(at point: NSPoint, in container: NSTextContainer) -> NSRange? {
        guard let view = container.textView else { return nil }
        let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        guard visible.contains(point) else { return nil }
        let chars = characterRange(forGlyphRange: glyphRange(forBoundingRect: visible, in: container), actualGlyphRange: nil)
        var index = upperBound(chars.location, count: markdownPageBreaks.count) { markdownPageBreaks[$0].location }
        if index > 0 { index -= 1 }
        while index < markdownPageBreaks.count {
            let range = markdownPageBreaks[index]
            if range.location >= NSMaxRange(chars) { break }
            index += 1
            if markdownPageBreakRect(for: range, in: container)?.contains(point) == true { return range }
        }
        return nil
    }

    private func visibleTOC(containing location: Int) -> Bool {
        let index = upperBound(location, count: markdownTOCRanges.count) { markdownTOCRanges[$0].location }
        guard index > 0 else { return false }
        let range = markdownTOCRanges[index - 1]
        return NSLocationInRange(location, range) && imageIsVisible(range)
    }

    private func visibleTOC(intersecting characters: NSRange) -> Bool {
        guard characters.length > 0 else { return false }
        let index = upperBound(NSMaxRange(characters) - 1, count: markdownTOCRanges.count) { markdownTOCRanges[$0].location }
        guard index > 0 else { return false }
        let range = markdownTOCRanges[index - 1]
        return NSIntersectionRange(characters, range).length > 0 && imageIsVisible(range)
    }

    func setMarkdownImage(_ image: NSImage?, for range: NSRange) {
        markdownImages.removeAll { $0.range == range }
        if let image { markdownImages.append((range, image)) }
        invalidateMarkdownLayout(in: range)
    }

    func clearMarkdownImages() {
        let ranges = markdownImages.map(\.range)
        markdownImages.removeAll()
        for range in ranges { invalidateMarkdownLayout(in: range) }
    }

    func setMarkdownBlockImage(_ image: NSImage?, for range: NSRange) {
        uppercaseHeadingVisuals.removeValue(forKey: range)
        markdownBlockImages.removeAll { $0.range == range }
        markdownMathReferences.removeValue(forKey: range)
        if let image { markdownBlockImages.append((range, image)) }
        invalidateMarkdownLayout(in: range)
        guard image != nil, imageIsVisible(range), let container = textContainers.first,
              range.location < (textStorage?.length ?? 0) else { return }
        let indent = listImageIndent(range)
        guard indent > 0 else { return }
        ensureLayout(forCharacterRange: NSRange(location: range.location, length: 1))
        let glyph = glyphIndexForCharacter(at: range.location)
        let actual = location(forGlyphAt: glyph).x - container.lineFragmentPadding
        if abs(actual - indent) > 0.5 {
            markdownBlockImages.removeAll { $0.range == range }
            invalidateMarkdownLayout(in: range)
        }
    }

    @discardableResult
    func setPlainUppercaseHeading(_ heading: NSRange, source: NSRange, text: String, width: CGFloat, level: Int) -> Bool {
        let run = MarkdownHeading.UppercaseRun(pieces: [.init(sourceRange: source, text: text, matchesSource: true)], styles: [])
        return setUppercaseHeading(heading, runs: [run], width: width, level: level)
    }

    @discardableResult
    func setUppercaseHeading(_ heading: NSRange, runs: [MarkdownHeading.UppercaseRun], width: CGFloat, level: Int,
                             attachmentImages: [NSRange: NSImage] = [:]) -> Bool {
        guard let storage = textStorage, let container = textContainers.first,
              width.isFinite, width > 0,
              heading.location >= 0, heading.length >= 0, heading.location <= storage.length,
              heading.length <= storage.length - heading.location else { return false }
        let pieces = runs.flatMap(\.pieces)
        for piece in pieces {
            guard piece.sourceRange.location >= heading.location,
                  piece.sourceRange.location <= NSMaxRange(heading),
                  piece.sourceRange.length >= 0,
                  piece.sourceRange.length <= NSMaxRange(heading) - piece.sourceRange.location else { return false }
            if piece.matchesSource && !storage.mutableString.substring(with: piece.sourceRange).utf16.elementsEqual(piece.text.utf16) { return false }
        }
        guard let projection = MarkdownHeadingUppercaseProjection(pieces: pieces, sourceRange: heading) else { return false }
        guard !projection.text.isEmpty else { return false }
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = markdownRightToLeft ? .rightToLeft : .natural
        let display = NSTextStorage(string: projection.text, attributes: [.font: markdownHeadingFont(level: level),
            .foregroundColor: markdownColors.text?.nsColor ?? NSColor.textColor, .paragraphStyle: style])
        if container.layoutOrientation == .vertical {
            display.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: display.length))
        }
        var attachments: [(source: NSRange, display: NSRange)] = []
        for run in runs {
            guard let first = run.pieces.first, let last = run.pieces.last,
                  let range = projection.displayRange(for: NSRange(location: first.sourceRange.location - heading.location,
                      length: NSMaxRange(last.sourceRange) - first.sourceRange.location)) else { return false }
            var font = markdownHeadingFont(level: level)
            var inlineStyle = MarkdownInlineStyle()
            let manager = NSFontManager.shared
            for kind in run.styles {
                switch kind {
                case .strong: font = manager.convert(font, toHaveTrait: .boldFontMask)
                case .emphasis: font = manager.convert(font, toHaveTrait: .italicFontMask)
                case .code, .keyboard:
                    font = markdownCodeFont.map { manager.convert($0, toSize: font.pointSize) }
                        ?? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                case .inlineStyle(let style): inlineStyle = style.inheriting(inlineStyle)
                case .link, .underline, .strikethrough, .highlight, .subscriptText, .superscriptText: break
                default: return false
                }
            }
            if run.styles.contains(.keyboard) {
                if run.styles.contains(.strong) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                if run.styles.contains(.emphasis) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            }
            if let size = inlineStyle.fontSize { font = manager.convert(font, toSize: CGFloat(size)) }
            if run.styles.contains(.subscriptText) || run.styles.contains(.superscriptText) {
                let baseSize = font.pointSize
                font = manager.convert(font, toSize: baseSize * 0.75)
                let offset = baseSize * (run.styles.contains(.subscriptText) ? -0.2 : 0.3)
                display.addAttribute(.baselineOffset, value: offset, range: range)
            }
            display.addAttribute(.font, value: font, range: range)
            if run.styles.contains(.link) || run.styles.contains(.underline) {
                display.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if run.styles.contains(.link) {
                display.addAttribute(.foregroundColor, value: markdownColors.link?.nsColor ?? NSColor.linkColor, range: range)
            }
            if let foreground = inlineStyle.foreground { display.addAttribute(.foregroundColor, value: foreground.nsColor, range: range) }
            if run.styles.contains(.strikethrough) {
                display.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if run.styles.contains(.highlight) {
                display.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: range)
            } else if run.styles.contains(.code) || run.styles.contains(.keyboard) {
                display.addAttribute(.backgroundColor, value: markdownColors.codeBackground?.nsColor ?? NSColor.quaternaryLabelColor.withAlphaComponent(0.12), range: range)
            }
            if let background = inlineStyle.background { display.addAttribute(.backgroundColor, value: background.nsColor, range: range) }
            if run.attachment != nil {
                guard run.pieces.count == 1, range.length == 1,
                      let image = attachmentImages[first.sourceRange] else { return false }
                let attachment = NSTextAttachment()
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: tableAttachmentImage(image))
                display.addAttribute(.attachment, value: attachment, range: range)
                attachments.append((first.sourceRange, range))
            }
        }
        let displayLayout = NSLayoutManager()
        display.addLayoutManager(displayLayout)
        let displayContainer = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        displayContainer.lineFragmentPadding = 0
        displayLayout.addTextContainer(displayContainer)
        displayLayout.ensureLayout(for: displayContainer)
        let size = NSSize(width: width, height: max(editorLineHeight, ceil(displayLayout.usedRect(for: displayContainer).height)))
        let image = NSImage(size: size, flipped: true) { _ in
            let glyphs = displayLayout.glyphRange(for: displayContainer)
            displayLayout.drawBackground(forGlyphRange: glyphs, at: .zero)
            displayLayout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            withExtendedLifetime(display) {}
            return true
        }
        setMarkdownBlockImage(image, for: heading)
        guard markdownBlockImages.contains(where: { $0.range == heading }) else { return false }
        uppercaseHeadingVisuals[heading] = UppercaseHeadingVisual(sourceRange: heading, projection: projection,
            storage: display, layout: displayLayout, container: displayContainer, size: size, image: image, attachments: attachments,
            orientation: container.layoutOrientation)
        if container.layoutOrientation == .vertical { invalidateMarkdownLayout(in: heading) }
        return true
    }

    func uppercaseHeadingFont(at position: Int, in heading: NSRange) -> NSFont? {
        guard let storage = uppercaseHeadingVisuals[heading]?.storage, position >= 0, position < storage.length else { return nil }
        return storage.attribute(.font, at: position, effectiveRange: nil) as? NSFont
    }

    func uppercaseHeadingSourcePosition(at point: NSPoint, in container: NSTextContainer) -> Int? {
        for (heading, visual) in uppercaseHeadingVisuals {
            let entry = (range: heading, image: visual.image)
            guard let rect = imageRect(entry, in: container), rect.contains(point), rect.width > 0, rect.height > 0 else { continue }
            let displayPoint = NSPoint(x: (point.x - rect.minX) * visual.size.width / rect.width,
                                       y: (point.y - rect.minY) * visual.size.height / rect.height)
            var fraction: CGFloat = 0
            let position = visual.layout.characterIndex(for: displayPoint, in: visual.container, fractionOfDistanceBetweenInsertionPoints: &fraction)
            guard let source = visual.projection.sourcePosition(for: position, fraction: fraction) else { return nil }
            return visual.sourceRange.location + source
        }
        return nil
    }

    private func uppercaseAttachmentRects(in container: NSTextContainer) -> [(NSRange, NSRect)] {
        var result: [(NSRange, NSRect)] = []
        for (heading, visual) in uppercaseHeadingVisuals {
            guard let bounds = imageRect((range: heading, image: visual.image), in: container),
                  visual.size.width > 0, visual.size.height > 0 else { continue }
            for attachment in visual.attachments {
                let glyph = visual.layout.glyphRange(forCharacterRange: attachment.display, actualCharacterRange: nil)
                guard glyph.length > 0 else { continue }
                let rect = visual.layout.boundingRect(forGlyphRange: glyph, in: visual.container)
                result.append((attachment.source, NSRect(x: bounds.minX + rect.minX * bounds.width / visual.size.width,
                    y: bounds.minY + rect.minY * bounds.height / visual.size.height,
                    width: rect.width * bounds.width / visual.size.width, height: rect.height * bounds.height / visual.size.height)))
            }
        }
        return result
    }

    private func isCoveredByUppercaseHeading(_ range: NSRange) -> Bool {
        uppercaseHeadingVisuals.keys.contains { heading in
            range.location >= heading.location && NSMaxRange(range) <= NSMaxRange(heading) && imageIsVisible(heading)
        }
    }

    func removePlainUppercaseHeading(for range: NSRange) {
        uppercaseHeadingVisuals.removeValue(forKey: range)
        setMarkdownBlockImage(nil, for: range)
    }

    func clearUppercaseHeadings() {
        for range in Array(uppercaseHeadingVisuals.keys) { removePlainUppercaseHeading(for: range) }
    }

    func uppercaseHeadingsNeedLayout(in container: NSTextContainer) -> Bool {
        guard let view = container.textView else { return false }
        for (range, visual) in uppercaseHeadingVisuals {
            let width = min(container.containerSize.width, view.visibleRect.width)
                - 2 * container.lineFragmentPadding - listImageIndent(range)
            if visual.orientation != container.layoutOrientation || abs(visual.size.width - width) > 0.5 { return true }
        }
        return false
    }

    func clearMarkdownBlockImages() {
        let ranges = markdownBlockImages.map(\.range)
        uppercaseHeadingVisuals.removeAll()
        markdownBlockImages.removeAll()
        for range in ranges { markdownMathReferences.removeValue(forKey: range) }
        for range in ranges { invalidateMarkdownLayout(in: range) }
    }

    func isMarkdownTablePosition(_ location: Int) -> Bool { tableLine(at: location) != nil }

    @discardableResult
    func setMarkdownInlineImage(_ image: NSImage, for range: NSRange, rubyBaseline: NSPoint? = nil) -> Bool {
        guard image.size.width >= 0, image.size.height >= 0,
              let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return false }
        markdownMathReferences.removeValue(forKey: range)
        if isMarkdownTablePosition(range.location) {
            guard !isCharacterFolded(range.location) else { return false }
            markdownTableMathImages[range] = image
            invalidateMarkdownLayout(in: range)
            return true
        }
        guard imageIsVisible(range) else { return false }
        if let rubyBaseline { markdownRubyBaselines[range] = rubyBaseline }
        else { markdownRubyBaselines.removeValue(forKey: range) }
        markdownInlineImages.removeAll { $0.range == range }
        markdownInlineImages.append((range, image))
        markdownInlineImages.sort { $0.range.location < $1.range.location }
        invalidateMarkdownLayout(in: range)
        ensureLayout(forCharacterRange: NSRange(location: range.location, length: 1))
        let glyph = glyphIndexForCharacter(at: range.location)
        guard let container = textContainers.first else { removeMarkdownInlineImage(for: range); return false }
        let bounds = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let width = container.layoutOrientation == .vertical ? image.size.height : image.size.width
        guard bounds.width >= width - 0.5 else { removeMarkdownInlineImage(for: range); return false }
        return true
    }

    func removeMarkdownInlineImage(for range: NSRange) {
        markdownInlineImages.removeAll { $0.range == range }
        markdownTableMathImages.removeValue(forKey: range)
        markdownEmojiAccessibility.removeValue(forKey: range)
        markdownRubyBaselines.removeValue(forKey: range)
        markdownMathReferences.removeValue(forKey: range)
        invalidateMarkdownLayout(in: range)
    }

    func clearMarkdownInlineImages() {
        let ranges = markdownInlineImages.map(\.range) + Array(markdownTableMathImages.keys)
        markdownInlineImages.removeAll()
        markdownTableMathImages.removeAll()
        markdownEmojiAccessibility.removeAll()
        markdownRubyBaselines.removeAll()
        for range in ranges { markdownMathReferences.removeValue(forKey: range) }
        for range in ranges { invalidateMarkdownLayout(in: range) }
    }

    func setMarkdownMediaSize(_ size: NSSize?, for range: NSRange) {
        if markdownMedia.first(where: { $0.range == range })?.size == size { return }
        markdownMedia.removeAll { $0.range == range }
        if let size { markdownMedia.append((range, size)) }
        invalidateMarkdownLayout(in: range)
    }

    func clearMarkdownMedia() {
        let ranges = markdownMedia.map(\.range)
        markdownMedia.removeAll()
        for range in ranges { invalidateMarkdownLayout(in: range) }
    }

    func canDisplayMarkdownMedia(_ range: NSRange) -> Bool { imageIsVisible(range) }
    func markdownMediaIndent(for range: NSRange) -> CGFloat { listImageIndent(range) }

    func markdownMediaRect(for range: NSRange, in container: NSTextContainer) -> NSRect? {
        guard imageIsVisible(range), let entry = markdownMedia.first(where: { $0.range == range }),
              range.location < (textStorage?.length ?? 0) else { return nil }
        let glyph = glyphIndexForCharacter(at: range.location)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let size = container.layoutOrientation == .vertical
            ? NSSize(width: entry.size.height, height: entry.size.width) : entry.size
        return NSRect(x: line.minX + container.lineFragmentPadding + markdownMediaIndent(for: range), y: line.minY,
                      width: size.width, height: size.height)
    }

    private func imageIsVisible(_ range: NSRange) -> Bool {
        guard textContainers.first?.textView?.hasMarkedText() != true else { return false }
        if intersectsFoldedRange(range) { return false }
        return !(markdownRevealedRange.map { touches(range, $0) } ?? false)
    }

    private func listImageIndent(_ range: NSRange) -> CGFloat {
        guard let storage = textStorage, range.location < storage.length else { return 0 }
        let text = storage.mutableString
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        guard line.location <= range.location else { return 0 }
        let prefix = text.substring(with: NSRange(location: line.location, length: range.location - line.location))
        let units = Array(prefix.utf16)
        guard units.count >= 2, units.last == 32 || units.last == 9 else { return 0 }
        var quoteEnd = 0
        while quoteEnd < units.count && units[quoteEnd] == 62 {
            quoteEnd += 1
            if quoteEnd < units.count && units[quoteEnd] == 32 { quoteEnd += 1 }
        }
        let visibleUnits = units.enumerated().compactMap { offset, unit in
            isMarkdownMarkerHidden(at: line.location + offset) ? nil : unit
        }
        let visiblePrefix = String(decoding: visibleUnits, as: UTF16.self)
        let marker = Array(units[quoteEnd...].drop(while: { $0 == 32 }).reversed().drop(while: { $0 == 32 || $0 == 9 }).reversed())
        let bullet = marker.count == 1 && [UInt16(45), 43, 42].contains(marker[0])
        let ordered = marker.count >= 2 && marker.count <= 10 && (marker.last == 46 || marker.last == 41)
            && marker.dropLast().allSatisfy { (48...57).contains($0) }
        guard bullet || ordered else { return 0 }
        let font = storage.attribute(.font, at: line.location, effectiveRange: nil) as? NSFont ?? textFont
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let paragraph = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) {
            attributes[.paragraphStyle] = paragraph
        }
        return (visiblePrefix as NSString).size(withAttributes: attributes).width
    }

    private func imageLogicalSize(_ image: NSImage, in container: NSTextContainer, indent: CGFloat = 0, centered: Bool = false) -> NSSize {
        let vertical = container.layoutOrientation == .vertical
        let visibleWidth = container.textView?.visibleRect.width ?? 0
        let inlineWidth = centered && visibleWidth > 0 ? min(container.size.width, visibleWidth) : container.size.width
        let available = vertical
            ? (container.textView?.enclosingScrollView?.contentView.bounds.width ?? container.size.width)
            : inlineWidth - 2 * container.lineFragmentPadding
        let width = max(0, available - indent)
        let scale = image.size.width > 0 ? min(1, width / image.size.width) : 1
        let physical = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return vertical ? NSSize(width: physical.height, height: physical.width) : physical
    }

    private func imageRect(_ entry: (range: NSRange, image: NSImage), in container: NSTextContainer, centered: Bool = false) -> NSRect? {
        guard imageIsVisible(entry.range), entry.range.length > 0,
              entry.range.location < (textStorage?.length ?? 0), entry.image.size.width > 0, entry.image.size.height > 0 else { return nil }
        let glyph = glyphIndexForCharacter(at: entry.range.location)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let indent = listImageIndent(entry.range)
        let visibleWidth = container.textView?.visibleRect.width ?? 0
        let inlineWidth = visibleWidth > 0 ? min(container.size.width, visibleWidth) : container.size.width
        let width = max(0, inlineWidth - 2 * container.lineFragmentPadding - indent)
        let size: NSSize
        if let visual = uppercaseHeadingVisuals[entry.range] {
            let scale = visual.size.width > 0 ? min(1, width / visual.size.width) : 1
            size = NSSize(width: visual.size.width * scale, height: visual.size.height * scale)
        } else { size = imageLogicalSize(entry.image, in: container, indent: indent, centered: centered) }
        return NSRect(x: line.minX + container.lineFragmentPadding + indent + (centered ? (width - size.width) / 2 : 0), y: line.minY,
                      width: size.width, height: size.height)
    }

    func setMarkdownMathReferences(_ references: [(rect: CGRect, target: NSRange)], for range: NSRange) {
        if references.isEmpty { markdownMathReferences.removeValue(forKey: range) }
        else { markdownMathReferences[range] = references }
    }

    func markdownMathReference(at point: NSPoint, in container: NSTextContainer) -> (source: NSRange, target: NSRange)? {
        guard let view = container.textView else { return nil }
        let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        guard visible.contains(point) else { return nil }
        for (source, rect) in uppercaseAttachmentRects(in: container) where rect.contains(point) {
            guard rect.width > 0, rect.height > 0, let references = markdownMathReferences[source] else { continue }
            let normalized: CGPoint
            if container.layoutOrientation == .vertical, let clip = view.enclosingScrollView?.contentView {
                let origin = view.textContainerOrigin
                let physical = clip.convert(rect.offsetBy(dx: origin.x, dy: origin.y), from: view)
                let physicalPoint = clip.convert(NSPoint(x: point.x + origin.x, y: point.y + origin.y), from: view)
                guard physical.width > 0, physical.height > 0 else { continue }
                normalized = CGPoint(x: (physicalPoint.x - physical.minX) / physical.width, y: (physicalPoint.y - physical.minY) / physical.height)
            } else {
                normalized = CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
            }
            let matches = references.filter { $0.rect.contains(normalized) }
            if matches.count == 1 { return (source, matches[0].target) }
        }
        for (entry, isInline) in markdownBlockImages.map({ ($0, false) }) + markdownInlineImages.map({ ($0, true) }) {
            if isInline && isCoveredByUppercaseHeading(entry.range) { continue }
            guard let references = markdownMathReferences[entry.range], !references.isEmpty else { continue }
            let image = isInline ? inlineImageRect(entry, in: container) : imageRect(entry, in: container)
            guard let image, image.contains(point) else { continue }
            let local: CGPoint
            if container.layoutOrientation == .vertical, let clip = view.enclosingScrollView?.contentView {
                let origin = view.textContainerOrigin
                let physical = clip.convert(image.offsetBy(dx: origin.x, dy: origin.y), from: view)
                let physicalPoint = clip.convert(NSPoint(x: point.x + origin.x, y: point.y + origin.y), from: view)
                guard physical.width > 0, physical.height > 0 else { continue }
                local = CGPoint(x: (physicalPoint.x - physical.minX) / physical.width, y: (physicalPoint.y - physical.minY) / physical.height)
            } else {
                local = CGPoint(x: (point.x - image.minX) / image.width, y: (point.y - image.minY) / image.height)
            }
            let matches = references.filter { $0.rect.contains(local) }
            if matches.count == 1 { return (entry.range, matches[0].target) }
        }
        guard !markdownMathReferences.isEmpty,
              let (cell, frame) = markdownTableCellInfo(at: point, in: container),
              let text = textStorage?.mutableString else { return nil }
        let inset = frame.insetBy(dx: 4, dy: 4)
        guard inset.contains(point) else { return nil }
        let textLayout = tableTextLayout(tableCellAttributedText(cell, text: text), width: inset.width)
        defer { withExtendedLifetime(textLayout.0) {} }
        let local = NSPoint(x: point.x - inset.minX, y: point.y - inset.minY)
        let runs = cell.displayRuns.compactMap { run -> (NSRange, NSRange, NSImage)? in
            guard let relative = tableImageSource(run.kind) else { return nil }
            let range = NSRange(location: cell.range.location + relative.location, length: relative.length)
            guard let image = markdownTableMathImages[range] else { return nil }
            return (run.range, range, image)
        }.sorted { $0.0.location < $1.0.location }
        var delta = 0
        for (display, source, image) in runs {
            defer { delta += display.length - 1 }
            guard let references = markdownMathReferences[source], !references.isEmpty else { continue }
            let location = display.location - delta
            guard location >= 0, location < textLayout.0.length else { continue }
            let glyphs = textLayout.1.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            guard glyphs.length == 1 else { continue }
            let rect = textLayout.1.boundingRect(forGlyphRange: glyphs, in: textLayout.2)
            let size = container.layoutOrientation == .vertical
                ? NSSize(width: image.size.height, height: image.size.width) : image.size
            guard abs(rect.width - size.width) < 0.5, abs(rect.height - size.height) < 0.5,
                  rect.contains(local), rect.width > 0, rect.height > 0 else { continue }
            let normalized: CGPoint
            if container.layoutOrientation == .vertical, let clip = view.enclosingScrollView?.contentView {
                let origin = view.textContainerOrigin
                let positioned = rect.offsetBy(dx: inset.minX + origin.x, dy: inset.minY + origin.y)
                let physical = clip.convert(positioned, from: view)
                let physicalPoint = clip.convert(NSPoint(x: point.x + origin.x, y: point.y + origin.y), from: view)
                guard physical.width > 0, physical.height > 0 else { continue }
                normalized = CGPoint(x: (physicalPoint.x - physical.minX) / physical.width,
                                     y: (physicalPoint.y - physical.minY) / physical.height)
            } else {
                normalized = CGPoint(x: (local.x - rect.minX) / rect.width, y: (local.y - rect.minY) / rect.height)
            }
            let matches = references.filter { $0.rect.contains(normalized) }
            if matches.count == 1 { return (source, matches[0].target) }
        }
        return nil
    }

    private func inlineImage(at location: Int) -> (range: NSRange, image: NSImage)? {
        let index = upperBound(location, count: markdownInlineImages.count) { markdownInlineImages[$0].range.location }
        guard index > 0 else { return nil }
        let entry = markdownInlineImages[index - 1]
        return NSLocationInRange(location, entry.range) && imageIsVisible(entry.range) ? entry : nil
    }

    func markdownInlineImage(for range: NSRange) -> NSImage? {
        guard let entry = inlineImage(at: range.location), entry.range == range else { return nil }
        return entry.image
    }

    private func inlineImageRect(_ entry: (range: NSRange, image: NSImage), in container: NSTextContainer) -> NSRect? {
        guard imageIsVisible(entry.range), entry.range.location < (textStorage?.length ?? 0) else { return nil }
        let glyph = glyphIndexForCharacter(at: entry.range.location)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = location(forGlyphAt: glyph)
        let size = container.layoutOrientation == .vertical
            ? NSSize(width: entry.image.size.height, height: entry.image.size.width) : entry.image.size
        let anchor = NSPoint(x: line.minX + location.x, y: line.minY + location.y)
        let rect = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        guard let baseline = markdownRubyBaselines[entry.range] else { return rect }
        if container.layoutOrientation != .vertical {
            return NSRect(x: anchor.x, y: anchor.y - baseline.y, width: size.width, height: size.height)
        }
        guard let view = container.textView, let clip = view.enclosingScrollView?.contentView,
              entry.image.size.width > 0, entry.image.size.height > 0 else { return nil }
        let physical = clip.convert(rect, from: view)
        let point = clip.convert(anchor, from: view)
        let x = point.x - baseline.x * physical.width / entry.image.size.width
        let yOffset = (clip.isFlipped ? baseline.y : entry.image.size.height - baseline.y) * physical.height / entry.image.size.height
        return view.convert(NSRect(x: x, y: point.y - yOffset, width: physical.width, height: physical.height), from: clip)
    }

    func markdownImageLocation(at point: NSPoint, in container: NSTextContainer) -> Int? {
        for entry in markdownInlineImages {
            if isCoveredByUppercaseHeading(entry.range) { continue }
            if let rect = inlineImageRect(entry, in: container), rect.contains(point) { return entry.range.location }
        }
        for entry in markdownImages {
            if let rect = imageRect(entry, in: container, centered: true), rect.contains(point) { return entry.range.location }
        }
        for entry in markdownBlockImages {
            if let rect = imageRect(entry, in: container), rect.contains(point) { return entry.range.location }
        }
        return nil
    }

    func markdownRenderedImageRects(for ranges: Set<NSRange>, in container: NSTextContainer, editingCell: NSRange? = nil) -> [NSRange: NSRect] {
        var result: [NSRange: NSRect] = [:]
        for entry in markdownInlineImages where ranges.contains(entry.range) { result[entry.range] = inlineImageRect(entry, in: container) }
        for entry in markdownImages where ranges.contains(entry.range) { result[entry.range] = imageRect(entry, in: container, centered: true) }
        for (range, rect) in uppercaseAttachmentRects(in: container) where ranges.contains(range) { result[range] = rect }
        guard let text = textStorage?.mutableString else { return result }
        var cells: [NSRange: (MarkdownTableCell, NSRect, Set<NSRange>)] = [:]
        var rowGeometry: [Int: [NSRange: TableCellGeometry]] = [:]
        for range in ranges where markdownTableMathImages[range] != nil && !isCharacterFolded(range.location) {
            guard let line = tableLine(at: range.location), let row = line.row else { continue }
            var low = 0, high = row.cells.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(row.cells[middle].range) <= range.location { low = middle + 1 } else { high = middle }
            }
            guard low < row.cells.count, range.location >= row.cells[low].range.location,
                  NSMaxRange(range) <= NSMaxRange(row.cells[low].range) else { continue }
            let cell = row.cells[low]
            if let editingCell, NSIntersectionRange(cell.range, editingCell).length > 0 { continue }
            if cells[cell.range] == nil {
                let (indent, width) = tableHorizontalGeometry(line, container: container)
                if rowGeometry[line.range.location] == nil {
                    var byRange: [NSRange: TableCellGeometry] = [:]
                    for item in tableLineGeometry(line, width: width) { byRange[item.cell.range] = item }
                    rowGeometry[line.range.location] = byRange
                }
                guard let geometry = rowGeometry[line.range.location]?[cell.range], geometry.cell.column == cell.column else { continue }
                let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
                let frame = geometry.rect.offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent, dy: fragment.minY)
                cells[cell.range] = (cell, frame, [])
            }
            cells[cell.range]?.2.insert(range)
        }
        for (cell, frame, requested) in cells.values {
            let inset = frame.insetBy(dx: 4, dy: 4)
            let textLayout = tableTextLayout(tableCellAttributedText(cell, text: text), width: inset.width)
            defer { withExtendedLifetime(textLayout.0) {} }
            let runs = cell.displayRuns.compactMap { run -> (NSRange, NSRange)? in
                guard let relative = tableImageSource(run.kind) else { return nil }
                let source = NSRange(location: cell.range.location + relative.location, length: relative.length)
                return markdownTableMathImages[source] == nil ? nil : (run.range, source)
            }.sorted { $0.0.location < $1.0.location }
            var delta = 0
            for (display, source) in runs {
                defer { delta += display.length - 1 }
                guard requested.contains(source), let image = markdownTableMathImages[source] else { continue }
                let position = display.location - delta
                guard position >= 0, position < textLayout.0.length else { continue }
                let glyphs = textLayout.1.glyphRange(forCharacterRange: NSRange(location: position, length: 1), actualCharacterRange: nil)
                guard glyphs.length == 1 else { continue }
                let rect = textLayout.1.boundingRect(forGlyphRange: glyphs, in: textLayout.2)
                let size = container.layoutOrientation == .vertical
                    ? NSSize(width: image.size.height, height: image.size.width) : image.size
                guard abs(rect.width - size.width) < 0.5, abs(rect.height - size.height) < 0.5 else { continue }
                result[source] = rect.offsetBy(dx: inset.minX, dy: inset.minY)
            }
        }
        return result
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for entry in markdownInlineImages where NSIntersectionRange(entry.range, visible).length > 0 {
            guard let rect = inlineImageRect(entry, in: container) else { continue }
            drawMarkdownImage(entry.image, in: rect.offsetBy(dx: origin.x, dy: origin.y), container: container)
        }
        for entry in markdownImages where NSIntersectionRange(entry.range, visible).length > 0 {
            guard let rect = imageRect(entry, in: container, centered: true) else { continue }
            drawMarkdownImage(entry.image, in: rect.offsetBy(dx: origin.x, dy: origin.y), container: container)
        }
        for entry in markdownBlockImages where NSIntersectionRange(entry.range, visible).length > 0 {
            guard let rect = imageRect(entry, in: container) else { continue }
            let target = rect.offsetBy(dx: origin.x, dy: origin.y)
            if uppercaseHeadingVisuals[entry.range] != nil {
                entry.image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else { drawMarkdownImage(entry.image, in: target, container: container) }
        }
    }

    private func drawMarkdownImage(_ image: NSImage, in rect: NSRect, container: NSTextContainer) {
        guard container.layoutOrientation == .vertical, let view = container.textView,
              let clip = view.enclosingScrollView?.contentView else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let physical = clip.convert(rect, from: view)
        let start = view.convert(physical.origin, from: clip)
        let x = view.convert(NSPoint(x: physical.minX + 1, y: physical.minY), from: clip)
        let y = view.convert(NSPoint(x: physical.minX, y: physical.minY + 1), from: clip)
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(m11: x.x - start.x, m12: x.y - start.y,
            m21: y.x - start.x, m22: y.y - start.y, tX: start.x, tY: start.y)
        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        image.draw(in: NSRect(origin: .zero, size: physical.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func checkboxRect(_ checkbox: MarkdownTaskCheckbox, in container: NSTextContainer) -> NSRect? {
        guard let view = container.textView, !view.hasMarkedText(),
              checkbox.markerRange.length == 3, NSMaxRange(checkbox.markerRange) <= (textStorage?.length ?? 0),
              !intersectsFoldedRange(checkbox.markerRange),
              view.selectedRange().length == 0 || NSIntersectionRange(view.selectedRange(), checkbox.markerRange).length == 0 else { return nil }
        let glyphs = glyphRange(forCharacterRange: checkbox.markerRange, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = boundingRect(forGlyphRange: glyphs, in: container)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    func markdownTaskCheckbox(at point: NSPoint, in container: NSTextContainer) -> MarkdownTaskCheckbox? {
        markdownTaskCheckboxes.first { checkboxRect($0, in: container)?.contains(point) == true }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var drawableRanges = [glyphsToShow]
        for entry in markdownImages where imageIsVisible(entry.range)
            && NSIntersectionRange(entry.range, visible).length > 0 {
            let hidden = NSIntersectionRange(
                glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil),
                glyphsToShow
            )
            guard hidden.length > 0 else { continue }
            drawableRanges = drawableRanges.flatMap { candidate in
                let intersection = NSIntersectionRange(candidate, hidden)
                guard intersection.length > 0 else { return [candidate] }
                var result: [NSRange] = []
                if candidate.location < intersection.location {
                    result.append(NSRange(location: candidate.location, length: intersection.location - candidate.location))
                }
                if NSMaxRange(intersection) < NSMaxRange(candidate) {
                    result.append(NSRange(location: NSMaxRange(intersection), length: NSMaxRange(candidate) - NSMaxRange(intersection)))
                }
                return result
            }
        }
        for range in drawableRanges where range.length > 0 {
            super.drawGlyphs(forGlyphRange: range, at: origin)
        }
        guard let container = textContainers.first else { return }
        var replacementIndex = upperBound(visible.location, count: markdownTextReplacements.count) { markdownTextReplacements[$0].range.location }
        if replacementIndex > 0 { replacementIndex -= 1 }
        while replacementIndex < markdownTextReplacements.count {
            let replacement = markdownTextReplacements[replacementIndex]
            replacementIndex += 1
            if replacement.range.location >= NSMaxRange(visible) { break }
            guard (replacement.kind == .smart || (replacement.kind == .spaces && replacement.text != " ")),
                  NSIntersectionRange(replacement.range, visible).length > 0,
                  textReplacement(at: replacement.range.location) != nil else { continue }
            let glyphs = glyphRange(forCharacterRange: replacement.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let rect = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            (replacement.text as NSString).draw(in: rect, withAttributes: textReplacementAttributes(at: replacement.range.location, in: container))
        }
        var headingIndex = upperBound(visible.location, count: markdownNumberedHeadingsBySource.count) { markdownNumberedHeadingsBySource[$0].range.location }
        if headingIndex > 0 { headingIndex -= 1 }
        while headingIndex < markdownNumberedHeadingsBySource.count {
            let heading = markdownNumberedHeadingsBySource[headingIndex]
            headingIndex += 1
            if heading.range.location >= NSMaxRange(visible) { break }
            guard let number = heading.number, NSLocationInRange(heading.range.location, visible),
                  !(markdownRevealedRange.map { touches(heading.range, $0) } ?? false),
                  heading.range.location < (textStorage?.length ?? 0) else { continue }
            let glyph = glyphIndexForCharacter(at: heading.range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = location(forGlyphAt: glyph)
            let font = markdownHeadingFont(level: heading.level)
            let width = markdownHeadingNumberWidths[heading.range.location] ?? 0
            guard width > 0 else { continue }
            let x = markdownRightToLeft ? line.minX + position.x : line.minX + position.x - width
            let rect = NSRect(x: x + origin.x, y: line.minY + origin.y, width: width, height: line.height)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: markdownColors.text?.nsColor ?? NSColor.textColor]
            if container.layoutOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
            (number as NSString).draw(in: rect, withAttributes: attributes)
        }
        var markerIndex = upperBound(visible.location, count: markdownListMarkers.count) { markdownListMarkers[$0].range.location }
        if markerIndex > 0 { markerIndex -= 1 }
        while markerIndex < markdownListMarkers.count {
            let marker = markdownListMarkers[markerIndex]
            markerIndex += 1
            if marker.range.location >= NSMaxRange(visible) { break }
            guard NSIntersectionRange(marker.range, visible).length > 0,
                  listMarker(at: marker.range.location) != nil,
                  let storage = textStorage, marker.range.location < storage.length else { continue }
            let glyph = glyphRange(forCharacterRange: marker.range, actualCharacterRange: nil)
            guard glyph.length > 0 else { continue }
            let rect = boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let font = (storage.attribute(.font, at: marker.range.location, effectiveRange: nil) as? NSFont) ?? textFont
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: markdownColors.text?.nsColor ?? NSColor.textColor]
            if container.layoutOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
            (listMarkerText(marker) as NSString).draw(in: rect, withAttributes: attributes)
        }
        for checkbox in markdownTaskCheckboxes where NSIntersectionRange(checkbox.markerRange, visible).length > 0 {
            guard let bounds = checkboxRect(checkbox, in: container)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            if let view = container.textView as? LacTextView, let text = textStorage?.string as NSString? {
                let location = min(view.selectedRange().location, text.length)
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                (NSLocationInRange(checkbox.markerRange.location, line) ? view.currentLineColor : view.backgroundColor).setFill()
            } else {
                NSColor.lacEditorBackground.setFill()
            }
            bounds.fill()
            let side = min(bounds.width, bounds.height) * 0.72
            let box = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            NSColor.secondaryLabelColor.setStroke()
            let border = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            border.lineWidth = 1
            border.stroke()
            if checkbox.state != 32 {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + side * 0.2, y: box.midY))
                check.line(to: NSPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.75))
                check.line(to: NSPoint(x: box.minX + side * 0.82, y: box.minY + side * 0.25))
                check.lineWidth = 1.5
                check.stroke()
            }
        }
        var alertIndex = upperBound(visible.location, count: markdownAlerts.count) { markdownAlerts[$0].range.location }
        if alertIndex > 0 { alertIndex -= 1 }
        while alertIndex < markdownAlerts.count {
            let alert = markdownAlerts[alertIndex]
            alertIndex += 1
            if alert.range.location >= NSMaxRange(visible) { break }
            guard NSIntersectionRange(alert.range, visible).length > 0 else { continue }
            guard case let .alert(label) = alert.kind, let marker = alert.markerRanges.first,
                  isMarkdownMarkerHidden(at: marker.location),
                  !intersectsFoldedRange(marker),
                  marker.location < (textStorage?.length ?? 0) else { continue }
            let glyph = glyphIndexForCharacter(at: marker.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let rect = NSRect(x: line.minX + container.lineFragmentPadding + origin.x, y: line.minY + origin.y,
                              width: max(1, container.size.width - 2 * container.lineFragmentPadding), height: line.height)
            let font = NSFontManager.shared.convert(textFont, toHaveTrait: .boldFontMask)
            (label as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: NSColor.controlAccentColor])
        }
        var tableIndex = upperBound(visible.location, count: tableLines.count) { tableLines.location(at: $0) }
        if tableIndex > 0 { tableIndex -= 1 }
        while tableIndex < tableLines.count {
            let line = tableLines[tableIndex]
            tableIndex += 1
            if line.range.location >= NSMaxRange(visible) { break }
            guard NSIntersectionRange(line.range, visible).length > 0, tableLine(at: line.range.location) != nil,
                  line.row != nil, let text = textStorage?.mutableString,
                  line.range.location < text.length else { continue }
            let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: line.range.location), effectiveRange: nil)
            let (indent, width) = tableHorizontalGeometry(line, container: container)
            for cell in tableLineGeometry(line, width: width) {
                let rect = cell.rect.offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent + origin.x, dy: fragment.minY + origin.y)
                NSColor.separatorColor.setStroke()
                NSBezierPath(rect: rect).stroke()
                let content = tableCellAttributedText(cell.cell, text: text)
                let inset = rect.insetBy(dx: 4, dy: 4)
                let textLayout = tableTextLayout(content, width: inset.width)
                defer { withExtendedLifetime(textLayout.0) {} }
                let glyphs = textLayout.1.glyphRange(for: textLayout.2)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: inset).addClip()
                textLayout.1.drawBackground(forGlyphRange: glyphs, at: inset.origin)
                textLayout.1.drawGlyphs(forGlyphRange: glyphs, at: inset.origin)
                NSGraphicsContext.restoreGraphicsState()
                if line.tableRange == activeTableRange {
                    let handle: NSRect?
                    if line.rowIndex == 0 {
                        handle = NSRect(x: rect.midX - 6, y: rect.minY - 12, width: 12, height: 12)
                    } else if cell.cell.column == 0 {
                        handle = NSRect(x: markdownRightToLeft ? rect.maxX : rect.minX - 12, y: rect.midY - 6, width: 12, height: 12)
                    } else { handle = nil }
                    if let handle {
                        ("⋮" as NSString).draw(in: handle, withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                    }
                }
            }
        }
        var breakIndex = upperBound(visible.location, count: markdownPageBreaks.count) { markdownPageBreaks[$0].location }
        if breakIndex > 0 { breakIndex -= 1 }
        while breakIndex < markdownPageBreaks.count {
            let range = markdownPageBreaks[breakIndex]
            if range.location >= NSMaxRange(visible) { break }
            breakIndex += 1
            guard let rect = markdownPageBreakRect(for: range, in: container) else { continue }
            let target = rect.offsetBy(dx: origin.x, dy: origin.y)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(10, textFont.pointSize - 2)), .foregroundColor: NSColor.secondaryLabelColor]
            let label = L10n.tr("markdown.pageBreak") as NSString
            label.draw(in: target, withAttributes: attributes)
            let start = target.minX + label.size(withAttributes: attributes).width + 8
            if start < target.maxX {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: start, y: target.midY))
                path.line(to: NSPoint(x: target.maxX, y: target.midY))
                path.setLineDash([3, 3], count: 2, phase: 0)
                NSColor.separatorColor.setStroke()
                path.stroke()
            }
        }
        var tocIndex = upperBound(visible.location, count: markdownTOCRanges.count) { markdownTOCRanges[$0].location }
        if tocIndex > 0 { tocIndex -= 1 }
        while tocIndex < markdownTOCRanges.count {
            let range = markdownTOCRanges[tocIndex]
            if range.location >= NSMaxRange(visible) { break }
            tocIndex += 1
            guard NSIntersectionRange(range, visible).length > 0, imageIsVisible(range) else { continue }
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let width = max(1, container.size.width - 2 * container.lineFragmentPadding)
            for (heading, rect) in tocRows(width: width) {
                let target = rect.offsetBy(dx: line.minX + container.lineFragmentPadding + origin.x, dy: line.minY + origin.y)
                var attributes: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: NSColor.linkColor]
                if container.layoutOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
                (heading.numberedTitle as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes)
            }
        }
    }

    func updateMarkdownTOCHeadings(_ headings: [MarkdownHeading]) {
        markdownTOCHeadings = headings
        markdownNumberedHeadingsBySource = headings.filter { $0.number != nil }.sorted { $0.range.location < $1.range.location }
        visibleTOCHeadings = headings.filter { $0.level <= markdownTOCMaxLevel }
        for range in markdownTOCRanges { invalidateMarkdownLayout(in: range) }
    }

    func markdownNumberedHeading(at location: Int) -> MarkdownHeading? {
        let index = upperBound(location, count: markdownNumberedHeadingsBySource.count) { markdownNumberedHeadingsBySource[$0].range.location }
        guard index > 0 else { return nil }
        let heading = markdownNumberedHeadingsBySource[index - 1]
        return heading.number != nil && NSLocationInRange(location, heading.range) ? heading : nil
    }

    func setMarkdownHeadingNumberWidth(_ width: CGFloat?, at location: Int) {
        markdownHeadingNumberWidths[location] = width
    }

    func setMarkdownPresentation(_ presentation: MarkdownPresentation?, revealedRange: NSRange?, inlineSelection: NSRange? = nil, invalidating range: NSRange? = nil) {
        if presentation == nil && markdownMarkers.isEmpty && markdownTextReplacements.isEmpty && markdownListMarkers.isEmpty && markdownParagraphs.isEmpty && markdownHeadings.isEmpty && markdownTaskCheckboxes.isEmpty && markdownTOCRanges.isEmpty && markdownPageBreaks.isEmpty && tableLines.isEmpty && range != nil {
            markdownRevealedRange = nil
            markdownInlineSelection = nil
            return
        }
        tableLines = TableLines(presentation?.tables ?? [])
        if let activeTableRange, !tableLines.tables.contains(where: { $0.range == activeTableRange }) { self.activeTableRange = nil }
        markdownTaskCheckboxes = presentation?.taskCheckboxes ?? []
        markdownListMarkers = presentation?.listMarkers ?? []
        markdownParagraphs = presentation?.paragraphs ?? []
        markdownCompletedTasks = presentation?.completedTaskRanges ?? []
        var taskEnd = 0
        markdownCompletedTaskEnds = markdownCompletedTasks.map { taskEnd = max(taskEnd, NSMaxRange($0)); return taskEnd }
        markdownParagraphSeparators = markdownParagraphs.compactMap { paragraph in
            paragraph.separatorAfter.map { ($0, NSUnionRange(paragraph.range, $0)) }
        }.sorted { $0.range.location < $1.range.location }
        markdownTOCHeadings = presentation?.headings ?? []
        markdownNumberedHeadingsBySource = markdownTOCHeadings.filter { $0.number != nil }.sorted { $0.range.location < $1.range.location }
        markdownHeadingNumberWidths.removeAll()
        visibleTOCHeadings = markdownTOCHeadings.filter { $0.level <= markdownTOCMaxLevel }
        markdownTOCRanges = markdownTOCHeadings.isEmpty ? [] : (presentation?.tableOfContents ?? []).sorted { $0.location < $1.location }
        markdownPageBreaks = (presentation?.pageBreaks ?? []).sorted { $0.location < $1.location }
        let spans = presentation?.spans ?? []
        markdownTextReplacements = presentation?.textReplacements ?? []
        markdownAlerts = spans.filter { if case .alert = $0.kind { return true }; return false }.sorted { $0.range.location < $1.range.location }
        markdownMarkers = spans.flatMap { span in
            let inline: Bool
            switch span.kind {
            case .strong, .emphasis, .strikethrough, .code, .keyboard, .link, .highlight, .subscriptText, .superscriptText, .underline, .inlineStyle: inline = true
            default: inline = false
            }
            return span.markerRanges.map { MarkdownMarker(range: $0, owner: span.range, inline: inline) }
        }.sorted { $0.range.location < $1.range.location }
        var end = 0
        markdownMarkerEnds = markdownMarkers.map { marker in
            end = max(end, NSMaxRange(marker.range))
            return end
        }
        markdownContainers = (spans.filter { !$0.markerRanges.isEmpty }.map(\.range) + markdownTextReplacements.map(\.range) + markdownListMarkers.map(\.line) + markdownParagraphSeparators.map(\.owner) + markdownImages.map(\.range) + (presentation?.diagrams.map(\.range) ?? []) + (presentation?.formulas.map(\.range) ?? []) + (presentation?.inlineFormulas.map(\.range) ?? []) + (presentation?.audioBlocks.map(\.range) ?? []) + (presentation?.iframeBlocks.map(\.range) ?? []) + (presentation?.htmlBlocks.map(\.range) ?? []) + markdownTOCRanges + markdownPageBreaks)
            .sorted { $0.location < $1.location }
        end = 0
        markdownContainerEnds = markdownContainers.map { range in
            end = max(end, NSMaxRange(range))
            return end
        }
        markdownHeadings = spans.filter {
            if case .heading = $0.kind { return true }
            return false
        }.sorted { $0.range.location < $1.range.location }
        markdownRevealedRange = revealedRange
        markdownInlineSelection = inlineSelection
        invalidateMarkdownLayout(in: range ?? NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    func invalidateMarkdownLayout(in range: NSRange) {
        guard let safe = clampedRange(range) else { return }
        invalidateFoldGlyphs(in: safe)
        invalidateLayout(forCharacterRange: safe, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: safe)
    }

    func updateMarkdownRevealedRange(_ range: NSRange?) {
        guard range != markdownRevealedRange else { return }
        let previous = markdownRevealedRange
        markdownRevealedRange = range
        for affected in [previous, range].compactMap({ $0 }) {
            var dirty = affected
            var index = upperBound(affected.location + affected.length, count: markdownContainers.count) {
                markdownContainers[$0].location
            }
            while index > 0 {
                index -= 1
                if markdownContainerEnds[index] < affected.location { break }
                let container = markdownContainers[index]
                if touches(container, affected) { dirty = NSUnionRange(dirty, container) }
            }
            invalidateMarkdownLayout(in: dirty)
        }
    }

    func updateMarkdownInlineSelection(_ range: NSRange?) {
        guard range != markdownInlineSelection else { return }
        let previous = markdownInlineSelection
        markdownInlineSelection = range
        for affected in [previous, range].compactMap({ $0 }) {
            var dirty = affected
            var index = upperBound(affected.location + affected.length, count: markdownContainers.count) { markdownContainers[$0].location }
            while index > 0 {
                index -= 1
                if markdownContainerEnds[index] < affected.location { break }
                let owner = markdownContainers[index]
                if touches(owner, affected) { dirty = NSUnionRange(dirty, owner) }
            }
            invalidateMarkdownLayout(in: dirty)
        }
    }

    func markdownHeadingFont(level: Int) -> NSFont {
        let scale: CGFloat = level == 1 ? 1.6 : (level == 2 ? 1.4 : (level == 3 ? 1.2 : 1))
        let bold = NSFontManager.shared.convert(textFont, toHaveTrait: .boldFontMask)
        let font = NSFont(descriptor: bold.fontDescriptor, size: textFont.pointSize * scale) ?? bold
        return markdownSmallCapsLevels.contains(level) ? (smallCapsFont(font) ?? font) : font
    }

    func isMarkdownMarkerHidden(at location: Int) -> Bool {
        guard textContainers.first?.textView?.hasMarkedText() != true else { return false }
        var index = upperBound(location, count: markdownMarkers.count) { markdownMarkers[$0].range.location }
        while index > 0 {
            index -= 1
            if markdownMarkerEnds[index] <= location { break }
            let marker = markdownMarkers[index]
            if NSLocationInRange(location, marker.range),
               !((marker.inline ? (markdownInlineSelection ?? markdownRevealedRange) : markdownRevealedRange).map { touches(marker.owner, $0) } ?? false) {
                return true
            }
        }
        return false
    }

    private func listMarker(at location: Int) -> MarkdownListMarker? {
        let index = upperBound(location, count: markdownListMarkers.count) { markdownListMarkers[$0].range.location }
        guard index > 0 else { return nil }
        let marker = markdownListMarkers[index - 1]
        guard NSLocationInRange(location, marker.range),
              !(markdownRevealedRange.map { touches(marker.line, $0) } ?? false),
              !intersectsFoldedRange(marker.range) else { return nil }
        return marker
    }

    private func listMarkerText(_ marker: MarkdownListMarker) -> String {
        if let ordinal = marker.ordinal, let style = resolvedListStyles.orderedStyle(at: marker.depth) {
            return style.marker(ordinal)
        }
        if marker.ordinal == nil, let (style, custom) = resolvedListStyles.unorderedStyle(at: marker.depth) {
            return style.marker(custom: custom)
        }
        return marker.text
    }

    private func touches(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        if rhs.length == 0 { return rhs.location >= lhs.location && rhs.location <= NSMaxRange(lhs) }
        return NSIntersectionRange(lhs, rhs).length > 0
    }

    private func textReplacement(at location: Int) -> MarkdownTextReplacement? {
        let index = upperBound(location, count: markdownTextReplacements.count) { markdownTextReplacements[$0].range.location }
        guard index > 0 else { return nil }
        let replacement = markdownTextReplacements[index - 1]
        let headingIndex = upperBound(location, count: markdownHeadings.count) { markdownHeadings[$0].range.location }
        if headingIndex > 0 {
            let heading = markdownHeadings[headingIndex - 1].range
            if NSLocationInRange(location, heading), uppercaseHeadingVisuals[heading] != nil, imageIsVisible(heading) { return nil }
        }
        guard NSLocationInRange(location, replacement.range),
              !(markdownInlineSelection.map { touches(replacement.range, $0) } ?? false),
              textContainers.first?.textView?.hasMarkedText() != true,
              !isCharacterFolded(location), !isMarkdownMarkerHidden(at: location),
              tableLine(at: location) == nil, inlineImage(at: location) == nil else { return nil }
        return replacement
    }

    private func textReplacementAttributes(at location: Int, in container: NSTextContainer) -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage, location < storage.length else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: (storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont) ?? textFont,
            .foregroundColor: (temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil) as? NSColor)
                ?? (storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
                ?? NSColor.textColor
        ]
        for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .baselineOffset] {
            if let value = temporaryAttribute(key, atCharacterIndex: location, effectiveRange: nil) ?? storage.attribute(key, at: location, effectiveRange: nil) {
                attributes[key] = value
            }
        }
        if container.layoutOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
        return attributes
    }

    private func upperBound(_ value: Int, count: Int, location: (Int) -> Int) -> Int {
        var lower = 0, upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if location(middle) <= value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func markdownFont(in glyphRange: NSRange) -> NSFont? {
        guard !markdownHeadings.isEmpty, glyphRange.length > 0 else { return nil }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let index = upperBound(NSMaxRange(characters) - 1, count: markdownHeadings.count) { markdownHeadings[$0].range.location }
        guard index > 0 else { return nil }
        let heading = markdownHeadings[index - 1]
        guard NSIntersectionRange(characters, heading.range).length > 0,
              case let .heading(level) = heading.kind else { return nil }
        return markdownHeadingFont(level: level)
    }

    override init() {
        super.init()
        delegate = self
        updateFontMetrics()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        updateFontMetrics()
    }

    override func setExtraLineFragmentRect(
        _ fragmentRect: NSRect,
        usedRect: NSRect,
        textContainer container: NSTextContainer
    ) {
        var fragmentRect = fragmentRect
        var usedRect = usedRect
        fragmentRect.size.height = editorLineHeight
        usedRect.size.height = editorLineHeight
        super.setExtraLineFragmentRect(
            fragmentRect,
            usedRect: usedRect,
            textContainer: container
        )
    }

    override func invalidateDisplay(forCharacterRange charRange: NSRange) {
        guard groupsTemporaryAttributeUpdates else {
            invalidateEditorDisplay(in: charRange)
            return
        }
        if let pendingTemporaryDisplayRange {
            let start = min(pendingTemporaryDisplayRange.location, charRange.location)
            let end = max(
                NSMaxRange(pendingTemporaryDisplayRange),
                NSMaxRange(charRange)
            )
            self.pendingTemporaryDisplayRange = NSRange(
                location: start,
                length: end - start
            )
        } else {
            pendingTemporaryDisplayRange = charRange
        }
    }

    /// Groups temporary syntax color changes into one display invalidation so
    /// the screen never presents an intermediate, partially recolored frame.
    func updateTemporaryAttributes(
        in range: NSRange,
        _ updates: () -> Void
    ) {
        let wasGrouping = groupsTemporaryAttributeUpdates
        groupsTemporaryAttributeUpdates = true
        updates()
        groupsTemporaryAttributeUpdates = wasGrouping
        guard !wasGrouping else { return }
        let invalidatedRange = pendingTemporaryDisplayRange ?? range
        pendingTemporaryDisplayRange = nil
        invalidateEditorDisplay(in: invalidatedRange)
    }

    private func invalidateEditorDisplay(in range: NSRange) {
        guard EditorLayoutPolicy.usesViewportLayout(textLength: textStorage?.length ?? 0) else {
            super.invalidateDisplay(forCharacterRange: range)
            return
        }
        // Filling a noncontiguous layout hole can invalidate display once per
        // fragment. Forwarding each callback reenters NSTextView's preparation
        // and recalculates usage over all earlier layout fragments. Flush one
        // union after layout returns, through the same native invalidation API.
        pendingViewportDisplayRange = pendingViewportDisplayRange.map { NSUnionRange($0, range) } ?? range
        guard !viewportDisplayScheduled else { return }
        viewportDisplayScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushViewportDisplay() }
    }

    private func flushViewportDisplay() {
        viewportDisplayScheduled = false
        guard let range = pendingViewportDisplayRange else { return }
        pendingViewportDisplayRange = nil
        let length = textStorage?.length ?? 0
        let location = min(range.location, length)
        super.invalidateDisplay(forCharacterRange: NSRange(
            location: location, length: min(range.length, length - location)
        ))
    }

    func setFoldedRange(_ range: NSRange?) {
        let safeRange = range.flatMap(clampedRange)
        guard foldedRange != safeRange else { return }
        let previousRange = foldedRange
        foldedRange = safeRange

        if let previousRange {
            invalidateFoldGlyphs(in: previousRange)
        }
        if let safeRange {
            invalidateFoldGlyphs(in: safeRange)
        }
    }

    func setAutomaticMediaFoldedRanges(_ ranges: [NSRange]) {
        let safeRanges = ranges.compactMap(clampedRange).sorted { $0.location < $1.location }
        guard automaticMediaFoldedRanges != safeRanges else { return }
        let previous = automaticMediaFoldedRanges
        automaticMediaFoldedRanges = safeRanges
        for range in previous { invalidateFoldGlyphs(in: range) }
        for range in safeRanges { invalidateFoldGlyphs(in: range) }
    }

    func removeAutomaticMediaFold(containing location: Int) -> Bool {
        guard let index = automaticMediaFoldedRanges.firstIndex(where: {
            location >= $0.location && location <= NSMaxRange($0)
        }) else { return false }
        let range = automaticMediaFoldedRanges.remove(at: index)
        invalidateFoldGlyphs(in: range)
        return true
    }

    func toggleAutomaticMediaFold(_ range: NSRange) {
        if let index = automaticMediaFoldedRanges.firstIndex(of: range) {
            let previous = automaticMediaFoldedRanges.remove(at: index)
            invalidateFoldGlyphs(in: previous)
        } else if let safe = clampedRange(range) {
            automaticMediaFoldedRanges.append(safe)
            automaticMediaFoldedRanges.sort { $0.location < $1.location }
            invalidateFoldGlyphs(in: safe)
        }
    }

    func intersectsFoldedRange(_ range: NSRange) -> Bool {
        if let foldedRange, NSIntersectionRange(foldedRange, range).length > 0 { return true }
        return automaticMediaFoldedRanges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    func isCharacterFolded(_ characterIndex: Int) -> Bool {
        if let foldedRange, NSLocationInRange(characterIndex, foldedRange) { return true }
        return automaticMediaFoldedRanges.contains { NSLocationInRange(characterIndex, $0) }
    }

    func isCharacterRangeFullyFolded(_ characterRange: NSRange) -> Bool {
        guard characterRange.length > 0 else { return false }
        if let foldedRange, NSIntersectionRange(foldedRange, characterRange).length == characterRange.length { return true }
        return automaticMediaFoldedRanges.contains {
            NSIntersectionRange($0, characterRange).length == characterRange.length
        }
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard foldedRange != nil || !automaticMediaFoldedRanges.isEmpty || !markdownMarkers.isEmpty || !markdownTextReplacements.isEmpty || !markdownListMarkers.isEmpty || !markdownImages.isEmpty || !markdownBlockImages.isEmpty || !markdownInlineImages.isEmpty || !markdownMedia.isEmpty || !markdownTOCRanges.isEmpty || !markdownPageBreaks.isEmpty || !tableLines.isEmpty else { return 0 }

        // A data-URI image can occupy many glyph-generation batches. Once a
        // batch is wholly inside an installed block image, every glyph is
        // hidden; avoid running all Markdown lookups for every Base64 unit.
        if glyphRange.length > 0 {
            let firstCharacter = characterIndexes[0]
            let lastCharacter = characterIndexes[glyphRange.length - 1]
            if markdownImages.contains(where: {
                imageIsVisible($0.range)
                    && NSLocationInRange(firstCharacter, $0.range)
                    && NSLocationInRange(lastCharacter, $0.range)
            }) {
                let hiddenProperties = [NSLayoutManager.GlyphProperty](
                    repeating: .null,
                    count: glyphRange.length
                )
                hiddenProperties.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    layoutManager.setGlyphs(
                        glyphs,
                        properties: baseAddress,
                        characterIndexes: characterIndexes,
                        font: font,
                        forGlyphRange: glyphRange
                    )
                }
                return glyphRange.length
            }
        }

        var adjustedProperties = Array(
            UnsafeBufferPointer(start: properties, count: glyphRange.length)
        )
        var didFoldGlyph = false
        for offset in adjustedProperties.indices where isCharacterFolded(characterIndexes[offset])
            || isMarkdownMarkerHidden(at: characterIndexes[offset])
            || visibleTOC(containing: characterIndexes[offset])
            || pageBreak(containing: characterIndexes[offset]) != nil
            || tableLine(at: characterIndexes[offset]) != nil
            || markdownImages.contains(where: { imageIsVisible($0.range) && NSLocationInRange(characterIndexes[offset], $0.range) })
            || markdownMedia.contains(where: { imageIsVisible($0.range) && NSLocationInRange(characterIndexes[offset], $0.range) })
            || markdownBlockImages.contains(where: { imageIsVisible($0.range) && NSLocationInRange(characterIndexes[offset], $0.range) }) {
            adjustedProperties[offset] = .null
            didFoldGlyph = true
        }
        for offset in adjustedProperties.indices {
            let character = characterIndexes[offset]
            if let replacement = textReplacement(at: character) {
                adjustedProperties[offset] = character == replacement.range.location ? .controlCharacter : .null
                didFoldGlyph = true
                continue
            }
            if let marker = listMarker(at: character), !isCharacterFolded(character), tableLine(at: character) == nil {
                adjustedProperties[offset] = character == marker.range.location ? .controlCharacter : .null
                didFoldGlyph = true
                continue
            }
            guard let entry = inlineImage(at: character),
                  !isCharacterFolded(character), !isMarkdownMarkerHidden(at: character), tableLine(at: character) == nil else { continue }
            adjustedProperties[offset] = character == entry.range.location ? .controlCharacter : .null
            didFoldGlyph = true
        }
        guard didFoldGlyph else { return 0 }

        adjustedProperties.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            layoutManager.setGlyphs(
                glyphs,
                properties: baseAddress,
                characterIndexes: characterIndexes,
                font: font,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        (textReplacement(at: charIndex)?.range.location == charIndex || inlineImage(at: charIndex)?.range.location == charIndex || listMarker(at: charIndex)?.range.location == charIndex) ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
        if let replacement = textReplacement(at: characterIndex), replacement.range.location == characterIndex {
            let size = (replacement.text as NSString).size(withAttributes: textReplacementAttributes(at: characterIndex, in: textContainer))
            return NSRect(origin: .zero, size: size)
        }
        if let marker = listMarker(at: characterIndex), marker.range.location == characterIndex {
            let font = (textStorage?.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont) ?? textFont
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if textContainer.layoutOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
            let size = (listMarkerText(marker) as NSString).size(withAttributes: attributes)
            return NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        guard let entry = inlineImage(at: characterIndex), entry.range.location == characterIndex else { return .zero }
        let size = textContainer.layoutOrientation == .vertical
            ? NSSize(width: entry.image.size.height, height: entry.image.size.width) : entry.image.size
        return NSRect(origin: .zero, size: size)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        lineSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: NSRect
    ) -> CGFloat {
        // Line spacing is encoded in each paragraph's fixed line height by
        // LacTextView. Applying it here only affects glyph-backed lines and
        // makes TextKit's trailing extra line fragment jump when typed into.
        0
    }

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        let character = characterIndexForGlyph(at: glyphIndex)
        let original = textStorage.flatMap { storage -> CGFloat? in
            guard character < storage.length else { return nil }
            return (storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing
        } ?? 0
        guard let markdownParagraphSpacing, !isCharacterFolded(character) else { return original }
        let index = upperBound(character, count: markdownParagraphs.count) { markdownParagraphs[$0].lastLine.location }
        guard index > 0, NSLocationInRange(character, markdownParagraphs[index - 1].lastLine),
              glyphIndex == glyphIndexForCharacter(at: NSMaxRange(markdownParagraphs[index - 1].lastLine) - 1),
              let separator = markdownParagraphs[index - 1].separatorAfter,
              !(markdownRevealedRange.map { touches(NSUnionRange(markdownParagraphs[index - 1].range, separator), $0) } ?? false) else { return original }
        return markdownParagraphSpacing
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if markdownParagraphSpacing != nil, characters.length > 0 {
            let index = upperBound(characters.location, count: markdownParagraphSeparators.count) { markdownParagraphSeparators[$0].range.location }
            if index > 0 {
                let separator = markdownParagraphSeparators[index - 1]
                if NSIntersectionRange(separator.range, characters).length > 0,
                   !(markdownRevealedRange.map { touches(separator.owner, $0) } ?? false),
                   !isCharacterFolded(characters.location) {
                    lineFragmentRect.pointee.size.height = 0.01
                    lineFragmentUsedRect.pointee.size.height = 0.01
                    return true
                }
            }
        }
        if characters.length > 0, let line = tableLine(intersecting: characters) {
            let (_, width) = tableHorizontalGeometry(line, container: textContainer)
            let height = line.row == nil ? CGFloat(0.01) : (tableLineGeometry(line, width: width).first?.rect.height ?? editorLineHeight) + (line.rowIndex == 0 ? 12 : 0)
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = editorBaselineOffset(orientation: textContainer.layoutOrientation)
            return true
        }
        let breakIndex = characters.length > 0 ? upperBound(NSMaxRange(characters) - 1, count: markdownPageBreaks.count) { markdownPageBreaks[$0].location } : 0
        if breakIndex > 0, let range = pageBreak(containing: markdownPageBreaks[breakIndex - 1].location),
           NSIntersectionRange(characters, range).length > 0 {
            let first = characters.location <= range.location && NSMaxRange(characters) > range.location
            let height = first ? editorLineHeight : 0.01
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = editorBaselineOffset(orientation: textContainer.layoutOrientation)
            return true
        }
        if visibleTOC(intersecting: characters) {
            let width = max(1, textContainer.size.width - 2 * textContainer.lineFragmentPadding)
            let height = tocRows(width: width).last.map { $0.1.maxY } ?? editorLineHeight
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = editorBaselineOffset(orientation: textContainer.layoutOrientation)
            return true
        }
        if let entry = markdownMedia.first(where: { imageIsVisible($0.range) && NSIntersectionRange($0.range, characters).length > 0 }) {
            let first = characters.location <= entry.range.location && NSMaxRange(characters) > entry.range.location
            let extent = textContainer.layoutOrientation == .vertical ? entry.size.width : entry.size.height
            let height = first ? max(editorLineHeight, extent) : 0.01
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = editorBaselineOffset(orientation: textContainer.layoutOrientation)
            return true
        }
        if let entry = markdownBlockImages.first(where: { imageIsVisible($0.range) && NSIntersectionRange($0.range, characters).length > 0 }),
           entry.image.size.width > 0, entry.image.size.height > 0 {
            let first = NSLocationInRange(glyphIndexForCharacter(at: entry.range.location), glyphRange)
            let indent = listImageIndent(entry.range)
            let extent: CGFloat
            if let visual = uppercaseHeadingVisuals[entry.range] {
                let visible = textContainer.textView?.visibleRect.width ?? textContainer.size.width
                let width = max(0, min(textContainer.size.width, visible) - 2 * textContainer.lineFragmentPadding - indent)
                extent = visual.size.height * (visual.size.width > 0 ? min(1, width / visual.size.width) : 1)
            } else { extent = imageLogicalSize(entry.image, in: textContainer, indent: indent).height }
            let height = first ? max(editorLineHeight, extent) : 0.01
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = editorBaselineOffset(orientation: textContainer.layoutOrientation)
            return true
        }
        if let entry = markdownImages.first(where: { imageIsVisible($0.range) && NSIntersectionRange($0.range, characters).length > 0 }),
           entry.image.size.width > 0, entry.image.size.height > 0 {
            let first = NSLocationInRange(glyphIndexForCharacter(at: entry.range.location), glyphRange)
            let height = first
                ? max(editorLineHeight, imageLogicalSize(entry.image, in: textContainer, centered: true).height)
                : 0.01
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = editorBaselineOffset(orientation: textContainer.layoutOrientation)
            return true
        }
        if markdownInlineImages.contains(where: { imageIsVisible($0.range) && NSIntersectionRange($0.range, characters).length > 0 }) {
            let baseHeight: CGFloat
            let baseline: CGFloat
            if let font = markdownFont(in: glyphRange) {
                baseHeight = max(editorLineHeight, defaultLineHeight(for: font) + editorLineSpacing)
                baseline = (baseHeight + defaultBaselineOffset(for: font) - (font.ascender - font.capHeight)) / 2
            } else {
                baseHeight = editorLineHeight
                baseline = editorBaselineOffset(orientation: textContainer.layoutOrientation)
            }
            let ordinaryImageHeight = markdownInlineImages.filter {
                markdownRubyBaselines[$0.range] == nil && imageIsVisible($0.range) && NSIntersectionRange($0.range, characters).length > 0
            }.map { textContainer.layoutOrientation == .vertical ? $0.image.size.width : $0.image.size.height }.max() ?? 0
            var ascent = max(baseline, ordinaryImageHeight), descent = max(0, baseHeight - baseline)
            for entry in markdownInlineImages where imageIsVisible(entry.range) && NSIntersectionRange(entry.range, characters).length > 0 {
                guard let rubyBaseline = markdownRubyBaselines[entry.range] else { continue }
                let above: CGFloat, below: CGFloat
                if textContainer.layoutOrientation == .vertical {
                    guard let view = textContainer.textView, let clip = view.enclosingScrollView?.contentView else { continue }
                    let start = clip.convert(NSPoint.zero, from: view)
                    let end = clip.convert(NSPoint(x: 0, y: 1), from: view)
                    above = end.x >= start.x ? rubyBaseline.x : entry.image.size.width - rubyBaseline.x
                    below = entry.image.size.width - above
                } else {
                    above = rubyBaseline.y
                    below = entry.image.size.height - rubyBaseline.y
                }
                ascent = max(ascent, above); descent = max(descent, below)
            }
            let height = max(baseHeight, ascent + descent)
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = height - descent
            return true
        }
        if let font = markdownFont(in: glyphRange) {
            let height = max(editorLineHeight, defaultLineHeight(for: font) + editorLineSpacing)
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = (height + defaultBaselineOffset(for: font)
                - (font.ascender - font.capHeight)) / 2
            return true
        }
        lineFragmentRect.pointee.size.height = editorLineHeight
        lineFragmentUsedRect.pointee.size.height = editorLineHeight
        baselineOffset.pointee = editorBaselineOffset(
            orientation: textContainer.layoutOrientation
        )
        return true
    }

    private func editorBaselineOffset(
        orientation: NSLayoutManager.TextLayoutOrientation
    ) -> CGFloat {
        switch orientation {
        case .vertical:
            return editorLineHeight / 2
        case .horizontal:
            // AppKit's default baseline includes the font's top leading. Drop
            // that visual cap-height difference before centering the glyphs.
            let topLeading = textFont.ascender - textFont.capHeight
            return (
                editorLineHeight
                    + cachedDefaultBaselineOffset
                    - topLeading
            ) / 2
        @unknown default:
            return editorLineHeight / 2
        }
    }

    private func updateFontMetrics() {
        cachedDefaultLineHeight = defaultLineHeight(for: textFont)
        cachedDefaultBaselineOffset = defaultBaselineOffset(for: textFont)
    }

    private func invalidateEditorLayout() {
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: range)
    }

    private func clampedRange(_ range: NSRange) -> NSRange? {
        let textLength = textStorage?.length ?? NSMaxRange(range)
        let safeRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: textLength)
        )
        return safeRange.length > 0 ? safeRange : nil
    }

    private func invalidateFoldGlyphs(in range: NSRange) {
        guard let safeRange = clampedRange(range) else { return }
        invalidateGlyphs(
            forCharacterRange: safeRange,
            changeInLength: 0,
            actualCharacterRange: nil
        )
    }
}
