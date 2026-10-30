import AppKit
import Foundation

@MainActor
final class AIQuestionController: ObservableObject {
    private struct Pending {
        let question: String
        let usesDraft: Bool
        let mode: AIQuestionSourceMode
        let sources: [AIQuestionSource]
        let selection: EditorTextSelectionSnapshot?
        let bytes: Int
    }

    @Published var draft = ""
    @Published var sourceMode: AIQuestionSourceMode = .currentDocument
    @Published private(set) var files: [URL] = []
    @Published private(set) var turns: [AIQuestionTurn] = []
    @Published private(set) var staleCitationIDs: Set<UUID> = []
    @Published private(set) var isWorking = false
    /// Временная настройка окна: не пишется в сессию, не сбрасывается «Новым разговором».
    @Published var webSearchEnabled = true
    /// Номер текущего веб-поиска в ответе; 0 — поиска нет.
    @Published private(set) var searchProgress = 0
    @Published private(set) var message = "" { didSet { messageKind = .error; messageAction = nil } }
    @Published private(set) var messageKind: StatusKind = .error
    @Published private(set) var messageAction: AIMessageAction?
    private weak var appState: AppState?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pending: Pending?
    private var lastRequest: (question: String, usesDraft: Bool, selectionOnly: Bool)?
    private var activeDocumentID: UUID?
    private var activeProfile: AIModelProfile?
    private var activeKey: String?
    private var activeSelection: EditorTextSelectionSnapshot?
    private var activeSources: [AIQuestionSource] = []
    private var activeJina: JinaConfiguration?
    private var activeSearchKey: String?
    private var activeReaderKey: String?
    private var observer: NSObjectProtocol?
    private let converse: ([AIConversationMessage], AIModelProfile, String?) async throws -> String
    private let loadKey: (AIRole, String) throws -> String?
    private let converseWeb: ([AIConversationMessage], AIModelProfile, String?, AIWebSearchSession) async throws -> String
    private let loadJinaKey: AIJinaCredentials.KeyLoader
    private let jinaClient: JinaClient

