import Foundation
import XCTest
@testable import LacEditor

final class EmojiShortcodeResolverTests: XCTestCase {
    func testBundledCatalogResolvesAliasesAndLeavesUnknown() throws {
        let result = try EmojiShortcodeResolver.resolve(["smile", "heart", "+1", "thumbsup", "family_man_woman_girl_boy", "not_a_real_emoji", "smile"])
        XCTAssertEqual(result, ["smile": "😄", "heart": "❤️", "+1": "👍", "thumbsup": "👍", "family_man_woman_girl_boy": "👨‍👩‍👧‍👦"])
        XCTAssertEqual(try EmojiShortcodeResolver.completions(prefix: "").count, 1913)
        let suggestions = try EmojiShortcodeResolver.completions(prefix: "smil")
        XCTAssertTrue(suggestions.contains("smile"))
        XCTAssertEqual(suggestions, suggestions.sorted())
        XCTAssertTrue(suggestions.allSatisfy { $0.hasPrefix("smil") })
        XCTAssertTrue(try EmojiShortcodeResolver.completions(prefix: "not_a_real_emoji").isEmpty)
    }

    func testPopularCompletionsAreLimitedAndRanked() throws {
        let all = try EmojiShortcodeResolver.popularCompletions(prefix: "")
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(Array(all.prefix(4)), ["joy", "heart", "rofl", "+1"])
        let smiles = try EmojiShortcodeResolver.popularCompletions(prefix: "smi")
        XCTAssertTrue(smiles.contains("smile"))
        XCTAssertLessThanOrEqual(smiles.count, 20)
        XCTAssertTrue(smiles.allSatisfy { $0.hasPrefix("smi") })
        XCTAssertEqual(try EmojiShortcodeResolver.popularCompletions(prefix: "hear").first, "heart")
        XCTAssertTrue(try EmojiShortcodeResolver.popularCompletions(prefix: "not_a_real_emoji").isEmpty)
    }

    func testContainsShortcodeFindsOnlyKnownNames() {
        XCTAssertTrue(EmojiShortcodeResolver.containsShortcode(":smile:"))
        XCTAssertTrue(EmojiShortcodeResolver.containsShortcode("a :+1: b"))
        XCTAssertFalse(EmojiShortcodeResolver.containsShortcode("10:30:00"))
        XCTAssertFalse(EmojiShortcodeResolver.containsShortcode(":not_a_real_emoji:"))
        XCTAssertFalse(EmojiShortcodeResolver.containsShortcode("smile:"))
    }

    func testEmptyInvalidAndCancelledInput() throws {
        XCTAssertTrue(try EmojiShortcodeResolver.resolve([]).isEmpty)
        for name in ["", "a b", "a:b", "中文", "a\nb", "a]b"] {
            XCTAssertThrowsError(try EmojiShortcodeResolver.resolve([name])) {
                guard case EmojiShortcodeResolver.ResolveError.invalidName = $0 else { return XCTFail("Expected invalid name: \($0)") }
            }
        }
        XCTAssertThrowsError(try EmojiShortcodeResolver.resolve(["smile"], isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testExportSnapshotLeavesRawHTMLTextUnchanged() throws {
        let source = "before <script>\n\ninside :smile:\n\n</script>\n\nafter :smile:"
        let output = try EmojiShortcodeResolver.prepareMarkdown(source)
        XCTAssertEqual(output, "before <script>\n\ninside :smile:\n\n</script>\n\nafter 😄")
    }

    func testRejectsMalformedAndAmbiguousCatalog() throws {
        for json in ["[]", "not json", #"[{"emoji":"😄","aliases":["smile"]},{"emoji":"❤️","aliases":["smile"]}]"#, #"[{"emoji":"","aliases":["smile"]}]"#, #"[{"emoji":"😄","aliases":["bad name"]}]"#] {
            XCTAssertThrowsError(try EmojiShortcodeResolver.readCatalog(Data(json.utf8)))
        }
    }
}
