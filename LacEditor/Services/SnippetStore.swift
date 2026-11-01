import Combine
import Foundation

struct Snippet: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var text: String

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// Список сниппетов в `Application Support/<AppEnvironment.dataDirectoryName>/Snippets.json`.
/// Повреждённый файл переносится рядом как `.corrupt` и не затирается; файл новее известной версии не трогается.
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    enum Issue: Equatable {
        /// Файл перенесён под этим именем, список пуст, запись разрешена.
        case corrupt(backupName: String)
        /// Файл не читается, новее известной версии или не удалось его перенести: запись запрещена.
        case unavailable
    }

    enum StoreError: LocalizedError, Equatable {
        case emptyName, emptyText, readOnly, notFound

        var errorDescription: String? {
            switch self {
            case .emptyName, .emptyText: L10n.tr("名称和内容不能为空")
            case .readOnly: L10n.tr("无法使用文本片段文件，修改将不会保存。")
            case .notFound: L10n.tr("无法保存文本片段")
            }
        }
    }

    private struct FileContents: Codable {
        var version: Int
        var snippets: [Snippet]
    }

    private static let currentVersion = 1

    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var issue: Issue?
    private let storageURL: URL

    var isReadOnly: Bool { issue == .unavailable }

    var issueMessage: String? {
        switch issue {
        case .corrupt(let backupName): L10n.tr("文本片段文件已损坏，已另存为 %@，当前列表为空。", backupName)
        case .unavailable: L10n.tr("无法使用文本片段文件，修改将不会保存。")
        case nil: nil
        }
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        load()
    }

    @discardableResult
    func add(name: String, text: String) throws -> Snippet {
        let snippet = Snippet(name: try validatedName(name, text: text), text: text)
        try persist(snippets + [snippet])
        return snippet
    }

    func update(_ snippet: Snippet) throws {
        let name = try validatedName(snippet.name, text: snippet.text)
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { throw StoreError.notFound }
        var updated = snippets
        updated[index] = Snippet(id: snippet.id, name: name, text: snippet.text)
        try persist(updated)
    }

    func remove(id: UUID) throws {
        guard !isReadOnly else { throw StoreError.readOnly }
        guard snippets.contains(where: { $0.id == id }) else { throw StoreError.notFound }
        try persist(snippets.filter { $0.id != id })
    }

    static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(AppEnvironment.dataDirectoryName, isDirectory: true)
            .appendingPathComponent("Snippets.json")
    }

    private func validatedName(_ name: String, text: String) throws -> String {
        guard !isReadOnly else { throw StoreError.readOnly }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        guard !text.isEmpty else { throw StoreError.emptyText }
        return trimmed
    }

    /// Память меняется только после успешной записи файла.
    private func persist(_ newSnippets: [Snippet]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(FileContents(version: Self.currentVersion, snippets: newSnippets))
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
        snippets = newSnippets
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        } catch {
            issue = .unavailable
            return
        }
        guard let contents = try? JSONDecoder().decode(FileContents.self, from: data) else {
            moveCorruptFileAside()
            return
        }
        guard contents.version <= Self.currentVersion else {
            issue = .unavailable
            return
        }
        snippets = contents.snippets
    }

    /// Свободное имя копии: `.corrupt`, затем `.corrupt-2`, `-3`…; прежние копии не затираются.
    private func moveCorruptFileAside() {
        let directory = storageURL.deletingLastPathComponent()
        let base = storageURL.lastPathComponent + ".corrupt"
        var name = base
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base)-\(number)"
            number += 1
        }
        do {
            try FileManager.default.moveItem(at: storageURL, to: directory.appendingPathComponent(name))
            issue = .corrupt(backupName: name)
        } catch {
            issue = .unavailable
        }
    }
}
