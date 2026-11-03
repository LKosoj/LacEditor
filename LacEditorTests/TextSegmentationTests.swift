import XCTest
@testable import LacEditor

final class TextSegmentationTests: XCTestCase {
    private func assertInvariants(_ segments: [TextSegment], in text: String, file: StaticString = #filePath, line: UInt = #line) {
        let ns = text as NSString
        var previousEnd = 0
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.range.location, previousEnd, file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(segment.range), ns.length, file: file, line: line)
            XCTAssertEqual(ns.substring(with: segment.range), segment.text, file: file, line: line)
            previousEnd = NSMaxRange(segment.range)
        }
    }

    func testChineseSentencesWithoutSpaces() {
        let text = "今天天气很好。我们去公园散步吧！明天再说。"
        let segments = TextSegmentation.sentences(in: text)
        assertInvariants(segments, in: text)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].text, "我们去公园散步吧！")
    }

    func testChineseWordsHaveNoSpacesAndAreMultiCharacter() {
        let text = "我们去公园散步"
        let words = TextSegmentation.words(in: text)
        assertInvariants(words, in: text)
        XCTAssertGreaterThan(words.count, 1)
        XCTAssertEqual(words.map(\.text).joined(), text)
        XCTAssertTrue(words.contains { $0.text.count >= 2 })
    }

    func testEnglishSentencesAndWords() {
        let text = "Hello, world. This is a test! Is it? Yes."
        let sentences = TextSegmentation.sentences(in: text)
        assertInvariants(sentences, in: text)
        XCTAssertEqual(sentences.count, 4)
        for sentence in sentences { XCTAssertFalse(sentence.text.hasSuffix(" ")) }
        let words = TextSegmentation.words(in: text)
        assertInvariants(words, in: text)
        XCTAssertEqual(words.map(\.text), ["Hello", "world", "This", "is", "a", "test", "Is", "it", "Yes"])
    }

    func testRussianSentencesAndWords() {
        let text = "Привет, мир. Это проверка! Всё хорошо?"
        let sentences = TextSegmentation.sentences(in: text)
        assertInvariants(sentences, in: text)
        XCTAssertEqual(sentences.count, 3)
        let words = TextSegmentation.words(in: text)
        assertInvariants(words, in: text)
        XCTAssertTrue(words.map(\.text).contains("Всё"))
    }

    func testMixedText() {
        let text = "Hello мир 你好. Next."
        let sentences = TextSegmentation.sentences(in: text)
        assertInvariants(sentences, in: text)
        XCTAssertEqual(sentences.count, 2)
        assertInvariants(TextSegmentation.words(in: text), in: text)
    }

    func testEmojiAndSurrogatePairsKeepUTF16Ranges() throws {
        let text = "😀 Hello 👋 world. Привет 🎉!"
        let words = TextSegmentation.words(in: text)
        assertInvariants(words, in: text)
        let world = try XCTUnwrap(words.first { $0.text == "world" })
        XCTAssertEqual(world.range.location, ("😀 Hello 👋 " as NSString).length)
        assertInvariants(TextSegmentation.sentences(in: text), in: text)

        let decomposed = "cafe\u{0301} au lait"
        assertInvariants(TextSegmentation.words(in: decomposed), in: decomposed)
        assertInvariants(TextSegmentation.sentences(in: decomposed), in: decomposed)
    }

    func testRangeParameterRestrictsResults() throws {
        let text = "First one. Second one. Third one."
        let all = TextSegmentation.sentences(in: text)
        XCTAssertEqual(all.count, 3)
        let second = TextSegmentation.sentences(in: text, range: all[1].range)
        assertInvariants(second, in: text)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.range, all[1].range)

        let beyond = TextSegmentation.sentences(in: text, range: NSRange(location: 20, length: 1_000))
        assertInvariants(beyond, in: text)
        XCTAssertTrue(TextSegmentation.sentences(in: text, range: NSRange(location: 5, length: 0)).isEmpty)
        XCTAssertTrue(TextSegmentation.words(in: text, range: NSRange(location: 5, length: 0)).isEmpty)
    }

    func testEmptyAndWhitespaceOnly() {
        for text in ["", "   \n\n"] {
            XCTAssertTrue(TextSegmentation.sentences(in: text).isEmpty)
            XCTAssertTrue(TextSegmentation.words(in: text).isEmpty)
        }
    }

    func testLanguageDetection() {
        XCTAssertEqual(TextSegmentation.language(of: "Сегодня очень хорошая погода, и мы решили пойти гулять в большой городской парк."), .ru)
        XCTAssertEqual(TextSegmentation.language(of: "The weather is very nice today, so we decided to take a long walk in the park."), .en)
        XCTAssertEqual(TextSegmentation.language(of: "今天天气很好，我们一起去公园散步吧。"), .zh)
        XCTAssertEqual(TextSegmentation.language(of: "Aujourd'hui il fait très beau, alors nous avons décidé de nous promener dans le grand parc."), .other)
        XCTAssertEqual(TextSegmentation.language(of: "Heute ist das Wetter sehr schön, deshalb haben wir beschlossen, im Park spazieren zu gehen."), .other)
        XCTAssertEqual(TextSegmentation.language(of: ""), .other)
        XCTAssertEqual(TextSegmentation.language(of: "12345 !!!"), .other)
    }

    func testLanguageCodes() throws {
        XCTAssertEqual(TextSegmentation.languageCode(for: .zh), "zh-CN")
        XCTAssertEqual(TextSegmentation.languageCode(for: .en), "en")
        XCTAssertEqual(TextSegmentation.languageCode(for: .ru), "ru")
        XCTAssertNil(TextSegmentation.languageCode(for: .other))
        XCTAssertEqual(TextLanguage.allCases.count, 4)
        for language in TextLanguage.allCases {
            let data = try JSONEncoder().encode([language])
            XCTAssertEqual(try JSONDecoder().decode([TextLanguage].self, from: data), [language])
        }
    }
}
