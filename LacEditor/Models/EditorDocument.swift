import Foundation

enum DocumentPerformanceProfile: String, CaseIterable, Identifiable {
    case standard
    case large
    case extreme

    static let largeFileByteThreshold = 20 * 1_024 * 1_024
    static let extremeFileByteThreshold = 50 * 1_024 * 1_024
    static let largeFileLineThreshold = 250_000

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: L10n.tr("标准模式")
        case .large: L10n.tr("大文件模式")
        case .extreme: L10n.tr("超大文件保护模式")
        }
    }

    static func resolve(byteCount: Int, lineCount: Int = 0) -> Self {
        if byteCount > extremeFileByteThreshold { return .extreme }
        if byteCount > largeFileByteThreshold || lineCount > largeFileLineThreshold {
            return .large
        }
        return .standard
    }
}

struct DocumentFeatureOverrides: Equatable {
    var wordWrap: Bool?
    var preview: Bool?
    var syntaxHighlighting: Bool?
    var folding: Bool?
    var wordCount: Bool?
}

enum DocumentManagedFeature {
    case wordWrap
    case preview
    case syntaxHighlighting
    case folding
    case wordCount
}

enum DocumentIOState: Equatable {
    case idle
    case opening
    case saving
    case failed(String)

    var statusText: String? {
        switch self {
        case .idle: nil
        case .opening: L10n.tr("正在打开")
        case .saving: L10n.tr("正在保存")
        case let .failed(message): message
        }
    }
}

struct DocumentSaveResult: Sendable {
    let targetURL: URL
    let encoding: String.Encoding
    let snapshotRevision: UInt
    let fileRevisionSnapshot: FileRevisionSnapshot?
    let errorDescription: String?

    var succeeded: Bool { errorDescription == nil && fileRevisionSnapshot != nil }
}

final class DocumentTaskCoordinator: @unchecked Sendable {
    enum Kind: Hashable {
        case search
        case replace
        case json
        case preview
        case metrics
        case save
        case listNormalization
        case delimiterMatch
        case folding
        case textTransformation
        case markdownPresentation
        case aiWriting
        case aiCompletion
        case aiMetadata
        case aiDocumentTools
    }

    private let lock = NSLock()
    private var generations: [Kind: UInt] = [:]
    private var operations: [Kind: Operation] = [:]
    private var taskCancellers: [Kind: () -> Void] = [:]

    @discardableResult
    func begin(_ kind: Kind, operation: Operation? = nil) -> UInt {
        lock.lock()
        defer { lock.unlock() }
        operations[kind]?.cancel()
        taskCancellers[kind]?()
        taskCancellers[kind] = nil
        let generation = (generations[kind] ?? 0) &+ 1
        generations[kind] = generation
        operations[kind] = operation
        return generation
    }

    @discardableResult
    func beginTask(_ kind: Kind, cancel: @escaping () -> Void) -> UInt {
        lock.lock()
        defer { lock.unlock() }
        operations[kind]?.cancel()
        taskCancellers[kind]?()
        let generation = (generations[kind] ?? 0) &+ 1
        generations[kind] = generation
        operations[kind] = nil
        taskCancellers[kind] = cancel
        return generation
    }

    func attach(_ operation: Operation, kind: Kind, generation: UInt) {
        lock.lock()
        defer { lock.unlock() }
        guard generations[kind] == generation else {
            operation.cancel()
            return
        }
        operations[kind] = operation
    }

    func attachTask(_ task: Task<Void, Never>, kind: Kind, generation: UInt) {
        lock.lock()
        defer { lock.unlock() }
        guard generations[kind] == generation else {
            task.cancel()
            return
        }
        taskCancellers[kind] = { task.cancel() }
    }

    func isCurrent(_ generation: UInt, for kind: Kind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[kind] == generation && operations[kind]?.isCancelled != true
    }

    func finish(_ kind: Kind, generation: UInt) {
        lock.lock()
        defer { lock.unlock() }
        if generations[kind] == generation {
            operations[kind] = nil
            taskCancellers[kind] = nil
        }
    }

