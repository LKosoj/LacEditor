import Combine
import Foundation

/// Состояние поиска в боковой панели хранилища: запрос, режим, результаты и ожидание ответа сервера.
/// Зависимости — замыкания, чтобы логика проверялась без сети и без окна.
@MainActor
final class VaultSearchController: ObservableObject {
    /// Пауза после последней буквы, прежде чем запрос уходит на сервер.
    static let debounce = Duration.milliseconds(400)

    @Published var query = "" { didSet { if query != oldValue { inputChanged(clearsResults: false) } } }
    @Published var mode: VaultSearchMode = .server { didSet { if mode != oldValue { inputChanged(clearsResults: true) } } }
    @Published private(set) var phase: VaultSearchPhase = .idle
    @Published private(set) var results: [VaultSearchResult] = []
    /// Сервер показал максимум (20) или список имён усечён: внизу появляется подпись.
    @Published private(set) var isLimited = false
    /// «Имена»: каталог загружен не полностью, результаты по тому, что уже есть.
    @Published private(set) var namesListIsPartial = false
    /// Растёт при ⌘⇧F: поле в панели берёт фокус.
    @Published private(set) var focusRequest = 0
    /// Открыта ли панель быстрого открытия (⌘⇧O в хранилище).
    @Published private(set) var isQuickOpenPresented = false
    /// Растёт при повторном ⌘⇧O: поле быстрого открытия берёт фокус.
    @Published private(set) var quickOpenFocusRequest = 0

    /// Не пустой запрос после нормализации: только тогда панель показывает результаты вместо разделов.
    var isActive: Bool { !VaultSearchSupport.normalizedQuery(query).isEmpty }

    /// Поиск сервера по нормализованному запросу.
    private let search: (String) async throws -> [VaultSearchHit]
    private let namePaths: () -> [String]
    private let isNameListComplete: () -> Bool
    private let hiddenRoots: () -> Set<String>
    private let isOnline: () -> Bool
    private let sleep: (Duration) async throws -> Void
    private let open: (VaultSearchResult, Bool, String) -> Void
    private let announce: (String) -> Void

    private var generation: UInt = 0
    private var task: Task<Void, Never>?
    /// Объявление числа найденных имён: только после паузы в наборе, а не на каждую букву.
    private var announceTask: Task<Void, Never>?
    /// Запрос, для которого сейчас показаны результаты: Return по нему открывает первый результат.
    private var shownQuery: String?
    /// После «Нет связи» один повтор, когда связь вернулась.
    private var retriesWhenOnline = false
    private var hasPendingFocus = false
    /// ⌘⇧F выделяет текст в поле, возврат по Esc из списка оставляет курсор как был.
    private(set) var selectsTextOnFocus = true
    /// Переход к фрагменту после открытия заметки (ставит `AppState`); новый поиск и выход его отменяют.
    var revealTask: Task<Void, Never>?
    /// Кому принадлежит контроллер: при смене сессии `AppState` создаёт новый.
    var ownerID: ObjectIdentifier?

    /// Для тестов: ждать окончания текущей работы.
    var currentTask: Task<Void, Never>? { task }

    init(search: @escaping (String) async throws -> [VaultSearchHit],
         namePaths: @escaping () -> [String],
         isNameListComplete: @escaping () -> Bool = { true },
         hiddenRoots: @escaping () -> Set<String> = { [] },
         isOnline: @escaping () -> Bool = { true },
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         open: @escaping (VaultSearchResult, Bool, String) -> Void,
         announce: @escaping (String) -> Void = { _ in }) {
        self.search = search
        self.namePaths = namePaths
        self.isNameListComplete = isNameListComplete
        self.hiddenRoots = hiddenRoots
        self.isOnline = isOnline
        self.sleep = sleep
        self.open = open
        self.announce = announce
    }

    // MARK: Действия

    /// Return в поле: результаты этого запроса уже показаны — открыть первый, иначе искать без ожидания.
    func submit() {
        let normalized = VaultSearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else { return }
        if phase == .results, shownQuery == normalized, let first = results.first {
            select(first, newTab: false)
            return
        }
        start(normalized, delay: false)
    }

    /// «Повторить»: тот же запрос сразу.
    func retry() {
        let normalized = VaultSearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else { return }
        start(normalized, delay: false)
    }

    /// Крестик и Esc: поле пустеет, панель возвращается к разделам.
    func clear() { query = "" }

    /// Выход из хранилища, смена хранилища, закрытие окна: всё отменяется, запрос забывается.
    func cancel() {
        invalidate()
        revealTask?.cancel()
        revealTask = nil
        shownQuery = nil
        // Присваиваются только изменившиеся значения: вызов из обновления вида не должен рассылать лишних уведомлений.
        if !results.isEmpty { results = [] }
        if phase != .idle { phase = .idle }
        if isLimited { isLimited = false }
        if isQuickOpenPresented { isQuickOpenPresented = false }
        if !query.isEmpty { query = "" }
    }

    func select(_ result: VaultSearchResult, newTab: Bool) {
        select(result, newTab: newTab, query: VaultSearchSupport.normalizedQuery(query))
    }

    /// `query` — слова для выделения в заметке (у быстрого открытия свой запрос, не из панели).
    func select(_ result: VaultSearchResult, newTab: Bool, query: String) {
        open(result, newTab, query)
    }

    /// «Искать по именам»: текст остаётся, результаты появляются сразу.
    func switchToNames() { mode = .names }

