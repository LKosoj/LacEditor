import Foundation
import Darwin

final class MarkdownRemoteImageDownloader: @unchecked Sendable {
    typealias AddressResolver = @Sendable (String) async throws -> [String]

    struct Limits: Sendable {
        var maximumImageBytes = 8 * 1024 * 1024
        var maximumBatchBytes = 32 * 1024 * 1024
        var maximumImages = 32

        init(maximumImageBytes: Int = 8 * 1024 * 1024, maximumBatchBytes: Int = 32 * 1024 * 1024, maximumImages: Int = 32) {
            self.maximumImageBytes = maximumImageBytes
            self.maximumBatchBytes = maximumBatchBytes
            self.maximumImages = maximumImages
        }
    }

    enum DownloadError: Error {
        case invalidURL, blockedAddress, response, limit, invalidImage
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private actor Budget {
        private var remainingImages: Int
        private var remainingBytes: Int

        init(limits: Limits) {
            remainingImages = limits.maximumImages
            remainingBytes = limits.maximumBatchBytes
        }

        func beginImage() -> Bool {
            guard remainingImages > 0 else { return false }
            remainingImages -= 1
            return true
        }

        func canReceive(declaredLength: Int64) -> Bool {
            declaredLength <= 0 || declaredLength <= remainingBytes
        }

        func consume(_ count: Int) -> Bool {
            guard count <= remainingBytes else { return false }
            remainingBytes -= count
            return true
        }
    }

    private let session: URLSession
    private let limits: Limits
    private let budget: Budget
    private let resolver: AddressResolver

    init(session: URLSession? = nil, limits: Limits = .init(), resolver: @escaping AddressResolver = MarkdownRemoteImageDownloader.resolveSystemAddresses) {
        self.session = session ?? Self.makeSession()
        self.limits = limits
        self.budget = Budget(limits: limits)
        self.resolver = resolver
    }

    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.protocolClasses = protocolClasses
        return URLSession(configuration: configuration)
    }

    func dataURIs(for addresses: [String]) async throws -> [Data: String] {
        var result: [Data: String] = [:]
        var downloaded: [String: MarkdownImageUploadService.Payload] = [:]
        var failed = Set<String>()
        for address in addresses {
            try Task.checkCancellation()
            guard let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let key = components?.url?.absoluteString ?? url.absoluteString
            if failed.contains(key) { continue }
            let payload: MarkdownImageUploadService.Payload
            if let cached = downloaded[key] { payload = cached }
            else {
                do {
                    payload = try await download(url)
                    downloaded[key] = payload
                } catch {
                    try Task.checkCancellation()
                    failed.insert(key)
                    continue
                }
            }
            result[Data(address.utf8)] = MarkdownImageUploadService.dataURI(payload, address: address)
        }
        try Task.checkCancellation()
        return result
    }

    func download(_ url: URL) async throws -> MarkdownImageUploadService.Payload {
        let host = try Self.normalizedHost(url)
        if Self.isLocalHostname(host) { throw DownloadError.blockedAddress }
        if Self.isIPAddress(host) {
            try Self.validateResolvedAddress(host)
        } else {
            let addresses = try await resolver(host)
            guard !addresses.isEmpty else { throw DownloadError.response }
            for address in addresses { try Self.validateResolvedAddress(address) }
        }
        guard limits.maximumImageBytes > 0, limits.maximumBatchBytes > 0, await budget.beginImage() else { throw DownloadError.limit }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let requestURL = components?.url else { throw DownloadError.invalidURL }
        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectDelegate())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, final.scheme?.lowercased() == requestURL.scheme?.lowercased(),
              final.host?.lowercased() == requestURL.host?.lowercased(), final.port == requestURL.port else { throw DownloadError.response }
        guard response.expectedContentLength <= 0 || response.expectedContentLength <= limits.maximumImageBytes,
              await budget.canReceive(declaredLength: response.expectedContentLength) else { throw DownloadError.limit }
        var data = Data()
        var chunk = Data()
        chunk.reserveCapacity(16 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count + chunk.count < limits.maximumImageBytes else { throw DownloadError.limit }
            chunk.append(byte)
            if chunk.count == 16 * 1024 {
                guard await budget.consume(chunk.count) else { throw DownloadError.limit }
                data.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            guard await budget.consume(chunk.count) else { throw DownloadError.limit }
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard let payload = try? MarkdownImageUploadService.payload(data: data) else { throw DownloadError.invalidImage }
        return payload
    }

    static func validate(_ url: URL) throws {
        let host = try normalizedHost(url)
        if isLocalHostname(host) { throw DownloadError.blockedAddress }
        if isIPAddress(host) { try validateResolvedAddress(host) }
    }

    @Sendable private static func resolveSystemAddresses(host: String) async throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0, let first else { throw DownloadError.response }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            defer { current = node.pointee.ai_next }
            var buffer = [CChar](repeating: 0, count: 1025)
            let result = getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { throw DownloadError.response }
            addresses.append(String(cString: buffer))
        }
        return addresses
    }

    private static func normalizedHost(_ url: URL) throws -> String {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { throw DownloadError.invalidURL }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost")
    }

    private static func addressBody(_ host: String) -> String {
        var host = host
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        return host
    }

    private static func isIPAddress(_ host: String) -> Bool {
        let host = addressBody(host)
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
    }

    private static func validateResolvedAddress(_ host: String) throws {
        let host = addressBody(host)
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            guard !isBlockedIPv4(UInt32(bigEndian: ipv4.s_addr)) else { throw DownloadError.blockedAddress }
            return
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { throw DownloadError.response }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            let value = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16) | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            guard !isBlockedIPv4(value) else { throw DownloadError.blockedAddress }
            return
        }
        let unspecified = bytes.allSatisfy { $0 == 0 }
        let loopback = bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1
        let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let siteLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0
        let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
        let multicast = (bytes[0] & 0xf0) == 0xf0
        guard !unspecified, !loopback, !linkLocal, !siteLocal, !uniqueLocal, !multicast else { throw DownloadError.blockedAddress }
    }

    private static func isBlockedIPv4(_ value: UInt32) -> Bool {
        let first = UInt8(value >> 24), second = UInt8((value >> 16) & 0xff)
        if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
        if first == 100 && (64...127).contains(second) { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        return false
    }
}