    func cancel(_ kind: Kind) {
        lock.lock()
        defer { lock.unlock() }
        operations[kind]?.cancel()
        taskCancellers[kind]?()
        operations[kind] = nil
        taskCancellers[kind] = nil
        generations[kind] = (generations[kind] ?? 0) &+ 1
    }

    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        operations.values.forEach { $0.cancel() }
        taskCancellers.values.forEach { $0() }
        operations.removeAll()
        taskCancellers.removeAll()
        for kind in generations.keys {
            generations[kind] = (generations[kind] ?? 0) &+ 1
        }
    }
}

final class EditorDocument: ObservableObject, Identifiable, @unchecked Sendable {
    let id: UUID
    @Published var text: String {
        didSet {
            if isMarkdownOutlineCurrent { isMarkdownOutlineCurrent = false }
            markdownReadableText = nil
            hasPendingLiveEdits = false
            pendingLiveTextIsEmpty = nil
            textRevision &+= 1
            textSnapshotCache = nil
            if !isTakingMetricsSnapshot { scheduleMetricsRefresh() }
        }
    }
    @Published var url: URL?
    @Published var language: EditorLanguage {
        didSet { if language != oldValue { markdownReadableText = nil; scheduleMetricsRefresh() } }
    }
    @Published private(set) var fileEncoding: String.Encoding
    @Published var isDirty: Bool
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var selectionRange = NSRange(location: 0, length: 0) {
        didSet { if selectionRange != oldValue && (selectionRange.length != 0 || oldValue.length != 0) { scheduleMetricsRefresh() } }
    }
    @Published var statusMessage: String?
    @Published var textCodecSuggestionTitle: String?
    @Published var markdownHeadings: [MarkdownHeading] = []
    @Published var isMarkdownOutlineCurrent = false
    @Published var isPreviewVisible: Bool
    @Published var isMarkdownFormatted = false
    @Published var performanceProfile: DocumentPerformanceProfile
    @Published var featureOverrides = DocumentFeatureOverrides()
    @Published var ioState: DocumentIOState = .idle
    @Published private(set) var statistics: DocumentStatistics?
    @Published private(set) var statisticsUnavailable = false
    private(set) var textRevision: UInt = 0
    private var textSnapshotCache: DocumentTextSnapshot?
    var scrollPositionRatio: CGFloat = 0
    var foldedRange: NSRange?
    private(set) var fileIdentity: DocumentFileIdentity?
    private(set) var fileRevisionSnapshot: FileRevisionSnapshot?
    let taskCoordinator = DocumentTaskCoordinator()
    let provenance = DocumentProvenance()
    var aiMetadata: String?
    @Published var pendingAIContextSelection: (range: NSRange, revision: UInt)? = nil
    private var savedText: String?
    private var liveTextProviderID: UUID?
    private var liveTextProvider: (() -> String?)?
    private var liveTextAcknowledgement: ((UInt) -> Void)?
    private(set) var hasPendingLiveEdits = false
    private var pendingLiveTextIsEmpty: Bool?
    private var isUpdatingDirtyState = false
    private var metricsGeneration: UInt = 0
    private var statisticsReadingSpeed = 200
    private var markdownReadableText: (revision: UInt, value: MarkdownReadableText)?
    private var metricsSuspended = false
    private var isTakingMetricsSnapshot = false
    private var metricsDebounceWorkItem: DispatchWorkItem?

    init(
        id: UUID = UUID(),
        text: String = "",
        url: URL? = nil,
        language: EditorLanguage = .plainText,
        fileEncoding: String.Encoding = .utf8,
        fileRevisionSnapshot: FileRevisionSnapshot? = nil,
        isDirty: Bool = false,
        byteCount: Int? = nil,
        lineCount: Int? = nil,
        performanceProfile: DocumentPerformanceProfile? = nil,
        requiresExplicitSave: Bool = false
    ) {
        self.id = id
        self.text = text
        self.url = url
        self.language = language
        self.fileEncoding = fileEncoding
        self.fileIdentity = url.map(DocumentFileIdentity.resolve)
        self.fileRevisionSnapshot = fileRevisionSnapshot
        self.isDirty = isDirty
        let resolvedProfile = performanceProfile ?? .resolve(
            byteCount: byteCount ?? text.utf8.count,
            lineCount: lineCount ?? Self.countLines(in: text)
        )
        self.performanceProfile = resolvedProfile
        self.isPreviewVisible = language == .markdown && resolvedProfile == .standard
        self.savedText = requiresExplicitSave ? nil : text
        self.statistics = language != .markdown && resolvedProfile == .standard && text.utf16.count < 100_000
            ? DocumentStatistics.calculate(text)
            : nil
        if resolvedProfile == .standard && text.utf16.count >= 100_000 {
            scheduleMetricsRefresh()
        }
    }

