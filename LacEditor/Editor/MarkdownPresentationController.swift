import AppKit

/// Keeps the source text unchanged while applying formatting to visible text.
final class MarkdownPresentationController {
    private weak var textView: LacTextView?
    private weak var layout: FoldLayoutManager?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var work: DispatchWorkItem?
    private var operation: BlockOperation?
    private var presentation: MarkdownPresentation?
    private var parsedResult: MarkdownPresentation?
    private var outlineVisible = false
    private var spans: [MarkdownPresentationSpan] = []
    private var prefixEnds: [Int] = []
    private var styledRanges: [NSRange] = []
    private var backgroundRanges: [NSRange] = []
    private var lastVisibleRange: NSRange?
    private var lastRevealedRange: NSRange?
    var geometryDidChange: (() -> Void)?
    var restoreDelimiterHighlight: (() -> Void)?
    private var enabled = false
    private var isActive = false
    private var needsRefresh = false
    private var needsCompositionRefresh = false
    private var generation: UInt = 0
    private var document: EditorDocument?
    private var revision: UInt = 0
    private var currentRevision: (() -> UInt)?

    init(textView: LacTextView, layout: FoldLayoutManager) {
        self.textView = textView
        self.layout = layout
    }

    func update(document: EditorDocument, enabled: Bool, outlineVisible: Bool = false, isActive: Bool, revision: UInt, currentRevision: @escaping () -> UInt) {
        let documentChanged = self.document !== document
        let formatChanged = self.enabled != enabled
        let activated = !self.isActive && isActive
        if documentChanged || (self.isActive && !isActive) { cancel() }
        if documentChanged { parsedResult = nil }
        self.document = document
        self.enabled = enabled
        self.outlineVisible = outlineVisible
        self.isActive = isActive
        self.currentRevision = currentRevision
        self.revision = revision
        if documentChanged || formatChanged { needsRefresh = true }
        guard isActive else { return }
        guard textView?.hasMarkedText() != true else {
            if needsRefresh { needsCompositionRefresh = true }
            return
        }
        if needsRefresh {
            needsRefresh = false
            if presentation != nil || !styledRanges.isEmpty { clear() }
            if enabled, let parsedResult { install(parsedResult) }
        }
        guard enabled || outlineVisible else {
            cancel()
            return
        }
        if let parsedResult {
            if outlineVisible && (!document.isMarkdownOutlineCurrent || document.markdownHeadings != parsedResult.headings) {
                publishOutline(parsedResult, revision: revision)
            }
        } else if activated || (work == nil && operation == nil) {
            schedule(revision: revision)
        }
    }

    private func publishOutline(_ result: MarkdownPresentation, revision: UInt) {
        guard let document else { return }
        let generation = self.generation
        DispatchQueue.main.async { [weak self, weak document] in
            guard let self, let document, self.document === document, self.isActive,
                  self.outlineVisible, self.generation == generation, self.currentRevision?() == revision,
                  self.parsedResult != nil,
                  !document.isMarkdownOutlineCurrent || document.markdownHeadings != result.headings else { return }
            document.markdownHeadings = result.headings
            document.isMarkdownOutlineCurrent = true
        }
    }

    func beforeEdit(range: NSRange, replacementLength: Int) {
        guard enabled || outlineVisible || presentation != nil || parsedResult != nil else { return }
        if document?.isMarkdownOutlineCurrent == true { document?.isMarkdownOutlineCurrent = false }
        parsedResult = nil
        cancel()
        if isActive && textView?.hasMarkedText() != true {
            if presentation != nil || !styledRanges.isEmpty {
                if let visible = visibleRange() { restoreStyles(in: visible) }
                invalidatePresentation(in: visibleRange())
            }
        } else if textView?.hasMarkedText() == true {
            needsCompositionRefresh = true
        } else {
            needsRefresh = true
        }
        func shifted(_ ranges: [NSRange]) -> [NSRange] {
            let oldEnd = NSMaxRange(range)
            let change = replacementLength - range.length
            return ranges.compactMap { current in
                let start = current.location <= range.location ? current.location
                    : (current.location >= oldEnd ? current.location + change : range.location)
                let end = NSMaxRange(current) <= range.location ? NSMaxRange(current)
                    : (NSMaxRange(current) >= oldEnd ? NSMaxRange(current) + change : range.location + replacementLength)
                return end > start ? NSRange(location: start, length: end - start) : nil
            }
        }
        styledRanges = shifted(styledRanges)
        backgroundRanges = shifted(backgroundRanges)
        lastVisibleRange = nil
    }

