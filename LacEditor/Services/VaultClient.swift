import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct VaultTreeEntry: Codable, Equatable {
    enum Kind: String, Codable { case file, directory }
    var path: String
    var name: String
    var kind: Kind
    var size: Int?
    var mtimeNs: Int64?
}

struct VaultTreePage: Equatable {
    var entries: [VaultTreeEntry]
    var nextPageToken: String?
    /// nil — старый сервер не сообщает полноту обхода: считать «неизвестно», не «полный».
    var listingComplete: Bool?
}

struct VaultFile: Equatable {
    var data: Data
    /// SHA-256 содержимого, строчными, без кавычек.
    var etag: String
    var modifiedNs: Int64?
}

enum VaultPutResult: Equatable {
    case saved(etag: String)
    case conflict(conflictID: String, currentETag: String)
}

struct VaultSearchHit: Codable, Equatable {
    var path: String
    var title: String?
    var snippet: String?
    var score: Double?
}

/// Итоговый файл задачи; скачивание в клиент этапа 2 не входит.
struct VaultJobArtifact: Equatable {
    var id: String
    var name: String
    var mimeType: String?
    var downloadPath: String
}

struct VaultJob: Equatable {
    enum State: String { case queued, running, completed, failed }
    var state: State
    var report: String?
    /// Пути `download_url` итоговых файлов.
    var artifacts: [String]
    var error: String?
    var retryable: Bool?
    var artifactItems: [VaultJobArtifact] = []
}

enum VaultClientError: Error, Equatable, LocalizedError {
    case offline, timeout, unauthorized, forbidden, notFound, tooLarge, preconditionRequired
    /// 422: причина сервера передаётся как есть.
    case ownerNotesOnly(reason: String?)
    /// 409 от `tree`: каталог изменился между страницами, обход начать заново.
    case listingChanged
    /// 503 поиска.
    case searchUnavailable
    case incompleteResponse
    case server(status: Int, message: String?)
    case invalidResponse
    /// Адрес не прошёл `VaultAddressRule`: запрос не отправлялся, токен не ушёл.
    case insecureAddress
    /// Ошибка TLS или сертификата сервера.
    case secureConnectionFailed

    var userMessage: String {
        switch self {
        case .offline: L10n.tr("服务器没有响应")
        case .timeout: L10n.tr("服务器响应超时")
        case .unauthorized: L10n.tr("服务器不接受令牌")
        case .forbidden: L10n.tr("服务器不允许访问此文件")
        case .notFound: L10n.tr("文件已在服务器上删除")
        case .tooLarge: L10n.tr("文件超过 16 MiB，服务器不接受")
        case .preconditionRequired: L10n.tr("未能发送，请重试")
        case .ownerNotesOnly: L10n.tr("服务器不接受“Owner Notes”分区之外的修改")
        case .listingChanged: L10n.tr("服务器上的笔记列表已变化，请重试")
        case .searchUnavailable: L10n.tr("服务器搜索不可用")
        case .incompleteResponse: L10n.tr("服务器的响应不完整，请重试")
        case .server(let status, _): L10n.tr("服务器返回错误（%d）", status)
        case .invalidResponse: L10n.tr("无法识别服务器的响应")
        case .secureConnectionFailed: L10n.tr("无法与服务器建立安全连接")
        case .insecureAddress: L10n.tr("未加密的 http:// 只能用于 127.0.0.1 或 localhost，其他地址请使用 https://")
        }
    }

    var errorDescription: String? { userMessage }
}

enum VaultEndpoint { case health, tree, file, put, resolve, search, submit, job }

