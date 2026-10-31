import Foundation
import AppKit
import XCTest
@testable import LacEditor

private final class ClipboardCopyURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler?(request) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MarkdownClipboardCopyTests: XCTestCase {
    func testWholeConfirmedDetailsAndSVGCopy() throws {
        for (details, expected) in [("<details><summary>More</summary><strong>Body</strong></details>", "More"),
                                    ("<details open><summary>More</summary><strong>Body 中文</strong><br>Next</details>", "More\nBody 中文\nNext")] {
            let source = ("before\n\n" + details + "\n\nafter") as NSString
            let range = source.range(of: details)
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: range))
            XCTAssertEqual(result.text, expected)
            XCTAssertTrue(result.html.contains("<details"))
            XCTAssertTrue(result.html.contains("<strong>Body"))
            XCTAssertTrue(result.hasUnverifiedHTMLBlocks)
            XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "Body")))
            let initialOpen = details.hasPrefix("<details open>")
            let toggled = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: range,
                detailsOpenOverrides: [range: !initialOpen]))
            XCTAssertEqual(toggled.text, initialOpen ? "More" : "More\nBody")
            XCTAssertEqual(toggled.html.contains("<details open"), !initialOpen)
            XCTAssertEqual(source.substring(with: range), details)
        }
        let svg = "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        for source in [svg, "前😀 " + svg + " after", "before\n\n" + svg + "\n\nafter"] {
            let raw = source as NSString, range = raw.range(of: svg)
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: range, includeImages: true))
            XCTAssertTrue(result.html.contains("data:image/svg+xml;base64,"))
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: range.location, length: range.length - 1), includeImages: true))
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: range, includeImages: false))
        }
    }
    func testLooseHeadingAndListCopyUseConfirmedStructure() throws {
        let heading = "###中文😀" as NSString
        let copiedHeading = try XCTUnwrap(MarkdownClipboardCopyService.project(heading as String, selection: NSRange(location: 0, length: heading.length), syntax: .init(strictMode: false)))
        XCTAssertTrue(copiedHeading.html.contains("<h3>中文😀</h3>"))
        let tabbed = "###Head\ttail" as NSString
        let copiedTabbed = MarkdownClipboardCopyService.project(tabbed as String, selection: NSRange(location: 0, length: tabbed.length), syntax: .init(strictMode: false))
        let strictTabbed = MarkdownClipboardCopyService.project(tabbed as String, selection: NSRange(location: 0, length: tabbed.length))
        XCTAssertEqual(copiedTabbed?.html, strictTabbed?.html)
        XCTAssertFalse(copiedTabbed?.html.contains("<h3>") ?? false)
        let list = "10. aaa\r\n  1. ccc" as NSString
        let copiedList = try XCTUnwrap(MarkdownClipboardCopyService.project(list as String, selection: NSRange(location: 0, length: list.length), syntax: .init(strictMode: false)))
        XCTAssertTrue(copiedList.html.contains("<ol start=\"10\">"))
        XCTAssertTrue(copiedList.html.contains("<ol start=\"1\">"))
        XCTAssertEqual(list as String, "10. aaa\r\n  1. ccc")
        let withYAML = "---\r\ntitle: 中文😀\r\n---\r\n\r\n10. aaa\r\n  1. ccc" as NSString
        let listRange = withYAML.range(of: "10. aaa\r\n  1. ccc")
        let copiedAfterYAML = try XCTUnwrap(MarkdownClipboardCopyService.project(withYAML as String, selection: listRange, syntax: .init(strictMode: false)))
        XCTAssertTrue(copiedAfterYAML.html.contains("<ol start=\"1\">"))
    }
    func testTwitterWidgetCopyRequiresWholeConfirmedBlock() throws {
        let widget = "<blockquote class='twitter-tweet'><p lang='en' dir='ltr'>Sunsets 中文</p>&mdash; User <a href='https://twitter.com/Interior/status/463440424141459456?ref_src=twsrc%5Etfw'>May 5, 2014</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>"
        let source = ("before\n\n" + widget + "\n\nafter") as NSString
        let range = source.range(of: widget)
        let only = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: range))
        XCTAssertEqual(only.text, "")
        XCTAssertTrue(only.hasUnverifiedHTMLBlocks)
        XCTAssertTrue(only.html.contains("sandbox=\"allow-scripts\""))
        XCTAssertTrue(only.html.contains("platform.twitter.com/embed/Tweet.html?id=463440424141459456"))
        XCTAssertFalse(only.html.contains("widgets.js"))
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 0, length: source.length)))
        XCTAssertTrue(whole.text.contains("before")); XCTAssertTrue(whole.text.contains("after"))
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "Sunsets 中文")))
        let unsafeSource = source.replacingOccurrences(of: "widgets.js", with: "other.js") as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unsafeSource as String, selection: unsafeSource.range(of: "Sunsets 中文")))
    }

    func testStandaloneSelfClosingMediaCopyIsAtomic() throws {
        for tag in ["<audio src='https://example.invalid/a/b.wav' />", "<video src='https://example.invalid/a/b.mp4' />"] {
            let source = ("before\n\n" + tag + "\n\nafter") as NSString
            let range = source.range(of: tag)
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: range))
            XCTAssertEqual(result.text, "")
            XCTAssertTrue(result.hasUnverifiedHTMLBlocks)
            XCTAssertTrue(result.html.contains("https://example.invalid/a/b."))
            XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: range.location, length: range.length - 1)))
        }
    }

    func testConfirmedMediaCopyPreservesDOMAndRejectsPartialSelection() throws {
        let source = "before <video src=\"https://example.invalid/a.mp4\" controls><source src=\"https://example.invalid/b.mp4\" type=\"video/mp4\">fallback &amp; **bold**</video> after" as NSString
        let range = source.range(of: "<video src=\"https://example.invalid/a.mp4\" controls><source src=\"https://example.invalid/b.mp4\" type=\"video/mp4\">fallback &amp; **bold**</video>")
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 0, length: source.length)))
        XCTAssertEqual(whole.text, "before  after")
        XCTAssertTrue(whole.html.contains("<video"))
        XCTAssertTrue(whole.html.contains("https://example.invalid/a.mp4"))
        XCTAssertTrue(whole.html.contains("https://example.invalid/b.mp4"))
        XCTAssertTrue(whole.html.contains("fallback &amp;"))
        XCTAssertTrue(whole.hasUnverifiedHTMLBlocks)
        let only = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: range))
        XCTAssertEqual(only.text, "")
        XCTAssertTrue(only.hasUnverifiedHTMLBlocks)
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "fallback")))
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: range.location, length: range.length - 1)))
        let unsafeSource = "before <video src=\"https://example.invalid/a\" onplay=\"evil()\">hidden</video> after" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unsafeSource as String, selection: unsafeSource.range(of: "hidden")))
        XCTAssertEqual(MarkdownClipboardCopyService.project(unsafeSource as String, selection: unsafeSource.range(of: "before"))?.text, "before")
        for malformed in ["before <video src=\"https://example.invalid/a\">hidden",
                          "before <video src=\"https://example.invalid/a\"><audio src=\"https://example.invalid/b\">hidden</video></audio>"] {
            let raw = malformed as NSString
            XCTAssertNil(MarkdownClipboardCopyService.project(malformed, selection: raw.range(of: "hidden")))
        }
        let inert = "before <script><video src=\"https://example.invalid/a\">secret</video></script> after" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(inert as String, selection: inert.range(of: "secret")))
        for address in ["relative.wav", "javascript:alert(1)"] {
            let value = "<audio src=\"\(address)\">fallback</audio>" as NSString
            XCTAssertNil(MarkdownClipboardCopyService.project(value as String, selection: NSRange(location: 0, length: value.length)))
        }
        let frame = "<iframe src=\"https://example.invalid\">fallback</iframe>" as NSString
        let frameCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(frame as String, selection: NSRange(location: 0, length: frame.length)))
        XCTAssertTrue(frameCopy.html.contains("sandbox=\"allow-scripts\""))
        XCTAssertEqual(frameCopy.text, "")
    }

    func testPairedInlineHTMLStrongAndEmphasisCopySelectedContent() throws {
        for newline in ["\n", "\r\n"] {
            let source = ("before <strong>中文😀</strong> after" + newline + newline + "<em>x **bold**</em>") as NSString
            let text = source as String
            let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(text, selection: NSRange(location: 0, length: source.length)))
            XCTAssertTrue(whole.html.contains("<strong>中文😀</strong>"))
            XCTAssertTrue(whole.html.contains("<em>x </em><strong><em>bold</em></strong>"))
            let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(text, selection: source.range(of: "文😀")))
            XCTAssertEqual(partial.text, "文😀")
            XCTAssertEqual(partial.html, "<strong>文😀</strong>")
            XCTAssertNil(MarkdownClipboardCopyService.project(text, selection: NSRange(location: source.range(of: "<strong>").location, length: 3)))
        }
        let nested = "<strong><strong>x</strong></strong>" as NSString
        XCTAssertEqual(MarkdownClipboardCopyService.project(nested as String, selection: NSRange(location: 0, length: nested.length))?.html, "<strong>x</strong>")
        let unmatched = "<strong>selected" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unmatched as String, selection: NSRange(location: 0, length: unmatched.length)))
        let inert = "before <script><strong>hidden</strong></script> after\n\nbefore <template><strong>inert</strong></template> after" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(inert as String, selection: inert.range(of: "hidden")))
        XCTAssertNil(MarkdownClipboardCopyService.project(inert as String, selection: inert.range(of: "inert")))
        XCTAssertEqual(MarkdownClipboardCopyService.project(inert as String, selection: inert.range(of: "before"))?.text, "before")
    }
    func testPairedInlineHTMLStylesShareNestedProjection() throws {
        let source = "<b>bold <i>italic <u>under</u></i></b> <s>strike</s> <mark>mark</mark> <sub>lo</sub><sup>hi</sup>" as NSString
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 0, length: source.length)))
        XCTAssertEqual(whole.text, "bold italic under strike mark lohi")
        XCTAssertTrue(whole.html.contains("<strong><em><u>under</u></em></strong>"))
        XCTAssertTrue(whole.html.contains("<del>strike</del>"))
        XCTAssertTrue(whole.html.contains("<mark>mark</mark>"))
        XCTAssertTrue(whole.html.contains("<sub>lo</sub><sup>hi</sup>"))
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "under")))
        XCTAssertEqual(partial.text, "under")
        XCTAssertEqual(partial.html, "<strong><em><u>under</u></em></strong>")
        for text in ["# <mark>title</mark>", "**<i>nested</i>**", "[<u>linked</u>](https://example.com)"] {
            let raw = text as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(text, selection: NSRange(location: 0, length: raw.length)), text)
            XCTAssertTrue(result.html.contains(text.hasPrefix("#") ? "<mark>title</mark>" : text.hasPrefix("**") ? "<strong><em>nested</em></strong>" : "<u>linked</u>"), text)
        }
        let malformed = "<b><i>x</b></i>" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(malformed as String, selection: NSRange(location: 0, length: malformed.length)))
    }

    func testKeyboardHTMLCopiesConfirmedContent() throws {
        let source = "before <kbd>中文😀</kbd> after" as NSString
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 0, length: source.length)))
        XCTAssertTrue(whole.html.contains("<kbd>中文😀</kbd>"))
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "文😀")))
        XCTAssertEqual(partial.text, "文😀")
        XCTAssertEqual(partial.html, "<kbd>文😀</kbd>")
        XCTAssertTrue(partial.runs.contains { $0.code })
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: source.range(of: "<kbd>").location, length: 3)))
        for text in ["**<kbd>key</kbd>**", "[<kbd>key</kbd>](https://example.com)", "<div>before <kbd>key</kbd> after</div>"] {
            let raw = text as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(text, selection: NSRange(location: 0, length: raw.length)))
            XCTAssertTrue(result.html.contains("<kbd>key</kbd>"), text)
        }
        let unsafeSource = "before <kbd onclick='bad()'>key</kbd> after" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unsafeSource as String, selection: NSRange(location: 0, length: unsafeSource.length)))
    }

    func testStyledSpanCopyInheritsFields() throws {
        let source = "before <span style='color:red;font-size:2rem'>outer <span style='background:yellow'>**中文😀**</span></span> after" as NSString
        let selection = source.range(of: "中文😀")
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: selection))
        XCTAssertEqual(result.text, "中文😀")
        let style = try XCTUnwrap(result.runs.first?.inlineStyle)
        XCTAssertEqual(style.foreground, MarkdownSRGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(style.background, MarkdownSRGBColor(red: 1, green: 1, blue: 0))
        XCTAssertEqual(style.fontSize, 32)
        XCTAssertTrue(result.runs.first?.bold == true)
        XCTAssertTrue(result.html.contains("<span style=\"" + style.css + "\">"))
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String,
            selection: NSRange(location: source.range(of: "<span").location, length: 3)))
        let unsupported = "before <span style='position:fixed'>hidden</span> after" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unsupported as String,
            selection: NSRange(location: 0, length: unsupported.length)))
        XCTAssertNil(MarkdownClipboardCopyService.project(unsupported as String, selection: unsupported.range(of: "hidden")))
    }

    func testHiddenExportSpanCopiesVisibleEditingText() throws {
        for source in ["before <span style='display:none;color:red'><span style='font-size:2rem'>中文😀</span></span> after",
                       "<div>before <span style='display:none;color:red'><span style='font-size:2rem'>中文😀</span></span> after</div>"] {
            let raw = source as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "中文😀")))
            XCTAssertEqual(result.text, "中文😀")
            XCTAssertFalse(result.html.contains("display:none"))
            XCTAssertTrue(result.html.contains("font-size:2.0rem"))
            XCTAssertEqual(result.runs.first?.inlineStyle?.foreground, MarkdownSRGBColor(red: 1, green: 0, blue: 0))
            XCTAssertEqual(result.runs.first?.inlineStyle?.fontSize, 32)
        }
    }

    func testStyledSpanInHTMLBlockUsesConfirmedDOM() throws {
        let source = "<div>before <span style='color:red'>red <span style='background:yellow;font-size:2rem'>中文😀</span></span> after</div>" as NSString
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 0, length: source.length)))
        let range = (result.text as NSString).range(of: "中文😀")
        let run = try XCTUnwrap(result.runs.first { NSIntersectionRange($0.range, range).length > 0 })
        XCTAssertEqual(run.inlineStyle?.foreground, MarkdownSRGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(run.inlineStyle?.background, MarkdownSRGBColor(red: 1, green: 1, blue: 0))
        XCTAssertEqual(run.inlineStyle?.fontSize, 32)
        XCTAssertTrue(result.html.contains("font-size:2.0rem"))
        let unsupported = "<div><span style='position:fixed'>hidden</span></div>" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unsupported as String, selection: NSRange(location: 0, length: unsupported.length)))
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String,
            selection: NSRange(location: source.range(of: "<span").location, length: 3)))
    }

    func testStyledSpanInTableUsesCellSourcePositions() throws {
        let source = "| Left | Right |\n| --- | --- |\n| **<span style='color:red;font-size:2rem'>中文\\|😀</span>** | neighbor |" as NSString
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 0, length: source.length)))
        XCTAssertTrue(whole.text.contains("中文|😀"))
        XCTAssertTrue(whole.text.contains("neighbor"))
        XCTAssertTrue(whole.html.contains("font-size:2.0rem"))
        let selected = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "😀")))
        XCTAssertEqual(selected.text, "😀")
        XCTAssertEqual(selected.runs.first?.inlineStyle?.fontSize, 32)
        XCTAssertTrue(selected.runs.first?.bold == true)
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String,
            selection: NSRange(location: source.range(of: "<span").location, length: 3)))
        let other = "| A |\n| --- |\n| <kbd>key</kbd> |" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(other as String, selection: NSRange(location: 0, length: other.length)))
        let unsafeSource = "| A | B |\n| --- | --- |\n| <span style='position:fixed'>hidden</span> | visible |" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unsafeSource as String, selection: unsafeSource.range(of: "hidden")))
    }

    func testNestedHTMLBlockCopyPreservesBlockBoundaries() throws {
        for (source, expected) in [
            ("<div>a<div><strong>中文😀</strong></div>c</div>", "a\n中文😀\nc"),
            ("<div>a<p>b</p>c</div>", "a\nb\n\nc"),
            ("<div><div>a</div><div>b</div></div>", "a\nb"),
            ("<div>a<div></div>b</div>", "a\nb"),
            ("<div>中文😀\r\n<div>b</div>\r\nc</div>", "中文😀\nb\nc")
        ] {
            let raw = source as NSString
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)), source)
            XCTAssertEqual(copy.text, expected, source)
            XCTAssertTrue(copy.html.contains("<div>"), source)
        }
    }

    func testPartialNestedHTMLBlockUsesSelectionBoundaries() throws {
        let source = "<div>AA<div>BB</div><p>CC</p>DD</div>" as NSString
        for (start, end, expected) in [("AA", "BB", "A\nB"), ("BB", "CC", "B\nC"),
                                       ("BB", "DD", "B\nCC\n\nD"), ("AA", "DD", "A\nBB\nCC\n\nD")] {
            let lower = source.range(of: start).location + 1, upper = source.range(of: end).location + 1
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: lower, length: upper - lower)))
            XCTAssertEqual(fragment.text, expected)
            XCTAssertTrue(fragment.hasUnverifiedHTMLBlocks)
        }
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 1, length: 2)))
        let spaces = "<div>aa  bb<div>cc</div></div>" as NSString
        let group = spaces.range(of: "  ")
        for offset in 0..<2 {
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(spaces as String, selection: NSRange(location: group.location + offset, length: 1)))
            XCTAssertEqual(copy.text, " ")
            XCTAssertTrue(copy.html.contains("white-space:break-spaces"))
        }
        let crossed = "<div>aa <strong>  bb </strong> cc<div> dd </div> ee</div>" as NSString
        let selectedSpace = NSRange(location: crossed.range(of: "aa ").location + 2, length: 1)
        XCTAssertEqual(MarkdownClipboardCopyService.project(crossed as String, selection: selectedSpace)?.text, " ")
        let hiddenSpaces = NSRange(location: crossed.range(of: "  bb").location, length: 2)
        XCTAssertNil(MarkdownClipboardCopyService.project(crossed as String, selection: hiddenSpaces))
        let entity = "<div>a&#32;<strong>b</strong><div>e\u{301} z</div></div>" as NSString
        XCTAssertEqual(MarkdownClipboardCopyService.project(entity as String, selection: entity.range(of: "&#32;"))?.text, " ")
        XCTAssertNil(MarkdownClipboardCopyService.project(entity as String, selection: entity.range(of: "#32")))
        let combining = "<div>a \u{301}b<div>c</div></div>" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(combining as String, selection: combining.range(of: " ")))
        let unicode = "<div>A<div>中文&amp;😀</div><p>尾巴</p>Z</div>" as NSString
        let lower = unicode.range(of: "中文").location, upper = unicode.range(of: "尾巴").location + 1
        let unicodeCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(unicode as String, selection: NSRange(location: lower, length: upper - lower)))
        XCTAssertEqual(unicodeCopy.text, "中文&😀\n尾")
        XCTAssertNil(MarkdownClipboardCopyService.project(unicode as String, selection: unicode.range(of: "amp")))
        let crlf = "<div>A\r\n<div>B</div>C</div>" as NSString
        let newline = crlf.range(of: "\r\n")
        XCTAssertNil(MarkdownClipboardCopyService.project(crlf as String, selection: NSRange(location: newline.location + 1, length: 1)))
    }

    func testCopyCollapsesOnlyConfirmedSpacesAndSoftBreaks() throws {
        let source = "a   😀\nb  \nc\n\n`code   text`"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let defaultCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection))
        let collapsed = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection, syntax: .init(preserveEditingWhitespace: false)))
        XCTAssertEqual(defaultCopy.text, collapsed.text)
        XCTAssertEqual(defaultCopy.html, collapsed.html)
        XCTAssertTrue(defaultCopy.text.contains("a 😀\nb"))
        let preserved = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection, syntax: .init(preserveEditingWhitespace: true)))
        XCTAssertTrue(preserved.html.contains("<span style=\"white-space:break-spaces\">a   😀</span>"))
        let syntax = MarkdownSyntaxOptions(preserveEditingWhitespace: false, preserveEditingSoftBreaks: false)
        let copied = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection, syntax: syntax))
        XCTAssertTrue(copied.text.contains("a 😀 b\nc"))
        XCTAssertTrue(copied.text.contains("code   text"))
        XCTAssertTrue(copied.html.contains("a 😀 b<br>c"))
        let part = (source as NSString).range(of: "  😀")
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: part, syntax: syntax))
        XCTAssertEqual(partial.text, " 😀")
        XCTAssertEqual(source, "a   😀\nb  \nc\n\n`code   text`")
    }
    func testCopyUsesDisabledInlineMathSnapshot() throws {
        let source = "before $x$ after"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: selection)?.mathImages.count, 1)
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection,
                                                                           syntax: .init(inlineMath: false)))
        XCTAssertEqual(fragment.text, source)
        XCTAssertTrue(fragment.html.contains("$x$"))
    }
    func testInlineMathCopyKeepsEarlierContextWithoutSelectingIt() throws {
        let source = "先 $\\def\\foo{z}$ text $\\foo$ after" as NSString
        let selected = source.range(of: "$\\foo$")
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: selected))
        XCTAssertEqual(fragment.text, "$\\foo$")
        XCTAssertEqual(fragment.mathExpressions.map(\.source), ["\\def\\foo{z}", "\\foo"])
        XCTAssertEqual(fragment.mathImages.count, 1)
        XCTAssertEqual(fragment.mathImages.first?.expressionIndex, 1)
        XCTAssertFalse(fragment.html.contains("def"))
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: selected.location + 1, length: selected.length - 2)))
    }

    @MainActor
    func testInlineMathCopyResolvesOnlySelectedFormula() async throws {
        let source = "先 $\\def\\foo{z}$ text $\\foo$ after" as NSString
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "$\\foo$")))
        let resolved = try await MarkdownClipboardCopyService.resolveMath(fragment, width: 400, fontSize: 16, dark: false, physics: true, numbering: .none)
        XCTAssertEqual(resolved.text, "$\\foo$")
        XCTAssertTrue(resolved.html.contains("data:image/png;base64,"))
        XCTAssertFalse(resolved.html.contains("LACCOPYMATH"))
        XCTAssertFalse(resolved.html.contains("\\def"))
    }
    func testRichCopyEmbedsLocalAndRemoteSVGBytes() async throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'/>".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try svg.write(to: directory.appendingPathComponent("local.svg"))
        let source = "![local](local.svg#first) ![remote](https://8.8.8.8/image.svg#second)"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source,
            selection: NSRange(location: 0, length: (source as NSString).length), includeImages: true,
            documentURL: directory.appendingPathComponent("note.md"), allowRemoteImages: true))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClipboardCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ClipboardCopyURLProtocol.handler = { _ in svg }
        defer { session.invalidateAndCancel(); ClipboardCopyURLProtocol.handler = nil }
        let result = try await MarkdownClipboardCopyService.resolveRemoteImages(fragment, session: session)
        let uri = "data:image/svg+xml;base64," + svg.base64EncodedString()
        XCTAssertEqual(result.html.components(separatedBy: uri).count - 1, 2)
        XCTAssertTrue(result.html.contains(uri + "#first"))
        XCTAssertTrue(result.html.contains(uri + "#second"))
    }

    @MainActor
    func testSVGRTFIsEitherRejectedOrKeepsImageAttachment() async throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'><rect width='4' height='4' fill='red'/></svg>".utf8)
        let source = "![x](data:image/svg+xml;base64," + svg.base64EncodedString() + ")"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source,
            selection: NSRange(location: 0, length: (source as NSString).length), includeImages: true))
        guard let data = await MarkdownClipboardCopyService.structuralRTF(fragment) else { return }
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var images: [NSImage] = []
        restored.enumerateAttribute(.attachment, in: NSRange(location: 0, length: restored.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) { images.append(image) }
        }
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.2)
    }
    func testRichCopyResolvesImageAgainstDocumentResourceRoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("a#b.png"))
        let source = "---\ntypora-root-url: .\n---\n\n![x](/a%23b.png)"
        let selection = (source as NSString).range(of: "![x](/a%23b.png)")
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection, includeImages: true,
            documentURL: directory.appendingPathComponent("document.md")))
        XCTAssertTrue(fragment.html.contains("data:image/png;base64," + png.base64EncodedString()))
        let invalidYAML = "---\ninvalid: [\n---\n\nordinary text"
        let textRange = (invalidYAML as NSString).range(of: "ordinary text")
        XCTAssertEqual(MarkdownClipboardCopyService.project(invalidYAML, selection: textRange, includeImages: true)?.text, "ordinary text")
        let relative = "---\ninvalid: [\n---\n\n![x](a%23b.png)"
        let relativeRange = (relative as NSString).range(of: "![x](a%23b.png)")
        XCTAssertNotNil(MarkdownClipboardCopyService.project(relative, selection: relativeRange, includeImages: true,
            documentURL: directory.appendingPathComponent("document.md")))
        let rooted = "---\ninvalid: [\n---\n\n![x](/a%23b.png)"
        XCTAssertNil(MarkdownClipboardCopyService.project(rooted, selection: (rooted as NSString).range(of: "![x](/a%23b.png)"), includeImages: true,
            documentURL: directory.appendingPathComponent("document.md")))
    }
    func testCopyRejectsUncoveredDefinitionsWithoutRejectingCode() throws {
        for source in ["> Before\n>\n> [^unused]: Note", "- Before\n\n  [^unused]: Note"] {
            let raw = source as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)), source)
            XCTAssertTrue(result.text.contains("[^unused]: Note"), source)
            XCTAssertTrue(result.html.contains("[^unused]: Note"), source)
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "Before"))?.text, "Before", source)
        }
        let definition = "[foo]: https://example.com\nhello\n\n[foo]"
        let definitionRaw = definition as NSString
        let full = try XCTUnwrap(MarkdownClipboardCopyService.project(definition, selection: NSRange(location: 0, length: definitionRaw.length)))
        XCTAssertEqual(full.text, "[foo]: https://example.com\nhello\n\nfoo")
        XCTAssertEqual(MarkdownClipboardCopyService.project(definition, selection: definitionRaw.range(of: "hello"))?.text, "hello")
        for newline in ["\n", "\r", "\r\n"] {
            let repeated = "[id]: /hello" + newline + "中😀 hello" + newline + "hello"
            let raw = repeated as NSString
            let last = raw.range(of: "hello", options: .backwards)
            XCTAssertEqual(MarkdownClipboardCopyService.project(repeated, selection: last)?.text, "hello")
        }
        let mixed = "[id]: https://example.com\r\n中 **bold** [link][id] $x$"
        let mixedRaw = mixed as NSString
        XCTAssertEqual(MarkdownClipboardCopyService.project(mixed, selection: mixedRaw.range(of: "bold"))?.text, "bold")
        let link = try XCTUnwrap(MarkdownClipboardCopyService.project(mixed, selection: mixedRaw.range(of: "[link][id]")))
        XCTAssertEqual(link.text, "link")
        XCTAssertTrue(link.html.contains("https://example.com"))
        let math = try XCTUnwrap(MarkdownClipboardCopyService.project(mixed, selection: mixedRaw.range(of: "$x$")))
        XCTAssertEqual(math.text, "$x$")
        XCTAssertEqual(math.mathImages.count, 1)
        let tabbed = "[id]: /url\n\thello"
        XCTAssertEqual(MarkdownClipboardCopyService.project(tabbed, selection: (tabbed as NSString).range(of: "hello"))?.text, "hello")
        let allTabbed = try XCTUnwrap(MarkdownClipboardCopyService.project(tabbed, selection: NSRange(location: 0, length: (tabbed as NSString).length)))
        XCTAssertTrue(allTabbed.text.contains("[id]: /url"))
        XCTAssertTrue(allTabbed.text.contains("hello"))
        let contentTab = "[id]: /url\n\thello\tworld"
        XCTAssertNil(MarkdownClipboardCopyService.project(contentTab, selection: (contentTab as NSString).range(of: "hello")))
        let tableDefinition = "[foo]: https://example.com\n| A |\n|---|\n| x |"
        let tableRaw = tableDefinition as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(tableDefinition, selection: NSRange(location: 0, length: tableRaw.length)))
        XCTAssertNil(MarkdownClipboardCopyService.project(tableDefinition, selection: NSRange(location: 5, length: tableRaw.length - 5)))
        let code = "```\n[^unused]: Note\n```"
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(code, selection: NSRange(location: 0, length: (code as NSString).length)))
        XCTAssertEqual(result.text, "[^unused]: Note\n")
    }

    func testReferenceDefinitionsInsideContainersKeepSelectedSource() throws {
        for newline in ["\n", "\r\n"] {
            for source in ["> [id]: /url" + newline + "> 中文 hello",
                           "- [id]: /url" + newline + "  中文 hello",
                           "> - [id]: /url" + newline + ">   中文 hello",
                           "> [id]: /url" + newline + ">\t中文 hello",
                           "- [id]: /url" + newline + "\t中文 hello",
                           "> - [id]: /url" + newline + "> \t中文 hello"] {
                let raw = source as NSString
                let selected = raw.range(of: "中文 hello")
                XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: selected)?.text, "中文 hello", source)
                let full = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)), source)
                XCTAssertTrue(full.text.contains("[id]: /url"), source)
                XCTAssertTrue(full.text.contains("中文 hello"), source)
            }
        }
        for source in ["> [id]: /url\n> hello\n**world**", "> [id]: /url\r\n> hello\r\n>   **world**"] {
            let selection = (source as NSString).range(of: "world")
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection), source)
            XCTAssertEqual(fragment.text, "world", source)
            XCTAssertTrue(fragment.html.contains("<strong>world</strong>"), source)
        }
    }

    func testQuoteReferenceTitleKeepsOnlySelectedSource() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["> [a]: /x", "> \"title 中文", "> [b]: /y\"", "> **bold** [link][a] $x$"].joined(separator: newline)
            let raw = source as NSString
            let partial = raw.range(of: "title 中文")
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: partial)?.text, "title 中文")
            let prefix = NSRange(location: 0, length: raw.range(of: "> **bold**").location)
            let selected = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: prefix))
            XCTAssertTrue(selected.text.contains("\"title 中文"))
            XCTAssertTrue(selected.text.contains("[b]: /y\""))
            XCTAssertFalse(selected.text.contains("bold"))
            let definitions = ["> > [a]: /x", "> > [b]: /y", "> > 中文 [link][b]"].joined(separator: newline)
            let second = (definitions as NSString).range(of: "[b]: /y")
            XCTAssertEqual(MarkdownClipboardCopyService.project(definitions, selection: second)?.text, "[b]: /y")
        }
    }

    func testListReferencePrefixKeepsUserSpacesAndTitle() throws {
        for newline in ["\n", "\r\n"] {
            for lines in [
                ["- [a]: /x", "  [b]: /y", "  中文 [link][b]"],
                ["> - [a]: /x", ">   \"title 中文", ">   [b]: /y\"", ">   **bold** $x$"],
                ["- [x] [a]: /x", "  [b]: /y", "  中文 [link][b]"],
                ["- outer", "  - [a]: /x", "    [b]: /y", "    中文 [link][b]"]
            ] {
                let text = lines.joined(separator: newline)
                let raw = text as NSString
                let selected = raw.range(of: "[b]: /y")
                XCTAssertEqual(MarkdownClipboardCopyService.project(text, selection: selected)?.text, "[b]: /y", text)
            }
            let text = ["- [a]: /x", "   [b]: /y", "  hello"].joined(separator: newline)
            let raw = text as NSString
            let start = raw.range(of: "   [b]").location
            let selection = NSRange(location: start, length: ("   [b]: /y" as NSString).length)
            XCTAssertEqual(MarkdownClipboardCopyService.project(text, selection: selection)?.text, " [b]: /y")
        }
    }

    func testListReferenceTabPreservesOnlySelectedRemainder() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["- [a]: /x", "\t[b]: /y", "  中文"].joined(separator: newline)
            let raw = source as NSString
            let tab = raw.range(of: "\t")
            let tabAndText = NSRange(location: tab.location, length: ("\t[b]: /y" as NSString).length)
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: tabAndText)?.text, "  [b]: /y")
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "[b]: /y"))?.text, "[b]: /y")
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: tab)?.text, "  ")
            let quote = ["> - [a]: /x", "> \t[b]: /y", ">   中文"].joined(separator: newline)
            let quoteRaw = quote as NSString
            let quoteTab = quoteRaw.range(of: "\t")
            let quoteSelection = NSRange(location: quoteTab.location, length: ("\t[b]: /y" as NSString).length)
            XCTAssertEqual(MarkdownClipboardCopyService.project(quote, selection: quoteSelection)?.text, "[b]: /y")
            let unknown = [">\t- [a]: /x", ">\t\t[b]: /y", ">\t  中文"].joined(separator: newline) as NSString
            let second = unknown.range(of: "[b]: /y")
            XCTAssertNil(MarkdownClipboardCopyService.project(unknown as String, selection: second))
        }
    }

    func testCancelledListReferenceTabProjectionReturnsNothing() async {
        let source = "- [a]: /x\n\t[b]: /y\n  中文"
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length))
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    func testReferenceRetainedTabsMapSelectedInlineContent() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = ["- [a]: /x", "  [b]: /y", "  中文\t**bold**\t[link][b] $x$"].joined(separator: newline)
            let raw = source as NSString
            let selected = raw.range(of: "bold")
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selected), source)
            XCTAssertEqual(fragment.text, "bold")
            XCTAssertTrue(fragment.html.contains("<strong>bold</strong>"))
            let link = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "link")), source)
            XCTAssertEqual(link.text, "link")
            XCTAssertTrue(link.html.contains("href=\"/y\""))
            let full = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)), source)
            XCTAssertTrue(full.text.contains("中文"))
            XCTAssertTrue(full.text.contains("$x$"))
        }
    }

    func testConfirmedHTMLLinksCopySelectedText() throws {
        for newline in ["\n", "\r\n"] {
            for (href, decoded) in [("https://example.com/?a=1&amp;b=2", "https://example.com/?a=1&b=2"), ("../doc.md", "../doc.md"), ("#target", "#target")] {
                let source = "before" + newline + "<a href='\(href)'>中文 **bold**</a>"
                let raw = source as NSString
                let selected = raw.range(of: "中文")
                let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selected), source)
                XCTAssertEqual(result.text, "中文")
                XCTAssertTrue(result.html.contains("href=\"\(decoded.replacingOccurrences(of: "&", with: "&amp;"))\""))
                let marker = raw.range(of: "href")
                XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: marker))
            }
        }
        for source in ["text <a href='javascript:alert(1)'>bad</a>", "text <a href='&#106;avascript:alert(1)'>bad</a>",
                       "text <a href='x' onclick='bad'>bad</a>", "text <a href='x' href='y'>bad</a>",
                       "text <a href='x'>[bad](y)</a>", "text [<a href='x'>bad</a>](y)"] {
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)), source)
        }
    }

    func testConfirmedInlineHTMLBreakCopiesOnlySelectedContent() throws {
        for marker in ["<br>", "<br/>", "<br />"] {
            let source = "中文 **before \(marker) after**"
            let raw = source as NSString
            let range = raw.range(of: marker)
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: range))
            XCTAssertEqual(result.text, "\n")
            XCTAssertTrue(result.html.contains("<br>"))
            let full = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
            XCTAssertEqual(full.text, "中文 before \n after")
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: range.location + 1, length: range.length - 2)))
        }
        for source in ["text <br class='x'> tail", "text <script><br></script> tail", "text <template><br></template> tail"] {
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: (source as NSString).range(of: "br")), source)
        }
    }

    func testConfirmedInlineHTMLImageCopiesSelectedResource() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let tag = "<img src='data:image/png;base64,\(png)' alt='中文' width='20'>"
        let source = "before \(tag) after"
        let raw = source as NSString
        let range = raw.range(of: tag)
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: range, includeImages: true))
        XCTAssertTrue(fragment.html.contains("data:image/png;base64," + png))
        XCTAssertTrue(fragment.html.contains("alt=\"中文\""))
        XCTAssertTrue(fragment.html.contains("width:20.0px"))
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: range.location + 1, length: range.length - 2), includeImages: true))
        let linked = "before [\(tag)](https://example.com) after"
        let linkedRaw = linked as NSString
        let linkedResult = try XCTUnwrap(MarkdownClipboardCopyService.project(linked, selection: linkedRaw.range(of: tag), includeImages: true))
        XCTAssertTrue(linkedResult.html.contains("<a href=\"https://example.com\"><img"))
        let remote = "before <img src='https://example.com/p.png' alt='remote'> after"
        let remoteRange = (remote as NSString).range(of: "<img src='https://example.com/p.png' alt='remote'>")
        let pending = try XCTUnwrap(MarkdownClipboardCopyService.project(remote, selection: remoteRange, includeImages: true, allowRemoteImages: true))
        XCTAssertEqual(pending.remoteImages.count, 1)
        for hidden in ["before <select>\(tag)</select>", "before <template>\(tag)</template>", "before <script>\(tag)</script>"] {
            XCTAssertNil(MarkdownClipboardCopyService.project(hidden, selection: (hidden as NSString).range(of: tag), includeImages: true), hidden)
        }
        let block = "<div>before \(tag) after</div>"
        let selected = try XCTUnwrap(MarkdownClipboardCopyService.project(block, selection: (block as NSString).range(of: tag), includeImages: true))
        XCTAssertEqual(selected.text, "中文")
        XCTAssertTrue(selected.html.contains("data:image/png;base64," + png))
        XCTAssertFalse(selected.html.contains("before"))
        XCTAssertFalse(selected.html.contains("after"))
        let quote = "> <div>\r\n> 中文 \(tag) after\r\n> </div>"
        let quoteImage = try XCTUnwrap(MarkdownClipboardCopyService.project(quote, selection: (quote as NSString).range(of: tag), includeImages: true))
        XCTAssertEqual(quoteImage.text, "中文")
        XCTAssertTrue(quoteImage.html.contains("data:image/png;base64," + png))
        XCTAssertFalse(quoteImage.html.contains("after"))
        let nested = "<div>before <span style='color:red'><strong>\(tag)</strong></span> after</div>"
        let nestedRaw = nested as NSString
        let nestedImage = try XCTUnwrap(MarkdownClipboardCopyService.project(nested, selection: nestedRaw.range(of: tag), includeImages: true))
        XCTAssertEqual(nestedImage.text, "中文")
        XCTAssertTrue(nestedImage.html.contains("<strong><img"))
        XCTAssertTrue(nestedImage.html.contains("color:rgba("))
        XCTAssertNil(MarkdownClipboardCopyService.project(nested, selection: NSRange(location: nestedRaw.range(of: tag).location + 1, length: 3), includeImages: true))
        let value = try XCTUnwrap(MarkdownInlineStyle(css: "background:yellow"))
        for (opening, closing, expected) in [
            ("<mark><span style='background:yellow'>", "</span></mark>", "<mark><span style=\"" + value.css + "\"><img"),
            ("<span style='background:yellow'><mark>", "</mark></span>", "<span style=\"" + value.css + "\"><mark><img")
        ] {
            let input = ("<div>" + opening + tag + closing + "</div>") as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(input as String, selection: input.range(of: tag), includeImages: true))
            XCTAssertTrue(result.html.contains(expected))
        }
        let unsafeNested = "<div><span style='position:fixed'>\(tag)</span></div>" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(unsafeNested as String, selection: unsafeNested.range(of: tag), includeImages: true))
        let blocks = "<div>before<p><mark>\(tag)</mark></p>after</div>" as NSString
        let blockCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(blocks as String, selection: NSRange(location: 0, length: blocks.length), includeImages: true))
        XCTAssertEqual(blockCopy.text, "before\n中文\n\nafter")
        XCTAssertTrue(blockCopy.html.contains("<p><mark><img"))
        let blockImage = try XCTUnwrap(MarkdownClipboardCopyService.project(blocks as String, selection: blocks.range(of: tag), includeImages: true))
        XCTAssertEqual(blockImage.text, "中文")
        XCTAssertTrue(blockImage.html.contains("<p><mark><img"))
        let emptyTag = "<img src='data:image/png;base64,\(png)' alt=''>"
        let emptyBlock = ("<div><p>" + emptyTag + "</p></div>") as NSString
        let emptyCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(emptyBlock as String, selection: emptyBlock.range(of: emptyTag), includeImages: true))
        XCTAssertEqual(emptyCopy.text, "")
        XCTAssertTrue(emptyCopy.html.contains("<img"))
        let mixed = "<div>before <strong>bold</strong> \(tag) after</div>"
        let mixedRaw = mixed as NSString
        let fullBlock = try XCTUnwrap(MarkdownClipboardCopyService.project(mixed, selection: NSRange(location: 0, length: mixedRaw.length), includeImages: true))
        XCTAssertEqual(fullBlock.text, "before bold 中文 after")
        XCTAssertTrue(fullBlock.html.contains("<strong>bold</strong>"))
        XCTAssertTrue(fullBlock.html.contains("data:image/png;base64," + png))
        let start = mixedRaw.range(of: "bold").location, end = NSMaxRange(mixedRaw.range(of: tag))
        let partialBlock = try XCTUnwrap(MarkdownClipboardCopyService.project(mixed, selection: NSRange(location: start, length: end - start), includeImages: true))
        XCTAssertEqual(partialBlock.text, "bold 中文")
        XCTAssertTrue(partialBlock.html.contains("<strong>bold</strong>"))
        XCTAssertFalse(partialBlock.html.contains("before"))
        XCTAssertFalse(partialBlock.html.contains("after"))
        for (block, selected) in [("<div>\(tag) text</div>", " text"), ("<div>text \(tag)</div>", "text ")] {
            let raw = block as NSString
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(block, selection: raw.range(of: selected), includeImages: true))
            XCTAssertEqual(copy.text, selected)
            XCTAssertFalse(copy.html.contains("<img"))
            XCTAssertFalse(copy.html.contains("data:image"))
        }
        let entityBlock = "<div>left &amp; right</div>"
        let entityRaw = entityBlock as NSString
        let entity = entityRaw.range(of: "&amp;")
        let entityCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(entityBlock, selection: entity))
        XCTAssertEqual(entityCopy.text, "&")
        XCTAssertTrue(entityCopy.html.contains("&amp;"))
        XCTAssertNil(MarkdownClipboardCopyService.project(entityBlock, selection: NSRange(location: entity.location + 1, length: entity.length - 2)))
        let collapsed = "<div>a <strong> b</strong></div>"
        let collapsedRaw = collapsed as NSString
        let collapsedCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(collapsed, selection: NSRange(location: 0, length: collapsedRaw.length)))
        XCTAssertEqual(collapsedCopy.text, "a b")
        let boundary = collapsedRaw.range(of: " <strong> ")
        XCTAssertEqual(MarkdownClipboardCopyService.project(collapsed, selection: boundary)?.text, " ")
        let spaces = "<div>中   x</div>"
        let spacesRaw = spaces as NSString
        let spacesCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(spaces, selection: NSRange(location: 0, length: spacesRaw.length)))
        XCTAssertEqual(spacesCopy.text, "中 x")
        XCTAssertTrue(spacesCopy.html.contains("中 x"))
        for preserve in [true, false] {
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(spaces, selection: NSRange(location: 0, length: spacesRaw.length),
                                                                           syntax: .init(preserveEditingWhitespace: preserve)))
            XCTAssertEqual(copy.text, "中 x")
            XCTAssertTrue(copy.html.contains("中 x"))
        }
        let part = try XCTUnwrap(MarkdownClipboardCopyService.project(spaces, selection: spacesRaw.range(of: "  ")))
        XCTAssertEqual(part.text, " ")
        let combiningSpaces = "<div>a  \u{301}b</div>"
        let combiningCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(combiningSpaces, selection: NSRange(location: 0, length: (combiningSpaces as NSString).length)))
        XCTAssertTrue(combiningCopy.text.utf16.elementsEqual("a \u{301}b".utf16))
        let entitySpace = "<div>a&#32;<strong> b</strong></div>"
        XCTAssertEqual(MarkdownClipboardCopyService.project(entitySpace, selection: NSRange(location: 0, length: (entitySpace as NSString).length))?.text, "a b")
        for entity in ["&#9;", "&#10;", "&#13;"] {
            let source = "<div>a" + entity + "<strong> b</strong></div>"
            let raw = source as NSString, range = raw.range(of: entity)
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length))?.text, "a b")
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: range)?.text, " ")
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: range.location + 1, length: range.length - 1)))
        }
        for entity in ["&#32;", "&#9;", "&#10;", "&#13;"] {
            let source = "<div>" + entity + "中" + entity + "</div>"
            let raw = source as NSString, first = raw.range(of: entity)
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length))?.text, "中")
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: first.location + 1, length: first.length - 1)))
            let mixed = "<div>\r\n" + entity + "中" + entity + "\r\n</div>"
            XCTAssertEqual(MarkdownClipboardCopyService.project(mixed, selection: NSRange(location: 0, length: (mixed as NSString).length))?.text, "中")
        }
        let edge = "<div>  中 text  </div>"
        let edgeRaw = edge as NSString
        XCTAssertEqual(MarkdownClipboardCopyService.project(edge, selection: NSRange(location: 0, length: edgeRaw.length))?.text, "中 text")
        XCTAssertEqual(MarkdownClipboardCopyService.project(edge, selection: edgeRaw.range(of: " 中"))?.text, "中")
        XCTAssertNil(MarkdownClipboardCopyService.project(edge, selection: edgeRaw.range(of: "  ")))
        for newline in ["\n", "\r", "\r\n"] {
            let edgeLines = "<div>" + newline + "  中  " + newline + "</div>"
            let edgeLinesRaw = edgeLines as NSString
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(edgeLines, selection: NSRange(location: 0, length: edgeLinesRaw.length)))
            XCTAssertEqual(copy.text, "中")
            XCTAssertFalse(copy.html.contains("<br>"))
            let styled = "<div>" + newline + "<strong>中</strong>" + newline + "</div>"
            let styledRaw = styled as NSString
            let styledCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(styled, selection: NSRange(location: 0, length: styledRaw.length)))
            XCTAssertEqual(styledCopy.text, "中")
            XCTAssertTrue(styledCopy.html.contains("<strong>中</strong>"))
        }
        for newline in ["\n", "\r", "\r\n"] {
            let multiline = "<div>中文" + newline + "<strong> text</strong></div>"
            let multilineRaw = multiline as NSString
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(multiline, selection: NSRange(location: 0, length: multilineRaw.length)))
            XCTAssertEqual(copy.text, "中文 text")
            XCTAssertFalse(copy.html.contains("<br>"))
            XCTAssertEqual(MarkdownClipboardCopyService.project(multiline, selection: multilineRaw.range(of: newline))?.text, " ")
            if newline == "\r\n" {
                let range = multilineRaw.range(of: newline)
                XCTAssertNil(MarkdownClipboardCopyService.project(multiline, selection: NSRange(location: range.location, length: 1)))
            }
        }
    }

    func testHTMLImageCopyPreservesLocalSVGSelectors() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><view id='é'/><view id='e\u{301}'/></svg>".utf8)
        try svg.write(to: folder.appendingPathComponent("views.svg"))
        let source = "before <img src='views.svg#é'> <img src='views.svg#e\u{301}'> after"
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length),
            includeImages: true, documentURL: folder.appendingPathComponent("note.md")))
        let uri = "data:image/svg+xml;base64," + svg.base64EncodedString()
        XCTAssertTrue(result.html.contains(uri + MarkdownImageUploadService.fragmentSuffix("views.svg#é")))
        XCTAssertTrue(result.html.contains(uri + MarkdownImageUploadService.fragmentSuffix("views.svg#e\u{301}")))
    }

    func testCopyUsesConfirmedEmojiAndKeepsSourceSelection() throws {
        let source = "中😀 **:smile:** \\:smile: `:smile:`"
        let raw = source as NSString
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
        XCTAssertEqual(fragment.text, "中😀 😄 :smile: :smile:")
        XCTAssertTrue(fragment.html.contains("<strong>😄</strong>"))
        XCTAssertTrue(fragment.html.contains("<code>:smile:</code>"))
        let token = raw.range(of: ":smile:")
        XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: token)?.text, "😄")
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: token.location + 1, length: token.length - 2)))
        let table = "| H |\n|---|\n| 中😀 :smile: |"
        let cell = (table as NSString).range(of: "中😀 :smile:")
        XCTAssertEqual(MarkdownClipboardCopyService.project(table, selection: cell)?.text, "中😀 😄")
    }

    func testSelectedRemoteImagesResolveOnceWithoutChangingOtherContent() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClipboardCopyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ClipboardCopyURLProtocol.handler = nil }
        let url = "https://8.8.8.8/a.png?x=1&y=2"
        let source = "![one](<\(url)>) ![two](<\(url)>)\n\n![other](https://example.org/other.png)"
        let selection = (source as NSString).range(of: "![one](<\(url)>) ![two](<\(url)>)")
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection, includeImages: true, allowRemoteImages: true))
        let lock = NSLock()
        var requests = 0
        ClipboardCopyURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, url)
            lock.lock(); requests += 1; lock.unlock()
            return png
        }
        let resolved = try await MarkdownClipboardCopyService.resolveRemoteImages(fragment, session: session)
        XCTAssertEqual(lock.withLock { requests }, 1)
        XCTAssertEqual(resolved.html.components(separatedBy: "data:image/png;base64,").count - 1, 2)
        XCTAssertFalse(resolved.html.contains("example.org"))
        XCTAssertEqual(resolved.text, "one two")
        XCTAssertTrue(resolved.remoteImages.isEmpty)
        XCTAssertEqual(source, "![one](<\(url)>) ![two](<\(url)>)\n\n![other](https://example.org/other.png)")
        let htmlSource = "before <img src='\(url)' alt='中文' width='40'> after"
        let htmlTag = (htmlSource as NSString).range(of: "<img src='\(url)' alt='中文' width='40'>")
        let htmlFragment = try XCTUnwrap(MarkdownClipboardCopyService.project(htmlSource, selection: htmlTag, includeImages: true, allowRemoteImages: true))
        let htmlResolved = try await MarkdownClipboardCopyService.resolveRemoteImages(htmlFragment, session: session)
        XCTAssertTrue(htmlResolved.html.contains("data:image/png;base64," + png.base64EncodedString()))
        XCTAssertTrue(htmlResolved.html.contains("width:40.0px"))
        XCTAssertEqual(htmlResolved.text, "中文")
        let nestedHTML = "<div><span style='color:red'><strong><img src='\(url)' alt='中文'></strong></span> <img src='https://example.org/other.png'></div>" as NSString
        let nestedTag = nestedHTML.range(of: "<img src='\(url)' alt='中文'>")
        let nestedCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(nestedHTML as String, selection: nestedTag, includeImages: true, allowRemoteImages: true))
        let nestedHTMLResolved = try await MarkdownClipboardCopyService.resolveRemoteImages(nestedCopy, session: session)
        XCTAssertTrue(nestedHTMLResolved.html.contains("<strong><img src=\"data:image/png;base64,"))
        XCTAssertFalse(nestedHTMLResolved.html.contains("example.org"))
        XCTAssertEqual(nestedHTMLResolved.text, "中文")
        let blockHTML = "<div>before<p><img src='\(url)' alt='中文'> text <img src='https://example.org/other.png' alt='other'></p>after</div>" as NSString
        let blockTag = blockHTML.range(of: "<img src='\(url)' alt='中文'>")
        let spaceSource = "<div><p><img src='https://example.org/other.png' alt='other'> text</p></div>" as NSString
        let space = NSRange(location: spaceSource.range(of: "> text").location + 1, length: 1)
        let spaceCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(spaceSource as String, selection: space, includeImages: true, allowRemoteImages: true))
        XCTAssertEqual(spaceCopy.text, " ")
        XCTAssertTrue(spaceCopy.remoteImages.isEmpty)
        XCTAssertFalse(spaceCopy.html.contains("<img"))
        let blockPending = try XCTUnwrap(MarkdownClipboardCopyService.project(blockHTML as String, selection: blockTag, includeImages: true, allowRemoteImages: true))
        let blockResolved = try await MarkdownClipboardCopyService.resolveRemoteImages(blockPending, session: session)
        XCTAssertTrue(blockResolved.html.contains("data:image/png;base64," + png.base64EncodedString()))
        XCTAssertFalse(blockResolved.html.contains("example.org"))
        XCTAssertEqual(blockResolved.text, "中文")
        let nested = "> - [![alt](<\(url)>) ](https://example.org/link)"
        let nestedFragment = try XCTUnwrap(MarkdownClipboardCopyService.project(nested,
            selection: NSRange(location: 0, length: (nested as NSString).length), includeImages: true, allowRemoteImages: true))
        let nestedImage = try XCTUnwrap(nestedFragment.remoteImages.first)
        XCTAssertEqual((nestedFragment.html as NSString).substring(with: nestedImage.range), "https://8.8.8.8/a.png?x=1&amp;y=2")
        let nestedResolved = try await MarkdownClipboardCopyService.resolveRemoteImages(nestedFragment, session: session)
        XCTAssertTrue(nestedResolved.html.contains("<blockquote><ul>"))
        XCTAssertTrue(nestedResolved.html.contains("<a href=\"https://example.org/link\"><img src=\"data:image/png;base64,"))
    }

    func testCopyKeepsSelectionsAfterEmailAutolinks() throws {
        let source = "中😀 a@example.com after b@example.com **end**"
        let raw = source as NSString
        for value in ["a@example.com", "after", "b@example.com", "end"] {
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: value)))
            XCTAssertEqual(fragment.text, value)
            if value.contains("@") {
                XCTAssertEqual(fragment.html, "<a href=\"mailto:\(value)\">\(value)</a>")
                XCTAssertTrue(fragment.runs.contains { $0.link == "mailto:" + value })
            }
        }
        let encoded = "a&commat;example.com tail"
        let encodedRange = (encoded as NSString).range(of: "a&commat;example.com")
        let decoded = try XCTUnwrap(MarkdownClipboardCopyService.project(encoded, selection: encodedRange))
        XCTAssertEqual(decoded.text, "a@example.com")
        XCTAssertEqual(decoded.html, "<a href=\"mailto:a@example.com\">a@example.com</a>")
    }

    func testThematicBreakCopiesOnlyWhenFullySelected() throws {
        for marker in ["---", "* * *", "___"] {
            let source = "中文😀\r\n\r\n" + marker + "\r\n\r\nafter"
            let raw = source as NSString
            let range = raw.range(of: marker)
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: range))
            XCTAssertEqual(result.text, "---")
            XCTAssertEqual(result.html, "<hr>")
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: range.location, length: 1)))
        }
    }

    func testPaddedInlineCodeCopiesContentWithoutDelimiters() throws {
        let source = "before `` `中😀` `` after"
        let raw = source as NSString
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "`` `中😀` ``")))
        XCTAssertEqual(whole.text, "`中😀`")
        XCTAssertEqual(whole.html, "<code>`中😀`</code>")
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "中😀")))
        XCTAssertEqual(partial.text, "中😀")
        XCTAssertEqual(partial.html, "<code>中😀</code>")
    }

    func testInlineCodeLineBreakUsesCmarkTextAndExactSelection() throws {
        for newline in ["\n", "\r\n"] {
            let source = "before `中😀" + newline + "code` after"
            let raw = source as NSString
            let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "`中😀" + newline + "code`")))
            XCTAssertEqual(whole.text, "中😀 code")
            XCTAssertEqual(whole.html, "<code>中😀 code</code>")
            let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "😀" + newline + "co")))
            XCTAssertEqual(partial.text, "😀 co")
            if newline == "\r\n" {
                let breakRange = raw.range(of: newline)
                XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: breakRange.location, length: 1)))
            }
        }
    }

    func testWholeSmartTextCopiesRenderedPunctuation() throws {
        let source = "\"hello\" -- end"
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source,
            selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertEqual(result.text, "“hello” – end")
        XCTAssertEqual(result.html, "“hello” – end")
        let raw = source as NSString
        let word = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "ell")))
        XCTAssertEqual(word.text, "ell")
        let openingQuote = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: 1)))
        XCTAssertEqual(openingQuote.text, "“")
        let dash = raw.range(of: "--")
        XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: dash)?.text, "–")
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: dash.location, length: 1)))
        let more = "中文😀 'word' --- end..."
        let moreRaw = more as NSString
        XCTAssertEqual(MarkdownClipboardCopyService.project(more, selection: moreRaw.range(of: "---"))?.text, "—")
        XCTAssertEqual(MarkdownClipboardCopyService.project(more, selection: moreRaw.range(of: "..."))?.text, "…")
        XCTAssertEqual(MarkdownClipboardCopyService.project(more, selection: moreRaw.range(of: "word"))?.text, "word")
    }

    func testEmbeddedImageScanCanBeCancelled() {
        XCTAssertThrowsError(try MarkdownClipboardCopyService.embeddedImages(in: "![x](data:image/png;base64,AA==)", isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testConfirmedHighlightAndScriptsCopyWithoutMarkers() throws {
        let source = "A ==中😀== ^2^ ~3~ ~~gone~~ Z"
        let ns = source as NSString
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: ns.length)))
        XCTAssertEqual(result.text, "A 中😀 2 3 gone Z")
        XCTAssertEqual(result.html, "A <mark>中😀</mark> <sup>2</sup> <sub>3</sub> <del>gone</del> Z")
        XCTAssertTrue(result.runs.contains { $0.highlight && (result.text as NSString).substring(with: $0.range) == "中😀" })
        XCTAssertTrue(result.runs.contains { $0.script == 1 && (result.text as NSString).substring(with: $0.range) == "2" })
        XCTAssertTrue(result.runs.contains { $0.script == -1 && (result.text as NSString).substring(with: $0.range) == "3" })
        let part = ns.range(of: "😀")
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: part))
        XCTAssertEqual(partial.text, "😀")
        XCTAssertEqual(partial.html, "<mark>😀</mark>")
        XCTAssertTrue(partial.runs.first?.highlight == true)
        let ambiguous = "~==x==~"
        let unchanged = try XCTUnwrap(MarkdownClipboardCopyService.project(ambiguous, selection: NSRange(location: 0, length: (ambiguous as NSString).length)))
        XCTAssertEqual(unchanged.html, "<del>==x==</del>")
    }

    func testConfirmedUnderlineCopiesFullAndPartialText() throws {
        let source = "before <u>中😀text</u> after"
        let ns = source as NSString
        let whole = ns.range(of: "<u>中😀text</u>")
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: whole))
        XCTAssertEqual(result.text, "中😀text")
        XCTAssertEqual(result.html, "<u>中😀text</u>")
        XCTAssertTrue(result.runs.first?.underline == true)
        let partial = ns.range(of: "😀te")
        let clipped = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: partial))
        XCTAssertEqual(clipped.text, "😀te")
        XCTAssertEqual(clipped.html, "<u>😀te</u>")
        XCTAssertEqual(clipped.runs.first?.range, NSRange(location: 0, length: 4))
        XCTAssertTrue(clipped.runs.first?.underline == true)
        let nested = "<u><u>x</u></u>"
        XCTAssertEqual(MarkdownClipboardCopyService.project(nested, selection: NSRange(location: 0, length: (nested as NSString).length))?.html, "<u>x</u>")
    }

    func testExplicitHTMLCanCopyRemoteImageWithoutFetchingIt() throws {
        let source = "![中😀](https://example.com/a.png?x=1&y=2 \"caption\")"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: selection, includeImages: true))
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection,
            includeImages: true, allowRemoteImages: true))
        XCTAssertEqual(result.text, "中😀")
        XCTAssertEqual(result.html, "<img src=\"https://example.com/a.png?x=1&amp;y=2\" alt=\"中😀\" title=\"caption\">")
        let linked = "[![x](https://example.com/a.png)](https://example.com/target)"
        let linkedResult = try XCTUnwrap(MarkdownClipboardCopyService.project(linked,
            selection: NSRange(location: 0, length: (linked as NSString).length), includeImages: true, allowRemoteImages: true))
        XCTAssertEqual(linkedResult.html, "<a href=\"https://example.com/target\"><img src=\"https://example.com/a.png\" alt=\"x\"></a>")
        let unsafeSource = "[![x](https://example.com/a.png)](javascript:evil)"
        XCTAssertNil(MarkdownClipboardCopyService.project(unsafeSource,
            selection: NSRange(location: 0, length: (unsafeSource as NSString).length), includeImages: true, allowRemoteImages: true))
    }
    func testEmbeddedImagesPreserveBytesAndReplaceOnlyConfirmedAddresses() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let dataURI = "data:image/png;base64," + png.base64EncodedString()
        let source = "😀 ![one](<\(dataURI)> 'title')\r\n![two](<\(dataURI)>) tail"
        let images = try MarkdownClipboardCopyService.embeddedImages(in: source)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images.map(\.data), [png, png])
        XCTAssertEqual(images.map(\.mime), ["image/png", "image/png"])
        let urls = try ["images/a.png", "images/b%20%E4%B8%AD.png"].map { try XCTUnwrap(URL(string: $0)) }
        let result = try MarkdownClipboardCopyService.replacingEmbeddedImages(in: source, images: images, addresses: urls)
        XCTAssertEqual(result, "😀 ![one](<images/a.png> 'title')\r\n![two](<images/b%20%E4%B8%AD.png>) tail")
        XCTAssertThrowsError(try MarkdownClipboardCopyService.embeddedImages(in: "![x](data:image/png;base64,YWJj)"))
        XCTAssertThrowsError(try MarkdownClipboardCopyService.embeddedImages(in: "![x](data:image/jpeg;base64,\(png.base64EncodedString()))"))
        XCTAssertThrowsError(try MarkdownClipboardCopyService.embeddedImages(in: "![x](https://example.com/x.png)"))
        XCTAssertThrowsError(try MarkdownClipboardCopyService.replacingEmbeddedImages(in: source, images: images, addresses: [urls[0]]))
    }

    func testEmbeddedImageCopyProjectsAltAndValidatedHTML() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let uri = "data:image/png;base64," + png
        let source = "before ![中😀 **alt**](<\(uri)>) after"
        let raw = source as NSString
        let range = raw.range(of: "![中😀 **alt**](<\(uri)>)")
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: range))
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: range, includeImages: true))
        XCTAssertEqual(fragment.text, "中😀 alt")
        XCTAssertEqual(fragment.html, "<img src=\"\(uri)\" alt=\"中😀 alt\">")
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "alt"), includeImages: true))
        let broken = "![x](data:image/png;base64,YWJj)"
        XCTAssertNil(MarkdownClipboardCopyService.project(broken, selection: NSRange(location: 0, length: (broken as NSString).length), includeImages: true))
        let outside = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "before"), includeImages: true))
        XCTAssertEqual(outside.text, "before")
        let linked = "[![x](<\(uri)> 'caption &amp; text')](https://example.com)"
        let full = NSRange(location: 0, length: (linked as NSString).length)
        let linkedResult = try XCTUnwrap(MarkdownClipboardCopyService.project(linked, selection: full, includeImages: true))
        XCTAssertEqual(linkedResult.html, "<a href=\"https://example.com\"><img src=\"\(uri)\" alt=\"x\" title=\"caption &amp; text\"></a>")
        XCTAssertEqual(linkedResult.imageLinks, ["https://example.com"])
        let partial = (linked as NSString).range(of: "x")
        XCTAssertNil(MarkdownClipboardCopyService.project(linked, selection: partial, includeImages: true))
    }

    func testLocalImageCopyUsesDocumentBaseAndDoesNotModifyFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let file = root.appendingPathComponent("中文 图.png")
        try png.write(to: file)
        let source = "![描述](%E4%B8%AD%E6%96%87%20%E5%9B%BE.png)"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection, includeImages: true,
            documentURL: root.appendingPathComponent("document.md")))
        XCTAssertEqual(fragment.text, "描述")
        XCTAssertEqual(fragment.html, "<img src=\"data:image/png;base64,\(png.base64EncodedString())\" alt=\"描述\">")
        XCTAssertEqual(try Data(contentsOf: file), png)
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: selection, includeImages: true))
        try Data("not an image".utf8).write(to: file)
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: selection, includeImages: true,
            documentURL: root.appendingPathComponent("document.md")))
        let remote = "![x](https://example.com/image.png)"
        XCTAssertNil(MarkdownClipboardCopyService.project(remote, selection: NSRange(location: 0, length: (remote as NSString).length), includeImages: true,
            documentURL: root.appendingPathComponent("document.md")))
    }

    @MainActor
    func testEmbeddedImageRTFRoundTripContainsImage() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let source = "![x](<data:image/png;base64,\(png)>)"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source,
            selection: NSRange(location: 0, length: (source as NSString).length), includeImages: true))
        let generated = await MarkdownClipboardCopyService.structuralRTF(fragment)
        let data = try XCTUnwrap(generated)
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var images: [NSImage] = []
        restored.enumerateAttribute(.attachment, in: NSRange(location: 0, length: restored.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) { images.append(image) }
        }
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        XCTAssertEqual(bitmap.pixelsWide, 1)
        XCTAssertEqual(bitmap.pixelsHigh, 1)
        let expectedBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(Data(base64Encoded: png))))
        let expected = try XCTUnwrap(expectedBitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        let actual = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.05)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.05)
        let linked = "[\(source)](https://example.com/image)"
        let linkedFragment = try XCTUnwrap(MarkdownClipboardCopyService.project(linked,
            selection: NSRange(location: 0, length: (linked as NSString).length), includeImages: true))
        let linkedGenerated = await MarkdownClipboardCopyService.structuralRTF(linkedFragment)
        let linkedRTF = try XCTUnwrap(linkedGenerated)
        let linkedText = try NSAttributedString(data: linkedRTF, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var linkedAddress: String?
        linkedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: linkedText.length)) { value, range, _ in
            guard value is NSTextAttachment else { return }
            let link = linkedText.attribute(.link, at: range.location, effectiveRange: nil)
            linkedAddress = (link as? URL)?.absoluteString ?? (link as? String)
        }
        XCTAssertEqual(linkedAddress, "https://example.com/image")
        let combined = source + " " + linked
        let combinedFragment = try XCTUnwrap(MarkdownClipboardCopyService.project(combined,
            selection: NSRange(location: 0, length: (combined as NSString).length), includeImages: true))
        XCTAssertEqual(combinedFragment.imageLinks, [nil, "https://example.com/image"])
        let combinedGenerated = await MarkdownClipboardCopyService.structuralRTF(combinedFragment)
        let combinedRTF = try XCTUnwrap(combinedGenerated)
        let combinedText = try NSAttributedString(data: combinedRTF, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var addresses: [String?] = []
        combinedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: combinedText.length)) { value, range, _ in
            guard value is NSTextAttachment else { return }
            let link = combinedText.attribute(.link, at: range.location, effectiveRange: nil)
            addresses.append((link as? URL)?.absoluteString ?? (link as? String))
        }
        XCTAssertEqual(addresses, [nil, "https://example.com/image"])
    }

    func testBundledPandocHTMLDataURIReachesEmbeddedImagePreparation() throws {
        _ = try XCTUnwrap(PandocExportService.findPandoc())
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let input = "<p>before <img alt=\"x\" src=\"data:image/png;base64,\(encoded)\"> after</p>"
        let result = try ClipboardMarkdownConversionService.convert(Data(input.utf8), format: .html)
        let images = try MarkdownClipboardCopyService.embeddedImages(in: result.markdown)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.data, Data(base64Encoded: encoded))
        XCTAssertEqual(images.first?.mime, "image/png")
    }

    func testWholeHeadingKeepsHTMLAndInlineText() throws {
        let empty = try XCTUnwrap(MarkdownClipboardCopyService.project("#", selection: NSRange(location: 0, length: 1)))
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.html, "<h1></h1>")
        for source in ["## 中文😀 **bold**", "中文😀 **bold**\r\n---"] {
            let raw = source as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
            XCTAssertEqual(result.text, "中文😀 bold")
            XCTAssertEqual(result.html, "<h2>中文😀 <strong>bold</strong></h2>")
            let range = (result.text as NSString).range(of: "bold")
            XCTAssertTrue(result.runs.contains { $0.range == range && $0.bold })
            let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "bold")))
            XCTAssertEqual(partial.html, "<strong>bold</strong>")
        }
    }

    func testQuoteHeadingKeepsStructureAndInlineStyle() throws {
        for newline in ["\n", "\r\n"] {
            let source = "> ## 中文😀 **bold**" + newline + newline + "after"
            let selected = (source as NSString).range(of: "> ## 中文😀 **bold**")
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selected))
            XCTAssertEqual(result.text, "> 中文😀 bold")
            XCTAssertEqual(result.html, "<blockquote><h2>中文😀 <strong>bold</strong></h2></blockquote>")
            let bold = (result.text as NSString).range(of: "bold")
            XCTAssertTrue(result.runs.contains { $0.range == bold && $0.bold })
        }
    }

    @MainActor
    func testStructuralRTFRefusesMixedQuoteAndKeepsNestedQuote() async throws {
        let source = "> quote\n\n- one\n- two"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertTrue(fragment.html.contains("<blockquote>"))
        XCTAssertTrue(fragment.html.contains("<ul>"))
        let data = await MarkdownClipboardCopyService.structuralRTF(fragment)
        XCTAssertNil(data)
        let nestedSource = "> outer\n>\n> > inner"
        let nested = try XCTUnwrap(MarkdownClipboardCopyService.project(nestedSource, selection: NSRange(location: 0, length: (nestedSource as NSString).length)))
        let nestedResult = await MarkdownClipboardCopyService.structuralRTF(nested)
        let nestedData = try XCTUnwrap(nestedResult)
        let restored = try NSAttributedString(data: nestedData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let text = restored.string as NSString
        let outer = text.range(of: "outer"), inner = text.range(of: "inner")
        guard outer.location != NSNotFound, inner.location != NSNotFound else { return XCTFail("RTF lost quote text") }
        let outerStyle = try XCTUnwrap(restored.attribute(.paragraphStyle, at: outer.location, effectiveRange: nil) as? NSParagraphStyle)
        let innerStyle = try XCTUnwrap(restored.attribute(.paragraphStyle, at: inner.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(max(innerStyle.headIndent, innerStyle.firstLineHeadIndent), max(outerStyle.headIndent, outerStyle.firstLineHeadIndent))
    }

    @MainActor
    func testStructuralRTFKeepsQuoteAndNestedListTogether() async throws {
        let source = "> 中文😀 quote\n>\n> - one\n>   - **two**\n> - last"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        let generated = await MarkdownClipboardCopyService.structuralRTF(fragment)
        let data = try XCTUnwrap(generated)
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let text = restored.string as NSString
        let quote = text.range(of: "中文😀 quote"), nested = text.range(of: "two")
        XCTAssertNotEqual(quote.location, NSNotFound)
        XCTAssertNotEqual(nested.location, NSNotFound)
        if quote.location != NSNotFound, nested.location != NSNotFound {
            let quoteStyle = restored.attribute(.paragraphStyle, at: quote.location, effectiveRange: nil) as? NSParagraphStyle
            let listStyle = restored.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertTrue((quoteStyle?.headIndent ?? 0) > 0 || (quoteStyle?.firstLineHeadIndent ?? 0) > 0)
            XCTAssertEqual(listStyle?.textLists.count, 2)
        }
        let repeated = "> same\n>\n> - same"
        let repeatedFragment = try XCTUnwrap(MarkdownClipboardCopyService.project(repeated, selection: NSRange(location: 0, length: (repeated as NSString).length)))
        let repeatedGenerated = await MarkdownClipboardCopyService.structuralRTF(repeatedFragment)
        let repeatedData = try XCTUnwrap(repeatedGenerated)
        let repeatedText = try NSAttributedString(data: repeatedData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let string = repeatedText.string as NSString
        let first = string.range(of: "same")
        XCTAssertNotEqual(first.location, NSNotFound)
        guard first.location != NSNotFound else { return }
        let second = string.range(of: "same", options: [], range: NSRange(location: NSMaxRange(first), length: string.length - NSMaxRange(first)))
        XCTAssertNotEqual(second.location, NSNotFound)
        guard second.location != NSNotFound else { return }
        let firstStyle = repeatedText.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle
        let secondStyle = repeatedText.attribute(.paragraphStyle, at: second.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(firstStyle?.textLists.count, 0)
        XCTAssertTrue((firstStyle?.headIndent ?? 0) > 0 || (firstStyle?.firstLineHeadIndent ?? 0) > 0)
        XCTAssertEqual(secondStyle?.textLists.count, 1)
    }

    func testStructuralPartsFollowContentAndContainers() throws {
        let source = "> same\n>\n> - same\n>   - 中文😀"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        let content = fragment.structuralParts.filter { $0.kind == .text }
        XCTAssertEqual(content.map(\.text), ["same", "same", "中文😀"])
        XCTAssertEqual(content.map(\.quoteDepth), [1, 1, 1])
        XCTAssertEqual(content.map(\.listDepth), [0, 1, 2])
        let quotedLines = "> A\r\n> B"
        let quoteParts = try XCTUnwrap(MarkdownClipboardCopyService.project(quotedLines, selection: NSRange(location: 0, length: (quotedLines as NSString).length))).structuralParts
        XCTAssertEqual(quoteParts.map(\.kind), [.quoteStart, .text, .lineBreak, .text, .quoteEnd])
        XCTAssertEqual(quoteParts.filter { $0.kind == .text || $0.kind == .lineBreak }.map(\.text), ["A", "\n", "B"])
        XCTAssertTrue(MarkdownClipboardCopyService.exactStructuralText(quoteParts, matches: "\nA\nB\n"))
        XCTAssertFalse(MarkdownClipboardCopyService.exactStructuralText(quoteParts, matches: "A\nA"))
        let quoted = NSMutableAttributedString(string: "A\nB")
        let indented = NSMutableParagraphStyle()
        indented.headIndent = 12
        quoted.addAttribute(.paragraphStyle, value: indented, range: NSRange(location: 0, length: quoted.length))
        XCTAssertTrue(MarkdownClipboardCopyService.quoteIndentMatches(quoteParts, text: quoted))
        quoted.removeAttribute(.paragraphStyle, range: NSRange(location: 2, length: 1))
        XCTAssertFalse(MarkdownClipboardCopyService.quoteIndentMatches(quoteParts, text: quoted))
        let table = "| A | B |\n|---|---|\n| x | |"
        let cells = try XCTUnwrap(MarkdownClipboardCopyService.project(table, selection: NSRange(location: 0, length: (table as NSString).length)))
        let cellContent = cells.structuralParts.filter { $0.kind == .text }
        XCTAssertEqual(cellContent.map(\.text), ["A", "B", "x", ""])
        XCTAssertEqual(cellContent.map { $0.tableCell?.row }, [0, 0, 1, 1])
        XCTAssertEqual(cellContent.map { $0.tableCell?.column }, [0, 1, 0, 1])
        let list = "- one\n-\n- two"
        let items = try XCTUnwrap(MarkdownClipboardCopyService.project(list, selection: NSRange(location: 0, length: (list as NSString).length)))
        XCTAssertEqual(items.structuralParts.map(\.kind), [.listItemStart, .text, .listItemEnd, .listItemStart, .emptyListItem, .listItemEnd, .listItemStart, .text, .listItemEnd])
        let nested = "- \n  - inner"
        let nestedParts = try XCTUnwrap(MarkdownClipboardCopyService.project(nested, selection: NSRange(location: 0, length: (nested as NSString).length))).structuralParts
        XCTAssertEqual(nestedParts.map(\.kind), [.listItemStart, .listItemStart, .text, .listItemEnd, .listItemEnd])
        XCTAssertEqual(nestedParts.map(\.listDepth), [1, 2, 2, 2, 1])
        let tasks = "- [x] done\n- [ ] later"
        let taskParts = try XCTUnwrap(MarkdownClipboardCopyService.project(tasks, selection: NSRange(location: 0, length: (tasks as NSString).length))).structuralParts
        XCTAssertEqual(taskParts.filter { $0.kind == .taskMarker }.map(\.text), ["☑ ", "☐ "])
        let rule = "---"
        let ruleParts = try XCTUnwrap(MarkdownClipboardCopyService.project(rule, selection: NSRange(location: 0, length: (rule as NSString).length))).structuralParts
        XCTAssertEqual(ruleParts.map(\.kind), [.thematicBreak])
    }

    func testStructuralTextComparisonRequiresEveryPartInOrder() throws {
        let source = "# same **same** 中文😀"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertTrue(MarkdownClipboardCopyService.exactStructuralText(fragment.structuralParts, matches: "\nsame same 中文😀\n"))
        XCTAssertFalse(MarkdownClipboardCopyService.exactStructuralText(fragment.structuralParts, matches: "same 中文😀"))
        XCTAssertFalse(MarkdownClipboardCopyService.exactStructuralText(fragment.structuralParts, matches: "same 中文😀 same"))
    }

    @MainActor
    func testQuoteTableCopiesPlainAndHTML() async throws {
        let source = "> 中😀\r\n>\r\n> | A | B |\r\n> |---|---|\r\n> | x | y |"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertEqual(fragment.text, "> 中😀\n> \n> A\tB\n> x\ty")
        XCTAssertEqual(fragment.html, "<blockquote>中😀<br><br><table><tr><th>A</th><th>B</th></tr><tr><td>x</td><td>y</td></tr></table></blockquote>")
        let rtf = await MarkdownClipboardCopyService.structuralRTF(fragment)
        XCTAssertNil(rtf)
    }

    func testQuoteThematicBreakKeepsBothBlankLines() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["> 中😀", ">", "> ---", ">", "> after"].joined(separator: newline)
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
            XCTAssertEqual(fragment.text, "> 中😀\n> \n> ---\n> \n> after")
            XCTAssertEqual(fragment.html, "<blockquote>中😀<br><br><hr><br><br>after</blockquote>")
        }
    }

    func testWholeSingleLineQuoteKeepsStructureAndInlineStyle() throws {
        let source = "> 中文😀 **bold**\r\n\r\nnext"
        let raw = source as NSString
        let quote = raw.range(of: "> 中文😀 **bold**")
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: quote))
        XCTAssertEqual(fragment.text, "> 中文😀 bold")
        XCTAssertEqual(fragment.html, "<blockquote>中文😀 <strong>bold</strong></blockquote>")
        let bold = (fragment.text as NSString).range(of: "bold")
        XCTAssertTrue(fragment.runs.contains { $0.range == bold && $0.bold })
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "bold")))
        XCTAssertEqual(partial.text, "bold")
        XCTAssertEqual(partial.html, "<strong>bold</strong>")
        for newline in ["\n", "\r\n"] {
            let multiline = ["> first", "> 中文😀 **second**", ">", "> third"].joined(separator: newline)
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(multiline, selection: NSRange(location: 0, length: (multiline as NSString).length)))
            XCTAssertEqual(result.text, "> first\n> 中文😀 second\n> \n> third")
            XCTAssertEqual(result.html, "<blockquote>first<br>中文😀 <strong>second</strong><br><br>third</blockquote>")
            XCTAssertTrue(result.runs.contains { $0.bold && (result.text as NSString).substring(with: $0.range) == "second" })
        }
        let nested = "> outer\n>\n> - item\n> - next"
        let combined = try XCTUnwrap(MarkdownClipboardCopyService.project(nested, selection: NSRange(location: 0, length: (nested as NSString).length)))
        XCTAssertEqual(combined.text, "> outer\n> \n> • item\n> • next")
        XCTAssertEqual(combined.html, "<blockquote>outer<br><br><ul><li>item</li><li>next</li></ul></blockquote>")
        let nestedList = "> - 中文😀\r\n>   - **inner**\r\n> - next"
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(nestedList, selection: NSRange(location: 0, length: (nestedList as NSString).length)))
        XCTAssertEqual(result.text, "> • 中文😀\n>   • inner\n> • next")
        XCTAssertEqual(result.html, "<blockquote><ul><li>中文😀<ul><li><strong>inner</strong></li></ul></li><li>next</li></ul></blockquote>")
        XCTAssertTrue(result.runs.contains { $0.bold && (result.text as NSString).substring(with: $0.range) == "inner" })
    }

    func testNestedQuoteKeepsDepthAndUTF16Runs() throws {
        for newline in ["\n", "\r\n"] {
            let source = ["> outer", ">", "> > 中😀 **inner**", "> > line", ">", "> after"].joined(separator: newline)
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
            XCTAssertEqual(result.text, "> outer\n> \n> > 中😀 inner\n> > line\n> \n> after")
            XCTAssertEqual(result.html, "<blockquote>outer<br><br><blockquote>中😀 <strong>inner</strong><br>line</blockquote><br><br>after</blockquote>")
            XCTAssertTrue(result.runs.contains { $0.bold && (result.text as NSString).substring(with: $0.range) == "inner" })
        }
    }

    func testFencedCodeCopiesSourceMappedBody() throws {
        let source = "```swift\r\n中😀 <x>\r\nnext\r\n```"
        let raw = source as NSString
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
        XCTAssertEqual(whole.text, "中😀 <x>\nnext\n")
        XCTAssertEqual(whole.html, "<pre><code class=\"language-swift\">中😀 &lt;x&gt;\nnext\n</code></pre>")
        XCTAssertEqual(whole.runs.first?.range, NSRange(location: 0, length: (whole.text as NSString).length))
        XCTAssertEqual(whole.runs.first?.code, true)
        let first = raw.range(of: "😀"), last = raw.range(of: "next")
        let part = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: first.location, length: NSMaxRange(last) - first.location)))
        XCTAssertEqual(part.text, "😀 <x>\nnext")
        XCTAssertEqual(part.html, "<pre><code class=\"language-swift\">😀 &lt;x&gt;\nnext</code></pre>")
        let empty = "```\n```"
        let emptyResult = try XCTUnwrap(MarkdownClipboardCopyService.project(empty, selection: NSRange(location: 0, length: (empty as NSString).length)))
        XCTAssertEqual(emptyResult.text, "")
        XCTAssertEqual(emptyResult.html, "<pre><code></code></pre>")
        let escaped = "```x\"onmouseover=bad\nvalue\n```"
        let safe = try XCTUnwrap(MarkdownClipboardCopyService.project(escaped, selection: NSRange(location: 0, length: (escaped as NSString).length)))
        XCTAssertTrue(safe.html.contains("class=\"language-x&quot;onmouseover=bad\""))
        let unclosed = "```\nhello"
        let unclosedResult = try XCTUnwrap(MarkdownClipboardCopyService.project(unclosed, selection: NSRange(location: 0, length: (unclosed as NSString).length)))
        XCTAssertEqual(unclosedResult.text, "hello")
        XCTAssertEqual(unclosedResult.html, "<pre><code>hello</code></pre>")
    }

    @MainActor
    func testQuoteFencedCopyPreservesCodeWithoutContainerMarkers() async throws {
        let source = "> ```js\r\n> 中😀\r\n> next\r\n> ```"
        let raw = source as NSString
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
        XCTAssertEqual(whole.text, "> 中😀\n> next\n> ")
        XCTAssertEqual(whole.html, "<blockquote><pre><code class=\"language-js\">中😀\nnext\n</code></pre></blockquote>")
        let rich = await MarkdownClipboardCopyService.structuralRTF(whole)
        XCTAssertNil(rich)
        let first = raw.range(of: "😀"), last = raw.range(of: "next")
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: first.location, length: NSMaxRange(last) - first.location)))
        XCTAssertEqual(partial.text, "😀\nnext")
        XCTAssertEqual(partial.html, "<pre><code class=\"language-js\">😀\nnext</code></pre>")
        let list = "- ```js\r\n  中😀\r\n  ```"
        let listCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(list, selection: NSRange(location: 0, length: (list as NSString).length)))
        XCTAssertEqual(listCopy.text, "• 中😀\n")
        XCTAssertEqual(listCopy.html, "<ul><li><pre><code class=\"language-js\">中😀\n</code></pre></li></ul>")
        let listRTF = await MarkdownClipboardCopyService.structuralRTF(listCopy)
        XCTAssertNil(listRTF)
    }

    func testFenceCopyIncludesSpacesFromSelectedPartialTab() throws {
        let source = "  ```js\n\tlet x = 1\n  ```"
        let raw = source as NSString
        let block = try XCTUnwrap(MarkdownPresentationParser.parse(source).codeBlocks.first)
        XCTAssertEqual(block.bodyPadding, [2])
        XCTAssertEqual(block.literal, "  let x = 1\n")
        let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
        XCTAssertEqual(whole.text, "  let x = 1\n")
        let tab = raw.range(of: "\t")
        let selected = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: tab))
        XCTAssertEqual(selected.text, "  ")
        let quote = ">\t```js\n>\tlet x = 1\n>\t```"
        let quoteCopy = try XCTUnwrap(MarkdownClipboardCopyService.project(quote, selection: NSRange(location: 0, length: (quote as NSString).length)))
        XCTAssertEqual(quoteCopy.text, ">  let x = 1\n> ")
        XCTAssertEqual(quoteCopy.html, "<blockquote><pre><code class=\"language-js\"> let x = 1\n</code></pre></blockquote>")
    }

    @MainActor
    func testStructuralRTFRoundTripRetainsTableAndNestedList() async throws {
        for source in ["| A | B |\n|---|---|\n| one | **two** |", "- one\n  - two\n  - three\n- last"] {
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
            let rendered = await MarkdownClipboardCopyService.structuralRTF(fragment)
            let data = try XCTUnwrap(rendered)
            let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            var table = false, list = false
            attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                guard let style = value as? NSParagraphStyle else { return }
                table = table || style.textBlocks.contains { $0 is NSTextTableBlock }
                list = list || !style.textLists.isEmpty
            }
            if source.hasPrefix("|") { XCTAssertTrue(table); XCTAssertTrue(attributed.string.contains("two")) }
            else {
                XCTAssertTrue(list)
                let text = attributed.string as NSString
                for (word, expectedDepth) in [("one", 1), ("two", 2), ("three", 2), ("last", 1)] {
                    let range = text.range(of: word)
                    XCTAssertNotEqual(range.location, NSNotFound)
                    guard range.location != NSNotFound else { continue }
                    let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                    XCTAssertEqual(style?.textLists.count, expectedDepth, word)
                }
            }
        }
    }

    func testNestedListKeepsHierarchyAndReadableIndentation() throws {
        let source = "- one\n  - two\n  - **three**\n- last"
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertEqual(result.text, "• one\n  • two\n  • three\n• last")
        XCTAssertEqual(result.html, "<ul><li>one<ul><li>two</li><li><strong>three</strong></li></ul></li><li>last</li></ul>")
        let crlf = "- one\r\n  - 中文\r\n  - 😀\r\n- last"
        let raw = crlf as NSString
        let begin = raw.range(of: "中文").location, end = NSMaxRange(raw.range(of: "😀"))
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(crlf, selection: NSRange(location: begin, length: end - begin)))
        XCTAssertEqual(partial.text, "• 中文\n• 😀")
        XCTAssertEqual(partial.html, "<ul><li>中文</li><li>😀</li></ul>")
    }

    func testListAndTaskItemsKeepStructureAndState() throws {
        let source = "- one\n- **two**"
        let list = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertEqual(list.text, "• one\n• two")
        XCTAssertEqual(list.html, "<ul><li>one</li><li><strong>two</strong></li></ul>")
        let task = "- [ ] todo\n- [x] done"
        let tasks = try XCTUnwrap(MarkdownClipboardCopyService.project(task, selection: NSRange(location: 0, length: (task as NSString).length)))
        XCTAssertEqual(tasks.text, "• ☐ todo\n• ☑ done")
        XCTAssertEqual(tasks.html, "<ul><li><input type=\"checkbox\" disabled> todo</li><li><input type=\"checkbox\" disabled checked> done</li></ul>")
        let numbered = "3. first\n4. second\n5. third"
        let raw = numbered as NSString
        let range = NSRange(location: raw.range(of: "second").location, length: NSMaxRange(raw.range(of: "third")) - raw.range(of: "second").location)
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(numbered, selection: range))
        XCTAssertEqual(partial.text, "4. second\n5. third")
        XCTAssertEqual(partial.html, "<ol start=\"4\"><li>second</li><li>third</li></ol>")
    }

    func testShortRowOutsideSelectionDoesNotBlockHeaderCopy() throws {
        let source = "| A | B | C |\n|---|---|---|\n| x |"
        let raw = source as NSString
        let single = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "A")))
        XCTAssertEqual(single.text, "A")
        let first = raw.range(of: "A"), last = raw.range(of: "B")
        let multiple = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: first.location, length: NSMaxRange(last) - first.location)))
        XCTAssertEqual(multiple.text, "A\tB")
        XCTAssertEqual(multiple.html, "<table><tr><th>A</th><th>B</th></tr></table>")
    }

    func testEmptyTableStillHasHTMLStructure() throws {
        let source = "| |\n|---|"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertEqual(fragment.text, "")
        XCTAssertEqual(fragment.html, "<table><tr><th></th></tr></table>")
    }

    func testCompleteTableCopiesCellTextAndStructure() throws {
        let source = "| A | B |\r\n| --- | --- |\r\n| 中\\|文 | **bold** |"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        XCTAssertEqual(fragment.text, "A\tB\n中|文\tbold")
        XCTAssertEqual(fragment.html, "<table><tr><th>A</th><th>B</th></tr><tr><td>中|文</td><td><strong>bold</strong></td></tr></table>")
        let bold = try XCTUnwrap(fragment.runs.last)
        XCTAssertEqual((fragment.text as NSString).substring(with: bold.range), "bold")
        XCTAssertTrue(bold.bold)
    }

    func testPartialMultiCellTableKeepsStructure() throws {
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        let raw = source as NSString
        let start = raw.range(of: "one").location
        let end = NSMaxRange(raw.range(of: "two"))
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: start, length: end - start)))
        XCTAssertEqual(result.text, "one\ttwo")
        XCTAssertEqual(result.html, "<table><tr><td>one</td><td>two</td></tr></table>")
    }

    @MainActor
    func testTableCopyKeepsAlignmentForOriginalColumns() async throws {
        let source = "| A | B | C |\r\n| :--- | :---: | ---: |\r\n| one | two | 中文😀 |"
        let raw = source as NSString
        let complete = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
        XCTAssertEqual(complete.html, "<table><tr><th align=\"left\">A</th><th align=\"center\">B</th><th align=\"right\">C</th></tr><tr><td align=\"left\">one</td><td align=\"center\">two</td><td align=\"right\">中文😀</td></tr></table>")
        let start = raw.range(of: "two").location, end = NSMaxRange(raw.range(of: "中文😀"))
        let partial = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: start, length: end - start)))
        XCTAssertEqual(partial.html, "<table><tr><td align=\"center\">two</td><td align=\"right\">中文😀</td></tr></table>")
        let rtf = await MarkdownClipboardCopyService.structuralRTF(complete)
        XCTAssertNil(rtf)
    }

    func testEscapedPunctuationUsesVisibleTextAndUTF16Ranges() throws {
        let source = "中😀 \\*x\\*"
        let raw = source as NSString
        let selection = raw.range(of: "\\*x\\*")
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selection))
        XCTAssertEqual(result.text, "*x*")
        XCTAssertEqual(result.html, "*x*")
        XCTAssertEqual(result.runs.first?.range, NSRange(location: 0, length: 3))
        let table = "| A |\n| --- |\n| 中\\|😀 |"
        let tableRaw = table as NSString
        let cell = try XCTUnwrap(MarkdownClipboardCopyService.project(table, selection: tableRaw.range(of: "中\\|😀")))
        XCTAssertEqual(cell.text, "中|😀")
    }

    func testUnselectedUnsafeLinksAndMathDoNotBlockCopy() {
        let source = "before\n\n[bad](javascript:evil)\n\n$x$\n\nafter" as NSString
        let text = source as String
        XCTAssertEqual(MarkdownClipboardCopyService.project(text, selection: source.range(of: "before"))?.text, "before")
        XCTAssertEqual(MarkdownClipboardCopyService.project(text, selection: source.range(of: "after"))?.text, "after")
        XCTAssertNil(MarkdownClipboardCopyService.project(text, selection: source.range(of: "bad")))
        XCTAssertEqual(MarkdownClipboardCopyService.project(text, selection: source.range(of: "$x$"))?.mathImages.count, 1)
    }

    func testSelectedFootnotesAreNotSilentlyDropped() {
        let source = "Text[^1].\n\n[^1]: Note" as NSString
        let reference = MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "Text[^1]."))
        XCTAssertEqual(reference?.text, "Text1.")
        XCTAssertEqual(reference?.html, "Text<sup>1</sup>.")
        XCTAssertEqual(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "[^1]: Note"))?.text, "[1] Note")
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "[^1]:")))
        XCTAssertEqual(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: "Text"))?.text, "Text")
    }

    func testFootnotesFollowSourceOrderAndRejectPartialTokens() {
        let source = "[^one]: Note 😀\r\n\r\nText[^one] again[^one]." as NSString
        let whole = NSRange(location: 0, length: source.length)
        let result = MarkdownClipboardCopyService.project(source as String, selection: whole)
        XCTAssertEqual(result?.text, "[1] Note 😀\n\nText1 again1.")
        XCTAssertTrue(result?.html.contains("<sup>1</sup>") == true)
        let reference = source.range(of: "[^one]", options: .backwards)
        XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: reference.location + 1, length: 2)))
        let unused = "Text[^one]\n\n[^one]: Note\n\n[^unused]: Hidden" as NSString
        let withUnused = MarkdownClipboardCopyService.project(unused as String, selection: NSRange(location: 0, length: unused.length))
        XCTAssertEqual(withUnused?.text, "Text1\n\n[1] Note\n\n[^unused]: Hidden")
        XCTAssertTrue(withUnused?.html.contains("<code>\n\n[^unused]: Hidden</code>") == true)
    }

    func testUnrepresentedTopLevelSourceIsCopiedInPlaceAndEscaped() throws {
        let source = "---\ntitle: example\n---\n\nBefore\n\n[^unused]: <img src=x>\n\nAfter" as NSString
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source as String, selection: NSRange(location: 0, length: source.length)))
        XCTAssertEqual(result.text, source as String)
        XCTAssertTrue(result.html.contains("&lt;img src=x&gt;"))
        XCTAssertFalse(result.html.contains("<img src=x>"))
        let partial = source.range(of: "unused")
        XCTAssertEqual(MarkdownClipboardCopyService.project(source as String, selection: partial)?.text, "unused")
    }

    func testUnrepresentedQuoteAndListGapsStayInsideTheirContainers() throws {
        let quote = "> Before 😀\r\n>\r\n> [^unused]: <b>note</b>\r\n>\r\n> After" as NSString
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(quote as String, selection: NSRange(location: 0, length: quote.length)))
        XCTAssertTrue(result.text.contains("[^unused]: <b>note</b>"))
        XCTAssertTrue(result.html.hasPrefix("<blockquote>"))
        XCTAssertTrue(result.html.contains("&lt;b&gt;note&lt;/b&gt;"))
        XCTAssertFalse(result.html.contains("<b>note</b>"))
        XCTAssertEqual(MarkdownClipboardCopyService.project(quote as String, selection: quote.range(of: "unused"))?.text, "unused")
        XCTAssertLessThan(try XCTUnwrap(result.text.range(of: "Before")?.lowerBound), try XCTUnwrap(result.text.range(of: "[^unused]")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(result.text.range(of: "[^unused]")?.lowerBound), try XCTUnwrap(result.text.range(of: "After")?.lowerBound))
        let list = "- Before\n\n  [^unused]: Note\n\n  After" as NSString
        let listed = try XCTUnwrap(MarkdownClipboardCopyService.project(list as String, selection: NSRange(location: 0, length: list.length)))
        XCTAssertTrue(listed.html.hasPrefix("<ul><li>"))
        XCTAssertTrue(listed.html.contains("[^unused]: Note"))
        XCTAssertTrue(listed.html.hasSuffix("</li></ul>"))
        XCTAssertEqual(MarkdownClipboardCopyService.project(list as String, selection: list.range(of: "unused"))?.text, "unused")
        let first = "- [^unused]: hidden\n\n  item" as NSString
        let firstResult = try XCTUnwrap(MarkdownClipboardCopyService.project(first as String, selection: NSRange(location: 0, length: first.length)))
        XCTAssertTrue(firstResult.text.contains("[^unused]: hidden"))
        XCTAssertLessThan(try XCTUnwrap(firstResult.text.range(of: "[^unused]")?.lowerBound), try XCTUnwrap(firstResult.text.range(of: "item")?.lowerBound))
        for only in ["> [^unused]: only", "- [^unused]: only"] {
            let text = only as NSString
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(only, selection: NSRange(location: 0, length: text.length)))
            XCTAssertTrue(fragment.text.contains("[^unused]: only"))
            XCTAssertEqual(MarkdownClipboardCopyService.project(only, selection: text.range(of: "unused"))?.text, "unused")
        }
    }

    func testQuoteInsideListPreservesSourceOrderAndStructure() throws {
        for newline in ["\n", "\r\n"] {
            let source = "- outer" + newline + "  > quoted 😀" + newline + "  > second"
            let raw = source as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
            XCTAssertEqual(result.text, "• outer\n  > quoted 😀\n  > second")
            XCTAssertEqual(result.html, "<ul><li>outer<br><blockquote>quoted 😀<br>second</blockquote></li></ul>")
        }
        let nested = "- outer\n  > > nested\n  > > second"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(nested, selection: NSRange(location: 0, length: (nested as NSString).length)))
        XCTAssertEqual(fragment.text, "• outer\n  > > nested\n  > > second")
        XCTAssertTrue(fragment.html.contains("<blockquote><blockquote>"))
    }

    func testHeadingAndThematicBreakInsideList() throws {
        for newline in ["\n", "\r\n"] {
            let source = "- item" + newline + "  # 标题 😀" + newline + newline + "  ---"
            let raw = source as NSString
            let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
            XCTAssertEqual(result.text, "• item\n  标题 😀\n\n  ---")
            XCTAssertEqual(result.html, "<ul><li>item<br><h1>标题 😀</h1><br><br><hr></li></ul>")
        }
        let quoted = "> - item\n>   # Heading\n>\n>   ---"
        let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(quoted, selection: NSRange(location: 0, length: (quoted as NSString).length)))
        XCTAssertTrue(fragment.html.contains("<h1>Heading</h1>"))
        XCTAssertTrue(fragment.html.contains("<hr>"))
    }

    func testSelectedLeadingAndTrailingLineEndings() throws {
        for newline in ["\n", "\r\n"] {
            let source = "before" + newline + newline + "after"
            let raw = source as NSString
            let trailing = NSRange(location: 0, length: (("before" + newline) as NSString).length)
            let leading = NSRange(location: (("before" + newline) as NSString).length, length: ((newline + "after") as NSString).length)
            XCTAssertEqual(try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: trailing)).text, "before\n")
            XCTAssertEqual(try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: leading)).text, "\nafter")
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: raw.range(of: newline))?.text, "\n")
        }
    }

    func testPartialInlineSelectionUsesDocumentContext() throws {
        let source = "Before **bold** and `code` and [link][id].\n\n[id]: https://example.com"
        let raw = source as NSString
        let bold = raw.range(of: "ol")
        let result = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: bold))
        XCTAssertEqual(result.text, "ol")
        XCTAssertEqual(result.html, "<strong>ol</strong>")
        XCTAssertEqual(result.runs.first?.range, NSRange(location: 0, length: 2))
        XCTAssertTrue(result.runs.first?.bold == true)
        let code = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "od")))
        XCTAssertEqual(code.text, "od")
        XCTAssertEqual(code.html, "<code>od</code>")
        let link = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "ink")))
        XCTAssertEqual(link.html, "<a href=\"https://example.com\">ink</a>")
        XCTAssertEqual(link.runs.first?.link, "https://example.com")
    }

    func testUTF16AndUnsupportedTransformRefusal() throws {
        let source = "中文😀 **value** &amp; more"
        let raw = source as NSString
        let emoji = raw.range(of: "😀")
        XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: emoji)?.text, "😀")
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: emoji.location + 1, length: 1)))
        XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "&amp;"))?.text, "&")
        XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: NSRange(location: raw.range(of: "&amp;").location, length: 2)))
    }

    func testNamedAndNumericEntitiesUseCmarkSemantics() throws {
        let source = "中 &reg; and &#x1F600; and &NotEqualTilde;"
        let raw = source as NSString
        for (token, expected) in [("&reg;", "®"), ("&#x1F600;", "😀"), ("&NotEqualTilde;", "≂̸")] {
            let fragment = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: raw.range(of: token)))
            XCTAssertEqual(fragment.text, expected)
            XCTAssertEqual(fragment.runs.first?.range.length, (expected as NSString).length)
        }
    }
}
