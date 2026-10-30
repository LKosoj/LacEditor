import Foundation
import ImageIO

enum AITransportFailure: Equatable { case timedOut, offline, cannotConnect, secureConnection }

enum AIError: LocalizedError {
    case invalidConfiguration, disabled, keychain, network, transport(AITransportFailure), http(Int, String?), invalidResponse, refused, truncated

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return L10n.tr("AI 配置无效")
        case .disabled: return L10n.tr("AI 功能已关闭")
        case .keychain: return L10n.tr("无法访问 AI 密钥")
        case .network: return L10n.tr("AI 网络请求失败")
        case .transport(let failure):
            switch failure {
            case .timedOut: return L10n.tr("AI 服务在 %lld 分钟内没有响应，请求已中止。", Int(AIClient.requestTimeout / 60))
            case .offline: return L10n.tr("没有网络连接或连接已中断，请检查网络后重试。")
            case .cannotConnect: return L10n.tr("无法找到或连接 AI 服务器，请检查服务地址。")
            case .secureConnection: return L10n.tr("与 AI 服务器的安全连接失败（证书或 TLS），请检查服务地址和证书。")
            }
        case .http(let status, let detail):
            let summary = L10n.tr("AI 服务返回错误（HTTP %d）", status)
            return if let detail { summary + "\n" + detail } else { summary }
        case .invalidResponse: return L10n.tr("AI 服务返回了无效或不完整的结果")
        case .refused: return L10n.tr("AI 服务拒绝了请求")
        case .truncated: return L10n.tr("AI 回复因长度限制被截断，请缩短输入或提高输出上限后重试。")
        }
    }

    static func transportError(_ error: Error) -> AIError {
        guard let error = error as? URLError else { return .network }
        switch error.code {
        case .timedOut: return .transport(.timedOut)
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .transport(.offline)
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return .transport(.cannotConnect)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .transport(.secureConnection)
        default: return .network
        }
    }

    static func http(status: Int, data: Data) -> AIError {
        .http(status, responseDetail(data))
    }

    private static func responseDetail(_ data: Data) -> String? {
        let candidate: String?
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                candidate = error["message"] as? String
            } else if let error = object["error"] as? String {
                candidate = error
            } else {
                candidate = object["message"] as? String ?? object["detail"] as? String
            }
        } else if data.count <= 4_096,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            candidate = text
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        let normalized = candidate.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(500))
    }
}

/// Описание функции, которую модель может вызвать; `parameters` — JSON Schema аргументов.
struct AIToolDefinition: @unchecked Sendable {
    let name: String
    let description: String
    let parameters: [String: Any]

    static let webSearch = AIToolDefinition(
        name: "web_search",
        description: "Search the web for current information not present in the documents. Returns result snippets or page text with resultIndex.",
        parameters: ["type": "object", "properties": ["query": ["type": "string", "description": "Short web search query"]],
                     "required": ["query"], "additionalProperties": false])
}

/// Расход токенов одного ответа; сервер без поля usage даёт нули.
struct AIUsage: Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0

    init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Responses отдаёт input_tokens/output_tokens, Chat Completions — prompt_tokens/completion_tokens.
    init(response: [String: Any]) {
        let usage = response["usage"] as? [String: Any]
        inputTokens = (usage?["input_tokens"] as? Int) ?? (usage?["prompt_tokens"] as? Int) ?? 0
        outputTokens = (usage?["output_tokens"] as? Int) ?? (usage?["completion_tokens"] as? Int) ?? 0
    }

    static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

/// Один шаг цикла: вызовы инструментов (с элементами для возврата модели) либо итоговый текст.
struct AIAgentStep: @unchecked Sendable {
    let calls: [AIToolCall]
    let echoed: [[String: Any]]
    let text: String?
    let usage: AIUsage
}

enum AIToolResultItem {
    static func toolResult(api: AIAPIProtocol, callID: String, output: String) -> [String: Any] {
        api == .responses ? ["type": "function_call_output", "call_id": callID, "output": output]
                          : ["role": "tool", "tool_call_id": callID, "content": output]
    }

    static func conversationItems(_ messages: [AIConversationMessage]) -> [[String: Any]] {
        messages.map { message -> [String: Any] in
            switch message {
            case .user(let text): ["role": "user", "content": text]
            case .assistant(let text): ["role": "assistant", "content": text]
            }
        }
    }
}

