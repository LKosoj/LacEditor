import CryptoKit
import Foundation

/// Где лежат снимки одного файла.
enum DocumentSnapshotLocation: Equatable, Sendable {
    /// Файл внутри проекта рукописи: `<root>/.laceditor/snapshots/<nodeID>/`.
    case project(root: URL, nodeID: UUID)
    /// Файл вне проекта: `Application Support/<dataDirectoryName>/Snapshots/<sha256(path)>/`.
    case file(path: String)
}

struct DocumentSnapshotInfo: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var name: String
    let date: Date
    let byteCount: Int
    /// Hex от UTF-8 байтов текста.
    let sha256: String
    /// Имя кодировки документа на момент снимка (справочно).
    let encoding: String
}

enum DocumentSnapshotError: LocalizedError, Equatable {
    /// Индекс записан более новой версией приложения.
    case readOnly
    case notFound
    /// Не совпала sha256 или нет файла `<id>.txt`.
    case corrupted
    /// Каталог снимков проекта вне корня (символическая ссылка).
    case unsafePath
    case io(String)

    var errorDescription: String? {
        switch self {
        case .readOnly: L10n.tr("快照由较新版本创建，无法修改")
        case .corrupted: L10n.tr("快照已损坏")
        case .notFound, .unsafePath: L10n.tr("无法保存快照")
        case .io(let text): text
        }
    }
}

/// Именованные копии текста одного файла. Формат каталога: `index.json` (`{"version":1,"snapshots":[…]}`)
/// и `<id>.txt` в UTF-8. Все операции синхронные, под одной блокировкой: вызывать не с главного потока.
final class DocumentSnapshotStore: @unchecked Sendable {
    static let shared = DocumentSnapshotStore()
    static let didChangeNotification = Notification.Name("DocumentSnapshotStoreDidChange")
    static let currentVersion = 1

    private struct Index: Codable {
        var version: Int
        var snapshots: [DocumentSnapshotInfo]
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    private let baseDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(baseDirectory: URL = DocumentSnapshotStore.defaultBaseDirectory(), fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    static func defaultBaseDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    /// Папка снимков для ключа (без создания).
    func directory(for location: DocumentSnapshotLocation) -> URL {
        switch location {
        case let .project(root, nodeID):
            return root.standardizedFileURL
                .appendingPathComponent(".laceditor", isDirectory: true)
                .appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(nodeID.uuidString, isDirectory: true)
        case let .file(path):
            return baseDirectory.appendingPathComponent(Self.hash(of: path), isDirectory: true)
        }
    }

    // MARK: Операции

    @discardableResult
    func add(text: String, name: String, encodingName: String,
             location: DocumentSnapshotLocation, keepLast: Int, now: Date = Date()) throws -> DocumentSnapshotInfo {
        let directory = self.directory(for: location)
        // В индексе дата хранится с точностью до секунды: так же округляем сразу.
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let info: DocumentSnapshotInfo
        do {
            lock.lock()
            defer { lock.unlock() }
            try prepareForWrite(directory, location: location)
            var index: Index
            do {
                index = try readIndex(in: directory, quarantine: true)
            } catch DocumentSnapshotError.corrupted {
                // Повреждённый индекс уже перенесён в .corrupt: начинаем с чистого.
                index = Index(version: Self.currentVersion, snapshots: [])
            }
            guard index.version <= Self.currentVersion else { throw DocumentSnapshotError.readOnly }
            let data = Data(text.utf8)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            info = DocumentSnapshotInfo(
                id: UUID(),
                name: trimmed.isEmpty ? ISO8601DateFormatter().string(from: now) : trimmed,
                date: now,
                byteCount: data.count,
                sha256: Self.hex(SHA256.hash(data: data)),
                encoding: encodingName
            )
            let file = textURL(info.id, in: directory)
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                throw DocumentSnapshotError.io(error.localizedDescription)
            }
            index.snapshots.append(info)
            var removed: [UUID] = []
            if keepLast > 0, index.snapshots.count > keepLast {
                let ordered = index.snapshots.enumerated().sorted {
                    $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset
                }
                for entry in ordered.prefix(index.snapshots.count - keepLast) where entry.element.id != info.id {
                    removed.append(entry.element.id)
                }
                index.snapshots.removeAll { removed.contains($0.id) }
            }
            do {
                try writeIndex(index, in: directory)
            } catch {
                try? fileManager.removeItem(at: file)
                throw error
            }
            for id in removed { try? fileManager.removeItem(at: self.textURL(id, in: directory)) }
        }
        postChange(directory)
        return info
    }

    /// Новые сверху. Нет индекса — пусто. Повреждённый индекс переименовывается в `index.json.corrupt`, список пуст.
    func list(location: DocumentSnapshotLocation) -> [DocumentSnapshotInfo] {
        let directory = self.directory(for: location)
        lock.lock()
        defer { lock.unlock() }
        guard let index = try? readIndex(in: directory, quarantine: true) else { return [] }
        return sorted(index.snapshots)
    }

