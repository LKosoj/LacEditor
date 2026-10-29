import XCTest
@testable import LacEditor

final class MarkdownListStyleTests: XCTestCase {
    func testDecimalAndAlphabeticStyles() {
        XCTAssertEqual(MarkdownOrderedListStyle.decimal.marker(0), "0.")
        XCTAssertEqual(MarkdownOrderedListStyle.decimalLeadingZero.marker(1), "01.")
        XCTAssertEqual(MarkdownOrderedListStyle.decimalLeadingZero.marker(-1), "-1.")
        XCTAssertEqual(MarkdownOrderedListStyle.decimalLeadingZero.marker(100), "100.")
        XCTAssertEqual(MarkdownOrderedListStyle.lowerAlpha.marker(27), "aa.")
        XCTAssertEqual(MarkdownOrderedListStyle.upperAlpha.marker(52), "AZ.")
        XCTAssertEqual(MarkdownOrderedListStyle.lowerGreek.marker(25), "αα.")
        XCTAssertEqual(MarkdownOrderedListStyle.hiragana.marker(49), "ああ、")
        XCTAssertEqual(MarkdownOrderedListStyle.katakana.marker(49), "アア、")
        XCTAssertEqual(MarkdownOrderedListStyle.hiragana.marker(0), "0、")
        XCTAssertEqual(MarkdownOrderedListStyle.lowerAlpha.marker(Int.max).last, ".")
    }

    func testRomanRangeAndChineseFallback() {
        XCTAssertEqual(MarkdownOrderedListStyle.lowerRoman.marker(4), "iv.")
        XCTAssertEqual(MarkdownOrderedListStyle.upperRoman.marker(3999), "MMMCMXCIX.")
        XCTAssertEqual(MarkdownOrderedListStyle.upperRoman.marker(4000), "4000.")
        XCTAssertEqual(MarkdownOrderedListStyle.lowerRoman.marker(0), "0.")
        XCTAssertEqual(MarkdownOrderedListStyle.cjkIdeographic.marker(0), "零、")
        XCTAssertEqual(MarkdownOrderedListStyle.cjkIdeographic.marker(11), "十一、")
        XCTAssertEqual(MarkdownOrderedListStyle.cjkIdeographic.marker(101), "一百零一、")
        XCTAssertEqual(MarkdownOrderedListStyle.cjkIdeographic.marker(-1001), "負一千零一、")
        XCTAssertEqual(MarkdownOrderedListStyle.cjkIdeographic.marker(10000), "一〇〇〇〇、")
        XCTAssertTrue(MarkdownOrderedListStyle.cjkIdeographic.marker(Int.min).hasSuffix("、"))
    }

    func testUnorderedMarkers() {
        XCTAssertEqual(MarkdownUnorderedListStyle.disc.marker(custom: "x"), "•")
        XCTAssertEqual(MarkdownUnorderedListStyle.circle.marker(custom: "x"), "◦")
        XCTAssertEqual(MarkdownUnorderedListStyle.square.marker(custom: "x"), "▪")
        XCTAssertEqual(MarkdownUnorderedListStyle.custom.marker(custom: "😀 "), "😀 ")
        XCTAssertEqual(MarkdownUnorderedListStyle.custom.marker(custom: "a\0b"), "a\u{fffd}b")
    }

    func testNestedLevelsInheritNearestOverride() {
        var styles = MarkdownListStyles()
        XCTAssertNil(styles.orderedStyle(at: 2))
        XCTAssertNil(styles.unorderedMarker(at: 2))
        styles.ordered = [1: .lowerAlpha, 3: .upperRoman]
        styles.unordered = [2: .custom, 4: .circle]
        styles.customMarkers = [2: "😀 "]
        XCTAssertEqual(styles.orderedStyle(at: 2), .lowerAlpha)
        XCTAssertEqual(styles.orderedStyle(at: 100), .upperRoman)
        XCTAssertNil(styles.unorderedMarker(at: 1))
        XCTAssertEqual(styles.unorderedMarker(at: 3), "😀 ")
        XCTAssertEqual(styles.unorderedMarker(at: 5), "◦")
        let resolved = MarkdownResolvedListStyles(styles)
        for depth in 0...100 {
            XCTAssertEqual(resolved.orderedStyle(at: depth), styles.orderedStyle(at: depth))
            XCTAssertEqual(resolved.unorderedStyle(at: depth).map { $0.0.marker(custom: $0.1) },
                           styles.unorderedMarker(at: depth))
        }
    }

    func testCSSUsesRealDepthsAndEscapesCustomMarker() {
        var styles = MarkdownListStyles()
        styles.ordered = [1: .lowerAlpha, Int.max: .upperRoman]
        styles.unordered = [1: .custom]
        styles.customMarkers = [1: "\"</style>😀"]
        let css = styles.cssRules(depths: [1, 2])
        XCTAssertTrue(css.contains("data-lac-list-depth=\"2\""))
        XCTAssertTrue(css.contains("list-style-type:lower-alpha"))
        XCTAssertFalse(css.contains("</style>"))
        XCTAssertTrue(css.contains("\\22 \\3c "))
        XCTAssertFalse(css.contains(String(Int.max)))
    }
}
