import AppKit
import Foundation
import XCTest
@testable import LacEditor

final class ProgressiveRestorationTests: XCTestCase {
    func testMetadataAndCopiedContentsSurviveAnotherCrash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceSessionStore(rootURL: root.appendingPathComponent("workspace"))
        let recoveryURL = root.appendingPathComponent("recovery")
        let ids = [UUID(), UUID()]
        let documents = zip(ids, [false, true]).map { id, dirty in
            WorkspaceDocumentSnapshot(documentID: id, text: "中文🙂 \(id)", sourceURL: nil,
                language: .plainText, encoding: .utf8, isDirty: dirty,
                selectionRange: NSRange(location: 2, length: 1), scrollPositionRatio: 0.5,
                isPreviewVisible: false, fileRevisionSnapshot: nil)
        }
        try workspace.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: documents, selectedDocumentID: ids[1], isSidebarVisible: true, frame: nil)]))
        let references = try XCTUnwrap(workspace.loadReferences())
        XCTAssertEqual(references.windows[0].selectedDocumentID, ids[1])
        XCTAssertEqual(references.windows[0].documents.map(\.snapshot.text), ["", ""])
        let first = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertTrue(try first.startSessionReferences().isEmpty)
        let copies = try first.copyForWorkspaceHandoff(references.windows[0].documents)
        XCTAssertEqual(copies.map(\.snapshot.isDirty), [false, true])
        try workspace.consume()
        let second = DocumentRecoveryStore(rootURL: recoveryURL)
        let recovered = try second.startSessionReferences()
        let byID = Dictionary(uniqueKeysWithValues: recovered.map { ($0.snapshot.documentID, $0) })
        for document in documents {
            let value = try DocumentRecoveryStore.read(XCTUnwrap(byID[document.documentID]))
            XCTAssertEqual(value.text, document.text)
            XCTAssertEqual(value.isDirty, document.isDirty)
            XCTAssertEqual(value.selectionRange, document.selectionRange)
        }
    }

    @MainActor
    func testNewerCrashSnapshotTakesPriorityOverCleanWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceSessionStore(rootURL: root.appendingPathComponent("workspace"))
        let recoveryURL = root.appendingPathComponent("recovery")
        let id = UUID()
        let clean = WorkspaceDocumentSnapshot(documentID: id, text: "old", sourceURL: nil,
            language: .plainText, encoding: .utf8, isDirty: false,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil)
        try workspace.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: [clean], selectedDocumentID: id, isSidebarVisible: true, frame: nil)]))
        let previous = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try previous.startSession()
        previous.persist(DocumentRecoverySnapshot(documentID: id, text: "new", sourceURL: nil,
            language: .plainText, encoding: .utf8, revision: 3,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil, capturedAt: Date()))
        previous.flushForTesting()
        let manager = WindowManager(recoveryStore: DocumentRecoveryStore(rootURL: recoveryURL),
            workspaceStore: workspace)
        let placeholder = try XCTUnwrap(manager.takeRecoveredDocuments().first)
        XCTAssertEqual(placeholder.id, id)
        XCTAssertTrue(placeholder.isDirty)
        XCTAssertEqual(placeholder.ioState, .opening)
        XCTAssertNil(try workspace.loadReferences())
        let afterCrash = DocumentRecoveryStore(rootURL: recoveryURL)
        let recovered = try XCTUnwrap(afterCrash.startSession().first)
        XCTAssertEqual(recovered.text, "new")
        XCTAssertTrue(recovered.isDirty)
    }

    func testOlderRecoveryMetadataDefaultsToDirty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DocumentRecoveryStore(rootURL: root)
        _ = try store.startSessionReferences()
        store.persist(DocumentRecoverySnapshot(documentID: UUID(), text: "draft", sourceURL: nil,
            language: .plainText, encoding: .utf8, revision: 1,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil, capturedAt: Date()))
        store.flushForTesting()
        let session = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("Session-") })
        let metadata = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: session,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        object.removeValue(forKey: "isDirty")
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        let next = DocumentRecoveryStore(rootURL: root)
        let snapshot = try XCTUnwrap(next.startSession().first)
        XCTAssertTrue(snapshot.isDirty)
        XCTAssertEqual(snapshot.text, "draft")
    }

    @MainActor
    func testPendingNilURLCanTransferAndCancelWithoutWritingEmptyRecovery() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceSessionStore(rootURL: root.appendingPathComponent("workspace"))
        let recoveryURL = root.appendingPathComponent("recovery")
        let id = UUID()
        let draft = WorkspaceDocumentSnapshot(documentID: id, text: "unsaved", sourceURL: nil,
            language: .plainText, encoding: .utf8, isDirty: true,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil)
        try workspace.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: [draft], selectedDocumentID: id, isSidebarVisible: true, frame: nil)]))
        let recovery = DocumentRecoveryStore(rootURL: recoveryURL)
        let manager = WindowManager(recoveryStore: recovery, workspaceStore: workspace)
        let document = try XCTUnwrap(manager.takeRecoveredDocuments().first)
        let source = AppState(initialDocument: document, recentFiles: manager.recentFiles,
            preferences: manager.preferences, recoveryStore: recovery)
        let destination = AppState(recentFiles: manager.recentFiles,
            preferences: manager.preferences, recoveryStore: recovery)
        source.windowManager = manager
        destination.windowManager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        destination.hostWindow = window
        window.orderFront(nil)
        defer { window.delegate = nil; window.close() }
        XCTAssertTrue(source.canTransferDocument(document))
        XCTAssertTrue(source.takeDocumentForTransfer(document) === document)
        destination.receiveTransferredDocument(document)
        XCTAssertTrue(destination.isOpeningPlaceholder(document))
        XCTAssertFalse(destination.saveAs(document))
        recovery.flushForTesting()
        let session = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: recoveryURL,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("Session-") })
        let content = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: session,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "utf8" })
        XCTAssertEqual(try String(contentsOf: content, encoding: .utf8), "unsaved")
        destination.cancelOpening(document)
        let cancelSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(cancelSheet, returnCode: .alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(100))
        recovery.flushForTesting()
        XCTAssertTrue(destination.documents.contains { $0 === document })
        XCTAssertTrue(manager.isRestorationPlaceholder(document))
        XCTAssertEqual(try String(contentsOf: content, encoding: .utf8), "unsaved")

        destination.cancelOpening(document)
        let discardSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(discardSheet, returnCode: .alertFirstButtonReturn)
        for _ in 0..<100 where manager.isRestorationPlaceholder(document) {
            try await Task.sleep(for: .milliseconds(20))
        }
        recovery.flushForTesting()
        XCTAssertFalse(destination.documents.contains { $0 === document })
        XCTAssertFalse(manager.isRestorationPlaceholder(document))
        XCTAssertTrue(try DocumentRecoveryStore(rootURL: recoveryURL).startSession().isEmpty)
    }

    @MainActor
    func testSelectedPendingDocumentMovesAheadInSerialQueue() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceSessionStore(rootURL: root)
        let ids = [UUID(), UUID(), UUID()]
        let documents = ids.map { id in WorkspaceDocumentSnapshot(documentID: id, text: id.uuidString,
            sourceURL: nil, language: .plainText, encoding: .utf8, isDirty: false,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil) }
        try workspace.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: documents, selectedDocumentID: ids[0], isSidebarVisible: true, frame: nil)]))
        let control = RestorationReadControl()
        defer { control.resume.signal() }
        let manager = WindowManager(workspaceStore: workspace, readRestoration: { try control.read($0) })
        let restored = manager.takeRecoveredDocuments()
        let state = AppState(initialDocument: restored[0], recentFiles: manager.recentFiles,
            preferences: manager.preferences)
        let selection = AppState(initialDocuments: restored, recentFiles: manager.recentFiles,
            preferences: manager.preferences)
        selection.windowManager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.register(windowID: UUID(), state: state, window: window)
        defer {
            for member in window.tabGroup?.windows ?? [window] { member.delegate = nil; member.close() }
        }
        for _ in 0..<100 where control.order.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(control.order, [ids[0]])
        selection.selectedDocumentID = ids[2]
        control.resume.signal()
        for _ in 0..<100 where control.order.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(control.order, [ids[0], ids[2], ids[1]])
    }

    @MainActor
    func testFailedRestorationStaysProtected() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceSessionStore(rootURL: root)
        let id = UUID()
        let draft = WorkspaceDocumentSnapshot(documentID: id, text: "draft", sourceURL: nil,
            language: .plainText, encoding: .utf8, isDirty: true,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil)
        try workspace.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: [draft], selectedDocumentID: id, isSidebarVisible: true, frame: nil)]))
        let suite = "LacEditorRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.workspaceExitBehavior = .preserveWorkspace
        preferences.confirmWorkspaceExitPrompt()
        let manager = WindowManager(workspaceStore: workspace, preferences: preferences, readRestoration: { _ in
            throw CocoaError(.fileReadUnknown)
        })
        let document = try XCTUnwrap(manager.takeRecoveredDocuments().first)
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles,
            preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        manager.register(windowID: UUID(), state: state, window: window)
        defer { window.delegate = nil; window.close() }
        for _ in 0..<100 where document.ioState == .opening { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(state.hasFailedOpeningPlaceholder)
        XCTAssertTrue(state.isOpeningPlaceholder(document))
        XCTAssertFalse(state.canTransferDocument(document))
        XCTAssertFalse(state.save(document))
        XCTAssertFalse(state.saveAs(document))
        XCTAssertEqual(document.text, "")
        var terminationResult: Bool?
        manager.requestApplicationTermination { terminationResult = $0 }
        XCTAssertEqual(terminationResult, false)
        XCTAssertFalse(manager.terminationApproved)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        XCTAssertTrue(manager.isRestorationPlaceholder(document))
    }

    func testMissingContentFailsBeforeWorkspaceIsConsumed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceSessionStore(rootURL: root.appendingPathComponent("workspace"))
        let id = UUID()
        let document = WorkspaceDocumentSnapshot(documentID: id, text: "draft", sourceURL: nil,
            language: .plainText, encoding: .utf8, isDirty: true,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil)
        try workspace.saveForTesting(WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: [document], selectedDocumentID: id, isSidebarVisible: true, frame: nil)]))
        let reference = try XCTUnwrap(workspace.loadReferences()?.windows.first?.documents.first)
        try FileManager.default.removeItem(at: reference.contentURL)
        let recovery = DocumentRecoveryStore(rootURL: root.appendingPathComponent("recovery"))
        _ = try recovery.startSessionReferences()
        XCTAssertThrowsError(try recovery.copyForWorkspaceHandoff([reference]))
        XCTAssertNotNil(try workspace.loadReferences())
    }
}

private final class RestorationReadControl: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values: [UUID] = []

    func read(_ reference: DocumentRecoveryReference) throws -> DocumentRecoverySnapshot {
        lock.lock()
        values.append(reference.snapshot.documentID)
        let first = values.count == 1
        lock.unlock()
        if first { started.signal(); resume.wait() }
        return try DocumentRecoveryStore.read(reference)
    }

    var order: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
