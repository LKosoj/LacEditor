import AppKit
import XCTest
@testable import LacEditor

final class SystemWritingChecksTests: XCTestCase {
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