/// Чистый разбор ответов сервера (без сети).
enum VaultAPIParser {
    static func jsonObject(_ body: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: body), let result = value as? [String: Any] else {
            throw VaultClientError.invalidResponse
        }
        return result
    }

    private static func int64(_ value: Any?) -> Int64? { value as? Int64 }

    static func tree(_ body: Data) throws -> VaultTreePage {
        let root = try jsonObject(body)
        guard let raw = root["entries"] as? [[String: Any]] else { throw VaultClientError.invalidResponse }
        var entries: [VaultTreeEntry] = []
        for item in raw {
            guard let path = item["path"] as? String, let name = item["name"] as? String,
                  let kindText = item["kind"] as? String else { throw VaultClientError.invalidResponse }
            // Неизвестный вид записи (не файл и не каталог) клиенту не нужен.
            guard let kind = VaultTreeEntry.Kind(rawValue: kindText) else { continue }
            entries.append(VaultTreeEntry(path: path, name: name, kind: kind,
                                          size: int64(item["size"]).map(Int.init), mtimeNs: int64(item["mtime_ns"])))
        }
        let token = root["next_page_token"] as? String
        return VaultTreePage(entries: entries, nextPageToken: token?.isEmpty == false ? token : nil,
                             listingComplete: root["listing_complete"] as? Bool)
    }

    static func search(_ body: Data) throws -> [VaultSearchHit] {
        let root = try jsonObject(body)
        guard let raw = root["results"] as? [[String: Any]] else { throw VaultClientError.invalidResponse }
        return try raw.map { item in
            guard let path = item["path"] as? String else { throw VaultClientError.invalidResponse }
            return VaultSearchHit(path: path, title: item["title"] as? String, snippet: item["snippet"] as? String, score: nil)
        }
    }

    static func putResult(_ body: Data) throws -> String {
        guard let raw = try jsonObject(body)["etag"] as? String, let normalized = etag(fromHeader: raw) else {
            throw VaultClientError.invalidResponse
        }
        return normalized
    }

    static func conflict(_ body: Data) throws -> (id: String, currentETag: String) {
        let root = try jsonObject(body)
        guard let id = root["conflict_id"] as? String, !id.isEmpty,
              let current = root["current_etag"] as? String, let currentETag = etag(fromHeader: current) else {
            throw VaultClientError.invalidResponse
        }
        return (id, currentETag)
    }

    static func submit(_ body: Data) throws -> String {
        guard let id = try jsonObject(body)["job_id"] as? String, !id.isEmpty else { throw VaultClientError.invalidResponse }
        return id
    }

    static func job(_ body: Data) throws -> VaultJob {
        let root = try jsonObject(body)
        guard let status = root["status"] as? String, let state = VaultJob.State(rawValue: status) else {
            throw VaultClientError.invalidResponse
        }
        let result = root["result"] as? [String: Any]
        let rawArtifacts = (result?["artifacts"] as? [[String: Any]]) ?? (root["artifacts"] as? [[String: Any]]) ?? []
        var items: [VaultJobArtifact] = []
        for item in rawArtifacts {
            guard let path = item["download_url"] as? String else { continue }
            let id = item["id"] as? String ?? ""
            items.append(VaultJobArtifact(id: id, name: item["name"] as? String ?? id,
                                          mimeType: item["mime_type"] as? String, downloadPath: path))
        }
        return VaultJob(state: state, report: result?["report"] as? String, artifacts: items.map(\.downloadPath),
                        error: (root["error"] as? String) ?? (result?["error"] as? String),
                        retryable: root["retryable"] as? Bool, artifactItems: items)
    }

    /// Снимает кавычки (и префикс слабого ETag), приводит к нижнему регистру; нужно ровно 64 шестнадцатеричных знака.
    static func etag(fromHeader value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("W/") { text.removeFirst(2) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        text = text.lowercased()
        guard text.utf8.count == 64, text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return text
    }

    static func errorInfo(_ body: Data) -> (message: String?, reason: String?) {
        guard let root = try? jsonObject(body) else { return (nil, nil) }
        return ((root["error"] as? String) ?? (root["message"] as? String), root["reason"] as? String)
    }

    static func error(status: Int, body: Data, endpoint: VaultEndpoint) -> VaultClientError {
        let info = errorInfo(body)
        switch status {
        case 400:
            if endpoint == .put, let message = info.message,
               message.contains("incomplete request body") || message.contains("body checksum mismatch") {
                return .incompleteResponse
            }
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: if endpoint == .tree { return .listingChanged }
        case 413: return .tooLarge
        case 422: return .ownerNotesOnly(reason: info.reason)
        case 428: return .preconditionRequired
        case 503: if endpoint == .search { return .searchUnavailable }
        default: break
        }
        return .server(status: status, message: info.message)
    }
}

