import Foundation

/// Проекция выделения на `MarkdownDocumentModel` (U4.5.1): без AppKit и cmark.
/// Каркас: накопитель `ProjectionState`, помощники записи (`record/emit/appendBreaks/emitUnrepresented/emitImage/emitMedia`),
/// корневой цикл по блокам и сверка покрытия. Блоки (U4.5.2), строчные узлы (U4.5.3) и HTML-блоки (U4.5.4)
/// добавляются в `projectBlock`/`projectInline` и в `extension ProjectionState` своих файлов.
extension MarkdownClipboardCopyService {
    /// Вход копирования с оформлением: проекция выделения на модель документа (cmark здесь не используется).
    /// Текст всегда разбирается заново: модель редактора содержит wiki-ссылки, вставки заметок и CriticMarkup, которых копирование не знает.
    static func project(_ markdown: String, selection: NSRange, includeImages: Bool = false, documentURL: URL? = nil,
                                 allowRemoteImages: Bool = false, syntax: MarkdownSyntaxOptions = .init(),
                                 detailsOpenOverrides: [NSRange: Bool] = [:]) -> Fragment? {
        let raw = markdown as NSString
        guard selection.location != NSNotFound, selection.length > 0,
              selection.location <= raw.length, selection.length <= raw.length - selection.location,
              !markdown.utf8.contains(0) else { return nil }
        func boundary(_ position: Int) -> Bool {
            position == 0 || position == raw.length ||
                !((0xd800...0xdbff).contains(raw.character(at: position - 1)) && (0xdc00...0xdfff).contains(raw.character(at: position)))
        }
        guard boundary(selection.location), boundary(NSMaxRange(selection)) else { return nil }
        let options = MarkdownDocumentModel.Options(syntax: syntax, includes: [.emoji], isVaultNote: false, detectsFrontMatter: true)
        guard let document = MarkdownDocumentParser.parse(markdown, options: options, isCancelled: { Task.isCancelled }),
              !Task.isCancelled else { return nil }
        let candidates = (document.emoji?.candidates ?? [])
            .filter { NSIntersectionRange($0.range, selection).length > 0 }
            .sorted { $0.range.location < $1.range.location }
        var emoji: [String: String] = [:]
        if !candidates.isEmpty {
            guard !Task.isCancelled,
                  let resolved = try? EmojiShortcodeResolver.resolve(candidates.map(\.name), isCancelled: { Task.isCancelled }) else { return nil }
            emoji = resolved
        }
        let state = ProjectionState(markdown: markdown, selection: selection, includeImages: includeImages, documentURL: documentURL,
                                    allowRemoteImages: allowRemoteImages, syntax: syntax, detailsOpenOverrides: detailsOpenOverrides,
                                    emojiCandidates: candidates, emoji: emoji, model: document)
        return state.run(document)
    }

    /// Состояние одной проекции. Класс, чтобы подзадачи .2–.4 дописывали обход в своих файлах (`extension ProjectionState`),
    /// не передавая накопители через замыкания.
    final class ProjectionState {
        // Входы (не меняются).
        let markdown: String
        let raw: NSString
        let selection: NSRange
        let includeImages: Bool
        let documentURL: URL?
        let allowRemoteImages: Bool
        let syntax: MarkdownSyntaxOptions
        let detailsOpenOverrides: [NSRange: Bool]
        let emojiCandidates: [MarkdownEmojiCandidate]
        let emoji: [String: String]
        /// Модель, по которой идёт проекция (подзадачи берут из неё `footnotes`, `emoji` и т. п.).
        let model: MarkdownDocumentModel

        // Накопители результата.
        var output = "", html = ""
        var runs: [Run] = []
        var structuralParts: [Fragment.StructuralPart] = []
        var imageLinks: [String?] = []
        var remoteImages: [Fragment.RemoteImage] = []
        var mathExpressions: [Fragment.MathExpression] = []
        var mathImages: [Fragment.MathImage] = []
        /// Исходные диапазоны, уже представленные узлами; остальное выделение должно быть пробелами, переводами строк и `>`.
        var covered: [NSRange] = []
        /// Диапазоны цитат: `>` внутри них разрешён в зазорах.
        var quoteRanges: [NSRange] = []
        /// Конец последнего записанного куска в исходнике (нужен для переводов строк между кусками).
        var lastEnd: Int?
        /// Любое сомнение: результат `nil`.
        var invalid = false
        var hasStructuralOutput = false
        var hasUnverifiedHTMLBlocks = false
        var mathContextValid = true
        var pendingSoftBreak = false
        /// Накопленный текст соседних `.text`/`.emoji` узлов (см. `projectInlines`).
        var textBuffer: (value: String, range: NSRange)?
        /// Число цитат в исходнике вокруг текущего узла: столько `>` пропускает `emitUnrepresented(quotePrefixes:)`.
        var sourceQuoteDepth = 0
        /// Виды объемлющих блоков текущего узла (корень — пусто): родитель решает, можно ли писать цитату, заголовок, `hr` (U4.5.2).
        var blockParents: [MarkdownBlockNode.Kind] = []
        /// Индекс формулы в `mathExpressions` по диапазону исходника (`$…$` или блок `$$…$$`).
        private var mathIndices: [NSRange: Int] = [:]

