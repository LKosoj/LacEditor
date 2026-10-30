import Foundation
import Darwin
import Yams
import SwiftSoup

enum PandocExportFormat: String, CaseIterable, Identifiable {
    case html, htmlPlain, docx, odt, rtf, epub, fb2, latex, text, pdf, mediawiki, rst, textile, opml

    var id: String { rawValue }
    var title: String {
        switch self {
        case .latex: "LaTeX"
        case .htmlPlain: L10n.tr("HTML（无样式）")
        case .text: "TXT"
        case .mediawiki: "MediaWiki"
        case .textile: "Textile"
        default: rawValue.uppercased()
        }
    }
    var fileExtension: String {
        switch self {
        case .latex: "tex"
        case .htmlPlain: "html"
        case .text: "txt"
        case .mediawiki: "wiki"
        default: rawValue
        }
    }
    var writer: String {
        switch self {
        case .latex, .pdf: "latex"
        case .htmlPlain: "html5"
        case .text: "plain"
        default: rawValue
        }
    }
}

enum PandocExportError: LocalizedError {
    case missingPandoc
    case conversionFailed(String)
    case openDocument
    case invalidConfiguration(String)
    case incompleteLatexAssets(String, String)

    var errorDescription: String? {
        switch self {
        case .missingPandoc:
            L10n.tr("找不到内置 Pandoc。请重新安装 LacEditor。")
        case let .conversionFailed(details):
            L10n.tr("Pandoc 导出失败：%@", details)
        case .openDocument:
            L10n.tr("不能覆盖在 LacEditor 中打开的文件或原始文件。")
        case let .invalidConfiguration(details):
            L10n.tr("导出设置无效：%@", details)
        case let .incompleteLatexAssets(path, reason):
            L10n.tr("导出失败：%@。请检查资源目录：%@", reason, path)
        }
    }
}

struct PandocExportResult {
    struct LatexAssets {
        let directoryName: String
        let files: [(name: String, bytes: Data)]
    }
    let preparedURL: URL
    let diagnostics: String
    var latexAssets: LatexAssets? = nil
}

