import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class FolderWorkspaceInteractionTests: XCTestCase {
    func testMoveFolderChecksOpenRelativeLinkTarget() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("a", isDirectory: true)
        let parent = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("target.md")
        let internalFile = source.appendingPathComponent("inside.md")
        try "external".write(to: external, atomically: true, encoding: .utf8)
        try "internal".write(to: internalFile, atomically: true, encoding: .utf8)
        let link = source.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../target.md")
        let document = EditorDocument(text: "dirty", url: link, language: .markdown, isDirty: true)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        defer { manager.unregister(windowID: id); window.close() }
        let load = try XCTUnwrap(state.folderWorkspace.setRoot(root))
        await load.value
        let destination = parent.appendingPathComponent("a", isDirectory: true)
        let (rejected, _, _) = await manager.moveFolderWorkspaceItem(source, to: destination, root: root, state: state)
        XCTAssertFalse(rejected)
        XCTAssertEqual(document.url, link)
        XCTAssertEqual(document.text, "dirty")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "inside.md")
        document.updateLocation(to: link)
        let (moved, _, _) = await manager.moveFolderWorkspaceItem(source, to: destination, root: root, state: state)
        XCTAssertTrue(moved)
        XCTAssertEqual(document.url, destination.appendingPathComponent("link.md"))
        XCTAssertEqual(document.text, "dirty")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("link.md"), encoding: .utf8), "internal")
    }

    func testMoveRelativeLinkRejectsDifferentTargetForDirtyOpenDocument() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceFolder = root.appendingPathComponent("a", isDirectory: true)
        let destinationFolder = root.appendingPathComponent("b/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.md")
        try "disk".write(to: target, atomically: true, encoding: .utf8)
        let link = sourceFolder.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../target.md")
        let document = EditorDocument(text: "dirty", url: link, language: .markdown, isDirty: true)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        defer { manager.unregister(windowID: id); window.close() }
        let load = try XCTUnwrap(state.folderWorkspace.setRoot(root))
        await load.value
        let destination = destinationFolder.appendingPathComponent("link.md")
        let (moved, _, _) = await manager.moveFolderWorkspaceItem(link, to: destination, root: root, state: state)
        XCTAssertFalse(moved)
        XCTAssertEqual(document.url, link)
        XCTAssertEqual(document.text, "dirty")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../target.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTrashLinkClosesLinkDocumentButNotTargetDocument() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = root.appendingPathComponent("target.md")
        let link = root.appendingPathComponent("link.md")
        try "target".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkDocument = EditorDocument(text: "target", url: link, language: .markdown)
        let targetDocument = EditorDocument(text: "target", url: target, language: .markdown)
        let manager = WindowManager()
        let owner = AppState(initialDocument: linkDocument, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let targetState = AppState(initialDocument: targetDocument, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        let firstID = UUID(), secondID = UUID()
        manager.register(windowID: firstID, state: owner, window: firstWindow)
        manager.register(windowID: secondID, state: targetState, window: secondWindow)
        defer { manager.unregister(windowID: secondID); manager.unregister(windowID: firstID); secondWindow.close(); firstWindow.close() }
        let load = try XCTUnwrap(owner.folderWorkspace.setRoot(root))
        await load.value
        let service = FileService()
        let identity = try service.workspaceNodeIdentity(link)
        let fakeTrash = base.appendingPathComponent("trashed-link")
        let (trashed, returnedURL, returnedIdentity, changes) = await manager.trashFolderWorkspaceItem(link, root: root, state: owner, expectedIdentity: identity) { source, _, _ in
            try FileManager.default.moveItem(at: source, to: fakeTrash)
            return fakeTrash
        }
        XCTAssertTrue(trashed)
        XCTAssertFalse(owner.documents.contains { $0 === linkDocument })
        XCTAssertTrue(targetState.documents.contains { $0 === targetDocument })
        XCTAssertEqual(targetDocument.url, target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target")
        let restored = await manager.restoreFolderWorkspaceTrash(try XCTUnwrap(returnedURL), to: link, root: root, state: owner, expectedIdentity: try XCTUnwrap(returnedIdentity), changes: try XCTUnwrap(changes))
        XCTAssertTrue(restored)
        XCTAssertTrue(targetState.documents.contains { $0 === targetDocument })
    }

    func testMoveRejectsDanglingOpenAliasAndRenamesLinkRecentPath() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let target = root.appendingPathComponent("target.md")
        try "target".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let document = EditorDocument(text: "dirty", url: link, language: .markdown, isDirty: true)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = WindowManager(recentFiles: RecentFilesStore(defaults: defaults), sidebarLibrary: SidebarLibraryStore(storageURL: base.appendingPathComponent("library.json")))
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let targetDocument = EditorDocument(text: "target", url: target, language: .markdown)
        let targetState = AppState(initialDocument: targetDocument, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let targetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        targetWindow.isReleasedWhenClosed = false
        let id = UUID(), targetID = UUID()
        manager.register(windowID: id, state: state, window: window)
        manager.register(windowID: targetID, state: targetState, window: targetWindow)
        defer { manager.unregister(windowID: targetID); manager.unregister(windowID: id); targetWindow.close(); window.close() }
        let load = try XCTUnwrap(state.folderWorkspace.setRoot(root))
        await load.value
        try FileManager.default.removeItem(at: target)
        let source = root.appendingPathComponent("other.md")
        try "other".write(to: source, atomically: true, encoding: .utf8)
        let (blocked, _, _) = await manager.moveFolderWorkspaceItem(source, to: target, root: root, state: state)
        XCTAssertFalse(blocked)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "other")

        manager.recentFiles.record(link)
        let renamed = root.appendingPathComponent("renamed.md")
        let (moved, identity, lists) = await manager.moveFolderWorkspaceItem(link, to: renamed, root: root, state: state)
        XCTAssertTrue(moved)
        XCTAssertTrue(manager.recentFiles.urls.contains(renamed))
        XCTAssertEqual(document.url, renamed)
        XCTAssertEqual(targetDocument.url, target)
        XCTAssertEqual(document.text, "dirty")
        XCTAssertTrue(document.isDirty)
        let (undone, _, _) = await manager.moveFolderWorkspaceItem(renamed, to: link, root: root, state: state, expectedIdentity: try XCTUnwrap(identity), updateLists: false)
        XCTAssertTrue(undone)
        manager.restoreMovedFolderWorkspaceLists(try XCTUnwrap(lists), source: link, destination: renamed)
        XCTAssertTrue(manager.recentFiles.urls.contains(link))
        XCTAssertEqual(document.url, link)
        XCTAssertEqual(targetDocument.url, target)
        XCTAssertEqual(document.text, "dirty")
    }

    func testTrashClosesOpenDocumentAndUndoRestoresFileWithoutReopening() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("file.md")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let service = FileService()
        let document = EditorDocument(text: "disk", url: file, language: .markdown, fileRevisionSnapshot: try FileRevisionSnapshot.capture(file))
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = WindowManager(recentFiles: RecentFilesStore(defaults: defaults), sidebarLibrary: SidebarLibraryStore(storageURL: root.appendingPathComponent("library.json")))
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        defer { manager.unregister(windowID: id); window.close() }
        let load = try XCTUnwrap(state.folderWorkspace.setRoot(root))
        await load.value
        let identity = try service.workspaceNodeIdentity(file)
        let fakeTrash = base.appendingPathComponent("trash.md")
        let (trashed, returnedURL, returnedIdentity, lists) = await manager.trashFolderWorkspaceItem(file, root: root, state: state, expectedIdentity: identity) { source, _, _ in
            try FileManager.default.moveItem(at: source, to: fakeTrash)
            return fakeTrash
        }
        XCTAssertTrue(trashed)
        XCTAssertFalse(state.documents.contains { $0 === document })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let restored = await manager.restoreFolderWorkspaceTrash(try XCTUnwrap(returnedURL), to: file, root: root, state: state, expectedIdentity: try XCTUnwrap(returnedIdentity), changes: try XCTUnwrap(lists))
        XCTAssertTrue(restored)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disk")
        XCTAssertFalse(state.documents.contains { $0 === document })
    }

    func testMoveAndUndoPreserveOpenDocumentsAndExternalConflict() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("file.md")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let baseline = try FileRevisionSnapshot.capture(file)
        let document = EditorDocument(text: "dirty", url: file, language: .markdown, fileRevisionSnapshot: baseline, isDirty: true)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = WindowManager(recentFiles: RecentFilesStore(defaults: defaults), sidebarLibrary: SidebarLibraryStore(storageURL: root.appendingPathComponent("library.json")))
        let owner = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let opened = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        let firstID = UUID(), secondID = UUID()
        manager.register(windowID: firstID, state: owner, window: firstWindow)
        manager.register(windowID: secondID, state: opened, window: secondWindow)
        defer { manager.unregister(windowID: secondID); manager.unregister(windowID: firstID); secondWindow.close(); firstWindow.close() }
        let load = try XCTUnwrap(owner.folderWorkspace.setRoot(root))
        await load.value
        manager.sidebarLibrary.toggleFavorite(file)
        let groupID = try XCTUnwrap(manager.sidebarLibrary.createGroup(named: UUID().uuidString))
        manager.sidebarLibrary.add(file, toGroup: groupID)
        manager.recentFiles.record(file)
        let removed = root.appendingPathComponent("removed.md")
        try "remove".write(to: removed, atomically: true, encoding: .utf8)
        manager.sidebarLibrary.toggleFavorite(removed)
        manager.sidebarLibrary.add(removed, toGroup: groupID)
        manager.recentFiles.record(removed)
        try "external change".write(to: file, atomically: true, encoding: .utf8)
        manager.recentFiles.recordFolder(folder)
        manager.sidebarLibrary.togglePinnedFolder(folder)
        let destination = root.appendingPathComponent("new", isDirectory: true)
        let (moved, identity, lists) = await manager.moveFolderWorkspaceItem(folder, to: destination, root: root, state: owner)
        XCTAssertTrue(moved)
        XCTAssertEqual(manager.recentFiles.folderURLs.map(\.path), [destination.resolvingSymlinksInPath().path])
        XCTAssertEqual(manager.sidebarLibrary.pinnedFolderPaths, [destination.resolvingSymlinksInPath().path])
        XCTAssertEqual(document.url, destination.appendingPathComponent("file.md"))
        XCTAssertEqual(document.text, "dirty")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.fileRevisionSnapshot, baseline)
        let newIdentity = try XCTUnwrap(identity)
        let laterFolder = root.appendingPathComponent("later", isDirectory: true)
        try FileManager.default.createDirectory(at: laterFolder, withIntermediateDirectories: true)
        manager.recentFiles.recordFolder(laterFolder)
        manager.sidebarLibrary.togglePinnedFolder(laterFolder)
        let unrelated = root.appendingPathComponent("unrelated.md")
        try "other".write(to: unrelated, atomically: true, encoding: .utf8)
        manager.sidebarLibrary.toggleFavorite(unrelated)
        manager.sidebarLibrary.add(unrelated, toGroup: groupID)
        manager.recentFiles.record(unrelated)
        manager.sidebarLibrary.toggleFavorite(removed)
        manager.sidebarLibrary.remove(removed, fromGroup: groupID)
        manager.recentFiles.remove(removed)
        let (restored, _, _) = await manager.moveFolderWorkspaceItem(destination, to: folder, root: root, state: owner, expectedIdentity: newIdentity, updateLists: false)
        XCTAssertTrue(restored)
        manager.restoreMovedFolderWorkspaceLists(try XCTUnwrap(lists), source: folder, destination: destination)
        XCTAssertEqual(manager.recentFiles.folderURLs.map(\.path), [laterFolder.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path])
        XCTAssertTrue(manager.sidebarLibrary.isPinnedFolder(folder))
        XCTAssertTrue(manager.sidebarLibrary.isPinnedFolder(laterFolder))
        XCTAssertTrue(manager.sidebarLibrary.isFavorite(file))
        XCTAssertTrue(manager.sidebarLibrary.isFavorite(unrelated))
        XCTAssertTrue(manager.sidebarLibrary.groups.first(where: { $0.id == groupID })?.urls.contains(file) == true)
        XCTAssertTrue(manager.sidebarLibrary.groups.first(where: { $0.id == groupID })?.urls.contains(unrelated) == true)
        XCTAssertTrue(manager.recentFiles.urls.contains(file))
        XCTAssertTrue(manager.recentFiles.urls.contains(unrelated))
        XCTAssertFalse(manager.sidebarLibrary.isFavorite(removed))
        XCTAssertFalse(manager.sidebarLibrary.groups.first(where: { $0.id == groupID })?.urls.contains(removed) == true)
        XCTAssertFalse(manager.recentFiles.urls.contains(removed))
        XCTAssertEqual(document.url, file)
        XCTAssertEqual(document.text, "dirty")
        XCTAssertEqual(document.fileRevisionSnapshot, baseline)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external change")
    }

    func testUndoFolderItemsRejectsOpenAliasesAcrossWindows() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = FileService()
        let created = try service.createWorkspaceItem(named: "created.md", in: root, root: root, isDirectory: false)
        let createdSnapshot = try service.workspaceItemSnapshot(created)
        let hardlink = base.appendingPathComponent("hardlink.md")
        try FileManager.default.linkItem(at: created, to: hardlink)
        let folder = try service.createWorkspaceItem(named: "copy", in: root, root: root, isDirectory: true)
        let child = folder.appendingPathComponent("child.md")
        try "child".write(to: child, atomically: true, encoding: .utf8)
        let folderSnapshot = try service.workspaceItemSnapshot(folder)
        let symlink = base.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: child)

        let manager = WindowManager()
        let owner = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let opened = AppState(initialDocument: EditorDocument(text: "", url: hardlink, language: .markdown), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        let firstID = UUID(), secondID = UUID()
        manager.register(windowID: firstID, state: owner, window: firstWindow)
        manager.register(windowID: secondID, state: opened, window: secondWindow)
        defer { manager.unregister(windowID: secondID); manager.unregister(windowID: firstID); secondWindow.close(); firstWindow.close() }
        let load = try XCTUnwrap(owner.folderWorkspace.setRoot(root))
        await load.value
        let removedCreated = await owner.undoFolderWorkspaceItem(created, root: root, snapshot: createdSnapshot, isCreated: true)
        XCTAssertFalse(removedCreated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        opened.selectedDocument?.updateLocation(to: symlink)
        let removedFolder = await owner.undoFolderWorkspaceItem(folder, root: root, snapshot: folderSnapshot, isCreated: false)
        XCTAssertFalse(removedFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        let other = try service.copyWorkspaceItem(folder, named: "other", root: root)
        let otherSnapshot = try service.workspaceItemSnapshot(other)
        let otherAlias = base.appendingPathComponent("other-hardlink.md")
        try FileManager.default.linkItem(at: other.appendingPathComponent("child.md"), to: otherAlias)
        let started = expectation(description: "background removal started")
        let release = DispatchSemaphore(value: 0)
        let undo = Task {
            await owner.undoFolderWorkspaceItem(other, root: root, snapshot: otherSnapshot, isCreated: false) { url, root, snapshot in
                started.fulfill()
                release.wait()
                try service.removeCopiedWorkspaceItem(url, root: root, snapshot: snapshot)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        manager.openFile(other.appendingPathComponent("child.md"), preferredState: owner)
        XCTAssertEqual(owner.selectedDocument?.statusMessage, L10n.tr("文件操作进行中，请稍后重试"))
        XCTAssertFalse(manager.openDocumentURLs.contains(other.appendingPathComponent("child.md")))
        manager.openFile(otherAlias, preferredState: owner)
        XCTAssertFalse(manager.openDocumentURLs.contains(otherAlias))
        release.signal()
        let removedOther = await undo.value
        XCTAssertTrue(removedOther)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testClosingLastCleanDocumentForFolderKeepsWindowRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.md")
        try "saved".write(to: url, atomically: true, encoding: .utf8)
        let document = EditorDocument(text: "saved", url: url, language: .markdown, isDirty: false)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let load = try XCTUnwrap(state.folderWorkspace.setRoot(root))
        await load.value
        let done = expectation(description: "closed")
        state.closeForFolderOperation(document) { approved in
            XCTAssertTrue(approved)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(state.documents.contains { $0 === document })
        XCTAssertEqual(state.folderWorkspace.rootURL, root)
    }

    func testVisibleRowsFollowExpandedDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nestedFile = child.appendingPathComponent("inside.md")
        try "nested".write(to: nestedFile, atomically: true, encoding: .utf8)
        try "root".write(to: root.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)

        let store = FolderWorkspaceStore()
        let rootTask = try XCTUnwrap(store.setRoot(root))
        await rootTask.value
        XCTAssertEqual(FolderWorkspaceVisibleRow.rows(in: store).map(\.depth), [0, 0])

        let childTask = try XCTUnwrap(store.expand(child))
        await childTask.value
        let expanded = FolderWorkspaceVisibleRow.rows(in: store)
        XCTAssertEqual(expanded.map(\.depth), [0, 1, 0])
        guard expanded.count == 3, case let .entry(entry) = expanded[1].content else {
            return XCTFail("Expected the nested file in the expanded directory")
        }
        XCTAssertEqual(entry.url, nestedFile)

        store.collapse(child)
        XCTAssertEqual(FolderWorkspaceVisibleRow.rows(in: store).map(\.depth), [0, 0])
    }

    func testRootsBelongToIndividualWindowStatesAndReset() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstRoot = base.appendingPathComponent("first", isDirectory: true)
        let secondRoot = base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = WindowManager()
        let first = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let second = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let firstTask = try XCTUnwrap(first.folderWorkspace.setRoot(firstRoot))
        let secondTask = try XCTUnwrap(second.folderWorkspace.setRoot(secondRoot))
        await firstTask.value
        await secondTask.value
        XCTAssertEqual(first.folderWorkspace.rootURL, firstRoot)
        XCTAssertEqual(second.folderWorkspace.rootURL, secondRoot)
        first.resetClosedWindow()
        XCTAssertNil(first.folderWorkspace.rootURL)
        XCTAssertEqual(second.folderWorkspace.rootURL, secondRoot)
        second.closeAuxiliaryWindows()
        XCTAssertNil(second.folderWorkspace.rootURL)
    }

    func testFolderFileOpenUsesExistingDocumentAcrossWindows() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("source.md")
        let link = base.appendingPathComponent("alias.md")
        try "saved".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let document = EditorDocument(text: "unsaved", url: file, language: .markdown, isDirty: true)
        let manager = WindowManager()
        let first = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let second = AppState(initialDocument: EditorDocument(), recentFiles: manager.recentFiles, preferences: manager.preferences)
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        let firstID = UUID(), secondID = UUID()
        manager.register(windowID: firstID, state: first, window: firstWindow)
        manager.register(windowID: secondID, state: second, window: secondWindow)
        defer {
            manager.unregister(windowID: secondID)
            manager.unregister(windowID: firstID)
            secondWindow.close()
            firstWindow.close()
        }
        second.openFile(link)
        XCTAssertTrue(first.selectedDocument === document)
        XCTAssertEqual(document.text, "unsaved")
        XCTAssertTrue(document.isDirty)
        XCTAssertFalse(second.documents.contains { $0 === document })
        XCTAssertEqual(manager.openDocumentURLs.filter { DocumentFileIdentity.resolve($0).matches(DocumentFileIdentity.resolve(file)) }.count, 1)
    }
}
