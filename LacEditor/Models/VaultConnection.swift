import Foundation

/// Поле настроек подключения, к которому относится ошибка (лист ставит подсветку и фокус).
enum VaultConnectionField: Hashable {
    case name, baseURL, host, user, sshPort, identityFile, remoteAPIPort, token
}

/// Ошибка настроек: поле и готовый локализованный текст («рядом с полем»).
struct VaultSettingsIssue: Error, Equatable {
    var field: VaultConnectionField
    var message: String
}

/// Настройки SSH-туннеля до сервера.
struct VaultTunnelSettings: Codable, Equatable {
    var host: String
    var user: String
    var sshPort: Int = 22
    /// Пусто — ключи и настройки из `~/.ssh/config` и агента.
    var identityFile: String?
    var remoteAPIPort: Int = 8765

    init(host: String, user: String, sshPort: Int = 22, identityFile: String? = nil, remoteAPIPort: Int = 8765) {
        self.host = host
        self.user = user
        self.sshPort = sshPort
        self.identityFile = identityFile
        self.remoteAPIPort = remoteAPIPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        user = try container.decode(String.self, forKey: .user)
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        remoteAPIPort = try container.decodeIfPresent(Int.self, forKey: .remoteAPIPort) ?? 8765
    }

    /// Путь ключа без пробелов по краям; nil для пустого.
    var trimmedIdentityFile: String? {
        guard let value = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    /// Правила полей: хост и пользователь не начинаются с «-» (иначе ssh примет их за параметр), порты 1–65535.
    func issues() -> [VaultSettingsIssue] {
        var result: [VaultSettingsIssue] = []
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty {
            result.append(VaultSettingsIssue(field: .host, message: L10n.tr("请输入 SSH 服务器")))
        } else if host.contains("@") || host.contains("/") {
            result.append(VaultSettingsIssue(field: .host, message: L10n.tr("服务器中不应含“@”或“/”，用户名请填在“用户名”栏")))
        } else if host.hasPrefix("-") || !host.unicodeScalars.allSatisfy(Self.isHostScalar) {
            result.append(VaultSettingsIssue(field: .host, message: L10n.tr("服务器不能以“-”开头，也不能含空格")))
        }
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty {
            result.append(VaultSettingsIssue(field: .user, message: L10n.tr("请输入 SSH 用户名")))
        } else if user.hasPrefix("-") || !user.unicodeScalars.allSatisfy(Self.isUserScalar) {
            result.append(VaultSettingsIssue(field: .user, message: L10n.tr("用户名不能以“-”开头，也不能含空格或“@”")))
        }
        if !Self.isValidPort(sshPort) {
            result.append(VaultSettingsIssue(field: .sshPort, message: L10n.tr("端口应为 1–65535 的数字")))
        }
        if let path = trimmedIdentityFile, path.contains(where: \.isNewline) {
            result.append(VaultSettingsIssue(field: .identityFile, message: L10n.tr("密钥文件路径无效")))
        }
        if !Self.isValidPort(remoteAPIPort) {
            result.append(VaultSettingsIssue(field: .remoteAPIPort, message: L10n.tr("端口应为 1–65535 的数字")))
        }
        return result
    }

    private static func isHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || ".-_:%".unicodeScalars.contains(scalar)
    }

    private static func isUserScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || "._+-".unicodeScalars.contains(scalar)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }
}

/// Сохранённое подключение к серверу хранилища. Токен сюда не входит: он лежит в Связке ключей.
struct VaultConnection: Codable, Identifiable, Equatable {
    static let defaultBaseURL = "http://127.0.0.1:8765"

    /// Токен уходит в заголовок HTTP: только видимые ASCII-символы (без пробелов и управляющих).
    static func tokenIssue(_ token: String) -> VaultSettingsIssue? {
        if token.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) { return nil }
        return VaultSettingsIssue(field: .token, message: L10n.tr("令牌含有无效字符（只允许可见的 ASCII 字符）"))
    }

    /// vaultID.
    var id: UUID
    var name: String
    /// Прямой адрес, когда туннель выключен.
    var baseURL: String
    /// nil — без SSH.
    var tunnel: VaultTunnelSettings?
    /// Корни хранилища, скрытые пользователем («Скрыть разделы»).
    var hiddenRoots: [String]

    init(id: UUID = UUID(), name: String, baseURL: String = VaultConnection.defaultBaseURL,
         tunnel: VaultTunnelSettings? = nil, hiddenRoots: [String] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.tunnel = tunnel
        self.hiddenRoots = hiddenRoots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        tunnel = try container.decodeIfPresent(VaultTunnelSettings.self, forKey: .tunnel)
        hiddenRoots = try container.decodeIfPresent([String].self, forKey: .hiddenRoots) ?? []
    }

    /// Адрес проверяется только без туннеля: с туннелем клиент ходит на свой loopback-порт.
    func validate() -> [VaultSettingsIssue] {
        var result: [VaultSettingsIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(VaultSettingsIssue(field: .name, message: L10n.tr("请输入连接名称")))
        }
        if let tunnel {
            result.append(contentsOf: tunnel.issues())
        } else {
            do { _ = try VaultAddressRule.check(baseURL) } catch let issue as VaultSettingsIssue { result.append(issue) } catch {}
        }
        return result
    }

    /// Значения без пробелов по краям; адрес без хвостового «/»; скрытые разделы без пустых и повторов, по алфавиту.
    var normalized: VaultConnection {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasSuffix("/") { address.removeLast() }
        copy.baseURL = address
        if var tunnel {
            tunnel.host = tunnel.host.trimmingCharacters(in: .whitespacesAndNewlines)
            tunnel.user = tunnel.user.trimmingCharacters(in: .whitespacesAndNewlines)
            tunnel.identityFile = tunnel.trimmedIdentityFile
            copy.tunnel = tunnel
        }
        let roots = hiddenRoots.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        copy.hiddenRoots = Array(Set(roots)).sorted()
        return copy
    }
}

/// Правило адреса: https — любой хост, http — только loopback (токен не уходит по открытому каналу).
enum VaultAddressRule {
    static func isLoopbackHost(_ host: String) -> Bool {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        return value == "127.0.0.1" || value == "localhost" || value == "::1"
    }

    private enum Verdict { case ok, malformed, insecure }

    /// Пробелы, управляющие и не-ASCII символы, «\»: такие адреса разные разборщики URL читают по-разному.
    static func hasForbiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value <= 0x20 || $0.value >= 0x7F || $0 == "\\" }
    }

    private static func verdict(_ url: URL) -> Verdict {
        guard !hasForbiddenCharacters(url.absoluteString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return .malformed }
        if scheme == "http", !isLoopbackHost(host) { return .insecure }
        return .ok
    }

    static func isAllowed(_ url: URL) -> Bool { verdict(url) == .ok }

    /// Бросает `VaultSettingsIssue(field: .baseURL, …)`: «Адрес неверен» либо «http только для loopback».
    static func check(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let malformed = VaultSettingsIssue(field: .baseURL, message: L10n.tr("地址无效，示例：http://127.0.0.1:8765"))
        guard !trimmed.isEmpty, !hasForbiddenCharacters(trimmed), let url = URL(string: trimmed) else { throw malformed }
        switch verdict(url) {
        case .ok: return url
        case .malformed: throw malformed
        case .insecure:
            throw VaultSettingsIssue(field: .baseURL,
                                     message: L10n.tr("未加密的 http:// 只能用于 127.0.0.1 或 localhost，其他地址请使用 https://"))
        }
    }
}