        // Заготовки подзадач. Узлы cmark заменены диапазонами исходника (`OpaquePointer` в модели нет).
        /// Номер сноски по метке определения `[^x]:` (диапазон маркера → номер cmark из `model.footnotes`), U4.5.2.
        var footnoteNumbers: [NSRange: Int] = [:]
        /// Подтверждённые картинки `<img>` по диапазону тега, U4.5.3.
        var htmlImages: [NSRange: MarkdownInlineNode.Image] = [:]
        /// Диапазоны тегов строчного HTML в сыром контексте (`<script>`, `<style>`…) и `<template>`; строится лениво, U4.5.3.
        var blockedState: (regions: [NSRange], selectionHit: Bool)?
        /// HTML строчных `<audio>`/`<video>` после разбора cmark по диапазону узла; считается один раз при первом media, U4.5.5.
        var mediaFallbackHTML: [NSRange: String]?
        /// Подтверждённые блоки медиа/iframe/svg (диапазон блока целиком), U4.5.4.
        var confirmedMediaBlocks = Set<NSRange>()
        /// Участки, занятые медиа (для проверки порядка и границ выделения), U4.5.4.
        var mediaRegions: [NSRange] = []
        /// `<details>` выделения: диапазон блока и разобранный блок, U4.5.4.
        var detailsCandidates: [(range: NSRange, details: MarkdownDetailsBlock)] = []
        /// В выделенном HTML-блоке есть картинка (для `includeImages`), U4.5.4.
        var selectedHTMLBlockHasImage = false
        /// Выделение режет медиа: результат `nil`, U4.5.4.
        var unsupportedMediaSelection = false
        /// Общие данные доказательств HTML-блоков, считаются один раз на проекцию (`+HTML.swift`), U4.5.4.
        var htmlProof = HTMLProofCache()

        // Положение в структуре (для `record`).
        var insideTable = false
        var quoteDepth = 0, listDepth = 0, tableCount = 0
        var headingLevel: Int?
        var tableCell: Fragment.TableCell?

        private var paths: MarkdownResourcePaths?
        private var pathsLoaded = false

        init(markdown: String, selection: NSRange, includeImages: Bool, documentURL: URL?, allowRemoteImages: Bool,
             syntax: MarkdownSyntaxOptions, detailsOpenOverrides: [NSRange: Bool],
             emojiCandidates: [MarkdownEmojiCandidate], emoji: [String: String], model: MarkdownDocumentModel) {
            self.model = model
            footnoteNumbers = model.footnoteNumbers
            self.markdown = markdown
            self.raw = markdown as NSString
            self.selection = selection
            self.includeImages = includeImages
            self.documentURL = documentURL
            self.allowRemoteImages = allowRemoteImages
            self.syntax = syntax
            self.detailsOpenOverrides = detailsOpenOverrides
            self.emojiCandidates = emojiCandidates
            self.emoji = emoji
        }

        // MARK: - Корневой цикл

        /// Экранирование HTML фрагмента: `& < > "` (без `'`). Формат фрагмента отличается от страницы, не заменять
        /// на `MarkdownHTMLRenderer.escapeHTML` (U4.5, п. 3).
        static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }

        func escape(_ text: String) -> String { Self.escape(text) }

        /// Контейнеры берут диапазон и маркеры, даже если помечены ненадёжными (U4.5.0, П3): ненадёжный лист внутри
        /// даст `nil` сам. Лист с `isUnreliable` на корне — порядок блоков неизвестен.
        func isContainer(_ kind: MarkdownBlockNode.Kind) -> Bool {
            switch kind {
            case .quote, .callout, .alert, .list, .listItem, .footnoteDefinition: return true
            default: return false
            }
        }

        /// Диапазон корневого блока целиком; у определения сноски — вместе с маркером `[^x]:`.
        func rootRange(_ block: MarkdownBlockNode) -> NSRange? {
            guard block.isUnreliable == false || isContainer(block.kind) else { return nil }
            let range = block.range
            guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= raw.length else { return nil }
            if case .footnoteDefinition = block.kind {
                guard let marker = block.markerRanges.first, marker.location >= 0, NSMaxRange(marker) <= raw.length else { return nil }
                return NSUnionRange(marker, range)
            }
            return range
        }

