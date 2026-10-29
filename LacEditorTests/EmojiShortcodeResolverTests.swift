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
