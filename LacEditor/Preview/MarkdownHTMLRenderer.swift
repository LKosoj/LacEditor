import Foundation

/// HTML-адаптер единой модели (U3.1): обходит `MarkdownDocumentModel` и пишет HTML теми же правилами, что `html.c` cmark-gfm.
/// Здесь — вход, писатель `Writer`, экранирование, `data-sourcepos`, пустой экран и общий `switch` по видам узлов.
/// Блоки и сноски — `+Blocks`, строчные узлы — `+Inlines`; медиа и спец-узлы — `+Media` (U3.2), Obsidian и CriticMarkup — `+Obsidian` (U3.3).
enum MarkdownHTMLRenderer {
    /// Писатель страницы: строка вывода и общие данные одного вызова.
    final class Writer {
        /// Исходный текст: срезы по `range` для узлов, чей вид ещё не выводится особо.
        let text: NSString
        let darkMode: Bool
        let forExport: Bool
        let isPreview: Bool
        let includeHeadingNumbers: Bool
        let includeListStyles: Bool
        /// `data-sourcepos` пишется только предпросмотру (`includeSourcePositions && !forExport`).
        let sourcePositions: Bool
        /// `HARDBREAKS` (перенос строки → `<br />`) или `NOBREAKS` (пробел).
        let hardBreaks: Bool
        let preserveWhitespace: Bool
        /// Параметры медиа и спец-блоков (U3.2).
        let includeHTMLMedia: Bool
        let renderEmoji: Bool
        let resolveLocalImages: Bool
        let documentURL: URL?
        let prepareRemoteImages: Bool
        let staticWidgetFallback: Bool
        let preserveRawHTMLBlocks: Bool
        let highlightCode: Bool
        /// Параметры Obsidian и CriticMarkup (U3.3); `nil` — узлы выводятся срезом исходника.
        let wiki: MarkdownWikiLinkContext?
        let critic: CriticMarkupRenderMode?
        let embeds: (any MarkdownNoteEmbedProvider)?
        var out = ""
        /// Глубины списков, для которых выведены метки стиля (`MarkdownRenderedPage.listDepths`).
        var listDepths: Set<Int> = []
        /// Номер заголовка («1.2. ») по `range.location` заголовка; пуст без `includeHeadingNumbers`.
        var headingNumbers: [Int: String] = [:]
        /// Состояние сносок страницы (предпроход U3.1b).
        var footnotes = FootnoteState()
        /// Состояние встраиваний и настройки разбора для вложенных заметок (U3.3, `prepareObsidian`).
        var obsidian = ObsidianPageState()
        /// Формулы и диаграммы страницы: номер в `data-lac-math`/`data-lac-diagram` — индекс в массиве.
        var formulas: [MarkdownRenderedMath] = []
        var diagrams: [MarkdownRenderedDiagram] = []
        /// Подстановка эмодзи по имени (`:имя:` → символ); пуста без `renderEmoji`.
        var emojiValues: [String: String] = [:]
        /// Состояние адресов, маркеров и сырого HTML (`+Media`).
        var media = MediaState()
        /// Заголовки для `[toc]` и псевдонимов ссылок `#…` (`prepareSpecial`).
        var special = SpecialState()

        init(text: NSString, darkMode: Bool, forExport: Bool, isPreview: Bool, includeHeadingNumbers: Bool, includeListStyles: Bool,
             includeSourcePositions: Bool, hardBreaks: Bool, preserveWhitespace: Bool,
             includeHTMLMedia: Bool = false, renderEmoji: Bool = false, resolveLocalImages: Bool = false, documentURL: URL? = nil,
             prepareRemoteImages: Bool = false, staticWidgetFallback: Bool = false, preserveRawHTMLBlocks: Bool = false,
             highlightCode: Bool = false, wiki: MarkdownWikiLinkContext? = nil, critic: CriticMarkupRenderMode? = nil,
             embeds: (any MarkdownNoteEmbedProvider)? = nil) {
            self.text = text
            self.darkMode = darkMode
            self.forExport = forExport
            self.isPreview = isPreview
            self.includeHeadingNumbers = includeHeadingNumbers
            self.includeListStyles = includeListStyles
            sourcePositions = includeSourcePositions && !forExport
            self.hardBreaks = hardBreaks
            self.preserveWhitespace = preserveWhitespace
            self.includeHTMLMedia = includeHTMLMedia
            self.renderEmoji = renderEmoji
            self.resolveLocalImages = resolveLocalImages
            self.documentURL = documentURL
            self.prepareRemoteImages = prepareRemoteImages
            self.staticWidgetFallback = staticWidgetFallback
            self.preserveRawHTMLBlocks = preserveRawHTMLBlocks
            self.highlightCode = highlightCode
            self.wiki = wiki
            self.critic = critic
            self.embeds = embeds
        }

