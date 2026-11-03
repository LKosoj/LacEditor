import Foundation

/// Состояние открытой заметки хранилища относительно сервера.
enum VaultNoteSyncState: String, Codable {
    case synced, modified, uploading, newerOnServer, conflict, deletedOnServer, loading
}

/// Запись об открытой заметке: версия сервера, на которой основан локальный файл, и состояние отправки.
struct VaultOpenNoteRecord: Codable, Equatable {
    var serverPath: String
    var baseETag: String
    var baseModifiedNs: Int64?
    /// Размер версии сервера в байтах: проверка «по списку папки» сравнивает `mtime_ns` и размер.
    var baseSize: Int?
    var state: VaultNoteSyncState
    /// Отпечаток текста в очереди отправки.
    var queuedSHA256: String?
    var queuedAt: Date?
    var pendingConflictID: String?
    /// false — заметка осталась только в «Неотправленном».
    var isOpenInTab: Bool
    /// Сервер не принял текст: автоповтора нет, пока текст не изменится или пользователь не нажмёт «Отправить сейчас».
    var uploadIssue: VaultUploadIssue?
    var uploadIssueDetail: String?

    init(serverPath: String, baseETag: String, baseModifiedNs: Int64? = nil, baseSize: Int? = nil,
         state: VaultNoteSyncState, queuedSHA256: String? = nil, queuedAt: Date? = nil,
         pendingConflictID: String? = nil, isOpenInTab: Bool = true,
         uploadIssue: VaultUploadIssue? = nil, uploadIssueDetail: String? = nil) {
        self.serverPath = serverPath
        self.baseETag = baseETag
        self.baseModifiedNs = baseModifiedNs
        self.baseSize = baseSize
        self.state = state
        self.queuedSHA256 = queuedSHA256
        self.queuedAt = queuedAt
        self.pendingConflictID = pendingConflictID
        self.isOpenInTab = isOpenInTab
        self.uploadIssue = uploadIssue
        self.uploadIssueDetail = uploadIssueDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverPath = try container.decode(String.self, forKey: .serverPath)
        baseETag = try container.decode(String.self, forKey: .baseETag)
        baseModifiedNs = try container.decodeIfPresent(Int64.self, forKey: .baseModifiedNs)
        baseSize = try container.decodeIfPresent(Int.self, forKey: .baseSize)
        state = try container.decode(VaultNoteSyncState.self, forKey: .state)
        queuedSHA256 = try container.decodeIfPresent(String.self, forKey: .queuedSHA256)
        queuedAt = try container.decodeIfPresent(Date.self, forKey: .queuedAt)
        pendingConflictID = try container.decodeIfPresent(String.self, forKey: .pendingConflictID)
        isOpenInTab = try container.decodeIfPresent(Bool.self, forKey: .isOpenInTab) ?? true
        // Незнакомое значение отказа (запись новее приложения) читается как «нет отказа»: заметка отправится заново.
        uploadIssue = (try? container.decodeIfPresent(VaultUploadIssue.self, forKey: .uploadIssue)) ?? nil
        uploadIssueDetail = try container.decodeIfPresent(String.self, forKey: .uploadIssueDetail)
    }
}

enum VaultStateStoreError: Error, Equatable {
    case invalidPath, unsafePath
    /// `state.json` нечитаем: перенесён в `state.json.corrupt`.
    case stateDamaged
    /// `state.json` записан более новой версией приложения.
    case readOnly
    case io(String)
}

/// Папка одного хранилища: `Application Support/<имя данных>/Vaults/<vaultID>/`.
/// Внутри: `open/` (открытые заметки), `open-state/` (базы по sha256 пути), `state.json`, `.metadata_never_index`.
/// Не потокобезопасен сам по себе: все вызовы идут из `VaultSyncEngine` (один владелец).
final class VaultStateStore: @unchecked Sendable {
    static let currentVersion = 1

    private struct StateFile: Codable {
        var version: Int
        var notes: [VaultOpenNoteRecord]
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    /// Стандартизованная папка хранилища.
    let root: URL
    private let fileManager: FileManager
    /// true, если `state.json` записан версией новее известной: `save` откажет.
    private(set) var isReadOnly = false

    /// `root` заменяет весь путь (папка самого хранилища); нужен тестам.
    init(vaultID: UUID, root: URL? = nil, fileManager: FileManager = .default) {
        self.root = (root ?? Self.defaultRoot(vaultID: vaultID)).standardizedFileURL
        self.fileManager = fileManager
    }

    static func defaultRoot(vaultID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("Vaults", isDirectory: true)
            .appendingPathComponent(vaultID.uuidString, isDirectory: true)
    }

    var openDirectory: URL { root.appendingPathComponent("open", isDirectory: true) }
    var openStateDirectory: URL { root.appendingPathComponent("open-state", isDirectory: true) }
    var stateFileURL: URL { root.appendingPathComponent("state.json") }
    private var attachmentsDirectory: URL { root.appendingPathComponent("open-attachments", isDirectory: true) }

