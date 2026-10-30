import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LacEditor

private func semaphoreIsSignaled(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now()) == .success)
        }
    }
}

@MainActor
final class WindowAndSessionTests: XCTestCase {
    func testWorkspaceFolderMetadataAndLegacyManifestCompatibility() throws {
        struct OldManifest: Decodable {
            struct Window: Decodable {
                struct Document: Decodable { let documentID: UUID; let contentFileName: String }
                let documents: [Document]
            }
            let version: Int
            let windows: [Window]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceSessionStore(rootURL: directory)
        let id = UUID()
        let folder = FolderWorkspaceSession(rootPath: "/tmp/example", expandedPaths: [["child"]], sort: "modified", view: "list", currentPath: ["child"])
        let document = WorkspaceDocumentSnapshot(documentID: id, text: "dirty", sourceURL: nil, language: .markdown,
            encoding: .utf8, isDirty: true, selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil, folderWorkspace: folder)
        let snapshot = WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(documents: [document], selectedDocumentID: id, isSidebarVisible: true, frame: nil)])
        try store.saveForTesting(snapshot)
        XCTAssertEqual(try store.load()?.windows.first?.documents.first?.folderWorkspace, folder)
        let workspace = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("Workspace-") })
        let manifest = workspace.appendingPathComponent("Manifest.json")
        let data = try Data(contentsOf: manifest)
        let oldReader = try JSONDecoder().decode(OldManifest.self, from: data)
        XCTAssertEqual(oldReader.version, 1)
        XCTAssertEqual(oldReader.windows.first?.documents.first?.documentID, id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
        var documents = try XCTUnwrap(windows[0]["documents"] as? [[String: Any]])
        documents[0].removeValue(forKey: "folderWorkspace")
        windows[0]["documents"] = documents
        json["windows"] = windows
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let legacy = try XCTUnwrap(store.load()?.windows.first?.documents.first)
        XCTAssertNil(legacy.folderWorkspace)
        XCTAssertEqual(legacy.text, "dirty")
    }

    func testWorkspaceExitWaitsForOpeningBeforeTakingSnapshot() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LacEditorWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let store = WorkspaceSessionStore(rootURL: directory)
        let manager = WindowManager(
            workspaceStore: store, preferences: preferences,
            recentFiles: RecentFilesStore(defaults: defaults)
        )
        let document = EditorDocument(text: "loading")
        document.ioState = .opening
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences)
        let window = makeWindow(title: "Opening")
        let windowID = UUID()
        manager.register(windowID: windowID, state: state, window: window)
        window.orderFront(nil)
        defer { manager.unregister(windowID: windowID); window.close() }
        var result: Bool?
        manager.requestApplicationTermination { result = $0 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(result)
        XCTAssertNil(try store.load())
        document.text = "finished"
        document.ioState = .idle
        for _ in 0..<100 where result == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(result, true)
        XCTAssertEqual(try store.load()?.windows.first?.documents.first?.text, "finished")
    }

    func testWorkspaceExitRetriesWhenDocumentChangesDuringSave() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LacEditorWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let fileManager = PausedWorkspaceFileManager()
        defer { fileManager.resume.signal() }
        let store = WorkspaceSessionStore(rootURL: directory, fileManager: fileManager)
        let manager = WindowManager(
            workspaceStore: store, preferences: preferences,
            recentFiles: RecentFilesStore(defaults: defaults)
        )
        let document = EditorDocument(text: "before")
        let readStarted = DispatchSemaphore(value: 0)
        let resumeRead = DispatchSemaphore(value: 0)
        defer { resumeRead.signal() }
        let state = AppState(
            initialDocument: document, recentFiles: manager.recentFiles, preferences: preferences,
            readFile: { url in
                let prepared = try FileService.prepareRead(url)
                readStarted.signal()
                resumeRead.wait()
                return prepared
            }
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "opened".write(to: url, atomically: true, encoding: .utf8)
        let window = makeWindow(title: "Save in progress")
        let windowID = UUID()
        manager.register(windowID: windowID, state: state, window: window)
        window.orderFront(nil)
        defer { manager.unregister(windowID: windowID); window.close() }
        var result: Bool?
        manager.requestApplicationTermination { result = $0 }
        var saveStarted = false
        for _ in 0..<100 {
            if await semaphoreIsSignaled(fileManager.started) { saveStarted = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(saveStarted)
        document.text = "after"
        state.beginOpeningFile(url)
        var didStartRead = false
        for _ in 0..<100 {
            if await semaphoreIsSignaled(readStarted) { didStartRead = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(didStartRead)
        fileManager.resume.signal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(result)
        resumeRead.signal()
        for _ in 0..<100 where result == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(result, true)
        XCTAssertEqual(try store.load()?.windows.first?.documents.map(\.text), ["after", "opened"])
    }

    func testWorkspaceExitRejectsFailedOpeningPlaceholder() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unreadable.txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        let suiteName = "LacEditorWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let store = WorkspaceSessionStore(rootURL: directory.appendingPathComponent("workspace"))
        let manager = WindowManager(
            workspaceStore: store, preferences: preferences,
            recentFiles: RecentFilesStore(defaults: defaults)
        )
        let state = AppState(recentFiles: manager.recentFiles, preferences: preferences, readFile: { _ in
            throw CocoaError(.fileReadUnknown)
        })
        let window = makeWindow(title: "Failed opening")
        let windowID = UUID()
        manager.register(windowID: windowID, state: state, window: window)
        window.orderFront(nil)
        defer { manager.unregister(windowID: windowID); window.close() }
        var modalTimedOut = false
        let dismissModal = Task { @MainActor in
            for _ in 0..<100 {
                if let modal = NSApp.modalWindow {
                    NSApp.stopModal()
                    modal.orderOut(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
            modalTimedOut = true
            if let document = state.selectedDocument { state.cancelOpening(document) }
        }
        defer { dismissModal.cancel() }
        state.beginOpeningFile(url)
        await dismissModal.value
        for _ in 0..<150 where state.hasPendingOpen { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(modalTimedOut, "Opening error dialog did not appear")
        XCTAssertTrue(state.hasFailedOpeningPlaceholder)
        _ = try XCTUnwrap(state.selectedDocument)
        XCTAssertFalse(state.save())
        var result: Bool?
        manager.requestApplicationTermination { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertNil(try store.load())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testRepeatedActivationDoesNotPublishOrReplaceWorkspaceSubscription() {
        _ = NSApplication.shared
        let manager = WindowManager()
        let state = makeState(document: EditorDocument(text: "kept"))
        let window = makeWindow(title: "Activation")
        let windowID = UUID()
        defer { window.close() }
        manager.register(windowID: windowID, state: state, window: window)
        var updates = 0
        let observation = manager.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }
        for _ in 0..<100 {
            manager.register(windowID: windowID, state: state, window: window)
            manager.activate(windowID: windowID)
        }
        XCTAssertEqual(updates, 0)
        state.selectedDocumentID = nil
        XCTAssertGreaterThan(updates, 0, "The selected workspace must still forward changes")
    }

    func testFullHeightSidebarAndTabAccessorySurviveResizeAndNativeCollapse() async throws {
        _ = NSApplication.shared
        let manager = WindowManager()
        let state = makeState(document: EditorDocument(text: "first"))
        let originalVisibility = state.isSidebarVisible
        state.isSidebarVisible = true
        state.newDocument()
        let windowID = UUID()
        let window = makeWindow(title: "Chrome regression")
        window.contentViewController = NSHostingController(rootView: EditorWindowRoot(
            appState: state, windowManager: manager, windowID: windowID
        ))
        defer {
            state.isSidebarVisible = originalVisibility
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))

        func findSplit(_ view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               controller.splitViewItems.first?.behavior == .sidebar { return controller }
            return view.subviews.lazy.compactMap(findSplit).first
        }
        let contentView = try XCTUnwrap(window.contentView)
        let split = try XCTUnwrap(findSplit(contentView))
        let sidebar = split.splitViewItems[0]
        let accessories = split.splitViewItems[1].topAlignedAccessoryViewControllers
        XCTAssertEqual(accessories.count, 1)
        XCTAssertTrue(accessories.first?.isHidden == true)
        for size in [NSSize(width: 900, height: 560), NSSize(width: 1120, height: 720)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(100))
            contentView.layoutSubtreeIfNeeded()
            XCTAssertEqual(split.view.convert(split.view.bounds, to: nil).maxY,
                           contentView.convert(contentView.bounds, to: nil).maxY, accuracy: 1,
                           "The split view must reach behind the titlebar")
            XCTAssertGreaterThan(split.splitViewItems[1].viewController.view.visibleRect.width, 200)
        }
        state.presentFindReplace(mode: .find)
        XCTAssertFalse(accessories.first?.isHidden ?? true)
        state.dismissFindReplace()
        XCTAssertTrue(accessories.first?.isHidden == true)
        sidebar.isCollapsed = true // Same entry point as AppKit's toolbar button.
        XCTAssertFalse(state.isSidebarVisible)
        state.newDocument()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sidebar.isCollapsed, "Document updates must not reopen the sidebar")
        state.toggleSidebar()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(sidebar.isCollapsed)
    }

    func testPrimaryWindowSessionCanRebindAfterCloseAndReopen() {
        _ = NSApplication.shared
        let manager = WindowManager()
        let state = makeState(document: EditorDocument(text: "kept"))
        let windowID = UUID()
        let firstWindow = makeWindow(title: "Primary")
        manager.register(windowID: windowID, state: state, window: firstWindow)

        manager.unregister(windowID: windowID)
        XCTAssertTrue(manager.activeState === state)

        let reopenedWindow = makeWindow(title: "Primary Reopened")
        defer {
            manager.unregister(windowID: windowID)
            firstWindow.close()
            reopenedWindow.close()
        }
        manager.register(windowID: windowID, state: state, window: reopenedWindow)

        XCTAssertTrue(manager.activeState === state)
        XCTAssertTrue(state.hostWindow === reopenedWindow)
        XCTAssertTrue(state.selectedDocument?.isDisposableBlank == true)
    }

    func testPreservedWorkspaceRestoresTabOrderAndDirtyState() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "LacEditorWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.confirmWorkspaceExitPrompt()
        let workspaceStore = WorkspaceSessionStore(
            rootURL: directory.appendingPathComponent("Workspace")
        )
        let manager = WindowManager(
            workspaceStore: workspaceStore,
            preferences: preferences
        )
        let first = EditorDocument(
            text: "draft",
            language: .markdown,
            isDirty: true,
            requiresExplicitSave: true
        )
        let second = EditorDocument(text: #"{"z":1,"a":2}"#, language: .json)
        let state = AppState(
            initialDocuments: [first, second],
            recentFiles: manager.recentFiles,
            preferences: preferences
        )
        var acknowledgedRevision: UInt?
        first.attachLiveTextProvider(
            id: UUID(),
            provider: { "latest draft" },
            acknowledgement: { acknowledgedRevision = $0 }
        )
        first.noteLiveEdit(isEmpty: false)
        XCTAssertEqual(first.text, "draft")
        state.selectedDocumentID = second.id
        state.isSidebarVisible = false
        let window = makeWindow(title: "Workspace")
        let windowID = UUID()
        manager.register(windowID: windowID, state: state, window: window)

        window.orderFront(nil)

        let shouldTerminate = await withCheckedContinuation { continuation in
            manager.requestApplicationTermination {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(shouldTerminate)
        XCTAssertEqual(acknowledgedRevision, first.textRevision)
        manager.unregister(windowID: windowID)
        window.close()

        let restoredManager = WindowManager(
            workspaceStore: workspaceStore,
            preferences: preferences
        )
        let restored = restoredManager.takeRecoveredDocuments()
        XCTAssertEqual(restored.map(\.id), [first.id, second.id])
        let restoredState = AppState(initialDocuments: Array(restored.prefix(1)),
            recentFiles: restoredManager.recentFiles, preferences: preferences)
        let restoredWindow = makeWindow(title: "Restored")
        let restoredWindowID = UUID()
        restoredManager.register(windowID: restoredWindowID, state: restoredState, window: restoredWindow)
        defer {
            for member in restoredWindow.tabGroup?.windows ?? [restoredWindow] {
                member.delegate = nil
                member.close()
            }
        }
        for _ in 0..<100 where restored.contains(where: { $0.ioState == .opening }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(restored.map(\.text), ["latest draft", #"{"z":1,"a":2}"#])
        XCTAssertNil(restored[0].url)
        XCTAssertTrue(restored[0].isDirty)
        XCTAssertFalse(restored[1].isDirty)
        XCTAssertEqual(restored[0].statusMessage, L10n.tr("已恢复上次工作区，尚未保存"))
    }

    func testRealWindowsRegisterSetsHostWindow() {
        _ = NSApplication.shared
        let manager = WindowManager()
        let sourceDocument = EditorDocument(text: "source")
        let targetDocument = EditorDocument(text: "target")
        let sourceState = makeState(document: sourceDocument)
        let targetState = makeState(document: targetDocument)
        let sourceWindow = makeWindow(title: "Source")
        let targetWindow = makeWindow(title: "Target")
        let sourceWindowID = UUID()
        let targetWindowID = UUID()
        defer {
            manager.unregister(windowID: sourceWindowID)
            manager.unregister(windowID: targetWindowID)
            sourceWindow.close()
            targetWindow.close()
        }

        manager.register(
            windowID: sourceWindowID,
            state: sourceState,
            window: sourceWindow
        )
        manager.register(
            windowID: targetWindowID,
            state: targetState,
            window: targetWindow
        )

        XCTAssertTrue(sourceState.hostWindow === sourceWindow)
        XCTAssertTrue(targetState.hostWindow === targetWindow)
    }

    func testEditorSessionCacheUsesLRUAndReturnsRealScrollView() {
        let store = EditorSessionStore(
            limit: 2,
            inactiveMemoryBudget: .max,
            maximumCacheableSessionCost: .max
        )
        let first = EditorDocument(text: "first")
        let second = EditorDocument(text: "second")
        let third = EditorDocument(text: "third")

        let firstView = makeEditorScrollView(text: first.text)
        store.store(
            firstView,
            coordinator: store.coordinator(for: first),
            for: first.id
        )
        store.store(
            makeEditorScrollView(text: second.text),
            coordinator: store.coordinator(for: second),
            for: second.id
        )
        XCTAssertTrue(store.cachedView(for: first.id) === firstView)

        store.store(
            makeEditorScrollView(text: third.text),
            coordinator: store.coordinator(for: third),
            for: third.id
        )

        XCTAssertEqual(store.snapshot.documentIDs, [first.id, third.id])
        XCTAssertFalse(store.snapshot.documentIDs.contains(second.id))
    }

    func testCacheBudgetRejectsOversizedInactiveSession() {
        let store = EditorSessionStore(
            limit: 3,
            inactiveMemoryBudget: 8_000,
            maximumCacheableSessionCost: 4_000
        )
        let document = EditorDocument(text: String(repeating: "x", count: 2_000))
        let coordinator = store.coordinator(for: document)
        store.store(
            makeEditorScrollView(text: document.text),
            coordinator: coordinator,
            for: document.id
        )

        XCTAssertFalse(store.snapshot.documentIDs.contains(document.id))
        XCTAssertEqual(store.snapshot.inactiveMemoryCost, 0)
    }

    func testCriticalMemoryPressureKeepsActiveSessionAndEvictsInactiveSessions() {
        let store = EditorSessionStore(
            limit: 3,
            inactiveMemoryBudget: .max,
            maximumCacheableSessionCost: .max
        )
        let activeDocument = EditorDocument(text: "active")
        let inactiveDocument = EditorDocument(text: "inactive")
        let activeCoordinator = store.coordinator(for: activeDocument)
        store.store(
            makeEditorScrollView(text: activeDocument.text),
            coordinator: activeCoordinator,
            for: activeDocument.id
        )
        activeCoordinator.updateActivity(true)
        store.store(
            makeEditorScrollView(text: inactiveDocument.text),
            coordinator: store.coordinator(for: inactiveDocument),
            for: inactiveDocument.id
        )

        store.processMemoryPressure(.critical)

        XCTAssertEqual(store.snapshot.documentIDs, [activeDocument.id])
        XCTAssertTrue(store.snapshot.inactiveDocumentIDs.isEmpty)
        activeCoordinator.updateActivity(false)
    }

    private func makeState(document: EditorDocument) -> AppState {
        AppState(
            initialDocument: document,
            recentFiles: RecentFilesStore(),
            preferences: AppPreferences()
        )
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeEditorScrollView(text: String) -> NSScrollView {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 420)
        )
        let textView = LacTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 420)
        )
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }
}

private final class PausedWorkspaceFileManager: FileManager, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private var hasPaused = false

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if url.lastPathComponent.hasPrefix("Workspace-"), !hasPaused {
            hasPaused = true
            started.signal()
            resume.wait()
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
