import XCTest
@testable import LacEditor

final class UIPolishATests: XCTestCase {
    // MARK: AIWordDiff

    func testWordDiffMarksReplacedWord() {
        let runs = AIWordDiff.runs(original: "the quick fox", replacement: "the slow fox")
        XCTAssertEqual(runs.original.map(\.text).joined(), "the quick fox")
        XCTAssertEqual(runs.replacement.map(\.text).joined(), "the slow fox")
        XCTAssertEqual(runs.original.filter { $0.kind == .removed }.map(\.text), ["quick"])
        XCTAssertEqual(runs.replacement.filter { $0.kind == .added }.map(\.text), ["slow"])
    }

    func testWordDiffKeepsCJKAndEmojiIntact() {
        let runs = AIWordDiff.runs(original: "你好😀世界", replacement: "你好😀地球")
        XCTAssertEqual(runs.original.map(\.text).joined(), "你好😀世界")
        XCTAssertEqual(runs.replacement.map(\.text).joined(), "你好😀地球")
        XCTAssertTrue(runs.original.contains { $0.kind == .same && $0.text.contains("😀") })
        XCTAssertEqual(runs.replacement.filter { $0.kind == .added }.map(\.text).joined(), "地球")
    }

    func testWordDiffIdenticalHasOnlySameRuns() {
        let runs = AIWordDiff.runs(original: "same text", replacement: "same text")
        XCTAssertTrue(runs.original.allSatisfy { $0.kind == .same })
        XCTAssertTrue(runs.replacement.allSatisfy { $0.kind == .same })
    }

    func testWordDiffEmptyOriginalIsAllAdded() {
        let runs = AIWordDiff.runs(original: "", replacement: "new words")
        XCTAssertTrue(runs.original.isEmpty)
        XCTAssertEqual(runs.replacement, [AIWordDiff.Run(kind: .added, text: "new words")])
    }

    func testWordDiffAttributedKeepsPlainText() {
        let runs = AIWordDiff.runs(original: "a b c", replacement: "a x c")
        XCTAssertEqual(String(AIWordDiff.attributed(runs.replacement).characters), "a x c")
        XCTAssertEqual(String(AIWordDiff.attributed(runs.original).characters), "a b c")
    }

    // MARK: AIDocumentToolsController