    // MARK: state.json

    func load() throws -> [String: VaultOpenNoteRecord] {
        isReadOnly = false
        guard fileManager.fileExists(atPath: stateFileURL.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: stateFileURL) } catch { throw VaultStateStoreError.io(error.localizedDescription) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let version = (try? decoder.decode(VersionOnly.self, from: data))?.version else {
            moveAsideCorruptState()
            throw VaultStateStoreError.stateDamaged
        }
        if version > Self.currentVersion {
            isReadOnly = true
            return Self.index((try? decoder.decode(StateFile.self, from: data))?.notes ?? [])
        }
        guard let file = try? decoder.decode(StateFile.self, from: data) else {
            moveAsideCorruptState()
            throw VaultStateStoreError.stateDamaged
        }
        return Self.index(file.notes)
    }

    func save(_ records: [String: VaultOpenNoteRecord]) throws {
        if isReadOnly { throw VaultStateStoreError.readOnly }
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = StateFile(version: Self.currentVersion, notes: records.values.sorted { $0.serverPath < $1.serverPath })
        do {
            try encoder.encode(file).write(to: stateFileURL, options: .atomic)
        } catch {
            throw VaultStateStoreError.io(error.localizedDescription)
        }
    }

    /// Записи с небезопасным путём отбрасываются: `state.json` мог быть изменён снаружи.
    private static func index(_ notes: [VaultOpenNoteRecord]) -> [String: VaultOpenNoteRecord] {
        var result: [String: VaultOpenNoteRecord] = [:]
        for note in notes where VaultPath.validated(note.serverPath) != nil { result[note.serverPath] = note }
        return result
    }

    private func moveAsideCorruptState() {
        var target = stateFileURL.appendingPathExtension("corrupt")
        var number = 2
        while fileManager.fileExists(atPath: target.path) {
            target = root.appendingPathComponent("state.json.corrupt-\(number)")
            number += 1
        }
        try? fileManager.moveItem(at: stateFileURL, to: target)
    }

    /// Есть перенесённый повреждённый `state.json` (`state.json.corrupt`, `-2`…).
    var hasQuarantinedState: Bool {
        ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).contains { $0.hasPrefix("state.json.corrupt") }
    }

