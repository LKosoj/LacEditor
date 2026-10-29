import Foundation

enum MarkdownLinkNavigationService {
    enum Destination: Equatable {
        case fragment(String)
        case file(URL, fragment: String?)
        case external(URL)
    }

    enum NavigationError: Error { case invalidAddress, unsupportedScheme, missingDocumentURL }

    static func fileTarget(_ url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> (url: URL, exists: Bool) {
        if exists(url) { return (url, true) }
        guard url.pathExtension.isEmpty else { return (url, false) }
        let markdown = url.appendingPathExtension("md")
        if exists(markdown) { return (markdown, true) }
        let alternate = url.appendingPathExtension("markdown")
        if exists(alternate) { return (alternate, true) }
        return (markdown, false)
    }

    static func destination(for address: String, documentURL: URL?) throws -> Destination {
        guard !address.isEmpty, let parts = URLComponents(string: address) else { throw NavigationError.invalidAddress }
        if address.hasPrefix("#"), let fragment = parts.fragment { return .fragment(fragment) }
        if let scheme = parts.scheme?.lowercased(), scheme != "file" {
            guard ["http", "https", "mailto"].contains(scheme) else { throw NavigationError.unsupportedScheme }
            guard let url = parts.url,
                  scheme == "mailto" ? !parts.path.isEmpty : !(parts.host ?? "").isEmpty else { throw NavigationError.invalidAddress }
            return .external(url)
        }
        let base: URL?
        if address.hasPrefix("/") { base = URL(fileURLWithPath: "/", isDirectory: true) }
        else { base = documentURL }
        guard parts.scheme != nil || base?.isFileURL == true else { throw NavigationError.missingDocumentURL }
        guard let resolved = URL(string: address, relativeTo: base)?.absoluteURL, resolved.isFileURL, resolved.path.hasPrefix("/"),
              var file = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else { throw NavigationError.invalidAddress }
        let fragment = file.fragment
        guard file.host == nil || file.host == "" || file.host?.lowercased() == "localhost" else {
            throw NavigationError.unsupportedScheme
        }
        file.fragment = nil
        file.query = nil
        guard let url = file.url else { throw NavigationError.invalidAddress }
        return .file(url.standardizedFileURL, fragment: fragment)
    }
}
