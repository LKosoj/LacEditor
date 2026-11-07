import Foundation

/// Медиа, картинки и сырой HTML в HTML-адаптере (U3.2): адреса и маркеры (`LACREMOTE`, `LACLOCALMEDIA`, `LACRAW`),
/// блоки `<audio>/<video>/<iframe>/<svg>`, твит, разрыв страницы, `<details>` и «богатый» HTML, `<img>`, пропущенный HTML.
extension MarkdownHTMLRenderer {
    /// Состояние адресов, маркеров и сырого HTML одного вызова.
    struct MediaState {
        var omittedHTML = false
        var remoteMarkers: [String: String] = [:]
        var localMarkers: [String: MarkdownRenderedPage.LocalMediaResource] = [:]
        var localPrefix: String?
        var rawBlocks: [(marker: String, html: String)] = []
        var rawPrefix: String?
        var rawFailed = false
        var resourcePaths: Result<MarkdownResourcePaths, Error>?
        var resourcePathsLoaded = false
        var imageDataURIs: [Data: String] = [:]
        var failedImageAddresses: Set<Data> = []
        /// Единственный строчный узел текущего абзаца: картинка в нём центрируется.
        var soleInline: NSRange?
        /// Прямые дети ячейки таблицы — `<br>` (по `range.location`): они выводятся тегом.
        var cellBreaks: Set<Int> = []
        /// Выводится содержимое ячейки таблицы.
        var inTableCell = false
        /// Именованные якоря (`prepareNamedAnchors`): `id` перед строчным узлом по `range.location`.
        var inlineAnchors: [Int: String] = [:]
        /// `<span id>` перед блоком, который целиком равен тегу якоря (по `range.location` блока).
        var blockAnchorSpans: [Int: [String]] = [:]
        /// Блоки с якорем внутри, уже выведенные в HTML (по `range.location` блока).
        var anchoredBlocks: [Int: String] = [:]
        /// Имя якоря (UTF-8) → `id` на странице; у заголовков приоритет (`special.aliases`).
        var namedAnchorTargets: [Data: String] = [:]
        /// Экспорт HTML: подтверждение прежнего прохода экспорта (`exportProof`), считается один раз при первом обращении.
        var exportProof: ExportProof?
        /// Экспорт HTML: глубина строчных `<template>` (как `templateDepth` в разборе); теги внутри не выводятся.
        var templateDepth = 0
        /// Абзац с разорванным открывающим тегом медиа, объединённый со следующим блоком (по `range.location` блока).
        var mergedOpenings: [Int: MarkdownBlockNode] = [:]
    }

    /// Теги и блоки, подтверждённые `MarkdownImageUploadService.images(htmlForExport:)`: баланс строчных тегов в родителе,
    /// контекст `<script>`/`<template>`, медиа и iframe. Ключ — диапазон узла в исходном тексте.
    struct ExportProof {
        var inline: [NSRange: String] = [:]
        var audio = Set<NSRange>(), video = Set<NSRange>()
        var frames: [NSRange: MarkdownHTMLMediaService.EmbeddedFrame] = [:]
        var blocks = Set<NSRange>()
    }

    static func exportProof(_ w: Writer) -> ExportProof {
        if let proof = w.media.exportProof { return proof }
        var proof = ExportProof()
        _ = try? MarkdownImageUploadService.images(in: w.text as String, allowSharedReference: true, isCancelled: { Task.isCancelled },
                                                   htmlForExport: true, confirmedAudio: { proof.audio.insert($0) },
                                                   confirmedVideo: { proof.video.insert($0) }, confirmedInline: { proof.inline[$0] = $1 },
                                                   confirmedFrame: { proof.frames[$0] = $1 }, confirmedBlock: { proof.blocks.insert($0) })
        w.media.exportProof = proof
        return proof
    }

    /// Флаги разбора для медиа и эмодзи: `:имя:` превращается в узел только при `renderEmoji`.
    static func mediaIncludes(renderEmoji: Bool) -> MarkdownDocumentModel.Includes { renderEmoji ? [.emoji] : [] }

    // MARK: - Адреса и маркеры

