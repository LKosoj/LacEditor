import XCTest
@testable import LacEditor

final class SceneSynopsisDrafterTests: XCTestCase {
    func testEmptyTextGivesNil() {
        XCTAssertNil(SceneSynopsisDrafter.draft(from: ""))
        XCTAssertNil(SceneSynopsisDrafter.draft(from: "# Заголовок\n\n```\ncode\n```\n"))
    }

    func testShortTextTakesFirstSentences() throws {
        let draft = try XCTUnwrap(SceneSynopsisDrafter.draft(from: "Анна вошла в тёмный дом. Она искала старый ключ. Потом ушла.", language: .ru))
        XCTAssertEqual(draft.method, .firstSentences)
        XCTAssertTrue(draft.text.hasPrefix("Анна вошла"))
    }

    func testPlainProseRemovesMarkup() {
        let text = "---\ntitle: x\n---\n# Head\n\nSee [the link](http://a.b) and ![pic](data:image/png;base64,AAAA) now.\n\n```\nskip me\n```\n"
        let prose = SceneSynopsisDrafter.plainProse(from: text)
        XCTAssertEqual(prose, "See the link and  now.")
    }

    func testLongTextRespectsLimit() throws {
        let sentence = "The quiet river carried small boats toward the old harbor every morning."
        let text = (0..<30).map { _ in sentence }.joined(separator: " ")
        let draft = try XCTUnwrap(SceneSynopsisDrafter.draft(from: text, language: .en))
        XCTAssertLessThanOrEqual(draft.text.count, SceneSynopsisDrafter.maxCharacters)
    }

    func testCancelledGivesNil() {
        XCTAssertNil(SceneSynopsisDrafter.draft(from: "Some text here. And more text.", isCancelled: { true }))
    }

    func testRankWithoutEdgesIsZero() {
        let scores = SceneSynopsisDrafter.rank([["a"], ["b"], ["c"]])
        XCTAssertEqual(scores, [0, 0, 0])
    }

    private let russian = "Анна долго шла по тёмной улице к старому дому. Старый дом стоял на краю тихого города. "
        + "В доме жил художник, который рисовал тёмную улицу каждую ночь. Анна хотела узнать, почему художник рисует улицу. "
        + "Художник ответил, что улица помнит всех, кто по ней шёл. Анна поняла, что улица и дом связаны. "
        + "Утром Анна вышла из дома и больше не боялась тёмной улицы."

    func testRussianTextRankPicksTwoSentencesInTextOrder() throws {
        let draft = try XCTUnwrap(SceneSynopsisDrafter.draft(from: russian, language: .ru))
        XCTAssertEqual(draft.method, .textRank)
        XCTAssertLessThanOrEqual(draft.text.count, SceneSynopsisDrafter.maxCharacters)
        XCTAssertTrue(russian.contains(draft.text.components(separatedBy: ". ").first ?? "?"))
    }

    func testResultIsDeterministic() {
        let first = SceneSynopsisDrafter.draft(from: russian, language: .ru)
        for _ in 0..<5 { XCTAssertEqual(SceneSynopsisDrafter.draft(from: russian, language: .ru), first) }
    }

    func testChineseJoinsWithoutSpaceAndRespectsLimit() throws {
        let sentence = "清晨的河面上飘着薄雾，渔夫们划着小船驶向远处的港口。"
        let text = (0..<12).map { _ in sentence }.joined()
        let draft = try XCTUnwrap(SceneSynopsisDrafter.draft(from: text, language: .zh))
        XCTAssertFalse(draft.text.contains(" "))
        XCTAssertLessThanOrEqual(draft.text.count, SceneSynopsisDrafter.maxCharactersCJK)
    }

    func testLongSingleSentenceIsTruncatedWithEllipsis() throws {
        let sentence = (0..<200).map { "word\($0)" }.joined(separator: " ") + "."
        let draft = try XCTUnwrap(SceneSynopsisDrafter.draft(from: sentence, language: .en))
        XCTAssertTrue(draft.text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(draft.text.count, SceneSynopsisDrafter.maxCharacters)
    }

    func testSimilarityIsSymmetricAndZeroForDisjointOrEmpty() {
        let a: Set<String> = ["river", "boat", "harbor"]
        let b: Set<String> = ["river", "boat", "night"]
        XCTAssertEqual(SceneSynopsisDrafter.similarity(a, b), SceneSynopsisDrafter.similarity(b, a), accuracy: 1e-12)
        XCTAssertGreaterThan(SceneSynopsisDrafter.similarity(a, b), 0)
        XCTAssertEqual(SceneSynopsisDrafter.similarity(a, ["other"]), 0)
        XCTAssertEqual(SceneSynopsisDrafter.similarity([], a), 0)
    }

    func testStopWordsAreRecognized() {
        XCTAssertTrue(StopWords.contains("the", language: .en))
        XCTAssertTrue(StopWords.contains("и", language: .ru))
        XCTAssertFalse(StopWords.contains("river", language: .en))
    }
}
