import AppKit
import SwiftUI

/// Поиск режима хранилища: контроллер боковой панели и открытие результата с переходом к найденному фрагменту.
extension AppState {
    /// Контроллер поиска этой вкладки. Привязан к сессии: при смене хранилища создаётся новый (прежний отменяется).
    var vaultSearch: VaultSearchController {
        let owner = vaultSession.map { ObjectIdentifier($0) }
        if let storage = vaultSearchStorage, storage.ownerID == owner { return storage }
        // Прежний контроллер отменяет `WindowManager.detachVault`: из геттера (он вызывается из body) состояние не меняем.
        let controller = VaultSearchController(
            search: { [weak self] query in
                guard let client = self?.vaultSession?.client else { throw CancellationError() }
                return try await client.search(query: query)
            },
            namePaths: { [weak self] in self?.vaultSession?.catalog.wikiLinkPaths() ?? [] },
            isNameListComplete: { [weak self] in self?.vaultSession?.catalog.isFullListingLoaded ?? true },
            hiddenRoots: { [weak self] in Set(self?.vaultSession?.connection.hiddenRoots ?? []) },
            isOnline: { [weak self] in self?.vaultSession?.isOnline ?? false },
            open: { [weak self] result, newTab, query in self?.openVaultSearchResult(result, newTab: newTab, query: query) },
            announce: { text in
                // Низкий приоритет: объявление не перебивает то, что VoiceOver читает сейчас, и фокус не отнимает.
                var message = AttributedString(text)
                message.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(message).post()
            })
        controller.ownerID = owner
        vaultSearchStorage = controller
        return controller
    }

    /// ⌘⇧F и пункт меню «Искать в хранилище…»: панель показывается, фокус уходит в поле поиска.
    func focusVaultSearch() {
        guard vaultSession != nil else { return }
        isSidebarVisible = true
        vaultSearch.requestFocus()
    }

    /// Открывает заметку результата и, если есть отрывок сервера, показывает его место в тексте.
    func openVaultSearchResult(_ result: VaultSearchResult, newTab: Bool, query: String) {
        guard let manager = windowManager, let session = vaultSession else { return }
        let search = vaultSearch
        search.revealTask?.cancel()
        search.revealTask = nil
        let path = result.path
        let snippet = result.snippet
        manager.openVaultNote(path: path, from: self, inNewTab: newTab) { [weak manager, weak session, weak search] loaded in
            // Нет связи или заметки нет в кэше: заметка откроется, когда появится связь, — тогда просто сверху.
            guard loaded, let snippet, let manager, let session,
                  let state = manager.states(of: session).first(where: { $0.vaultNote?.path == path }) else { return }
            search?.revealTask = Task { @MainActor [weak state] in
                await state?.revealVaultSnippet(snippet, query: query, path: path)
            }
        }
    }

    /// Ищет отрывок сервера в текущем тексте заметки и выделяет его. Если за время поиска пользователь что-то сделал
    /// (правка, смена вкладки, набор иероглифов), переход молча отменяется.
    func revealVaultSnippet(_ snippet: String, query: String, path: String) async {
        guard let document = vaultDocument, vaultNote?.path == path else { return }
        let snapshot = document.synchronizedSnapshot()
        let match: VaultSnippetMatch?
        if snapshot.utf16Length > 200_000 {
            match = await Task.detached(priority: .userInitiated) {
                VaultSnippetLocator.locate(snippet: snippet, in: snapshot.text, query: query)
            }.value
        } else {
            match = VaultSnippetLocator.locate(snippet: snippet, in: snapshot.text, query: query)
        }
        guard !Task.isCancelled, selectedDocument === document, document.textRevision == snapshot.revision,
              !document.hasPendingLiveEdits,
              (hostWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if let match {
            revealFolderSearchRange(match.selection, in: document)
        } else if VaultSnippetLocator.cleanedSnippet(snippet) != nil {
            let message = L10n.tr("未在笔记中找到该片段，已从开头打开")
            showVaultNotice(message)
            AccessibilityNotification.Announcement(message).post()
        }
    }
}
