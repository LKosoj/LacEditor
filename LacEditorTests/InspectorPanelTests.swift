import XCTest
@testable import LacEditor

@MainActor
final class InspectorPanelTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor").appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testAvailableSegments() {
        XCTAssertEqual(InspectorSegment.available(isWriter: false), [.style, .ai])
        XCTAssertEqual(InspectorSegment.available(isWriter: true), [.scene, .style, .ai])
    }

    func testResolveFallsBackToAI() {
        XCTAssertEqual(InspectorSegment.resolve(.scene, isWriter: false), .ai)
        XCTAssertEqual(InspectorSegment.resolve(.scene, isWriter: true), .scene)
        XCTAssertEqual(InspectorSegment.resolve(.style, isWriter: false), .style)
        XCTAssertEqual(InspectorSegment.resolve(.ai, isWriter: true), .ai)
    }

    func testStoredSegmentsAreSeparatePerMode() throws {
        let suite = "LacEditor-Inspector-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(InspectorSegment.stored(isWriter: false, defaults: defaults), .ai)
        XCTAssertEqual(InspectorSegment.stored(isWriter: true, defaults: defaults), .ai)
        InspectorSegment.store(.style, isWriter: false, defaults: defaults)
        InspectorSegment.store(.scene, isWriter: true, defaults: defaults)
        XCTAssertEqual(InspectorSegment.stored(isWriter: false, defaults: defaults), .style)
        XCTAssertEqual(InspectorSegment.stored(isWriter: true, defaults: defaults), .scene)
        defaults.set("мусор", forKey: "inspectorSegment.writer")
        XCTAssertEqual(InspectorSegment.stored(isWriter: true, defaults: defaults), .ai)
    }

    func testAppStateDefaultsToAIAndNormalTab() throws {
        let suite = "LacEditor-InspectorState-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(initialDocument: EditorDocument(text: "x"), recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        XCTAssertFalse(state.inspectorIsWriterTab)
        state.inspectorSegment = .scene
        XCTAssertEqual(state.effectiveInspectorSegment, .ai)
        state.inspectorSegment = .style
        XCTAssertEqual(state.effectiveInspectorSegment, .style)
    }

    func testSegmentTitles() {
        XCTAssertEqual(InspectorSegment.ai.title, "AI")
        XCTAssertEqual(InspectorSegment.style.title, L10n.tr("文风"))
        XCTAssertEqual(InspectorSegment.scene.title, L10n.tr("书稿场景"))
    }

    func testWiringInSources() throws {
        let commands = try source("App/LacEditorCommands.swift")
        XCTAssertEqual(commands.components(separatedBy: ".keyboardShortcut(\"0\", modifiers: [.command, .option])").count - 1, 1)
        let main = try source("Views/MainWindowView.swift")
        XCTAssertTrue(main.contains("InspectorPanelView("))
        XCTAssertFalse(main.contains("AIWritingView("))
        XCTAssertTrue(try source("Views/TitleToolbar.swift").contains("显示或隐藏检查器（⌥⌘0）"))
        XCTAssertTrue(try source("Views/AIWritingView.swift").contains("AIQuestionView(controller: controller.question"))
    }

    func testSettingsNavigator() {
        let navigator = SettingsNavigator()
        XCTAssertNil(navigator.request)
        navigator.open(.ai, aiPage: .connections)
        let first = navigator.request
        XCTAssertEqual(first?.section, .ai)
        XCTAssertEqual(first?.aiPage, .connections)
        navigator.open(.ai, aiPage: .connections)
        XCTAssertNotEqual(first?.id, navigator.request?.id)
        navigator.clear()
        XCTAssertNil(navigator.request)
    }
}
