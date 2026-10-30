import Foundation

/// Чистое разрешение цели wiki-ссылки по списку относительных путей Markdown-файлов. Диск не читает.
/// База — корень рабочей папки либо каталог документа (если папка не открыта); пути разделены «/».
struct MarkdownWikiLinkResolver: Equatable, Sendable {
    enum Resolution: Equatable, Sendable {
        /// Пустая цель: `[[#Заголовок]]`.
        case currentDocument
        /// Единственное совпадение: относительный путь внутри базы.
        case file(String)
        /// Несколько совпадений (отсортированы); ближайший файл не выбирается.
        case ambiguous([String])
        /// Файла нет; предлагаемый относительный путь с расширением `.md`.
        case missing(String)
        /// Нечем или нельзя разрешать: нет базы, `..`, абсолютный путь, пустой компонент.
        case invalid
    }

    let base: URL?
    let paths: [String]
    /// Поколение каталога: меняется, когда набор путей или база изменились.
    let token: UInt
    private let byPath: [String: [Int]]
    private let byName: [String: [Int]]

    init(base: URL?, paths: [String], token: UInt = 0) {
        self.base = base
        self.paths = paths
        self.token = token
        var byPath: [String: [Int]] = [:], byName: [String: [Int]] = [:]
        func add(_ key: String, _ index: Int, to map: inout [String: [Int]]) {
            if map[key]?.contains(index) != true { map[key, default: []].append(index) }
        }
        for (index, path) in paths.enumerated() {
            let stemPath = Self.strippingMarkdownExtension(path)
            let name = (path as NSString).lastPathComponent
            let stem = (stemPath as NSString).lastPathComponent
            add(Self.fold(path), index, to: &byPath)
            add(Self.fold(stemPath), index, to: &byPath)
            add(Self.fold(name), index, to: &byName)
            add(Self.fold(stem), index, to: &byName)
        }
        self.byPath = byPath
        self.byName = byName
    }

    static func == (lhs: MarkdownWikiLinkResolver, rhs: MarkdownWikiLinkResolver) -> Bool {
        lhs.base == rhs.base && lhs.token == rhs.token && lhs.paths == rhs.paths
    }

    static func fold(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }

    /// База разрешения: корень папки либо каталог сохранённого документа; иначе nil.
    static func base(root: URL?, documentURL: URL?) -> URL? {
        if let root { return URL(fileURLWithPath: root.standardizedFileURL.path) }
        guard let documentURL, documentURL.isFileURL else { return nil }
        return URL(fileURLWithPath: documentURL.deletingLastPathComponent().standardizedFileURL.path)
    }