    init(appState: AppState,
         converse: @escaping ([AIConversationMessage], AIModelProfile, String?) async throws -> String = { try await AIQuestionService.converse(messages: $0, profile: $1, key: $2) },
         loadKey: @escaping (AIRole, String) throws -> String? = { try AIKeychainStore().load(for: $0, baseURL: $1) },
         converseWeb: @escaping ([AIConversationMessage], AIModelProfile, String?, AIWebSearchSession) async throws -> String = { try await AIQuestionService.converse(messages: $0, profile: $1, key: $2, web: $3) },
         loadJinaKey: @escaping AIJinaCredentials.KeyLoader = AIJinaCredentials.defaultLoader,
         jinaClient: JinaClient = JinaClient()) {
        self.appState = appState; self.converse = converse; self.loadKey = loadKey
        self.converseWeb = converseWeb; self.loadJinaKey = loadJinaKey; self.jinaClient = jinaClient
        observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.documentContentDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let id = note.object as? UUID else { return }
                if (self.isWorking || self.pending != nil), self.activeSources.contains(where: { $0.snapshot.document?.id == id }) {
                    self.cancel()
                    self.post(L10n.tr("所选来源已不可用或已更改。"), kind: .info)
                }
                self.markStale(documentID: id)
            }
        }
    }
    deinit { task?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func post(_ text: String, kind: StatusKind = .error, action: AIMessageAction? = nil) {
        message = text; messageKind = kind; messageAction = action
    }
    private func fail(_ error: Error) { post(error.localizedDescription, action: AIMessageAction.forError(error)) }

    var isWebSearchAvailable: Bool { appState?.preferences.jinaConfiguration.searchEnabled == true }
    var isEnabled: Bool { appState?.preferences.aiFeatures.contains(.ask) == true }
    var availableDocuments: [EditorDocument] { appState.map { AIContextService.availableDocuments(in: $0) } ?? [] }

    func addFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { for url in panel.urls where !files.contains(url) { files.append(url) } }
    }
    func removeFile(_ url: URL) { files.removeAll { $0 == url } }

    func ask() { send(question: draft.trimmingCharacters(in: .whitespacesAndNewlines), usesDraft: true, selectionOnly: false) }
    func askAboutSelection() {
        sourceMode = .currentDocument
        send(question: L10n.tr("请解释所选文本。"), usesDraft: false, selectionOnly: true)
    }
    /// Повторяет последний отправленный запрос, а не текущий черновик.
    func retry() {
        guard let last = lastRequest else { return }
        start(question: last.question, usesDraft: last.usesDraft, selectionOnly: last.selectionOnly, approving: nil)
    }
    private func send(question: String, usesDraft: Bool, selectionOnly: Bool) {
        if !question.isEmpty { lastRequest = (question, usesDraft, selectionOnly) }
        start(question: question, usesDraft: usesDraft, selectionOnly: selectionOnly, approving: nil)
    }

    func sendAnyway() {
        guard let pending, let appState else { return }
        guard AIContextService.isCurrent(pending.sources.map(\.snapshot), appState: appState), selectionIsCurrent(pending.selection) else {
            self.pending = nil
            post(L10n.tr("所选来源已不可用或已更改。"), kind: .info)
            return
        }
        start(question: pending.question, usesDraft: pending.usesDraft, selectionOnly: false, approving: pending)
    }

    private func selectionIsCurrent(_ selection: EditorTextSelectionSnapshot?) -> Bool {
        guard let selection else { return true }
        let extraction = EditorTextExtractionRequest(documentID: selection.documentID, allowsTokenAtCaret: false, allowsWholeDocument: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        return extraction.result?.editorRevision == selection.editorRevision && extraction.result?.range == selection.range
    }

    /// Источник «текущий документ»: выделение, а без него (если разрешено) весь текст; nil — нечего отправлять.
    private func currentSource(_ document: EditorDocument, selectionOnly: Bool) throws -> (source: AIQuestionSource, selection: EditorTextSelectionSnapshot)? {
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: !selectionOnly)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let selection = extraction.result else { return nil }
        let snapshot = document.synchronizedSnapshot()
        let full = snapshot.text as NSString
        var text = snapshot.text
        var range: NSRange?
        if selection.wasExplicitSelection {
            guard selection.range.location != NSNotFound, NSMaxRange(selection.range) <= full.length,
                  full.substring(with: selection.range) == selection.text else { throw AIContextError.unavailable }
            text = selection.text; range = selection.range
        }
        let context = AIContextSnapshot(input: .document(document.id), name: document.displayName, text: text, document: document,
                                        documentRevision: snapshot.revision, fileRevision: nil)
        return (AIQuestionSource(snapshot: context, selectionRange: range), selection)
    }

    private func summary(_ mode: AIQuestionSourceMode, _ sources: [AIQuestionSource]) -> String {
        switch mode {
        case .currentDocument:
            guard let source = sources.first else { return "" }
            return source.selectionRange == nil ? source.snapshot.name : L10n.tr("%@（所选片段）", source.snapshot.name)
        case .openDocuments: return L10n.tr("%lld 个已打开的文档", sources.count)
        case .files: return L10n.tr("%lld 个文件", sources.count)
        }
    }

    private func start(question: String, usesDraft: Bool, selectionOnly: Bool, approving: Pending?) {
        guard let appState, let document = appState.selectedDocument, document.ioState == .idle, isEnabled, !isWorking, !question.isEmpty else { return }
        let profile = appState.preferences.aiProfile(for: .ask)
        guard profile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
        let mode = approving?.mode ?? sourceMode
        var ready = approving?.sources
        var picked = approving?.selection
        var wanted: [AIContextInput] = []
        let key: String?
        var jina: JinaConfiguration?
        var searchKey: String?
        var readerKey: String?
        do {
            switch mode {
            case .currentDocument:
                if ready == nil {
                    guard let current = try currentSource(document, selectionOnly: selectionOnly) else {
                        post(L10n.tr("请先选择需要处理的文本"), kind: .info); return
                    }
                    ready = [current.source]; picked = current.selection
                }
            case .openDocuments:
                // Источники уже собраны в pending: выбор заново не проверяем
                if ready == nil {
                    wanted = AIContextService.availableDocuments(in: appState).map { .document($0.id) }
                    guard !wanted.isEmpty else { post(L10n.tr("请至少添加一个来源。"), kind: .info); return }
                }
            case .files:
                if ready == nil {
                    guard !files.isEmpty else { post(L10n.tr("请至少添加一个来源。"), kind: .info); return }
                    wanted = files.map { .file($0) }
                }
            }
            key = try loadKey(.text, profile.baseURL)
            if isWebSearchAvailable && webSearchEnabled {
                let configuration = appState.preferences.jinaConfiguration
                (searchKey, readerKey) = try AIJinaCredentials.keys(for: configuration, loadKey: loadJinaKey)
                jina = configuration
            }
        } catch { fail(error); return }
        pending = nil; message = ""
        activeDocumentID = document.id; activeProfile = profile; activeKey = key; activeSelection = picked; activeSources = ready ?? []
        activeJina = jina; activeSearchKey = searchKey; activeReaderKey = readerKey
        searchProgress = 0
        isWorking = true
        let current = generation
        let taskGeneration = document.taskCoordinator.begin(.aiQuestion)
        let history = turns, converse = converse, converseWeb = converseWeb, jinaClient = jinaClient
        let prepared = ready, selection = picked, inputs = wanted
        let webJina = jina, webSearchKey = searchKey, webReaderKey = readerKey
        task = Task { [weak self] in
            defer { document.taskCoordinator.finish(.aiQuestion, generation: taskGeneration); if let self, self.generation == current { self.isWorking = false; self.searchProgress = 0 } }
            do {
                let sources: [AIQuestionSource]
                if let prepared { sources = prepared } else {
                    sources = try await AIContextService.capture(inputs, appState: appState).map { AIQuestionSource(snapshot: $0, selectionRange: nil) }
                }
                guard let self, self.generation == current else { return }
                self.activeSources = sources
                guard self.validate(current, document: document, taskGeneration: taskGeneration) else { return }
                let sizes = AIQuestionService.sizeBytes(history: history, question: question, sources: sources)
                let label = self.summary(mode, sources)
                if sizes.total > max(AIRequestSize.threshold, approving?.bytes ?? 0) {
                    self.pending = Pending(question: question, usesDraft: usesDraft, mode: mode, sources: sources, selection: selection, bytes: sizes.total)
                    let detail = sizes.history > 0 ? L10n.tr("%@ + 对话历史 %@", label, AIRequestSize.text(sizes.history)) : label
                    self.post(AIRequestSize.warning(label: detail, bytes: sizes.total), kind: .info, action: .sendAnyway)
                    return
                }
                let messages = AIQuestionService.messages(history: history, question: question, sources: sources)
                let text: String
                var web: AIWebSearchSession?
                if let webJina {
                    let session = AIWebSearchSession(client: jinaClient, configuration: webJina, searchKey: webSearchKey, readerKey: webReaderKey,
                                                     isCurrent: { [weak self] in await self?.isCurrent(current) ?? false },
                                                     onSearch: { [weak self] count in await self?.setSearchProgress(count, generation: current) })
                    web = session
                    text = try await converseWeb(messages, profile, key, session)
                } else {
                    text = try await converse(messages, profile, key)
                }
                guard self.validate(current, document: document, taskGeneration: taskGeneration) else { return }
                let reply = try AIQuestionService.parse(text, sources: sources, web: web?.sources ?? [], readerEnabled: webJina?.readerEnabled == true)
                self.turns.append(AIQuestionTurn(id: UUID(), question: question, answer: reply.answer, citations: reply.citations,
                                                 skippedCitations: reply.skipped, sourceSummary: label, sentBytes: sizes.total,
                                                 webSources: web?.sources ?? [], webCitations: reply.webCitations))
                if usesDraft { self.draft = "" }
                self.refreshStaleness()
                if reply.skipped > 0 { self.post(AIRequestSize.skippedMessage(reply.skipped, allDropped: reply.citations.isEmpty && reply.webCitations.isEmpty), kind: .info) } else { self.message = "" }
            } catch {
                guard let self, self.validate(current, document: document, taskGeneration: taskGeneration) else { return }
                if webJina != nil, case AIError.http(let status, _) = error, [400, 404, 422, 501].contains(status) {
                    self.post(error.localizedDescription + "\n" + L10n.tr("服务器拒绝了带联网搜索的请求。请关闭“在互联网上搜索”后重试（服务器可能不支持函数调用，或上下文不够长）。"),
                              action: AIMessageAction.forError(error))
                } else {
                    self.fail(error)
                }
            }
        }
        if let task { document.taskCoordinator.attachTask(task, kind: .aiQuestion, generation: taskGeneration) }
    }

    private func setSearchProgress(_ count: Int, generation: Int) {
        if self.generation == generation { searchProgress = count }
    }

    func openWebSource(_ source: AIWebSource) {
        guard isEnabled, let scheme = source.url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              turns.contains(where: { $0.webSources.contains(source) }) else { return }
        NSWorkspace.shared.open(source.url)
    }

    private func validate(_ current: Int, document: EditorDocument, taskGeneration: UInt) -> Bool {
        guard !Task.isCancelled, isCurrent(current), document.taskCoordinator.isCurrent(taskGeneration, for: .aiQuestion) else {
            if generation == current { cancel(); post(L10n.tr("所选来源已不可用或已更改。"), kind: .info) }
            return false
        }
        return true
    }

    private func isCurrent(_ current: Int) -> Bool {
        guard generation == current, let appState, let profile = activeProfile,
              appState.selectedDocumentID == activeDocumentID, appState.selectedDocument?.ioState == .idle,
              appState.preferences.aiFeatures.contains(.ask), appState.preferences.aiProfile(for: .ask) == profile,
              AIContextService.isCurrent(activeSources.map(\.snapshot), appState: appState),
              selectionIsCurrent(activeSelection),
              AIJinaCredentials.isCurrent(activeJina, searchKey: activeSearchKey, readerKey: activeReaderKey,
                                          preferences: appState.preferences, loadKey: loadJinaKey) else { return false }
        do { return try loadKey(.text, profile.baseURL) == activeKey } catch { return false }
    }

    func newConversation() {
        cancel()
        turns = []; staleCitationIDs = []; message = ""; lastRequest = nil
    }

    /// Остановка по кнопке: история и ввод остаются.
    func stop() { cancel() }
    func hidden() { cancel() }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        isWorking = false
        activeDocumentID = nil; activeProfile = nil; activeKey = nil; activeSelection = nil; activeSources = []
        activeJina = nil; activeSearchKey = nil; activeReaderKey = nil; searchProgress = 0
        if pending != nil { pending = nil; message = "" }
    }

    func invalidate(documentID: UUID) {
        if activeDocumentID == documentID || activeSources.contains(where: { $0.snapshot.document?.id == documentID }) { cancel() }
        refreshStaleness()
    }

    func selectedDocumentChanged() {
        cancel(); message = ""
        refreshStaleness()
    }

    func settingsChanged() {
        if !isEnabled {
            if !turns.isEmpty || isWorking || pending != nil { newConversation() }
        } else if activeProfile != nil && !isCurrent(generation) { cancel() }
        objectWillChange.send()
    }

    func refreshStaleness() {
        guard let appState else { return }
        let stale = Set(turns.flatMap(\.citations).filter { !AIContextService.isCurrent([$0.stamp], appState: appState) }.map(\.id))
        if stale != staleCitationIDs { staleCitationIDs = stale }
    }

    /// При вводе: только цитаты документа из уведомления, по версии, без проверок файлов.
    private func markStale(documentID: UUID) {
        let stale = turns.flatMap(\.citations).filter { citation in
            guard let document = citation.stamp.document, document.id == documentID else { return false }
            return document.textRevision != citation.stamp.documentRevision || document.hasPendingLiveEdits
        }.map(\.id)
        let merged = staleCitationIDs.union(stale)
        if merged != staleCitationIDs { staleCitationIDs = merged }
    }

    func openCitation(_ citation: AIQuestionCitation) {
        guard isEnabled, let appState, turns.contains(where: { $0.citations.contains { $0.id == citation.id } }) else { return }
        refreshStaleness()
        guard !staleCitationIDs.contains(citation.id) else { post(L10n.tr("来源已更改，无法定位。"), kind: .info); return }
        if let document = citation.stamp.document, document === appState.selectedDocument {
            NotificationCenter.default.post(name: EditorCommandNotification.revealSelection, object: EditorSelectionRequest(documentID: document.id, range: citation.range))
        } else {
            AIContextService.reveal(citation.stamp, range: citation.range, appState: appState)
        }
    }
}
