import XCTest
@preconcurrency @testable import LacEditor

final class AIDocumentToolsTests: XCTestCase {
    @MainActor
    func testMermaidInsertsAtCurrentCaretWithFreshRevisionOnlyInShownTab() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.mermaid]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.modelID = "test-model"
        preferences.aiConfiguration = configuration
        let document = EditorDocument(text: "prefix 😀乙")
        let other = EditorDocument(text: "other")
        let state = AppState(initialDocuments: [document, other], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        state.selectedDocumentID = document.id
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in "graph TD\nA-->B" }, loadKey: { _, _ in nil })
        final class RevisionBox: @unchecked Sendable { var value: UInt = 3 }
        let revision = RevisionBox()
        var replacement: EditorRangeReplacementRequest?
        let center = NotificationCenter.default
        let extraction = center.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: document.id, range: NSRange(location: 7, length: 3), text: "😀乙", editorRevision: revision.value, wasExplicitSelection: true)
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
        XCTAssertEqual(replacement?.expectedEditorRevision, 3)
        replacement = nil
        revision.value += 1
        controller.insert()
        XCTAssertEqual(replacement?.expectedEditorRevision, 4)
        replacement = nil
        state.selectedDocumentID = other.id
        XCTAssertNotNil(controller.otherDocumentName)
        controller.insert()
        XCTAssertNil(replacement)
        state.selectedDocumentID = document.id
        XCTAssertNil(controller.otherDocumentName)
        controller.insert()
        XCTAssertNotNil(replacement)
    }

    @MainActor
    func testContextEditDoesNotCancelPendingResult() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.contextReview]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.modelID = "test-model"
        configuration.text.modelID = "test-model"
        preferences.aiConfiguration = configuration
        let target = EditorDocument(text: "target")
        let source = EditorDocument(text: "source")
        let state = AppState(initialDocuments: [target, source], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            try? await Task.sleep(nanoseconds: 40_000_000)
            return "{\"report\":\"result\",\"references\":[{\"sourceIndex\":0,\"quote\":\"source\"}]}"
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
        XCTAssertEqual(controller.report, "result")
        XCTAssertFalse(controller.isWorking)
    }

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
    func testEditKeepsFinishedResultAndCopyDoesNotClear() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "text")
        let (controller, state) = makeTools(features: [.mermaid], documents: [document], defaults: defaults) { _, _, _, _, _, _, _ in "graph TD" }
        let observer = observeSelection(document)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.mermaid)
        for _ in 0..<1000 where controller.report.isEmpty { await Task.yield() }
        document.text += " more"
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: document.id)
        controller.copy()
        XCTAssertEqual(controller.report, "graph TD")
        XCTAssertTrue(controller.hasResult)
        controller.clearResult()
        XCTAssertFalse(controller.hasResult)
        withExtendedLifetime(state) {}
    }

    @MainActor
    func testClearResultKeepsInputs() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "text")
        let (controller, state) = makeTools(features: [.mermaid], documents: [document], defaults: defaults) { _, _, _, _, _, _, _ in "graph TD" }
        let observer = observeSelection(document)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.option = "keep me"
        controller.run(.mermaid)
        for _ in 0..<1000 where controller.report.isEmpty { await Task.yield() }
        controller.clearResult()
        XCTAssertEqual(controller.option, "keep me")
        XCTAssertTrue(controller.report.isEmpty)
        withExtendedLifetime(state) {}
    }

    @MainActor
    func testTabSwitchKeepsToolResult() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = EditorDocument(text: "text"), second = EditorDocument(text: "other")
        let (controller, state) = makeTools(features: [.mermaid], documents: [first, second], defaults: defaults) { _, _, _, _, _, _, _ in "graph TD" }
        var applied = false
        let center = NotificationCenter.default
        let selection = observeSelection(first)
        let apply = center.addObserver(forName: EditorCommandNotification.applyRangeReplacement, object: nil, queue: .main) { notification in
            applied = true
            (notification.object as? EditorRangeReplacementRequest)?.wasHandled = true
        }
        defer { center.removeObserver(selection); center.removeObserver(apply) }
        state.selectedDocumentID = first.id
        controller.run(.mermaid)
        for _ in 0..<1000 where controller.report.isEmpty { await Task.yield() }
        state.selectedDocumentID = second.id
        controller.selectedDocumentChanged()
        XCTAssertEqual(controller.report, "graph TD")
        XCTAssertEqual(controller.otherDocumentName, first.displayName)
        controller.insert()
        XCTAssertFalse(applied)
        state.selectedDocumentID = first.id
        controller.selectedDocumentChanged()
        XCTAssertNil(controller.otherDocumentName)
        controller.insert()
        XCTAssertTrue(applied)
    }

    @MainActor
    func testSettingsChangeKeepsResultAfterEdit() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "text")
        let (controller, state) = makeTools(features: [.mermaid], documents: [document], defaults: defaults) { _, _, _, _, _, _, _ in "graph TD" }
        let observer = observeSelection(document)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.run(.mermaid)
        for _ in 0..<1000 where controller.report.isEmpty { await Task.yield() }
        document.text += " more"
        state.preferences.aiFeatureModelIDs[AIFeature.summary.rawValue] = "other-model"
        controller.settingsChanged()
        XCTAssertEqual(controller.report, "graph TD")
        withExtendedLifetime(state) {}
    }

    @MainActor
    func testBlockSeparator() {
        XCTAssertEqual(AIDocumentToolsController.blockSeparator(before: 0, in: "" as NSString), "")
        XCTAssertEqual(AIDocumentToolsController.blockSeparator(before: 1, in: "a" as NSString), "\n\n")
        XCTAssertEqual(AIDocumentToolsController.blockSeparator(before: 2, in: "a\n" as NSString), "\n")
        XCTAssertEqual(AIDocumentToolsController.blockSeparator(before: 3, in: "a\n\n" as NSString), "")
        XCTAssertEqual(AIDocumentToolsController.blockSeparator(before: 3, in: "a\r\n" as NSString), "\n")
        XCTAssertEqual(AIDocumentToolsController.blockSeparator(before: 5, in: "a\r\n\r\n" as NSString), "")
    }

    @MainActor
    func testDisablingFeatureCancelsPendingResult() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.mermaid]
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
        controller.run(.mermaid)
        preferences.aiFeatures = []
        controller.settingsChanged()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(controller.report.isEmpty)
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
            let result = try AIDocumentToolsService.parseContextResponse(response(index, quote), contexts: [source])
            XCTAssertTrue(result.references.isEmpty)
            XCTAssertEqual(result.skipped, 1)
        }
        XCTAssertThrowsError(try AIDocumentToolsService.parseContextResponse("{\"report\":\"review\",\"references\":[]}", contexts: [source]))
        let empty = AIContextSnapshot(input: .file(URL(fileURLWithPath: "/tmp/empty.txt")), name: "empty.txt", text: " \u{2003}\n", document: nil, documentRevision: nil, fileRevision: nil)
        let insufficient = try AIDocumentToolsService.parseContextResponse("{\"report\":\"Not enough context\",\"references\":[]}", contexts: [empty])
        XCTAssertEqual(insufficient.report, "Not enough context")
        XCTAssertTrue(insufficient.references.isEmpty)
    }

    func testContextSkipsOnlyInvalidReferencesAndAcceptsFence() throws {
        let source = AIContextSnapshot(input: .file(URL(fileURLWithPath: "/tmp/context.txt")), name: "context.txt", text: "alpha beta", document: nil, documentRevision: nil, fileRevision: nil)
        let json = "```json\n{\"report\":\"review\",\"references\":[{\"sourceIndex\":0,\"quote\":\"alpha\"},{\"sourceIndex\":0,\"quote\":\"gamma\"}]}\n```"
        let result = try AIDocumentToolsService.parseContextResponse(json, contexts: [source])
        XCTAssertEqual(result.references.map(\.quote), ["alpha"])
        XCTAssertEqual(result.skipped, 1)
    }

    @MainActor
    private func largeSendFixture(sourceText: String, calls: @escaping @MainActor () -> Void, response: String = "{\"report\":\"review\",\"references\":[]}") throws -> (AIDocumentToolsController, EditorDocument, EditorDocument, () -> Void) {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.contextReview]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.modelID = "test-model"
        preferences.aiConfiguration = configuration
        let target = EditorDocument(text: "target")
        let source = EditorDocument(text: sourceText)
        let state = AppState(initialDocuments: [target, source], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        state.selectedDocumentID = target.id
        let controller = AIDocumentToolsController(appState: state, generate: { _, _, _, _, _, _, _ in
            await MainActor.run { calls() }
            return response
        }, loadKey: { _, _ in nil })
        let extraction = NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: target.id, range: NSRange(location: 0, length: 6), text: "target", editorRevision: 0, wasExplicitSelection: false)
        }
        return (controller, target, source, {
            NotificationCenter.default.removeObserver(extraction)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @MainActor
    private func settle(_ controller: AIDocumentToolsController) async {
        for _ in 0..<2000 where controller.isWorking { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @MainActor
    func testLargeContextWarnsThenSendAnywayRuns() async throws {
        var count = 0
        let (controller, _, source, cleanup) = try largeSendFixture(sourceText: String(repeating: "a", count: 60 * 1024), calls: { count += 1 })
        defer { cleanup() }
        controller.inputs = [.document(source.id)]
        controller.run(.contextReview)
        await settle(controller)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(controller.messageAction, .sendAnyway)
        XCTAssertEqual(controller.messageKind, .info)
        XCTAssertNil(controller.sentSummary)
        controller.sendAnyway()
        await settle(controller)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(controller.report, "review")
        let summary = try XCTUnwrap(controller.sentSummary)
        XCTAssertTrue(summary.contains(AIRequestSize.label(EditorTextSelectionSnapshot(documentID: UUID(), range: NSRange(location: 0, length: 0), text: "", editorRevision: 0, wasExplicitSelection: false), sources: 1)))
    }

    @MainActor
    func testSendAnywayAfterOptionChangeIsDropped() async throws {
        var count = 0
        let (controller, _, source, cleanup) = try largeSendFixture(sourceText: String(repeating: "a", count: 60 * 1024), calls: { count += 1 })
        defer { cleanup() }
        controller.inputs = [.document(source.id)]
        controller.run(.contextReview)
        await settle(controller)
        controller.option = "changed"
        controller.sendAnyway()
        await settle(controller)
        XCTAssertEqual(count, 0)
        XCTAssertNotEqual(controller.messageAction, .sendAnyway)
    }

    @MainActor
    func testSourceGrowthAfterWarningWarnsAgain() async throws {
        var count = 0
        let (controller, _, source, cleanup) = try largeSendFixture(sourceText: String(repeating: "a", count: 60 * 1024), calls: { count += 1 })
        defer { cleanup() }
        controller.inputs = [.document(source.id)]
        controller.run(.contextReview)
        await settle(controller)
        let first = controller.message
        source.text += String(repeating: "b", count: 20 * 1024)
        controller.sendAnyway()
        await settle(controller)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(controller.messageAction, .sendAnyway)
        XCTAssertNotEqual(controller.message, first)
    }

    @MainActor
    func testContextSkippedReferencesPostInfo() async throws {
        var count = 0
        let response = "{\"report\":\"review\",\"references\":[{\"sourceIndex\":0,\"quote\":\"source\"},{\"sourceIndex\":0,\"quote\":\"absent\"}]}"
        let (controller, _, source, cleanup) = try largeSendFixture(sourceText: "source", calls: { count += 1 }, response: response)
        defer { cleanup() }
        controller.inputs = [.document(source.id)]
        controller.run(.contextReview)
        await settle(controller)
        XCTAssertEqual(controller.references.count, 1)
        XCTAssertEqual(controller.message, L10n.tr("已跳过 %lld 个无法核对的条目。", 1))
        XCTAssertEqual(controller.messageKind, .info)
        XCTAssertNotNil(controller.sentSummary)
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
    func testOpenReferenceAfterEditKeepsResult() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = EditorDocument(text: "target")
        let source = EditorDocument(text: "A😀中文")
        let (controller, state) = makeTools(features: [.contextReview], documents: [target, source], defaults: defaults) { _, _, _, _, _, _, _ in
            "{\"report\":\"review\",\"references\":[{\"sourceIndex\":0,\"quote\":\"中文\"}]}"
        }
        let observer = observeSelection(target)
        defer { NotificationCenter.default.removeObserver(observer) }
        state.selectedDocumentID = target.id
        controller.inputs = [.document(source.id)]
        controller.run(.contextReview)
        for _ in 0..<1000 where controller.report.isEmpty { await Task.yield() }
        let reference = try XCTUnwrap(controller.references.first)
        source.text += "!"
        controller.openReference(reference)
        XCTAssertEqual(state.selectedDocumentID, target.id)
        XCTAssertEqual(controller.messageKind, .info)
        XCTAssertFalse(controller.message.isEmpty)
        XCTAssertEqual(controller.report, "review")
        XCTAssertEqual(controller.references.count, 1)
    }

    @MainActor
    func testChangedOptionKeepsResultAndMarksStale() async throws {
        let suite = "LacEditor-DocumentTools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.mermaid]
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
        controller.run(.mermaid)
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
