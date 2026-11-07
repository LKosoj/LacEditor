import Foundation
import cmark_gfm
import cmark_gfm_extensions
import SwiftSoup

private final class MarkdownRubyBaseParseState {
    var isValid = true
    var isStyled = false
}

// Подтверждение HTML для ядра: блоки и строчные теги, медиа, SVG, ruby, details, twitter.
// Рендер и ядро вызывают помощники напрямую.
extension MarkdownDocumentParser {
    static func containerProofNode(_ node: OpaquePointer, isCancelled: () -> Bool) -> OpaquePointer? {
        var current = node
        while let parent = cmark_node_parent(current) {
            if isCancelled() { return nil }
            let kind = cmark_node_get_type(parent)
            if kind == CMARK_NODE_DOCUMENT || kind == CMARK_NODE_BLOCK_QUOTE || kind == CMARK_NODE_ITEM || kind == CMARK_NODE_LIST { return current }
            guard let name = cmark_node_get_type_string(parent),
                  ["paragraph", "heading", "strong", "emph", "link", "strikethrough"].contains(String(cString: name)) else { return nil }
            current = parent
        }
        return nil
    }

    static func multilineMediaOpening(_ node: OpaquePointer, source: MarkdownSourcePositions, sourceText: NSString,
                                      isCancelled: () -> Bool) -> (range: NSRange, prefixes: [NSRange])? {
        guard cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE, let pointer = cmark_node_get_literal(node) else { return nil }
        let literal = String(cString: pointer)
        let lowered = literal.lowercased()
        guard lowered.contains("\n"), let start = source.firstPosition(node), let proofNode = containerProofNode(node, isCancelled: isCancelled),
              ["<audio", "<video"].contains(where: { name in
                  lowered.hasPrefix(name) && lowered.dropFirst(name.count).first.map({ [" ", "\t", "\n"].contains($0) }) == true
              }) else { return nil }
        let parts = literal.components(separatedBy: "\n")
        var cursor = start, end = start, prefixes: [NSRange] = []
        for (index, part) in parts.enumerated() {
            if isCancelled() { return nil }
            guard cursor < sourceText.length else { return nil }
            let line = sourceText.lineRange(for: NSRange(location: cursor, length: 0))
            var contentEnd = NSMaxRange(line)
            while contentEnd > line.location && [10, 13].contains(Int(sourceText.character(at: contentEnd - 1))) { contentEnd -= 1 }
            var content = cursor
            if index > 0 {
                while content < contentEnd && [9, 32, 62].contains(Int(sourceText.character(at: content))) { content += 1 }
                guard fencePrefixes(proofNode, source: source, text: sourceText, position: content) != nil else { return nil }
                if content > line.location { prefixes.append(NSRange(location: line.location, length: content - line.location)) }
            }
            let length = (part as NSString).length
            guard content + length <= contentEnd, index == parts.count - 1 || content + length == contentEnd,
                  sourceText.substring(with: NSRange(location: content, length: length)).utf16.elementsEqual(part.utf16) else { return nil }
            end = content + length
            cursor = NSMaxRange(line)
        }
        return (NSRange(location: start, length: end - start), prefixes)
    }

    static func containerHTMLPrefixes(_ node: OpaquePointer, range: NSRange, source: MarkdownSourcePositions, sourceText: NSString, isCancelled: () -> Bool) -> [NSRange]? {
        guard let literalPointer = cmark_node_get_literal(node), range.length > 0,
              NSMaxRange(range) <= sourceText.length else { return nil }
        let literal = String(cString: literalPointer) as NSString
        var offset = 0, cursor = range.location, prefixes: [NSRange] = [], first = true
        while offset < literal.length {
            if isCancelled() { return nil }
            let remaining = NSRange(location: offset, length: literal.length - offset)
            let newline = literal.range(of: "\n", options: .literal, range: remaining)
            let end = newline.location == NSNotFound ? literal.length : newline.location
            let length = end - offset
            let line = sourceText.lineRange(for: NSRange(location: cursor, length: 0))
            var contentEnd = min(NSMaxRange(line), NSMaxRange(range))
            while contentEnd > cursor && [10, 13].contains(Int(sourceText.character(at: contentEnd - 1))) { contentEnd -= 1 }
            let start = contentEnd - length
            guard start >= cursor, (!first || start == range.location),
                  let proof = fencePrefixes(node, source: source, text: sourceText, position: start), proof.nested,
                  sourceText.substring(with: NSRange(location: start, length: length)).utf16
                    .elementsEqual(literal.substring(with: NSRange(location: offset, length: length)).utf16) else { return nil }
            if !first && start > line.location { prefixes.append(NSRange(location: line.location, length: start - line.location)) }
            first = false
            if newline.location == NSNotFound { return contentEnd == NSMaxRange(range) ? prefixes : nil }
            offset = newline.location + 1
            if offset == literal.length { return contentEnd == NSMaxRange(range) ? prefixes : nil }
            guard NSMaxRange(line) > cursor, NSMaxRange(line) <= NSMaxRange(range) else { return nil }
            cursor = NSMaxRange(line)
        }
        return nil
    }

    static func containerPrefixes(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString, isCancelled: @escaping () -> Bool = { false }) -> (source: String, continuation: String)? {
        var cached: [OpaquePointer: (Int, String)] = [:]
        func itemColumn(_ item: OpaquePointer) -> (Int, String)? {
            if isCancelled() { return nil }
            if let result = cached[item] { return result }
            guard let marker = source.firstPosition(item), marker < text.length,
                  let ancestors = fencePrefixes(item, source: source, text: text, position: marker,
                                                allowEarlierItem: false, itemStartColumn: itemColumn) else { return nil }
            var end = marker
            let first = text.character(at: end)
            if first == 45 || first == 43 || first == 42 { end += 1 }
            else {
                while end < text.length && text.character(at: end) >= 48 && text.character(at: end) <= 57 {
                    if isCancelled() { return nil }
                    end += 1
                }
                guard end > marker, end < text.length, text.character(at: end) == 46 || text.character(at: end) == 41 else { return nil }
                end += 1
            }
            let prefix = Array(ancestors.continuation.utf16)
            var column = prefix.reduce(0) { value, unit in unit == 9 ? (value / 4 + 1) * 4 : value + 1 }
            column += end - marker
            let padding = column
            while end < text.length && (text.character(at: end) == 32 || text.character(at: end) == 9) {
                if isCancelled() { return nil }
                column = text.character(at: end) == 9 ? (column / 4 + 1) * 4 : column + 1
                end += 1
            }
            guard (1...4).contains(column - padding), end < text.length,
                  text.character(at: end) != 10, text.character(at: end) != 13 else { return nil }
            var quoteEnd = prefix.lastIndex(of: 62).map { $0 + 1 } ?? 0
            if quoteEnd > 0 && quoteEnd < prefix.count && (prefix[quoteEnd] == 32 || prefix[quoteEnd] == 9) { quoteEnd += 1 }
            let result = (column, String(decoding: prefix[..<quoteEnd], as: UTF16.self))
            cached[item] = result
            return result
        }
        guard let position = source.firstPosition(node) else { return nil }
        var prefixPosition = position
        if cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH, let parent = cmark_node_parent(node),
           let name = cmark_node_get_type_string(parent), String(cString: name) == "tasklist" {
            guard let checkbox = source.taskCheckbox(parent), itemColumn(parent) != nil,
                  (checkbox.state != 32) == cmark_gfm_extensions_get_tasklist_item_checked(parent),
                  NSMaxRange(checkbox.markerRange) < position else { return nil }
            var cursor = NSMaxRange(checkbox.markerRange)
            while cursor < position && (text.character(at: cursor) == 32 || text.character(at: cursor) == 9) {
                if isCancelled() { return nil }
                cursor += 1
            }
            guard cursor == position else { return nil }
            prefixPosition = checkbox.markerRange.location
        }
        guard let prefixes = fencePrefixes(node, source: source, text: text, position: prefixPosition,
                                           allowEarlierItem: false, itemStartColumn: itemColumn), !isCancelled() else { return nil }
        return (prefixes.source, prefixes.continuation)
    }

    static func listContainerPrefixes(_ item: OpaquePointer, source: MarkdownSourcePositions, text: NSString) -> (source: String, continuation: String)? {
        guard cmark_node_get_type(item) == CMARK_NODE_ITEM else { return nil }
        return containerPrefixes(item, source: source, text: text)
    }

    struct InlineHTMLPair {
        let opening: OpaquePointer
        let closing: OpaquePointer
        let openingRange: NSRange
        let closingRange: NSRange
        let kind: MarkdownPresentationKind
        let href: String?
    }

