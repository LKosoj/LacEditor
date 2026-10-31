import AppKit
import AVKit
import ImageIO
import os
import WebKit

private let markdownEditorPerformanceLog = OSLog(subsystem: "com.laceditor.LacEditor", category: "MarkdownEditorPerformance")

private final class MarkdownAnimatedImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class MarkdownDetailsButton: NSButton {
    var revealSource: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { revealSource?(); return }
        super.mouseDown(with: event)
    }
}

private final class MarkdownDetailsView: NSView {
    let disclosure = MarkdownDetailsButton()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let richSummary = MarkdownHTMLBlockView(frame: .zero)
    private let richBody = MarkdownHTMLBlockView(frame: .zero)
    private let block: MarkdownDetailsBlock
    var onToggle: ((Bool) -> Bool)?
    var revealSource: (() -> Void)?
    var openLink: ((String) -> Void)?
    var canInteract: (() -> Bool)?
    private var confirmedOpen = false
    /// Всё, от чего зависит показ, и итоговый размер: при тех же входных данных разбор HTML и перекладка не повторяются.
    private var configured: (width: CGFloat, font: NSFont, foreground: NSColor, linkColor: NSColor,
                             codeFont: NSFont?, paragraphStyle: NSParagraphStyle?, open: Bool, size: NSSize)?
    override var isFlipped: Bool { true }

    init(block: MarkdownDetailsBlock) {
        self.block = block
        super.init(frame: .zero)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.target = self
        disclosure.action = #selector(toggle(_:))
        disclosure.setAccessibilityLabel(block.summary)
        disclosure.revealSource = { [weak self] in self?.revealSource?() }
        summary.stringValue = block.summary
        body.stringValue = block.body
        addSubview(disclosure); addSubview(summary); addSubview(body)
        addSubview(richSummary); addSubview(richBody)
        for view in [richSummary, richBody] {
            view.canInteract = { [weak self] in self?.canInteract?() ?? false }
            view.revealSource = { [weak self] in self?.revealSource?() }
            view.openLink = { [weak self] address in self?.openLink?(address) }
        }
        richSummary.click = { [weak self] in self?.disclosure.performClick(nil) }
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func toggle(_ sender: NSButton) {
        let open = sender.state == .on
        if onToggle?(open) == true { confirmedOpen = open }
        else { sender.state = confirmedOpen ? .on : .off }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === summary || hit === body ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command), summary.frame.contains(convert(event.locationInWindow, from: nil)) {
            disclosure.performClick(nil)
        } else { revealSource?() }
    }

    func configure(width: CGFloat, font: NSFont, foreground: NSColor, linkColor: NSColor,
                   codeFont: NSFont?, paragraphStyle: NSParagraphStyle?, open: Bool) -> NSSize? {
        // Содержимое блока в виде не меняется (`block` постоянный), поэтому сравниваются только остальные входные данные.
        if let last = configured, last.width == width, last.font == font, last.foreground == foreground, last.linkColor == linkColor,
           last.codeFont == codeFont, last.paragraphStyle == paragraphStyle, last.open == open { return last.size }
        configured = nil
        let inset: CGFloat = 22
        let textWidth = max(1, width - inset)
        let rich = block.summaryHTML != nil && block.bodyHTML != nil
        if let summaryHTML = block.summaryHTML, let bodyHTML = block.bodyHTML {
            guard richSummary.configure(confirmedHTML: summaryHTML, font: font, foreground: foreground, linkColor: linkColor,
                                        codeFont: codeFont, paragraphStyle: paragraphStyle),
                  richBody.configure(confirmedHTML: bodyHTML, font: font, foreground: foreground, linkColor: linkColor,
                                     codeFont: codeFont, paragraphStyle: paragraphStyle) else { return nil }
        }
        if !rich {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            if let paragraphStyle { attributes[.paragraphStyle] = paragraphStyle }
            summary.attributedStringValue = NSAttributedString(string: block.summary, attributes: attributes)
            body.attributedStringValue = NSAttributedString(string: block.body, attributes: attributes)
        }
        func height(_ field: NSTextField) -> CGFloat {
            ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height ?? font.pointSize)
        }
        let summaryHeight = max(18, rich ? (richSummary.measuredSize(width: textWidth)?.height ?? 0) : height(summary))
        let bodyHeight = open ? (rich ? (richBody.measuredSize(width: textWidth)?.height ?? 0) : height(body)) : 0
        disclosure.state = open ? .on : .off
        confirmedOpen = open
        disclosure.setAccessibilityExpanded(open)
        disclosure.frame = NSRect(x: 0, y: 0, width: inset, height: summaryHeight)
        summary.frame = NSRect(x: inset, y: 0, width: textWidth, height: summaryHeight)
        body.frame = NSRect(x: inset, y: summaryHeight, width: textWidth, height: bodyHeight)
        richSummary.frame = summary.frame; richBody.frame = body.frame
        summary.isHidden = rich; body.isHidden = rich || !open
        richSummary.isHidden = !rich; richBody.isHidden = !rich || !open
        let size = NSSize(width: width, height: summaryHeight + bodyHeight)
        configured = (width, font, foreground, linkColor, codeFont, paragraphStyle, open, size)
        return size
    }
}

private final class MarkdownIframeNavigation: NSObject, WKNavigationDelegate {
    let isCurrent: () -> Bool
    private var initialNavigation = true

    init(isCurrent: @escaping () -> Bool) { self.isCurrent = isCurrent }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard isCurrent(), let frame = navigationAction.targetFrame,
              let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if frame.isMainFrame {
            let allowed = initialNavigation && url.absoluteString == "about:blank"
            initialNavigation = false
            decisionHandler(allowed ? .allow : .cancel)
        } else {
            decisionHandler(["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel)
        }
    }
}

private func markdownPresentationImageData(_ address: String, baseURL: URL?, paths: MarkdownResourcePaths?, rootInvalid: Bool) -> Data? {
    if address.hasPrefix("data:") {
        guard let comma = address.firstIndex(of: ",") else { return nil }
        let metadata = address[address.index(address.startIndex, offsetBy: 5)..<comma]
        let value = String(address[address.index(after: comma)...])
        if metadata.lowercased().hasSuffix(";base64") { return Data(base64Encoded: value) }
        let bytes = Array(value.utf8)
        var decoded = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count,
                      let byte = UInt8(String(decoding: bytes[index + 1...index + 2], as: UTF8.self), radix: 16) else { return nil }
                decoded.append(byte)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }
    let url: URL?
    if address.hasPrefix("/") {
        guard !MarkdownResourcePaths.requiresRoot(address) || !rootInvalid else { return nil }
        url = paths?.resolve(address) ?? URL(string: address, relativeTo: URL(fileURLWithPath: "/", isDirectory: true))?.absoluteURL
    } else {
        url = URL(string: address, relativeTo: baseURL?.deletingLastPathComponent())?.absoluteURL
    }
    guard let url, url.isFileURL else { return nil }
    return try? Data(contentsOf: url)
}

/// Keeps the source text unchanged while applying formatting to visible text.
@MainActor
final class MarkdownPresentationController {
    /// Стабильная идентичность медиа не зависит от его текущего положения в исходнике.
    /// Диапазон хранится отдельно как placement и меняется при редактировании.
    private struct ImageCacheKey: Hashable {
        let source: String
        let sizing: String?
        let isInline: Bool
    }

    private struct DiagramCacheKey: Hashable {
        let kind: String
        let source: String
        let width: CGFloat
        let dark: Bool
    }

    private struct CachedImage {
        let image: NSImage
        let animated: NSImage?
        let intrinsic: CGSize?
        let width: CGFloat?
    }

    private struct CachedDiagram {
        let image: NSImage
        let svg: Data?
    }

    private weak var textView: LacTextView?
    private weak var layout: FoldLayoutManager?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private(set) var work: DispatchWorkItem?
    private var operation: BlockOperation?
    private var imageOperations: [NSRange: BlockOperation] = [:]
    private var remoteImageJobs: [NSRange: (UUID, Task<Void, Never>)] = [:]
    private var svgImageJobs: [NSRange: (UUID, CGFloat, MarkdownSVGRenderService)] = [:]
    private var imagePresentationWidths: [NSRange: CGFloat] = [:]
    private var imageCache: [ImageCacheKey: CachedImage] = [:]
    private var animatedImages: [NSRange: NSImageView] = [:]
    private var editingTableCell: NSRange?
    var imageSession = URLSession.shared
    var projectedImageSource: ((String) -> String?)?
    var imageLoadDidComplete: ((NSRange, Bool) -> Void)?
    var audioLoadDidComplete: ((NSRange, Bool) -> Void)?
    var audioJobDidFinish: ((NSRange) -> Void)?
    var audioAssetIsPlayable: @MainActor (AVURLAsset) async -> Bool = { (try? await $0.load(.isPlayable)) == true }
    private var codeJobs: [NSRange: (UUID, BlockOperation)] = [:]
    /// Позиции токенов и `prefixEnds` отсчитываются от начала тела блока (`bodyRange.location`): сдвиг блока их не трогает.
    private struct CodeResult {
        let tokens: [SyntaxHighlighter.Token]
        let prefixEnds: [Int]
    }
    private var codeResults: [NSRange: CodeResult] = [:]
    private var codeFailed: Set<NSRange> = []
    private var codeColoredRanges: Set<NSRange> = []
    var codeHighlighter: ([MarkdownCodeHighlightService.Segment], String, String, NSRange, BlockOperation) -> [SyntaxHighlighter.Token]? = {
        segments, literal, info, visible, operation in
        MarkdownCodeHighlightService.tokens(segments: segments, literal: literal,
                                            info: info, visible: visible, isCancelled: { operation.isCancelled })
    }
    var codeHighlightDidComplete: ((NSRange) -> Void)?
    private var loadedImageRanges: Set<NSRange> = []
    private var imageBaseURL: URL?
    private var resourcePaths: MarkdownResourcePaths?
    private var resourceRootInvalid = false
    @MainActor
    private enum DiagramJob {
        case mermaid(MermaidRenderService)
        case legacy(LegacyDiagramRenderService)
        func cancel() {
            switch self { case let .mermaid(service): service.cancel(); case let .legacy(service): service.cancel() }
        }
        func start() {
            switch self { case let .mermaid(service): service.start(); case let .legacy(service): service.start() }
        }
        var svg: Data? {
            switch self { case let .mermaid(service): return service.renderedSVG; case let .legacy(service): return service.renderedSVG }
        }
    }
    /// Идентичность задания не зависит от текущего диапазона в исходнике.
    /// Диапазон остаётся ключом словаря только как быстрый placement; при
    /// сдвиге текста он переносится, а callback ищет его по token.
    private struct DiagramJobIdentity: Equatable {
        let kind: String
        let source: String
    }
    private struct DiagramJobEntry {
        let token: UUID
        let identity: DiagramJobIdentity
        var revision: UInt
        let job: DiagramJob
    }
    private var diagramJobs: [NSRange: DiagramJobEntry] = [:]
    private var diagramResources: [NSRange: (image: NSImage, svg: Data?)] = [:]
    private var diagramCache: [DiagramCacheKey: CachedDiagram] = [:]
    struct DiagramResource {
        let range: NSRange
        let image: NSImage
        let svg: Data?
        let document: EditorDocument
        let revision: UInt
        let generation: UInt
        let selection: [NSValue]
    }
    struct ImageResource {
        let image: MarkdownImage
        let document: EditorDocument
        let revision: UInt
        let generation: UInt
    }
    private var diagramCompleted: Set<NSRange> = []
    var emojiResolver: ([String], BlockOperation) -> [String: String]? = { names, operation in
        try? EmojiShortcodeResolver.resolve(names, isCancelled: { operation.isCancelled })
    }
    var emojiResolutionDidComplete: (() -> Void)?
    private var emojiOperation: BlockOperation?
    private var emojiValues: [String: String]?
    private var uppercaseEmojiResolutionFailed = false
    private var emojiRanges: Set<NSRange> = []
    private var emojiFonts: [NSRange: NSFont] = [:]
    private var formulaJob: (token: UUID, service: MathJaxRenderService, busy: Bool, formulas: [(MarkdownFormula, Bool)])?
    private var formulaCompleted: Set<NSRange> = []
    private var sourceMathReferences: [NSRange: [(NSRange, NSRange)]] = [:]
    private var formulaFontSize: CGFloat?
    private var mathOptions = MathJaxRenderService.Options()
    private var syntaxOptions = MarkdownSyntaxOptions()
    private var pendingSyntaxOptions: MarkdownSyntaxOptions?
    private var mathOptionsNeedRefresh = false
    private struct IframeView {
        var block: MarkdownIframeBlock
        let view: WKWebView
        let navigation: MarkdownIframeNavigation
        var height: CGFloat
    }
    private var iframeViews: [NSRange: IframeView] = [:]
    private struct HTMLBlockView {
        var block: MarkdownHTMLBlock
        let view: MarkdownHTMLBlockView
        let font: NSFont
        let codeFont: NSFont?
        let paragraphStyle: NSParagraphStyle?
        let foreground: NSColor
        let linkColor: NSColor
        let vertical: Bool
    }
    private var htmlBlockViews: [NSRange: HTMLBlockView] = [:]
    var htmlBlockLink: ((String, NSRange) -> Void)?
    private var detailsViews: [NSRange: MarkdownDetailsView] = [:]
    private struct RubyKey: Equatable {
        var item: MarkdownRuby
        let font: NSFont
        let color: NSColor
        let parentFont: NSFont
        let parentColor: NSColor
        let scale: CGFloat
        let vertical: Bool
        let available: NSSize
    }
    private var rubyJobs: [NSRange: (UUID, RubyKey, Task<Void, Never>)] = [:]
    private var rubyRendered: [NSRange: RubyKey] = [:]
    private var expandedDetails: [NSRange: Bool] = [:]
    var detailsOpenOverrides: [NSRange: Bool] { expandedDetails }
    private var audioJobs: [NSRange: (UUID, Task<Void, Never>)] = [:]
    private var audioViews: [NSRange: AVPlayerView] = [:]
    private var audioCompleted: Set<NSRange> = []
    private var diagramGeometry: (CGFloat, Bool)?
    private var footnoteTooltips: [(tag: NSView.ToolTipTag, rect: NSRect, owner: NSString)] = []
    var footnoteTooltipRects: [NSRect] { footnoteTooltips.map(\.rect) }
    private var lastFootnote: MarkdownFootnote?
    private var presentation: MarkdownPresentation?
    private var parsedResult: MarkdownPresentation?
    private var parsedResultToken = UUID()
    private struct FenceContainerOpening {
        var line: NSRange
        let sourcePrefix: String
        let continuationPrefix: String
    }
    private struct FenceContext {
        let openings: [FenceContainerOpening]
        let blocked: [NSRange]
        let blockedEOF: Bool
        let sourceLength: Int
        var revision: UInt
        var line: NSRange?
        var opening: FenceContainerOpening?
        var lineAllowed = false
    }
    private var fenceContext: FenceContext?
    private struct EmojiCompletionContext {
        let ranges: [NSRange]
        let sourceLength: Int
        var revision: UInt
        var prefix: NSRange?
    }
    private var emojiCompletionContext: EmojiCompletionContext?
    private var emojiCompletionRequested = false
    private var wikiCompletionRequested = false
    var wikiResolver: MarkdownWikiLinkResolver?
    var wikiCatalogNeeded: (() -> Void)?
    var wikiCompletionReady: (() -> Void)?
    private struct SmartTextContext {
        let ranges: [NSRange]
        let rawHTMLRanges: [NSRange]?
        var revision: UInt
        var active: NSRange?
    }
    private var smartTextContext: SmartTextContext?
    private var mathPairContext: SmartTextContext?
    private var mathPairRequested = false
    private var elementPathRequested = false
    private var parsedRevision: UInt?
    private var parsedSource: String?
    private var outlineVisible = false
    private var spans: [MarkdownPresentationSpan] { presentation?.spans ?? [] }
    private var prefixEnds: [Int] { presentation?.spanEnds ?? [] }
    private var completedTaskPrefixEnds: [Int] { presentation?.completedEnds ?? [] }
    private var strikeCompletedTasks = false
    private var headingNumbering = false
    private var uppercaseHeadingLevels: Set<Int> = []
    private var uppercaseSnapshotReady = false
    private var uppercaseHeadings: [Int: MarkdownHeading] = [:]
    private var uppercaseInstalled: Set<NSRange> = []
    private var styledRanges: [NSRange] = []
    private struct ParagraphStyleOrigin: Hashable {
        let alignment: Int?
        let direction: Int?
        let firstLineIndent: CGFloat?
        let headIndent: CGFloat?
    }
    private var alignedRanges: [ParagraphStyleOrigin: IndexSet] = [:]
    private var backgroundRanges: [NSRange] = []
    private var inlineForegroundRanges: [NSRange] = []
    private var lastVisibleRange: NSRange?
    /// Ревизия, итоговая длина текста и вставка правки, под которую `beforeEdit` сдвинул оформление; `edited` забирает её один раз.
    private var keptEdit: (revision: UInt, length: Int, inserted: NSRange)?
    /// На экране сдвинутое оформление предыдущего разбора: при установке нового разбора стили видимой области снимаются.
    private var presentationKept = false
    // При полном переразборе не убираем готовые медиа до появления нового результата.
    // Это предотвращает превращение неизменившихся картинок и диаграмм в исходный текст во время ввода.
    private var deferredReadyClear = false
    private var mediaPlacementPending = false
    private var lastRevealedRange: NSRange?
    var emojiCompletionReady: (() -> Void)?
    var parsedResultDidChange: (() -> Void)?
    var geometryDidChange: (() -> Void)?
    var restoreDelimiterHighlight: (() -> Void)?
    var restoreCodeColors: (([NSRange]) -> Void)?
    private var enabled = false
    private var isActive = false
    private var needsRefresh = false
    private var needsCompositionRefresh = false
    private var generation: UInt = 0
    private var document: EditorDocument?
    private var appliedReadingMode = false
    private var revision: UInt = 0
    private var currentRevision: (() -> UInt)?
    private var readableEnabled: Bool { document?.language == .markdown && document?.isWordCountEnabled == true }
    private var emojiCompletionEnabled: Bool { document?.language == .markdown && (emojiCompletionRequested || wikiCompletionRequested) }
    private var mathPairEnabled: Bool { document?.language == .markdown && mathPairRequested }
    private var elementPathEnabled: Bool { document?.language == .markdown && elementPathRequested }

    func setMathPairContextEnabled(_ enabled: Bool) {
        guard mathPairRequested != enabled else { return }
        mathPairRequested = enabled
        if !enabled {
            mathPairContext = nil
            if !self.enabled && !outlineVisible && !readableEnabled && !emojiCompletionEnabled && !elementPathEnabled { cancel() }
        }
        else if isActive, document?.language == .markdown, !hasMarkedText, mathPairContext == nil, work == nil, operation == nil {
            schedule(revision: revision)
        }
    }

    /// Путь элементов под курсором для строки состояния; включает общий разбор, даже если ему больше ничего не нужно.
    func setElementPathEnabled(_ enabled: Bool) {
        guard elementPathRequested != enabled else { return }
        elementPathRequested = enabled
        guard !enabled else { return }
        clearElementPath()
        if !self.enabled && !outlineVisible && !readableEnabled && !emojiCompletionEnabled && !mathPairEnabled { cancel() }
    }

    /// Снимает показанный путь на следующем проходе главного потока: вызывается и из обновления SwiftUI.
    private func clearElementPath() {
        guard let document, document.markdownElementPath != nil else { return }
        DispatchQueue.main.async { [weak document] in document?.setMarkdownElementPath(nil) }
    }

    /// Показанный путь не стирается при наборе: он обновляется, когда готов новый разбор. Стирается при непустом выделении.
    private func refreshElementPath() {
        guard elementPathEnabled, isActive, let document, let textView else { return }
        if editingTableCell == nil {
            let ranges = textView.selectedRanges
            guard ranges.count == 1, ranges[0].rangeValue.length == 0 else { document.setMarkdownElementPath(nil); return }
        }
        guard !hasMarkedText, let parsedResult, parsedRevision == revision, currentRevision?() == revision,
              let storage = textView.textStorage, parsedResult.elements.textLength == storage.length else { return }
        if let cell = editingTableCell {
            document.setMarkdownElementPath(parsedResult.elements.path(at: cell.location, blocksOnly: true))
        } else {
            document.setMarkdownElementPath(parsedResult.elements.path(at: textView.selectedRange().location))
        }
    }

    init(textView: LacTextView, layout: FoldLayoutManager) {
        self.textView = textView
        self.layout = layout
    }

    func setSyntaxOptions(_ options: MarkdownSyntaxOptions) {
        if hasMarkedText {
            pendingSyntaxOptions = options
            return
        }
        pendingSyntaxOptions = nil
        guard syntaxOptions != options else { return }
        syntaxOptions = options
        document?.invalidateMarkdownReadableText()
        document?.isMarkdownOutlineCurrent = false
        clearElementPath()
        parsedResult = nil
        parsedSource = nil
        fenceContext = nil
        smartTextContext = nil
        mathPairContext = nil
        emojiCompletionContext = nil
        cancel()
        needsRefresh = true
        if isActive, let document, let currentRevision {
            update(document: document, enabled: enabled, outlineVisible: outlineVisible, isActive: isActive, revision: revision, currentRevision: currentRevision)
        }
    }

