import Foundation
import cmark_gfm
import UniformTypeIdentifiers

/// Keep the parsed body separate from the page shell. Ordinary edits replace
/// only article content; appearance changes reuse the same parsed Markdown.
struct MarkdownTypography: Equatable, Sendable {
    let fontSize: Double
    let lineHeight: Double
    let textFamily: String?
    let codeFamily: String?
    let maximumWidth: Double?
    let usesCustomFontMetrics: Bool
    let tocMaxLevel: Int
    let ligatures: Int?
    let smallCapsLevels: Set<Int>
    let uppercaseHeadingLevels: Set<Int>
    let centeredHeadingLevels: Set<Int>
    let textAlignment: String?
    let rightToLeft: Bool
    let verticalWriting: Bool
    let strikeCompletedTasks: Bool
    let numberHeadings: Bool
    let listStyles: MarkdownListStyles
    let paragraphSpacing: Double?
    let lightColors: MarkdownColorOverrides
    let darkColors: MarkdownColorOverrides

    init(fontSize: Double, lineHeight: Double, textFamily: String? = nil, codeFamily: String? = nil,
         maximumWidth: Double? = nil, usesCustomFontMetrics: Bool = true, tocMaxLevel: Int = 6, ligatures: Int? = nil, smallCapsLevels: Set<Int> = [], centeredHeadingLevels: Set<Int> = [], textAlignment: String? = nil, rightToLeft: Bool = false, verticalWriting: Bool = false, strikeCompletedTasks: Bool = false, numberHeadings: Bool = false, paragraphSpacing: Double? = nil,
         listStyles: MarkdownListStyles = .init(), uppercaseHeadingLevels: Set<Int> = [], lightColors: MarkdownColorOverrides = .init(), darkColors: MarkdownColorOverrides = .init()) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.textFamily = textFamily
        self.codeFamily = codeFamily
        self.maximumWidth = maximumWidth
        self.usesCustomFontMetrics = usesCustomFontMetrics
        self.tocMaxLevel = tocMaxLevel
        self.ligatures = ligatures
        self.smallCapsLevels = smallCapsLevels
        self.uppercaseHeadingLevels = uppercaseHeadingLevels
        self.centeredHeadingLevels = centeredHeadingLevels
        self.textAlignment = textAlignment
        self.rightToLeft = rightToLeft
        self.verticalWriting = verticalWriting
        self.strikeCompletedTasks = strikeCompletedTasks
        self.numberHeadings = numberHeadings
        self.listStyles = listStyles
        self.paragraphSpacing = paragraphSpacing
        self.lightColors = lightColors
        self.darkColors = darkColors
    }
    var paragraphCSS: String {
        var rules: [String] = []
        if let textAlignment, ["left", "center", "right", "justify"].contains(textAlignment) {
            rules.append("article{text-align:\(textAlignment)}")
        }
        if rightToLeft { rules.append("article{direction:rtl}") }
        if verticalWriting {
            rules.append("article{writing-mode:vertical-rl;text-orientation:mixed}@media screen{article{height:100vh;overflow-x:auto}}")
        }
        if strikeCompletedTasks { rules.append("article li:has(>span[data-lac-checked-task]){text-decoration:line-through}") }
        if numberHeadings { rules.append("article span[data-lac-heading-number]::before{content:attr(data-lac-heading-number)}") }
        if let paragraphSpacing, paragraphSpacing.isFinite, paragraphSpacing >= 0 {
            if verticalWriting { rules.append("article p{margin:0;margin-block-end:\(paragraphSpacing)px}") }
            else { rules.append("article p{margin:0 0 \(paragraphSpacing)px}") }
        }
        let headings = centeredHeadingLevels.filter { (1...6).contains($0) }.sorted().map { "article h\($0)" }
        if !headings.isEmpty { rules.append(headings.joined(separator: ",") + "{text-align:center}") }
        let uppercase = uppercaseHeadingLevels.filter { (1...6).contains($0) }.sorted().map { "article h\($0)" }
        if !uppercase.isEmpty {
            rules.append(uppercase.joined(separator: ",") + "{text-transform:uppercase}")
            rules.append(uppercase.map { $0 + " [data-lac-math]" }.joined(separator: ",") + "{text-transform:none}")
        }
        return rules.joined()
    }

    var smallCapsCSS: String {
        let selectors = smallCapsLevels.filter { (1...6).contains($0) }.sorted().map { "h\($0)" }
        return selectors.isEmpty ? "" : selectors.joined(separator: ",") + "{font-variant:small-caps}"
    }

    var ligatureCSS: String? {
        switch ligatures {
        case 0: return "none"
        case 1: return "normal"
        case 2: return "common-ligatures discretionary-ligatures historical-ligatures contextual"
        default: return nil
        }
    }

}

struct MarkdownRenderedMath: Sendable {
    let source: String
    let display: Bool
}

struct MarkdownRenderedDiagram: Sendable {
    let kind: MarkdownDiagram.Kind
    let source: String
}

struct MarkdownRenderedPage: Sendable {
    struct LocalMediaResource: Sendable {
        let url: URL
        let fragment: String
    }
    var body: String
    var darkMode: Bool
    var typography: MarkdownTypography?
    let headingIDs: Set<String>
    let formulas: [MarkdownRenderedMath]
    let diagrams: [MarkdownRenderedDiagram]
    let omittedHTML: Bool
    let preserveWhitespace: Bool
    var remoteImageMarkers: [String: String] = [:]
    var localMediaMarkers: [String: LocalMediaResource] = [:]
    var rawHTMLBlocks: [(marker: String, html: String)] = []
    var rawHTMLBlockProofFailed = false
    /// Системный акцент для декора; задаётся только в предпросмотре.
    var previewAccent: String?
    var listDepths: Set<Int> = []
    var paragraphCSS: String { (typography?.paragraphCSS ?? "") + (typography?.listStyles.cssRules(depths: listDepths) ?? "") }

    private func remoteImageMatches() throws -> [NSTextCheckingResult] {
        let expression = try NSRegularExpression(pattern: "LACREMOTE[0-9A-F]{32}")
        return expression.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length))
    }

    private mutating func replaceRemoteImages(_ values: [Data: String], matches: [NSTextCheckingResult]) throws {
        let original = body as NSString
        let result = NSMutableString(string: body)
        for match in matches.reversed() {
            try Task.checkCancellation()
            guard let address = remoteImageMarkers[original.substring(with: match.range)] else { continue }
            result.replaceCharacters(in: match.range, with: values[Data(address.utf8)] ?? "data:,")
        }
        body = result as String
        remoteImageMarkers.removeAll()
    }

    mutating func hideRemoteImages() throws {
        guard !remoteImageMarkers.isEmpty else { return }
        try replaceRemoteImages([:], matches: remoteImageMatches())
    }

    mutating func resolveRemoteImages(session: URLSession = .shared) async throws {
        guard !remoteImageMarkers.isEmpty else { return }
        let matches = try remoteImageMatches()
        let original = body as NSString
        let addresses = matches.compactMap { remoteImageMarkers[original.substring(with: $0.range)] }
        let values = try await MarkdownImageUploadService.remoteImageDataURIs(addresses, session: session)
        try replaceRemoteImages(values, matches: matches)
    }

    mutating func prepareLocalMedia(load: Bool) throws {
        guard !localMediaMarkers.isEmpty else { return }
        let expression = try NSRegularExpression(pattern: "LACLOCALMEDIA[0-9A-F]{32}X[0-9]+")
        func prepare(_ text: String) throws -> String {
            let original = text as NSString
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: original.length))
            let result = NSMutableString(string: text)
            for match in matches.reversed() {
                try Task.checkCancellation()
                guard let resource = localMediaMarkers[original.substring(with: match.range)] else { continue }
                var replacement = "data:,"
                if load, let mime = UTType(filenameExtension: resource.url.pathExtension)?.preferredMIMEType,
                   let bytes = try? Data(contentsOf: URL(fileURLWithPath: resource.url.path)) {
                    try Task.checkCancellation()
                    replacement = "data:\(mime);base64,\(bytes.base64EncodedString())" + resource.fragment
                }
                result.replaceCharacters(in: match.range, with: replacement)
            }
            return result as String
        }
        let preparedBody = try prepare(body)
        let preparedRaw = try rawHTMLBlocks.map { (marker: $0.marker, html: try prepare($0.html)) }
        try Task.checkCancellation()
        body = preparedBody
        rawHTMLBlocks = preparedRaw
        localMediaMarkers.removeAll()
    }

    init(body: String, darkMode: Bool, headingIDs: Set<String> = [], typography: MarkdownTypography? = nil, formulas: [MarkdownRenderedMath] = [], diagrams: [MarkdownRenderedDiagram] = [], omittedHTML: Bool = false, preserveWhitespace: Bool = false) {
        self.body = body
        self.darkMode = darkMode
        self.typography = typography
        self.headingIDs = headingIDs
        self.formulas = formulas
        self.diagrams = diagrams
        self.omittedHTML = omittedHTML
        self.preserveWhitespace = preserveWhitespace
    }

    /// Цвета корня страницы: пользовательские + (только предпросмотр) системный акцент для декора.
    var rootColorVariables: [String: String] {
        var values = typography.map { (darkMode ? $0.darkColors : $0.lightColors).cssVariables } ?? [:]
        if values["--accent"] == nil, let previewAccent { values["--lac-accent"] = previewAccent }
        return values
    }

    var html: String {
        func cssFamily(_ family: String) -> String {
            family.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
        }
        var displayedBody = body
        let maximumLevel = typography?.tocMaxLevel ?? 6
        for level in 1...6 where level > maximumLevel {
            displayedBody = displayedBody.replacingOccurrences(of: "<li data-level=\"\(level)\">", with: "<li data-level=\"\(level)\" hidden>")
        }
        let colors = rootColorVariables
        let colorDeclarations = colors.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ";")
        let colorStyle = colors.isEmpty ? "" : " style=\"\(colorDeclarations)\""
        let bodyStyle = typography.map { value in
            var styles: [String] = []
            if value.usesCustomFontMetrics {
                styles.append("font-size:\(value.fontSize)px;line-height:\(value.lineHeight)px")
                if let family = value.textFamily { styles.append("font-family:\(cssFamily(family))") }
                if let family = value.codeFamily { styles.append("--lac-code-font:\(cssFamily(family))") }
            }
            if let ligatures = value.ligatureCSS { styles.append("font-variant-ligatures:\(ligatures)") }
            if let width = value.maximumWidth {
                styles.append("--lac-content-width:\(width)px;--lac-print-width:min(100%,\(width)px)")
            }
            return styles.isEmpty ? "" : " style=\"\(styles.joined(separator: ";"))\""
        } ?? ""
        return """
        <!doctype html>
        <html lang="\(L10n.languageCode)" data-theme="\(darkMode ? "dark" : "light")"\(colorStyle)>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; media-src data: http: https:; frame-src http: https:; style-src 'unsafe-inline'">
        <style>\(Self.styles)</style>
        <style id="lac-whitespace">\(preserveWhitespace ? "article span[data-lac-whitespace]{white-space:break-spaces}" : "")</style>
        <style id="lac-heading-small-caps">\(typography?.smallCapsCSS ?? "")</style>
        <style id="lac-paragraph-settings">\(paragraphCSS)</style>
        </head>
        <body\(bodyStyle)><article aria-label="\(L10n.tr("Markdown 预览"))">\(displayedBody)</article></body>
        </html>
        """
    }

    private static let styles = """
      :root {
        color-scheme: light;
        --page: #fbfbfb; --text: #303038; --secondary: #6d6d78;
        --border: #e2e2e8; --code: #f0f0f4; --accent: #5c61ba; --quote: #f4f4f8;
        --mark: #fff1a8; --kbd-edge: #b4b4be;
        --alert-note: #0969da; --alert-note-text: #0550ae;
        --alert-tip: #1a7f37; --alert-tip-text: #116329;
        --alert-important: #8250df; --alert-important-text: #6639ba;
        --alert-warning: #9a6700; --alert-warning-text: #7d4e00;
        --alert-caution: #cf222e; --alert-caution-text: #a40e26;
        --tok-k: #4a4f9e; --tok-s: #33754a; --tok-n: #a35016; --tok-y: #87479c; --tok-c: #556652;
        background: var(--page);
      }
      :root[data-theme="dark"] {
        color-scheme: dark;
        --page: #1b1b1b; --text: #dddde3; --secondary: #acacb8;
        --border: #38383f; --code: #25252c; --accent: #a1a6f2; --quote: #222228;
        --mark: #5a4a10; --kbd-edge: #4a4a54;
        --alert-note: #4493f8; --alert-note-text: #79b8ff;
        --alert-tip: #3fb950; --alert-tip-text: #56d364;
        --alert-important: #ab7df8; --alert-important-text: #c9a8ff;
        --alert-warning: #d29922; --alert-warning-text: #e3b341;
        --alert-caution: #f85149; --alert-caution-text: #ff8a85;
        --tok-k: #9eabfa; --tok-s: #7ac28c; --tok-n: #f09e57; --tok-y: #cc96e0; --tok-c: #99a89e;
      }
      * { box-sizing: border-box; }
      html { overflow-wrap: anywhere; }
      body {
        margin: 0; padding: 24px clamp(20px, 4vw, 28px) 64px;
        background: var(--page); color: var(--text);
        font: 15px/1.7 -apple-system, BlinkMacSystemFont, system-ui, "PingFang SC", "Hiragino Sans", "Apple SD Gothic Neo", sans-serif;
        -webkit-font-smoothing: antialiased;
      }
      article { max-width: var(--lac-content-width, 760px); min-width: 0; margin: 0 auto; }
      article > :first-child { margin-top: 0; }
      article > :last-child { margin-bottom: 0; }
      h1, h2, h3, h4, h5, h6 { line-height: 1.4; margin: 1.6em 0 .6em; font-weight: 650; letter-spacing: -.015em; }
      h1 { font-size: 1.85em; }
      h2 { font-size: 1.4em; }
      h3 { font-size: 1.15em; }
      h4, h5, h6 { font-size: 1em; }
      h5, h6 { color: var(--secondary); }
      p { margin: 0 0 .9em; }
      ul, ol { margin: .7em 0 1em; padding-left: 1.7em; }
      ul { list-style-type: disc; }
      ul ul { list-style-type: circle; }
      ul ul ul { list-style-type: square; }
      ol, ol ol, ol ol ol { list-style-type: decimal; }
      li { margin: .2em 0; padding-left: .15em; }
      li::marker { color: var(--secondary); font-variant-numeric: tabular-nums; }
      li > ul, li > ol { margin: .3em 0 .4em; }
      li > p { margin: .45em 0; }
      blockquote {
        margin: 1.15em 0; padding: .65em 1em; color: var(--text);
        border-left: 3px solid var(--lac-accent, var(--accent)); background: var(--quote);
        border-radius: 0 5px 5px 0;
      }
      blockquote > :first-child { margin-top: 0; }
      blockquote > :last-child { margin-bottom: 0; }
      blockquote blockquote { margin: .6em 0; }
      aside.lac-alert { margin: 1.15em 0; }
      aside.lac-alert > blockquote { margin: 0; border-left-color: var(--alert); background: color-mix(in srgb, var(--alert) 8%, var(--quote)); }
      aside.lac-alert > blockquote > p:first-child > strong:first-child { display: block; margin-bottom: .15em; color: var(--alert-text); text-transform: lowercase; }
      aside.lac-alert > blockquote > p:first-child > strong:first-child::first-letter { text-transform: uppercase; }
      .lac-alert-note { --alert: var(--alert-note); --alert-text: var(--alert-note-text); }
      .lac-alert-tip { --alert: var(--alert-tip); --alert-text: var(--alert-tip-text); }
      .lac-alert-important { --alert: var(--alert-important); --alert-text: var(--alert-important-text); }
      .lac-alert-warning { --alert: var(--alert-warning); --alert-text: var(--alert-warning-text); }
      .lac-alert-caution { --alert: var(--alert-caution); --alert-text: var(--alert-caution-text); }
      hr { border: 0; border-top: 1px solid var(--border); margin: 1.8em 0; }
      a { color: var(--accent); text-decoration-line: underline; text-decoration-thickness: 1px; text-underline-offset: 3px; text-decoration-color: color-mix(in srgb, var(--accent) 45%, transparent); }
      a:hover, a:focus-visible { text-decoration-color: currentColor; text-decoration-thickness: 2px; }
      :focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 2px; }
      code, kbd { font: .88em/1.65 ui-monospace, SFMono-Regular, Menlo, monospace; font-family: var(--lac-code-font, ui-monospace, SFMono-Regular, Menlo, monospace); background: var(--code); padding: .15em .35em; border-radius: 4px; }
      pre {
        max-width: 100%; overflow: auto; overscroll-behavior-x: contain;
        margin: 1.1em 0; background: var(--code); border: 1px solid var(--border);
        padding: 14px 16px; border-radius: 7px; tab-size: 4;
      }
      pre code { background: none; padding: 0; border-radius: 0; overflow-wrap: normal; white-space: pre; }
      .tok-k { color: var(--tok-k); } .tok-s { color: var(--tok-s); } .tok-n { color: var(--tok-n); }
      .tok-y { color: var(--tok-y); } .tok-c { color: var(--tok-c); }
      pre[hidden] { display: none; }
      .mermaid-diagram { max-width: 100%; overflow-x: auto; margin: 1.1em 0; }
      .mermaid-diagram svg { max-width: 100%; height: auto; }
      .table-scroll { max-width: 100%; overflow-x: auto; overscroll-behavior-x: contain; margin: 1.1em 0; }
      table { width: 100%; border-collapse: collapse; font-size: .93em; }
      th, td { border: 1px solid var(--border); padding: .55em .8em; text-align: left; min-width: 5em; }
      th { font-weight: 600; background: var(--code); }
      td { font-variant-numeric: tabular-nums; }
      tbody tr:nth-child(even) { background: var(--quote); }
      img { max-width: 100%; height: auto; }
      [data-lac-centered-image] { display: block; text-align: center; }
      input[type="checkbox"] { margin: 0 .45em 0 0; accent-color: var(--lac-accent, var(--accent)); vertical-align: middle; }
      del { color: var(--secondary); }
      mark { background: var(--mark); color: var(--text); padding: .05em .2em; border-radius: 3px; }
      kbd { border: 1px solid var(--border); border-bottom: 2px solid var(--kbd-edge); border-radius: 5px; padding: .1em .45em; }
      li:has(> input[type="checkbox"]) { list-style: none; }
      li > input[type="checkbox"]:first-child { margin-left: -1.55em; }
      sup.footnote-ref { font-size: .75em; line-height: 0; margin-left: .1em; }
      sup.footnote-ref a, a.footnote-backref { text-decoration: none; padding: 0 .15em; }
      a.footnote-backref { margin-left: .3em; }
      section[data-footnotes] { margin-top: 2.2em; padding-top: .5em; border-top: 1px solid var(--border); font-size: .9em; }
      section[data-footnotes] > ol { margin: .5em 0; }
      section[data-footnotes] li:target { background: var(--quote); border-radius: 4px; }
      .lac-empty { margin: 18vh 0 0; text-align: center; color: var(--secondary); }
      ::selection { background: color-mix(in srgb, var(--lac-accent, #9296db) 35%, transparent); }
      :root[data-theme="dark"] ::selection { background: color-mix(in srgb, var(--lac-accent, #a1a6f2) 44%, transparent); }
      @media (prefers-contrast: more) {
        :root { --secondary: #4a4a55; --border: #92929c; --accent: #3f4490; --mark: #ffe066; }
        :root[data-theme="dark"] { --secondary: #d2d2dc; --border: #878792; --accent: #c8cbff; }
        :root { --alert-note-text: #0a3069; --alert-tip-text: #0b4a1f; --alert-important-text: #4b2a99; --alert-warning-text: #5c3a00; --alert-caution-text: #7d0b1d; }
        :root[data-theme="dark"] { --alert-note-text: #a5d0ff; --alert-tip-text: #9be9a8; --alert-important-text: #ddc6ff; --alert-warning-text: #ffd866; --alert-caution-text: #ffb3ae; }
        :root { --tok-k: #3b3f86; --tok-s: #1f5c35; --tok-n: #8a4210; --tok-y: #6f2f84; --tok-c: #3f5a48; }
        :root[data-theme="dark"] { --tok-k: #c9cdff; --tok-s: #9be0ae; --tok-n: #ffb877; --tok-y: #e6b8f5; --tok-c: #c4d2c9; }
        a { text-decoration-color: currentColor; }
        sup.footnote-ref a, a.footnote-backref { text-decoration-line: underline; }
        mark { outline: 1px solid var(--text); }
      }
      @media print {
        :root, :root[data-theme="dark"] {
          color-scheme: light;
          --page: #fff; --text: #303038; --secondary: #6d6d78;
          --border: #e2e2e8; --code: #f0f0f4; --accent: #5c61ba; --quote: #f4f4f8;
          --mark: #fff1a8; --kbd-edge: #b4b4be;
          --alert-note: #0969da; --alert-note-text: #0550ae;
          --alert-tip: #1a7f37; --alert-tip-text: #116329;
          --alert-important: #8250df; --alert-important-text: #6639ba;
          --alert-warning: #9a6700; --alert-warning-text: #7d4e00;
          --alert-caution: #cf222e; --alert-caution-text: #a40e26;
          --tok-k: #4a4f9e; --tok-s: #33754a; --tok-n: #a35016; --tok-y: #87479c; --tok-c: #556652;
        }
        pre, table, img, blockquote, .mermaid-diagram, tr { break-inside: avoid; }
        h1, h2, h3, h4, h5, h6 { break-after: avoid; }
        body { padding: 0; }
        article { max-width: var(--lac-print-width, none); }
        pre, code, kbd, mark, th, tr, blockquote, aside.lac-alert blockquote {
          print-color-adjust: exact; -webkit-print-color-adjust: exact;
        }
        img, .mermaid-diagram svg { max-height: var(--lac-print-height, none); object-fit: contain; }
      }
    """
}

