import AppKit
import Combine
import Foundation
import SwiftUI

/// Панель «Стиль»: локальные правила после паузы набора и AI-проверка по кнопке.
/// Все диапазоны находок — UTF-16 в координатах исходника (`EditorTextSpace.source`).
@MainActor
final class StyleCheckController: ObservableObject {
    enum Availability: Equatable { case ready, noDocument, unsupportedType, largeFile }

    struct Suggestion: Equatable {
        let findingID: UUID
        /// Текст, который заменяется в документе.
        let original: String
        let replacement: String
        /// То, что показывает блок «было/стало» (для пробелов — вместе с соседним знаком).
        let shownBefore: String
        let shownAfter: String
        let explanation: String
        /// Ожидаемое место `original` (координаты исходника).
        let expected: NSRange
        /// Номер строки документа (с 1).
        let line: Int
    }

    private struct PendingSend { let selection: EditorTextSelectionSnapshot; let bytes: Int }
    private enum LastOperation { case review, suggest }

    // Состояние для панели
    @Published private(set) var availability: Availability = .noDocument
    @Published private(set) var findings: [StyleFinding] = []
    @Published private(set) var detectedLanguage: TextLanguage?
    @Published private(set) var isChecking = false
    @Published private(set) var isReviewing = false
    @Published private(set) var isSuggesting = false
    @Published private(set) var isStale = false
    @Published var selectedID: UUID?
    @Published private(set) var suggestion: Suggestion?
    @Published private(set) var message = ""
    @Published private(set) var messageKind: StatusKind = .info
    @Published private(set) var messageAction: AIMessageAction?
    @Published private(set) var hasChecked = false
    @Published private(set) var lineNumbers: [UUID: Int] = [:]

    private weak var appState: AppState?
    private let loadKey: (AIRole, String) throws -> String?
    private let review: (String, String?, [StyleFinding], String, AIModelProfile, String?) async throws -> String
    private let suggest: (String, String, AIModelProfile, String?) async throws -> AIWritingResult
    private let announce: (String) -> Void

    private var localGeneration = 0
    private var reviewGeneration = 0
    private var suggestGeneration = 0
    private var localTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    private var localFindings: [StyleFinding] = []
    private var aiFindings: [StyleFinding] = []
    private var skippedIDs = Set<UUID>()
    private var lastResult: StyleCheckResult?
    /// Текст, по которому построены диапазоны локальных замечаний (нужен для замены пробелов).
    private var localSourceText = ""
    private var subscriptions: [AnyCancellable] = []
    private var activeDocumentID: UUID?
    private var isPanelVisible = false
    private var pendingSend: PendingSend?
    private var lastOperation = LastOperation.review
    /// Идёт применение своей правки (принятие): `textEdits` приходит синхронно, это не печатание.
    private var ownEditPending = false
    /// Последняя правка — своя: результат сдвинут, а не устарел. Любая новая правка пользователя сбрасывает.
    private var lastEditWasOwn = false
    private var settingsRecheck: Task<Void, Never>?
    private var settingsRecheckPending = false

