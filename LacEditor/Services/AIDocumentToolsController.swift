import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum AIMessageAction: Equatable {
    case openSettings, retry, sendAnyway
    /// Тип ошибки решает, что предложить; по тексту не определяем.
    static func forError(_ error: Error) -> AIMessageAction? {
        guard let error = error as? AIError else { return nil }
        switch error {
        case .disabled, .invalidConfiguration, .keychain: return .openSettings
        case .http(let status, _): return status == 401 || status == 403 ? .openSettings : .retry
        case .network, .invalidResponse: return .retry
        case .transport(let failure): return failure == .secureConnection ? .openSettings : .retry
        case .refused: return nil
        }
    }
}

@MainActor
final class AIDocumentToolsController: ObservableObject {
    private struct PendingSend { let feature: AIFeature; let selection: EditorTextSelectionSnapshot; let bytes: Int }
    @Published var option = ""
    @Published var inputs: [AIContextInput] = []
    @Published var before: AIContextInput?
    @Published var after: AIContextInput?
    @Published var checkID: UUID?
    @Published private(set) var fileURL: URL?
    @Published private(set) var report = ""
    @Published private(set) var differences = ""
    @Published private(set) var references: [AIContextReference] = []
    @Published private(set) var message = "" { didSet { messageKind = .error; messageAction = nil } }
    @Published private(set) var messageKind: StatusKind = .error
    @Published private(set) var messageAction: AIMessageAction?
    @Published private(set) var isWorking = false
    @Published private(set) var sentSummary: String?
    let recorder: AIVoiceRecorder
    private weak var appState: AppState?
    private var task: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var recordingDocumentID: UUID?
    private var recordingGeneration = 0
    private var generation = 0
    private var pendingSend: PendingSend?
    private var selection: EditorTextSelectionSnapshot?
    private var sources: [AIContextSnapshot] = []
    private var fileRevision: FileRevisionSnapshot?
    private var activeFeature: AIFeature?
    private var activeProfile: AIModelProfile?
    private var activeKey: String?
    private var activeCheck: AICustomCheck?
    private var activeOption = ""
    private var activeInputs: [AIContextInput] = []
    private var activeFileURL: URL?
    private var observer: NSObjectProtocol?
    private var recorderObserver: AnyCancellable?
    private let generate: (AIFeature, String, String, [AIContextSnapshot], AICustomCheck?, AIModelProfile, String?) async throws -> String
    private let recognize: (URL, AIModelProfile, String?) async throws -> String
    private let transcribe: (URL, AIModelProfile, String?) async throws -> String
    private let loadKey: (AIRole, String) throws -> String?

