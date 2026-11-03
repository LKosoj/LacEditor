import XCTest
@testable import LacEditor

final class StyleCheckTests: XCTestCase {
    private func run(_ text: String, markdown: Bool = false, _ settings: StyleCheckSettings = .default) -> StyleCheckResult {
        StyleCheckService.check(text: text, isMarkdown: markdown, settings: settings, documentID: UUID(), revision: 1)
    }

    private func found(_ result: StyleCheckResult, _ category: StyleCategory) -> [StyleFinding] {
        result.findings.filter { $0.category == category }
    }

    private func settings(_ change: (inout StyleCheckSettings) -> Void) -> StyleCheckSettings {
        var value = StyleCheckSettings.default
        change(&value)
        return value
    }

    func testRepeatedEnglishWordWithinWindow() {
        let result = run("The garden was quiet and the garden was cold.")
        let items = found(result, .repeatedWord)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.fragment, "garden")
    }

    func testRepeatedWordOutsideWindowIsIgnored() {
        let result = run("Garden is here. One two three four five six seven eight nine ten. Garden again.",
                         settings { $0.windowWords = 5 })
        XCTAssertTrue(found(result, .repeatedWord).isEmpty)
    }

    func testRepeatedRussianWordsMatchByStem() {
        let result = run("Мы увидели большой дом и ещё один большой дом рядом.")
        XCTAssertFalse(found(result, .repeatedWord).isEmpty)
    }

    func testStopWordsAreNotRepeats() {
        let result = run("It was the one and the other.")
        XCTAssertTrue(found(result, .repeatedWord).isEmpty)
    }

    func testCustomStopWordIsIgnored() {
        let text = "The garden was quiet and the garden was cold."
        let result = run(text, settings { $0.customStopWords = ["garden"] })
        XCTAssertTrue(found(result, .repeatedWord).isEmpty)
    }

    func testRepeatedSentenceStart() {
        let result = run("He opened the door slowly. He looked inside the room.")
        XCTAssertEqual(found(result, .repeatedStart).count, 1)
    }

    func testLongSentenceByWordLimit() {
        let sentence = Array(repeating: "word", count: 12).joined(separator: " ") + "."
        XCTAssertEqual(found(run(sentence, settings { $0.longSentenceWords = 10 }), .longSentence).count, 1)
        XCTAssertTrue(found(run(sentence, settings { $0.longSentenceWords = 20 }), .longSentence).isEmpty)
    }

    func testCustomWordFoundCaseInsensitiveOnWordBoundary() {
        let result = run("Basically it works. Basic things stay.", settings { $0.customWords = ["basically"] })
        let items = found(result, .customWord)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.range, NSRange(location: 0, length: 9))
    }

    func testCustomRussianWordDoesNotMatchAnotherLetter() {
        let result = run("Край поля. Крайний случай.", settings { $0.customWords = ["край"] })
        XCTAssertEqual(found(result, .customWord).count, 1)
    }

    func testDoubleSpaceHasReplacement() {
        let text = "One  two."
        let items = found(run(text), .spacing)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.range, NSRange(location: 3, length: 2))
        XCTAssertEqual(items.first?.replacement, " ")
    }

    func testSpaceBeforeCommaHasEmptyReplacement() {
        let items = found(run("One , two."), .spacing)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.replacement, "")
    }

    func testMarkdownCodeAndLinksAreNotChecked() {
        let text = "```\nthe  the  the  the\n```\n\nSee [the link](http://example.com/a  b) now.\n\n`a  b`\n"
        XCTAssertTrue(found(run(text, markdown: true), .spacing).isEmpty)
    }

    func testMarkdownFrontMatterIsSkipped() {
        let text = "---\ntitle: word  word word word\n---\n\nPlain text here.\n"
        XCTAssertTrue(run(text, markdown: true).findings.isEmpty)
    }

    func testMarkdownTableAndListMarkersAreSkipped() {
        let text = "| a  | b |\n|---|---|\n| c  | d |\n\n-   item one\n"
        XCTAssertTrue(found(run(text, markdown: true), .spacing).isEmpty)
    }

    func testPlainTextKeepsEverythingChecked() {
        XCTAssertEqual(found(run("`a  b`", markdown: false), .spacing).count, 1)
    }

    func testFindingsAreSortedAndInsideText() {
        let text = "Basically the garden was quiet and the garden was cold ,  really."
        let result = run(text, settings { $0.customWords = ["basically"] })
        let length = (text as NSString).length
        XCTAssertEqual(result.findings.map(\.range.location), result.findings.map(\.range.location).sorted())
        for finding in result.findings { XCTAssertLessThanOrEqual(NSMaxRange(finding.range), length) }
    }

    func testCancelledCheckReturnsQuickly() {
        let result = StyleCheckService.check(text: String(repeating: "word  word. ", count: 2000), isMarkdown: false,
                                             settings: .default, documentID: UUID(), revision: 1, isCancelled: { true })
        XCTAssertLessThan(result.findings.count, 2000)
    }

    func testShiftedFindingAfterReplacement() {
        let finding = StyleFinding(category: .customWord, range: NSRange(location: 10, length: 3), fragment: "abc", explanation: "")
        XCTAssertEqual(finding.shifted(after: NSRange(location: 0, length: 5), delta: -2)?.range.location, 8)
        XCTAssertEqual(finding.shifted(after: NSRange(location: 20, length: 2), delta: 5)?.range.location, 10)
        XCTAssertNil(finding.shifted(after: NSRange(location: 9, length: 2), delta: 1))
    }

    func testSettingsAreClampedAndDecodeOldData() throws {
        var value = StyleCheckSettings.default
        value.windowWords = 1000
        value.longSentenceChars = 1
        value.goal = String(repeating: "a", count: 600)
        let clamped = value.clamped()
        XCTAssertEqual(clamped.windowWords, 100)
        XCTAssertEqual(clamped.longSentenceChars, 20)
        XCTAssertEqual(clamped.goal.count, 500)
        let decoded = try JSONDecoder().decode(StyleCheckSettings.self, from: Data("{\"windowWords\":2}".utf8))
        XCTAssertEqual(decoded.windowWords, 5)
        XCTAssertTrue(decoded.autoCheck)
    }

    func testParseListTrimsAndDeduplicates() {
        XCTAssertEqual(StyleCheckSettings.parseList(" Foo \nfoo\n\nbar"), ["Foo", "bar"])
    }

    func testDisabledCategoryFlag() {
        var value = StyleCheckSettings.default
        value.setEnabled(.spacing, false)
        XCTAssertFalse(value.isEnabled(.spacing))
        value.setEnabled(.spacing, true)
        XCTAssertTrue(value.isEnabled(.spacing))
    }

    func testLineNumbersCountBreaks() {
        let a = StyleFinding(category: .spacing, range: NSRange(location: 0, length: 1), fragment: "", explanation: "")
        let b = StyleFinding(category: .spacing, range: NSRange(location: 4, length: 1), fragment: "", explanation: "")
        let numbers = StyleCheckController.lineNumbers(for: [a, b], in: "a\nb\nc")
        XCTAssertEqual(numbers[a.id], 1)
        XCTAssertEqual(numbers[b.id], 3)
    }
}
