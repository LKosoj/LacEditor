import AppKit
import XCTest
@preconcurrency @testable import LacEditor

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
    func testManualResultIsDiscardedAfterFeatureModelChange() async throws {
        let suite = "LacEditor-AIModels-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.summary]
        preferences.aiFeatureModelIDs[AIFeature.summary.rawValue] = "summary-model"
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "text")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let started = expectation(description: "manual request")
        var reply: CheckedContinuation<AIWritingResult, Never>?
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }, generate: { _, _, _, _, _, _, _, _, _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        })
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.summary)
        await fulfillment(of: [started], timeout: 2)
        preferences.aiFeatureModelIDs[AIFeature.summary.rawValue] = "changed-model"
        reply?.resume(returning: AIWritingResult(suggestions: [], report: "stale", image: nil))
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(controller.report.isEmpty)
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

        init(text: String, features: Set<AIFeature> = [.summary]) throws {
            let sink = SendSink(), document = EditorDocument(text: text)
            let suite = "LacEditor-AISend-\(UUID().uuidString)"
            self.sink = sink; self.document = document; self.suite = suite
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let preferences = AppPreferences(defaults: defaults)
            preferences.aiFeatures = features
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
    func testSendAnywayAfterDocumentCloseIsDropped() async throws {
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
        XCTAssertTrue(fixture.calls.isEmpty)
        XCTAssertTrue(fixture.state.isAIWritingVisible)
        XCTAssertEqual(fixture.controller.requestedFeature, .rewrite)
        fixture.controller.run(.rewrite)
        await fixture.settle()
        XCTAssertEqual(fixture.calls.map(\.0), [.rewrite])
        XCTAssertEqual(fixture.modes, [.shorten])
    }

    @MainActor
    func testMenuCommandsOpenPanelWithoutRequest() async throws {
        let features: [AIFeature] = [.clarity, .consistency, .structure, .summary, .sources, .metadata, .tasksAndDecisions, .table, .illustration, .imageDescription, .imageEdit, .rewrite, .translation, .readerReview]
        let fixture = try SendFixture(text: "text", features: Set(features))
        defer { fixture.tearDown() }
        for feature in features {
            fixture.controller.prepare(feature)
            XCTAssertTrue(fixture.state.isAIWritingVisible)
            XCTAssertEqual(fixture.controller.requestedFeature, feature)
            await fixture.settle()
            XCTAssertTrue(fixture.calls.isEmpty, "\(feature)")
            XCTAssertFalse(fixture.controller.isWorking)
        }
        fixture.controller.selectRewrite(.tone)
        fixture.controller.selectRewrite(.expand)
        await fixture.settle()
        XCTAssertTrue(fixture.calls.isEmpty)
    }

    func testMenuSourceDoesNotStartRequests() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let commands = try String(contentsOf: root.appendingPathComponent("LacEditor/App/LacEditorCommands.swift"), encoding: .utf8)
        XCTAssertFalse(commands.contains("aiWriting.run("))
        XCTAssertFalse(commands.contains("describeImage()"))
        XCTAssertFalse(commands.contains("opensPanelFirst"))
        XCTAssertTrue(commands.contains("aiWriting.prepare(feature)"))
        XCTAssertTrue(commands.contains("aiWriting.explainSelection()"))
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
        fixture.controller.run(.rewrite)
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
    func testPrepareImageDescriptionKeepsResultAfterRevisionChange() async throws {
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
        XCTAssertEqual(controller.report, "alt")
    }

    // MARK: Результат и правки после изменения текста

    /// Редактор для тестов: отдаёт живой текст и курсор, применяет замены к документу и меняет версию.
    @MainActor
    private final class LiveEditor {
        let document: EditorDocument
        var revision: UInt = 1
        var caret = NSRange(location: 0, length: 0)
        /// Текст редактора, если он отличается от текста документа (свёрнутые data URI).
        var projection: String?
        private(set) var requests: [EditorRangeReplacementRequest] = []
        private var tokens: [NSObjectProtocol] = []

        init(document: EditorDocument) {
            self.document = document
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let request = note.object as? EditorTextExtractionRequest, request.documentID == self.document.id,
                          !request.requiresEditable || !self.document.isReadingMode else { return }
                    let text = self.projection ?? self.document.text
                    if request.includesEditorText { request.editorText = text }
                    request.result = request.allowsWholeDocument
                        ? EditorTextSelectionSnapshot(documentID: request.documentID, range: NSRange(location: 0, length: (text as NSString).length), text: text, editorRevision: self.revision, wasExplicitSelection: false)
                        : EditorTextSelectionSnapshot(documentID: request.documentID, range: self.caret, text: "", editorRevision: self.revision, wasExplicitSelection: false)
                }
            })
            tokens.append(center.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let request = note.object as? EditorRangeReplacementRequest, request.documentID == self.document.id else { return }
                    self.requests.append(request)
                    let text = (self.projection ?? self.document.text) as NSString
                    guard request.expectedEditorRevision == self.revision, NSMaxRange(request.range) <= text.length,
                          text.substring(with: request.range) == request.originalText else {
                        request.failureMessage = "changed"
                        return
                    }
                    let replaced = text.replacingCharacters(in: request.range, with: request.replacementText)
                    if self.projection != nil { self.projection = replaced } else { self.document.text = replaced }
                    self.revision += 1
                    request.wasHandled = true
                }
            })
        }

        /// Правка пользователя: меняет текст и версию редактора.
        func setText(_ text: String) {
            document.text = text
            revision += 1
        }

        func tearDown() { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    private typealias WritingGenerate = (AIFeature, String, String, AIModelProfile, String?, JinaConfiguration?, String?, String?, AIRewriteMode?) async throws -> AIWritingResult

    @MainActor
    private func makeLive(text: String, features: Set<AIFeature> = [.clarity], extra: [EditorDocument] = [], generate: @escaping WritingGenerate) throws -> (controller: AIWritingController, state: AppState, document: EditorDocument, editor: LiveEditor, cleanup: @MainActor () -> Void) {
        let suite = "LacEditor-AILive-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = features
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: text)
        let state = AppState(initialDocuments: [document] + extra, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        state.selectedDocumentID = document.id
        let controller = AIWritingController(appState: state, loadKey: { _, _ in nil }, generate: generate)
        let editor = LiveEditor(document: document)
        return (controller, state, document, editor, { editor.tearDown(); defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    private func settle(_ controller: AIWritingController) async {
        for _ in 0..<2000 where controller.isWorking { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    func testAcceptingOneSuggestionKeepsOthersAndShiftsRanges() async throws {
        let first = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 2), original: "aa", replacement: "xxxx", explanation: "")
        let second = AIWritingSuggestion(id: UUID(), range: NSRange(location: 6, length: 2), original: "cc", replacement: "y", explanation: "")
        let live = try makeLive(text: "aa bb cc") { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [first, second], report: "", image: nil) }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await settle(live.controller)
        live.controller.accept(first)
        XCTAssertEqual(live.editor.requests.count, 1)
        XCTAssertEqual(live.editor.requests[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(live.controller.suggestions.map(\.id), [second.id])
        XCTAssertEqual(live.controller.suggestions.first?.range, NSRange(location: 8, length: 2))
        XCTAssertTrue(live.controller.hasResult)
        live.controller.accept(live.controller.suggestions[0])
        XCTAssertEqual(live.editor.requests.count, 2)
        XCTAssertEqual(live.editor.requests[1].range, NSRange(location: 8, length: 2))
        XCTAssertEqual(live.document.text, "xxxx bb y")
        XCTAssertTrue(live.controller.suggestions.isEmpty)
    }

    @MainActor
    func testAcceptUsesEditorCoordinatesWhenDocumentTextDiffers() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 4, length: 2), original: "cc", replacement: "y", explanation: "")
        let live = try makeLive(text: "![](data:image/png;base64,QUJD) cc") { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [suggestion], report: "", image: nil) }
        defer { live.cleanup() }
        live.editor.projection = "![] cc"
        live.controller.run(.clarity)
        await settle(live.controller)
        live.controller.accept(suggestion)
        XCTAssertEqual(live.editor.requests.first?.range, NSRange(location: 4, length: 2))
        XCTAssertEqual(live.editor.projection, "![] y")
        XCTAssertTrue(live.controller.suggestions.isEmpty)
    }

    @MainActor
    func testAcceptIsRefusedInReadingModeAndKeepsSuggestion() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 2), original: "aa", replacement: "x", explanation: "")
        let live = try makeLive(text: "aa bb") { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [suggestion], report: "", image: nil) }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await settle(live.controller)
        live.document.setReadingMode(true)
        live.controller.accept(suggestion)
        live.controller.acceptAll()
        XCTAssertTrue(live.editor.requests.isEmpty)
        XCTAssertEqual(live.controller.message, L10n.tr("阅读模式下无法修改"))
        XCTAssertEqual(live.controller.suggestions.map(\.id), [suggestion.id])
    }

    @MainActor
    func testSendAnywayAfterDocumentEditIsDropped() async throws {
        var calls = 0
        let live = try makeLive(text: largeText, features: [.summary]) { _, _, _, _, _, _, _, _, _ in
            calls += 1
            return AIWritingResult(suggestions: [], report: "report", image: nil)
        }
        defer { live.cleanup() }
        live.controller.run(.summary)
        live.editor.setText(largeText + "b")
        live.controller.sendAnyway()
        await settle(live.controller)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testAcceptFindsOnlyOccurrenceAfterUserEdit() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 6, length: 2), original: "cc", replacement: "y", explanation: "")
        let live = try makeLive(text: "aa bb cc") { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [suggestion], report: "", image: nil) }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await settle(live.controller)
        live.editor.setText("ZZ aa bb cc")
        live.controller.accept(suggestion)
        XCTAssertEqual(live.editor.requests.count, 1)
        XCTAssertEqual(live.editor.requests[0].range, NSRange(location: 9, length: 2))
        XCTAssertEqual(live.editor.requests[0].expectedEditorRevision, live.editor.revision - 1)
        XCTAssertEqual(live.document.text, "ZZ aa bb y")
    }

    @MainActor
    func testAcceptMarksAmbiguousOrMissingSuggestion() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 6, length: 2), original: "cc", replacement: "y", explanation: "")
        let live = try makeLive(text: "aa bb cc") { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [suggestion], report: "", image: nil) }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await settle(live.controller)
        live.editor.setText("cc cc zz")
        live.controller.accept(suggestion)
        XCTAssertTrue(live.editor.requests.isEmpty)
        XCTAssertEqual(live.controller.unavailableIDs, [suggestion.id])
        XCTAssertEqual(live.controller.suggestions.count, 1)
        live.editor.setText("zzzzzzzz")
        live.controller.accept(suggestion)
        XCTAssertTrue(live.editor.requests.isEmpty)
        XCTAssertEqual(live.controller.suggestions.count, 1)
        live.editor.setText("aa bb cc")
        live.controller.accept(suggestion)
        XCTAssertEqual(live.editor.requests.count, 1)
        XCTAssertTrue(live.controller.unavailableIDs.isEmpty)
    }

    @MainActor
    func testEditingTextKeepsResultAndRunningRequest() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 2), original: "aa", replacement: "x", explanation: "")
        let started = expectation(description: "request")
        var reply: CheckedContinuation<AIWritingResult, Never>?
        let live = try makeLive(text: "aa bb") { _, _, _, _, _, _, _, _, _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await fulfillment(of: [started], timeout: 2)
        live.editor.setText("aa bb!")
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: live.document.id)
        XCTAssertTrue(live.controller.isWorking)
        reply?.resume(returning: AIWritingResult(suggestions: [suggestion], report: "", image: nil))
        await settle(live.controller)
        XCTAssertEqual(live.controller.suggestions.count, 1)
        live.editor.setText("aa bb!!")
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: live.document.id)
        XCTAssertEqual(live.controller.suggestions.count, 1)
    }

    @MainActor
    func testResetClearsResultAndDropsLateResponse() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 2), original: "aa", replacement: "x", explanation: "")
        let started = expectation(description: "request")
        var reply: CheckedContinuation<AIWritingResult, Never>?
        var calls = 0
        let live = try makeLive(text: "aa bb") { _, _, _, _, _, _, _, _, _ in
            calls += 1
            if calls == 1 { return AIWritingResult(suggestions: [suggestion], report: "", image: nil) }
            return await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await settle(live.controller)
        XCTAssertTrue(live.controller.hasResult)
        live.controller.reset()
        XCTAssertFalse(live.controller.hasResult)
        XCTAssertEqual(live.controller.feature, .clarity)
        live.controller.run(.clarity)
        await fulfillment(of: [started], timeout: 2)
        live.controller.reset()
        XCTAssertFalse(live.controller.isWorking)
        reply?.resume(returning: AIWritingResult(suggestions: [suggestion], report: "", image: nil))
        await settle(live.controller)
        XCTAssertFalse(live.controller.hasResult)
    }

    @MainActor
    func testTabSwitchKeepsResultAndShowsOtherDocument() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 2), original: "aa", replacement: "x", explanation: "")
        let second = EditorDocument(text: "other")
        let live = try makeLive(text: "aa bb", extra: [second]) { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [suggestion], report: "", image: nil) }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await settle(live.controller)
        live.state.selectedDocumentID = second.id
        live.controller.selectedDocumentChanged()
        XCTAssertEqual(live.controller.suggestions.count, 1)
        XCTAssertEqual(live.controller.otherDocumentName, live.document.displayName)
        live.controller.accept(suggestion)
        XCTAssertTrue(live.editor.requests.isEmpty)
        live.state.selectedDocumentID = live.document.id
        live.controller.selectedDocumentChanged()
        XCTAssertNil(live.controller.otherDocumentName)
        live.controller.accept(suggestion)
        XCTAssertEqual(live.editor.requests.count, 1)
    }

    @MainActor
    func testTabSwitchDropsRunningRequest() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 2), original: "aa", replacement: "x", explanation: "")
        let second = EditorDocument(text: "other")
        let started = expectation(description: "request")
        var reply: CheckedContinuation<AIWritingResult, Never>?
        let live = try makeLive(text: "aa bb", extra: [second]) { _, _, _, _, _, _, _, _, _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await fulfillment(of: [started], timeout: 2)
        live.state.selectedDocumentID = second.id
        live.controller.selectedDocumentChanged()
        XCTAssertFalse(live.controller.isWorking)
        reply?.resume(returning: AIWritingResult(suggestions: [suggestion], report: "", image: nil))
        await settle(live.controller)
        XCTAssertFalse(live.controller.hasResult)
    }

    @MainActor
    func testClosingResultDocumentClearsResult() async throws {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 0, length: 2), original: "aa", replacement: "x", explanation: "")
        let second = EditorDocument(text: "other")
        let live = try makeLive(text: "aa bb", extra: [second]) { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [suggestion], report: "", image: nil) }
        defer { live.cleanup() }
        live.controller.run(.clarity)
        await settle(live.controller)
        live.state.selectedDocumentID = second.id
        live.controller.selectedDocumentChanged()
        live.controller.invalidate(documentID: second.id)
        XCTAssertEqual(live.controller.suggestions.count, 1)
        live.controller.invalidate(documentID: live.document.id)
        XCTAssertTrue(live.controller.suggestions.isEmpty)
    }

    @MainActor
    func testSummaryInsertsAfterSourceThenAtCaretAfterEdit() async throws {
        let live = try makeLive(text: "hello world", features: [.summary]) { _, _, _, _, _, _, _, _, _ in AIWritingResult(suggestions: [], report: "sum", image: nil) }
        defer { live.cleanup() }
        live.controller.run(.summary)
        await settle(live.controller)
        live.controller.insertSummary()
        XCTAssertEqual(live.editor.requests.last?.range, NSRange(location: 11, length: 0))
        XCTAssertEqual(live.document.text, "hello world\n\nsum")
        live.editor.caret = NSRange(location: 5, length: 0)
        live.controller.insertSummary()
        XCTAssertEqual(live.editor.requests.last?.range, NSRange(location: 5, length: 0))
        XCTAssertEqual(live.document.text, "hello\n\nsum world\n\nsum")
        XCTAssertEqual(live.controller.report, "sum")
    }

    func testPlacementLocatesExpectedPlaceThenOnlyOccurrence() {
        let text = "a😀b a😀b" as NSString
        XCTAssertEqual(AIWritingPlacement.locate(original: "b", expected: NSRange(location: 3, length: 1), in: text), NSRange(location: 3, length: 1))
        XCTAssertNil(AIWritingPlacement.locate(original: "b", expected: NSRange(location: 0, length: 1), in: text))
        XCTAssertEqual(AIWritingPlacement.locate(original: "😀b a", expected: NSRange(location: 0, length: 1), in: text), NSRange(location: 1, length: 5))
        XCTAssertNil(AIWritingPlacement.locate(original: "zz", expected: NSRange(location: 0, length: 2), in: text))
        XCTAssertNil(AIWritingPlacement.locate(original: "", expected: NSRange(location: 0, length: 0), in: text))
        XCTAssertEqual(AIWritingPlacement.locate(original: "a😀b a", expected: NSRange(location: 90, length: 3), in: "xx a😀b a😀" as NSString), NSRange(location: 3, length: 6))
    }

    func testShiftedKeepsIdentityAndMovesRange() {
        let suggestion = AIWritingSuggestion(id: UUID(), range: NSRange(location: 4, length: 2), original: "ab", replacement: "c", explanation: "e")
        let moved = suggestion.shifted(by: -3)
        XCTAssertEqual(moved.id, suggestion.id)
        XCTAssertEqual(moved.range, NSRange(location: 1, length: 2))
        XCTAssertEqual(moved.original, "ab")
        XCTAssertEqual(moved.replacement, "c")
    }
}
