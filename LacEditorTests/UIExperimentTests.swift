import AppKit
import SwiftUI
import XCTest
import Darwin
@testable import LacEditor

@MainActor
final class UIExperimentTests: XCTestCase {
    func testTooltipCancelsWhenOriginatingWindowResignsKeyOrViewDetaches() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tracking = ToolTipTrackingView(text: "设置", shortcut: "⌘,")
        tracking.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        window.contentView?.addSubview(tracking)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        tracking.mouseEntered(with: event)
        XCTAssertTrue(tracking.isPresentationPending)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(tracking.isPresentationPending)
        tracking.mouseEntered(with: event)
        XCTAssertTrue(tracking.isPresentationPending)
        tracking.removeFromSuperview()
        XCTAssertFalse(tracking.isPresentationPending)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testInactiveSettingsWaitsForActivationAndDoesNotReopenAfterClose() async throws {
        _ = NSApplication.shared
        let fixture = try UI2Fixture()
        defer { fixture.dispose() }
        try await Task.sleep(for: .milliseconds(100))
        var active = false
        var activationRequests = 0
        let settings = SettingsWindowController(applicationIsActive: { active },
                                                activateApplication: { activationRequests += 1 })
        settings.present(windowManager: fixture.manager)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(activationRequests, 1)
        XCTAssertFalse(NSApp.windows.contains {
            $0.identifier?.rawValue == "LacEditor.SettingsWindow" && $0.isVisible
        })
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(150))
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "LacEditor.SettingsWindow" && $0.isVisible
        })
        window.performClose(nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(activationRequests, 1)
    }

    func testNativeTabEnduranceAndClosedEditorRelease() async throws {
        guard ProcessInfo.processInfo.environment["LACEDITOR_UI_ENDURANCE"] == "1" else {
            throw XCTSkip("Enable LACEDITOR_UI_ENDURANCE for the two-minute native tab workload")
        }
        _ = NSApplication.shared
        let unit = "中英文 Mixed text 123，长期滚动与原生标签切换。\n"
        let text = String(repeating: unit, count: 30_000)
        let fixture = try UI2Fixture(text: text)
        defer { fixture.dispose() }
        fixture.preferences.wordWrapEnabled = false
        var states = [fixture.state]
        for index in 1..<10 {
            let state = fixture.manager.openNativeTab(from: fixture.state)
            state.selectedDocument?.text = "\(index)\n" + text
            state.selectedDocument?.markSaved()
            states.append(state)
        }
        try await Task.sleep(for: .seconds(1))
        let editors = NSHashTable<LacTextView>.weakObjects()
        for state in states {
            let view = try XCTUnwrap(state.hostWindow?.contentView)
            editors.add(try XCTUnwrap(descendants(in: view, of: LacTextView.self).first))
        }
        XCTAssertEqual(editors.allObjects.count, 10)
        let duration: TimeInterval = 120
        let start = ProcessInfo.processInfo.systemUptime
        var cycle = 0
        var nextSample: TimeInterval = 0
        var samples: [UInt64] = []
        while ProcessInfo.processInfo.systemUptime - start < duration {
            let state = states[cycle % states.count]
            let window = try XCTUnwrap(state.hostWindow)
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            let content = try XCTUnwrap(window.contentView)
            let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let fraction = CGFloat((cycle * 17) % 100) / 100
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.bounds.height - scroll.contentSize.height) * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            if cycle.isMultiple(of: 10) {
                window.setContentSize(NSSize(width: cycle.isMultiple(of: 20) ? 1000 : 1180, height: 720))
            }
            content.layoutSubtreeIfNeeded()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if elapsed >= nextSample {
                samples.append(hostResidentSize())
                print("UI6_ENDURANCE elapsed_s=\(Int(elapsed)) switches=\(cycle) host_rss_bytes=\(samples.last!)")
                fflush(stdout)
                nextSample += 10
            }
            cycle += 1
            try await Task.sleep(for: .milliseconds(30))
        }
        for (index, state) in states.enumerated() {
            XCTAssertEqual(state.selectedDocument?.synchronizedText(), index == 0 ? text : "\(index)\n" + text)
        }
        for state in states.dropFirst() { state.hostWindow?.performClose(nil) }
        states.removeSubrange(1...)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(editors.allObjects.count, 1, "Closed native tabs must release their editors")
        XCTAssertTrue(fixture.manager.activeState === fixture.state)
        print("UI6_ENDURANCE completed switches=\(cycle) rss_samples=\(samples) after_close_rss_bytes=\(hostResidentSize())")
        fflush(stdout)
    }

    private func hostResidentSize() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    func testCandidatePreviewEnduranceAndRelease() async throws {
        guard ProcessInfo.processInfo.environment["LACEDITOR_RC_PREVIEW"] == "1" else {
            throw XCTSkip("Enable LACEDITOR_RC_PREVIEW for the candidate preview workload")
        }
        _ = NSApplication.shared
        let text = String(repeating: "## 中英文 Mixed text\n\n正文与 `code`。\n\n1. first\n2. second\n\n", count: 300)
        var fixture: UI2Fixture? = try UI2Fixture(text: text, language: .markdown)
        weak var releasedEditor: LacTextView?
        weak var releasedWebView: MarkdownWebView?
        var samples: [UInt64] = []
        func workload(_ fixture: UI2Fixture) async throws {
            fixture.preferences.wordWrapEnabled = true
            fixture.document.isPreviewVisible = true
            let window = try XCTUnwrap(fixture.state.hostWindow)
            let content = try XCTUnwrap(window.contentView)
            try await Task.sleep(for: .seconds(1))
            let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
            let web = try XCTUnwrap(descendants(in: content, of: MarkdownWebView.self).first)
            releasedEditor = editor
            releasedWebView = web
            samples.append(hostResidentSize())
            for cycle in 0..<60 {
                fixture.document.text = text + "\nRC1-latest-\(cycle)\n"
                fixture.state.togglePreview()
                fixture.state.toggleSidebar()
                if cycle.isMultiple(of: 3) {
                    window.setContentSize(NSSize(width: cycle.isMultiple(of: 2) ? 1000 : 1180, height: 720))
                }
                if let scroll = editor.enclosingScrollView {
                    let y = max(0, editor.bounds.height - scroll.contentSize.height) * CGFloat(cycle % 10) / 10
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                content.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                if cycle.isMultiple(of: 10) { samples.append(hostResidentSize()) }
                XCTAssertTrue(descendants(in: content, of: LacTextView.self).first === editor)
                XCTAssertTrue(descendants(in: content, of: MarkdownWebView.self).first === web)
            }
            fixture.document.isPreviewVisible = true
            fixture.document.text = text + "\nRC1-final-revision\n"
            try await Task.sleep(for: .seconds(2))
            let body = try await web.evaluateJavaScript("document.body.innerText") as? String
            XCTAssertTrue(body?.contains("RC1-final-revision") == true, "Preview must show the final revision after repeated cancellation")
            XCTAssertFalse(body?.contains("RC1-latest-") == true)
            samples.append(hostResidentSize())
            fixture.document.markSaved()
        }
        try await workload(try XCTUnwrap(fixture))
        fixture?.dispose()
        fixture = nil
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(releasedEditor)
        XCTAssertNil(releasedWebView, "Closing the editor must release its WebKit view")
        print("RC1_PREVIEW cycles=60 host_rss_bytes=\(samples) after_close_rss_bytes=\(hostResidentSize()) editor_and_webview_released=true")
        fflush(stdout)
    }

    func testSettingsPresentationFinishesOriginatingEventAndReleasesClosedHost() async throws {
        _ = NSApplication.shared
        let fixture = try UI2Fixture()
        defer { fixture.dispose() }
        try await Task.sleep(for: .milliseconds(150))
        let settings = SettingsWindowController(applicationIsActive: { true })
        settings.present(windowManager: fixture.manager)
        // A button event can still reorder its originating editor before it
        // returns. Presentation must happen after that synchronous work.
        fixture.state.hostWindow?.makeKeyAndOrderFront(nil)
        XCTAssertFalse(NSApp.windows.contains {
            $0.identifier?.rawValue == "LacEditor.SettingsWindow" && $0.isVisible
        })
        try await Task.sleep(for: .milliseconds(150))
        var window: NSWindow? = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "LacEditor.SettingsWindow" && $0.isVisible
        })
        let closedHosts = NSHashTable<NSViewController>.weakObjects()
        closedHosts.add(try XCTUnwrap(window?.contentViewController))
        let originalHost = ObjectIdentifier(try XCTUnwrap(window?.contentViewController))
        for _ in 0..<10 { settings.present(windowManager: fixture.manager) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window?.contentViewController)), originalHost)
        window?.performClose(nil)
        window = nil
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(closedHosts.allObjects.isEmpty)
    }

    func testUI5ChromeMaterialsAndPaneBoundariesAcrossSizesAndThemes() async throws {
        _ = NSApplication.shared
        let fixture = try UI2Fixture(text: "# 布局检查\n\n中文与 English 123。\n", language: .markdown)
        defer { fixture.dispose() }
        let samples = ExperimentSampleLibrary(rootURL: fixture.directory.appendingPathComponent("Examples"),
                                               defaults: fixture.defaults)
        await samples.prepare(in: fixture.manager.sidebarLibrary)
        fixture.state.isSidebarVisible = true
        fixture.document.isPreviewVisible = true
        let window = try XCTUnwrap(fixture.state.hostWindow)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(350))
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
        let webView = try XCTUnwrap(descendants(in: content, of: MarkdownWebView.self).first)
        for theme: AppTheme in [.light, .dark, .system] {
            fixture.preferences.theme = theme
            for size in [NSSize(width: 900, height: 560), NSSize(width: 1180, height: 780)] {
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(100))
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(window.toolbarStyle, .unified)
                XCTAssertEqual(window.titlebarSeparatorStyle, .none)
                let material = try XCTUnwrap(descendants(in: content, of: NSVisualEffectView.self)
                    .first { $0.material == .sidebar })
                XCTAssertEqual(material.blendingMode, .behindWindow)
                XCTAssertEqual(material.state, .followsWindowActiveState)
                let split = try XCTUnwrap(descendants(in: content, of: ContentDividerSplitView.self).first)
                XCTAssertEqual(split.dividerColor, NSColor.clear)
                let editorRect = editor.convert(editor.visibleRect, to: content)
                let previewRect = webView.convert(webView.visibleRect, to: content)
                XCTAssertLessThanOrEqual(editorRect.maxX, previewRect.minX + 1)
                XCTAssertGreaterThan(editorRect.width, 200)
                XCTAssertGreaterThan(previewRect.width, 190)
                XCTAssertTrue(descendants(in: content, of: LacTextView.self).first === editor)
                for scroll in descendants(in: content, of: NSScrollView.self) {
                    XCTAssertEqual(scroll.scrollerStyle, NSScroller.preferredScrollerStyle,
                                   "Owned scroll views must follow macOS scrollbar preferences")
                }
            }
            try await captureFixture(window, name: "UI5-window-\(theme.rawValue)")
        }
    }

    func testViewportDisplayBatchingKeepsDeepEditingUndoAndCompositionStable() async throws {
        _ = NSApplication.shared
        let unit = "中英文 Mixed text 123，深处编辑的行高与撤销应保持稳定。\n"
        let text = String(repeating: unit, count: 14_000)
        let fixture = try UI2Fixture(text: text)
        defer { fixture.dispose() }
        fixture.preferences.wordWrapEnabled = false
        try await Task.sleep(for: .milliseconds(200))
        let content = try XCTUnwrap(fixture.state.hostWindow?.contentView)
        let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
        let layout = try XCTUnwrap(editor.layoutManager as? FoldLayoutManager)
        XCTAssertTrue(EditorLayoutPolicy.usesViewportLayout(textLength: editor.textStorage!.length))
        let location = (unit as NSString).length * 12_000
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        fixture.state.hostWindow?.makeFirstResponder(editor)
        let initialHeight = layout.editorLineHeight
        for theme: AppTheme in [.dark, .light] {
            fixture.preferences.theme = theme
            layout.invalidateDisplay(forCharacterRange: NSRange(location: location, length: 10))
            try await Task.sleep(for: .milliseconds(70))
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(layout.editorLineHeight, initialHeight)
        }
        editor.insertText("edit", replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.string.contains("edit"))
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, text)
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual((editor.string as NSString).substring(with: NSRange(location: location, length: 2)), "中文")
        XCTAssertEqual(layout.editorLineHeight, initialHeight)
        XCTAssertTrue(descendants(in: content, of: LacTextView.self).first === editor)
        XCTAssertEqual(fixture.document.synchronizedText(), editor.string)
    }

    func testUI4SamplesFilterAndEmptyEditorRetainNativeEditor() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LacEditorTests.ui4.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = AppPreferences(defaults: defaults)
        let samples = ExperimentSampleLibrary(rootURL: directory.appendingPathComponent("Examples"), defaults: defaults)
        let manager = WindowManager(preferences: preferences, recentFiles: RecentFilesStore(defaults: defaults),
                                    sidebarLibrary: SidebarLibraryStore(storageURL: directory.appendingPathComponent("library.json")),
                                    experimentSamples: samples)
        await manager.prepareExperimentSamples()
        let document = EditorDocument()
        let state = manager.openNewWindow(with: document)
        state.isSidebarVisible = true
        let window = try XCTUnwrap(state.hostWindow)
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible)
        defer {
            window.delegate = nil
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
        for theme: AppTheme in [.light, .dark] {
            preferences.theme = theme
            try await Task.sleep(for: .milliseconds(200))
            try await captureFixture(window, name: "UI4-start-\(theme.rawValue)")
        }
        window.makeFirstResponder(editor)
        editor.insertText("直接输入", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(descendants(in: content, of: LacTextView.self).first === editor)
        XCTAssertEqual(editor.string, "直接输入")
        XCTAssertTrue(window.firstResponder === editor)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "")
        for index in 0..<50 {
            manager.sidebarLibrary.setExpanded(index.isMultiple(of: 2), for: .groups)
            try await Task.sleep(for: .milliseconds(5))
        }
        manager.sidebarLibrary.setExpanded(true, for: .groups)
        manager.openExperimentWelcome(in: state)
        for _ in 0..<100 {
            if state.selectedDocument?.url == samples.welcomeURL, state.selectedDocument?.ioState == .idle { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(state.selectedDocument?.url, samples.welcomeURL)
        XCTAssertTrue(state.selectedDocument?.text.contains("给想法留一点空间") == true)
        for theme: AppTheme in [.light, .dark] {
            preferences.theme = theme
            state.selectedDocument?.isPreviewVisible = true
            try await Task.sleep(for: .milliseconds(350))
            try await captureFixture(window, name: "UI4-samples-\(theme.rawValue)")
        }
        let filtered = SidebarLibraryView(recentFiles: manager.recentFiles, library: manager.sidebarLibrary, query: "JS")
            .environmentObject(state).environmentObject(manager)
        let filterHost = NSHostingView(rootView: filtered)
        filterHost.frame = NSRect(x: 0, y: 0, width: 250, height: 500)
        filterHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(filterHost.fittingSize.height, 0)
        XCTAssertEqual(manager.sidebarLibrary.groups.count, 3)
    }

    func testNativeTabSwitchingRetainsEditorsAndPreview() async throws {
        let fixture = try UI2Fixture(text: "# 原生标签\n\n保留编辑与预览。", language: .markdown)
        defer { fixture.dispose() }
        fixture.document.isPreviewVisible = true
        try await Task.sleep(for: .milliseconds(350))
        let first = try XCTUnwrap(fixture.state.hostWindow)
        let secondState = fixture.manager.openNativeTab(from: fixture.state)
        let second = try XCTUnwrap(secondState.hostWindow)
        defer {
            second.delegate = nil
            second.contentViewController = nil
            second.close()
        }
        try await Task.sleep(for: .milliseconds(250))
        let firstContent = try XCTUnwrap(first.contentView)
        let secondContent = try XCTUnwrap(second.contentView)
        let editor = try XCTUnwrap(descendants(in: firstContent, of: LacTextView.self).first)
        let otherEditor = try XCTUnwrap(descendants(in: secondContent, of: LacTextView.self).first)
        let preview = try XCTUnwrap(descendants(in: firstContent, of: MarkdownWebView.self).first)
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let group = try XCTUnwrap(first.tabGroup)
        XCTAssertEqual(group.windows.count, 2)
        var samples: [Double] = []
        for index in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            group.selectedWindow = index.isMultiple(of: 2) ? first : second
            group.selectedWindow?.contentView?.layoutSubtreeIfNeeded()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertTrue(descendants(in: firstContent, of: LacTextView.self).first === editor)
        XCTAssertTrue(descendants(in: secondContent, of: LacTextView.self).first === otherEditor)
        XCTAssertTrue(descendants(in: firstContent, of: MarkdownWebView.self).first === preview)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
        let sorted = samples.sorted()
        print(String(format: "UI3_METRIC native-tab median_ms=%.3f p95_ms=%.3f max_ms=%.3f count=100",
                     sorted[50], sorted[94], sorted[99]))
    }

    func testPreviewTogglePreservesEditorViewportWithWrappedText() async throws {
        let text = String(repeating: "中英文 Mixed words，分栏宽度改变时保留阅读位置。", count: 5) + "\n"
        let fixture = try UI2Fixture(text: String(repeating: text, count: 300), language: .markdown)
        defer { fixture.dispose() }
        fixture.state.isSidebarVisible = false
        fixture.document.isPreviewVisible = true
        try await Task.sleep(for: .milliseconds(400))
        let window = try XCTUnwrap(fixture.state.hostWindow)
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        let location = (text as NSString).length * 100
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + editor.textContainerOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        func topCharacter() -> Int {
            let point = NSPoint(x: 0, y: scroll.contentView.bounds.minY - editor.textContainerOrigin.y + 1)
            let glyph = layout.glyphIndex(for: point, in: container)
            return layout.characterIndexForGlyph(at: min(glyph, layout.numberOfGlyphs - 1))
        }
        let original = topCharacter()
        fixture.state.togglePreview()
        try await Task.sleep(for: .milliseconds(150))
        fixture.state.togglePreview()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(Double(topCharacter()), Double(original), accuracy: Double((text as NSString).length),
                       "A preview round trip must keep the editor within the same paragraph")
    }

    /// Opt-in, repeatable native-window workload used for UI2/UI3 comparison.
    /// Measurements include AppKit layout; they are not display frame times.
    func testProfileInteractionWorkload() async throws {
        guard ProcessInfo.processInfo.environment["LACEDITOR_UI_STRESS"] == "1" else {
            throw XCTSkip("Enable LACEDITOR_UI_STRESS for the profiling workload")
        }
        _ = NSApplication.shared
        let large = ProcessInfo.processInfo.environment["LACEDITOR_PROFILE_SIZE_MB"] == "50"
        let unit = "## 阅读与编辑\n\n中英文 Mixed text 123，保留注意力。\n\n- 项目\n  - 子项\n\n```js\nconst value = { enabled: true };\n```\n\n"
        let text = String(repeating: unit, count: large ? (50 * 1_024 * 1_024 / unit.utf8.count + 1) : 6_000)
        let fixture = try UI2Fixture(text: text, language: .markdown)
        defer { fixture.dispose() }
        fixture.state.isSidebarVisible = false
        fixture.document.isPreviewVisible = !large
        let window = try XCTUnwrap(fixture.state.hostWindow)
        window.orderFront(nil)
        try await Task.sleep(for: .seconds(2))
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        editor.setSelectedRange(NSRange(location: 10, length: 4))
        var samples: [String: [Double]] = [:]
        var rss: [UInt64] = []
        func residentSize() -> UInt64 {
            var info = mach_task_basic_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.resident_size : 0
        }
        rss.append(residentSize())
        for cycle in 0..<30 {
            var start = ProcessInfo.processInfo.systemUptime
            window.setContentSize(NSSize(width: cycle.isMultiple(of: 2) ? 1000 : 1180, height: 720))
            content.layoutSubtreeIfNeeded()
            samples["resize", default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(20))
            start = ProcessInfo.processInfo.systemUptime
            let y = max(0, editor.bounds.height - scroll.contentView.bounds.height) * CGFloat(cycle % 10) / 10
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            content.layoutSubtreeIfNeeded()
            samples["scroll", default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if !large {
                start = ProcessInfo.processInfo.systemUptime
                fixture.state.togglePreview()
                content.layoutSubtreeIfNeeded()
                samples["preview-toggle", default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            fixture.state.toggleSidebar()
            try await Task.sleep(for: .milliseconds(60))
            if cycle.isMultiple(of: 5) { rss.append(residentSize()) }
        }
        try await Task.sleep(for: .seconds(1))
        rss.append(residentSize())
        XCTAssertTrue(descendants(in: content, of: LacTextView.self).first === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 10, length: 4))
        XCTAssertEqual(fixture.document.synchronizedText(), text)
        for (name, values) in samples.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            print(String(format: "UI3_METRIC %@ median_ms=%.3f p95_ms=%.3f max_ms=%.3f count=%d", name,
                         sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!, sorted.count))
        }
        print("UI3_METRIC bytes=\(text.utf8.count) host_rss_bytes=\(rss)")
        fflush(stdout)
    }

    func testPreviewToggleKeepsEditorUndoWebViewAndSplitRatio() async throws {
        _ = NSApplication.shared
        let text = """
        # 留一点空白

        轻量的编辑器，让注意力回到文字。
        A quiet place to write and think.

        ## 把想法写下来

        1. 记录今天的灵感
           1. 留住细节
           2. 整理线索
        2. 写下第一稿

        > 不急着写完，先把这一句写好。

        | 内容 | 状态 |
        | --- | --- |
        | 文字与代码 | 随时开始 |

        ```swift
        let message = "你好，LacEditor"
        print(message)
        ```
        """
        let fixture = try UI2Fixture(text: text, language: .markdown)
        defer { fixture.dispose() }
        let draft = fixture.directory.appendingPathComponent("draft.md")
        try text.write(to: draft, atomically: true, encoding: .utf8)
        fixture.document.url = draft
        fixture.manager.recentFiles.record(draft)
        fixture.manager.sidebarLibrary.toggleFavorite(draft)
        fixture.state.isSidebarVisible = true
        fixture.document.isPreviewVisible = true
        try await Task.sleep(for: .milliseconds(500))
        let window = try XCTUnwrap(fixture.state.hostWindow)
        let content = try XCTUnwrap(window.contentView)
        func findSplit(in view: NSView) -> NativeEditorSplitController? {
            if let split = view as? NSSplitView, let controller = split.delegate as? NativeEditorSplitController { return controller }
            return view.subviews.lazy.compactMap { findSplit(in: $0) }.first
        }
        let split = try XCTUnwrap(findSplit(in: content))
        let editor = try XCTUnwrap(descendants(in: content, of: LacTextView.self).first)
        let webView = try XCTUnwrap(descendants(in: content, of: MarkdownWebView.self).first)
        window.makeFirstResponder(editor)
        editor.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(300))
        let editedText = editor.string
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        editor.setSelectedRange(NSRange(location: 10, length: 3))
        split.splitView.setPosition((split.splitView.bounds.width - split.splitView.dividerThickness) * 0.62, ofDividerAt: 0)
        content.layoutSubtreeIfNeeded()
        let fraction = split.splitView.subviews[0].frame.width / (split.splitView.bounds.width - split.splitView.dividerThickness)
        for _ in 0..<6 {
            fixture.state.togglePreview()
            try await Task.sleep(for: .milliseconds(35))
            content.layoutSubtreeIfNeeded()
            fixture.state.togglePreview()
            try await Task.sleep(for: .milliseconds(35))
            content.layoutSubtreeIfNeeded()
            XCTAssertTrue(descendants(in: content, of: LacTextView.self).first === editor)
            XCTAssertTrue(descendants(in: content, of: MarkdownWebView.self).first === webView)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 10, length: 3))
            XCTAssertEqual(split.splitView.subviews[0].frame.width / (split.splitView.bounds.width - split.splitView.dividerThickness),
                           fraction, accuracy: 0.015)
        }
        XCTAssertEqual(editor.string, editedText)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, text, "Preview toggling must preserve the real text undo operation")
        for theme: AppTheme in [.light, .dark] {
            fixture.preferences.theme = theme
            split.splitView.setPosition((split.splitView.bounds.width - split.splitView.dividerThickness) * 0.5, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(400))
            try await captureFixture(window, name: "UI3-preview-\(theme.rawValue)")
        }
    }

    func testSettingsPagesFitMinimumWindowAndKeepNativeScrollContainers() async throws {
        _ = NSApplication.shared
        let fixture = try UI2Fixture()
        defer { fixture.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        defer { window.contentViewController = nil; window.close() }
        for theme: AppTheme in [.light, .dark] {
            fixture.preferences.theme = theme
            for section in SettingsSection.allCases {
                window.contentViewController = NSHostingController(rootView:
                    UtilityWindowRoot(appState: fixture.state) { SettingsView(initialSection: section) })
                window.setContentSize(NSSize(width: 720, height: 520))
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(180))
                let content = try XCTUnwrap(window.contentView)
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(content.bounds.width, 720, accuracy: 1)
                XCTAssertEqual(content.bounds.height, 520, accuracy: 1)
                let scrolls = descendants(in: content, of: NSScrollView.self)
                XCTAssertFalse(scrolls.isEmpty, "Every settings page must remain scrollable")
                for scroll in scrolls {
                    XCTAssertLessThanOrEqual(scroll.bounds.width, 720)
                    XCTAssertFalse(scroll.hasHorizontalScroller)
                    XCTAssertEqual(scroll.scrollerStyle, NSScroller.preferredScrollerStyle)
                }
                XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                               theme == .light ? .aqua : .darkAqua)
                try await captureFixture(window, name: "settings-\(section.id)-\(theme.rawValue)")
            }
        }
    }

    func testUtilityWindowsRetainPresentationThemeAndPreviewInvalidation() async throws {
        _ = NSApplication.shared
        let fixture = try UI2Fixture()
        defer { fixture.dispose() }
        let parent = try XCTUnwrap(fixture.state.hostWindow)
        try await Task.sleep(for: .milliseconds(250)) // Allow native window registration.
        let settings = SettingsWindowController(applicationIsActive: { true })
        settings.present(windowManager: fixture.manager)
        try await Task.sleep(for: .milliseconds(250))
        let settingsWindow = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "LacEditor.SettingsWindow" && $0.isVisible
        })
        let settingsRoot = settingsWindow.contentViewController
        settings.present(windowManager: fixture.manager)
        XCTAssertTrue(settingsWindow.contentViewController === settingsRoot,
                      "Re-presenting settings must not reset its navigation and scroll state")
        try await Task.sleep(for: .milliseconds(250))
        // The command-line XCTest host does not participate in foreground
        // application activation. Verify presentation here; real key-window
        // routing remains an application-level acceptance check.
        XCTAssertTrue(settingsWindow.isVisible && settingsWindow.canBecomeKey)
        settingsWindow.performClose(nil)

        let find = FindReplaceWindowController(appState: fixture.state)
        let codec = TextTransformationWindowController(appState: fixture.state)
        defer {
            find.window?.contentViewController = nil
            find.window?.delegate = nil
            find.window?.close()
            codec.dispose()
        }
        fixture.state.findReplace.query = "LacEditor"
        fixture.state.findReplace.replacement = "轻装编辑"
        fixture.state.textTransformation.present(TextTransformationPreview(
            documentID: fixture.document.id, range: NSRange(location: 0, length: 9),
            input: String(repeating: "%E4%BD%A0%E5%A5%BD%20LacEditor%0A", count: 80),
            output: String(repeating: "你好 LacEditor\n", count: 80), editorRevision: 0,
            operation: .urlDecode, detectedKind: .url))
        for theme: AppTheme in [.light, .dark] {
            fixture.preferences.theme = theme
            find.present(mode: .replace, relativeTo: parent)
            let findWindow = try XCTUnwrap(find.window)
            findWindow.setContentSize(findWindow.contentMinSize)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(findWindow.isVisible && findWindow.canBecomeKey)
            XCTAssertTrue(parent.isVisible)
            XCTAssertNil(NSApp.modalWindow)
            XCTAssertEqual(findWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                           theme == .light ? .aqua : .darkAqua)
            XCTAssertLessThanOrEqual(findWindow.contentView!.fittingSize.height,
                                     findWindow.contentMinSize.height + 1)
            try await captureFixture(findWindow, name: "find-\(theme.rawValue)")
            find.dismiss()
            codec.present(relativeTo: parent)
            let codecWindow = try XCTUnwrap(codec.window)
            codecWindow.setContentSize(codecWindow.contentMinSize)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(codecWindow.isVisible && codecWindow.canBecomeKey)
            XCTAssertEqual(codecWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                           theme == .light ? .aqua : .darkAqua)
            let scrolls = descendants(in: codecWindow.contentView!, of: NSScrollView.self)
            XCTAssertEqual(scrolls.count, 2)
            XCTAssertTrue(scrolls.allSatisfy { !$0.hasHorizontalScroller })
            try await captureFixture(codecWindow, name: "codec-\(theme.rawValue)")
        }
        fixture.state.textTransformation.invalidate(documentID: fixture.document.id)
        XCTAssertFalse(fixture.state.textTransformation.canReplace)
        XCTAssertNotNil(fixture.state.textTransformation.message)
        XCTAssertEqual(fixture.document.text, "LacEditor 测试正文\n")
        codec.window?.performClose(nil)
        XCTAssertNil(fixture.state.textTransformation.preview)
    }

    private func descendants<T: NSView>(in view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(in: $0, of: type) }
    }

    func testStatusBarKeepsItsHeightWhenNarrowBusyOrShowingLongErrors() async throws {
        _ = NSApplication.shared
        let fixture = try UI2Fixture()
        defer { fixture.dispose() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 24),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            UtilityWindowRoot(appState: fixture.state) {
                StatusBarView(document: fixture.document)
            })
        window.center()
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        fixture.document.performanceProfile = .large
        fixture.document.statusMessage = L10n.tr("JSON 无效") + L10n.tr("：第 %@ 行，第 %@ 列。%@", "128", "24", "Missing closing bracket")
        for width: CGFloat in [360, 620, 900] {
            window.setContentSize(NSSize(width: width, height: 24))
            fixture.document.ioState = .saving
            try await Task.sleep(for: .milliseconds(230))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.bounds.height, 24, accuracy: 0.5)
            XCTAssertLessThanOrEqual(content.fittingSize.width, width + 1)
            try await captureFixture(window, name: "status-\(Int(width))")
            fixture.document.ioState = .idle
        }
        XCTAssertEqual(fixture.document.text, "LacEditor 测试正文\n")
    }

    private func captureFixture(_ window: NSWindow, name: String) async throws {
        guard ProcessInfo.processInfo.environment["LACEDITOR_UI_SNAPSHOTS"] == "1" else { return }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/UIExperimentSnapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("\(name).png").path]
        try capture.run()
        while capture.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(capture.terminationStatus, 0)
    }

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
        XCTAssertEqual(own.scrollerStyle, NSScroller.preferredScrollerStyle)
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

@MainActor
private final class UI2Fixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let preferences: AppPreferences
    let manager: WindowManager
    let document: EditorDocument
    let state: AppState

    init(text: String = "LacEditor 测试正文\n", language: EditorLanguage = .plainText) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "LacEditorTests.ui2.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        preferences = AppPreferences(defaults: defaults)
        manager = WindowManager(preferences: preferences, recentFiles: RecentFilesStore(defaults: defaults),
                                sidebarLibrary: SidebarLibraryStore(storageURL: directory.appendingPathComponent("library.json")))
        document = EditorDocument(text: text, language: language)
        state = manager.openNewWindow(with: document)
    }

    func dispose() {
        state.closeAuxiliaryWindows()
        state.hostWindow?.delegate = nil
        state.hostWindow?.contentViewController = nil
        state.hostWindow?.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
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
