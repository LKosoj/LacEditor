import AppKit
import Combine
import Foundation

/// Проект рукописи, открытый в писательском режиме. Один на корень проекта, живёт, пока к нему привязана хотя бы одна вкладка.
@MainActor
final class WriterSession: ObservableObject {
    let rootURL: URL
    let projectStore: ManuscriptProjectStore
    let wordCounter = ManuscriptWordCounter()
    let world = StoryCardWorld()
    @Published private(set) var attachedStateCount = 0
    /// Выбранный узел дерева «书稿» и фокус дерева: команды меню действуют на выбранный узел, пока дерево в фокусе.
    @Published var selectedNodeID: UUID?
    @Published var isTreeFocused = false
    /// Доска и сводный просмотр: по одному окну на проект.
    var boardController: WriterBoardController?
    var boardWindow: WriterAuxiliaryWindowController?
    var combinedController: WriterCombinedViewController?
    var combinedWindow: WriterAuxiliaryWindowController?
    /// Окна проекта (доска, сводный просмотр, карты); закрываются вместе с последней вкладкой.
    private var ownedWindows: [NSWindow] = []
    private var storeCancellable: AnyCancellable?

    var projectID: UUID { projectStore.projectID }
    var title: String { projectStore.title }

    init(rootURL: URL, projectStore: ManuscriptProjectStore) {
        self.rootURL = rootURL.standardizedFileURL
        self.projectStore = projectStore
        // Название и дерево меняет хранилище: подписчики сессии должны перерисоваться.
        storeCancellable = projectStore.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func registerAuxiliaryWindow(_ window: NSWindow) {
        guard !ownedWindows.contains(where: { $0 === window }) else { return }
        ownedWindows.append(window)
    }

    /// Окно закрыто пользователем: больше не держим его до закрытия последней вкладки.
    func unregisterAuxiliaryWindow(_ window: NSWindow) {
        ownedWindows.removeAll { $0 === window }
    }

    func attach() { attachedStateCount += 1 }

    /// Отвязывает одну вкладку. Возвращает true, когда вкладок не осталось: окна проекта закрыты, сессию можно удалять.
    func detach() -> Bool {
        attachedStateCount = max(0, attachedStateCount - 1)
        guard attachedStateCount == 0 else { return false }
        wordCounter.cancel()
        boardController?.cancelAll()
        combinedController?.cancel()
        world.cancelAll()
        let windows = ownedWindows
        ownedWindows.removeAll()
        windows.forEach { $0.close() }
        return true
    }

    /// Файл лежит внутри корня проекта.
    func contains(_ url: URL) -> Bool {
        FolderSearchService.relativePath(url, root: rootURL) != nil
    }
}
