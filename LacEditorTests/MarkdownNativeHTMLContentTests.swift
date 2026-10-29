import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownNativeHTMLContentTests: XCTestCase {
    func testTextStylesLinksAndWhitespace() throws {
        let html = "<div><p> 中文  <strong> bold <em>😀</em></strong>  <a href='relative.md'>link</a>&nbsp;é</p><p>next<br>line</p></div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.nativeHTMLContent(html, font: .systemFont(ofSize: 16), foreground: .black))
        XCTAssertEqual(result.string, "中文 bold 😀 link\u{00a0}é\nnext\nline\n")
        let raw = result.string as NSString
        let bold = try XCTUnwrap(result.attribute(.font, at: raw.range(of: "😀").location, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: bold)
        XCTAssertTrue(traits.contains(.boldFontMask)); XCTAssertTrue(traits.contains(.italicFontMask))
        XCTAssertEqual(result.attribute(.link, at: raw.range(of: "link").location, effectiveRange: nil) as? String, "relative.md")
        XCTAssertEqual(result.attribute(.underlineStyle, at: raw.range(of: "link").location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(result.attribute(.foregroundColor, at: raw.range(of: "link").location, effectiveRange: nil) as? NSColor, .linkColor)
        let styled = try XCTUnwrap(MarkdownHTMLMediaService.nativeHTMLContent("<p><span style='color:red'><a href='x'>red</a></span></p>", font: .systemFont(ofSize: 16), foreground: .black, linkColor: .blue))
        XCTAssertEqual(styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    }

    func testTableUsesTextBlocksAndSpans() throws {
        let html = "<table><tr><th rowspan='2'>A</th><td>B</td></tr><tr><td>C</td></tr></table>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.nativeHTMLContent(html, font: .systemFont(ofSize: 16), foreground: .black))
        let raw = result.string as NSString
        let style = try XCTUnwrap(result.attribute(.paragraphStyle, at: raw.range(of: "A").location, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        let headerFont = try XCTUnwrap(result.attribute(.font, at: raw.range(of: "A").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: headerFont).contains(.boldFontMask))
        XCTAssertEqual(cell.rowSpan, 2)
        XCTAssertEqual(cell.table.numberOfColumns, 2)
        XCTAssertTrue(result.string.contains("B")); XCTAssertTrue(result.string.contains("C"))
        XCTAssertNil(MarkdownHTMLMediaService.nativeHTMLContent("<table><tr><td>A</td><td>B</td></tr><tr><td>C</td></tr></table>", font: .systemFont(ofSize: 16), foreground: .black))
        XCTAssertNil(MarkdownHTMLMediaService.nativeHTMLContent("<table><tr><td>A</td><td rowspan='2'>B</td></tr><tr><td colspan='2'>C</td></tr></table>", font: .systemFont(ofSize: 16), foreground: .black))
        let wide = try XCTUnwrap(MarkdownHTMLMediaService.nativeHTMLContent("<table><tr><td colspan='1000000000'>A</td></tr></table>", font: .systemFont(ofSize: 16), foreground: .black))
        let wideStyle = try XCTUnwrap(wide.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual((wideStyle.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns, 1000)
    }

    func testLargeTableSpanUsesPhysicalRows() throws {
        let html = "<table><tr><td rowspan='10000' colspan='1000'>A</td></tr>" +
            String(repeating: "<tr></tr>", count: 9999) + "</table>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.nativeHTMLContent(html, font: .systemFont(ofSize: 16), foreground: .black))
        let style = try XCTUnwrap(result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(cell.rowSpan, 10000)
        XCTAssertEqual(cell.table.numberOfColumns, 1000)
    }

    func testPreUsesMonospacedFontAndPreservesNestedTraits() throws {
        let result = try XCTUnwrap(MarkdownHTMLMediaService.nativeHTMLContent("<div><strong><pre>a  b\n</pre></strong></div>", font: .systemFont(ofSize: 16), foreground: .black))
        XCTAssertTrue(result.string.contains("a  b\n"))
        let value = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: value)
        XCTAssertTrue(traits.contains(.fixedPitchFontMask)); XCTAssertTrue(traits.contains(.boldFontMask))
    }

    func testEditorParagraphAndCodeFontApplyToTextAndTable() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.baseWritingDirection = .rightToLeft
        paragraph.lineSpacing = 7
        let codeFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 22))
        for html in ["<div><strong><code>ABC</code></strong></div>",
                     "<table><tr><td><strong><code>ABC</code></strong></td></tr></table>"] {
            let value = try XCTUnwrap(MarkdownHTMLMediaService.nativeHTMLContent(html, font: .systemFont(ofSize: 16),
                foreground: .black, codeFont: codeFont, paragraphStyle: paragraph))
            let style = try XCTUnwrap(value.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.alignment, .right)
            XCTAssertEqual(style.baseWritingDirection, .rightToLeft)
            XCTAssertEqual(style.lineSpacing, 7)
            if html.hasPrefix("<table>") { XCTAssertTrue(style.textBlocks.first is NSTextTableBlock) }
            let rendered = try XCTUnwrap(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(rendered.familyName, codeFont.familyName)
            XCTAssertEqual(rendered.pointSize, 16, accuracy: 0.001)
            XCTAssertTrue(NSFontManager.shared.traits(of: rendered).contains(.boldFontMask))
        }
    }

    func testUnsupportedAndCancellationLeaveSource() {
        XCTAssertNil(MarkdownHTMLMediaService.nativeHTMLContent("<details><summary>x</summary>y</details>", font: .systemFont(ofSize: 16), foreground: .black))
        XCTAssertNil(MarkdownHTMLMediaService.nativeHTMLContent("<div>x</div>", font: .systemFont(ofSize: 16), foreground: .black, isCancelled: { true }))
    }
}
