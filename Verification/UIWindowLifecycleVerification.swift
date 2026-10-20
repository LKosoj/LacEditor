import AppKit
import ApplicationServices

/// Exercises the packaged App through Accessibility, targeting its PID rather
/// than its display name (formal and acceptance Apps may share that name).
@main
struct UIWindowLifecycleVerification {
    enum Failure: Error { case arguments, alreadyRunning, accessibility, missing(String), focus(String), quit }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func find(_ element: AXUIElement, depth: Int = 0,
                     matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 24 else { return nil }
        if predicate(element) { return element }
        for child in children(element) {
            if let found = find(child, depth: depth + 1, matching: predicate) { return found }
        }
        return nil
    }

    static func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute) as? String ?? ""
    }

    static func windows(_ application: AXUIElement) -> [AXUIElement] {
        attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func press(_ element: AXUIElement?) throws {
        guard let element else { throw Failure.missing("button/menu") }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw Failure.missing("AXPress \(title(element))")
        }
    }

    static func click(_ element: AXUIElement?, pid: pid_t) async throws {
        guard let element,
              let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { throw Failure.missing("button geometry") }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { throw Failure.missing("AX geometry") }
        let point = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
        CGWarpMouseCursorPosition(point)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        // Keep the pointer over the button long enough to exercise its tooltip.
        try await Task.sleep(for: .milliseconds(700))
        for type: CGEventType in [.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    static func closeWithKeyboard(pid: pid_t) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: isDown)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
    }

    @MainActor
    static func main() async {
        do { try await verify() }
        catch { fputs("Lifecycle verification failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor
    static func verify() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.arguments }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let identifier = Bundle(url: url)?.bundleIdentifier,
              ["com.laceditor.acceptance", "com.laceditor.ui-experiment"].contains(identifier) else {
            throw Failure.arguments
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else {
            throw Failure.alreadyRunning
        }
        guard AXIsProcessTrusted() else { throw Failure.accessibility }
        let originalPointer = CGEvent(source: nil)?.location
        defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let previousApp = NSWorkspace.shared.frontmostApplication
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        defer { if !app.isTerminated { _ = app.terminate() } }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        try await Task.sleep(for: .seconds(1))
        let bundle = Bundle(url: url)
        print("App \(identifier) PID \(app.processIdentifier), version=\(bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") build=\(bundle?.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")")
        let editor = try windows(application).first { title($0) != "设置" }
            .unwrap("editor")
        for cycle in 0..<6 {
            if cycle == 4, let previousApp, previousApp.processIdentifier != app.processIdentifier {
                // An AX button action while the App is inactive exercises the
                // application-activation path without depending on overlap.
                let previous = AXUIElementCreateApplication(previousApp.processIdentifier)
                AXUIElementSetAttributeValue(previous, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            } else {
                AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            try await Task.sleep(for: .milliseconds(300))
            // Alternate sidebar and menu so both entry points are covered.
            if cycle.isMultiple(of: 2) {
                let button = find(editor) {
                    attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                        && (title($0) == "设置" || (attribute($0, kAXDescriptionAttribute) as? String ?? "").hasPrefix("设置"))
                }
                if cycle == 4 { try press(button) }
                else { try await click(button, pid: app.processIdentifier) }
            } else {
                guard let menu = attribute(application, kAXMenuBarAttribute) else { throw Failure.missing("menu") }
                try press(find(menu as! AXUIElement) { title($0) == "设置…" })
            }
            for delay in [50, 200, 500, 800] {
                try await Task.sleep(for: .milliseconds(delay))
                let settings = try windows(application).first { title($0) == "设置" }.unwrap("settings")
                let focused = attribute(settings, kAXFocusedAttribute) as? Bool ?? false
                print("settings cycle=\(cycle) delay_ms=\(delay) focused=\(focused) window_count=\(windows(application).count)")
                guard focused else { throw Failure.focus("settings cycle \(cycle)") }
            }
            let settings = try windows(application).first { title($0) == "设置" }.unwrap("settings")
            if cycle.isMultiple(of: 2) {
                let close = attribute(settings, kAXCloseButtonAttribute)
                try press(close.map { $0 as! AXUIElement })
            } else {
                closeWithKeyboard(pid: app.processIdentifier)
            }
            try await Task.sleep(for: .milliseconds(200))
            guard !windows(application).contains(where: { title($0) == "设置" }) else {
                throw Failure.focus("settings close cycle \(cycle)")
            }
        }
        guard app.terminate() else { throw Failure.quit }
        for _ in 0..<100 {
            if app.isTerminated { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard app.isTerminated else { throw Failure.quit }
        print("Packaged settings lifecycle passed, 6 sidebar/menu open-close cycles.")
    }
}

private extension Optional {
    func unwrap(_ name: String) throws -> Wrapped {
        guard let self else { throw UIWindowLifecycleVerification.Failure.missing(name) }
        return self
    }
}