    static func inlineAnchorHref(_ tag: String, isCancelled: () -> Bool) -> String? {
        let raw = tag as NSString
        guard raw.length >= 8, raw.substring(with: NSRange(location: 0, length: 2)).lowercased() == "<a" else { return nil }
        func whitespace(_ value: unichar) -> Bool { value == 32 || value == 9 || value == 10 || value == 13 }
        var cursor = 2
        guard whitespace(raw.character(at: cursor)) else { return nil }
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor + 4 <= raw.length, raw.substring(with: NSRange(location: cursor, length: 4)).lowercased() == "href" else { return nil }
        cursor += 4
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor < raw.length, raw.character(at: cursor) == 61 else { return nil }
        cursor += 1
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor < raw.length else { return nil }
        let quote = raw.character(at: cursor)
        if quote == 34 || quote == 39 {
            cursor += 1
            while cursor < raw.length && raw.character(at: cursor) != quote { if isCancelled() { return nil }; cursor += 1 }
            guard cursor < raw.length else { return nil }
            cursor += 1
        } else {
            let start = cursor
            while cursor < raw.length && !whitespace(raw.character(at: cursor)) && raw.character(at: cursor) != 62 {
                if isCancelled() { return nil }
                guard ![34, 39, 60, 61, 96].contains(Int(raw.character(at: cursor))) else { return nil }
                cursor += 1
            }
            guard cursor > start else { return nil }
        }
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor == raw.length - 1, raw.character(at: cursor) == 62, !isCancelled() else { return nil }
        do {
            let document = try SwiftSoup.parseBodyFragment(tag + "</a>")
            guard let body = document.body(), body.children().size() == 1, let anchor = body.children().first(),
                  anchor.tagName() == "a", anchor.getAttributes()?.asList().count == 1, anchor.hasAttr("href") else { return nil }
            let href = try anchor.attr("href")
            guard !href.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 92 }),
                  let components = URLComponents(string: href),
                  components.scheme.map({ ["http", "https", "mailto"].contains($0.lowercased()) }) ?? true else { return nil }
            return href
        } catch { return nil }
    }

    static func isSpanOpening(_ tag: String) -> Bool {
        let raw = tag.lowercased() as NSString
        guard raw.length > 5, raw.substring(to: 5) == "<span" else { return false }
        return [9, 10, 12, 13, 32, 62].contains(Int(raw.character(at: 5)))
    }

    static func filterInlineHTMLForStyles(_ nodes: [(OpaquePointer, NSRange?)], confirmed: Set<OpaquePointer>, text: NSString,
                                          isCancelled: @escaping () -> Bool = { false }) -> (confirmed: Set<OpaquePointer>, blocked: [NSRange]) {
        var hasSpan = false
        for (node, _) in nodes {
            if isCancelled() { return ([], []) }
            if let literal = cmark_node_get_literal(node), isSpanOpening(String(cString: literal)) { hasSpan = true; break }
        }
        if !hasSpan { return (confirmed, []) }
        var ordered: [(OpaquePointer, NSRange)] = []
        for (node, candidate) in nodes {
            if isCancelled() { return ([], []) }
            guard let range = candidate, htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else { return ([], [NSRange(location: 0, length: text.length)]) }
            ordered.append((node, range))
        }
        ordered.sort { $0.1.location < $1.1.location }
        var result: Set<OpaquePointer> = [], blockedParents: [OpaquePointer] = [], blocked: [NSRange] = [], blockedStart = 0, previousEnd = 0
        for (node, range) in ordered {
            if isCancelled() { return ([], []) }
            guard range.location >= previousEnd else { return ([], [NSRange(location: 0, length: text.length)]) }
            previousEnd = NSMaxRange(range)
            let raw = text.substring(with: range), tag = raw.lowercased()
            let opening = isSpanOpening(tag)
            let parent = cmark_node_parent(node)
            if !blockedParents.isEmpty {
                if opening, let parent { blockedParents.append(parent) }
                else if tag == "</span>", confirmed.contains(node), parent == blockedParents.last {
                    blockedParents.removeLast()
                    if blockedParents.isEmpty { blocked.append(NSRange(location: blockedStart, length: NSMaxRange(range) - blockedStart)) }
                }
                continue
            }
            if opening && MarkdownHTMLMediaService.hasStyledSpan(in: raw, isCancelled: isCancelled) &&
                (!confirmed.contains(node) || MarkdownHTMLMediaService.inlineStyleOpening(raw, isCancelled: isCancelled) == nil) {
                guard let parent else { return ([], [NSRange(location: 0, length: text.length)]) }
                blockedStart = range.location
                blockedParents.append(parent)
                continue
            }
            if confirmed.contains(node) { result.insert(node) }
        }
        if !blockedParents.isEmpty { blocked.append(NSRange(location: blockedStart, length: text.length - blockedStart)) }
        return (result, blocked)
    }

    static func inlineHTMLPairs(in parent: OpaquePointer, confirmed: Set<OpaquePointer>, source: MarkdownSourcePositions,
                                text: NSString, tablePositions: MarkdownSourcePositions.TableCellPositions? = nil,
                                mappedRange: ((OpaquePointer) -> NSRange?)? = nil, ignoreRubyTags: Bool = false, isCancelled: @escaping () -> Bool = { false }) -> [InlineHTMLPair] {
        let kinds: [String: MarkdownPresentationKind] = ["strong": .strong, "b": .strong, "em": .emphasis, "i": .emphasis, "u": .underline,
            "s": .strikethrough, "del": .strikethrough, "mark": .highlight, "sub": .subscriptText, "sup": .superscriptText, "kbd": .keyboard]
        var stack: [(node: OpaquePointer, name: String, range: NSRange, kind: MarkdownPresentationKind, href: String?, pairStart: Int)] = []
        var pairs: [InlineHTMLPair] = []
        var rejectedSpanDepth = 0
        func rejectOpenPairs() {
            if let first = stack.first, first.pairStart < pairs.count { pairs.removeSubrange(first.pairStart..<pairs.count) }
            stack.removeAll()
        }
        var child = cmark_node_first_child(parent)
        while let node = child {
            if isCancelled() { return [] }
            defer { child = cmark_node_next(node) }
            if cmark_node_get_type(node) != CMARK_NODE_HTML_INLINE {
                if stack.contains(where: { $0.kind == .link }) {
                    var pending = [node], found = false
                    while let current = pending.popLast() {
                        if isCancelled() { return [] }
                        if cmark_node_get_type(current) == CMARK_NODE_LINK { found = true; break }
                        if cmark_node_get_type(current) == CMARK_NODE_HTML_INLINE, let literal = cmark_node_get_literal(current),
                           String(cString: literal).lowercased().hasPrefix("<a") { found = true; break }
                        var nested = cmark_node_first_child(current)
                        while let item = nested { if isCancelled() { return [] }; pending.append(item); nested = cmark_node_next(item) }
                    }
                    if found { rejectOpenPairs() }
                }
                continue
            }
            let candidate: NSRange?
            if let tablePositions { candidate = source.tableInlineRange(node, positions: tablePositions) }
            else if let mappedRange { candidate = mappedRange(node) }
            else { candidate = source.range(node) }
            guard confirmed.contains(node), let range = candidate,
                  htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            let tag = text.substring(with: range).lowercased()
            if ignoreRubyTags && ["<ruby>", "</ruby>", "<rt>", "</rt>", "<rp>", "</rp>", "<br>", "<br/>", "<br />"].contains(tag) { continue }
            let spanOpening = isSpanOpening(tag)
            if rejectedSpanDepth > 0 {
                if spanOpening { rejectedSpanDepth += 1 }
                else if tag == "</span>" { rejectedSpanDepth -= 1 }
                continue
            }
            let closing = tag.hasPrefix("</")
            let name = String(tag.dropFirst(closing ? 2 : 1).dropLast())
            let href = !closing ? inlineAnchorHref(text.substring(with: range), isCancelled: isCancelled) : nil
            let anchor = href != nil || tag == "</a>"
            let spanStyle = spanOpening ? MarkdownHTMLMediaService.inlineStyleOpening(text.substring(with: range), isCancelled: isCancelled) : nil
            if spanOpening && !MarkdownHTMLMediaService.hasStyledSpan(in: text.substring(with: range), isCancelled: isCancelled) {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            if spanOpening && spanStyle == nil {
                if !stack.isEmpty { rejectOpenPairs() }
                rejectedSpanDepth = 1
                continue
            }
            let closingSpan = tag == "</span>"
            let kind: MarkdownPresentationKind? = anchor ? .link : (spanStyle.map { .inlineStyle($0) } ?? (closingSpan ? stack.last?.kind : kinds[name]))
            guard let kind, anchor || spanStyle != nil || closingSpan || (range.length <= 9 && tag == "<" + (closing ? "/" : "") + name + ">") else {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            if !closing {
                if kind == .link {
                    var ancestor: OpaquePointer? = parent, nested = stack.contains { $0.kind == .link }
                    while let current = ancestor { if isCancelled() { return [] }; if cmark_node_get_type(current) == CMARK_NODE_LINK { nested = true; break }; ancestor = cmark_node_parent(current) }
                    if nested { rejectOpenPairs(); continue }
                }
                stack.append((node, anchor ? "a" : (spanStyle != nil ? "span" : name), range, kind, href, pairs.count)); continue
            }
            guard let opening = stack.last, opening.name == (anchor ? "a" : name) else {
                if !stack.isEmpty { rejectOpenPairs() }
                continue
            }
            stack.removeLast()
            pairs.append(InlineHTMLPair(opening: opening.node, closing: node, openingRange: opening.range,
                                        closingRange: range, kind: opening.kind, href: opening.href))
        }
        if !stack.isEmpty { rejectOpenPairs() }
        return pairs
    }

    struct PairedMediaCollector {
        private var pending: [(name: String, node: OpaquePointer, parent: OpaquePointer, tag: NSRange, offset: Int)] = []
        private(set) var candidates: [(proof: MarkdownHTMLProof.MediaProofCandidate, range: NSRange, isInline: Bool)] = []
        /// Абзац из одного разорванного на строки открывающего тега и следующий html_block проверяются в DOM как один блок:
        /// на время проверки literal тега переносится в начало literal блока, смещения тегов блока считаются по объединённому literal.
        private(set) var merges: [(inline: OpaquePointer, block: OpaquePointer, literal: String)] = []

        mutating func cancelPending() { pending.removeAll() }

        mutating func consume(node: OpaquePointer, range: NSRange, tags: [(NSRange, String, Bool)],
                              sourceText: NSString, isCancelled: () -> Bool) {
            guard let parent = cmark_node_parent(node), let typePointer = cmark_node_get_type_string(node), !tags.isEmpty else { return }
            let type = String(cString: typePointer)
            var shift = 0, merged: String?
            if let first = pending.first, first.parent != parent {
                if type == "html_block", pending.count == 1, cmark_node_get_type(first.node) == CMARK_NODE_HTML_INLINE,
                   cmark_node_first_child(first.parent) == first.node, cmark_node_next(first.node) == nil,
                   cmark_node_get_type(first.parent) == CMARK_NODE_PARAGRAPH, cmark_node_next(first.parent) == node,
                   let opening = cmark_node_get_literal(first.node), String(cString: opening).contains("\n"),
                   let block = cmark_node_get_literal(node) {
                    let literal = String(cString: opening) + "\n"
                    let combined = literal + String(cString: block)
                    shift = (literal as NSString).length
                    merged = combined
                    pending[0] = (name: first.name, node: node, parent: parent, tag: first.tag, offset: 0)
                    merges.append((first.node, node, combined))
                } else { pending.removeAll() }
            }
            let parentType = cmark_node_get_type_string(parent).map { String(cString: $0) }
            let supportedParent = type == "html_block" || ["paragraph", "heading", "strong", "emph", "strikethrough", "link"].contains(parentType ?? "")
            let positions = tags.flatMap { [$0.0, NSRange(location: NSMaxRange($0.0) - 1, length: 1)] }.sorted { $0.location < $1.location }
            let offsets = type == "html_block" ? MarkdownHTMLProof.htmlBlockTagOffsets(node, range: range, tags: positions, sourceText: sourceText, isCancelled: isCancelled) : nil
            for (tag, name, closing) in tags {
                if isCancelled() { return }
                guard supportedParent, let start = type == "html_block" ? offsets?[tag.location].map({ $0 + shift }) : 0,
                      let last = type == "html_block" ? offsets?[NSMaxRange(tag) - 1].map({ $0 + shift }) : tag.length - 1 else { pending.removeAll(); continue }
                let opening = (name: name, node: node, parent: parent, tag: tag, offset: start)
                if !closing && name != "embed" {
                    pending.append(opening)
                    continue
                }
                // `<embed>` не имеет закрывающего тега: он сам себе пара.
                guard let pending = closing ? self.pending.last : opening else { self.pending.removeAll(); continue }
                if closing {
                    guard pending.name == name, pending.parent == parent, (type != "html_block" || pending.node == node),
                          pending.tag.location <= tag.location else { self.pending.removeAll(); continue }
                    self.pending.removeLast()
                }
                if !self.pending.isEmpty { continue }
                let whole = NSRange(location: pending.tag.location, length: NSMaxRange(tag) - pending.tag.location)
                let html: String
                var isInline = true
                if type == "html_block" {
                    guard let pointer = cmark_node_get_literal(node) else { continue }
                    let literal = (merged ?? String(cString: pointer)) as NSString
                    guard pending.offset <= last, last < literal.length else { continue }
                    html = literal.substring(with: NSRange(location: pending.offset, length: last - pending.offset + 1))
                    let before = NSRange(location: 0, length: pending.offset)
                    let after = NSRange(location: last + 1, length: literal.length - last - 1)
                    isInline = !(literal.substring(with: before).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        literal.substring(with: after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else { html = sourceText.substring(with: whole) }
                let expected: MarkdownHTMLMediaService.ProvenMedia
                if name == "iframe", let frame = MarkdownHTMLMediaService.iframe(in: html) { expected = .frame(frame) }
                else if name != "iframe", let media = MarkdownHTMLMediaService.embeddedMedia(in: html) { expected = .media(media) }
                else { continue }
                let proof = MarkdownHTMLProof.MediaProofCandidate(openingNode: pending.node, openingOffset: pending.offset,
                    closingNode: node, closingOffset: last + 1, expected: expected)
                candidates.append((proof, whole, isInline))
            }
        }
    }

    struct StandaloneSVG {
        let proof: MarkdownHTMLProof.SVGProofCandidate
        let range: NSRange
        let data: Data
        let paragraph: OpaquePointer?
        var isInline: Bool = false
    }

    static func standaloneSVGBlockCandidate(_ node: OpaquePointer, range: NSRange, text: NSString,
                                            isCancelled: () -> Bool) -> StandaloneSVG? {
        guard cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK, let pointer = cmark_node_get_literal(node) else { return nil }
        let literal = String(cString: pointer) as NSString
        var start = 0, end = literal.length
        while start < end && [9, 10, 12, 13, 32].contains(Int(literal.character(at: start))) { if isCancelled() { return nil }; start += 1 }
        while end > start && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { if isCancelled() { return nil }; end -= 1 }
        guard end - start >= 4, literal.substring(with: NSRange(location: start, length: 4)) == "<svg" else { return nil }
        let svg = literal.substring(with: NSRange(location: start, length: end - start))
        guard let data = MarkdownImageUploadService.standaloneSVGData(svg, isCancelled: isCancelled),
              MarkdownHTMLProof.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: text, isCancelled: isCancelled) != nil else { return nil }
        return StandaloneSVG(proof: .init(opening: node, openingOffset: start, closing: node, closingOffset: end, literal: svg),
                             range: range, data: data, paragraph: nil)
    }

    static func standaloneSVGInlineCandidates(parents: [OpaquePointer], confirmed: Set<OpaquePointer>, source: MarkdownSourcePositions,
                                              text: NSString, isCancelled: () -> Bool) -> [StandaloneSVG] {
        var candidates: [StandaloneSVG] = []
        for parent in parents where cmark_node_get_type(parent) == CMARK_NODE_PARAGRAPH {
            if isCancelled() { return [] }
            guard let paragraphRange = source.range(parent), paragraphRange.location >= 0,
                  NSMaxRange(paragraphRange) <= text.length else { continue }
            var child = cmark_node_first_child(parent)
            while let first = child {
                if isCancelled() { return [] }
                child = cmark_node_next(first)
                guard cmark_node_get_type(first) == CMARK_NODE_HTML_INLINE, confirmed.contains(first),
                      let firstRange = source.range(first), firstRange.length >= 4,
                      firstRange.location >= paragraphRange.location, NSMaxRange(firstRange) <= NSMaxRange(paragraphRange),
                      htmlSourceMatches(first, range: firstRange, text: text, isCancelled: isCancelled),
                      text.substring(with: NSRange(location: firstRange.location, length: 4)) == "<svg" else { continue }
                var cursor = NSMaxRange(firstRange), next = cmark_node_next(first), closing: OpaquePointer?
                while let node = next {
                    if isCancelled() { return [] }
                    let kind = cmark_node_get_type(node)
                    guard let childRange = source.range(node), childRange.location == cursor,
                          childRange.length <= NSMaxRange(paragraphRange) - cursor, let pointer = cmark_node_get_literal(node) else { break }
                    if kind == CMARK_NODE_HTML_INLINE {
                        guard confirmed.contains(node), htmlSourceMatches(node, range: childRange, text: text, isCancelled: isCancelled) else { break }
                    } else if kind == CMARK_NODE_TEXT {
                        let value = String(cString: pointer)
                        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              text.substring(with: childRange).utf16.elementsEqual(value.utf16) else { break }
                    } else { break }
                    cursor = NSMaxRange(childRange)
                    next = cmark_node_next(node)
                    if kind == CMARK_NODE_HTML_INLINE && text.substring(with: childRange).lowercased() == "</svg>" { closing = node; break }
                }
                guard let last = closing, let lastLiteral = cmark_node_get_literal(last) else { child = next; continue }
                child = next
                let range = NSRange(location: firstRange.location, length: cursor - firstRange.location)
                let svg = text.substring(with: range)
                guard let data = MarkdownImageUploadService.standaloneSVGData(svg, isCancelled: isCancelled) else { continue }
                let inline = range != paragraphRange
                candidates.append(StandaloneSVG(proof: .init(opening: first, openingOffset: 0, closing: last,
                    closingOffset: (String(cString: lastLiteral) as NSString).length, literal: svg), range: range, data: data, paragraph: parent, isInline: inline))
            }
        }
        return candidates
    }

    static func unconfirmedRubyRanges(tags: [(parent: OpaquePointer, range: NSRange, closing: Bool)],
                                      accepted: Set<NSRange>, sourceLength: Int,
                                      parentRange: (OpaquePointer) -> NSRange?, isCancelled: () -> Bool) -> [NSRange] {
        var open: [(OpaquePointer, Int)] = [], blocked: [NSRange] = []
        for tag in tags {
            if isCancelled() { return [] }
            if !tag.closing { open.append((tag.parent, tag.range.location)); continue }
            guard let opening = open.last, opening.0 == tag.parent, NSMaxRange(tag.range) >= opening.1 else { continue }
            open.removeLast()
            let range = NSRange(location: opening.1, length: NSMaxRange(tag.range) - opening.1)
            if !accepted.contains(range) { blocked.append(range) }
        }
        for opening in open {
            if isCancelled() { return [] }
            let parentEnd = parentRange(opening.0).map { min(sourceLength, NSMaxRange($0)) } ?? sourceLength
            let end = parentEnd > opening.1 ? parentEnd : sourceLength
            blocked.append(NSRange(location: opening.1, length: end - opening.1))
        }
        return blocked
    }

    static func inlineRubyCandidates(parents: [OpaquePointer], confirmed: Set<OpaquePointer>, source: MarkdownSourcePositions, text: NSString,
                                     sourceRange: (OpaquePointer) -> NSRange?, isCancelled: @escaping () -> Bool) -> [(proof: MarkdownHTMLProof.RubyProofCandidate, value: MarkdownRuby)] {
        var candidates: [(proof: MarkdownHTMLProof.RubyProofCandidate, value: MarkdownRuby)] = []
        for parent in parents where cmark_node_get_type(parent) == CMARK_NODE_PARAGRAPH {
            if isCancelled() { break }
            let outerPairs = withoutActuallyEscaping(sourceRange) { mappedRange in
                inlineHTMLPairs(in: parent, confirmed: confirmed, source: source, text: text,
                                mappedRange: mappedRange, ignoreRubyTags: true, isCancelled: isCancelled)
            }
            var pairedNodes: Set<OpaquePointer> = []
            for pair in outerPairs {
                if isCancelled() { return [] }
                pairedNodes.insert(pair.opening); pairedNodes.insert(pair.closing)
            }
            var sibling = cmark_node_first_child(parent), unpairedStyle = false
            while let node = sibling {
                if isCancelled() { return [] }
                sibling = cmark_node_next(node)
                guard cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE, confirmed.contains(node),
                      let range = sourceRange(node), htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else { continue }
                let raw = text.substring(with: range), tag = raw.lowercased()
                let styles = ["strong", "b", "em", "i", "u", "s", "del", "mark", "sub", "sup", "kbd"]
                let styleTag = styles.contains { tag == "<" + $0 + ">" || tag == "</" + $0 + ">" }
                    || MarkdownHTMLMediaService.inlineStyleOpening(raw, isCancelled: isCancelled) != nil
                    || tag == "</span>" || inlineAnchorHref(raw, isCancelled: isCancelled) != nil || tag == "</a>"
                if styleTag && !pairedNodes.contains(node) { unpairedStyle = true; break }
            }
            if unpairedStyle { continue }
            var child = cmark_node_first_child(parent)
            while let opening = child {
                if isCancelled() { break }
                child = cmark_node_next(opening)
                func tag(_ node: OpaquePointer?, _ expected: String) -> NSRange? {
                    guard let node, cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE, confirmed.contains(node),
                          let range = sourceRange(node),
                          htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled),
                          text.substring(with: range).lowercased() == expected else { return nil }
                    return range
                }
                func textNode(_ node: OpaquePointer?) -> (NSRange, String)? {
                    guard let node, cmark_node_get_type(node) == CMARK_NODE_TEXT,
                          let range = sourceRange(node), range.location >= 0, range.location <= text.length,
                          range.length > 0, range.length <= text.length - range.location,
                          let literal = cmark_node_get_literal(node) else { return nil }
                    let value = String(cString: literal)
                    guard let pieces = MarkdownInlineTextProjection.pieces(spelling: text.substring(with: range) as NSString, literal: value, sourceOffset: range.location, isCancelled: isCancelled), !value.isEmpty, value.rangeOfCharacter(from: .newlines) == nil,
                          pieces.map(\.text).joined().utf16.elementsEqual(value.utf16),
                          inlineDecorations(node, source: source, text: text, mappedRange: range).isEmpty else { return nil }
                    return (range, value)
                }
                guard let openRange = tag(opening, "<ruby>"), let baseNode = cmark_node_next(opening) else { continue }
                var base = "", baseHTML = "", editingBaseHTML = "", baseRuns: [MarkdownRubyBaseRun] = []
                var cursor = NSMaxRange(openRange), baseNext: OpaquePointer? = baseNode
                let baseState = MarkdownRubyBaseParseState()
                struct BaseStyle { var bold = false; var italic = false; var foreground: MarkdownSRGBColor? }
                var style = BaseStyle(), styleStack: [(String, BaseStyle)] = []
                func escape(_ value: String) -> String {
                    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                }
                func walkBase(_ node: OpaquePointer, floor: Int) {
                    guard baseState.isValid, !isCancelled(), let range = sourceRange(node), range.location == cursor,
                          range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length else { baseState.isValid = false; return }
                    let type = cmark_node_get_type(node)
                    if type == CMARK_NODE_TEXT {
                        guard let (_, value) = textNode(node) else { baseState.isValid = false; return }
                        let start = (base as NSString).length
                        base += value; baseHTML += escape(value); editingBaseHTML += escape(value)
                        baseRuns.append(.init(range: NSRange(location: start, length: (value as NSString).length), bold: style.bold, italic: style.italic, foreground: style.foreground))
                        cursor = NSMaxRange(range); return
                    }
                    if type == CMARK_NODE_STRONG || type == CMARK_NODE_EMPH {
                        let strong = type == CMARK_NODE_STRONG, count = strong ? 2 : 1
                        let markers = source.pairedMarkers(range, characters: [42, 95], count: count)
                        guard markers.count == 2 else { baseState.isValid = false; return }
                        let name = strong ? "strong" : "em", previous = style, depth = styleStack.count
                        if strong { style.bold = true } else { style.italic = true }
                        baseState.isStyled = true; baseHTML += "<" + name + ">"; editingBaseHTML += "<" + name + ">"
                        cursor = NSMaxRange(markers[0])
                        var child = cmark_node_first_child(node)
                        while let current = child { walkBase(current, floor: depth); child = cmark_node_next(current) }
                        guard baseState.isValid, styleStack.count == depth, cursor == markers[1].location else { baseState.isValid = false; return }
                        cursor = NSMaxRange(markers[1]); style = previous
                        baseHTML += "</" + name + ">"; editingBaseHTML += "</" + name + ">"
                        return
                    }
                    guard type == CMARK_NODE_HTML_INLINE, confirmed.contains(node),
                          htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else { baseState.isValid = false; return }
                    let spelling = text.substring(with: range), lower = spelling.lowercased()
                    if ["<strong>", "<em>"].contains(lower) {
                        let name = lower == "<strong>" ? "strong" : "em"
                        styleStack.append((name, style)); if name == "strong" { style.bold = true } else { style.italic = true }
                        baseHTML += lower; editingBaseHTML += lower
                    } else if ["</strong>", "</em>", "</span>"].contains(lower) {
                        let name = String(lower.dropFirst(2).dropLast())
                        guard styleStack.count > floor, let previous = styleStack.popLast(), previous.0 == name else { baseState.isValid = false; return }
                        style = previous.1; baseHTML += lower; editingBaseHTML += lower
                    } else if let inlineStyle = MarkdownHTMLMediaService.inlineStyleOpening(spelling, isCancelled: isCancelled),
                              inlineStyle.background == nil, inlineStyle.fontSizeRem == nil {
                        styleStack.append(("span", style))
                        if let color = inlineStyle.foreground { style.foreground = color }
                        baseHTML += spelling
                        editingBaseHTML += inlineStyle.editingCSS.isEmpty ? "<span>" : "<span style=\"" + escape(inlineStyle.editingCSS) + "\">"
                    } else { baseState.isValid = false; return }
                    baseState.isStyled = true; cursor = NSMaxRange(range)
                }
                while let node = baseNext, tag(node, "<rt>") == nil, tag(node, "<rp>") == nil {
                    walkBase(node, floor: 0)
                    if !baseState.isValid { break }
                    baseNext = cmark_node_next(node)
                }
                guard baseState.isValid, styleStack.isEmpty, !base.isEmpty else { continue }
                let baseRange = NSRange(location: NSMaxRange(openRange), length: cursor - NSMaxRange(openRange))
                if baseState.isStyled, MarkdownHTMLMediaService.rubyNeedsWhitespaceProjection(base, isCancelled: isCancelled) != false { continue }
                var next = baseNext, before: String?, after: String?
                func fallback(_ node: inout OpaquePointer?, cursor: inout Int) -> String? {
                    guard let begin = tag(node, "<rp>"), begin.location == cursor, let open = node,
                          let content = cmark_node_next(open), let (range, value) = textNode(content), range.location == NSMaxRange(begin),
                          let closeNode = cmark_node_next(content), let close = tag(closeNode, "</rp>"), close.location == NSMaxRange(range) else { return nil }
                    cursor = NSMaxRange(close); node = cmark_node_next(closeNode)
                    return value
                }
                if tag(next, "<rp>") != nil { guard let value = fallback(&next, cursor: &cursor) else { continue }; before = value }
                guard let rt = next, let rtRange = tag(rt, "<rt>"), rtRange.location == cursor,
                      let readingNode = cmark_node_next(rt), let (readingRange, reading) = textNode(readingNode),
                      readingRange.location == NSMaxRange(rtRange), let rtCloseNode = cmark_node_next(readingNode),
                      let rtClose = tag(rtCloseNode, "</rt>"), rtClose.location == NSMaxRange(readingRange) else { continue }
                guard !base.utf16.contains(where: { [9, 10, 12, 13].contains(Int($0)) }),
                      !reading.utf16.contains(where: { [9, 10, 12, 13].contains(Int($0)) }),
                      let displayBase = MarkdownHTMLMediaService.rubyDisplayText(base, isCancelled: isCancelled), !displayBase.isEmpty,
                      let displayReading = MarkdownHTMLMediaService.rubyDisplayText(reading, isCancelled: isCancelled), !displayReading.isEmpty else { continue }
                cursor = NSMaxRange(rtClose); next = cmark_node_next(rtCloseNode)
                if tag(next, "<rp>") != nil { guard let value = fallback(&next, cursor: &cursor) else { continue }; after = value }
                var trailing: String?
                if let node = next, cmark_node_get_type(node) == CMARK_NODE_TEXT {
                    guard let (range, value) = textNode(node), range.location == cursor,
                          value.utf16.allSatisfy({ $0 == 32 }) else { continue }
                    trailing = value; cursor = NSMaxRange(range); next = cmark_node_next(node)
                }
                guard let closing = next, let closeRange = tag(closing, "</ruby>"), closeRange.location == cursor else { continue }
                let range = NSRange(location: openRange.location, length: NSMaxRange(closeRange) - openRange.location)
                var unsupportedOuterStyle = false
                for pair in outerPairs where NSMaxRange(pair.openingRange) <= range.location && NSMaxRange(range) <= pair.closingRange.location {
                    if isCancelled() { return [] }
                    switch pair.kind {
                    case .strong, .emphasis: break
                    case .inlineStyle(let style):
                        if style.background != nil || style.fontSizeRem != nil { unsupportedOuterStyle = true }
                    default: unsupportedOuterStyle = true
                    }
                }
                if unsupportedOuterStyle { continue }
                guard let baseWhitespace = MarkdownHTMLMediaService.rubyNeedsWhitespaceProjection(base, isCancelled: isCancelled),
                      let readingWhitespace = MarkdownHTMLMediaService.rubyNeedsWhitespaceProjection(reading, isCancelled: isCancelled) else { continue }
                let needsWhitespaceProjection = baseWhitespace || readingWhitespace || trailing != nil
                if needsWhitespaceProjection {
                    guard cmark_node_first_child(parent) == opening, cmark_node_next(closing) == nil,
                          let paragraphRange = sourceRange(parent), paragraphRange == range else { continue }
                }
                candidates.append((.init(opening: opening, closing: closing, closingOffset: closeRange.length,
                                             base: base, reading: reading, before: before, after: after, trailing: trailing,
                                             baseHTML: baseState.isStyled ? baseHTML : nil, editingBaseHTML: baseState.isStyled ? editingBaseHTML : nil),
                                       MarkdownRuby(range: range, baseRange: baseRange, readingRange: readingRange, base: base, reading: reading,
                                                    baseRuns: baseState.isStyled ? baseRuns : [])))
                child = cmark_node_next(closing)
            }
        }
        return isCancelled() ? [] : candidates
    }

    static func htmlSourceMatches(_ node: OpaquePointer, range: NSRange, text: NSString,
                                  isCancelled: () -> Bool = { false }) -> Bool {
        guard let literal = cmark_node_get_literal(node) else { return false }
        return htmlSourceMatches(literal: String(cString: literal) as NSString, isBlock: cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK,
                                 range: range, text: text, isCancelled: isCancelled)
    }

    /// То же по тексту литерала без узла cmark (модель хранит `HTMLBlock.literal`).
    static func htmlSourceMatches(literal value: NSString, isBlock: Bool, range: NSRange, text: NSString,
                                  isCancelled: () -> Bool = { false }) -> Bool {
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return false }
        var sourceIndex = range.location, literalIndex = 0
        while sourceIndex < NSMaxRange(range) && literalIndex < value.length {
            if isCancelled() { return false }
            var unit = text.character(at: sourceIndex)
            sourceIndex += 1
            if unit == 13 {
                if sourceIndex < NSMaxRange(range), text.character(at: sourceIndex) == 10 { sourceIndex += 1 }
                unit = 10
            }
            guard unit == value.character(at: literalIndex) else { return false }
            literalIndex += 1
        }
        guard sourceIndex == NSMaxRange(range) else { return false }
        if literalIndex == value.length { return !isCancelled() }
        guard isBlock,
              literalIndex + 1 == value.length, value.character(at: literalIndex) == 10 else { return false }
        return !isCancelled() && (sourceIndex == text.length || [10, 13].contains(Int(text.character(at: sourceIndex))))
    }
}

// MARK: - Подтверждение HTML для модели

extension MarkdownDocumentParser {
    /// Итог подтверждения HTML одного разбора: считается один раз до обхода блоков.
    final class HTMLConfirmation {
        /// Слитый строчный узел: от открывающего тега до `last`.
        struct Merge {
            let last: OpaquePointer
            let kind: MarkdownInlineNode.Kind
            let range: NSRange
            let markers: [NSRange]
        }
        /// Подтверждённый вид html_block; нет записи — сырой HTML.
        var blocks: [OpaquePointer: MarkdownBlockNode.HTMLBlock.Kind] = [:]
        /// Открывающий узел → слитый узел (media, iframe, svg, ruby, `<img>`).
        var merges: [OpaquePointer: Merge] = [:]
        /// Открывающий узел → пара тегов (`kbd`, `u`, `mark`, `sub`, `sup`, `span`, `a`).
        var pairs: [OpaquePointer: InlineHTMLPair] = [:]
        /// Неподтверждённые строчные теги и ruby: показ их не оформляет (`blockedHTML` редактора).
        var blocked: [NSRange] = []
        /// Подтверждённые HTML-узлы по порядку документа (диапазоны) и признак, что весь HTML-контекст прослежен (`smartRawHTMLRanges`, `blockIndex`).
        var ranges: [NSRange] = []
        var rangesAvailable = true
        /// Текст с погашенными префиксами контейнеров; nil — совпадает с замаскированным.
        var contextText: NSString?
        /// Подтверждённые строчные теги (после отбора для стилей) и диапазоны `<img>` с размерами: нужны участкам верхнего регистра.
        var confirmedInline = Set<OpaquePointer>()
        var images = Set<NSRange>()
    }

    private static let htmlWhitespace: Set<Int> = [9, 10, 12, 13, 32]

    private static func trimmedBounds(_ literal: NSString, isCancelled: () -> Bool) -> (start: Int, end: Int) {
        var start = 0, end = literal.length
        while start < end && htmlWhitespace.contains(Int(literal.character(at: start))) { if isCancelled() { break }; start += 1 }
        while end > start && htmlWhitespace.contains(Int(literal.character(at: end - 1))) { if isCancelled() { break }; end -= 1 }
        return (start, end)
    }

    /// Подтверждает HTML-узлы документа: блоки, парные теги, media, SVG, ruby, `<img>`.
    /// Правила — как у рендера: HTML принимается, только если литерал cmark совпал с исходником
    /// и повторный разбор cmark с маркерами вернул ожидаемое (`MarkdownHTMLMediaService.proven*`).
    static func confirmHTML(root: OpaquePointer, cmarkOptions: Int32, ctx: Context) -> HTMLConfirmation {
        let result = HTMLConfirmation()
        let text = ctx.masked
        guard text.range(of: "<").location != NSNotFound else { return result }
        let source = ctx.source, ext = ctx.ext
        let isCancelled = ctx.isCancelled
        var htmlText: NSMutableString?
        var htmlContext = MarkdownImageUploadService.HTMLContext()
        var lastEnd = 0, templateDepth = 0, scriptStartedInContainer = false
        // Сырой script в контейнере: текст между тегами и открывающий тег доказывают префиксы контейнера в промежутке.
        var scriptOpeningNode: OpaquePointer?, scriptGapUnproven = false
        var scriptGapText: [(range: NSRange, node: OpaquePointer)] = []
        var mediaCollector = PairedMediaCollector()
        var lazyRanges: [OpaquePointer: [OpaquePointer: NSRange]?] = [:]
        // Как в рендере: ленивые диапазоны абзаца берутся первыми и только если в исходном (не маскированном) тексте есть `<span`.
        var rendererLazy: [OpaquePointer: [OpaquePointer: NSRange]?] = [:]
        let hasStyledSpanCandidate = (ctx.text as String).localizedCaseInsensitiveContains("<span")
        var inlineParents: [OpaquePointer] = [], seenParents = Set<OpaquePointer>()
        var allInlineHTML: [(OpaquePointer, NSRange?)] = [], confirmedInline = Set<OpaquePointer>()
        var rubyTags: [(parent: OpaquePointer, range: NSRange, closing: Bool)] = []
        var twitter: [(node: OpaquePointer, proof: MarkdownHTMLProof.TwitterProofCandidate)] = []
        var htmlBlocks: [(node: OpaquePointer, proof: MarkdownHTMLProof.HTMLBlockCandidate, display: String)] = []
        var standalone: [(node: OpaquePointer, media: MarkdownHTMLMediaService.StandaloneMedia)] = []
        var pageBreaks: [(node: OpaquePointer, offset: Int, style: String)] = []
        var details: [(node: OpaquePointer, offset: Int, summary: String, body: String)] = []
        var svgs: [StandaloneSVG] = []
        var imageCandidates: [(node: OpaquePointer, image: MarkdownInlineNode.Image, range: NSRange, source: String, offset: Int, isBlock: Bool)] = []
        var tableParents: [(parent: OpaquePointer, cell: OpaquePointer)] = [], tableParentSet = Set<OpaquePointer>()
        let containerTypes: Set<String> = ["paragraph", "heading", "strong", "emph", "link", "strikethrough"]

        func rangeOf(_ node: OpaquePointer, cell: OpaquePointer?, prefixes: inout [NSRange]?) -> NSRange? {
            if let cell {
                return ctx.tablePositions(cell).flatMap { source.tableInlineRange(node, positions: $0) }
            }
            if cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE,
               let opening = multilineMediaOpening(node, source: source, sourceText: text, isCancelled: isCancelled) {
                prefixes = opening.prefixes
                return opening.range
            }
            if hasStyledSpanCandidate, let parent = cmark_node_parent(node), cmark_node_get_type(parent) == CMARK_NODE_PARAGRAPH {
                if rendererLazy[parent] == nil {
                    rendererLazy[parent] = .some(source.lazyParagraphInlineRanges(parent, text: text, isCancelled: isCancelled))
                }
                if let range = rendererLazy[parent]??[node] { return range }
            }
            // Многострочный абзац: позиции cmark на строках продолжения не учитывают отступ (диапазон есть, но сдвинут), поэтому
            // подтверждённые диапазоны абзаца берутся первыми.
            return paragraphLazy(from: cmark_node_parent(node))?[node] ?? source.range(node)
        }

        /// Подтверждённые диапазоны узлов абзаца (в том числе вложенных в `**…**`, ссылку и т. п.); `start` — абзац или строчный контейнер в нём.
        func paragraphLazy(from start: OpaquePointer?) -> [OpaquePointer: NSRange]? {
            var current = start
            while let node = current {
                if cmark_node_get_type(node) == CMARK_NODE_PARAGRAPH {
                    if lazyRanges[node] == nil {
                        lazyRanges[node] = .some(source.lazyParagraphInlineRanges(node, text: text, plainEditing: true, inlineMath: ctx.mathInline,
                                                                                  referenceLinks: true, isCancelled: isCancelled))
                    }
                    return lazyRanges[node] ?? nil
                }
                guard let name = cmark_node_get_type_string(node), ["strong", "emph", "link", "strikethrough"].contains(String(cString: name)) else { return nil }
                current = cmark_node_parent(node)
            }
            return nil
        }

        func insideContainer(_ node: OpaquePointer) -> Bool {
            var ancestor = cmark_node_parent(node)
            while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
                let kind = cmark_node_get_type(current)
                if kind == CMARK_NODE_BLOCK_QUOTE || kind == CMARK_NODE_ITEM || kind == CMARK_NODE_LIST { return true }
                ancestor = cmark_node_parent(current)
            }
            return false
        }

        func scriptGapPrefixes(before node: OpaquePointer, range: NSRange) -> [NSRange]? {
            guard !scriptGapUnproven, let opening = scriptOpeningNode, lastEnd <= range.location else { return nil }
            let end = range.location
            var cursor = lastEnd, index = 0, prefixes: [NSRange] = []
            while cursor < end {
                if isCancelled() { return nil }
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                var contentEnd = min(NSMaxRange(line), end)
                while contentEnd > cursor && [10, 13].contains(Int(text.character(at: contentEnd - 1))) { contentEnd -= 1 }
                while index < scriptGapText.count && NSMaxRange(scriptGapText[index].range) <= cursor { index += 1 }
                var content = cursor
                if line.location >= lastEnd {
                    let first = index < scriptGapText.count && scriptGapText[index].range.location < contentEnd ? scriptGapText[index] : nil
                    let currentHTML = range.location < NSMaxRange(line)
                    let prefixEnd = first?.range.location ?? (currentHTML ? range.location : contentEnd)
                    guard let proofNode = containerProofNode(first?.node ?? (currentHTML ? node : opening), isCancelled: isCancelled) else { return nil }
                    guard prefixEnd >= line.location, prefixEnd <= contentEnd,
                          fencePrefixes(proofNode, source: source, text: text, position: prefixEnd) != nil else { return nil }
                    if prefixEnd > line.location { prefixes.append(NSRange(location: line.location, length: prefixEnd - line.location)) }
                    content = prefixEnd
                }
                while content < contentEnd {
                    if isCancelled() { return nil }
                    while index < scriptGapText.count && NSMaxRange(scriptGapText[index].range) <= content { index += 1 }
                    if index < scriptGapText.count, scriptGapText[index].range.location <= content,
                       NSMaxRange(scriptGapText[index].range) > content {
                        content = min(contentEnd, NSMaxRange(scriptGapText[index].range))
                    } else if [9, 32].contains(Int(text.character(at: content))) { content += 1 }
                    else { return nil }
                }
                let next = min(end, NSMaxRange(line))
                guard next > cursor else { return nil }
                cursor = next
            }
            return prefixes
        }

        // Обход в порядке документа: контекст сырого HTML (script, style, template) зависит от порядка тегов.
        var stack: [(node: OpaquePointer, cell: OpaquePointer?, supported: Bool)] = []
        func push(children parent: OpaquePointer, cell: OpaquePointer?, supported: Bool) {
            var items: [OpaquePointer] = []
            var child = cmark_node_first_child(parent)
            while let current = child { items.append(current); child = cmark_node_next(current) }
            for item in items.reversed() { stack.append((item, cell, supported)) }
        }
        push(children: root, cell: nil, supported: true)
        while let (node, cell, supported) = stack.popLast() {
            if isCancelled() { return HTMLConfirmation() }
            let nodeType = cmark_node_get_type(node)
            let name = cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
            if nodeType == CMARK_NODE_HTML_BLOCK || nodeType == CMARK_NODE_HTML_INLINE {
                let isBlock = nodeType == CMARK_NODE_HTML_BLOCK
                if !isBlock, supported, let parent = cmark_node_parent(node), seenParents.insert(parent).inserted,
                   let parentName = cmark_node_get_type_string(parent), containerTypes.contains(String(cString: parentName)) {
                    inlineParents.append(parent)
                }
                // Ячейка таблицы: пары `<kbd>`, `<span style>` собираются по позициям ячейки; родитель тега может быть
                // вложенным (`**<span style>…</span>**`), позиции берутся у ячейки-предка.
                if !isBlock, let cell, let parent = cmark_node_parent(node), tableParentSet.insert(parent).inserted { tableParents.append((parent, cell)) }
                var multilinePrefixes: [NSRange]?
                let nodeRange = rangeOf(node, cell: cell, prefixes: &multilinePrefixes)
                if !isBlock { allInlineHTML.append((node, nodeRange)) }
                var confirmed = nodeRange.map { htmlSourceMatches(node, range: $0, text: text, isCancelled: isCancelled) } ?? false
                if !confirmed, let nodeRange,
                   let prefixes = multilinePrefixes ?? (isBlock ? containerHTMLPrefixes(node, range: nodeRange, source: source, sourceText: text, isCancelled: isCancelled) : nil) {
                    if htmlText == nil { htmlText = NSMutableString(string: text as String) }
                    for prefix in prefixes { htmlText?.replaceCharacters(in: prefix, with: String(repeating: " ", count: prefix.length)) }
                    confirmed = true
                }
                guard let range = nodeRange, confirmed else { result.rangesAvailable = false; htmlContext.invalidate(); continue }
                // Сырой script/style в контейнере с разрывом строк: префиксы контейнера в тексте не доказаны.
                if htmlContext.inScriptContext, lastEnd < range.location, scriptStartedInContainer || insideContainer(node) {
                    var broken = false
                    for position in lastEnd..<range.location where [10, 13].contains(Int(text.character(at: position))) { broken = true; break }
                    if broken {
                        guard let prefixes = scriptGapPrefixes(before: node, range: range) else { result.rangesAvailable = false; htmlContext.invalidate(); continue }
                        if htmlText == nil { htmlText = NSMutableString(string: text as String) }
                        for prefix in prefixes { htmlText?.replaceCharacters(in: prefix, with: String(repeating: " ", count: prefix.length)) }
                    }
                }
                result.ranges.append(range)
                var imageTags: [NSRange] = [], mediaTags: [(NSRange, String, Bool)] = []
                let outside = htmlContext.consume(source: (htmlText as NSString?) ?? text, range: range, isCancelled: isCancelled,
                    confirmedTag: { tag, tagName, closing in
                        if tagName == "script", !closing { scriptStartedInContainer = insideContainer(node); scriptOpeningNode = node }
                        if tagName == "img", !closing, templateDepth == 0 { imageTags.append(tag) }
                        if ["audio", "video", "iframe", "embed"].contains(tagName), templateDepth == 0 { mediaTags.append((tag, tagName, closing)) }
                        if tagName == "ruby", !isBlock, templateDepth == 0, let parent = cmark_node_parent(node) { rubyTags.append((parent, tag, closing)) }
                        if tagName == "template" { mediaCollector.cancelPending(); templateDepth = closing ? max(0, templateDepth - 1) : templateDepth + 1 }
                    }, confirmedRawClose: { tag, tagName in
                        if tagName == "iframe", templateDepth == 0 { mediaTags.append((tag, tagName, true)) }
                    })
                scriptGapText.removeAll(keepingCapacity: true)
                scriptGapUnproven = false
                if !htmlContext.inScriptContext { scriptStartedInContainer = false; scriptOpeningNode = nil }
                lastEnd = NSMaxRange(range)
                let safe = outside && templateDepth == 0
                if supported { mediaCollector.consume(node: node, range: range, tags: mediaTags, sourceText: text, isCancelled: isCancelled) }
                guard safe else { continue }
                let proofText = (htmlText as NSString?) ?? text
                if !isBlock { confirmedInline.insert(node) }
                if supported || cell != nil {
                    let offsets = isBlock ? MarkdownHTMLProof.htmlBlockTagOffsets(node, range: range, tags: imageTags, sourceText: text, isCancelled: isCancelled) : nil
                    for tag in imageTags {
                        guard let verified = MarkdownImageUploadService.confirmedHTMLImage(in: proofText, range: tag, isCancelled: isCancelled),
                              let image = MarkdownHTMLMediaService.displayImage(in: proofText.substring(with: tag)) else { continue }
                        let value = MarkdownInlineNode.Image(url: verified.address, alt: image.alt, title: image.title, syntax: .html,
                                                             addressRange: nil, sizing: image.sizing, isBlock: false, tagRange: tag)
                        if isBlock {
                            guard let offset = offsets?[tag.location] else { continue }
                            imageCandidates.append((node, value, tag, image.source, offset, true))
                        } else {
                            imageCandidates.append((node, value, tag, image.source, 0, false))
                        }
                    }
                }
                guard isBlock, supported, let pointer = cmark_node_get_literal(node) else { continue }
                let literal = String(cString: pointer) as NSString
                let proven = MarkdownHTMLProof.htmlBlockTagOffsets(node, range: range, tags: [], sourceText: text, isCancelled: isCancelled) != nil
                if proven {
                    let bounds = trimmedBounds(literal, isCancelled: isCancelled)
                    if let widget = MarkdownHTMLMediaService.twitterWidget(literal as String, isCancelled: isCancelled) {
                        twitter.append((node, .init(node: node, start: bounds.start, end: bounds.end, widget: widget)))
                    }
                    let plain = MarkdownHTMLMediaService.plainDetails(literal as String, isCancelled: isCancelled)
                    if plain == nil, let display = MarkdownHTMLMediaService.editingHTMLBlock(literal as String, isCancelled: isCancelled) {
                        htmlBlocks.append((node, .init(node: node, start: bounds.start, end: bounds.end, html: literal as String), display))
                    }
                    if let media = MarkdownHTMLMediaService.standaloneMedia(literal as String, isCancelled: isCancelled) { standalone.append((node, media)) }
                    if let style = MarkdownHTMLMediaService.pageBreakStyle(literal as String, isCancelled: isCancelled) {
                        pageBreaks.append((node, leadingWhitespace(literal), style))
                    }
                    if let plain { details.append((node, leadingWhitespace(literal), plain.summary, plain.body)) }
                }
                if let candidate = standaloneSVGBlockCandidate(node, range: range, text: text, isCancelled: isCancelled) { svgs.append(candidate) }
                if let frame = MarkdownHTMLMediaService.iframe(in: literal as String) {
                    result.blocks[node] = .iframe(frame, html: MarkdownHTMLMediaService.iframeHTML(frame),
                                                  displayHTML: MarkdownHTMLMediaService.iframeFallbackHTML(frame))
                }
                if let media = hasMediaFallback(literal, isCancelled: isCancelled) { result.blocks[node] = .media(media) }
                continue
            }
            if nodeType == CMARK_NODE_TEXT, htmlContext.inScriptContext {
                if let range = source.range(node), let literal = cmark_node_get_literal(node), range.location >= lastEnd,
                   (scriptGapText.last.map { NSMaxRange($0.range) <= range.location } ?? true), NSMaxRange(range) <= text.length,
                   text.substring(with: range).utf16.elementsEqual(String(cString: literal).utf16) {
                    scriptGapText.append((range, node))
                } else { scriptGapUnproven = true }
            }
            let childSupported = supported && nodeType != CMARK_NODE_FOOTNOTE_DEFINITION && nodeType != CMARK_NODE_IMAGE && name != "table"
            push(children: node, cell: name == "table_cell" ? node : cell, supported: childSupported)
        }
        if isCancelled() { return HTMLConfirmation() }

        func prove<T>(_ items: [T], _ run: ([T]) -> Set<Int>) -> [T] {
            guard !items.isEmpty, !isCancelled() else { return [] }
            return run(items).sorted().map { items[$0] }
        }
        // Блоки.
        for item in prove(twitter, { MarkdownHTMLProof.provenTwitter(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                           candidates: $0.map(\.proof), isCancelled: isCancelled) }) {
            if MarkdownHTMLMediaService.twitterFrame(item.proof.widget) != nil { result.blocks[item.node] = .twitter(item.proof.widget) }
        }
        for item in prove(htmlBlocks, { MarkdownHTMLProof.provenHTMLBlocks(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                                 candidates: $0.map(\.proof), isCancelled: isCancelled) }) {
            if result.blocks[item.node] != nil { continue }
            if let rich = MarkdownHTMLMediaService.richDetails(item.proof.html, isCancelled: isCancelled), let range = source.range(item.node) {
                result.blocks[item.node] = .details(MarkdownDetailsBlock(range: range, summary: rich.summary, body: "", summaryHTML: rich.summaryHTML,
                                                                         bodyHTML: rich.bodyHTML, initiallyOpen: rich.initiallyOpen))
            } else { result.blocks[item.node] = .confirmed(displayHTML: item.display) }
        }
        for item in prove(standalone, { MarkdownHTMLProof.provenStandaloneMedia(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                                      candidates: $0.map { ($0.node, $0.media) }, isCancelled: isCancelled) }) {
            result.blocks[item.node] = .media(item.media.media)
        }
        if !pageBreaks.isEmpty, !isCancelled() {
            let accepted = MarkdownHTMLProof.provenPageBreaks(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                      candidates: pageBreaks.map { ($0.node, $0.offset, $0.style) }, isCancelled: isCancelled)
            for item in pageBreaks where accepted.contains(item.node) { result.blocks[item.node] = .pageBreak(style: item.style) }
        }
        if !details.isEmpty, !isCancelled() {
            let accepted = MarkdownHTMLProof.provenDetails(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                   candidates: details.map { ($0.node, $0.offset, $0.summary, $0.body) }, isCancelled: isCancelled)
            for item in details where accepted.contains(item.node) {
                guard let range = source.range(item.node),
                      let summary = MarkdownHTMLMediaService.detailsDisplayText(item.summary, isCancelled: isCancelled),
                      let body = MarkdownHTMLMediaService.detailsDisplayText(item.body, isCancelled: isCancelled) else { continue }
                result.blocks[item.node] = .details(MarkdownDetailsBlock(range: range, summary: summary, body: body))
            }
        }
        // Изображения `<img>`: блок целиком или строчный узел.
        if !imageCandidates.isEmpty, !isCancelled() {
            let proof = imageCandidates.map { MarkdownHTMLProof.ImageProofCandidate(node: $0.node, offset: $0.offset, source: $0.source) }
            let accepted = MarkdownHTMLProof.provenImageIndices(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                        candidates: proof, isCancelled: isCancelled)
            var blockImages: [OpaquePointer: [MarkdownInlineNode.Image]] = [:], blockOrder: [OpaquePointer] = []
            for index in accepted.keys.sorted() {
                let item = imageCandidates[index]
                if item.isBlock {
                    if blockImages[item.node] == nil { blockOrder.append(item.node) }
                    var image = item.image
                    image.isBlock = false
                    blockImages[item.node, default: []].append(image)
                } else {
                    result.merges[item.node] = .init(last: item.node, kind: .image(item.image), range: item.range, markers: [])
                }
            }
            for node in blockOrder where result.blocks[node] == nil { result.blocks[node] = .images(blockImages[node] ?? []) }
        }
        // Парные media и iframe.
        let paired = mediaCollector.candidates
        if !paired.isEmpty, !isCancelled() {
            var originals: [(OpaquePointer, String)] = []
            for merge in mediaCollector.merges {
                for (node, literal) in [(merge.inline, ""), (merge.block, merge.literal)] {
                    guard let pointer = cmark_node_get_literal(node) else { continue }
                    originals.append((node, String(cString: pointer)))
                    _ = literal.withCString { cmark_node_set_literal(node, $0) }
                }
            }
            defer { for (node, literal) in originals.reversed() { _ = literal.withCString { cmark_node_set_literal(node, $0) } } }
            let accepted = MarkdownHTMLProof.provenMediaIndices(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                        candidates: paired.map(\.proof), isCancelled: isCancelled)
            let selected = accepted.sorted().map { paired[$0] }
            let ordered = selected.sorted { (first: (proof: MarkdownHTMLProof.MediaProofCandidate, range: NSRange, isInline: Bool),
                                            second: (proof: MarkdownHTMLProof.MediaProofCandidate, range: NSRange, isInline: Bool)) -> Bool in
                if first.range.location != second.range.location { return first.range.location < second.range.location }
                return first.range.length > second.range.length
            }
            var end = 0
            let taken = result.blocks.compactMap { source.range($0.key) }
            for candidate in ordered {
                if isCancelled() { break }
                guard candidate.range.location >= end, !taken.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) else { continue }
                end = NSMaxRange(candidate.range)
                let kind: MarkdownInlineNode.Kind
                switch candidate.proof.expected {
                case .media(let media): kind = .media(media)
                case .frame(let frame): kind = .iframe(frame, html: MarkdownHTMLMediaService.iframeHTML(frame), displayHTML: MarkdownHTMLMediaService.iframeFallbackHTML(frame))
                }
                if candidate.isInline {
                    result.merges[candidate.proof.openingNode] = .init(last: candidate.proof.closingNode, kind: kind, range: candidate.range, markers: [])
                } else {
                    switch candidate.proof.expected {
                    case .media(let media): result.blocks[candidate.proof.openingNode] = .media(media)
                    case .frame(let frame): result.blocks[candidate.proof.openingNode] = .iframe(frame, html: MarkdownHTMLMediaService.iframeHTML(frame),
                                                                                                displayHTML: MarkdownHTMLMediaService.iframeFallbackHTML(frame))
                    }
                }
            }
        }
        // Строчные теги: пары и ruby.
        let filtered = filterInlineHTMLForStyles(allInlineHTML, confirmed: confirmedInline, text: text, isCancelled: isCancelled)
        confirmedInline = filtered.confirmed
        result.confirmedInline = confirmedInline
        result.contextText = htmlText
        for merge in result.merges.values {
            if case let .image(image) = merge.kind, image.sizing != nil { result.images.insert(merge.range) }
        }
        let rubyCandidates = inlineRubyCandidates(parents: inlineParents, confirmed: confirmedInline, source: source, text: text, sourceRange: { node in
            if let direct = cmark_node_get_type(node) == CMARK_NODE_TEXT ? source.editingTextRange(node) : source.range(node) { return direct }
            guard let parent = cmark_node_parent(node) else { return nil }
            return lazyRanges[parent]??[node]
        }, isCancelled: isCancelled)
        var acceptedRuby = Set<NSRange>()
        if !rubyCandidates.isEmpty, !isCancelled() {
            let accepted = MarkdownHTMLProof.provenRuby(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                                candidates: rubyCandidates.map(\.proof), isCancelled: isCancelled)
            for index in accepted.sorted() {
                let candidate = rubyCandidates[index]
                let value = candidate.value
                acceptedRuby.insert(value.range)
                let ruby = MarkdownInlineNode.Ruby(base: value.base, reading: value.reading, baseRange: value.baseRange, readingRange: value.readingRange,
                                                   baseRuns: value.baseRuns, openingParenthesis: candidate.proof.before, closingParenthesis: candidate.proof.after,
                                                   baseHTML: candidate.proof.baseHTML, trailing: candidate.proof.trailing)
                result.merges[candidate.proof.opening] = .init(last: candidate.proof.closing, kind: .ruby(ruby), range: value.range, markers: [])
            }
        }
        let rubyBlocked = unconfirmedRubyRanges(tags: rubyTags, accepted: acceptedRuby, sourceLength: text.length,
                                                parentRange: { source.range($0) }, isCancelled: isCancelled)
        // `<br>` с атрибутом, внутри script или template не подтверждён: показ его не оформляет.
        var brBlocked: [NSRange] = []
        for (node, range) in allInlineHTML {
            guard let range, let literal = cmark_node_get_literal(node) else { continue }
            let value = String(cString: literal).lowercased()
            guard value.hasPrefix("<br"), value.dropFirst(3).first.map({ " />\t".contains($0) }) ?? false else { continue }
            if confirmedInline.contains(node), ["<br>", "<br/>", "<br />"].contains(text.substring(with: range).lowercased()) { continue }
            brBlocked.append(range)
        }
        var blocked: [NSRange] = []
        for range in (filtered.blocked + rubyBlocked + brBlocked).sorted(by: { $0.location < $1.location }) {
            if let last = blocked.last, range.location <= NSMaxRange(last) { blocked[blocked.count - 1] = NSUnionRange(last, range) } else { blocked.append(range) }
        }
        result.blocked = blocked
        // Строчные SVG.
        svgs.append(contentsOf: standaloneSVGInlineCandidates(parents: inlineParents, confirmed: confirmedInline, source: source, text: text, isCancelled: isCancelled))
        if !svgs.isEmpty, !isCancelled() {
            let accepted = MarkdownHTMLProof.provenSVG(root: root, mathExtension: ext, options: cmarkOptions, text: text,
                                                               candidates: svgs.map(\.proof), isCancelled: isCancelled)
            for index in accepted.sorted() {
                let candidate = svgs[index]
                if blocked.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) { continue }
                // Строчные узлы (абзац из одного `<svg>` тоже): блок `.svg` бывает только у настоящего HTML-блока.
                if candidate.paragraph != nil {
                    result.merges[candidate.proof.opening] = .init(last: candidate.proof.closing, kind: .svg(candidate.data), range: candidate.range, markers: [])
                } else { result.blocks[candidate.proof.opening] = .svg(candidate.data) }
            }
        }
        // Пары тегов.
        let ignoredRubyParents = Set(rubyCandidates.compactMap { acceptedRuby.contains($0.value.range) ? cmark_node_parent($0.proof.opening) : nil })
        for parent in inlineParents {
            if isCancelled() { break }
            let lazy = paragraphLazy(from: parent)
            let mapped: ((OpaquePointer) -> NSRange?)? = lazy != nil ? { lazy?[$0] ?? source.range($0) } : nil
            for pair in inlineHTMLPairs(in: parent, confirmed: confirmedInline, source: source, text: text, mappedRange: mapped,
                                        ignoreRubyTags: ignoredRubyParents.contains(parent), isCancelled: isCancelled) {
                result.pairs[pair.opening] = pair
            }
        }
        for (parent, cell) in tableParents {
            if isCancelled() { break }
            guard let positions = ctx.tablePositions(cell) else { continue }
            for pair in inlineHTMLPairs(in: parent, confirmed: confirmedInline, source: source, text: text, tablePositions: positions, isCancelled: isCancelled) {
                // В ячейках оформляются только `<kbd>` и `<span style>`.
                if pair.kind == .keyboard { result.pairs[pair.opening] = pair }
                else if case .inlineStyle = pair.kind { result.pairs[pair.opening] = pair }
            }
        }
        return isCancelled() ? HTMLConfirmation() : result
    }

    private static func leadingWhitespace(_ literal: NSString) -> Int {
        var offset = 0
        while offset < literal.length && htmlWhitespace.contains(Int(literal.character(at: offset))) { offset += 1 }
        return offset
    }

    /// Блок с `<audio>`/`<video>` и запасным содержимым (`<br>`, `<source>`): не одиночный самозакрывающийся тег.
    private static func hasMediaFallback(_ literal: NSString, isCancelled: () -> Bool) -> MarkdownEmbeddedMedia? {
        var context = MarkdownImageUploadService.HTMLContext(), tags: [NSRange] = []
        _ = context.consume(source: literal, range: NSRange(location: 0, length: literal.length), isCancelled: isCancelled,
                            confirmedTag: { tag, _, _ in tags.append(tag) })
        let bounds = trimmedBounds(literal, isCancelled: isCancelled)
        let standalone = tags.count == 1 && tags[0] == NSRange(location: bounds.start, length: bounds.end - bounds.start) &&
            bounds.end >= bounds.start + 2 && literal.character(at: bounds.end - 2) == 47 && literal.character(at: bounds.end - 1) == 62
        let value = literal as String
        let hasFallback = value.range(of: "<br", options: .caseInsensitive) != nil || value.range(of: "<source", options: .caseInsensitive) != nil
        return !standalone && hasFallback ? MarkdownHTMLMediaService.embeddedMedia(in: value) : nil
    }

    /// Слитый строчный узел или пара тегов, начинающиеся на `nodes[index]`; `nil` — обычная обработка.
    /// Возвращает узел и индекс следующего необработанного соседа. `positions` — индексы соседей (строится один раз на список).
    static func htmlInline(_ nodes: [OpaquePointer], positions: [OpaquePointer: Int], at index: Int, ctx: Context,
                           children: ([OpaquePointer], NSRange, Int) -> [MarkdownInlineNode]) -> (node: MarkdownInlineNode, next: Int)? {
        guard let html = ctx.html else { return nil }
        let node = nodes[index]
        if let merge = html.merges[node], let last = positions[merge.last], last >= index {
            return (MarkdownInlineNode(kind: merge.kind, range: merge.range, markerRanges: merge.markers, children: [], isUnreliable: false), last + 1)
        }
        if let pair = html.pairs[node], let close = positions[pair.closing], close >= index {
            let kind: MarkdownInlineNode.Kind
            switch pair.kind {
            case .strong: kind = .strong
            case .emphasis: kind = .emphasis
            case .strikethrough: kind = .strikethrough
            case .keyboard: kind = .keyboard
            case .underline: kind = .underline
            case .highlight: kind = .highlight
            case .subscriptText: kind = .subscriptText
            case .superscriptText: kind = .superscriptText
            case .inlineStyle(let style): kind = .inlineStyle(style)
            case .link: kind = .link(MarkdownInlineNode.Link(url: pair.href ?? "", title: nil, form: .html, destinationRange: nil))
            default: return nil
            }
            let range = NSUnionRange(pair.openingRange, pair.closingRange)
            let inner = NSRange(location: NSMaxRange(pair.openingRange), length: max(0, pair.closingRange.location - NSMaxRange(pair.openingRange)))
            return (MarkdownInlineNode(kind: kind, range: range, markerRanges: [pair.openingRange, pair.closingRange],
                                       children: children(Array(nodes[(index + 1)..<close]), inner, NSMaxRange(pair.openingRange)), isUnreliable: false), close + 1)
        }
        return nil
    }
}

