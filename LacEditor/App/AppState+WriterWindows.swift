import AppKit
import SwiftUI

/// Окно проекта рукописи: следит за темой. Вкладку-открыватель не держит: действия идут через замыкания с живой вкладкой проекта.
private struct WriterWindowRoot<Content: View>: View {
    @ObservedObject var preferences: AppPreferences
    let content: Content

    var body: some View {
        content.preferredColorScheme(WriterWindowTheme.colorScheme(preferences.theme))
    }
}

private enum WriterWindowTheme {
    @MainActor static func colorScheme(_ theme: AppTheme) -> ColorScheme {
        switch theme {
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Доска карточек и сводный просмотр: немодальные окна, по одному на проект.
@MainActor
extension AppState {
    /// Вкладка проекта, от имени которой окно открывает файлы и проверяет AI: эта, а если её уже закрыли — любая другая.
    private static func writerWindowHost(_ candidate: AppState?, session: WriterSession?, manager: WindowManager?) -> AppState? {
        guard let session else { return nil }
        if let candidate, candidate.writerSession === session { return candidate }
        return manager?.states(of: session).first
    }

    func presentWriterBoard() {
        guard let session = writerSession, let manager = windowManager else { return }
        if let existing = session.boardWindow {
            session.boardController?.refresh()
            existing.show()
            return
        }
        let counter = session.wordCounter
        if counter.counts.isEmpty, !counter.isCounting, session.projectStore.state == .loaded {
            counter.refresh(store: session.projectStore, openDocuments: manager.folderSearchSnapshots(root: session.rootURL))
        }
        let controller = WriterBoardController(
            store: session.projectStore,
            wordCounts: { [weak counter] in counter?.counts ?? [:] },
            windowManager: manager, preferences: preferences,
            aiAvailability: { [weak self, weak session, weak manager] in
                Self.writerWindowHost(self, session: session, manager: manager)?.aiAvailability(for: .summary) ?? .aiDisabled
            })
        controller.openSceneHandler = { [weak self, weak session, weak manager] id in
            Self.writerWindowHost(self, session: session, manager: manager)?.openManuscriptNode(id)
        }
        controller.createSceneHandler = { [weak self, weak session, weak manager] parent in
            Self.writerWindowHost(self, session: session, manager: manager)?.createScene(parent: parent, after: nil)
        }
        controller.openCombinedHandler = { [weak self, weak session, weak manager] group in
            Self.writerWindowHost(self, session: session, manager: manager)?.presentWriterCombinedView(scope: .group(group))
        }
        let root = WriterWindowRoot(preferences: preferences, content: WriterBoardView(
            controller: controller, store: session.projectStore, counter: counter)
            .environmentObject(manager))
        let window = WriterAuxiliaryWindowController(
            kind: .board, title: L10n.tr("卡片板 - %@", session.title),
            content: NSHostingView(rootView: root), autosaveName: "LacEditor.WriterBoard")
        window.onClose = { [weak session, weak controller, nsWindow = window.window] in
            controller?.cancelAll()
            session?.boardController = nil
            session?.boardWindow = nil
            session?.unregisterAuxiliaryWindow(nsWindow)
        }
        window.onBecomeKey = { [weak controller] in controller?.refresh() }
        session.boardController = controller
        session.boardWindow = window
        session.registerAuxiliaryWindow(window.window)
        window.show()
    }

    func presentWriterCombinedView(scope: WriterCombinedViewController.Scope = .wholeBook) {
        guard let session = writerSession, let manager = windowManager else { return }
        if let existing = session.combinedWindow, let controller = session.combinedController {
            if controller.scope != scope {
                controller.scope = scope
                controller.reload()
            }
            existing.show()
            return
        }
        let controller = WriterCombinedViewController(
            store: session.projectStore, windowManager: manager, preferences: preferences, scope: scope,
            isDark: { [weak preferences] in preferences.map { WriterWindowTheme.colorScheme($0.theme) == .dark } ?? false })
        controller.openNodeHandler = { [weak self, weak session, weak manager] id in
            Self.writerWindowHost(self, session: session, manager: manager)?.openManuscriptNode(id)
        }
        let root = WriterWindowRoot(preferences: preferences, content: WriterCombinedView(controller: controller)
            .environmentObject(manager))
        let window = WriterAuxiliaryWindowController(
            kind: .combined, title: L10n.tr("合并预览 - %@", session.title),
            content: NSHostingView(rootView: root), autosaveName: "LacEditor.WriterCombined")
        window.onClose = { [weak session, weak controller, nsWindow = window.window] in
            controller?.cancel()
            session?.combinedController = nil
            session?.combinedWindow = nil
            session?.unregisterAuxiliaryWindow(nsWindow)
        }
        window.onBecomeKey = { [weak controller] in controller?.checkStale() }
        session.combinedController = controller
        session.combinedWindow = window
        session.registerAuxiliaryWindow(window.window)
        controller.reload()
        window.show()
    }
}
