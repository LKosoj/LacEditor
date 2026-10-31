import AppKit
import os
import SwiftUI

let editorPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "EditorPerformance"
)

struct EditorTextView: NSViewRepresentable {
    static let minimumHorizontalInset: CGFloat = 16

    @Environment(\.isEnabled) private var isEnabled
    @ObservedObject var document: EditorDocument

    private var isEditorEditable: Bool { isEnabled && !document.isReadingMode }
    let sessionStore: EditorSessionStore
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let indentationStyle: IndentationStyle
    let tabWidth: Int
    let wordWrap: Bool
    let showsLineNumbers: Bool
    let topInset: CGFloat
    let isActive: Bool
    let requestTextTransformation: (TextTransformationOperation) -> Void
    var isOutlineVisible = false
    var spellingEnabled = false
    var grammarEnabled = false
    var aiPreferences: AppPreferences? = nil
    var isFocusMode = false
    var focusScope: FocusScope = .paragraph
    var isTypewriterMode = false
    var textFontFamily: String? = nil
    var codeFontFamily: String? = nil
    var remoteImageTransferEnabled = false
    var maximumTextWidth: Double? = nil
    var colorOverrides = MarkdownColorOverrides()
    var markdownTOCMaxLevel = 6
    var viewMagnification: CGFloat = 1
    var magnificationDidChange: ((CGFloat) -> Void)? = nil
    var requestAIImageEdit: ((AIImageEditRequest) -> Void)? = nil
    var requestAIImageDescription: ((AIImageEditRequest) -> Void)? = nil
    var wikiResolver: MarkdownWikiLinkResolver? = nil
    var requestWikiCatalog: (() -> Void)? = nil
    var wikiSource: (() -> MarkdownWikiLinkSource)? = nil

    static func applyWritingChecks(to textView: NSTextView, spellingEnabled: Bool, grammarEnabled: Bool) {
        guard !textView.hasMarkedText() else { return }
        let containsDataImage = (textView.string as NSString).range(
            of: "data:image/",
            options: [.caseInsensitive]
        ).location != NSNotFound
        let effectiveSpelling = spellingEnabled && !containsDataImage
        let effectiveGrammar = grammarEnabled && !containsDataImage
        if textView.isContinuousSpellCheckingEnabled != effectiveSpelling {
            textView.isContinuousSpellCheckingEnabled = effectiveSpelling
        }
        if textView.isGrammarCheckingEnabled != effectiveGrammar {
            textView.isGrammarCheckingEnabled = effectiveGrammar
        }
        if textView.isAutomaticSpellingCorrectionEnabled {
            textView.isAutomaticSpellingCorrectionEnabled = false
        }
    }

