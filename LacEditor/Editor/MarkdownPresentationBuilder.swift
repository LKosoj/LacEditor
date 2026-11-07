import Foundation

/// Переводчик модели документа в оформление редактора (U5.1): из `MarkdownDocumentModel` строит тот же `MarkdownPresentation`,
/// который рисует TextKit. Дерево cmark не читает; AppKit и SwiftUI не нужны.
/// Таблицы — `MarkdownPresentationBuilder+Table.swift`, отсев показа (медиа, неподтверждённый HTML, безопасные замены) — `+Filter.swift`.
enum MarkdownPresentationBuilder {
    /// Флаги показа: что из модели попадает в оформление.
    struct BuildOptions: Sendable {
        var includeReadableText = false
        var includeEmojiCandidates = false
        var includeWikiLinks = false
        var syntax = MarkdownSyntaxOptions()
    }

    /// Контекст таблицы: цитаты и списки вокруг неё (как у `MarkdownTableEditingService.presentationTable`).
    struct TableContext: Sendable {
        var containerPrefix: String
        var quoteDepth: Int
        var nestedList: Bool
    }

    /// Поля оформления до отсева показа. После `build` отсев (`+Filter`) убирает из них то, что закрыто медиа или неподтверждённым HTML.
    struct Draft {
        var spans: [MarkdownPresentationSpan] = []
        var headings: [MarkdownHeading] = []
        var namedAnchors: [MarkdownNamedAnchor] = []
        var images: [MarkdownImage] = []
        var audioBlocks: [MarkdownAudioBlock] = []
        var iframeBlocks: [MarkdownIframeBlock] = []
        var detailsBlocks: [MarkdownDetailsBlock] = []
        var htmlBlocks: [MarkdownHTMLBlock] = []
        var pageBreaks: [NSRange] = []
        var ruby: [MarkdownRuby] = []
        var links: [MarkdownLink] = []
        var wikiLinks: [MarkdownWikiLink] = []
        var diagrams: [MarkdownDiagram] = []
        var formulas: [MarkdownFormula] = []
        var inlineFormulas: [MarkdownFormula] = []
        var emojiCandidates: [MarkdownEmojiCandidate] = []
        var emojiCompletionRanges: [NSRange] = []
        var smartTextRanges: [NSRange] = []
        var textReplacements: [MarkdownTextReplacement] = []
        var paragraphs: [MarkdownParagraph] = []
        var completedTaskRanges: [NSRange] = []
        var taskCheckboxes: [MarkdownTaskCheckbox] = []
        var listMarkers: [MarkdownListMarker] = []
        var footnotes: [MarkdownFootnote] = []
        var tableOfContents: [NSRange] = []
        var tables: [MarkdownTable] = []
        var codeBlocks: [MarkdownCodeBlock] = []
    }

