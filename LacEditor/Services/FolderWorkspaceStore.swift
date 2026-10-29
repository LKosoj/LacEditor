import Combine
import CoreServices
import Foundation

private final class FolderWorkspaceEvents: @unchecked Sendable {
    struct Event: Sendable { let path: String; let flags: FSEventStreamEventFlags }
    private var stream: FSEventStreamRef?
    private let receive: @Sendable ([Event]) -> Void

    init?(root: URL, receive: @escaping @Sendable ([Event]) -> Void) {
        self.receive = receive
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<FolderWorkspaceEvents>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                guard let pointer else { return }
                Unmanaged<FolderWorkspaceEvents>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<FolderWorkspaceEvents>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            guard paths.count == count else { return }
            owner.receive(paths.indices.map { Event(path: paths[$0], flags: flags[$0]) })
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.laceditor.folder-events", qos: .utility))
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
    deinit { stop() }
}

struct FolderWorkspaceEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    var creationDate: Date? = nil
    var modificationDate: Date? = nil

    var id: URL { url }
}

@MainActor
final class FolderWorkspaceStore: ObservableObject {
    enum Sort: String, CaseIterable { case name, natural, created, modified }
    enum Display: String, CaseIterable { case tree, list }
    @Published private(set) var rootURL: URL?
    @Published private(set) var entries: [URL: [FolderWorkspaceEntry]] = [:]
    @Published private(set) var listEntries: [FolderWorkspaceEntry] = []
    @Published private(set) var loading: Set<URL> = []
    @Published private(set) var errors: [URL: String] = [:]
    @Published private(set) var expanded: Set<URL> = []
    @Published private(set) var sort: Sort = .natural
    @Published private(set) var sortAscending: Bool?
    @Published private(set) var groupByFolder = true
    var ascending: Bool { sortAscending ?? (sort == .name || sort == .natural) }
    @Published private(set) var display: Display = .tree
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var watchError: String?
    @Published private(set) var notice: String?

    private let enumerate: @Sendable (URL, URL) throws -> [FolderWorkspaceEntry]
    private let enumerateList: @Sendable (URL, @Sendable () -> Bool) throws -> FolderSearchService.Result<FolderSearchService.ListedFile>
    private var generation: UInt = 0
    private var requests: [URL: UUID] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var watcher: FolderWorkspaceEvents?
    private var rootIdentity: WorkspaceNodeIdentity?
    private var restorationGeneration: UInt = 0
    private var pendingExpandedPaths: [[String]] = []

    deinit { watcher?.stop() }

    init(enumerate: @escaping @Sendable (URL, URL) throws -> [FolderWorkspaceEntry] = FolderWorkspaceStore.readDirectory,
         enumerateList: @escaping @Sendable (URL, @Sendable () -> Bool) throws -> FolderSearchService.Result<FolderSearchService.ListedFile> = { root, cancelled in
             try FolderSearchService.listing(root: root, isCancelled: cancelled)
         }) {
        self.enumerate = enumerate
        self.enumerateList = enumerateList
    }

    @discardableResult
    func setRoot(_ url: URL?) -> Task<Void, Never>? {
        watcher?.stop()
        watcher = nil
        rootIdentity = nil
        watchError = nil
        notice = nil
        restorationGeneration &+= 1
        pendingExpandedPaths = []
        generation &+= 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        requests.removeAll()
        entries.removeAll()
        listEntries.removeAll()
        loading.removeAll()
        errors.removeAll()
        expanded.removeAll()
        rootURL = url.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        currentDirectory = rootURL
        guard let rootURL else { return nil }
        expanded.insert(rootURL)
        return display == .list ? loadList() : load(rootURL)
    }

    @discardableResult
    func expand(_ url: URL) -> Task<Void, Never>? {
        restorationGeneration &+= 1
        return expandNode(url)
    }

    @discardableResult
    private func expandNode(_ url: URL) -> Task<Void, Never>? {
        let directory = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        guard directory == rootURL || entries.values.contains(where: { children in
            children.contains { $0.url == directory && $0.isDirectory && !$0.isSymbolicLink }
        }) else { return nil }
        expanded.insert(directory)
        return load(directory)
    }

    func collapse(_ url: URL) {
        restorationGeneration &+= 1
        let directory = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        guard directory != rootURL, expanded.contains(directory) else { return }
        removeBranch(directory)
    }

