import Foundation

/// Находит в тексте Markdown-файла ссылки на заданный документ: разрешённые wiki-ссылки и обычные ссылки.
/// Сначала дешёвая проверка по имени файла, затем подтверждение общим cmark-разбором.
enum MarkdownBacklinkScanner {
    /// Имя цели без расширения: как есть, в канонически составленной форме (NFC) и в виде, закодированном для адреса (пробелы, кириллица).
    static func needles(for target: FolderSearchService.BacklinkTarget) -> [String] {
        let stem = (target.url.lastPathComponent as NSString).deletingPathExtension
        guard !stem.isEmpty else { return [] }
        var result: [String] = []
        for value in [stem, stem.precomposedStringWithCanonicalMapping] {
            for needle in [value, value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value] where !result.contains(needle) {
                result.append(needle)
            }
        }
        return result
    }

    /// Без учёта регистра и с канонической эквивалентностью Unicode (NFC/NFD имён файлов macOS).
    static func mayLink(_ text: NSString, needles: [String]) -> Bool {
        needles.contains { text.range(of: $0, options: [.caseInsensitive]).location != NSNotFound }
    }

    /// Диапазоны UTF-16 ссылок на цель по возрастанию. `targetPath` — путь цели в `resolver`; адрес обычной ссылки разрешается от каталога файла `file`.
    static func ranges(in text: String, file: FolderSearchService.File, target: FolderSearchService.BacklinkTarget,
                       targetPath: String, resolver: MarkdownWikiLinkResolver, needles: [String], isCancelled: () -> Bool) throws -> [NSRange] {
        if isCancelled() { throw CancellationError() }
        guard mayLink(text as NSString, needles: needles) else { return [] }
        // разбор принимает замыкание отмены как escaping, но не сохраняет его после возврата
        let presentation = withoutActuallyEscaping(isCancelled) {
            MarkdownPresentationParser.parse(text, includeWikiLinks: true, syntax: target.syntax, isCancelled: $0)
        }
        if isCancelled() { throw CancellationError() }
        var result: [NSRange] = []
        for link in presentation.wikiLinks {
            if isCancelled() { throw CancellationError() }
            // пустая цель (`[[#Заголовок]]`) разрешается в текущий файл и сюда не попадает
            if resolver.resolve(target: link.target) == .file(targetPath) { result.append(link.range) }
        }
        for link in presentation.links {
            if isCancelled() { throw CancellationError() }
            if isLink(link.url, from: file.url, to: target) { result.append(link.range) }
        }
        return Array(Set(result)).sorted { $0.location < $1.location }
    }

    /// Файловый адрес без расширения проверяется как `.md` и `.markdown`, как при переходе по ссылке; `#якорь` того же файла не считается.
    static func isLink(_ address: String, from documentURL: URL, to target: FolderSearchService.BacklinkTarget) -> Bool {
        guard case let .file(url, _)? = try? MarkdownLinkNavigationService.destination(for: address, documentURL: documentURL) else { return false }
        var candidates = [url]
        if url.pathExtension.isEmpty { candidates += [url.appendingPathExtension("md"), url.appendingPathExtension("markdown")] }
        let targetPath = target.url.standardizedFileURL.path as NSString
        return candidates.contains { candidate in
            targetPath.compare(candidate.standardizedFileURL.path, options: [.caseInsensitive]) == .orderedSame &&
                DocumentFileIdentity.resolve(candidate).matches(target.identity)
        }
    }
}
