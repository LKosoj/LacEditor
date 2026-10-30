import Foundation

enum FolderSearchService {
    struct IdentityLookup {
        private var paths: [String: [Int]] = [:]
        private var missingIDsByPath: [String: [Int]] = [:]
        private var resources: [String: [Int]] = [:]

        mutating func insert(_ identity: DocumentFileIdentity, value: Int) {
            paths[identity.canonicalPath, default: []].append(value)
            if let resource = identity.resourceIdentifier { resources[resource, default: []].append(value) }
            else { missingIDsByPath[identity.canonicalPath, default: []].append(value) }
        }

        func matches(_ identity: DocumentFileIdentity) -> [Int] {
            if let resource = identity.resourceIdentifier {
                return (resources[resource] ?? []) + (missingIDsByPath[identity.canonicalPath] ?? [])
            }
            return paths[identity.canonicalPath] ?? []
        }
    }
    struct OpenDocument: Sendable {
        let url: URL
        let identity: DocumentFileIdentity
        let snapshot: DocumentTextSnapshot
    }

    struct File: Equatable, Sendable {
        let url: URL
        let relativePath: String
    }

    struct ListedFile: Sendable {
        let file: File
        let isSymbolicLink: Bool
        let creationDate: Date?
        let modificationDate: Date?
    }

    static func listing(root: URL, isCancelled: () -> Bool = { false }) throws -> Result<ListedFile> {
        let root = normalized(root)
        let result = try enumerate(root: root, includeMetadata: true, isCancelled: isCancelled)
        return Result(root: root, values: result.listedFiles, problems: result.problems)
    }

    /// Markdown-файлы папки для разрешения wiki-ссылок; без метаданных и без индекса.
    static func markdownFiles(root: URL, isCancelled: () -> Bool = { false }) throws -> Result<File> {
        let root = normalized(root)
        let listing = try enumerate(root: root, isCancelled: isCancelled)
        let files = listing.files.filter { ["md", "markdown"].contains($0.url.pathExtension.lowercased()) }
        try checkCancellation(isCancelled)
        return Result(root: root, values: files, problems: listing.problems)
    }

    enum ProblemReason: Equatable, Sendable {
        case inaccessible, symbolicLink, invalidUTF8, changed, conflictingOpenDocuments, invalidTags
    }

    struct Problem: Equatable, Sendable {
        let url: URL
        let reason: ProblemReason
    }

    enum Source: Equatable, Sendable {
        case open(documentID: UUID, revision: UInt, identity: DocumentFileIdentity)
        case disk(FileRevisionSnapshot)
    }

    struct Match: Equatable, Sendable {
        let file: File
        let range: NSRange
        let matchedText: String
        let contextRange: NSRange
        let context: String
        let source: Source

        var key: MatchKey { MatchKey(url: file.url, location: range.location, length: range.length) }
    }

    /// Ключ совпадения для выбора флажками и предпросмотра замены.
    struct MatchKey: Hashable, Sendable {
        let url: URL
        let location: Int
        let length: Int
    }

    struct Result<Value: Sendable>: Sendable {
        let root: URL
        let values: [Value]
        let problems: [Problem]
    }

    static func files(root: URL, query: String, caseSensitive: Bool,
                      isCancelled: () -> Bool = { false }) throws -> Result<File> {
        let root = normalized(root)
        try checkCancellation(isCancelled)
        guard !query.isEmpty else { return Result(root: root, values: [], problems: []) }
        let listing = try enumerate(root: root, isCancelled: isCancelled)
        let matcher = NameQuery(query, caseSensitive: caseSensitive)
        var files: [(file: File, rank: Int)] = []
        for file in listing.files {
            try checkCancellation(isCancelled)
            if let rank = try matcher.rank(path: file.relativePath, name: file.url.lastPathComponent, isCancelled: isCancelled) {
                files.append((file, rank))
            }
        }
        try checkCancellation(isCancelled)
        files.sort { $0.rank == $1.rank ? fileOrder($0.file, $1.file) : $0.rank < $1.rank }
        try checkCancellation(isCancelled)
        return Result(root: root, values: files.map(\.file), problems: listing.problems)
    }