    deinit {
        taskCoordinator.cancelAll()
        metricsDebounceWorkItem?.cancel()
    }

    var displayName: String {
        url?.lastPathComponent ?? L10n.tr("未命名")
    }

    var encodingName: String {
        FileService.encodingName(for: fileEncoding)
    }

    func updateFileEncoding(_ encoding: String.Encoding) {
        fileEncoding = encoding
    }

    func updateFileRevisionSnapshot(_ snapshot: FileRevisionSnapshot?) {
        fileRevisionSnapshot = snapshot
        if let snapshot { fileIdentity = snapshot.identity }
    }

    var isDisposableBlank: Bool {
        let isEmpty = hasPendingLiveEdits
            ? pendingLiveTextIsEmpty ?? text.isEmpty
            : text.isEmpty
        return ioState == .idle && url == nil && isEmpty && !isDirty
    }

    var lineCount: Int {
        Self.countLines(in: text)
    }

    var isLargeFileMode: Bool { performanceProfile != .standard }

    func effectiveWordWrap(globalDefault: Bool) -> Bool {
        featureOverrides.wordWrap ?? (performanceProfile == .standard ? globalDefault : false)
    }

    var isPreviewEffectivelyEnabled: Bool {
        language == .markdown && (featureOverrides.preview ?? (
            performanceProfile == .standard && isPreviewVisible
        ))
    }

    var isSyntaxHighlightingEnabled: Bool {
        featureOverrides.syntaxHighlighting ?? (performanceProfile != .extreme)
    }

    var isFoldingEnabled: Bool {
        featureOverrides.folding ?? (performanceProfile == .standard)
    }

    var isWordCountEnabled: Bool {
        featureOverrides.wordCount ?? (performanceProfile == .standard)
    }

    func updatePerformanceProfile(byteCount: Int? = nil, lineCount: Int? = nil) {
        let next = DocumentPerformanceProfile.resolve(
            byteCount: byteCount ?? text.utf8.count,
            lineCount: lineCount ?? self.lineCount
        )
        guard next != performanceProfile else { return }
        performanceProfile = next
        if next != .standard { isPreviewVisible = false }
        scheduleMetricsRefresh()
    }

    func setOverride(_ enabled: Bool, for feature: DocumentManagedFeature) {
        switch feature {
        case .wordWrap: featureOverrides.wordWrap = enabled
        case .preview: featureOverrides.preview = enabled
        case .syntaxHighlighting: featureOverrides.syntaxHighlighting = enabled
        case .folding: featureOverrides.folding = enabled
        case .wordCount:
            featureOverrides.wordCount = enabled
            scheduleMetricsRefresh()
        }
    }

    static func countLines(in text: String) -> Int {
        var count = 1
        var previousWasCR = false
        // Sequential UTF-16 iteration avoids NSString random-access bridging
        // on every code unit of a large, mixed CJK/Latin Swift String.
        for character in text.utf16 {
            if (character == 0x0A && !previousWasCR)
                || character == 0x0D
                || character == 0x2028
                || character == 0x2029 {
                count += 1
            }
            previousWasCR = character == 0x0D
        }
        return count
    }

    func refreshDirtyState() {
        synchronizeLiveText()
        let currentText = text
        let shouldBeDirty = savedText.map { currentText != $0 } ?? true
        updateDirtyState(shouldBeDirty)
    }

    func markSaved() {
        synchronizeLiveText()
        let currentText = text
        savedText = currentText
        updateDirtyState(false)
    }

