import Foundation
import ImageIO

enum AIError: LocalizedError {
    case invalidConfiguration, disabled, keychain, network, http(Int, String?), invalidResponse, refused

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return L10n.tr("AI 配置无效")
        case .disabled: return L10n.tr("AI 功能已关闭")
        case .keychain: return L10n.tr("无法访问 AI 密钥")
        case .network: return L10n.tr("AI 网络请求失败")
        case .http(let status, let detail):
            let summary = L10n.tr("AI 服务返回错误（HTTP %d）", status)
            return if let detail { summary + "\n" + detail } else { summary }
        case .invalidResponse: return L10n.tr("AI 服务返回了无效或不完整的结果")
        case .refused: return L10n.tr("AI 服务拒绝了请求")
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

struct AIClient {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    private func endpoint(_ profile: AIModelProfile, path: String) throws -> URL {
        let baseURL = try AIModelProfile.normalizedBaseURL(profile.baseURL)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw AIError.invalidConfiguration }
        components.path += "/" + path
        guard let url = components.url else { throw AIError.invalidConfiguration }
        return url
    }

    private func request(_ profile: AIModelProfile, path: String, key: String?, body: [String: Any]? = nil,
                         allowsMediaData: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(profile, path: path))
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
            throw AIError.network
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
        let result = try object(await fetch(request(profile, path: "models", key: key)))
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

    private func responseText(_ result: [String: Any], api: AIAPIProtocol) throws -> String {
        let text: String
        if api == .responses {
            guard result["status"] as? String == "completed", let output = result["output"] as? [[String: Any]] else { throw AIError.invalidResponse }
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
            data = try await fetch(URLRequest(url: url))
        } else { throw AIError.invalidResponse }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw AIError.invalidResponse }
        return data
    }
}