        func put(_ string: String) { out += string }

        /// Как `cmark_html_render_cr`: перенос строки, если вывод не пуст и не кончается переносом.
        func cr() {
            if let last = out.utf8.last, last != 10 { out += "\n" }
        }

        /// Срез исходника; диапазон обрезается по длине текста.
        func slice(_ range: NSRange) -> String {
            let lower = min(max(range.location, 0), text.length)
            let upper = min(max(NSMaxRange(range), lower), text.length)
            return text.substring(with: NSRange(location: lower, length: upper - lower))
        }

        /// Начала строк в UTF-16 (`\n`, `\r`, `\r\n`).
        private lazy var lineStarts: [Int] = {
            var starts = [0]
            var index = 0
            let length = text.length
            while index < length {
                let unit = text.character(at: index)
                if unit == 10 {
                    starts.append(index + 1)
                } else if unit == 13 {
                    if index + 1 < length, text.character(at: index + 1) == 10 { index += 1 }
                    starts.append(index + 1)
                }
                index += 1
            }
            return starts
        }()

        /// Номер строки (с 0) для смещения.
        private func line(containing offset: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low
        }

        /// ` data-sourcepos="L1:C1-L2:C2"` — как у cmark: строки с 1, колонки с 1 в байтах UTF-8, конец включительно.
        /// Пусто, если позиции выключены (в экспорте не пишутся никогда).
        func sp(_ range: NSRange) -> String {
            guard sourcePositions else { return "" }
            let length = text.length
            let start = min(max(range.location, 0), length)
            var end = min(max(NSMaxRange(range), start), length)
            // Завершающий перевод строки в `range` не входит в позицию конца (cmark кончает блок на последнем символе строки).
            while end > start, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
            let startLine = line(containing: start)
            let endLine = line(containing: max(start, end - 1))
            func byteCount(from lineStart: Int, to offset: Int) -> Int {
                offset > lineStart ? text.substring(with: NSRange(location: lineStart, length: offset - lineStart)).utf8.count : 0
            }
            let startColumn = byteCount(from: lineStarts[startLine], to: start) + 1
            let endColumn = max(1, byteCount(from: lineStarts[endLine], to: max(end, lineStarts[endLine])))
            return " data-sourcepos=\"\(startLine + 1):\(startColumn)-\(endLine + 1):\(endColumn)\""
        }

        func sp(_ node: MarkdownBlockNode) -> String { sp(node.range) }
        func sp(_ node: MarkdownInlineNode) -> String { sp(node.range) }

        /// Номер заголовка для `<span data-lac-heading-number>`; `nil` — номера не нужны.
        func headingNumber(for node: MarkdownBlockNode) -> String? { headingNumbers[node.range.location] }
    }

    // MARK: - Вход