enum MarkdownRenderer {
    private final class RemoteImageMarkers {
        var values: [String: String] = [:]
    }
    private final class LocalMediaMarkers {
        var values: [String: MarkdownRenderedPage.LocalMediaResource] = [:]
        var prefix: String?
    }
    private final class RawHTMLBlocks {
        var prefix: String?
        var values: [(marker: String, html: String)] = []
        var failed = false
    }
    private final class ListDepths {
        var values: Set<Int> = []
    }

    static func render(_ markdown: String, darkMode: Bool) -> String {
        renderPage(markdown, darkMode: darkMode).html
    }

    static func renderPage(_ markdown: String, darkMode: Bool, includeHTMLMedia: Bool = false, renderEmoji: Bool = false,
                           resolveLocalImages: Bool = false, documentURL: URL? = nil, prepareRemoteImages: Bool = false,
                           syntax: MarkdownSyntaxOptions = .init(), forExport: Bool = false, includeHeadingNumbers: Bool = false, includeListStyles: Bool = false,
                           staticWidgetFallback: Bool = false, preserveRawHTMLBlocks: Bool = false,
                           includeSourcePositions: Bool = false, isPreview: Bool = false, highlightCode: Bool = false,
                           wiki: MarkdownWikiLinkContext? = nil) -> MarkdownRenderedPage {
        let markdown = substitutingWikiLinks(markdown, wiki: wiki, syntax: syntax)
        // Позиции исходника нужны только предпросмотру; в экспорт, PDF и копирование они не попадают.
        let sourcePositions = includeSourcePositions && !forExport
        let remoteImageMarkers = RemoteImageMarkers()
        let localMediaMarkers = LocalMediaMarkers()
        let listDepths = ListDepths()
        let rawHTMLBlocks = RawHTMLBlocks()
        let rendered = renderBody(markdown, includeHTMLMedia: includeHTMLMedia, renderEmoji: renderEmoji,
                                  resolveLocalImages: resolveLocalImages, documentURL: documentURL, prepareRemoteImages: prepareRemoteImages,
                                  remoteImageMarkers: remoteImageMarkers, localMediaMarkers: localMediaMarkers, syntax: syntax, forExport: forExport, includeHeadingNumbers: includeHeadingNumbers,
                                  listDepths: listDepths, includeListStyles: includeListStyles, staticWidgetFallback: staticWidgetFallback,
                                  preserveRawHTMLBlocks: preserveRawHTMLBlocks, rawHTMLBlocks: rawHTMLBlocks, includeSourcePositions: sourcePositions,
                                  highlightCode: highlightCode)
        let tableWrapper = "<div class=\"table-scroll\" role=\"region\" aria-label=\"\(L10n.tr("表格，可横向滚动"))\" tabindex=\"0\">"
        let preAttributes = "tabindex=\"0\" aria-label=\"\(L10n.tr("代码块，可横向滚动"))\""
        var body = rendered.body
            .replacingOccurrences(of: "<table>", with: tableWrapper + "<table>")
            .replacingOccurrences(of: "<table data-sourcepos=\"", with: tableWrapper + "<table data-sourcepos=\"")
            .replacingOccurrences(of: "</table>", with: "</table></div>")
            .replacingOccurrences(of: "<pre>", with: "<pre \(preAttributes)>")
            .replacingOccurrences(of: "<pre data-sourcepos=\"", with: "<pre \(preAttributes) data-sourcepos=\"")
        // Подсказка нужна только предпросмотру пустого или состоящего из пробелов документа; экспорт и печать остаются пустыми.
        if isPreview, !forExport, markdown.allSatisfy(\.isWhitespace) {
            body = "<p class=\"lac-empty\">" + htmlEscaped(L10n.tr("预览为空。在编辑器中输入 Markdown 后，内容会显示在这里。")) + "</p>"
        }
        var page = MarkdownRenderedPage(body: body, darkMode: darkMode, headingIDs: rendered.headingIDs, formulas: rendered.formulas, diagrams: rendered.diagrams, omittedHTML: rendered.omittedHTML, preserveWhitespace: forExport ? syntax.preserveExportWhitespace : (syntax.preserveEditingWhitespace ?? false))
        page.remoteImageMarkers = remoteImageMarkers.values
        page.localMediaMarkers = localMediaMarkers.values
        page.listDepths = listDepths.values
        page.rawHTMLBlocks = rawHTMLBlocks.values
        page.rawHTMLBlockProofFailed = rawHTMLBlocks.failed
        return page
    }

    /// `[[…]]` → обычная ссылка либо простой текст (цель не найдена или неоднозначна); число строк не меняется.
    static func substitutingWikiLinks(_ markdown: String, wiki: MarkdownWikiLinkContext?, syntax: MarkdownSyntaxOptions) -> String {
        guard let wiki, markdown.contains("[[") else { return markdown }
        let links = MarkdownWikiLinkExtractor.links(in: markdown, syntax: syntax, isCancelled: { Task.isCancelled })
        return MarkdownWikiLinkRewriter.rewrite(markdown, links: links, context: wiki, isCancelled: { Task.isCancelled })
    }

    private static func htmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func tokenClassCode(_ kind: SyntaxHighlighter.TokenKind) -> UInt8 {
        switch kind {
        case .keyword, .markup, .selector, .heading: return 1
        case .string: return 2
        case .number: return 3
        case .literal, .function, .typeName, .attribute, .property, .variable, .strong, .emphasis: return 4
        case .comment: return 5
        case .punctuation: return 0
        }
    }

    private static func tokenClassName(_ code: UInt8) -> String {
        switch code {
        case 1: return "tok-k"
        case 2: return "tok-s"
        case 3: return "tok-n"
        case 4: return "tok-y"
        default: return "tok-c"
        }
    }

    // Ключ — язык и точный текст блока, поэтому результат другой версии или документа вернуться не может.
    // Стоимость — объём ключа и HTML в UTF-16: правки большого блока не копят записи до нехватки памяти.
    private static let highlightCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private static func highlightedCodeHTML(_ literal: String, language: EditorLanguage) -> String? {
        let key = "\(language)\u{0}\(literal)" as NSString
        if let cached = highlightCache.object(forKey: key) { return cached as String }
        let text = literal as NSString
        let tokens = SyntaxHighlighter.tokens(in: literal, language: language, documentID: nil, isCancelled: { Task.isCancelled })
        guard !Task.isCancelled else { return nil }
        // Токены вложенные: потомок идёт после родителя и перекрывает его, поэтому красим по UTF-16-позициям.
        var kinds = [UInt8](repeating: 0, count: text.length)
        for token in tokens {
            let code = tokenClassCode(token.kind)
            guard code != 0, token.range.location >= 0, NSMaxRange(token.range) <= text.length else { continue }
            for index in token.range.location..<NSMaxRange(token.range) { kinds[index] = code }
        }
        var html = "", start = 0
        while start < text.length {
            var end = start + 1
            while end < text.length, kinds[end] == kinds[start] { end += 1 }
            // Не рвём суррогатную пару границей span.
            if end < text.length, UTF16.isLeadSurrogate(text.character(at: end - 1)) { end += 1 }
            let piece = htmlEscaped(text.substring(with: NSRange(location: start, length: end - start)))
            html += kinds[start] == 0 ? piece : "<span class=\"\(tokenClassName(kinds[start]))\">\(piece)</span>"
            start = end
        }
        highlightCache.setObject(html as NSString, forKey: key, cost: key.length + html.utf16.count)
        return html
    }

