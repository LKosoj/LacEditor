import AppKit
import os

private let lineNumberPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "EditorPerformance"
)

struct LineNumberVisibleLine: Equatable {
    let number: Int
    let characterRange: NSRange
    let rulerRect: NSRect
}

struct LineNumberVisibleMapCacheKey: Equatable {
    let visibleTextRect: NSRect
    let contentLayoutRect: NSRect
    let rulerBounds: NSRect
    let textContainerWidth: CGFloat
    let textLength: Int
    let layoutGeneration: UInt
    let foldedRange: NSRange?
}

enum LineNumberGeometry {
    static func rulerRect(
        for textViewRect: NSRect,
        visibleTextRect: NSRect,
        contentLayoutRect: NSRect,
        rulerBounds: NSRect
    ) -> NSRect {
        NSRect(
            x: rulerBounds.minX,
            y: contentLayoutRect.minY
                + textViewRect.minY
                - visibleTextRect.minY,
            width: rulerBounds.width,
            height: textViewRect.height
        )
    }

    static let trailingGap: CGFloat = 8
    static let minimumThickness: CGFloat = 44

    /// Ruler width that fits the digits of the largest line number; never below the minimum.
    static func thickness(forLineCount count: Int, digitWidth: CGFloat) -> CGFloat {
        let digits = max(2, String(max(1, count)).count)
        return max(minimumThickness, ceil(CGFloat(digits) * digitWidth) + 8 + trailingGap)
    }

    static func labelOrigin(
        rulerWidth: CGFloat,
        labelSize: NSSize,
        lineRect: NSRect
    ) -> NSPoint {
        NSPoint(
            x: floor(rulerWidth - labelSize.width - trailingGap),
            y: floor(lineRect.midY - labelSize.height / 2)
        )
    }

    static func horizontalLabelOrigin(rulerHeight: CGFloat, labelSize: NSSize, lineRect: NSRect) -> NSPoint {
        NSPoint(x: floor(lineRect.midX - labelSize.width / 2), y: floor((rulerHeight - labelSize.height) / 2))
    }

    static func selectionRange(
        from firstLine: NSRange,
        to lastLine: NSRange
    ) -> NSRange {
        let start = min(firstLine.location, lastLine.location)
        let end = max(NSMaxRange(firstLine), NSMaxRange(lastLine))
        return NSRange(location: start, length: max(0, end - start))
    }
}

final class LineNumberRulerView: NSRulerView {
    var lineNumberProvider: ((Int) -> Int)?

    override var isOpaque: Bool { true }

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var visibleLineMap: [LineNumberVisibleLine] = []
    private var contentDrawingRect: NSRect = .zero
    private var dragAnchorLine: LineNumberVisibleLine?
    private var visibleLineMapCacheKey: LineNumberVisibleMapCacheKey?
    private var layoutGeneration: UInt = 0
    private lazy var digitWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width

