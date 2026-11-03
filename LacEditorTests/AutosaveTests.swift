import XCTest
@testable import LacEditor

@MainActor
final class AutosaveTests: XCTestCase {
    private var folder: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var states: [AppState] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "LacEditorAutosaveTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        states.forEach { $0.autosave.stop() }
        states = []
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Файл с текстом "one"; документ изменён до "two".
    private func makeState(enabled: Bool = true, interval: Int = 30, dirty: Bool = true,
                           hasURL: Bool = true) throws -> (AppState, EditorDocument, URL) {
        let preferences = AppPreferences(defaults: defaults)
        preferences.autosaveEnabled = enabled
        preferences.autosaveInterval = interval
        let url = folder.appendingPathComponent("note.txt")
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let document = hasURL
            ? EditorDocument(text: "one", url: url, fileRevisionSnapshot: try FileRevisionSnapshot.capture(url))
            : EditorDocument(text: "one")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        states.append(state)
        if dirty { document.text = "two" }
        return (state, document, url)
    }

    private func settle(_ document: EditorDocument) async throws {
        for _ in 0..<200 where document.ioState != .idle || document.isDirty {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForStatus(_ state: AppState, _ document: EditorDocument) async throws {
        for _ in 0..<200 where state.autosave.status(for: document.id) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testTickSavesDirtyDocumentWithPath() async throws {
        let (state, document, url) = try makeState()
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(state.autosave.tick(now: Date()), 1)
        try await settle(document)
        XCTAssertEqual(try read(url), "two")
        XCTAssertFalse(document.isDirty)
        if case .saved? = state.autosave.status(for: document.id) {} else { XCTFail("\(String(describing: state.autosave.status(for: document.id)))") }
        XCTAssertNil(document.statusMessage)
        XCTAssertEqual(document.ioState, .idle)
    }

    func testTickSkipsNewDocumentWithoutURL() throws {
        let (state, _, _) = try makeState(hasURL: false)
        XCTAssertEqual(state.autosave.tick(now: Date()), 0)
    }

    func testTickSkipsWhenDisabled() throws {
        let (state, _, url) = try makeState(enabled: false)
        XCTAssertEqual(state.autosave.tick(now: Date()), 0)
        XCTAssertEqual(try read(url), "one")
    }

    func testTickSkipsUnchangedDocument() throws {
        let (state, _, _) = try makeState(dirty: false)
        XCTAssertEqual(state.autosave.tick(now: Date()), 0)
    }

    func testTickRespectsMinimumIntervalBetweenAttempts() async throws {
        let (state, document, url) = try makeState()
        let start = Date()
        XCTAssertEqual(state.autosave.tick(now: start), 1)
        try await settle(document)
        document.text = "three"
        XCTAssertEqual(state.autosave.tick(now: start.addingTimeInterval(10)), 0)
        XCTAssertEqual(try read(url), "two")
        XCTAssertEqual(state.autosave.tick(now: start.addingTimeInterval(31)), 1)
        try await settle(document)
        XCTAssertEqual(try read(url), "three")
    }

    func testExternalChangePausesAutosaveAndDoesNotOverwrite() async throws {
        let (state, document, url) = try makeState()
        try "external, longer".write(to: url, atomically: true, encoding: .utf8)
        document.noteDiskState(.present(try FileRevisionSnapshot.capture(url)))
        XCTAssertNotNil(document.externalChange)
        XCTAssertEqual(state.autosave.tick(now: Date()), 0)
        XCTAssertEqual(state.autosave.status(for: document.id), .pausedExternalChange)
        XCTAssertEqual(try read(url), "external, longer")
    }

    func testUnnoticedExternalChangeIsDetectedByWriteAndPauses() async throws {
        let (state, document, url) = try makeState()
        try "external, longer".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(state.autosave.tick(now: Date()), 0)
        XCTAssertEqual(state.autosave.status(for: document.id), .pausedExternalChange)
        XCTAssertEqual(try read(url), "external, longer")
        XCTAssertEqual(document.ioState, .idle)
    }

    func testKeepMyVersionDoesNotLiftPause() async throws {
        let (state, document, url) = try makeState()
        try "external, longer".write(to: url, atomically: true, encoding: .utf8)
        document.noteDiskState(.present(try FileRevisionSnapshot.capture(url)))
        let start = Date()
        XCTAssertEqual(state.autosave.tick(now: start), 0)
        document.keepMyVersion()
        XCTAssertNil(document.externalChange)
        XCTAssertEqual(state.autosave.tick(now: start.addingTimeInterval(60)), 0)
        XCTAssertEqual(state.autosave.status(for: document.id), .pausedExternalChange)
        XCTAssertEqual(try read(url), "external, longer")
    }

    func testPauseLiftsAfterReload() async throws {
        let (state, document, url) = try makeState()
        try "external, longer".write(to: url, atomically: true, encoding: .utf8)
        document.noteDiskState(.present(try FileRevisionSnapshot.capture(url)))
        let start = Date()
        XCTAssertEqual(state.autosave.tick(now: start), 0)
        // Файл перезагружен или сохранён вручную: состояние файла в документе изменилось.
        document.updateFileRevisionSnapshot(try FileRevisionSnapshot.capture(url))
        XCTAssertEqual(state.autosave.tick(now: start.addingTimeInterval(60)), 1)
        try await settle(document)
        XCTAssertEqual(try read(url), "two")
    }

    func testWriteFailureSetsFailedStatusWithoutAlertAndIoStateIdle() async throws {
        let (state, document, url) = try makeState()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: folder.path), "каталог остался доступным для записи")
        XCTAssertEqual(state.autosave.tick(now: Date()), 1)
        try await waitForStatus(state, document)
        if case .failed? = state.autosave.status(for: document.id) {} else { XCTFail("\(String(describing: state.autosave.status(for: document.id)))") }
        XCTAssertEqual(document.ioState, .idle)
        XCTAssertTrue(document.isDirty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertEqual(try read(url), "one")
    }

    func testUnknownMediaTokensBlockAutosave() throws {
        let (state, document, url) = try makeState()
        document.setHasUnknownMediaTokens(true)
        XCTAssertEqual(state.autosave.tick(now: Date()), 0)
        if case .failed? = state.autosave.status(for: document.id) {} else { XCTFail("статус должен быть .failed") }
        XCTAssertEqual(try read(url), "one")
    }

    func testSkipsDuringCloseConfirmation() throws {
        let (state, _, url) = try makeState()
        state.closeConfirmationDepth = 1
        XCTAssertTrue(state.isClosingOrConfirmingDocument)
        XCTAssertEqual(state.autosave.tick(now: Date()), 0)
        XCTAssertEqual(try read(url), "one")
        state.closeConfirmationDepth = 0
        XCTAssertFalse(state.isClosingOrConfirmingDocument)
    }

    func testVersionRecordedNotMoreOftenThanFiveMinutes() async throws {
        let (state, document, _) = try makeState()
        let start = Date()
        XCTAssertEqual(state.autosave.tick(now: start), 1)
        try await settle(document)
        XCTAssertEqual(state.autosave.lastVersionRecordDate(for: document.id), start)
        document.text = "three"
        XCTAssertEqual(state.autosave.tick(now: start.addingTimeInterval(40)), 1)
        try await settle(document)
        XCTAssertEqual(state.autosave.lastVersionRecordDate(for: document.id), start)
        document.text = "four"
        let later = start.addingTimeInterval(400)
        XCTAssertEqual(state.autosave.tick(now: later), 1)
        try await settle(document)
        XCTAssertEqual(state.autosave.lastVersionRecordDate(for: document.id), later)
    }

    func testManualSaveStillWorksAndRecordsVersion() async throws {
        let (state, document, url) = try makeState(enabled: false)
        XCTAssertTrue(state.save(document))
        try await settle(document)
        XCTAssertEqual(try read(url), "two")
    }

    func testMakeSnapshotKeepsFileAndDirtyState() async throws {
        let (state, document, url) = try makeState(enabled: false)
        let store = DocumentSnapshotStore.shared
        let location = try XCTUnwrap(state.snapshotLocation(for: document))
        // Не оставляем следов в настоящем Application Support.
        defer { try? FileManager.default.removeItem(at: store.directory(for: location)) }
        let expectation = expectation(description: "snapshot")
        var created: DocumentSnapshotInfo?
        state.makeSnapshot(of: document, name: "Тест снимка \(UUID().uuidString)") { result in
            created = try? result.get()
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 5)
        let info = try XCTUnwrap(created)
        XCTAssertTrue(store.list(location: location).contains { $0.id == info.id })
        XCTAssertEqual(try store.text(id: info.id, location: location), "two")
        XCTAssertEqual(try read(url), "one")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.statusMessage, L10n.tr("快照已保存"))
    }

    func testRenamedFileMovesSnapshotsOutsideProject() async throws {
        let (state, document, url) = try makeState(enabled: false)
        let store = DocumentSnapshotStore.shared
        let oldLocation = try XCTUnwrap(state.snapshotLocation(for: document))
        let newURL = folder.appendingPathComponent("renamed.txt")
        let newLocation = DocumentSnapshotLocation.file(path: newURL.standardizedFileURL.path)
        defer {
            try? FileManager.default.removeItem(at: store.directory(for: oldLocation))
            try? FileManager.default.removeItem(at: store.directory(for: newLocation))
        }
        let info = try store.add(text: "x", name: "R", encodingName: "UTF-8", location: oldLocation, keepLast: 0)
        try FileManager.default.moveItem(at: url, to: newURL)
        state.updateRenamedFileReference(from: url, to: newURL)
        for _ in 0..<100 where store.list(location: newLocation).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.list(location: newLocation).map(\.id), [info.id])
        XCTAssertTrue(store.list(location: oldLocation).isEmpty)
    }
}
