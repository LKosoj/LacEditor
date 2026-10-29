import XCTest
@testable import LacEditor

final class AIDocumentToolsTests: XCTestCase {
    @MainActor
    func testMermaidInsertionUsesUTF16AndRejectsChangedRevision() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.mermaid]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "prefix 😀乙")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in "graph TD\nA-->B" }, loadKey: { _, _ in nil })
        var revision: UInt = 3
        var replacement: EditorRangeReplacementRequest?
        let center = NotificationCenter.default
        let extraction = center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 7, length: 3), text: "😀乙", editorRevision: revision, wasExplicitSelection: true)
        }
        let apply = center.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { notification in
            replacement = notification.object as? EditorRangeReplacementRequest
            replacement?.wasHandled = true
        }
        defer { center.removeObserver(extraction); center.removeObserver(apply) }
        controller.run(.mermaid)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.report, "graph TD\nA-->B")
        controller.insert()
        XCTAssertEqual(replacement?.range, NSRange(location: 10, length: 0))
        XCTAssertEqual(replacement?.replacementText, "\n\n```mermaid\ngraph TD\nA-->B\n```")
        replacement = nil
        revision += 1
        controller.insert()
        XCTAssertNil(replacement)
    }

    @MainActor
    func testContextEditCancelsPendingResult() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.contextReview]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let target = EditorDocument(text: "target")
        let source = EditorDocument(text: "source")
        let state = AppState(initialDocuments: [target, source], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            try? await Task.sleep(nanoseconds: 40_000_000)
            return "stale"
        }, loadKey: { _, _ in nil })
        let center = NotificationCenter.default
        let extraction = center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: target.id, range: NSRange(location: 0, length: 6), text: "target", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { center.removeObserver(extraction) }
        controller.inputs = [.document(source.id)]
        controller.run(.contextReview)
        try await Task.sleep(nanoseconds: 10_000_000)
        center.post(name: EditorCommandNotification.documentContentDidChange, object: source.id)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(controller.report.isEmpty)
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testDisablingFeatureCancelsPendingResult() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.explain]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "text")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            try? await Task.sleep(nanoseconds: 40_000_000)
            return "stale"
        }, loadKey: { _, _ in nil })
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: true)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.explain)
        preferences.aiFeatures = []
        controller.settingsChanged()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(controller.report.isEmpty)
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testDisablingVoiceCancelsPendingMicrophonePermission() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.voiceDraft]
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let requested = expectation(description: "permission requested")
        var reply: CheckedContinuation<Bool, Never>?
        let recorder = AIVoiceRecorder(requestPermission: {
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        let controller = AIDocumentToolsController(appState: state, recorder: recorder)
        controller.startRecording()
        await fulfillment(of: [requested], timeout: 2)
        preferences.aiFeatures = []
        controller.settingsChanged()
        reply?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.recordingURL)
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testSwitchingDocumentCancelsPendingMicrophonePermission() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.voiceDraft]
        let first = EditorDocument(), second = EditorDocument()
        let state = AppState(initialDocuments: [first, second], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let requested = expectation(description: "permission requested")
        var reply: CheckedContinuation<Bool, Never>?
        let recorder = AIVoiceRecorder(requestPermission: {
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        })
        let controller = AIDocumentToolsController(appState: state, recorder: recorder)
        controller.startRecording()
        await fulfillment(of: [requested], timeout: 2)
        state.selectedDocumentID = second.id
        controller.selectedDocumentChanged()
        reply?.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.recordingURL)
        XCTAssertFalse(controller.isWorking)
    }

    @MainActor
    func testChangedFileClearsPublishedComparisonAfterResponse() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.txt")
        let new = directory.appendingPathComponent("new.txt")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        try "new".write(to: new, atomically: true, encoding: .utf8)
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.compareVersions]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "target")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let requested = expectation(description: "model request started")
        var reply: CheckedContinuation<String, Never>?
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            await withCheckedContinuation { continuation in
                reply = continuation
                requested.fulfill()
            }
        }, loadKey: { _, _ in nil })
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 6), text: "target", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.before = .file(old); controller.after = .file(new)
        controller.run(.compareVersions)
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertFalse(controller.differences.isEmpty)
        try "changed after request".write(to: old, atomically: true, encoding: .utf8)
        reply?.resume(returning: "old explanation")
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        XCTAssertFalse(controller.isWorking)
        XCTAssertTrue(controller.differences.isEmpty)
        XCTAssertTrue(controller.report.isEmpty)
        XCTAssertFalse(controller.message.isEmpty)
    }

    func testContextQuotesUseUTF16AndRejectInvalidOrAmbiguousReferences() throws {
        let source = AIContextSnapshot(input: .file(URL(fileURLWithPath: "/tmp/context.txt")), name: "context.txt", text: "A😀中文 B repeated repeated", document: nil, documentRevision: nil, fileRevision: nil)
        func response(_ index: Any, _ quote: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["report": "review", "references": [["sourceIndex": index, "quote": quote]]])
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
        let parsed = try AIDocumentToolsService.parseContextResponse(response(0, "中文"), contexts: [source])
        XCTAssertEqual(parsed.references.first?.range, NSRange(location: 3, length: 2))
        for (index, quote) in [(0, "missing"), (0, "repeated"), (0, ""), (true, "中文"), (-1, "中文"), (1, "中文"), (0.5, "中文")] as [(Any, String)] {
            XCTAssertThrowsError(try AIDocumentToolsService.parseContextResponse(response(index, quote), contexts: [source]))
        }
        XCTAssertThrowsError(try AIDocumentToolsService.parseContextResponse("{\"report\":\"review\",\"references\":[]}", contexts: [source]))
        let empty = AIContextSnapshot(input: .file(URL(fileURLWithPath: "/tmp/empty.txt")), name: "empty.txt", text: " \u{2003}\n", document: nil, documentRevision: nil, fileRevision: nil)
        let insufficient = try AIDocumentToolsService.parseContextResponse("{\"report\":\"Not enough context\",\"references\":[]}", contexts: [empty])
        XCTAssertEqual(insufficient.report, "Not enough context")
        XCTAssertTrue(insufficient.references.isEmpty)
    }

    @MainActor
    func testContextReferenceRevealsOpenDocumentAtUTF16Range() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.contextReview]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let target = EditorDocument(text: "target")
        let source = EditorDocument(text: "A😀中文")
        let state = AppState(initialDocuments: [target, source], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let requested = expectation(description: "context request")
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            requested.fulfill()
            return "{\"report\":\"review\",\"references\":[{\"sourceIndex\":0,\"quote\":\"中文\"}]}"
        }, loadKey: { _, _ in nil })
        let center = NotificationCenter.default
        let extraction = center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: target.id, range: NSRange(location: 0, length: 6), text: "target", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { center.removeObserver(extraction) }
        controller.inputs = [.document(source.id)]
        controller.run(.contextReview)
        await fulfillment(of: [requested], timeout: 2)
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        let reference = try XCTUnwrap(controller.references.first)
        XCTAssertEqual(controller.referenceName(reference), source.displayName)
        controller.openReference(reference)
        XCTAssertEqual(state.selectedDocumentID, source.id)
        XCTAssertEqual(source.pendingAIContextSelection?.range, NSRange(location: 3, length: 2))
        XCTAssertEqual(source.pendingAIContextSelection?.revision, source.textRevision)
    }

    @MainActor
    func testChangedOptionKeepsResultAndMarksStale() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.explain]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "text")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let started = expectation(description: "model request")
        var reply: CheckedContinuation<String, Never>?
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }, loadKey: { _, _ in nil })
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: true)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.explain)
        await fulfillment(of: [started], timeout: 2)
        controller.option = "changed"
        reply?.resume(returning: "old answer")
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.report, "old answer")
        XCTAssertTrue(controller.isResultStale)
    }

    @MainActor
    func testChangedComparisonChoiceKeepsResultAndMarksStale() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.compareVersions]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let target = EditorDocument(text: "target"), old = EditorDocument(text: "old"), new = EditorDocument(text: "new")
        let state = AppState(initialDocuments: [target, old, new], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let started = expectation(description: "model request")
        var reply: CheckedContinuation<String, Never>?
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }, loadKey: { _, _ in nil })
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: target.id, range: NSRange(location: 0, length: 6), text: "target", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.before = .document(old.id); controller.after = .document(new.id)
        controller.run(.compareVersions)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(controller.differences.isEmpty)
        controller.after = .document(old.id)
        reply?.resume(returning: "old explanation")
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.report, "old explanation")
        XCTAssertFalse(controller.differences.isEmpty)
        XCTAssertTrue(controller.isResultStale)
    }

    @MainActor
    func testDisablingCustomCheckClearsSelection() throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let check = AICustomCheck(name: "check", instructions: "check text", isEnabled: true)
        preferences.aiCustomChecks = [check]
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIDocumentToolsController(appState: state)
        controller.checkID = check.id
        preferences.aiCustomChecks[0].isEnabled = false
        controller.settingsChanged()
        XCTAssertNil(controller.checkID)
    }

    @MainActor
    func testCustomCheckUsesRuleModelAndRejectsChangedModel() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.customCheck]
        preferences.aiFeatureModelIDs[AIFeature.customCheck.rawValue] = "feature-model"
        let check = AICustomCheck(name: "check", instructions: "check", isEnabled: true, modelID: "rule-model")
        preferences.aiCustomChecks = [check]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "text")
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let started = expectation(description: "check request")
        var model = ""
        var reply: CheckedContinuation<String, Never>?
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, profile, _ in
            model = profile.modelID
            return await withCheckedContinuation { continuation in reply = continuation; started.fulfill() }
        }, loadKey: { _, _ in nil })
        let observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 0, length: 4), text: "text", editorRevision: 0, wasExplicitSelection: false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.checkID = check.id
        controller.run(.customCheck)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model, "rule-model")
        preferences.aiCustomChecks[0].modelID = "changed-model"
        reply?.resume(returning: "stale")
        for _ in 0..<1000 where controller.isWorking { await Task.yield() }
        XCTAssertTrue(controller.report.isEmpty)
        XCTAssertFalse(controller.isWorking)
    }

}
