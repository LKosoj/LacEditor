import Combine
import Foundation

/// Запросы AI для карточек мира. Результаты — предложения с галочками: без подтверждения ничего не записывается.
@MainActor
final class StoryCardAIController: ObservableObject {
    enum Mode { case candidates, facts, relations }

    private struct Job {
        let mode: Mode
        let document: EditorDocument
        let snapshot: DocumentTextSnapshot
        let subject: StoryCard?
        let known: [StoryCard]
        /// Текст сцен вместо текста самого документа (факты и связи берутся из сцен, где карточка упомянута).
        var sourceText: String?
        var text: String { sourceText ?? snapshot.text }
    }

    @Published private(set) var isRunning = false
    /// Документ, для которого получены сообщение и результаты: другим документам они не показываются.
    @Published private(set) var documentID: UUID?
    /// Последний запущенный режим (для «Повторить»).
    private(set) var lastMode: Mode?
    @Published private(set) var message = ""
    @Published private(set) var messageKind: StatusKind = .info
    @Published private(set) var messageAction: AIMessageAction?
    @Published var candidates: [StoryCardCandidate] = []
    @Published var facts: [StoryCardFactProposal] = []
    @Published var relations: [StoryCardRelationProposal] = []
    /// Размер запроса, ожидающего подтверждения «Всё равно отправить».
    @Published private(set) var pendingBytes: Int?

    private weak var appState: AppState?
    private var pendingJob: Job?
    private var lastJob: Job?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var taskGeneration: UInt = 0

    init(appState: AppState? = nil) { self.appState = appState }

    deinit { task?.cancel() }

    func attach(_ appState: AppState) { self.appState = appState }

    private func post(_ text: String, _ kind: StatusKind = .error, action: AIMessageAction? = nil) {
        message = text
        messageKind = kind
        messageAction = action
    }

    func clear() {
        cancel()
        documentID = nil
        message = ""
        messageAction = nil
        candidates = []
        facts = []
        relations = []
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        if let document = pendingJob?.document ?? appState?.selectedDocument {
            document.taskCoordinator.cancel(.worldCards)
        }
        pendingJob = nil
        pendingBytes = nil
        isRunning = false
    }

    /// Повторяет последний запрос с теми же входами; `nil`, если повторять нечего.
    func retry() {
        guard let job = lastJob else { return }
        start(job, approved: false)
    }

    // MARK: Запуск

    func findCandidates(document: EditorDocument, known: [StoryCard]) {
        start(Job(mode: .candidates, document: document, snapshot: document.synchronizedSnapshot(), subject: nil, known: known), approved: false)
    }

    func suggestFacts(for card: StoryCard, document: EditorDocument, sourceText: String) {
        start(Job(mode: .facts, document: document, snapshot: document.synchronizedSnapshot(), subject: card, known: [], sourceText: sourceText), approved: false)
    }

    func suggestRelations(for card: StoryCard, document: EditorDocument, known: [StoryCard], sourceText: String) {
        start(Job(mode: .relations, document: document, snapshot: document.synchronizedSnapshot(), subject: card, known: known, sourceText: sourceText), approved: false)
    }

    func sendAnyway() {
        guard let job = pendingJob else { return }
        start(job, approved: true)
    }

    private func instructions(_ job: Job) -> String {
        let code = TextSegmentation.languageCode(for: TextSegmentation.language(of: job.text))
        switch job.mode {
        case .candidates: return StoryCardAIService.candidatesInstructions(languageCode: code)
        case .facts: return StoryCardAIService.factsInstructions(languageCode: code)
        case .relations: return StoryCardAIService.relationsInstructions(languageCode: code)
        }
    }

    private func input(_ job: Job) -> String {
        switch job.mode {
        case .candidates: return StoryCardAIService.candidatesInput(text: job.text, known: job.known)
        case .facts: return StoryCardAIService.factsInput(subject: job.subject!, text: job.text)
        case .relations: return StoryCardAIService.relationsInput(subject: job.subject!, known: job.known, text: job.text)
        }
    }

