import Foundation

/// Строчные узлы модели (U4.5.3): код, стили, ссылка, картинка, формула, сноска, перенос `<br>`, ruby, svg, media, iframe.
/// Текст, эмодзи и мягкие переносы разбирает общий `projectInlineNode`; дочерние узлы обходятся только через `projectInlines`.
extension MarkdownClipboardCopyService.ProjectionState {
    func projectStyledInline(_ node: MarkdownInlineNode, style: MarkdownClipboardCopyService.Style) {
        if NSIntersectionRange(node.range, selection).length > 0, selectionHitsBlockedRegion() { invalid = true; return }
        switch node.kind {
        case let .code(literal):
            projectCode(literal, node: node, style: style)
        case .strong: projectWrapper(node, style: style) { $0.bold = true }
        case .emphasis: projectWrapper(node, style: style) { $0.italic = true }
        case .strikethrough: projectWrapper(node, style: style) { $0.strike = true }
        case .underline: projectWrapper(node, style: style) { $0.underline = true }
        case .highlight: projectWrapper(node, style: style) { $0.highlight = true }
        case .subscriptText: projectWrapper(node, style: style) { $0.script = -1 }
        case .superscriptText: projectWrapper(node, style: style) { $0.script = 1 }
        case .keyboard: projectWrapper(node, style: style) { $0.keyboard = true }
        case let .inlineStyle(value):
            projectWrapper(node, style: style) { styled in styled.inlineStyle = styled.inlineStyle.map { value.inheriting($0) } ?? value }
        case let .link(link):
            guard NSIntersectionRange(node.range, selection).length > 0 else { return }
            // Адрес с неподдерживаемой схемой (`javascript:` и т. п.) не копируется; вложенная HTML-ссылка тоже.
            if let scheme = URLComponents(string: link.url)?.scheme?.lowercased(), !["http", "https", "mailto"].contains(scheme) {
                invalid = true; return
            }
            if link.form == .html, style.link != nil { invalid = true; return }
            // Автоссылка `<https://…>` — не пара HTML-тегов, хотя её маркер начинается с `<`.
            projectWrapper(node, style: style, htmlPair: link.form == .html) { $0.link = link.url }
            if !invalid { lastEnd = max(lastEnd ?? 0, min(NSMaxRange(node.range), NSMaxRange(selection))) }
        case let .image(image):
            projectImage(image, node: node, style: style)
        case let .media(media):
            projectMedia(node, expected: .media(media), style: style)
        case let .iframe(frame, _, _):
            projectMedia(node, expected: .frame(frame), style: style)
        case let .svg(data):
            guard NSIntersectionRange(node.range, selection).length > 0 else { return }
            guard includeImages, coversWhole(node.range) else { invalid = true; return }
            covered.append(node.range)
            emitImage(range: node.range, address: "data:image/svg+xml;base64," + data.base64EncodedString(), alt: "", title: "", css: "", style: style)
        case let .ruby(ruby):
            projectRuby(ruby, node: node, style: style)
        case .formula:
            emitInlineMath(range: node.range, style: style)
        case let .footnoteReference(label):
            projectFootnoteReference(label, node: node, style: style)
        case .rawHTML:
            projectRawHTML(node, style: style)
        default:
            invalid = true // остальные виды сюда не приходят (см. `projectInlineNode`)
        }
    }

    /// Выделение целиком накрывает диапазон узла.
    private func coversWhole(_ range: NSRange) -> Bool {
        selection.location <= range.location && NSMaxRange(selection) >= NSMaxRange(range)
    }

    /// Узел со стилем: дети идут с добавленным оформлением. У пары тегов `<u>…</u>` выделение не должно резать сам тег.
    private func projectWrapper(_ node: MarkdownInlineNode, style: MarkdownClipboardCopyService.Style, htmlPair: Bool? = nil,
                                _ apply: (inout MarkdownClipboardCopyService.Style) -> Void) {
        guard NSIntersectionRange(node.range, selection).length > 0 else { return }
        if htmlPair ?? node.hasHTMLTagMarker(in: raw) {
            // В ячейке таблицы поддержан только `<span style>`; остальные пары там — «сырой» HTML.
            if insideTable {
                guard case .inlineStyle = node.kind else { invalid = true; return }
            }
            for marker in node.markerRanges {
                let selected = NSIntersectionRange(selection, marker)
                if selected.length > 0 && selected.length != marker.length { invalid = true; return }
            }
        }
        var styled = style
        apply(&styled)
        projectInlines(node.children, style: styled)
    }