    /// Основной вход: модель + исходный текст (для срезов по `range`).
    /// `syntax` берётся из `model.options.syntax`, признак заметки хранилища — из `model.options.isVaultNote`
    /// (поэтому `hidesObsidianComments` здесь нет).
    static func renderPage(_ model: MarkdownDocumentModel, text: String, darkMode: Bool, includeHTMLMedia: Bool = false,
                           renderEmoji: Bool = false, resolveLocalImages: Bool = false, documentURL: URL? = nil,
                           prepareRemoteImages: Bool = false, forExport: Bool = false, includeHeadingNumbers: Bool = false,
                           includeListStyles: Bool = false, staticWidgetFallback: Bool = false, preserveRawHTMLBlocks: Bool = false,
                           includeSourcePositions: Bool = false, isPreview: Bool = false, highlightCode: Bool = false,
                           wiki: MarkdownWikiLinkContext? = nil, critic: CriticMarkupRenderMode? = nil,
                           embeds: (any MarkdownNoteEmbedProvider)? = nil) -> MarkdownRenderedPage {
        let syntax = model.options.syntax
        let hardBreaks = forExport ? (syntax.preserveExportSoftBreaks ?? true) : syntax.preserveEditingSoftBreaks
        let preserveWhitespace = forExport ? syntax.preserveExportWhitespace : (syntax.preserveEditingWhitespace ?? false)
        let writer = Writer(text: text as NSString, darkMode: darkMode, forExport: forExport, isPreview: isPreview,
                            includeHeadingNumbers: includeHeadingNumbers, includeListStyles: includeListStyles,
                            includeSourcePositions: includeSourcePositions, hardBreaks: hardBreaks, preserveWhitespace: preserveWhitespace,
                            includeHTMLMedia: includeHTMLMedia, renderEmoji: renderEmoji, resolveLocalImages: resolveLocalImages,
                            documentURL: documentURL, prepareRemoteImages: prepareRemoteImages,
                            staticWidgetFallback: staticWidgetFallback, preserveRawHTMLBlocks: preserveRawHTMLBlocks,
                            highlightCode: highlightCode, wiki: wiki, critic: critic, embeds: embeds)
        if includeHeadingNumbers { writer.headingNumbers = headingNumbers(in: model.blocks) }
        // Правки CriticMarkup в режимах `.result`/`.original` и комментарии `%%` убираются из модели до вывода (U3.3).
        let blocks = prepareObsidian(model, writer)
        prepareFootnotes(blocks, writer)
        prepareSpecial(model, writer)
        prepareNamedAnchors(model, writer)
        writeBlocks(blocks, writer, tight: false)
        writeFootnoteSection(writer)
        var body = writer.out
        if Task.isCancelled {
            body = ""
        } else if isPreview, !forExport, body.allSatisfy(\.isWhitespace), !hasSourceBesideHidden(model, text: text) {
            // Подсказка нужна только предпросмотру, когда в исходнике нет ничего, кроме пробелов, `%%…%%` и правок CriticMarkup
            // (front matter, определения ссылок и HTML-комментарии подсказку не вызывают, как в старом рендере); экспорт и печать остаются пустыми.
            body = "<p class=\"lac-empty\">" + escapeHTML(L10n.tr("预览为空。在编辑器中输入 Markdown 后，内容会显示在这里。")) + "</p>"
        }
        var page = MarkdownRenderedPage(body: body, darkMode: darkMode, headingIDs: Set(model.headingIDs), formulas: writer.formulas,
                                        diagrams: writer.diagrams, omittedHTML: includeHTMLMedia && writer.media.omittedHTML,
                                        preserveWhitespace: preserveWhitespace)
        page.listDepths = writer.listDepths
        page.remoteImageMarkers = writer.media.remoteMarkers
        page.localMediaMarkers = writer.media.localMarkers
        page.rawHTMLBlocks = writer.media.rawBlocks
        page.rawHTMLBlockProofFailed = writer.media.rawFailed
        return page
    }

    /// Подходит ли готовая модель (например, модель редактора) для предпросмотра с такими настройками.
    /// Условия те же, что строковый вход построил бы сам; несовпадение — не ошибка: вызывающий разберёт текст сам.
    /// Содержимое модели не сверяется: соответствие тексту обеспечивает `EditorDocument.markdownModel(forRevision:)`.
    static func accepts(_ model: MarkdownDocumentModel, text: String, syntax: MarkdownSyntaxOptions, wiki: MarkdownWikiLinkContext?,
                        critic: CriticMarkupRenderMode?, documentURL: URL?) -> Bool {
        guard model.textLength == text.utf16.count, !text.utf8.contains(0) else { return false }
        let options = model.options
        guard options.syntax == syntax, options.detectsFrontMatter,
              options.isVaultNote == MarkdownObsidianComment.appliesTo(documentURL: documentURL) else { return false }
        // Критика, встраивания и wiki-ссылки меняют HTML и в лишнем, и в недостающем виде: набор должен совпасть ровно.
        let exact: MarkdownDocumentModel.Includes = [.criticMarkup, .noteEmbeds, .wikiLinks]
        var needed: MarkdownDocumentModel.Includes = []
        if wiki != nil { needed.formUnion([.wikiLinks, .noteEmbeds]) }
        if critic != nil { needed.insert(.criticMarkup) }
        // Остальные флаги HTML не меняют, но `.emoji` обязателен (в предпросмотре `renderEmoji` всегда включён).
        return options.includes.intersection(exact) == needed && options.includes.contains(.emoji)
    }

