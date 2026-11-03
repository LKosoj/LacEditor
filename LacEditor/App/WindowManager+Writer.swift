import AppKit

/// Реестр проектов рукописи (`WriterSession`) и привязка к ним вкладок. Одна сессия на корень проекта.
extension WindowManager {
    /// Общая сессия на корень; создаёт при необходимости. Без манифеста (`.none`) сессии нет.
    /// Повреждённый манифест тоже даёт сессию: секция «Рукопись» предложит создать проект заново.
    func writerSession(for root: URL, probe: ManuscriptProjectProbe) -> WriterSession? {
        if case .none = probe { return nil }
        let root = root.standardizedFileURL
        if let existing = writerSessions[root.path] {
            existing.projectStore.checkForExternalChange()
            return existing
        }
        let session = WriterSession(rootURL: root, projectStore: ManuscriptProjectStore(rootURL: root))
        writerSessions[root.path] = session
        return session
    }

    /// Привязывает вкладку к проекту и отвязывает от прежнего. Документ и его правки не затрагиваются.
    func attachWriter(_ session: WriterSession, to state: AppState) {
        if state.writerSession === session { return }
        detachWriter(from: state)
        state.writerSession = session
        session.attach()
        if state.folderWorkspace.rootURL?.standardizedFileURL.path != session.rootURL.path {
            state.folderWorkspace.setRoot(session.rootURL)
        }
    }

    /// Отвязка одной вкладки; пустая сессия удаляется из реестра, окна проекта закрываются.
    func detachWriter(from state: AppState) {
        state.writerProjectIssue = nil
        state.pendingWriterProject = nil
        guard let session = state.writerSession else { return }
        state.writerSession = nil
        if session.detach() {
            writerSessions = writerSessions.filter { $0.value !== session }
        }
    }

    /// Все вкладки проекта.
    func states(of session: WriterSession) -> [AppState] {
        states.values.filter { $0.writerSession === session }
    }

    /// Сессия для вкладки, открываемой из `source`: проект источника, если файл (когда он известен) внутри корня.
    func inheritedWriterSession(from source: AppState?, openingFileAt url: URL?) -> WriterSession? {
        guard let session = source?.writerSession else { return nil }
        guard let url else { return session }
        return session.contains(url) ? session : nil
    }

    /// Восстановление привязки из файла сессии: проект найден с тем же `projectID` — вкладка снова писательская,
    /// иначе обычная вкладка с плашкой «Проект не найден». Прежняя запись хранится до решения пользователя.
    func restoreWriterProject(_ record: WriterProjectSession?, in state: AppState) {
        guard let record, record.isValid else { return }
        let root = URL(fileURLWithPath: record.rootPath, isDirectory: true).standardizedFileURL
        let probe = ManuscriptProjectStore.probe(root: root)
        if case let .found(projectID, _, _) = probe, projectID == record.projectID,
           let session = writerSession(for: root, probe: probe) {
            attachWriter(session, to: state)
            return
        }
        state.pendingWriterProject = record
        state.writerProjectIssue = WriterProjectIssue(projectTitle: root.lastPathComponent, rootPath: record.rootPath)
    }
}
