import XCTest
@testable import LacEditor

final class MarkdownEmojiStatisticsTests: XCTestCase {
    func testResolvedEmojiChangesReadableWordsAndKeepsSourceSelection() throws {
        let source = "Hi :smile: and :wave: 中文"
        let raw = source as NSString
        let base = try XCTUnwrap(MarkdownPresentationParser.parse(source, includeReadableText: true).readableText)
        let mapped = try XCTUnwrap(base.replacingEmojiText([
            (raw.range(of: ":smile:"), "😄"), (raw.range(of: ":wave:"), "👋")
        ]))
        let readable = try XCTUnwrap(mapped.text())
        XCTAssertTrue(readable.contains("Hi 😄 and 👋 中文"))
        let statistics = try XCTUnwrap(DocumentStatistics.calculate(source, readableText: readable))
        XCTAssertEqual(statistics.words, 4)
        XCTAssertEqual(statistics.characters, source.count)
        XCTAssertEqual(mapped.text(in: raw.range(of: ":smile:"), source: raw), "😄")
        XCTAssertNil(mapped.text(in: raw.range(of: "mil"), source: raw))
        XCTAssertEqual(mapped.text(in: raw.range(of: "and"), source: raw), "and")
        XCTAssertEqual(try XCTUnwrap(base.replacingEmojiText([])).text(), base.text())
    }

    func testEntitySpellingAndAtomicBoundaries() throws {
        let source = "Hi &colon;smile&colon;!", raw = source as NSString
        let base = try XCTUnwrap(MarkdownPresentationParser.parse(source, includeReadableText: true).readableText)
        let token = raw.range(of: "&colon;smile&colon;")
        let mapped = try XCTUnwrap(base.replacingEmojiText([(token, "😄")]))
        XCTAssertEqual(mapped.text()?.trimmingCharacters(in: .whitespacesAndNewlines), "Hi 😄!")
        XCTAssertEqual(mapped.text(in: token, source: raw), "😄")
        XCTAssertNil(base.replacingEmojiText([(NSRange(location: token.location + 1, length: token.length - 1), "😄")]))
    }

    func testFragmentReadingOrderNeedNotMatchSourceOrder() throws {
        let source = "a :x: b :y:", raw = source as NSString
        let fragments = ["b :y:", "a :x:"].map {
            MarkdownReadableText.Fragment(sourceRange: raw.range(of: $0), text: $0, matchesSource: true)
        }
        let base = MarkdownReadableText(sourceLength: raw.length, fragments: fragments, unsupportedRanges: [])
        let mapped = try XCTUnwrap(base.replacingEmojiText([(raw.range(of: ":y:"), "👋"), (raw.range(of: ":x:"), "😄")]))
        XCTAssertEqual(mapped.text(), "b 👋a 😄")
    }

    func testCancellationAndOverlappingRangesDoNotPublishPartialProjection() throws {
        let source = String(repeating: ":x: ", count: 1000)
        let base = MarkdownReadableText(sourceLength: source.utf16.count,
            fragments: [.init(sourceRange: NSRange(location: 0, length: source.utf16.count), text: source, matchesSource: true)], unsupportedRanges: [])
        let replacements = (0..<1000).map { (range: NSRange(location: $0 * 4, length: 3), text: "😄") }
        var checks = 0
        XCTAssertNil(base.replacingEmojiText(replacements, isCancelled: { checks += 1; return checks > 30 }))
        XCTAssertGreaterThan(checks, 30)
        XCTAssertNil(base.replacingEmojiText([(NSRange(location: 0, length: 3), "😄"), (NSRange(location: 1, length: 3), "👋")]))
        let complete = try XCTUnwrap(base.replacingEmojiText(replacements))
        XCTAssertEqual(complete.text(), String(repeating: "😄 ", count: 1000))
    }
}