    func update(document: EditorDocument, enabled: Bool, outlineVisible: Bool = false, isActive: Bool, revision: UInt, currentRevision: @escaping () -> UInt) {
        let documentChanged = self.document !== document
        if documentChanged || self.revision != revision { expandedDetails.removeAll() }
        let imageBaseChanged = imageBaseURL != document.url
        if imageBaseChanged {
            cancel()
            parsedResult = nil
            parsedSource = nil
            clearAudio()
            for operation in imageOperations.values { operation.cancel() }
            imageOperations.removeAll()
            for (_, task) in remoteImageJobs.values { task.cancel() }
            remoteImageJobs.removeAll()
            loadedImageRanges.removeAll()
            imageCache.removeAll()
            diagramCache.removeAll()
            if !hasMarkedText { layout?.clearMarkdownImages() }
            lastVisibleRange = nil
        }
        imageBaseURL = document.url
        let formatChanged = self.enabled != enabled
        if formatChanged { cancel(); clearElementPath() }
        let activated = !self.isActive && isActive
        if self.isActive && !isActive && textView?.hasMarkedText() == true { needsRefresh = true }
        if documentChanged { self.document?.invalidateMarkdownReadableText() }
        if documentChanged || (self.isActive && !isActive) {
            cancel()
            emojiCompletionContext = nil
            emojiCompletionRequested = false
            wikiCompletionRequested = false
            smartTextContext = nil
            mathPairContext = nil
        }
        if documentChanged {
            clearElementPath()
            parsedResult = nil; parsedSource = nil; fenceContext = nil
        }
        self.document = document
        self.enabled = enabled
        self.outlineVisible = outlineVisible
        self.isActive = isActive
        self.currentRevision = currentRevision
        self.revision = revision
        if documentChanged { clearElementPath() }
        if elementPathEnabled, parsedResult != nil, parsedRevision != revision {
            // Текст заменён снаружи без правки через редактор: прежний разбор и показанный путь устарели.
            clearElementPath()
            parsedResult = nil
            parsedSource = nil
            cancel()
        }
        if !document.isSyntaxHighlightingEnabled { cancelCodeHighlighting() }
        if documentChanged || formatChanged || imageBaseChanged { needsRefresh = true }
        guard isActive else { return }
        guard !hasMarkedText else {
            if needsRefresh { needsCompositionRefresh = true }
            return
        }
        if needsRefresh {
            needsRefresh = false
            if presentation != nil || !styledRanges.isEmpty { clear() }
            if enabled, let parsedResult { install(parsedResult) }
        }
        if appliedReadingMode != document.isReadingMode {
            appliedReadingMode = document.isReadingMode
            if enabled && presentation != nil { selectionChanged() }
        }
        guard enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || mathPairEnabled || elementPathEnabled else {
            cancel()
            return
        }
        if activated && enabled && presentation != nil { applyVisible() }
        if let parsedResult {
            if outlineVisible && (!document.isMarkdownOutlineCurrent || document.markdownHeadings != parsedResult.headings) {
                publishOutline(parsedResult, revision: revision)
            }
            publishReadableTextIfNeeded()
            if elementPathEnabled && (activated || documentChanged || formatChanged) {
                DispatchQueue.main.async { [weak self] in self?.refreshElementPath() }
            }
            if ((readableEnabled && parsedResult.readableText == nil) || (enabled && !parsedResult.emojiCandidatesIncluded)) && work == nil && operation == nil {
                schedule(revision: revision)
            }
        } else if (activated || (work == nil && operation == nil)) &&
                    (enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || elementPathEnabled || mathPairContext?.revision != revision) {
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

    private func publishReadableTextIfNeeded() {
        guard isActive, readableEnabled, !hasMarkedText, currentRevision?() == revision,
              let document, !document.hasCurrentMarkdownReadableText, let parsedResult,
              (parsedResult.emojiCandidates.isEmpty || emojiValues != nil),
              let readable = parsedResult.readableText, let source = parsedSource else { return }
        document.installMarkdownReadableText(readable, source: source)
    }

    private func fenceLineBlocked(_ location: Int, in context: FenceContext) -> Bool {
        if location == context.sourceLength && context.blockedEOF { return true }
        var low = 0, high = context.blocked.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(context.blocked[middle]) <= location { low = middle + 1 } else { high = middle }
        }
        return low < context.blocked.count && context.blocked[low].location <= location
    }

    func noteFenceContextEdit(range: NSRange, replacement: String, in text: NSString, revision: UInt) {
        noteEmojiCompletionEdit(range: range, replacement: replacement, in: text, revision: revision)
        noteSmartTextEdit(range: range, replacement: replacement, in: text, revision: revision)
        noteMathPairEdit(range: range, replacement: replacement, in: text, revision: revision)
        guard var context = fenceContext, context.revision &+ 1 == revision,
              range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= text.length, range.length <= text.length - range.location else { fenceContext = nil; return }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        var contentEnd = NSMaxRange(line)
        while contentEnd > line.location && [10, 13, 0x85, 0x2028, 0x2029].contains(Int(text.character(at: contentEnd - 1))) { contentEnd -= 1 }
        guard NSMaxRange(range) <= contentEnd,
              !replacement.utf16.contains(where: { [10, 13, 0x85, 0x2028, 0x2029].contains(Int($0)) }) else { fenceContext = nil; return }
        if let previous = context.line {
            guard previous == line else { fenceContext = nil; return }
        } else {
            context.lineAllowed = !fenceLineBlocked(line.location, in: context)
            context.opening = fenceContainerOpening(in: context, lineRange: line)
        }
        if let opening = context.opening,
           range.location < line.location + (opening.sourcePrefix as NSString).length {
            context.opening = nil
        }
        let length = line.length + (replacement as NSString).length - range.length
        guard length >= 0 else { fenceContext = nil; return }
        let updatedLine = NSRange(location: line.location, length: length)
        context.line = updatedLine
        context.opening?.line = updatedLine
        context.revision = revision
        fenceContext = context
    }

    private func smartTextRange(containing range: NSRange, in context: SmartTextContext) -> NSRange? {
        if let active = context.active {
            return range.location >= active.location && NSMaxRange(range) > active.location && NSMaxRange(range) <= NSMaxRange(active) ? active : nil
        }
        var low = 0, high = context.ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(context.ranges[middle]) < range.location || (range.length > 0 && NSMaxRange(context.ranges[middle]) == range.location) { low = middle + 1 } else { high = middle }
        }
        guard low < context.ranges.count else { return nil }
        let candidate = context.ranges[low]
        return range.location >= candidate.location && NSMaxRange(range) > candidate.location && NSMaxRange(range) <= NSMaxRange(candidate) ? candidate : nil
    }

    private func allowsBlankSmartQuote(_ range: NSRange, replacement: String, in text: NSString,
                                       context: SmartTextContext, revision: UInt) -> Bool {
        guard isActive, enabled, range.length == 0, replacement == "\"" || replacement == "'",
              let fence = fenceContext, fence.revision &+ 1 == revision, fence.line == nil,
              let rawRanges = context.rawHTMLRanges, !fenceLineBlocked(range.location, in: fence) else { return false }
        var low = 0, high = rawRanges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(rawRanges[middle]) < range.location { low = middle + 1 } else { high = middle }
        }
        if low < rawRanges.count && rawRanges[low].location <= range.location { return false }
        let line = text.lineRange(for: range)
        var end = NSMaxRange(line)
        while end > line.location && [10, 13, 0x85, 0x2028, 0x2029].contains(Int(text.character(at: end - 1))) { end -= 1 }
        guard range.location == end, end - line.location <= 3 else { return false }
        return (line.location..<end).allSatisfy { text.character(at: $0) == 32 }
    }

