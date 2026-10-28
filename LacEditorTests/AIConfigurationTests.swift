import Foundation
import XCTest
@testable import LacEditor

final class AIConfigurationTests: XCTestCase {
    func testProfilesRoundTripWithoutSecrets() throws {
        var configuration = AIConfiguration()
        configuration.text.modelID = "model"
        configuration.decisions.api = .chatCompletions
        configuration.image.baseURL = "http://localhost:8000/v1"
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(AIConfiguration.self, from: data), configuration)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("key"))
        XCTAssertFalse(configuration.text.isEnabled)
        XCTAssertTrue(configuration.decisions.supports(.decisions))
        XCTAssertFalse(configuration.image.supports(.text))
    }

    func testAddressNormalizationAndInvalidAddresses() throws {
        let normalized = try AIModelProfile.normalizedBaseURL("HTTPS://EXAMPLE.COM:443/v1/")
        XCTAssertEqual(normalized.absoluteString, "https://example.com/v1")
        for value in ["https://user:password@example.com/v1", "https://example.com/v1?token=secret", "file:///tmp"] {
            XCTAssertThrowsError(try AIModelProfile.normalizedBaseURL(value))
        }
    }
    @MainActor
    func testPreferencesPersistConfigurationInIsolatedDefaults() throws {
        let suite = "LacEditor-AI-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.aiConfiguration, AIConfiguration())
        var configuration = preferences.aiConfiguration
        configuration.text.isEnabled = true
        configuration.text.modelID = "example"
        configuration.decisions.api = .chatCompletions
        preferences.aiConfiguration = configuration
        XCTAssertEqual(AppPreferences(defaults: defaults).aiConfiguration, configuration)
        let data = try XCTUnwrap(defaults.data(forKey: "aiConfiguration"))
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).localizedCaseInsensitiveContains("key"))
    }

}

extension AIConfigurationTests {
    func testLegacyProfilesSurviveAddingMediaProfiles() throws {
        let json = #"{"text":{"isEnabled":true,"baseURL":"https://example.com/v1","modelID":"legacy","api":"responses"},"decisions":{"isEnabled":false,"baseURL":"https://example.com/v1","modelID":"decision","api":"decisions"},"image":{"isEnabled":true,"baseURL":"https://example.com/v1","modelID":"image","api":"images"}}"#
        let value = try JSONDecoder().decode(AIConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(value.text.modelID, "legacy")
        XCTAssertTrue(value.text.isEnabled)
        XCTAssertEqual(value.decisions.modelID, "decision")
        XCTAssertEqual(value.image.modelID, "image")
        XCTAssertEqual(value.ocr, .default(for: .ocr))
        XCTAssertEqual(value.audio, .default(for: .audio))
        XCTAssertTrue(value.ocr.supports(.ocr))
        XCTAssertTrue(value.audio.supports(.audio))
        XCTAssertFalse(value.audio.supports(.ocr))
    }
}
