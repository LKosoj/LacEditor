import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownAutoPairTests: XCTestCase {
    private func action(_ source: String, _ character: String, range: NSRange) -> MarkdownAutoPairService.Action? {
        MarkdownAutoPairService.action(in: source as NSString, selection: range, character: character, brackets: true, markdown: true, pairs: [])
    }

    func testPairsAndUnicodeSelection() throws {
        let selection = ("中文😀" as NSString).range(of: "文😀")
        for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("*", "*"), ("_", "_"), ("`", "`"), ("~", "~"), ("^", "^"), ("=", "=")] {
            guard case let .replace(range, text, selected, _)? = action("中文😀", opening, range: selection) else { XCTFail("Missing pair for \(opening)"); continue }
            let result = ("中文😀" as NSString).replacingCharacters(in: range, with: text)
            XCTAssertEqual(result, "中" + opening + "文😀" + closing)
            XCTAssertEqual((result as NSString).substring(with: selected), "文😀")
        }
        XCTAssertNil(action("😀", "(", range: NSRange(location: 1, length: 0)))
        XCTAssertNil(action("e\u{301}", "(", range: NSRange(location: 1, length: 0)))
    }

    func testEscapesAndCodeContexts() {
        XCTAssertNil(action("\\", "(", range: NSRange(location: 1, length: 0)))
        XCTAssertNotNil(action("\\\\", "(", range: NSRange(location: 2, length: 0)))
        for source in ["```\ncode\n```", "- ```\n  code\n  ```", "    code", "`line\ncode`"] {
            let position = (source as NSString).range(of: "code").location + 1
            XCTAssertNil(action(source, "*", range: NSRange(location: position, length: 0)), source)
        }
        XCTAssertNil(action("- ```", "(", range: NSRange(location: 5, length: 0)))
        XCTAssertNil(action("a `code` b", "(", range: ("a `code` b" as NSString).range(of: "code` b")))
    }

    func testPreferencesGateTheirOwnPairs() {
        let empty = NSRange(location: 0, length: 0)
        XCTAssertNil(action("", "~", range: empty)); XCTAssertNil(action("", "^", range: empty)); XCTAssertNil(action("", "=", range: empty)); XCTAssertNotNil(action("", "$", range: empty))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "$", brackets: true, markdown: false, pairs: []))
        XCTAssertNotNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "{", brackets: true, markdown: false, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "'", brackets: false, markdown: true, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "(", brackets: false, markdown: true, pairs: []))
        XCTAssertNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "*", brackets: true, markdown: false, pairs: []))
        XCTAssertNotNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "(", brackets: true, markdown: false, pairs: []))
        XCTAssertNotNil(MarkdownAutoPairService.action(in: "" as NSString, selection: empty, character: "*", brackets: false, markdown: true, pairs: []))
    }

    func testPreferencesAreIndependentAndDefaultOff() {
        let suite = "MarkdownAutoPairTests.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.autoPairBracketsEnabled); XCTAssertFalse(preferences.autoPairMarkdownEnabled)
        preferences.autoPairBracketsEnabled = true
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.autoPairBracketsEnabled); XCTAssertFalse(reloaded.autoPairMarkdownEnabled)
    }

    func testSystemTextSubstitutionPreferencesPersistIndependently() {
        let suite = "MarkdownTextSubstitutionTests.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.smartQuotesEnabled); XCTAssertFalse(preferences.smartDashesEnabled); XCTAssertFalse(preferences.systemTextReplacementEnabled)
        preferences.smartQuotesEnabled = true; preferences.systemTextReplacementEnabled = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertTrue(restored.smartQuotesEnabled); XCTAssertFalse(restored.smartDashesEnabled); XCTAssertTrue(restored.systemTextReplacementEnabled)
    }
}
