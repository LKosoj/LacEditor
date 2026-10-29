import Foundation

@MainActor
final class RecentFilesStore: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var folderURLs: [URL] = []

    private let key = "recentFilePaths"
    private let foldersKey = "recentFolderPaths"
    private let maximumCount = 12
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: key) ?? []
        urls = paths.map(URL.init(fileURLWithPath:))
        folderURLs = (defaults.stringArray(forKey: foldersKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func recordFolder(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        folderURLs.removeAll { $0.path == url.path }
        folderURLs.insert(url, at: 0)
        folderURLs = Array(folderURLs.prefix(maximumCount))
        persistFolders()
    }

    func removeFolder(_ url: URL) {
        folderURLs.removeAll { $0.path == url.standardizedFileURL.resolvingSymlinksInPath().path }
        persistFolders()
    }

    func clearFolders() { folderURLs = []; persistFolders() }

    func restoreFolders(_ previous: [URL], ifUnchanged expected: [URL]) -> Bool {
        guard folderURLs == expected else { return false }
        folderURLs = previous
        persistFolders()
        return true
    }

    func replaceFolder(_ oldURL: URL, with newURL: URL) {
        let old = oldURL.standardizedFileURL.path
        folderURLs = folderURLs.map { $0.path == old ? newURL.standardizedFileURL : $0 }
        var seen: Set<String> = []
        folderURLs = folderURLs.filter { seen.insert($0.path).inserted }
        persistFolders()
    }

    private func persistFolders() { defaults.set(folderURLs.map(\.path), forKey: foldersKey) }

    func record(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(maximumCount))
        persist()
    }

    func clear() {
        urls = []
        persist()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persist()
    }

    func restore(_ previous: [URL], ifUnchanged expected: [URL]) -> Bool {
        guard urls == expected else { return false }
        urls = previous
        persist()
        return true
    }

    func replace(_ oldURL: URL, with newURL: URL) {
        let oldURL = oldURL.standardizedFileURL
        let newURL = newURL.standardizedFileURL
        urls = urls.map {
            $0.standardizedFileURL == oldURL ? newURL : $0
        }
        var seen: Set<URL> = []
        urls = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        persist()
    }

    private func persist() {
        defaults.set(urls.map(\.path), forKey: key)
    }
}
