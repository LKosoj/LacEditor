import AppKit
import Combine
import Foundation

/// Результат быстрой проверки папки на наличие проекта.
enum ManuscriptProjectProbe: Equatable {
    /// Нет `.laceditor/project.json`.
    case none
    /// `isReadOnly`: версия манифеста новее поддерживаемой.
    case found(projectID: UUID, title: String, isReadOnly: Bool)
    /// JSON повреждён или путь небезопасен (символическая ссылка).
    case unreadable(reason: String)
}

enum ManuscriptProjectError: LocalizedError, Equatable {
    case readOnly, changedExternally, invalid(String), duplicatePath, outsideRoot, alreadyExists

    var errorDescription: String? {
        switch self {
        case .readOnly: L10n.tr("此项目由较新版本的 LacEditor 创建，仅可查看。")
        case .changedExternally: L10n.tr("项目文件已在外部更改，已重新读取。")
        case let .invalid(message): L10n.tr("项目文件无法保存：%@", message)
        case .duplicatePath: L10n.tr("项目中已有此文件")
        case .outsideRoot: L10n.tr("文件必须位于项目文件夹内")
        case .alreadyExists: L10n.tr("项目文件无法保存：%@", ".laceditor/project.json")
        }
    }
}

/// Манифест проекта рукописи `.laceditor/project.json`: один экземпляр на корень, общий для всех вкладок проекта.
/// Запись атомарная, с проверкой `FileRevisionSnapshot`; повреждённый файл не перезаписывается.
@MainActor
final class ManuscriptProjectStore: ObservableObject {
    enum State: Equatable {
        case loaded
        /// Манифест новее поддерживаемой версии: только просмотр сообщения, дерево недоступно.
        case readOnlyNewerVersion(Int)
        case unreadable(String)
        /// Манифеста нет (не создан или удалён извне).
        case missing
    }

    nonisolated static let supportedVersion = 1
    static let relativeManifestPath = ".laceditor/project.json"

    @Published private(set) var project: ManuscriptProject?
    @Published private(set) var state: State = .missing
    /// Манифест изменён извне и перечитан; интерфейс показывает сообщение и сбрасывает флаг.
    @Published var externalChangeNotice = false

    let rootURL: URL
    private var fallbackID = UUID()
    private var fallbackTitle: String?
    private var lastRevision: FileRevisionSnapshot?
    private var activationCancellable: AnyCancellable?

