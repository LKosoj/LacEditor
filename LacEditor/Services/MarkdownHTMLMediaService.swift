import Foundation
import AppKit
import SwiftSoup
import cmark_gfm

enum MarkdownHTMLMediaService {
    typealias ImageSizing = MarkdownImageSizing

    @MainActor
    static func nativeHTMLContent(_ confirmedEditingHTML: String, font: NSFont, foreground: NSColor, linkColor: NSColor = .linkColor,
                                  codeFont: NSFont? = nil, paragraphStyle: NSParagraphStyle? = nil,
                                  isCancelled: () -> Bool = { false }) -> NSAttributedString? {
        guard !isCancelled(), let document = try? SwiftSoup.parseBodyFragment(confirmedEditingHTML),
              let body = document.body(), body.children().size() == 1 else { return nil }
        let output = NSMutableAttributedString(string: "")
        var pendingSpace: [NSAttributedString.Key: Any]?
        var atLineStart = true
        var valid = true
        var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        if let paragraphStyle { base[.paragraphStyle] = paragraphStyle.copy() as? NSParagraphStyle }
        func monospaced(_ current: NSFont) -> NSFont {
            var mono = codeFont.map { NSFontManager.shared.convert($0, toSize: current.pointSize) }
                ?? NSFont.monospacedSystemFont(ofSize: current.pointSize, weight: .regular)
            let traits = NSFontManager.shared.traits(of: current)
            if traits.contains(.boldFontMask) { mono = NSFontManager.shared.convert(mono, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { mono = NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask) }
            return mono
        }
        func boundary() {
            pendingSpace = nil
            if output.length > 0 && !atLineStart {
                output.append(NSAttributedString(string: "\n", attributes: base))
                atLineStart = true
            }
        }
        func appendText(_ text: String, attributes: [NSAttributedString.Key: Any], preserve: Bool) {
            for scalar in text.unicodeScalars {
                if isCancelled() { valid = false; return }
                if !preserve && [9, 10, 12, 13, 32].contains(Int(scalar.value)) {
                    if pendingSpace == nil && !atLineStart { pendingSpace = attributes }
                } else {
                    if let space = pendingSpace { output.append(NSAttributedString(string: " ", attributes: space)); pendingSpace = nil }
                    output.append(NSAttributedString(string: String(scalar), attributes: attributes))
                    atLineStart = scalar.value == 10 || scalar.value == 13
                }
            }
        }
        func walk(_ node: Node, attributes: [NSAttributedString.Key: Any], preserve: Bool, inCell: Bool, explicitColor: Bool) {
            guard valid, !isCancelled() else { valid = false; return }
            if let text = node as? TextNode { appendText(text.getWholeText(), attributes: attributes, preserve: preserve); return }
            guard let element = node as? Element else { valid = false; return }
            let name = element.tagName().lowercased()
            if name == "br" { pendingSpace = nil; output.append(NSAttributedString(string: "\n", attributes: attributes)); atLineStart = true; return }
            if name == "table" {
                guard !inCell else { valid = false; return }
                boundary()
                var rows: [Element] = []
                for child in element.children().array() {
                    let tag = child.tagName().lowercased()
                    if tag == "tr" { rows.append(child) }
                    else if ["thead", "tbody", "tfoot"].contains(tag) {
                        for row in child.children().array() {
                            guard row.tagName().lowercased() == "tr" else { valid = false; return }
                            rows.append(row)
                        }
                    } else { valid = false; return }
                }
                guard !rows.isEmpty else { valid = false; return }
                var occupied = Array(repeating: IndexSet(), count: rows.count), cells: [(Element, Int, Int, Int, Int)] = [], columns = 0
                for (rowIndex, row) in rows.enumerated() {
                    var column = 0
                    for cell in row.children().array() {
                        if isCancelled() { valid = false; return }
                        guard ["td", "th"].contains(cell.tagName().lowercased()) else { valid = false; return }
                        while let range = occupied[rowIndex].rangeView.first(where: { $0.contains(column) }) {
                            if isCancelled() { valid = false; return }
                            column = range.upperBound
                        }
                        func span(_ key: String) -> Int? {
                            guard cell.hasAttr(key) else { return 1 }
                            guard let value = try? cell.attr(key), !value.isEmpty,
                                  value.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(value), n > 0 else { return nil }
                            return min(n, key == "colspan" ? 1000 : 65534)
                        }
                        guard let rs = span("rowspan"), let cs = span("colspan"), rs <= rows.count - rowIndex,
                              cs <= Int.max - column else { valid = false; return }
                        let columnsRange = column..<(column + cs)
                        for r in rowIndex..<(rowIndex + rs) {
                            if isCancelled() || !occupied[r].intersection(IndexSet(integersIn: columnsRange)).isEmpty { valid = false; return }
                            occupied[r].insert(integersIn: columnsRange)
                        }
                        cells.append((cell, rowIndex, column, rs, cs)); column += cs
                        columns = max(columns, column)
                    }
                }
                guard columns > 0 else { valid = false; return }
                for row in rows.indices {
                    if isCancelled() || occupied[row].count != columns { valid = false; return }
                }
                let table = NSTextTable(); table.numberOfColumns = columns; table.collapsesBorders = true
                for (cell, row, column, rs, cs) in cells {
                    if isCancelled() { valid = false; return }
                    let start = output.length
                    var cellAttributes = attributes
                    if cell.tagName().lowercased() == "th", let current = cellAttributes[.font] as? NSFont {
                        cellAttributes[.font] = NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask)
                    }
                    for child in cell.getChildNodes() { walk(child, attributes: cellAttributes, preserve: false, inCell: true, explicitColor: explicitColor) }
                    guard valid else { return }
                    pendingSpace = nil
                    output.append(NSAttributedString(string: "\n", attributes: attributes))
                    atLineStart = true
                    let style = (paragraphStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    style.textBlocks = [NSTextTableBlock(table: table, startingRow: row, rowSpan: rs, startingColumn: column, columnSpan: cs)]
                    output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
                }
                return
            }
            let blocks = ["div", "p", "pre"]
            let inline = ["span", "strong", "b", "em", "i", "u", "s", "del", "mark", "sub", "sup", "kbd", "code", "a"]
            guard blocks.contains(name) || inline.contains(name) else { valid = false; return }
            if blocks.contains(name) { boundary() }
            var next = attributes
            var nextExplicitColor = explicitColor
            if name == "span", element.hasAttr("style") {
                guard let css = try? element.attr("style"), let style = MarkdownInlineStyle(css: css) else { valid = false; return }
                if let color = style.foreground { next[.foregroundColor] = color.nsColor; nextExplicitColor = true }
                if let color = style.background { next[.backgroundColor] = color.nsColor }
                if let size = style.fontSize, let current = next[.font] as? NSFont { next[.font] = NSFontManager.shared.convert(current, toSize: CGFloat(size)) }
            }
            if let current = next[.font] as? NSFont {
                if ["strong", "b"].contains(name) { next[.font] = NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask) }
                if ["em", "i"].contains(name) { next[.font] = NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask) }
                if ["code", "kbd", "pre"].contains(name) { next[.font] = monospaced(current) }
            }
            if name == "u" { next[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if ["s", "del"].contains(name) { next[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if name == "mark" { next[.backgroundColor] = NSColor.yellow }
            if name == "sub" || name == "sup" { next[.superscript] = name == "sup" ? 1 : -1 }
            if name == "a" {
                guard let href = try? element.attr("href"), !href.isEmpty else { valid = false; return }
                next[.link] = href
                if next[.underlineStyle] == nil { next[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if !nextExplicitColor { next[.foregroundColor] = linkColor }
            }
            for child in element.getChildNodes() { walk(child, attributes: next, preserve: preserve || name == "pre", inCell: inCell, explicitColor: nextExplicitColor) }
            if blocks.contains(name) { boundary() }
        }
        guard let root = body.children().first() else { return nil }
        walk(root, attributes: base, preserve: false, inCell: false, explicitColor: false)
        guard valid, !isCancelled() else { return nil }
        return output
    }

    struct TwitterWidget: Equatable {
        let id: String
        let postURL: String
        let text: String
        var iframeURL: String { "https://platform.twitter.com/embed/Tweet.html?id=" + id + "&dnt=true" }
    }

    static func twitterFrame(_ widget: TwitterWidget) -> EmbeddedFrame? {
        guard let url = URL(string: widget.iframeURL) else { return nil }
        return EmbeddedFrame(source: url, width: nil, height: nil, title: nil, fallback: "",
                             allowsFullscreen: false, scrolling: nil, frameBorder: nil, allowTransparency: nil)
    }

    static func twitterFallbackHTML(_ widget: TwitterWidget) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return "<blockquote>" + escape(widget.text) + " <a href=\"" + escape(widget.postURL) + "\">" + escape(widget.postURL) + "</a></blockquote>"
    }

    static func twitterWidget(_ literal: String, isCancelled: () -> Bool = { false }) -> TwitterWidget? {
        let raw = literal as NSString
        var first = 0
        while first < raw.length && [9, 10, 12, 13, 32].contains(Int(raw.character(at: first))) { if isCancelled() { return nil }; first += 1 }
        guard raw.length - first >= 11,
              raw.substring(with: NSRange(location: first, length: 11)).lowercased() == "<blockquote" else { return nil }
        var context = MarkdownImageUploadService.HTMLContext(), tags: [(NSRange, String, Bool)] = []
        let safe = context.consume(source: raw, range: NSRange(location: 0, length: raw.length), isCancelled: isCancelled,
            confirmedTag: { tags.append(($0, $1, $2)) }, confirmedRawClose: { tags.append(($0, $1, true)) })
        guard safe, !isCancelled() else { return nil }
        func space(_ value: unichar) -> Bool { [9, 10, 12, 13, 32].contains(Int(value)) }
        func attributes(_ range: NSRange, name: String) -> Set<String>? {
            let end = NSMaxRange(range), begin = range.location + 1 + (name as NSString).length
            guard begin < end, raw.substring(with: NSRange(location: range.location + 1, length: (name as NSString).length)).lowercased() == name else { return nil }
            var cursor = begin, result = Set<String>()
            while cursor < end - 1 {
                if isCancelled() { return nil }
                guard space(raw.character(at: cursor)) else { return nil }
                while cursor < end - 1 && space(raw.character(at: cursor)) { cursor += 1 }
                if cursor == end - 1 { break }
                let start = cursor
                while cursor < end - 1 {
                    let unit = raw.character(at: cursor)
                    if space(unit) || unit == 61 || unit == 62 { break }
                    guard (65...90).contains(unit) || (97...122).contains(unit) || unit == 45 else { return nil }
                    cursor += 1
                }
                guard cursor > start else { return nil }
                let key = raw.substring(with: NSRange(location: start, length: cursor - start)).lowercased()
                guard result.insert(key).inserted else { return nil }
                let afterName = cursor
                while cursor < end - 1 && space(raw.character(at: cursor)) { cursor += 1 }
                if cursor == end - 1 || raw.character(at: cursor) != 61 {
                    guard name == "script", key == "async" else { return nil }
                    cursor = afterName
                    continue
                }
                cursor += 1
                while cursor < end - 1 && space(raw.character(at: cursor)) { cursor += 1 }
                guard cursor < end - 1 else { return nil }
                let quote = raw.character(at: cursor)
                if quote == 34 || quote == 39 {
                    cursor += 1
                    while cursor < end - 1 && raw.character(at: cursor) != quote {
                        if isCancelled() || raw.character(at: cursor) == 60 { return nil }; cursor += 1
                    }
                    guard cursor < end - 1 else { return nil }; cursor += 1
                } else {
                    let valueStart = cursor
                    while cursor < end - 1 && !space(raw.character(at: cursor)) {
                        if isCancelled() || [34, 39, 60, 61, 96].contains(Int(raw.character(at: cursor))) { return nil }; cursor += 1
                    }
                    guard cursor > valueStart else { return nil }
                }
            }
            return result
        }
        var stack: [String] = [], rootClosed = false, scriptClosed = false, scriptStart: Int?
        for (range, name, closing) in tags {
            if isCancelled() { return nil }
            guard ["blockquote", "p", "a", "script"].contains(name) else { return nil }
            if closing {
                guard let last = stack.last, last == name,
                      raw.substring(with: range).lowercased() == "</" + name + ">" else { return nil }
                if name == "script", let start = scriptStart {
                    guard raw.substring(with: NSRange(location: start, length: range.location - start)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    scriptClosed = true
                }
                stack.removeLast()
                if name == "blockquote" { rootClosed = true }
                continue
            }
            guard let names = attributes(range, name: name) else { return nil }
            switch name {
            case "blockquote": guard stack.isEmpty, !rootClosed, names == ["class"] else { return nil }
            case "p": guard stack == ["blockquote"], names.isSubset(of: ["lang", "dir"]) else { return nil }
            case "a": guard stack == ["blockquote"] || stack == ["blockquote", "p"], names == ["href"] else { return nil }
            case "script":
                guard stack.isEmpty, rootClosed, !scriptClosed, names == ["async", "src", "charset"] else { return nil }
                scriptStart = NSMaxRange(range)
            default: return nil
            }
            stack.append(name)
        }
        guard stack.isEmpty, rootClosed, scriptClosed, !isCancelled() else { return nil }
        do {
            guard let body = try SwiftSoup.parseBodyFragment(literal).body(), body.children().size() == 2,
                  body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let block = body.children().first(), block.tagName() == "blockquote", try block.attr("class") == "twitter-tweet",
                  let script = body.children().array().last, script.tagName() == "script", script.hasAttr("async"),
                  try script.attr("src") == "https://platform.twitter.com/widgets.js", try script.attr("charset").lowercased() == "utf-8" else { return nil }
            for node in body.getChildNodes() {
                if isCancelled() { return nil }
                if let value = node as? TextNode, value.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if node === block || node === script { continue }
                return nil
            }
            var nodes: [Node] = block.getChildNodes()
            while let node = nodes.popLast() {
                if isCancelled() { return nil }
                if node is TextNode { continue }
                guard let element = node as? Element, ["p", "a"].contains(element.tagName()) else { return nil }
                nodes.append(contentsOf: element.getChildNodes())
            }
            var matches: [(String, String)] = []
            for anchor in try block.select("a[href]").array() {
                if isCancelled() { return nil }
                let address = try anchor.attr("href")
                guard let url = URLComponents(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil else { return nil }
                guard url.scheme?.lowercased() == "https",
                      let host = url.host?.lowercased(), ["twitter.com", "x.com"].contains(host),
                      url.port == nil, url.fragment == nil,
                      url.percentEncodedQuery == nil || url.percentEncodedQuery == "ref_src=twsrc%5Etfw" else { continue }
                let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 4, parts[0].isEmpty, !parts[1].isEmpty, parts[2] == "status", !parts[3].isEmpty,
                      parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }),
                      parts[3].utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
                matches.append((String(parts[3]), address))
            }
            guard matches.count == 1 else { return nil }
            return TwitterWidget(id: matches[0].0, postURL: matches[0].1, text: try block.text())
        } catch { return nil }
    }

    struct EmbeddedFrame: Equatable, Sendable {
        let source: URL
        let width: String?
        let height: String?
        let title: String?
        let fallback: String
        let allowsFullscreen: Bool
        let scrolling: String?
        let frameBorder: String?
        let allowTransparency: String?
    }

    private static func centeredMarkdownImage(_ block: String, isCancelled: () -> Bool, resolveImage: ((String) -> String?)?) -> String? {
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
            guard let range = MarkdownPresentationParser.Source(inner).range(image),
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

    // The caller supplies the whole, cmark-confirmed HTML block.
    static func iframe(in confirmedHTMLBlock: String) -> EmbeddedFrame? {
        do {
            let document = try SwiftSoup.parseBodyFragment(confirmedHTMLBlock)
            guard let body = document.body(), body.children().size() == 1,
                  body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let frame = body.children().first(), frame.tagName() == "iframe" else { return nil }
            return iframe(element: frame)
        } catch { return nil }
    }

    private static func iframe(element frame: Element) -> EmbeddedFrame? {
        do {
            let attributes = frame.getAttributes()?.asList() ?? []
            let allowed: Set<String> = ["src", "width", "height", "title", "style", "scrolling", "frameborder", "allowtransparency", "allowfullscreen"]
            guard attributes.allSatisfy({ allowed.contains($0.getKey().lowercased()) }), frame.hasAttr("src") else { return nil }
            let rawSource = try frame.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawSource.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
            let absolute = rawSource.hasPrefix("//") ? "https:" + rawSource : rawSource
            guard let url = URL(string: absolute), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            func dimension(_ raw: String) -> String? {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let suffix = value.hasSuffix("%") ? "%" : (value.hasSuffix("px") ? "px" : "")
                let number = suffix.isEmpty ? value : String(value.dropLast(suffix.count))
                guard !number.isEmpty, number.allSatisfy({ $0.isNumber || $0 == "." }),
                      let scalar = Double(number), scalar.isFinite, scalar > 0 else { return nil }
                return number + suffix
            }
            var width: String?, height: String?
            if frame.hasAttr("width") { guard let value = dimension(try frame.attr("width")) else { return nil }; width = value }
            if frame.hasAttr("height") { guard let value = dimension(try frame.attr("height")) else { return nil }; height = value }
            if frame.hasAttr("style") {
                let style = try frame.attr("style")
                for declaration in style.split(separator: ";") {
                    let parts = declaration.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, let value = dimension(String(parts[1])) else { return nil }
                    switch parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    case "width": width = value
                    case "height": height = value
                    default: return nil
                    }
                }
            }
            var fallback = ""
            for child in frame.getChildNodes() {
                if let text = child as? TextNode { fallback += text.getWholeText() }
                else if let data = child as? DataNode { fallback += data.getWholeData() }
                else { return nil }
            }
            guard fallback.range(of: "</iframe", options: .caseInsensitive) == nil else { return nil }
            return EmbeddedFrame(source: url, width: width, height: height,
                                 title: frame.hasAttr("title") ? try frame.attr("title") : nil,
                                 fallback: fallback, allowsFullscreen: frame.hasAttr("allowfullscreen"),
                                 scrolling: frame.hasAttr("scrolling") ? try frame.attr("scrolling") : nil,
                                 frameBorder: frame.hasAttr("frameborder") ? try frame.attr("frameborder") : nil,
                                 allowTransparency: frame.hasAttr("allowtransparency") ? try frame.attr("allowtransparency") : nil)
        } catch { return nil }
    }

    static func iframeHTML(_ frame: EmbeddedFrame) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func dimension(_ value: String) -> String {
            value.hasSuffix("%") || value.hasSuffix("px") ? value : value + "px"
        }
        var html = "<iframe sandbox=\"allow-scripts" + (frame.allowsFullscreen ? " allow-presentation" : "") + "\" src=\"\(escape(frame.source.absoluteString))\""
        if let title = frame.title { html += " title=\"\(escape(title))\"" }
        if let scrolling = frame.scrolling { html += " scrolling=\"\(escape(scrolling))\"" }
        if let border = frame.frameBorder { html += " frameborder=\"\(escape(border))\"" }
        if let transparency = frame.allowTransparency { html += " allowtransparency=\"\(escape(transparency))\"" }
        if frame.allowsFullscreen { html += " allowfullscreen" }
        var style = ""
        if let width = frame.width { style += "width:\(dimension(width));" }
        if let height = frame.height { style += "height:\(dimension(height));" }
        if !style.isEmpty { html += " style=\"\(style)\"" }
        return html + ">" + frame.fallback + "</iframe>"
    }

    struct ExportBlock {
        let html: String
        let omitted: Bool
        var sourceFallback = false
    }

    struct HTMLBlockCandidate {
        let node: OpaquePointer
        let start: Int
        let end: Int
        let html: String
    }

    static func editingHTMLBlock(_ literal: String, isCancelled: @escaping () -> Bool) -> String? {
        let raw = literal as NSString
        let allowed: Set<String> = ["div", "p", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "details", "summary", "span", "strong", "em", "b", "i", "u", "s", "del", "mark", "sub", "sup", "kbd", "code", "pre", "a", "br"]
        func space(_ unit: unichar) -> Bool { [9, 10, 12, 13, 32].contains(Int(unit)) }
        var context = MarkdownImageUploadService.HTMLContext(), stack: [String] = [], valid = true, roots = 0
        let safe = context.consume(source: raw, range: NSRange(location: 0, length: raw.length), isCancelled: isCancelled, confirmedTag: { range, name, closing in
            if isCancelled() || !valid { valid = false; return }
            guard allowed.contains(name) else { valid = false; return }
            let tag = raw.substring(with: range) as NSString
            if closing {
                guard (tag as String).lowercased() == "</\(name)>", stack.last == name else { valid = false; return }
                stack.removeLast(); return
            }
            if stack.isEmpty { roots += 1; if !["div", "p", "table", "details"].contains(name) { valid = false; return } }
            var cursor = 1 + (name as NSString).length, names = Set<String>()
            while cursor < tag.length - 1 {
                guard space(tag.character(at: cursor)) else { valid = false; return }
                while cursor < tag.length - 1 && space(tag.character(at: cursor)) { if isCancelled() { valid = false; return }; cursor += 1 }
                if cursor == tag.length - 1 { break }
                let start = cursor
                while cursor < tag.length - 1 {
                    if isCancelled() { valid = false; return }
                    let unit = tag.character(at: cursor)
                    if space(unit) || unit == 61 || unit == 62 { break }
                    guard (65...90).contains(unit) || (97...122).contains(unit) || unit == 45 else { valid = false; return }
                    cursor += 1
                }
                guard cursor > start else { valid = false; return }
                let key = tag.substring(with: NSRange(location: start, length: cursor - start)).lowercased()
                guard names.insert(key).inserted else { valid = false; return }
                let afterName = cursor
                while cursor < tag.length - 1 && space(tag.character(at: cursor)) { if isCancelled() { valid = false; return }; cursor += 1 }
                if cursor >= tag.length - 1 || tag.character(at: cursor) != 61 {
                    guard name == "details", key == "open" else { valid = false; return }
                    cursor = afterName; continue
                }
                cursor += 1
                while cursor < tag.length - 1 && space(tag.character(at: cursor)) { if isCancelled() { valid = false; return }; cursor += 1 }
                guard cursor < tag.length - 1 else { valid = false; return }
                let quote = tag.character(at: cursor)
                if quote == 34 || quote == 39 {
                    cursor += 1
                    while cursor < tag.length - 1 && tag.character(at: cursor) != quote { if isCancelled() { valid = false; return }; cursor += 1 }
                    guard cursor < tag.length - 1 else { valid = false; return }; cursor += 1
                } else {
                    let begin = cursor
                    while cursor < tag.length - 1 && !space(tag.character(at: cursor)) {
                        if isCancelled() || [34, 39, 60, 61, 96].contains(Int(tag.character(at: cursor))) { valid = false; return }
                        cursor += 1
                    }
                    guard cursor > begin else { valid = false; return }
                }
            }
            let accepted: Set<String> = name == "a" ? ["href"] : name == "span" ? ["style"] :
                name == "details" ? ["open"] : name == "td" || name == "th" ? ["colspan", "rowspan"] : []
            guard names.isSubset(of: accepted), name != "a" || names.contains("href") else { valid = false; return }
            if name == "span", names.contains("style"), inlineStyleOpening(tag as String, isCancelled: isCancelled) == nil { valid = false; return }
            if name != "br" { stack.append(name) }
        })
        guard safe, valid, roots == 1, stack.isEmpty, !isCancelled() else { return nil }
        do {
            guard let body = try SwiftSoup.parseBodyFragment(literal).body(), body.children().size() == 1,
                  body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var pending: [Node] = body.getChildNodes()
            while let node = pending.popLast() {
                if isCancelled() { return nil }
                if node is TextNode { continue }
                guard let element = node as? Element else { return nil }
                pending.append(contentsOf: element.getChildNodes())
            }
        } catch { return nil }
        guard let output = exportBlock(literal, isCancelled: isCancelled, imageOnly: true, editingStyles: true),
              !output.omitted, !output.sourceFallback else { return nil }
        return output.html
    }

    typealias EmbeddedMedia = MarkdownEmbeddedMedia

    // The caller supplies one whole cmark-confirmed HTML block.
    static func embeddedMedia(in html: String) -> EmbeddedMedia? {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body(), body.children().size() == 1,
                  body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let element = body.children().first() else { return nil }
            let kind: EmbeddedMedia.Kind
            switch element.tagName().lowercased() {
            case "audio": kind = .audio
            case "video": kind = .video
            default: return nil
            }
            let allowed: Set<String> = kind == .video ? ["src", "controls", "width", "height"] : ["src", "controls"]
            guard (element.getAttributes()?.asList() ?? []).allSatisfy({ allowed.contains($0.getKey().lowercased()) }) else { return nil }
            func dimension(_ name: String) throws -> String? {
                guard element.hasAttr(name) else { return nil }
                let value = try element.attr(name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let suffix = value.hasSuffix("%") ? "%" : (value.hasSuffix("px") ? "px" : "")
                let number = suffix.isEmpty ? value : String(value.dropLast(suffix.count))
                guard !number.isEmpty, number.allSatisfy({ $0.isNumber || $0 == "." }),
                      let scalar = Double(number), scalar.isFinite, scalar > 0 else { throw MediaError.invalidDimension }
                return number + suffix
            }
            var sources: [String] = []
            if element.hasAttr("src") {
                let source = try element.attr("src")
                guard !source.isEmpty else { return nil }
                sources = [source]
            } else {
                for child in element.children().array() {
                    guard child.tagName().lowercased() == "source", child.hasAttr("src"),
                          (child.getAttributes()?.asList() ?? []).allSatisfy({ ["src", "type"].contains($0.getKey().lowercased()) }) else { return nil }
                    let source = try child.attr("src")
                    guard !source.isEmpty else { return nil }
                    sources.append(source)
                }
            }
            guard !sources.isEmpty else { return nil }
            return EmbeddedMedia(kind: kind, sources: sources,
                                 controls: element.hasAttr("controls") || (kind == .audio && audioSource(in: html) != nil)
                                    || (kind == .video && videoSource(in: html) != nil),
                                 width: try dimension("width"), height: try dimension("height"))
        } catch { return nil }
    }

    private enum MediaError: Error { case invalidDimension }

    static func videoInsertion(file: URL, document: URL?, text: String, location: Int) -> MarkdownFormattingEdit? {
        let source = text as NSString
        guard location >= 0, location <= source.length,
              Range(NSRange(location: location, length: 0), in: text) != nil,
              let address = MarkdownImageEditingService.address(for: file, document: document) else { return nil }
        let escaped = address.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let newline = text.contains("\r\n") ? "\r\n" : (text.contains("\n") ? "\n" : (text.contains("\r") ? "\r" : "\n"))
        let prefix = location == 0 ? "" : newline + newline
        let suffix = location == source.length ? "" : newline + newline
        let replacement = prefix + "<video src=\"" + escaped + "\" />" + suffix
        return MarkdownFormattingEdit(range: NSRange(location: location, length: 0), replacement: replacement,
                                      selectionRange: NSRange(location: location + (replacement as NSString).length, length: 0))
    }

    static func inlineStyleOpening(_ html: String, isCancelled: () -> Bool = { false }) -> MarkdownInlineStyle? {
        let raw = html as NSString
        func whitespace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
        guard raw.length >= 8, raw.substring(with: NSRange(location: 0, length: 5)).lowercased() == "<span" else { return nil }
        var cursor = 5
        guard whitespace(raw.character(at: cursor)) else { return nil }
        while cursor < raw.length && whitespace(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor + 5 <= raw.length, raw.substring(with: NSRange(location: cursor, length: 5)).lowercased() == "style" else { return nil }
        cursor += 5
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
            let document = try SwiftSoup.parseBodyFragment(html + "</span>")
            guard !isCancelled(), let body = document.body(), body.children().size() == 1,
                  let span = body.children().first(), span.tagName() == "span",
                  span.getAttributes()?.asList().count == 1, span.hasAttr("style"), span.getChildNodes().isEmpty else { return nil }
            return MarkdownInlineStyle(css: try span.attr("style"))
        } catch { return nil }
    }

    static func pageBreakStyle(_ html: String, isCancelled: () -> Bool = { false }) -> String? {
        let raw = html.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        func space(_ value: unichar) -> Bool { [9, 10, 12, 13, 32].contains(Int(value)) }
        guard raw.length >= 17, raw.substring(with: NSRange(location: 0, length: 4)).lowercased() == "<div" else { return nil }
        var cursor = 4
        guard space(raw.character(at: cursor)) else { return nil }
        while cursor < raw.length && space(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor + 5 <= raw.length, raw.substring(with: NSRange(location: cursor, length: 5)).lowercased() == "style" else { return nil }
        cursor += 5
        while cursor < raw.length && space(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor < raw.length, raw.character(at: cursor) == 61 else { return nil }
        cursor += 1
        while cursor < raw.length && space(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor < raw.length else { return nil }
        let quote = raw.character(at: cursor)
        if quote == 34 || quote == 39 {
            cursor += 1
            while cursor < raw.length && raw.character(at: cursor) != quote { if isCancelled() { return nil }; cursor += 1 }
            guard cursor < raw.length else { return nil }
            cursor += 1
        } else {
            let start = cursor
            while cursor < raw.length && !space(raw.character(at: cursor)) && raw.character(at: cursor) != 62 {
                if isCancelled() { return nil }
                guard ![34, 39, 60, 61, 96].contains(Int(raw.character(at: cursor))) else { return nil }
                cursor += 1
            }
            guard cursor > start else { return nil }
        }
        while cursor < raw.length && space(raw.character(at: cursor)) { if isCancelled() { return nil }; cursor += 1 }
        guard cursor < raw.length, raw.character(at: cursor) == 62,
              raw.substring(from: cursor + 1).lowercased() == "</div>", !isCancelled() else { return nil }
        do {
            let document = try SwiftSoup.parseBodyFragment(raw as String)
            guard !isCancelled(), let body = document.body(), body.children().size() == 1,
                  let div = body.children().first(), div.tagName() == "div", div.getChildNodes().isEmpty,
                  div.getAttributes()?.asList().count == 1, div.hasAttr("style") else { return nil }
            let css = try div.attr("style")
            return isPageBreakStyle(css, isCancelled: isCancelled) ? css : nil
        } catch { return nil }
    }

    static func isPageBreak(_ html: String, isCancelled: () -> Bool = { false }) -> Bool {
        pageBreakStyle(html, isCancelled: isCancelled) != nil
    }

    private static func isPageBreakStyle(_ css: String, isCancelled: () -> Bool) -> Bool {
        var seen = Set<String>()
        for part in css.split(separator: ";") {
            if isCancelled() { return false }
            let pair = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard seen.insert(name).inserted,
                  (name == "page-break-after" && value == "always") || (name == "break-after" && value == "page") else { return false }
        }
        return seen.contains("page-break-after") && !isCancelled()
    }

    static func hasStyledSpan(in html: String, isCancelled: @escaping () -> Bool = { false }) -> Bool {
        let source = html as NSString
        var context = MarkdownImageUploadService.HTMLContext(), found = false
        _ = context.consume(source: source, range: NSRange(location: 0, length: source.length), isCancelled: isCancelled, confirmedTag: { range, name, closing in
            guard !found, !isCancelled(), name == "span", !closing,
                  let document = try? SwiftSoup.parseBodyFragment(source.substring(with: range) + "</span>"),
                  let span = document.body()?.children().first(), span.tagName() == "span", span.hasAttr("style") else { return }
            found = true
        })
        return found && !isCancelled()
    }

    static func anchorNames(inOpeningTag html: String) -> [String] {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body(), body.children().size() == 1,
                  body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let link = body.children().first(), link.tagName() == "a", link.getChildNodes().isEmpty else { return [] }
            var names: [String] = []
            for key in ["id", "name"] where link.hasAttr(key) {
                let value = try link.attr(key)
                if !value.isEmpty && !names.contains(where: { $0.utf8.elementsEqual(value.utf8) }) { names.append(value) }
            }
            return names
        } catch { return [] }
    }

    static func inlineLinkOpening(_ html: String) -> String? {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body(), body.children().size() == 1,
                  body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let link = body.children().first(), link.tagName() == "a", link.getChildNodes().isEmpty,
                  let result = exportBlock(html), !result.omitted, result.html.hasSuffix("</a>") else { return nil }
            return String(result.html.dropLast(4))
        } catch { return nil }
    }

    // A whole cmark-confirmed block is parsed once as HTML; no source positions
    // are inferred from the DOM and source text is never changed.
    struct ExportImageMarker {
        let source: String
        let address: String
    }

    static func exportBlock(_ confirmedHTMLBlock: String, isCancelled: @escaping () -> Bool = { false },
                            anchorMarkers: [String: [String]] = [:],
                            imageMarkers: [String: ExportImageMarker] = [:],
                            mediaMarkers: [String: ProvenMedia] = [:],
                            imageOnly: Bool = false,
                            editingStyles: Bool = false,
                            resolveMedia: ((String) -> String)? = nil,
                            fallbackSource: String? = nil,
                            resolveImage: ((String) -> String?)? = nil) -> ExportBlock? {
        do {
            if isCancelled() { return nil }
            let input = confirmedHTMLBlock as NSString
            var context = MarkdownImageUploadService.HTMLContext(), styles: [(NSRange, MarkdownInlineStyle)] = [], unsupportedStyle = false
            _ = context.consume(source: input, range: NSRange(location: 0, length: input.length), isCancelled: isCancelled, confirmedTag: { range, name, closing in
                guard name == "span", !closing, !isCancelled() else { return }
                let tag = input.substring(with: range)
                guard let fragment = try? SwiftSoup.parseBodyFragment(tag + "</span>"),
                      let span = fragment.body()?.children().first(), span.tagName() == "span", span.hasAttr("style") else { return }
                if let style = inlineStyleOpening(tag, isCancelled: isCancelled) { styles.append((range, style)) }
                else { unsupportedStyle = true }
            })
            guard !isCancelled() else { return nil }
            if unsupportedStyle {
                guard let fallbackSource else { return nil }
                let escaped = fallbackSource.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return ExportBlock(html: "<pre>" + escaped + "</pre>", omitted: false, sourceFallback: true)
            }
            var styleMarkers: [String: MarkdownInlineStyle] = [:], insertions: [(Int, String)] = []
            if !styles.isEmpty {
                var prefix: String
                repeat { prefix = "LACSTYLE" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
                while confirmedHTMLBlock.contains(prefix)
                for (index, item) in styles.enumerated() {
                    if isCancelled() { return nil }
                    let marker = prefix + String(index)
                    styleMarkers[marker] = item.1
                    insertions.append((item.0.location, "<!--\(marker)-->"))
                }
            }
            guard let marked = insertingMarkers(in: confirmedHTMLBlock, insertions: insertions, isCancelled: isCancelled) else { return nil }
            let document = try SwiftSoup.parseBodyFragment(marked)
            guard !isCancelled(), let body = document.body() else { return nil }
            if anchorMarkers.isEmpty, imageMarkers.isEmpty, mediaMarkers.isEmpty, body.children().size() == 1, body.children().first()?.tagName() == "center",
               let image = centeredMarkdownImage(confirmedHTMLBlock, isCancelled: isCancelled, resolveImage: resolveImage) {
                guard !isCancelled() else { return nil }
                return ExportBlock(html: image, omitted: false)
            }
            var markedAnchors = Set<ObjectIdentifier>()
            var markedImages: [ObjectIdentifier: ExportImageMarker] = [:]
            var markedMedia = Set<ObjectIdentifier>()
            var markedStyles: [ObjectIdentifier: MarkdownInlineStyle] = [:]
            if !styleMarkers.isEmpty {
                var pending: [Node] = [body], seen = Set<String>()
                while let node = pending.popLast() {
                    if isCancelled() { return nil }
                    pending.append(contentsOf: node.getChildNodes())
                    guard let comment = node as? Comment, let expected = styleMarkers[comment.getData()] else { continue }
                    guard seen.insert(comment.getData()).inserted, let span = comment.nextSibling() as? Element,
                          span.tagName() == "span", span.getAttributes()?.asList().count == 1, span.hasAttr("style"),
                          MarkdownInlineStyle(css: try span.attr("style")) == expected else { return nil }
                    markedStyles[ObjectIdentifier(span)] = expected
                }
                guard seen.count == styleMarkers.count else { return nil }
            }
            if !mediaMarkers.isEmpty {
                var pending: [Node] = [body], openings: [String: Comment] = [:], closings: [String: Comment] = [:]
                while let node = pending.popLast() {
                    if isCancelled() { return nil }
                    pending.append(contentsOf: node.getChildNodes())
                    guard let comment = node as? Comment else { continue }
                    let value = comment.getData()
                    guard let suffix = value.last, suffix == "O" || suffix == "C" else { continue }
                    let marker = String(value.dropLast())
                    guard mediaMarkers[marker] != nil else { continue }
                    if suffix == "O" {
                        guard openings.updateValue(comment, forKey: marker) == nil else { return nil }
                    } else {
                        guard closings.updateValue(comment, forKey: marker) == nil else { return nil }
                    }
                }
                for (marker, expected) in mediaMarkers {
                    if isCancelled() { return nil }
                    guard let opening = openings[marker], let closing = closings[marker],
                          let element = opening.nextSibling() as? Element, closing.previousSibling() === element,
                          try mediaElementMatches(element, expected: expected, isCancelled: isCancelled) else { return nil }
                    var ancestor = element.parent()
                    while let current = ancestor {
                        if isCancelled() { return nil }
                        if ["template", "script", "style"].contains(current.tagName()) { return nil }
                        ancestor = current.parent()
                    }
                    markedMedia.insert(ObjectIdentifier(element))
                }
            }
            if !imageMarkers.isEmpty {
                var pending: [Node] = [body], seen = Set<String>()
                while let node = pending.popLast() {
                    if isCancelled() { return nil }
                    pending.append(contentsOf: node.getChildNodes())
                    guard let comment = node as? Comment, let expected = imageMarkers[comment.getData()] else { continue }
                    guard seen.insert(comment.getData()).inserted, let image = comment.nextSibling() as? Element,
                          image.tagName() == "img", image.hasAttr("src"),
                          try image.attr("src").utf8.elementsEqual(expected.source.utf8) else { return nil }
                    markedImages[ObjectIdentifier(image)] = expected
                }
                guard seen.count == imageMarkers.count else { return nil }
            }
            if !anchorMarkers.isEmpty {
                var pending = [body], seen = Set<String>()
                while let parent = pending.popLast() {
                    if isCancelled() { return nil }
                    let children = parent.getChildNodes()
                    for (index, child) in children.enumerated() {
                        guard let element = child as? Element else { continue }
                        pending.append(element)
                        let id = try element.attr("id")
                        guard let expected = anchorMarkers[id] else { continue }
                        guard element.tagName() == "span", element.getChildNodes().isEmpty,
                              seen.insert(id).inserted, index + 1 < children.count,
                              let next = children[index + 1] as? Element, next.tagName() == "a" else { return nil }
                        var names: [String] = []
                        for key in ["id", "name"] where next.hasAttr(key) {
                            let value = try next.attr(key)
                            if !value.isEmpty && !names.contains(where: { $0.utf8.elementsEqual(value.utf8) }) { names.append(value) }
                        }
                        guard names.count == expected.count,
                              zip(names, expected).allSatisfy({ pair in pair.0.utf8.elementsEqual(pair.1.utf8) }) else { return nil }
                        markedAnchors.insert(ObjectIdentifier(next))
                    }
                }
                guard seen.count == anchorMarkers.count else { return nil }
            }
            var omitted = false, output = ""
            func escape(_ value: String) -> String {
                value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            }
            let containers: Set<String> = ["center", "div", "p", "span", "strong", "em", "b", "i", "u", "s", "del", "mark", "sub", "sup", "blockquote", "ul", "ol", "li", "details", "summary", "kbd", "ruby", "rt", "rp", "pre", "code", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "h1", "h2", "h3", "h4", "h5", "h6", "a"]
            var pending = body.getChildNodes().reversed().map { ($0, false) }
            while let (node, closing) = pending.popLast() {
                if isCancelled() { return nil }
                if closing, let element = node as? Element { output += "</\(element.tagName().lowercased())>"; continue }
                if let text = node as? TextNode { output += escape(text.getWholeText()); continue }
                guard let element = node as? Element else { continue }
                let name = element.tagName().lowercased()
                if ["script", "style", "template", "noscript"].contains(name) { omitted = true; continue }
                let confirmedMedia = markedMedia.contains(ObjectIdentifier(element))
                let confirmedSource = name == "source" && element.parent().map { markedMedia.contains(ObjectIdentifier($0)) } == true
                if imageOnly && ["audio", "video", "source", "iframe"].contains(name) && !confirmedMedia && !confirmedSource {
                    omitted = true
                    pending.append(contentsOf: element.getChildNodes().reversed().map { ($0, false) })
                    continue
                }
                if imageOnly && name == "img" && markedImages[ObjectIdentifier(element)] == nil { omitted = true; continue }
                if name == "iframe" {
                    if let frame = iframe(element: element) { output += iframeHTML(frame) }
                    else { omitted = true }
                    continue
                }
                if name == "input" {
                    guard element.hasAttr("type"), (try element.attr("type")).lowercased() == "checkbox" else {
                        omitted = true; continue
                    }
                }
                let isMedia = name == "img" || name == "audio" || name == "video" || name == "source"
                guard containers.contains(name) || isMedia || name == "br" || name == "hr" || name == "input" else {
                    omitted = true
                    pending.append(contentsOf: element.getChildNodes().reversed().map { ($0, false) })
                    continue
                }
                var allowed: Set<String> = ["title"]
                if name == "span", anchorMarkers[try element.attr("id")] != nil { allowed.insert("id") }
                if name == "img" { allowed.formUnion(["src", "alt", "width", "height"]) }
                if name == "audio" || name == "video" { allowed.formUnion(["src", "controls", "width", "height"]) }
                if name == "source" { allowed.formUnion(["src", "type"]) }
                if name == "a" { allowed.insert("href") }
                if name == "input" { allowed.formUnion(["type", "checked", "disabled"]) }
                if name == "ol" { allowed.formUnion(["start", "reversed", "type"]) }
                if name == "li" { allowed.insert("value") }
                if name == "details" { allowed.insert("open") }
                if name == "td" || name == "th" { allowed.formUnion(["colspan", "rowspan", "headers"]) }
                if name == "th" { allowed.insert("scope") }
                var attrs = name == "audio" || name == "video" ? " controls" : ""
                if let style = markedStyles[ObjectIdentifier(element)] {
                    let css = editingStyles ? style.editingCSS : style.css
                    if !css.isEmpty { attrs += " style=\"\(escape(css))\"" }
                }
                if name == "img", markedImages[ObjectIdentifier(element)] != nil {
                    let sizing = ImageSizing(width: element.hasAttr("width") ? try element.attr("width") : nil,
                                             height: element.hasAttr("height") ? try element.attr("height") : nil,
                                             style: element.hasAttr("style") ? try element.attr("style") : nil)
                    if !sizing.css.isEmpty { attrs += " style=\"\(escape(sizing.css))\"" }
                }
                for attribute in element.getAttributes()?.asList() ?? [] {
                    if isCancelled() { return nil }
                    let key = attribute.getKey().lowercased(), value = attribute.getValue()
                    if key == "style" { continue }
                    if name == "a", markedAnchors.contains(ObjectIdentifier(element)), ["id", "name"].contains(key) { continue }
                    guard allowed.contains(key) else { omitted = true; continue }
                    if key == "controls" { continue }
                    if name == "input" && ["checked", "disabled"].contains(key) { attrs += " \(key)"; continue }
                    if (name == "ol" && key == "reversed") || (name == "details" && key == "open") { attrs += " \(key)"; continue }
                    if key == "href" {
                        let normalized = value.unicodeScalars.filter { $0.value > 32 && $0.value != 127 }.map { String($0) }.joined().lowercased()
                        if normalized.hasPrefix("javascript:") || normalized.hasPrefix("data:") { omitted = true; continue }
                    }
                    let address = name == "img" ? (markedImages[ObjectIdentifier(element)]?.address ?? value) : value
                    let outputValue: String
                    if name == "img" && key == "src" { outputValue = resolveImage?(address) ?? address }
                    else if key == "src" && (confirmedMedia || confirmedSource) { outputValue = resolveMedia?(value) ?? value }
                    else { outputValue = value }
                    attrs += " \(key)=\"\(escape(outputValue))\""
                }
                if ["img", "source"].contains(name) {
                    guard element.hasAttr("src"), !(try element.attr("src")).isEmpty else { omitted = true; continue }
                }
                output += "<\(name)\(attrs)>"
                if !["img", "source", "br", "hr", "input"].contains(name) {
                    pending.append((node, true))
                    pending.append(contentsOf: element.getChildNodes().reversed().map { ($0, false) })
                }
            }
            return ExportBlock(html: output, omitted: omitted)
        } catch { return nil }
    }
    // The caller supplies one html_block from the shared cmark tree.
    static func audioSource(in confirmedHTMLBlock: String, allowPaired: Bool = false) -> String? {
        mediaSource(in: confirmedHTMLBlock, name: "audio", allowPaired: allowPaired)
    }

    static func videoSource(in confirmedHTMLBlock: String) -> String? {
        mediaSource(in: confirmedHTMLBlock, name: "video", allowPaired: true)
    }

    private static func mediaSource(in confirmedHTMLBlock: String, name: String, allowPaired: Bool) -> String? {
        let source = confirmedHTMLBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = source.lowercased()
        guard (allowPaired ? lowered.hasPrefix("<" + name) : source.hasPrefix("<" + name)),
              (source.hasSuffix("/>") || (allowPaired && lowered.hasSuffix("</" + name + ">"))),
              !source.contains("\n"), !source.contains("\r") else { return nil }
        if let opening = source.firstIndex(where: { $0 == "\"" || $0 == "'" }),
           let closing = source[source.index(after: opening)...].firstIndex(of: source[opening]),
           source[source.index(after: opening)..<closing].contains("\t") { return nil }
        let delegate = AudioElementParser(name: name)
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isValid else { return nil }
        return delegate.source
    }

    struct Image {
        let source: String
        let alt: String?
        let title: String?
        let width: String?
        let height: String?
    }

    struct DisplayImage {
        let source: String
        let alt: String
        let title: String?
        let sizing: ImageSizing
    }

    static func htmlBlockTagOffsets(_ node: OpaquePointer, range: NSRange, tags: [NSRange], sourceText: NSString, isCancelled: () -> Bool) -> [Int: Int]? {
        guard let pointer = cmark_node_get_literal(node), range.length > 0 else { return nil }
        let literal = String(cString: pointer) as NSString
        var cursor = range.location, offset = 0, tagIndex = 0, result: [Int: Int] = [:]
        while offset < literal.length {
            if isCancelled() { return nil }
            let newline = literal.range(of: "\n", options: .literal, range: NSRange(location: offset, length: literal.length - offset))
            let end = newline.location == NSNotFound ? literal.length : newline.location
            let length = end - offset
            let line = sourceText.lineRange(for: NSRange(location: cursor, length: 0))
            var contentEnd = min(NSMaxRange(line), NSMaxRange(range))
            while contentEnd > cursor && [10, 13].contains(Int(sourceText.character(at: contentEnd - 1))) { contentEnd -= 1 }
            let start = contentEnd - length
            guard start >= cursor,
                  sourceText.substring(with: NSRange(location: start, length: length)).utf16
                    .elementsEqual(literal.substring(with: NSRange(location: offset, length: length)).utf16) else { return nil }
            while tagIndex < tags.count && tags[tagIndex].location < contentEnd {
                if isCancelled() { return nil }
                guard tags[tagIndex].location >= start else { return nil }
                result[tags[tagIndex].location] = offset + tags[tagIndex].location - start
                tagIndex += 1
            }
            while tagIndex < tags.count && tags[tagIndex].location < min(NSMaxRange(line), NSMaxRange(range)) {
                if isCancelled() { return nil }
                guard newline.location != NSNotFound, tags[tagIndex].location >= contentEnd else { return nil }
                result[tags[tagIndex].location] = end
                tagIndex += 1
            }
            if newline.location == NSNotFound || end + 1 == literal.length {
                return contentEnd == NSMaxRange(range) && tagIndex == tags.count ? result : nil
            }
            guard NSMaxRange(line) > cursor, NSMaxRange(line) <= NSMaxRange(range) else { return nil }
            cursor = NSMaxRange(line); offset = end + 1
        }
        return nil
    }

    struct ImageAncestor {
        let name: String
        let style: MarkdownInlineStyle?
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

    struct ProvenText {
        let text: String
        let styles: [String]
        let inlineStyle: MarkdownInlineStyle?
        let blocks: [String]
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
                                 candidates: [TextProofCandidate], styleCandidates: [TextStyleCandidate] = [], isCancelled: () -> Bool) -> [Int: ProvenText] {
        provenTextAndContainers(root: root, mathExtension: mathExtension, options: options, text: text,
            candidates: candidates, styleCandidates: styleCandidates, isCancelled: isCancelled) ?? [:]
    }

    static func provenTextAndContainers(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                 candidates: [TextProofCandidate], styleCandidates: [TextStyleCandidate] = [],
                                 containers: [TextContainerCandidate] = [], isCancelled: () -> Bool) -> [Int: ProvenText]? {
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
              !isCancelled(), let document = try? SwiftSoup.parse(html, "", Parser.htmlParser()) else { return nil }
        var pending: [Node] = [document], starts: [Int: Comment] = [:], ends: [Int: Comment] = [:], duplicates: Set<Int> = []
        while let node = pending.popLast() {
            if isCancelled() { return nil }
            for child in node.getChildNodes() { if isCancelled() { return nil }; pending.append(child) }
            guard let comment = node as? Comment, let (index, start) = names[comment.getData()] else { continue }
            if start { if starts.updateValue(comment, forKey: index) != nil { duplicates.insert(index) } }
            else if ends.updateValue(comment, forKey: index) != nil { duplicates.insert(index) }
        }
        var containerOpen: [Int: Comment] = [:], containerClose: [Int: Comment] = [:]
        var containerNodes: [Node] = [document]
        while let node = containerNodes.popLast() {
            if isCancelled() { return nil }
            containerNodes.append(contentsOf: node.getChildNodes())
            guard let comment = node as? Comment, let (index, opening) = containerNames[comment.getData()] else { continue }
            if opening { if containerOpen.updateValue(comment, forKey: index) != nil { return nil } }
            else if containerClose.updateValue(comment, forKey: index) != nil { return nil }
        }
        for (index, candidate) in containers.enumerated() {
            if isCancelled() { return nil }
            guard let opening = containerOpen[index], let closing = containerClose[index],
                  let element = opening.nextSibling() as? Element, closing.previousSibling() === element,
                  element.tagName() == candidate.name, (element.getAttributes()?.asList() ?? []).isEmpty else { return nil }
        }
        var markedStyles: [ObjectIdentifier: MarkdownInlineStyle] = [:], seenStyles = Set<String>()
        var styleNodes: [Node] = [document]
        while let node = styleNodes.popLast() {
            if isCancelled() { return nil }
            styleNodes.append(contentsOf: node.getChildNodes())
            guard let comment = node as? Comment, let expected = styleNames[comment.getData()] else { continue }
            guard seenStyles.insert(comment.getData()).inserted, let span = comment.nextSibling() as? Element,
                  span.tagName() == "span", span.getAttributes()?.asList().count == 1, span.hasAttr("style"),
                  let css = try? span.attr("style"), MarkdownInlineStyle(css: css) == expected else { return nil }
            markedStyles[ObjectIdentifier(span)] = expected
        }
        guard seenStyles.count == styleNames.count else { return nil }
        var result: [Int: ProvenText] = [:]
        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { return nil }
            guard !duplicates.contains(index), let start = starts[index], let end = ends[index],
                  let value = start.nextSibling() as? TextNode, end.previousSibling() === value else { continue }
            let decoded = value.getWholeText()
            guard MarkdownInlineTextProjection.pieces(spelling: candidate.text as NSString, literal: decoded, sourceOffset: 0, isCancelled: isCancelled) != nil else { continue }
            var current = value.parent(), styles: [String] = [], inlineStyles: [MarkdownInlineStyle] = [], blocks: [String] = [], valid = false
            while let node = current {
                if isCancelled() { return nil }
                guard let element = node as? Element else { break }
                let name = element.tagName().lowercased()
                if name == "body" { valid = true; break }
                guard ["div", "p", "span", "strong", "b", "em", "i", "u", "s", "del", "mark", "sub", "sup", "kbd"].contains(name) else { break }
                if let inline = markedStyles[ObjectIdentifier(element)] { inlineStyles.append(inline) }
                else if !(element.getAttributes()?.asList() ?? []).isEmpty { break }
                if name == "div" || name == "p" { blocks.append(name) }
                if !["div", "p", "span"].contains(name) { styles.append(name) }
                current = element.parent()
            }
            if valid {
                var combined: MarkdownInlineStyle?
                for inline in inlineStyles.reversed() { combined = combined.map { inline.inheriting($0) } ?? inline }
                result[index] = ProvenText(text: decoded, styles: Array(styles.reversed()), inlineStyle: combined, blocks: Array(blocks.reversed()))
            }
        }
        return result
    }

    enum ProvenMedia: Equatable {
        case media(EmbeddedMedia)
        case frame(EmbeddedFrame)
    }

    struct StandaloneMedia {
        let normalizedLiteral: String
        let openingOffset: Int
        let closingOffset: Int
        let media: EmbeddedMedia
    }

    static func standaloneMedia(_ literal: String, isCancelled: () -> Bool) -> StandaloneMedia? {
        let raw = literal as NSString
        func space(_ value: unichar) -> Bool { [9, 10, 12, 13, 32].contains(Int(value)) }
        var start = 0, end = raw.length
        while start < end && space(raw.character(at: start)) { if isCancelled() { return nil }; start += 1 }
        while end > start && space(raw.character(at: end - 1)) { if isCancelled() { return nil }; end -= 1 }
        guard end > start + 2, raw.character(at: start) == 60 else { return nil }
        var cursor = start + 1
        while cursor < end && ((65...90).contains(raw.character(at: cursor)) || (97...122).contains(raw.character(at: cursor))) { cursor += 1 }
        let name = raw.substring(with: NSRange(location: start + 1, length: cursor - start - 1)).lowercased()
        guard ["audio", "video"].contains(name), cursor < end, space(raw.character(at: cursor)) else { return nil }
        let allowed: Set<String> = name == "audio" ? ["src", "controls"] : ["src", "controls", "width", "height"]
        var attributes = Set<String>(), slash: Int?
        while cursor < end {
            if isCancelled() { return nil }
            while cursor < end && space(raw.character(at: cursor)) {
                if raw.character(at: cursor) == 10 || raw.character(at: cursor) == 13 { return nil }
                cursor += 1
            }
            guard cursor < end else { return nil }
            if raw.character(at: cursor) == 47, cursor + 1 == end - 1, raw.character(at: cursor + 1) == 62 { slash = cursor; break }
            let begin = cursor
            while cursor < end {
                let unit = raw.character(at: cursor)
                if space(unit) || [47, 61, 62].contains(Int(unit)) { break }
                guard (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit) || unit == 45 else { return nil }
                cursor += 1
            }
            guard cursor > begin else { return nil }
            let attribute = raw.substring(with: NSRange(location: begin, length: cursor - begin)).lowercased()
            guard allowed.contains(attribute), attributes.insert(attribute).inserted else { return nil }
            while cursor < end && space(raw.character(at: cursor)) {
                if raw.character(at: cursor) == 10 || raw.character(at: cursor) == 13 { return nil }
                cursor += 1
            }
            if cursor >= end || raw.character(at: cursor) != 61 {
                guard attribute == "controls" else { return nil }
                continue
            }
            cursor += 1
            while cursor < end && space(raw.character(at: cursor)) {
                if raw.character(at: cursor) == 10 || raw.character(at: cursor) == 13 { return nil }
                cursor += 1
            }
            guard cursor < end else { return nil }
            let quote = raw.character(at: cursor)
            if quote == 34 || quote == 39 {
                cursor += 1; let valueStart = cursor
                while cursor < end && raw.character(at: cursor) != quote {
                    if isCancelled() || [10, 13, 60].contains(Int(raw.character(at: cursor))) { return nil }
                    cursor += 1
                }
                guard cursor < end, cursor > valueStart || attribute == "controls" else { return nil }
                cursor += 1
            } else {
                let valueStart = cursor
                while cursor < end && !space(raw.character(at: cursor)) && raw.character(at: cursor) != 62 {
                    if isCancelled() || [34, 39, 60, 61, 96].contains(Int(raw.character(at: cursor))) { return nil }
                    cursor += 1
                }
                guard cursor > valueStart else { return nil }
            }
        }
        guard !isCancelled(), attributes.contains("src"), let slash else { return nil }
        let tag = raw.substring(with: NSRange(location: start, length: slash - start)) + "></" + name + ">"
        guard let media = embeddedMedia(in: tag) else { return nil }
        let prefix = raw.substring(with: NSRange(location: 0, length: start))
        let suffix = raw.substring(from: end)
        return StandaloneMedia(normalizedLiteral: prefix + tag + suffix, openingOffset: start,
                               closingOffset: start + (tag as NSString).length, media: media)
    }

    static func copyMediaHTML(_ html: String, expected: ProvenMedia, resolveMedia: @escaping (String) -> String,
                              isCancelled: @escaping () -> Bool) -> String? {
        if case .frame(let frame) = expected { return iframeHTML(frame) }
        let marker = "LACCOPYMEDIA" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard !html.contains(marker),
              let exported = exportBlock("<!--\(marker)O-->" + html + "<!--\(marker)C-->", isCancelled: isCancelled,
                                         mediaMarkers: [marker: expected], imageOnly: true, resolveMedia: resolveMedia),
              !exported.omitted, !isCancelled() else { return nil }
        do {
            guard case .media(let media) = expected else { return nil }
            var safeHTML = exported.html
            if !media.controls {
                let tag = media.kind == .audio ? "audio" : "video"
                let prefix = "<\(tag) controls"
                guard safeHTML.hasPrefix(prefix) else { return nil }
                safeHTML = "<\(tag)" + String(safeHTML.dropFirst(prefix.count))
            }
            guard let original = try SwiftSoup.parseBodyFragment(html).body()?.children().first(),
                  let result = try SwiftSoup.parseBodyFragment(safeHTML).body()?.children().first() else { return nil }
            func same(_ left: Node, _ right: Node) throws -> Bool {
                if isCancelled() { return false }
                if let a = left as? TextNode, let b = right as? TextNode {
                    return a.getWholeText().utf16.elementsEqual(b.getWholeText().utf16)
                }
                guard let a = left as? Element, let b = right as? Element, a.tagName() == b.tagName() else { return false }
                var attributes: [String: String] = [:], actual: [String: String] = [:]
                for attribute in a.getAttributes()?.asList() ?? [] {
                    let key = attribute.getKey().lowercased()
                    if key == "controls" { continue }
                    attributes[key] = key == "src" && (a.tagName() == "source" || a === original)
                        ? resolveMedia(attribute.getValue()) : attribute.getValue()
                }
                for attribute in b.getAttributes()?.asList() ?? [] {
                    let key = attribute.getKey().lowercased()
                    if key != "controls" { actual[key] = attribute.getValue() }
                }
                guard attributes.count == actual.count,
                      attributes.allSatisfy({ key, value in actual[key].map { $0.utf16.elementsEqual(value.utf16) } ?? false }),
                      a !== original || b.hasAttr("controls") == media.controls else { return false }
                let leftChildren = a.getChildNodes(), rightChildren = b.getChildNodes()
                guard leftChildren.count == rightChildren.count else { return false }
                for (leftChild, rightChild) in zip(leftChildren, rightChildren) {
                    if try !same(leftChild, rightChild) { return false }
                }
                return true
            }
            return try same(original, result) && !isCancelled() ? safeHTML : nil
        } catch { return nil }
    }

    private static func mediaElementMatches(_ element: Element, expected: ProvenMedia, isCancelled: () -> Bool) throws -> Bool {
        if isCancelled() { return false }
        switch expected {
        case .frame(let expected):
            func same(_ left: String?, _ right: String?) -> Bool {
                switch (left, right) {
                case (nil, nil): return true
                case let (left?, right?): return left.utf8.elementsEqual(right.utf8)
                default: return false
                }
            }
            guard element.tagName() == "iframe", let actual = iframe(element: element), actual == expected else { return false }
            return actual.source.absoluteString.utf8.elementsEqual(expected.source.absoluteString.utf8) &&
                actual.fallback.utf8.elementsEqual(expected.fallback.utf8) &&
                same(actual.title, expected.title) && same(actual.width, expected.width) && same(actual.height, expected.height) &&
                same(actual.scrolling, expected.scrolling) && same(actual.frameBorder, expected.frameBorder) &&
                same(actual.allowTransparency, expected.allowTransparency)
        case .media(let expected):
            guard element.tagName() == (expected.kind == .audio ? "audio" : "video") else { return false }
            let allowed: Set<String> = expected.kind == .video ? ["src", "controls", "width", "height"] : ["src", "controls"]
            guard (element.getAttributes()?.asList() ?? []).allSatisfy({ allowed.contains($0.getKey().lowercased()) }) else { return false }
            let width = element.hasAttr("width") ? try element.attr("width").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
            let height = element.hasAttr("height") ? try element.attr("height").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil
            guard width == expected.width, height == expected.height else { return false }
            var sources: [String] = []
            if element.hasAttr("src") { sources = [try element.attr("src")] }
            else {
                for child in element.children().array() where child.tagName() == "source" {
                    if isCancelled() { return false }
                    guard child.hasAttr("src") else { return false }
                    sources.append(try child.attr("src"))
                }
            }
            return sources.count == expected.sources.count &&
                zip(sources, expected.sources).allSatisfy({ $0.0.utf8.elementsEqual($0.1.utf8) })
        }
    }

    struct MediaProofCandidate {
        let openingNode: OpaquePointer
        let openingOffset: Int
        let closingNode: OpaquePointer
        let closingOffset: Int
        let expected: ProvenMedia
    }

    static func provenStandaloneMedia(root: OpaquePointer, mathExtension: OpaquePointer, options: Int32, text: NSString,
                                      candidates: [(node: OpaquePointer, media: StandaloneMedia)],
                                      isCancelled: () -> Bool) -> Set<Int> {
        guard !candidates.isEmpty, !isCancelled() else { return [] }
        var originals: [(OpaquePointer, String)] = [], nodes = Set<OpaquePointer>(), proof: [MediaProofCandidate] = []
        defer { for (node, literal) in originals { literal.withCString { _ = cmark_node_set_literal(node, $0) } } }
        for candidate in candidates {
            if isCancelled() { return [] }
            guard nodes.insert(candidate.node).inserted, let pointer = cmark_node_get_literal(candidate.node) else { return [] }
            let original = String(cString: pointer)
            guard let verified = standaloneMedia(original, isCancelled: isCancelled),
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
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
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
                guard try mediaElementMatches(element, expected: candidate.expected, isCancelled: isCancelled) else { continue }
                if let confirmedHTML { confirmedHTML(index, try element.outerHtml()) }
                accepted.insert(index)
            }
            return accepted
        } catch { return [] }
    }

    static func insertingMarkers(in literal: String, insertions: [(Int, String)], isCancelled: () -> Bool) -> String? {
        let raw = literal as NSString, output = NSMutableString()
        var cursor = 0, previous: Int?
        for (offset, marker) in insertions.sorted(by: { $0.0 < $1.0 }) {
            if isCancelled() { return nil }
            guard offset >= cursor, offset <= raw.length, previous != offset else { return nil }
            output.append(raw.substring(with: NSRange(location: cursor, length: offset - cursor)))
            output.append(marker)
            cursor = offset
            previous = offset
        }
        if isCancelled() { return nil }
        output.append(raw.substring(from: cursor))
        return output as String
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
            guard let changed = insertingMarkers(in: literal, insertions: entries.map { ($0.1, $0.2) }, isCancelled: isCancelled),
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

    struct RichDetails {
        let summary: String
        let summaryHTML: String
        let bodyHTML: String
        let initiallyOpen: Bool
    }

    static func richDetails(_ html: String, isCancelled: @escaping () -> Bool = { false }) -> RichDetails? {
        guard let editing = editingHTMLBlock(html, isCancelled: isCancelled), !isCancelled() else { return nil }
        do {
            let document = try SwiftSoup.parseBodyFragment(editing)
            document.outputSettings().prettyPrint(pretty: false)
            guard let details = document.body()?.children().first(), details.tagName() == "details" else { return nil }
            var summary: Element?, body: [Node] = []
            for child in details.getChildNodes() {
                if isCancelled() { return nil }
                if summary == nil {
                    if let text = child as? TextNode, text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    guard let element = child as? Element, element.tagName() == "summary" else { return nil }
                    summary = element
                } else { body.append(child) }
            }
            guard let summary else { return nil }
            var pending = summary.getChildNodes() + body
            while let node = pending.popLast() {
                if isCancelled() { return nil }
                if node is TextNode { continue }
                guard let element = node as? Element,
                      ["strong", "b", "em", "i", "span", "a", "br"].contains(element.tagName()) else { return nil }
                pending.append(contentsOf: element.getChildNodes())
            }
            let summaryHTML = try summary.getChildNodes().map { try $0.outerHtml() }.joined()
            let bodyHTML = try body.map { try $0.outerHtml() }.joined()
            return RichDetails(summary: try summary.text(), summaryHTML: "<div>\(summaryHTML)</div>",
                               bodyHTML: "<div>\(bodyHTML)</div>", initiallyOpen: details.hasAttr("open"))
        } catch { return nil }
    }

    static func plainDetails(_ html: String, isCancelled: () -> Bool = { false }) -> (summary: String, body: String)? {
        let raw = html.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let opening = "<details>" as NSString, summaryOpening = "<summary>" as NSString
        guard raw.length >= opening.length, raw.substring(with: NSRange(location: 0, length: opening.length)).lowercased() == opening as String else { return nil }
        var cursor = opening.length
        while cursor < raw.length && [9, 10, 12, 13, 32].contains(Int(raw.character(at: cursor))) {
            if isCancelled() { return nil }; cursor += 1
        }
        guard cursor + summaryOpening.length <= raw.length,
              raw.substring(with: NSRange(location: cursor, length: summaryOpening.length)).lowercased() == summaryOpening as String else { return nil }
        cursor += summaryOpening.length
        let summaryEnd = raw.range(of: "</summary>", options: .caseInsensitive, range: NSRange(location: cursor, length: raw.length - cursor))
        guard summaryEnd.location != NSNotFound else { return nil }
        let summary = raw.substring(with: NSRange(location: cursor, length: summaryEnd.location - cursor))
        cursor = NSMaxRange(summaryEnd)
        let bodyEnd = raw.range(of: "</details>", options: .caseInsensitive, range: NSRange(location: cursor, length: raw.length - cursor))
        guard bodyEnd.location != NSNotFound, NSMaxRange(bodyEnd) == raw.length else { return nil }
        let body = raw.substring(with: NSRange(location: cursor, length: bodyEnd.location - cursor))
        guard !summary.contains("<"), !body.contains("<"), !isCancelled() else { return nil }
        do {
            let doc = try SwiftSoup.parseBodyFragment(raw as String)
            guard let element = doc.body()?.children().first(), element.tagName() == "details",
                  doc.body()?.children().size() == 1, element.getAttributes()?.asList().isEmpty != false else { return nil }
            let children = element.getChildNodes()
            var foundSummary = false, summaryText = "", bodyText = ""
            for child in children {
                if isCancelled() { return nil }
                if let node = child as? TextNode {
                    if foundSummary { bodyText += node.getWholeText() }
                    else if !node.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                } else if let node = child as? Element, !foundSummary, node.tagName() == "summary",
                          node.getAttributes()?.asList().isEmpty != false,
                          node.getChildNodes().allSatisfy({ $0 is TextNode }) {
                    foundSummary = true
                    summaryText = node.getChildNodes().compactMap { ($0 as? TextNode)?.getWholeText() }.joined()
                } else { return nil }
            }
            guard foundSummary else { return nil }
            return (summaryText, bodyText)
        } catch { return nil }
    }

    static func detailsDisplayText(_ text: String, isCancelled: () -> Bool = { false }) -> String? {
        var output = String.UnicodeScalarView(), pendingSpace = false, pendingLine = false
        for scalar in text.unicodeScalars {
            if isCancelled() { return nil }
            if [9, 10, 12, 13, 32].contains(Int(scalar.value)) {
                pendingSpace = !output.isEmpty
                if !output.isEmpty && [10, 13].contains(Int(scalar.value)) { pendingLine = true }
            }
            else {
                if pendingLine { return nil }
                if pendingSpace { output.append(" ") }
                output.append(scalar); pendingSpace = false
            }
        }
        return String(output)
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
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
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

    static func rubyDisplayText(_ value: String, isCancelled: () -> Bool = { false }) -> String? {
        var result = String.UnicodeScalarView(), pendingSpace = false
        for scalar in value.unicodeScalars {
            if isCancelled() { return nil }
            if scalar.value == 32 { pendingSpace = !result.isEmpty; continue }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(scalar)
        }
        return isCancelled() ? nil : String(result)
    }

    static func rubyNeedsWhitespaceProjection(_ value: String, isCancelled: () -> Bool) -> Bool? {
        var previousSpace = false, first = true, repeated = false
        for unit in value.utf16 {
            if isCancelled() { return nil }
            let space = unit == 32
            if first && space { repeated = true }
            if previousSpace && space { repeated = true }
            first = false; previousSpace = space
        }
        return isCancelled() ? nil : (repeated || previousSpace)
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
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
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
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
            document.outputSettings().prettyPrint(pretty: false)
            var pending: [Node] = [document], seen = Set<String>(), duplicates = Set<String>(), accepted: [String: OpaquePointer] = [:]
            while let node = pending.popLast() {
                if isCancelled() { return [] }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment, let (original, summary, body) = names[comment.getData()] else { continue }
                let marker = comment.getData()
                if !seen.insert(marker).inserted { duplicates.insert(marker); continue }
                guard let details = comment.nextSibling() as? Element, details.tagName() == "details",
                      let serialized = try? details.outerHtml(), let actual = plainDetails(serialized, isCancelled: isCancelled),
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
        let widget: TwitterWidget
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
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
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
                  let verified = twitterWidget(String(cString: pointer), isCancelled: isCancelled),
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
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
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
                guard let actual = twitterWidget(markup, isCancelled: isCancelled),
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
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
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
                      isPageBreakStyle(actual, isCancelled: isCancelled) else { continue }
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
                                   candidates: [ImageProofCandidate], ancestors: [Int: [ImageAncestor]] = [:], isCancelled: () -> Bool) -> [Int: String] {
        guard !candidates.isEmpty, !isCancelled() else { return [:] }
        var markers: [String: Int] = [:], expected: [String: String] = [:], expectedAncestors: [String: [ImageAncestor]] = [:], insertions: [(OpaquePointer, Int, String)] = []
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
              !isCancelled(), let accepted = confirmedImageMarkers(in: rendered, expected: expected, ancestors: expectedAncestors, isCancelled: isCancelled),
              !isCancelled() else { return [:] }
        return Dictionary(uniqueKeysWithValues: accepted.compactMap { marker in markers[marker].map { ($0, marker) } })
    }

    static func confirmedImageMarkers(in html: String, expected: [String: String], ancestors: [String: [ImageAncestor]] = [:], isCancelled: () -> Bool) -> Set<String>? {
        guard !isCancelled() else { return nil }
        do {
            let document = try SwiftSoup.parse(html, "", Parser.htmlParser())
            guard !isCancelled() else { return nil }
            var pending: [Node] = [document], found: [String: Int] = [:], accepted: Set<String> = []
            while let node = pending.popLast() {
                if isCancelled() { return nil }
                pending.append(contentsOf: node.getChildNodes())
                guard let comment = node as? Comment else { continue }
                let marker = comment.getData()
                guard let source = expected[marker] else { continue }
                found[marker, default: 0] += 1
                guard let image = comment.nextSibling() as? Element, image.tagName() == "img",
                      image.hasAttr("src"), try image.attr("src").utf8.elementsEqual(source.utf8) else { continue }
                var ancestor = comment.parent(), inert = false
                while let current = ancestor {
                    if isCancelled() { return nil }
                    if let element = current as? Element, ["template", "script", "style"].contains(element.tagName()) { inert = true; break }
                    if let element = current as? Element, element.tagName() == "object" { inert = true; break }
                    ancestor = current.parent()
                }
                if !inert, let chain = ancestors[marker] {
                    var parent = image.parent(), matches = true
                    for expected in chain.reversed() {
                        if isCancelled() { return nil }
                        guard let element = parent, element.tagName().lowercased() == expected.name else { matches = false; break }
                        let attrs = element.getAttributes()?.asList() ?? []
                        if let style = expected.style {
                            guard attrs.count == 1, element.hasAttr("style"),
                                  let css = try? element.attr("style"), MarkdownInlineStyle(css: css) == style else { matches = false; break }
                        } else if !attrs.isEmpty { matches = false; break }
                        parent = element.parent()
                    }
                    if !matches { continue }
                }
                if !inert { accepted.insert(marker) }
            }
            return Set(accepted.filter { found[$0] == 1 })
        } catch { return nil }
    }

    // The caller confirms the complete tag and its position in the source.
    static func displayImage(in confirmedTag: String) -> DisplayImage? {
        do {
            let document = try SwiftSoup.parseBodyFragment(confirmedTag)
            guard let body = document.body(), body.children().size() == 1,
                  body.ownText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let image = body.children().first(), image.tagName() == "img", image.hasAttr("src") else { return nil }
            let source = try image.attr("src")
            guard !source.isEmpty else { return nil }
            return DisplayImage(source: source, alt: try image.attr("alt"),
                                title: image.hasAttr("title") ? try image.attr("title") : nil,
                                sizing: ImageSizing(width: image.hasAttr("width") ? try image.attr("width") : nil,
                                                    height: image.hasAttr("height") ? try image.attr("height") : nil,
                                                    style: image.hasAttr("style") ? try image.attr("style") : nil))
        } catch { return nil }
    }

    // Only a single, XML-compatible img with these attributes is emitted.
    static func image(in confirmedHTML: String) -> Image? {
        var source = confirmedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.lowercased().hasPrefix("<img"), source.hasSuffix(">"),
              !source.contains("\n"), !source.contains("\r") else { return nil }
        if !source.hasSuffix("/>") { source.removeLast(); source += "/>" }
        let delegate = ImageElementParser()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, let attributes = delegate.attributes,
              let address = attributes["src"], !address.isEmpty else { return nil }
        return Image(source: address, alt: attributes["alt"], title: attributes["title"], width: attributes["width"], height: attributes["height"])
    }

    private final class ImageElementParser: NSObject, XMLParserDelegate {
        var attributes: [String: String]?
        var valid = true
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard attributes == nil, elementName.lowercased() == "img",
                  Set(attributeDict.keys).isSubset(of: ["src", "alt", "title", "width", "height"]) else {
                valid = false; parser.abortParsing(); return
            }
            attributes = attributeDict
        }
        func parser(_ parser: XMLParser, foundComment comment: String) { valid = false; parser.abortParsing() }
    }

    // Processes consecutive Pandoc raw HTML nodes in document order. Source
    // script/style elements are omitted before the writer adds its template.
    struct SourceHTMLFilter {
        private var raw: String?
        private var scriptCommentSeen = false
        private var scriptDoubleEscaped = false
        var suppressesText: Bool { raw == "script" || raw == "style" }

        private mutating func advanceScriptContext(_ source: NSString, range: NSRange, isCancelled: () -> Bool) {
            var cursor = range.location
            let end = NSMaxRange(range)
            func space(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
            while cursor < end {
                if isCancelled() { return }
                func matches(_ text: String) -> Bool {
                    let length = (text as NSString).length
                    guard length <= end - cursor else { return false }
                    return source.compare(text, options: .caseInsensitive, range: NSRange(location: cursor, length: length)) == .orderedSame
                }
                if matches("<!--") {
                    scriptCommentSeen = true
                    cursor += 4
                } else if matches("-->") {
                    scriptCommentSeen = false
                    scriptDoubleEscaped = false
                    cursor += 3
                } else if scriptCommentSeen && matches("<script"), cursor + 7 < source.length,
                          (space(source.character(at: cursor + 7)) || source.character(at: cursor + 7) == 47 || source.character(at: cursor + 7) == 62) {
                    scriptDoubleEscaped = true
                    cursor += 7
                } else { cursor += 1 }
            }
        }

        mutating func filter(_ html: String, isCancelled: () -> Bool = { false }) -> String {
            let source = html as NSString
            var result = "", cursor = 0
            func space(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
            while cursor < source.length {
                if isCancelled() { return result }
                if let context = raw {
                    let suppress = suppressesText
                    let found = source.range(of: "</" + context, options: .caseInsensitive,
                                             range: NSRange(location: cursor, length: source.length - cursor))
                    if found.location == NSNotFound {
                        if !suppress { result += source.substring(from: cursor) }
                        if context == "script" { advanceScriptContext(source, range: NSRange(location: cursor, length: source.length - cursor), isCancelled: isCancelled) }
                        break
                    }
                    if context == "script" { advanceScriptContext(source, range: NSRange(location: cursor, length: found.location - cursor), isCancelled: isCancelled) }
                    let after = NSMaxRange(found)
                    if after < source.length && (space(source.character(at: after)) || source.character(at: after) == 62 || source.character(at: after) == 47) {
                        let close = source.range(of: ">", options: [], range: NSRange(location: after, length: source.length - after)).location
                        if close != NSNotFound {
                            if context == "script" && scriptDoubleEscaped {
                                scriptDoubleEscaped = false; cursor = close + 1; continue
                            }
                            if !suppress { result += source.substring(with: NSRange(location: cursor, length: close + 1 - cursor)) }
                            cursor = close + 1; raw = nil; scriptCommentSeen = false; scriptDoubleEscaped = false
                            continue
                        }
                        if !suppress { result += source.substring(from: cursor) }
                        break
                    }
                    if !suppress { result += source.substring(with: NSRange(location: cursor, length: after - cursor)) }
                    cursor = after
                    continue
                }
                let found = source.range(of: "<", options: [], range: NSRange(location: cursor, length: source.length - cursor))
                if found.location == NSNotFound { result += source.substring(from: cursor); break }
                result += source.substring(with: NSRange(location: cursor, length: found.location - cursor))
                cursor = found.location
                if source.length - cursor >= 4 && source.substring(with: NSRange(location: cursor, length: 4)) == "<!--" {
                    let rest = NSRange(location: cursor + 4, length: source.length - cursor - 4)
                    let ends = ["-->", "--!>"].map { source.range(of: $0, options: [], range: rest) }.filter { $0.location != NSNotFound }
                    let end: Int
                    if rest.length > 0 && source.character(at: rest.location) == 62 { end = rest.location + 1 }
                    else if rest.length > 1 && source.character(at: rest.location) == 45 && source.character(at: rest.location + 1) == 62 { end = rest.location + 2 }
                    else { end = ends.min(by: { $0.location < $1.location }).map(NSMaxRange) ?? source.length }
                    result += source.substring(with: NSRange(location: cursor, length: end - cursor)); cursor = end; continue
                }
                var end = cursor + 1
                if end < source.length && source.character(at: end) == 47 { end += 1 }
                let nameStart = end
                while end < source.length && !space(source.character(at: end)) && source.character(at: end) != 47 && source.character(at: end) != 62 { end += 1 }
                let name = source.substring(with: NSRange(location: nameStart, length: end - nameStart)).lowercased()
                let closing = nameStart > cursor + 1
                var quote: UInt16?
                while end < source.length {
                    let c = source.character(at: end)
                    if let delimiter = quote { if c == delimiter { quote = nil } }
                    else if c == 34 || c == 39 { quote = c }
                    else if c == 62 { break }
                    end += 1
                }
                guard end < source.length else { result += source.substring(from: cursor); break }
                end += 1
                let rawNames = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"]
                if !closing && rawNames.contains(name) { raw = name; scriptCommentSeen = false; scriptDoubleEscaped = false }
                if !suppressesText { result += source.substring(with: NSRange(location: cursor, length: end - cursor)) }
                cursor = end
            }
            return result
        }
    }

    static func exportFragments(options: MarkdownHTMLExportOptions, variables: [String: String]) -> (head: String, body: String) {
        func value(_ key: String, fallback: String) -> String {
            guard options.allowDocumentOverrides else { return fallback }
            return variables["typora-" + key] ?? variables[key] ?? fallback
        }
        func extra(_ key: String) -> String {
            guard options.allowDocumentOverrides else { return "" }
            return variables["typora-" + key] ?? variables[key] ?? ""
        }
        let head = value("append-head", fallback: options.appendHead) + extra("append-head-extra")
        let body = value("append-body", fallback: options.appendBody) + extra("append-body-extra")
        return (substituteMetaVariables(in: head, variables: variables), substituteMetaVariables(in: body, variables: variables))
    }

    // User-supplied export HTML is never inserted into the live preview. Only
    // attribute values of actual meta tags receive escaped variable values.
    static func substituteMetaVariables(in html: String, variables: [String: String]) -> String {
        let source = html as NSString
        let pattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_.-]*)\}"#)
        func space(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }
        func escaped(_ value: String, unquoted: Bool) -> String {
            var result = ""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 38: result += "&amp;"
                case 60: result += "&lt;"
                case 62: result += "&gt;"
                case 34: result += "&quot;"
                case 39: result += "&#39;"
                case 9, 10, 12, 13, 32, 61, 96:
                    if unquoted { result += "&#\(scalar.value);" }
                    else { result.unicodeScalars.append(scalar) }
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result
        }
        var edits: [(NSRange, String)] = []
        var cursor = 0, raw: String?, scriptCommentSeen = false
        while cursor < source.length {
            if let context = raw {
                let needle = "</" + context
                let found = source.range(of: needle, options: .caseInsensitive, range: NSRange(location: cursor, length: source.length - cursor))
                if found.location == NSNotFound { break }
                if context == "script" {
                    var searchStart = cursor
                    if !scriptCommentSeen {
                        let comment = source.range(of: "<!--", options: [], range: NSRange(location: cursor, length: found.location - cursor))
                        if comment.location != NSNotFound { scriptCommentSeen = true; searchStart = NSMaxRange(comment) }
                    }
                    if scriptCommentSeen {
                        let nested = source.range(of: "<script", options: .caseInsensitive,
                                                  range: NSRange(location: searchStart, length: found.location - searchStart))
                        if nested.location != NSNotFound { break }
                    }
                }
                let after = NSMaxRange(found)
                if after < source.length && (space(source.character(at: after)) || source.character(at: after) == 62 || source.character(at: after) == 47) {
                    raw = nil; cursor = found.location
                } else { cursor = after }
                continue
            }
            let found = source.range(of: "<", options: [], range: NSRange(location: cursor, length: source.length - cursor))
            if found.location == NSNotFound { break }
            cursor = found.location
            if source.length - cursor >= 4 && source.substring(with: NSRange(location: cursor, length: 4)) == "<!--" {
                let rest = NSRange(location: cursor + 4, length: source.length - cursor - 4)
                if rest.length > 0 && source.character(at: rest.location) == 62 { cursor = rest.location + 1; continue }
                if rest.length > 1 && source.character(at: rest.location) == 45 && source.character(at: rest.location + 1) == 62 {
                    cursor = rest.location + 2; continue
                }
                let endings = ["-->", "--!>"].map { source.range(of: $0, options: [], range: rest) }.filter { $0.location != NSNotFound }
                cursor = endings.min(by: { $0.location < $1.location }).map(NSMaxRange) ?? source.length
                continue
            }
            var position = cursor + 1, closing = false
            if position < source.length && source.character(at: position) == 47 { closing = true; position += 1 }
            let start = position
            while position < source.length {
                let c = source.character(at: position)
                if space(c) || c == 47 || c == 62 { break }
                position += 1
            }
            guard position > start else { cursor += 1; continue }
            let name = source.substring(with: NSRange(location: start, length: position - start)).lowercased()
            let attributesStart = position
            var quote: UInt16?
            while position < source.length {
                let c = source.character(at: position)
                if let q = quote { if c == q { quote = nil } }
                else if c == 34 || c == 39 { quote = c }
                else if c == 62 { break }
                position += 1
            }
            guard position < source.length else { break }
            let end = position
            cursor = end + 1
            if !closing && ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"].contains(name) {
                if name == "plaintext" { break }
                raw = name
                scriptCommentSeen = false
            }
            guard !closing, name == "meta" else { continue }
            position = attributesStart
            while position < end {
                while position < end && (space(source.character(at: position)) || source.character(at: position) == 47) { position += 1 }
                let attributeStart = position
                while position < end && !space(source.character(at: position)) && ![UInt16(61), 47, 62].contains(source.character(at: position)) { position += 1 }
                guard position > attributeStart else { break }
                while position < end && space(source.character(at: position)) { position += 1 }
                guard position < end, source.character(at: position) == 61 else { continue }
                position += 1
                while position < end && space(source.character(at: position)) { position += 1 }
                guard position < end else { break }
                let delimiter = source.character(at: position)
                let quoted = delimiter == 34 || delimiter == 39
                if quoted { position += 1 }
                let valueStart = position
                while position < end {
                    let c = source.character(at: position)
                    if quoted ? c == delimiter : space(c) { break }
                    position += 1
                }
                let valueRange = NSRange(location: valueStart, length: position - valueStart)
                for match in pattern.matches(in: html, range: valueRange) {
                    let key = source.substring(with: match.range(at: 1))
                    if let value = variables[key] { edits.append((match.range, escaped(value, unquoted: !quoted))) }
                }
                if quoted && position < end { position += 1 }
            }
        }
        let result = NSMutableString(string: html)
        for (range, value) in edits.reversed() { result.replaceCharacters(in: range, with: value) }
        return result as String
    }

    private final class AudioElementParser: NSObject, XMLParserDelegate {
        let name: String
        var source: String?
        var isValid = true
        init(name: String) { self.name = name }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            guard source == nil, elementName.lowercased() == name, attributeDict.count == 1,
                  let value = attributeDict["src"], !value.isEmpty else {
                isValid = false
                parser.abortParsing()
                return
            }
            source = value
        }

        func parser(_ parser: XMLParser, foundComment comment: String) {
            isValid = false
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isValid = false
                parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            isValid = false
            parser.abortParsing()
        }
    }
}
