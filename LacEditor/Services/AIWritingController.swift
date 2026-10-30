import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct AIImageEditRequest {
    let documentID: UUID
    let revision: UInt
    let range: NSRange
    let originalMarkdown: String
    let address: String
    let documentURL: URL?
}

@MainActor
final class AIWritingController: ObservableObject {
    let documentTools: AIDocumentToolsController
    let question: AIQuestionController
    let agent: AIAgentController
    @Published var feature: AIFeature = .clarity
    @Published var requestedFeature: AIFeature = .clarity
    @Published var option = ""
    @Published var translationLanguage: AITranslationLanguage = .english {
        didSet { if oldValue != translationLanguage { translationTargetChanged() } }
    }
    @Published var customTranslationLanguage = "" {
        didSet { if oldValue != customTranslationLanguage, translationLanguage == .custom { translationTargetChanged() } }
    }
    @Published var rewriteMode: AIRewriteMode = .rephrase {
        didSet { if oldValue != rewriteMode { clearResultIfCurrent(.rewrite) } }
    }
    @Published private(set) var isWorking = false
    @Published private(set) var report = ""
    @Published private(set) var suggestions: [AIWritingSuggestion] = [] {
        didSet {
            let ids = Set(suggestions.map(\.id))
            diffCache = diffCache.filter { ids.contains($0.key) }
            unavailableIDs.formIntersection(ids)
        }
    }
    /// Правки, место которых при принятии не нашлось в живом тексте.
    @Published private(set) var unavailableIDs: Set<UUID> = []
    @Published private(set) var references: [AIWritingReference] = []
    @Published private(set) var image: Data?
    @Published private(set) var imageEditSource: Data?
    @Published private(set) var message = "" { didSet { messageKind = .error; messageAction = nil } }
    @Published private(set) var messageKind: StatusKind = .error
    @Published private(set) var messageAction: AIMessageAction?
    @Published private(set) var generatedAt: Date?
    @Published private(set) var resultRevision: UInt?
    @Published private(set) var sentSummary: String?

    private struct PendingSend { let feature: AIFeature; let option: String; let snapshot: EditorTextSelectionSnapshot; let bytes: Int }
    private var pendingSend: PendingSend?
    private weak var appState: AppState?
    private let generate: (AIFeature, String, String, AIModelProfile, String?, JinaConfiguration?, String?, String?, AIRewriteMode?) async throws -> AIWritingResult
    private let loadKey: (AIRole, String) throws -> String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var snapshot: EditorTextSelectionSnapshot?
    private var settingsObserver: AnyCancellable?
    private var activeProfile: AIModelProfile?
    private var activeKey: String?
    private var activeNeedsKey = false
    private var activeJinaConfiguration: JinaConfiguration?
    private var activeFeatures: Set<AIFeature> = []
    private var diffCache: [UUID: (original: AttributedString, replacement: AttributedString)] = [:]
    private var imageEditRequest: AIImageEditRequest?
    private let editImage: (Data, String, AIModelProfile, String?) async throws -> Data
    private let describe: (Data, AIModelProfile, String?) async throws -> String
    private var imageDescriptionRequest: AIImageEditRequest?

