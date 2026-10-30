import Foundation
import XCTest
@testable import LacEditor

private final class AIURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

}

final class AIClientTests: XCTestCase {
    private func makeClient() -> AIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIURLProtocol.self]
        return AIClient(session: URLSession(configuration: configuration))
    }

    private func profile(_ api: AIAPIProtocol) -> AIModelProfile {
        var profile = AIModelProfile(api: api)
        profile.baseURL = "https://example.com/gateway/v1/"
        profile.modelID = "test-model"
        profile.isEnabled = true
        return profile
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw try XCTUnwrap(stream.streamError) }
                if count == 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testModelsAndResponsesRequest() async throws {
        let client = makeClient()
        AIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/gateway/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            return (200, Data(#"{"data":[{"id":"one"},{"id":"two"}]}"#.utf8))
        }
        let models = try await client.listModels(profile: profile(.responses), key: "test-key")
        XCTAssertEqual(models, ["one", "two"])
        AIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/responses")
            let body = try self.body(request)
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertEqual(body["input"] as? String, "hello")
            XCTAssertEqual(body["instructions"] as? String, "write")
            XCTAssertEqual(body["store"] as? Bool, false)
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"result"}]}]}"#.utf8))
        }
        let text = try await client.generateText(input: "hello", instructions: "write", profile: profile(.responses), key: nil)
        XCTAssertEqual(text, "result")
    }

    func testChatAndDecisionsRequests() async throws {
        let client = makeClient()
        AIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let messages = try XCTUnwrap(try self.body(request)["messages"] as? [[String: String]])
            XCTAssertEqual(messages.last?["content"], "hello")
            return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"answer"}}]}"#.utf8))
        }
        let text = try await client.generateText(input: "hello", instructions: "classify", profile: profile(.chatCompletions), key: "")
        XCTAssertEqual(text, "answer")
        AIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/decisions")
            let body = try self.body(request)
            let questions = try XCTUnwrap(body["questions"] as? [[String: String]])
            XCTAssertEqual(questions.first?["name"], "result")
            XCTAssertEqual(questions.first?["type"], "predicate")
            XCTAssertEqual(questions.first?["instructions"], "question")
            return (200, Data(#"{"answers":[{"type":"predicate","name":"result","probability":0.92}]}"#.utf8))
        }
        let probability = try await client.decide(input: "hello", question: "question", profile: profile(.decisions), key: nil)
        XCTAssertEqual(probability, 0.92)
    }

    func testInvalidAndRefusedResponses() async throws {
        let client = makeClient()
        for response in [#"{"answers":[{"type":"predicate","name":"result","probability":1.1}]}"#, #"{"answers":[]}"#, #"{"answers":[{"type":"refusal","name":"result"}]}"#] {
            AIURLProtocol.handler = { _ in (200, Data(response.utf8)) }
            do {
                _ = try await client.decide(input: "x", question: "q", profile: profile(.decisions), key: nil)
                XCTFail("Expected invalid or refused response")
            } catch is AIError {} catch { XCTFail("Unexpected error") }
        }
        for response in [#"{"status":"incomplete","output":[]}"#, #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal"}]}]}"#, #"{"status":"completed","output":[]}"#, #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"valid"},{"type":"output_text"}]}]}"#] {
            AIURLProtocol.handler = { _ in (200, Data(response.utf8)) }
            do {
                _ = try await client.generateText(input: "x", instructions: "q", profile: profile(.responses), key: nil)
                XCTFail("Expected invalid or refused response")
            } catch is AIError {} catch { XCTFail("Unexpected error") }
        }
        AIURLProtocol.handler = { _ in (401, Data("private error detail".utf8)) }
        do {
            _ = try await client.listModels(profile: profile(.responses), key: "secret")
            XCTFail("Expected HTTP failure")
        } catch AIError.http(let status, _) { XCTAssertEqual(status, 401) }
    }
    func testImageURLIsDownloadedWithoutCredentials() async throws {
        let client = makeClient()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a1sAAAAASUVORK5CYII="
        AIURLProtocol.handler = { request in
            if request.url?.host == "images.example.com" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data(base64Encoded: png)!)
            }
            XCTAssertEqual(request.url?.path, "/gateway/v1/images/generations")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
            return (200, Data(#"{"data":[{"url":"https://images.example.com/image.png"}]}"#.utf8))
        }
        let data = try await client.generateImage(prompt: "test", profile: profile(.images), key: "key")
        XCTAssertEqual(data, Data(base64Encoded: png))
    }

    func testCancellationIsPreserved() async throws {
        AIURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await makeClient().listModels(profile: profile(.responses), key: nil)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error") }
    }

    func testRequestTimeoutIs600AndListModelsIs60() async throws {
        XCTAssertEqual(AIClient.defaultSession.configuration.timeoutIntervalForRequest, 600)
        XCTAssertEqual(AIClient.defaultSession.configuration.timeoutIntervalForResource, 600)
        var timeouts: [String: TimeInterval] = [:]
        AIURLProtocol.handler = { request in
            timeouts[request.url?.lastPathComponent ?? ""] = request.timeoutInterval
            return (200, Data(#"{"data":[{"id":"one"}]}"#.utf8))
        }
        _ = try await makeClient().listModels(profile: profile(.responses), key: nil)
        XCTAssertEqual(timeouts["models"], 60)
        AIURLProtocol.handler = { request in
            timeouts[request.url?.lastPathComponent ?? ""] = request.timeoutInterval
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#.utf8))
        }
        _ = try await makeClient().generateText(input: "a", instructions: "b", profile: profile(.responses), key: nil)
        XCTAssertEqual(timeouts["responses"], 600)
    }

    func testTransportErrorsAreClassified() async throws {
        let cases: [(URLError.Code, AITransportFailure?)] = [
            (.timedOut, .timedOut), (.notConnectedToInternet, .offline), (.networkConnectionLost, .offline),
            (.cannotFindHost, .cannotConnect), (.cannotConnectToHost, .cannotConnect),
            (.serverCertificateUntrusted, .secureConnection), (.secureConnectionFailed, .secureConnection),
            (.badServerResponse, nil)
        ]
        for (code, expected) in cases {
            AIURLProtocol.handler = { _ in throw URLError(code) }
            do {
                _ = try await makeClient().generateText(input: "a", instructions: "b", profile: profile(.responses), key: nil)
                XCTFail("Expected error")
            } catch let error as AIError {
                switch (error, expected) {
                case (.transport(let failure), let expected?): XCTAssertEqual(failure, expected)
                case (.network, nil): break
                default: XCTFail("Unexpected \(error) for \(code)")
                }
            }
        }
    }

    func testTransportMessagesAreDistinctAndLocalized() {
        let messages = [AITransportFailure.timedOut, .offline, .cannotConnect, .secureConnection].map { AIError.transport($0).errorDescription }
        XCTAssertEqual(Set(messages.compactMap { $0 }).count, 4)
        XCTAssertEqual(AIError.transport(.offline).errorDescription, L10n.tr("没有网络连接或连接已中断，请检查网络后重试。"))
        XCTAssertEqual(AIError.transport(.timedOut).errorDescription, L10n.tr("AI 服务在 %lld 分钟内没有响应，请求已中止。", 10))
    }

    func testImageBase64AndInvalidImage() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a1sAAAAASUVORK5CYII="
        AIURLProtocol.handler = { _ in (200, Data("{\"data\":[{\"b64_json\":\"\(png)\"}]}".utf8)) }
        let image = try await makeClient().generateImage(prompt: "test", profile: profile(.images), key: nil)
        XCTAssertEqual(image, Data(base64Encoded: png))
        AIURLProtocol.handler = { _ in (200, Data(#"{"data":[{"b64_json":"SGVsbG8="}]}"#.utf8)) }
        do {
            _ = try await makeClient().generateImage(prompt: "test", profile: profile(.images), key: nil)
            XCTFail("Expected invalid image")
        } catch is AIError {} catch { XCTFail("Unexpected error") }
    }

    func testDisabledProfileDoesNotGenerateButCanListModels() async throws {
        let client = makeClient()
        AIURLProtocol.handler = { _ in XCTFail("Disabled profile made a request"); return (500, Data()) }
        for api in [AIAPIProtocol.responses, .chatCompletions, .decisions, .images] {
            var disabled = profile(api)
            disabled.isEnabled = false
            do {
                switch api {
                case .responses, .chatCompletions:
                    _ = try await client.generateText(input: "x", instructions: "q", profile: disabled, key: nil)
                case .decisions:
                    _ = try await client.decide(input: "x", question: "q", profile: disabled, key: nil)
                case .images:
                    _ = try await client.generateImage(prompt: "x", profile: disabled, key: nil)
                case .gatewayPDF, .transcriptions:
                    XCTFail("Media protocols use AIMediaClient")
                    continue
                }
                XCTFail("Expected disabled error")
            } catch AIError.disabled {} catch { XCTFail("Unexpected error") }
        }
        var disabled = profile(.responses)
        disabled.isEnabled = false
        AIURLProtocol.handler = { _ in (200, Data(#"{"data":[{"id":"available"}]}"#.utf8)) }
        let models = try await client.listModels(profile: disabled, key: nil)
        XCTAssertEqual(models, ["available"])
    }

    func testImageDescriptionSendsActualImage() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a1sAAAAASUVORK5CYII=")!
        AIURLProtocol.handler = { request in
            let body = try self.body(request)
            let input = try XCTUnwrap(body["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["image_url"] as? String, "data:image/png;base64,\(png.base64EncodedString())")
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"A dot"}]}]}"#.utf8))
        }
        let description = try await makeClient().generateImageDescription(data: png, instructions: "describe", profile: profile(.responses), key: nil)
        XCTAssertEqual(description, "A dot")
    }

    func testTextRequestsOmitEmbeddedMediaData() async throws {
        let client = makeClient()
        let input = "Before ![image](data:image/png;base64,AAAA) after data:audio/mpeg;base64,BBBB."
        AIURLProtocol.handler = { request in
            let body = try self.body(request)
            XCTAssertEqual(body["input"] as? String, "Before ![image]([media omitted]) after [media omitted].")
            return (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"result"}]}]}"#.utf8))
        }
        let result = try await client.generateText(input: input, instructions: "write", profile: profile(.responses), key: nil)
        XCTAssertEqual(result, "result")
    }

    func testImageEditSendsSelectedImageAsMultipartData() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a1sAAAAASUVORK5CYII=")!
        AIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/images/edits")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            let body = try XCTUnwrap(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"model\""))
            XCTAssertTrue(text.contains("test-model"))
            XCTAssertTrue(text.contains("name=\"prompt\""))
            XCTAssertTrue(text.contains("make it blue"))
            XCTAssertTrue(text.contains("name=\"image\"; filename=\"image.png\""))
            XCTAssertNotNil(body.range(of: png))
            return (200, Data("{\"data\":[{\"b64_json\":\"(png.base64EncodedString())\"}]}".utf8))
        }
        let result = try await makeClient().editImage(data: png, prompt: "make it blue", profile: profile(.images), key: nil)
        XCTAssertEqual(result, png)
    }


    func testConversationRequestsKeepRolesForBothProtocols() async throws {
        let messages: [AIConversationMessage] = [.user("q1"), .assistant(#"{"answer":"a1"}"#), .user("Sources: data:image/png;base64,AAAA\nq2")]
        let reply = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#
        AIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/responses")
            let body = try self.body(request)
            XCTAssertEqual(body["instructions"] as? String, "rules")
            XCTAssertEqual(body["store"] as? Bool, false)
            let input = try XCTUnwrap(body["input"] as? [[String: String]])
            XCTAssertEqual(input.map { $0["role"] }, ["user", "assistant", "user"])
            XCTAssertEqual(input[1]["content"], #"{"answer":"a1"}"#)
            XCTAssertEqual(input[2]["content"], "Sources: [media omitted]\nq2")
            return (200, Data(reply.utf8))
        }
        let first = try await makeClient().generateConversation(messages: messages, instructions: "rules", profile: profile(.responses), key: nil)
        XCTAssertEqual(first, "ok")
        AIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/gateway/v1/chat/completions")
            let sent = try XCTUnwrap(try self.body(request)["messages"] as? [[String: String]])
            XCTAssertEqual(sent.map { $0["role"] }, ["system", "user", "assistant", "user"])
            XCTAssertEqual(sent[0]["content"], "rules")
            XCTAssertEqual(sent[3]["content"], "Sources: [media omitted]\nq2")
            return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}]}"#.utf8))
        }
        let second = try await makeClient().generateConversation(messages: messages, instructions: "rules", profile: profile(.chatCompletions), key: nil)
        XCTAssertEqual(second, "ok")
    }

    func testConversationRejectsOtherProtocolsDisabledAndRefusal() async throws {
        AIURLProtocol.handler = { _ in XCTFail("No request expected"); return (500, Data()) }
        for api in [AIAPIProtocol.decisions, .images] {
            do {
                _ = try await makeClient().generateConversation(messages: [.user("q")], instructions: "i", profile: profile(api), key: nil)
                XCTFail("Expected invalid configuration")
            } catch AIError.invalidConfiguration {} catch { XCTFail("Unexpected error") }
        }
        var disabled = profile(.responses)
        disabled.isEnabled = false
        do {
            _ = try await makeClient().generateConversation(messages: [.user("q")], instructions: "i", profile: disabled, key: nil)
            XCTFail("Expected disabled")
        } catch AIError.disabled {} catch { XCTFail("Unexpected error") }
        AIURLProtocol.handler = { _ in (200, Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#.utf8)) }
        do {
            _ = try await makeClient().generateConversation(messages: [.user("q")], instructions: "i", profile: profile(.responses), key: nil)
            XCTFail("Expected refusal")
        } catch AIError.refused {} catch { XCTFail("Unexpected error") }
    }
}
