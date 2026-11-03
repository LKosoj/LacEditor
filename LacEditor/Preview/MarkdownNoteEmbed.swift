import Foundation

/// Откуда брать текст встраиваемой заметки. Синхронный, из готового кэша или с диска; nil — нет содержимого.
/// `target` — имя заметки как написано в `![[…]]`, без `#раздел` и `|псевдоним`.
protocol MarkdownNoteEmbedProvider: Sendable {
    func embeddedNote(for target: String) -> String?
    /// Адрес для ссылки «Открыть» (относительный путь, как у wiki-ссылок); nil — построить из каталога файлов.
    func openAddress(for target: String, heading: String?) -> String?
}

extension MarkdownNoteEmbedProvider {
    func openAddress(for target: String, heading: String?) -> String? { nil }
}

/// Встраивание, найденное в тексте.
struct MarkdownNoteEmbedItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case note, image, attachment }
    let range: NSRange            // от `!` до последней `]`
    let target: String
    let heading: String?
    let alias: String?
    let kind: Kind
    let isBlock: Bool             // стоит в отдельном абзаце верхнего уровня
}

/// Встраивание заметок Obsidian `![[…]]` в предпросмотре и экспорте HTML/PDF.
enum MarkdownNoteEmbed {
    static let maxEmbedsPerPage = 20
    static let maxTotalBytes = 1 << 20
    static let maxNoteBytes = 64 << 10

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tiff", "tif"]

    /// Содержит ли текст `![[`.
    static func mayContainEmbed(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { (buffer: UnsafeBufferPointer<UInt8>) -> Bool in
            var index = 0
            let count = buffer.count
            while index + 2 < count {
                if buffer[index] == 0x21, buffer[index + 1] == 0x5B, buffer[index + 2] == 0x5B { return true }
                index += 1
            }
            return false
        }
    }

    /// Расширения вложений: аудио, видео и PDF берутся из `MarkdownDataMedia.extensions`.
    private static let attachmentExtensions: Set<String> = Set(MarkdownDataMedia.extensions.values)

