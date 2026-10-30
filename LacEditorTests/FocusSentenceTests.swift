import XCTest
@testable import LacEditor

final class FocusSentenceTests: XCTestCase {
    private func sentence(_ text: String, _ location: Int, _ length: Int = 0) -> String? {
        let string = text as NSString
        guard let range = FocusSentenceService.activeRange(in: string, selection: NSRange(location: location, length: length)) else { return nil }
        return string.substring(with: range).trimmingCharacters(in: .whitespaces)
    }

    func testEnglishSentences() {
        let text = "Hello world. Second one! Third?"
        for location in [0, 5, 12] { XCTAssertEqual(sentence(text, location), "Hello world.") }
        XCTAssertEqual(sentence(text, 13), "Second one!")
        XCTAssertEqual(sentence(text, (text as NSString).length), "Third?")
    }

    func testTrailingSpaceAtParagraphEnd() {
        let text = "One. Two. "
        XCTAssertEqual(sentence(text, (text as NSString).length), "Two.")
    }

    func testChineseSentences() {
        let text = "你好。再见！好吗？"
        XCTAssertEqual(sentence(text, 1), "你好。")
        XCTAssertEqual(sentence(text, 3), "再见！")
        XCTAssertEqual(sentence(text, (text as NSString).length), "好吗？")
    }

    func testRussianSentences() {
        let text = "Это раз. Это два! А три?"
        XCTAssertEqual(sentence(text, 2), "Это раз.")
        XCTAssertEqual(sentence(text, 11), "Это два!")
        XCTAssertEqual(sentence(text, 22), "А три?")
        XCTAssertNotNil(sentence("«Да» — сказал он. Нет.", 3))
    }

    func testAbbreviationsFollowFoundationBoundaries() throws {
        let text = "Dr. Smith went home. Then he slept." as NSString
        let location = text.range(of: "went").location + 1
        let range = FocusSentenceService.activeRange(in: text, selection: NSRange(location: location, length: 0))
        let found = try XCTUnwrap(range)
        XCTAssertGreaterThan(found.length, 0)
        XCTAssertTrue(NSLocationInRange(location, found))
        XCTAssertLessThanOrEqual(NSMaxRange(found), text.length)
        var boundaries: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.bySentences, .substringNotRequired]) { _, r, _, _ in boundaries.append(r) }
        XCTAssertTrue(boundaries.contains { $0.location == found.location })
        XCTAssertTrue(boundaries.contains { NSMaxRange($0) == NSMaxRange(found) })
    }

    func testSurrogatesAndCombiningMarks() {
        let text = "Hi 😀. Next 👍! Last"
        XCTAssertEqual(sentence(text, 4), "Hi 😀.")
        XCTAssertEqual(sentence("e\u{301}. B.", 1), "e\u{301}.")
        XCTAssertEqual(sentence("🇷🇺 раз. Два.", 2), "🇷🇺 раз.")
        let length = (text as NSString).length
        let range = FocusSentenceService.activeRange(in: text as NSString, selection: NSRange(location: 4, length: 0))
        XCTAssertLessThanOrEqual(NSMaxRange(range ?? NSRange()), length)
    }

    func testEmptyParagraphDocumentEndAndNoTrailingNewline() {
        let blank = "a.\n\nb." as NSString
        XCTAssertEqual(FocusSentenceService.activeRange(in: blank, selection: NSRange(location: 3, length: 0)), NSRange(location: 3, length: 1))
        XCTAssertEqual(FocusSentenceService.activeRange(in: "" as NSString, selection: NSRange(location: 0, length: 0)), NSRange(location: 0, length: 0))
        XCTAssertEqual(FocusSentenceService.activeRange(in: "a.\n" as NSString, selection: NSRange(location: 3, length: 0)), NSRange(location: 3, length: 0))
        XCTAssertEqual(FocusSentenceService.activeRange(in: "Конец" as NSString, selection: NSRange(location: 5, length: 0)), NSRange(location: 0, length: 5))
    }

    func testSelectionCoversAllTouchedSentences() {
        let text = "A one. A two. A three."
        let start = 2
        let end = (text as NSString).range(of: "three").location + 2
        XCTAssertEqual(sentence(text, start, end - start), text)
        XCTAssertEqual(sentence(text, 0, 7), "A one.")
    }

    func testSelectionAcrossParagraphs() {
        let text = "A1. A2.\nB1. B2.\nC1." as NSString
        let a2 = text.range(of: "A2").location
        let b1End = NSMaxRange(text.range(of: "B1."))
        let range = FocusSentenceService.activeRange(in: text, selection: NSRange(location: a2, length: b1End - a2 - 1))
        XCTAssertEqual(range.map { text.substring(with: $0).trimmingCharacters(in: .whitespaces) }, "A2.\nB1.")
        let across = FocusSentenceService.activeRange(in: text, selection: NSRange(location: a2, length: text.length - a2 - 1))
        XCTAssertEqual(across.map { text.substring(with: $0) }, "A2.\nB1. B2.\nC1.")
    }

    func testParagraphTerminatorsAreExcluded() {
        for text in ["A. B.\r\nC.", "A. B.\u{2029}C.", "A. B.\rC."] {
            let string = text as NSString
            for location in 0...string.length {
                guard let range = FocusSentenceService.activeRange(in: string, selection: NSRange(location: location, length: 0)), range.length > 0 else { continue }
                let piece = string.substring(with: range)
                XCTAssertFalse(piece.contains("\r") || piece.contains("\n") || piece.contains("\u{2029}"), "\(text) @ \(location)")
            }
        }
    }

    func testInvalidSelectionReturnsNil() {
        let text = "abc" as NSString
        XCTAssertNil(FocusSentenceService.activeRange(in: text, selection: NSRange(location: NSNotFound, length: 0)))
        XCTAssertNil(FocusSentenceService.activeRange(in: text, selection: NSRange(location: 4, length: 0)))
        XCTAssertNil(FocusSentenceService.activeRange(in: text, selection: NSRange(location: 1, length: 5)))
    }

    func testInvariantForAllPositions() {
        for text in ["Раз. Два! Три?", "你好。再见！\n\nA. B.\r\nC", "Hi 😀. Next 👍! Last", "a.\n"] {
            let string = text as NSString
            for location in 0...string.length {
                guard let range = FocusSentenceService.activeRange(in: string, selection: NSRange(location: location, length: 0)) else {
                    XCTFail("nil for \(text) @ \(location)")
                    continue
                }
                XCTAssertLessThanOrEqual(NSMaxRange(range), string.length)
                if range.length > 0 { XCTAssertTrue(location >= range.location && location <= NSMaxRange(range) + 1, "\(text) @ \(location)") }
            }
        }
    }
}
