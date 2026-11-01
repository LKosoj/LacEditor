import Foundation

/// Аудио, видео и PDF из адресов `data:`: разбор адреса и временные файлы для плеера и открытия ссылки.
enum MarkdownDataMedia {
    /// Единственный источник расширения и белый список типов: другого в файл не пишется.
    static let extensions: [String: String] = [
        "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav",
        "audio/ogg": "ogg", "audio/aac": "aac", "audio/flac": "flac",
        "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm",
        "application/pdf": "pdf"
    ]

    struct Parsed {
        let mimeType: String
        let fileExtension: String
        let data: Data
    }

    /// Тип из заголовка адреса, без разбора данных. `nil`, если адрес не `data:` или тип не из таблицы.
    static func fileExtension(forAddress address: String) -> String? {
        header(of: address).flatMap { extensions[$0.mime] }
    }

    /// Токен без записи в таблице (`#lac-media-…`) данных не несёт: его не разбираем.
    static func parse(_ address: String) -> Parsed? {
        guard let head = header(of: address), let fileExtension = extensions[head.mime] else { return nil }
        var payload = Substring(head.payload)
        if let hash = payload.firstIndex(of: "#") {
            if payload[hash...].hasPrefix("#lac-media-") { return nil }
            payload = payload[..<hash]
        }
        let data: Data
        if head.isBase64 {
            var text = payload.filter { !$0.isWhitespace && $0 != "=" }
            if text.count % 4 == 1 { return nil }
            while text.count % 4 != 0 { text.append("=") }
            guard let decoded = Data(base64Encoded: text) else { return nil }
            data = decoded
        } else {
            data = percentDecoded(payload)
        }
        return Parsed(mimeType: head.mime, fileExtension: fileExtension, data: data)
    }

    private static func header(of address: String) -> (mime: String, isBase64: Bool, payload: Substring)? {
        guard address.prefix(5).lowercased() == "data:", let comma = address.firstIndex(of: ",") else { return nil }
        let parts = address[address.index(address.startIndex, offsetBy: 5)..<comma].split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let mime = first.trimmingCharacters(in: .whitespaces).lowercased()
        let isBase64 = parts.dropFirst().last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() == "base64" } ?? false
        return (mime, isBase64, address[address.index(after: comma)...])
    }

    private static func percentDecoded(_ text: Substring) -> Data {
        var bytes: [UInt8] = []
        let source = Array(text.utf8)
        bytes.reserveCapacity(source.count)
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var index = 0
        while index < source.count {
            if source[index] == 37, index + 2 < source.count, let high = digit(source[index + 1]), let low = digit(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return Data(bytes)
    }

    fileprivate static func hash(_ address: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in address.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return value
    }
}

/// Временные файлы одного документа в `<tmp>/LacEditor-media/<pid>/<id документа>/`. Один адрес даёт один файл.
/// Номер процесса в пути нужен, чтобы второй запущенный LacEditor не удалил файлы первого.
final class MarkdownTemporaryMedia: @unchecked Sendable {
    static var defaultRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("LacEditor-media", isDirectory: true) }

    private let directory: URL
    private let lock = NSLock()
    private var closed = false
    /// Адрес каждого записанного файла: хэш короткий, поэтому совпадение имени ещё не значит те же данные.
    private var addresses: [String: String] = [:]

    init(documentID: UUID, root: URL = MarkdownTemporaryMedia.defaultRoot) {
        directory = root.appendingPathComponent(String(getpid()), isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    /// Путь к файлу с данными адреса. `nil` — тип не из таблицы, данные не разобрались или документ закрыт; тогда ничего не пишется.
    func fileURL(forAddress address: String) throws -> URL? {
        guard let fileExtension = MarkdownDataMedia.fileExtension(forAddress: address) else { return nil }
        let base = String(MarkdownDataMedia.hash(address), radix: 16) + "-" + String(address.utf8.count, radix: 16)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        var name = base + "." + fileExtension
        var suffix = 1
        while let known = addresses[name], known != address {
            suffix += 1
            name = base + "-" + String(suffix) + "." + fileExtension
        }
        let file = directory.appendingPathComponent(name)
        if addresses[name] != nil, FileManager.default.fileExists(atPath: file.path) { return file }
        guard let parsed = MarkdownDataMedia.parse(address) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try parsed.data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        addresses[name] = address
        return file
    }

    /// Документ закрыт: файлы удаляются, а запоздавшая фоновая запись новых не создаст.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        try? FileManager.default.removeItem(at: directory)
    }

    /// При запуске: каталоги процессов, которых уже нет.
    static func removeStale(root: URL = defaultRoot) {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            if let process = Int32(item.lastPathComponent), kill(process, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// При выходе: все файлы этого процесса.
    static func removeEverything(root: URL = defaultRoot) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(String(getpid()), isDirectory: true))
    }
}
