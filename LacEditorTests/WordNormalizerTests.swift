import XCTest
@testable import LacEditor

final class WordNormalizerTests: XCTestCase {
    private func check(_ pairs: [(String, String)], language: TextLanguage, file: StaticString = #filePath, line: UInt = #line) {
        for (word, stem) in pairs {
            XCTAssertEqual(WordNormalizer.normalize(word, language: language), stem, word, file: file, line: line)
        }
    }

    func testEnglishSnowballPairs() {
        check([("caresses", "caress"), ("ponies", "poni"), ("ties", "tie"), ("cats", "cat"), ("feed", "feed"),
               ("agreed", "agre"), ("plastered", "plaster"), ("motoring", "motor"), ("sing", "sing"),
               ("conflated", "conflat"), ("troubled", "troubl"), ("sized", "size"), ("hopping", "hop"),
               ("falling", "fall"), ("hissing", "hiss"), ("failing", "fail"), ("filing", "file"),
               ("happy", "happi"), ("happiness", "happi"), ("running", "run"), ("relational", "relat"),
               ("conditional", "condit"), ("generously", "generous"), ("generate", "generat"), ("general", "general"),
               ("universal", "univers"), ("skies", "sky"), ("sky", "sky"), ("news", "news"), ("dying", "die"), ("is", "is")],
              language: .en)
    }

    func testEnglishSnowballSampleVocabulary() {
        check([("consign", "consign"), ("consigned", "consign"), ("consigning", "consign"), ("consignment", "consign"),
               ("consist", "consist"), ("consistency", "consist"), ("consolation", "consol"), ("consolations", "consol"),
               ("console", "consol"), ("consoling", "consol"), ("consolidate", "consolid"), ("consonant", "conson"),
               ("conspicuous", "conspicu"), ("conspiracy", "conspiraci"), ("conspirator", "conspir"), ("conspire", "conspir"),
               ("constable", "constabl"), ("constance", "constanc"), ("constant", "constant")],
              language: .en)
    }

    func testEnglishFormsCollapse() {
        let run = Set(["run", "runs", "running"].map { WordNormalizer.normalize($0, language: .en) })
        XCTAssertEqual(run.count, 1)
        for word in ["connect", "connected", "connecting", "connection"] {
            XCTAssertEqual(WordNormalizer.normalize(word, language: .en), "connect", word)
        }
        XCTAssertEqual(WordNormalizer.normalize("RUNNING", language: .en), WordNormalizer.normalize("running", language: .en))
        for word in ["dog's", "dogs'", "dog\u{2019}s"] {
            XCTAssertEqual(WordNormalizer.normalize(word, language: .en), "dog", word)
        }
    }

    func testEnglishNonLetterTokensAreNotStemmed() {
        XCTAssertEqual(WordNormalizer.normalize("3D", language: .en), "3d")
        XCTAssertEqual(WordNormalizer.normalize("Co-op", language: .en), "co-op")
        XCTAssertEqual(WordNormalizer.normalize("Café", language: .en), "café")
    }

    func testRussianSnowballPairs() {
        check([("книги", "книг"), ("книга", "книг"), ("книгами", "книг"), ("красивый", "красив"), ("красивая", "красив"),
               ("красивого", "красив"), ("красивые", "красив"), ("дома", "дом"), ("дом", "дом"), ("домов", "дом"),
               ("домом", "дом"), ("доме", "дом"), ("вода", "вод"), ("воды", "вод"), ("водой", "вод"),
               ("работа", "работ"), ("работы", "работ"), ("работой", "работ"), ("работать", "работа"),
               ("читаю", "чита"), ("читает", "чита"), ("читают", "чита"), ("читал", "чита"), ("читать", "чита"),
               ("учиться", "уч"), ("учился", "уч"), ("учится", "уч"), ("возможность", "возможн"),
               ("возможности", "возможн"), ("лучший", "лучш"), ("новый", "нов"), ("прочитав", "прочита")],
              language: .ru)
    }

    func testRussianYoIsFolded() {
        XCTAssertEqual(WordNormalizer.normalize("ёлка", language: .ru), WordNormalizer.normalize("елка", language: .ru))
        XCTAssertEqual(WordNormalizer.normalize("ёлка", language: .ru), "елк")
        XCTAssertEqual(WordNormalizer.normalize("КНИГИ", language: .ru), "книг")
    }

    func testRussianNonCyrillicIsNotStemmed() {
        XCTAssertEqual(WordNormalizer.normalize("hello", language: .ru), "hello")
        XCTAssertEqual(WordNormalizer.normalize("из-за", language: .ru), "из-за")
    }

    func testChineseUnchanged() {
        XCTAssertEqual(WordNormalizer.normalize("我们", language: .zh), "我们")
        XCTAssertEqual(WordNormalizer.normalize("AbC", language: .zh), "abc")
    }

    func testOtherLowercasesAndFoldsDiacritics() {
        XCTAssertEqual(WordNormalizer.normalize("Café", language: .other), "cafe")
        XCTAssertFalse(WordNormalizer.normalize("Straße", language: .other).isEmpty)
    }

    func testShortAndEmptyInput() {
        for language in TextLanguage.allCases {
            XCTAssertEqual(WordNormalizer.normalize("", language: language), "")
            for word in ["a", "я", "我", "'"] { _ = WordNormalizer.normalize(word, language: language) }
        }
    }
}
