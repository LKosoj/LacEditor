import Foundation

/// Блоки HTML-адаптера (U3.1b): правила `html.c` и `extensions/{table,tasklist}.c` cmark-gfm, сноски — `blocks.c: process_footnotes`.
extension MarkdownHTMLRenderer {
    /// Состояние сносок страницы: определения, ссылки и номера, посчитанные предпроходом `prepareFootnotes`.
    struct FootnoteState {
        struct Definition {
            var node: MarkdownBlockNode
            /// Метка как написана (идёт в `id`/`href` через `escapeHref`).
            var label: String
            /// Номер по первой ссылке; 0 — на определение никто не ссылается, оно не выводится.
            var ix = 0
            /// Сколько раз на определение сослались (`def_count` cmark).
            var refCount = 0
        }
        struct Reference {
            var definition: Int
            /// Номер ссылки среди ссылок на это определение (`ref_ix` cmark).
            var refIx: Int
        }
        var definitions: [Definition] = []
        /// Ссылки по `range.location` узла.
        var references: [Int: Reference] = [:]
        /// Выводится тело определения: там метка отмеченной задачи не ставится (как в старом рендере).
        var inDefinition = false
        /// Обратная ссылка ждёт последний абзац определения (`range` абзаца) либо конец определения.
        var backrefRange: NSRange?
        var backrefHTML = ""
    }

    /// `tight` — абзац лежит в пункте плотного списка: только инлайны, без `<p>`.
    static func writeParagraph(_ node: MarkdownBlockNode, _ w: Writer, tight: Bool) {
        // Абзац из одного неподдержанного тега: исходный текст в `<pre>`; из одного SVG — картинка без `<p>`.
        if hasUnsupportedInlineTag(node.inlines, within: node.range, w) {
            // В экспорте HTML теги абзаца выводятся текстом, а не HTML.
            if w.includeHTMLMedia { w.media.omittedHTML = true }
            w.cr()
            w.put("<pre tabindex=\"0\" aria-label=\"\(L10n.tr("代码块，可横向滚动"))\">\(escapeHTML(rawBlockText(node, w)))</pre>")
            w.cr()
            return
        }
        if node.inlines.count == 1, case .svg(let data) = node.inlines[0].kind {
            putCustomBlock(addingSourcePosition(svgImageHTML(data), node.range, w), w)
            return
        }
        w.media.soleInline = node.inlines.count == 1 ? node.inlines[0].range : nil
        if tight {
            writeInlines(node.inlines, w)
            return
        }
        w.cr()
        w.put("<p\(w.sp(node))>")
        writeInlines(node.inlines, w)
        if let range = w.footnotes.backrefRange, range == node.range {
            w.put(" " + w.footnotes.backrefHTML)
            w.footnotes.backrefRange = nil
            w.footnotes.backrefHTML = ""
        }
        w.put("</p>\n")
    }

    /// `cr`, `<span id>` при непустом `id`, `<hN sp>`, номер (`w.headingNumber(for:)`), инлайны.
    static func writeHeading(_ node: MarkdownBlockNode, _ heading: MarkdownBlockNode.Heading, _ w: Writer) {
        w.cr()
        if !heading.id.isEmpty {
            w.put("<span id=\"\(escapeHTML(heading.id))\"></span>")
            w.cr()
        }
        let level = min(6, max(1, heading.level))
        w.put("<h\(level)\(w.sp(node))>")
        if let number = w.headingNumber(for: node) {
            w.put("<span data-lac-heading-number=\"\(escapeHTML(number))\"></span>")
        }
        writeInlines(node.inlines, w)
        w.put("</h\(level)>\n")
    }

    static func writeQuote(_ node: MarkdownBlockNode, _ w: Writer) {
        w.cr()
        w.put("<blockquote\(w.sp(node))>\n")
        writeBlocks(node.children, w, tight: false)
        w.cr()
        w.put("</blockquote>\n")
    }

    /// Сам обходит `node.children` (пункты), передаёт им `list`.
    static func writeList(_ node: MarkdownBlockNode, _ list: MarkdownBlockNode.ListBlock, _ w: Writer) {
        w.cr()
        let tag: String
        switch list.marker {
        case .bullet:
            tag = "ul"
            w.put("<ul\(w.sp(node))>\n")
        case .ordered(let start, _):
            tag = "ol"
            w.put(start == 1 ? "<ol\(w.sp(node))>\n" : "<ol start=\"\(start)\"\(w.sp(node))>\n")
        }
        for child in node.children {
            if Task.isCancelled { return }
            if case .listItem(let item) = child.kind {
                writeListItem(child, item, w, list: list)
            } else {
                writeBlock(child, w, tight: list.isTight)
            }
        }
        w.put("</\(tag)>\n")
    }