        func run(_ model: MarkdownDocumentModel) -> Fragment? {
            let blocks = model.blocks
            if markdown.contains("$") {
                guard buildMathCatalog() else { return nil }
            }
            var wholes: [NSRange] = []
            wholes.reserveCapacity(blocks.count)
            var orderKnown = true, hasSelectedDefinition = false, previousEnd = 0
            for block in blocks {
                if Task.isCancelled { return nil }
                guard let whole = rootRange(block) else { orderKnown = false; wholes.append(NSRange(location: NSNotFound, length: 0)); continue }
                if case .footnoteDefinition = block.kind, NSIntersectionRange(whole, selection).length > 0 { hasSelectedDefinition = true }
                if whole.location < previousEnd { orderKnown = false }
                previousEnd = max(previousEnd, NSMaxRange(whole))
                wholes.append(whole)
            }
            if orderKnown {
                // Бинарный поиск первого блока, заканчивающегося правее начала выделения; дальше — только пересекающие.
                var low = 0, high = wholes.count
                while low < high {
                    let middle = (low + high) / 2
                    if NSMaxRange(wholes[middle]) <= selection.location { low = middle + 1 } else { high = middle }
                }
                var cursor = low > 0 ? NSMaxRange(wholes[low - 1]) : 0
                var index = low
                while index < blocks.count, wholes[index].location < NSMaxRange(selection) {
                    if Task.isCancelled { return nil }
                    if cursor < wholes[index].location {
                        emitUnrepresented(NSRange(location: cursor, length: wholes[index].location - cursor))
                    }
                    // Front matter пропускается как блок: он копируется одним зазором вместе с пустыми строками после него.
                    if case .frontMatter = blocks[index].kind { index += 1; continue }
                    projectBlock(blocks[index], style: Style())
                    cursor = NSMaxRange(wholes[index])
                    index += 1
                }
                if cursor < raw.length { emitUnrepresented(NSRange(location: cursor, length: raw.length - cursor)) }
            } else if hasSelectedDefinition {
                return nil
            } else {
                for (index, block) in blocks.enumerated() {
                    if Task.isCancelled { return nil }
                    if wholes[index].location != NSNotFound, NSIntersectionRange(wholes[index], selection).length == 0 { continue }
                    projectBlock(block, style: Style())
                }
            }
            return finish()
        }

        /// Сверка покрытия: выделение целиком покрыто узлами либо состоит из пробелов, переводов строк и `>` цитаты.
        private func finish() -> Fragment? {
            guard !Task.isCancelled else { return nil }
            let orderedCoverage = covered.sorted { $0.location < $1.location }
            let quotes = quoteRanges.sorted { $0.location < $1.location }
            var quoteEnds: [Int] = [], maxQuoteEnd = 0
            for range in quotes { maxQuoteEnd = max(maxQuoteEnd, NSMaxRange(range)); quoteEnds.append(maxQuoteEnd) }
            var quoteLine = NSRange(location: NSNotFound, length: 0), quoteChecked = 0, quotePrefixValid = true
            func isQuoteMarker(_ offset: Int) -> Bool {
                var low = 0, high = quotes.count
                while low < high {
                    let middle = (low + high) / 2
                    if quotes[middle].location <= offset { low = middle + 1 } else { high = middle }
                }
                guard low > 0, quoteEnds[low - 1] > offset else { return false }
                if quoteLine.location == NSNotFound || offset >= NSMaxRange(quoteLine) {
                    quoteLine = raw.lineRange(for: NSRange(location: offset, length: 0))
                    quoteChecked = quoteLine.location
                    quotePrefixValid = true
                }
                while quoteChecked < offset {
                    if Task.isCancelled { return false }
                    let unit = raw.character(at: quoteChecked)
                    if unit != 32 && unit != 9 && unit != 62 { quotePrefixValid = false }
                    quoteChecked += 1
                }
                return quotePrefixValid
            }
            var cursor = selection.location
            for range in orderedCoverage {
                if Task.isCancelled { return nil }
                let end = min(NSMaxRange(selection), range.location)
                while cursor < end {
                    if Task.isCancelled { return nil }
                    let unit = raw.character(at: cursor)
                    if unit != 32 && unit != 9 && unit != 10 && unit != 13 && !(unit == 62 && isQuoteMarker(cursor)) { return nil }
                    cursor += 1
                }
                cursor = max(cursor, min(NSMaxRange(selection), NSMaxRange(range)))
                if cursor == NSMaxRange(selection) { break }
            }
            while cursor < NSMaxRange(selection) {
                if Task.isCancelled { return nil }
                let unit = raw.character(at: cursor)
                if unit != 32 && unit != 9 && unit != 10 && unit != 13 && !(unit == 62 && isQuoteMarker(cursor)) { return nil }
                cursor += 1
            }
            if let lastEnd, lastEnd < NSMaxRange(selection) {
                appendBreaks(in: NSRange(location: lastEnd, length: NSMaxRange(selection) - lastEnd))
            }
            if lastEnd == nil, raw.substring(with: selection).utf16.allSatisfy({ $0 == 13 || $0 == 10 }) {
                appendBreaks(in: selection)
            }
            guard !invalid, !Task.isCancelled, (mathImages.isEmpty || mathContextValid), !output.isEmpty || hasStructuralOutput else { return nil }
            return Fragment(text: output, html: html, runs: runs, imageLinks: imageLinks, remoteImages: remoteImages, structuralParts: structuralParts,
                            mathExpressions: mathExpressions, mathImages: mathImages, hasUnverifiedHTMLBlocks: hasUnverifiedHTMLBlocks)
        }