    /// Вид цели по расширению: графические — картинка; известные аудио, видео и PDF — вложение;
    /// остальное (в том числе имена с точкой вроде «v1.2 заметки») — заметка.
    static func kind(forTarget target: String) -> MarkdownNoteEmbedItem.Kind {
        let ext = (target as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        return attachmentExtensions.contains(ext) ? .attachment : .note
    }

    /// Все `![[…]]` вне исключаемых диапазонов; строка без `]]`, с переводом строки внутри, с `\` или `\0` в цели — не встраивание.
    static func items(in text: NSString, excluded: [NSRange]) -> [MarkdownNoteEmbedItem] {
        let length = text.length
        var result: [MarkdownNoteEmbedItem] = []
        var position = 0
        func isExcluded(_ location: Int) -> Bool {
            var low = 0, high = excluded.count
            while low < high {
                let middle = (low + high) / 2
                if excluded[middle].location <= location { low = middle + 1 } else { high = middle }
            }
            return low > 0 && NSMaxRange(excluded[low - 1]) > location
        }
        while position + 4 < length {
            let found = text.range(of: "![[", options: .literal, range: NSRange(location: position, length: length - position))
            guard found.location != NSNotFound else { break }
            let start = found.location
            position = start + 3
            if isExcluded(start) { continue }
            var slashes = 0
            while start - slashes - 1 >= 0, text.character(at: start - slashes - 1) == 92 { slashes += 1 }
            if slashes % 2 == 1 { continue }
            // Содержимое до `]]` в пределах строки.
            var end = start + 3
            var closed = false
            while end + 1 < length {
                let unit = text.character(at: end)
                if unit == 10 || unit == 13 { break }
                if unit == 93, text.character(at: end + 1) == 93 { closed = true; break }
                end += 1
            }
            guard closed else { continue }
            let inner = text.substring(with: NSRange(location: start + 3, length: end - start - 3))
            if inner.contains("\\") || inner.contains("\0") || inner.contains("[[") { continue }
            let range = NSRange(location: start, length: end + 2 - start)
            guard let parsed = parse(inner) else { continue }
            result.append(MarkdownNoteEmbedItem(range: range, target: parsed.target, heading: parsed.heading, alias: parsed.alias,
                                                kind: kind(forTarget: parsed.target),
                                                isBlock: isBlockEmbed(range: range, in: text)))
            position = NSMaxRange(range)
        }
        return result
    }

    /// `цель#раздел|псевдоним`; nil — пустая цель.
    private static func parse(_ inner: String) -> (target: String, heading: String?, alias: String?)? {
        var main = inner
        var alias: String?
        if let bar = inner.firstIndex(of: "|") {
            main = String(inner[inner.startIndex..<bar])
            alias = String(inner[inner.index(after: bar)...])
        }
        var target = main
        var heading: String?
        if let hash = main.firstIndex(of: "#") {
            target = String(main[main.startIndex..<hash])
            let value = String(main[main.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            heading = value.isEmpty ? nil : value
        }
        target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return (target, heading, alias)
    }

    /// Строка целиком из встраивания (отступ не больше 3 пробелов), сверху и снизу пустая строка или граница документа.
    private static func isBlockEmbed(range: NSRange, in text: NSString) -> Bool {
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: range.location, length: 0))
        guard NSMaxRange(range) <= contentsEnd else { return false }
        let indent = range.location - line.location
        guard indent <= 3, (line.location..<range.location).allSatisfy({ text.character(at: $0) == 32 }) else { return false }
        guard (NSMaxRange(range)..<contentsEnd).allSatisfy({ text.character(at: $0) == 32 || text.character(at: $0) == 9 }) else { return false }
        func isBlankLine(_ lineRange: NSRange) -> Bool {
            (lineRange.location..<NSMaxRange(lineRange)).allSatisfy {
                let unit = text.character(at: $0)
                return unit == 32 || unit == 9 || unit == 10 || unit == 13
            }
        }
        if line.location > 0 {
            let previous = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
            if !isBlankLine(previous) { return false }
        }
        if NSMaxRange(line) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            if !isBlankLine(next) { return false }
        }
        return true
    }

    /// Текст без front matter (`MarkdownPresentationParser.frontMatter`).
    static func body(of note: String) -> String {
        guard let frontMatter = MarkdownPresentationParser.frontMatter(note) else { return note }
        var rest = (note as NSString).substring(from: NSMaxRange(frontMatter.range))
        // Конец строки закрывающего маркера в диапазон front matter не входит.
        if rest.hasPrefix("\r\n") { rest.removeFirst(2) } else if rest.hasPrefix("\n") || rest.hasPrefix("\r") { rest.removeFirst() }
        return rest
    }

    /// Раздел заметки: заголовок и всё до следующего заголовка того же или более высокого уровня. Заголовки ATX, строки внутри
    /// ограждённого кода пропускаются, сравнение через `MarkdownHeadingAnchors.slug(of:)`; `A#B` — берётся последний компонент.
    /// nil — раздел не найден; `#^id` всегда nil.
    static func section(of note: String, heading: String) -> String? {
        let wanted = heading.split(separator: "#", omittingEmptySubsequences: true).last.map(String.init) ?? heading
        let trimmed = wanted.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("^") else { return nil }
        let slug = MarkdownHeadingAnchors.slug(of: trimmed)
        let lines = note.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var fence: (character: Character, length: Int)?
        var startIndex: Int?
        var startLevel = 0
        for (index, line) in lines.enumerated() {
            if let marker = fenceMarker(line) {
                if let open = fence {
                    if marker.character == open.character, marker.length >= open.length, marker.isClosing { fence = nil }
                } else {
                    fence = (marker.character, marker.length)
                }
                continue
            }
            if fence != nil { continue }
            guard let atx = atxHeading(line) else { continue }
            if let startIndex {
                if atx.level <= startLevel { return lines[startIndex..<index].joined(separator: "\n") }
            } else if MarkdownHeadingAnchors.slug(of: atx.title) == slug {
                startIndex = index
                startLevel = atx.level
            }
        }
        guard let startIndex else { return nil }
        return lines[startIndex...].joined(separator: "\n")
    }

