import Foundation

/// Узлы Obsidian и CriticMarkup (U3.3): правки `{++ ++}`, комментарии `%%`, wiki-ссылки, выноски, алерты и строчные встраивания.
/// Блочные встраивания `![[заметка]]` — в `+Embeds`. Адаптер ничего не переписывает: пишет HTML прямо по узлам модели.
extension MarkdownHTMLRenderer {
    /// Флаги разбора удобного входа и признак заметки хранилища (п. 2 плана U3.3).
    static func obsidianOptions(_ text: String, wiki: MarkdownWikiLinkContext?, critic: CriticMarkupRenderMode?,
                                embeds: (any MarkdownNoteEmbedProvider)?, documentURL: URL?,
                                hidesObsidianComments: Bool) -> (includes: MarkdownDocumentModel.Includes, isVaultNote: Bool) {
        var includes: MarkdownDocumentModel.Includes = []
        if wiki != nil, text.contains("[[") { includes.insert(.wikiLinks) }
        if wiki != nil || embeds != nil, MarkdownNoteEmbed.mayContainEmbed(text) { includes.insert(.noteEmbeds) }
        if critic != nil { includes.insert(.criticMarkup) }
        return (includes, hidesObsidianComments || MarkdownObsidianComment.appliesTo(documentURL: documentURL))
    }

    /// Провайдер встраиваний страницы: явный либо папка из wiki-контекста.
    static func embedProvider(_ w: Writer) -> (any MarkdownNoteEmbedProvider)? {
        w.embeds ?? w.wiki.map { MarkdownFolderNoteEmbedProvider(context: $0) }
    }

    /// Подготовка страницы (зовётся один раз из `renderPage` до вывода): запоминает настройки разбора для встраиваний
    /// и возвращает блоки без «молчащих» узлов: комментариев `%%` и правок CriticMarkup в режимах `.result` и `.original`.
    /// Правки принимаются или отклоняются здесь, поэтому соседние тексты склеивает обычный писатель (`writeInlines`),
    /// а абзац, в котором ничего не осталось, не выводится.
    static func prepareObsidian(_ model: MarkdownDocumentModel, _ w: Writer) -> [MarkdownBlockNode] {
        w.obsidian = ObsidianPageState(syntax: model.options.syntax, isVaultNote: model.options.isVaultNote, provider: embedProvider(w))
        let quiet = w.critic == .result || w.critic == .original
        guard quiet || model.options.isVaultNote || w.preserveWhitespace else { return model.blocks }
        return silencing(model.blocks, w, accept: w.critic == .result, quiet: quiet)
    }

    // MARK: - Пустой предпросмотр

    /// Есть ли в исходнике что-то кроме пробелов, комментариев `%%` и правок CriticMarkup (их вывод пуст, когда тело пустое).
    static func hasSourceBesideHidden(_ model: MarkdownDocumentModel, text: String) -> Bool {
        var ranges: [NSRange] = []
        func collect(_ nodes: [MarkdownInlineNode]) {
            for node in nodes {
                switch node.kind {
                case .comment, .critic: ranges.append(node.range)
                default: collect(node.children)
                }
            }
        }
        func collect(_ blocks: [MarkdownBlockNode]) {
            for block in blocks {
                if case .comment = block.kind { ranges.append(block.range); continue }
                collect(block.inlines)
                collect(block.children)
                if case .table(let table) = block.kind { for row in table.rows { for cell in row.cells { collect(cell.inlines) } } }
            }
        }
        collect(model.blocks)
        let source = NSMutableString(string: text)
        var end = 0
        var kept: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.location >= end && NSMaxRange(range) <= source.length {
            kept.append(range)
            end = NSMaxRange(range)
        }
        for range in kept.reversed() { source.deleteCharacters(in: range) }
        return !(source as String).allSatisfy(\.isWhitespace)
    }

    // MARK: - Молчащие узлы

