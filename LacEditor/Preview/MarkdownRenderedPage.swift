import Foundation
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

    mutating func resolveRemoteImages(session: URLSession? = nil) async throws {
        guard !remoteImageMarkers.isEmpty else { return }
        let matches = try remoteImageMatches()
        let original = body as NSString
        let addresses = matches.compactMap { remoteImageMarkers[original.substring(with: $0.range)] }
        let values = try await MarkdownRemoteImageDownloader(session: session).dataURIs(for: addresses)
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
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; media-src data:; frame-src 'none'; style-src 'unsafe-inline'">
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
      \(CriticMarkupPreviewStyle.css)
      \(MarkdownObsidianPreviewStyle.css)
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