    private static func fenceMarker(_ line: String) -> (character: Character, length: Int, isClosing: Bool)? {
        let stripped = line.drop(while: { $0 == " " })
        guard line.count - stripped.count <= 3, let first = stripped.first, first == "`" || first == "~" else { return nil }
        let run = stripped.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let rest = stripped.dropFirst(run.count)
        // Закрывающий забор не имеет info-строки; у открывающего «`» в info-строке нельзя.
        if first == "`", rest.contains("`") { return nil }
        return (first, run.count, rest.allSatisfy { $0 == " " || $0 == "\t" })
    }

    private static func atxHeading(_ line: String) -> (level: Int, title: String)? {
        let stripped = line.drop(while: { $0 == " " })
        guard line.count - stripped.count <= 3 else { return nil }
        let hashes = stripped.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = stripped.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // Закрывающая последовательность `#`.
        if let last = title.lastIndex(where: { $0 != "#" }) {
            if last != title.index(before: title.endIndex), title[last] == " " || title[last] == "\t" {
                title = String(title[title.startIndex...last]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            title = ""
        }
        return (hashes.count, title)
    }

    struct Prepared {
        let text: String                       // число строк не изменилось
        let blocks: [Block]                    // встраивания-врезки
        let token: String                      // префикс подстановочных абзацев, уникальный для страницы
        struct Block { let marker: String; let item: MarkdownNoteEmbedItem }
    }

    /// До cmark: картинки/вложения → `![x](путь)` или курсивная подпись «Вложение недоступно»; блоки → абзац `token + номер`.
    /// Без провайдера блоки остаются текстом. Число строк не меняется.
    static func prepare(_ text: String, syntax: MarkdownSyntaxOptions, context: MarkdownWikiLinkContext?,
                        provider: (any MarkdownNoteEmbedProvider)?, documentURL: URL? = nil) -> Prepared {
        var token = "LACEMBED"
        var counter = 0
        while text.contains(token) { counter += 1; token = "LACEMBED\(counter)X" }
        guard mayContainEmbed(text) else { return Prepared(text: text, blocks: [], token: token) }
        let source = text as NSString
        let index = MarkdownPresentationParser.parse(text, syntax: syntax, isCancelled: { false }).elements
        guard index.textLength == source.length else { return Prepared(text: text, blocks: [], token: token) }
        let excluded = index.excludedRanges(intersecting: NSRange(location: 0, length: source.length))
        let found = items(in: source, excluded: excluded)
        guard !found.isEmpty else { return Prepared(text: text, blocks: [], token: token) }
        let address = documentURL ?? context?.documentURL
        var replacements: [(NSRange, String)] = []
        var blocks: [Prepared.Block] = []
        for item in found {
            switch item.kind {
            case .image, .attachment:
                replacements.append((item.range, fileReplacement(for: item, documentURL: address, base: context?.resolver.base)))
            case .note:
                guard item.isBlock, provider != nil else { continue }
                let marker = token + String(blocks.count) + "Z"
                blocks.append(Prepared.Block(marker: marker, item: item))
                replacements.append((item.range, marker))
            }
        }
        guard !replacements.isEmpty else { return Prepared(text: text, blocks: [], token: token) }
        let result = NSMutableString(string: text)
        for (range, value) in replacements.reversed() { result.replaceCharacters(in: range, with: value) }
        return Prepared(text: result as String, blocks: blocks, token: token)
    }

    private static let markdownSpecial: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "&", "~", "^", "$", "!", "|", "=", "#", "{", "}"]

    private static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            if markdownSpecial.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()[]<>\\ $:")
        return set
    }()

    /// Картинка или ссылка на существующий файл либо курсивная подпись «Вложение недоступно».
    private static func fileReplacement(for item: MarkdownNoteEmbedItem, documentURL: URL?, base: URL?) -> String {
        let name = (item.target as NSString).lastPathComponent
        if let href = existingFileHref(target: item.target, documentURL: documentURL, base: base) {
            return item.kind == .image ? "![\(escaped(name))](\(href))" : "[\(escaped(name))](\(href))"
        }
        return "*" + escaped(L10n.tr("附件不可用：%@", name)) + "*"
    }

