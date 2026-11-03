import Foundation

/// Тексты сцен проекта для доски и сводного просмотра: открытые документы приоритетнее диска (как в сборке рукописи).
@MainActor
enum WriterNodeTextLoader {
    struct Part {
        let node: ManuscriptNode
        let url: URL
        let text: String
        let isOpen: Bool
    }

    struct Output {
        var parts: [Part] = []
        /// Относительные пути файлов, которые не удалось прочитать.
        var problems: [String] = []
        /// Снимки открытых документов сейчас недоступны (документ меняется): тексты не загружались.
        var snapshotsUnavailable = false
    }

    /// Читает на фоне; отмена задачи вызывающего отменяет и чтение. Узлы без пути и группы пропускаются.
    static func load(nodes: [ManuscriptNode], store: ManuscriptProjectStore, windowManager: WindowManager?) async -> Output {
        var output = Output()
        var files: [FolderSearchService.File] = []
        var byPath: [String: (node: ManuscriptNode, url: URL)] = [:]
        for node in nodes where node.kind == .text {
            guard let path = node.path else { continue }
            guard let url = store.fileURL(for: node) else { output.problems.append(path); continue }
            files.append(FolderSearchService.File(url: url, relativePath: path))
            byPath[path] = (node, url)
        }
        guard !files.isEmpty else { return output }
        let root = store.rootURL
        var documents: [FolderSearchService.OpenDocument] = []
        if let windowManager {
            guard let snapshots = windowManager.folderSearchSnapshots(root: root) else {
                output.snapshotsUnavailable = true
                return output
            }
            documents = snapshots
        }
        let selected = files
        let documentsSnapshot = documents
        let worker = Task.detached(priority: .userInitiated) { () -> FolderSearchService.Result<FolderSearchService.ManuscriptSource>? in
            try? FolderSearchService.manuscriptSources(root: root, files: selected, openDocuments: documentsSnapshot,
                                                       markdownOnly: false, isCancelled: { Task.isCancelled })
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard let result else {
            output.problems.append(contentsOf: files.map(\.relativePath))
            return output
        }
        var found = Set<String>()
        for source in result.values {
            guard let entry = byPath[source.file.relativePath] else { continue }
            found.insert(source.file.relativePath)
            output.parts.append(Part(node: entry.node, url: entry.url, text: source.text, isOpen: source.isOpen))
        }
        for file in files where !found.contains(file.relativePath) { output.problems.append(file.relativePath) }
        return output
    }
}