    func markSaved(snapshot: String, revision: UInt) {
        savedText = snapshot
        let shouldBeDirty = textRevision != revision
            || hasPendingLiveEdits
            || text != snapshot
        updateDirtyState(shouldBeDirty)
    }

    func attachLiveTextProvider(
        id: UUID,
        provider: @escaping () -> String?,
        acknowledgement: @escaping (UInt) -> Void
    ) {
        liveTextProviderID = id
        liveTextProvider = provider
        liveTextAcknowledgement = acknowledgement
    }

    func detachLiveTextProvider(id: UUID) {
        guard liveTextProviderID == id else { return }
        synchronizeLiveText()
        liveTextProviderID = nil
        liveTextProvider = nil
        liveTextAcknowledgement = nil
        hasPendingLiveEdits = false
        pendingLiveTextIsEmpty = nil
        let shouldBeDirty = savedText.map { text != $0 } ?? true
        updateDirtyState(shouldBeDirty)
    }

    func noteLiveEdit(isEmpty: Bool) {
        markdownReadableText = nil
        hasPendingLiveEdits = true
        pendingLiveTextIsEmpty = isEmpty
        scheduleMetricsRefresh()
        let shouldBeDirty = !(url == nil && isEmpty)
        updateDirtyState(shouldBeDirty)
    }

    @discardableResult
    func synchronizeLiveText() -> Bool {
        guard hasPendingLiveEdits,
              let currentText = liveTextProvider?() else { return false }
        hasPendingLiveEdits = false
        pendingLiveTextIsEmpty = nil
        text = currentText
        liveTextAcknowledgement?(textRevision)
        return true
    }

    func synchronizedText() -> String {
        synchronizeLiveText()
        return text
    }

    /// Returns one immutable snapshot for the current revision. Swift's
    /// copy-on-write String keeps background consumers on shared storage until
    /// a mutation occurs, while the revision prevents stale results.
    func synchronizedSnapshot() -> DocumentTextSnapshot {
        synchronizeLiveText()
        if let cached = textSnapshotCache,
           cached.revision == textRevision {
            return cached
        }
        let snapshot = DocumentTextSnapshot(
            documentID: id,
            revision: textRevision,
            text: text
        )
        textSnapshotCache = snapshot
        return snapshot
    }

    private func updateDirtyState(_ newValue: Bool) {
        guard !isUpdatingDirtyState else { return }
        guard isDirty != newValue else { return }
        isUpdatingDirtyState = true
        defer { isUpdatingDirtyState = false }
        isDirty = newValue
    }

    func updateLocationAfterRename(from oldURL: URL, to newURL: URL) {
        guard url?.standardizedFileURL == oldURL.standardizedFileURL else {
            return
        }
        updateLocation(to: newURL)
    }

    func updateLocation(to newURL: URL) {
        let wasMarkdown = language == .markdown
        let newLanguage = EditorLanguage.infer(from: newURL)
        url = newURL.standardizedFileURL
        fileIdentity = DocumentFileIdentity.resolve(newURL)
        language = newLanguage
        if newLanguage == .markdown, !wasMarkdown {
            isPreviewVisible = true
        } else if newLanguage != .markdown {
            isPreviewVisible = false
        }

        // @Published announces before assignment. Emit once after this compound
        // update so parent views read the new title, language, and preview state.
        objectWillChange.send()
    }

    func setStatisticsReadingSpeed(_ wordsPerMinute: Int) {
        guard wordsPerMinute > 0, wordsPerMinute != statisticsReadingSpeed else { return }
        statisticsReadingSpeed = wordsPerMinute
        scheduleMetricsRefresh()
    }

    var hasCurrentMarkdownReadableText: Bool {
        !hasPendingLiveEdits && markdownReadableText?.revision == textRevision
    }

