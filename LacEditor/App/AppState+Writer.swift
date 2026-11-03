import AppKit
import SwiftUI

/// Писательский режим вкладки и действия над деревом рукописи.
@MainActor
extension AppState {
    /// Название проекта для заголовка окна («Проект › Документ»); у обычной вкладки nil.
    var writerWindowTitlePrefix: String? { writerSession?.title }

    /// Узел проекта для открытого документа (команды меню «Вверх», «Вниз» работают с ним).
    var currentManuscriptNodeID: UUID? {
        guard let url = selectedDocument?.url else { return nil }
        return writerSession?.projectStore.node(forFileURL: url)?.id
    }

    /// Узел для команд «Вверх», «Вниз»: выбранный в дереве, если дерево в фокусе, иначе узел открытого документа.
    var manuscriptActionNodeID: UUID? {
        if let session = writerSession, session.isTreeFocused, let id = session.selectedNodeID,
           session.projectStore.node(id: id) != nil { return id }
        return currentManuscriptNodeID
    }

    /// ⌘⇧E: в дереве переключает «Включать в книгу» у выбранного узла, иначе добавляет документ в проект.
    func manuscriptIncludeShortcut() {
        if let session = writerSession, session.isTreeFocused, let id = session.selectedNodeID {
            toggleManuscriptInclude(id)
        } else {
            addCurrentDocumentToProject()
        }
    }

    private var writerStore: ManuscriptProjectStore? { writerSession?.projectStore }

    private func reportWriterError(_ error: Error) {
        sidebarFeedback.show(error.localizedDescription, symbol: "exclamationmark.triangle")
    }

    // MARK: Режим вкладки

    func enableWriterMode() {
        guard let manager = windowManager, let window = hostWindow,
              manager.ownsVisibleState(self, window: window), writerWizardSheet == nil else { return }
        // Папка уже открыта: проект берётся из неё, окно выбора нужно только без папки.
        if let root = folderWorkspace.rootURL {
            startWriterProject(at: root)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("选择书稿项目的文件夹")
        panel.prompt = L10n.tr("选择")
        panel.directoryURL = folderWorkspace.rootURL
        guard panel.runModal() == .OK, let url = panel.url,
              manager.ownsVisibleState(self, window: window) else { return }
        startWriterProject(at: url)
    }

    /// Открывает папку как проект: есть манифест — вкладка привязывается к нему, нет — запускается мастер.
    func startWriterProject(at url: URL) {
        guard let manager = windowManager else { return }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        guard openFolder(root) else { return }
        let probe = ManuscriptProjectStore.probe(root: root)
        switch probe {
        case .none:
            presentManuscriptProjectWizard(root: root)
        case .found:
            if let session = manager.writerSession(for: root, probe: probe) { manager.attachWriter(session, to: self) }
        case .unreadable:
            if let session = manager.writerSession(for: root, probe: probe) { manager.attachWriter(session, to: self) }
            sidebarFeedback.show(L10n.tr("无法读取项目文件 .laceditor/project.json"), symbol: "exclamationmark.triangle")
        }
    }

    /// Вкладка становится обычной. Открытые документы и папка остаются.
    func exitWriterMode() {
        windowManager?.detachWriter(from: self)
    }

    /// Проект закрывается во всех вкладках; вкладки остаются обычными.
    func closeWriterProject() {
        guard let manager = windowManager, let session = writerSession else { return }
        manager.states(of: session).forEach { manager.detachWriter(from: $0) }
    }

    /// Плашка «Проект не найден»: выбрать папку проекта или продолжить как обычная вкладка.
    func resolveMissingWriterProject(choosingFolder: Bool) {
        guard let pending = pendingWriterProject, let manager = windowManager else {
            writerProjectIssue = nil
            return
        }
        guard choosingFolder else {
            writerProjectIssue = nil
            pendingWriterProject = nil
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("选择")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let probe = ManuscriptProjectStore.probe(root: root)
        guard case let .found(projectID, _, _) = probe, projectID == pending.projectID,
              let session = manager.writerSession(for: root, probe: probe) else {
            sidebarFeedback.show(L10n.tr("所选文件夹不是此项目"), symbol: "exclamationmark.triangle")
            return
        }
        manager.attachWriter(session, to: self)
    }

    // MARK: Мастер проекта

    func presentManuscriptProjectWizard(root: URL) {
        guard writerWizardSheet == nil, let window = hostWindow else { return }
        let model = ManuscriptWizardModel(root: root)
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: ManuscriptProjectWizardView(
            model: model,
            create: { [weak self] title, language, files in
                self?.finishWriterWizard(root: root, title: title, language: language, files: files)
            },
            cancel: { [weak self] in self?.closeWriterWizard() }
        )))
        sheet.styleMask.remove(.closable)
        writerWizardSheet = sheet
        window.beginSheet(sheet)
    }