    struct NameQuery {
        private let query: String
        private let caseSensitive: Bool
        private let needle: [Character]

        init(_ query: String, caseSensitive: Bool) {
            self.query = caseSensitive ? query : query.lowercased()
            self.caseSensitive = caseSensitive
            needle = Array(self.query)
        }

        func rank(path: String, name: String, isCancelled: () -> Bool = { false }) throws -> Int? {
            try FolderSearchService.checkCancellation(isCancelled)
            guard !needle.isEmpty else { return 0 }
            let name = caseSensitive ? name : name.lowercased()
            if name == query { return 0 }
            let path = caseSensitive ? path : path.lowercased()
            let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            if (path as NSString).range(of: query, options: options).location != NSNotFound { return 1 }
            var next = 0
            for character in path {
                try FolderSearchService.checkCancellation(isCancelled)
                if character == needle[next] {
                    next += 1
                    if next == needle.count { return 2 }
                }
            }
            return nil
        }
    }

    enum SearchKind { case text, tags }

    /// Документ, на который ищутся обратные ссылки: сам он среди источников не просматривается.
    struct BacklinkTarget: Equatable, Sendable {
        let url: URL
        let identity: DocumentFileIdentity
        let syntax: MarkdownSyntaxOptions
    }

    /// Обратные ссылки: разрешённые wiki-ссылки и обычные Markdown-ссылки на `target` в `.md/.markdown` папки.
    static func backlinks(root: URL, target: BacklinkTarget, openDocuments: [OpenDocument],
                          isCancelled: () -> Bool = { false }) throws -> Result<Match> {
        let root = normalized(root)
        try checkCancellation(isCancelled)
        let targetURL = normalized(target.url)
        guard let targetPath = relativePath(targetURL, root: root) else { return Result(root: root, values: [], problems: []) }
        let needles = MarkdownBacklinkScanner.needles(for: target)
        var prepared: (targetPath: String, resolver: MarkdownWikiLinkResolver)?
        var matches: [Match] = []
        let problems = try scan(root: root, openDocuments: openDocuments, markdownOnly: true, isCancelled: isCancelled,
                                skip: { url, identity in identity?.matches(target.identity) == true || url == targetURL },
                                prepare: { files in
            // Цель всегда входит в набор путей, даже если файла ещё нет на диске.
            var paths = files.filter { ["md", "markdown"].contains($0.url.pathExtension.lowercased()) }.map(\.relativePath)
            let folded = MarkdownWikiLinkResolver.fold(targetPath)
            let known = paths.first { MarkdownWikiLinkResolver.fold($0) == folded }
            if known == nil { paths.append(targetPath) }
            prepared = (known ?? targetPath, MarkdownWikiLinkResolver(base: root, paths: paths))
        }) { text, file, source in
            guard let prepared else { return }
            let ranges = try MarkdownBacklinkScanner.ranges(in: text, file: file, target: target, targetPath: prepared.targetPath, resolver: prepared.resolver,
                                                            needles: needles, isCancelled: isCancelled)
            try appendMatches(ranges, in: text, file: file, source: source, isCancelled: isCancelled, to: &matches)
        }
        try checkCancellation(isCancelled)
        return Result(root: root, values: matches, problems: problems)
    }