    /// Пустое оформление возвращается при отмене.
    static func build(_ model: MarkdownDocumentModel, text: NSString, options: BuildOptions = BuildOptions(),
                      isCancelled: @escaping () -> Bool = { false }) -> MarkdownPresentation {
        var walker = Walker(model: model, text: text, options: options, isCancelled: isCancelled)
        if let front = model.frontMatter {
            walker.draft.spans.append(MarkdownPresentationSpan(range: front.range, kind: .yaml, markerRanges: front.markers))
        }
        walker.draft.namedAnchors = model.namedAnchors
        walker.draft.footnotes = model.footnotes
        walker.footnoteReferences = Set(model.footnotes.map(\.referenceRange))
        let emoji = options.includeEmojiCandidates ? model.emoji : nil
        walker.draft.emojiCandidates = emoji?.candidates ?? []
        walker.draft.emojiCompletionRanges = emoji?.completionRanges ?? []
        walker.draft.smartTextRanges = emoji?.smartTextRanges ?? []
        walker.draft.textReplacements = model.smartReplacements
        walker.visit(model.blocks, ctx: Walker.Context())
        if walker.cancelled || isCancelled() { return MarkdownPresentation(spans: []) }
        var draft = walker.draft
        draft.audioBlocks.sort { $0.range.location < $1.range.location }
        draft.iframeBlocks.sort { $0.range.location < $1.range.location }
        draft.images.sort { $0.range.location < $1.range.location }
        guard let filtered = applyingDisplayFilter(draft, blockedHTML: model.blockedHTML, text: text, isCancelled: isCancelled) else {
            return MarkdownPresentation(spans: [])
        }
        draft = filtered
        // Wiki-ссылки получают и span `.link`: он добавляется после отсева.
        for link in draft.wikiLinks { draft.spans.append(MarkdownPresentationSpan(range: link.range, kind: .link, markerRanges: link.markerRanges)) }
        let fence = model.fence
        let presentation = MarkdownPresentation(
            spans: draft.spans, headings: draft.headings, namedAnchors: draft.namedAnchors, images: draft.images, audioBlocks: draft.audioBlocks,
            iframeBlocks: draft.iframeBlocks, detailsBlocks: draft.detailsBlocks, htmlBlocks: draft.htmlBlocks, pageBreaks: draft.pageBreaks,
            ruby: draft.ruby, links: draft.links, diagrams: draft.diagrams, formulas: draft.formulas, inlineFormulas: draft.inlineFormulas,
            emojiCandidates: draft.emojiCandidates, emojiCandidatesIncluded: options.includeEmojiCandidates,
            emojiCompletionRanges: draft.emojiCompletionRanges, smartTextRanges: draft.smartTextRanges,
            smartRawHTMLRanges: emoji?.smartRawHTMLRanges, textReplacements: draft.textReplacements,
            paragraphs: draft.paragraphs, completedTaskRanges: draft.completedTaskRanges, taskCheckboxes: draft.taskCheckboxes,
            listMarkers: draft.listMarkers, looseIndents: model.looseIndents, footnotes: draft.footnotes, tableOfContents: draft.tableOfContents,
            tables: draft.tables, codeBlocks: draft.codeBlocks,
            fenceContainerLines: fence?.containerLines ?? [], fenceBlockedRanges: fence?.blockedRanges ?? [],
            fenceBlockedEOF: fence?.blockedEOF ?? false, fenceContextAvailable: fence?.isAvailable ?? false,
            readableText: options.includeReadableText ? model.readableText : nil)
        return presentation.withWikiLinks(draft.wikiLinks).withElements(model.elements ?? .empty)
            .withUnreliableRanges(model.unreliableRanges)
    }

    // MARK: - Обход модели

    private struct Walker {
        /// Где мы в дереве: вне оформляемого (`unsupported`: таблица, сноска), цитаты и списки вокруг.
        struct Context {
            /// Таблица, определение сноски, картинка: спаны и абзацы не строятся.
            var unsupported = false
            var quoteDepth = 0
            /// Глубина ближайшего списка (`ListBlock.depth`); 0 вне списков.
            var listDepth = 0
            /// Абзац или заголовок, в котором лежат строчные картинки (`MarkdownImage.paragraphRange`); у ячейки — её диапазон.
            var owner: NSRange?
            /// Ячейка таблицы, попавшей в оформление: картинки в ней показываются.
            var inCell = false
            /// Внутри таблицы: CriticMarkup и `%%` не окрашиваются (`MarkdownElementIndex.excludedRanges`).
            var inTable = false
            /// Первая строка выноски `[!тип]`: она входит в первый абзац выноски.
            var calloutStart: Int?
        }

        let model: MarkdownDocumentModel
        let text: NSString
        let options: BuildOptions
        let isCancelled: () -> Bool
        var draft = Draft()
        var cancelled = false
        var footnoteReferences: Set<NSRange> = []

        init(model: MarkdownDocumentModel, text: NSString, options: BuildOptions, isCancelled: @escaping () -> Bool) {
            self.model = model
            self.text = text
            self.options = options
            self.isCancelled = isCancelled
        }

