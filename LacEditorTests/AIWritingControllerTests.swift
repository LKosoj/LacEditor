import AppKit
import XCTest
@preconcurrency @testable import LacEditor

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
        let controller = AIWritingController(appState: state, generate: { _, _, _, _, _, _, _, _, _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return AIWritingResult(suggestions: [], report: "stale", image: nil)
        })
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
        let controller = AIWritingController(appState: state, generate: { _, _, _, _, _, _, _, _, _ in
            AIWritingResult(suggestions: [], report: "summary", image: nil)
        })
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
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }, generate: { _, _, option, _, _, _, _, _, _ in
            requestedLanguage = option
            let result = await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
            returned.fulfill()
            return result
        })
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
        let controller = AIWritingController(appState: state, generate: { _, _, _, _, _, _, _, _, _ in
            AIWritingResult(suggestions: [], report: "candidates", image: nil)
        })
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
        preferences.aiFeatures = [.summary, .consistency]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "prefix 😀乙")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let reference = AIWritingReference(id: UUID(), range: NSRange(location: 2, length: 1), quote: "乙")
        let controller = AIWritingController(appState: state, generate: { feature, _, _, _, _, _, _, _, _ in
            if feature == .summary { return AIWritingResult(suggestions: [], report: "summary", image: nil) }
            return AIWritingResult(suggestions: [], report: "terms", image: nil, references: [reference])
        })
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
        controller.run(.consistency)
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
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }, generate: { feature, _, _, profile, _, _, _, _, _ in
            models[feature] = profile.modelID
            if feature == .summary {
                return await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
            }
            return AIWritingResult(suggestions: [], report: "first", image: nil)
        })
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
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }, generate: { _, _, _, profile, _, _, _, _, _ in
            model = profile.modelID
            return await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        })
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
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }, generate: { _, _, _, profile, _, _, _, _, _ in
            model = profile.modelID
            started.fulfill()
            return AIWritingResult(suggestions: [], report: "summary", image: nil)
        })
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.summary)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model, "summary-model")
    }

    private final class SendSink: @unchecked Sendable {
        var calls: [(AIFeature, String, String)] = []
        var modes: [AIRewriteMode?] = []
        var revision: UInt = 0
        var result = AIWritingResult(suggestions: [], report: "summary", image: nil)
    }

    @MainActor
    private final class SendFixture {
        let defaults: UserDefaults
        let suite: String
        let document: EditorDocument
        let state: AppState
        let controller: AIWritingController
        private let sink: SendSink
        var calls: [(AIFeature, String, String)] { sink.calls }
        var modes: [AIRewriteMode?] { sink.modes }
        var revision: UInt { get { sink.revision } set { sink.revision = newValue } }
        var result: AIWritingResult { get { sink.result } set { sink.result = newValue } }
        private var observer: NSObjectProtocol?

        init(text: String, features: Set<AIFeature> = [.summary], background: Bool = false) throws {
            let sink = SendSink(), document = EditorDocument(text: text)
            let suite = "LacEditor-AISend-\(UUID().uuidString)"
            self.sink = sink; self.document = document; self.suite = suite
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let preferences = AppPreferences(defaults: defaults)
            preferences.aiFeatures = features
            preferences.aiBackgroundEnabled = background
            var configuration = preferences.aiConfiguration
            configuration.text.isEnabled = true
            preferences.aiConfiguration = configuration
            state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
            controller = AIWritingController(appState: state, loadKey: { _, _ in nil }, generate: { feature, input, option, _, _, _, _, _, mode in
                sink.calls.append((feature, input, option))
                sink.modes.append(mode)
                return sink.result
            })
            observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
                (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: (text as NSString).length), text: text, editorRevision: sink.revision, wasExplicitSelection: false)
            }
        }

        func settle() async {
            for _ in 0..<2000 where controller.isWorking { await Task.yield() }
            for _ in 0..<20 { await Task.yield() }
        }

        func tearDown() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private var largeText: String { String(repeating: "a", count: 60 * 1024) }

    @MainActor
    func testLargeManualRunWarnsAndDoesNotSend() async throws {
        let fixture = try SendFixture(text: largeText)
        defer { fixture.tearDown() }
        fixture.controller.run(.summary)
        await fixture.settle()
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertFalse(fixture.controller.message.isEmpty)
        XCTAssertEqual(fixture.controller.messageAction, .sendAnyway)
        XCTAssertEqual(fixture.controller.messageKind, .info)
        XCTAssertFalse(fixture.controller.isWorking)
    }

    @MainActor
    func testSendAnywaySendsSameSnapshotOnce() async throws {
        let text = largeText
        let fixture = try SendFixture(text: text)
        defer { fixture.tearDown() }
        fixture.controller.run(.summary)
        fixture.controller.sendAnyway()
        await fixture.settle()
        XCTAssertEqual(fixture.calls.count, 1)
        XCTAssertEqual(fixture.calls.first?.1, text)
        XCTAssertEqual(fixture.controller.report, "summary")
        let label = L10n.tr("整个文档")
        XCTAssertEqual(fixture.controller.sentSummary, L10n.tr("已发送：%@，%@", label, AIRequestSize.text(text.utf8.count)))
        fixture.controller.sendAnyway()
        await fixture.settle()
        XCTAssertEqual(fixture.calls.count, 1)
    }

    @MainActor
    func testSendAnywayRejectsChangedSnapshot() async throws {
        let fixture = try SendFixture(text: largeText)
        defer { fixture.tearDown() }
        fixture.controller.run(.summary)
        fixture.revision += 1
        fixture.controller.sendAnyway()
        await fixture.settle()
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertEqual(fixture.controller.message, L10n.tr("编辑内容已变化，请重新执行转换"))
        fixture.controller.sendAnyway()
        await fixture.settle()
        XCTAssertTrue(fixture.calls.isEmpty)
    }

    @MainActor
    func testSendAnywayAfterDocumentEditIsDropped() async throws {
        let fixture = try SendFixture(text: largeText)
        defer { fixture.tearDown() }
        fixture.controller.run(.summary)
        fixture.controller.invalidate(documentID: fixture.document.id)
        XCTAssertTrue(fixture.controller.message.isEmpty)
        fixture.controller.sendAnyway()
        await fixture.settle()
        XCTAssertTrue(fixture.calls.isEmpty)
    }

    @MainActor
    func testBackgroundOverThresholdIsSilentlySkipped() async throws {
        let fixture = try SendFixture(text: largeText, features: [.summary, .metadata], background: true)
        defer { fixture.tearDown() }
        fixture.controller.didSave(documentID: fixture.document.id)
        await fixture.settle()
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertTrue(fixture.controller.message.isEmpty)
        // Контроль: тот же путь с текстом ниже порога запрос отправляет, значит пропуск был именно из-за порога
        fixture.document.text = "text"
        fixture.controller.didSave(documentID: fixture.document.id)
        for _ in 0..<300 where fixture.calls.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(fixture.calls.map(\.0), [.metadata])
    }

    @MainActor
    func testSmallRunShowsSentSummaryWithoutWarning() async throws {
        let fixture = try SendFixture(text: "text")
        defer { fixture.tearDown() }
        fixture.controller.run(.summary)
        await fixture.settle()
        XCTAssertEqual(fixture.calls.count, 1)
        XCTAssertNil(fixture.controller.messageAction)
        XCTAssertEqual(fixture.controller.sentSummary, L10n.tr("已发送：%@，%@", L10n.tr("整个文档"), AIRequestSize.text(4)))
    }

    @MainActor
    func testSkippedItemsPostInfoMessage() async throws {
        let fixture = try SendFixture(text: "text", features: [.clarity])
        defer { fixture.tearDown() }
        fixture.result = AIWritingResult(suggestions: [], report: "", image: nil, skipped: 2)
        fixture.controller.run(.clarity)
        await fixture.settle()
        XCTAssertEqual(fixture.controller.message, L10n.tr("模型返回的 %lld 个条目均无法核对，已全部跳过。", 2))
        XCTAssertEqual(fixture.controller.messageKind, .info)
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 4), original: "text", replacement: "x", explanation: "")
        fixture.result = AIWritingResult(suggestions: [suggestion], report: "", image: nil, skipped: 2)
        fixture.controller.run(.clarity)
        await fixture.settle()
        XCTAssertEqual(fixture.controller.message, L10n.tr("已跳过 %lld 个无法核对的条目。", 2))
    }

    @MainActor
    func testPartialSourcesReportsSkippedNotAllDropped() async throws {
        let fixture = try SendFixture(text: "text", features: [.sources])
        defer { fixture.tearDown() }
        fixture.result = AIWritingResult(suggestions: [], report: "claim\nquote", image: nil, skipped: 1, accepted: 1)
        fixture.controller.run(.sources)
        await fixture.settle()
        XCTAssertEqual(fixture.controller.message, L10n.tr("已跳过 %lld 个无法核对的条目。", 1))
        fixture.result = AIWritingResult(suggestions: [], report: "none", image: nil, skipped: 2, accepted: 0)
        fixture.controller.run(.sources)
        await fixture.settle()
        XCTAssertEqual(fixture.controller.message, L10n.tr("模型返回的 %lld 个条目均无法核对，已全部跳过。", 2))
    }

    @MainActor
    func testRewriteModeIsPassedToGenerate() async throws {
        let fixture = try SendFixture(text: "text", features: [.rewrite])
        defer { fixture.tearDown() }
        fixture.controller.selectRewrite(.shorten)
        await fixture.settle()
        XCTAssertEqual(fixture.calls.map(\.0), [.rewrite])
        XCTAssertEqual(fixture.modes, [.shorten])
    }

    @MainActor
    func testToneRewriteRequiresOptionAndOpensPanel() async throws {
        let fixture = try SendFixture(text: "text", features: [.rewrite])
        defer { fixture.tearDown() }
        fixture.controller.selectRewrite(.tone)
        XCTAssertTrue(fixture.state.isAIWritingVisible)
        XCTAssertEqual(fixture.controller.requestedFeature, .rewrite)
        XCTAssertTrue(fixture.calls.isEmpty)
        fixture.controller.run(.rewrite, option: "")
        XCTAssertEqual(fixture.controller.message, L10n.tr("请输入目标语言或语气"))
        XCTAssertEqual(fixture.controller.messageKind, .info)
        XCTAssertTrue(fixture.calls.isEmpty)
        fixture.controller.run(.rewrite, option: "formal")
        await fixture.settle()
        XCTAssertEqual(fixture.modes, [.tone])
    }

    @MainActor
    func testChangingRewriteModeClearsResult() async throws {
        let fixture = try SendFixture(text: "text", features: [.rewrite])
        defer { fixture.tearDown() }
        fixture.result = AIWritingResult(suggestions: [], report: "done", image: nil)
        fixture.controller.selectRewrite(.expand)
        await fixture.settle()
        XCTAssertEqual(fixture.controller.report, "done")
        fixture.controller.rewriteMode = .rephrase
        XCTAssertTrue(fixture.controller.report.isEmpty)
        XCTAssertTrue(fixture.controller.suggestions.isEmpty)
    }

    @MainActor
    func testReaderReviewRunsWithoutOption() async throws {
        let fixture = try SendFixture(text: "text", features: [.readerReview])
        defer { fixture.tearDown() }
        fixture.controller.run(.readerReview, option: "")
        await fixture.settle()
        XCTAssertEqual(fixture.calls.map(\.0), [.readerReview])
    }

    @MainActor
    func testBackgroundBatchIncludesConsistencyAndReaderReview() async throws {
        let fixture = try SendFixture(text: "text", features: [.consistency, .readerReview, .summary, .translation], background: true)
        defer { fixture.tearDown() }
        let window = AIWritingKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        fixture.state.hostWindow = window
        defer { window.close() }
        fixture.controller.documentChanged(fixture.document.id)
        for _ in 0..<300 where fixture.calls.count < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(fixture.calls.map(\.0), [.consistency, .readerReview, .summary])
    }

    @MainActor
    func testPrepareImageDescriptionSendsPictureData() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let address = "data:image/png;base64," + png.base64EncodedString()
        let markdown = "![](\(address))"
        let fixture = try SendFixture(text: markdown, features: [.imageDescription])
        defer { fixture.tearDown() }
        var received: Data?
        let controller = AIWritingController(appState: fixture.state, loadKey: { _, _ in nil }, describe: { data, _, _ in received = data; return "alt" })
        let request = AIImageEditRequest(documentID: fixture.document.id, revision: fixture.document.synchronizedSnapshot().revision,
                                         range: NSRange(location: 0, length: (markdown as NSString).length), originalMarkdown: markdown,
                                         address: address, documentURL: nil)
        controller.prepareImageDescription(request)
        for _ in 0..<2000 where controller.isWorking { await Task.yield() }
        XCTAssertEqual(controller.report, "alt")
        XCTAssertEqual(controller.feature, .imageDescription)
        XCTAssertTrue(fixture.state.isAIWritingVisible)
        XCTAssertEqual(received, png)
    }

    @MainActor
    func testPrepareImageDescriptionIgnoredWhenFeatureDisabled() async throws {
        let fixture = try SendFixture(text: "![](data:image/png;base64,AA==)", features: [.summary])
        defer { fixture.tearDown() }
        var called = false
        let controller = AIWritingController(appState: fixture.state, loadKey: { _, _ in nil }, describe: { _, _, _ in called = true; return "alt" })
        let request = AIImageEditRequest(documentID: fixture.document.id, revision: fixture.document.synchronizedSnapshot().revision,
                                         range: NSRange(location: 0, length: 3), originalMarkdown: "![]", address: "data:image/png;base64,AA==", documentURL: nil)
        controller.prepareImageDescription(request)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(called)
        XCTAssertTrue(controller.report.isEmpty)
    }

    @MainActor
    func testPrepareImageDescriptionIgnoresResultAfterRevisionChange() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let address = "data:image/png;base64," + png.base64EncodedString()
        let markdown = "![](\(address))"
        let fixture = try SendFixture(text: markdown, features: [.imageDescription])
        defer { fixture.tearDown() }
        var called = false
        let controller = AIWritingController(appState: fixture.state, loadKey: { _, _ in nil }, describe: { _, _, _ in
            called = true
            await MainActor.run { fixture.document.text += " x" }
            return "alt"
        })
        let request = AIImageEditRequest(documentID: fixture.document.id, revision: fixture.document.synchronizedSnapshot().revision,
                                         range: NSRange(location: 0, length: (markdown as NSString).length), originalMarkdown: markdown,
                                         address: address, documentURL: nil)
        controller.prepareImageDescription(request)
        for _ in 0..<2000 where controller.isWorking { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(called)
        XCTAssertTrue(controller.report.isEmpty)
    }
}
