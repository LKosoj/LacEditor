import CryptoKit
import Foundation

/// Резервная копия последней замены в папке: исходные байты закрытых файлов и отпечатки для безопасного возврата.
struct FolderReplaceBackupStore: Sendable {
    struct Manifest: Codable, Equatable, Sendable {
        var version: Int
        var operationID: String
        var createdAt: Date
        var rootPath: String
    }

    struct Entry: Codable, Equatable, Sendable {
        var index: Int
        var relativePath: String
        var originalSHA256: String
        var futureSHA256: String
        var originalByteCount: Int
    }

    enum Verdict: Equatable, Sendable {
        case reverted, notApplied, conflict, openInEditor, failed
    }

    struct RevertResult: Equatable, Sendable {
        var reverted = 0, notApplied = 0, conflicts = 0, openInEditor = 0, failed = 0
    }

    struct Loaded: Equatable, Sendable {
        let manifest: Manifest
        let entries: [Entry]
    }

    static let manifestVersion = 1

    let directory: URL

    init(directory: URL = Self.defaultDirectory()) {
        self.directory = directory
    }

    /// `Application Support/<AppEnvironment.dataDirectoryName>/FolderReplaceBackup`.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("FolderReplaceBackup", isDirectory: true)
    }

    /// Начинает новую операцию: каталог создаётся при первой записи.
    func makeRecorder(root: URL) -> Recorder {
        Recorder(directory: directory, rootPath: root.standardizedFileURL.path)
    }

    var hasBackup: Bool { load() != nil }

    /// Последняя операция, у которой есть хотя бы одна запись.
    func load() -> Loaded? {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        var best: Loaded?
        for child in children {
            guard let manifest = Self.readManifest(in: child), manifest.version == Self.manifestVersion else { continue }
            let entries = Self.readEntries(in: child)
            guard !entries.isEmpty else { continue }
            if best == nil || manifest.createdAt > best!.manifest.createdAt { best = Loaded(manifest: manifest, entries: entries) }
        }
        return best
    }

    /// Возвращает файлы, не менявшиеся после замены; `isOpen` — файл сейчас открыт в редакторе.
    func revert(isOpen: (URL) -> Bool) -> RevertResult {
        guard let loaded = load() else { return RevertResult() }
        let operation = directory.appendingPathComponent(loaded.manifest.operationID, isDirectory: true)
        let root = URL(fileURLWithPath: loaded.manifest.rootPath, isDirectory: true)
        var result = RevertResult()
        for entry in loaded.entries {
            let verdict = revert(entry, root: root, operation: operation, isOpen: isOpen)
            switch verdict {
            case .reverted: result.reverted += 1
            case .notApplied: result.notApplied += 1
            case .conflict: result.conflicts += 1
            case .openInEditor: result.openInEditor += 1
            case .failed: result.failed += 1
            }
            if verdict == .reverted || verdict == .notApplied { Self.remove(entry, in: operation) }
        }
        if Self.readEntries(in: operation).isEmpty { try? FileManager.default.removeItem(at: operation) }
        return result
    }

    private func revert(_ entry: Entry, root: URL, operation: URL, isOpen: (URL) -> Bool) -> Verdict {
        let url = root.appendingPathComponent(entry.relativePath)
        if isOpen(url) { return .openInEditor }
        guard let expected = try? FileRevisionSnapshot.capture(url) else { return .conflict }
        guard let current = try? FolderSearchService.readForReplace(url: url, root: root, expected: expected) else { return .conflict }
        let hash = Self.sha256(Data(current.utf8))
        if hash == entry.originalSHA256 { return .notApplied }
        guard hash == entry.futureSHA256 else { return .conflict }
        guard let data = try? Data(contentsOf: Self.origURL(entry.index, in: operation)),
              Self.sha256(data) == entry.originalSHA256,
              let original = String(data: data, encoding: .utf8), Data(original.utf8) == data else { return .failed }
        guard (try? FileRevisionSnapshot.capture(url)) == expected else { return .conflict }
        do { try FileService.writeUTF8(original, to: url) } catch { return .failed }
        return .reverted
    }

    /// Одна операция замены: вызывается последовательно, до записи каждого файла.
    final class Recorder: @unchecked Sendable {
        private let directory: URL
        private let manifest: Manifest
        private var operation: URL { directory.appendingPathComponent(manifest.operationID, isDirectory: true) }
        private var started = false
        private var count = 0

        fileprivate init(directory: URL, rootPath: String) {
            self.directory = directory
            manifest = Manifest(version: FolderReplaceBackupStore.manifestVersion, operationID: UUID().uuidString,
                                createdAt: Date(), rootPath: rootPath)
        }

        func record(originalText: String, futureText: String, relativePath: String) throws {
            let fileManager = FileManager.default
            if !started {
                try fileManager.createDirectory(at: operation, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(to: operation.appendingPathComponent("manifest.json"), options: .atomic)
            }
            let original = Data(originalText.utf8)
            let index = count + 1
            try original.write(to: FolderReplaceBackupStore.origURL(index, in: operation), options: .atomic)
            let entry = Entry(index: index, relativePath: relativePath,
                              originalSHA256: FolderReplaceBackupStore.sha256(original),
                              futureSHA256: FolderReplaceBackupStore.sha256(Data(futureText.utf8)),
                              originalByteCount: original.count)
            // Запись .json — точка фиксации: без неё файл считается не начатым.
            try JSONEncoder().encode(entry).write(to: FolderReplaceBackupStore.entryURL(index, in: operation), options: .atomic)
            count = index
            guard !started else { return }
            started = true
            // Прежняя операция удаляется только после первой успешной записи новой.
            let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for child in children where child.lastPathComponent != manifest.operationID { try? fileManager.removeItem(at: child) }
        }
    }

    // MARK: Файлы на диске

    private static func name(_ index: Int) -> String { String(format: "%05d", index) }

    fileprivate static func origURL(_ index: Int, in operation: URL) -> URL {
        operation.appendingPathComponent(name(index) + ".orig")
    }

    fileprivate static func entryURL(_ index: Int, in operation: URL) -> URL {
        operation.appendingPathComponent(name(index) + ".json")
    }

    private static func readManifest(in operation: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: operation.appendingPathComponent("manifest.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    private static func readEntries(in operation: URL) -> [Entry] {
        let children = (try? FileManager.default.contentsOfDirectory(at: operation, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return children
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Entry.self, from: $0) } }
            .sorted { $0.index < $1.index }
    }

    private static func remove(_ entry: Entry, in operation: URL) {
        try? FileManager.default.removeItem(at: entryURL(entry.index, in: operation))
        try? FileManager.default.removeItem(at: origURL(entry.index, in: operation))
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