    init(appState: AppState, loadKey: @escaping (AIRole, String) throws -> String? = { try AIKeychainStore().load(for: $0, baseURL: $1) }, generate: @escaping (AIFeature, String, String, AIModelProfile, String?, JinaConfiguration?, String?, String?, AIRewriteMode?) async throws -> AIWritingResult = { feature, input, option, profile, key, jina, searchKey, readerKey, mode in
        try await AIWritingService.generate(feature: feature, input: input, option: option, profile: profile, key: key, jinaConfiguration: jina ?? JinaConfiguration(), jinaSearchKey: searchKey, jinaReaderKey: readerKey, rewriteMode: mode)
    }, editImage: @escaping (Data, String, AIModelProfile, String?) async throws -> Data = {
        try await AIClient().editImage(data: $0, prompt: $1, profile: $2, key: $3)
    }, describe: @escaping (Data, AIModelProfile, String?) async throws -> String = {
        try await AIWritingService.describeImage(data: $0, profile: $1, key: $2)
    }) {
        self.appState = appState
        documentTools = AIDocumentToolsController(appState: appState)
        question = AIQuestionController(appState: appState)
        agent = AIAgentController(appState: appState)
        self.generate = generate
        self.editImage = editImage
        self.describe = describe
        self.loadKey = loadKey
        settingsObserver = appState.preferences.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.settingsChanged() }
        }
    }

    deinit { task?.cancel() }

    var enabledFeatures: [AIFeature] {
        guard let preferences = appState?.preferences else { return [] }
        return AIFeature.allCases.filter { preferences.aiFeatures.contains($0) && $0 != .completion && $0 != .voiceDraft }
    }

    var translationTarget: String {
        translationLanguage.targetName(customName: customTranslationLanguage)
    }

    private func post(_ text: String, kind: StatusKind = .error, action: AIMessageAction? = nil) {
        message = text; messageKind = kind; messageAction = action
    }
    private func fail(_ error: Error) { post(error.localizedDescription, action: AIMessageAction.forError(error)) }

    /// Подсветка слов для карточки подсказки; только отображение, текст не меняется.
    func wordDiff(for suggestion: AIWritingSuggestion) -> (original: AttributedString, replacement: AttributedString) {
        if let cached = diffCache[suggestion.id] { return cached }
        let runs = AIWordDiff.runs(original: suggestion.original, replacement: suggestion.replacement)
        let value = (original: AIWordDiff.attributed(runs.original), replacement: AIWordDiff.attributed(runs.replacement))
        diffCache[suggestion.id] = value
        return value
    }

    private func translationTargetChanged() { clearResultIfCurrent(.translation) }

    private func clearResultIfCurrent(_ target: AIFeature) {
        if pendingSend?.feature == target { pendingSend = nil; message = "" }
        guard feature == target else { return }
        reset()
    }

    /// Снимает только показанный результат; выбранная функция и поля ввода остаются.
    func reset() {
        cancel()
        pendingSend = nil
        snapshot = nil; suggestions = []; references = []; report = ""; image = nil; message = ""; sentSummary = nil
        generatedAt = nil; resultRevision = nil
    }

    var hasResult: Bool { !report.isEmpty || !suggestions.isEmpty || !references.isEmpty || image != nil }

    /// Название документа, которому принадлежит результат, если выбрана другая вкладка.
    var otherDocumentName: String? {
        guard hasResult, let snapshot, let appState, appState.selectedDocumentID != snapshot.documentID else { return nil }
        return appState.documents.first { $0.id == snapshot.documentID }?.displayName
    }

    func prepare(_ feature: AIFeature) {
        guard let appState, appState.preferences.aiFeatures.contains(feature) else { return }
        requestedFeature = feature
        appState.isAIWritingVisible = true
    }

    func explainSelection() {
        prepare(.ask)
        question.askAboutSelection()
    }

    func selectRewrite(_ mode: AIRewriteMode) {
        guard let appState, appState.preferences.aiFeatures.contains(.rewrite) else { return }
        rewriteMode = mode
        prepare(.rewrite)
    }

    func prepareImageEdit(_ request: AIImageEditRequest) {
        guard let appState, appState.selectedDocumentID == request.documentID,
              appState.preferences.aiFeatures.contains(.imageEdit),
              let document = appState.selectedDocument, document.ioState == .idle else { return }
        cancel()
        requestedFeature = .imageEdit; feature = .imageEdit
        imageEditRequest = request; imageDescriptionRequest = nil; imageEditSource = nil; image = nil; report = ""; suggestions = []; references = []; message = ""
        generatedAt = nil; resultRevision = nil; isWorking = true
        appState.isAIWritingVisible = true
        let current = generation
        task = Task { [weak self, weak document] in
            defer { if let self, self.generation == current { self.isWorking = false } }
            do {
                let data = try await Self.loadImage(for: request, document: document)
                guard let self, !Task.isCancelled, self.generation == current,
                      self.currentImageEditRequest() != nil else { return }
                self.imageEditSource = data
            } catch {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.fail(error)
            }
        }
    }

    func prepareImageDescription(_ request: AIImageEditRequest) {
        guard let appState, appState.selectedDocumentID == request.documentID,
              appState.preferences.aiFeatures.contains(.imageDescription),
              let document = appState.selectedDocument, document.ioState == .idle else { return }
        let profile = appState.preferences.aiProfile(for: .imageDescription)
        guard profile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
        let key: String?
        do { key = try loadKey(.text, profile.baseURL) } catch { fail(error); return }
        cancel()
        requestedFeature = .imageDescription; feature = .imageDescription
        imageEditRequest = nil; imageDescriptionRequest = request; imageEditSource = nil
        report = ""; suggestions = []; references = []; image = nil; message = ""
        sentSummary = nil; snapshot = nil; pendingSend = nil
        generatedAt = nil; resultRevision = nil
        activeProfile = profile; activeKey = key; activeNeedsKey = true; activeFeatures = [.imageDescription]
        isWorking = true
        appState.isAIWritingVisible = true
        let current = generation, describe = self.describe
        task = Task { [weak self, weak document] in
            defer { if let self, self.generation == current { self.isWorking = false } }
            do {
                let data = try await Self.loadImage(for: request, document: document)
                let text = try await describe(data, profile, key)
                guard let self, !Task.isCancelled, self.generation == current,
                      self.imageDescriptionRequest != nil, self.appState?.selectedDocumentID == request.documentID,
                      self.appState?.preferences.aiFeatures.contains(.imageDescription) == true,
                      self.appState?.preferences.aiProfile(for: .imageDescription) == profile,
                      self.keyIsCurrent(key, profile: profile, role: .text, required: true) else { return }
                self.report = text; self.generatedAt = Date(); self.resultRevision = request.revision
            } catch {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.fail(error)
            }
        }
    }

    private static func loadImage(for request: AIImageEditRequest, document: EditorDocument?) async throws -> Data {
        if let url = URL(string: request.address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return try await MarkdownImageUploadService.download(url).data
        }
        let text = document?.synchronizedText() ?? request.originalMarkdown
        return try await Task.detached {
            let paths = try? MarkdownResourcePaths(text: text, document: request.documentURL)
            return try MarkdownImageUploadService.payload(address: request.address, document: request.documentURL, paths: paths).data
        }.value
    }

    func runImageEdit(prompt: String) {
        guard let source = imageEditSource, let request = currentImageEditRequest(), let appState else { return }
        let profile = appState.preferences.aiProfile(for: .imageEdit)
        guard profile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
        let key: String?
        do { key = try loadKey(.image, profile.baseURL) } catch { fail(error); return }
        cancel(); imageEditRequest = request; imageEditSource = source; feature = .imageEdit; requestedFeature = .imageEdit
        activeProfile = profile; activeKey = key; activeNeedsKey = true; activeFeatures = [.imageEdit]
        image = nil; message = ""; isWorking = true
        let current = generation, editImage = self.editImage
        task = Task { [weak self] in
            defer { if let self, self.generation == current { self.isWorking = false } }
            do {
                let result = try await editImage(source, prompt, profile, key)
                guard let self, !Task.isCancelled, self.generation == current,
                      self.currentImageEditRequest() != nil,
                      self.appState?.preferences.aiProfile(for: .imageEdit) == profile,
                      self.keyIsCurrent(key, profile: profile, role: .image, required: true) else { return }
                self.image = result; self.generatedAt = Date(); self.resultRevision = request.revision
            } catch {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.fail(error)
            }
        }
    }

    private func currentImageEditRequest() -> AIImageEditRequest? { currentImageRequest(imageEditRequest, feature: .imageEdit) }

    private func currentImageRequest(_ request: AIImageEditRequest?, feature: AIFeature) -> AIImageEditRequest? {
        guard let request, let appState,
              appState.selectedDocumentID == request.documentID,
              appState.preferences.aiFeatures.contains(feature),
              let document = appState.selectedDocument, document.ioState == .idle else { return nil }
        let snapshot = document.synchronizedSnapshot(), text = snapshot.text as NSString
        guard snapshot.revision == request.revision, request.range.location <= text.length,
              request.range.length <= text.length - request.range.location,
              text.substring(with: request.range) == request.originalMarkdown else { return nil }
        return request
    }

    func applyImageEdit() {
        guard let result = image else { return }
        guard let request = currentImageEditRequest(),
              let input = MarkdownImageEditingService.initial(in: request.originalMarkdown as NSString, selection: NSRange(location: 0, length: (request.originalMarkdown as NSString).length)) else {
            post(L10n.tr("编辑内容已变化，请重新执行转换"))
            return
        }
        do {
            let address: String
            if request.address.lowercased().hasPrefix("data:image/") {
                guard let source = CGImageSourceCreateWithData(result as CFData, nil),
                      let identifier = CGImageSourceGetType(source) as String?,
                      let mime = UTType(identifier)?.preferredMIMEType else { throw AIError.invalidResponse }
                address = "data:\(mime);base64,\(result.base64EncodedString())"
            } else {
                guard let appState, let window = appState.hostWindow,
                      let source = CGImageSourceCreateWithData(result as CFData, nil),
                      let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
                      let ext = type.preferredFilenameExtension else { throw AIError.invalidResponse }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [type]
                panel.nameFieldStringValue = "edited-image." + ext
                guard panel.runModal() == .OK, let destination = panel.url,
                      window == appState.hostWindow, currentImageEditRequest() != nil else { return }
                try result.write(to: destination, options: .withoutOverwriting)
                guard let value = MarkdownImageEditingService.address(for: destination, document: request.documentURL) else { throw AIError.invalidConfiguration }
                address = value
            }
            let changed = MarkdownImageInput(alt: input.alt, address: address, title: input.title)
            guard let edit = MarkdownImageEditingService.edit(in: request.originalMarkdown as NSString, selection: NSRange(location: 0, length: (request.originalMarkdown as NSString).length), input: changed) else { throw AIError.invalidResponse }
            let replacement = (request.originalMarkdown as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            let apply = EditorRangeReplacementRequest(documentID: request.documentID, range: request.range,
                originalText: request.originalMarkdown, replacementText: replacement,
                expectedEditorRevision: request.revision, actionName: AIFeature.imageEdit.title)
            NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: apply)
            if apply.wasHandled { imageEditRequest = nil; imageEditSource = nil; image = nil }
            else { post(apply.failureMessage ?? L10n.tr("编辑内容已变化，请重新执行转换")) }
        } catch { fail(error) }
    }

    func saveEditedImage() {
        guard let image, feature == .imageEdit, currentImageEditRequest() != nil,
              let source = CGImageSourceCreateWithData(image as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              let ext = type.preferredFilenameExtension else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [type]; panel.nameFieldStringValue = "edited-image." + ext
        guard panel.runModal() == .OK, let url = panel.url, currentImageEditRequest() != nil else { return }
        do { try image.write(to: url, options: .atomic) } catch { fail(error) }
    }

    func run(_ feature: AIFeature, option: String = "") {
        if feature.isDocumentTool { prepare(feature); return }
        requestedFeature = feature
        if let pending = pendingSend, pending.feature != feature { pendingSend = nil; message = "" }
        if (feature == .translation || (feature == .rewrite && rewriteMode.requiresOption)),
           option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            post(L10n.tr("请输入目标语言或语气"), kind: .info)
            return
        }
        start(feature, option: option)
    }

    func sendAnyway() {
        guard let pending = pendingSend else { return }
        start(pending.feature, option: pending.option, approving: pending)
    }

    private func start(_ feature: AIFeature, option: String, approving: PendingSend? = nil) {
        guard let appState, let document = appState.selectedDocument,
              document.ioState == .idle,
              appState.preferences.aiFeatures.contains(feature) else { return }
        let profile = appState.preferences.aiProfile(for: feature)
        let jina = feature == .sources ? appState.preferences.jinaConfiguration : nil
        let needsKey = feature != .sources || jina?.readerEnabled == true
        guard !needsKey || profile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: !feature.isReplacement && feature != .illustration)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let snapshot = extraction.result else {
            post(L10n.tr("请先选择需要处理的文本"), kind: .info)
            return
        }
        if let approving, !approving.snapshot.matches(snapshot) {
            pendingSend = nil
            post(L10n.tr("编辑内容已变化，请重新执行转换"), kind: .info)
            return
        }
        let measured = feature != .illustration
        let bytes = !measured ? 0 : (needsKey ? AIRequestSize.bytes(snapshot.text, option) : AIRequestSize.bytes(option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? snapshot.text : option))
        if bytes > max(AIRequestSize.threshold, approving?.bytes ?? 0) {
            pendingSend = PendingSend(feature: feature, option: option, snapshot: snapshot, bytes: bytes)
            post(AIRequestSize.warning(label: AIRequestSize.label(snapshot), bytes: bytes), kind: .info, action: .sendAnyway)
            return
        }
        pendingSend = nil
        let key: String?
        let searchKey: String?
        let readerKey: String?
        do {
            let store = AIKeychainStore()
            key = try needsKey ? loadKey(feature.role, profile.baseURL) : nil
            searchKey = try jina.flatMap { $0.searchEnabled ? try store.load(for: JinaServiceKind.search, baseURL: $0.searchEndpoint) : nil }
            readerKey = try jina.flatMap { $0.readerEnabled ? try store.load(for: JinaServiceKind.reader, baseURL: $0.readerEndpoint) : nil }
        } catch { fail(error); return }
        cancel()
        self.snapshot = snapshot
        self.feature = feature
        imageDescriptionRequest = nil
        self.option = option
        report = ""; suggestions = []; references = []; image = nil; message = ""
        generatedAt = nil; resultRevision = nil
        sentSummary = measured ? AIRequestSize.sent(label: AIRequestSize.label(snapshot), bytes: bytes) : nil
        isWorking = true
        activeProfile = profile
        activeKey = key
        activeNeedsKey = needsKey
        activeJinaConfiguration = jina
        activeFeatures = [feature]
        let current = generation
        let taskGeneration = document.taskCoordinator.begin(.aiWriting)
        let generate = self.generate
        let mode = rewriteMode
        task = Task { [weak self] in
            defer {
                document.taskCoordinator.finish(.aiWriting, generation: taskGeneration)
                if let self, self.generation == current { self.isWorking = false }
            }
            do {
                let result = try await generate(feature, snapshot.text, option, profile, key, jina, searchKey, readerKey, feature == .rewrite ? mode : nil)
                guard let self, !Task.isCancelled, self.isCurrent(current, snapshot: snapshot, feature: feature, profile: profile),
                      self.activeCredentialsAreCurrent(),
                      document.taskCoordinator.isCurrent(taskGeneration, for: .aiWriting),
                      AIJinaCredentials.isCurrent(jina, searchKey: searchKey, readerKey: readerKey, preferences: self.appState?.preferences),
                      self.keyIsCurrent(key, profile: profile, role: feature.role, required: needsKey) else { return }
                self.suggestions.append(contentsOf: result.suggestions)
                self.references.append(contentsOf: result.references)
                if !result.report.isEmpty { self.report = result.report }
                self.image = result.image
                self.generatedAt = Date(); self.resultRevision = snapshot.editorRevision
                if feature == .metadata { document.aiMetadata = result.report }
                if result.skipped > 0 {
                    let allDropped = self.suggestions.isEmpty && self.references.isEmpty && (self.report.isEmpty || (feature == .sources && result.accepted == 0))
                    self.post(AIRequestSize.skippedMessage(result.skipped, allDropped: allDropped), kind: .info)
                }
            } catch {
                guard let self, !Task.isCancelled, self.isCurrent(current, snapshot: snapshot, feature: feature, profile: profile) && document.taskCoordinator.isCurrent(taskGeneration, for: .aiWriting) else { return }
                self.fail(error)
            }
        }
        if let task { document.taskCoordinator.attachTask(task, kind: .aiWriting, generation: taskGeneration) }
    }

    private func isCurrent(_ generation: Int, snapshot: EditorTextSelectionSnapshot, feature: AIFeature, profile: AIModelProfile) -> Bool {
        guard self.generation == generation, let appState,
              appState.selectedDocumentID == snapshot.documentID,
              appState.selectedDocument?.ioState == .idle,
              appState.preferences.aiFeatures.contains(feature),
              appState.preferences.aiProfile(for: feature) == profile else { return false }
        return true
    }

    private func keyIsCurrent(_ key: String?, profile: AIModelProfile, role: AIRole, required: Bool) -> Bool {
        guard required else { return true }
        do { return try loadKey(role, profile.baseURL) == key }
        catch { return false }
    }

    private func activeCredentialsAreCurrent() -> Bool {
        guard let appState, let profile = activeProfile,
              appState.preferences.aiProfile(for: feature) == profile else { return false }
        return keyIsCurrent(activeKey, profile: profile, role: feature.role, required: activeNeedsKey)
    }

    /// Живой текст редактора и выделение с актуальной версией: версия из снимка после любой правки устарела. Диапазоны снимка и замены заданы в координатах редактора, а не текста документа. nil, если открыта другая вкладка или документ занят.
    private func liveText(for snapshot: EditorTextSelectionSnapshot, requiresEditable: Bool = true) -> (text: NSString, selection: EditorTextSelectionSnapshot)? {
        guard let appState, appState.selectedDocumentID == snapshot.documentID,
              let document = appState.selectedDocument, document.ioState == .idle else { return nil }
        let extraction = EditorTextExtractionRequest(documentID: snapshot.documentID, allowsTokenAtCaret: false, allowsInsertionPoint: true, requiresEditable: requiresEditable, includesEditorText: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        // nil: вкладка неактивна, идёт ввод marked text или текст только для чтения
        guard let current = extraction.result else {
            if requiresEditable { post(document.isReadingMode ? L10n.tr("阅读模式下无法修改") : L10n.tr("当前文本无法修改")) }
            return nil
        }
        return ((extraction.editorText ?? document.synchronizedSnapshot().text) as NSString, current)
    }

    private func place(_ suggestion: AIWritingSuggestion, snapshot: EditorTextSelectionSnapshot, in text: NSString) -> NSRange? {
        let expected = NSRange(location: snapshot.range.location + suggestion.range.location, length: suggestion.range.length)
        return AIWritingPlacement.locate(original: suggestion.original, expected: expected, in: text)
    }

    func accept(_ suggestion: AIWritingSuggestion) {
        guard let snapshot, let appState,
              appState.selectedDocumentID == snapshot.documentID,
              appState.preferences.aiFeatures.contains(feature),
              activeCredentialsAreCurrent(),
              suggestions.contains(where: { $0.id == suggestion.id }),
              let live = liveText(for: snapshot) else { return }
        guard let range = place(suggestion, snapshot: snapshot, in: live.text) else {
            unavailableIDs.insert(suggestion.id)
            return
        }
        let request = EditorRangeReplacementRequest(documentID: snapshot.documentID, range: range, originalText: suggestion.original, replacementText: suggestion.replacement, expectedEditorRevision: live.selection.editorRevision, actionName: feature.title)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        guard request.wasHandled else { message = request.failureMessage ?? L10n.tr("编辑内容已变化，请重新执行转换"); return }
        // Остальные правки сдвигаются на разницу длин (UTF-16), считая в хранимых координатах принятой правки
        let delta = (suggestion.replacement as NSString).length - range.length
        let end = NSMaxRange(suggestion.range)
        suggestions = suggestions.filter { $0.id != suggestion.id }.map { $0.range.location >= end ? $0.shifted(by: delta) : $0 }
    }

    /// Одна замена объемлющего диапазона и одна группа отмены: после первой правки версия редактора меняется, поэтому по очереди через accept() нельзя.
    func acceptAll() {
        guard let snapshot, let appState,
              appState.selectedDocumentID == snapshot.documentID,
              appState.preferences.aiFeatures.contains(feature),
              activeCredentialsAreCurrent(),
              let live = liveText(for: snapshot) else { return }
        let items = suggestions.filter { $0.original != $0.replacement }
        guard !items.isEmpty else { post(L10n.tr("转换结果与原文相同"), kind: .info); return }
        var placed: [(suggestion: AIWritingSuggestion, range: NSRange)] = []
        var missing = Set<UUID>()
        for item in items {
            if let range = place(item, snapshot: snapshot, in: live.text) { placed.append((suggestion: item, range: range)) } else { missing.insert(item.id) }
        }
        unavailableIDs = missing
        placed.sort { $0.range.location < $1.range.location }
        guard let first = placed.first else { post(L10n.tr("原文已不存在，无法应用")); return }
        var cursor = first.range.location
        var composed = ""
        for (item, range) in placed {
            guard range.location >= cursor else {
                post(L10n.tr("建议的位置互相重叠，请逐条接受"))
                return
            }
            composed += live.text.substring(with: NSRange(location: cursor, length: range.location - cursor)) + item.replacement
            cursor = NSMaxRange(range)
        }
        let span = NSRange(location: first.range.location, length: cursor - first.range.location)
        let request = EditorRangeReplacementRequest(documentID: snapshot.documentID, range: span, originalText: live.text.substring(with: span), replacementText: composed, expectedEditorRevision: live.selection.editorRevision, actionName: feature.title)
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        guard request.wasHandled else { message = request.failureMessage ?? L10n.tr("编辑内容已变化，请重新执行转换"); return }
        suggestions = suggestions.filter { missing.contains($0.id) }
        if !missing.isEmpty { post(L10n.tr("已接受 %lld 处修改，%lld 处无法应用", placed.count, missing.count), kind: .info) }
    }

    func rejectAll() { suggestions = [] }

    func reject(_ suggestion: AIWritingSuggestion) { suggestions.removeAll { $0.id == suggestion.id } }

    func reveal(_ suggestion: AIWritingSuggestion) {
        guard let snapshot, let text = liveText(for: snapshot, requiresEditable: false)?.text else { return }
        guard let range = place(suggestion, snapshot: snapshot, in: text) else {
            unavailableIDs.insert(suggestion.id)
            return
        }
        NotificationCenter.default.post(name: EditorCommandNotification.revealSelection, object: EditorSelectionRequest(documentID: snapshot.documentID, range: range))
    }

    func revealReference(_ reference: AIWritingReference) {
        guard let snapshot, let appState, appState.selectedDocumentID == snapshot.documentID,
              appState.preferences.aiFeatures.contains(feature), activeCredentialsAreCurrent(),
              references.contains(where: { $0.id == reference.id }),
              reference.range.location != NSNotFound,
              let text = liveText(for: snapshot, requiresEditable: false)?.text else { return }
        let range = NSRange(location: snapshot.range.location + reference.range.location, length: reference.range.length)
        // Цитата сверяется с живым текстом: устаревшая цитата не открывается
        guard NSMaxRange(range) <= text.length, text.substring(with: range) == reference.quote else { return }
        NotificationCenter.default.post(name: EditorCommandNotification.revealSelection, object: EditorSelectionRequest(documentID: snapshot.documentID, range: range))
    }

    var canInsertSummary: Bool { feature == .summary && !report.isEmpty }

    func insertSummary() {
        guard canInsertSummary else { return }
        insertBlock(report)
    }

    func insertImage() {
        guard let image else { return }
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let mime = UTType(identifier)?.preferredMIMEType else { return }
        insertBlock("![AI](data:\(mime);base64,\(image.base64EncodedString()))")
    }

    /// Сводка и картинка: если текст не менялся, после исходного фрагмента, иначе в текущий курсор. Отказа из-за правки текста нет.
    private func insertBlock(_ block: String) {
        guard let snapshot, let appState,
              appState.selectedDocumentID == snapshot.documentID,
              appState.preferences.aiFeatures.contains(feature),
              activeCredentialsAreCurrent(),
              let live = liveText(for: snapshot) else { return }
        let location = live.selection.editorRevision == snapshot.editorRevision ? NSMaxRange(snapshot.range) : NSMaxRange(live.selection.range)
        guard location <= live.text.length else { return }
        let replacement = AIDocumentToolsController.blockSeparator(before: location, in: live.text) + block
        let request = EditorRangeReplacementRequest(documentID: snapshot.documentID, range: NSRange(location: location, length: 0), originalText: "", replacementText: replacement, expectedEditorRevision: live.selection.editorRevision, actionName: feature.title)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        if !request.wasHandled { message = request.failureMessage ?? L10n.tr("编辑内容已变化，请重新执行转换") }
    }

    func saveImage() {
        guard let image, let appState, let documentID = snapshot?.documentID,
              appState.selectedDocumentID == documentID,
              appState.preferences.aiFeatures.contains(.illustration), activeCredentialsAreCurrent() else { return }
        let current = generation
        let profile = appState.preferences.aiProfile(for: .illustration)
        let panel = NSSavePanel()
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), let ext = type.preferredFilenameExtension else { return }
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "illustration." + ext
        guard panel.runModal() == .OK, let url = panel.url,
              generation == current, self.image == image, feature == .illustration,
              appState.selectedDocumentID == documentID,
              appState.preferences.aiFeatures.contains(.illustration),
              appState.preferences.aiProfile(for: .illustration) == profile, activeCredentialsAreCurrent() else { return }
        do { try image.write(to: url, options: .atomic) } catch { fail(error) }
    }

    func describeImage() {
        guard let appState, appState.preferences.aiFeatures.contains(.imageDescription),
              let document = appState.selectedDocument, document.ioState == .idle else { return }
        let profile = appState.preferences.aiProfile(for: .imageDescription)
        guard profile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              appState.selectedDocumentID == document.id, document.ioState == .idle,
              appState.preferences.aiFeatures.contains(.imageDescription),
              appState.preferences.aiProfile(for: .imageDescription) == profile else { return }
        do {
            let data = try Data(contentsOf: url)
            let key = try loadKey(.text, profile.baseURL)
            cancel(); feature = .imageDescription; imageDescriptionRequest = nil; activeProfile = profile; activeKey = key; activeNeedsKey = true; activeFeatures = [.imageDescription]; report = ""; suggestions = []; references = []; image = nil; message = ""; isWorking = true
            let current = generation, describe = self.describe
            task = Task { [weak self] in
                defer { if let self, self.generation == current { self.isWorking = false } }
                do {
                    let text = try await describe(data, profile, key)
                    guard let self, !Task.isCancelled, self.generation == current,
                          self.appState?.selectedDocumentID == document.id,
                          self.appState?.preferences.aiFeatures.contains(.imageDescription) == true,
                          self.appState?.preferences.aiProfile(for: .imageDescription) == profile,
                          self.keyIsCurrent(key, profile: profile, role: .text, required: true) else { return }
                    self.report = text; self.generatedAt = Date(); self.resultRevision = document.textRevision; self.isWorking = false
                } catch {
                    guard let self, !Task.isCancelled, self.generation == current else { return }
                    self.fail(error); self.isWorking = false
                }
            }
        } catch { fail(error) }
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        isWorking = false
        activeProfile = nil
        activeKey = nil
        activeNeedsKey = false
        activeJinaConfiguration = nil
        activeFeatures = []
    }

    func invalidate(documentID: UUID) {
        documentTools.invalidate(documentID: documentID)
        question.invalidate(documentID: documentID)
        if snapshot?.documentID == documentID || pendingSend?.snapshot.documentID == documentID || imageEditRequest?.documentID == documentID || imageDescriptionRequest?.documentID == documentID {
            if pendingSend != nil { pendingSend = nil; message = "" }
            cancel(); snapshot = nil; suggestions = []; references = []; report = ""; image = nil; imageEditSource = nil; imageEditRequest = nil; imageDescriptionRequest = nil; sentSummary = nil
            generatedAt = nil; resultRevision = nil
        }
    }

    /// Окно закрывается: агент не должен работать без окна.
    func windowClosed() { if agent.hasConversation { agent.stop() } }

    func selectedDocumentChanged() {
        documentTools.selectedDocumentChanged()
        question.selectedDocumentChanged()
        // Готовый результат остаётся в панели; сбрасывается только запрос, ещё идущий для прежней вкладки
        if isWorking { reset() }
        imageEditSource = nil; imageEditRequest = nil; imageDescriptionRequest = nil
        if pendingSend != nil { pendingSend = nil; message = "" }
        objectWillChange.send()
    }

    func updateMetadata(_ text: String) {
        guard feature == .metadata, let appState, let snapshot,
              let document = appState.selectedDocument, document.id == snapshot.documentID,
              appState.preferences.aiFeatures.contains(.metadata),
              activeCredentialsAreCurrent() else { return }
        document.aiMetadata = text
        report = text
    }

    private func settingsChanged() {
        documentTools.settingsChanged()
        question.settingsChanged()
        agent.settingsChanged()
        objectWillChange.send()
        guard let appState else { return }
        objectWillChange.send()
        if ((!report.isEmpty || snapshot != nil || image != nil || imageEditRequest != nil) && !appState.preferences.aiFeatures.contains(feature)) || !activeFeatures.isSubset(of: appState.preferences.aiFeatures) || (activeProfile != nil && !activeCredentialsAreCurrent()) || (activeJinaConfiguration != nil && activeJinaConfiguration != appState.preferences.jinaConfiguration) {
            cancel(); snapshot = nil; suggestions = []; references = []; report = ""; image = nil; imageEditSource = nil; imageEditRequest = nil; imageDescriptionRequest = nil
            if pendingSend != nil { pendingSend = nil; message = "" }
            sentSummary = nil
        }
    }
}