    /// Строчный код: в выделение попадает содержимое без обрамляющих кавычек; перевод строки внутри — пробел.
    private func projectCode(_ literal: String, node: MarkdownInlineNode, style: MarkdownClipboardCopyService.Style) {
        let range = node.range
        guard range.location >= 0, NSMaxRange(range) <= raw.length else { invalid = true; return }
        guard NSIntersectionRange(selection, range).length > 0 else { return }
        var styled = style
        styled.code = true
        let spelling = raw.substring(with: range) as NSString
        var content = range
        var mappedValue: String?
        var mappedRange: NSRange?
        if spelling as String != literal {
            var ticks = 0
            while ticks < spelling.length && spelling.character(at: ticks) == 96 { ticks += 1 }
            guard ticks * 2 <= spelling.length,
                  (0..<ticks).allSatisfy({ spelling.character(at: spelling.length - 1 - $0) == 96 }) else { invalid = true; return }
            var body = NSRange(location: ticks, length: spelling.length - ticks * 2)
            func normalizeCode(_ text: String) -> String {
                text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            }
            if body.length >= 2, spelling.character(at: body.location) == 32, spelling.character(at: NSMaxRange(body) - 1) == 32 {
                let trimmed = NSRange(location: body.location + 1, length: body.length - 2)
                if normalizeCode(spelling.substring(with: trimmed)) == literal { body = trimmed }
            }
            guard normalizeCode(spelling.substring(with: body)) == literal else { invalid = true; return }
            content = NSRange(location: range.location + body.location, length: body.length)
            if spelling.substring(with: body) != literal {
                var pieces: [MarkdownReadableText.Piece] = [], position = body.location, run = position
                let end = NSMaxRange(body)
                while position < end {
                    if Task.isCancelled { invalid = true; return }
                    let unit = spelling.character(at: position)
                    if unit == 10 || unit == 13 {
                        if position > run {
                            let part = NSRange(location: run, length: position - run)
                            pieces.append(.init(sourceRange: NSRange(location: range.location + run, length: part.length), text: spelling.substring(with: part), matchesSource: true))
                        }
                        let length = unit == 13 && position + 1 < end && spelling.character(at: position + 1) == 10 ? 2 : 1
                        pieces.append(.init(sourceRange: NSRange(location: range.location + position, length: length), text: " ", matchesSource: false))
                        position += length
                        run = position
                    } else { position += 1 }
                }
                if position > run {
                    let part = NSRange(location: run, length: position - run)
                    pieces.append(.init(sourceRange: NSRange(location: range.location + run, length: part.length), text: spelling.substring(with: part), matchesSource: true))
                }
                guard let selected = MarkdownReadableText.selected(pieces, in: selection) else { invalid = true; return }
                guard let mapped = selected.1 else { return }
                mappedRange = mapped
                mappedValue = selected.0
            }
        }
        let clipped = mappedRange ?? NSIntersectionRange(selection, content)
        guard clipped.length > 0 else { return }
        emit(mappedValue ?? raw.substring(with: clipped), sourceRange: clipped, style: styled)
    }

    /// Картинка `![](…)`, `![][ссылка]` и `<img>`: только с включёнными картинками и целиком в выделении.
    private func projectImage(_ image: MarkdownInlineNode.Image, node: MarkdownInlineNode, style: MarkdownClipboardCopyService.Style) {
        let range = node.range
        guard NSIntersectionRange(range, selection).length > 0 else { return }
        guard includeImages, coversWhole(range) else { invalid = true; return }
        if image.syntax == .html {
            // Тег `<img>` и есть весь узел; иначе доказательство относилось бы к другому участку.
            guard image.tagRange == nil || image.tagRange == range else { invalid = true; return }
            covered.append(range)
            emitImage(range: range, address: image.url, alt: image.alt, title: image.title ?? "", css: image.sizing?.css ?? "", style: style)
        } else {
            guard altIsPlain(node) else { invalid = true; return }
            emitImage(range: range, address: image.url, alt: image.alt, title: image.title ?? "", css: "", style: style)
        }
    }