        mutating func stop() -> Bool {
            if !cancelled && isCancelled() { cancelled = true }
            return cancelled
        }

        mutating func visit(_ blocks: [MarkdownBlockNode], ctx: Context) {
            var previousParagraph: Int?
            var ctx = ctx
            for block in blocks {
                if stop() { return }
                defer { ctx.calloutStart = nil }
                let before = draft.paragraphs.count
                visit(block, ctx: ctx)
                // Пустая строка между соседними абзацами одного контейнера (`separatorAfter`).
                if block.isParagraphLike, draft.paragraphs.count > before {
                    let index = draft.paragraphs.count - 1
                    if let previous = previousParagraph { separator(after: previous, before: index, quoteDepth: ctx.quoteDepth) }
                    previousParagraph = index
                } else { previousParagraph = nil }
            }
        }

        /// Между абзацами только пустые строки (и `>` по числу цитат) — промежуток запоминается.
        private mutating func separator(after first: Int, before second: Int, quoteDepth: Int) {
            let start = NSMaxRange(draft.paragraphs[first].range), end = draft.paragraphs[second].range.location
            guard start < end, end <= text.length else { return }
            var position = start, markers = 0
            while position < end {
                let character = text.character(at: position)
                if character == 62 { markers += 1 }
                else if character == 10 || character == 13 {
                    if markers != quoteDepth { return }
                    markers = 0
                    if character == 13 && position + 1 < end && text.character(at: position + 1) == 10 { position += 1 }
                } else if character != 32 && character != 9 { return }
                position += 1
            }
            if markers == 0 { draft.paragraphs[first].separatorAfter = NSRange(location: start, length: end - start) }
        }

        private mutating func visit(_ block: MarkdownBlockNode, ctx: Context) {
            var inner = ctx
            switch block.kind {
            case .paragraph:
                if !ctx.unsupported { addParagraph(block, from: ctx.calloutStart) }
                inner.owner = block.range
                visitInlines(block.inlines, ctx: inner)
            case .heading(let heading):
                if !ctx.unsupported && !heading.inUnsupportedContainer {
                    if block.isUnreliable { addUnreliableHeading(block, heading) } else { addHeading(block, heading) }
                }
                inner.owner = block.range
                visitInlines(block.inlines, ctx: inner)
            case .quote, .callout, .alert:
                if !ctx.unsupported && !block.isUnreliable {
                    if case .alert(let alert) = block.kind, let marker = alertMarker(block, alert) {
                        draft.spans.append(MarkdownPresentationSpan(range: block.range, kind: .alert(alert.rawValue), markerRanges: [marker]))
                    }
                    draft.spans.append(MarkdownPresentationSpan(range: block.range, kind: .quote, markerRanges: block.markerRanges))
                    if case .callout(let callout) = block.kind { draft.spans += MarkdownPresentationBuilder.calloutSpans(block, callout) }
                }
                inner.quoteDepth += 1
                inner.owner = block.range
                inner.calloutStart = nil
                if case .callout(let callout) = block.kind {
                    inner.calloutStart = callout.markerRange.location
                }
                // Заголовок выноски лежит в `inlines` узла.
                visitInlines(block.inlines, ctx: inner)
                visit(block.children, ctx: inner)
            case .list(let list):
                inner.listDepth = list.depth
                visit(block.children, ctx: inner)
            case .listItem(let item):
                if !ctx.unsupported { addListItem(block, item, depth: ctx.listDepth) }
                visit(block.children, ctx: inner)
            case .codeBlock(let code):
                if !ctx.unsupported { addCodeBlock(block, code) }
            case .mathBlock(let source):
                if let formula = MarkdownFormula(block: block, source: source) { draft.formulas.append(formula) }
            case .table(let table):
                if !ctx.unsupported { addTable(block, table, ctx: ctx) }
            case .html(let html):
                if !ctx.unsupported { addHTML(block, html) }
            case .tableOfContents:
                if !ctx.unsupported && !block.isUnreliable {
                    draft.tableOfContents.append(block.range)
                    // `[toc]` — обычный абзац с текстом.
                    addParagraphLines(text.lineRange(for: block.range))
                }
            case .footnoteDefinition:
                inner.unsupported = true
                visit(block.children, ctx: inner)
            case .noteEmbed(let embed):
                if !ctx.unsupported, !block.isUnreliable, let link = MarkdownPresentationBuilder.embedLink(range: block.range, embed, text: text) {
                    draft.wikiLinks.append(link)
                }
            case .comment:
                // Цвет `%%` ставится и в сносках.
                if !block.isUnreliable {
                    draft.spans.append(MarkdownPresentationBuilder.obsidianCommentSpan(range: block.range, markerRanges: block.markerRanges))
                }
            case .frontMatter, .thematicBreak:
                break
            }
        }

