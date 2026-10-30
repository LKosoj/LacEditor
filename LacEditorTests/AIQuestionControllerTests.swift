import XCTest
@testable import LacEditor

final class AIQuestionControllerTests: XCTestCase {
    private let valid = #"{"answer":"ok","citations":[]}"#

    @MainActor
    private func make(_ documents: [EditorDocument], converse: @escaping ([AIConversationMessage], AIModelProfile, String?) async throws -> String) throws -> (AIQuestionController, AppState, AppPreferences) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditor-AIQuestion-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.ask]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let state = AppState(initialDocuments: documents, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        return (AIQuestionController(appState: state, converse: converse, loadKey: { _, _ in nil }), state, preferences)
    }

    private func observeSelection(_ document: EditorDocument, range: NSRange, text: String, explicit: Bool) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: range, text: text, editorRevision: 0, wasExplicitSelection: explicit)
        }
    }

    @MainActor
    private func settle(_ controller: AIQuestionController) async {
        for _ in 0..<2000 where controller.isWorking { await Task.yield() }
    }

    private func lastUserText(_ messages: [AIConversationMessage]) -> String {
        if case .user(let text)? = messages.last { return text }
        return ""
    }

    @MainActor
    func testSelectionIsTheSourceAndCitationRangeIsAbsolute() async throws {
        let document = EditorDocument(text: "Intro. The key fact is here. Outro.")
        var sent: [AIConversationMessage] = []
        let (controller, _, _) = try make([document]) { messages, _, _ in
            sent = messages
            return #"{"answer":"yes","citations":[{"sourceIndex":0,"quote":"key fact"}]}"#
        }
        let observer = observeSelection(document, range: NSRange(location: 7, length: 21), text: "The key fact is here.", explicit: true)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.draft = "What is the fact?"
        controller.ask()
        await settle(controller)
        let text = lastUserText(sent)
        XCTAssertTrue(text.contains(#""scope":"selection""#))
        XCTAssertFalse(text.contains("Intro"))
        let turn = try XCTUnwrap(controller.turns.first)
        XCTAssertEqual(turn.citations.first?.range, NSRange(location: 11, length: 8))
        XCTAssertEqual(controller.draft, "")
        XCTAssertEqual(turn.sourceSummary, L10n.tr("%@（所选片段）", document.displayName))
    }

    @MainActor
    func testWholeDocumentWithoutSelectionAndExplainNeedsSelection() async throws {
        let document = EditorDocument(text: "Whole text")
        var calls = 0
        var sent: [AIConversationMessage] = []
        let (controller, _, _) = try make([document]) { messages, _, _ in calls += 1; sent = messages; return self.valid }
        let observer = observeSelection(document, range: NSRange(location: 0, length: 10), text: "Whole text", explicit: false)
        controller.draft = "Question"
        controller.ask()
        await settle(controller)
        XCTAssertTrue(lastUserText(sent).contains(#""scope":"document""#))
        XCTAssertEqual(controller.turns.count, 1)
        NotificationCenter.default.removeObserver(observer)
        controller.askAboutSelection()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.messageKind, .info)
        XCTAssertEqual(controller.message, L10n.tr("请先选择需要处理的文本"))
    }

    @MainActor
    func testExplainSelectionSendsFixedQuestionWithoutTouchingDraft() async throws {
        let document = EditorDocument(text: "Some selected words")
        var sent: [AIConversationMessage] = []
        let (controller, _, _) = try make([document]) { messages, _, _ in sent = messages; return self.valid }
        let observer = observeSelection(document, range: NSRange(location: 5, length: 8), text: "selected", explicit: true)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.sourceMode = .files
        controller.draft = "keep me"
        controller.askAboutSelection()
        await settle(controller)
        XCTAssertEqual(controller.sourceMode, .currentDocument)
        XCTAssertTrue(lastUserText(sent).hasSuffix(L10n.tr("请解释所选文本。")))
        XCTAssertEqual(controller.draft, "keep me")
        XCTAssertEqual(controller.turns.count, 1)
    }

    @MainActor
    func testOpenDocumentsUseOnlyAvailableDocumentsOfTheWindow() async throws {
        let first = EditorDocument(text: "FIRST-TEXT"), second = EditorDocument(text: "SECOND-TEXT"), third = EditorDocument(text: "THIRD-TEXT")
        var sent: [AIConversationMessage] = []
        let (controller, state, _) = try make([first, second, third]) { messages, _, _ in
            sent = messages
            return #"{"answer":"ok","citations":[{"sourceIndex":1,"quote":"SECOND"}]}"#
        }
        third.ioState = .opening
        XCTAssertEqual(controller.availableDocuments.map(\.id), [first.id, second.id])
        controller.sourceMode = .openDocuments
        controller.draft = "Question"
        controller.ask()
        await settle(controller)
        let text = lastUserText(sent)
        XCTAssertTrue(text.contains("FIRST-TEXT") && text.contains("SECOND-TEXT"))
        XCTAssertFalse(text.contains("THIRD-TEXT"))
        let citation = try XCTUnwrap(controller.turns.first?.citations.first)
        XCTAssertEqual(citation.sourceName, second.displayName)
        controller.openCitation(citation)
        XCTAssertEqual(state.selectedDocumentID, second.id)
        XCTAssertEqual(second.pendingAIContextSelection?.range, NSRange(location: 0, length: 6))
    }

    @MainActor
    func testFilesModeWithoutFilesAsksForSource() throws {
        var calls = 0
        let (controller, _, _) = try make([EditorDocument(text: "x")]) { _, _, _ in calls += 1; return self.valid }
        controller.sourceMode = .files
        controller.draft = "Question"
        controller.ask()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(controller.message, L10n.tr("请至少添加一个来源。"))
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testLargeRequestWaitsForConfirmationAndRejectsChangedSource() async throws {
        let big = String(repeating: "x", count: AIRequestSize.threshold + 10)
        let document = EditorDocument(text: big)
        var calls = 0
        let (controller, _, _) = try make([document]) { _, _, _ in calls += 1; return self.valid }
        let observer = observeSelection(document, range: NSRange(location: 0, length: big.utf16.count), text: big, explicit: false)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.draft = "Question"
        controller.ask()
        await settle(controller)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(controller.messageAction, .sendAnyway)
        XCTAssertEqual(controller.draft, "Question")
        controller.sendAnyway()
        await settle(controller)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.turns.count, 1)
        controller.newConversation()
        controller.draft = "Again"
        controller.ask()
        await settle(controller)
        XCTAssertEqual(calls, 1)
        document.text = big + "y"
        controller.sendAnyway()
        await settle(controller)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(controller.turns.isEmpty)
        XCTAssertEqual(controller.message, L10n.tr("所选来源已不可用或已更改。"))
        controller.sendAnyway()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testHistoryIsSentErrorKeepsDraftAndNewConversationClears() async throws {
        let document = EditorDocument(text: "Body")
        var sent: [[AIConversationMessage]] = []
        var failure: Error?
        let (controller, _, _) = try make([document]) { messages, _, _ in
            sent.append(messages)
            if let failure { throw failure }
            return #"{"answer":"a\#(sent.count)"}"#
        }
        let observer = observeSelection(document, range: NSRange(location: 0, length: 4), text: "Body", explicit: false)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.draft = "q1"
        controller.ask()
        await settle(controller)
        controller.draft = "q2"
        controller.ask()
        await settle(controller)
        XCTAssertEqual(sent[1].count, 3)
        XCTAssertEqual(sent[1][0], .user("q1"))
        XCTAssertEqual(sent[1][1], .assistant(#"{"answer":"a1"}"#))
        XCTAssertEqual(controller.turns.map(\.answer), ["a1", "a2"])
        failure = AIError.network
        controller.draft = "q3"
        controller.ask()
        await settle(controller)
        XCTAssertEqual(controller.draft, "q3")
        XCTAssertEqual(controller.messageAction, .retry)
        XCTAssertEqual(controller.turns.count, 2)
        controller.newConversation()
        XCTAssertTrue(controller.turns.isEmpty)
        XCTAssertTrue(controller.message.isEmpty)
    }

    @MainActor
    private func assertLateReplyIsDropped(_ trigger: (AIQuestionController, AppState, AppPreferences, EditorDocument) -> Void) async throws {
        let document = EditorDocument(text: "Body")
        let started = expectation(description: "request")
        var reply: CheckedContinuation<String, Never>?
        let (controller, state, preferences) = try make([document]) { _, _, _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }
        let observer = observeSelection(document, range: NSRange(location: 0, length: 4), text: "Body", explicit: false)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.draft = "Question"
        controller.ask()
        await fulfillment(of: [started], timeout: 2)
        trigger(controller, state, preferences, document)
        reply?.resume(returning: valid)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(controller.turns.isEmpty)
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testLateReplyIsDroppedAfterCancellationEvents() async throws {
        try await assertLateReplyIsDropped { controller, _, _, _ in controller.hidden() }
        try await assertLateReplyIsDropped { controller, _, _, _ in controller.stop() }
        try await assertLateReplyIsDropped { controller, _, _, _ in controller.selectedDocumentChanged() }
        try await assertLateReplyIsDropped { controller, _, _, document in controller.invalidate(documentID: document.id) }
        try await assertLateReplyIsDropped { controller, _, preferences, _ in preferences.aiFeatures = []; controller.settingsChanged() }
        try await assertLateReplyIsDropped { controller, _, preferences, _ in
            var configuration = preferences.aiConfiguration
            configuration.text.modelID = "other-model"
            preferences.aiConfiguration = configuration
            controller.settingsChanged()
        }
        try await assertLateReplyIsDropped { _, _, _, document in
            document.text = "Changed"
            NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: document.id)
        }
    }

    @MainActor
    func testHiddenKeepsHistoryAndDisablingFeatureClearsIt() async throws {
        let document = EditorDocument(text: "Body")
        let (controller, _, preferences) = try make([document]) { _, _, _ in self.valid }
        let observer = observeSelection(document, range: NSRange(location: 0, length: 4), text: "Body", explicit: false)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.draft = "q1"
        controller.ask()
        await settle(controller)
        controller.hidden()
        controller.selectedDocumentChanged()
        XCTAssertEqual(controller.turns.count, 1)
        preferences.aiFeatures = []
        controller.settingsChanged()
        XCTAssertTrue(controller.turns.isEmpty)
    }

    @MainActor
    func testCitationBecomesStaleAfterEditAndRevealsOnlyWhenCurrent() async throws {
        let document = EditorDocument(text: "Alpha beta gamma")
        let (controller, _, _) = try make([document]) { _, _, _ in #"{"answer":"ok","citations":[{"sourceIndex":0,"quote":"beta"}]}"# }
        let selection = observeSelection(document, range: NSRange(location: 0, length: 16), text: "Alpha beta gamma", explicit: false)
        var revealed: [EditorSelectionRequest] = []
        let reveal = NotificationCenter.default.addObserver(forName: EditorCommandNotification.revealSelection, object: nil, queue: .main) { notification in
            if let request = notification.object as? EditorSelectionRequest { revealed.append(request) }
        }
        defer { NotificationCenter.default.removeObserver(selection); NotificationCenter.default.removeObserver(reveal) }
        controller.draft = "Question"
        controller.ask()
        await settle(controller)
        let citation = try XCTUnwrap(controller.turns.first?.citations.first)
        XCTAssertTrue(controller.staleCitationIDs.isEmpty)
        controller.openCitation(citation)
        XCTAssertEqual(revealed.count, 1)
        XCTAssertEqual(revealed.first?.range, NSRange(location: 6, length: 4))
        document.text = "Alpha changed gamma"
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: document.id)
        XCTAssertEqual(controller.staleCitationIDs, [citation.id])
        controller.openCitation(citation)
        XCTAssertEqual(revealed.count, 1)
        XCTAssertEqual(controller.message, L10n.tr("来源已更改，无法定位。"))
    }

    @MainActor
    func testDisabledFeatureDoesNotSend() throws {
        var calls = 0
        let (controller, _, preferences) = try make([EditorDocument(text: "x")]) { _, _, _ in calls += 1; return self.valid }
        preferences.aiFeatures = []
        controller.draft = "Question"
        controller.ask()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testRetryResendsSelectionQuestionAfterError() async throws {
        let document = EditorDocument(text: "Alpha beta")
        var calls = 0
        var sent: [AIConversationMessage] = []
        let (controller, _, _) = try make([document]) { messages, _, _ in
            calls += 1; sent = messages
            if calls == 1 { throw AIContextError.unavailable }
            return #"{"answer":"ok","citations":[]}"#
        }
        let selection = observeSelection(document, range: NSRange(location: 0, length: 5), text: "Alpha", explicit: true)
        defer { NotificationCenter.default.removeObserver(selection) }
        controller.askAboutSelection()
        await settle(controller)
        XCTAssertFalse(controller.message.isEmpty)
        controller.retry()
        await settle(controller)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(lastUserText(sent).contains(L10n.tr("请解释所选文本。")))
        XCTAssertEqual(controller.turns.count, 1)
    }

    @MainActor
    func testTypingInOtherDocumentDoesNotMarkCitationStale() async throws {
        let document = EditorDocument(text: "Alpha beta gamma")
        let (controller, _, _) = try make([document]) { _, _, _ in #"{"answer":"ok","citations":[{"sourceIndex":0,"quote":"beta"}]}"# }
        let selection = observeSelection(document, range: NSRange(location: 0, length: 16), text: "Alpha beta gamma", explicit: false)
        defer { NotificationCenter.default.removeObserver(selection) }
        controller.draft = "Question"
        controller.ask()
        await settle(controller)
        document.text = "Alpha changed gamma"
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: UUID())
        XCTAssertTrue(controller.staleCitationIDs.isEmpty)
    }
}