    init(appState: AppState,
         recorder: AIVoiceRecorder? = nil,
         generate: @escaping (AIFeature, String, String, [AIContextSnapshot], AICustomCheck?, AIModelProfile, String?) async throws -> String = AIDocumentToolsService.text,
         recognize: @escaping (URL, AIModelProfile, String?) async throws -> String = { try await AIMediaClient().recognize(fileURL: $0, profile: $1, key: $2) },
         transcribe: @escaping (URL, AIModelProfile, String?) async throws -> String = { try await AIMediaClient().transcribe(fileURL: $0, profile: $1, key: $2) },
         loadKey: @escaping (AIRole, String) throws -> String? = { try AIKeychainStore().load(for: $0, baseURL: $1) }) {
        self.appState = appState; self.recorder = recorder ?? AIVoiceRecorder(); self.generate = generate; self.recognize = recognize; self.transcribe = transcribe; self.loadKey = loadKey
        observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.documentContentDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let id = note.object as? UUID else { return }
                if self.selection?.documentID == id || self.sources.contains(where: { $0.document?.id == id }) || self.activeInputs.contains(.document(id)) { self.clearResult() }
            }
        }
        recorderObserver = self.recorder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    deinit { task?.cancel(); recordingTask?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func post(_ text: String, kind: StatusKind = .error, action: AIMessageAction? = nil) {
        message = text; messageKind = kind; messageAction = action
    }
    private func fail(_ error: Error) { post(error.localizedDescription, action: AIMessageAction.forError(error)) }

    static func usesOption(_ feature: AIFeature) -> Bool { [.contextReview, .compareVersions, .customCheck, .mermaid].contains(feature) }
    /// Показанный результат получен для прежних входов: его можно читать и копировать, но не вставлять.
    var isResultStale: Bool {
        guard activeFeature != nil, !report.isEmpty || !differences.isEmpty else { return false }
        return activeInputsDiffer
    }
    private var activeInputsDiffer: Bool {
        guard let feature = activeFeature else { return false }
        if Self.usesOption(feature), option != activeOption { return true }
        switch feature {
        case .contextReview: return inputs != activeInputs
        case .compareVersions:
            guard let before, let after else { return true }
            return [before, after] != activeInputs
        case .customCheck: return checkID != activeCheck?.id
        case .recognizeDocument, .voiceDraft: return fileURL != activeFileURL
        default: return false
        }
    }

    func isEnabled(_ feature: AIFeature) -> Bool { appState?.preferences.aiFeatures.contains(feature) == true }
    var documents: [EditorDocument] { appState?.windowManager?.documentsForAI ?? appState?.documents ?? [] }
    var checks: [AICustomCheck] { appState?.preferences.aiCustomChecks.filter(\.isEnabled) ?? [] }
    func name(_ input: AIContextInput) -> String {
        switch input { case .document(let id): return documents.first(where: { $0.id == id })?.displayName ?? L10n.tr("文档不可用"); case .file(let url): return url.lastPathComponent }
    }
    func addFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { for url in panel.urls where !inputs.contains(.file(url)) { inputs.append(.file(url)) } }
    }
    func chooseFile(feature: AIFeature) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = feature == .recognizeDocument ? [.image, .pdf] : [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorder.discard(); fileURL = url
    }
    func chooseComparisonFile(before isBefore: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isBefore { before = .file(url) } else { after = .file(url) }
    }
    func startRecording() {
        guard let appState, let document = appState.selectedDocument,
              document.ioState == .idle, isEnabled(.voiceDraft) else { return }
        clearResult(); recorder.discard(); fileURL = nil
        recordingDocumentID = document.id
        recordingGeneration += 1
        let current = recordingGeneration
        isWorking = true
        recordingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.recordingGeneration == current { self.recordingTask = nil; self.isWorking = false }
            }
            do {
                try await self.recorder.start()
            } catch {
                if self.recordingGeneration == current {
                    self.recordingDocumentID = nil
                    if !Task.isCancelled { self.fail(error) }
                }
            }
        }
    }
    private func discardRecording() {
        recordingGeneration += 1
        recordingTask?.cancel(); recordingTask = nil
        recordingDocumentID = nil
        if recorder.recordingURL == fileURL { fileURL = nil }
        recorder.discard()
    }
    func stopRecording() {
        fileURL = recorder.stop(); recordingDocumentID = nil
        clearResult()
    }
    func hidden() { cancel(); discardRecording() }

    func run(_ feature: AIFeature) { run(feature, approving: nil) }
    private func run(_ feature: AIFeature, approving: PendingSend?) {
        guard let appState, let document = appState.selectedDocument, document.ioState == .idle, appState.preferences.aiFeatures.contains(feature) else { return }
        let check = feature == .customCheck ? checks.first(where: { $0.id == checkID }) : nil
        if feature == .customCheck && check == nil { post(L10n.tr("请选择已启用的检查。"), kind: .info); return }
        let profile = appState.preferences.aiProfile(for: feature, customCheck: check)
        guard profile.isEnabled else { post(L10n.tr("AI 功能已关闭"), action: .openSettings); return }
        let extraction = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: feature == .contextReview || feature == .customCheck || feature == .compareVersions, allowsInsertionPoint: feature == .recognizeDocument || feature == .voiceDraft)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        guard let selection = extraction.result else { post(L10n.tr("请先选择需要处理的文本"), kind: .info); return }
        let selectedInputs: [AIContextInput]
        if feature == .contextReview { guard !inputs.isEmpty else { post(L10n.tr("请至少添加一个来源。"), kind: .info); return }; selectedInputs = inputs }
        else if feature == .compareVersions { guard let before, let after else { post(L10n.tr("请选择两个版本。"), kind: .info); return }; selectedInputs = [before, after] }
        else { selectedInputs = [] }
        if let approving, !approving.selection.matches(selection) { clearResult(); post(L10n.tr("编辑内容已变化，请重新执行转换"), kind: .info); return }
        let mediaURL = feature == .recognizeDocument || feature == .voiceDraft ? fileURL : nil
        if (feature == .recognizeDocument || feature == .voiceDraft) && (mediaURL == nil || recorder.isRecording) { post(L10n.tr("请选择文件或完成录音。"), kind: .info); return }
        do {
            let key = try loadKey(feature.role, profile.baseURL)
            let revision = try mediaURL.map { try FileRevisionSnapshot.capture($0) }
            clearResult(); self.selection = selection; activeFeature = feature; activeProfile = profile; activeKey = key; activeCheck = check; activeOption = self.option; activeInputs = selectedInputs; activeFileURL = mediaURL; fileRevision = revision; isWorking = true
            let current = generation
            let taskGeneration = document.taskCoordinator.begin(.aiDocumentTools)
            let option = option, generate = generate, recognize = recognize, transcribe = transcribe
            task = Task { [weak self] in
                defer { document.taskCoordinator.finish(.aiDocumentTools, generation: taskGeneration); if let self, self.generation == current { self.isWorking = false } }
                do {
                    let snapshots = try await AIContextService.capture(selectedInputs, appState: appState)
                    guard let self, self.validate(current, document: document, taskGeneration: taskGeneration) else { return }
                    self.sources = snapshots
                    var target = selection.text
                    if feature == .compareVersions {
                        let old = snapshots[0].text, new = snapshots[1].text
                        let comparison = Task.detached {
                            try Task.checkCancellation()
                            let difference = AITextComparison.compare(before: old, after: new)
                            try Task.checkCancellation()
                            return difference
                        }
                        let difference = try await withTaskCancellationHandler {
                            try await comparison.value
                        } onCancel: {
                            comparison.cancel()
                        }
                        guard self.validate(current, document: document, taskGeneration: taskGeneration) else { return }
                        target = difference
                    }
                    let result: String
                    if feature == .recognizeDocument, let mediaURL { result = try await recognize(mediaURL, profile, key) }
                    else if feature == .voiceDraft, let mediaURL { result = try await transcribe(mediaURL, profile, key) }
                    else {
                        let size = AIRequestSize.bytes(AIDocumentToolsService.input(target: target, option: option, contexts: snapshots))
                        let label = AIRequestSize.label(selection, sources: snapshots.count)
                        if size > max(AIRequestSize.threshold, approving?.bytes ?? 0) {
                            self.pendingSend = PendingSend(feature: feature, selection: selection, bytes: size)
                            self.post(AIRequestSize.warning(label: label, bytes: size), kind: .info, action: .sendAnyway)
                            return
                        }
                        self.sentSummary = AIRequestSize.sent(label: label, bytes: size)
                        if feature == .compareVersions { self.differences = target }
                        result = try await generate(feature, target, option, snapshots, check, profile, key)
                    }
                    guard self.validate(current, document: document, taskGeneration: taskGeneration) else { return }
                    if feature == .contextReview {
                        let review = try AIDocumentToolsService.parseContextResponse(result, contexts: snapshots)
                        self.references = review.references
                        self.report = review.report
                        if review.skipped > 0 { self.post(AIRequestSize.skippedMessage(review.skipped, allDropped: review.references.isEmpty), kind: .info) }
                    } else { self.report = result }
                } catch {
                    guard let self, self.validate(current, document: document, taskGeneration: taskGeneration) else { return }
                    self.fail(error)
                }
            }
            if let task { document.taskCoordinator.attachTask(task, kind: .aiDocumentTools, generation: taskGeneration) }
        } catch { fail(error) }
    }
    func sendAnyway() {
        guard let pending = pendingSend, let feature = activeFeature, feature == pending.feature, !activeInputsDiffer else {
            if pendingSend != nil { clearResult(); post(L10n.tr("所选来源已不可用或已更改。"), kind: .info) }
            return
        }
        run(feature, approving: pending)
    }
    private func discardStale(_ current: Int) {
        guard generation == current else { return }
        clearResult()
        post(L10n.tr("所选来源已不可用或已更改。"), kind: .info)
    }
    private func validate(_ current: Int, document: EditorDocument, taskGeneration: UInt) -> Bool {
        guard !Task.isCancelled, isCurrent(current), document.taskCoordinator.isCurrent(taskGeneration, for: .aiDocumentTools) else {
            discardStale(current)
            return false
        }
        return true
    }
    private func isCurrent(_ current: Int) -> Bool {
        guard generation == current, let appState, let selection, let feature = activeFeature, let profile = activeProfile,
              appState.selectedDocumentID == selection.documentID, appState.selectedDocument?.ioState == .idle,
              appState.preferences.aiFeatures.contains(feature), appState.preferences.aiProfile(for: feature, customCheck: activeCheck) == profile,
              AIContextService.isCurrent(sources, appState: appState) else { return false }
        do { guard try loadKey(feature.role, profile.baseURL) == activeKey else { return false } } catch { return false }
        if let check = activeCheck, !appState.preferences.aiCustomChecks.contains(check) { return false }
        if let revision = fileRevision { guard let activeFileURL, (try? FileRevisionSnapshot.capture(activeFileURL)) == revision else { return false } }
        let insertionPoint = feature == .recognizeDocument || feature == .voiceDraft
        let extraction = EditorTextExtractionRequest(documentID: selection.documentID, allowsTokenAtCaret: false, allowsWholeDocument: !insertionPoint, allowsInsertionPoint: insertionPoint)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        return extraction.result?.editorRevision == selection.editorRevision && extraction.result?.range == selection.range
    }
    func insert() {
        guard let selection, let feature = activeFeature, [.recognizeDocument, .voiceDraft, .mermaid].contains(feature), !report.isEmpty, !isResultStale else { return }
        guard isCurrent(generation) else { discardStale(generation); return }
        let replacement = feature == .mermaid ? "\n\n```mermaid\n\(report)\n```" : "\n\n" + report
        let request = EditorRangeReplacementRequest(documentID: selection.documentID, range: NSRange(location: NSMaxRange(selection.range), length: 0), originalText: "", replacementText: replacement, expectedEditorRevision: selection.editorRevision, actionName: feature.title)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        if !request.wasHandled { message = request.failureMessage ?? L10n.tr("编辑内容已变化，请重新执行转换") }
    }
    func copy() { guard !report.isEmpty else { return }; guard isCurrent(generation) else { discardStale(generation); return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string) }
    func referenceName(_ reference: AIContextReference) -> String {
        guard sources.indices.contains(reference.sourceIndex) else { return "" }
        return sources[reference.sourceIndex].name
    }
    func isOpenDocument(_ reference: AIContextReference) -> Bool {
        sources.indices.contains(reference.sourceIndex) && sources[reference.sourceIndex].document != nil
    }
    func openReference(_ reference: AIContextReference) {
        guard references.contains(reference), sources.indices.contains(reference.sourceIndex), let appState else { return }
        guard isCurrent(generation) else { discardStale(generation); return }
        AIContextService.reveal(sources[reference.sourceIndex], range: reference.range, appState: appState)
    }
    /// Остановка по кнопке: только прекращает запрос, входы остаются.
    func stop() { cancel(); if report.isEmpty { differences = "" } }
    func cancel() { generation += 1; task?.cancel(); task = nil; if recordingDocumentID != nil { discardRecording() }; isWorking = false }
    func clearResult() { cancel(); selection = nil; sources = []; fileRevision = nil; activeFeature = nil; activeProfile = nil; activeKey = nil; activeCheck = nil; activeOption = ""; activeInputs = []; activeFileURL = nil; report = ""; differences = ""; references = []; pendingSend = nil; sentSummary = nil; message = "" }
    func invalidate(documentID: UUID) { if recordingDocumentID == documentID || selection?.documentID == documentID || sources.contains(where: { $0.document?.id == documentID }) { clearResult() } }
    func selectedDocumentChanged() { clearResult() }
    func settingsChanged() {
        if let checkID, !checks.contains(where: { $0.id == checkID }) { self.checkID = nil }
        if (recordingDocumentID != nil && !isEnabled(.voiceDraft)) || (activeFeature != nil && !isCurrent(generation)) { clearResult() }
        objectWillChange.send()
    }
}