    private static func renderBody(_ markdown: String, includeHTMLMedia: Bool, renderEmoji: Bool,
                                   resolveLocalImages: Bool, documentURL: URL?, prepareRemoteImages: Bool, remoteImageMarkers: RemoteImageMarkers, localMediaMarkers: LocalMediaMarkers, syntax: MarkdownSyntaxOptions,
                                   forExport: Bool, includeHeadingNumbers: Bool, listDepths: ListDepths, includeListStyles: Bool, staticWidgetFallback: Bool,
                                   preserveRawHTMLBlocks: Bool, rawHTMLBlocks: RawHTMLBlocks, includeSourcePositions: Bool, highlightCode: Bool) -> (body: String, headingIDs: Set<String>, formulas: [MarkdownRenderedMath], diagrams: [MarkdownRenderedDiagram], omittedHTML: Bool) {
        let hardBreaks = forExport ? (syntax.preserveExportSoftBreaks ?? true) : syntax.preserveEditingSoftBreaks
        let options = ((syntax.smartPunctuation ?? true) ? CMARK_OPT_SMART : 0) | CMARK_OPT_TABLE_SPANS | (hardBreaks ? CMARK_OPT_HARDBREAKS : CMARK_OPT_NOBREAKS) | CMARK_OPT_FOOTNOTES
        let preserveWhitespace = forExport ? syntax.preserveExportWhitespace : (syntax.preserveEditingWhitespace ?? false)
        let input = MarkdownPresentationParser.maskedFrontMatter(markdown, frontMatter: MarkdownPresentationParser.frontMatter(markdown))
        let includeHTMLImages = resolveLocalImages && !includeHTMLMedia
        let rawMarkdown = includeHTMLMedia ? markdown as NSString : nil
        var confirmedAudio = Set<NSRange>()
        var confirmedVideo = Set<NSRange>()
        var confirmedInline: [NSRange: String] = [:]
        var confirmedFrames: [NSRange: MarkdownHTMLMediaService.EmbeddedFrame] = [:]
        var confirmedBlocks = Set<NSRange>()
        func markRemote(_ address: String) -> String? {
            guard prepareRemoteImages, let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            var marker: String
            repeat { marker = "LACREMOTE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
            while markdown.contains(marker) || remoteImageMarkers.values[marker] != nil
            remoteImageMarkers.values[marker] = address
            return marker
        }
        return MarkdownMathExtension.withDocument(input, options: options, includeInline: syntax.inlineMath, legacyInlineMath: syntax.legacyInlineMath,
                                                  strictMode: syntax.strictMode, sourceForPositions: markdown, isCancelled: { Task.isCancelled }) { document, extensionNode, inline, parser in
            let mappedSource = MarkdownPresentationParser.Source(markdown, root: document, textOrigins: MarkdownMathExtension.textOrigins(in: extensionNode),
                looseHeadings: MarkdownMathExtension.looseHeadings(in: extensionNode), looseListRanges: MarkdownMathExtension.looseListRanges(in: extensionNode),
                isCancelled: { Task.isCancelled })
            var detachedFrameNodes: [OpaquePointer] = []
            defer { for node in detachedFrameNodes { cmark_node_free(node) } }
            var htmlImageNodes: [(OpaquePointer, MarkdownImageUploadService.Image)] = []
            var mediaCollector = MarkdownPresentationParser.PairedMediaCollector()
            var standaloneMediaCandidates: [(node: OpaquePointer, range: NSRange, media: MarkdownHTMLMediaService.StandaloneMedia)] = []
            var mediaTemplateDepth = 0
            var pageBreakCandidates: [(node: OpaquePointer, range: NSRange, offset: Int, style: String)] = []
            var detailsCandidates: [(node: OpaquePointer, range: NSRange, offset: Int, summary: String, body: String)] = []
            var richDetailsCandidates: [(range: NSRange, proof: MarkdownHTMLMediaService.HTMLBlockCandidate)] = []
            var svgBlockCandidates: [MarkdownPresentationParser.StandaloneSVG] = []
            var twitterCandidates: [(range: NSRange, proof: MarkdownHTMLMediaService.TwitterProofCandidate)] = []
            let confirmedImages = (includeHTMLMedia || includeHTMLImages || markdown.range(of: "<details", options: .caseInsensitive) != nil) ? (try? MarkdownImageUploadService.images(in: markdown, allowSharedReference: true, isCancelled: { Task.isCancelled },
                htmlForExport: true, confirmedAudio: { _ = confirmedAudio.insert($0) },
                confirmedVideo: { _ = confirmedVideo.insert($0) }, confirmedInline: { confirmedInline[$0] = $1 },
                confirmedFrame: { confirmedFrames[$0] = $1 }, confirmedBlock: { _ = confirmedBlocks.insert($0) },
                confirmedImage: { htmlImageNodes.append(($0, $1)) },
                confirmedHTMLTags: { node, range, tags in
                    let outsideTemplate = mediaTemplateDepth == 0
                    var eligible: [(NSRange, String, Bool)] = []
                    for (tag, name, closing) in tags {
                        if Task.isCancelled { return }
                        if name == "template" {
                            mediaCollector.cancelPending()
                            mediaTemplateDepth = closing ? max(0, mediaTemplateDepth - 1) : mediaTemplateDepth + 1
                        } else if mediaTemplateDepth == 0 && ["audio", "video", "iframe"].contains(name) {
                            eligible.append((tag, name, closing))
                        }
                    }
                    if outsideTemplate && mediaTemplateDepth == 0, cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK,
                       let pointer = cmark_node_get_literal(node) {
                        let literal = String(cString: pointer) as NSString
                        if let widget = MarkdownHTMLMediaService.twitterWidget(literal as String, isCancelled: { Task.isCancelled }),
                           (MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }) ||
                            MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mappedSource, sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil),
                           MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil {
                            var start = 0, end = literal.length
                            while start < end && [9, 10, 12, 13, 32].contains(Int(literal.character(at: start))) { start += 1 }
                            while end > start && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { end -= 1 }
                            twitterCandidates.append((range, .init(node: node, start: start, end: end, widget: widget)))
                        }
                        if let media = MarkdownHTMLMediaService.standaloneMedia(literal as String, isCancelled: { Task.isCancelled }),
                           (MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }) ||
                            MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mappedSource, sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil),
                           MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil {
                            standaloneMediaCandidates.append((node, range, media))
                        }
                        if let candidate = MarkdownPresentationParser.standaloneSVGBlockCandidate(node, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }),
                           (MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }) ||
                            MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mappedSource, sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil) {
                            svgBlockCandidates.append(candidate)
                        }
                        if let details = MarkdownHTMLMediaService.plainDetails(literal as String, isCancelled: { Task.isCancelled }),
                           (MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }) ||
                            MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mappedSource, sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil),
                           MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil {
                            var offset = 0
                            while offset < literal.length && [9, 10, 12, 13, 32].contains(Int(literal.character(at: offset))) { offset += 1 }
                            detailsCandidates.append((node, range, offset, details.summary, details.body))
                        }
                        if MarkdownHTMLMediaService.richDetails(literal as String, isCancelled: { Task.isCancelled }) != nil,
                           (MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }) ||
                            MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mappedSource, sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil),
                           MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil {
                            var start = 0, end = literal.length
                            while start < end && [9, 10, 12, 13, 32].contains(Int(literal.character(at: start))) { start += 1 }
                            while end > start && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { end -= 1 }
                            richDetailsCandidates.append((range, .init(node: node, start: start, end: end, html: literal as String)))
                        }
                        if let style = MarkdownHTMLMediaService.pageBreakStyle(literal as String, isCancelled: { Task.isCancelled }),
                           (MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }) ||
                            MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mappedSource, sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil),
                           MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil {
                            var offset = 0
                            while offset < literal.length && [9, 10, 12, 13, 32].contains(Int(literal.character(at: offset))) { offset += 1 }
                            pageBreakCandidates.append((node, range, offset, style))
                        }
                    }
                    guard includeHTMLImages || (preserveRawHTMLBlocks && cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK) else { return }
                    var ancestor = cmark_node_parent(node)
                    while let current = ancestor {
                        if Task.isCancelled { return }
                        if let pointer = cmark_node_get_type_string(current), ["image", "table", "footnote_definition"].contains(String(cString: pointer)) { return }
                        ancestor = cmark_node_parent(current)
                    }
                    mediaCollector.consume(node: node, range: range, tags: eligible, sourceText: markdown as NSString, isCancelled: { Task.isCancelled })
                },
                root: document, sourceMapping: mappedSource)) ?? [] : []
            let pageBreaks = MarkdownHTMLMediaService.provenPageBreaks(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: pageBreakCandidates.filter { confirmedBlocks.contains($0.range) }.map { ($0.node, $0.offset, $0.style) },
                isCancelled: { Task.isCancelled })
            var details = MarkdownHTMLMediaService.provenDetails(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: detailsCandidates.filter { confirmedBlocks.contains($0.range) }.map { ($0.node, $0.offset, $0.summary, $0.body) },
                isCancelled: { Task.isCancelled })
            let richDetails = richDetailsCandidates.filter { confirmedBlocks.contains($0.range) }
            for index in MarkdownHTMLMediaService.provenHTMLBlocks(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: richDetails.map(\.proof), isCancelled: { Task.isCancelled }) {
                details.insert(richDetails[index].proof.node)
            }
            standaloneMediaCandidates = standaloneMediaCandidates.filter { confirmedBlocks.contains($0.range) }
            let acceptedStandaloneMedia = MarkdownHTMLMediaService.provenStandaloneMedia(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: standaloneMediaCandidates.map { ($0.node, $0.media) }, isCancelled: { Task.isCancelled })
            var standaloneMedia: [OpaquePointer: MarkdownHTMLMediaService.EmbeddedMedia] = [:]
            for index in acceptedStandaloneMedia {
                if Task.isCancelled { break }
                standaloneMedia[standaloneMediaCandidates[index].node] = standaloneMediaCandidates[index].media.media
            }
            svgBlockCandidates = svgBlockCandidates.filter { confirmedBlocks.contains($0.range) }
            let acceptedSVGBlocks = MarkdownHTMLMediaService.provenSVG(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: svgBlockCandidates.map(\.proof), isCancelled: { Task.isCancelled })
            var svgBlocks: [OpaquePointer: MarkdownPresentationParser.StandaloneSVG] = [:]
            for index in acceptedSVGBlocks { if Task.isCancelled { break }; svgBlocks[svgBlockCandidates[index].proof.opening] = svgBlockCandidates[index] }
            twitterCandidates = twitterCandidates.filter { confirmedBlocks.contains($0.range) }
            let acceptedTwitter = MarkdownHTMLMediaService.provenTwitter(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: twitterCandidates.map(\.proof), isCancelled: { Task.isCancelled })
            var twitterBlocks: [OpaquePointer: MarkdownHTMLMediaService.TwitterWidget] = [:]
            for index in acceptedTwitter { if Task.isCancelled { break }; twitterBlocks[twitterCandidates[index].proof.node] = twitterCandidates[index].proof.widget }
            let mediaCandidates = mediaCollector.candidates
            let acceptedMedia = MarkdownHTMLMediaService.provenMediaIndices(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: mediaCandidates.map(\.proof), isCancelled: { Task.isCancelled })
            let selectedMedia: [(proof: MarkdownHTMLMediaService.MediaProofCandidate, range: NSRange, isInline: Bool)] = acceptedMedia.map { mediaCandidates[$0] }
            let orderedMedia = selectedMedia.sorted { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length > rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }
            var provedMedia: [(proof: MarkdownHTMLMediaService.MediaProofCandidate, range: NSRange, isInline: Bool)] = []
            var mediaEnd = 0
            for candidate in orderedMedia {
                if Task.isCancelled { break }
                guard candidate.range.location >= mediaEnd else { continue }
                provedMedia.append(candidate)
                mediaEnd = NSMaxRange(candidate.range)
            }
            var mediaMarkerPrefix: String?
            var provedMediaBlocks: [OpaquePointer: [(Int, Int, String, MarkdownHTMLMediaService.ProvenMedia)]] = [:]
            var inlineMediaOpenings: [OpaquePointer: (MarkdownHTMLMediaService.EmbeddedMedia, OpaquePointer)] = [:]
            var inlineFrameOpenings: [OpaquePointer: (MarkdownHTMLMediaService.EmbeddedFrame, OpaquePointer)] = [:]
            for (index, candidate) in provedMedia.enumerated() {
                if Task.isCancelled { break }
                let proof = candidate.proof
                if proof.openingNode == proof.closingNode, cmark_node_get_type(proof.openingNode) == CMARK_NODE_HTML_BLOCK {
                    if mediaMarkerPrefix == nil {
                        var prefix: String
                        repeat { prefix = "LACBLOCKMEDIA" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
                        while markdown.contains(prefix) && !Task.isCancelled
                        mediaMarkerPrefix = prefix
                    }
                    guard let mediaMarkerPrefix, !Task.isCancelled else { break }
                    provedMediaBlocks[proof.openingNode, default: []].append((proof.openingOffset, proof.closingOffset,
                        mediaMarkerPrefix + String(index), proof.expected))
                } else if proof.openingNode != proof.closingNode, case .media(let media) = proof.expected {
                    inlineMediaOpenings[proof.openingNode] = (media, proof.closingNode)
                } else if proof.openingNode != proof.closingNode, case .frame(let frame) = proof.expected {
                    inlineFrameOpenings[proof.openingNode] = (frame, proof.closingNode)
                }
            }
            func insideMedia(_ range: NSRange) -> Bool {
                var low = 0, high = provedMedia.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(provedMedia[middle].range) <= range.location { low = middle + 1 } else { high = middle }
                }
                return low < provedMedia.count && provedMedia[low].range.location < NSMaxRange(range)
            }
            if !provedMedia.isEmpty {
                var visibleImageNodes: [(OpaquePointer, MarkdownImageUploadService.Image)] = []
                for image in htmlImageNodes {
                    if Task.isCancelled { break }
                    if !insideMedia(image.1.range) { visibleImageNodes.append(image) }
                }
                if !Task.isCancelled { htmlImageNodes = visibleImageNodes }
            }
            let htmlImages = Dictionary(confirmedImages.compactMap { image -> (NSRange, MarkdownImageUploadService.Image)? in
                if case .html = image.syntax { return (image.range, image) }
                return nil
            }, uniquingKeysWith: { first, _ in first })
            var imageProof: [MarkdownHTMLMediaService.ImageProofCandidate] = []
            var imageCandidates: [(node: OpaquePointer, image: MarkdownHTMLMediaService.DisplayImage, address: String, offset: Int)] = []
            var blockCandidateCounts: [OpaquePointer: Int] = [:]
            if includeHTMLImages {
                let text = markdown as NSString
                let groups = Dictionary(grouping: htmlImageNodes, by: { $0.0 })
                for (node, entries) in groups {
                    if Task.isCancelled { break }
                    let isBlock = cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK
                    let range = isBlock ? mappedSource.range(node) : entries.first?.1.range
                    guard let range else { continue }
                    let exact = MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: text, isCancelled: { Task.isCancelled })
                    if !exact {
                        guard isBlock, MarkdownPresentationParser.containerHTMLPrefixes(node, range: range, source: mappedSource, sourceText: text, isCancelled: { Task.isCancelled }) != nil else { continue }
                    }
                    let sorted = entries.map { $0.1 }.sorted { $0.range.location < $1.range.location }
                    let positions = sorted.flatMap { [$0.range, NSRange(location: NSMaxRange($0.range) - 1, length: 1)] }.sorted { $0.location < $1.location }
                    let offsets = isBlock ? MarkdownHTMLMediaService.htmlBlockTagOffsets(node, range: range, tags: positions, sourceText: text, isCancelled: { Task.isCancelled }) : nil
                    let literal = cmark_node_get_literal(node).map { String(cString: $0) as NSString }
                    if isBlock { guard offsets != nil else { continue }; blockCandidateCounts[node] = sorted.count }
                    for image in sorted {
                        if Task.isCancelled { break }
                        guard image.range.location >= range.location, NSMaxRange(image.range) <= NSMaxRange(range) else { continue }
                        let offset = isBlock ? offsets?[image.range.location] : 0
                        guard let offset else { continue }
                        let tag: String
                        if isBlock {
                            guard let literal, let end = offsets?[NSMaxRange(image.range) - 1], end >= offset, end < literal.length else { continue }
                            tag = literal.substring(with: NSRange(location: offset, length: end - offset + 1))
                        } else { tag = text.substring(with: image.range) }
                        let tagText = tag as NSString
                        guard let checked = MarkdownImageUploadService.confirmedHTMLImage(in: tagText, range: NSRange(location: 0, length: tagText.length), isCancelled: { Task.isCancelled }),
                              let display = MarkdownHTMLMediaService.displayImage(in: tag) else { continue }
                        imageProof.append(.init(node: node, offset: offset, source: display.source))
                        imageCandidates.append((node, display, checked.address, offset))
                    }
                }
            }
            let accepted = MarkdownHTMLMediaService.provenImageIndices(root: document, mathExtension: extensionNode, options: options,
                text: markdown as NSString, candidates: imageProof, isCancelled: { Task.isCancelled })
            let provedHTMLImages = Dictionary(accepted.keys.compactMap { index -> (OpaquePointer, (MarkdownHTMLMediaService.DisplayImage, String))? in
                let candidate = imageCandidates[index]
                return blockCandidateCounts[candidate.node] == nil ? (candidate.node, (candidate.image, candidate.address)) : nil
            }, uniquingKeysWith: { first, _ in first })
            var provedHTMLBlocks: [OpaquePointer: [(Int, String, MarkdownHTMLMediaService.ExportImageMarker)]] = [:]
            for (index, marker) in accepted {
                let candidate = imageCandidates[index]
                guard blockCandidateCounts[candidate.node] != nil else { continue }
                provedHTMLBlocks[candidate.node, default: []].append((candidate.offset, marker, .init(source: candidate.image.source, address: candidate.address)))
            }
            provedHTMLBlocks = provedHTMLBlocks.filter { $0.value.count == blockCandidateCounts[$0.key] }
            let unprovedHTMLImageBlocks = includeHTMLImages ? Set(htmlImageNodes.compactMap {
                cmark_node_get_type($0.0) == CMARK_NODE_HTML_BLOCK ? $0.0 : nil
            }).subtracting(provedHTMLBlocks.keys) : []
            if includeListStyles { listDepths.values = installListStyleMarkers(in: document, source: mappedSource) }
            let source = includeHTMLMedia ? mappedSource : nil
            let inlineByNode = Dictionary(uniqueKeysWithValues: inline.map { ($0.node, $0) })
            var emojiLocations: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]] = [:]
            var emojiCandidates: [MarkdownEmojiCandidateExtractor.Candidate] = []
            var emojiValues: [String: String] = [:]
            if renderEmoji && !Task.isCancelled {
                let emojiSource = mappedSource
                emojiCandidates = MarkdownEmojiCandidateExtractor.candidates(in: document, source: emojiSource, text: markdown as NSString,
                    isCancelled: { Task.isCancelled }, onCandidate: { node, offset, candidate in
                        emojiLocations[node, default: []].append((offset, candidate))
                    }).sorted { $0.range.location < $1.range.location }
                emojiValues = (try? EmojiShortcodeResolver.resolve(emojiCandidates.map(\.name), isCancelled: { Task.isCancelled })) ?? [:]
                if Task.isCancelled { emojiLocations.removeAll(); emojiCandidates.removeAll(); emojiValues.removeAll() }
            }
            var resourcePaths: Result<MarkdownResourcePaths, Error>?
            var resourcePathsLoaded = false
            func resolvedMedia(_ address: String) -> String {
                if Task.isCancelled { return "data:," }
                if let url = URL(string: address), let scheme = url.scheme?.lowercased(),
                   ["http", "https"].contains(scheme), url.host != nil { return url.absoluteString }
                if MarkdownResourcePaths.requiresRoot(address) && !resourcePathsLoaded {
                    resourcePaths = Result { try MarkdownResourcePaths(text: markdown, document: documentURL) }
                    resourcePathsLoaded = true
                }
                let paths = resourcePaths.flatMap { try? $0.get() }
                guard !(MarkdownResourcePaths.requiresRoot(address) && resourcePathsLoaded && paths == nil),
                      let url = try? MarkdownImageUploadService.localURL(address: address, document: documentURL, paths: paths) else { return "data:," }
                if localMediaMarkers.prefix == nil {
                    var prefix: String
                    repeat {
                        if Task.isCancelled { return "data:," }
                        prefix = "LACLOCALMEDIA" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    } while markdown.contains(prefix)
                    localMediaMarkers.prefix = prefix
                }
                guard let prefix = localMediaMarkers.prefix else { return "data:," }
                let marker = prefix + "X" + String(localMediaMarkers.values.count)
                localMediaMarkers.values[marker] = .init(url: url, fragment: MarkdownImageUploadService.fragmentSuffix(address))
                return marker
            }
            let (headingIDs, omittedNamedHTML, blockedStyles) = installTableOfContents(in: document, markdown: markdown, source: mappedSource, mathExtension: extensionNode, options: options, mathInline: inlineByNode,
                emojiLocations: emojiLocations, emojiCandidates: emojiCandidates, emojiValues: emojiValues,
                resolveLocalImages: resolveLocalImages, documentURL: documentURL, includeHeadingNumbers: includeHeadingNumbers,
                imageMarkersByNode: &provedHTMLBlocks, mediaMarkersByNode: &provedMediaBlocks,
                unprovedImageBlocks: unprovedHTMLImageBlocks, confirmedInline: &confirmedInline, detachedNodes: &detachedFrameNodes, markRemote: markRemote, resolveMedia: resolvedMedia,
                preserveRawHTML: preserveRawHTMLBlocks)
            var formulas: [MarkdownRenderedMath] = []
            var diagrams: [MarkdownRenderedDiagram] = []
            var omittedHTML = includeHTMLMedia && omittedNamedHTML
            var imageDataURIs: [Data: String] = [:]
            var failedImageAddresses: Set<Data> = []
            var diagramSource = source
            func diagramRange(_ node: OpaquePointer) -> NSRange? {
                if diagramSource == nil { diagramSource = mappedSource }
                guard let diagramSource, let range = diagramSource.range(node), diagramSource.fenceMarkers(range).count == 2 else { return nil }
                return range
            }
            var tablePositions: [OpaquePointer: MarkdownPresentationParser.Source.TableCellPositions] = [:]
            var invalidTablePositions: Set<OpaquePointer> = []
            func intersectsBlockedStyle(_ range: NSRange) -> Bool {
                var low = 0, high = blockedStyles.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(blockedStyles[middle]) <= range.location { low = middle + 1 } else { high = middle }
                }
                return low < blockedStyles.count && blockedStyles[low].location < NSMaxRange(range)
            }
            let blockedMediaNodes = Set(provedMedia.filter { intersectsBlockedStyle($0.range) }.map { $0.proof.openingNode })
            var unsafeResourceFailure = false
            func resourceRange(_ node: OpaquePointer) -> NSRange? {
                var ancestor = cmark_node_parent(node)
                while let current = ancestor {
                    if Task.isCancelled { return nil }
                    if cmark_node_get_type_string(current).map({ String(cString: $0) }) == "table_cell" {
                        if tablePositions[current] == nil && !invalidTablePositions.contains(current) {
                            if let positions = mappedSource.tableCellPositions(current, isCancelled: { Task.isCancelled }) { tablePositions[current] = positions }
                            else { invalidTablePositions.insert(current) }
                        }
                        return tablePositions[current].flatMap { mappedSource.tableInlineRange(node, positions: $0) }
                    }
                    ancestor = cmark_node_parent(current)
                }
                return mappedSource.editingTextRange(node)
            }
            func escape(_ value: String) -> String {
                value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            }
            func mediaOpeningHTML(_ media: MarkdownHTMLMediaService.EmbeddedMedia) -> String? {
                let tag = media.kind == .audio ? "audio" : "video"
                var html = "<\(tag)" + (media.controls ? " controls" : "")
                var style = ""
                for (name, value) in [("width", media.width), ("height", media.height)] {
                    if let value { style += "\(name):\(value.hasSuffix("%") || value.hasSuffix("px") ? value : value + "px");" }
                }
                if !style.isEmpty { html += " style=\"\(escape(style))\"" }
                html += ">"
                for address in media.sources {
                    if Task.isCancelled { return nil }
                    html += "<source src=\"\(escape(resolvedMedia(address)))\">"
                }
                return html
            }
            func resolvedImage(_ address: String) -> String {
                guard resolveLocalImages else { return address }
                if let marker = markRemote(address) { return marker }
                let scheme = URL(string: address)?.scheme?.lowercased()
                guard !address.hasPrefix("//"), scheme == nil || scheme == "file" else { return address }
                if MarkdownResourcePaths.requiresRoot(address) && !resourcePathsLoaded {
                    resourcePaths = Result { try MarkdownResourcePaths(text: markdown, document: documentURL) }
                    resourcePathsLoaded = true
                }
                let key = Data(address.utf8)
                if imageDataURIs[key] == nil && !failedImageAddresses.contains(key) {
                    let paths = resourcePaths.flatMap { try? $0.get() }
                    if MarkdownResourcePaths.requiresRoot(address) && resourcePathsLoaded && paths == nil {
                        failedImageAddresses.insert(key)
                    } else if let payload = try? MarkdownImageUploadService.payload(address: address, document: documentURL, paths: paths) {
                        imageDataURIs[key] = MarkdownImageUploadService.dataURI(payload, address: address)
                    } else { failedImageAddresses.insert(key) }
                }
                return imageDataURIs[key] ?? address
            }
            func imageHTML(_ image: MarkdownHTMLMediaService.Image) -> String {
                var html = "<img src=\"\(escape(image.source))\""
                if let alt = image.alt { html += " alt=\"\(escape(alt))\"" }
                if let title = image.title { html += " title=\"\(escape(title))\"" }
                if let width = image.width { html += " width=\"\(escape(width))\"" }
                if let height = image.height { html += " height=\"\(escape(height))\"" }
                return html + ">"
            }
            func visit(_ node: OpaquePointer) {
                if Task.isCancelled { return }
                var child = cmark_node_first_child(node)
                while let current = child {
                    if Task.isCancelled { return }
                    let next = cmark_node_next(current)
                    let type = cmark_node_get_type(current)
                    if preserveRawHTMLBlocks, type == CMARK_NODE_HTML_INLINE,
                       inlineMediaOpenings[current] == nil, inlineFrameOpenings[current] == nil {
                        guard let range = resourceRange(current),
                              MarkdownPresentationParser.htmlSourceMatches(current, range: range, text: markdown as NSString, isCancelled: { Task.isCancelled }),
                              let replacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else {
                            rawHTMLBlocks.failed = true; return
                        }
                        let original = (markdown as NSString).substring(with: range)
                        let tagText = original as NSString
                        var tagContext = MarkdownImageUploadService.HTMLContext(), rawTag: (name: String, closing: Bool)?
                        _ = tagContext.consume(source: tagText, range: NSRange(location: 0, length: tagText.length), isCancelled: { Task.isCancelled }, confirmedTag: { tag, name, closing in
                            if tag.location == 0 && ["script", "style", "textarea"].contains(name) { rawTag = (name, closing) }
                        })
                        if let rawTag, !rawTag.closing {
                            let name = rawTag.name
                            let rawSource = markdown as NSString
                            var context = MarkdownImageUploadService.HTMLContext(), nodes: [OpaquePointer] = []
                            var sibling: OpaquePointer? = current, end = range.location, opened = false, closed = false
                            while let node = sibling {
                                if Task.isCancelled { break }
                                let part: NSRange?
                                if cmark_node_get_type(node) == CMARK_NODE_SOFTBREAK, let next = cmark_node_next(node),
                                   let nextRange = resourceRange(next), nextRange.location >= end {
                                    let gap = NSRange(location: end, length: nextRange.location - end)
                                    let value = rawSource.substring(with: gap)
                                    part = ["\n", "\r", "\r\n"].contains(value) ? gap : nil
                                } else { part = resourceRange(node) }
                                guard let part, part.location == end, part.length > 0,
                                      part.location <= rawSource.length, part.length <= rawSource.length - part.location else { break }
                                if cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE &&
                                    !MarkdownPresentationParser.htmlSourceMatches(node, range: part, text: rawSource, isCancelled: { Task.isCancelled }) { break }
                                var closing: NSRange?
                                _ = context.consume(source: rawSource, range: part, isCancelled: { Task.isCancelled }, confirmedTag: { tag, tagName, isClosing in
                                    if !isClosing && tagName == name && tag.location == range.location { opened = true }
                                }, confirmedRawClose: { tag, tagName in
                                    if tagName == name { closing = tag }
                                })
                                nodes.append(node); end = NSMaxRange(part)
                                if let closing {
                                    closed = opened && NSMaxRange(closing) == end
                                    break
                                }
                                sibling = cmark_node_next(node)
                            }
                            guard !Task.isCancelled, opened, closed, let last = nodes.last else {
                                cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                            }
                            if rawHTMLBlocks.prefix == nil {
                                var prefix: String
                                repeat { prefix = "LACRAW" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while markdown.contains(prefix)
                                rawHTMLBlocks.prefix = prefix
                            }
                            let marker = "<!--" + rawHTMLBlocks.prefix! + "X" + String(rawHTMLBlocks.values.count) + "-->"
                            guard marker.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                                  cmark_node_insert_before(current, replacement) != 0 else {
                                cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                            }
                            let after = cmark_node_next(last)
                            rawHTMLBlocks.values.append((marker, rawSource.substring(with: NSRange(location: range.location, length: end - range.location))))
                            for item in nodes {
                                if Task.isCancelled { rawHTMLBlocks.failed = true; return }
                                cmark_node_unlink(item); detachedFrameNodes.append(item)
                            }
                            child = after
                            continue
                        }
                        if rawTag?.closing == true {
                            cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                        }
                        if rawHTMLBlocks.prefix == nil {
                            var prefix: String
                            repeat { prefix = "LACRAW" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while markdown.contains(prefix)
                            rawHTMLBlocks.prefix = prefix
                        }
                        let marker = "<!--" + rawHTMLBlocks.prefix! + "X" + String(rawHTMLBlocks.values.count) + "-->"
                        let configured = marker.withCString { cmark_node_set_on_enter(replacement, $0) }
                        guard configured != 0, cmark_node_insert_before(current, replacement) != 0 else {
                            cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                        }
                        rawHTMLBlocks.values.append((marker, original))
                        cmark_node_unlink(current); detachedFrameNodes.append(current)
                        child = next
                        continue
                    }
                    let canonicalBlock: Bool
                    if preserveRawHTMLBlocks && type == CMARK_NODE_HTML_BLOCK {
                        let range = mappedSource.range(current)
                        canonicalBlock = svgBlocks[current] != nil || twitterBlocks[current] != nil || standaloneMedia[current] != nil ||
                            range.map { confirmedAudio.contains($0) || confirmedVideo.contains($0) || confirmedFrames[$0] != nil } == true
                    } else { canonicalBlock = false }
                    if preserveRawHTMLBlocks, type == CMARK_NODE_HTML_BLOCK, !canonicalBlock {
                        guard let range = mappedSource.range(current),
                              MarkdownHTMLMediaService.htmlBlockTagOffsets(current, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil,
                              let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else {
                            rawHTMLBlocks.failed = true; return
                        }
                        if rawHTMLBlocks.prefix == nil {
                            var prefix: String
                            repeat { prefix = "LACRAW" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while markdown.contains(prefix)
                            rawHTMLBlocks.prefix = prefix
                        }
                        let original = NSMutableString(string: (markdown as NSString).substring(with: range))
                        if cmark_node_parent(current).map({ cmark_node_get_type($0) }) != CMARK_NODE_DOCUMENT {
                            guard let prefixes = MarkdownPresentationParser.containerHTMLPrefixes(current, range: range,
                                source: mappedSource, sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) else {
                                cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                            }
                            for prefix in prefixes.reversed() {
                                guard prefix.location >= range.location, NSMaxRange(prefix) <= NSMaxRange(range) else {
                                    cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                                }
                                original.deleteCharacters(in: NSRange(location: prefix.location - range.location, length: prefix.length))
                            }
                        }
                        let mediaEntries = provedMediaBlocks[current] ?? []
                        if !mediaEntries.isEmpty {
                            guard let pointer = cmark_node_get_literal(current) else { cmark_node_free(replacement); rawHTMLBlocks.failed = true; return }
                            let literal = String(cString: pointer) as NSString
                            let endpoints = mediaEntries.flatMap { [$0.0, $0.1] }.sorted()
                            var mapped: [Int: Int] = [:], sourceOffset = 0, literalOffset = 0, endpoint = 0
                            while literalOffset < literal.length && sourceOffset < original.length {
                                if Task.isCancelled { cmark_node_free(replacement); rawHTMLBlocks.failed = true; return }
                                while endpoint < endpoints.count && endpoints[endpoint] == literalOffset {
                                    mapped[endpoints[endpoint]] = sourceOffset; endpoint += 1
                                }
                                let expected = literal.character(at: literalOffset), actual = original.character(at: sourceOffset)
                                if expected == 10 && actual == 13 {
                                    sourceOffset += 1
                                    if sourceOffset < original.length && original.character(at: sourceOffset) == 10 { sourceOffset += 1 }
                                } else if expected == actual { sourceOffset += 1 }
                                else { cmark_node_free(replacement); rawHTMLBlocks.failed = true; return }
                                literalOffset += 1
                            }
                            while endpoint < endpoints.count && endpoints[endpoint] == literalOffset {
                                mapped[endpoints[endpoint]] = sourceOffset; endpoint += 1
                            }
                            guard endpoint == endpoints.count, sourceOffset == original.length,
                                  literalOffset == literal.length || (literalOffset + 1 == literal.length && literal.character(at: literalOffset) == 10) else {
                                cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                            }
                            var lastEnd = 0, replacements: [(NSRange, String)] = []
                            for (open, close, _, expected) in mediaEntries.sorted(by: { $0.0 < $1.0 }) {
                                guard let start = mapped[open], let end = mapped[close], start >= lastEnd, end > start else {
                                    cmark_node_free(replacement); rawHTMLBlocks.failed = true; return
                                }
                                let html: String
                                switch expected {
                                case .media(let media):
                                    var addresses: [Data: String] = [:]
                                    let fragment = original.substring(with: NSRange(location: start, length: end - start))
                                    guard var rendered = MarkdownHTMLMediaService.copyMediaHTML(fragment, expected: expected, resolveMedia: { address in
                                        let key = Data(address.utf8)
                                        if let value = addresses[key] { return value }
                                        let value = resolvedMedia(address); addresses[key] = value; return value
                                    }, isCancelled: { Task.isCancelled }) else { cmark_node_free(replacement); rawHTMLBlocks.failed = true; return }
                                    if !media.controls {
                                        let tag = media.kind == .audio ? "audio" : "video"
                                        rendered.insert(contentsOf: " controls", at: rendered.index(rendered.startIndex, offsetBy: tag.count + 1))
                                    }
                                    html = rendered
                                case .frame(let frame): html = MarkdownHTMLMediaService.iframeHTML(frame)
                                }
                                replacements.append((NSRange(location: start, length: end - start), html)); lastEnd = end
                            }
                            for (range, html) in replacements.reversed() { original.replaceCharacters(in: range, with: html) }
                        }
                        let rawBlock = original as String
                        let marker = "<!--" + rawHTMLBlocks.prefix! + "X" + String(rawHTMLBlocks.values.count) + "-->"
                        let configured = marker.withCString { cmark_node_set_on_enter(replacement, $0) }
                        if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                            rawHTMLBlocks.values.append((marker, rawBlock))
                            cmark_node_unlink(current); detachedFrameNodes.append(current)
                            child = next
                            continue
                        }
                        cmark_node_free(replacement)
                        rawHTMLBlocks.failed = true
                        return
                    }
                    if !blockedStyles.isEmpty && (type == CMARK_NODE_IMAGE || type == CMARK_NODE_HTML_INLINE || type == CMARK_NODE_HTML_BLOCK) {
                        let range = resourceRange(current)
                        let blocked = range.map(intersectsBlockedStyle) ?? true
                        if type == CMARK_NODE_HTML_BLOCK && blocked {
                            guard let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { unsafeResourceFailure = true; return }
                            let literal: String
                            if let range, let pointer = cmark_node_get_literal(current),
                               MarkdownHTMLMediaService.htmlBlockTagOffsets(current, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil {
                                literal = "<pre>" + escape(String(cString: pointer)) + "</pre>"
                            } else { literal = "" }
                            guard literal.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                                  cmark_node_replace(current, replacement) != 0 else { cmark_node_free(replacement); unsafeResourceFailure = true; return }
                            detachedFrameNodes.append(current)
                            child = next
                            continue
                        }
                        if type == CMARK_NODE_IMAGE && blocked {
                            guard let replacement = cmark_node_new(CMARK_NODE_TEXT) else { unsafeResourceFailure = true; return }
                            let original = range.flatMap { NSMaxRange($0) <= (markdown as NSString).length ? (markdown as NSString).substring(with: $0) : nil } ?? ""
                            guard original.withCString({ cmark_node_set_literal(replacement, $0) }) != 0,
                                  cmark_node_replace(current, replacement) != 0 else { cmark_node_free(replacement); unsafeResourceFailure = true; return }
                            detachedFrameNodes.append(current)
                            child = next
                            continue
                        }
                        if type == CMARK_NODE_HTML_INLINE && (blocked || blockedMediaNodes.contains(current)) {
                            child = next
                            continue
                        }
                    }
                    if pageBreaks.contains(current), let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let html = "<div style=\"page-break-after:always;break-after:page\"></div>"
                        if html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                           cmark_node_replace(current, replacement) != 0 {
                            detachedFrameNodes.append(current)
                        } else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    if let svg = svgBlocks[current], let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let html = "<img src=\"data:image/svg+xml;base64," + svg.data.base64EncodedString() + "\" alt=\"\">"
                        if html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                           cmark_node_replace(current, replacement) != 0 { detachedFrameNodes.append(current) }
                        else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    if let widget = twitterBlocks[current], let frame = MarkdownHTMLMediaService.twitterFrame(widget),
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let html = staticWidgetFallback ? MarkdownHTMLMediaService.twitterFallbackHTML(widget) : MarkdownHTMLMediaService.iframeHTML(frame)
                        if html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                           cmark_node_replace(current, replacement) != 0 { detachedFrameNodes.append(current) }
                        else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    if let media = standaloneMedia[current], let start = mediaOpeningHTML(media),
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let html = start + (media.kind == .audio ? "</audio>" : "</video>")
                        if html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                           cmark_node_replace(current, replacement) != 0 { detachedFrameNodes.append(current) }
                        else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    if details.contains(current), let pointer = cmark_node_get_literal(current),
                       let rendered = MarkdownHTMLMediaService.exportBlock(String(cString: pointer), isCancelled: { Task.isCancelled }, imageOnly: true),
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        if rendered.html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                           cmark_node_replace(current, replacement) != 0 {
                            detachedFrameNodes.append(current)
                        } else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    if let (frame, closing) = inlineFrameOpenings[current] {
                        var cursor: OpaquePointer? = current
                        var nodes: [OpaquePointer] = []
                        while let item = cursor {
                            if Task.isCancelled { return }
                            nodes.append(item)
                            if item == closing { break }
                            cursor = cmark_node_next(item)
                        }
                        if nodes.last == closing, let replacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) {
                            let configured = MarkdownHTMLMediaService.iframeHTML(frame).withCString { cmark_node_set_on_enter(replacement, $0) }
                            if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                for item in nodes {
                                    if Task.isCancelled { return }
                                    cmark_node_unlink(item); detachedFrameNodes.append(item)
                                }
                                child = cmark_node_next(replacement).map(OpaquePointer.init)
                                continue
                            }
                            cmark_node_free(replacement)
                        }
                    }
                    if let (media, closing) = inlineMediaOpenings[current],
                       let openingReplacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) {
                        if let closingReplacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) {
                            let tag = media.kind == .audio ? "audio" : "video"
                            guard let html = mediaOpeningHTML(media) else { cmark_node_free(closingReplacement); cmark_node_free(openingReplacement); return }
                            let start = html.withCString { cmark_node_set_on_enter(openingReplacement, $0) }
                            let end = "</\(tag)>".withCString { cmark_node_set_on_enter(closingReplacement, $0) }
                            if start != 0, end != 0, cmark_node_insert_before(current, openingReplacement) != 0 {
                                if cmark_node_insert_before(closing, closingReplacement) != 0 {
                                    cmark_node_unlink(current); cmark_node_free(current)
                                    cmark_node_unlink(closing); cmark_node_free(closing)
                                    child = cmark_node_next(openingReplacement).map(OpaquePointer.init)
                                    continue
                                }
                                cmark_node_unlink(openingReplacement)
                            }
                            cmark_node_free(closingReplacement)
                        }
                        cmark_node_free(openingReplacement)
                    }
                    if includeHTMLImages, cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK,
                       let range = mappedSource.range(current), let literal = cmark_node_get_literal(current),
                       confirmedAudio.contains(range) || confirmedVideo.contains(range) || confirmedFrames[range] != nil {
                        let html: String?
                        if let frame = confirmedFrames[range] { html = MarkdownHTMLMediaService.iframeHTML(frame) }
                        else if let media = MarkdownHTMLMediaService.embeddedMedia(in: String(cString: literal)), let start = mediaOpeningHTML(media) {
                            html = start + (media.kind == .audio ? "</audio>" : "</video>")
                        } else { html = nil }
                        if let html, let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                            let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                            if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                cmark_node_unlink(current); cmark_node_free(current)
                            } else { cmark_node_free(replacement) }
                            child = next
                            continue
                        }
                    }
                    if includeHTMLImages, !unprovedHTMLImageBlocks.contains(current),
                       provedHTMLBlocks[current] != nil || provedMediaBlocks[current] != nil,
                       let pointer = cmark_node_get_literal(current) {
                        let entries = provedHTMLBlocks[current] ?? []
                        let mediaEntries = provedMediaBlocks[current] ?? []
                        var markers: [String: MarkdownHTMLMediaService.ExportImageMarker] = [:]
                        var mediaMarkers: [String: MarkdownHTMLMediaService.ProvenMedia] = [:]
                        var insertions: [(Int, String)] = []
                        for (_, close, marker, expected) in mediaEntries {
                            if Task.isCancelled { return }
                            insertions.append((close, "<!--\(marker)C-->"))
                            mediaMarkers[marker] = expected
                        }
                        for (offset, marker, expected) in entries {
                            if Task.isCancelled { return }
                            insertions.append((offset, "<!--\(marker)-->"))
                            markers[marker] = expected
                        }
                        for (open, _, marker, _) in mediaEntries { insertions.append((open, "<!--\(marker)O-->")) }
                        if let merged = mergeMarkerInsertions(insertions),
                           let block = MarkdownHTMLMediaService.insertingMarkers(in: String(cString: pointer), insertions: merged, isCancelled: { Task.isCancelled }),
                           let rendered = MarkdownHTMLMediaService.exportBlock(block, isCancelled: { Task.isCancelled }, imageMarkers: markers,
                               mediaMarkers: mediaMarkers, imageOnly: true, resolveMedia: resolvedMedia,
                               fallbackSource: mappedSource.range(current).flatMap { range in
                                   MarkdownHTMLMediaService.htmlBlockTagOffsets(current, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) == nil ? nil : String(cString: pointer)
                               }, resolveImage: { resolvedImage($0) }),
                           let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                            let configured = rendered.html.withCString { cmark_node_set_on_enter(replacement, $0) }
                            if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                cmark_node_unlink(current); cmark_node_free(current)
                            } else { cmark_node_free(replacement) }
                            child = next
                            continue
                        }
                    }
                    if includeHTMLImages, let (image, address) = provedHTMLImages[current],
                       let replacement = cmark_node_new(cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK ? CMARK_NODE_CUSTOM_BLOCK : CMARK_NODE_CUSTOM_INLINE) {
                        var html = "<img src=\"\(escape(resolvedImage(address)))\" alt=\"\(escape(image.alt))\""
                        if let title = image.title { html += " title=\"\(escape(title))\"" }
                        if !image.sizing.css.isEmpty { html += " style=\"\(escape(image.sizing.css))\"" }
                        html += ">"
                        let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                        if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                            cmark_node_unlink(current); cmark_node_free(current)
                        } else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    if includeHTMLImages, cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK,
                       !unprovedHTMLImageBlocks.contains(current), let range = mappedSource.range(current),
                       confirmedBlocks.contains(range), let pointer = cmark_node_get_literal(current) {
                        let literal = String(cString: pointer)
                        if MarkdownHTMLMediaService.hasStyledSpan(in: literal, isCancelled: { Task.isCancelled }),
                           MarkdownHTMLMediaService.htmlBlockTagOffsets(current, range: range, tags: [], sourceText: markdown as NSString, isCancelled: { Task.isCancelled }) != nil,
                           let rendered = MarkdownHTMLMediaService.exportBlock(literal, isCancelled: { Task.isCancelled }, imageOnly: true, fallbackSource: literal),
                           let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                            let configured = rendered.html.withCString { cmark_node_set_on_enter(replacement, $0) }
                            if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                cmark_node_unlink(current); cmark_node_free(current)
                            } else { cmark_node_free(replacement) }
                            child = next
                            continue
                        }
                    }
                    if resolveLocalImages, cmark_node_get_type(current) == CMARK_NODE_IMAGE,
                       let raw = cmark_node_get_url(current) {
                        if let parent = cmark_node_parent(current), cmark_node_get_type(parent) == CMARK_NODE_PARAGRAPH,
                           cmark_node_previous(current) == nil, cmark_node_next(current) == nil,
                           let open = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) {
                            if let close = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) {
                                let start = "<span data-lac-centered-image>".withCString { cmark_node_set_on_enter(open, $0) }
                                let end = "</span>".withCString { cmark_node_set_on_enter(close, $0) }
                                if start == 0 || end == 0 || cmark_node_insert_before(current, open) == 0 {
                                    cmark_node_free(open); cmark_node_free(close)
                                } else if cmark_node_insert_after(current, close) == 0 {
                                    cmark_node_unlink(open); cmark_node_free(open); cmark_node_free(close)
                                }
                            } else { cmark_node_free(open) }
                        }
                        let address = String(cString: raw)
                        let resolved = resolvedImage(address)
                        if resolved != address { _ = resolved.withCString { cmark_node_set_url(current, $0) } }
                    }
                    if includeHTMLMedia, let source, [CMARK_NODE_HTML_INLINE, CMARK_NODE_HTML_BLOCK].contains(cmark_node_get_type(current)) {
                        var ancestor = cmark_node_parent(current)
                        var tableCell: OpaquePointer?
                        while let candidate = ancestor {
                            if let name = cmark_node_get_type_string(candidate), String(cString: name) == "table_cell" {
                                tableCell = candidate; break
                            }
                            ancestor = cmark_node_parent(candidate)
                        }
                        let range: NSRange?
                        if let tableCell {
                            if tablePositions[tableCell] == nil && !invalidTablePositions.contains(tableCell) {
                                if let positions = source.tableCellPositions(tableCell) { tablePositions[tableCell] = positions }
                                else { invalidTablePositions.insert(tableCell) }
                            }
                            range = tablePositions[tableCell].flatMap { source.tableInlineRange(current, positions: $0) }
                        } else { range = source.range(current) }
                        if cmark_node_get_type(current) == CMARK_NODE_HTML_INLINE, let range,
                           let html = confirmedInline[range], let replacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) {
                            let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                            if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                cmark_node_unlink(current); cmark_node_free(current)
                            } else { cmark_node_free(replacement); omittedHTML = true }
                            child = next
                            continue
                        }
                        if cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK, let range, let raw = rawMarkdown,
                           confirmedBlocks.contains(range), !confirmedAudio.contains(range), !confirmedVideo.contains(range),
                           confirmedFrames[range] == nil,
                           let rendered = MarkdownHTMLMediaService.exportBlock(raw.substring(with: range), isCancelled: { Task.isCancelled },
                               fallbackSource: MarkdownHTMLMediaService.htmlBlockTagOffsets(current, range: range, tags: [], sourceText: raw, isCancelled: { Task.isCancelled }).flatMap { _ in
                                   cmark_node_get_literal(current).map { String(cString: $0) }
                               }),
                           let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                            let configured = rendered.html.withCString { cmark_node_set_on_enter(replacement, $0) }
                            if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                cmark_node_unlink(current); cmark_node_free(current)
                                omittedHTML = omittedHTML || rendered.omitted
                            } else { cmark_node_free(replacement); omittedHTML = true }
                            child = next
                            continue
                        }
                        if let range, let confirmed = htmlImages[range], let literal = cmark_node_get_literal(current),
                           let image = MarkdownHTMLMediaService.image(in: confirmed.htmlXML ?? String(cString: literal)), image.source == confirmed.address {
                            let html = imageHTML(image)
                            let kind = cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK ? CMARK_NODE_CUSTOM_BLOCK : CMARK_NODE_CUSTOM_INLINE
                            if let replacement = cmark_node_new(kind) {
                                let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                                if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                    cmark_node_unlink(current); cmark_node_free(current)
                                } else { cmark_node_free(replacement); omittedHTML = true }
                            } else { omittedHTML = true }
                            child = next
                            continue
                        }
                    }
                    if includeHTMLMedia, let source, cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK,
                       let range = source.range(current), confirmedAudio.contains(range), let literal = cmark_node_get_literal(current),
                       let source = MarkdownHTMLMediaService.audioSource(in: String(cString: literal), allowPaired: true),
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let html = "<audio controls src=\"\(escape(source))\"></audio>"
                        let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                        if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                            cmark_node_unlink(current)
                            cmark_node_free(current)
                        } else { cmark_node_free(replacement); omittedHTML = true }
                        child = next
                        continue
                    }
                    if includeHTMLMedia, let source, cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK,
                       let range = source.range(current), confirmedVideo.contains(range), let literal = cmark_node_get_literal(current),
                       let address = MarkdownHTMLMediaService.videoSource(in: String(cString: literal)),
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let html = "<video controls src=\"\(escape(address))\"></video>"
                        let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                        if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                            cmark_node_unlink(current); cmark_node_free(current)
                        } else { cmark_node_free(replacement); omittedHTML = true }
                        child = next
                        continue
                    }
                    if includeHTMLMedia, let source, cmark_node_get_type(current) == CMARK_NODE_HTML_BLOCK,
                       let range = source.range(current), let frame = confirmedFrames[range],
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let html = MarkdownHTMLMediaService.iframeHTML(frame)
                        let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                        if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                            cmark_node_unlink(current); cmark_node_free(current)
                        } else { cmark_node_free(replacement); omittedHTML = true }
                        child = next
                        continue
                    }
                    if includeHTMLMedia && [CMARK_NODE_HTML_INLINE, CMARK_NODE_HTML_BLOCK].contains(cmark_node_get_type(current)) { omittedHTML = true }
                    if cmark_node_get_type(current) == CMARK_NODE_CODE_BLOCK,
                       let parent = cmark_node_parent(current), cmark_node_get_type(parent) == CMARK_NODE_DOCUMENT,
                       let info = cmark_node_get_fence_info(current),
                       let kind = MarkdownDiagram.Kind(rawValue: String(cString: info).trimmingCharacters(in: .whitespaces)),
                       kind != .mermaid, diagramRange(current) != nil, let literal = cmark_node_get_literal(current),
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        let item = MarkdownRenderedDiagram(kind: kind, source: String(cString: literal))
                        let html = "<pre data-lac-diagram=\"\(diagrams.count)\">\(escape(item.source))</pre>"
                        let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                        if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                            diagrams.append(item)
                            cmark_node_unlink(current); cmark_node_free(current)
                        } else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    if highlightCode, cmark_node_get_type(current) == CMARK_NODE_CODE_BLOCK,
                       cmark_node_get_syntax_extension(current) == nil,
                       let infoPointer = cmark_node_get_fence_info(current), let literalPointer = cmark_node_get_literal(current),
                       let language = MarkdownCodeHighlightService.language(for: String(cString: infoPointer)),
                       let inner = highlightedCodeHTML(String(cString: literalPointer), language: language),
                       let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) {
                        // Как в cmark: класс языка — до первого пробела информационной строки.
                        let first = String(String(cString: infoPointer).prefix { !" \t\r\n".contains($0) })
                        let position = includeSourcePositions
                            ? " data-sourcepos=\"\(cmark_node_get_start_line(current)):\(cmark_node_get_start_column(current))-\(cmark_node_get_end_line(current)):\(cmark_node_get_end_column(current))\"" : ""
                        let html = "<pre\(position)><code class=\"language-\(htmlEscaped(first))\">\(inner)</code></pre>\n"
                        let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                        if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                            cmark_node_unlink(current); cmark_node_free(current)
                        } else { cmark_node_free(replacement) }
                        child = next
                        continue
                    }
                    let item: MarkdownRenderedMath?
                    if let value = inlineByNode[current] { item = MarkdownRenderedMath(source: value.text, display: false) }
                    else if cmark_node_get_type(current) == CMARK_NODE_CODE_BLOCK,
                            cmark_node_get_syntax_extension(current) == extensionNode,
                            let literal = cmark_node_get_literal(current) {
                        item = MarkdownRenderedMath(source: String(cString: literal), display: true)
                    } else { item = nil }
                    if let item {
                        let tag = item.display ? "div" : "span"
                        let value = item.display ? "$$\n" + item.source + "$$" : "$" + item.source + "$"
                        let html = "<\(tag) data-lac-math=\"\(formulas.count)\">\(escape(value))</\(tag)>"
                        let kind = item.display ? CMARK_NODE_CUSTOM_BLOCK : CMARK_NODE_CUSTOM_INLINE
                        if let replacement = cmark_node_new(kind) {
                            let configured = html.withCString { cmark_node_set_on_enter(replacement, $0) }
                            if configured != 0 && cmark_node_insert_before(current, replacement) != 0 {
                                formulas.append(item)
                                cmark_node_unlink(current)
                                cmark_node_free(current)
                            } else { cmark_node_free(replacement) }
                        }
                    } else { visit(current) }
                    child = next
                }
            }
            visit(document)
            if Task.isCancelled || unsafeResourceFailure { return ("", headingIDs, [], [], omittedHTML) }
            if preserveWhitespace {
                var stack = [document]
                while let node = stack.popLast() {
                    if Task.isCancelled { return ("", headingIDs, [], [], omittedHTML) }
                    var child = cmark_node_first_child(node)
                    while let current = child {
                        let next = cmark_node_next(current)
                        if cmark_node_get_type(current) == CMARK_NODE_TEXT {
                            guard let open = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { return ("", headingIDs, [], [], omittedHTML) }
                            guard let close = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else {
                                cmark_node_free(open); return ("", headingIDs, [], [], omittedHTML)
                            }
                            let tag = forExport ? "<span data-lac-whitespace style=\"white-space:break-spaces\">" : "<span data-lac-whitespace>"
                            let start = tag.withCString { cmark_node_set_on_enter(open, $0) }
                            let end = "</span>".withCString { cmark_node_set_on_enter(close, $0) }
                            guard start != 0, end != 0, cmark_node_insert_before(current, open) != 0 else {
                                cmark_node_free(open); cmark_node_free(close)
                                return ("", headingIDs, [], [], omittedHTML)
                            }
                            guard cmark_node_insert_after(current, close) != 0 else {
                                cmark_node_unlink(open); cmark_node_free(open); cmark_node_free(close)
                                return ("", headingIDs, [], [], omittedHTML)
                            }
                        } else { stack.append(current) }
                        child = next
                    }
                }
            }
            guard let rendered = cmark_render_html(document, includeSourcePositions ? options | CMARK_OPT_SOURCEPOS : options, cmark_parser_get_syntax_extensions(parser)) else {
                return ("", headingIDs, formulas, diagrams, omittedHTML)
            }
            defer { free(rendered) }
            return (String(cString: rendered), headingIDs, formulas, diagrams, omittedHTML)
        } ?? ("", [], [], [], false)
    }

    private static func installListStyleMarkers(in root: OpaquePointer, source: MarkdownPresentationParser.Source) -> Set<Int> {
        var depths: Set<Int> = [], stack: [(OpaquePointer, Int)] = [(root, 0)]
        while let (node, parentDepth) = stack.popLast() {
            if Task.isCancelled { return [] }
            let type = cmark_node_get_type(node)
            let depth = type == CMARK_NODE_LIST ? parentDepth + 1 : parentDepth
            var child = cmark_node_first_child(node)
            while let current = child {
                if Task.isCancelled { return [] }
                stack.append((current, depth))
                child = cmark_node_next(current)
            }
            guard type == CMARK_NODE_ITEM, let parent = cmark_node_parent(node),
                  cmark_node_get_type(parent) == CMARK_NODE_LIST,
                  source.taskCheckbox(node) == nil,
                  let typeName = cmark_node_get_type_string(node), String(cString: typeName) != "tasklist",
                  let marker = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let kind = cmark_node_get_list_type(parent) == CMARK_ORDERED_LIST ? "ordered" : "unordered"
            let html = "<span hidden data-lac-list-depth=\"\(depth)\" data-lac-list-kind=\"\(kind)\"></span>"
            let configured = html.withCString { cmark_node_set_on_enter(marker, $0) }
            if configured != 0 && cmark_node_prepend_child(node, marker) != 0 { depths.insert(depth) }
            else { cmark_node_free(marker) }
        }
        return depths
    }

    private static func mergeMarkerInsertions(_ insertions: [(Int, String)]) -> [(Int, String)]? {
        var merged: [Int: String] = [:]
        for (offset, marker) in insertions {
            if Task.isCancelled { return nil }
            merged[offset, default: ""] += marker
        }
        return merged.map { ($0.key, $0.value) }
    }

    private static func installTableOfContents(in root: OpaquePointer, markdown: String, source: MarkdownPresentationParser.Source, mathExtension: OpaquePointer, options: Int32, mathInline: [OpaquePointer: MarkdownMathExtension.Inline] = [:],
        emojiLocations: [OpaquePointer: [(Int, MarkdownEmojiCandidateExtractor.Candidate)]],
        emojiCandidates: [MarkdownEmojiCandidateExtractor.Candidate], emojiValues: [String: String],
        resolveLocalImages: Bool, documentURL: URL?, includeHeadingNumbers: Bool,
        imageMarkersByNode: inout [OpaquePointer: [(Int, String, MarkdownHTMLMediaService.ExportImageMarker)]],
        mediaMarkersByNode: inout [OpaquePointer: [(Int, Int, String, MarkdownHTMLMediaService.ProvenMedia)]],
        unprovedImageBlocks: Set<OpaquePointer>,
        confirmedInline: inout [NSRange: String],
        detachedNodes: inout [OpaquePointer],
        markRemote: @escaping (String) -> String?, resolveMedia: @escaping (String) -> String,
        preserveRawHTML: Bool) -> (Set<String>, Bool, [NSRange]) {
        struct Heading {
            let node: OpaquePointer
            let level: Int
            let title: String
            let slug: String
            let id: String
        }
        let bytes = Array(markdown.utf8)
        let sourceText = markdown as NSString
        var starts = [0], offset = 0
        while offset < bytes.count {
            if bytes[offset] == 13 || bytes[offset] == 10 {
                if bytes[offset] == 13, offset + 1 < bytes.count, bytes[offset + 1] == 10 { offset += 1 }
                starts.append(offset + 1)
            }
            offset += 1
        }
        func isMarker(_ node: OpaquePointer) -> Bool {
            let line = Int(cmark_node_get_start_line(node)) - 1
            let column = Int(cmark_node_get_start_column(node))
            let endLine = Int(cmark_node_get_end_line(node)) - 1
            let endColumn = Int(cmark_node_get_end_column(node))
            guard line >= 0, line < starts.count, line == endLine, column > 0, endColumn - column == 4 else { return false }
            let start = starts[line] + column - 1
            guard start >= 0, start + 5 <= bytes.count else { return false }
            return Array(bytes[start..<(start + 5)]) == Array("[toc]".utf8)
        }
        var headings: [Heading] = [], markers: [OpaquePointer] = [], links: [OpaquePointer] = [], checkedTasks: [OpaquePointer] = []
        var htmlNodes: [(OpaquePointer, NSRange, Bool)] = []
        var lazyInlineRanges: [OpaquePointer: NSRange] = [:]
        let hasStyledSpanCandidate = markdown.localizedCaseInsensitiveContains("<span")
        var htmlRangesAvailable = true
        var htmlCellPositions: [OpaquePointer: MarkdownPresentationParser.Source.TableCellPositions?] = [:]
        var highlights: [(OpaquePointer, NSRange, [(NSRange, MarkdownPresentationKind)])] = []
        var subscripts: [(OpaquePointer, NSRange)] = []
        var inlineHTMLParents: [(OpaquePointer, MarkdownPresentationParser.Source.TableCellPositions?)] = []
        var tableBreaks: [OpaquePointer] = []
        var alerts: [(OpaquePointer, OpaquePointer, String)] = []
        var anchors = MarkdownHeadingAnchors.Allocator()
        func visit(_ node: OpaquePointer, unsupported: Bool) {
            guard let name = cmark_node_get_type_string(node) else { return }
            let type = String(cString: name)
            let blocked = unsupported || type == "table" || type == "image" || cmark_node_get_type(node) == CMARK_NODE_FOOTNOTE_DEFINITION
            if type == "paragraph", hasStyledSpanCandidate,
               let ranges = source.lazyParagraphInlineRanges(node, text: sourceText, isCancelled: { Task.isCancelled }) {
                lazyInlineRanges.merge(ranges) { _, new in new }
            }
            if !blocked, type == "tasklist", let checkbox = source.taskCheckbox(node), checkbox.state != 32,
               cmark_gfm_extensions_get_tasklist_item_checked(node) { checkedTasks.append(node) }
            if ["html_inline", "html_block"].contains(type) {
                var ancestor = cmark_node_parent(node), cell: OpaquePointer?
                while let current = ancestor {
                    if let name = cmark_node_get_type_string(current), String(cString: name) == "table_cell" { cell = current; break }
                    ancestor = cmark_node_parent(current)
                }
                let range: NSRange?
                if let cell {
                    let positions: MarkdownPresentationParser.Source.TableCellPositions?
                    if let cached = htmlCellPositions[cell] { positions = cached }
                    else {
                        positions = source.tableCellPositions(cell, isCancelled: { Task.isCancelled })
                        htmlCellPositions[cell] = .some(positions)
                    }
                    range = positions.flatMap { source.tableInlineRange(node, positions: $0) }
                } else { range = lazyInlineRanges[node] ?? source.range(node) }
                if let range, MarkdownPresentationParser.htmlSourceMatches(node, range: range, text: sourceText, isCancelled: { Task.isCancelled }) {
                    htmlNodes.append((node, range, type == "html_inline"))
                } else { htmlRangesAvailable = false }
            }
            if type == "table_cell", let positions = source.tableCellPositions(node) {
                var child = cmark_node_first_child(node)
                while let current = child {
                    if let childName = cmark_node_get_type_string(current), String(cString: childName) == "html_inline",
                       let literal = cmark_node_get_literal(current), let range = source.tableInlineRange(current, positions: positions) {
                        let raw = sourceText.substring(with: range)
                        if raw == String(cString: literal), ["<br>", "<br/>", "<br />"].contains(raw.lowercased()) {
                            tableBreaks.append(current)
                        }
                    }
                    child = cmark_node_next(current)
                }
            }
            if !blocked, type == "heading" {
                let title = MarkdownPresentationParser.headingText(node, mathInline: mathInline)
                let anchor = anchors.next(title)
                headings.append(Heading(node: node, level: Int(cmark_node_get_heading_level(node)), title: title, slug: anchor.slug, id: anchor.id))
            }
            if !unsupported, type == "paragraph", let parent = cmark_node_parent(node), parent == root,
               let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
               let childName = cmark_node_get_type_string(child), String(cString: childName) == "text", isMarker(node) { markers.append(node) }
            if type == "link" { links.append(node) }
            if !blocked, let alert = MarkdownPresentationParser.alert(node, source: source, text: sourceText),
               let paragraph = cmark_node_first_child(node), let marker = cmark_node_first_child(paragraph) {
                alerts.append((node, marker, alert.label))
            }
            if !blocked, type == "text", let range = source.range(node) {
                let matches = MarkdownPresentationParser.inlineDecorations(node, source: source, text: sourceText)
                if !matches.isEmpty { highlights.append((node, range, matches)) }
            }
            if !blocked, let range = MarkdownPresentationParser.subscriptRange(node, source: source, text: sourceText) {
                subscripts.append((node, range))
            }
            if !blocked && ["paragraph", "heading", "strong", "emph", "link", "strikethrough"].contains(type) {
                inlineHTMLParents.append((node, nil))
            } else if ["table_cell", "strong", "emph", "link", "strikethrough"].contains(type) {
                var ancestor: OpaquePointer? = node, cell: OpaquePointer?, valid = true
                while let current = ancestor {
                    let currentType = cmark_node_get_type(current)
                    if currentType == CMARK_NODE_IMAGE || currentType == CMARK_NODE_FOOTNOTE_DEFINITION { valid = false; break }
                    if let name = cmark_node_get_type_string(current), String(cString: name) == "table_cell" { cell = current; break }
                    ancestor = cmark_node_parent(current)
                }
                if valid, let cell {
                    let positions: MarkdownPresentationParser.Source.TableCellPositions?
                    if let cached = htmlCellPositions[cell] { positions = cached }
                    else {
                        positions = source.tableCellPositions(cell, isCancelled: { Task.isCancelled })
                        htmlCellPositions[cell] = .some(positions)
                    }
                    if let positions { inlineHTMLParents.append((node, positions)) }
                }
            }
            var child = cmark_node_first_child(node)
            while let next = child { visit(next, unsupported: blocked); child = cmark_node_next(next) }
        }
        visit(root, unsupported: false)
        for task in checkedTasks {
            if Task.isCancelled { break }
            guard let marker = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let configured = "<span data-lac-checked-task></span>".withCString { cmark_node_set_on_enter(marker, $0) }
            if configured == 0 || cmark_node_prepend_child(task, marker) == 0 { cmark_node_free(marker) }
        }
        func renderedSource(_ range: NSRange) -> String {
            let result = NSMutableString(string: sourceText.substring(with: range))
            var low = 0, high = emojiCandidates.count
            while low < high {
                let middle = (low + high) / 2
                if emojiCandidates[middle].range.location < range.location { low = middle + 1 } else { high = middle }
            }
            var matches: [MarkdownEmojiCandidateExtractor.Candidate] = []
            while low < emojiCandidates.count && emojiCandidates[low].range.location < NSMaxRange(range) {
                let candidate = emojiCandidates[low]
                if NSMaxRange(candidate.range) <= NSMaxRange(range) { matches.append(candidate) }
                low += 1
            }
            for candidate in matches.reversed() {
                if let value = emojiValues[candidate.name] {
                    result.replaceCharacters(in: NSRange(location: candidate.range.location - range.location, length: candidate.range.length), with: value)
                }
            }
            return result as String
        }
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let confirmed = (includeHeadingNumbers ? headings : []).compactMap { heading -> (Heading, MarkdownHeading)? in
            guard let range = source.range(heading.node) ?? source.headingAnchor(heading.node) else { return nil }
            return (heading, MarkdownHeading(level: heading.level, title: heading.title, range: range))
        }
        let numbered = MarkdownHeadingNumbering.applying(to: confirmed.map { $0.1 }, enabled: true)
        var headingNumbers: [OpaquePointer: String] = [:]
        for (entry, heading) in zip(confirmed, numbered) {
            if Task.isCancelled { break }
            guard let number = heading.number, let marker = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { continue }
            let html = "<span data-lac-heading-number=\"\(escaped(number))\"></span>"
            let configured = html.withCString { cmark_node_set_on_enter(marker, $0) }
            guard configured != 0, cmark_node_prepend_child(entry.0.node, marker) != 0 else { cmark_node_free(marker); continue }
            headingNumbers[entry.0.node] = number
        }
        var installed = Set<String>()
        for heading in headings {
            guard let node = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let html = "<span id=\"\(escaped(heading.id))\"></span>"
            let configured = html.withCString { cmark_node_set_on_enter(node, $0) }
            guard configured != 0, cmark_node_insert_before(heading.node, node) != 0 else { cmark_node_free(node); continue }
            installed.insert(heading.id)
        }
        let aliases = MarkdownHeadingAnchors.aliases(headings.filter { installed.contains($0.id) }.map {
            MarkdownHeadingAnchors.Entry(slug: $0.slug, id: $0.id)
        })
        var orderedHTML = htmlNodes.sorted { $0.1.location < $1.1.location }
        var htmlContext = MarkdownImageUploadService.HTMLContext(), templateDepth = 0, previousHTMLEnd = 0
        var scriptStartedInContainer = false
        func insideContainer(_ node: OpaquePointer) -> Bool {
            var ancestor = cmark_node_parent(node)
            while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
                if Task.isCancelled { return false }
                let kind = cmark_node_get_type(current)
                if kind == CMARK_NODE_BLOCK_QUOTE || kind == CMARK_NODE_ITEM || kind == CMARK_NODE_LIST { return true }
                ancestor = cmark_node_parent(current)
            }
            return false
        }
        var confirmedInlineHTML: Set<OpaquePointer> = []
        var rubyTags: [(parent: OpaquePointer, range: NSRange, closing: Bool)] = []
        var rawTextOpening: Int?, rawTextRanges: [NSRange] = []
        if htmlRangesAvailable {
            for (node, range, inline) in orderedHTML {
                if Task.isCancelled { break }
                if range.location < previousHTMLEnd { htmlContext.invalidate(); continue }
                if htmlContext.inScriptContext && previousHTMLEnd < range.location && (scriptStartedInContainer || insideContainer(node)) {
                    for index in previousHTMLEnd..<range.location {
                        if Task.isCancelled { break }
                        if sourceText.character(at: index) == 10 || sourceText.character(at: index) == 13 {
                            htmlContext.invalidate(); break
                        }
                    }
                }
                let outsideTemplate = templateDepth == 0
                let safe = htmlContext.consume(source: sourceText, range: range, isCancelled: { Task.isCancelled }, confirmedTag: { tag, name, closing in
                    if name == "template" { templateDepth = closing ? max(0, templateDepth - 1) : templateDepth + 1 }
                    if name == "ruby", inline, templateDepth == 0, let parent = cmark_node_parent(node) { rubyTags.append((parent, tag, closing)) }
                    if name == "script" && !closing { scriptStartedInContainer = insideContainer(node) }
                    if preserveRawHTML && inline && !closing && ["script", "style", "textarea"].contains(name) { rawTextOpening = tag.location }
                }, confirmedRawClose: { tag, _ in
                    if let start = rawTextOpening {
                        rawTextRanges.append(NSRange(location: start, length: NSMaxRange(tag) - start))
                        rawTextOpening = nil
                    }
                })
                if inline && safe && outsideTemplate && templateDepth == 0 { confirmedInlineHTML.insert(node) }
                if !htmlContext.inScriptContext { scriptStartedInContainer = false }
                previousHTMLEnd = NSMaxRange(range)
            }
        }
        if let start = rawTextOpening { rawTextRanges.append(NSRange(location: start, length: sourceText.length - start)) }
        func insideRawText(_ range: NSRange) -> Bool {
            var low = 0, high = rawTextRanges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(rawTextRanges[middle]) <= range.location { low = middle + 1 } else { high = middle }
            }
            return low < rawTextRanges.count && rawTextRanges[low].location < NSMaxRange(range)
        }
        let confirmedBeforeStyleFilter = confirmedInlineHTML
        let styleFilter = MarkdownPresentationParser.filterInlineHTMLForStyles(
            htmlNodes.filter { $0.2 }.map { ($0.0, Optional($0.1)) }, confirmed: confirmedInlineHTML, text: sourceText,
            isCancelled: { Task.isCancelled })
        confirmedInlineHTML = styleFilter.confirmed
        let rubyCandidates = MarkdownPresentationParser.inlineRubyCandidates(parents: inlineHTMLParents.compactMap { $0.1 == nil ? $0.0 : nil },
            confirmed: confirmedInlineHTML, source: source, text: sourceText, sourceRange: { node in
                cmark_node_get_type(node) == CMARK_NODE_TEXT ? source.editingTextRange(node) : source.range(node)
            }, isCancelled: { Task.isCancelled })
        let provedRuby = MarkdownHTMLMediaService.provenRuby(root: root, mathExtension: mathExtension, options: options,
            text: sourceText, candidates: rubyCandidates.map(\.proof), isCancelled: { Task.isCancelled })
        var acceptedRuby = Set<Int>()
        for index in provedRuby {
            if Task.isCancelled { break }
            let range = rubyCandidates[index].value.range
            var low = 0, high = emojiCandidates.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(emojiCandidates[middle].range) <= range.location { low = middle + 1 } else { high = middle }
            }
            if low == emojiCandidates.count || emojiCandidates[low].range.location >= NSMaxRange(range) { acceptedRuby.insert(index) }
        }
        let rubyBlocked = MarkdownPresentationParser.unconfirmedRubyRanges(tags: rubyTags,
            accepted: Set(acceptedRuby.map { rubyCandidates[$0].value.range }), sourceLength: sourceText.length,
            parentRange: { source.range($0) }, isCancelled: { Task.isCancelled })
        var blockedRanges: [NSRange] = []
        for range in (styleFilter.blocked + rubyBlocked).sorted(by: { $0.location < $1.location }) {
            if Task.isCancelled { break }
            if let last = blockedRanges.last, range.location <= NSMaxRange(last) { blockedRanges[blockedRanges.count - 1] = NSUnionRange(last, range) }
            else { blockedRanges.append(range) }
        }
        let svgCandidates = MarkdownPresentationParser.standaloneSVGInlineCandidates(
            parents: inlineHTMLParents.compactMap { $0.1 == nil ? $0.0 : nil }, confirmed: confirmedInlineHTML,
            source: source, text: sourceText, isCancelled: { Task.isCancelled })
        let acceptedSVG = MarkdownHTMLMediaService.provenSVG(root: root, mathExtension: mathExtension, options: options,
            text: sourceText, candidates: svgCandidates.map(\.proof), isCancelled: { Task.isCancelled })
        for (node, range, inline) in htmlNodes where inline && !confirmedInlineHTML.contains(node) {
            confirmedInline.removeValue(forKey: range)
        }
        var fallbackParagraphs: Set<OpaquePointer> = []
        var fallbackCells = Set<OpaquePointer>()
        var rowRanges: [OpaquePointer: [OpaquePointer: NSRange]] = [:], invalidRows = Set<OpaquePointer>()
        var htmlOpenings: [Int: (OpaquePointer, NSRange)] = [:]
        var rubyOpeningLocations = Set<Int>()
        for tag in rubyTags {
            if Task.isCancelled { break }
            if !tag.closing { rubyOpeningLocations.insert(tag.range.location) }
        }
        for (node, range, inline) in htmlNodes where inline {
            if Task.isCancelled { break }
            htmlOpenings[range.location] = (node, range)
        }
        for blocked in (preserveRawHTML ? [] : blockedRanges) {
            if Task.isCancelled { break }
            guard let (node, opening) = htmlOpenings[blocked.location],
                  confirmedBeforeStyleFilter.contains(node),
                  MarkdownPresentationParser.htmlSourceMatches(node, range: opening, text: sourceText, isCancelled: { Task.isCancelled }) else { continue }
            let tag = sourceText.substring(with: opening)
            let unsupportedSpan = MarkdownHTMLMediaService.hasStyledSpan(in: tag, isCancelled: { Task.isCancelled }) &&
                MarkdownHTMLMediaService.inlineStyleOpening(tag, isCancelled: { Task.isCancelled }) == nil
            guard unsupportedSpan || rubyOpeningLocations.contains(opening.location) else { continue }
            var parent = cmark_node_parent(node)
            while let current = parent, cmark_node_get_type(current) != CMARK_NODE_PARAGRAPH,
                  cmark_node_get_type_string(current).map({ String(cString: $0) }) != "table_cell" {
                if Task.isCancelled { break }
                parent = cmark_node_parent(current)
            }
            if let cell = parent, cmark_node_get_type_string(cell).map({ String(cString: $0) }) == "table_cell",
               !fallbackCells.contains(cell), let row = cmark_node_parent(cell) {
                if rowRanges[row] == nil && !invalidRows.contains(row) {
                    if let ranges = source.tableRowCellSourceRanges(cell, text: sourceText, isCancelled: { Task.isCancelled }) { rowRanges[row] = ranges }
                    else { invalidRows.insert(row) }
                }
                guard let range = rowRanges[row]?[cell], opening.location >= range.location,
                      NSMaxRange(opening) <= NSMaxRange(range), NSMaxRange(blocked) <= NSMaxRange(range),
                      let first = cmark_node_first_child(cell), !Task.isCancelled,
                      let replacement = cmark_node_new(CMARK_NODE_TEXT) else { continue }
                let literal = sourceText.substring(with: range)
                guard literal.withCString({ cmark_node_set_literal(replacement, $0) }) != 0,
                      cmark_node_insert_before(first, replacement) != 0 else { cmark_node_free(replacement); continue }
                var child: OpaquePointer? = first
                while let item = child {
                    if Task.isCancelled { break }
                    let next = cmark_node_next(item)
                    cmark_node_unlink(item)
                    detachedNodes.append(item)
                    fallbackParagraphs.insert(item)
                    child = next
                }
                fallbackCells.insert(cell)
                continue
            }
            guard let paragraph = parent, !fallbackParagraphs.contains(paragraph),
                  source.referencePrefix(paragraph) == nil, let range = source.editingTextRange(paragraph),
                  range.length > 0, NSMaxRange(range) <= sourceText.length,
                  opening.location >= range.location, NSMaxRange(opening) <= NSMaxRange(range),
                  NSMaxRange(blocked) <= NSMaxRange(range),
                  source.firstPosition(paragraph) == range.location,
                  let prefix = MarkdownPresentationParser.containerPrefixes(paragraph, source: source, text: sourceText, isCancelled: { Task.isCancelled }) else { continue }
            let line = sourceText.lineRange(for: NSRange(location: range.location, length: 0))
            let lastLine = sourceText.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            var end = NSMaxRange(lastLine)
            while end > lastLine.location && [10, 13].contains(Int(sourceText.character(at: end - 1))) { end -= 1 }
            guard range.location >= line.location, NSMaxRange(range) == end,
                  sourceText.substring(with: NSRange(location: line.location, length: range.location - line.location)).utf16.elementsEqual(prefix.source.utf16) else { continue }
            if cmark_node_get_start_line(paragraph) != cmark_node_get_end_line(paragraph),
               cmark_node_parent(paragraph).map({ cmark_node_get_type($0) != CMARK_NODE_DOCUMENT }) == true {
                let continuation = prefix.continuation as NSString
                guard continuation.length > 0, !prefix.source.contains("\t"), !prefix.continuation.contains("\t") else { continue }
                var lazyRanges: [NSRange]?
                func provesLazyLine(_ start: Int, _ end: Int) -> Bool {
                    guard start < end else { return false }
                    if lazyRanges == nil {
                        var pending = [paragraph], ranges: [NSRange] = []
                        while let item = pending.popLast() {
                            if Task.isCancelled { return false }
                            let type = cmark_node_get_type(item)
                            if let range = lazyInlineRanges[item],
                               type == CMARK_NODE_TEXT || (type == CMARK_NODE_HTML_INLINE && confirmedBeforeStyleFilter.contains(item)) {
                                ranges.append(range)
                            }
                            var child = cmark_node_first_child(item)
                            while let node = child { if Task.isCancelled { return false }; pending.append(node); child = cmark_node_next(node) }
                        }
                        lazyRanges = ranges.sorted { $0.location < $1.location }
                    }
                    guard let ranges = lazyRanges else { return false }
                    var low = 0, high = ranges.count
                    while low < high {
                        let middle = (low + high) / 2
                        if ranges[middle].location < start { low = middle + 1 } else { high = middle }
                    }
                    var cursor = start
                    while low < ranges.count && cursor < end {
                        if Task.isCancelled { return false }
                        let range = ranges[low]
                        guard range.location == cursor, range.length > 0, NSMaxRange(range) <= end else { return false }
                        cursor = NSMaxRange(range); low += 1
                    }
                    return cursor == end
                }
                var position = NSMaxRange(line), valid = true
                while position < NSMaxRange(range) {
                    if Task.isCancelled { valid = false; break }
                    let currentLine = sourceText.lineRange(for: NSRange(location: position, length: 0))
                    var contentEnd = min(NSMaxRange(currentLine), NSMaxRange(range))
                    while contentEnd > position && [10, 13].contains(Int(sourceText.character(at: contentEnd - 1))) { contentEnd -= 1 }
                    let matchesPrefix = contentEnd - position >= continuation.length &&
                        sourceText.substring(with: NSRange(location: position, length: continuation.length)).utf16.elementsEqual(prefix.continuation.utf16) &&
                        !sourceText.substring(with: NSRange(location: position + continuation.length, length: contentEnd - position - continuation.length)).trimmingCharacters(in: .whitespaces).isEmpty
                    if !matchesPrefix && !provesLazyLine(position, contentEnd) { valid = false; break }
                    position = NSMaxRange(currentLine)
                }
                guard valid, !Task.isCancelled else { continue }
            }
            guard !Task.isCancelled, let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let html = "<pre>" + escaped(sourceText.substring(with: range)) + "</pre>"
            guard html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                  cmark_node_insert_before(paragraph, replacement) != 0 else { cmark_node_free(replacement); continue }
            cmark_node_unlink(paragraph)
            detachedNodes.append(paragraph)
            fallbackParagraphs.insert(paragraph)
        }
        var detachedSVGNodes = Set<OpaquePointer>()
        for index in acceptedSVG.sorted() {
            if Task.isCancelled { break }
            let candidate = svgCandidates[index]
            guard let paragraph = candidate.paragraph, !fallbackParagraphs.contains(paragraph) else { continue }
            var low = 0, high = blockedRanges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(blockedRanges[middle]) <= candidate.range.location { low = middle + 1 } else { high = middle }
            }
            if low < blockedRanges.count && blockedRanges[low].location < NSMaxRange(candidate.range) { continue }
            if candidate.isInline {
                if preserveRawHTML { continue }
                var nodes: [OpaquePointer] = [], current: OpaquePointer? = candidate.proof.opening
                while let node = current {
                    if Task.isCancelled { break }
                    nodes.append(node)
                    if node == candidate.proof.closing { break }
                    current = cmark_node_next(node)
                }
                guard !Task.isCancelled, nodes.last == candidate.proof.closing,
                      let replacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { continue }
                let html = "<img src=\"data:image/svg+xml;base64," + candidate.data.base64EncodedString() + "\" alt=\"\">"
                guard html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                      cmark_node_insert_before(candidate.proof.opening, replacement) != 0 else { cmark_node_free(replacement); continue }
                for node in nodes {
                    if Task.isCancelled { break }
                    cmark_node_unlink(node); detachedNodes.append(node); detachedSVGNodes.insert(node)
                }
                continue
            }
            guard let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let html = "<img src=\"data:image/svg+xml;base64," + candidate.data.base64EncodedString() + "\" alt=\"\">"
            guard html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                  cmark_node_replace(paragraph, replacement) != 0 else { cmark_node_free(replacement); continue }
            detachedNodes.append(paragraph)
            fallbackParagraphs.insert(paragraph)
        }
        func isFallbackDescendant(_ node: OpaquePointer) -> Bool {
            var current: OpaquePointer? = node
            while let item = current {
                if fallbackParagraphs.contains(item) { return true }
                current = cmark_node_parent(item)
            }
            return false
        }
        if !fallbackParagraphs.isEmpty {
            orderedHTML.removeAll { isFallbackDescendant($0.0) }
            inlineHTMLParents.removeAll { isFallbackDescendant($0.0) }
            links.removeAll { isFallbackDescendant($0) }
            highlights.removeAll { isFallbackDescendant($0.0) }
            subscripts.removeAll { isFallbackDescendant($0.0) }
            tableBreaks.removeAll { isFallbackDescendant($0) }
            alerts.removeAll { isFallbackDescendant($0.1) }
        }
        if !detachedSVGNodes.isEmpty {
            orderedHTML.removeAll { detachedSVGNodes.contains($0.0) }
            highlights.removeAll { detachedSVGNodes.contains($0.0) }
            subscripts.removeAll { detachedSVGNodes.contains($0.0) }
        }
        orderedHTML.removeAll { entry in
            var low = 0, high = blockedRanges.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(blockedRanges[middle]) <= entry.1.location { low = middle + 1 } else { high = middle }
            }
            return low < blockedRanges.count && blockedRanges[low].location < NSMaxRange(entry.1)
        }
        for (node, entries) in emojiLocations {
            if Task.isCancelled { break }
            if detachedSVGNodes.contains(node) { continue }
            if isFallbackDescendant(node) { continue }
            if preserveRawHTML, let range = source.range(node), insideRawText(range) { continue }
            guard let literal = cmark_node_get_literal(node) else { continue }
            let result = NSMutableString(string: String(cString: literal))
            for (offset, candidate) in entries.reversed() {
                guard let value = emojiValues[candidate.name], offset >= 0,
                      offset + candidate.range.length <= result.length else { continue }
                result.replaceCharacters(in: NSRange(location: offset, length: candidate.range.length), with: value)
            }
            (result as String).withCString { _ = cmark_node_set_literal(node, $0) }
        }
        let visibleHeadingTitles = Dictionary(uniqueKeysWithValues: headings.map {
            ($0.node, MarkdownPresentationParser.headingText($0.node, mathInline: mathInline))
        })
        var htmlPairs: [MarkdownPresentationParser.InlineHTMLPair] = []
        let rubyParents = Set(acceptedRuby.compactMap { cmark_node_parent(rubyCandidates[$0].proof.opening) })
        for (parent, positions) in inlineHTMLParents {
            if Task.isCancelled { break }
            let pairs = MarkdownPresentationParser.inlineHTMLPairs(in: parent, confirmed: confirmedInlineHTML, source: source, text: sourceText, tablePositions: positions, ignoreRubyTags: rubyParents.contains(parent), isCancelled: { Task.isCancelled })
            htmlPairs.append(contentsOf: positions == nil ? pairs : pairs.filter { if case .inlineStyle = $0.kind { return true }; return false })
        }
        let named = htmlRangesAvailable ? MarkdownPresentationParser.confirmedNamedAnchors(in: sourceText, ranges: orderedHTML.map { $0.1 }, isCancelled: { Task.isCancelled }) : []
        var namesByRange: [NSRange: [String]] = [:]
        for anchor in named { namesByRange[anchor.range, default: []].append(anchor.name) }
        var anchorIDs: [Int: String] = [:]
        var namedAliases: [Data: String] = [:]
        var htmlIndex = 0
        var blockAnchors: [Int: [(MarkdownNamedAnchor, String)]] = [:]
        var omittedNamedHTML = false
        for anchor in named {
            while htmlIndex < orderedHTML.count && NSMaxRange(orderedHTML[htmlIndex].1) <= anchor.range.location { htmlIndex += 1 }
            guard aliases[anchor.name] == nil,
                  htmlIndex < orderedHTML.count else { continue }
            let container = orderedHTML[htmlIndex]
            guard NSLocationInRange(anchor.range.location, container.1) else { continue }
            if anchorIDs[anchor.range.location] != nil { continue }
            if !container.2 && container.1 != anchor.range {
                let id = "lac-anchor-\(UUID().uuidString)"
                anchorIDs[anchor.range.location] = id
                blockAnchors[htmlIndex, default: []].append((anchor, id))
                continue
            }
            let id = "lac-anchor-\(anchorIDs.count)"
            guard let node = cmark_node_new(container.2 ? CMARK_NODE_CUSTOM_INLINE : CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let configured = "<span id=\"\(id)\"></span>".withCString { cmark_node_set_on_enter(node, $0) }
            guard configured != 0, cmark_node_insert_before(container.0, node) != 0 else { cmark_node_free(node); continue }
            anchorIDs[anchor.range.location] = id
            installed.insert(id)
        }
        var paths: Result<MarkdownResourcePaths, Error>?
        var images: [Data: String] = [:]
        for (index, entries) in blockAnchors.sorted(by: { $0.key < $1.key }) {
            let (original, range, _) = orderedHTML[index]
            if preserveRawHTML { continue }
            if unprovedImageBlocks.contains(original) { continue }
            let imageEntries = imageMarkersByNode[original] ?? []
            let mediaEntries = mediaMarkersByNode[original] ?? []
            let block: String
            var insertions: [(Int, String)] = []
            var imageMarkers: [String: MarkdownHTMLMediaService.ExportImageMarker] = [:]
            var mediaMarkers: [String: MarkdownHTMLMediaService.ProvenMedia] = [:]
            if !imageEntries.isEmpty || !mediaEntries.isEmpty {
                guard let pointer = cmark_node_get_literal(original),
                      let offsets = MarkdownHTMLMediaService.htmlBlockTagOffsets(original, range: range, tags: entries.map { $0.0.range }.sorted { $0.location < $1.location }, sourceText: sourceText, isCancelled: { Task.isCancelled }) else { continue }
                block = String(cString: pointer)
                for (_, close, marker, expected) in mediaEntries {
                    insertions.append((close, "<!--\(marker)C-->"))
                    mediaMarkers[marker] = expected
                }
                for (offset, marker, expected) in imageEntries {
                    insertions.append((offset, "<!--\(marker)-->")); imageMarkers[marker] = expected
                }
                for (open, _, marker, _) in mediaEntries { insertions.append((open, "<!--\(marker)O-->")) }
                for (anchor, id) in entries {
                    guard let offset = offsets[anchor.range.location] else { continue }
                    insertions.append((offset, "<span id=\"\(id)\"></span>"))
                }
                guard insertions.count == imageEntries.count + entries.count + mediaEntries.count * 2 else { continue }
            } else { block = sourceText.substring(with: range) }
            guard entries.allSatisfy({ !block.contains($0.1) }) else { continue }
            var expectations: [String: [String]] = [:]
            for (anchor, id) in entries {
                expectations[id] = namesByRange[anchor.range]
                if imageEntries.isEmpty && mediaEntries.isEmpty { insertions.append((anchor.range.location - range.location, "<span id=\"\(id)\"></span>")) }
            }
            guard let merged = mergeMarkerInsertions(insertions),
                  let markedBlock = MarkdownHTMLMediaService.insertingMarkers(in: block, insertions: merged, isCancelled: { Task.isCancelled }) else { continue }
            let fallback = MarkdownHTMLMediaService.htmlBlockTagOffsets(original, range: range, tags: [], sourceText: sourceText, isCancelled: { Task.isCancelled }).flatMap { _ in
                cmark_node_get_literal(original).map { String(cString: $0) }
            }
            let rendered = MarkdownHTMLMediaService.exportBlock(markedBlock, isCancelled: { Task.isCancelled }, anchorMarkers: expectations, imageMarkers: imageMarkers, mediaMarkers: mediaMarkers, imageOnly: resolveLocalImages, resolveMedia: resolveMedia, fallbackSource: fallback) { address in
                guard resolveLocalImages, !address.hasPrefix("//") else { return nil }
                if let remote = markRemote(address) { return remote }
                let scheme = URL(string: address)?.scheme?.lowercased()
                guard scheme == nil || scheme == "file" else { return nil }
                let key = Data(address.utf8)
                if let cached = images[key] { return cached }
                if MarkdownResourcePaths.requiresRoot(address), paths == nil {
                    paths = Result { try MarkdownResourcePaths(text: markdown, document: documentURL) }
                }
                let root = paths.flatMap { try? $0.get() }
                if MarkdownResourcePaths.requiresRoot(address), paths != nil, root == nil { return nil }
                guard let payload = try? MarkdownImageUploadService.payload(address: address, document: documentURL, paths: root) else { return nil }
                let uri = MarkdownImageUploadService.dataURI(payload, address: address)
                images[key] = uri
                return uri
            }
            guard let rendered, let replacement = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let configured = rendered.html.withCString { cmark_node_set_on_enter(replacement, $0) }
            guard configured != 0, cmark_node_replace(original, replacement) != 0 else { cmark_node_free(replacement); continue }
            omittedNamedHTML = omittedNamedHTML || rendered.omitted
            imageMarkersByNode.removeValue(forKey: original)
            mediaMarkersByNode.removeValue(forKey: original)
            cmark_node_free(original)
            for (_, id) in entries where !rendered.sourceFallback {
                installed.insert(id)
            }
        }
        for anchor in named where aliases[anchor.name] == nil {
            let key = Data(anchor.name.utf8)
            if namedAliases[key] == nil, let id = anchorIDs[anchor.range.location], installed.contains(id) { namedAliases[key] = id }
        }
        for link in links {
            guard let raw = cmark_node_get_url(link) else { continue }
            let url = String(cString: raw)
            guard url.hasPrefix("#"), let fragment = String(url.dropFirst()).removingPercentEncoding,
                  let target = aliases[fragment] ?? namedAliases[Data(fragment.utf8)], let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { continue }
            ("#" + encoded).withCString { _ = cmark_node_set_url(link, $0) }
        }
        for (original, range, matches) in highlights {
            if preserveRawHTML && insideRawText(range) { continue }
            var pieces: [OpaquePointer] = []
            var cursor = range.location
            var valid = true
            func addText(_ value: String, parent: OpaquePointer? = nil) {
                guard !value.isEmpty else { return }
                guard let node = cmark_node_new(CMARK_NODE_TEXT) else { valid = false; return }
                let configured = value.withCString { cmark_node_set_literal(node, $0) }
                guard configured != 0 else { cmark_node_free(node); valid = false; return }
                if let parent {
                    if cmark_node_append_child(parent, node) == 0 { cmark_node_free(node); valid = false }
                } else { pieces.append(OpaquePointer(node)) }
            }
            for (match, kind) in matches {
                addText(renderedSource(NSRange(location: cursor, length: match.location - cursor)))
                guard let node = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { valid = false; break }
                let tag = kind == .highlight ? "mark" : "sup"
                let markerLength = kind == .highlight ? 2 : 1
                let start = "<\(tag)>".withCString { cmark_node_set_on_enter(node, $0) }
                let end = "</\(tag)>".withCString { cmark_node_set_on_exit(node, $0) }
                if start == 0 || end == 0 { cmark_node_free(node); valid = false; break }
                addText(renderedSource(NSRange(location: match.location + markerLength, length: match.length - 2 * markerLength)), parent: OpaquePointer(node))
                pieces.append(OpaquePointer(node))
                cursor = NSMaxRange(match)
            }
            if valid { addText(renderedSource(NSRange(location: cursor, length: NSMaxRange(range) - cursor))) }
            var inserted = 0
            if valid {
                for node in pieces {
                    guard cmark_node_insert_before(original, node) != 0 else { valid = false; break }
                    inserted += 1
                }
            }
            if valid { cmark_node_unlink(original); cmark_node_free(original) }
            else {
                for (index, node) in pieces.enumerated() {
                    if index < inserted { cmark_node_unlink(node) }
                    cmark_node_free(node)
                }
            }
        }
        for (original, range) in subscripts {
            if preserveRawHTML && insideRawText(range) { continue }
            guard let node = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { continue }
            guard let child = cmark_node_new(CMARK_NODE_TEXT) else { cmark_node_free(node); continue }
            let content = renderedSource(NSRange(location: range.location + 1, length: range.length - 2))
            let start = "<sub>".withCString { cmark_node_set_on_enter(node, $0) }
            let end = "</sub>".withCString { cmark_node_set_on_exit(node, $0) }
            let literal = content.withCString { cmark_node_set_literal(child, $0) }
            guard start != 0, end != 0, literal != 0, cmark_node_append_child(node, child) != 0 else {
                cmark_node_free(child); cmark_node_free(node); continue
            }
            guard cmark_node_replace(original, node) != 0 else { cmark_node_free(node); continue }
            cmark_node_free(original)
        }
        for original in (preserveRawHTML ? [] : tableBreaks) {
            guard let node = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { continue }
            let configured = "<br>".withCString { cmark_node_set_on_enter(node, $0) }
            guard configured != 0, cmark_node_replace(original, node) != 0 else { cmark_node_free(node); continue }
            cmark_node_free(original)
        }
        var styledRubyNodes = Set<OpaquePointer>()
        for index in acceptedRuby where rubyCandidates[index].proof.baseHTML != nil {
            var sibling: OpaquePointer? = rubyCandidates[index].proof.opening
            while let current = sibling {
                if Task.isCancelled { break }
                var pending = [current]
                while let node = pending.popLast() {
                    if Task.isCancelled { break }
                    styledRubyNodes.insert(node)
                    var child = cmark_node_first_child(node)
                    while let item = child { pending.append(item); child = cmark_node_next(item) }
                }
                if current == rubyCandidates[index].proof.closing { break }
                sibling = cmark_node_next(current)
            }
        }
        for pair in (preserveRawHTML ? [] : htmlPairs) {
            if Task.isCancelled { break }
            if styledRubyNodes.contains(pair.opening) || styledRubyNodes.contains(pair.closing) { continue }
            let opening = pair.opening, closing = pair.closing
            let tag: String
            switch pair.kind {
            case .strong: tag = "strong"
            case .emphasis: tag = "em"
            case .underline: tag = "u"
            case .keyboard: tag = "kbd"
            case .strikethrough: tag = "del"
            case .highlight: tag = "mark"
            case .subscriptText: tag = "sub"
            case .superscriptText: tag = "sup"
            case .link: tag = "a"
            case .inlineStyle: tag = "span"
            default: continue
            }
            guard let start = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { continue }
            guard let end = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { cmark_node_free(start); continue }
            var openingHTML = "<\(tag)>"
            if case .inlineStyle(let style) = pair.kind {
                openingHTML = "<span style=\"\(style.css)\">"
            }
            if tag == "a", var href = pair.href {
                if href.hasPrefix("#"), let fragment = String(href.dropFirst()).removingPercentEncoding,
                   let target = aliases[fragment] ?? namedAliases[Data(fragment.utf8)],
                   let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) { href = "#" + encoded }
                let escaped = href.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                openingHTML = "<a href=\"\(escaped)\">"
            }
            let startOK = openingHTML.withCString { cmark_node_set_on_enter(start, $0) }
            let endOK = "</\(tag)>".withCString { cmark_node_set_on_enter(end, $0) }
            guard startOK != 0, endOK != 0, cmark_node_replace(opening, start) != 0 else {
                cmark_node_free(start); cmark_node_free(end); continue
            }
            guard cmark_node_replace(closing, end) != 0 else {
                _ = cmark_node_replace(start, opening)
                cmark_node_free(start); cmark_node_free(end)
                continue
            }
            cmark_node_free(opening); cmark_node_free(closing)
        }
        for index in (preserveRawHTML ? [] : acceptedRuby.sorted()) {
            if Task.isCancelled { break }
            let candidate = rubyCandidates[index].proof
            if isFallbackDescendant(candidate.opening) { continue }
            if let baseHTML = candidate.baseHTML {
                var html = "<ruby>" + baseHTML
                if let before = candidate.before { html += "<rp>" + escaped(before) + "</rp>" }
                html += "<rt>" + escaped(candidate.reading) + "</rt>"
                if let after = candidate.after { html += "<rp>" + escaped(after) + "</rp>" }
                if let trailing = candidate.trailing { html += escaped(trailing) }
                html += "</ruby>"
                var nodes: [OpaquePointer] = [], current: OpaquePointer? = candidate.opening
                while let node = current {
                    if Task.isCancelled { break }
                    nodes.append(node)
                    if node == candidate.closing { break }
                    current = cmark_node_next(node)
                }
                guard !Task.isCancelled, nodes.last == candidate.closing,
                      let replacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { continue }
                guard html.withCString({ cmark_node_set_on_enter(replacement, $0) }) != 0,
                      cmark_node_insert_before(candidate.opening, replacement) != 0 else { cmark_node_free(replacement); continue }
                for node in nodes {
                    if Task.isCancelled { break }
                    cmark_node_unlink(node); detachedNodes.append(node)
                }
                continue
            }
            var node: OpaquePointer? = candidate.opening
            var replacements: [(OpaquePointer, OpaquePointer)] = [], reachedEnd = false, valid = true
            while let current = node {
                if Task.isCancelled { valid = false; break }
                if cmark_node_get_type(current) == CMARK_NODE_HTML_INLINE {
                    guard let literal = cmark_node_get_literal(current),
                          ["<ruby>", "</ruby>", "<rt>", "</rt>", "<rp>", "</rp>"].contains(String(cString: literal).lowercased()),
                          let replacement = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { valid = false; break }
                    let configured = String(cString: literal).lowercased().withCString { cmark_node_set_on_enter(replacement, $0) }
                    guard configured != 0 else { cmark_node_free(replacement); valid = false; break }
                    replacements.append((current, OpaquePointer(replacement)))
                }
                if current == candidate.closing { reachedEnd = true; break }
                node = cmark_node_next(current)
            }
            if !valid || !reachedEnd || Task.isCancelled {
                for (_, replacement) in replacements { cmark_node_free(replacement) }
                continue
            }
            var installed: [(OpaquePointer, OpaquePointer)] = []
            for (original, replacement) in replacements {
                if Task.isCancelled || cmark_node_replace(original, replacement) == 0 { break }
                installed.append((original, replacement))
            }
            if installed.count != replacements.count {
                for (original, replacement) in installed.reversed() { _ = cmark_node_replace(replacement, original) }
                for (_, replacement) in replacements { cmark_node_free(replacement) }
                continue
            }
            detachedNodes.append(contentsOf: replacements.map(\.0))
        }
        for (quote, marker, label) in alerts {
            // Класс берётся только из белого списка Parser.alert; произвольный текст в атрибут не попадает.
            let kind = label.lowercased()
            guard ["note", "tip", "important", "warning", "caution"].contains(kind) else { continue }
            guard let aside = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            guard let title = cmark_node_new(CMARK_NODE_CUSTOM_INLINE) else { cmark_node_free(aside); continue }
            let asideStart = "<aside class=\"lac-alert lac-alert-\(kind)\">".withCString { cmark_node_set_on_enter(aside, $0) }
            let asideEnd = "</aside>".withCString { cmark_node_set_on_exit(aside, $0) }
            let heading = "<strong>\(label)</strong>".withCString { cmark_node_set_on_enter(title, $0) }
            guard asideStart != 0, asideEnd != 0, heading != 0,
                  cmark_node_insert_before(quote, aside) != 0 else { cmark_node_free(aside); cmark_node_free(title); continue }
            cmark_node_unlink(quote)
            guard cmark_node_append_child(aside, quote) != 0 else {
                _ = cmark_node_insert_before(aside, quote)
                cmark_node_unlink(aside); cmark_node_free(aside); cmark_node_free(title)
                continue
            }
            guard cmark_node_replace(marker, title) != 0 else {
                cmark_node_unlink(quote)
                _ = cmark_node_insert_before(aside, quote)
                cmark_node_unlink(aside); cmark_node_free(aside); cmark_node_free(title)
                continue
            }
            cmark_node_free(marker)
        }
        let rows = headings.filter { installed.contains($0.id) }.map { heading -> String in
            let fragment = heading.id.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
            let number = headingNumbers[heading.node].map { "<span data-lac-heading-number=\"\(escaped($0))\"></span>" } ?? ""
            return "<li data-level=\"\(heading.level)\"><a href=\"#\(escaped(fragment))\">\(number)\(escaped(visibleHeadingTitles[heading.node] ?? heading.title))</a></li>"
        }
        if !rows.isEmpty {
            let html = "<nav aria-label=\"\(escaped(L10n.tr("文档大纲")))\" data-lac-toc><ul>" + rows.joined() + "</ul></nav>"
            for marker in markers {
                guard let node = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
                let configured = html.withCString { cmark_node_set_on_enter(node, $0) }
                guard configured != 0, cmark_node_replace(marker, node) != 0 else { cmark_node_free(node); continue }
                cmark_node_free(marker)
            }
        }
        return (installed, omittedNamedHTML, blockedRanges)
    }
}