    init(scrollView: NSScrollView, textView: NSTextView, orientation: NSRulerView.Orientation = .verticalRuler) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = textView
        ruleThickness = 44
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.drawsAsynchronously = false
    }

    /// Returns true when the width changed. Never call from draw: the caller must re-run layout.
    @discardableResult
    func updateThickness(lineCount: Int) -> Bool {
        guard orientation == .verticalRuler else { return false }
        let value = LineNumberGeometry.thickness(forLineCount: lineCount, digitWidth: digitWidth)
        guard abs(ruleThickness - value) > 0.5 else { return false }
        ruleThickness = value
        return true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateHashMarks()
        setNeedsDisplay(bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func displaySelectionImmediately() {
        invalidateHashMarks()
        needsDisplay = true
        setNeedsDisplay(bounds)
        displayIfNeeded()
    }

    func requestRedraw(invalidateLineMap: Bool = true) {
        if invalidateLineMap {
            layoutGeneration &+= 1
            visibleLineMapCacheKey = nil
        }
        invalidateHashMarks()
        needsDisplay = true
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in dirtyRect: NSRect) {
        let drawSignpostID = OSSignpostID(log: lineNumberPerformanceLog)
        os_signpost(
            .begin,
            log: lineNumberPerformanceLog,
            name: "LineNumberDraw",
            signpostID: drawSignpostID
        )
        defer {
            os_signpost(
                .end,
                log: lineNumberPerformanceLog,
                name: "LineNumberDraw",
                signpostID: drawSignpostID
            )
        }

        NSColor.lacEditorBackground.setFill()
        bounds.fill(using: .copy)
        rebuildVisibleLineMap()
        guard !contentDrawingRect.isEmpty else { return }

        let selectedLineLocations: ClosedRange<Int>
        if let textView = clientView as? NSTextView,
           let text = textView.textStorage?.mutableString {
            selectedLineLocations = LogicalLineIndex.selectedLineLocations(
                in: text,
                selectedRange: textView.selectedRange()
            )
        } else {
            selectedLineLocations = 0...0
        }

        for line in visibleLineMap where line.rulerRect.intersects(dirtyRect) {
            draw(
                lineNumber: line.number,
                lineRect: line.rulerRect,
                isActive: selectedLineLocations.contains(line.characterRange.location),
                clippingTo: contentDrawingRect
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let line = visibleLine(near: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }

        dragAnchorLine = anchorLine(for: event, fallback: line)
        select(from: dragAnchorLine ?? line, to: line, stillSelecting: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchorLine else {
            super.mouseDragged(with: event)
            return
        }

        scrollView?.autoscroll(with: event)
        rebuildVisibleLineMap()
        guard let line = visibleLine(near: convert(event.locationInWindow, from: nil)) else {
            return
        }
        select(from: anchor, to: line, stillSelecting: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragAnchorLine = nil }
        guard let anchor = dragAnchorLine else {
            super.mouseUp(with: event)
            return
        }
        rebuildVisibleLineMap()
        if let line = visibleLine(near: convert(event.locationInWindow, from: nil)) {
            select(from: anchor, to: line, stillSelecting: false)
        }
    }

    private func rebuildVisibleLineMap() {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let text = textView.textStorage?.mutableString else {
            visibleLineMap = []
            contentDrawingRect = .zero
            return
        }

        // Share the clip view's physical viewport with the text. Do not anchor
        // labels to the titlebar safe area: that pins the first visible number.
        let contentLayoutRect = scrollView.map {
            let viewport = convert($0.contentView.bounds, from: $0.contentView)
            let rect = orientation == .horizontalRuler
                ? NSRect(x: viewport.minX, y: bounds.minY, width: viewport.width, height: bounds.height)
                : NSRect(x: bounds.minX, y: viewport.minY, width: bounds.width, height: viewport.height)
            return bounds.intersection(rect)
        } ?? bounds
        contentDrawingRect = contentLayoutRect
        guard !contentLayoutRect.isEmpty else {
            visibleLineMap = []
            visibleLineMapCacheKey = nil
            return
        }

        let visibleRect = textView.visibleRect
        let cacheKey = LineNumberVisibleMapCacheKey(
            visibleTextRect: visibleRect,
            contentLayoutRect: contentLayoutRect,
            rulerBounds: bounds,
            textContainerWidth: textContainer.containerSize.width,
            textLength: text.length,
            layoutGeneration: layoutGeneration,
            foldedRange: (layoutManager as? FoldLayoutManager)?.foldedRange
        )
        if visibleLineMapCacheKey == cacheKey {
            return
        }
        let containerRect = visibleRect.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRectWithoutAdditionalLayout: containerRect,
            in: textContainer
        )
        guard glyphRange.length > 0 || text.length == 0 else {
            visibleLineMap = []
            visibleLineMapCacheKey = nil
            return
        }
        let visibleCharacterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let firstCharacterLocation: Int
        if orientation == .horizontalRuler {
            firstCharacterLocation = min(visibleCharacterRange.location, text.length)
        } else if containerRect.minY <= 0.5 || text.length == 0 {
            firstCharacterLocation = 0
        } else {
            let firstGlyph = layoutManager.glyphIndex(
                for: NSPoint(x: 0, y: containerRect.minY),
                in: textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            firstCharacterLocation = min(
                layoutManager.characterIndexForGlyph(at: firstGlyph),
                text.length
            )
        }
        let characterRange = NSRange(
            location: firstCharacterLocation,
            length: max(0, NSMaxRange(visibleCharacterRange) - firstCharacterLocation)
        )

        var lines: [LineNumberVisibleLine] = []
        var lineNumber = lineNumberProvider?(characterRange.location) ?? 1
        if lineNumberProvider == nil, characterRange.location > 0 {
            lineNumber = LogicalLineIndex(
                text: text.substring(to: characterRange.location)
            ).lineNumber(at: characterRange.location)
        }
        var index = text.lineRange(
            for: NSRange(location: characterRange.location, length: 0)
        ).location

        while index < NSMaxRange(characterRange), index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            defer {
                lineNumber += 1
                index = NSMaxRange(lineRange)
            }
            if let foldLayoutManager = layoutManager as? FoldLayoutManager,
               foldLayoutManager.isCharacterRangeFullyFolded(lineRange) {
                continue
            }

            let anchor = LogicalLineIndex.layoutAnchorCharacterIndex(
                in: text,
                lineRange: lineRange,
                foldedRange: (layoutManager as? FoldLayoutManager)?.foldedRange
            )
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: anchor)
            var textViewRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            textViewRect.origin.x += textView.textContainerOrigin.x
            textViewRect.origin.y += textView.textContainerOrigin.y
            var rulerRect = convert(textViewRect, from: textView)
            if orientation == .horizontalRuler { rulerRect.origin.y = bounds.minY; rulerRect.size.height = bounds.height }
            else { rulerRect.origin.x = bounds.minX; rulerRect.size.width = bounds.width }
            guard rulerRect.intersects(contentLayoutRect) else { continue }
            lines.append(LineNumberVisibleLine(
                number: lineNumber,
                characterRange: lineRange,
                rulerRect: rulerRect
            ))
        }

        let trailingCharacter = text.length > 0 ? text.character(at: text.length - 1) : 0
        let hasTrailingEmptyLine = text.length == 0
            || trailingCharacter == 0x0A
            || trailingCharacter == 0x0D
            || trailingCharacter == 0x2028
            || trailingCharacter == 0x2029
        if hasTrailingEmptyLine {
            var textViewRect = layoutManager.extraLineFragmentRect
            if textViewRect.isEmpty {
                textViewRect = NSRect(
                    x: textView.textContainerOrigin.x,
                    y: textView.textContainerOrigin.y,
                    width: 1,
                    height: max(font.pointSize + 3, textView.font?.pointSize ?? 14)
                )
            } else {
                textViewRect.origin.x += textView.textContainerOrigin.x
                textViewRect.origin.y += textView.textContainerOrigin.y
            }
            var rulerRect = convert(textViewRect, from: textView)
            if orientation == .horizontalRuler { rulerRect.origin.y = bounds.minY; rulerRect.size.height = bounds.height }
            else { rulerRect.origin.x = bounds.minX; rulerRect.size.width = bounds.width }
            if rulerRect.intersects(contentLayoutRect) {
                lines.append(LineNumberVisibleLine(
                    number: lineNumber,
                    characterRange: NSRange(location: text.length, length: 0),
                    rulerRect: rulerRect
                ))
            }
        }

        visibleLineMap = lines
        visibleLineMapCacheKey = cacheKey
    }

    private func visibleLine(near point: NSPoint) -> LineNumberVisibleLine? {
        rebuildVisibleLineMap()
        guard !contentDrawingRect.isEmpty,
              !visibleLineMap.isEmpty else {
            return nil
        }
        return visibleLineMap.min { first, second in
            distance(from: point, to: first.rulerRect) < distance(from: point, to: second.rulerRect)
        }
    }

    private func anchorLine(
        for event: NSEvent,
        fallback: LineNumberVisibleLine
    ) -> LineNumberVisibleLine {
        guard event.modifierFlags.contains(.shift),
              let textView = clientView as? NSTextView,
              let text = textView.textStorage?.mutableString else {
            return fallback
        }
        let location = min(textView.selectedRange().location, text.length)
        let range = text.lineRange(for: NSRange(location: location, length: 0))
        return LineNumberVisibleLine(
            number: lineNumberProvider?(range.location) ?? fallback.number,
            characterRange: range,
            rulerRect: fallback.rulerRect
        )
    }

    private func select(
        from firstLine: LineNumberVisibleLine,
        to lastLine: LineNumberVisibleLine,
        stillSelecting: Bool
    ) {
        guard let textView = clientView as? LacTextView else { return }
        let selection = LineNumberGeometry.selectionRange(
            from: firstLine.characterRange,
            to: lastLine.characterRange
        )
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(
            selection,
            affinity: .downstream,
            stillSelecting: stillSelecting
        )
        displaySelectionImmediately()
    }

    private func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        if orientation == .horizontalRuler {
            if point.x >= rect.minX && point.x <= rect.maxX { return 0 }
            return min(abs(point.x - rect.minX), abs(point.x - rect.maxX))
        }
        if point.y >= rect.minY && point.y <= rect.maxY { return 0 }
        return min(abs(point.y - rect.minY), abs(point.y - rect.maxY))
    }

    private func draw(
        lineNumber: Int,
        lineRect: NSRect,
        isActive: Bool,
        clippingTo drawingRect: NSRect
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isActive ? NSColor.labelColor : NSColor.lacMutedText
        ]
        let value = "\(lineNumber)" as NSString
        let size = value.size(withAttributes: attributes)
        let origin = orientation == .horizontalRuler
            ? LineNumberGeometry.horizontalLabelOrigin(rulerHeight: bounds.height, labelSize: size, lineRect: lineRect)
            : LineNumberGeometry.labelOrigin(rulerWidth: bounds.width, labelSize: size, lineRect: lineRect)
        let labelRect = NSRect(origin: origin, size: size)
        let visibleLabelRect = NSIntersectionRect(labelRect, drawingRect)
        guard !visibleLabelRect.isEmpty else { return }

        if visibleLabelRect.equalTo(labelRect) {
            value.draw(at: origin, withAttributes: attributes)
            return
        }
        let image = NSImage(size: size, flipped: true) { _ in
            value.draw(at: .zero, withAttributes: attributes)
            return true
        }
        image.draw(
            in: visibleLabelRect,
            from: visibleLabelRect.offsetBy(dx: -labelRect.minX, dy: -labelRect.minY),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}