    func edited(revision: UInt) {
        guard enabled || outlineVisible || presentation != nil || parsedResult != nil else { return }
        if document?.isMarkdownOutlineCurrent == true { document?.isMarkdownOutlineCurrent = false }
        parsedResult = nil
        self.revision = revision
        cancel()
        guard textView?.hasMarkedText() != true else { return }
        guard isActive else { needsRefresh = true; return }
        invalidatePresentation(in: visibleRange())
        if enabled || outlineVisible { schedule(revision: revision) }
    }

    func compositionFinished(revision: UInt) {
        guard enabled || outlineVisible || presentation != nil || needsCompositionRefresh else { return }
        self.revision = revision
        guard textView?.hasMarkedText() != true else { return }
        needsCompositionRefresh = false
        guard isActive else { needsRefresh = true; return }
        if needsRefresh {
            needsRefresh = false
            clear()
            if enabled || outlineVisible { schedule(revision: revision) }
        } else if enabled || outlineVisible {
            invalidatePresentation(in: visibleRange())
            schedule(revision: revision)
        } else {
            clear()
        }
    }

    func selectionChanged() {
        guard isActive, enabled, textView?.hasMarkedText() != true, presentation != nil else { return }
        let range = revealedRange()
        guard range != lastRevealedRange else { return }
        lastRevealedRange = range
        layout?.updateMarkdownRevealedRange(range)
        geometryDidChange?()
    }

    func viewportChanged() {
        guard isActive, enabled, textView?.hasMarkedText() != true else { return }
        if presentation != nil {
            applyVisible()
        } else if let visible = visibleRange(), visible != lastVisibleRange {
            lastVisibleRange = visible
            restoreStyles(in: visible)
            layout?.invalidateMarkdownLayout(in: visible)
            geometryDidChange?()
        }
    }

