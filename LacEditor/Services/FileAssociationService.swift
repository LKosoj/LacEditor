import AppKit
import UniformTypeIdentifiers

/// macOS associates content types, not a private per-extension preference.
/// Resolve the system's actual types and group aliases before offering a change.
struct FileAssociationFormat: Identifiable {
    let type: UTType
    let extensions: [String]
    var id: String { type.identifier }
    var title: String { extensions.map { "." + $0 }.joined(separator: "、") }
    var isText: Bool { type.isDynamic || type.conforms(to: .text) || type.conforms(to: .sourceCode) }

    static func catalog(extensions: [String] = supportedExtensions) -> [Self] {
        var result: [Self] = []
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext) else { continue }
            if let index = result.firstIndex(where: { $0.id == type.identifier }) {
                result[index] = Self(type: type, extensions: result[index].extensions + [ext])
            } else {
                result.append(Self(type: type, extensions: [ext]))
            }
        }
        return result
    }

    static let supportedExtensions = [
        "txt", "md", "markdown", "html", "htm", "json", "js", "mjs", "cjs",
        "ts", "tsx", "css", "py", "pyw", "swift", "sh", "bash", "zsh",
        "yaml", "yml", "c", "h", "cc", "cpp", "cxx", "hpp", "sql"
    ]
}

@MainActor
final class FileAssociationService: ObservableObject {
    struct ApplicationIdentity {
        let url: URL
        let identifier: String?
        let declaresAssociations: Bool

        var canSetDefaults: Bool {
            guard identifier == "com.laceditor.app", declaresAssociations else { return false }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let installed = ["/Applications/LacEditor.app",
                             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/LacEditor.app").path]
            return installed.contains(path)
        }

        static var current: Self {
            let bundle = Bundle.main
            let entries = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
            return Self(url: bundle.bundleURL, identifier: bundle.bundleIdentifier,
                        declaresAssociations: entries.contains { ($0["LSHandlerRank"] as? String) == "Alternate" })
        }
    }

    struct Client {
        var defaultApplication: (UTType) -> URL?
        var setDefault: (URL, UTType) async throws -> Void

        static var system: Self {
            Self(defaultApplication: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
                 setDefault: { app, type in
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                 })
        }
    }

    struct Row: Identifiable {
        let format: FileAssociationFormat
        let applicationURL: URL?
        let applicationName: String
        let isCurrentApplication: Bool
        var id: String { format.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var changingID: String?
    @Published private(set) var message: String?
    let identity: ApplicationIdentity
    private let formats: [FileAssociationFormat]
    private let client: Client

    init(identity: ApplicationIdentity = .current,
         formats: [FileAssociationFormat] = FileAssociationFormat.catalog(), client: Client = .system) {
        self.identity = identity
        self.formats = formats
        self.client = client
    }

    func refresh() {
        rows = formats.map { format in
            let url = client.defaultApplication(format.type)
            let current = url?.standardizedFileURL.resolvingSymlinksInPath()
                == identity.url.standardizedFileURL.resolvingSymlinksInPath()
            let name = url.map { url in
                let base = url.deletingPathExtension().lastPathComponent
                if Bundle(url: url)?.bundleIdentifier == "com.laceditor.app", !current {
                    return base + "（其他位置）"
                }
                return base
            } ?? "未设置"
            return Row(format: format, applicationURL: url, applicationName: name, isCurrentApplication: current)
        }
    }

    func setDefault(for id: String) async {
        guard changingID == nil, identity.canSetDefaults,
              let format = formats.first(where: { $0.id == id }), format.isText else { return }
        changingID = id
        message = nil
        defer { changingID = nil }
        do {
            try await client.setDefault(identity.url, format.type)
            refresh()
            if rows.first(where: { $0.id == id })?.isCurrentApplication == true {
                message = "已将 \(format.title) 的默认打开应用设为 LacEditor。"
            } else {
                message = "系统尚未应用更改，请确认系统提示后点击「刷新状态」。"
            }
        } catch {
            refresh()
            message = "未更改默认应用：\(error.localizedDescription)"
        }
    }
}
