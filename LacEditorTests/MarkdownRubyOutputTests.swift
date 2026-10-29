import AppKit
import WebKit
import XCTest
@testable import LacEditor

@MainActor
private final class RubyOutputNavigation: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation
    init(_ finished: XCTestExpectation) { self.finished = finished }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
}

@MainActor
final class MarkdownRubyOutputTests: XCTestCase {
    func testStyledRubyBaseKeepsStylesAcrossEditorPreviewAndCopy() throws {
        for ruby in ["<ruby><strong>漢</strong><em>字</em><rt>kan</rt></ruby>",
                     "<ruby>**漢**<span style='color:red'>字</span><rt>kan</rt></ruby>"] {
            let source = "before " + ruby + " after"
            let parsed = MarkdownPresentationParser.parse(source)
            let item = try XCTUnwrap(parsed.ruby.first, ruby)
            XCTAssertEqual(item.base, "漢字")
            XCTAssertEqual(item.baseRuns.map(\.range), [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])
            XCTAssertTrue(item.baseRuns[0].bold)
            if ruby.contains("<em>") { XCTAssertTrue(item.baseRuns[1].italic) }
            else { XCTAssertNotNil(item.baseRuns[1].foreground) }
            let range = (source as NSString).range(of: ruby)
            let copied = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: range))
            XCTAssertEqual(copied.text, "漢字kan")
            XCTAssertTrue(copied.html.contains("<strong>漢</strong>"))
            XCTAssertTrue(copied.hasUnverifiedHTMLBlocks)
            for plain in [false, true] {
                let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
                XCTAssertTrue(page.body.contains("<ruby>"), ruby)
                XCTAssertTrue(page.body.contains("<strong>漢</strong>"), ruby)
                XCTAssertTrue(page.body.contains("<rt>kan</rt>"), ruby)
            }
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: (source as NSString).range(of: "漢")))
        }
    }

    func testStyledRubyRejectsCrossingAndUnsupportedReading() {
        for ruby in ["<ruby><strong>**a</strong><em>b**</em><rt>x</rt></ruby>",
                     "<ruby><span style='background:yellow'>漢</span><rt>kan</rt></ruby>",
                     "<ruby><strong>漢</strong><rt><em>kan</em></rt></ruby>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(ruby).ruby.isEmpty, ruby)
            XCTAssertNil(MarkdownClipboardCopyService.project(ruby, selection: NSRange(location: 0, length: (ruby as NSString).length)), ruby)
        }
    }

    func testRubyRejectsUnsupportedOuterStyles() throws {
        let ruby = "<ruby><strong>漢</strong><rt>kan</rt></ruby>"
        for (opening, closing) in [("<span style='background:yellow'>", "</span>"),
                                   ("<span style='font-size:2rem'>", "</span>"),
                                   ("<u>", "</u>"), ("<mark>", "</mark>"), ("<s>", "</s>")] {
            let source = opening + ruby + closing
            XCTAssertTrue(MarkdownPresentationParser.parse(source).ruby.isEmpty, source)
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: (source as NSString).range(of: ruby)), source)
            let page = MarkdownRenderer.renderPage(source, darkMode: false)
            XCTAssertTrue(page.body.contains("&lt;ruby&gt;"), source)
        }
        let supported = "<strong><span style='color:red'>" + ruby + "</span></strong>"
        let presentation = MarkdownPresentationParser.parse(supported)
        XCTAssertEqual(presentation.ruby.count, 1)
        let item = try XCTUnwrap(presentation.ruby.first)
        XCTAssertTrue(presentation.spans.contains { $0.kind == .strong && NSIntersectionRange($0.range, item.range) == item.range })
        XCTAssertTrue(presentation.spans.contains { if case .inlineStyle(let style) = $0.kind { return style.foreground != nil && NSIntersectionRange($0.range, item.range) == item.range }; return false })
        let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(supported, selection: (supported as NSString).range(of: ruby)))
        XCTAssertTrue(copy.html.contains("<strong><ruby>"))
        XCTAssertTrue(copy.html.components(separatedBy: "<ruby>").first?.contains("color:") == true)
        let page = MarkdownRenderer.renderPage(supported, darkMode: false)
        XCTAssertTrue(page.body.contains("<strong><span style="))
        XCTAssertTrue(page.body.components(separatedBy: "<ruby>").first?.contains("color:") == true)
        for source in ["<u><br>" + ruby + "</u>", "<u>" + ruby + "<br></u>",
                       "<u><span>" + ruby + "</span></u>"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source).ruby.isEmpty, source)
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: (source as NSString).range(of: ruby)), source)
        }
    }

    func testStyledRubyInsideQuoteKeepsQuoteRange() throws {
        let ruby = "<ruby><strong>漢</strong><rt>kan</rt></ruby>"
        let source = "> " + ruby
        let parsed = MarkdownPresentationParser.parse(source)
        let item = try XCTUnwrap(parsed.ruby.first)
        let quote = try XCTUnwrap(parsed.spans.first { $0.kind == .quote })
        XCTAssertEqual((source as NSString).substring(with: item.range), ruby)
        XCTAssertEqual(NSIntersectionRange(quote.range, item.range), item.range)
    }
    func testRubyCopyRefusesPartialOrUnprovenContentsWithoutBlockingNeighbors() {
        for ruby in ["<ruby class='x'>漢<rt>kan</rt></ruby>", "<ruby>漢<rt>kan</rt>",
                     "<ruby>漢<rt><b>kan</b></rt></ruby>", "<ruby>漢<rt>kan</ruby></rt>"] {
            let source = "before " + ruby + "\n\nafter"
            let text = source as NSString
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: text.range(of: "漢")), ruby)
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: text.range(of: "kan")), ruby)
            XCTAssertEqual(MarkdownClipboardCopyService.project(source, selection: text.range(of: "before"))?.text, "before", ruby)
        }
        let source = "before <ruby>漢<rt>kan</rt></ruby> after" as NSString
        for part in ["漢", "kan", "<ruby>", "</ruby>"] {
            XCTAssertNil(MarkdownClipboardCopyService.project(source as String, selection: source.range(of: part)), part)
        }
        for ruby in ["<ruby>:smile:<rt>kan</rt></ruby>", "<ruby>漢<rt>:smile:</rt></ruby>",
                     "<ruby>==漢==<rt>kan</rt></ruby>", "<ruby>漢<rt>^kan^</rt></ruby>"] {
            XCTAssertNil(MarkdownClipboardCopyService.project(ruby, selection: NSRange(location: 0, length: (ruby as NSString).length)), ruby)
        }
    }

    func testSpacedRubyCopiesConfirmedVisibleText() throws {
        for (source, expected) in [("<ruby> 漢 <rt> ㄏㄢˋ </rt> </ruby>", "漢 ㄏㄢˋ"),
                                   ("<ruby> A   B <rt> x  y </rt> </ruby>", "A B x y"),
                                   ("<ruby>漢&nbsp;<rt> kan </rt> </ruby>", "漢\u{a0} kan")] {
            let raw = source as NSString
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: raw.length)))
            XCTAssertEqual(copy.text, expected)
            XCTAssertTrue(copy.hasUnverifiedHTMLBlocks)
            XCTAssertTrue(copy.html.contains("<ruby>"))
            XCTAssertNil(MarkdownClipboardCopyService.project(source, selection: raw.range(of: "<rt>")))
        }
        let ambiguous = "X<ruby> 漢 <rt> kan </rt> </ruby>Y" as NSString
        XCTAssertNil(MarkdownClipboardCopyService.project(ambiguous as String, selection: ambiguous.range(of: "<ruby> 漢 <rt> kan </rt> </ruby>")))
    }

    func testSpacedRubyMatchesWebKitSelection() async throws {
        _ = NSApplication.shared
        let source = "<ruby> 漢 <rt> ㄏㄢˋ </rt> </ruby>"
        let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: NSRange(location: 0, length: (source as NSString).length)))
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain, resolveLocalImages: !plain)
            let loaded = expectation(description: "spaced ruby loaded")
            let navigation = RubyOutputNavigation(loaded)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
            web.navigationDelegate = navigation
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            web.loadHTMLString("<!doctype html><meta charset='utf-8'><article>" + page.body + "</article>", baseURL: nil)
            await fulfillment(of: [loaded], timeout: 10)
            let selected = try await web.evaluateJavaScript("(() => { const r=document.querySelector('ruby'); if (!r) return null; const s=getSelection(), q=document.createRange(); q.selectNodeContents(r); s.removeAllRanges(); s.addRange(q); return s.toString(); })()")
            XCTAssertEqual(selected as? String, copy.text)
        }
    }

    func testRubyCopyKeepsReadingAndOmitsParenthesisFallback() throws {
        for (ruby, visible) in [
            ("<ruby>漢<rt>kan</rt></ruby>", "漢kan"),
            ("<ruby>漢<rp>(</rp><rt>kan</rt><rp>)</rp></ruby>", "漢kan"),
            ("<ruby>文😀<rp>（</rp><rt>wén &amp; reading</rt><rp>）</rp></ruby>", "文😀wén & reading")
        ] {
            let source = "before " + ruby + " after"
            let range = (source as NSString).range(of: ruby)
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: range))
            XCTAssertEqual(copy.text, visible)
            XCTAssertTrue(copy.html.contains("<ruby>"))
            XCTAssertTrue(copy.html.contains("<rt>"))
            XCTAssertTrue(copy.hasUnverifiedHTMLBlocks)
            let whole = try XCTUnwrap(MarkdownClipboardCopyService.project(source,
                selection: NSRange(location: 0, length: (source as NSString).length)))
            XCTAssertEqual(whole.text, "before " + visible + " after")
        }
    }

    func testRubyOutputMatchesWebKitSelectionInStyledAndPlainHTML() async throws {
        _ = NSApplication.shared
        for ruby in ["<ruby>文😀<rp>(</rp><rt>wén &amp; reading</rt><rp>)</rp></ruby>",
                     "<ruby><strong>文</strong><span style='color:red'>😀</span><rp>(</rp><rt>wén &amp; reading</rt><rp>)</rp></ruby>"] {
        let source = "before " + ruby + " after"
        let selected = (source as NSString).range(of: ruby)
        for plain in [false, true] {
            let page = MarkdownRenderer.renderPage(source, darkMode: false, includeHTMLMedia: plain,
                                                   resolveLocalImages: !plain)
            let loaded = expectation(description: "ruby output loaded")
            let navigation = RubyOutputNavigation(loaded)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 240), configuration: configuration)
            web.navigationDelegate = navigation
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web; window.makeKeyAndOrderFront(nil)
            defer { web.stopLoading(); web.navigationDelegate = nil; window.close() }
            web.loadHTMLString("<!doctype html><meta charset='utf-8'><article>" + page.body + "</article>", baseURL: nil)
            await fulfillment(of: [loaded], timeout: 10)
            let result = try await web.evaluateJavaScript("""
                (() => {
                    const ruby = document.querySelector('ruby');
                    if (!ruby || ruby.querySelectorAll('rt').length !== 1) return null;
                    const range = document.createRange(); range.selectNodeContents(ruby);
                    const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
                    return { selected: selection.toString(), text: ruby.textContent,
                             fallbackHidden: [...ruby.querySelectorAll('rp')].every(x => getComputedStyle(x).display === 'none') };
                })()
                """, in: nil, contentWorld: .defaultClient)
            let values = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(values["selected"] as? String, "文😀wén & reading")
            XCTAssertEqual(values["text"] as? String, "文😀(wén & reading)")
            XCTAssertEqual(values["fallbackHidden"] as? Bool, true)
            let copy = try XCTUnwrap(MarkdownClipboardCopyService.project(source, selection: selected))
            XCTAssertEqual(copy.text, values["selected"] as? String)
        }
        }
    }
}
