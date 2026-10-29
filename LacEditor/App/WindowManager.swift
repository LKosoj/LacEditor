import AppKit
import Combine
import SwiftUI

struct FolderWorkspaceMoveLists {
    let oldRecent: [URL]
    let newRecent: [URL]
    let oldFavorites: [String]
    let newFavorites: [String]
    let oldGroups: [SidebarFileGroup]
    let newGroups: [SidebarFileGroup]
    let isLink: Bool
    var oldRecentFolders: [URL] = []
    var newRecentFolders: [URL] = []
    var oldPinnedFolders: [String] = []
    var newPinnedFolders: [String] = []
}

@MainActor
private final class FolderSearchOpenWaiter {
    weak var manager: WindowManager?
    weak var state: AppState?
    weak var document: EditorDocument?
    let expected: DocumentFileIdentity
    private var continuation: CheckedContinuation<FolderSearchService.OpenDocument?, Never>?
    private var subscriptions: [AnyCancellable] = []
    private var finished = false

    init(manager: WindowManager, state: AppState, document: EditorDocument, expected: DocumentFileIdentity) {
        self.manager = manager
        self.state = state
        self.document = document
        self.expected = expected
    }

    func wait() async -> FolderSearchService.OpenDocument? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !finished, let state, let document, let window = state.hostWindow else {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                subscriptions.append(document.$ioState.sink { [weak self] _ in
                    DispatchQueue.main.async { self?.check() }
                })
                subscriptions.append(state.$documents.sink { [weak self] _ in
                    DispatchQueue.main.async { self?.check() }
                })
                subscriptions.append(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window).sink { [weak self] _ in
                    DispatchQueue.main.async { self?.finish(nil) }
                })
                check()
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    private func check() {
        guard !finished, let manager, let state, let document,
              manager.stateContaining(document) === state,
              state.documents.contains(where: { $0 === document }) else { finish(nil); return }
        if case .failed = document.ioState { finish(nil); return }
        guard document.ioState == .idle, !state.isOpeningPlaceholder(document) else { return }
        guard let url = document.url, let identity = document.fileIdentity, identity.matches(expected) else {
            finish(nil)
            return
        }
        let snapshot = document.synchronizedSnapshot()
        guard manager.stateContaining(document) === state, document.url == url,
              document.fileIdentity == identity, document.textRevision == snapshot.revision,
              !document.hasPendingLiveEdits else { finish(nil); return }
        finish(.init(url: url, identity: identity, snapshot: snapshot))
    }

    private func finish(_ result: FolderSearchService.OpenDocument?) {
        guard !finished else { return }
        finished = true
        subscriptions.removeAll()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}

@MainActor
final class WindowManager: ObservableObject {
    static let tabPasteboardType = NSPasteboard.PasteboardType(
        "com.laceditor.editor-tab"
    )

    let recentFiles: RecentFilesStore
    let sidebarLibrary: SidebarLibraryStore
    let preferences: AppPreferences
    let recoveryStore: DocumentRecoveryStore?
    let workspaceStore: WorkspaceSessionStore?
    let experimentSamples: ExperimentSampleLibrary?
    @Published private(set) var activeState: AppState?
    @Published private(set) var draggedDocumentID: UUID?
    /// Changes whenever the retained primary window is reopened. Sidebar
    /// scroll views use this identity to discard stale content offsets from a
    /// window that was closed after its last tab was removed.
    @Published private(set) var primaryReopenGeneration = 0
    private(set) var terminationApproved = false
    private(set) var startupError: Error?

    private final class ActiveTabDrag {
        let documentID: UUID
        weak var sourceState: AppState?
        weak var targetState: AppState?
        var targetDocumentID: UUID?
        var wasAccepted = false

        init(documentID: UUID, sourceState: AppState) {
            self.documentID = documentID
            self.sourceState = sourceState
        }
    }

    private var exportingDocumentIDs: Set<UUID> = []
    private var folderMoveDocumentIDs: Set<UUID> = []
    private var folderMovePaths: [URL] = []
    private var folderMoveIdentities: [DocumentFileIdentity] = []
    private var states: [UUID: AppState] = [:]
    private var windowControllers: [UUID: NSWindowController] = [:]
    // Retain the initial editor state and its native window across closing the
    // last window. App, document, and Dock launches share this single owner.
    private var primaryWindowID: UUID?
    private var transferringDocumentIDs: Set<UUID> = []
    private var activeTabDrag: ActiveTabDrag?
    private var isConfirmingRecentFilesClear = false
    private var activeStateCancellable: AnyCancellable?
    private var recentFilesCancellable: AnyCancellable?
    private var sidebarLibraryCancellable: AnyCancellable?
    private let fileService = FileService()
    private var recoveredDocuments: [EditorDocument] = []
    private struct RestoredWindow {
        let documents: [EditorDocument]
        let selectedDocumentID: UUID?
        let isSidebarVisible: Bool
        let frame: WorkspaceWindowFrame?
        var folderStates: [UUID: FolderWorkspaceSession] = [:]
    }
    private var initialRestoredWindow: RestoredWindow?
    private var pendingRestoredWindows: [RestoredWindow] = []
    private var restorationReferences: [UUID: DocumentRecoveryReference] = [:]
    private var restorationOrder: [UUID] = []
    private var restorationLoadingID: UUID?
    private let restorationQueue = DispatchQueue(label: "com.laceditor.restore", qos: .utility)
    private let readRestoration: @Sendable (DocumentRecoveryReference) throws -> DocumentRecoverySnapshot
    enum CommandLineCreation: Equatable { case file, directory }
    private struct PendingOpen {
        let url: URL
        let allowsCreation: Bool
        let confirm: ((URL) -> CommandLineCreation?)?
    }
    private var pendingFinderURLs: [PendingOpen] = []
    private var didApplyInitialRestoration = false
    private var didConsiderStartupFolder = false
    private lazy var appearanceMenuController = AppearanceMenuController(
        windowManager: self
    )
    private lazy var menuLocalizationController = MenuLocalizationController()

    init(
        recoveryStore: DocumentRecoveryStore? = nil,
        workspaceStore: WorkspaceSessionStore? = nil,
        preferences: AppPreferences? = nil,
        recentFiles: RecentFilesStore? = nil,
        sidebarLibrary: SidebarLibraryStore? = nil,
        experimentSamples: ExperimentSampleLibrary? = nil,
        readRestoration: @escaping @Sendable (DocumentRecoveryReference) throws -> DocumentRecoverySnapshot = { reference in
            try DocumentRecoveryStore.read(reference)
        }
    ) {
        self.recentFiles = recentFiles ?? RecentFilesStore()
        self.sidebarLibrary = sidebarLibrary ?? SidebarLibraryStore()
        self.recoveryStore = recoveryStore
        self.workspaceStore = workspaceStore
        self.experimentSamples = experimentSamples
        self.readRestoration = readRestoration
        self.preferences = preferences ?? AppPreferences()
        do {
            let recovered = try recoveryStore?.startSessionReferences() ?? []
            let workspace = try workspaceStore?.loadReferences()
            var references = Dictionary(uniqueKeysWithValues: recovered.map { ($0.snapshot.documentID, $0) })
            if let workspace, let recoveryStore {
                let handoff = workspace.windows.flatMap(\.documents).filter { references[$0.snapshot.documentID] == nil }
                for reference in try recoveryStore.copyForWorkspaceHandoff(handoff) {
                    references[reference.snapshot.documentID] = reference
                }
                try workspaceStore?.consume()
            } else if let workspace {
                for reference in workspace.windows.flatMap(\.documents) where references[reference.snapshot.documentID] == nil {
                    let value = reference.snapshot
                    references[value.documentID] = DocumentRecoveryReference(snapshot: DocumentRecoverySnapshot(
                        documentID: value.documentID, text: "", sourceURL: value.sourceURL,
                        language: value.language, encoding: value.encoding, revision: 0,
                        selectionRange: value.selectionRange, scrollPositionRatio: value.scrollPositionRatio,
                        isPreviewVisible: value.isPreviewVisible, fileRevisionSnapshot: value.fileRevisionSnapshot,
                        capturedAt: Date(), isDirty: value.isDirty), contentURL: reference.contentURL)
                }
            }
            restorationReferences = references
            restoreInitialSession(workspace: workspace, recoverySnapshots: recovered)
        } catch {
            startupError = error
        }
        recentFilesCancellable = self.recentFiles.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        sidebarLibraryCancellable = self.sidebarLibrary.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        _ = appearanceMenuController
        _ = menuLocalizationController
    }

