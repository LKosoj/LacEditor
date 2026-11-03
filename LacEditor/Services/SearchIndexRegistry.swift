import CryptoKit
import Foundation

/// Один индекс на корень папки. Файлы лежат в `Application Support/<AppEnvironment.dataDirectoryName>/SearchIndex`.
final class SearchIndexRegistry: @unchecked Sendable {
    static let shared = SearchIndexRegistry()

    private let directory: URL
    private let lock = NSLock()
    private var indexes: [String: SearchIndex] = [:]

    init(directory: URL = SearchIndexRegistry.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("SearchIndex", isDirectory: true)
    }

    private static func key(_ root: URL) -> String { root.standardizedFileURL.path }

    /// Имя файла — SHA-256 пути корня.
    func databaseURL(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(Self.key(root).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".sqlite")
    }

    /// Создаёт объект при необходимости; файл базы появится при первом `prepare`.
    func index(for root: URL) -> SearchIndex {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(root)
        if let existing = indexes[key] { return existing }
        let created = SearchIndex(databaseURL: databaseURL(for: root), root: URL(fileURLWithPath: key, isDirectory: true))
        indexes[key] = created
        return created
    }

    /// Только если база уже есть на диске: на сохранении файла индекс сам не создаётся.
    func existingIndex(for root: URL) -> SearchIndex? {
        guard FileManager.default.fileExists(atPath: databaseURL(for: root).path) else { return nil }
        return index(for: root)
    }

    /// Забыть объект (после `destroy`).
    func remove(root: URL) {
        lock.lock()
        indexes[Self.key(root)] = nil
        lock.unlock()
    }
}
