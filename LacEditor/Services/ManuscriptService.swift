import Foundation

/// Склейка Markdown-файлов в один текст: разделители, front matter, абсолютные адреса, проверка меток сносок.
enum ManuscriptService {
    struct Part: Equatable, Sendable {
        let file: FolderSearchService.File
        let text: String
    }

    struct Report: Equatable, Sendable {
        var mergedFiles = 0
        /// Не прочитано (сюда же добавляет читатель).
        var skipped: [FolderSearchService.Problem] = []
        /// Относительные адреса, которые не удалось подтверждённо перевести в абсолютные.
        var unconvertedAddresses = 0
        /// Относительные пути файлов, где не подтвердилась запись изображений.
        var filesWithoutImageCheck: [String] = []
        var duplicateFootnoteLabels: [String] = []
        /// В метаданных первого файла задан `typora-root-url`.
        var blockedByRootURL = false
        var hasNotes: Bool { !skipped.isEmpty || unconvertedAddresses > 0 || !filesWithoutImageCheck.isEmpty
            || !duplicateFootnoteLabels.isEmpty || blockedByRootURL }
    }

    struct Output: Equatable, Sendable {
        let text: String
        let report: Report
    }

    struct Prepared: Equatable, Sendable {
        let text: String
        let footnoteLabels: [String]
        let unconverted: Int
        let imageCheckFailed: Bool
    }