    private static func strippingMarkdownExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? (path as NSString).deletingPathExtension : path
    }

    private static func isValidPath(_ value: String) -> Bool {
        guard !value.hasPrefix("/"), !value.hasPrefix("~"),
              !value.unicodeScalars.contains(where: { $0 == "\\" || $0 == "\0" }) else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Цель с «/» или с ведущим «./» сравнивается с путём от базы, остальные — с именем файла.
    private func indices(for value: String) -> [Int] {
        let forcePath = value.hasPrefix("./")
        let stripped = forcePath ? String(value.dropFirst(2)) : value
        let key = Self.fold(stripped)
        return ((forcePath || stripped.contains("/")) ? byPath[key] : byName[key]) ?? []
    }

    func resolve(target: String) -> Resolution {
        if target.isEmpty { return .currentDocument }
        let value = target.hasPrefix("./") ? String(target.dropFirst(2)) : target
        guard base != nil, Self.isValidPath(value) else { return .invalid }
        let found = indices(for: target)
        if found.count == 1 { return .file(paths[found[0]]) }
        if found.count > 1 { return .ambiguous(found.map { paths[$0] }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }) }
        let ext = (value as NSString).pathExtension.lowercased()
        return .missing(ext == "md" || ext == "markdown" ? value : value + ".md")
    }

    /// Адрес файла внутри базы; nil при недопустимом пути.
    func url(for relativePath: String) -> URL? {
        guard let base, Self.isValidPath(relativePath) else { return nil }
        var url = base
        for component in relativePath.split(separator: "/") { url.appendPathComponent(String(component)) }
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/") else { return nil }
        return url
    }

    /// Подсказки для вставки после `[[`: файл подходит, если с префикса (без учёта регистра) начинается его имя или путь;
    /// показывается кратчайшая форма, которая разрешается ровно в этот файл. Порядок естественный; без префикса — все имена.
    func completions(prefix: String) -> [String] {
        let needle = Self.fold(prefix)
        var seen = Set<String>(), result: [String] = []
        for (index, path) in paths.enumerated() {
            let stemPath = Self.strippingMarkdownExtension(path)
            let candidates = [(stemPath as NSString).lastPathComponent, stemPath, (path as NSString).lastPathComponent, path, "./" + stemPath, "./" + path]
            guard needle.isEmpty || candidates.contains(where: { Self.fold($0).hasPrefix(needle) }),
                  let value = candidates.first(where: { candidate in !candidate.contains(where: { "#|[]".contains($0) }) && indices(for: candidate) == [index] }) else { continue }
            if seen.insert(value).inserted { result.append(value) }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Что нужно предпросмотру и экспорту: каталог путей и адрес сохранённого документа.
/// Откуда экспорту брать список файлов: папка окна (если открыта) и адрес документа.
struct MarkdownWikiLinkSource: Equatable, Sendable {
    let root: URL?
    let documentURL: URL?
}

struct MarkdownWikiLinkContext: Equatable, Sendable {
    let resolver: MarkdownWikiLinkResolver
    let documentURL: URL?

    /// Читает диск заново: корень — все `.md/.markdown` папки (символические каталоги не обходятся),
    /// без папки — только файлы каталога сохранённого документа.
    static func load(root: URL?, documentURL: URL?, isCancelled: () -> Bool = { false }) throws -> MarkdownWikiLinkContext {
        if let root {
            let result = try FolderSearchService.markdownFiles(root: root, isCancelled: isCancelled)
            return MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: result.root, paths: result.values.map(\.relativePath)), documentURL: documentURL)
        }
        guard let base = MarkdownWikiLinkResolver.base(root: nil, documentURL: documentURL) else {
            return MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: nil, paths: []), documentURL: documentURL)
        }
        if isCancelled() { throw CancellationError() }
        let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        var paths: [String] = []
        for child in children {
            if isCancelled() { throw CancellationError() }
            guard ["md", "markdown"].contains(child.pathExtension.lowercased()) else { continue }
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true || values?.isSymbolicLink == true { paths.append(child.lastPathComponent) }
        }
        return MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: base, paths: paths), documentURL: documentURL)
    }

    /// Адрес для существующего перехода по Markdown-ссылке: `file:///…#slug` либо `#slug`.
    func fileAddress(for link: MarkdownWikiLink) -> (resolution: MarkdownWikiLinkResolver.Resolution, address: String?) {
        let resolution = resolver.resolve(target: link.target)
        let fragment = link.heading.map { Self.encoded(MarkdownHeadingAnchors.slug(of: $0), allowed: Self.fragmentAllowed) }
        switch resolution {
        case .currentDocument:
            return (resolution, fragment.map { "#" + $0 })
        case let .file(path), let .missing(path):
            guard let url = resolver.url(for: path) else { return (resolution, nil) }
            return (resolution, url.absoluteString + (fragment.map { "#" + $0 } ?? ""))
        case .ambiguous, .invalid:
            return (resolution, nil)
        }
    }

    /// Адрес для HTML и экспорта: путь от каталога сохранённого документа; nil — ссылку нельзя построить.
    func relativeHref(for link: MarkdownWikiLink) -> String? {
        let fragment = link.heading.map { "#" + Self.encoded(MarkdownHeadingAnchors.slug(of: $0), allowed: Self.fragmentAllowed) } ?? ""
        switch resolver.resolve(target: link.target) {
        case .currentDocument:
            return fragment.isEmpty ? nil : fragment
        case let .file(path):
            guard let documentURL, documentURL.isFileURL, let file = resolver.url(for: path) else { return nil }
            let target = file.standardizedFileURL.pathComponents
            let directory = documentURL.deletingLastPathComponent().standardizedFileURL.pathComponents
            var common = 0
            while common < directory.count, common < target.count - 1, directory[common] == target[common] { common += 1 }
            let parts = Array(repeating: "..", count: directory.count - common) + target[common...]
            return parts.map { $0 == ".." ? $0 : Self.encoded($0, allowed: Self.pathAllowed) }.joined(separator: "/") + fragment
        case .ambiguous, .missing, .invalid:
            return nil
        }
    }

    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "()[]<>\\ /$:")
        return set
    }()

    private static let fragmentAllowed: CharacterSet = {
        var set = CharacterSet.urlFragmentAllowed
        set.remove(charactersIn: "()[]<>\\ /$:")
        return set
    }()

    private static func encoded(_ value: String, allowed: CharacterSet) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Подставляет вместо `[[…]]` обычную ссылку (или просто текст) в снимке для предпросмотра и экспорта.
/// Число строк не меняется: в диапазоне ссылки нет переводов строк.
enum MarkdownWikiLinkRewriter {
    static func replacements(links: [MarkdownWikiLink], context: MarkdownWikiLinkContext, in text: NSString,
                             isCancelled: () -> Bool = { false }) -> [(NSRange, String)] {
        var result: [(NSRange, String)] = []
        var cache: [String: String?] = [:]
        for link in links {
            if isCancelled() { return [] }
            guard link.range.location >= 0, NSMaxRange(link.range) <= text.length, link.range.length >= 4,
                  NSLocationInRange(link.displayRange.location, link.range), NSMaxRange(link.displayRange) <= NSMaxRange(link.range),
                  text.substring(with: NSRange(location: link.range.location, length: 2)) == "[[",
                  text.substring(with: NSRange(location: NSMaxRange(link.range) - 2, length: 2)) == "]]" else { continue }
            let display = text.substring(with: link.displayRange)
            let key = link.target + "#" + (link.heading ?? "")
            let href: String?
            if let cached = cache[key] { href = cached } else {
                href = context.relativeHref(for: link)
                cache[key] = href
            }
            result.append((link.range, href.map { "[" + escaped(display) + "](" + $0 + ")" } ?? display))
        }
        return result
    }

    static func rewrite(_ markdown: String, links: [MarkdownWikiLink], context: MarkdownWikiLinkContext,
                        isCancelled: () -> Bool = { false }) -> String {
        guard !links.isEmpty else { return markdown }
        let text = markdown as NSString
        let items = replacements(links: links, context: context, in: text, isCancelled: isCancelled)
        if isCancelled() { return markdown }
        let result = NSMutableString(string: markdown)
        for (range, value) in items.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: value)
        }
        return result as String
    }

    private static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            if "\\`*_[]<>&~^$!|=#{}".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
