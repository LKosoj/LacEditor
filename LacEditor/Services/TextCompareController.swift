import Combine
import Foundation

enum TextCompareError: Error { case tooLarge, closed }

/// Одна сторона сравнения (левая). Текст читается заново при каждом «Обновить».
struct TextCompareSource: Identifiable, Sendable {
    let id: String
    let name: String
    let isUnsaved: Bool
    let load: @Sendable () async throws -> String
}

enum TextCompareService {
    /// nil, если документ можно сравнивать; иначе текст отказа.
    @MainActor
    static func refusal(for document: EditorDocument) -> String? {
        document.isLargeFileMode ? L10n.tr("文本过大，无法比较") : nil
    }

    /// Источник из открытого документа: снимок на момент загрузки.
    @MainActor
    static func source(of document: EditorDocument) -> TextCompareSource {
        let sourceDocument = document
        return TextCompareSource(
            id: "doc:\(document.id.uuidString)",
            name: document.displayName,
            isUnsaved: document.isDirty || document.url == nil
        ) { [weak sourceDocument] in
            try await MainActor.run { [weak sourceDocument] in
                guard let sourceDocument else { throw TextCompareError.closed }
                guard !sourceDocument.isLargeFileMode else { throw TextCompareError.tooLarge }
                return sourceDocument.synchronizedSnapshot().text
            }
        }
    }

    /// Читает файл: UTF-8, иначе кодировка документа без угадывания; слишком большой файл не читается.
    nonisolated static func loadFileText(_ url: URL, fallback: String.Encoding, fallbackName: String) throws -> String {
        let size = try FileRevisionSnapshot.capture(url).fileSize ?? 0
        guard size <= DocumentPerformanceProfile.largeFileByteThreshold else { throw TextCompareError.tooLarge }
        let file: DecodedFile
        switch try FileService.prepareRead(url) {
        case .decoded(let decoded):
            file = decoded
        case .needsEncoding(let data, let byteCount, _):
            file = try FileService.decode(data, encoding: fallback, encodingName: fallbackName, byteCount: byteCount)
        }
        guard file.lineCount <= DocumentPerformanceProfile.largeFileLineThreshold else { throw TextCompareError.tooLarge }
        return file.text
    }

    @MainActor
    static func source(ofFile url: URL, fallback: String.Encoding, fallbackName: String) -> TextCompareSource {
        TextCompareSource(id: "file:\(url.path)", name: url.lastPathComponent, isUnsaved: false) {
            try await Task.detached(priority: .userInitiated) {
                try loadFileText(url, fallback: fallback, fallbackName: fallbackName)
            }.value
        }
    }
}

@MainActor
final class TextCompareController: ObservableObject {
    @Published private(set) var candidates: [TextCompareSource]
    @Published private(set) var source: TextCompareSource?
    @Published private(set) var changes: [AITextComparison.Change] = []
    @Published private(set) var hasResult = false
    @Published private(set) var isStale = false
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var messageKind: StatusKind = .info
    let currentName: String
    let currentIsUnsaved: Bool
    var canChooseFile: Bool { chooseFile != nil }

    private weak var document: EditorDocument?
    private let documentID: UUID
    private let initial: TextCompareSource?
    private let chooseFile: (@MainActor () -> TextCompareSource?)?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var observer: NSObjectProtocol?

    init(document: EditorDocument,
         candidates: [TextCompareSource],
         initial: TextCompareSource? = nil,
         chooseFile: (@MainActor () -> TextCompareSource?)? = nil) {
        self.document = document
        documentID = document.id
        self.candidates = candidates
        self.initial = initial
        self.chooseFile = chooseFile
        currentName = document.displayName
        currentIsUnsaved = document.isDirty || document.url == nil
        observer = NotificationCenter.default.addObserver(forName: EditorCommandNotification.documentContentDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? UUID == self.documentID, self.hasResult, !self.isStale else { return }
                self.markStale()
            }
        }
    }
    deinit { task?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }

    func start() {
        if let initial { run(initial) }
    }

    func select(_ id: String) {
        guard let next = candidates.first(where: { $0.id == id }) else { return }
        run(next)
    }

    func chooseFileTapped() {
        guard let next = chooseFile?() else { return }
        if !candidates.contains(where: { $0.id == next.id }) { candidates.append(next) }
        run(next)
    }

    func refresh() {
        if let source { run(source) }
    }

    func cancel() {
        task?.cancel()
        generation += 1
        isLoading = false
    }

    private func run(_ next: TextCompareSource) {
        guard let document else { return }
        task?.cancel()
        generation += 1
        let token = generation
        source = next
        clearResult()
        isLoading = true
        message = nil
        let snapshot = document.synchronizedSnapshot()
        task = Task { [weak self] in
            let outcome: Result<[AITextComparison.Change], Error>
            do {
                let left = try await next.load()
                let diff = await Task.detached(priority: .userInitiated) {
                    AITextComparison.changes(before: left, after: snapshot.text)
                }.value
                outcome = .success(diff)
            } catch {
                outcome = .failure(error)
            }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.isLoading = false
            guard let document = self.document, document.synchronizedSnapshot() == snapshot else {
                self.markStale()
                return
            }
            switch outcome {
            case .success(let diff):
                self.changes = diff
                self.hasResult = true
            case .failure(let error):
                self.post(self.errorText(error), .error)
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        if let error = error as? TextCompareError {
            switch error {
            case .tooLarge: return L10n.tr("文本过大，无法比较")
            case .closed: return L10n.tr("比较的文档已关闭")
            }
        }
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
    }

    private func markStale() {
        isStale = true
        post(L10n.tr("文档已更改，比较结果已过期"), .info)
    }

    private func post(_ text: String, _ kind: StatusKind) {
        message = text
        messageKind = kind
    }
}
