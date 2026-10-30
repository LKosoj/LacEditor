import Foundation
import XCTest
@testable import LacEditor

final class MarkdownWikiLinkTests: XCTestCase {
    private func links(_ text: String) -> [MarkdownWikiLink] {
        MarkdownWikiLinkExtractor.links(in: text)
    }

    func testTargetHeadingAndAliasWithUTF16Ranges() throws {
        let text = "See [[Page#Head|Alias]] now"
        let link = try XCTUnwrap(links(text).first)
        XCTAssertEqual(links(text).count, 1)
        XCTAssertEqual((text as NSString).substring(with: link.range), "[[Page#Head|Alias]]")
        XCTAssertEqual((text as NSString).substring(with: link.displayRange), "Alias")
        XCTAssertEqual(link.target, "Page")
        XCTAssertEqual(link.heading, "Head")
        XCTAssertEqual(link.alias, "Alias")
    }

    func testPlainTargetAndHeadingOnly() throws {
        let plain = try XCTUnwrap(links("[[Заметка]]").first)
        XCTAssertEqual(plain.target, "Заметка")
        XCTAssertNil(plain.heading)
        XCTAssertNil(plain.alias)
        let current = try XCTUnwrap(links("[[#Раздел]]").first)
        XCTAssertEqual(current.target, "")
        XCTAssertEqual(current.heading, "Раздел")
    }

    func testRangesAfterEmojiAreUTF16() throws {
        let text = "😀 [[Заметка]]"
        let link = try XCTUnwrap(links(text).first)
        XCTAssertEqual(link.range.location, 3)
        XCTAssertEqual((text as NSString).substring(with: link.range), "[[Заметка]]")
    }

    func testCodeEscapesEmbedsAndBrokenFormsAreIgnored() {
        XCTAssertTrue(links("`[[a]]`").isEmpty)
        XCTAssertTrue(links("```\n[[a]]\n```").isEmpty)
        XCTAssertTrue(links("![[a]]").isEmpty)
        XCTAssertTrue(links("[[]]").isEmpty)
        XCTAssertTrue(links("[[a|]]").isEmpty)
        XCTAssertTrue(links("[[a\nb]]").isEmpty)
        XCTAssertTrue(links("[[a]").isEmpty)
        XCTAssertTrue(links("no links here").isEmpty)
    }

    func testSeveralLinksInOneLine() {
        let found = links("[[a]] and [[b|B]] and [[c#d]]")
        XCTAssertEqual(found.map(\.target), ["a", "b", "c"])
    }

    func testParserKeepsWikiLinksOnlyWhenRequested() {
        let text = "[[a]]"
        XCTAssertTrue(MarkdownPresentationParser.parse(text).wikiLinks.isEmpty)
        XCTAssertEqual(MarkdownPresentationParser.parse(text, includeWikiLinks: true).wikiLinks.count, 1)
    }
}
