import AppKit
import XCTest
@testable import LacEditor

final class SystemWritingChecksTests: XCTestCase {
    @MainActor
    func testDataImageDisablesSystemWritingChecks() {
        let view = NSTextView()
        view.string = "![alt](data:image/png;base64,AAAA+/==)"

        EditorTextView.applyWritingChecks(to: view, spellingEnabled: true, grammarEnabled: true)

        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isGrammarCheckingEnabled)
    }

    @MainActor
    func testFlagsAndAutomaticCorrection() {
        let view = NSTextView()
        for spelling in [false, true] {
            for grammar in [false, true] {
                EditorTextView.applyWritingChecks(to: view, spellingEnabled: spelling, grammarEnabled: grammar)
                XCTAssertEqual(view.isContinuousSpellCheckingEnabled, spelling)
                XCTAssertEqual(view.isGrammarCheckingEnabled, grammar)
                XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
            }
        }
    }
}
