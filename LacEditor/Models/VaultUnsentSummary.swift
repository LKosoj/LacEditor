import Foundation

/// Строка раздела «Неотправленное» или «Конфликты».
struct VaultUnsentRow: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case waiting, sending, offline
        case rejected(VaultUploadIssue)
        case conflict, deletedOnServer
    }

    var id: String { serverPath }
    var serverPath: String
    /// Название без `.md`.
    var title: String
    /// Путь папки (пусто — корень).
    var folder: String
    var kind: Kind
    var isOpenInTab: Bool
    var canSendNow: Bool
    var canDiscard: Bool
    var canShowConflict: Bool
    /// Когда заметка встала в очередь отправки.
    var queuedAt: Date?

    /// Требует ли строка внимания: отказ, удаление на сервере, нет связи или ждёт отправки дольше `attentionDelay`.
    /// Только что сохранённая заметка внимания не просит: она уходит сама через секунду-другую.
    func needsAttention(now: Date) -> Bool {
        switch kind {
        case .rejected, .deletedOnServer, .offline, .conflict: return true
        case .waiting, .sending:
            guard let queuedAt else { return true }
            return now.timeIntervalSince(queuedAt) >= VaultUnsentSummary.attentionDelay
        }
    }

    /// Вторая строка состояния словами: цвет не единственный признак.
    var statusText: String {
        switch kind {
        case .waiting: L10n.tr("等待上传")
        case .sending: L10n.tr("正在发送…")
        case .offline: L10n.tr("等待连接")
        case .rejected(let issue): issue.userMessage
        case .conflict: L10n.tr("冲突")
        case .deletedOnServer: L10n.tr("已在服务器上删除")
        }
    }
}

/// Вопрос при выходе из приложения: что не отправлено и что можно предложить.
struct VaultQuitPrompt: Equatable, Sendable {
    var count: Int
    /// Не больше `VaultUnsentSummary.maxListed` строк.
    var listed: [VaultUnsentRow]
    var moreCount: Int
    var hasConflicts: Bool
    var conflictCount: Int
    /// Заметки, которые отправить нельзя без решения человека: сервер не принял или удалил их.
    var blockedCount: Int
    var isOffline: Bool
    /// false — нечего отправлять (только конфликты) или нет связи.
    var offersSend: Bool

    var listedTitles: [String] { listed.map(\.title) }
}

/// Единый источник текстов для боковой панели, вопроса при выходе и строки состояния.
struct VaultUnsentSummary: Equatable, Sendable {
    static let maxListed = 8
    /// Сколько секунд заметка может ждать отправки, не привлекая внимания.
    static let attentionDelay: TimeInterval = 8
    static let empty = VaultUnsentSummary(records: [:], isOnline: true)

    /// Изменённые, отправляющиеся и удалённые на сервере без вкладки; по порядку первого сохранения.
    let unsent: [VaultUnsentRow]
    let conflicts: [VaultUnsentRow]
    let isOnline: Bool

    var unsentCount: Int { unsent.count }
    var conflictCount: Int { conflicts.count }

    /// Есть ли заметки, которые отправка может унести: без отказа сервера и без удаления на сервере.
    var hasSendable: Bool {
        unsent.contains { row in
            switch row.kind { case .waiting, .sending, .offline: return true; default: return false }
        }
    }

    /// Строки «Неотправленного», которые просят внимания (для значка и раздела боковой панели).
    func attentionUnsent(now: Date = Date()) -> [VaultUnsentRow] { unsent.filter { $0.needsAttention(now: now) } }

    /// Через сколько секунд одна из ждущих строк начнёт просить внимания; nil — ждать нечего.
    func nextAttentionDelay(now: Date = Date()) -> TimeInterval? {
        unsent.compactMap { row -> TimeInterval? in
            guard !row.needsAttention(now: now), let queuedAt = row.queuedAt else { return nil }
            return Self.attentionDelay - now.timeIntervalSince(queuedAt)
        }.min()
    }

    init(records: [String: VaultOpenNoteRecord], isOnline: Bool) {
        self.isOnline = isOnline
        let ordered = records.values.sorted { lhs, rhs in
            switch (lhs.queuedAt, rhs.queuedAt) {
            case let (a?, b?) where a != b: return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.serverPath < rhs.serverPath
            }
        }
        var unsent: [VaultUnsentRow] = []
        var conflicts: [VaultUnsentRow] = []
        for record in ordered {
            let title = VaultPresentation.displayName(ofPath: record.serverPath)
            let folder = record.serverPath.split(separator: "/").dropLast().joined(separator: "/")
            func row(_ kind: VaultUnsentRow.Kind, send: Bool, discard: Bool, conflict: Bool) -> VaultUnsentRow {
                VaultUnsentRow(serverPath: record.serverPath, title: title, folder: folder, kind: kind,
                               isOpenInTab: record.isOpenInTab, canSendNow: send, canDiscard: discard, canShowConflict: conflict, queuedAt: record.queuedAt)
            }
            switch record.state {
            case .modified, .uploading:
                if let issue = record.uploadIssue {
                    unsent.append(row(.rejected(issue), send: issue.isRetryable, discard: true, conflict: false))
                } else if record.state == .uploading {
                    unsent.append(row(.sending, send: false, discard: false, conflict: false))
                } else {
                    unsent.append(row(isOnline ? .waiting : .offline, send: true, discard: true, conflict: false))
                }
            case .deletedOnServer where !record.isOpenInTab:
                unsent.append(row(.deletedOnServer, send: false, discard: true, conflict: false))
            case .conflict:
                conflicts.append(row(.conflict, send: false, discard: true, conflict: true))
            default:
                break
            }
        }
        self.unsent = unsent
        self.conflicts = conflicts
    }

    /// nil — спрашивать нечего.
    func quitPrompt() -> VaultQuitPrompt? {
        let all = unsent + conflicts
        guard !all.isEmpty else { return nil }
        let listed = Array(all.prefix(Self.maxListed))
        // Отправить можно только заметки без отказа сервера (или уже отправляющиеся): остальные ждут решения человека.
        let canSend = hasSendable
        let blocked = unsent.filter { row in
            switch row.kind { case .rejected, .deletedOnServer: return true; default: return false }
        }.count
        return VaultQuitPrompt(count: all.count, listed: listed, moreCount: all.count - listed.count,
                               hasConflicts: !conflicts.isEmpty, conflictCount: conflicts.count, blockedCount: blocked,
                               isOffline: !isOnline, offersSend: canSend && isOnline)
    }
}