        // MARK: Списки и абзацы

        private mutating func addListItem(_ block: MarkdownBlockNode, _ item: MarkdownBlockNode.ListItem, depth: Int) {
            if let task = item.task {
                draft.taskCheckboxes.append(task)
                if task.state != 32, block.range.location <= task.markerRange.location, NSMaxRange(block.range) >= NSMaxRange(task.markerRange) {
                    draft.completedTaskRanges.append(block.range)
                }
                return
            }
            // Маркер пункта: «•» или «N.»; пункты-задачи маркера не дают (их рисует отметка).
            guard let marker = block.markerRanges.first, marker.length > 0, NSMaxRange(marker) <= text.length else { return }
            draft.listMarkers.append(MarkdownListMarker(
                range: marker, line: text.lineRange(for: NSRange(location: marker.location, length: 0)),
                text: item.ordinal.map { "\($0)." } ?? "•", ordinal: item.ordinal, depth: depth))
        }

        /// Абзац оформляется, если все его строчные узлы подтверждены, а формул в нём нет.
        private mutating func addParagraph(_ block: MarkdownBlockNode, from calloutStart: Int? = nil) {
            // Позиция блока не подтверждена (таб в отступе): строки берутся по подтверждённым строчным узлам.
            var block = block
            if block.isUnreliable, let span = Self.leafSpan(block.inlines),
               span.location >= block.range.location, NSMaxRange(span) <= NSMaxRange(block.range) {
                block.range = span
                block.isUnreliable = false
            }
            guard !block.isUnreliable, block.range.length > 0, block.range.location >= 0, NSMaxRange(block.range) <= text.length,
                  Self.isConfirmedText(block.inlines, text: text) else { return }
            var hasText = false
            func scan(_ nodes: [MarkdownInlineNode]) {
                for node in nodes {
                    switch node.kind {
                    case .text, .code, .image, .rawHTML, .ruby, .svg, .wikiLink, .emoji: hasText = true
                    default: break
                    }
                    scan(node.children)
                }
            }
            scan(block.inlines)
            guard hasText else { return }
            var range = text.lineRange(for: block.range)
            // Абзац после определений ссылок: cmark начинает его с первого определения, а оформляются строки самого текста.
            if let first = block.inlines.first, !first.isUnreliable, first.range.location >= range.location, first.range.location < NSMaxRange(range) {
                let firstLine = text.lineRange(for: NSRange(location: first.range.location, length: 0)).location
                if firstLine > range.location { range = NSRange(location: firstLine, length: NSMaxRange(range) - firstLine) }
            }
            if let start = calloutStart, start < range.location {
                let first = text.lineRange(for: NSRange(location: start, length: 0)).location
                range = NSRange(location: first, length: NSMaxRange(range) - first)
            }
            addParagraphLines(range)
        }

        private mutating func addParagraphLines(_ range: NSRange) {
            guard range.length > 0 else { return }
            let lastLine = text.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            draft.paragraphs.append(MarkdownParagraph(range: range, lastLine: lastLine))
        }

