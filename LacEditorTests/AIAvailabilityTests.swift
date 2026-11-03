import XCTest
@testable import LacEditor

@MainActor
final class AIAvailabilityTests: XCTestCase {
    private func makeState(_ body: (AppPreferences) -> Void = { _ in }) throws -> (AppState, AppPreferences, () -> Void) {
        let suite = "LacEditor-AIAvailability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        body(preferences)
        let state = AppState(initialDocument: EditorDocument(text: "x"), recentFiles: RecentFilesStore(defaults: defaults), preferences: preferences)
        return (state, preferences, { defaults.removePersistentDomain(forName: suite) })
    }

    private func enableText(_ preferences: AppPreferences, modelID: String) {
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.modelID = modelID
        preferences.aiConfiguration = configuration
    }

    func testConnectionDisabledByDefault() throws {
        let (state, _, cleanup) = try makeState()
        defer { cleanup() }
        for feature in [AIFeature.summary, .styleReview] {
            XCTAssertEqual(state.aiAvailability(for: feature), .aiDisabled)
        }
    }

    func testFeatureDisabled() throws {
        let (state, preferences, cleanup) = try makeState()
        defer { cleanup() }
        enableText(preferences, modelID: "m")
        preferences.aiFeatures = []
        XCTAssertEqual(state.aiAvailability(for: .summary), .featureDisabled)
    }

    func testNoModel() throws {
        let (state, preferences, cleanup) = try makeState()
        defer { cleanup() }
        enableText(preferences, modelID: "")
        preferences.aiFeatures = [.summary]
        preferences.aiFeatureModelIDs = [:]
        XCTAssertEqual(state.aiAvailability(for: .summary), .noModel)
    }

    func testAvailable() throws {
        let (state, preferences, cleanup) = try makeState()
        defer { cleanup() }
        enableText(preferences, modelID: "m")
        preferences.aiFeatures = [.summary]
        XCTAssertEqual(state.aiAvailability(for: .summary), .available)

        enableText(preferences, modelID: "")
        preferences.aiFeatures = [.styleReview]
        preferences.aiFeatureModelIDs["styleReview"] = "x"
        XCTAssertEqual(state.aiAvailability(for: .styleReview), .available)
    }

    func testDisabledConnectionWinsOverDisabledFeature() throws {
        let (state, preferences, cleanup) = try makeState()
        defer { cleanup() }
        preferences.aiFeatures = []
        XCTAssertEqual(state.aiAvailability(for: .summary), .aiDisabled)
    }

    func testNewFeaturesAreEvaluated() throws {
        let (state, _, cleanup) = try makeState()
        defer { cleanup() }
        for feature in AIFeature.allCases where feature.isWriterFeature {
            XCTAssertEqual(state.aiAvailability(for: feature), .aiDisabled)
        }
    }
}

final class AIHintStoreTests: XCTestCase {
    func testDismissAndResetAreIsolatedByFeatureAndSuite() throws {
        let suite = "LacEditor-AIHints-\(UUID().uuidString)"
        let other = "LacEditor-AIHints-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: other))
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: other)
        }
        let store = AIHintStore(defaults: defaults)
        XCTAssertFalse(store.isDismissed(.styleReview))
        store.dismiss(.styleReview)
        XCTAssertTrue(store.isDismissed(.styleReview))
        XCTAssertFalse(store.isDismissed(.mindMap))
        XCTAssertTrue(AIHintStore(defaults: defaults).isDismissed(.styleReview))
        XCTAssertFalse(AIHintStore(defaults: otherDefaults).isDismissed(.styleReview))
        store.dismiss(.mindMap)
        store.resetAll()
        XCTAssertFalse(store.isDismissed(.styleReview))
        XCTAssertFalse(store.isDismissed(.mindMap))
    }
}
