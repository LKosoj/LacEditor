import XCTest
@testable import LacEditor

final class MarkdownInlineStyleTests: XCTestCase {
    func testDocumentedColorsAndRemSize() throws {
        let style = try XCTUnwrap(MarkdownInlineStyle(css: "color: red; font-size: 2rem; background: yellow"))
        XCTAssertEqual(style.foreground, MarkdownSRGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(style.background, MarkdownSRGBColor(red: 1, green: 1, blue: 0))
        XCTAssertEqual(style.fontSize, 32)
        XCTAssertTrue(style.css.contains("font-size:2.0rem"))
        XCTAssertFalse(style.css.contains("background:"))
    }

    func testLastValidDeclarationAndIndependentInheritance() throws {
        let parent = try XCTUnwrap(MarkdownInlineStyle(css: "COLOR: red; background-color: YELLOW; font-size: 2rem"))
        let child = try XCTUnwrap(MarkdownInlineStyle(css: "color: red; color: yellow; font-size: -1rem; background:;"))
        let inherited = child.inheriting(parent)
        XCTAssertEqual(inherited.foreground, MarkdownSRGBColor(red: 1, green: 1, blue: 0))
        XCTAssertEqual(inherited.background, parent.background)
        XCTAssertEqual(inherited.fontSize, 32)
        XCTAssertEqual(MarkdownInlineStyle(css: " \n ; ")?.css, "")
    }

    func testCSSNumberGrammarDoesNotAcceptOtherSwiftNumbers() throws {
        for value in ["0x1p2rem", "2 rem", "1_0rem", "2.rem", "NaNrem", "-1rem"] {
            let style = try XCTUnwrap(MarkdownInlineStyle(css: "font-size:2rem;font-size:" + value))
            XCTAssertEqual(style.fontSize, 32, value)
        }
        for (value, points) in [(".5rem", 8.0), ("1e2rem", 1600.0), ("+2rem", 32.0)] {
            XCTAssertEqual(MarkdownInlineStyle(css: "font-size:" + value)?.fontSize, points)
        }
    }

    func testUnsupportedCSSKeepsTheSourceInsteadOfGuessing() {
        for css in ["position:fixed", "display:block", "display:none!important", "color:blue", "color:#fff", "font-size:0rem", "font-size:12px",
                    "color:red!important", "font-size:calc(2rem + 1px)", "background:url(x)",
                    "color:'red; color:yellow'", "font-size:1e309rem", "color"] {
            XCTAssertNil(MarkdownInlineStyle(css: css), css)
        }
    }

    func testHiddenExportPreservesVisibleEditingStyleAndAncestorVisibility() throws {
        let hidden = try XCTUnwrap(MarkdownInlineStyle(css: "DISPLAY: none; color:red"))
        let visible = try XCTUnwrap(MarkdownInlineStyle(css: "background:yellow; font-size:2rem"))
        XCTAssertTrue(hidden.hideOnExport)
        XCTAssertTrue(hidden.css.contains("display:none"))
        XCTAssertFalse(hidden.editingCSS.contains("display"))
        XCTAssertTrue(hidden.editingCSS.contains("color:"))
        let child = visible.inheriting(hidden)
        XCTAssertTrue(child.hideOnExport)
        XCTAssertEqual(child.foreground, hidden.foreground)
        XCTAssertEqual(child.background, visible.background)
        XCTAssertEqual(child.fontSize, 32)
        XCTAssertEqual(hidden.inheriting(visible), child)
        XCTAssertEqual(MarkdownInlineStyle(css: "display:none;display:none")?.css, "display:none")
        XCTAssertEqual(MarkdownInlineStyle(css: "display:none")?.editingCSS, "")
        XCTAssertFalse(visible.hideOnExport)
        XCTAssertEqual(visible.css, visible.editingCSS)
        XCTAssertNil(MarkdownInlineStyle(css: "display:none;position:fixed"))
    }
}
