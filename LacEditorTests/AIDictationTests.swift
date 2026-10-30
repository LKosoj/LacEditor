import XCTest
@preconcurrency @testable import LacEditor

@MainActor
final class AIDictationTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var transcribeCalls = 0
        var cleanupCalls = 0
        var cleanupInput: String?
        var cleanupProfile: AIModelProfile?
        var pasteboard: String?
        var replacement: EditorRangeReplacementRequest?
        var selection = NSRange(location: 5, length: 0)
        var editorText: String?
        var revision: UInt = 7
        var handled = true
        var hasSelection = true
    }

    private struct Environment {
        let state: AppState
        let document: EditorDocument
        let preferences: AppPreferences
        let box: Box
        let observers: [NSObjectProtocol]
        let cleanup: () -> Void
    }

    private func makeEnvironment(text: String = "hello world", textProfileEnabled: Bool = true) throws -> Environment {
        let suite = "LacEditor-Dictation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.voiceDraft]
        var configuration = preferences.aiConfiguration
        configuration.audio.isEnabled = true
        configuration.audio.modelID = "audio-model"
        configuration.text.isEnabled = textProfileEnabled
        configuration.text.modelID = "text-model"
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: text)
        let state = AppState(initialDocuments: [document], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        state.selectedDocumentID = document.id
        let box = Box()
        let center = NotificationCenter.default
        let extraction = center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            guard box.hasSelection, let request = notification.object as? EditorTextExtractionRequest else { return }
            request.result = EditorTextSelectionSnapshot(documentID: request.documentID, range: box.selection, text: "", editorRevision: box.revision, wasExplicitSelection: box.selection.length > 0)
            request.editorText = box.editorText
        }
        let apply = center.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { notification in
            box.replacement = notification.object as? EditorRangeReplacementRequest
            box.replacement?.wasHandled = box.handled
        }
        return Environment(state: state, document: document, preferences: preferences, box: box, observers: [extraction, apply], cleanup: {
            center.removeObserver(extraction); center.removeObserver(apply)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    private func makeController(_ environment: Environment,
                                transcribe: @escaping (URL, AIModelProfile, String?) async throws -> String = { _, _, _ in "э привет" },
                                cleanup: ((String, AIModelProfile, String?) async throws -> String)? = nil,
                                askRetry: ((String) async -> Bool)? = nil) -> AIDictationController {
        let box = environment.box
        return AIDictationController(
            appState: environment.state,
            recorder: AIVoiceRecorder(requestPermission: { true }),
            transcribe: transcribe,
            cleanup: cleanup ?? { input, profile, _ in
                box.cleanupCalls += 1; box.cleanupInput = input; box.cleanupProfile = profile
                return "Привет."
            },
            loadKey: { _, _ in nil },
            askRetry: askRetry,
            writePasteboard: { box.pasteboard = $0 })
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func waitForIdle(_ controller: AIDictationController) async throws {
        for _ in 0..<200 where controller.state != .idle { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Чистые функции

    func testInsertionSpaceRule() {
        func insertion(_ text: String, _ source: String, _ location: Int) -> String? {
            AIDictationController.insertion(of: text, in: source as NSString, at: location)
        }
        XCTAssertEqual(insertion("привет", "", 0), "привет")
        XCTAssertEqual(insertion("привет", "abc", 3), " привет")
        XCTAssertEqual(insertion("привет", "abc ", 4), "привет")
        XCTAssertEqual(insertion("привет", "abc\n", 4), "привет")
        XCTAssertEqual(insertion("привет", "abc\r\n", 5), "привет")
        XCTAssertEqual(insertion("привет", "a😀", 3), " привет")
        XCTAssertEqual(insertion("привет", "e\u{301}", 2), " привет")
        XCTAssertEqual(insertion("  привет \n\n", "abc", 3), " привет")
        XCTAssertEqual(insertion("раз\n\nдва", "abc", 3), " раз\n\nдва")
        XCTAssertNil(insertion("  \n", "abc", 3))
        XCTAssertNil(insertion("", "abc", 3))
        XCTAssertNil(insertion("привет", "abc", 4))
        XCTAssertNil(insertion("привет", "abc", -1))
        XCTAssertFalse((insertion("привет", "abc\n", 4) ?? "").contains("\n\n"))
    }

    func testCleanedResponse() {
        XCTAssertEqual(AIDictationController.cleaned(" Привет. \n", fallback: "э привет"), "Привет.")
        XCTAssertEqual(AIDictationController.cleaned("```\nПривет.\n```", fallback: "э привет"), "Привет.")
        XCTAssertEqual(AIDictationController.cleaned("  \n", fallback: "э привет"), "э привет")
    }

    func testVoiceCleanupProfileUsesTextProfileAndOwnModel() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let preferences = environment.preferences
        XCTAssertEqual(preferences.voiceCleanupProfile().modelID, "text-model")
        preferences.aiFeatureModelIDs[AppPreferences.voiceCleanupModelKey] = "  cleanup-model "
        let profile = preferences.voiceCleanupProfile()
        XCTAssertEqual(profile.modelID, "cleanup-model")
        XCTAssertEqual(profile.baseURL, preferences.aiConfiguration.text.baseURL)
        XCTAssertEqual(profile.api, preferences.aiConfiguration.text.api)
        XCTAssertEqual(preferences.aiProfile(for: .voiceDraft).modelID, "audio-model")
    }

    func testUnavailableReasonTable() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let preferences = environment.preferences
        let document = environment.document
        XCTAssertNil(AIDictationController.unavailableReason(preferences: preferences, document: document))
        XCTAssertNotNil(AIDictationController.unavailableReason(preferences: preferences, document: nil))
        let original = preferences.aiConfiguration
        var configuration = original
        configuration.audio.modelID = " "
        preferences.aiConfiguration = configuration
        XCTAssertNotNil(AIDictationController.unavailableReason(preferences: preferences, document: document))
        configuration = original
        configuration.audio.isEnabled = false
        preferences.aiConfiguration = configuration
        XCTAssertNotNil(AIDictationController.unavailableReason(preferences: preferences, document: document))
        configuration = original
        configuration.audio.api = .responses
        preferences.aiConfiguration = configuration
        XCTAssertNotNil(AIDictationController.unavailableReason(preferences: preferences, document: document))
        preferences.aiConfiguration = original
        preferences.aiFeatures = []
        XCTAssertNotNil(AIDictationController.unavailableReason(preferences: preferences, document: document))
        preferences.aiFeatures = [.voiceDraft]
        document.ioState = .opening
        XCTAssertNotNil(AIDictationController.unavailableReason(preferences: preferences, document: document))
    }

    func testButtonStates() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let controller = makeController(environment)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.isButtonEnabled)
        XCTAssertEqual(controller.buttonSymbol, "mic")
        environment.preferences.aiFeatures = []
        XCTAssertFalse(controller.isButtonEnabled)
        XCTAssertFalse(controller.buttonToolTip.isEmpty)
    }

    func testVoiceDraftIsNotAPanelFeature() throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        XCTAssertFalse(AIFeature.voiceDraft.isDocumentTool)
        XCTAssertFalse(environment.state.aiWriting.enabledFeatures.contains(.voiceDraft))
        XCTAssertEqual(AIFeature.voiceDraft.role, .audio)
        XCTAssertEqual(AIFeature(rawValue: "voiceDraft"), .voiceDraft)
    }

    // MARK: Поток обработки

    func testProcessInsertsAfterSelectionWithoutReplacingIt() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        // Текст редактора отличается от текста документа (свёрнутые data URI): пробел считается по тексту редактора.
        environment.box.editorText = "abc def"
        environment.box.selection = NSRange(location: 4, length: 3)
        let controller = makeController(environment)
        let audio = try makeAudio()
        controller.process(audio: audio, documentID: environment.document.id)
        XCTAssertEqual(controller.state, .processing)
        try await waitForIdle(controller)
        let request = try XCTUnwrap(environment.box.replacement)
        XCTAssertEqual(request.range, NSRange(location: 7, length: 0))
        XCTAssertEqual(request.originalText, "")
        XCTAssertEqual(request.replacementText, " Привет.")
        XCTAssertEqual(request.expectedEditorRevision, 7)
        XCTAssertEqual(request.actionName, AIFeature.voiceDraft.title)
        XCTAssertEqual(environment.box.cleanupInput, "э привет")
        XCTAssertEqual(environment.box.cleanupProfile?.modelID, "text-model")
        XCTAssertNil(environment.box.pasteboard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testCleanupFailureInsertsRawTextWithNotice() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.editorText = "abc "
        environment.box.selection = NSRange(location: 4, length: 0)
        let controller = makeController(environment, cleanup: { _, _, _ in throw AIError.network })
        controller.process(audio: try makeAudio(), documentID: environment.document.id)
        try await waitForIdle(controller)
        XCTAssertEqual(environment.box.replacement?.replacementText, "э привет")
        XCTAssertEqual(environment.document.statusMessage, L10n.tr("整理文字失败，已插入未整理的识别结果"))
    }

    func testDisabledTextProfileSkipsCleanup() async throws {
        let environment = try makeEnvironment(textProfileEnabled: false)
        defer { environment.cleanup() }
        environment.box.editorText = "abc"
        environment.box.selection = NSRange(location: 3, length: 0)
        let controller = makeController(environment)
        controller.process(audio: try makeAudio(), documentID: environment.document.id)
        try await waitForIdle(controller)
        XCTAssertEqual(environment.box.cleanupCalls, 0)
        XCTAssertEqual(environment.box.replacement?.replacementText, " э привет")
        XCTAssertEqual(environment.document.statusMessage, L10n.tr("文本模型未启用，已插入未整理的识别结果"))
    }

    func testRecognitionFailureDeleteRemovesAudioAndInsertsNothing() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let controller = makeController(environment, transcribe: { _, _, _ in throw AIError.network }, askRetry: { _ in false })
        let audio = try makeAudio()
        controller.process(audio: audio, documentID: environment.document.id)
        try await waitForIdle(controller)
        XCTAssertNil(environment.box.replacement)
        XCTAssertNil(environment.box.pasteboard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testRecognitionRetrySucceedsOnSecondAttempt() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.editorText = ""
        environment.box.selection = NSRange(location: 0, length: 0)
        let box = environment.box
        let controller = makeController(environment, transcribe: { _, _, _ in
            box.transcribeCalls += 1
            if box.transcribeCalls == 1 { throw AIError.network }
            return "привет"
        }, askRetry: { _ in true })
        controller.process(audio: try makeAudio(), documentID: environment.document.id)
        try await waitForIdle(controller)
        XCTAssertEqual(box.transcribeCalls, 2)
        XCTAssertEqual(box.replacement?.replacementText, "Привет.")
    }

    func testOtherTabGoesToPasteboard() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let other = EditorDocument(text: "other")
        environment.state.documents.append(other)
        environment.state.selectedDocumentID = other.id
        let controller = makeController(environment)
        controller.process(audio: try makeAudio(), documentID: environment.document.id)
        try await waitForIdle(controller)
        XCTAssertNil(environment.box.replacement)
        XCTAssertEqual(environment.box.pasteboard, "Привет.")
        XCTAssertEqual(other.statusMessage, L10n.tr("无法插入到原文档，听写文字已复制到剪贴板"))
    }

    func testUnhandledOrMissingInsertionPointGoesToPasteboard() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        environment.box.editorText = "abc"
        environment.box.selection = NSRange(location: 3, length: 0)
        environment.box.handled = false
        let controller = makeController(environment)
        controller.process(audio: try makeAudio(), documentID: environment.document.id)
        try await waitForIdle(controller)
        XCTAssertEqual(environment.box.pasteboard, "Привет.")
        environment.box.pasteboard = nil
        environment.box.replacement = nil
        environment.box.hasSelection = false
        controller.process(audio: try makeAudio(), documentID: environment.document.id)
        try await waitForIdle(controller)
        XCTAssertNil(environment.box.replacement)
        XCTAssertEqual(environment.box.pasteboard, "Привет.")
    }

    // MARK: Отмена

    func testWindowClosedCancelsPendingMicrophonePermission() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let requested = expectation(description: "permission requested")
        var reply: CheckedContinuation<Bool, Never>?
        let recorder = AIVoiceRecorder(requestPermission: {
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        let controller = AIDictationController(appState: environment.state, recorder: recorder)
        controller.toggle()
        XCTAssertEqual(controller.state, .requestingPermission)
        XCTAssertFalse(controller.isButtonEnabled)
        await fulfillment(of: [requested], timeout: 2)
        controller.windowClosed()
        reply?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.recordingURL)
    }

    func testDisablingFeatureCancelsPendingMicrophonePermission() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let requested = expectation(description: "permission requested")
        var reply: CheckedContinuation<Bool, Never>?
        let recorder = AIVoiceRecorder(requestPermission: {
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        let controller = AIDictationController(appState: environment.state, recorder: recorder)
        controller.toggle()
        await fulfillment(of: [requested], timeout: 2)
        environment.preferences.aiFeatures = []
        for _ in 0..<20 { await Task.yield(); try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(controller.state, .idle)
        reply?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.recordingURL)
    }

    func testLateRecognitionAfterWindowClosedInsertsNothingAndKeepsNoFile() async throws {
        let environment = try makeEnvironment()
        defer { environment.cleanup() }
        let requested = expectation(description: "transcribe started")
        var reply: CheckedContinuation<String, Never>?
        let controller = makeController(environment, transcribe: { _, _, _ in
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        let audio = try makeAudio()
        controller.process(audio: audio, documentID: environment.document.id)
        await fulfillment(of: [requested], timeout: 2)
        controller.windowClosed()
        XCTAssertEqual(controller.state, .idle)
        reply?.resume(returning: "поздний ответ")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(environment.box.replacement)
        XCTAssertNil(environment.box.pasteboard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }
}
