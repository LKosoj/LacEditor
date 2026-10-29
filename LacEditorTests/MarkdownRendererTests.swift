import AppKit
import Foundation
import XCTest
@testable import LacEditor

private final class RemotePreviewURLProtocol: URLProtocol {
    static var requests: [String] = []
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url.path)
        let status = url.path.contains("missing") ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: Self.data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UnicodePreviewURLProtocol: URLProtocol {
    static let first = Data("<svg xmlns='http://www.w3.org/2000/svg'><rect fill='red'/></svg>".utf8)
    static let second = Data("<svg xmlns='http://www.w3.org/2000/svg'><rect fill='blue'/></svg>".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: url.absoluteString.contains("%C3%A9") ? Self.first : Self.second)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MarkdownRendererTests: XCTestCase {
    func testTwitterWidgetUsesSandboxAndStaticFallback() {
        let source = "before\n\n<blockquote class='twitter-tweet'><p lang='en' dir='ltr'>Sunsets 中文</p>&mdash; User <a href='https://twitter.com/Interior/status/463440424141459456?ref_src=twsrc%5Etfw'>May 5, 2014</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>\n\nafter"
        for plain in [false, true] {
            let live = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
            XCTAssertTrue(live.body.contains("sandbox=\"allow-scripts\""))
            XCTAssertTrue(live.body.contains("platform.twitter.com/embed/Tweet.html?id=463440424141459456&amp;dnt=true"))
            XCTAssertFalse(live.body.contains("widgets.js"))
            XCTAssertTrue(live.body.contains("before")); XCTAssertTrue(live.body.contains("after"))
        }
        let output = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true, staticWidgetFallback: true)
        XCTAssertTrue(output.body.contains("Sunsets 中文"))
        XCTAssertTrue(output.body.contains("https://twitter.com/Interior/status/463440424141459456?ref_src=twsrc%5Etfw"))
        XCTAssertFalse(output.body.contains("<iframe"))
        XCTAssertFalse(output.body.contains("platform.twitter.com"))
        XCTAssertFalse(output.body.contains("widgets.js"))
    }

    func testExportWhitespaceOptionChangesRenderedText() {
        let source = "中文   text"
        for preserve in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false,
                syntax: .init(preserveExportWhitespace: preserve), forExport: true)
            XCTAssertEqual(page.body.contains("white-space:break-spaces"), preserve)
            XCTAssertTrue(page.body.contains("中文")); XCTAssertTrue(page.body.contains("text"))
        }
    }

    func testPlainHTMLRawBlocksStayInertUntilExport() {
        let source = "before\n\n<div id='id' class='name' data-x='value'>中文</div>\n\n<script>window.RAW_SENTINEL=1</script>\n\n<style>.name{color:red}</style>\n\nafter"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                               forExport: true, preserveRawHTMLBlocks: true)
        XCTAssertEqual(page.rawHTMLBlocks.count, 3)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        XCTAssertFalse(page.body.contains("RAW_SENTINEL"))
        XCTAssertFalse(page.body.contains("color:red"))
        XCTAssertTrue(page.body.contains("before"))
        XCTAssertTrue(page.body.contains("after"))
        XCTAssertTrue(page.rawHTMLBlocks.allSatisfy { page.body.contains($0.marker) })
        XCTAssertTrue(page.rawHTMLBlocks.contains { $0.html.contains("RAW_SENTINEL") })
    }

    func testLooseHeadingRenderingUsesConfirmedSource() {
        for strict in [false, true] {
            let syntax = MarkdownSyntaxOptions(strictMode: strict)
            let plain = MarkdownRenderer.renderPage("###Header", darkMode: false, syntax: syntax)
            XCTAssertEqual(plain.body.contains("<h3"), !strict)
            let tabbed = MarkdownRenderer.renderPage("###Head\ttail", darkMode: false, syntax: syntax)
            XCTAssertFalse(tabbed.body.contains("<h3"))
        }
    }

    func testLooseListRenderingUsesConfirmedSource() throws {
        for strict in [false, true] {
            let syntax = MarkdownSyntaxOptions(strictMode: strict)
            let continuation = MarkdownRenderer.renderPage("1. aaa\n\n  bbb", darkMode: false, syntax: syntax).body
            let end = try XCTUnwrap(continuation.range(of: "</ol>"))
            let second = try XCTUnwrap(continuation.range(of: "<p>bbb</p>"))
            XCTAssertEqual(second.lowerBound < end.lowerBound, !strict)
            let nested = MarkdownRenderer.renderPage("10. aaa\n  1. ccc", darkMode: false, syntax: syntax).body
            XCTAssertEqual(nested.components(separatedBy: "<ol").count - 1, strict ? 1 : 2)
            XCTAssertEqual(nested.components(separatedBy: "<li").count - 1, 2)
            let yaml = "---\ntitle: 中文😀\n---\n\n10. aaa\n  1. ccc"
            let afterYAML = MarkdownRenderer.renderPage(yaml, darkMode: false, syntax: syntax).body
            XCTAssertEqual(afterYAML.components(separatedBy: "<ol").count - 1, strict ? 1 : 2)
        }
    }

    func testPlainHTMLKeepsInlineTagsAroundMarkdown() {
        let source = "Before <span class='keep' data-x='value'>**bold**</span> after"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                               forExport: true, preserveRawHTMLBlocks: true)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        XCTAssertEqual(page.rawHTMLBlocks.count, 2)
        XCTAssertTrue(page.rawHTMLBlocks[0].html.contains("class='keep' data-x='value'"))
        XCTAssertEqual(page.rawHTMLBlocks[1].html, "</span>")
        XCTAssertTrue(page.body.contains("<strong>bold</strong>"))
        XCTAssertFalse(page.body.contains("class='keep'"))
    }

    func testPlainHTMLKeepsInlineRawTextOutOfRender() {
        for source in ["Before <script>const a=\"**x**\";</script> after",
                       "Before <script>const a='==x== :smile:';</script> after",
                       "Before <textarea>**x** ==y== :smile:</textarea> after",
                       "Before <style>.x { color:red }</style> after"] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true, renderEmoji: true,
                                                   forExport: true, preserveRawHTMLBlocks: true)
            XCTAssertFalse(page.rawHTMLBlockProofFailed, source)
            XCTAssertEqual(page.rawHTMLBlocks.count, 1, source)
            let rawStart = source.range(of: "<")!
            let rawEnd = source.range(of: ">", options: .backwards)!.upperBound
            XCTAssertEqual(page.rawHTMLBlocks[0].html, String(source[rawStart.lowerBound..<rawEnd]), source)
            XCTAssertFalse(page.body.contains("const a="))
            XCTAssertFalse(page.body.contains("color:red"))
            XCTAssertFalse(page.body.contains("==x=="))
            XCTAssertFalse(page.body.contains(":smile:"))
            XCTAssertTrue(page.body.contains("Before ")); XCTAssertTrue(page.body.contains(" after"))
        }
        let earlyClose = "Before <script>let x='</script>'; after"
        let page = MarkdownRenderer.renderPage(earlyClose, darkMode: false, includeHTMLMedia: true,
                                               forExport: true, preserveRawHTMLBlocks: true)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        XCTAssertEqual(page.rawHTMLBlocks.first?.html, "<script>let x='</script>")
        XCTAssertTrue(page.body.contains(" after"))
        for tag in ["scripture", "stylesheet"] {
            let source = "Before <\(tag)>text</\(tag)> after"
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                                   forExport: true, preserveRawHTMLBlocks: true)
            XCTAssertFalse(page.rawHTMLBlockProofFailed, source)
            XCTAssertEqual(page.rawHTMLBlocks.map(\.html), ["<\(tag)>", "</\(tag)>"], source)
        }
    }

    func testPlainHTMLRawBlocksKeepContainerContentAndLineEndings() {
        for (first, continuation) in [("> ", "> "), ("- ", "  ")] {
            let source = first + "<div data-x='keep'>\r\n" + continuation + "中文 😀\r\n" + continuation + "</div>\r\n\r\nafter"
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                                   forExport: true, preserveRawHTMLBlocks: true)
            XCTAssertFalse(page.rawHTMLBlockProofFailed, source)
            XCTAssertEqual(page.rawHTMLBlocks.count, 1, source)
            XCTAssertTrue(page.rawHTMLBlocks.first?.html.utf16.elementsEqual("<div data-x='keep'>\r\n中文 😀\r\n</div>".utf16) == true, source)
            XCTAssertTrue(page.body.contains("after"), source)
        }
    }

    func testStandaloneSelfClosingMediaKeepsAdjacentBlocks() {
        for newline in ["\n", "\r\n"] {
            for (tag, element) in [("<audio src='https://example.invalid/a/b.wav' />", "audio"),
                                   ("<video src='https://example.invalid/a/b.mp4' width='120' height='80' />", "video")] {
                let source = "BEFORE😀" + newline + newline + tag + newline + newline + "AFTER"
                for plain in [false, true] {
                    let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
                    XCTAssertEqual(page.body.components(separatedBy: "<" + element).count - 1, 1, source)
                    XCTAssertTrue(page.body.contains("https://example.invalid/a/b."), source)
                    XCTAssertTrue(page.body.contains("BEFORE😀"), source)
                    XCTAssertTrue(page.body.contains("AFTER"), source)
                    XCTAssertTrue(page.body.contains("</" + element + ">"), source)
                }
            }
        }
    }
    func testStandaloneSVGExportsAsVectorImage() {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let source = "before\n\n" + svg + "\n\nafter"
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
            XCTAssertTrue(page.body.contains("data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()))
            XCTAssertTrue(page.body.contains("before"))
            XCTAssertTrue(page.body.contains("after"))
            XCTAssertFalse(page.body.contains("<svg"))
        }
        let multiline = "<svg width='40' height='20'>\n<rect width='40' height='20' fill='red'/>\n</svg>"
        let encoded = Data(("<svg xmlns=\"http://www.w3.org/2000/svg\"" + String(multiline.dropFirst(4))).utf8).base64EncodedString()
        for source in [multiline, "> <svg width='40' height='20'>\r\n> <rect width='40' height='20' fill='red'/>\r\n> </svg>"] {
            for plain in [false, true] {
                let page = MarkdownRenderer.renderPage(source + "\n\nafter", darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
                XCTAssertTrue(page.body.contains("data:image/svg+xml;base64," + encoded), source)
                XCTAssertTrue(page.body.contains("after"))
            }
        }
    }

    func testInlineSVGPreservesTextAndLinks() {
        let svg = "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let source = "前😀 " + svg + " [link](https://example.com) " + svg + " after"
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
            XCTAssertEqual(page.body.components(separatedBy: "data:image/svg+xml;base64,").count - 1, 2)
            XCTAssertTrue(page.body.contains("前😀"))
            XCTAssertTrue(page.body.contains("href=\"https://example.com\""))
            XCTAssertTrue(page.body.contains("after"))
        }
    }

    func testUnsupportedRubyKeepsProvenSource() {
        for ruby in ["<ruby>==漢==<rt>kan</rt></ruby>", "<ruby>漢<rt>^kan^</rt></ruby>",
                     "<ruby class='x'>漢<rt>kan</rt></ruby>"] {
            let source = "before " + ruby + " after"
            for plain in [false, true] {
                let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
                XCTAssertTrue(page.body.contains("&lt;ruby"), source)
                XCTAssertTrue(page.body.contains("&lt;/ruby&gt;"), source)
                XCTAssertTrue(page.body.contains("before"))
                XCTAssertTrue(page.body.contains("after"))
            }
        }
        let emoji = "before <ruby>:smile:<rt>smile</rt></ruby> after"
        let page = MarkdownRenderer.renderPage(emoji, darkMode: false, renderEmoji: true, resolveLocalImages: true)
        XCTAssertTrue(page.body.contains("&lt;ruby&gt;:smile:&lt;rt&gt;smile&lt;/rt&gt;&lt;/ruby&gt;"))
    }

    func testPlainDetailsRendersWithoutChangingSourceState() {
        let source = "before\n\n<details><summary>More &amp; 中文</summary>Body 😀</details>\n\nafter"
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
            XCTAssertTrue(page.body.contains("<details>"))
            XCTAssertTrue(page.body.contains("<summary>More &amp; 中文</summary>"))
            XCTAssertTrue(page.body.contains("Body 😀"))
            XCTAssertFalse(page.body.contains("<details open"))
            XCTAssertTrue(page.body.contains("before"))
            XCTAssertTrue(page.body.contains("after"))
        }
    }

    func testRichDetailsRendersOpenAndClosedInPreviewAndExport() {
        for open in [false, true] {
            let source = "before\n\n<details\(open ? " open" : "")><summary><strong>More</strong></summary><em>Body</em></details>\n\nafter"
            for (media, images, exporting) in [(false, false, false), (false, true, true), (true, false, true)] {
                let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: media,
                                                       resolveLocalImages: images, forExport: exporting)
                XCTAssertTrue(page.body.contains(open ? "<details open>" : "<details>"), source)
                XCTAssertTrue(page.body.contains("<summary><strong>More</strong></summary>"), source)
                XCTAssertTrue(page.body.contains("<em>Body</em>"), source)
                XCTAssertTrue(page.body.contains("before")); XCTAssertTrue(page.body.contains("after"))
            }
        }
    }

    func testConfirmedPageBreaksRenderOnlySafeEmptyBlocks() {
        let first = "<div style=\"page-break-after:always\"></div>"
        let second = "<div style=\"page-break-after: always; break-after: page;\"></div>"
        let source = "before\n\n" + first + "\n\nbetween\n\n" + second + "\n\nafter\n\n`" + first + "`\n\n<script>" + first + "</script>\n\n<template>" + first + "</template>\n\n<select>" + first + "</select>"
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
            XCTAssertEqual(page.body.components(separatedBy: "<div style=\"page-break-after:always;break-after:page\"></div>").count - 1, 2)
            XCTAssertTrue(page.body.contains("before"))
            XCTAssertTrue(page.body.contains("between"))
            XCTAssertTrue(page.body.contains("after"))
        }
        let unsafe = "<div style='page-break-after:always' style='color:red'></div>"
        XCTAssertFalse(MarkdownRenderer.renderPage(unsafe, darkMode: false, includeHTMLMedia: true).body.contains("break-after:page"))
        for source in ["> before\n>\n> " + first + "\n>\n> after", "- before\n\n  " + first + "\n\n  after"] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
            XCTAssertTrue(page.body.contains("<div style=\"page-break-after:always;break-after:page\"></div>"), source)
            XCTAssertTrue(page.body.contains("before"))
            XCTAssertTrue(page.body.contains("after"))
        }
    }
    func testUnicodeImagePathsAndSelectorsStayByteDistinctInRenderedBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnicodePreviewURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let remote = "![one](https://example.invalid/é.svg) ![two](https://example.invalid/e\u{301}.svg)"
        var page = MarkdownRenderer.renderPage(remote, darkMode: false, resolveLocalImages: true, prepareRemoteImages: true)
        try await page.resolveRemoteImages(session: session)
        XCTAssertTrue(page.body.contains("data:image/svg+xml;base64," + UnicodePreviewURLProtocol.first.base64EncodedString()))
        XCTAssertTrue(page.body.contains("data:image/svg+xml;base64," + UnicodePreviewURLProtocol.second.base64EncodedString()))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><view id='é'/><view id='e\u{301}'/></svg>".utf8)
        try svg.write(to: directory.appendingPathComponent("views.svg"))
        let source = "![one](views.svg#é) ![two](views.svg#e\u{301})"
        let local = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true, documentURL: directory.appendingPathComponent("note.md"))
        let uri = "data:image/svg+xml;base64," + svg.base64EncodedString()
        XCTAssertTrue(local.body.contains(uri + MarkdownImageUploadService.fragmentSuffix("views.svg#é")))
        XCTAssertTrue(local.body.contains(uri + MarkdownImageUploadService.fragmentSuffix("views.svg#e\u{301}")))
        let anchored = "[jump](#anchor)\n\n<div><a id='anchor'></a><img src='views.svg#é'><img src='views.svg#e\u{301}'></div>"
        let named = MarkdownRenderer.renderPage(anchored, darkMode: false, resolveLocalImages: true, documentURL: directory.appendingPathComponent("note.md"))
        XCTAssertTrue(named.body.contains(uri + MarkdownImageUploadService.fragmentSuffix("views.svg#é")))
        XCTAssertTrue(named.body.contains(uri + MarkdownImageUploadService.fragmentSuffix("views.svg#e\u{301}")))
    }
    func testListStyleMarkersCoverOnlyConfirmedItemsAndDepths() {
        let source = "- tight\n  1. nested\n- [x] task\n\n- # heading\n\n- ```\n  code\n  ```\n\n- \n"
        var page = MarkdownRenderer.renderPage(source, darkMode: false, includeListStyles: true)
        XCTAssertTrue(page.listDepths.contains(1))
        XCTAssertTrue(page.listDepths.contains(2))
        XCTAssertTrue(page.body.contains("<span hidden data-lac-list-depth=\"1\" data-lac-list-kind=\"unordered\"></span>"))
        XCTAssertTrue(page.body.contains("data-lac-list-depth=\"2\" data-lac-list-kind=\"ordered\""))
        XCTAssertFalse(page.paragraphCSS.contains("data-lac-list-depth"))
        var styles = MarkdownListStyles()
        styles.ordered[2] = .lowerAlpha
        styles.unordered[1] = .custom
        styles.customMarkers[1] = "</style>😀"
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, listStyles: styles)
        XCTAssertTrue(page.paragraphCSS.contains("list-style-type:lower-alpha"))
        XCTAssertFalse(page.paragraphCSS.contains("</style>"))
        XCTAssertFalse(MarkdownRenderer.renderPage(source, darkMode: false).body.contains("data-lac-list-depth"))
        XCTAssertFalse(MarkdownRenderer.renderPage("- [x] task", darkMode: false, includeListStyles: true).body.contains("data-lac-list-depth"))
    }

    func testOnlyStandaloneImagesAreCenteredInRenderedPage() {
        let source = "![alone](one.png)\n\n- ![list](two.png)\n\nbefore ![inline](three.png) after\n\n| A |\n|---|\n| ![cell](four.png) |"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
        XCTAssertEqual(page.body.components(separatedBy: "data-lac-centered-image").count - 1, 2)
        XCTAssertTrue(page.html.contains("[data-lac-centered-image] { display: block; text-align: center; }"))
        XCTAssertTrue(page.body.contains("before"))
        let plain = MarkdownRenderer.renderPage("<center>![中文](image.png)</center>", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(plain.body.contains("<center><img src=\"image.png\" alt=\"中文\"></center>"))
    }
    func testHeadingNumberMarkersMatchOutlineWithoutChangingAnchors() {
        let source = "[toc]\n\n## First\n\n# Title :smile:\n\n### Child\n\nref [^1]\n\n[^1]:\n    # Foot\n"
        var page = MarkdownRenderer.renderPage(source, darkMode: false, renderEmoji: true, includeHeadingNumbers: true)
        for number in ["0.1. ", "1. ", "1.0.1. "] {
            XCTAssertEqual(page.body.components(separatedBy: "data-lac-heading-number=\"\(number)\"").count - 1, 2)
        }
        XCTAssertEqual(page.body.components(separatedBy: "data-lac-heading-number=").count - 1, 6)
        XCTAssertTrue(page.body.contains("lac-heading-title-smile"))
        XCTAssertTrue(page.body.contains("😄"))
        XCTAssertFalse(page.html.contains("content:attr(data-lac-heading-number)"))
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, numberHeadings: true)
        XCTAssertTrue(page.html.contains("content:attr(data-lac-heading-number)"))
    }

    func testRemoteImagesUseRenderedSnapshotAndKeepFragments() async throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'/>".utf8)
        RemotePreviewURLProtocol.data = svg
        RemotePreviewURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemotePreviewURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let source = "![a](https://example.invalid/x.svg#one) **![b](https://example.invalid/x.svg#two)** <img src='https://example.invalid/x.svg#three' width='50%'> ![missing](https://example.invalid/missing.svg) `![code](https://example.invalid/code.svg)`"
        var page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true, prepareRemoteImages: true)
        try await page.resolveRemoteImages(session: session)
        let uri = "data:image/svg+xml;base64," + svg.base64EncodedString()
        XCTAssertTrue(page.body.contains(uri + "#one"))
        XCTAssertTrue(page.body.contains(uri + "#two"))
        XCTAssertTrue(page.body.contains(uri + "#three"))
        XCTAssertTrue(page.body.contains("width:50.0%"))
        XCTAssertTrue(page.body.contains("data:,"))
        XCTAssertEqual(RemotePreviewURLProtocol.requests.filter { $0 == "/x.svg" }.count, 1)
        XCTAssertFalse(RemotePreviewURLProtocol.requests.contains("/code.svg"))
        XCTAssertFalse(page.body.contains("LACREMOTE"))
    }
    func testSyntaxSnapshotControlsInlineMathSmartPunctuationAndSoftBreaks() {
        let source = "\"Hello\" -- world\nnext  \nhard\n\n$x$ and $ spaced $5"
        let defaults = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertTrue(defaults.body.contains("<br"))
        XCTAssertEqual(defaults.formulas.map(\.source), ["x"])
        let options = MarkdownSyntaxOptions(inlineMath: false, smartPunctuation: false,
                                            preserveEditingSoftBreaks: false)
        let plain = MarkdownRenderer.renderPage(source, darkMode: false, syntax: options)
        XCTAssertTrue(plain.formulas.isEmpty)
        XCTAssertTrue(plain.body.contains("&quot;Hello&quot; -- world") || plain.body.contains("\"Hello\" -- world"))
        XCTAssertEqual(plain.body.components(separatedBy: "<br").count - 1, 1)
        let exportedPage = MarkdownRenderer.renderPage(source, darkMode: false, syntax: options, forExport: true)
        XCTAssertEqual(exportedPage.body.components(separatedBy: "<br").count - 1, 2)
        let legacy = MarkdownRenderer.renderPage(source, darkMode: false, syntax: .init(legacyInlineMath: true))
        XCTAssertEqual(legacy.formulas.map(\.source), ["x", " spaced "])
    }

    func testNamedAnchorsUseGeneratedTargetsAndKeepHeadingPriority() {
        let source = "[named](#中文) [heading](#title)\n\n<a id='中文'></a>\n\n<a name='title'></a>\n\n# Title\n\n<script><a id='hidden'></script>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertTrue(page.body.contains("href=\"#lac-anchor-0\""))
        XCTAssertTrue(page.body.contains("id=\"lac-anchor-0\""))
        XCTAssertTrue(page.body.contains("href=\"#lac-heading-title\""))
        XCTAssertFalse(page.body.contains("id=\"中文\""))
        XCTAssertFalse(page.body.contains("hidden"))
    }

    func testNamedAnchorAfterReferenceDefinitionUsesConfirmedSource() {
        let source = "[foo]: https://example.com\n<a id='x'></a>\n\n[go](#x)"
        let body = MarkdownRenderer.renderPage(source, darkMode: false).body
        XCTAssertTrue(body.contains("href=\"#lac-anchor-0\""))
        XCTAssertTrue(body.contains("id=\"lac-anchor-0\""))
        let tabbed = "[foo]: https://example.com\n\t<a id='x'></a>\n\n[go](#x)"
        XCTAssertTrue(MarkdownRenderer.renderPage(tabbed, darkMode: false).body.contains("lac-anchor-0"))
    }

    func testReferenceRetainedTabsRenderInlineContent() {
        for newline in ["\n", "\r", "\r\n"] {
            let source = ["- [a]: /x", "  [b]: /y", "  中文\t**bold**\t[link][b] `code` $x$"].joined(separator: newline)
            let page = MarkdownRenderer.renderPage(source, darkMode: false)
            XCTAssertTrue(page.body.contains("<strong>bold</strong>"), source)
            XCTAssertTrue(page.body.contains("href=\"/y\""), source)
            XCTAssertTrue(page.body.contains("<code>code</code>"), source)
            XCTAssertEqual(page.formulas.map(\.source), ["x"], source)
        }
    }

    func testConfirmedInlineHTMLLinkRendersSafeHrefAndFragment() {
        let source = "text <a href='#target'>中文</a> <a href='https://example.com/?a=1&amp;b=2'>link</a>\n\n# Target"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertTrue(page.body.contains("href=\"#lac-heading-target\""))
        XCTAssertTrue(page.body.contains("href=\"https://example.com/?a=1&amp;b=2\""))
        XCTAssertTrue(page.body.contains(">中文</a>"))
        let unsafe = MarkdownRenderer.renderPage("text <a href='javascript:alert(1)'>bad</a>", darkMode: false)
        XCTAssertFalse(unsafe.body.contains("href=\"javascript:"))
    }

    func testNamedAnchorTargetsDistinguishUnicodeNormalizationForms() throws {
        let source = "[a](#%C3%A9) [b](#e%CC%81)\n\n<a id='é'></a> <a id='e\u{301}'></a>"
        let body = MarkdownRenderer.renderPage(source, darkMode: false).body as NSString
        let pattern = try NSRegularExpression(pattern: "href=\"#(lac-anchor-[^\"]+)\"")
        let matches = pattern.matches(in: body as String, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(matches.count, 2)
        guard matches.count == 2 else { return }
        XCTAssertNotEqual(body.substring(with: matches[0].range(at: 1)), body.substring(with: matches[1].range(at: 1)))
    }

    func testNestedNamedAnchorKeepsSafeHTMLPosition() {
        let source = "[jump](#inside)\n\n<div>before <a id='inside'>target</a> after <template><a id='hidden'></a></template></div>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        let linkStart = page.body.range(of: "href=\"#lac-anchor-")
        XCTAssertNotNil(linkStart)
        XCTAssertTrue(page.body.contains("before <span id=\"lac-anchor-"))
        XCTAssertTrue(page.body.contains("</span><a>target</a> after"))
        XCTAssertFalse(page.body.contains("hidden"))
        let plain = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(plain.body.contains("href=\"#lac-anchor-"))
        XCTAssertTrue(plain.body.contains("before <span id=\"lac-anchor-"))
        XCTAssertTrue(plain.omittedHTML)
    }

    func testNamedAnchorConfirmsTabbedSourcePositions() {
        let source = "[foo]: https://example.com\n\t<a id='x'></a>\n\n[foo] [jump](#x)"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertTrue(page.body.contains("id=\"lac-anchor-"))
    }

    func testRepeatedNamedAnchorsFollowSourceOrderAcrossHTMLBlocks() throws {
        for target in ["<div><a id='same'>block</a></div>\n\n<a id='same'></a>",
                       "<a id='same'></a>\n\n<div><a id='same'>block</a></div>"] {
            let page = MarkdownRenderer.renderPage("[jump](#same)\n\n" + target, darkMode: false)
            let body = page.body as NSString
            let pattern = try NSRegularExpression(pattern: "(?:href=\"#|id=\")(lac-anchor-[^\"]+)\"")
            let matches = pattern.matches(in: page.body, range: NSRange(location: 0, length: body.length))
            XCTAssertGreaterThanOrEqual(matches.count, 3)
            guard matches.count >= 3 else { continue }
            XCTAssertEqual(body.substring(with: matches[0].range(at: 1)), body.substring(with: matches[1].range(at: 1)))
        }
    }

    func testParagraphTypographyUsesFixedAlignmentAndSpacing() {
        var page = MarkdownRenderer.renderPage("First\n\nSecond", darkMode: false)
        XCTAssertFalse(page.html.contains("article{text-align:"))
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, usesCustomFontMetrics: false,
                                             textAlignment: "justify", paragraphSpacing: 12)
        XCTAssertTrue(page.html.contains("article{text-align:justify}article p{margin:0 0 12.0px}"))
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, usesCustomFontMetrics: false,
                                             textAlignment: "left;color:red", paragraphSpacing: -Double.infinity)
        XCTAssertFalse(page.html.contains("article{text-align:left;color:red}"))
        XCTAssertFalse(page.html.contains("margin:0 0 -infpx"))
    }
    func testCenteredHeadingLevelsOverrideArticleAlignment() {
        var page = MarkdownRenderer.renderPage("# First\n\n## Second", darkMode: false)
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, usesCustomFontMetrics: false,
                                             centeredHeadingLevels: [1, 3, 7], textAlignment: "right")
        XCTAssertTrue(page.html.contains("article{text-align:right}"))
        XCTAssertTrue(page.html.contains("article h1,article h3{text-align:center}"))
        XCTAssertFalse(page.html.contains("article h7"))
    }
    func testUppercaseHeadingLevelsUseDisplayOnlyCSS() {
        var page = MarkdownRenderer.renderPage("# Straße\n\n## mixed", darkMode: false)
        let body = page.body
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, uppercaseHeadingLevels: [1, 3, 7])
        XCTAssertTrue(page.html.contains("article h1,article h3{text-transform:uppercase}"))
        XCTAssertTrue(page.html.contains("article h1 [data-lac-math],article h3 [data-lac-math]{text-transform:none}"))
        XCTAssertFalse(page.html.contains("article h7"))
        XCTAssertEqual(page.body, body)
        page.typography = nil
        XCTAssertFalse(page.html.contains("text-transform:uppercase"))
    }
    func testRightToLeftUsesFixedDocumentRule() {
        var page = MarkdownRenderer.renderPage("مرحبا English", darkMode: false)
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, rightToLeft: true)
        XCTAssertTrue(page.html.contains("article{direction:rtl}"))
        page.typography = nil
        XCTAssertFalse(page.html.contains("article{direction:rtl}"))
    }
    func testVerticalWritingUsesFixedDocumentRule() {
        var page = MarkdownRenderer.renderPage("中文 English", darkMode: false)
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, verticalWriting: true)
        XCTAssertTrue(page.html.contains("article{writing-mode:vertical-rl;text-orientation:mixed}@media screen{article{height:100vh;overflow-x:auto}}"))
        page.typography = nil
        XCTAssertFalse(page.html.contains("writing-mode:vertical-rl"))
    }
    func testCompletedTasksUseOptInRule() {
        var page = MarkdownRenderer.renderPage("- [x] done\n- [ ] pending\n\n<div><a id='point'></a><ul><li><input type='checkbox' checked>raw</li></ul></div>", darkMode: false)
        XCTAssertFalse(page.html.contains("article li:has(>span[data-lac-checked-task])"))
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, strikeCompletedTasks: true)
        XCTAssertTrue(page.html.contains("article li:has(>span[data-lac-checked-task]){text-decoration:line-through}"))
        XCTAssertTrue(page.body.contains("checked"))
        XCTAssertEqual(page.body.components(separatedBy: "data-lac-checked-task").count - 1, 1)
    }
    func testLocalImagesUseSnapshotRootOnlyForRenderedOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let site = directory.appendingPathComponent("site", isDirectory: true)
        let posts = directory.appendingPathComponent("posts", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: posts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: site.appendingPathComponent("a#b.png"))
        try png.write(to: posts.appendingPathComponent("relative.png"))
        let source = "---\ntypora-root-url: ../site\n---\n\n![a](/a%23b.png) ![b](relative.png)"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true,
                                               documentURL: posts.appendingPathComponent("note.md"))
        XCTAssertEqual(page.body.components(separatedBy: "data:image/png;base64," + png.base64EncodedString()).count - 1, 2)
        let nestedSource = "---\ntypora-root-url: ../site\n---\n\n[jump](#point)\n\n<div><a id='point'>target</a><img src='/a%23b.png'></div>"
        let nested = MarkdownRenderer.renderPage(nestedSource, darkMode: false, resolveLocalImages: true,
                                                 documentURL: posts.appendingPathComponent("note.md"))
        XCTAssertTrue(nested.body.contains("data:image/png;base64," + png.base64EncodedString()))
        XCTAssertTrue(nested.body.contains("href=\"#lac-anchor-"))
        let plain = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(plain.body.contains("/a%23b.png"))
        XCTAssertTrue(plain.body.contains("relative.png"))
        let network = "---\ntypora-root-url: [invalid]\n---\n\n![remote](//example.com/image.png) ![local](relative.png)"
        let networkPage = MarkdownRenderer.renderPage(network, darkMode: false, resolveLocalImages: true,
                                                      documentURL: posts.appendingPathComponent("note.md"))
        XCTAssertTrue(networkPage.body.contains("//example.com/image.png"))
        XCTAssertTrue(networkPage.body.contains("data:image/png;base64," + png.base64EncodedString()))
    }

    func testRenderedHTMLImagesUseSafeSizingAndKeepOtherHTMLDisabled() {
        let uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let source = "before <img src='\(uri)' width='80' style='height:20px;zoom:50%;background:url(https://example.invalid)'> after\n\n<select> text <img src='\(uri)' width='5'> text </select>\n\n<video src='https://example.invalid/video.mp4'></video>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(page.body.contains("style=\"width:80.0px;height:20.0px;zoom:0.5;\""))
        XCTAssertEqual(page.body.components(separatedBy: "<img ").count - 1, 1)
        XCTAssertFalse(page.body.contains("background:"))
        XCTAssertFalse(page.body.contains("<video"))
        let plain = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(plain.body.contains("zoom:0.5"))
        let block = "<div>before <img src='\(uri)' width='40'> middle <strong>text</strong> <img src='\(uri)' style='height:12px'> after<video src='https://example.invalid/v'></video></div>"
        let nested = MarkdownRenderer.renderPage(block, darkMode: false, resolveLocalImages: true)
        XCTAssertEqual(nested.body.components(separatedBy: "<img ").count - 1, 2)
        XCTAssertTrue(nested.body.contains("before"))
        XCTAssertTrue(nested.body.contains("middle <strong>text</strong>"))
        XCTAssertTrue(nested.body.contains("after"))
        XCTAssertTrue(nested.body.contains("width:40.0px"))
        XCTAssertTrue(nested.body.contains("height:12.0px"))
        XCTAssertFalse(nested.body.contains("<video"))
        let anchored = "[jump](#point)\n\n<div><a id='point'></a><img src='\(uri)' width='80' style='zoom:50%'> tail</div>"
        let withAnchor = MarkdownRenderer.renderPage(anchored, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(withAnchor.body.contains("href=\"#lac-anchor-"))
        XCTAssertTrue(withAnchor.body.contains("width:80.0px;zoom:0.5;"))
        XCTAssertTrue(withAnchor.body.contains("tail"))
        XCTAssertTrue(withAnchor.body.contains(uri))
        let object = "[jump](#point)\n\n<div><a id='point'></a><object data='movie.mp4'><img src='\(uri)'></object></div>"
        let objectPage = MarkdownRenderer.renderPage(object, darkMode: false, resolveLocalImages: true)
        XCTAssertFalse(objectPage.body.contains("<img "))
        let multiline = "<div>\r\n中文 <img src='\(uri)' width='30'>\r\ntext <img src='\(uri)' height='10'>\r\n</div>"
        let multilinePage = MarkdownRenderer.renderPage(multiline, darkMode: false, resolveLocalImages: true)
        XCTAssertEqual(multilinePage.body.components(separatedBy: "<img ").count - 1, 2)
        XCTAssertTrue(multilinePage.body.contains("中文"))
        XCTAssertTrue(multilinePage.body.contains("text"))
        let quote = "> <div>\r\n> before <img\r\n> src='\(uri)' width='30'> after\r\n> </div>"
        let quotePage = MarkdownRenderer.renderPage(quote, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(quotePage.body.contains("before"))
        XCTAssertTrue(quotePage.body.contains("after"))
        XCTAssertTrue(quotePage.body.contains("width:30.0px"))
        let list = "- <div>\n  before <img src='\(uri)' width='20'> after\n  </div>"
        let listPage = MarkdownRenderer.renderPage(list, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(listPage.body.contains("before"))
        XCTAssertTrue(listPage.body.contains("after"))
        XCTAssertTrue(listPage.body.contains("width:20.0px"))
        let script = "> <script><!--<script\n> </script\n> still\n> -->\n> <img src='https://example.invalid/hidden.png'>\n> </script>\n\n<img src='\(uri)' width='25'>"
        let scriptPage = MarkdownRenderer.renderPage(script, darkMode: false, resolveLocalImages: true, prepareRemoteImages: true)
        XCTAssertFalse(scriptPage.remoteImageMarkers.values.contains("https://example.invalid/hidden.png"))
        let control = "<script>hidden</script>\n\n<img src='\(uri)' width='25'>"
        XCTAssertTrue(MarkdownRenderer.renderPage(control, darkMode: false, resolveLocalImages: true).body.contains("width:25.0px"))
        let splitControl = "before <script>\n\ntext\n\n</script> after <u>visible</u> <img src='\(uri)' width='25'>"
        let splitPage = MarkdownRenderer.renderPage(splitControl, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(splitPage.body.contains("<u>visible</u>"))
        XCTAssertTrue(splitPage.body.contains("width:25.0px"))
    }

    func testLocalSVGIsEmbeddedInRenderedPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'><rect width='2' height='2' fill='red'/></svg>".utf8)
        try svg.write(to: directory.appendingPathComponent("figure.svg"))
        let page = MarkdownRenderer.renderPage("![figure](figure.svg#first)\n\n[jump](#point)\n\n<div><a id='point'>target</a><img src='figure.svg#second'></div>", darkMode: false, resolveLocalImages: true,
                                               documentURL: directory.appendingPathComponent("note.md"))
        let uri = "data:image/svg+xml;base64," + svg.base64EncodedString()
        XCTAssertTrue(page.body.contains(uri + "#first"))
        XCTAssertTrue(page.body.contains(uri + "#second"))
    }

    func testSmallCapsOnlyTargetsSelectedHeadingLevels() {
        var page = MarkdownRenderer.renderPage("# First\n\n## Second\n\n#### Fourth", darkMode: false)
        let ids = page.headingIDs
        page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, usesCustomFontMetrics: false, smallCapsLevels: [1, 4, 9])
        XCTAssertTrue(page.html.contains("h1,h4{font-variant:small-caps}"))
        XCTAssertFalse(page.html.contains("h9{font-variant:small-caps}"))
        XCTAssertEqual(page.headingIDs, ids)
        XCTAssertTrue(page.body.contains("Second"))
    }

    func testLigatureTypographyUsesFixedValuesAndPreservesDefault() {
        var page = MarkdownRenderer.renderPage("office `ffi`", darkMode: false)
        XCTAssertFalse(page.html.contains("font-variant-ligatures:"))
        for (value, css) in [(0, "none"), (1, "normal"), (2, "common-ligatures discretionary-ligatures historical-ligatures contextual")] {
            page.typography = MarkdownTypography(fontSize: 14, lineHeight: 20, usesCustomFontMetrics: false, ligatures: value)
            XCTAssertTrue(page.html.contains("font-variant-ligatures:\(css)"))
            XCTAssertTrue(page.body.contains("<code>ffi</code>"))
        }
    }

    func testEmojiRenderingUsesConfirmedTextNodes() async {
        let source = "中😀 :smile: \\:heart: `:smile:` [link :heart:](https://example.com/:smile:)\r\n\r\n| H |\r\n|---|\r\n| a\\|b **:smile:** |"
        let page = await Task.detached { MarkdownRenderer.renderPage(source, darkMode: false, renderEmoji: true) }.value
        XCTAssertTrue(page.body.contains("中😀 😄"))
        XCTAssertTrue(page.body.contains(":heart:"))
        XCTAssertTrue(page.body.contains("<code>:smile:</code>"))
        XCTAssertTrue(page.body.contains("href=\"https://example.com/:smile:\""))
        XCTAssertTrue(page.body.contains("link ❤️"))
        XCTAssertTrue(page.body.contains("a|b <strong>😄</strong>"))
    }

    func testEmojiInsideDecorationsAndTOCKeepsHeadingID() async {
        let source = "[toc]\n\n# Header :smile:\n\n==:smile:== ^:heart:^ ~:smile:~"
        let original = MarkdownRenderer.renderPage(source, darkMode: false)
        let page = await Task.detached { MarkdownRenderer.renderPage(source, darkMode: false, renderEmoji: true) }.value
        XCTAssertEqual(page.headingIDs, original.headingIDs)
        XCTAssertTrue(page.body.contains("<mark>😄</mark>"))
        XCTAssertTrue(page.body.contains("<sup>❤️</sup>"))
        XCTAssertTrue(page.body.contains("<sub>😄</sub>"))
        XCTAssertTrue(page.body.contains("Header 😄"))
        XCTAssertTrue(page.body.contains("<a href=\"#"))
        XCTAssertFalse(page.body.contains(":smile:"))
        XCTAssertFalse(page.body.contains(":heart:"))
    }

    func testTOCLevelHidesOnlyGeneratedEntriesAndKeepsAllAnchors() {
        let source = "[toc]\n\n# 中文😀\n\n### Deep\n\n## Second\n\n# 中文😀"
        var page = MarkdownRenderer.renderPage(source, darkMode: false)
        let ids = page.headingIDs
        page.typography = MarkdownTypography(fontSize: 16, lineHeight: 24, usesCustomFontMetrics: false, tocMaxLevel: 1)
        XCTAssertTrue(page.html.contains("<li data-level=\"3\" hidden>"))
        XCTAssertTrue(page.html.contains("<li data-level=\"2\" hidden>"))
        XCTAssertTrue(page.html.contains("<li data-level=\"1\"><a"))
        XCTAssertEqual(page.headingIDs, ids)
        XCTAssertEqual(ids.count, 4)
    }

    func testWidthOnlyTypographyKeepsDefaultFontAndPrintWidth() {
        var page = MarkdownRenderer.renderPage("Text", darkMode: false)
        page.typography = MarkdownTypography(fontSize: 30, lineHeight: 50, textFamily: "Menlo", codeFamily: "Menlo",
                                             maximumWidth: 420, usesCustomFontMetrics: false)
        XCTAssertTrue(page.html.contains("--lac-content-width:420.0px"))
        XCTAssertTrue(page.html.contains("--lac-print-width:min(100%,420.0px)"))
        XCTAssertFalse(page.html.contains("font-size:30.0px"))
        XCTAssertFalse(page.html.contains("--lac-code-font:"))
        XCTAssertTrue(page.html.contains("max-width: var(--lac-print-width, none)"))
    }

    func testLegacyDiagramsUseOnlyConfirmedTopLevelClosedFences() {
        let source = "中文😀\r\n\r\n```flow\r\ns=>start: <Start>\r\n```\r\n\r\n```sequence\r\nA->B: Hello\r\n```\r\n\r\n> ```flow\r\n> nested\r\n> ```\r\n\r\n```sequence\r\nunclosed"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertEqual(page.diagrams.map(\.kind), [.flow, .sequence])
        XCTAssertEqual(page.diagrams.map(\.source), ["s=>start: <Start>\n", "A->B: Hello\n"])
        XCTAssertTrue(page.body.contains("data-lac-diagram=\"0\""))
        XCTAssertTrue(page.body.contains("&lt;Start&gt;"))
        XCTAssertFalse(page.body.contains("<Start>"))
        XCTAssertTrue(page.body.contains("unclosed"))
    }

    @MainActor
    func testExportKeepsConfirmedImageWhenAnotherHasUnmappedTab() {
        let text = "Text <img src=\"good.png\" alt=\"ok\">\n\n<img src='other.png' title='a\tb'>"
        let page = MarkdownRenderer.renderPage(text, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("src=\"good.png\""))
        XCTAssertTrue(page.body.contains("alt=\"ok\""))
        XCTAssertFalse(page.body.contains("other.png"))
    }

    func testExportPreservesConfirmedImageTitle() {
        let page = MarkdownRenderer.renderPage("Text <img src=\"image.png\" title=\"A &amp; B\">", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("src=\"image.png\""))
        XCTAssertTrue(page.body.contains("title=\"A &amp; B\""))
    }

    func testExportRendersUnquotedImageAttributes() {
        let source = "Text <img src=photo.png alt=中文 title=A&amp;B width=50>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("src=\"photo.png\""))
        XCTAssertTrue(page.body.contains("alt=\"中文\""))
        XCTAssertTrue(page.body.contains("title=\"A&amp;B\""))
        XCTAssertTrue(page.body.contains("width=\"50\""))
        XCTAssertFalse(page.omittedHTML)
    }

    func testExportRendersCaseInsensitiveImageAttributes() {
        let page = MarkdownRenderer.renderPage("Text <IMG SRC=\"photo.png\" ALT=\"中文\" TITLE=\"Title\">", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<img src=\"photo.png\" alt=\"中文\" title=\"Title\">"))
        XCTAssertFalse(page.omittedHTML)
    }

    func testExportPreservesEmptyImageAlt() {
        let page = MarkdownRenderer.renderPage("Text <img src=photo.png alt=\"\" title=\"\">", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("src=\"photo.png\" alt=\"\" title=\"\""))
        XCTAssertFalse(page.omittedHTML)
    }

    func testExportDecodesHTMLImageAttributeEntities() {
        let source = "Text <img src='photo&copy;.png' alt=\"&copy; &copy &#x80; &y=2\" title=\"A &amp; B\">"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("alt=\"© © € &amp;y=2\""))
        XCTAssertTrue(page.body.contains("src=\"photo©.png\""))
        XCTAssertTrue(page.body.contains("title=\"A &amp; B\""))
        XCTAssertFalse(page.omittedHTML)
    }

    func testExportPreservesTextAndImagesInMixedHTMLBlock() {
        let source = "<div>Before &amp; after <img src=\"first.png\" alt=\"中文\"> text <img src=\"second.png\" title=\"A &amp; B\"></div>\n"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<div>Before &amp; after <img src=\"first.png\" alt=\"中文\"> text <img src=\"second.png\" title=\"A &amp; B\"></div>"))
        XCTAssertFalse(page.omittedHTML)
        let unsafe = MarkdownRenderer.renderPage("<div>before <script>alert(1)</script> <img src=\"x.png\"></div>\n", darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(unsafe.body.contains("<script>"))
        XCTAssertFalse(unsafe.body.contains("alert(1)"))
        XCTAssertTrue(unsafe.omittedHTML)
    }

    func testExportPreservesPairedAudioAndImageInMixedHTMLBlock() {
        let source = "<div>Before <audio src=\"sound.mp3\"></audio> middle <img src=\"x.png\"> after</div>\n"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<div>Before <audio controls src=\"sound.mp3\"></audio> middle <img src=\"x.png\"> after</div>"))
        XCTAssertFalse(page.omittedHTML)
        let unsafe = MarkdownRenderer.renderPage("<div><script><audio src=\"hidden.mp3\"></audio></script><img src=\"x.png\"></div>", darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(unsafe.body.contains("hidden.mp3"))
        XCTAssertTrue(unsafe.omittedHTML)
    }

    func testPreviewKeepsConfirmedInlineAndNestedMediaWithSurroundingText() {
        let source = "before <video controls src='https://example.invalid/movie.mp4'><img src='fallback.png'></video> after\n\n<div>left <audio controls src='https://example.invalid/sound.mp3'></audio> right</div>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(page.body.contains("before "))
        XCTAssertTrue(page.body.contains(" after"))
        XCTAssertTrue(page.body.contains("left "))
        XCTAssertTrue(page.body.contains(" right"))
        XCTAssertTrue(page.body.contains("<video"))
        XCTAssertTrue(page.body.contains("https://example.invalid/movie.mp4"))
        XCTAssertTrue(page.body.contains("<audio"))
        XCTAssertTrue(page.body.contains("https://example.invalid/sound.mp3"))
        if let image = page.body.range(of: "fallback.png") {
            let video = page.body.range(of: "<video")
            let end = page.body.range(of: "</video>")
            XCTAssertNotNil(video)
            XCTAssertNotNil(end)
            if let video, let end { XCTAssertTrue(video.lowerBound < image.lowerBound && image.upperBound < end.upperBound) }
        }
        XCTAssertTrue(page.html.contains("media-src data: http: https:"))
        XCTAssertTrue(page.html.contains("frame-src http: https:"))
        let unproved = "<div><a id='target'></a><video onclick='bad()' src='https://example.invalid/unproved.mp4'></video></div>\n\n[link](#target)"
        let guarded = MarkdownRenderer.renderPage(unproved, darkMode: false, resolveLocalImages: true)
        XCTAssertFalse(guarded.body.contains("unproved.mp4"))
        let sourceChild = MarkdownRenderer.renderPage("before <video controls><source src='https://example.invalid/child.mp4'>fallback</video> after", darkMode: false, resolveLocalImages: true)
        XCTAssertEqual(sourceChild.body.components(separatedBy: "<source ").count - 1, 1)
        XCTAssertTrue(sourceChild.body.contains("fallback"))
        let standalone = MarkdownRenderer.renderPage("<video src='https://example.invalid/movie.mp4' />\n\n<iframe src='https://example.invalid/frame'></iframe>", darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(standalone.body.contains("https://example.invalid/movie.mp4"))
        XCTAssertTrue(standalone.body.contains("sandbox=\"allow-scripts\""))
        XCTAssertTrue(standalone.body.contains("https://example.invalid/frame"))
        let anchored = MarkdownRenderer.renderPage("<div><a id='target'></a>left <video controls src='https://example.invalid/anchored.mp4'></video> right</div>\n\n[link](#target)", darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(anchored.body.contains("https://example.invalid/anchored.mp4"))
        XCTAssertTrue(anchored.body.contains("left "))
        XCTAssertTrue(anchored.body.contains(" right"))
        XCTAssertTrue(anchored.body.contains("lac-anchor-"))
        let adjacent = MarkdownRenderer.renderPage("<div><audio controls src='https://example.invalid/a.mp3'></audio><audio controls src='https://example.invalid/b.mp3'></audio></div>", darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(adjacent.body.contains("https://example.invalid/a.mp3"))
        XCTAssertTrue(adjacent.body.contains("https://example.invalid/b.mp3"))
        let inlineFrame = MarkdownRenderer.renderPage("before <iframe src='https://example.invalid/frame'>fallback <b>literal</b></iframe> after", darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(inlineFrame.body.contains("before "))
        XCTAssertTrue(inlineFrame.body.contains(" after"))
        XCTAssertTrue(inlineFrame.body.contains("sandbox=\"allow-scripts\""))
        XCTAssertTrue(inlineFrame.body.contains("fallback <b>literal</b>"))
        XCTAssertEqual(inlineFrame.body.components(separatedBy: "<iframe").count - 1, 1)
        for source in ["before <script><video src='https://example.invalid/hidden.mp4'></video></script> after",
                       "before <template><video src='https://example.invalid/hidden.mp4'></video></template> after",
                       "before <select><video src='https://example.invalid/hidden.mp4'></video></select> after"] {
            let hidden = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
            XCTAssertFalse(hidden.body.contains("hidden.mp4"))
        }
        for source in ["<video src='https://example.invalid/outer.mp4'>\nfallback <audio src='https://example.invalid/inner.wav'></audio>\n</video>",
                       "before <video src='https://example.invalid/outer.mp4'>fallback <audio src='https://example.invalid/inner.wav'></audio></video> after",
                       "<div>before <video src='https://example.invalid/outer.mp4'>fallback <audio src='https://example.invalid/inner.wav'></audio></video> after</div>"] {
            let nested = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
            XCTAssertTrue(nested.body.contains("outer.mp4"))
            XCTAssertFalse(nested.body.contains("inner.wav"))
            XCTAssertEqual(nested.body.components(separatedBy: "<video").count - 1, 1)
        }
        let crossing = MarkdownRenderer.renderPage("**before <video src='https://example.invalid/cross.mp4'>** fallback </video> after", darkMode: false, resolveLocalImages: true)
        XCTAssertFalse(crossing.body.contains("cross.mp4"))
        for (source, style) in [("**before <video src='https://example.invalid/strong.mp4'>fallback</video> after**", "strong"),
                                ("*before <video src='https://example.invalid/emph.mp4'>fallback</video> after*", "em"),
                                ("~~before <video src='https://example.invalid/strike.mp4'>fallback</video> after~~", "del")] {
            let formatted = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
            XCTAssertTrue(formatted.body.contains("<\(style)>"))
            XCTAssertTrue(formatted.body.contains("</\(style)>"))
            XCTAssertTrue(formatted.body.contains("<video"))
            XCTAssertTrue(formatted.body.contains("before"))
            XCTAssertTrue(formatted.body.contains("after"))
            XCTAssertTrue(formatted.body.contains("fallback"))
        }
        let linked = MarkdownRenderer.renderPage("[before <video src='https://example.invalid/linked.mp4'>fallback</video> after](https://example.invalid/page)", darkMode: false, resolveLocalImages: true)
        XCTAssertEqual(linked.body.components(separatedBy: "<a ").count - 1, 1)
        XCTAssertTrue(linked.body.contains("https://example.invalid/page"))
        XCTAssertTrue(linked.body.contains("https://example.invalid/linked.mp4"))
        XCTAssertTrue(linked.body.contains("before"))
        XCTAssertTrue(linked.body.contains("after"))
    }

    func testPlainHTMLPreservesCanonicalMediaAndUnknownRawAttributes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([0x52, 0x49, 0x46, 0x46, 1, 2])
        try bytes.write(to: directory.appendingPathComponent("sound.wav"))
        let source = "<audio controls src='sound.wav'></audio>"
        let url = directory.appendingPathComponent("note.md")
        var baseline = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                                    documentURL: url, forExport: true)
        var raw = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                               documentURL: url, forExport: true, preserveRawHTMLBlocks: true)
        try baseline.prepareLocalMedia(load: true); try raw.prepareLocalMedia(load: true)
        XCTAssertFalse(raw.rawHTMLBlockProofFailed)
        XCTAssertTrue(raw.rawHTMLBlocks.isEmpty)
        XCTAssertEqual(raw.body, baseline.body)
        let unknown = "<div><video class='unsupported' data-x='keep' src='local.mp4'></video></div>"
        let page = MarkdownRenderer.renderPage(unknown, darkMode: false, includeHTMLMedia: true,
                                               forExport: true, preserveRawHTMLBlocks: true)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        XCTAssertTrue(page.rawHTMLBlocks.contains { $0.html == unknown })
    }

    func testPlainHTMLKeepsRawNeighboursOfConfirmedMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: directory.appendingPathComponent("movie.mp4"))
        let source = "<div data-x='keep'>\r\n<video src='movie.mp4'>Видео &amp; 中文</video><video><source src='movie.mp4'>Запас &amp; 😀</video>\r\n<script>window.example=1</script><style>.x{color:red}</style>\r\n</div>"
        var page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
            documentURL: directory.appendingPathComponent("note.md"), forExport: true, preserveRawHTMLBlocks: true)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        XCTAssertFalse(page.body.contains("window.example"))
        try page.prepareLocalMedia(load: true)
        let raw = try XCTUnwrap(page.rawHTMLBlocks.first?.html)
        XCTAssertTrue(raw.contains("<div data-x='keep'>\r\n"))
        XCTAssertTrue(raw.contains("data:video/mp4;base64," + bytes.base64EncodedString()))
        XCTAssertTrue(raw.contains("Видео &amp; 中文</video>"))
        XCTAssertTrue(raw.contains("Запас &amp; 😀</video>"))
        XCTAssertEqual(raw.components(separatedBy: "data:video/mp4;base64,").count - 1, 2)
        XCTAssertEqual(raw.components(separatedBy: "<video controls").count - 1, 2)
        XCTAssertTrue(raw.contains("<script>window.example=1</script><style>.x{color:red}</style>"))
        XCTAssertFalse(raw.contains("LACLOCALMEDIA"))
    }

    func testPlainHTMLKeepsInlineMediaSourceOnce() {
        let source = "text <video><source src='https://example.com/a.mp4'></video> end"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                               forExport: true, preserveRawHTMLBlocks: true)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        XCTAssertEqual(page.rawHTMLBlocks.map(\.html), ["<video>", "<source src='https://example.com/a.mp4'>", "</video>"])
        XCTAssertEqual(page.body.components(separatedBy: "<source").count - 1, 0)
    }

    func testPlainHTMLUsesCanonicalRecognizedWidgets() {
        let twitter = "<blockquote class='twitter-tweet'><p>Sunsets 中文</p><a href='https://x.com/Interior/status/463440424141459456'>Post</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js'></script>"
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20'/></svg>"
        let frame = "<iframe src='https://example.invalid/embed'></iframe>"
        for source in [twitter, svg, frame] {
            let previous = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true, forExport: true)
            let current = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true,
                                                      forExport: true, preserveRawHTMLBlocks: true)
            XCTAssertFalse(current.rawHTMLBlockProofFailed, source)
            XCTAssertEqual(current.body, previous.body, source)
            XCTAssertTrue(current.rawHTMLBlocks.isEmpty, source)
        }
    }

    func testLocalMediaPreparationPreservesBytesAndFragment() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let bytes = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02])
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let marker = "LACLOCALMEDIA" + String(repeating: "A", count: 32) + "X0"
        var page = MarkdownRenderedPage(body: "before <audio src=\"\(marker)\"></audio> after", darkMode: false)
        page.localMediaMarkers[marker] = .init(url: file, fragment: "#t=2")
        var placeholder = page
        try placeholder.prepareLocalMedia(load: false)
        XCTAssertTrue(placeholder.body.contains("src=\"data:,\""))
        try page.prepareLocalMedia(load: true)
        XCTAssertTrue(page.body.contains(";base64,\(bytes.base64EncodedString())#t=2"))
        XCTAssertTrue(page.body.contains("before "))
        XCTAssertTrue(page.body.contains(" after"))
        XCTAssertTrue(page.localMediaMarkers.isEmpty)
    }

    func testExportPreservesDocumentedDetailsBlock() {
        let source = "<details>\n<summary>Question?</summary>\nAnswer.\n</details>\n"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<details>"))
        XCTAssertTrue(page.body.contains("<summary>Question?</summary>"))
        XCTAssertTrue(page.body.contains("Answer."))
        XCTAssertFalse(page.omittedHTML)
        let unknown = MarkdownRenderer.renderPage("<lac-root>VISIBLE</lac-root>", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(unknown.omittedHTML)
    }

    func testExportPreservesConfirmedInlineHTMLOutsideScripts() {
        let clean = MarkdownRenderer.renderPage("Text <kbd>Ctrl</kbd><br>After", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(clean.body.contains("<kbd>Ctrl</kbd><br>After"))
        XCTAssertFalse(clean.omittedHTML)
        let source = "Text <kbd>Ctrl</kbd> <ruby>漢<rt>ㄏㄢˋ</rt></ruby><br>After\n\n<script><kbd>hidden</kbd></script>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<kbd>Ctrl</kbd>"))
        XCTAssertTrue(page.body.contains("<ruby>漢<rt>ㄏㄢˋ</rt></ruby>"))
        XCTAssertTrue(page.body.contains("<br>After"))
        XCTAssertFalse(page.body.contains("<kbd>hidden</kbd>"))
        XCTAssertTrue(page.omittedHTML)
        for source in ["hello <strong>world\n\nnext", "hello </kbd>world", "<kbd><ruby>text</kbd></ruby>"] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
            XCTAssertFalse(page.body.contains("<strong>"))
            XCTAssertFalse(page.body.contains("<kbd>"))
            XCTAssertFalse(page.body.contains("</kbd>"))
            XCTAssertTrue(page.omittedHTML)
        }
    }

    func testSharedInlineHTMLPairsRenderInPreviewAndExport() {
        let source = "中文😀 <u>outer <u>inner</u></u> **<em>mixed</em>** [<strong>link</strong>](https://example.com) <mark>mark</mark> <sub>2</sub> <sup>3</sup> <s>old</s>\n\n<script><u>hidden</u></script>\n\n<template><u>inert</u></template>"
        for export in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: export)
            XCTAssertTrue(page.body.contains("<u>outer <u>inner</u></u>"))
            XCTAssertTrue(page.body.contains("<strong><em>mixed</em></strong>"))
            XCTAssertTrue(page.body.contains("<strong>link</strong>"))
            XCTAssertTrue(page.body.contains("<mark>mark</mark>"))
            XCTAssertTrue(page.body.contains("<sub>2</sub>"))
            XCTAssertTrue(page.body.contains("<sup>3</sup>"))
            XCTAssertTrue(page.body.contains("<del>old</del>"))
            XCTAssertFalse(page.body.contains("<u>hidden</u>"))
            XCTAssertFalse(page.body.contains("<u>inert</u>"))
        }
    }

    func testStyledInlineSpansRenderInPreviewAndPlainHTML() throws {
        let source = "Text <span style='color:&#114;ed'>red <span style='font-size:2rem;background:yellow'>**中文😀**</span></span> end"
        let outer = try XCTUnwrap(MarkdownInlineStyle(css: "color:red"))
        let inner = try XCTUnwrap(MarkdownInlineStyle(css: "font-size:2rem;background:yellow"))
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain)
            XCTAssertTrue(page.body.contains("<span style=\"" + outer.css + "\">red <span style=\"" + inner.css + "\"><strong>中文😀</strong></span></span>"))
            XCTAssertTrue(page.body.contains(" end"))
            let unsafe = MarkdownRenderer.renderPage("before <span style='position:fixed'>**<span style='color:red'>hidden</span>**</span> after", darkMode: false, includeHTMLMedia: plain)
            XCTAssertFalse(unsafe.body.contains("style=\"" + outer.css + "\""))
        }
    }

    func testDisplayNoneRendersInInlineBlockAndTableExports() {
        let examples = [
            "before <span style='display:none;color:red'>hidden <span style='background:yellow'>nested</span></span> after",
            "<div>before <span style='display:none'>hidden</span> after</div>",
            "| A | B |\n| --- | --- |\n| <span style='display:none'>hidden</span> | visible |"
        ]
        for source in examples {
            for plain in [false, true] {
                let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
                XCTAssertTrue(page.body.contains("display:none"), source)
                XCTAssertTrue(page.body.contains("hidden"), source)
                XCTAssertTrue(page.body.contains(source.contains("| A |") ? "visible" : "after"), source)
                XCTAssertFalse(page.body.contains("&lt;span style='display:none'"), source)
            }
        }
    }

    func testStyledHTMLBlockPreservesTextAndRejectsUnsupportedStyles() throws {
        let style = try XCTUnwrap(MarkdownInlineStyle(css: "color:red"))
        let simple = "<div>before <span style='color:red'>中文</span> after</div>"
        let preview = MarkdownRenderer.renderPage(simple, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(preview.body.contains("before <span style=\"" + style.css + "\">中文</span> after"))
        let source = "<div><a id='place'></a>before <span style='color:red'>中文</span> after</div>"
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
            XCTAssertTrue(page.body.contains("before <span style=\"" + style.css + "\">中文</span> after"))
            XCTAssertFalse(page.body.contains("LACSTYLE"))
        }
        for source in ["<div><a id='place'></a><span style='position:fixed'>hidden</span></div>",
                       "<div><span style='color:red' style='color:yellow'>text</span></div>"] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
            XCTAssertTrue(page.body.contains("&lt;span"))
            XCTAssertFalse(page.body.contains("<span style=\""))
            XCTAssertFalse(page.body.contains("LACSTYLE"))
        }
    }

    func testStyledSpansInTableUseCellSourcePositions() throws {
        let source = "| Left | Right |\n| --- | --- |\n| **<span style='color:red'>中文\\|😀</span>** | neighbor |"
        let style = try XCTUnwrap(MarkdownInlineStyle(css: "color:red"))
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain)
            XCTAssertTrue(page.body.contains("<span style=\"" + style.css + "\">中文|😀</span>"))
            XCTAssertTrue(page.body.contains("neighbor"))
            let crossing = "| Left | Right |\n| --- | --- |\n| <span style='color:red'>one | two</span> |"
            XCTAssertFalse(MarkdownRenderer.renderPage(crossing, darkMode: false, includeHTMLMedia: plain).body.contains("style=\"" + style.css + "\""))
        }
        let other = MarkdownRenderer.renderPage("| x |\n| --- |\n| <kbd>key</kbd> |", darkMode: false)
        XCTAssertFalse(other.body.contains("<kbd>key</kbd>"))
    }

    func testUnsupportedInlineStyleShowsConfirmedSingleLineSource() {
        for prefix in ["", "> ", "- "] {
            for newline in ["\n", "\r\n"] {
                let paragraph = "before <span style='position:fixed'>**中文😀** ![x](https://example.invalid/x.png)</span> after"
                let source = prefix + paragraph + newline + newline + "neighbor"
                for plain in [false, true] {
                    let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain,
                        resolveLocalImages: !plain, prepareRemoteImages: !plain)
                    XCTAssertTrue(page.body.contains("&lt;span style=&quot;position:fixed&quot;&gt;") || page.body.contains("&lt;span style='position:fixed'&gt;"), source)
                    XCTAssertTrue(page.body.contains("**中文😀**"))
                    XCTAssertTrue(page.body.contains("neighbor"))
                    XCTAssertFalse(page.body.contains("LACREMOTE"))
                    XCTAssertEqual(source, prefix + paragraph + newline + newline + "neighbor")
                }
            }
        }
    }

    func testUnsupportedTableStyleShowsOnlyConfirmedCellSource() {
        for ending in ["\n", "\r\n"] {
            for prefixes in [["", "", ""], ["> ", "> ", "> "], ["- ", "  ", "  "]] {
                let rows = ["| A | B |", "| --- | --- |", "| <span style='position:fixed'>中文\\|😀</span> | neighbor |"]
                let source = zip(prefixes, rows).map { $0.0 + $0.1 }.joined(separator: ending)
                for plain in [false, true] {
                    let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
                    XCTAssertTrue(page.body.contains("&lt;span style='position:fixed'&gt;中文\\|😀&lt;/span&gt;"), source)
                    XCTAssertTrue(page.body.contains("<td>neighbor</td>"), source)
                }
            }
        }
    }

    func testUnsupportedMultilineStylePreservesProvenSource() {
        for newline in ["\n", "\r\n"] {
            let paragraph = "before <span style='position:fixed'>中文  \\" + newline + "second</span> after"
            let source = paragraph + newline + newline + "neighbor"
            for plain in [false, true] {
                let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
                XCTAssertTrue(page.body.contains("<pre>before &lt;span style='position:fixed'&gt;中文  \\" + newline + "second&lt;/span&gt; after</pre>"), source)
                XCTAssertTrue(page.body.contains("neighbor"))
                XCTAssertEqual(source, paragraph + newline + newline + "neighbor")
            }
        }
        let ambiguous = "[id]: /url\t\"title\"\n[<span style='position:fixed'>x\nend</span>\n\nneighbor"
        let page = MarkdownRenderer.renderPage(ambiguous, darkMode: false, resolveLocalImages: true)
        XCTAssertFalse(page.body.contains("<pre>[&lt;span"))
        XCTAssertTrue(page.body.contains("neighbor"))
    }

    func testUnsupportedMultilineStyleInQuoteAndListKeepsPrefixes() {
        for (first, continuation) in [(" > ", " > "), ("- ", "  "), ("> - ", ">   ")] {
            for newline in ["\n", "\r\n"] {
                let source = first + "before <span style='position:fixed'>中文" + newline + continuation + "second</span> after" + newline + newline + "neighbor"
                let expected = "<pre>before &lt;span style='position:fixed'&gt;中文" + newline + continuation + "second&lt;/span&gt; after</pre>"
                let page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true)
                XCTAssertTrue(page.body.contains(expected), source)
                XCTAssertTrue(page.body.contains("neighbor"))
            }
        }
        for first in ["> ", "- ", "> - "] {
            for ending in ["\n", "\r\n"] {
                let lazy = first + "before <span style='position:fixed'>中文😀" + ending + "second</span> after"
                let page = MarkdownRenderer.renderPage(lazy, darkMode: false, resolveLocalImages: true)
                XCTAssertTrue(page.body.contains("<pre>before &lt;span style='position:fixed'&gt;中文😀" + ending + "second&lt;/span&gt; after</pre>"), lazy)
            }
        }
        let transformed = "> - before <span style='position:fixed'>x\r\na &amp; -- \\*b\\*</span> after"
        let transformedPage = MarkdownRenderer.renderPage(transformed, darkMode: false, resolveLocalImages: true)
        XCTAssertTrue(transformedPage.body.contains("<pre>before &lt;span style='position:fixed'&gt;x\r\na &amp;amp; -- \\*b\\*&lt;/span&gt; after</pre>"))
        let tabbed = "> before <span style='position:fixed'>x\n>\tsecond</span> after"
        XCTAssertFalse(MarkdownRenderer.renderPage(tabbed, darkMode: false, resolveLocalImages: true).body.contains("<pre>before &lt;span"))
        let reference = "> [id]: /url\n> before <span style='position:fixed'>x\nsecond</span> after"
        XCTAssertFalse(MarkdownRenderer.renderPage(reference, darkMode: false, resolveLocalImages: true).body.contains("<pre>before &lt;span"))
    }

    func testUnsupportedInlineStyleDoesNotFetchImage() async throws {
        RemotePreviewURLProtocol.requests = []
        RemotePreviewURLProtocol.data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemotePreviewURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); RemotePreviewURLProtocol.requests = []; RemotePreviewURLProtocol.data = Data() }
        let address = "https://example.invalid/span.png"
        for image in ["![x](\(address))", "<img src='\(address)' alt='x'>"] {
            RemotePreviewURLProtocol.requests = []
            let unsafe = "before <span style='position:fixed'>\(image)</span> after"
            var page = MarkdownRenderer.renderPage(unsafe, darkMode: false, resolveLocalImages: true, prepareRemoteImages: true)
            try await page.resolveRemoteImages(session: session)
            XCTAssertTrue(RemotePreviewURLProtocol.requests.isEmpty)
            XCTAssertTrue(page.body.contains("&lt;span"))
            let safe = "before <span style='color:red'>\(image)</span> after"
            var valid = MarkdownRenderer.renderPage(safe, darkMode: false, resolveLocalImages: true, prepareRemoteImages: true)
            try await valid.resolveRemoteImages(session: session)
            XCTAssertEqual(RemotePreviewURLProtocol.requests, ["/span.png"])
            XCTAssertTrue(valid.body.contains("data:image/png;base64,"))
            RemotePreviewURLProtocol.requests = []
            let hidden = "before <span style='display:none'>\(image)</span> after"
            var hiddenPage = MarkdownRenderer.renderPage(hidden, darkMode: false, resolveLocalImages: true, prepareRemoteImages: true)
            try await hiddenPage.resolveRemoteImages(session: session)
            XCTAssertEqual(RemotePreviewURLProtocol.requests, ["/span.png"])
            XCTAssertTrue(hiddenPage.body.contains("display:none"))
        }
        let hidden = "https://example.invalid/hidden.png", visible = "https://example.invalid/visible.png"
        for source in ["before <span style='position:fixed'>first\n![x](\(hidden))</span> after\n\n![y](\(visible))",
                       "| Left | Right |\n| --- | --- |\n| <span style='position:fixed'>![x](\(hidden))</span> | neighbor |\n\n![y](\(visible))",
                       "> before <span style='position:fixed'>first\n![x](\(hidden))</span> after\n\n![y](\(visible))"] {
            RemotePreviewURLProtocol.requests = []
            var page = MarkdownRenderer.renderPage(source, darkMode: false, resolveLocalImages: true, prepareRemoteImages: true)
            try await page.resolveRemoteImages(session: session)
            XCTAssertEqual(RemotePreviewURLProtocol.requests, ["/visible.png"], source)
            XCTAssertTrue(page.body.contains("neighbor") || page.body.contains("after"))
        }
    }

    func testUnstyledExportPreservesPairedInlineHTMLLink() {
        let source = "Text <a href='https://example.com/?a=1&amp;b=2' title='中文'>**link**</a> end"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<a href=\"https://example.com/?a=1&amp;b=2\" title=\"中文\"><strong>link</strong></a>"))
        XCTAssertFalse(page.omittedHTML)
        for invalid in ["Text <a href='https://example.com'>link", "Text <a href='javascript:alert(1)'>link</a>", "Text <a href='https://example.com'><kbd>x</a></kbd>", "Text <a href='https://a'>outer <a href='https://b'>inner</a></a>"] {
            let result = MarkdownRenderer.renderPage(invalid, darkMode: false, includeHTMLMedia: true)
            XCTAssertFalse(result.body.contains("<a "))
            XCTAssertTrue(result.omittedHTML)
        }
        let nestedMarkdown = MarkdownRenderer.renderPage("Text <a href='https://a'>[inner](https://b)</a>", darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(nestedMarkdown.body.contains("https://a"))
        XCTAssertTrue(nestedMarkdown.body.contains("https://b"))
        XCTAssertTrue(nestedMarkdown.omittedHTML)
        let outerMarkdown = MarkdownRenderer.renderPage("Text [<a href='https://inner'>text</a>](https://outer)", darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(outerMarkdown.body.contains("https://inner"))
        XCTAssertTrue(outerMarkdown.body.contains("https://outer"))
        XCTAssertTrue(outerMarkdown.omittedHTML)
    }

    func testExportAudioRequiresConfirmedRawHTMLContext() {
        for tag in ["script", "style"] {
            let text = "<audio src=\"before.mp3\"/>\n\nbefore <\(tag)>hello\n\n<audio src=\"inside.mp3\"/>\n\n</\(tag)>\n\n<audio src=\"after.mp3\"/>"
            let page = MarkdownRenderer.renderPage(text, darkMode: false, includeHTMLMedia: true)
            XCTAssertTrue(page.body.contains("before.mp3"))
            XCTAssertFalse(page.body.contains("inside.mp3"))
            XCTAssertTrue(page.body.contains("after.mp3"))
        }
    }

    func testExportPreservesPairedAudioWithoutFallbackText() {
        let page = MarkdownRenderer.renderPage("<audio src=\"song.mp3\"></audio>", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<audio controls src=\"song.mp3\"></audio>"))
        XCTAssertFalse(page.omittedHTML)
        let uppercase = MarkdownRenderer.renderPage("<AUDIO src=\"song.mp3\"></AUDIO>", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(uppercase.body.contains("<audio controls src=\"song.mp3\"></audio>"))
        XCTAssertFalse(uppercase.omittedHTML)
        let fallback = MarkdownRenderer.renderPage("<audio src=\"song.mp3\">fallback</audio>", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(fallback.omittedHTML)
    }

    func testExportPreservesStandaloneVideoOutsideScript() {
        let page = MarkdownRenderer.renderPage("<video src=\"movie.mp4\" />", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<video controls src=\"movie.mp4\"></video>"))
        XCTAssertFalse(page.omittedHTML)
        let script = MarkdownRenderer.renderPage("before <script>\n\n<video src=\"hidden.mp4\" />\n\n</script>", darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(script.body.contains("hidden.mp4"))
        XCTAssertTrue(script.omittedHTML)
    }

    func testExportIncludesOnlyConfirmedSandboxedIframe() {
        let source = "<iframe src='//example.com/embed?a=1&amp;b=2' title='A &amp; B' style='width:100%;' height='265'></iframe>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("sandbox=\"allow-scripts\""))
        XCTAssertTrue(page.body.contains("src=\"https://example.com/embed?a=1&amp;b=2\""))
        XCTAssertTrue(page.body.contains("style=\"width:100%;height:265px;\""))
        XCTAssertFalse(page.body.contains("allow-same-origin"))
        XCTAssertFalse(page.omittedHTML)
        let fallback = MarkdownRenderer.renderPage("<iframe src='https://example.com'>Fallback <a href='https://example.com'>link</a></iframe>", darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(fallback.body.contains("Fallback <a href='https://example.com'>link</a>"))
        XCTAssertFalse(fallback.omittedHTML)
        let invalid = MarkdownRenderer.renderPage("<iframe src='file:///tmp/private.html'></iframe>", darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(invalid.body.contains("<iframe"))
        XCTAssertTrue(invalid.omittedHTML)
        let script = MarkdownRenderer.renderPage("before <script>\n\n<iframe src='https://example.com'></iframe>\n\n</script>", darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(script.body.contains("<iframe"))
        XCTAssertTrue(script.omittedHTML)
    }

    func testExportPreservesNestedSandboxedIframeInHTMLBlock() {
        let source = "<div>before <iframe src='https://example.com/embed'>fallback</iframe> after</div>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: true)
        XCTAssertTrue(page.body.contains("<iframe sandbox=\"allow-scripts\" src=\"https://example.com/embed\">fallback</iframe>"))
        XCTAssertFalse(page.omittedHTML)
    }

    func testExportDoesNotTreatScriptContentAsImage() {
        let text = "prefix <script><img src=\"fake.png\"></script> suffix\n\nText <img src=\"real.png\" alt=\"yes\">"
        let page = MarkdownRenderer.renderPage(text, darkMode: false, includeHTMLMedia: true)
        XCTAssertFalse(page.body.contains("fake.png"))
        XCTAssertTrue(page.body.contains("src=\"real.png\""))
    }

    func testExportRendersManyConfirmedHTMLImagesInTable() {
        let tags = (0..<100).map { "<img src=\"image\($0).png\" alt=\"图片 \($0)\">" }.joined(separator: " ")
        let text = "| A |\n|---|\n| 中文\\|😀 " + tags + " |"
        let page = MarkdownRenderer.renderPage(text, darkMode: false, includeHTMLMedia: true)
        for index in 0..<100 {
            XCTAssertTrue(page.body.contains("src=\"image\(index).png\""))
            XCTAssertTrue(page.body.contains("alt=\"图片 \(index)\""))
        }
    }

    func testTypographyKeepsLegacyDefaultsAndPersistsExplicitChanges() throws {
        let suite = "MarkdownTypographyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(18.0, forKey: "editorFontSize")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertNil(preferences.markdownTypography)
        let legacy = MarkdownRenderer.render("text", darkMode: false)
        XCTAssertFalse(legacy.contains("<body style="))
        preferences.editorLineSpacing = 6
        let settings = try XCTUnwrap(preferences.markdownTypography)
        XCTAssertEqual(settings.fontSize, 18)
        let expectedHeight = NSLayoutManager().defaultLineHeight(for: lacEditorFont(size: 18)) + 6
        XCTAssertEqual(settings.lineHeight, Double(expectedHeight), accuracy: 0.001)
        var page = MarkdownRenderer.renderPage("text", darkMode: false)
        page.typography = settings
        XCTAssertTrue(page.html.contains("font-size:18.0px;line-height:\(settings.lineHeight)px"))
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.markdownTypography, settings)
        restored.editorTextFontFamily = "LacEditor nonexistent font family"
        XCTAssertEqual(restored.editorTextFontFamily, "LacEditor nonexistent font family")
        XCTAssertNil(restored.markdownTypography?.textFamily)
        XCTAssertEqual(AppPreferences.textFont(family: restored.editorTextFontFamily, size: 18), lacEditorFont(size: 18))
        let unusual = MarkdownTypography(fontSize: 14, lineHeight: 18,
                                         textFamily: "name\";color:red", codeFamily: "code</style>")
        page.typography = unusual
        XCTAssertFalse(page.html.contains("name\";color:red"))
        XCTAssertFalse(page.html.contains("code</style>"))
    }


    @MainActor
    func testEditorPreferenceUpdatesPreviewWithoutChangingDocumentOrUndo() async throws {
        _ = NSApplication.shared
        let suite = "MarkdownTypographyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let manager = WindowManager(preferences: preferences, recentFiles: RecentFilesStore(defaults: defaults))
        let document = EditorDocument(text: "中文 text", language: .markdown)
        let state = manager.openNewWindow(with: document)
        let window = try XCTUnwrap(state.hostWindow)
        defer { state.closeAuxiliaryWindows(); window.delegate = nil; window.contentViewController = nil; window.close() }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let result = view as? T { return result }
            for child in view.subviews { if let result = find(type, in: child) { return result } }
            return nil
        }
        var editor: LacTextView?, preview: MarkdownWebView?
        for _ in 0..<100 {
            if let content = window.contentView {
                editor = find(LacTextView.self, in: content)
                preview = find(MarkdownWebView.self, in: content)
            }
            if editor != nil && preview != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let textView = try XCTUnwrap(editor), webView = try XCTUnwrap(preview)
        let originalFamily = textView.font?.familyName
        let family = try XCTUnwrap(NSFontManager.shared.availableFontFamilies.first {
            $0 != originalFamily && AppPreferences.availableFont(family: $0, size: 20) != nil
        })
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("X", replacementRange: textView.selectedRange())
        let selection = textView.selectedRange(), before = textView.string
        preferences.editorFontSize = 20
        preferences.editorLineSpacing = 5
        preferences.editorTextFontFamily = family
        let deadline = Date().addingTimeInterval(10)
        var fontSize = ""
        while Date() < deadline {
            fontSize = (try? await webView.evaluateJavaScript("getComputedStyle(document.body).fontSize", in: nil, contentWorld: .defaultClient) as? String) ?? ""
            if fontSize == "20px", textView.font?.pointSize == 20, textView.font?.familyName == family { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fontSize, "20px")
        XCTAssertEqual(textView.font?.pointSize, 20)
        XCTAssertEqual(textView.font?.familyName, family)
        XCTAssertEqual(textView.string, before)
        XCTAssertEqual(textView.selectedRange(), selection)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "中文 text")
    }

    func testMathPlaceholdersUseSharedTreeAndEscapeTeX() {
        let source = "# Heading $x$\n\n[link $y$](https://example.com)\n\n> $$\n> <script>alert(1)</script>\n> $$\n\n`$not_math$`\n\n| A | B |\n|---|---|\n| one | two |"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertEqual(page.formulas.map(\.source), ["x", "y", "<script>alert(1)</script>\n"])
        XCTAssertEqual(page.formulas.map(\.display), [false, false, true])
        XCTAssertTrue(page.body.contains("data-lac-math=\"0\""))
        XCTAssertTrue(page.body.contains("data-lac-math=\"2\""))
        XCTAssertTrue(page.body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(page.body.contains("<script>"))
        XCTAssertTrue(page.body.contains("<code>$not_math$</code>"))
        XCTAssertTrue(page.body.contains("<table>"))
        XCTAssertEqual(page.headingIDs.count, 1)
    }

    func testTableBreaksRenderOnlyConfirmedSafeInlineTags() {
        let source = "| A | B |\r\n| --- | --- |\r\n| 中😀a\\|b<br>one\\|two<br/>three | four<br />five |\r\n| six<BR>seven | `<br>` |\r\n| \\<br> | <script>bad()</script> |\r\n\r\noutside<br>tag"
        let body = MarkdownRenderer.renderPage(source, darkMode: false).body
        XCTAssertTrue(body.contains("中😀a|b<br>one|two<br>three"))
        XCTAssertTrue(body.contains("four<br>five"))
        XCTAssertTrue(body.contains("six<br>seven"))
        XCTAssertTrue(body.contains("&lt;br&gt;"))
        XCTAssertTrue(body.contains("<code>&lt;br&gt;</code>"))
        XCTAssertFalse(body.contains("<script>"))
        XCTAssertFalse(body.contains("outside<br>tag"))
    }

    func testSimpleUnderlineRendersOnlyConfirmedTags() {
        let body = MarkdownRenderer.renderPage("中文😀 <u>plain</u>\n\n`<u>code</u>`\n\n<script>bad()</script>", darkMode: false).body
        XCTAssertTrue(body.contains("<u>plain</u>"))
        XCTAssertTrue(body.contains("<code>&lt;u&gt;code&lt;/u&gt;</code>"))
        XCTAssertFalse(body.contains("<script>"))
        let nested = MarkdownRenderer.renderPage("<u>**bold**</u>", darkMode: false).body
        XCTAssertTrue(nested.contains("<u><strong>bold</strong></u>"))
        for source in ["<u><u>x</u></u>", "<u>before <u>x</u> tail</u>", "<u>**<u>x</u>**</u>", "<U><u>x</u></U>"] {
            XCTAssertTrue(MarkdownRenderer.renderPage(source, darkMode: false).body.contains("<u>"), source)
        }
        let attributed = MarkdownRenderer.renderPage("<u class=\"x\"><u>x</u></u>", darkMode: false).body
        XCTAssertFalse(attributed.contains("class=\"x\""))
    }
    func testSubscriptSuperscriptAndStrikethroughRenderSafely() {
        let source = "中文😀 H~2~O X^2^ ~~strike~~ `~code~ ^code^` [^link^](url)\n\n<script>bad()</script>"
        let body = MarkdownRenderer.renderPage(source, darkMode: false).body
        XCTAssertTrue(body.contains("H<sub>2</sub>O"))
        XCTAssertTrue(body.contains("X<sup>2</sup>"))
        XCTAssertTrue(body.contains("<del>strike</del>"))
        XCTAssertTrue(body.contains("<code>~code~ ^code^</code>"))
        XCTAssertFalse(body.contains("<sup>link</sup>"))
        XCTAssertFalse(body.contains("<script>"))
        let overlap = MarkdownRenderer.renderPage("==x^2^==", darkMode: false).body
        XCTAssertFalse(overlap.contains("<mark>"))
        XCTAssertFalse(overlap.contains("<sup>"))
        for source in ["~==x==~", "~x^2^~"] {
            let body = MarkdownRenderer.renderPage(source, darkMode: false).body
            XCTAssertFalse(body.contains("<sub>"), source)
            XCTAssertTrue(body.contains("<del>"), source)
        }
    }
    func testAlertsRenderFiveKindsWithoutUnsafeHTML() {
        for label in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
            let body = MarkdownRenderer.renderPage("> [!\(label)]\r\n> content **bold**\r\n\r\n<script>bad()</script>", darkMode: false).body
            XCTAssertTrue(body.contains("<aside>"), label)
            XCTAssertTrue(body.contains("<strong>\(label)</strong>"), label)
            XCTAssertTrue(body.contains("content <strong>bold</strong>"), label)
            XCTAssertFalse(body.contains("<script>"), label)
        }
        let unknown = MarkdownRenderer.renderPage("> [!UNKNOWN]\n> content", darkMode: false).body
        XCTAssertFalse(unknown.contains("<aside>"))
        XCTAssertTrue(unknown.contains("[!UNKNOWN]"))
    }
    func testSimpleFrontMatterIsOmittedWithoutChangingLaterContent() {
        let source = "---\r\ntitle: 中文😀\r\n---\r\n\r\n# Heading\r\n\r\n<script>bad()</script>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertFalse(page.body.contains("title: 中文😀"))
        XCTAssertTrue(page.body.contains("<h1>Heading</h1>"))
        XCTAssertFalse(page.body.contains("<script>"))
        XCTAssertTrue(page.headingIDs.contains("lac-heading-heading"))
        let quoted = MarkdownRenderer.renderPage("---\ntitle: \"quoted\"\n---", darkMode: false)
        XCTAssertFalse(quoted.body.contains("title:"))
        let unclosed = MarkdownRenderer.renderPage("---\ntitle: \"quoted\"", darkMode: false)
        XCTAssertTrue(unclosed.body.contains("title:"))
    }

    func testComplexFrontMatterDoesNotCreateHeadingOrTOC() {
        let source = "---\r\n标题: 中文😀\r\ndescription: |\r\n  [toc]\r\n  # hidden\r\nmap: {a: [1, 2]}\r\n# comment\r\n---\r\n\r\n# Visible"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertFalse(page.body.contains("标题"))
        XCTAssertFalse(page.body.contains("hidden"))
        XCTAssertTrue(page.body.contains("<h1>Visible</h1>"))
        XCTAssertEqual(page.headingIDs.count, 1)
    }

    func testBOMAndDotTerminatedFrontMatterIsMasked() {
        let source = "\u{feff}--- \t\r\ntitle: 中文😀\r\ndescription: |\r\n  [toc]\r\n... \t\r\n\r\n# Visible"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertFalse(page.body.contains("title:"))
        XCTAssertFalse(page.body.contains("[toc]"))
        XCTAssertTrue(page.body.contains("<h1>Visible</h1>"))
    }
    func testHighlightUsesConfirmedTextNodesWithoutEnablingRawHTML() {
        let source = "中文😀 ==one== and ==two==\n\n**==bold==**\n\n`==code==` [==link==](url)\n\n\\==escaped==\n\n<script>bad()</script>"
        let body = MarkdownRenderer.renderPage(source, darkMode: false).body
        XCTAssertTrue(body.contains("<mark>one</mark>"))
        XCTAssertTrue(body.contains("<mark>two</mark>"))
        XCTAssertTrue(body.contains("<strong><mark>bold</mark></strong>"))
        XCTAssertTrue(body.contains("<code>==code==</code>"))
        XCTAssertFalse(body.contains("<mark>link</mark>"))
        XCTAssertFalse(body.contains("<mark>escaped</mark>"))
        XCTAssertFalse(body.contains("<script>"))
    }
    func testTableOfContentsUsesSafeUniqueAnchorsAndSharedHeadingOrder() {
        let source = "[toc]\r\n\r\n# 中文😀\r\n\r\n## A\r\n\r\n# A-1\r\n\r\n# A\r\n\r\n#\r\n\r\n[go](#a)\r\n\r\n<script>alert(1)</script>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertEqual(page.headingIDs, ["lac-heading-中文", "lac-heading-a", "lac-heading-a-1", "lac-heading-a-2", "lac-heading-section"])
        XCTAssertTrue(page.body.contains("<nav aria-label="))
        XCTAssertTrue(page.body.contains("href=\"#lac-heading-a\""))
        XCTAssertTrue(page.body.contains("id=\"lac-heading-a-2\""))
        XCTAssertFalse(page.body.contains("<script>"))
        let headings = MarkdownPresentationParser.parse(source).headings
        XCTAssertEqual(headings.map(\.title), ["中文😀", "A", "A-1", "A", ""])
        for heading in headings where !heading.title.isEmpty { XCTAssertTrue(page.body.contains(heading.title)) }
        XCTAssertEqual(source, "[toc]\r\n\r\n# 中文😀\r\n\r\n## A\r\n\r\n# A-1\r\n\r\n# A\r\n\r\n#\r\n\r\n[go](#a)\r\n\r\n<script>alert(1)</script>")
    }

    func testTableOfContentsRecognizesOnlyExactTopLevelMarker() {
        for source in ["`[toc]`\n\n# H", "> [toc]\n\n# H", "- [toc]\n\n# H",
                       "\\[toc]\n\n# H", "[toc]\n\n[toc]: https://example.com\n\n# H", "[toc] text\n\n# H"] {
            XCTAssertFalse(MarkdownRenderer.renderPage(source, darkMode: false).body.contains("<nav aria-label="), source)
        }
        let noHeadings = MarkdownRenderer.renderPage("[toc]", darkMode: false)
        XCTAssertTrue(noHeadings.body.contains("<p>[toc]</p>"))
        XCTAssertFalse(noHeadings.body.contains("<nav aria-label="))
    }

    func testHeadingAnchorsDoNotCollideWithFootnotesOrUnsafeHTML() {
        let source = "[toc]\n\n# fn-a\n\n# A & B\n\n[heading](#fn-a) [unknown](#missing) note[^a]\n\n[^a]: note\n\n<script>bad()</script>"
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertTrue(page.headingIDs.contains("lac-heading-fn-a"))
        XCTAssertTrue(page.body.contains("href=\"#lac-heading-fn-a\""))
        XCTAssertTrue(page.body.contains("href=\"#fn-a\""))
        XCTAssertTrue(page.body.contains("href=\"#missing\""))
        XCTAssertTrue(page.body.contains("A &amp; B"))
        XCTAssertFalse(page.body.contains("<script>"))
    }

    func testManyRepeatedHeadingsAndOccupiedSuffixesHaveUniqueAnchors() {
        let source = "[toc]\n\n# A\n\n# A-1\n\n" + String(repeating: "# A\n\n", count: 2_000)
        let page = MarkdownRenderer.renderPage(source, darkMode: false)
        XCTAssertEqual(page.headingIDs.count, 2_002)
        XCTAssertTrue(page.headingIDs.contains("lac-heading-a"))
        XCTAssertTrue(page.headingIDs.contains("lac-heading-a-1"))
        XCTAssertTrue(page.headingIDs.contains("lac-heading-a-2"))
        XCTAssertTrue(page.headingIDs.contains("lac-heading-a-2001"))
    }
    func testCommonMarkBlocksAndLooseLists() {
        let html = MarkdownRenderer.render(
            """
            标题
            ====

            > 第一段
            >
            > 第二段

            1) 第一项

               第一项的续行段落。

            2) 第二项
               - 子项
                 跨行内容
            """,
            darkMode: false
        )

        XCTAssertTrue(html.contains("<h1>标题</h1>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<p>第一段</p>"))
        XCTAssertTrue(html.contains("<p>第二段</p>"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<p>第一项</p>"))
        XCTAssertTrue(html.contains("<p>第一项的续行段落。</p>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("子项"))
        XCTAssertTrue(html.contains("跨行内容"))
    }

    func testGFMExtensionsAndEscapedTableCells() {
        let html = MarkdownRenderer.render(
            """
            | 名称 | 状态 |
            | :--- | ---: |
            | Lac \\| Editor | ~~旧值~~ |

            - [x] 已完成
            - [ ] 未完成

            https://example.com/path
            """,
            darkMode: false
        )

        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("Lac | Editor"))
        XCTAssertTrue(html.contains("<del>旧值</del>"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("checked=\"\""))
        XCTAssertTrue(html.contains("href=\"https://example.com/path\""))
    }

    func testInlineMarkupEscapingAndRawHTMLSafety() {
        let html = MarkdownRenderer.render(
            """
            `**保持原样** [链接](https://example.com)`

            [带下划线的链接](https://example.com/foo_bar_baz)

            <script>alert('blocked')</script>

            [危险链接](javascript:alert(1))
            """,
            darkMode: false
        )

        XCTAssertTrue(html.contains("<code>**保持原样** [链接](https://example.com)</code>"))
        XCTAssertTrue(html.contains("href=\"https://example.com/foo_bar_baz\""))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
    }

    func testCRLFAndUnicodeContent() {
        let html = MarkdownRenderer.render(
            "第一行\r\n第二行 😀",
            darkMode: false
        )
        XCTAssertTrue(html.contains("第一行"))
        XCTAssertTrue(html.contains("第二行 😀"))
        XCTAssertFalse(html.contains("第一行<br />\n<br />"))
    }

    func testSingleNewlineRendersAsVisibleBreak() {
        let html = MarkdownRenderer.render("第一行\n第二行", darkMode: false)
        XCTAssertTrue(html.contains("第一行<br") || html.contains("第一行\n第二行"))
        XCTAssertFalse(html.contains("<p>第一行 第二行</p>"))
    }

    func testHardBreaksDoNotDamageCodeBlocksOrLists() {
        let html = MarkdownRenderer.render(
            """
            - 第一项
              续行

            ```js
            const value = 1;
            console.log(value);
            ```
            """,
            darkMode: false
        )
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("const value = 1;"))
        XCTAssertTrue(html.contains("console.log(value);"))
    }

    func testMarkdownRenderingPerformanceGate() {
        let markdown = String(
            repeating: "## 标题\n\n段落包含 **强调** 和 [链接](https://example.com)。\n\n",
            count: 2_000
        )
        let start = ProcessInfo.processInfo.systemUptime
        let html = MarkdownRenderer.render(markdown, darkMode: false)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertTrue(html.contains("<h2>标题</h2>"))
        XCTAssertLessThan(elapsed, 5, "Markdown rendering took \(elapsed)s")
    }
}
