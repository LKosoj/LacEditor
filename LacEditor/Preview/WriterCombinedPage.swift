import Foundation

/// Страница сводного просмотра: тексты сцен подряд, у каждой части подпись-ссылка «Название · Открыть».
/// Чистая сборка HTML без окон: рендер каждой части делает `MarkdownHTMLRenderer`, шапка, CSP и стили берутся у `MarkdownRenderedPage`.
enum WriterCombinedPage {
    struct PartInput: Sendable {
        let title: String
        let text: String
        let documentURL: URL
    }

    static let scheme = "lacpart"

    /// Случайная строка на один рендер: ссылка из документа с чужим токеном не будет принята за ссылку части.
    static func makeToken() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func partURL(token: String, index: Int) -> URL {
        URL(string: "\(scheme)://\(token)/\(index)") ?? URL(fileURLWithPath: "/")
    }

    /// Номер части по ссылке; nil, если схема, токен или номер не наши.
    static func partIndex(from url: URL, token: String) -> Int? {
        guard url.scheme == scheme, !token.isEmpty, url.host == token else { return nil }
        let path = url.path
        guard path.hasPrefix("/"), let index = Int(path.dropFirst()), index >= 0 else { return nil }
        return index
    }

    static func html(parts: [PartInput], token: String, darkMode: Bool, syntax: MarkdownSyntaxOptions, openLabel: String) -> String {
        var sections: [String] = []
        for (index, part) in parts.enumerated() {
            var page = MarkdownHTMLRenderer.renderPage(part.text, darkMode: darkMode, renderEmoji: true, resolveLocalImages: true,
                                                       documentURL: part.documentURL, prepareRemoteImages: true, syntax: syntax,
                                                       highlightCode: true)
            // CSP страницы пускает только `data:`: внешние картинки скрываются, локальные встраиваются.
            try? page.hideRemoteImages()
            try? page.prepareLocalMedia(load: true)
            let label = escape("\(part.title) · \(openLabel)")
            sections.append("<section class=\"lac-part\"><div class=\"lac-part-label\"><a href=\"\(partURL(token: token, index: index).absoluteString)\">\(label)</a></div>\(page.body)</section>")
        }
        let full = MarkdownRenderedPage(body: sections.joined(separator: "\n"), darkMode: darkMode).html
        let style = "<style>.lac-part-label{font-size:.8em;color:var(--secondary);margin:2em 0 .5em}"
            + ".lac-part-label a{color:inherit;text-decoration:none}"
            + ".lac-part+.lac-part{border-top:1px solid var(--border)}</style>\n"
        guard let head = full.range(of: "</head>") else { return full }
        return full.replacingCharacters(in: head.lowerBound..<head.lowerBound, with: style)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
