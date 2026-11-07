import Foundation
import SwiftSoup

/// Собственные узлы Markdown в HTML-адаптере (U3.2): подсветка и диаграммы, формулы, `[toc]`, эмодзи, строчные теги
/// (`<u>`, `<kbd>`, `==`, `^`, `~`, `<span style>`), ruby и пары `<b>/<i>/<s>`. Медиа, картинки и HTML-блоки — `+Media`.
extension MarkdownHTMLRenderer {
    /// Данные страницы, посчитанные до обхода: оглавление и псевдонимы ссылок на заголовки.
    struct SpecialState {
        struct TOCEntry {
            let level: Int
            let id: String
            let title: String
            let location: Int
            /// Эмодзи заголовка: значения словаря известны только после предпрохода, поэтому подстановка — при выводе.
            let emoji: [MarkdownHeading.Emoji]
        }
        var toc: [TOCEntry] = []
        /// `слаг` и `уникальная часть id` → `id` заголовка (`MarkdownHeadingAnchors.aliases`).
        var aliases: [String: String] = [:]
        /// Неподтверждённый строчный HTML (объединённые диапазоны) по началу диапазона: абзац с таким тегом выводится исходным текстом.
        var blocked: [Int: NSRange] = [:]
    }

    /// Предпроход: заголовки с `id`, псевдонимы и значения эмодзи (одним запросом к словарю).
    static func prepareSpecial(_ model: MarkdownDocumentModel, _ w: Writer) {
        var entries: [MarkdownHeadingAnchors.Entry] = []
        var names: [String] = []
        var seen = Set<String>()
        func collect(_ nodes: [MarkdownInlineNode]) {
            for node in nodes {
                if case .emoji(let name) = node.kind, seen.insert(name).inserted { names.append(name) }
                if !node.children.isEmpty { collect(node.children) }
            }
        }
        func visit(_ blocks: [MarkdownBlockNode]) {
            for node in blocks {
                if case .heading(let heading) = node.kind, !heading.id.isEmpty {
                    w.special.toc.append(.init(level: heading.level, id: heading.id, title: heading.title, location: node.range.location, emoji: heading.emoji))
                    entries.append(.init(slug: heading.slug, id: heading.id))
                }
                if w.renderEmoji {
                    collect(node.inlines)
                    if case .table(let table) = node.kind {
                        for row in table.rows { for cell in row.cells { collect(cell.inlines) } }
                    }
                }
                visit(node.children)
            }
        }
        visit(model.blocks)
        if !w.preserveRawHTMLBlocks {
            var merged: [NSRange] = []
            for range in model.blockedHTML.sorted(by: { $0.location < $1.location }) {
                if let last = merged.last, range.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, range) } else { merged.append(range) }
            }
            for range in merged { w.special.blocked[range.location] = range }
        }
        w.special.aliases = MarkdownHeadingAnchors.aliases(entries)
        if !names.isEmpty, !Task.isCancelled {
            w.emojiValues = (try? EmojiShortcodeResolver.resolve(names, isCancelled: { Task.isCancelled })) ?? [:]
        }
    }

    /// `#фрагмент` → `#id` заголовка (если фрагмент — слаг или уникальная часть id); остальные адреса не меняются.
    static func rewrittenAddress(_ url: String, _ w: Writer) -> String {
        guard url.hasPrefix("#"), let fragment = String(url.dropFirst()).removingPercentEncoding,
              let target = w.special.aliases[fragment] ?? w.media.namedAnchorTargets[Data(fragment.utf8)],
              let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return url }
        return "#" + encoded
    }

    // MARK: - Абзац с неподдержанным тегом

    /// Абзац (ячейка) с неподдержанным `<span style>` или `<ruby>` выводится исходным текстом: тег стоит в начале
    /// неподтверждённого диапазона HTML, который целиком лежит в абзаце.
    static func hasUnsupportedInlineTag(_ nodes: [MarkdownInlineNode], within limit: NSRange, _ w: Writer) -> Bool {
        if w.special.blocked.isEmpty { return false }
        for node in nodes {
            if case .rawHTML(let tag) = node.kind, let blocked = w.special.blocked[node.range.location], NSMaxRange(blocked) <= NSMaxRange(limit) {
                let lowered = tag.lowercased()
                let isRuby = lowered.hasPrefix("<ruby") && (lowered.count == 5 || " >/\t\n".contains(lowered[lowered.index(lowered.startIndex, offsetBy: 5)]))
                if isRuby || (MarkdownHTMLMediaService.hasStyledSpan(in: tag, isCancelled: { Task.isCancelled }) &&
                              MarkdownHTMLMediaService.inlineStyleOpening(tag, isCancelled: { Task.isCancelled }) == nil) { return true }
            }
            if hasUnsupportedInlineTag(node.children, within: limit, w) { return true }
        }
        return false
    }

    // MARK: - Блоки

    /// Диаграмма (`flow`, `sequence`), подсвеченный код или обычный `<pre>`.
    static func writeCodeBlock(_ node: MarkdownBlockNode, _ code: MarkdownBlockNode.CodeBlock, _ w: Writer) {
        if let kind = code.diagram, kind != .mermaid {
            let item = MarkdownRenderedDiagram(kind: kind, source: code.literal)
            w.cr()
            w.put("<pre data-lac-diagram=\"\(w.diagrams.count)\"\(w.sp(node))>\(escapeHTML(item.source))</pre>")
            w.cr()
            w.diagrams.append(item)
            return
        }
        if w.highlightCode, let language = MarkdownCodeHighlightService.language(for: code.info),
           let inner = highlightedCodeHTML(code.literal, language: language) {
            // Как в cmark: класс языка — до первого пробела информационной строки.
            let first = String(code.info.prefix { !" \t\r\n".contains($0) })
            w.cr()
            w.put("<pre tabindex=\"0\" aria-label=\"\(L10n.tr("代码块，可横向滚动"))\"\(w.sp(node))><code class=\"language-\(escapeHTML(first))\">\(inner)</code></pre>\n")
            return
        }
        writePlainCodeBlock(node, code, w)
    }

    /// `$$…$$`: подставка `<div data-lac-math>`; формулу рисует страница.
    static func writeMathBlock(_ source: String, _ w: Writer) {
        let item = MarkdownRenderedMath(source: source, display: true)
        w.cr()
        w.put("<div data-lac-math=\"\(w.formulas.count)\">\(escapeHTML("$$\n" + source + "$$"))</div>")
        w.cr()
        w.formulas.append(item)
    }

    /// Видимый заголовок с подставленными эмодзи (как в самом заголовке на странице): `:имя:` → символ из словаря.
    /// Диапазоны эмодзи отсчитываются от начала `title`.
    private static func emojiTitle(_ entry: SpecialState.TOCEntry, _ w: Writer) -> String {
        guard w.renderEmoji, !entry.emoji.isEmpty else { return entry.title }
        let result = NSMutableString(string: entry.title)
        for emoji in entry.emoji.sorted(by: { $0.range.location > $1.range.location }) {
            guard let value = w.emojiValues[emoji.name], NSMaxRange(emoji.range) <= result.length else { continue }
            result.replaceCharacters(in: emoji.range, with: value)
        }
        return result as String
    }

    /// `[toc]` → оглавление; без заголовков с `id` остаётся абзацем с исходным текстом.
    static func writeTableOfContents(_ node: MarkdownBlockNode, _ w: Writer) {
        guard !w.special.toc.isEmpty else {
            w.cr()
            w.put("<p\(w.sp(node))>")
            writeText(w.slice(node.range), w)
            w.put("</p>\n")
            return
        }
        w.cr()
        w.put("<nav aria-label=\"\(escapeHTML(L10n.tr("文档大纲")))\" data-lac-toc><ul>")
        for entry in w.special.toc {
            let fragment = entry.id.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
            w.put("<li data-level=\"\(entry.level)\"><a href=\"#\(escapeHTML(fragment))\">")
            if let number = w.headingNumbers[entry.location] { w.put("<span data-lac-heading-number=\"\(escapeHTML(number))\"></span>") }
            w.put("\(escapeHTML(emojiTitle(entry, w)))</a></li>")
        }
        w.put("</ul></nav>")
        w.cr()
    }

    // MARK: - Строчные узлы

    /// Текст эмодзи: символ из словаря либо исходное `:имя:`.
    static func emojiText(_ node: MarkdownInlineNode, _ w: Writer) -> String {
        if case .emoji(let name) = node.kind, let value = w.emojiValues[name] { return value }
        return w.slice(node.range)
    }

    /// Пара тегов с открывающим и закрывающим маркерами. При `preserveRawHTMLBlocks` теги остаются сырым HTML (маркерами `LACRAW`).
    static func writeTagPair(_ node: MarkdownInlineNode, open: String, close: String, _ w: Writer) {
        if w.preserveRawHTMLBlocks, node.hasHTMLTagMarker(in: w.text), node.markerRanges.count >= 2 {
            w.put(rawMarker(w.slice(node.markerRanges[0]), w))
            writeInlines(node.children, w)
            w.put(rawMarker(w.slice(node.markerRanges[node.markerRanges.count - 1]), w))
            return
        }
        w.put(open)
        writeInlines(node.children, w)
        w.put(close)
    }

    static func writeSpecialInline(_ node: MarkdownInlineNode, _ w: Writer) {
        switch node.kind {
        case .underline: writeTagPair(node, open: "<u>", close: "</u>", w)
        case .keyboard:
            // В ячейке таблицы предпросмотр оформляет из HTML-пар только `<span style>`, теги `<kbd>` пропускаются (как в старом рендере).
            if w.media.inTableCell, !w.includeHTMLMedia, node.hasHTMLTagMarker(in: w.text) {
                w.put(omittedHTMLComment)
                writeInlines(node.children, w)
                w.put(omittedHTMLComment)
            } else { writeTagPair(node, open: "<kbd>", close: "</kbd>", w) }
        case .highlight: writeTagPair(node, open: "<mark>", close: "</mark>", w)
        case .subscriptText: writeTagPair(node, open: "<sub>", close: "</sub>", w)
        case .superscriptText: writeTagPair(node, open: "<sup>", close: "</sup>", w)
        case .inlineStyle(let style): writeTagPair(node, open: "<span style=\"\(style.css)\">", close: "</span>", w)
        case .emoji: writeText(emojiText(node, w), w)
        case .formula(let source):
            let item = MarkdownRenderedMath(source: source, display: false)
            w.put("<span data-lac-math=\"\(w.formulas.count)\">\(escapeHTML("$" + source + "$"))</span>")
            w.formulas.append(item)
        case .ruby(let ruby): writeRuby(node, ruby, w)
        default: assertionFailure("Узел не относится к специальным")
        }
    }

    /// Ruby: без `preserveRawHTMLBlocks` HTML собирается из разобранных полей, текст экранируется один раз.
    /// При `preserveRawHTMLBlocks` каждый тег — маркер, текст между тегами декодируется из исходника.
    static func writeRuby(_ node: MarkdownInlineNode, _ ruby: MarkdownInlineNode.Ruby, _ w: Writer) {
        if !w.preserveRawHTMLBlocks {
            var html = "<ruby>" + (ruby.baseHTML.map(normalizedSpanStyles) ?? escapeHTML(ruby.base))
            if let before = ruby.openingParenthesis { html += "<rp>" + escapeHTML(before) + "</rp>" }
            html += "<rt>" + escapeHTML(ruby.reading) + "</rt>"
            if let after = ruby.closingParenthesis { html += "<rp>" + escapeHTML(after) + "</rp>" }
            if let trailing = ruby.trailing { html += escapeHTML(trailing) }
            w.put(html + "</ruby>")
            return
        }
        let source = w.slice(node.range) as NSString
        var cursor = 0
        while cursor < source.length {
            let open = source.range(of: "<", options: [], range: NSRange(location: cursor, length: source.length - cursor))
            guard open.location != NSNotFound else { break }
            let close = source.range(of: ">", options: [], range: NSRange(location: open.location, length: source.length - open.location))
            guard close.location != NSNotFound else { break }
            if open.location > cursor { writeText(decodedEntities(source.substring(with: NSRange(location: cursor, length: open.location - cursor))), w) }
            w.put(rawMarker(source.substring(with: NSRange(location: open.location, length: NSMaxRange(close) - open.location)), w))
            cursor = NSMaxRange(close)
        }
        if cursor < source.length { writeText(decodedEntities(source.substring(from: cursor)), w) }
    }

    /// `<span style="…">` в оформленном основании: стиль записывается нормализованным (`style.css`), как у обычного `<span>`.
    private static func normalizedSpanStyles(_ html: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "<span\\b[^>]*>", options: [.caseInsensitive]) else { return html }
        let source = html as NSString
        let result = NSMutableString(string: html)
        for match in expression.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let tag = source.substring(with: match.range)
            guard let style = MarkdownHTMLMediaService.inlineStyleOpening(tag, isCancelled: { Task.isCancelled }) else { continue }
            result.replaceCharacters(in: match.range, with: "<span style=\"" + style.css + "\">")
        }
        return result as String
    }

    /// Все HTML-сущности (`&nbsp;`, `&copy;`, `&#12354;`, `&#x3042;`) в текст, как у cmark.
    private static func decodedEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        return (try? Entities.unescape(string: string, strict: true)) ?? string
    }

    /// Подсветка кода блока: токены → `<span class="tok-…">`.
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

    static func highlightedCodeHTML(_ literal: String, language: EditorLanguage) -> String? {
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
            let piece = escapeHTML(text.substring(with: NSRange(location: start, length: end - start)))
            html += kinds[start] == 0 ? piece : "<span class=\"\(tokenClassName(kinds[start]))\">\(piece)</span>"
            start = end
        }
        highlightCache.setObject(html as NSString, forKey: key, cost: key.length + html.utf16.count)
        return html
    }
}
