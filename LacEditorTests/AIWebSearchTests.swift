import XCTest
@testable import LacEditor

private final class WebSearchTestProtocol: URLProtocol {
    static var handler: ((URLRequest, [String: Any]) throws -> (Int, Data))?
    static var requests: [(url: URL, body: [String: Any])] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func bodyObject() -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    override func startLoading() {
        let body = bodyObject()
        Self.requests.append((request.url!, body))
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value - 1 }
}

final class AIWebSearchTests: XCTestCase {
    private var modelRequests: [[String: Any]] { WebSearchTestProtocol.requests.filter { $0.url.host == "model.example" }.map(\.body) }
    private var jinaRequests: [[String: Any]] { WebSearchTestProtocol.requests.filter { $0.url.host == "jina.example" }.map(\.body) }

    override func setUp() {
        WebSearchTestProtocol.requests = []
        WebSearchTestProtocol.handler = nil
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSearchTestProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func profile(_ api: AIAPIProtocol) -> AIModelProfile {
        var profile = AIModelProfile(api: api)
        profile.baseURL = "https://model.example/v1/"
        profile.modelID = "test-model"
        profile.isEnabled = true
        return profile
    }

    private func jinaConfiguration(reader: Bool) -> JinaConfiguration {
        var configuration = JinaConfiguration()
        configuration.searchEnabled = true
        configuration.readerEnabled = reader
        configuration.searchEndpoint = "https://jina.example/search"
        configuration.readerEndpoint = "https://jina.example/read"
        return configuration
    }

    private func webSession(reader: Bool, isCurrent: @escaping @Sendable () async -> Bool = { true }) -> AIWebSearchSession {
        AIWebSearchSession(client: JinaClient(session: session()), configuration: jinaConfiguration(reader: reader), searchKey: nil, readerKey: nil, isCurrent: isCurrent)
    }

    private func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    private func responsesCall(_ id: String, _ query: String, encrypted: String? = nil) -> [String: Any] {
        var reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "summary": []]
        if let encrypted { reasoning["encrypted_content"] = encrypted }
        return ["status": "completed", "output": [
            reasoning,
            ["type": "function_call", "id": "fc_\(id)", "call_id": id, "name": "web_search", "arguments": "{\"query\":\"\(query)\"}", "status": "completed"]]]
    }

    private func responsesFinal(_ text: String) -> [String: Any] {
        ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": text]]]]]
    }

