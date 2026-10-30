import Foundation
import XCTest
@testable import LacEditor

final class CriticMarkupServiceTests: XCTestCase {
    private func scan(_ text: String, excluded: [NSRange] = []) -> [CriticMarkupItem] {
        CriticMarkupService.items(in: text as NSString, excluded: excluded)
    }

    private func parsedItems(_ text: String) -> [CriticMarkupItem] {
        let excluded = MarkdownPresentationParser.parse(text).elements
            .excludedRanges(intersecting: NSRange(location: 0, length: (text as NSString).length))
        return scan(text, excluded: excluded)
    }

    func testFiveKindsWithUTF16Ranges() throws {
        let item = try XCTUnwrap(scan("{++你好😀++}").first)
        XCTAssertEqual(item.kind, .insertion)
        XCTAssertEqual(item.range, NSRange(location: 0, length: 10))
        XCTAssertEqual(item.content, NSRange(location: 3, length: 4))
        XCTAssertEqual(scan("{--a--}").first?.kind, .deletion)
        XCTAssertEqual(scan("{~~a~>b~~}").first?.kind, .substitution)
        XCTAssertEqual(scan("{>>a<<}").first?.kind, .comment)
        XCTAssertEqual(scan("{==a==}").first?.kind, .highlight)
    }

    func testSubstitutionSplitsOnFirstArrow() throws {
        let item = try XCTUnwrap(scan("{~~a~>b~>c~~}").first)
        XCTAssertEqual(item.content, NSRange(location: 3, length: 7))
        XCTAssertEqual(item.separator, NSRange(location: 4, length: 2))
        let empty = try XCTUnwrap(scan("{~~~>~~}").first)
        XCTAssertEqual(empty.separator, NSRange(location: 3, length: 2))
        XCTAssertTrue(scan("{~~a~~}").isEmpty)
    }

    func testNotChanges() {
        for text in ["{++a", "{++a--}", "{--}", "{++}", "++}{++", "{>>a<<", "{==a"] {
            XCTAssertTrue(scan(text).isEmpty, text)
        }
        XCTAssertEqual(scan("{++++}").count, 1)
    }