    var projectID: UUID { project?.projectID ?? fallbackID }
    var title: String { project?.title ?? fallbackTitle ?? rootURL.lastPathComponent }

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        reload()
        activationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.checkForExternalChange() }
            }
    }

    // MARK: Чтение

    nonisolated static func manifestURL(root: URL) -> URL {
        root.standardizedFileURL.appendingPathComponent(".laceditor", isDirectory: true)
            .appendingPathComponent("project.json", isDirectory: false)
    }

    private enum ManifestData {
        case none
        case unsafe
        case data(Data)
        case failure(String)
    }

    nonisolated private static func readManifestData(root: URL) -> ManifestData {
        let url = manifestURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard (try? FolderSearchService.pathIsSafe(url, root: root, isCancelled: { false })) == true else { return .unsafe }
        do { return .data(try Data(contentsOf: url)) }
        catch { return .failure(error.localizedDescription) }
    }

    private struct Header: Decodable {
        let version: Int
        let projectID: UUID
        let title: String?
    }

    nonisolated static func probe(root: URL) -> ManuscriptProjectProbe {
        switch readManifestData(root: root) {
        case .none: return .none
        case .unsafe: return .unreadable(reason: ".laceditor")
        case let .failure(reason): return .unreadable(reason: reason)
        case let .data(data):
            guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
                return .unreadable(reason: "JSON")
            }
            return .found(projectID: header.projectID,
                          title: header.title ?? root.lastPathComponent,
                          isReadOnly: header.version > supportedVersion)
        }
    }

    /// Принудительно перечитывает манифест. Флаг `externalChangeNotice` не трогает.
    func reload() {
        switch Self.readManifestData(root: rootURL) {
        case .none:
            project = nil
            state = .missing
            lastRevision = nil
        case .unsafe:
            project = nil
            state = .unreadable(".laceditor")
            lastRevision = nil
        case let .failure(reason):
            project = nil
            state = .unreadable(reason)
            lastRevision = nil
        case let .data(data):
            lastRevision = try? FileRevisionSnapshot.capture(Self.manifestURL(root: rootURL))
            guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
                project = nil
                state = .unreadable("JSON")
                return
            }
            fallbackID = header.projectID
            fallbackTitle = header.title
            if header.version > Self.supportedVersion {
                project = nil
                state = .readOnlyNewerVersion(header.version)
                return
            }
            do {
                project = try JSONDecoder().decode(ManuscriptProject.self, from: data)
                state = .loaded
            } catch {
                project = nil
                state = .unreadable(error.localizedDescription)
            }
        }
    }

    /// Сравнивает манифест на диске с прочитанным; при отличии перечитывает и ставит `externalChangeNotice`.
    @discardableResult
    func checkForExternalChange() -> Bool {
        let current = try? FileRevisionSnapshot.capture(Self.manifestURL(root: rootURL))
        guard current != lastRevision else { return false }
        reload()
        externalChangeNotice = true
        return true
    }

    // MARK: Узлы

    func node(id: UUID) -> ManuscriptNode? { project?.node(id: id) }

    func node(forFileURL url: URL) -> ManuscriptNode? {
        guard let project else { return nil }
        if let relative = FolderSearchService.relativePath(url, root: rootURL), let node = project.node(forRelativePath: relative) {
            return node
        }
        // Корень и документ могут называться через разные символические ссылки (/var и /private/var).
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        guard let relative = FolderSearchService.relativePath(url.resolvingSymlinksInPath(), root: resolvedRoot) else { return nil }
        return project.node(forRelativePath: relative)
    }

    /// nil: группа или небезопасный путь. Наличие файла не проверяется.
    func fileURL(for node: ManuscriptNode) -> URL? {
        guard node.kind == .text, let path = node.path, ManuscriptProjectValidation.isSafeRelativePath(path) else { return nil }
        return path.split(separator: "/").reduce(rootURL) { $0.appendingPathComponent(String($1)) }
    }

    /// Текстовые узлы в порядке книги (обход в глубину). Выключенная группа скрывает всю ветку.
    func orderedTextNodes(includedOnly: Bool) -> [ManuscriptNode] {
        var result: [ManuscriptNode] = []
        func walk(_ list: [ManuscriptNode]) {
            for node in list {
                if includedOnly, !node.include { continue }
                if node.kind == .text { result.append(node) } else { walk(node.children) }
            }
        }
        walk(project?.nodes ?? [])
        return result
    }

    // MARK: Запись

    /// Применяет правку к копии модели, проверяет её и пишет манифест атомарно.
    /// Модель в памяти меняется только после успешной записи.
    func update(_ change: (inout ManuscriptProject) -> Void) throws {
        guard state == .loaded, let current = project else { throw ManuscriptProjectError.readOnly }
        try verifyUnchangedOnDisk()
        var working = current
        change(&working)
        working.projectID = current.projectID
        working.version = current.version
        let issues = ManuscriptProjectValidation.validate(working)
        if let error = issues.first(where: { $0.severity == .error }) {
            if error.message.hasPrefix("duplicate path") { throw ManuscriptProjectError.duplicatePath }
            throw ManuscriptProjectError.invalid(error.message)
        }
        // Символические ссылки проверяются только у новых путей: старый узел не должен блокировать все правки.
        let known = Set(current.allNodes().compactMap(\.path))
        for node in working.allNodes() {
            guard let path = node.path, !known.contains(path), let url = fileURL(for: node),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            if (try? FolderSearchService.pathIsSafe(url, root: rootURL, isCancelled: { false })) != true {
                throw ManuscriptProjectError.invalid(path)
            }
        }
        try write(working)
        project = working
    }

    private func verifyUnchangedOnDisk() throws {
        let current = try? FileRevisionSnapshot.capture(Self.manifestURL(root: rootURL))
        guard current == lastRevision else {
            reload()
            externalChangeNotice = true
            throw ManuscriptProjectError.changedExternally
        }
    }

    private func write(_ project: ManuscriptProject) throws {
        let url = Self.manifestURL(root: rootURL)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? FolderSearchService.pathIsSafe(url.deletingLastPathComponent(), root: rootURL, isCancelled: { false })) == true else {
            throw ManuscriptProjectError.invalid(".laceditor")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(project)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        lastRevision = try? FileRevisionSnapshot.capture(url)
    }

    /// Переносит узел (с поддеревом) к другому родителю или в корень; `id` не меняется.
    func moveNode(id: UUID, toParent parent: UUID?, index: Int) throws {
        guard let current = project, let moving = current.node(id: id) else { throw ManuscriptProjectError.invalid("node") }
        if let parent {
            guard let target = current.node(id: parent), target.kind == .group else { throw ManuscriptProjectError.invalid("parent") }
            let subtree = ManuscriptProject(title: "", nodes: [moving]).allNodes().map(\.id)
            if subtree.contains(parent) { throw ManuscriptProjectError.invalid("cycle") }
        }
        try update { project in
            guard let removed = project.removeNode(id: id) else { return }
            project.insertNode(removed.node, parent: parent, index: index)
        }
    }

    func setInclude(_ include: Bool, nodeID: UUID) throws {
        try update { $0.mutateNode(id: nodeID) { $0.include = include } }
    }

    struct RemovedNode: Equatable {
        let node: ManuscriptNode
        let parent: UUID?
        let index: Int
    }

    /// Убирает узел из проекта; файлы остаются. Результат нужен для отмены.
    func removeNode(id: UUID) throws -> RemovedNode {
        var removed: RemovedNode?
        try update { project in
            if let result = project.removeNode(id: id) { removed = RemovedNode(node: result.node, parent: result.parent, index: result.index) }
        }
        guard let removed else { throw ManuscriptProjectError.invalid("node") }
        return removed
    }

    func insertNode(_ node: ManuscriptNode, parent: UUID?, index: Int) throws {
        var inserted = true
        try update { inserted = $0.insertNode(node, parent: parent, index: index) }
        if !inserted { throw ManuscriptProjectError.invalid("parent") }
    }

    /// Другое место файла для узла (кнопка «Указать файл…»). Путь не должен принадлежать другому узлу.
    func relocateNode(id: UUID, toRelativePath path: String) throws {
        guard ManuscriptProjectValidation.isSafeRelativePath(path) else { throw ManuscriptProjectError.outsideRoot }
        if let other = project?.node(forRelativePath: path), other.id != id { throw ManuscriptProjectError.duplicatePath }
        try update { $0.mutateNode(id: id) { $0.path = path } }
    }

    /// Обновляет `path` после переименования или переноса файла (или папки) через приложение.
    /// Если новое место вне корня, узел остаётся со старым путём и показывается как отсутствующий.
    @discardableResult
    func renameFile(oldURL: URL, newURL: URL) -> Bool {
        guard state == .loaded, let current = project,
              let old = FolderSearchService.relativePath(oldURL, root: rootURL),
              let new = FolderSearchService.relativePath(newURL, root: rootURL),
              ManuscriptProjectValidation.isSafeRelativePath(new) else { return false }
        let affected = current.allNodes().filter { node in
            guard let path = node.path else { return false }
            return path == old || path.hasPrefix(old + "/")
        }
        guard !affected.isEmpty else { return false }
        do {
            try update { project in
                for node in affected {
                    guard let path = node.path else { continue }
                    project.mutateNode(id: node.id) { $0.path = new + String(path.dropFirst(old.count)) }
                }
            }
            return true
        } catch { return false }
    }

    // MARK: Создание

    /// Создаёт манифест. Файлы не читаются и не меняются; `files` — относительные пути в нужном порядке.
    func createProject(title: String, language: String?, files: [String]) throws {
        let url = Self.manifestURL(root: rootURL)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ManuscriptProjectError.alreadyExists }
        let nodes = files.filter { ManuscriptProjectValidation.isSafeRelativePath($0) }.map { path in
            ManuscriptNode(kind: .text,
                           title: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                           path: path)
        }
        let created = ManuscriptProject(title: title, language: language, nodes: nodes)
        if let error = ManuscriptProjectValidation.validate(created).first(where: { $0.severity == .error }) {
            throw ManuscriptProjectError.invalid(error.message)
        }
        try write(created)
        project = created
        fallbackID = created.projectID
        fallbackTitle = created.title
        state = .loaded
    }

    /// Повреждённый манифест переносится в `project.json.corrupt` (затем `-2`, `-3`…), после чего создаётся новый.
    func recreateAfterCorruption(title: String, language: String?, files: [String]) throws {
        guard case .unreadable = state,
              (try? FolderSearchService.pathIsSafe(Self.manifestURL(root: rootURL), root: rootURL, isCancelled: { false })) == true else {
            throw ManuscriptProjectError.invalid("state")
        }
        try moveCorruptFileAside()
        try createProject(title: title, language: language, files: files)
    }

    private func moveCorruptFileAside() throws {
        let url = Self.manifestURL(root: rootURL)
        let directory = url.deletingLastPathComponent()
        let base = url.lastPathComponent + ".corrupt"
        var name = base
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base)-\(number)"
            number += 1
        }
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(name))
    }
}
