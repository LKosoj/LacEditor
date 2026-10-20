import Foundation

@MainActor
final class RecentFilesStore: ObservableObject {
    @Published private(set) var urls: [URL] = []

    private let key = "recentFilePaths"
    private let maximumCount = 12
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: key) ?? []
        urls = paths.map(URL.init(fileURLWithPath:))
    }

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
