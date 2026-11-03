import AppKit
import SwiftUI

/// Карточки персонажей, мест и мира писательского проекта.
@MainActor
extension AppState {
    private func reportWorldError(_ error: Error) {
        sidebarFeedback.show(error.localizedDescription, symbol: "exclamationmark.triangle")
    }

    private func preparedWorld() -> WriterSession? {
        guard let session = writerSession else { return nil }
        session.world.ai.attach(self)
        return session
    }

    // MARK: Каталог

    func refreshWorld(delay: TimeInterval = 0) {
        guard let session = preparedWorld() else { return }
        let paths = Set((session.projectStore.project?.allNodes() ?? []).compactMap(\.path))
        session.world.catalog.refresh(root: session.rootURL, manuscriptPaths: paths, delay: delay)
    }

    /// Хук после сохранения: карточка могла измениться, папка перечитывается с задержкой (схлопывает частые сохранения).
    func noteSavedForWorld(_ url: URL) {
        guard let session = writerSession, session.contains(url), url.pathExtension.lowercased() == "md"
                || url.pathExtension.lowercased() == "markdown" else { return }
        refreshWorld(delay: 0.5)
    }

    func openStoryCard(_ card: StoryCard) {
        openFile(card.url)
    }

    // MARK: Создание карточек

    /// Спрашивает название и создаёт карточку.
    func requestWorldCard(type: StoryCardType) {
        guard writerSession != nil, let window = hostWindow, windowManager?.ownsVisibleState(self, window: window) == true else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("新建%@卡片", type.title)
        alert.informativeText = L10n.tr("名称")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("创建"))
        alert.addButton(withTitle: L10n.tr("取消"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createWorldCard(type: type, name: field.stringValue)
    }

    func createWorldCard(type: StoryCardType, name: String) {
        guard let session = preparedWorld() else { return }
        do {
            let url = try makeWorldCardFile(type: type, name: name, root: session.rootURL)
            refreshWorld()
            openFile(url)
        } catch {
            reportWorldError(error)
        }
    }

    func createWorldCards(from candidates: [StoryCardCandidate]) {
        guard let session = preparedWorld() else { return }
        var created = 0
        for candidate in candidates {
            do {
                _ = try makeWorldCardFile(type: candidate.type, name: candidate.name, root: session.rootURL)
                created += 1
            } catch {
                reportWorldError(error)
            }
        }
        refreshWorld()
        if created > 0 { sidebarFeedback.show(L10n.tr("已创建 %lld 张卡片", created)) }
    }

    /// Папка «Мир» (любая из трёх языковых) создаётся при необходимости; существующие файлы не перезаписываются.
    private func makeWorldCardFile(type: StoryCardType, name: String, root: URL) throws -> URL {
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for forbidden in ["/", ":", "\\"] { title = title.replacingOccurrences(of: forbidden, with: " ") }
        title = title.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasPrefix(".") { title.removeFirst() }
        guard !title.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let manager = FileManager.default
        let folder: URL
        if let existing = StoryCardTemplates.folderNames.first(where: {
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }) {
            folder = root.appendingPathComponent(existing, isDirectory: true)
        } else {
            folder = try fileService.createWorkspaceItem(named: StoryCardTemplates.folderName, in: root, root: root, isDirectory: true)
        }
        let contents = NoteTemplateService.render(StoryCardTemplates.skeleton(for: type), title: title, date: Date())
        var attempt = 1
        while true {
            let fileName = NoteTemplateService.normalizedFileName(attempt == 1 ? title : "\(title) \(attempt)")
            if !manager.fileExists(atPath: folder.appendingPathComponent(fileName).path) {
                return try fileService.createWorkspaceTextFile(named: fileName, contents: contents, in: folder, root: root)
            }
            attempt += 1
            if attempt > 99 { throw CocoaError(.fileWriteFileExists) }
        }
    }

    func installStoryCardTemplates() {
        let path = preferences.templatesFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("未设置模板文件夹")
            alert.informativeText = L10n.tr("在“设置 > 文件”中选择模板文件夹。")
            alert.addButton(withTitle: L10n.tr("打开设置…"))
            alert.addButton(withTitle: L10n.tr("取消"))
            if alert.runModal() == .alertFirstButtonReturn, let windowManager {
                SettingsWindowController.shared.present(windowManager: windowManager)
            }
            return
        }
        do {
            let added = try StoryCardTemplates.installTemplates(into: URL(fileURLWithPath: path, isDirectory: true))
            sidebarFeedback.show(added > 0 ? L10n.tr("已添加 %lld 个卡片模板", added) : L10n.tr("卡片模板已存在"))
        } catch {
            presentError(title: L10n.tr("无法读取模板文件夹"), error: error)
        }
    }

