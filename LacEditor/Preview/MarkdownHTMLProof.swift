import Foundation
import AppKit
import SwiftSoup
import cmark_gfm

/// Подтверждение HTML по дереву cmark: код обхода узлов, перенесённый из `MarkdownHTMLMediaService` без изменений.
enum MarkdownHTMLProof {
    static func centeredMarkdownImage(_ block: String, isCancelled: () -> Bool, resolveImage: ((String) -> String?)?) -> String? {
        let raw = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix("<center>"), raw.lowercased().hasSuffix("</center>") else { return nil }
        let inner = String(raw.dropFirst(8).dropLast(9))
        guard inner.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("![") else { return nil }
        return MarkdownMathExtension.withDocument(inner, includeInline: false) { root, _, _ in
            guard let paragraph = cmark_node_first_child(root), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                  cmark_node_next(paragraph) == nil, let image = cmark_node_first_child(paragraph),
                  cmark_node_get_type(image) == CMARK_NODE_IMAGE, cmark_node_next(image) == nil,
                  let source = cmark_node_get_url(image) else { return nil }
            let text = inner as NSString
            guard let range = MarkdownSourcePositions(inner).range(image),
                  range.location >= 0, NSMaxRange(range) <= text.length,
                  text.substring(with: NSRange(location: 0, length: range.location)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.substring(from: NSMaxRange(range)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  MarkdownImageUploadService.addressRange(in: text, image: range) != nil else { return nil }
            var alt = "", child = cmark_node_first_child(image)
            while let node = child {
                if isCancelled() { return nil }
                guard cmark_node_get_type(node) == CMARK_NODE_TEXT, let value = cmark_node_get_literal(node) else { return nil }
                alt += String(cString: value)
                child = cmark_node_next(node)
            }
            func escape(_ value: String) -> String {
                value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            }
            let address = String(cString: source)
            guard !address.isEmpty else { return nil }
            let title = cmark_node_get_title(image).map { String(cString: $0) } ?? ""
            let titleAttribute = title.isEmpty ? "" : " title=\"\(escape(title))\""
            return "<center><img src=\"\(escape(resolveImage?(address) ?? address))\" alt=\"\(escape(alt))\"\(titleAttribute)></center>"
        } ?? nil
    }

    struct HTMLBlockCandidate {
        let node: OpaquePointer
        let start: Int
        let end: Int
        let html: String
    }

    static func htmlBlockTagOffsets(_ node: OpaquePointer, range: NSRange, tags: [NSRange], sourceText: NSString, isCancelled: () -> Bool) -> [Int: Int]? {
        guard let pointer = cmark_node_get_literal(node) else { return nil }
        return MarkdownHTMLMediaService.htmlBlockTagOffsets(literal: String(cString: pointer) as NSString, range: range, tags: tags, sourceText: sourceText, isCancelled: isCancelled)
    }

    struct ImageProofCandidate {
        let node: OpaquePointer
        let offset: Int
        let source: String
    }

    struct TextProofCandidate {
        let node: OpaquePointer
        let start: Int
        let end: Int
        let text: String
    }

    struct TextContainerCandidate {
        let node: OpaquePointer
        let opening: Int
        let closing: Int
        let name: String
    }

    struct TextStyleCandidate {
        let node: OpaquePointer
        let offset: Int
        let style: MarkdownInlineStyle
    }

    static func provenTextStyles(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                 candidates: [TextProofCandidate], styleCandidates: [TextStyleCandidate] = [], isCancelled: () -> Bool) -> [Int: MarkdownHTMLMediaService.ProvenText] {
        provenTextAndContainers(root: root, mathExtension: mathExtension, options: options, text: text,
            candidates: candidates, styleCandidates: styleCandidates, isCancelled: isCancelled) ?? [:]
    }

    static func provenTextAndContainers(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                 candidates: [TextProofCandidate], styleCandidates: [TextStyleCandidate] = [],
                                 containers: [TextContainerCandidate] = [], isCancelled: () -> Bool) -> [Int: MarkdownHTMLMediaService.ProvenText]? {
        guard (!candidates.isEmpty || !containers.isEmpty), !isCancelled() else { return nil }
        var prefix: String
        repeat { prefix = "LACTEXT" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var grouped: [OpaquePointer: [Int: [(Bool, String)]]] = [:], names: [String: (Int, Bool)] = [:]
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return nil }
            let start = prefix + "S" + String(index), end = prefix + "E" + String(index)
            grouped[candidate.node, default: [:]][candidate.start, default: []].append((true, start))
            grouped[candidate.node, default: [:]][candidate.end, default: []].append((false, end))
            names[start] = (index, true); names[end] = (index, false)
        }
        var styleNames: [String: MarkdownInlineStyle] = [:]
        for (index, candidate) in styleCandidates.enumerated() {
            if isCancelled() { return nil }
            let marker = prefix + "T" + String(index)
            styleNames[marker] = candidate.style
            grouped[candidate.node, default: [:]][candidate.offset, default: []].append((true, marker))
        }
        var containerNames: [String: (Int, Bool)] = [:]
        for (index, candidate) in containers.enumerated() {
            if isCancelled() { return nil }
            let opening = prefix + "BO" + String(index), closing = prefix + "BC" + String(index)
            grouped[candidate.node, default: [:]][candidate.opening, default: []].append((true, opening))
            grouped[candidate.node, default: [:]][candidate.closing, default: []].append((false, closing))
            containerNames[opening] = (index, true); containerNames[closing] = (index, false)
        }
        var insertions: [(OpaquePointer, Int, String)] = []
        for (node, offsets) in grouped {
            for (offset, markers) in offsets {
                if isCancelled() { return nil }
                let value = markers.sorted { !$0.0 && $1.0 }.map { "<!--\($0.1)-->" }.joined()
                insertions.append((node, offset, value))
            }
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options, insertions: insertions, isCancelled: isCancelled),
              !isCancelled() else { return nil }
        return MarkdownHTMLMediaService.provenText(inMarkedHTML: html, names: names, styleNames: styleNames, containerNames: containerNames,
                          candidateTexts: candidates.map { $0.text }, containerTags: containers.map { $0.name }, isCancelled: isCancelled)
    }

    struct MediaProofCandidate {
        let openingNode: OpaquePointer
        let openingOffset: Int
        let closingNode: OpaquePointer
        let closingOffset: Int
        let expected: MarkdownHTMLMediaService.ProvenMedia
    }

    static func provenStandaloneMedia(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                      candidates: [(node: OpaquePointer, media: MarkdownHTMLMediaService.StandaloneMedia)],
                                      isCancelled: () -> Bool) -> Set<Int> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var originals: [(OpaquePointer, String)] = [], nodes = Set<OpaquePointer>(), proof: [MediaProofCandidate] = []
        defer { for (node, literal) in originals { literal.withCString { _ = cmark_node_set_literal(node, $0) } } }
        for candidate in candidates {
            if isCancelled() { return [] }
            guard nodes.insert(candidate.node).inserted, let pointer = cmark_node_get_literal(candidate.node) else { return [] }
            let original = String(cString: pointer)
            guard let verified = MarkdownHTMLMediaService.standaloneMedia(original, isCancelled: isCancelled),
                  verified.normalizedLiteral.utf16.elementsEqual(candidate.media.normalizedLiteral.utf16),
                  verified.openingOffset == candidate.media.openingOffset, verified.closingOffset == candidate.media.closingOffset,
                  verified.media == candidate.media.media,
                  verified.normalizedLiteral.withCString({ cmark_node_set_literal(candidate.node, $0) }) != 0 else { return [] }
            originals.append((candidate.node, original))
            proof.append(.init(openingNode: candidate.node, openingOffset: verified.openingOffset,
                               closingNode: candidate.node, closingOffset: verified.closingOffset, expected: .media(verified.media)))
        }
        return provenMediaIndices(root: root, mathExtension: mathExtension, options: options, text: text,
                                  candidates: proof, isCancelled: isCancelled)
    }

