import AppKit
import ApplicationServices

/// Runs two real, acceptance-identified App bundles against one temporary home.
/// Neither the installed App nor the user's preferences/workspace are touched.
@main
struct ReleaseCandidateVerification {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    static let identifier = "com.laceditor.acceptance"

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func elements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 24 else { return [] }
        return [element] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .flatMap { elements($0, depth: depth + 1) }
    }
    static func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute) as? String ?? ""
    }
    static func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    static func editor(_ app: NSRunningApplication) throws -> AXUIElement {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focused = attribute(application, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        let candidates = focused.map { [$0] } ?? windows(app)
        guard let result = candidates.flatMap({ elements($0) }).first(where: {
            attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole
        }) else { throw Failure("missing editor") }
        return result
    }
    static func key(_ code: CGKeyCode, pid: pid_t, flags: CGEventFlags = .maskCommand) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }
    static func insert(_ text: String, app: NSRunningApplication) throws {
        let area = try editor(app)
        AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let units = Array(text.utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            units.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!) }
            event?.postToPid(app.processIdentifier)
        }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }
    @MainActor
    static func wait(_ label: String, seconds: Double = 8, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure("timeout: \(label)")
    }
    @MainActor
    static func launch(_ url: URL, home: URL) async throws -> NSRunningApplication {
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty, "acceptance App already running")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["CFFIXED_USER_HOME": home.path]
        configuration.activates = true
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try require(app.bundleURL?.standardizedFileURL == url.standardizedFileURL, "wrong bundle launched")
        do {
            try await wait("first editor") { (try? editor(app)) != nil }
        } catch {
            print("Launch failed for \(url.path), PID=\(app.processIdentifier), windows=\(windows(app).count)")
            for element in windows(app).flatMap({ elements($0) }) {
                print("AX \(attribute(element, kAXRoleAttribute) ?? "" as CFString) title=\(title(element)) description=\(attribute(element, kAXDescriptionAttribute) ?? "" as CFString)")
            }
            if !app.isTerminated { _ = app.forceTerminate() }
            throw error
        }
        try await Task.sleep(for: .milliseconds(500))
        return app
    }
    @MainActor
    static func open(_ file: URL, in appURL: URL, app: NSRunningApplication) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let result = try await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration)
        try require(result.processIdentifier == app.processIdentifier && !app.isTerminated, "Finder open restarted App")
        try await wait("Finder file \(file.lastPathComponent)") {
            windows(app).contains { title($0).contains(file.lastPathComponent) }
        }
        try await Task.sleep(for: .milliseconds(300))
    }
    @MainActor
    static func quit(_ app: NSRunningApplication) async throws {
        key(12, pid: app.processIdentifier)
        try await wait("graceful workspace exit", seconds: 12) {
            if app.isTerminated { return true }
            let button = windows(app).flatMap { elements($0) }.first { title($0) == "保留并退出" }
            if let button { AXUIElementPerformAction(button, kAXPressAction as CFString) }
            return false
        }
    }
    static func snapshot(_ support: URL) throws -> (documents: [[String: Any]], texts: [String]) {
        let root = support.appendingPathComponent("Workspace")
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("CurrentWorkspace.json"))) as! [String: String]
        let folder = root.appendingPathComponent("Workspace-" + marker["workspaceID"]!.lowercased())
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Manifest.json"))) as! [String: Any]
        try require(manifest["version"] as? Int == 1, "workspace schema changed")
        let documents = (manifest["windows"] as! [[String: Any]]).flatMap { $0["documents"] as! [[String: Any]] }
        let texts = try documents.map { try String(contentsOf: folder.appendingPathComponent($0["contentFileName"] as! String), encoding: .utf8) }
        return (documents, texts)
    }
    static func preferences(_ home: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: home.appendingPathComponent("Library/Preferences/\(identifier).plist")), format: nil) as! [String: Any]
    }
    static func visibleEditorCount(_ app: NSRunningApplication) -> Int {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return infos.filter {
            guard $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  $0[kCGWindowLayer as String] as? Int == 0,
                  let bounds = $0[kCGWindowBounds as String] as? [String: Double] else { return false }
            return bounds["Width", default: 0] > 500 && bounds["Height", default: 0] > 350
        }.count
    }
    static func pressMenu(_ app: NSRunningApplication, matching predicate: (String) -> Bool) throws {
        guard let menu = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute),
              let item = elements(menu as! AXUIElement).first(where: { predicate(title($0)) }),
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw Failure("native window menu action missing")
        }
    }
    @MainActor
    static func main() async {
        do { try await verify() }
        catch { fputs("RC verification failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor
    static func verify() async throws {
        guard CommandLine.arguments.count == 3, AXIsProcessTrusted() else { throw Failure("usage: verifier baseline.app candidate.app; Accessibility required") }
        let baselineURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let candidateURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        for url in [baselineURL, candidateURL] {
            try require(Bundle(url: url)?.bundleIdentifier == identifier, "only acceptance bundles permitted")
        }
        try require(Bundle(url: baselineURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.14.4", "baseline is not 0.14.4")
        try require(Bundle(url: candidateURL)?.object(forInfoDictionaryKey: "LacEditorReleaseStage") as? String == "RC1", "not RC1")
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("LacEditor-RC1-\(UUID())")
        let support = home.appendingPathComponent("Library/Application Support/LacEditor-Acceptance")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer { _ = previousApp?.activate(options: []) }
        let note = home.appendingPathComponent("升级保留.txt")
        let other = home.appendingPathComponent("访达打开.md")
        try "旧版磁盘内容\n".write(to: note, atomically: true, encoding: .utf8)
        try "# 访达文件\n\n正文\n".write(to: other, atomically: true, encoding: .utf8)
        let libraryURL = support.appendingPathComponent("SidebarLibrary.json")
        let library: [String: Any] = [
            "favoritePaths": [note.path],
            "groups": [["id": UUID().uuidString, "name": "升级验证分组", "isExpanded": true, "paths": [note.path]]],
            "favoriteSectionExpanded": true, "groupsSectionExpanded": true, "recentSectionExpanded": true
        ]
        let libraryData = try JSONSerialization.data(withJSONObject: library, options: .sortedKeys)
        try libraryData.write(to: libraryURL)
        let seeded: [String: Any] = ["editorFontSize": 17.0, "editorLineSpacing": 7.0, "editorTabWidth": 8,
                                   "isWordWrapEnabled": false, "appTheme": "跟随系统", "recentFilePaths": [note.path],
                                   "workspaceExitBehavior": "preserveWorkspace", "hasConfirmedWorkspaceExitPrompt": true]
        let prefsURL = home.appendingPathComponent("Library/Preferences/\(identifier).plist")
        try fm.createDirectory(at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: seeded, format: .xml, options: 0).write(to: prefsURL)

        var running: NSRunningApplication?
        defer { if let running, !running.isTerminated { _ = running.forceTerminate() } }
        let baseline = try await launch(baselineURL, home: home)
        running = baseline
        let draft = "RC1 unsaved draft 旧版未保存内容 123"
        try insert(draft, app: baseline)
        try await wait("baseline draft input") { (try? attribute(editor(baseline), kAXValueAttribute) as? String)?.contains(draft) == true }
        try await open(note, in: baselineURL, app: baseline)
        try await quit(baseline)
        let oldSnapshot = try snapshot(support)
        try require(oldSnapshot.texts.contains(draft), "old App did not persist draft")
        try require(oldSnapshot.documents.contains { $0["sourcePath"] as? String == note.path }, "old App did not persist disk tab")
        print("BASELINE 0.14.4 saved \(oldSnapshot.documents.count) tabs, including unsaved draft")

        let candidate = try await launch(candidateURL, home: home)
        running = candidate
        do {
            try await wait("restored sidebar") {
                windows(candidate).flatMap { elements($0) }.contains {
                    let text = title($0) + (attribute($0, kAXDescriptionAttribute) as? String ?? "")
                        + (attribute($0, kAXValueAttribute) as? String ?? "")
                    return text.contains("升级验证分组")
                }
            }
        } catch {
            for element in windows(candidate).flatMap({ elements($0) }) {
                print("AX \(attribute(element, kAXRoleAttribute) ?? "" as CFString) title=\(title(element)) description=\(attribute(element, kAXDescriptionAttribute) ?? "" as CFString) value=\(attribute(element, kAXValueAttribute) ?? "" as CFString)")
            }
            throw error
        }
        let visibleLabels = windows(candidate).flatMap { elements($0) }.map { title($0) + (attribute($0, kAXValueAttribute) as? String ?? "") }.joined(separator: "\n")
        try require(!visibleLabels.contains("打开体验文档") && !visibleLabels.contains("UI9"), "experiment UI leaked")
        try await open(other, in: candidateURL, app: candidate)
        try await open(other, in: candidateURL, app: candidate)
        try pressMenu(candidate) { $0.contains("移到新窗口") || $0 == "Move Tab to New Window" }
        try await wait("native tab detach") { visibleEditorCount(candidate) == 2 }
        try await Task.sleep(for: .milliseconds(800))
        try pressMenu(candidate) { $0 == "窗口" || $0 == "Window" }
        try await Task.sleep(for: .milliseconds(200))
        try pressMenu(candidate) { $0.contains("合并所有窗口") || $0 == "Merge All Windows" }
        do {
            try await wait("native tab merge") { visibleEditorCount(candidate) == 1 }
        } catch {
            print("MERGE visible=\(visibleEditorCount(candidate)) AX_windows=\(windows(candidate).map(title))")
            throw error
        }
        try await quit(candidate)
        let upgraded = try snapshot(support)
        try require(upgraded.texts.contains(draft), "candidate lost unsaved draft")
        for path in [note.path, other.path] {
            try require(upgraded.documents.filter { $0["sourcePath"] as? String == path }.count == 1, "missing/duplicate \(path)")
        }
        try require(upgraded.documents.contains { ($0["isDirty"] as? Bool == true) && $0["sourcePath"] == nil }, "draft dirty state lost")
        let savedPrefs = try preferences(home)
        for name in ["editorFontSize", "editorLineSpacing", "editorTabWidth", "isWordWrapEnabled", "appTheme"] {
            try require((savedPrefs[name] as? NSObject)?.isEqual(seeded[name]) == true, "preference changed: \(name)")
        }
        try require((savedPrefs["recentFilePaths"] as? [String])?.contains(note.path) == true, "recent files lost")
        let savedLibrary = try JSONSerialization.jsonObject(with: Data(contentsOf: libraryURL)) as! NSDictionary
        try require(savedLibrary == library as NSDictionary, "favorites/groups changed")
        try require(!fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/LacEditor-UI-Experiment").path), "candidate created experimental data")
        print("UPGRADE passed: draft, dirty flag, file identity, favorites, groups, recent files and preferences; Finder open kept same PID and deduplicated")

        // A fresh isolated session checks closing the final window and Dock-style reopen.
        let freshHome = home.appendingPathComponent("Fresh")
        try fm.createDirectory(at: freshHome, withIntermediateDirectories: true)
        let fresh = try await launch(candidateURL, home: freshHome)
        running = fresh
        try await open(note, in: candidateURL, app: fresh)
        key(13, pid: fresh.processIdentifier)
        try await wait("last populated tab became blank") { (try? attribute(editor(fresh), kAXValueAttribute) as? String) == "" }
        key(13, pid: fresh.processIdentifier)
        try await wait("last blank closed window") { windows(fresh).isEmpty }
        try require(!fresh.isTerminated, "closing window terminated App")
        let reopened = try await NSWorkspace.shared.openApplication(at: candidateURL, configuration: NSWorkspace.OpenConfiguration())
        try require(reopened.processIdentifier == fresh.processIdentifier, "Dock reopen restarted App")
        try await wait("Dock reopen editor and sidebar") {
            (try? editor(fresh)) != nil && windows(fresh).flatMap { elements($0) }.contains {
                title($0) == "设置" || attribute($0, kAXDescriptionAttribute) as? String == "设置"
            }
        }
        key(17, pid: fresh.processIdentifier)
        try await Task.sleep(for: .milliseconds(600))
        try insert("new tab after reopen", app: fresh)
        try await wait("Command+T after reopen") { (try? attribute(editor(fresh), kAXValueAttribute) as? String)?.contains("new tab after reopen") == true }
        key(13, pid: fresh.processIdentifier)
        try await wait("unsaved close confirmation") {
            let button = windows(fresh).flatMap { elements($0) }.first { title($0) == "不保存" }
            if let button { AXUIElementPerformAction(button, kAXPressAction as CFString); return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(400))
        let remainingText = attribute(try editor(fresh), kAXValueAttribute) as? String
        try require(remainingText == "", "discard did not close populated tab")
        try await quit(fresh)
        print("LIFECYCLE passed: populated → blank → close, same-PID Dock reopen, sidebar, Command+T, discard/Command+W and graceful quit")
    }
}