    /// Подпись картинки собирается только из текста, кода, переносов и вложенных `strong/emphasis/strike/image`;
    /// строчный HTML, ссылка и прочее внутри подписи не поддерживается.
    private func altIsPlain(_ node: MarkdownInlineNode) -> Bool {
        guard node.markerRanges.count >= 2 else { return true }
        let start = node.range.location + 2, end = node.markerRanges[1].location
        guard start >= 0, end >= start, end <= raw.length else { return false }
        let label = raw.substring(with: NSRange(location: start, length: end - start))
        if !label.contains("<") && !label.contains("[") && !label.contains("$") { return true }
        let options = MarkdownDocumentModel.Options(syntax: .init(), includes: [], isVaultNote: false, detectsFrontMatter: false)
        guard let parsed = MarkdownDocumentParser.parse(label, options: options), parsed.blocks.count == 1,
              case .paragraph = parsed.blocks[0].kind else { return false }
        func plain(_ nodes: [MarkdownInlineNode]) -> Bool {
            nodes.allSatisfy { item in
                switch item.kind {
                case .text, .code, .softBreak, .hardBreak, .emoji: return true
                case .strong, .emphasis, .strikethrough, .image:
                    // `<b>…</b>` в подписи — строчный HTML, а не `**…**`.
                    return !item.hasHTMLTagMarker(in: label as NSString) && plain(item.children)
                default: return false
                }
            }
        }
        return plain(parsed.blocks[0].inlines)
    }

    /// Подтверждённые `<audio>`, `<video>`, `<iframe>` внутри абзаца: только целиком.
    private func projectMedia(_ node: MarkdownInlineNode, expected: MarkdownHTMLMediaService.ProvenMedia, style: MarkdownClipboardCopyService.Style) {
        let range = node.range
        guard NSIntersectionRange(range, selection).length > 0 else { return }
        guard coversWhole(range), range.location >= 0, NSMaxRange(range) <= raw.length else { invalid = true; return }
        var html = raw.substring(with: range)
        // Запасной текст внутри медиа берётся из разбора cmark всего документа (`**bold**` -> `<strong>`).
        if case .media(let media) = expected, media.kind != .pdf {
            guard let rendered = fallbackHTML()[range] else { invalid = true; return }
            html = rendered
        }
        emitMedia(range: range, html: html, expected: expected, style: style)
    }

    /// Один разбор документа на проекцию: все строчные audio/video, пересекающие выделение, размечаются разом (см. `renderedInlineMediaHTML`).
    private func fallbackHTML() -> [NSRange: String] {
        if let cached = mediaFallbackHTML { return cached }
        var media: [(range: NSRange, expected: MarkdownHTMLMediaService.ProvenMedia)] = []
        func inlines(_ nodes: [MarkdownInlineNode]) {
            for node in nodes {
                if Task.isCancelled { return }
                if case let .media(value) = node.kind, value.kind != .pdf, NSIntersectionRange(node.range, selection).length > 0 {
                    media.append((node.range, .media(value)))
                }
                inlines(node.children)
            }
        }
        func blocks(_ list: [MarkdownBlockNode]) {
            for block in list {
                if Task.isCancelled { return }
                if case let .table(table) = block.kind { for row in table.rows { for cell in row.cells { inlines(cell.inlines) } } }
                inlines(block.inlines)
                blocks(block.children)
            }
        }
        blocks(model.blocks)
        if Task.isCancelled { return [:] }
        let result = MarkdownHTMLProof.renderedInlineMediaHTML(markdown: markdown, media: media, syntax: syntax, isCancelled: { Task.isCancelled }) ?? [:]
        mediaFallbackHTML = result
        return result
    }

    /// Ruby: целиком в выделении; текст — основание и чтение, HTML — `<ruby>` с `<rp>`/`<rt>`.
    private func projectRuby(_ ruby: MarkdownInlineNode.Ruby, node: MarkdownInlineNode, style: MarkdownClipboardCopyService.Style) {
        let range = node.range
        guard NSIntersectionRange(range, selection).length > 0 else { return }
        guard coversWhole(range) else { invalid = true; return }
        // Шорткод эмодзи внутри ruby подставить некуда: копирование отклоняется.
        if emojiCandidates.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { invalid = true; return }
        var content = "<ruby>" + (ruby.baseHTML.map(editingSpanStyles) ?? escape(ruby.base))
        if let before = ruby.openingParenthesis { content += "<rp>" + escape(before) + "</rp>" }
        content += "<rt>" + escape(ruby.reading) + "</rt>"
        if let after = ruby.closingParenthesis { content += "<rp>" + escape(after) + "</rp>" }
        if let trailing = ruby.trailing { content += escape(trailing) }
        content += "</ruby>"
        let separator = ruby.base.utf16.last == 32 || ruby.reading.utf16.first == 32 ? " " : ""
        guard let displayBase = MarkdownHTMLMediaService.rubyDisplayText(ruby.base, isCancelled: { Task.isCancelled }),
              let displayReading = MarkdownHTMLMediaService.rubyDisplayText(ruby.reading, isCancelled: { Task.isCancelled }) else { invalid = true; return }
        emit(displayBase + separator + displayReading, sourceRange: range, style: style, htmlContent: content)
        covered.append(range)
        hasUnverifiedHTMLBlocks = true
    }

