import Foundation
import Security

struct AIKeychainStore {
    private let namespace: String

    init(namespace: String = AppEnvironment.dataDirectoryName) {
        self.namespace = namespace
    }

    private func query(for account: String, baseURL: String) throws -> [String: Any] {
        let url = try AIModelProfile.normalizedBaseURL(baseURL)
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(namespace).AI",
         kSecAttrAccount as String: "\(account):\(url.absoluteString)"]
    }

    private func load(account: String, baseURL: String) throws -> String? {
        var query = try query(for: account, baseURL: baseURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AIError.keychain }
        return value
    }

    private func save(_ key: String, account: String, baseURL: String) throws {
        let data = Data(key.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(try query(for: account, baseURL: baseURL) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = try query(for: account, baseURL: baseURL)
            item[kSecValueData as String] = data
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AIError.keychain }
        } else if status != errSecSuccess {
            throw AIError.keychain
        }
    }

    private func delete(account: String, baseURL: String) throws {
        let status = SecItemDelete(try query(for: account, baseURL: baseURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.keychain }
    }

    func load(for role: AIRole, baseURL: String) throws -> String? { try load(account: role.rawValue, baseURL: baseURL) }
    func save(_ key: String, for role: AIRole, baseURL: String) throws { try save(key, account: role.rawValue, baseURL: baseURL) }
    func delete(for role: AIRole, baseURL: String) throws { try delete(account: role.rawValue, baseURL: baseURL) }

    func load(for kind: JinaServiceKind, baseURL: String) throws -> String? { try load(account: "jina.\(kind.rawValue)", baseURL: baseURL) }
    func save(_ key: String, for kind: JinaServiceKind, baseURL: String) throws { try save(key, account: "jina.\(kind.rawValue)", baseURL: baseURL) }
    func delete(for kind: JinaServiceKind, baseURL: String) throws { try delete(account: "jina.\(kind.rawValue)", baseURL: baseURL) }

}
