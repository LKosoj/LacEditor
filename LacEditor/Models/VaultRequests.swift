import Foundation

/// Локальная метка запроса: сервер её не получает (тип он определяет сам).
enum VaultRequestKind: String, Codable { case capture, ask }

/// Запрос, записанный на диск до отправки (`Vaults/<vaultID>/requests.json`).
struct VaultPendingRequest: Codable, Equatable, Identifiable {
    var requestID: String
    /// Не меняется после создания: повтор с тем же `request_id` и другим текстом сервер отклонит.
    var text: String
    var kind: VaultRequestKind
    /// Появляется после ответа сервера на отправку.
    var jobID: String?
    var createdAt: Date

    var id: String { requestID }
}

enum VaultRequestError: Error, Equatable { case empty, tooLong, storageUnavailable }

enum VaultRequestText {
    /// Лимит сервера: 100 000 знаков после обрезки пробелов.
    static let maxScalars = 100_000
    /// Тело запроса у сервера не больше 256 КиБ; запас на JSON.
    static let maxUTF8Bytes = 240_000

    /// Обрезает пробелы по краям; бросает `.empty` / `.tooLong`.
    static func validated(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultRequestError.empty }
        guard trimmed.unicodeScalars.count <= maxScalars, trimmed.utf8.count <= maxUTF8Bytes else {
            throw VaultRequestError.tooLong
        }
        return trimmed
    }
}

struct VaultRequestResult: Equatable {
    var report: String
    var artifacts: [VaultJobArtifact]
}

enum VaultRequestFailure: Equatable {
    /// Сервер прервал задачу: автоповтора нет (повтор мог бы продублировать запись).
    case interrupted
    /// Сервер потерял задачу (404): повторной отправки нет.
    case jobLost
    case serverError(String?, canRetry: Bool)
    /// Окончательный отказ (400/409/413…): запись удалена, текст возвращается пользователю.
    case rejected(VaultClientError)
    /// 401/403/адрес: запись сохранена, повтор остановлен до исправления подключения.
    case needsConnectionFix(VaultClientError)

    var userMessage: String {
        switch self {
        case .interrupted:
            L10n.tr("服务器中断了任务；记录可能已保存，请检查每日笔记")
        case .jobLost:
            L10n.tr("服务器找不到该任务；记录可能已保存，请检查每日笔记")
        case .serverError(let message, _):
            if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                L10n.tr("服务器未能完成任务：%@", message)
            } else {
                L10n.tr("服务器未能完成任务")
            }
        case .rejected:
            L10n.tr("服务器不接受这条内容")
        case .needsConnectionFix(let error):
            switch error {
            case .unauthorized, .forbidden, .insecureAddress, .secureConnectionFailed:
                error.userMessage + "\n" + L10n.tr("请先在“连接笔记库…”中检查连接")
            case .server(let status, _):
                L10n.tr("服务器返回错误（%d），记录已保存", status)
            default:
                error.userMessage + "\n" + L10n.tr("记录已保存")
            }
        }
    }

    /// Можно ли предложить «Повторить» (новый запрос с тем же текстом).
    var canRetry: Bool {
        switch self {
        case .serverError(_, let canRetry): canRetry
        case .rejected, .interrupted, .jobLost, .needsConnectionFix: false
        }
    }
}

enum VaultRequestPhase: Equatable {
    /// Первая отправка идёт.
    case submitting
    /// Отправка или опрос не удались, ждём связь.
    case waitingForConnection
    case queued, running
    case completed(VaultRequestResult)
    case failed(VaultRequestFailure)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: true
        default: false
        }
    }

    /// Итог, после которого запрос больше не изменится; остановка до исправления подключения возобновляется.
    var isFinal: Bool {
        if case .failed(.needsConnectionFix) = self { return false }
        return isTerminal
    }
}

struct VaultRequestUpdate: Equatable {
    var request: VaultPendingRequest
    var phase: VaultRequestPhase
}

enum VaultReply {
    /// Ответ «умного входа» на запись мысли: текст начинается с «✓» (после обрезки пробелов).
    static func isCaptureAcknowledgement(_ report: String) -> Bool {
        report.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\u{2713}")
    }
}

