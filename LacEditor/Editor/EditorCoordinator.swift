import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

private struct MarkdownDataImageProjection {
    struct Entry {
        let token: String
        let source: String
    }

    private(set) var entries: [Entry] = []

    mutating func project(_ source: String) -> String {
        entries.removeAll(keepingCapacity: true)
        let pattern = #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]{16384,}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let raw = source as NSString
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: raw.length))
        guard !matches.isEmpty else { return source }
        let projected = NSMutableString(string: source)
        for (index, match) in matches.enumerated().reversed() {
            let original = raw.substring(with: match.range)
            guard let comma = original.firstIndex(of: ",") else { continue }
            let mediaType = String(original[..<comma])
            let token = "\(mediaType),AA==#lac-image-\(index)-\(UUID().uuidString)"
            entries.append(Entry(token: token, source: original))
            projected.replaceCharacters(in: match.range, with: token)
        }
        entries.reverse()
        return projected as String
    }

    func restore(_ display: String) -> String {
        let source = NSMutableString(string: display)
        for entry in entries {
            source.replaceOccurrences(of: entry.token, with: entry.source,
                                      range: NSRange(location: 0, length: source.length))
        }
        return source as String
    }

    func source(for address: String) -> String? {
        entries.first(where: { $0.token == address })?.source
    }

    func sourceRange(for displayRange: NSRange, in display: String) -> NSRange {
        let raw = display as NSString
        func map(_ position: Int, trailing: Bool) -> Int {
            var delta = 0
            for entry in entries {
                let range = raw.range(of: entry.token)
                guard range.location != NSNotFound else { continue }
                if position <= range.location { return position + delta }
                let sourceLength = (entry.source as NSString).length
                if position < NSMaxRange(range) {
                    return range.location + delta + (trailing ? sourceLength : 0)
                }
                delta += sourceLength - range.length
            }
            return position + delta
        }
        let start = map(displayRange.location, trailing: false)
        let end = map(NSMaxRange(displayRange), trailing: true)
        return NSRange(location: start, length: max(0, end - start))
    }

    func displayRange(for sourceRange: NSRange, in display: String) -> NSRange {
        let raw = display as NSString
        func map(_ position: Int, trailing: Bool) -> Int {
            var delta = 0
            for entry in entries {
                let range = raw.range(of: entry.token)
                guard range.location != NSNotFound else { continue }
                let sourceLength = (entry.source as NSString).length
                let sourceStart = range.location + delta
                if position <= sourceStart { return position - delta }
                if position < sourceStart + sourceLength {
                    return trailing ? NSMaxRange(range) : range.location
                }
                delta += sourceLength - range.length
            }
            return position - delta
        }
        let start = map(sourceRange.location, trailing: false)
        let end = map(NSMaxRange(sourceRange), trailing: true)
        return NSRange(location: max(0, start), length: max(0, end - start))
    }

    func intersectsToken(_ range: NSRange, in display: String) -> Bool {
        let raw = display as NSString
        return entries.contains { entry in
            let token = raw.range(of: entry.token)
            return token.location != NSNotFound && (NSIntersectionRange(token, range).length > 0 ||
                (range.length == 0 && range.location > token.location && range.location < NSMaxRange(token)))
        }
    }
}


