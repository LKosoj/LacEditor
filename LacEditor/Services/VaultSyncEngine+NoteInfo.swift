import Foundation

/// Только чтение для правой панели: что движок держит в памяти про открытую заметку.
extension VaultSyncEngine {
    /// Версия сервера, которую движок получил, но ещё не применил (сервер новее, конфликт). Не UTF-8 — nil.
    func heldServerText(serverPath: String) -> String? {
        guard let held = heldServerVersions[serverPath] else { return nil }
        return String(data: held.data, encoding: .utf8)
    }

    func noteSummary(serverPath: String) -> (record: VaultOpenNoteRecord?, hasHeld: Bool) {
        (records()[serverPath], heldServerVersions[serverPath] != nil)
    }
}
