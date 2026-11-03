import Foundation

/// Что показывает блок синхронизации правой панели. Строится из сессии и записи движка; сети и AppKit здесь нет.
struct VaultNoteInfo: Equatable, Sendable {
    /// Источник для «Показать изменения сервера».
    enum Compare: Equatable, Sendable {
        /// Версия сервера, которую движок держит в памяти и ещё не применил.
        case heldServerVersion
        /// Текст до последнего обновления сервером (в памяти сессии).
        case beforeLastServerUpdate(Date)
    }

    var state: VaultNoteSyncState
    var isOnline: Bool
    /// Последняя проверка сервера.
    var lastCheck: Date?
    /// Время изменения на сервере (по записи движка).
    var serverModified: Date?
    var compareSource: Compare?
}

/// Слова и значки состояния заметки; значок и цвет никогда не единственный признак.
enum VaultNoteStateDescription {
    enum Tone: Equatable, Sendable { case neutral, accent, warning, danger }

    static func title(_ state: VaultNoteSyncState) -> String {
        switch state {
        case .synced: L10n.tr("已同步")
        case .modified: L10n.tr("未上传")
        case .uploading: L10n.tr("正在发送…")
        case .newerOnServer: L10n.tr("服务器上有更新")
        case .conflict: L10n.tr("冲突")
        case .deletedOnServer: L10n.tr("已在服务器上删除")
        case .loading: L10n.tr("正在加载")
        }
    }

    /// Для VoiceOver: слово состояния, при отсутствии связи — «…, нет связи».
    static func spoken(_ state: VaultNoteSyncState, isOnline: Bool) -> String {
        isOnline ? title(state) : "\(title(state)), \(L10n.tr("未连接"))"
    }

    static func symbol(_ state: VaultNoteSyncState) -> String {
        switch state {
        case .synced: "checkmark.icloud"
        case .modified, .uploading: "arrow.up.circle"
        case .newerOnServer: "arrow.down.circle"
        case .conflict: "exclamationmark.triangle"
        case .deletedOnServer: "trash"
        case .loading: "ellipsis.circle"
        }
    }

    static func tone(_ state: VaultNoteSyncState) -> Tone {
        switch state {
        case .synced, .loading: .neutral
        case .modified, .uploading: .accent
        case .newerOnServer, .conflict: .warning
        case .deletedOnServer: .danger
        }
    }
}

/// Тексты до серверных обновлений (по одному на заметку) для «Показать изменения сервера». В памяти, на диск не пишется;
/// слишком большой текст не запоминается.
final class VaultServerUpdateMemory {
    struct Entry: Equatable {
        var previousText: String
        var date: Date
    }

    /// Предел размера одного текста в байтах UTF-8.
    static let limit = 2 * 1024 * 1024

    private var entries: [String: Entry] = [:]

    func record(path: String, previousText: String, date: Date = Date()) {
        guard previousText.utf8.count <= Self.limit else {
            entries[path] = nil
            return
        }
        entries[path] = Entry(previousText: previousText, date: date)
    }

    func entry(for path: String) -> Entry? { entries[path] }
    func remove(path: String) { entries[path] = nil }
    func clear() { entries = [:] }
}