extension EditorTextView {
    @preconcurrency @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private enum ClipboardCopyMode: Sendable { case rich, markdown, html }
        var document: EditorDocument {
            didSet {
                if oldValue !== document { cancelMarkdownLinkNavigation(); cachedMarkdownNavigation = nil; endEmojiCompletion() }
            }
        }
        weak var textView: LacTextView?
        weak var ruler: LineNumberRulerView?
        weak var scrollView: NSScrollView?
        weak var foldLayoutManager: FoldLayoutManager?
        var magnificationDidChange: ((CGFloat) -> Void)?
        private var pendingMagnification: CGFloat?
        private var applyingMagnification = false
        private var lastObservedMagnification: CGFloat = 1
        var isApplyingExternalUpdate = false
        private var isApplyingAutomatedEdit = false
        private var isRestoringOffscreenEdit = false
        var currentFontSize: CGFloat = 14
        var currentTabWidth: Int = 4
        var currentLanguage: EditorLanguage
        var lastSynchronizedRevision: UInt
        var maximumTextWidth: CGFloat?
        private(set) var editorLigatures: Int?
        private(set) var strikeCompletedTasks = false
        private(set) var headingNumbering = false
        private(set) var uppercaseHeadingLevels: Set<Int> = []
        private(set) var listStyles = MarkdownListStyles()
        private(set) var mathPairContextEnabled = false
        private var syntaxOptions = MarkdownSyntaxOptions()
        private(set) var markdownVerticalWriting = false
        private var hasAppliedLigatures = false
        private var wordWrap = true
        private var writingFocus = false
        private var writingTypewriter = false
        private var writingBaseInset: CGFloat = 0
        private var pendingTypewriterAfterComposition = false
        private var typewriterWorkItem: DispatchWorkItem?
        private var typewriterSelection: NSRange?
        private var isTypewriterScrolling = false
        private var isActive = false
        private var syntaxHighlightingEnabled: Bool
        private var clearsDisabledSyntaxOnScroll = false
        private var lineNumbersVisible: Bool?
        private var lastLayoutWidth: CGFloat = -1
        private var lastRulerWidth: CGFloat = -1
        private var highlightWorkItem: DispatchWorkItem?
        private let highlightQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.laceditor.syntax-highlighting"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private var highlightOperation: BlockOperation?
        private let syntaxHighlightContext = SyntaxHighlighter.IncrementalContext()
        private let delimiterMatchingContext = DelimiterMatchingService.Context()
        private var delimiterMatchWorkItem: DispatchWorkItem?
        private let delimiterMatchQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.laceditor.delimiter-matching"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private var delimiterMatchOperation: BlockOperation?
        private var delimiterSnapshot: String?
        private var delimiterSnapshotRevision: UInt?
        private var delimiterHighlightRanges: [NSRange] = []
        private var highlightGeneration: UInt = 0
        var isMarkdownOutlineVisible = false
        private var markdownPresentation: MarkdownPresentationController?
        private var markdownImageProjection = MarkdownDataImageProjection()
        private var markdownImageProjectionEnabled = false
        private var mathOptions = MathJaxRenderService.Options()
        private var contentRevision: UInt
        private(set) var markdownLinkTask: Task<Void, Never>?
        var markdownLinkParse: (@Sendable (String) -> MarkdownPresentation)?
        private var markdownLinkID = UUID()
        private var markdownLinkSelection: [NSValue]?
        private var cachedMarkdownNavigation: (UUID, UInt, MarkdownPresentation)?
        private var tableCellEditor: MarkdownTableCellEditor?
        private var tableCellRange: NSRange?
        private var tableCellContextID = UUID()
        private(set) var clipboardPasteTask: Task<Void, Never>?
        private var clipboardPasteID = UUID()
        private(set) var clipboardCopyTask: Task<Void, Never>?
        private var clipboardCopyID = UUID()
        var clipboardCopyProject: @Sendable (String, NSRange, URL?, Bool, MarkdownSyntaxOptions, [NSRange: Bool]) -> MarkdownClipboardCopyService.Fragment? = {
            MarkdownClipboardCopyService.project($0, selection: $1, includeImages: true, documentURL: $2, allowRemoteImages: $3, syntax: $4, detailsOpenOverrides: $5)
        }
        var clipboardCopySession = URLSession.shared
        var clipboardConversionExecutable: URL?
        var clipboardImageWrite: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .withoutOverwriting) }
        private var tableCellVirtualSeparators = 0
        private var tableCellColumn = 0
        private var tableCellRowStart: Int?
        private var tableCellRowIndex: Int?
        private var tableCellHasVirtualHistory = false
        private var tableCellTableRange: NSRange?
        private var tableCellPresentation: MarkdownPresentation?
        private var tableCellIsCompletedTask = false
        private var tableCellOriginal = ""
        private var tableCellRevision: UInt = 0
        private var applyingTableCell = false
        private var tableCellHadComposition = false
        private var pendingTableTextMetrics: (() -> Void)?
        private var tableCellUndoCount = 0
        private var tableCellRedoCount = 0
        private var tableDragSnapshot: (range: NSRange, text: String, revision: UInt)?
        private var tableAccessibilityVirtualTarget: (range: NSRange, column: Int)?
        private let aiCompletion = AICompletionController()
        private weak var aiPreferences: AppPreferences?
        private var aiSettings: AIConfiguration?
        private var aiCompletionSettings: AIModelProfile?
        private var aiFeatures: Set<AIFeature> = []
        private var aiBackgroundEnabled = false
        private var aiCompletionRevision: UInt?
        private var aiCompletionCaret: Int?
        private var aiCompletionProfile: AIModelProfile?
        private var aiCompletionKey: String?
        private var writingSpellingEnabled = false
        private var writingGrammarEnabled = false
        private var isApplyingAIGenerated = false
        private var pendingFoldSelection: NSRange?
        private var highlightedRevision: UInt?
        private var appliedTreeChangeRevision: UInt?
        private var highlightedLanguage: EditorLanguage?
        private var highlightedFontSize: CGFloat?
        private var highlightedRanges: [NSRange] = []
        private var pendingHighlightRanges = DirtyRangeAccumulator()
        private var lastSyntaxEdit: DocumentEditDelta?
        private var emojiCompletionTask: Task<Void, Never>?
        var emojiCompletions: @Sendable (String) -> [String]? = { try? EmojiShortcodeResolver.completions(prefix: $0) }
        var emojiCompletionDidFinish: (() -> Void)?
        private var emojiCompletionID = UUID()
        private(set) var emojiCompletionRequested = false
        private static let smartCheckingKey = NSSpellChecker.OptionKey(rawValue: "LacEditorSmartCheckingID")
        private var parentSmartChecking: (UUID, UInt, UUID)?
        private var childSmartChecking: (UUID, UInt, UUID)?
        private var rulerRefreshWorkItem: DispatchWorkItem?
        private var rulerRefreshNeedsLayout = false
        private var selectionVisibilityWorkItem: DispatchWorkItem?
        private var textCodecSuggestionWorkItem: DispatchWorkItem?
        private var textCodecSuggestionGeneration: UInt = 0
        private var modelSyncWorkItem: DispatchWorkItem?
        private var layoutPrefetchWorkItem: DispatchWorkItem?
        private var listNormalizationWorkItem: DispatchWorkItem?
        private let listNormalizationQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.laceditor.list-normalization"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private var pendingListNormalizationLocation: Int?
        private var lastViewportOriginY: CGFloat = 0
        private var lastClipBoundsOrigin: NSPoint?
        private var lastClipBoundsSize: NSSize?
        private var liveResizeLayoutWorkItem: DispatchWorkItem?
        private var pendingLiveResizeWordWrap: Bool?
        private var isLiveResizing = false
        private let liveTextProviderID = UUID()
        private var pendingSelectionScrollOriginY: CGFloat?
        private var pendingOffscreenEditAnchor: Int?
        private var pendingOffscreenSelectionRange: NSRange?
        private var observerTokens: [NSObjectProtocol] = []
        private var findHighlightMatches: [NSRange] = []
        private var appliedFindRanges: [NSRange] = []
        private var appliedFindVisibleRange: NSRange?
        private var findMatchesChanged = false
        private let lineIndex: LogicalLineIndex

        init(document: EditorDocument) {
            self.document = document
            currentLanguage = document.language
            lastSynchronizedRevision = document.textRevision
            contentRevision = document.textRevision
            lineIndex = LogicalLineIndex(text: document.text)
            syntaxHighlightingEnabled = document.isSyntaxHighlightingEnabled
        }

        var isSessionActive: Bool { isActive }

        func applyPendingContextSelection() {
            guard isActive, let textView, !textView.hasMarkedText(),
                  let pending = document.pendingAIContextSelection else { return }
            document.pendingAIContextSelection = nil
            let documentID = document.id
            let revision = contentRevision
            guard document.textRevision == pending.revision, !document.hasPendingLiveEdits,
                  pending.range.location != NSNotFound,
                  NSMaxRange(pending.range) <= (textView.textStorage?.length ?? 0) else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.isActive, !textView.hasMarkedText(),
                      self.document.id == documentID, self.contentRevision == revision,
                      self.document.textRevision == pending.revision,
                      !self.document.hasPendingLiveEdits else { return }
                NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                    object: EditorSelectionRequest(documentID: documentID, range: pending.range))
            }
        }

        func configureWritingChecks(spellingEnabled: Bool, grammarEnabled: Bool) {
            writingSpellingEnabled = spellingEnabled
            writingGrammarEnabled = grammarEnabled
            if let textView {
                EditorTextView.applyWritingChecks(to: textView, spellingEnabled: spellingEnabled, grammarEnabled: grammarEnabled)
            }
        }

        func configureAIAssistance(preferences: AppPreferences?) {
            let settings = preferences?.aiConfiguration
            let completionSettings = preferences?.aiProfile(for: .completion)
            let features = preferences?.aiFeatures ?? []
            let background = preferences?.aiBackgroundEnabled ?? false
            if aiSettings != settings || aiCompletionSettings != completionSettings || aiFeatures != features || aiBackgroundEnabled != background {
                cancelAICompletion()
            }
            aiPreferences = preferences
            aiSettings = settings
            aiCompletionSettings = completionSettings
            aiFeatures = features
            aiBackgroundEnabled = background
            if let textView {
                document.provenance.configure(enabled: features.contains(.provenance), length: textView.textStorage?.length ?? 0)
                textView.acceptAICompletion = { [weak self] in self?.acceptCompletion() ?? false }
                textView.dismissAICompletion = { [weak self] in self?.cancelAICompletion() }
            }
        }

        private func cancelAICompletion() {
            aiCompletion.cancel()
            aiCompletionRevision = nil
            aiCompletionCaret = nil
            aiCompletionProfile = nil
            aiCompletionKey = nil
            textView?.completionText = nil
        }

        private func scheduleAICompletion() {
            cancelAICompletion()
            guard isActive, !document.isLargeFileMode, aiBackgroundEnabled, aiFeatures.contains(.completion),
                  let preferences = aiPreferences, let textView, !textView.hasMarkedText(),
                  let text = textView.textStorage?.mutableString else { return }
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location <= text.length else { return }
            let profile = preferences.aiProfile(for: .completion)
            guard profile.isEnabled, profile.supports(.text) else { return }
            let revision = contentRevision
            let documentID = document.id
            aiCompletion.schedule(inputProvider: { [weak textView] in
                    guard let text = textView?.textStorage?.mutableString,
                          selection.location <= text.length else { return nil }
                    let line = text.lineRange(for: selection)
                    let range = NSRange(location: line.location, length: selection.location - line.location)
                    return range.length > 0 ? text.substring(with: range) : nil
                }, keyProvider: {
                    try AIKeychainStore().load(for: .text, baseURL: profile.baseURL)
                }, coordinator: document.taskCoordinator, profile: profile,
                isCurrent: { [weak self, weak textView] in
                    guard let self, let textView, self.isActive, self.document.id == documentID,
                          self.contentRevision == revision, !self.document.isLargeFileMode, !textView.hasMarkedText(),
                          textView.selectedRange() == selection,
                          self.aiBackgroundEnabled, self.aiFeatures.contains(.completion),
                          self.aiPreferences?.aiProfile(for: .completion) == profile else { return false }
                    return true
                }, show: { [weak self, weak textView] completion, key in
                    guard let self, let textView else { return }
                    self.aiCompletionRevision = revision
                    self.aiCompletionCaret = selection.location
                    self.aiCompletionProfile = profile
                    self.aiCompletionKey = key
                    textView.completionText = completion
                })
        }

        private func acceptCompletion() -> Bool {
            guard isActive, !document.isLargeFileMode, let textView, !textView.hasMarkedText(),
                  let completion = textView.completionText, let revision = aiCompletionRevision,
                  let caret = aiCompletionCaret, revision == contentRevision,
                  textView.selectedRange() == NSRange(location: caret, length: 0),
                  aiBackgroundEnabled, aiFeatures.contains(.completion),
                  let profile = aiCompletionProfile,
                  aiPreferences?.aiProfile(for: .completion) == profile else { cancelAICompletion(); return false }
            do {
                guard try AIKeychainStore().load(for: .text, baseURL: profile.baseURL) == aiCompletionKey else {
                    cancelAICompletion()
                    return false
                }
            } catch {
                cancelAICompletion()
                return false
            }
            let request = EditorRangeReplacementRequest(documentID: document.id,
                range: NSRange(location: caret, length: 0), originalText: "", replacementText: completion,
                expectedEditorRevision: revision, actionName: AIFeature.completion.title)
            request.isAIGenerated = true
            cancelAICompletion()
            apply(request, to: textView)
            if request.wasHandled {
                textView.setSelectedRange(NSRange(location: caret + (completion as NSString).length, length: 0))
            }
            return request.wasHandled
        }

        func indentCurrentListItem(outdent: Bool) -> Bool {
            if textView?.hasMarkedText() == true { return true }
            guard isActive, currentLanguage == .markdown, document.ioState == .idle,
                  let textView, textView.isEditable, textView.selectedRanges.count == 1,
                  let storage = textView.textStorage,
                  ListContinuationService.isListOutsideCode(in: storage.mutableString, at: textView.selectedRange().location) else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return true }
            let indentUnit = textView.indentationStyle == .tabs ? "\t" : String(repeating: " ", count: textView.tabWidth)
            if let edit = ListContinuationService.unorderedIndentEdit(in: storage.mutableString, selection: selection, indentUnit: indentUnit, outdent: outdent) {
                textView.breakUndoCoalescing()
                textView.undoManager?.beginUndoGrouping()
                defer { textView.undoManager?.endUndoGrouping(); textView.breakUndoCoalescing() }
                isApplyingAutomatedEdit = true
                defer { isApplyingAutomatedEdit = false }
                guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return true }
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
                textView.didChangeText()
                textView.setSelectedRange(edit.selection)
                return true
            }
            if ListContinuationService.isUnorderedList(in: storage.mutableString, at: selection.location) {
                return !(outdent && ListContinuationService.isUnorderedRoot(in: storage.mutableString, at: selection.location))
            }
            guard let edits = ListContinuationService.indentationEdit(in: storage.mutableString, at: selection.location,
                indentUnit: indentUnit, outdent: outdent) else { return false }
            let selectionLocation = textView.selectedRange().location
            let updatedText = NSMutableString(string: storage.string)
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                updatedText.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            let normalized = outdent && edits.count == 1
                ? updatedText as String
                : ListContinuationService.normalizeNestedLists(in: updatedText as String)
            if normalized != updatedText as String {
                updatedText.replaceCharacters(
                    in: NSRange(location: 0, length: updatedText.length),
                    with: normalized
                )
            }
            // Indenting removes an item from its parent sequence. Normalize
            // the next parent item immediately so its number does not remain
            // stale until a later edit.
            if !outdent {
                let currentLine = updatedText.lineRange(
                    for: NSRange(location: min(selectionLocation, updatedText.length), length: 0)
                )
                let nextLocation = NSMaxRange(currentLine)
                if nextLocation < updatedText.length,
                   let normalization = ListContinuationService.normalizeOrderedList(
                    in: updatedText as String,
                    aroundUTF16Location: nextLocation
                   ) {
                    for edit in normalization.edits.sorted(by: { $0.range.location > $1.range.location }) {
                        updatedText.replaceCharacters(in: edit.range, with: edit.replacement)
                    }
                }
            }
            let original = storage.string as NSString
            var prefix = 0
            while prefix < original.length, prefix < updatedText.length,
                  original.character(at: prefix) == updatedText.character(at: prefix) {
                prefix += 1
            }
            if prefix > 0, prefix < original.length,
               (0xDC00...0xDFFF).contains(Int(original.character(at: prefix))) {
                prefix -= 1
            }
            var suffix = 0
            while suffix < original.length - prefix, suffix < updatedText.length - prefix,
                  original.character(at: original.length - suffix - 1)
                    == updatedText.character(at: updatedText.length - suffix - 1) {
                suffix += 1
            }
            if suffix > 0, original.length - suffix < original.length,
               (0xDC00...0xDFFF).contains(Int(original.character(at: original.length - suffix))) {
                suffix -= 1
            }
            let changedRange = NSRange(location: prefix, length: original.length - prefix - suffix)
            let replacement = updatedText.substring(with: NSRange(
                location: prefix, length: updatedText.length - prefix - suffix
            ))
            isApplyingAutomatedEdit = true
            defer { isApplyingAutomatedEdit = false }
            guard textView.shouldChangeText(in: changedRange, replacementString: replacement) else {
                return false
            }
            storage.replaceCharacters(in: changedRange, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(
                location: max(0, min(
                    storage.length,
                    selectionLocation
                        + edits.reduce(0) { $0 + ($1.replacement as NSString).length - $1.range.length }
                )),
                length: 0
            ))
            textView.undoManager?.setActionName(L10n.tr("整理有序列表"))
            return true
        }

        var estimatedMemoryCost: Int {
            let utf16Bytes = (textView?.textStorage?.length ?? document.text.utf16.count) * 2
            return utf16Bytes * 4
        }

        func prepareForEviction() {
            flushModelText(reconcileDirtyState: true)
            if let scrollView {
                let clip = scrollView.contentView
                let documentRect = scrollView.documentView.map { clip.convert($0.bounds, from: $0) } ?? .zero
                let extent = markdownVerticalWriting
                    ? documentRect.width - clip.bounds.width
                    : (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height
                let offset = markdownVerticalWriting ? clip.bounds.minX - documentRect.minX : clip.bounds.minY
                document.scrollPositionRatio = min(
                    1,
                    max(0, offset / max(1, extent))
                )
            }
            document.foldedRange = foldLayoutManager?.foldedRange
        }

        func restoreViewportState() {
            guard let scrollView else { return }
            let ratio = document.scrollPositionRatio
            let vertical = markdownVerticalWriting
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView, ratio > 0 else { return }
                let clip = scrollView.contentView
                let documentRect = scrollView.documentView.map { clip.convert($0.bounds, from: $0) } ?? .zero
                let extent = max(0, vertical
                    ? documentRect.width - clip.bounds.width
                    : (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
                clip.scroll(
                    to: vertical ? NSPoint(x: documentRect.minX + extent * ratio, y: clip.bounds.minY) : NSPoint(x: 0, y: extent * ratio)
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        isolated deinit {
            markdownLinkTask?.cancel()
#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML)
            TreeSitterJavaScriptBackend.invalidate(documentID: document.id)
#endif
            markdownPresentation?.cancel()
            modelSyncWorkItem?.cancel()
            layoutPrefetchWorkItem?.cancel()
            listNormalizationWorkItem?.cancel()
            listNormalizationQueue.cancelAllOperations()
            document.detachLiveTextProvider(id: liveTextProviderID)
            highlightWorkItem?.cancel()
            highlightOperation?.cancel()
            highlightQueue.cancelAllOperations()
            delimiterMatchWorkItem?.cancel()
            delimiterMatchOperation?.cancel()
            delimiterMatchQueue.cancelAllOperations()
            document.taskCoordinator.cancel(.delimiterMatch)
            document.taskCoordinator.cancel(.folding)
            document.taskCoordinator.cancel(.aiCompletion)
            rulerRefreshWorkItem?.cancel()
            liveResizeLayoutWorkItem?.cancel()
            selectionVisibilityWorkItem?.cancel()
            typewriterWorkItem?.cancel()
            textCodecSuggestionWorkItem?.cancel()
            clearFindHighlights()
            observerTokens.forEach(NotificationCenter.default.removeObserver)
        }

        private func cancelMarkdownLinkNavigation() {
            markdownLinkTask?.cancel()
            markdownLinkTask = nil
            markdownLinkID = UUID()
            markdownLinkSelection = nil
        }

        private func navigateMarkdownLink(at point: NSPoint) -> Bool {
            guard isActive, currentLanguage == .markdown, document.language == .markdown, document.ioState == .idle,
                  let textView, textView.window?.isKeyWindow == true, !textView.hasMarkedText(),
                  let layout = textView.layoutManager, let container = textView.textContainer else { return false }
            let local = NSPoint(x: point.x - textView.textContainerOrigin.x, y: point.y - textView.textContainerOrigin.y)
            if foldLayoutManager?.markdownTableCellInfo(at: local, in: container) != nil {
                if let child = tableCellEditor {
                    guard !child.hasMarkedText() else { return true }
                    let revision = contentRevision
                    finishTableCell()
                    guard contentRevision == revision else { return true }
                }
                guard let range = foldLayoutManager?.markdownTableLinkRange(at: local, in: container) else { return false }
                return navigateMarkdownLink(position: range.location, expectedRange: range)
            }
            guard tableCellEditor == nil else { return false }
            if let position = foldLayoutManager?.uppercaseHeadingSourcePosition(at: local, in: container) {
                return navigateMarkdownLink(position: position, expectedRange: nil)
            }
            let glyph = layout.glyphIndex(for: local, in: container)
            guard glyph < layout.numberOfGlyphs,
                  layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return false }
            let position = layout.characterIndexForGlyph(at: glyph)
            return navigateMarkdownLink(position: position, expectedRange: nil)
        }

        private func navigateMarkdownLink(position: Int, expectedRange: NSRange?) -> Bool {
            guard isActive, currentLanguage == .markdown, document.language == .markdown, document.ioState == .idle,
                  let textView, textView.window?.isKeyWindow == true, !textView.hasMarkedText(), tableCellEditor == nil else { return false }
            cancelMarkdownLinkNavigation()
            let token = markdownLinkID, revision = contentRevision, document = self.document
            markdownLinkSelection = textView.selectedRanges
            let snapshot = document.synchronizedSnapshot()
            guard self.document === document, contentRevision == revision, !textView.hasMarkedText() else { return false }
            func follow(_ parsed: MarkdownPresentation) -> Bool {
                guard let link = parsed.links.first(where: { link in expectedRange.map { $0 == link.range } ?? NSLocationInRange(position, link.range) }) else { return false }
                postMarkdownLink(link, headings: parsed.headings, namedAnchors: parsed.namedAnchors, snapshot: snapshot, document: document, revision: revision, token: token)
                return true
            }
            if let cachedMarkdownNavigation, cachedMarkdownNavigation.0 == document.id, cachedMarkdownNavigation.1 == revision {
                return follow(cachedMarkdownNavigation.2)
            }
            if let parsed = markdownPresentation?.navigationPresentation(document: document, revision: revision), follow(parsed) { return true }
            let parse = markdownLinkParse, syntax = syntaxOptions
            markdownLinkTask = Task { @MainActor [weak self, weak document] in
                let parsed = await Task.detached(priority: .userInitiated) { parse?(snapshot.text) ?? MarkdownPresentationParser.parse(snapshot.text, syntax: syntax) }.value
                guard !Task.isCancelled, let self, let document, self.markdownLinkID == token,
                      self.document === document, self.contentRevision == revision, self.isActive,
                      self.textView?.hasMarkedText() == false, self.tableCellEditor == nil else { return }
                self.markdownLinkTask = nil
                self.cachedMarkdownNavigation = (document.id, revision, parsed)
                guard let link = parsed.links.first(where: { link in expectedRange.map { $0 == link.range } ?? NSLocationInRange(position, link.range) }) else { return }
                self.postMarkdownLink(link, headings: parsed.headings, namedAnchors: parsed.namedAnchors, snapshot: snapshot, document: document, revision: revision, token: token)
            }
            return true
        }

        private func postMarkdownLink(_ link: MarkdownLink, headings: [MarkdownHeading], namedAnchors: [MarkdownNamedAnchor], snapshot: DocumentTextSnapshot,
                                      document: EditorDocument, revision: UInt, token: UUID) {
            let request = MarkdownLinkNavigationRequest(snapshot: snapshot, link: link, headings: headings, namedAnchors: namedAnchors) { [weak self, weak document] in
                guard let self, let document else { return false }
                return self.document === document && self.markdownLinkID == token && self.contentRevision == revision &&
                    self.textView?.hasMarkedText() == false && self.tableCellEditor == nil
            }
            NotificationCenter.default.post(name: EditorCommandNotification.navigateMarkdownLink, object: request)
        }

        private func navigateTableCellLink(_ child: MarkdownTableCellEditor, at point: NSPoint) -> Bool {
            guard isActive, child === tableCellEditor, !child.hasMarkedText(), tableCellVirtualSeparators == 0,
                  tableCellRevision == contentRevision, let parent = textView, !parent.hasMarkedText(),
                  let storage = parent.textStorage, let range = tableCellRange,
                  range.location <= storage.length, range.length <= storage.length - range.location,
                  storage.mutableString.substring(with: range) == tableCellOriginal,
                  let presentation = tableCellPresentation, let tableRange = tableCellTableRange,
                  let table = presentation.tables.first(where: { $0.range == tableRange }),
                  let row = tableCellRowIndex, table.rows.indices.contains(row),
                  let cell = table.rows[row].cells.first(where: { $0.column == tableCellColumn && $0.range == range }),
                  let layout = child.layoutManager, let container = child.textContainer else { return false }
            let local = NSPoint(x: point.x - child.textContainerOrigin.x, y: point.y - child.textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: local, in: container)
            guard glyph < layout.numberOfGlyphs,
                  layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return false }
            let position = layout.characterIndexForGlyph(at: glyph)
            let projection = MarkdownTableCellEditor.projection(tableCellOriginal)
            guard child.string == projection.text, position < projection.rawBoundaries.count else { return false }
            let rawPosition = projection.rawBoundaries[position]
            let matches = cell.displayRuns.compactMap { run -> NSRange? in
                guard run.kind == .link, let raw = run.sourceRange, NSLocationInRange(rawPosition, raw) else { return nil }
                return NSRange(location: range.location + raw.location, length: raw.length)
            }
            guard matches.count == 1, moveTableSelectionToParent() else { return false }
            return navigateMarkdownLink(position: matches[0].location, expectedRange: matches[0])
        }

        private func navigateTableCellMathReference(_ child: MarkdownTableCellEditor, at point: NSPoint) -> Bool {
            guard isActive, child === tableCellEditor, !child.hasMarkedText(), tableCellVirtualSeparators == 0,
                  tableCellRevision == contentRevision, let parent = textView, !parent.hasMarkedText(),
                  let storage = parent.textStorage, let range = tableCellRange,
                  range.location <= storage.length, range.length <= storage.length - range.location,
                  storage.mutableString.substring(with: range) == tableCellOriginal,
                  let layout = child.layoutManager, let container = child.textContainer else { return false }
            let local = NSPoint(x: point.x - child.textContainerOrigin.x, y: point.y - child.textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: local, in: container)
            guard glyph < layout.numberOfGlyphs,
                  layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return false }
            let projection = MarkdownTableCellEditor.projection(tableCellOriginal)
            let position = layout.characterIndexForGlyph(at: glyph)
            guard child.string == projection.text, position < projection.rawBoundaries.count else { return false }
            let offset = range.location + projection.rawBoundaries[position], revision = contentRevision
            guard let target = markdownPresentation?.mathReference(atSourceOffset: offset, document: document, revision: revision),
                  moveTableSelectionToParent() else { return false }
            guard contentRevision == revision,
                  markdownPresentation?.mathReference(atSourceOffset: offset, document: document, revision: revision) == target else { return true }
            NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                            object: EditorSelectionRequest(documentID: document.id, range: NSRange(location: target.location, length: 0)))
            return true
        }

        func installObservers(scrollView: NSScrollView) {
            textView?.markdownLinkHandler = { [weak self] point in self?.navigateMarkdownLink(at: point) ?? false }
            textView?.diagramMenuHandler = { [weak self] point in self?.diagramMenu(at: point) ?? [] }
            textView?.appearanceChangedHandler = { [weak self] in self?.editorAppearanceChanged() }
            textView?.paragraphStylesChangedHandler = { [weak self] range in
                self?.markdownPresentation?.paragraphStylesDidChange(in: range)
            }
            textView?.richPasteHandler = { [weak self] board in self?.pasteRichText(board, child: nil) ?? false }
            textView?.richCopyHandler = { [weak self] board in self?.copyRichText(board, child: nil) ?? false }
            observerTokens.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let child = self.tableCellEditor, note.object as AnyObject? === child else { return }
                self.clipboardPasteTask?.cancel()
                self.clipboardPasteTask = nil
                self.clipboardCopyTask?.cancel()
                self.clipboardCopyTask = nil
            })
            textView?.imageTransferHandler = { [weak self] transfer in
                guard let self, isActive, currentLanguage == .markdown, document.language == .markdown,
                      document.ioState == .idle, let textView, textView.isEditable, !textView.hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
                      (tableCellVirtualSeparators > 0 || moveTableSelectionToParent()) else { return false }
                let request = MarkdownImageTransferRequest(documentID: document.id, transfer: transfer)
                NotificationCenter.default.post(name: EditorCommandNotification.insertMarkdownImage, object: request)
                return request.handled
            }
            textView?.videoTransferHandler = { [weak self] file in
                guard let self, isActive, currentLanguage == .markdown, document.language == .markdown,
                      document.ioState == .idle, tableCellEditor == nil, let textView, textView.isEditable,
                      !textView.hasMarkedText(), textView.selectedRanges.count == 1, let storage = textView.textStorage else { return false }
                let selection = textView.selectedRange(), revision = contentRevision
                guard selection.length == 0,
                      let edit = MarkdownHTMLMediaService.videoInsertion(file: file, document: document.url,
                                                                         text: storage.string, location: selection.location),
                      revision == contentRevision, textView.selectedRange() == selection else { return false }
                textView.breakUndoCoalescing()
                let undo = textView.undoManager
                undo?.beginUndoGrouping()
                defer { undo?.endUndoGrouping(); textView.breakUndoCoalescing() }
                isApplyingAutomatedEdit = true
                defer { isApplyingAutomatedEdit = false }
                guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
                textView.didChangeText()
                textView.setSelectedRange(edit.selectionRange)
                textView.scrollRangeToVisible(edit.selectionRange)
                undo?.setActionName(L10n.tr("插入视频"))
                return true
            }
            textView?.tableCellHandler = { [weak self] cell, frame in
                guard let self,
                      markdownPresentation?.isCurrentTableCell(cell, document: document, revision: contentRevision) == true else { return false }
                tableAccessibilityVirtualTarget = nil
                return beginTableCell(cell.range, frame: frame, cell: cell)
            }
            textView?.tableAccessibilityRevision = { [weak self] in
                guard let self, self.isActive else { return nil }
                return self.contentRevision
            }
            textView?.tableAccessibilitySelection = { [weak self] in
                guard let self, self.isActive, let view = self.textView else { return nil }
                if let range = self.tableCellRange { return (range, self.tableCellColumn) }
                if let target = self.tableAccessibilityVirtualTarget, view.selectedRange() == target.range {
                    return (target.range, target.column)
                }
                return (view.selectedRange(), nil)
            }
            textView?.tableAccessibilityActionHandler = { [weak self] cell, frame, action in
                guard let self, markdownPresentation?.isCurrentTableCell(cell, document: document, revision: contentRevision) == true else { return false }
                let command: MarkdownTableCommand
                switch action {
                case .rowUp: command = .moveRowUp
                case .rowDown: command = .moveRowDown
                case .columnLeft: command = .moveColumnLeft
                case .columnRight: command = .moveColumnRight
                }
                let revision = contentRevision
                guard beginTableCell(cell.range, frame: frame, cell: cell) else { return false }
                applyMarkdownFormatting(.table(command))
                return contentRevision != revision
            }
            textView?.tableAccessibilityRevealHandler = { [weak self] cell in
                guard let self, isActive, document.language == .markdown, document.isMarkdownFormatted,
                      let textView, !textView.hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
                      markdownPresentation?.isCurrentTableCell(cell, document: document, revision: contentRevision) == true else { return false }
                let revision = contentRevision
                finishTableCell()
                guard revision == contentRevision,
                      markdownPresentation?.isCurrentTableCell(cell, document: document, revision: revision) == true else { return false }
                let range = NSRange(location: cell.range.location, length: 0)
                clearFoldIfNeeded(toReveal: range)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
                tableAccessibilityVirtualTarget = cell.virtualSeparators > 0 ? (cell.range, cell.column) : nil
                return true
            }
            textView?.tableOutsideClickHandler = { [weak self] in
                guard let self else { return false }
                if let child = tableCellEditor {
                    guard !child.hasMarkedText() else { return true }
                    finishTableCell()
                }
                tableAccessibilityVirtualTarget = nil
                foldLayoutManager?.setActiveTableRange(nil)
                markdownPresentation?.tableEditingGeometryChanged(cell: nil)
                return false
            }
            textView?.tableDragStartHandler = { [weak self] handle in
                guard let self, isActive, document.language == .markdown, document.isMarkdownFormatted,
                      document.ioState == .idle, let textView, textView.isEditable, !textView.hasMarkedText(),
                      tableCellEditor?.hasMarkedText() != true,
                      markdownPresentation?.isCurrentTableCell(handle.cell, document: document, revision: contentRevision) == true,
                      let storage = textView.textStorage else { return false }
                let revision = contentRevision
                finishTableCell()
                guard contentRevision == revision, handle.tableRange.location <= storage.length,
                      handle.tableRange.length <= storage.length - handle.tableRange.location else { return false }
                tableDragSnapshot = (handle.tableRange, storage.mutableString.substring(with: handle.tableRange), revision)
                textView.window?.makeFirstResponder(textView)
                return true
            }
            textView?.tableDragEndHandler = { [weak self] start, target in
                self?.finishTableDrag(start, target: target)
            }
            textView?.pageBreakHandler = { [weak self] range in
                guard let self, isActive, currentLanguage == .markdown, document.language == .markdown,
                      document.isMarkdownFormatted, document.ioState == .idle,
                      textView?.hasMarkedText() == false, tableCellEditor?.hasMarkedText() != true,
                      markdownPresentation?.isCurrentPageBreak(range, document: document, revision: contentRevision) == true else { return false }
                NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                    object: EditorSelectionRequest(documentID: document.id, range: NSRange(location: range.location, length: 0)))
                return true
            }
            textView?.tableOfContentsHandler = { [weak self] range, heading in
                guard let self, isActive, currentLanguage == .markdown, document.language == .markdown,
                      document.isMarkdownFormatted, document.ioState == .idle,
                      markdownPresentation?.isCurrentTOC(range, heading: heading, document: document, revision: contentRevision) == true else { return false }
                let target = heading?.range.location ?? range.location
                NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                                object: EditorSelectionRequest(documentID: document.id, range: NSRange(location: target, length: 0)))
                return true
            }
            textView?.autoPairAllowed = { [weak self] in
                guard let self, self.isActive, self.currentLanguage == .markdown,
                      self.document.language == .markdown, self.document.ioState == .idle,
                      !self.isApplyingAutomatedEdit, !self.isApplyingExternalUpdate,
                      self.textView?.hasMarkedText() == false else { return false }
                return true
            }
            textView?.mathPairAllowed = { [weak self] range in
                guard let self, self.aiPreferences?.markdownInlineMath != false, self.tableCellEditor == nil, let view = self.textView,
                      view.selectedRanges.count == 1, view.selectedRange() == range else { return false }
                return self.markdownPresentation?.allowsMathPair(document: self.document, revision: self.contentRevision, range: range) == true
            }
            textView?.footnoteNavigationHandler = { [weak self] point in
                guard let self, isActive, currentLanguage == .markdown, document.language == .markdown,
                      document.isMarkdownFormatted, document.ioState == .idle,
                      let target = markdownPresentation?.footnoteTarget(at: point, document: document, revision: contentRevision) else { return false }
                NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                                object: EditorSelectionRequest(documentID: document.id, range: target))
                return true
            }
            textView?.blockMathReferenceHandler = { [weak self] point in
                guard let self, isActive, currentLanguage == .markdown, document.language == .markdown,
                      document.isMarkdownFormatted, document.ioState == .idle,
                      let textView, !textView.hasMarkedText() else { return false }
                let local = NSPoint(x: point.x - textView.textContainerOrigin.x, y: point.y - textView.textContainerOrigin.y)
                if let child = tableCellEditor {
                    guard !child.hasMarkedText() else { return true }
                    let revision = contentRevision
                    finishTableCell()
                    guard contentRevision == revision else { return true }
                }
                guard let target = markdownPresentation?.mathReference(at: local, document: document, revision: contentRevision) else { return false }
                NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                                object: EditorSelectionRequest(documentID: document.id, range: NSRange(location: target.location, length: 0)))
                return true
            }
            textView?.taskCheckboxHandler = { [weak self] checkbox in
                guard let self, isActive, currentLanguage == .markdown, document.language == .markdown,
                      document.isMarkdownFormatted, document.ioState == .idle,
                      let textView, textView.isEditable, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
                      let storage = textView.textStorage,
                      markdownPresentation?.isCurrentTaskCheckbox(checkbox, document: document, revision: contentRevision) == true,
                      NSMaxRange(checkbox.markerRange) <= storage.length,
                      storage.mutableString.substring(with: checkbox.markerRange) == (checkbox.state == 32 ? "[ ]" : checkbox.state == 120 ? "[x]" : "[X]") else { return false }
                let selection = textView.selectedRange()
                let replacement = checkbox.state == 32 ? "x" : " "
                textView.breakUndoCoalescing()
                textView.undoManager?.beginUndoGrouping()
                defer { textView.undoManager?.endUndoGrouping(); textView.breakUndoCoalescing() }
                isApplyingAutomatedEdit = true
                defer { isApplyingAutomatedEdit = false }
                guard textView.shouldChangeText(in: checkbox.stateRange, replacementString: replacement) else { return true }
                storage.replaceCharacters(in: checkbox.stateRange, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(selection)
                textView.undoManager?.setActionName(L10n.tr("任务列表"))
                return true
            }
            textView?.codeFenceNewlineHandler = { [weak self] in
                guard let self, self.isActive, self.currentLanguage == .markdown, self.document.language == .markdown,
                      self.document.isMarkdownFormatted, self.document.ioState == .idle,
                      self.tableCellEditor == nil, let view = self.textView, view.isEditable, !view.hasMarkedText(),
                      view.selectedRanges.count == 1, let storage = view.textStorage else { return false }
                let selected = view.selectedRange(), text = storage.mutableString
                guard selected.length == 0, selected.location <= text.length, text.length > 0 else { return false }
                let line = text.lineRange(for: selected)
                var contentEnd = NSMaxRange(line)
                while contentEnd > line.location && (text.character(at: contentEnd - 1) == 10 || text.character(at: contentEnd - 1) == 13) { contentEnd -= 1 }
                guard selected.location == contentEnd else { return false }
                let singleLine = line.location == 0 && contentEnd == text.length
                let container = self.markdownPresentation?.fenceContainerOpening(document: self.document, revision: self.contentRevision, lineRange: line)
                guard container != nil || singleLine || self.markdownPresentation?.allowsFenceOpening(document: self.document, revision: self.contentRevision, lineRange: line) == true else { return false }
                let prefixLength = ((container?.sourcePrefix ?? "") as NSString).length
                guard prefixLength <= contentEnd - line.location,
                      container == nil || text.substring(with: NSRange(location: line.location, length: prefixLength)) == container?.sourcePrefix else { return false }
                var index = line.location + prefixLength
                let openingStart = index
                while index < contentEnd && text.character(at: index) == 32 { index += 1 }
                guard index - openingStart <= 3, index < contentEnd else { return false }
                let marker = text.character(at: index)
                guard marker == 96 || marker == 126 else { return false }
                let begin = index
                while index < contentEnd && text.character(at: index) == marker { index += 1 }
                guard index - begin >= 3 else { return false }
                for position in index..<contentEnd {
                    let unit = text.character(at: position)
                    if marker == 96 && unit == 96 { return false }
                }
                let newline: String
                if contentEnd < NSMaxRange(line) { newline = text.substring(with: NSRange(location: contentEnd, length: NSMaxRange(line) - contentEnd)) }
                else if line.location >= 2 && text.character(at: line.location - 2) == 13 && text.character(at: line.location - 1) == 10 { newline = "\r\n" }
                else if line.location > 0 && text.character(at: line.location - 1) == 13 { newline = "\r" }
                else { newline = "\n" }
                let fence = text.substring(with: NSRange(location: openingStart, length: index - openingStart))
                let continuation = container?.continuationPrefix ?? ""
                let replacement = newline + continuation + newline + continuation + fence
                view.breakUndoCoalescing()
                let undo = view.undoManager
                undo?.beginUndoGrouping()
                defer { undo?.endUndoGrouping(); view.breakUndoCoalescing() }
                self.isApplyingAutomatedEdit = true
                defer { self.isApplyingAutomatedEdit = false }
                guard view.shouldChangeText(in: selected, replacementString: replacement) else { return true }
                storage.replaceCharacters(in: selected, with: replacement)
                view.didChangeText()
                view.setSelectedRange(NSRange(location: selected.location + (newline as NSString).length + (continuation as NSString).length, length: 0))
                undo?.setActionName(L10n.tr("代码块"))
                return true
            }
            textView?.listNewlineHandler = { [weak self] in
                guard let self, isActive, currentLanguage == .markdown,
                      document.ioState == .idle, let textView, textView.isEditable,
                      !textView.hasMarkedText(), textView.selectedRanges.count == 1,
                      let storage = textView.textStorage,
                      let edit = ListContinuationService.listNewlineEdit(
                        in: storage.mutableString, selection: textView.selectedRange(),
                        indentUnit: textView.indentationStyle == .tabs ? "\t" : String(repeating: " ", count: textView.tabWidth)
                      ) else { return false }
                textView.insertText(edit.replacement, replacementRange: edit.range)
                textView.setSelectedRange(edit.selection)
                return true
            }
            self.scrollView = scrollView
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, isActive else { return }
                let bounds = scrollView.contentView.bounds
                if !applyingMagnification, textView?.hasMarkedText() != true,
                   tableCellEditor?.hasMarkedText() != true,
                   abs(lastObservedMagnification - scrollView.magnification) > 0.0001 {
                    let scale = scrollView.magnification
                    lastObservedMagnification = scale
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isActive,
                              abs(scrollView.magnification - scale) < 0.0001 else { return }
                        self.magnificationDidChange?(scale)
                    }
                }
                let sizeChanged = lastClipBoundsSize.map {
                    abs($0.width - bounds.width) > 0.5
                        || abs($0.height - bounds.height) > 0.5
                } ?? true
                let originChanged = lastClipBoundsOrigin.map {
                    abs($0.x - bounds.origin.x) > 0.5
                        || abs($0.y - bounds.origin.y) > 0.5
                } ?? true
                lastClipBoundsSize = bounds.size
                lastClipBoundsOrigin = bounds.origin
                if sizeChanged { applyWritingModes() }
                if originChanged, !isTypewriterScrolling, let event = NSApp.currentEvent,
                   event.type == .scrollWheel || event.type == .leftMouseDragged || event.type == .leftMouseDown {
                    writingUserDidScroll()
                }

                resetHorizontalScrollIfNeeded()
                if sizeChanged {
                    scheduleResizeLayout(wordWrap: wordWrap)
                    DispatchQueue.main.async { [weak self] in
                        self?.applyVisibleLigatures()
                        self?.markdownPresentation?.viewportChanged()
                        self?.applyFindHighlights()
                    }
                    return
                }
                guard originChanged else { return }
                schedulePreviewScrollSync()
                applyVisibleLigatures()
                applyFindHighlights()
                refreshRulerForViewportChange()
                Task { @MainActor [weak self] in
                    self?.markdownPresentation?.viewportChanged()
                }
                scheduleHighlight()
                scheduleDirectionalLayoutPrefetch()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, isActive else { return }
                scheduleResizeLayout(wordWrap: wordWrap)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak scrollView] notification in
                guard let self, let scrollView,
                      notification.object as? NSWindow === scrollView.window else { return }
                finishLiveResize()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.revealSelection,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorSelectionRequest,
                      request.documentID == document.id,
                      let textView else { return }
                let length = textView.textStorage?.length ?? 0
                let location = min(request.range.location, length)
                let range = NSRange(location: location, length: min(request.range.length, length - location))
                clearFoldIfNeeded(toReveal: range)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                if request.focusesEditor { textView.window?.makeFirstResponder(textView) }
                applyFindHighlights()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.findHighlights,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? FindHighlightRequest,
                      request.documentID == document.id else { return }
                findHighlightMatches = request.matches
                findMatchesChanged = true
                applyFindHighlights()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.toggleFold,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      notification.object as? UUID == document.id else { return }
                toggleFold()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.undo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      notification.object as? UUID == document.id else { return }
                textView?.undoManager?.undo()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.redo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      notification.object as? UUID == document.id else { return }
                textView?.undoManager?.redo()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.applyTextUpdate,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorTextUpdateRequest,
                      request.documentID == document.id,
                      let textView else { return }
                clearFindHighlights()
                apply(request, to: textView)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.markdownClipboard,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let request = notification.object as? MarkdownClipboardRequest,
                      request.documentID == self.document.id, self.isActive else { return }
                switch request.command {
                case .copyMarkdown: _ = self.copyRichText(.general, child: self.tableCellEditor, mode: .markdown)
                case .copyHTML: _ = self.copyRichText(.general, child: self.tableCellEditor, mode: .html)
                case .pasteSource: self.pasteClipboardSource(.general)
                case .copyCodeBlock: self.performCodeBlockCommand(changeLanguage: false)
                case .setCodeLanguage: self.performCodeBlockCommand(changeLanguage: true)
                }
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.extractTextSelection,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorTextExtractionRequest,
                      request.documentID == document.id else { return }
                extractSelection(for: request)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.formatMarkdown,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? MarkdownFormattingRequest,
                      request.documentID == document.id else { return }
                applyMarkdownFormatting(request.command)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.applyRangeReplacement,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorRangeReplacementRequest,
                      request.documentID == document.id,
                      let textView else { return }
                clearFindHighlights()
                apply(request, to: textView)
            })
        }

        private func diagramMenu(at point: NSPoint) -> [NSMenuItem] {
            guard let controller = markdownPresentation, let resource = controller.diagramResource(at: point),
                  controller.isCurrentDiagramResource(resource) else { return [] }
            let copy = NSMenuItem(title: L10n.tr("复制图表为图片"), action: #selector(copyDiagram(_:)), keyEquivalent: "")
            let save = NSMenuItem(title: L10n.tr("图表另存为…"), action: #selector(saveDiagram(_:)), keyEquivalent: "")
            for item in [copy, save] { item.target = self; item.representedObject = resource }
            return [copy, save]
        }

        private func diagramBitmap(_ resource: MarkdownPresentationController.DiagramResource, type: NSBitmapImageRep.FileType) -> Data? {
            guard let tiff = resource.image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: type, properties: [:])
        }

        @objc private func copyDiagram(_ sender: NSMenuItem) {
            guard let resource = sender.representedObject as? MarkdownPresentationController.DiagramResource,
                  markdownPresentation?.isCurrentDiagramResource(resource) == true,
                  let png = diagramBitmap(resource, type: .png) else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.setData(png, forType: .png)
        }

        @objc private func saveDiagram(_ sender: NSMenuItem) {
            guard let resource = sender.representedObject as? MarkdownPresentationController.DiagramResource,
                  markdownPresentation?.isCurrentDiagramResource(resource) == true, let window = textView?.window else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "diagram.png"
            panel.allowedContentTypes = resource.svg == nil ? [.png, .jpeg] : [.png, .jpeg, .svg]
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url,
                      self.markdownPresentation?.isCurrentDiagramResource(resource) == true else { return }
                let data: Data?
                switch url.pathExtension.lowercased() {
                case "svg": data = resource.svg
                case "jpg", "jpeg": data = self.diagramBitmap(resource, type: .jpeg)
                case "png": data = self.diagramBitmap(resource, type: .png)
                default: data = nil
                }
                do {
                    guard let data else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                } catch { resource.document.statusMessage = L10n.tr("无法保存图表") }
            }
        }

        private func moveTableSelectionToParent(allowVirtual: Bool = false) -> Bool {
            guard let child = tableCellEditor else { return true }
            guard let textView, let storage = textView.textStorage else { return false }
            let childSelection = child.selectedRange(), original = tableCellOriginal
            guard !child.hasMarkedText(),
                  let range = tableCellRange, tableCellRevision == contentRevision,
                  range.location <= storage.length, range.length <= storage.length - range.location,
                  child.string == MarkdownTableCellEditor.projection(original).text,
                  storage.mutableString.substring(with: range) == original else { return false }
            let projection = MarkdownTableCellEditor.projection(original)
            guard childSelection.location != NSNotFound, childSelection.location < projection.rawBoundaries.count,
                  childSelection.length <= projection.rawBoundaries.count - 1 - childSelection.location,
                  allowVirtual || tableCellVirtualSeparators == 0 else { return false }
            let revision = contentRevision
            finishTableCell()
            guard revision == contentRevision, range.location <= storage.length,
                  range.length <= storage.length - range.location,
                  storage.mutableString.substring(with: range) == original else { return false }
            textView.window?.makeFirstResponder(textView)
            let start = projection.rawBoundaries[childSelection.location]
            let end = projection.rawBoundaries[NSMaxRange(childSelection)]
            textView.setSelectedRange(NSRange(location: range.location + start, length: end - start))
            return true
        }

        private func applyMarkdownFormatting(_ command: MarkdownFormattingCommand) {
            guard isActive, document.language == .markdown, document.ioState == .idle,
                  let textView, textView.isEditable, !textView.hasMarkedText(),
                  textView.selectedRanges.count == 1, let storage = textView.textStorage else { return }
            var tableColumn: Int?
            if tableCellEditor != nil {
                if tableCellVirtualSeparators > 0 {
                    guard case .table = command else { return }
                    tableColumn = tableCellColumn
                }
                guard moveTableSelectionToParent(allowVirtual: tableColumn != nil) else { return }
            }
            let selection = textView.selectedRange()
            let revision = contentRevision
            let edit: MarkdownFormattingEdit?
            if let tableColumn, case let .table(tableCommand) = command {
                edit = MarkdownTableEditingService.edit(in: storage.mutableString, selection: selection,
                                                        command: tableCommand, columnOverride: tableColumn)
            } else {
                edit = MarkdownFormattingService.edit(in: storage.mutableString, selection: selection, command: command, strictMode: syntaxOptions.strictMode)
            }
            guard let edit,
                  revision == contentRevision, textView.selectedRange() == selection else { return }
            let original = storage.mutableString.substring(with: edit.range)
            guard original != edit.replacement else { return }
            textView.breakUndoCoalescing()
            let undoManager = textView.undoManager
            undoManager?.beginUndoGrouping()
            defer {
                undoManager?.endUndoGrouping()
                textView.breakUndoCoalescing()
            }
            isApplyingAutomatedEdit = true
            defer { isApplyingAutomatedEdit = false }
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(edit.selectionRange)
            textView.scrollRangeToVisible(edit.selectionRange)
            undoManager?.setActionName(command.actionName)
        }

        private func finishTableDrag(_ start: FoldLayoutManager.TableDragHandle, target: FoldLayoutManager.TableDragHandle?) {
            defer { tableDragSnapshot = nil }
            guard let snapshot = tableDragSnapshot, let target, target.tableRange == start.tableRange,
                  target.axis == start.axis, isActive, document.language == .markdown, document.isMarkdownFormatted,
                  document.ioState == .idle, let view = textView, view.isEditable, !view.hasMarkedText(), tableCellEditor == nil,
                  contentRevision == snapshot.revision, snapshot.range == start.tableRange, let storage = view.textStorage,
                  snapshot.range.location <= storage.length, snapshot.range.length <= storage.length - snapshot.range.location,
                  storage.mutableString.substring(with: snapshot.range) == snapshot.text else { return }
            let positions = start.axis == .row ? target.row - start.row : target.column - start.column
            guard let edit = MarkdownTableEditingService.move(in: storage.mutableString,
                    selection: NSRange(location: start.cell.range.location, length: 0), rows: start.axis == .row,
                    positions: positions), edit.range.location <= storage.length,
                  edit.range.length <= storage.length - edit.range.location else { return }
            view.breakUndoCoalescing()
            view.undoManager?.beginUndoGrouping()
            defer { view.undoManager?.endUndoGrouping(); view.breakUndoCoalescing() }
            isApplyingAutomatedEdit = true
            defer { isApplyingAutomatedEdit = false }
            guard view.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            view.didChangeText()
            view.setSelectedRange(edit.selectionRange)
            view.undoManager?.setActionName(L10n.tr("表格"))
        }

        @discardableResult
        func beginTableCell(_ range: NSRange, frame: NSRect, cell: MarkdownTableCell? = nil) -> Bool {
            guard isActive, document.language == .markdown, document.isMarkdownFormatted,
                  document.ioState == .idle, let textView, textView.isEditable,
                  !textView.hasMarkedText(), tableCellEditor?.hasMarkedText() != true, let storage = textView.textStorage,
                  range.location != NSNotFound, range.location >= 0, range.length >= 0,
                  range.location <= storage.length, range.length <= storage.length - range.location else { return false }
            cancelMarkdownLinkNavigation()
            finishTableCell()
            let child = MarkdownTableCellEditor(frame: frame)
            child.delegate = child
            child.beginTextChecking = { [weak self] options in self?.beginSmartTextChecking(options, child: true) ?? options }
            child.filterTextCheckingResults = { [weak self, weak child] results, options in
                guard let self, let child else { return [] }
                return self.filterSmartSubstitutions(results, options: options, child: child)
            }
            child.isRichText = false
            child.allowsUndo = false
            child.font = textView.font
            let raw = storage.mutableString.substring(with: range)
            child.string = MarkdownTableCellEditor.projection(raw).text
            tableCellRange = range
            tableCellContextID = UUID()
            tableCellVirtualSeparators = cell?.virtualSeparators ?? 0
            tableCellHasVirtualHistory = tableCellVirtualSeparators > 0
            tableCellColumn = cell?.column ?? 0
            let presentation = markdownPresentation?.currentTablePresentation(document: document, revision: contentRevision)
                ?? MarkdownPresentationParser.parse(storage.string, syntax: aiPreferences?.markdownSyntax ?? .init())
            tableCellPresentation = presentation
            tableCellIsCompletedTask = presentation.completedTaskRanges.contains {
                $0.location <= range.location && NSMaxRange(range) <= NSMaxRange($0)
            }
            tableCellRowStart = presentation.tables.flatMap(\.rows).first(where: {
                NSLocationInRange(range.location, $0.range) || range.location == NSMaxRange($0.range)
            })?.range.location
            if cell == nil, let found = presentation.tables.flatMap(\.rows).flatMap(\.cells).first(where: { $0.range == range }) {
                tableCellColumn = found.column
            }
            tableCellTableRange = presentation.tables.first(where: {
                $0.rows.contains(where: { $0.cells.contains(where: { $0.range == range }) })
            })?.range
            if let table = presentation.tables.first(where: { $0.range == tableCellTableRange }) {
                tableCellRowIndex = table.rows.firstIndex(where: {
                    NSLocationInRange(range.location, $0.range) || range.location == NSMaxRange($0.range)
                })
            }
            foldLayoutManager?.setActiveTableRange(tableCellTableRange)
            tableCellOriginal = raw
            tableCellRevision = contentRevision
            tableCellHadComposition = false
            tableCellUndoCount = 0
            tableCellRedoCount = 0
            tableCellEditor = child
            child.compositionStartHandler = { [weak self] marked in
                guard let self else { return }
                self.scrollView?.allowsMagnification = !marked && self.textView?.hasMarkedText() != true
            }
            markdownPresentation?.tableEditingGeometryChanged(cell: range)
            updateTableCellWritingDirection()
            updateTableCellVerticalGlyphForm()
            updateTableCellTaskStrike()
            updateSmartSubstitutionSettings()
            applyLigatures(to: child, range: NSRange(location: 0, length: (child.string as NSString).length), value: editorLigatures)
            applyTableCellColors()
            child.validateChange = { [weak self, weak child] range, replacement in
                guard let self, let child, self.tableCellRevision == self.contentRevision,
                      range.location != NSNotFound, range.location <= (child.string as NSString).length,
                      range.length <= (child.string as NSString).length - range.location else { return false }
                let display = (child.string as NSString).replacingCharacters(in: range, with: replacement)
                return MarkdownTableCellEditor.sourceText(raw: self.tableCellOriginal, display: display) != nil
            }
            child.contentDidChange = { [weak self] in
                self?.updateSyntaxOptions()
                self?.applyTableCellColors(); self?.tableCellChanged(); self?.updateTableCellTaskStrike()
            }
            child.mathPairEnabled = { [weak self, weak child] in
                guard let self, let child else { return false }
                return self.isActive && self.tableCellEditor === child && self.tableCellRevision == self.contentRevision &&
                    self.textView?.autoPairMarkdownEnabled == true && self.textView?.isEditable == true &&
                    self.textView?.hasMarkedText() == false && self.currentLanguage == .markdown &&
                    self.document.language == .markdown && self.document.ioState == .idle &&
                    !self.isApplyingAutomatedEdit && !self.isApplyingExternalUpdate
            }
            child.mathPairAllowed = { [weak self, weak child] selected in
                guard let self, self.aiPreferences?.markdownInlineMath != false, let child, self.tableCellEditor === child, !child.hasMarkedText(),
                      child.selectedRanges.count == 1, child.selectedRange() == selected,
                      self.tableCellVirtualSeparators == 0, let range = self.tableCellRange,
                      self.tableCellRevision == self.contentRevision, let storage = self.textView?.textStorage,
                      range.location <= storage.length, range.length <= storage.length - range.location,
                      storage.mutableString.substring(with: range) == self.tableCellOriginal else { return false }
                let projection = MarkdownTableCellEditor.projection(self.tableCellOriginal)
                guard projection.text == child.string, selected.location != NSNotFound,
                      selected.location < projection.rawBoundaries.count,
                      selected.length <= projection.rawBoundaries.count - 1 - selected.location else { return false }
                let start = projection.rawBoundaries[selected.location], end = projection.rawBoundaries[NSMaxRange(selected)]
                return self.markdownPresentation?.allowsMathPair(document: self.document, revision: self.contentRevision,
                    range: NSRange(location: range.location + start, length: end - start)) == true
            }
            child.acceptEmojiCompletion = { [weak self, weak child] word, range in
                guard let child else { return false }
                return self?.acceptEmojiCompletion(word, range: range, child: child) ?? false
            }
            child.dismissEmojiCompletion = { [weak self] in self?.endEmojiCompletion() }
            child.emojiTyped = { [weak self, weak child] value in
                guard let self, let child, child === self.tableCellEditor, !child.hasMarkedText() else { return }
                if value == ":" {
                    if self.emojiCompletionRequested { self.endEmojiCompletion(); return }
                    self.emojiCompletionRequested = true
                } else if !self.emojiCompletionRequested { return }
                else if !value.utf16.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 43 || $0 == 45 }) {
                    self.endEmojiCompletion(); return
                }
                self.markdownPresentation?.requestEmojiCompletionAfterTableEdit()
            }
            child.markdownLinkHandler = { [weak self, weak child] point in
                guard let self, let child else { return false }
                return self.navigateTableCellLink(child, at: point)
            }
            child.mathReferenceHandler = { [weak self, weak child] point in
                guard let self, let child else { return false }
                return self.navigateTableCellMathReference(child, at: point)
            }
            child.richPaste = { [weak self, weak child] board in
                guard let self, let child else { return false }
                return self.pasteRichText(board, child: child)
            }
            child.richCopy = { [weak self, weak child] board in
                guard let self, let child else { return false }
                return self.copyRichText(board, child: child)
            }
            child.canTransferImage = { [weak textView] pasteboard, preferText in
                textView?.imageTransfer(from: pasteboard, preferText: preferText) != nil
            }
            child.imageTransfer = { [weak textView, weak child] pasteboard, preferText in
                guard let textView, let child, child.isEditable,
                      let transfer = textView.imageTransfer(from: pasteboard, preferText: preferText) else { return false }
                if !child.hasMarkedText() { _ = textView.imageTransferHandler?(transfer) }
                return true
            }
            child.navigate = { [weak self] backwards in self?.navigateTableCell(backwards: backwards) ?? false }
            child.undoAction = { [weak self] redo in self?.undoTableCell(redo: redo) ?? false }
            child.rowCommand = { [weak self] delete in self?.applyTableRowShortcut(delete: delete) ?? false }
            textView.addSubview(child)
            textView.window?.makeFirstResponder(child)
            return true
        }

        private func tableCellSource() -> String? {
            guard let textView, let storage = textView.textStorage, let child = tableCellEditor,
                  let range = tableCellRange, tableCellRevision == contentRevision,
                  range.location <= storage.length, range.length <= storage.length - range.location,
                  storage.mutableString.substring(with: range) == tableCellOriginal else { return nil }
            guard let value = MarkdownTableCellEditor.sourceText(raw: tableCellOriginal, display: child.string) else { return nil }
            let prefix = value.isEmpty ? "" : String(repeating: "|", count: tableCellVirtualSeparators)
            return storage.mutableString.replacingCharacters(in: range, with: prefix + value)
        }

        private func tableCellChanged() {
            guard !applyingTableCell, let child = tableCellEditor, let textView,
                  let storage = textView.textStorage, let range = tableCellRange,
                  tableCellRevision == contentRevision, range.location <= storage.length,
                  range.length <= storage.length - range.location,
                  storage.mutableString.substring(with: range) == tableCellOriginal else { return }
            if child.hasMarkedText() {
                tableCellHadComposition = true
                document.noteLiveEdit(isEmpty: false)
                return
            }
            let completedComposition = tableCellHadComposition
            defer {
                if completedComposition { applyVisibleLigatures(); updateTableCellVerticalGlyphForm(); markdownPresentation?.metricsChanged() }
                if !child.hasMarkedText() {
                    if textView.hasMarkedText() == false { scrollView?.allowsMagnification = true }
                    let update = pendingTableTextMetrics
                    pendingTableTextMetrics = nil
                    update?()
                    finishPendingMagnification()
                }
            }
            guard let replacement = MarkdownTableCellEditor.sourceText(raw: tableCellOriginal, display: child.string) else { return }
            guard replacement != tableCellOriginal else {
                if tableCellHadComposition {
                    tableCellHadComposition = false
                    document.noteLiveEdit(isEmpty: storage.length == 0)
                    document.refreshDirtyState()
                }
                return
            }
            let htmlContextChanged = Self.tableEditChangesHTMLContext(before: tableCellOriginal, after: replacement)
            tableCellHadComposition = false
            applyingTableCell = true
            defer { applyingTableCell = false }
            textView.breakUndoCoalescing()
            let undo = textView.undoManager
            undo?.beginUndoGrouping()
            defer { undo?.endUndoGrouping(); textView.breakUndoCoalescing() }
            isApplyingAutomatedEdit = true
            defer { isApplyingAutomatedEdit = false }
            let prefix = String(repeating: "|", count: tableCellVirtualSeparators)
            let inserted = prefix + replacement
            guard textView.shouldChangeText(in: range, replacementString: inserted) else {
                child.string = MarkdownTableCellEditor.projection(tableCellOriginal).text
                document.noteLiveEdit(isEmpty: storage.length == 0)
                document.refreshDirtyState()
                return
            }
            let oldTableRange = tableCellTableRange
            storage.replaceCharacters(in: range, with: inserted)
            tableCellRange = NSRange(location: range.location + (prefix as NSString).length, length: (replacement as NSString).length)
            tableCellVirtualSeparators = 0
            if let tableRange = tableCellTableRange {
                tableCellTableRange = NSRange(location: tableRange.location, length: tableRange.length + (inserted as NSString).length - range.length)
            }
            tableCellOriginal = replacement
            tableCellRevision = contentRevision
            tableCellUndoCount += 1
            tableCellRedoCount = 0
            textView.didChangeText()
            restoreActiveTable(oldTable: oldTableRange, edit: range, replacementLength: (inserted as NSString).length, htmlContextChanged: htmlContextChanged)
        }

        private static func tableEditChangesHTMLContext(before: String, after: String) -> Bool {
            let old = before as NSString, new = after as NSString
            var prefix = 0, suffix = 0
            while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            while suffix < old.length - prefix && suffix < new.length - prefix &&
                    old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) { suffix += 1 }
            func sensitive(_ text: NSString, end: Int) -> Bool {
                var open = false
                var quote: unichar?, comment = false, position = 0
                while position < end {
                    let unit = text.character(at: position)
                    if comment {
                        if position + 2 < end, unit == 45, text.character(at: position + 1) == 45, text.character(at: position + 2) == 62 {
                            comment = false; open = false; position += 3; continue
                        }
                    } else if open {
                        if let current = quote {
                            if unit == current { quote = nil }
                        } else if unit == 34 || unit == 39 { quote = unit }
                        else if unit == 62 { open = false }
                    } else if unit == 60 {
                        open = true
                        if position + 3 < text.length, text.character(at: position + 1) == 33,
                           text.character(at: position + 2) == 45, text.character(at: position + 3) == 45 { comment = true }
                    }
                    position += 1
                }
                return open
            }
            for (text, end) in [(old, old.length - suffix), (new, new.length - suffix)] {
                if sensitive(text, end: prefix) { return true }
                for position in prefix..<end where text.character(at: position) == 60 || text.character(at: position) == 62 { return true }
            }
            return false
        }

        private func restoreActiveTable(oldTable: NSRange?, edit: NSRange, replacementLength: Int, htmlContextChanged: Bool = false) {
            guard let view = textView, let storage = view.textStorage, let layout = foldLayoutManager,
                  let range = tableCellTableRange, let oldTable, let presentation = tableCellPresentation,
                  let original = presentation.tables.first(where: { $0.range == oldTable }),
                  let table = updatedActiveTable(original, range: range, edit: edit, replacementLength: replacementLength) else { return }
            let updated: MarkdownPresentation
            if htmlContextChanged {
                var rows: [MarkdownTableRow] = []
                for row in table.rows {
                    var cells: [MarkdownTableCell] = []
                    for cell in row.cells {
                        guard cell.range.location >= 0, NSMaxRange(cell.range) <= storage.length else { return }
                        cells.append(MarkdownTableCell(range: cell.range, column: cell.column,
                            virtualSeparators: cell.virtualSeparators,
                            displayText: storage.mutableString.substring(with: cell.range), displayRuns: []))
                    }
                    rows.append(MarkdownTableRow(range: row.range, cells: cells))
                }
                let rawTable = MarkdownTable(range: table.range, delimiterRange: table.delimiterRange,
                    alignments: table.alignments, rows: rows, containerPrefix: table.containerPrefix,
                    quoteDepth: table.quoteDepth, nestedList: table.nestedList, referenceLabels: table.referenceLabels)
                updated = MarkdownPresentation(spans: [], tables: [rawTable])
            } else {
                updated = presentation.replacingTable(table, oldTable: oldTable, edit: edit, replacementLength: replacementLength)
            }
            tableCellPresentation = updated
            if let markdownPresentation {
                markdownPresentation.installTablePresentation(updated, document: document, revision: contentRevision)
            } else {
                layout.setMarkdownPresentation(updated, revealedRange: nil, invalidating: range)
            }
            layout.setActiveTableRange(range)
            markdownPresentation?.tableEditingGeometryChanged(cell: tableCellRange)
            updateTableCellFrame()
        }

        private func updatedActiveTable(_ table: MarkdownTable, range: NSRange, edit: NSRange, replacementLength: Int) -> MarkdownTable? {
            guard let storage = textView?.textStorage, let index = tableCellRowIndex, table.rows.indices.contains(index) else { return nil }
            let oldRow = table.rows[index], delta = replacementLength - edit.length
            guard oldRow.range.location <= edit.location, NSMaxRange(edit) <= NSMaxRange(oldRow.range),
                  oldRow.range.length + delta >= 0 else { return nil }
            let rowRange = NSRange(location: oldRow.range.location, length: oldRow.range.length + delta)
            guard let parsed = MarkdownTableEditingService.presentationRow(in: storage.mutableString, range: rowRange,
                                                                           columns: table.alignments.count) else { return nil }
            let row = MarkdownPresentationParser.tableRowDisplay(parsed, text: storage.mutableString, previous: oldRow,
                                                                 changedColumn: tableCellColumn, referenceLabels: table.referenceLabels,
                                                                 syntax: aiPreferences?.markdownSyntax ?? .init())
            let delimiter = table.delimiterRange.location >= NSMaxRange(edit)
                ? NSRange(location: table.delimiterRange.location + delta, length: table.delimiterRange.length) : table.delimiterRange
            return MarkdownTable(range: range, delimiterRange: delimiter, alignments: table.alignments,
                                 rows: table.rows.replacing(index, row: row, delta: delta),
                                 containerPrefix: table.containerPrefix, quoteDepth: table.quoteDepth,
                                 nestedList: table.nestedList, referenceLabels: table.referenceLabels)
        }

        private func updateTableCellFrame() {
            guard let view = textView, let child = tableCellEditor, let range = tableCellRange,
                  let layout = foldLayoutManager, let container = view.textContainer,
                  let frame = layout.markdownTableFrame(for: MarkdownTableCell(range: range, column: tableCellColumn,
                      virtualSeparators: tableCellVirtualSeparators), in: container) else { return }
            child.frame = frame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        }

        private func undoTableCell(redo: Bool) -> Bool {
            guard let view = textView, let child = tableCellEditor, let range = tableCellRange,
                  !child.hasMarkedText(), let storage = view.textStorage, let undo = view.undoManager,
                  redo ? undo.canRedo : undo.canUndo else { return false }
            if (redo ? tableCellRedoCount : tableCellUndoCount) == 0 {
                finishTableCell()
                if redo { undo.redo() } else { undo.undo() }
                return true
            }
            let oldLength = storage.length
            let oldText = tableCellOriginal
            let oldTableRange = tableCellTableRange
            let oldVirtualSeparators = tableCellVirtualSeparators
            applyingTableCell = true
            defer { applyingTableCell = false }
            if redo {
                undo.redo()
                tableCellRedoCount -= 1
                tableCellUndoCount += 1
            } else {
                undo.undo()
                tableCellUndoCount -= 1
                tableCellRedoCount += 1
            }
            if tableCellHasVirtualHistory, let oldTableRange, let rowStart = tableCellRowStart {
                let delta = storage.length - oldLength
                let length = oldTableRange.length + delta
                let newTableRange = NSRange(location: oldTableRange.location, length: max(0, length))
                guard length >= 0, let original = tableCellPresentation?.tables.first(where: { $0.range == oldTableRange }),
                      let rowIndex = tableCellRowIndex, original.rows.indices.contains(rowIndex),
                      original.rows[rowIndex].range.location == rowStart,
                      original.rows[rowIndex].range.length + delta >= 0,
                      let row = MarkdownTableEditingService.presentationRow(in: storage.mutableString,
                          range: NSRange(location: rowStart, length: original.rows[rowIndex].range.length + delta), columns: original.alignments.count),
                      let cell = row.cells.first(where: { $0.column == tableCellColumn }) else {
                    finishTableCell()
                    view.window?.makeFirstResponder(view)
                    return true
                }
                tableCellRange = cell.range
                tableCellVirtualSeparators = cell.virtualSeparators
                tableCellTableRange = newTableRange
                tableCellOriginal = storage.mutableString.substring(with: cell.range)
                tableCellRevision = contentRevision
                child.string = MarkdownTableCellEditor.projection(tableCellOriginal).text
                child.setSelectedRange(NSRange(location: min(child.selectedRange().location, (child.string as NSString).length), length: 0))
                let changedRange: NSRange
                let replacementLength: Int
                if oldVirtualSeparators == 0 && cell.virtualSeparators > 0 {
                    changedRange = NSRange(location: cell.range.location, length: NSMaxRange(range) - cell.range.location)
                    replacementLength = 0
                } else if oldVirtualSeparators > 0 && cell.virtualSeparators == 0 {
                    changedRange = range
                    replacementLength = NSMaxRange(cell.range) - range.location
                } else {
                    changedRange = range
                    replacementLength = cell.range.length
                }
                restoreActiveTable(oldTable: oldTableRange, edit: changedRange, replacementLength: replacementLength,
                                   htmlContextChanged: Self.tableEditChangesHTMLContext(before: oldText, after: tableCellOriginal))
                return true
            }
            let newLength = range.length + storage.length - oldLength
            guard newLength >= 0, range.location <= storage.length, newLength <= storage.length - range.location else {
                finishTableCell()
                return true
            }
            let updated = NSRange(location: range.location, length: newLength)
            tableCellRange = updated
            if let tableRange = tableCellTableRange {
                tableCellTableRange = NSRange(location: tableRange.location, length: tableRange.length + newLength - range.length)
            }
            tableCellOriginal = storage.mutableString.substring(with: updated)
            tableCellRevision = contentRevision
            child.string = MarkdownTableCellEditor.projection(tableCellOriginal).text
            child.setSelectedRange(NSRange(location: min(child.selectedRange().location, (child.string as NSString).length), length: 0))
            restoreActiveTable(oldTable: oldTableRange, edit: range, replacementLength: newLength,
                               htmlContextChanged: Self.tableEditChangesHTMLContext(before: oldText, after: tableCellOriginal))
            return true
        }

        private func applyTableRowShortcut(delete: Bool) -> Bool {
            guard let view = textView, view.isEditable, let child = tableCellEditor, !child.hasMarkedText(),
                  let tableRange = tableCellTableRange, let range = tableCellRange, let storage = view.textStorage,
                  tableCellRevision == contentRevision else { return false }
            let command: MarkdownTableCommand = delete ? .deleteRow : .insertRowAfter
            guard MarkdownTableEditingService.edit(in: storage.mutableString, selection: NSRange(location: range.location, length: 0),
                                                   command: command, columnOverride: tableCellVirtualSeparators > 0 ? tableCellColumn : nil) != nil else { return true }
            let oldRevision = contentRevision
            applyMarkdownFormatting(.table(command))
            guard contentRevision != oldRevision,
                  let table = MarkdownPresentationParser.parse(storage.string, syntax: syntaxOptions).tables.first(where: { $0.range.location == tableRange.location }),
                  let row = table.rows.first(where: { NSLocationInRange(view.selectedRange().location, $0.range) })
                      ?? table.rows.first(where: { view.selectedRange().location == NSMaxRange($0.range) }),
                  let cell = row.cells.first, let layout = view.layoutManager as? FoldLayoutManager,
                  let container = view.textContainer, row.range.location < storage.length else { return true }
            layout.ensureLayout(forCharacterRange: row.range)
            let glyph = layout.glyphIndexForCharacter(at: row.range.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let indent = (table.containerPrefix as NSString).size(withAttributes: [.font: layout.textFont]).width + 12
            let width = max(1, container.size.width - 2 * container.lineFragmentPadding - indent)
            let rowTable = MarkdownTable(range: row.range, delimiterRange: table.delimiterRange, alignments: table.alignments, rows: [row])
            guard let geometry = layout.markdownTableGeometry(rowTable, text: storage.mutableString, width: width).first(where: { $0.cell == cell }) else { return true }
            let headerOffset: CGFloat = table.rows.first == row ? 12 : 0
            let frame = geometry.rect.offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent + view.textContainerOrigin.x,
                                               dy: fragment.minY + headerOffset + view.textContainerOrigin.y)
            _ = beginTableCell(cell.range, frame: frame, cell: cell)
            return true
        }

        private func navigateTableCell(backwards: Bool) -> Bool {
            guard let view = textView, let storage = view.textStorage, let range = tableCellRange,
                  tableCellRevision == contentRevision, tableCellEditor?.hasMarkedText() == false else { return false }
            var parsed = MarkdownPresentationParser.parse(storage.string, syntax: syntaxOptions)
            guard var table = parsed.tables.first(where: { NSLocationInRange(range.location, $0.range) || range.location == NSMaxRange($0.range) }),
                  let current = table.rows.flatMap(\.cells).firstIndex(where: { $0.range == range && $0.column == tableCellColumn }) else { return false }
            var cells = table.rows.flatMap(\.cells)
            if backwards && current == 0 { finishTableCell(); view.window?.makeFirstResponder(view); return true }
            if !backwards && current == cells.count - 1 {
                guard let edit = MarkdownTableEditingService.edit(in: storage.mutableString, selection: NSRange(location: range.location, length: 0), command: .insertRowAfter) else { return true }
                let undo = view.undoManager
                undo?.beginUndoGrouping()
                isApplyingAutomatedEdit = true
                if view.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                    storage.replaceCharacters(in: edit.range, with: edit.replacement)
                    view.didChangeText()
                }
                isApplyingAutomatedEdit = false
                undo?.endUndoGrouping()
                parsed = MarkdownPresentationParser.parse(storage.string, syntax: syntaxOptions)
                guard let updated = parsed.tables.first(where: { $0.range.location == table.range.location }) else { finishTableCell(); return true }
                table = updated
                cells = table.rows.flatMap(\.cells)
            }
            let next = backwards ? current - 1 : current + 1
            guard next >= 0, next < cells.count, let layout = view.layoutManager as? FoldLayoutManager,
                  let container = view.textContainer,
                  let row = table.rows.first(where: { $0.cells.contains(cells[next]) }),
                  row.range.location < storage.length else { return true }
            let glyph = layout.glyphIndexForCharacter(at: row.range.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let indent = (table.containerPrefix as NSString).size(withAttributes: [.font: layout.textFont]).width + 12
            let width = max(1, container.size.width - 2 * container.lineFragmentPadding - indent)
            let rowTable = MarkdownTable(range: row.range, delimiterRange: table.delimiterRange, alignments: table.alignments, rows: [row])
            guard let geometry = layout.markdownTableGeometry(rowTable, text: storage.mutableString, width: width).first(where: { $0.cell == cells[next] }) else { return true }
            let headerOffset: CGFloat = table.rows.first == row ? 12 : 0
            let frame = geometry.rect.offsetBy(dx: fragment.minX + container.lineFragmentPadding + indent + view.textContainerOrigin.x,
                                               dy: fragment.minY + headerOffset + view.textContainerOrigin.y)
            // The structural edit invalidates the old range; do not recommit it.
            tableCellEditor?.contentDidChange = nil
            tableCellEditor?.removeFromSuperview()
            tableCellEditor = nil
            tableCellRange = nil
            markdownPresentation?.tableEditingGeometryChanged(cell: nil)
            tableCellVirtualSeparators = 0
            return beginTableCell(cells[next].range, frame: frame, cell: cells[next])
        }

        func updateTableCellWritingDirection() {
            guard let child = tableCellEditor, !child.hasMarkedText(), textView?.hasMarkedText() == false else { return }
            let direction: NSWritingDirection = document.isMarkdownFormatted && foldLayoutManager?.markdownRightToLeft == true ? .rightToLeft : .natural
            if child.defaultParagraphStyle?.baseWritingDirection == direction { return }
            let style = (child.defaultParagraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.baseWritingDirection = direction
            child.defaultParagraphStyle = style
            var typing = child.typingAttributes
            typing[.paragraphStyle] = style
            child.typingAttributes = typing
            if let storage = child.textStorage, storage.length > 0 {
                storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
            }
        }

        private func updateTableCellVerticalGlyphForm() {
            guard let child = tableCellEditor, !child.hasMarkedText(), textView?.hasMarkedText() == false,
                  let storage = child.textStorage else { return }
            let value: Int? = markdownVerticalWriting ? 1 : nil
            var typing = child.typingAttributes
            if let value { typing[.verticalGlyphForm] = value } else { typing.removeValue(forKey: .verticalGlyphForm) }
            child.typingAttributes = typing
            let range = NSRange(location: 0, length: storage.length)
            guard range.length > 0 else { return }
            var changes: [NSRange] = []
            storage.enumerateAttribute(.verticalGlyphForm, in: range) { existing, part, _ in
                if (existing as? NSNumber)?.intValue != value { changes.append(part) }
            }
            for part in changes {
                if let value { storage.addAttribute(.verticalGlyphForm, value: value, range: part) }
                else { storage.removeAttribute(.verticalGlyphForm, range: part) }
            }
        }

        private func updateTableCellTaskStrike() {
            guard let child = tableCellEditor, !child.hasMarkedText(), textView?.hasMarkedText() == false,
                  tableCellRange != nil, let layout = child.layoutManager else { return }
            let length = (child.string as NSString).length
            guard length > 0 else { return }
            let whole = NSRange(location: 0, length: length)
            layout.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: whole)
            guard document.isMarkdownFormatted, strikeCompletedTasks,
                  tableCellIsCompletedTask else { return }
            layout.addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: whole)
        }

        func finishTableCell() {
            guard let child = tableCellEditor else { return }
            if emojiCompletionRequested { endEmojiCompletion() }
            if child.hasMarkedText() { child.unmarkText() }
            tableCellChanged()
            child.contentDidChange = nil
            child.removeFromSuperview()
            tableCellEditor = nil
            tableCellRange = nil
            markdownPresentation?.tableEditingGeometryChanged(cell: nil)
            tableCellVirtualSeparators = 0
            tableCellHasVirtualHistory = false
            tableCellRowStart = nil
            tableCellRowIndex = nil
            tableCellTableRange = nil
            tableCellPresentation = nil
            tableCellIsCompletedTask = false
            let update = pendingTableTextMetrics
            pendingTableTextMetrics = nil
            update?()
            if textView?.hasMarkedText() != true { scrollView?.allowsMagnification = true }
            finishPendingMagnification()
        }

        func applyOrDeferTableTextMetrics(_ update: (() -> Void)?) {
            if tableCellEditor?.hasMarkedText() == true { pendingTableTextMetrics = update }
            else { pendingTableTextMetrics = nil; update?() }
        }

        func updateViewMagnification(_ value: CGFloat) {
            guard let scrollView, let textView else { return }
            if textView.hasMarkedText() || tableCellEditor?.hasMarkedText() == true {
                pendingMagnification = value
                return
            }
            pendingMagnification = nil
            guard abs(scrollView.magnification - value) > 0.0001 else { return }
            applyingMagnification = true
            let bounds = scrollView.contentView.bounds
            scrollView.setMagnification(value, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
            lastObservedMagnification = scrollView.magnification
            applyingMagnification = false
            updateLayout(wordWrap: wordWrap, force: true)
        }

        private func finishPendingMagnification() {
            if let value = pendingMagnification { updateViewMagnification(value) }
        }

        func updateEditorLigatures(_ value: Int?) {
            guard let textView, !textView.hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return }
            editorLigatures = value
            foldLayoutManager?.markdownLigatures = value
            if value != nil { hasAppliedLigatures = true }
            applyVisibleLigatures()
            if let child = tableCellEditor {
                applyLigatures(to: child, range: NSRange(location: 0, length: (child.string as NSString).length), value: value)
            }
        }

        private func applyLigatures(to view: NSTextView, range: NSRange, value: Int?) {
            guard !view.hasMarkedText(), let storage = view.textStorage else { return }
            var typing = view.typingAttributes
            if let value { typing[.ligature] = value } else { typing.removeValue(forKey: .ligature) }
            view.typingAttributes = typing
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            var changes: [NSRange] = []
            storage.enumerateAttribute(.ligature, in: range) { existing, part, _ in
                if (existing as? NSNumber)?.intValue != value { changes.append(part) }
            }
            for part in changes {
                if let value { storage.addAttribute(.ligature, value: value, range: part) }
                else { storage.removeAttribute(.ligature, range: part) }
            }
        }

        private func applyVisibleLigatures() {
            guard hasAppliedLigatures, let textView, !textView.hasMarkedText(), tableCellEditor?.hasMarkedText() != true,
                  let layout = textView.layoutManager, let container = textView.textContainer else { return }
            let rect = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
            let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            applyLigatures(to: textView, range: range, value: editorLigatures)
        }

        func updateTableCellFont(_ font: NSFont) {
            guard let child = tableCellEditor, !child.hasMarkedText() else { return }
            child.font = font
        }

        private var previewSyncScheduled = false
        private var lastSentPreviewPosition: MarkdownPreviewScrollRelay.Position?

        private func schedulePreviewScrollSync() {
            let relay = document.previewScrollRelay
            guard relay.isListening, currentLanguage == .markdown, !previewSyncScheduled else { return }
            previewSyncScheduled = true
            // Склеиваем серию событий прокрутки в одно сообщение предпросмотру.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                previewSyncScheduled = false
                guard isActive, let position = currentPreviewPosition(), position != lastSentPreviewPosition else { return }
                lastSentPreviewPosition = position
                relay.positionHandler?(position)
            }
        }

        /// Верхняя видимая логическая строка. Берёт только раскладку видимой области,
        /// как applyVisibleLigatures; ensureLayout не вызывается.
        private func currentPreviewPosition() -> MarkdownPreviewScrollRelay.Position? {
            guard isActive, currentLanguage == .markdown, !markdownVerticalWriting, let textView,
                  let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let storage = textView.textStorage else { return nil }
            let visible = textView.visibleRect
            if visible.minY <= 0.5 { return .init(line: 1, atBottom: false) }
            let atBottom = visible.maxY >= textView.bounds.maxY - 1
            let rect = visible.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
            let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            return .init(line: lineIndex.lineNumber(at: min(characters.location, storage.length)), atBottom: atBottom)
        }

        func attachLiveTextProvider() {
            document.previewScrollRelay.positionProvider = { [weak self] in self?.currentPreviewPosition() }
            document.attachLiveTextProvider(
                id: liveTextProviderID,
                provider: { [weak self] in
                    guard let self else { return nil }
                    if self.tableCellEditor?.hasMarkedText() == true { return self.tableCellSource() }
                    guard let text = self.textView?.string else { return nil }
                    return self.markdownImageProjectionEnabled
                        ? self.markdownImageProjection.restore(text)
                        : text
                },
                acknowledgement: { [weak self] revision in
                    self?.lastSynchronizedRevision = revision
                }
            )
        }

        func displayedText(for source: String) -> String {
            guard document.language == .markdown, document.isMarkdownFormatted else {
                markdownImageProjectionEnabled = false
                markdownImageProjection = MarkdownDataImageProjection()
                return source
            }
            markdownImageProjectionEnabled = true
            return markdownImageProjection.project(source)
        }

        func displayedRange(for sourceRange: NSRange, in display: String) -> NSRange {
            guard markdownImageProjectionEnabled else { return sourceRange }
            return markdownImageProjection.displayRange(for: sourceRange, in: display)
        }

        private func synchronizeMarkdownImageProjection() {
            guard let textView, !textView.hasMarkedText() else { return }
            let shouldProject = document.language == .markdown && document.isMarkdownFormatted
            guard shouldProject != markdownImageProjectionEnabled else { return }
            let oldDisplay = textView.string
            let source = markdownImageProjectionEnabled ? markdownImageProjection.restore(oldDisplay) : oldDisplay
            let sourceSelection = markdownImageProjectionEnabled
                ? markdownImageProjection.sourceRange(for: textView.selectedRange(), in: oldDisplay)
                : textView.selectedRange()
            let next = shouldProject ? displayedText(for: source) : source
            if !shouldProject {
                markdownImageProjectionEnabled = false
                markdownImageProjection = MarkdownDataImageProjection()
            }
            isApplyingExternalUpdate = true
            textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: (oldDisplay as NSString).length), with: next)
            let selection = shouldProject
                ? markdownImageProjection.displayRange(for: sourceSelection, in: next)
                : sourceSelection
            textView.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: (next as NSString).length)))
            resetLineIndex(with: next)
            isApplyingExternalUpdate = false
            markdownPresentation?.projectionChanged(revision: contentRevision)
        }

        private func apply(
            _ request: EditorTextUpdateRequest,
            to textView: LacTextView
        ) {
            let fullRange = NSRange(
                location: 0,
                length: textView.textStorage?.length ?? 0
            )
            isApplyingAutomatedEdit = true
            defer { isApplyingAutomatedEdit = false }
            guard textView.shouldChangeText(
                in: fullRange,
                replacementString: request.text
            ) else { return }

            request.wasHandled = true
            textView.textStorage?.replaceCharacters(
                in: fullRange,
                with: request.text
            )
            textView.didChangeText()
            textView.setSelectedRange(request.selectionRange)
            textView.scrollRangeToVisible(request.selectionRange)
            textView.undoManager?.setActionName(request.actionName)
        }

        private func performCodeBlockCommand(changeLanguage: Bool) {
            clipboardCopyTask?.cancel()
            clipboardCopyID = UUID()
            guard isActive, currentLanguage == .markdown, document.language == .markdown,
                  document.ioState == .idle, let view = textView, !view.hasMarkedText(),
                  tableCellEditor == nil, view.selectedRanges.count == 1,
                  (!changeLanguage || view.isEditable), let storage = view.textStorage else { return }
            let selection = view.selectedRange(), revision = contentRevision, documentRevision = document.textRevision
            let text = storage.string, documentID = document.id, commandID = clipboardCopyID
            let board = NSPasteboard.general, changeCount = board.changeCount
            guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
                  selection.location <= storage.length, selection.length <= storage.length - selection.location else { return }
            clipboardCopyTask = Task.detached(priority: .userInitiated) { [weak self] in
                let blocks = MarkdownPresentationParser.parse(text, isCancelled: { Task.isCancelled }).codeBlocks.filter {
                    selection.length == 0 ? selection.location >= $0.range.location &&
                        (selection.location < NSMaxRange($0.range) || (!$0.isClosed && selection.location == NSMaxRange($0.range) && selection.location == (text as NSString).length))
                        : selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range)
                }
                guard !Task.isCancelled, blocks.count == 1, let block = blocks.first else { return }
                await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self, let view = self.textView, let storage = view.textStorage else { return }
                    @MainActor func current() -> Bool {
                        !Task.isCancelled && self.isActive && self.document.id == documentID && self.document.language == .markdown &&
                        self.document.ioState == .idle && self.contentRevision == revision &&
                        self.document.textRevision == documentRevision && self.clipboardCopyID == commandID &&
                        self.tableCellEditor == nil && !view.hasMarkedText() && view.selectedRanges.count == 1 &&
                        view.selectedRange() == selection && (!changeLanguage || view.isEditable)
                    }
                    guard current(), block.infoRange.location >= 0, block.infoRange.length >= 0,
                          block.infoRange.location <= storage.length,
                          block.infoRange.length <= storage.length - block.infoRange.location else { return }
                    if !changeLanguage {
                        guard board.changeCount == changeCount else { return }
                        board.clearContents()
                        board.setString(block.literal, forType: .string)
                        return
                    }
                    let original = storage.mutableString.substring(with: block.infoRange)
                    let alert = NSAlert()
                    alert.messageText = L10n.tr("设置代码块语言")
                    alert.addButton(withTitle: L10n.tr("确定"))
                    alert.addButton(withTitle: L10n.tr("取消"))
                    let input = NSTextField(string: block.info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "")
                    input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
                    alert.accessoryView = input
                    guard alert.runModal() == .alertFirstButtonReturn, current() else { return }
                    let language = input.stringValue
                    guard !language.contains(where: { $0.isWhitespace || $0 == "`" }) else { return }
                    let old = original as NSString
                    var start = 0, end = 0
                    while start < old.length && (old.character(at: start) == 32 || old.character(at: start) == 9) { start += 1 }
                    end = start
                    while end < old.length && old.character(at: end) != 32 && old.character(at: end) != 9 { end += 1 }
                    let replacement = old.substring(to: start) + language + old.substring(from: end)
                    guard replacement != original else { return }
                    view.breakUndoCoalescing()
                    let undo = view.undoManager
                    undo?.beginUndoGrouping()
                    defer { undo?.endUndoGrouping(); view.breakUndoCoalescing() }
                    self.isApplyingAutomatedEdit = true
                    defer { self.isApplyingAutomatedEdit = false }
                    guard view.shouldChangeText(in: block.infoRange, replacementString: replacement) else { return }
                    storage.replaceCharacters(in: block.infoRange, with: replacement)
                    view.didChangeText()
                    let delta = (replacement as NSString).length - block.infoRange.length
                    func translated(_ offset: Int) -> Int {
                        if offset <= block.infoRange.location { return offset }
                        if offset >= NSMaxRange(block.infoRange) { return offset + delta }
                        return block.infoRange.location + min(offset - block.infoRange.location, (replacement as NSString).length)
                    }
                    let selectionStart = translated(selection.location), selectionEnd = translated(NSMaxRange(selection))
                    view.setSelectedRange(NSRange(location: selectionStart, length: selectionEnd - selectionStart))
                    undo?.setActionName(L10n.tr("设置代码块语言"))
                }
            }
        }

        private func copyRichText(_ board: NSPasteboard, child: MarkdownTableCellEditor?, mode: ClipboardCopyMode = .rich) -> Bool {
            clipboardCopyTask?.cancel()
            clipboardCopyTask = nil
            clipboardCopyID = UUID()
            guard isActive, currentLanguage == .markdown, document.language == .markdown,
                  (mode != .rich || document.isMarkdownFormatted), document.ioState == .idle, let view = textView,
                  !view.hasMarkedText(), (child != nil || tableCellEditor == nil),
                  child == nil || (child === tableCellEditor && child?.hasMarkedText() == false) else { return false }
            guard (child?.selectedRanges.count ?? view.selectedRanges.count) == 1 else {
                document.statusMessage = L10n.tr("无法复制格式化内容")
                return true
            }
            let selected = child?.selectedRange() ?? view.selectedRange()
            guard selected.location != NSNotFound, selected.length > 0, let storage = view.textStorage else { return false }
            let sourceSelection: NSRange
            if let child {
                guard let range = tableCellRange, tableCellRevision == contentRevision,
                      range.location <= storage.length, range.length <= storage.length - range.location,
                      storage.mutableString.substring(with: range) == tableCellOriginal else { return true }
                let projection = MarkdownTableCellEditor.projection(tableCellOriginal)
                guard child.string == projection.text, selected.location < projection.rawBoundaries.count,
                      selected.length <= projection.rawBoundaries.count - 1 - selected.location else { return true }
                let start = projection.rawBoundaries[selected.location], end = projection.rawBoundaries[NSMaxRange(selected)]
                sourceSelection = NSRange(location: range.location + start, length: end - start)
            } else { sourceSelection = selected }
            guard sourceSelection.location <= storage.length, sourceSelection.length <= storage.length - sourceSelection.location else { return true }
            let markdown = storage.string, revision = contentRevision, documentRevision = document.textRevision, documentURL = document.url
            let wasFormatted = document.isMarkdownFormatted
            let contextID = tableCellContextID, copyID = clipboardCopyID, changeCount = board.changeCount
            let wasChild = child != nil
            let syntax = aiPreferences?.markdownSyntax ?? .init()
            let detailsOpenOverrides = markdownPresentation?.detailsOpenOverrides ?? [:]
            let copyMathPhysics = mathOptions.physics
            let copyMathNumbering = mathOptions.numbering
            let copyMathWidth = max(1, view.enclosingScrollView?.contentView.bounds.width ?? view.bounds.width)
            let copyMathFontSize = view.font?.pointSize ?? 16
            let copyMathDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let project = clipboardCopyProject
            let session = clipboardCopySession
            clipboardCopyTask = Task.detached(priority: .userInitiated) { [weak self, weak child, weak document] in
                var fragment = mode == .markdown
                    ? MarkdownClipboardCopyService.Fragment(text: (markdown as NSString).substring(with: sourceSelection), html: "", runs: [])
                    : project(markdown, sourceSelection, documentURL, true, syntax, detailsOpenOverrides)
                if mode == .rich, let projected = fragment, !projected.remoteImages.isEmpty {
                    fragment = try? await MarkdownClipboardCopyService.resolveRemoteImages(projected, session: session)
                }
                if let projected = fragment, !projected.mathImages.isEmpty {
                    fragment = try? await MarkdownClipboardCopyService.resolveMath(projected, width: copyMathWidth, fontSize: copyMathFontSize,
                        dark: copyMathDark, physics: copyMathPhysics, numbering: copyMathNumbering)
                }
                guard !Task.isCancelled else { return }
                let hasStructure = mode == .rich && (fragment?.html.contains("<table>") == true ||
                    fragment?.html.contains("<ul>") == true || fragment?.html.contains("<ol ") == true ||
                    fragment?.html.contains("<blockquote>") == true || fragment?.html.contains("<hr>") == true ||
                    fragment?.html.contains("<img src=\"") == true ||
                    (1...6).contains { fragment?.html.contains("<h\($0)>") == true })
                let structuralRTF: Data?
                if hasStructure, let fragment { structuralRTF = await MarkdownClipboardCopyService.structuralRTF(fragment) }
                else { structuralRTF = nil }
                guard !Task.isCancelled else { return }
                let capturedSelf = self, capturedDocument = document, capturedChild = child, capturedFragment = fragment
                await MainActor.run { [weak self = capturedSelf, weak document = capturedDocument, weak child = capturedChild, fragment = capturedFragment] in
                    guard !Task.isCancelled, let self, let document, self.document === document,
                          self.clipboardCopyID == copyID, self.isActive, self.contentRevision == revision,
                          document.textRevision == documentRevision, document.url == documentURL, document.language == .markdown, self.currentLanguage == .markdown,
                          document.isMarkdownFormatted == wasFormatted, document.ioState == .idle, board.changeCount == changeCount,
                          (mode == .markdown || (self.markdownPresentation?.detailsOpenOverrides ?? [:]) == detailsOpenOverrides),
                          (self.aiPreferences?.markdownSyntax ?? .init()) == syntax,
                          self.mathOptions.physics == copyMathPhysics, self.mathOptions.numbering == copyMathNumbering,
                          let view = self.textView, !view.hasMarkedText() else { return }
                    if wasChild {
                        guard let child, child === self.tableCellEditor, self.tableCellContextID == contextID,
                              !child.hasMarkedText(), child.selectedRanges.count == 1, child.selectedRange() == selected else { return }
                    } else {
                        guard self.tableCellEditor == nil, view.selectedRanges.count == 1, view.selectedRange() == selected else { return }
                    }
                    self.clipboardCopyTask = nil
                    guard let fragment else { document.statusMessage = L10n.tr("无法复制格式化内容"); return }
                    let item = NSPasteboardItem()
                    var copiedWithoutRTF = false
                    let plain = mode == .html ? fragment.html : fragment.text
                    guard item.setString(plain, forType: .string) else {
                        document.statusMessage = L10n.tr("无法复制格式化内容"); return
                    }
                    if mode == .rich {
                        let attributed = NSMutableAttributedString(string: fragment.text)
                        for run in fragment.runs {
                            let size = CGFloat(run.inlineStyle?.fontSize ?? Double(NSFont.systemFontSize))
                            var font = run.code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
                            if run.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                            if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                            attributed.addAttribute(.font, value: font, range: run.range)
                            if run.strike { attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run.range) }
                            if run.underline { attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run.range) }
                            if run.highlight { attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: run.range) }
                            if let color = run.inlineStyle?.foreground { attributed.addAttribute(.foregroundColor, value: color.nsColor, range: run.range) }
                            if let color = run.inlineStyle?.background { attributed.addAttribute(.backgroundColor, value: color.nsColor, range: run.range) }
                            if run.script != 0 {
                                attributed.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * 0.75), range: run.range)
                                attributed.addAttribute(.baselineOffset, value: NSFont.systemFontSize * (run.script < 0 ? -0.2 : 0.3), range: run.range)
                            }
                            if let link = run.link, let url = URL(string: link) { attributed.addAttribute(.link, value: url, range: run.range) }
                        }
                        var rtf = fragment.hasUnverifiedHTMLBlocks ? nil : (hasStructure ? structuralRTF : try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
                        if let candidate = rtf, fragment.runs.contains(where: { $0.underline || $0.highlight || $0.script != 0 || $0.inlineStyle != nil }) {
                            let preservesStyles: Bool = {
                                guard !hasStructure,
                                      let restored = try? NSAttributedString(data: candidate, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
                                      restored.string == fragment.text else { return false }
                                for run in fragment.runs where run.underline || run.highlight || run.script != 0 || run.inlineStyle != nil {
                                    guard run.range.length > 0, NSMaxRange(run.range) <= restored.length else { return false }
                                    var intact = true
                                    if run.underline {
                                        restored.enumerateAttribute(.underlineStyle, in: run.range) { value, _, _ in
                                            if (value as? NSNumber)?.intValue != NSUnderlineStyle.single.rawValue { intact = false }
                                        }
                                    }
                                    if run.highlight {
                                        restored.enumerateAttribute(.backgroundColor, in: run.range) { value, _, _ in
                                            if value == nil { intact = false }
                                        }
                                    }
                                    if run.script != 0 {
                                        restored.enumerateAttribute(.baselineOffset, in: run.range) { value, _, _ in
                                            if (value as? NSNumber).map({ $0.doubleValue * Double(run.script) > 0 }) != true { intact = false }
                                        }
                                        restored.enumerateAttribute(.font, in: run.range) { value, _, _ in
                                            if (value as? NSFont).map({ $0.pointSize < CGFloat(run.inlineStyle?.fontSize ?? Double(NSFont.systemFontSize)) }) != true { intact = false }
                                        }
                                    }
                                    if let style = run.inlineStyle {
                                        restored.enumerateAttribute(.font, in: run.range) { value, _, _ in
                                            guard let font = value as? NSFont else { intact = false; return }
                                            let traits = NSFontManager.shared.traits(of: font)
                                            if run.bold && !traits.contains(.boldFontMask) { intact = false }
                                            if run.italic && !traits.contains(.italicFontMask) { intact = false }
                                            if run.code && !traits.contains(.fixedPitchFontMask) { intact = false }
                                        }
                                        if let link = run.link {
                                            restored.enumerateAttribute(.link, in: run.range) { value, _, _ in
                                                let actual = (value as? URL)?.absoluteString ?? (value as? String)
                                                if actual != link { intact = false }
                                            }
                                        }
                                        func checkColor(_ key: NSAttributedString.Key, _ expected: MarkdownSRGBColor) {
                                            restored.enumerateAttribute(key, in: run.range) { value, _, _ in
                                                guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { intact = false; return }
                                                let tolerance = 1.0 / 255.0 + 0.001
                                                if abs(Double(color.redComponent) - expected.red) > tolerance ||
                                                   abs(Double(color.greenComponent) - expected.green) > tolerance ||
                                                   abs(Double(color.blueComponent) - expected.blue) > tolerance ||
                                                   abs(Double(color.alphaComponent) - expected.alpha) > tolerance { intact = false }
                                            }
                                        }
                                        if let color = style.foreground { checkColor(.foregroundColor, color) }
                                        if let color = style.background { checkColor(.backgroundColor, color) }
                                        if let size = style.fontSize {
                                            let expected = size * (run.script == 0 ? 1 : 0.75)
                                            restored.enumerateAttribute(.font, in: run.range) { value, _, _ in
                                                if (value as? NSFont).map({ abs(Double($0.pointSize) - expected) < 0.1 }) != true { intact = false }
                                            }
                                        }
                                    }
                                    guard intact else { return false }
                                }
                                return true
                            }()
                            if !preservesStyles { rtf = nil }
                        }
                        guard item.setString(fragment.html, forType: .html) else {
                            document.statusMessage = L10n.tr("无法复制格式化内容"); return
                        }
                        if let rtf {
                            guard item.setData(rtf, forType: .rtf) else { document.statusMessage = L10n.tr("无法复制格式化内容"); return }
                        } else { copiedWithoutRTF = true }
                    }
                    var saved: [NSPasteboardItem] = []
                    for old in board.pasteboardItems ?? [] {
                        let copy = NSPasteboardItem()
                        for type in old.types {
                            guard let data = old.data(forType: type), copy.setData(data, forType: type) else {
                                document.statusMessage = L10n.tr("无法复制格式化内容"); return
                            }
                        }
                        saved.append(copy)
                    }
                    guard board.changeCount == changeCount else { return }
                    board.clearContents()
                    if !board.writeObjects([item]) {
                        board.clearContents()
                        _ = board.writeObjects(saved)
                        document.statusMessage = L10n.tr("无法复制格式化内容")
                    } else if copiedWithoutRTF {
                        document.statusMessage = L10n.tr("已复制纯文本和 HTML")
                    } else if document.statusMessage == L10n.tr("已复制纯文本和 HTML") {
                        document.statusMessage = nil
                    }
                }
            }
            return true
        }

        private func pasteClipboardSource(_ board: NSPasteboard) {
            clipboardPasteTask?.cancel()
            clipboardPasteTask = nil
            guard isActive, currentLanguage == .markdown, document.language == .markdown, document.ioState == .idle,
                  let view = textView, view.isEditable, !view.hasMarkedText(),
                  let text = board.string(forType: .string) else { return }
            if let child = tableCellEditor {
                guard child.isEditable, !child.hasMarkedText(), child.selectedRanges.count == 1 else { return }
                child.insertText(text, replacementRange: child.selectedRange())
                return
            }
            guard view.selectedRanges.count == 1 else { return }
            let previous = view.editSource
            view.editSource = .pasted
            defer { view.editSource = previous }
            view.breakUndoCoalescing()
            view.undoManager?.beginUndoGrouping()
            defer { view.undoManager?.endUndoGrouping(); view.breakUndoCoalescing() }
            view.insertText(text, replacementRange: view.selectedRange())
        }

        nonisolated private static func htmlImageSources(_ html: String, isCancelled: @escaping () -> Bool) -> [String]? {
            if isCancelled() { return nil }
            let characters = Array(html)
            let blockedTags: Set<String> = ["image", "svg", "picture", "object", "embed", "iframe", "video", "audio", "source", "link", "style", "script"]
            var index = 0, images: [String] = []
            while index < characters.count {
                if isCancelled() { return nil }
                guard characters[index] == "<", index + 1 < characters.count else { index += 1; continue }
                if index + 3 < characters.count, characters[index + 1] == "!", characters[index + 2] == "-", characters[index + 3] == "-" {
                    var end = index + 4
                    while end + 2 < characters.count && !(characters[end] == "-" && characters[end + 1] == "-" && characters[end + 2] == ">") {
                        if isCancelled() { return nil }
                        end += 1
                    }
                    guard end + 2 < characters.count else { return nil }
                    index = end + 3
                    continue
                }
                var cursor = index + 1
                let closing = characters[cursor] == "/"
                if closing { cursor += 1 }
                guard cursor < characters.count, characters[cursor].isLetter else { index += 1; continue }
                let start = cursor
                while cursor < characters.count && (characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "-") {
                    if isCancelled() { return nil }
                    cursor += 1
                }
                let tag = String(characters[start..<cursor]).lowercased()
                if blockedTags.contains(tag) || (tag == "img" && closing) { return nil }
                var imageSource = false
                var rawImageSource = ""
                while cursor < characters.count && characters[cursor] != ">" {
                    if isCancelled() { return nil }
                    if characters[cursor].isWhitespace || characters[cursor] == "/" { cursor += 1; continue }
                    let nameStart = cursor
                    while cursor < characters.count && !characters[cursor].isWhitespace && characters[cursor] != "=" && characters[cursor] != ">" && characters[cursor] != "/" {
                        if isCancelled() { return nil }
                        cursor += 1
                    }
                    guard cursor > nameStart else { return nil }
                    let name = String(characters[nameStart..<cursor]).lowercased()
                    while cursor < characters.count && characters[cursor].isWhitespace { if isCancelled() { return nil }; cursor += 1 }
                    guard cursor < characters.count else { return nil }
                    if characters[cursor] != "=" { continue }
                    cursor += 1
                    while cursor < characters.count && characters[cursor].isWhitespace { if isCancelled() { return nil }; cursor += 1 }
                    guard cursor < characters.count else { return nil }
                    let quote: Character? = characters[cursor] == "\"" || characters[cursor] == "'" ? characters[cursor] : nil
                    if quote != nil { cursor += 1 }
                    let valueStart = cursor
                    while cursor < characters.count && (quote.map { characters[cursor] != $0 } ?? (!characters[cursor].isWhitespace && characters[cursor] != ">")) {
                        if isCancelled() { return nil }
                        cursor += 1
                    }
                    if name == "src", tag == "img" {
                        guard !imageSource, cursor > valueStart else { return nil }
                        imageSource = true
                        rawImageSource = String(characters[valueStart..<cursor])
                    } else if ["src", "srcset", "background", "style"].contains(name) { return nil }
                    if quote != nil {
                        guard cursor < characters.count else { return nil }
                        cursor += 1
                    }
                }
                guard cursor < characters.count else { return nil }
                if tag == "img" {
                    guard imageSource else { return nil }
                    let value: String
                    if rawImageSource.contains("&") {
                        guard let image = try? MarkdownImageUploadService.images(in: String(characters[index...cursor]), isCancelled: isCancelled),
                              image.count == 1, let address = image.first?.address else { return nil }
                        value = address
                    } else { value = rawImageSource }
                    let embedded = value.hasPrefix("data:image/") && value.contains(";base64,")
                    let url = URL(string: value)
                    let remote = url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && $0.absoluteString == value } ?? false
                    let local = url.map { $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && $0.absoluteString == value } ?? false
                    guard embedded || remote || local else { return nil }
                    images.append(value)
                }
                index = cursor + 1
            }
            return images
        }

        private func pasteRichText(_ board: NSPasteboard, child: MarkdownTableCellEditor?) -> Bool {
            clipboardPasteTask?.cancel()
            clipboardPasteTask = nil
            clipboardPasteID = UUID()
            guard isActive, currentLanguage == .markdown, document.language == .markdown,
                  document.isMarkdownFormatted, document.ioState == .idle,
                  let view = textView, view.isEditable, !view.hasMarkedText(),
                  (child != nil || tableCellEditor == nil),
                  child == nil || (child === tableCellEditor && child?.isEditable == true && child?.hasMarkedText() == false) else { return false }
            let type: NSPasteboard.PasteboardType
            let format: ClipboardMarkdownConversionService.InputFormat
            if board.types?.contains(.html) == true { type = .html; format = .html }
            else if board.types?.contains(.rtf) == true { type = .rtf; format = .rtf }
            else { return false }
            guard board.pasteboardItems?.count == 1 else {
                document.statusMessage = L10n.tr("无法粘贴格式化内容")
                return true
            }
            guard (child?.selectedRanges.count ?? view.selectedRanges.count) == 1 else {
                document.statusMessage = L10n.tr("无法粘贴格式化内容")
                return true
            }
            guard let data = board.data(forType: type) else {
                document.statusMessage = L10n.tr("无法粘贴格式化内容")
                return true
            }
            // Refuse resources that cannot be confirmed and saved explicitly.
            let text = format == .html ? String(data: data, encoding: .utf8) : String(data: data, encoding: .isoLatin1)
            guard let text else { document.statusMessage = L10n.tr("无法粘贴格式化内容"); return true }
            guard format != .rtf || text.range(of: #"(?i)\\(?:object|objdata|bin)\b"#, options: .regularExpression) == nil else {
                document.statusMessage = L10n.tr("无法粘贴格式化内容")
                return true
            }
            let selection = child?.selectedRange() ?? view.selectedRange()
            let source: NSString? = child.map { $0.string as NSString } ?? view.textStorage?.mutableString
            guard let source, selection.location != NSNotFound, selection.location <= source.length,
                  selection.length <= source.length - selection.location else { return true }
            let original = source.substring(with: selection)
            let revision = contentRevision, documentID = document.id, contextID = tableCellContextID
            let documentRevision = document.textRevision
            let executable = clipboardConversionExecutable
            let pasteID = clipboardPasteID, wasChild = child != nil
            if format == .html || text.range(of: #"(?i)\\pict\b"#, options: .regularExpression) != nil {
                let documentURL = document.url
                let writeImage = clipboardImageWrite
                let current: @MainActor () -> Bool = { [weak self, weak document, weak child] in
                    guard let self, let document, self.document === document, self.clipboardPasteID == pasteID,
                          self.isActive, self.contentRevision == revision, document.textRevision == documentRevision,
                          document.url == documentURL, document.language == .markdown, self.currentLanguage == .markdown,
                          document.isMarkdownFormatted, document.ioState == .idle, let view = self.textView,
                          view.isEditable, !view.hasMarkedText() else { return false }
                    if wasChild {
                        guard let child, child === self.tableCellEditor, self.tableCellContextID == contextID,
                              child.isEditable, !child.hasMarkedText(), child.selectedRanges.count == 1,
                              child.selectedRange() == selection, selection.location <= (child.string as NSString).length,
                              selection.length <= (child.string as NSString).length - selection.location else { return false }
                        return (child.string as NSString).substring(with: selection) == original
                    }
                    guard self.tableCellEditor == nil, view.selectedRanges.count == 1, view.selectedRange() == selection,
                          let storage = view.textStorage, selection.location <= storage.length,
                          selection.length <= storage.length - selection.location else { return false }
                    return storage.mutableString.substring(with: selection) == original
                }
                clipboardPasteTask = Task.detached(priority: .userInitiated) { [weak self, weak document, weak child] in
                    let capturedSelf = self, capturedDocument = document, capturedChild = child
                    guard let htmlImages = format == .html ? Self.htmlImageSources(text, isCancelled: { Task.isCancelled }) : [], !Task.isCancelled else {
                        await MainActor.run { [capturedDocument] in if !Task.isCancelled, current() { capturedDocument?.statusMessage = L10n.tr("无法粘贴格式化内容") } }
                        return
                    }
                    let converted = Result {
                        if format == .rtf { return try ClipboardMarkdownConversionService.convertRTFWithMedia(data, executable: executable, isCancelled: { Task.isCancelled }) }
                        return try ClipboardMarkdownConversionService.convert(data, format: .html, executable: executable, isCancelled: { Task.isCancelled })
                    }
                    guard !Task.isCancelled else { return }
                    guard case let .success(output) = converted,
                          let parsedImages = try? MarkdownImageUploadService.images(in: output.markdown, isCancelled: { Task.isCancelled }),
                          format != .html || parsedImages.map(\.address) == htmlImages,
                          format != .rtf || ClipboardMarkdownConversionService.rtfPictureCount(data, isCancelled: { Task.isCancelled }) == parsedImages.count,
                          let images = try? MarkdownClipboardCopyService.embeddedImages(in: output.markdown, allowingExternal: format == .html, isCancelled: { Task.isCancelled }) else {
                        await MainActor.run { [capturedDocument] in if !Task.isCancelled, current() { capturedDocument?.statusMessage = L10n.tr("无法粘贴格式化内容") } }
                        return
                    }
                    var destinations: [URL] = []
                    func reportSaved() async {
                        guard !destinations.isEmpty else { return }
                        let paths = destinations.map(\.path).joined(separator: "\n")
                        let notice = ClipboardSavedImagesNotice(documentID: documentID, message: L10n.tr("图片位于 %@，未插入", paths))
                        await MainActor.run { [capturedDocument] in
                            NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
                            if !notice.handled, let document = capturedDocument {
                                if let existing = document.statusMessage, !existing.isEmpty {
                                    if !existing.contains(notice.message) { document.statusMessage = existing + "\n" + notice.message }
                                } else { document.statusMessage = notice.message }
                            }
                        }
                    }
                    for image in images {
                        let destination: URL? = await MainActor.run {
                            guard !Task.isCancelled, current() else { return nil }
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = image.filename
                            if let type = UTType(mimeType: image.mime) { panel.allowedContentTypes = [type] }
                            guard panel.runModal() == .OK, current(), !Task.isCancelled else { return nil }
                            return panel.url
                        }
                        guard let destination else { await reportSaved(); return }
                        do { try writeImage(image.data, destination) }
                        catch {
                            await reportSaved()
                            let noDestinations = destinations.isEmpty
                            await MainActor.run { [capturedDocument] in if noDestinations, current() { capturedDocument?.statusMessage = L10n.tr("无法保存图片，文件可能已存在") } }
                            return
                        }
                        destinations.append(destination)
                        guard !Task.isCancelled, await MainActor.run(body: { current() }) else { await reportSaved(); return }
                    }
                    let addresses = destinations.compactMap { MarkdownImageEditingService.address(for: $0, document: documentURL).flatMap(URL.init(string:)) }
                    guard addresses.count == destinations.count else { await reportSaved(); return }
                    let convertedMarkdown: String
                    if images.isEmpty { convertedMarkdown = output.markdown }
                    else if let result = try? MarkdownClipboardCopyService.replacingEmbeddedImages(in: output.markdown, images: images, addresses: addresses) { convertedMarkdown = result }
                    else {
                        await reportSaved(); return
                    }
                    let markdown = convertedMarkdown.hasSuffix("\n") ? String(convertedMarkdown.dropLast()) : convertedMarkdown
                    let applied = await MainActor.run { [capturedSelf, capturedChild] () -> Bool in
                        guard !Task.isCancelled, current(), let self = capturedSelf, let view = self.textView else { return false }
                        self.clipboardPasteTask = nil
                        if wasChild, let child = capturedChild {
                            child.insertText(markdown, replacementRange: selection)
                            return self.contentRevision != revision
                        }
                        else {
                            let request = EditorRangeReplacementRequest(documentID: documentID, range: selection, originalText: original,
                                replacementText: markdown, expectedEditorRevision: revision, actionName: L10n.tr("粘贴文本"))
                            request.groupsUndo = true
                            self.apply(request, to: view)
                            return request.wasHandled
                        }
                    }
                    if !applied { await reportSaved() }
                }
                return true
            }
            clipboardPasteTask = Task.detached(priority: .userInitiated) { [weak self, weak child, weak document] in
                let result = Result { try ClipboardMarkdownConversionService.convert(data, format: format, executable: executable, isCancelled: { Task.isCancelled }) }
                guard !Task.isCancelled else { return }
                let capturedSelf = self, capturedDocument = document, capturedChild = child
                await MainActor.run { [weak self = capturedSelf, weak document = capturedDocument, weak child = capturedChild] in
                    guard !Task.isCancelled, let self, let document, self.document === document,
                          document.textRevision == documentRevision, self.clipboardPasteID == pasteID, self.isActive, self.document.id == documentID,
                          self.document.language == .markdown, self.currentLanguage == .markdown,
                          self.document.isMarkdownFormatted, self.document.ioState == .idle,
                          self.contentRevision == revision, let view = self.textView, view.isEditable,
                          !view.hasMarkedText() else { return }
                    if wasChild {
                        guard let child else { return }
                        guard child === self.tableCellEditor, self.tableCellContextID == contextID,
                              child.isEditable, !child.hasMarkedText(), child.selectedRanges.count == 1, child.selectedRange() == selection,
                              (child.string as NSString).substring(with: selection) == original else { return }
                    } else {
                        guard self.tableCellEditor == nil, view.selectedRanges.count == 1, view.selectedRange() == selection,
                              let storage = view.textStorage, selection.location <= storage.length,
                              selection.length <= storage.length - selection.location,
                              storage.mutableString.substring(with: selection) == original else { return }
                    }
                    self.clipboardPasteTask = nil
                    switch result {
                    case let .success(output):
                        let markdown = output.markdown.hasSuffix("\n") ? String(output.markdown.dropLast()) : output.markdown
                        if wasChild, let child { child.insertText(markdown, replacementRange: selection) }
                        else {
                            let request = EditorRangeReplacementRequest(documentID: documentID, range: selection,
                                originalText: original, replacementText: markdown,
                                expectedEditorRevision: revision, actionName: L10n.tr("粘贴文本"))
                            request.groupsUndo = true
                            self.apply(request, to: view)
                        }
                    case .failure:
                        self.document.statusMessage = L10n.tr("无法粘贴格式化内容")
                    }
                }
            }
            return true
        }

        private func virtualTableTarget() -> EditorVirtualTableTarget? {
            guard let child = tableCellEditor, !child.hasMarkedText(), child.string.isEmpty,
                  child.selectedRange() == NSRange(location: 0, length: 0), tableCellVirtualSeparators > 0,
                  let range = tableCellRange, range.length == 0, let rowStart = tableCellRowStart,
                  tableCellRevision == contentRevision, let storage = textView?.textStorage,
                  range.location <= storage.length else { return nil }
            return EditorVirtualTableTarget(contextID: tableCellContextID, rowStart: rowStart,
                                            column: tableCellColumn, separators: tableCellVirtualSeparators, range: range)
        }

        private func extractSelection(for request: EditorTextExtractionRequest) {
            if request.allowsInsertionPoint, let target = virtualTableTarget(), isActive,
               let textView, !textView.hasMarkedText(), (!request.requiresEditable || textView.isEditable) {
                var result = EditorTextSelectionSnapshot(documentID: document.id, range: target.range, text: "",
                    editorRevision: contentRevision, wasExplicitSelection: false)
                result.virtualTableTarget = target
                request.result = result
                return
            }
            guard isActive, let textView, !textView.hasMarkedText(), (!request.requiresEditable || textView.isEditable),
                  moveTableSelectionToParent(),
                  let text = textView.textStorage?.mutableString else { return }
            if request.allowsInsertionPoint && textView.selectedRange().length == 0 {
                request.result = EditorTextSelectionSnapshot(documentID: document.id,
                    range: textView.selectedRange(), text: "", editorRevision: contentRevision,
                    wasExplicitSelection: false)
                return
            }
            if request.allowsWholeDocument && textView.selectedRange().length == 0 {
                request.result = EditorTextSelectionSnapshot(documentID: document.id,
                    range: NSRange(location: 0, length: text.length), text: text as String,
                    editorRevision: contentRevision, wasExplicitSelection: false)
                return
            }
            guard let candidate = TextCodecService.candidate(
                      in: text,
                      selection: textView.selectedRange(),
                      allowsTokenAtCaret: request.allowsTokenAtCaret,
                      maximumLength: request.allowsTokenAtCaret
                          ? TextCodecService.automaticDetectionLimit
                          : nil
                  ) else { return }
            request.result = EditorTextSelectionSnapshot(
                documentID: document.id,
                range: candidate.range,
                text: candidate.text,
                editorRevision: contentRevision,
                wasExplicitSelection: textView.selectedRange().length > 0
            )
        }

        private func apply(
            _ request: EditorRangeReplacementRequest,
            to textView: LacTextView
        ) {
            if let target = request.virtualTableTarget {
                guard isActive, textView.isEditable, !textView.hasMarkedText(),
                      target == virtualTableTarget(), request.expectedEditorRevision == contentRevision,
                      request.range == target.range, request.originalText.isEmpty,
                      !request.replacementText.isEmpty,
                      moveTableSelectionToParent(allowVirtual: true) else { return }
                let forwarded = EditorRangeReplacementRequest(documentID: request.documentID, range: request.range,
                    originalText: request.originalText, replacementText: request.replacementText,
                    expectedEditorRevision: request.expectedEditorRevision, actionName: request.actionName)
                forwarded.groupsUndo = request.groupsUndo
                forwarded.suppressUndoRegistration = request.suppressUndoRegistration
                forwarded.registerImageFileUndo = request.registerImageFileUndo
                forwarded.isAIGenerated = request.isAIGenerated
                forwarded.resultingSelection = request.resultingSelection
                apply(forwarded, to: textView)
                request.wasHandled = forwarded.wasHandled
                request.failureMessage = forwarded.failureMessage
                return
            }
            guard isActive, textView.isEditable, !textView.hasMarkedText(), moveTableSelectionToParent() else {
                request.failureMessage = L10n.tr("当前文本无法修改")
                return
            }
            guard request.expectedEditorRevision == contentRevision else {
                request.failureMessage = L10n.tr("编辑内容已变化，请重新执行转换")
                return
            }
            guard let storage = textView.textStorage,
                  request.range.location != NSNotFound,
                  NSMaxRange(request.range) <= storage.length,
                  (request.suppressUndoRegistration
                    ? storage.mutableString.substring(with: request.range).utf16.elementsEqual(request.originalText.utf16)
                    : storage.mutableString.substring(with: request.range) == request.originalText) else {
                request.failureMessage = L10n.tr("原文位置已变化，请重新执行转换")
                return
            }
            guard request.originalText != request.replacementText else {
                request.failureMessage = L10n.tr("转换结果与原文相同")
                return
            }
            guard request.registerImageFileUndo == nil || textView.undoManager?.isUndoRegistrationEnabled == true else {
                request.failureMessage = L10n.tr("当前文本无法修改")
                return
            }

            if request.groupsUndo { textView.breakUndoCoalescing(); textView.undoManager?.beginUndoGrouping() }
            if request.suppressUndoRegistration { textView.undoManager?.disableUndoRegistration() }
            defer {
                if request.suppressUndoRegistration { textView.undoManager?.enableUndoRegistration() }
                if request.groupsUndo { textView.undoManager?.endUndoGrouping(); textView.breakUndoCoalescing() }
            }
            isApplyingAutomatedEdit = true
            isApplyingAIGenerated = request.isAIGenerated
            defer { isApplyingAutomatedEdit = false; isApplyingAIGenerated = false }
            guard textView.shouldChangeText(
                in: request.range,
                replacementString: request.replacementText
            ) else {
                request.failureMessage = L10n.tr("当前文本无法修改")
                return
            }
            request.wasHandled = true
            storage.replaceCharacters(
                in: request.range,
                with: request.replacementText
            )
            textView.didChangeText()
            let replacementRange = NSRange(
                location: request.range.location,
                length: (request.replacementText as NSString).length
            )
            let selected = request.resultingSelection ?? replacementRange
            textView.setSelectedRange(selected)
            textView.scrollRangeToVisible(selected)
            if request.suppressUndoRegistration, let manager = textView.undoManager, let register = request.registerImageFileUndo {
                manager.enableUndoRegistration()
                register(manager, textView)
                manager.disableUndoRegistration()
            }
            textView.undoManager?.setActionName(request.actionName)
        }

        func updateMarkdownVerticalWriting(_ vertical: Bool) {
            guard markdownVerticalWriting != vertical, let view = textView, let scroll = scrollView,
                  let layout = view.layoutManager, let container = view.textContainer,
                  !view.hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return }
            let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
            let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let anchor = min(characters.location, view.textStorage?.length ?? 0)
            let expectedDocument = document.id, expectedRevision = contentRevision
            markdownVerticalWriting = vertical
            view.setLayoutOrientation(vertical ? .vertical : .horizontal)
            updateTableCellVerticalGlyphForm()
            let newRuler = LineNumberRulerView(scrollView: scroll, textView: view,
                                               orientation: vertical ? .horizontalRuler : .verticalRuler)
            newRuler.lineNumberProvider = { [weak self] location in self?.lineNumber(at: location) ?? 1 }
            if vertical { scroll.horizontalRulerView = newRuler } else { scroll.verticalRulerView = newRuler }
            ruler = newRuler
            _ = newRuler.updateThickness(lineCount: lineNumber(at: view.textStorage?.length ?? 0))
            scroll.hasHorizontalRuler = vertical && (lineNumbersVisible == true)
            scroll.hasVerticalRuler = !vertical && (lineNumbersVisible == true)
            scroll.rulersVisible = lineNumbersVisible == true
            lastLayoutWidth = -1
            lastRulerWidth = -1
            updateLayout(wordWrap: wordWrap, force: true)
            applyWritingModes()
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, self.document.id == expectedDocument,
                      self.contentRevision == expectedRevision, self.markdownVerticalWriting == vertical,
                      anchor <= (view.textStorage?.length ?? 0) else { return }
                view.scrollRangeToVisible(NSRange(location: anchor, length: 0))
            }
        }

        func updateLayout(wordWrap: Bool, force: Bool = false) {
            if !force, scrollView?.window?.inLiveResize == true {
                scheduleResizeLayout(wordWrap: wordWrap)
                return
            }
            applyLayout(wordWrap: wordWrap, force: force, duringLiveResize: false)
        }

        private func applyLayout(
            wordWrap: Bool,
            force: Bool,
            duringLiveResize: Bool
        ) {
            guard isActive || force else {
                self.wordWrap = wordWrap
                return
            }
            guard let scrollView, let textView, let textContainer = textView.textContainer else { return }
            let scale = scrollView.magnification
            let contentSize = scrollView.contentView.bounds.size
            if markdownVerticalWriting {
                let availableHeight = max(1, contentSize.height)
                let rulerHeight = scrollView.rulersVisible ? (scrollView.horizontalRulerView?.ruleThickness ?? 0) / scale : 0
                guard force || self.wordWrap != wordWrap || abs(lastLayoutWidth - availableHeight) > 0.5 || abs(lastRulerWidth - rulerHeight) > 0.5 else { return }
                self.wordWrap = wordWrap
                lastLayoutWidth = availableHeight
                lastRulerWidth = rulerHeight
                let documentHeight = max(1, availableHeight - rulerHeight)
                let textWidth = wordWrap ? min(documentHeight, maximumTextWidth ?? documentHeight) : documentHeight
                textView.textContainerInset.width = max(0, (documentHeight - textWidth) / 2)
                textContainer.heightTracksTextView = false
                textContainer.widthTracksTextView = false
                textContainer.containerSize = NSSize(width: wordWrap ? max(1, textWidth) : CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = true
                textView.isVerticallyResizable = !wordWrap
                textView.autoresizingMask = wordWrap ? [.height] : []
                textView.minSize = NSSize(width: contentSize.width, height: 0)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                          height: wordWrap ? documentHeight : CGFloat.greatestFiniteMagnitude)
                textView.frame.origin.y = rulerHeight
                if wordWrap { textView.frame.size.height = documentHeight }
                else if textView.frame.height < documentHeight { textView.frame.size.height = documentHeight }
                scrollView.hasHorizontalScroller = true
                scrollView.hasVerticalScroller = !wordWrap
                scrollView.horizontalScrollElasticity = .automatic
                textView.needsDisplay = true
                ruler?.requestRedraw()
                if !duringLiveResize { ensureVisibleLayout() }
                markdownPresentation?.viewportChanged()
                updateTableCellFrame()
                return
            }
            let availableWidth = max(1, contentSize.width)
            let rulerWidth = scrollView.rulersVisible
                ? (scrollView.verticalRulerView?.ruleThickness ?? 0) / scale
                : 0
            guard force
                    || self.wordWrap != wordWrap
                    || abs(lastLayoutWidth - availableWidth) > 0.5
                    || abs(lastRulerWidth - rulerWidth) > 0.5
            else {
                return
            }
            self.wordWrap = wordWrap
            lastLayoutWidth = availableWidth
            lastRulerWidth = rulerWidth
            let documentWidth = max(1, availableWidth - rulerWidth)
            let minimumInset = EditorTextView.minimumHorizontalInset
            let paddedWidth = max(1, documentWidth - 2 * minimumInset)
            let textWidth = wordWrap ? min(paddedWidth, maximumTextWidth ?? paddedWidth) : documentWidth
            textView.textContainerInset.width = wordWrap ? max(minimumInset, (documentWidth - textWidth) / 2) : minimumInset
            let usableTextWidth = max(1, textWidth)

            // The text container is managed explicitly so its line fragments
            // stop before the preview divider, including both horizontal insets.
            textContainer.widthTracksTextView = false
            textContainer.heightTracksTextView = false
            textContainer.containerSize = NSSize(
                width: wordWrap ? usableTextWidth : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = !wordWrap
            textView.isVerticallyResizable = true
            textView.autoresizingMask = wordWrap ? [.width] : []
            textView.minSize = NSSize(width: 0, height: contentSize.height)
            textView.maxSize = NSSize(
                width: wordWrap ? documentWidth : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.frame.origin.x = rulerWidth
            textView.frame.origin.y = 0
            if wordWrap {
                textView.frame.size.width = documentWidth
            } else if textView.frame.width < documentWidth {
                textView.frame.size.width = documentWidth
            }
            scrollView.hasHorizontalScroller = !wordWrap
            scrollView.hasVerticalScroller = true
            scrollView.horizontalScrollElasticity = wordWrap ? .none : .automatic
            resetHorizontalScrollIfNeeded()
            textView.needsDisplay = true
            ruler?.requestRedraw()
            if !duringLiveResize {
                ensureVisibleLayout()
            }
            markdownPresentation?.viewportChanged()
            updateTableCellFrame()
        }

        private func endEmojiCompletion() {
            emojiCompletionTask?.cancel()
            emojiCompletionTask = nil
            emojiCompletionID = UUID()
            emojiCompletionRequested = false
            textView?.emojiCompletionRange = nil
            textView?.emojiCompletionSpelling = ""
            textView?.emojiCompletionValues = []
            tableCellEditor?.emojiCompletionRange = nil
            tableCellEditor?.emojiCompletionSpelling = ""
            tableCellEditor?.emojiCompletionValues = []
            markdownPresentation?.endEmojiCompletion()
        }

        private func emojiSourceRange(_ range: NSRange, child: MarkdownTableCellEditor?) -> NSRange? {
            guard let child else { return range }
            guard child === tableCellEditor, !child.hasMarkedText(), let cell = tableCellRange,
                  tableCellRevision == contentRevision, let storage = textView?.textStorage,
                  cell.location <= storage.length, cell.length <= storage.length - cell.location,
                  storage.mutableString.substring(with: cell) == tableCellOriginal else { return nil }
            let projection = MarkdownTableCellEditor.projection(tableCellOriginal)
            guard child.string == projection.text, range.location < projection.rawBoundaries.count,
                  range.length <= projection.rawBoundaries.count - 1 - range.location else { return nil }
            let start = projection.rawBoundaries[range.location], end = projection.rawBoundaries[NSMaxRange(range)]
            return NSRange(location: cell.location + start, length: end - start)
        }

        func updateSmartSubstitutionSettings() {
            guard let textView, !textView.hasMarkedText(), tableCellEditor?.hasMarkedText() != true else { return }
            let enabled = document.language == .markdown && document.isMarkdownFormatted
            for view in [textView as NSTextView, tableCellEditor].compactMap({ $0 }) {
                view.isAutomaticQuoteSubstitutionEnabled = enabled && (aiPreferences?.smartQuotesEnabled ?? false)
                view.isAutomaticDashSubstitutionEnabled = enabled && (aiPreferences?.smartDashesEnabled ?? false)
                view.isAutomaticTextReplacementEnabled = enabled && (aiPreferences?.systemTextReplacementEnabled ?? false)
            }
        }

        func beginSmartTextChecking(_ options: [NSSpellChecker.OptionKey: Any], child: Bool = false) -> [NSSpellChecker.OptionKey: Any] {
            let token = UUID()
            if child { childSmartChecking = (token, contentRevision, document.id) } else { parentSmartChecking = (token, contentRevision, document.id) }
            var updated = options
            updated[Self.smartCheckingKey] = token.uuidString
            return updated
        }

        func filterSmartSubstitutions(_ results: [NSTextCheckingResult], options: [NSSpellChecker.OptionKey: Any], child: MarkdownTableCellEditor? = nil) -> [NSTextCheckingResult] {
            let checking = child == nil ? parentSmartChecking : childSmartChecking
            let current = checking.map { $0.0.uuidString == (options[Self.smartCheckingKey] as? String) && $0.1 == contentRevision && $0.2 == document.id } ?? false
            return results.filter { result in
                guard result.resultType == .quote || result.resultType == .dash || result.resultType == .replacement else { return true }
                guard current, let sourceRange = emojiSourceRange(result.range, child: child) else { return false }
                return markdownPresentation?.allowsSmartSubstitution(document: document, revision: contentRevision, range: sourceRange) == true
            }
        }

        func textView(_ view: NSTextView, willCheckTextIn range: NSRange, options: [NSSpellChecker.OptionKey: Any],
                      types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>) -> [NSSpellChecker.OptionKey: Any] {
            view === textView ? beginSmartTextChecking(options) : options
        }

        func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                      options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                      orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
            guard view === textView else { return results }
            return filterSmartSubstitutions(results, options: options)
        }

        private func scheduleEmojiCompletion() {
            guard emojiCompletionRequested, isActive, currentLanguage == .markdown, document.language == .markdown, document.ioState == .idle,
                  let parent = textView, !parent.hasMarkedText(), parent.completionText == nil else { return }
            let child = tableCellEditor
            let view: NSTextView = child.map { $0 as NSTextView } ?? parent
            guard view.isEditable, !view.hasMarkedText(), view.selectedRanges.count == 1, let text = view.textStorage?.mutableString else { return }
            let selection = view.selectedRange()
            guard selection.length == 0, selection.location <= text.length else { endEmojiCompletion(); return }
            var start = selection.location
            while start > 0 {
                let unit = text.character(at: start - 1)
                guard (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 43 || unit == 45 else { break }
                start -= 1
            }
            guard start > 0, text.character(at: start - 1) == 58 else { endEmojiCompletion(); return }
            start -= 1
            let range = NSRange(location: start, length: selection.location - start)
            guard let sourceRange = emojiSourceRange(range, child: child),
                  markdownPresentation?.allowsEmojiCompletion(document: document, revision: contentRevision, prefixRange: sourceRange) == true else {
                if markdownPresentation?.navigationPresentation(document: document, revision: contentRevision) != nil { endEmojiCompletion() }
                return
            }
            let spelling = text.substring(with: range), prefix = String(spelling.dropFirst())
            let revision = contentRevision, documentID = document.id, id = UUID()
            let completions = emojiCompletions
            emojiCompletionTask?.cancel()
            emojiCompletionID = id
            emojiCompletionTask = Task { [weak self, weak view, weak child] in
                let names = await Task.detached(priority: .userInitiated) { completions(prefix) }.value
                defer { self?.emojiCompletionDidFinish?() }
                guard !Task.isCancelled, let self, let view,
                      self.emojiCompletionRequested, self.emojiCompletionID == id, self.isActive,
                      self.document.id == documentID, self.contentRevision == revision,
                      self.currentLanguage == .markdown, self.document.language == .markdown, self.document.ioState == .idle,
                      (child != nil ? child === self.tableCellEditor : self.tableCellEditor == nil),
                      view.isEditable, self.textView?.completionText == nil, !view.hasMarkedText(), view.selectedRanges.count == 1, view.selectedRange() == selection,
                      let text = view.textStorage?.mutableString, NSMaxRange(range) <= text.length,
                      text.substring(with: range) == spelling,
                      self.emojiSourceRange(range, child: child) == sourceRange,
                      self.markdownPresentation?.allowsEmojiCompletion(document: self.document, revision: revision, prefixRange: sourceRange) == true else { return }
                guard let names, !names.isEmpty else { self.endEmojiCompletion(); return }
                if let child {
                    child.emojiCompletionRange = range; child.emojiCompletionSpelling = spelling
                    child.emojiCompletionValues = names.map { ":" + $0 + ":" }
                } else if let parent = view as? LacTextView {
                    parent.emojiCompletionRange = range; parent.emojiCompletionSpelling = spelling
                    parent.emojiCompletionValues = names.map { ":" + $0 + ":" }
                }
                view.complete(nil)
            }
        }

        private func acceptEmojiCompletion(_ word: String, range: NSRange, child: MarkdownTableCellEditor? = nil) -> Bool {
            guard emojiCompletionRequested, isActive, currentLanguage == .markdown, document.language == .markdown, document.ioState == .idle,
                  let parent = textView, (child != nil ? child === tableCellEditor : tableCellEditor == nil) else { return false }
            let view: NSTextView = child.map { $0 as NSTextView } ?? parent
            let recordedRange = child?.emojiCompletionRange ?? parent.emojiCompletionRange
            let values = child?.emojiCompletionValues ?? parent.emojiCompletionValues
            let spelling = child?.emojiCompletionSpelling ?? parent.emojiCompletionSpelling
            guard view.isEditable, !view.hasMarkedText(), recordedRange == range, values.contains(word),
                  let text = view.textStorage?.mutableString, NSMaxRange(range) <= text.length,
                  text.substring(with: range) == spelling,
                  view.selectedRanges.count == 1,
                  view.selectedRange() == NSRange(location: NSMaxRange(range), length: 0),
                  let sourceRange = emojiSourceRange(range, child: child),
                  markdownPresentation?.allowsEmojiCompletion(document: document, revision: contentRevision, prefixRange: sourceRange) == true else { return false }
            endEmojiCompletion()
            view.breakUndoCoalescing()
            view.undoManager?.beginUndoGrouping()
            defer { view.undoManager?.endUndoGrouping(); view.breakUndoCoalescing() }
            let hasClosingColon = NSMaxRange(range) < text.length && text.character(at: NSMaxRange(range)) == 58
            view.insertText(word, replacementRange: NSRange(location: range.location, length: range.length + (hasClosingColon ? 1 : 0)))
            return true
        }

        func updateMarkdownPresentation() {
            guard let textView, let foldLayoutManager else { return }
            synchronizeMarkdownImageProjection()
            if markdownPresentation == nil {
                markdownPresentation = MarkdownPresentationController(textView: textView, layout: foldLayoutManager)
                markdownPresentation?.projectedImageSource = { [weak self] address in
                    self?.markdownImageProjection.source(for: address)
                }
                markdownPresentation?.setMathPairContextEnabled(mathPairContextEnabled)
                markdownPresentation?.setStrikeCompletedTasks(strikeCompletedTasks)
                markdownPresentation?.setHeadingNumbering(headingNumbering)
                markdownPresentation?.setUppercaseHeadingLevels(uppercaseHeadingLevels)
                markdownPresentation?.setMathOptions(mathOptions)
                markdownPresentation?.emojiCompletionReady = { [weak self] in self?.scheduleEmojiCompletion() }
                markdownPresentation?.htmlBlockLink = { [weak self] address, range in
                    guard let self, self.isActive, self.document.language == .markdown, self.document.ioState == .idle,
                          let textView = self.textView, textView.window?.isKeyWindow == true,
                          !textView.hasMarkedText(), self.tableCellEditor == nil else { return }
                    self.cancelMarkdownLinkNavigation()
                    let token = self.markdownLinkID, revision = self.contentRevision, document = self.document
                    self.markdownLinkSelection = textView.selectedRanges
                    let snapshot = document.synchronizedSnapshot()
                    guard self.document === document, self.contentRevision == revision,
                          let parsed = self.markdownPresentation?.navigationPresentation(document: document, revision: revision) else { return }
                    self.postMarkdownLink(MarkdownLink(range: range, url: address), headings: parsed.headings,
                                          namedAnchors: parsed.namedAnchors, snapshot: snapshot, document: document, revision: revision, token: token)
                }
                textView.acceptEmojiCompletion = { [weak self] word, range in self?.acceptEmojiCompletion(word, range: range) ?? false }
                textView.dismissEmojiCompletion = { [weak self] in self?.endEmojiCompletion() }
                markdownPresentation?.geometryDidChange = { [weak self] in
                    self?.ruler?.requestRedraw()
                    self?.updateTableCellFrame()
                }
                markdownPresentation?.restoreCodeColors = { [weak self] ranges in
                    guard let self, let storage = self.textView?.textStorage else { return }
                    for range in ranges {
                        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
                        guard bounded.length > 0 else { continue }
                        self.pendingHighlightRanges.invalidate(bounded)
                        self.highlightedRanges.removeAll { NSIntersectionRange($0, bounded).length > 0 }
                    }
                    self.scheduleHighlight(delay: 0)
                }
                markdownPresentation?.restoreDelimiterHighlight = { [weak self] in
                    guard let self, let layoutManager = self.textView?.layoutManager else { return }
                    self.restoreFindHighlights()
                    for range in self.delimiterHighlightRanges {
                        layoutManager.addTemporaryAttribute(
                            .backgroundColor, value: NSColor.lacDelimiterMatchBackground,
                            forCharacterRange: range
                        )
                    }
                }
                textView.compositionStartHandler = { [weak self] marked in
                    guard let self else { return }
                    self.scrollView?.allowsMagnification = !marked && self.tableCellEditor?.hasMarkedText() != true
                }
                textView.compositionCompletionHandler = { [weak self] in
                    guard let self else { return }
                    if self.tableCellEditor?.hasMarkedText() != true { self.scrollView?.allowsMagnification = true }
                    if let textView = self.textView {
                        EditorTextView.applyWritingChecks(to: textView, spellingEnabled: self.writingSpellingEnabled, grammarEnabled: self.writingGrammarEnabled)
                    }
                    self.updateSyntaxOptions()
                    self.finishPendingMagnification()
                    self.markdownPresentation?.compositionFinished(revision: self.contentRevision)
                    self.applyVisibleLigatures()
                    self.applyFindHighlights()
                    if self.clearsDisabledSyntaxOnScroll { self.scheduleHighlight(delay: 0) }
                    self.applyWritingModes()
                    if self.pendingTypewriterAfterComposition {
                        self.pendingTypewriterAfterComposition = false
                        self.scheduleTypewriterCentering()
                    }
                    self.applyPendingContextSelection()
                }
            }
            updateSyntaxOptions()
            markdownPresentation?.update(
                document: document,
                enabled: document.language == .markdown && document.isMarkdownFormatted,
                outlineVisible: document.language == .markdown && isMarkdownOutlineVisible,
                isActive: isActive,
                revision: contentRevision,
                currentRevision: { [weak self] in self?.contentRevision ?? 0 }
            )
            updateTableCellWritingDirection()
            updateTableCellTaskStrike()
        }

        private func updateSyntaxOptions() {
            let next = aiPreferences?.markdownSyntax ?? .init()
            markdownPresentation?.setSyntaxOptions(next)
            guard textView?.hasMarkedText() != true, tableCellEditor?.hasMarkedText() != true,
                  syntaxOptions != next else { return }
            cancelMarkdownLinkNavigation()
            cachedMarkdownNavigation = nil
            syntaxOptions = next
            tableCellPresentation = nil
        }

        func updateMarkdownColors(_ colors: MarkdownColorOverrides) {
            guard let layout = foldLayoutManager, let view = textView, layout.markdownColors != colors else { return }
            layout.markdownColors = colors
            view.backgroundColor = colors.background?.nsColor ?? .lacEditorBackground
            view.insertionPointColor = colors.text?.nsColor ?? .labelColor
            highlightedRanges.removeAll()
            if !document.isSyntaxHighlightingEnabled {
                clearsDisabledSyntaxOnScroll = true
            }
            scheduleHighlight(delay: 0)
            markdownPresentation?.metricsChanged()
            applyTableCellColors()
            view.needsDisplay = true
        }

        private func editorAppearanceChanged() {
            guard let view = textView else { return }
            view.applyOrDeferTextMetrics { [weak self, weak view] in
                guard let self, let view else { return }
                let colors = foldLayoutManager?.markdownColors ?? .init()
                let foreground = colors.text?.nsColor ?? NSColor.labelColor
                view.textColor = foreground
                view.backgroundColor = colors.background?.nsColor ?? .lacEditorBackground
                view.insertionPointColor = foreground
                var typingAttributes = view.typingAttributes
                typingAttributes[.foregroundColor] = foreground
                view.typingAttributes = typingAttributes
                highlightedRanges.removeAll()
                scheduleHighlight(delay: 0)
                markdownMetricsChanged()
                applyTableCellColors()
                view.needsDisplay = true
            }
        }

        private func applyTableCellColors() {
            guard let child = tableCellEditor, !child.hasMarkedText(), let colors = foldLayoutManager?.markdownColors else { return }
            child.backgroundColor = colors.background?.nsColor ?? .lacEditorBackground
            child.insertionPointColor = colors.text?.nsColor ?? .labelColor
            let range = NSRange(location: 0, length: (child.string as NSString).length)
            guard range.length > 0 else { return }
            child.layoutManager?.addTemporaryAttribute(.foregroundColor, value: colors.text?.nsColor ?? NSColor.labelColor, forCharacterRange: range)
        }

        func updateStrikeCompletedTasks(_ enabled: Bool) {
            guard strikeCompletedTasks != enabled else { return }
            strikeCompletedTasks = enabled
            markdownPresentation?.setStrikeCompletedTasks(enabled)
            updateTableCellTaskStrike()
        }

        func updateMathPairContextEnabled(_ enabled: Bool) {
            guard mathPairContextEnabled != enabled else { return }
            mathPairContextEnabled = enabled
            markdownPresentation?.setMathPairContextEnabled(enabled)
        }

        func updateHeadingNumbering(_ enabled: Bool) {
            guard headingNumbering != enabled else { return }
            headingNumbering = enabled
            markdownPresentation?.setHeadingNumbering(enabled)
        }

        func updateUppercaseHeadingLevels(_ levels: Set<Int>) {
            guard uppercaseHeadingLevels != levels else { return }
            uppercaseHeadingLevels = levels
            markdownPresentation?.setUppercaseHeadingLevels(levels)
        }

        func updateListStyles(_ styles: MarkdownListStyles) {
            guard listStyles != styles else { return }
            listStyles = styles
            foldLayoutManager?.markdownListStyles = styles
            markdownPresentation?.metricsChanged()
        }

        func markdownMetricsChanged() { markdownPresentation?.metricsChanged() }

        func updateMathOptions(_ options: MathJaxRenderService.Options) {
            mathOptions = options
            markdownPresentation?.setMathOptions(options)
        }

        func updatePerformanceFeatures() {
            if let foldLayoutManager {
                EditorLayoutPolicy.configure(
                    foldLayoutManager,
                    textLength: textView?.textStorage?.length ?? 0
                )
            }
            let nextSyntaxEnabled = document.isSyntaxHighlightingEnabled
            if syntaxHighlightingEnabled && !nextSyntaxEnabled {
                clearsDisabledSyntaxOnScroll = true
                cancelPendingHighlight()
                clearSyntaxAttributesInVisibleRange()
            } else if nextSyntaxEnabled {
                clearsDisabledSyntaxOnScroll = false
            }
            syntaxHighlightingEnabled = nextSyntaxEnabled
            if !document.isFoldingEnabled { clearFold() }
        }

        private func scheduleResizeLayout(wordWrap: Bool) {
            pendingLiveResizeWordWrap = wordWrap
            if scrollView?.window?.inLiveResize == true {
                beginLiveResizeIfNeeded()
            }
            guard liveResizeLayoutWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                liveResizeLayoutWorkItem = nil
                let nextWordWrap = pendingLiveResizeWordWrap ?? self.wordWrap
                pendingLiveResizeWordWrap = nil
                let stillLiveResizing = scrollView?.window?.inLiveResize == true
                if stillLiveResizing {
                    beginLiveResizeIfNeeded()
                }
                applyLayout(
                    wordWrap: nextWordWrap,
                    force: false,
                    duringLiveResize: stillLiveResizing
                )
                if !stillLiveResizing, isLiveResizing {
                    finishLiveResize()
                }
            }
            liveResizeLayoutWorkItem = workItem
            let delay: TimeInterval = scrollView?.window?.inLiveResize == true
                ? 1.0 / 60.0
                : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func beginLiveResizeIfNeeded() {
            guard !isLiveResizing else { return }
            isLiveResizing = true
            os_signpost(
                .begin,
                log: editorPerformanceLog,
                name: "EditorLiveResize"
            )
            cancelPendingHighlight()
            layoutPrefetchWorkItem?.cancel()
            layoutPrefetchWorkItem = nil
        }

        private func finishLiveResize() {
            guard isLiveResizing else { return }
            isLiveResizing = false
            liveResizeLayoutWorkItem?.cancel()
            liveResizeLayoutWorkItem = nil
            let nextWordWrap = pendingLiveResizeWordWrap ?? wordWrap
            pendingLiveResizeWordWrap = nil
            applyLayout(
                wordWrap: nextWordWrap,
                force: true,
                duringLiveResize: false
            )
            ruler?.requestRedraw()
            scheduleHighlight(delay: 0)
            scheduleDirectionalLayoutPrefetch()
            os_signpost(
                .end,
                log: editorPerformanceLog,
                name: "EditorLiveResize"
            )
        }

        private func resetHorizontalScrollIfNeeded() {
            guard wordWrap,
                  let scrollView,
                  scrollView.contentView.bounds.origin.x != 0 else { return }
            let y = scrollView.contentView.bounds.origin.y
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func scheduleDirectionalLayoutPrefetch() {
            layoutPrefetchWorkItem?.cancel()
            layoutPrefetchWorkItem = nil
            guard isActive, !isLiveResizing, !wordWrap, let textView,
                  let window = textView.window, window.isVisible,
                  window.tabGroup.map({ $0.selectedWindow === window }) ?? true,
                  EditorLayoutPolicy.usesViewportLayout(
                    textLength: textView.textStorage?.length ?? 0
                  ) else { return }
            let currentY = textView.visibleRect.minY
            let direction: CGFloat = currentY >= lastViewportOriginY ? 1 : -1
            lastViewportOriginY = currentY
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, isActive, !isLiveResizing, let textView,
                      let window = textView.window, window.isVisible,
                      window.tabGroup.map({ $0.selectedWindow === window }) ?? true,
                      let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer,
                      EditorLayoutPolicy.usesViewportLayout(
                        textLength: textView.textStorage?.length ?? 0
                      ), !wordWrap else { return }
                layoutPrefetchWorkItem = nil
                let visible = textView.visibleRect.offsetBy(
                    dx: -textView.textContainerOrigin.x,
                    dy: -textView.textContainerOrigin.y
                )
                let target = visible.offsetBy(
                    dx: 0,
                    dy: direction * visible.height
                )
                layoutManager.ensureLayout(
                    forBoundingRect: target,
                    in: textContainer
                )
            }
            layoutPrefetchWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        func updateLineNumbersVisibility(_ isVisible: Bool) {
            guard let scrollView else { return }
            guard lineNumbersVisible != isVisible else { return }
            lineNumbersVisible = isVisible
            scrollView.hasVerticalRuler = isVisible && !markdownVerticalWriting
            scrollView.hasHorizontalRuler = isVisible && markdownVerticalWriting
            scrollView.rulersVisible = isVisible
            lastRulerWidth = -1
            ruler?.needsDisplay = true
        }

        func writingUserDidScroll() {
            typewriterWorkItem?.cancel()
            typewriterWorkItem = nil
            selectionVisibilityWorkItem?.cancel()
        }

        func updateWritingModes(focus: Bool, typewriter: Bool) {
            if writingTypewriter && !typewriter {
                typewriterWorkItem?.cancel()
                typewriterWorkItem = nil
                pendingTypewriterAfterComposition = false
            }
            writingFocus = focus
            writingTypewriter = typewriter
            applyWritingModes()
        }

        func updateTopInset(_ topInset: CGFloat) {
            writingBaseInset = topInset
            applyWritingModes()
        }

        private func applyWritingModes() {
            guard let textView, !textView.hasMarkedText() else { return }
            textView.focusModeEnabled = writingFocus
            let extent = markdownVerticalWriting ? (scrollView?.contentView.bounds.width ?? 0) : (scrollView?.contentView.bounds.height ?? 0)
            // The vertical layout keeps its previous geometry; the comfortable top margin is horizontal-only.
            let baseInset = markdownVerticalWriting ? 0 : writingBaseInset
            let inset = writingTypewriter ? max(baseInset, extent / 2) : baseInset
            let desired = NSSize(width: textView.textContainerInset.width, height: inset)
            guard abs(textView.textContainerInset.width - desired.width) > 0.5 || abs(textView.textContainerInset.height - desired.height) > 0.5 else { return }
            textView.textContainerInset = desired
            textView.needsLayout = true
            textView.needsDisplay = true
            invalidateEntireRuler(displayImmediately: true)
            refreshRuler()
        }

        private func scheduleTypewriterCentering() {
            typewriterWorkItem?.cancel()
            guard writingTypewriter, isActive, let textView, textView.isEditable else { return }
            if textView.hasMarkedText() { pendingTypewriterAfterComposition = true; return }
            let revision = contentRevision
            let documentID = document.id
            typewriterSelection = textView.selectedRange()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, self.isActive, self.writingTypewriter,
                      self.document.id == documentID, self.contentRevision == revision,
                      textView.isEditable else { return }
                if textView.hasMarkedText() { self.pendingTypewriterAfterComposition = true; return }
                guard self.typewriterSelection == textView.selectedRange(),
                      let scrollView = self.scrollView, let layout = textView.layoutManager,
                      textView.textContainer != nil, let storage = textView.textStorage else { return }
                let position = min(textView.selectedRange().location, storage.length)
                let rect: NSRect
                if storage.length == 0 || (position == storage.length && storage.length > 0 &&
                    (storage.mutableString.character(at: storage.length - 1) == 10 || storage.mutableString.character(at: storage.length - 1) == 13)) {
                    if storage.length > 0 {
                        var start = storage.length - 1
                        if storage.mutableString.character(at: start) == 10, start > 0,
                           storage.mutableString.character(at: start - 1) == 13 { start -= 1 }
                        layout.ensureLayout(forCharacterRange: NSRange(location: start, length: storage.length - start))
                    }
                    rect = layout.extraLineFragmentRect
                    guard !rect.isEmpty else { return }
                } else {
                    let character = min(position, storage.length - 1)
                    let composed = storage.mutableString.rangeOfComposedCharacterSequence(at: character)
                    layout.ensureLayout(forCharacterRange: composed)
                    rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: composed.location), effectiveRange: nil)
                }
                let clip = scrollView.contentView
                let viewRect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                let clipRect = clip.convert(viewRect, from: textView)
                let origin = self.markdownVerticalWriting
                    ? NSPoint(x: clipRect.midX - clip.bounds.width / 2, y: clip.bounds.origin.y)
                    : NSPoint(x: clip.bounds.origin.x, y: clipRect.midY - clip.bounds.height / 2)
                let proposed = NSRect(origin: origin, size: clip.bounds.size)
                let constrained = clip.constrainBoundsRect(proposed)
                self.isTypewriterScrolling = true
                clip.scroll(to: constrained.origin)
                scrollView.reflectScrolledClipView(clip)
                self.isTypewriterScrolling = false
                self.typewriterWorkItem = nil
            }
            typewriterWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        func updateActivity(_ newValue: Bool) {
            guard isActive != newValue else { return }
            if !newValue, markdownLinkTask != nil { cancelMarkdownLinkNavigation() }
            if !newValue { clipboardPasteTask?.cancel(); clipboardPasteTask = nil }
            if !newValue { clipboardCopyTask?.cancel(); clipboardCopyTask = nil }
            if !newValue { endEmojiCompletion() }
            if !newValue { textView?.cancelTableDrag(); finishTableCell(); tableAccessibilityVirtualTarget = nil }
            isActive = newValue
            updateMarkdownPresentation()
            guard newValue else {
                typewriterWorkItem?.cancel()
                typewriterWorkItem = nil
                pendingTypewriterAfterComposition = false
                cancelAICompletion()
                markdownPresentation?.cancel()
                rulerRefreshWorkItem?.cancel()
                rulerRefreshWorkItem = nil
                rulerRefreshNeedsLayout = false
                liveResizeLayoutWorkItem?.cancel()
                liveResizeLayoutWorkItem = nil
                pendingLiveResizeWordWrap = nil
                isLiveResizing = false
                layoutPrefetchWorkItem?.cancel()
                layoutPrefetchWorkItem = nil
                scheduleTextCodecSuggestion()
                cancelDelimiterMatch(clearHighlight: true, releaseSnapshot: true)
                textView?.requestsFirstResponderWhenAttached = false
                if let textView,
                   let window = textView.window,
                   window.firstResponder === textView {
                    window.makeFirstResponder(nil)
                }
                cancelPendingHighlight()
                cancelFoldTask()
                return
            }
            textView?.requestsFirstResponderWhenAttached = true
            updateLayout(wordWrap: wordWrap, force: true)
            ruler?.requestRedraw()
            scheduleHighlight(delay: 0)
            scheduleDelimiterMatch(delay: 0)
            scheduleTextCodecSuggestion(delay: 0.18)
            DispatchQueue.main.async { [weak self] in
                guard let self, isActive, let textView, let window = textView.window else {
                    return
                }
                ruler?.requestRedraw()
                window.makeFirstResponder(textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            clearFindHighlights()
            cancelMarkdownLinkNavigation()
            cachedMarkdownNavigation = nil
            guard !isApplyingExternalUpdate, let textView else { return }
            cancelAICompletion()
            let revision = contentRevision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.contentRevision == revision else { return }
                self.scheduleAICompletion()
            }
            if let text = textView.textStorage?.mutableString,
               lineIndex.textLength != text.length {
                lineIndex.reset(with: text)
            }
            restorePendingOffscreenEdit(in: textView)
            document.noteLiveEdit(isEmpty: textView.textStorage?.length == 0)
            markdownPresentation?.edited(revision: contentRevision)
            if emojiCompletionRequested { DispatchQueue.main.async { [weak self] in self?.scheduleEmojiCompletion() } }
            NotificationCenter.default.post(
                name: EditorCommandNotification.documentContentDidChange,
                object: document.id
            )
            document.statusMessage = nil
            clearFold()
            refreshRuler()
            updateCursor()
            scheduleDelimiterMatch()
            scheduleSelectionVisibilitySync()
            if !isApplyingAutomatedEdit { scheduleTypewriterCentering() }
            scheduleModelSync()
            scheduleHighlight()
            scheduleTextCodecSuggestion()
            if let location = pendingListNormalizationLocation {
                pendingListNormalizationLocation = nil
                scheduleOrderedListNormalization(around: location)
            }
        }

        private func scheduleModelSync() {
            modelSyncWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                modelSyncWorkItem = nil
                flushModelText(reconcileDirtyState: true)
            }
            modelSyncWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.35,
                execute: workItem
            )
        }

        func flushModelText(reconcileDirtyState: Bool) {
            if reconcileDirtyState {
                modelSyncWorkItem?.cancel()
                modelSyncWorkItem = nil
            }
            let needsSynchronization = document.hasPendingLiveEdits
            let syncSignpostID = OSSignpostID(log: editorPerformanceLog)
            if needsSynchronization {
                os_signpost(
                    .begin,
                    log: editorPerformanceLog,
                    name: "EditorModelSync",
                    signpostID: syncSignpostID
                )
            }
            if document.synchronizeLiveText() {
                lastSynchronizedRevision = document.textRevision
            }
            if needsSynchronization {
                os_signpost(
                    .end,
                    log: editorPerformanceLog,
                    name: "EditorModelSync",
                    signpostID: syncSignpostID
                )
            }
            if reconcileDirtyState {
                document.refreshDirtyState()
                lastSynchronizedRevision = document.textRevision
            }
        }

        func advanceContentRevision() {
            cancelAICompletion()
            if document.provenance.isEnabled {
                document.provenance.configure(enabled: false, length: 0)
                document.provenance.configure(enabled: true, length: (document.text as NSString).length)
            }
            contentRevision &+= 1
            markdownPresentation?.edited(revision: contentRevision)
            cancelFoldTask()
            delimiterSnapshot = nil
            delimiterSnapshotRevision = nil
            delimiterMatchingContext.reset()
            cancelDelimiterMatch(clearHighlight: true)
        }

        private func scheduleSelectionVisibilitySync() {
            selectionVisibilityWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let textView else { return }
                let selection = textView.selectedRange()
                guard let text = textView.textStorage?.mutableString else { return }
                if text.length > 0, let layoutManager = textView.layoutManager {
                    let anchor = min(selection.location, text.length - 1)
                    let lineRange = text.lineRange(
                        for: NSRange(location: anchor, length: 0)
                    )
                    layoutManager.invalidateLayout(
                        forCharacterRange: lineRange,
                        actualCharacterRange: nil
                    )
                    layoutManager.ensureLayout(forCharacterRange: lineRange)
                }
                textView.scrollRangeToVisible(selection)
                updateCursor()
                refreshRuler()
            }
            selectionVisibilityWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func captureOffscreenSelectionPosition(
            in textView: NSTextView,
            affectedRange: NSRange,
            replacement: String
        ) {
            let expectedSelection = NSRange(
                location: affectedRange.location + (replacement as NSString).length,
                length: 0
            )
            if let pendingAnchor = pendingOffscreenEditAnchor {
                if pendingAnchor == affectedRange.location {
                    pendingOffscreenSelectionRange = expectedSelection
                    return
                }
                pendingSelectionScrollOriginY = nil
                pendingOffscreenEditAnchor = nil
                pendingOffscreenSelectionRange = nil
            }

            guard let layoutManager = textView.layoutManager,
                  let text = textView.textStorage?.mutableString else { return }
            // IME commits can temporarily move selectedRange to the document end.
            // The delegate's affected range remains the authoritative edit anchor.
            let location = min(affectedRange.location, text.length)
            if location == 0, textView.visibleRect.minY > 0.5 {
                pendingSelectionScrollOriginY = 0
                pendingOffscreenEditAnchor = affectedRange.location
                pendingOffscreenSelectionRange = expectedSelection
                return
            }
            let lineRect: NSRect
            if location == text.length,
               !layoutManager.extraLineFragmentRect.isEmpty {
                lineRect = layoutManager.extraLineFragmentRect
            } else if text.length > 0 {
                let anchor = min(location, text.length - 1)
                let lineRange = text.lineRange(
                    for: NSRange(location: anchor, length: 0)
                )
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: lineRange,
                    actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else { return }
                lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
            } else {
                lineRect = NSRect(
                    x: 0,
                    y: 0,
                    width: 1,
                    height: textView.font?.pointSize ?? 14
                )
            }

            var textViewRect = lineRect
            textViewRect.origin.y += textView.textContainerOrigin.y
            let visibleRect = textView.visibleRect
            guard textViewRect.maxY < visibleRect.minY
                    || textViewRect.minY > visibleRect.maxY else { return }
            pendingSelectionScrollOriginY = max(
                0,
                textViewRect.minY - textView.textContainerInset.height
            )
            pendingOffscreenEditAnchor = affectedRange.location
            pendingOffscreenSelectionRange = expectedSelection
        }

        private func restorePendingOffscreenEdit(in textView: NSTextView) {
            guard !textView.hasMarkedText(),
                  let expectedSelection = pendingOffscreenSelectionRange else {
                return
            }

            let textLength = textView.textStorage?.length ?? 0
            let location = min(expectedSelection.location, textLength)
            let selection = NSRange(
                location: location,
                length: min(
                    expectedSelection.length,
                    textLength - location
                )
            )
            isRestoringOffscreenEdit = true
            textView.setSelectedRange(selection)
            if let targetY = pendingSelectionScrollOriginY, let scrollView {
                scrollView.contentView.scroll(to: NSPoint(
                    x: scrollView.contentView.bounds.origin.x,
                    y: max(0, targetY)
                ))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            isRestoringOffscreenEdit = false
            pendingSelectionScrollOriginY = nil
            pendingOffscreenEditAnchor = nil
            pendingOffscreenSelectionRange = nil
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            tableAccessibilityVirtualTarget = nil
            if tableCellEditor != nil && !applyingTableCell { finishTableCell() }
            clearFold()
            // Снимать подсветку совпадений до правки: временные атрибуты сдвигаются вместе с текстом,
            // и после неё сохранённые диапазоны уже не совпадают с окрашенными.
            clearFindHighlights()
            let replacement = replacementString ?? ""
            guard let nsText = textView.textStorage?.mutableString else { return false }
            if !isApplyingAutomatedEdit, let view = textView as? LacTextView, view.editSource == .typed, !view.hasMarkedText() {
                if replacement == ":" {
                    if emojiCompletionRequested { endEmojiCompletion() }
                    else { emojiCompletionRequested = true; markdownPresentation?.beginEmojiCompletion() }
                } else if emojiCompletionRequested && !replacement.utf16.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 43 || $0 == 45 }) {
                    endEmojiCompletion()
                }
            } else if emojiCompletionRequested && !applyingTableCell { endEmojiCompletion() }
            let safeLocation = min(affectedCharRange.location, nsText.length)
            let safeRange = NSRange(
                location: safeLocation,
                length: min(
                    affectedCharRange.length,
                    nsText.length - safeLocation
                )
            )
            if markdownImageProjectionEnabled,
               markdownImageProjection.intersectsToken(safeRange, in: nsText as String) {
                NSSound.beep()
                return false
            }
            let replacementLength = (replacement as NSString).length
            func recordProvenance() {
                let source: DocumentProvenance.Source
                if isApplyingAIGenerated { source = .generated }
                else if isApplyingAutomatedEdit || textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true { source = .unknown }
                else { source = (textView as? LacTextView)?.editSource ?? .unknown }
                document.provenance.record(editedRange: safeRange, replacementLength: replacementLength, source: source)
            }
            cancelAICompletion()
            contentRevision &+= 1
            markdownPresentation?.noteFenceContextEdit(range: safeRange, replacement: replacement, in: nsText, revision: contentRevision)
            let editDelta = DocumentEditDelta(
                documentID: document.id,
                revision: contentRevision,
                editedRange: safeRange,
                replacementLength: replacementLength,
                changeInLength: replacementLength - safeRange.length,
                changedLineRange: nil
            )
            lastSyntaxEdit = editDelta
            pendingHighlightRanges.append(editDelta)
            let affectedLineStart = nsText.lineRange(for: safeRange).location
            pendingHighlightRanges.invalidate(NSRange(
                location: affectedLineStart,
                length: max(0, nsText.length + editDelta.changeInLength - affectedLineStart)
            ))
            translateHighlightedRanges(after: NSRange(location: affectedLineStart, length: 0))
            syntaxHighlightContext.invalidate(after: safeRange.location)
            delimiterMatchingContext.invalidate(after: safeRange.location)
            delimiterSnapshot = nil
            delimiterSnapshotRevision = nil
            cancelDelimiterMatch(clearHighlight: true)
            if !isApplyingAutomatedEdit {
                listNormalizationWorkItem?.cancel()
                listNormalizationQueue.cancelAllOperations()
                document.taskCoordinator.cancel(.listNormalization)
            }

            if !isApplyingAutomatedEdit {
                captureOffscreenSelectionPosition(
                    in: textView,
                    affectedRange: safeRange,
                    replacement: replacement
                )
            }

            if isApplyingAutomatedEdit {
                markdownPresentation?.beforeEdit(range: safeRange, replacementLength: replacementLength)
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                recordProvenance()
                return true
            }
            guard document.language == .markdown else {
                markdownPresentation?.beforeEdit(range: safeRange, replacementLength: replacementLength)
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                recordProvenance()
                return true
            }

            guard ListContinuationService.shouldNormalizeOrderedListEdit(
                    in: nsText,
                    range: safeRange,
                    replacement: replacement
                  ),
                  !ListContinuationService.isManualOrderedMarkerEdit(
                    in: nsText,
                    range: safeRange,
                    replacement: replacement
                  ) else {
                markdownPresentation?.beforeEdit(range: safeRange, replacementLength: replacementLength)
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                recordProvenance()
                return true
            }

            let intendedCaretLocation = safeRange.location
                + (replacement as NSString).length
            if ListContinuationService.orderedListExceedsBackgroundThreshold(
                in: nsText,
                aroundUTF16Location: safeRange.location
            ) {
                pendingListNormalizationLocation = intendedCaretLocation
                markdownPresentation?.beforeEdit(range: safeRange, replacementLength: replacementLength)
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                recordProvenance()
                return true
            }

            let prospectiveText = NSMutableString(string: textView.string)
            prospectiveText.replaceCharacters(in: safeRange, with: replacement)
            guard let normalization = ListContinuationService.normalizeOrderedList(
                in: prospectiveText as String,
                aroundUTF16Location: intendedCaretLocation
            ), let combinedEdit = combinedEdit(
                from: textView.string,
                to: normalization.text
            ) else {
                markdownPresentation?.beforeEdit(range: safeRange, replacementLength: replacementLength)
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                recordProvenance()
                return true
            }

            isApplyingAutomatedEdit = true
            textView.insertText(
                combinedEdit.replacement,
                replacementRange: combinedEdit.range
            )
            textView.setSelectedRange(NSRange(
                location: normalization.mappedLocation(for: intendedCaretLocation),
                length: 0
            ))
            isApplyingAutomatedEdit = false
            return false
        }

        private func scheduleOrderedListNormalization(around location: Int) {
            listNormalizationWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let textView else { return }
                listNormalizationWorkItem = nil
                let snapshot = textView.string
                let revision = contentRevision
                let taskGeneration = document.taskCoordinator.begin(.listNormalization)
                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled else { return }
                    let result = ListContinuationService.normalizeOrderedList(
                        in: snapshot,
                        aroundUTF16Location: location
                    )
                    guard let result, !operation.isCancelled,
                          document.taskCoordinator.isCurrent(
                            taskGeneration,
                            for: .listNormalization
                          ) else { return }
                    DispatchQueue.main.async { [weak self, weak operation] in
                        guard let self, let operation, !operation.isCancelled,
                              revision == contentRevision,
                              document.taskCoordinator.isCurrent(
                                taskGeneration,
                                for: .listNormalization
                              ),
                              let edit = combinedEdit(from: snapshot, to: result.text) else { return }
                        document.taskCoordinator.finish(
                            .listNormalization,
                            generation: taskGeneration
                        )
                        let selectionBeforeApply = textView.selectedRange()
                        isApplyingAutomatedEdit = true
                        textView.insertText(
                            edit.replacement,
                            replacementRange: edit.range
                        )
                        textView.setSelectedRange(NSRange(
                            location: result.mappedLocation(
                                for: selectionBeforeApply.location
                            ),
                            length: 0
                        ))
                        textView.undoManager?.setActionName(L10n.tr("整理有序列表"))
                        isApplyingAutomatedEdit = false
                    }
                }
                document.taskCoordinator.attach(
                    operation,
                    kind: .listNormalization,
                    generation: taskGeneration
                )
                listNormalizationQueue.addOperation(operation)
            }
            listNormalizationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if emojiCompletionRequested { DispatchQueue.main.async { [weak self] in self?.scheduleEmojiCompletion() } }
            if let markdownLinkSelection, textView?.selectedRanges != markdownLinkSelection { cancelMarkdownLinkNavigation() }
            clipboardPasteTask?.cancel()
            clipboardPasteTask = nil
            clipboardCopyTask?.cancel()
            clipboardCopyTask = nil
            if let target = tableAccessibilityVirtualTarget, textView?.selectedRange() != target.range {
                tableAccessibilityVirtualTarget = nil
            }
            if tableCellEditor == nil && tableDragSnapshot == nil, let textView {
                if foldLayoutManager?.clearActiveTableIfSelectionOutside(textView.selectedRange()) == true {
                    markdownPresentation?.tableEditingGeometryChanged(cell: nil)
                }
            }
            if typewriterWorkItem != nil, let textView, typewriterSelection != textView.selectedRange() {
                if textView.editSource == .typed || textView.editSource == .pasted {
                    typewriterSelection = textView.selectedRange()
                } else {
                    typewriterWorkItem?.cancel()
                    typewriterWorkItem = nil
                }
            }
            cancelAICompletion()
            cancelFoldIfSelectionChanged()
            guard !isApplyingExternalUpdate,
                  !isRestoringOffscreenEdit else { return }
            guard textView?.hasMarkedText() != true else {
                cancelDelimiterMatch(clearHighlight: true)
                return
            }
            markdownPresentation?.selectionChanged()
            textView?.needsDisplay = true
            invalidateEntireRuler(
                displayImmediately: true,
                invalidateLineMap: false
            )
            updateCursor()
            scheduleDelimiterMatch()
            scheduleTextCodecSuggestion()
        }

        func selectionDidChangeDuringTracking() {
            if let target = tableAccessibilityVirtualTarget, textView?.selectedRange() != target.range {
                tableAccessibilityVirtualTarget = nil
            }
            if tableCellEditor == nil && tableDragSnapshot == nil, let textView {
                if foldLayoutManager?.clearActiveTableIfSelectionOutside(textView.selectedRange()) == true {
                    markdownPresentation?.tableEditingGeometryChanged(cell: nil)
                }
            }
            if typewriterWorkItem != nil, typewriterSelection != textView?.selectedRange() {
                typewriterWorkItem?.cancel()
                typewriterWorkItem = nil
            }
            cancelAICompletion()
            cancelFoldIfSelectionChanged()
            guard !isRestoringOffscreenEdit else { return }
            guard textView?.hasMarkedText() != true else {
                cancelDelimiterMatch(clearHighlight: true)
                return
            }
            markdownPresentation?.selectionChanged()
            textView?.needsDisplay = true
            invalidateEntireRuler(
                displayImmediately: true,
                invalidateLineMap: false
            )
            scheduleDelimiterMatch()
            scheduleTextCodecSuggestion()
        }

        func synchronizeSelectionState() {
            DispatchQueue.main.async { [weak self] in
                self?.updateCursor()
                self?.scheduleDelimiterMatch(delay: 0)
                self?.scheduleTextCodecSuggestion(delay: 0.18)
            }
        }

        private func scheduleTextCodecSuggestion(delay: TimeInterval = 0.18) {
            textCodecSuggestionWorkItem?.cancel()
            textCodecSuggestionGeneration &+= 1
            let generation = textCodecSuggestionGeneration
            // updateNSView may call this while SwiftUI is reconciling. Publish
            // the suggestion outside that update, and discard stale clears.
            DispatchQueue.main.async { [weak self] in
                guard let self, textCodecSuggestionGeneration == generation,
                      document.textCodecSuggestionTitle != nil else { return }
                document.textCodecSuggestionTitle = nil
            }
            guard isActive,
                  let textView,
                  !textView.hasMarkedText(),
                  textView.textStorage != nil else {
                return
            }
            let selection = textView.selectedRange()
            let revision = contentRevision
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, isActive,
                      textCodecSuggestionGeneration == generation,
                      let textView,
                      let currentText = textView.textStorage?.mutableString,
                      textView.selectedRange() == selection,
                      contentRevision == revision,
                      let candidate = TextCodecService.candidate(
                          in: currentText,
                          selection: selection,
                          allowsTokenAtCaret: true,
                          maximumLength: TextCodecService.automaticDetectionLimit
                      ),
                      let detection = TextCodecService.detect(
                          in: candidate.text,
                          allowsBase64: selection.length > 0
                      ) else {
                    return
                }
                document.textCodecSuggestionTitle = detection.suggestionTitle
            }
            textCodecSuggestionWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func scheduleDelimiterMatch(delay: TimeInterval = 0.03) {
            cancelDelimiterMatch(clearHighlight: true)
            guard isActive,
                  DelimiterMatchingService.supports(currentLanguage),
                  let textView,
                  !textView.hasMarkedText() else { return }
            let selection = textView.selectedRange()
            guard selection.length <= 1 else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      isActive,
                      !textView.hasMarkedText(),
                      textView.selectedRange() == selection else { return }
                delimiterMatchWorkItem = nil
                let revision = contentRevision
                let language = currentLanguage
                let snapshot: String
                if delimiterSnapshotRevision == revision,
                   let cached = delimiterSnapshot {
                    snapshot = cached
                } else {
                    snapshot = textView.string
                    delimiterSnapshot = snapshot
                    delimiterSnapshotRevision = revision
                }
                let taskGeneration = document.taskCoordinator.begin(.delimiterMatch)
                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled else { return }
                    let match = DelimiterMatchingService.match(
                        in: snapshot,
                        selection: selection,
                        language: language,
                        revision: revision,
                        context: delimiterMatchingContext,
                        isCancelled: { operation.isCancelled }
                    )
                    guard !operation.isCancelled else { return }
                    DispatchQueue.main.async { [weak self, weak operation] in
                        guard let self, let operation, !operation.isCancelled,
                              isActive,
                              contentRevision == revision,
                              currentLanguage == language,
                              textView.selectedRange() == selection,
                              document.taskCoordinator.isCurrent(
                                taskGeneration,
                                for: .delimiterMatch
                              ) else { return }
                        document.taskCoordinator.finish(
                            .delimiterMatch,
                            generation: taskGeneration
                        )
                        delimiterMatchOperation = nil
                        if let match {
                            applyDelimiterMatch(match)
                        }
                    }
                }
                delimiterMatchOperation = operation
                document.taskCoordinator.attach(
                    operation,
                    kind: .delimiterMatch,
                    generation: taskGeneration
                )
                delimiterMatchQueue.addOperation(operation)
            }
            delimiterMatchWorkItem = workItem
            if delay <= 0 {
                DispatchQueue.main.async(execute: workItem)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }

        private func applyDelimiterMatch(_ match: DelimiterMatchingService.Match) {
            guard let layoutManager = textView?.layoutManager else { return }
            clearDelimiterHighlight()
            delimiterHighlightRanges = [match.openingRange, match.closingRange]
            for range in delimiterHighlightRanges {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.lacDelimiterMatchBackground,
                    forCharacterRange: range
                )
            }
        }

        private func clearDelimiterHighlight() {
            guard !delimiterHighlightRanges.isEmpty else { return }
            if let layoutManager = textView?.layoutManager {
                for range in delimiterHighlightRanges {
                    layoutManager.removeTemporaryAttribute(
                        .backgroundColor,
                        forCharacterRange: range
                    )
                }
            }
            let clearedRanges = delimiterHighlightRanges
            delimiterHighlightRanges.removeAll(keepingCapacity: true)
            markdownPresentation?.restoreBackground(in: clearedRanges)
            restoreFindHighlights(intersecting: clearedRanges)
        }

        /// Сброс фона скобок или Markdown не должен стирать жёлтую подсветку совпадений под ним.
        private func restoreFindHighlights(intersecting ranges: [NSRange]? = nil) {
            guard let layoutManager = textView?.layoutManager else { return }
            for range in appliedFindRanges where ranges?.contains(where: { NSIntersectionRange($0, range).length > 0 }) ?? true {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor.lacFindMatchBackground, forCharacterRange: range
                )
            }
        }

        /// Подсветка всех совпадений поиска в видимой области: временные атрибуты, текст и undo не меняются.
        private func applyFindHighlights() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let currentVisible = visibleHighlightRange()
            // Прокрутка внутри того же тайла с теми же совпадениями ничего не перерисовывает.
            if !findMatchesChanged, !appliedFindRanges.isEmpty || appliedFindVisibleRange != nil,
               currentVisible == appliedFindVisibleRange { return }
            clearAppliedFindHighlights(in: layoutManager)
            findMatchesChanged = false
            guard !findHighlightMatches.isEmpty, !textView.hasMarkedText(),
                  !markdownImageProjectionEnabled,   // координаты проекции отличаются от исходника
                  !document.hasPendingLiveEdits,
                  let visible = currentVisible else { return }
            let length = textView.textStorage?.length ?? 0
            var index = TextSearchService.firstIndex(in: findHighlightMatches, endingAfter: visible.location)
            var applied: [NSRange] = []
            while index < findHighlightMatches.count, findHighlightMatches[index].location < NSMaxRange(visible) {
                let range = findHighlightMatches[index]
                if NSMaxRange(range) <= length {
                    layoutManager.addTemporaryAttribute(
                        .backgroundColor, value: NSColor.lacFindMatchBackground, forCharacterRange: range
                    )
                    applied.append(range)
                }
                index += 1
            }
            appliedFindRanges = applied
            appliedFindVisibleRange = visible
        }

        private func clearAppliedFindHighlights(in layoutManager: NSLayoutManager) {
            guard !appliedFindRanges.isEmpty || appliedFindVisibleRange != nil else { return }
            let cleared = appliedFindRanges
            appliedFindRanges.removeAll(keepingCapacity: true)
            appliedFindVisibleRange = nil
            let length = textView?.textStorage?.length ?? 0
            for range in cleared where NSMaxRange(range) <= length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            markdownPresentation?.restoreBackground(in: cleared)
            for range in delimiterHighlightRanges {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor.lacDelimiterMatchBackground, forCharacterRange: range
                )
            }
        }

        private func clearFindHighlights() {
            findHighlightMatches = []
            findMatchesChanged = false
            if let layoutManager = textView?.layoutManager { clearAppliedFindHighlights(in: layoutManager) }
        }

        private func cancelDelimiterMatch(
            clearHighlight: Bool,
            releaseSnapshot: Bool = false
        ) {
            delimiterMatchWorkItem?.cancel()
            delimiterMatchWorkItem = nil
            delimiterMatchOperation?.cancel()
            delimiterMatchOperation = nil
            delimiterMatchQueue.cancelAllOperations()
            document.taskCoordinator.cancel(.delimiterMatch)
            if clearHighlight { clearDelimiterHighlight() }
            if releaseSnapshot {
                delimiterSnapshot = nil
                delimiterSnapshotRevision = nil
            }
        }

        func scheduleHighlight(delay: TimeInterval = 0.12) {
            guard isActive, document.isSyntaxHighlightingEnabled else {
                cancelPendingHighlight()
                if clearsDisabledSyntaxOnScroll {
                    clearSyntaxAttributesInVisibleRange()
                }
                return
            }
            highlightWorkItem?.cancel()
            highlightGeneration &+= 1
            let generation = highlightGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      generation == highlightGeneration else { return }
                beginHighlight(generation: generation)
            }
            highlightWorkItem = work
            if delay <= 0 {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        private func beginHighlight(generation: UInt) {
            guard isActive,
                  generation == highlightGeneration,
                  let textView,
                  !textView.hasMarkedText(),
                  let storage = textView.textStorage else { return }
            highlightWorkItem = nil

            flushModelText(reconcileDirtyState: false)
            let revision = contentRevision
            let language = currentLanguage
            let fontSize = currentFontSize
            let fullRange = NSRange(location: 0, length: storage.length)
            let requiresReset = highlightedLanguage != language
                || highlightedFontSize != fontSize
            if requiresReset {
                clearSyntaxAttributesInVisibleRange()
                highlightedRanges.removeAll(keepingCapacity: true)
                pendingHighlightRanges.clear()
            }
            let dirtyRange = pendingHighlightRanges.unionRange
            let requestedRange = visibleHighlightRange() ?? dirtyRange ?? fullRange
            let targetRange = expandedHighlightRange(
                requestedRange,
                in: storage.length,
                language: language
            )
            if highlightedRanges.contains(where: {
                targetRange.location >= $0.location
                    && NSMaxRange(targetRange) <= NSMaxRange($0)
            }) && !pendingHighlightRanges.ranges.contains(where: {
                NSIntersectionRange($0, targetRange).length > 0
            }) {
                return
            }

            let synchronizedSnapshot = document.text
            let snapshot = (synchronizedSnapshot as NSString).length == storage.length
                ? synchronizedSnapshot
                : storage.string
            let edit = lastSyntaxEdit
            let documentID = document.id
            highlightOperation?.cancel()
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let operation, !operation.isCancelled else { return }
                let tokenizeSignpostID = OSSignpostID(log: editorPerformanceLog)
                os_signpost(
                    .begin,
                    log: editorPerformanceLog,
                    name: "SyntaxTokenize",
                    signpostID: tokenizeSignpostID
                )
                let tokens = SyntaxHighlighter.tokens(
                    in: snapshot,
                    language: language,
                    range: targetRange,
                    context: self?.syntaxHighlightContext,
                    revision: revision,
                    documentID: documentID,
                    edit: edit,
                    isCancelled: { operation.isCancelled }
                )
                os_signpost(
                    .end,
                    log: editorPerformanceLog,
                    name: "SyntaxTokenize",
                    signpostID: tokenizeSignpostID
                )
                guard !operation.isCancelled else { return }
                let changedRanges = SyntaxParserRegistry.changedRanges(
                    documentID: documentID, revision: revision, language: language
                )
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let operation, !operation.isCancelled else { return }
                    self?.applyHighlight(
                        tokens: tokens,
                        changedRanges: changedRanges,
                        range: targetRange,
                        revision: revision,
                        language: language,
                        fontSize: fontSize,
                        generation: generation
                    )
                }
            }
            highlightOperation = operation
            highlightQueue.addOperation(operation)
        }

        private func applyHighlight(
            tokens: [SyntaxHighlighter.Token],
            changedRanges: [NSRange]?,
            range: NSRange,
            revision: UInt,
            language: EditorLanguage,
            fontSize: CGFloat,
            generation: UInt
        ) {
            guard isActive,
                  generation == highlightGeneration,
                  revision == contentRevision,
                  language == currentLanguage,
                  fontSize == currentFontSize,
                  let textView,
                  !textView.hasMarkedText(),
                  let storage = textView.textStorage,
                  NSMaxRange(range) <= storage.length else { return }
            if appliedTreeChangeRevision != revision, let changedRanges {
                for changed in changedRanges {
                    let bounded = NSIntersectionRange(changed, NSRange(location: 0, length: storage.length))
                    guard bounded.length > 0 else { continue }
                    pendingHighlightRanges.invalidate(bounded)
                    highlightedRanges.removeAll { NSIntersectionRange($0, bounded).length > 0 }
                }
                appliedTreeChangeRevision = revision
            }
            let applySignpostID = OSSignpostID(log: editorPerformanceLog)
            os_signpost(
                .begin,
                log: editorPerformanceLog,
                name: "SyntaxApply",
                signpostID: applySignpostID
            )
            SyntaxHighlighter.apply(
                tokens: tokens,
                to: textView.layoutManager,
                range: range
            )
            markdownPresentation?.reapplyCodeColors(in: range)
            markdownPresentation?.reapplyLinkColors(in: range)
            os_signpost(
                .end,
                log: editorPerformanceLog,
                name: "SyntaxApply",
                signpostID: applySignpostID
            )
            highlightedRevision = revision
            highlightedLanguage = language
            highlightedFontSize = fontSize
            recordHighlightedRange(range)
            if revision == contentRevision {
                pendingHighlightRanges.remove(range)
            }
            highlightOperation = nil
            refreshRuler()
        }

        private func translateHighlightedRanges(after editedRange: NSRange) {
            guard !highlightedRanges.isEmpty else { return }
            var translated: [NSRange] = []
            translated.reserveCapacity(highlightedRanges.count)
            for range in highlightedRanges {
                if range.upperBound <= editedRange.location {
                    translated.append(range)
                } else if range.location < editedRange.location {
                    translated.append(NSRange(
                        location: range.location,
                        length: editedRange.location - range.location
                    ))
                }
                // An edit can change syntax throughout the following text.
            }
            highlightedRanges = translated
        }

        private func expandedHighlightRange(
            _ requested: NSRange,
            in textLength: Int,
            language: EditorLanguage
        ) -> NSRange {
            guard textLength > 0 else { return NSRange(location: 0, length: 0) }
            let bounded = NSIntersectionRange(
                requested,
                NSRange(location: 0, length: textLength)
            )
            guard let text = textView?.string as NSString? else { return bounded }
            let seed = bounded.length > 0
                ? bounded
                : NSRange(
                    location: min(max(0, requested.location), textLength - 1),
                    length: 1
                )
            let lineRange = text.lineRange(for: seed)
            let padding = language == .markdown ? 256 : 64 * 1_024
            let start = max(0, lineRange.location - padding)
            let end = min(textLength, NSMaxRange(lineRange) + padding)
            return NSRange(location: start, length: max(0, end - start))
        }

        private func recordHighlightedRange(_ range: NSRange) {
            var merged = range
            var retained: [NSRange] = []
            retained.reserveCapacity(highlightedRanges.count + 1)
            for candidate in highlightedRanges {
                if NSMaxRange(candidate) < merged.location
                    || NSMaxRange(merged) < candidate.location {
                    retained.append(candidate)
                } else {
                    let start = min(candidate.location, merged.location)
                    let end = max(NSMaxRange(candidate), NSMaxRange(merged))
                    merged = NSRange(location: start, length: end - start)
                }
            }
            retained.append(merged)
            highlightedRanges = retained.sorted { $0.location < $1.location }
        }

        private func cancelPendingHighlight() {
            highlightWorkItem?.cancel()
            highlightWorkItem = nil
            highlightOperation?.cancel()
            highlightOperation = nil
            highlightGeneration &+= 1
        }

        private func clearSyntaxAttributesInVisibleRange() {
            guard let textView, !textView.hasMarkedText(), let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage,
                  storage.length > 0 else { return }
            let range = storage.length > 500_000
                ? visibleHighlightRange() ?? NSRange(location: 0, length: 0)
                : NSRange(location: 0, length: storage.length)
            guard range.length > 0 else { return }
            SyntaxHighlighter.apply(
                tokens: [],
                to: layoutManager,
                range: range
            )
            markdownPresentation?.reapplyCodeColors(in: range)
            markdownPresentation?.reapplyLinkColors(in: range)
        }

        private func updateCursor() {
            guard let textView,
                  let text = textView.textStorage?.mutableString else { return }
            let selection = textView.selectedRange()
            document.selectionRange = markdownImageProjectionEnabled
                ? markdownImageProjection.sourceRange(for: selection, in: text as String)
                : selection
            let location = min(selection.location, text.length)
            let position = lineIndex.position(
                at: location,
                in: text
            )
            document.cursorLine = position.line
            document.cursorColumn = position.column
        }

        private func combinedEdit(
            from original: String,
            to replacement: String
        ) -> (range: NSRange, replacement: String)? {
            let oldText = original as NSString
            let newText = replacement as NSString
            guard !oldText.isEqual(to: replacement) else { return nil }

            let sharedLimit = min(oldText.length, newText.length)
            var prefixLength = 0
            while prefixLength < sharedLimit,
                  oldText.character(at: prefixLength) == newText.character(at: prefixLength) {
                prefixLength += 1
            }

            var suffixLength = 0
            while suffixLength < oldText.length - prefixLength,
                  suffixLength < newText.length - prefixLength,
                  oldText.character(at: oldText.length - suffixLength - 1)
                    == newText.character(at: newText.length - suffixLength - 1) {
                suffixLength += 1
            }

            let oldRange = NSRange(
                location: prefixLength,
                length: oldText.length - prefixLength - suffixLength
            )
            let newRange = NSRange(
                location: prefixLength,
                length: newText.length - prefixLength - suffixLength
            )
            return (oldRange, newText.substring(with: newRange))
        }

        private func refreshRuler() {
            guard textView != nil else { return }
            scheduleRulerRefresh(ensureLayout: true)
        }

        private func refreshRulerForViewportChange() {
            rulerRefreshWorkItem?.cancel()
            rulerRefreshWorkItem = nil
            rulerRefreshNeedsLayout = false
            ruler?.requestRedraw()
        }

        private func scheduleRulerRefresh(ensureLayout: Bool) {
            rulerRefreshNeedsLayout = rulerRefreshNeedsLayout || ensureLayout
            guard rulerRefreshWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                rulerRefreshWorkItem = nil
                if rulerRefreshNeedsLayout {
                    rulerRefreshNeedsLayout = false
                    ensureVisibleLayout()
                }
                invalidateEntireRuler()
            }
            rulerRefreshWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func invalidateEntireRuler(
            displayImmediately: Bool = false,
            invalidateLineMap: Bool = true
        ) {
            guard let ruler else { return }
            if ruler.updateThickness(lineCount: lineNumber(at: textView?.textStorage?.length ?? 0)) {
                updateLayout(wordWrap: wordWrap, force: true)
            }
            ruler.requestRedraw(invalidateLineMap: invalidateLineMap)
            if displayImmediately {
                ruler.displaySelectionImmediately()
            }
        }

        func resetLineIndex(with text: String) {
            lineIndex.reset(with: text)
        }

        func resetSyntaxHighlightContext() {
            syntaxHighlightContext.reset()
            highlightedRevision = nil
            appliedTreeChangeRevision = nil
            highlightedLanguage = nil
            highlightedFontSize = nil
            highlightedRanges.removeAll(keepingCapacity: true)
            pendingHighlightRanges.clear()
            delimiterMatchingContext.reset()
            delimiterSnapshot = nil
            delimiterSnapshotRevision = nil
            cancelDelimiterMatch(clearHighlight: true)
        }

        func lineNumber(at location: Int) -> Int {
            lineIndex.lineNumber(at: location)
        }

        private func ensureVisibleLayout() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }
            let visibleRect = textView.visibleRect.offsetBy(
                dx: -textView.textContainerOrigin.x,
                dy: -textView.textContainerOrigin.y
            )
            let layoutSignpostID = OSSignpostID(log: editorPerformanceLog)
            os_signpost(
                .begin,
                log: editorPerformanceLog,
                name: "TextKitVisibleLayout",
                signpostID: layoutSignpostID
            )
            layoutManager.ensureLayout(
                forBoundingRect: visibleRect,
                in: textContainer
            )
            os_signpost(
                .end,
                log: editorPerformanceLog,
                name: "TextKitVisibleLayout",
                signpostID: layoutSignpostID
            )
        }

        private func visibleHighlightRange() -> NSRange? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let visibleRect = textView.visibleRect.offsetBy(
                dx: -textView.textContainerOrigin.x,
                dy: -textView.textContainerOrigin.y
            )
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: visibleRect,
                in: textContainer
            )
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            let textLength = textView.textStorage?.length ?? 0
            let tileSize = 64 * 1_024
            let contextPadding = 256
            let tileStart = (characterRange.location / tileSize) * tileSize
            let visibleEnd = max(characterRange.location + 1, NSMaxRange(characterRange))
            let tileEnd = min(
                textLength,
                ((visibleEnd + tileSize - 1) / tileSize) * tileSize
            )
            let start = max(0, tileStart - contextPadding)
            let end = min(textLength, tileEnd + contextPadding)
            return NSRange(location: start, length: max(0, end - start))
        }

        private func toggleFold() {
            guard document.isFoldingEnabled,
                  let textView, textView.window?.firstResponder === textView,
                  !textView.hasMarkedText(),
                  let foldLayoutManager else { return }
            cancelFoldTask()
            if foldLayoutManager.foldedRange != nil {
                clearFold()
                return
            }
            let snapshot = textView.string
            let selection = textView.selectedRange()
            pendingFoldSelection = selection
            let revision = contentRevision
            let language = document.language
            let targetDocument = document
            let coordinator = targetDocument.taskCoordinator
            let generation = coordinator.begin(.folding)
            let task = Task.detached(priority: .userInitiated) { [weak self, weak targetDocument] in
                let range = FoldService.foldableRange(
                    in: snapshot, at: selection.location, language: language,
                    isCancelled: { Task.isCancelled }
                )
                guard !Task.isCancelled, coordinator.isCurrent(generation, for: .folding) else { return }
                await MainActor.run { [weak self, weak targetDocument] in
                    guard !Task.isCancelled, let self, let targetDocument,
                          self.document === targetDocument, self.isActive,
                          coordinator.isCurrent(generation, for: .folding),
                          self.contentRevision == revision, targetDocument.language == language,
                          targetDocument.isFoldingEnabled, let textView = self.textView,
                          textView.window?.firstResponder === textView,
                          !textView.hasMarkedText(), textView.selectedRange() == selection,
                          let layout = self.foldLayoutManager, layout.foldedRange == nil else { return }
                    coordinator.finish(.folding, generation: generation)
                    self.pendingFoldSelection = nil
                    if let range {
                        layout.setFoldedRange(range)
                        self.refreshFoldLayout()
                    }
                }
            }
            coordinator.attachTask(task, kind: .folding, generation: generation)
        }

        func clearFold() {
            cancelFoldTask()
            guard foldLayoutManager?.foldedRange != nil else { return }
            foldLayoutManager?.setFoldedRange(nil)
            refreshFoldLayout()
        }

        func cancelFoldTask() {
            pendingFoldSelection = nil
            document.taskCoordinator.cancel(.folding)
        }

        private func cancelFoldIfSelectionChanged() {
            guard let pendingFoldSelection, textView?.selectedRange() != pendingFoldSelection else { return }
            cancelFoldTask()
        }

        private func clearFoldIfNeeded(toReveal range: NSRange) {
            guard let foldedRange = foldLayoutManager?.foldedRange,
                  NSIntersectionRange(foldedRange, range).length > 0 ||
                    (range.length == 0 && NSLocationInRange(range.location, foldedRange)) else { return }
            clearFold()
        }

        private func refreshFoldLayout() {
            guard let textView else { return }
            if let textContainer = textView.textContainer {
                foldLayoutManager?.ensureLayout(for: textContainer)
            }
            textView.needsLayout = true
            textView.needsDisplay = true
            markdownPresentation?.viewportChanged()
            markdownPresentation?.foldGeometryChanged()
            ruler?.invalidateHashMarks()
            ruler?.needsDisplay = true
        }
    }
}


extension NSColor {
    static let lacFindMatchBackground = NSColor(name: nil) { appearance in
        let alpha: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.32 : 0.45
        return NSColor.systemYellow.withAlphaComponent(alpha)
    }
}
