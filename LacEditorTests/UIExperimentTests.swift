import AppKit
import SwiftUI
import XCTest
@testable import LacEditor

@MainActor
final class UIExperimentTests: XCTestCase {
    func testDataNamespacesDoNotOverlap() {
        XCTAssertEqual(AppEnvironment.dataDirectoryName(for: "com.laceditor.app"), "LacEditor")
        XCTAssertEqual(AppEnvironment.dataDirectoryName(for: AppEnvironment.experimentIdentifier), "LacEditor-UI-Experiment")
        XCTAssertEqual(AppEnvironment.dataDirectoryName(for: "com.laceditor.acceptance"), "LacEditor-Acceptance")
    }

    func testRecentFilesAndPreferencesUseTheirInjectedDefaults() {
        let formalName = "LacEditorTests.formal.\(UUID().uuidString)"
        let experimentName = "LacEditorTests.experiment.\(UUID().uuidString)"
        let formal = UserDefaults(suiteName: formalName)!
        let experiment = UserDefaults(suiteName: experimentName)!
        defer {
            formal.removePersistentDomain(forName: formalName)
            experiment.removePersistentDomain(forName: experimentName)
        }
        let original = RecentFilesStore(defaults: formal)
        let isolated = RecentFilesStore(defaults: experiment)
        let url = URL(fileURLWithPath: "/tmp/experiment-fixture.txt")
        isolated.record(url)
        XCTAssertTrue(original.urls.isEmpty)
        XCTAssertEqual(RecentFilesStore(defaults: experiment).urls, [url])
        XCTAssertTrue(RecentFilesStore(defaults: formal).urls.isEmpty)

        let originalPreferences = AppPreferences(defaults: formal)
        let isolatedPreferences = AppPreferences(defaults: experiment)
        isolatedPreferences.editorFontSize = 20
        isolatedPreferences.wordWrapEnabled = false
        XCTAssertEqual(originalPreferences.editorFontSize, AppPreferences.defaultFontSize)
        XCTAssertTrue(originalPreferences.wordWrapEnabled)
        XCTAssertEqual(AppPreferences(defaults: experiment).editorFontSize, 20)
        XCTAssertFalse(AppPreferences(defaults: experiment).wordWrapEnabled)
    }

    func testRevealKeepsHeaderAndRowsAnchoredThroughoutCollapseAndReversal() {
        _ = NSApplication.shared
        var headerOrigins: [CGFloat] = []
        var firstRowOrigins: [CGFloat] = []
        for progress: CGFloat in [1, 0.75, 0.5, 0.25, 0, 0.5, 1] {
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                LayoutProbe(name: "header").frame(height: 28)
                SidebarRevealLayout(progress: progress) {
                    VStack(spacing: 2) {
                        LayoutProbe(name: "first").frame(height: 34)
                        Color.clear.frame(height: 34)
                        Color.clear.frame(height: 34)
                    }
                }.clipped()
            }.frame(width: 250).fixedSize(horizontal: false, vertical: true))
            let height = host.fittingSize.height
            host.frame = NSRect(x: 0, y: 0, width: 250, height: height)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(height, 28 + 106 * progress, accuracy: 0.5)
            func find(_ name: String, in view: NSView) -> NSView? {
                if view.identifier?.rawValue == name { return view }
                return view.subviews.lazy.compactMap { find(name, in: $0) }.first
            }
            if let header = find("header", in: host), let first = find("first", in: host) {
                headerOrigins.append(header.convert(header.bounds, to: host).minY)
                firstRowOrigins.append(first.convert(first.bounds, to: host).minY)
            } else {
                XCTFail("Missing hosted layout probes at progress \(progress)")
            }
        }
        for origin in headerOrigins { XCTAssertEqual(origin, headerOrigins[0], accuracy: 0.5) }
        for origin in firstRowOrigins { XCTAssertEqual(origin, firstRowOrigins[0], accuracy: 0.5) }
    }

    func testScrollConfigurationTouchesOnlyItsEnclosingScrollView() {
        let own = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 400))
        let other = NSScrollView(frame: NSRect(x: 250, y: 0, width: 250, height: 400))
        own.scrollerStyle = .legacy
        other.scrollerStyle = .legacy
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 800))
        let bridge = NativeScrollViewConfigurator.ConfiguratorView()
        content.addSubview(bridge)
        own.documentView = content
        bridge.configureScrollViews()
        XCTAssertEqual(own.scrollerStyle, .overlay)
        XCTAssertTrue(own.autohidesScrollers)
        XCTAssertEqual(other.scrollerStyle, .legacy)
    }

    func testRapidSidebarCollapsePreservesEditorAndDocument() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LacEditorTests.ui.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let recent = RecentFilesStore(defaults: defaults)
        let library = SidebarLibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.theme = .light
        let manager = WindowManager(preferences: preferences, recentFiles: recent, sidebarLibrary: library)
        let group = try XCTUnwrap(library.createGroup(named: "日常与灵感"))
        let project = try XCTUnwrap(library.createGroup(named: "项目"))
        for name in ["draft.md", "config.json", "welcome.html"] {
            let url = directory.appendingPathComponent(name)
            try "测试文件".write(to: url, atomically: true, encoding: .utf8)
            recent.record(url)
            library.toggleFavorite(url)
            library.add(url, toGroup: group)
            library.add(url, toGroup: project)
        }
        let text = "# 留一点空白\n\n轻量的编辑器，让注意力回到文字。\n\n## 今天要做的事\n\n1. 整理想法\n2. 写下第一稿\n3. 留时间再读一遍\n\n```swift\nlet message = \"你好，LacEditor\"\nprint(message)\n```\n"
        let document = EditorDocument(text: text, url: directory.appendingPathComponent("draft.md"), language: .markdown)
        let state = manager.openNewWindow(with: document)
        state.isSidebarVisible = true
        let window = try XCTUnwrap(state.hostWindow)
        defer { window.delegate = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        func editor(in view: NSView) -> LacTextView? {
            if let text = view as? LacTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let content = try XCTUnwrap(window.contentView)
        let originalEditor = try XCTUnwrap(editor(in: content))
        for index in 0..<30 {
            library.setExpanded(index.isMultiple(of: 2), for: .favorites)
            library.setExpanded(index.isMultiple(of: 2), for: group)
            try await Task.sleep(for: .milliseconds(12))
        }
        library.setExpanded(true, for: .favorites)
        library.setExpanded(true, for: group)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(editor(in: content) === originalEditor)
        XCTAssertEqual(state.selectedDocument?.text, text)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(originalEditor.string, text)
        let scroll = try XCTUnwrap(originalEditor.enclosingScrollView)
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 400)

        // Opt-in artifacts contain only the temporary fixture above, never a
        // user's document. Normal test runs do not accumulate image files.
        if ProcessInfo.processInfo.environment["LACEDITOR_UI_SNAPSHOTS"] == "1" {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/UIExperimentSnapshots")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for theme: AppTheme in [.light, .dark] {
                preferences.theme = theme
                try await Task.sleep(for: .milliseconds(350))
                content.layoutSubtreeIfNeeded()
                // View caching omits composited SwiftUI scroll content and
                // behind-window materials. Capture only this fixture window.
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber),
                                     output.appendingPathComponent("sidebar-\(theme.rawValue).png").path]
                try capture.run()
                while capture.isRunning { try await Task.sleep(for: .milliseconds(50)) }
                XCTAssertEqual(capture.terminationStatus, 0, "Window capture requires existing screen-recording access")
            }
        }
    }
}

private struct LayoutProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