    /// ⌘⇧F: поле берёт фокус сразу или, если панель была скрыта, при появлении (`consumeFocusRequest`).
    func requestFocus(selectingText: Bool = true) {
        hasPendingFocus = true
        selectsTextOnFocus = selectingText
        focusRequest += 1
    }

    func consumeFocusRequest() -> Bool {
        defer { hasPendingFocus = false }
        return hasPendingFocus
    }

    /// Повторный вызов при открытой панели оставляет её открытой и возвращает фокус в поле (как у обычного быстрого открытия).
    func presentQuickOpen() {
        if isQuickOpenPresented { quickOpenFocusRequest += 1 }
        isQuickOpenPresented = true
    }
    func dismissQuickOpen() { isQuickOpenPresented = false }

    /// Статус сессии «в сети» изменился: после «Нет связи» поиск повторяется один раз сам.
    func connectivityChanged(isOnline online: Bool) {
        guard online, retriesWhenOnline, phase == .offline, mode == .server else { return }
        retriesWhenOnline = false
        retry()
    }

    /// Каталог дозагрузился: имена пересчитываются по полному списку.
    func refreshNames() {
        guard mode == .names, isActive else { return }
        inputChanged(clearsResults: false)
    }

    /// Пути и полнота каталога для быстрого открытия.
    func catalogPaths() -> [String] { namePaths() }
    var isCatalogComplete: Bool { isNameListComplete() }

    // MARK: Запуск

    private func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        announceTask?.cancel()
        announceTask = nil
    }

    private func inputChanged(clearsResults: Bool) {
        invalidate()
        retriesWhenOnline = false
        if clearsResults {
            results = []
            isLimited = false
            shownQuery = nil
        }
        let normalized = VaultSearchSupport.normalizedQuery(query)
        guard !normalized.isEmpty else {
            results = []
            isLimited = false
            shownQuery = nil
            phase = .idle
            return
        }
        switch mode {
        case .names: startNames(normalized)
        case .server:
            phase = .waiting
            start(normalized, delay: true)
        }
    }

    /// Запрос к серверу; `delay` — подождать конец ввода.
    private func start(_ normalized: String, delay: Bool) {
        invalidate()
        guard mode == .server else { return startNames(normalized) }
        let generation = self.generation
        retriesWhenOnline = false
        if !delay { phase = .loading }
        task = Task { [weak self] in
            guard let self else { return }
            if delay {
                do { try await self.sleep(Self.debounce) } catch { return }
                guard self.isCurrent(generation, normalized) else { return }
            }
            guard self.isOnline() else {
                self.finish(.offline, generation: generation, query: normalized)
                return
            }
            self.phase = .loading
            do {
                let hits = try await self.search(normalized)
                guard self.isCurrent(generation, normalized) else { return }
                let found = VaultSearchSupport.results(from: hits, hidden: self.hiddenRoots())
                self.results = found
                self.isLimited = hits.count >= VaultSearchSupport.serverLimit
                self.shownQuery = normalized
                self.phase = found.isEmpty ? .empty : .results
                self.announce(found.isEmpty ? L10n.tr("没有匹配结果") : L10n.tr("结果：%lld", found.count))
            } catch {
                guard self.isCurrent(generation, normalized) else { return }
                // Отмена внутри запроса (например, сессия закрыта) не ошибка: индикатор не должен висеть вечно.
                guard let failed = VaultSearchSupport.phase(for: error) else { self.phase = .idle; return }
                self.finish(failed, generation: generation, query: normalized)
            }
        }
    }

    /// Ошибка или «Нет связи»: прежние результаты убираются, чтобы не выдавать их за ответ на этот запрос.
    private func finish(_ failed: VaultSearchPhase, generation: UInt, query: String) {
        guard isCurrent(generation, query) else { return }
        results = []
        isLimited = false
        shownQuery = nil
        phase = failed
        retriesWhenOnline = failed == .offline
        switch failed {
        case .unavailable: announce(L10n.tr("服务器搜索不可用"))
        case .offline: announce(L10n.tr("与服务器没有连接"))
        case .failed(let message): announce(message)
        default: break
        }
    }

    private func startNames(_ normalized: String) {
        invalidate()
        let generation = self.generation
        let paths = namePaths()
        namesListIsPartial = !isNameListComplete()
        phase = .waiting
        let worker = Task.detached(priority: .userInitiated) {
            try? VaultSearchSupport.rankNames(query: normalized, paths: paths, isCancelled: { Task.isCancelled })
        }
        task = Task { [weak self] in
            let ranked = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, self.isCurrent(generation, normalized), let ranked else { return }
            self.results = ranked.results
            self.isLimited = ranked.total > ranked.results.count
            self.shownQuery = normalized
            self.phase = ranked.results.isEmpty ? .empty : .results
            let message = ranked.results.isEmpty ? L10n.tr("没有匹配结果") : L10n.tr("结果：%lld", ranked.results.count)
            self.announceTask = Task { [weak self] in
                guard let self else { return }
                do { try await self.sleep(Self.debounce) } catch { return }
                guard self.isCurrent(generation, normalized) else { return }
                self.announce(message)
            }
        }
    }

    /// Ответ принимается, только если запрос и режим не менялись за время ожидания.
    private func isCurrent(_ generation: UInt, _ normalized: String) -> Bool {
        self.generation == generation && !Task.isCancelled && VaultSearchSupport.normalizedQuery(query) == normalized
    }
}