/// Пути заметок в тексте ответа сервера. Ответ — данные: ссылки ведут только на заметки хранилища.
enum VaultAskLinks {
    struct Match: Equatable {
        var range: Range<String.Index>
        var path: String
    }

    static let scheme = "laceditor-vault"

    // Вики-цель `[[dir/name]]`, `[[dir/name.md|псевдоним]]`, `[[dir/name#раздел]]`.
    private static let wikiPattern = try! NSRegularExpression(pattern: #"\[\[([^\[\]|#\n]+)(?:[|#][^\]\n]*)?\]\]"#)
    // Путь без пробелов; начало — после разделителя, конец — `.md` и не продолжение слова.
    private static let plainPattern = try! NSRegularExpression(
        pattern: #"(?<=^|[\s`\[(<"'«“*|])[^\s`\[\]()<>"'«»“”|*,;:]+\.md(?![\p{L}\p{N}_/\-])"#)

    /// Находит `dir/name.md` (минимум один «/»), то же в обратных кавычках и цели `[[dir/name]]`.
    /// Путь проходит `VaultPath.validated`; хвостовая пунктуация в путь не входит.
    static func matches(in text: String, isKnownPath: (String) -> Bool = { _ in true }) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        var result: [Match] = []
        var taken: [NSRange] = []
        for found in wikiPattern.matches(in: text, range: whole) {
            let targetRange = found.range(at: 1)
            guard let range = Range(targetRange, in: text) else { continue }
            let target = text[range].trimmingCharacters(in: .whitespaces)
            guard target.contains("/") else { continue }
            let path = target.hasSuffix(".md") ? target : target + ".md"
            taken.append(found.range)
            guard VaultPath.validated(path) != nil, isKnownPath(path) else { continue }
            result.append(Match(range: range, path: path))
        }
        for found in plainPattern.matches(in: text, range: whole) {
            guard !taken.contains(where: { NSIntersectionRange($0, found.range).length > 0 }),
                  let range = Range(found.range, in: text) else { continue }
            let path = String(text[range])
            guard path.contains("/"), VaultPath.validated(path) != nil, isKnownPath(path) else { continue }
            result.append(Match(range: range, path: path))
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Для вида: Markdown → `AttributedString` (при ошибке разбора — простой текст). Пути ищутся в уже разобранном тексте,
    /// чтобы разметка не искажала их, и получают ссылку `laceditor-vault://note?path=<путь>`.
    static func attributed(_ report: String, isKnownPath: (String) -> Bool = { _ in true }) -> AttributedString {
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: report, options: options)) ?? AttributedString(report)
        #else
        // Разбор Markdown в AttributedString есть только в Foundation на macOS; на Linux (стенд) — простой текст.
        var result = AttributedString(report)
        #endif
        let plain = String(result.characters)
        for match in matches(in: plain, isKnownPath: isKnownPath) {
            guard let url = link(forPath: match.path) else { continue }
            let start = plain.distance(from: plain.startIndex, to: match.range.lowerBound)
            let length = plain.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let lower = result.index(result.startIndex, offsetByCharacters: start)
            let upper = result.index(lower, offsetByCharacters: length)
            result[lower..<upper].link = url
        }
        return result
    }

    static func link(forPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "note"
        components.percentEncodedQuery = "path=" + VaultClient.encode(path)
        return components.url
    }

    /// Обратный разбор; другие схемы и небезопасные пути → nil.
    static func path(fromLink url: URL) -> String? {
        guard url.scheme == scheme, url.host == "note",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              VaultPath.validated(path) != nil else { return nil }
        return path
    }
}

/// Какие итоговые файлы задачи можно открыть как текст (иначе только «Сохранить как…»).
enum VaultArtifactText {
    static let maxBytes = 5 * 1024 * 1024
    static let textExtensions: Set<String> = ["md", "markdown", "txt", "csv", "json", "html", "xml"]

    static func isOpenableAsText(name: String, mimeType: String?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        guard let mime = mimeType?.lowercased() else { return false }
        return mime.hasPrefix("text/") || mime == "application/json"
    }

    /// Текст файла или nil: не подходит по типу, больше 5 МиБ или не UTF-8.
    static func decode(_ data: Data, name: String, mimeType: String?) -> String? {
        guard isOpenableAsText(name: name, mimeType: mimeType), data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
