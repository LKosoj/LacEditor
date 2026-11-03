import Foundation

/// Число слов в сценах проекта. Читает файлы в фоне, открытые документы берёт из памяти; результат по файлам кешируется.
/// Для китайского `DocumentStatistics` считает каждый иероглиф, поэтому «词» и «字» здесь одно число.
@MainActor
final class ManuscriptWordCounter: ObservableObject {
    /// Слова по идентификатору узла; узел без значения не читался (файл отсутствует, не UTF-8 или больше лимита).
    @Published private(set) var counts: [UUID: Int] = [:]
    @Published private(set) var bookTotal = 0
    @Published private(set) var isCounting = false

    static let maxFileSize = 5 * 1_024 * 1_024

    private struct CacheKey: Equatable, Sendable {
        let modified: Date
        let size: Int
    }
    private struct Entry: Sendable {
        let id: UUID
        let url: URL
        let isIncluded: Bool
    }

    private var cache: [String: (key: CacheKey, words: Int)] = [:]
    private var generation = 0
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    /// Пересчитывает слова. `openDocuments` — снимки открытых файлов (nil — только диск).
    func refresh(store: ManuscriptProjectStore, openDocuments: [FolderSearchService.OpenDocument]?) {
        generation += 1
        let current = generation
        task?.cancel()
        let included = Set(store.orderedTextNodes(includedOnly: true).map(\.id))
        let entries: [Entry] = store.orderedTextNodes(includedOnly: false).compactMap { node in
            store.fileURL(for: node).map { Entry(id: node.id, url: $0, isIncluded: included.contains(node.id)) }
        }
        var open: [String: String] = [:]
        for document in openDocuments ?? [] { open[document.url.standardizedFileURL.path] = document.snapshot.text }
        let snapshotCache = cache
        isCounting = true
        task = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { () -> (counts: [UUID: Int], cache: [String: (key: CacheKey, words: Int)])? in
                var counts: [UUID: Int] = [:]
                var updated = snapshotCache
                for entry in entries {
                    if Task.isCancelled { return nil }
                    let path = entry.url.standardizedFileURL.path
                    if let text = open[path] {
                        counts[entry.id] = DocumentStatistics.calculate(text, isCancelled: { Task.isCancelled })?.words
                        continue
                    }
                    guard let values = try? entry.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true, let modified = values.contentModificationDate,
                          let size = values.fileSize, size <= ManuscriptWordCounter.maxFileSize else { continue }
                    let key = CacheKey(modified: modified, size: size)
                    if let cached = updated[path], cached.key == key {
                        counts[entry.id] = cached.words
                        continue
                    }
                    guard let data = try? Data(contentsOf: entry.url), let text = String(data: data, encoding: .utf8),
                          let words = DocumentStatistics.calculate(text, isCancelled: { Task.isCancelled })?.words else { continue }
                    updated[path] = (key, words)
                    counts[entry.id] = words
                }
                return (counts, updated)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.isCounting = false
            guard let result else { return }
            self.cache = result.cache
            self.counts = result.counts
            self.bookTotal = entries.filter(\.isIncluded).reduce(0) { $0 + (result.counts[$1.id] ?? 0) }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        isCounting = false
    }
}