    static func provenMediaIndices(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                   candidates: [MediaProofCandidate], isCancelled: () -> Bool,
                                   confirmedHTML: ((Int, String) -> Void)? = nil) -> Set<Int> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var prefix: String
        repeat { prefix = "LACMEDIA" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var grouped: [OpaquePointer: [Int: [(Bool, String)]]] = [:], names: [String: (Int, Bool)] = [:]
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return [] }
            let opening = prefix + "O" + String(index), closing = prefix + "C" + String(index)
            grouped[candidate.openingNode, default: [:]][candidate.openingOffset, default: []].append((true, opening))
            grouped[candidate.closingNode, default: [:]][candidate.closingOffset, default: []].append((false, closing))
            names[opening] = (index, true); names[closing] = (index, false)
        }
        var ambiguous: Set<Int> = []
        for offsets in grouped.values {
            for markers in offsets.values {
                if isCancelled() { return [] }
                for opening in [false, true] {
                    let duplicates = markers.filter { $0.0 == opening }
                    if duplicates.count > 1 { for (_, marker) in duplicates { if let index = names[marker]?.0 { ambiguous.insert(index) } } }
                }
            }
        }
        var insertions: [(OpaquePointer, Int, String)] = []
        for (node, offsets) in grouped {
            for (offset, markers) in offsets {
                if isCancelled() { return [] }
                let value = markers.filter { names[$0.1].map { !ambiguous.contains($0.0) } ?? false }
                    .sorted { !$0.0 && $1.0 }.map { "<!--\($0.1)-->" }.joined()
                if value.isEmpty { continue }
                insertions.append((node, offset, value))
            }
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options, insertions: insertions, isCancelled: isCancelled),
              !isCancelled() else { return [] }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            if confirmedHTML != nil { document.outputSettings().prettyPrint(pretty: false) }
            var pending: [Node] = [document], openings: [Int: Comment] = [:], closings: [Int: Comment] = [:], duplicates: Set<Int> = []
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (index, opening) = names[comment.getData()] else { continue }
                if opening {
                    if openings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
                } else if closings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
            }
            var accepted: Set<Int> = []
            for (index, candidate) in candidates.enumerated() {
                if isCancelled() { return [] }
                guard !ambiguous.contains(index), !duplicates.contains(index), let open = openings[index], let close = closings[index],
                      let element = open.nextSibling() as? Element, close.previousSibling() === element else { continue }
                var ancestor = element.parent(), inert = false
                while let current = ancestor {
                    if isCancelled() { return [] }
                    if ["template", "script", "style"].contains(current.tagName()) { inert = true; break }
                    ancestor = current.parent()
                }
                guard !inert else { continue }
                guard try MarkdownHTMLMediaService.mediaElementMatches(element, expected: candidate.expected, isCancelled: isCancelled) else { continue }
                if let confirmedHTML { confirmedHTML(index, try element.outerHtml()) }
                accepted.insert(index)
            }
            return accepted
        } catch { return [] }
    }

    private static func renderMarkedHTML(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32,
                                         insertions: [(OpaquePointer, Int, String)], isCancelled: () -> Bool) -> String? {
        var originals: [(OpaquePointer, String)] = []
        defer { for (node, literal) in originals { literal.withCString { _ = cmark_node_set_literal(node, $0) } } }
        let groups = Dictionary(grouping: insertions, by: { $0.0 })
        for (node, entries) in groups {
            if isCancelled() { return nil }
            guard let pointer = cmark_node_get_literal(node) else { return nil }
            let literal = String(cString: pointer)
            guard let changed = MarkdownHTMLMediaService.insertingMarkers(in: literal, insertions: entries.map { ($0.1, $0.2) }, isCancelled: isCancelled),
                  changed.withCString({ cmark_node_set_literal(node, $0) }) != 0 else { return nil }
            originals.append((node, literal))
        }
        guard !isCancelled() else { return nil }
        let allocator = cmark_get_default_mem_allocator()
        var extensions = cmark_llist_append(allocator, nil, UnsafeMutableRawPointer(mathExtension))
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            name.withCString { if let pointer = cmark_find_syntax_extension($0) {
                extensions = cmark_llist_append(allocator, extensions, UnsafeMutableRawPointer(pointer))
            } }
        }
        defer { cmark_llist_free(allocator, extensions) }
        guard let rendered = cmark_render_html(root, options | CMARK_OPT_UNSAFE, extensions) else { return nil }
        defer { free(rendered) }
        guard !isCancelled() else { return nil }
        return String(cString: rendered)
    }

    /// HTML строчных `<audio>`/`<video>` после разбора cmark всего документа (запасной текст оформлен: `**bold**` -> `<strong>`).
    /// Вызывается только при копировании и один раз на проекцию: метки ставятся у всех медиа разом, рендер и разбор SwiftSoup — один.
    /// Документ разбирается параметрами `syntax`, контекст сохраняется: ссылки-ссылки, сноски, цитаты, списки.
    /// Метка-комментарий ставится только после `</video>`, чтобы не менять начало строки. В результате нет тех медиа,
    /// для которых не доказано, что элемент перед меткой и есть это медиа; nil — не удалось разобрать документ.
    static func renderedInlineMediaHTML(markdown: String, media: [(range: NSRange, expected: MarkdownHTMLMediaService.ProvenMedia)], syntax: MarkdownSyntaxOptions,
                                        isCancelled: () -> Bool) -> [NSRange: String]? {
        let options = ((syntax.smartPunctuation ?? true) ? CMARK_OPT_SMART : 0) | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS | CMARK_OPT_FOOTNOTES
        let masked = MarkdownFrontMatter.maskedFrontMatter(markdown, frontMatter: MarkdownFrontMatter.frontMatter(markdown)) as NSString
        guard !media.isEmpty, !isCancelled() else { return nil }
        var prefix: String
        repeat { prefix = "LACMEDIA" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while masked.contains(prefix)
        let input = NSMutableString(string: masked as String)
        var previousStart = masked.length + 1
        for (index, item) in media.enumerated().sorted(by: { $0.element.range.location > $1.element.range.location }) {
            if isCancelled() { return nil }
            let end = NSMaxRange(item.range)
            guard item.range.location >= 0, end <= masked.length, end <= previousStart else { return nil }
            input.insert("<!--\(prefix)\(index)-->", at: end)
            previousStart = item.range.location
        }
        let rendered: [NSRange: String]?? = MarkdownMathExtension.withDocument(input as String, options: options, includeInline: syntax.inlineMath,
                                                                              legacyInlineMath: syntax.legacyInlineMath, strictMode: syntax.strictMode,
                                                                              sourceForPositions: input as String, isCancelled: isCancelled) { root, mathExtension, _ -> [NSRange: String]? in
            guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options, insertions: [], isCancelled: isCancelled),
                  !isCancelled(), let document = try? SwiftSoup.parseBodyFragment(html) else { return nil }
            document.outputSettings().prettyPrint(pretty: false)
            var pending: [Node] = [document], comments: [Int: [Comment]] = [:]
            while let node = pending.popLast() {
                if isCancelled() { return nil }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment else { continue }
                let name = comment.getData()
                if name.hasPrefix(prefix), let index = Int(name.dropFirst(prefix.count)) { comments[index, default: []].append(comment) }
            }
            var result: [NSRange: String] = [:]
            for (index, item) in media.enumerated() {
                if isCancelled() { return nil }
                guard let found = comments[index], found.count == 1, let element = found[0].previousSibling() as? Element,
                      ["video", "audio"].contains(element.tagName()),
                      (try? MarkdownHTMLMediaService.mediaElementMatches(element, expected: item.expected, isCancelled: isCancelled)) == true,
                      let outer = try? element.outerHtml() else { continue }
                result[item.range] = outer
            }
            return result
        }
        return rendered ?? nil
    }

    struct SVGProofCandidate {
        let opening: OpaquePointer
        let openingOffset: Int
        let closing: OpaquePointer
        let closingOffset: Int
        let literal: String
    }

    static func provenSVG(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                          candidates: [SVGProofCandidate], isCancelled: () -> Bool) -> Set<Int> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var prefix: String
        repeat { prefix = "LACSVG" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var insertions: [(OpaquePointer, Int, String)] = [], names: [String: (Int, Bool)] = [:]
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return [] }
            let opening = prefix + "O" + String(index), closing = prefix + "C" + String(index)
            names[opening] = (index, true); names[closing] = (index, false)
            insertions.append((candidate.opening, candidate.openingOffset, "<!--\(opening)-->"))
            insertions.append((candidate.closing, candidate.closingOffset, "<!--\(closing)-->"))
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options,
                                          insertions: insertions, isCancelled: isCancelled) else { return [] }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            var pending: [Node] = [document], openings: [Int: Comment] = [:], closings: [Int: Comment] = [:], duplicates = Set<Int>()
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (index, opening) = names[comment.getData()] else { continue }
                if opening {
                    if openings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
                } else if closings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
            }
            var accepted = Set<Int>()
            for (index, candidate) in candidates.enumerated() {
                if isCancelled() { return [] }
                guard !duplicates.contains(index), let opening = openings[index], let closing = closings[index],
                      let svg = opening.nextSibling() as? Element, svg.tagName() == "svg", closing.previousSibling() === svg,
                      MarkdownImageUploadService.standaloneSVGData(candidate.literal, isCancelled: isCancelled) != nil,
                      let body = try SwiftSoup.parseBodyFragment(candidate.literal).body(), body.children().size() == 1,
                      body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let expected = body.children().first(), expected.tagName() == "svg" else { continue }
                var ancestor = svg.parent(), inert = false
                while let current = ancestor {
                    if isCancelled() { return [] }
                    if ["script", "style", "template", "select"].contains(current.tagName()) { inert = true; break }
                    ancestor = current.parent()
                }
                if inert { continue }
                var pairs: [(Node, Node)] = [(expected, svg)], equal = true
                while let (left, right) = pairs.popLast() {
                    if isCancelled() { return [] }
                    if let a = left as? TextNode, let b = right as? TextNode {
                        if !a.getWholeText().utf16.elementsEqual(b.getWholeText().utf16) { equal = false; break }
                        continue
                    }
                    guard let a = left as? Element, let b = right as? Element, a.tagName() == b.tagName() else { equal = false; break }
                    let leftAttributes = a.getAttributes()?.asList() ?? [], rightAttributes = b.getAttributes()?.asList() ?? []
                    guard leftAttributes.count == rightAttributes.count else { equal = false; break }
                    var attributes: [String: String] = [:]
                    for attribute in rightAttributes { attributes[attribute.getKey()] = attribute.getValue() }
                    guard leftAttributes.allSatisfy({ attribute in attributes[attribute.getKey()].map { $0.utf16.elementsEqual(attribute.getValue().utf16) } ?? false }) else { equal = false; break }
                    let leftChildren = a.getChildNodes(), rightChildren = b.getChildNodes()
                    guard leftChildren.count == rightChildren.count else { equal = false; break }
                    pairs.append(contentsOf: zip(leftChildren, rightChildren))
                }
                if equal { accepted.insert(index) }
            }
            return accepted
        } catch { return [] }
    }

    struct RubyProofCandidate {
        let opening: OpaquePointer
        let closing: OpaquePointer
        let closingOffset: Int
        let base: String
        let reading: String
        let before: String?
        let after: String?
        var trailing: String? = nil
        var baseHTML: String? = nil
        var editingBaseHTML: String? = nil
    }

    static func provenRuby(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                           candidates: [RubyProofCandidate], isCancelled: () -> Bool) -> Set<Int> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var prefix: String
        repeat { prefix = "LACRUBY" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var insertions: [(OpaquePointer, Int, String)] = [], names: [String: (Int, Bool)] = [:]
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return [] }
            let opening = prefix + "O" + String(index), closing = prefix + "C" + String(index)
            names[opening] = (index, true); names[closing] = (index, false)
            insertions.append((candidate.opening, 0, "<!--\(opening)-->"))
            insertions.append((candidate.closing, candidate.closingOffset, "<!--\(closing)-->"))
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options,
                                          insertions: insertions, isCancelled: isCancelled) else { return [] }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            var pending: [Node] = [document], openings: [Int: Comment] = [:], closings: [Int: Comment] = [:], duplicates = Set<Int>()
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (index, opening) = names[comment.getData()] else { continue }
                if opening {
                    if openings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
                } else if closings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
            }
            var accepted = Set<Int>()
            for (index, candidate) in candidates.enumerated() {
                if isCancelled() { return [] }
                // A shortcode inside ruby would be shown differently by emoji rendering, so such ruby stays source.
                guard !EmojiShortcodeResolver.containsShortcode(candidate.base), !EmojiShortcodeResolver.containsShortcode(candidate.reading),
                      !duplicates.contains(index), let opening = openings[index], let closing = closings[index],
                      let ruby = opening.nextSibling() as? Element, ruby.tagName() == "ruby", closing.previousSibling() === ruby,
                      ruby.getAttributes()?.asList().isEmpty != false else { continue }
                var ancestor = ruby.parent(), inert = false
                while let current = ancestor {
                    if isCancelled() { return [] }
                    if ["script", "style", "template", "select"].contains(current.tagName()) { inert = true; break }
                    ancestor = current.parent()
                }
                if inert { continue }
                var expected: [(String, String)] = []
                var baseNodes: [Node] = []
                if let html = candidate.baseHTML {
                    guard let expectedBody = try SwiftSoup.parseBodyFragment("<ruby>" + html + "</ruby>").body(),
                          let expectedRuby = expectedBody.children().first(), expectedRuby.tagName() == "ruby" else { continue }
                    baseNodes = expectedRuby.getChildNodes()
                } else { expected.append(("", candidate.base)) }
                if let before = candidate.before { expected.append(("rp", before)) }
                expected.append(("rt", candidate.reading))
                if let after = candidate.after { expected.append(("rp", after)) }
                if let trailing = candidate.trailing { expected.append(("", trailing)) }
                let children = ruby.getChildNodes()
                guard children.count == expected.count + baseNodes.count else { continue }
                var matches = true
                for (child, expectedNode) in zip(children.prefix(baseNodes.count), baseNodes) {
                    if isCancelled() { return [] }
                    if !(try child.outerHtml()).utf16.elementsEqual((try expectedNode.outerHtml()).utf16) { matches = false; break }
                }
                if !matches { continue }
                for (child, item) in zip(children.dropFirst(baseNodes.count), expected) {
                    if isCancelled() { return [] }
                    let value: String
                    if item.0.isEmpty, let node = child as? TextNode { value = node.getWholeText() }
                    else if let node = child as? Element, node.tagName() == item.0,
                            node.getAttributes()?.asList().isEmpty != false,
                            node.getChildNodes().allSatisfy({ $0 is TextNode }) {
                        value = node.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined()
                    } else { matches = false; break }
                    if !value.utf16.elementsEqual(item.1.utf16) { matches = false; break }
                }
                if matches { accepted.insert(index) }
            }
            return accepted
        } catch { return [] }
    }

    static func provenDetails(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                              candidates: [(node: OpaquePointer, offset: Int, summary: String, body: String)],
                              isCancelled: () -> Bool) -> Set<OpaquePointer> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var prefix: String
        repeat { prefix = "LACDETAILS" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var names: [String: (OpaquePointer, String, String)] = [:], insertions: [(OpaquePointer, Int, String)] = []
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return [] }
            let marker = prefix + String(index)
            names[marker] = (candidate.node, candidate.summary, candidate.body)
            insertions.append((candidate.node, candidate.offset, "<!--\(marker)-->"))
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options,
                                          insertions: insertions, isCancelled: isCancelled), !isCancelled() else { return [] }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            document.outputSettings().prettyPrint(pretty: false)
            var pending: [Node] = [document], seen = Set<String>(), duplicates = Set<String>(), accepted: [String: OpaquePointer] = [:]
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (original, summary, body) = names[comment.getData()] else { continue }
                let marker = comment.getData()
                if !seen.insert(marker).inserted { duplicates.insert(marker); continue }
                guard let details = comment.nextSibling() as? Element, details.tagName() == "details",
                      let serialized = try? details.outerHtml(), let actual = MarkdownHTMLMediaService.plainDetails(serialized, isCancelled: isCancelled),
                      actual.summary.utf16.elementsEqual(summary.utf16), actual.body.utf16.elementsEqual(body.utf16) else { continue }
                var ancestor = details.parent(), inert = false
                while let current = ancestor {
                    if isCancelled() { return [] }
                    if ["template", "script", "style", "select"].contains(current.tagName()) { inert = true; break }
                    ancestor = current.parent()
                }
                if !inert { accepted[marker] = original }
            }
            return Set(accepted.compactMap { duplicates.contains($0.key) ? nil : $0.value })
        } catch { return [] }
    }

    struct TwitterProofCandidate {
        let node: OpaquePointer
        let start: Int
        let end: Int
        let widget: MarkdownHTMLMediaService.TwitterWidget
    }

    static func provenHTMLBlocks(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                 candidates: [HTMLBlockCandidate], isCancelled: () -> Bool) -> Set<Int> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var prefix: String
        repeat { prefix = "LACBLOCK" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var names: [String: (Int, Bool)] = [:], insertions: [(OpaquePointer, Int, String)] = []
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return [] }
            let opening = prefix + "O" + String(index), closing = prefix + "C" + String(index)
            names[opening] = (index, true); names[closing] = (index, false)
            insertions.append((candidate.node, candidate.start, "<!--\(opening)-->"))
            insertions.append((candidate.node, candidate.end, "<!--\(closing)-->"))
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options,
                                          insertions: insertions, isCancelled: isCancelled) else { return [] }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            document.outputSettings().prettyPrint(pretty: false)
            var pending: [Node] = [document], openings: [Int: Comment] = [:], closings: [Int: Comment] = [:], duplicates = Set<Int>()
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (index, opening) = names[comment.getData()] else { continue }
                if opening {
                    if openings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
                } else if closings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
            }
            var accepted = Set<Int>()
            for (index, candidate) in candidates.enumerated() {
                if isCancelled() { return [] }
                guard !duplicates.contains(index), let opening = openings[index], let closing = closings[index],
                      let element = opening.nextSibling() as? Element, closing.previousSibling() === element else { continue }
                var parent = element.parent(), inert = false
                while let current = parent {
                    if isCancelled() { return [] }
                    if ["script", "style", "template", "select"].contains(current.tagName()) { inert = true; break }
                    parent = current.parent()
                }
                if inert { continue }
                let fragment = try SwiftSoup.parseBodyFragment(candidate.html)
                fragment.outputSettings().prettyPrint(pretty: false)
                guard let body = fragment.body(), body.children().size() == 1,
                      body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let expected = body.children().first(),
                      try element.outerHtml().utf16.elementsEqual(expected.outerHtml().utf16) else { continue }
                accepted.insert(index)
            }
            return accepted
        } catch { return [] }
    }

    static func provenTwitter(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                              candidates: [TwitterProofCandidate], isCancelled: () -> Bool) -> Set<Int> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var prefix: String
        repeat { prefix = "LACTWITTER" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var names: [String: (Int, Bool)] = [:], insertions: [(OpaquePointer, Int, String)] = []
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return [] }
            guard cmark_node_get_type(candidate.node) == CMARK_NODE_HTML_BLOCK, let pointer = cmark_node_get_literal(candidate.node),
                  let verified = MarkdownHTMLMediaService.twitterWidget(String(cString: pointer), isCancelled: isCancelled),
                  verified.id.utf8.elementsEqual(candidate.widget.id.utf8),
                  verified.postURL.utf8.elementsEqual(candidate.widget.postURL.utf8),
                  verified.text.utf16.elementsEqual(candidate.widget.text.utf16) else { return [] }
            let opening = prefix + "O" + String(index), closing = prefix + "C" + String(index)
            names[opening] = (index, true); names[closing] = (index, false)
            insertions.append((candidate.node, candidate.start, "<!--\(opening)-->"))
            insertions.append((candidate.node, candidate.end, "<!--\(closing)-->"))
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options,
                                          insertions: insertions, isCancelled: isCancelled) else { return [] }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            document.outputSettings().prettyPrint(pretty: false)
            var pending: [Node] = [document], openings: [Int: Comment] = [:], closings: [Int: Comment] = [:], duplicates = Set<Int>()
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (index, opening) = names[comment.getData()] else { continue }
                if opening {
                    if openings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
                } else if closings.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
            }
            var accepted = Set<Int>()
            for (index, candidate) in candidates.enumerated() {
                if isCancelled() { return [] }
                guard !duplicates.contains(index), let opening = openings[index], let closing = closings[index],
                      let block = opening.nextSibling() as? Element, block.tagName() == "blockquote" else { continue }
                var sibling = block.nextSibling()
                while let value = sibling as? TextNode, value.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sibling = value.nextSibling() }
                guard let script = sibling as? Element, script.tagName() == "script", script.nextSibling() === closing else { continue }
                var ancestor = block.parent(), inert = false
                while let current = ancestor {
                    if isCancelled() { return [] }
                    if ["script", "style", "template", "select"].contains(current.tagName()) { inert = true; break }
                    ancestor = current.parent()
                }
                if inert { continue }
                let markup = try block.outerHtml() + "\n" + script.outerHtml()
                guard let actual = MarkdownHTMLMediaService.twitterWidget(markup, isCancelled: isCancelled),
                      actual.id.utf8.elementsEqual(candidate.widget.id.utf8),
                      actual.postURL.utf8.elementsEqual(candidate.widget.postURL.utf8),
                      actual.text.utf16.elementsEqual(candidate.widget.text.utf16) else { continue }
                accepted.insert(index)
            }
            return accepted
        } catch { return [] }
    }

    static func provenPageBreaks(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                 candidates: [(node: OpaquePointer, offset: Int, style: String)], isCancelled: () -> Bool) -> Set<OpaquePointer> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var prefix: String
        repeat { prefix = "LACBREAK" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        var names: [String: (OpaquePointer, String)] = [:], insertions: [(OpaquePointer, Int, String)] = []
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return [] }
            let marker = prefix + String(index)
            names[marker] = (candidate.node, candidate.style)
            insertions.append((candidate.node, candidate.offset, "<!--\(marker)-->"))
        }
        guard let html = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options,
                                          insertions: insertions, isCancelled: isCancelled), !isCancelled() else { return [] }
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            var pending: [Node] = [document], seen = Set<String>(), duplicates = Set<String>(), accepted: [String: OpaquePointer] = [:]
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (original, expected) = names[comment.getData()] else { continue }
                let marker = comment.getData()
                if !seen.insert(marker).inserted { duplicates.insert(marker); continue }
                guard let div = comment.nextSibling() as? Element, div.tagName() == "div", div.getChildNodes().isEmpty,
                      div.getAttributes()?.asList().count == 1, div.hasAttr("style"),
                      let actual = try? div.attr("style"), actual.utf8.elementsEqual(expected.utf8),
                      MarkdownHTMLMediaService.isPageBreakStyle(actual, isCancelled: isCancelled) else { continue }
                var ancestor = div.parent(), inert = false
                while let current = ancestor {
                    if isCancelled() { return [] }
                    if ["template", "script", "style", "select"].contains(current.tagName()) { inert = true; break }
                    ancestor = current.parent()
                }
                if !inert { accepted[marker] = original }
            }
            return Set(accepted.compactMap { duplicates.contains($0.key) ? nil : $0.value })
        } catch { return [] }
    }

    static func provenImageIndices(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                   candidates: [ImageProofCandidate], ancestors: [Int: [MarkdownHTMLMediaService.ImageAncestor]] = [:], isCancelled: () -> Bool) -> [Int: String] {
        guard !candidates.isEmpty, !isCancelled() else { return [:] }
        var markers: [String: Int] = [:], expected: [String: String] = [:], expectedAncestors: [String: [MarkdownHTMLMediaService.ImageAncestor]] = [:], insertions: [(OpaquePointer, Int, String)] = []
        var prefix: String
        repeat { prefix = "LACIMG" + UUID().uuidString.replacingOccurrences(of: "-", with: "") } while text.contains(prefix)
        let groups = Dictionary(grouping: candidates.enumerated(), by: { $0.element.node })
        for (node, entries) in groups {
            if isCancelled() { return [:] }
            guard let pointer = cmark_node_get_literal(node) else { continue }
            let raw = String(cString: pointer) as NSString
            for (index, candidate) in entries {
                if isCancelled() { return [:] }
                guard candidate.offset >= 0, candidate.offset <= raw.length, 4 <= raw.length - candidate.offset,
                      raw.substring(with: NSRange(location: candidate.offset, length: 4)).lowercased() == "<img" else { continue }
                let marker = prefix + String(index)
                insertions.append((node, candidate.offset, "<!--\(marker)-->"))
                markers[marker] = index; expected[marker] = candidate.source
                if let chain = ancestors[index] { expectedAncestors[marker] = chain }
            }
        }
        guard !markers.isEmpty, !isCancelled() else { return [:] }
        guard let rendered = renderMarkedHTML(root: root, mathExtension: mathExtension, options: options, insertions: insertions, isCancelled: isCancelled),
              !isCancelled(), let accepted = MarkdownHTMLMediaService.confirmedImageMarkers(in: rendered, expected: expected, ancestors: expectedAncestors, isCancelled: isCancelled),
              !isCancelled() else { return [:] }
        return Dictionary(uniqueKeysWithValues: accepted.compactMap { marker in markers[marker].map { ($0, marker) } })
    }
}
