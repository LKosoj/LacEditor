import AppKit

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
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.backgroundLayoutEnabled = !usesViewportLayout(
            textLength: textLength
        )
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
    private struct MarkdownMarker {
        let range: NSRange
        let owner: NSRange
    }
    private var markdownMarkers: [MarkdownMarker] = []
    private var markdownMarkerEnds: [Int] = []
    private var markdownContainers: [NSRange] = []
    private var markdownContainerEnds: [Int] = []
    private var markdownHeadings: [MarkdownPresentationSpan] = []
    private var markdownRevealedRange: NSRange?

    func setMarkdownPresentation(_ presentation: MarkdownPresentation?, revealedRange: NSRange?, invalidating range: NSRange? = nil) {
        if presentation == nil && markdownMarkers.isEmpty && markdownHeadings.isEmpty && range != nil {
            markdownRevealedRange = nil
            return
        }
        let spans = presentation?.spans ?? []
        markdownMarkers = spans.flatMap { span in
            span.markerRanges.map { MarkdownMarker(range: $0, owner: span.range) }
        }.sorted { $0.range.location < $1.range.location }
        var end = 0
        markdownMarkerEnds = markdownMarkers.map { marker in
            end = max(end, NSMaxRange(marker.range))
            return end
        }
        markdownContainers = spans.filter { !$0.markerRanges.isEmpty }.map(\.range)
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
            invalidateFoldGlyphs(in: dirty)
        }
    }

    func markdownHeadingFont(level: Int) -> NSFont {
        let scale: CGFloat = level == 1 ? 1.6 : (level == 2 ? 1.4 : (level == 3 ? 1.2 : 1))
        let bold = NSFontManager.shared.convert(textFont, toHaveTrait: .boldFontMask)
        return NSFont(descriptor: bold.fontDescriptor, size: textFont.pointSize * scale) ?? bold
    }

    func isMarkdownMarkerHidden(at location: Int) -> Bool {
        guard textContainers.first?.textView?.hasMarkedText() != true else { return false }
        var index = upperBound(location, count: markdownMarkers.count) { markdownMarkers[$0].range.location }
        while index > 0 {
            index -= 1
            if markdownMarkerEnds[index] <= location { break }
            let marker = markdownMarkers[index]
            if NSLocationInRange(location, marker.range),
               !(markdownRevealedRange.map { touches(marker.owner, $0) } ?? false) {
                return true
            }
        }
        return false
    }

    private func touches(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        if rhs.length == 0 { return rhs.location >= lhs.location && rhs.location <= NSMaxRange(lhs) }
        return NSIntersectionRange(lhs, rhs).length > 0
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

    func isCharacterFolded(_ characterIndex: Int) -> Bool {
        guard let foldedRange else { return false }
        return NSLocationInRange(characterIndex, foldedRange)
    }

    func isCharacterRangeFullyFolded(_ characterRange: NSRange) -> Bool {
        guard let foldedRange, characterRange.length > 0 else { return false }
        return NSIntersectionRange(foldedRange, characterRange).length
            == characterRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard foldedRange != nil || !markdownMarkers.isEmpty else { return 0 }

        var adjustedProperties = Array(
            UnsafeBufferPointer(start: properties, count: glyphRange.length)
        )
        var didFoldGlyph = false
        for offset in adjustedProperties.indices where isCharacterFolded(characterIndexes[offset])
            || isMarkdownMarkerHidden(at: characterIndexes[offset]) {
            adjustedProperties[offset] = .null
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

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
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
