import AppKit
import XCTest
@testable import LacEditor

private final class AIWritingKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

final class AIWritingControllerTests: XCTestCase {
    @MainActor
    func testDisabledFeaturesCannotStartAndSelectionClearsState() throws {
        let suite = "LacEditor-AIWriting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let first = EditorDocument()
        let second = EditorDocument()
        let state = AppState(initialDocuments: [first, second], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = state.aiWriting
        XCTAssertTrue(controller.enabledFeatures.isEmpty)
        controller.run(.summary)
        XCTAssertFalse(controller.isWorking)
        XCTAssertTrue(controller.report.isEmpty)
        preferences.aiFeatures = [.summary, .completion]
        XCTAssertEqual(controller.enabledFeatures, [.summary])
        state.selectedDocumentID = second.id
        XCTAssertFalse(controller.isWorking)
        XCTAssertTrue(controller.suggestions.isEmpty)
        XCTAssertTrue(controller.report.isEmpty)
    }
    @MainActor
    func testMetadataFromSavedVersionIsDiscardedAfterEdit() async throws {
        let suite = "LacEditor-AIMetadata-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.metadata]
        preferences.aiBackgroundEnabled = true
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "original")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIWritingController(appState: state) { _, _, _, _, _, _, _, _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return AIWritingResult(suggestions: [], report: "stale", image: nil)
        }
        controller.didSave(documentID: document.id)
        document.noteLiveEdit(isEmpty: false)
        controller.documentChanged(document.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(document.aiMetadata)
    }

    @MainActor
    func testFailedCommandKeepsPreviousResultAndFeature() async throws {
        let suite = "LacEditor-AIResult-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.summary]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "original")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            guard let request = notification.object as? EditorTextExtractionRequest else { return }
            request.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 8), text: "original", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let controller = AIWritingController(appState: state) { _, _, _, _, _, _, _, _ in
            AIWritingResult(suggestions: [], report: "summary", image: nil)
        }
        controller.run(.summary)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.report, "summary")
        controller.run(.translation)
        XCTAssertEqual(controller.feature, .summary)
        XCTAssertEqual(controller.report, "summary")
    }

    @MainActor
    func testTranslationWaitsForTargetLanguage() throws {
        let suite = "LacEditor-AIOption-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.translation]
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = state.aiWriting
        controller.prepare(.translation)
        XCTAssertTrue(state.isAIWritingVisible)
        XCTAssertEqual(controller.requestedFeature, .translation)
        controller.run(.translation, option: "  ")
        XCTAssertFalse(controller.isWorking)
        XCTAssertFalse(controller.message.isEmpty)
    }

    @MainActor
    func testChangingTranslationLanguageCancelsPendingResult() async throws {
        let suite = "LacEditor-AITranslation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.translation]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "original")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let started = expectation(description: "translation request started")
        let returned = expectation(description: "cancelled request returned")
        var reply: CheckedContinuation<AIWritingResult, Never>?
        var requestedLanguage = ""
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }) { _, _, option, _, _, _, _, _ in
            requestedLanguage = option
            let result = await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
            returned.fulfill()
            return result
        }
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 8), text: "original", editorRevision: 0, wasExplicitSelection: true)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.translation, option: controller.translationTarget)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(requestedLanguage, "English")
        XCTAssertTrue(controller.isWorking)
        controller.translationLanguage = .russian
        XCTAssertFalse(controller.isWorking)
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 8), original: "original", replacement: "устарело", explanation: "")
        reply?.resume(returning: AIWritingResult(suggestions: [suggestion], report: "stale", image: nil))
        await fulfillment(of: [returned], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(controller.suggestions.isEmpty)
        XCTAssertTrue(controller.report.isEmpty)
    }

    @MainActor
    func testSourceSearchDoesNotRequireTextProfileWhenReaderIsOff() async throws {
        let suite = "LacEditor-JinaSearch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.sources]
        var jina = preferences.jinaConfiguration
        jina.searchEnabled = true
        jina.readerEnabled = false
        preferences.jinaConfiguration = jina
        let document = EditorDocument(text: "claim")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            guard let request = notification.object as? EditorTextExtractionRequest else { return }
            request.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 5), text: "claim", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let controller = AIWritingController(appState: state) { _, _, _, _, _, _, _, _ in
            AIWritingResult(suggestions: [], report: "candidates", image: nil)
        }
        controller.run(.sources)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.report, "candidates")
    }

    @MainActor
    func testReferencesAndSummaryUseUTF16EditorRanges() async throws {
        let suite = "LacEditor-AIRanges-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.summary, .terminology]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "prefix 😀乙")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let reference = AIWritingReference(id: UUID(), range: NSRange(location: 2, length: 1), quote: "乙")
        let controller = AIWritingController(appState: state) { feature, _, _, _, _, _, _, _ in
            if feature == .summary { return AIWritingResult(suggestions: [], report: "summary", image: nil) }
            return AIWritingResult(suggestions: [], report: "terms", image: nil, references: [reference])
        }
        var revealed: EditorSelectionRequest?
        var replacement: EditorRangeReplacementRequest?
        let center = NotificationCenter.default
        let extraction = center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 7, length: 3), text: "😀乙", editorRevision: 9, wasExplicitSelection: true)
        }
        let reveal = center.addObserver(forName: EditorCommandNotification.revealSelection, object: nil, queue: .main) { notification in
            revealed = notification.object as? EditorSelectionRequest
        }
        let apply = center.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { notification in
            replacement = notification.object as? EditorRangeReplacementRequest
            replacement?.wasHandled = true
        }
        defer { center.removeObserver(extraction); center.removeObserver(reveal); center.removeObserver(apply) }
        controller.run(.terminology)
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.revealReference(reference)
        XCTAssertEqual(revealed?.range, NSRange(location: 9, length: 1))
        controller.run(.summary)
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.insertSummary()
        XCTAssertEqual(replacement?.range, NSRange(location: 10, length: 0))
        XCTAssertEqual(replacement?.expectedEditorRevision, 9)
        XCTAssertEqual(replacement?.originalText, "")
        XCTAssertEqual(replacement?.replacementText, "\n\nsummary")
    }

    @MainActor
    func testBackgroundUsesEachFeatureModelAndInvalidatesWholeBatch() async throws {
        _ = NSApplication.shared
        let suite = "LacEditor-AIModels-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.clarity, .summary]
        preferences.aiBackgroundEnabled = true
        preferences.aiFeatureModelIDs = [AIFeature.clarity.rawValue: "clarity-model", AIFeature.summary.rawValue: "summary-model"]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "text")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let window = AIWritingKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state.hostWindow = window
        defer { window.close() }
        let started = expectation(description: "second background request")
        var models: [AIFeature: String] = [:]
        var reply: CheckedContinuation<AIWritingResult, Never>?
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }) { feature, _, _, profile, _, _, _, _ in
            models[feature] = profile.modelID
            if feature == .summary {
                return await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
            }
            return AIWritingResult(suggestions: [], report: "first", image: nil)
        }
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.documentChanged(document.id)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(models[.clarity], "clarity-model")
        XCTAssertEqual(models[.summary], "summary-model")
        XCTAssertFalse(controller.report.isEmpty)
        preferences.aiFeatureModelIDs[AIFeature.clarity.rawValue] = "changed-model"
        reply?.resume(returning: AIWritingResult(suggestions: [], report: "stale", image: nil))
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(controller.report.isEmpty)
    }

    @MainActor
    func testSaveMetadataUsesItsOwnModelAndRejectsChangedModel() async throws {
        let suite = "LacEditor-AIModels-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.metadata]
        preferences.aiBackgroundEnabled = true
        preferences.aiFeatureModelIDs[AIFeature.metadata.rawValue] = "metadata-model"
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "text")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let started = expectation(description: "metadata request")
        var model = ""
        var reply: CheckedContinuation<AIWritingResult, Never>?
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }) { _, _, _, profile, _, _, _, _ in
            model = profile.modelID
            return await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }
        controller.didSave(documentID: document.id)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model, "metadata-model")
        preferences.aiFeatureModelIDs[AIFeature.metadata.rawValue] = "other-model"
        reply?.resume(returning: AIWritingResult(suggestions: [], report: "stale", image: nil))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(document.aiMetadata)
    }

    @MainActor
    func testManualFeatureUsesItsSelectedModel() async throws {
        let suite = "LacEditor-AIModels-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.summary]
        preferences.aiFeatureModelIDs[AIFeature.summary.rawValue] = "summary-model"
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.modelID = "role-model"
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "text")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let started = expectation(description: "manual request")
        var model = ""
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }) { _, _, _, profile, _, _, _, _ in
            model = profile.modelID
            started.fulfill()
            return AIWritingResult(suggestions: [], report: "summary", image: nil)
        }
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.summary)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model, "summary-model")
    }

}
