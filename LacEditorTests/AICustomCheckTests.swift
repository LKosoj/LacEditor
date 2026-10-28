import XCTest
@testable import LacEditor

@MainActor
final class AICustomCheckTests: XCTestCase {
    func testChecksPersistSeparately() throws {
        let suite = "AICustomCheckTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let check = AICustomCheck(name: "Test", instructions: "Check it")
        XCTAssertFalse(check.isEnabled)
        preferences.aiCustomChecks = [check]
        XCTAssertEqual(AppPreferences(defaults: defaults).aiCustomChecks, [check])
    }
    func testOldCheckJSONKeepsExistingFields() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","name":"Old","instructions":"Review","isEnabled":true}
        """
        let check = try JSONDecoder().decode(AICustomCheck.self, from: Data(json.utf8))
        XCTAssertEqual(check.id, id)
        XCTAssertEqual(check.name, "Old")
        XCTAssertEqual(check.instructions, "Review")
        XCTAssertTrue(check.isEnabled)
        XCTAssertEqual(check.modelID, "")
    }

}
