import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Keep the parsed body separate from the page shell. Ordinary edits replace
/// only article content; appearance changes reuse the same parsed Markdown.
struct MarkdownRenderedPage: Sendable {
    let body: String
    var darkMode: Bool

    var html: String {
        """
        <!doctype html>
        <html lang="\(L10n.languageCode)" data-theme="\(darkMode ? "dark" : "light")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>\(Self.styles)</style>
        </head>
        <body><article aria-label="\(L10n.tr("Markdown 预览"))">\(body)</article></body>
        </html>
        """
    }

    private static let styles = """
      :root {
        color-scheme: light;
        --page: #fbfbfb; --text: #303038; --secondary: #6d6d78;
        --border: #e2e2e8; --code: #f0f0f4; --accent: #5c61ba; --quote: #f4f4f8;
        background: var(--page);
      }
      :root[data-theme="dark"] {
        color-scheme: dark;
        --page: #1b1b1b; --text: #dddde3; --secondary: #acacb8;
        --border: #38383f; --code: #25252c; --accent: #a1a6f2; --quote: #222228;
      }
      * { box-sizing: border-box; }
      html { overflow-wrap: anywhere; }
      body {
        margin: 0; padding: 24px clamp(20px, 4vw, 28px) 64px;
        background: var(--page); color: var(--text);
        font: 15px/1.7 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
        -webkit-font-smoothing: antialiased;
      }
      article { max-width: 760px; min-width: 0; margin: 0 auto; }
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
        margin: 1.15em 0; padding: .65em 1em; color: var(--secondary);
        border-left: 3px solid var(--accent); background: var(--quote);
        border-radius: 0 5px 5px 0;
      }
      blockquote > :first-child { margin-top: 0; }
      blockquote > :last-child { margin-bottom: 0; }
      blockquote blockquote { margin: .6em 0; }
      hr { border: 0; border-top: 1px solid var(--border); margin: 1.8em 0; }
      a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 3px; }
      a:not(:hover) { text-decoration-color: transparent; }
      :focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 2px; }
      code { font: .88em/1.65 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: .15em .35em; border-radius: 4px; }
      pre {
        max-width: 100%; overflow: auto; overscroll-behavior-x: contain;
        margin: 1.1em 0; background: var(--code); border: 1px solid var(--border);
        padding: 14px 16px; border-radius: 7px; tab-size: 4;
      }
      pre code { background: none; padding: 0; border-radius: 0; overflow-wrap: normal; white-space: pre; }
      pre[hidden] { display: none; }
      .mermaid-diagram { max-width: 100%; overflow-x: auto; margin: 1.1em 0; }
      .mermaid-diagram svg { max-width: 100%; height: auto; }
      .table-scroll { max-width: 100%; overflow-x: auto; overscroll-behavior-x: contain; margin: 1.1em 0; }
      table { width: 100%; border-collapse: collapse; font-size: .93em; }
      th, td { border: 1px solid var(--border); padding: .55em .8em; text-align: left; min-width: 5em; }
      th { font-weight: 600; background: var(--code); }
      img { max-width: 100%; height: auto; }
      input[type="checkbox"] { margin: 0 .45em 0 0; accent-color: var(--accent); vertical-align: middle; }
      del { color: var(--secondary); }
      ::selection { background: #9296db55; }
      @media (prefers-contrast: more) {
        :root { --secondary: #4a4a55; --border: #92929c; }
        :root[data-theme="dark"] { --secondary: #d2d2dc; --border: #878792; }
        a { text-decoration-color: currentColor; }
      }
      @media (prefers-reduced-transparency: reduce) { body { background: var(--page); } }
      @media print { body { padding: 0; } article { max-width: none; } }
    """
}

enum MarkdownRenderer {
    private static let extensions = ["table", "strikethrough", "tasklist", "autolink", "tagfilter"]

    static func render(_ markdown: String, darkMode: Bool) -> String {
        renderPage(markdown, darkMode: darkMode).html
    }

    static func renderPage(_ markdown: String, darkMode: Bool) -> MarkdownRenderedPage {
        let body = renderBody(markdown)
            .replacingOccurrences(of: "<table>", with: "<div class=\"table-scroll\" role=\"region\" aria-label=\"\(L10n.tr("表格，可横向滚动"))\" tabindex=\"0\"><table>")
            .replacingOccurrences(of: "</table>", with: "</table></div>")
            .replacingOccurrences(of: "<pre>", with: "<pre tabindex=\"0\" aria-label=\"\(L10n.tr("代码块，可横向滚动"))\">")
        return MarkdownRenderedPage(body: body, darkMode: darkMode)
    }

    private static func renderBody(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        // Treat ordinary single newlines as visible line breaks in the preview.
        // This keeps blank-line paragraph separation intact while preventing
        // prose pasted from the editor from appearing as one wrapped line.
        let options = CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }

        for name in extensions {
            name.withCString { extensionName in
                guard let syntaxExtension = cmark_find_syntax_extension(extensionName) else {
                    return
                }
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        markdown.withCString { source in
            cmark_parser_feed(parser, source, markdown.utf8.count)
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }

        let syntaxExtensions = cmark_parser_get_syntax_extensions(parser)
        guard let rendered = cmark_render_html(document, options, syntaxExtensions) else {
            return ""
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }
}
