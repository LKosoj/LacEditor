import Foundation
import XCTest
@testable import LacEditor

final class AIFeaturePreferencesTests: XCTestCase {
    @MainActor
    func testFeaturesAndChecksPersistIndependently() throws {
        let suite = "LacEditor-AIFeatures-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.aiFeatures.isEmpty)
        XCTAssertFalse(preferences.aiBackgroundEnabled)
        XCTAssertFalse(preferences.systemSpellingEnabled)
        XCTAssertFalse(preferences.systemGrammarEnabled)
        preferences.aiFeatures = [.clarity, .translation]
        preferences.aiBackgroundEnabled = true
        preferences.systemGrammarEnabled = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.aiFeatures, [.clarity, .translation])
        XCTAssertTrue(restored.aiBackgroundEnabled)
        XCTAssertTrue(restored.systemGrammarEnabled)
        XCTAssertFalse(restored.systemSpellingEnabled)
        XCTAssertFalse(restored.aiConfiguration.text.isEnabled)
        restored.aiFeatures.remove(.clarity)
        restored.systemSpellingEnabled = true
        restored.systemGrammarEnabled = false
        let updated = AppPreferences(defaults: defaults)
        XCTAssertEqual(updated.aiFeatures, [.translation])
        XCTAssertTrue(updated.systemSpellingEnabled)
        XCTAssertFalse(updated.systemGrammarEnabled)
    }
    @MainActor
    func testFeatureModelsUseRoleSettingsAndPersistUnknownKeys() throws {
        let suite = "LacEditor-AIModels-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        var configuration = preferences.aiConfiguration
        configuration.text.modelID = "default-model"
        configuration.text.baseURL = "https://example.com/v1"
        configuration.text.isEnabled = true
        preferences.aiConfiguration = configuration
        XCTAssertEqual(preferences.aiProfile(for: .translation), configuration.text)
        preferences.aiFeatureModelIDs = [AIFeature.translation.rawValue: "  translate  ", "futureFeature": "future"]
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.aiProfile(for: .translation).modelID, "translate")
        XCTAssertEqual(restored.aiProfile(for: .summary), configuration.text)
        XCTAssertEqual(restored.aiProfile(for: .translation).baseURL, configuration.text.baseURL)
        XCTAssertEqual(restored.aiProfile(for: .translation).isEnabled, configuration.text.isEnabled)
        restored.aiFeatureModelIDs[AIFeature.translation.rawValue] = "  "
        XCTAssertEqual(restored.aiProfile(for: .translation).modelID, "default-model")
        XCTAssertEqual(AppPreferences(defaults: defaults).aiFeatureModelIDs["futureFeature"], "future")
    }

    @MainActor
    func testCustomCheckModelOverridesOnlyItsFeature() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditor-AIModels-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatureModelIDs[AIFeature.customCheck.rawValue] = "check-default"
        var check = AICustomCheck(modelID: "  own-model  ")
        XCTAssertEqual(preferences.aiProfile(for: .customCheck, customCheck: check).modelID, "own-model")
        check.modelID = "  "
        XCTAssertEqual(preferences.aiProfile(for: .customCheck, customCheck: check).modelID, "check-default")
        XCTAssertEqual(preferences.aiProfile(for: .summary, customCheck: AICustomCheck(modelID: "other")), preferences.aiConfiguration.text)
    }

}