    init(appState: AppState? = nil,
         loadKey: @escaping (AIRole, String) throws -> String? = { try AIKeychainStore().load(for: $0, baseURL: $1) },
         review: @escaping (String, String?, [StyleFinding], String, AIModelProfile, String?) async throws -> String = {
             try await StyleReviewService.review(text: $0, languageCode: $1, known: $2, goal: $3, profile: $4, key: $5)
         },
         suggest: @escaping (String, String, AIModelProfile, String?) async throws -> AIWritingResult = {
             try await AIWritingService.generate(feature: .clarity, input: $0, option: $1, profile: $2, key: $3)
         },
         announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() }) {
        self.appState = appState
        self.loadKey = loadKey
        self.review = review
        self.suggest = suggest
        self.announce = announce
    }

    deinit {
        localTask?.cancel()
        reviewTask?.cancel()
        suggestTask?.cancel()
    }

    // MARK: Настройки и списки

    var settings: StyleCheckSettings {
        get { appState?.preferences.styleCheck ?? .default }
        set {
            let old = appState?.preferences.styleCheck
            let next = newValue.clamped()
            appState?.preferences.styleCheck = next
            objectWillChange.send()
            // Окна, пороги и списки меняют сами находки: нужна новая проверка (или пометка «устарело»).
            guard let old, old.windowWords != next.windowWords || old.windowChars != next.windowChars
                    || old.longSentenceWords != next.longSentenceWords || old.longSentenceChars != next.longSentenceChars
                    || old.customWords != next.customWords || old.customStopWords != next.customStopWords,
                  availability == .ready, hasChecked else { return }
            // Короткий дебаунс: списки слов меняются на каждый символ.
            settingsRecheck?.cancel()
            settingsRecheckPending = true
            settingsRecheck = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.availability == .ready else { return }
                self.settingsRecheckPending = false
                if self.settings.autoCheck { self.runLocal(userInitiated: false) } else {
                    self.isStale = true
                    self.clearMarks(documentID: self.activeDocumentID)
                }
            }
        }
    }

    /// Для списка: порядок категорий как в `StyleCategory.allCases`, пустые не включаются.
    var groups: [(category: StyleCategory, findings: [StyleFinding])] {
        StyleCategory.allCases.compactMap { category -> (category: StyleCategory, findings: [StyleFinding])? in
            let items = findings.filter { $0.category == category }
            return items.isEmpty ? nil : (category: category, findings: items)
        }
    }

    var selectedFinding: StyleFinding? { findings.first { $0.id == selectedID } }

    private func post(_ text: String, _ kind: StatusKind = .error, action: AIMessageAction? = nil) {
        message = text
        messageKind = kind
        messageAction = action
    }

    private func fail(_ error: Error) { post(error.localizedDescription, action: AIMessageAction.forError(error)) }

    private func clearMessage() {
        if !message.isEmpty { message = "" }
        messageAction = nil
    }

    // MARK: Жизненный цикл

    func panelAppeared() {
        isPanelVisible = true
        attach()
        refreshAvailability()
        guard availability == .ready, let document = appState?.selectedDocument else { return }
        if let result = lastResult, result.documentID != document.id || result.revision != document.textRevision || document.hasPendingLiveEdits {
            isStale = true
        }
        if settings.autoCheck, !hasChecked || isStale { runLocal(userInitiated: false) } else if !isStale { publishMarks() }
    }

    func panelDisappeared() {
        isPanelVisible = false
        cancelWork()
        subscriptions = []
        publishMarks()
    }

    func selectedDocumentChanged() {
        clearMarks(documentID: activeDocumentID)
        cancelWork()
        resetResults()
        subscriptions = []
        activeDocumentID = nil
        guard isPanelVisible else { return }
        attach()
        refreshAvailability()
        if availability == .ready, settings.autoCheck { runLocal(userInitiated: false) }
    }

    func invalidate(documentID: UUID) {
        guard activeDocumentID == documentID || lastResult?.documentID == documentID else { return }
        clearMarks(documentID: documentID)
        cancelWork()
        resetResults()
        subscriptions = []
        activeDocumentID = nil
    }

    func windowClosed() {
        clearMarks(documentID: activeDocumentID)
        isPanelVisible = false
        cancelWork()
        resetResults()
        subscriptions = []
        activeDocumentID = nil
    }

    private func cancelWork() {
        // Отложенная проверка не успела: без пометки «устарело» панель при возврате показала бы старый результат как свежий.
        if settingsRecheckPending, hasChecked { isStale = true }
        settingsRecheckPending = false
        settingsRecheck?.cancel(); settingsRecheck = nil
        localGeneration &+= 1
        reviewGeneration &+= 1
        suggestGeneration &+= 1
        localTask?.cancel(); localTask = nil
        reviewTask?.cancel(); reviewTask = nil
        suggestTask?.cancel(); suggestTask = nil
        if let document = appState?.documents.first(where: { $0.id == activeDocumentID }) {
            document.taskCoordinator.cancel(.styleCheck)
            document.taskCoordinator.cancel(.styleReview)
        }
        isChecking = false
        isReviewing = false
        isSuggesting = false
        pendingSend = nil
    }

    private func resetResults() {
        localFindings = []
        aiFindings = []
        skippedIDs = []
        lastResult = nil
        localSourceText = ""
        lineNumbers = [:]
        detectedLanguage = nil
        hasChecked = false
        isStale = false
        suggestion = nil
        selectedID = nil
        message = ""
        messageAction = nil
        rebuildVisible()
    }

    /// Подписка на правки выбранного документа и на смену его типа и профиля.
    private func attach() {
        subscriptions = []
        guard let document = appState?.selectedDocument else { activeDocumentID = nil; return }
        activeDocumentID = document.id
        subscriptions = [
            // Первая правка серии сразу помечает результат устаревшим и снимает подчёркивания.
            document.textEdits.sink { [weak self] in self?.documentTyped() },
            document.textEdits.debounce(for: .seconds(EditorDocument.typingPause), scheduler: DispatchQueue.main)
                .sink { [weak self] in self?.documentEdited() },
            document.$language.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.typeChanged() },
            document.$performanceProfile.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.typeChanged() }
        ]
    }

    private func typeChanged() {
        refreshAvailability()
        if availability == .ready, settings.autoCheck, !hasChecked { runLocal(userInitiated: false) }
    }

    private func documentTyped() {
        guard !ownEditPending else { return }
        lastEditWasOwn = false
        guard hasChecked || !aiFindings.isEmpty, !isStale else { return }
        isStale = true
        suggestion = nil
        clearMarks(documentID: activeDocumentID)
    }

    private func documentEdited() {
        if lastEditWasOwn {
            lastEditWasOwn = false
            if settings.autoCheck, availability == .ready { runLocal(userInitiated: false) } else {
                // Снимок синхронизирует живой текст (ревизия растёт) и не рассылает `textEdits`.
                _ = appState?.selectedDocument?.symbolOutlineSnapshot()
                publishMarks()
            }
            return
        }
        if hasChecked || !aiFindings.isEmpty { isStale = true }
        if settings.autoCheck, availability == .ready { runLocal(userInitiated: false) }
    }

    private func refreshAvailability() {
        let next: Availability
        if let document = appState?.selectedDocument {
            if document.isLargeFileMode { next = .largeFile }
            else if document.language == .markdown || document.language == .plainText { next = .ready }
            else { next = .unsupportedType }
        } else { next = .noDocument }
        if availability != next { availability = next }
        if next != .ready {
            clearMarks(documentID: activeDocumentID)
            cancelWork()
            resetResults()
        }
    }

    // MARK: Локальная проверка

    func checkNow() { runLocal(userInitiated: true) }

    private func runLocal(userInitiated: Bool) {
        refreshAvailability()
        guard availability == .ready, let appState, let document = appState.selectedDocument, document.ioState == .idle else { return }
        localGeneration &+= 1
        let current = localGeneration
        localTask?.cancel()
        let taskGeneration = document.taskCoordinator.begin(.styleCheck)
        // Снимок не рассылает `textEdits`, иначе проверка запускала бы сама себя.
        guard let snapshot = document.symbolOutlineSnapshot() else {
            document.taskCoordinator.finish(.styleCheck, generation: taskGeneration)
            return
        }
        isChecking = true
        let settings = self.settings
        let isMarkdown = document.language == .markdown
        let worker = Task.detached(priority: .utility) {
            StyleCheckService.check(text: snapshot.text, isMarkdown: isMarkdown, settings: settings,
                                    documentID: snapshot.documentID, revision: snapshot.revision,
                                    isCancelled: { Task.isCancelled })
        }
        let task = Task { [weak self, weak document] in
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, let document else { return }
            defer {
                document.taskCoordinator.finish(.styleCheck, generation: taskGeneration)
                if self.localGeneration == current { self.isChecking = false }
            }
            // Поздний или устаревший результат тихо отбрасывается: при продолжающемся наборе автопроверка сработает снова.
            guard !Task.isCancelled, self.localGeneration == current,
                  self.appState?.selectedDocument === document,
                  document.textRevision == snapshot.revision, !document.hasPendingLiveEdits,
                  document.taskCoordinator.isCurrent(taskGeneration, for: .styleCheck) else { return }
            self.apply(result, snapshot: snapshot, userInitiated: userInitiated)
        }
        localTask = task
        document.taskCoordinator.attachTask(task, kind: .styleCheck, generation: taskGeneration)
    }

    private func apply(_ result: StyleCheckResult, snapshot: DocumentTextSnapshot, userInitiated: Bool) {
        lastResult = result
        localSourceText = snapshot.text
        localFindings = result.findings
        skippedIDs.removeAll()
        hasChecked = true
        isStale = false
        suggestion = nil
        detectedLanguage = result.language
        // AI-замечания привязываются к новому тексту заново; не нашедшиеся выбрасываются.
        let text = snapshot.text as NSString
        aiFindings = aiFindings.compactMap { finding in
            guard let range = AIWritingPlacement.locate(original: finding.fragment, expected: finding.range, in: text) else { return nil }
            var moved = finding
            moved.range = range
            return moved
        }
        lineNumbers = Self.lineNumbers(for: localFindings + aiFindings, in: snapshot.text)
        rebuildVisible()
        publishMarks()
        if userInitiated { announce(L10n.tr("文风检查完成，发现 %lld 个问题", findings.count)) }
    }

    /// Номера строк (с 1) для находок: один проход по тексту.
    nonisolated static func lineNumbers(for findings: [StyleFinding], in text: String) -> [UUID: Int] {
        guard !findings.isEmpty else { return [:] }
        let units = Array(text.utf16)
        var result: [UUID: Int] = [:]
        var line = 1, position = 0
        for finding in findings.sorted(by: { $0.range.location < $1.range.location }) {
            let target = min(finding.range.location, units.count)
            while position < target {
                if units[position] == 0x0A { line += 1 }
                else if units[position] == 0x0D, !(position + 1 < units.count && units[position + 1] == 0x0A) { line += 1 }
                position += 1
            }
            result[finding.id] = line
        }
        return result
    }

    // MARK: AI-проверка

    func runReview() { runReview(approving: nil) }

    func sendAnyway() {
        guard let pending = pendingSend else { return }
        runReview(approving: pending)
    }

    func cancelReview() {
        reviewGeneration &+= 1
        reviewTask?.cancel(); reviewTask = nil
        appState?.selectedDocument?.taskCoordinator.cancel(.styleReview)
        isReviewing = false
        pendingSend = nil
    }

    func retry() {
        switch lastOperation {
        case .review: runReview()
        case .suggest: suggestEdit()
        }
    }

    private func runReview(approving: PendingSend?) {
        guard availability == .ready, let appState, let document = appState.selectedDocument, document.ioState == .idle else { return }
        lastOperation = .review
        guard appState.aiAvailability(for: .styleReview) == .available else {
            post(L10n.tr("AI 功能已关闭"), .info, action: .openSettings)
            return
        }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: true, includesEditorText: false)
        extraction.space = .source
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let selection = extraction.result else { post(L10n.tr("文本已变化，请重新检查"), .info); return }
        if let approving, !approving.selection.matches(selection) {
            pendingSend = nil
            post(L10n.tr("文本已变化，请重新检查"), .info)
            return
        }
        let profile = appState.preferences.aiProfile(for: .styleReview)
        let key: String?
        do { key = try loadKey(AIFeature.styleReview.role, profile.baseURL) } catch { fail(error); return }
        let language = settings.fixedLanguage ?? TextSegmentation.language(of: selection.text)
        let code = TextSegmentation.languageCode(for: language)
        let goal = settings.goal
        let known = Array(findings.filter {
            $0.source == .rule && selection.range.location <= $0.range.location && NSMaxRange($0.range) <= NSMaxRange(selection.range)
        }.prefix(StyleReviewService.maxKnown))
        let size = AIRequestSize.bytes(StyleReviewService.instructions(languageCode: code, goal: goal),
                                       StyleReviewService.input(text: selection.text, languageCode: code, known: known, goal: goal))
        if size > max(AIRequestSize.threshold, approving?.bytes ?? 0) {
            pendingSend = PendingSend(selection: selection, bytes: size)
            post(AIRequestSize.warning(label: AIRequestSize.label(selection), bytes: size), .info, action: .sendAnyway)
            return
        }
        pendingSend = nil
        clearMessage()
        reviewGeneration &+= 1
        let current = reviewGeneration
        reviewTask?.cancel()
        // Отдельный вид задачи: `.styleCheck` обесценил бы результат локальной проверки.
        let taskGeneration = document.taskCoordinator.begin(.styleReview)
        let sentRevision = document.textRevision
        isReviewing = true
        let review = self.review
        let task = Task { [weak self, weak document] in
            defer {
                document?.taskCoordinator.finish(.styleReview, generation: taskGeneration)
                if let self, self.reviewGeneration == current { self.isReviewing = false }
            }
            do {
                let response = try await review(selection.text, code, known, goal, profile, key)
                guard let self, let document, self.isReviewCurrent(current, document: document, taskGeneration: taskGeneration, profile: profile, key: key) else { return }
                try self.applyReview(response, selection: selection, sentRevision: sentRevision, document: document)
            } catch {
                guard let self, let document, self.isReviewCurrent(current, document: document, taskGeneration: taskGeneration, profile: profile, key: key) else { return }
                self.fail(error)
            }
        }
        reviewTask = task
        document.taskCoordinator.attachTask(task, kind: .styleReview, generation: taskGeneration)
    }

    /// Документ, функция, профиль и ключ те же, что при запуске. Иначе результат выбрасывается без сообщения.
    private func isReviewCurrent(_ generation: Int, document: EditorDocument, taskGeneration: UInt, profile: AIModelProfile, key: String?) -> Bool {
        guard !Task.isCancelled, reviewGeneration == generation, let appState,
              appState.selectedDocument === document,
              document.taskCoordinator.isCurrent(taskGeneration, for: .styleReview),
              appState.preferences.aiFeatures.contains(.styleReview),
              appState.preferences.aiProfile(for: .styleReview) == profile,
              (try? loadKey(AIFeature.styleReview.role, profile.baseURL)) == key else { return false }
        return true
    }

    private func applyReview(_ response: String, selection: EditorTextSelectionSnapshot, sentRevision: UInt, document: EditorDocument) throws {
        let parsed = try StyleReviewService.parse(response: response, text: selection.text, offset: selection.range.location)
        var found = parsed.findings
        var skipped = parsed.skipped
        guard let snapshot = document.symbolOutlineSnapshot() else { return }
        // Текст менялся во время запроса: цитаты ищутся в живом тексте заново, не нашедшиеся пропускаются.
        if snapshot.revision != sentRevision || document.hasPendingLiveEdits {
            let text = snapshot.text as NSString
            found = found.compactMap { finding in
                guard let range = AIWritingPlacement.locate(original: finding.fragment, expected: finding.range, in: text) else {
                    skipped += 1
                    return nil
                }
                var moved = finding
                moved.range = range
                return moved
            }
        }
        aiFindings = found
        suggestion = nil
        lineNumbers = Self.lineNumbers(for: localFindings + aiFindings, in: snapshot.text)
        rebuildVisible()
        publishMarks()
        if skipped > 0 { post(L10n.tr("有 %lld 条 AI 意见无法对应到原文，已略过", skipped), .info) }
        else if found.isEmpty { post(L10n.tr("AI 未发现问题"), .info) }
        announce(L10n.tr("文风检查完成，发现 %lld 个问题", findings.count))
    }

    // MARK: Выбор и список

    private func rebuildVisible() {
        let settings = self.settings
        findings = (localFindings + aiFindings)
            .filter { settings.isEnabled($0.category) && !skippedIDs.contains($0.id) }
            .sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length < $1.range.length }
        if let selectedID, !findings.contains(where: { $0.id == selectedID }) { self.selectedID = nil; suggestion = nil }
    }

    func select(_ id: UUID) {
        guard let finding = findings.first(where: { $0.id == id }) else { return }
        if selectedID != id { suggestion = nil }
        selectedID = id
        reveal(finding)
    }

    func select(next: Bool) {
        guard !findings.isEmpty else { return }
        let index = findings.firstIndex { $0.id == selectedID }
        let target: Int
        if let index { target = (index + (next ? 1 : -1) + findings.count) % findings.count }
        else { target = next ? 0 : findings.count - 1 }
        select(findings[target].id)
    }

    private func reveal(_ finding: StyleFinding) {
        guard !isStale, let document = appState?.selectedDocument else { return }
        NotificationCenter.default.post(name: EditorCommandNotification.revealSelection,
                                        object: EditorSelectionRequest(documentID: document.id, range: finding.range, focusesEditor: false))
    }

    func skip(_ id: UUID) {
        let wasSelected = selectedID == id
        skippedIDs.insert(id)
        let position = findings.firstIndex { $0.id == id }
        rebuildVisible()
        publishMarks()
        guard wasSelected else { return }
        suggestion = nil
        if let position, !findings.isEmpty { select(findings[min(position, findings.count - 1)].id) }
    }

    func setCategory(_ category: StyleCategory, enabled: Bool) {
        var next = settings
        next.setEnabled(category, enabled)
        settings = next
        rebuildVisible()
        publishMarks()
        // Правила выключенной категории при проверке не выполнялись: после включения нужна новая проверка.
        if enabled, category.source == .rule, hasChecked {
            if next.autoCheck { runLocal(userInitiated: false) } else { isStale = true; clearMarks(documentID: activeDocumentID) }
        }
    }

    func setFixedLanguage(_ language: TextLanguage?) {
        var next = settings
        next.fixedLanguage = language
        settings = next
        if next.autoCheck, availability == .ready { runLocal(userInitiated: false) } else if hasChecked { isStale = true }
    }

    func resetSettings() {
        settings = .default
        rebuildVisible()
        if availability == .ready, settings.autoCheck { runLocal(userInitiated: false) } else if hasChecked { isStale = true }
    }

    // MARK: Правка

    /// Готовая замена (пробелы или предложение AI) не требует нового запроса.
    private func readySuggestion(for finding: StyleFinding) -> Suggestion? {
        guard let replacement = finding.replacement else { return nil }
        let line = lineNumbers[finding.id] ?? 1
        if finding.source == .ai {
            return Suggestion(findingID: finding.id, original: finding.fragment, replacement: replacement,
                              shownBefore: finding.fragment, shownAfter: replacement,
                              explanation: finding.explanation, expected: finding.range, line: line)
        }
        let text = localSourceText as NSString
        guard NSMaxRange(finding.range) <= text.length else { return nil }
        let original = text.substring(with: finding.range)
        // Фрагмент начинается с заменяемых пробелов и несёт соседний знак для показа.
        let fragment = finding.fragment as NSString
        let tail = fragment.length >= finding.range.length ? fragment.substring(from: finding.range.length) : ""
        return Suggestion(findingID: finding.id, original: original, replacement: replacement,
                          shownBefore: finding.fragment, shownAfter: replacement + tail,
                          explanation: finding.explanation, expected: finding.range, line: line)
    }

    func suggestEdit() {
        guard !isStale, !isSuggesting, let finding = selectedFinding else { return }
        lastOperation = .suggest
        if let ready = readySuggestion(for: finding) { suggestion = ready; return }
        guard let appState, let document = appState.selectedDocument, appState.aiAvailability(for: .styleReview) == .available else {
            post(L10n.tr("AI 功能已关闭"), .info, action: .openSettings)
            return
        }
        guard let snapshot = document.symbolOutlineSnapshot(), NSMaxRange(finding.range) <= snapshot.utf16Length else {
            post(L10n.tr("文本已变化，请重新检查"), .info)
            return
        }
        let text = snapshot.text as NSString
        let option = "Fix only this issue and keep the meaning: " + finding.explanation + " Fragment: " + finding.fragment
        // Контекст: предыдущее, текущее и следующее предложения абзаца. Слишком большой — только текущее.
        let paragraph = text.paragraphRange(for: finding.range)
        let sentences = TextSegmentation.sentences(in: snapshot.text, range: paragraph)
        var context = paragraph
        var own = paragraph
        if let index = sentences.firstIndex(where: { NSLocationInRange(finding.range.location, $0.range) }) {
            own = sentences[index].range
            let first = sentences[max(index - 1, 0)].range, last = sentences[min(index + 1, sentences.count - 1)].range
            context = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        }
        if AIRequestSize.bytes(text.substring(with: context), option) > AIRequestSize.threshold { context = own }
        if AIRequestSize.bytes(text.substring(with: context), option) > AIRequestSize.threshold {
            post(L10n.tr("片段过长，无法建议修改"), .info)
            return
        }
        let profile = appState.preferences.aiProfile(for: .styleReview)
        let key: String?
        do { key = try loadKey(AIFeature.styleReview.role, profile.baseURL) } catch { fail(error); return }
        clearMessage()
        suggestGeneration &+= 1
        let current = suggestGeneration
        suggestTask?.cancel()
        isSuggesting = true
        let contextText = text.substring(with: context)
        let target = NSRange(location: finding.range.location - context.location, length: finding.range.length)
        let suggest = self.suggest
        suggestTask = Task { [weak self, weak document] in
            defer { if let self, self.suggestGeneration == current { self.isSuggesting = false } }
            do {
                let result = try await suggest(contextText, option, profile, key)
                guard let self, let document, self.isSuggestCurrent(current, document: document, findingID: finding.id, profile: profile, key: key) else { return }
                guard let chosen = result.suggestions.first(where: {
                    $0.original != $0.replacement && NSIntersectionRange($0.range, target).length > 0
                }) else {
                    self.post(L10n.tr("没有可用的修改建议"), .info)
                    return
                }
                self.suggestion = Suggestion(findingID: finding.id, original: chosen.original, replacement: chosen.replacement,
                                             shownBefore: chosen.original, shownAfter: chosen.replacement,
                                             explanation: chosen.explanation.isEmpty ? finding.explanation : chosen.explanation,
                                             expected: NSRange(location: context.location + chosen.range.location, length: chosen.range.length),
                                             line: self.lineNumbers[finding.id] ?? 1)
            } catch {
                guard let self, let document, self.isSuggestCurrent(current, document: document, findingID: finding.id, profile: profile, key: key) else { return }
                self.fail(error)
            }
        }
    }

    private func isSuggestCurrent(_ generation: Int, document: EditorDocument, findingID: UUID, profile: AIModelProfile, key: String?) -> Bool {
        guard !Task.isCancelled, suggestGeneration == generation, let appState,
              appState.selectedDocument === document, selectedID == findingID, !isStale,
              appState.preferences.aiFeatures.contains(.styleReview),
              appState.preferences.aiProfile(for: .styleReview) == profile,
              (try? loadKey(AIFeature.styleReview.role, profile.baseURL)) == key else { return false }
        return true
    }

    func reject() { suggestion = nil }

    /// Принимает предложенную правку либо готовую замену выбранного замечания.
    func accept() {
        guard let appState, let document = appState.selectedDocument, availability == .ready else { return }
        guard let item = suggestion ?? selectedFinding.flatMap({ readySuggestion(for: $0) }) else { return }
        guard !document.isReadingMode, document.ioState == .idle else { post(L10n.tr("此文档不可编辑"), .info); return }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: true,
                                                     requiresEditable: true, includesEditorText: true)
        extraction.space = .source
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let result = extraction.result, let editorText = extraction.editorText else {
            post(L10n.tr("当前文本无法修改"), .info)
            return
        }
        // Цитата ищется в свежем тексте редактора: положение из проверки могло устареть.
        guard let range = AIWritingPlacement.locate(original: item.original, expected: item.expected, in: editorText as NSString) else {
            post(L10n.tr("文本已变化，请重新检查"), .info)
            return
        }
        let request = EditorRangeReplacementRequest(documentID: document.id, range: range, originalText: item.original,
                                                    replacementText: item.replacement, expectedEditorRevision: result.editorRevision,
                                                    actionName: L10n.tr("文风检查"))
        request.groupsUndo = true
        ownEditPending = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        ownEditPending = false
        guard request.wasHandled else {
            post(request.failureMessage ?? L10n.tr("文本已变化，请重新检查"), .info)
            return
        }
        lastEditWasOwn = true
        let delta = (item.replacement as NSString).length - range.length
        localFindings = localFindings.filter { $0.id != item.findingID }.compactMap { $0.shifted(after: range, delta: delta) }
        aiFindings = aiFindings.filter { $0.id != item.findingID }.compactMap { $0.shifted(after: range, delta: delta) }
        let newText = (editorText as NSString).replacingCharacters(in: range, with: item.replacement)
        localSourceText = newText
        lineNumbers = Self.lineNumbers(for: localFindings + aiFindings, in: newText)
        suggestion = nil
        selectedID = nil
        rebuildVisible()
        publishMarks()
        // Фокус переходит к следующему замечанию после принятого.
        if let next = findings.first(where: { $0.range.location >= range.location }) ?? findings.first { select(next.id) }
    }

    // MARK: Подчёркивания

    private func publishMarks() {
        guard let document = appState?.selectedDocument else { return }
        let show = isPanelVisible && !isStale && availability == .ready
        let marks = show ? findings.map { StyleMark(range: $0.range, source: $0.source) } : []
        NotificationCenter.default.post(name: EditorCommandNotification.styleMarks,
                                        object: StyleMarksRequest(documentID: document.id, textRevision: document.textRevision, marks: marks))
    }

    private func clearMarks(documentID: UUID?) {
        guard let documentID else { return }
        NotificationCenter.default.post(name: EditorCommandNotification.styleMarks,
                                        object: StyleMarksRequest(documentID: documentID, textRevision: 0, marks: []))
    }
}