/// Подсветка различий по словам: токены делятся по Character, чтобы не разрывать составные символы.
enum AIWordDiff {
    struct Run: Equatable {
        enum Kind { case same, removed, added }
        var kind: Kind
        var text: String
    }

    private enum TokenClass { case space, word, other }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF: return true
        default: return false
        }
    }

    private static func tokenClass(_ character: Character) -> TokenClass {
        if character.isWhitespace { return .space }
        if character.unicodeScalars.contains(where: isCJK) { return .other }
        if character.isLetter || character.isNumber { return .word }
        return .other
    }

    /// Пробелы подряд и слова подряд — один токен; китайский символ, пунктуация и emoji — отдельные токены.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentClass: TokenClass?
        for character in text {
            let kind = tokenClass(character)
            if let currentClass, currentClass == kind, kind != .other {
                current.append(character)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(character)
                currentClass = kind
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func runs(original: String, replacement: String) -> (original: [Run], replacement: [Run]) {
        let old = tokens(original), new = tokens(replacement)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), added = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        func build(_ tokens: [String], marked: Set<Int>, kind: Run.Kind) -> [Run] {
            var runs: [Run] = []
            for (index, token) in tokens.enumerated() {
                let tokenKind: Run.Kind = marked.contains(index) ? kind : .same
                if let last = runs.last, last.kind == tokenKind { runs[runs.count - 1].text += token }
                else { runs.append(Run(kind: tokenKind, text: token)) }
            }
            return runs
        }
        return (build(old, marked: removed, kind: .removed), build(new, marked: added, kind: .added))
    }

    /// Цвет не единственный признак: удалённое зачёркнуто, вставленное подчёркнуто и жирное. Текст остаётся прежним.
    static func attributed(_ runs: [Run]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            switch run.kind {
            case .same: break
            case .removed:
                part.strikethroughStyle = Text.LineStyle.single
                part.backgroundColor = Color.red.opacity(0.15)
            case .added:
                part.underlineStyle = Text.LineStyle.single
                part.inlinePresentationIntent = .stronglyEmphasized
                part.backgroundColor = Color.green.opacity(0.15)
            }
            result.append(part)
        }
        return result
    }
}