        /// От первого до последнего подтверждённого листа: обёртка выделения на строке с табом позиции не имеет, но её дети подтверждены.
        private static func leafSpan(_ nodes: [MarkdownInlineNode]) -> NSRange? {
            func leaves(_ list: [MarkdownInlineNode]) -> [NSRange] {
                list.flatMap { node -> [NSRange] in
                    if isWrapper(node.kind), !node.children.isEmpty { return leaves(node.children) }
                    return node.isUnreliable ? [] : [node.range]
                }
            }
            let all = leaves(nodes)
            guard let first = all.first, let last = all.last else { return nil }
            return NSUnionRange(first, last)
        }

        private static func isWrapper(_ kind: MarkdownInlineNode.Kind) -> Bool {
            switch kind {
            case .strong, .emphasis, .strikethrough, .underline, .keyboard, .highlight, .subscriptText, .superscriptText, .inlineStyle, .link: return true
            default: return false
            }
        }

        private static func isConfirmedText(_ nodes: [MarkdownInlineNode], text: NSString) -> Bool {
            nodes.allSatisfy { node in
                // Подтверждать нужно листья (текст, код, картинку, HTML); у обёртки выделения или ссылки позиция может быть неизвестна (таб в строке).
                if node.isUnreliable, !(isWrapper(node.kind) && !node.children.isEmpty) {
                    // Мягкий перенос не текст: на строке с табом его позиция неизвестна, абзац от этого не теряется.
                    if case .softBreak = node.kind { return true }
                    return false
                }
                if case .formula = node.kind { return false }
                // Перенос «пробелы в конце строки»: текст до и после него не подтверждается; перенос `\` подтверждается.
                if case .hardBreak = node.kind, node.range.location >= text.length || text.character(at: node.range.location) != 92 { return false }
                return isConfirmedText(node.children, text: text)
            }
        }

        // MARK: Заголовки, алерт

        private mutating func addHeading(_ block: MarkdownBlockNode, _ heading: MarkdownBlockNode.Heading) {
            var plain: NSRange?
            if options.includeEmojiCandidates, heading.emoji.isEmpty, block.inlines.count == 1, case .text(let value) = block.inlines[0].kind,
               !block.inlines[0].isUnreliable, value == heading.title, block.inlines[0].range.length == (value as NSString).length,
               block.inlines[0].range.location >= block.range.location, NSMaxRange(block.inlines[0].range) <= NSMaxRange(block.range),
               NSMaxRange(block.inlines[0].range) <= text.length, text.substring(with: block.inlines[0].range) == value {
                plain = block.inlines[0].range
            }
            draft.headings.append(MarkdownHeading(block: block, heading, plainTextRange: plain,
                                                  uppercaseRuns: options.includeEmojiCandidates ? heading.uppercaseRuns : nil))
            draft.spans.append(MarkdownPresentationSpan(range: block.range, kind: .heading(heading.level),
                                                     markerRanges: heading.style == .setext ? [] : block.markerRanges))
        }

        /// Заголовок без подтверждённой позиции остаётся в оглавлении: якорь нулевой длины в начале строки, оформления нет.
        private mutating func addUnreliableHeading(_ block: MarkdownBlockNode, _ heading: MarkdownBlockNode.Heading) {
            draft.headings.append(MarkdownHeading(block: block, heading))
        }

        /// `[!NOTE]` на первой строке: после `>` и необязательного пробела; модель хранит только вид алерта.
        private func alertMarker(_ block: MarkdownBlockNode, _ alert: MarkdownBlockNode.Alert) -> NSRange? {
            let start = block.range.location + (block.range.location + 1 < text.length && text.character(at: block.range.location + 1) == 32 ? 2 : 1)
            let range = NSRange(location: start, length: alert.rawValue.utf16.count + 3)
            return NSMaxRange(range) <= text.length ? range : nil
        }

        // MARK: Код

        /// Конец строки вместе с переводом (`\n`, `\r`, `\r\n`), начиная с `location`.
        private func afterLine(_ location: Int) -> Int {
            var end = location
            while end < text.length, text.character(at: end) != 10, text.character(at: end) != 13 { end += 1 }
            return Self.afterBreak(text, end)
        }

