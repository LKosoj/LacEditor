import Foundation

/// Черновик «Записать мысль» в файле: мысль не теряется при Esc, закрытии окна, выходе и сбое.
struct VaultCaptureDraftStore {
    let fileURL: URL

    init(fileURL: URL = VaultCaptureDraftStore.defaultURL()) { self.fileURL = fileURL }

    /// `Application Support/<dataDirectoryName>/VaultCaptureDraft.txt` (вне `Vaults/<id>/`: уборка подключений его не заденет).
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("VaultCaptureDraft.txt")
    }

    func load() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Пустой или пробельный текст удаляет файл; запись атомарная, права 0600.
    func save(_ text: String) throws {
        let manager = FileManager.default
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clear()
            return
        }
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Возвращённый текст: в пустой черновик — как есть, иначе после пустой строки (если его там ещё нет).
    static func merged(_ current: String, returning returned: String) -> String {
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return returned }
        return current.contains(returned) ? current : current + "\n\n" + returned
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