    @discardableResult
    func installMarkdownReadableText(_ value: MarkdownReadableText, source: String) -> Bool {
        guard language == .markdown, isWordCountEnabled, !metricsSuspended else { return false }
        isTakingMetricsSnapshot = true
        let snapshot = synchronizedSnapshot()
        isTakingMetricsSnapshot = false
        guard !hasPendingLiveEdits, snapshot.text.utf16.elementsEqual(source.utf16), value.sourceLength == (source as NSString).length else { return false }
        markdownReadableText = (snapshot.revision, value)
        scheduleMetricsRefresh()
        return true
    }

    func invalidateMarkdownReadableText() {
        guard markdownReadableText != nil else { return }
        markdownReadableText = nil
        scheduleMetricsRefresh()
    }

    private func scheduleMetricsRefresh() {
        metricsGeneration &+= 1
        let generation = metricsGeneration
        metricsDebounceWorkItem?.cancel()
        metricsDebounceWorkItem = nil
        taskCoordinator.cancel(.metrics)
        if statistics != nil { statistics = nil }
        if statisticsUnavailable { statisticsUnavailable = false }
        guard !metricsSuspended, isWordCountEnabled else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.metricsGeneration == generation,
                  !self.metricsSuspended, self.isWordCountEnabled else { return }
            self.metricsDebounceWorkItem = nil
            self.isTakingMetricsSnapshot = true
            let snapshot = self.synchronizedSnapshot()
            self.isTakingMetricsSnapshot = false
            guard !self.hasPendingLiveEdits else { return }
            let selection = self.selectionRange
            let selectedText: String
            if selection.length == 0 {
                selectedText = snapshot.text
            } else {
                let source = snapshot.text as NSString
                func isBoundary(_ location: Int) -> Bool {
                    location == 0 || location == source.length ||
                        (location < source.length && source.rangeOfComposedCharacterSequence(at: location).location == location)
                }
                guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
                      selection.location <= source.length, selection.length <= source.length - selection.location,
                      isBoundary(selection.location), isBoundary(NSMaxRange(selection)),
                      let range = Range(selection, in: snapshot.text) else {
                    self.statisticsUnavailable = true
                    return
                }
                selectedText = String(snapshot.text[range])
            }
            let readable: MarkdownReadableText?
            if self.language == .markdown {
                guard let cached = self.markdownReadableText, cached.revision == snapshot.revision else { return }
                readable = cached.value
            } else { readable = nil }
            self.startMetricsRefresh(for: selectedText, source: snapshot.text, readable: readable,
                                     selection: selection.length == 0 ? nil : selection, generation: generation, revision: snapshot.revision)
        }
        metricsDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func startMetricsRefresh(for snapshot: String, source: String, readable: MarkdownReadableText?, selection: NSRange?, generation: UInt, revision: UInt) {
        let coordinator = taskCoordinator
        let taskGeneration = coordinator.begin(.metrics)
        let readingSpeed = statisticsReadingSpeed
        let task = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let prose = readable?.text(in: selection, source: source as NSString, isCancelled: { Task.isCancelled })
            let unavailable = readable != nil && prose == nil
            let result = unavailable ? nil : DocumentStatistics.calculate(snapshot, wordsPerMinute: readingSpeed, readableText: prose, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled, coordinator.isCurrent(taskGeneration, for: .metrics) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.metricsGeneration == generation, self.textRevision == revision,
                      !self.hasPendingLiveEdits,
                      (self.selectionRange.length == 0 ? nil : self.selectionRange) == selection,
                      !self.metricsSuspended, self.isWordCountEnabled, !Task.isCancelled,
                      coordinator.isCurrent(taskGeneration, for: .metrics) else { return }
                self.statistics = result
                self.statisticsUnavailable = unavailable
                coordinator.finish(.metrics, generation: taskGeneration)
            }
        }
        coordinator.attachTask(task, kind: .metrics, generation: taskGeneration)
    }

    func cancelMetricsRefresh() {
        metricsSuspended = true
        metricsGeneration &+= 1
        metricsDebounceWorkItem?.cancel()
        metricsDebounceWorkItem = nil
        taskCoordinator.cancel(.metrics)
        if statistics != nil { statistics = nil }
    }

    func resumeMetricsRefresh() {
        guard metricsSuspended else { return }
        metricsSuspended = false
        scheduleMetricsRefresh()
    }
}