    private func noteSmartTextEdit(range: NSRange, replacement: String, in text: NSString, revision: UInt) {
        guard !hasMarkedText, var context = smartTextContext, context.revision &+ 1 == revision,
              range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= text.length, range.length <= text.length - range.location else { smartTextContext = nil; return }
        if allowsBlankSmartQuote(range, replacement: replacement, in: text, context: context, revision: revision) {
            context.active = NSRange(location: range.location, length: 1)
            context.revision = revision
            smartTextContext = context
            return
        }
        guard let active = smartTextRange(containing: range, in: context), range.location > active.location,
              replacement.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ||
                  scalar == " " || scalar == "\t" || "'\"-‘’“”–—".unicodeScalars.contains(scalar)
              }) else { smartTextContext = nil; return }
        context.active = NSRange(location: active.location, length: active.length + (replacement as NSString).length - range.length)
        context.revision = revision
        smartTextContext = context
    }

    func allowsSmartSubstitution(document: EditorDocument, revision: UInt, range: NSRange) -> Bool {
        guard isActive, enabled, document.language == .markdown, self.document === document,
              currentRevision?() == revision, !hasMarkedText,
              range.location != NSNotFound, range.location >= 0, range.length >= 0,
              let context = smartTextContext, context.revision == revision else { return false }
        return smartTextRange(containing: range, in: context) != nil
    }

    private func mathPairTextRange(containing range: NSRange, in context: SmartTextContext) -> NSRange? {
        if let active = context.active {
            return range.location >= active.location && NSMaxRange(range) <= NSMaxRange(active) ? active : nil
        }
        var low = 0, high = context.ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(context.ranges[middle]) < range.location || (range.length > 0 && NSMaxRange(context.ranges[middle]) == range.location) { low = middle + 1 } else { high = middle }
        }
        guard low < context.ranges.count else { return nil }
        let candidate = context.ranges[low]
        return range.location >= candidate.location && NSMaxRange(range) <= NSMaxRange(candidate) ? candidate : nil
    }

    private func noteMathPairEdit(range: NSRange, replacement: String, in text: NSString, revision: UInt) {
        func safe(_ unit: UInt16) -> Bool {
            if [10, 13, 0x85, 0x2028, 0x2029].contains(Int(unit)) { return false }
            return unit > 127 || (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 32 || unit == 9
        }
        guard mathPairEnabled, !hasMarkedText, var context = mathPairContext, context.revision &+ 1 == revision,
              range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= text.length, range.length <= text.length - range.location,
              let active = mathPairTextRange(containing: range, in: context), range.location > active.location,
              replacement.utf16.allSatisfy(safe),
              (range.location..<NSMaxRange(range)).allSatisfy({ safe(text.character(at: $0)) }),
              (range.location == 0 || safe(text.character(at: range.location - 1))),
              (NSMaxRange(range) == text.length || safe(text.character(at: NSMaxRange(range)))) else { mathPairContext = nil; return }
        context.active = NSRange(location: active.location, length: active.length + (replacement as NSString).length - range.length)
        context.revision = revision
        mathPairContext = context
    }

    func allowsMathPair(document: EditorDocument, revision: UInt, range: NSRange) -> Bool {
        guard isActive, mathPairEnabled, self.document === document, currentRevision?() == revision, !hasMarkedText,
              let context = mathPairContext, context.revision == revision, let storage = textView?.textStorage,
              range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= storage.length, range.length <= storage.length - range.location else { return false }
        let source = storage.mutableString
        if range.location > 0 && source.character(at: range.location - 1) == 36 { return false }
        if NSMaxRange(range) < source.length && source.character(at: NSMaxRange(range)) == 36 { return false }
        if mathPairTextRange(containing: range, in: context) != nil { return true }
        guard range.length == 0, context.active == nil, let fence = fenceContext, fence.revision == revision,
              fence.line == nil, let rawRanges = context.rawHTMLRanges, !fenceLineBlocked(range.location, in: fence) else { return false }
        var low = 0, high = rawRanges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(rawRanges[middle]) < range.location { low = middle + 1 } else { high = middle }
        }
        if low < rawRanges.count && rawRanges[low].location <= range.location { return false }
        let text = source, line = text.lineRange(for: range)
        var end = NSMaxRange(line)
        while end > line.location && [10, 13, 0x85, 0x2028, 0x2029].contains(Int(text.character(at: end - 1))) { end -= 1 }
        return range.location == end && end - line.location <= 3 &&
            (line.location..<end).allSatisfy { text.character(at: $0) == 32 }
    }

    private func emojiTextContains(_ range: NSRange, in context: EmojiCompletionContext) -> Bool {
        var low = 0, high = context.ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(context.ranges[middle]) < range.location || (range.length > 0 && NSMaxRange(context.ranges[middle]) == range.location) { low = middle + 1 } else { high = middle }
        }
        guard low < context.ranges.count else { return false }
        let candidate = context.ranges[low]
        return candidate.location <= range.location && NSMaxRange(range) <= NSMaxRange(candidate)
    }

    func beginEmojiCompletion() {
        emojiCompletionRequested = true
    }

    func beginWikiCompletion() {
        wikiCompletionRequested = true
        wikiCatalogNeeded?()
        if !hasMarkedText, parsedResult == nil, work == nil && operation == nil { schedule(revision: revision) }
    }

    func endWikiCompletion() {
        guard wikiCompletionRequested else { return }
        wikiCompletionRequested = false
        if !emojiCompletionRequested { emojiCompletionContext = nil }
        if !enabled && !outlineVisible && !readableEnabled && !mathPairEnabled && !elementPathEnabled && !emojiCompletionRequested { cancel() }
    }

    /// Диапазон от `[[` до курсора должен целиком лежать в подтверждённом тексте текущей версии.
    func allowsWikiCompletion(document: EditorDocument, revision: UInt, range: NSRange) -> Bool {
        guard isActive, document.language == .markdown, self.document === document, currentRevision?() == revision, !hasMarkedText,
              let context = emojiCompletionContext, context.revision == revision, range.length > 0 else { return false }
        // cmark выдаёт скобки отдельными текстовыми узлами: проверяем цепочку соседних фрагментов.
        var low = 0, high = context.ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(context.ranges[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        guard low < context.ranges.count, context.ranges[low].location <= range.location else { return false }
        var covered = NSMaxRange(context.ranges[low])
        low += 1
        while covered < NSMaxRange(range), low < context.ranges.count, context.ranges[low].location == covered {
            covered = NSMaxRange(context.ranges[low])
            low += 1
        }
        return covered >= NSMaxRange(range)
    }

    func requestEmojiCompletionAfterTableEdit() {
        guard isActive, document?.language == .markdown, !hasMarkedText,
              currentRevision?() == revision else { return }
        emojiCompletionRequested = true
        if parsedResult != nil { emojiCompletionReady?() }
        else if work == nil && operation == nil { schedule(revision: revision) }
    }

    func endEmojiCompletion() {
        emojiCompletionRequested = false
        emojiCompletionContext = nil
        if !enabled && !outlineVisible && !readableEnabled && !mathPairEnabled && !elementPathEnabled { cancel() }
    }

    private func noteEmojiCompletionEdit(range: NSRange, replacement: String, in text: NSString, revision: UInt) {
        let nameEdit = replacement.utf16.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 43 || $0 == 45
        }
        if hasMarkedText || (replacement != ":" && !nameEdit) { emojiCompletionRequested = false }
        guard !hasMarkedText, var context = emojiCompletionContext, context.revision &+ 1 == revision,
              range.location >= 0, range.location <= text.length, range.length >= 0,
              range.length <= text.length - range.location else { emojiCompletionContext = nil; return }
        if let prefix = context.prefix {
            guard range.location > prefix.location, NSMaxRange(range) <= NSMaxRange(prefix),
                  nameEdit else {
                emojiCompletionContext = nil; emojiCompletionRequested = false; return
            }
            context.prefix = NSRange(location: prefix.location, length: prefix.length + (replacement as NSString).length - range.length)
        } else {
            guard range.length == 0 else { emojiCompletionContext = nil; return }
            var start = range.location
            if replacement != ":" && nameEdit {
                while start > 0 {
                    let unit = text.character(at: start - 1)
                    guard (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 43 || unit == 45 else { break }
                    start -= 1
                }
                guard start > 0 && text.character(at: start - 1) == 58 else { emojiCompletionContext = nil; return }
                start -= 1
            } else if replacement != ":" { emojiCompletionContext = nil; return }
            guard (context.sourceLength == 0 && start == 0 || emojiTextContains(NSRange(location: start, length: range.location - start), in: context)) else {
                emojiCompletionContext = nil; return
            }
            var index = start, slashes = 0
            while index > 0 && text.character(at: index - 1) == 92 { index -= 1; slashes += 1 }
            guard slashes % 2 == 0 else { emojiCompletionContext = nil; return }
            context.prefix = NSRange(location: start, length: range.location - start + (replacement as NSString).length)
        }
        context.revision = revision
        emojiCompletionContext = context
    }

    func allowsEmojiCompletion(document: EditorDocument, revision: UInt, prefixRange: NSRange) -> Bool {
        guard isActive, document.language == .markdown, self.document === document, currentRevision?() == revision, !hasMarkedText,
              let context = emojiCompletionContext, context.revision == revision else { return false }
        if let prefix = context.prefix { return prefix == prefixRange }
        guard prefixRange.length > 0 else { return false }
        return emojiTextContains(prefixRange, in: context)
    }

    private func fenceContainerOpening(in context: FenceContext, lineRange: NSRange) -> FenceContainerOpening? {
        if let line = context.line { return line == lineRange ? context.opening : nil }
        var low = 0, high = context.openings.count
        while low < high {
            let middle = (low + high) / 2
            if context.openings[middle].line.location < lineRange.location { low = middle + 1 } else { high = middle }
        }
        guard low < context.openings.count, context.openings[low].line == lineRange else { return nil }
        return context.openings[low]
    }

    func fenceContainerOpening(document: EditorDocument, revision: UInt, lineRange: NSRange) -> (sourcePrefix: String, continuationPrefix: String)? {
        guard isActive, enabled, self.document === document, currentRevision?() == revision,
              !hasMarkedText, let context = fenceContext, context.revision == revision,
              let opening = fenceContainerOpening(in: context, lineRange: lineRange) else { return nil }
        return (opening.sourcePrefix, opening.continuationPrefix)
    }

    func allowsFenceOpening(document: EditorDocument, revision: UInt, lineRange: NSRange) -> Bool {
        guard isActive, enabled, self.document === document, currentRevision?() == revision,
              !hasMarkedText, let context = fenceContext, context.revision == revision else { return false }
        if let line = context.line { return line == lineRange && context.lineAllowed }
        return !fenceLineBlocked(lineRange.location, in: context)
    }

    func beforeEdit(range: NSRange, replacementLength: Int, replacement: String? = nil) {
        guard enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || mathPairEnabled || elementPathEnabled || presentation != nil || parsedResult != nil else { return }
        let isContinuation = deferredReadyClear
        // Прошлая правка сдвинула оформление, но текст так и не изменился: сдвиг ничем не подтверждён.
        if keptEdit != nil {
            keptEdit = nil
            // Следующая клавиша подтверждает, что ввод продолжается. Не сбрасываем
            // готовые медиа между клавишами: их диапазоны будут сдвинуты ещё раз,
            // а новый разбор позже заменит только действительно изменившиеся блоки.
            deferredReadyClear = true
        }
        document?.invalidateMarkdownReadableText()
        if document?.isMarkdownOutlineCurrent == true { document?.isMarkdownOutlineCurrent = false }
        parsedResult = nil
        parsedSource = nil
        // `cancelPending` вызывается до сдвига placement. Если оформление уже
        // показано, незавершённые загрузки неизменившихся картинок должны
        // пережить эту клавишу; их ключи будут перенесены в `shiftInstalledMedia`.
        deferredReadyClear = isActive && !hasMarkedText && (presentation != nil || !styledRanges.isEmpty)
        cancelPending(preservingMedia: deferredReadyClear)
        if isActive && !hasMarkedText {
            if presentation != nil || !styledRanges.isEmpty {
                if let replacement, let edit = presentationAfterEdit(range: range, replacement: replacement, replacementLength: replacementLength) {
                    lastRevealedRange = lastRevealedRange.flatMap { shifted([$0]).first }
                    if isContinuation {
                        presentation?.shiftMediaOnly(edit)
                        shiftInstalledMedia(edit)
                        shiftDiagrams(edit)
                        layout?.shiftMarkdownMediaOnly(edit)
                    } else {
                        shiftPresentation(edit)
                    }
                    keptEdit = (currentRevision?() ?? 0, (textView?.textStorage?.length ?? 0) - range.length + replacementLength,
                                NSRange(location: range.location, length: replacementLength))
                    deferredReadyClear = true
                } else {
                    // Полный разбор всё равно понадобится, но готовые медиа оставляем на экране
                    // до его завершения. Даже при структурно небезопасной правке переносим
                    // старые диапазоны механически: иначе FoldLayoutManager сразу показывает
                    // исходный Markdown вместо ещё актуальных вставок.
                    let edit = MarkdownTextEdit(range: range, replacementLength: replacementLength,
                                                textLength: textView?.textStorage?.length ?? 0)
                    let editingDiagram = presentation?.diagrams.contains { diagram in
                        if range.length > 0 {
                            return NSIntersectionRange(range, diagram.range).length > 0
                        }
                        return diagram.range.location <= range.location && range.location <= NSMaxRange(diagram.range)
                    } == true
                    // Внутри диаграммы показывается исходный текст. Не тратим
                    // O(N)-сдвиг всей Markdown-модели на каждую букву: новый
                    // результат будет установлен после выхода из блока.
                    if editingDiagram || isContinuation {
                        presentation?.shiftMediaOnly(edit)
                        shiftInstalledMedia(edit)
                        shiftDiagrams(edit)
                        layout?.shiftMarkdownMediaOnly(edit)
                    } else {
                        shiftPresentation(edit)
                    }
                    deferredReadyClear = true
                }
            } else {
                clearReady()
            }
        } else if hasMarkedText {
            clearReady()
            needsCompositionRefresh = true
        } else {
            clearReady()
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
        let inheritedAlignment = alignedRanges.first { $0.value.contains(range.location) }?.key
            ?? (range.location > 0 ? alignedRanges.first { $0.value.contains(range.location - 1) }?.key : nil)
        for key in Array(alignedRanges.keys) {
            alignedRanges[key]?.remove(integersIn: range.location..<NSMaxRange(range))
            alignedRanges[key]?.shift(startingAt: NSMaxRange(range), by: replacementLength - range.length)
        }
        if let inheritedAlignment, replacementLength > 0 {
            alignedRanges[inheritedAlignment, default: IndexSet()].insert(integersIn: range.location..<(range.location + replacementLength))
        }
        backgroundRanges = shifted(backgroundRanges)
        inlineForegroundRanges = shifted(inlineForegroundRanges)
        lastVisibleRange = nil
    }

    func edited(revision: UInt) {
        guard enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || mathPairEnabled || elementPathEnabled || presentation != nil || parsedResult != nil else { return }
        document?.invalidateMarkdownReadableText()
        if document?.isMarkdownOutlineCurrent == true { document?.isMarkdownOutlineCurrent = false }
        parsedResult = nil
        parsedSource = nil
        let kept = keptEdit?.revision == revision && keptEdit?.length == textView?.textStorage?.length && !hasMarkedText && isActive
        // Открытые details переезжают вместе с блоками (`shiftMedia`): очищаются только на старом пути.
        if self.revision != revision && !kept { expandedDetails.removeAll() }
        self.revision = revision
        // `beforeEdit` уже отменил устаревшие операции перед сдвигом placement.
        // При сохранённом оформлении повторная отмена здесь выполнялась для
        // каждого символа и лишний раз инвалидировала поколение/очередь задач.
        if !deferredReadyClear {
            cancelPending()
        }
        let inserted = keptEdit?.inserted
        keptEdit = nil
        if !kept && !deferredReadyClear {
            clearReady()
            dropKeptPresentation()
        }
        guard !hasMarkedText else {
            deferredReadyClear = false
            return
        }
        guard isActive else { needsRefresh = true; return }
        if !kept && !deferredReadyClear { invalidatePresentation(in: visibleRange()) }
        else {
            if let inserted { matchInsertedStyle(inserted) }
            // Анимированные картинки лежат отдельными видами: на сдвинутое место их ставит только пересчёт рамок.
            if !animatedImages.isEmpty { notifyGeometryChanged() }
            placeMediaAfterEdit()
        }
        if enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || elementPathEnabled || (mathPairEnabled && mathPairContext?.revision != revision) { schedule(revision: revision) }
    }

    func projectionChanged(revision: UInt) {
        clearElementPath()
        parsedResult = nil
        parsedSource = nil
        self.revision = revision
        cancel()
        needsRefresh = true
    }

    func compositionFinished(revision: UInt) {
        if !hasMarkedText, let pendingSyntaxOptions { setSyntaxOptions(pendingSyntaxOptions) }
        guard enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || mathPairEnabled || elementPathEnabled || presentation != nil || needsCompositionRefresh else { return }
        if self.revision != revision { expandedDetails.removeAll() }
        self.revision = revision
        guard !hasMarkedText else { return }
        needsCompositionRefresh = false
        guard isActive else { needsRefresh = true; return }
        if needsRefresh {
            needsRefresh = false
            clear()
            if enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || elementPathEnabled || (mathPairEnabled && mathPairContext?.revision != revision) { schedule(revision: revision) }
        } else if enabled || outlineVisible || readableEnabled || emojiCompletionEnabled || mathPairEnabled || elementPathEnabled {
            invalidatePresentation(in: visibleRange())
            schedule(revision: revision)
        } else {
            clear()
        }
    }

    private func clearFootnoteTooltips() {
        for tooltip in footnoteTooltips { textView?.removeToolTip(tooltip.tag) }
        footnoteTooltips.removeAll()
    }

    /// Подсказка на прежнем месте с прежним текстом остаётся: снимаются и добавляются только изменившиеся.
    private func updateFootnoteTooltips(in visible: NSRange) {
        guard let textView, let layout, let container = textView.textContainer, let presentation else {
            clearFootnoteTooltips()
            return
        }
        var stale = footnoteTooltips
        footnoteTooltips.removeAll()
        for footnote in presentation.footnotes where NSIntersectionRange(footnote.referenceRange, visible).length > 0 {
            let glyphs = layout.glyphRange(forCharacterRange: footnote.referenceRange, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            guard !rect.isEmpty else { continue }
            let owner = footnote.text as NSString
            if let same = stale.firstIndex(where: { $0.rect == rect && $0.owner == owner }) {
                footnoteTooltips.append(stale.remove(at: same))
                continue
            }
            let tag = textView.addToolTip(rect, owner: owner, userData: nil)
            footnoteTooltips.append((tag, rect, owner))
        }
        for tooltip in stale { textView.removeToolTip(tooltip.tag) }
    }

    func footnoteTarget(at point: NSPoint, document: EditorDocument, revision: UInt) -> NSRange? {
        guard isActive, enabled, self.document === document, self.revision == revision,
              currentRevision?() == revision, let textView, !textView.hasMarkedText(),
              let layout, let container = textView.textContainer, let presentation else { return nil }
        let location = NSPoint(x: point.x - textView.textContainerOrigin.x, y: point.y - textView.textContainerOrigin.y)
        func contains(_ range: NSRange) -> Bool {
            guard NSMaxRange(range) <= (textView.textStorage?.length ?? 0),
                  !layout.intersectsFoldedRange(range) else { return false }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: container).contains(location)
        }
        if let reference = presentation.footnotes.first(where: { contains($0.referenceRange) }) {
            lastFootnote = reference
            return NSRange(location: reference.definitionRange.location, length: 0)
        }
        if let lastFootnote, presentation.footnotes.contains(lastFootnote), contains(lastFootnote.definitionRange) {
            self.lastFootnote = nil
            return NSRange(location: lastFootnote.referenceRange.location, length: 0)
        }
        return nil
    }

    func isCurrentTaskCheckbox(_ checkbox: MarkdownTaskCheckbox, document: EditorDocument, revision: UInt) -> Bool {
        isActive && enabled && self.document === document && self.revision == revision &&
            currentRevision?() == revision && textView?.hasMarkedText() == false &&
            presentation?.taskCheckboxes.contains(checkbox) == true
    }

    func navigationPresentation(document: EditorDocument, revision: UInt) -> MarkdownPresentation? {
        guard isActive, self.document === document, self.revision == revision,
              currentRevision?() == revision, !hasMarkedText else { return nil }
        return parsedResult
    }

    /// Индекс текущего разбора для правок CriticMarkup: только для актуальной версии, длины текста и без незавершённого ввода.
    func criticElementIndex(document: EditorDocument, revision: UInt, textLength: Int) -> MarkdownElementIndex? {
        guard isActive, self.document === document, self.revision == revision, parsedRevision == revision,
              currentRevision?() == revision, !hasMarkedText,
              let elements = parsedResult?.elements, elements.textLength == textLength else { return nil }
        return elements
    }

    func mathReference(at point: NSPoint, document: EditorDocument, revision: UInt) -> NSRange? {
        guard isActive, enabled, self.document === document, self.revision == revision,
              currentRevision?() == revision, !hasMarkedText, let presentation,
              let textView, let container = textView.textContainer,
              let result = layout?.markdownMathReference(at: point, in: container),
              (presentation.formulas + presentation.inlineFormulas).contains(where: { $0.range == result.source }),
              (presentation.formulas + presentation.inlineFormulas).contains(where: { $0.range == result.target }) else { return nil }
        return result.target
    }

    func mathReference(atSourceOffset offset: Int, document: EditorDocument, revision: UInt) -> NSRange? {
        guard isActive, enabled, self.document === document, self.revision == revision,
              currentRevision?() == revision, !hasMarkedText, let presentation,
              let storage = textView?.textStorage else { return nil }
        for formula in presentation.inlineFormulas where offset > formula.range.location && offset < NSMaxRange(formula.range) - 1 {
            guard let references = sourceMathReferences[formula.range], NSMaxRange(formula.range) <= storage.length,
                  storage.mutableString.substring(with: formula.range) == "$" + formula.source + "$" else { continue }
            guard let target = references.first(where: { NSLocationInRange(offset, $0.0) })?.1,
                  (presentation.formulas + presentation.inlineFormulas).contains(where: { $0.range == target }) else { continue }
            return target
        }
        return nil
    }

    func currentTablePresentation(document: EditorDocument, revision: UInt) -> MarkdownPresentation? {
        // Сдвинутое на месте оформление неполное (заголовки, элементы очищены): ячейке нужен свежий разбор.
        guard isActive, enabled, self.document === document, self.revision == revision,
              currentRevision?() == revision, !presentationKept else { return nil }
        return presentation
    }

    func installTablePresentation(_ result: MarkdownPresentation, document: EditorDocument, revision: UInt) {
        guard isActive, enabled, self.document === document, self.revision == revision,
              currentRevision?() == revision else { return }
        install(result)
    }

    func isCurrentTableCell(_ cell: MarkdownTableCell, document: EditorDocument, revision: UInt) -> Bool {
        isActive && enabled && self.document === document && self.revision == revision &&
            currentRevision?() == revision && textView?.hasMarkedText() == false &&
            presentation?.tables.contains(where: { $0.rows.contains(where: { $0.cells.contains(cell) }) }) == true
    }

    func isCurrentTOC(_ range: NSRange, heading: MarkdownHeading?, document: EditorDocument, revision: UInt) -> Bool {
        isActive && enabled && self.document === document && self.revision == revision &&
            currentRevision?() == revision && textView?.hasMarkedText() == false &&
            presentation?.tableOfContents.contains(range) == true &&
            (heading.map { value in presentation?.headings.contains(where: { $0.sameSource(as: value) }) == true } ?? true)
    }

    func isCurrentPageBreak(_ range: NSRange, document: EditorDocument, revision: UInt) -> Bool {
        isActive && enabled && self.document === document && self.revision == revision &&
            currentRevision?() == revision && !hasMarkedText && presentation?.pageBreaks.contains(range) == true
    }

    func selectionChanged() {
        refreshElementPath()
        if isActive, mathPairEnabled, !enabled, !outlineVisible, !readableEnabled, !emojiCompletionEnabled,
           !hasMarkedText, currentRevision?() == revision, let context = mathPairContext,
           let active = context.active, let selection = textView?.selectedRange(),
           (selection.location < active.location || NSMaxRange(selection) > NSMaxRange(active)) {
            mathPairContext = nil
            if work == nil && operation == nil { schedule(revision: revision) }
        }
        guard isActive, enabled, !hasMarkedText, presentation != nil else { return }
        if let visible = visibleRange() { loadVisibleDiagrams(in: visible) }
        layout?.updateMarkdownInlineSelection(inlineSelection())
        let range = revealedRange()
        guard range != lastRevealedRange else { return }
        lastRevealedRange = range
        layout?.updateMarkdownRevealedRange(range)
        if headingNumbering {
            lastVisibleRange = nil
            applyVisible()
        }
        notifyGeometryChanged()
        if let visible = visibleRange() {
            updateAudio(in: visible)
            updateIframes(in: visible)
            updateDetails(in: visible)
            updateHTMLBlocks(in: visible)
            updateRuby(in: visible)
            loadVisibleImages(in: visible)
            loadVisibleFormulas(in: visible)
            loadVisibleEmoji(in: visible)
            updateFootnoteTooltips(in: visible)
        }
    }

    func viewportChanged() {
        guard isActive, enabled, !hasMarkedText else { return }
        if !uppercaseHeadingLevels.isEmpty, let container = textView?.textContainer,
           layout?.uppercaseHeadingsNeedLayout(in: container) == true {
            clearUppercaseHeadings()
            lastVisibleRange = nil
        }
        if presentation != nil {
            let previous = lastVisibleRange
            applyVisible()
            if let visible = visibleRange() {
                updateAudio(in: visible)
                updateIframes(in: visible)
                updateDetails(in: visible)
                updateHTMLBlocks(in: visible)
                updateRuby(in: visible)
                if visible == previous { loadVisibleImages(in: visible) }
                if visible == previous { updateFootnoteTooltips(in: visible) }
            }
        } else if let visible = visibleRange(), visible != lastVisibleRange {
            lastVisibleRange = visible
            restoreStyles(in: visible)
            layout?.invalidateMarkdownLayout(in: visible)
            notifyGeometryChanged()
        }
    }

    func tableEditingGeometryChanged(cell: NSRange?) {
        editingTableCell = cell
        DispatchQueue.main.async { [weak self] in self?.refreshElementPath() }
        foldGeometryChanged()
    }

    func foldGeometryChanged() {
        guard !hasMarkedText else { return }
        notifyGeometryChanged()
    }

    func restoreBackground(in ranges: [NSRange]) {
        guard isActive, enabled, presentation != nil, textView?.hasMarkedText() != true, let layout else { return }
        for range in ranges {
            for background in backgroundRanges {
                let part = NSIntersectionRange(background, range)
                if part.length > 0 {
                    let color = backgroundColor(for: intersecting(part))
                    layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: part)
                }
            }
        }
    }

    private func backgroundColor(for active: [MarkdownPresentationSpan]) -> NSColor {
        if let color = inlineStyle(for: active).background { return color.nsColor }
        if active.contains(where: { $0.kind == .highlight }) { return NSColor.systemYellow.withAlphaComponent(0.3) }
        if active.contains(where: { $0.kind == .code || $0.kind == .keyboard || $0.kind == .codeBlock }), let color = layout?.markdownColors.codeBackground { return color.nsColor }
        if active.contains(where: { $0.kind == .quote }), let color = layout?.markdownColors.quoteBackground { return color.nsColor }
        return NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
    }

    private func inlineStyle(for active: [MarkdownPresentationSpan]) -> MarkdownInlineStyle {
        let styles = active.compactMap { span -> (NSRange, MarkdownInlineStyle)? in
            if case .inlineStyle(let style) = span.kind { return (span.range, style) }
            return nil
        }.sorted { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location }
        return styles.reduce(MarkdownInlineStyle()) { parent, item in item.1.inheriting(parent) }
    }

    private func rememberInlineForeground(_ range: NSRange) {
        var merged = range
        var low = 0, high = inlineForegroundRanges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(inlineForegroundRanges[middle]) < merged.location { low = middle + 1 } else { high = middle }
        }
        let startIndex = low
        while low < inlineForegroundRanges.count && inlineForegroundRanges[low].location <= NSMaxRange(merged) {
            let current = inlineForegroundRanges[low]
            let start = min(current.location, merged.location)
            merged = NSRange(location: start, length: max(NSMaxRange(current), NSMaxRange(merged)) - start)
            low += 1
        }
        inlineForegroundRanges.replaceSubrange(startIndex..<low, with: [merged])
    }

    func reapplyLinkColors(in range: NSRange) {
        guard isActive, enabled, !hasMarkedText, currentRevision?() == revision, let layout else { return }
        defer { applyUnresolvedWikiColors(in: range) }
        if let color = layout.markdownColors.link?.nsColor {
            for span in intersecting(range) where span.kind == .link {
                let part = NSIntersectionRange(span.range, range)
                if part.length > 0 { layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: part) }
            }
        }
        let spans = intersecting(range)
        for span in spans.sorted(by: { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }) {
            guard case .inlineStyle(let style) = span.kind, let color = style.foreground else { continue }
            let part = NSIntersectionRange(span.range, range)
            if part.length > 0 {
                layout.addTemporaryAttribute(.foregroundColor, value: color.nsColor, forCharacterRange: part)
                rememberInlineForeground(part)
            }
        }
    }

    /// Wiki-ссылка без единственного файла рисуется приглушённым цветом; пока каталог не загружен, считается разрешённой.
    private func applyUnresolvedWikiColors(in range: NSRange) {
        guard let layout, let links = presentation?.wikiLinks, !links.isEmpty else { return }
        var low = 0, high = links.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(links[middle].range) <= range.location { low = middle + 1 } else { high = middle }
        }
        while low < links.count && links[low].range.location < NSMaxRange(range) {
            let link = links[low]
            low += 1
            guard let resolver = wikiResolver else { continue }
            switch resolver.resolve(target: link.target) {
            case .file, .currentDocument: continue
            case .ambiguous, .missing, .invalid: break
            }
            let part = NSIntersectionRange(link.displayRange, range)
            if part.length > 0 { layout.addTemporaryAttribute(.foregroundColor, value: NSColor.lacMutedText, forCharacterRange: part) }
        }
    }

    /// Каталог файлов изменился: заново расставить цвета wiki-ссылок в оформленной области.
    func wikiResolverChanged() {
        guard isActive, enabled, let layout, let links = presentation?.wikiLinks, !links.isEmpty else { return }
        // Во время незавершённого ввода цвета расставит разбор, который запускается после его окончания.
        guard !hasMarkedText, currentRevision?() == revision else { return }
        for link in links {
            for styled in styledRanges where NSIntersectionRange(styled, link.range).length > 0 {
                let part = NSIntersectionRange(link.displayRange, styled)
                guard part.length > 0 else { continue }
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: part)
                reapplyLinkColors(in: part)
            }
        }
    }

    func metricsChanged() {
        guard isActive, !hasMarkedText else { return }
        if !uppercaseHeadingLevels.isEmpty { clearUppercaseHeadings() }
        publishReadableTextIfNeeded()
        refreshMathOptionsIfNeeded()
        lastVisibleRange = nil
        if enabled, presentation != nil { applyVisible() }
    }

    func setStrikeCompletedTasks(_ enabled: Bool) {
        guard strikeCompletedTasks != enabled else { return }
        strikeCompletedTasks = enabled
        layout?.markdownStrikeCompletedTasks = enabled
        metricsChanged()
    }

    func setHeadingNumbering(_ enabled: Bool) {
        guard headingNumbering != enabled, !hasMarkedText else { return }
        headingNumbering = enabled
        if !enabled { restoreParagraphAlignment() }
        guard let result = parsedResult else {
            work?.cancel()
            work = nil
            operation?.cancel()
            operation = nil
            generation &+= 1
            if isActive { schedule(revision: revision) }
            return
        }
        let updated = result.numberingHeadings(enabled)
        parsedResultToken = UUID()
        emojiOperation?.cancel()
        emojiOperation = nil
        parsedResult = updated
        if outlineVisible { publishOutline(updated, revision: revision) }
        if self.enabled { install(updated) }
        else { startEmojiResolution() }
    }

    func setUppercaseHeadingLevels(_ levels: Set<Int>) {
        let levels = Set(levels.filter { (1...6).contains($0) })
        guard uppercaseHeadingLevels != levels, !hasMarkedText else { return }
        uppercaseHeadingLevels = levels
        uppercaseSnapshotReady = false
        uppercaseHeadings.removeAll()
        clearUppercaseHeadings()
        if levels.isEmpty {
            lastVisibleRange = nil
            if enabled { applyVisible() }
            return
        }
        work?.cancel(); work = nil
        operation?.cancel(); operation = nil
        generation &+= 1
        document?.taskCoordinator.cancel(.markdownPresentation)
        if isActive && (enabled || outlineVisible || readableEnabled) { schedule(revision: revision) }
    }

    private func clearUppercaseHeadings() {
        layout?.clearUppercaseHeadings()
        uppercaseInstalled.removeAll()
    }

    func setMathOptions(_ options: MathJaxRenderService.Options) {
        guard mathOptions != options else { return }
        mathOptions = options
        let service = formulaJob?.service
        formulaJob = nil
        sourceMathReferences.removeAll()
        service?.cancel()
        mathOptionsNeedRefresh = true
        lastVisibleRange = nil
        metricsChanged()
    }

    private func refreshMathOptionsIfNeeded() {
        guard mathOptionsNeedRefresh, !hasMarkedText else { return }
        let inline = Set(presentation?.inlineFormulas.map(\.range) ?? [])
        for range in formulaCompleted {
            if inline.contains(range) { layout?.removeMarkdownInlineImage(for: range) }
            else { layout?.setMarkdownBlockImage(nil, for: range) }
        }
        formulaCompleted.removeAll()
        sourceMathReferences.removeAll()
        mathOptionsNeedRefresh = false
    }

    /// Старый путь: отмена незавершённого и очистка готового.
    func cancel() {
        clearReady()
        deferredReadyClear = false
        cancelPending()
    }

    /// Останавливает то, что ещё считается; поздние результаты отбрасываются по поколению. Готовое не трогает.
    private func cancelPending(preservingMedia: Bool = false) {
        cancelCodeJobs()
        // Отменяем только незавершённый рендер. Готовые диаграммы и формулы
        // должны оставаться в раскладке до установки нового разбора.
        if !preservingMedia {
            cancelDiagramJobs()
            formulaJob?.service.cancel()
            formulaJob = nil
            cancelMediaJobs()
        }
        emojiOperation?.cancel()
        emojiOperation = nil
        // Во время обычного ввода `beforeEdit` сохраняет keptEdit: позиционные
        // placement уже сдвинутся, а загрузки неизменившихся изображений должны
        // продолжаться. При полном сбросе разбора старые задания действительно
        // устарели и отменяются.
        if !preservingMedia { cancelImageJobs() }
        work?.cancel()
        work = nil
        operation?.cancel()
        operation = nil
        if !preservingMedia {
            generation &+= 1
            document?.taskCoordinator.cancel(.markdownPresentation)
        }
    }

    /// Отменяет незавершённые загрузки картинок: ключи у них позиционные, после расхождения разбора они устарели.
    private func cancelImageJobs() {
        for operation in imageOperations.values { operation.cancel() }
        imageOperations.removeAll()
        for (_, task) in remoteImageJobs.values { task.cancel() }
        remoteImageJobs.removeAll()
        let svgJobs = svgImageJobs.values.map { $0.2 }
        svgImageJobs.removeAll()
        for job in svgJobs { job.cancel() }
    }

    private func imageCacheKey(for image: MarkdownImage) -> ImageCacheKey {
        ImageCacheKey(source: image.url, sizing: image.sizing?.css, isInline: image.isInline)
    }

    /// Диапазон — только текущее placement. Асинхронная работа живёт дольше одной
    /// правки текста, поэтому после `shiftPresentation` её нужно искать по
    /// стабильному идентификатору, а не по захваченному старому диапазону.
    private func currentImagePlacement(for token: UUID) -> NSRange? {
        if let entry = remoteImageJobs.first(where: { $0.value.0 == token }) { return entry.key }
        if let entry = svgImageJobs.first(where: { $0.value.0 == token }) { return entry.key }
        return nil
    }

    private func currentImagePlacement(for operation: BlockOperation) -> NSRange? {
        imageOperations.first(where: { $0.value === operation })?.key
    }

    private func image(at placement: NSRange) -> MarkdownImage? {
        presentation?.images.first { image in
            let range = image.isInline ? image.range : image.paragraphRange
            return range == placement
        }
    }

    private func diagramCacheKey(for diagram: MarkdownDiagram, width: CGFloat, dark: Bool) -> DiagramCacheKey {
        DiagramCacheKey(kind: diagram.kind.rawValue, source: diagram.source, width: width, dark: dark)
    }

    /// Переносит только placement уже готовых ресурсов к результату нового разбора.
    /// Ресурс с той же identity остаётся в кэше; старый ресурс удаляется лишь если такого
    /// элемента больше нет в презентации. Одинаковые картинки сопоставляются по порядку,
    /// чтобы повторяющиеся ссылки не перепутали свои диапазоны.
    private func reconcileMediaCache(from old: MarkdownPresentation, to new: MarkdownPresentation) {
        let oldImages = Dictionary(grouping: old.images, by: imageCacheKey(for:))
        let newImages = Dictionary(grouping: new.images, by: imageCacheKey(for:))
        func placement(_ image: MarkdownImage) -> NSRange {
            image.isInline ? image.range : image.paragraphRange
        }
        for (key, images) in oldImages {
            let targets = newImages[key, default: []].sorted { $0.range.location < $1.range.location }
            let sources = images.sorted { $0.range.location < $1.range.location }
            for (source, target) in zip(sources, targets) where placement(source) != placement(target) {
                // Не переносим флаг loaded в новый диапазон: после adopt новый
                // placement восстановит изображение из identity-кэша без старой
                // геометрии и без краткого показа исходного текста.
                loadedImageRanges.remove(placement(source))
                imagePresentationWidths.removeValue(forKey: placement(source))
                if let view = animatedImages.removeValue(forKey: placement(source)) {
                    view.animates = false
                    view.removeFromSuperview()
                }
            }
            if sources.count > targets.count {
                for source in sources.dropFirst(targets.count) {
                    let sourcePlacement = placement(source)
                    loadedImageRanges.remove(sourcePlacement)
                    imagePresentationWidths.removeValue(forKey: sourcePlacement)
                    if let view = animatedImages.removeValue(forKey: sourcePlacement) {
                        view.animates = false
                        view.removeFromSuperview()
                    }
                    if source.isInline { layout?.removeMarkdownInlineImage(for: source.range) }
                    else { layout?.setMarkdownImage(nil, for: source.paragraphRange) }
                }
            }
        }

        guard let geometry = diagramGeometry else { return }
        let oldDiagrams = Dictionary(grouping: old.diagrams, by: { diagramCacheKey(for: $0, width: geometry.0, dark: geometry.1) })
        let newDiagrams = Dictionary(grouping: new.diagrams, by: { diagramCacheKey(for: $0, width: geometry.0, dark: geometry.1) })
        for (key, diagrams) in oldDiagrams {
            let targets = newDiagrams[key, default: []].sorted { $0.range.location < $1.range.location }
            let sources = diagrams.sorted { $0.range.location < $1.range.location }
            for (source, target) in zip(sources, targets) where source.range != target.range {
                diagramCompleted.remove(source.range)
                diagramResources.removeValue(forKey: source.range)
            }
            if sources.count > targets.count {
                for source in sources.dropFirst(targets.count) {
                    diagramCompleted.remove(source.range)
                    diagramResources.removeValue(forKey: source.range)
                    layout?.setMarkdownBlockImage(nil, for: source.range)
                }
            }
        }
    }

    /// Убирает готовое: оформление, привязанное к позициям, нельзя оставлять там, где оно уже не соответствует тексту.
    private func clearReady() {
        cancelCodeHighlighting()
        emojiValues = nil
        if !hasMarkedText { emojiRanges.removeAll() }
        emojiFonts.removeAll()
        clearFootnoteTooltips()
        lastFootnote = nil
        imagePresentationWidths.removeAll()
        if !hasMarkedText { clearAnimatedImages() }
        loadedImageRanges.removeAll()
        cancelDiagrams()
        clearAudio()
        lastVisibleRange = nil
        if !hasMarkedText { layout?.clearMarkdownImages() }
    }

    private func schedule(revision: UInt) {
        let generation = self.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, (self.enabled || self.outlineVisible || self.readableEnabled || self.emojiCompletionEnabled || self.mathPairEnabled || self.elementPathEnabled), self.isActive, self.generation == generation,
                  let document = self.document, let textView = self.textView,
                  !self.hasMarkedText, self.currentRevision?() == revision else { return }
            self.work = nil
            let text = textView.string
            let sourceURL = document.url
            let includeReadableText = self.readableEnabled
            let includeMathPair = self.mathPairEnabled
            let syntax = self.syntaxOptions
            let headingNumbering = self.headingNumbering
            let includeUppercaseRuns = self.enabled && !self.uppercaseHeadingLevels.isEmpty
            let includeEmojiCandidates = self.enabled || self.outlineVisible || self.readableEnabled || self.emojiCompletionEnabled || self.mathPairEnabled
            let taskGeneration = document.taskCoordinator.begin(.markdownPresentation)
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation, weak document] in
                guard let operation, !operation.isCancelled, let document else { return }
                let signpost = OSSignpostID(log: markdownEditorPerformanceLog)
                os_signpost(.begin, log: markdownEditorPerformanceLog, name: "MarkdownPresentationParse", signpostID: signpost)
                let parsed = MarkdownPresentationParser.parse(text, includeReadableText: includeReadableText, includeEmojiCandidates: includeEmojiCandidates,
                                                              includeUppercaseRuns: includeUppercaseRuns, includeWikiLinks: true, syntax: syntax,
                                                              isCancelled: { operation.isCancelled })
                os_signpost(.end, log: markdownEditorPerformanceLog, name: "MarkdownPresentationParse", signpostID: signpost)
                let result = headingNumbering ? parsed.numberingHeadings(true) : parsed
                let needsRoot = result.images.contains { MarkdownResourcePaths.requiresRoot($0.url) } || result.audioBlocks.contains { $0.media.sources.contains(where: { MarkdownResourcePaths.requiresRoot($0) }) }
                let paths: MarkdownResourcePaths?
                if needsRoot { paths = try? MarkdownResourcePaths(text: text, document: sourceURL) }
                else { paths = nil }
                let raw = text as NSString
                let sourceLength = raw.length
                var mathPairRanges: [NSRange] = []
                if includeMathPair {
                    let formulas = result.inlineFormulas.map(\.range).sorted { $0.location < $1.location }
                    let textRanges = result.emojiCompletionRanges
                    var blockedLines: [NSRange] = [], position = 0, formulaIndex = 0, textIndex = 0, backslashes = 0
                    var blockedStart: Int?
                    while position < raw.length {
                        if operation.isCancelled { return }
                        let unit = raw.character(at: position)
                        while formulaIndex < formulas.count && NSMaxRange(formulas[formulaIndex]) <= position { formulaIndex += 1 }
                        while textIndex < textRanges.count && NSMaxRange(textRanges[textIndex]) <= position { textIndex += 1 }
                        let inFormula = formulaIndex < formulas.count && NSLocationInRange(position, formulas[formulaIndex])
                        let inText = textIndex < textRanges.count && NSLocationInRange(position, textRanges[textIndex])
                        if unit == 36 && inText && !inFormula && backslashes % 2 == 0 && blockedStart == nil { blockedStart = position }
                        backslashes = unit == 92 ? backslashes + 1 : 0
                        position += 1
                        if [10, 13, 0x85, 0x2028, 0x2029].contains(Int(unit)) {
                            if unit == 13 && position < raw.length && raw.character(at: position) == 10 { position += 1 }
                            if let start = blockedStart { blockedLines.append(NSRange(location: start, length: position - start)) }
                            blockedStart = nil
                            backslashes = 0
                        }
                    }
                    if let start = blockedStart { blockedLines.append(NSRange(location: start, length: raw.length - start)) }
                    for range in result.smartTextRanges {
                        guard !operation.isCancelled, range.location >= 0, NSMaxRange(range) <= raw.length else { return }
                        var low = 0, high = blockedLines.count
                        while low < high {
                            let middle = (low + high) / 2
                            if NSMaxRange(blockedLines[middle]) <= range.location { low = middle + 1 } else { high = middle }
                        }
                        var cursor = range.location
                        while low < blockedLines.count && blockedLines[low].location < NSMaxRange(range) {
                            let blocked = blockedLines[low]
                            if cursor < blocked.location { mathPairRanges.append(NSRange(location: cursor, length: blocked.location - cursor)) }
                            cursor = max(cursor, NSMaxRange(blocked))
                            low += 1
                        }
                        if cursor < NSMaxRange(range) { mathPairRanges.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
                    }
                }
                let paragraphOpenings = result.fenceContainerLines.map {
                    FenceContainerOpening(line: $0.line, sourcePrefix: $0.sourcePrefix, continuationPrefix: $0.continuationPrefix)
                }
                let codeOpenings = result.codeBlocks.compactMap { block -> FenceContainerOpening? in
                    guard !operation.isCancelled, block.isNested, !block.isClosed, block.bodyRange.length == 0,
                          block.range.location < raw.length else { return nil }
                    let line = raw.lineRange(for: NSRange(location: block.range.location, length: 0))
                    let prefix = raw.substring(with: NSRange(location: line.location, length: block.range.location - line.location))
                    guard !prefix.isEmpty else { return nil }
                    return FenceContainerOpening(line: line, sourcePrefix: prefix, continuationPrefix: block.continuationPrefix)
                }
                let openings = (paragraphOpenings + codeOpenings).sorted { $0.line.location < $1.line.location }
                guard !operation.isCancelled else { return }
                DispatchQueue.main.async { [weak self, weak document] in
                    guard let self, let document, self.document === document, document.url == sourceURL, (self.enabled || self.outlineVisible || self.readableEnabled || self.emojiCompletionEnabled || self.mathPairEnabled || self.elementPathEnabled), self.isActive,
                          self.generation == generation, self.currentRevision?() == revision,
                          document.taskCoordinator.isCurrent(taskGeneration, for: .markdownPresentation),
                          !self.hasMarkedText else { return }
                    document.taskCoordinator.finish(.markdownPresentation, generation: taskGeneration)
                    self.operation = nil
                    self.emojiOperation?.cancel()
                    self.emojiOperation = nil
                    self.emojiValues = nil
                    self.uppercaseEmojiResolutionFailed = false
                    self.uppercaseSnapshotReady = includeUppercaseRuns
                    self.parsedResultToken = UUID()
                    self.parsedResult = result
                    self.parsedRevision = revision
                    self.parsedSource = text
                    self.resourcePaths = paths
                    self.resourceRootInvalid = needsRoot && paths == nil
                    self.emojiCompletionContext = EmojiCompletionContext(ranges: result.emojiCompletionRanges, sourceLength: sourceLength, revision: revision)
                    self.smartTextContext = SmartTextContext(ranges: result.smartTextRanges, rawHTMLRanges: result.smartRawHTMLRanges, revision: revision)
                    self.mathPairContext = self.mathPairEnabled && includeMathPair ? SmartTextContext(ranges: mathPairRanges, rawHTMLRanges: result.smartRawHTMLRanges, revision: revision) : nil
                    self.fenceContext = result.fenceContextAvailable
                        ? FenceContext(openings: openings, blocked: result.fenceBlockedRanges, blockedEOF: result.fenceBlockedEOF,
                                       sourceLength: sourceLength, revision: revision) : nil
                    if self.readableEnabled, result.emojiCandidates.isEmpty, let readableText = result.readableText {
                        document.installMarkdownReadableText(readableText, source: text)
                    }
                    if (self.readableEnabled && !includeReadableText) || (self.enabled && !includeEmojiCandidates) || (self.mathPairEnabled && !includeMathPair) {
                        self.schedule(revision: revision)
                    }
                    if self.outlineVisible { self.publishOutline(result, revision: revision) }
                    if self.enabled { self.install(result) }
                    else { self.startEmojiResolution() }
                    if self.emojiCompletionRequested { self.emojiCompletionReady?() }
                    if !result.wikiLinks.isEmpty { self.wikiCatalogNeeded?() }
                    if self.wikiCompletionRequested { self.wikiCompletionReady?() }
                    self.refreshElementPath()
                    self.parsedResultDidChange?()
                }
            }
            self.operation = operation
            document.taskCoordinator.attach(operation, kind: .markdownPresentation, generation: taskGeneration)
            self.queue.addOperation(operation)
        }
        work = item
        // Когда разбор нужен только ради пути, пауза длиннее: короткие остановки при наборе не должны его запускать.
        let pathOnly = !enabled && !outlineVisible && !readableEnabled && !emojiCompletionEnabled && !mathPairEnabled
        // Полный разбор форматированного документа не должен запускаться на каждой клавише:
        // при непрерывном вводе ждём короткую паузу, оставляя уже установленное оформление.
        let delay = pathOnly ? 0.4 : (enabled ? 0.6 : 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func install(_ result: MarkdownPresentation) {
        if deferredReadyClear {
            deferredReadyClear = false
            // Полный разбор уже подготовлен, но готовые медиа нельзя снимать до
            // сопоставления их стабильных identity с новым результатом.
            presentationKept = true
        }
        clearUppercaseHeadings()
        uppercaseHeadings = uppercaseSnapshotReady && !uppercaseHeadingLevels.isEmpty
            ? Dictionary(result.headings.map { ($0.range.location, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        lastVisibleRange = nil
        if presentationKept {
            if let kept = presentation { reconcileMediaCache(from: kept, to: result) }
            presentationKept = false
            if let visible = visibleRange() { restoreStyles(in: visible) }
        }
        adopt(result)
        pruneCodeHighlighting(keeping: result.codeBlocks)
        lastRevealedRange = revealedRange()
        layout?.setMarkdownPresentation(result, revealedRange: lastRevealedRange, inlineSelection: inlineSelection(), invalidating: visibleRange() ?? NSRange(location: 0, length: 0))
        if visibleRange() == nil { notifyGeometryChanged() }
        startEmojiResolution()
        applyVisible()
    }

    private func adopt(_ result: MarkdownPresentation) {
        presentation = result
        presentation?.prepareForEditing()
    }

    private func clear() {
        keptEdit = nil
        deferredReadyClear = false
        presentationKept = false
        clearUppercaseHeadings()
        uppercaseHeadings.removeAll()
        emojiOperation?.cancel()
        emojiOperation = nil
        emojiValues = nil
        for range in emojiRanges { layout?.removeMarkdownInlineImage(for: range) }
        emojiRanges.removeAll()
        emojiFonts.removeAll()
        cancelCodeHighlighting()
        clearAudio()
        clearFootnoteTooltips()
        lastFootnote = nil
        layout?.clearMarkdownImages()
        layout?.clearMarkdownBlockImages()
        layout?.clearMarkdownInlineImages()
        clearAnimatedImages()
        let hadGeometry = presentation != nil || !styledRanges.isEmpty
        restoreStyles()
        if let textView, let layout {
            var typing = textView.typingAttributes
            typing[.font] = layout.textFont
            textView.typingAttributes = typing
        }
        presentation = nil
        lastVisibleRange = nil
        lastRevealedRange = nil
        layout?.setMarkdownPresentation(nil, revealedRange: nil)
        if hadGeometry { notifyGeometryChanged() }
    }

    private func invalidatePresentation(in range: NSRange?) {
        presentationKept = false
        clearUppercaseHeadings()
        uppercaseHeadings.removeAll()
        clearAudio()
        layout?.clearMarkdownImages()
        layout?.clearMarkdownBlockImages()
        layout?.clearMarkdownInlineImages()
        clearAnimatedImages()
        emojiRanges.removeAll()
        emojiFonts.removeAll()
        guard presentation != nil else { return }
        presentation = nil
        lastVisibleRange = nil
        lastRevealedRange = nil
        layout?.setMarkdownPresentation(nil, revealedRange: nil, invalidating: range ?? NSRange(location: 0, length: 0))
        notifyGeometryChanged()
    }

    /// Оформление остаётся на экране до результата нового разбора; диапазоны сдвигаются на месте под правку, без копий и сортировок.
    private func shiftPresentation(_ edit: MarkdownTextEdit) {
        guard let spanStart = presentation?.firstAffectedLocation(edit) else { return }
        // Выделение ещё в старых координатах: сверять его с картинками надо до их сдвига.
        let selection = inlineSelection()
        presentation?.shift(edit)
        presentationKept = true
        // Возврат по Cmd-клику с определения после правки не обещаем (как в `clearReady`): сноски уже сдвинуты.
        lastFootnote = nil
        layout?.shiftMarkdownPresentation(edit, spanStart: spanStart, revealedRange: lastRevealedRange, inlineSelection: selection)
        shiftCodeHighlighting(edit)
        shiftInstalledMedia(edit)
        shiftDiagrams(edit)
        shiftMedia(edit)
    }

    /// Простой текст вводится базовым шрифтом: до нового разбора вставка берёт оформление соседнего символа: слева, а после переноса строки и в начале текста справа.
    private func matchInsertedStyle(_ inserted: NSRange) {
        guard inserted.length > 0, let textView, let storage = textView.textStorage,
              NSMaxRange(inserted) <= storage.length else { return }
        // Сразу после переноса строки (и в начале текста) стиль берётся справа: слева он принадлежит предыдущей строке.
        let breaks: Set<unichar> = [10, 13]
        let source = inserted.location > 0 && !breaks.contains(storage.mutableString.character(at: inserted.location - 1))
            ? inserted.location - 1 : NSMaxRange(inserted)
        guard source < storage.length else { return }
        let neighbour = storage.attributes(at: source, effectiveRange: nil)
        guard neighbour[.font] as? NSFont != storage.attribute(.font, at: inserted.location, effectiveRange: nil) as? NSFont else { return }
        let typing = textView.typingAttributes
        storage.setAttributes(neighbour, range: inserted)
        textView.typingAttributes = typing
    }

    /// Правка обычного текста внутри одной строки, которую можно провести сдвигом оформления на месте; nil, если вести надо прежним путём.
    private func presentationAfterEdit(range: NSRange, replacement: String, replacementLength: Int) -> MarkdownTextEdit? {
        guard enabled, !hasMarkedText, uppercaseHeadingLevels.isEmpty, !headingNumbering, uppercaseHeadings.isEmpty, uppercaseInstalled.isEmpty,
              let presentation, layout?.hasActiveTable != true,
              let text = textView?.textStorage?.mutableString else { return nil }
        // Enter: правка берётся в позиции после уже стоящего перевода строки (`paragraphBreakEdit` сам вызывает `canShift`).
        if replacement == "\n" {
            return range.length == 0 ? presentation.paragraphBreakEdit(in: text, at: range.location) : nil
        }
        guard MarkdownPresentation.allowsTypingEdit(in: text, range: range, replacement: replacement) else { return nil }
        let edit = MarkdownTextEdit(range: range, replacementLength: replacementLength, textLength: text.length)
        return presentation.canShift(edit) ? edit : nil
    }

    /// Оставленное при правке оформление снимается как раньше: стили экрана возвращаются, разбор сбрасывается.
    private func dropKeptPresentation() {
        guard presentationKept else { return }
        // Ключи готового (подсветка кода, картинки, формулы, эмодзи, диаграммы, вставки) уже сдвинуты, а сдвиг не подтверждён: готовое снимается.
        clearReady()
        expandedDetails.removeAll()
        if let visible = visibleRange() { restoreStyles(in: visible) }
        invalidatePresentation(in: visibleRange())
    }

    private func inlineSelection() -> NSRange? {
        guard document?.isReadingMode != true else { return nil }
        guard let textView, let text = textView.textStorage?.mutableString else { return nil }
        let selection = textView.selectedRange()
        guard selection.location <= text.length else { return nil }
        if selectionTouchesImage(selection) { return nil }
        return NSRange(location: selection.location, length: min(selection.length, text.length - selection.location))
    }

    private func revealedRange() -> NSRange? {
        guard document?.isReadingMode != true else { return nil }
        guard let textView, let text = textView.textStorage?.mutableString else { return nil }
        let selection = textView.selectedRange()
        guard selection.location <= text.length else { return nil }
        // Непрозрачные медиа не редактируются внутри оформленного редактора.
        // Раскрытие всей строки здесь временно показывало их полный Markdown
        // перед установкой ресурса. Диаграммы намеренно не входят в этот список:
        // при попадании курсора внутрь диаграммы они должны перейти в текстовый вид.
        if selectionTouchesOpaqueMedia(selection) { return nil }
        let length = min(selection.length, text.length - selection.location)
        let line = text.lineRange(for: NSRange(location: selection.location, length: length))
        // Курсор может стоять перед блочным медиа в той же строке. В этом
        // случае раскрытие строки всё равно показывало бы полный Markdown-код
        // картинки, хотя курсор не находится внутри её диапазона.
        if presentation?.images.contains(where: { image in
            let range = image.isInline ? image.range : image.paragraphRange
            return NSIntersectionRange(line, range).length > 0
        }) == true {
            return nil
        }
        return line
    }

    private func selectionTouchesImage(_ selection: NSRange) -> Bool {
        presentation?.images.contains { image in
            let range = image.isInline ? image.range : image.paragraphRange
            if selection.length == 0 {
                return selection.location >= range.location && selection.location <= NSMaxRange(range)
            }
            return NSIntersectionRange(selection, range).length > 0
        } == true
    }

    private func selectionTouchesOpaqueMedia(_ selection: NSRange) -> Bool {
        guard let presentation else { return false }
        func touches(_ range: NSRange) -> Bool {
            if selection.length == 0 {
                return selection.location >= range.location && selection.location <= NSMaxRange(range)
            }
            return NSIntersectionRange(selection, range).length > 0
        }
        return presentation.images.contains { touches($0.isInline ? $0.range : $0.paragraphRange) }
            || presentation.audioBlocks.contains { touches($0.range) }
            || presentation.iframeBlocks.contains { touches($0.range) }
            || presentation.detailsBlocks.contains { touches($0.range) }
            || presentation.htmlBlocks.contains { touches($0.range) }
            || presentation.formulas.contains { touches($0.range) }
            || presentation.inlineFormulas.contains { touches($0.range) }
    }

    private func intersecting(_ range: NSRange) -> [MarkdownPresentationSpan] {
        let spans = self.spans, prefixEnds = self.prefixEnds
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
        guard let textView else { return nil }
        let rect = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        return characterRange(in: rect)
    }

    private func imageRetentionRange() -> NSRange? {
        guard let textView else { return nil }
        let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        return characterRange(in: visible.insetBy(dx: -visible.width, dy: -visible.height))
    }

    private func characterRange(in rect: NSRect) -> NSRange? {
        guard let textView, let storage = textView.textStorage, let layout,
              let container = textView.textContainer, storage.length > 0 else { return nil }
        let glyphs = layout.glyphRange(
            forBoundingRectWithoutAdditionalLayout: rect,
            in: container
        )
        guard glyphs.length > 0 else { return nil }
        let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard range.location < storage.length else { return nil }
        let visible = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
        return visible.length > 0 ? visible : nil
    }

    private func applyVisible() {
        guard !hasMarkedText, let textView, let storage = textView.textStorage, let layout,
              let visible = visibleRange(), visible != lastVisibleRange else { return }
        refreshMathOptionsIfNeeded()
        lastVisibleRange = visible
        updateAudio(in: visible)
        updateIframes(in: visible)
        updateDetails(in: visible)
        updateHTMLBlocks(in: visible)
        updateRuby(in: visible)
        loadVisibleDiagrams(in: visible)
        loadVisibleImages(in: visible)
        loadVisibleFormulas(in: visible)
        startEmojiResolution()
        loadVisibleCode(in: visible)
        guard let styleRange = unstyledRange(in: visible) else {
            updateFootnoteTooltips(in: visible)
            return
        }
        restoreStyles(in: styleRange)
        applyParagraphAlignment(in: styleRange)
        let matches = intersecting(styleRange)
        var boundaries = [styleRange.location, NSMaxRange(styleRange)]
        var events: [(location: Int, index: Int, start: Bool)] = []
        for (index, span) in matches.enumerated() {
            let part = NSIntersectionRange(span.range, styleRange)
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
                let inlineStyle = inlineStyle(for: active)
                var font = layout.textFont
                let headingLevel = active.compactMap({ span -> Int? in
                    if case .heading(let level) = span.kind { return level }; return nil
                }).first
                if let headingLevel { font = layout.markdownHeadingFont(level: headingLevel) }
                let manager = NSFontManager.shared
                if active.contains(where: { $0.kind == .strong }) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                if active.contains(where: { $0.kind == .emphasis || $0.kind == .quote }) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
                if active.contains(where: { $0.kind == .code || $0.kind == .keyboard || $0.kind == .codeBlock }) {
                    if let codeFont = layout.markdownCodeFont { font = manager.convert(codeFont, toSize: font.pointSize) }
                    else { font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
                }
                if active.contains(where: { $0.kind == .keyboard }) {
                    if active.contains(where: { $0.kind == .strong }) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                    if active.contains(where: { $0.kind == .emphasis || $0.kind == .quote }) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
                }
                if let size = inlineStyle.fontSize { font = manager.convert(font, toSize: CGFloat(size)) }
                let subscriptText = active.contains { $0.kind == .subscriptText }
                let superscriptText = active.contains { $0.kind == .superscriptText }
                if subscriptText || superscriptText {
                    let baseSize = font.pointSize
                    font = NSFontManager.shared.convert(font, toSize: baseSize * 0.75)
                    storage.addAttribute(.baselineOffset, value: baseSize * (subscriptText ? -0.2 : 0.3), range: part)
                }
                if let headingLevel, layout.markdownSmallCapsLevels.contains(headingLevel) {
                    font = layout.smallCapsFont(font) ?? font
                }
                storage.addAttribute(.font, value: font, range: part)
                if active.contains(where: { $0.kind == .strikethrough }) {
                    layout.addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: part)
                }
                if active.contains(where: { $0.kind == .link || $0.kind == .underline }) {
                    layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: part)
                }
                if inlineStyle.background != nil || active.contains(where: { $0.kind == .quote || $0.kind == .code || $0.kind == .keyboard || $0.kind == .codeBlock || $0.kind == .highlight || $0.kind == .yaml }) {
                    let color = backgroundColor(for: active)
                    layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: part)
                    backgroundRanges.append(part)
                }
                if let color = inlineStyle.foreground {
                    layout.addTemporaryAttribute(.foregroundColor, value: color.nsColor, forCharacterRange: part)
                    rememberInlineForeground(part)
                }
            }
        }
        storage.endEditing()
        textView.typingAttributes = typing
        if strikeCompletedTasks, let tasks = presentation?.completedTaskRanges {
            let prefixEnds = completedTaskPrefixEnds
            var low = 0, high = prefixEnds.count
            while low < high {
                let middle = (low + high) / 2
                if prefixEnds[middle] <= styleRange.location { low = middle + 1 } else { high = middle }
            }
            while low < tasks.count && tasks[low].location < NSMaxRange(styleRange) {
                let part = NSIntersectionRange(tasks[low], styleRange)
                if part.length > 0 { layout.addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: part) }
                low += 1
            }
        }
        applyInlineTagColors(in: styleRange, layout: layout)
        var merged = styleRange
        styledRanges = styledRanges.filter { range in
            if NSMaxRange(range) < merged.location || NSMaxRange(merged) < range.location { return true }
            let start = min(range.location, merged.location)
            merged = NSRange(location: start, length: max(NSMaxRange(range), NSMaxRange(merged)) - start)
            return false
        }
        styledRanges.append(merged)
        loadVisibleEmoji(in: styleRange)
        updateUppercaseHeadings(spans: matches)
        layout.invalidateMarkdownLayout(in: styleRange)
        restoreDelimiterHighlight?()
        notifyGeometryChanged()
        updateFootnoteTooltips(in: visible)
        reapplyLinkColors(in: styleRange)
    }

    /// Встроенные `#теги` красятся временным цветом только в оформляемой области; ячейки таблиц рисуют свои представления.
    private func applyInlineTagColors(in range: NSRange, layout: FoldLayoutManager) {
        guard let presentation, let storage = textView?.textStorage else { return }
        let ranges = presentation.emojiCompletionRanges
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        var pieces: [NSRange] = []
        while low < ranges.count && ranges[low].location < NSMaxRange(range) { pieces.append(ranges[low]); low += 1 }
        guard !pieces.isEmpty else { return }
        let raw = storage.mutableString
        guard pieces.contains(where: { raw.range(of: "#", options: .literal, range: $0).location != NSNotFound }) else { return }
        let extent = NSRange(location: pieces[0].location, length: NSMaxRange(pieces[pieces.count - 1]) - pieces[0].location)
        let excluded = presentation.links.map(\.range).filter { NSIntersectionRange($0, extent).length > 0 }
            + presentation.wikiLinks.map(\.range).filter { NSIntersectionRange($0, extent).length > 0 }
        guard let tags = try? MarkdownTagReader.inlineTags(in: storage.mutableString, textRanges: pieces, excluding: excluded) else { return }
        for tag in tags where !presentation.tables.contains(where: { NSIntersectionRange($0.range, tag.range).length > 0 }) {
            let part = NSIntersectionRange(tag.range, range)
            guard part.length > 0 else { continue }
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.lacTagText, forCharacterRange: part)
            rememberInlineForeground(part)
        }
    }

    private func unstyledRange(in visible: NSRange) -> NSRange? {
        var start = visible.location
        let end = NSMaxRange(visible)
        for range in styledRanges.sorted(by: { $0.location < $1.location }) {
            guard range.location <= start else { break }
            start = max(start, min(NSMaxRange(range), end))
            if start >= end { return nil }
        }
        return NSRange(location: start, length: end - start)
    }

    private func updateUppercaseHeadings(spans: [MarkdownPresentationSpan]) {
        guard uppercaseSnapshotReady, !uppercaseHeadingLevels.isEmpty, !hasMarkedText,
              let layout, let textView, let container = textView.textContainer,
              currentRevision?() == revision else {
            clearUppercaseHeadings()
            return
        }
        var candidates: [MarkdownHeading] = []
        for span in spans {
            guard case .heading = span.kind, let heading = uppercaseHeadings[span.range.location],
                  heading.range == span.range, uppercaseHeadingLevels.contains(heading.level),
                  heading.uppercaseRuns != nil, layout.canDisplayMarkdownMedia(heading.range),
                  heading.emoji.isEmpty || (emojiValues != nil && !uppercaseEmojiResolutionFailed) else { continue }
            candidates.append(heading)
        }
        let wanted = Set(candidates.map(\.range))
        for range in uppercaseInstalled.subtracting(wanted) {
            layout.removePlainUppercaseHeading(for: range)
            uppercaseInstalled.remove(range)
        }
        for heading in candidates where !uppercaseInstalled.contains(heading.range) {
            guard let runs = heading.uppercaseRuns else { continue }
            var images: [NSRange: NSImage] = [:], ready = true
            for run in runs where run.attachment != nil {
                guard let range = run.pieces.first?.sourceRange,
                      let image = layout.markdownInlineImage(for: range) else { ready = false; break }
                images[range] = image
            }
            guard ready else { continue }
            let available = min(container.containerSize.width, textView.visibleRect.width)
                - 2 * container.lineFragmentPadding - layout.markdownMediaIndent(for: heading.range)
            guard available > 0, available.isFinite else { continue }
            if layout.setUppercaseHeading(heading.range, runs: runs, width: available, level: heading.level, attachmentImages: images) {
                uppercaseInstalled.insert(heading.range)
            }
        }
    }

    private func retryUppercaseHeading(for range: NSRange) {
        guard uppercaseSnapshotReady, !uppercaseHeadingLevels.isEmpty, !hasMarkedText,
              let layout, let visible = visibleRange(), NSIntersectionRange(visible, range).length > 0 else { return }
        for span in intersecting(range) {
            guard case .heading = span.kind, let heading = uppercaseHeadings[span.range.location],
                  uppercaseHeadingLevels.contains(heading.level), let runs = heading.uppercaseRuns,
                  heading.emoji.isEmpty || (emojiValues != nil && !uppercaseEmojiResolutionFailed) else { continue }
            let ready = runs.allSatisfy { run in
                run.attachment == nil || run.pieces.first.flatMap { layout.markdownInlineImage(for: $0.sourceRange) } != nil
            }
            guard ready else { continue }
            if uppercaseInstalled.remove(heading.range) != nil { layout.removePlainUppercaseHeading(for: heading.range) }
            lastVisibleRange = nil
            applyVisible()
            return
        }
    }

    private func suspendUppercaseHeading(for range: NSRange) {
        guard uppercaseSnapshotReady, !uppercaseHeadingLevels.isEmpty, let layout else { return }
        for span in intersecting(range) {
            guard case .heading = span.kind, let heading = uppercaseHeadings[span.range.location],
                  uppercaseInstalled.remove(heading.range) != nil else { continue }
            layout.removePlainUppercaseHeading(for: heading.range)
        }
    }

    private func applyParagraphAlignment(in visible: NSRange) {
        guard let textView, let storage = textView.textStorage, let layout, storage.length > 0,
              layout.markdownTextAlignment != nil || layout.markdownRightToLeft || !layout.markdownCenteredHeadingLevels.isEmpty || headingNumbering else { return }
        let range = storage.mutableString.lineRange(for: visible)
        restoreParagraphAlignment(in: range)
        let headings = intersecting(range).compactMap { span -> NSRange? in
            guard case let .heading(level) = span.kind, layout.markdownCenteredHeadingLevels.contains(level) else { return nil }
            return NSIntersectionRange(storage.mutableString.lineRange(for: span.range), range)
        }.filter { $0.length > 0 }
        let numbered: [(NSRange, CGFloat, Int)] = intersecting(range).compactMap { span in
            guard case .heading = span.kind, let heading = layout.markdownNumberedHeading(at: span.range.location),
                  let number = heading.number,
                  !(lastRevealedRange.map { NSIntersectionRange(heading.range, $0).length > 0 } ?? false) else { return nil }
            let line = storage.mutableString.lineRange(for: NSRange(location: span.range.location, length: 0))
            let part = NSIntersectionRange(line, range)
            guard part.length > 0 else { return nil }
            var attributes: [NSAttributedString.Key: Any] = [.font: layout.markdownHeadingFont(level: heading.level)]
            if textView.layoutOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
            let width = (number as NSString).size(withAttributes: attributes).width
            layout.setMarkdownHeadingNumberWidth(nil, at: heading.range.location)
            return (part, width, heading.range.location)
        }
        var boundaries = [range.location, NSMaxRange(range)]
        for heading in headings { boundaries.append(heading.location); boundaries.append(NSMaxRange(heading)) }
        for (heading, _, _) in numbered { boundaries.append(heading.location); boundaries.append(NSMaxRange(heading)) }
        boundaries = Array(Set(boundaries)).sorted()
        var runs: [(NSRange, NSParagraphStyle?, NSTextAlignment?, CGFloat, Int?)] = []
        var headingIndex = 0
        var numberIndex = 0
        for index in 0..<(boundaries.count - 1) {
            let part = NSRange(location: boundaries[index], length: boundaries[index + 1] - boundaries[index])
            while headingIndex < headings.count && NSMaxRange(headings[headingIndex]) <= part.location { headingIndex += 1 }
            let centered = headingIndex < headings.count && NSIntersectionRange(headings[headingIndex], part).length > 0
            while numberIndex < numbered.count && NSMaxRange(numbered[numberIndex].0) <= part.location { numberIndex += 1 }
            let numberWidth = numberIndex < numbered.count && NSIntersectionRange(numbered[numberIndex].0, part).length > 0 ? numbered[numberIndex].1 : 0
            let numberLocation = numberWidth > 0 ? numbered[numberIndex].2 : nil
            let alignment = centered ? NSTextAlignment.center : layout.markdownTextAlignment
            guard alignment != nil || layout.markdownRightToLeft || numberWidth > 0 else { continue }
            storage.enumerateAttribute(.paragraphStyle, in: part) { value, attributeRange, _ in
                runs.append((attributeRange, value as? NSParagraphStyle, alignment, numberWidth, numberLocation))
            }
        }
        let typing = textView.typingAttributes
        var numberWidths: [Int: CGFloat] = [:]
        for (_, original, _, numberWidth, numberLocation) in runs {
            guard let numberLocation else { continue }
            let style = original ?? NSParagraphStyle.default
            let available = max(0, (textView.textContainer?.size.width ?? 0) - 2 * (textView.textContainer?.lineFragmentPadding ?? 0) - max(style.firstLineHeadIndent, style.headIndent) - 1)
            let width = min(numberWidth, available)
            numberWidths[numberLocation] = min(numberWidths[numberLocation] ?? width, width)
        }
        for (location, width) in numberWidths { layout.setMarkdownHeadingNumberWidth(width, at: location) }
        storage.beginEditing()
        for (part, original, alignment, _, numberLocation) in runs {
            let style = original ?? NSParagraphStyle.default
            let changeAlignment = alignment.map { style.alignment != $0 } ?? false
            let changeDirection = layout.markdownRightToLeft && style.baseWritingDirection != .rightToLeft
            let indent = numberLocation.flatMap { numberWidths[$0] } ?? 0
            guard changeAlignment || changeDirection || indent > 0, let changed = style.mutableCopy() as? NSMutableParagraphStyle else { continue }
            let origin = ParagraphStyleOrigin(alignment: original?.alignment.rawValue, direction: original?.baseWritingDirection.rawValue,
                                              firstLineIndent: original?.firstLineHeadIndent, headIndent: original?.headIndent)
            alignedRanges[origin, default: IndexSet()].insert(integersIn: part.location..<NSMaxRange(part))
            if let alignment { changed.alignment = alignment }
            if layout.markdownRightToLeft { changed.baseWritingDirection = .rightToLeft }
            changed.firstLineHeadIndent += indent
            changed.headIndent += indent
            storage.addAttribute(.paragraphStyle, value: changed, range: part)
        }
        storage.endEditing()
        textView.typingAttributes = typing
    }

    private func restoreParagraphAlignment(in requested: NSRange? = nil) {
        guard let textView, let storage = textView.textStorage else { return }
        let target = requested.map { NSIntersectionRange($0, NSRange(location: 0, length: storage.length)) }
            ?? NSRange(location: 0, length: storage.length)
        let targetIndexes = IndexSet(integersIn: target.location..<NSMaxRange(target))
        let typing = textView.typingAttributes
        storage.beginEditing()
        for key in Array(alignedRanges.keys) {
            guard let indexes = alignedRanges[key] else { continue }
            let overlap = indexes.intersection(targetIndexes)
            for slice in overlap.rangeView {
                let range = NSRange(location: slice.lowerBound, length: slice.count)
                if key.alignment == nil && key.direction == nil {
                    storage.removeAttribute(.paragraphStyle, range: range)
                } else if let alignmentValue = key.alignment, let directionValue = key.direction,
                          let firstLineIndent = key.firstLineIndent, let headIndent = key.headIndent,
                          let original = NSTextAlignment(rawValue: alignmentValue),
                          let direction = NSWritingDirection(rawValue: directionValue) {
                    var runs: [(NSRange, NSParagraphStyle)] = []
                    storage.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                        runs.append((part, (value as? NSParagraphStyle) ?? NSParagraphStyle.default))
                    }
                    for (part, style) in runs where style.alignment != original || style.baseWritingDirection != direction || style.firstLineHeadIndent != firstLineIndent || style.headIndent != headIndent {
                        guard let changed = style.mutableCopy() as? NSMutableParagraphStyle else { continue }
                        changed.alignment = original
                        changed.baseWritingDirection = direction
                        changed.firstLineHeadIndent = firstLineIndent
                        changed.headIndent = headIndent
                        storage.addAttribute(.paragraphStyle, value: changed, range: part)
                    }
                }
            }
            alignedRanges[key]?.subtract(overlap)
        }
        storage.endEditing()
        textView.typingAttributes = typing
    }

    func paragraphStylesDidChange(in range: NSRange) {
        let indexes = IndexSet(integersIn: range.location..<NSMaxRange(range))
        for key in Array(alignedRanges.keys) { alignedRanges[key]?.subtract(indexes) }
        guard enabled, !hasMarkedText, let visible = visibleRange(), NSIntersectionRange(visible, range).length > 0 else { return }
        lastVisibleRange = nil
        applyVisible()
    }

    private func mediaRect(for range: NSRange, size: NSSize, inline: Bool,
                           layout: FoldLayoutManager, container: NSTextContainer) -> NSRect? {
        if inline {
            if layout.markdownInlineImage(for: range)?.size != size {
                guard layout.setMarkdownInlineImage(NSImage(size: size), for: range) else { return nil }
            }
            return layout.markdownRenderedImageRects(for: [range], in: container)[range]
        }
        layout.setMarkdownMediaSize(size, for: range)
        return layout.markdownMediaRect(for: range, in: container)
    }

    private func clearMediaGeometry(_ range: NSRange, layout: FoldLayoutManager) {
        layout.setMarkdownMediaSize(nil, for: range)
        layout.removeMarkdownInlineImage(for: range)
    }

    private func notifyGeometryChanged() {
        if !hasMarkedText, let layout, let textView, let container = textView.textContainer {
            let imageRects = layout.markdownRenderedImageRects(for: Set(animatedImages.keys), in: container, editingCell: editingTableCell)
            for (range, view) in animatedImages {
                guard let rect = imageRects[range],
                      rect.intersects(textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)) else {
                    view.animates = false
                    view.removeFromSuperview()
                    continue
                }
                if view.superview !== textView { textView.addSubview(view) }
                textView.placeMarkdownSubview(view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
                view.animates = true
            }
            let inlineMedia = Set((presentation?.audioBlocks ?? []).filter(\.isInline).map(\.range))
            let inlineRects = layout.markdownRenderedImageRects(for: inlineMedia, in: container)
            for range in Array(audioViews.keys) {
                guard let view = audioViews[range] else { continue }
                let rect = inlineMedia.contains(range) ? inlineRects[range] : layout.markdownMediaRect(for: range, in: container)
                if let rect {
                    if view.superview !== textView { textView.addSubview(view) }
                    textView.placeMarkdownSubview(view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
                } else {
                    view.player?.pause()
                    view.removeFromSuperview()
                }
            }
        }
        if let visible = visibleRange() { updateIframes(in: visible); updateDetails(in: visible); updateHTMLBlocks(in: visible) }
        geometryDidChange?()
    }

    private func clearAnimatedImages() {
        for view in animatedImages.values { view.animates = false; view.removeFromSuperview() }
        animatedImages.removeAll()
    }

    /// Останавливает загрузки аудио и отрисовку ruby, которые ещё идут; готовые плееры, вью и картинки не трогает.
    private func cancelMediaJobs() {
        for (_, job) in rubyJobs { job.2.cancel() }
        rubyJobs.removeAll()
        for job in audioJobs.values { job.1.cancel() }
        audioJobs.removeAll()
    }

    private func clearAudio() {
        clearRuby()
        clearIframes()
        clearDetails()
        clearHTMLBlocks()
        for job in audioJobs.values { job.1.cancel() }
        audioJobs.removeAll()
        for (range, view) in audioViews {
            view.player?.pause()
            view.player = nil
            view.removeFromSuperview()
            if !hasMarkedText, let layout { clearMediaGeometry(range, layout: layout) }
        }
        audioViews.removeAll()
        audioCompleted.removeAll()
        if !hasMarkedText { layout?.clearMarkdownMedia() }
    }

    private func clearRuby() {
        for (_, job) in rubyJobs { job.2.cancel() }
        rubyJobs.removeAll()
        guard !hasMarkedText, let layout else { return }
        for range in rubyRendered.keys { layout.removeMarkdownInlineImage(for: range) }
        rubyRendered.removeAll()
    }

    private static func rubyColor(_ textView: LacTextView, layout: FoldLayoutManager) -> NSColor? {
        var value: NSColor?
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            value = (layout.markdownColors.text?.nsColor ?? NSColor.textColor).usingColorSpace(.sRGB)
        }
        return value
    }

    private func updateRuby(in visible: NSRange) {
        guard !hasMarkedText, enabled, isActive, let presentation, let document,
              let layout, let textView, let container = textView.textContainer else { return }
        guard let color = Self.rubyColor(textView, layout: layout) else { clearRuby(); return }
        let font = layout.textFont
        let scale = textView.window?.backingScaleFactor ?? 1
        let vertical = container.layoutOrientation == .vertical
        let available = textView.visibleRect.size
        let items = presentation.ruby.filter { NSIntersectionRange($0.range, visible).length > 0 && layout.canDisplayMarkdownMedia($0.range) }
        let needed = Set(items.map(\.range))
        for (range, job) in rubyJobs where !needed.contains(range) { job.2.cancel(); rubyJobs.removeValue(forKey: range) }
        for range in Array(rubyRendered.keys) where !needed.contains(range) {
            layout.removeMarkdownInlineImage(for: range); rubyRendered.removeValue(forKey: range)
        }
        for item in items {
            let outer = intersecting(item.range).filter { NSIntersectionRange($0.range, item.range) == item.range }
            let inline = inlineStyle(for: outer)
            if inline.background != nil || inline.fontSizeRem != nil {
                rubyJobs.removeValue(forKey: item.range)?.2.cancel()
                if rubyRendered.removeValue(forKey: item.range) != nil { layout.removeMarkdownInlineImage(for: item.range) }
                continue
            }
            var parentFont = font
            if outer.contains(where: { $0.kind == .strong }) { parentFont = NSFontManager.shared.convert(parentFont, toHaveTrait: .boldFontMask) }
            if outer.contains(where: { $0.kind == .emphasis || $0.kind == .quote }) { parentFont = NSFontManager.shared.convert(parentFont, toHaveTrait: .italicFontMask) }
            let parentColor = inline.foreground?.nsColor ?? color
            let key = RubyKey(item: item, font: font, color: color, parentFont: parentFont, parentColor: parentColor,
                              scale: scale, vertical: vertical, available: available)
            if rubyRendered[item.range] == key { continue }
            if rubyRendered.removeValue(forKey: item.range) != nil { layout.removeMarkdownInlineImage(for: item.range) }
            if let previous = rubyJobs[item.range], previous.1 != key { previous.2.cancel(); rubyJobs.removeValue(forKey: item.range) }
            guard rubyJobs[item.range] == nil else { continue }
            let token = UUID(), generation = self.generation, revision = self.revision
            let task = Task { @MainActor [weak self, weak document, weak layout, weak textView] in
                guard let self, let document, let layout, let textView else { return }
                defer { if self.rubyJobs[item.range]?.0 == token { self.rubyJobs.removeValue(forKey: item.range) } }
                @MainActor func currentGeometry() -> Bool {
                    guard let container = textView.textContainer else { return false }
                    return layout.textFont == key.font && Self.rubyColor(textView, layout: layout) == key.color &&
                        (textView.window?.backingScaleFactor ?? 1) == key.scale &&
                        (container.layoutOrientation == .vertical) == key.vertical && textView.visibleRect.size == key.available
                }
                guard !Task.isCancelled, self.document === document, self.enabled, self.isActive, !self.hasMarkedText,
                      self.generation == generation, self.currentRevision?() == revision,
                      self.presentation?.ruby.contains(item) == true, layout.canDisplayMarkdownMedia(item.range),
                      currentGeometry() else { return }
                guard let displayBase = MarkdownHTMLMediaService.rubyDisplayText(item.base, isCancelled: { Task.isCancelled }),
                      let displayReading = MarkdownHTMLMediaService.rubyDisplayText(item.reading, isCancelled: { Task.isCancelled }) else { return }
                let base = NSMutableAttributedString(string: displayBase, attributes: [.font: key.parentFont, .foregroundColor: key.parentColor])
                if !item.baseRuns.isEmpty {
                    guard displayBase.utf16.elementsEqual(item.base.utf16) else { return }
                    var offset = 0
                    for run in item.baseRuns {
                        guard !Task.isCancelled, run.range.location == offset, run.range.length > 0,
                              run.range.length <= base.length - offset else { return }
                        var runFont = key.parentFont
                        if run.bold { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                        if run.italic { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                        base.addAttribute(.font, value: runFont, range: run.range)
                        if let foreground = run.foreground { base.addAttribute(.foregroundColor, value: foreground.nsColor, range: run.range) }
                        offset = NSMaxRange(run.range)
                    }
                    guard offset == base.length else { return }
                }
                guard let rendering = MarkdownRubyRenderService.render(base: base, annotation: displayReading, scale: scale,
                    availableSize: available, orientation: vertical ? .vertical : .horizontal,
                    annotationFont: item.baseRuns.isEmpty ? nil : key.parentFont, annotationColor: item.baseRuns.isEmpty ? nil : key.parentColor), !Task.isCancelled,
                      self.generation == generation, self.currentRevision?() == revision, !self.hasMarkedText,
                      layout.canDisplayMarkdownMedia(item.range), currentGeometry() else { return }
                if layout.setMarkdownInlineImage(rendering.image, for: item.range, rubyBaseline: rendering.baseline) {
                    self.rubyRendered[item.range] = key
                    self.notifyGeometryChanged()
                }
            }
            rubyJobs[item.range] = (token, key, task)
        }
    }

    private func clearIframes() {
        for (range, entry) in iframeViews {
            entry.view.stopLoading()
            entry.view.navigationDelegate = nil
            entry.view.removeFromSuperview()
            if !hasMarkedText, let layout { clearMediaGeometry(range, layout: layout) }
        }
        iframeViews.removeAll()
    }

    private func clearDetails() {
        for (range, view) in detailsViews {
            view.onToggle = nil; view.revealSource = nil
            view.removeFromSuperview()
            if !hasMarkedText, let layout { clearMediaGeometry(range, layout: layout) }
        }
        detailsViews.removeAll()
    }

    private func clearHTMLBlocks() {
        for (range, entry) in htmlBlockViews {
            entry.view.invalidate(); entry.view.removeFromSuperview()
            if !hasMarkedText, let layout { clearMediaGeometry(range, layout: layout) }
        }
        htmlBlockViews.removeAll()
    }

    private func htmlParagraphStyle(textView: LacTextView, layout: FoldLayoutManager) -> NSParagraphStyle {
        let style = (textView.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        if let alignment = layout.markdownTextAlignment { style.alignment = alignment }
        if layout.markdownRightToLeft { style.baseWritingDirection = .rightToLeft }
        style.lineSpacing = layout.editorLineSpacing
        return style
    }

    private func updateHTMLBlocks(in visible: NSRange) {
        guard !hasMarkedText, enabled, isActive, let presentation, let document,
              let layout, let textView, let container = textView.textContainer else { return }
        let vertical = container.layoutOrientation == .vertical
        let blocks = presentation.htmlBlocks.filter {
            NSIntersectionRange($0.range, visible).length > 0 && layout.canDisplayMarkdownMedia($0.range)
        }
        let ranges = Set(blocks.map(\.range))
        for range in Array(htmlBlockViews.keys) where !ranges.contains(range) {
            if let entry = htmlBlockViews.removeValue(forKey: range) {
                entry.view.invalidate(); entry.view.removeFromSuperview(); clearMediaGeometry(range, layout: layout)
            }
        }
        var foreground: NSColor?, linkColor: NSColor?
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            foreground = (layout.markdownColors.text?.nsColor ?? textView.textColor ?? NSColor.textColor).usingColorSpace(.sRGB)
            linkColor = (layout.markdownColors.link?.nsColor ?? NSColor.linkColor).usingColorSpace(.sRGB)
        }
        guard let foreground, let linkColor else { clearHTMLBlocks(); return }
        let font = textView.font ?? layout.textFont
        let codeFont = layout.markdownCodeFont
        let paragraphStyle = htmlParagraphStyle(textView: textView, layout: layout)
        for block in blocks {
            let indent = layout.markdownMediaIndent(for: block.range)
            let available = (vertical ? (textView.enclosingScrollView?.contentView.bounds.width ?? container.size.width) :
                min(container.size.width, textView.visibleRect.width)) - 2 * container.lineFragmentPadding - indent
            let width = floor(available)
            guard width.isFinite, width > 0 else {
                if let old = htmlBlockViews.removeValue(forKey: block.range) {
                    old.view.invalidate(); old.view.removeFromSuperview(); clearMediaGeometry(block.range, layout: layout)
                }
                continue
            }
            if let old = htmlBlockViews[block.range], old.block != block ||
                old.font != font || old.codeFont != codeFont || old.paragraphStyle != paragraphStyle ||
                old.foreground != foreground || old.linkColor != linkColor || old.vertical != vertical {
                old.view.invalidate(); old.view.removeFromSuperview(); clearMediaGeometry(block.range, layout: layout)
                htmlBlockViews.removeValue(forKey: block.range)
            }
            if htmlBlockViews[block.range] == nil {
                let view = MarkdownHTMLBlockView(frame: .zero)
                guard view.configure(confirmedHTML: block.html, font: font, foreground: foreground, linkColor: linkColor,
                                     codeFont: codeFont, paragraphStyle: paragraphStyle),
                      let size = view.measuredSize(width: width),
                      let rect = mediaRect(for: block.range, size: size, inline: false, layout: layout, container: container) else {
                    clearMediaGeometry(block.range, layout: layout); continue
                }
                htmlBlockViews[block.range] = HTMLBlockView(block: block, view: view,
                                                           font: font, codeFont: codeFont, paragraphStyle: paragraphStyle,
                                                           foreground: foreground, linkColor: linkColor, vertical: vertical)
                // Вью переживает правки выше него: блок и позицию берём из записи по самому вью, а не из запомненных значений.
                let current = { [weak self, weak document, weak view, weak layout] () -> NSRange? in
                    guard let self, let document, let view, let layout,
                          self.document === document, self.enabled, self.isActive, !self.hasMarkedText,
                          self.currentRevision?() == self.revision,
                          let (range, entry) = self.htmlBlockViews.first(where: { $0.value.view === view }),
                          self.presentation?.htmlBlocks.contains(entry.block) == true,
                          layout.canDisplayMarkdownMedia(range) else { return nil }
                    return range
                }
                view.canInteract = { current() != nil }
                view.revealSource = { [weak self, weak textView] in
                    guard let self, let textView, let range = current() else { return }
                    textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
                    textView.window?.makeFirstResponder(textView)
                    if let visible = self.visibleRange() { self.updateHTMLBlocks(in: visible) }
                }
                view.openLink = { [weak self] address in guard let self, let range = current() else { return }; self.htmlBlockLink?(address, range) }
                textView.addSubview(view)
                textView.placeMarkdownSubview(view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
                geometryDidChange?()
            } else if let entry = htmlBlockViews[block.range] {
                guard let size = entry.view.measuredSize(width: width),
                      let rect = mediaRect(for: block.range, size: size, inline: false, layout: layout, container: container) else {
                    entry.view.invalidate(); entry.view.removeFromSuperview(); htmlBlockViews.removeValue(forKey: block.range)
                    clearMediaGeometry(block.range, layout: layout); continue
                }
                textView.placeMarkdownSubview(entry.view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
            }
        }
    }

    private func updateDetails(in visible: NSRange) {
        guard !hasMarkedText, enabled, isActive, let presentation, let document,
              let layout, let textView, let container = textView.textContainer else { return }
        let blocks = presentation.detailsBlocks.filter {
            NSIntersectionRange($0.range, visible).length > 0 && layout.canDisplayMarkdownMedia($0.range)
        }
        let ranges = Set(blocks.map(\.range))
        for range in Array(detailsViews.keys) where !ranges.contains(range) {
            if let view = detailsViews.removeValue(forKey: range) {
                view.onToggle = nil; view.revealSource = nil
                view.removeFromSuperview()
                clearMediaGeometry(range, layout: layout)
            }
        }
        for block in blocks {
            let indent = layout.markdownMediaIndent(for: block.range)
            let available = max(1, (container.layoutOrientation == .vertical
                ? (textView.enclosingScrollView?.contentView.bounds.width ?? container.size.width)
                : container.size.width) - 2 * container.lineFragmentPadding - indent)
            let width = container.layoutOrientation == .vertical ? available :
                (textView.visibleRect.width > 0 ? min(available, max(1, textView.visibleRect.width - 2 * container.lineFragmentPadding - indent)) : available)
            let view: MarkdownDetailsView
            if let current = detailsViews[block.range] { view = current }
            else {
                let created = MarkdownDetailsView(block: block)
                detailsViews[block.range] = created
                view = created
            }
            let generation = self.generation, revision = self.revision
            view.revealSource = { [weak self, weak document] in
                guard let self, let document, self.document === document, self.enabled, self.isActive, !self.hasMarkedText,
                      self.generation == generation, self.currentRevision?() == revision,
                      self.presentation?.detailsBlocks.contains(block) == true, let textView = self.textView else { return }
                textView.setSelectedRange(block.range)
                textView.scrollRangeToVisible(block.range)
                textView.window?.makeFirstResponder(textView)
            }
            view.onToggle = { [weak self, weak document] open in
                guard let self, let document, self.document === document, self.enabled, self.isActive, !self.hasMarkedText,
                      self.generation == generation, self.currentRevision?() == revision,
                      self.presentation?.detailsBlocks.contains(block) == true else { return false }
                self.expandedDetails[block.range] = open
                if let visible = self.visibleRange() { self.updateDetails(in: visible) }
                return true
            }
            view.canInteract = { [weak self, weak document, weak layout] in
                guard let self, let document, let layout else { return false }
                return self.document === document && self.enabled && self.isActive && !self.hasMarkedText &&
                    self.generation == generation && self.currentRevision?() == revision &&
                    self.presentation?.detailsBlocks.contains(block) == true && layout.canDisplayMarkdownMedia(block.range)
            }
            view.openLink = { [weak self, weak view] address in
                guard let self, let view, view.canInteract?() == true else { return }
                self.htmlBlockLink?(address, block.range)
            }
            var foreground: NSColor?, linkColor: NSColor?
            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                foreground = (layout.markdownColors.text?.nsColor ?? textView.textColor ?? NSColor.textColor).usingColorSpace(.sRGB)
                linkColor = (layout.markdownColors.link?.nsColor ?? NSColor.linkColor).usingColorSpace(.sRGB)
            }
            guard let foreground, let linkColor,
                  let size = view.configure(width: width, font: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                            foreground: foreground, linkColor: linkColor,
                                            codeFont: layout.markdownCodeFont, paragraphStyle: htmlParagraphStyle(textView: textView, layout: layout),
                                            open: expandedDetails[block.range] ?? block.initiallyOpen) else {
                detailsViews.removeValue(forKey: block.range); view.removeFromSuperview()
                clearMediaGeometry(block.range, layout: layout); continue
            }
            if let rect = mediaRect(for: block.range, size: size, inline: false, layout: layout, container: container) {
                if view.superview !== textView { textView.addSubview(view) }
                textView.placeMarkdownSubview(view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
            }
        }
    }

    private func iframeDimension(_ value: String?, available: CGFloat, fallback: CGFloat) -> CGFloat? {
        guard let value else { return fallback }
        let percentage = value.hasSuffix("%")
        let numeric = percentage ? String(value.dropLast()) : (value.hasSuffix("px") ? String(value.dropLast(2)) : value)
        guard let number = Double(numeric), number.isFinite, number > 0 else { return nil }
        let result = percentage ? available * CGFloat(number / 100) : CGFloat(number)
        return result.isFinite && result > 0 ? result : nil
    }

    private func mediaWidth(_ block: MarkdownAudioBlock, container: NSTextContainer) -> CGFloat? {
        var available = container.layoutOrientation == .vertical
            ? max(1, container.textView?.enclosingScrollView?.contentView.bounds.width ?? container.size.width)
            : max(1, container.size.width - 2 * container.lineFragmentPadding)
        if block.isInline, container.layoutOrientation != .vertical, let visible = container.textView?.visibleRect.width, visible > 0 {
            available = min(available, max(1, visible - 2 * container.lineFragmentPadding))
        }
        let width = max(1, available - (layout?.markdownMediaIndent(for: block.range) ?? 0))
        guard block.media.kind == .video else { return width }
        guard let requested = iframeDimension(block.media.width, available: width, fallback: min(560, width)) else { return nil }
        return block.isInline ? min(requested, width) : requested
    }

    private func mediaHeight(_ block: MarkdownAudioBlock, textView: NSTextView) -> CGFloat? {
        guard block.media.kind == .video else { return 64 }
        let available = textView.enclosingScrollView?.contentView.bounds.height ?? textView.visibleRect.height
        return iframeDimension(block.media.height, available: available, fallback: 315)
    }

    private func updateIframes(in visible: NSRange) {
        guard !hasMarkedText, enabled, isActive, let presentation, let document,
              let layout, let textView, let container = textView.textContainer else { return }
        let blocks = presentation.iframeBlocks.filter {
            NSIntersectionRange($0.range, visible).length > 0 && layout.canDisplayMarkdownMedia($0.range)
        }
        let ranges = Set(blocks.map(\.range))
        for range in Array(iframeViews.keys) where !ranges.contains(range) {
            if let entry = iframeViews.removeValue(forKey: range) {
                entry.view.stopLoading()
                entry.view.navigationDelegate = nil
                entry.view.removeFromSuperview()
                clearMediaGeometry(range, layout: layout)
            }
        }
        let availableWidth = container.layoutOrientation == .vertical
            ? max(1, textView.enclosingScrollView?.contentView.bounds.width ?? container.size.width)
            : max(1, container.size.width - 2 * container.lineFragmentPadding)
        let availableHeight = textView.enclosingScrollView?.contentView.bounds.height ?? textView.visibleRect.height
        for block in blocks {
            let indent = layout.markdownMediaIndent(for: block.range)
            var widthAvailable = max(1, availableWidth - indent)
            if block.isInline, container.layoutOrientation != .vertical, textView.visibleRect.width > 0 {
                widthAvailable = min(widthAvailable, max(1, textView.visibleRect.width - 2 * container.lineFragmentPadding - indent))
            }
            guard let requestedWidth = iframeDimension(block.width, available: widthAvailable, fallback: block.isInline || indent > 0 ? min(560, widthAvailable) : 560),
                  let height = iframeDimension(block.height, available: availableHeight, fallback: 315) else { continue }
            let width = block.isInline ? min(requestedWidth, widthAvailable) : requestedWidth
            // Разбор вернул на этот ключ другой iframe: старый снимается, ниже создаётся новый.
            if let old = iframeViews[block.range], old.block != block {
                old.view.stopLoading()
                old.view.navigationDelegate = nil
                old.view.removeFromSuperview()
                clearMediaGeometry(block.range, layout: layout)
                iframeViews.removeValue(forKey: block.range)
            }
            if iframeViews[block.range] == nil {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
                // Вью переживает правки выше него: запись ищем по самому вью, запомненные блок и позиция устарели бы после первого сдвига.
                let navigation = MarkdownIframeNavigation { [weak self, weak document, weak view] in
                    guard let self, let document, let view, let entry = self.iframeViews.values.first(where: { $0.view === view }) else { return false }
                    return self.document === document && self.enabled && self.isActive &&
                        self.currentRevision?() == self.revision && !self.hasMarkedText &&
                        self.presentation?.iframeBlocks.contains(entry.block) == true
                }
                view.navigationDelegate = navigation
                view.setAccessibilityLabel(block.title ?? L10n.tr("嵌入内容"))
                view.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: L10n.tr("编辑源代码")) { [weak self, weak document, weak view] in
                    guard let self, let document, let view, self.document === document,
                          self.currentRevision?() == self.revision, self.enabled, self.isActive, !self.hasMarkedText,
                          let (range, entry) = self.iframeViews.first(where: { $0.value.view === view }),
                          self.presentation?.iframeBlocks.contains(entry.block) == true, let textView = self.textView else { return false }
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                    textView.window?.makeFirstResponder(textView)
                    return true
                }])
                iframeViews[block.range] = IframeView(block: block, view: view, navigation: navigation, height: height)
                if let rect = mediaRect(for: block.range, size: NSSize(width: width, height: height), inline: block.isInline, layout: layout, container: container) {
                    textView.addSubview(view)
                    textView.placeMarkdownSubview(view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
                }
                let html = """
                <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src http: https:; style-src 'unsafe-inline'"><style>html,body{margin:0;width:100%;height:100%}iframe{width:100%!important;height:100%!important;box-sizing:border-box}</style></head><body>\(block.html)</body></html>
                """
                view.loadHTMLString(html, baseURL: nil)
            } else if var entry = iframeViews[block.range] {
                if entry.height != height {
                    entry.height = height
                    iframeViews[block.range] = entry
                }
                if let rect = mediaRect(for: block.range, size: NSSize(width: width, height: height), inline: block.isInline, layout: layout, container: container) {
                    if entry.view.superview !== textView { textView.addSubview(entry.view) }
                    textView.placeMarkdownSubview(entry.view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
                }
            }
        }
    }

    private func updateAudio(in visible: NSRange) {
        guard !hasMarkedText, enabled, isActive, let presentation, let document,
              let layout, let textView, let container = textView.textContainer else { return }
        let blocks = presentation.audioBlocks.filter {
            NSIntersectionRange($0.range, visible).length > 0 && layout.canDisplayMarkdownMedia($0.range)
        }
        let ranges = Set(blocks.map(\.range))
        for range in Array(audioViews.keys) where !ranges.contains(range) {
            let view = audioViews.removeValue(forKey: range)
            view?.player?.pause()
            view?.player = nil
            view?.removeFromSuperview()
            clearMediaGeometry(range, layout: layout)
        }
        for range in Array(audioJobs.keys) where !ranges.contains(range) {
            audioJobs.removeValue(forKey: range)?.1.cancel()
        }
        audioCompleted.formIntersection(ranges)
        for block in blocks {
            guard let width = mediaWidth(block, container: container), let height = mediaHeight(block, textView: textView) else { continue }
            if let view = audioViews[block.range] {
                guard let rect = mediaRect(for: block.range, size: NSSize(width: width, height: height), inline: block.isInline, layout: layout, container: container) else { continue }
                if view.superview !== textView { textView.addSubview(view) }
                textView.placeMarkdownSubview(view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
                continue
            }
            guard !audioCompleted.contains(block.range), audioJobs[block.range] == nil else { continue }
            let baseURL = document.url
            let paths = resourcePaths, rootInvalid = resourceRootInvalid
            let generation = self.generation, revision = self.revision, token = UUID()
            let isPlayable = audioAssetIsPlayable
            let task = Task { @MainActor [weak self, weak document] in
                defer { self?.audioJobDidFinish?(block.range) }
                var selected: AVURLAsset?
                for source in block.media.sources {
                    guard !Task.isCancelled else { return }
                    let base = source.hasPrefix("/") ? URL(fileURLWithPath: "/", isDirectory: true) : baseURL?.deletingLastPathComponent()
                    guard !(MarkdownResourcePaths.requiresRoot(source) && rootInvalid),
                          let url = paths?.resolve(source) ?? URL(string: source, relativeTo: base)?.absoluteURL,
                          url.isFileURL || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil) else { continue }
                    let asset = AVURLAsset(url: url)
                    if await isPlayable(asset) { selected = asset; break }
                }
                guard let self, self.audioJobs[block.range]?.0 == token else { return }
                self.audioJobs.removeValue(forKey: block.range)
                guard !Task.isCancelled, let document, self.document === document,
                      self.enabled, self.isActive, self.generation == generation,
                      self.currentRevision?() == revision, document.url == baseURL,
                      !self.hasMarkedText, self.presentation?.audioBlocks.contains(block) == true,
                      let visible = self.visibleRange(), NSIntersectionRange(block.range, visible).length > 0,
                      let layout = self.layout, layout.canDisplayMarkdownMedia(block.range),
                      let textView = self.textView, let container = textView.textContainer else { return }
                self.audioCompleted.insert(block.range)
                guard let asset = selected else { self.audioLoadDidComplete?(block.range, false); return }
                guard let width = self.mediaWidth(block, container: container),
                      let height = self.mediaHeight(block, textView: textView) else { return }
                let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
                view.controlsStyle = block.media.controls ? .inline : .none
                view.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                // Плеер переживает правки выше него: позицию ищем по самому вью, запомненные блок и поколение устарели бы после первого сдвига.
                view.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: L10n.tr("编辑源代码")) { [weak self, weak document, weak view] in
                    guard let self, let document, let view, self.document === document,
                          self.currentRevision?() == self.revision, self.enabled, self.isActive, !self.hasMarkedText,
                          let range = self.audioViews.first(where: { $0.value === view })?.key,
                          self.presentation?.audioBlocks.contains(where: { $0.range == range }) == true,
                          let textView = self.textView else { return false }
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                    textView.window?.makeFirstResponder(textView)
                    return true
                }])
                self.audioViews[block.range] = view
                if let rect = self.mediaRect(for: block.range, size: NSSize(width: width, height: height), inline: block.isInline, layout: layout, container: container) {
                    textView.addSubview(view)
                    textView.placeMarkdownSubview(view, in: rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y))
                }
                self.notifyGeometryChanged()
                self.audioLoadDidComplete?(block.range, true)
            }
            audioJobs[block.range] = (token, task)
        }
    }

    private var hasMarkedText: Bool {
        guard let view = textView else { return false }
        return view.hasMarkedText() || view.subviews.contains { ($0 as? NSTextView)?.hasMarkedText() == true }
    }

    private func codeBlocks(intersecting range: NSRange) -> [MarkdownCodeBlock] {
        guard let blocks = presentation?.codeBlocks, !blocks.isEmpty, range.length > 0 else { return [] }
        var low = 0, high = blocks.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(blocks[middle].bodyRange) <= range.location { low = middle + 1 } else { high = middle }
        }
        var result: [MarkdownCodeBlock] = []
        while low < blocks.count && blocks[low].bodyRange.location < NSMaxRange(range) {
            if NSIntersectionRange(blocks[low].bodyRange, range).length > 0 { result.append(blocks[low]) }
            low += 1
        }
        return result
    }

    private func cancelCodeJobs() {
        for job in codeJobs.values { job.1.cancel() }
        codeJobs.removeAll()
    }

    private func cancelCodeHighlighting() {
        cancelCodeJobs()
        codeResults.removeAll()
        codeFailed.removeAll()
        let ranges = Array(codeColoredRanges)
        codeColoredRanges.removeAll()
        if !ranges.isEmpty { restoreCodeColors?(ranges) }
    }

    /// Готовая подсветка блоков кода переезжает вместе с блоками: меняются только ключи, токены лежат от начала тела блока.
    /// Незавершённые задания уже отменены (`cancelPending`): они заново запустятся на блоках без результата.
    private func shiftCodeHighlighting(_ edit: MarkdownTextEdit) {
        let right = { (range: NSRange) in range.location > edit.range.location }
        guard edit.delta != 0, codeResults.keys.contains(where: right) || codeFailed.contains(where: right) || codeColoredRanges.contains(where: right) else { return }
        codeResults = Dictionary(codeResults.compactMap { range, result in edit.away(range).map { ($0, result) } }, uniquingKeysWith: { first, _ in first })
        codeFailed = Set(codeFailed.compactMap(edit.away))
        codeColoredRanges = Set(codeColoredRanges.compactMap(edit.away))
    }

    /// Готовые картинки, формулы и эмодзи переезжают вместе с элементами: меняются только ключи, объекты слоя сдвигает `shiftMarkdownMedia`.
    /// Незавершённые загрузки уже отменены (`cancelPending`): после разбора они запустятся заново только для пропущенных ключей.
    private func shiftInstalledMedia(_ edit: MarkdownTextEdit) {
        // Значения эмодзи разбираются заново после разбора: заголовки и читаемый текст должны получить замену.
        emojiValues = nil
        // Идущее вычисление формул отменяется: его ответ отбросит поколение, а занятая служба не дала бы запустить новое.
        if formulaJob?.busy == true {
            let service = formulaJob?.service
            formulaJob = nil
            service?.cancel()
        }
        guard edit.delta != 0 else { return }
        let right = { (range: NSRange) in range.location > edit.range.location }
        // Ключ блочной картинки — абзац, он растёт вместе с абзацем (`block`); остальные ключи — неделимые диапазоны (`canShift` не пускает правку в них).
        if loadedImageRanges.contains(where: { NSMaxRange($0) >= edit.range.location }) {
            loadedImageRanges = Set(loadedImageRanges.compactMap(edit.block))
        }
        if imagePresentationWidths.keys.contains(where: { NSMaxRange($0) >= edit.range.location }) {
            imagePresentationWidths = Dictionary(imagePresentationWidths.compactMap { key, width in edit.block(key).map { ($0, width) } },
                                                 uniquingKeysWith: { first, _ in first })
        }
        // Незавершённые загрузки имеют тот же стабильный элемент, но их
        // словарные ключи — диапазоны старого текста. Переносим ключи вместе с
        // placement, чтобы следующая видимая область не запускала дубликат.
        func movedJobRange(_ range: NSRange) -> NSRange? {
            edit.away(range) ?? edit.block(range)
        }
        if !imageOperations.isEmpty {
            var moved: [NSRange: BlockOperation] = [:]
            for (key, job) in imageOperations {
                guard let next = movedJobRange(key), moved[next] == nil else {
                    job.cancel()
                    continue
                }
                moved[next] = job
            }
            imageOperations = moved
        }
        if !remoteImageJobs.isEmpty {
            var moved: [NSRange: (UUID, Task<Void, Never>)] = [:]
            for (key, job) in remoteImageJobs {
                guard let next = movedJobRange(key), moved[next] == nil else {
                    job.1.cancel()
                    continue
                }
                moved[next] = job
            }
            remoteImageJobs = moved
        }
        if !svgImageJobs.isEmpty {
            var moved: [NSRange: (UUID, CGFloat, MarkdownSVGRenderService)] = [:]
            for (key, job) in svgImageJobs {
                guard let next = movedJobRange(key), moved[next] == nil else {
                    job.2.cancel()
                    continue
                }
                moved[next] = job
            }
            svgImageJobs = moved
        }
        if animatedImages.keys.contains(where: { NSMaxRange($0) >= edit.range.location }) {
            animatedImages = Dictionary(animatedImages.compactMap { key, view in edit.block(key).map { ($0, view) } },
                                        uniquingKeysWith: { first, _ in first })
        }
        if emojiRanges.contains(where: right) || emojiFonts.keys.contains(where: right) {
            emojiRanges = Set(emojiRanges.compactMap(edit.away))
            emojiFonts = Dictionary(emojiFonts.compactMap { key, font in edit.away(key).map { ($0, font) } },
                                    uniquingKeysWith: { first, _ in first })
        }
        if formulaCompleted.contains(where: right) {
            formulaCompleted = Set(formulaCompleted.compactMap(edit.away))
        }
        // Ссылка хранит ключ, место ссылки в исходнике и целевую формулу: правее правки может быть любое из трёх.
        if sourceMathReferences.contains(where: { entry in right(entry.key) || entry.value.contains { right($0.0) || right($0.1) } }) {
            sourceMathReferences = Dictionary(sourceMathReferences.compactMap { key, references in
                edit.away(key).map { moved in
                    (moved, references.map { reference in (edit.away(reference.0) ?? reference.0, edit.away(reference.1) ?? reference.1) })
                }
            }, uniquingKeysWith: { first, _ in first })
        }
        if let job = formulaJob, job.formulas.contains(where: { right($0.0.range) }) {
            for index in job.formulas.indices {
                if let range = edit.away(job.formulas[index].0.range) { formulaJob?.formulas[index].0.range = range }
            }
        }
    }

    /// Живые вставки переезжают вместе со своими блоками: вью, плееры и веб-вью те же, меняются ключи, блок в записи и рамка (её считает `notifyGeometryChanged`).
    /// Идущие загрузки аудио и отрисовка ruby уже отменены (`cancelPending`), их ключей в словарях нет. `baseRuns` у ruby лежат от начала подписи и не двигаются.
    private func shiftMedia(_ edit: MarkdownTextEdit) {
        guard edit.delta != 0 else { return }
        func moved<Value>(_ items: [NSRange: Value]) -> [NSRange: Value] {
            Dictionary(items.compactMap { range, value in edit.away(range).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
        }
        if !audioViews.isEmpty { audioViews = moved(audioViews) }
        if !audioCompleted.isEmpty { audioCompleted = Set(audioCompleted.compactMap(edit.away)) }
        if !detailsViews.isEmpty { detailsViews = moved(detailsViews) }
        if !expandedDetails.isEmpty { expandedDetails = moved(expandedDetails) }
        if !iframeViews.isEmpty {
            iframeViews = Dictionary(iframeViews.compactMap { range, entry -> (NSRange, IframeView)? in
                guard let to = edit.away(range) else { return nil }
                var entry = entry
                entry.block.range = to
                return (to, entry)
            }, uniquingKeysWith: { first, _ in first })
        }
        if !htmlBlockViews.isEmpty {
            htmlBlockViews = Dictionary(htmlBlockViews.compactMap { range, entry -> (NSRange, HTMLBlockView)? in
                guard let to = edit.away(range) else { return nil }
                var entry = entry
                entry.block.range = to
                return (to, entry)
            }, uniquingKeysWith: { first, _ in first })
        }
        if !rubyRendered.isEmpty {
            rubyRendered = Dictionary(rubyRendered.compactMap { range, key -> (NSRange, RubyKey)? in
                guard let to = edit.away(range), let base = edit.away(key.item.baseRange), let reading = edit.away(key.item.readingRange) else { return nil }
                var key = key
                key.item.range = to
                key.item.baseRange = base
                key.item.readingRange = reading
                return (to, key)
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// После подтверждённого сдвига живые вставки стоят на новых ключах, но рамки старые. Пересчёт через `notifyGeometryChanged` идёт на следующем
    /// проходе главного потока, когда раскладка строки с правкой дописана; одна проверка на пачку правок и только при живых вью.
    private func placeMediaAfterEdit() {
        guard !mediaPlacementPending,
              !(audioViews.isEmpty && iframeViews.isEmpty && detailsViews.isEmpty && htmlBlockViews.isEmpty) else { return }
        mediaPlacementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mediaPlacementPending = false
            guard self.isActive, self.enabled, !self.hasMarkedText else { return }
            self.notifyGeometryChanged()
        }
    }

    /// После разбора снимает результаты, ключ которых не совпал ни с одним блоком, и просит перекрасить их строки.
    private func pruneCodeHighlighting(keeping blocks: [MarkdownCodeBlock]) {
        guard !codeResults.isEmpty || !codeFailed.isEmpty else { return }
        let live = Set(blocks.map(\.range))
        let stale = codeResults.keys.filter { !live.contains($0) } + codeFailed.filter { !live.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale { codeResults.removeValue(forKey: key); codeFailed.remove(key) }
        let colored = codeColoredRanges.filter { segment in stale.contains { NSIntersectionRange($0, segment).length > 0 } }
        codeColoredRanges.subtract(colored)
        if !colored.isEmpty { restoreCodeColors?(Array(colored)) }
    }

    func reapplyCodeColors(in range: NSRange) {
        guard isActive, enabled, !hasMarkedText, currentRevision?() == revision,
              document?.isSyntaxHighlightingEnabled == true, let layout else { return }
        for block in codeBlocks(intersecting: range) {
            guard let result = codeResults[block.range] else { continue }
            let tokens = result.tokens
            let base = block.bodyRange.location
            var low = 0, high = block.bodySegments.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(block.bodySegments[middle]) <= range.location { low = middle + 1 } else { high = middle }
            }
            while low < block.bodySegments.count && block.bodySegments[low].location < NSMaxRange(range) {
                let segment = block.bodySegments[low]
                low += 1
                let part = NSIntersectionRange(segment, range)
                guard part.length > 0 else { continue }
                var first = 0, last = tokens.count
                while first < last {
                    let middle = (first + last) / 2
                    if result.prefixEnds[middle] <= part.location - base { first = middle + 1 } else { last = middle }
                }
                var end = first
                while end < tokens.count && tokens[end].range.location < NSMaxRange(part) - base { end += 1 }
                SyntaxHighlighter.apply(tokens: tokens[first..<end].map { SyntaxHighlighter.Token(range: NSRange(location: $0.range.location + base, length: $0.range.length), kind: $0.kind) },
                                        to: layout, range: part)
                codeColoredRanges.insert(segment)
            }
        }
    }

    private func loadVisibleCode(in visible: NSRange) {
        guard isActive, enabled, !hasMarkedText, let document, document.isSyntaxHighlightingEnabled,
              let storage = textView?.textStorage else { return }
        let blocks = codeBlocks(intersecting: visible)
        let visibleRanges = Set(blocks.map(\.range))
        for range in Array(codeJobs.keys) where !visibleRanges.contains(range) {
            codeJobs.removeValue(forKey: range)?.1.cancel()
        }
        for block in blocks where codeJobs[block.range] == nil && codeResults[block.range] == nil && !codeFailed.contains(block.range) {
            guard block.bodyRange.location <= storage.length, block.bodyRange.length <= storage.length - block.bodyRange.location else { continue }
            guard block.bodySegments.count == block.bodyPadding.count,
                  block.bodySegments.allSatisfy({ $0.location <= storage.length && $0.length <= storage.length - $0.location }) else { continue }
            let segments = zip(block.bodySegments, block.bodyPadding).map {
                MarkdownCodeHighlightService.Segment(sourceLocation: $0.0.location, text: storage.mutableString.substring(with: $0.0), leadingSpaces: $0.1)
            }
            let token = UUID(), generation = self.generation, revision = self.revision
            let operation = BlockOperation()
            let highlighter = codeHighlighter
            codeJobs[block.range] = (token, operation)
            operation.addExecutionBlock { [weak self, weak operation, weak document] in
                guard let operation, !operation.isCancelled else { return }
                let tokens = highlighter(segments, block.literal, block.info, block.bodyRange, operation)
                guard !operation.isCancelled else { return }
                let base = block.bodyRange.location
                let sorted = (tokens ?? []).sorted { $0.range.location < $1.range.location }
                    .map { SyntaxHighlighter.Token(range: NSRange(location: $0.range.location - base, length: $0.range.length), kind: $0.kind) }
                var maximumEnd = 0
                let prefixEnds = sorted.map { maximumEnd = max(maximumEnd, NSMaxRange($0.range)); return maximumEnd }
                guard !operation.isCancelled else { return }
                DispatchQueue.main.async { [weak self, weak document] in
                    guard let self, self.codeJobs[block.range]?.0 == token else { return }
                    self.codeJobs.removeValue(forKey: block.range)
                    self.codeHighlightDidComplete?(block.range)
                    guard let document, self.document === document, self.isActive, self.enabled,
                          self.generation == generation, self.currentRevision?() == revision, !self.hasMarkedText,
                          self.codeBlocks(intersecting: block.bodyRange).contains(block) else { return }
                    guard tokens != nil else { self.codeFailed.insert(block.range); return }
                    self.codeResults[block.range] = CodeResult(tokens: sorted, prefixEnds: prefixEnds)
                    if let current = self.visibleRange() { self.reapplyCodeColors(in: current) }
                }
            }
            queue.addOperation(operation)
        }
        reapplyCodeColors(in: visible)
    }

    /// Останавливает идущую отрисовку диаграмм; готовые картинки не трогает. Поздние ответы отбрасывает сверка по `diagramJobs`.
    private func cancelDiagramJobs() {
        let jobs = diagramJobs.values.map { $0.job }
        diagramJobs.removeAll()
        for job in jobs { job.cancel() }
    }

    private func currentDiagramPlacement(for token: UUID) -> (range: NSRange, entry: DiagramJobEntry)? {
        diagramJobs.first { $0.value.token == token }.map { ($0.key, $0.value) }
    }

    /// Готовые диаграммы переезжают вместе со своими блоками: меняются только ключи, картинка и SVG те же.
    /// Идущие отрисовки уже отменены (`cancelPending`) и заново пойдут по видимым диаграммам без результата.
    private func shiftDiagrams(_ edit: MarkdownTextEdit) {
        guard edit.delta != 0 else { return }
        for range in Array(diagramJobs.keys) where edit.away(range) == nil {
            diagramJobs[range]?.job.cancel()
            diagramJobs.removeValue(forKey: range)
        }
        diagramCompleted = Set(diagramCompleted.compactMap(edit.away))
        diagramResources = Dictionary(diagramResources.compactMap { range, value in edit.away(range).map { ($0, value) } },
                                      uniquingKeysWith: { first, _ in first })
        diagramJobs = Dictionary(diagramJobs.compactMap { range, entry in
            edit.away(range).map { ($0, entry) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func cancelDiagrams() {
        cancelDiagramJobs()
        let formula = formulaJob?.service
        formulaJob = nil
        diagramCompleted.removeAll()
        diagramResources.removeAll()
        formulaCompleted.removeAll()
        sourceMathReferences.removeAll()
        formulaFontSize = nil
        diagramGeometry = nil
        formula?.cancel()
        if !hasMarkedText {
            layout?.clearMarkdownBlockImages()
            uppercaseInstalled.removeAll()
            layout?.clearMarkdownInlineImages()
            if let presentation {
                for image in presentation.images where image.isInline {
                    loadedImageRanges.remove(image.range)
                    if let view = animatedImages.removeValue(forKey: image.range) { view.animates = false; view.removeFromSuperview() }
                }
            }
            emojiRanges.removeAll()
            emojiFonts.removeAll()
            if let visible = visibleRange() {
                updateAudio(in: visible)
                updateIframes(in: visible)
                updateDetails(in: visible)
                updateHTMLBlocks(in: visible)
            }
        }
    }

    private func loadVisibleDiagrams(in visible: NSRange) {
        guard !hasMarkedText, let presentation, let document, let view = textView, let container = view.textContainer, let layout else { return }
        let width = max(1, container.size.width - 2 * container.lineFragmentPadding)
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let old = diagramGeometry, old.0 != width || old.1 != dark { cancelDiagrams() }
        diagramGeometry = (width, dark)
        let diagrams = presentation.diagrams.filter { NSIntersectionRange($0.range, visible).length > 0 }
        // Готовые диаграммы не выгружаем при прокрутке. Их диапазон и размер уже
        // участвуют в раскладке, а удаление картинки оставляет пустой блок и при
        // возврате временно показывает исходный текст до нового рендера.
        for diagram in diagrams {
            // Диаграмма редактируется как исходный текст, пока курсор находится
            // внутри её блока. Не запускаем новый рендер на каждой клавише;
            // после выхода selectionChanged/viewportChanged снова вызовет этот путь.
            if NSIntersectionRange(view.selectedRange(), diagram.range).length > 0 {
                continue
            }
            guard !diagramCompleted.contains(diagram.range), diagramJobs[diagram.range] == nil else { continue }
            let cacheKey = diagramCacheKey(for: diagram, width: width, dark: dark)
            if let cached = diagramCache[cacheKey] {
                diagramCompleted.insert(diagram.range)
                diagramResources[diagram.range] = (cached.image, cached.svg)
                layout.setMarkdownBlockImage(cached.image, for: diagram.range)
                continue
            }
            let token = UUID(), generation = self.generation, revision = self.revision
            let identity = DiagramJobIdentity(kind: diagram.kind.rawValue, source: diagram.source)
            let receive: (Result<NSImage, Error>) -> Void = { [weak self, weak document] result in
                guard let self, let current = self.currentDiagramPlacement(for: token), current.entry.identity == identity else { return }
                let currentRange = current.range
                let svg = current.entry.job.svg
                self.diagramJobs.removeValue(forKey: currentRange)
                guard let document, self.document === document, self.enabled, self.isActive,
                      self.generation == generation,
                      !self.hasMarkedText,
                      let currentDiagram = self.presentation?.diagrams.first(where: { $0.range == currentRange && $0.kind.rawValue == identity.kind && $0.source == identity.source }),
                      let visible = self.visibleRange(), NSIntersectionRange(currentDiagram.range, visible).length > 0,
                      let geometry = self.diagramGeometry, geometry.0 == width, geometry.1 == dark else { return }
                self.diagramCompleted.insert(currentDiagram.range)
                if case let .success(image) = result {
                    self.diagramResources[currentDiagram.range] = (image, svg)
                    self.diagramCache[cacheKey] = CachedDiagram(image: image, svg: svg)
                    self.layout?.setMarkdownBlockImage(image, for: currentDiagram.range)
                    self.notifyGeometryChanged()
                }
            }
            let job: DiagramJob
            switch diagram.kind {
            case .mermaid:
                job = .mermaid(MermaidRenderService(code: diagram.source, width: width, dark: dark, completion: receive))
            case .flow, .sequence:
                let kind: LegacyDiagramRenderService.Kind = diagram.kind == .flow ? .flow : .sequence
                job = .legacy(LegacyDiagramRenderService(code: diagram.source, kind: kind, width: width, completion: receive))
            }
            diagramJobs[diagram.range] = DiagramJobEntry(token: token, identity: identity, revision: revision, job: job)
            job.start()
        }
    }

    func diagramResource(at point: NSPoint) -> DiagramResource? {
        guard let view = textView, let container = view.textContainer, let layout, let document,
              isActive, enabled, !hasMarkedText, currentRevision?() == revision,
              let location = layout.markdownImageLocation(at: NSPoint(x: point.x - view.textContainerOrigin.x,
                                                                       y: point.y - view.textContainerOrigin.y), in: container),
              let diagram = presentation?.diagrams.first(where: { $0.range.location == location }),
              let resource = diagramResources[diagram.range], layout.canDisplayMarkdownMedia(diagram.range) else { return nil }
        return DiagramResource(range: diagram.range, image: resource.image, svg: resource.svg, document: document,
                               revision: revision, generation: generation, selection: view.selectedRanges)
    }

    func imageResource(at point: NSPoint) -> ImageResource? {
        guard let view = textView, let container = view.textContainer, let layout, let document,
              isActive, enabled, !hasMarkedText, currentRevision?() == revision,
              let location = layout.markdownImageLocation(at: NSPoint(x: point.x - view.textContainerOrigin.x,
                                                                       y: point.y - view.textContainerOrigin.y), in: container),
              let image = presentation?.images.first(where: { $0.range.location == location }),
              layout.canDisplayMarkdownMedia(image.range) else { return nil }
        return ImageResource(image: image, document: document, revision: revision, generation: generation)
    }

    func isCurrentImageResource(_ resource: ImageResource) -> Bool {
        isActive && enabled && !hasMarkedText && document === resource.document && revision == resource.revision
            && generation == resource.generation && currentRevision?() == resource.revision
            && presentation?.images.contains(resource.image) == true
    }

    func isCurrentDiagramResource(_ resource: DiagramResource) -> Bool {
        guard let view = textView, let layout, let current = diagramResources[resource.range],
              document === resource.document, current.image === resource.image,
              isActive, enabled, !hasMarkedText, generation == resource.generation,
              revision == resource.revision, currentRevision?() == resource.revision,
              view.window?.isKeyWindow == true, view.selectedRanges == resource.selection,
              let visible = visibleRange(), NSIntersectionRange(resource.range, visible).length > 0 else { return false }
        return layout.canDisplayMarkdownMedia(resource.range)
    }

    private static func sourceReferences(in formula: MarkdownFormula, references: [MathJaxRenderService.Reference],
                                         formulas: [(MarkdownFormula, Bool)]) -> [(NSRange, NSRange)]? {
        guard !references.isEmpty else { return nil }
        let source = formula.source as NSString
        var position = 0, result: [(NSRange, NSRange)] = []
        while position < source.length {
            let unit = source.character(at: position)
            if unit == 92 {
                let prefix: Int
                if position + 5 <= source.length && source.substring(with: NSRange(location: position, length: 5)) == "\\ref{" { prefix = 5 }
                else if position + 7 <= source.length && source.substring(with: NSRange(location: position, length: 7)) == "\\eqref{" { prefix = 7 }
                else { return nil }
                var end = position + prefix
                while end < source.length && source.character(at: end) != 125 {
                    let character = source.character(at: end)
                    guard (48...57).contains(character) || (65...90).contains(character) ||
                            (97...122).contains(character) || [45, 46, 58, 95].contains(character) else { return nil }
                    end += 1
                }
                guard end > position + prefix, end < source.length, result.count < references.count else { return nil }
                let commandRange = NSRange(location: position, length: end - position + 1)
                let reference = references[result.count]
                guard reference.latex == source.substring(with: commandRange), formulas.indices.contains(reference.targetIndex) else { return nil }
                result.append((NSRange(location: formula.range.location + 1 + position, length: commandRange.length),
                               formulas[reference.targetIndex].0.range))
                position = end + 1
            } else {
                guard unit >= 128 || (48...57).contains(unit) || (65...90).contains(unit) ||
                        (97...122).contains(unit) || [9, 10, 13, 32, 40, 41, 42, 43, 44, 45, 46, 47, 61, 91, 93].contains(unit) else { return nil }
                position += 1
            }
        }
        return result.count == references.count ? result : nil
    }

    private func startEmojiResolution() {
        guard isActive, (enabled || outlineVisible || readableEnabled), !hasMarkedText, emojiOperation == nil, emojiValues == nil,
              let parsedResult, !parsedResult.emojiCandidates.isEmpty, let document else { return }
        let candidates = parsedResult.emojiCandidates
        let generation = self.generation, revision = self.revision, parsedToken = parsedResultToken
        let resolver = emojiResolver
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation, weak document] in
            guard let operation, !operation.isCancelled else { return }
            let resolved = resolver(candidates.map(\.name), operation)
            guard !operation.isCancelled else { return }
            let values = resolved ?? [:]
            let replacements = candidates.compactMap { candidate -> (range: NSRange, text: String)? in
                values[candidate.name].map { (candidate.range, $0) }
            }
            var readable = parsedResult.readableText
            if let original = readable {
                if resolved != nil, let mapped = original.replacingEmojiText(replacements, isCancelled: { operation.isCancelled }) {
                    readable = mapped
                } else {
                    let ranges = resolved == nil ? candidates.map(\.range) : replacements.map(\.range)
                    readable = MarkdownReadableText(sourceLength: original.sourceLength, fragments: original.fragments,
                                                    unsupportedRanges: original.unsupportedRanges + ranges)
                }
            }
            guard !operation.isCancelled else { return }
            let updated = parsedResult.resolvingHeadingEmoji(values, readableText: readable)
            let headingChanged = updated.headings != parsedResult.headings
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self, weak document] in
                guard let self, self.emojiOperation === operation else { return }
                self.emojiOperation = nil
                guard let document, self.document === document, (self.enabled || self.outlineVisible || self.readableEnabled), self.isActive,
                      self.generation == generation, self.currentRevision?() == revision,
                      self.parsedResultToken == parsedToken, !self.hasMarkedText else { return }
                self.emojiValues = values
                self.uppercaseEmojiResolutionFailed = resolved == nil
                self.parsedResult = updated
                self.publishReadableTextIfNeeded()
                if self.presentation != nil { self.adopt(updated) }
                if headingChanged {
                    if self.presentation != nil {
                        self.layout?.updateMarkdownTOCHeadings(updated.headings)
                        self.notifyGeometryChanged()
                    }
                    if self.outlineVisible { self.publishOutline(updated, revision: revision) }
                }
                self.emojiResolutionDidComplete?()
                if let visible = self.visibleRange() { self.loadVisibleEmoji(in: visible) }
                if self.uppercaseSnapshotReady && !self.uppercaseHeadingLevels.isEmpty {
                    self.uppercaseHeadings = Dictionary(updated.headings.map { ($0.range.location, $0) }, uniquingKeysWith: { first, _ in first })
                    self.clearUppercaseHeadings()
                    self.lastVisibleRange = nil
                    self.applyVisible()
                }
            }
        }
        emojiOperation = operation
        queue.addOperation(operation)
    }

    private func loadVisibleEmoji(in visible: NSRange) {
        guard !hasMarkedText, let presentation, let values = emojiValues, let layout, let storage = textView?.textStorage else { return }
        var changed = false
        let all = presentation.emojiCandidates
        var low = 0, high = all.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(all[middle].range) <= visible.location { low = middle + 1 } else { high = middle }
        }
        var candidates: [MarkdownEmojiCandidate] = []
        while low < all.count && all[low].range.location < NSMaxRange(visible) {
            let candidate = all[low]
            let table = layout.isMarkdownTablePosition(candidate.range.location)
            if values[candidate.name] != nil &&
                (table ? !layout.isCharacterFolded(candidate.range.location) : layout.canDisplayMarkdownMedia(candidate.range)) {
                candidates.append(candidate)
            }
            low += 1
        }
        let visibleRanges = Set(candidates.map(\.range))
        for range in emojiRanges.subtracting(visibleRanges) {
            layout.removeMarkdownInlineImage(for: range)
            emojiRanges.remove(range)
            emojiFonts.removeValue(forKey: range)
            changed = true
        }
        let tableFonts = layout.markdownTableEmojiFonts(for: candidates.map(\.range))
        for candidate in candidates {
            guard let value = values[candidate.name], candidate.range.location < storage.length else { continue }
            let font = tableFonts[candidate.range]
                ?? (storage.attribute(.font, at: candidate.range.location, effectiveRange: nil) as? NSFont)
                ?? layout.textFont
            if emojiRanges.contains(candidate.range) && emojiFonts[candidate.range] == font { continue }
            if emojiRanges.remove(candidate.range) != nil {
                layout.removeMarkdownInlineImage(for: candidate.range)
                emojiFonts.removeValue(forKey: candidate.range)
                changed = true
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let size = (value as NSString).size(withAttributes: attributes)
            guard size.width > 0, size.height > 0 else { continue }
            let image = NSImage(size: size)
            image.lockFocus()
            (value as NSString).draw(at: .zero, withAttributes: attributes)
            image.unlockFocus()
            if layout.setMarkdownInlineImage(image, for: candidate.range) {
                emojiRanges.insert(candidate.range)
                emojiFonts[candidate.range] = font
                layout.setMarkdownEmojiAccessibility(value, for: candidate.range)
                changed = true
            }
        }
        if changed { notifyGeometryChanged() }
    }

    private func loadVisibleFormulas(in visible: NSRange) {
        guard !hasMarkedText, let presentation, let document, let geometry = diagramGeometry, let layout else { return }
        let fontSize = layout.textFont.pointSize
        let inlineRanges = Set(presentation.inlineFormulas.map(\.range))
        if let previous = formulaFontSize, previous != fontSize {
            let service = formulaJob?.service
            formulaJob = nil
            service?.cancel()
            for range in formulaCompleted {
                if inlineRanges.contains(range) { layout.removeMarkdownInlineImage(for: range) }
                else { layout.setMarkdownBlockImage(nil, for: range) }
            }
            formulaCompleted.removeAll()
        }
        formulaFontSize = fontSize
        let blocks = presentation.formulas.filter { NSIntersectionRange($0.range, visible).length > 0 }
        let inline = presentation.inlineFormulas.filter {
            NSIntersectionRange($0.range, visible).length > 0 &&
                (layout.isMarkdownTablePosition($0.range.location) ? !layout.isCharacterFolded($0.range.location) : layout.canDisplayMarkdownMedia($0.range))
        }
        let visibleRanges = Set((blocks + inline).map(\.range))
        for range in formulaCompleted.subtracting(visibleRanges) {
            if inlineRanges.contains(range) { layout.removeMarkdownInlineImage(for: range) }
            else { layout.setMarkdownBlockImage(nil, for: range) }
            formulaCompleted.remove(range)
        }
        let needed = visibleRanges.subtracting(formulaCompleted)
        guard !needed.isEmpty, formulaJob?.busy != true else { return }
        let all = formulaJob?.formulas ?? (presentation.formulas.map { ($0, true) } + presentation.inlineFormulas.map { ($0, false) })
            .sorted { $0.0.range.location < $1.0.range.location }
        let indices = all.indices.filter { needed.contains(all[$0].0.range) }
        guard !indices.isEmpty else { return }
        let generation = self.generation, revision = self.revision
        let token = formulaJob?.token ?? UUID()
        let reused = formulaJob != nil
        let receive: (Result<[NSImage?], Error>) -> Void = { [weak self, weak document] result in
            guard let self, self.formulaJob?.token == token else { return }
            self.formulaJob?.busy = false
            guard let document, self.document === document, self.enabled, self.isActive,
                  self.generation == generation, self.currentRevision?() == revision, !self.hasMarkedText,
                  self.presentation?.formulas == presentation.formulas,
                  self.presentation?.inlineFormulas == presentation.inlineFormulas,
                  let visible = self.visibleRange(),
                  let current = self.diagramGeometry, current.0 == geometry.0, current.1 == geometry.1 else { return }
            guard case let .success(images) = result, images.count == indices.count else {
                self.formulaJob = nil
                if reused { self.loadVisibleFormulas(in: visible) }
                return
            }
            for (index, image) in zip(indices, images) {
                let formula = all[index].0
                guard NSIntersectionRange(formula.range, visible).length > 0 else { continue }
                self.formulaCompleted.insert(formula.range)
                if let image {
                    if all[index].1 { self.layout?.setMarkdownBlockImage(image, for: formula.range) }
                    else {
                        self.suspendUppercaseHeading(for: formula.range)
                        self.layout?.setMarkdownInlineImage(image, for: formula.range)
                    }
                    let rawReferences = self.formulaJob?.service.references[index] ?? []
                    if !all[index].1, let mapped = Self.sourceReferences(in: formula, references: rawReferences, formulas: all) {
                        self.sourceMathReferences[formula.range] = mapped
                    }
                    let references = rawReferences.compactMap { reference -> (rect: CGRect, target: NSRange)? in
                        guard all.indices.contains(reference.targetIndex), reference.pixelSize.width > 0, reference.pixelSize.height > 0 else { return nil }
                        let rect = reference.rect
                        return (CGRect(x: rect.minX / reference.pixelSize.width, y: rect.minY / reference.pixelSize.height,
                                       width: rect.width / reference.pixelSize.width, height: rect.height / reference.pixelSize.height),
                                all[reference.targetIndex].0.range)
                    }
                    self.layout?.setMarkdownMathReferences(references, for: formula.range)
                }
            }
            if self.uppercaseSnapshotReady && !self.uppercaseHeadingLevels.isEmpty {
                self.clearUppercaseHeadings()
                self.lastVisibleRange = nil
                self.applyVisible()
            }
            self.notifyGeometryChanged()
            self.loadVisibleFormulas(in: visible)
        }
        if let job = formulaJob {
            formulaJob?.busy = true
            job.service.requestImages(indices, completion: receive)
        } else {
            let expressions = all.map { MathJaxRenderService.Expression(source: $0.0.source, display: $0.1) }
            let service = MathJaxRenderService(expressions: expressions, outputIndices: indices,
                                               width: geometry.0, dark: geometry.1, fontSize: fontSize,
                                               options: mathOptions, retainForRequests: true, completion: receive)
            formulaJob = (token, service, true, all)
            service.start()
        }
    }

    private func loadVisibleImages(in visible: NSRange) {
        guard let presentation, let document, let layout else { return }
        let cursor = textView?.selectedRange().location ?? visible.location
        let images = presentation.images
            .filter { NSIntersectionRange($0.paragraphRange, visible).length > 0 }
            .sorted { lhs, rhs in
                let leftDistance = abs(lhs.paragraphRange.location - cursor)
                let rightDistance = abs(rhs.paragraphRange.location - cursor)
                return leftDistance == rightDistance
                    ? lhs.paragraphRange.location < rhs.paragraphRange.location
                    : leftDistance < rightDistance
            }
        let retention = imageRetentionRange() ?? visible
        let retainedRanges = Set(presentation.images.lazy
            .filter { NSIntersectionRange($0.paragraphRange, retention).length > 0 }
            .map { $0.isInline ? $0.range : $0.paragraphRange })
        for (range, operation) in imageOperations where !retainedRanges.contains(range) {
            operation.cancel()
            imageOperations.removeValue(forKey: range)
        }
        for (range, (_, task)) in remoteImageJobs where !retainedRanges.contains(range) {
            task.cancel()
            remoteImageJobs.removeValue(forKey: range)
        }
        for range in Array(svgImageJobs.keys) where !retainedRanges.contains(range) {
            let job = svgImageJobs.removeValue(forKey: range)?.2
            job?.cancel()
        }
        for image in images {
            let key = image.isInline ? image.range : image.paragraphRange
            let cacheKey = imageCacheKey(for: image)
            if let cached = imageCache[cacheKey],
               (cached.width == nil || imageWidth(for: image) == cached.width),
               !loadedImageRanges.contains(key), imageOperations[key] == nil, svgImageJobs[key] == nil {
                installPresentedImage(cached.image.copy() as? NSImage ?? cached.image,
                                      animated: cached.animated,
                                      intrinsic: cached.intrinsic,
                                      for: image, key: key)
                continue
            }
            if let job = svgImageJobs[key], imageWidth(for: image) != job.1 {
                svgImageJobs.removeValue(forKey: key)
                job.2.cancel()
            }
            if let width = imagePresentationWidths[key], imageWidth(for: image) != width {
                imagePresentationWidths.removeValue(forKey: key)
                loadedImageRanges.remove(key)
                if image.isInline { layout.removeMarkdownInlineImage(for: key) }
                else { layout.setMarkdownImage(nil, for: key) }
                if let view = animatedImages.removeValue(forKey: key) { view.animates = false; view.removeFromSuperview() }
            }
            guard !loadedImageRanges.contains(key), imageOperations[key] == nil, svgImageJobs[key] == nil else { continue }
            // Reserve the media placement before starting an asynchronous load.
            // Without a placeholder FoldLayoutManager draws the full source line
            // during the cache miss, which looks like the image is раскрывается
            // while scrolling. The real resource replaces this placeholder.
            installImagePlaceholder(for: image, key: key, layout: layout)
            if let url = URL(string: image.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                guard remoteImageJobs[key] == nil else { continue }
                let token = UUID(), generation = self.generation, revision = self.revision, baseURL = document.url
                let session = imageSession
                let task = Task { @MainActor [weak self, weak document] in
                    let data = try? await MarkdownImageUploadService.downloadData(url, session: session)
                    guard !Task.isCancelled else { return }
                    let decoded = await Task.detached(priority: .userInitiated) { () -> ((CGImage, Bool)?, String?) in
                        guard let data else { return (nil, nil) }
                        guard (try? MarkdownImageUploadService.payload(data: data)) != nil else { return (nil, data.base64EncodedString()) }
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (nil, data.base64EncodedString()) }
                        return ((image, (CGImageSourceGetType(source) as String?) == "com.compuserve.gif" && CGImageSourceGetCount(source) > 1), nil)
                    }.value
                    guard !Task.isCancelled, let self,
                          let currentKey = self.currentImagePlacement(for: token),
                          let currentImage = self.image(at: currentKey) else { return }
                    self.remoteImageJobs.removeValue(forKey: currentKey)
                    guard let document, self.document === document, self.enabled, self.isActive,
                          self.generation == generation, self.currentRevision?() == revision, document.url == baseURL,
                          !self.hasMarkedText,
                          let visible = self.visibleRange(), NSIntersectionRange(currentImage.paragraphRange, visible).length > 0 else { return }
                    guard let raster = decoded.0 else {
                        if let encoded = decoded.1 {
                            self.startSVG(encoded, for: currentImage, key: currentKey, document: document, generation: generation, revision: revision, baseURL: baseURL)
                            return
                        }
                        self.loadedImageRanges.insert(currentKey)
                        return
                    }
                    self.installImage(raster.0, data: data, isAnimated: raster.1, for: currentImage, key: currentKey)
                }
                remoteImageJobs[key] = (token, task)
                continue
            }
            let generation = self.generation
            let revision = self.revision
            let baseURL = document.url
            let paths = resourcePaths, rootInvalid = resourceRootInvalid
            let projectedSource = projectedImageSource?(image.url)
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak document, weak operation] in
                guard let operation, !operation.isCancelled,
                      let data = markdownPresentationImageData(projectedSource ?? image.url, baseURL: baseURL, paths: paths, rootInvalid: rootInvalid), !operation.isCancelled else {
                        DispatchQueue.main.async { [weak self, weak operation] in
                        guard let self, let operation, !operation.isCancelled, self.generation == generation,
                              let currentKey = self.currentImagePlacement(for: operation) else { return }
                        self.imageOperations.removeValue(forKey: currentKey)
                        self.loadedImageRanges.insert(currentKey)
                    }
                    return
                }
                let source = CGImageSourceCreateWithData(data as CFData, nil)
                let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                let isAnimated = source.map { (CGImageSourceGetType($0) as String?) == "com.compuserve.gif" && CGImageSourceGetCount($0) > 1 } ?? false
                let encoded = decoded == nil ? data.base64EncodedString() : nil
                DispatchQueue.main.async { [weak self, weak document, weak operation] in
                    guard let self, let operation,
                          let currentKey = self.currentImagePlacement(for: operation),
                          let currentImage = self.image(at: currentKey) else { return }
                    self.imageOperations.removeValue(forKey: currentKey)
                    guard let document, !operation.isCancelled,
                          self.document === document, self.enabled, self.isActive, self.generation == generation,
                          self.currentRevision?() == revision, document.url == baseURL,
                          !self.hasMarkedText,
                          let visible = self.visibleRange(), NSIntersectionRange(currentImage.paragraphRange, visible).length > 0 else { return }
                    if let decoded { self.installImage(decoded, data: data, isAnimated: isAnimated, for: currentImage, key: currentKey) }
                    else if let encoded { self.startSVG(encoded, for: currentImage, key: currentKey, document: document, generation: generation, revision: revision, baseURL: baseURL) }
                }
            }
            imageOperations[key] = operation
            queue.addOperation(operation)
        }
    }

    private func installImagePlaceholder(for image: MarkdownImage, key: NSRange, layout: FoldLayoutManager) {
        guard !loadedImageRanges.contains(key), imageOperations[key] == nil, svgImageJobs[key] == nil else { return }
        let placeholder = NSImage(size: NSSize(width: 1, height: 1))
        if image.isInline {
            _ = layout.setMarkdownInlineImage(placeholder, for: image.range)
        } else {
            layout.setMarkdownImage(placeholder, for: image.paragraphRange)
        }
    }

    private func imageWidth(for image: MarkdownImage) -> CGFloat? {
        guard let layout, let container = textView?.textContainer else { return nil }
        var width = max(1, container.size.width - 2 * container.lineFragmentPadding)
        if image.isInline, layout.isMarkdownTablePosition(image.range.location),
           let frame = layout.markdownTableFrame(containing: image.range, in: container) {
            let physicalWidth = image.sizing != nil && container.layoutOrientation == .vertical ? frame.height : frame.width
            width = max(1, physicalWidth - 8)
        }
        else if image.sizing != nil {
            let visibleWidth = container.layoutOrientation == .vertical
                ? (textView?.enclosingScrollView?.contentView.bounds.width ?? 0) : (textView?.visibleRect.width ?? 0)
            if visibleWidth > 0 {
                width = container.layoutOrientation == .vertical ? visibleWidth : min(width, max(1, visibleWidth - 2 * container.lineFragmentPadding))
            }
            width = max(1, width - layout.markdownMediaIndent(for: image.paragraphRange))
        }
        return width
    }

    private func startSVG(_ encoded: String, for image: MarkdownImage, key: NSRange, document: EditorDocument,
                          generation: UInt, revision: UInt, baseURL: URL?) {
        guard let width = imageWidth(for: image) else { return }
        let token = UUID()
        let service = MarkdownSVGRenderService(encoded: encoded, fragment: MarkdownImageUploadService.fragmentSuffix(image.url), width: width) { [weak self, weak document] value in
            guard let self, let currentKey = self.currentImagePlacement(for: token),
                  let currentImage = self.image(at: currentKey) else { return }
            let intrinsic = self.svgImageJobs[currentKey]?.2.intrinsicSize
            self.svgImageJobs.removeValue(forKey: currentKey)
            guard let document, self.document === document, self.enabled, self.isActive,
                  self.generation == generation, self.currentRevision?() == revision, document.url == baseURL,
                  !self.hasMarkedText,
                  let visible = self.visibleRange(), NSIntersectionRange(currentImage.paragraphRange, visible).length > 0 else { return }
            guard self.imageWidth(for: currentImage) == width else { self.loadVisibleImages(in: visible); return }
            guard let value else { self.loadedImageRanges.insert(currentKey); return }
            self.imagePresentationWidths[currentKey] = width
            self.installPresentedImage(value, animated: nil, intrinsic: intrinsic, for: currentImage, key: currentKey)
        }
        svgImageJobs[key] = (token, width, service)
        service.start()
    }

    private func installImage(_ decoded: CGImage, data: Data?, isAnimated: Bool, for image: MarkdownImage, key: NSRange) {
        var size = NSSize(width: CGFloat(decoded.width), height: CGFloat(decoded.height))
        if image.isInline, let width = imageWidth(for: image), size.width > width {
            size.height *= width / size.width; size.width = width
        }
        var animated: NSImage?
        if isAnimated, let data {
            animated = NSImage(data: data)
        }
        let value = animated == nil ? NSImage(cgImage: decoded, size: size) : NSImage(size: size)
        installPresentedImage(value, animated: animated, intrinsic: CGSize(width: CGFloat(decoded.width), height: CGFloat(decoded.height)), for: image, key: key)
    }

    private func installPresentedImage(_ original: NSImage, animated: NSImage?, intrinsic: CGSize? = nil, for image: MarkdownImage, key: NSRange) {
        guard let layout else { return }
        let source = original.copy() as? NSImage ?? original
        let value = source
        let renderWidth = imageWidth(for: image)
        if let sizing = image.sizing {
            guard let width = imageWidth(for: image),
                  let size = sizing.size(intrinsic: intrinsic ?? value.size, availableWidth: width) else { return }
            value.size = size
        }
        if image.isInline {
            suspendUppercaseHeading(for: image.range)
            let installed = layout.setMarkdownInlineImage(value, for: image.range)
            imageLoadDidComplete?(image.range, installed)
            guard installed else { return }
        } else { layout.setMarkdownImage(value, for: image.paragraphRange) }
        loadedImageRanges.insert(key)
        if image.sizing != nil, let width = imageWidth(for: image) { imagePresentationWidths[key] = width }
        imageCache[imageCacheKey(for: image)] = CachedImage(image: source, animated: animated,
                                                             intrinsic: intrinsic, width: renderWidth)
        if let animated {
            let view = MarkdownAnimatedImageView()
            view.image = animated
            view.imageScaling = .scaleAxesIndependently
            view.animates = true
            animatedImages[key] = view
        }
        retryUppercaseHeading(for: image.range)
        notifyGeometryChanged()
    }

    private func restoreStyles(in requested: NSRange? = nil) {
        guard let textView, let storage = textView.textStorage, let layout else { return }
        restoreParagraphAlignment(in: requested.map { storage.mutableString.lineRange(for: $0) })
        let typing = textView.typingAttributes
        let whole = NSRange(location: 0, length: storage.length)
        let target = requested.map { NSIntersectionRange($0, whole) } ?? whole
        var foregroundRanges: [NSRange] = []
        for current in inlineForegroundRanges {
            let range = NSIntersectionRange(current, target)
            if range.length > 0 { foregroundRanges.append(range); layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
        }
        storage.beginEditing()
        for range in styledRanges {
            let safe = NSIntersectionRange(range, target)
            guard safe.length > 0 else { continue }
            storage.addAttribute(.font, value: layout.textFont, range: safe)
            storage.removeAttribute(.baselineOffset, range: safe)
            layout.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: safe)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: safe)
        }
        for range in backgroundRanges {
            let safe = NSIntersectionRange(range, target)
            if safe.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safe) }
        }
        storage.endEditing()
        textView.typingAttributes = typing
        if !foregroundRanges.isEmpty { restoreCodeColors?(foregroundRanges) }
        if requested == nil {
            for range in styledRanges { SyntaxHighlighter.apply(tokens: [], to: layout, range: range) }
            if !styledRanges.isEmpty { restoreCodeColors?(styledRanges) }
            styledRanges.removeAll()
            backgroundRanges.removeAll()
            inlineForegroundRanges.removeAll()
        } else {
            inlineForegroundRanges = inlineForegroundRanges.flatMap { range -> [NSRange] in
                let overlap = NSIntersectionRange(range, target)
                guard overlap.length > 0 else { return [range] }
                var remaining: [NSRange] = []
                if range.location < overlap.location { remaining.append(NSRange(location: range.location, length: overlap.location - range.location)) }
                if NSMaxRange(overlap) < NSMaxRange(range) { remaining.append(NSRange(location: NSMaxRange(overlap), length: NSMaxRange(range) - NSMaxRange(overlap))) }
                return remaining
            }
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
            styledRanges = styledRanges.flatMap { range -> [NSRange] in
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