    func restoreBackground(in ranges: [NSRange]) {
        guard isActive, enabled, presentation != nil, textView?.hasMarkedText() != true, let layout else { return }
        for range in ranges {
            for background in backgroundRanges {
                let part = NSIntersectionRange(background, range)
                if part.length > 0 {
                    layout.addTemporaryAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12), forCharacterRange: part)
                }
            }
        }
    }

    func metricsChanged() {
        guard isActive, textView?.hasMarkedText() != true else { return }
        lastVisibleRange = nil
        if enabled, presentation != nil { applyVisible() }
    }

    func cancel() {
        work?.cancel()
        work = nil
        operation?.cancel()
        operation = nil
        generation &+= 1
        document?.taskCoordinator.cancel(.markdownPresentation)
    }

    private func schedule(revision: UInt) {
        let generation = self.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, (self.enabled || self.outlineVisible), self.isActive, self.generation == generation,
                  let document = self.document, let textView = self.textView,
                  !textView.hasMarkedText(), self.currentRevision?() == revision else { return }
            self.work = nil
            let text = textView.string
            let taskGeneration = document.taskCoordinator.begin(.markdownPresentation)
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation, weak document] in
                guard let operation, !operation.isCancelled, let document else { return }
                let result = MarkdownPresentationParser.parse(text)
                guard !operation.isCancelled else { return }
                DispatchQueue.main.async { [weak self, weak document] in
                    guard let self, let document, self.document === document, (self.enabled || self.outlineVisible), self.isActive,
                          self.generation == generation, self.currentRevision?() == revision,
                          document.taskCoordinator.isCurrent(taskGeneration, for: .markdownPresentation),
                          self.textView?.hasMarkedText() != true else { return }
                    document.taskCoordinator.finish(.markdownPresentation, generation: taskGeneration)
                    self.operation = nil
                    self.parsedResult = result
                    if self.outlineVisible { self.publishOutline(result, revision: revision) }
                    if self.enabled { self.install(result) }
                }
            }
            self.operation = operation
            document.taskCoordinator.attach(operation, kind: .markdownPresentation, generation: taskGeneration)
            self.queue.addOperation(operation)
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func install(_ result: MarkdownPresentation) {
        lastVisibleRange = nil
        presentation = result
        spans = result.spans.sorted { $0.range.location < $1.range.location }
        var end = 0
        prefixEnds = spans.map { end = max(end, NSMaxRange($0.range)); return end }
        lastRevealedRange = revealedRange()
        layout?.setMarkdownPresentation(result, revealedRange: lastRevealedRange, invalidating: visibleRange() ?? NSRange(location: 0, length: 0))
        if visibleRange() == nil { geometryDidChange?() }
        applyVisible()
    }

    private func clear() {
        let hadGeometry = presentation != nil || !styledRanges.isEmpty
        restoreStyles()
        if let textView, let layout {
            var typing = textView.typingAttributes
            typing[.font] = layout.textFont
            textView.typingAttributes = typing
        }
        presentation = nil
        spans = []
        prefixEnds = []
        lastVisibleRange = nil
        lastRevealedRange = nil
        layout?.setMarkdownPresentation(nil, revealedRange: nil)
        if hadGeometry { geometryDidChange?() }
    }

    private func invalidatePresentation(in range: NSRange?) {
        guard presentation != nil else { return }
        presentation = nil
        spans = []
        prefixEnds = []
        lastVisibleRange = nil
        lastRevealedRange = nil
        layout?.setMarkdownPresentation(nil, revealedRange: nil, invalidating: range ?? NSRange(location: 0, length: 0))
        geometryDidChange?()
    }

    private func revealedRange() -> NSRange? {
        guard let textView, let text = textView.textStorage?.string as NSString? else { return nil }
        let selection = textView.selectedRange()
        guard selection.location <= text.length else { return nil }
        let length = min(selection.length, text.length - selection.location)
        return text.lineRange(for: NSRange(location: selection.location, length: length))
    }

    private func intersecting(_ range: NSRange) -> [MarkdownPresentationSpan] {
        var low = 0
        var high = prefixEnds.count
        while low < high {
            let middle = (low + high) / 2
            if prefixEnds[middle] <= range.location { low = middle + 1 } else { high = middle }
        }
        var result: [MarkdownPresentationSpan] = []
        while low < spans.count && spans[low].range.location < NSMaxRange(range) {
            if NSIntersectionRange(spans[low].range, range).length > 0 { result.append(spans[low]) }
            low += 1
        }
        return result
    }

    private func visibleRange() -> NSRange? {
        guard let textView, let storage = textView.textStorage, let layout,
              let container = textView.textContainer, storage.length > 0 else { return nil }
        let rect = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard range.location < storage.length else { return nil }
        let visible = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
        return visible.length > 0 ? visible : nil
    }

    private func applyVisible() {
        guard let textView, let storage = textView.textStorage, let layout,
              let visible = visibleRange(), visible != lastVisibleRange else { return }
        lastVisibleRange = visible
        restoreStyles(in: visible)
        let matches = intersecting(visible)
        var boundaries = [visible.location, NSMaxRange(visible)]
        var events: [(location: Int, index: Int, start: Bool)] = []
        for (index, span) in matches.enumerated() {
            let part = NSIntersectionRange(span.range, visible)
            boundaries.append(part.location)
            boundaries.append(NSMaxRange(part))
            events.append((part.location, index, true))
            events.append((NSMaxRange(part), index, false))
        }
        boundaries = Array(Set(boundaries)).sorted()
        events.sort { $0.location < $1.location }
        var activeIndices = Set<Int>()
        var eventIndex = 0
        let typing = textView.typingAttributes
        storage.beginEditing()
        if boundaries.count > 1 {
            for index in 0..<(boundaries.count - 1) {
                let part = NSRange(location: boundaries[index], length: boundaries[index + 1] - boundaries[index])
                while eventIndex < events.count && events[eventIndex].location == part.location {
                    let event = events[eventIndex]
                    if event.start { activeIndices.insert(event.index) }
                    else { activeIndices.remove(event.index) }
                    eventIndex += 1
                }
                guard !activeIndices.isEmpty else { continue }
                let active = activeIndices.map { matches[$0] }
                var font = layout.textFont
                if let heading = active.compactMap({ span -> Int? in
                    if case .heading(let level) = span.kind { return level }; return nil
                }).first { font = layout.markdownHeadingFont(level: heading) }
                let manager = NSFontManager.shared
                if active.contains(where: { $0.kind == .strong }) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                if active.contains(where: { $0.kind == .emphasis || $0.kind == .quote }) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
                if active.contains(where: { $0.kind == .code || $0.kind == .codeBlock }) {
                    font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                }
                storage.addAttribute(.font, value: font, range: part)
                if active.contains(where: { $0.kind == .strikethrough }) {
                    layout.addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: part)
                }
                if active.contains(where: { $0.kind == .link }) {
                    layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: part)
                }
                if active.contains(where: { $0.kind == .quote || $0.kind == .code || $0.kind == .codeBlock }) {
                    layout.addTemporaryAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.12), forCharacterRange: part)
                    backgroundRanges.append(part)
                }
            }
        }
        storage.endEditing()
        textView.typingAttributes = typing
        var merged = visible
        styledRanges = styledRanges.filter { range in
            if NSMaxRange(range) < merged.location || NSMaxRange(merged) < range.location { return true }
            let start = min(range.location, merged.location)
            merged = NSRange(location: start, length: max(NSMaxRange(range), NSMaxRange(merged)) - start)
            return false
        }
        styledRanges.append(merged)
        layout.invalidateMarkdownLayout(in: visible)
        restoreDelimiterHighlight?()
        geometryDidChange?()
    }

    private func restoreStyles(in requested: NSRange? = nil) {
        guard let textView, let storage = textView.textStorage, let layout else { return }
        let typing = textView.typingAttributes
        let whole = NSRange(location: 0, length: storage.length)
        let target = requested.map { NSIntersectionRange($0, whole) } ?? whole
        storage.beginEditing()
        for range in styledRanges {
            let safe = NSIntersectionRange(range, target)
            guard safe.length > 0 else { continue }
            storage.addAttribute(.font, value: layout.textFont, range: safe)
            layout.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: safe)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: safe)
        }
        for range in backgroundRanges {
            let safe = NSIntersectionRange(range, target)
            if safe.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe) }
        }
        storage.endEditing()
        textView.typingAttributes = typing
        if requested == nil {
            styledRanges.removeAll()
            backgroundRanges.removeAll()
        } else {
            backgroundRanges = backgroundRanges.flatMap { range -> [NSRange] in
                let overlap = NSIntersectionRange(range, target)
                guard overlap.length > 0 else { return [range] }
                var remaining: [NSRange] = []
                if range.location < overlap.location {
                    remaining.append(NSRange(location: range.location, length: overlap.location - range.location))
                }
                if NSMaxRange(overlap) < NSMaxRange(range) {
                    remaining.append(NSRange(location: NSMaxRange(overlap), length: NSMaxRange(range) - NSMaxRange(overlap)))
                }
                return remaining
            }
        }
        restoreDelimiterHighlight?()
    }
}
