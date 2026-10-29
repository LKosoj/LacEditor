import AppKit
import Combine
import XCTest
@testable import LacEditor

@MainActor
final class FolderOpeningTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @MainActor
    private struct Fixture {
        let manager: WindowManager
        let state: AppState
        let window: NSWindow
        let windowID: UUID
        let defaults: UserDefaults
        let suite: String

        func close() {
            state.closeAuxiliaryWindows()
            state.documents.forEach { $0.cancelMetricsRefresh() }
            manager.unregister(windowID: windowID)
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func fixture(document: EditorDocument = EditorDocument(), workspaceStore: WorkspaceSessionStore? = nil,
                         beforeRegistration: (WindowManager) -> Void = { _ in },
                         configureState: (AppState) -> Void = { _ in }) throws -> Fixture {
        _ = NSApplication.shared
        let suite = "LacEditorTests.FolderOpening.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = WindowManager(workspaceStore: workspaceStore, preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults))
        let initialDocument = manager.takeRecoveredDocuments().first ?? document
        let state = AppState(initialDocument: initialDocument, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = UUID()
        manager.preparePrimaryWindow(windowID: id, state: state)
        beforeRegistration(manager)
        configureState(state)
        manager.register(windowID: id, state: state, window: window)
        return Fixture(manager: manager, state: state, window: window, windowID: id, defaults: defaults, suite: suite)
    }

    func testCommandLinePathsPreserveOrderAndStopAtUnknownOptions() {
        let base = URL(fileURLWithPath: "/tmp/CLI 中", isDirectory: true)
        let paths = WindowManager.commandLineURLs(arguments: ["-psn_0_123", "a b.md", "../目录/", "--", "-note.md"], workingDirectory: base)
        XCTAssertEqual(paths.map(\.path), ["/tmp/CLI 中/a b.md", "/tmp/目录", "/tmp/CLI 中/-note.md"])
        XCTAssertTrue(paths[1].hasDirectoryPath)
        XCTAssertEqual(WindowManager.commandLineURLs(arguments: ["first.md", "-AppleLanguages", "(ru)", "other.md"], workingDirectory: base).map(\.lastPathComponent), ["first.md"])
    }

    func testCommandLineFolderOutranksDefaultAndDoesNotReplaceDirtyText() async throws {
        let root = try temporaryFolder(), other = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let document = EditorDocument(text: "unsaved 中😀", language: .markdown, isDirty: true)
        let fixture = try fixture(document: document, beforeRegistration: {
            $0.preferences.startupFolderPath = root.path
            $0.openFilesFromCommandLine([other])
        })
        defer { fixture.close() }
        for _ in 0..<200 where fixture.state.folderWorkspace.rootURL == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, other.resolvingSymlinksInPath().path)
        XCTAssertTrue(fixture.state.selectedDocument === document)
        XCTAssertEqual(document.synchronizedText(), "unsaved 中😀")
        XCTAssertTrue(document.isDirty)
    }

    func testQueuedCommandLineCreationIsDeduplicatedWithFinderAndDoesNotOverwrite() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("created 中.md")
        var confirmations = 0
        let fixture = try fixture(beforeRegistration: {
            $0.preferences.startupFolderPath = root.path
            $0.openFilesFromCommandLine([target], confirm: { url in
                confirmations += 1
                try? "concurrent contents".write(to: url, atomically: true, encoding: .utf8)
                return .file
            })
            $0.openFilesFromFinder([target])
        })
        defer { fixture.close() }
        for _ in 0..<200 where fixture.state.documents.allSatisfy({ $0.url != target || $0.ioState != .idle }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "concurrent contents")
        XCTAssertEqual(fixture.state.documents.filter { $0.url == target }.count, 1)
    }

    func testCommandLineCreatesOnlyConfirmedTargetAndRequiresExistingParent() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture()
        defer { fixture.close() }
        let file = root.appendingPathComponent("new.md")
        fixture.manager.openFilesFromCommandLine([file], confirm: { _ in .file })
        XCTAssertEqual(try Data(contentsOf: file), Data())
        let directory = root.appendingPathComponent("new folder", isDirectory: true)
        fixture.manager.openFilesFromCommandLine([directory], confirm: { _ in .directory })
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let missingParent = root.appendingPathComponent("missing/child.md")
        fixture.manager.openFilesFromCommandLine([missingParent], confirm: { _ in .file })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let throughAlias = alias.appendingPathComponent("through alias.md")
        fixture.manager.openFilesFromCommandLine([throughAlias], confirm: { _ in .file })
        XCTAssertEqual(try Data(contentsOf: throughAlias), Data())
    }

    func testCommandLineCancelAndChangedWindowDoNotCreateAnything() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = EditorDocument(text: "keep dirty", language: .markdown, isDirty: true)
        let fixture = try fixture(document: document)
        defer { fixture.close() }
        let target = root.appendingPathComponent("cancel.md")
        fixture.manager.openFilesFromCommandLine([target], confirm: { _ in nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        fixture.manager.openFilesFromCommandLine([target], confirm: { _ in
            fixture.state.hostWindow = nil
            return .file
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(document.synchronizedText(), "keep dirty")
        XCTAssertTrue(document.isDirty)
    }

    func testCommandLineDoesNotReplaceRestoredDirtyFileOrFolder() async throws {
        let root = try temporaryFolder(), other = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let file = root.appendingPathComponent("restored.md")
        try "on disk".write(to: file, atomically: true, encoding: .utf8)
        let store = WorkspaceSessionStore(rootURL: root.appendingPathComponent("workspace", isDirectory: true))
        let id = UUID()
        let folder = FolderWorkspaceSession(rootPath: root.path, expandedPaths: [], sort: "natural", view: "tree", currentPath: [])
        let document = WorkspaceDocumentSnapshot(documentID: id, text: "restored unsaved 中😀", sourceURL: file, language: .markdown,
            encoding: .utf8, isDirty: true, selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil, folderWorkspace: folder)
        try store.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(documents: [document],
            selectedDocumentID: id, isSidebarVisible: true, frame: nil)]))
        let fixture = try fixture(workspaceStore: store, beforeRegistration: {
            $0.preferences.startupFolderPath = other.path
            $0.openFilesFromCommandLine([file])
        })
        defer { fixture.close() }
        let drained = expectation(description: "queued CLI request was processed")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        for _ in 0..<200 where fixture.state.selectedDocument?.ioState != .idle { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.state.selectedDocument?.ioState, .idle)
        XCTAssertEqual(fixture.state.documents.filter { $0.id == id }.count, 1)
        XCTAssertEqual(fixture.state.selectedDocument?.synchronizedText(), "restored unsaved 中😀")
        XCTAssertEqual(fixture.state.selectedDocument?.isDirty, true)
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, root.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "on disk")
    }

    func testStartupFolderAppliesOnceAndDoesNotChangeDirtyDocument() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = EditorDocument(text: "unsaved 中😀", language: .markdown, isDirty: true)
        let fixture = try fixture(document: document, beforeRegistration: { $0.preferences.startupFolderPath = root.path })
        defer { fixture.close() }
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(fixture.manager.recentFiles.folderURLs.first?.path, root.resolvingSymlinksInPath().path)
        XCTAssertTrue(fixture.state.selectedDocument === document)
        XCTAssertEqual(document.synchronizedText(), "unsaved 中😀")
        XCTAssertTrue(document.isDirty)
        fixture.state.folderWorkspace.setRoot(nil)
        fixture.manager.reopenPrimaryWindow()
        XCTAssertNil(fixture.state.folderWorkspace.rootURL)
    }

    func testExistingFolderAndEarlyFinderFolderTakePriorityOverStartupDefault() async throws {
        let root = try temporaryFolder(), other = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let existing = try fixture(beforeRegistration: { $0.preferences.startupFolderPath = root.path },
            configureState: { $0.folderWorkspace.setRoot(other) })
        XCTAssertEqual(existing.state.folderWorkspace.rootURL?.path, other.path)
        XCTAssertTrue(existing.manager.recentFiles.folderURLs.isEmpty)
        existing.close()
        let queued = try fixture(beforeRegistration: {
            $0.preferences.startupFolderPath = root.path
            $0.openFilesFromFinder([other])
        })
        defer { queued.close() }
        XCTAssertNil(queued.state.folderWorkspace.rootURL)
        let opened = expectation(description: "queued folder outranks default")
        let subscription = queued.state.folderWorkspace.$rootURL.sink { url in
            if url?.path == other.resolvingSymlinksInPath().path { opened.fulfill() }
        }
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(queued.manager.recentFiles.folderURLs.map(\.path), [other.resolvingSymlinksInPath().path])
        withExtendedLifetime(subscription) {}
    }

    func testEarlyFinderFileSkipsDefaultAndLateFolderUsesNormalOpening() async throws {
        let root = try temporaryFolder(), parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("file.md")
        try "file".write(to: file, atomically: true, encoding: .utf8)
        let fixture = try fixture(beforeRegistration: {
            $0.preferences.startupFolderPath = root.path
            $0.openFilesFromFinder([file])
        })
        defer { fixture.close() }
        XCTAssertNil(fixture.state.folderWorkspace.rootURL)
        let opened = expectation(description: "queued file opens without default folder")
        let subscription = fixture.state.$selectedDocumentID.sink { id in
            if fixture.state.documents.first(where: { $0.id == id })?.url == file { opened.fulfill() }
        }
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, parent.path)
        XCTAssertTrue(fixture.manager.recentFiles.folderURLs.isEmpty)
        fixture.manager.openFilesFromFinder([root])
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(fixture.state.selectedDocument?.url, file)
        withExtendedLifetime(subscription) {}
    }

    func testRestoredFolderIsNotReplacedByStartupDefault() throws {
        let root = try temporaryFolder(), other = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let store = WorkspaceSessionStore(rootURL: root.appendingPathComponent("workspace", isDirectory: true))
        let id = UUID()
        let folder = FolderWorkspaceSession(rootPath: root.path, expandedPaths: [], sort: "natural", view: "tree", currentPath: [])
        let document = WorkspaceDocumentSnapshot(documentID: id, text: "restored", sourceURL: nil, language: .markdown,
            encoding: .utf8, isDirty: false, selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil, folderWorkspace: folder)
        try store.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(documents: [document],
            selectedDocumentID: id, isSidebarVisible: true, frame: nil)]))
        let fixture = try fixture(workspaceStore: store, beforeRegistration: { $0.preferences.startupFolderPath = other.path })
        defer { fixture.close() }
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, root.path)
        XCTAssertEqual(fixture.state.selectedDocument?.id, id)
        XCTAssertTrue(fixture.manager.recentFiles.folderURLs.isEmpty)
    }

    func testMissingStartupFolderDoesNotCreateDirectoryOrReplaceDocument() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let document = EditorDocument(text: "dirty", isDirty: true)
        let fixture = try fixture(document: document, beforeRegistration: { $0.preferences.startupFolderPath = missing.path })
        defer { fixture.close() }
        XCTAssertNil(fixture.state.folderWorkspace.rootURL)
        XCTAssertTrue(fixture.state.selectedDocument === document)
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(fixture.manager.recentFiles.folderURLs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(AppPreferences(defaults: fixture.defaults).startupFolderPath, missing.path)
    }

    func testFinderFolderKeepsDocumentAndDirtyText() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = EditorDocument(text: "unsaved 中😀", language: .markdown, isDirty: true)
        let fixture = try fixture(document: document)
        defer { fixture.close() }
        XCTAssertEqual(fixture.manager.preferences.startupFolderPath, "")
        fixture.manager.openFilesFromFinder([root])
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(fixture.state.documents.map(\.id), [document.id])
        XCTAssertEqual(document.synchronizedText(), "unsaved 中😀")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.ioState, .idle)
    }

    func testEarlyFinderFolderDrainsAfterWindowRegistration() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try fixture(beforeRegistration: { $0.openFilesFromFinder([root]) })
        defer { fixture.close() }
        let opened = expectation(description: "queued folder opened")
        let subscription = fixture.state.folderWorkspace.$rootURL.sink { url in
            if url?.path == root.resolvingSymlinksInPath().path { opened.fulfill() }
        }
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(fixture.state.documents.count, 1)
        XCTAssertNil(fixture.state.selectedDocument?.url)
        XCTAssertEqual(fixture.state.selectedDocument?.ioState, .idle)
        withExtendedLifetime(subscription) {}
    }

    func testNewFileGetsParentAndExplicitRootIsPreserved() throws {
        let parent = try temporaryFolder(), explicit = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: explicit) }
        let file = parent.appendingPathComponent("file.md")
        try "# Text".write(to: file, atomically: true, encoding: .utf8)
        for root in [nil, explicit] as [URL?] {
            let fixture = try fixture()
            defer { fixture.close() }
            fixture.state.folderWorkspace.setRoot(root)
            let opened = try XCTUnwrap(fixture.manager.openFile(file, preferredState: fixture.state))
            XCTAssertTrue(opened.state === fixture.state)
            XCTAssertEqual(opened.state.folderWorkspace.rootURL?.path, (root ?? parent).path)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Text")
        }
    }

    func testAlreadyOpenAliasKeepsRootAndFinderURLOrder() throws {
        let root = try temporaryFolder(), other = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let file = root.appendingPathComponent("file.md"), alias = root.appendingPathComponent("alias.md")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let document = EditorDocument(text: "unsaved", url: file, language: .markdown, isDirty: true)
        let fixture = try fixture(document: document)
        defer { fixture.close() }
        fixture.state.folderWorkspace.setRoot(other.resolvingSymlinksInPath())
        let opened = try XCTUnwrap(fixture.manager.openFile(alias, preferredState: fixture.state))
        XCTAssertTrue(opened.document === document)
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, other.resolvingSymlinksInPath().path)
        XCTAssertEqual(document.synchronizedText(), "unsaved")
        fixture.manager.openFilesFromFinder([root, other])
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, other.resolvingSymlinksInPath().path)
        XCTAssertEqual(fixture.state.documents.map(\.id), [document.id])
    }
    func testQueuedFolderThenFileKeepsExplicitFolder() async throws {
        let root = try temporaryFolder(), parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("file.md")
        try "# Other folder".write(to: file, atomically: true, encoding: .utf8)
        let fixture = try fixture(beforeRegistration: { $0.openFilesFromFinder([root, file]) })
        defer { fixture.close() }
        let opened = expectation(description: "queued file follows folder")
        let subscription = fixture.state.$selectedDocumentID.sink { id in
            if fixture.state.documents.first(where: { $0.id == id })?.url == file { opened.fulfill() }
        }
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(fixture.state.folderWorkspace.rootURL?.path, root.resolvingSymlinksInPath().path)
        XCTAssertEqual(fixture.state.selectedDocument?.url, file)
        XCTAssertEqual(fixture.state.documents.count, 1)
        withExtendedLifetime(subscription) {}
    }

    func testCancelledExtremeFileDoesNotSetParentFolder() throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("extreme.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 51 * 1024 * 1024)
        try handle.close()
        let fixture = try fixture()
        defer { fixture.close() }
        let original = try XCTUnwrap(fixture.state.selectedDocument)
        var sawConfirmation = false
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let alertWindow = NSApp.modalWindow {
                    sawConfirmation = true
                    NSApp.stopModal(withCode: .alertSecondButtonReturn)
                    alertWindow.orderOut(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let opened = fixture.manager.openFile(file, preferredState: fixture.state)
        XCTAssertTrue(sawConfirmation)
        XCTAssertNil(opened)
        XCTAssertNil(fixture.state.folderWorkspace.rootURL)
        XCTAssertTrue(fixture.state.selectedDocument === original)
        XCTAssertEqual(original.ioState, .idle)
    }

}
