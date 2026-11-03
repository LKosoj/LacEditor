import Foundation

struct SearchIndexProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}

/// Обновление индекса по папке. Чтение и нарезка идут вне актора индекса, в актор уходят короткие вызовы.
enum SearchIndexer {
    /// Режиму «По словам» маска файлов не применяется: индексируется фиксированный набор расширений.
    static let extensions: Set<String> = ["md", "markdown", "txt"]
    static let maxFileBytes = 8 * 1024 * 1024

    struct Report: Equatable, Sendable {
        var indexed = 0
        var removed = 0
        var skipped = 0
        var problems: [String] = []
    }

    private enum Outcome { case indexed, skipped, invalidUTF8 }

    static func isIndexable(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Приводит индекс в соответствие с папкой. Отмена проверяется между файлами и возвращает частичный отчёт.
    static func refresh(_ index: SearchIndex, root: URL,
                        progress: @escaping @Sendable (SearchIndexProgress) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) async throws -> Report {
        try await index.prepare()
        let root = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
        var report = Report()
        let listing: FolderSearchService.Result<FolderSearchService.ListedFile>
        do { listing = try FolderSearchService.listing(root: root, isCancelled: isCancelled) }
        catch is CancellationError { return report }

        var current: [String: (url: URL, stamp: SearchIndexFileStamp)] = [:]
        for listed in listing.values where !listed.isSymbolicLink && isIndexable(listed.file.url) {
            guard let stamp = stamp(of: listed.file.url) else { continue }
            guard stamp.size <= maxFileBytes else { report.skipped += 1; continue }
            current[listed.file.relativePath] = (listed.file.url, stamp)
        }
        let stored = try await index.fileStamps()
        let gone = stored.keys.filter { current[$0] == nil }.sorted()
        if !gone.isEmpty {
            try await index.remove(paths: gone)
            report.removed = gone.count
        }
        let work = current.filter { stored[$0.key] != $0.value.stamp }.sorted { $0.key < $1.key }
        progress(SearchIndexProgress(done: 0, total: work.count))
        for (offset, item) in work.enumerated() {
            if isCancelled() { break }
            do {
                switch try await process(index, root: root, url: item.value.url, relative: item.key, isCancelled: isCancelled) {
                case .indexed: report.indexed += 1
                case .skipped: report.skipped += 1
                case .invalidUTF8:
                    report.problems.append(item.key)
                    try await index.remove(paths: [item.key])
                }
            } catch is CancellationError { break }
            progress(SearchIndexProgress(done: offset + 1, total: work.count))
        }
        return report
    }

    /// Хук «после сохранения»: обновляет один файл; если файла уже нет или он не подходит, убирает его из индекса.
    static func refreshFile(_ index: SearchIndex, root: URL, url: URL) async throws {
        let root = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
        let url = URL(fileURLWithPath: url.standardizedFileURL.path)
        guard isIndexable(url), let relative = FolderSearchService.relativePath(url, root: root),
              relative != ".laceditor", !relative.hasPrefix(".laceditor/") else { return }
        try await index.prepare()
        guard let stamp = stamp(of: url), stamp.size <= maxFileBytes else {
            try await index.remove(paths: [relative])
            return
        }
        if try await process(index, root: root, url: url, relative: relative, isCancelled: { false }) == .invalidUTF8 {
            try await index.remove(paths: [relative])
        }
    }

    /// Отметка файла: время изменения и размер. nil — не обычный файл, ссылка или нечитаемый.
    static func stamp(of url: URL) -> SearchIndexFileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let date = values.contentModificationDate, let size = values.fileSize else { return nil }
        return SearchIndexFileStamp(mtime: date.timeIntervalSince1970, size: Int64(size))
    }

    private static func process(_ index: SearchIndex, root: URL, url: URL, relative: String,
                                isCancelled: @escaping @Sendable () -> Bool) async throws -> Outcome {
        guard try FolderSearchService.pathIsSafe(url, root: root, isCancelled: isCancelled) else { return .skipped }
        let readStarted = Date().timeIntervalSince1970
        // Отметка до и после чтения: файл, который меняется прямо сейчас, пропускается и догонится при следующем обновлении.
        guard let before = stamp(of: url), before.size <= maxFileBytes, let data = try? Data(contentsOf: url),
              stamp(of: url) == before else { return .skipped }
        guard let text = String(data: data, encoding: .utf8) else { return .invalidUTF8 }
        let chunks = SearchIndexChunker.chunks(in: text, fileTitle: url.lastPathComponent)
        return try await index.replace(path: relative, stamp: before, chunks: chunks, readStarted: readStarted) ? .indexed : .skipped
    }
}
