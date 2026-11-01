import CoreServices
import Foundation

/// Следит за файлами открытых документов и только отмечает в документе, что диск изменился.
/// Текст документа не трогается: перечитывание идёт по кнопке пользователя.
@MainActor
final class OpenFileWatcher {
    typealias Capture = @Sendable (URL) -> ExternalFileState?
    typealias SourceFactory = (_ paths: [String], _ handler: @escaping @Sendable ([FolderWorkspaceEvents.Event]) -> Void) -> FolderWorkspaceEvents?

    private let documents: () -> [EditorDocument]
    private let debounce: TimeInterval
    private let retry: TimeInterval
    private let capture: Capture
    private let makeSource: SourceFactory
    private var stream: FolderWorkspaceEvents?
    private var watchedDirectories: Set<String> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Разрешённый каталог файла считается один раз на адрес: события приходят пачками, а раскрытие ссылок идёт в файловую систему.
    private var parents: [UUID: (url: URL, path: String)] = [:]

    init(documents: @escaping () -> [EditorDocument],
         debounce: TimeInterval = 0.3,
         retry: TimeInterval = 0.5,
         capture: @escaping Capture = { url in OpenFileWatcher.captureOnDisk(url) },
         makeSource: @escaping SourceFactory = { FolderWorkspaceEvents(paths: $0, receive: $1) }) {
        self.documents = documents
        self.debounce = debounce
        self.retry = retry
        self.capture = capture
        self.makeSource = makeSource
    }

    deinit {
        stream?.stop()
        tasks.values.forEach { $0.cancel() }
    }

    /// Пересчитывает наблюдаемые каталоги; поток пересоздаётся, только если набор изменился.
    func refreshTargets() {
        let targets = trackedDocuments()
        let alive = Set(targets.map(\.id))
        for id in parents.keys where !alive.contains(id) { parents.removeValue(forKey: id) }
        for id in tasks.keys where !alive.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        let all = Set(targets.compactMap { parentPath(of: $0) })
        // Поток рекурсивен: каталог внутри другого наблюдаемого отдельно не нужен.
        let directories = all.filter { directory in
            !all.contains { other in
                other != directory && directory.hasPrefix(other == "/" ? "/" : other + "/")
            }
        }
        guard directories != watchedDirectories else { return }
        stream?.stop()
        stream = nil
        watchedDirectories = directories
        guard !directories.isEmpty else { return }
        stream = makeSource(directories.sorted()) { [weak self] events in
            Task { @MainActor [weak self] in self?.receive(events) }
        }
    }

    /// Активация приложения: проверка всех документов без пауз (покрывает сетевые диски без событий).
    func checkAll() {
        refreshTargets()
        for document in trackedDocuments() {
            Task { @MainActor [weak self] in await self?.checkNow(document) }
        }
    }

    func receive(_ events: [FolderWorkspaceEvents.Event]) {
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let targets = trackedDocuments()
        if events.contains(where: { $0.flags & rescan != 0 }) {
            targets.forEach { schedule($0, after: debounce) }
            return
        }
        for event in events {
            let eventParent = (event.path as NSString).deletingLastPathComponent
            for document in targets {
                guard let documentParent = parentPath(of: document) else { continue }
                if documentParent == eventParent || documentParent == event.path {
                    schedule(document, after: debounce)
                }
            }
        }
    }

    /// Одна проверка без паузы: результат применяется, только если документ за это время не изменился.
    func checkNow(_ document: EditorDocument) async {
        guard let url = document.url, let baseline = document.fileRevisionSnapshot, isTracked(document) else { return }
        switch document.ioState {
        case .idle: break
        case .saving, .opening:
            schedule(document, after: retry)
            return
        case .failed: return
        }
        let capture = capture
        let state = await Task.detached { capture(url) }.value
        // Отмена: появилась более новая задача или документ закрыт.
        guard !Task.isCancelled, isTracked(document) else { return }
        guard document.url == url, document.fileRevisionSnapshot == baseline, document.ioState == .idle else {
            schedule(document, after: retry)
            return
        }
        document.noteDiskState(state)
    }

    func stop() {
        stream?.stop()
        stream = nil
        watchedDirectories = []
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        parents.removeAll()
    }

    nonisolated static func captureOnDisk(_ url: URL) -> ExternalFileState? {
        do {
            return .present(try FileRevisionSnapshot.capture(url))
        } catch {
            let error = error as NSError
            switch error.domain {
            case NSCocoaErrorDomain where error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError:
                return .missing
            case NSPOSIXErrorDomain where error.code == Int(ENOENT) || error.code == Int(ENOTDIR):
                return .missing
            default:
                return nil
            }
        }
    }

    private func schedule(_ document: EditorDocument, after delay: TimeInterval) {
        tasks[document.id]?.cancel()
        tasks[document.id] = Task { @MainActor [weak self, weak document] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self, let document else { return }
            await self.checkNow(document)
        }
    }

    private func isTracked(_ document: EditorDocument) -> Bool {
        documents().contains { $0 === document }
    }

    /// Документы с файлом и известным состоянием на диске; заглушки без baseline пропускаются.
    private func trackedDocuments() -> [EditorDocument] {
        documents().filter { $0.url != nil && $0.fileRevisionSnapshot != nil }
    }

    /// Каталог файла с раскрытыми ссылками: FSEvents присылает именно такие пути.
    private func parentPath(of document: EditorDocument) -> String? {
        guard let url = document.url else { return nil }
        if let cached = parents[document.id], cached.url == url { return cached.path }
        let path = url.resolvingSymlinksInPath().deletingLastPathComponent().path
        parents[document.id] = (url, path)
        return path
    }
}
