import Foundation

/// Запрос от команды `lacedit`: адрес вида `laceditor://open?path=…&line=…&column=…` или `laceditor://stdin?id=<UUID>`.
/// Адрес может прийти и из браузера, поэтому разбор строгий: чужие поля, повторы и неверные значения отклоняются целиком.
enum LaceditRequest: Equatable {
    case open(path: String, line: Int?, column: Int?)
    case stdin(id: UUID)

    static let scheme = "laceditor"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else { return nil }
        }
        switch components.host?.lowercased() {
        case "open":
            guard let path = values["path"], Self.isSafe(path: path) else { return nil }
            var line: Int?, column: Int?
            if let text = values["line"] {
                guard let value = Self.positive(text) else { return nil }
                line = value
            }
            if let text = values["column"] {
                guard line != nil, let value = Self.positive(text) else { return nil }
                column = value
            }
            self = .open(path: path, line: line, column: column)
        case "stdin":
            guard values.count == 1, let text = values["id"], let id = UUID(uuidString: text) else { return nil }
            self = .stdin(id: id)
        default:
            return nil
        }
    }

    /// Только абсолютный путь без нулевого символа и без компонента `..`.
    private static func isSafe(path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// Только десятичные цифры, от 1 до 999 999 999 (без знака и пробелов).
    private static func positive(_ text: String) -> Int? {
        guard (1...9).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), value >= 1 else { return nil }
        return value
    }
}

/// Файлы-«ящики» с текстом из стандартного ввода. Скрипт кладёт их в системный временный каталог пользователя.
enum LaceditStdinInbox {
    static let maximumBytes = 50 * 1024 * 1024

    static func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lacedit-stdin", isDirectory: true)
    }

    /// Читает `<id>.txt` и всегда удаляет его. nil: файла нет, это не обычный файл, он чужой, больше лимита или не UTF-8.
    /// Имя файла строится только из разобранного UUID, поэтому выйти из каталога нельзя; ссылку удаляем саму, не её цель.
    static func take(id: UUID, directory: URL = LaceditStdinInbox.directory(), limit: Int = LaceditStdinInbox.maximumBytes) -> String? {
        let url = directory.appendingPathComponent(id.uuidString + ".txt")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum LaceditInstall {
    static let linkPath = "/usr/local/bin/lacedit"

    /// Строка для Терминала. Путь к скрипту берётся в одинарные кавычки, одиночная кавычка внутри экранируется.
    static func command(scriptPath: String) -> String {
        let quoted = "'" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \(quoted) \(linkPath)"
    }
}
