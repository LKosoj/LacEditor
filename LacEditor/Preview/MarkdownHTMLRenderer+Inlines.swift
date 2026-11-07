import Foundation

/// Строчные узлы HTML-адаптера (U3.1c): правила `html.c` и `extensions/strikethrough.c` cmark-gfm.
/// Текст (`writeText`) и картинка (`writeImage`) живут в `MarkdownHTMLRenderer.swift` (точки подключения U3.2).
extension MarkdownHTMLRenderer {
    /// `<code>` + экранированный литерал + `</code>`.
    static func writeInlineCode(_ literal: String, _ w: Writer) {
        w.put("<code>")
        w.put(escapeHTML(literal))
        w.put("</code>")
    }

    /// `<strong>` вокруг `node.children`; `strong` прямо внутри `strong` теги не пишет (у cmark `parent.type != STRONG`).
    /// Пара `<b>…</b>` выводится настоящими тегами (в экспорте HTML — маркерами сырого HTML).
    static func writeStrong(_ node: MarkdownInlineNode, _ w: Writer) {
        if node.hasHTMLTagMarker(in: w.text) {
            writeTagPair(node, open: "<strong>", close: "</strong>", w)
            return
        }
        w.put("<strong>")
        writeStrongChildren(node.children, w)
        w.put("</strong>")
    }

    /// Дети `strong`: вложенный `strong` раскрывается без тегов, остальное — как обычно.
    private static func writeStrongChildren(_ nodes: [MarkdownInlineNode], _ w: Writer) {
        for child in nodes {
            if case .strong = child.kind, !child.hasHTMLTagMarker(in: w.text) {
                writeStrongChildren(child.children, w)
            } else {
                writeInline(child, w)
            }
        }
    }

    static func writeEmphasis(_ node: MarkdownInlineNode, _ w: Writer) {
        writeTagPair(node, open: "<em>", close: "</em>", w)
    }

    /// `<del>`…`</del>`.
    static func writeStrikethrough(_ node: MarkdownInlineNode, _ w: Writer) {
        writeTagPair(node, open: "<del>", close: "</del>", w)
    }

    /// `w.hardBreaks` → `<br />\n`, иначе пробел.
    static func writeSoftBreak(_ w: Writer) {
        w.put(w.hardBreaks ? "<br />\n" : " ")
    }

    /// Всегда `<br />\n`.
    static func writeHardBreak(_ w: Writer) {
        w.put("<br />\n")
    }

    /// `<a href=… title=…>` + `node.children` + `</a>`; адрес через `hrefValue`.
    static func writeLink(_ node: MarkdownInlineNode, _ link: MarkdownInlineNode.Link, _ w: Writer) {
        if link.form == .html {
            w.put("<a href=\"\(escapeHTML(rewrittenAddress(link.url, w)))\">")
            writeInlines(node.children, w)
            w.put("</a>")
            return
        }
        w.put("<a href=\"\(hrefValue(rewrittenAddress(link.url, w)))")
        if let title = link.title, !title.isEmpty { w.put("\" title=\"\(escapeHTML(title))") }
        w.put("\">")
        writeInlines(node.children, w)
        w.put("</a>")
    }
}
