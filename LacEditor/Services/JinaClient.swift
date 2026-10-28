import Foundation

struct JinaPage {
    let title: String
    let url: URL
    let content: String
}

private final class JinaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct JinaClient {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    private func validURL(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              let url = parts.url else { throw AIError.invalidConfiguration }
        return url
    }

    private func request(kind: JinaServiceKind, configuration: JinaConfiguration, key: String?, body: [String: String]) async throws -> [String: Any] {
        guard configuration.isEnabled(for: kind) else { throw AIError.disabled }
        let endpoint = configuration.endpoint(for: kind)
        guard let parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.query == nil, parts.fragment == nil else { throw AIError.invalidConfiguration }
        var request = URLRequest(url: try validURL(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do {
            let (result, response) = try await session.data(for: request, delegate: JinaRedirectDelegate())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw AIError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw AIError.http(response.statusCode) }
            data = result
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AIError { throw error }
        catch { throw AIError.network }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.invalidResponse }
        return object
    }

    private func page(_ object: [String: Any]) throws -> JinaPage {
        guard let rawURL = object["url"] as? String else { throw AIError.invalidResponse }
        let url: URL
        do { url = try validURL(rawURL) } catch { throw AIError.invalidResponse }
        return JinaPage(title: object["title"] as? String ?? "", url: url,
                        content: object["content"] as? String ?? object["description"] as? String ?? "")
    }

    func search(query: String, configuration: JinaConfiguration, key: String?) async throws -> [JinaPage] {
        let object = try await request(kind: .search, configuration: configuration, key: key, body: ["q": query])
        guard let entries = object["data"] as? [[String: Any]] else { throw AIError.invalidResponse }
        return try entries.map(page)
    }

    func read(url: URL, configuration: JinaConfiguration, key: String?) async throws -> JinaPage {
        _ = try validURL(url.absoluteString)
        let object = try await request(kind: .reader, configuration: configuration, key: key, body: ["url": url.absoluteString])
        guard let entry = object["data"] as? [String: Any], entry["content"] is String else { throw AIError.invalidResponse }
        return try page(entry)
    }
}