    /// Относительный путь от каталога документа к существующему файлу: сначала рядом с документом, затем от корня.
    private static func existingFileHref(target: String, documentURL: URL?, base: URL?) -> String? {
        guard let documentURL, documentURL.isFileURL, !target.hasPrefix("/"), !target.hasPrefix("~"),
              !target.contains("\0"), !target.contains("\\"),
              !target.split(separator: "/").contains(where: { $0 == ".." }) else { return nil }
        let directory = documentURL.deletingLastPathComponent()
        func exists(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        let components = target.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        let nearby = components.reduce(directory) { $0.appendingPathComponent($1) }
        if exists(nearby) { return components.map { encoded($0) }.joined(separator: "/") }
        if let base {
            let file = components.reduce(base) { $0.appendingPathComponent($1) }
            if exists(file) { return relativePath(from: directory, to: file) }
        }
        return nil
    }

    private static func encoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? component
    }

    private static func relativePath(from directory: URL, to file: URL) -> String {
        let target = file.standardizedFileURL.pathComponents
        let from = directory.standardizedFileURL.pathComponents
        var common = 0
        while common < from.count, common < target.count - 1, from[common] == target[common] { common += 1 }
        let parts = Array(repeating: "..", count: from.count - common) + target[common...]
        return parts.map { $0 == ".." ? $0 : encoded($0) }.joined(separator: "/")
    }