    // MARK: Правки текущей карточки

    /// Одна отменяемая правка шапки открытой карточки.
    func applyStoryCardEdit(_ edit: StoryCardHeaderEdit, documentID: UUID) {
        guard let (document, text, revision) = writableCardText(documentID) else { return }
        do {
            let patch = try StoryCardHeaderEditor.patch(for: edit, in: text, newID: { UUID() })
            applyCardReplacement(NSRange(location: patch.range.location, length: patch.range.length), replacement: patch.replacement,
                                 in: text, revision: revision, document: document)
        } catch let error as StoryCardHeaderEditError {
            switch error {
            case .duplicateAlias, .emptyValue, .notFound: break
            case .noHeader, .flowStyle, .verificationFailed:
                sidebarFeedback.show(L10n.tr("无法修改此卡片的头部（%@）", L10n.tr("头部使用了不支持的写法")), symbol: "exclamationmark.triangle")
            }
        } catch {
            reportWorldError(error)
        }
    }

    /// Несколько правок шапки одним патчем: один шаг отмены, повторы связей пропускаются.
    func applyStoryCardEdits(_ edits: [StoryCardHeaderEdit], documentID: UUID) {
        guard !edits.isEmpty, let (document, text, revision) = writableCardText(documentID) else { return }
        do {
            guard let patch = try StoryCardHeaderEditor.patch(for: edits, in: text, newID: { UUID() }) else { return }
            applyCardReplacement(patch.range, replacement: patch.replacement, in: text, revision: revision, document: document)
        } catch let error as StoryCardHeaderEditError {
            switch error {
            case .duplicateAlias, .emptyValue, .notFound: break
            case .noHeader, .flowStyle, .verificationFailed:
                sidebarFeedback.show(L10n.tr("无法修改此卡片的头部（%@）", L10n.tr("头部使用了不支持的写法")), symbol: "exclamationmark.triangle")
            }
        } catch {
            reportWorldError(error)
        }
    }

    /// Факты дописываются в раздел «Факты» (раздела нет — создаётся в конце), цитаты не записываются.
    func applyStoryCardFacts(_ facts: [String], documentID: UUID) {
        guard let (document, text, revision) = writableCardText(documentID),
              let insertion = StoryCardFactsWriter.insertion(adding: facts, to: text) else { return }
        applyCardReplacement(insertion.range, replacement: insertion.replacement, in: text, revision: revision, document: document)
    }

