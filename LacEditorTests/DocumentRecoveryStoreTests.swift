import Foundation
import XCTest
@testable import LacEditor

final class DocumentRecoveryStoreTests: XCTestCase {
    func testWorkspaceSessionRoundTripPreservesWindowsTabsAndContent() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceSessionStore(
            rootURL: directory.appendingPathComponent("Workspace")
        )
        let firstID = UUID()
        let secondID = UUID()
        let snapshot = WorkspaceSessionSnapshot(windows: [
            WorkspaceWindowSnapshot(
                documents: [
                    WorkspaceDocumentSnapshot(
                        documentID: firstID,
                        text: "未保存内容",
                        sourceURL: nil,
                        language: .markdown,
                        encoding: .utf8,
                        isDirty: true,
                        selectionRange: NSRange(location: 3, length: 2),
                        scrollPositionRatio: 0.4,
                        isPreviewVisible: true,
                        fileRevisionSnapshot: nil
                    ),
                    WorkspaceDocumentSnapshot(
                        documentID: secondID,
                        text: #"{"z":1,"a":2}"#,
                        sourceURL: directory.appendingPathComponent("config.json"),
                        language: .json,
                        encoding: .utf8,
                        isDirty: false,
                        selectionRange: NSRange(location: 5, length: 0),
                        scrollPositionRatio: 0.8,
                        isPreviewVisible: false,
                        fileRevisionSnapshot: nil
                    )
                ],
                selectedDocumentID: secondID,
                isSidebarVisible: false,
                frame: WorkspaceWindowFrame(
                    x: 120,
                    y: 160,
                    width: 1_100,
                    height: 720
                )
            ),
            WorkspaceWindowSnapshot(
                documents: [WorkspaceDocumentSnapshot(
                    documentID: UUID(),
                    text: "second window",
                    sourceURL: nil,
                    language: .plainText,
                    encoding: .utf8,
                    isDirty: true,
                    selectionRange: NSRange(location: 2, length: 0),
                    scrollPositionRatio: 0.2,
                    isPreviewVisible: false,
                    fileRevisionSnapshot: nil
                )],
                selectedDocumentID: nil,
                isSidebarVisible: true,
                frame: nil
            )
        ])

