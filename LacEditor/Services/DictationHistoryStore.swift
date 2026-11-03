import Combine
import Foundation

/// Одна диктовка: что распознано, что получилось после очистки и куда вставлялось. Аудио не хранится.
struct DictationHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    /// Имя документа на момент диктовки (документ мог быть закрыт позже).
    var documentName: String
    /// Распознанный текст без очистки; не пустой.
    var rawText: String
    /// Текст после очистки моделью; nil, если очистка выключена или не удалась.
    var cleanedText: String?
    /// Модель распознавания речи (`AIModelProfile.modelID`).
    var transcriptionModel: String
    /// Модель очистки; nil, если очистки не было.
    var cleanupModel: String?

    init(id: UUID = UUID(), date: Date, documentName: String, rawText: String, cleanedText: String?,
         transcriptionModel: String, cleanupModel: String?) {
        self.id = id
        self.date = date
        self.documentName = documentName
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.transcriptionModel = transcriptionModel
        self.cleanupModel = cleanupModel
    }
}

/// Последние диктовки в `Application Support/<AppEnvironment.dataDirectoryName>/DictationHistory.json`
/// (`{"version":1,"entries":[…]}`, запись атомарная, новые записи первыми).
/// Повреждённый файл переносится рядом как `.corrupt`; файл новее известной версии не трогается.
@MainActor
final class DictationHistoryStore: ObservableObject {
    static let shared = DictationHistoryStore()
    static let defaultLimit = 20
    static let defaultRetention: TimeInterval = 14 * 24 * 60 * 60

    enum Issue: Equatable {
        /// Файл перенесён под этим именем, список пуст, запись разрешена.
        case corrupt(backupName: String)
        /// Файл не читается, новее известной версии или не удалось его перенести: запись запрещена.
        case unavailable
    }

    enum StoreError: LocalizedError, Equatable {
        case readOnly, emptyText

        var errorDescription: String? {
            switch self {
            case .readOnly: L10n.tr("无法使用听写历史文件，修改将不会保存。")
            case .emptyText: L10n.tr("听写历史不能保存空文字。")
            }
        }
    }

    private struct FileContents: Codable {
        var version: Int
        var entries: [DictationHistoryEntry]
    }

    private struct FileVersion: Decodable {
        var version: Int
    }

    private static let currentVersion = 1

    /// От новых к старым, без просроченных на момент последней операции.
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var issue: Issue?
    private let storageURL: URL
    private let now: () -> Date
    private let limit: Int
    private let retention: TimeInterval

    var isReadOnly: Bool { issue == .unavailable }

    var issueMessage: String? {
        switch issue {
        case .corrupt(let backupName): L10n.tr("听写历史文件已损坏，已另存为 %@，当前列表为空。", backupName)
        case .unavailable: L10n.tr("无法使用听写历史文件，修改将不会保存。")
        case nil: nil
        }
    }

    init(storageURL: URL? = nil, now: @escaping () -> Date = Date.init,
         limit: Int = DictationHistoryStore.defaultLimit,
         retention: TimeInterval = DictationHistoryStore.defaultRetention) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.now = now
        self.limit = limit
        self.retention = retention
        load()
    }

    /// Добавляет запись первой, удаляет просроченные и лишние сверх `limit`, пишет файл.
    @discardableResult
    func add(rawText: String, cleanedText: String?, documentName: String,
             transcriptionModel: String, cleanupModel: String?) throws -> DictationHistoryEntry {
        guard !isReadOnly else { throw StoreError.readOnly }
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.emptyText }
        let entry = DictationHistoryEntry(date: now(), documentName: documentName, rawText: rawText,
                                          cleanedText: cleanedText, transcriptionModel: transcriptionModel,
                                          cleanupModel: cleanupModel)
        try persist(kept([entry] + entries))
        return entry
    }

    /// Записи не старше `retention` относительно `now()`, не больше `limit`. Файл не пишет.
    func recent() -> [DictationHistoryEntry] {
        kept(entries)
    }

    func entry(id: UUID) -> DictationHistoryEntry? {
        recent().first { $0.id == id }
    }

    /// Удаляет все записи, в том числе просроченные.
    func clear() throws {
        guard !isReadOnly else { throw StoreError.readOnly }
        try persist([])
    }

    static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("DictationHistory.json")
    }

    /// Запись ровно `retention` назад ещё жива; порядок — от новых к старым.
    private func kept(_ list: [DictationHistoryEntry]) -> [DictationHistoryEntry] {
        let threshold = now().addingTimeInterval(-retention)
        let alive = list.enumerated().filter { $0.element.date >= threshold }
        let sorted = alive.sorted { left, right in
            left.element.date != right.element.date ? left.element.date > right.element.date : left.offset < right.offset
        }
        return Array(sorted.map(\.element).prefix(limit))
    }

    /// Память меняется только после успешной записи файла.
    private func persist(_ newEntries: [DictationHistoryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(FileContents(version: Self.currentVersion, entries: newEntries))
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        entries = newEntries
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        } catch {
            issue = .unavailable
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Сначала только версия: у более новой версии схема записей может быть другой, такой файл не трогаем.
        guard let header = try? decoder.decode(FileVersion.self, from: data) else {
            moveCorruptFileAside()
            return
        }
        guard header.version <= Self.currentVersion else {
            issue = .unavailable
            return
        }
        guard let contents = try? decoder.decode(FileContents.self, from: data) else {
            moveCorruptFileAside()
            return
        }
        let alive = kept(contents.entries)
        // Просроченный текст не должен оставаться на диске.
        if alive.count != contents.entries.count { try? persist(alive) }
        entries = alive
    }

    /// Свободное имя копии: `.corrupt`, затем `.corrupt-2`, `-3`…; прежние копии не затираются.
    private func moveCorruptFileAside() {
        let directory = storageURL.deletingLastPathComponent()
        let base = storageURL.lastPathComponent + ".corrupt"
        var name = base
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base)-\(number)"
            number += 1
        }
        do {
            try FileManager.default.moveItem(at: storageURL, to: directory.appendingPathComponent(name))
            issue = .corrupt(backupName: name)
        } catch {
            issue = .unavailable
        }
    }
}