    func takeRecoveredDocuments() -> [EditorDocument] {
        defer { recoveredDocuments.removeAll() }
        return recoveredDocuments
    }

    func preparePrimaryWindow(windowID: UUID, state: AppState) {
        precondition(primaryWindowID == nil)
        primaryWindowID = windowID
        states[windowID] = state
        state.windowManager = self
    }

    func prepareExperimentSamples() async {
        await experimentSamples?.prepare(in: sidebarLibrary)
    }

    func openExperimentWelcome(in state: AppState) {
        guard let samples = experimentSamples, !samples.isPreparing else { return }
        Task { [weak self, weak state] in
            guard let self, let state else { return }
            await samples.prepare(in: sidebarLibrary)
            guard samples.errorMessage == nil else { return }
            state.openFile(samples.welcomeURL)
        }
    }

    func persistRecoverySnapshotsImmediately() {
        states.values.forEach { $0.persistRecoverySnapshotsImmediately() }
    }

    func register(windowID: UUID, state: AppState, window: NSWindow) {
        let considerStartupFolder = !didConsiderStartupFolder
        didConsiderStartupFolder = true
        let wasDetachedPrimaryWindow = windowID == primaryWindowID
            && state.hostWindow !== window
            && (state.hostWindow == nil || state.hostWindow?.isVisible == false)
        if primaryWindowID == nil {
            primaryWindowID = windowID
        }
        states[windowID] = state
        state.windowManager = self
        state.hostWindow = window
        if wasDetachedPrimaryWindow {
            primaryReopenGeneration &+= 1
        }
        if window.isKeyWindow || activeState == nil {
            activate(windowID: windowID)
        }
        if !didApplyInitialRestoration,
           let restoration = initialRestoredWindow {
            didApplyInitialRestoration = true
            apply(restoration, to: state, window: window)
            let additionalWindows = pendingRestoredWindows
            pendingRestoredWindows.removeAll()
            DispatchQueue.main.async { [weak self] in
                additionalWindows.forEach { self?.openRestoredWindow($0) }
                self?.loadNextRestoration()
                self?.drainPendingFinderURLs()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.drainPendingFinderURLs()
            }
        }
        if considerStartupFolder {
            if state.folderWorkspace.rootURL == nil, pendingFinderURLs.isEmpty,
               !preferences.startupFolderPath.isEmpty {
                state.openFolder(URL(fileURLWithPath: preferences.startupFolderPath, isDirectory: true))
            }
        }
    }

    /// Routes files opened from Finder into the already registered editor
    /// window. Finder can send this event before applicationDidFinishLaunching,
    /// so retain the URLs until primary window registration completes
    /// instead of creating a temporary second window.
    func openFilesFromFinder(_ urls: [URL]) {
        guard startupError == nil else { return }
        routeOpenRequests(urls.filter(\.isFileURL).map { PendingOpen(url: $0, allowsCreation: false, confirm: nil) })
    }

    nonisolated static func commandLineURLs(arguments: [String], workingDirectory: URL) -> [URL] {
        var paths: [URL] = [], positionalOnly = false
        for argument in arguments {
            if !positionalOnly {
                if argument == "--" { positionalOnly = true; continue }
                if argument.hasPrefix("-psn_") { continue }
                if argument.hasPrefix("-") { break }
            }
            guard !argument.isEmpty else { continue }
            paths.append(URL(fileURLWithPath: argument, isDirectory: argument.hasSuffix("/"), relativeTo: workingDirectory).absoluteURL.standardizedFileURL)
        }
        return paths
    }

    func openFilesFromCommandLine(_ urls: [URL], confirm: ((URL) -> CommandLineCreation?)? = nil) {
        guard startupError == nil else { return }
        routeOpenRequests(urls.filter(\.isFileURL).map { PendingOpen(url: $0, allowsCreation: true, confirm: confirm) })
    }

    private func routeOpenRequests(_ requests: [PendingOpen]) {
        guard activeState != nil else {
            for request in requests {
                let identity = DocumentFileIdentity.resolve(request.url)
                if let index = pendingFinderURLs.firstIndex(where: { DocumentFileIdentity.resolve($0.url).matches(identity) }) {
                    if request.allowsCreation { pendingFinderURLs[index] = request }
                } else { pendingFinderURLs.append(request) }
            }
            return
        }
        requests.forEach(openPendingRequest)
    }

    private func drainPendingFinderURLs() {
        guard activeState != nil, !pendingFinderURLs.isEmpty else { return }
        let files = pendingFinderURLs
        pendingFinderURLs.removeAll()
        files.forEach(openPendingRequest)
    }

    private func openPendingRequest(_ request: PendingOpen) {
        let url = request.url
        guard request.allowsCreation, !FileManager.default.fileExists(atPath: url.path) else {
            openFinderURL(url)
            return
        }
        guard let state = activeState, let window = state.hostWindow else { return }
        let choice: CommandLineCreation?
        if let confirm = request.confirm { choice = confirm(url) }
        else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("路径不存在，要创建吗？")
            alert.informativeText = url.path
            if !url.hasDirectoryPath { alert.addButton(withTitle: L10n.tr("创建文件")) }
            alert.addButton(withTitle: L10n.tr("创建文件夹"))
            alert.addButton(withTitle: L10n.tr("取消"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { choice = url.hasDirectoryPath ? .directory : .file }
            else if !url.hasDirectoryPath, response == .alertSecondButtonReturn { choice = .directory }
            else { choice = nil }
        }
        guard let choice, activeState === state, state.hostWindow === window,
              states.values.contains(where: { $0 === state }) else { return }
        if FileManager.default.fileExists(atPath: url.path) { openFinderURL(url); return }
        do {
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            let created = try fileService.createWorkspaceItem(named: url.lastPathComponent, in: parent, root: parent,
                                                              isDirectory: choice == .directory)
            openFinderURL(created)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { openFinderURL(url) }
            else { state.selectedDocument?.statusMessage = L10n.tr("无法创建路径：%@", error.localizedDescription) }
        }
    }

    private func openFinderURL(_ url: URL) {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            activeState?.openFolder(url)
        } else {
            openFile(url, preferredState: activeState)
        }
    }

    func activate(windowID: UUID) {
        guard let state = states[windowID] else { return }
        guard activeState !== state else { return }
        if let previous = activeState, previous !== state,
           let group = state.hostWindow?.tabGroup,
           let previousWindow = previous.hostWindow,
           group.windows.contains(previousWindow) {
            state.isSidebarVisible = previous.isSidebarVisible
        }
        setActiveState(state)
        if let id = state.selectedDocumentID { prioritizeRestoration(id) }
    }

