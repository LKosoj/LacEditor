import AppKit
import Foundation

/// Development maintenance only. Never launched by LacEditor or on login.
/// No global Launch Services reset and no changes to default handlers.
@main
struct FileAssociationMaintenance {
    struct Entry: Equatable {
        let path: String
        let identifier: String
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }
    static let registrar = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let identifiers: Set<String> = ["com.koslaceditor.app", "com.laceditor.acceptance", "com.laceditor.development",
                                           "com.laceditor.ui-experiment", "com.laceditor.native-tabs-experiment",
                                           "com.laceditor.local-verification"]
    static let installedURL = URL(fileURLWithPath: "/Applications/LacEditor.app")

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw Failure("\(executable): \(text)") }
        return text
    }

    static func parse(_ dump: String) -> [Entry] {
        var path: String?
        var entries: [Entry] = []
        for line in dump.components(separatedBy: .newlines) {
            if line.hasPrefix("bundle id:") { path = nil }
            if line.hasPrefix("path:") {
                var value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let suffix = value.range(of: " (0x", options: .backwards) { value = String(value[..<suffix.lowerBound]) }
                path = value
            }
            if line.hasPrefix("identifier:"), let path {
                let id = String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                if identifiers.contains(id), path.hasPrefix("/"), path.hasSuffix(".app") {
                    let entry = Entry(path: path, identifier: id)
                    if !entries.contains(entry) { entries.append(entry) }
                }
            }
        }
        return entries
    }

    static func inventory() throws -> [Entry] { parse(try run(registrar, ["-dump"])) }

    static func audit() throws {
        let entries = try inventory()
        for entry in entries {
            let state = FileManager.default.fileExists(atPath: entry.path) ? "存在" : "已不存在"
            print("\(entry.identifier) | \(state) | \(entry.path)")
        }
        print("共 \(entries.count) 个 LacEditor 登记。")
    }

    static func clean() throws {
        guard Bundle(url: installedURL)?.bundleIdentifier == "com.koslaceditor.app" else {
            throw Failure("未找到 /Applications/LacEditor.app 正式 App，停止处理。")
        }
        for entry in try inventory() where entry.path != installedURL.path {
            _ = try run(registrar, ["-u", entry.path])
            print("已撤销副本登记：\(entry.path)")
        }
        _ = try run(registrar, ["-f", installedURL.path])
        try verifyOpenWith()
        print("文件关联清理通过；未更改默认应用。系统仍可能保留没有文档关联的开发/验收 App 基本记录。")
    }

    /// A bundle record can survive/reappear without a document binding. Verify
    /// the actual Open With candidates rather than treating every record as one.
    static func verifyOpenWith() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("LacEditor-AssociationProbe-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        for ext in ["txt", "md", "markdown", "json", "html", "js", "py", "swift", "yaml", "css", "sql", "cpp"] {
            let file = directory.appendingPathComponent("probe.\(ext)")
            try Data().write(to: file)
            let candidates = NSWorkspace.shared.urlsForApplications(toOpen: file).filter {
                guard let id = Bundle(url: $0)?.bundleIdentifier else { return false }
                return identifiers.contains(id)
            }.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
            guard Set(candidates) == [installedURL.path] else {
                throw Failure(".\(ext) 的实际打开方式候选不符合预期：\(candidates)；请检查 --audit，未重置系统数据库。")
            }
            print(".\(ext)：仅 /Applications/LacEditor.app")
        }
    }

    static func unregisterBuild(_ path: String, root: URL) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let build = root.appendingPathComponent(".build").resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(build), url.pathExtension == "app" else { throw Failure("仅允许撤销本工程 .build 内的 App。") }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let id = Bundle(url: url)?.bundleIdentifier, identifiers.contains(id) else { throw Failure("构建不是 LacEditor。") }
        }
        guard try inventory().contains(where: { $0.path == url.path }) else {
            print("构建没有登记，无需撤销：\(url.path)")
            return
        }
        _ = try run(registrar, ["-u", url.path])
        print("已撤销构建登记：\(url.path)")
    }

    static func archiveHistory(root: URL) throws {
        let fm = FileManager.default
        let dist = root.appendingPathComponent("dist", isDirectory: true)
        let archives = dist.appendingPathComponent("Archives", isDirectory: true)
        let children = try fm.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil)
        for directory in children.sorted(by: { $0.path < $1.path }) {
            let app = directory.appendingPathComponent("LacEditor.app")
            guard directory.lastPathComponent.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                  fm.fileExists(atPath: app.path) else { continue }
            guard !((try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink ?? false),
                  !((try app.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink ?? false),
                  let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.koslaceditor.app",
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  version == directory.lastPathComponent,
                  build.range(of: #"^\d+$"#, options: .regularExpression) != nil else {
                throw Failure("历史 App 身份或路径校验失败：\(app.path)")
            }
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
            guard !running else { throw Failure("历史 App 正在运行，未归档：\(app.path)") }
            try fm.createDirectory(at: archives, withIntermediateDirectories: true)
            let zip = archives.appendingPathComponent("LacEditor-\(version)-\(build).zip")
            guard !fm.fileExists(atPath: zip.path) else { throw Failure("归档已存在，避免覆盖：\(zip.path)") }
            let staging = root.appendingPathComponent(".build/AssociationArchive-\(UUID()).noindex", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let stagedZip = staging.appendingPathComponent("archive.zip")
            _ = try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, stagedZip.path])
            _ = try run("/usr/bin/unzip", ["-tq", stagedZip.path])
            _ = try run("/usr/bin/ditto", ["-x", "-k", stagedZip.path, staging.path])
            let extracted = staging.appendingPathComponent("LacEditor.app")
            let files = ["Contents/Info.plist", "Contents/MacOS/LacEditor"]
            for file in files {
                guard try Data(contentsOf: app.appendingPathComponent(file)) == Data(contentsOf: extracted.appendingPathComponent(file)) else {
                    throw Failure("归档回读不一致：\(file)")
                }
            }
            try fm.moveItem(at: stagedZip, to: zip)
            _ = try run(registrar, ["-u", app.path])
            // Recoverable removal, only after ZIP integrity and contents match.
            var trashed: NSURL?
            try fm.trashItem(at: app, resultingItemURL: &trashed)
            print("历史 App 已归档：\(zip.path)；解压副本已移废纸篓：\(trashed?.path ?? "")")
        }
    }

    static func selfTest() throws {
        let sample = """
        bundle id: Example (0x1)
        path: /tmp/with spaces/LacEditor.app (0x42)
        identifier: com.koslaceditor.app
        bundle id: Other (0x2)
        path: /Applications/Other.app (0x43)
        identifier: com.example.other
        bundle id: LacEditor (0x3)
        path: /Applications/LacEditor.app (0x44)
        identifier: com.koslaceditor.app
        """
        guard parse(sample) == [Entry(path: "/tmp/with spaces/LacEditor.app", identifier: "com.koslaceditor.app"),
                                Entry(path: installedURL.path, identifier: "com.koslaceditor.app")] else { throw Failure("解析回归失败") }
        print("登记解析和精确身份过滤验证通过。")
    }

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("LacEditor.xcodeproj").path) else {
                throw Failure("请在 LacEditor 工程根目录运行。")
            }
            switch args {
            case [], ["--audit"]: try audit()
            case ["--clean"]: try clean()
            case ["--verify-open-with"]: try verifyOpenWith()
            case ["--archive-history"]: try archiveHistory(root: root)
            case ["--self-test"]: try selfTest()
            default:
                guard args.count == 2, args[0] == "--unregister-build" else {
                    throw Failure("用法：--audit | --clean | --verify-open-with | --archive-history | --unregister-build <App路径> | --self-test")
                }
                try unregisterBuild(args[1], root: root)
            }
        } catch { fputs("文件关联维护失败：\(error)\n", stderr); exit(1) }
    }
}