    /// Переименовывает `state.json.corrupt*` в `state.json.acknowledged*`: данные остаются, блокировка уборки снимается.
    func acknowledgeQuarantine() {
        let names = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("state.json.corrupt") }
        for name in names {
            let newName = "state.json.acknowledged" + name.dropFirst("state.json.corrupt".count)
            try? fileManager.moveItem(at: root.appendingPathComponent(name), to: root.appendingPathComponent(newName))
        }
    }

    /// В `open/` есть хоть какой-то файл (на случай пустого списка записей).
    var hasOpenFiles: Bool {
        guard let walker = fileManager.enumerator(atPath: openDirectory.path) else { return false }
        for case let name as String in walker {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: openDirectory.appendingPathComponent(name).path, isDirectory: &isDirectory),
               !isDirectory.boolValue { return true }
        }
        return false
    }

    // MARK: Заметки и базы

    /// Адрес файла заметки внутри `open/`; диск не трогает.
    func noteURL(for serverPath: String) -> URL? {
        VaultPath.localURL(for: serverPath, under: openDirectory)
    }

    /// Обратное преобразование: путь на сервере для файла внутри `open/`, иначе nil.
    func serverPath(forLocalURL url: URL) -> String? {
        let prefix = openDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(prefix) else { return nil }
        return VaultPath.validated(String(path.dropFirst(prefix.count)))
    }

    func writeNote(_ data: Data, serverPath: String) throws -> URL {
        guard let url = noteURL(for: serverPath) else { throw VaultStateStoreError.invalidPath }
        try ensureRoot()
        try checkNoSymlinks(from: openDirectory, to: url)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw VaultStateStoreError.unsafePath
        }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw VaultStateStoreError.io(error.localizedDescription)
        }
        return url
    }

    func writeBase(_ data: Data, serverPath: String) throws {
        let url = try baseURL(for: serverPath)
        try ensureRoot()
        do { try data.write(to: url, options: .atomic) } catch { throw VaultStateStoreError.io(error.localizedDescription) }
    }

    func readBase(serverPath: String) throws -> Data? {
        try readIfExists(try baseURL(for: serverPath))
    }

    func readNote(serverPath: String) throws -> Data? {
        guard let url = noteURL(for: serverPath) else { throw VaultStateStoreError.invalidPath }
        return try readIfExists(url)
    }

    /// Файл и база насовсем (не в корзину); нет файла — не ошибка; опустевшие папки внутри `open/` убираются.
    func removeNote(serverPath: String) throws {
        guard let url = noteURL(for: serverPath) else { throw VaultStateStoreError.invalidPath }
        let base = try baseURL(for: serverPath)
        if isSymbolicLink(openDirectory) || isSymbolicLink(openStateDirectory) { throw VaultStateStoreError.unsafePath }
        try checkNoSymlinks(from: openDirectory, to: url.deletingLastPathComponent())
        var failure: String?
        for target in [url, base] where exists(target) {
            do { try fileManager.removeItem(at: target) } catch { failure = error.localizedDescription }
        }
        var folder = url.deletingLastPathComponent()
        let stop = openDirectory.standardizedFileURL.path
        while folder.standardizedFileURL.path != stop, folder.path.hasPrefix(stop + "/"), isEmptyDirectory(folder) {
            do { try fileManager.removeItem(at: folder) } catch { break }
            folder = folder.deletingLastPathComponent()
        }
        if let failure { throw VaultStateStoreError.io(failure) }
    }

    /// Удаляет из `open/` и `open-state/` всё, чего нет в `keeping` (пути на сервере). Трогает только
    /// `open/`, `open-state/` и `open-attachments/`; остальное в папке хранилища (`requests.json` и т. п.) не касается.
    /// Возвращает пути удалённых сирот. Сбой одного удаления не останавливает обход: ошибка бросается в конце.
    @discardableResult
    func cleanupOrphans(keeping: Set<String>) throws -> [String] {
        var removed: [String] = []
        var failure: String?
        func remove(_ url: URL) {
            do { try fileManager.removeItem(at: url) } catch { failure = error.localizedDescription }
        }
        func walk(_ directory: URL, relative: String) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let path = relative.isEmpty ? name : relative + "/" + name
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true {
                    remove(url)
                } else if values?.isDirectory == true {
                    walk(url, relative: path)
                    if isEmptyDirectory(url) { remove(url) }
                // `contains` сравнивает строки по каноническому Unicode: «й» в разных видах считается одним путём.
                } else if keeping.contains(path), VaultPath.validated(path) != nil {
                    continue
                } else {
                    remove(url)
                    if VaultPath.validated(path) != nil { removed.append(path) }
                }
            }
        }
        // Папка-ссылка на чужое место: удаляем саму ссылку, внутрь не заходим.
        if isSymbolicLink(openDirectory) { remove(openDirectory) } else if exists(openDirectory) { walk(openDirectory, relative: "") }
        if isSymbolicLink(openStateDirectory) { remove(openStateDirectory) }
        else if exists(openStateDirectory), let names = try? fileManager.contentsOfDirectory(atPath: openStateDirectory.path) {
            let wanted = Set(keeping.compactMap { try? baseURL(for: $0).lastPathComponent })
            for name in names where !wanted.contains(name) { remove(openStateDirectory.appendingPathComponent(name)) }
        }
        if keeping.isEmpty, exists(attachmentsDirectory) { remove(attachmentsDirectory) }
        if let failure { throw VaultStateStoreError.io(failure) }
        return removed.sorted()
    }

    /// Вся папка хранилища (при удалении подключения).
    func removeAll() throws {
        guard exists(root) else { return }
        do { try fileManager.removeItem(at: root) } catch { throw VaultStateStoreError.io(error.localizedDescription) }
    }

    // MARK: Внутреннее

    private func baseURL(for serverPath: String) throws -> URL {
        guard let path = VaultPath.validated(serverPath) else { throw VaultStateStoreError.invalidPath }
        return openStateDirectory.appendingPathComponent(VaultClient.sha256Hex(Data(path.utf8)) + ".base")
    }

    /// Существует ли что-то по адресу, включая «битую» символическую ссылку.
    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func isEmptyDirectory(_ url: URL) -> Bool {
        (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true
    }

    private func readIfExists(_ url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do { return try Data(contentsOf: url) } catch { throw VaultStateStoreError.io(error.localizedDescription) }
    }

    /// Создаёт папки и `.metadata_never_index`; сами `root`, `open`, `open-state` не должны быть ссылками.
    private func ensureRoot() throws {
        do {
            for directory in [root, openDirectory, openStateDirectory] {
                if isSymbolicLink(directory) { throw VaultStateStoreError.unsafePath }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let marker = root.appendingPathComponent(".metadata_never_index")
            if !fileManager.fileExists(atPath: marker.path) { try Data().write(to: marker) }
        } catch let error as VaultStateStoreError {
            throw error
        } catch {
            throw VaultStateStoreError.io(error.localizedDescription)
        }
    }

    /// Ни один существующий компонент пути от `base` до `url` не должен быть символической ссылкой.
    private func checkNoSymlinks(from base: URL, to url: URL) throws {
        var current = base.standardizedFileURL
        for component in url.standardizedFileURL.pathComponents.dropFirst(current.pathComponents.count) {
            current.appendPathComponent(component)
            if isSymbolicLink(current) { throw VaultStateStoreError.unsafePath }
        }
    }
}
