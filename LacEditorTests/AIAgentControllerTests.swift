import XCTest
@testable import LacEditor

private final class AgentWebProtocol: URLProtocol {
    static var requests: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request.url!)
        let object: [String: Any]
        if request.url?.path == "/search" {
            object = ["data": [["title": "Page A", "url": "https://example.org/a", "description": "snippet A"],
                               ["title": "Page B", "url": "https://example.org/b", "description": "snippet B"]]]
        } else {
            object = ["data": ["title": "T", "url": "https://example.org/x", "content": "page text"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Сценарий ответов модели без сети: очередь ответов и запись всех запросов.
private final class AgentStepScript: @unchecked Sendable {
    enum Reply { case text(String), calls([(name: String, arguments: String)]), fail(Error) }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [(items: [[String: Any]], toolChoice: String, tools: [String])] = []
    private(set) var profiles: [AIModelProfile] = []
    private(set) var keys: [String?] = []
    var usage = AIUsage(inputTokens: 10, outputTokens: 2)
    var onStep: ((Int) async -> Void)?

    init(_ replies: [Reply]) { self.replies = replies }

    func step(_ items: [[String: Any]], _ choice: String, _ tools: [AIToolDefinition], _ profile: AIModelProfile, _ key: String?) async throws -> AIAgentStep {
        let index = lock.withLock { () -> Int in
            requests.append((items, choice, tools.map(\.name))); profiles.append(profile); keys.append(key)
            return requests.count - 1
        }
        await onStep?(index)
        let reply: Reply = lock.withLock { replies.isEmpty ? .text("end") : replies.removeFirst() }
        switch reply {
        case .fail(let error): throw error
        case .text(let text): return AIAgentStep(calls: [], echoed: [], text: text, usage: usage)
        case .calls(let calls):
            let list = calls.enumerated().map { AIToolCall(id: "c\(index)-\($0.offset)", name: $0.element.name, arguments: $0.element.arguments) }
            // Эхо в форме нужного API: очистке контекста нужны пары вызов-ответ
            let echoed: [[String: Any]] = profile.api == .responses
                ? list.map { ["type": "function_call", "call_id": $0.id, "name": $0.name, "arguments": $0.arguments] }
                : [["role": "assistant", "content": "",
                    "tool_calls": list.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }]]
            return AIAgentStep(calls: list, echoed: echoed, text: nil, usage: usage)
        }
    }

    func serialized(_ index: Int) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: requests[index].items)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class AIAgentControllerTests: XCTestCase {
    private var directories: [URL] = []

    override func setUp() {
        AgentWebProtocol.requests = []
    }

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url.standardizedFileURL)
        return url.standardizedFileURL
    }

    private struct Setup {
        let controller: AIAgentController
        let state: AppState
        let preferences: AppPreferences
        let script: AgentStepScript
        let documents: [EditorDocument]
    }

    @MainActor
    private func make(_ replies: [AgentStepScript.Reply], documents: [EditorDocument]? = nil, web: Bool = false, enabled: Bool = true,
                      limits: AIAgentLimits = AIAgentLimits(), loadKey: @escaping (AIRole, String) throws -> String? = { _, _ in nil }) throws -> Setup {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditor-AIAgent-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.agent]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = enabled
        configuration.text.modelID = "test-model"
        preferences.aiConfiguration = configuration
        var jina = JinaConfiguration()
        jina.searchEnabled = web
        jina.readerEnabled = false
        jina.searchEndpoint = "https://jina.example/search"
        jina.readerEndpoint = "https://jina.example/read"
        preferences.jinaConfiguration = jina
        let docs = documents ?? [EditorDocument(text: "Whole text")]
        let state = AppState(initialDocuments: docs, recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let script = AgentStepScript(replies)
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.protocolClasses = [AgentWebProtocol.self]
        let controller = AIAgentController(appState: state, step: { try await script.step($0, $1, $2, $3, $4) }, loadKey: loadKey,
                                           loadJinaKey: { _, _ in nil }, jinaClient: JinaClient(session: URLSession(configuration: urlConfiguration)),
                                           limits: limits)
        return Setup(controller: controller, state: state, preferences: preferences, script: script, documents: docs)
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @MainActor
    private func send(_ controller: AIAgentController, _ text: String) async {
        controller.draft = text
        controller.send()
        for _ in 0..<1000 {
            _ = await waitFor { !controller.isWorking || controller.approval != nil }
            guard controller.isWorking, let approval = controller.approval else { return }
            switch approval.content {
            case .document: controller.resolve(.allowOnce)
            case .webSearch: return
            }
        }
    }

    @MainActor
    private func settle(_ controller: AIAgentController) async {
        _ = await waitFor { !controller.isWorking }
    }

    /// Шаг с номером `index` ждёт, пока тест не откроет ворота.
    private func hold(_ script: AgentStepScript, at index: Int = 0) -> AsyncStream<Void>.Continuation {
        let gate = AsyncStream<Void>.makeStream()
        script.onStep = { current in
            guard current == index else { return }
            for await _ in gate.stream { break }
        }
        return gate.continuation
    }

    private func call(_ name: String, _ arguments: String = "{}") -> AgentStepScript.Reply { .calls([(name, arguments)]) }

    // MARK: - Функция

    func testFeatureIsOffByDefaultAndDescribed() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditor-AIAgentDefaults-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.aiFeatures.contains(.agent))
        XCTAssertTrue(AIFeature.features(in: .analysis).contains(.agent))
        XCTAssertFalse(AIFeature.agent.needs.isEmpty)
        XCTAssertFalse(AIFeature.agent.result.isEmpty)
        XCTAssertFalse(AIFeature.agent.detail.isEmpty)
        XCTAssertEqual(AIFeature.agent.role, .text)
        XCTAssertTrue(AIFeature.agent.isDocumentTool)
        XCTAssertEqual(AIFeature(rawValue: "agent"), .agent)
    }

    // MARK: - Запуск

    @MainActor
    func testPlainAnswerFinishesOneTurn() async throws {
        let setup = try make([.text("done")])
        await send(setup.controller, "Do it")
        let controller = setup.controller
        XCTAssertEqual(controller.turns.count, 1)
        XCTAssertEqual(controller.turns[0].status, .answered)
        XCTAssertEqual(controller.turns[0].answer, "done")
        XCTAssertEqual(controller.turns[0].question, "Do it")
        XCTAssertFalse(controller.isWorking)
        XCTAssertFalse(controller.canResume)
        XCTAssertEqual(controller.counters.rounds, 1)
        XCTAssertEqual(controller.counters.usage, AIUsage(inputTokens: 10, outputTokens: 2))
        XCTAssertEqual(controller.draft, "")
    }

    @MainActor
    func testReadsUnsavedTextOfOpenDocument() async throws {
        let document = EditorDocument(text: "alpha\nunsaved-beta")
        let setup = try make([call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#), .text("ok")], documents: [document])
        await send(setup.controller, "Read")
        let entry = try XCTUnwrap(setup.controller.turns.first?.journal.first)
        XCTAssertEqual(entry.kind, .readDocument)
        XCTAssertEqual(entry.files.first?.source, .unsaved)
        XCTAssertTrue(setup.script.serialized(1).contains("unsaved-beta"))
        XCTAssertTrue(setup.script.serialized(0).contains("open:\(document.id.uuidString)"))
    }

    @MainActor
    func testExternalDocumentConsentIsPerDocumentAndNotRepeated() async throws {
        let first = EditorDocument(text: "FIRST-SECRET"), second = EditorDocument(text: "SECOND-SECRET")
        func read(_ document: EditorDocument) -> AgentStepScript.Reply {
            call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#)
        }
        let setup = try make([read(first), read(first), read(second), .text("done"), read(first), .text("after")], documents: [first, second])
        setup.controller.draft = "Read"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        guard case .document(let firstID, _, _) = try XCTUnwrap(setup.controller.approval).content else { return XCTFail("Expected document approval") }
        XCTAssertEqual(firstID, first.id)
        setup.controller.resolve(.allowOnce)
        _ = await waitFor { setup.controller.approval != nil }
        guard case .document(let secondID, _, _) = try XCTUnwrap(setup.controller.approval).content else { return XCTFail("Expected second document approval") }
        XCTAssertEqual(secondID, second.id)
        XCTAssertEqual(setup.script.requests.count, 3, "The second read of the approved document must not prompt")
        setup.controller.resolve(.allowOnce)
        await settle(setup.controller)
        XCTAssertEqual(setup.controller.turns.first?.status, .answered)
        XCTAssertEqual(setup.controller.turns.first?.journal.map(\.kind), [.readDocument, .readDocument, .readDocument])
        XCTAssertTrue(setup.script.serialized(3).contains("FIRST-SECRET"))
        XCTAssertTrue(setup.script.serialized(3).contains("SECOND-SECRET"))
        setup.controller.draft = "Follow up"; setup.controller.send()
        await settle(setup.controller)
        XCTAssertNil(setup.controller.approval, "Consent lasts for the whole conversation")
        XCTAssertEqual(setup.controller.turns.last?.answer, "after")
        XCTAssertEqual(setup.script.requests.count, 6)
    }

    @MainActor
    func testDeniedExternalDocumentSendsNoSecret() async throws {
        let document = EditorDocument(text: "DO-NOT-SEND-THIS-SECRET")
        let setup = try make([call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#), .text("without document")], documents: [document])
        setup.controller.draft = "Read"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        setup.controller.resolve(.deny)
        await settle(setup.controller)
        XCTAssertEqual(setup.script.requests.count, 2)
        XCTAssertFalse(setup.script.serialized(1).contains("DO-NOT-SEND-THIS-SECRET"))
        XCTAssertTrue(setup.script.serialized(1).contains("access was declined"))
        let entry = try XCTUnwrap(setup.controller.turns.first?.journal.first)
        XCTAssertEqual(entry.kind, .rejected)
        XCTAssertTrue(entry.files.isEmpty)
        XCTAssertNil(entry.fileBytes)
        XCTAssertEqual(setup.controller.turns.first?.status, .answered)
    }

    @MainActor
    func testWorkspaceOpenDocumentDoesNotNeedConsent() async throws {
        let root = try temporaryDirectory()
        let document = EditorDocument(text: "workspace text")
        document.url = root.appendingPathComponent("note.md")
        let setup = try make([call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#), .text("done")], documents: [document])
        setup.state.folderWorkspace.setRoot(root)
        setup.controller.draft = "Read"; setup.controller.send()
        await settle(setup.controller)
        XCTAssertNil(setup.controller.approval)
        XCTAssertEqual(setup.controller.turns.first?.status, .answered)
        XCTAssertTrue(setup.script.serialized(1).contains("workspace text"))
    }

    @MainActor
    func testDocumentConsentResetsAfterStopNewConversationAndRootChange() async throws {
        let document = EditorDocument(text: "secret")
        let read = call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#)
        let setup = try make([read, .text("one"), read, .text("two"), read, .text("three"), read, .text("four")], documents: [document])

        func beginAndWaitForApproval() async {
            setup.controller.draft = "Read"; setup.controller.send()
            _ = await waitFor { setup.controller.approval != nil }
        }
        await beginAndWaitForApproval()
        setup.controller.resolve(.allowOnce)
        await settle(setup.controller)
        setup.controller.stop()

        await beginAndWaitForApproval()
        XCTAssertNotNil(setup.controller.approval, "A new run after Stop must ask again")
        setup.controller.resolve(.allowOnce)
        await settle(setup.controller)
        setup.controller.newConversation()

        await beginAndWaitForApproval()
        XCTAssertNotNil(setup.controller.approval, "A new conversation must ask again")
        setup.controller.resolve(.allowOnce)
        await settle(setup.controller)
        setup.state.folderWorkspace.setRoot(try temporaryDirectory())

        await beginAndWaitForApproval()
        XCTAssertNotNil(setup.controller.approval, "A root change must ask again")
        setup.controller.stop()
        await settle(setup.controller)
    }

    @MainActor
    func testStopAndSettingsChangeReleaseDocumentApproval() async throws {
        let document = EditorDocument(text: "SECRET-WAITING")
        let read = call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#)
        let stopped = try make([read, .text("late")], documents: [document])
        stopped.controller.draft = "Read"; stopped.controller.send()
        _ = await waitFor { stopped.controller.approval != nil }
        stopped.controller.stop()
        XCTAssertNil(stopped.controller.approval)
        stopped.controller.resolve(.allowOnce)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(stopped.script.requests.count, 1)
        XCTAssertFalse(stopped.script.serialized(0).contains("SECRET-WAITING"))

        let other = EditorDocument(text: "SECRET-SETTINGS")
        let otherRead = call("read_document", #"{"path":"open:\#(other.id.uuidString)"}"#)
        let changed = try make([otherRead, .text("late")], documents: [other])
        changed.controller.draft = "Read"; changed.controller.send()
        _ = await waitFor { changed.controller.approval != nil }
        changed.preferences.aiFeatureModelIDs = ["agent": "other"]
        changed.controller.settingsChanged()
        XCTAssertNil(changed.controller.approval)
        XCTAssertFalse(changed.controller.isWorking)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(changed.script.requests.count, 1)
        XCTAssertFalse(changed.script.serialized(0).contains("SECRET-SETTINGS"))
    }

    @MainActor
    func testToolListHasNoWebSearchByDefaultAndNoUrlTools() async throws {
        let setup = try make([.text("a")])
        await send(setup.controller, "q")
        XCTAssertEqual(setup.script.requests[0].tools, AIAgentTools.definitions.map(\.name))
        XCTAssertFalse(setup.script.requests[0].tools.contains("web_search"))
        for name in ["read_url", "fetch", "open_url", "open", "shell"] { XCTAssertFalse(setup.script.requests[0].tools.contains(name)) }
    }

    @MainActor
    func testWebSearchToolNeedsSwitchAndJinaSearch() async throws {
        let on = try make([.text("a")], web: true)
        XCTAssertTrue(on.controller.isWebSearchAvailable)
        XCTAssertFalse(on.controller.webSearchEnabled)
        on.controller.webSearchEnabled = true
        await send(on.controller, "q")
        XCTAssertTrue(on.script.requests[0].tools.contains("web_search"))

        let off = try make([.text("a")], web: false)
        XCTAssertFalse(off.controller.isWebSearchAvailable)
        off.controller.webSearchEnabled = true
        await send(off.controller, "q")
        XCTAssertFalse(off.script.requests[0].tools.contains("web_search"))
    }

    @MainActor
    func testProfileKeyAndDisabledProfile() async throws {
        let setup = try make([.text("a")], loadKey: { _, _ in "secret" })
        setup.preferences.aiFeatureModelIDs = ["agent": "agent-model"]
        await send(setup.controller, "q")
        XCTAssertEqual(setup.script.profiles.first?.modelID, "agent-model")
        XCTAssertEqual(setup.script.keys.first ?? nil, "secret")

        let disabled = try make([.text("a")], enabled: false)
        await send(disabled.controller, "q")
        XCTAssertEqual(disabled.controller.message, L10n.tr("AI 功能已关闭"))
        XCTAssertEqual(disabled.controller.messageAction, .openSettings)
        XCTAssertTrue(disabled.script.requests.isEmpty)
        XCTAssertTrue(disabled.controller.turns.isEmpty)
    }

    // MARK: - Остановка, пауза, отмена

    @MainActor
    func testStopDropsLateAnswer() async throws {
        let setup = try make([.text("late")])
        let gate = hold(setup.script)
        setup.controller.draft = "q"
        setup.controller.send()
        _ = await waitFor { !setup.script.requests.isEmpty }
        setup.controller.stop()
        XCTAssertFalse(setup.controller.isWorking)
        XCTAssertEqual(setup.controller.turns.last?.status, .stopped)
        XCTAssertFalse(setup.controller.canResume)
        gate.yield()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(setup.controller.turns.last?.answer, "")
        XCTAssertEqual(setup.controller.turns.last?.status, .stopped)
        XCTAssertFalse(setup.controller.hasConversation)
    }

    @MainActor
    func testPauseAndResumeRepeatSameRequest() async throws {
        let setup = try make([.fail(AIError.network), .text("fine")])
        await send(setup.controller, "q")
        XCTAssertTrue(setup.controller.canResume)
        XCTAssertEqual(setup.controller.turns.last?.status, .paused)
        XCTAssertEqual(setup.controller.messageAction, .retry)
        setup.controller.resume()
        await settle(setup.controller)
        XCTAssertEqual(setup.controller.turns.last?.status, .answered)
        XCTAssertEqual(setup.controller.turns.last?.answer, "fine")
        XCTAssertFalse(setup.controller.canResume)
        XCTAssertEqual(setup.script.serialized(0), setup.script.serialized(1))
    }

    @MainActor
    func testServerWithoutToolsMessageForClientErrors() async throws {
        for status in [400, 404, 422, 501] {
            let setup = try make([.fail(AIError.http(status, nil))])
            await send(setup.controller, "q")
            XCTAssertTrue(setup.controller.canResume, "\(status)")
            XCTAssertNil(setup.controller.messageAction, "\(status)")
            XCTAssertTrue(setup.controller.message.contains(L10n.tr("服务器拒绝了带工具的请求。代理需要函数调用（tools）支持，请换用支持该功能的模型或服务器。")))
        }
        let server = try make([.fail(AIError.http(500, nil))])
        await send(server.controller, "q")
        XCTAssertEqual(server.controller.messageAction, .retry)
        XCTAssertFalse(server.controller.message.contains(L10n.tr("服务器拒绝了带工具的请求。代理需要函数调用（tools）支持，请换用支持该功能的模型或服务器。")))
    }

    @MainActor
    func testSettingsChangesCancelTheRun() async throws {
        // Смена модели функции
        let model = try make([.text("late")])
        var gate = hold(model.script)
        model.controller.draft = "q"; model.controller.send()
        _ = await waitFor { !model.script.requests.isEmpty }
        model.preferences.aiFeatureModelIDs = ["agent": "other-model"]
        model.controller.settingsChanged()
        XCTAssertFalse(model.controller.isWorking)
        gate.yield()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.controller.turns.last?.answer, "")
        XCTAssertEqual(model.controller.turns.last?.status, .stopped)

        // Смена ключа
        var keyCalls = 0
        let key = try make([.text("late")], loadKey: { _, _ in keyCalls += 1; return keyCalls > 2 ? "new" : "old" })
        gate = hold(key.script)
        key.controller.draft = "q"; key.controller.send()
        _ = await waitFor { !key.script.requests.isEmpty }
        key.controller.settingsChanged()
        XCTAssertFalse(key.controller.isWorking)
        gate.yield()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(key.controller.turns.last?.answer, "")

        // Выключение функции сбрасывает разговор
        let off = try make([.text("late")])
        gate = hold(off.script)
        off.controller.draft = "q"; off.controller.send()
        _ = await waitFor { !off.script.requests.isEmpty }
        off.preferences.aiFeatures = []
        off.controller.settingsChanged()
        XCTAssertFalse(off.controller.isWorking)
        XCTAssertTrue(off.controller.turns.isEmpty)
        XCTAssertFalse(off.controller.hasConversation)
        gate.yield()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(off.controller.turns.isEmpty)
    }

    @MainActor
    func testRootChangeCancelsTheRun() async throws {
        let first = try temporaryDirectory(), second = try temporaryDirectory()
        let setup = try make([.text("late")])
        setup.state.folderWorkspace.setRoot(first)
        let gate = hold(setup.script)
        setup.controller.draft = "q"; setup.controller.send()
        _ = await waitFor { !setup.script.requests.isEmpty }
        setup.state.folderWorkspace.setRoot(second)
        XCTAssertFalse(setup.controller.isWorking)
        gate.yield()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(setup.controller.turns.last?.answer, "")
        XCTAssertEqual(setup.controller.turns.last?.status, .stopped)
    }

    @MainActor
    func testDocumentEditsAndPanelStateDoNotCancel() async throws {
        let document = EditorDocument(text: "old text")
        let other = EditorDocument(text: "other")
        let setup = try make([call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#),
                              call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#), .text("ok")], documents: [document, other])
        setup.script.onStep = { index in
            if index == 1 {
                await MainActor.run {
                    document.text = "new text"
                    setup.state.selectedDocumentID = other.id
                    setup.state.isAIWritingVisible = false
                }
            }
        }
        await send(setup.controller, "Read")
        XCTAssertEqual(setup.controller.turns.last?.status, .answered)
        XCTAssertTrue(setup.script.serialized(2).contains("old text"))
        XCTAssertFalse(setup.script.serialized(2).contains("new text"))
    }

    // MARK: - Разговор

    @MainActor
    func testSecondQuestionKeepsHistoryAndAccumulatesCounters() async throws {
        let document = EditorDocument(text: "first version")
        let setup = try make([.text("one"), .text("two")], documents: [document])
        await send(setup.controller, "first")
        let afterFirst = setup.controller.counters
        document.text = "second version"
        await send(setup.controller, "second")
        XCTAssertEqual(setup.controller.turns.map(\.answer), ["one", "two"])
        XCTAssertTrue(setup.script.serialized(1).contains("first"))
        XCTAssertTrue(setup.script.serialized(1).contains("one"))
        XCTAssertTrue(setup.script.serialized(1).contains("second"))
        XCTAssertGreaterThan(setup.controller.counters.sentBytes, afterFirst.sentBytes)
        XCTAssertEqual(setup.controller.counters.usage.inputTokens, 20)
    }

    @MainActor
    func testNewConversationClearsHistoryButKeepsSwitchAndDraft() async throws {
        let setup = try make([.text("one"), .text("two")], web: true)
        setup.controller.webSearchEnabled = true
        await send(setup.controller, "first")
        XCTAssertTrue(setup.controller.hasConversation)
        setup.controller.draft = "typed"
        setup.controller.newConversation()
        XCTAssertTrue(setup.controller.turns.isEmpty)
        XCTAssertEqual(setup.controller.counters, AIAgentCounters())
        XCTAssertEqual(setup.controller.message, "")
        XCTAssertFalse(setup.controller.hasConversation)
        XCTAssertTrue(setup.controller.webSearchEnabled)
        XCTAssertEqual(setup.controller.draft, "typed")
        setup.controller.send()
        await settle(setup.controller)
        XCTAssertEqual(setup.controller.turns.count, 1)
        XCTAssertFalse(setup.script.serialized(1).contains("first"))
    }

    @MainActor
    func testJournalKeepsCallOrderAndSentBytesGrow() async throws {
        let setup = try make([.calls([("list_documents", "{}"), ("document_outline", #"{"path":"open:none"}"#)]), call("list_documents"), .text("ok")])
        await send(setup.controller, "q")
        XCTAssertEqual(setup.controller.turns[0].journal.map(\.tool), ["list_documents", "document_outline", "list_documents"])
        XCTAssertGreaterThan(setup.controller.counters.sentBytes, setup.controller.counters.contextBytes)
    }

    @MainActor
    func testRoundLimitGivesPartial() async throws {
        var limits = AIAgentLimits()
        limits.maxRounds = 2
        let setup = try make([call("list_documents"), call("list_documents"), call("list_documents")], limits: limits)
        await send(setup.controller, "q")
        XCTAssertEqual(setup.controller.turns[0].status, .partial)
        XCTAssertEqual(setup.script.requests.last?.toolChoice, "none")
        XCTAssertEqual(setup.controller.message, L10n.tr("已达到步骤上限，未能给出总结。"))
    }

    @MainActor
    func testMissingUsageGivesZeros() async throws {
        let setup = try make([.text("a")])
        setup.script.usage = AIUsage()
        await send(setup.controller, "q")
        XCTAssertEqual(setup.controller.counters.usage, AIUsage())
    }

    // MARK: - Веб-поиск

    @MainActor
    private func makeWeb(_ replies: [AgentStepScript.Reply], limits: AIAgentLimits = AIAgentLimits()) throws -> Setup {
        let setup = try make(replies, web: true, limits: limits)
        setup.controller.webSearchEnabled = true
        return setup
    }

    private func search(_ query: String = "swift") -> AgentStepScript.Reply { call("web_search", #"{"query":"\#(query)"}"#) }

    @MainActor
    func testAllowOnceSearchesOnceThenAsksAgain() async throws {
        let setup = try makeWeb([.calls([("web_search", #"{"query":"one"}"#)]), search("two"), .text("done")])
        setup.controller.draft = "q"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        XCTAssertEqual(setup.controller.approval?.query, "one")
        XCTAssertTrue(AgentWebProtocol.requests.isEmpty)
        setup.controller.resolve(.allowOnce)
        _ = await waitFor { setup.controller.approval != nil }
        XCTAssertEqual(setup.controller.approval?.query, "two")
        XCTAssertEqual(AgentWebProtocol.requests.filter { $0.path == "/search" }.count, 1)
        _ = await waitFor { setup.controller.turns.first?.journal.count == 3 }
        let journal = try XCTUnwrap(setup.controller.turns.first?.journal)
        XCTAssertEqual(journal.map(\.kind), [.webSearch, .webPage, .webPage])
        XCTAssertGreaterThan(journal[1].sentBytes, 0)
        XCTAssertEqual(journal[1].subject, "https://example.org/a")
        setup.controller.resolve(.deny)
        await settle(setup.controller)
        XCTAssertEqual(setup.controller.turns.first?.status, .answered)
    }

    @MainActor
    func testAllowInRunSkipsNextApprovalButNotNextQuestion() async throws {
        let setup = try makeWeb([search("one"), search("two"), .text("a1"), search("three"), .text("a2")])
        setup.controller.draft = "q"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        setup.controller.resolve(.allowInRun)
        await settle(setup.controller)
        XCTAssertNil(setup.controller.approval)
        XCTAssertEqual(setup.controller.turns[0].status, .answered)
        XCTAssertEqual(AgentWebProtocol.requests.filter { $0.path == "/search" }.count, 2)
        setup.controller.draft = "again"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        XCTAssertEqual(setup.controller.approval?.query, "three")
        setup.controller.resolve(.deny)
        await settle(setup.controller)
    }

    @MainActor
    func testDenyDoesNotUseNetworkAndTellsModel() async throws {
        let setup = try makeWeb([search(), .text("without web")])
        setup.controller.draft = "q"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        setup.controller.resolve(.deny)
        await settle(setup.controller)
        XCTAssertTrue(AgentWebProtocol.requests.isEmpty)
        XCTAssertTrue(setup.script.serialized(1).contains("declined"))
        XCTAssertEqual(setup.controller.turns[0].journal.map(\.kind), [.rejected])
        XCTAssertEqual(setup.controller.turns[0].journal.first?.subject, "swift")
        XCTAssertEqual(setup.controller.turns[0].status, .answered)
    }

    @MainActor
    func testCancelWhileWaitingReleasesApproval() async throws {
        let setup = try makeWeb([search(), .text("late")])
        setup.controller.draft = "q"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        setup.controller.stop()
        XCTAssertNil(setup.controller.approval)
        setup.controller.resolve(.allowOnce)
        // Старая задача успевает свернуться: сетевых запросов она не делает
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(AgentWebProtocol.requests.isEmpty)
        XCTAssertEqual(setup.controller.turns.last?.status, .stopped)

        let changed = try makeWeb([search(), .text("late")])
        changed.controller.draft = "q"; changed.controller.send()
        _ = await waitFor { changed.controller.approval != nil }
        changed.preferences.aiFeatureModelIDs = ["agent": "other"]
        changed.controller.settingsChanged()
        XCTAssertNil(changed.controller.approval)
        XCTAssertFalse(changed.controller.isWorking)
    }

    @MainActor
    func testBadArgumentsAndLimitDoNotAskApproval() async throws {
        var limits = AIAgentLimits()
        limits.maxWebSearches = 1
        let setup = try makeWeb([call("web_search", "{}"), search("one"), search("two"), .text("done")], limits: limits)
        setup.controller.draft = "q"; setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        // Неверные аргументы уже обработаны без карточки; теперь первый настоящий поиск
        XCTAssertEqual(setup.controller.approval?.query, "one")
        XCTAssertTrue(AgentWebProtocol.requests.isEmpty)
        setup.controller.resolve(.allowOnce)
        await settle(setup.controller)
        XCTAssertNil(setup.controller.approval)
        XCTAssertEqual(AgentWebProtocol.requests.filter { $0.path == "/search" }.count, 1)
        XCTAssertEqual(setup.controller.turns[0].status, .answered)
    }

    @MainActor
    func testLinksAreAllowedOnlyFromWebSources() async throws {
        let web = try makeWeb([search(), .text("see [a](https://example.org/a) and [z](https://evil.example/z)")])
        web.controller.draft = "q"; web.controller.send()
        _ = await waitFor { web.controller.approval != nil }
        web.controller.resolve(.allowOnce)
        await settle(web.controller)
        let turn = try XCTUnwrap(web.controller.turns.first)
        XCTAssertEqual(turn.allowedURLs, [URL(string: "https://example.org/a")!, URL(string: "https://example.org/b")!])
        let links = AttributedString(modelMarkdown: turn.answer, allowedURLs: turn.allowedURLs).runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.org/a")!])

        let plain = try make([.text("see [a](https://example.org/a)")])
        await send(plain.controller, "q")
        XCTAssertTrue(plain.controller.turns[0].allowedURLs.isEmpty)
    }

    // MARK: - Снимок

    func testRelativePathInsideAndOutsideRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/agent-root", isDirectory: true)
        XCTAssertEqual(AIAgentController.relativePath(of: root.appendingPathComponent("a/b.md"), root: root), "a/b.md")
        XCTAssertNil(AIAgentController.relativePath(of: URL(fileURLWithPath: "/tmp/other/b.md"), root: root))
        XCTAssertNil(AIAgentController.relativePath(of: URL(fileURLWithPath: "/tmp/agent-root-2/b.md"), root: root))
        XCTAssertNil(AIAgentController.relativePath(of: root, root: root))
        XCTAssertNil(AIAgentController.relativePath(of: nil, root: root))
        XCTAssertNil(AIAgentController.relativePath(of: root.appendingPathComponent("a.md"), root: nil))
    }

    @MainActor
    func testScopeUsesUnsavedTextAndRelativePaths() throws {
        let root = try temporaryDirectory()
        let inside = EditorDocument(text: "saved")
        inside.url = root.appendingPathComponent("note.md")
        inside.text = "unsaved edit"
        let outside = EditorDocument(text: "outside")
        outside.url = URL(fileURLWithPath: "/tmp/elsewhere/other.md")
        let nameless = EditorDocument(text: "nameless")
        let setup = try make([], documents: [inside, outside, nameless])
        setup.state.folderWorkspace.setRoot(root)
        let scope = AIAgentController.makeScope(appState: setup.state)
        XCTAssertEqual(scope.root?.path, root.path)
        let byID = Dictionary(uniqueKeysWithValues: scope.openDocuments.map { ($0.id, $0) })
        XCTAssertEqual(byID[inside.id]?.relativePath, "note.md")
        XCTAssertEqual(byID[inside.id]?.text, "unsaved edit")
        XCTAssertNil(byID[outside.id]?.relativePath)
        XCTAssertNil(byID[nameless.id]?.relativePath)
    }

    // MARK: - Локализация

    // MARK: - План и контекст

    private static let planArguments = #"{"items":[{"title":"A","status":"done"},{"title":"B","status":"pending"}],"notes":"N1"}"#

    private func readingDocument() -> (document: EditorDocument, read: AgentStepScript.Reply) {
        let text = (0..<30).map { "line \($0) " + String(repeating: "w", count: 100) }.joined(separator: "\n")
        let document = EditorDocument(text: text)
        return (document, call("read_document", #"{"path":"open:\#(document.id.uuidString)"}"#))
    }

    @MainActor
    func testUpdatePlanShowsInPanelAndInNextRequest() async throws {
        let setup = try make([call("update_plan", Self.planArguments), .text("ok")])
        await send(setup.controller, "q")
        XCTAssertEqual(setup.controller.plan.items.map(\.title), ["A", "B"])
        XCTAssertEqual(setup.controller.plan.notes, "N1")
        XCTAssertEqual(setup.controller.turns[0].journal.map(\.kind), [.updatePlan])
        let last = try XCTUnwrap(setup.script.requests[1].items.last)
        XCTAssertTrue((last["content"] as? String)?.contains("[done] A") == true)
        XCTAssertFalse(setup.script.serialized(0).contains("Plan:"))
    }

    @MainActor
    func testPlanSurvivesQuestionAndStopButNotNewConversationOrLaunch() async throws {
        let setup = try make([call("update_plan", Self.planArguments), .text("one"), .text("two"), .text("three")])
        await send(setup.controller, "q1")
        await send(setup.controller, "q2")
        XCTAssertEqual(setup.controller.plan.items.count, 2)
        XCTAssertTrue(setup.script.serialized(2).contains("[done] A"))
        setup.controller.stop()
        XCTAssertEqual(setup.controller.plan.items.count, 2, "после «Стоп» план остаётся в панели")
        await send(setup.controller, "q3")
        XCTAssertTrue(setup.controller.plan.isEmpty, "новый запуск начинает с пустого плана")
        XCTAssertFalse(setup.script.serialized(3).contains("[done] A"))

        let other = try make([call("update_plan", Self.planArguments), .text("one")])
        await send(other.controller, "q")
        other.controller.newConversation()
        XCTAssertTrue(other.controller.plan.isEmpty)
    }

    @MainActor
    func testOldResultsAreClearedAndCounterShrinks() async throws {
        let reading = readingDocument()
        var limits = AIAgentLimits()
        limits.maxContextBytes = 40_000
        let setup = try make((0..<9).map { _ in reading.read } + [.text("end")], documents: [reading.document], limits: limits)
        await send(setup.controller, "q")
        let journal = setup.controller.turns[0].journal
        XCTAssertTrue(journal.contains { $0.kind == .contextCleared && $0.count > 0 && $0.savedBytes > 0 })
        XCTAssertTrue(setup.script.serialized(9).contains("Result removed to save space"))
        XCTAssertLessThan(setup.controller.counters.contextBytes, 9 * 3_000)
        XCTAssertEqual(setup.controller.turns[0].status, .answered)
    }

    @MainActor
    func testCondenseRequestHasNoToolsAndLoopContinues() async throws {
        let reading = readingDocument()
        var limits = AIAgentLimits()
        limits.maxContextBytes = 8_000
        let setup = try make([reading.read, reading.read, reading.read, .text("SUMMARY"), .text("final")], documents: [reading.document], limits: limits)
        await send(setup.controller, "q")
        XCTAssertEqual(setup.script.requests[3].tools, [])
        XCTAssertEqual(setup.script.requests[3].items.count, 1)
        XCTAssertFalse(setup.script.requests[4].tools.isEmpty)
        XCTAssertTrue(setup.controller.turns[0].journal.contains { $0.kind == .contextCondensed })
        XCTAssertEqual(setup.controller.turns[0].answer, "final")
        XCTAssertEqual(setup.controller.counters.rounds, 4)
    }

    @MainActor
    func testCondenseFailurePausesAndResumeRepeatsIt() async throws {
        let reading = readingDocument()
        var limits = AIAgentLimits()
        limits.maxContextBytes = 8_000
        let setup = try make([reading.read, reading.read, reading.read, .fail(AIError.network), .text("SUMMARY"), .text("final")],
                             documents: [reading.document], limits: limits)
        await send(setup.controller, "q")
        XCTAssertEqual(setup.controller.turns.last?.status, .paused)
        XCTAssertTrue(setup.controller.canResume)
        setup.controller.resume()
        await settle(setup.controller)
        XCTAssertEqual(setup.script.requests[4].tools, [])
        XCTAssertEqual(setup.controller.turns.last?.answer, "final")
    }

    @MainActor
    func testStopDuringCondenseDropsLateSummary() async throws {
        let reading = readingDocument()
        var limits = AIAgentLimits()
        limits.maxContextBytes = 8_000
        let setup = try make([reading.read, reading.read, reading.read, .text("SUMMARY"), .text("final")], documents: [reading.document], limits: limits)
        let gate = hold(setup.script, at: 3)
        setup.controller.draft = "q"
        setup.controller.send()
        _ = await waitFor { setup.controller.approval != nil }
        setup.controller.resolve(.allowOnce)
        _ = await waitFor { setup.script.requests.count == 4 }
        setup.controller.stop()
        gate.yield()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(setup.controller.hasConversation)
        XCTAssertEqual(setup.controller.turns.last?.status, .stopped)
        XCTAssertEqual(setup.controller.turns.last?.answer, "")
        XCTAssertEqual(setup.script.requests.count, 4)
    }

    @MainActor
    func testContextFullGivesPartialWithoutResume() async throws {
        var limits = AIAgentLimits()
        limits.maxContextBytes = 300
        let setup = try make([.text("never")], limits: limits)
        await send(setup.controller, String(repeating: "q", count: 500))
        XCTAssertEqual(setup.controller.turns.last?.status, .partial)
        XCTAssertFalse(setup.controller.canResume)
        XCTAssertFalse(setup.controller.isWorking)
        XCTAssertFalse(setup.controller.message.isEmpty)
        XCTAssertTrue(setup.script.requests.isEmpty)
    }

    func testViewAndControllerStringsExistInAllCatalogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LacEditor")
        var keys = Set<String>()
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\("((?:[^"\\]|\\.)*)""#)
        for file in ["Services/AIAgentController.swift", "Services/AIAgentRun.swift", "Views/AIAgentView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                keys.insert((source as NSString).substring(with: match.range(at: 1)))
            }
        }
        XCTAssertFalse(keys.isEmpty)
        let catalogs = try ["zh-Hans", "en", "ru"].map { try String(contentsOf: root.appendingPathComponent("\($0).lproj/Localizable.strings"), encoding: .utf8) }
        for key in keys {
            for catalog in catalogs { XCTAssertTrue(catalog.contains("\"\(key)\" ="), key) }
            for catalog in catalogs.dropFirst() {
                let line = catalog.components(separatedBy: "\n").first { $0.hasPrefix("\"\(key)\" =") } ?? ""
                XCTAssertEqual(line.components(separatedBy: "%lld").count, key.components(separatedBy: "%lld").count, key)
                XCTAssertEqual(line.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, key)
            }
        }
        for catalog in catalogs {
            XCTAssertEqual(catalog.components(separatedBy: "\n\"AI 代理\" =").count, 2)
        }
    }
}
