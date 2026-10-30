import XCTest
@testable import LacEditor

final class MarkdownInlineTagTests: XCTestCase {
    private func names(_ text: String) throws -> [String] {
        let parsed = try MarkdownTagReader.read(text: text)
        let source = text as NSString
        for tag in parsed.inline { XCTAssertEqual(source.substring(with: tag.range), "#" + tag.name) }
        return parsed.inline.map(\.name)
    }

    func testAcceptedForms() throws {
        XCTAssertEqual(try names("#tag"), ["tag"])
        XCTAssertEqual(try names("# Title #tag"), ["tag"])
        XCTAssertEqual(try names("см. #проект/план"), ["проект/план"])
        XCTAssertEqual(try names("#中文 今天#日记"), ["中文", "日记"])
        XCTAssertEqual(try names("#2024-q1"), ["2024-q1"])
        XCTAssertEqual(try names("(#a) \"#b\" *#c* **#d**"), ["a", "b", "c", "d"])
        XCTAssertEqual(try names("#tag, #tag. #tag) #tag/"), ["tag", "tag", "tag", "tag"])
        XCTAssertEqual(try names("😀#tag"), ["tag"])
        XCTAssertEqual(try names("a\r\n#one\r#two\n#three"), ["one", "two", "three"])
        XCTAssertEqual(try names("- item #x\n> quote #y"), ["x", "y"])
    }

    func testRejectedForms() throws {
        for text in ["# Title", "## Title", "#1", "#2024", "#1/2", "C#", "C# lang", "C#sharp", "a#b", "x_#b", "a-#b", "a/#b",
                     "##tag", "[x](#y)", "[#tag](u)", "https://a/#b", "<https://a/#b>", "`#tag`", "```\n#tag\n```",
                     "\\#tag", "&#35;tag", "<span id=\"#x\">", "<a href=\"#x\">x</a>", "$#a$", "#a//b", "#-x", "#/x", "[[page#head]]", "[[page|#alias]]"] {
            XCTAssertEqual(try names(text), [], text)
        }
    }

    func testFrontMatterIsMaskedAndYAMLReportedTogether() throws {
        let parsed = try MarkdownTagReader.read(text: "---\n# comment\ntags: [a]\n---\nbody #b")
        XCTAssertEqual(parsed.yaml, .tags(["a"]))
        XCTAssertEqual(parsed.inline.map(\.name), ["b"])
        XCTAssertNotNil(parsed.frontMatterRange)
        let broken = try MarkdownTagReader.read(text: "---\ntags: [\n---\n#still")
        guard case .invalid? = broken.yaml else { return XCTFail("Expected invalid YAML") }
        XCTAssertEqual(broken.inline.map(\.name), ["still"])
    }

    func testRangesUseUTF16AndComposedCharacters() throws {
        let text = "中文😀 #tag é #é\u{301}x"
        let parsed = try MarkdownTagReader.read(text: text)
        let source = text as NSString
        XCTAssertEqual(parsed.inline.count, 2)
        XCTAssertEqual(source.substring(with: parsed.inline[0].range), "#tag")
        XCTAssertEqual(source.substring(with: parsed.inline[1].range), "#é\u{301}x")
    }

    func testEmptyAndTrailingHash() throws {
        XCTAssertEqual(try names(""), [])
        XCTAssertEqual(try names("text #"), [])
        XCTAssertEqual(try names("#tag"), ["tag"])
    }

    func testCancellationIsNotReportedAsNoTags() {
        XCTAssertThrowsError(try MarkdownTagReader.read(text: "#tag", isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testPrefilterIsSupersetOfRecognizedTags() throws {
        for text in ["#tag", "a #b", "中文#日记", "\n#x", "# T #t"] { XCTAssertTrue(try MarkdownTagReader.hasCandidate(text), text) }
        for text in ["", "no hash", "# heading", "#\n", "##", "a # b", "C#", "C#sharp", "x_#b"] { XCTAssertFalse(try MarkdownTagReader.hasCandidate(text), text) }
    }

    func testWholeSegmentMatching() {
        XCTAssertTrue(MarkdownTagReader.matches(tag: "a", query: "a"))
        XCTAssertTrue(MarkdownTagReader.matches(tag: "A", query: "a"))
        XCTAssertTrue(MarkdownTagReader.matches(tag: "a/b", query: "a"))
        XCTAssertTrue(MarkdownTagReader.matches(tag: "a", query: "#a"))
        XCTAssertTrue(MarkdownTagReader.matches(tag: "Проект", query: "проект"))
        XCTAssertFalse(MarkdownTagReader.matches(tag: "ab", query: "a"))
        XCTAssertFalse(MarkdownTagReader.matches(tag: "a/b", query: "b"))
        XCTAssertFalse(MarkdownTagReader.matches(tag: "a", query: ""))
        XCTAssertFalse(MarkdownTagReader.matches(tag: "a", query: "#"))
    }
}