        // MARK: - Точки расширения

        /// Блок модели. U4.5.2 — заголовок, цитаты, списки, код, таблица, сноски, `hr`; U4.5.4 — HTML-блоки.
        /// Пока нереализованное ставит `invalid` (результат `nil`): так же отвечает проектор при сомнении.
        func projectBlock(_ block: MarkdownBlockNode, style: Style) {
            if Task.isCancelled { invalid = true; return }
            switch block.kind {
            case .paragraph:
                projectParagraph(block, style: style)
            case .frontMatter:
                break // уже учтён зазором в `run`
            case .heading, .quote, .callout, .alert, .list, .listItem, .codeBlock, .mathBlock, .table, .thematicBreak, .footnoteDefinition:
                projectStructureBlock(block, style: style) // +Blocks.swift, U4.5.2
            case let .html(htmlBlock):
                projectHTMLBlock(block, htmlBlock: htmlBlock, style: style) // +HTML.swift, U4.5.4
            case .tableOfContents:
                // `[toc]` копируется как обычный абзац из одного текстового узла.
                let tocRange = NSRange(location: block.range.location, length: 5)
                guard tocRange.location >= 0, NSMaxRange(tocRange) <= raw.length,
                      raw.substring(with: tocRange) == "[toc]" else { invalid = true; return }
                let literal = raw.substring(with: tocRange)
                var paragraph = block
                paragraph.kind = .paragraph
                paragraph.range = tocRange
                paragraph.inlines = [MarkdownInlineNode(kind: .text(literal), range: tocRange, markerRanges: [], children: [], isUnreliable: false)]
                projectParagraph(paragraph, style: style)
            case .noteEmbed, .comment:
                invalid = true // не включаются в разбор копирования
            }
        }

        /// Список соседних строчных узлов одного стиля. Соседние `.text`/`.emoji` склеиваются в один `emit` на общий диапазон
        /// (текст пишется одним куском: один run, эмодзи подставляются внутри него). Склейки по стилю нет.
        /// Абзац и подзадачи U4.5.2/.3 обходят дочерние узлы только через эту функцию.
        func projectInlines(_ nodes: [MarkdownInlineNode], style: Style) {
            for node in nodes {
                if Task.isCancelled { invalid = true; return }
                switch node.kind {
                case .text, .emoji:
                    projectInlineNode(node, style: style)
                default:
                    flushText(style: style)
                    projectInlineNode(node, style: style)
                }
                if invalid { return }
            }
            flushText(style: style)
        }

        /// Один узел (для вызовов с одиночным узлом).
        func projectInline(_ node: MarkdownInlineNode, style: Style) {
            projectInlines([node], style: style)
        }

        /// Копит текст в `textBuffer`, пока куски идут вплотную друг к другу в исходнике.
        func bufferText(_ value: String, sourceRange: NSRange, style: Style) {
            if let buffered = textBuffer {
                if NSMaxRange(buffered.range) == sourceRange.location {
                    textBuffer = (buffered.value + value, NSUnionRange(buffered.range, sourceRange))
                    return
                }
                flushText(style: style)
                if invalid { return }
            }
            textBuffer = (value, sourceRange)
        }

        func flushText(style: Style) {
            guard let buffered = textBuffer else { return }
            textBuffer = nil
            emit(buffered.value, sourceRange: buffered.range, style: style, collapseSpaces: true)
        }

