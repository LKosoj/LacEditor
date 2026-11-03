import Combine
import Foundation
import Security

/// Хранилище токенов подключений (в приложении — Связка ключей, в тестах — словарь).
protocol VaultTokenStoring {
    func load(vaultID: UUID) throws -> String?
    func save(_ token: String, vaultID: UUID) throws
    func delete(vaultID: UUID) throws
}

enum VaultKeychainError: Error { case failed }

/// Связка ключей: service `<dataDirectoryName>.Vault`, account — `vaultID`. Не синхронизируется через iCloud.
struct VaultKeychainTokenStore: VaultTokenStoring {
    private let namespace: String

    init(namespace: String = AppEnvironment.dataDirectoryName) {
        self.namespace = namespace
    }

    private func query(for vaultID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(namespace).Vault",
         kSecAttrAccount as String: vaultID.uuidString]
    }

    func load(vaultID: UUID) throws -> String? {
        var query = query(for: vaultID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw VaultKeychainError.failed
        }
        return value
    }

    func save(_ token: String, vaultID: UUID) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(for: vaultID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(for: vaultID)
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VaultKeychainError.failed }
        } else if status != errSecSuccess {
            throw VaultKeychainError.failed
        }
    }

    func delete(vaultID: UUID) throws {
        let status = SecItemDelete(query(for: vaultID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultKeychainError.failed }
    }
}

enum VaultConnectionStoreError: LocalizedError, Equatable {
    /// Не прошла `validate()`.
    case invalid(VaultSettingsIssue)
    case keychain
    case keychainRead
    case storage
    /// Файл подключений новее известной версии или не читается.
    case readOnly
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalid(let issue): issue.message
        case .keychain: L10n.tr("无法访问系统钥匙串，令牌未保存")
        case .keychainRead: L10n.tr("无法读取系统钥匙串中的令牌")
        case .storage, .notFound: L10n.tr("无法保存连接")
        case .readOnly: L10n.tr("无法使用连接列表文件，修改将不会保存。")
        }
    }
}

/// Список подключений в `Application Support/<dataDirectoryName>/VaultConnections.json`; токены — в Связке ключей.
/// Повреждённый файл переносится рядом как `.corrupt`; файл новее известной версии не трогается.
@MainActor
final class VaultConnectionStore: ObservableObject {
    static let shared = VaultConnectionStore()

    enum Issue: Equatable {
        /// Файл перенесён под этим именем, список пуст, запись разрешена.
        case corrupt(backupName: String)
        /// Файл не читается, новее известной версии или не удалось его перенести: запись запрещена.
        case unavailable
    }

    private struct FileContents: Codable {
        var version: Int
        var connections: [VaultConnection]
    }

    private static let currentVersion = 1

    @Published private(set) var connections: [VaultConnection] = []
    @Published private(set) var issue: Issue?
    private let storageURL: URL
    private let tokens: VaultTokenStoring

    var isReadOnly: Bool { issue == .unavailable }

    init(storageURL: URL? = nil, tokens: VaultTokenStoring = VaultKeychainTokenStore()) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.tokens = tokens
        load()
    }

    static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("VaultConnections.json")
    }

    /// `token == nil` (или пустой) — токен не менять. Сначала токен, потом файл; при ошибке файла токен нового подключения откатывается.
    func save(_ connection: VaultConnection, token: String?) throws {
        guard !isReadOnly else { throw VaultConnectionStoreError.readOnly }
        let normalized = connection.normalized
        if let issue = normalized.validate().first { throw VaultConnectionStoreError.invalid(issue) }
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = trimmedToken?.isEmpty == false ? trimmedToken : nil
        if let newToken, let issue = VaultConnection.tokenIssue(newToken) { throw VaultConnectionStoreError.invalid(issue) }
        let index = connections.firstIndex { $0.id == normalized.id }
        // Прежний токен нужен, чтобы вернуть его, если файл записать не удалось.
        let previousToken = (index != nil && newToken != nil) ? ((try? tokens.load(vaultID: normalized.id)) ?? nil) : nil
        if let newToken {
            do { try tokens.save(newToken, vaultID: normalized.id) } catch { throw VaultConnectionStoreError.keychain }
        }
        var updated = connections
        if let index { updated[index] = normalized } else { updated.append(normalized) }
        do {
            try persist(updated)
        } catch {
            if newToken != nil {
                if let previousToken { try? tokens.save(previousToken, vaultID: normalized.id) } else { try? tokens.delete(vaultID: normalized.id) }
            }
            throw VaultConnectionStoreError.storage
        }
    }

    /// Сначала токен, потом запись: «осиротевший» секрет хуже «осиротевшей» записи.
    func delete(_ id: UUID) throws {
        guard !isReadOnly else { throw VaultConnectionStoreError.readOnly }
        guard connections.contains(where: { $0.id == id }) else { throw VaultConnectionStoreError.notFound }
        do { try tokens.delete(vaultID: id) } catch { throw VaultConnectionStoreError.keychain }
        do { try persist(connections.filter { $0.id != id }) } catch { throw VaultConnectionStoreError.storage }
    }

    func token(for id: UUID) throws -> String? {
        do { return try tokens.load(vaultID: id) } catch { throw VaultConnectionStoreError.keychainRead }
    }

    var issueMessage: String? {
        switch issue {
        case .corrupt(let backupName): L10n.tr("连接列表文件已损坏，已另存为 %@，当前列表为空。", backupName)
        case .unavailable: L10n.tr("无法使用连接列表文件，修改将不会保存。")
        case nil: nil
        }
    }

    /// Память меняется только после успешной записи файла.
    private func persist(_ newConnections: [VaultConnection]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(FileContents(version: Self.currentVersion, connections: newConnections))
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        connections = newConnections
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
        guard let contents = try? JSONDecoder().decode(FileContents.self, from: data) else {
            moveCorruptFileAside()
            return
        }
        guard contents.version <= Self.currentVersion else {
            issue = .unavailable
            return
        }
        connections = contents.connections
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