    @MainActor
    private func makeTools(features: Set<AIFeature>, documents: [EditorDocument], defaults: UserDefaults,
                           generate: @escaping (AIFeature, String, String, [AIContextSnapshot], AICustomCheck?, AIModelProfile, String?) async throws -> String) -> (AIDocumentToolsController, AppState) {
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = features
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let state = AppState(initialDocuments: documents, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        return (AIDocumentToolsController(appState: state, generate: generate, loadKey: { _, _ in nil }), state)
    }

    @MainActor
    private func observeSelection(_ document: EditorDocument) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: true)
        }
    }

    @MainActor
    func testStopKeepsInputs() async throws {
        let suite = "LacEditor-UIPolishA-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "text")
        let started = expectation(description: "request")
        var reply: CheckedContinuation<String, Never>?
        let (controller, state) = makeTools(features: [.explain], documents: [document], defaults: defaults) { _, _, _, _, _, _, _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }
        let observer = observeSelection(document)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.option = "keep me"
        controller.run(.explain)
        await fulfillment(of: [started], timeout: 2)
        controller.stop()
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.option, "keep me")
        reply?.resume(returning: "late")
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(controller.report.isEmpty)
        withExtendedLifetime(state) {}
    }

    @MainActor
    func testOptionChangeKeepsResultAndMarksStale() async throws {
        let suite = "LacEditor-UIPolishA-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "text")
        let (controller, state) = makeTools(features: [.mermaid], documents: [document], defaults: defaults) { _, _, _, _, _, _, _ in "graph TD" }
        var applied = false
        let center = NotificationCenter.default
        let selection = observeSelection(document)
        let apply = center.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { _ in applied = true }
        defer { center.removeObserver(selection); center.removeObserver(apply) }
        controller.run(.mermaid)
        for _ in 0..<1000 where controller.report.isEmpty { await Task.yield() }
        XCTAssertEqual(controller.report, "graph TD")
        XCTAssertFalse(controller.isResultStale)
        controller.option = "changed"
        XCTAssertTrue(controller.isResultStale)
        controller.insert()
        XCTAssertFalse(applied)
        controller.option = ""
        XCTAssertFalse(controller.isResultStale)
        withExtendedLifetime(state) {}
    }

    @MainActor
    func testMessagesAreTyped() async throws {
        let suite = "LacEditor-UIPolishA-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "text")
        var failure: AIError = .network
        let (controller, state) = makeTools(features: [.explain], documents: [document], defaults: defaults) { _, _, _, _, _, _, _ in throw failure }
        // нет выделения: уведомление, без действия
        controller.run(.explain)
        XCTAssertEqual(controller.messageKind, .info)
        XCTAssertNil(controller.messageAction)
        let observer = observeSelection(document)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.explain)
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        XCTAssertEqual(controller.messageKind, .error)
        XCTAssertEqual(controller.messageAction, .retry)
        failure = .http(401)
        controller.run(.explain)
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        XCTAssertEqual(controller.messageAction, .openSettings)
        failure = .http(503)
        controller.run(.explain)
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        XCTAssertEqual(controller.messageAction, .retry)
        XCTAssertNil(AIMessageAction.forError(AIError.refused))
        // выключенный профиль
        var configuration = state.preferences.aiConfiguration
        configuration.text.isEnabled = false
        state.preferences.aiConfiguration = configuration
        controller.run(.explain)
        XCTAssertEqual(controller.messageKind, .error)
        XCTAssertEqual(controller.messageAction, .openSettings)
        withExtendedLifetime(state) {}
    }

    // MARK: AIWritingController

    @MainActor
    private func makeWriting(defaults: UserDefaults, document: EditorDocument, suggestions: [AIWritingSuggestion]) async throws -> (AIWritingController, AppState) {
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.clarity]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }) { _, _, _, _, _, _, _, _ in
            AIWritingResult(suggestions: suggestions, report: "", image: nil)
        }
        controller.run(.clarity)
        for _ in 0..<1000 where controller.suggestions.isEmpty { await Task.yield() }
        return (controller, state)
    }

    @MainActor
    private func observeWriting(_ document: EditorDocument) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 3, length: 13), text: "one two three", editorRevision: 7, wasExplicitSelection: true)
        }
    }

    @MainActor
    func testAcceptAllIsOneGroupedReplacement() async throws {
        let suite = "LacEditor-UIPolishA-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "abcone two three")
        let selection = observeWriting(document)
        var requests: [EditorRangeReplacementRequest] = []
        let apply = NotificationCenter.default.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { notification in
            guard let request = notification.object as? EditorRangeReplacementRequest else { return }
            requests.append(request); request.wasHandled = true
        }
        defer { NotificationCenter.default.removeObserver(selection); NotificationCenter.default.removeObserver(apply) }
        let (controller, state) = try await makeWriting(defaults: defaults, document: document, suggestions: [
            AIWritingSuggestion(id: UUID(), range: NSRange(location: 8, length: 5), original: "three", replacement: "3", explanation: ""),
            AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 3), original: "one", replacement: "1", explanation: "")
        ])
        XCTAssertEqual(controller.suggestions.count, 2)
        controller.acceptAll()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.range, NSRange(location: 3, length: 13))
        XCTAssertEqual(request.originalText, "one two three")
        XCTAssertEqual(request.replacementText, "1 two 3")
        XCTAssertTrue(request.groupsUndo)
        XCTAssertTrue(request.isAIGenerated)
        XCTAssertTrue(controller.suggestions.isEmpty)
        withExtendedLifetime(state) {}
    }

    @MainActor
    func testAcceptAllRejectsOverlapAndChangedOriginal() async throws {
        let suite = "LacEditor-UIPolishA-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "abcone two three")
        let selection = observeWriting(document)
        var requestCount = 0
        let apply = NotificationCenter.default.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { _ in requestCount += 1 }
        defer { NotificationCenter.default.removeObserver(selection); NotificationCenter.default.removeObserver(apply) }
        let (overlapping, state1) = try await makeWriting(defaults: defaults, document: document, suggestions: [
            AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 7), original: "one two", replacement: "x", explanation: ""),
            AIWritingSuggestion(id: UUID(), range: NSRange(location: 4, length: 3), original: "two", replacement: "2", explanation: "")
        ])
        overlapping.acceptAll()
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(overlapping.message.isEmpty)
        XCTAssertEqual(overlapping.suggestions.count, 2)
        let (changed, state2) = try await makeWriting(defaults: defaults, document: document, suggestions: [
            AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 3), original: "uno", replacement: "1", explanation: ""),
            AIWritingSuggestion(id: UUID(), range: NSRange(location: 8, length: 5), original: "three", replacement: "3", explanation: "")
        ])
        changed.acceptAll()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(changed.suggestions.count, 2)
        withExtendedLifetime((state1, state2)) {}
    }

    @MainActor
    func testRejectAllClearsSuggestions() async throws {
        let suite = "LacEditor-UIPolishA-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "abcone two three")
        let selection = observeWriting(document)
        defer { NotificationCenter.default.removeObserver(selection) }
        let (controller, state) = try await makeWriting(defaults: defaults, document: document, suggestions: [
            AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 3), original: "one", replacement: "1", explanation: "")
        ])
        XCTAssertEqual(controller.suggestions.count, 1)
        controller.rejectAll()
        XCTAssertTrue(controller.suggestions.isEmpty)
        withExtendedLifetime(state) {}
    }

    // MARK: Исходники

    func testViewsUseStopSubmitAndNoWindowShortcuts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let tools = try String(contentsOf: root.appendingPathComponent("LacEditor/Views/AIDocumentToolsView.swift"), encoding: .utf8)
        let writing = try String(contentsOf: root.appendingPathComponent("LacEditor/Views/AIWritingView.swift"), encoding: .utf8)
        XCTAssertTrue(tools.contains("controller.stop()"))
        XCTAssertTrue(tools.contains(".onSubmit"))
        XCTAssertFalse(tools.contains(".onChange(of: controller.option)"))
        XCTAssertTrue(writing.contains("acceptAll()"))
        for source in [tools, writing] {
            XCTAssertFalse(source.contains("keyboardShortcut"))
            XCTAssertTrue(source.contains(".onExitCommand"))
        }
    }
}