private final class AIRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AIRequestMediaSanitizer {
    private static let omitted = "[media omitted]"

    static func sanitize(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        while let marker = text.range(of: "data:", options: .caseInsensitive, range: cursor..<text.endIndex) {
            result += text[cursor..<marker.lowerBound]
            guard let comma = text[marker.upperBound...].firstIndex(of: ","),
                  text.distance(from: marker.upperBound, to: comma) <= 128 else {
                result += text[marker]
                cursor = marker.upperBound
                continue
            }
            let header = text[marker.upperBound..<comma].lowercased()
            guard header.hasPrefix("image/") || header.hasPrefix("audio/")
                    || header.hasPrefix("video/") || header.hasPrefix("application/pdf") else {
                result += text[marker]
                cursor = marker.upperBound
                continue
            }
            let isBase64 = header.split(separator: ";").dropFirst().contains("base64")
            var end = text.index(after: comma)
            while end < text.endIndex,
                  isBase64 ? isBase64Character(text[end]) : !isTerminator(text[end]) {
                end = text.index(after: end)
            }
            result += omitted
            cursor = end
        }
        result += text[cursor...]
        return result
    }

    static func sanitize(_ value: Any) -> Any {
        if let text = value as? String { return sanitize(text) }
        if let array = value as? [Any] { return array.map { sanitize($0) } }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { sanitize($0) } }
        return value
    }

    private static func isBase64Character(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "+" || character == "/" || character == "="
    }

    private static func isTerminator(_ character: Character) -> Bool {
        character.isWhitespace || "\"'<>)]}\\".contains(character)
    }
}

enum AIResponseJSON {
    static func unwrap(_ response: String) -> String {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: .newlines)
        if lines.count == 1 {
            guard text.count >= 6, text.hasSuffix("```") else { return text }
            var inner = String(text.dropFirst(3).dropLast(3))
            if inner.lowercased().hasPrefix("json") { inner = String(inner.dropFirst(4)) }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let opening = lines.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        guard opening == "```" || opening == "```json",
              lines.removeLast().trimmingCharacters(in: .whitespaces) == "```" else { return text }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func object(_ response: String) throws -> [String: Any] {
        guard let data = unwrap(response).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        return value
    }
}

enum AIRequestSize {
    static let threshold = 50 * 1024

    static func bytes(_ parts: String...) -> Int {
        parts.reduce(0) { $0 + AIRequestMediaSanitizer.sanitize($1).utf8.count }
    }

    static func text(_ bytes: Int) -> String {
        // Порог задан как 50 × 1024 байт: показываем двоичные КБ, чтобы он не выглядел как 51 КБ
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func warning(label: String, bytes: Int) -> String {
        L10n.tr("即将发送的内容较大：%@，共 %@（建议不超过 %@）。确认后才会发送。", label, text(bytes), text(threshold))
    }

    static func sent(label: String, bytes: Int) -> String {
        L10n.tr("已发送：%@，%@", label, text(bytes))
    }

    static func label(_ selection: EditorTextSelectionSnapshot, sources: Int = 0) -> String {
        let base = selection.wasExplicitSelection ? L10n.tr("所选文本") : L10n.tr("整个文档")
        return sources > 0 ? L10n.tr("%@ + %lld 个来源", base, sources) : base
    }

    static func skippedMessage(_ count: Int, allDropped: Bool) -> String {
        allDropped ? L10n.tr("模型返回的 %lld 个条目均无法核对，已全部跳过。", count) : L10n.tr("已跳过 %lld 个无法核对的条目。", count)
    }
}

struct AIClient {
    static let requestTimeout: TimeInterval = 600
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    init(session: URLSession = AIClient.defaultSession) { self.session = session }

    private func endpoint(_ profile: AIModelProfile, path: String) throws -> URL {
        let baseURL = try AIModelProfile.normalizedBaseURL(profile.baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw AIError.invalidConfiguration }
        components.path += "/" + path
        guard let url = components.url else { throw AIError.invalidConfiguration }
        return url
    }