    func makeCoordinator() -> Coordinator {
        sessionStore.coordinator(for: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.updateMathOptions(.init(physics: aiPreferences?.mathPhysicsEnabled ?? true,
                                                    numbering: aiPreferences?.mathNumbering ?? .none))
        context.coordinator.requestAIImageEdit = requestAIImageEdit
        context.coordinator.requestAIImageDescription = requestAIImageDescription
        if let cachedView = sessionStore.cachedView(for: document.id) {
            context.coordinator.configureWritingChecks(spellingEnabled: spellingEnabled, grammarEnabled: grammarEnabled)
            context.coordinator.configureAIAssistance(preferences: aiPreferences)
            if let textView = cachedView.documentView as? LacTextView {
                textView.autoPairBracketsEnabled = aiPreferences?.autoPairBracketsEnabled ?? false
                textView.autoPairMarkdownEnabled = aiPreferences?.autoPairMarkdownEnabled ?? false
                textView.isEditable = isEditorEditable
                Self.applyWritingChecks(to: textView, spellingEnabled: spellingEnabled, grammarEnabled: grammarEnabled)
            }
            os_signpost(
                .event,
                log: editorPerformanceLog,
                name: "EditorSessionReattach"
            )
            return cachedView
        }
        let createSignpostID = OSSignpostID(log: editorPerformanceLog)
        os_signpost(
            .begin,
            log: editorPerformanceLog,
            name: "EditorSessionCreate",
            signpostID: createSignpostID
        )
        defer {
            os_signpost(
                .end,
                log: editorPerformanceLog,
                name: "EditorSessionCreate",
                signpostID: createSignpostID
            )
        }
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .lacEditorBackground

        let textStorage = NSTextStorage()
        let layoutManager = FoldLayoutManager()
        let editorFont = AppPreferences.textFont(family: textFontFamily, size: fontSize)
        layoutManager.textFont = editorFont
        layoutManager.markdownCodeFont = AppPreferences.availableFont(family: codeFontFamily, size: fontSize)
        layoutManager.editorLineSpacing = lineSpacing
        EditorLayoutPolicy.configure(
            layoutManager,
            textLength: (document.text as NSString).length
        )
        textStorage.addLayoutManager(layoutManager)
        let initialSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: wordWrap ? initialSize.width : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = wordWrap
        layoutManager.addTextContainer(textContainer)

        let textView = LacTextView(
            frame: NSRect(origin: .zero, size: initialSize),
            textContainer: textContainer
        )
        textView.remoteImageTransferEnabled = remoteImageTransferEnabled
        textView.isEditable = isEditorEditable
        textView.autoPairBracketsEnabled = aiPreferences?.autoPairBracketsEnabled ?? false
        textView.autoPairMarkdownEnabled = aiPreferences?.autoPairMarkdownEnabled ?? false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: Self.minimumHorizontalInset, height: topInset)
        // Leave a one-pixel safety edge so AppKit's insertion caret is not
        // clipped when it sits at the first column.
        textContainer.lineFragmentPadding = 1
        textView.backgroundColor = NSColor.lacEditorBackground
        textView.drawsBackground = true
        // Establish the final font and paragraph metrics before assigning the
        // document. Otherwise an empty document gets an extra-line fragment
        // laid out with AppKit defaults and jumps when its first glyph arrives.
        textView.font = editorFont
        textView.textColor = .labelColor
        textView.editorLineSpacing = lineSpacing
        textView.indentationStyle = indentationStyle
        textView.tabWidth = tabWidth
        textView.configureTabStops()
        textView.string = document.text
        Self.applyWritingChecks(to: textView, spellingEnabled: spellingEnabled, grammarEnabled: grammarEnabled)
        let textLength = (document.text as NSString).length
        let selectionLocation = min(document.selectionRange.location, textLength)
        textView.setSelectedRange(NSRange(
            location: selectionLocation,
            length: min(
                document.selectionRange.length,
                textLength - selectionLocation
            )
        ))
        textView.delegate = context.coordinator
        if let style = textView.defaultParagraphStyle,
           let storage = textView.textStorage,
           storage.length > 0 {
            storage.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: 0, length: storage.length)
            )
        }
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wordWrap
        textView.autoresizingMask = NSView.AutoresizingMask.width
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = showsLineNumbers
        scrollView.rulersVisible = showsLineNumbers
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.textView = textView
        context.coordinator.configureWritingChecks(spellingEnabled: spellingEnabled, grammarEnabled: grammarEnabled)
        context.coordinator.configureAIAssistance(preferences: aiPreferences)
        context.coordinator.foldLayoutManager = layoutManager
        context.coordinator.ruler = ruler
        _ = ruler.updateThickness(lineCount: context.coordinator.lineNumber(at: textView.textStorage?.length ?? 0))
        context.coordinator.attachLiveTextProvider()
        textView.selectionTrackingHandler = { [weak coordinator = context.coordinator] in
            coordinator?.selectionDidChangeDuringTracking()
        }
        textView.textTransformationHandler = requestTextTransformation
        textView.listIndentationHandler = { [weak coordinator = context.coordinator] outdent in
            coordinator?.indentCurrentListItem(outdent: outdent) ?? false
        }
        ruler.lineNumberProvider = { [weak coordinator = context.coordinator] location in
            coordinator?.lineNumber(at: location) ?? 1
        }
        context.coordinator.currentFontSize = fontSize
        context.coordinator.currentTabWidth = tabWidth
        context.coordinator.maximumTextWidth = maximumTextWidth.map { CGFloat($0) }
        context.coordinator.currentLanguage = document.language
        context.coordinator.requestWikiCatalog = requestWikiCatalog
        context.coordinator.wikiSource = wikiSource
        context.coordinator.updateWikiResolver(wikiResolver)
        context.coordinator.isMarkdownOutlineVisible = isOutlineVisible
        context.coordinator.updatePerformanceFeatures()
        context.coordinator.lastSynchronizedRevision = document.textRevision
        context.coordinator.installObservers(scrollView: scrollView)
        context.coordinator.updateLineNumbersVisibility(showsLineNumbers)
        context.coordinator.updateWritingModes(focus: isFocusMode, focusScope: focusScope, typewriter: isTypewriterMode)
        context.coordinator.updateTopInset(topInset)
        context.coordinator.foldLayoutManager?.markdownTOCMaxLevel = markdownTOCMaxLevel
        context.coordinator.foldLayoutManager?.markdownSmallCapsLevels = aiPreferences?.markdownSmallCapsLevels ?? []
        context.coordinator.foldLayoutManager?.markdownParagraphSpacing = aiPreferences?.markdownParagraphSpacing.map { CGFloat($0) }
        context.coordinator.foldLayoutManager?.markdownTextAlignment = aiPreferences?.markdownTextAlignment?.appKitAlignment
        context.coordinator.foldLayoutManager?.markdownRightToLeft = aiPreferences?.markdownRightToLeft ?? false
        context.coordinator.foldLayoutManager?.markdownCenteredHeadingLevels = aiPreferences?.markdownCenteredHeadingLevels ?? []
        context.coordinator.updateStrikeCompletedTasks(aiPreferences?.markdownStrikeCompletedTasks ?? false)
        context.coordinator.updateHeadingNumbering(document.language == .markdown && (aiPreferences?.markdownNumberHeadings ?? false))
        context.coordinator.updateUppercaseHeadingLevels(document.language == .markdown ? (aiPreferences?.markdownUppercaseHeadingLevels ?? []) : [])
        context.coordinator.updateListStyles(aiPreferences?.markdownListStyles ?? .init())
        if context.coordinator.foldLayoutManager?.markdownListStyles != context.coordinator.listStyles {
            context.coordinator.foldLayoutManager?.markdownListStyles = context.coordinator.listStyles
        }
        context.coordinator.updateMathPairContextEnabled(document.language == .markdown && (aiPreferences?.autoPairMarkdownEnabled ?? false))
        context.coordinator.updateMarkdownVerticalWriting(document.language == .markdown && document.isMarkdownFormatted && (aiPreferences?.markdownVerticalWriting ?? false))
        context.coordinator.updateMarkdownColors(colorOverrides)
        context.coordinator.updateLayout(wordWrap: wordWrap, force: true)
        context.coordinator.updateActivity(isActive)
        context.coordinator.updateMarkdownPresentation()
        context.coordinator.synchronizeSelectionState()
        context.coordinator.scheduleHighlight(delay: 0)
        context.coordinator.restoreViewportState()
        context.coordinator.applyPendingContextSelection()
        sessionStore.store(
            scrollView,
            coordinator: context.coordinator,
            for: document.id
        )
        return scrollView
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.flushModelText(reconcileDirtyState: true)
        coordinator.updateActivity(false)
        coordinator.textView?.paragraphStylesChangedHandler = nil
        coordinator.textView?.diagramMenuHandler = nil
        coordinator.requestAIImageEdit = nil
        coordinator.requestAIImageDescription = nil
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.updateMathOptions(.init(physics: aiPreferences?.mathPhysicsEnabled ?? true,
                                                    numbering: aiPreferences?.mathNumbering ?? .none))
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.requestAIImageEdit = requestAIImageEdit
        context.coordinator.requestAIImageDescription = requestAIImageDescription
        context.coordinator.magnificationDidChange = magnificationDidChange
        context.coordinator.updateViewMagnification(viewMagnification)
        textView.remoteImageTransferEnabled = remoteImageTransferEnabled
        context.coordinator.configureWritingChecks(spellingEnabled: spellingEnabled, grammarEnabled: grammarEnabled)
        context.coordinator.configureAIAssistance(preferences: aiPreferences)
        // Набранное в ячейке таблицы фиксируется через shouldChangeText родителя:
        // закрыть ячейку надо до того, как правка станет запрещённой.
        if document.isReadingMode, textView.isEditable {
            context.coordinator.finishTableCell()
        }
        textView.isEditable = isEditorEditable
        textView.autoPairBracketsEnabled = aiPreferences?.autoPairBracketsEnabled ?? false
        textView.autoPairMarkdownEnabled = aiPreferences?.autoPairMarkdownEnabled ?? false
        Self.applyWritingChecks(to: textView, spellingEnabled: spellingEnabled, grammarEnabled: grammarEnabled)
        textView.textTransformationHandler = requestTextTransformation
        let documentChanged = context.coordinator.document.id != document.id
        let remoteImageConsentChanged = context.coordinator.remoteImagesConsentSnapshot != document.allowsRemoteImages
        let requestedFont = AppPreferences.textFont(family: textFontFamily, size: fontSize)
        let fontChanged = context.coordinator.foldLayoutManager?.textFont != requestedFont
        let requestedCodeFont = AppPreferences.availableFont(family: codeFontFamily, size: fontSize)
        let codeFontChanged = context.coordinator.foldLayoutManager?.markdownCodeFont != requestedCodeFont
        let requestedMaximumWidth = maximumTextWidth.map { CGFloat($0) }
        let widthChanged = context.coordinator.maximumTextWidth != requestedMaximumWidth
        let tabWidthChanged = context.coordinator.currentTabWidth != tabWidth
        let lineSpacingChanged = context.coordinator.foldLayoutManager?
            .editorLineSpacing != lineSpacing
        let languageChanged = context.coordinator.currentLanguage != document.language
        if documentChanged || languageChanged || !document.isMarkdownFormatted || !isEditorEditable ||
            context.coordinator.lastSynchronizedRevision != document.textRevision {
            context.coordinator.finishTableCell()
        }
        if documentChanged || languageChanged {
            context.coordinator.cancelFoldTask()
            context.coordinator.resetSyntaxHighlightContext()
        }
        context.coordinator.document = document
        if remoteImageConsentChanged { context.coordinator.remoteImageConsentChanged() }
        context.coordinator.updateRemoteImagesConsentSnapshot(document.allowsRemoteImages)
        context.coordinator.currentLanguage = document.language
        context.coordinator.isMarkdownOutlineVisible = isOutlineVisible
        textView.indentationStyle = indentationStyle
        let colorsChanged = context.coordinator.foldLayoutManager?.markdownColors != colorOverrides
        let requestedColors = colorOverrides
        let tocLevelChanged = context.coordinator.foldLayoutManager?.markdownTOCMaxLevel != markdownTOCMaxLevel
        let requestedTOCLevel = markdownTOCMaxLevel
        let requestedSmallCaps = aiPreferences?.markdownSmallCapsLevels ?? []
        let smallCapsChanged = context.coordinator.foldLayoutManager?.markdownSmallCapsLevels != requestedSmallCaps
        let requestedParagraphSpacing = aiPreferences?.markdownParagraphSpacing.map { CGFloat($0) }
        let paragraphSpacingChanged = context.coordinator.foldLayoutManager?.markdownParagraphSpacing != requestedParagraphSpacing
        let requestedAlignment = aiPreferences?.markdownTextAlignment?.appKitAlignment
        let alignmentChanged = context.coordinator.foldLayoutManager?.markdownTextAlignment != requestedAlignment
        let requestedRightToLeft = aiPreferences?.markdownRightToLeft ?? false
        let rightToLeftChanged = context.coordinator.foldLayoutManager?.markdownRightToLeft != requestedRightToLeft
        let requestedCenteredHeadings = aiPreferences?.markdownCenteredHeadingLevels ?? []
        let centeredHeadingsChanged = context.coordinator.foldLayoutManager?.markdownCenteredHeadingLevels != requestedCenteredHeadings
        let requestedStrikeTasks = aiPreferences?.markdownStrikeCompletedTasks ?? false
        let strikeTasksChanged = context.coordinator.strikeCompletedTasks != requestedStrikeTasks
        let requestedHeadingNumbering = document.language == .markdown && (aiPreferences?.markdownNumberHeadings ?? false)
        let headingNumberingChanged = context.coordinator.headingNumbering != requestedHeadingNumbering
        let requestedUppercaseHeadings = document.language == .markdown ? (aiPreferences?.markdownUppercaseHeadingLevels ?? []) : []
        let uppercaseHeadingsChanged = context.coordinator.uppercaseHeadingLevels != requestedUppercaseHeadings
        let requestedListStyles = aiPreferences?.markdownListStyles ?? .init()
        let listStylesChanged = context.coordinator.listStyles != requestedListStyles
        let requestedMathPair = document.language == .markdown && (aiPreferences?.autoPairMarkdownEnabled ?? false)
        let mathPairChanged = context.coordinator.mathPairContextEnabled != requestedMathPair
        let requestedVertical = document.language == .markdown && document.isMarkdownFormatted && (aiPreferences?.markdownVerticalWriting ?? false)
        let verticalChanged = context.coordinator.markdownVerticalWriting != requestedVertical
        let requestedLigatures = aiPreferences?.editorLigatures
        let ligaturesChanged = context.coordinator.editorLigatures != requestedLigatures
        let smartEnabled = document.language == .markdown && document.isMarkdownFormatted
        let smartChanged = textView.isAutomaticQuoteSubstitutionEnabled != (smartEnabled && (aiPreferences?.smartQuotesEnabled ?? false))
            || textView.isAutomaticDashSubstitutionEnabled != (smartEnabled && (aiPreferences?.smartDashesEnabled ?? false))
            || textView.isAutomaticTextReplacementEnabled != (smartEnabled && (aiPreferences?.systemTextReplacementEnabled ?? false))
        let shouldRefreshTextMetrics = colorsChanged
            || ligaturesChanged
            || smartChanged
            || tocLevelChanged
            || smallCapsChanged
            || paragraphSpacingChanged
            || alignmentChanged
            || rightToLeftChanged
            || centeredHeadingsChanged
            || strikeTasksChanged
            || headingNumberingChanged
            || uppercaseHeadingsChanged
            || listStylesChanged
            || mathPairChanged
            || verticalChanged
            || widthChanged
            || lineSpacingChanged
            || fontChanged
            || codeFontChanged
            || tabWidthChanged
        if shouldRefreshTextMetrics {
            let requestedFontSize = fontSize
            let requestedLineSpacing = lineSpacing
            let requestedTabWidth = tabWidth
            let requestedWordWrap = wordWrap
            context.coordinator.applyOrDeferTableTextMetrics { [weak textView, weak coordinator = context.coordinator] in
                guard let textView, let coordinator else { return }
                textView.applyOrDeferTextMetrics { [weak textView, weak coordinator] in
                    guard let textView, let coordinator else { return }
                    let fontChanged = coordinator.foldLayoutManager?.textFont != requestedFont
                    let codeFontChanged = coordinator.foldLayoutManager?.markdownCodeFont != requestedCodeFont
                    let lineSpacingChanged = coordinator.foldLayoutManager?.editorLineSpacing != requestedLineSpacing
                    let tocLevelChanged = coordinator.foldLayoutManager?.markdownTOCMaxLevel != requestedTOCLevel
                    let smallCapsChanged = coordinator.foldLayoutManager?.markdownSmallCapsLevels != requestedSmallCaps
                    let paragraphSpacingChanged = coordinator.foldLayoutManager?.markdownParagraphSpacing != requestedParagraphSpacing
                    let alignmentChanged = coordinator.foldLayoutManager?.markdownTextAlignment != requestedAlignment
                    let rightToLeftChanged = coordinator.foldLayoutManager?.markdownRightToLeft != requestedRightToLeft
                    let centeredHeadingsChanged = coordinator.foldLayoutManager?.markdownCenteredHeadingLevels != requestedCenteredHeadings
                    coordinator.currentFontSize = requestedFontSize
                    coordinator.currentTabWidth = requestedTabWidth
                    coordinator.maximumTextWidth = requestedMaximumWidth
                    coordinator.updateMarkdownColors(requestedColors)
                    coordinator.updateEditorLigatures(requestedLigatures)
                    coordinator.updateSmartSubstitutionSettings()
                    coordinator.foldLayoutManager?.markdownTOCMaxLevel = requestedTOCLevel
                    coordinator.foldLayoutManager?.markdownSmallCapsLevels = requestedSmallCaps
                    coordinator.foldLayoutManager?.markdownParagraphSpacing = requestedParagraphSpacing
                    coordinator.foldLayoutManager?.markdownTextAlignment = requestedAlignment
                    coordinator.foldLayoutManager?.markdownRightToLeft = requestedRightToLeft
                    coordinator.updateTableCellWritingDirection()
                    coordinator.foldLayoutManager?.markdownCenteredHeadingLevels = requestedCenteredHeadings
                    coordinator.updateStrikeCompletedTasks(requestedStrikeTasks)
                    coordinator.updateHeadingNumbering(requestedHeadingNumbering)
                    coordinator.updateUppercaseHeadingLevels(requestedUppercaseHeadings)
                    coordinator.updateListStyles(requestedListStyles)
                    coordinator.updateMathPairContextEnabled(requestedMathPair)
                    coordinator.updateMarkdownVerticalWriting(requestedVertical)
                    coordinator.foldLayoutManager?.textFont = requestedFont
                    coordinator.foldLayoutManager?.markdownCodeFont = requestedCodeFont
                    coordinator.foldLayoutManager?.editorLineSpacing = requestedLineSpacing
                    textView.editorLineSpacing = requestedLineSpacing
                    textView.tabWidth = requestedTabWidth
                    if fontChanged { textView.font = requestedFont }
                    if fontChanged { coordinator.updateTableCellFont(requestedFont) }
                    if fontChanged || lineSpacingChanged || tabWidthChanged {
                        textView.configureTabStops()
                        if textView.textStorage?.length ?? 0 > 0 { textView.scheduleParagraphStyleRefresh() }
                    }
                    coordinator.updateLayout(wordWrap: requestedWordWrap, force: lineSpacingChanged || widthChanged)
                    if fontChanged || codeFontChanged || tocLevelChanged || ligaturesChanged || smallCapsChanged || paragraphSpacingChanged || alignmentChanged || rightToLeftChanged || centeredHeadingsChanged {
                        coordinator.markdownMetricsChanged()
                        if fontChanged { coordinator.scheduleHighlight(delay: 0) }
                    }
                }
            }
        } else {
            context.coordinator.applyOrDeferTableTextMetrics(nil)
            textView.applyOrDeferTextMetrics(nil)
        }
        context.coordinator.updatePerformanceFeatures()
        context.coordinator.updateLineNumbersVisibility(showsLineNumbers)
        context.coordinator.updateWritingModes(focus: isFocusMode, focusScope: focusScope, typewriter: isTypewriterMode)
        context.coordinator.updateTopInset(topInset)
        context.coordinator.updateActivity(isActive)
        context.coordinator.updateMarkdownPresentation()

        // Marked text is owned by the input method. Replacing the string or its
        // attributes while it is composing cancels Chinese/Japanese/Korean input.
        guard !textView.hasMarkedText() else { return }

        let revisionChanged = context.coordinator.lastSynchronizedRevision
            != document.textRevision
        if documentChanged || revisionChanged {
            if revisionChanged, !documentChanged {
                context.coordinator.resetSyntaxHighlightContext()
            }
            context.coordinator.advanceContentRevision()
            context.coordinator.isApplyingExternalUpdate = true
            context.coordinator.clearFold()
            let requestedSelection = document.selectionRange
            let displayedText = context.coordinator.displayedText(for: document.text)
            textView.string = displayedText
            context.coordinator.resetLineIndex(with: displayedText)
            let displayedSelection = context.coordinator.displayedRange(for: requestedSelection, in: displayedText)
            let textLength = (displayedText as NSString).length
            let selectionLocation = min(displayedSelection.location, textLength)
            let selectionLength = min(
                displayedSelection.length,
                textLength - selectionLocation
            )
            textView.setSelectedRange(NSRange(
                location: selectionLocation,
                length: selectionLength
            ))
            context.coordinator.isApplyingExternalUpdate = false
            context.coordinator.lastSynchronizedRevision = document.textRevision
            context.coordinator.updateMarkdownPresentation()
        }

        context.coordinator.updateLayout(
            wordWrap: wordWrap,
            force: lineSpacingChanged
        )
        if documentChanged || revisionChanged || fontChanged || languageChanged {
            context.coordinator.scheduleHighlight(delay: 0)
        }
        if documentChanged || revisionChanged || languageChanged {
            context.coordinator.scheduleDelimiterMatch(delay: 0)
        }
        context.coordinator.applyPendingContextSelection()
    }

}

private extension MarkdownTextAlignment {
    var appKitAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        case .justify: return .justified
        }
    }
}
