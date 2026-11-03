import Combine
import Foundation

/// Данные правой панели заметки хранилища: шапка, исходящие ссылки, состояние синхронизации.
/// Тяжёлое (разбор шапки, ссылки) считается не на каждую букву: по паузе ввода и по номеру поколения, поздний результат отбрасывается.
@MainActor
final class VaultInspectorModel: ObservableObject {
    @Published private(set) var frontmatter: VaultFrontmatterParseResult = .none
    @Published private(set) var links: [VaultOutgoingLink] = []
    @Published private(set) var info: VaultNoteInfo?
    /// Похожие заметки по цели ссылки (id ссылки → пути); только показ.
    @Published private(set) var similar: [String: [String]] = [:]
    @Published private(set) var isListingLoading = false
    /// Шапка уже разобрана хотя бы раз (до этого форма показывает загрузку, а не «нет свойств»).
    @Published private(set) var isParsed = false
    /// Документ слишком большой для разбора ссылок (`isLargeFileMode`).
    @Published private(set) var isLinksTooLarge = false

    private(set) var documentID: UUID?
    private var document: EditorDocument?
    private var session: VaultSession?
    private var serverPath: String?
    var updates: VaultServerUpdateMemory?
    private var linksGeneration = 0
    private var linksTask: Task<Void, Never>?
    /// Резолвер ссылок по каталогу: собирается заново только при изменении каталога, а не на каждую паузу ввода.
    private var resolver: MarkdownWikiLinkResolver?
    private var resolverToken: UInt = 0
    /// Поколение каталога: резолвер, собранный для прежнего каталога, не принимается.
    private var catalogGeneration = 0
    private var generation = 0
    private var bindings = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    private var infoTask: Task<Void, Never>?
    private var similarTask: Task<Void, Never>?

    /// Привязка к вкладке; повторный вызов с теми же объектами ничего не делает.
    func bind(document: EditorDocument?, session: VaultSession?, serverPath: String?) {
        if self.document === document, self.session === session, self.serverPath == serverPath { return }
        bindings.removeAll()
        reloadTask?.cancel()
        infoTask?.cancel()
        similarTask?.cancel()
        linksTask?.cancel()
        resolver = nil
        isParsed = false
        isLinksTooLarge = false
        generation += 1
        linksGeneration += 1
        self.document = document
        self.session = session
        self.serverPath = serverPath
        documentID = document?.id
        frontmatter = .none
        links = []
        similar = [:]
        info = nil
        guard let document else { return }
        document.textEdits
            .debounce(for: .seconds(EditorDocument.typingPause), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &bindings)
        document.$vaultPageMode.dropFirst().sink { [weak self] _ in self?.reload() }.store(in: &bindings)
        if let session {
            // `@Published` сообщает до записи значения: обработчики идут через очередь главного потока и читают уже новое.
            let main = DispatchQueue.main
            session.$noteStates.dropFirst().receive(on: main).sink { [weak self] _ in self?.reloadInfo() }.store(in: &bindings)
            session.$isOnline.dropFirst().receive(on: main).sink { [weak self] _ in self?.reloadInfo() }.store(in: &bindings)
            session.$lastSyncDate.dropFirst().receive(on: main).sink { [weak self] _ in self?.reloadInfo() }.store(in: &bindings)
            session.catalog.$allFiles.dropFirst().receive(on: main).sink { [weak self] _ in self?.catalogChanged() }.store(in: &bindings)
            session.catalog.$isFullListingLoaded.dropFirst().receive(on: main).sink { [weak self] _ in self?.catalogChanged() }.store(in: &bindings)
        }
        reload()
    }

    /// Шапку читает форма сразу после своей правки: «пауза ввода» её не ждёт.
    func reload() {
        reloadFrontmatter()
        reloadLinks()
        reloadInfo()
    }

    func reloadFrontmatter() {
        guard let document else { return }
        let text = document.synchronizedText()
        generation += 1
        let mine = generation
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { VaultFrontmatterEditor.parse(text) }.value
            guard let self, !Task.isCancelled, mine == self.generation else { return }
            if self.frontmatter != result { self.frontmatter = result }
            self.isParsed = true
        }
    }

    private func catalogChanged() {
        catalogGeneration += 1
        resolver = nil
        reloadLinks()
    }

    func reloadLinks() {
        guard let document, let session else { return }
        linksTask?.cancel()
        guard !document.isLargeFileMode else {
            isLinksTooLarge = true
            if !links.isEmpty { links = [] }
            return
        }
        isLinksTooLarge = false
        let text = document.synchronizedText()
        let complete = session.catalog.isFullListingLoaded
        isListingLoading = !complete
        let cached = resolver
        // Пути берутся здесь (массив не копируется), а индекс резолвера строится в фоне: в хранилище десятки тысяч путей.
        let paths = cached == nil ? session.catalog.wikiLinkPaths() : []
        resolverToken &+= 1
        let token = resolverToken
        let catalogMine = catalogGeneration
        linksGeneration += 1
        let mine = linksGeneration
        linksTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> (MarkdownWikiLinkResolver, [VaultOutgoingLink]) in
                let current = cached ?? VaultLinks.resolver(paths: paths, token: token)
                if Task.isCancelled { return (current, []) }
                let found = VaultLinks.outgoing(in: text, resolver: current, isCatalogComplete: complete, isCancelled: { Task.isCancelled })
                return (current, found)
            }
            // Отмена родителя не доходит до detached-задачи сама.
            let (built, found) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, mine == self.linksGeneration else { return }
            if catalogMine == self.catalogGeneration { self.resolver = built }
            if self.links != found { self.links = found }
        }
    }

    func reloadInfo() {
        guard let session, let path = serverPath else { return }
        infoTask?.cancel()
        let state = session.noteStates[path] ?? .synced
        let online = session.isOnline
        let last = session.lastSyncDate
        let memory = updates?.entry(for: path)?.date
        infoTask = Task { [weak self] in
            let summary = await session.engine.noteSummary(serverPath: path)
            guard let self, !Task.isCancelled else { return }
            var compare: VaultNoteInfo.Compare?
            if summary.hasHeld { compare = .heldServerVersion } else if let memory { compare = .beforeLastServerUpdate(memory) }
            let modified = summary.record?.baseModifiedNs.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) }
            let next = VaultNoteInfo(state: state, isOnline: online, lastCheck: last, serverModified: modified, compareSource: compare)
            if self.info != next { self.info = next }
        }
    }

    /// Показывает до пяти похожих заметок для ссылки, которой нет.
    func findSimilar(for link: VaultOutgoingLink) {
        guard let session else { return }
        similarTask?.cancel()
        let paths = session.catalog.wikiLinkPaths()
        let target = link.target
        let id = link.id
        similarTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                VaultLinks.similar(to: target, in: paths, isCancelled: { Task.isCancelled })
            }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.similar[id] = found
        }
    }
}
