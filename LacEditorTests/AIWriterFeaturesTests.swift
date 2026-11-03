import XCTest
@testable import LacEditor

@MainActor
final class AIWriterFeaturesTests: XCTestCase {
    private let writerFeatures: [AIFeature] = [.styleReview, .searchExpansion, .worldCards, .mindMap, .fountainAdaptation]

    func testNewFeaturesExistAndAreWriterFeatures() {
        for feature in writerFeatures {
            XCTAssertTrue(AIFeature.allCases.contains(feature))
            XCTAssertTrue(feature.isWriterFeature)
            XCTAssertEqual(AIFeature(rawValue: feature.rawValue), feature)
        }
        XCTAssertEqual(writerFeatures.map(\.rawValue), ["styleReview", "searchExpansion", "worldCards", "mindMap", "fountainAdaptation"])
        XCTAssertEqual(Set(AIFeature.allCases.filter(\.isWriterFeature)), Set(writerFeatures))
    }

    func testWriterFeaturesAreHiddenFromAIPanelList() throws {
        let suite = "LacEditor-AIWriterFeatures-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let state = AppState(initialDocument: EditorDocument(text: "x"), recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        preferences.aiFeatures = [.summary, .styleReview, .mindMap]
        XCTAssertEqual(state.aiWriting.enabledFeatures, [.summary])
    }

    func testWriterFeaturesHaveDescriptionsAndGroups() {
        for feature in writerFeatures {
            XCTAssertFalse(feature.title.isEmpty)
            XCTAssertFalse(feature.needs.isEmpty)
            XCTAssertFalse(feature.result.isEmpty)
            XCTAssertNotEqual(feature.needs, feature.result)
            XCTAssertTrue(feature.detail.contains(feature.needs))
            XCTAssertTrue(feature.detail.contains(feature.result))
            XCTAssertEqual(AIFeatureGroup.allCases.filter { AIFeature.features(in: $0).contains(feature) }.count, 1)
        }
    }

    func testFeatureModelOverrideForWriterFeature() throws {
        let suite = "LacEditor-AIWriterModel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.aiFeatureModelIDs["worldCards"] = "x"
        XCTAssertEqual(preferences.aiProfile(for: .worldCards).modelID, "x")
    }

    func testStoredWriterFeaturesRoundTrip() throws {
        let suite = "LacEditor-AIWriterStored-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppPreferences(defaults: defaults).aiFeatures = [.styleReview, .fountainAdaptation]
        XCTAssertEqual(AppPreferences(defaults: defaults).aiFeatures, [.styleReview, .fountainAdaptation])
    }
}
