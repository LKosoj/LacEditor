import Combine
import Foundation

@MainActor
final class VersionHistoryController: ObservableObject {
    enum Mode { case history, disk }

    let mode: Mode
    @Published private(set) var versions: [FileVersionInfo] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var changes: [AITextComparison.Change] = []
    @Published private(set) var hasResult = false
    @Published private(set) var isStale = false
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var messageKind: StatusKind = .info
    var onRestored: (() -> Void)?

    private weak var document: EditorDocument?
    private let documentID: UUID
    private let url: URL
    private let encoding: String.Encoding
    private let encodingName: String
    private var base: DocumentTextSnapshot
    private var restorableText: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var observer: NSObjectProtocol?
    private let fetchVersions: @Sendable (URL) async -> [FileVersionInfo]
    private let fetchText: @Sendable (FileVersionInfo, String.Encoding, String) async throws -> String
    private let fetchDisk: @Sendable (URL, String.Encoding, String) async throws -> String
    private let apply: (String, DocumentTextSnapshot) -> String?

    init(document: EditorDocument,
         url: URL,
         mode: Mode,
         apply: @escaping (String, DocumentTextSnapshot) -> String?,
         fetchVersions: @escaping @Sendable (URL) async -> [FileVersionInfo] = { url in
             await Task.detached(priority: .userInitiated) { FileVersionService.versions(of: url) }.value
         },
         fetchText: @escaping @Sendable (FileVersionInfo, String.Encoding, String) async throws -> String = { info, encoding, name in
             try await Task.detached(priority: .userInitiated) {
                 try FileVersionService.loadText(info, encoding: encoding, encodingName: name)
             }.value
         },
         fetchDisk: @escaping @Sendable (URL, String.Encoding, String) async throws -> String = { url, encoding, name in
             try await Task.detached(priority: .userInitiated) {
                 try FileVersionService.loadDiskText(at: url, encoding: encoding, encodingName: name)
             }.value
         }) {
        self.document = document
        documentID = document.id
        self.url = url
        self.mode = mode
        encoding = document.fileEncoding
        encodingName = document.encodingName
        base = document.synchronizedSnapshot()
        self.apply = apply
        self.fetchVersions = fetchVersions
        self.fetchText = fetchText
        self.fetchDisk = fetchDisk
        observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.documentContentDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? UUID == self.documentID, self.hasResult, !self.isStale else { return }
                self.markStale()
            }
        }
    }
    deinit { task?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }

    var canRestore: Bool { mode == .history && restorableText != nil && !changes.isEmpty && !isStale && !isLoading }

    func start() {
        switch mode {
        case .history: loadVersions(reselecting: nil)
        case .disk: compareWithDisk()
        }
    }

    func refresh() {
        guard let document else { return }
        base = document.synchronizedSnapshot()
        switch mode {
        case .history: loadVersions(reselecting: selectedID)
        case .disk: compareWithDisk()
        }
    }

    func select(_ id: String) {
        guard let info = versions.first(where: { $0.id == id }) else { return }
        selectedID = id
        run(isRestorable: true) { [fetchText, encoding, encodingName] in
            try await fetchText(info, encoding, encodingName)
        }
    }

    func restore() {
        guard canRestore, let document, let text = restorableText else { return }
        guard document.synchronizedSnapshot() == base else { markStale(); return }
        if let failure = apply(text, base) {
            post(failure, .error)
        } else {
            onRestored?()
        }
    }

    func cancel() {
        task?.cancel()
        generation += 1
        isLoading = false
    }

    private func compareWithDisk() {
        run(isRestorable: false) { [fetchDisk, url, encoding, encodingName] in
            try await fetchDisk(url, encoding, encodingName)
        }
    }

    private func loadVersions(reselecting id: String?) {
        task?.cancel()
        generation += 1
        let token = generation
        isLoading = true
        message = nil
        task = Task { [weak self, fetchVersions, url] in
            let found = await fetchVersions(url)
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.isLoading = false
            self.versions = found
            if let id, found.contains(where: { $0.id == id }) {
                self.select(id)
            } else {
                self.selectedID = nil
                self.clearResult()
                if found.isEmpty { self.post(L10n.tr("没有可用的历史版本"), .info) }
            }
        }
    }

    private func run(isRestorable: Bool, load: @escaping @Sendable () async throws -> String) {
        task?.cancel()
        generation += 1
        let token = generation
        clearResult()
        isLoading = true
        message = nil
        let current = base.text
        task = Task { [weak self] in
            let outcome: Result<(text: String, changes: [AITextComparison.Change]), Error>
            do {
                let text = try await load()
                let diff = await Task.detached(priority: .userInitiated) {
                    AITextComparison.changes(before: text, after: current)
                }.value
                outcome = .success((text, diff))
            } catch {
                outcome = .failure(error)
            }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.isLoading = false
            guard let document = self.document, document.url == self.url,
                  document.synchronizedSnapshot() == self.base else {
                self.markStale()
                return
            }
            switch outcome {
            case .success(let value):
                self.changes = value.changes
                self.hasResult = true
                self.restorableText = isRestorable ? value.text : nil
            case .failure(let error):
                self.post(self.errorText(error), .error)
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        if case FileServiceError.unsupportedEncoding = error { return L10n.tr("无法按文档编码解码该内容") }
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile {
            return L10n.tr("磁盘上找不到该文件")
        }
        return error.localizedDescription
    }

    private func clearResult() {
        changes = []
        hasResult = false
        isStale = false
        restorableText = nil
    }

    private func markStale() {
        isStale = true
        restorableText = nil
        post(L10n.tr("文档已更改，比较结果已过期"), .info)
    }

    private func post(_ text: String, _ kind: StatusKind) {
        message = text
        messageKind = kind
    }
}