    private func writableCardText(_ documentID: UUID) -> (EditorDocument, String, UInt)? {
        guard let document = documents.first(where: { $0.id == documentID }), selectedDocument === document,
              document.ioState == .idle, !document.hasPendingLiveEdits else { return nil }
        let extraction = EditorTextExtractionRequest(documentID: documentID, allowsTokenAtCaret: false, allowsWholeDocument: true,
                                                     requiresEditable: true, includesEditorText: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let current = extraction.result else {
            sidebarFeedback.show(L10n.tr("当前文本无法修改"), symbol: "exclamationmark.triangle")
            return nil
        }
        return (document, extraction.editorText ?? current.text, current.editorRevision)
    }

    private func applyCardReplacement(_ range: NSRange, replacement: String, in text: String, revision: UInt, document: EditorDocument) {
        let request = EditorRangeReplacementRequest(
            documentID: document.id,
            range: range,
            originalText: (text as NSString).substring(with: range),
            replacementText: replacement,
            expectedEditorRevision: revision,
            actionName: L10n.tr("修改卡片")
        )
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        if !request.wasHandled {
            sidebarFeedback.show(request.failureMessage ?? L10n.tr("当前文本无法修改"), symbol: "exclamationmark.triangle")
        }
    }

    // MARK: Кандидаты

    /// Алгоритм по тексту текущего документа; AI предлагается, если алгоритм ничего не нашёл.
    func findWorldCandidates() {
        guard let session = preparedWorld(), let window = hostWindow, let manager = windowManager,
              manager.ownsVisibleState(self, window: window), window.attachedSheet == nil,
              let document = selectedDocument, document.ioState == .idle else { return }
        guard document.language == .markdown else {
            sidebarFeedback.show(L10n.tr("仅适用于 Markdown 文档"), symbol: "info.circle")
            return
        }
        let text = document.synchronizedSnapshot().text
        let known = session.world.catalog.cards
        session.world.ai.clear()
        session.world.localCandidates = []
        session.world.candidatesNote = ""
        session.world.isSearchingCandidates = true
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: WorldCandidatesView(
            world: session.world,
            close: { [weak self] in self?.closeWorldCandidates() },
            create: { [weak self] items in self?.createWorldCards(from: items) },
            askAI: { [weak self] in self?.findWorldCandidatesWithAI() }
        ).environmentObject(self).environmentObject(manager)))
        sheet.styleMask.remove(.closable)
        session.world.candidatesWindow = sheet
        window.beginSheet(sheet)
        Task { [weak session] in
            let found = await Task.detached(priority: .userInitiated) {
                StoryCardCandidateFinder.find(in: text, known: known)
            }.value
            guard let session, session.world.candidatesWindow === sheet else { return }
            session.world.localCandidates = found
            session.world.isSearchingCandidates = false
        }
    }

    func findWorldCandidatesWithAI() {
        guard let session = preparedWorld(), let document = selectedDocument, document.language == .markdown else { return }
        session.world.ai.findCandidates(document: document, known: session.world.catalog.cards)
    }

    func closeWorldCandidates() {
        guard let session = writerSession else { return }
        session.world.ai.clear()
        session.world.isSearchingCandidates = false
        guard let sheet = session.world.candidatesWindow else { return }
        session.world.candidatesWindow = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    // MARK: Контекст для AI

    /// Карточки, упомянутые в текущем документе и выбранных файлах (без `ai: exclude`).
    func mentionedStoryCardURLs(files: [URL]) async -> [URL] {
        guard let session = writerSession else { return [] }
        let cards = session.world.catalog.cards.filter { !$0.excludedFromAI }
        guard !cards.isEmpty else { return [] }
        let current = selectedDocument?.synchronizedSnapshot().text
        // Текущая карточка в собственный контекст не попадает.
        let selfURL = selectedDocument?.url?.standardizedFileURL
        // Открытые документы читаются по живому тексту, остальные файлы — с диска.
        var live: [URL: String] = [:]
        for document in documents {
            if let url = document.url?.standardizedFileURL, files.contains(where: { $0.standardizedFileURL == url }) {
                live[url] = document.synchronizedSnapshot().text
            }
        }
        let matcher = StoryCardMatcher(cards: cards)
        let keys = await Task.detached(priority: .userInitiated) { () -> Set<String> in
            var result = Set<String>()
            if let current { result.formUnion(matcher.counts(in: current).keys) }
            for url in files {
                let text = live[url.standardizedFileURL] ?? (try? String(contentsOf: url, encoding: .utf8))
                if let text { result.formUnion(matcher.counts(in: text).keys) }
            }
            return result
        }.value
        return cards.filter { keys.contains($0.id) && $0.url.standardizedFileURL != selfURL }.map(\.url)
    }
}
