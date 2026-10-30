import Foundation

enum NoteTemplateService {
    static let dailyTemplateName = "daily.md"
    static let defaultDateFormat = "yyyy-MM-dd"

    enum TemplateError: LocalizedError {
        case notUTF8, dailyFolderInvalid, dailyFolderMissing, dailyNoteInvalid

        var errorDescription: String? {
            switch self {
            case .notUTF8: L10n.tr("模板必须是 UTF-8 文本。")
            case .dailyFolderInvalid: L10n.tr("无法使用每日笔记文件夹")
            case .dailyFolderMissing: L10n.tr("每日笔记文件夹不存在")
            case .dailyNoteInvalid: L10n.tr("每日笔记路径不是普通文件")
            }
        }
    }

    enum DailyNotePlan: Equatable {
        case open(URL)
        case create(URL, String)
    }

    /// Подставляет `{{title}}`, `{{date}}`, `{{time}}` за один проход: подставленный текст заново не разбирается.
    static func render(_ template: String, title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let values = [
            "{{title}}": title,
            "{{date}}": formatted(date, format: defaultDateFormat, timeZone: timeZone),
            "{{time}}": formatted(date, format: "HH:mm", timeZone: timeZone),
        ]
        var result = String.UnicodeScalarView()
        var rest = template.unicodeScalars[...]
        while let start = rest.firstIndex(where: { $0 == "{" }) {
            result.append(contentsOf: rest[rest.startIndex..<start])
            rest = rest[start...]
            if let (token, value) = values.first(where: { rest.starts(with: $0.key.unicodeScalars) }) {
                result.append(contentsOf: value.unicodeScalars)
                rest = rest.dropFirst(token.unicodeScalars.count)
            } else {
                result.append(rest[start])
                rest = rest.dropFirst()
            }
        }
        result.append(contentsOf: rest)
        return String(result)
    }

    /// Существующий путь заметки дня должен быть обычным файлом; каталог и символическая ссылка отклоняются.
    static func requireRegularFile(_ url: URL) throws {
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
              type == .typeRegular else { throw TemplateError.dailyNoteInvalid }
    }

    /// Имя файла заметки дня с `.md`; пустой или непригодный для имени формат заменяется на `yyyy-MM-dd`.
    static func dailyNoteFileName(date: Date, format: String, timeZone: TimeZone = .current) -> String {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = trimmed.isEmpty ? "" : formatted(date, format: trimmed, timeZone: timeZone)
        if name.isEmpty || name.contains("/") || name.contains(":") || name == "." || name == ".." {
            name = formatted(date, format: defaultDateFormat, timeZone: timeZone)
        }
        return name + ".md"
    }

    /// Добавляет `.md`, если нет `.md`/`.markdown`; пустое имя остаётся пустым, чтобы его отклонила проверка имени.
    static func normalizedFileName(_ input: String) -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? name : name + ".md"
    }

    static func listTemplates(in folder: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .filter { url in
                guard ["md", "markdown"].contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
                return values.isDirectory != true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func readTemplate(_ url: URL) throws -> String {
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw TemplateError.notUTF8 }
        return text
    }

    /// Относительная папка внутри корня; пустая строка — сам корень, абсолютный путь и `..` отклоняются.
    static func resolveSubfolder(_ relative: String, root: URL) -> URL? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return root }
        guard !trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
    }

    /// Решает, что делать для заметки дня; `validateDirectory` проверяет каталог так же, как запись в рабочей папке.
    static func dailyNotePlan(root: URL, subfolder: String, templatesFolder: String, date: Date, format: String,
                              timeZone: TimeZone = .current,
                              validateDirectory: (URL) throws -> Void) throws -> DailyNotePlan {
        guard let folder = resolveSubfolder(subfolder, root: root) else { throw TemplateError.dailyFolderInvalid }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TemplateError.dailyFolderMissing
        }
        try validateDirectory(folder)
        let fileName = dailyNoteFileName(date: date, format: format, timeZone: timeZone)
        let url = folder.appendingPathComponent(fileName).standardizedFileURL
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            try requireRegularFile(url)
            return .open(url)
        }
        var contents = ""
        let templatesPath = templatesFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !templatesPath.isEmpty {
            let template = URL(fileURLWithPath: templatesPath, isDirectory: true).appendingPathComponent(dailyTemplateName)
            if FileManager.default.fileExists(atPath: template.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                let title = (fileName as NSString).deletingPathExtension
                contents = render(try readTemplate(template), title: title, date: date, timeZone: timeZone)
            }
        }
        return .create(url, contents)
    }

    private static func formatted(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