/// Запрещает перенаправления: токен не должен уйти на другой адрес.
private final class VaultRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Клиент сетевого API сервера хранилища. Токен в описание и журнал не попадает.
final class VaultClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = VaultClient.sharedSession) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Общая сессия по умолчанию: без состояния, поэтому каждый клиент не плодит свою.
    static let sharedSession = makeSession()

    /// Эфемерная сессия: без кэша, cookies и хранилища учётных данных; перенаправления запрещены.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: VaultRedirectBlocker(), delegateQueue: nil)
    }

    var description: String {
        let scheme = baseURL.scheme ?? "?"
        let host = baseURL.host ?? "?"
        return "VaultClient(\(scheme)://\(host)\(baseURL.port.map { ":\($0)" } ?? ""))"
    }
    var debugDescription: String { description }

    // MARK: Запросы

    func health(timeout: TimeInterval = 15) async throws {
        let (data, _) = try await send(method: "GET", path: "/healthz", endpoint: .health, authorized: false, timeout: timeout)
        guard try VaultAPIParser.jsonObject(data)["status"] as? String == "ok" else {
            throw VaultClientError.invalidResponse
        }
    }

    func tree(path: String, depth: Int, pageSize: Int, pageToken: String?) async throws -> VaultTreePage {
        var query = "path=\(Self.encode(path))&depth=\(depth)&page_size=\(pageSize)"
        if let pageToken { query += "&page_token=\(Self.encode(pageToken))" }
        let (data, _) = try await send(method: "GET", path: "/v1/vault/tree", query: query, endpoint: .tree)
        return try VaultAPIParser.tree(data)
    }

    func file(path: String) async throws -> VaultFile {
        let (data, response) = try await send(method: "GET", path: "/v1/vault/file", query: "path=\(Self.encode(path))",
                                              endpoint: .file, accept: "*/*", timeout: 60)
        // Целостность проверяет SHA-256: Content-Length у сжатых и порционных ответов может отсутствовать.
        guard let etag = VaultAPIParser.etag(fromHeader: response.value(forHTTPHeaderField: "ETag")) else {
            throw VaultClientError.invalidResponse
        }
        guard Self.sha256Hex(data) == etag else { throw VaultClientError.incompleteResponse }
        let modified = response.value(forHTTPHeaderField: "X-File-Modified-Ns").flatMap { Int64($0) }
        return VaultFile(data: data, etag: etag, modifiedNs: modified)
    }

    func put(path: String, data: Data, ifMatch: String) async throws -> VaultPutResult {
        let etag = VaultAPIParser.etag(fromHeader: ifMatch) ?? ifMatch.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let headers = ["If-Match": "\"\(etag)\"", "Content-Type": "application/octet-stream",
                       "X-Content-SHA256": Self.sha256Hex(data)]
        let (body, response) = try await send(method: "PUT", path: "/v1/vault/file", query: "path=\(Self.encode(path))",
                                              endpoint: .put, headers: headers, body: data, passthrough: [409])
        if response.statusCode == 409 {
            let parsed = try VaultAPIParser.conflict(body)
            return .conflict(conflictID: parsed.id, currentETag: parsed.currentETag)
        }
        return .saved(etag: try VaultAPIParser.putResult(body))
    }

    func resolveConflict(id: String, decision: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["decision": decision])
        _ = try await send(method: "POST", path: "/v1/vault/conflicts/\(Self.encodeComponent(id))/resolve", endpoint: .resolve,
                           headers: ["Content-Type": "application/json"], body: body)
    }

    func search(query: String) async throws -> [VaultSearchHit] {
        let (data, _) = try await send(method: "GET", path: "/v1/vault/search", query: "q=\(Self.encode(query))", endpoint: .search)
        return try VaultAPIParser.search(data)
    }

    func submitRequest(requestID: String, text: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["request_id": requestID, "text": text, "client": "laceditor"])
        let (data, _) = try await send(method: "POST", path: "/v1/requests", endpoint: .submit,
                                       headers: ["Content-Type": "application/json"], body: body)
        return try VaultAPIParser.submit(data)
    }

    func job(id: String) async throws -> VaultJob {
        let (data, _) = try await send(method: "GET", path: "/v1/jobs/\(Self.encodeComponent(id))", endpoint: .job)
        return try VaultAPIParser.job(data)
    }

    /// Скачивает итоговый файл задачи по `download_url` (`/v1/jobs/<id>/artifacts/<имя>`).
    func downloadArtifact(path: String) async throws -> VaultArtifactData {
        guard path.hasPrefix("/v1/jobs/"), !path.contains(".."), !path.contains("?"), !path.contains("#") else {
            throw VaultClientError.invalidResponse
        }
        let (data, response) = try await send(method: "GET", path: path, endpoint: .job, accept: "*/*", timeout: 60)
        if let lengthText = response.value(forHTTPHeaderField: "Content-Length"), let length = Int(lengthText),
           length != data.count {
            throw VaultClientError.incompleteResponse
        }
        return VaultArtifactData(data: data, fileName: Self.fileName(fromContentDisposition: response.value(forHTTPHeaderField: "Content-Disposition")))
    }

    /// Имя из `filename="…"` без `/` и `\`; nil, если заголовка нет или имя пустое.
    static func fileName(fromContentDisposition header: String?) -> String? {
        guard let header, let range = header.range(of: "filename=") else { return nil }
        var name = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let end = name.firstIndex(of: ";"), !name.hasPrefix("\"") { name = String(name[..<end]) }
        if name.hasPrefix("\"") {
            name.removeFirst()
            if let close = name.firstIndex(of: "\"") { name = String(name[..<close]) }
        }
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "." || name == ".." ? nil : name
    }

    // MARK: Отправка

    private func send(method: String, path: String, query: String? = nil, endpoint: VaultEndpoint,
                      authorized: Bool = true, accept: String = "application/json", timeout: TimeInterval = 15,
                      headers: [String: String] = [:], body: Data? = nil,
                      passthrough: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        // Проверка до создания запроса: токен не должен уйти по открытому каналу.
        guard VaultAddressRule.isAllowed(baseURL),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw VaultClientError.insecureAddress
        }
        components.percentEncodedPath = path
        components.percentEncodedQuery = query
        guard let url = components.url else { throw VaultClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = timeout
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: VaultRedirectBlocker())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw VaultClientError.timeout
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                throw VaultClientError.secureConnectionFailed
            default: throw VaultClientError.offline
            }
        } catch {
            throw VaultClientError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw VaultClientError.invalidResponse }
        let status = http.statusCode
        if (300..<400).contains(status) { throw VaultClientError.server(status: status, message: nil) }
        if (200..<300).contains(status) { return (data, http) }
        if passthrough.contains(status) { return (data, http) }
        throw VaultAPIParser.error(status: status, body: data, endpoint: endpoint)
    }

    // MARK: Вспомогательное

    /// Кодирует всё, кроме `A-Za-z0-9-._~` и `/`, чтобы сервер прочитал значение без искажений.
    static func encode(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            let isPlain = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 95 || byte == 126 || byte == 47
            result += isPlain ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }
        return result
    }

    /// Как `encode`, но «/» тоже кодируется: идентификатор остаётся одним компонентом пути.
    static func encodeComponent(_ text: String) -> String {
        let encoded = encode(text).replacingOccurrences(of: "/", with: "%2F")
        // «.» и «..» сервер или URL-разборщик читает как переход по пути.
        return !text.isEmpty && text.allSatisfy({ $0 == "." }) ? encoded.replacingOccurrences(of: ".", with: "%2E") : encoded
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
