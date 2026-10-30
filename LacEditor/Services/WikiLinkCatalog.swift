import Combine
import Foundation

/// Кэш списка Markdown-файлов для оформления, предпросмотра и автодополнения wiki-ссылок (один на окно).
/// Не индекс содержимого: хранятся только относительные пути; действия (переход, экспорт) читают диск заново.
@MainActor
final class WikiLinkCatalog: ObservableObject {
    @Published private(set) var snapshot: MarkdownWikiLinkResolver?

    private var requestedRoot: URL?
    private var requestedDocumentURL: URL?
    private var isRequested = false
    private var loadingBase: URL?
    private var isLoading = false
    private var isStale = true
    private var generation: UInt = 0
    private var loadTask: Task<Void, Never>?
    private var loader: Task<(resolver: MarkdownWikiLinkResolver, isChanged: Bool)?, Never>?
    private var invalidateTask: Task<Void, Never>?

    deinit {
        loader?.cancel()
        loadTask?.cancel()
        invalidateTask?.cancel()
    }

    /// Запускает загрузку, если база сменилась или список устарел. Сам ничего не публикует синхронно.
    func ensure(root: URL?, documentURL: URL?) {
        isRequested = true
        requestedRoot = root
        requestedDocumentURL = documentURL
        let base = MarkdownWikiLinkResolver.base(root: root, documentURL: documentURL)
        if isLoading, loadingBase == base { return }
        if !isStale, snapshot?.base == base, snapshot != nil { return }
        load(root: root, documentURL: documentURL, base: base)
    }

    /// Список мог измениться на диске; перезагрузка с паузой, только если им уже пользовались.
    func invalidate() {
        isStale = true
        guard isRequested else { return }
        invalidateTask?.cancel()
        invalidateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.load(root: self.requestedRoot, documentURL: self.requestedDocumentURL,
                      base: MarkdownWikiLinkResolver.base(root: self.requestedRoot, documentURL: self.requestedDocumentURL))
        }
    }

    private func load(root: URL?, documentURL: URL?, base: URL?) {
        loader?.cancel()
        loadTask?.cancel()
        generation &+= 1
        let current = generation
        isLoading = true
        loadingBase = base
        // Резолвер, токен и сравнение наборов путей считаются в фоне; на главном потоке остаётся только присваивание.
        let old = snapshot
        let loader = Task.detached(priority: .utility) { () -> (resolver: MarkdownWikiLinkResolver, isChanged: Bool)? in
            guard let context = try? MarkdownWikiLinkContext.load(root: root, documentURL: documentURL, isCancelled: { Task.isCancelled }) else { return nil }
            let loaded = context.resolver
            if let old, old.base == loaded.base, Set(old.paths) == Set(loaded.paths) { return (old, false) }
            return (MarkdownWikiLinkResolver(base: loaded.base, paths: loaded.paths, token: (old?.token ?? 0) &+ 1), true)
        }
        self.loader = loader
        loadTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await loader.value } onCancel: { loader.cancel() }
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.isLoading = false
            guard let result,
                  result.resolver.base == MarkdownWikiLinkResolver.base(root: self.requestedRoot, documentURL: self.requestedDocumentURL) else { return }
            self.isStale = false
            if result.isChanged { self.snapshot = result.resolver }
        }
    }
}
