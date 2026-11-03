import Foundation

/// Привязка вкладки к заметке хранилища для файла сессии: путь на сервере, а не временный путь на Mac.
/// Старые сессии читаются без неё; испорченное поле не ломает восстановление всей сессии.
struct VaultNoteBinding: Codable, Equatable, Sendable {
    let vaultID: String
    let path: String

    init(vaultID: String, path: String) {
        self.vaultID = vaultID
        self.path = path
    }

    init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self),
              let id = try? values.decode(String.self, forKey: .vaultID),
              let path = try? values.decode(String.self, forKey: .path) else {
            vaultID = ""
            path = ""
            return
        }
        vaultID = id
        self.path = path
    }

    /// Подходящий идентификатор подключения и безопасный путь на сервере.
    var isValid: Bool { UUID(uuidString: vaultID) != nil && VaultPath.validated(path) != nil }
}

/// Общее состояние связи для значка и строки состояния.
enum VaultStatus: Equatable {
    case connecting
    case online
    case offline
    /// Есть что-то, требующее внимания: неотправленные заметки или конфликты (число).
    case attention(Int)

    /// Конфликты важнее «нет связи», «нет связи» важнее неотправленного: порядок виден пользователю.
    static func resolve(isConnecting: Bool, isOnline: Bool, unsentCount: Int, conflictCount: Int) -> VaultStatus {
        if conflictCount > 0 { return .attention(conflictCount) }
        if isConnecting { return .connecting }
        if !isOnline { return .offline }
        if unsentCount > 0 { return .attention(unsentCount) }
        return .online
    }

    /// Слово состояния для строки состояния, подписи вкладки и VoiceOver.
    var spokenName: String {
        switch self {
        case .connecting: L10n.tr("连接中")
        case .online: L10n.tr("已同步")
        case .offline: L10n.tr("未连接")
        case .attention(let count): L10n.tr("需要注意：%lld", count)
        }
    }

    /// Символ SF Symbols: цвет и форма не единственные носители смысла, слово всегда рядом.
    var symbolName: String {
        switch self {
        case .connecting, .online: "cloud"
        case .offline: "icloud.slash"
        case .attention: "exclamationmark.icloud"
        }
    }
}

/// Состояние вкладки, у которой текст заметки ещё не пришёл.
enum VaultOpeningState: Equatable {
    case loading
    /// Сервер отвечает дольше трёх секунд.
    case slow
    case waitingForConnection

    /// Через три секунды ожидания `loading` становится `slow`; остальные состояния не меняются.
    func afterDelay() -> VaultOpeningState {
        self == .loading ? .slow : self
    }

    static let slowDelay: TimeInterval = 3
}

/// Заметка дня и пути, которые строятся из даты. Формат сервера: `daily/YYYY-MM-DD.md`, создаёт его сервер.
enum VaultDailyNote {
    static let folder = "daily"

    static func path(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 1970, month = parts.month ?? 1, day = parts.day ?? 1
        return String(format: "\(folder)/%04d-%02d-%02d.md", year, month, day)
    }

    static func yesterday(of date: Date, calendar: Calendar = .current) -> String {
        path(for: calendar.date(byAdding: .day, value: -1, to: date) ?? date, calendar: calendar)
    }

    /// Дата из пути заметки дня; nil — не заметка дня.
    static func date(fromPath path: String) -> String? {
        guard path.hasPrefix(folder + "/"), path.hasSuffix(".md") else { return nil }
        let name = String(path.dropFirst(folder.count + 1).dropLast(3))
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return name
    }
}

/// Чистые помощники списка заметок и заголовка вкладки.
enum VaultPresentation {
    /// Закрепление/открепление: порядок сохраняется, повторов нет.
    static func togglingPin(_ path: String, in pinned: [String]) -> [String] {
        pinned.contains(path) ? pinned.filter { $0 != path } : pinned + [path]
    }

    /// Закреплённые, которых уже нет на сервере, не показываются, но и не удаляются из хранения (сервер мог ответить не полностью).
    static func visiblePinned(_ pinned: [String], hidden: Set<String>) -> [String] {
        pinned.filter { path in
            VaultPath.validated(path) != nil
                && !hidden.contains(path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path)
        }
    }

    /// Подпись снимка в списке: служебное имя снимка «до замены версией сервера» показывается переведённым.
    static func snapshotDisplayName(_ name: String) -> String {
        name == VaultSyncEngine.preservedSnapshotName ? L10n.tr("服务器版本替换前的本地文本") : name
    }

    /// Имя без расширения `.md` для строки списка и заголовка.
    static func displayName(ofPath path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// «Подключение › projects › status»: папки пути, самой заметки здесь нет (её имя поле заголовка добавляет само).
    static func titlePrefix(connectionName: String, path: String?) -> String {
        guard let path else { return connectionName }
        let folders = path.split(separator: "/").dropLast().map(String.init)
        return ([connectionName] + folders).joined(separator: " › ")
    }

    /// Показывать ли во вкладке плашку «Нет связи» вместо пустого списка.
    static func isCatalogEmptyBecauseOffline(rootsCount: Int, isOnline: Bool, isConnecting: Bool) -> Bool {
        rootsCount == 0 && !isOnline && !isConnecting
    }
}

/// Минимальная замена, превращающая один текст в другой: общие начало и конец отбрасываются.
/// Так серверное обновление правит только изменившееся место, а выделение и прокрутка остаются на месте.
enum VaultTextDiff {
    /// nil — тексты равны. Диапазон задан в UTF-16 (как у `NSRange` редактора) и не разрывает суррогатные пары.
    static func enclosingChange(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        guard old != new else { return nil }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        let limit = min(a.count, b.count)
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return (NSRange(location: prefix, length: a.count - prefix - suffix), replacement)
    }
}
