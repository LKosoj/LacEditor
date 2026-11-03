import Combine
import Foundation

@MainActor
final class VersionHistoryController: ObservableObject {
    enum Mode { case history, disk, snapshots }

    let mode: Mode
    @Published private(set) var versions: [FileVersionInfo] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var changes: [AITextComparison.Change] = []
    @Published private(set) var hasResult = false
    @Published private(set) var isStale = false
    @Published private(set) var isLoading = false
    /// Режим «снимки», большой файл: различия не считаются, вернуть снимок можно.
    @Published private(set) var isDiffSkipped = false
    @Published private(set) var message: String?
    @Published private(set) var messageKind: StatusKind = .info
    var onRestored: (() -> Void)?
    /// Снимок, который надо выбрать после первой загрузки списка (режим «снимки»).
    var initialSelection: UUID?
    /// Кнопка «制作快照…» в листе; действие задаёт `AppState`.
    var onMakeSnapshot: (() -> Void)?

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
    private let fetchSnapshots: @Sendable () -> [DocumentSnapshotInfo]
    private let fetchSnapshotText: @Sendable (UUID) throws -> String
    private let renameSnapshotInStore: @Sendable (UUID, String) throws -> Void
    private let deleteSnapshotInStore: @Sendable (UUID) throws -> Void
    private var snapshotObserver: NSObjectProtocol?

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
         },
         fetchSnapshots: @escaping @Sendable () -> [DocumentSnapshotInfo] = { [] },
         fetchSnapshotText: @escaping @Sendable (UUID) throws -> String = { _ in throw DocumentSnapshotError.notFound },
         renameSnapshot: @escaping @Sendable (UUID, String) throws -> Void = { _, _ in throw DocumentSnapshotError.notFound },
         deleteSnapshot: @escaping @Sendable (UUID) throws -> Void = { _ in throw DocumentSnapshotError.notFound }) {
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
        self.fetchSnapshots = fetchSnapshots
        self.fetchSnapshotText = fetchSnapshotText
        renameSnapshotInStore = renameSnapshot
        deleteSnapshotInStore = deleteSnapshot
        if mode == .snapshots {
            // Снимок сделан из самого листа или другим окном: список обновляется.
            snapshotObserver = NotificationCenter.default.addObserver(forName: DocumentSnapshotStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isLoading else { return }
                    self.loadVersions(reselecting: self.selectedID)
                }
            }
        }
        observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.documentContentDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? UUID == self.documentID, self.hasResult, !self.isStale else { return }
                self.markStale()
            }
        }
    }
    deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let snapshotObserver { NotificationCenter.default.removeObserver(snapshotObserver) }
    }

    var canRestore: Bool {
        switch mode {
        case .history: restorableText != nil && !changes.isEmpty && !isStale && !isLoading
        case .snapshots: restorableText != nil && (!changes.isEmpty || isDiffSkipped) && !isStale && !isLoading
        case .disk: false
        }
    }

    func start() {
        switch mode {
        case .history, .snapshots: loadVersions(reselecting: nil)
        case .disk: compareWithDisk()
        }
    }

    func refresh() {
        guard let document else { return }
        base = document.synchronizedSnapshot()
        switch mode {
        case .history, .snapshots: loadVersions(reselecting: selectedID)
        case .disk: compareWithDisk()
        }
    }

    func select(_ id: String) {
        guard let info = versions.first(where: { $0.id == id }) else { return }
        selectedID = id
        if mode == .snapshots {
            guard let snapshotID = UUID(uuidString: id) else { return }
            run(isRestorable: true) { [fetchSnapshotText] in
                try await Task.detached(priority: .userInitiated) { try fetchSnapshotText(snapshotID) }.value
            }
            return
        }
        run(isRestorable: true) { [fetchText, encoding, encodingName] in
            try await fetchText(info, encoding, encodingName)
        }
    }

    func renameSnapshot(id: String, name: String) {
        guard mode == .snapshots, let snapshotID = UUID(uuidString: id) else { return }
        let rename = renameSnapshotInStore
        mutateSnapshots(reselecting: selectedID) { try rename(snapshotID, name) }
    }

    func deleteSnapshot(id: String) {
        guard mode == .snapshots, let snapshotID = UUID(uuidString: id),
              let position = versions.firstIndex(where: { $0.id == id }) else { return }
        // После удаления выбирается сосед; если удалён не выбранный снимок, выбор остаётся.
        var next = selectedID
        if selectedID == id {
            next = position + 1 < versions.count ? versions[position + 1].id : (position > 0 ? versions[position - 1].id : nil)
        }
        let delete = deleteSnapshotInStore
        mutateSnapshots(reselecting: next) { try delete(snapshotID) }
    }

    private func mutateSnapshots(reselecting id: String?, _ change: @escaping @Sendable () throws -> Void) {
        task?.cancel()
        generation += 1
        let token = generation
        isLoading = true
        message = nil
        task = Task { [weak self] in
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                do { try change(); return nil } catch { return error }
            }.value
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.loadVersions(reselecting: id)
            if let failure { self.post(self.errorText(failure), .error) }
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
        let isSnapshots = mode == .snapshots
        task = Task { [weak self, fetchVersions, fetchSnapshots, url] in
            let found: [FileVersionInfo]
            if isSnapshots {
                found = await Task.detached(priority: .userInitiated) {
                    fetchSnapshots().map {
                        FileVersionInfo(id: $0.id.uuidString, date: $0.date, computerName: nil, contentURL: url, title: $0.name)
                    }
                }.value
            } else {
                found = await fetchVersions(url)
            }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.isLoading = false
            self.versions = found
            let wanted = id ?? self.initialSelection?.uuidString
            self.initialSelection = nil
            if let wanted, found.contains(where: { $0.id == wanted }) {
                self.select(wanted)
            } else {
                self.selectedID = nil
                self.clearResult()
                if found.isEmpty { self.post(isSnapshots ? L10n.tr("还没有快照") : L10n.tr("没有可用的历史版本"), .info) }
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
        let skipsDiff = mode == .snapshots && (document?.isLargeFileMode ?? false)
        task = Task { [weak self] in
            let outcome: Result<(text: String, changes: [AITextComparison.Change]), Error>
            do {
                let text = try await load()
                var diff: [AITextComparison.Change] = []
                if !skipsDiff {
                    diff = await Task.detached(priority: .userInitiated) {
                        AITextComparison.changes(before: text, after: current)
                    }.value
                }
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
                self.isDiffSkipped = skipsDiff
                self.restorableText = isRestorable ? value.text : nil
                if skipsDiff { self.post(L10n.tr("文本过大，无法比较"), .info) }
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
        isDiffSkipped = false
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
