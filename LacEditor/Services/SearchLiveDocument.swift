import Foundation

/// Открытый документ, нарезанный в памяти: берёт участие в поиске по словам вместо устаревшего текста с диска.
struct SearchLiveDocument: Sendable {
    let path: String              // относительный путь от корня
    let documentID: UUID
    let revision: UInt            // `DocumentTextSnapshot.revision`
    let chunks: [SearchChunk]
}

/// Кэш нарезки по документу и ревизии: повторный поиск не режет неизменённый текст заново.
final class SearchLiveDocumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: (revision: UInt, chunks: [SearchChunk])] = [:]

    init() {}

    /// `make` вызывается вне блокировки: нарезка длинная, а другие окна не должны ждать.
    func chunks(documentID: UUID, revision: UInt, make: () -> [SearchChunk]) -> [SearchChunk] {
        lock.lock()
        let cached = entries[documentID]
        lock.unlock()
        if let cached, cached.revision == revision { return cached.chunks }
        let chunks = make()
        lock.lock()
        entries[documentID] = (revision, chunks)
        lock.unlock()
        return chunks
    }

    /// Забывает закрытые документы: в кэше остаются только открытые сейчас.
    func keepOnly(_ ids: Set<UUID>) {
        lock.lock()
        entries = entries.filter { ids.contains($0.key) }
        lock.unlock()
    }
}

enum SearchLiveDocuments {
    /// Условия включения те же, что у `FolderSearchService.scan`: путь под корнем, родитель без симлинков,
    /// каноническая ссылка документа совпадает с путём. Нарезка тяжёлая: вызывать вне главного потока и вне актора индекса.
    static func build(snapshots: [FolderSearchService.OpenDocument], root: URL, cache: SearchLiveDocumentCache) -> [SearchLiveDocument] {
        var result: [SearchLiveDocument] = []
        var seen: Set<String> = []
        defer { cache.keepOnly(Set(snapshots.map(\.snapshot.documentID))) }
        for document in snapshots {
            let url = URL(fileURLWithPath: document.url.standardizedFileURL.path)
            guard SearchIndexer.isIndexable(url),
                  let relative = FolderSearchService.relativePath(url, root: root),
                  (try? FolderSearchService.pathIsSafe(url.deletingLastPathComponent(), root: root, isCancelled: { false })) == true,
                  document.identity.canonicalPath == url.resolvingSymlinksInPath().path,
                  seen.insert(relative).inserted else { continue }
            let snapshot = document.snapshot
            let chunks = cache.chunks(documentID: snapshot.documentID, revision: snapshot.revision) {
                SearchIndexChunker.chunks(in: snapshot.text, fileTitle: url.lastPathComponent)
            }
            result.append(SearchLiveDocument(path: relative, documentID: snapshot.documentID, revision: snapshot.revision, chunks: chunks))
        }
        return result
    }
}
