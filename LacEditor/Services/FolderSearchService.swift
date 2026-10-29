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

    static func search(root: URL, query: String, caseSensitive: Bool, openDocuments: [OpenDocument], kind: SearchKind = .text,
                       isCancelled: () -> Bool = { false }) throws -> Result<Match> {
        let root = normalized(root)
        try checkCancellation(isCancelled)
        guard !query.isEmpty else { return Result(root: root, values: [], problems: []) }
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
        var visited = IdentityLookup()
        var matches: [Match] = []
        var tagInputs: [MarkdownTagReader.Input] = []
        var tagMatches: [UUID: Match] = [:]
        func append(_ text: String, file: File, source: Source) throws {
            if kind == .text {
                try appendMatches(text, file: file, source: source, query: query, caseSensitive: caseSensitive,
                                  isCancelled: isCancelled, to: &matches)
            } else if let frontMatter = MarkdownPresentationParser.frontMatter(text) {
                try checkCancellation(isCancelled)
                let raw = (text as NSString).substring(with: frontMatter.range)
                let id = UUID()
                tagInputs.append(MarkdownTagReader.Input(id: id, frontMatter: raw))
                tagMatches[id] = Match(file: file, range: frontMatter.range, matchedText: raw,
                                       contextRange: frontMatter.range, context: "", source: source)
            }
        }
        for file in files {
            try checkCancellation(isCancelled)
            if kind == .tags, !["md", "markdown"].contains(file.url.pathExtension.lowercased()) { continue }
            let url = normalized(file.url)
            if excluded.contains(url) { continue }
            let identity = try pathIsSafe(url, root: root, isCancelled: isCancelled) ? DocumentFileIdentity.resolve(url) : nil
            let candidateIndices = Set((documentURLs[url] ?? []) + (identity.map { documentIdentities.matches($0) } ?? [])).sorted()
            let candidates = candidateIndices.map { documents[$0] }
            if let first = candidates.first {
                if candidates.contains(where: { $0.snapshot != first.snapshot || !$0.identity.matches(first.identity) }) {
                    problems.append(Problem(url: url, reason: .conflictingOpenDocuments))
                    continue
                }
                guard visited.matches(first.identity).isEmpty else { continue }
                visited.insert(first.identity, value: 0)
                let origin = Source.open(documentID: first.snapshot.documentID, revision: first.snapshot.revision, identity: first.identity)
                let documentURL = normalized(first.url)
                let documentFile = File(url: documentURL, relativePath: relativePath(documentURL, root: root)!)
                try append(first.snapshot.text, file: documentFile, source: origin)
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
                try append(text, file: file, source: .disk(after))
            } catch is CancellationError { throw CancellationError() }
            catch { problems.append(Problem(url: url, reason: .inaccessible)) }
        }
        try checkCancellation(isCancelled)
        if kind == .tags {
            let results = try MarkdownTagReader.read(tagInputs, isCancelled: isCancelled)
            let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            for input in tagInputs {
                try checkCancellation(isCancelled)
                guard let original = tagMatches[input.id], let result = results[input.id] else { continue }
                switch result {
                case let .tags(tags):
                    guard tags.contains(where: { ($0 as NSString).compare(query, options: options) == .orderedSame }) else { continue }
                    matches.append(Match(file: original.file, range: original.range, matchedText: original.matchedText,
                                         contextRange: original.contextRange, context: tags.joined(separator: ", "), source: original.source))
                case .invalid:
                    problems.append(Problem(url: original.file.url, reason: .invalidTags))
                }
            }
        }
        try checkCancellation(isCancelled)
        return Result(root: root, values: matches, problems: problems)
    }

    static func isCurrent(_ match: Match, openDocument: OpenDocument) -> Bool {
        guard case let .open(id, revision, identity) = match.source,
              openDocument.snapshot.documentID == id, openDocument.snapshot.revision == revision,
              identity.matches(openDocument.identity), normalized(openDocument.url) == normalized(match.file.url) else { return false }
        return hasFragment(match, text: openDocument.snapshot.text)
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

    private static func hasFragment(_ match: Match, text: String) -> Bool {
        let source = text as NSString
        return match.range.location >= 0 && match.range.location <= source.length &&
            match.range.length >= 0 && match.range.length <= source.length - match.range.location &&
            source.substring(with: match.range) == match.matchedText
    }

    private static func appendMatches(_ text: String, file: File, source: Source, query: String,
                                      caseSensitive: Bool, isCancelled: () -> Bool, to output: inout [Match]) throws {
        try checkCancellation(isCancelled)
        let ranges = TextSearchService.allRanges(in: text, query: query, caseSensitive: caseSensitive, isCancelled: isCancelled)
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