    func closeWriterWizard() {
        guard let sheet = writerWizardSheet else { return }
        writerWizardSheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    /// Создаёт манифест и привязывает вкладку. Возвращает текст ошибки для мастера или nil при успехе.
    private func finishWriterWizard(root: URL, title: String, language: String?, files: [String]) -> String? {
        guard let manager = windowManager else { return nil }
        let key = root.standardizedFileURL.path
        do {
            if let session = manager.writerSessions[key] {
                if case .unreadable = session.projectStore.state {
                    try session.projectStore.recreateAfterCorruption(title: title, language: language, files: files)
                } else {
                    try session.projectStore.createProject(title: title, language: language, files: files)
                }
                manager.attachWriter(session, to: self)
            } else {
                let store = ManuscriptProjectStore(rootURL: root)
                try store.createProject(title: title, language: language, files: files)
                let session = WriterSession(rootURL: root, projectStore: store)
                manager.writerSessions[key] = session
                manager.attachWriter(session, to: self)
            }
        } catch {
            return error.localizedDescription
        }
        closeWriterWizard()
        return nil
    }

    // MARK: Действия над узлами

    func openManuscriptNode(_ id: UUID) {
        guard let store = writerStore, let node = store.node(id: id), node.kind == .text,
              let url = store.fileURL(for: node) else { return }
        guard FileManager.default.fileExists(atPath: url.path),
              (try? FolderSearchService.pathIsSafe(url, root: store.rootURL, isCancelled: { false })) == true else {
            sidebarFeedback.show(L10n.tr("文件不存在"), symbol: "exclamationmark.triangle")
            return
        }
        openFile(url)
    }

    /// Новый файл-сцена в корне проекта и узел после `after` (или в конце `parent`). Возвращает id нового узла.
    @discardableResult
    func createScene(parent: UUID?, after: UUID?) -> UUID? {
        guard let store = writerStore, let project = store.project else { return nil }
        let title = L10n.tr("新场景")
        var created: URL?
        for attempt in 1...20 {
            let name = (attempt == 1 ? title : "\(title) \(attempt)") + ".md"
            do {
                created = try fileService.createWorkspaceTextFile(named: name, contents: "# \(title)\n\n", in: store.rootURL, root: store.rootURL)
                break
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                reportWriterError(error)
                return nil
            }
        }
        guard let url = created, let path = ManuscriptProjectFiles.relativePath(for: url, root: store.rootURL) else {
            sidebarFeedback.show(L10n.tr("无法创建文件"), symbol: "exclamationmark.triangle")
            return nil
        }
        let node = ManuscriptNode(kind: .text, title: title, path: path)
        let index = insertionIndex(project: project, parent: parent, after: after)
        do {
            try store.insertNode(node, parent: parent, index: index)
        } catch {
            reportWriterError(error)
            return nil
        }
        openFile(url)
        return node.id
    }

    @discardableResult
    func createGroup(parent: UUID?, after: UUID?) -> UUID? {
        guard let store = writerStore, let project = store.project else { return nil }
        let node = ManuscriptNode(kind: .group, title: L10n.tr("新分组"))
        do {
            try store.insertNode(node, parent: parent, index: insertionIndex(project: project, parent: parent, after: after))
        } catch {
            reportWriterError(error)
            return nil
        }
        return node.id
    }

    private func insertionIndex(project: ManuscriptProject, parent: UUID?, after: UUID?) -> Int {
        let siblings = project.children(of: parent)
        if let after, let index = siblings.firstIndex(where: { $0.id == after }) { return index + 1 }
        return siblings.count
    }

    /// Выбор существующих файлов из папки проекта.
    func addExistingFiles(parent: UUID?) {
        guard let store = writerStore else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = store.rootURL
        guard panel.runModal() == .OK else { return }
        addFilesToProject(panel.urls, parent: parent)
    }

    /// Добавляет файлы в конец `parent`; уже включённые и посторонние пропускаются.
    func addFilesToProject(_ urls: [URL], parent: UUID?) {
        guard let store = writerStore else { return }
        var skipped = 0
        for url in urls {
            guard let project = store.project else { return }
            guard let path = ManuscriptProjectFiles.relativePath(for: url, root: store.rootURL),
                  project.node(forRelativePath: path) == nil else { skipped += 1; continue }
            let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            do {
                try store.insertNode(ManuscriptNode(kind: .text, title: title, path: path),
                                     parent: parent, index: project.children(of: parent).count)
            } catch {
                reportWriterError(error)
                return
            }
        }
        if skipped > 0 { sidebarFeedback.show(L10n.tr("已跳过 %d 个文件", skipped), symbol: "info.circle") }
    }

    /// Текущий документ становится сценой проекта.
    func addCurrentDocumentToProject() {
        guard let url = selectedDocument?.url else { return }
        addFilesToProject([url], parent: nil)
    }

    func removeNodeFromProject(_ id: UUID) {
        guard let store = writerStore else { return }
        do {
            let removed = try store.removeNode(id: id)
            sidebarFeedback.show(L10n.tr("已从项目中移除“%@”", removed.node.title), symbol: "minus.circle", undo: { [weak store] in
                guard let store else { return false }
                return (try? store.insertNode(removed.node, parent: removed.parent, index: removed.index)) != nil
            })
        } catch {
            reportWriterError(error)
        }
    }

    func toggleManuscriptInclude(_ id: UUID) {
        guard let store = writerStore, let node = store.node(id: id) else { return }
        do { try store.setInclude(!node.include, nodeID: id) } catch { reportWriterError(error) }
    }

    func renameManuscriptNode(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = writerStore, !trimmed.isEmpty, store.node(id: id)?.title != trimmed else { return }
        do { try store.update { $0.mutateNode(id: id) { $0.title = trimmed } } } catch { reportWriterError(error) }
    }

    /// Переносит узел. `index` считается после изъятия узла из прежнего места.
    func moveManuscriptNode(_ id: UUID, toParent parent: UUID?, index: Int) {
        do { try writerStore?.moveNode(id: id, toParent: parent, index: index) } catch { reportWriterError(error) }
    }

    func moveManuscriptNodeUp(_ id: UUID) { shiftManuscriptNode(id, by: -1) }
    func moveManuscriptNodeDown(_ id: UUID) { shiftManuscriptNode(id, by: 1) }

    private func shiftManuscriptNode(_ id: UUID, by delta: Int) {
        guard let project = writerStore?.project, let place = project.location(of: id) else { return }
        let target = place.index + delta
        guard target >= 0, target < project.children(of: place.parent).count else { return }
        moveManuscriptNode(id, toParent: place.parent, index: target)
    }

    /// Узел уходит внутрь предыдущей группы того же уровня.
    func nestManuscriptNode(_ id: UUID) {
        guard let project = writerStore?.project, let place = project.location(of: id), place.index > 0 else { return }
        let previous = project.children(of: place.parent)[place.index - 1]
        guard previous.kind == .group else { return }
        moveManuscriptNode(id, toParent: previous.id, index: previous.children.count)
    }

    /// Узел выходит из группы на уровень выше, сразу после неё.
    func outdentManuscriptNode(_ id: UUID) {
        guard let project = writerStore?.project, let place = project.location(of: id), let parent = place.parent,
              let parentPlace = project.location(of: parent) else { return }
        moveManuscriptNode(id, toParent: parentPlace.parent, index: parentPlace.index + 1)
    }

    /// «Указать файл…» для узла, чей файл не найден.
    func locateMissingFile(for id: UUID) {
        guard let store = writerStore else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let path = ManuscriptProjectFiles.relativePath(for: url, root: store.rootURL) else {
            sidebarFeedback.show(ManuscriptProjectError.outsideRoot.localizedDescription, symbol: "exclamationmark.triangle")
            return
        }
        do { try store.relocateNode(id: id, toRelativePath: path) } catch { reportWriterError(error) }
    }

    func revealManuscriptNode(_ id: UUID) {
        guard let store = writerStore, let node = store.node(id: id), let url = store.fileURL(for: node) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
