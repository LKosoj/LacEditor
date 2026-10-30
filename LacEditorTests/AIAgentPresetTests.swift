import XCTest
@testable import LacEditor

@MainActor
final class AIAgentPresetTests: XCTestCase {
    private func catalog(_ language: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testFiveCasesAndTextsInAllLanguages() throws {
        XCTAssertEqual(AIAgentPreset.allCases.count, 5)
        let name = "LacEditor.AIAgentPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); L10n.configure() }
        for language in ["zh-Hans", "en", "ru"] {
            defaults.set(language, forKey: L10n.languageKey)
            L10n.configure(defaults: defaults)
            for preset in AIAgentPreset.allCases {
                XCTAssertFalse(preset.title.isEmpty, language)
                XCTAssertFalse(preset.summary.isEmpty, language)
                XCTAssertFalse(preset.taskText.isEmpty, language)
            }
        }
    }

    func testKeysExistInCatalogs() throws {
        // Ключи каталога китайские: на другом языке L10n.tr вернул бы перевод
        let name = "LacEditor.AIAgentPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); L10n.configure() }
        defaults.set("zh-Hans", forKey: L10n.languageKey)
        L10n.configure(defaults: defaults)
        let keys = AIAgentPreset.allCases.flatMap(\.catalogKeys)
            + [AIAgentPreset.webHintAvailable, AIAgentPreset.webHintLocked, AIAgentPreset.webHintUnavailable]
        for language in ["zh-Hans", "en", "ru"] {
            let strings = try catalog(language)
            for key in keys { XCTAssertNotNil(strings[key], "\(language): \(key)") }
        }
    }

    func testTaskTextsMentionTools() {
        let known = Set(AIAgentTools.definitions.map(\.name))
        XCTAssertTrue(known.contains("update_plan") && known.contains("propose_edit"))
        XCTAssertTrue(AIAgentPreset.factCheck.taskText.contains("update_plan"))
        XCTAssertTrue(AIAgentPreset.translateLong.taskText.contains("propose_edit"))
        XCTAssertTrue(AIAgentPreset.consistencyAcrossDocuments.taskText.contains("search_text"))
        XCTAssertTrue(AIAgentPreset.folderEdit.taskText.contains("propose_edit"))
        XCTAssertTrue(AIAgentPreset.draftFromNotes.taskText.contains("document_links"))
    }

    func testWebHint() {
        let web = AIAgentPreset.factCheck
        XCTAssertNil(AIAgentPreset.webHint(for: .folderEdit, webEnabled: false, available: true, locked: false))
        XCTAssertNil(AIAgentPreset.webHint(for: web, webEnabled: true, available: true, locked: false))
        XCTAssertEqual(AIAgentPreset.webHint(for: web, webEnabled: false, available: false, locked: false), AIAgentPreset.webHintUnavailable)
        XCTAssertEqual(AIAgentPreset.webHint(for: web, webEnabled: false, available: true, locked: true), AIAgentPreset.webHintLocked)
        XCTAssertEqual(AIAgentPreset.webHint(for: web, webEnabled: false, available: true, locked: false), AIAgentPreset.webHintAvailable)
    }

    private func makeController() throws -> (AIAgentController, AppState) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditor-AIAgentPreset-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        let state = AppState(initialDocuments: [EditorDocument(text: "x")], recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        let controller = AIAgentController(appState: state, step: { _, _, _, _, _ in
            XCTFail("сценарий не должен отправлять запрос")
            return AIAgentStep(calls: [], echoed: [], text: "", usage: AIUsage())
        }, loadKey: { _, _ in nil }, loadJinaKey: { _, _ in nil })
        return (controller, state)
    }

    func testApplyPresetFillsAndAppends() throws {
        let (controller, _) = try makeController()
        controller.applyPreset(.factCheck)
        XCTAssertEqual(controller.draft, AIAgentPreset.factCheck.taskText)
        controller.applyPreset(.folderEdit)
        XCTAssertEqual(controller.draft, AIAgentPreset.folderEdit.taskText)
        controller.draft = "моя задача"
        controller.applyPreset(.translateLong)
        XCTAssertEqual(controller.draft, "моя задача\n\n" + AIAgentPreset.translateLong.taskText)
        XCTAssertFalse(controller.webSearchEnabled)
    }

    func testHintAndReset() throws {
        let (controller, _) = try makeController()
        XCTAssertNil(controller.presetWebHint)
        controller.applyPreset(.factCheck)
        XCTAssertEqual(controller.selectedPreset, .factCheck)
        XCTAssertEqual(controller.presetWebHint, AIAgentPreset.webHintUnavailable)
        XCTAssertFalse(controller.webSearchEnabled)
        controller.draft = ""
        XCTAssertNil(controller.selectedPreset)
        controller.applyPreset(.folderEdit)
        XCTAssertNil(controller.presetWebHint)
        controller.newConversation()
        XCTAssertNil(controller.selectedPreset)
    }
}