    /// Только тело HTML с параметрами по умолчанию.
    static func render(_ markdown: String, darkMode: Bool) -> String {
        renderPage(markdown, darkMode: darkMode).html
    }

    /// Удобный вход: строит модель (`MarkdownDocumentParser.parse`) и зовёт основной. Для тестов и потребителей без модели.
    static func renderPage(_ markdown: String, darkMode: Bool, includeHTMLMedia: Bool = false, renderEmoji: Bool = false,
                           resolveLocalImages: Bool = false, documentURL: URL? = nil, prepareRemoteImages: Bool = false,
                           syntax: MarkdownSyntaxOptions = .init(), forExport: Bool = false, includeHeadingNumbers: Bool = false,
                           includeListStyles: Bool = false, staticWidgetFallback: Bool = false, preserveRawHTMLBlocks: Bool = false,
                           includeSourcePositions: Bool = false, isPreview: Bool = false, highlightCode: Bool = false,
                           wiki: MarkdownWikiLinkContext? = nil, critic: CriticMarkupRenderMode? = nil,
                           embeds: (any MarkdownNoteEmbedProvider)? = nil, hidesObsidianComments: Bool = false) -> MarkdownRenderedPage {
        // Разбор заменяет NUL на U+FFFD; срезы по `range` берутся из того же текста.
        let text = markdown.utf8.contains(0) ? markdown.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}") : markdown
        // Флаги разбора по параметрам вывода: медиа и эмодзи — `+Media` (U3.2), Obsidian и CriticMarkup — `+Obsidian` (U3.3).
        let obsidian = obsidianOptions(text, wiki: wiki, critic: critic, embeds: embeds, documentURL: documentURL,
                                       hidesObsidianComments: hidesObsidianComments)
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: mediaIncludes(renderEmoji: renderEmoji).union(obsidian.includes),
                                                    isVaultNote: obsidian.isVaultNote, detectsFrontMatter: true)
        guard let model = MarkdownDocumentParser.parse(text, options: options, isCancelled: { Task.isCancelled }) else {
            // Разбор отменён: страница пустая.
            return MarkdownRenderedPage(body: "", darkMode: darkMode, headingIDs: [], formulas: [], diagrams: [], omittedHTML: false,
                                        preserveWhitespace: forExport ? syntax.preserveExportWhitespace : (syntax.preserveEditingWhitespace ?? false))
        }
        return renderPage(model, text: text, darkMode: darkMode, includeHTMLMedia: includeHTMLMedia, renderEmoji: renderEmoji,
                          resolveLocalImages: resolveLocalImages, documentURL: documentURL, prepareRemoteImages: prepareRemoteImages,
                          forExport: forExport, includeHeadingNumbers: includeHeadingNumbers, includeListStyles: includeListStyles,
                          staticWidgetFallback: staticWidgetFallback, preserveRawHTMLBlocks: preserveRawHTMLBlocks,
                          includeSourcePositions: includeSourcePositions, isPreview: isPreview, highlightCode: highlightCode,
                          wiki: wiki, critic: critic, embeds: embeds)
    }

    /// Номера заголовков с непустым `id` (`MarkdownHeadingNumbering`, не копия алгоритма), по `range.location`.
    /// `isUnreliable` не смотрим: нумеруются и заголовки с восстановленной позицией (`#\tFoo`, setext с табом).
    private static func headingNumbers(in blocks: [MarkdownBlockNode]) -> [Int: String] {
        var headings: [MarkdownHeading] = []
        func collect(_ nodes: [MarkdownBlockNode]) {
            for node in nodes {
                if case .heading(let heading) = node.kind, !heading.id.isEmpty {
                    headings.append(MarkdownHeading(level: heading.level, title: heading.title, range: node.range))
                }
                collect(node.children)
            }
        }
        collect(blocks)
        var numbers: [Int: String] = [:]
        for heading in MarkdownHeadingNumbering.applying(to: headings, enabled: true) {
            if let number = heading.number { numbers[heading.range.location] = number }
        }
        return numbers
    }

    // MARK: - Экранирование и адреса

    /// `houdini_escape_html0` при `secure = 0`: только `& < > "`. Апостроф и `/` не трогаются.
    static func escapeHTML(_ string: String) -> String {
        var needs = false
        for byte in string.utf8 where byte == 38 || byte == 60 || byte == 62 || byte == 34 { needs = true; break }
        guard needs else { return string }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count + 16)
        for byte in string.utf8 {
            switch byte {
            case 38: bytes.append(contentsOf: Array("&amp;".utf8))
            case 60: bytes.append(contentsOf: Array("&lt;".utf8))
            case 62: bytes.append(contentsOf: Array("&gt;".utf8))
            case 34: bytes.append(contentsOf: Array("&quot;".utf8))
            default: bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Символы адреса, которые `houdini_escape_href` оставляет как есть (таблица `HREF_SAFE`).
    private static func isHrefSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122: return true
        case 33, 35, 36, 37, 40...47, 58, 59, 61, 63, 64, 95, 126: return true
        default: return false
        }
    }

    /// `houdini_escape_href`: `&` → `&amp;`, `'` → `&#x27;`, остальное небезопасное — `%XX` по байтам UTF-8.
    static func escapeHref(_ string: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count + 8)
        for byte in string.utf8 {
            if isHrefSafe(byte) {
                bytes.append(byte)
            } else if byte == 38 {
                bytes.append(contentsOf: Array("&amp;".utf8))
            } else if byte == 39 {
                bytes.append(contentsOf: Array("&#x27;".utf8))
            } else {
                bytes.append(37)
                bytes.append(hex[Int(byte >> 4)])
                bytes.append(hex[Int(byte & 15)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `_scan_dangerous_url`: адрес с `javascript:`, `vbscript:`, `file:`, `data:` (без учёта регистра); `data:image/{png,gif,jpeg,webp}` безопасны.
    static func isDangerousURL(_ string: String) -> Bool {
        let head = String(decoding: string.utf8.prefix(16).map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
        if head.hasPrefix("data:image/") {
            for kind in ["png", "gif", "jpeg", "webp"] where head.hasPrefix("data:image/" + kind) { return false }
        }
        return ["javascript:", "vbscript:", "file:", "data:"].contains { head.hasPrefix($0) }
    }

    /// Значение атрибута `href`/`src`: у опасного адреса пустое, иначе `escapeHref`. `UNSAFE` страница не включает, проверка всегда.
    static func hrefValue(_ url: String) -> String {
        isDangerousURL(url) ? "" : escapeHref(url)
    }

    // MARK: - Общий обход

    static func writeBlocks(_ nodes: [MarkdownBlockNode], _ w: Writer, tight: Bool) {
        for node in nodes {
            if Task.isCancelled { return }
            writeBlock(node, w, tight: tight)
        }
    }

    /// `tight` — родитель узла: пункт плотного списка (абзац тогда без `<p>`).
    /// Все виды узлов разобраны без `default`: новый вид не соберётся, пока его не отнесут к блокам, медиа или Obsidian.
    static func writeBlock(_ node: MarkdownBlockNode, _ w: Writer, tight: Bool) {
        switch node.kind {
        case .paragraph: writeParagraph(node, w, tight: tight)
        case .heading(let heading): writeHeading(node, heading, w)
        case .quote: writeQuote(node, w)
        case .list(let list): writeList(node, list, w)
        case .listItem(let item): writeListItem(node, item, w, list: nil)
        case .codeBlock(let code): writeCodeBlock(node, code, w)
        case .table(let table): writeTable(node, table, w)
        case .thematicBreak: writeThematicBreak(node, w)
        // Определения сносок выводятся в конце страницы (`writeFootnoteSection`), на своём месте — ничего.
        case .footnoteDefinition: break
        // Front matter не выводится: в старом рендере он заменялся пробелами.
        case .frontMatter: break
        case .html, .mathBlock, .tableOfContents: writeMediaBlock(node, w)
        case .callout, .alert, .noteEmbed, .comment: writeObsidianBlock(node, w)
        }
    }

    static let omittedHTMLComment = "<!-- raw HTML omitted -->"

    static func writeInlines(_ nodes: [MarkdownInlineNode], _ w: Writer) {
        // При `preserveWhitespace` подряд идущие `.text` и `.emoji` (он выводится текстом) пишутся одним `data-lac-whitespace`.
        var run: String?
        var index = 0
        while index < nodes.count {
            let node = nodes[index]
            index += 1
            if !w.media.inlineAnchors.isEmpty, let id = w.media.inlineAnchors.removeValue(forKey: node.range.location) {
                if let text = run { writeText(text, w); run = nil }
                w.put("<span id=\"\(id)\"></span>")
            }
            // Экспорт HTML: `<script|style|textarea>` … закрывающий тег — один маркер, внутри нет Markdown.
            if w.preserveRawHTMLBlocks, let last = rawElementEnd(nodes, from: index - 1, w) {
                if let text = run { writeText(text, w); run = nil }
                let range = NSRange(location: node.range.location, length: NSMaxRange(nodes[last].range) - node.range.location)
                w.put(rawMarker(w.slice(range), w))
                index = last + 1
                continue
            }
            guard w.preserveWhitespace else { writeInline(node, w); continue }
            switch node.kind {
            case .text(let string): if run == nil { run = string } else { run!.append(string) }
            case .emoji where node.children.isEmpty:
                let string = emojiText(node, w)
                if run == nil { run = string } else { run!.append(string) }
            default:
                if let text = run { writeText(text, w); run = nil }
                writeInline(node, w)
            }
        }
        if let text = run { writeText(text, w) }
    }

    static func writeInline(_ node: MarkdownInlineNode, _ w: Writer) {
        switch node.kind {
        case .text(let string): writeText(string, w)
        case .code(let literal): writeInlineCode(literal, w)
        case .strong: writeStrong(node, w)
        case .emphasis: writeEmphasis(node, w)
        case .strikethrough: writeStrikethrough(node, w)
        case .softBreak: writeSoftBreak(w)
        case .hardBreak: writeHardBreak(w)
        case .link(let link): writeLink(node, link, w)
        case .image(let image): writeImage(node, image, w)
        case .footnoteReference(let label): writeFootnoteReference(node, label: label, w)
        case .underline, .keyboard, .highlight, .subscriptText, .superscriptText, .inlineStyle, .media, .iframe, .svg, .ruby,
             .emoji, .formula, .rawHTML:
            writeMediaInline(node, w)
        case .wikiLink, .noteEmbed, .critic, .comment: writeObsidianInline(node, w)
        }
    }

    // MARK: - Текст

    /// Точка 3 (U3.2): писатель текста. Экранирует; при `preserveWhitespace` оборачивает в `<span data-lac-whitespace>`.
    /// U3.2 объединяет соседние `.text`/`.emoji` в один вызов (в `writeInlines`), поэтому сюда приходит готовая строка.
    static func writeText(_ string: String, _ w: Writer) {
        if w.preserveWhitespace {
            w.put(w.forExport ? "<span data-lac-whitespace style=\"white-space:break-spaces\">" : "<span data-lac-whitespace>")
            w.put(escapeHTML(string))
            w.put("</span>")
        } else {
            w.put(escapeHTML(string))
        }
    }

    /// Картинка: Markdown-форма (`![](…)`) или HTML-тег `<img>` (`+Media`).
    static func writeImage(_ node: MarkdownInlineNode, _ image: MarkdownInlineNode.Image, _ w: Writer) {
        if image.syntax == .html { writeHTMLImage(node, image, w) } else { writeMarkdownImage(node, image, w) }
    }
}