        private static func afterBreak(_ text: NSString, _ location: Int) -> Int {
            guard location < text.length else { return location }
            let unit = text.character(at: location)
            if unit == 13 { return location + (location + 1 < text.length && text.character(at: location + 1) == 10 ? 2 : 1) }
            return unit == 10 ? location + 1 : location
        }

        private mutating func addCodeBlock(_ block: MarkdownBlockNode, _ code: MarkdownBlockNode.CodeBlock) {
            guard !block.isUnreliable else { return }
            if let kind = code.diagram {
                draft.diagrams.append(MarkdownDiagram(range: block.range, source: code.literal, kind: kind))
            }
            guard code.isFenced, !block.markerRanges.isEmpty, let info = code.infoRange else {
                // Блок с отступом-табом не оформляется: позиция узла в cmark там не подтверждалась.
                if !code.isFenced, text.character(at: text.lineRange(for: NSRange(location: block.range.location, length: 0)).location) == 9 { return }
                draft.spans.append(MarkdownPresentationSpan(range: block.range, kind: .codeBlock, markerRanges: []))
                return
            }
            // Модель режет перевод строки в конце незакрытого блока; оформлению он нужен.
            let range = code.isClosed ? block.range : NSRange(location: block.range.location,
                                                                length: Self.afterBreak(text, NSMaxRange(block.range)) - block.range.location)
            let bodyStart = afterLine(NSMaxRange(info))
            var bodyEnd = NSMaxRange(range)
            if code.isClosed, let closing = block.markerRanges.last {
                bodyEnd = text.lineRange(for: NSRange(location: closing.location, length: 0)).location
            }
            let segments = code.bodySegments.map { NSRange(location: $0.location, length: Self.afterBreak(text, NSMaxRange($0)) - $0.location) }
            // Блок верхнего уровня префикса контейнера не имеет: продолжение — отступ самого ограждения.
            let continuation = block.containerPrefixes.first?.continuation ?? block.markerRanges.first.flatMap {
                MarkdownDocumentExtras.fencePrefix(ancestors: [], text: text, position: $0.location, allowEarlierItem: true, itemStartColumn: { _ in nil })?.continuation
            } ?? ""
            let confirmed = MarkdownCodeBlock(range: range, bodyRange: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)),
                                              bodySegments: segments, bodyPadding: code.bodyPadding, infoRange: info,
                                              fenceMarkers: block.markerRanges, continuationPrefix: continuation,
                                              isNested: !block.containerPrefixes.isEmpty, isClosed: code.isClosed, info: code.info, literal: code.literal)
            draft.codeBlocks.append(confirmed)
            draft.spans.append(MarkdownPresentationSpan(range: range, kind: .codeBlock, markerRanges: code.isClosed ? block.markerRanges : []))
        }

        // MARK: Таблицы

        private mutating func addTable(_ block: MarkdownBlockNode, _ table: MarkdownBlockNode.Table, ctx: Context) {
            // Цитаты и списки вокруг: префикс — текст от начала строки до таблицы.
            var start = block.range.location
            while start > 0 && text.character(at: start - 1) != 10 && text.character(at: start - 1) != 13 { start -= 1 }
            let nested = ctx.listDepth > 0
            let prefix = ctx.quoteDepth > 0 || nested ? text.substring(with: NSRange(location: start, length: block.range.location - start)) : ""
            let context = TableContext(containerPrefix: prefix, quoteDepth: ctx.quoteDepth, nestedList: nested)
            let produced = block.isUnreliable ? nil : MarkdownPresentationBuilder.presentationTable(
                block, table: table, context: context, text: text, emojiCandidates: draft.emojiCandidates,
                syntax: options.syntax, isCancelled: isCancelled)
            if let produced { draft.tables.append(produced) }
            var inner = ctx
            inner.unsupported = true
            inner.inTable = true
            for row in table.rows {
                for cell in row.cells {
                    inner.owner = cell.range
                    inner.inCell = produced != nil
                    visitInlines(cell.inlines, ctx: inner)
                }
            }
        }

        // MARK: HTML-блоки

        private mutating func addHTML(_ block: MarkdownBlockNode, _ html: MarkdownBlockNode.HTMLBlock) {
            guard !block.isUnreliable else { return }
            switch html.kind {
            case .raw:
                break
            case .images(let images):
                // Картинка блока — по диапазону своего тега `<img>`; строчная, если в блоке есть что-то кроме неё.
                for image in images {
                    guard let tag = image.tagRange, tag.location >= block.range.location, NSMaxRange(tag) <= NSMaxRange(block.range) else { continue }
                    let before = text.substring(with: NSRange(location: block.range.location, length: tag.location - block.range.location))
                    let after = text.substring(with: NSRange(location: NSMaxRange(tag), length: NSMaxRange(block.range) - NSMaxRange(tag)))
                    let standalone = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    draft.images.append(MarkdownImage(range: tag, paragraphRange: block.range, url: image.url, alt: image.alt, title: image.title,
                                                      isInline: !standalone, sizing: image.sizing))
                }
            case .confirmed(let display):
                draft.htmlBlocks.append(MarkdownHTMLBlock(range: block.range, html: display))
            case .details(let details):
                draft.detailsBlocks.append(details)
            case .media(let media):
                draft.audioBlocks.append(MarkdownAudioBlock(range: block.range, media: media))
            case .iframe(let frame, let value, let display):
                draft.iframeBlocks.append(MarkdownIframeBlock(range: block.range, html: value, displayHTML: display,
                                                              width: frame.width, height: frame.height, title: frame.title))
            case .twitter(let widget):
                guard let frame = MarkdownHTMLMediaService.twitterFrame(widget) else { return }
                draft.iframeBlocks.append(MarkdownIframeBlock(range: block.range, html: MarkdownHTMLMediaService.iframeHTML(frame),
                                                              displayHTML: MarkdownHTMLMediaService.twitterFallbackHTML(widget),
                                                              width: frame.width, height: frame.height, title: frame.title))
            case .svg(let data):
                draft.images.append(MarkdownImage(range: block.range, paragraphRange: block.range, url: Self.svgURL(data), alt: "", title: nil))
            case .pageBreak:
                draft.pageBreaks.append(block.range)
            }
        }

        private static func svgURL(_ data: Data) -> String { "data:image/svg+xml;base64," + data.base64EncodedString() }

        // MARK: Строчные узлы

        private mutating func visitInlines(_ nodes: [MarkdownInlineNode], ctx: Context) {
            for node in nodes {
                if stop() { return }
                visitInline(node, ctx: ctx)
                visitInlines(node.children, ctx: ctx)
            }
        }

        private mutating func span(_ node: MarkdownInlineNode, _ kind: MarkdownPresentationKind, ctx: Context) {
            guard !ctx.unsupported, !node.isUnreliable else { return }
            draft.spans.append(MarkdownPresentationSpan(range: node.range, kind: kind, markerRanges: node.markerRanges))
        }

        private mutating func visitInline(_ node: MarkdownInlineNode, ctx: Context) {
            switch node.kind {
            case .strong: span(node, .strong, ctx: ctx)
            case .emphasis: span(node, .emphasis, ctx: ctx)
            case .strikethrough: span(node, .strikethrough, ctx: ctx)
            case .code: span(node, .code, ctx: ctx)
            case .underline: span(node, .underline, ctx: ctx)
            case .keyboard: span(node, .keyboard, ctx: ctx)
            case .highlight: span(node, .highlight, ctx: ctx)
            case .subscriptText: span(node, .subscriptText, ctx: ctx)
            case .superscriptText: span(node, .superscriptText, ctx: ctx)
            case .inlineStyle(let style): span(node, .inlineStyle(style), ctx: ctx)
            case .link(let link):
                // Скобки прячутся у `[текст](адрес)` и у пары `<a href>…</a>` (теги); у автоссылки и ссылочной формы маркеров нет.
                if link.form == .inline || link.form == .html { span(node, .link, ctx: ctx) }
                else if !ctx.unsupported, !node.isUnreliable { draft.spans.append(MarkdownPresentationSpan(range: node.range, kind: .link, markerRanges: [])) }
                if let entry = MarkdownDocumentQueries.LinkEntry(node: node, link) { draft.links.append(entry.link) }
            case .image(let image): addImage(node, image, ctx: ctx)
            case .media(let media):
                guard !ctx.unsupported, !node.isUnreliable else { return }
                draft.audioBlocks.append(MarkdownAudioBlock(range: node.range, media: media, isInline: true))
            case .iframe(let frame, let html, let display):
                guard !ctx.unsupported, !node.isUnreliable else { return }
                draft.iframeBlocks.append(MarkdownIframeBlock(range: node.range, html: html, displayHTML: display,
                                                              width: frame.width, height: frame.height, title: frame.title, isInline: true))
            case .svg(let data):
                guard !ctx.unsupported, !node.isUnreliable, let owner = ctx.owner else { return }
                draft.images.append(MarkdownImage(range: node.range, paragraphRange: owner, url: Self.svgURL(data), alt: "", title: nil, isInline: node.range != owner))
            case .ruby(let ruby):
                guard !ctx.unsupported, !node.isUnreliable else { return }
                draft.ruby.append(MarkdownRuby(range: node.range, baseRange: ruby.baseRange, readingRange: ruby.readingRange, base: ruby.base,
                                               reading: ruby.reading, baseRuns: ruby.baseRuns))
            case .wikiLink(let wiki):
                guard options.includeWikiLinks, !ctx.unsupported, !node.isUnreliable else { return }
                draft.wikiLinks.append(MarkdownWikiLink(node: node, wiki))
            case .formula(let source):
                if let formula = MarkdownFormula(node: node, source: source) { draft.inlineFormulas.append(formula) }
            case .footnoteReference:
                if !ctx.unsupported, footnoteReferences.contains(node.range) {
                    draft.spans.append(MarkdownPresentationSpan(range: node.range, kind: .link, markerRanges: []))
                }
            case .noteEmbed(let embed):
                guard !ctx.unsupported, !node.isUnreliable, let link = MarkdownPresentationBuilder.embedLink(range: node.range, embed, text: text) else { return }
                draft.wikiLinks.append(link)
            case .critic(let kind):
                // Цвет правок ставится и в сносках, но не в таблицах.
                guard !ctx.inTable, !node.isUnreliable else { return }
                draft.spans.append(MarkdownPresentationBuilder.criticSpan(node, kind: kind))
            case .comment:
                guard !ctx.inTable, !node.isUnreliable else { return }
                draft.spans.append(MarkdownPresentationBuilder.obsidianCommentSpan(range: node.range, markerRanges: node.markerRanges))
            case .text, .emoji, .softBreak, .hardBreak, .rawHTML:
                break
            }
        }

        /// Картинка `![…](…)` и `<img>`: блочная — единственная в абзаце; строчная — внутри абзаца, заголовка или ячейки таблицы.
        private mutating func addImage(_ node: MarkdownInlineNode, _ image: MarkdownInlineNode.Image, ctx: Context) {
            guard !node.isUnreliable, let owner = ctx.owner else { return }
            if ctx.unsupported && !ctx.inCell { return }
            let isHTML = image.syntax == .html
            if !isHTML, node.range.length < 4 { return }
            let block = !isHTML && image.isBlock && !ctx.unsupported
            draft.images.append(MarkdownImage(range: node.range, paragraphRange: owner, url: image.url, alt: image.alt, title: isHTML ? image.title : (image.title ?? ""),
                                              isInline: !block, sizing: image.sizing))
        }
    }
}

private extension MarkdownBlockNode {
    var isParagraphLike: Bool {
        switch kind {
        case .paragraph, .tableOfContents: return true
        default: return false
        }
    }
}