    private func request(_ profile: AIModelProfile, path: String, key: String?, body: [String: Any]? = nil,
                         allowsMediaData: Bool = false, timeout: TimeInterval = AIClient.requestTimeout) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(profile, path: path))
        request.timeoutInterval = timeout
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: allowsMediaData ? body : AIRequestMediaSanitizer.sanitize(body))
        }
        return request
    }

    private func imageEditRequest(_ profile: AIModelProfile, data: Data, prompt: String, key: String?) throws -> URLRequest {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String? else { throw AIError.invalidResponse }
        let mime: String, filename: String
        switch type {
        case "public.png": mime = "image/png"; filename = "image.png"
        case "public.jpeg": mime = "image/jpeg"; filename = "image.jpg"
        case "org.webmproject.webp": mime = "image/webp"; filename = "image.webp"
        default: throw AIError.invalidResponse
        }
        let boundary = "LacEditor-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(try model(profile))\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n\(AIRequestMediaSanitizer.sanitize(prompt))\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: try endpoint(profile, path: "images/edits"))
        request.timeoutInterval = AIClient.requestTimeout
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request, delegate: AIRedirectDelegate())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw AIError.http(status: response.statusCode, data: data) }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.transportError(error)
        }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        return value
    }

    private func model(_ profile: AIModelProfile) throws -> String {
        let value = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AIError.invalidConfiguration }
        return value
    }

    func listModels(profile: AIModelProfile, key: String?) async throws -> [String] {
        let result = try object(await fetch(request(profile, path: "models", key: key, timeout: 60)))
        guard let data = result["data"] as? [[String: Any]] else { throw AIError.invalidResponse }
        return data.compactMap { $0["id"] as? String }
    }

    func generateText(input: String, instructions: String, profile: AIModelProfile, key: String?) async throws -> String {
        guard profile.isEnabled else { throw AIError.disabled }
        let model = try model(profile)
        let path: String
        let body: [String: Any]
        switch profile.api {
        case .responses:
            path = "responses"
            body = ["model": model, "input": input, "instructions": instructions, "store": false]
        case .chatCompletions:
            path = "chat/completions"
            body = ["model": model, "messages": [["role": "system", "content": instructions], ["role": "user", "content": input]]]
        default: throw AIError.invalidConfiguration
        }
        let result = try object(await fetch(request(profile, path: path, key: key, body: body)))
        return try responseText(result, api: profile.api)
    }

    /// Один шаг разговора: единственное место, где вопрос к документу обращается к модели (вариант без инструментов).
    func generateConversation(messages: [AIConversationMessage], instructions: String, profile: AIModelProfile, key: String?) async throws -> String {
        guard profile.isEnabled else { throw AIError.disabled }
        let model = try model(profile)
        let items = AIToolResultItem.conversationItems(messages)
        let path: String
        let body: [String: Any]
        switch profile.api {
        case .responses:
            path = "responses"
            body = ["model": model, "input": items, "instructions": instructions, "store": false]
        case .chatCompletions:
            path = "chat/completions"
            body = ["model": model, "messages": [["role": "system", "content": instructions]] + items]
        default: throw AIError.invalidConfiguration
        }
        let result = try object(await fetch(request(profile, path: path, key: key, body: body)))
        return try responseText(result, api: profile.api)
    }

    /// Один запрос цикла инструментов: вызовы модели с элементами для возврата либо итоговый текст. Обрезка ответа проверяется первой.
    func agentStep(items: [[String: Any]], instructions: String, tools: [AIToolDefinition], toolChoice: String,
                   profile: AIModelProfile, key: String?) async throws -> AIAgentStep {
        guard profile.isEnabled else { throw AIError.disabled }
        let model = try model(profile)
        let path: String
        var body: [String: Any]
        switch profile.api {
        case .responses:
            path = "responses"
            body = ["model": model, "input": items, "instructions": instructions, "store": false]
            if !tools.isEmpty {
                body["tool_choice"] = toolChoice
                body["tools"] = tools.map { ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters, "strict": true] as [String: Any] }
            }
        case .chatCompletions:
            path = "chat/completions"
            body = ["model": model, "messages": [["role": "system", "content": instructions]] + items]
            if !tools.isEmpty {
                body["tool_choice"] = toolChoice
                body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters, "strict": true] as [String: Any]] as [String: Any] }
            }
        default: throw AIError.invalidConfiguration
        }
        let result = try object(await fetch(request(profile, path: path, key: key, body: body)))
        var calls: [AIToolCall] = []
        var echoed: [[String: Any]] = []
        if profile.api == .responses {
            let output = try responsesOutput(result)
            for item in output where item["type"] as? String == "function_call" {
                guard let id = item["call_id"] as? String, !id.isEmpty, let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String else { throw AIError.invalidResponse }
                calls.append(AIToolCall(id: id, name: name, arguments: arguments))
            }
            if !calls.isEmpty {
                // При store:false сервер не хранит reasoning: без encrypted_content такой элемент вернуть нельзя (404).
                echoed = output.filter {
                    guard $0["type"] as? String == "reasoning" else { return true }
                    return !(($0["encrypted_content"] as? String) ?? "").isEmpty
                }
                // Элемент с id требует своего reasoning; без него возвращается по call_id и содержимому.
                if echoed.count < output.count {
                    echoed = echoed.map { var item = $0; item.removeValue(forKey: "id"); return item }
                }
            }
        } else {
            guard let choices = result["choices"] as? [[String: Any]], let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else { throw AIError.invalidResponse }
            // Отказ проверяет responseText раньше длины, поэтому здесь обрезка не перекрывает его
            if choice["finish_reason"] as? String == "length", !(message["refusal"] is String) { throw AIError.truncated }
            if let rawCalls = message["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
                for raw in rawCalls {
                    guard let id = raw["id"] as? String, !id.isEmpty, let function = raw["function"] as? [String: Any],
                          let name = function["name"] as? String, let arguments = function["arguments"] as? String else { throw AIError.invalidResponse }
                    calls.append(AIToolCall(id: id, name: name, arguments: arguments))
                }
                echoed = [message]
            }
        }
        let text: String? = try calls.isEmpty ? responseText(result, api: profile.api) : nil
        return AIAgentStep(calls: calls, echoed: echoed, text: text, usage: AIUsage(response: result))
    }

    /// Разговор с инструментами (по умолчанию web_search): пока модель просит вызов, результат возвращается ей; на последнем раунде tool_choice = "none".
    func generateConversation(messages: [AIConversationMessage], instructions: String, profile: AIModelProfile, key: String?,
                              maxToolRounds: Int = 5, tools: [AIToolDefinition] = [.webSearch],
                              toolHandler: (AIToolCall) async throws -> String) async throws -> String {
        var items = AIToolResultItem.conversationItems(messages)
        for round in 0...maxToolRounds {
            try Task.checkCancellation()
            let step = try await agentStep(items: items, instructions: instructions, tools: tools,
                                           toolChoice: round == maxToolRounds ? "none" : "auto", profile: profile, key: key)
            if step.calls.isEmpty {
                guard let text = step.text else { throw AIError.invalidResponse }
                return text
            }
            guard round < maxToolRounds else { throw AIError.invalidResponse }
            items += step.echoed
            for call in step.calls {
                try Task.checkCancellation()
                let output = try await toolHandler(call)
                items.append(AIToolResultItem.toolResult(api: profile.api, callID: call.id, output: output))
            }
        }
        throw AIError.invalidResponse
    }

    /// Output items ответа Responses: сначала обрезка по длине, затем общая проверка статуса.
    private func responsesOutput(_ result: [String: Any]) throws -> [[String: Any]] {
        let status = result["status"] as? String
        if status == "incomplete", (result["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens" {
            throw AIError.truncated
        }
        guard status == "completed", let output = result["output"] as? [[String: Any]] else { throw AIError.invalidResponse }
        return output
    }

    private func responseText(_ result: [String: Any], api: AIAPIProtocol) throws -> String {
        let text: String
        if api == .responses {
            let output = try responsesOutput(result)
            var parts: [String] = []
            for item in output where item["type"] as? String == "message" {
                guard let content = item["content"] as? [[String: Any]] else { throw AIError.invalidResponse }
                for part in content {
                    if part["type"] as? String == "refusal" { throw AIError.refused }
                    if part["type"] as? String == "output_text" {
                        guard let value = part["text"] as? String else { throw AIError.invalidResponse }
                        parts.append(value)
                    }
                }
            }
            text = parts.joined()
        } else {
            guard let choices = result["choices"] as? [[String: Any]], let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else { throw AIError.invalidResponse }
            if message["refusal"] is String { throw AIError.refused }
            if choice["finish_reason"] as? String == "length" { throw AIError.truncated }
            guard choice["finish_reason"] as? String == "stop", let content = message["content"] as? String else { throw AIError.invalidResponse }
            text = content
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse }
        return text
    }


    func generateImageDescription(data: Data, instructions: String, profile: AIModelProfile, key: String?) async throws -> String {
        guard profile.isEnabled else { throw AIError.disabled }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { throw AIError.invalidResponse }
        let mime: String
        switch type {
        case "public.png": mime = "image/png"
        case "public.jpeg": mime = "image/jpeg"
        case "com.compuserve.gif": mime = "image/gif"
        case "org.webmproject.webp": mime = "image/webp"
        default: throw AIError.invalidResponse
        }
        let imageURL = "data:\(mime);base64,\(data.base64EncodedString())"
        let body: [String: Any]
        let path: String
        switch profile.api {
        case .responses:
            path = "responses"
            body = ["model": try model(profile), "instructions": instructions, "store": false,
                    "input": [["role": "user", "content": [["type": "input_image", "image_url": imageURL]]]]]
        case .chatCompletions:
            path = "chat/completions"
            body = ["model": try model(profile), "messages": [["role": "system", "content": instructions],
                    ["role": "user", "content": [["type": "image_url", "image_url": ["url": imageURL]]]]]]
        default: throw AIError.invalidConfiguration
        }
        let result = try object(await fetch(request(profile, path: path, key: key, body: body, allowsMediaData: true)))
        return try responseText(result, api: profile.api)
    }

    func decide(input: String, question: String, profile: AIModelProfile, key: String?) async throws -> Double {
        guard profile.isEnabled else { throw AIError.disabled }
        guard profile.api == .decisions else { throw AIError.invalidConfiguration }
        let body: [String: Any] = ["model": try model(profile), "input": input,
                                  "questions": [["type": "predicate", "name": "result", "instructions": question]]]
        let result = try object(await fetch(request(profile, path: "decisions", key: key, body: body)))
        guard let answers = result["answers"] as? [[String: Any]], answers.count == 1,
              let answer = answers.first, answer["name"] as? String == "result" else { throw AIError.invalidResponse }
        if answer["type"] as? String == "refusal" { throw AIError.refused }
        guard answer["type"] as? String == "predicate", let number = answer["probability"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw AIError.invalidResponse }
        let probability = number.doubleValue
        guard probability.isFinite, (0...1).contains(probability) else { throw AIError.invalidResponse }
        return probability
    }

    func generateImage(prompt: String, profile: AIModelProfile, key: String?) async throws -> Data {
        guard profile.isEnabled else { throw AIError.disabled }
        guard profile.api == .images else { throw AIError.invalidConfiguration }
        let body: [String: Any] = ["model": try model(profile), "prompt": prompt]
        let result = try object(await fetch(request(profile, path: "images/generations", key: key, body: body)))
        return try await imageData(result)
    }

    func editImage(data: Data, prompt: String, profile: AIModelProfile, key: String?) async throws -> Data {
        guard profile.isEnabled else { throw AIError.disabled }
        guard profile.api == .images, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidConfiguration }
        let result = try object(await fetch(imageEditRequest(profile, data: data, prompt: prompt, key: key)))
        return try await imageData(result)
    }

    private func imageData(_ result: [String: Any]) async throws -> Data {
        guard let images = result["data"] as? [[String: Any]], let image = images.first else { throw AIError.invalidResponse }
        let data: Data
        if let encoded = image["b64_json"] as? String, let decoded = Data(base64Encoded: encoded) {
            data = decoded
        } else if let value = image["url"] as? String, let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  url.host != nil, url.user == nil, url.password == nil {
            var imageRequest = URLRequest(url: url)
            imageRequest.timeoutInterval = AIClient.requestTimeout
            data = try await fetch(imageRequest)
        } else { throw AIError.invalidResponse }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw AIError.invalidResponse }
        return data
    }
}