        try store.saveForTesting(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try store.load(), snapshot)
        try store.consume()
        XCTAssertNil(try store.load())
    }

    func testWorkspaceHandoffSurvivesCrashAndDiscardDoesNotRestoreDocument() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceSessionStore(rootURL: directory.appendingPathComponent("Workspace"))
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let documentID = UUID()
        let document = WorkspaceDocumentSnapshot(
            documentID: documentID, text: "unsaved", sourceURL: nil,
            language: .markdown, encoding: .utf8, isDirty: true,
            selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
            isPreviewVisible: false, fileRevisionSnapshot: nil
        )
        let snapshot = WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: [document], selectedDocumentID: documentID,
            isSidebarVisible: true, frame: nil
        )])
        try workspace.saveForTesting(snapshot)
        let recovery = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertTrue(try recovery.startSession().isEmpty)
        XCTAssertEqual(try workspace.load(), snapshot)
        try recovery.persistForWorkspaceHandoff([makeSnapshot(documentID: documentID, text: "unsaved", revision: 1)])
        XCTAssertEqual(try workspace.load(), snapshot)
        try workspace.consume()
        XCTAssertNil(try workspace.load())

        let afterCrash = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertEqual(try afterCrash.startSession().first?.text, "unsaved")
        afterCrash.discard(documentID: documentID)
        afterCrash.flushForTesting()
        let afterCloseAndCrash = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertTrue(try afterCloseAndCrash.startSession().isEmpty)
        afterCloseAndCrash.finishCleanlyForTesting()
    }

    func testWorkspaceHandoffFailsWithoutActiveRecoverySession() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = DocumentRecoveryStore(rootURL: directory.appendingPathComponent("Recovery"))
        XCTAssertThrowsError(try recovery.persistForWorkspaceHandoff([makeSnapshot(text: "unsaved", revision: 1)]))
    }

    func testWorkspaceConsumeFailureKeepsSnapshot() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FailingRecoveryFileManager()
        let workspace = WorkspaceSessionStore(rootURL: directory, fileManager: fileManager)
        let snapshot = WorkspaceSessionSnapshot(windows: [])
        try workspace.saveForTesting(snapshot)
        fileManager.failRemoval = directory.appendingPathComponent("CurrentWorkspace.json")
        XCTAssertThrowsError(try workspace.consume())
        XCTAssertEqual(try workspace.load(), snapshot)
    }

    func testAbnormalSessionRestoresLatestAtomicSnapshot() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("draft.md")
        try Data("disk version".utf8).write(to: sourceURL)
        let baseline = try FileRevisionSnapshot.capture(sourceURL)
        let documentID = UUID()

        let interruptedStore = DocumentRecoveryStore(rootURL: directory.appendingPathComponent("Recovery"))
        XCTAssertTrue(try interruptedStore.startSession().isEmpty)
        interruptedStore.persist(makeSnapshot(
            documentID: documentID,
            text: "first recovery",
            revision: 1,
            sourceURL: sourceURL,
            baseline: baseline
        ))
        interruptedStore.persist(makeSnapshot(
            documentID: documentID,
            text: "latest recovery",
            revision: 2,
            sourceURL: sourceURL,
            baseline: baseline
        ))
        interruptedStore.flushForTesting()

        let relaunchedStore = DocumentRecoveryStore(rootURL: directory.appendingPathComponent("Recovery"))
        let recovered = try relaunchedStore.startSession()
        let snapshot = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(snapshot.documentID, documentID)
        XCTAssertEqual(snapshot.text, "latest recovery")
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.sourceURL, sourceURL)
        XCTAssertEqual(snapshot.fileRevisionSnapshot, baseline)
        relaunchedStore.finishCleanlyForTesting()
    }

    func testCleanTerminationDoesNotOfferRecovery() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let store = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try store.startSession()
        store.persist(makeSnapshot(text: "temporary", revision: 1))
        store.flushForTesting()
        store.finishCleanlyForTesting()

        let nextLaunch = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertTrue(try nextLaunch.startSession().isEmpty)
        nextLaunch.finishCleanlyForTesting()
    }

    func testDiscardRemovesOnlyTargetDocument() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let store = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try store.startSession()
        let discardedID = UUID()
        let retainedID = UUID()
        store.persist(makeSnapshot(documentID: discardedID, text: "discard", revision: 1))
        store.persist(makeSnapshot(documentID: retainedID, text: "retain", revision: 1))
        store.discard(documentID: discardedID)
        store.flushForTesting()

        let nextLaunch = DocumentRecoveryStore(rootURL: recoveryURL)
        let recovered = try nextLaunch.startSession()
        XCTAssertEqual(recovered.map(\.documentID), [retainedID])
        nextLaunch.finishCleanlyForTesting()
    }

    func testFailedSessionCopyKeepsPreviousSessionAndCanRetry() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let original = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try original.startSession()
        let documentID = UUID()
        original.persist(makeSnapshot(documentID: documentID, text: "original", revision: 1))
        original.flushForTesting()

        let fileManager = FailingRecoveryFileManager()
        fileManager.failOnSessionDirectoryCall = 2
        let retrying = DocumentRecoveryStore(rootURL: recoveryURL, fileManager: fileManager)
        XCTAssertThrowsError(try retrying.startSession())
        retrying.persist(makeSnapshot(documentID: documentID, text: "must not persist", revision: 2))
        retrying.flushForTesting()
        fileManager.failOnSessionDirectoryCall = nil
        XCTAssertEqual(try retrying.startSession().first?.text, "original")
        retrying.finishCleanlyForTesting()
    }

    func testUnreadableRecoverySnapshotKeepsPreviousSession() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let original = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try original.startSession()
        original.persist(makeSnapshot(text: "original", revision: 1))
        original.flushForTesting()
        let markerURL = recoveryURL.appendingPathComponent("ActiveSession.json")
        let marker = try Data(contentsOf: markerURL)
        let sessionURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: recoveryURL, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("Session-") })
        let metadataURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: sessionURL, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        let metadata = try Data(contentsOf: metadataURL)
        try Data("invalid".utf8).write(to: metadataURL)

        let retrying = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertThrowsError(try retrying.startSession())
        XCTAssertEqual(try Data(contentsOf: markerURL), marker)
        try metadata.write(to: metadataURL)
        XCTAssertEqual(try retrying.startSession().first?.text, "original")
        retrying.finishCleanlyForTesting()
    }

    func testFailedSessionDirectoryKeepsPreviousSession() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let original = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try original.startSession()
        original.persist(makeSnapshot(text: "original", revision: 1))
        original.flushForTesting()

        let fileManager = FailingRecoveryFileManager()
        fileManager.failOnSessionDirectoryCall = 1
        let retrying = DocumentRecoveryStore(rootURL: recoveryURL, fileManager: fileManager)
        XCTAssertThrowsError(try retrying.startSession())
        fileManager.failOnSessionDirectoryCall = nil
        XCTAssertEqual(try retrying.startSession().first?.text, "original")
        retrying.finishCleanlyForTesting()
    }

    func testFailedMarkerWriteDoesNotActivateSessionAndCanRetry() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        let markerURL = recoveryURL.appendingPathComponent("ActiveSession.json")
        // Install an obstruction after startSession reads the absent marker.
        let fileManager = FailingRecoveryFileManager()
        fileManager.obstructMarker = markerURL
        let retrying = DocumentRecoveryStore(rootURL: recoveryURL, fileManager: fileManager)
        XCTAssertThrowsError(try retrying.startSession())
        retrying.persist(makeSnapshot(text: "must not persist", revision: 1))
        retrying.flushForTesting()
        try FileManager.default.removeItem(at: markerURL)
        fileManager.obstructMarker = nil
        XCTAssertTrue(try retrying.startSession().isEmpty)
        retrying.persist(makeSnapshot(text: "persisted after retry", revision: 2))
        retrying.flushForTesting()
        let relaunched = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertEqual(try relaunched.startSession().first?.text, "persisted after retry")
        relaunched.finishCleanlyForTesting()
        retrying.finishCleanlyForTesting()
    }

    @MainActor
    func testWindowManagerBuildsDirtyDocumentThatRequiresExplicitSave() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let interruptedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try interruptedStore.startSession()
        let documentID = UUID()
        interruptedStore.persist(makeSnapshot(
            documentID: documentID,
            text: "unsaved text",
            revision: 7
        ))
        interruptedStore.flushForTesting()

        let relaunchedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        let manager = WindowManager(recoveryStore: relaunchedStore)
        let document = try XCTUnwrap(manager.takeRecoveredDocuments().first)
        XCTAssertEqual(document.id, documentID)
        XCTAssertEqual(document.text, "unsaved text")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.statusMessage, L10n.tr("已从上次异常退出中恢复，请确认后保存"))

        document.refreshDirtyState()
        XCTAssertTrue(document.isDirty)
        document.markSaved()
        XCTAssertFalse(document.isDirty)
        relaunchedStore.finishCleanlyForTesting()
    }

    @MainActor
    func testAppStatePersistsDirtyDocumentWhenAppResignsActive() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let interruptedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try interruptedStore.startSession()
        let suiteName = "LacEditorRecoveryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            recentFiles: RecentFilesStore(),
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: interruptedStore
        )
        let document = try XCTUnwrap(state.selectedDocument)
        var acknowledgedRevision: UInt?
        document.attachLiveTextProvider(
            id: UUID(),
            provider: { "typed immediately before losing focus" },
            acknowledgement: { acknowledgedRevision = $0 }
        )
        document.noteLiveEdit(isEmpty: false)
        XCTAssertEqual(document.text, "")
        state.persistRecoverySnapshotsImmediately()
        try await Task.sleep(for: .milliseconds(50))
        interruptedStore.flushForTesting()

        let relaunchedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        let recovered = try relaunchedStore.startSession()
        XCTAssertEqual(recovered.first?.documentID, document.id)
        XCTAssertEqual(recovered.first?.text, "typed immediately before losing focus")
        XCTAssertNil(recovered.first?.sourceURL)
        XCTAssertEqual(recovered.first?.revision, document.textRevision)
        XCTAssertEqual(acknowledgedRevision, document.textRevision)
        XCTAssertEqual(recovered.first?.isDirty, true)
        relaunchedStore.finishCleanlyForTesting()
    }

    func testPersistCompletionReportsWrittenOnMainThread() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRecoveryStore(rootURL: directory.appendingPathComponent("Recovery"))
        _ = try store.startSession()
        let done = expectation(description: "persist")
        store.persist(makeSnapshot(text: "text", revision: 1)) { result in
            XCTAssertEqual(result, .written)
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        store.finishCleanlyForTesting()
    }

    func testPersistCompletionReportsNoSessionWithoutWriting() {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let store = DocumentRecoveryStore(rootURL: recoveryURL)
        let done = expectation(description: "persist")
        store.persist(makeSnapshot(text: "text", revision: 1)) { result in
            XCTAssertEqual(result, .noSession)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        var values: [Int] { lock.withLock { stored } }
        func append(_ value: Int) { lock.withLock { stored.append(value) } }
    }

    func testCompletionOrderFollowsPersistOrder() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentRecoveryStore(rootURL: directory.appendingPathComponent("Recovery"))
        _ = try store.startSession()
        let documentID = UUID()
        let order = OrderRecorder()
        let done = expectation(description: "persist")
        done.expectedFulfillmentCount = 2
        store.persist(makeSnapshot(documentID: documentID, text: "a", revision: 1)) { _ in
            order.append(1)
            done.fulfill()
        }
        store.persist(makeSnapshot(documentID: documentID, text: "b", revision: 2)) { _ in
            order.append(2)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(order.values, [1, 2])
        store.finishCleanlyForTesting()
    }

    private func makeSnapshot(
        documentID: UUID = UUID(),
        text: String,
        revision: UInt,
        sourceURL: URL? = nil,
        baseline: FileRevisionSnapshot? = nil
    ) -> DocumentRecoverySnapshot {
        DocumentRecoverySnapshot(
            documentID: documentID,
            text: text,
            sourceURL: sourceURL,
            language: .markdown,
            encoding: .utf8,
            revision: revision,
            selectionRange: NSRange(location: 2, length: 3),
            scrollPositionRatio: 0.4,
            isPreviewVisible: true,
            fileRevisionSnapshot: baseline,
            capturedAt: Date()
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LacEditorRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FailingRecoveryFileManager: FileManager, @unchecked Sendable {
    var failOnSessionDirectoryCall: Int?
    var obstructMarker: URL?
    var failRemoval: URL?
    private var sessionDirectoryCalls = 0

    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.lastPathComponent.hasPrefix("Session-") {
            sessionDirectoryCalls += 1
            if sessionDirectoryCalls == failOnSessionDirectoryCall {
                throw CocoaError(.fileWriteNoPermission)
            }
            if let marker = obstructMarker {
                try super.createDirectory(at: marker, withIntermediateDirectories: true, attributes: nil)
            }
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func removeItem(at URL: URL) throws {
        if URL == failRemoval { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