    private static func silencing(_ blocks: [MarkdownBlockNode], _ w: Writer, accept: Bool, quiet: Bool) -> [MarkdownBlockNode] {
        var result: [MarkdownBlockNode] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            var node = block
            if !block.children.isEmpty { node.children = silencing(block.children, w, accept: accept, quiet: quiet) }
            if !block.inlines.isEmpty {
                node.inlines = silencing(block.inlines, w, accept: accept, quiet: quiet, edges: true)
                // Абзац, в котором после правок ничего не осталось, не выводится.
                if node.inlines.isEmpty, case .paragraph = block.kind { continue }
            }
            if case .table(var table) = block.kind {
                for row in table.rows.indices {
                    for cell in table.rows[row].cells.indices {
                        table.rows[row].cells[cell].inlines = silencing(table.rows[row].cells[cell].inlines, w, accept: accept, quiet: quiet, edges: true)
                    }
                }
                node.kind = .table(table)
            }
            result.append(node)
        }
        return result
    }

    private static func isBreak(_ node: MarkdownInlineNode) -> Bool {
        switch node.kind {
        case .softBreak, .hardBreak: return true
        default: return false
        }
    }

    /// `edges` — список строчных узлов блока целиком: пробелы у убранной правки на краю строки отбрасываются, как это делал cmark.
    private static func silencing(_ nodes: [MarkdownInlineNode], _ w: Writer, accept: Bool, quiet: Bool, edges: Bool = false) -> [MarkdownInlineNode] {
        var gaps: [Int] = []
        var result: [MarkdownInlineNode] = []
        result.reserveCapacity(nodes.count)
        var removedAtStart = false
        var removedLast = false
        for node in nodes {
            removedLast = false
            switch node.kind {
            case .comment:
                gaps.append(result.count)
                if result.isEmpty { removedAtStart = true }
                removedLast = true
            case .critic(let kind) where quiet:
                let kept = silencing(criticResolution(node, kind, accept: accept, w), w, accept: accept, quiet: quiet)
                if kept.isEmpty {
                    gaps.append(result.count)
                    if result.isEmpty { removedAtStart = true }
                    removedLast = true
                }
                result.append(contentsOf: kept)
            case .noteEmbed(let embed) where w.preserveWhitespace && embed.kind == .note:
                // Строчная заметка — срез исходника: при `preserveWhitespace` склеивается с соседним текстом.
                result.append(MarkdownInlineNode(kind: .text(w.slice(node.range)), range: node.range, markerRanges: [], children: [], isUnreliable: false))
            case .wikiLink(let link) where w.preserveWhitespace && unresolvedWiki(link, w):
                // Ненайденная wiki-ссылка — обычный текст: при `preserveWhitespace` он склеивается с соседним (как в старом рендере).
                let shown = w.slice(w.wiki == nil ? node.range : link.displayRange)
                result.append(MarkdownInlineNode(kind: .text(shown), range: node.range, markerRanges: [], children: [], isUnreliable: false))
            default:
                var copy = node
                if !node.children.isEmpty { copy.children = silencing(node.children, w, accept: accept, quiet: quiet) }
                result.append(copy)
            }
        }
        // Перенос строки рядом с убранной целиком правкой остаётся без текста по одну сторону: лишний перенос не нужен.
        if removedAtStart { while let first = result.first, isBreak(first) { result.removeFirst() } }
        if removedLast { while let tail = result.last, isBreak(tail) { result.removeLast() } }
        if edges && !gaps.isEmpty { trimEdges(&result, gaps: gaps) }
        return result
    }

    private static func unresolvedWiki(_ link: MarkdownInlineNode.WikiLink, _ w: Writer) -> Bool {
        w.wiki == nil || wikiHref(link, range: NSRange(location: 0, length: 0), w) == nil
    }

    /// Адрес wiki-ссылки с кэшем страницы (как `replacements` в `MarkdownWikiLinkRewriter`).
    private static func wikiHref(_ link: MarkdownInlineNode.WikiLink, range: NSRange, _ w: Writer) -> String? {
        guard let wiki = w.wiki else { return nil }
        let key = link.target + "#" + (link.heading ?? "")
        if let cached = w.obsidian.hrefs[key] { return cached }
        let href = wiki.relativeHref(for: MarkdownWikiLink(range: range, displayRange: link.displayRange, target: link.target,
                                                           heading: link.heading, alias: link.alias, markerRanges: []))
        w.obsidian.hrefs[key] = .some(href)
        return href
    }

    /// Пробелы на краю строки у места, где убрана правка: начало блока или строки (после переноса) и конец строки.
    private static func trimEdges(_ nodes: inout [MarkdownInlineNode], gaps: [Int]) {
        func trimmed(_ node: MarkdownInlineNode, leading: Bool) -> MarkdownInlineNode? {
            guard case .text(let string) = node.kind else { return node }
            var value = Substring(string)
            if leading { while let c = value.first, c == " " || c == "\t" { value.removeFirst() } }
            else { while let c = value.last, c == " " || c == "\t" { value.removeLast() } }
            if value.isEmpty { return nil }
            var copy = node
            copy.kind = .text(String(value))
            return copy
        }
        var removed: [Int] = []
        for gap in gaps {
            if gap < nodes.count, gap == 0 || isBreak(nodes[gap - 1]), let node = trimmed(nodes[gap], leading: true) { nodes[gap] = node }
            else if gap < nodes.count, gap == 0 || isBreak(nodes[gap - 1]), case .text = nodes[gap].kind { removed.append(gap) }
            if gap > 0, gap == nodes.count || isBreak(nodes[gap]), let node = trimmed(nodes[gap - 1], leading: false) { nodes[gap - 1] = node }
            else if gap > 0, gap == nodes.count || isBreak(nodes[gap]), case .text = nodes[gap - 1].kind { removed.append(gap - 1) }
        }
        for index in Set(removed).sorted(by: >) { nodes.remove(at: index) }
    }

    // MARK: - CriticMarkup

    /// Что остаётся от правки при принятии (`accept`) или отклонении: семантика `CriticMarkupService.resolution`.
    private static func criticResolution(_ node: MarkdownInlineNode, _ kind: CriticMarkupKind, accept: Bool, _ w: Writer) -> [MarkdownInlineNode] {
        switch kind {
        case .insertion: return accept ? node.children : []
        case .deletion: return accept ? [] : node.children
        case .comment: return []
        case .highlight: return node.children
        case .substitution:
            let parts = substitutionParts(node, w)
            return accept ? parts.after : parts.before
        }
    }

    /// Куски подмены: «было» и «стало». Правка, разрезанная по контейнерам, может не содержать `~>` — тогда сторону
    /// определяют разделители куска, а у среднего куска — положение относительно `~>` в исходнике.
    private static func substitutionParts(_ node: MarkdownInlineNode, _ w: Writer)
        -> (before: [MarkdownInlineNode], after: [MarkdownInlineNode], hasBefore: Bool, hasAfter: Bool) {
        if let separator = node.markerRanges.first(where: { w.slice($0) == "~>" }) {
            let before = node.children.filter { $0.range.location < separator.location }
            return (before, Array(node.children.dropFirst(before.count)), true, true)
        }
        let markers = node.markerRanges.map { w.slice($0) }
        if markers.contains("{~~") { return (node.children, [], true, false) }
        if markers.contains("~~}") { return ([], node.children, false, true) }
        let open = w.text.range(of: "{~~", options: [.backwards, .literal], range: NSRange(location: 0, length: min(node.range.location, w.text.length)))
        if open.location != NSNotFound {
            let from = NSMaxRange(open)
            let separator = w.text.range(of: "~>", options: .literal, range: NSRange(location: from, length: w.text.length - from))
            if separator.location != NSNotFound, node.range.location >= NSMaxRange(separator) { return ([], node.children, false, true) }
        }
        return (node.children, [], true, false)
    }

    private static func writeCritic(_ node: MarkdownInlineNode, _ kind: CriticMarkupKind, _ w: Writer) {
        guard let mode = w.critic else {
            // Режим правок выключен: узел модели выводится срезом исходника.
            writeText(w.slice(node.range), w)
            return
        }
        guard mode == .show else {
            writeInlines(criticResolution(node, kind, accept: mode == .result, w), w)
            return
        }
        func wrap(_ tag: CriticMarkupRender.Kind, _ children: [MarkdownInlineNode]) {
            w.put(tag.openTag)
            writeInlines(children, w)
            w.put(tag.closeTag)
        }
        switch kind {
        case .insertion: wrap(.ins, node.children)
        case .deletion: wrap(.del, node.children)
        case .highlight: wrap(.hl, node.children)
        case .substitution:
            let parts = substitutionParts(node, w)
            if parts.hasBefore { wrap(.del, parts.before) }
            if parts.hasAfter { wrap(.ins, parts.after) }
        case .comment:
            var raw = w.slice(node.range)
            if node.markerRanges.count >= 2, let open = node.markerRanges.first, let close = node.markerRanges.last, close.location >= NSMaxRange(open) {
                raw = w.slice(NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)))
            } else {
                if raw.hasPrefix("{>>") { raw.removeFirst(3) }
                if raw.hasSuffix("<<}") { raw.removeLast(3) }
            }
            let label = CriticMarkupRender.attributeEscaped(CriticMarkupRender.commentLabel(raw))
            w.put("<span class=\"critic-comment\" role=\"note\" tabindex=\"0\" aria-label=\"\(label)\" title=\"\(label)\">&#9998;</span>")
        }
    }

    // MARK: - Wiki-ссылки

    private static func writeWikiLink(_ node: MarkdownInlineNode, _ link: MarkdownInlineNode.WikiLink, _ w: Writer) {
        guard w.wiki != nil else {
            writeText(w.slice(node.range), w)
            return
        }
        if Task.isCancelled { return }
        let href = wikiHref(link, range: node.range, w)
        if let href { w.put("<a href=\"\(hrefValue(href))\">") }
        writeText(w.slice(link.displayRange), w)
        if href != nil { w.put("</a>") }
    }

    // MARK: - Встраивания вложений и картинок

    /// Картинка или вложение `![[файл]]` (строчное или в своём абзаце): картинка/ссылка на существующий файл либо подпись «недоступно».
    static func writeFileEmbed(range: NSRange, _ embed: MarkdownBlockNode.NoteEmbed, isBlock: Bool, _ w: Writer) {
        let name = (embed.target as NSString).lastPathComponent
        let address = w.documentURL ?? w.wiki?.documentURL
        guard let href = MarkdownNoteEmbed.existingFileHref(target: embed.target, documentURL: address, base: w.wiki?.resolver.base) else {
            w.put("<em>")
            writeText(L10n.tr("附件不可用：%@", name), w)
            w.put("</em>")
            return
        }
        func synthetic(_ kind: MarkdownInlineNode.Kind, children: [MarkdownInlineNode] = []) -> MarkdownInlineNode {
            MarkdownInlineNode(kind: kind, range: range, markerRanges: [], children: children, isUnreliable: false)
        }
        if embed.kind == .image {
            // Картинка в своём абзаце центрируется, как единственный элемент абзаца (`soleInline` для встраивания не задан).
            let centered = isBlock && w.resolveLocalImages
            if centered { w.put("<span data-lac-centered-image>") }
            writeInline(synthetic(.image(.init(url: href, alt: name, title: nil, syntax: .markdown, addressRange: nil, sizing: nil, isBlock: isBlock))), w)
            if centered { w.put("</span>") }
        } else {
            let label = synthetic(.text(name))
            writeInline(synthetic(.link(.init(url: href, title: nil, form: .inline, destinationRange: nil)), children: [label]), w)
        }
    }

    // MARK: - Блоки

    /// Блоки: `.callout`, `.alert`, `.noteEmbed`, `.comment`.
    static func writeObsidianBlock(_ node: MarkdownBlockNode, _ w: Writer) {
        switch node.kind {
        case .callout(let callout): writeCallout(node, callout, w)
        case .alert(let alert): writeAlert(node, alert, w)
        case .noteEmbed(let embed): writeNoteEmbedBlock(node, embed, w)
        case .comment: break
        case .paragraph, .heading, .quote, .list, .listItem, .codeBlock, .mathBlock, .table, .html, .tableOfContents,
             .footnoteDefinition, .frontMatter, .thematicBreak:
            assertionFailure("Блок не относится к U3.3")
        }
    }

    /// Вывод во временную строку: `cr` в начале пустой строки ничего не пишет, поэтому абзац не получает лишний перевод строки.
    static func capture(_ w: Writer, _ body: () -> Void) -> String {
        var saved = ""
        swap(&saved, &w.out)
        body()
        var captured = ""
        swap(&captured, &w.out)
        swap(&saved, &w.out)
        return captured
    }

    private static func trimmed(_ html: String) -> String { html.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Число переводов строки в исходнике между `from` и `to` (`\r\n` — один).
    private static func lineBreaks(_ w: Writer, from: Int, to: Int) -> Int {
        var count = 0
        var index = max(0, from)
        let end = min(to, w.text.length)
        while index < end {
            let unit = w.text.character(at: index)
            if unit == 13 {
                count += 1
                if index + 1 < end, w.text.character(at: index + 1) == 10 { index += 1 }
            } else if unit == 10 {
                count += 1
            }
            index += 1
        }
        return count
    }

    /// `<div|details class="lac-callout …">`: заголовок — `inlines`, тело — `children` (контракт R4).
    private static func writeCallout(_ node: MarkdownBlockNode, _ callout: MarkdownBlockNode.Callout, _ w: Writer) {
        let kind = callout.kind
        let visibleKind = kind ?? .note
        let label = kind?.label ?? MarkdownCalloutRender.capitalized(callout.type)
        let title = trimmed(capture(w) { writeInlines(node.inlines, w) })
        let plainTitle = MarkdownCalloutRender.plainText(ofHTML: title)
        let ariaLabel = plainTitle.isEmpty ? label : L10n.tr("标注标签 %@：%@", label, plainTitle)
        var classes = "lac-callout lac-callout-\(visibleKind.rawValue)"
        if kind == nil { classes += " lac-callout-custom" }
        let titleContent = "<span class=\"lac-callout-icon\" aria-hidden=\"true\">\(visibleKind.symbol)</span>"
            + "<span class=\"lac-callout-label\">\(label)</span>"
            + (title.isEmpty ? "" : "<span class=\"lac-callout-text\">\(title)</span>")
        w.cr()
        let closing: String
        if callout.fold == .none {
            w.put("<div class=\"\(classes)\" role=\"note\" aria-label=\"\(ariaLabel)\"\(w.sp(node))><div class=\"lac-callout-title\">\(titleContent)</div>")
            closing = "</div>"
        } else {
            let isOpen = callout.fold == .expanded || w.forExport
            w.put("<details class=\"\(classes)\"\(isOpen ? " open" : "") aria-label=\"\(ariaLabel)\"\(w.sp(node))>"
                + "<summary class=\"lac-callout-title\">\(titleContent)</summary>")
            closing = "</details>"
        }
        guard let first = node.children.first else {
            w.put("\n\(closing)\n")
            return
        }
        w.put("<div class=\"lac-callout-body\">")
        // Остаток абзаца с заголовком идёт сразу за открывающим тегом тела, любой другой блок — с новой строки.
        var rest = node.children[...]
        if case .paragraph = first.kind, isTitleRemainder(first, callout, w) {
            w.put(capture(w) { writeParagraph(first, w, tight: false) })
            rest = rest.dropFirst()
        } else {
            w.put("\n")
        }
        writeBlocks(Array(rest), w, tight: false)
        w.cr()
        w.put("</div>\(closing)\n")
    }

    /// Первый абзац тела выноски — остаток абзаца с заголовком (строка сразу под ним), а не отдельный абзац после пустой строки.
    private static func isTitleRemainder(_ paragraph: MarkdownBlockNode, _ callout: MarkdownBlockNode.Callout, _ w: Writer) -> Bool {
        let line = w.text.lineRange(for: NSRange(location: min(callout.markerRange.location, w.text.length), length: 0))
        var titleEnd = NSMaxRange(line)
        while titleEnd > line.location, [10, 13].contains(w.text.character(at: titleEnd - 1)) { titleEnd -= 1 }
        return lineBreaks(w, from: titleEnd, to: paragraph.range.location) == 1
    }

    /// `<aside class="lac-alert …">` вокруг цитаты; маркер `[!NOTE]` первого абзаца заменён на `<strong>NOTE</strong>`.
    private static func writeAlert(_ node: MarkdownBlockNode, _ alert: MarkdownBlockNode.Alert, _ w: Writer) {
        w.cr()
        w.put("<aside class=\"lac-alert lac-alert-\(alert.rawValue.lowercased())\">\n")
        w.put("<blockquote\(w.sp(node))>\n")
        var rest = node.children[...]
        if let first = rest.first, case .paragraph = first.kind, let marker = first.inlines.first, case .text = marker.kind {
            w.put("<p\(w.sp(first))><strong>\(alert.rawValue)</strong>")
            writeInlines(Array(first.inlines.dropFirst()), w)
            w.put("</p>\n")
            rest = rest.dropFirst()
        }
        writeBlocks(Array(rest), w, tight: false)
        w.cr()
        w.put("</blockquote>\n</aside>\n")
    }

    // MARK: - Строчные

    /// Строчные: `.wikiLink`, `.noteEmbed`, `.critic`, `.comment`.
    static func writeObsidianInline(_ node: MarkdownInlineNode, _ w: Writer) {
        switch node.kind {
        case .wikiLink(let link): writeWikiLink(node, link, w)
        case .noteEmbed(let embed):
            // Строчная заметка остаётся срезом исходника; картинка и вложение — как отдельный абзац, но без него.
            if embed.kind == .note { writeText(w.slice(node.range), w) } else { writeFileEmbed(range: node.range, embed, isBlock: false, w) }
        case .critic(let kind): writeCritic(node, kind, w)
        case .comment: break
        case .text, .code, .strong, .emphasis, .strikethrough, .underline, .keyboard, .highlight, .subscriptText, .superscriptText,
             .inlineStyle, .link, .image, .media, .iframe, .svg, .ruby, .formula, .footnoteReference, .emoji, .softBreak,
             .hardBreak, .rawHTML:
            assertionFailure("Узел не относится к U3.3")
        }
    }
}
