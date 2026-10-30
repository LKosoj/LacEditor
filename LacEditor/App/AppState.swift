import AppKit
import Combine
import ImageIO
import os
import SwiftUI
import UniformTypeIdentifiers

private let filePerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "FilePerformance"
)

private let fileVersionLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "FileVersions"
)

private let taskPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "DocumentTasks"
)

private final class ImportFormatFilterController: NSObject {
    private weak var panel: NSOpenPanel?
    private let allTypes: [UTType]
    private let individualTypes: [UTType]

    init(panel: NSOpenPanel, allTypes: [UTType], individualTypes: [UTType]) {
        self.panel = panel
        self.allTypes = allTypes
        self.individualTypes = individualTypes
    }

    @objc func selectFormat(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        panel?.allowedContentTypes = index == 0 ? allTypes : [individualTypes[index - 1]]
    }
}

private func documentTaskSignpostName(
    for kind: DocumentTaskCoordinator.Kind
) -> StaticString {
    switch kind {
    case .search: "Search"
    case .replace: "ReplaceAll"
    case .json: "JSONFormat"
    case .preview: "MarkdownRender"
    case .metrics: "Metrics"
    case .save: "FileSave"
    case .listNormalization: "ListNormalization"
    case .delimiterMatch: "DelimiterMatch"
    case .folding: "Folding"
    case .textTransformation: "TextTransformation"
    case .markdownPresentation: "MarkdownPresentation"
    case .aiWriting: "AIWriting"
    case .aiCompletion: "AICompletion"
    case .aiMetadata: "AIMetadata"
    case .aiDocumentTools: "AIDocumentTools"
    case .aiQuestion: "AIQuestion"
    case .lineEndings: "LineEndings"
    case .lineEndingConversion: "LineEndingConversion"
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum EditorCommandNotification {
    static let clipboardSavedImages = Notification.Name("LacEditor.clipboardSavedImages")
    static let navigateMarkdownLink = Notification.Name("LacEditor.navigateMarkdownLink")
    static let markdownClipboard = Notification.Name("LacEditor.markdownClipboard")
    static let insertMarkdownImage = Notification.Name("LacEditor.insertMarkdownImage")
    static let formatMarkdown = Notification.Name("LacEditor.formatMarkdown")
    static let editLines = Notification.Name("LacEditor.editLines")
    static let criticMarkup = Notification.Name("LacEditor.criticMarkup")
    static let revealSelection = Notification.Name("LacEditor.revealSelection")
    static let findHighlights = Notification.Name("LacEditor.findHighlights")
    static let toggleFold = Notification.Name("LacEditor.toggleFold")
    static let undo = Notification.Name("LacEditor.undo")
    static let redo = Notification.Name("LacEditor.redo")
    static let applyTextUpdate = Notification.Name("LacEditor.applyTextUpdate")
    static let extractTextSelection = Notification.Name(
        "LacEditor.extractTextSelection"
    )
    static let applyRangeReplacement = Notification.Name(
        "LacEditor.applyRangeReplacement"
    )
    static let documentContentDidChange = Notification.Name(
        "LacEditor.documentContentDidChange"
    )
}

final class ClipboardSavedImagesNotice {
    let documentID: UUID
    let message: String
    var handled = false

    init(documentID: UUID, message: String) {
        self.documentID = documentID
        self.message = message
    }

    func deliver(to document: EditorDocument) {
        if let existing = document.statusMessage, !existing.isEmpty {
            if !existing.contains(message) { document.statusMessage = existing + "\n" + message }
        } else { document.statusMessage = message }
    }
}

enum MarkdownClipboardCommand { case copyMarkdown, copyHTML, pasteSource, copyCodeBlock, setCodeLanguage }
struct MarkdownClipboardRequest {
    let documentID: UUID
    let command: MarkdownClipboardCommand
}

struct MarkdownLinkNavigationRequest {
    let snapshot: DocumentTextSnapshot
    let link: MarkdownLink
    let headings: [MarkdownHeading]
    var namedAnchors: [MarkdownNamedAnchor] = []
    let isCurrent: () -> Bool
}

struct EditorSelectionRequest {
    let documentID: UUID
    let range: NSRange
    var focusesEditor = true
}

/// Пустой список снимает подсветку совпадений поиска.
struct FindHighlightRequest {
    let documentID: UUID
    let matches: [NSRange]
}

struct MarkdownFormattingRequest {
    let documentID: UUID
    let command: MarkdownFormattingCommand
}

struct LineEditingRequest {
    let documentID: UUID
    let command: LineEditingCommand
}

struct CriticMarkupRequest {
    let documentID: UUID
    let command: CriticMarkupCommand
}

final class EditorTextUpdateRequest {
    let documentID: UUID
    let text: String
    let selectionRange: NSRange
    let actionName: String
    var wasHandled = false

    init(
        documentID: UUID,
        text: String,
        selectionRange: NSRange,
        actionName: String
    ) {
        self.documentID = documentID
        self.text = text
        self.selectionRange = selectionRange
        self.actionName = actionName
    }
}

struct EditorVirtualTableTarget: Equatable {
    let contextID: UUID
    let rowStart: Int
    let column: Int
    let separators: Int
    let range: NSRange
}

struct EditorTextSelectionSnapshot {
    let documentID: UUID
    let range: NSRange
    let text: String
    let editorRevision: UInt
    let wasExplicitSelection: Bool
    var virtualTableTarget: EditorVirtualTableTarget? = nil

    func matches(_ other: EditorTextSelectionSnapshot) -> Bool {
        documentID == other.documentID && range == other.range && text == other.text && editorRevision == other.editorRevision && virtualTableTarget == other.virtualTableTarget
    }
}

struct MarkdownLinkDialogState {
    let document: DocumentTextSnapshot
    let selection: EditorTextSelectionSnapshot

    func matches(document otherDocument: DocumentTextSnapshot, selection otherSelection: EditorTextSelectionSnapshot) -> Bool {
        document.documentID == otherDocument.documentID && document.revision == otherDocument.revision && selection.matches(otherSelection)
    }
}

final class MarkdownImageTransferRequest {
    let documentID: UUID
    let transfer: MarkdownImageTransfer
    var handled = false
    init(documentID: UUID, transfer: MarkdownImageTransfer) {
        self.documentID = documentID
        self.transfer = transfer
    }
}

final class EditorTextExtractionRequest {
    let documentID: UUID
    let allowsTokenAtCaret: Bool
    let allowsWholeDocument: Bool
    let allowsInsertionPoint: Bool
    let requiresEditable: Bool
    var result: EditorTextSelectionSnapshot?

    init(documentID: UUID, allowsTokenAtCaret: Bool, allowsWholeDocument: Bool = false, allowsInsertionPoint: Bool = false, requiresEditable: Bool = false) {
        self.documentID = documentID
        self.allowsTokenAtCaret = allowsTokenAtCaret
        self.allowsWholeDocument = allowsWholeDocument
        self.allowsInsertionPoint = allowsInsertionPoint
        self.requiresEditable = requiresEditable
    }
}

final class EditorRangeReplacementRequest {
    let documentID: UUID
    let range: NSRange
    let originalText: String
    let replacementText: String
    let expectedEditorRevision: UInt
    let actionName: String
    var wasHandled = false
    var failureMessage: String?
    var resultingSelection: NSRange?
    var groupsUndo = false
    var suppressUndoRegistration = false
    var registerImageFileUndo: ((UndoManager, LacTextView) -> Void)?
    var virtualTableTarget: EditorVirtualTableTarget?

    init(
        documentID: UUID,
        range: NSRange,
        originalText: String,
        replacementText: String,
        expectedEditorRevision: UInt,
        actionName: String
    ) {
        self.documentID = documentID
        self.range = range
        self.originalText = originalText
        self.replacementText = replacementText
        self.expectedEditorRevision = expectedEditorRevision
        self.actionName = actionName
    }
}

private final class MarkdownImageFileUndoState {
    struct File {
        let source: URL
        let destination: URL?
        var current: URL
        var identity: WorkspaceNodeIdentity
    }
    var files: [File]
    let retainedCopies: [(URL, FileRevisionSnapshot)]
    let documentURL: URL?
    let before: String
    let after: String
    let edit: MarkdownFormattingEdit
    let selection: NSRange

    init(files: [File], retainedCopies: [(URL, FileRevisionSnapshot)] = [], documentURL: URL?, before: String, after: String,
         edit: MarkdownFormattingEdit, selection: NSRange) {
        self.files = files
        self.retainedCopies = retainedCopies
        self.documentURL = documentURL
        self.before = before
        self.after = after
        self.edit = edit
        self.selection = selection
    }
}

enum SidebarPresentation: Equatable {
    case hidden
    case preview
    case pinned
}

@MainActor
final class AppState: ObservableObject {
    let sidebarFeedback = InlineFeedbackState()
    @Published var documents: [EditorDocument] = []
    private var searchMatchCache = SearchMatchCacheStore()
    @Published var selectedDocumentID: UUID? {
        didSet {
            if oldValue != selectedDocumentID { aiWriting.selectedDocumentChanged() }
            if oldValue != selectedDocumentID, let selectedDocumentID {
                windowManager?.prioritizeRestoration(selectedDocumentID)
            }
            if oldValue != selectedDocumentID, findReplace.isBarVisible {
                clearFindResults()
                scheduleFindRefresh()
            }
            guard oldValue != selectedDocumentID,
                  findReplace.isWorking,
                  let activeID = findReplace.activeDocumentID,
                  activeID != selectedDocumentID else { return }
            documents.first(where: { $0.id == activeID })?.taskCoordinator.cancel(.search)
            documents.first(where: { $0.id == activeID })?.taskCoordinator.cancel(.replace)
            findReplace.isWorking = false
            findReplace.activeDocumentID = nil
            findReplace.message = L10n.tr("目标标签已切换，查找已取消")
        }
    }
    @Published var isSidebarVisible: Bool {
        didSet {
            UserDefaults.standard.set(
                isSidebarVisible,
                forKey: "isSidebarVisible"
            )
        }
    }
    @Published private(set) var isDistractionFree = false
    @Published private(set) var isFocusMode = false
    @Published private(set) var focusScope: FocusScope = .paragraph
    @Published private(set) var isTypewriterMode = false
    @Published private(set) var viewMagnification: CGFloat = 1
    @Published var isMarkdownOutlineExpanded = false
    @Published var isBacklinksExpanded = false
    var isWordWrapEnabled: Bool {
        get { preferences.wordWrapEnabled }
        set { preferences.wordWrapEnabled = newValue }
    }
    var editorFontSize: CGFloat {
        get { preferences.editorFontSize }
        set { preferences.editorFontSize = newValue }
    }
    var editorLineSpacing: CGFloat {
        get { preferences.editorLineSpacing }
        set { preferences.editorLineSpacing = newValue }
    }
    var indentationStyle: IndentationStyle {
        get { preferences.indentationStyle }
        set { preferences.indentationStyle = newValue }
    }
    var tabWidth: Int {
        get { preferences.tabWidth }
        set { preferences.tabWidth = newValue }
    }
    var isLineNumbersVisible: Bool {
        get { preferences.lineNumbersVisible }
        set { preferences.lineNumbersVisible = newValue }
    }
    var isStatusBarVisible: Bool {
        get { preferences.statusBarVisible }
        set { preferences.statusBarVisible = newValue }
    }
    var theme: AppTheme {
        get { preferences.theme }
        set { preferences.theme = newValue }
    }
    var workspaceExitBehavior: WorkspaceExitBehavior {
        get { preferences.workspaceExitBehavior }
        set { preferences.workspaceExitBehavior = newValue }
    }

    let recentFiles: RecentFilesStore
    let preferences: AppPreferences
    let folderWorkspace = FolderWorkspaceStore()
    /// Список Markdown-файлов для wiki-ссылок (оформление, предпросмотр, экспорт, подсказки).
    let wikiCatalog = WikiLinkCatalog()
    private var wikiCatalogCancellable: AnyCancellable?
    private var wikiRootCancellable: AnyCancellable?
    private var folderSearchStorage: FolderSearchController?
    private var folderSearchRootCancellable: AnyCancellable?
    var folderSearch: FolderSearchController {
        if let folderSearchStorage { return folderSearchStorage }
        let controller = FolderSearchController(snapshots: { [weak self] in
            guard let self, let root = self.folderWorkspace.rootURL, let manager = self.windowManager else { return nil }
            return manager.folderSearchSnapshots(root: root)
        }, open: { [weak self] url in
            guard !Task.isCancelled, let self, let root = self.folderWorkspace.rootURL,
                  url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents),
                  let manager = self.windowManager else { return nil }
            return await manager.openFolderSearchFile(url, preferredState: self)
        }, reveal: { [weak self] match, document in
            self?.windowManager?.revealFolderSearchMatch(match, expected: document) == true
        }, openFile: { [weak self] url in
            self?.openFile(url)
        }, folderLocations: { [weak self] in
            guard let self else { return [] }
            return (self.windowManager?.sidebarLibrary.pinnedFolderURLs ?? []) + self.recentFiles.folderURLs
        }, openFolder: { [weak self] url in
            self?.openFolder(url)
        }, confirmReplace: { summary in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("确认替换？")
            var text = L10n.tr("将在 %d 个文件中替换 %d 处。已关闭的文件将直接写入磁盘，此操作无法用“撤销”命令撤回；已打开的文档会作为一次编辑进行，可以撤销。", summary.fileCount, summary.matchCount)
            if summary.openCount > 0 {
                text += "\n" + L10n.tr("其中 %d 个文件已在编辑器中打开，将切换到对应窗口。", summary.openCount)
            }
            alert.informativeText = text
            alert.addButton(withTitle: L10n.tr("取消"))
            let replace = alert.addButton(withTitle: L10n.tr("替换"))
            replace.hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn
        }, interpretsEscapes: { [weak self] in
            self?.findReplace.interpretsEscapes ?? true
        }, applyOpen: { [weak self] replace in
            guard let manager = self?.windowManager else { return .skipped(.changed) }
            return await manager.applyFolderReplace(replace)
        })
        controller.setRoot(folderWorkspace.rootURL)
        folderSearchStorage = controller
        folderSearchRootCancellable = folderWorkspace.$rootURL.sink { [weak controller] root in
            controller?.setRoot(root)
        }
        return controller
    }
    /// Обратные ссылки текущего документа; панель вызывает `update`, события папки — `refreshSoon`.
    private var backlinksStorage: MarkdownBacklinksController?
    var backlinks: MarkdownBacklinksController {
        if let backlinksStorage { return backlinksStorage }
        let controller = MarkdownBacklinksController(snapshots: { [weak self] in
            guard let self, let root = self.folderWorkspace.rootURL, let manager = self.windowManager else { return nil }
            return manager.folderSearchSnapshots(root: root)
        }, open: { [weak self] url in
            guard !Task.isCancelled, let self, let root = self.folderWorkspace.rootURL,
                  url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents),
                  let manager = self.windowManager else { return nil }
            return await manager.openFolderSearchFile(url, preferredState: self)
        }, reveal: { [weak self] match, document in
            self?.windowManager?.revealFolderSearchMatch(match, expected: document) == true
        }, syntax: { [weak self] in
            self?.preferences.markdownSyntax ?? .init()
        })
        backlinksStorage = controller
        return controller
    }
    private var folderTagsStorage: FolderTagsController?
    private var folderTagsRootCancellable: AnyCancellable?
    var folderTags: FolderTagsController {
        if let folderTagsStorage { return folderTagsStorage }
        let controller = FolderTagsController(snapshots: { [weak self] in
            guard let self, let root = self.folderWorkspace.rootURL, let manager = self.windowManager else { return nil }
            return manager.folderSearchSnapshots(root: root)
        })
        controller.setRoot(folderWorkspace.rootURL)
        folderTagsStorage = controller
        folderTagsRootCancellable = folderWorkspace.$rootURL.sink { [weak controller] root in
            controller?.setRoot(root)
        }
        return controller
    }
    let findReplace = FindReplaceState()
    let textTransformation = TextTransformationPreviewState()
    lazy var aiWriting = AIWritingController(appState: self)
    @Published var isAIWritingVisible = false
    let commandPalette = CommandPaletteController()
    weak var hostWindow: NSWindow? {
        didSet {
            if oldValue !== hostWindow && isDistractionFree { toggleDistractionFree() }
        }
    }
    private weak var distractionFreeToolbar: NSToolbar?
    private var previousToolbarVisibility: Bool?
    weak var windowManager: WindowManager?
    private var findRefreshTask: Task<Void, Never>?
    var templateTask: Task<Void, Never>?
    var renameLinkTask: Task<Void, Never>?
    var manuscriptSheet: NSWindow?
    var manuscriptStorage: ManuscriptController?
    private var textTransformationWindowController: TextTransformationWindowController?
    let fileService = FileService()
    private let fileOpeningQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.laceditor.file-opening"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let fileWriteQueue = DispatchQueue(
        label: "com.laceditor.file-writing",
        qos: .userInitiated
    )
    private let documentTaskQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.laceditor.document-tasks"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var documentCancellables: [UUID: AnyCancellable] = [:]
    private var recoveryCancellables: [UUID: AnyCancellable] = [:]
    private var writingGoalCancellables: [UUID: AnyCancellable] = [:]
    private var writingGoalLanguages: [UUID: EditorLanguage] = [:]
    private var recoveryWorkItems: [UUID: DispatchWorkItem] = [:]
    /// Токены запросов записи копии: подтверждение применяется только к последнему запросу документа.
    private var recoveryRequestTokens: [UUID: UInt] = [:]
    private var recoveryTokenCounter: UInt = 0
    private var documentsBeingSnapshotted: Set<UUID> = []
    private var exportingDocumentIDs: Set<UUID> = []
    private var pdfExports: [UUID: MarkdownPDFExportService] = [:]
    private var customExportOperations: [UUID: Operation] = [:]
    private var imageExportPreparations: [UUID: (UUID, MarkdownExportImagesService)] = [:]
    private var imageExportDocuments: Set<UUID> = []
    var latexExportWillCommit: ((URL) -> Void)?
    private var imageUploads: [UUID: (UUID, Task<Void, Never>)] = [:]
    private var imagePolicyOperations: [UUID: Operation] = [:]
    private var imageCopyOperations: [UUID: Operation] = [:]
    private enum PreviousMarkdownExportKind {
        case profile(MarkdownExportProfile), htmlProfile(MarkdownExportProfile, MarkdownHTMLExportOptions), standard(PandocExportFormat), html(MarkdownHTMLExportOptions), htmlPlain(MarkdownHTMLExportOptions), pdf(MarkdownNativeExportOptions, MarkdownPDFHeaderFooterOptions), image(MarkdownNativeExportOptions)
    }
    private struct PreviousMarkdownExport {
        let kind: PreviousMarkdownExportKind
        let destination: URL?
        let revision: FileRevisionSnapshot?
    }
    @Published private var previousMarkdownExports: [UUID: PreviousMarkdownExport] = [:]
    private var openingFileURLs: Set<URL> = []
    private var openingOperations: [URL: Operation] = [:]
    private var openingPlaceholderIDs: Set<UUID> = []
    private var versionHistorySheet: NSWindow?
    private var contentChangeObserver: NSObjectProtocol?
    private var markdownLinkObserver: NSObjectProtocol?
    private var markdownLinkTask: (id: UUID, documentID: UUID, task: Task<Void, Never>)?
    private var imageTransferObserver: NSObjectProtocol?
    private var clipboardSavedImagesObserver: NSObjectProtocol?
    private var preferencesCancellable: AnyCancellable?
    private let recoveryStore: DocumentRecoveryStore?
    private let readFile: @Sendable (URL) throws -> PreparedFileRead
    /// Сырые байты для «Открыть заново в кодировке»: `readFile` при валидном UTF-8 возвращает уже декодированный текст.
    private let readRawFile: @Sendable (URL) throws -> (data: Data, snapshot: FileRevisionSnapshot)

    init(
        initialDocument: EditorDocument? = nil,
        initialDocuments: [EditorDocument] = [],
        recentFiles: RecentFilesStore,
        preferences: AppPreferences,
        recoveryStore: DocumentRecoveryStore? = nil,
        readFile: @escaping @Sendable (URL) throws -> PreparedFileRead = { try FileService.prepareRead($0) },
        readRawFile: @escaping @Sendable (URL) throws -> (data: Data, snapshot: FileRevisionSnapshot) = { try FileService.readRawData($0) }
    ) {
        self.recentFiles = recentFiles
        self.preferences = preferences
        self.recoveryStore = recoveryStore
        self.readFile = readFile
        self.readRawFile = readRawFile
        isSidebarVisible = UserDefaults.standard.object(
            forKey: "isSidebarVisible"
        ) as? Bool ?? true
        preferencesCancellable = preferences.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        wikiCatalogCancellable = wikiCatalog.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        folderWorkspace.filesDidChange = { [weak self] in self?.wikiCatalog.invalidate(); self?.backlinksStorage?.refreshSoon() }
        // @Published сообщает до смены значения: каталог запрашиваем на следующем шаге главного потока.
        wikiRootCancellable = folderWorkspace.$rootURL.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let document = self.selectedDocument, document.language == .markdown else { return }
                self.requestWikiCatalog(for: document)
            }
        }
        if !initialDocuments.isEmpty {
            openingPlaceholderIDs.formUnion(initialDocuments.filter { $0.ioState == .opening && $0.text.isEmpty }.map(\.id))
            documents = initialDocuments
            selectedDocumentID = initialDocuments.first?.id
            initialDocuments.forEach(observe)
        } else if let initialDocument {
            if initialDocument.ioState == .opening && initialDocument.text.isEmpty { openingPlaceholderIDs.insert(initialDocument.id) }
            documents = [initialDocument]
            selectedDocumentID = initialDocument.id
            observe(initialDocument)
        } else {
            newDocument()
        }
        markdownLinkObserver = NotificationCenter.default.addObserver(forName: EditorCommandNotification.navigateMarkdownLink, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let request = notification.object as? MarkdownLinkNavigationRequest,
                      self.selectedDocument?.id == request.snapshot.documentID else { return }
                self.navigateMarkdownLink(request)
            }
        }
        imageTransferObserver = NotificationCenter.default.addObserver(forName: EditorCommandNotification.insertMarkdownImage, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let request = notification.object as? MarkdownImageTransferRequest,
                      self.selectedDocument?.id == request.documentID else { return }
                request.handled = self.presentMarkdownImage(transfer: request.transfer)
            }
        }
        clipboardSavedImagesObserver = NotificationCenter.default.addObserver(forName: EditorCommandNotification.clipboardSavedImages, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let manager = self.windowManager, manager.activeState === self,
                      let notice = notification.object as? ClipboardSavedImagesNotice, !notice.handled,
                      let target = manager.documentsForAI.first(where: { $0.id == notice.documentID }) ?? self.selectedDocument else { return }
                notice.handled = true
                notice.deliver(to: target)
            }
        }
        contentChangeObserver = NotificationCenter.default.addObserver(
            forName: EditorCommandNotification.documentContentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let documentID = notification.object as? UUID,
                      let document = self.documents.first(where: { $0.id == documentID }) else { return }
                if self.imageExportDocuments.contains(documentID) {
                    self.customExportOperations[documentID]?.cancel()
                    self.imageExportPreparations[documentID]?.1.cancel()
                    document.statusMessage = L10n.tr("文档已更改，导出已取消。")
                }
                if self.markdownLinkTask?.documentID == documentID {
                    self.markdownLinkTask?.task.cancel()
                    self.markdownLinkTask = nil
                }
                document.taskCoordinator.cancel(.search)
                document.taskCoordinator.cancel(.replace)
                document.taskCoordinator.cancel(.json)
                document.taskCoordinator.cancel(.listNormalization)
                document.taskCoordinator.cancel(.textTransformation)
                let upload = self.imageUploads.removeValue(forKey: documentID)
                let imagePolicy = self.imagePolicyOperations.removeValue(forKey: documentID)
                let imageCopy = self.imageCopyOperations.removeValue(forKey: documentID)
                upload?.1.cancel()
                imagePolicy?.cancel()
                imageCopy?.cancel()
                if upload != nil || imagePolicy != nil || imageCopy != nil {
                    document.statusMessage = L10n.tr("文档已变化，未应用上传结果")
                }
                if document.statusMessage?.hasPrefix(L10n.tr("正在格式化")) == true
                    || document.statusMessage?.hasPrefix(L10n.tr("正在压缩")) == true {
                    document.statusMessage = L10n.tr("内容已变化，JSON 操作已取消")
                }
                if self.findReplace.isWorking {
                    self.findReplace.isWorking = false
                    self.findReplace.message = L10n.tr("内容已变化，任务已取消")
                }
                if documentID == self.selectedDocumentID, self.findReplace.isBarVisible {
                    self.clearFindResults()
                    self.scheduleFindRefresh()
                }
                self.textTransformation.invalidate(documentID: documentID)
                self.aiWriting.documentChanged(documentID)
                self.scheduleRecoverySnapshot(for: document)
            }
        }
    }

    deinit {
        markdownLinkTask?.task.cancel()
        if let markdownLinkObserver { NotificationCenter.default.removeObserver(markdownLinkObserver) }
        if let imageTransferObserver { NotificationCenter.default.removeObserver(imageTransferObserver) }
        if let clipboardSavedImagesObserver { NotificationCenter.default.removeObserver(clipboardSavedImagesObserver) }
        if let contentChangeObserver {
            NotificationCenter.default.removeObserver(contentChangeObserver)
        }
        documentTaskQueue.cancelAllOperations()
        recoveryWorkItems.values.forEach { $0.cancel() }
    }

    var selectedDocument: EditorDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var selectedDocumentIndex: Int? {
        guard let selectedDocumentID else { return nil }
        return documents.firstIndex { $0.id == selectedDocumentID }
    }

    func isOpeningPlaceholder(_ document: EditorDocument) -> Bool {
        openingPlaceholderIDs.contains(document.id)
    }

    var hasPendingOpen: Bool {
        documents.contains { $0.ioState == .opening }
    }

    var hasFailedOpeningPlaceholder: Bool {
        documents.contains { openingPlaceholderIDs.contains($0.id) && $0.ioState != .opening }
    }

    var hasPendingSave: Bool {
        documents.contains { $0.ioState == .saving }
    }

    func waitForPendingSaves(completion: @escaping () -> Void) {
        guard hasPendingSave else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.waitForPendingSaves(completion: completion)
        }
    }

    var preferredColorScheme: ColorScheme {
        switch theme {
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func refreshSystemAppearance() {
        guard theme == .system else { return }
        objectWillChange.send()
    }

    var windowTitle: String {
        guard let document = selectedDocument else { return AppEnvironment.displayName }
        return "\(document.isDirty ? "● " : "")\(document.displayName) — \(AppEnvironment.displayName)"
    }

    var sidebarPresentation: SidebarPresentation {
        isSidebarVisible ? .pinned : .hidden
    }

    var isSidebarEffectivelyVisible: Bool {
        isSidebarVisible && !isDistractionFree
    }

    func toggleSidebar() {
        if isDistractionFree {
            toggleDistractionFree()
            isSidebarVisible = true
        } else {
            isSidebarVisible.toggle()
        }
    }

    func toggleFocusMode() { isFocusMode.toggle() }

    func toggleFocusScope(_ scope: FocusScope) {
        if isFocusMode && focusScope == scope { isFocusMode = false; return }
        focusScope = scope
        isFocusMode = true
    }

    /// Не переключается во время чтения/записи файла и незавершённого системного ввода.
    func toggleReadingMode() {
        guard let document = selectedDocument, document.ioState == .idle,
              !isOpeningPlaceholder(document),
              (hostWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        document.setReadingMode(!document.isReadingMode)
    }

    func toggleTypewriterMode() { isTypewriterMode.toggle() }

    func setViewMagnification(_ value: CGFloat) {
        guard value.isFinite else { return }
        viewMagnification = min(4, max(0.25, value))
    }

    func increaseViewMagnification() { setViewMagnification(viewMagnification * 1.2) }
    func decreaseViewMagnification() { setViewMagnification(viewMagnification / 1.2) }
    func resetViewMagnification() { setViewMagnification(1) }

    /// Палитра команд и быстрое открытие взаимно исключают друг друга; повторный вызов закрывает палитру.
    func showCommandPalette() {
        guard let window = hostWindow else { return }
        if commandPalette.isPresented { commandPalette.dismiss(); return }
        if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        folderSearch.cancelQuickOpen()
        commandPalette.present(menu: NSApp.mainMenu, preferences: preferences)
    }

    func showQuickOpen() {
        commandPalette.dismiss()
        folderSearch.requestQuickOpen()
    }

    func toggleDistractionFree() {
        if isDistractionFree {
            if let previousToolbarVisibility {
                distractionFreeToolbar?.isVisible = previousToolbarVisibility
            }
            distractionFreeToolbar = nil
            previousToolbarVisibility = nil
            isDistractionFree = false
        } else {
            let toolbar = hostWindow?.toolbar
            distractionFreeToolbar = toolbar
            previousToolbarVisibility = toolbar?.isVisible
            toolbar?.isVisible = false
            isDistractionFree = true
        }
    }

    func newDocument() {
        if let windowManager, hostWindow != nil {
            windowManager.openNativeTab(from: self)
            return
        }
        let document = EditorDocument()
        documents.append(document)
        selectedDocumentID = document.id
        observe(document)
    }

    func openFiles() {
        fileService.chooseFiles().forEach(openFile)
    }

    func openFolder() {
        guard let manager = windowManager, let window = hostWindow,
              manager.ownsVisibleState(self, window: window) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              manager.ownsVisibleState(self, window: window) else { return }
        openFolder(url)
    }

    @discardableResult
    func openFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              directory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
            sidebarFeedback.show(L10n.tr("无法打开文件夹"), symbol: "info.circle")
            return false
        }
        folderWorkspace.setRoot(url.resolvingSymlinksInPath())
        recentFiles.recordFolder(url)
        return true
    }

    func importDocument() {
        guard let manager = windowManager, let window = hostWindow,
              let document = selectedDocument else { return }
        let panel = NSOpenPanel()
        let formats = (PandocImportService.extensions + ["pdf"]).sorted().compactMap { fileExtension in
            UTType(filenameExtension: fileExtension).map { (fileExtension, $0) }
        }
        let extensions = formats.map(\.0)
        let types = formats.map(\.1)
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        formatPopup.addItem(withTitle: L10n.tr("所有支持的格式"))
        formatPopup.addItems(withTitles: extensions.map { ".\($0.uppercased())" })
        let formatFilter = ImportFormatFilterController(
            panel: panel,
            allTypes: types,
            individualTypes: types
        )
        formatPopup.target = formatFilter
        formatPopup.action = #selector(ImportFormatFilterController.selectFormat(_:))

        let formatLabel = NSTextField(labelWithString: L10n.tr("格式："))
        let accessory = NSStackView(views: [formatLabel, formatPopup])
        accessory.orientation = .horizontal
        accessory.alignment = .centerY
        accessory.spacing = 8
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let source = panel.url,
              manager.ownsVisibleState(self, window: window),
              documents.contains(where: { $0 === document }) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak manager, weak window, weak document] in
            let result = Result {
                source.pathExtension.lowercased() == "pdf"
                    ? try PDFImportService.convert(source: source)
                    : try PandocImportService.convert(source: source)
            }
            DispatchQueue.main.async {
                guard let self, let manager, let window, let document,
                      manager.ownsVisibleState(self, window: window),
                      self.documents.contains(where: { $0 === document }) else { return }
                switch result {
                case let .success(imported):
                    let importedDocument = EditorDocument(text: imported.text, language: .markdown,
                                                          isDirty: true, requiresExplicitSave: true)
                    if !imported.diagnostics.isEmpty {
                        importedDocument.statusMessage = L10n.tr("Pandoc 提示：%@", imported.diagnostics)
                    }
                    manager.openNativeTab(from: self, with: importedDocument)
                case let .failure(error):
                    self.presentError(title: L10n.tr("无法导入"), error: error)
                }
            }
        }
    }

    func openFile(_ url: URL) {
        if let windowManager {
            windowManager.openFile(url, preferredState: self)
            return
        }
        beginOpeningFile(url)
    }

    func beginOpeningFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        var retryPlaceholder: EditorDocument?
        if let existing = documents.first(where: {
            $0.fileIdentity?.matches(DocumentFileIdentity.resolve(normalized)) == true
        }) {
            selectedDocumentID = existing.id
            if case .failed = existing.ioState, openingPlaceholderIDs.contains(existing.id) {
                guard windowManager?.isRestorationPlaceholder(existing) != true else { return }
                _ = existing.synchronizedText()
                guard !existing.isDirty, !existing.hasPendingLiveEdits, existing.text.isEmpty else { return }
                retryPlaceholder = existing
                openingFileURLs.remove(normalized)
            } else {
                return
            }
        }
        guard openingFileURLs.insert(normalized).inserted else { return }

        let byteCount = (try? FileService.fileByteCount(at: normalized)) ?? 0
        let profile = DocumentPerformanceProfile.resolve(byteCount: byteCount)
        if profile == .extreme, !confirmOpeningExtremeFile(normalized, byteCount: byteCount) {
            openingFileURLs.remove(normalized)
            return
        }

        let placeholder: EditorDocument
        if let retryPlaceholder {
            placeholder = retryPlaceholder
            placeholder.ioState = .opening
            placeholder.updatePerformanceProfile(byteCount: byteCount, lineCount: 0)
        } else {
            placeholder = EditorDocument(
                url: normalized,
                language: EditorLanguage.infer(from: normalized),
                byteCount: byteCount,
                performanceProfile: profile
            )
            placeholder.ioState = .opening
            if documents.count == 1, let blank = documents.first, blank.isDisposableBlank {
                stopObserving(blank)
                documents.removeAll()
            }
            documents.append(placeholder)
            openingPlaceholderIDs.insert(placeholder.id)
            observe(placeholder)
        }
        selectedDocumentID = placeholder.id

        let readFile = self.readFile
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let readSignpostID = OSSignpostID(log: filePerformanceLog)
            os_signpost(
                .begin,
                log: filePerformanceLog,
                name: "FileOpen",
                signpostID: readSignpostID
            )
            let result = Result { try readFile(normalized) }
            os_signpost(
                .end,
                log: filePerformanceLog,
                name: "FileOpen",
                signpostID: readSignpostID
            )
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard operation?.isCancelled == false else { return }
                guard let self, let operation, self.openingOperations[normalized] === operation else { return }
                self.finishOpeningFile(normalized, operation: operation, result: result)
            }
        }
        openingOperations[normalized] = operation
        fileOpeningQueue.addOperation(operation)
    }

    private func finishOpeningFile(
        _ url: URL,
        operation: Operation,
        result: Result<PreparedFileRead, Error>
    ) {
        do {
            let prepared = try result.get()
            let decoded: DecodedFile
            switch prepared {
            case let .decoded(value):
                decoded = value
            case let .needsEncoding(data, byteCount, fileRevisionSnapshot):
                guard let choice = fileService.chooseEncoding(for: url) else {
                    guard openingOperations[url] === operation else { return }
                    openingFileURLs.remove(url)
                    openingOperations.removeValue(forKey: url)
                    removeOpeningPlaceholder(for: url)
                    return
                }
                guard openingOperations[url] === operation, !operation.isCancelled else { return }
                decodeOpeningFileInBackground(
                    data,
                    choice: choice,
                    byteCount: byteCount,
                    fileRevisionSnapshot: fileRevisionSnapshot,
                    url: url
                )
                return
            }
            openingFileURLs.remove(url)
            openingOperations.removeValue(forKey: url)
            insertOpenedFile(decoded, at: url)
        } catch CocoaError.userCancelled {
            openingFileURLs.remove(url)
            openingOperations.removeValue(forKey: url)
            removeOpeningPlaceholder(for: url)
            return
        } catch {
            openingFileURLs.remove(url)
            openingOperations.removeValue(forKey: url)
            if let placeholder = documents.first(where: {
                $0.url?.standardizedFileURL == url && $0.ioState == .opening
            }) {
                placeholder.ioState = .failed(error.localizedDescription)
            }
            presentError(title: L10n.tr("无法打开文件"), error: error)
        }
    }

    private func decodeOpeningFileInBackground(
        _ data: Data,
        choice: FileEncodingChoice,
        byteCount: Int,
        fileRevisionSnapshot: FileRevisionSnapshot,
        url: URL
    ) {
        openingFileURLs.insert(url)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result {
                try FileService.decode(
                    data,
                    encoding: choice.encoding,
                    encodingName: choice.name,
                    byteCount: byteCount,
                    fileRevisionSnapshot: fileRevisionSnapshot
                )
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self else { return }
                guard let operation, !operation.isCancelled, self.openingOperations[url] === operation else { return }
                self.openingFileURLs.remove(url)
                self.openingOperations.removeValue(forKey: url)
                do {
                    self.insertOpenedFile(try result.get(), at: url)
                } catch {
                    if let placeholder = self.documents.first(where: {
                        $0.url?.standardizedFileURL == url && $0.ioState == .opening
                    }) {
                        placeholder.ioState = .failed(error.localizedDescription)
                    }
                    self.presentError(title: L10n.tr("无法打开文件"), error: error)
                }
            }
        }
        openingOperations[url] = operation
        fileOpeningQueue.addOperation(operation)
    }

    func cancelOpening(_ document: EditorDocument) {
        if windowManager?.isRestorationPlaceholder(document) == true {
            close(document)
            return
        }
        guard document.ioState == .opening, let url = document.url else { return }
        let normalized = url.standardizedFileURL
        openingOperations.removeValue(forKey: normalized)?.cancel()
        openingFileURLs.remove(normalized)
        if openingPlaceholderIDs.contains(document.id) {
            removeOpeningPlaceholder(for: normalized)
        } else {
            document.ioState = .idle
        }
    }

    func finishRestoring(_ document: EditorDocument, snapshot: DocumentRecoverySnapshot, byteCount: Int, lineCount: Int) {
        guard documents.contains(where: { $0 === document }), openingPlaceholderIDs.contains(document.id),
              document.ioState == .opening else { return }
        document.text = snapshot.text
        document.updatePerformanceProfile(byteCount: byteCount, lineCount: lineCount)
        document.selectionRange = snapshot.selectionRange
        document.scrollPositionRatio = snapshot.scrollPositionRatio
        document.isPreviewVisible = snapshot.language == .markdown && snapshot.isPreviewVisible
            && document.performanceProfile == .standard
        if !snapshot.isDirty { document.markSaved(snapshot: snapshot.text, revision: document.textRevision) }
        openingPlaceholderIDs.remove(document.id)
        document.ioState = .idle
    }

    private func insertOpenedFile(_ decoded: DecodedFile, at url: URL) {
        if let existing = documents.first(where: {
            $0.url?.standardizedFileURL == url
        }) {
            if existing.ioState == .opening {
                _ = existing.synchronizedText()
                guard !existing.isDirty, !existing.hasPendingLiveEdits, existing.text.isEmpty else {
                    existing.ioState = .failed(L10n.tr("重新载入期间内容已变化，已保留本地修改"))
                    return
                }
                existing.text = decoded.text
                existing.updateFileEncoding(decoded.encoding)
                existing.updateFileRevisionSnapshot(
                    decoded.fileRevisionSnapshot
                )
                existing.ioState = .idle
                openingPlaceholderIDs.remove(existing.id)
                existing.updatePerformanceProfile(
                    byteCount: decoded.byteCount,
                    lineCount: decoded.lineCount
                )
                existing.markSaved()
                selectedDocumentID = existing.id
                recentFiles.record(url)
            } else {
                selectedDocumentID = existing.id
            }
            return
        }
        let document = EditorDocument(
            text: decoded.text,
            url: url,
            language: EditorLanguage.infer(from: url),
            fileEncoding: decoded.encoding,
            fileRevisionSnapshot: decoded.fileRevisionSnapshot,
            byteCount: decoded.byteCount,
            lineCount: decoded.lineCount
        )
        if documents.count == 1,
           let first = documents.first,
           first.isDisposableBlank {
            stopObserving(first)
            documents.removeAll()
        }
        documents.append(document)
        selectedDocumentID = document.id
        recentFiles.record(url)
        observe(document)
    }

    var canShowVersionHistory: Bool {
        guard let document = selectedDocument else { return false }
        return document.url != nil && document.ioState == .idle && !isOpeningPlaceholder(document)
    }

    func presentVersionHistory(mode: VersionHistoryController.Mode) {
        guard canShowVersionHistory, versionHistorySheet == nil,
              let document = selectedDocument, let url = document.url,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        let controller = VersionHistoryController(document: document, url: url, mode: mode) { [weak self, weak document] text, base in
            guard let self, let document else { return L10n.tr("当前文本无法修改") }
            return self.applyVersionRestore(text, to: document, base: base)
        }
        controller.onRestored = { [weak self, weak document] in
            self?.closeVersionHistory()
            document?.statusMessage = L10n.tr("已恢复历史版本，尚未保存")
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: VersionHistoryView(
            controller: controller,
            fileName: url.lastPathComponent,
            close: { [weak self] in self?.closeVersionHistory() }
        )))
        sheet.styleMask.remove(.closable)
        versionHistorySheet = sheet
        window.beginSheet(sheet)
    }

    private func closeVersionHistory() {
        guard let sheet = versionHistorySheet else { return }
        versionHistorySheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    /// Заменяет весь текст версией одной заменой редактора; файл на диске не пишется.
    /// Возвращает текст ошибки или nil при успехе.
    private func applyVersionRestore(_ text: String, to document: EditorDocument, base: DocumentTextSnapshot) -> String? {
        guard selectedDocument === document, document.ioState == .idle, !document.hasPendingLiveEdits,
              document.synchronizedSnapshot() == base else { return L10n.tr("文档已更改，比较结果已过期") }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false,
            allowsWholeDocument: true, requiresEditable: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let current = extraction.result else { return L10n.tr("当前文本无法修改") }
        let request = EditorRangeReplacementRequest(
            documentID: document.id,
            range: NSRange(location: 0, length: (base.text as NSString).length),
            originalText: base.text,
            replacementText: text,
            expectedEditorRevision: current.editorRevision,
            actionName: L10n.tr("恢复历史版本")
        )
        let newLength = (text as NSString).length
        let location = min(document.selectionRange.location, newLength)
        request.resultingSelection = NSRange(location: location, length: min(document.selectionRange.length, newLength - location))
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        return request.wasHandled ? nil : (request.failureMessage ?? L10n.tr("当前文本无法修改"))
    }

    @discardableResult
    func save(_ document: EditorDocument? = nil) -> Bool {
        guard let document = document ?? selectedDocument else { return false }
        if let url = document.url {
            return write(document, to: url)
        }
        return saveAs(document)
    }

    @discardableResult
    func saveAs(_ document: EditorDocument? = nil) -> Bool {
        guard let document = document ?? selectedDocument else { return false }
        return saveAs(document, encoding: document.fileEncoding, completion: nil)
    }

    private func saveAs(
        _ document: EditorDocument,
        encoding: String.Encoding,
        completion: ((Bool) -> Void)?
    ) -> Bool {
        guard !openingPlaceholderIDs.contains(document.id) else {
            completion?(false)
            return false
        }
        guard let url = fileService.chooseSaveURL(
            suggestedName: suggestedFilename(for: document)
        ) else {
            completion?(false)
            return false
        }
        if let conflict = windowManager?.conflictingDocument(
            at: url,
            excluding: document.id
        ) {
            windowManager?.focus(conflict.document, in: conflict.state)
            let error = NSError(
                domain: "LacEditor",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("该文件已在 LacEditor 的另一个标签中打开。")]
            )
            presentError(title: L10n.tr("无法另存为"), error: error)
            completion?(false)
            return false
        }
        document.updateFileEncoding(encoding)
        return write(document, to: url, completion: completion)
    }

    private func prepareExportImages(snapshot: DocumentTextSnapshot, document: EditorDocument, source: URL?,
                                     operation: BlockOperation, syntax: MarkdownSyntaxOptions, includeMath: Bool = true,
                                     completion: @escaping (Result<String, Error>) -> Void) {
        let token = UUID()
        let dark = hostWindow?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fontSize = preferences.markdownTypography?.fontSize ?? 16
        let options = MathJaxRenderService.Options(physics: preferences.mathPhysicsEnabled, numbering: preferences.mathNumbering)
        let service = MarkdownExportImagesService(source: snapshot.text, width: 760, dark: dark, fontSize: fontSize,
            mathOptions: options, syntax: syntax, includeMath: includeMath, isCurrent: { [weak self, weak document] in
                guard let self, let document, !operation.isCancelled, self.selectedDocument === document,
                      self.documents.contains(where: { $0 === document }), document.language == .markdown,
                      document.ioState == .idle, document.url == source else { return false }
                return document.synchronizedSnapshot().revision == snapshot.revision
            }) { [weak self] result in
                guard let self else { completion(.failure(CancellationError())); return }
                guard self.imageExportPreparations[snapshot.documentID]?.0 == token else { return }
                self.imageExportPreparations.removeValue(forKey: snapshot.documentID)
                completion(result)
            }
        imageExportPreparations[snapshot.documentID] = (token, service)
        service.start()
    }

    func exportMarkdown(as format: PandocExportFormat) {
        exportMarkdown(as: format, destination: nil, expectedRevision: nil)
    }

    private func exportMarkdown(as format: PandocExportFormat, destination fixedDestination: URL?, expectedRevision: FileRevisionSnapshot?, nativeOptions: MarkdownNativeExportOptions? = nil, pdfHeaders: MarkdownPDFHeaderFooterOptions? = nil, htmlOptions: MarkdownHTMLExportOptions? = nil) {
        guard let document = selectedDocument, document.language == .markdown,
              document.ioState == .idle, !exportingDocumentIDs.contains(document.id),
              !openingPlaceholderIDs.contains(document.id) else { return }
        let manager = windowManager
        guard manager?.beginMarkdownExport(documentID: document.id) ?? true else { return }
        exportingDocumentIDs.insert(document.id)
        var started = false
        defer {
            if !started {
                exportingDocumentIDs.remove(document.id)
                manager?.endMarkdownExport(documentID: document.id)
            }
        }
        let baseName = document.url?.deletingPathExtension().lastPathComponent ?? L10n.tr("未命名")
        let destination: URL
        if let fixedDestination { destination = fixedDestination }
        else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = baseName + "." + format.fileExtension
            if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard documents.contains(where: { $0 === document }),
              document.language == .markdown, document.ioState == .idle else { return }
        if let expectedRevision, (try? FileRevisionSnapshot.capture(destination)) != expectedRevision {
            presentError(title: L10n.tr("无法导出"), error: CocoaError(.fileWriteFileExists)); return
        }
        let source = document.url
        let openURLs = manager?.openDocumentURLs ?? documents.compactMap(\.url)
        guard !PandocExportService.conflicts(destination: destination, source: source, openURLs: openURLs) else {
            presentError(title: L10n.tr("无法导出"), error: PandocExportError.openDocument)
            return
        }
        let snapshot = document.synchronizedSnapshot()
        if format == .htmlPlain {
            guard hostWindow != nil else { return }
            started = true
            let options = htmlOptions ?? preferences.markdownHTMLExportOptions
            startNativeMarkdownOutput(document: document, snapshot: snapshot, destination: destination, mode: .htmlPlain,
                                      previousKind: .htmlPlain(options), htmlOptions: options)
            return
        }
        if format == .pdf {
            guard hostWindow != nil else { return }
            started = true
            let options = nativeOptions ?? preferences.markdownNativeExportOptions
            let headers = pdfHeaders ?? preferences.markdownPDFHeaderFooterOptions
            startNativeMarkdownOutput(document: document, snapshot: snapshot, destination: destination, mode: .pdf,
                                      previousKind: .pdf(options, headers), options: options, headers: headers)
            return
        }
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
        let destinationRevision = try? FileRevisionSnapshot.capture(destination)
        guard !destinationExisted || destinationRevision != nil else {
            presentError(title: L10n.tr("无法导出"), error: CocoaError(.fileReadUnknown)); return
        }
        started = true
        document.statusMessage = L10n.tr("正在导出…")
        let savedHTMLOptions = htmlOptions ?? preferences.markdownHTMLExportOptions
        let syntax = preferences.markdownSyntax
        let wiki = MarkdownWikiLinkSource(root: folderWorkspace.rootURL, documentURL: source)
        let needsImages = [.html, .docx, .odt, .rtf, .epub, .fb2, .latex].contains(format)
        let operation = BlockOperation()
        if needsImages { customExportOperations[document.id] = operation; imageExportDocuments.insert(document.id) }
        func runExport(_ preparedText: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result {
                let prepared = try PandocExportService.prepare(
                    text: preparedText, source: source, destination: destination, format: format,
                    title: baseName, isCancelled: { operation.isCancelled }, htmlOptions: savedHTMLOptions, syntax: syntax, wiki: wiki
                )
                guard prepared.latexAssets != nil else { return (prepared, false) }
                do {
                    @MainActor func validateCurrent() throws {
                        guard !operation.isCancelled, selectedDocument === document, document.url == source,
                              document.synchronizedSnapshot().revision == snapshot.revision else { throw CancellationError() }
                        let openURLs = manager?.openDocumentURLs ?? documents.compactMap(\.url)
                        guard !PandocExportService.conflicts(destination: destination, source: source, openURLs: openURLs) else { throw PandocExportError.openDocument }
                        let exists = FileManager.default.fileExists(atPath: destination.path)
                        guard exists == destinationExisted,
                              !exists || (try? FileRevisionSnapshot.capture(destination)) == destinationRevision else { throw CocoaError(.fileWriteFileExists) }
                    }
                    try PandocExportService.install(prepared, at: destination, isCancelled: { operation.isCancelled }, commit: { verifySidecar in
                        try DispatchQueue.main.sync {
                            if let assets = prepared.latexAssets { self.latexExportWillCommit?(destination.deletingLastPathComponent().appendingPathComponent(assets.directoryName)) }
                            try validateCurrent()
                            try verifySidecar()
                            try PandocExportService.install(prepared.preparedURL, at: destination)
                        }
                    }) { try DispatchQueue.main.sync { try validateCurrent() } }
                    return (prepared, true)
                } catch {
                    try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent())
                    throw error
                }
            }
            DispatchQueue.main.async { [self] in
                exportingDocumentIDs.remove(document.id)
                if needsImages { imageExportDocuments.remove(document.id) }
                if customExportOperations[document.id] === operation { customExportOperations.removeValue(forKey: document.id) }
                manager?.endMarkdownExport(documentID: document.id)
                let owner = manager?.stateContaining(document)
                let isOpen = owner != nil || (manager == nil && documents.contains(where: { $0 === document }))
                @MainActor func report(_ error: Error) {
                    if !isOpen {
                        if let exportError = error as? PandocExportError, case .incompleteLatexAssets = exportError {
                            presentError(title: L10n.tr("无法导出"), error: error)
                        }
                        return
                    }
                    document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                    if let window = (owner ?? self).hostWindow {
                        let alert = NSAlert(error: error)
                        alert.messageText = L10n.tr("无法导出")
                        alert.beginSheetModal(for: window)
                    }
                }
                switch result {
                case let .failure(error):
                    if let exportError = error as? PandocExportError, case .incompleteLatexAssets = exportError { report(error); return }
                    if operation.isCancelled || error is CancellationError { return }
                    report(error)
                case let .success((prepared, installed)):
                    defer { try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent()) }
                    if needsImages && !installed {
                        guard !operation.isCancelled else { return }
                        guard selectedDocument === document, document.url == source,
                              document.synchronizedSnapshot().revision == snapshot.revision else {
                            if isOpen { document.statusMessage = L10n.tr("文档已更改，导出已取消。") }
                            return
                        }
                    }
                    do {
                        if !installed {
                            let openURLs = manager?.openDocumentURLs ?? documents.compactMap(\.url)
                            guard !PandocExportService.conflicts(destination: destination, source: source, openURLs: openURLs) else {
                                throw PandocExportError.openDocument
                            }
                            let currentExists = FileManager.default.fileExists(atPath: destination.path)
                            guard currentExists == destinationExisted,
                                  !currentExists || (try? FileRevisionSnapshot.capture(destination)) == destinationRevision else {
                                throw CocoaError(.fileWriteFileExists)
                            }
                            try PandocExportService.install(prepared.preparedURL, at: destination)
                        }
                        if self.documents.contains(where: { $0 === document }), let revision = try? FileRevisionSnapshot.capture(destination) {
                            self.previousMarkdownExports[document.id] = PreviousMarkdownExport(kind: format == .html ? .html(savedHTMLOptions) : .standard(format), destination: destination, revision: revision)
                        }
                        if isOpen {
                            let message: String
                            if format == .latex {
                                message = L10n.tr("导出完成。LaTeX 中的相对图片路径基于原始文件文件夹。")
                            } else { message = L10n.tr("导出完成") }
                            document.statusMessage = prepared.diagnostics.isEmpty
                                ? message
                                : message + " " + L10n.tr("Pandoc 提示：%@", prepared.diagnostics)
                        }
                    } catch {
                        report(error)
                    }
                }
            }
        }
        }
        if needsImages {
            prepareExportImages(snapshot: snapshot, document: document, source: source, operation: operation, syntax: syntax, includeMath: format != .latex) { [weak self, weak document] result in
                guard let self else { manager?.endMarkdownExport(documentID: snapshot.documentID); return }
                switch result {
                case let .success(text): runExport(text)
                case let .failure(error):
                    if self.customExportOperations[snapshot.documentID] === operation {
                        self.customExportOperations.removeValue(forKey: snapshot.documentID)
                        self.exportingDocumentIDs.remove(snapshot.documentID)
                        self.imageExportDocuments.remove(snapshot.documentID)
                    }
                    manager?.endMarkdownExport(documentID: snapshot.documentID)
                    if !operation.isCancelled, let document, self.documents.contains(where: { $0 === document }) {
                        document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                        self.presentError(title: L10n.tr("无法导出"), error: error)
                    }
                }
            }
        } else { runExport(snapshot.text) }
    }

    func exportMarkdown(profile: MarkdownExportProfile) {
        exportMarkdown(profile: profile, destination: nil, expectedRevision: nil)
    }

    func exportMarkdown(profile: MarkdownExportProfile, destination fixedDestination: URL?, expectedRevision: FileRevisionSnapshot?, htmlOptions: MarkdownHTMLExportOptions? = nil) {
        if profile.kind == "command" || profile.kind == "pdf-engine" {
            exportMarkdownCommand(profile: profile, destination: fixedDestination, expectedRevision: expectedRevision)
            return
        }
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              !exportingDocumentIDs.contains(document.id), !openingPlaceholderIDs.contains(document.id) else { return }
        let manager = windowManager
        guard manager?.beginMarkdownExport(documentID: document.id) ?? true else { return }
        exportingDocumentIDs.insert(document.id)
        var started = false
        defer {
            if !started {
                exportingDocumentIDs.remove(document.id)
                manager?.endMarkdownExport(documentID: document.id)
            }
        }
        let baseName = document.url?.deletingPathExtension().lastPathComponent ?? L10n.tr("未命名")
        let destination: URL
        if let fixedDestination { destination = fixedDestination }
        else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = baseName + (profile.extensions.first.map { "." + $0 } ?? "")
            panel.allowedContentTypes = profile.extensions.compactMap { UTType(filenameExtension: $0) }
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard selectedDocument === document, document.language == .markdown, document.ioState == .idle else { return }
        let source = document.url
        let openURLs = manager?.openDocumentURLs ?? documents.compactMap(\.url)
        guard !PandocExportService.conflicts(destination: destination, source: source, openURLs: openURLs) else {
            presentError(title: L10n.tr("无法导出"), error: PandocExportError.openDocument); return
        }
        let existed = FileManager.default.fileExists(atPath: destination.path)
        let revision = try? FileRevisionSnapshot.capture(destination)
        guard (!existed || revision != nil), expectedRevision == nil || expectedRevision == revision else {
            presentError(title: L10n.tr("无法导出"), error: CocoaError(.fileWriteFileExists)); return
        }
        let snapshot = document.synchronizedSnapshot()
        let operation = BlockOperation()
        customExportOperations[document.id] = operation
        started = true
        document.statusMessage = L10n.tr("正在导出…")
        let writer = String(profile.writer.prefix { $0 != "+" && $0 != "-" }).lowercased()
        let inferred = destination.pathExtension.lowercased()
        let isHTML = writer.isEmpty ? ["html", "htm"].contains(inferred) : ["html", "html4", "html5"].contains(writer)
        let isLatex = writer.isEmpty ? ["tex", "latex"].contains(inferred) : writer == "latex"
        let savedHTMLOptions = htmlOptions ?? preferences.markdownHTMLExportOptions
        let syntax = preferences.markdownSyntax
        let wiki = MarkdownWikiLinkSource(root: folderWorkspace.rootURL, documentURL: source)
        let needsImages = isLatex || (profile.rawType.isEmpty && (writer.isEmpty
            ? ["html", "htm", "docx", "odt", "rtf", "fb2", "epub", "pptx"].contains(inferred)
            : ["html", "html4", "html5", "docx", "odt", "rtf", "fb2", "epub", "epub2", "epub3", "pptx"].contains(writer)))
        if needsImages { imageExportDocuments.insert(document.id) }
        func runProfileExport(_ preparedText: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self, document] in
            let result = Result {
                let prepared = try PandocExportService.prepare(text: preparedText, source: source, destination: destination,
                    profile: profile, title: baseName, isCancelled: { operation.isCancelled }, htmlOptions: isHTML ? savedHTMLOptions : nil, syntax: syntax, wiki: wiki)
                guard prepared.latexAssets != nil else { return (prepared, false) }
                do {
                    @MainActor func validateCurrent() throws {
                        guard !operation.isCancelled, self.selectedDocument === document, document.url == source,
                              document.synchronizedSnapshot().revision == snapshot.revision else { throw CancellationError() }
                        let openURLs = manager?.openDocumentURLs ?? self.documents.compactMap(\.url)
                        guard !PandocExportService.conflicts(destination: destination, source: source, openURLs: openURLs) else { throw PandocExportError.openDocument }
                        let currentExists = FileManager.default.fileExists(atPath: destination.path)
                        guard currentExists == existed,
                              !currentExists || (try? FileRevisionSnapshot.capture(destination)) == revision else { throw CocoaError(.fileWriteFileExists) }
                    }
                    try PandocExportService.install(prepared, at: destination, isCancelled: { operation.isCancelled }, commit: { verifySidecar in
                        try DispatchQueue.main.sync {
                            if let assets = prepared.latexAssets { self.latexExportWillCommit?(destination.deletingLastPathComponent().appendingPathComponent(assets.directoryName)) }
                            try validateCurrent()
                            try verifySidecar()
                            try PandocExportService.install(prepared.preparedURL, at: destination)
                        }
                    }) { try DispatchQueue.main.sync { try validateCurrent() } }
                    return (prepared, true)
                } catch {
                    try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent())
                    throw error
                }
            }
            DispatchQueue.main.async { [self, document] in
                manager?.endMarkdownExport(documentID: snapshot.documentID)
                if self.customExportOperations[snapshot.documentID] === operation {
                    self.customExportOperations.removeValue(forKey: snapshot.documentID)
                    self.exportingDocumentIDs.remove(snapshot.documentID)
                    self.imageExportDocuments.remove(snapshot.documentID)
                }
                guard self.documents.contains(where: { $0 === document }) else {
                    if case let .success((prepared, _)) = result { try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent()) }
                    if case let .failure(error) = result, let exportError = error as? PandocExportError,
                       case .incompleteLatexAssets = exportError { self.presentError(title: L10n.tr("无法导出"), error: error) }
                    return
                }
                switch result {
                case let .failure(error):
                    if error is CancellationError { return }
                    document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                    self.presentError(title: L10n.tr("无法导出"), error: error)
                case let .success((prepared, installed)):
                    defer { try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent()) }
                    if !installed && operation.isCancelled { return }
                    if needsImages && !installed {
                        guard self.selectedDocument === document, document.url == source,
                              document.synchronizedSnapshot().revision == snapshot.revision else {
                            document.statusMessage = L10n.tr("文档已更改，导出已取消。")
                            return
                        }
                    }
                    do {
                        if !installed {
                            let openURLs = manager?.openDocumentURLs ?? self.documents.compactMap(\.url)
                            guard !PandocExportService.conflicts(destination: destination, source: source, openURLs: openURLs) else {
                                throw PandocExportError.openDocument
                            }
                            let currentExists = FileManager.default.fileExists(atPath: destination.path)
                            guard currentExists == existed, !currentExists || (try? FileRevisionSnapshot.capture(destination)) == revision else {
                                throw CocoaError(.fileWriteFileExists)
                            }
                            try PandocExportService.install(prepared.preparedURL, at: destination)
                        }
                        if let revision = try? FileRevisionSnapshot.capture(destination) {
                            self.previousMarkdownExports[document.id] = PreviousMarkdownExport(kind: isHTML ? .htmlProfile(profile, savedHTMLOptions) : .profile(profile), destination: destination, revision: revision)
                        }
                        document.statusMessage = prepared.diagnostics.isEmpty ? L10n.tr("导出完成") : L10n.tr("导出完成") + " " + L10n.tr("Pandoc 提示：%@", prepared.diagnostics)
                    } catch {
                        document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                        self.presentError(title: L10n.tr("无法导出"), error: error)
                    }
                }
            }
        }
        }
        if needsImages {
            prepareExportImages(snapshot: snapshot, document: document, source: source, operation: operation, syntax: syntax, includeMath: !isLatex) { [weak self, weak document] result in
                guard let self else { manager?.endMarkdownExport(documentID: snapshot.documentID); return }
                switch result {
                case let .success(text): runProfileExport(text)
                case let .failure(error):
                    if self.customExportOperations[snapshot.documentID] === operation {
                        self.customExportOperations.removeValue(forKey: snapshot.documentID)
                        self.exportingDocumentIDs.remove(snapshot.documentID)
                        self.imageExportDocuments.remove(snapshot.documentID)
                    }
                    manager?.endMarkdownExport(documentID: snapshot.documentID)
                    if !operation.isCancelled, let document, self.documents.contains(where: { $0 === document }) {
                        document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                        self.presentError(title: L10n.tr("无法导出"), error: error)
                    }
                }
            }
        } else { runProfileExport(snapshot.text) }
    }

    private func exportMarkdownCommand(profile: MarkdownExportProfile, destination fixedDestination: URL?, expectedRevision: FileRevisionSnapshot?) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              !exportingDocumentIDs.contains(document.id), !openingPlaceholderIDs.contains(document.id) else { return }
        let manager = windowManager
        guard manager?.beginMarkdownExport(documentID: document.id) ?? true else { return }
        exportingDocumentIDs.insert(document.id)
        var started = false
        defer {
            if !started {
                exportingDocumentIDs.remove(document.id)
                manager?.endMarkdownExport(documentID: document.id)
            }
        }
        let mode = profile.kind == "pdf-engine" ? "file" : (profile.commandDestination ?? "file")
        let destination: CustomMarkdownExportService.Destination
        let chosenURL: URL?
        switch mode {
        case "file":
            let url: URL
            if let fixedDestination { url = fixedDestination }
            else {
                let panel = NSSavePanel()
                let name = document.url?.deletingPathExtension().lastPathComponent ?? L10n.tr("未命名")
                panel.nameFieldStringValue = name + (profile.extensions.first.map { "." + $0 } ?? "")
                panel.allowedContentTypes = profile.extensions.compactMap { UTType(filenameExtension: $0) }
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let selected = panel.url else { return }
                url = selected
            }
            destination = .file(url)
            chosenURL = url
        case "folder":
            let url: URL
            if let fixedDestination { url = fixedDestination }
            else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let selected = panel.url else { return }
                url = selected
            }
            destination = .folder(url)
            chosenURL = url
        case "none": destination = .none; chosenURL = nil
        default:
            presentError(title: L10n.tr("无法导出"), error: PandocExportError.invalidConfiguration(L10n.tr("不支持的命令输出方式")))
            return
        }
        guard selectedDocument === document, document.language == .markdown, document.ioState == .idle else { return }
        let source = document.url
        var existed = false
        var revision: FileRevisionSnapshot?
        if case let .file(url) = destination {
            let openURLs = manager?.openDocumentURLs ?? documents.compactMap(\.url)
            guard !PandocExportService.conflicts(destination: url, source: source, openURLs: openURLs) else {
                presentError(title: L10n.tr("无法导出"), error: PandocExportError.openDocument); return
            }
            existed = FileManager.default.fileExists(atPath: url.path)
            revision = try? FileRevisionSnapshot.capture(url)
            guard (!existed || revision != nil), expectedRevision == nil || expectedRevision == revision else {
                presentError(title: L10n.tr("无法导出"), error: CocoaError(.fileWriteFileExists)); return
            }
        }
        let snapshot = document.synchronizedSnapshot()
        let expectedExists = existed, initialRevision = revision
        let syntax = preferences.markdownSyntax
        let wiki = MarkdownWikiLinkSource(root: folderWorkspace.rootURL, documentURL: source)
        let operation = BlockOperation()
        customExportOperations[document.id] = operation
        let preparesDiagrams = profile.kind == "pdf-engine"
        if preparesDiagrams { imageExportDocuments.insert(document.id) }
        started = true
        document.statusMessage = L10n.tr("正在导出…")
        func runCommand(_ preparedText: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak document] in
            let result = Swift.Result {
                if profile.kind == "pdf-engine", case let .file(url) = destination {
                    return try CustomMarkdownExportService.preparePDFEngine(text: preparedText, source: source, destination: url,
                        profile: profile, isCancelled: { operation.isCancelled }, syntax: syntax,
                        extractEmbeddedMedia: !preparedText.utf16.elementsEqual(snapshot.text.utf16), wiki: wiki)
                }
                return try CustomMarkdownExportService.prepare(text: snapshot.text, source: source, destination: destination,
                                                               command: profile.command ?? "", isCancelled: { operation.isCancelled })
            }
            DispatchQueue.main.async { [weak self, weak document] in
                manager?.endMarkdownExport(documentID: snapshot.documentID)
                guard let self else {
                    if case let .success(output) = result, let prepared = output.preparedURL { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
                    return
                }
                if self.customExportOperations[snapshot.documentID] === operation {
                    self.customExportOperations.removeValue(forKey: snapshot.documentID)
                    self.exportingDocumentIDs.remove(snapshot.documentID)
                    if preparesDiagrams { self.imageExportDocuments.remove(snapshot.documentID) }
                }
                guard let document else {
                    if case let .success(output) = result, let prepared = output.preparedURL { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
                    return
                }
                guard self.documents.contains(where: { $0 === document }) else {
                    if case let .success(output) = result, let prepared = output.preparedURL { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
                    return
                }
                switch result {
                case let .failure(error):
                    if error is CancellationError { return }
                    document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                    self.presentError(title: L10n.tr("无法导出"), error: error)
                case let .success(output):
                    defer { if let prepared = output.preparedURL { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) } }
                    guard !operation.isCancelled else { return }
                    guard self.selectedDocument === document, document.synchronizedSnapshot().revision == snapshot.revision,
                          !preparesDiagrams || document.url == source else {
                        document.statusMessage = L10n.tr("文档已更改；命令可能已经执行。")
                        return
                    }
                    do {
                        var installedRevision: FileRevisionSnapshot?
                        if case let .file(url) = destination {
                            guard let prepared = output.preparedURL else { throw CocoaError(.fileReadUnknown) }
                            let openURLs = manager?.openDocumentURLs ?? self.documents.compactMap(\.url)
                            guard !PandocExportService.conflicts(destination: url, source: source, openURLs: openURLs) else { throw PandocExportError.openDocument }
                            let currentExists = FileManager.default.fileExists(atPath: url.path)
                            guard currentExists == expectedExists, !currentExists || (try? FileRevisionSnapshot.capture(url)) == initialRevision else {
                                throw CocoaError(.fileWriteFileExists)
                            }
                            try PandocExportService.install(prepared, at: url)
                            installedRevision = try? FileRevisionSnapshot.capture(url)
                        }
                        if mode != "file" || installedRevision != nil {
                            self.previousMarkdownExports[document.id] = PreviousMarkdownExport(kind: .profile(profile), destination: chosenURL, revision: installedRevision)
                        }
                        document.statusMessage = output.stderr.isEmpty ? L10n.tr("导出完成") : L10n.tr("导出完成") + " " + output.stderr
                        if profile.showCommandOutput == true {
                            let alert = NSAlert()
                            alert.messageText = L10n.tr("命令输出")
                            alert.informativeText = output.stdout
                            if let window = self.hostWindow { alert.beginSheetModal(for: window) }
                            else { alert.runModal() }
                        }
                    } catch {
                        document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                        self.presentError(title: L10n.tr("无法导出"), error: error)
                    }
                }
            }
        }
        }
        if preparesDiagrams {
            prepareExportImages(snapshot: snapshot, document: document, source: source, operation: operation, syntax: syntax, includeMath: false) { [weak self, weak document] result in
                guard let self else { manager?.endMarkdownExport(documentID: snapshot.documentID); return }
                switch result {
                case let .success(text): runCommand(text)
                case let .failure(error):
                    if self.customExportOperations[snapshot.documentID] === operation {
                        self.customExportOperations.removeValue(forKey: snapshot.documentID)
                        self.exportingDocumentIDs.remove(snapshot.documentID)
                        self.imageExportDocuments.remove(snapshot.documentID)
                    }
                    manager?.endMarkdownExport(documentID: snapshot.documentID)
                    if !operation.isCancelled, let document, self.documents.contains(where: { $0 === document }) {
                        document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                        self.presentError(title: L10n.tr("无法导出"), error: error)
                    }
                }
            }
        } else { runCommand(snapshot.text) }
    }

    var hasPreviousMarkdownExport: Bool {
        guard let id = selectedDocument?.id else { return false }
        return previousMarkdownExports[id] != nil
    }

    func repeatMarkdownExport(overwrite: Bool) {
        guard let document = selectedDocument, let previous = previousMarkdownExports[document.id] else { return }
        let destination = overwrite ? previous.destination : nil
        let revision = overwrite ? previous.revision : nil
        switch previous.kind {
        case let .profile(profile): exportMarkdown(profile: profile, destination: destination, expectedRevision: revision)
        case let .htmlProfile(profile, options): exportMarkdown(profile: profile, destination: destination, expectedRevision: revision, htmlOptions: options)
        case let .standard(format): exportMarkdown(as: format, destination: destination, expectedRevision: revision)
        case let .html(options): exportMarkdown(as: .html, destination: destination, expectedRevision: revision, htmlOptions: options)
        case let .htmlPlain(options): exportMarkdown(as: .htmlPlain, destination: destination, expectedRevision: revision, htmlOptions: options)
        case let .pdf(options, headers): exportMarkdown(as: .pdf, destination: destination, expectedRevision: revision, nativeOptions: options, pdfHeaders: headers)
        case let .image(options): exportMarkdownImage(destination: destination, expectedRevision: revision, nativeOptions: options)
        }
    }

    func exportMarkdownImage() {
        exportMarkdownImage(destination: nil, expectedRevision: nil)
    }

    private func exportMarkdownImage(destination fixedDestination: URL?, expectedRevision: FileRevisionSnapshot?, nativeOptions: MarkdownNativeExportOptions? = nil) {
        guard let document = selectedDocument, document.language == .markdown,
              document.ioState == .idle, !exportingDocumentIDs.contains(document.id),
              !openingPlaceholderIDs.contains(document.id), hostWindow != nil else { return }
        let manager = windowManager
        guard manager?.beginMarkdownExport(documentID: document.id) ?? true else { return }
        exportingDocumentIDs.insert(document.id)
        var started = false
        defer {
            if !started {
                exportingDocumentIDs.remove(document.id)
                manager?.endMarkdownExport(documentID: document.id)
            }
        }
        let destination: URL
        if let fixedDestination { destination = fixedDestination }
        else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (document.url?.deletingPathExtension().lastPathComponent ?? L10n.tr("未命名")) + ".png"
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        guard selectedDocument === document, document.language == .markdown, document.ioState == .idle else { return }
        if let expectedRevision, (try? FileRevisionSnapshot.capture(destination)) != expectedRevision {
            presentError(title: L10n.tr("无法导出"), error: CocoaError(.fileWriteFileExists)); return
        }
        let openURLs = manager?.openDocumentURLs ?? documents.compactMap(\.url)
        guard !PandocExportService.conflicts(destination: destination, source: document.url, openURLs: openURLs) else {
            presentError(title: L10n.tr("无法导出"), error: PandocExportError.openDocument)
            return
        }
        let snapshot = document.synchronizedSnapshot()
        started = true
        let options = nativeOptions ?? preferences.markdownNativeExportOptions
        startNativeMarkdownOutput(document: document, snapshot: snapshot, destination: destination, mode: .png, previousKind: .image(options), options: options)
    }

    func printMarkdown() {
        guard let document = selectedDocument, document.language == .markdown,
              document.ioState == .idle, !exportingDocumentIDs.contains(document.id),
              !openingPlaceholderIDs.contains(document.id), let window = hostWindow else { return }
        let manager = windowManager
        guard manager?.beginMarkdownExport(documentID: document.id) ?? true else { return }
        exportingDocumentIDs.insert(document.id)
        let initial = document.synchronizedSnapshot()
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.orientation = .portrait
        let panel = NSPrintPanel()
        panel.beginSheet(using: info, on: window) { [weak self, weak document] result in
            guard let self, let document else {
                manager?.endMarkdownExport(documentID: initial.documentID)
                return
            }
            var started = false
            defer {
                if !started {
                    self.exportingDocumentIDs.remove(document.id)
                    manager?.endMarkdownExport(documentID: document.id)
                }
            }
            guard result == .printed, self.hostWindow === window, self.selectedDocument === document,
                  document.language == .markdown, document.ioState == .idle,
                  document.synchronizedSnapshot().revision == initial.revision else { return }
            let destination: URL?
            if info.jobDisposition == .spool { destination = nil }
            else if info.jobDisposition == .save,
                    let url = info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL, url.isFileURL {
                destination = url
                let openURLs = manager?.openDocumentURLs ?? self.documents.compactMap(\.url)
                guard !PandocExportService.conflicts(destination: url, source: document.url, openURLs: openURLs) else {
                    self.presentError(title: L10n.tr("无法导出"), error: PandocExportError.openDocument)
                    return
                }
            } else {
                self.presentError(title: L10n.tr("无法打印"), error: MarkdownPDFExportService.ExportError.unsupportedPrintDestination)
                return
            }
            started = true
            self.startNativeMarkdownOutput(document: document, snapshot: initial, destination: destination, mode: .printJob(info),
                                           options: self.preferences.markdownNativeExportOptions,
                                           headers: self.preferences.markdownPDFHeaderFooterOptions)
        }
    }

    /// Печать и PDF всегда светлые, чтобы не заливать бумагу тёмным фоном; PNG и HTML повторяют тему окна.
    static func markdownOutputUsesDarkMode(for mode: MarkdownPDFExportService.Mode, windowIsDark: Bool) -> Bool {
        switch mode {
        case .pdf, .printJob: return false
        case .png, .htmlPlain: return windowIsDark
        }
    }

    private func startNativeMarkdownOutput(document: EditorDocument, snapshot: DocumentTextSnapshot,
                                           destination: URL?, mode: MarkdownPDFExportService.Mode,
                                           previousKind: PreviousMarkdownExportKind? = nil,
                                           options: MarkdownNativeExportOptions = .init(),
                                           headers: MarkdownPDFHeaderFooterOptions = .init(),
                                           htmlOptions: MarkdownHTMLExportOptions = .init()) {
        guard let window = hostWindow else {
            exportingDocumentIDs.remove(document.id)
            windowManager?.endMarkdownExport(documentID: document.id)
            return
        }
        let manager = windowManager
        let source = document.url
        let destinationExisted = destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let destinationRevision = destination.flatMap { try? FileRevisionSnapshot.capture($0) }
        if destinationExisted && destinationRevision == nil {
            exportingDocumentIDs.remove(document.id)
            manager?.endMarkdownExport(documentID: document.id)
            presentError(title: L10n.tr("无法导出"), error: CocoaError(.fileReadUnknown))
            return
        }
        document.statusMessage = L10n.tr("正在导出…")
        let service = MarkdownPDFExportService(destination: destination, mode: mode, window: window, isCurrent: { [weak self, weak document] in
            guard let self, let document else { return false }
            return self.hostWindow != nil && self.documents.contains(where: { $0 === document })
        }) { [weak self, weak document] result in
            guard let self, let document else {
                manager?.endMarkdownExport(documentID: snapshot.documentID)
                if case let .success(.file(prepared)) = result { try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent()) }
                return
            }
            self.pdfExports.removeValue(forKey: document.id)
            self.exportingDocumentIDs.remove(document.id)
            manager?.endMarkdownExport(documentID: document.id)
            let isOpen = self.documents.contains(where: { $0 === document })
            switch result {
            case let .failure(error):
                if let exportError = error as? MarkdownPDFExportService.ExportError, case .cancelled = exportError { return }
                guard isOpen else { return }
                document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                self.presentError(title: L10n.tr("无法导出"), error: error)
            case .success(.printed):
                if isOpen { document.statusMessage = L10n.tr("打印完成") }
            case let .success(.file(prepared)):
                defer { try? FileManager.default.removeItem(at: prepared.preparedURL.deletingLastPathComponent()) }
                guard isOpen, let destination else { return }
                do {
                    let openURLs = manager?.openDocumentURLs ?? self.documents.compactMap(\.url)
                    guard !PandocExportService.conflicts(destination: destination, source: source, openURLs: openURLs) else {
                        throw PandocExportError.openDocument
                    }
                    let currentExists = FileManager.default.fileExists(atPath: destination.path)
                    guard currentExists == destinationExisted,
                          !currentExists || (try? FileRevisionSnapshot.capture(destination)) == destinationRevision else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    try PandocExportService.install(prepared.preparedURL, at: destination)
                    if let previousKind, let revision = try? FileRevisionSnapshot.capture(destination) {
                        self.previousMarkdownExports[document.id] = PreviousMarkdownExport(kind: previousKind, destination: destination, revision: revision)
                    }
                    if case .htmlPlain = mode {
                        let message = L10n.tr("导出完成。HTML 中的相对图片路径需要相对于输出文件有效。")
                        document.statusMessage = prepared.diagnostics.isEmpty ? message : message + " " + prepared.diagnostics
                    } else { document.statusMessage = L10n.tr("导出完成") }
                } catch {
                    document.statusMessage = L10n.tr("导出失败：%@", error.localizedDescription)
                    self.presentError(title: L10n.tr("无法导出"), error: error)
                }
            }
        }
        pdfExports[document.id] = service
        let windowIsDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let darkMode = Self.markdownOutputUsesDarkMode(for: mode, windowIsDark: windowIsDark)
        service.start(snapshot: snapshot, darkMode: darkMode, typography: preferences.markdownTypography,
                      mathOptions: .init(physics: preferences.mathPhysicsEnabled, numbering: preferences.mathNumbering), options: options, headers: headers, sourceURL: source, htmlOptions: htmlOptions, syntax: preferences.markdownSyntax,
                      wiki: MarkdownWikiLinkSource(root: folderWorkspace.rootURL, documentURL: source))
    }

    func closeSelectedDocument() {
        if let document = selectedDocument { close(document) }
    }

    private var isClosingDocument = false

    func close(_ document: EditorDocument) {
        guard !isClosingDocument else { return }
        // A native tab is an NSWindow. Keep the last populated tab's window
        // alive and replace its document; only a disposable blank closes it.
        if documents.count == 1, let hostWindow,
           document.isDisposableBlank || (hostWindow.tabGroup?.windows.count ?? 1) > 1 {
            hostWindow.performClose(nil)
            return
        }
        isClosingDocument = true
        let confirm = { [weak self, weak document] in
            guard let self, let document else { return }
            self.confirmClosing(document) { [weak self, weak document] shouldClose in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isClosingDocument = false
                    guard shouldClose, let document else { return }
                    self.removeDocument(document)
                }
            }
        }
        if hasPendingSave { waitForPendingSaves(completion: confirm) }
        else { confirm() }
    }

    /// Uses the same confirmation and window cleanup as an ordinary close,
    /// while reporting cancellation to the folder operation.
    func closeForFolderOperation(_ document: EditorDocument, keepWindow: Bool = false, completion: @escaping (Bool) -> Void) {
        guard !isClosingDocument, documents.contains(where: { $0 === document }) else {
            completion(false)
            return
        }
        isClosingDocument = true
        let confirm = { [weak self, weak document] in
            guard let self, let document, self.documents.contains(where: { $0 === document }) else {
                self?.isClosingDocument = false
                completion(false)
                return
            }
            let expectedURL = document.url
            let expectedRevision = document.synchronizedSnapshot().revision
            self.confirmClosing(document) { [weak self, weak document] approved in
                DispatchQueue.main.async {
                    guard let self else { completion(false); return }
                    self.isClosingDocument = false
                    guard approved, let document, self.documents.contains(where: { $0 === document }),
                          document.url == expectedURL,
                          document.synchronizedSnapshot().revision == expectedRevision else {
                        completion(false)
                        return
                    }
                    if !keepWindow, self.documents.count == 1, let window = self.hostWindow,
                       (window.tabGroup?.windows.count ?? 1) > 1 {
                        self.prepareForApprovedWindowClose()
                        window.close()
                    } else {
                        let root = self.documents.count == 1 ? self.folderWorkspace.rootURL : nil
                        self.removeDocument(document)
                        if let root { self.folderWorkspace.setRoot(root) }
                    }
                    completion(true)
                }
            }
        }
        if hasPendingSave { waitForPendingSaves(completion: confirm) }
        else { confirm() }
    }

    func selectNextTab() {
        hostWindow?.selectNextTab(nil)
    }

    func selectPreviousTab() {
        hostWindow?.selectPreviousTab(nil)
    }

    func selectTab(at index: Int) {
        guard let group = hostWindow?.tabGroup, group.windows.indices.contains(index) else { return }
        group.selectedWindow = group.windows[index]
    }

    func togglePreview() {
        guard let document = selectedDocument, document.language == .markdown else { return }
        document.synchronizeLiveText()
        if document.isLargeFileMode {
            document.featureOverrides.preview = !document.isPreviewEffectivelyEnabled
        } else {
            document.isPreviewVisible.toggle()
        }
    }

    func toggleWordWrap() {
        guard let document = selectedDocument else { return }
        if document.isLargeFileMode {
            document.setOverride(
                !document.effectiveWordWrap(globalDefault: isWordWrapEnabled),
                for: .wordWrap
            )
        } else {
            isWordWrapEnabled.toggle()
        }
    }

    func toggleLargeFileFeature(_ feature: DocumentManagedFeature) {
        guard let document = selectedDocument, document.isLargeFileMode else { return }
        let enabled: Bool
        switch feature {
        case .wordWrap:
            enabled = !document.effectiveWordWrap(globalDefault: isWordWrapEnabled)
        case .preview:
            enabled = !document.isPreviewEffectivelyEnabled
        case .syntaxHighlighting:
            enabled = !document.isSyntaxHighlightingEnabled
        case .folding:
            enabled = !document.isFoldingEnabled
        case .wordCount:
            enabled = !document.isWordCountEnabled
        }
        document.setOverride(enabled, for: feature)
    }

    func setLanguage(_ language: EditorLanguage) {
        guard let document = selectedDocument else { return }
        document.synchronizeLiveText()
        let wasMarkdown = document.language == .markdown
        document.language = language
        if language == .markdown && !wasMarkdown {
            document.isPreviewVisible = true
        } else if language != .markdown {
            document.isPreviewVisible = false
        }
    }

    func formatJSON(pretty: Bool = true) {
        guard let document = selectedDocument, document.language == .json else { return }
        guard !document.isReadingMode else {
            document.setStatusError(L10n.tr("阅读模式下无法修改"))
            return
        }
        let snapshot = document.synchronizedSnapshot()
        let source = snapshot.text
        let revision = snapshot.revision
        document.statusMessage = pretty ? L10n.tr("正在格式化 JSON…") : L10n.tr("正在压缩 JSON…")
        performCancellableDocumentTask(document, kind: .json) { isCancelled in
            Result {
                try JSONFormatter.format(
                    source,
                    pretty: pretty,
                    isCancelled: isCancelled
                )
            }
        } completion: { [weak self, weak document] result in
            guard let self, let document,
                  self.isTaskResultCurrent(document, revision: revision) else { return }
            switch result {
            case let .success(formatted):
                guard self.applyTextUpdate(
                    formatted,
                    to: document,
                    selectionRange: document.selectionRange,
                    actionName: pretty ? L10n.tr("格式化 JSON") : L10n.tr("压缩 JSON")
                ) else { return }
                document.statusMessage = pretty ? L10n.tr("JSON 已格式化") : L10n.tr("JSON 已压缩")
            case let .failure(error):
                let message = JSONFormatter.userFacingError(error, in: source)
                if error is CancellationError { document.statusMessage = message }
                else { document.setStatusError(message) }
            }
        }
    }

    func presentTextTransformation(_ operation: TextTransformationOperation) {
        guard let document = selectedDocument else { return }
        let extraction = EditorTextExtractionRequest(
            documentID: document.id,
            allowsTokenAtCaret: operation == .smartDecode
        )
        NotificationCenter.default.post(
            name: EditorCommandNotification.extractTextSelection,
            object: extraction
        )
        guard let snapshot = extraction.result else {
            document.statusMessage = operation == .smartDecode
                ? L10n.tr("请将光标放在编码内容中，或先选择文本")
                : L10n.tr("请先选择需要转换的文本")
            return
        }

        let inputByteCount = snapshot.text.utf8.count
        guard inputByteCount <= TextCodecService.maximumInputByteLimit else {
            document.statusMessage = L10n.tr("选区超过 32 MB，请拆分后再转换")
            return
        }
        if inputByteCount > TextCodecService.warningInputByteLimit,
           !confirmLargeTextTransformation(
                byteCount: inputByteCount,
                operation: operation
           ) {
            document.statusMessage = nil
            return
        }

        document.statusMessage = L10n.tr("正在转换文本…")
        performCancellableDocumentTask(document, kind: .textTransformation) { isCancelled in
            Result { () -> TextTransformationPreview in
                let detected = operation == .smartDecode
                    ? TextCodecService.detect(
                        in: snapshot.text,
                        allowsBase64: snapshot.wasExplicitSelection
                    )
                    : nil
                if operation == .smartDecode, detected == nil {
                    throw TextCodecError.noDetectedEncoding
                }
                let resolvedOperation = detected?.operation ?? operation
                let output: String
                if let detected {
                    output = detected.output
                } else {
                    output = try TextCodecService.transform(
                        snapshot.text,
                        operation: resolvedOperation,
                        isCancelled: isCancelled
                    )
                }
                return TextTransformationPreview(
                    documentID: document.id,
                    range: snapshot.range,
                    input: snapshot.text,
                    output: output,
                    editorRevision: snapshot.editorRevision,
                    operation: resolvedOperation,
                    detectedKind: detected?.kind
                )
            }
        } completion: { [weak self, weak document] result in
            guard let self, let document,
                  self.documents.contains(where: { $0.id == document.id }) else { return }
            switch result {
            case let .success(preview):
                document.statusMessage = nil
                self.textTransformation.present(preview)
                let controller = self.textTransformationWindowController
                    ?? TextTransformationWindowController(appState: self)
                self.textTransformationWindowController = controller
                if let hostWindow = self.hostWindow {
                    controller.present(relativeTo: hostWindow)
                }
            case let .failure(error):
                document.statusMessage = error.localizedDescription
            }
        }
    }

    func applyTextTransformationPreview() {
        guard textTransformation.canReplace,
              let preview = textTransformation.preview else {
            textTransformation.message = L10n.tr("编辑内容已变化，请重新执行转换")
            return
        }
        guard let document = documents.first(where: { $0.id == preview.documentID }) else {
            textTransformation.message = L10n.tr("原文标签已关闭，请重新执行转换")
            return
        }
        let request = EditorRangeReplacementRequest(
            documentID: preview.documentID,
            range: preview.range,
            originalText: preview.input,
            replacementText: preview.output,
            expectedEditorRevision: preview.editorRevision,
            actionName: preview.operation.actionName
        )
        NotificationCenter.default.post(
            name: EditorCommandNotification.applyRangeReplacement,
            object: request
        )
        guard request.wasHandled else {
            textTransformation.message = request.failureMessage
                ?? L10n.tr("编辑内容已变化，请重新执行转换")
            return
        }
        document.statusMessage = L10n.tr("已完成 %@", String(describing: preview.operation.title))
        dismissTextTransformation()
    }

    func copyTextTransformationResult(to pasteboard: NSPasteboard = .general) {
        guard let output = textTransformation.preview?.output else { return }
        pasteboard.clearContents()
        if pasteboard.setString(output, forType: .string) {
            textTransformation.copyFeedback.show(L10n.tr("结果已复制"))
        } else {
            textTransformation.message = L10n.tr("无法写入剪贴板，请重试")
        }
    }

    func dismissTextTransformation() {
        textTransformationWindowController?.dismiss()
    }

    func closeAuxiliaryWindows() {
        aiWriting.windowClosed()
        closeVersionHistory()
        closeManuscript()
        templateTask?.cancel()
        templateTask = nil
        renameLinkTask?.cancel()
        renameLinkTask = nil
        markdownLinkTask?.task.cancel()
        markdownLinkTask = nil
        Array(pdfExports.values).forEach { $0.cancel() }
        customExportOperations.values.forEach { $0.cancel() }
        Array(imageExportPreparations.values).forEach { $0.1.cancel() }
        imageUploads.values.forEach { $0.1.cancel() }
        imageUploads.removeAll()
        imagePolicyOperations.values.forEach { $0.cancel() }
        imagePolicyOperations.removeAll()
        imageCopyOperations.values.forEach { $0.cancel() }
        imageCopyOperations.removeAll()
        folderSearchStorage?.close()
        backlinksStorage?.close()
        folderTagsStorage?.invalidate()
        folderWorkspace.setRoot(nil)
        sidebarFeedback.clear()
        dismissFindReplace()
        openingOperations.values.forEach { $0.cancel() }
        openingOperations.removeAll()
        openingFileURLs.removeAll()
        for document in documents where openingPlaceholderIDs.contains(document.id) {
            _ = windowManager?.cancelRestoration(document)
        }
        openingPlaceholderIDs.removeAll()
        documentTaskQueue.cancelAllOperations()
        documents.forEach { $0.taskCoordinator.cancelAll() }
        textTransformationWindowController?.dispose()
        textTransformationWindowController = nil
        textTransformation.clear()
    }

    private func confirmLargeTextTransformation(
        byteCount: Int,
        operation: TextTransformationOperation
    ) -> Bool {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let multiplier = operation == .urlEncodeComponent ? 3 : 2
        let estimated = Int64(byteCount * multiplier)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("转换较大的文本选区？")
        alert.informativeText = L10n.tr("选区大小为 %@，预计最多产生约 %@ 的结果。转换期间可继续使用其他标签。", formatter.string(fromByteCount: Int64(byteCount)), formatter.string(fromByteCount: estimated))
        alert.addButton(withTitle: L10n.tr("继续转换"))
        alert.addButton(withTitle: L10n.tr("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func presentFindReplace(mode: FindReplaceMode) {
        findReplace.mode = mode
        findReplace.message = nil
        findReplace.isBarVisible = true
        findReplace.focusRequestID = UUID()
        if mode != .goToLine { scheduleFindRefresh() }
    }

    func dismissFindReplace(returnFocus: Bool = false) {
        if let documentID = findReplace.activeDocumentID,
           let document = documents.first(where: { $0.id == documentID }) {
            document.taskCoordinator.cancel(.search)
            document.taskCoordinator.cancel(.replace)
        }
        findRefreshTask?.cancel()
        findRefreshTask = nil
        findReplace.isWorking = false
        findReplace.activeDocumentID = nil
        findReplace.isBarVisible = false
        clearFindResults()
        if returnFocus, let document = selectedDocument {
            NotificationCenter.default.post(
                name: EditorCommandNotification.revealSelection,
                object: EditorSelectionRequest(documentID: document.id, range: document.selectionRange)
            )
        }
    }

    func findNext(keepFocusInBar: Bool = false) {
        guard let document = selectedDocument else { return }
        let source = document.synchronizedSnapshot().text
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            presentFindReplace(mode: .find)
            return
        }
        performFind(
            in: document,
            source: source,
            query: query,
            selection: document.selectionRange,
            backwards: false,
            focusEditor: !keepFocusInBar
        )
    }

    func findPrevious(keepFocusInBar: Bool = false) {
        guard let document = selectedDocument else { return }
        let source = document.synchronizedSnapshot().text
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            presentFindReplace(mode: .find)
            return
        }
        performFind(
            in: document,
            source: source,
            query: query,
            selection: document.selectionRange,
            backwards: true,
            focusEditor: !keepFocusInBar
        )
    }

    func replaceCurrentMatch(keepFocusInBar: Bool = false) {
        guard let document = selectedDocument else { return }
        guard !document.isReadingMode else {
            findReplace.show(L10n.tr("阅读模式下无法修改"), kind: .error)
            return
        }
        let source = document.synchronizedSnapshot().text
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            findReplace.show(L10n.tr("请输入查找内容"), kind: .error)
            return
        }
        let replacement: String?
        do {
            replacement = try TextSearchService.replacement(
                forSelection: document.selectionRange,
                in: source,
                query: query,
                replacement: findReplace.replacement,
                options: findReplace.searchOptions,
                interpretsEscapes: findReplace.interpretsEscapes
            )
        } catch {
            findReplace.show(L10n.tr("正则表达式无效"), kind: .error)
            return
        }
        guard let replacement else {
            findNext(keepFocusInBar: keepFocusInBar)
            return
        }

        let mutable = NSMutableString(string: source)
        let originalRange = document.selectionRange
        mutable.replaceCharacters(in: originalRange, with: replacement)
        let nextSelection = NSRange(
            location: originalRange.location,
            length: (replacement as NSString).length
        )
        guard applyTextUpdate(
            mutable as String,
            to: document,
            selectionRange: nextSelection,
            actionName: L10n.tr("替换")
        ) else { return }
        findReplace.show(L10n.tr("已替换 1 处"), kind: .success)
        findNext(keepFocusInBar: keepFocusInBar)
    }

    /// ⌘E: подставляет выделение в запрос (с экранированием под текущий режим); панель не открывает.
    func useSelectionForFind() {
        guard let document = selectedDocument else { return }
        let snapshot = document.synchronizedSnapshot()
        let selection = document.selectionRange
        let text = snapshot.text as NSString
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return }
        let selected = text.substring(with: selection)
        findReplace.query = findReplace.usesRegex
            ? NSRegularExpression.escapedPattern(for: selected)
            : (findReplace.interpretsEscapes ? TextSearchService.escapedForInterpretation(selected) : selected)
        if findReplace.isBarVisible, findReplace.mode != .goToLine { scheduleFindRefresh() }
    }

    /// Ввод «строка» или «строка:столбец» (с 1). Успех закрывает панель и переносит курсор.
    @discardableResult
    func goToLine(_ input: String) -> Bool {
        guard let document = selectedDocument else { return false }
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let line = Int(parts[0]), line >= 1,
              parts.count == 1 || (Int(parts[1]).map { $0 >= 1 } ?? false) else {
            findReplace.show(L10n.tr("请输入有效的行号，例如 12 或 12:5"), kind: .error)
            return false
        }
        let column = parts.count == 2 ? (Int(parts[1]) ?? 1) : 1
        let text = document.synchronizedSnapshot().text as NSString
        let index = LogicalLineIndex(text: text as String)
        guard let location = index.location(line: line, column: column, in: text) else {
            findReplace.show(L10n.tr("行号超出范围（1–%@）", String(index.lineCount)), kind: .error)
            return false
        }
        reveal(NSRange(location: location, length: 0), in: document)
        findReplace.show(nil, kind: .info)
        dismissFindReplace()
        return true
    }

    func scheduleFindRefresh() {
        findRefreshTask?.cancel()
        guard findReplace.isBarVisible, findReplace.mode != .goToLine, !findReplace.query.isEmpty,
              let document = selectedDocument, !document.isLargeFileMode else {
            clearFindResults()
            if findReplace.mode != .goToLine, findReplace.messageKind == .error { findReplace.show(nil, kind: .info) }
            return
        }
        findRefreshTask = Task { @MainActor [weak self, weak document] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, let document, self.selectedDocument === document, !self.findReplace.isWorking else { return }
            self.refreshFindMatches(in: document)
        }
    }

    private func refreshFindMatches(in document: EditorDocument) {
        let snapshot = document.synchronizedSnapshot()
        let query = interpretedSearchQuery()
        let options = findReplace.searchOptions
        let rawQuery = findReplace.query
        guard !query.isEmpty else { clearFindResults(); return }
        if !options.isPlain {
            do { _ = try TextSearchService.regularExpression(query: query, options: options) }
            catch {
                findReplace.show(L10n.tr("正则表达式无效"), kind: .error)
                clearFindResults()
                return
            }
        }
        if findReplace.messageKind == .error { findReplace.show(nil, kind: .info) }
        let key = TextSearchService.CacheKey(
            revision: snapshot.revision,
            query: query,
            caseSensitive: options.caseSensitive,
            usesRegex: options.usesRegex,
            wholeWord: options.wholeWord
        )
        if let cached = searchMatchCache.value(for: document.id, key: key) {
            publishFindMatches(cached.matches, in: document, revision: snapshot.revision)
            return
        }
        performAsyncSearchTask(document, source: snapshot.text, query: query, options: options) { [weak self, weak document] matches in
            guard let self, let document,
                  self.findReplace.query == rawQuery,
                  self.findReplace.searchOptions == options else { return }
            self.searchMatchCache.insert(SearchMatchCacheStore.Entry(key: key, matches: matches), for: document.id)
            self.publishFindMatches(matches, in: document, revision: snapshot.revision)
        }
    }

    private func publishFindMatches(_ matches: [NSRange], in document: EditorDocument, revision: UInt) {
        guard isTaskResultCurrent(document, revision: revision),
              selectedDocument === document,
              findReplace.isBarVisible else { return }
        findReplace.setMatches(matches, documentID: document.id)
        if findReplace.message != nil, findReplace.messageKind != .success, !findReplace.isWorking {
            findReplace.show(nil, kind: .info)
        }
        NotificationCenter.default.post(
            name: EditorCommandNotification.findHighlights,
            object: FindHighlightRequest(documentID: document.id, matches: matches)
        )
    }

    private func clearFindResults() {
        if let id = findReplace.matchesDocumentID {
            NotificationCenter.default.post(
                name: EditorCommandNotification.findHighlights,
                object: FindHighlightRequest(documentID: id, matches: [])
            )
        }
        findReplace.setMatches(nil, documentID: nil)
    }

    func replaceAllMatches() {
        guard let document = selectedDocument else { return }
        guard !document.isReadingMode else {
            findReplace.show(L10n.tr("阅读模式下无法修改"), kind: .error)
            return
        }
        let snapshot = document.synchronizedSnapshot()
        let source = snapshot.text
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            findReplace.show(L10n.tr("请输入查找内容"), kind: .error)
            return
        }
        let options = findReplace.searchOptions
        if !options.isPlain {
            do { _ = try TextSearchService.regularExpression(query: query, options: options) }
            catch {
                findReplace.show(L10n.tr("正则表达式无效"), kind: .error)
                return
            }
        }
        let replacement = findReplace.replacement
        let interpretsEscapes = findReplace.interpretsEscapes
        let revision = snapshot.revision
        let rawQuery = findReplace.query
        findReplace.isWorking = true
        findReplace.activeDocumentID = document.id
        findReplace.message = L10n.tr("正在替换…")
        performCancellableDocumentTask(document, kind: .replace) { isCancelled in
            // Выражение проверено на главном потоке до запуска.
            (try? TextSearchService.replaceAll(
                in: source,
                query: query,
                replacement: replacement,
                options: options,
                interpretsEscapes: interpretsEscapes,
                isCancelled: isCancelled
            )) ?? (source, 0)
        } completion: { [weak self, weak document] result in
            guard let self, let document else { return }
            guard self.findReplace.activeDocumentID == document.id else { return }
            self.findReplace.isWorking = false
            self.findReplace.activeDocumentID = nil
            guard self.findReplace.query == rawQuery,
                  self.findReplace.searchOptions == options,
                  self.isTaskResultCurrent(document, revision: revision) else {
                self.findReplace.message = L10n.tr("内容已变化，已取消替换")
                return
            }
            guard result.count > 0 else {
                self.findReplace.show(L10n.tr("未找到匹配内容"), kind: .error)
                return
            }
            guard self.applyTextUpdate(
                result.text,
                to: document,
                selectionRange: NSRange(location: 0, length: 0),
                actionName: L10n.tr("全部替换")
            ) else {
                self.findReplace.show(L10n.tr("阅读模式下无法修改"), kind: .error)
                return
            }
            self.findReplace.show(L10n.tr("已替换 %@ 处", String(result.count)), kind: .success)
            self.scheduleFindRefresh()
        }
    }

    func cancelFindReplaceTask() {
        guard findReplace.isWorking,
              let documentID = findReplace.activeDocumentID,
              let document = documents.first(where: { $0.id == documentID }) else { return }
        document.taskCoordinator.cancel(.search)
        document.taskCoordinator.cancel(.replace)
        findReplace.isWorking = false
        findReplace.activeDocumentID = nil
        findReplace.message = L10n.tr("已取消")
    }

    func increaseFontSize() {
        editorFontSize = min(editorFontSize + 1, 32)
    }

    func decreaseFontSize() {
        editorFontSize = max(editorFontSize - 1, 9)
    }

    func resetFontSize() {
        editorFontSize = AppPreferences.defaultFontSize
    }

    var isUsingDefaultFontSize: Bool {
        editorFontSize == AppPreferences.defaultFontSize
    }

    func resetLineSpacing() {
        editorLineSpacing = AppPreferences.defaultLineSpacing
    }

    var isUsingDefaultLineSpacing: Bool {
        editorLineSpacing == AppPreferences.defaultLineSpacing
    }

    func updateRenamedFileReference(from oldURL: URL, to newURL: URL) {
        for document in documents {
            document.updateLocationAfterRename(from: oldURL, to: newURL)
        }
    }

    func createFolderWorkspaceItem(in directory: URL, isDirectory: Bool) {
        guard let root = folderWorkspace.rootURL else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr(isDirectory ? "新建文件夹" : "新建文件")
        alert.addButton(withTitle: L10n.tr("创建"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, folderWorkspace.rootURL == root else { return }
        do {
            let url = try fileService.createWorkspaceItem(named: field.stringValue, in: directory, root: root, isDirectory: isDirectory)
            folderWorkspace.refresh()
            guard let snapshot = try? fileService.workspaceItemSnapshot(url) else {
                sidebarFeedback.show(L10n.tr("已创建，但无法准备撤销"), symbol: "info.circle")
                return
            }
            sidebarFeedback.showAsyncUndo(L10n.tr("已创建")) { [weak self] in
                guard let self else { return false }
                return await self.undoFolderWorkspaceItem(url, root: root, snapshot: snapshot, isCreated: true)
            }
        } catch { presentError(title: L10n.tr("无法创建文件"), error: error) }
    }

    func duplicateFolderWorkspaceItem(_ source: URL) {
        guard let root = folderWorkspace.rootURL else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("复制文件或文件夹")
        alert.addButton(withTitle: L10n.tr("复制"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let ext = source.pathExtension
        field.stringValue = ext.isEmpty ? source.lastPathComponent + " copy" : source.deletingPathExtension().lastPathComponent + " copy." + ext
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, folderWorkspace.rootURL == root else { return }
        let name = field.stringValue
        let service = fileService
        Task { [weak self] in
            let result = await Task.detached { () -> Result<(URL, WorkspaceItemSnapshot?), Error> in
                Result {
                    try service.validateWorkspaceDirectory(source.deletingLastPathComponent(), root: root)
                    let sourceSnapshot = try service.workspaceItemSnapshot(source)
                    let url = try service.copyWorkspaceItem(source, named: name, root: root)
                    let snapshot: WorkspaceItemSnapshot?
                    do {
                        try service.validateWorkspaceDirectory(url.deletingLastPathComponent(), root: root)
                        snapshot = try service.workspaceItemSnapshot(url)
                    } catch { snapshot = nil }
                    return (url, snapshot?.entries == sourceSnapshot.entries ? snapshot : nil)
                }
            }.value
            guard let self else { return }
            switch result {
            case let .failure(error): self.presentError(title: L10n.tr("无法复制文件"), error: error)
            case let .success((url, snapshot)):
                self.folderWorkspace.refresh()
                guard let snapshot, self.folderWorkspace.rootURL == root else {
                    self.sidebarFeedback.show(L10n.tr("已复制，但无法准备撤销"), symbol: "info.circle")
                    return
                }
                self.sidebarFeedback.showAsyncUndo(L10n.tr("已复制")) { [weak self] in
                    guard let self else { return false }
                    return await self.undoFolderWorkspaceItem(url, root: root, snapshot: snapshot, isCreated: false)
                }
            }
        }
    }

    func undoFolderWorkspaceItem(_ url: URL, root: URL, snapshot: WorkspaceItemSnapshot, isCreated: Bool,
                                 removeCopy: (@Sendable (URL, URL, WorkspaceItemSnapshot) throws -> Void)? = nil) async -> Bool {
        let service = fileService
        let current = await Task.detached { () -> WorkspaceItemSnapshot? in
            do {
                try service.validateWorkspaceDirectory(url.deletingLastPathComponent(), root: root)
                return try service.workspaceItemSnapshot(url)
            } catch { return nil }
        }.value
        guard current == snapshot, folderWorkspace.rootURL == root, let manager = windowManager,
              manager.beginFolderRemoval(url, snapshot: snapshot) else { return false }
        defer { manager.endFolderRemoval() }
        guard folderWorkspace.rootURL == root,
              !hasOpenDocument(in: url, snapshot: snapshot) else { return false }
        let removed = await Task.detached { () -> Bool in
            do {
                if isCreated { try service.removeEmptyWorkspaceItem(url, root: root, snapshot: snapshot) }
                else if let removeCopy { try removeCopy(url, root, snapshot) }
                else { try service.removeCopiedWorkspaceItem(url, root: root, snapshot: snapshot) }
                return true
            } catch { return false }
        }.value
        if removed { folderWorkspace.refresh() }
        return removed
    }

    func hasOpenDocument(in url: URL, snapshot: WorkspaceItemSnapshot) -> Bool {
        windowManager?.documentsForAI.contains { document in
            if let documentURL = document.url,
               documentURL.standardizedFileURL.pathComponents.starts(with: url.standardizedFileURL.pathComponents) {
                return true
            }
            guard let identity = document.fileIdentity else { return false }
            return snapshot.fileIdentities.contains { $0.matches(identity) }
        } ?? false
    }

    func moveFolderWorkspaceItem(_ source: URL, rename: Bool) {
        guard let root = folderWorkspace.rootURL, let manager = windowManager,
              let identity = try? fileService.workspaceNodeIdentity(source) else { return }
        let destination: URL
        if rename {
            let alert = NSAlert()
            alert.messageText = L10n.tr("重命名文件")
            alert.addButton(withTitle: L10n.tr("重命名"))
            alert.addButton(withTitle: L10n.tr("取消"))
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.stringValue = source.lastPathComponent
            alert.accessoryView = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { destination = try fileService.workspaceDestination(named: field.stringValue, in: source.deletingLastPathComponent(), root: root) }
            catch { presentError(title: L10n.tr("无法移动文件"), error: error); return }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = root
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            do { destination = try fileService.workspaceDestination(named: source.lastPathComponent, in: folder, root: root) }
            catch { presentError(title: L10n.tr("无法移动文件"), error: error); return }
        }
        guard folderWorkspace.rootURL == root else { return }
        Task { [weak self, weak manager] in
            guard let self, let manager else { return }
            let linkPlan = await self.prepareMarkdownLinkUpdate(from: source, to: destination)
            let (succeeded, newIdentity, listChanges) = await manager.moveFolderWorkspaceItem(source, to: destination, root: root, state: self, expectedIdentity: identity)
            guard succeeded else {
                self.sidebarFeedback.show(L10n.tr("无法移动文件，请检查文件和保存状态"), symbol: "info.circle")
                return
            }
            guard let newIdentity, let listChanges else {
                self.sidebarFeedback.show(L10n.tr("已移动，但无法准备撤销"), symbol: "info.circle")
                await self.completeMarkdownLinkUpdate(linkPlan)
                return
            }
            self.sidebarFeedback.showAsyncUndo(L10n.tr("已移动")) { [weak self, weak manager] in
                guard let self, let manager else { return false }
                let (restored, _, _) = await manager.moveFolderWorkspaceItem(destination, to: source, root: root, state: self, expectedIdentity: newIdentity, updateLists: false)
                if restored { manager.restoreMovedFolderWorkspaceLists(listChanges, source: source, destination: destination) }
                return restored
            }
            await self.completeMarkdownLinkUpdate(linkPlan)
        }
    }

    func trashFolderWorkspaceItem(_ source: URL) {
        guard let root = folderWorkspace.rootURL, let manager = windowManager,
              let identity = try? fileService.workspaceNodeIdentity(source) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("移到废纸篓？")
        alert.informativeText = L10n.tr("打开的文件会先逐个确认并关闭。")
        alert.addButton(withTitle: L10n.tr("移到废纸篓"))
        alert.addButton(withTitle: L10n.tr("取消"))
        guard alert.runModal() == .alertFirstButtonReturn, folderWorkspace.rootURL == root else { return }
        Task { [weak self, weak manager] in
            guard let self, let manager else { return }
            let (succeeded, trashURL, trashIdentity, changes) = await manager.trashFolderWorkspaceItem(source, root: root, state: self, expectedIdentity: identity)
            guard succeeded else {
                self.sidebarFeedback.show(L10n.tr("未移到废纸篓"), symbol: "info.circle")
                return
            }
            guard let trashURL, let trashIdentity, let changes else {
                self.sidebarFeedback.show(L10n.tr("已移到废纸篓，但无法准备撤销"), symbol: "info.circle")
                return
            }
            self.sidebarFeedback.showAsyncUndo(L10n.tr("已移到废纸篓")) { [weak self, weak manager] in
                guard let self, let manager else { return false }
                return await manager.restoreFolderWorkspaceTrash(trashURL, to: source, root: root, state: self, expectedIdentity: trashIdentity, changes: changes)
            }
        }
    }

    func confirmClosingAllDocuments(completion: @escaping (Bool) -> Void) {
        closeDocumentsSequentially(documents, removesDocuments: false, completion: completion)
    }

    func toggleSidebarFavorite(_ url: URL) {
        guard let library = windowManager?.sidebarLibrary else { return }
        let previous = library.favoritePaths
        let wasFavorite = library.isFavorite(url)
        library.toggleFavorite(url)
        let expected = library.favoritePaths
        sidebarFeedback.show(wasFavorite ? L10n.tr("已从收藏夹移除") : L10n.tr("已添加到收藏夹")) { [weak library] in
            library?.restoreFavorites(previous, ifUnchanged: expected) ?? false
        }
    }

    func addSidebarFile(_ url: URL, toGroup id: UUID) {
        guard let library = windowManager?.sidebarLibrary,
              let group = library.groups.first(where: { $0.id == id }) else { return }
        guard !library.groupsContaining(url).contains(id) else {
            sidebarFeedback.show(L10n.tr("文件已在此分组中"))
            return
        }
        library.add(url, toGroup: id)
        let expected = library.groups.first(where: { $0.id == id })?.paths ?? []
        sidebarFeedback.show(L10n.tr("已添加到“%@”", String(describing: group.name))) { [weak library] in
            library?.restoreGroupFiles(group.paths, in: id, ifUnchanged: expected) ?? false
        }
    }

    func removeSidebarFile(_ url: URL, fromGroup id: UUID) {
        guard let library = windowManager?.sidebarLibrary,
              let group = library.groups.first(where: { $0.id == id }) else { return }
        library.remove(url, fromGroup: id)
        let expected = library.groups.first(where: { $0.id == id })?.paths ?? []
        guard group.paths != expected else { return }
        sidebarFeedback.show(L10n.tr("已从“%@”移除", String(describing: group.name))) { [weak library] in
            library?.restoreGroupFiles(group.paths, in: id, ifUnchanged: expected) ?? false
        }
    }

    func removeRecentSidebarFile(_ url: URL) {
        let previous = recentFiles.urls
        recentFiles.remove(url)
        let expected = recentFiles.urls
        guard previous != expected else { return }
        sidebarFeedback.show(L10n.tr("已移除最近文件记录")) { [weak recentFiles] in
            recentFiles?.restore(previous, ifUnchanged: expected) ?? false
        }
    }

    func addSidebarFavorites(_ urls: [URL]) {
        guard let library = windowManager?.sidebarLibrary else { return }
        let previous = library.favoritePaths
        for url in urls where !library.isFavorite(url) { library.toggleFavorite(url) }
        let expected = library.favoritePaths
        guard previous != expected else { return }
        sidebarFeedback.show(L10n.tr("已更新所选文件")) { [weak library] in
            library?.restoreFavorites(previous, ifUnchanged: expected) ?? false
        }
    }

    func addSidebarFiles(_ urls: [URL], toGroup id: UUID) {
        guard let library = windowManager?.sidebarLibrary,
              let group = library.groups.first(where: { $0.id == id }) else { return }
        for url in urls where !library.groupsContaining(url).contains(id) { library.add(url, toGroup: id) }
        let expected = library.groups.first(where: { $0.id == id })?.paths ?? []
        guard group.paths != expected else { return }
        sidebarFeedback.show(L10n.tr("已更新所选文件")) { [weak library] in
            library?.restoreGroupFiles(group.paths, in: id, ifUnchanged: expected) ?? false
        }
    }

    func removeSidebarFiles(_ urls: [URL], location: SidebarFileLocation) {
        switch location {
        case .favorites:
            guard let library = windowManager?.sidebarLibrary else { return }
            let previous = library.favoritePaths
            for url in urls where library.isFavorite(url) { library.toggleFavorite(url) }
            let expected = library.favoritePaths
            guard previous != expected else { return }
            sidebarFeedback.show(L10n.tr("已更新所选文件")) { [weak library] in
                library?.restoreFavorites(previous, ifUnchanged: expected) ?? false
            }
        case let .group(id):
            guard let library = windowManager?.sidebarLibrary,
                  let group = library.groups.first(where: { $0.id == id }) else { return }
            for url in urls { library.remove(url, fromGroup: id) }
            let expected = library.groups.first(where: { $0.id == id })?.paths ?? []
            guard group.paths != expected else { return }
            sidebarFeedback.show(L10n.tr("已更新所选文件")) { [weak library] in
                library?.restoreGroupFiles(group.paths, in: id, ifUnchanged: expected) ?? false
            }
        case .recent:
            let previous = recentFiles.urls
            for url in urls { recentFiles.remove(url) }
            let expected = recentFiles.urls
            guard previous != expected else { return }
            sidebarFeedback.show(L10n.tr("已更新所选文件")) { [weak recentFiles] in
                recentFiles?.restore(previous, ifUnchanged: expected) ?? false
            }
        }
    }

    private func observe(_ document: EditorDocument) {
        document.resumeMetricsRefresh()
        documentCancellables[document.id] = Publishers.MergeMany([
            document.$url.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$language.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$isDirty.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$isPreviewVisible.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$isMarkdownFormatted.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$isReadingMode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$performanceProfile.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$featureOverrides.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$ioState.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .sink { [weak self] in self?.objectWillChange.send() }

        recoveryCancellables[document.id] = Publishers.MergeMany([
            document.$text.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$url.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$language.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$isDirty.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .sink { [weak self, weak document] in
            guard let self, let document,
                  !self.documentsBeingSnapshotted.contains(document.id) else {
                return
            }
            self.scheduleRecoverySnapshot(for: document)
        }
        if document.isDirty {
            scheduleRecoverySnapshot(for: document, delay: 0)
        }

        if document.ioState == .idle, document.text.isEmpty {
            // Пустой документ начинает день с нуля, а не со слов, набранных до первой статистики.
            preferences.writingGoal.record(words: 0, documentID: document.id)
        }
        writingGoalCancellables[document.id] = document.$statistics
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak document] _ in
                guard let self, let document else { return }
                self.recordWritingGoal(for: document)
            }
    }

    private func recordWritingGoal(for document: EditorDocument) {
        guard documents.contains(where: { $0 === document }),
              !openingPlaceholderIDs.contains(document.id),
              document.ioState == .idle,
              document.performanceProfile == .standard,
              document.isWordCountEnabled,
              !document.statisticsUnavailable,
              document.selectionRange.length == 0,
              let statistics = document.statistics else { return }
        // другой язык считает слова иначе: разница не написана пользователем
        let previousLanguage = writingGoalLanguages.updateValue(document.language, forKey: document.id)
        if let previousLanguage, previousLanguage != document.language {
            preferences.writingGoal.rebase(words: statistics.words, documentID: document.id)
        } else {
            preferences.writingGoal.record(words: statistics.words, documentID: document.id)
        }
    }

    private func stopObserving(_ document: EditorDocument) {
        pdfExports[document.id]?.cancel()
        customExportOperations[document.id]?.cancel()
        imageExportPreparations[document.id]?.1.cancel()
        imageUploads.removeValue(forKey: document.id)?.1.cancel()
        imagePolicyOperations.removeValue(forKey: document.id)?.cancel()
        imageCopyOperations.removeValue(forKey: document.id)?.cancel()
        document.taskCoordinator.cancel(.search)
        document.taskCoordinator.cancel(.replace)
        document.taskCoordinator.cancel(.json)
        document.taskCoordinator.cancel(.preview)
        document.taskCoordinator.cancel(.folding)
        document.cancelMetricsRefresh()
        document.taskCoordinator.cancel(.textTransformation)
        textTransformation.invalidate(documentID: document.id)
        aiWriting.invalidate(documentID: document.id)
        documentCancellables.removeValue(forKey: document.id)?.cancel()
        recoveryCancellables.removeValue(forKey: document.id)?.cancel()
        writingGoalCancellables.removeValue(forKey: document.id)?.cancel()
        writingGoalLanguages.removeValue(forKey: document.id)
        preferences.writingGoal.markClosed(documentID: document.id)
        recoveryWorkItems.removeValue(forKey: document.id)?.cancel()
        recoveryRequestTokens.removeValue(forKey: document.id)
    }

    private func scheduleRecoverySnapshot(
        for document: EditorDocument,
        delay: TimeInterval? = nil
    ) {
        guard let recoveryStore, !openingPlaceholderIDs.contains(document.id) else { return }
        recoveryWorkItems.removeValue(forKey: document.id)?.cancel()
        guard document.isDirty else {
            recoveryRequestTokens[document.id] = nil
            document.resetRecoveryCopy()
            recoveryStore.discard(documentID: document.id)
            return
        }
        document.beginRecoveryTracking()

        let workItem = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document,
                  self.documents.contains(where: { $0.id == document.id }),
                  document.isDirty else {
                return
            }
            self.documentsBeingSnapshotted.insert(document.id)
            let text = document.synchronizedText()
            self.documentsBeingSnapshotted.remove(document.id)
            guard document.isDirty else {
                self.recoveryRequestTokens[document.id] = nil
                document.resetRecoveryCopy()
                recoveryStore.discard(documentID: document.id)
                return
            }
            self.recoveryTokenCounter &+= 1
            let token = self.recoveryTokenCounter
            self.recoveryRequestTokens[document.id] = token
            let revision = document.textRevision
            recoveryStore.persist(DocumentRecoverySnapshot(
                documentID: document.id,
                text: text,
                sourceURL: document.url,
                language: document.language,
                encoding: document.fileEncoding,
                revision: revision,
                selectionRange: document.selectionRange,
                scrollPositionRatio: document.scrollPositionRatio,
                isPreviewVisible: document.isPreviewVisible,
                fileRevisionSnapshot: document.fileRevisionSnapshot,
                capturedAt: Date()
            )) { [weak self, weak document] result in
                MainActor.assumeIsolated {
                    guard let self, let document,
                          self.documents.contains(where: { $0.id == document.id }),
                          self.recoveryRequestTokens[document.id] == token else { return }
                    document.acknowledgeRecoveryCopy(revision: revision, result: result)
                }
            }
            self.recoveryWorkItems.removeValue(forKey: document.id)
        }
        recoveryWorkItems[document.id] = workItem
        let resolvedDelay = delay ?? (document.isLargeFileMode ? 5 : 2)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + resolvedDelay,
            execute: workItem
        )
    }

    func prepareForApprovedWindowClose() {
        let documentIDs = documents.map(\.id)
        recoveryWorkItems.values.forEach { $0.cancel() }
        recoveryWorkItems.removeAll()
        recoveryRequestTokens.removeAll()
        recoveryStore?.discard(documentIDs: documentIDs)
    }

    /// Only called after the close pipeline has approved discarding/saving.
    /// SwiftUI retains its primary scene, but closed documents must not return.
    func resetClosedWindow() {
        folderSearchStorage?.close()
        backlinksStorage?.close()
        folderTagsStorage?.invalidate()
        folderWorkspace.setRoot(nil)
        isFocusMode = false
        focusScope = .paragraph
        isTypewriterMode = false
        viewMagnification = 1
        for document in documents { stopObserving(document) }
        let blank = EditorDocument()
        documents = [blank]
        selectedDocumentID = blank.id
        observe(blank)
    }

    func persistRecoverySnapshotsImmediately() {
        for document in documents where document.isDirty {
            scheduleRecoverySnapshot(for: document, delay: 0)
        }
    }

    private func suggestedFilename(for document: EditorDocument) -> String {
        if let existing = document.url?.lastPathComponent { return existing }
        return switch document.language {
        case .markdown: L10n.tr("未命名") + ".md"
        case .json: L10n.tr("未命名") + ".json"
        case .html: L10n.tr("未命名") + ".html"
        case .javascript: L10n.tr("未命名") + ".js"
        case .typescript: L10n.tr("未命名") + ".ts"
        case .css: L10n.tr("未命名") + ".css"
        case .python: L10n.tr("未命名") + ".py"
        case .swift: L10n.tr("未命名") + ".swift"
        case .shell: L10n.tr("未命名") + ".sh"
        case .yaml: L10n.tr("未命名") + ".yaml"
        case .cFamily: L10n.tr("未命名") + ".cpp"
        case .sql: L10n.tr("未命名") + ".sql"
        case .plainText: L10n.tr("未命名") + ".txt"
        }
    }

    private func interpretedSearchQuery() -> String {
        // В режиме регулярного выражения свои escape-последовательности: \s не должен стать пробелом.
        if findReplace.usesRegex { return findReplace.query }
        return TextSearchService.interpreted(
            findReplace.query,
            enabled: findReplace.interpretsEscapes
        )
    }

    private func performFind(
        in document: EditorDocument,
        source: String,
        query: String,
        selection: NSRange,
        backwards: Bool,
        focusEditor: Bool
    ) {
        let options = findReplace.searchOptions
        if !options.isPlain {
            do { _ = try TextSearchService.regularExpression(query: query, options: options) }
            catch {
                findReplace.show(L10n.tr("正则表达式无效"), kind: .error)
                findReplace.isWorking = false
                findReplace.activeDocumentID = nil
                return
            }
        }
        let revision = document.textRevision
        let rawQuery = findReplace.query
        let cacheKey = TextSearchService.CacheKey(
            revision: revision,
            query: query,
            caseSensitive: options.caseSensitive,
            usesRegex: options.usesRegex,
            wholeWord: options.wholeWord
        )
        findReplace.isWorking = true
        findReplace.activeDocumentID = document.id
        findReplace.message = L10n.tr("正在查找…")

        if let cached = searchMatchCache.value(for: document.id, key: cacheKey) {
            let range = backwards
                ? TextSearchService.previousRange(
                    in: cached.matches,
                    before: selection
                )
                : TextSearchService.nextRange(
                    in: cached.matches,
                    after: selection
                )
            finishFind(
                range,
                in: document,
                revision: revision,
                rawQuery: rawQuery,
                options: options,
                focusEditor: focusEditor
            )
            publishFindMatches(cached.matches, in: document, revision: revision)
            return
        }

        performAsyncSearchTask(
            document,
            source: source,
            query: query,
            options: options
        ) { [weak self, weak document] matches in
            guard let self, let document else { return }
            self.searchMatchCache.insert(
                SearchMatchCacheStore.Entry(
                key: cacheKey,
                matches: matches
                ),
                for: document.id
            )
            let range = backwards
                ? TextSearchService.previousRange(
                    in: matches,
                    before: selection
                )
                : TextSearchService.nextRange(
                    in: matches,
                    after: selection
                )
            self.finishFind(
                range,
                in: document,
                revision: revision,
                rawQuery: rawQuery,
                options: options,
                focusEditor: focusEditor
            )
            self.publishFindMatches(matches, in: document, revision: revision)
        }
    }

    private func performAsyncSearchTask(
        _ document: EditorDocument,
        source: String,
        query: String,
        options: TextSearchService.Options,
        completion: @escaping ([NSRange]) -> Void
    ) {
        var task: Task<Void, Never>?
        let generation = document.taskCoordinator.beginTask(.search) {
            task?.cancel()
        }
        let coordinator = document.taskCoordinator
        task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let signpostID = OSSignpostID(log: taskPerformanceLog)
            os_signpost(
                .begin,
                log: taskPerformanceLog,
                name: documentTaskSignpostName(for: .search),
                signpostID: signpostID
            )
            // Выражение проверено на главном потоке до запуска задачи.
            let matches = (try? TextSearchService.allRanges(
                in: source,
                query: query,
                options: options,
                isCancelled: { Task.isCancelled }
            )) ?? []
            os_signpost(
                .end,
                log: taskPerformanceLog,
                name: documentTaskSignpostName(for: .search),
                signpostID: signpostID
            )
            guard !Task.isCancelled,
                  coordinator.isCurrent(generation, for: .search) else { return }
            await MainActor.run {
                guard !Task.isCancelled,
                      coordinator.isCurrent(generation, for: .search) else { return }
                coordinator.finish(.search, generation: generation)
                completion(matches)
            }
        }
    }

    private func finishFind(
        _ range: NSRange?,
        in document: EditorDocument,
        revision: UInt,
        rawQuery: String,
        options: TextSearchService.Options,
        focusEditor: Bool
    ) {
        guard findReplace.activeDocumentID == document.id else { return }
        findReplace.isWorking = false
        findReplace.activeDocumentID = nil
        guard findReplace.query == rawQuery,
              findReplace.searchOptions == options,
              isTaskResultCurrent(document, revision: revision) else {
            findReplace.message = L10n.tr("内容已变化，已取消查找")
            return
        }
        guard let range else {
            findReplace.show(L10n.tr("未找到匹配内容"), kind: .error)
            return
        }
        reveal(range, in: document, focusEditor: focusEditor)
        findReplace.show(nil, kind: .info)
    }

    private func performDocumentTask<Result>(
        _ document: EditorDocument,
        kind: DocumentTaskCoordinator.Kind,
        work: @escaping () -> Result,
        completion: @escaping (Result) -> Void
    ) {
        let generation = document.taskCoordinator.begin(kind)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak document, weak operation] in
            guard let document, let operation, !operation.isCancelled else { return }
            let signpostID = OSSignpostID(log: taskPerformanceLog)
            os_signpost(
                .begin,
                log: taskPerformanceLog,
                name: documentTaskSignpostName(for: kind),
                signpostID: signpostID
            )
            let result = work()
            os_signpost(
                .end,
                log: taskPerformanceLog,
                name: documentTaskSignpostName(for: kind),
                signpostID: signpostID
            )
            guard !operation.isCancelled,
                  document.taskCoordinator.isCurrent(generation, for: kind) else { return }
            DispatchQueue.main.async { [weak document] in
                guard let document,
                      document.taskCoordinator.isCurrent(generation, for: kind) else { return }
                document.taskCoordinator.finish(kind, generation: generation)
                completion(result)
            }
        }
        document.taskCoordinator.attach(operation, kind: kind, generation: generation)
        documentTaskQueue.addOperation(operation)
    }

    private func performCancellableDocumentTask<Result>(
        _ document: EditorDocument,
        kind: DocumentTaskCoordinator.Kind,
        work: @escaping (@escaping () -> Bool) -> Result,
        completion: @escaping (Result) -> Void
    ) {
        let generation = document.taskCoordinator.begin(kind)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak document, weak operation] in
            guard let document, let operation, !operation.isCancelled else { return }
            let signpostID = OSSignpostID(log: taskPerformanceLog)
            os_signpost(.begin, log: taskPerformanceLog, name: documentTaskSignpostName(for: kind), signpostID: signpostID)
            let result = work { operation.isCancelled }
            os_signpost(.end, log: taskPerformanceLog, name: documentTaskSignpostName(for: kind), signpostID: signpostID)
            guard !operation.isCancelled,
                  document.taskCoordinator.isCurrent(generation, for: kind) else { return }
            DispatchQueue.main.async { [weak document] in
                guard let document,
                      document.taskCoordinator.isCurrent(generation, for: kind) else { return }
                document.taskCoordinator.finish(kind, generation: generation)
                completion(result)
            }
        }
        document.taskCoordinator.attach(operation, kind: kind, generation: generation)
        documentTaskQueue.addOperation(operation)
    }

    private func isTaskResultCurrent(
        _ document: EditorDocument,
        revision: UInt
    ) -> Bool {
        documents.contains(where: { $0.id == document.id })
            && document.textRevision == revision
            && !document.hasPendingLiveEdits
    }

    @discardableResult
    private func tableInsertionSource(_ snapshot: DocumentTextSnapshot, _ selection: EditorTextSelectionSnapshot) -> (NSString, NSRange) {
        guard let target = selection.virtualTableTarget else { return (snapshot.text as NSString, selection.range) }
        let prefix = String(repeating: "|", count: target.separators)
        let text = (snapshot.text as NSString).replacingCharacters(in: target.range, with: prefix) as NSString
        return (text, NSRange(location: target.range.location + (prefix as NSString).length, length: 0))
    }

    private func markdownLocalImageURL(_ image: MarkdownImageUploadService.Image, text: String, documentURL: URL?) throws -> URL? {
        let address = image.address
        let url: URL
        if MarkdownResourcePaths.requiresRoot(address) {
            let paths = try MarkdownResourcePaths(text: text, document: documentURL)
            guard let resolved = try? MarkdownImageUploadService.localURL(address: address, document: documentURL, paths: paths) else { return nil }
            url = resolved
        } else {
            guard let resolved = try? MarkdownImageUploadService.localURL(address: address, document: documentURL) else { return nil }
            url = resolved
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func imagesReferencedByAnotherOpenDocument(_ sources: [URL], excluding document: EditorDocument) throws -> Bool {
        guard !sources.isEmpty else { return false }
        guard let windowManager else { return true }
        let identities = sources.map(DocumentFileIdentity.resolve)
        let identifiers = Set(identities.compactMap(\.resourceIdentifier))
        let unknownPaths = Set(identities.filter { $0.resourceIdentifier == nil }.map(\.canonicalPath))
        let allPaths = Set(identities.map(\.canonicalPath))
        for open in windowManager.documentsForAI where open !== document && open.language == .markdown {
            let text = open.synchronizedSnapshot().text
            for image in try MarkdownImageUploadService.images(in: text, allowSharedReference: false) {
                guard let url = try markdownLocalImageURL(image, text: text, documentURL: open.url) else { continue }
                let identity = DocumentFileIdentity.resolve(url)
                if let identifier = identity.resourceIdentifier {
                    if identifiers.contains(identifier) || unknownPaths.contains(identity.canonicalPath) { return true }
                } else if allPaths.contains(identity.canonicalPath) { return true }
            }
        }
        return false
    }

    private func imageMutationFailure(_ error: Error, document: EditorDocument) {
        guard let issue = error as? ImageFileMutationError else {
            document.statusMessage = L10n.tr("图片操作无法撤销：文档或文件已变化")
            return
        }
        switch issue {
        case let .movedWithoutIdentity(url):
            document.statusMessage = L10n.tr("图片操作未完成，文件位于：%@", url.path)
        case let .moveIncomplete(source, destination):
            document.statusMessage = L10n.tr("图片移动未完成，请检查源文件 %@ 和目标文件 %@", source.path, destination.path)
        case .trashedWithoutLocation:
            document.statusMessage = L10n.tr("图片已移到废纸篓，但无法确定位置")
        }
    }

    private func registerMarkdownImageFileUndo(_ state: MarkdownImageFileUndoState, document: EditorDocument,
                                               manager: UndoManager, view: LacTextView, undo: Bool) {
        manager.registerUndo(withTarget: view) { [weak self, weak document, weak manager] target in
            guard let self, let document, let manager else { return }
            self.applyMarkdownImageFileUndo(state, document: document, manager: manager, view: target, undo: undo)
        }
        manager.setActionName(L10n.tr("移动或删除图片"))
    }

    private func applyMarkdownImageFileUndo(_ state: MarkdownImageFileUndoState, document: EditorDocument,
                                            manager: UndoManager, view: LacTextView, undo: Bool) {
        let expected = undo ? state.after : state.before
        guard documents.contains(where: { $0 === document }), selectedDocument === document,
              document.url == state.documentURL, document.ioState == .idle, view.isEditable, !view.hasMarkedText(),
              view.string.utf16.elementsEqual(expected.utf16) else {
            document.statusMessage = L10n.tr("图片操作无法撤销：文档或文件已变化")
            return
        }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false,
            allowsInsertionPoint: true, requiresEditable: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let selection = extraction.result, selection.virtualTableTarget == nil else { return }
        var moved: [(index: Int, old: URL)] = []
        func rollback() -> Bool {
            var complete = true
            for item in moved.reversed() {
                do {
                    let identity = try fileService.moveImageFile(state.files[item.index].current, to: item.old,
                                                                 expectedIdentity: state.files[item.index].identity)
                    state.files[item.index].current = item.old
                    state.files[item.index].identity = identity
                } catch { complete = false }
            }
            return complete
        }
        func reportPaths() {
            let candidates = state.files.flatMap { [$0.source.path, $0.destination?.path, $0.current.path].compactMap { $0 } }
                + state.retainedCopies.map { $0.0.path }
            let existing = Set(candidates.filter { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil })
            let missing = state.files.filter { !existing.contains($0.source.path) && !existing.contains($0.current.path) &&
                !($0.destination.map { existing.contains($0.path) } ?? false) }.map { $0.current.path }
                + state.retainedCopies.filter { !existing.contains($0.0.path) }.map { $0.0.path }
            let paths = Array(existing).sorted() + missing.map { L10n.tr("无法确认：%@", $0) }
            document.statusMessage = L10n.tr("图片操作未完成，请检查文件：%@", paths.joined(separator: "\n"))
        }
        do {
            for (url, revision) in state.retainedCopies {
                guard (try? FileRevisionSnapshot.capture(url)) == revision else {
                    document.statusMessage = L10n.tr("图片操作无法撤销：文档或文件已变化")
                    return
                }
            }
            guard try !imagesReferencedByAnotherOpenDocument(state.files.map(\.current), excluding: document) else {
                document.statusMessage = L10n.tr("图片操作无法撤销：文档或文件已变化")
                return
            }
            for file in state.files {
                guard try fileService.workspaceNodeIdentity(file.current) == file.identity else {
                    document.statusMessage = L10n.tr("图片操作无法撤销：文档或文件已变化")
                    return
                }
                if let target = undo ? file.source : file.destination,
                   (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                    document.statusMessage = L10n.tr("图片操作无法撤销：文档或文件已变化")
                    return
                }
            }
            for index in state.files.indices {
                let file = state.files[index]
                let result: (URL, WorkspaceNodeIdentity)
                if undo { result = (file.source, try fileService.moveImageFile(file.current, to: file.source, expectedIdentity: file.identity)) }
                else if let destination = file.destination { result = (destination, try fileService.moveImageFile(file.current, to: destination, expectedIdentity: file.identity)) }
                else { result = try fileService.trashImageFile(file.current, expectedIdentity: file.identity) }
                state.files[index].current = result.0
                state.files[index].identity = result.1
                moved.append((index, file.current))
            }
            let range = NSRange(location: state.edit.range.location,
                length: undo ? (state.edit.replacement as NSString).length : state.edit.range.length)
            let original = undo ? state.edit.replacement : (state.before as NSString).substring(with: state.edit.range)
            let replacement = undo ? (state.before as NSString).substring(with: state.edit.range) : state.edit.replacement
            let request = EditorRangeReplacementRequest(documentID: document.id, range: range, originalText: original,
                replacementText: replacement, expectedEditorRevision: selection.editorRevision, actionName: L10n.tr("移动或删除图片"))
            request.resultingSelection = undo ? state.selection : state.edit.selectionRange
            request.suppressUndoRegistration = true
            NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
            guard request.wasHandled else {
                if rollback() { document.statusMessage = L10n.tr("图片操作无法撤销：文档或文件已变化") }
                else { reportPaths() }
                return
            }
            registerMarkdownImageFileUndo(state, document: document, manager: manager, view: view, undo: !undo)
        } catch {
            let rolledBack = rollback()
            if state.files.count == 1 && rolledBack { imageMutationFailure(error, document: document) }
            else { reportPaths() }
        }
    }

    func moveAllMarkdownImages(choose: (() -> URL?)? = nil, session: URLSession = .shared,
                               move: ((URL, URL, WorkspaceNodeIdentity) throws -> WorkspaceNodeIdentity)? = nil) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        let documentID = document.id
        func extract() -> EditorTextSelectionSnapshot? {
            let request = EditorTextExtractionRequest(documentID: documentID, allowsTokenAtCaret: false,
                allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        guard let first = extract(), first.virtualTableTarget == nil else { return }
        let snapshot = document.synchronizedSnapshot(), sourceURL = document.url
        guard let selection = extract(), first.matches(selection), !document.hasPendingLiveEdits else { return }
        let folder: URL?
        if let choose { folder = choose() }
        else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            folder = panel.runModal() == .OK ? panel.url : nil
        }
        guard let folder, folder.isFileURL, selectedDocument === document, document.url == sourceURL,
              manager.activeState === self, manager.ownsVisibleState(self, window: window),
              let before = extract(), selection.matches(before) else { return }
        let current = document.synchronizedSnapshot()
        guard let after = extract(), selection.matches(after), current == snapshot,
              current.text.utf16.elementsEqual(snapshot.text.utf16), !document.hasPendingLiveEdits else { return }
        imageUploads.removeValue(forKey: documentID)?.1.cancel()
        imagePolicyOperations.removeValue(forKey: documentID)?.cancel()
        imageCopyOperations.removeValue(forKey: documentID)?.cancel()
        let generation = UUID(), files = fileService
        document.statusMessage = L10n.tr("正在移动图片…")
        let task = Task.detached { [weak self, weak document, weak manager, weak window] in
            let outcome: Result<MarkdownImageCopyService.MoveAllPlan, Error>
            do { outcome = .success(try await MarkdownImageCopyService.prepareMoveAll(text: snapshot.text, selection: selection.range,
                document: sourceURL, folder: folder, files: files, session: session)) }
            catch { outcome = .failure(error) }
            guard !Task.isCancelled else { return }
            let capturedSelf = self, capturedDocument = document, capturedManager = manager, capturedWindow = window
            await MainActor.run { [weak self = capturedSelf, weak document = capturedDocument, weak manager = capturedManager, weak window = capturedWindow] in
                guard let self, self.imageUploads[documentID]?.0 == generation else { return }
                self.imageUploads.removeValue(forKey: documentID)
                guard let document, let manager, let window, self.selectedDocument === document,
                      document.url == sourceURL, document.language == .markdown, document.ioState == .idle,
                      manager.activeState === self, manager.ownsVisibleState(self, window: window),
                      let before = extract(), selection.matches(before) else { return }
                let current = document.synchronizedSnapshot()
                guard let after = extract(), selection.matches(after), current == snapshot,
                      current.text.utf16.elementsEqual(snapshot.text.utf16), !document.hasPendingLiveEdits else { return }
                guard case let .success(plan) = outcome else {
                    if case let .failure(error) = outcome, !(error is CancellationError) {
                        document.statusMessage = L10n.tr("图片操作失败：%@", error.localizedDescription)
                    }
                    return
                }
                var moved: [MarkdownImageFileUndoState.File] = [], created: [URL] = []
                var retainedCopies: [(URL, FileRevisionSnapshot)] = []
                func reportPaths() {
                    let candidates = plan.items.flatMap { [$0.source?.path, $0.destination.path].compactMap { $0 } } + created.map(\.path)
                    let existing = Set(candidates.filter { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil })
                    let missing = plan.items.filter { item in
                        let sourceExists = item.source.map { existing.contains($0.path) } ?? false
                        return !sourceExists && !existing.contains(item.destination.path)
                    }.map { $0.destination.path }
                    let paths = Array(existing).sorted() + missing.map { L10n.tr("无法确认：%@", $0) }
                    document.statusMessage = L10n.tr("图片操作未完成，请检查文件：%@", paths.joined(separator: "\n"))
                }
                @MainActor func rollback() -> Bool {
                    var complete = true
                    for file in moved.reversed() {
                        do { _ = try self.fileService.moveImageFile(file.current, to: file.source, expectedIdentity: file.identity) }
                        catch { complete = false }
                    }
                    return complete
                }
                do {
                    guard try !self.imagesReferencedByAnotherOpenDocument(plan.items.compactMap(\.source), excluding: document) else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    for item in plan.items {
                        guard (try? FileManager.default.attributesOfItem(atPath: item.destination.path)) == nil else {
                            throw FileServiceError.destinationExists
                        }
                        if let source = item.source, let identity = item.identity {
                            guard try self.fileService.workspaceNodeIdentity(source) == identity else {
                                throw CocoaError(.fileWriteNoPermission)
                            }
                        }
                    }
                    for item in plan.items {
                        if let source = item.source, let identity = item.identity {
                            let newIdentity: WorkspaceNodeIdentity
                            if let move { newIdentity = try move(source, item.destination, identity) }
                            else { newIdentity = try self.fileService.moveImageFile(source, to: item.destination, expectedIdentity: identity) }
                            moved.append(.init(source: source, destination: item.destination, current: item.destination, identity: newIdentity))
                        } else if let data = item.data {
                            try data.write(to: item.destination, options: .withoutOverwriting)
                            created.append(item.destination)
                            retainedCopies.append((item.destination, try FileRevisionSnapshot.capture(item.destination)))
                        }
                    }
                    let edit = plan.edit
                    let changed = (snapshot.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                    let request = EditorRangeReplacementRequest(documentID: documentID, range: edit.range,
                        originalText: (snapshot.text as NSString).substring(with: edit.range), replacementText: edit.replacement,
                        expectedEditorRevision: selection.editorRevision, actionName: L10n.tr("移动全部图片"))
                    request.resultingSelection = edit.selectionRange
                    request.groupsUndo = true
                    if !moved.isEmpty || !retainedCopies.isEmpty {
                        let state = MarkdownImageFileUndoState(files: moved, retainedCopies: retainedCopies, documentURL: sourceURL, before: snapshot.text,
                            after: changed, edit: edit, selection: selection.range)
                        request.suppressUndoRegistration = true
                        request.registerImageFileUndo = { [weak self, weak document] undoManager, view in
                            guard let self, let document else { return }
                            self.registerMarkdownImageFileUndo(state, document: document, manager: undoManager, view: view, undo: true)
                        }
                    }
                    NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
                    if !request.wasHandled { _ = rollback(); reportPaths() }
                } catch {
                    _ = rollback()
                    reportPaths()
                }
            }
        }
        imageUploads[documentID] = (generation, task)
    }

    func moveOrDeleteMarkdownImage(deleteOriginal: Bool, choose: ((URL) -> URL?)? = nil,
                                   confirm: ((URL) -> Bool)? = nil, afterMove: (() -> Void)? = nil) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        func extract() -> EditorTextSelectionSnapshot? {
            let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false,
                allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        guard let first = extract(), first.virtualTableTarget == nil else { return }
        let snapshot = document.synchronizedSnapshot(), documentURL = document.url
        guard let selection = extract(), first.matches(selection), !document.hasPendingLiveEdits else { return }
        do {
            let selected = try MarkdownImageUploadService.images(in: snapshot.text, selection: selection.range, allowSharedReference: false)
            guard selected.count == 1, let image = selected.first,
                  let source = try markdownLocalImageURL(image, text: snapshot.text, documentURL: documentURL) else {
                document.statusMessage = L10n.tr("请选择一个本地图片")
                return
            }
            let identity = try fileService.workspaceNodeIdentity(source)
            let destination: URL?
            if deleteOriginal {
                let approved: Bool
                if let confirm { approved = confirm(source) }
                else {
                    let alert = NSAlert()
                    alert.messageText = L10n.tr("删除图片并移到废纸篓？")
                    alert.informativeText = L10n.tr("其他未打开的文档可能仍引用此文件。")
                    alert.addButton(withTitle: L10n.tr("移到废纸篓"))
                    alert.addButton(withTitle: L10n.tr("取消"))
                    approved = alert.runModal() == .alertFirstButtonReturn
                }
                guard approved else { return }
                destination = nil
            } else if let choose { destination = choose(source) }
            else {
                let panel = NSSavePanel()
                panel.directoryURL = source.deletingLastPathComponent()
                panel.nameFieldStringValue = source.lastPathComponent
                destination = panel.runModal() == .OK ? panel.url : nil
            }
            if !deleteOriginal {
                guard let destination, destination.isFileURL, destination.standardizedFileURL != source,
                      destination.pathExtension.lowercased() == source.pathExtension.lowercased() else { return }
            }
            guard selectedDocument === document, document.url == documentURL, document.language == .markdown,
                  document.ioState == .idle, manager.activeState === self, manager.ownsVisibleState(self, window: window),
                  let before = extract(), selection.matches(before) else { return }
            let current = document.synchronizedSnapshot()
            guard let after = extract(), selection.matches(after), current == snapshot,
                  current.text.utf16.elementsEqual(snapshot.text.utf16), !document.hasPendingLiveEdits,
                  try fileService.workspaceNodeIdentity(source) == identity else { return }
            let sourceIdentity = DocumentFileIdentity.resolve(source)
            var matching: [MarkdownImageUploadService.Image] = []
            for open in manager.documentsForAI where open.language == .markdown {
                let text = open === document ? snapshot.text : open.synchronizedSnapshot().text
                let images = try MarkdownImageUploadService.images(in: text, allowSharedReference: false)
                for candidate in images {
                    guard let url = try markdownLocalImageURL(candidate, text: text, documentURL: open.url),
                          DocumentFileIdentity.resolve(url).matches(sourceIdentity) else { continue }
                    guard open === document else {
                        document.statusMessage = L10n.tr("图片仍被其他打开的文档引用")
                        return
                    }
                    matching.append(candidate)
                }
            }
            let occurrences = matching.reduce(0) { $0 + max(1, $1.inlineReferences.count) }
            guard !matching.isEmpty, !deleteOriginal || occurrences == 1 else {
                document.statusMessage = L10n.tr("图片仍被当前文档引用")
                return
            }
            let edit: MarkdownFormattingEdit
            if deleteOriginal {
                edit = MarkdownFormattingEdit(range: image.range, replacement: "", selectionRange: NSRange(location: image.range.location, length: 0))
            } else {
                guard let destination, let address = MarkdownImageEditingService.address(for: destination, document: documentURL),
                      let url = URL(string: address) else { throw MarkdownImageUploadService.UploadError.invalidInput }
                edit = try MarkdownImageUploadService.replacement(in: snapshot.text, images: matching,
                    urls: Array(repeating: url, count: matching.count), selection: selection.range)
            }
            let moved: (URL, WorkspaceNodeIdentity)
            if let destination { moved = (destination, try fileService.moveImageFile(source, to: destination, expectedIdentity: identity)) }
            else { moved = try fileService.trashImageFile(source, expectedIdentity: identity) }
            afterMove?()
            let changed = (snapshot.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            let file = MarkdownImageFileUndoState.File(source: source, destination: destination, current: moved.0, identity: moved.1)
            let state = MarkdownImageFileUndoState(files: [file], documentURL: documentURL,
                before: snapshot.text, after: changed, edit: edit, selection: selection.range)
            let request = EditorRangeReplacementRequest(documentID: document.id, range: edit.range,
                originalText: (snapshot.text as NSString).substring(with: edit.range), replacementText: edit.replacement,
                expectedEditorRevision: selection.editorRevision, actionName: L10n.tr("移动或删除图片"))
            request.resultingSelection = edit.selectionRange
            request.groupsUndo = true
            request.suppressUndoRegistration = true
            request.registerImageFileUndo = { [weak self, weak document] undoManager, view in
                guard let self, let document else { return }
                self.registerMarkdownImageFileUndo(state, document: document, manager: undoManager, view: view, undo: true)
            }
            NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
            if !request.wasHandled {
                do { _ = try fileService.moveImageFile(moved.0, to: source, expectedIdentity: moved.1) }
                catch let issue as ImageFileMutationError { imageMutationFailure(issue, document: document); return }
                catch { document.statusMessage = L10n.tr("图片操作未完成，文件位于：%@", moved.0.path); return }
                document.statusMessage = L10n.tr("图片操作未完成")
            }
        } catch let issue as ImageFileMutationError { imageMutationFailure(issue, document: document) }
        catch { document.statusMessage = L10n.tr("图片操作失败：%@", error.localizedDescription) }
    }

    func copyMarkdownImages(selectedOnly: Bool, remoteOnly: Bool, choose: (() -> URL?)? = nil,
                            session: URLSession = .shared) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        let documentID = document.id
        func extract() -> EditorTextSelectionSnapshot? {
            let request = EditorTextExtractionRequest(documentID: documentID, allowsTokenAtCaret: false,
                allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        guard let first = extract(), first.virtualTableTarget == nil else { return }
        let snapshot = document.synchronizedSnapshot(), sourceURL = document.url
        guard let selection = extract(), first.matches(selection), !document.hasPendingLiveEdits else { return }
        let folder: URL?
        if let choose { folder = choose() }
        else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            folder = panel.runModal() == .OK ? panel.url : nil
        }
        guard let folder, folder.isFileURL, selectedDocument === document, document.url == sourceURL,
              document.language == .markdown, document.ioState == .idle, manager.activeState === self,
              manager.ownsVisibleState(self, window: window), let before = extract(), selection.matches(before) else { return }
        let current = document.synchronizedSnapshot()
        guard let after = extract(), selection.matches(after), current == snapshot, !document.hasPendingLiveEdits else { return }
        imageUploads.removeValue(forKey: documentID)?.1.cancel()
        imagePolicyOperations.removeValue(forKey: documentID)?.cancel()
        imageCopyOperations.removeValue(forKey: documentID)?.cancel()
        let generation = UUID()
        document.statusMessage = L10n.tr("正在复制图片…")
        let task = Task.detached { [weak self, weak document, weak manager, weak window] in
            let outcome: Result<MarkdownImageCopyService.BatchResult, Error>
            do {
                outcome = .success(try await MarkdownImageCopyService.prepare(text: snapshot.text, selection: selection.range,
                    selectedOnly: selectedOnly, remoteOnly: remoteOnly, document: sourceURL, folder: folder,
                    session: session, isCancelled: { Task.isCancelled }))
            } catch { outcome = .failure(error) }
            let capturedSelf = self, capturedDocument = document, capturedManager = manager, capturedWindow = window
            await MainActor.run { [weak self = capturedSelf, weak document = capturedDocument, weak manager = capturedManager, weak window = capturedWindow] in
                func report(_ message: String) {
                    let notice = ClipboardSavedImagesNotice(documentID: documentID, message: message)
                    NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
                    if !notice.handled, let document { notice.deliver(to: document) }
                }
                func reportCreated(_ urls: [URL]) {
                    guard !urls.isEmpty else { return }
                    report(MarkdownImageCopyService.PartialFailure(created: urls, reason: L10n.tr("文档已变化，未应用图片链接")).localizedDescription)
                }
                if case let .failure(error as MarkdownImageCopyService.PartialFailure) = outcome {
                    report(error.localizedDescription)
                    if let self, self.imageUploads[documentID]?.0 == generation { self.imageUploads.removeValue(forKey: documentID) }
                    return
                }
                if case let .success(result) = outcome,
                   (Task.isCancelled || self == nil || self?.imageUploads[documentID]?.0 != generation) {
                    reportCreated(result.created)
                    return
                }
                guard let self, self.imageUploads[documentID]?.0 == generation else { return }
                self.imageUploads.removeValue(forKey: documentID)
                guard let document, self.documents.contains(where: { $0 === document }),
                      let manager, let window, self.selectedDocument === document, manager.activeState === self,
                      manager.ownsVisibleState(self, window: window), document.language == .markdown,
                      document.ioState == .idle, document.url == sourceURL,
                      let before = extract(), selection.matches(before) else {
                    if case let .success(result) = outcome { reportCreated(result.created) }
                    return
                }
                let now = document.synchronizedSnapshot()
                guard let after = extract(), selection.matches(after), now == snapshot, !document.hasPendingLiveEdits else {
                    if case let .success(result) = outcome { reportCreated(result.created) }
                    return
                }
                switch outcome {
                case let .failure(error):
                    if !(error is CancellationError) { document.statusMessage = L10n.tr("图片复制失败：%@", error.localizedDescription) }
                case let .success(result):
                    let edit = result.edit
                    let request = EditorRangeReplacementRequest(documentID: documentID, range: edit.range,
                        originalText: (snapshot.text as NSString).substring(with: edit.range), replacementText: edit.replacement,
                        expectedEditorRevision: selection.editorRevision, actionName: L10n.tr("复制图片"))
                    request.resultingSelection = edit.selectionRange
                    request.groupsUndo = true
                    NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
                    if request.wasHandled { document.statusMessage = L10n.tr("图片已复制") }
                    else { reportCreated(result.created) }
                }
            }
        }
        imageUploads[documentID] = (generation, task)
    }

    func uploadMarkdownImages(selectedOnly: Bool) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        let config = preferences.markdownImageUploadConfiguration
        guard config.method == "picgo" || config.method == "piclist" || config.method == "upic" || config.method == "picsee" || config.method == "ipic" || config.method == "command" else {
            document.statusMessage = L10n.tr("请先在设置中选择图片上传方式")
            return
        }
        let documentID = document.id
        func extract() -> EditorTextSelectionSnapshot? {
            let request = EditorTextExtractionRequest(documentID: documentID, allowsTokenAtCaret: false,
                allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        guard let first = extract() else { return }
        let snapshot = document.synchronizedSnapshot()
        guard let selection = extract(), first.matches(selection), selection.virtualTableTarget == nil,
              !document.hasPendingLiveEdits else { return }
        let sourceURL = document.url
        imageUploads.removeValue(forKey: documentID)?.1.cancel()
        imagePolicyOperations.removeValue(forKey: documentID)?.cancel()
        imageCopyOperations.removeValue(forKey: documentID)?.cancel()
        let generation = UUID()
        document.statusMessage = L10n.tr("正在上传图片…")
        let task = Task.detached { [weak self, weak document, weak manager, weak window] in
            let outcome: Result<(MarkdownFormattingEdit, [URL]), Error>
            do {
                let all = try MarkdownImageUploadService.images(in: snapshot.text, selection: selectedOnly ? selection.range : nil, isCancelled: { Task.isCancelled })
                let images = all.filter { image in
                    let scheme = URL(string: image.address)?.scheme?.lowercased()
                    return scheme == nil || scheme == "file" || scheme == "data"
                }
                guard !images.isEmpty else { throw MarkdownImageUploadService.UploadError.invalidInput }
                let paths: MarkdownResourcePaths?
                if images.contains(where: { MarkdownResourcePaths.requiresRoot($0.address) }) {
                    paths = try MarkdownResourcePaths(text: snapshot.text, document: sourceURL)
                } else { paths = nil }
                let payloads = try images.map { try MarkdownImageUploadService.payload(address: $0.address, document: sourceURL, paths: paths) }
                let urls = try await MarkdownImageUploadService.upload(payloads, method: config.method, endpoint: config.endpoint,
                    executable: config.executable, arguments: config.arguments, document: sourceURL, isCancelled: { Task.isCancelled })
                do {
                    if Task.isCancelled { throw CancellationError() }
                    let edit = try MarkdownImageUploadService.replacement(in: snapshot.text, images: images, urls: urls, selection: selection.range, isCancelled: { Task.isCancelled })
                    outcome = .success((edit, urls))
                } catch {
                    if config.method == "piclist" { throw MarkdownImageUploadService.UploadError.picListPartial(urls.map(\.absoluteString), error.localizedDescription) }
                    if config.method == "upic" { throw MarkdownImageUploadService.UploadError.uPicPartial(urls.map(\.absoluteString), error.localizedDescription) }
                    if config.method == "picsee" { throw MarkdownImageUploadService.UploadError.picseePartial(urls.map(\.absoluteString), error.localizedDescription) }
                    if config.method == "ipic" { throw MarkdownImageUploadService.UploadError.iPicPartial(urls.map(\.absoluteString), error.localizedDescription) }
                    throw error
                }
            } catch { outcome = .failure(error) }
            let capturedSelf = self, capturedDocument = document, capturedManager = manager, capturedWindow = window
            await MainActor.run { [weak self = capturedSelf, weak document = capturedDocument, weak manager = capturedManager, weak window = capturedWindow] in
                func reportUploaded(_ urls: [URL]) {
                    let error: MarkdownImageUploadService.UploadError = config.method == "ipic"
                        ? .iPicPartial(urls.map(\.absoluteString), L10n.tr("文档已变化，未应用上传结果")) : config.method == "picsee"
                        ? .picseePartial(urls.map(\.absoluteString), L10n.tr("文档已变化，未应用上传结果")) : config.method == "upic"
                        ? .uPicPartial(urls.map(\.absoluteString), L10n.tr("文档已变化，未应用上传结果"))
                        : .picListPartial(urls.map(\.absoluteString), L10n.tr("文档已变化，未应用上传结果"))
                    let notice = ClipboardSavedImagesNotice(documentID: documentID, message: error.localizedDescription)
                    NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
                    if !notice.handled, let document { notice.deliver(to: document) }
                }
                if case let .success((_, urls)) = outcome, ["piclist", "upic", "picsee", "ipic"].contains(config.method),
                   (Task.isCancelled || self == nil || self?.imageUploads[documentID]?.0 != generation) {
                    reportUploaded(urls)
                    return
                }
                if case let .failure(error) = outcome,
                   let issue = error as? MarkdownImageUploadService.UploadError, issue.reportsUploadedResources {
                    let notice = ClipboardSavedImagesNotice(documentID: documentID, message: error.localizedDescription)
                    NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
                    if !notice.handled, let document { notice.deliver(to: document) }
                    if let self, self.imageUploads[documentID]?.0 == generation { self.imageUploads.removeValue(forKey: documentID) }
                    return
                }
                guard let self, self.imageUploads[documentID]?.0 == generation else { return }
                self.imageUploads.removeValue(forKey: documentID)
                guard let document, self.documents.contains(where: { $0 === document }) else { return }
                guard let manager, let window, self.selectedDocument === document,
                      manager.activeState === self, manager.ownsVisibleState(self, window: window),
                      document.language == .markdown, document.ioState == .idle, document.url == sourceURL,
                      self.preferences.markdownImageUploadConfiguration == config,
                      let before = extract(), selection.matches(before) else {
                    if case let .success((_, urls)) = outcome, ["piclist", "upic", "picsee", "ipic"].contains(config.method) { reportUploaded(urls) }
                    else { document.statusMessage = L10n.tr("文档已变化，未应用上传结果") }
                    return
                }
                let now = document.synchronizedSnapshot()
                guard let after = extract(), selection.matches(after), now == snapshot, !document.hasPendingLiveEdits else {
                    if case let .success((_, urls)) = outcome, ["piclist", "upic", "picsee", "ipic"].contains(config.method) { reportUploaded(urls) }
                    else { document.statusMessage = L10n.tr("文档已变化，未应用上传结果") }
                    return
                }
                switch outcome {
                case let .failure(error):
                    if error is CancellationError { return }
                    document.statusMessage = L10n.tr("图片上传失败：%@", error.localizedDescription)
                case let .success((edit, urls)):
                    let request = EditorRangeReplacementRequest(documentID: documentID, range: edit.range,
                        originalText: (snapshot.text as NSString).substring(with: edit.range), replacementText: edit.replacement,
                        expectedEditorRevision: selection.editorRevision, actionName: L10n.tr("上传图片"))
                    request.resultingSelection = edit.selectionRange
                    request.groupsUndo = true
                    NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
                    if !request.wasHandled && ["piclist", "upic", "picsee", "ipic"].contains(config.method) { reportUploaded(urls) }
                    else { document.statusMessage = request.wasHandled ? L10n.tr("图片已上传") : L10n.tr("文档已变化，未应用上传结果") }
                }
            }
        }
        imageUploads[documentID] = (generation, task)
    }

    nonisolated private static func identifyMarkdownImage(_ source: MarkdownImageTransfer) -> (Data?, URL?, String)? {
        switch source {
        case let .file(url):
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(image) > 0,
                  let identifier = CGImageSourceGetType(image) as String?, UTType(identifier)?.conforms(to: .image) == true else { return nil }
            return (nil, url, identifier)
        case let .data(data):
            guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
                  let identifier = CGImageSourceGetType(image) as String?, UTType(identifier)?.conforms(to: .image) == true else { return nil }
            return (data, nil, identifier)
        case let .remote(url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return (nil, url, "")
        }
    }

    func presentMarkdownImage(transfer: MarkdownImageTransfer? = nil,
                              identify: ((MarkdownImageTransfer) -> (Data?, URL?, String)?)? = nil,
                              copyImage: ((MarkdownImageUploadService.Payload, URL, String?, () -> Bool) throws -> URL)? = nil) -> Bool {
        if case .some(.remote(_)) = transfer, !preferences.markdownImageUploadConfiguration.automaticOnline { return false }
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return false }
        let documentID = document.id
        let extract: () -> EditorTextSelectionSnapshot? = {
            let request = EditorTextExtractionRequest(documentID: documentID, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        guard let first = extract() else { return false }
        let snapshot = document.synchronizedSnapshot()
        guard let selection = extract(), first.matches(selection), selectedDocument === document,
              !document.hasPendingLiveEdits else { return false }
        let (editingSource, editingSelection) = tableInsertionSource(snapshot, selection)
        guard let initial = MarkdownImageEditingService.initial(in: editingSource, selection: editingSelection) else { return false }
        let originalURL = document.url
        let current: () -> Bool = { [weak self, weak document, weak window, weak manager] in
            guard let self, let document, let window, let manager, manager.activeState === self, manager.ownsVisibleState(self, window: window), self.selectedDocument === document,
                  document.language == .markdown, document.ioState == .idle, document.url == originalURL,
                  let before = extract(), selection.matches(before) else { return false }
            let now = document.synchronizedSnapshot()
            guard let after = extract(), selection.matches(after), !document.hasPendingLiveEdits else { return false }
            return now == snapshot
        }
        let reportStale: (String) -> Void = { [weak self, weak document] message in
            guard let document else { return }
            let otherWork = self?.imageUploads[documentID] != nil || self?.imageCopyOperations[documentID] != nil
            if otherWork, let existing = document.statusMessage, !existing.isEmpty, existing != message {
                document.statusMessage = existing + "\n" + message
            } else { document.statusMessage = message }
        }
        let ask: (String, Bool, Bool) -> MarkdownImageInput? = { proposedAddress, allowAddressEditing, pendingUpload in
            let alt = NSTextField(string: initial.alt)
            let address = NSTextField(string: pendingUpload ? L10n.tr("处理后生成地址") : proposedAddress)
            address.isEditable = allowAddressEditing
            let title = NSTextField(string: initial.title)
            let fields = NSStackView(views: [NSTextField(labelWithString: L10n.tr("图片替代文字")), alt,
                NSTextField(labelWithString: L10n.tr("图片地址")), address,
                NSTextField(labelWithString: L10n.tr("图片标题")), title])
            fields.orientation = .vertical
            fields.alignment = .leading
            fields.spacing = 6
            fields.frame = NSRect(x: 0, y: 0, width: 360, height: 150)
            for field in [alt, address, title] { field.widthAnchor.constraint(equalToConstant: 360).isActive = true }
            let alert = NSAlert()
            alert.messageText = L10n.tr("图片")
            alert.accessoryView = fields
            alert.addButton(withTitle: L10n.tr("应用"))
            alert.addButton(withTitle: L10n.tr("取消"))
            while alert.runModal() == .alertFirstButtonReturn {
                guard current() else { reportStale(L10n.tr("文档已变化，未插入图片")); return nil }
                let input = MarkdownImageInput(alt: alt.stringValue, address: pendingUpload ? proposedAddress : address.stringValue, title: title.stringValue)
                if MarkdownImageEditingService.edit(in: editingSource, selection: editingSelection, input: input) != nil { return input }
                alert.informativeText = L10n.tr("无法创建此图片，请检查地址和文字")
            }
            return nil
        }
        let apply: (MarkdownImageInput) -> Bool = { input in
            guard current(), let edit = MarkdownImageEditingService.edit(in: editingSource, selection: editingSelection, input: input) else { return false }
            let target = selection.virtualTableTarget
            guard target == nil || edit.range == editingSelection else { return false }
            let range = target?.range ?? edit.range
            let replacement = String(repeating: "|", count: target?.separators ?? 0) + edit.replacement
            let request = EditorRangeReplacementRequest(documentID: documentID, range: range,
                originalText: (snapshot.text as NSString).substring(with: range), replacementText: replacement,
                expectedEditorRevision: selection.editorRevision, actionName: L10n.tr("插入图片"))
            request.virtualTableTarget = target
            request.resultingSelection = edit.selectionRange
            request.groupsUndo = true
            NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
            return request.wasHandled
        }
        if case .none = transfer, !initial.address.isEmpty {
            if let input = ask(initial.address, true, false) { _ = apply(input) }
            return true
        }
        var source = transfer
        if case .none = source {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url, current() else { return true }
            source = .file(url)
        }
        guard let source else { return true }
        let readImage = identify ?? Self.identifyMarkdownImage
        let writeCopy = copyImage ?? { payload, folder, name, cancelled in
            try MarkdownImageCopyService.copy(payload, to: folder, name: name, isCancelled: cancelled)
        }
        let uploadConfig = preferences.markdownImageUploadConfiguration
        imagePolicyOperations.removeValue(forKey: documentID)?.cancel()
        imageCopyOperations.removeValue(forKey: documentID)?.cancel()
        let policyOperation = BlockOperation()
        if uploadConfig.allowDocumentPolicy || uploadConfig.allowDocumentCopy { imagePolicyOperations[documentID] = policyOperation }
        Task { @MainActor [weak self, weak manager, weak document] in
            defer {
                if let self, self.imagePolicyOperations[documentID] === policyOperation { self.imagePolicyOperations.removeValue(forKey: documentID) }
            }
            let identified = await Task.detached { readImage(source) }.value
            guard current(), self?.preferences.markdownImageUploadConfiguration == uploadConfig else {
                reportStale(L10n.tr("文档已变化，未插入图片"))
                return
            }
            guard let (data, selectedURL, identifier) = identified else {
                document?.statusMessage = L10n.tr("无法读取图片")
                return
            }
            let isRemote: Bool
            if case .remote = source { isRemote = true } else { isRemote = false }
            var automaticUpload = isRemote ? uploadConfig.automaticOnline : uploadConfig.automaticLocal
            var effectiveUploadConfig = uploadConfig
            var copyPath: String? = isRemote || uploadConfig.copyFolder.isEmpty ? nil : uploadConfig.copyFolder
            if uploadConfig.allowDocumentPolicy || uploadConfig.allowDocumentCopy {
                let policy = await Task.detached { Result { try MarkdownImageUploadService.documentPolicy(in: snapshot.text, isCancelled: { policyOperation.isCancelled }) } }.value
                guard let self else { return }
                guard self.imagePolicyOperations[documentID] === policyOperation else { return }
                self.imagePolicyOperations.removeValue(forKey: documentID)
                guard current(), self.preferences.markdownImageUploadConfiguration == uploadConfig else {
                    reportStale(L10n.tr("文档已变化，未插入图片"))
                    return
                }
                switch policy {
                case .success(.absent): break
                case .success(.upload):
                    if uploadConfig.allowDocumentPolicy { automaticUpload = isRemote ? uploadConfig.automaticOnline : true; copyPath = nil }
                case let .success(.other(path)):
                    if path == "ipic" {
                        if uploadConfig.allowDocumentPolicy {
                            effectiveUploadConfig.method = "ipic"
                            automaticUpload = isRemote ? uploadConfig.automaticOnline : true
                            copyPath = nil
                        }
                    } else if uploadConfig.allowDocumentCopy && !isRemote {
                        copyPath = path
                        automaticUpload = false
                    }
                case let .failure(error):
                    if !(error is CancellationError) { document?.statusMessage = L10n.tr("图片插入设置错误：%@", error.localizedDescription) }
                    return
                }
            }
            if automaticUpload {
                guard let self else { return }
                let config = effectiveUploadConfig
                guard config.method == "picgo" || config.method == "piclist" || config.method == "upic" || config.method == "picsee" || config.method == "ipic" || config.method == "command" else {
                    document?.statusMessage = L10n.tr("请先在设置中选择图片上传方式")
                    return
                }
                let proposed = selectedURL.flatMap { MarkdownImageEditingService.address(for: $0, document: originalURL) }
                    ?? "https://laceditor.invalid/upload"
                guard let input = ask(proposed, false, data != nil || isRemote), current(), self.preferences.markdownImageUploadConfiguration == uploadConfig else { return }
                self.imageUploads.removeValue(forKey: documentID)?.1.cancel()
                let generation = UUID()
                document?.statusMessage = L10n.tr("正在上传图片…")
                let task = Task.detached { [weak self, weak document] in
                    let outcome: Result<URL, Error>
                    do {
                        let payload: MarkdownImageUploadService.Payload
                        if let selectedURL, isRemote { payload = try await MarkdownImageUploadService.download(selectedURL) }
                        else if let selectedURL { payload = try MarkdownImageUploadService.payload(address: selectedURL.absoluteString, document: originalURL) }
                        else if let data { payload = try MarkdownImageUploadService.payload(data: data) }
                        else { throw MarkdownImageUploadService.UploadError.invalidInput }
                        let urls = try await MarkdownImageUploadService.upload([payload], method: config.method, endpoint: config.endpoint,
                            executable: config.executable, arguments: config.arguments, document: originalURL, isCancelled: { Task.isCancelled })
                        guard let url = urls.first else { throw MarkdownImageUploadService.UploadError.invalidResult }
                        if Task.isCancelled {
                            if config.method == "piclist" { throw MarkdownImageUploadService.UploadError.picListPartial(urls.map(\.absoluteString), L10n.tr("取消")) }
                            if config.method == "upic" { throw MarkdownImageUploadService.UploadError.uPicPartial(urls.map(\.absoluteString), L10n.tr("取消")) }
                            if config.method == "picsee" { throw MarkdownImageUploadService.UploadError.picseePartial(urls.map(\.absoluteString), L10n.tr("取消")) }
                            if config.method == "ipic" { throw MarkdownImageUploadService.UploadError.iPicPartial(urls.map(\.absoluteString), L10n.tr("取消")) }
                            throw CancellationError()
                        }
                        outcome = .success(url)
                    } catch { outcome = .failure(error) }
                    let capturedSelf = self, capturedDocument = document
                    await MainActor.run { [weak self = capturedSelf, weak document = capturedDocument] in
                        func reportUploaded(_ url: URL) {
                            let error: MarkdownImageUploadService.UploadError = config.method == "ipic"
                                ? .iPicPartial([url.absoluteString], L10n.tr("文档已变化，未应用上传结果")) : config.method == "picsee"
                                ? .picseePartial([url.absoluteString], L10n.tr("文档已变化，未应用上传结果")) : config.method == "upic"
                                ? .uPicPartial([url.absoluteString], L10n.tr("文档已变化，未应用上传结果"))
                                : .picListPartial([url.absoluteString], L10n.tr("文档已变化，未应用上传结果"))
                            let notice = ClipboardSavedImagesNotice(documentID: documentID, message: error.localizedDescription)
                            NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
                            if !notice.handled, let document { notice.deliver(to: document) }
                        }
                        if case let .success(url) = outcome, ["piclist", "upic", "picsee", "ipic"].contains(config.method),
                           (Task.isCancelled || self == nil || self?.imageUploads[documentID]?.0 != generation) {
                            reportUploaded(url)
                            return
                        }
                        if case let .failure(error) = outcome,
                           let issue = error as? MarkdownImageUploadService.UploadError, issue.reportsUploadedResources {
                            let notice = ClipboardSavedImagesNotice(documentID: documentID, message: error.localizedDescription)
                            NotificationCenter.default.post(name: EditorCommandNotification.clipboardSavedImages, object: notice)
                            if !notice.handled, let document { notice.deliver(to: document) }
                            if let self, self.imageUploads[documentID]?.0 == generation { self.imageUploads.removeValue(forKey: documentID) }
                            return
                        }
                        guard let self, self.imageUploads[documentID]?.0 == generation else { return }
                        self.imageUploads.removeValue(forKey: documentID)
                        guard let document, self.documents.contains(where: { $0 === document }) else { return }
                        guard current(), self.preferences.markdownImageUploadConfiguration == uploadConfig else {
                            if case let .success(url) = outcome, ["piclist", "upic", "picsee", "ipic"].contains(config.method) { reportUploaded(url) }
                            else { document.statusMessage = L10n.tr("文档已变化，未应用上传结果") }
                            return
                        }
                        switch outcome {
                        case let .failure(error):
                            if !(error is CancellationError) { document.statusMessage = L10n.tr("图片上传失败：%@", error.localizedDescription) }
                        case let .success(url):
                            let uploaded = MarkdownImageInput(alt: input.alt, address: url.absoluteString, title: input.title)
                            if apply(uploaded) { document.statusMessage = L10n.tr("图片已上传") }
                            else if ["piclist", "upic", "picsee", "ipic"].contains(config.method) { reportUploaded(url) }
                            else { document.statusMessage = L10n.tr("文档已变化，未应用上传结果") }
                        }
                    }
                }
                self.imageUploads[documentID] = (generation, task)
                return
            }
            if let copyPath, !isRemote {
                let proposed = selectedURL.flatMap { MarkdownImageEditingService.address(for: $0, document: originalURL) }
                    ?? "https://laceditor.invalid/copy"
                guard let input = ask(proposed, false, true), current(), self?.preferences.markdownImageUploadConfiguration == uploadConfig else { return }
                let operation = BlockOperation()
                self?.imageCopyOperations.removeValue(forKey: documentID)?.cancel()
                self?.imageCopyOperations[documentID] = operation
                defer {
                    if let self, self.imageCopyOperations[documentID] === operation { self.imageCopyOperations.removeValue(forKey: documentID) }
                }
                let prepared = await Task.detached { () -> Result<(MarkdownImageUploadService.Payload, URL), Error> in
                    Result {
                        let folder = try MarkdownImageCopyService.folder(path: copyPath, document: originalURL)
                        let payload: MarkdownImageUploadService.Payload
                        if let selectedURL { payload = try MarkdownImageUploadService.payload(address: selectedURL.absoluteString, document: originalURL) }
                        else if let data { payload = try MarkdownImageUploadService.payload(data: data) }
                        else { throw MarkdownImageUploadService.UploadError.invalidInput }
                        return (payload, folder)
                    }
                }.value
                guard current(), self?.preferences.markdownImageUploadConfiguration == uploadConfig, !operation.isCancelled else {
                    reportStale(L10n.tr("文档已变化，未插入图片"))
                    return
                }
                guard case let .success(value) = prepared else {
                    if case let .failure(error) = prepared { document?.statusMessage = L10n.tr("图片复制失败：%@", error.localizedDescription) }
                    return
                }
                let (payload, folder) = value
                var copied = await Task.detached { Result { try writeCopy(payload, folder, nil, { operation.isCancelled }) } }.value
                if case .failure = copied, !operation.isCancelled, current(), self?.preferences.markdownImageUploadConfiguration == uploadConfig {
                    let occupied = folder.appendingPathComponent(payload.filename)
                    let exists = await Task.detached {
                        FileManager.default.fileExists(atPath: occupied.path)
                            || (try? occupied.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                    }.value
                    guard current(), self?.preferences.markdownImageUploadConfiguration == uploadConfig, !operation.isCancelled else { return }
                    if exists {
                        let panel = NSSavePanel()
                        panel.directoryURL = folder
                        panel.nameFieldStringValue = payload.filename
                        if let type = UTType(mimeType: payload.mime) { panel.allowedContentTypes = [type] }
                        guard panel.runModal() == .OK, let destination = panel.url,
                              current(), self?.preferences.markdownImageUploadConfiguration == uploadConfig, !operation.isCancelled else { return }
                        copied = await Task.detached { Result { try writeCopy(payload, destination.deletingLastPathComponent(),
                            destination.lastPathComponent, { operation.isCancelled }) } }.value
                    }
                }
                switch copied {
                case let .failure(error):
                    if !(error is CancellationError) { document?.statusMessage = L10n.tr("图片复制失败：%@", error.localizedDescription) }
                case let .success(destination):
                    guard current(), self?.preferences.markdownImageUploadConfiguration == uploadConfig, !operation.isCancelled,
                          let address = MarkdownImageEditingService.address(for: destination, document: originalURL) else {
                        let message = L10n.tr("图片位于 %@，但文档已变化，未插入", destination.path)
                        reportStale(message)
                        return
                    }
                    if self?.imageCopyOperations[documentID] === operation { self?.imageCopyOperations.removeValue(forKey: documentID) }
                    guard apply(MarkdownImageInput(alt: input.alt, address: address, title: input.title)) else {
                        reportStale(L10n.tr("图片位于 %@，但文档已变化，未插入", destination.path))
                        return
                    }
                    document?.statusMessage = L10n.tr("图片位于 %@", destination.path)
                }
                return
            }
            let destination: URL
            if let selectedURL { destination = selectedURL }
            else {
                let panel = NSSavePanel()
                if let type = UTType(identifier) { panel.allowedContentTypes = [type]; panel.nameFieldStringValue = "image." + (type.preferredFilenameExtension ?? "png") }
                guard panel.runModal() == .OK, let url = panel.url, current() else { return }
                destination = url
            }
            guard let address = MarkdownImageEditingService.address(for: destination, document: originalURL),
                  let input = ask(address, data == nil, false), current() else { return }
            if let data {
                let written = await Task.detached { () -> Bool in
                    do { try data.write(to: destination, options: .withoutOverwriting); return true } catch { return false }
                }.value
                guard written else { document?.statusMessage = L10n.tr("无法保存图片，文件可能已存在"); return }
                guard current(), apply(input) else {
                    manager?.activeState?.selectedDocument?.statusMessage = L10n.tr("图片已保存，但文档已变化，未插入")
                    return
                }
            } else { _ = apply(input) }
        }
        return true
    }

    func presentMarkdownResourceRoot(choose: (() -> URL?)? = nil) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        func extract() -> EditorTextSelectionSnapshot? {
            let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false,
                allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        guard let first = extract(), first.virtualTableTarget == nil else { return }
        let snapshot = document.synchronizedSnapshot(), originalURL = document.url
        guard let selected = extract(), first.matches(selected), selectedDocument === document,
              !document.hasPendingLiveEdits else { return }
        let folder: URL?
        if let choose { folder = choose() }
        else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            folder = panel.runModal() == .OK ? panel.url : nil
        }
        guard let folder, folder.isFileURL, selectedDocument === document, document.url == originalURL,
              document.language == .markdown, document.ioState == .idle,
              manager.activeState === self, manager.ownsVisibleState(self, window: window),
              let before = extract(), selected.matches(before) else { return }
        let current = document.synchronizedSnapshot()
        guard let after = extract(), selected.matches(after), current == snapshot, !document.hasPendingLiveEdits else { return }
        guard let edit = MarkdownImageEditingService.rootPathEdit(in: snapshot.text, path: folder.path, selection: selected.range) else {
            document.statusMessage = L10n.tr("无法更新图片资源根路径")
            return
        }
        let raw = snapshot.text as NSString
        let request = EditorRangeReplacementRequest(documentID: document.id, range: edit.range,
            originalText: raw.substring(with: edit.range), replacementText: edit.replacement,
            expectedEditorRevision: selected.editorRevision, actionName: L10n.tr("设置图片资源根路径"))
        request.resultingSelection = edit.selectionRange
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
    }

    func presentMarkdownLink() {
        guard let document = selectedDocument, document.language == .markdown,
              document.ioState == .idle, hostWindow != nil else { return }
        func extract() -> EditorTextSelectionSnapshot? {
            let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return request.result
        }
        guard let first = extract() else { return }
        let snapshot = document.synchronizedSnapshot()
        guard let selected = extract(), first.matches(selected), selected.documentID == document.id,
              selectedDocument === document, !document.hasPendingLiveEdits,
              selected.range.location <= (snapshot.text as NSString).length,
              selected.range.length <= (snapshot.text as NSString).length - selected.range.location,
              (snapshot.text as NSString).substring(with: selected.range) == selected.text else { return }
        let (editingSource, editingSelection) = tableInsertionSource(snapshot, selected)
        guard let initial = MarkdownLinkEditingService.initial(in: editingSource, selection: editingSelection) else { return }
        let dialogState = MarkdownLinkDialogState(document: snapshot, selection: selected)
        let label = NSTextField(string: initial.label)
        let address = NSTextField(string: initial.address)
        let fields = NSStackView(views: [NSTextField(labelWithString: L10n.tr("链接文字")), label,
                                        NSTextField(labelWithString: L10n.tr("链接地址")), address])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        fields.frame = NSRect(x: 0, y: 0, width: 360, height: 100)
        label.widthAnchor.constraint(equalToConstant: 360).isActive = true
        address.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let alert = NSAlert()
        alert.messageText = L10n.tr("链接")
        alert.accessoryView = fields
        alert.addButton(withTitle: L10n.tr("应用"))
        alert.addButton(withTitle: L10n.tr("取消"))
        while alert.runModal() == .alertFirstButtonReturn {
            guard selectedDocument === document, document.language == .markdown, document.ioState == .idle,
                  let before = extract(), selected.matches(before) else { return }
            let current = document.synchronizedSnapshot()
            guard let after = extract(), dialogState.matches(document: current, selection: after), selectedDocument === document,
                  document.language == .markdown, document.ioState == .idle, !document.hasPendingLiveEdits else { return }
            let input = MarkdownLinkInput(label: label.stringValue, address: address.stringValue)
            guard !input.label.isEmpty, !input.address.isEmpty else {
                alert.informativeText = L10n.tr("请输入链接文字和地址")
                continue
            }
            guard let edit = MarkdownLinkEditingService.edit(in: editingSource, selection: editingSelection, input: input) else {
                alert.informativeText = L10n.tr("无法创建此链接，请检查文字和地址")
                continue
            }
            if let target = selected.virtualTableTarget {
                guard edit.range == editingSelection else { return }
                let request = EditorRangeReplacementRequest(documentID: document.id, range: target.range,
                    originalText: "", replacementText: String(repeating: "|", count: target.separators) + edit.replacement,
                    expectedEditorRevision: selected.editorRevision, actionName: L10n.tr("链接"))
                request.virtualTableTarget = target
                request.resultingSelection = edit.selectionRange
                request.groupsUndo = true
                NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
                return
            }
            formatMarkdown(.link(input))
            return
        }
    }

    func formatMarkdown(_ command: MarkdownFormattingCommand) {
        guard let document = selectedDocument, document.language == .markdown,
              document.ioState == .idle else { return }
        NotificationCenter.default.post(
            name: EditorCommandNotification.formatMarkdown,
            object: MarkdownFormattingRequest(documentID: document.id, command: command)
        )
    }

    func editLines(_ command: LineEditingCommand) {
        guard let document = selectedDocument, document.ioState == .idle else { return }
        if command == .toggleComment, document.language.commentSyntax == nil { return }
        NotificationCenter.default.post(
            name: EditorCommandNotification.editLines,
            object: LineEditingRequest(documentID: document.id, command: command)
        )
    }

    func criticMarkup(_ command: CriticMarkupCommand) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle else { return }
        NotificationCenter.default.post(
            name: EditorCommandNotification.criticMarkup,
            object: CriticMarkupRequest(documentID: document.id, command: command)
        )
    }

    func markdownClipboard(_ command: MarkdownClipboardCommand) {
        guard let document = selectedDocument, document.language == .markdown, document.ioState == .idle else { return }
        NotificationCenter.default.post(name: EditorCommandNotification.markdownClipboard,
                                        object: MarkdownClipboardRequest(documentID: document.id, command: command))
    }

    func revealMarkdownHeading(_ heading: MarkdownHeading, in document: EditorDocument) {
        guard selectedDocument === document, document.language == .markdown,
              document.ioState == .idle, document.isMarkdownOutlineCurrent,
              document.markdownHeadings.contains(where: { $0.sameSource(as: heading) }) else { return }
        reveal(NSRange(location: heading.range.location, length: 0), in: document)
    }

    /// Можно ли сдвинуть раздел заголовка на одного соседа (для меню оглавления). Считает по полному списку заголовков.
    func canMoveMarkdownSection(_ heading: MarkdownHeading, _ direction: MarkdownSectionMoveService.Direction, in document: EditorDocument) -> Bool {
        guard selectedDocument === document, document.language == .markdown, document.isMarkdownOutlineCurrent,
              !document.isReadingMode, document.ioState == .idle,
              let index = document.markdownHeadings.firstIndex(where: { $0.sameSource(as: heading) }) else { return false }
        return MarkdownSectionMoveService.target(direction, section: index, headings: document.markdownHeadings) != nil
    }

    /// Перенос раздела кнопкой «Вверх/Вниз». false — перенос не состоялся.
    @discardableResult
    func moveMarkdownSection(_ heading: MarkdownHeading, _ direction: MarkdownSectionMoveService.Direction, in document: EditorDocument) -> Bool {
        performMarkdownSectionMove(heading, in: document) { MarkdownSectionMoveService.target(direction, section: $0, headings: $1) }
    }

    /// Перенос раздела перетаскиванием: `before` — заголовок, перед которым встанет раздел; nil — в конец документа.
    @discardableResult
    func moveMarkdownSection(_ heading: MarkdownHeading, before: MarkdownHeading?, in document: EditorDocument) -> Bool {
        performMarkdownSectionMove(heading, in: document) { _, headings in
            guard let before else { return .end }
            return headings.firstIndex(where: { $0.sameSource(as: before) }).map(MarkdownSectionMoveService.Target.before)
        }
    }

    private func performMarkdownSectionMove(
        _ heading: MarkdownHeading, in document: EditorDocument,
        target: (Int, [MarkdownHeading]) -> MarkdownSectionMoveService.Target?
    ) -> Bool {
        guard selectedDocument === document, document.language == .markdown, document.ioState == .idle,
              !openingPlaceholderIDs.contains(document.id) else { return false }
        guard !document.isReadingMode else {
            document.setStatusError(L10n.tr("阅读模式下无法修改"))
            return false
        }
        // сначала перенос ввода из редактора в модель: он же гасит устаревший список заголовков
        let snapshot = document.synchronizedSnapshot()
        guard document.isMarkdownOutlineCurrent, !document.hasPendingLiveEdits else {
            document.statusMessage = L10n.tr("正在更新大纲…")
            return false
        }
        let headings = document.markdownHeadings
        guard let index = headings.firstIndex(where: { $0.sameSource(as: heading) }),
              let place = target(index, headings) else { return false }
        guard let selection = editableSelection(in: document) else {
            document.setStatusError(L10n.tr("当前文本无法修改"))
            return false
        }
        let source = snapshot.text as NSString
        switch MarkdownSectionMoveService.move(in: source, headings: headings, section: index, to: place) {
        case let .failure(failure):
            switch failure {
            case .unchanged: break
            case .insideSelf: document.setStatusError(L10n.tr("无法把章节移入自身"))
            default: document.setStatusError(L10n.tr("无法移动该章节"))
            }
            return false
        case let .success(move):
            let request = EditorRangeReplacementRequest(documentID: document.id, range: move.range,
                originalText: source.substring(with: move.range), replacementText: move.replacement,
                expectedEditorRevision: selection.editorRevision, actionName: L10n.tr("移动章节"))
            request.groupsUndo = true
            request.resultingSelection = move.selectionRange
            NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
            if !request.wasHandled { document.setStatusError(request.failureMessage ?? L10n.tr("当前文本无法修改")) }
            return request.wasHandled
        }
    }

    /// Текущий список файлов для wiki-ссылок документа; nil, пока он не загружен или относится к другой базе.
    func wikiResolver(for document: EditorDocument) -> MarkdownWikiLinkResolver? {
        guard document.language == .markdown, let snapshot = wikiCatalog.snapshot,
              snapshot.base == MarkdownWikiLinkResolver.base(root: folderWorkspace.rootURL, documentURL: document.url) else { return nil }
        return snapshot
    }

    func wikiContext(for document: EditorDocument) -> MarkdownWikiLinkContext? {
        wikiResolver(for: document).map { MarkdownWikiLinkContext(resolver: $0, documentURL: document.url) }
    }

    func requestWikiCatalog(for document: EditorDocument) {
        wikiCatalog.ensure(root: folderWorkspace.rootURL, documentURL: document.url)
    }

    private func isCurrentMarkdownLink(_ request: MarkdownLinkNavigationRequest) -> Bool {
        guard let document = selectedDocument, document.id == request.snapshot.documentID,
              document.ioState == .idle, request.isCurrent() else { return false }
        return document.synchronizedSnapshot() == request.snapshot
    }

    private func navigateMarkdownLink(_ request: MarkdownLinkNavigationRequest) {
        guard isCurrentMarkdownLink(request), let document = selectedDocument else { return }
        let sourceURL = document.url
        markdownLinkTask?.task.cancel()
        markdownLinkTask = nil
        do {
            switch try MarkdownLinkNavigationService.destination(for: request.link.url, documentURL: document.url) {
            case let .fragment(fragment):
                let location: Int
                if fragment.isEmpty { location = 0 }
                else if let heading = MarkdownHeadingAnchors.target(for: fragment, in: request.headings) { location = heading.range.location }
                else if let anchor = request.namedAnchors.first(where: { $0.name.utf8.elementsEqual(fragment.utf8) }) { location = anchor.range.location }
                else { document.statusMessage = L10n.tr("找不到链接目标"); return }
                reveal(NSRange(location: location, length: 0), in: document)
            case let .external(url):
                if !NSWorkspace.shared.open(url) { document.statusMessage = L10n.tr("无法打开链接") }
            case let .file(url, fragment):
                let target = MarkdownLinkNavigationService.fileTarget(url)
                let targetURL = target.url
                guard FileService.supportedExtensions.contains(targetURL.pathExtension.lowercased()) else {
                    var external = URLComponents(url: targetURL, resolvingAgainstBaseURL: true)
                    external?.fragment = fragment
                    guard let target = external?.url, NSWorkspace.shared.open(target) else {
                        document.statusMessage = L10n.tr("无法打开链接"); return
                    }
                    return
                }
                if !target.exists, ["md", "markdown"].contains(targetURL.pathExtension.lowercased()) {
                    let alert = NSAlert()
                    alert.messageText = L10n.tr("链接的文件不存在")
                    alert.informativeText = L10n.tr("是否创建文件：%@？", targetURL.path)
                    alert.addButton(withTitle: L10n.tr("创建"))
                    alert.addButton(withTitle: L10n.tr("取消"))
                    guard alert.runModal() == .alertFirstButtonReturn,
                          let manager = windowManager, manager.activeState === self,
                          document.url == sourceURL, isCurrentMarkdownLink(request) else { return }
                    if !FileManager.default.fileExists(atPath: targetURL.path) {
                        do { try fileService.createLinkedMarkdownFile(at: targetURL) }
                        catch {
                            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                                presentError(title: L10n.tr("无法创建文件"), error: error)
                                return
                            }
                        }
                    }
                }
                let token = UUID()
                let task = Task { @MainActor [weak self] in
                    defer { if self?.markdownLinkTask?.id == token { self?.markdownLinkTask = nil } }
                    guard let manager = self?.windowManager else { return }
                    let opened: FolderSearchService.OpenDocument?
                    do {
                        guard let state = self, manager.activeState === state, state.selectedDocument?.url == sourceURL,
                              state.isCurrentMarkdownLink(request) else { return }
                        opened = await manager.openFolderSearchFile(targetURL, preferredState: state)
                    }
                    guard !Task.isCancelled, let opened, self?.selectedDocument?.url == sourceURL, self?.isCurrentMarkdownLink(request) == true,
                          manager.activeState?.selectedDocument?.id == opened.snapshot.documentID else { return }
                    guard let fragment else { return }
                    let location: Int
                    if fragment.isEmpty { location = 0 }
                    else {
                        guard manager.documentsForAI.first(where: { $0.id == opened.snapshot.documentID })?.language == .markdown else {
                            manager.activeState?.selectedDocument?.statusMessage = L10n.tr("找不到链接目标"); return
                        }
                        guard let syntax = self?.preferences.markdownSyntax else { return }
                        let parsed = await Task.detached(priority: .userInitiated) {
                            MarkdownPresentationParser.parse(opened.snapshot.text, syntax: syntax, isCancelled: { Task.isCancelled })
                        }.value
                        guard !Task.isCancelled, self?.selectedDocument?.url == sourceURL, self?.isCurrentMarkdownLink(request) == true,
                              self?.preferences.markdownSyntax == syntax,
                              manager.activeState?.selectedDocument?.id == opened.snapshot.documentID else { return }
                        guard let target = MarkdownHeadingAnchors.target(for: fragment, in: parsed.headings)?.range.location
                                ?? parsed.namedAnchors.first(where: { $0.name.utf8.elementsEqual(fragment.utf8) })?.range.location else {
                            manager.activeState?.selectedDocument?.statusMessage = L10n.tr("找不到链接目标"); return
                        }
                        location = target
                    }
                    let range = NSRange(location: location, length: 0)
                    let match = FolderSearchService.Match(file: .init(url: opened.url, relativePath: opened.url.lastPathComponent),
                        range: range, matchedText: "", contextRange: range, context: "",
                        source: .open(documentID: opened.snapshot.documentID, revision: opened.snapshot.revision, identity: opened.identity))
                    _ = manager.revealFolderSearchMatch(match, expected: opened)
                }
                markdownLinkTask = (token, document.id, task)
            }
        } catch {
            document.statusMessage = L10n.tr("无法打开链接")
        }
    }

    func revealFolderSearchRange(_ range: NSRange, in document: EditorDocument) {
        guard selectedDocument === document else { return }
        reveal(range, in: document)
    }

    private func reveal(_ range: NSRange, in document: EditorDocument, focusEditor: Bool = true) {
        document.selectionRange = range
        NotificationCenter.default.post(
            name: EditorCommandNotification.revealSelection,
            object: EditorSelectionRequest(documentID: document.id, range: range, focusesEditor: focusEditor)
        )
    }

    private func applyTextUpdate(
        _ text: String,
        to document: EditorDocument,
        selectionRange: NSRange,
        actionName: String
    ) -> Bool {
        // Запасная запись в модель ниже в режиме чтения изменила бы текст в обход редактора.
        guard !document.isReadingMode else {
            document.setStatusError(L10n.tr("阅读模式下无法修改"))
            return false
        }
        guard text != document.synchronizedText() else { return true }
        let textLength = (text as NSString).length
        let safeLocation = min(selectionRange.location, textLength)
        let safeSelection = NSRange(
            location: safeLocation,
            length: min(selectionRange.length, textLength - safeLocation)
        )
        let request = EditorTextUpdateRequest(
            documentID: document.id,
            text: text,
            selectionRange: safeSelection,
            actionName: actionName
        )
        NotificationCenter.default.post(
            name: EditorCommandNotification.applyTextUpdate,
            object: request
        )

        guard !request.wasHandled else { return true }
        document.text = text
        document.selectionRange = safeSelection
        document.refreshDirtyState()
        if findReplace.isBarVisible { scheduleFindRefresh() }
        return true
    }

    private func write(
        _ document: EditorDocument,
        to url: URL,
        bypassExternalConflict: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard windowManager?.isFolderMoveBlocked(document, target: url) != true else {
            document.statusMessage = L10n.tr("文件操作进行中，请稍后重试")
            completion?(false)
            return false
        }
        guard !openingPlaceholderIDs.contains(document.id) else {
            completion?(false)
            return false
        }
        guard document.ioState != .saving else {
            document.statusMessage = L10n.tr("已有保存任务正在进行")
            completion?(false)
            return false
        }
        if !bypassExternalConflict,
           url.standardizedFileURL == document.url?.standardizedFileURL,
           hasExternalFileConflict(document, at: url) {
            resolveExternalFileConflict(for: document, at: url, completion: completion)
            return false
        }
        let text = document.synchronizedText()
        let revision = document.textRevision
        let encoding = document.fileEncoding
        let encodingName = document.encodingName
        let saveGeneration = document.taskCoordinator.begin(.save)
        document.ioState = .saving
        document.statusMessage = L10n.tr("正在保存…")
        let signpostID = OSSignpostID(log: filePerformanceLog)
        fileWriteQueue.async { [weak self, weak document] in
            os_signpost(
                .begin,
                log: filePerformanceLog,
                name: "FileSave",
                signpostID: signpostID
            )
            let saveResult: DocumentSaveResult
            let saveError: Error?
            do {
                try FileService.write(
                    text,
                    to: url,
                    encoding: encoding,
                    encodingName: encodingName
                )
                saveResult = DocumentSaveResult(
                    targetURL: url,
                    encoding: encoding,
                    snapshotRevision: revision,
                    fileRevisionSnapshot: try FileRevisionSnapshot.capture(url),
                    errorDescription: nil
                )
                saveError = nil
            } catch {
                saveResult = DocumentSaveResult(
                    targetURL: url,
                    encoding: encoding,
                    snapshotRevision: revision,
                    fileRevisionSnapshot: nil,
                    errorDescription: error.localizedDescription
                )
                saveError = error
            }
            os_signpost(
                .end,
                log: filePerformanceLog,
                name: "FileSave",
                signpostID: signpostID
            )
            DispatchQueue.main.async {
                guard let self, let document else { return }
                guard document.taskCoordinator.isCurrent(
                    saveGeneration,
                    for: .save
                ) else { return }
                document.taskCoordinator.finish(.save, generation: saveGeneration)
                if saveResult.succeeded,
                   let fileSnapshot = saveResult.fileRevisionSnapshot {
                    document.updateLocation(to: url)
                    document.updateFileEncoding(encoding)
                    document.updateFileRevisionSnapshot(fileSnapshot)
                    document.markSaved(snapshot: text, revision: revision)
                    document.noteSavedToDisk(at: Date())
                    document.ioState = .idle
                    document.statusMessage = document.isDirty
                        ? L10n.tr("已保存先前版本，仍有未保存更改")
                        : nil
                    self.recentFiles.record(url)
                    self.scheduleRecoverySnapshot(for: document, delay: 0)
                    self.aiWriting.didSave(documentID: document.id)
                    completion?(!document.isDirty)
                } else {
                    let description = saveResult.errorDescription ?? L10n.tr("无法取得保存后的文件状态")
                    document.ioState = .failed(description)
                    document.statusMessage = L10n.tr("保存失败：%@", String(describing: description))
                    if let saveError {
                        self.handleSaveError(
                            saveError,
                            for: document,
                            completion: completion
                        )
                    } else {
                        completion?(false)
                    }
                }
            }
            // Версия не участвует в результате сохранения: снимок файла уже зафиксирован выше.
            if saveResult.succeeded, let error = FileVersionService.recordVersion(of: url) {
                os_log(.error, log: fileVersionLog, "FileVersion: %{public}@", error.localizedDescription)
            }
        }
        return true
    }

    private func hasExternalFileConflict(
        _ document: EditorDocument,
        at url: URL
    ) -> Bool {
        guard let baseline = document.fileRevisionSnapshot else { return false }
        guard let current = try? FileRevisionSnapshot.capture(url) else { return true }
        return current != baseline
    }

    private func resolveExternalFileConflict(
        for document: EditorDocument,
        at url: URL,
        completion: ((Bool) -> Void)?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("磁盘上的文件已发生变化")
        alert.informativeText = L10n.tr("为避免覆盖其他程序的修改，LacEditor 已停止保存。你可以重新载入磁盘版本、另存为新文件，或明确覆盖。")
        alert.addButton(withTitle: L10n.tr("取消"))
        alert.addButton(withTitle: L10n.tr("重新载入"))
        alert.addButton(withTitle: L10n.tr("另存为"))
        alert.addButton(withTitle: L10n.tr("仍然覆盖"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak document] response in
            guard let self, let document else { return }
            switch response {
            case .alertSecondButtonReturn:
                self.reloadFromDisk(document, at: url)
                completion?(false)
            case .alertThirdButtonReturn:
                _ = self.saveAs(
                    document,
                    encoding: document.fileEncoding,
                    completion: completion
                )
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                _ = self.write(
                    document,
                    to: url,
                    bypassExternalConflict: true,
                    completion: completion
                )
            default:
                completion?(false)
                break
            }
        }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    func reloadFromDisk(_ document: EditorDocument, at url: URL) {
        _ = document.synchronizedText()
        let expectedRevision = document.textRevision
        let normalized = url.standardizedFileURL
        document.ioState = .opening
        let readFile = self.readFile
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak document, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result { try readFile(normalized) }
            DispatchQueue.main.async { [weak self, weak document, weak operation] in
                guard let self, let document, let operation, !operation.isCancelled,
                      self.openingOperations[normalized] === operation else { return }
                do {
                    switch try result.get() {
                    case let .decoded(decoded):
                        self.openingOperations.removeValue(forKey: normalized)
                        self.finishReload(
                            decoded, document: document, expectedRevision: expectedRevision
                        )
                    case let .needsEncoding(data, byteCount, fileRevisionSnapshot):
                        let choice = self.fileService.chooseEncoding(for: normalized)
                        guard self.openingOperations[normalized] === operation, !operation.isCancelled else { return }
                        guard let choice else {
                            self.openingOperations.removeValue(forKey: normalized)
                            document.ioState = .idle
                            return
                        }
                        self.decodeReloadInBackground(
                            data, choice: choice, byteCount: byteCount,
                            fileRevisionSnapshot: fileRevisionSnapshot, document: document,
                            url: normalized, expectedRevision: expectedRevision
                        )
                    }
                } catch {
                    self.openingOperations.removeValue(forKey: normalized)
                    document.ioState = .failed(error.localizedDescription)
                    self.presentError(title: L10n.tr("无法重新载入文件"), error: error)
                }
            }
        }
        openingOperations[normalized] = operation
        fileOpeningQueue.addOperation(operation)
    }

    private func decodeReloadInBackground(
        _ data: Data,
        choice: FileEncodingChoice,
        byteCount: Int,
        fileRevisionSnapshot: FileRevisionSnapshot,
        document: EditorDocument,
        url: URL,
        expectedRevision: UInt
    ) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak document, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result {
                try FileService.decode(
                    data,
                    encoding: choice.encoding,
                    encodingName: choice.name,
                    byteCount: byteCount,
                    fileRevisionSnapshot: fileRevisionSnapshot
                )
            }
            DispatchQueue.main.async { [weak self, weak document, weak operation] in
                guard let self, let document, let operation, !operation.isCancelled,
                      self.openingOperations[url] === operation else { return }
                self.openingOperations.removeValue(forKey: url)
                do {
                    self.finishReload(
                        try result.get(), document: document, expectedRevision: expectedRevision
                    )
                } catch {
                    document.ioState = .failed(error.localizedDescription)
                    self.presentError(title: L10n.tr("无法重新载入文件"), error: error)
                }
            }
        }
        openingOperations[url] = operation
        fileOpeningQueue.addOperation(operation)
    }

    private func finishReload(
        _ decoded: DecodedFile,
        document: EditorDocument,
        expectedRevision: UInt
    ) {
        _ = document.synchronizedText()
        guard document.textRevision == expectedRevision, !document.hasPendingLiveEdits else {
            document.ioState = .idle
            document.statusMessage = L10n.tr("重新载入期间内容已变化，已保留本地修改")
            return
        }
        document.text = decoded.text
        document.updateFileEncoding(decoded.encoding)
        document.updateFileRevisionSnapshot(decoded.fileRevisionSnapshot)
        document.markSaved()
        document.ioState = .idle
        scheduleRecoverySnapshot(for: document, delay: 0)
    }

    /// Приводит все переносы документа к одному виду одной заменой с одной отменой.
    func convertLineEndings(to target: LineEnding) {
        guard let document = selectedDocument, document.ioState == .idle,
              !openingPlaceholderIDs.contains(document.id) else { return }
        guard let first = editableSelection(in: document) else {
            document.setStatusError(L10n.tr("当前文本无法修改"))
            return
        }
        let snapshot = document.synchronizedSnapshot()
        let source = snapshot.text as NSString
        guard !document.hasPendingLiveEdits, first.documentID == document.id, first.range.location != NSNotFound,
              first.range.length <= source.length - first.range.location else {
            document.setStatusError(L10n.tr("当前文本无法修改"))
            return
        }
        let coordinator = document.taskCoordinator
        let generation = coordinator.begin(.lineEndingConversion)
        let task = Task.detached(priority: .userInitiated) { [weak self, weak document] in
            let converted = LineEndingService.convert(snapshot.text, to: target, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self, weak document] in
                guard let self, let document, !Task.isCancelled,
                      coordinator.isCurrent(generation, for: .lineEndingConversion) else { return }
                coordinator.finish(.lineEndingConversion, generation: generation)
                guard let converted else {
                    document.statusMessage = L10n.tr("转换结果与原文相同")
                    return
                }
                // Правка во время фонового расчёта или смена вкладки отменяют применение.
                guard self.documents.contains(where: { $0 === document }), self.selectedDocument === document,
                      document.ioState == .idle else { return }
                let current = document.synchronizedSnapshot()
                guard current.revision == snapshot.revision, !document.hasPendingLiveEdits,
                      let second = editableSelection(in: document), first.matches(second) else {
                    document.statusMessage = L10n.tr("编辑内容已变化，请重新执行转换")
                    return
                }
                let source = snapshot.text as NSString
                func mapped(_ location: Int) -> Int {
                    LineEndingService.mappedLocation(location, in: source, to: target)
                }
                let newLength = (converted as NSString).length
                let start = min(mapped(first.range.location), newLength)
                let end = min(mapped(NSMaxRange(first.range)), newLength)
                let request = EditorRangeReplacementRequest(documentID: document.id, range: NSRange(location: 0, length: source.length),
                    originalText: snapshot.text, replacementText: converted,
                    expectedEditorRevision: second.editorRevision, actionName: L10n.tr("转换换行符"))
                request.groupsUndo = true
                request.resultingSelection = NSRange(location: start, length: max(0, end - start))
                NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
                if !request.wasHandled {
                    document.setStatusError(request.failureMessage ?? L10n.tr("当前文本无法修改"))
                }
            }
        }
        coordinator.attachTask(task, kind: .lineEndingConversion, generation: generation)
    }

    private func editableSelection(in document: EditorDocument) -> EditorTextSelectionSnapshot? {
        let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
        return request.result
    }

    private func encodingChoices(including current: String.Encoding) -> [FileEncodingChoice] {
        var choices = FileService.encodingChoices
        if !choices.contains(where: { $0.encoding == current }) {
            choices.insert(FileEncodingChoice(name: FileService.encodingName(for: current), encoding: current), at: 0)
        }
        return choices
    }

    func chooseSaveEncoding() {
        guard let document = selectedDocument, document.ioState == .idle,
              !openingPlaceholderIDs.contains(document.id) else { return }
        guard let choice = fileService.chooseEncoding(
            title: L10n.tr("选择保存编码"),
            message: L10n.tr("保存时将把文本转换为所选编码；无法表示的字符会阻止保存。"),
            confirmTitle: L10n.tr("选择"),
            choices: encodingChoices(including: document.fileEncoding),
            selected: document.fileEncoding
        ) else { return }
        guard selectedDocument === document else { return }
        applySaveEncoding(choice, to: document)
    }

    /// Только меняет кодировку будущей записи и помечает документ несохранённым; сам файл не трогается.
    /// Запись идёт обычным `write` с проверкой внешних изменений и запретом потери символов.
    /// Это не текстовая правка, в историю отмены редактора она не попадает.
    func applySaveEncoding(_ choice: FileEncodingChoice, to document: EditorDocument) {
        guard document.ioState == .idle, !openingPlaceholderIDs.contains(document.id),
              choice.encoding != document.fileEncoding else { return }
        document.changeFileEncodingPendingSave(choice.encoding)
        document.statusMessage = L10n.tr("保存编码已设为%@，保存时将转换文件", choice.name)
        scheduleRecoverySnapshot(for: document, delay: 0)
    }

    func chooseReopenEncoding() {
        guard let document = selectedDocument, document.url != nil, document.ioState == .idle,
              !openingPlaceholderIDs.contains(document.id) else { return }
        _ = document.synchronizedText()
        let expectedRevision = document.textRevision
        if document.isDirty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("要丢弃未保存的修改并重新打开吗？")
            alert.informativeText = L10n.tr("“%@”有未保存的修改，重新打开会丢弃这些修改和撤销记录。", document.displayName)
            alert.addButton(withTitle: L10n.tr("重新打开"))
            alert.addButton(withTitle: L10n.tr("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let choice = fileService.chooseEncoding(
            title: L10n.tr("选择重新打开所用的编码"),
            message: L10n.tr("“%@”将从磁盘按所选编码重新读取。", document.displayName),
            confirmTitle: L10n.tr("重新打开"),
            choices: encodingChoices(including: document.fileEncoding),
            selected: document.fileEncoding
        ) else { return }
        _ = document.synchronizedText()
        guard selectedDocument === document, document.ioState == .idle,
              document.textRevision == expectedRevision, !document.hasPendingLiveEdits else { return }
        reopen(document, with: choice)
    }

    /// Перечитывает файл целиком в выбранной кодировке через `finishReload`; история отмены сбрасывается.
    func reopen(_ document: EditorDocument, with choice: FileEncodingChoice) {
        guard let url = document.url, document.ioState == .idle,
              !openingPlaceholderIDs.contains(document.id) else { return }
        _ = document.synchronizedText()
        let expectedRevision = document.textRevision
        let normalized = url.standardizedFileURL
        document.ioState = .opening
        let readRawFile = self.readRawFile
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak document, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result<DecodedFile, Error> {
                let raw = try readRawFile(normalized)
                return try FileService.decode(
                    raw.data,
                    encoding: choice.encoding,
                    encodingName: choice.name,
                    byteCount: raw.data.count,
                    fileRevisionSnapshot: raw.snapshot
                )
            }
            DispatchQueue.main.async { [weak self, weak document, weak operation] in
                guard let self, let document, let operation, !operation.isCancelled,
                      self.openingOperations[normalized] === operation else { return }
                self.openingOperations.removeValue(forKey: normalized)
                do {
                    let decoded = try result.get()
                    _ = document.synchronizedText()
                    let isCurrent = document.textRevision == expectedRevision && !document.hasPendingLiveEdits
                    self.finishReload(decoded, document: document, expectedRevision: expectedRevision)
                    if isCurrent { document.statusMessage = L10n.tr("已按%@重新打开", choice.name) }
                } catch {
                    // Документ остаётся доступным: ошибка видна в строке состояния.
                    document.ioState = .idle
                    document.setStatusError(error.localizedDescription)
                }
            }
        }
        openingOperations[normalized] = operation
        fileOpeningQueue.addOperation(operation)
    }

    private func handleSaveError(
        _ error: Error,
        for document: EditorDocument,
        completion: ((Bool) -> Void)?
    ) {
        guard case FileServiceError.unrepresentableCharacters = error else {
            presentError(title: L10n.tr("无法保存文件"), error: error)
            completion?(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("当前编码无法保存这些字符")
        alert.informativeText = L10n.tr("原文件没有被覆盖。你可以取消，或另存为 UTF-8 文件。")
        alert.addButton(withTitle: L10n.tr("取消"))
        alert.addButton(withTitle: L10n.tr("另存为 UTF-8"))
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else {
            completion?(false)
            return
        }
        _ = saveAs(document, encoding: .utf8, completion: completion)
    }

    private func confirmClosing(
        _ document: EditorDocument,
        completion: @escaping (Bool) -> Void
    ) {
        if openingPlaceholderIDs.contains(document.id) {
            guard document.isDirty else { completion(true); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("要保存对“%@”的更改吗？", String(describing: document.displayName))
            alert.informativeText = L10n.tr("如果不保存，更改将会丢失。")
            alert.addButton(withTitle: L10n.tr("不保存"))
            alert.addButton(withTitle: L10n.tr("取消"))
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                completion(response == .alertFirstButtonReturn)
            }
            if let hostWindow { alert.beginSheetModal(for: hostWindow, completionHandler: handle) }
            else { handle(alert.runModal()) }
            return
        }
        document.refreshDirtyState()
        guard document.isDirty else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("要保存对“%@”的更改吗？", String(describing: document.displayName))
        alert.informativeText = L10n.tr("如果不保存，更改将会丢失。")
        alert.addButton(withTitle: L10n.tr("保存"))
        alert.addButton(withTitle: L10n.tr("不保存"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak document] response in
            guard let self, let document else {
                completion(false)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                self.saveForClosing(document, completion: completion)
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func saveForClosing(
        _ document: EditorDocument,
        completion: @escaping (Bool) -> Void
    ) {
        let targetURL: URL
        if let url = document.url {
            targetURL = url
        } else {
            guard let url = fileService.chooseSaveURL(
                suggestedName: suggestedFilename(for: document)
            ) else {
                completion(false)
                return
            }
            targetURL = url
        }
        if let conflict = windowManager?.conflictingDocument(
            at: targetURL,
            excluding: document.id
        ) {
            windowManager?.focus(conflict.document, in: conflict.state)
            completion(false)
            return
        }
        _ = write(document, to: targetURL, completion: completion)
    }

    private func closeDocumentsSequentially(
        _ queue: [EditorDocument],
        removesDocuments: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        guard let document = queue.first else {
            completion(true)
            return
        }
        confirmClosing(document) { [weak self] shouldClose in
            guard let self, shouldClose else {
                completion(false)
                return
            }
            if removesDocuments,
               self.documents.contains(where: { $0.id == document.id }) {
                self.removeDocument(document)
            }
            self.closeDocumentsSequentially(
                Array(queue.dropFirst()),
                removesDocuments: removesDocuments,
                completion: completion
            )
        }
    }

    private func removeOpeningPlaceholder(for url: URL) {
        guard let placeholder = documents.first(where: {
            $0.url?.standardizedFileURL == url && $0.ioState == .opening
        }) else { return }
        removeDocument(placeholder)
    }

    private func confirmOpeningExtremeFile(_ url: URL, byteCount: Int) -> Bool {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("打开超大文件？")
        alert.informativeText = L10n.tr("“%@”大小为 %@。LacEditor 将进入保护模式并关闭高亮、预览、换行、折叠和实时字数统计。", url.lastPathComponent, formatter.string(fromByteCount: Int64(byteCount)))
        alert.addButton(withTitle: L10n.tr("继续打开"))
        alert.addButton(withTitle: L10n.tr("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func removeDocument(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        closeVersionHistory()
        previousMarkdownExports.removeValue(forKey: document.id)
        _ = windowManager?.cancelRestoration(document)
        if document.ioState == .opening, let url = document.url?.standardizedFileURL {
            openingOperations.removeValue(forKey: url)?.cancel()
            openingFileURLs.remove(url)
        }
        openingPlaceholderIDs.remove(document.id)
        stopObserving(document)
        recoveryStore?.discard(documentID: document.id)
        documents.remove(at: index)
        if documents.isEmpty {
            resetClosedWindow()
        } else {
            selectedDocumentID = documents[min(index, documents.count - 1)].id
        }
    }

    func presentError(title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }
}

extension AppState {
    private enum TemplateNoteFailure: Error {
        case read(Error), create(Error)
    }

    func newNoteFromTemplate() {
        guard let manager = windowManager, let window = hostWindow,
              manager.ownsVisibleState(self, window: window) else { return }
        guard let root = folderWorkspace.rootURL else { presentNoWorkspaceAlert(); return }
        let templatesPath = preferences.templatesFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templatesPath.isEmpty else { presentTemplatesFolderNotSetAlert(); return }
        let folder = URL(fileURLWithPath: templatesPath, isDirectory: true)
        let service = fileService
        templateTask?.cancel()
        templateTask = Task { [weak self] in
            let listing = await Task.detached { Result { try NoteTemplateService.listTemplates(in: folder) } }.value
            guard let self, !Task.isCancelled, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            let templates: [URL]
            switch listing {
            case let .failure(error): self.presentError(title: L10n.tr("无法读取模板文件夹"), error: error); return
            case let .success(urls): templates = urls
            }
            guard !templates.isEmpty else {
                let alert = NSAlert()
                alert.messageText = L10n.tr("模板文件夹中没有 Markdown 模板")
                alert.addButton(withTitle: L10n.tr("取消"))
                alert.runModal()
                return
            }
            let alert = NSAlert()
            alert.messageText = L10n.tr("从模板新建笔记")
            alert.addButton(withTitle: L10n.tr("创建"))
            alert.addButton(withTitle: L10n.tr("取消"))
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            let baseNames = templates.map { $0.deletingPathExtension().lastPathComponent }
            for url in templates {
                let base = url.deletingPathExtension().lastPathComponent
                let item = NSMenuItem(title: baseNames.filter { $0 == base }.count > 1 ? url.lastPathComponent : base,
                                      action: nil, keyEquivalent: "")
                item.representedObject = url
                popup.menu?.addItem(item)
            }
            popup.setAccessibilityLabel(L10n.tr("模板"))
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = L10n.tr("笔记名称")
            let stack = NSStackView(views: [popup, field])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: 58)
            alert.accessoryView = stack
            guard alert.runModal() == .alertFirstButtonReturn, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            guard let template = popup.selectedItem?.representedObject as? URL else { return }
            let name = NoteTemplateService.normalizedFileName(field.stringValue)
            let directory = self.folderWorkspace.currentDirectory ?? root
            let title = (name as NSString).deletingPathExtension
            let creation = await Task.detached { () -> Result<URL, TemplateNoteFailure> in
                let text: String
                do { text = try NoteTemplateService.readTemplate(template) }
                catch { return .failure(.read(error)) }
                let contents = NoteTemplateService.render(text, title: title, date: Date())
                do { return .success(try service.createWorkspaceTextFile(named: name, contents: contents, in: directory, root: root)) }
                catch { return .failure(.create(error)) }
            }.value
            guard !Task.isCancelled, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            switch creation {
            case let .failure(.read(error)): self.presentError(title: L10n.tr("无法读取模板"), error: error)
            case let .failure(.create(error)): self.presentError(title: L10n.tr("无法创建文件"), error: error)
            case let .success(url):
                self.folderWorkspace.refresh()
                self.openFile(url)
            }
        }
    }

    func openDailyNote() {
        guard let manager = windowManager, let window = hostWindow,
              manager.ownsVisibleState(self, window: window) else { return }
        guard let root = folderWorkspace.rootURL else { presentNoWorkspaceAlert(); return }
        let subfolder = preferences.dailyNotesFolder
        let templatesFolder = preferences.templatesFolderPath
        let format = preferences.dailyNoteDateFormat
        let service = fileService
        templateTask?.cancel()
        templateTask = Task { [weak self] in
            let result = await Task.detached { () -> Result<URL, Error> in
                Result {
                    let plan = try NoteTemplateService.dailyNotePlan(
                        root: root, subfolder: subfolder, templatesFolder: templatesFolder, date: Date(), format: format,
                        validateDirectory: { try service.validateWorkspaceDirectory($0, root: root) })
                    switch plan {
                    case let .open(url): return url
                    case let .create(url, contents):
                        do {
                            return try service.createWorkspaceTextFile(
                                named: url.lastPathComponent, contents: contents, in: url.deletingLastPathComponent(), root: root)
                        } catch let error as CocoaError where error.code == .fileWriteFileExists {
                            try NoteTemplateService.requireRegularFile(url)
                            return url
                        }
                    }
                }
            }.value
            guard let self, !Task.isCancelled, self.folderWorkspace.rootURL == root,
                  manager.ownsVisibleState(self, window: window) else { return }
            switch result {
            case let .failure(error): self.presentError(title: L10n.tr("每日笔记"), error: error)
            case let .success(url):
                self.folderWorkspace.refresh()
                self.openFile(url)
            }
        }
    }

    private func presentNoWorkspaceAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("需要先打开工作文件夹")
        alert.informativeText = L10n.tr("笔记会创建在工作文件夹中。")
        alert.addButton(withTitle: L10n.tr("打开文件夹…"))
        alert.addButton(withTitle: L10n.tr("取消"))
        if alert.runModal() == .alertFirstButtonReturn { openFolder() }
    }

    private func presentTemplatesFolderNotSetAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("未设置模板文件夹")
        alert.informativeText = L10n.tr("在“设置 > 文件”中选择模板文件夹。")
        alert.addButton(withTitle: L10n.tr("打开设置…"))
        alert.addButton(withTitle: L10n.tr("取消"))
        if alert.runModal() == .alertFirstButtonReturn, let windowManager {
            SettingsWindowController.shared.present(windowManager: windowManager)
        }
    }
}

@MainActor
extension AppState {
    /// Ссылки обновляем только для Markdown-файла внутри открытой папки окна; иначе nil.
    func renameLinkScope(from old: URL, to new: URL) -> MarkdownRenameLinkService.Rename? {
        guard let folder = folderWorkspace.rootURL else { return nil }
        let base = folder.standardizedFileURL.pathComponents
        let old = old.standardizedFileURL, new = new.standardizedFileURL
        func isInside(_ url: URL) -> Bool { url.pathComponents.count > base.count && url.pathComponents.starts(with: base) }
        func isMarkdown(_ url: URL) -> Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
        guard old != new, isInside(old), isInside(new), isMarkdown(old), isMarkdown(new) else { return nil }
        // Обычный файл, и по пути до него нет символических ссылок.
        var current = folder.standardizedFileURL
        for component in old.pathComponents.dropFirst(base.count) {
            current.appendPathComponent(component)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
        }
        guard (try? old.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return .init(oldURL: old, newURL: new, root: folder)
    }

    /// Поиск ссылок до переноса. nil: поиск не нужен, пропущен кнопкой «Пропустить» или не удался — перенос идёт без обновления ссылок.
    func prepareMarkdownLinkUpdate(from old: URL, to new: URL) async -> MarkdownRenameLinkService.Plan? {
        guard renameLinkTask == nil, let rename = renameLinkScope(from: old, to: new), let manager = windowManager,
              let documents = manager.folderSearchSnapshots(root: rename.root) else { return nil }
        let identity = DocumentFileIdentity.resolve(rename.oldURL)
        let syntax = preferences.markdownSyntax
        let search = Task.detached(priority: .userInitiated) { () -> MarkdownRenameLinkService.Plan? in
            try? FolderSearchService.renameReferences(rename: rename, identity: identity, syntax: syntax, openDocuments: documents,
                                                      isCancelled: { Task.isCancelled })
        }
        // Отмена этой задачи (кнопка «Пропустить», закрытие окна) останавливает обход.
        renameLinkTask = Task { await withTaskCancellationHandler { _ = await search.value } onCancel: { search.cancel() } }
        let alert = NSAlert()
        alert.messageText = L10n.tr("正在查找指向该文件的链接…")
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        alert.accessoryView = spinner
        alert.addButton(withTitle: L10n.tr("跳过"))
        let indicator = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, let window = self.hostWindow else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.renameLinkTask?.cancel() }
            }
        }
        let plan = await search.value
        indicator.cancel()
        alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
        renameLinkTask = nil
        guard folderWorkspace.rootURL == rename.root else { return nil }
        return plan
    }

    /// Вопрос, запись и отчёт после успешного переноса.
    func completeMarkdownLinkUpdate(_ plan: MarkdownRenameLinkService.Plan?) async {
        guard let plan, folderWorkspace.rootURL == plan.rename.root, let manager = windowManager else { return }
        let (old, new) = (plan.rename.oldURL, plan.rename.newURL)
        // Старый путь может вести на тот же файл, если менялся только регистр имени.
        guard FileManager.default.fileExists(atPath: new.path),
              !FileManager.default.fileExists(atPath: old.path) ||
                DocumentFileIdentity.resolve(old).matches(DocumentFileIdentity.resolve(new)) else { return }
        var notes: [String] = []
        if plan.skipped.total > 0 {
            notes.append(L10n.tr("另有 %d 个链接不会修改：新文件名含有 # | [ ]，存在多个同名文件，或写法不受支持。", plan.skipped.total))
        }
        if !plan.problems.isEmpty {
            notes.append(L10n.tr("有 %d 个文件无法检查，其中的链接不会修改。", plan.problems.count))
        }
        guard plan.linkCount > 0 else {
            guard !notes.isEmpty else { return }
            // Не строка обратной связи: она заменила бы кнопку отмены переноса.
            let note = NSAlert()
            note.messageText = L10n.tr("部分文件未更新")
            note.informativeText = notes.joined(separator: "\n\n")
            note.addButton(withTitle: L10n.tr("确定"))
            note.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("更新 %d 个链接（%d 个文件）？", plan.linkCount, plan.fileCount)
        var details = L10n.tr("文件已重命名。“撤销”重命名不会还原这些链接。已关闭的文件将直接写入磁盘，无法撤销；已打开的文档会作为一次编辑修改，可以撤销。")
        if old.deletingLastPathComponent() != new.deletingLastPathComponent() {
            details += "\n\n" + L10n.tr("该文件自身的相对链接不会修改。")
        }
        alert.informativeText = ([details] + notes).joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.tr("不更新"))
        alert.addButton(withTitle: L10n.tr("更新链接"))
        guard alert.runModal() == .alertSecondButtonReturn, folderWorkspace.rootURL == plan.rename.root else { return }
        // Отмена переноса во время записи вернула бы файл, а ссылки остались бы на новом имени.
        sidebarFeedback.show(L10n.tr("正在更新链接…"), symbol: "info.circle")
        let task = Task { await self.applyMarkdownLinkEdits(plan, manager: manager) }
        renameLinkTask = Task { await withTaskCancellationHandler { _ = await task.value } onCancel: { task.cancel() } }
        let report = await task.value
        renameLinkTask = nil
        guard folderWorkspace.rootURL == plan.rename.root else { return }
        folderWorkspace.refresh()
        if report.isCancelled {
            sidebarFeedback.show(L10n.tr("已取消，已更新 %d 个链接", report.updatedLinks), symbol: "info.circle")
        } else if report.skipped.isEmpty {
            sidebarFeedback.show(L10n.tr("已更新 %d 个链接（%d 个文件）", report.updatedLinks, report.updatedFiles), symbol: "checkmark.circle")
        } else {
            sidebarFeedback.show(L10n.tr("已更新 %d 个链接，%d 个文件未处理", report.updatedLinks, report.skipped.count), symbol: "info.circle")
            let list = NSAlert()
            list.messageText = L10n.tr("部分文件未更新")
            var lines = report.skipped.prefix(10).map { "\($0.file.relativePath) — \(skipText($0.reason))" }
            if report.skipped.count > 10 { lines.append(L10n.tr("……还有 %d 个", report.skipped.count - 10)) }
            list.informativeText = lines.joined(separator: "\n")
            list.addButton(withTitle: L10n.tr("确定"))
            list.runModal()
        }
    }

    /// Сначала открытые документы, затем закрытые файлы по одному в фоне; отмена действует между файлами.
    private func applyMarkdownLinkEdits(_ plan: MarkdownRenameLinkService.Plan, manager: WindowManager) async -> MarkdownRenameLinkService.Report {
        let root = plan.rename.root
        var report = MarkdownRenameLinkService.Report()
        func record(_ file: MarkdownRenameLinkService.FilePlan, _ outcome: FolderReplaceService.Outcome) {
            switch outcome {
            case let .replaced(count): report.updatedLinks += count; report.updatedFiles += 1
            case let .skipped(reason): report.skipped.append(.init(file: file.file, reason: reason))
            }
        }
        for file in plan.files where file.isOpen {
            if Task.isCancelled { report.isCancelled = true; break }
            let outcome = await manager.applyRenameLinkEdits(file)
            // Пропуск из-за отмены — не «файл изменился».
            if Task.isCancelled, case .skipped = outcome { report.isCancelled = true; break }
            record(file, outcome)
        }
        for file in plan.files where !file.isOpen {
            if Task.isCancelled { report.isCancelled = true; break }
            // Файл мог открыться в окне, пока шёл диалог: под открытым документом на диск не пишем.
            guard folderWorkspace.rootURL == root, let documents = manager.folderSearchSnapshots(root: root),
                  !documents.contains(where: { $0.url.standardizedFileURL == file.file.url.standardizedFileURL ||
                      $0.identity.matches(DocumentFileIdentity.resolve(file.file.url)) }) else {
                record(file, .skipped(.changed)); continue
            }
            let worker = Task.detached(priority: .userInitiated) { () throws -> FolderReplaceService.Outcome in
                try MarkdownRenameLinkService.applyOnDisk(file, root: root, isCancelled: { Task.isCancelled })
            }
            do {
                record(file, try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }))
            } catch { report.isCancelled = true; break }
        }
        return report
    }

    private func skipText(_ reason: FolderReplaceService.SkipReason) -> String {
        switch reason {
        case .changed: L10n.tr("文件已变化")
        case .notExactUTF8: L10n.tr("不是精确的 UTF-8（含 BOM 等）")
        case .inaccessible: L10n.tr("无法读取")
        case .symbolicLink: L10n.tr("已跳过符号链接")
        case .writeFailed: L10n.tr("无法写入")
        case .openDocumentBusy, .openInEditorFailed: L10n.tr("无法修改已打开的文档")
        }
    }
}

@MainActor
extension AppState {
    var manuscript: ManuscriptController {
        if let manuscriptStorage { return manuscriptStorage }
        let controller = ManuscriptController(snapshots: { [weak self] in
            guard let self, let root = self.folderWorkspace.rootURL, let manager = self.windowManager else { return nil }
            return manager.folderSearchSnapshots(root: root)
        }, syntax: { [weak self] in
            self?.preferences.markdownSyntax ?? MarkdownSyntaxOptions()
        }, onBuilt: { [weak self] output in
            self?.finishManuscript(output)
        })
        manuscriptStorage = controller
        return controller
    }

    func presentManuscript() {
        guard manuscriptSheet == nil, let root = folderWorkspace.rootURL,
              let window = hostWindow, let manager = windowManager, manager.activeState === self,
              manager.ownsVisibleState(self, window: window) else { return }
        let controller = manuscript
        controller.attach(root: root)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ManuscriptView(
            controller: controller,
            folderName: root.lastPathComponent,
            close: { [weak self] in self?.closeManuscript() }
        )))
        sheet.styleMask.remove(.closable)
        manuscriptSheet = sheet
        window.beginSheet(sheet)
    }

    func closeManuscript() {
        manuscriptStorage?.cancel()
        guard let sheet = manuscriptSheet else { return }
        manuscriptSheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    /// Результат применяется, только если лист жив, окно и корень прежние; исходные файлы и документы не меняются.
    private func finishManuscript(_ output: ManuscriptService.Output) {
        guard manuscriptSheet != nil, let window = hostWindow, let manager = windowManager,
              manager.ownsVisibleState(self, window: window),
              folderWorkspace.rootURL == manuscriptStorage?.root else { return }
        let document = EditorDocument(text: output.text, language: .markdown, isDirty: true, requiresExplicitSave: true)
        document.statusMessage = L10n.tr("已合并 %d 个文件", output.report.mergedFiles)
        closeManuscript()
        manager.openNativeTab(from: self, with: document)
        if output.report.hasNotes { showManuscriptNotes(output.report) }
    }

    private func showManuscriptNotes(_ report: ManuscriptService.Report) {
        var parts: [String] = []
        if !report.skipped.isEmpty {
            var lines = [L10n.tr("未合并的文件：")]
            let prefix = (manuscriptStorage?.root?.standardizedFileURL.path ?? "") + "/"
            lines += report.skipped.prefix(10).map { problem in
                let path = problem.url.standardizedFileURL.path
                return "\(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : problem.url.lastPathComponent) — \(manuscriptReason(problem.reason))"
            }
            if report.skipped.count > 10 { lines.append(L10n.tr("……还有 %d 个", report.skipped.count - 10)) }
            parts.append(lines.joined(separator: "\n"))
        }
        if report.unconvertedAddresses > 0 {
            parts.append(L10n.tr("%d 个相对地址未转换（引用式写法、HTML 或无法确认的写法）。", report.unconvertedAddresses))
        }
        if !report.filesWithoutImageCheck.isEmpty {
            parts.append(L10n.tr("无法确认图片写法的文件：%@", report.filesWithoutImageCheck.prefix(10).joined(separator: ", ")))
        }
        if !report.duplicateFootnoteLabels.isEmpty {
            parts.append(L10n.tr("脚注标签重复：%@。文本未改写，请在合并后的文稿中手动改名。",
                                 report.duplicateFootnoteLabels.joined(separator: ", ")))
        }
        if report.blockedByRootURL { parts.append(L10n.tr("第一个文件的元数据设置了 typora-root-url，相对地址未转换。")) }
        let alert = NSAlert()
        alert.messageText = L10n.tr("合并完成，但有需要注意的地方")
        alert.informativeText = parts.joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.tr("关闭"))
        alert.runModal()
    }

    private func manuscriptReason(_ reason: FolderSearchService.ProblemReason) -> String {
        switch reason {
        case .inaccessible: L10n.tr("无法读取")
        case .symbolicLink: L10n.tr("已跳过符号链接")
        case .invalidUTF8: L10n.tr("不是有效的 UTF-8")
        case .invalidTags: L10n.tr("无法读取 YAML 标签")
        case .changed: L10n.tr("文件已变化")
        case .conflictingOpenDocuments: L10n.tr("打开的文档冲突")
        }
    }
}
