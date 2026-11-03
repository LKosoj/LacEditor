import AppKit
import Foundation

extension AppState {
    /// Хук после сохранения: обновляет файл в поисковом индексе папки. Индекс на сохранении не создаётся,
    /// только обновляется, если он уже есть; ошибки молча игнорируются (индекс догонится при следующем обновлении).
    func noteSavedForSearchIndex(_ url: URL) {
        guard let root = folderWorkspace.rootURL, SearchIndexer.isIndexable(url),
              FolderSearchService.relativePath(url, root: root) != nil,
              SearchIndexRegistry.shared.existingIndex(for: root) != nil else { return }
        SearchIndexUpdater.shared.schedule(url, root: root)
    }

    /// Удаляет индекс текущей папки и строит заново.
    func rebuildSearchIndex() {
        guard folderWorkspace.rootURL != nil else { return }
        folderSearch.words.rebuildIndex()
    }

    /// Удаляет индекс текущей папки после подтверждения.
    func deleteSearchIndex() {
        guard folderWorkspace.rootURL != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("删除此文件夹的搜索索引？之后可重新建立。")
        alert.addButton(withTitle: L10n.tr("取消"))
        let delete = alert.addButton(withTitle: L10n.tr("删除"))
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        folderSearch.words.deleteIndex()
    }
}

/// Обновление индекса после сохранения: повторные сохранения одного файла за 0,4 с схлопываются в одно.
@MainActor
final class SearchIndexUpdater {
    static let shared = SearchIndexUpdater()

    private var tasks: [String: Task<Void, Never>] = [:]

    func schedule(_ url: URL, root: URL) {
        let key = url.standardizedFileURL.path
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.tasks[key] = nil
            guard let index = SearchIndexRegistry.shared.existingIndex(for: root) else { return }
            try? await SearchIndexer.refreshFile(index, root: root, url: url)
        }
    }
}
