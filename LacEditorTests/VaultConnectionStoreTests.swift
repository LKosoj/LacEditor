import Foundation
import XCTest
@testable import LacEditor

private final class FakeTokens: VaultTokenStoring {
    struct Failure: Error {}
    var values: [UUID: String] = [:]
    var failLoad = false
    var failSave = false
    var failDelete = false
    var deleteCalls = 0

    func load(vaultID: UUID) throws -> String? {
        if failLoad { throw Failure() }
        return values[vaultID]
    }

    func save(_ token: String, vaultID: UUID) throws {
        if failSave { throw Failure() }
        values[vaultID] = token
    }

    func delete(vaultID: UUID) throws {
        deleteCalls += 1
        if failDelete { throw Failure() }
        values[vaultID] = nil
    }
}

@MainActor
final class VaultConnectionStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    private func makeStore(_ tokens: FakeTokens = FakeTokens(), file: URL? = nil) throws -> (VaultConnectionStore, URL) {
        let url = try file ?? directory().appendingPathComponent("VaultConnections.json")
        return (VaultConnectionStore(storageURL: url, tokens: tokens), url)
    }

    private func sample(id: UUID = UUID(), name: String = "Второй мозг") -> VaultConnection {
        VaultConnection(id: id, name: name, tunnel: VaultTunnelSettings(host: "vps.example", user: "me"))
    }

    private func assertStoreError(_ expected: VaultConnectionStoreError, _ block: () throws -> Void, line: UInt = #line) {
        XCTAssertThrowsError(try block(), line: line) { XCTAssertEqual($0 as? VaultConnectionStoreError, expected, line: line) }
    }

    func testEmptyStoreStartsEmpty() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertNil(store.issue)
        XCTAssertFalse(store.isReadOnly)
    }

    func testSaveNewConnectionPersistsAndKeepsTokenOutOfJSON() throws {
        let tokens = FakeTokens()
        let (store, url) = try makeStore(tokens)
        let connection = sample()
        try store.save(connection, token: "  test-token \n")
        XCTAssertEqual(try store.token(for: connection.id), "test-token")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("test-token"))
        XCTAssertTrue(text.contains("vps.example"))
        let reloaded = VaultConnectionStore(storageURL: url, tokens: tokens)
        XCTAssertEqual(reloaded.connections, [connection])
    }

    func testSaveWithNilTokenKeepsOldToken() throws {
        let (store, _) = try makeStore()
        let connection = sample()
        try store.save(connection, token: "old-token")
        try store.save(connection, token: nil)
        XCTAssertEqual(try store.token(for: connection.id), "old-token")
    }

    func testSaveWithBlankTokenKeepsOldToken() throws {
        let (store, _) = try makeStore()
        let connection = sample()
        try store.save(connection, token: "old-token")
        try store.save(connection, token: "   ")
        XCTAssertEqual(try store.token(for: connection.id), "old-token")
    }

    func testSaveWithNewTokenReplaces() throws {
        let (store, _) = try makeStore()
        let connection = sample()
        try store.save(connection, token: "old-token")
        try store.save(connection, token: "new-token")
        XCTAssertEqual(try store.token(for: connection.id), "new-token")
    }

    func testDeleteRemovesTokenFirst() throws {
        let tokens = FakeTokens()
        let (store, url) = try makeStore(tokens)
        let connection = sample()
        try store.save(connection, token: "test-token")
        tokens.failDelete = true
        assertStoreError(.keychain) { try store.delete(connection.id) }
        XCTAssertEqual(store.connections.count, 1)
        tokens.failDelete = false
        try store.delete(connection.id)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertNil(tokens.values[connection.id])
        XCTAssertTrue(VaultConnectionStore(storageURL: url, tokens: tokens).connections.isEmpty)
        assertStoreError(.notFound) { try store.delete(UUID()) }
    }

    func testKeychainFailureOnSaveLeavesNothing() throws {
        let tokens = FakeTokens()
        tokens.failSave = true
        let (store, url) = try makeStore(tokens)
        assertStoreError(.keychain) { try store.save(self.sample(), token: "test-token") }
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testKeychainReadFailureIsReported() throws {
        let tokens = FakeTokens()
        let (store, _) = try makeStore(tokens)
        tokens.failLoad = true
        assertStoreError(.keychainRead) { _ = try store.token(for: UUID()) }
    }

    func testJSONWriteFailureRollsBackNewToken() throws {
        let tokens = FakeTokens()
        let folder = try directory().appendingPathComponent("data", isDirectory: true)
        let (store, _) = try makeStore(tokens, file: folder.appendingPathComponent("VaultConnections.json"))
        // после чтения каталог данных подменяется файлом: запись становится невозможной
        try Data("x".utf8).write(to: folder)
        let connection = sample()
        assertStoreError(.storage) { try store.save(connection, token: "test-token") }
        XCTAssertNil(tokens.values[connection.id])
        XCTAssertTrue(store.connections.isEmpty)
    }

    func testJSONWriteFailureRestoresOldTokenOfExistingConnection() throws {
        let tokens = FakeTokens()
        let folder = try directory().appendingPathComponent("data", isDirectory: true)
        let (store, _) = try makeStore(tokens, file: folder.appendingPathComponent("VaultConnections.json"))
        let connection = sample()
        try store.save(connection, token: "old-token")
        try FileManager.default.removeItem(at: folder)
        try Data("x".utf8).write(to: folder)
        var changed = connection
        changed.name = "Другое имя"
        assertStoreError(.storage) { try store.save(changed, token: "new-token") }
        XCTAssertEqual(tokens.values[connection.id], "old-token")
        XCTAssertEqual(store.connections.first?.name, connection.name)
    }

    func testTokenWithControlOrNonASCIICharactersIsRejected() throws {
        let tokens = FakeTokens()
        let (store, _) = try makeStore(tokens)
        for token in ["to\u{7}ken", "токен", "to ken", "tok\nen"] {
            XCTAssertThrowsError(try store.save(sample(), token: token), token) {
                guard case .invalid(let issue)? = $0 as? VaultConnectionStoreError else { return XCTFail("\($0)") }
                XCTAssertEqual(issue.field, .token)
            }
        }
        XCTAssertTrue(tokens.values.isEmpty)
        XCTAssertTrue(store.connections.isEmpty)
    }

    func testHostWithAtOrSlashHasExplicitMessage() {
        for host in ["me@vps.example", "vps.example/path"] {
            let issue = VaultTunnelSettings(host: host, user: "me").issues().first
            XCTAssertEqual(issue?.field, .host)
            XCTAssertEqual(issue?.message, L10n.tr("服务器中不应含“@”或“/”，用户名请填在“用户名”栏"))
        }
    }

    func testCorruptFileIsMovedAside() throws {
        let url = try directory().appendingPathComponent("VaultConnections.json")
        try Data("not json".utf8).write(to: url)
        let (store, _) = try makeStore(file: url)
        XCTAssertEqual(store.issue, .corrupt(backupName: "VaultConnections.json.corrupt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        XCTAssertTrue(store.connections.isEmpty)
        try store.save(sample(), token: "test-token")
        XCTAssertEqual(store.connections.count, 1)
    }

    func testNewerVersionIsReadOnly() throws {
        let url = try directory().appendingPathComponent("VaultConnections.json")
        let original = Data("{\"version\":99,\"connections\":[]}".utf8)
        try original.write(to: url)
        let (store, _) = try makeStore(file: url)
        XCTAssertEqual(store.issue, .unavailable)
        XCTAssertTrue(store.isReadOnly)
        assertStoreError(.readOnly) { try store.save(self.sample(), token: "test-token") }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testValidationRejectsBadSettings() throws {
        let (store, _) = try makeStore()
        func rejected(_ connection: VaultConnection) -> VaultConnectionField? {
            do { try store.save(connection, token: "test-token"); return nil } catch VaultConnectionStoreError.invalid(let issue) { return issue.field } catch { return .token }
        }
        XCTAssertEqual(rejected(VaultConnection(name: "  ", tunnel: VaultTunnelSettings(host: "h", user: "u"))), .name)
        XCTAssertEqual(rejected(VaultConnection(name: "A", baseURL: "http://example.com")), .baseURL)
        XCTAssertEqual(rejected(VaultConnection(name: "A", tunnel: VaultTunnelSettings(host: "-x", user: "u"))), .host)
        XCTAssertNil(rejected(VaultConnection(name: "A", baseURL: "https://example.com")))
        // при включённом SSH адрес не проверяется
        XCTAssertNil(rejected(VaultConnection(name: "B", baseURL: "ftp://что-то", tunnel: VaultTunnelSettings(host: "h", user: "u"))))
    }

    func testAddressRule() throws {
        XCTAssertNil(try? VaultAddressRule.check("http://example.com"))
        XCTAssertNil(try? VaultAddressRule.check("http://127.0.0.1:8765/path"))
        XCTAssertNil(try? VaultAddressRule.check("http://127.0.0.1:8765?x=1"))
        XCTAssertNil(try? VaultAddressRule.check(""))
        XCTAssertNotNil(try? VaultAddressRule.check(" http://127.0.0.1:8765/ "))
        XCTAssertNotNil(try? VaultAddressRule.check("https://vault.example.com"))
        XCTAssertTrue(VaultAddressRule.isLoopbackHost("LocalHost"))
        XCTAssertTrue(VaultAddressRule.isLoopbackHost("::1"))
        XCTAssertFalse(VaultAddressRule.isLoopbackHost("127.0.0.2"))
        XCTAssertFalse(VaultAddressRule.isLoopbackHost("localhost."))
        XCTAssertFalse(VaultAddressRule.isLoopbackHost("[::ffff:127.0.0.1]"))
        for text in ["http://127.0.0.1 :8765", "https://a\\b.com", "https://пример.рф", "http://127.0.0.1\u{7}", "http://user:pw@127.0.0.1"] {
            XCTAssertNil(try? VaultAddressRule.check(text), text)
        }
        XCTAssertThrowsError(try VaultAddressRule.check("http://example.com")) {
            XCTAssertEqual(($0 as? VaultSettingsIssue)?.message, L10n.tr("未加密的 http:// 只能用于 127.0.0.1 或 localhost，其他地址请使用 https://"))
        }
    }

    func testNormalization() {
        let connection = VaultConnection(name: "  Мозг  ", baseURL: " https://example.com/ ",
                                         tunnel: VaultTunnelSettings(host: " h ", user: " u ", identityFile: "  "),
                                         hiddenRoots: ["b", " a ", "", "b"])
        let normalized = connection.normalized
        XCTAssertEqual(normalized.name, "Мозг")
        XCTAssertEqual(normalized.baseURL, "https://example.com")
        XCTAssertEqual(normalized.tunnel?.host, "h")
        XCTAssertEqual(normalized.tunnel?.user, "u")
        XCTAssertNil(normalized.tunnel?.identityFile)
        XCTAssertEqual(normalized.hiddenRoots, ["a", "b"])
    }

    func testCodableRoundTripAndMissingFields() throws {
        let id = UUID()
        let text = "{\"id\":\"\(id.uuidString)\",\"name\":\"A\"}"
        let decoded = try JSONDecoder().decode(VaultConnection.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, VaultConnection(id: id, name: "A"))
        XCTAssertEqual(decoded.baseURL, VaultConnection.defaultBaseURL)
        let tunnel = try JSONDecoder().decode(VaultTunnelSettings.self, from: Data("{\"host\":\"h\",\"user\":\"u\"}".utf8))
        XCTAssertEqual(tunnel, VaultTunnelSettings(host: "h", user: "u", sshPort: 22, identityFile: nil, remoteAPIPort: 8765))
        let full = VaultConnection(id: id, name: "Б", baseURL: "https://x.example", tunnel: VaultTunnelSettings(host: "h", user: "u", sshPort: 2222, identityFile: "/k", remoteAPIPort: 9000), hiddenRoots: ["private"])
        let again = try JSONDecoder().decode(VaultConnection.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(again, full)
    }

    func testReplaceKeepsOrderAndId() throws {
        let (store, _) = try makeStore()
        let first = sample(name: "Первое")
        let second = sample(name: "Второе")
        try store.save(first, token: "test-token")
        try store.save(second, token: "test-token")
        var changed = first
        changed.name = "Изменено"
        try store.save(changed, token: nil)
        XCTAssertEqual(store.connections.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.connections.first?.name, "Изменено")
    }
}