    private func chatCall(_ calls: [(String, String)]) -> [String: Any] {
        ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
            "tool_calls": calls.map { ["id": $0.0, "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":\"\($0.1)\"}"]] }]]]]
    }

    private func chatFinal(_ text: String) -> [String: Any] {
        ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": text]]]]
    }

    private func installHandler(api: AIAPIProtocol, rounds: @escaping (Int) -> [String: Any], searchStatus: Int = 200, readStatus: Int = 200) {
        var round = 0
        WebSearchTestProtocol.handler = { request, body in
            switch request.url?.host {
            case "model.example":
                defer { round += 1 }
                return (200, self.json(rounds(round)))
            default:
                if request.url?.path == "/search" {
                    return (searchStatus, self.json(["data": [
                        ["title": "A", "url": "https://example.org/a", "description": "snippet A"],
                        ["title": "B", "url": "https://example.org/b", "description": "snippet B"]]]))
                }
                if readStatus != 200 && body["url"] as? String == "https://example.org/b" { return (readStatus, Data("{}".utf8)) }
                return (200, self.json(["data": ["title": "T", "url": body["url"] as? String ?? "", "content": "full text of \(body["url"] as? String ?? "")"]]))
            }
        }
    }

    func testResponsesLoopReturnsOutputItemsAndFunctionOutput() async throws {
        installHandler(api: .responses) { $0 == 0 ? self.responsesCall("call_1", "swift") : self.responsesFinal("done") }
        let web = webSession(reader: false)
        let client = AIClient(session: session())
        let text = try await client.generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil, toolHandler: web.run)
        XCTAssertEqual(text, "done")
        let first = modelRequests[0], second = modelRequests[1]
        let tool = try XCTUnwrap((first["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertEqual(tool["name"] as? String, "web_search")
        XCTAssertEqual(first["store"] as? Bool, false)
        XCTAssertEqual(first["tool_choice"] as? String, "auto")
        let input = try XCTUnwrap(second["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, [nil, "function_call", "function_call_output"])
        XCTAssertEqual(input.last?["call_id"] as? String, "call_1")
        let output = try XCTUnwrap(input.last?["output"] as? String)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let result = try XCTUnwrap((parsed["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["resultIndex"] as? Int, 0)
        XCTAssertEqual(result["url"] as? String, "https://example.org/a")
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertEqual(result["text"] as? String, "snippet A")
        XCTAssertEqual(jinaRequests.count, 1)
    }

    func testChatLoopEchoesAssistantMessageAndToolMessages() async throws {
        installHandler(api: .chatCompletions) { $0 == 0 ? self.chatCall([("c1", "one"), ("c2", "two")]) : self.chatFinal("done") }
        let web = webSession(reader: false)
        let text = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.chatCompletions), key: nil, toolHandler: web.run)
        XCTAssertEqual(text, "done")
        let tool = try XCTUnwrap((modelRequests[0]["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual((tool["function"] as? [String: Any])?["name"] as? String, "web_search")
        let messages = try XCTUnwrap(modelRequests[1]["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool"])
        XCTAssertNotNil(messages[2]["tool_calls"])
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "c2")
        XCTAssertEqual(jinaRequests.count, 2)
    }

    func testFourthSearchGetsLimitMessageWithoutCallingJina() async throws {
        installHandler(api: .chatCompletions) { $0 < 4 ? self.chatCall([("c\($0)", "q\($0)")]) : self.chatFinal("done") }
        let web = webSession(reader: false)
        let text = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.chatCompletions), key: nil, toolHandler: web.run)
        XCTAssertEqual(text, "done")
        XCTAssertEqual(jinaRequests.count, 3)
        XCTAssertEqual(web.searches, 3)
        let last = try XCTUnwrap((modelRequests.last?["messages"] as? [[String: Any]])?.last)
        XCTAssertTrue((last["content"] as? String ?? "").contains("search limit reached"))
    }

    func testParallelCallsShareTheLimit() async throws {
        installHandler(api: .responses) { $0 == 0 ? self.responsesCalls(4) : self.responsesFinal("done") }
        let web = webSession(reader: false)
        _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil, toolHandler: web.run)
        XCTAssertEqual(jinaRequests.count, 3)
        let outputs = try XCTUnwrap(modelRequests[1]["input"] as? [[String: Any]]).filter { $0["type"] as? String == "function_call_output" }
        XCTAssertEqual(outputs.count, 4)
        XCTAssertTrue((outputs[3]["output"] as? String ?? "").contains("search limit reached"))
    }

    private func responsesCalls(_ count: Int) -> [String: Any] {
        ["status": "completed", "output": (0..<count).map { ["type": "function_call", "call_id": "c\($0)", "name": "web_search", "arguments": "{\"query\":\"q\($0)\"}"] }]
    }

    func testEndlessToolCallsStopAfterFiveRoundsWithToolChoiceNone() async throws {
        installHandler(api: .chatCompletions) { self.chatCall([("c\($0)", "q")]) }
        let web = webSession(reader: false)
        do {
            _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.chatCompletions), key: nil, toolHandler: web.run)
            XCTFail("expected invalidResponse")
        } catch AIError.invalidResponse {}
        XCTAssertEqual(modelRequests.count, 6)
        XCTAssertEqual(modelRequests.last?["tool_choice"] as? String, "none")
        XCTAssertEqual(modelRequests.first?["tool_choice"] as? String, "auto")
    }

    func testReaderFailureOfOnePageDoesNotStopOthers() async throws {
        installHandler(api: .responses, rounds: { $0 == 0 ? self.responsesCall("c", "q") : self.responsesFinal("done") }, readStatus: 500)
        let web = webSession(reader: true)
        _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil, toolHandler: web.run)
        XCTAssertEqual(jinaRequests.count, 3)
        XCTAssertEqual(web.sources.map(\.isVerified), [true, false])
        XCTAssertEqual(web.sources[0].content, "full text of https://example.org/a")
        XCTAssertTrue(web.sources[1].readFailed)
    }

    func testJinaSearchErrorIsReturnedToModelNotThrown() async throws {
        installHandler(api: .responses, rounds: { $0 == 0 ? self.responsesCall("c", "q") : self.responsesFinal("done") }, searchStatus: 500)
        let web = webSession(reader: false)
        let text = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil, toolHandler: web.run)
        XCTAssertEqual(text, "done")
        let output = try XCTUnwrap((modelRequests[1]["input"] as? [[String: Any]])?.last?["output"] as? String)
        XCTAssertTrue(output.contains("Web search failed"))
        XCTAssertTrue(web.sources.isEmpty)
    }

    func testReasoningIsReturnedOnlyWithEncryptedContent() async throws {
        for (encrypted, expected) in [(nil, [nil, "function_call", "function_call_output"]),
                                      ("", [nil, "function_call", "function_call_output"]),
                                      ("blob", [nil, "reasoning", "function_call", "function_call_output"])] as [(String?, [String?])] {
            WebSearchTestProtocol.requests = []
            installHandler(api: .responses) { $0 == 0 ? self.responsesCall("c", "q", encrypted: encrypted) : self.responsesFinal("done") }
            _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil, toolHandler: webSession(reader: false).run)
            XCTAssertNil(modelRequests[0]["include"])
            XCTAssertNil(modelRequests[1]["include"])
            let input = try XCTUnwrap(modelRequests[1]["input"] as? [[String: Any]])
            XCTAssertEqual(input.map { $0["type"] as? String }, expected)
            let call = try XCTUnwrap(input.first { $0["type"] as? String == "function_call" })
            XCTAssertEqual(call["id"] as? String, encrypted == "blob" ? "fc_c" : nil)
            XCTAssertEqual(call["call_id"] as? String, "c")
        }
    }

    func testConfigurationChangeDuringSearchCancels() async throws {
        installHandler(api: .responses) { $0 == 0 ? self.responsesCall("c", "q") : self.responsesFinal("done") }
        let calls = LockedCounter()
        let web = webSession(reader: false, isCurrent: { calls.next() < 1 })
        do {
            _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil, toolHandler: web.run)
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(jinaRequests.count, 1)
        XCTAssertEqual(modelRequests.count, 1)
    }

    func testStaleConfigurationCancelsBeforeJina() async throws {
        installHandler(api: .responses) { $0 == 0 ? self.responsesCall("c", "q") : self.responsesFinal("done") }
        let web = webSession(reader: false, isCurrent: { false })
        do {
            _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil, toolHandler: web.run)
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(jinaRequests.isEmpty)
        XCTAssertEqual(modelRequests.count, 1)
    }

    func testCancellationStopsTheLoop() async throws {
        installHandler(api: .responses) { $0 == 0 ? self.responsesCall("c", "q") : self.responsesFinal("done") }
        let web = webSession(reader: false)
        let task = Task { () -> String in
            try await AIClient(session: self.session()).generateConversation(messages: [.user("q")], instructions: "i", profile: self.profile(.responses), key: nil) { call in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await web.run(call)
            }
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(jinaRequests.isEmpty)
    }

    func testMediaInToolOutputIsOmittedFromRequest() async throws {
        installHandler(api: .responses) { $0 == 0 ? self.responsesCall("c", "q") : self.responsesFinal("done") }
        let output = AIRequestMediaSanitizer.sanitize("see data:image/png;base64,AAAA end")
        XCTAssertEqual(output, "see [media omitted] end")
        _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil) { _ in
            return "x data:image/png;base64,AAAAAAAA y"
        }
        let sent = try XCTUnwrap((modelRequests[1]["input"] as? [[String: Any]])?.last?["output"] as? String)
        XCTAssertEqual(sent, "x [media omitted] y")
    }

    func testDuplicateURLsKeepTheirIndexAcrossSearches() async throws {
        installHandler(api: .chatCompletions) { $0 < 2 ? self.chatCall([("c\($0)", "q\($0)")]) : self.chatFinal("done") }
        let web = webSession(reader: true)
        _ = try await AIClient(session: session()).generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.chatCompletions), key: nil, toolHandler: web.run)
        XCTAssertEqual(web.sources.map(\.id), [0, 1])
        XCTAssertEqual(jinaRequests.count, 4)
    }

    // MARK: - webCitations

    private func document(_ text: String = "Doc text") -> [AIQuestionSource] {
        [AIQuestionSource(snapshot: AIContextSnapshot(input: .file(URL(fileURLWithPath: "/tmp/a.md")), name: "a.md", text: text, document: nil, documentRevision: 0, fileRevision: nil), selectionRange: nil)]
    }

    private func webSource(_ id: Int, content: String, verified: Bool) -> AIWebSource {
        AIWebSource(id: id, title: "T", url: URL(string: "https://example.org/\(id)")!, content: content, isVerified: verified, readFailed: false)
    }

    func testWebCitationsAreVerifiedLiterallyWithReader() throws {
        let web = [webSource(0, content: "The sky is blue today", verified: true), webSource(1, content: "", verified: false)]
        let response = "```json\n" + #"{"answer":"a","citations":[],"webCitations":[{"resultIndex":0,"quote":"sky is blue"},{"resultIndex":0,"quote":"sky is green"},{"resultIndex":5,"quote":"x"},{"resultIndex":true,"quote":"x"},{"resultIndex":0.5,"quote":"x"},{"resultIndex":1,"quote":"x"}]}"# + "\n```"
        let reply = try AIQuestionService.parse(response, sources: document(), web: web, readerEnabled: true)
        XCTAssertEqual(reply.webCitations.map(\.quote), ["sky is blue"])
        XCTAssertEqual(reply.webCitations.first?.sourceIndex, 0)
        XCTAssertEqual(reply.skipped, 5)
    }

    func testWebCitationsWithoutReaderAreNotShownAsVerified() throws {
        let web = [webSource(0, content: "snippet", verified: false)]
        let reply = try AIQuestionService.parse(#"{"answer":"a","webCitations":[{"resultIndex":0,"quote":"snippet"}]}"#, sources: document(), web: web, readerEnabled: false)
        XCTAssertTrue(reply.webCitations.isEmpty)
        XCTAssertEqual(reply.skipped, 0)
    }

    func testMissingWebCitationsKeyIsNotAnError() throws {
        let reply = try AIQuestionService.parse(#"{"answer":"a","citations":[]}"#, sources: document(), web: [webSource(0, content: "x", verified: true)], readerEnabled: true)
        XCTAssertTrue(reply.webCitations.isEmpty)
        XCTAssertEqual(reply.skipped, 0)
    }

    func testInstructionsMentionWebCitationsOnlyWhenSearchIsOn() {
        XCTAssertFalse(AIQuestionService.instructions.contains("webCitations"))
        XCTAssertTrue(AIQuestionService.webInstructions.contains("webCitations"))
    }

    // MARK: - Контроллер

    @MainActor
    private func makeController(searchEnabled: Bool, reader: Bool = false, converse: @escaping ([AIConversationMessage], AIModelProfile, String?) async throws -> String,
                                converseWeb: @escaping ([AIConversationMessage], AIModelProfile, String?, AIWebSearchSession) async throws -> String) throws -> AIQuestionController {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditor-AIWeb-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatures = [.ask]
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        var jina = JinaConfiguration()
        jina.searchEnabled = searchEnabled; jina.readerEnabled = reader
        preferences.jinaConfiguration = jina
        let state = AppState(initialDocuments: [EditorDocument(text: "Whole text")], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        return AIQuestionController(appState: state, converse: converse, loadKey: { _, _ in nil }, converseWeb: converseWeb, loadJinaKey: { _, _ in nil })
    }

    @MainActor
    private func settle(_ controller: AIQuestionController) async {
        for _ in 0..<2000 where controller.isWorking { await Task.yield() }
    }

    @MainActor
    private func selectWholeDocument(_ id: UUID) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = EditorTextSelectionSnapshot(documentID: id, range: NSRange(location: 0, length: 10), text: "Whole text", editorRevision: 0, wasExplicitSelection: false)
        }
    }

    @MainActor
    func testToggleIsHiddenWithoutJinaSearchAndSurvivesNewConversation() throws {
        let off = try makeController(searchEnabled: false, converse: { _, _, _ in "" }, converseWeb: { _, _, _, _ in "" })
        XCTAssertFalse(off.isWebSearchAvailable)
        let on = try makeController(searchEnabled: true, converse: { _, _, _ in "" }, converseWeb: { _, _, _, _ in "" })
        XCTAssertTrue(on.isWebSearchAvailable)
        XCTAssertTrue(on.webSearchEnabled)
        on.webSearchEnabled = false
        on.newConversation()
        XCTAssertFalse(on.webSearchEnabled)
    }

    @MainActor
    func testDisabledToggleUsesPlainConversationWithoutTools() async throws {
        var plain = 0, web = 0
        let controller = try makeController(searchEnabled: true, converse: { _, _, _ in plain += 1; return #"{"answer":"ok","citations":[]}"# },
                                            converseWeb: { _, _, _, _ in web += 1; return "" })
        let observer = selectWholeDocument(try XCTUnwrap(controller.availableDocuments.first).id)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.webSearchEnabled = false
        controller.draft = "Q"
        controller.ask()
        await settle(controller)
        XCTAssertEqual(plain, 1)
        XCTAssertEqual(web, 0)
        XCTAssertEqual(controller.turns.count, 1)
    }

    @MainActor
    func testWebAnswerIsStoredAndProgressIsReset() async throws {
        let controller = try makeController(searchEnabled: true, reader: true, converse: { _, _, _ in "" }, converseWeb: { _, _, _, _ in
            return #"{"answer":"ok","citations":[],"webCitations":[]}"#
        })
        let observer = selectWholeDocument(try XCTUnwrap(controller.availableDocuments.first).id)
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.draft = "Q"
        controller.ask()
        await settle(controller)
        XCTAssertEqual(controller.turns.count, 1)
        XCTAssertNil(controller.messageAction)
        XCTAssertEqual(controller.searchProgress, 0)
    }

    @MainActor
    func testServerRejectionWithToolsAddsHintOnlyForClientErrors() async throws {
        var status = 400
        let controller = try makeController(searchEnabled: true, converse: { _, _, _ in "" }, converseWeb: { _, _, _, _ in throw AIError.http(status, nil) })
        let observer = selectWholeDocument(try XCTUnwrap(controller.availableDocuments.first).id)
        defer { NotificationCenter.default.removeObserver(observer) }
        let hint = L10n.tr("服务器拒绝了带联网搜索的请求。请关闭“在互联网上搜索”后重试（服务器可能不支持函数调用，或上下文不够长）。")
        controller.draft = "Q"
        controller.ask()
        await settle(controller)
        XCTAssertTrue(controller.message.contains(hint))
        status = 401
        controller.ask()
        await settle(controller)
        XCTAssertFalse(controller.message.contains(hint))
    }
}
