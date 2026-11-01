import AppKit
import Foundation
import XCTest
@testable import LacEditor

final class AICompletionTests: XCTestCase {
    private static let context = AICompletionContext(before: "text", after: "", fileType: "Markdown", heading: nil, isProse: true)

    @MainActor
    func testStaleCompletionIsNotShown() async {
        let controller = AICompletionController { _, _, _ in "continuation" }
        let coordinator = DocumentTaskCoordinator()
        let shown = expectation(description: "stale completion")
        shown.isInverted = true
        var current = true
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        controller.schedule(delay: 0, inputProvider: { Self.context }, keyProvider: { nil }, coordinator: coordinator, profile: profile,
                            isCurrent: { current }, show: { _, _ in shown.fulfill() })
        current = false
        await fulfillment(of: [shown], timeout: 1)
    }

    @MainActor
    func testCancellationDoesNotShowCompletion() async {
        let controller = AICompletionController { _, _, _ in "continuation" }
        let coordinator = DocumentTaskCoordinator()
        let shown = expectation(description: "cancelled completion")
        shown.isInverted = true
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        controller.schedule(delay: 0, inputProvider: { Self.context }, keyProvider: { nil }, coordinator: coordinator, profile: profile,
                            isCurrent: { true }, show: { _, _ in shown.fulfill() })
        controller.cancel()
        await fulfillment(of: [shown], timeout: 1)
    }

    @MainActor
    func testNoContextSkipsRequest() async {
        var calls = 0
        let controller = AICompletionController { _, _, _ in calls += 1; return "continuation" }
        let coordinator = DocumentTaskCoordinator()
        let shown = expectation(description: "no context")
        shown.isInverted = true
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        controller.schedule(delay: 0, inputProvider: { nil }, keyProvider: { nil }, coordinator: coordinator, profile: profile,
                            isCurrent: { true }, show: { _, _ in shown.fulfill() })
        await fulfillment(of: [shown], timeout: 0.5)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testRepeatedRequestComesFromCache() async {
        var calls = 0
        let controller = AICompletionController { _, _, _ in calls += 1; return " more" }
        let coordinator = DocumentTaskCoordinator()
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        for _ in 0..<2 {
            let shown = expectation(description: "completion")
            controller.schedule(delay: 0, inputProvider: { Self.context }, keyProvider: { nil }, coordinator: coordinator, profile: profile,
                                isCurrent: { true }, show: { text, _ in XCTAssertEqual(text, " more"); shown.fulfill() })
            await fulfillment(of: [shown], timeout: 2)
        }
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testFailureIsReportedWithoutServerDetail() async {
        let controller = AICompletionController { _, _, _ in throw AIError.http(404, "secret detail") }
        let coordinator = DocumentTaskCoordinator()
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        let failed = expectation(description: "failure")
        controller.schedule(delay: 0, inputProvider: { Self.context }, keyProvider: { nil }, coordinator: coordinator, profile: profile,
                            isCurrent: { true }, show: { _, _ in XCTFail("Failure displayed a completion") },
                            fail: { message in
                                XCTAssertEqual(message, L10n.tr("自动续写失败：%@", L10n.tr("AI 服务返回错误（HTTP %d）", 404)))
                                XCTAssertFalse(message.contains("secret"))
                                failed.fulfill()
                            })
        await fulfillment(of: [failed], timeout: 2)
    }

    @MainActor
    func testCancelledRequestIsNotReportedAsFailure() async {
        let controller = AICompletionController { _, _, _ in throw CancellationError() }
        let coordinator = DocumentTaskCoordinator()
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        let failed = expectation(description: "cancellation")
        failed.isInverted = true
        controller.schedule(delay: 0, inputProvider: { Self.context }, keyProvider: { nil }, coordinator: coordinator, profile: profile,
                            isCurrent: { true }, show: { _, _ in }, fail: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 0.5)
    }

    @MainActor
    func testShowsOnlyVisibleFirstLine() async {
        let controller = AICompletionController { _, _, _ in " continuation\nhidden" }
        let coordinator = DocumentTaskCoordinator()
        let shown = expectation(description: "completion")
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        controller.schedule(delay: 0, inputProvider: { Self.context }, keyProvider: { nil }, coordinator: coordinator, profile: profile,
                            isCurrent: { true }, show: { text, _ in
                                XCTAssertEqual(text, " continuation")
                                shown.fulfill()
                            })
        await fulfillment(of: [shown], timeout: 2)
    }
    @MainActor
    func testInputAndKeyAreNotReadBeforeDebounce() async {
        let controller = AICompletionController { _, _, _ in "continuation" }
        let coordinator = DocumentTaskCoordinator()
        var inputReads = 0
        var keyReads = 0
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        controller.schedule(delay: 700_000_000, inputProvider: { inputReads += 1; return Self.context },
                            keyProvider: { keyReads += 1; return nil },
                            coordinator: coordinator, profile: profile,
                            isCurrent: { true }, show: { _, _ in XCTFail("Cancelled request displayed") })
        XCTAssertEqual(inputReads, 0)
        XCTAssertEqual(keyReads, 0)
        controller.cancel()
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(inputReads, 0)
        XCTAssertEqual(keyReads, 0)
    }

    @MainActor
    func testChangedKeyPreventsShowingCompletion() async {
        var key: String? = "first"
        let controller = AICompletionController { _, _, _ in key = "second"; return "continuation" }
        let coordinator = DocumentTaskCoordinator()
        let shown = expectation(description: "outdated key")
        shown.isInverted = true
        var profile = AIModelProfile.default(for: .text)
        profile.isEnabled = true
        controller.schedule(delay: 0, inputProvider: { Self.context }, keyProvider: { key }, coordinator: coordinator,
                            profile: profile, isCurrent: { true }, show: { _, _ in shown.fulfill() })
        await fulfillment(of: [shown], timeout: 1)
    }

    @MainActor
    func testGeneratedReplacementUsesCurrentUTF16Range() throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "中文😀", language: .plainText)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: document.text)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: true)
        view.setSelectedRange(NSRange(location: storage.length, length: 0))
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        let snapshot = try XCTUnwrap(extraction.result)
        XCTAssertEqual(snapshot.range.length, 4)
        let stale = EditorRangeReplacementRequest(documentID: document.id, range: NSRange(location: 4, length: 0), originalText: "", replacementText: "!", expectedEditorRevision: snapshot.editorRevision + 1, actionName: "AI")
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: stale)
        XCTAssertFalse(stale.wasHandled)
        XCTAssertEqual(view.string, "中文😀")
        let request = EditorRangeReplacementRequest(documentID: document.id, range: NSRange(location: 4, length: 0), originalText: "", replacementText: "!", expectedEditorRevision: snapshot.editorRevision, actionName: "AI")
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertTrue(request.wasHandled)
        XCTAssertEqual(view.string, "中文😀!")
    }

    @MainActor
    func testChangingCompletionModelClearsVisibleCompletion() throws {
        _ = NSApplication.shared
        let suite = "LacEditor-AICompletion-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let document = EditorDocument(text: "text")
        let coordinator = EditorTextView.Coordinator(document: document)
        let view = LacTextView(frame: .zero)
        coordinator.textView = view
        coordinator.configureAIAssistance(preferences: preferences)
        view.completionText = "old completion"
        preferences.aiFeatureModelIDs[AIFeature.completion.rawValue] = "another-model"
        coordinator.configureAIAssistance(preferences: preferences)
        XCTAssertNil(view.completionText)
    }

}
