import Foundation

struct FileVersionInfo: Identifiable, Sendable, Equatable {
    let id: String
    let date: Date?
    let computerName: String?
    /// Путь содержимого версии в системном хранилище; читать сразу, не хранить.
    let contentURL: URL
}

enum FileVersionService {
    /// Записывает текущее содержимое файла как версию. Вызывать после успешной записи
    /// и после снимка `FileRevisionSnapshot`; сам файл не меняется.
    nonisolated static func recordVersion(of url: URL) -> Error? {
        do {
            _ = try NSFileVersion.addOfItem(at: url, withContentsOf: url, options: [])
            return nil
        } catch {
            return error
        }
    }

    nonisolated static func versions(of url: URL) -> [FileVersionInfo] {
        let found = NSFileVersion.otherVersionsOfItem(at: url) ?? []
        return found
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
            .map { version in
                FileVersionInfo(
                    id: String(describing: version.persistentIdentifier),
                    date: version.modificationDate,
                    computerName: version.localizedNameOfSavingComputer,
                    contentURL: version.url
                )
            }
    }

    nonisolated static func loadText(
        _ info: FileVersionInfo,
        encoding: String.Encoding,
        encodingName: String
    ) throws -> String {
        let data = try Data(contentsOf: info.contentURL)
        return try FileService.decode(data, encoding: encoding, encodingName: encodingName).text
    }

    /// Читает файл кодировкой документа; отметка файла до и после чтения должна совпасть.
    nonisolated static func loadDiskText(
        at url: URL,
        encoding: String.Encoding,
        encodingName: String
    ) throws -> String {
        let before = try FileRevisionSnapshot.capture(url)
        let data = try Data(contentsOf: url)
        guard try FileRevisionSnapshot.capture(url) == before else { throw CocoaError(.fileReadUnknown) }
        return try FileService.decode(data, encoding: encoding, encodingName: encodingName).text
    }
}
