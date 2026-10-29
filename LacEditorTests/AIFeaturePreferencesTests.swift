import Foundation
import XCTest
@testable import LacEditor

final class AIFeaturePreferencesTests: XCTestCase {
    @MainActor
    func testUppercaseHeadingLevelsDefaultEmptyAndPersist() throws {
        let suite = "LacEditor-Uppercase-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.markdownUppercaseHeadingLevels.isEmpty)
        preferences.markdownUppercaseHeadingLevels = [1, 3, 8]
        XCTAssertEqual(preferences.markdownUppercaseHeadingLevels, [1, 3])
        XCTAssertEqual(preferences.markdownTypography?.uppercaseHeadingLevels, [1, 3])
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownUppercaseHeadingLevels, [1, 3])
    }

    @MainActor
    func testListStyleOverridesPersistByDepth() throws {
        let suite = "LacEditor-ListStyles-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.markdownListStyles, .init())
        preferences.markdownListStyles.ordered[1] = .lowerAlpha
        preferences.markdownListStyles.unordered[3] = .custom
        preferences.markdownListStyles.customMarkers[3] = "😀 \" <"
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownTypography?.listStyles, restored.markdownListStyles)
        XCTAssertEqual(restored.markdownListStyles.orderedStyle(at: 2), .lowerAlpha)
        XCTAssertEqual(restored.markdownListStyles.unorderedMarker(at: 4), "😀 \" <")
        restored.markdownListStyles = .init()
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownListStyles, .init())
    }

    @MainActor
    func testHeadingNumberingPreferenceDefaultsOffAndPersists() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.markdownNumberHeadings)
        preferences.markdownNumberHeadings = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertTrue(restored.markdownNumberHeadings)
        restored.markdownNumberHeadings = false
        XCTAssertFalse(AppPreferences(defaults: defaults).markdownNumberHeadings)
    }
    @MainActor
    func testVerticalWritingPreferencePersists() throws {
        let suite = "LacEditor-Vertical-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.markdownVerticalWriting)
        preferences.markdownVerticalWriting = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownTypography?.verticalWriting, true)
        XCTAssertEqual(restored.markdownTypography?.usesCustomFontMetrics, false)
        restored.markdownVerticalWriting = false
        XCTAssertNil(AppPreferences(defaults: defaults).markdownTypography)
    }

    @MainActor
    func testStrikeCompletedTasksPersists() throws {
        let suite = "LacEditor-Tasks-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.markdownStrikeCompletedTasks)
        preferences.markdownStrikeCompletedTasks = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownTypography?.strikeCompletedTasks, true)
        restored.markdownStrikeCompletedTasks = false
        XCTAssertNil(AppPreferences(defaults: defaults).markdownTypography)
    }

    @MainActor
    func testRightToLeftPreferencePersistsWithoutChangingFonts() throws {
        let suite = "LacEditor-RTL-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.markdownRightToLeft)
        preferences.markdownRightToLeft = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertTrue(restored.markdownRightToLeft)
        XCTAssertEqual(restored.markdownTypography?.rightToLeft, true)
        XCTAssertEqual(restored.markdownTypography?.usesCustomFontMetrics, false)
        restored.markdownRightToLeft = false
        XCTAssertNil(AppPreferences(defaults: defaults).markdownTypography)
    }

    @MainActor
    func testCenteredHeadingLevelsPersist() throws {
        let suite = "LacEditor-CenteredHeadings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.markdownCenteredHeadingLevels.isEmpty)
        preferences.markdownCenteredHeadingLevels = [1, 3, 7]
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownCenteredHeadingLevels, [1, 3])
        XCTAssertEqual(restored.markdownTypography?.centeredHeadingLevels, [1, 3])
        XCTAssertEqual(restored.markdownTypography?.usesCustomFontMetrics, false)
        restored.markdownCenteredHeadingLevels = []
        XCTAssertNil(AppPreferences(defaults: defaults).markdownTypography)
    }

    @MainActor
    func testParagraphTypographyPersistsWithoutChangingFontMetrics() throws {
        let suite = "LacEditor-Paragraph-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertNil(preferences.markdownTextAlignment)
        XCTAssertNil(preferences.markdownParagraphSpacing)
        XCTAssertNil(preferences.markdownTypography)
        preferences.markdownTextAlignment = .justify
        preferences.markdownParagraphSpacing = 12
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownTextAlignment, .justify)
        XCTAssertEqual(restored.markdownParagraphSpacing, 12)
        XCTAssertEqual(restored.markdownTypography?.textAlignment, "justify")
        XCTAssertEqual(restored.markdownTypography?.paragraphSpacing, 12)
        XCTAssertEqual(restored.markdownTypography?.usesCustomFontMetrics, false)
        restored.markdownTextAlignment = nil
        restored.markdownParagraphSpacing = nil
        XCTAssertNil(AppPreferences(defaults: defaults).markdownTypography)
    }

    @MainActor
    func testSmallCapsLevelsPersistWithoutChangingOtherTypography() throws {
        let suite = "LacEditor-SmallCaps-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.markdownSmallCapsLevels.isEmpty)
        XCTAssertNil(preferences.markdownTypography)
        preferences.markdownSmallCapsLevels = [1, 4]
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownSmallCapsLevels, [1, 4])
        XCTAssertEqual(restored.markdownTypography?.smallCapsLevels, [1, 4])
        XCTAssertEqual(restored.markdownTypography?.usesCustomFontMetrics, false)
        restored.markdownSmallCapsLevels = []
        XCTAssertNil(AppPreferences(defaults: defaults).markdownTypography)
    }

    @MainActor
    func testLigaturesPreserveLegacyDefaultsAndPersistSeparately() throws {
        let suite = "LacEditor-Ligatures-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertNil(preferences.editorLigatures)
        XCTAssertNil(preferences.markdownTypography)
        preferences.editorLigatures = 0
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.editorLigatures, 0)
        XCTAssertEqual(restored.markdownTypography?.ligatures, 0)
        XCTAssertEqual(restored.markdownTypography?.usesCustomFontMetrics, false)
        restored.editorLigatures = 2
        XCTAssertEqual(AppPreferences(defaults: defaults).editorLigatures, 2)
        restored.editorLigatures = nil
        XCTAssertNil(AppPreferences(defaults: defaults).markdownTypography)
    }

    @MainActor
    func testMathOptionsPersistWithCompatibleDefaults() throws {
        let suite = "LacEditor-Math-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.mathPhysicsEnabled)
        XCTAssertEqual(preferences.mathNumbering, .none)
        preferences.mathPhysicsEnabled = false
        preferences.mathNumbering = .ams
        let restored = AppPreferences(defaults: defaults)
        XCTAssertFalse(restored.mathPhysicsEnabled)
        XCTAssertEqual(restored.mathNumbering, .ams)
        restored.mathNumbering = .all
        XCTAssertEqual(AppPreferences(defaults: defaults).mathNumbering, .all)
    }

    @MainActor
    func testNativeExportOptionsPersistWithCompatibleDefaults() throws {
        let suite = "LacEditor-NativeExport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.markdownNativeExportOptions, MarkdownNativeExportOptions())
        XCTAssertNil(preferences.markdownNativeExportOptions.pageBreakTopHeadings)
        preferences.markdownNativeExportOptions.pageBreakTopHeadings = true
        preferences.markdownNativeExportOptions.paper = "a4"
        preferences.markdownNativeExportOptions.customMargins = true
        preferences.markdownNativeExportOptions.marginLeft = 42
        preferences.markdownNativeExportOptions.imageWidth = 640
        preferences.markdownNativeExportOptions.imageQuality = "high"
        preferences.markdownNativeExportOptions.customImageFontSize = true
        preferences.markdownNativeExportOptions.imageFontSize = 24
        preferences.markdownPDFHeaderFooterOptions.header = "${title}"
        preferences.markdownPDFHeaderFooterOptions.allowDocumentOverrides = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownNativeExportOptions, preferences.markdownNativeExportOptions)
        XCTAssertEqual(restored.markdownPDFHeaderFooterOptions, preferences.markdownPDFHeaderFooterOptions)
    }

    @MainActor
    func testHTMLExportOptionsHaveCompatibleDefaultsAndPersist() throws {
        let suite = "LacEditor-HTMLExport-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.markdownHTMLExportOptions, MarkdownHTMLExportOptions())
        preferences.markdownHTMLExportOptions.appendHead = "<meta name=\"title\" content=\"${title}\">"
        preferences.markdownHTMLExportOptions.appendBody = "<script>console.log('hello')</script>"
        preferences.markdownHTMLExportOptions.allowDocumentOverrides = true
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownHTMLExportOptions, preferences.markdownHTMLExportOptions)
    }

    @MainActor
    func testStatisticsPreferencesPersistAndRejectNonPositiveSpeed() throws {
        let suite = "LacEditor-Statistics-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.statisticsDisplayUnit, .words)
        XCTAssertEqual(preferences.readingWordsPerMinute, 200)
        for unit in StatisticsDisplayUnit.allCases {
            preferences.statisticsDisplayUnit = unit
            XCTAssertEqual(AppPreferences(defaults: defaults).statisticsDisplayUnit, unit)
        }
        preferences.readingWordsPerMinute = Int.max
        XCTAssertEqual(AppPreferences(defaults: defaults).readingWordsPerMinute, Int.max)
        preferences.readingWordsPerMinute = 0
        XCTAssertEqual(preferences.readingWordsPerMinute, Int.max)
        preferences.readingWordsPerMinute = -1
        XCTAssertEqual(preferences.readingWordsPerMinute, Int.max)
        XCTAssertEqual(AppPreferences(defaults: defaults).readingWordsPerMinute, Int.max)
        defaults.set(-10, forKey: "readingWordsPerMinute")
        defaults.set("future", forKey: "statisticsDisplayUnit")
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.readingWordsPerMinute, 200)
        XCTAssertEqual(restored.statisticsDisplayUnit, .words)
    }

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
