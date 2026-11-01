import Foundation
import XCTest
@testable import LacEditor

final class AICompletionContextTests: XCTestCase {
    private func window(_ text: String, caret: Int, tokens: [NSRange] = []) -> (text: NSString, before: NSRange, after: NSRange) {
        let nsText = NSMutableString(string: text)
        let result = AICompletionContext.window(in: nsText, caret: caret, tokens: tokens)
        return (nsText, result.before, result.after)
    }

    private func clean(_ response: String, before: String, after: String = "", isProse: Bool = true) -> String? {
        AICompletionContext.clean(response, before: before, after: after, isProse: isProse)
    }

    func testWindowMovesToSentenceBoundariesWithinCeiling() {
        let result = window(String(repeating: "Это предложение номер один. ", count: 60), caret: 1000)
        XCTAssertEqual(result.text.character(at: result.before.location - 1), 0x2E)
        XCTAssertTrue((800...1000).contains(result.before.length))
        XCTAssertEqual(result.text.character(at: NSMaxRange(result.after) - 1), 0x2E)
        XCTAssertTrue((150...250).contains(result.after.length))
        let chinese = window(String(repeating: "这是一个句子。", count: 300), caret: 1400)
        XCTAssertEqual(chinese.text.character(at: chinese.before.location - 1), 0x3002)
        XCTAssertEqual(chinese.text.character(at: NSMaxRange(chinese.after) - 1), 0x3002)
    }

    func testDotInsideWordIsNotSentenceBoundary() {
        let result = window(String(repeating: "x.y", count: 400), caret: 1000)
        XCTAssertEqual(result.before.location, 0, "точка без пробела за ней не граница")
    }

    func testWindowReachesDocumentEdgeWithoutBoundaryWithinCeiling() {
        let result = window(String(repeating: "abcd ", count: 220), caret: 900)
        XCTAssertEqual(result.before.location, 0)
        XCTAssertEqual(NSMaxRange(result.after), 1100)
    }

    func testWindowWithoutBoundaryKeepsSizeAndDoesNotCutWords() {
        let russian = window(String(repeating: "слово ", count: 400), caret: 1200)
        XCTAssertTrue((800...1000).contains(russian.before.length))
        XCTAssertEqual(russian.text.character(at: russian.before.location - 1), 0x20)
        XCTAssertEqual(russian.text.character(at: NSMaxRange(russian.after) - 1), 0x20)
        let chinese = window(String(repeating: "这是一个很长的句子，没有句号", count: 200), caret: 1500)
        XCTAssertEqual(chinese.before.length, 800)
        XCTAssertEqual(chinese.after.length, 150)
    }

    func testWindowDoesNotSplitComposedCharactersOrTokens() {
        let emoji = window(String(repeating: "😀", count: 700), caret: 1000)
        XCTAssertEqual(emoji.before.location % 2, 0)
        XCTAssertEqual(NSMaxRange(emoji.after) % 2, 0)
        let family = window(String(repeating: "👨‍👩‍👧", count: 300), caret: 1600)
        XCTAssertEqual(family.before.location % 8, 0)
        XCTAssertEqual(NSMaxRange(family.after) % 8, 0)
        let text = String(repeating: "ab ", count: 500)
        XCTAssertEqual(window(text, caret: 1200, tokens: [NSRange(location: 390, length: 40)]).before.location, 430)
        XCTAssertEqual(NSMaxRange(window(text, caret: 1000, tokens: [NSRange(location: 1130, length: 30)]).after), 1130)
    }

    func testWindowAtDocumentEdges() {
        let start = window("Привет, мир", caret: 0)
        XCTAssertEqual(start.before, NSRange(location: 0, length: 0))
        XCTAssertEqual(start.after, NSRange(location: 0, length: 11))
        let end = window("Привет, мир", caret: 11)
        XCTAssertEqual(end.before, NSRange(location: 0, length: 11))
        XCTAssertEqual(end.after.length, 0)
        XCTAssertEqual(window("", caret: 0).after.length, 0)
    }

    func testStartRules() {
        XCTAssertTrue(AICompletionContext.shouldStart(before: "abc", restOfLine: "  ", isMediaOnlyLine: false))
        XCTAssertTrue(AICompletionContext.shouldStart(before: "a\n\nb c\n", restOfLine: "", isMediaOnlyLine: false))
        XCTAssertFalse(AICompletionContext.shouldStart(before: "ab \n ", restOfLine: "", isMediaOnlyLine: false))
        XCTAssertFalse(AICompletionContext.shouldStart(before: "abcdef", restOfLine: "x", isMediaOnlyLine: false))
        XCTAssertFalse(AICompletionContext.shouldStart(before: "abcdef", restOfLine: "", isMediaOnlyLine: true))
        let text = NSMutableString(string: "![](TOKEN)")
        XCTAssertTrue(AICompletionContext.isMediaOnlyLine(in: text, line: NSRange(location: 0, length: 10), tokens: [NSRange(location: 4, length: 5)]))
        let mixed = NSMutableString(string: "text TOKEN")
        XCTAssertFalse(AICompletionContext.isMediaOnlyLine(in: mixed, line: NSRange(location: 0, length: 10), tokens: [NSRange(location: 5, length: 5)]))
        let lines = NSMutableString(string: "abc\ndef ghi\njkl")
        XCTAssertEqual(lines.substring(with: AICompletionContext.line(in: lines, caret: 5)), "def ghi")
    }