    private func setActiveState(_ state: AppState?) {
        guard activeState !== state else { return }
        activeStateCancellable = nil
        activeState = state
        activeStateCancellable = state?.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func unregister(windowID: UUID) {
        guard let state = states[windowID] else { return }
        state.closeAuxiliaryWindows()

        // Reuse the primary editor after its final blank tab closes. Its state
        // must remain registered so sidebar and commands target it on reopen.
        if windowID == primaryWindowID {
            state.resetClosedWindow()
            setActiveState(states.values.first(where: {
                $0 !== state && $0.hostWindow?.isVisible == true
            }) ?? state)
            return
        }

        let removedState = states.removeValue(forKey: windowID)
        windowControllers.removeValue(forKey: windowID)
        if activeState === removedState {
            setActiveState(states.values.first(where: {
                $0.hostWindow?.isVisible == true
            }))
        }
    }

    /// Create or re-show the same primary editor for app/file launch and Dock
    /// reopen. Never wait for a SwiftUI Window scene to bootstrap this state.
    func reopenPrimaryWindow() {
        guard startupError == nil else { return }
        guard let primaryWindowID,
              let state = states[primaryWindowID] else { return }
        guard let window = state.hostWindow else {
            showNativeWindow(windowID: primaryWindowID, state: state, near: nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        primaryReopenGeneration &+= 1
        register(windowID: primaryWindowID, state: state, window: window)
        activate(windowID: primaryWindowID)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func openNativeTab(from source: AppState? = nil, with document: EditorDocument? = nil) -> AppState {
        let source = source ?? activeState
        let parent = source?.hostWindow
        let state = openNewWindow(with: document)
        if let source { state.isSidebarVisible = source.isSidebarVisible }
        if let parent, parent.isVisible || parent.tabGroup?.windows.contains(where: { $0.isVisible }) == true, let window = state.hostWindow {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        return state
    }

    func ownsVisibleState(_ state: AppState, window: NSWindow) -> Bool {
        states.values.contains { $0 === state } && state.hostWindow === window
            && (window.isVisible || window.tabGroup?.windows.contains(where: { $0.isVisible }) == true)
    }

    @discardableResult
    func openNewWindow(
        with document: EditorDocument? = nil,
        near screenPoint: NSPoint? = nil
    ) -> AppState {
        let windowID = UUID()
        let state = AppState(
            initialDocument: document,
            recentFiles: recentFiles,
            preferences: preferences,
            recoveryStore: recoveryStore
        )
        state.windowManager = self
        states[windowID] = state

        showNativeWindow(windowID: windowID, state: state, near: screenPoint)
        return state
    }

    private func showNativeWindow(windowID: UUID, state: AppState, near screenPoint: NSPoint?) {
        let rootView = EditorWindowRoot(
            appState: state,
            windowManager: self,
            windowID: windowID
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        window.title = state.windowTitle
        configureEditorWindowChrome(window)
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.minSize = NSSize(width: 900, height: 560)
        if let screenPoint {
            position(window, near: screenPoint)
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        state.hostWindow = window

        let controller = NSWindowController(window: window)
        windowControllers[windowID] = controller
        window.tabbingMode = .disallowed
        controller.showWindow(nil)
        window.tabbingMode = .preferred
        window.makeKeyAndOrderFront(nil)
        // Register synchronously once visible, so restoration can insert and
        // select native tabs without the factory showing the first tab again.
        // Do not depend on the later SwiftUI representable callback.
        register(windowID: windowID, state: state, window: window)
        DispatchQueue.main.async { [weak window, weak state] in
            guard let window, let state else { return }
            configureEditorWindowChrome(window, appState: state)
        }
    }

    private func openRestoredWindow(_ restoration: RestoredWindow) {
        let state = openNewWindow(with: restoration.documents.first)
        guard let window = state.hostWindow else { return }
        apply(restoration, to: state, window: window)
    }

    func openFileInNewWindow(_ url: URL) {
        openFile(url, preferredState: nil, createWindowIfNeeded: true)
    }

    @discardableResult
    func openFile(
        _ url: URL,
        preferredState: AppState?,
        createWindowIfNeeded: Bool = false
    ) -> (state: AppState, document: EditorDocument)? {
        let identity = DocumentFileIdentity.resolve(url)
        if folderMovePaths.contains(where: { Self.pathsOverlap($0, url) || Self.pathsOverlap($0, url.resolvingSymlinksInPath()) }) ||
            folderMoveIdentities.contains(where: { $0.matches(identity) }) {
            (preferredState ?? activeState)?.selectedDocument?.statusMessage = L10n.tr("文件操作进行中，请稍后重试")
            return nil
        }
        if let match = openDocument(matching: identity) {
            focus(match.document, in: match.state)
            return match
        }
        let candidate = preferredState ?? activeState
        let target: AppState
        if createWindowIfNeeded {
            target = openNewWindow()
        } else if let candidate, candidate.documents.count == 1,
                  candidate.documents.first?.isDisposableBlank == true {
            target = candidate
        } else {
            target = openNativeTab(from: candidate)
        }
        target.hostWindow?.makeKeyAndOrderFront(nil)
        target.beginOpeningFile(url)
        guard let opened = openDocument(matching: identity) else { return nil }
        if opened.state === target, target.isOpeningPlaceholder(opened.document), target.folderWorkspace.rootURL == nil {
            target.folderWorkspace.setRoot(url.deletingLastPathComponent())
        }
        return opened
    }

    private static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        let a = first.standardizedFileURL.pathComponents
        let b = second.standardizedFileURL.pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }

    func isFolderMoveBlocked(_ document: EditorDocument, target: URL) -> Bool {
        let targetIdentity = folderMoveIdentities.isEmpty ? nil : DocumentFileIdentity.resolve(target)
        return folderMoveDocumentIDs.contains(document.id) || folderMoveIdentities.contains {
            document.fileIdentity?.matches($0) == true || targetIdentity?.matches($0) == true
        } || folderMovePaths.contains {
            Self.pathsOverlap($0, target) || Self.pathsOverlap($0, target.resolvingSymlinksInPath())
        }
    }

    func beginFolderRemoval(_ url: URL, snapshot: WorkspaceItemSnapshot, otherURL: URL? = nil) -> Bool {
        guard folderMovePaths.isEmpty else { return false }
        folderMovePaths = [url] + (otherURL.map { [$0] } ?? [])
        folderMoveIdentities = snapshot.fileIdentities
        return true
    }

    func endFolderRemoval() {
        folderMovePaths.removeAll()
        folderMoveIdentities.removeAll()
    }

    private static func movedURL(_ url: URL, from source: URL, to destination: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        let base = source.standardizedFileURL.pathComponents
        guard components.starts(with: base) else { return nil }
        return components.dropFirst(base.count).reduce(destination) { $0.appendingPathComponent($1) }
    }

    /// Moves disk data while affected documents cannot start another save.
    /// Existing document objects remain in their windows.
    func moveFolderWorkspaceItem(_ source: URL, to destination: URL, root: URL, state: AppState,
                                 expectedIdentity: WorkspaceNodeIdentity? = nil, updateLists: Bool = true) async -> (Bool, WorkspaceNodeIdentity?, FolderWorkspaceMoveLists?) {
        guard folderMovePaths.isEmpty, state.folderWorkspace.rootURL == root else { return (false, nil, nil) }
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard source != root.standardizedFileURL, source != destination else { return (false, nil, nil) }
        let values = try? URL(fileURLWithPath: source.path).resourceValues(forKeys: [.isSymbolicLinkKey])
        guard let values else { return (false, nil, nil) }
        let isLink = values.isSymbolicLink == true
        let folderSource = source.resolvingSymlinksInPath()
        func linkTargetPreserved(_ old: URL, new: URL) -> Bool {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: old.path) else { return false }
            let future = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : new.deletingLastPathComponent().appendingPathComponent(target)).standardizedFileURL
            let oldCandidate: URL
            if let mapped = Self.movedURL(future, from: destination, to: source) {
                oldCandidate = mapped
            } else {
                guard Self.movedURL(future, from: source, to: source) == nil else { return false }
                oldCandidate = future
            }
            return DocumentFileIdentity.resolve(old).matches(DocumentFileIdentity.resolve(oldCandidate))
        }
        var ambiguous = false
        let documents = documentsForAI.compactMap { document -> (EditorDocument, URL, URL)? in
            guard let old = document.url else { return nil }
            if isLink {
                guard old.standardizedFileURL == source else { return nil }
                if !linkTargetPreserved(old, new: destination) { ambiguous = true }
                return (document, old, destination)
            }
            let resolved = old.standardizedFileURL.resolvingSymlinksInPath()
            if let new = Self.movedURL(old, from: source, to: destination) {
                let oldValues = try? URL(fileURLWithPath: old.path).resourceValues(forKeys: [.isSymbolicLinkKey])
                guard let oldValues else { ambiguous = true; return nil }
                if oldValues.isSymbolicLink == true {
                    if !linkTargetPreserved(old, new: new) { ambiguous = true }
                } else if Self.movedURL(resolved, from: source, to: destination) == nil {
                    ambiguous = true
                }
                return (document, old, new)
            }
            guard let new = Self.movedURL(resolved, from: source, to: destination) else { return nil }
            return (document, old, new)
        }
        guard !ambiguous, documents.allSatisfy({ $0.0.ioState == .idle }),
              !documentsForAI.contains(where: { document in
                  guard let url = document.url else { return false }
                  let canonical = url.resolvingSymlinksInPath()
                  let targetIdentity = DocumentFileIdentity.resolve(destination)
                  return Self.movedURL(url, from: destination, to: destination) != nil ||
                      Self.movedURL(canonical, from: destination, to: destination) != nil ||
                      document.fileIdentity?.matches(targetIdentity) == true
              }) else { return (false, nil, nil) }
        folderMoveDocumentIDs = Set(documents.map { $0.0.id })
        folderMovePaths = [source, destination]
        defer { folderMoveDocumentIDs.removeAll(); folderMovePaths.removeAll() }
        let records = documents.map { ($0.0.id, $0.1, $0.2, $0.0.fileRevisionSnapshot) }
        let service = fileService
        let result = await Task.detached { () -> Result<([(UUID, URL, FileRevisionSnapshot?)], WorkspaceNodeIdentity?), Error> in
            Result {
                if let expectedIdentity, try service.workspaceNodeIdentity(source) != expectedIdentity {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let before = records.map { (id: $0.0, old: $0.1, new: $0.2, baseline: $0.3, current: try? FileRevisionSnapshot.capture($0.1)) }
                _ = try service.moveWorkspaceItem(source, to: destination.deletingLastPathComponent(), named: destination.lastPathComponent, root: root)
                let updates = before.map { record in
                    let after = try? FileRevisionSnapshot.capture(record.new)
                    let safe = record.baseline != nil && record.baseline == record.current &&
                        record.current?.identity.resourceIdentifier != nil &&
                        record.current?.identity.resourceIdentifier == after?.identity.resourceIdentifier
                    return (record.id, record.new, safe ? after : nil)
                }
                return (updates, try? service.workspaceNodeIdentity(destination))
            }
        }.value
        guard case let .success((updated, identity)) = result else { return (false, nil, nil) }
        for (id, newURL, newBaseline) in updated {
            guard let document = documentsForAI.first(where: { $0.id == id }) else { continue }
            document.updateLocation(to: newURL)
            if let newBaseline { document.updateFileRevisionSnapshot(newBaseline) }
        }
        let oldRecent = recentFiles.urls
        let oldFavorites = sidebarLibrary.favoritePaths
        let oldGroups = sidebarLibrary.groups
        let oldRecentFolders = recentFiles.folderURLs
        let oldPinnedFolders = sidebarLibrary.pinnedFolderPaths
        if updateLists {
            let paths = recentFiles.urls + sidebarLibrary.favoriteURLs + sidebarLibrary.groups.flatMap(\.urls)
            for old in Set(paths) {
                if isLink && old.standardizedFileURL != source { continue }
                guard let new = Self.movedURL(old, from: source, to: destination) else { continue }
                recentFiles.replace(old, with: new)
                sidebarLibrary.replace(old, with: new)
            }
        }
        if updateLists, !isLink {
            let folderDestination = destination.resolvingSymlinksInPath()
            for old in Set(oldRecentFolders + oldPinnedFolders.map(URL.init(fileURLWithPath:))) {
                guard let new = Self.movedURL(old, from: folderSource, to: folderDestination) else { continue }
                recentFiles.replaceFolder(old, with: new)
                sidebarLibrary.replacePinnedFolder(old, with: new)
            }
        }
        let listChanges = FolderWorkspaceMoveLists(oldRecent: oldRecent, newRecent: recentFiles.urls,
            oldFavorites: oldFavorites, newFavorites: sidebarLibrary.favoritePaths,
            oldGroups: oldGroups, newGroups: sidebarLibrary.groups, isLink: isLink,
            oldRecentFolders: oldRecentFolders, newRecentFolders: recentFiles.folderURLs,
            oldPinnedFolders: oldPinnedFolders, newPinnedFolders: sidebarLibrary.pinnedFolderPaths)
        state.folderWorkspace.refresh()
        return (true, identity, updateLists ? listChanges : nil)
    }

    func restoreFolderWorkspaceLists(_ changes: FolderWorkspaceMoveLists) {
        _ = recentFiles.restore(changes.oldRecent, ifUnchanged: changes.newRecent)
        _ = recentFiles.restoreFolders(changes.oldRecentFolders, ifUnchanged: changes.newRecentFolders)
        _ = sidebarLibrary.restorePinnedFolders(changes.oldPinnedFolders, ifUnchanged: changes.newPinnedFolders)
        _ = sidebarLibrary.restoreFavorites(changes.oldFavorites, ifUnchanged: changes.newFavorites)
        for old in changes.oldGroups {
            guard let expected = changes.newGroups.first(where: { $0.id == old.id }) else { continue }
            _ = sidebarLibrary.restoreGroupFiles(old.paths, in: old.id, ifUnchanged: expected.paths)
        }
    }

    func restoreMovedFolderWorkspaceLists(_ changes: FolderWorkspaceMoveLists, source: URL, destination: URL) {
        if !changes.isLink {
            let folderSource = source.resolvingSymlinksInPath(), folderDestination = destination.resolvingSymlinksInPath()
            for old in changes.oldRecentFolders {
                guard let new = Self.movedURL(old, from: folderSource, to: folderDestination),
                      recentFiles.folderURLs.contains(where: { $0.path == new.path }) else { continue }
                recentFiles.replaceFolder(new, with: old)
            }
            for old in changes.oldPinnedFolders.map(URL.init(fileURLWithPath:)) {
                guard let new = Self.movedURL(old, from: folderSource, to: folderDestination) else { continue }
                sidebarLibrary.replacePinnedFolder(new, with: old)
            }
        }
        func moved(_ old: URL) -> URL? {
            if changes.isLink && old.standardizedFileURL != source.standardizedFileURL { return nil }
            return Self.movedURL(old, from: source, to: destination)
        }
        for old in changes.oldRecent {
            guard let new = moved(old), recentFiles.urls.contains(where: { $0.standardizedFileURL == new.standardizedFileURL }) else { continue }
            recentFiles.replace(new, with: old)
        }
        for path in changes.oldFavorites {
            let old = URL(fileURLWithPath: path)
            guard let new = moved(old) else { continue }
            sidebarLibrary.replaceFavorite(new, with: old)
        }
        for group in changes.oldGroups {
            for old in group.urls {
                guard let new = moved(old) else { continue }
                sidebarLibrary.replaceFile(new, with: old, inGroup: group.id)
            }
        }
    }

    func trashFolderWorkspaceItem(_ source: URL, root: URL, state: AppState,
                                  expectedIdentity: WorkspaceNodeIdentity,
                                  trash: (@Sendable (URL, URL, WorkspaceNodeIdentity) throws -> URL?)? = nil) async -> (Bool, URL?, WorkspaceNodeIdentity?, FolderWorkspaceMoveLists?) {
        guard folderMovePaths.isEmpty, state.folderWorkspace.rootURL == root,
              source.standardizedFileURL != root.standardizedFileURL,
              let values = try? URL(fileURLWithPath: source.path).resourceValues(forKeys: [.isSymbolicLinkKey]),
              (try? fileService.workspaceNodeIdentity(source)) == expectedIdentity else { return (false, nil, nil, nil) }
        let isLink = values.isSymbolicLink == true
        let folderSource = source.resolvingSymlinksInPath()
        func affected() -> [EditorDocument] {
            return documentsForAI.filter { document in
                guard let url = document.url else { return false }
                if isLink { return url.standardizedFileURL == source.standardizedFileURL }
                return Self.movedURL(url.resolvingSymlinksInPath(), from: source, to: source) != nil
            }
        }
        var currentIdentity = expectedIdentity
        for document in affected() {
            guard state.folderWorkspace.rootURL == root,
                  let owner = stateContaining(document),
                  (try? fileService.workspaceNodeIdentity(source)) == currentIdentity else { return (false, nil, nil, nil) }
            let approved = await withCheckedContinuation { continuation in
                owner.closeForFolderOperation(document, keepWindow: owner === state) { continuation.resume(returning: $0) }
            }
            guard approved, let after = try? fileService.workspaceNodeIdentity(source) else { return (false, nil, nil, nil) }
            if after != currentIdentity {
                guard document.url?.standardizedFileURL == source.standardizedFileURL,
                      !document.isDirty, let baseline = document.fileRevisionSnapshot,
                      (try? FileRevisionSnapshot.capture(source)) == baseline else { return (false, nil, nil, nil) }
                currentIdentity = after
            }
        }
        guard state.folderWorkspace.rootURL == root, affected().isEmpty else { return (false, nil, nil, nil) }
        let service = fileService
        let snapshot = await Task.detached { () -> WorkspaceItemSnapshot? in
            do {
                try service.validateWorkspaceDirectory(source.deletingLastPathComponent(), root: root)
                return try service.workspaceItemSnapshot(source)
            } catch { return nil }
        }.value
        guard let snapshot, snapshot.rootDevice == currentIdentity.device, snapshot.rootInode == currentIdentity.inode,
              state.folderWorkspace.rootURL == root, beginFolderRemoval(source, snapshot: snapshot) else { return (false, nil, nil, nil) }
        defer { endFolderRemoval() }
        guard affected().isEmpty else { return (false, nil, nil, nil) }
        let identity = currentIdentity
        let result = await Task.detached { () -> Result<URL?, Error> in
            Result {
                if let trash { return try trash(source, root, identity) }
                return try service.trashWorkspaceItem(source, root: root, expectedIdentity: identity)
            }
        }.value
        guard case let .success(trashURL) = result else { return (false, nil, nil, nil) }
        let oldRecent = recentFiles.urls
        let oldFavorites = sidebarLibrary.favoritePaths
        let oldGroups = sidebarLibrary.groups
        let oldRecentFolders = recentFiles.folderURLs
        let oldPinnedFolders = sidebarLibrary.pinnedFolderPaths
        if !isLink {
            for url in oldRecentFolders where Self.movedURL(url, from: folderSource, to: folderSource) != nil { recentFiles.removeFolder(url) }
            for url in oldPinnedFolders.map(URL.init(fileURLWithPath:)) where Self.movedURL(url, from: folderSource, to: folderSource) != nil {
                if sidebarLibrary.isPinnedFolder(url) { sidebarLibrary.togglePinnedFolder(url) }
            }
            for url in oldRecent where Self.movedURL(url, from: source, to: source) != nil { recentFiles.remove(url) }
            for url in oldFavorites.map(URL.init(fileURLWithPath:)) where Self.movedURL(url, from: source, to: source) != nil {
                if sidebarLibrary.isFavorite(url) { sidebarLibrary.toggleFavorite(url) }
            }
            for group in oldGroups {
                for url in group.urls where Self.movedURL(url, from: source, to: source) != nil { sidebarLibrary.remove(url, fromGroup: group.id) }
            }
        }
        let changes = FolderWorkspaceMoveLists(oldRecent: oldRecent, newRecent: recentFiles.urls,
            oldFavorites: oldFavorites, newFavorites: sidebarLibrary.favoritePaths,
            oldGroups: oldGroups, newGroups: sidebarLibrary.groups, isLink: isLink,
            oldRecentFolders: oldRecentFolders, newRecentFolders: recentFiles.folderURLs,
            oldPinnedFolders: oldPinnedFolders, newPinnedFolders: sidebarLibrary.pinnedFolderPaths)
        let trashIdentity = trashURL.flatMap { try? service.workspaceNodeIdentity($0) }
        state.folderWorkspace.refresh()
        return (true, trashURL, trashIdentity, changes)
    }

    func restoreFolderWorkspaceTrash(_ trashURL: URL, to source: URL, root: URL, state: AppState,
                                     expectedIdentity: WorkspaceNodeIdentity, changes: FolderWorkspaceMoveLists) async -> Bool {
        guard state.folderWorkspace.rootURL == root else { return false }
        let service = fileService
        let snapshot = await Task.detached { try? service.workspaceItemSnapshot(trashURL) }.value
        guard let snapshot, snapshot.rootDevice == expectedIdentity.device, snapshot.rootInode == expectedIdentity.inode,
              state.folderWorkspace.rootURL == root,
              beginFolderRemoval(source, snapshot: snapshot, otherURL: trashURL) else { return false }
        defer { endFolderRemoval() }
        guard !state.hasOpenDocument(in: trashURL, snapshot: snapshot),
              !documentsForAI.contains(where: { document in
                  guard let url = document.url else { return false }
                  return Self.movedURL(url, from: source, to: source) != nil
              }) else { return false }
        let restored = await Task.detached { () -> Bool in
            do {
                try service.restoreWorkspaceTrashItem(trashURL, to: source, root: root, expectedIdentity: expectedIdentity)
                return true
            } catch { return false }
        }.value
        if restored {
            restoreFolderWorkspaceLists(changes)
            state.folderWorkspace.refresh()
        }
        return restored
    }

    func beginMarkdownExport(documentID: UUID) -> Bool {
        exportingDocumentIDs.insert(documentID).inserted
    }

    func endMarkdownExport(documentID: UUID) {
        exportingDocumentIDs.remove(documentID)
    }

    func stateContaining(_ document: EditorDocument) -> AppState? {
        states.values.first { state in state.documents.contains { $0 === document } }
    }

    var documentsForAI: [EditorDocument] {
        states.values.flatMap(\.documents)
    }

    func folderSearchSnapshots(root: URL) -> [FolderSearchService.OpenDocument]? {
        let initial = states.values.flatMap { state in state.documents.map { (state, $0, $0.url, $0.fileIdentity) } }
        var result: [FolderSearchService.OpenDocument] = []
        for (state, document, originalURL, originalIdentity) in initial {
            guard document.url == originalURL, document.fileIdentity == originalIdentity else { return nil }
            guard let url = originalURL else { continue }
            guard url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents) else { continue }
            guard !state.isOpeningPlaceholder(document), document.ioState != .opening,
                  let identity = document.fileIdentity else { return nil }
            let snapshot = document.synchronizedSnapshot()
            guard stateContaining(document) === state, document.url == url,
                  document.fileIdentity == identity, document.textRevision == snapshot.revision,
                  !document.hasPendingLiveEdits else { return nil }
            result.append(.init(url: url, identity: identity, snapshot: snapshot))
        }
        let current = states.values.flatMap { state in state.documents.map { (state, $0) } }
        guard current.count == initial.count,
              initial.allSatisfy({ old in current.contains { $0.0 === old.0 && $0.1 === old.1 } && old.1.url == old.2 && old.1.fileIdentity == old.3 }),
              result.allSatisfy({ value in
                  guard let document = documentsForAI.first(where: { $0.id == value.snapshot.documentID }) else { return false }
                  return document.url == value.url && document.fileIdentity == value.identity &&
                      document.textRevision == value.snapshot.revision && !document.hasPendingLiveEdits
              }) else { return nil }
        return result
    }

    func openFolderSearchFile(_ url: URL, preferredState: AppState) async -> FolderSearchService.OpenDocument? {
        guard !Task.isCancelled else { return nil }
        let expected = DocumentFileIdentity.resolve(url)
        guard !Task.isCancelled, let opened = openFile(url, preferredState: preferredState), !Task.isCancelled else { return nil }
        let waiter = FolderSearchOpenWaiter(manager: self, state: opened.state, document: opened.document, expected: expected)
        return await waiter.wait()
    }

    func revealFolderSearchMatch(_ match: FolderSearchService.Match, expected: FolderSearchService.OpenDocument) -> Bool {
        guard let document = documentsForAI.first(where: { $0.id == expected.snapshot.documentID }),
              let state = stateContaining(document), document.ioState == .idle else { return false }
        func isCurrent() -> Bool {
            guard stateContaining(document) === state, document.url == expected.url,
                  document.fileIdentity == expected.identity else { return false }
            let snapshot = document.synchronizedSnapshot()
            let text = snapshot.text as NSString
            let range = match.range
            guard snapshot == expected.snapshot, !document.hasPendingLiveEdits,
                  range.location >= 0, range.location <= text.length, range.length >= 0,
                  range.length <= text.length - range.location,
                  text.substring(with: range) == match.matchedText else { return false }
            if case .open = match.source {
                return FolderSearchService.isCurrent(match, openDocument: .init(url: expected.url, identity: expected.identity, snapshot: snapshot))
            }
            return true
        }
        guard (state.hostWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true,
              isCurrent() else { return false }
        if case .disk = match.source {
            guard activeState === state, state.selectedDocument === document else { return false }
        } else {
            focus(document, in: state)
        }
        guard state.selectedDocument === document,
              (state.hostWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true,
              isCurrent() else { return false }
        state.revealFolderSearchRange(match.range, in: document)
        return true
    }

    var openDocumentURLs: [URL] {
        states.values.flatMap { $0.documents.compactMap(\.url) }
    }

    func conflictingDocument(
        at url: URL,
        excluding documentID: UUID
    ) -> (state: AppState, document: EditorDocument)? {
        let identity = DocumentFileIdentity.resolve(url)
        return states.values.lazy.compactMap { state in
            state.documents.first(where: {
                $0.id != documentID && $0.fileIdentity?.matches(identity) == true
            }).map { (state, $0) }
        }.first
    }

    func focus(_ document: EditorDocument, in state: AppState) {
        state.selectedDocumentID = document.id
        if let window = state.hostWindow { window.tabGroup?.selectedWindow = window }
        state.hostWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDocument(
        matching identity: DocumentFileIdentity
    ) -> (state: AppState, document: EditorDocument)? {
        states.values.lazy.compactMap { state in
            state.documents.first(where: {
                $0.fileIdentity?.matches(identity) == true
            }).map { (state, $0) }
        }.first
    }

    func requestClearRecentFiles() {
        guard !recentFiles.urls.isEmpty,
              !isConfirmingRecentFilesClear else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("清除最近文件？")
        alert.informativeText = L10n.tr("这只会清空最近文件列表，不会删除磁盘上的任何文件。此操作无法撤销。")
        alert.addButton(withTitle: L10n.tr("清除"))
        alert.addButton(withTitle: L10n.tr("取消"))
        isConfirmingRecentFilesClear = true

        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                isConfirmingRecentFilesClear = false
                if response == .alertFirstButtonReturn {
                    recentFiles.clear()
                }
            }
        } else {
            let response = alert.runModal()
            isConfirmingRecentFilesClear = false
            if response == .alertFirstButtonReturn {
                recentFiles.clear()
            }
        }
    }

    func requestCreateSidebarGroup(adding url: URL? = nil) {
        presentTextPrompt(
            title: L10n.tr("新建分组"),
            message: L10n.tr("输入分组名称。"),
            initialValue: L10n.tr("新分组"),
            actionTitle: L10n.tr("创建")
        ) { [weak self] name in
            guard let self,
                  let id = sidebarLibrary.createGroup(named: name) else { return }
            if let url { sidebarLibrary.add(url, toGroup: id) }
        }
    }

    func requestRenameSidebarGroup(_ group: SidebarFileGroup) {
        presentTextPrompt(
            title: L10n.tr("重命名分组"),
            message: L10n.tr("输入新的分组名称。"),
            initialValue: group.name,
            actionTitle: L10n.tr("重命名")
        ) { [weak self] name in
            self?.sidebarLibrary.renameGroup(group.id, to: name)
        }
    }

    func requestDeleteSidebarGroup(_ group: SidebarFileGroup) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("删除分组“%@”？", String(describing: group.name))
        alert.informativeText = L10n.tr("只会删除侧边栏中的快捷入口，不会删除磁盘上的文件。")
        alert.addButton(withTitle: L10n.tr("删除分组"))
        alert.addButton(withTitle: L10n.tr("取消"))
        present(alert) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.sidebarLibrary.deleteGroup(group.id)
            }
        }
    }

    func requestRelocateSidebarFile(_ missingURL: URL) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("重新定位“%@”", String(describing: missingURL.lastPathComponent))
        panel.message = L10n.tr("选择该文件当前所在的位置。")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = FileService.supportedContentTypes
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let replacement = panel.url else { return }
            self?.sidebarLibrary.replace(missingURL, with: replacement)
            self?.recentFiles.replace(missingURL, with: replacement)
        }
        if let window = activeState?.hostWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private func presentTextPrompt(
        title: String,
        message: String,
        initialValue: String,
        actionTitle: String,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: L10n.tr("取消"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initialValue
        alert.accessoryView = field
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue)
        }
    }