        /// Строчный узел модели. U4.5.3 — стили, код, ссылки, картинки, формулы, эмодзи, ruby, svg, media, iframe.
        func projectInlineNode(_ node: MarkdownInlineNode, style: Style) {
            if Task.isCancelled { invalid = true; return }
            if node.isUnreliable {
                // Ненадёжный узел вне выделения не мешает: покрытие проверяется только внутри выделения.
                if node.range.location >= 0, NSMaxRange(node.range) <= raw.length, NSIntersectionRange(node.range, selection).length == 0 { return }
                invalid = true
                return
            }
            switch node.kind {
            case let .text(literal):
                // Теги внутри `<script>`/`<template>` не копируются; текст и эмодзи там копируются как в панели.
                if NSIntersectionRange(node.range, selection).length > 0, selectionHitsBlockedRegion() { invalid = true; return }
                projectText(literal, range: node.range, style: style)
            case .emoji:
                // Модель выделяет `:имя:` отдельным узлом; подстановку эмодзи делает `emit` по кандидатам. Частично
                // выделенный шорткод `emit` отвергает (`invalid`).
                let part = NSIntersectionRange(selection, node.range)
                guard part.length > 0 else { return }
                if selectionHitsBlockedRegion() { invalid = true; return }
                bufferText(raw.substring(with: part), sourceRange: part, style: style)
            case .softBreak:
                pendingSoftBreak = true
            case .hardBreak:
                pendingSoftBreak = false
            case .code, .strong, .emphasis, .strikethrough, .underline, .keyboard, .highlight, .subscriptText, .superscriptText,
                 .inlineStyle, .link, .image, .media, .iframe, .svg, .ruby, .formula, .footnoteReference, .rawHTML:
                projectStyledInline(node, style: style) // +Inlines.swift, U4.5.3
            case .wikiLink, .noteEmbed, .critic, .comment:
                invalid = true // не включаются в разбор копирования
            }
        }

        /// Простой текст (без кода): целиком, часть дословного текста либо часть через доказанное соответствие.
        func projectText(_ literal: String, range: NSRange, style: Style) {
            guard range.location >= 0, NSMaxRange(range) <= raw.length else { invalid = true; return }
            guard NSIntersectionRange(selection, range).length > 0 else { return }
            let spelling = raw.substring(with: range) as NSString
            var mappedValue: String?
            var mappedRange: NSRange?
            if spelling as String != literal {
                if selection.location <= range.location && NSMaxRange(selection) >= NSMaxRange(range) {
                    guard MarkdownInlineTextProjection.pieces(spelling: spelling, literal: literal, sourceOffset: range.location,
                                                              isCancelled: { Task.isCancelled }) != nil else { invalid = true; return }
                    bufferText(literal, sourceRange: range, style: style)
                    return
                }
                guard let pieces = MarkdownInlineTextProjection.pieces(spelling: spelling, literal: literal, sourceOffset: range.location),
                      let selected = MarkdownReadableText.selected(pieces, in: selection) else { invalid = true; return }
                guard let mapped = selected.1 else { return }
                mappedRange = mapped
                mappedValue = selected.0
            }
            let clipped = mappedRange ?? NSIntersectionRange(selection, range)
            guard clipped.length > 0 else { return }
            bufferText(mappedValue ?? raw.substring(with: clipped), sourceRange: clipped, style: style)
        }

        // MARK: - Формулы

        /// Все формулы документа в порядке исходника (`mathNodes`): `mathExpressions` уходит во `Fragment`
        /// целиком, индексы `mathImages` ссылаются на него. Строится один раз, если в тексте есть `$`.
        /// Формула с диапазоном, не совпадающим с `$…$`, делает контекст недостоверным (`mathContextValid`).
        func buildMathCatalog() -> Bool {
            var found: [Fragment.MathExpression] = []
            // Формулы внутри `<template>` и сырых контекстов (`<script>`, `<style>`…) в каталог не попадают
            // (модель их создаёт), копирование такой формулы целиком даёт nil.
            var context = MarkdownImageUploadService.HTMLContext(), templateDepth = 0, lastHTMLPosition = 0
            func consumeHTML(range: NSRange, unreliable: Bool) {
                guard !unreliable, range.location >= lastHTMLPosition else { context.invalidate(); return }
                _ = context.consume(source: raw, range: range, isCancelled: { Task.isCancelled }, confirmedTag: { _, name, closing in
                    if name == "template" { templateDepth = closing ? max(0, templateDepth - 1) : templateDepth + 1 }
                })
                lastHTMLPosition = NSMaxRange(range)
            }
            func inlineFormulas(_ nodes: [MarkdownInlineNode]) -> Bool {
                for node in nodes {
                    if Task.isCancelled { return false }
                    if case .rawHTML = node.kind { consumeHTML(range: node.range, unreliable: node.isUnreliable) }
                    if case let .formula(source) = node.kind, !context.inRawContext, templateDepth == 0 {
                        let range = node.range
                        guard !node.isUnreliable, range.length >= 2, range.location >= 0, NSMaxRange(range) <= raw.length,
                              raw.character(at: range.location) == 36, raw.character(at: NSMaxRange(range) - 1) == 36 else {
                            mathContextValid = false; continue
                        }
                        found.append(.init(source: source, display: false, range: range))
                    }
                    if !inlineFormulas(node.children) { return false }
                }
                return true
            }
            func visit(_ blocks: [MarkdownBlockNode]) -> Bool {
                for block in blocks {
                    if Task.isCancelled { return false }
                    if case .html = block.kind { consumeHTML(range: block.range, unreliable: block.isUnreliable) }
                    if case let .mathBlock(source) = block.kind, !context.inRawContext, templateDepth == 0 {
                        guard !block.isUnreliable, block.range.location >= 0, NSMaxRange(block.range) <= raw.length else { mathContextValid = false; continue }
                        found.append(.init(source: source, display: true, range: block.range))
                    }
                    if case let .table(table) = block.kind {
                        for row in table.rows { for cell in row.cells where !inlineFormulas(cell.inlines) { return false } }
                    }
                    if !inlineFormulas(block.inlines) || !visit(block.children) { return false }
                }
                return true
            }
            guard visit(model.blocks) else { return false }
            found.sort { $0.range.location < $1.range.location }
            mathExpressions = found
            mathIndices = Dictionary(found.enumerated().map { ($0.element.range, $0.offset) }, uniquingKeysWith: { first, _ in first })
            return true
        }