// MARK: - Подчёркивание `<u>…</u>`

extension MarkdownDocumentParser {
    static func underline(_ node: OpaquePointer, source: MarkdownSourcePositions, text: NSString) -> (range: NSRange, opening: NSRange, closing: NSRange)? {
        guard let name = cmark_node_get_type_string(node), String(cString: name) == "html_inline", !isExcludedInline(node),
              let parent = cmark_node_parent(node), let parentType = cmark_node_get_type_string(parent),
              String(cString: parentType) == "paragraph",
              let opening = source.range(node), text.substring(with: opening) == "<u>",
              let middle = cmark_node_next(node), let middleType = cmark_node_get_type_string(middle), String(cString: middleType) == "text",
              let content = source.range(middle), let literal = cmark_node_get_literal(middle),
              content.length > 0, text.substring(with: content) == String(cString: literal),
              let close = cmark_node_next(middle), let closeType = cmark_node_get_type_string(close), String(cString: closeType) == "html_inline",
              let closing = source.range(close), text.substring(with: closing) == "</u>",
              cmark_node_get_start_line(node) == cmark_node_get_end_line(close),
              NSMaxRange(opening) == content.location, NSMaxRange(content) == closing.location else { return nil }
        let raw = text.substring(with: content)
        guard !raw.contains("=="), !raw.contains("^") else { return nil }
        return (NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location), opening, closing)
    }

    static func underlines(in parent: OpaquePointer, source: MarkdownSourcePositions, text: NSString, isCancelled: () -> Bool = { false }) -> [(OpaquePointer, OpaquePointer, NSRange, NSRange, NSRange)] {
        var result: [(OpaquePointer, OpaquePointer, NSRange, NSRange, NSRange)] = []
        var depth = 0, child = cmark_node_first_child(parent)
        while let node = child {
            if isCancelled() { return [] }
            defer { child = cmark_node_next(node) }
            guard let kind = cmark_node_get_type_string(node), String(cString: kind) == "html_inline",
                  let range = source.range(node) else { continue }
            let raw = text.substring(with: range)
            let lower = raw.lowercased() as NSString
            func tagBoundary(_ index: Int) -> Bool {
                guard index < lower.length else { return false }
                let unit = lower.character(at: index)
                return unit == 62 || unit == 47 || unit == 32 || unit == 9 || unit == 10 || unit == 13
            }
            if lower.hasPrefix("<u"), tagBoundary(2) {
                if depth == 0, let item = underline(node, source: source, text: text),
                   let middle = cmark_node_next(node), let close = cmark_node_next(middle) {
                    result.append((node, close, item.range, item.opening, item.closing))
                }
                depth += 1
            } else if lower.hasPrefix("</u"), tagBoundary(3) { depth = max(0, depth - 1) }
        }
        return result
    }
}

extension MarkdownDocumentParser {
    static func confirmedNamedAnchors(in source: NSString, ranges: [NSRange], isCancelled: () -> Bool = { false }) -> [MarkdownNamedAnchor] {
        var context = MarkdownImageUploadService.HTMLContext()
        var suppressed: [String] = [], anchors: [MarkdownNamedAnchor] = []
        var previousEnd = 0
        for range in ranges {
            guard !isCancelled(), range.location >= previousEnd else { return [] }
            _ = context.consume(source: source, range: range, isCancelled: isCancelled) { tag, name, closing in
                if ["template", "pre", "code"].contains(name) {
                    if closing {
                        if suppressed.last == name { suppressed.removeLast() }
                    } else { suppressed.append(name) }
                } else if suppressed.isEmpty && name == "a" && !closing {
                    for value in MarkdownHTMLMediaService.anchorNames(inOpeningTag: source.substring(with: tag)) {
                        anchors.append(MarkdownNamedAnchor(name: value, range: tag))
                    }
                }
            }
            previousEnd = NSMaxRange(range)
        }
        return isCancelled() ? [] : anchors
    }
}
