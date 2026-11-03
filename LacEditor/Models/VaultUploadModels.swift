import Foundation

/// Почему сервер (или проверка перед отправкой) не принимает правки заметки. Без повтора, пока текст не изменится.
enum VaultUploadIssue: String, Codable, Equatable, Sendable {
    /// 413 или файл больше 16 МиБ: на сервер не отправляется вообще.
    case tooLarge
    /// 403.
    case forbidden
    /// 422 (кроме `not_utf8`) или правка вне разрешённого места страницы.
    case ownerNotesOnly
    /// 422 с причиной `not_utf8`.
    case notUTF8
    /// 401: токен не принят, отправка остановлена целиком.
    case unauthorized
    /// 400/428/прочее, не лечащееся повтором (после трёх попыток).
    case rejected

    /// Причина словами для плашки и строки «Неотправленного».
    var userMessage: String {
        switch self {
        case .tooLarge: VaultClientError.tooLarge.userMessage
        case .forbidden: VaultClientError.forbidden.userMessage
        case .ownerNotesOnly: VaultClientError.ownerNotesOnly(reason: nil).userMessage
        case .notUTF8: L10n.tr("服务器只接受 UTF-8 文本")
        case .unauthorized: VaultClientError.unauthorized.userMessage
        case .rejected: VaultClientError.preconditionRequired.userMessage
        }
    }

    /// Повтор той же отправки бессмыслен: кнопка «Повторить» не показывается.
    var isRetryable: Bool {
        switch self {
        case .tooLarge, .notUTF8: false
        default: true
        }
    }
}

/// Итог одной попытки отправить заметку (для «Отправить сейчас» и закрытия вкладки).
enum VaultUploadOutcome: Equatable, Sendable {
    case sent, alreadySynced, conflict, offline, retryLater, deletedOnServer
    /// Заметки нет в очереди (нет записи).
    case notQueued
    /// Ожидание кончилось, запрос идёт дальше сам.
    case timedOut
    /// Файл изменился, пока шла отправка или решался конфликт.
    case fileChanged
    case issue(VaultUploadIssue)
}

/// Ответ хозяина вкладки на просьбу записать объединённый текст.
enum VaultApplyResult: Sendable {
    /// Файл уже записан, редактор показывает тот же текст.
    case applied
    /// Вкладка не выбрана и чиста, либо её нет: файл может записать движок.
    case engineMayWrite
    /// В документе есть несохранённый ввод или он занят: ничего не менять, повторить позже.
    case busy
}

enum VaultDiscardResult: Equatable, Sendable {
    /// Закрытая заметка удалена с диска совсем.
    case removed
    /// Открытая вкладка: заменить текст версией основы (файл движок не трогает).
    case revertTo(String)
    case busy
    case notFound
}

struct VaultUploadSummary: Equatable, Sendable {
    var sent: Int
    var remaining: [String]
    var conflicts: [String]
    var issues: [String: VaultUploadIssue]
    var isOffline: Bool
}

/// Всё, что нужно листу конфликта.
struct VaultConflictContext: Equatable, Sendable {
    var serverPath: String
    var base: String
    var mine: String
    var server: String
    var serverETag: String
    var conflict: VaultMergeConflict
}

enum VaultConflictLoad: Equatable, Sendable {
    case conflict(VaultConflictContext)
    case noLongerConflicting
}

/// Одноразовое ожидание результата: можно завершить раньше, чем начали ждать, и дважды (второй вызов игнорируется).
final class VaultWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var result: Value?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ value: Value) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