    func refresh() {
        guard rootURL != nil else { return }
        if display == .list { _ = loadList(); return }
        let active = display == .tree ? expanded : Set(currentDirectory.map { [$0] } ?? [])
        for directory in active { load(directory) }
    }

    func setSort(_ value: Sort) {
        guard value != sort else { return }
        restorationGeneration &+= 1
        sort = value
        refresh()
    }

    func setAscending(_ value: Bool) {
        guard sortAscending != value else { return }
        restorationGeneration &+= 1
        sortAscending = value
        refresh()
    }

    func setGroupByFolder(_ value: Bool) {
        guard groupByFolder != value else { return }
        restorationGeneration &+= 1
        groupByFolder = value
        refresh()
    }

    func setDisplay(_ value: Display) {
        guard value != display else { return }
        restorationGeneration &+= 1
        display = value
        refresh()
        if value == .tree, let root = rootURL, !pendingExpandedPaths.isEmpty {
            let paths = pendingExpandedPaths
            pendingExpandedPaths = []
            let token = restorationGeneration, rootGeneration = generation
            let rootTask = tasks[root]
            Task { [weak self] in
                await rootTask?.value
                await self?.restoreExpanded(paths, root: root, generation: rootGeneration, token: token)
            }
        }
    }

    @discardableResult
    func showDirectory(_ url: URL) -> Task<Void, Never>? {
        restorationGeneration &+= 1
        return showDirectoryNode(url)
    }

    @discardableResult
    private func showDirectoryNode(_ url: URL) -> Task<Void, Never>? {
        let directory = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        guard directory == rootURL || entries.values.contains(where: { $0.contains { $0.url == directory && $0.isDirectory && !$0.isSymbolicLink } }) else { return nil }
        currentDirectory = directory
        notice = nil
        return load(directory)
    }

    var sessionState: FolderWorkspaceSession? {
        guard let root = rootURL else { return nil }
        let base = root.standardizedFileURL.pathComponents
        func relative(_ url: URL) -> [String]? {
            let parts = url.standardizedFileURL.pathComponents
            guard parts.starts(with: base) else { return nil }
            return Array(parts.dropFirst(base.count))
        }
        return FolderWorkspaceSession(rootPath: root.path,
            expandedPaths: Array(Set(expanded.compactMap(relative).filter { !$0.isEmpty } + pendingExpandedPaths))
                .sorted { $0.lexicographicallyPrecedes($1) },
            sort: sort.rawValue, view: display.rawValue,
            currentPath: currentDirectory.flatMap(relative) ?? [], ascending: sortAscending, groupByFolder: groupByFolder)
    }