    /// План обновления ссылок на файл, который ещё лежит по старому адресу (вызывать до переноса).
    static func renameReferences(rename: MarkdownRenameLinkService.Rename, identity: DocumentFileIdentity, syntax: MarkdownSyntaxOptions,
                                 openDocuments: [OpenDocument], isCancelled: () -> Bool = { false }) throws -> MarkdownRenameLinkService.Plan {
        let root = normalized(rename.root)
        try checkCancellation(isCancelled)
        let oldURL = normalized(rename.oldURL), newURL = normalized(rename.newURL)
        guard let oldPath = relativePath(oldURL, root: root), let newPath = relativePath(newURL, root: root) else { return .empty(rename) }
        let target = BacklinkTarget(url: oldURL, identity: identity, syntax: syntax)
        let needles = MarkdownBacklinkScanner.needles(for: target)
        var context: MarkdownRenameLinkService.Context?
        var plans: [MarkdownRenameLinkService.FilePlan] = []
        var counts = MarkdownRenameLinkService.Counts()
        let problems = try scan(root: root, openDocuments: openDocuments, markdownOnly: true, isCancelled: isCancelled,
                                skip: { url, id in id?.matches(identity) == true || url == oldURL },
                                prepare: { files in
            // Старый путь всегда входит в набор, даже если файла нет в обходе; новый каталог — тот же набор с новым путём.
            var paths = files.filter { ["md", "markdown"].contains($0.url.pathExtension.lowercased()) }.map(\.relativePath)
            let folded = MarkdownWikiLinkResolver.fold(oldPath)
            let known = paths.first { MarkdownWikiLinkResolver.fold($0) == folded } ?? oldPath
            if !paths.contains(known) { paths.append(known) }
            let after = paths.filter { $0 != known } + [newPath]
            context = .init(rename: rename, oldPath: known, newPath: newPath,
                            oldResolver: MarkdownWikiLinkResolver(base: root, paths: paths),
                            newResolver: MarkdownWikiLinkResolver(base: root, paths: after), target: target)
        }) { text, file, source in
            guard let context else { return }
            let edits = try MarkdownRenameLinkService.edits(in: text, file: file, context: context, needles: needles,
                                                            counts: &counts, isCancelled: isCancelled)
            if !edits.isEmpty { plans.append(.init(file: file, source: source, edits: edits)) }
        }
        try checkCancellation(isCancelled)
        return .init(rename: rename, files: plans, skipped: counts, problems: problems)
    }

    struct ManuscriptSource: Sendable { let file: File; let text: String; let isOpen: Bool }

    /// Тексты выбранных файлов в порядке `files`; открытые документы приоритетнее диска, невыбранные файлы не читаются.
    static func manuscriptSources(root: URL, files: [File], openDocuments: [OpenDocument],
                                  isCancelled: () -> Bool = { false }) throws -> Result<ManuscriptSource> {
        let root = normalized(root)
        try checkCancellation(isCancelled)
        var order: [URL: Int] = [:]
        for (index, file) in files.enumerated() where order[normalized(file.url)] == nil { order[normalized(file.url)] = index }
        var found: [(Int, ManuscriptSource)] = []
        let problems = try scan(root: root, openDocuments: openDocuments, markdownOnly: true, isCancelled: isCancelled,
                                skip: { url, _ in order[url] == nil }) { text, file, source in
            guard let index = order[normalized(file.url)] else { return }
            let isOpen: Bool = { if case .open = source { true } else { false } }()
            found.append((index, ManuscriptSource(file: file, text: text, isOpen: isOpen)))
        }
        try checkCancellation(isCancelled)
        // Проблемы обхода касаются всей папки: оставляем только выбранные файлы.
        let selected = problems.filter { order[normalized($0.url)] != nil }
        // Файл исчез после показа списка: обход его не видел, но молча выпасть из рукописи он не должен.
        let reported = Set(found.map { normalized($0.1.file.url) } + selected.map { normalized($0.url) })
        let missing = order.sorted { $0.value < $1.value }.map(\.key).filter { !reported.contains($0) }
            .map { Problem(url: $0, reason: .inaccessible) }
        return Result(root: root, values: found.sorted { $0.0 < $1.0 }.map(\.1), problems: selected + missing)
    }

