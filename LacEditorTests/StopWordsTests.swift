import XCTest
@testable import LacEditor

final class StopWordsTests: XCTestCase {
    func testEnglishRussianChineseContainNormalizedStopWords() {
        for (word, language) in [("the", TextLanguage.en), ("was", .en), ("и", .ru), ("был", .ru), ("это", .ru), ("的", .zh), ("我们", .zh)] {
            XCTAssertTrue(StopWords.contains(WordNormalizer.normalize(word, language: language), language: language), word)
        }
    }

    func testContentWordsAreNotStopWords() {
        for (word, language) in [("house", TextLanguage.en), ("дом", .ru), ("公园", .zh)] {
            XCTAssertFalse(StopWords.contains(WordNormalizer.normalize(word, language: language), language: language), word)
        }
    }

    func testOtherNeverHasStopWords() {
        XCTAssertFalse(StopWords.contains("the", language: .other))
        XCTAssertFalse(StopWords.contains("и", language: .other))
    }

    func testListsSizeAndNoDuplicates() {
        for list in [StopWordLists.en, StopWordLists.ru, StopWordLists.zh] {
            XCTAssertTrue((100...320).contains(list.count))
            XCTAssertEqual(Set(list).count, list.count)
        }
    }

    func testEveryListedWordIsFound() {
        for (list, language) in [(StopWordLists.en, TextLanguage.en), (StopWordLists.ru, .ru), (StopWordLists.zh, .zh)] {
            for word in list {
                XCTAssertTrue(StopWords.contains(WordNormalizer.normalize(word, language: language), language: language), word)
            }
        }
    }

    func testLanguagesDoNotLeak() {
        XCTAssertFalse(StopWords.contains(WordNormalizer.normalize("the", language: .ru), language: .ru))
        XCTAssertFalse(StopWords.contains(WordNormalizer.normalize("и", language: .en), language: .en))
    }
}
