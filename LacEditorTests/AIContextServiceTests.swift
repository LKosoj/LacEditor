import XCTest
@testable import LacEditor

final class AIContextServiceTests: XCTestCase {
    @MainActor
    func testOpenFileUsesDocumentAndDetectsPendingEdit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "disk".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AIContextTests.\(UUID().uuidString)"))
        let document = EditorDocument(text: "unsaved", url: url)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let snapshots = try await AIContextService.capture([.file(url)], appState: state)
        XCTAssertEqual(snapshots.first?.text, "unsaved")
        XCTAssertTrue(AIContextService.isCurrent(snapshots, appState: state))
        document.noteLiveEdit(isEmpty: false)
        XCTAssertFalse(AIContextService.isCurrent(snapshots, appState: state))
    }

    @MainActor
    func testClosedFileChangeAndInvalidEncoding() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "first".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AIContextTests.\(UUID().uuidString)"))
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let snapshots = try await AIContextService.capture([.file(url)], appState: state)
        try "different length".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(AIContextService.isCurrent(snapshots, appState: state))
        try Data([0xff]).write(to: url)
        do {
            _ = try await AIContextService.capture([.file(url)], appState: state)
            XCTFail("Expected encoding request")
        } catch AIContextError.encodingRequired {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    @MainActor
    func testUnavailableDocumentStatesForBothInputKinds() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AIContextTests.\(UUID().uuidString)"))
        let document = EditorDocument(text: "unsaved", url: url, isDirty: true)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        let inputs: [AIContextInput] = [.document(document.id), .file(url)]
        for input in inputs {
            document.ioState = .saving
            let snapshots = try await AIContextService.capture([input], appState: state)
            XCTAssertEqual(snapshots.first?.text, "unsaved")
            for unavailable in [DocumentIOState.opening, .failed("error")] {
                document.ioState = unavailable
                XCTAssertFalse(AIContextService.isCurrent(snapshots, appState: state))
                do {
                    _ = try await AIContextService.capture([input], appState: state)
                    XCTFail("Expected unavailable source")
                } catch AIContextError.unavailable {
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    @MainActor
    func testOpeningPlaceholderRemainsUnavailable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AIContextTests.\(UUID().uuidString)"))
        let document = EditorDocument()
        document.ioState = .opening
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        document.ioState = .idle
        do {
            _ = try await AIContextService.capture([.document(document.id)], appState: state)
            XCTFail("Expected unavailable placeholder")
        } catch AIContextError.unavailable {
        }
    }

    @MainActor
    func testAvailableDocumentsSkipOpeningAndFailedAndRevealSelectsDocument() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AIContextTests.\(UUID().uuidString)"))
        let first = EditorDocument(text: "a"), second = EditorDocument(text: "b"), third = EditorDocument(text: "c")
        let state = AppState(initialDocuments: [first, second, third], recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        second.ioState = .opening
        third.ioState = .saving
        XCTAssertEqual(AIContextService.availableDocuments(in: state).map(\.id), [first.id, third.id])
        let snapshot = AIContextSnapshot(input: .document(third.id), name: "c", text: "", document: third, documentRevision: third.textRevision, fileRevision: nil)
        AIContextService.reveal(snapshot, range: NSRange(location: 0, length: 1), appState: state)
        XCTAssertEqual(state.selectedDocumentID, third.id)
        XCTAssertEqual(third.pendingAIContextSelection?.range, NSRange(location: 0, length: 1))
    }
}