    func testPause() {
        XCTAssertEqual(AICompletionContext.delayNanoseconds(lastBeforeCaret: " "), 350_000_000)
        XCTAssertEqual(AICompletionContext.delayNanoseconds(lastBeforeCaret: ","), 350_000_000)
        XCTAssertEqual(AICompletionContext.delayNanoseconds(lastBeforeCaret: nil), 350_000_000)
        XCTAssertEqual(AICompletionContext.delayNanoseconds(lastBeforeCaret: "a"), 700_000_000)
    }

    func testRequestIsMarkedUpAndHasNoSections() {
        let context = AICompletionContext(before: "Hi", after: "Bye", fileType: "Markdown", heading: "Intro", isProse: true)
        XCTAssertEqual(context.requestText, "<file_type>Markdown</file_type>\n<section_heading>Intro</section_heading>\n<text_before_cursor>\nHi\n</text_before_cursor>\n<text_after_cursor>\nBye\n</text_after_cursor>")
        var withoutHeading = context
        withoutHeading.heading = nil
        XCTAssertFalse(withoutHeading.requestText.contains("section_heading"))
    }

    func testCleaningTakesFirstNonEmptyLine() {
        XCTAssertEqual(clean(" continuation\nhidden", before: "text"), " continuation")
        XCTAssertEqual(clean("\n\n second", before: "x y z"), " second")
        XCTAssertNil(clean("   \n  ", before: "abc"))
        XCTAssertEqual(clean("```\nfoo bar\n```", before: "abc"), "foo bar")
    }

    func testCleaningRemovesRepeatedEdges() {
        XCTAssertEqual(clean("brown fox", before: "the quick brown"), " fox")
        XCTAssertEqual(clean("quick brown fox", before: "the quick brown"), " fox")
        XCTAssertEqual(clean("ownership", before: "the own"), "ownership")
        XCTAssertEqual(clean("end of it. The next", before: "start ", after: "The next line"), "end of it.")
        XCTAssertNil(clean("The next", before: "start ", after: "The next line"))
        XCTAssertEqual(clean("a", before: "xx a"), "a")
    }

    func testCleaningFixesJunctionSpaces() {
        XCTAssertEqual(clean("lo world", before: "say hel"), "lo world")
        XCTAssertEqual(clean(" world", before: "say hello "), "world")
        XCTAssertEqual(clean("world", before: "say hello,"), " world")
        XCTAssertEqual(clean("  text", before: "Hello.\n"), "text")
        XCTAssertEqual(clean("world", before: "foo.", isProse: false), "world")
        XCTAssertEqual(clean("  indented()", before: "func x() {\n", isProse: false), "  indented()")
        XCTAssertEqual(clean("也是这样", before: "我们今天"), "也是这样")
    }

    func testRemainderOfSuggestion() {
        XCTAssertEqual(AICompletionContext.remainder(of: " world and", afterTyping: " wo"), "rld and")
        XCTAssertNil(AICompletionContext.remainder(of: " world", afterTyping: " world"))
        XCTAssertNil(AICompletionContext.remainder(of: " world", afterTyping: " x"))
        XCTAssertNil(AICompletionContext.remainder(of: "a", afterTyping: ""))
        XCTAssertEqual(AICompletionContext.remainder(of: "世界很大", afterTyping: "世"), "界很大")
    }

    func testCacheKeepsLastEightAnswers() {
        var cache = AICompletionCache()
        func key(_ request: String, model: String = "m", server: String = "s") -> String {
            AICompletionCache.key(request: request, model: model, server: server)
        }
        for index in 0..<9 { cache.store("v\(index)", for: key("r\(index)")) }
        XCTAssertNil(cache.value(for: key("r0")))
        XCTAssertEqual(cache.value(for: key("r1")), "v1")
        XCTAssertNil(cache.value(for: key("r1", model: "other")))
        XCTAssertNil(cache.value(for: key("r1", server: "other")))
        cache.store("new", for: key("new"))
        XCTAssertEqual(cache.value(for: key("r1")), "v1")
        XCTAssertNil(cache.value(for: key("r2")))
    }

    func testEncodedDataIsRemovedFromWindow() {
        let blob = String(repeating: "QUJDREVG", count: 20)
        XCTAssertEqual(AICompletionContext.withoutEncodedData("img = \"data:image/png;base64,\(blob)\"; конец"), "img = \"\"; конец")
        XCTAssertEqual(AICompletionContext.withoutEncodedData("\(blob)\"; let a = 1"), "\"; let a = 1", "окно началось посреди данных")
        XCTAssertEqual(AICompletionContext.withoutEncodedData("a\n\(blob)\n\(blob)\nQUJDREVGQUJDREVGQUJD\nслово"), "a\n\nслово")
        let ordinary = "обычный текст, https://ex.com/a/b?c=1, metadata:a/b,c и snake_case_name."
        XCTAssertEqual(AICompletionContext.withoutEncodedData(ordinary), ordinary)
        XCTAssertEqual(AICompletionContext.withoutEncodedData("QUJDREVG\"; let a = 1", startsInData: true), "\"; let a = 1", "короткий обрывок в начале окна")
        XCTAssertEqual(AICompletionContext.withoutEncodedData("let a = \"QUJDREVG", endsInData: true), "let a = \"", "короткий обрывок в конце окна")
        XCTAssertEqual(AICompletionContext.withoutEncodedData("QUJD слово"), "QUJD слово", "без разреза короткое слово остаётся")
        XCTAssertTrue(AICompletionContext.isEncodedDataUnit(0x2B))
        XCTAssertFalse(AICompletionContext.isEncodedDataUnit(0x20))
        XCTAssertFalse(AICompletionContext.isEncodedDataUnit(0x042F))
    }
}