enum PandocExportService {
    private static func stageLatexImages(in tree: inout [String: Any], destination: URL, temporary: URL,
                                         isCancelled: () -> Bool) throws -> PandocExportResult.LatexAssets? {
        guard var blocks = tree["blocks"] as? [Any] else { throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效")) }
        let manager = FileManager.default
        let staged = temporary.appendingPathComponent("latex-assets", isDirectory: true)
        var directoryName: String?, files: [(name: String, bytes: Data)] = []
        func chooseDirectoryName() throws -> String {
            let base = destination.deletingPathExtension().lastPathComponent + "_files"
            var index = 0
            while true {
                if isCancelled() { throw CancellationError() }
                let name = index == 0 ? base : base + "-\(index)"
                let url = destination.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
                var info = stat()
                if lstat(url.path, &info) != 0 {
                    guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    return name
                }
                index += 1
            }
        }
        func visit(_ value: Any) throws -> Any {
            if isCancelled() { throw CancellationError() }
            if var node = value as? [String: Any] {
                if node["t"] as? String == "Image", var content = node["c"] as? [Any], content.count == 3,
                   var target = content[2] as? [String], target.count == 2,
                   target[0].prefix("data:image/png;base64,".count).lowercased() == "data:image/png;base64,",
                   MarkdownImageUploadService.fragmentSuffix(target[0]).isEmpty,
                   let payload = try? MarkdownImageUploadService.payload(address: target[0], document: nil), payload.mime == "image/png" {
                    if directoryName == nil {
                        directoryName = try chooseDirectoryName()
                        try manager.createDirectory(at: staged, withIntermediateDirectories: false)
                    }
                    guard let directoryName else { throw CocoaError(.fileWriteUnknown) }
                    let name = "image-\(files.count + 1).png"
                    try payload.data.write(to: staged.appendingPathComponent(name), options: .withoutOverwriting)
                    if isCancelled() { throw CancellationError() }
                    files.append((name, payload.data))
                    target[0] = directoryName + "/" + name
                    content[2] = target
                    node["c"] = content
                }
                for (key, child) in node { node[key] = try visit(child) }
                return node
            }
            if let values = value as? [Any] { return try values.map { try visit($0) } }
            return value
        }
        blocks = try blocks.map { try visit($0) }
        tree["blocks"] = blocks
        guard let directoryName else { return nil }
        return PandocExportResult.LatexAssets(directoryName: directoryName, files: files)
    }

    struct MathMarker {
        let token: String
        let source: String
        let display: Bool
        var preservesSpaces = false
    }

    static func markedExportSnapshot(_ text: String, syntax: MarkdownSyntaxOptions, includeTOC: Bool, wiki: MarkdownWikiLinkSource? = nil,
                                     isCancelled: @escaping () -> Bool) throws -> (text: String, math: [MathMarker], toc: [String]) {
        let presentation = MarkdownPresentationParser.parse(text, includeEmojiCandidates: true, includeWikiLinks: wiki != nil, syntax: syntax, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        let values = try EmojiShortcodeResolver.resolve(presentation.emojiCandidates.map(\.name), isCancelled: isCancelled)
        var replacements: [(NSRange, String)] = presentation.emojiCandidates.compactMap { candidate in
            values[candidate.name].map { (candidate.range, $0) }
        }
        if let wiki, !presentation.wikiLinks.isEmpty {
            // Список файлов читается с диска заново; ссылки, пересекающиеся с эмодзи или формулой, остаются текстом.
            let context = try MarkdownWikiLinkContext.load(root: wiki.root, documentURL: wiki.documentURL, isCancelled: isCancelled)
            let others = replacements.map(\.0) + (presentation.inlineFormulas.map(\.range) + presentation.formulas.map(\.range))
            let links = presentation.wikiLinks.filter { link in !others.contains { NSIntersectionRange($0, link.range).length > 0 } }
            replacements.append(contentsOf: MarkdownWikiLinkRewriter.replacements(links: links, context: context, in: text as NSString, isCancelled: isCancelled))
        }
        let ranges = includeTOC ? presentation.tableOfContents : []
        var prefix: String
        repeat { prefix = "LACEDITORTOC" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        while text.contains(prefix)
        let markers = ranges.indices.map { prefix + "X\($0)" }
        let raw = text as NSString
        if !syntax.strictMode {
            for span in presentation.spans {
                if isCancelled() { throw CancellationError() }
                guard case .heading = span.kind, let marker = span.markerRanges.first,
                      marker.length > 0, marker.location >= 0, marker.location <= raw.length,
                      marker.length < raw.length - marker.location else { continue }
                let hashes = raw.substring(with: marker)
                guard hashes.utf16.allSatisfy({ $0 == 35 }),
                      ![9, 10, 13, 32].contains(Int(raw.character(at: NSMaxRange(marker)))) else { continue }
                replacements.append((marker, hashes + " "))
            }
            for indent in presentation.looseIndents {
                if isCancelled() { throw CancellationError() }
                let range = indent.range
                guard range.location >= 0, range.location <= raw.length, range.length > 0,
                      range.length <= raw.length - range.location,
                      raw.substring(with: range).utf16.allSatisfy({ $0 == 32 }),
                      indent.replacement.utf16.allSatisfy({ $0 == 32 }),
                      indent.replacement.utf16.count > range.length else {
                    throw PandocExportError.invalidConfiguration(L10n.tr("无法确认列表缩进"))
                }
                replacements.append((range, indent.replacement))
            }
        }
        for index in ranges.indices {
            if isCancelled() { throw CancellationError() }
            let range = ranges[index]
            guard range.location >= 0, range.location <= raw.length, range.length <= raw.length - range.location,
                  raw.substring(with: range) == "[toc]" else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认目录标记")) }
            replacements.append((range, markers[index]))
        }
        let result = try markedMathSnapshot(text, presentation: presentation, additionalReplacements: replacements,
                                            preserveWhitespace: syntax.preserveExportWhitespace, isCancelled: isCancelled)
        return (result.0, result.1, markers)
    }

    static func originalMathMetadata(_ text: String, executable: URL, source: URL?, temporary: URL,
                                     environment: [String: String] = [:], isCancelled: () -> Bool) throws -> [String: Any]? {
        guard let frontMatter = MarkdownPresentationParser.frontMatter(text) else { return nil }
        let yaml = (text as NSString).substring(with: frontMatter.range)
        guard yaml.contains("$") else { return nil }
        if isCancelled() { throw CancellationError() }
        let input = temporary.appendingPathComponent("metadata-math.md")
        let output = temporary.appendingPathComponent("metadata-math.json")
        let log = temporary.appendingPathComponent("metadata-math.stderr")
        try Data((yaml + "\n").utf8).write(to: input, options: .atomic)
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stderr.close() }
        let arguments = [executable.path, "--from=gfm+yaml_metadata_block", "--to=json", "--output", output.path, "--", input.path]
        let status = try CustomMarkdownExportService.runPandocGroup(executable, arguments: arguments,
            directory: source?.deletingLastPathComponent() ?? temporary, stderr: stderr, isCancelled: isCancelled,
            additionalEnvironment: environment)
        if isCancelled() { throw CancellationError() }
        guard status == 0, let tree = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any],
              let metadata = tree["meta"] as? [String: Any] else { throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效")) }
        return metadata
    }

    static func markedMathSnapshot(_ text: String, presentation: MarkdownPresentation,
                                   additionalReplacements: [(NSRange, String)] = [],
                                   preserveWhitespace: Bool = false,
                                   isCancelled: () -> Bool) throws -> (String, [MathMarker]) {
        let raw = text as NSString
        var prefix: String
        repeat { prefix = "LACMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "X" }
        while text.contains(prefix)
        let formulas = (presentation.inlineFormulas.map { ($0, false) } + presentation.formulas.map { ($0, true) })
            .sorted { $0.0.range.location < $1.0.range.location }
        var previousEnd = 0, markers: [MathMarker] = []
        for (index, entry) in formulas.enumerated() {
            if isCancelled() { throw CancellationError() }
            let range = entry.0.range
            guard range.location >= previousEnd, range.length > 0, range.location <= raw.length,
                  range.length <= raw.length - range.location else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
            previousEnd = NSMaxRange(range)
            markers.append(MathMarker(token: prefix + String(index) + "Z", source: entry.0.source, display: entry.1))
        }
        var replacements = formulas.indices.map { (formulas[$0].0.range, markers[$0].token) } + additionalReplacements
        if preserveWhitespace {
            for range in presentation.emojiCompletionRanges {
                if isCancelled() { throw CancellationError() }
                guard range.location >= 0, range.location <= raw.length, range.length <= raw.length - range.location else {
                    throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式"))
                }
                var position = range.location
                while position < NSMaxRange(range) {
                    if isCancelled() { throw CancellationError() }
                    guard raw.character(at: position) == 32 else { position += 1; continue }
                    let start = position
                    while position < NSMaxRange(range), raw.character(at: position) == 32 {
                        if isCancelled() { throw CancellationError() }
                        position += 1
                    }
                    guard position - start > 1 else { continue }
                    let token = prefix + String(markers.count) + "Z"
                    let spaces = NSRange(location: start, length: position - start)
                    markers.append(MathMarker(token: token, source: raw.substring(with: spaces), display: false, preservesSpaces: true))
                    replacements.append((spaces, token))
                }
            }
        }
        replacements = replacements
            .sorted { $0.0.location < $1.0.location }
        previousEnd = 0
        for (range, _) in replacements {
            guard range.location >= previousEnd, range.length > 0, range.location <= raw.length,
                  range.length <= raw.length - range.location else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
            previousEnd = NSMaxRange(range)
        }
        let result = NSMutableString(string: text)
        for (range, replacement) in replacements.reversed() {
            if isCancelled() { throw CancellationError() }
            result.replaceCharacters(in: range, with: replacement)
        }
        return (result as String, markers)
    }

    static func restoreMath(in tree: [String: Any], markers: [MathMarker], latexWhitespace: Bool = false, isCancelled: () -> Bool) throws -> [String: Any] {
        guard !markers.isEmpty else { return tree }
        let byToken = Dictionary(uniqueKeysWithValues: markers.map { ($0.token, $0) })
        var remaining = Set(byToken.keys)
        let prefix = String(markers[0].token.dropLast(2))
        func containsMarker(_ value: String) -> Bool { value.contains(prefix) }
        func transform(_ value: Any) throws -> Any {
            if isCancelled() { throw CancellationError() }
            if let array = value as? [Any] {
                var output: [Any] = []
                for element in array {
                    if let node = element as? [String: Any], node["t"] as? String == "Str", let text = node["c"] as? String {
                        let raw = text as NSString
                        var cursor = 0
                        while cursor < raw.length {
                            if isCancelled() { throw CancellationError() }
                            let search = NSRange(location: cursor, length: raw.length - cursor)
                            let start = raw.range(of: prefix, options: .literal, range: search)
                            guard start.location != NSNotFound else { break }
                            var end = NSMaxRange(start)
                            while end < raw.length, (48...57).contains(raw.character(at: end)) {
                                if isCancelled() { throw CancellationError() }
                                end += 1
                            }
                            guard end < raw.length, raw.character(at: end) == 90 else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
                            let range = NSRange(location: start.location, length: end + 1 - start.location)
                            guard let marker = byToken[raw.substring(with: range)] else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
                            guard remaining.remove(marker.token) != nil else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
                            if range.location > cursor { output.append(["t": "Str", "c": raw.substring(with: NSRange(location: cursor, length: range.location - cursor))]) }
                            if marker.preservesSpaces {
                                if latexWhitespace {
                                    output.append(["t": "RawInline", "c": ["latex", String(repeating: "\\ ", count: marker.source.utf16.count)]])
                                } else {
                                    output.append(["t": "Span", "c": [["", [], [["style", "white-space: break-spaces;"]]], [["t": "Str", "c": marker.source]]]])
                                }
                            } else {
                                output.append(["t": "Math", "c": [["t": marker.display ? "DisplayMath" : "InlineMath"], marker.source]])
                            }
                            cursor = NSMaxRange(range)
                        }
                        if cursor < raw.length { output.append(["t": "Str", "c": raw.substring(from: cursor)]) }
                    } else { output.append(try transform(element)) }
                }
                return output
            }
            if let object = value as? [String: Any] {
                var output: [String: Any] = [:]
                for (key, item) in object { output[key] = try transform(item) }
                return output
            }
            if let value = value as? String, containsMarker(value) { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
            return value
        }
        guard let metadata = tree["meta"], let blocks = tree["blocks"] else { throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效")) }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.fragmentsAllowed])
        guard !containsMarker(String(decoding: metadataData, as: UTF8.self)) else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
        let result = try transform(blocks)
        guard remaining.isEmpty else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认数学公式")) }
        var output = tree
        output["blocks"] = result
        return output
    }
    private struct MediaFragment {
        let marker: String
        let name: String
        let fragment: String?
    }

    private static func markMediaFragments(_ text: String, isCancelled: @escaping () -> Bool) throws -> (String, [MediaFragment]) {
        let sources = try MarkdownImageUploadService.mediaSources(in: text, isCancelled: isCancelled)
        let raw = text as NSString, output = NSMutableString(string: text)
        let hasRoot = (try? yamlFrontMatter(text))?.contains(where: { $0.key.scalar?.string == "typora-root-url" }) == true
        var markers: [MediaFragment] = []
        for image in sources.reversed() {
            if isCancelled() { throw CancellationError() }
            let tag = raw.substring(with: image.range).lowercased()
            guard let name = ["audio", "video", "source"].first(where: { tag.hasPrefix("<" + $0) }) else {
                throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容"))
            }
            let fragment = URLComponents(string: image.address)?.percentEncodedFragment
            guard fragment != nil || (name == "source" && hasRoot && MarkdownResourcePaths.requiresRoot(image.address)) else { continue }
            var marker: String
            repeat { marker = "data-lac-media-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
            while text.localizedCaseInsensitiveContains(marker)
            output.insert(" \(marker)=\"1\"", at: image.range.location + 1 + (name as NSString).length)
            markers.append(MediaFragment(marker: marker, name: name, fragment: fragment))
        }
        return (output as String, markers)
    }

    private static func restoreMediaFragments(in output: URL, markers: [MediaFragment], isCancelled: @escaping () -> Bool) throws {
        guard !markers.isEmpty else { return }
        let html = try String(contentsOf: output, encoding: .utf8), document = try SwiftSoup.parseHTML(html)
        let names = Dictionary(uniqueKeysWithValues: markers.map { ($0.marker, $0) })
        var confirmed: Set<String> = [], nodes: [(SwiftSoup.Node, Element?, Bool)] = [(document, nil, false)]
        while let (node, parent, forbidden) = nodes.popLast() {
            if isCancelled() { throw CancellationError() }
            let element = node as? Element, name = element?.tagName().lowercased()
            let blocked = forbidden || ["template", "script", "style"].contains(name ?? "")
            if let element {
                for attribute in element.getAttributes()?.asList() ?? [] {
                    let key = attribute.getKey().lowercased()
                    if let marker = names[key] {
                        guard !blocked, name == marker.name, element.hasAttr("src"), confirmed.insert(key).inserted else {
                            throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容"))
                        }
                        if name == "source" {
                            guard let parent, ["audio", "video"].contains(parent.tagName().lowercased()), !parent.hasAttr("src") else {
                                throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容"))
                            }
                        }
                    }
                }
            }
            for child in node.getChildNodes() { nodes.append((child, element ?? parent, blocked)) }
        }
        guard confirmed.count == markers.count else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容")) }
        let raw = html as NSString
        var counts: [String: Int] = [:], cursor = 0
        while cursor < raw.length {
            if isCancelled() { throw CancellationError() }
            let match = raw.range(of: "data-lac-media-", options: [], range: NSRange(location: cursor, length: raw.length - cursor))
            guard match.location != NSNotFound else { break }
            var end = NSMaxRange(match)
            while end < raw.length {
                if isCancelled() { throw CancellationError() }
                let c = raw.character(at: end)
                if !(48...57).contains(c) && !(97...122).contains(c) && c != 45 { break }
                end += 1
            }
            let key = raw.substring(with: NSRange(location: match.location, length: end - match.location))
            if names[key] != nil { counts[key, default: 0] += 1 }
            cursor = end
        }
        guard markers.allSatisfy({ counts[$0.marker] == 1 }) else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容")) }
        var context = MarkdownImageUploadService.HTMLContext(), edits: [(NSRange, String)] = [], matched: Set<String> = []
        _ = context.consume(source: raw, range: NSRange(location: 0, length: raw.length), isCancelled: isCancelled, confirmedTag: { tag, name, closing in
            guard !closing else { return }
            var cursor = tag.location
            while cursor < NSMaxRange(tag) {
                let position = raw.range(of: " data-lac-media-", options: [], range: NSRange(location: cursor, length: NSMaxRange(tag) - cursor))
                guard position.location != NSNotFound else { break }
                var end = NSMaxRange(position)
                while end < NSMaxRange(tag) {
                    if isCancelled() { return }
                    let c = raw.character(at: end)
                    if !(48...57).contains(c) && !(97...122).contains(c) && c != 45 { break }
                    end += 1
                }
                cursor = end
                let key = raw.substring(with: NSRange(location: position.location + 1, length: end - position.location - 1))
                guard let marker = names[key], marker.name == name else { continue }
                let token = " " + marker.marker + "=\"1\""
                guard position.location + (token as NSString).length <= NSMaxRange(tag),
                      raw.substring(with: NSRange(location: position.location, length: (token as NSString).length)) == token,
                      let image = MarkdownImageUploadService.mediaSource(in: raw, range: tag, name: name, isCancelled: isCancelled) else { continue }
                let fragment = URLComponents(string: image.address)?.percentEncodedFragment
                if let expected = marker.fragment, let fragment, !fragment.utf8.elementsEqual(expected.utf8) { continue }
                guard matched.insert(marker.marker).inserted else { continue }
                edits.append((NSRange(location: position.location, length: (token as NSString).length), ""))
                if fragment == nil, let original = marker.fragment {
                    let escaped = original.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
                    edits.append((NSRange(location: NSMaxRange(image.addressRange), length: 0), "#" + escaped))
                }
            }
        })
        guard !isCancelled() else { throw CancellationError() }
        guard matched.count == markers.count, edits.count >= markers.count else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容")) }
        let result = NSMutableString(string: html)
        for (range, value) in edits.sorted(by: { $0.0.location > $1.0.location }) { result.replaceCharacters(in: range, with: value) }
        try (result as String).write(to: output, atomically: true, encoding: .utf8)
    }

    private static func protectTextareas(_ text: String, isCancelled: () -> Bool) throws -> (String, [(String, String)]) {
        let ranges = try MarkdownImageUploadService.textareaContents(in: text, isCancelled: isCancelled)
        let source = text as NSString, result = NSMutableString(string: text)
        var values: [(String, String)] = []
        for range in ranges.reversed() {
            if isCancelled() { throw CancellationError() }
            var marker: String
            repeat { marker = "LACEDITORTEXTAREA" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
            while text.contains(marker)
            values.append((marker, source.substring(with: range)))
            result.replaceCharacters(in: range, with: marker)
        }
        return (result as String, values)
    }

    private static func restoreTextareas(in output: URL, values: [(String, String)], isCancelled: () -> Bool) throws {
        guard !values.isEmpty else { return }
        var html = try String(contentsOf: output, encoding: .utf8)
        let document = try SwiftSoup.parseHTML(html)
        let markers = Set(values.map(\.0))
        var confirmed: Set<String> = []
        var nodes: [(SwiftSoup.Node, Bool, Bool)] = [(document, false, false)]
        while let (node, inTextarea, forbidden) = nodes.popLast() {
            if isCancelled() { throw CancellationError() }
            let name = (node as? Element)?.tagName().lowercased()
            let blocked = forbidden || name == "template" || name == "script"
            if inTextarea && !blocked {
                let value = (node as? TextNode)?.getWholeText() ?? (node as? DataNode)?.getWholeData()
                if let value, markers.contains(value) { confirmed.insert(value) }
            }
            for child in node.getChildNodes() {
                nodes.append((child, name == "textarea", blocked))
            }
        }
        guard confirmed == markers else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容")) }
        for (marker, value) in values {
            if isCancelled() { throw CancellationError() }
            guard let range = html.range(of: marker), html.range(of: marker, range: range.upperBound..<html.endIndex) == nil else {
                throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容"))
            }
            html.replaceSubrange(range, with: value)
        }
        try html.write(to: output, atomically: true, encoding: .utf8)
    }

    private static func mayNeedResourceRoot(_ text: String, isCancelled: @escaping () -> Bool) throws -> Bool {
        var yamlError: Error?
        do {
            guard try yamlFrontMatter(text)?.contains(where: { $0.key.scalar?.string == "typora-root-url" }) == true else { return false }
        } catch { yamlError = error }
        let needsRoot: Bool
        do {
            needsRoot = try MarkdownImageUploadService.images(in: text, allowSharedReference: true, isCancelled: isCancelled)
                .contains { MarkdownResourcePaths.requiresRoot($0.address) }
        } catch is CancellationError { throw CancellationError() }
        catch { return yamlError == nil }
        if needsRoot, let yamlError { throw yamlError }
        return needsRoot
    }

    static func resolveRootImages(in tree: [String: Any], text: String, document: URL?,
                                  isCancelled: () -> Bool = { false }) throws -> [String: Any] {
        var paths: MarkdownResourcePaths?
        var loaded = false
        func visit(_ value: Any) throws -> Any {
            if isCancelled() { throw CancellationError() }
            if var object = value as? [String: Any] {
                if object["t"] as? String == "Image", var parts = object["c"] as? [Any], parts.count == 3,
                   var target = parts[2] as? [String], target.count == 2, MarkdownResourcePaths.requiresRoot(target[0]) {
                    if !loaded { paths = try MarkdownResourcePaths(text: text, document: document); loaded = true }
                    if let paths, paths.root != nil {
                        guard let url = paths.resolve(target[0]), url.isFileURL else { throw MarkdownResourcePaths.PathError.invalidRoot }
                        target[0] = url.absoluteString
                        parts[2] = target
                        object["c"] = parts
                    }
                }
                for (key, child) in object { object[key] = try visit(child) }
                return object
            }
            if let array = value as? [Any] { return try array.map { try visit($0) } }
            return value
        }
        guard let result = try visit(tree) as? [String: Any] else { throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效")) }
        return result
    }

    static func rootImageSnapshot(_ text: String, document: URL?, isCancelled: @escaping () -> Bool) throws -> String {
        guard try mayNeedResourceRoot(text, isCancelled: isCancelled) else { return text }
        let paths = try MarkdownResourcePaths(text: text, document: document)
        guard paths.root != nil else { return text }
        let images = try MarkdownImageUploadService.images(in: text, allowSharedReference: true, isCancelled: isCancelled)
            .filter { MarkdownResourcePaths.requiresRoot($0.address) }
        guard !images.isEmpty else { return text }
        let urls = try images.map { image -> URL in
            guard !isCancelled() else { throw CancellationError() }
            guard let url = paths.resolve(image.address), url.isFileURL else { throw MarkdownResourcePaths.PathError.invalidRoot }
            return url
        }
        let raw = text as NSString
        let edit = try MarkdownImageUploadService.replacement(in: text, images: images, urls: urls,
            selection: NSRange(location: 0, length: raw.length), isCancelled: isCancelled, filePaths: true)
        return raw.replacingCharacters(in: edit.range, with: edit.replacement)
    }

    static func rootMediaSnapshot(_ text: String, document: URL?, isCancelled: @escaping () -> Bool) throws -> String {
        guard text.range(of: "<audio", options: .caseInsensitive) != nil || text.range(of: "<video", options: .caseInsensitive) != nil else { return text }
        var yamlError: Error?
        do {
            guard try yamlFrontMatter(text)?.contains(where: { $0.key.scalar?.string == "typora-root-url" }) == true else { return text }
        } catch { yamlError = error }
        let sources = try MarkdownImageUploadService.mediaSources(in: text, isCancelled: isCancelled)
        let targets = sources.filter { MarkdownResourcePaths.requiresRoot($0.address) }
        guard !targets.isEmpty else { return text }
        if let yamlError { throw yamlError }
        let paths = try MarkdownResourcePaths(text: text, document: document)
        guard paths.root != nil else { return text }
        let raw = text as NSString, result = NSMutableString(string: text)
        var expected: [NSRange: String] = [:]
        for item in targets.reversed() {
            if isCancelled() { throw CancellationError() }
            guard raw.substring(with: item.addressRange) == item.rawAddress,
                  let url = paths.resolve(item.address), url.isFileURL else { throw MarkdownResourcePaths.PathError.invalidRoot }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            var path = components?.percentEncodedPath ?? url.path
            if let query = components?.percentEncodedQuery { path += "?" + query }
            if let fragment = components?.percentEncodedFragment { path += "#" + fragment }
            let escaped = path.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
            expected[item.addressRange] = escaped
            if case let .html(quote) = item.syntax {
                result.replaceCharacters(in: item.addressRange, with: quote == nil ? "\"" + escaped + "\"" : escaped)
            } else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容")) }
        }
        let snapshot = result as String
        let verified = try MarkdownImageUploadService.mediaSources(in: snapshot, isCancelled: isCancelled)
        guard verified.count == sources.count,
              zip(sources, verified).allSatisfy({ original, changed in
                  changed.rawAddress.utf8.elementsEqual((expected[original.addressRange] ?? original.rawAddress).utf8)
              }) else {
            throw PandocExportError.invalidConfiguration(L10n.tr("无法确认 HTML 内容"))
        }
        return snapshot
    }

    static func argumentTokens(_ text: String) throws -> [String] {
        var result: [String] = [], current = "", quote: Character?, escaped = false, started = false
        for character in text {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if character == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                started = true
            } else if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else { current.append(character); started = true }
        }
        guard !escaped, quote == nil else { throw PandocExportError.invalidConfiguration(L10n.tr("引号或转义未结束")) }
        if started { result.append(current) }
        return result
    }

    static func checkedArguments(_ text: String, variables: [String: String], pdfEngine: Bool = false) throws -> [String] {
        func expand(_ token: String) throws -> String {
            var expanded = "", cursor = token.startIndex
            while let start = token.range(of: "${", range: cursor..<token.endIndex) {
                guard let end = token[start.upperBound...].firstIndex(of: "}") else {
                    throw PandocExportError.invalidConfiguration(L10n.tr("变量未结束"))
                }
                let name = String(token[start.upperBound..<end])
                guard let value = variables[name] else { throw PandocExportError.invalidConfiguration(L10n.tr("未知变量：%@", name)) }
                expanded += String(token[cursor..<start.lowerBound]) + value
                cursor = token.index(after: end)
            }
            return expanded + String(token[cursor...])
        }
        let tokens = try argumentTokens(text)
        // Pandoc 3.13 manual: flags with an optional value accept it with '='.
        let optional: Set<String> = ["--sandbox", "--fail-if-warnings", "--file-scope", "--preserve-tabs", "--trace", "--toc", "--table-of-contents", "--lof", "--list-of-figures", "--lot", "--list-of-tables", "--strip-comments", "--no-check-certificate", "--self-contained", "--embed-resources", "--link-images", "--html-q-tags", "--ascii", "--reference-links", "--list-tables", "--number-sections", "--listings", "--incremental", "--section-divs", "--mathjax", "--webtex", "--katex"]
        let bare: Set<String> = ["--verbose", "--quiet", "--standalone", "--no-highlight", "--citeproc", "--natbib", "--biblatex", "--mathml", "--gladtex", "-p", "-s", "-N", "-i", "-C"]
        let valued: Set<String> = ["--data-dir", "--defaults", "-d", "--shift-heading-level-by", "--base-header-level", "--indented-code-classes", "--default-image-extension", "--filter", "-F", "--lua-filter", "-L", "--metadata", "-M", "--metadata-file", "--tab-stop", "--track-changes", "--abbreviations", "--typst-input", "--template", "--variable", "-V", "--variable-json", "--eol", "--dpi", "--wrap", "--columns", "--toc-depth", "--syntax-highlighting", "--highlight-style", "--syntax-definition", "--include-in-header", "-H", "--include-before-body", "-B", "--include-after-body", "-A", "--resource-path", "--request-header", "--reference-location", "--figure-caption-position", "--table-caption-position", "--markdown-headings", "--top-level-division", "--number-offset", "--slide-level", "--email-obfuscation", "--id-prefix", "--title-prefix", "-T", "--css", "-c", "--split-level", "--epub-chapter-level", "--epub-cover-image", "--epub-title-page", "--epub-metadata", "--epub-embed-font", "--epub-subdirectory", "--ipynb-output", "--bibliography", "--csl", "--citation-abbreviations", "--math-method", "--reference-doc"]
        let forbidden: Set<String> = ["--from", "--read", "--to", "--write", "--output", "--extract-media", "--log", "--chunk-template", "--pdf-engine", "--ignore-args", "--dump-args", "--completion", "--bash-completion", "--help", "--version", "--list-input-formats", "--list-output-formats", "--list-extensions", "--list-highlight-languages", "--list-highlight-styles", "--print-default-template", "--print-default-data-file", "--print-highlight-style"]
        let forbiddenShort: Set<String> = ["-f", "-r", "-t", "-w", "-o", "-D", "-h", "-v"]
        let attached: Set<String> = ["-d", "-F", "-L", "-M", "-V", "-H", "-B", "-A", "-T", "-c"]
        var result: [String] = [], index = 0
        while index < tokens.count {
            let token = tokens[index]
            var parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if token.hasPrefix("-") && !token.hasPrefix("--") && token.count > 2 {
                let short = String(token.prefix(2))
                if forbiddenShort.contains(short) { throw PandocExportError.invalidConfiguration(L10n.tr("不支持的参数：%@", short)) }
                guard attached.contains(short) else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持的参数：%@", token)) }
                parts = [short, String(token.dropFirst(2))]
            }
            let flag = parts[0]
            guard flag != "--", flag.hasPrefix("-"), !forbiddenShort.contains(flag),
                  !forbidden.contains(where: { $0.hasPrefix(flag) }),
                  !(flag != "--pdf-engine-opt" && "--pdf-engine-opt".hasPrefix(flag)),
                  flag != "--pdf-engine-opt" || pdfEngine else {
                throw PandocExportError.invalidConfiguration(L10n.tr("不支持的参数：%@", flag))
            }
            let known = optional.contains(flag) || bare.contains(flag) || valued.contains(flag) || (flag == "--pdf-engine-opt" && pdfEngine)
            if !known && (optional.union(bare).union(valued).contains { $0.hasPrefix(flag) } || "--pdf-engine-opt".hasPrefix(flag)) {
                throw PandocExportError.invalidConfiguration(L10n.tr("不支持的参数：%@", flag))
            }
            if optional.contains(flag) {
                if parts.count == 2 { result.append(flag + "=" + (try expand(parts[1]))) }
                else { result.append(flag) }
                index += 1; continue
            }
            if bare.contains(flag), parts.count == 1 { result.append(flag); index += 1; continue }
            let needsValue = valued.contains(flag) || (flag == "--pdf-engine-opt" && pdfEngine)
            if !needsValue {
                guard flag.hasPrefix("--") else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持的参数：%@", flag)) }
                if parts.count == 2 { result.append(flag + "=" + (try expand(parts[1]))) }
                else { result.append(flag) }
                index += 1; continue
            }
            let raw: String
            if parts.count == 2 { raw = parts[1] }
            else {
                index += 1
                guard index < tokens.count else { throw PandocExportError.invalidConfiguration(L10n.tr("参数值无效：%@", flag)) }
                raw = tokens[index]
            }
            let value = try expand(raw)
            if (parts.count == 1 || !flag.hasPrefix("--")) && value.hasPrefix("-") && flag != "--pdf-engine-opt" && !(flag == "--shift-heading-level-by" && Int(value) != nil) {
                throw PandocExportError.invalidConfiguration(L10n.tr("参数值无效：%@", flag))
            }
            guard !value.isEmpty else { throw PandocExportError.invalidConfiguration(L10n.tr("参数值无效：%@", flag)) }
            if flag.hasPrefix("-") && !flag.hasPrefix("--") { result += [flag, value] }
            else if parts.count == 2 { result.append(flag + "=" + value) }
            else { result += [flag, value] }
            index += 1
        }
        return result
    }
    static func findPandoc() -> URL? {
        #if SWIFT_PACKAGE
        let executable = Bundle.module.resourceURL?.appendingPathComponent("Pandoc/pandoc")
        #else
        let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("pandoc")
        #endif
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }

    static func conflicts(destination: URL, source: URL?, openURLs: [URL]) -> Bool {
        let target = DocumentFileIdentity.resolve(destination)
        return ([source].compactMap { $0 } + openURLs).contains { url in
            let identity = DocumentFileIdentity.resolve(url)
            return target.canonicalPath == identity.canonicalPath || target.matches(identity)
        }
    }

    static func yaml12Resolver() throws -> Resolver {
        try Resolver.basic
            .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
            .appending(.int, "^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$")
            .appending(.float, "^[-+]?(?:(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?|\\.(?:inf|Inf|INF))$|^\\.(?:nan|NaN|NAN)$")
            .appending(.null, "^(?:~|null|Null|NULL|)$")
            .appending(.merge, "^<<$")
    }

    static func yamlFrontMatter(_ text: String) throws -> Yams.Node.Mapping? {
        guard let block = MarkdownPresentationParser.frontMatter(text), block.markers.count == 2 else { return nil }
        let source = text as NSString
        let start = NSMaxRange(block.markers[0]), end = block.markers[1].location
        guard end >= start else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
        let yaml = source.substring(with: NSRange(location: start, length: end - start))
        guard let root = try Yams.compose(yaml: yaml, yaml12Resolver()) else { return nil }
        guard let mapping = root.mapping else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
        return try flattenYAMLMapping(mapping)
    }

    static func yamlScalarVariables(_ text: String, isCancelled: () -> Bool) throws -> [String: String] {
        if isCancelled() { throw CancellationError() }
        guard let mapping = try yamlFrontMatter(text) else { return [:] }
        return try yamlScalarVariables(mapping, isCancelled: isCancelled)
    }

    static func yamlScalarVariables(_ mapping: Yams.Node.Mapping, isCancelled: () -> Bool) throws -> [String: String] {
        var values: [String: String] = [:]
        func collect(_ node: Yams.Node, key: String) throws {
            if isCancelled() { throw CancellationError() }
            if let children = node.mapping {
                for item in try flattenYAMLMapping(children) {
                    guard let name = item.key.scalar?.string else { continue }
                    try collect(item.value, key: key + "." + name)
                }
            } else if let scalar = node.scalar {
                if node.tag == Tag(.str) || node.tag == Tag(.int) || node.tag == Tag(.float) { values[key] = scalar.string }
                else if node.tag == Tag(.bool) { values[key] = scalar.string.lowercased() }
            }
        }
        for item in mapping {
            guard let name = item.key.scalar?.string else { continue }
            try collect(item.value, key: name)
        }
        if isCancelled() { throw CancellationError() }
        return values
    }

    static func flattenYAMLMapping(_ mapping: Yams.Node.Mapping) throws -> Yams.Node.Mapping {
        var merged: [(Yams.Node, Yams.Node)] = [], explicit: [(Yams.Node, Yams.Node)] = []
        for item in mapping {
            if item.key.tag == Tag(.merge) {
                if let child = item.value.mapping {
                    merged += try flattenYAMLMapping(child).map { ($0.key, $0.value) }
                } else if let children = item.value.sequence {
                    for value in children.reversed() {
                        guard let child = value.mapping else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
                        merged += try flattenYAMLMapping(child).map { ($0.key, $0.value) }
                    }
                } else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
            } else { explicit.append((item.key, item.value)) }
        }
        var result: [(Yams.Node, Yams.Node)] = [], positions: [String: Int] = [:]
        for pair in merged + explicit {
            guard let key = pair.0.scalar?.string else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
            if let index = positions[key] { result[index] = pair }
            else { positions[key] = result.count; result.append(pair) }
        }
        return Yams.Node.Mapping(result, mapping.tag, mapping.style)
    }

    static func prepareDefaults(arguments: [String], source: URL?, temporary: URL, profile: MarkdownExportProfile,
                                isCancelled: () -> Bool) throws -> (arguments: [String], environment: [String: String], embedsResources: Bool) {
        let manager = FileManager.default
        var options = arguments
        var embedResources = false, selfContained = false
        var defaultsEnvironment: [String: String] = [:]
        var optionIndex = 0, defaultsIndex = 0
        let workingDirectory = source?.deletingLastPathComponent() ?? temporary
        let pathFields: Set<String> = ["data-dir", "filters", "metadata-file", "metadata-files", "abbreviations", "template",
            "syntax-definition", "syntax-definitions", "syntax-highlighting", "highlight-style", "include-in-header", "include-before-body",
            "include-after-body", "resource-path", "reference-doc", "epub-cover-image", "epub-metadata", "epub-fonts", "css",
            "bibliography", "csl", "citation-abbreviations"]
        let forbiddenDefaults: Set<String> = ["from", "reader", "to", "writer", "input-file", "input-files", "output-file",
            "log-file", "extract-media", "chunk-template", "ignore-args", "dump-args", "pdf-engine", "pdf-engine-opt", "pdf-engine-opts"]
        let processEnvironment = ProcessInfo.processInfo.environment
        let homeDirectory = processEnvironment["HOME"] ?? NSHomeDirectory()
        let xdgDataDirectory = URL(fileURLWithPath: processEnvironment["XDG_DATA_HOME"] ?? homeDirectory + "/.local/share", isDirectory: true)
            .appendingPathComponent("pandoc", isDirectory: true)
        let legacyDataDirectory = URL(fileURLWithPath: homeDirectory, isDirectory: true).appendingPathComponent(".pandoc", isDirectory: true)
        var isDirectory: ObjCBool = false
        let xdgExists = manager.fileExists(atPath: xdgDataDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        isDirectory = false
        let legacyExists = manager.fileExists(atPath: legacyDataDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let defaultDataDirectory = !xdgExists && legacyExists ? legacyDataDirectory : xdgDataDirectory
        var commandDataDirectory: URL?
        func expandedDefaultsPath(_ value: String, directory: URL, dataDirectory: URL?) -> (String, [String]) {
            var result = "", cursor = value.startIndex, missing: [String] = []
            while let begin = value.range(of: "${", range: cursor..<value.endIndex),
                  let end = value[begin.upperBound...].firstIndex(of: "}") {
                result += value[cursor..<begin.lowerBound]
                let name = String(value[begin.upperBound..<end])
                if name == "." { result += directory.path }
                else if name == "USERDATA" { result += (dataDirectory ?? defaultDataDirectory).path }
                else if let found = processEnvironment[name] { result += found }
                else { missing.append(name) }
                cursor = value.index(after: end)
            }
            result += value[cursor...]
            return (result, missing)
        }
        func findDefaults(_ path: String, dataDirectory: URL?) -> URL {
            let direct = URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
            let fallback = (dataDirectory ?? defaultDataDirectory).appendingPathComponent("defaults", isDirectory: true)
                .appendingPathComponent(path)
            for candidate in [direct, direct.appendingPathExtension("yaml"), fallback, fallback.appendingPathExtension("yaml")] {
                if manager.fileExists(atPath: candidate.path) { return candidate }
            }
            return direct
        }
        func rewritePaths(_ node: Yams.Node, marker: String) -> Yams.Node {
            switch node {
            case .scalar(var scalar):
                if scalar.string.contains("${.}") {
                    let tag = scalar.tag
                    scalar.string = scalar.string.replacingOccurrences(of: "${.}", with: "${" + marker + "}")
                    scalar.tag = tag
                }
                return .scalar(scalar)
            case .sequence(var values):
                for index in values.indices { values[index] = rewritePaths(values[index], marker: marker) }
                return .sequence(values)
            case .mapping(var values):
                for index in values.indices {
                    let item = values[index]
                    values[index] = (item.key, rewritePaths(item.value, marker: marker))
                }
                return .mapping(values)
            case .alias: return node
            }
        }
        let yamlResolver = try yaml12Resolver()
        func snapshotDefaults(_ url: URL, ancestors: Set<String>) throws -> URL {
            if isCancelled() { throw CancellationError() }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard !ancestors.contains(canonical.path) else { throw PandocExportError.invalidConfiguration(L10n.tr("defaults 文件循环引用")) }
            let data = try Data(contentsOf: canonical)
            guard let yaml = String(data: data, encoding: .utf8), var root = try Yams.compose(yaml: yaml, yamlResolver),
                  var mapping = root.mapping else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
            mapping = try flattenYAMLMapping(mapping)
            let keys = Set(mapping.compactMap { $0.key.scalar?.string })
            guard forbiddenDefaults.isDisjoint(with: keys),
                  !(profile.epubTOCDepth != nil && keys.contains("toc-depth")),
                  !(profile.templatePath != nil && keys.contains("template")),
                  !(profile.referenceDocumentPath != nil && keys.contains("reference-doc")),
                  !(profile.epubCoverPath != nil && keys.contains("epub-cover-image")) else {
                throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容"))
            }
            let originalDirectory = canonical.deletingLastPathComponent()
            let marker = "LACEDITOR_DEFAULTS_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            defaultsEnvironment[marker] = originalDirectory.path
            let dataDirectory: URL?
            if let value = mapping["data-dir"]?.scalar?.string {
                let expanded = expandedDefaultsPath(value, directory: originalDirectory, dataDirectory: commandDataDirectory).0
                dataDirectory = URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
            } else { dataDirectory = nil }
            let nextAncestors = ancestors.union([canonical.path])
            for index in mapping.indices {
                let item = mapping[index]
                guard let name = item.key.scalar?.string else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
                if name == "defaults" {
                    func resolveChild(_ value: Yams.Node) throws -> (URL, [String]) {
                        guard value.tag == Tag(.str), let scalar = value.scalar else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 defaults 文件内容")) }
                        let (path, missing) = expandedDefaultsPath(scalar.string, directory: originalDirectory, dataDirectory: dataDirectory)
                        return (findDefaults(path, dataDirectory: dataDirectory), missing)
                    }
                    func child(_ resolved: (URL, [String])) throws -> Yams.Node {
                        let copy = try snapshotDefaults(resolved.0, ancestors: nextAncestors)
                        let key = "LACEDITOR_DEFAULTS_FILE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        defaultsEnvironment[key] = copy.path
                        return Yams.Node("${" + key + "}" + resolved.1.map { "${" + $0 + "}" }.joined())
                    }
                    if var sequence = item.value.sequence {
                        let resolved = try sequence.map(resolveChild)
                        for childIndex in sequence.indices { sequence[childIndex] = try child(resolved[childIndex]) }
                        mapping[index] = (item.key, .sequence(sequence))
                    } else { mapping[index] = (item.key, try child(resolveChild(item.value))) }
                } else if pathFields.contains(name) {
                    mapping[index] = (item.key, rewritePaths(item.value, marker: marker))
                }
            }
            if let value = mapping["embed-resources"], value.tag == Tag(.bool), let scalar = value.scalar?.string {
                embedResources = scalar.lowercased() == "true"
            }
            if let value = mapping["self-contained"], value.tag == Tag(.bool), let scalar = value.scalar?.string {
                selfContained = scalar.lowercased() == "true"
            }
            if let dataDirectory { commandDataDirectory = dataDirectory }
            root.mapping = mapping
            let copy = temporary.appendingPathComponent("defaults-\(defaultsIndex).yaml")
            defaultsIndex += 1
            try Data(try Yams.serialize(node: root, canonical: true, allowUnicode: true).utf8).write(to: copy, options: .withoutOverwriting)
            return copy
        }
        while optionIndex < options.count {
            let argument = options[optionIndex]
            if argument == "--embed-resources" || argument == "--embed-resources=true" { embedResources = true }
            if argument == "--embed-resources=false" { embedResources = false }
            if argument == "--self-contained" || argument == "--self-contained=true" { selfContained = true }
            if argument == "--self-contained=false" { selfContained = false }
            if argument.hasPrefix("--data-dir=") {
                commandDataDirectory = URL(fileURLWithPath: String(argument.dropFirst("--data-dir=".count)), relativeTo: workingDirectory).standardizedFileURL
            } else if argument == "--data-dir", optionIndex + 1 < options.count {
                commandDataDirectory = URL(fileURLWithPath: options[optionIndex + 1], relativeTo: workingDirectory).standardizedFileURL
            }
            let explicit = argument.hasPrefix("--defaults=")
            if explicit || argument == "--defaults" || argument == "-d" {
                let path: String
                if explicit { path = String(argument.dropFirst("--defaults=".count)) }
                else {
                    guard optionIndex + 1 < options.count else { throw PandocExportError.invalidConfiguration(L10n.tr("参数值无效：%@", argument)) }
                    path = options[optionIndex + 1]
                }
                guard source != nil || path.hasPrefix("/") else {
                    throw PandocExportError.invalidConfiguration(L10n.tr("未保存文档需要 defaults 绝对路径"))
                }
                let original = findDefaults(path, dataDirectory: commandDataDirectory)
                let copy = try snapshotDefaults(original, ancestors: [])
                if explicit { options[optionIndex] = "--defaults=" + copy.path }
                else { options[optionIndex + 1] = copy.path; optionIndex += 1 }
            }
            optionIndex += 1
        }
        return (options, defaultsEnvironment, embedResources || selfContained)
    }

    // Two Pandoc passes use the same snapshot. The first exposes YAML metadata;
    // the second consumes that exact parsed document and writes only to a temporary file.
    static func prepare(text original: String, source: URL?, destination: URL, profile: MarkdownExportProfile,
                        title: String, executable: URL? = nil, isCancelled: @escaping () -> Bool = { false },
                        htmlOptions: MarkdownHTMLExportOptions? = nil, syntax: MarkdownSyntaxOptions = .init(),
                        wiki: MarkdownWikiLinkSource? = nil) throws -> PandocExportResult {
        if isCancelled() { throw CancellationError() }
        guard let pandoc = executable ?? findPandoc() else { throw PandocExportError.missingPandoc }
        guard ["", "mediawiki", "latex"].contains(profile.rawType) else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此原始类型")) }
        let ext = destination.pathExtension
        guard !ext.isEmpty, ext.lowercased() != "pdf" else { throw PandocExportError.invalidConfiguration(L10n.tr("不支持此输出扩展名")) }
        let writers: Set<String> = ["ansi", "asciidoc", "asciidoc_legacy", "asciidoctor", "bbcode", "bbcode_fluxbb",
            "bbcode_phpbb", "bbcode_steam", "bbcode_hubzilla", "bbcode_xenforo", "beamer", "bibtex", "biblatex",
            "chunkedhtml", "commonmark", "commonmark_x", "context", "csljson", "djot", "docbook", "docbook4",
            "docbook5", "docx", "dokuwiki", "epub", "epub2", "epub3", "fb2", "fodt", "gfm", "markdown_github",
            "haddock", "html", "html4", "html5", "icml", "ipynb", "jats", "jats_archiving", "jats_articleauthoring",
            "jats_publishing", "jira", "json", "latex", "man", "markdown", "markdown_mmd", "markdown_phpextra",
            "markdown_strict", "markua", "mediawiki", "ms", "muse", "native", "odt", "opml", "opendocument", "org",
            "plain", "pptx", "rst", "rtf", "texinfo", "textile", "t2t", "slideous", "slidy", "dzslides", "revealjs",
            "s5", "tei", "typst", "vimdoc", "xml", "xwiki", "zimwiki"]
        if !profile.writer.isEmpty {
            let components = profile.writer.split(whereSeparator: { $0 == "+" || $0 == "-" })
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
            guard let first = profile.writer.first, first != "+", first != "-",
                  let base = components.first, writers.contains(String(base)),
                  profile.writer.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "+" || $0 == "-" }),
                  !profile.writer.hasSuffix("+"), !profile.writer.hasSuffix("-"),
                  !profile.writer.contains("++"), !profile.writer.contains("--"),
                  !profile.writer.contains("+-"), !profile.writer.contains("-+") else {
                throw PandocExportError.invalidConfiguration(L10n.tr("不支持此 Pandoc 输出格式"))
            }
        }
        if !profile.rawType.isEmpty {
            let base = String(profile.writer.prefix { $0 != "+" && $0 != "-" })
            let inferred = ext.lowercased() == "tex" ? "latex" : (ext.lowercased() == "wiki" ? "mediawiki" : ext.lowercased())
            guard (base.isEmpty ? inferred : base) == profile.rawType else {
                throw PandocExportError.invalidConfiguration(L10n.tr("原始类型与输出格式不匹配"))
            }
        }
        let snapshot = try markedExportSnapshot(original, syntax: syntax, includeTOC: !profile.rawType.isEmpty, wiki: wiki, isCancelled: isCancelled)
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.md")
        let ast = temporary.appendingPathComponent("document.json")
        let output = temporary.appendingPathComponent("output").appendingPathExtension(ext)
        let log = temporary.appendingPathComponent("stderr")
        let markers = snapshot.toc
        let markedText = snapshot.text
        try markedText.write(to: input, atomically: true, encoding: .utf8)
        var defaultsEnvironment: [String: String] = [:]
        func run(_ arguments: [String]) throws -> String {
            guard manager.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let stderr = try FileHandle(forWritingTo: log)
            defer { try? stderr.close(); try? manager.removeItem(at: log) }
            let status = try CustomMarkdownExportService.runPandocGroup(pandoc, arguments: [pandoc.path] + arguments,
                directory: source?.deletingLastPathComponent() ?? temporary, stderr: stderr, isCancelled: isCancelled,
                additionalEnvironment: defaultsEnvironment)
            try stderr.synchronize()
            let diagnostics = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !isCancelled() else { throw CancellationError() }
            guard status == 0 else {
                throw PandocExportError.conversionFailed(diagnostics.isEmpty ? "Pandoc (\(status))" : diagnostics)
            }
            return diagnostics
        }
        let readerFormat = "--from=gfm+yaml_metadata_block-tex_math_dollars" + ((syntax.smartPunctuation ?? true) ? "+smart" : "-smart") + (syntax.preserveExportSoftBreaks == true ? "+hard_line_breaks" : "-hard_line_breaks")
        let firstDiagnostics = try run([readerFormat, "--to=json", "--output", ast.path, "--", input.path])
        var rootedDiagnostics = ""
        guard var tree = try JSONSerialization.jsonObject(with: Data(contentsOf: ast)) as? [String: Any],
              var metadata = tree["meta"] as? [String: Any] else { throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效")) }
        if let originalMetadata = try originalMathMetadata(original, executable: pandoc, source: source, temporary: temporary, isCancelled: isCancelled) {
            metadata = originalMetadata
            tree["meta"] = originalMetadata
        }
        func installTOCMarkers(in tree: inout [String: Any]) throws {
            guard !markers.isEmpty else { return }
            guard var blocks = tree["blocks"] as? [[String: Any]] else {
                throw PandocExportError.invalidConfiguration(L10n.tr("无法确认目录标记"))
            }
            let allMarkers = Set(markers)
            var remaining = allMarkers
            for index in blocks.indices {
                guard blocks[index]["t"] as? String == "Para",
                      let inlines = blocks[index]["c"] as? [[String: Any]], inlines.count == 1,
                      inlines[0]["t"] as? String == "Str", let marker = inlines[0]["c"] as? String,
                      allMarkers.contains(marker) else { continue }
                guard remaining.remove(marker) != nil else {
                    throw PandocExportError.invalidConfiguration(L10n.tr("无法确认目录标记"))
                }
                let raw = profile.rawType == "mediawiki" ? "__TOC__" : "\\tableofcontents"
                blocks[index] = ["t": "RawBlock", "c": [profile.rawType, raw]]
            }
            guard remaining.isEmpty else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确认目录标记")) }
            tree["blocks"] = blocks
        }
        try installTOCMarkers(in: &tree)
        let htmlWriter = profile.writer.isEmpty ? ext.lowercased() : String(profile.writer.prefix { $0 != "+" && $0 != "-" }).lowercased()
        if ["docx", "odt", "rtf", "fb2", "pptx", "epub", "epub2", "epub3"].contains(htmlWriter) {
            tree = try resolveRootImages(in: tree, text: original, document: source, isCancelled: isCancelled)
            guard let resolvedMetadata = tree["meta"] as? [String: Any] else { throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效")) }
            metadata = resolvedMetadata
        }
        if metadata["title"] == nil { metadata["title"] = ["t": "MetaString", "c": title] }
        tree["meta"] = metadata
        var variables: [String: String] = [:]
        func collect(_ node: Any, key: String) {
            guard let node = node as? [String: Any], let type = node["t"] as? String else { return }
            if type == "MetaMap", let children = node["c"] as? [String: Any] {
                for (name, value) in children { collect(value, key: key + "." + name) }
            } else if type == "MetaString", let value = node["c"] as? String { variables[key] = value }
            else if type == "MetaBool", let value = node["c"] as? Bool { variables[key] = value ? "true" : "false" }
            else if type == "MetaInlines", let inlines = node["c"] as? [[String: Any]] {
                var value = ""
                for inline in inlines {
                    switch inline["t"] as? String {
                    case "Str": guard let part = inline["c"] as? String else { return }; value += part
                    case "Space", "SoftBreak": value += " "
                    default: return
                    }
                }
                variables[key] = value
            }
        }
        for (key, node) in metadata { collect(node, key: key) }
        for (key, value) in try yamlScalarVariables(original, isCancelled: isCancelled) { variables[key] = value }
        for key in ["currentPath", "currentFolder", "currentFileName", "currentFileFullName"] { variables.removeValue(forKey: key) }
        variables["outputPath"] = destination.path
        variables["outputFileName"] = destination.deletingPathExtension().lastPathComponent
        variables["outputFileFullName"] = destination.lastPathComponent
        if let source {
            variables["currentPath"] = source.path
            variables["currentFolder"] = source.deletingLastPathComponent().path
            variables["currentFileName"] = source.deletingPathExtension().lastPathComponent
            variables["currentFileFullName"] = source.lastPathComponent
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd"
        variables["today"] = date.string(from: Date())
        var options = try checkedArguments(profile.arguments, variables: variables)
        let defaults = try prepareDefaults(arguments: options, source: source, temporary: temporary, profile: profile, isCancelled: isCancelled)
        options = defaults.arguments
        defaultsEnvironment = defaults.environment
        func hasOption(_ name: String) -> Bool { options.contains { $0 == name || $0.hasPrefix(name + "=") } }
        if (profile.templatePath != nil && hasOption("--template")) ||
            (profile.referenceDocumentPath != nil && hasOption("--reference-doc")) ||
            (profile.epubCoverPath != nil && hasOption("--epub-cover-image")) {
            throw PandocExportError.invalidConfiguration(L10n.tr("参数与输出格式不匹配"))
        }
        if profile.epubTOCDepth != nil && options.contains(where: { $0 == "--toc-depth" || $0.hasPrefix("--toc-depth=") }) {
            throw PandocExportError.invalidConfiguration(L10n.tr("目录深度重复设置"))
        }
        let selectedWriter = profile.writer.isEmpty ? ext.lowercased() : String(profile.writer.prefix { $0 != "+" && $0 != "-" })
        guard profile.referenceDocumentPath == nil || ["docx", "odt"].contains(selectedWriter),
              (profile.epubCoverPath == nil && profile.epubTOCDepth == nil) || ["epub", "epub2", "epub3"].contains(selectedWriter) else {
            throw PandocExportError.invalidConfiguration(L10n.tr("参数与输出格式不匹配"))
        }
        var textareaValues: [(String, String)] = []
        var mediaFragments: [MediaFragment] = []
        if ["html", "htm", "html4", "html5"].contains(selectedWriter.lowercased()),
           defaults.embedsResources {
            let imageRooted = try rootImageSnapshot(markedText, document: source, isCancelled: isCancelled)
            let rooted = try rootMediaSnapshot(imageRooted, document: source, isCancelled: isCancelled)
            let markedMedia = try markMediaFragments(rooted, isCancelled: isCancelled)
            mediaFragments = markedMedia.1
            let protected = try protectTextareas(markedMedia.0, isCancelled: isCancelled)
            textareaValues = protected.1
            if protected.0 != markedText {
                try protected.0.write(to: input, atomically: true, encoding: .utf8)
                rootedDiagnostics = try run([readerFormat, "--to=json", "--output", ast.path, "--", input.path])
                guard var rootedTree = try JSONSerialization.jsonObject(with: Data(contentsOf: ast)) as? [String: Any] else {
                    throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效"))
                }
                try installTOCMarkers(in: &rootedTree)
                guard let blocks = rootedTree["blocks"] as? [[String: Any]] else { throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效")) }
                tree["blocks"] = blocks
                if let metadata = tree["meta"] as? [String: Any] {
                    let resolved = try resolveRootImages(in: ["meta": metadata], text: original, document: source, isCancelled: isCancelled)
                    tree["meta"] = resolved["meta"]
                }
            } else {
                tree = try resolveRootImages(in: tree, text: original, document: source, isCancelled: isCancelled)
            }
        }
        tree = try restoreMath(in: tree, markers: snapshot.math, latexWhitespace: ["latex", "tex"].contains(selectedWriter.lowercased()), isCancelled: isCancelled)
        let latexAssets = ["latex", "tex"].contains(selectedWriter.lowercased())
            ? try stageLatexImages(in: &tree, destination: destination, temporary: temporary, isCancelled: isCancelled) : nil
        try JSONSerialization.data(withJSONObject: tree).write(to: ast, options: .atomic)
        var arguments = ["--from=json", "--standalone"]
        if !profile.writer.isEmpty { arguments.append("--to=\(profile.writer)") }
        if let path = profile.templatePath { arguments.append("--template=\(path)") }
        if let path = profile.referenceDocumentPath { arguments.append("--reference-doc=\(path)") }
        if let depth = profile.epubTOCDepth {
            guard depth > 0 else { throw PandocExportError.invalidConfiguration(L10n.tr("目录深度无效")) }
            arguments.append("--toc-depth=\(depth)")
        }
        if let path = profile.epubCoverPath { arguments.append("--epub-cover-image=\(path)") }
        arguments += options + ["--output", output.path, "--", ast.path]
        let secondDiagnostics = try run(arguments)
        try restoreTextareas(in: output, values: textareaValues, isCancelled: isCancelled)
        try restoreMediaFragments(in: output, markers: mediaFragments, isCancelled: isCancelled)
        if let htmlOptions, ["html", "htm", "html4", "html5"].contains(selectedWriter.lowercased()) {
            let htmlMetadata = try MarkdownPDFMetadataReader.read(original, includeHTMLFragments: htmlOptions.allowDocumentOverrides,
                                                                   executable: pandoc, isCancelled: isCancelled)
            let systemKeys: Set<String> = ["outputPath", "outputFileName", "outputFileFullName", "currentPath", "currentFolder", "currentFileName", "currentFileFullName", "today"]
            for (key, value) in htmlMetadata.variables where !systemKeys.contains(key) { variables[key] = value }
            try appendHTML(to: output, options: htmlOptions, variables: variables)
        }
        let replacementDirectory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: destination.deletingLastPathComponent(), create: true)
        let prepared = replacementDirectory.appendingPathComponent("output").appendingPathExtension(ext)
        do {
            try manager.copyItem(at: output, to: prepared)
            if latexAssets != nil { try manager.copyItem(at: temporary.appendingPathComponent("latex-assets"), to: replacementDirectory.appendingPathComponent("latex-assets")) }
        }
        catch { try? manager.removeItem(at: replacementDirectory); throw error }
        return PandocExportResult(preparedURL: prepared, diagnostics: [firstDiagnostics, rootedDiagnostics, secondDiagnostics].filter { !$0.isEmpty }.joined(separator: "\n"), latexAssets: latexAssets)
    }

    // Runs off the main thread. The returned file is on the destination volume
    // so the final move or replacement stays on the same volume.
    static func prepare(
        text original: String, source: URL?, destination: URL, format: PandocExportFormat,
        title: String, executable: URL? = nil, isCancelled: @escaping () -> Bool = { false },
        htmlOptions: MarkdownHTMLExportOptions = .init(), syntax: MarkdownSyntaxOptions = .init(), wiki: MarkdownWikiLinkSource? = nil
    ) throws -> PandocExportResult {
        guard let pandoc = executable ?? findPandoc() else { throw PandocExportError.missingPandoc }
        let snapshot = try markedExportSnapshot(original, syntax: syntax, includeTOC: false, wiki: wiki, isCancelled: isCancelled)
        let emojiText = snapshot.text
        let rootedText: String
        if format == .html {
            let imageRooted = try rootImageSnapshot(emojiText, document: source, isCancelled: isCancelled)
            rootedText = try rootMediaSnapshot(imageRooted, document: source, isCancelled: isCancelled)
        }
        else { rootedText = emojiText }
        let markedMedia = try format == .html ? markMediaFragments(rootedText, isCancelled: isCancelled) : (rootedText, [])
        let protected = try format == .html ? protectTextareas(markedMedia.0, isCancelled: isCancelled) : (markedMedia.0, [])
        let text = protected.0
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.md")
        let output = temporary.appendingPathComponent("output.\(format.fileExtension)")
        let log = temporary.appendingPathComponent("stderr")
        try text.write(to: input, atomically: true, encoding: .utf8)
        guard manager.createFile(atPath: log.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stderr = try FileHandle(forWritingTo: log)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = pandoc
        let metadata: MarkdownPDFMetadata?
        let needsRootImages = try [.html, .docx, .odt, .rtf, .fb2, .epub].contains(format) && mayNeedResourceRoot(original, isCancelled: isCancelled)
        if format == .html {
            metadata = try MarkdownPDFMetadataReader.read(rootedText, includeHTMLFragments: htmlOptions.allowDocumentOverrides, executable: executable, isCancelled: isCancelled)
        } else { metadata = nil }
        var writerInput = input
        var latexAssets: PandocExportResult.LatexAssets?
        do {
            let ast = temporary.appendingPathComponent("document.json")
            let reader = Process()
            reader.executableURL = pandoc
            reader.arguments = ["--from=\(format == .html ? "gfm+yaml_metadata_block" : "gfm")-tex_math_dollars\((syntax.smartPunctuation ?? true) ? "+smart" : "-smart")\(syntax.preserveExportSoftBreaks == true ? "+hard_line_breaks" : "-hard_line_breaks")", "--to=json", "--output", ast.path, "--", input.path]
            if let source { reader.currentDirectoryURL = source.deletingLastPathComponent() }
            reader.standardOutput = FileHandle.nullDevice
            reader.standardError = stderr
            try CustomMarkdownExportService.run(reader, isCancelled: isCancelled)
            guard reader.terminationStatus == 0 else {
                try stderr.synchronize()
                let diagnostics = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw PandocExportError.conversionFailed(diagnostics.isEmpty ? "Pandoc (\(reader.terminationStatus))" : diagnostics)
            }
            guard var tree = try JSONSerialization.jsonObject(with: Data(contentsOf: ast)) as? [String: Any],
                  tree["blocks"] is [[String: Any]] else {
                throw PandocExportError.invalidConfiguration(L10n.tr("Pandoc 元数据无效"))
            }
            if format == .html, let originalMetadata = try originalMathMetadata(original, executable: pandoc, source: source, temporary: temporary, isCancelled: isCancelled) {
                tree["meta"] = originalMetadata
            }
            if format == .html, let metadata = tree["meta"] as? [String: Any] {
                let resolved = try resolveRootImages(in: ["meta": metadata], text: original, document: source, isCancelled: isCancelled)
                tree["meta"] = resolved["meta"]
            } else if needsRootImages { tree = try resolveRootImages(in: tree, text: original, document: source, isCancelled: isCancelled) }
            tree = try restoreMath(in: tree, markers: snapshot.math, latexWhitespace: format == .latex, isCancelled: isCancelled)
            if format == .latex { latexAssets = try stageLatexImages(in: &tree, destination: destination, temporary: temporary, isCancelled: isCancelled) }
            try JSONSerialization.data(withJSONObject: tree).write(to: ast, options: .atomic)
            writerInput = ast
        }
        var arguments = ["--from=json", "--to=\(format.writer)", "--standalone"]
        if metadata?.variables["title"] == nil { arguments += ["--metadata", "title=\(title)"] }
        if format == .html { arguments.append("--embed-resources") }
        process.arguments = arguments + ["--output", output.path, writerInput.path]
        if let source {
            process.currentDirectoryURL = source.deletingLastPathComponent()
        }
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? ""
        environment["PATH"] = path + ":/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try CustomMarkdownExportService.run(process, isCancelled: isCancelled)
        try stderr.synchronize()
        let diagnostics = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw PandocExportError.conversionFailed(diagnostics.isEmpty ? "Pandoc (\(process.terminationStatus))" : diagnostics)
        }
        try restoreTextareas(in: output, values: protected.1, isCancelled: isCancelled)
        try restoreMediaFragments(in: output, markers: markedMedia.1, isCancelled: isCancelled)
        if format == .html, let metadata {
            var variables = metadata.variables
            variables["outputPath"] = destination.path
            variables["outputFileName"] = destination.deletingPathExtension().lastPathComponent
            variables["outputFileFullName"] = destination.lastPathComponent
            if let source {
                variables["currentPath"] = source.path
                variables["currentFolder"] = source.deletingLastPathComponent().path
                variables["currentFileName"] = source.deletingPathExtension().lastPathComponent
                variables["currentFileFullName"] = source.lastPathComponent
            }
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd"
            variables["today"] = date.string(from: Date())
            try appendHTML(to: output, options: htmlOptions, variables: variables)
        }
        let replacementDirectory = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination.deletingLastPathComponent(), create: true
        )
        let prepared = replacementDirectory.appendingPathComponent("output.\(format.fileExtension)")
        do {
            try manager.copyItem(at: output, to: prepared)
            if latexAssets != nil { try manager.copyItem(at: temporary.appendingPathComponent("latex-assets"), to: replacementDirectory.appendingPathComponent("latex-assets")) }
        } catch {
            try? manager.removeItem(at: replacementDirectory)
            throw error
        }
        return PandocExportResult(preparedURL: prepared, diagnostics: diagnostics, latexAssets: latexAssets)
    }

    private static func appendHTML(to output: URL, options: MarkdownHTMLExportOptions, variables: [String: String]) throws {
        let fragments = MarkdownHTMLMediaService.exportFragments(options: options, variables: variables)
        guard !fragments.head.isEmpty || !fragments.body.isEmpty else { return }
        let html = try String(contentsOf: output, encoding: .utf8) as NSString
        func uniqueClose(_ tag: String) throws -> NSRange {
            let range = html.range(of: tag, options: .caseInsensitive)
            guard range.location != NSNotFound,
                  html.range(of: tag, options: .caseInsensitive, range: NSRange(location: NSMaxRange(range), length: html.length - NSMaxRange(range))).location == NSNotFound else {
                throw PandocExportError.invalidConfiguration(L10n.tr("无法确定 HTML 附加内容位置"))
            }
            return range
        }
        let head = try uniqueClose("</head>"), body = try uniqueClose("</body>")
        guard head.location < body.location else { throw PandocExportError.invalidConfiguration(L10n.tr("无法确定 HTML 附加内容位置")) }
        let result = NSMutableString(string: html as String)
        result.insert(fragments.body, at: body.location)
        result.insert(fragments.head, at: head.location)
        try Data((result as String).utf8).write(to: output, options: .atomic)
    }

    static func install(_ prepared: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: prepared)
        } else {
            try manager.moveItem(at: prepared, to: destination)
        }
    }

    static func install(_ result: PandocExportResult, at destination: URL, isCancelled: () -> Bool,
                        commit: ((() throws -> Void) throws -> Void)? = nil, validate: () throws -> Void) throws {
        guard let assets = result.latexAssets else {
            try validate()
            if isCancelled() { throw CancellationError() }
            if let commit { try commit({}) } else { try install(result.preparedURL, at: destination) }
            return
        }
        let manager = FileManager.default
        func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") }
        let fileNames = assets.files.map(\.name)
        guard validName(assets.directoryName), !fileNames.isEmpty,
              fileNames.allSatisfy(validName), Set(fileNames).count == fileNames.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = destination.deletingLastPathComponent().appendingPathComponent(assets.directoryName, isDirectory: true)
        let replacementDirectory = result.preparedURL.deletingLastPathComponent()
        let staged = replacementDirectory.appendingPathComponent("latex-assets", isDirectory: true)
        let privateDirectory = replacementDirectory.appendingPathComponent("latex-install", isDirectory: true)
        try validate()
        if isCancelled() { throw CancellationError() }
        guard mkdir(privateDirectory.path, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directoryFD = open(privateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directoryFD) }
        var original = stat(), named = stat()
        guard fstat(directoryFD, &original) == 0, (original.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              lstat(privateDirectory.path, &named) == 0, named.st_dev == original.st_dev, named.st_ino == original.st_ino else {
            throw CocoaError(.fileWriteUnknown)
        }
        if isCancelled() { throw CancellationError() }
        guard renamex_np(privateDirectory.path, directory.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        func publicDirectoryIsOriginal() -> Bool {
            var current = stat()
            return lstat(directory.path, &current) == 0 && (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
                current.st_dev == original.st_dev && current.st_ino == original.st_ino
        }
        var written: [(name: String, bytes: Data, device: dev_t, inode: ino_t)] = []
        do {
            guard publicDirectoryIsOriginal() else { throw CocoaError(.fileWriteUnknown) }
            for asset in assets.files {
                if isCancelled() { throw CancellationError() }
                guard publicDirectoryIsOriginal() else { throw CocoaError(.fileWriteUnknown) }
                let bytes = try Data(contentsOf: staged.appendingPathComponent(asset.name))
                guard bytes == asset.bytes else { throw CocoaError(.fileReadCorruptFile) }
                let fileFD = openat(directoryFD, asset.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
                guard fileFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let file = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
                var info = stat()
                do {
                    try file.write(contentsOf: bytes)
                    guard fstat(fileFD, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw CocoaError(.fileWriteUnknown) }
                    try file.close()
                } catch {
                    try? file.close()
                    throw error
                }
                written.append((asset.name, bytes, info.st_dev, info.st_ino))
                if isCancelled() { throw CancellationError() }
            }
            try validate()
            if isCancelled() { throw CancellationError() }
            guard publicDirectoryIsOriginal(),
                  Set(try manager.contentsOfDirectory(atPath: directory.path)) == Set(written.map(\.name)),
                  publicDirectoryIsOriginal() else { throw CocoaError(.fileWriteUnknown) }
            var verified: [(name: String, info: stat)] = []
            for item in written {
                if isCancelled() { throw CancellationError() }
                let fileFD = openat(directoryFD, item.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fileFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let file = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
                var info = stat()
                let identityMatches = fstat(fileFD, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
                    info.st_dev == item.device && info.st_ino == item.inode
                let content = identityMatches ? try file.readToEnd() : nil
                var namedFile = stat()
                let matches = identityMatches && content == item.bytes &&
                    fstatat(directoryFD, item.name, &namedFile, AT_SYMLINK_NOFOLLOW) == 0 &&
                    namedFile.st_dev == item.device && namedFile.st_ino == item.inode
                try file.close()
                guard matches else { throw CocoaError(.fileWriteUnknown) }
                verified.append((item.name, namedFile))
            }
            try validate()
            func verifyBeforeCommit() throws {
                if isCancelled() { throw CancellationError() }
                guard publicDirectoryIsOriginal(),
                      Set(try manager.contentsOfDirectory(atPath: directory.path)) == Set(written.map(\.name)),
                      publicDirectoryIsOriginal() else { throw CocoaError(.fileWriteUnknown) }
                for item in verified {
                    if isCancelled() { throw CancellationError() }
                    var current = stat()
                    guard fstatat(directoryFD, item.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          current.st_dev == item.info.st_dev, current.st_ino == item.info.st_ino, current.st_size == item.info.st_size,
                          current.st_mtimespec.tv_sec == item.info.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == item.info.st_mtimespec.tv_nsec,
                          current.st_ctimespec.tv_sec == item.info.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == item.info.st_ctimespec.tv_nsec else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                if isCancelled() { throw CancellationError() }
                guard publicDirectoryIsOriginal() else { throw CocoaError(.fileWriteUnknown) }
            }
            if let commit { try commit(verifyBeforeCommit) }
            else { try verifyBeforeCommit(); try install(result.preparedURL, at: destination) }
        } catch {
            throw PandocExportError.incompleteLatexAssets(directory.path, error.localizedDescription)
        }

    }
}