    private func present(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func requestRenameFile(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("重命名文件")
        alert.informativeText = L10n.tr("请输入新的文件名。")
        alert.addButton(withTitle: L10n.tr("重命名"))
        alert.addButton(withTitle: L10n.tr("取消"))

        let nameField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 24)
        )
        nameField.stringValue = url.lastPathComponent
        nameField.selectText(nil)
        alert.accessoryView = nameField

        let rename: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = nameField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            self?.renameFile(url, to: newName)
        }

        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window, completionHandler: rename)
        } else {
            rename(alert.runModal())
        }
    }

    @discardableResult
    func beginTabDrag(_ document: EditorDocument, from state: AppState) -> Bool {
        guard state.canTransferDocument(document),
              state.documents.contains(where: { $0.id == document.id }) else {
            return false
        }
        activeTabDrag = ActiveTabDrag(
            documentID: document.id,
            sourceState: state
        )
        draggedDocumentID = document.id
        state.selectedDocumentID = document.id
        return true
    }

    func setTabDragTarget(
        in targetState: AppState,
        before targetDocumentID: UUID?
    ) {
        guard let drag = activeTabDrag else { return }
        drag.targetState = targetState
        drag.targetDocumentID = targetDocumentID
    }

    func clearTabDragTarget(
        in targetState: AppState,
        before targetDocumentID: UUID?
    ) {
        guard let drag = activeTabDrag,
              drag.targetState === targetState,
              drag.targetDocumentID == targetDocumentID else {
            return
        }
        drag.targetState = nil
        drag.targetDocumentID = nil
    }

    @discardableResult
    func acceptTabDrag(
        into targetState: AppState,
        before targetDocumentID: UUID?
    ) -> Bool {
        guard let drag = activeTabDrag,
              let sourceState = drag.sourceState,
              let document = sourceState.documents.first(where: { $0.id == drag.documentID }),
              sourceState.canTransferDocument(document) else {
            return false
        }

        let accepted = moveDraggedDocument(
            drag.documentID,
            from: sourceState,
            to: targetState,
            before: targetDocumentID
        )
        drag.wasAccepted = accepted
        return accepted
    }

    func finishTabDrag(at screenPoint: NSPoint) {
        guard let drag = activeTabDrag else {
            draggedDocumentID = nil
            return
        }
        activeTabDrag = nil
        draggedDocumentID = nil
        guard let sourceState = drag.sourceState else { return }
        if !drag.wasAccepted, let targetState = drag.targetState,
           moveDraggedDocument(
               drag.documentID,
               from: sourceState,
               to: targetState,
               before: drag.targetDocumentID
           ) {
            return
        }
        guard !drag.wasAccepted,
              let document = sourceState.documents.first(where: {
                  $0.id == drag.documentID
              }) else {
            return
        }

        if let targetState = editorState(at: screenPoint) {
            guard targetState !== sourceState else { return }
            _ = transferDocument(
                document.id,
                from: sourceState,
                to: targetState,
                before: nil
            )
        } else {
            detach(document, from: sourceState, near: screenPoint)
        }
    }

    func cancelTabDrag() {
        activeTabDrag = nil
        draggedDocumentID = nil
    }

    private func renameFile(_ url: URL, to newName: String) {
        guard !folderMovePaths.contains(where: { Self.pathsOverlap($0, url) || Self.pathsOverlap($0, url.resolvingSymlinksInPath()) }) else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("文件操作进行中，请稍后重试")
            alert.runModal()
            return
        }
        do {
            let newURL = try fileService.rename(url, to: newName)
            for state in states.values {
                state.updateRenamedFileReference(from: url, to: newURL)
            }
            recentFiles.replace(url, with: newURL)
            sidebarLibrary.replace(url, with: newURL)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = L10n.tr("无法重命名文件")
            if let window = activeState?.hostWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    func detach(
        _ document: EditorDocument,
        from state: AppState,
        near screenPoint: NSPoint? = nil
    ) {
        guard transferringDocumentIDs.insert(document.id).inserted else { return }

        DispatchQueue.main.async { [weak self, weak state] in
            guard let self else { return }
            defer { transferringDocumentIDs.remove(document.id) }
            guard let state,
                  let transferred = state.takeDocumentForTransfer(document) else {
                return
            }
            openNewWindow(with: transferred, near: screenPoint)
        }
    }

    func confirmClosingAllWindows(completion: @escaping (Bool) -> Void) {
        terminationApproved = false
        confirmClosingStates(Array(states.values), completion: completion)
    }

    func requestApplicationTermination(
        completion: @escaping (Bool) -> Void
    ) {
        switch preferences.workspaceExitBehavior {
        case .askToSave:
            confirmClosingAllWindows(completion: completion)
        case .preserveWorkspace:
            if hasDirtyDocuments,
               !preferences.hasConfirmedWorkspaceExitPrompt {
                presentFirstWorkspaceExitPrompt(completion: completion)
            } else {
                preserveWorkspaceAndTerminate(completion: completion)
            }
        }
    }

    private func confirmClosingStates(
        _ queue: [AppState],
        completion: @escaping (Bool) -> Void
    ) {
        guard let state = queue.first else {
            terminationApproved = true
            guard let workspaceStore else {
                finishCleanRecovery(completion: completion)
                return
            }
            workspaceStore.clear { [weak self] in
                guard let self, let recoveryStore else {
                    completion(true)
                    return
                }
                recoveryStore.finishCleanly {
                    completion(true)
                }
            }
            return
        }
        state.confirmClosingAllDocuments { [weak self] approved in
            guard let self, approved else {
                completion(false)
                return
            }
            self.confirmClosingStates(Array(queue.dropFirst()), completion: completion)
        }
    }

    var hasPendingSaves: Bool {
        states.values.contains(where: \.hasPendingSave)
    }

    func finishTerminationAfterPendingSaves(
        completion: @escaping (Bool) -> Void
    ) {
        waitForPendingSaves { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            confirmClosingAllWindows(completion: completion)
        }
    }

    private func waitForPendingSaves(completion: @escaping () -> Void) {
        guard hasPendingSaves else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForPendingSaves(completion: completion)
        }
    }

    private func waitForPendingReadsAndSaves(completion: @escaping () -> Void) {
        guard hasPendingSaves || states.values.contains(where: \.hasPendingOpen) else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForPendingReadsAndSaves(completion: completion)
        }
    }

    private var hasDirtyDocuments: Bool {
        states.values.contains { state in
            state.documents.contains { $0.isDirty || $0.hasPendingLiveEdits }
        }
    }

    private func presentFirstWorkspaceExitPrompt(
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr("退出并保留当前工作区？")
        alert.informativeText = L10n.tr("所有窗口、标签和未保存内容会在下次启动时恢复。磁盘文件不会被自动修改。")
        alert.addButton(withTitle: L10n.tr("保留并退出"))
        alert.addButton(withTitle: L10n.tr("检查未保存文件"))
        alert.addButton(withTitle: L10n.tr("取消"))
        present(alert) { [weak self] response in
            guard let self else {
                completion(false)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                preferences.confirmWorkspaceExitPrompt()
                preserveWorkspaceAndTerminate(completion: completion)
            case .alertSecondButtonReturn:
                confirmClosingAllWindows(completion: completion)
            default:
                completion(false)
            }
        }
    }

    private func preserveWorkspaceAndTerminate(
        completion: @escaping (Bool) -> Void
    ) {
        terminationApproved = false
        waitForPendingReadsAndSaves { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            guard !states.values.contains(where: \.hasFailedOpeningPlaceholder) else {
                presentWorkspaceSaveError(CocoaError(.fileReadUnknown))
                completion(false)
                return
            }
            let snapshot = captureWorkspaceSnapshot()
            guard let workspaceStore else {
                confirmClosingAllWindows(completion: completion)
                return
            }
            workspaceStore.save(snapshot) { [weak self] result in
                guard let self else {
                    completion(false)
                    return
                }
                switch result {
                case .success:
                    guard !hasPendingSaves,
                          !states.values.contains(where: \.hasPendingOpen),
                          !states.values.contains(where: \.hasFailedOpeningPlaceholder),
                          captureWorkspaceSnapshot() == snapshot else {
                        preserveWorkspaceAndTerminate(completion: completion)
                        return
                    }
                    recoveryStore?.finishCleanlySynchronously()
                    terminationApproved = true
                    completion(true)
                case let .failure(error):
                    presentWorkspaceSaveError(error)
                    completion(false)
                }
            }
        }
    }

    // Preserve the existing on-disk schema: one stored window is one native
    // tab group, with documents in the order AppKit currently displays them.
    func captureWorkspaceSnapshot() -> WorkspaceSessionSnapshot {
        var visited = Set<ObjectIdentifier>()
        var snapshots: [WorkspaceWindowSnapshot] = []
        for window in NSApp.orderedWindows + states.values.compactMap(\.hostWindow) {
            guard states.values.contains(where: { $0.hostWindow === window }),
                  !visited.contains(ObjectIdentifier(window)) else { continue }
            let members = window.tabGroup?.windows ?? [window]
            members.forEach { visited.insert(ObjectIdentifier($0)) }
            guard members.contains(where: { $0.isVisible }) else { continue }
            let groupStates = members.compactMap { member in
                states.values.first { $0.hostWindow === member }
            }
            let selectedWindow = window.tabGroup?.selectedWindow ?? window
            let selectedState = groupStates.first { $0.hostWindow === selectedWindow }
                ?? groupStates.first
            let documents = groupStates.flatMap { state in state.documents.map { document in
                document.refreshDirtyState()
                return WorkspaceDocumentSnapshot(
                    documentID: document.id,
                    text: document.synchronizedText(),
                    sourceURL: document.url,
                    language: document.language,
                    encoding: document.fileEncoding,
                    isDirty: document.isDirty,
                    selectionRange: document.selectionRange,
                    scrollPositionRatio: document.scrollPositionRatio,
                    isPreviewVisible: document.isPreviewVisible,
                    fileRevisionSnapshot: document.fileRevisionSnapshot,
                    folderWorkspace: state.folderWorkspace.sessionState
                )
            } }
            snapshots.append(WorkspaceWindowSnapshot(
                documents: documents,
                selectedDocumentID: selectedState?.selectedDocumentID,
                isSidebarVisible: selectedState?.isSidebarVisible ?? true,
                frame: WorkspaceWindowFrame(
                    x: Double(selectedWindow.frame.origin.x),
                    y: Double(selectedWindow.frame.origin.y),
                    width: Double(selectedWindow.frame.width),
                    height: Double(selectedWindow.frame.height)
                )
            ))
        }
        return WorkspaceSessionSnapshot(windows: snapshots)
    }

    private func presentWorkspaceSaveError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .critical
        alert.messageText = L10n.tr("无法保留工作区")
        alert.informativeText = L10n.tr("工作区没有完整写入，LacEditor 已取消退出。\n\n%@", error.localizedDescription)
        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func finishCleanRecovery(completion: @escaping (Bool) -> Void) {
        guard let recoveryStore else {
            completion(true)
            return
        }
        recoveryStore.finishCleanly { completion(true) }
    }

    private func transferDocument(
        _ documentID: UUID,
        from sourceState: AppState,
        to targetState: AppState,
        before targetDocumentID: UUID?
    ) -> Bool {
        guard sourceState !== targetState,
              let document = sourceState.documents.first(where: {
                  $0.id == documentID
              }),
              let transferred = sourceState.takeDocumentForTransfer(document)
        else {
            return false
        }
        targetState.receiveTransferredDocument(
            transferred,
            before: targetDocumentID
        )
        targetState.hostWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    private func moveDraggedDocument(
        _ documentID: UUID,
        from sourceState: AppState,
        to targetState: AppState,
        before targetDocumentID: UUID?
    ) -> Bool {
        if sourceState === targetState {
            sourceState.moveDocument(
                documentID,
                before: targetDocumentID
            )
            return true
        }
        return transferDocument(
            documentID,
            from: sourceState,
            to: targetState,
            before: targetDocumentID
        )
    }

    private func editorState(at screenPoint: NSPoint) -> AppState? {
        for window in NSApp.orderedWindows
        where window.isVisible && window.frame.contains(screenPoint) {
            if let state = states.values.first(where: {
                $0.hostWindow === window
            }) {
                return state
            }
        }
        return nil
    }

    private func position(_ window: NSWindow, near screenPoint: NSPoint) {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(screenPoint)
        }) ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let desired = NSPoint(
            x: screenPoint.x - min(150, size.width * 0.2),
            y: screenPoint.y - size.height + 28
        )
        window.setFrameOrigin(NSPoint(
            x: min(max(desired.x, visible.minX), visible.maxX - size.width),
            y: min(max(desired.y, visible.minY), visible.maxY - size.height)
        ))
    }

    private func restoreInitialSession(
        workspace: WorkspaceSessionReference?,
        recoverySnapshots: [DocumentRecoveryReference]
    ) {
        var recoveryByID = Dictionary(
            uniqueKeysWithValues: recoverySnapshots.map { ($0.snapshot.documentID, $0) }
        )
        if let workspace, !workspace.windows.isEmpty {
            let restored = workspace.windows.map { window in
                let documents = window.documents.map { snapshot in
                    if let recovery = recoveryByID.removeValue(
                        forKey: snapshot.snapshot.documentID
                    ) {
                        return Self.makeRestorationPlaceholder(from: recovery.snapshot, recovered: true)
                    }
                    return Self.makeRestorationPlaceholder(from: restorationReferences[snapshot.snapshot.documentID]!.snapshot)
                }
                return RestoredWindow(
                    documents: documents,
                    selectedDocumentID: window.selectedDocumentID,
                    isSidebarVisible: window.isSidebarVisible,
                    frame: window.frame,
                    folderStates: Dictionary(window.documents.compactMap { reference in
                        reference.snapshot.folderWorkspace.map { (reference.snapshot.documentID, $0) }
                    }, uniquingKeysWith: { first, _ in first })
                )
            }
            var windows = restored
            if !recoveryByID.isEmpty {
                let extras = recoveryByID.values
                    .sorted { $0.snapshot.capturedAt < $1.snapshot.capturedAt }
                    .map { Self.makeRestorationPlaceholder(from: $0.snapshot, recovered: true) }
                if windows.isEmpty {
                    windows = [RestoredWindow(
                        documents: extras,
                        selectedDocumentID: extras.first?.id,
                        isSidebarVisible: true,
                        frame: nil
                    )]
                } else {
                    let first = windows[0]
                    windows[0] = RestoredWindow(
                        documents: first.documents + extras,
                        selectedDocumentID: first.selectedDocumentID,
                        isSidebarVisible: first.isSidebarVisible,
                        frame: first.frame,
                        folderStates: first.folderStates
                    )
                }
            }
            let selectedIDs = windows.compactMap { window in
                window.documents.first(where: { $0.id == window.selectedDocumentID })?.id
                    ?? window.documents.first?.id
            }
            restorationOrder = selectedIDs + windows.flatMap(\.documents).map(\.id)
                .filter { !selectedIDs.contains($0) }
            initialRestoredWindow = windows.first
            pendingRestoredWindows = Array(windows.dropFirst())
            recoveredDocuments = windows.first?.documents ?? []
            return
        }
        let recovered = recoverySnapshots.map { Self.makeRestorationPlaceholder(from: $0.snapshot, recovered: true) }
        restorationOrder = recovered.map(\.id)
        recoveredDocuments = recovered
        if !recovered.isEmpty {
            initialRestoredWindow = RestoredWindow(
                documents: recovered, selectedDocumentID: recovered.first?.id,
                isSidebarVisible: true, frame: nil
            )
        }
    }

    private static func makeRestorationPlaceholder(from snapshot: DocumentRecoverySnapshot, recovered: Bool = false) -> EditorDocument {
        let document = EditorDocument(id: snapshot.documentID, url: snapshot.sourceURL,
            language: snapshot.language, fileEncoding: snapshot.encoding,
            fileRevisionSnapshot: snapshot.fileRevisionSnapshot, isDirty: snapshot.isDirty,
            requiresExplicitSave: snapshot.isDirty)
        document.ioState = .opening
        if snapshot.isDirty {
            document.statusMessage = recovered
                ? L10n.tr("已从上次异常退出中恢复，请确认后保存")
                : L10n.tr("已恢复上次工作区，尚未保存")
        }
        return document
    }

    func prioritizeRestoration(_ id: UUID) {
        guard restorationLoadingID != nil, restorationOrder.contains(id) else { return }
        restorationOrder.removeAll { $0 == id }
        restorationOrder.insert(id, at: 0)
    }

    func isRestorationPlaceholder(_ document: EditorDocument) -> Bool {
        restorationReferences[document.id] != nil
    }

    func cancelRestoration(_ document: EditorDocument) -> Bool {
        guard restorationReferences.removeValue(forKey: document.id) != nil else { return false }
        restorationOrder.removeAll { $0 == document.id }
        return true
    }

    private func loadNextRestoration() {
        guard restorationLoadingID == nil else { return }
        while let id = restorationOrder.first {
            restorationOrder.removeFirst()
            guard let reference = restorationReferences[id],
                  states.values.contains(where: { $0.documents.contains(where: { $0.id == id }) }) else { continue }
            restorationLoadingID = id
            let readRestoration = self.readRestoration
            restorationQueue.async { [weak self] in
                let result = Result {
                    let snapshot = try readRestoration(reference)
                    return (snapshot, snapshot.text.utf8.count, EditorDocument.countLines(in: snapshot.text))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.restorationLoadingID = nil
                    if self.restorationReferences[id] != nil,
                       let state = self.states.values.first(where: { $0.documents.contains(where: { $0.id == id }) }),
                       let document = state.documents.first(where: { $0.id == id }), document.ioState == .opening {
                        switch result {
                        case let .success((snapshot, byteCount, lineCount)):
                            self.restorationReferences.removeValue(forKey: id)
                            state.finishRestoring(document, snapshot: snapshot, byteCount: byteCount, lineCount: lineCount)
                        case let .failure(error): document.ioState = .failed(error.localizedDescription)
                        }
                    }
                    self.loadNextRestoration()
                }
            }
            return
        }
    }

    private func apply(
        _ restoration: RestoredWindow,
        to state: AppState,
        window: NSWindow
    ) {
        state.isSidebarVisible = restoration.isSidebarVisible
        if let id = restoration.documents.first?.id, let folder = restoration.folderStates[id] {
            state.folderWorkspace.restore(folder)
        }
        applyFrame(restoration.frame, to: window)
        var selectedWindow = window
        var previousWindow = window
        for document in restoration.documents.dropFirst() {
            let tabState = openNewWindow(with: document)
            tabState.isSidebarVisible = restoration.isSidebarVisible
            if let folder = restoration.folderStates[document.id] { tabState.folderWorkspace.restore(folder) }
            guard let tabWindow = tabState.hostWindow else { continue }
            previousWindow.addTabbedWindow(tabWindow, ordered: .above)
            previousWindow = tabWindow
            if document.id == restoration.selectedDocumentID { selectedWindow = tabWindow }
        }
        if let group = window.tabGroup { group.selectedWindow = selectedWindow }
        selectedWindow.makeKeyAndOrderFront(nil)
    }

    private func applyFrame(
        _ storedFrame: WorkspaceWindowFrame?,
        to window: NSWindow
    ) {
        guard let storedFrame else {
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.center()
            return
        }
        var frame = NSRect(
            x: storedFrame.x,
            y: storedFrame.y,
            width: max(900, storedFrame.width),
            height: max(560, storedFrame.height)
        )
        let screen = NSScreen.screens.first(where: {
            $0.visibleFrame.intersects(frame)
        }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }

    private static func makeWorkspaceDocument(
        from snapshot: WorkspaceDocumentSnapshot
    ) -> EditorDocument {
        let document = EditorDocument(
            id: snapshot.documentID,
            text: snapshot.text,
            url: snapshot.sourceURL,
            language: snapshot.language,
            fileEncoding: snapshot.encoding,
            fileRevisionSnapshot: snapshot.fileRevisionSnapshot,
            isDirty: snapshot.isDirty,
            requiresExplicitSave: snapshot.isDirty
        )
        document.selectionRange = snapshot.selectionRange
        document.scrollPositionRatio = snapshot.scrollPositionRatio
        document.isPreviewVisible = snapshot.language == .markdown
            && snapshot.isPreviewVisible
            && document.performanceProfile == .standard
        if snapshot.isDirty {
            document.statusMessage = L10n.tr("已恢复上次工作区，尚未保存")
        }
        return document
    }

    private static func makeRecoveredDocument(
        from snapshot: DocumentRecoverySnapshot
    ) -> EditorDocument {
        let document = EditorDocument(
            id: snapshot.documentID,
            text: snapshot.text,
            url: snapshot.sourceURL,
            language: snapshot.language,
            fileEncoding: snapshot.encoding,
            fileRevisionSnapshot: snapshot.fileRevisionSnapshot,
            isDirty: true,
            requiresExplicitSave: true
        )
        document.selectionRange = snapshot.selectionRange
        document.scrollPositionRatio = snapshot.scrollPositionRatio
        document.isPreviewVisible = snapshot.language == .markdown
            && snapshot.isPreviewVisible
            && document.performanceProfile == .standard
        document.statusMessage = L10n.tr("已从上次异常退出中恢复，请确认后保存")
        return document
    }
}