    private static func uniquePrefix(_ base: String, _ w: Writer) -> String {
        var prefix: String
        repeat { prefix = base + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while w.text.range(of: prefix).location != NSNotFound && !Task.isCancelled
        return prefix
    }

    /// Маркер сырого HTML `<!--LACRAW…X{n}-->`; исходный HTML запоминается в `rawHTMLBlocks`.
    static func rawMarker(_ original: String, _ w: Writer) -> String {
        if w.media.rawPrefix == nil { w.media.rawPrefix = uniquePrefix("LACRAW", w) }
        let marker = "<!--" + w.media.rawPrefix! + "X" + String(w.media.rawBlocks.count) + "-->"
        w.media.rawBlocks.append((marker, original))
        return marker
    }

    /// Адрес удалённой картинки → маркер `LACREMOTE…` (страница подставит данные позже); `nil` — не http(s) или предзагрузка выключена.
    static func markRemote(_ address: String, _ w: Writer) -> String? {
        guard w.prepareRemoteImages, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        var marker: String
        repeat { marker = "LACREMOTE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while (w.text.range(of: marker).location != NSNotFound || w.media.remoteMarkers[marker] != nil) && !Task.isCancelled
        w.media.remoteMarkers[marker] = address
        return marker
    }

    private static func resourcePaths(for address: String, _ w: Writer) -> MarkdownResourcePaths? {
        if MarkdownResourcePaths.requiresRoot(address), !w.media.resourcePathsLoaded {
            w.media.resourcePaths = Result { try MarkdownResourcePaths(text: w.text as String, document: w.documentURL) }
            w.media.resourcePathsLoaded = true
        }
        return w.media.resourcePaths.flatMap { try? $0.get() }
    }

    /// Адрес медиа: http(s) остаётся адресом только в экспорте HTML, локальный файл — маркер `LACLOCALMEDIA…X{n}`.
    static func resolvedMedia(_ address: String, _ w: Writer) -> String {
        if Task.isCancelled { return "data:," }
        if let url = URL(string: address), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil { return w.includeHTMLMedia ? url.absoluteString : "data:," }
        let paths = resourcePaths(for: address, w)
        guard !(MarkdownResourcePaths.requiresRoot(address) && w.media.resourcePathsLoaded && paths == nil),
              let url = try? MarkdownImageUploadService.localURL(address: address, document: w.documentURL, paths: paths) else { return "data:," }
        if w.media.localPrefix == nil { w.media.localPrefix = uniquePrefix("LACLOCALMEDIA", w) }
        guard let prefix = w.media.localPrefix, !Task.isCancelled else { return "data:," }
        let marker = prefix + "X" + String(w.media.localMarkers.count)
        w.media.localMarkers[marker] = .init(url: url, fragment: MarkdownImageUploadService.fragmentSuffix(address))
        return marker
    }

    /// Адрес картинки при `resolveLocalImages`: удалённая → маркер, локальная → data URI, остальное без изменений.
    static func resolvedImage(_ address: String, _ w: Writer) -> String {
        guard w.resolveLocalImages else { return address }
        if let marker = markRemote(address, w) { return marker }
        let scheme = URL(string: address)?.scheme?.lowercased()
        guard !address.hasPrefix("//"), scheme == nil || scheme == "file" else { return address }
        if Task.isCancelled { return address }
        let paths = resourcePaths(for: address, w)
        let key = Data(address.utf8)
        if w.media.imageDataURIs[key] == nil && !w.media.failedImageAddresses.contains(key) {
            if MarkdownResourcePaths.requiresRoot(address) && w.media.resourcePathsLoaded && paths == nil {
                w.media.failedImageAddresses.insert(key)
            } else if !Task.isCancelled, let payload = try? MarkdownImageUploadService.payload(address: address, document: w.documentURL, paths: paths) {
                w.media.imageDataURIs[key] = MarkdownImageUploadService.dataURI(payload, address: address)
            } else { w.media.failedImageAddresses.insert(key) }
        }
        return w.media.imageDataURIs[key] ?? address
    }

    // MARK: - Общие помощники вывода

    /// Атрибут `data-sourcepos` вставляется в первый тег (у пользовательских узлов cmark позиции не наследуются).
    static func addingSourcePosition(_ html: String, _ range: NSRange, _ w: Writer) -> String {
        let attribute = w.sp(range)
        guard !attribute.isEmpty, let end = html.firstIndex(of: ">") else { return html }
        return String(html[..<end]) + attribute + String(html[end...])
    }

    /// Пользовательский блок cmark: перенос строки до и после.
    static func putCustomBlock(_ html: String, _ w: Writer) {
        w.cr()
        w.put(html)
        w.cr()
    }

    /// Открывающий тег `<audio>/<video>` и источники; адреса через `resolvedMedia`.
    static func mediaOpeningHTML(_ media: MarkdownEmbeddedMedia, _ w: Writer) -> String {
        let tag = media.kind == .audio ? "audio" : "video"
        var html = "<\(tag)" + (media.controls ? " controls" : "")
        var style = ""
        for (name, value) in [("width", media.width), ("height", media.height)] {
            if let value { style += "\(name):\(value.hasSuffix("%") || value.hasSuffix("px") ? value : value + "px");" }
        }
        if !style.isEmpty { html += " style=\"\(escapeHTML(style))\"" }
        html += ">"
        for address in media.sources {
            if Task.isCancelled { return html }
            html += "<source src=\"\(escapeHTML(resolvedMedia(address, w)))\">"
        }
        return html
    }

    static func frameHTML(_ frame: MarkdownHTMLMediaService.EmbeddedFrame, _ w: Writer) -> String {
        w.includeHTMLMedia ? MarkdownHTMLMediaService.iframeHTML(frame) : MarkdownHTMLMediaService.iframeFallbackHTML(frame)
    }

    static func svgImageHTML(_ data: Data) -> String {
        "<img src=\"data:image/svg+xml;base64," + data.base64EncodedString() + "\" alt=\"\">"
    }

    /// Исходный текст блока без префиксов контейнеров (`> `, отступы пунктов) на строках продолжения.
    static func rawBlockText(_ node: MarkdownBlockNode, _ w: Writer) -> String {
        let range = node.range
        let original = NSMutableString(string: w.slice(range))
        for prefix in node.containerPrefixes.reversed() {
            let location = prefix.line.location
            guard location >= range.location, location + prefix.prefixLength <= NSMaxRange(range) else { continue }
            original.deleteCharacters(in: NSRange(location: location - range.location, length: prefix.prefixLength))
        }
        return original as String
    }

    /// Смещение в `literal` блока по смещению в исходнике: без префиксов контейнеров и с `\r\n` как `\n`.
    private static func literalOffset(_ offset: Int, in node: MarkdownBlockNode, _ w: Writer) -> Int {
        var removed = 0
        for prefix in node.containerPrefixes {
            let location = prefix.line.location
            if location >= node.range.location, location + prefix.prefixLength <= offset { removed += prefix.prefixLength }
        }
        var index = node.range.location
        while index < offset - 1 {
            if w.text.character(at: index) == 13, w.text.character(at: index + 1) == 10 { removed += 1; index += 1 }
            index += 1
        }
        return offset - node.range.location - removed
    }

    // MARK: - Блоки

    /// Блоки: `.html`, `.mathBlock`, `.tableOfContents`.
    static func writeMediaBlock(_ node: MarkdownBlockNode, _ w: Writer) {
        switch node.kind {
        case .html(let block): writeHTMLBlock(node, block, w)
        case .mathBlock(let source): writeMathBlock(source, w)
        case .tableOfContents: writeTableOfContents(node, w)
        case .paragraph, .heading, .quote, .callout, .alert, .list, .listItem, .codeBlock, .table, .footnoteDefinition,
             .frontMatter, .thematicBreak, .noteEmbed, .comment:
            assertionFailure("Блок не относится к U3.2")
        }
    }

    /// Абзац из одного разорванного на строки `<audio`/`<video`, который ядро объединило со следующим блоком медиа
    /// (`PairedMediaCollector.merges`): медиа блока совпадает с медиа из объединённого текста.
    static func isMergedMediaOpening(_ paragraph: MarkdownBlockNode, before next: MarkdownBlockNode) -> Bool {
        guard case .paragraph = paragraph.kind, paragraph.inlines.count == 1, case .rawHTML(let opening) = paragraph.inlines[0].kind,
              opening.contains("\n"), case .html(let block) = next.kind, case .media(let media) = block.kind else { return false }
        let combined = (opening + "\n" + block.literal).trimmingCharacters(in: .whitespacesAndNewlines)
        return MarkdownHTMLMediaService.embeddedMedia(in: combined) == media
    }

    private static func putOmittedBlock(_ w: Writer) {
        w.cr()
        w.put(omittedHTMLComment)
        w.cr()
        w.media.omittedHTML = true
    }

    static func writeHTMLBlock(_ node: MarkdownBlockNode, _ block: MarkdownBlockNode.HTMLBlock, _ w: Writer) {
        for span in w.media.blockAnchorSpans[node.range.location] ?? [] { putCustomBlock(span, w) }
        if let html = w.media.anchoredBlocks[node.range.location] {
            putCustomBlock(html, w)
            return
        }
        let opening = w.media.mergedOpenings[node.range.location]
        let canonical: Bool
        switch block.kind {
        // Медиа внутри HTML (с `<source>`, разорванный тег) в экспорте HTML остаётся сырым блоком с подставленными адресами.
        case .media: canonical = opening == nil && MarkdownHTMLMediaService.standaloneMedia(block.literal, isCancelled: { Task.isCancelled }) != nil
        case .svg, .twitter, .iframe: canonical = true
        case .raw, .confirmed, .details, .pageBreak, .images: canonical = false
        }
        // Экспорт HTML: любой блок, кроме медиа, остаётся сырым HTML — страница подставит его по маркеру.
        if w.preserveRawHTMLBlocks, !canonical {
            var raw = rawBlockText(node, w), literal = block.literal, unreliable = node.isUnreliable
            if let opening, case .rawHTML(let tag) = opening.inlines[0].kind {
                // Объединённый блок начинается с тега из абзаца; перевод строки после тега берётся из исходника.
                let gap = w.slice(NSRange(location: NSMaxRange(opening.range), length: max(0, node.range.location - NSMaxRange(opening.range))))
                raw = rawBlockText(opening, w) + (gap.hasPrefix("\r\n") ? "\r\n" : "\n") + raw
                literal = tag + "\n" + literal
                unreliable = unreliable || opening.isUnreliable
            }
            // Дешёвая сверка с literal ядра (`\r\n` как `\n`, хвостовой перевод строки не важен).
            let normalized = { (value: String) -> String in
                var text = value.replacingOccurrences(of: "\r\n", with: "\n")
                while text.hasSuffix("\n") { text.removeLast() }
                return text
            }
            if unreliable || normalized(raw) != normalized(literal) { w.media.rawFailed = true }
            putCustomBlock(rawMarker(substitutingRawMedia(raw, w), w), w)
            return
        }
        // Экспорт HTML: блок выводится, только если его подтвердил проход экспорта (вне `<script>`, позиции сверены);
        // одиночные `<audio>`/`<video>` — в прежнем каноническом виде.
        if w.includeHTMLMedia, !w.preserveRawHTMLBlocks {
            let proof = exportProof(w), literal = w.slice(node.range)
            if proof.audio.contains(node.range), let address = MarkdownHTMLMediaService.audioSource(in: literal, allowPaired: true) {
                putCustomBlock(addingSourcePosition("<audio controls src=\"\(escapeHTML(address))\"></audio>", node.range, w), w)
                return
            }
            if proof.video.contains(node.range), let address = MarkdownHTMLMediaService.videoSource(in: literal) {
                putCustomBlock(addingSourcePosition("<video controls src=\"\(escapeHTML(address))\"></video>", node.range, w), w)
                return
            }
            if let frame = proof.frames[node.range] {
                putCustomBlock(addingSourcePosition(frameHTML(frame, w), node.range, w), w)
                return
            }
            guard proof.blocks.contains(node.range) else { putOmittedBlock(w); return }
        }
        switch block.kind {
        case .pageBreak:
            putCustomBlock("<div style=\"page-break-after:always;break-after:page\"></div>", w)
        case .svg(let data):
            putCustomBlock(addingSourcePosition(svgImageHTML(data), node.range, w), w)
        case .twitter(let widget):
            guard let frame = MarkdownHTMLMediaService.twitterFrame(widget) else { putOmittedBlock(w); return }
            let html = w.staticWidgetFallback || !w.includeHTMLMedia
                ? MarkdownHTMLMediaService.twitterFallbackHTML(widget) : MarkdownHTMLMediaService.iframeHTML(frame)
            putCustomBlock(addingSourcePosition(html, node.range, w), w)
        case .media(let media):
            let tail = media.kind == .audio ? "</audio>" : "</video>"
            putCustomBlock(addingSourcePosition(mediaOpeningHTML(media, w) + tail, node.range, w), w)
        case .iframe(let frame, _, _):
            putCustomBlock(addingSourcePosition(frameHTML(frame, w), node.range, w), w)
        case .details:
            if let rendered = MarkdownHTMLMediaService.exportBlock(block.literal, isCancelled: { Task.isCancelled }, imageOnly: true) {
                putCustomBlock(addingSourcePosition(rendered.html, node.range, w), w)
            } else { putOmittedBlock(w) }
        case .images(let images):
            writeImagesBlock(node, block, images, w)
        case .raw, .confirmed:
            writeConfirmedBlock(node, block, w)
        }
    }

    /// Экспорт HTML: `<audio>/<video>/<iframe>` внутри сырого блока получают разрешённые адреса (локальный файл — `LACLOCALMEDIA`).
    /// Теги ищет тот же разбор HTML, что и у ядра (`HTMLContext`): комментарии, атрибуты, `script`, `style`, `textarea`, а также
    /// `pre`, `code`, `template` тегами не считаются. Проход один, незакрытый тег ничего не стоит.
    private static func substitutingRawMedia(_ raw: String, _ w: Writer) -> String {
        guard raw.range(of: "<audio", options: .caseInsensitive) != nil || raw.range(of: "<video", options: .caseInsensitive) != nil
                || raw.range(of: "<iframe", options: .caseInsensitive) != nil else { return raw }
        let source = raw as NSString
        var context = MarkdownImageUploadService.HTMLContext()
        var suppressed: [String] = [], pending: [String: Int] = [:], found: [(range: NSRange, name: String)] = []
        func close(_ tag: NSRange, _ name: String) {
            if let start = pending.removeValue(forKey: name) { found.append((NSRange(location: start, length: NSMaxRange(tag) - start), name)) }
        }
        let closed = context.consume(source: source, range: NSRange(location: 0, length: source.length), isCancelled: { Task.isCancelled }, confirmedTag: { tag, name, closing in
            if ["template", "pre", "code"].contains(name) {
                if closing { if suppressed.last == name { suppressed.removeLast() } } else { suppressed.append(name) }
            } else if suppressed.isEmpty, ["audio", "video", "iframe"].contains(name) {
                if !closing { pending[name] = tag.location } else { close(tag, name) }
            }
        }, confirmedRawClose: { tag, name in
            // Закрывающий `</iframe>` приходит отдельно: `iframe` для разбора — «сырой текст».
            if suppressed.isEmpty, name == "iframe" { close(tag, name) }
        })
        guard closed, !found.isEmpty else { return raw }
        found.sort { $0.range.location < $1.range.location }
        let result = NSMutableString(string: raw)
        // `copyMediaHTML` сверяет адрес повторным вызовом: ответ на один адрес должен быть одним и тем же.
        var addresses: [Data: String] = [:]
        let resolve = { (address: String) -> String in
            let key = Data(address.utf8)
            if let value = addresses[key] { return value }
            let value = resolvedMedia(address, w)
            addresses[key] = value
            return value
        }
        var end = 0
        var fragments: [(range: NSRange, name: String)] = []
        for item in found where item.range.location >= end {
            fragments.append(item)
            end = NSMaxRange(item.range)
        }
        for match in fragments.reversed() {
            if Task.isCancelled { return raw }
            let fragment = source.substring(with: match.range)
            let html: String
            if match.name == "iframe" {
                guard let frame = MarkdownHTMLMediaService.iframe(in: fragment) else { continue }
                html = frameHTML(frame, w)
            } else {
                guard let media = MarkdownHTMLMediaService.embeddedMedia(in: fragment), media.kind != .pdf,
                      var rendered = MarkdownHTMLMediaService.copyMediaHTML(fragment, expected: .media(media), resolveMedia: resolve,
                                                                            isCancelled: { Task.isCancelled }) else { continue }
                // Без `controls` у тега проигрывателя не было бы видно, поэтому атрибут добавляется.
                if !media.controls { rendered.insert(contentsOf: " controls", at: rendered.index(rendered.startIndex, offsetBy: (media.kind == .audio ? "audio" : "video").count + 1)) }
                html = rendered
            }
            result.replaceCharacters(in: match.range, with: html)
        }
        return result as String
    }

    /// Подтверждённый или неизвестный блок: экспорт HTML разбирает его целиком, предпросмотр — только блоки со стилевым `<span>`.
    private static func writeConfirmedBlock(_ node: MarkdownBlockNode, _ block: MarkdownBlockNode.HTMLBlock, _ w: Writer) {
        if w.includeHTMLMedia {
            if let rendered = MarkdownHTMLMediaService.exportBlock(w.slice(node.range), isCancelled: { Task.isCancelled },
                                                                  fallbackSource: block.literal) {
                putCustomBlock(addingSourcePosition(rendered.html, node.range, w), w)
                if rendered.omitted { w.media.omittedHTML = true }
                return
            }
        } else if w.resolveLocalImages, MarkdownHTMLMediaService.hasStyledSpan(in: block.literal, isCancelled: { Task.isCancelled }),
                  let rendered = MarkdownHTMLMediaService.exportBlock(block.literal, isCancelled: { Task.isCancelled }, imageOnly: true,
                                                                     fallbackSource: block.literal) {
            putCustomBlock(addingSourcePosition(rendered.html, node.range, w), w)
            return
        }
        putOmittedBlock(w)
    }

    /// Блок из `<img>`: экспорт HTML — как подтверждённый блок, предпросмотр — картинки с подменой адреса.
    private static func writeImagesBlock(_ node: MarkdownBlockNode, _ block: MarkdownBlockNode.HTMLBlock,
                                         _ images: [MarkdownInlineNode.Image], _ w: Writer) {
        if w.includeHTMLMedia {
            writeConfirmedBlock(node, block, w)
            return
        }
        guard w.resolveLocalImages, let rendered = renderImagesBlock(node, block, images, anchors: [], expectations: [:], w) else {
            putOmittedBlock(w)
            return
        }
        putCustomBlock(addingSourcePosition(rendered.html, node.range, w), w)
    }

    /// Блок из `<img>` для предпросмотра: маркеры картинок (и якорей `anchors`) вставляются в literal, дальше — `exportBlock`.
    private static func renderImagesBlock(_ node: MarkdownBlockNode, _ block: MarkdownBlockNode.HTMLBlock,
                                          _ images: [MarkdownInlineNode.Image], anchors: [(range: NSRange, id: String)],
                                          expectations: [String: [String]], _ w: Writer) -> MarkdownHTMLMediaService.ExportBlock? {
        let prefix = uniquePrefix("LACHTMLIMG", w)
        var markers: [String: MarkdownHTMLMediaService.ExportImageMarker] = [:]
        var insertions: [(Int, String)] = []
        for (index, image) in images.enumerated() {
            guard let tag = image.tagRange else { return nil }
            // Тег берётся из literal: у разорванного на строки тега в цитате или списке в исходнике внутри стоят префиксы контейнера.
            let start = literalOffset(tag.location, in: node, w), end = literalOffset(NSMaxRange(tag), in: node, w)
            let literal = block.literal as NSString
            guard start >= 0, start <= end, end <= literal.length,
                  let display = MarkdownHTMLMediaService.displayImage(in: literal.substring(with: NSRange(location: start, length: end - start))) else { return nil }
            let marker = prefix + "X" + String(index)
            insertions.append((start, "<!--\(marker)-->"))
            markers[marker] = .init(source: display.source, address: image.url)
        }
        for anchor in anchors {
            guard !block.literal.contains(anchor.id) else { return nil }
            insertions.append((literalOffset(anchor.range.location, in: node, w), "<span id=\"\(anchor.id)\"></span>"))
        }
        guard let marked = MarkdownHTMLMediaService.insertingMarkers(in: block.literal, insertions: insertions, isCancelled: { Task.isCancelled }) else { return nil }
        return MarkdownHTMLMediaService.exportBlock(marked, isCancelled: { Task.isCancelled }, anchorMarkers: expectations, imageMarkers: markers,
                                                    imageOnly: true, resolveMedia: { resolvedMedia($0, w) }, fallbackSource: block.literal,
                                                    resolveImage: { resolvedImage($0, w) })
    }

    // MARK: - Именованные якоря

    /// Предпроход: `<a name|id>` из HTML получают `<span id="lac-anchor-N">`, ссылки `#имя` переписываются на них
    /// (у заголовков приоритет). Блок шире тега выводится через `exportBlock(anchorMarkers:)` со случайным `id`.
    /// В экспорте HTML (`preserveRawHTMLBlocks`) якоря остаются в сыром HTML и работают сами.
    static func prepareNamedAnchors(_ model: MarkdownDocumentModel, _ w: Writer) {
        guard !w.preserveRawHTMLBlocks, !model.namedAnchors.isEmpty else { return }
        var htmlBlocks: [(node: MarkdownBlockNode, block: MarkdownBlockNode.HTMLBlock)] = []
        func visit(_ nodes: [MarkdownBlockNode]) {
            for node in nodes {
                if case .html(let block) = node.kind { htmlBlocks.append((node, block)) }
                visit(node.children)
            }
        }
        visit(model.blocks)
        var ids: [Int: String] = [:], installed = Set<String>()
        var groups: [Int: [(anchor: MarkdownNamedAnchor, id: String)]] = [:]
        // Якоря и HTML-блоки идут по порядку документа: один проход, указатель `htmlIndex` только вперёд.
        var htmlIndex = 0
        for anchor in model.namedAnchors.sorted(by: { $0.range.location < $1.range.location }) {
            let location = anchor.range.location
            guard w.special.aliases[anchor.name] == nil, ids[location] == nil else { continue }
            while htmlIndex < htmlBlocks.count && NSMaxRange(htmlBlocks[htmlIndex].node.range) <= location { htmlIndex += 1 }
            guard htmlIndex < htmlBlocks.count, NSLocationInRange(location, htmlBlocks[htmlIndex].node.range) else {
                let id = "lac-anchor-\(ids.count)"
                ids[location] = id
                w.media.inlineAnchors[location] = id
                installed.insert(id)
                continue
            }
            let index = htmlIndex
            let node = htmlBlocks[index].node
            if node.range == anchor.range {
                let id = "lac-anchor-\(ids.count)"
                ids[location] = id
                w.media.blockAnchorSpans[node.range.location, default: []].append("<span id=\"\(id)\"></span>")
                installed.insert(id)
            } else {
                let id = "lac-anchor-\(UUID().uuidString)"
                ids[location] = id
                groups[index, default: []].append((anchor, id))
            }
        }
        var namesByRange: [NSRange: [String]] = [:]
        for anchor in model.namedAnchors { namesByRange[anchor.range, default: []].append(anchor.name) }
        for (index, entries) in groups.sorted(by: { $0.key < $1.key }) {
            if Task.isCancelled { return }
            let (node, block) = htmlBlocks[index]
            var expectations: [String: [String]] = [:]
            for (anchor, id) in entries { expectations[id] = namesByRange[anchor.range] }
            // Блок из `<img>` в предпросмотре: якоря вставляются вместе с маркерами картинок.
            if case .images(let images) = block.kind, w.resolveLocalImages, !w.includeHTMLMedia {
                guard let rendered = renderImagesBlock(node, block, images, anchors: entries.map { ($0.anchor.range, $0.id) },
                                                       expectations: expectations, w) else { continue }
                w.media.anchoredBlocks[node.range.location] = addingSourcePosition(rendered.html, node.range, w)
                if rendered.omitted { w.media.omittedHTML = true }
                if !rendered.sourceFallback { for (_, id) in entries { installed.insert(id) } }
                continue
            }
            let source = w.slice(node.range)
            guard entries.allSatisfy({ !source.contains($0.id) }),
                  let marked = MarkdownHTMLMediaService.insertingMarkers(
                    in: source, insertions: entries.map { ($0.anchor.range.location - node.range.location, "<span id=\"\($0.id)\"></span>") },
                    isCancelled: { Task.isCancelled }) else { continue }
            guard let rendered = MarkdownHTMLMediaService.exportBlock(
                marked, isCancelled: { Task.isCancelled }, anchorMarkers: expectations, imageOnly: w.resolveLocalImages,
                resolveMedia: { resolvedMedia($0, w) }, fallbackSource: block.literal,
                resolveImage: { w.resolveLocalImages ? resolvedImage($0, w) : nil }) else { continue }
            w.media.anchoredBlocks[node.range.location] = addingSourcePosition(rendered.html, node.range, w)
            if rendered.omitted { w.media.omittedHTML = true }
            if !rendered.sourceFallback { for (_, id) in entries { installed.insert(id) } }
        }
        for anchor in model.namedAnchors where w.special.aliases[anchor.name] == nil {
            let key = Data(anchor.name.utf8)
            if w.media.namedAnchorTargets[key] == nil, let id = ids[anchor.range.location], installed.contains(id) {
                w.media.namedAnchorTargets[key] = id
            }
        }
    }

    /// Тег без точной позиции (абзац после определений ссылок с табом): якорь подтверждён по исходнику,
    /// тег узла — тот же текст внутри его запасного диапазона. Берётся первый такой якорь.
    static func unreliableAnchor(_ node: MarkdownInlineNode, _ w: Writer) -> String? {
        guard node.isUnreliable, case .rawHTML(let literal) = node.kind else { return nil }
        let length = (literal as NSString).length
        guard let location = w.media.inlineAnchors.keys.filter({ NSLocationInRange($0, node.range) && $0 + length <= NSMaxRange(node.range)
            && w.slice(NSRange(location: $0, length: length)) == literal }).min() else { return nil }
        return w.media.inlineAnchors.removeValue(forKey: location)
    }

    // MARK: - Строчные

    /// Строчные: `.underline`, `.keyboard`, `.highlight`, `.subscriptText`, `.superscriptText`, `.inlineStyle`, `.media`, `.iframe`,
    /// `.svg`, `.ruby`, `.emoji`, `.formula`, `.rawHTML`.
    static func writeMediaInline(_ node: MarkdownInlineNode, _ w: Writer) {
        switch node.kind {
        case .rawHTML(let literal): writeRawInline(node, literal, w)
        case .media(let media):
            let tag = media.kind == .audio ? "audio" : "video"
            if writeInlinePairMarkers(node, w) { return }
            if w.includeHTMLMedia {
                // Экспорт HTML: пара, которую принимает `audioSource`/`videoSource`, — в прежнем каноническом виде;
                // пустая пара — как в предпросмотре; пара с запасным содержимым пропускается.
                let literal = w.slice(node.range), opening = openingTagRange(node.range, w)
                let address = media.kind == .audio ? MarkdownHTMLMediaService.audioSource(in: literal, allowPaired: true)
                    : MarkdownHTMLMediaService.videoSource(in: literal)
                if let address {
                    w.put(addingSourcePosition("<\(tag) controls src=\"\(escapeHTML(address))\"></\(tag)>", opening, w))
                    return
                }
                if !node.children.isEmpty || (literal as NSString).substring(from: opening.length).lowercased() != "</\(tag)>" {
                    w.media.omittedHTML = true
                    w.put(omittedHTMLComment)
                    return
                }
            }
            w.put(addingSourcePosition(mediaOpeningHTML(media, w), openingTagRange(node.range, w), w))
            writeInlines(node.children, w)
            w.put("</\(tag)>")
        case .iframe(let frame, _, _):
            if writeInlinePairMarkers(node, w) { return }
            w.put(addingSourcePosition(frameHTML(frame, w), openingTagRange(node.range, w), w))
        case .svg(let data):
            w.put(addingSourcePosition(svgImageHTML(data), node.range, w))
        case .underline, .keyboard, .highlight, .subscriptText, .superscriptText, .inlineStyle, .ruby, .emoji, .formula:
            writeSpecialInline(node, w)
        case .text, .code, .strong, .emphasis, .strikethrough, .link, .image, .wikiLink, .noteEmbed, .footnoteReference, .critic,
             .softBreak, .hardBreak, .comment:
            assertionFailure("Узел не относится к U3.2")
        }
    }

    /// Диапазон открывающего тега в начале `range`: до первого `>` вне кавычек (позиция `data-sourcepos` у строчного медиа).
    private static func openingTagRange(_ range: NSRange, _ w: Writer) -> NSRange {
        var quote: unichar = 0
        var index = range.location
        while index < NSMaxRange(range) {
            let unit = w.text.character(at: index)
            if quote != 0 { if unit == quote { quote = 0 } }
            else if unit == 34 || unit == 39 { quote = unit }
            else if unit == 62 { return NSRange(location: range.location, length: index + 1 - range.location) }
            index += 1
        }
        return range
    }

    /// Экспорт HTML: строчная пара `<audio>…</audio>` остаётся сырым HTML, каждый тег — свой маркер.
    private static func writeInlinePairMarkers(_ node: MarkdownInlineNode, _ w: Writer) -> Bool {
        guard w.preserveRawHTMLBlocks else { return false }
        let opening = openingTagRange(node.range, w)
        let closeStart = w.text.range(of: "</", options: .backwards, range: node.range).location
        w.put(rawMarker(w.slice(opening), w))
        // Сырой HTML между тегами, не покрытый детьми (например, `<source>`), — тоже маркеры.
        let end = closeStart != NSNotFound && closeStart >= NSMaxRange(opening) ? closeStart : NSMaxRange(node.range)
        if node.children.contains(where: { $0.isUnreliable }) {
            writeInlines(node.children, w)
        } else {
            var cursor = NSMaxRange(opening), segment: [MarkdownInlineNode] = []
            for child in node.children + [nil] as [MarkdownInlineNode?] {
                let next = child.map { $0.range.location } ?? end
                if next > cursor {
                    writeInlines(segment, w)
                    segment.removeAll()
                    w.put(rawMarker(w.slice(NSRange(location: cursor, length: next - cursor)), w))
                }
                guard let child else { break }
                segment.append(child)
                cursor = max(cursor, NSMaxRange(child.range))
            }
            writeInlines(segment, w)
        }
        if closeStart != NSNotFound, closeStart >= NSMaxRange(opening) {
            w.put(rawMarker(w.slice(NSRange(location: closeStart, length: NSMaxRange(node.range) - closeStart)), w))
        }
        return true
    }

    /// Индекс узла с закрывающим тегом, если `nodes[start]` открывает `<script|style|textarea>`; иначе (и без пары) `nil`.
    static func rawElementEnd(_ nodes: [MarkdownInlineNode], from start: Int, _ w: Writer) -> Int? {
        guard case .rawHTML(let literal) = nodes[start].kind else { return nil }
        let opening = literal.lowercased()
        guard let name = ["script", "style", "textarea"].first(where: { opening.hasPrefix("<" + $0) && !opening.hasPrefix("</") }),
              opening.dropFirst(name.count + 1).first.map({ " >\t\n/".contains($0) }) ?? false, !opening.hasSuffix("/>") else { return nil }
        var index = start + 1
        while index < nodes.count {
            if case .rawHTML(let closing) = nodes[index].kind, closing.lowercased().hasPrefix("</" + name) { return index }
            index += 1
        }
        w.media.rawFailed = true
        return nil
    }

    private static func writeRawInline(_ node: MarkdownInlineNode, _ literal: String, _ w: Writer) {
        if w.preserveRawHTMLBlocks {
            if node.isUnreliable { w.media.rawFailed = true }
            w.put(rawMarker(node.isUnreliable ? literal : w.slice(node.range), w))
            return
        }
        // `<br>` — прямой ребёнок ячейки таблицы: настоящий перенос строки.
        if w.media.cellBreaks.contains(node.range.location), ["<br>", "<br/>", "<br />"].contains(literal.lowercased()) {
            w.put("<br>")
            return
        }
        if w.includeHTMLMedia {
            let lowered = literal.lowercased()
            if lowered.hasPrefix("<template") { w.media.templateDepth += 1 }
            else if lowered.hasPrefix("</template") { w.media.templateDepth = max(0, w.media.templateDepth - 1) }
            if w.media.templateDepth == 0, let html = exportProof(w).inline[node.range] {
                w.put(addingSourcePosition(html, node.range, w))
            } else {
                w.media.omittedHTML = true
                w.put(omittedHTMLComment)
            }
            return
        }
        w.put(omittedHTMLComment)
    }

    /// `<img>` из HTML: экспорт — тег с размерами, предпросмотр с `resolveLocalImages` — тег с подменой адреса, иначе — «raw HTML omitted».
    static func writeHTMLImage(_ node: MarkdownInlineNode, _ image: MarkdownInlineNode.Image, _ w: Writer) {
        let range = image.tagRange ?? node.range
        let tag = w.slice(range)
        if w.preserveRawHTMLBlocks {
            w.put(rawMarker(tag, w))
        } else if w.includeHTMLMedia {
            // Тег без кавычек, в верхнем регистре или с ссылками на символы сначала приводится к XML.
            let xml = MarkdownImageUploadService.htmlImage(in: w.text, range: range, htmlForExport: true, isCancelled: { Task.isCancelled })?.htmlXML
            guard let parsed = MarkdownHTMLMediaService.image(in: xml ?? tag), parsed.source == image.url else {
                w.media.omittedHTML = true
                w.put(omittedHTMLComment)
                return
            }
            var html = "<img src=\"\(escapeHTML(parsed.source))\""
            if let alt = parsed.alt { html += " alt=\"\(escapeHTML(alt))\"" }
            if let title = parsed.title { html += " title=\"\(escapeHTML(title))\"" }
            if let width = parsed.width { html += " width=\"\(escapeHTML(width))\"" }
            if let height = parsed.height { html += " height=\"\(escapeHTML(height))\"" }
            w.put(addingSourcePosition(html + ">", range, w))
        } else if w.resolveLocalImages {
            var html = "<img src=\"\(escapeHTML(resolvedImage(image.url, w)))\" alt=\"\(escapeHTML(image.alt))\""
            if let title = image.title { html += " title=\"\(escapeHTML(title))\"" }
            if let display = MarkdownHTMLMediaService.displayImage(in: tag), !display.sizing.css.isEmpty {
                html += " style=\"\(escapeHTML(display.sizing.css))\""
            }
            w.put(addingSourcePosition(html + ">", range, w))
        } else {
            w.put(omittedHTMLComment)
        }
    }

    /// Markdown-картинка: адрес подменяется при `resolveLocalImages`; единственный элемент абзаца центрируется.
    static func writeMarkdownImage(_ node: MarkdownInlineNode, _ image: MarkdownInlineNode.Image, _ w: Writer) {
        let centered = w.resolveLocalImages && w.media.soleInline == node.range
        if centered { w.put("<span data-lac-centered-image>") }
        w.put("<img src=\"\(hrefValue(resolvedImage(image.url, w)))\" alt=\"\(escapeHTML(image.alt))\"")
        if let title = image.title, !title.isEmpty { w.put(" title=\"\(escapeHTML(title))\"") }
        w.put(" />")
        if centered { w.put("</span>") }
    }
}
