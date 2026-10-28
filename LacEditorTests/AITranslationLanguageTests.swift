import XCTest
@testable import LacEditor

final class AITranslationLanguageTests: XCTestCase {
    func testSupportedLanguagesAndCustomName() {
        let names = AITranslationLanguage.allCases.filter { $0 != .custom }.map { $0.targetName(customName: "ignored") }
        XCTAssertEqual(names, ["English", "Russian", "Simplified Chinese", "Traditional Chinese", "German", "French", "Spanish", "Portuguese", "Italian", "Ukrainian", "Japanese", "Korean", "Arabic"])
        XCTAssertEqual(AITranslationLanguage.custom.targetName(customName: "  Ελληνικά \n"), "Ελληνικά")
        XCTAssertEqual(AITranslationLanguage.custom.targetName(customName: " \n"), "")
        XCTAssertNotEqual(AITranslationLanguage.simplifiedChinese.targetName(customName: ""), AITranslationLanguage.traditionalChinese.targetName(customName: ""))
    }
}