    /// После cmark: заменяет `<p …>token N</p>` на врезку. Содержимое — вложенный
    /// `MarkdownRenderer.renderPage(embeds и wiki отключены, forExport: …)`, затем `flatten` (картинки → alt, без `id`).
    static func finalize(html: String, prepared: Prepared, context: MarkdownWikiLinkContext?,
                         provider: (any MarkdownNoteEmbedProvider)?, syntax: MarkdownSyntaxOptions,
                         darkMode: Bool, forExport: Bool, hidesComments: Bool = false) -> String {
        guard !prepared.blocks.isEmpty else { return html }
        var cache: [String: String?] = [:]
        var replacements: [(range: Range<String.Index>, html: String)] = []
        var totalBytes = 0
        for (number, block) in prepared.blocks.enumerated() {
            let item = block.item
            let outcome: Outcome
            if number >= maxEmbedsPerPage {
                outcome = .missingNote
            } else {
                let note: String?
                if let cached = cache[item.target] { note = cached } else {
                    var read = provider?.embeddedNote(for: item.target)
                    if let value = read {
                        let bytes = min(value.utf8.count, maxNoteBytes)
                        if totalBytes + bytes > maxTotalBytes { read = nil } else { totalBytes += bytes }
                    }
                    cache[item.target] = read
                    note = read
                }
                if let note {
                    var content = body(of: note)
                    var missingSection = false
                    if let heading = item.heading {
                        if let section = section(of: content, heading: heading) { content = section } else { missingSection = true }
                    }
                    if missingSection {
                        outcome = .missingSection
                    } else {
                        let (limited, wasCut) = limitedNote(content)
                        let page = MarkdownRenderer.renderPage(limited, darkMode: darkMode, syntax: syntax, forExport: forExport, wiki: nil, embeds: nil,
                                                         hidesObsidianComments: hidesComments)
                        outcome = .content(html: flatten(page.body), truncated: wasCut)
                    }
                } else {
                    outcome = .missingNote
                }
            }
            let href = provider?.openAddress(for: item.target, heading: item.heading)
                ?? context?.relativeHref(for: MarkdownWikiLink(range: NSRange(location: 0, length: 0), displayRange: NSRange(location: 0, length: 0),
                                                              target: item.target, heading: item.heading, alias: nil, markerRanges: []))
            let embedHTML = blockHTML(name: item.target, heading: item.heading, href: href, outcome: outcome)
            if let range = markerRange(block.marker, in: html) { replacements.append((range, embedHTML)) }
        }
        // Подстановка с конца по диапазонам исходного HTML: текст встроенных заметок маркер подменить не может.
        var result = html
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(replacement.range, with: replacement.html)
        }
        return result
    }

    /// Обрезка до `maxNoteBytes` по границе символа и строки.
    private static func limitedNote(_ value: String) -> (String, Bool) {
        guard value.utf8.count > maxNoteBytes else { return (value, false) }
        var count = maxNoteBytes
        var cut: String?
        while count > 0, cut == nil {
            cut = String(value.utf8.prefix(count))
            if cut == nil { count -= 1 }
        }
        var text = cut ?? ""
        if let newline = text.lastIndex(where: { $0 == "\n" }) { text = String(text[text.startIndex..<newline]) }
        return (text, true)
    }

    /// Диапазон абзаца-подстановки (с атрибутами или без) в исходном HTML; если маркер не в абзаце — только сам маркер.
    private static func markerRange(_ marker: String, in source: String) -> Range<String.Index>? {
        guard let markerRange = source.range(of: marker) else { return nil }
        let before = source[source.startIndex..<markerRange.lowerBound]
        if let tagStart = before.range(of: "<p", options: .backwards),
           let tagEnd = source.range(of: ">", range: tagStart.upperBound..<source.endIndex),
           tagEnd.upperBound == markerRange.lowerBound,
           source[tagStart.upperBound...].hasPrefix(">") || source[tagStart.upperBound...].hasPrefix(" "),
           source[markerRange.upperBound...].hasPrefix("</p>") {
            return tagStart.lowerBound..<source.index(markerRange.upperBound, offsetBy: 4)
        }
        return markerRange
    }

    /// HTML врезки по готовому телу или причине отсутствия.
    enum Outcome { case content(html: String, truncated: Bool), missingNote, missingSection }

    static func blockHTML(name: String, heading: String?, href: String?, outcome: Outcome) -> String {
        let displayName = heading.map { name + " › " + $0 } ?? name
        let escapedDisplay = htmlEscaped(displayName)
        switch outcome {
        case .missingNote:
            let message = htmlEscaped(L10n.tr("未找到笔记：%@", name))
            return "<section class=\"lac-embed lac-embed-missing\" role=\"group\" aria-label=\"\(message)\"><p class=\"lac-embed-note\">\(message)</p></section>"
        case .missingSection:
            let message = htmlEscaped(L10n.tr("未找到章节：%@", displayName))
            return "<section class=\"lac-embed lac-embed-missing\" role=\"group\" aria-label=\"\(message)\"><p class=\"lac-embed-note\">\(message)</p></section>"
        case let .content(body, truncated):
            let open = href.map {
                "<a class=\"lac-embed-open\" href=\"\(htmlEscaped($0))\" aria-label=\"\(htmlEscaped(L10n.tr("打开笔记：%@", name)))\">\(htmlEscaped(L10n.tr("打开")))</a>"
            } ?? ""
            let note = truncated ? "<p class=\"lac-embed-note\">\(htmlEscaped(L10n.tr("嵌入内容已截断")))</p>" : ""
            return "<section class=\"lac-embed\" role=\"group\" aria-label=\"\(htmlEscaped(L10n.tr("嵌入的笔记：%@", name)))\">"
                + "<div class=\"lac-embed-head\"><span class=\"lac-embed-name\">\(escapedDisplay)</span>\(open)</div>"
                + "<div class=\"lac-embed-body\">\(body)</div>\(note)</section>"
        }
    }

    private static func htmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Картинки → подпись `alt`, `id` убираются: во встроенной заметке нет ни файлов другого документа, ни своих якорей.
    static func flatten(_ html: String) -> String {
        var result = html
        if let images = try? NSRegularExpression(pattern: "<img\\b[^>]*?\\balt=\"([^\"]*)\"[^>]*>") {
            result = images.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "$1")
        }
        if let bare = try? NSRegularExpression(pattern: "<img\\b[^>]*>") {
            result = bare.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        if let ids = try? NSRegularExpression(pattern: " id=\"[^\"]*\"") {
            result = ids.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        return result
    }
}