    /// Общий обход папки: открытые документы приоритетнее диска, символические ссылки и изменившиеся файлы попадают в проблемы.
    private static func scan(root: URL, openDocuments: [OpenDocument], markdownOnly: Bool, isCancelled: () -> Bool,
                             skip: (URL, DocumentFileIdentity?) -> Bool = { _, _ in false },
                             prepare: ([File]) throws -> Void = { _ in },
                             visit: (String, File, Source) throws -> Void) throws -> [Problem] {
        let listing = try enumerate(root: root, isCancelled: isCancelled)
        var problems = listing.problems
        var documents: [OpenDocument] = []
        var excluded: Set<URL> = []
        for document in openDocuments {
            try checkCancellation(isCancelled)
            let url = normalized(document.url)
            guard relativePath(url, root: root) != nil, try pathIsSafe(url.deletingLastPathComponent(), root: root, isCancelled: isCancelled),
                  document.identity.canonicalPath == url.resolvingSymlinksInPath().path else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                guard try pathIsSafe(url, root: root, isCancelled: isCancelled), document.identity.matches(DocumentFileIdentity.resolve(url)) else {
                    excluded.insert(url)
                    problems.append(Problem(url: url, reason: .changed)); continue
                }
            }
            documents.append(document)
        }
        var files = listing.files
        var fileURLs = Set(files.map { normalized($0.url) })
        var documentURLs: [URL: [Int]] = [:]
        var documentIdentities = IdentityLookup()
        for (index, document) in documents.enumerated() {
            try checkCancellation(isCancelled)
            let url = normalized(document.url)
            documentURLs[url, default: []].append(index)
            documentIdentities.insert(document.identity, value: index)
            if fileURLs.insert(url).inserted, let relative = relativePath(url, root: root) {
                files.append(File(url: url, relativePath: relative))
            }
        }
        files.sort(by: fileOrder)
        try prepare(files)
        var visited = IdentityLookup()
        for file in files {
            try checkCancellation(isCancelled)
            if markdownOnly, !["md", "markdown"].contains(file.url.pathExtension.lowercased()) { continue }
            let url = normalized(file.url)
            if excluded.contains(url) { continue }
            let identity = try pathIsSafe(url, root: root, isCancelled: isCancelled) ? DocumentFileIdentity.resolve(url) : nil
            if skip(url, identity) { continue }
            let candidateIndices = Set((documentURLs[url] ?? []) + (identity.map { documentIdentities.matches($0) } ?? [])).sorted()
            let candidates = candidateIndices.map { documents[$0] }
            if let first = candidates.first {
                if candidates.contains(where: { $0.snapshot != first.snapshot || !$0.identity.matches(first.identity) }) {
                    problems.append(Problem(url: url, reason: .conflictingOpenDocuments))
                    continue
                }
                guard visited.matches(first.identity).isEmpty else { continue }
                visited.insert(first.identity, value: 0)
                if skip(url, first.identity) { continue }
                let origin = Source.open(documentID: first.snapshot.documentID, revision: first.snapshot.revision, identity: first.identity)
                let documentURL = normalized(first.url)
                let documentFile = File(url: documentURL, relativePath: relativePath(documentURL, root: root)!)
                try visit(first.snapshot.text, documentFile, origin)
                continue
            }
            guard try pathIsSafe(url, root: root, isCancelled: isCancelled) else {
                problems.append(Problem(url: url, reason: .symbolicLink)); continue
            }
            do {
                try checkCancellation(isCancelled)
                let before = try FileRevisionSnapshot.capture(url)
                try checkCancellation(isCancelled)
                let data = try Data(contentsOf: url)
                try checkCancellation(isCancelled)
                let after = try FileRevisionSnapshot.capture(url)
                try checkCancellation(isCancelled)
                guard before == after, try pathIsSafe(url, root: root, isCancelled: isCancelled) else {
                    problems.append(Problem(url: url, reason: .changed)); continue
                }
                guard visited.matches(after.identity).isEmpty else { continue }
                visited.insert(after.identity, value: 0)
                guard let text = String(data: data, encoding: .utf8) else {
                    problems.append(Problem(url: url, reason: .invalidUTF8)); continue
                }
                try visit(text, file, .disk(after))
            } catch is CancellationError { throw CancellationError() }
            catch { problems.append(Problem(url: url, reason: .inaccessible)) }
        }
        return problems
    }

    static func search(root: URL, query: String, caseSensitive: Bool, openDocuments: [OpenDocument], kind: SearchKind = .text,
                       options: TextSearchService.Options? = nil, isCancelled: () -> Bool = { false }) throws -> Result<Match> {
        let root = normalized(root)
        try checkCancellation(isCancelled)
        guard !query.isEmpty else { return Result(root: root, values: [], problems: []) }
        var matches: [Match] = []
        var tagProblems: [Problem] = []
        let problems = try scan(root: root, openDocuments: openDocuments, markdownOnly: kind == .tags, isCancelled: isCancelled) { text, file, source in
            if kind == .text {
                try appendMatches(text, file: file, source: source, query: query,
                                  options: options ?? TextSearchService.Options(caseSensitive: caseSensitive),
                                  isCancelled: isCancelled, to: &matches)
            } else {
                try appendTagMatches(text, file: file, source: source, query: query, isCancelled: isCancelled,
                                     to: &matches, problems: &tagProblems)
            }
        }
        try checkCancellation(isCancelled)
        return Result(root: root, values: matches, problems: problems + tagProblems)
    }

    /// Тег папки: имя в первом встреченном написании и число файлов, где он есть (YAML и встроенные, повтор в файле — один).
    struct TagEntry: Equatable, Sendable {
        let name: String
        let fileCount: Int
    }

    static func tagListing(root: URL, openDocuments: [OpenDocument], isCancelled: () -> Bool = { false }) throws -> Result<TagEntry> {
        let root = normalized(root)
        try checkCancellation(isCancelled)
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        var tagProblems: [Problem] = []
        let problems = try scan(root: root, openDocuments: openDocuments, markdownOnly: true, isCancelled: isCancelled) { text, file, _ in
            let parsed = try MarkdownTagReader.read(text: text, isCancelled: isCancelled)
            var found: [String] = []
            switch parsed.yaml {
            case let .tags(tags)?: found = tags.map(MarkdownTagReader.normalized)
            case .invalid?: tagProblems.append(Problem(url: file.url, reason: .invalidTags))
            case nil: break
            }
            found.append(contentsOf: parsed.inline.map(\.name))
            var seen: Set<String> = []
            for name in found where !name.isEmpty {
                let key = name.lowercased()
                guard seen.insert(key).inserted else { continue }
                if names[key] == nil { names[key] = name }
                counts[key, default: 0] += 1
            }
        }
        try checkCancellation(isCancelled)
        let entries = names.map { TagEntry(name: $0.value, fileCount: counts[$0.key] ?? 0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Result(root: root, values: entries, problems: problems + tagProblems)
    }

    static func isCurrent(_ match: Match, openDocument: OpenDocument) -> Bool {
        guard case let .open(id, revision, identity) = match.source,
              openDocument.snapshot.documentID == id, openDocument.snapshot.revision == revision,
              identity.matches(openDocument.identity), normalized(openDocument.url) == normalized(match.file.url) else { return false }
        return hasFragment(match, text: openDocument.snapshot.text)
    }

    enum ReplaceReadFailure: Error, Equatable { case changed, symbolicLink, notExactUTF8, inaccessible }

    /// Чтение закрытого файла перед записью замены: отметка до и после чтения, путь без символических ссылок,
    /// байты равны UTF-8 перекодированию текста (без BOM и нестандартных последовательностей).
    static func readForReplace(url: URL, root: URL, expected: FileRevisionSnapshot,
                               isCancelled: () -> Bool = { false }) throws -> String {
        let root = normalized(root), url = normalized(url)
        try checkCancellation(isCancelled)
        guard relativePath(url, root: root) != nil else { throw ReplaceReadFailure.inaccessible }
        guard try pathIsSafe(url, root: root, isCancelled: isCancelled) else { throw ReplaceReadFailure.symbolicLink }
        let data: Data
        do {
            guard try FileRevisionSnapshot.capture(url) == expected else { throw ReplaceReadFailure.changed }
            try checkCancellation(isCancelled)
            data = try Data(contentsOf: url)
            try checkCancellation(isCancelled)
            guard try FileRevisionSnapshot.capture(url) == expected,
                  try pathIsSafe(url, root: root, isCancelled: isCancelled) else { throw ReplaceReadFailure.changed }
        } catch let failure as ReplaceReadFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch { throw ReplaceReadFailure.inaccessible }
        // BOM Foundation может отбросить при декодировании: файл с ним не угадываем, а пропускаем.
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]),
              let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else { throw ReplaceReadFailure.notExactUTF8 }
        return text
    }

    static func isCurrent(_ match: Match, root: URL, isCancelled: () -> Bool = { false }) throws -> Bool {
        guard case let .disk(expected) = match.source else { return false }
        let root = normalized(root), url = normalized(match.file.url)
        try checkCancellation(isCancelled)
        guard relativePath(url, root: root) != nil, try pathIsSafe(url, root: root, isCancelled: isCancelled) else { return false }
        do {
            let before = try FileRevisionSnapshot.capture(url)
            try checkCancellation(isCancelled)
            guard before == expected else { return false }
            let data = try Data(contentsOf: url)
            try checkCancellation(isCancelled)
            let after = try FileRevisionSnapshot.capture(url)
            try checkCancellation(isCancelled)
            guard after == expected, try pathIsSafe(url, root: root, isCancelled: isCancelled), let text = String(data: data, encoding: .utf8) else { return false }
            return hasFragment(match, text: text)
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    static func hasFragment(_ match: Match, text: String) -> Bool {
        let source = text as NSString
        return match.range.location >= 0 && match.range.location <= source.length &&
            match.range.length >= 0 && match.range.length <= source.length - match.range.location &&
            source.substring(with: match.range) == match.matchedText
    }

    private static func appendMatches(_ text: String, file: File, source: Source, query: String,
                                      options: TextSearchService.Options, isCancelled: () -> Bool, to output: inout [Match]) throws {
        try checkCancellation(isCancelled)
        let ranges = try TextSearchService.allRanges(in: text, query: query, options: options, isCancelled: isCancelled)
        try appendMatches(ranges, in: text, file: file, source: source, isCancelled: isCancelled, to: &output)
    }

    /// Совпадения по готовым диапазонам (по возрастанию): строка контекста общая для текстового поиска и обратных ссылок.
    private static func appendMatches(_ ranges: [NSRange], in text: String, file: File, source: Source,
                                      isCancelled: () -> Bool, to output: inout [Match]) throws {
        try checkCancellation(isCancelled)
        let string = text as NSString
        var contexts: [NSRange: String] = [:]
        var previousContext: NSRange?
        for range in ranges {
            try checkCancellation(isCancelled)
            let context: NSRange
            if let previousContext, range.location < NSMaxRange(previousContext), NSMaxRange(range) <= NSMaxRange(previousContext) {
                context = previousContext
            } else {
                context = string.lineRange(for: range)
                let firstLine = string.lineRange(for: NSRange(location: range.location, length: 0))
                previousContext = context == firstLine ? context : nil
            }
            let contextText: String
            if let cached = contexts[context] { contextText = cached }
            else { contextText = string.substring(with: context); contexts[context] = contextText }
            output.append(Match(file: file, range: range, matchedText: string.substring(with: range),
                                contextRange: context, context: contextText, source: source))
        }
    }

    private static func appendTagMatches(_ text: String, file: File, source: Source, query: String, isCancelled: () -> Bool,
                                         to output: inout [Match], problems: inout [Problem]) throws {
        let parsed = try MarkdownTagReader.read(text: text, isCancelled: isCancelled)
        let string = text as NSString
        if let range = parsed.frontMatterRange, let yaml = parsed.yaml {
            switch yaml {
            case let .tags(tags):
                if tags.contains(where: { MarkdownTagReader.matches(tag: $0, query: query) }) {
                    output.append(Match(file: file, range: range, matchedText: string.substring(with: range),
                                        contextRange: range, context: tags.joined(separator: ", "), source: source))
                }
            case .invalid:
                problems.append(Problem(url: file.url, reason: .invalidTags))
            }
        }
        var lastContext: (range: NSRange, text: String)?
        for tag in parsed.inline where MarkdownTagReader.matches(tag: tag.name, query: query) {
            try checkCancellation(isCancelled)
            let context = string.lineRange(for: tag.range)
            let contextText: String
            if let lastContext, lastContext.range == context { contextText = lastContext.text }
            else { contextText = string.substring(with: context) }
            lastContext = (context, contextText)
            output.append(Match(file: file, range: tag.range, matchedText: string.substring(with: tag.range),
                                contextRange: context, context: contextText, source: source))
        }
    }

    private static func enumerate(root: URL, includeMetadata: Bool = false, isCancelled: () -> Bool) throws -> (files: [File], listedFiles: [ListedFile], problems: [Problem]) {
        var files: [File] = [], listedFiles: [ListedFile] = [], problems: [Problem] = [], pending = [root]
        while let directory = pending.popLast() {
            try checkCancellation(isCancelled)
            guard try pathIsSafe(directory, root: root, isCancelled: isCancelled) else { problems.append(Problem(url: directory, reason: .inaccessible)); continue }
            do {
                let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                try checkCancellation(isCancelled)
                for child in children {
                    try checkCancellation(isCancelled)
                    let url = normalized(child)
                    do {
                        var keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
                        if includeMetadata { keys.formUnion([.creationDateKey, .contentModificationDateKey]) }
                        let values = try url.resourceValues(forKeys: keys)
                        try checkCancellation(isCancelled)
                        if values.isSymbolicLink != true && values.isDirectory == true { pending.append(url) }
                        else if (values.isSymbolicLink == true || values.isRegularFile == true), let relative = relativePath(url, root: root) {
                            let file = File(url: url, relativePath: relative)
                            files.append(file)
                            if includeMetadata { listedFiles.append(ListedFile(file: file, isSymbolicLink: values.isSymbolicLink == true, creationDate: values.creationDate, modificationDate: values.contentModificationDate)) }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { problems.append(Problem(url: url, reason: .inaccessible)) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { problems.append(Problem(url: directory, reason: .inaccessible)) }
        }
        return (files, listedFiles, problems)
    }

    private static func normalized(_ url: URL) -> URL { URL(fileURLWithPath: url.standardizedFileURL.path) }

    private static func relativePath(_ url: URL, root: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents, base = root.standardizedFileURL.pathComponents
        guard components.count > base.count, components.starts(with: base) else { return nil }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    private static func pathIsSafe(_ url: URL, root: URL, isCancelled: () -> Bool) throws -> Bool {
        let components = url.standardizedFileURL.pathComponents, base = root.standardizedFileURL.pathComponents
        guard components.starts(with: base) else { return false }
        var current = root
        let paths = [root] + components.dropFirst(base.count).map { component -> URL in
            current.appendPathComponent(component)
            return current
        }
        for (index, path) in paths.enumerated() {
            try checkCancellation(isCancelled)
            let values = try? normalized(path).resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            try checkCancellation(isCancelled)
            guard let values,
                  values.isSymbolicLink != true,
                  index == paths.count - 1 || values.isDirectory == true else { return false }
        }
        return true
    }

    private static func fileOrder(_ first: File, _ second: File) -> Bool {
        let comparison = first.relativePath.localizedStandardCompare(second.relativePath)
        return comparison == .orderedSame ? first.url.path < second.url.path : comparison == .orderedAscending
    }

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }
}