    func restore(_ session: FolderWorkspaceSession) {
        guard session.rootPath.hasPrefix("/") else { _ = setRoot(nil); return }
        sort = Sort(rawValue: session.sort) ?? .natural
        sortAscending = session.ascending
        groupByFolder = session.groupByFolder ?? true
        display = Display(rawValue: session.view) ?? .tree
        let root = URL(fileURLWithPath: session.rootPath, isDirectory: true).standardizedFileURL
        guard let first = setRoot(root) else { return }
        let expectedGeneration = generation
        let token = restorationGeneration
        func valid(_ parts: [String]) -> Bool {
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }
        }
        if display == .list {
            pendingExpandedPaths = session.expandedPaths.filter(valid)
            if valid(session.currentPath) { currentDirectory = session.currentPath.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) } }
        }
        Task { [weak self] in
            await first.value
            guard let self, self.generation == expectedGeneration, self.restorationGeneration == token, self.rootURL == root else { return }
            if self.display == .tree {
                await self.restoreExpanded(session.expandedPaths.filter(valid), root: root, generation: expectedGeneration, token: token)
            }
        }
    }

    private func restoreExpanded(_ paths: [[String]], root: URL, generation: UInt, token: UInt) async {
        for parts in paths.sorted(by: { $0.count < $1.count }) {
            guard self.generation == generation, restorationGeneration == token, rootURL == root, display == .tree else { return }
            let url = parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            if let task = expandNode(url) { await task.value }
        }
    }

    private nonisolated static func ordered(_ first: FolderWorkspaceEntry, _ second: FolderWorkspaceEntry, sort: Sort, ascending: Bool, nameAscending: Bool, groupByFolder: Bool) -> Bool {
        let firstFolder = first.isDirectory && !first.isSymbolicLink
        let secondFolder = second.isDirectory && !second.isSymbolicLink
        if groupByFolder && firstFolder != secondFolder { return firstFolder }
        if sort == .created || sort == .modified {
            let a = sort == .created ? first.creationDate : first.modificationDate
            let b = sort == .created ? second.creationDate : second.modificationDate
            if a != b {
                if let a, let b { return ascending ? a < b : a > b }
                return a != nil
            }
        }
        let order = sort == .name ? first.name.localizedCompare(second.name) : first.name.localizedStandardCompare(second.name)
        if order != .orderedSame { return nameAscending ? order == .orderedAscending : order == .orderedDescending }
        return first.url.path < second.url.path
    }

    @discardableResult
    private func loadList() -> Task<Void, Never>? {
        guard let root = rootURL, display == .list else { return nil }
        tasks[root]?.cancel()
        let request = UUID(), expectedGeneration = generation, expectedIdentity = rootIdentity
        let sort = sort, ascending = ascending, nameAscending = sortAscending ?? true, grouped = groupByFolder, read = enumerateList
        requests[root] = request
        loading.insert(root)
        errors.removeValue(forKey: root)
        tasks[root] = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                Result {
                    let identity = try Self.identity(root)
                    if let expectedIdentity, expectedIdentity != identity { throw CocoaError(.fileReadNoPermission) }
                    let listing = try read(root, { Task.isCancelled })
                    var values = listing.values.map { item in
                        FolderWorkspaceEntry(url: item.file.url, name: item.file.url.lastPathComponent, isDirectory: false,
                            isSymbolicLink: item.isSymbolicLink, creationDate: item.creationDate, modificationDate: item.modificationDate)
                    }
                    values.sort { first, second in
                        if grouped {
                            let a = first.url.deletingLastPathComponent().path, b = second.url.deletingLastPathComponent().path
                            if a != b {
                                let order = a.localizedStandardCompare(b)
                                return order == .orderedSame ? a < b : order == .orderedAscending
                            }
                        }
                        return Self.ordered(first, second, sort: sort, ascending: ascending, nameAscending: nameAscending, groupByFolder: false)
                    }
                    guard !Task.isCancelled else { throw CancellationError() }
                    guard try Self.identity(root) == identity else { throw CocoaError(.fileReadNoPermission) }
                    return (values, listing.problems, identity)
                }
            }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, self.rootURL == root, self.generation == expectedGeneration, self.display == .list, self.requests[root] == request else { return }
            self.requests.removeValue(forKey: root)
            self.tasks.removeValue(forKey: root)
            self.loading.remove(root)
            switch result {
            case let .success((values, problems, identity)):
                if self.rootIdentity == nil { self.rootIdentity = identity }
                if self.watcher == nil { self.startWatcher(root: root, generation: expectedGeneration) }
                self.listEntries = values
                self.notice = problems.isEmpty ? nil : L10n.tr("部分文件夹无法读取")
            case let .failure(error):
                if !(error is CancellationError) { self.errors[root] = error.localizedDescription }
            }
        }
        return tasks[root]
    }

    @discardableResult
    private func load(_ directory: URL) -> Task<Void, Never>? {
        guard let root = rootURL, (display == .tree ? expanded.contains(directory) : currentDirectory == directory) else { return nil }
        tasks[directory]?.cancel()
        let request = UUID(), expectedGeneration = generation, read = enumerate, sort = sort, ascending = ascending, nameAscending = sortAscending ?? true, groupByFolder = groupByFolder, expectedRootIdentity = rootIdentity
        requests[directory] = request
        loading.insert(directory)
        errors.removeValue(forKey: directory)
        tasks[directory] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let before = try Self.identity(root)
                    if let expectedRootIdentity, expectedRootIdentity != before { throw CocoaError(.fileReadNoPermission) }
                    let children = try read(root, directory).sorted { first, second in
                        Self.ordered(first, second, sort: sort, ascending: ascending, nameAscending: nameAscending, groupByFolder: groupByFolder)
                    }
                    guard try Self.identity(root) == before else { throw CocoaError(.fileReadNoPermission) }
                    return (children, before)
                }
            }.value
            guard let self, self.rootURL == root, self.generation == expectedGeneration,
                  (self.display == .tree ? self.expanded.contains(directory) : self.currentDirectory == directory), self.requests[directory] == request else { return }
            self.requests.removeValue(forKey: directory)
            self.tasks.removeValue(forKey: directory)
            self.loading.remove(directory)
            switch result {
            case let .success((children, identity)):
                if self.rootIdentity == nil { self.rootIdentity = identity }
                let needsWatcher = self.watcher == nil
                if needsWatcher { self.startWatcher(root: root, generation: expectedGeneration) }
                self.entries[directory] = children
                let childDirectories = Set(children.filter { $0.isDirectory && !$0.isSymbolicLink }.map(\.url))
                let removed = self.expanded.filter { child in
                    child != root && child.deletingLastPathComponent() == directory && !childDirectories.contains(child)
                }
                for child in removed { self.removeBranch(child) }
                if needsWatcher, self.watcher != nil {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.rootURL == root, self.generation == expectedGeneration else { return }
                        self.refresh()
                    }
                }
            case let .failure(error):
                self.entries.removeValue(forKey: directory)
                self.errors[directory] = error.localizedDescription
                let children = self.expanded.filter { $0 != directory && Self.isDescendant($0, of: directory) }
                for child in children { self.removeBranch(child) }
                if self.display == .list, self.currentDirectory == directory, directory != root {
                    self.currentDirectory = directory.deletingLastPathComponent()
                    self.notice = L10n.tr("文件夹不可用，已返回上级")
                    self.load(directory.deletingLastPathComponent())
                }
            }
        }
        return tasks[directory]
    }

    nonisolated private static func identity(_ url: URL) throws -> WorkspaceNodeIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { throw CocoaError(.fileReadUnknown) }
        return WorkspaceNodeIdentity(device: device, inode: inode)
    }

    private func startWatcher(root: URL, generation: UInt) {
        watcher = FolderWorkspaceEvents(root: root) { [weak self] events in
            Task { @MainActor [weak self] in self?.receive(events, root: root, generation: generation) }
        }
        watchError = watcher == nil ? L10n.tr("无法自动监视文件夹") : nil
    }

    private func receive(_ events: [FolderWorkspaceEvents.Event], root: URL, generation: UInt) {
        guard rootURL == root, self.generation == generation else { return }
        if display == .list { _ = loadList(); return }
        let full = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        if events.contains(where: { $0.flags & full != 0 }) { refresh(); return }
        let active = display == .tree ? expanded : Set(currentDirectory.map { [$0] } ?? [])
        var affected: Set<URL> = []
        for event in events {
            let url = URL(fileURLWithPath: event.path).standardizedFileURL
            let parent = url.deletingLastPathComponent()
            for directory in active where directory.standardizedFileURL.pathComponents == parent.pathComponents || directory.standardizedFileURL.pathComponents == url.pathComponents {
                affected.insert(directory)
            }
        }
        for directory in affected { load(directory) }
    }

    private func removeBranch(_ directory: URL) {
        let affected = Set(expanded.filter { $0 == directory || Self.isDescendant($0, of: directory) })
        for child in affected {
            tasks.removeValue(forKey: child)?.cancel()
            requests.removeValue(forKey: child)
            loading.remove(child)
            errors.removeValue(forKey: child)
            entries.removeValue(forKey: child)
            expanded.remove(child)
        }
    }

    private static func isDescendant(_ url: URL, of parent: URL) -> Bool {
        let path = url.standardizedFileURL.pathComponents
        let base = parent.standardizedFileURL.pathComponents
        return path.count > base.count && path.starts(with: base)
    }

    nonisolated private static func readDirectory(_ root: URL, _ url: URL) throws -> [FolderWorkspaceEntry] {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { throw CocoaError(.fileReadNoPermission) }
        let freshRoot = URL(fileURLWithPath: root.path, isDirectory: false)
        let rootValues = try freshRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { throw CocoaError(.fileReadNoPermission) }
        var current = root
        for component in components.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            let fresh = URL(fileURLWithPath: current.path, isDirectory: false)
            let values = try fresh.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw CocoaError(.fileReadNoPermission) }
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [])
            .map { child in
                let values = try child.resourceValues(forKeys: keys)
                let link = values.isSymbolicLink == true
                let directory = values.isDirectory == true && !link
                return FolderWorkspaceEntry(url: URL(fileURLWithPath: child.path, isDirectory: directory), name: child.lastPathComponent,
                                            isDirectory: directory, isSymbolicLink: link,
                                            creationDate: values.creationDate, modificationDate: values.contentModificationDate)
            }
    }
}
