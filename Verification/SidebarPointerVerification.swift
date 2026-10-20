import AppKit
import ApplicationServices

/// Opt-in pointer checks against a real acceptance App with a temporary home.
/// Does not change the installed App, its sidebar, or any user document.
@main
struct SidebarPointerVerification {
    enum Failure: Error { case arguments, accessibility, alreadyRunning, missing(String), operation(String) }

    struct Group: Codable, Equatable {
        var id: UUID
        var name: String
        var isExpanded: Bool
        var paths: [String]
    }
    struct Library: Codable {
        var favoritePaths: [String] = []
        var groups: [Group]
        var favoriteSectionExpanded = true
        var groupsSectionExpanded = true
        var recentSectionExpanded = true
    }

    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    static func find(_ element: AXUIElement, depth: Int = 0, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if matches(element) { return element }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let match = find(child, depth: depth + 1, matches) { return match }
        }
        return nil
    }

    static func frame(_ element: AXUIElement) throws -> CGRect {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { throw Failure.missing("geometry") }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { throw Failure.missing("geometry value") }
        return CGRect(origin: origin, size: extent)
    }

    static func mouse(_ type: CGEventType, at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                            mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left)
        if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(type) {
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event?.post(tap: .cghidEventTap)
    }

    static func click(_ element: AXUIElement) async throws {
        let rect = try frame(element)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        mouse(.mouseMoved, at: point)
        try await Task.sleep(for: .milliseconds(20))
        mouse(.leftMouseDown, at: point)
        try await Task.sleep(for: .milliseconds(60))
        mouse(.leftMouseUp, at: point)
    }

    static func snapshot(pid: pid_t, name: String) async throws {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let entry = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }), let number = entry[kCGWindowNumber as String] as? Int else { return }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/UIExperimentSnapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(number), directory.appendingPathComponent(name + ".png").path]
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        guard process.terminationStatus == 0 else { throw Failure.operation("fixture screenshot") }
    }

    @MainActor static func main() async {
        do { try await verify() }
        catch { fputs("Sidebar pointer verification failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func verify() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.arguments }
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let identifier = "com.laceditor.acceptance"
        guard Bundle(url: appURL)?.bundleIdentifier == identifier else { throw Failure.arguments }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
            throw Failure.alreadyRunning
        }
        guard AXIsProcessTrusted() else { throw Failure.accessibility }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LacEditor-UI7-Pointer-\(UUID().uuidString)")
        let support = directory.appendingPathComponent("Library/Application Support/LacEditor-Acceptance")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [String] = []
        for index in 0..<16 {
            let file = directory.appendingPathComponent("sample-\(index).txt")
            try "侧栏指针验收，仅使用临时文件。".write(to: file, atomically: true, encoding: .utf8)
            files.append(file.standardizedFileURL.resolvingSymlinksInPath().path)
        }
        let first = Group(id: UUID(), name: "拖放源分组", isExpanded: true, paths: files)
        let second = Group(id: UUID(), name: "悬停展开分组", isExpanded: false, paths: [files.last!])
        let libraryURL = support.appendingPathComponent("SidebarLibrary.json")
        try JSONEncoder().encode(Library(groups: [first, second])).write(to: libraryURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.environment = ["CFFIXED_USER_HOME": directory.path]
        let previousApp = NSWorkspace.shared.frontmostApplication
        let running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        defer {
            if !running.isTerminated { _ = running.terminate() }
            _ = previousApp?.activate(options: [])
        }
        try await Task.sleep(for: .seconds(1))
        let pid = running.processIdentifier
        let original = CGEvent(source: nil)?.location
        var dragPoint: CGPoint?
        defer {
            if let dragPoint { mouse(.leftMouseUp, at: dragPoint) }
            if let original { CGWarpMouseCursorPosition(original) }
        }
        let app = AXUIElementCreateApplication(pid)
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        guard AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success else {
            throw Failure.operation("activate fixture")
        }
        try await Task.sleep(for: .milliseconds(250))
        guard let window = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            throw Failure.missing("fixture window")
        }
        func identified(_ id: String) throws -> AXUIElement {
            guard let element = find(window, { attribute($0, kAXIdentifierAttribute) as? String == id }) else {
                throw Failure.missing("fixture element")
            }
            return element
        }
        let firstID = "sidebar.group.\(first.id.uuidString)"
        let secondID = "sidebar.group.\(second.id.uuidString)"
        let initial = try frame(identified(firstID))
        print("Initial header y=\(initial.minY)")
        let snapshots = ProcessInfo.processInfo.environment["LACEDITOR_UI_SNAPSHOTS"] == "1"
        if snapshots { try await snapshot(pid: pid, name: "UI7-sidebar-expanded") }
        _ = running.activate(options: [.activateAllWindows])
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        try await Task.sleep(for: .milliseconds(300))
        print("Fixture frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        for _ in 0..<3 {
            try await click(identified(firstID))
            try await Task.sleep(for: .milliseconds(65))
            let closing = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL))
            guard closing.groups[0].isExpanded == false else { throw Failure.operation("collapse click not received") }
            try await click(identified(firstID))
            try await Task.sleep(for: .milliseconds(250))
            let opened = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL))
            guard opened.groups[0].isExpanded else { throw Failure.operation("reversal click not received") }
            guard abs(try frame(identified(firstID)).minY - initial.minY) < 1 else {
                throw Failure.operation("group header moved during reversal")
            }
        }
        if ProcessInfo.processInfo.environment["LACEDITOR_INTERACTION_POLISH"] == "1" {
            func library() throws -> Library {
                try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL))
            }
            let sourceID = "sidebar.file.group.\(first.id.uuidString).\(files[0])"
            func menuAction(_ title: String) async throws {
                let rect = try frame(identified(sourceID))
                let point = CGPoint(x: rect.midX, y: rect.midY)
                mouse(.mouseMoved, at: point)
                try await Task.sleep(for: .milliseconds(100))
                mouse(.rightMouseDown, at: point)
                try await Task.sleep(for: .milliseconds(60))
                mouse(.rightMouseUp, at: point)
                try await Task.sleep(for: .milliseconds(250))
                guard let item = find(app, {
                    attribute($0, kAXTitleAttribute) as? String == title
                        && attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole
                }) else {
                    throw Failure.operation("context menu action: \(title)")
                }
                print("Context menu \(title) rect=\(try frame(item))")
                guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                    throw Failure.operation("context menu press: \(title)")
                }
                try await Task.sleep(for: .milliseconds(350))
            }
            try await menuAction("添加到收藏夹")
            print("Favorite after menu=\(try library().favoritePaths), expected=\(files[0])")
            guard try library().favoritePaths == [files[0]] else {
                try await snapshot(pid: pid, name: "UI8-feedback-failure")
                throw Failure.operation("favorite action")
            }
            let undo = try identified("sidebar.feedback.undo")
            if snapshots { try await snapshot(pid: pid, name: "UI8-sidebar-feedback") }
            guard AXUIElementPerformAction(undo, kAXPressAction as CFString) == .success else {
                throw Failure.operation("favorite undo action")
            }
            try await Task.sleep(for: .milliseconds(150))
            guard try library().favoritePaths.isEmpty else { throw Failure.operation("favorite undo") }
            try await Task.sleep(for: .milliseconds(300))
            try await menuAction("从分组中移除")
            print("Group after remove count=\(try library().groups[0].paths.count), first=\(try library().groups[0].paths.first ?? "nil")")
            guard try library().groups[0].paths == Array(first.paths.dropFirst()) else {
                throw Failure.operation("remove membership")
            }
            guard AXUIElementPerformAction(try identified("sidebar.feedback.undo"), kAXPressAction as CFString) == .success,
                  try library().groups[0].paths == first.paths else { throw Failure.operation("membership undo") }
            try await Task.sleep(for: .milliseconds(300))
            // The feedback row reserves its height, so these operations cannot
            // displace the source/header or editor content.
            guard abs(try frame(identified(firstID)).minY - initial.minY) < 1 else {
                throw Failure.operation("feedback moved group header")
            }
            print("UI8 context menus: favorite/remove + inline undo preserve original order and header position.")
            guard let filter = find(window, {
                attribute($0, kAXRoleAttribute) as? String == kAXTextFieldRole
                    && (attribute($0, kAXDescriptionAttribute) as? String ?? "").contains("筛选")
            }) else { throw Failure.missing("filter field") }
            try await click(filter)
            try await Task.sleep(for: .milliseconds(150))
            guard attribute(filter, kAXFocusedAttribute) as? Bool == true else {
                throw Failure.operation("filter focus")
            }
            if snapshots { try await snapshot(pid: pid, name: "UI8-filter-focus") }
            print("UI8 native filter field received focus; button Tab traversal remains system-controlled.")
        }
        let source = try frame(identified("sidebar.file.group.\(first.id.uuidString).\(files[0])"))
        guard let scroll = find(window, { attribute($0, kAXRoleAttribute) as? String == kAXScrollAreaRole }) else {
            throw Failure.missing("sidebar scroll viewport")
        }
        let viewport = try frame(scroll)
        print("Pointer source=\(source) viewport=\(viewport)")
        var point = CGPoint(x: source.midX, y: source.midY)
        mouse(.mouseMoved, at: point)
        try await Task.sleep(for: .milliseconds(150))
        mouse(.leftMouseDown, at: point)
        dragPoint = point
        try await Task.sleep(for: .milliseconds(100))
        for offset in 1...8 {
            point = CGPoint(x: source.midX + CGFloat(offset * 2), y: source.midY + CGFloat(offset * 2))
            mouse(.leftMouseDragged, at: point)
            dragPoint = point
            try await Task.sleep(for: .milliseconds(20))
        }
        point = CGPoint(x: viewport.midX, y: viewport.maxY - 9)
        mouse(.leftMouseDragged, at: point)
        dragPoint = point
        var destination: CGRect?
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            mouse(.leftMouseDragged, at: point)
            if let element = try? identified(secondID), let rect = try? frame(element),
               rect.midY < viewport.maxY - 60, rect.midY > viewport.minY + 60 {
                destination = rect
                break
            }
        }
        guard let destination else {
            try await snapshot(pid: pid, name: "UI7-pointer-edge-failure")
            throw Failure.operation("edge scroll did not reveal target group")
        }
        print("Edge scroll revealed target at y=\(destination.minY)")
        point = CGPoint(x: destination.midX, y: destination.midY)
        mouse(.leftMouseDragged, at: point)
        dragPoint = point
        for _ in 0..<17 {
            mouse(.leftMouseDragged, at: point)
            try await Task.sleep(for: .milliseconds(50))
        }
        let hoverResult = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL))
        print("Hover expansion state=\(hoverResult.groups.map(\.isExpanded))")
        guard hoverResult.groups.first(where: { $0.id == second.id })?.isExpanded == true else {
            try await snapshot(pid: pid, name: "UI7-pointer-hover-failure")
            throw Failure.operation("hover did not expand target group")
        }
        if snapshots { try await snapshot(pid: pid, name: "UI7-sidebar-hover-expanded") }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)
            event?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(100))
        mouse(.leftMouseUp, at: point)
        dragPoint = nil
        guard running.terminate() else { throw Failure.operation("quit fixture") }
        for _ in 0..<100 {
            if running.isTerminated { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard running.isTerminated else { throw Failure.operation("quit timeout") }
        let saved = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL))
        guard saved.groups.map(\.id) == [first.id, second.id],
              saved.groups.map(\.paths) == [first.paths, second.paths],
              saved.groups.allSatisfy(\.isExpanded) else { throw Failure.operation("cancel changed library order or membership") }
        print("Real pointer: 3 rapid collapse/reversal pairs, edge scroll, hover expansion and Escape cancellation passed.")
    }
}