        /// Строчная формула `$…$`: выделение обязано покрыть её целиком. В HTML вместо текста идёт `<img src="LACCOPYMATH…">`,
        /// токен потом заменяется картинкой (`resolveMath`). Блочные формулы (`display`) не копируются: `invalid`.
        func emitInlineMath(range: NSRange, style: Style) {
            guard let index = mathIndices[range], !mathExpressions[index].display else {
                if NSIntersectionRange(range, selection).length > 0 { invalid = true }
                return
            }
            guard NSIntersectionRange(range, selection).length > 0 else { return }
            guard selection.location <= range.location, NSMaxRange(selection) >= NSMaxRange(range) else { invalid = true; return }
            let value = raw.substring(with: range)
            let htmlStart = (html as NSString).length
            emit(value, sourceRange: range, style: style)
            guard !invalid else { return }
            var token: String
            repeat { token = "LACCOPYMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
            while markdown.contains(token) || html.contains(token)
            let rendered = html as NSString
            let match = rendered.range(of: escape(value), options: .backwards,
                                       range: NSRange(location: htmlStart, length: rendered.length - htmlStart))
            guard match.location != NSNotFound else { invalid = true; return }
            let replaced = NSMutableString(string: html)
            replaced.replaceCharacters(in: match, with: "<img src=\"\(token)\" alt=\"\(escape(value))\">")
            html = replaced as String
            mathImages.append(.init(token: token, expressionIndex: index))
            imageLinks.append(style.link)
            hasStructuralOutput = true
        }

        // MARK: - Запись результата

        func record(_ text: String, kind: Fragment.StructuralPart.Kind = .text) {
            structuralParts.append(.init(text: text, quoteDepth: quoteDepth, listDepth: listDepth,
                                         headingLevel: headingLevel, tableCell: tableCell, kind: kind))
        }

        /// Переводы строк исходника между кусками: `\r\n` и `\r` считаются одним `\n`.
        func appendBreaks(in range: NSRange) {
            guard range.length > 0 else { return }
            let between = raw.substring(with: range).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let breaks = String(between.filter { $0 == "\n" })
            if pendingSoftBreak && !syntax.preserveEditingSoftBreaks && breaks.count == 1 {
                output += " "
                html += " "
                record(" ")
                pendingSoftBreak = false
                return
            }
            output += breaks
            html += String(repeating: "<br>", count: breaks.count)
            for _ in breaks { record("\n", kind: .lineBreak) }
            pendingSoftBreak = false
        }

        func emit(_ value: String, sourceRange: NSRange, style: Style, collapseSpaces: Bool = false, preserveSelectedSpaces: Bool = false, htmlContent: String? = nil) {
            var low = 0, high = emojiCandidates.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(emojiCandidates[middle].range) <= sourceRange.location { low = middle + 1 } else { high = middle }
            }
            var replacements: [(range: NSRange, text: String)] = []
            while low < emojiCandidates.count && emojiCandidates[low].range.location < NSMaxRange(sourceRange) {
                let candidate = emojiCandidates[low]
                if let resolved = emoji[candidate.name] {
                    guard candidate.range.location >= sourceRange.location, NSMaxRange(candidate.range) <= NSMaxRange(sourceRange) else { invalid = true; return }
                    replacements.append((candidate.range, resolved))
                }
                low += 1
            }
            var value = value
            if !replacements.isEmpty {
                let spelling = raw.substring(with: sourceRange) as NSString
                guard let pieces = MarkdownInlineTextProjection.pieces(spelling: spelling, literal: value, sourceOffset: sourceRange.location, isCancelled: { Task.isCancelled }),
                      let projection = MarkdownReadableText(sourceLength: raw.length,
                        fragments: [.init(sourceRange: sourceRange, text: value, matchesSource: false, pieces: pieces)],
                        unsupportedRanges: []).replacingEmojiText(replacements, isCancelled: { Task.isCancelled }),
                      let mapped = projection.text(isCancelled: { Task.isCancelled }) else { invalid = true; return }
                value = mapped
            }
            if collapseSpaces && !(syntax.preserveEditingWhitespace ?? false) {
                let units = value as NSString
                var position = 0, runStart = 0, lastWasSpace = false
                let collapsed = NSMutableString(string: "")
                while position < units.length {
                    if Task.isCancelled { invalid = true; return }
                    let unit = units.character(at: position)
                    if unit == 32 && lastWasSpace {
                        if position > runStart { collapsed.append(units.substring(with: NSRange(location: runStart, length: position - runStart))) }
                        runStart = position + 1
                    }
                    lastWasSpace = unit == 32
                    position += 1
                }
                if position > runStart { collapsed.append(units.substring(with: NSRange(location: runStart, length: position - runStart))) }
                value = collapsed as String
            }
            let precedingEnd = lastEnd ?? selection.location
            if !insideTable && sourceRange.location > precedingEnd {
                appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: sourceRange.location - precedingEnd)))
            }
            pendingSoftBreak = false
            record(value)
            let resultRange = NSRange(location: (output as NSString).length, length: (value as NSString).length)
            output += value
            runs.append(Run(range: resultRange, bold: style.bold, italic: style.italic, strike: style.strike,
                            underline: style.underline, highlight: style.highlight, script: style.script, code: style.code || style.keyboard, link: style.link, inlineStyle: style.inlineStyle))
            var fragment = htmlContent ?? escape(value)
            if preserveSelectedSpaces || (collapseSpaces && syntax.preserveEditingWhitespace == true) {
                fragment = "<span style=\"white-space:break-spaces\">" + fragment + "</span>"
            }
            if style.code { fragment = "<code>" + fragment + "</code>" }
            if style.keyboard { fragment = "<kbd>" + fragment + "</kbd>" }
            html += wrapStyle(fragment, style: style)
            lastEnd = NSMaxRange(sourceRange)
        }

        /// Теги стилей вокруг готового HTML: `del`, `u`, `mark`, `sub/sup`, `em`, `strong`, `span style`, `a`.
        /// `kbd` и `code` оборачивает вызывающий (у медиа и картинок их нет).
        func wrapStyle(_ content: String, style: Style) -> String {
            var fragment = content
            if style.strike { fragment = "<del>" + fragment + "</del>" }
            if style.underline { fragment = "<u>" + fragment + "</u>" }
            if style.highlight { fragment = "<mark>" + fragment + "</mark>" }
            if style.script != 0 { let tag = style.script < 0 ? "sub" : "sup"; fragment = "<\(tag)>" + fragment + "</\(tag)>" }
            if style.italic { fragment = "<em>" + fragment + "</em>" }
            if style.bold { fragment = "<strong>" + fragment + "</strong>" }
            if let inlineStyle = style.inlineStyle { fragment = "<span style=\"" + inlineStyle.editingCSS + "\">" + fragment + "</span>" }
            if let link = style.link { fragment = "<a href=\"" + escape(link) + "\">" + fragment + "</a>" }
            return fragment
        }

        /// Зазор между узлами: пробелы и `>` цитаты не пишутся, видимый текст — как код (`<code>` / `<pre>` при переводах строк).
        func emitUnrepresented(_ gap: NSRange, quotePrefixes: Int = 0, structuralPrefixes: [Int: (end: Int, tab: Int?, padding: Int)] = [:]) {
            let selected = NSIntersectionRange(gap, selection)
            guard selected.length > 0 else { return }
            let literal = NSMutableString(string: "")
            var containsText = false, multiline = false, position = selected.location
            while position < NSMaxRange(selected) {
                if Task.isCancelled { return }
                let line = raw.lineRange(for: NSRange(location: position, length: 0))
                var prefix = line.location
                if let structural = structuralPrefixes[line.location] {
                    prefix = structural.end
                    if let tab = structural.tab, tab >= position, tab < NSMaxRange(selected), structural.padding > 0 {
                        literal.append(String(repeating: " ", count: structural.padding))
                        containsText = true
                    }
                }
                else { for _ in 0..<quotePrefixes {
                    while prefix < NSMaxRange(line), raw.character(at: prefix) == 32 || raw.character(at: prefix) == 9 {
                        if Task.isCancelled { return }
                        prefix += 1
                    }
                    guard prefix < NSMaxRange(line), raw.character(at: prefix) == 62 else { invalid = true; return }
                    prefix += 1
                    if prefix < NSMaxRange(line), raw.character(at: prefix) == 32 || raw.character(at: prefix) == 9 { prefix += 1 }
                } }
                let end = min(NSMaxRange(selected), NSMaxRange(line))
                let contentStart = min(end, max(position, prefix))
                while position < end {
                    if Task.isCancelled { return }
                    let unit = raw.character(at: position)
                    if position >= contentStart {
                        if unit == 10 || unit == 13 { multiline = true }
                        else if unit != 32 && unit != 9 { containsText = true }
                    }
                    position += 1
                }
                if contentStart < end { literal.append(raw.substring(with: NSRange(location: contentStart, length: end - contentStart))) }
            }
            guard containsText, !Task.isCancelled else { return }
            covered.append(selected)
            var code = Style(); code.code = true
            if multiline { html += "<pre>" }
            emit(literal as String, sourceRange: selected, style: code)
            if multiline { html += "</pre>" }
        }

        /// Каталоги ресурсов нужны только для адресов от корня; грузятся один раз.
        func resourcePaths(for address: String) -> (paths: MarkdownResourcePaths?, failed: Bool) {
            if MarkdownResourcePaths.requiresRoot(address) && !pathsLoaded {
                paths = try? MarkdownResourcePaths(text: markdown, document: documentURL)
                pathsLoaded = true
            }
            return (paths, MarkdownResourcePaths.requiresRoot(address) && paths == nil)
        }

        func emitImage(range: NSRange, address: String, alt: String, title: String, css: String, style: Style,
                       inlineOwners: [MarkdownHTMLMediaService.ImageAncestor] = []) {
            let uri: String
            if allowRemoteImages, let url = URL(string: address),
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                uri = url.absoluteString
            } else {
                let loaded = resourcePaths(for: address)
                guard !loaded.failed,
                      let payload = try? MarkdownImageUploadService.payload(address: address, document: documentURL, paths: loaded.paths) else { invalid = true; return }
                uri = MarkdownImageUploadService.dataURI(payload, address: address)
            }
            let precedingEnd = lastEnd ?? selection.location
            if !insideTable && range.location > precedingEnd { appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: range.location - precedingEnd))) }
            output += alt
            record(alt, kind: .image)
            let titleAttribute = title.isEmpty ? "" : " title=\"" + escape(title) + "\""
            let sizing = css.isEmpty ? "" : " style=\"" + escape(css) + "\""
            let encodedURI = escape(uri)
            let image = "<img src=\"" + encodedURI + "\" alt=\"" + escape(alt) + "\"" + titleAttribute + sizing + ">"
            var starts: [String] = [], ends: [String] = []
            func wrap(_ open: String, _ close: String) { starts.append(open); ends.insert(close, at: 0) }
            if let link = style.link { wrap("<a href=\"" + escape(link) + "\">", "</a>") }
            if let inline = style.inlineStyle { wrap("<span style=\"" + inline.editingCSS + "\">", "</span>") }
            for owner in inlineOwners where owner.name != "div" && owner.name != "p" {
                if let value = owner.style { wrap("<span style=\"" + value.editingCSS + "\">", "</span>") }
                else { wrap("<" + owner.name + ">", "</" + owner.name + ">") }
            }
            let opening = starts.joined()
            if allowRemoteImages, let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                let location = (html as NSString).length + (opening as NSString).length + ("<img src=\"" as NSString).length
                remoteImages.append(.init(range: NSRange(location: location, length: (encodedURI as NSString).length), url: url))
            }
            html += opening + image + ends.joined()
            imageLinks.append(style.link)
            hasStructuralOutput = true
            lastEnd = NSMaxRange(range)
        }

        /// Подтверждённое медиа (`audio`/`video`/`iframe`): `html` — исходный тег, `expected` — что доказал разбор.
        func emitMedia(range: NSRange, html mediaHTML: String, expected: MarkdownHTMLMediaService.ProvenMedia, style: Style) {
            var unresolved = false
            func resolve(_ address: String) -> String {
                if let url = URL(string: address), let scheme = url.scheme?.lowercased(),
                   ["http", "https"].contains(scheme), url.host != nil { return url.absoluteString }
                let loaded = resourcePaths(for: address)
                guard !loaded.failed,
                      let url = try? MarkdownImageUploadService.localURL(address: address, document: documentURL, paths: loaded.paths) else {
                    unresolved = true
                    return "data:,"
                }
                return url.absoluteString
            }
            guard let value = MarkdownHTMLMediaService.copyMediaHTML(mediaHTML, expected: expected,
                resolveMedia: resolve, isCancelled: { Task.isCancelled }), !unresolved else { invalid = true; return }
            let precedingEnd = lastEnd ?? selection.location
            if !insideTable && range.location > precedingEnd {
                appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: range.location - precedingEnd)))
            }
            var fragment = value
            if style.keyboard { fragment = "<kbd>" + fragment + "</kbd>" }
            html += wrapStyle(fragment, style: style)
            covered.append(range)
            hasStructuralOutput = true
            // Confirmed standalone images have a safe structural RTF
            // representation; opaque media/HTML blocks must still reject
            // RTF to avoid advertising lossy rich clipboard data.
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<img") {
                hasUnverifiedHTMLBlocks = true
            }
            lastEnd = NSMaxRange(range)
        }
    }
}