    /// `list == nil` — пункт вне списка (не бывает в модели): как пункт свободного маркированного списка без метки стиля.
    static func writeListItem(_ node: MarkdownBlockNode, _ item: MarkdownBlockNode.ListItem, _ w: Writer,
                              list: MarkdownBlockNode.ListBlock?) {
        w.cr()
        w.put("<li\(w.sp(node))>")
        if let task = item.task {
            let checked = task.state == 120 || task.state == 88
            w.put(checked ? "<input type=\"checkbox\" checked=\"\" disabled=\"\" /> " : "<input type=\"checkbox\" disabled=\"\" /> ")
            if checked, !w.footnotes.inDefinition {
                w.cr()
                w.put("<span data-lac-checked-task></span>")
                w.cr()
            }
        } else if w.includeListStyles, let list {
            let kind: String
            if case .ordered = list.marker { kind = "ordered" } else { kind = "unordered" }
            w.cr()
            w.put("<span hidden data-lac-list-depth=\"\(list.depth)\" data-lac-list-kind=\"\(kind)\"></span>")
            w.cr()
            w.listDepths.insert(list.depth)
        }
        writeBlocks(node.children, w, tight: list?.isTight ?? false)
        w.put("</li>\n")
    }

    /// Обычный `<pre tabindex aria-label sp><code …>`; U3.2 зовёт его из `writeCodeBlock`, если не диаграмма и не подсветка.
    static func writePlainCodeBlock(_ node: MarkdownBlockNode, _ code: MarkdownBlockNode.CodeBlock, _ w: Writer) {
        w.cr()
        w.put("<pre tabindex=\"0\" aria-label=\"\(L10n.tr("代码块，可横向滚动"))\"\(w.sp(node))><code")
        if !code.info.isEmpty {
            // Язык — info до первого пробельного символа (`cmark_isspace`).
            let scalars = code.info.unicodeScalars
            let end = scalars.firstIndex { [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"].contains($0) } ?? scalars.endIndex
            w.put(" class=\"language-\(escapeHTML(String(scalars[scalars.startIndex..<end])))\"")
        }
        w.put(">\(escapeHTML(code.literal))</code></pre>\n")
    }

    static func writeTable(_ node: MarkdownBlockNode, _ table: MarkdownBlockNode.Table, _ w: Writer) {
        w.cr()
        w.put("<div class=\"table-scroll\" role=\"region\" aria-label=\"\(L10n.tr("表格，可横向滚动"))\" tabindex=\"0\">")
        w.put("<table\(w.sp(node))>")
        var needsClosingBody = false
        for row in table.rows {
            if Task.isCancelled { return }
            w.cr()
            if row.isHeader {
                w.put("<thead>")
                w.cr()
            } else if !needsClosingBody {
                w.put("<tbody>")
                w.cr()
                needsClosingBody = true
            }
            w.put("<tr\(w.sp(row.range))>")
            for cell in row.cells {
                // Нулевой colspan/rowspan — ячейка-заполнитель, cmark её не выводит.
                guard cell.colspan > 0, cell.rowspan > 0 else { continue }
                w.cr()
                w.put(row.isHeader ? "<th" : "<td")
                // Ячейки, которыми cmark добирает короткую строку до числа столбцов, не имеют данных ячейки: выравнивания у них нет.
                let isPadding = cell.isPadding
                if !isPadding, cell.column >= 0, cell.column < table.alignments.count {
                    switch table.alignments[cell.column] {
                    case .left: w.put(" align=\"left\"")
                    case .center: w.put(" align=\"center\"")
                    case .right: w.put(" align=\"right\"")
                    case .unspecified: break
                    }
                }
                if cell.colspan > 1 { w.put(" colspan=\"\(cell.colspan)\"") }
                if cell.rowspan > 1 { w.put(" rowspan=\"\(cell.rowspan)\"") }
                w.put("\(w.sp(cell.contentRange))>")
                if hasUnsupportedInlineTag(cell.inlines, within: cell.contentRange, w) {
                    writeText(w.slice(cell.contentRange), w)
                    w.put(row.isHeader ? "</th>" : "</td>")
                    continue
                }
                for child in cell.inlines { if case .rawHTML = child.kind { w.media.cellBreaks.insert(child.range.location) } }
                w.media.inTableCell = true
                writeInlines(cell.inlines, w)
                w.media.inTableCell = false
                w.put(row.isHeader ? "</th>" : "</td>")
            }
            w.cr()
            w.put("</tr>")
            if row.isHeader {
                w.cr()
                w.put("</thead>")
            }
        }
        if needsClosingBody {
            w.cr()
            w.put("</tbody>")
            w.cr()
        }
        w.cr()
        w.put("</table></div>")
        w.cr()
    }

    static func writeThematicBreak(_ node: MarkdownBlockNode, _ w: Writer) {
        w.cr()
        w.put("<hr\(w.sp(node)) />\n")
    }

    // MARK: - Сноски

    /// Ключ сопоставления метки (`normalize_map_label`): обрезка, склейка пробелов, свёртка регистра.
    static func footnoteKey(_ label: String) -> String {
        let words = label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return words.folding(options: [.caseInsensitive], locale: nil).lowercased()
    }

    /// Предпроход по модели: заполняет `w.footnotes` (п. 2.6 плана). Зовётся один раз до вывода.
    /// Определения могут лежать где угодно (модель держит их на своих местах), ссылки нумеруются по порядку обхода документа.
    static func prepareFootnotes(_ blocks: [MarkdownBlockNode], _ w: Writer) {
        var definitions: [FootnoteState.Definition] = []
        var byKey: [String: Int] = [:]
        func collect(_ nodes: [MarkdownBlockNode]) {
            for node in nodes {
                if case .footnoteDefinition(let label) = node.kind {
                    let key = footnoteKey(label)
                    // Пустая метка — не определение; при повторе берётся первое.
                    if !key.isEmpty, byKey[key] == nil {
                        byKey[key] = definitions.count
                        definitions.append(FootnoteState.Definition(node: node, label: label))
                    }
                }
                collect(node.children)
            }
        }
        collect(blocks)
        guard !definitions.isEmpty else { return }
        var next = 0
        var references: [Int: FootnoteState.Reference] = [:]
        func visitInlines(_ nodes: [MarkdownInlineNode]) {
            for node in nodes {
                if case .footnoteReference(let label) = node.kind {
                    // Метка узла — настоящая (метка определения, а не номер cmark).
                    if let index = byKey[footnoteKey(label)] {
                        if definitions[index].ix == 0 {
                            next += 1
                            definitions[index].ix = next
                        }
                        definitions[index].refCount += 1
                        references[node.range.location] = .init(definition: index, refIx: definitions[index].refCount)
                    }
                }
                visitInlines(node.children)
            }
        }
        func visit(_ nodes: [MarkdownBlockNode]) {
            for node in nodes {
                visitInlines(node.inlines)
                if case .table(let table) = node.kind {
                    for row in table.rows { for cell in row.cells { visitInlines(cell.inlines) } }
                }
                visit(node.children)
            }
        }
        visit(blocks)
        w.footnotes.definitions = definitions
        w.footnotes.references = references
    }

    /// `<sup class="footnote-ref">…` либо текст `[^метка]`, если определения нет.
    static func writeFootnoteReference(_ node: MarkdownInlineNode, label: String, _ w: Writer) {
        guard let reference = w.footnotes.references[node.range.location] else {
            writeText(w.slice(node.range), w)
            return
        }
        let definition = w.footnotes.definitions[reference.definition]
        let id = escapeHref(definition.label)
        w.put("<sup class=\"footnote-ref\"><a href=\"#fn-\(id)\" id=\"fnref-\(id)")
        if reference.refIx > 1 { w.put("-\(reference.refIx)") }
        w.put("\" data-footnote-ref>\(definition.ix)</a></sup>")
    }

    /// Обратные ссылки определения (`S_put_footnote_backref`).
    private static func footnoteBackref(_ definition: FootnoteState.Definition) -> String {
        let id = escapeHref(definition.label)
        let m = definition.ix
        var html = "<a href=\"#fnref-\(id)\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"\(m)\" aria-label=\"Back to reference \(m)\">↩</a>"
        if definition.refCount > 1 {
            for n in 2...definition.refCount {
                html += " <a href=\"#fnref-\(id)-\(n)\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"\(m)-\(n)\" aria-label=\"Back to reference \(m)-\(n)\">↩<sup class=\"footnote-ref\">\(n)</sup></a>"
            }
        }
        return html
    }

    /// Раздел `<section class="footnotes">` в конце страницы; ничего, если ссылок на определения нет. Зовётся один раз после блоков.
    static func writeFootnoteSection(_ w: Writer) {
        let used = w.footnotes.definitions.filter { $0.ix > 0 }.sorted { $0.ix < $1.ix }
        guard !used.isEmpty else { return }
        w.put("<section class=\"footnotes\" data-footnotes>\n<ol>\n")
        for definition in used {
            if Task.isCancelled { return }
            w.put("<li id=\"fn-\(escapeHref(definition.label))\">\n")
            // Вложенные определения cmark выносит в конец документа, здесь их нет.
            let children = definition.node.children.filter { if case .footnoteDefinition = $0.kind { return false } else { return true } }
            w.footnotes.backrefHTML = footnoteBackref(definition)
            w.footnotes.backrefRange = nil
            if let last = children.last, case .paragraph = last.kind { w.footnotes.backrefRange = last.range }
            w.footnotes.inDefinition = true
            writeBlocks(children, w, tight: false)
            w.footnotes.inDefinition = false
            // Последний ребёнок — не абзац: ссылка после детей и перевода строки.
            if !w.footnotes.backrefHTML.isEmpty {
                w.put(w.footnotes.backrefHTML + "\n")
            }
            w.footnotes.backrefRange = nil
            w.footnotes.backrefHTML = ""
            w.put("</li>\n")
        }
        w.put("</ol>\n</section>\n")
    }
}