    private func start(_ job: Job, approved: Bool) {
        guard let appState, job.document.ioState == .idle else { return }
        if documentID != job.document.id { candidates = []; facts = []; relations = [] }
        documentID = job.document.id
        lastMode = job.mode
        lastJob = job
        // Карточка с `ai: exclude` не уходит в модель: ни как предмет запроса, ни как текст, из которого ищут кандидатов.
        if isExcluded(job) {
            post(L10n.tr("此卡片不会发送给 AI"), .info)
            return
        }
        guard appState.aiAvailability(for: .worldCards) == .available else {
            post(L10n.tr("AI 功能已关闭"), .info, action: .openSettings)
            return
        }
        let profile = appState.preferences.aiProfile(for: .worldCards)
        let key: String?
        do { key = try AIKeychainStore().load(for: AIFeature.worldCards.role, baseURL: profile.baseURL) } catch {
            post(error.localizedDescription, action: AIMessageAction.forError(error))
            return
        }
        let instructions = instructions(job)
        let input = input(job)
        let bytes = AIRequestSize.bytes(instructions, input)
        if !approved, bytes > AIRequestSize.threshold {
            pendingJob = job
            pendingBytes = bytes
            post(AIRequestSize.warning(label: L10n.tr("整个文档"), bytes: bytes), .info, action: .sendAnyway)
            return
        }
        pendingJob = nil
        pendingBytes = nil
        message = ""
        messageAction = nil
        generation &+= 1
        let current = generation
        task?.cancel()
        isRunning = true
        let taskGeneration = job.document.taskCoordinator.begin(.worldCards)
        self.taskGeneration = taskGeneration
        let task = Task { [weak self, weak document = job.document] in
            defer {
                document?.taskCoordinator.finish(.worldCards, generation: taskGeneration)
                if let self, self.generation == current { self.isRunning = false }
            }
            do {
                let response = try await StoryCardAIService.send(input: input, instructions: instructions, profile: profile, key: key)
                guard let self, self.isCurrent(current, job: job, taskGeneration: taskGeneration, profile: profile, key: key) else { return }
                self.apply(response, job: job)
            } catch {
                guard let self, self.isCurrent(current, job: job, taskGeneration: taskGeneration, profile: profile, key: key) else { return }
                self.post(error.localizedDescription, action: AIMessageAction.forError(error))
            }
        }
        self.task = task
        job.document.taskCoordinator.attachTask(task, kind: .worldCards, generation: taskGeneration)
    }

    /// Документ, функция, профиль и ключ те же, что при запуске. Иначе результат выбрасывается без сообщения.
    private func isCurrent(_ generation: Int, job: Job, taskGeneration: UInt, profile: AIModelProfile, key: String?) -> Bool {
        guard !Task.isCancelled, self.generation == generation, let appState,
              appState.selectedDocument === job.document,
              job.document.taskCoordinator.isCurrent(taskGeneration, for: .worldCards),
              appState.preferences.aiFeatures.contains(.worldCards),
              appState.preferences.aiProfile(for: .worldCards) == profile,
              (try? AIKeychainStore().load(for: AIFeature.worldCards.role, baseURL: profile.baseURL)) == key else { return false }
        return true
    }

    private func isExcluded(_ job: Job) -> Bool {
        if job.subject?.excludedFromAI == true { return true }
        guard job.mode == .candidates, let session = appState?.writerSession, let url = job.document.url else { return false }
        if session.world.catalog.card(forURL: url)?.excludedFromAI == true { return true }
        return StoryCardHeader.parse(job.snapshot.text, url: url, root: session.rootURL)?.excludedFromAI == true
    }

    private func apply(_ response: String, job: Job) {
        // Текст изменился за время запроса: цитаты больше не сверить.
        guard job.document.textRevision == job.snapshot.revision, !job.document.hasPendingLiveEdits else {
            post(L10n.tr("文本已变化"), .info)
            return
        }
        do {
            let skipped: Int
            let count: Int
            switch job.mode {
            case .candidates:
                let parsed = try StoryCardAIService.parseCandidates(response: response, text: job.text, known: job.known)
                candidates = parsed.items; skipped = parsed.skipped; count = parsed.items.count
            case .facts:
                let parsed = try StoryCardAIService.parseFacts(response: response, text: job.text)
                facts = parsed.items; skipped = parsed.skipped; count = parsed.items.count
            case .relations:
                let parsed = try StoryCardAIService.parseRelations(response: response, text: job.text, subject: job.subject!, known: job.known)
                relations = parsed.items; skipped = parsed.skipped; count = parsed.items.count
            }
            if skipped > 0 {
                post(AIRequestSize.skippedMessage(skipped, allDropped: count == 0), .info)
            } else if count == 0 {
                post(L10n.tr("没有可补充的内容"), .info)
            }
        } catch {
            post(error.localizedDescription, action: AIMessageAction.forError(error))
        }
    }
}
