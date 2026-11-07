import Foundation
import SwiftSoup

private typealias HTMLImage = (NSRange, String, MarkdownHTMLMediaService.DisplayImage)

// Доказательства текста, картинок и контейнеров по литералу блока (без узлов cmark).
private struct TextProof { let start: Int; let end: Int; let text: String }
private struct ImageProof { let offset: Int; let source: String }
private struct StyleProof { let offset: Int; let style: MarkdownInlineStyle }
private struct ContainerProof { let opening: Int; let closing: Int; let name: String }

/// Данные доказательств HTML-блоков, общие для всей проекции: считаются один раз.
struct HTMLProofCache {
    /// Уникальная приставка маркеров (нет в тексте документа).
    var token: String?
    var scanned = false
    /// Участки после незакрытого `<div>` предыдущего HTML-блока до его закрытия.
    var unclosedSpans: [NSRange] = []
}

extension MarkdownClipboardCopyService.ProjectionState {
    /// HTML-блоки (U4.5.4): details, media, iframe, svg, twitter, images, confirmed, raw.
    /// Вид блока берётся из модели (`HTMLBlock.Kind`); текст блока — `HTMLBlock.literal` (как `cmark_node_get_literal`).
    /// Любое сомнение (в том числе частично выделенное медиа, details, svg, twitter) — `invalid`, результат `nil`.
    func projectHTMLBlock(_ block: MarkdownBlockNode, htmlBlock: MarkdownBlockNode.HTMLBlock, style: MarkdownClipboardCopyService.Style) {
        let range = block.range
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= raw.length else { invalid = true; return }
        guard NSIntersectionRange(range, selection).length > 0 else { return }
        if block.isUnreliable { invalid = true; return }
        let literal = htmlBlock.literal as NSString
        let whole = NSIntersectionRange(range, selection) == range
        func proven() -> Bool { htmlLiteralOffsets(literal, range: range, tags: []) != nil }
        switch htmlBlock.kind {
        case let .details(details):
            guard whole, proven(), let rich = MarkdownHTMLMediaService.richDetails(htmlBlock.literal, isCancelled: { Task.isCancelled }),
                  let display = MarkdownHTMLMediaService.editingHTMLBlock(htmlBlock.literal, isCancelled: { Task.isCancelled }) else { invalid = true; return }
            emitDetails(range: range, key: details.range, rich: rich, display: display)
        case let .svg(data):
            guard whole, proven(), includeImages else { invalid = true; return }
            covered.append(range)
            emitImage(range: range, address: "data:image/svg+xml;base64," + data.base64EncodedString(), alt: "", title: "", css: "", style: style)
        case let .twitter(widget):
            guard whole, proven(), let frame = MarkdownHTMLMediaService.twitterFrame(widget) else { invalid = true; return }
            let precedingEnd = lastEnd ?? selection.location
            if !insideTable && range.location > precedingEnd {
                appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: range.location - precedingEnd)))
            }
            html += MarkdownHTMLMediaService.iframeHTML(frame)
            covered.append(range)
            hasStructuralOutput = true
            hasUnverifiedHTMLBlocks = true
            lastEnd = NSMaxRange(range)
        case let .media(media):
            emitBlockMedia(range: range, literal: htmlBlock.literal, proven: proven(), expected: .media(media), style: style)
        case let .iframe(frame, canonical, _):
            // Вид блока определяет модель (решение 1): HTML берётся канонический, так копируется и `<iframe …/>`.
            emitBlockMedia(range: range, literal: canonical, proven: proven(), expected: .frame(frame), style: style)
        case .pageBreak, .confirmed, .raw, .images:
            var images: [HTMLImage] = []
            if includeImages, case let .images(list) = htmlBlock.kind {
                for image in list {
                    guard let tag = image.tagRange, tag.location >= 0, NSMaxRange(tag) <= raw.length else { continue }
                    // Адрес и описание берутся из тега исходника (в модели `url` может быть закодирован).
                    let tagText = raw.substring(with: tag) as NSString
                    guard let verified = MarkdownImageUploadService.confirmedHTMLImage(in: tagText, range: NSRange(location: 0, length: tagText.length),
                                                                                      isCancelled: { Task.isCancelled }),
                          let display = MarkdownHTMLMediaService.displayImage(in: tagText as String) else { continue }
                    images.append((tag, verified.address, display))
                }
            }
            // Только внутри контейнера (цитата, список, сноска): на верхнем уровне блок идёт через `projectFlatHTMLBlock` с обёрткой `<div>`.
            if images.count == 1, !blockParents.isEmpty || !htmlLiteralMatchesSource(literal, range: range), let image = images.first,
               selection.location <= image.0.location, NSMaxRange(selection) >= NSMaxRange(image.0) {
                var context = MarkdownImageUploadService.HTMLContext()
                var tags: [(NSRange, String, Bool)] = []
                if context.consume(source: raw, range: range, isCancelled: { Task.isCancelled }, confirmedTag: { tags.append(($0, $1, $2)) }),
                   tags.count == 3, tags[0].1 == "div", !tags[0].2, tags[1].1 == "img", !tags[1].2, tags[1].0 == image.0,
                   tags[2].1 == "div", tags[2].2 {
                    covered.append(image.0)
                    emitImage(range: image.0, address: image.1, alt: image.2.alt, title: image.2.title ?? "", css: image.2.sizing.css, style: style)
                    return
                }
            }
            if projectNestedHTMLBlock(literal, range: range, htmlImages: images, style: style) ||
                projectFlatHTMLBlock(literal, range: range, htmlImages: images, style: style) { return }
            invalid = true
        }
    }

    /// `<details>`: текст заголовка и (если раскрыт) тела, HTML — подтверждённый показ с нужным `open`.
    private func emitDetails(range: NSRange, key: NSRange, rich: MarkdownHTMLMediaService.RichDetails, display shown: String) {
        let open = detailsOpenOverrides[key] ?? rich.initiallyOpen
        guard let summary = detailsText(rich.summaryHTML),
              let body = open ? detailsText(rich.bodyHTML) : "",
              let document = try? SwiftSoup.parseBodyFragment(shown),
              let element = document.body()?.children().first(), element.tagName() == "details" else { invalid = true; return }
        document.outputSettings().prettyPrint(pretty: false)
        do {
            if open { try element.attr("open", "") } else { try element.removeAttr("open") }
        } catch { invalid = true; return }
        guard let display = try? element.outerHtml() else { invalid = true; return }
        let value = summary + (body.isEmpty ? "" : "\n" + body)
        let precedingEnd = lastEnd ?? selection.location
        if !insideTable && range.location > precedingEnd {
            appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: range.location - precedingEnd)))
        }
        output += value; record(value)
        html += display
        covered.append(range)
        hasStructuralOutput = true; hasUnverifiedHTMLBlocks = true
        lastEnd = NSMaxRange(range)
    }

    /// `audio`/`video`/`iframe` блоком: выделение обязано покрыть тег целиком, вокруг тега — только пробелы.
    private func emitBlockMedia(range: NSRange, literal: String, proven: Bool, expected: MarkdownHTMLMediaService.ProvenMedia,
                                style: MarkdownClipboardCopyService.Style) {
        let tag = trimmedRange(range)
        guard proven, tag.length > 0, NSIntersectionRange(tag, selection) == tag else { invalid = true; return }
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = MarkdownHTMLMediaService.standaloneMedia(literal, isCancelled: { Task.isCancelled })?
            .normalizedLiteral.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        emitMedia(range: tag, html: value, expected: expected, style: style)
    }

    private func trimmedRange(_ range: NSRange) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        func space(_ unit: unichar) -> Bool { [9, 10, 12, 13, 32].contains(Int(unit)) }
        while start < end && space(raw.character(at: start)) { start += 1 }
        while end > start && space(raw.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Литерал блока совпадает с исходником (переводы строк `\r\n` и `\r` считаются `\n`): вне контейнеров с префиксами.
    private func htmlLiteralMatchesSource(_ value: NSString, range: NSRange) -> Bool {
        MarkdownDocumentParser.htmlSourceMatches(literal: value, isBlock: true, range: range, text: raw, isCancelled: { Task.isCancelled })
    }

    /// Текстовые промежутки HTML-блока доказываются по DOM одного литерала. Это верно только для блока верхнего уровня
    /// и не после незакрытого элемента предыдущего HTML (блока или строчного `rawHTML` абзаца): контекст (`li`, `blockquote`, чужой `div`) нам неизвестен.
    /// Незакрытым считается `div` и любой элемент вне списка известных (`p`, `span`, `strong` и т. п.).
    private func htmlTextProofAllowed(_ range: NSRange) -> Bool {
        guard blockParents.isEmpty else { return false }
        if !htmlProof.scanned {
            htmlProof.scanned = true
            let known: Set<String> = ["p", "span", "strong", "b", "em", "i", "u", "s", "del", "mark", "sub", "sup", "kbd"]
            let voids: Set<String> = ["img", "br", "hr", "input", "source", "wbr", "col", "area", "base", "link", "meta", "track", "embed", "param"]
            var open: [String] = [], spanStart: Int?
            func consume(_ range: NSRange) {
                guard range.location >= 0, NSMaxRange(range) <= raw.length else { return }
                var context = MarkdownImageUploadService.HTMLContext()
                _ = context.consume(source: raw, range: range, isCancelled: { Task.isCancelled }, confirmedTag: { _, name, closing in
                    guard !voids.contains(name) else { return }
                    if !closing { open.append(name) } else if let index = open.lastIndex(of: name) { open.removeSubrange(index...) }
                })
                let unclosed = open.contains { $0 == "div" || !known.contains($0) }
                if unclosed, spanStart == nil { spanStart = NSMaxRange(range) }
                if !unclosed, let start = spanStart {
                    htmlProof.unclosedSpans.append(NSRange(location: start, length: NSMaxRange(range) - start))
                    spanStart = nil
                }
            }
            func visit(_ inlines: [MarkdownInlineNode]) {
                for inline in inlines {
                    if Task.isCancelled { return }
                    if case .rawHTML = inline.kind { consume(inline.range) }
                    visit(inline.children)
                }
            }
            func visit(_ blocks: [MarkdownBlockNode]) {
                for block in blocks {
                    if Task.isCancelled { return }
                    if case .html = block.kind { if !block.isUnreliable { consume(block.range) } } else { visit(block.inlines) }
                    visit(block.children)
                }
            }
            visit(model.blocks)
            if let start = spanStart { htmlProof.unclosedSpans.append(NSRange(location: start, length: max(0, raw.length - start))) }
        }
        return !htmlProof.unclosedSpans.contains { range.location >= $0.location && range.location < NSMaxRange($0) }
    }

    /// Приставка маркеров: одна на проекцию, проверена по тексту документа один раз.
    private func proofToken() -> String {
        if let token = htmlProof.token { return token }
        var token: String
        repeat { token = "LACPROOF" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while markdown.contains(token)
        htmlProof.token = token
        return token
    }

    private func htmlLiteralOffsets(_ literal: NSString, range: NSRange, tags: [NSRange]) -> [Int: Int]? {
        MarkdownHTMLMediaService.htmlBlockTagOffsets(literal: literal, range: range, tags: tags, sourceText: raw, isCancelled: { Task.isCancelled })
    }

    /// Сколько `<img>` из кандидатов подтверждено разбором литерала с маркерами (замена `provenImageIndices` без cmark).
    private func provenImageCount(in literal: NSString, candidates: [ImageProof], ancestors: [Int: [MarkdownHTMLMediaService.ImageAncestor]]) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let prefix = proofToken() + "I"
        var insertions: [(Int, String)] = [], expected: [String: String] = [:], chains: [String: [MarkdownHTMLMediaService.ImageAncestor]] = [:]
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { return 0 }
            guard candidate.offset >= 0, candidate.offset <= literal.length, 4 <= literal.length - candidate.offset,
                  literal.substring(with: NSRange(location: candidate.offset, length: 4)).lowercased() == "<img" else { continue }
            let marker = prefix + String(index)
            insertions.append((candidate.offset, "<!--\(marker)-->"))
            expected[marker] = candidate.source
            if let chain = ancestors[index] { chains[marker] = chain }
        }
        guard !expected.isEmpty, let marked = MarkdownHTMLMediaService.insertingMarkers(in: literal as String, insertions: insertions, isCancelled: { Task.isCancelled }),
              let accepted = MarkdownHTMLMediaService.confirmedImageMarkers(in: marked, expected: expected, ancestors: chains, isCancelled: { Task.isCancelled })
        else { return 0 }
        return accepted.count
    }

    /// Текст, стили и контейнеры по литералу с маркерами (замена `provenTextAndContainers` без cmark).
    private func provenTextAndContainers(in literal: NSString, candidates: [TextProof], styleCandidates: [StyleProof] = [],
                                         containers: [ContainerProof] = []) -> [Int: MarkdownHTMLMediaService.ProvenText]? {
        guard !candidates.isEmpty || !containers.isEmpty, !Task.isCancelled else { return nil }
        let prefix = proofToken() + "X"
        var grouped: [Int: [(Bool, String)]] = [:], names: [String: (Int, Bool)] = [:]
        for (index, candidate) in candidates.enumerated() {
            let start = prefix + "S" + String(index), end = prefix + "E" + String(index)
            grouped[candidate.start, default: []].append((true, start))
            grouped[candidate.end, default: []].append((false, end))
            names[start] = (index, true); names[end] = (index, false)
        }
        var styleNames: [String: MarkdownInlineStyle] = [:]
        for (index, candidate) in styleCandidates.enumerated() {
            let marker = prefix + "T" + String(index)
            styleNames[marker] = candidate.style
            grouped[candidate.offset, default: []].append((true, marker))
        }
        var containerNames: [String: (Int, Bool)] = [:]
        for (index, candidate) in containers.enumerated() {
            let opening = prefix + "BO" + String(index), closing = prefix + "BC" + String(index)
            grouped[candidate.opening, default: []].append((true, opening))
            grouped[candidate.closing, default: []].append((false, closing))
            containerNames[opening] = (index, true); containerNames[closing] = (index, false)
        }
        let insertions = grouped.map { offset, markers in (offset, markers.sorted { !$0.0 && $1.0 }.map { "<!--\($0.1)-->" }.joined()) }
        guard let marked = MarkdownHTMLMediaService.insertingMarkers(in: literal as String, insertions: insertions, isCancelled: { Task.isCancelled }),
              !Task.isCancelled else { return nil }
        return MarkdownHTMLMediaService.provenText(inMarkedHTML: marked, names: names, styleNames: styleNames, containerNames: containerNames,
                                                   candidateTexts: candidates.map { $0.text }, containerTags: containers.map { $0.name },
                                                   isCancelled: { Task.isCancelled })
    }

    private func detailsText(_ html: String) -> String? {
        guard let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else { return nil }
        var result = "", pendingSpace = false, atLineStart = true
        var nodes = Array(body.getChildNodes().reversed())
        while let node = nodes.popLast() {
            if Task.isCancelled { return nil }
            if let text = node as? TextNode {
                for scalar in text.getWholeText().unicodeScalars {
                    if Task.isCancelled { return nil }
                    if [9, 10, 12, 13, 32].contains(Int(scalar.value)) {
                        if !atLineStart { pendingSpace = true }
                    } else {
                        if pendingSpace { result += " "; pendingSpace = false }
                        result.unicodeScalars.append(scalar); atLineStart = false
                    }
                }
            } else if let element = node as? Element {
                if element.tagName() == "br" { result += "\n"; pendingSpace = false; atLineStart = true }
                else { nodes.append(contentsOf: element.getChildNodes().reversed()) }
            } else { return nil }
        }
        return result
    }

    private func projectNestedHTMLBlock(_ literal: NSString, range: NSRange, htmlImages: [HTMLImage], style: MarkdownClipboardCopyService.Style) -> Bool {
        guard htmlLiteralMatchesSource(literal, range: range) else { return false }
        var context = MarkdownImageUploadService.HTMLContext(), tags: [(NSRange, String, Bool)] = []
        guard context.consume(source: raw, range: range, isCancelled: { Task.isCancelled }, confirmedTag: { tags.append(($0, $1, $2)) }),
              tags.count >= 2, let first = tags.first, ["div", "p"].contains(first.1), !first.2,
              let last = tags.last, last.1 == first.1, last.2 else { return false }
        var stack: [(String, NSRange, MarkdownInlineStyle?)] = [], gaps: [(NSRange, [String])] = [], containers: [(NSRange, NSRange, String)] = []
        var imageOwners: [NSRange: [MarkdownHTMLMediaService.ImageAncestor]] = [:]
        var styles: [(NSRange, MarkdownInlineStyle)] = [], cursor = range.location, nested = first.1 == "p"
        let inlineNames = ["strong", "b", "em", "i", "u", "s", "del", "mark", "sub", "sup", "kbd", "span"]
        for (tag, name, closing) in tags {
            if Task.isCancelled { return false }
            guard tag.location >= cursor, NSMaxRange(tag) <= NSMaxRange(range) else { return false }
            let selectedTag = NSIntersectionRange(tag, selection)
            guard selectedTag.length == 0 || selectedTag == tag else { return false }
            if tag.location > cursor { gaps.append((NSRange(location: cursor, length: tag.location - cursor), stack.filter { ["div", "p"].contains($0.0) }.map { $0.0 })) }
            let spelling = raw.substring(with: tag).lowercased()
            if name == "img" {
                guard !closing else { return false }
                imageOwners[tag] = stack.map { .init(name: $0.0, style: $0.2) }
                cursor = NSMaxRange(tag)
                continue
            }
            let inlineStyle = name == "span" && !closing ? MarkdownHTMLMediaService.inlineStyleOpening(raw.substring(with: tag), isCancelled: { Task.isCancelled }) : nil
            guard (["div", "p"].contains(name) || inlineNames.contains(name)),
                  spelling == "<" + (closing ? "/" : "") + name + ">" || inlineStyle != nil else { return false }
            if let inlineStyle { styles.append((tag, inlineStyle)) }
            if closing {
                guard let opening = stack.last, opening.0 == name else { return false }
                stack.removeLast()
                if ["div", "p"].contains(name) { containers.append((opening.1, tag, name)) }
            } else {
                if ["div", "p"].contains(name) && !stack.isEmpty { nested = true }
                stack.append((name, tag, inlineStyle))
            }
            cursor = NSMaxRange(tag)
        }
        guard nested, stack.isEmpty else { return false }
        if cursor < NSMaxRange(range) { gaps.append((NSRange(location: cursor, length: NSMaxRange(range) - cursor), [])) }
        let images = htmlImages.sorted { $0.0.location < $1.0.location }
        guard images.count == imageOwners.count, !gaps.isEmpty || !images.isEmpty else { return false }
        // Контекст важен только для текста, стилей и контейнеров; одни картинки доказываются своими предками.
        guard (gaps.isEmpty && styles.isEmpty && containers.isEmpty) || htmlTextProofAllowed(range) else { return false }
        let points = gaps.flatMap { [$0.0, NSRange(location: NSMaxRange($0.0) - 1, length: 1)] } +
            containers.flatMap { [$0.0, NSRange(location: NSMaxRange($0.1) - 1, length: 1)] } + styles.map { $0.0 } + Array(imageOwners.keys)
        guard let offsets = htmlLiteralOffsets(literal, range: range, tags: points.sorted { $0.location < $1.location }) else { return false }
        var proof: [TextProof] = []
        for (gap, _) in gaps {
            guard let start = offsets[gap.location], let end = offsets[NSMaxRange(gap) - 1], end >= start, end < literal.length else { return false }
            let source = raw.substring(with: gap).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            guard literal.substring(with: NSRange(location: start, length: end - start + 1)).utf16.elementsEqual(source.utf16) else { return false }
            proof.append(.init(start: start, end: end + 1, text: source))
        }
        if !images.isEmpty {
            var candidates: [ImageProof] = [], ancestors: [Int: [MarkdownHTMLMediaService.ImageAncestor]] = [:]
            for image in images {
                if Task.isCancelled { return false }
                guard let offset = offsets[image.0.location], let owners = imageOwners[image.0] else { return false }
                ancestors[candidates.count] = owners
                candidates.append(.init(offset: offset, source: image.2.source))
            }
            guard !Task.isCancelled, provenImageCount(in: literal, candidates: candidates, ancestors: ancestors) == candidates.count else { return false }
        }
        var styleProof: [StyleProof] = []
        for (tag, value) in styles { guard let offset = offsets[tag.location] else { return false }; styleProof.append(.init(offset: offset, style: value)) }
        var containerProof: [ContainerProof] = []
        for (open, close, name) in containers {
            guard let start = offsets[open.location], let end = offsets[NSMaxRange(close) - 1] else { return false }
            containerProof.append(.init(opening: start, closing: end + 1, name: name))
        }
        guard let confirmed = provenTextAndContainers(in: literal, candidates: proof, styleCandidates: styleProof, containers: containerProof),
              !Task.isCancelled, confirmed.count == proof.count,
              gaps.indices.allSatisfy({ confirmed[$0]?.blocks == gaps[$0].1 }) else { return false }
        var visiblePrefix = [0]
        for index in gaps.indices {
            if Task.isCancelled { return false }
            let visible = confirmed[index]?.text.utf16.contains(where: { ![9, 10, 12, 13, 32].contains(Int($0)) }) == true
            visiblePrefix.append(visiblePrefix[visiblePrefix.count - 1] + (visible ? 1 : 0))
        }
        func gapIndex(at position: Int) -> Int {
            var low = 0, high = gaps.count
            while low < high {
                let middle = (low + high) / 2
                if gaps[middle].0.location < position { low = middle + 1 } else { high = middle }
            }
            return low
        }
        var containersByOpening: [NSRange: (NSRange, NSRange, String)] = [:]
        for container in containers {
            if Task.isCancelled { return false }
            containersByOpening[container.0] = container
            if container.2 == "p" {
                let first = gapIndex(at: NSMaxRange(container.0)), last = gapIndex(at: container.1.location)
                var low = 0, high = images.count
                while low < high {
                    let middle = (low + high) / 2
                    if images[middle].0.location < NSMaxRange(container.0) { low = middle + 1 } else { high = middle }
                }
                let hasImage = low < images.count && NSMaxRange(images[low].0) <= container.1.location
                if visiblePrefix[last] == visiblePrefix[first] && !hasImage && NSMaxRange(container.0) != container.1.location { return false }
            }
        }
        for boundary in [selection.location, NSMaxRange(selection)] where boundary > 0 && boundary < raw.length {
            if raw.character(at: boundary - 1) == 13 && raw.character(at: boundary) == 10 { return false }
        }
        struct GapToken {
            var pieces: [MarkdownReadableText.Piece]
            let whitespace: Bool
            var visible: Bool
        }
        var tokens = [[GapToken]](repeating: [], count: gaps.count)
        for index in gaps.indices {
            if Task.isCancelled { return false }
            let gap = gaps[index].0, spelling = raw.substring(with: gap) as NSString
            let normalized = spelling.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
            var boundaries = [0], offset = 0
            while offset < spelling.length {
                if Task.isCancelled { return false }
                if spelling.character(at: offset) == 13, offset + 1 < spelling.length, spelling.character(at: offset + 1) == 10 { offset += 2 }
                else { offset += 1 }
                boundaries.append(offset)
            }
            guard boundaries.count == normalized.length + 1, let value = confirmed[index]?.text,
                  let projected = MarkdownInlineTextProjection.pieces(spelling: normalized, literal: value, sourceOffset: 0, isCancelled: { Task.isCancelled }) else { return false }
            let displayed = value as NSString
            for position in 0..<displayed.length {
                if Task.isCancelled { return false }
                if [9, 10, 12, 13, 32].contains(Int(displayed.character(at: position))),
                   displayed.rangeOfComposedCharacterSequence(at: position).length > 1 { return false }
            }
            func append(_ piece: MarkdownReadableText.Piece, whitespace: Bool) {
                if whitespace, tokens[index].last?.whitespace == true { tokens[index][tokens[index].count - 1].pieces.append(piece) }
                else { tokens[index].append(GapToken(pieces: [piece], whitespace: whitespace, visible: !whitespace)) }
            }
            for piece in projected {
                if Task.isCancelled { return false }
                let start = piece.sourceRange.location, end = NSMaxRange(piece.sourceRange)
                guard start >= 0, end < boundaries.count else { return false }
                if piece.matchesSource {
                    var i = start
                    while i < end {
                        if Task.isCancelled { return false }
                        let whitespace = [9, 10, 12, 13, 32].contains(Int(normalized.character(at: i)))
                        let beginning = i
                        if normalized.character(at: i) == 10 { i += 1 }
                        else {
                            repeat { i += 1 } while i < end && normalized.character(at: i) != 10 &&
                                [9, 10, 12, 13, 32].contains(Int(normalized.character(at: i))) == whitespace
                        }
                        let length = boundaries[i] - boundaries[beginning]
                        append(.init(sourceRange: NSRange(location: gap.location + boundaries[beginning], length: length),
                            text: normalized.substring(with: NSRange(location: beginning, length: i - beginning)),
                            matchesSource: length == i - beginning), whitespace: whitespace)
                    }
                } else {
                    let units = Array(piece.text.utf16), whitespace = units.allSatisfy { [9, 10, 12, 13, 32].contains(Int($0)) }
                    guard whitespace || !units.contains(where: { [9, 10, 12, 13, 32].contains(Int($0)) }) else { return false }
                    append(.init(sourceRange: NSRange(location: gap.location + boundaries[start], length: boundaries[end] - boundaries[start]), text: piece.text, matchesSource: false), whitespace: whitespace)
                }
            }
        }
        let events = (tags.filter { $0.1 != "img" }.map { ($0.0.location, Optional($0), Optional<Int>.none, Optional<Int>.none) } +
            gaps.indices.map { (gaps[$0].0.location, nil, Optional($0), nil) } +
            images.indices.map { (images[$0].0.location, nil, nil, Optional($0)) }).sorted { $0.0 < $1.0 }
        var pending: (Int, Int)?, precedingText = false
        for (_, tag, gapIndex, imageIndex) in events {
            if Task.isCancelled { return false }
            if let tag, ["div", "p"].contains(tag.1) { pending = nil; precedingText = false }
            else if imageIndex != nil {
                if let (gap, token) = pending { tokens[gap][token].visible = true }
                pending = nil; precedingText = true
            } else if let index = gapIndex {
                for tokenIndex in tokens[index].indices {
                    if Task.isCancelled { return false }
                    if tokens[index][tokenIndex].whitespace {
                        if pending == nil && precedingText { pending = (index, tokenIndex) }
                    } else {
                        if let (gap, token) = pending { tokens[gap][token].visible = true }
                        pending = nil; precedingText = true
                    }
                }
            }
        }
        var selected: [Int: (String, NSRange)] = [:]
        for index in gaps.indices {
            if Task.isCancelled { return false }
            let part = NSIntersectionRange(gaps[index].0, selection)
            if part.length == 0 { continue }
            var value = "", first: Int?, last: Int?
            for token in tokens[index] {
                guard let result = MarkdownReadableText.selected(token.pieces, in: part, isCancelled: { Task.isCancelled }) else { return false }
                guard let mapped = result.1 else { continue }
                if token.visible {
                    value += token.whitespace ? " " : result.0
                    if first == nil { first = mapped.location }
                    last = NSMaxRange(mapped)
                }
            }
            if let first, let last { selected[index] = (value, NSRange(location: first, length: last - first)) }
        }
        let selectedImages = Set(images.indices.filter { index in
            selection.location <= images[index].0.location && NSMaxRange(selection) >= NSMaxRange(images[index].0)
        })
        let selectedRanges = selected.values.map { $0.1 } + selectedImages.map { images[$0].0 }
        guard let first = selectedRanges.map(\.location).min(), let last = selectedRanges.map({ NSMaxRange($0) }).max(), last >= first else { return false }
        let envelope = NSRange(location: first, length: last - first)
        covered.append(range)
        let preceding = lastEnd ?? selection.location
        if !insideTable && range.location > preceding { appendBreaks(in: NSIntersectionRange(selection, NSRange(location: preceding, length: range.location - preceding))) }
        var pendingBreak = 0, emitted = false, trailingEmptyContainer = false
        var blockStack: [(String, Int, Bool)] = [], visibleCount = 0
        for (_, tag, gapIndex, imageIndex) in events {
            if Task.isCancelled { invalid = true; return true }
            if let tag, ["div", "p"].contains(tag.1) {
                if !tag.2 {
                    guard let container = containersByOpening[tag.0] else { invalid = true; return true }
                    let whole = NSRange(location: container.0.location, length: NSMaxRange(container.1) - container.0.location)
                    let included = NSIntersectionRange(whole, envelope).length > 0
                    blockStack.append((tag.1, visibleCount, included))
                    if emitted { pendingBreak = max(pendingBreak, 1) }
                    if included { html += "<" + tag.1 + ">" }
                } else {
                    guard let block = blockStack.popLast(), block.0 == tag.1 else { invalid = true; return true }
                    if !blockStack.isEmpty { trailingEmptyContainer = visibleCount == block.1 }
                    if emitted { pendingBreak = max(pendingBreak, tag.1 == "p" && visibleCount > block.1 ? 2 : 1) }
                    if block.2 { html += "</" + tag.1 + ">" }
                }
            } else if let index = imageIndex, selectedImages.contains(index) {
                if pendingBreak > 0 && emitted {
                    let breaks = String(repeating: "\n", count: pendingBreak)
                    output += breaks; record(breaks, kind: .lineBreak); pendingBreak = 0
                }
                let image = images[index]
                lastEnd = image.0.location
                emitImage(range: image.0, address: image.1, alt: image.2.alt, title: image.2.title ?? "", css: image.2.sizing.css,
                          style: style, inlineOwners: imageOwners[image.0] ?? [])
                emitted = true; visibleCount += 1
            } else if let index = gapIndex, let proven = confirmed[index], let chosen = selected[index] {
                if pendingBreak > 0 && emitted {
                    let breaks = String(repeating: "\n", count: pendingBreak)
                    output += breaks; record(breaks, kind: .lineBreak); pendingBreak = 0
                }
                let result = chosen.0
                emitted = true
                visibleCount += 1
                if !result.isEmpty {
                    var current = style
                    if let inline = proven.inlineStyle { current.inlineStyle = style.inlineStyle.map { inline.inheriting($0) } ?? inline }
                    for name in proven.styles {
                        switch name {
                        case "strong", "b": current.bold = true
                        case "em", "i": current.italic = true
                        case "u": current.underline = true
                        case "s", "del": current.strike = true
                        case "mark": current.highlight = true
                        case "sub": current.script = -1
                        case "sup": current.script = 1
                        case "kbd": current.keyboard = true
                        default: break
                        }
                    }
                    lastEnd = chosen.1.location
                    emit(result, sourceRange: chosen.1, style: current,
                         preserveSelectedSpaces: result.hasPrefix(" ") || result.hasSuffix(" "))
                }
            }
        }
        let hasInlineStyle = confirmed.values.contains { $0.inlineStyle != nil }
        if pendingBreak > 0, emitted, !trailingEmptyContainer, !hasInlineStyle, NSMaxRange(selection) == NSMaxRange(range) {
            let breaks = String(repeating: "\n", count: pendingBreak)
            output += breaks
            record(breaks, kind: .lineBreak)
        }
        lastEnd = min(NSMaxRange(range), NSMaxRange(selection))
        hasStructuralOutput = true
        hasUnverifiedHTMLBlocks = true
        return true
    }
    private func projectFlatHTMLBlock(_ literal: NSString, range: NSRange, htmlImages: [HTMLImage], style: MarkdownClipboardCopyService.Style) -> Bool {
        guard htmlLiteralMatchesSource(literal, range: range) else { return false }
        for boundary in [selection.location, NSMaxRange(selection)] where boundary > 0 && boundary < raw.length {
            if raw.character(at: boundary - 1) == 13 && raw.character(at: boundary) == 10 { return false }
        }
        var context = MarkdownImageUploadService.HTMLContext(), tags: [(NSRange, String, Bool)] = []
        guard context.consume(source: raw, range: range, isCancelled: { Task.isCancelled }, confirmedTag: { tag, name, closing in
            tags.append((tag, name, closing))
        }), tags.count >= 2, tags.first?.1 == "div", tags.first?.2 == false,
              tags.last?.1 == "div", tags.last?.2 == true else { return false }
        let confirmedImageRanges = Set(htmlImages.map { $0.0 })
        var gaps: [NSRange] = [], styledTags: [(NSRange, MarkdownInlineStyle)] = [], cursor = range.location, tagStack: [String] = []
        var ownerStack: [MarkdownHTMLMediaService.ImageAncestor] = [], imageOwners: [NSRange: [MarkdownHTMLMediaService.ImageAncestor]] = [:]
        for (index, tag) in tags.enumerated() {
            if Task.isCancelled { return false }
            guard tag.0.location >= cursor, NSMaxRange(tag.0) <= NSMaxRange(range) else { return false }
            let selected = NSIntersectionRange(tag.0, selection)
            if selected.length > 0 && selected != tag.0 { return false }
            let spelling = raw.substring(with: tag.0).lowercased()
            if tag.1 == "img" {
                guard !tag.2, tagStack.first == "div" else { return false }
                if selected.length > 0 && !confirmedImageRanges.contains(tag.0) { return false }
                imageOwners[tag.0] = ownerStack
            } else {
                let spanStyle = tag.1 == "span" && !tag.2 ? MarkdownHTMLMediaService.inlineStyleOpening(raw.substring(with: tag.0), isCancelled: { Task.isCancelled }) : nil
                guard ["div", "strong", "b", "em", "i", "u", "s", "del", "mark", "sub", "sup", "kbd", "span"].contains(tag.1),
                      (spelling == "<" + (tag.2 ? "/" : "") + tag.1 + ">" || spanStyle != nil),
                      tag.1 != "div" || index == 0 || index == tags.count - 1 else { return false }
                if let spanStyle { styledTags.append((tag.0, spanStyle)) }
                if tag.2 {
                    guard tagStack.last == tag.1 else { return false }
                    tagStack.removeLast(); ownerStack.removeLast()
                } else {
                    tagStack.append(tag.1)
                    ownerStack.append(.init(name: tag.1, style: spanStyle))
                }
            }
            if cursor < tag.0.location { gaps.append(NSRange(location: cursor, length: tag.0.location - cursor)) }
            cursor = NSMaxRange(tag.0)
        }
        guard tagStack.isEmpty else { return false }
        if cursor < NSMaxRange(range) { gaps.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
        guard (gaps.isEmpty && styledTags.isEmpty) || htmlTextProofAllowed(range) else { return false }
        var proof: [TextProof] = []
        let points = (gaps.flatMap { [$0, NSRange(location: NSMaxRange($0) - 1, length: 1)] } + styledTags.map { $0.0 } + Array(imageOwners.keys)).sorted { $0.location < $1.location }
        guard let offsets = htmlLiteralOffsets(literal, range: range, tags: points) else { return false }
        for gap in gaps {
            if Task.isCancelled { return false }
            let value = raw.substring(with: gap)
            guard !value.contains("<"), !value.contains("\t") else { return false }
            guard let start = offsets[gap.location], let last = offsets[NSMaxRange(gap) - 1], last >= start, last < literal.length else { return false }
            let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            guard literal.substring(with: NSRange(location: start, length: last - start + 1)).utf16.elementsEqual(normalized.utf16) else { return false }
            proof.append(.init(start: start, end: last + 1, text: normalized))
        }
        let imagesForProof = htmlImages.filter { imageOwners[$0.0] != nil }
        var imageProof: [ImageProof] = [], ancestorProof: [Int: [MarkdownHTMLMediaService.ImageAncestor]] = [:]
        for image in imagesForProof {
            if Task.isCancelled { return false }
            guard let offset = offsets[image.0.location], let owners = imageOwners[image.0] else { return false }
            ancestorProof[imageProof.count] = owners
            imageProof.append(.init(offset: offset, source: image.2.source))
        }
        if !imageProof.isEmpty {
            guard !Task.isCancelled, provenImageCount(in: literal, candidates: imageProof, ancestors: ancestorProof) == imageProof.count else { return false }
        }
        var styleProof: [StyleProof] = []
        for (tag, value) in styledTags {
            guard let offset = offsets[tag.location] else { return false }
            styleProof.append(.init(offset: offset, style: value))
        }
        let confirmed = provenTextAndContainers(in: literal, candidates: proof, styleCandidates: styleProof) ?? [:]
        guard confirmed.count == proof.count, !Task.isCancelled else { return false }
        var firstVisible: (Int, Int)?, lastVisible: (Int, Int)?
        func whitespace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 }
        func entityEdge(_ gap: NSRange, decoded: NSString, leading: Bool) -> (Int, Bool)? {
            let spelling = raw.substring(with: gap) as NSString
            let normalized = spelling.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
            var boundaries = [0], offset = 0
            while offset < spelling.length {
                if Task.isCancelled { return nil }
                if spelling.character(at: offset) == 13, offset + 1 < spelling.length, spelling.character(at: offset + 1) == 10 { offset += 2 }
                else { offset += 1 }
                boundaries.append(offset)
            }
            guard boundaries.count == normalized.length + 1,
                  let pieces = MarkdownInlineTextProjection.pieces(spelling: normalized, literal: decoded as String,
                      sourceOffset: 0, isCancelled: { Task.isCancelled }) else { return nil }
            let ordered = leading ? pieces : pieces.reversed().map { $0 }
            for piece in ordered {
                if Task.isCancelled { return nil }
                let text = piece.text as NSString
                let start = piece.sourceRange.location, end = NSMaxRange(piece.sourceRange)
                guard start >= 0, end < boundaries.count else { return nil }
                let sourceRange = NSRange(location: gap.location + boundaries[start], length: boundaries[end] - boundaries[start])
                var index = leading ? 0 : text.length
                if leading {
                    while index < text.length && whitespace(text.character(at: index)) { index += 1 }
                } else {
                    while index > 0 && whitespace(text.character(at: index - 1)) { index -= 1 }
                }
                let hidden = leading ? index : text.length - index
                if hidden > 0 && !piece.matchesSource {
                    guard hidden == text.length else { return nil }
                    let selected = NSIntersectionRange(selection, sourceRange)
                    if selected.length > 0 && selected != sourceRange { return nil }
                }
                if hidden < text.length {
                    guard piece.matchesSource || hidden == 0 else { return nil }
                    return (leading ? gap.location + boundaries[start + hidden] : gap.location + boundaries[end - hidden], false)
                }
            }
            return (leading ? NSMaxRange(gap) : gap.location, true)
        }
        for index in gaps.indices {
            if Task.isCancelled { return false }
            let gap = gaps[index], decoded = (confirmed[index]?.text ?? "") as NSString
            if raw.substring(with: gap).contains("&") {
                guard let (start, empty) = entityEdge(gap, decoded: decoded, leading: true) else { return false }
                if empty { continue }
                firstVisible = (index, start); break
            }
            var start = gap.location
            while start < NSMaxRange(gap), whitespace(raw.character(at: start)) {
                if Task.isCancelled { return false }; start += 1
            }
            let prefix = raw.substring(with: NSRange(location: gap.location, length: start - gap.location))
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
            guard prefix.length <= decoded.length,
                  decoded.substring(with: NSRange(location: 0, length: prefix.length)).utf16.elementsEqual((prefix as String).utf16) else { return false }
            if start == NSMaxRange(gap) { guard prefix.length == decoded.length else { return false }; continue }
            guard prefix.length < decoded.length, !whitespace(decoded.character(at: prefix.length)) else { return false }
            firstVisible = (index, start); break
        }
        for index in gaps.indices.reversed() {
            if Task.isCancelled { return false }
            let gap = gaps[index], decoded = (confirmed[index]?.text ?? "") as NSString
            if raw.substring(with: gap).contains("&") {
                guard let (end, empty) = entityEdge(gap, decoded: decoded, leading: false) else { return false }
                if empty { continue }
                lastVisible = (index, end); break
            }
            var end = NSMaxRange(gap)
            while end > gap.location, whitespace(raw.character(at: end - 1)) {
                if Task.isCancelled { return false }; end -= 1
            }
            let suffix = raw.substring(with: NSRange(location: end, length: NSMaxRange(gap) - end))
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
            guard suffix.length <= decoded.length,
                  decoded.substring(from: decoded.length - suffix.length).utf16.elementsEqual((suffix as String).utf16) else { return false }
            if end == gap.location { guard suffix.length == decoded.length else { return false }; continue }
            guard suffix.length < decoded.length, !whitespace(decoded.character(at: decoded.length - suffix.length - 1)) else { return false }
            lastVisible = (index, end); break
        }
        if let visible = firstVisible, let first = gaps.first,
           visible.1 > first.location && tags.contains(where: { $0.1 == "img" && $0.0.location < visible.1 }) {
            guard visible.0 == 0,
                  tags.filter({ $0.1 == "img" && $0.0.location < visible.1 }).allSatisfy({ tag in
                      tag.0.location < first.location && confirmedImageRanges.contains(tag.0)
                  }) else { return false }
            firstVisible = (0, first.location)
        }
        if let visible = lastVisible, let last = gaps.last,
           visible.1 < NSMaxRange(last) && tags.contains(where: { $0.1 == "img" && $0.0.location >= visible.1 }) {
            guard visible.0 == gaps.count - 1,
                  tags.filter({ $0.1 == "img" && $0.0.location >= visible.1 }).allSatisfy({ tag in
                      tag.0.location >= NSMaxRange(last) && confirmedImageRanges.contains(tag.0)
                  }) else { return false }
            lastVisible = (gaps.count - 1, NSMaxRange(last))
        }
        if !gaps.isEmpty && confirmedImageRanges.isEmpty && (firstVisible == nil || lastVisible == nil) { return false }
        let images = htmlImages.sorted { $0.0.location < $1.0.location }
        var events: [(NSRange, Int?, Int?)] = gaps.enumerated().map { ($0.element, $0.offset, nil) }
        events += images.enumerated().map { ($0.element.0, nil, $0.offset) }
        events.sort { $0.0.location < $1.0.location }
        covered.append(range)
        let blockStart = max(range.location, selection.location), precedingEnd = lastEnd ?? selection.location
        if !insideTable && blockStart > precedingEnd {
            appendBreaks(in: NSIntersectionRange(selection, NSRange(location: precedingEnd, length: blockStart - precedingEnd)))
        }
        lastEnd = max(precedingEnd, blockStart)
        html += "<div>"
        var previousSpace = false
        for (event, textIndex, imageIndex) in events {
            if Task.isCancelled { invalid = true; return true }
            var part = NSIntersectionRange(event, selection)
            if let index = textIndex, let firstVisible, index < firstVisible.0 { continue }
            if let index = textIndex, let lastVisible, index > lastVisible.0 { continue }
            if let index = textIndex, let firstVisible, index == firstVisible.0, part.location < firstVisible.1 {
                let end = NSMaxRange(part)
                part = NSRange(location: min(firstVisible.1, end), length: max(0, end - firstVisible.1))
            }
            if let index = textIndex, let lastVisible, index == lastVisible.0, NSMaxRange(part) > lastVisible.1 {
                part.length = max(0, lastVisible.1 - part.location)
            }
            guard part.length > 0 else { continue }
            if let index = textIndex, let proven = confirmed[index] {
                var current = style
                if let inline = proven.inlineStyle { current.inlineStyle = style.inlineStyle.map { inline.inheriting($0) } ?? inline }
                for name in proven.styles {
                    switch name {
                    case "strong", "b": current.bold = true
                    case "em", "i": current.italic = true
                    case "u": current.underline = true
                    case "s", "del": current.strike = true
                    case "mark": current.highlight = true
                    case "sub": current.script = -1
                    case "sup": current.script = 1
                    case "kbd": current.keyboard = true
                    default: break
                    }
                }
                let spelling = raw.substring(with: event) as NSString
                let normalized = spelling.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
                var boundaries = [0], rawOffset = 0
                while rawOffset < spelling.length {
                    if Task.isCancelled { invalid = true; return true }
                    if spelling.character(at: rawOffset) == 13, rawOffset + 1 < spelling.length, spelling.character(at: rawOffset + 1) == 10 { rawOffset += 2 }
                    else { rawOffset += 1 }
                    boundaries.append(rawOffset)
                }
                guard boundaries.count == normalized.length + 1,
                      let projected = MarkdownInlineTextProjection.pieces(spelling: normalized, literal: proven.text, sourceOffset: 0, isCancelled: { Task.isCancelled }) else { invalid = true; return true }
                var pieces: [MarkdownReadableText.Piece] = []
                for piece in projected {
                    if Task.isCancelled { invalid = true; return true }
                    let start = piece.sourceRange.location, end = NSMaxRange(piece.sourceRange)
                    guard start >= 0, end < boundaries.count else { invalid = true; return true }
                    if !piece.matchesSource {
                        let value = ["\n", "\r", "\t"].contains(piece.text) ? " " : piece.text
                        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\t") else { invalid = true; return true }
                        pieces.append(.init(sourceRange: NSRange(location: event.location + boundaries[start], length: boundaries[end] - boundaries[start]), text: value, matchesSource: false))
                        continue
                    }
                    var position = start, runStart = start
                    while position < end {
                        if Task.isCancelled { invalid = true; return true }
                        if normalized.character(at: position) == 10 {
                            if position > runStart {
                                pieces.append(.init(sourceRange: NSRange(location: event.location + boundaries[runStart], length: boundaries[position] - boundaries[runStart]), text: normalized.substring(with: NSRange(location: runStart, length: position - runStart)), matchesSource: true))
                            }
                            pieces.append(.init(sourceRange: NSRange(location: event.location + boundaries[position], length: boundaries[position + 1] - boundaries[position]), text: " ", matchesSource: false))
                            runStart = position + 1
                        }
                        position += 1
                    }
                    if position > runStart {
                        pieces.append(.init(sourceRange: NSRange(location: event.location + boundaries[runStart], length: boundaries[position] - boundaries[runStart]), text: normalized.substring(with: NSRange(location: runStart, length: position - runStart)), matchesSource: true))
                    }
                }
                guard let selected = MarkdownReadableText.selected(pieces, in: part, isCancelled: { Task.isCancelled }), let mapped = selected.1 else { invalid = true; return true }
                let units = selected.0 as NSString, collapsed = NSMutableString(string: "")
                var position = 0, runStart = 0
                while position < units.length {
                    if Task.isCancelled { invalid = true; return true }
                    let space = units.character(at: position) == 32
                    if space && previousSpace {
                        if position > runStart { collapsed.append(units.substring(with: NSRange(location: runStart, length: position - runStart))) }
                        runStart = position + 1
                    }
                    previousSpace = space
                    position += 1
                }
                if position > runStart { collapsed.append(units.substring(with: NSRange(location: runStart, length: position - runStart))) }
                lastEnd = max(lastEnd ?? mapped.location, mapped.location)
                emit(collapsed as String, sourceRange: mapped, style: current)
            } else if let index = imageIndex {
                let image = images[index]
                previousSpace = false
                lastEnd = max(lastEnd ?? image.0.location, image.0.location)
                emitImage(range: image.0, address: image.1, alt: image.2.alt, title: image.2.title ?? "", css: image.2.sizing.css,
                          style: style, inlineOwners: imageOwners[image.0] ?? [])
            }
        }
        html += "</div>"
        let selectedBlock = NSIntersectionRange(range, selection)
        if selectedBlock.length > 0 { lastEnd = max(lastEnd ?? 0, NSMaxRange(selectedBlock)) }
        return true
    }
}
