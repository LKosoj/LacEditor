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
    @Published var feature: AIFeature = .clarity
    @Published var requestedFeature: AIFeature = .clarity
    @Published var option = ""
    @Published var translationLanguage: AITranslationLanguage = .english {
        didSet { if oldValue != translationLanguage { translationTargetChanged() } }
    }
    @Published var customTranslationLanguage = "" {
        didSet { if oldValue != customTranslationLanguage, translationLanguage == .custom { translationTargetChanged() } }
    }
    @Published private(set) var isWorking = false
    @Published private(set) var report = ""
    @Published private(set) var suggestions: [AIWritingSuggestion] = [] {
        didSet {
            let ids = Set(suggestions.map(\.id))
            diffCache = diffCache.filter { ids.contains($0.key) }
        }
    }
    @Published private(set) var references: [AIWritingReference] = []
    @Published private(set) var image: Data?
    @Published private(set) var imageEditSource: Data?
    @Published private(set) var message = "" { didSet { messageKind = .error; messageAction = nil } }
    @Published private(set) var messageKind: StatusKind = .error
    @Published private(set) var messageAction: AIMessageAction?
    @Published private(set) var generatedAt: Date?
    @Published private(set) var resultRevision: UInt?

    private weak var appState: AppState?
    private let generate: (AIFeature, String, String, AIModelProfile, String?, JinaConfiguration?, String?, String?) async throws -> AIWritingResult
    private let loadKey: (AIRole, String) throws -> String?
    private struct Credentials {
        let profile: AIModelProfile
        let key: String?
        let required: Bool
    }
    private var batchCredentials: [AIFeature: Credentials] = [:]
    private var task: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var metadataGeneration = 0
    private var metadataProfile: AIModelProfile?
    private var generation = 0
    private var snapshot: EditorTextSelectionSnapshot?
    private var settingsObserver: AnyCancellable?
    private var activeProfile: AIModelProfile?
    private var activeKey: String?
    private var activeNeedsKey = false
    private var activeJinaConfiguration: JinaConfiguration?
    private var isBackground = false
    private var reportIsBackground = false
    private var activeFeatures: Set<AIFeature> = []
    private var diffCache: [UUID: (original: AttributedString, replacement: AttributedString)] = [:]
    private var imageEditRequest: AIImageEditRequest?
    private let editImage: (Data, String, AIModelProfile, String?) async throws -> Data

    init(appState: AppState, loadKey: @escaping (AIRole, String) throws -> String? = { try AIKeychainStore().load(for: $0, baseURL: $1) }, generate: @escaping (AIFeature, String, String, AIModelProfile, String?, JinaConfiguration?, String?, String?) async throws -> AIWritingResult = { feature, input, option, profile, key, jina, searchKey, readerKey in
        try await AIWritingService.generate(feature: feature, input: input, option: option, profile: profile, key: key, jinaConfiguration: jina ?? JinaConfiguration(), jinaSearchKey: searchKey, jinaReaderKey: readerKey)
    }, editImage: @escaping (Data, String, AIModelProfile, String?) async throws -> Data = {
        try await AIClient().editImage(data: $0, prompt: $1, profile: $2, key: $3)
    }) {
        self.appState = appState
        documentTools = AIDocumentToolsController(appState: appState)
        self.generate = generate
        self.editImage = editImage
        self.loadKey = loadKey
        settingsObserver = appState.preferences.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.settingsChanged() }
        }
    }

    deinit { task?.cancel(); debounce?.cancel(); metadataTask?.cancel() }

    var enabledFeatures: [AIFeature] {
        guard let preferences = appState?.preferences else { return [] }
        return AIFeature.allCases.filter { preferences.aiFeatures.contains($0) && $0 != .completion }
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

    private func translationTargetChanged() {
        guard feature == .translation else { return }
        cancel()
        snapshot = nil; suggestions = []; references = []; report = ""; image = nil; message = ""
        generatedAt = nil; resultRevision = nil
    }

    func prepare(_ feature: AIFeature) {
        guard let appState, appState.preferences.aiFeatures.contains(feature) else { return }
        requestedFeature = feature
        appState.isAIWritingVisible = true
    }

    func prepareImageEdit(_ request: AIImageEditRequest) {
        guard let appState, appState.selectedDocumentID == request.documentID,
              appState.preferences.aiFeatures.contains(.imageEdit),
              let document = appState.selectedDocument, document.ioState == .idle else { return }
        cancel()
        requestedFeature = .imageEdit; feature = .imageEdit
        imageEditRequest = request; imageEditSource = nil; image = nil; report = ""; suggestions = []; references = []; message = ""
        generatedAt = nil; resultRevision = nil; isWorking = true; reportIsBackground = false
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
        image = nil; message = ""; isWorking = true; reportIsBackground = false
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

    private func currentImageEditRequest() -> AIImageEditRequest? {
        guard let request = imageEditRequest, let appState,
              appState.selectedDocumentID == request.documentID,
              appState.preferences.aiFeatures.contains(.imageEdit),
              let document = appState.selectedDocument, document.ioState == .idle else { return nil }
        let snapshot = document.synchronizedSnapshot(), text = snapshot.text as NSString
        guard snapshot.revision == request.revision, request.range.location <= text.length,
              request.range.length <= text.length - request.range.location,
              text.substring(with: request.range) == request.originalMarkdown else { return nil }
        return request
    }

    func applyImageEdit() {
        guard let result = image, let request = currentImageEditRequest(),
              let input = MarkdownImageEditingService.initial(in: request.originalMarkdown as NSString, selection: NSRange(location: 0, length: (request.originalMarkdown as NSString).length)) else { return }
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
            apply.isAIGenerated = true
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
        if [.translation, .toneRewrite, .audienceReview].contains(feature),
           option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            post(L10n.tr("请输入目标语言、语气或读者"), kind: .info)
            return
        }
        start(feature, option: option, background: false)
    }

    private func start(_ feature: AIFeature, option: String, background: Bool, backgroundFeatures: [AIFeature] = []) {
        guard let appState, let document = appState.selectedDocument,
              document.ioState == .idle,
              appState.preferences.aiFeatures.contains(feature) else { return }
        if feature == .provenance {
            reportIsBackground = false
            cancel(); self.feature = feature; self.option = option; suggestions = []; references = []; image = nil; message = ""
            document.provenance.configure(enabled: true, length: (document.synchronizedText() as NSString).length)
            report = document.provenance.report()
            generatedAt = Date(); resultRevision = document.textRevision
            return
        }
        let profile = appState.preferences.aiProfile(for: feature)
        let jina = feature == .sources ? appState.preferences.jinaConfiguration : nil
        let needsKey = feature != .sources || jina?.readerEnabled == true
        guard !needsKey || profile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: !feature.isReplacement && feature != .illustration)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let snapshot = extraction.result else {
            if !background { post(L10n.tr("请先选择需要处理的文本"), kind: .info) }
            return
        }
        let key: String?
        let features = background ? backgroundFeatures : [feature]
        var credentials: [AIFeature: Credentials] = [:]
        let searchKey: String?
        let readerKey: String?
        do {
            let store = AIKeychainStore()
            key = try needsKey ? loadKey(feature.role, profile.baseURL) : nil
            credentials[feature] = Credentials(profile: profile, key: key, required: needsKey)
            for currentFeature in features where currentFeature != feature {
                let currentProfile = appState.preferences.aiProfile(for: currentFeature)
                guard currentProfile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
                let currentKey = try loadKey(currentFeature.role, currentProfile.baseURL)
                credentials[currentFeature] = Credentials(profile: currentProfile, key: currentKey, required: true)
            }
            searchKey = try jina.flatMap { $0.searchEnabled ? try store.load(for: JinaServiceKind.search, baseURL: $0.searchEndpoint) : nil }
            readerKey = try jina.flatMap { $0.readerEnabled ? try store.load(for: JinaServiceKind.reader, baseURL: $0.readerEndpoint) : nil }
        } catch { fail(error); return }
        cancel()
        self.snapshot = snapshot
        self.feature = feature
        self.option = option
        report = ""; suggestions = []; references = []; image = nil; message = ""
        generatedAt = nil; resultRevision = nil
        isWorking = true
        activeProfile = profile
        batchCredentials = credentials
        activeKey = key
        activeNeedsKey = needsKey
        activeJinaConfiguration = jina
        isBackground = background
        reportIsBackground = background
        activeFeatures = Set(background ? backgroundFeatures : [feature])
        let current = generation
        let taskGeneration = document.taskCoordinator.begin(.aiWriting)
        let generate = self.generate
        task = Task { [weak self] in
            defer {
                document.taskCoordinator.finish(.aiWriting, generation: taskGeneration)
                if let self, self.generation == current { self.isWorking = false }
            }
            do {
                for currentFeature in features {
                    try Task.checkCancellation()
                    guard let item = credentials[currentFeature] else { return }
                    let result = try await generate(currentFeature, snapshot.text, option, item.profile, item.key, jina, searchKey, readerKey)
                    guard let self, !Task.isCancelled, self.isCurrent(current, snapshot: snapshot, feature: currentFeature, profile: item.profile),
                          self.activeCredentialsAreCurrent(),
                          document.taskCoordinator.isCurrent(taskGeneration, for: .aiWriting),
                          self.jinaIsCurrent(jina, searchKey: searchKey, readerKey: readerKey),
                          self.keyIsCurrent(item.key, profile: item.profile, role: currentFeature.role, required: item.required),
                          !background || self.appState?.preferences.aiBackgroundEnabled == true else { return }
                    self.suggestions.append(contentsOf: result.suggestions)
                    self.references.append(contentsOf: result.references)
                    if !result.report.isEmpty {
                        if !self.report.isEmpty { self.report += "\n\n" }
                        self.report += background ? "\(currentFeature.title)\n\(result.report)" : result.report
                    }
                    self.image = result.image
                    self.generatedAt = Date(); self.resultRevision = snapshot.editorRevision
                    if currentFeature == .metadata { document.aiMetadata = result.report }
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
        guard keyIsCurrent(activeKey, profile: profile, role: feature.role, required: activeNeedsKey) else { return false }
        return batchCredentials.allSatisfy { feature, item in
            appState.preferences.aiFeatures.contains(feature) &&
            appState.preferences.aiProfile(for: feature) == item.profile &&
            keyIsCurrent(item.key, profile: item.profile, role: feature.role, required: item.required)
        }
    }

    private func jinaIsCurrent(_ configuration: JinaConfiguration?, searchKey: String?, readerKey: String?) -> Bool {
        guard let configuration else { return true }
        guard appState?.preferences.jinaConfiguration == configuration else { return false }
        let store = AIKeychainStore()
        do {
            let currentSearchKey = try configuration.searchEnabled ? store.load(for: JinaServiceKind.search, baseURL: configuration.searchEndpoint) : nil
            let currentReaderKey = try configuration.readerEnabled ? store.load(for: JinaServiceKind.reader, baseURL: configuration.readerEndpoint) : nil
            return currentSearchKey == searchKey && currentReaderKey == readerKey
        } catch { return false }
    }

    func accept(_ suggestion: AIWritingSuggestion) {
        guard let snapshot, let appState,
              appState.selectedDocumentID == snapshot.documentID,
              appState.preferences.aiFeatures.contains(feature),
              activeCredentialsAreCurrent(),
              suggestion.range.location != NSNotFound,
              suggestion.range.location <= (snapshot.text as NSString).length,
              suggestion.range.length <= (snapshot.text as NSString).length - suggestion.range.location else { return }
        let range = NSRange(location: snapshot.range.location + suggestion.range.location, length: suggestion.range.length)
        let request = EditorRangeReplacementRequest(documentID: snapshot.documentID, range: range, originalText: suggestion.original, replacementText: suggestion.replacement, expectedEditorRevision: snapshot.editorRevision, actionName: feature.title)
        request.isAIGenerated = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        if !request.wasHandled { message = request.failureMessage ?? L10n.tr("编辑内容已变化，请重新执行转换") }
    }

    /// Одна замена объемлющего диапазона и одна группа отмены: после первой правки версия редактора меняется, поэтому по очереди через accept() нельзя.
    func acceptAll() {
        guard let snapshot, let appState,
              appState.selectedDocumentID == snapshot.documentID,
              appState.preferences.aiFeatures.contains(feature),
              activeCredentialsAreCurrent() else { return }
        let text = snapshot.text as NSString
        let items = suggestions.filter { $0.original != $0.replacement }.sorted { $0.range.location < $1.range.location }
        guard let first = items.first else { post(L10n.tr("转换结果与原文相同"), kind: .info); return }
        var cursor = first.range.location
        var composed = ""
        for item in items {
            guard item.range.location != NSNotFound, item.range.location >= cursor,
                  item.range.length >= 0, NSMaxRange(item.range) <= text.length,
                  text.substring(with: item.range) == item.original else {
                post(L10n.tr("建议的位置互相重叠，请逐条接受"))
                return
            }
            composed += text.substring(with: NSRange(location: cursor, length: item.range.location - cursor)) + item.replacement
            cursor = NSMaxRange(item.range)
        }
        let span = NSRange(location: first.range.location, length: cursor - first.range.location)
        let request = EditorRangeReplacementRequest(documentID: snapshot.documentID, range: NSRange(location: snapshot.range.location + span.location, length: span.length), originalText: text.substring(with: span), replacementText: composed, expectedEditorRevision: snapshot.editorRevision, actionName: feature.title)
        request.isAIGenerated = true
        request.groupsUndo = true
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        if request.wasHandled { suggestions = [] }
        else { message = request.failureMessage ?? L10n.tr("编辑内容已变化，请重新执行转换") }
    }

    func rejectAll() { suggestions = [] }

    func reject(_ suggestion: AIWritingSuggestion) { suggestions.removeAll { $0.id == suggestion.id } }

    func reveal(_ suggestion: AIWritingSuggestion) {
        guard let snapshot else { return }
        let range = NSRange(location: snapshot.range.location + suggestion.range.location, length: suggestion.range.length)
        NotificationCenter.default.post(name: EditorCommandNotification.revealSelection, object: EditorSelectionRequest(documentID: snapshot.documentID, range: range))
    }

    func revealReference(_ reference: AIWritingReference) {
        guard let snapshot, let appState, appState.selectedDocumentID == snapshot.documentID,
              appState.preferences.aiFeatures.contains(feature), activeCredentialsAreCurrent(),
              references.contains(where: { $0.id == reference.id }),
              reference.range.location != NSNotFound,
              reference.range.location <= (snapshot.text as NSString).length,
              reference.range.length <= (snapshot.text as NSString).length - reference.range.location,
              (snapshot.text as NSString).substring(with: reference.range) == reference.quote else { return }
        let range = NSRange(location: snapshot.range.location + reference.range.location, length: reference.range.length)
        NotificationCenter.default.post(name: EditorCommandNotification.revealSelection, object: EditorSelectionRequest(documentID: snapshot.documentID, range: range))
    }

    var canInsertSummary: Bool { feature == .summary && !reportIsBackground && !report.isEmpty }

    func insertSummary() {
        guard canInsertSummary, let snapshot else { return }
        accept(AIWritingSuggestion(id: UUID(), range: NSRange(location: snapshot.range.length, length: 0), original: "", replacement: "\n\n" + report, explanation: ""))
    }

    func insertImage() {
        guard let image, let snapshot else { return }
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let mime = UTType(identifier)?.preferredMIMEType else { return }
        let replacement = "\n\n![AI](data:\(mime);base64,\(image.base64EncodedString()))"
        accept(AIWritingSuggestion(id: UUID(), range: NSRange(location: snapshot.range.length, length: 0), original: "", replacement: replacement, explanation: ""))
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
            cancel(); feature = .imageDescription; activeProfile = profile; activeKey = key; activeNeedsKey = true; activeFeatures = [.imageDescription]; report = ""; suggestions = []; references = []; image = nil; message = ""; isWorking = true
            reportIsBackground = false
            let current = generation
            task = Task { [weak self] in
                defer { if let self, self.generation == current { self.isWorking = false } }
                do {
                    let text = try await AIWritingService.describeImage(data: data, profile: profile, key: key)
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
        batchCredentials = [:]
        activeKey = nil
        activeNeedsKey = false
        activeJinaConfiguration = nil
        isBackground = false
        activeFeatures = []
    }

    func invalidate(documentID: UUID) {
        documentTools.invalidate(documentID: documentID)
        if snapshot?.documentID == documentID || imageEditRequest?.documentID == documentID || appState?.selectedDocumentID == documentID {
            cancel(); snapshot = nil; suggestions = []; references = []; report = ""; image = nil; imageEditSource = nil; imageEditRequest = nil
        }
        debounce?.cancel(); debounce = nil
        cancelMetadata()
        generatedAt = nil; resultRevision = nil
    }

    func selectedDocumentChanged() {
        documentTools.selectedDocumentChanged()
        cancel(); cancelMetadata(); debounce?.cancel(); snapshot = nil; suggestions = []; references = []; report = ""; image = nil; imageEditSource = nil; imageEditRequest = nil
        generatedAt = nil; resultRevision = nil
    }

    func documentChanged(_ documentID: UUID) {
        invalidate(documentID: documentID)
        guard let appState, appState.selectedDocumentID == documentID,
              appState.selectedDocument?.isLargeFileMode != true,
              appState.preferences.aiBackgroundEnabled else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, let appState = self.appState,
                  appState.selectedDocumentID == documentID, appState.preferences.aiBackgroundEnabled,
                  appState.selectedDocument?.isLargeFileMode != true,
                  appState.hostWindow?.isKeyWindow == true,
                  !self.isWorking, (self.reportIsBackground || (self.suggestions.isEmpty && self.image == nil && self.report.isEmpty)) else { return }
            let features = AIFeature.allCases.filter { $0.isBackground && $0 != .completion && appState.preferences.aiFeatures.contains($0) }
            guard let feature = features.first else { return }
            self.start(feature, option: "", background: true, backgroundFeatures: features)
        }
    }

    func didSave(documentID: UUID) {
        guard let appState, appState.selectedDocumentID == documentID,
              let document = appState.selectedDocument, document.ioState == .idle, !document.isLargeFileMode,
              appState.preferences.aiBackgroundEnabled,
              appState.preferences.aiFeatures.contains(.metadata) else { return }
        let profile = appState.preferences.aiProfile(for: .metadata)
        guard profile.isEnabled else { return }
        let key: String?
        do { key = try loadKey(.text, profile.baseURL) }
        catch { return }
        let snapshot = document.synchronizedSnapshot()
        cancelMetadata()
        metadataProfile = profile
        let current = metadataGeneration
        let taskGeneration = document.taskCoordinator.begin(.aiMetadata)
        let generate = self.generate
        metadataTask = Task { [weak self, weak document] in
            do {
                let result = try await generate(.metadata, snapshot.text, "", profile, key, nil, nil, nil)
                guard let self, let document, let appState = self.appState,
                      !Task.isCancelled, self.metadataGeneration == current,
                      document.taskCoordinator.isCurrent(taskGeneration, for: .aiMetadata),
                      appState.selectedDocumentID == documentID,
                      appState.documents.contains(where: { $0 === document }),
                      document.textRevision == snapshot.revision, !document.hasPendingLiveEdits,
                      appState.preferences.aiBackgroundEnabled,
                      appState.preferences.aiFeatures.contains(.metadata),
                      appState.preferences.aiProfile(for: .metadata) == profile,
                      self.keyIsCurrent(key, profile: profile, role: .text, required: true) else { return }
                document.aiMetadata = result.report
                document.taskCoordinator.finish(.aiMetadata, generation: taskGeneration)
                self.metadataTask = nil; self.metadataProfile = nil
            } catch {
                guard let self, self.metadataGeneration == current else { return }
                document?.taskCoordinator.finish(.aiMetadata, generation: taskGeneration)
                self.metadataTask = nil; self.metadataProfile = nil
            }
        }
        if let metadataTask { document.taskCoordinator.attachTask(metadataTask, kind: .aiMetadata, generation: taskGeneration) }
    }

    private func cancelMetadata() {
        metadataGeneration += 1
        metadataTask?.cancel(); metadataTask = nil; metadataProfile = nil
    }

    func updateMetadata(_ text: String) {
        guard feature == .metadata, let appState, let snapshot,
              let document = appState.selectedDocument, document.id == snapshot.documentID,
              appState.preferences.aiFeatures.contains(.metadata),
              activeCredentialsAreCurrent() else { return }
        cancelMetadata()
        document.aiMetadata = text
        report = text
    }

    private func settingsChanged() {
        documentTools.settingsChanged()
        objectWillChange.send()
        guard let appState else { return }
        objectWillChange.send()
        if metadataProfile != nil && (!appState.preferences.aiBackgroundEnabled || !appState.preferences.aiFeatures.contains(.metadata) || metadataProfile != appState.preferences.aiProfile(for: .metadata)) { cancelMetadata() }
        if ((!report.isEmpty || snapshot != nil || image != nil || imageEditRequest != nil) && !appState.preferences.aiFeatures.contains(feature)) || !activeFeatures.isSubset(of: appState.preferences.aiFeatures) || (activeProfile != nil && !activeCredentialsAreCurrent()) || (activeJinaConfiguration != nil && activeJinaConfiguration != appState.preferences.jinaConfiguration) || (reportIsBackground && !appState.preferences.aiBackgroundEnabled) {
            cancel(); debounce?.cancel(); snapshot = nil; suggestions = []; references = []; report = ""; image = nil; imageEditSource = nil; imageEditRequest = nil
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