    func testNestingKeepsOnlyInnerChange() throws {
        let items = scan("{++a {--b--} c++}")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .deletion)
        XCTAssertEqual(items.first?.range, NSRange(location: 5, length: 7))
        let started = Date()
        XCTAssertTrue(scan(String(repeating: "{++", count: 5_000)).isEmpty)
        XCTAssertEqual(scan(String(repeating: "{++", count: 5_000) + "x++}").count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testMultilineAndBlankLines() throws {
        XCTAssertEqual(scan("{++a\nb\nc++}").count, 1)
        XCTAssertEqual(scan("{++a\r\nb++}").count, 1)
        XCTAssertTrue(scan("{++a\n\nb++}").isEmpty)
        XCTAssertTrue(scan("{++a\n>\nb++}").isEmpty)
        XCTAssertTrue(scan("{++a\r\n\r\nb++}").isEmpty)
        let separator = try XCTUnwrap(scan("{++a\u{2028}b++}").first)
        XCTAssertEqual(("{++a\u{2028}b++}" as NSString).substring(with: separator.content), "a\u{2028}b")
    }

    func testEscaping() {
        XCTAssertTrue(scan("\\{++a++}").isEmpty)
        XCTAssertEqual(scan("\\\\{++a++}").first?.range.location, 2)
    }

    func testExcludedRanges() {
        let text = "ab{++c++}de"
        XCTAssertTrue(scan(text, excluded: [NSRange(location: 0, length: 3)]).isEmpty)
        XCTAssertTrue(scan(text, excluded: [NSRange(location: 5, length: 1)]).isEmpty)
        XCTAssertEqual(scan(text, excluded: [NSRange(location: 0, length: 2)]).count, 1)
        XCTAssertEqual(scan(text, excluded: [NSRange(location: 9, length: 2)]).count, 1)
    }

    func testAdjacentChangesAreSeparate() {
        XCTAssertEqual(scan("{==а==}{>>б<<}").map(\.kind), [.highlight, .comment])
    }

    func testWindowAndParagraphRange() {
        let text = "a\n\n{++b++}\n\nc" as NSString
        XCTAssertEqual(CriticMarkupService.paragraphRange(containing: NSRange(location: 5, length: 0), in: text),
                       NSRange(location: 3, length: 7))
        XCTAssertEqual(CriticMarkupService.paragraphRange(containing: NSRange(location: 0, length: 0), in: "a\nb" as NSString),
                       NSRange(location: 0, length: 3))
        let two = "{++a++}\n\n{--b--}" as NSString
        let items = CriticMarkupService.items(in: two, window: NSRange(location: 9, length: 7), excluded: [])
        XCTAssertEqual(items.map(\.kind), [.deletion])
    }

    func testResolutionTable() {
        func resolve(_ text: String, accept: Bool) -> String {
            CriticMarkupService.resolution(of: scan(text)[0], accept: accept, in: text as NSString)
        }
        XCTAssertEqual(resolve("{++x++}", accept: true), "x")
        XCTAssertEqual(resolve("{++x++}", accept: false), "")
        XCTAssertEqual(resolve("{--x--}", accept: true), "")
        XCTAssertEqual(resolve("{--x--}", accept: false), "x")
        XCTAssertEqual(resolve("{~~а😀~>b~~}", accept: true), "b")
        XCTAssertEqual(resolve("{~~а😀~>b~~}", accept: false), "а😀")
        XCTAssertEqual(resolve("{>>c<<}", accept: true), "")
        XCTAssertEqual(resolve("{>>c<<}", accept: false), "")
        XCTAssertEqual(resolve("{==h==}", accept: true), "h")
        XCTAssertEqual(resolve("{==h==}", accept: false), "h")
        XCTAssertEqual(resolve("{++a\r\n> b++}", accept: true), "a\r\n> b")
    }

    func testResolveAllGoesFromEndToStart() {
        let text = "A{++x++}B{--y--}C{~~p~>q~~}D"
        let items = scan(text)
        func apply(accept: Bool) -> String {
            let result = NSMutableString(string: text)
            for step in CriticMarkupService.resolutions(of: items, accept: accept, in: text as NSString) {
                result.replaceCharacters(in: step.range, with: step.replacement)
            }
            return result as String
        }
        XCTAssertEqual(apply(accept: true), "AxBCqD")
        XCTAssertEqual(apply(accept: false), "AByCpD")
    }

    func testItemAtSelection() {
        let items = scan("{++a++}{--b--}")
        func kind(_ location: Int, _ length: Int = 0) -> CriticMarkupKind? {
            CriticMarkupService.item(at: NSRange(location: location, length: length), in: items)?.kind
        }
        XCTAssertEqual(kind(3), .insertion)
        XCTAssertEqual(kind(0), .insertion)
        XCTAssertEqual(kind(7), .deletion)
        XCTAssertEqual(kind(14), .deletion)
        XCTAssertEqual(kind(1, 2), .insertion)
        XCTAssertNil(kind(5, 4))
        XCTAssertNil(CriticMarkupService.item(at: NSRange(location: 0, length: 0), in: scan("x {++a++} y")))
    }

    func testNextAndPrevious() {
        let items = scan("a {++b++} c {--d--} e")
        func next(_ location: Int) -> Int? { CriticMarkupService.next(after: NSRange(location: location, length: 0), in: items)?.range.location }
        func previous(_ location: Int) -> Int? { CriticMarkupService.previous(before: NSRange(location: location, length: 0), in: items)?.range.location }
        XCTAssertEqual(next(0), 2)
        XCTAssertEqual(next(2), 12)
        XCTAssertEqual(next(5), 12)
        XCTAssertNil(next(19))
        XCTAssertEqual(previous(19), 12)
        XCTAssertNil(previous(5))
        XCTAssertEqual(previous(12), 2)
        XCTAssertNil(previous(2))
    }

    func testSuggestions() throws {
        let text = "hello world" as NSString
        func suggest(_ command: CriticMarkupCommand, _ location: Int, _ length: Int) -> MarkdownFormattingEdit? {
            CriticMarkupService.suggestion(command, in: text, selection: NSRange(location: location, length: length), items: [], excluded: [])
        }
        let insertion = try XCTUnwrap(suggest(.suggestInsertion, 0, 5))
        XCTAssertEqual(insertion.replacement, "{++hello++}")
        XCTAssertEqual(insertion.selectionRange, NSRange(location: 3, length: 5))
        XCTAssertEqual(try XCTUnwrap(suggest(.suggestDeletion, 0, 5)).replacement, "{--hello--}")
        let comment = try XCTUnwrap(suggest(.addComment, 0, 5))
        XCTAssertEqual(comment.replacement, "{==hello==}{>><<}")
        XCTAssertEqual(comment.selectionRange, NSRange(location: 14, length: 0))
        XCTAssertEqual(try XCTUnwrap(suggest(.suggestInsertion, 5, 0)).selectionRange, NSRange(location: 8, length: 0))
        let emptyComment = try XCTUnwrap(suggest(.addComment, 5, 0))
        XCTAssertEqual(emptyComment.replacement, "{>><<}")
        XCTAssertEqual(emptyComment.selectionRange, NSRange(location: 8, length: 0))
        XCTAssertNil(suggest(.suggestDeletion, 5, 0))
    }

    func testSuggestionRefusals() {
        let existing = "x {++abc++} y"
        let items = scan(existing)
        func suggest(_ text: String, _ location: Int, _ length: Int, items: [CriticMarkupItem] = [],
                     excluded: [NSRange] = [], _ command: CriticMarkupCommand = .suggestInsertion) -> MarkdownFormattingEdit? {
            CriticMarkupService.suggestion(command, in: text as NSString, selection: NSRange(location: location, length: length),
                                           items: items, excluded: excluded)
        }
        XCTAssertNil(suggest(existing, 6, 1, items: items))
        XCTAssertNil(suggest(existing, 0, 2, items: items))
        XCTAssertNil(suggest("a\n\nb", 0, 4))
        XCTAssertNil(suggest("a++}b", 0, 5))
        XCTAssertNil(suggest("0123456789ab", 5, 0, excluded: [NSRange(location: 0, length: 10)]))
        XCTAssertNil(suggest("0123456789ab", 3, 2, excluded: [NSRange(location: 0, length: 10)]))
        XCTAssertNil(suggest("\\a", 1, 1))
    }

    func testExcludedRangesFromParser() {
        let code = "```\nline1\nline2\nline3\n```\n"
        let index = MarkdownPresentationParser.parse(code).elements
        let inside = index.excludedRanges(intersecting: NSRange(location: 7, length: 3))
        XCTAssertEqual(inside.count, 1)
        XCTAssertEqual(inside.first?.location, 0)
        XCTAssertTrue(MarkdownPresentationParser.parse("plain text").elements.excludedRanges(intersecting: NSRange(location: 0, length: 10)).isEmpty)
    }

    func testParserExcludesCodeHTMLTablesAndFrontMatter() {
        XCTAssertTrue(parsedItems("```\n{++a++}\n```\n").isEmpty)
        XCTAssertTrue(parsedItems("`{++a++}`").isEmpty)
        XCTAssertTrue(parsedItems("<!-- {++a++} -->\n\ntext").isEmpty)
        XCTAssertTrue(parsedItems("| a |\n| - |\n| {++x++} |\n").isEmpty)
        XCTAssertTrue(parsedItems("---\ntitle: {++a++}\n---\n\nbody").isEmpty)
    }

    func testParserKeepsParagraphsQuotesListsAndExtensionDelimiters() {
        XCTAssertEqual(parsedItems("para {++a++}").count, 1)
        XCTAssertEqual(parsedItems("> {++a++}").count, 1)
        XCTAssertEqual(parsedItems("- {++a++}").count, 1)
        XCTAssertEqual(parsedItems("{~~а~>б~~}").count, 1)
        XCTAssertEqual(parsedItems("{==а==}").count, 1)
        XCTAssertEqual(parsedItems("{-- а --}").count, 1)
    }
}