    enum Rewrite: Equatable { case unchanged, converted(String), unconfirmed }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()[]<>\\ /$:&\"'*~")
        return set
    }()

    private static let unsafeInPath = CharacterSet(charactersIn: " ()[]<>\\%#?&\"'|`{}^*~")

    /// HTML-ссылки и медиа; `<img>` разбирает `MarkdownImageUploadService`.
    private static let htmlAddress = try? NSRegularExpression(
        pattern: "<(?:a|audio|video|source)\\b[^<>]*?\\s(?:href|src)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'<>]+))",
        options: .caseInsensitive)

    /// Не-ASCII остаётся читаемым: `addingPercentEncoding` такие символы в разрешённом наборе не учитывает.
    private static func encodedComponent(_ part: String) -> String {
        var result = ""
        for scalar in part.unicodeScalars {
            let text = String(scalar)
            result += scalar.isASCII ? (text.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? text) : text
        }
        return result
    }

    /// Текст без ведущего BOM; по единицам UTF-16, а не по `Character`.
    private static func strippingBOM(_ text: String) -> String {
        text.utf16.first == 0xFEFF ? (text as NSString).substring(from: 1) : text
    }

    private static func resourcePaths(of text: String, document: URL) -> MarkdownResourcePaths? {
        try? MarkdownResourcePaths(text: text, document: document)
    }

    static func merge(_ parts: [Part], skipped: [FolderSearchService.Problem], syntax: MarkdownSyntaxOptions,
                      isCancelled: () -> Bool = { false }) throws -> Output {
        var report = Report()
        report.skipped = skipped
        if isCancelled() { throw CancellationError() }
        // Front matter остаётся у первой непустой части, её же `typora-root-url` влияет на все адреса результата.
        let firstIndex = parts.firstIndex { !strippingBOM($0.text).isEmpty }
        var convertsAddresses = true
        if let firstIndex, resourcePaths(of: strippingBOM(parts[firstIndex].text), document: parts[firstIndex].file.url)?.root != nil {
            convertsAddresses = false
            report.blockedByRootURL = true
        }
        var texts: [String] = []
        var labelCounts: [String: Int] = [:]
        var labelOrder: [(folded: String, name: String)] = []
        for (index, part) in parts.enumerated() {
            if isCancelled() { throw CancellationError() }
            let prepared = try prepare(part, isFirst: index == firstIndex, convertsAddresses: convertsAddresses,
                                       syntax: syntax, isCancelled: isCancelled)
            guard !prepared.text.isEmpty else { continue }
            texts.append(prepared.text)
            report.unconvertedAddresses += prepared.unconverted
            if prepared.imageCheckFailed { report.filesWithoutImageCheck.append(part.file.relativePath) }
            for label in prepared.footnoteLabels {
                let folded = label.lowercased()
                if labelCounts[folded] == nil { labelOrder.append((folded, label)) }
                labelCounts[folded, default: 0] += 1
            }
        }
        report.mergedFiles = texts.count
        report.duplicateFootnoteLabels = labelOrder.filter { (labelCounts[$0.folded] ?? 0) >= 2 }.map(\.name)
        return Output(text: join(texts), report: report)
    }

    /// `isFirst` сохраняет front matter; `convertsAddresses == false` пропускает адреса.
    static func prepare(_ part: Part, isFirst: Bool, convertsAddresses: Bool, syntax: MarkdownSyntaxOptions,
                        isCancelled: () -> Bool) throws -> Prepared {
        let text = strippingBOM(part.text)
        let source = text as NSString
        var edits: [FolderReplaceService.Edit] = []
        var frontMatterEdit: FolderReplaceService.Edit?
        var unconverted = 0
        var imageCheckFailed = false
        // Удаляется только подтверждённый front matter: структура и корректный YAML-отображение (или пустой YAML).
        var frontMatterEnd = 0
        if !isFirst, let block = MarkdownPresentationParser.frontMatter(text) {
            var isConfirmed = true
            do { _ = try PandocExportService.yamlFrontMatter(text) } catch { isConfirmed = false }
            if isConfirmed {
                var end = NSMaxRange(block.range)
                if end < source.length {
                    let unit = source.character(at: end)
                    if unit == 13 { end += end + 1 < source.length && source.character(at: end + 1) == 10 ? 2 : 1 }
                    else if unit == 10 { end += 1 }
                }
                frontMatterEnd = end
                let range = NSRange(location: 0, length: end)
                frontMatterEdit = .init(range: range, original: source.substring(with: range), replacement: "")
            }
        }
        // разбор принимает замыкание отмены как escaping, но не сохраняет его после возврата
        let presentation = withoutActuallyEscaping(isCancelled) {
            MarkdownPresentationParser.parse(text, syntax: syntax, isCancelled: $0)
        }
        if isCancelled() { throw CancellationError() }
        var labels: [String] = []
        var seenLabels: Set<String> = []
        var seenDefinitions: Set<Int> = []
        for footnote in presentation.footnotes {
            let range = footnote.definitionRange
            guard range.location >= 0, range.length >= 4, NSMaxRange(range) <= source.length,
                  seenDefinitions.insert(range.location).inserted else { continue }
            let marker = source.substring(with: range)
            guard marker.hasPrefix("[^"), marker.hasSuffix("]:") else { continue }
            let label = (marker as NSString).substring(with: NSRange(location: 2, length: range.length - 4))
            if seenLabels.insert(label.lowercased()).inserted { labels.append(label) }
        }
        if convertsAddresses {
            let paths = resourcePaths(of: text, document: part.file.url)
            func countIfRelative(_ raw: String) {
                if rewrite(path: raw, from: part.file.url, paths: paths) != .unchanged { unconverted += 1 }
            }
            func addEdit(raw: String, range: NSRange, isLink: Bool) {
                let path = split(raw).path
                switch rewrite(path: raw, from: part.file.url, paths: paths, checksNavigation: isLink) {
                case .unchanged: break
                case .unconfirmed: unconverted += 1
                case let .converted(new):
                    edits.append(.init(range: NSRange(location: range.location, length: (path as NSString).length),
                                       original: path, replacement: new))
                }
            }
            func isPlain(_ raw: String) -> Bool { !raw.contains("\\") && !raw.contains("&") }

            var images: [MarkdownImageUploadService.Image] = []
            do {
                images = try withoutActuallyEscaping(isCancelled) { try MarkdownImageUploadService.images(in: text, isCancelled: $0) }
            } catch is CancellationError { throw CancellationError() }
            catch { imageCheckFailed = true }
            if isCancelled() { throw CancellationError() }
            for image in images {
                let isQuoted: Bool
                switch image.syntax {
                case .markdown: isQuoted = true
                case let .html(quote): isQuoted = quote != nil
                case .reference: isQuoted = false
                }
                let range = image.addressRange
                if isQuoted, image.rawAddress == image.address, isPlain(image.rawAddress),
                   range.location >= 0, NSMaxRange(range) <= source.length,
                   source.substring(with: range) == image.rawAddress {
                    addEdit(raw: image.rawAddress, range: range, isLink: false)
                } else {
                    countIfRelative(image.rawAddress)
                }
            }

            var tails: [NSRange: NSRange] = [:]
            for span in presentation.spans where span.kind == .link && span.markerRanges.count == 2 { tails[span.range] = span.markerRanges[1] }
            for link in presentation.links {
                if isCancelled() { throw CancellationError() }
                if let tail = tails[link.range], tail.location >= 0, tail.length >= 3, NSMaxRange(tail) <= source.length,
                   source.substring(with: NSRange(location: tail.location, length: 2)) == "](",
                   source.character(at: NSMaxRange(tail) - 1) == 41,
                   let (rawRange, _) = MarkdownRenameLinkService.rawDestination(in: source, tail: tail),
                   source.substring(with: rawRange) == link.url, isPlain(link.url) {
                    addEdit(raw: link.url, range: rawRange, isLink: true)
                } else {
                    countIfRelative(link.url)
                }
            }
            // Не переписываются, только считаются; теги внутри блоков кода тоже попадают в счёт.
            htmlAddress?.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
                guard let match else { return }
                for group in 1...3 where match.range(at: group).location != NSNotFound {
                    countIfRelative(source.substring(with: match.range(at: group)))
                }
            }
        }
        var kept: [FolderReplaceService.Edit] = frontMatterEdit.map { [$0] } ?? []
        let candidates = edits.filter { $0.original != $0.replacement && $0.range.location >= frontMatterEnd }
            .sorted { $0.range.location < $1.range.location }
        for edit in candidates {
            if let last = kept.last, NSMaxRange(last.range) > edit.range.location { unconverted += 1; continue }
            kept.append(edit)
        }
        guard let result = FolderReplaceService.apply(kept, to: text) else {
            assertionFailure("Правки рукописи не совпали с текстом")
            return Prepared(text: text, footnoteLabels: labels, unconverted: unconverted + kept.count, imageCheckFailed: imageCheckFailed)
        }
        return Prepared(text: result, footnoteLabels: labels, unconverted: unconverted, imageCheckFailed: imageCheckFailed)
    }

    /// Путь до первого `#`/`?` и суффикс, который остаётся дословно.
    private static func split(_ raw: String) -> (path: String, suffix: String) {
        let text = raw as NSString
        let found = text.rangeOfCharacter(from: CharacterSet(charactersIn: "#?"))
        guard found.location != NSNotFound else { return (raw, "") }
        return (text.substring(to: found.location), text.substring(from: found.location))
    }

    /// `raw` — сырой адрес (без `<>`), `file` — файл-источник, `paths` — `typora-root-url` этого файла.
    static func rewrite(path raw: String, from file: URL, paths: MarkdownResourcePaths?,
                        checksNavigation: Bool = false) -> Rewrite {
        guard !raw.isEmpty, !raw.hasPrefix("#"), !raw.hasPrefix("//"),
              raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { return .unchanged }
        let (pathPart, suffix) = split(raw)
        guard !pathPart.isEmpty else { return .unchanged }
        let target: String
        if pathPart.hasPrefix("/") {
            guard paths?.root != nil else { return .unchanged }
            guard let resolved = paths?.resolve(pathPart), resolved.isFileURL else { return .unconfirmed }
            target = resolved.standardizedFileURL.path
        } else {
            guard let decoded = pathPart.removingPercentEncoding, !decoded.contains("\0") else { return .unconfirmed }
            let directory = file.standardizedFileURL.deletingLastPathComponent()
            target = URL(fileURLWithPath: decoded, relativeTo: directory).standardizedFileURL.path
            // Так относительный адрес разрешает приложение.
            guard URL(string: pathPart, relativeTo: directory)?.absoluteURL.standardizedFileURL.path == target else { return .unconfirmed }
        }
        let components = target.split(separator: "/").map(String.init).map { part -> String in
            let needs = part.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || unsafeInPath.contains($0) }
            return needs ? encodedComponent(part) : part
        }
        let new = "/" + components.joined(separator: "/")
        guard URL(string: new, relativeTo: URL(fileURLWithPath: "/"))?.absoluteURL.path == target else { return .unconfirmed }
        if checksNavigation {
            guard case let .file(url, fragment)? = try? MarkdownLinkNavigationService.destination(for: new + suffix, documentURL: nil),
                  case let .file(_, oldFragment)? = try? MarkdownLinkNavigationService.destination(for: raw, documentURL: file),
                  url.path == target, fragment == oldFragment else { return .unconfirmed }
        }
        return .converted(new)
    }

    /// Перевод строки по последнему `\r`/`\n` в тексте: стык продолжает конец предыдущей части.
    static func lineEnding(of text: String) -> String {
        let source = text as NSString
        var index = source.length
        while index > 0 {
            index -= 1
            let unit = source.character(at: index)
            if unit == 10 { return index > 0 && source.character(at: index - 1) == 13 ? "\r\n" : "\n" }
            if unit == 13 { return "\r" }
        }
        return "\n"
    }

    /// Между частями ровно одна пустая строка (больше, если она уже была в файлах); конец последней части не трогается.
    static func join(_ texts: [String]) -> String {
        var result = ""
        for (index, text) in texts.enumerated() {
            if index > 0 {
                let previous = texts[index - 1]
                result += String(repeating: lineEnding(of: previous), count: max(0, 2 - trailingBreaks(previous)))
            }
            result += text
        }
        return result
    }

    /// Число завершающих переводов строки; `\r\n` — один.
    private static func trailingBreaks(_ text: String) -> Int {
        let source = text as NSString
        var index = source.length
        var count = 0
        while index > 0 {
            let unit = source.character(at: index - 1)
            if unit == 10 {
                index -= 1
                if index > 0, source.character(at: index - 1) == 13 { index -= 1 }
            } else if unit == 13 {
                index -= 1
            } else { break }
            count += 1
        }
        return count
    }
}