    /// Текст снимка; проверяет sha256 и UTF-8, иначе `.corrupted`.
    func text(id: UUID, location: DocumentSnapshotLocation) throws -> String {
        let directory = self.directory(for: location)
        lock.lock()
        defer { lock.unlock() }
        let index = try readIndex(in: directory, quarantine: false)
        guard let info = index.snapshots.first(where: { $0.id == id }) else { throw DocumentSnapshotError.notFound }
        guard let data = try? Data(contentsOf: textURL(id, in: directory)),
              Self.hex(SHA256.hash(data: data)) == info.sha256,
              let text = String(data: data, encoding: .utf8) else { throw DocumentSnapshotError.corrupted }
        return text
    }

    func rename(id: UUID, to name: String, location: DocumentSnapshotLocation) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentSnapshotError.io("empty") }
        let directory = self.directory(for: location)
        do {
            lock.lock()
            defer { lock.unlock() }
            var index = try readIndex(in: directory, quarantine: false)
            guard index.version <= Self.currentVersion else { throw DocumentSnapshotError.readOnly }
            guard let position = index.snapshots.firstIndex(where: { $0.id == id }) else { throw DocumentSnapshotError.notFound }
            index.snapshots[position].name = trimmed
            try prepareForWrite(directory, location: location)
            try writeIndex(index, in: directory)
        }
        postChange(directory)
    }

    func delete(id: UUID, location: DocumentSnapshotLocation) throws {
        let directory = self.directory(for: location)
        do {
            lock.lock()
            defer { lock.unlock() }
            var index = try readIndex(in: directory, quarantine: false)
            guard index.version <= Self.currentVersion else { throw DocumentSnapshotError.readOnly }
            guard index.snapshots.contains(where: { $0.id == id }) else { throw DocumentSnapshotError.notFound }
            index.snapshots.removeAll { $0.id == id }
            try prepareForWrite(directory, location: location)
            try writeIndex(index, in: directory)
            try? fileManager.removeItem(at: textURL(id, in: directory))
        }
        postChange(directory)
    }

    /// Все снимки файла: удаляет папку целиком (насовсем, не в корзину). Нет папки — ничего не делает.
    func deleteAll(location: DocumentSnapshotLocation) throws {
        let directory = self.directory(for: location)
        do {
            lock.lock()
            defer { lock.unlock() }
            guard fileManager.fileExists(atPath: directory.path) else { return }
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                throw DocumentSnapshotError.io(error.localizedDescription)
            }
        }
        postChange(directory)
    }

    /// Перенос снимков при переименовании файла вне проекта. Нет каталога — ничего не делает;
    /// если у нового пути уже есть каталог — не перезаписывает.
    func moveFile(fromPath: String, toPath: String) throws {
        let source = directory(for: .file(path: fromPath))
        let target = directory(for: .file(path: toPath))
        guard source != target else { return }
        do {
            lock.lock()
            defer { lock.unlock() }
            guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) else { return }
            do {
                try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: target)
            } catch {
                throw DocumentSnapshotError.io(error.localizedDescription)
            }
        }
        postChange(source)
        postChange(target)
    }

    // MARK: Внутреннее

    private func textURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).txt")
    }

    private func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json")
    }

    private func sorted(_ snapshots: [DocumentSnapshotInfo]) -> [DocumentSnapshotInfo] {
        snapshots.enumerated().sorted {
            $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset > $1.offset
        }.map(\.element)
    }

    /// Создаёт каталог. Внутри проекта ни `.laceditor`, ни `snapshots`, ни папка узла не должны быть символической ссылкой.
    private func prepareForWrite(_ directory: URL, location: DocumentSnapshotLocation) throws {
        if case let .project(root, _) = location {
            var current = root.standardizedFileURL
            let components = directory.pathComponents.dropFirst(current.pathComponents.count)
            for component in components {
                current.appendPathComponent(component)
                if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                    throw DocumentSnapshotError.unsafePath
                }
            }
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DocumentSnapshotError.io(error.localizedDescription)
        }
    }

    private func readIndex(in directory: URL, quarantine: Bool) throws -> Index {
        let url = indexURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return Index(version: Self.currentVersion, snapshots: []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url) {
            // Индекс более новой версии читаем, как получится, и никогда не считаем повреждённым.
            if let version = (try? decoder.decode(VersionOnly.self, from: data))?.version, version > Self.currentVersion {
                return (try? decoder.decode(Index.self, from: data)) ?? Index(version: version, snapshots: [])
            }
            if let index = try? decoder.decode(Index.self, from: data) { return index }
        }
        if quarantine { moveAsideCorruptIndex(url) }
        throw DocumentSnapshotError.corrupted
    }

    private func moveAsideCorruptIndex(_ url: URL) {
        var target = url.appendingPathExtension("corrupt")
        var number = 2
        while fileManager.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("index.json.corrupt-\(number)")
            number += 1
        }
        try? fileManager.moveItem(at: url, to: target)
    }

    private func writeIndex(_ index: Index, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(index).write(to: indexURL(in: directory), options: .atomic)
        } catch {
            throw DocumentSnapshotError.io(error.localizedDescription)
        }
    }

    private func postChange(_ directory: URL) {
        let key = directory.path
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: key)
        }
    }

    private static func hash(of path: String) -> String {
        String(hex(SHA256.hash(data: Data(path.utf8))).prefix(32))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
