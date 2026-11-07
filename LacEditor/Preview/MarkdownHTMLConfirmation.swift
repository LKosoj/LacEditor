import Foundation
import SwiftSoup
import cmark_gfm
import cmark_gfm_extensions

/// Подтверждение HTML и картинок по дереву cmark: обход выполняется здесь,
/// строковые части остаются в MarkdownImageUploadService.
enum MarkdownHTMLConfirmation {
    typealias Image = MarkdownImageUploadService.Image
    typealias UploadError = MarkdownImageUploadService.UploadError

    static func textareaContents(in source: String, isCancelled: () -> Bool) throws -> [NSRange] {
        guard source.range(of: "<textarea", options: .caseInsensitive) != nil else { return [] }
        let text = source as NSString
        let input = MarkdownFrontMatter.maskedFrontMatter(source, frontMatter: MarkdownFrontMatter.frontMatter(source))
        guard let result = MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES, { root, _, _ in
            let mapping = MarkdownSourcePositions(source, root: root, isCancelled: isCancelled)
            var context = MarkdownImageUploadService.HTMLContext(), opening: Int?, ranges: [NSRange] = [], valid = true
            func visit(_ node: OpaquePointer) {
                guard valid, !isCancelled() else { valid = false; return }
                if let name = cmark_node_get_type_string(node), ["html_inline", "html_block"].contains(String(cString: name)) {
                    guard let range = mapping.range(node), MarkdownDocumentParser.htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else {
                        valid = false; return
                    }
                    _ = context.consume(source: text, range: range, isCancelled: isCancelled, confirmedTag: { tag, name, closing in
                        if name == "textarea" && !closing { opening = NSMaxRange(tag) }
                    }, confirmedRawClose: { tag, name in
                        if name == "textarea", let start = opening, start <= tag.location {
                            ranges.append(NSRange(location: start, length: tag.location - start))
                            opening = nil
                        }
                    })
                }
                var child = cmark_node_first_child(node)
                while let current = child, valid, !isCancelled() { visit(current); child = cmark_node_next(current) }
            }
            visit(root)
            return valid && opening == nil ? ranges : nil
        }) else { throw UploadError.invalidInput }
        if isCancelled() { throw CancellationError() }
        guard let result else { throw UploadError.invalidInput }
        return result
    }

    static func mediaSources(in source: String, isCancelled: @escaping () -> Bool) throws -> [Image] {
        guard source.range(of: "<audio", options: .caseInsensitive) != nil || source.range(of: "<video", options: .caseInsensitive) != nil else { return [] }
        let text = source as NSString
        let input = MarkdownFrontMatter.maskedFrontMatter(source, frontMatter: MarkdownFrontMatter.frontMatter(source))
        guard let result = MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES, { root, _, _ in
            let mapping = MarkdownSourcePositions(source, root: root, isCancelled: isCancelled)
            var context = MarkdownImageUploadService.HTMLContext(), found: [Image] = [], valid = true, templateDepth = 0
            var pendingMedia: (name: String, parent: OpaquePointer, end: Int, sources: [Image], nested: [String])?
            func visit(_ node: OpaquePointer) {
                guard valid, !isCancelled() else { valid = false; return }
                if let pointer = cmark_node_get_type_string(node) {
                    let kind = String(cString: pointer)
                    if kind == "html_inline" || kind == "html_block" {
                        guard let range = mapping.range(node), MarkdownDocumentParser.htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) else {
                            context.invalidate(); return
                        }
                        let outside = !context.inRawContext
                        let block = kind == "html_block" && outside && templateDepth == 0 ? text.substring(with: range) : ""
                        let hasMedia = block.range(of: "<audio", options: .caseInsensitive) != nil || block.range(of: "<video", options: .caseInsensitive) != nil
                        var candidates: [(NSRange, String, Image)] = []
                        _ = context.consume(source: text, range: range, isCancelled: isCancelled, confirmedTag: { tag, name, closing in
                            if name == "template" {
                                if kind == "html_inline", var pending = pendingMedia, pending.parent == cmark_node_parent(node) {
                                    if closing && pending.nested.last == name { pending.nested.removeLast() }
                                    else if !closing { pending.nested.append(name) }
                                    else { pendingMedia = nil; return }
                                    pending.end = NSMaxRange(tag)
                                    pendingMedia = pending
                                } else { pendingMedia = nil }
                                if closing { templateDepth = max(0, templateDepth - 1) }
                                else { templateDepth += 1 }
                                return
                            }
                            if kind == "html_inline", templateDepth == 0, let parent = cmark_node_parent(node) {
                                func orderedGap(from start: Int) -> Bool {
                                    start <= tag.location && !isCancelled()
                                }
                                if !closing && ["audio", "video"].contains(name) {
                                    pendingMedia = nil
                                    var missingSource = false
                                    if let value = MarkdownImageUploadService.htmlImage(in: text, range: tag, htmlForExport: false, isCancelled: isCancelled, tagName: name,
                                                             missingSource: { missingSource = true }) {
                                        found.append(value)
                                    } else if missingSource { pendingMedia = (name, parent, NSMaxRange(tag), [], []) }
                                } else if !closing && name == "source", var pending = pendingMedia,
                                          pending.parent == parent, pending.nested.isEmpty, orderedGap(from: pending.end),
                                          let value = MarkdownImageUploadService.htmlImage(in: text, range: tag, htmlForExport: false, isCancelled: isCancelled, tagName: name) {
                                    pending.sources.append(value)
                                    pending.end = NSMaxRange(tag)
                                    pendingMedia = pending
                                } else if closing, let pending = pendingMedia, name == pending.name,
                                          pending.parent == parent, pending.nested.isEmpty, orderedGap(from: pending.end) {
                                    found.append(contentsOf: pending.sources)
                                    pendingMedia = nil
                                } else if var pending = pendingMedia, pending.parent == parent, orderedGap(from: pending.end) {
                                    if closing && pending.nested.last == name { pending.nested.removeLast() }
                                    else if !closing && !["br", "hr", "img", "input", "source", "wbr", "area", "base", "embed", "link", "meta", "param", "track"].contains(name) { pending.nested.append(name) }
                                    else if closing { pendingMedia = nil; return }
                                    pending.end = NSMaxRange(tag)
                                    pendingMedia = pending
                                } else { pendingMedia = nil }
                            }
                            guard hasMedia, !closing, ["audio", "video", "source"].contains(name),
                                  let value = MarkdownImageUploadService.htmlImage(in: text, range: tag, htmlForExport: false, isCancelled: isCancelled, tagName: name) else { return }
                            candidates.append((tag, name, value))
                        }, confirmedRawClose: { tag, name in
                            if kind == "html_inline", var pending = pendingMedia,
                               pending.parent == cmark_node_parent(node), pending.nested.last == name {
                                pending.nested.removeLast()
                                pending.end = NSMaxRange(tag)
                                pendingMedia = pending
                            }
                        })
                        if hasMedia, !context.inRawContext, !candidates.isEmpty {
                            var marker: String
                            repeat { marker = "data-lac-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
                            while block.localizedCaseInsensitiveContains(marker)
                            let tagged = NSMutableString(string: block)
                            for index in candidates.indices.reversed() {
                                let (tag, name, _) = candidates[index]
                                let offset = tag.location - range.location + 1 + (name as NSString).length
                                tagged.insert(" \(marker)=\"\(index)\"", at: offset)
                            }
                            do {
                                let document = try SwiftSoup.parseBodyFragment(tagged as String)
                                var stack: [(SwiftSoup.Node, Element?, Bool)] = [(document, nil, false)]
                                var seen = Set<Int>(), selected = Set<Int>(), validMarkers = true
                                while let (node, parent, forbidden) = stack.popLast() {
                                    if isCancelled() { valid = false; break }
                                    let element = node as? Element
                                    let name = element?.tagName().lowercased()
                                    let blocked = forbidden || ["template", "script", "style"].contains(name ?? "")
                                    if let element, element.hasAttr(marker) {
                                        guard let index = Int(try element.attr(marker)), candidates.indices.contains(index), seen.insert(index).inserted else {
                                            validMarkers = false; break
                                        }
                                        let (_, expectedName, image) = candidates[index]
                                        if !blocked, name == expectedName, let normalized = MarkdownImageUploadService.normalizeHTMLReferences(image.rawAddress, isCancelled: isCancelled),
                                           let decoded = MarkdownImageUploadService.decodeHTMLReferences(normalized), try element.attr("src").utf8.elementsEqual(decoded.utf8) {
                                            if name == "audio" || name == "video" { selected.insert(index) }
                                            else if name == "source", let parent, ["audio", "video"].contains(parent.tagName().lowercased()), !parent.hasAttr("src") { selected.insert(index) }
                                        }
                                    }
                                    for child in node.getChildNodes() { stack.append((child, element ?? parent, blocked)) }
                                }
                                if validMarkers && seen.count == candidates.count {
                                    found.append(contentsOf: candidates.indices.filter { selected.contains($0) }.map { candidates[$0].2 })
                                }
                            } catch { valid = false }
                        }
                    }
                }
                var child = cmark_node_first_child(node)
                while let current = child, valid, !isCancelled() { visit(current); child = cmark_node_next(current) }
            }
            visit(root)
            return valid ? found : nil
        }) else { throw UploadError.invalidInput }
        if isCancelled() { throw CancellationError() }
        guard let result else { throw UploadError.invalidInput }
        return result
    }

    // cmark's source columns are UTF-8 byte offsets, whereas AppKit uses UTF-16.
    static func images(in source: String, selection: NSRange?, isCancelled: @escaping () -> Bool, htmlForExport: Bool,
                       confirmedAudio: ((NSRange) -> Void)?, confirmedVideo: ((NSRange) -> Void)?,
                       confirmedInline: ((NSRange, String) -> Void)?,
                       confirmedFrame: ((NSRange, MarkdownHTMLMediaService.EmbeddedFrame) -> Void)?,
                       confirmedBlock: ((NSRange) -> Void)?,
                       confirmedImage: ((OpaquePointer, Image) -> Void)?,
                       confirmedHTMLTags: ((OpaquePointer, NSRange, [(NSRange, String, Bool)]) -> Void)?,
                       root: OpaquePointer?, sourceMapping: MarkdownSourcePositions?) throws
        -> (found: [Image], references: [(range: NSRange, ordinal: Int, label: String)]) {
        let text = source as NSString
        var mapping: MarkdownSourcePositions!
        var lines: [(Int, String)] = [], start = 0, offset = 0
        while offset < text.length {
            if isCancelled() { throw CancellationError() }
            if text.character(at: offset) == 10 || text.character(at: offset) == 13 {
                if text.character(at: offset) == 13 && offset + 1 < text.length && text.character(at: offset + 1) == 10 { offset += 1 }
                offset += 1
                lines.append((start, text.substring(with: NSRange(location: start, length: offset - start))))
                start = offset
            } else { offset += 1 }
        }
        lines.append((start, text.substring(from: start)))
        var found: [Image] = [], ordinal = 0
        var htmlRawContext: String?
        var scriptFilter = MarkdownHTMLMediaService.SourceHTMLFilter()
        var scriptCursor: Int?
        var htmlContextSource: NSMutableString?
        var previousHTMLRangeEnd = 0
        var scriptStartedInContainer = false
        var tablePositions: [OpaquePointer: MarkdownSourcePositions.TableCellPositions] = [:]
        var invalidTablePositions: Set<OpaquePointer> = []
        var references: [(range: NSRange, ordinal: Int, label: String)] = []
        var inlineTags: [OpaquePointer: [(NSRange, String)]] = [:]
        var inlineLinks: [NSRange] = []
        var unknownInlineLink = false
        func visit(_ node: OpaquePointer) throws {
            if isCancelled() { throw CancellationError() }
            guard let name = cmark_node_get_type_string(node) else { return }
            let kind = String(cString: name)
            let currentOrdinal = ordinal
            if kind == "link" || kind == "image" { ordinal += 1 }
            func relevant(_ range: NSRange) -> Bool {
                guard let selection else { return true }
                return selection.length == 0 ? selection.location >= range.location && selection.location < NSMaxRange(range)
                    : NSIntersectionRange(selection, range).length > 0
            }
            func nodeRange() -> NSRange? {
                var ancestor = cmark_node_parent(node)
                while let current = ancestor {
                    if let name = cmark_node_get_type_string(current), String(cString: name) == "table_cell" {
                        if tablePositions[current] == nil && !invalidTablePositions.contains(current) {
                            if let positions = mapping.tableCellPositions(current) { tablePositions[current] = positions }
                            else { invalidTablePositions.insert(current) }
                        }
                        guard let positions = tablePositions[current] else { return nil }
                        return mapping.tableInlineRange(node, positions: positions)
                    }
                    ancestor = cmark_node_parent(current)
                }
                return mapping.range(node)
            }
            func insideContainer() -> Bool {
                var ancestor = cmark_node_parent(node)
                while let current = ancestor, cmark_node_get_type(current) != CMARK_NODE_DOCUMENT {
                    if isCancelled() { return false }
                    let kind = cmark_node_get_type(current)
                    if kind == CMARK_NODE_BLOCK_QUOTE || kind == CMARK_NODE_ITEM || kind == CMARK_NODE_LIST { return true }
                    ancestor = cmark_node_parent(current)
                }
                return false
            }
            if htmlForExport && confirmedInline != nil && kind == "link" {
                if let range = nodeRange() { inlineLinks.append(range) }
                else { unknownInlineLink = true }
            }
            if kind == "html_inline" || kind == "html_block" {
                if let range = nodeRange() {
                    if root != nil && htmlForExport {
                        if range.location < previousHTMLRangeEnd { htmlRawContext = "plaintext" }
                        if htmlRawContext == "script", previousHTMLRangeEnd < range.location,
                           scriptStartedInContainer || insideContainer() {
                            for position in previousHTMLRangeEnd..<range.location {
                                if isCancelled() { throw CancellationError() }
                                if text.character(at: position) == 10 || text.character(at: position) == 13 {
                                    htmlRawContext = "plaintext"; break
                                }
                            }
                        }
                        previousHTMLRangeEnd = NSMaxRange(range)
                        if !MarkdownDocumentParser.htmlSourceMatches(node, range: range, text: text, isCancelled: isCancelled) {
                            guard kind == "html_block", let prefixes = MarkdownDocumentParser.containerHTMLPrefixes(node, range: range, source: mapping, sourceText: text, isCancelled: isCancelled) else {
                                htmlRawContext = "plaintext"; return
                            }
                            if htmlContextSource == nil { htmlContextSource = NSMutableString(string: source) }
                            for prefix in prefixes { htmlContextSource?.replaceCharacters(in: prefix, with: String(repeating: " ", count: prefix.length)) }
                        }
                    }
                    let htmlText = (htmlContextSource as NSString?) ?? text
                    let startedOutside = htmlRawContext == nil
                    let block = htmlForExport && kind == "html_block" && startedOutside ? htmlText.substring(with: range) : nil
                    let prefix = block.map { $0.drop(while: { $0.isWhitespace }).prefix(7).lowercased() } ?? ""
                    let audio = block.map { prefix.hasPrefix("<audio") && MarkdownHTMLMediaService.audioSource(in: $0, allowPaired: true) != nil } ?? false
                    let video = block.map { prefix.hasPrefix("<video") && MarkdownHTMLMediaService.videoSource(in: $0) != nil } ?? false
                    let frame: MarkdownHTMLMediaService.EmbeddedFrame?
                    if let block, confirmedFrame != nil, prefix == "<iframe" {
                        frame = MarkdownHTMLMediaService.iframe(in: block)
                    } else { frame = nil }
                    let parent = cmark_node_parent(node)
                    var tags: [(NSRange, String, Bool)] = []
                    let images = MarkdownImageUploadService.htmlImages(in: htmlText, range: range, rawContext: &htmlRawContext, scriptFilter: &scriptFilter, scriptCursor: &scriptCursor,
                                            confirmedAudio: htmlForExport ? confirmedAudio : nil,
                                            confirmedInline: htmlForExport && kind == "html_inline" && confirmedInline != nil ? { tag, value in
                                                if let parent { inlineTags[parent, default: []].append((tag, value)) }
                                            } : nil,
                                            htmlForExport: htmlForExport, isCancelled: isCancelled,
                                            confirmedTag: { tag, name, closing in
                                                if confirmedHTMLTags != nil { tags.append((tag, name, closing)) }
                                                if root != nil && htmlForExport && name == "script" && !closing { scriptStartedInContainer = insideContainer() }
                                            }, confirmedRawClose: { tag, name in
                                                if confirmedHTMLTags != nil { tags.append((tag, name, true)) }
                                            })
                    if isCancelled() { throw CancellationError() }
                    if images != nil { confirmedHTMLTags?(node, range, tags) }
                    if htmlRawContext != "script" { scriptStartedInContainer = false }
                    if audio && images != nil && htmlRawContext == nil { confirmedAudio?(range) }
                    if video && images != nil && htmlRawContext == nil { confirmedVideo?(range) }
                    if let frame, images != nil, htmlRawContext == nil { confirmedFrame?(range, frame) }
                    if htmlForExport && kind == "html_block" && startedOutside && images != nil && htmlRawContext == nil { confirmedBlock?(range) }
                    if images == nil && relevant(range) {
                        if htmlForExport { htmlRawContext = "plaintext" }
                        else { throw UploadError.unsupportedImage }
                    }
                    for image in images ?? [] where relevant(image.range) {
                        if let selection, selection.length > 0, selection != image.range { throw UploadError.invalidInput }
                        found.append(image)
                        confirmedImage?(node, image)
                    }
                } else if let literal = cmark_node_get_literal(node) {
                    if htmlRawContext == "script" {
                        if htmlForExport { htmlRawContext = "plaintext"; return }
                        throw UploadError.unsupportedImage
                    }
                    let raw = String(cString: literal) as NSString
                    var localFilter = MarkdownHTMLMediaService.SourceHTMLFilter()
                    var localCursor: Int?
                    let images = MarkdownImageUploadService.htmlImages(in: raw, range: NSRange(location: 0, length: raw.length), rawContext: &htmlRawContext,
                                            scriptFilter: &localFilter, scriptCursor: &localCursor, isCancelled: isCancelled)
                    if htmlRawContext == "script" {
                        if !htmlForExport { throw UploadError.unsupportedImage }
                        htmlRawContext = "plaintext"
                    }
                    if isCancelled() { throw CancellationError() }
                    let first = max(0, min(Int(cmark_node_get_start_line(node)) - 1, lines.count - 1))
                    let last = max(first, min(Int(cmark_node_get_end_line(node)) - 1, lines.count - 1))
                    let end = lines[last].0 + (lines[last].1 as NSString).length
                    if (images == nil || !(images?.isEmpty ?? true)) && relevant(NSRange(location: lines[first].0, length: end - lines[first].0)) {
                        if !htmlForExport { throw UploadError.unsupportedImage }
                        if images == nil { htmlRawContext = "plaintext" }
                    }
                }
            }
            if kind == "image", htmlForExport { return }
            if kind == "image" {
                if htmlRawContext != nil { return }
                guard let whole = nodeRange(), let url = cmark_node_get_url(node) else {
                    let first = max(0, min(Int(cmark_node_get_start_line(node)) - 1, lines.count - 1))
                    let last = max(first, min(Int(cmark_node_get_end_line(node)) - 1, lines.count - 1))
                    let end = lines[last].0 + (lines[last].1 as NSString).length
                    if relevant(NSRange(location: lines[first].0, length: end - lines[first].0)) { throw UploadError.unsupportedImage }
                    return
                }
                if !relevant(whole) { return }
                if let selection, selection.length > 0, selection != whole { throw UploadError.invalidInput }
                guard let address = MarkdownImageUploadService.addressRange(in: text, image: whole) else {
                    guard let label = MarkdownImageUploadService.referenceLabel(text.substring(with: whole) as NSString) else { throw UploadError.unsupportedImage }
                    references.append((whole, currentOrdinal, label))
                    return
                }
                let raw = text.substring(with: whole) as NSString
                let local = NSRange(location: address.location - whole.location, length: address.length)
                let marker = "https://laceditor.invalid/" + UUID().uuidString
                let originalURL = String(cString: url)
                let title = cmark_node_get_title(node).map { String(cString: $0) } ?? ""
                guard imageIdentity(raw as String) == [originalURL, title],
                      imageIdentity(raw.replacingCharacters(in: local, with: marker)) == [marker, title] else { throw UploadError.unsupportedImage }
                found.append(Image(range: whole, addressRange: address, rawAddress: text.substring(with: address), address: String(cString: url), syntax: .markdown))
                return
            }
            var child = cmark_node_first_child(node)
            while let next = child { try visit(next); child = cmark_node_next(next) }
        }
        func process(_ root: OpaquePointer) -> Result<Void, Error> {
            mapping = sourceMapping ?? MarkdownSourcePositions(source, root: root, isCancelled: isCancelled)
            return Result {
                try visit(root)
                let links = inlineLinks.sorted { $0.location < $1.location }
                var linkEnd = 0
                let linkEnds = links.map { range in
                    linkEnd = max(linkEnd, NSMaxRange(range))
                    return linkEnd
                }
                for tags in inlineTags.values {
                    if isCancelled() { throw CancellationError() }
                    var stack: [(String, Int)] = [], valid = true, hasAnchor = false
                    for (range, tag) in tags where tag != "<br>" {
                        if isCancelled() { throw CancellationError() }
                        let closing = tag.hasPrefix("</")
                        let name = closing ? String(tag.dropFirst(2).dropLast()) : String(tag.dropFirst().prefix { $0 != " " && $0 != ">" })
                        if closing {
                            guard let opening = stack.last, opening.0 == name else { valid = false; break }
                            if name == "a" {
                                if unknownInlineLink { valid = false; break }
                                var low = 0, high = links.count
                                while low < high {
                                    let middle = (low + high) / 2
                                    if links[middle].location < range.location { low = middle + 1 } else { high = middle }
                                }
                                if low > 0 && linkEnds[low - 1] > opening.1 { valid = false; break }
                                hasAnchor = false
                            }
                            stack.removeLast()
                        } else {
                            if name == "a" && hasAnchor { valid = false; break }
                            if name == "a" { hasAnchor = true }
                            stack.append((name, range.location))
                        }
                    }
                    if !stack.isEmpty { valid = false }
                    for (range, tag) in tags where valid || tag == "<br>" {
                        if isCancelled() { throw CancellationError() }
                        confirmedInline?(range, tag)
                    }
                }
            }
        }
        let result: Result<Void, Error>
        if let root { result = process(root) }
        else {
            let input = MarkdownFrontMatter.maskedFrontMatter(source, frontMatter: MarkdownFrontMatter.frontMatter(source))
            guard let parsed = MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES, { root, _, _ in process(root) }) else { throw UploadError.invalidInput }
            result = parsed
        }
        try result.get()
        if isCancelled() { throw CancellationError() }
        return (found, references)
    }

    static func imageIdentity(_ source: String) -> [String]? {
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_parser_free(parser) }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(root) }
        var found: [[String]] = []
        func visit(_ node: OpaquePointer) {
            if let kind = cmark_node_get_type_string(node), String(cString: kind) == "image", let url = cmark_node_get_url(node) {
                found.append([String(cString: url), cmark_node_get_title(node).map { String(cString: $0) } ?? ""])
            }
            var child = cmark_node_first_child(node)
            while let next = child { visit(next); child = cmark_node_next(next) }
        }
        visit(OpaquePointer(root))
        return found.count == 1 ? found[0] : nil
    }

    static func destinations(_ source: String) -> [(String, String, String)]? {
        let input = MarkdownFrontMatter.maskedFrontMatter(source, frontMatter: MarkdownFrontMatter.frontMatter(source))
        return MarkdownMathExtension.withDocument(input, options: CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES) { root, _, _ in
            var values: [(String, String, String)] = []
            func visit(_ node: OpaquePointer) {
                guard let raw = cmark_node_get_type_string(node) else { return }
                let kind = String(cString: raw)
                if kind == "link" || kind == "image" {
                    values.append((kind, cmark_node_get_url(node).map { String(cString: $0) } ?? "",
                                   cmark_node_get_title(node).map { String(cString: $0) } ?? ""))
                    if kind == "image" { return }
                }
                var child = cmark_node_first_child(node)
                while let next = child { visit(next); child = cmark_node_next(next) }
            }
            visit(root)
            return values
        }
    }
}