    /// `<span style="…">` в оформленном основании: стиль записывается в редакторской форме (`editingCSS`).
    private func editingSpanStyles(_ html: String) -> String {
        guard html.contains("<"), let expression = try? NSRegularExpression(pattern: "<span\\b[^>]*>", options: [.caseInsensitive]) else { return html }
        let source = html as NSString
        let result = NSMutableString(string: html)
        for match in expression.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let style = MarkdownHTMLMediaService.inlineStyleOpening(source.substring(with: match.range), isCancelled: { Task.isCancelled }) else { continue }
            let css = style.editingCSS
            result.replaceCharacters(in: match.range, with: css.isEmpty ? "<span>" : "<span style=\"" + escape(css) + "\">")
        }
        return result as String
    }

    /// Ссылка на сноску `[^x]`: целиком, текст — номер сноски (надстрочный). Определение должно существовать, метки совпасть.
    private func projectFootnoteReference(_ label: String, node: MarkdownInlineNode, style: MarkdownClipboardCopyService.Style) {
        let range = node.range
        guard NSIntersectionRange(range, selection).length > 0 else { return }
        // Ссылка внутри тела определения в `model.footnotes` не входит: определение ищется по метке среди блоков модели.
        let definitionRange = model.footnotes.first(where: { $0.referenceRange == range })?.definitionRange ?? footnoteDefinitionMarker(label: label)
        guard coversWhole(range), !label.isEmpty, let definitionRange,
              definitionRange.location >= 0, NSMaxRange(definitionRange) <= raw.length,
              range.location >= 0, NSMaxRange(range) <= raw.length,
              raw.substring(with: range) == raw.substring(with: definitionRange),
              let number = footnoteNumbers[definitionRange] else { invalid = true; return }
        covered.append(range)
        var superscript = style
        superscript.script = 1
        emit(String(number), sourceRange: range, style: superscript)
    }

    /// Метка определения `[^x]:` с таким `label` (первое по порядку документа).
    private func footnoteDefinitionMarker(label: String) -> NSRange? {
        func find(_ blocks: [MarkdownBlockNode]) -> NSRange? {
            for block in blocks {
                if Task.isCancelled { return nil }
                if case let .footnoteDefinition(value) = block.kind, value == label, !block.isUnreliable, let marker = block.markerRanges.first { return marker }
                if let found = find(block.children) { return found }
            }
            return nil
        }
        return find(model.blocks)
    }

    /// Сырой строчный HTML: копируется только подтверждённый `<br>`, всё остальное — `nil`.
    private func projectRawHTML(_ node: MarkdownInlineNode, style: MarkdownClipboardCopyService.Style) {
        let range = node.range
        guard NSIntersectionRange(range, selection).length > 0 else { return }
        guard range.location >= 0, NSMaxRange(range) <= raw.length,
              ["<br>", "<br/>", "<br />"].contains(raw.substring(with: range).lowercased()),
              !isInRawHTMLContext(range) else { invalid = true; return }
        guard coversWhole(range) else { invalid = true; return }
        let precedingEnd = lastEnd ?? selection.location
        if !insideTable && range.location > precedingEnd {
            appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: range.location - precedingEnd)))
        }
        output += "\n"
        record("\n", kind: .lineBreak)
        var fragment = "<br>"
        if style.keyboard { fragment = "<kbd>" + fragment + "</kbd>" }
        html += wrapStyle(fragment, style: style)
        pendingSoftBreak = false
        lastEnd = NSMaxRange(range)
    }

    // MARK: - Сырой контекст HTML

    /// Выделение задевает участок, который не копируется: теги внутри `<script>`/`<template>`/`<textarea>`…
    /// и всё между непринятыми тегами `video/audio/iframe/ruby/span style` (в том числе вложенные узлы любого вида).
    func selectionHitsBlockedRegion() -> Bool { blockedStateValue().selectionHit }

    /// Тег вне подтверждённого HTML (внутри сырого контекста): `<br>` там не считается подтверждённым.
    func isInRawHTMLContext(_ range: NSRange) -> Bool { blockedStateValue().regions.contains(range) }

    /// Участки считаются один раз; признак «выделение задевает участок» тоже.
    private func blockedStateValue() -> (regions: [NSRange], selectionHit: Bool) {
        if let state = blockedState { return state }
        let regions = buildBlockedRegions()
        let state = (regions: regions, selectionHit: regions.contains { NSIntersectionRange($0, selection).length > 0 })
        blockedState = state
        return state
    }

    /// Имя и признак закрывающего тега для `video/audio/iframe/ruby/span`; `style` — у `<span>` есть атрибут style.
    private func pairedTag(_ range: NSRange) -> (name: String, closing: Bool, blocking: Bool)? {
        guard range.location >= 0, NSMaxRange(range) <= raw.length else { return nil }
        let tag = (raw.substring(with: range) as NSString).lowercased as NSString
        guard tag.length > 2, tag.character(at: 0) == 60, tag.character(at: tag.length - 1) == 62,
              tag.character(at: tag.length - 2) != 47 else { return nil }
        let closing = tag.character(at: 1) == 47
        let start = closing ? 2 : 1
        var end = start
        while end < tag.length, (97...122).contains(tag.character(at: end)) { end += 1 }
        let name = tag.substring(with: NSRange(location: start, length: end - start))
        guard ["video", "audio", "iframe", "span", "ruby"].contains(name) else { return nil }
        let blocking = name != "span" || closing || MarkdownHTMLMediaService.hasStyledSpan(in: tag as String, isCancelled: { Task.isCancelled })
        return (name, closing, blocking)
    }

    /// Один проход по модели в порядке исходника: `.rawHTML` и `.html`-блоки двигают сырой контекст (`HTMLContext`),
    /// неподтверждённые теги попадают в набор (текст и эмодзи копируются как в панели). Незакрытая пара тегов действует до конца списка
    /// соседей. Ненадёжный HTML портит контекст до конца документа.
    private func buildBlockedRegions() -> [NSRange] {
        var blocked: [NSRange] = []
        guard markdown.contains("<") else { return blocked }
        var context = MarkdownImageUploadService.HTMLContext(), templateDepth = 0, lastHTMLPosition = 0
        /// `true`, если тег вне сырого контекста и вне `<template>` (до и после).
        func consume(range: NSRange, unreliable: Bool) -> Bool {
            guard !unreliable, range.location >= lastHTMLPosition else { context.invalidate(); return false }
            let outsideTemplate = templateDepth == 0
            let outside = context.consume(source: raw, range: range, isCancelled: { Task.isCancelled }, confirmedTag: { _, name, closing in
                if name == "template" { templateDepth = closing ? max(0, templateDepth - 1) : templateDepth + 1 }
            })
            lastHTMLPosition = NSMaxRange(range)
            return outside && outsideTemplate && templateDepth == 0
        }
        func inlines(_ nodes: [MarkdownInlineNode]) {
            var open: [(name: String, start: Int, blocking: Bool)] = []
            for node in nodes {
                if Task.isCancelled { invalid = true; return }
                if case .rawHTML = node.kind {
                    if !consume(range: node.range, unreliable: node.isUnreliable) { blocked.append(node.range) }
                    if let tag = pairedTag(node.range) {
                        if !tag.closing { open.append((tag.name, node.range.location, tag.blocking)) }
                        else if let index = open.lastIndex(where: { $0.name == tag.name }) {
                            for entry in open[index...] where entry.blocking {
                                blocked.append(NSRange(location: entry.start, length: NSMaxRange(node.range) - entry.start))
                            }
                            open.removeSubrange(index...)
                        }
                    }
                }
                inlines(node.children)
            }
            if let end = nodes.last.map({ NSMaxRange($0.range) }) {
                for entry in open where entry.blocking && end > entry.start { blocked.append(NSRange(location: entry.start, length: end - entry.start)) }
            }
        }
        func blocks(_ list: [MarkdownBlockNode]) {
            for block in list {
                if Task.isCancelled { invalid = true; return }
                if case .html = block.kind { _ = consume(range: block.range, unreliable: block.isUnreliable) }
                if case let .table(table) = block.kind {
                    for row in table.rows { for cell in row.cells { inlines(cell.inlines) } }
                }
                inlines(block.inlines)
                blocks(block.children)
            }
        }
        blocks(model.blocks)
        return blocked
    }
}
