import AppKit
import cmark_gfm
import WebKit
import XCTest
@testable import LacEditor

final class MarkdownHTMLMediaServiceTests: XCTestCase {
    func testTwitterWidgetAcceptsOnlyDocumentedMarkup() throws {
        for host in ["twitter.com", "x.com"] {
            let source = "<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">Sunsets 中文 <a href=\"https://t.co/example\">link</a></p>&mdash; User <a href=\"https://\(host)/Interior/status/463440424141459456?ref_src=twsrc%5Etfw\">May 5, 2014</a></blockquote>\n<script async src=\"https://platform.twitter.com/widgets.js\" charset=\"utf-8\"></script>"
            let widget = try XCTUnwrap(MarkdownHTMLMediaService.twitterWidget(source))
            XCTAssertEqual(widget.id, "463440424141459456")
            XCTAssertEqual(widget.iframeURL, "https://platform.twitter.com/embed/Tweet.html?id=463440424141459456&dnt=true")
            XCTAssertTrue(widget.text.contains("Sunsets 中文"))
            let proof = MarkdownMathExtension.withDocument(source) { root, ext, _ -> Bool in
                guard let node = cmark_node_first_child(root), let pointer = cmark_node_get_literal(node) else { return false }
                let literal = String(cString: pointer) as NSString
                var end = literal.length
                while end > 0 && [9, 10, 12, 13, 32].contains(Int(literal.character(at: end - 1))) { end -= 1 }
                let candidate = MarkdownHTMLMediaService.TwitterProofCandidate(node: node, start: 0, end: end, widget: widget)
                let accepted = MarkdownHTMLMediaService.provenTwitter(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                    text: source as NSString, candidates: [candidate], isCancelled: { false })
                return accepted == Set([0]) && cmark_node_get_literal(node).map { String(cString: $0) } == literal as String
            }
            XCTAssertEqual(proof, true)
            for invalid in [source.replacingOccurrences(of: "class=\"twitter-tweet\"", with: "class=\"twitter-tweet\" class=\"x\""),
                            source.replacingOccurrences(of: "<script async", with: "<script onclick=\"x()\" async"),
                            source.replacingOccurrences(of: "widgets.js", with: "evil.js"),
                            source.replacingOccurrences(of: "</script>", with: "alert(1)</script>"),
                            source + "<p>extra</p>"] {
                XCTAssertNil(MarkdownHTMLMediaService.twitterWidget(invalid), invalid)
            }
            XCTAssertNil(MarkdownHTMLMediaService.twitterWidget(source, isCancelled: { true }))
        }
    }

    func testSVGMarkersProveSameDOMAndRestoreLiterals() throws {
        let source = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let result = MarkdownMathExtension.withDocument(source) { root, ext, _ -> Bool in
            guard let paragraph = cmark_node_first_child(root), let opening = cmark_node_first_child(paragraph),
                  let closing = cmark_node_last_child(paragraph), let pointer = cmark_node_get_literal(closing) else { return false }
            let original = String(cString: pointer)
            let candidate = MarkdownHTMLMediaService.SVGProofCandidate(opening: opening, openingOffset: 0, closing: closing,
                closingOffset: (original as NSString).length, literal: source)
            let accepted = MarkdownHTMLMediaService.provenSVG(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                text: source as NSString, candidates: [candidate], isCancelled: { false })
            let mismatch = MarkdownHTMLMediaService.SVGProofCandidate(opening: opening, openingOffset: 0, closing: closing,
                closingOffset: (original as NSString).length, literal: source.replacingOccurrences(of: "red", with: "black"))
            let rejected = MarkdownHTMLMediaService.provenSVG(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                text: source as NSString, candidates: [mismatch], isCancelled: { false })
            let trailing = MarkdownHTMLMediaService.SVGProofCandidate(opening: opening, openingOffset: 0, closing: closing,
                closingOffset: (original as NSString).length, literal: source + "extra")
            let extra = MarkdownHTMLMediaService.provenSVG(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                text: source as NSString, candidates: [trailing], isCancelled: { false })
            return accepted == Set([0]) && rejected.isEmpty && extra.isEmpty && cmark_node_get_literal(closing).map { String(cString: $0) } == original
        }
        XCTAssertEqual(result, true)
    }

    func testRichDetailsRequiresSupportedContents() throws {
        let source = "<details open><summary><strong>More &amp; 中文</strong></summary><em>Body</em> <a href='https://example.com'>link</a></details>"
        let details = try XCTUnwrap(MarkdownHTMLMediaService.richDetails(source))
        XCTAssertTrue(details.initiallyOpen)
        XCTAssertEqual(details.summary, "More & 中文")
        XCTAssertTrue(details.summaryHTML.contains("<strong>"))
        XCTAssertTrue(details.bodyHTML.contains("href="))
        for invalid in ["<details><summary>x</summary><table><tr><td>y</td></tr></table></details>",
                        "<details><summary>x</summary><script>y</script></details>",
                        "<details><summary>x</summary><span style='position:fixed'>y</span></details>",
                        "<details><summary>x</summary><details><summary>y</summary></details></details>"] {
            XCTAssertNil(MarkdownHTMLMediaService.richDetails(invalid), invalid)
        }
        XCTAssertNil(MarkdownHTMLMediaService.richDetails(source, isCancelled: { true }))
    }

    func testPlainDetailsRequiresMatchingSourceAndDOM() throws {
        let source = "<details><summary>More &amp; 中文</summary>Body 😀</details>"
        let value = try XCTUnwrap(MarkdownHTMLMediaService.plainDetails(source))
        XCTAssertEqual(value.summary, "More & 中文")
        XCTAssertEqual(value.body, "Body 😀")
        XCTAssertEqual(MarkdownHTMLMediaService.detailsDisplayText(" a \u{301}b\u{a0}c\r\n "), "a \u{301}b\u{a0}c")
        XCTAssertNil(MarkdownHTMLMediaService.detailsDisplayText("中\r\n文"))
        XCTAssertNil(MarkdownHTMLMediaService.detailsDisplayText("text", isCancelled: { true }))
        for invalid in ["<details open><summary>More</summary>Body</details>",
                        "<details><summary>More</summary><b>Body</b></details>",
                        "<details><summary class='x'>More</summary>Body</details>"] {
            XCTAssertNil(MarkdownHTMLMediaService.plainDetails(invalid))
        }
        let proved = MarkdownMathExtension.withDocument(source) { root, ext, _ -> Bool in
            guard let node = cmark_node_first_child(root) else { return false }
            return MarkdownHTMLMediaService.provenDetails(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                text: source as NSString, candidates: [(node, 0, value.summary, value.body)], isCancelled: { false }).contains(node)
        }
        XCTAssertEqual(proved, true)
    }

    func testTextMarkersRequireExactSafeDOMText() throws {
        for (source, accepted) in [("<div>before <strong>bold</strong> after</div>", true),
                                   ("<select>bold</select>", false), ("<div>b&amp;old</div>", true)] {
            let value = source.contains("&amp;") ? "b&amp;old" : "bold"
            let range = (source as NSString).range(of: value)
            let result = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, ext, _ -> [Int: MarkdownHTMLMediaService.ProvenText]? in
                guard let node = cmark_node_first_child(root), cmark_node_get_type(node) == CMARK_NODE_HTML_BLOCK else { return nil }
                let candidate = MarkdownHTMLMediaService.TextProofCandidate(node: node, start: range.location,
                    end: NSMaxRange(range), text: value)
                return MarkdownHTMLMediaService.provenTextStyles(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                    text: source as NSString, candidates: [candidate], isCancelled: { false })
            } ?? nil)
            XCTAssertEqual(result[0] != nil, accepted, source)
            if source.contains("<strong>") { XCTAssertEqual(result[0]?.styles, ["strong"]) }
            if source.contains("&amp;") { XCTAssertEqual(result[0]?.text, "b&old") }
        }
    }
    func testPairedMediaProofUsesRenderedDOMAndRestoresTree() throws {
        let source = "before <video controls><source src='a.mp4'>fallback **bold**</video> after"
        let expected = try XCTUnwrap(MarkdownHTMLMediaService.embeddedMedia(in: "<video controls><source src='a.mp4'>fallback **bold**</video>"))
        let result = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, ext, _ -> (Set<Int>, String)? in
            guard let paragraph = cmark_node_first_child(root) else { return nil }
            var child = cmark_node_first_child(paragraph), opening: OpaquePointer?, closing: OpaquePointer?
            while let node = child {
                if cmark_node_get_type(node) == CMARK_NODE_HTML_INLINE, let pointer = cmark_node_get_literal(node) {
                    let value = String(cString: pointer)
                    if value.hasPrefix("<video") { opening = node }
                    if value == "</video>" { closing = node }
                }
                child = cmark_node_next(node)
            }
            guard let opening, let closing, let literal = cmark_node_get_literal(closing) else { return nil }
            let candidate = MarkdownHTMLMediaService.MediaProofCandidate(openingNode: opening, openingOffset: 0,
                closingNode: closing, closingOffset: (String(cString: literal) as NSString).length, expected: .media(expected))
            let accepted = MarkdownHTMLMediaService.provenMediaIndices(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                text: source as NSString, candidates: [candidate], isCancelled: { false })
            guard let restored = cmark_node_get_literal(opening) else { return nil }
            return (accepted, String(cString: restored))
        } ?? nil)
        XCTAssertEqual(result.0, Set([0]))
        XCTAssertEqual(result.1, "<video controls>")
    }

    func testPairedMediaProofRejectsInertAndChangedFrames() throws {
        let expectedVideo = try XCTUnwrap(MarkdownHTMLMediaService.embeddedMedia(in: "<video src='a.mp4'></video>"))
        let expectedFrame = try XCTUnwrap(MarkdownHTMLMediaService.iframe(in: "<iframe src='https://example.invalid'>original</iframe>"))
        func accepted(_ source: String, name: String, expected: MarkdownHTMLMediaService.ProvenMedia, duplicate: Bool = false) throws -> Set<Int> {
            try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, ext, _ -> Set<Int>? in
                guard let paragraph = cmark_node_first_child(root) else { return nil }
                var opening: OpaquePointer?, closing: OpaquePointer?, child = cmark_node_first_child(paragraph)
                while let node = child {
                    if cmark_node_get_type(node) == CMMARK_NODE_HTML_INLINE, let pointer = cmark_node_get_literal(node) {
                        let value = String(cString: pointer)
                        if value.hasPrefix("<" + name) { opening = node }
                        if value == "</" + name + ">" { closing = node }
                    }
                    child = cmark_node_next(node)
                }
                guard let opening, let closing, let pointer = cmark_node_get_literal(closing) else { return nil }
                let candidate = MarkdownHTMLMediaService.MediaProofCandidate(openingNode: opening, openingOffset: 0,
                    closingNode: closing, closingOffset: (String(cString: pointer) as NSString).length, expected: expected)
                return MarkdownHTMLMediaService.provenMediaIndices(root: root, mathExtension: ext, options: CMARK_OPT_DEFAULT,
                    text: source as NSString, candidates: duplicate ? [candidate, candidate] : [candidate], isCancelled: { false })
            } ?? nil)
        }
        XCTAssertTrue(try accepted("before <select><video src='a.mp4'></video></select> after", name: "video", expected: .media(expectedVideo)).isEmpty)
        XCTAssertTrue(try accepted("before <template><video src='a.mp4'></video></template> after", name: "video", expected: .media(expectedVideo)).isEmpty)
        XCTAssertTrue(try accepted("before <video src='a.mp4'></video> after", name: "video", expected: .media(expectedVideo), duplicate: true).isEmpty)
        XCTAssertTrue(try accepted("before <iframe src='https://example.invalid/other'>original</iframe> after", name: "iframe", expected: .frame(expectedFrame)).isEmpty)
        XCTAssertTrue(try accepted("before <iframe src='https://example.invalid'>changed</iframe> after", name: "iframe", expected: .frame(expectedFrame)).isEmpty)
        XCTAssertTrue(try accepted("before <iframe src='https://example.invalid' title='changed'>original</iframe> after", name: "iframe", expected: .frame(expectedFrame)).isEmpty)
    }

    func testInlineAndNestedMediaUseExactSourceRanges() {
        let source = "中文😀 before <video controls><source src='a.mp4'>fallback **bold**</video> after\r\n\r\ntext <iframe src='https://example.invalid'>fallback</iframe> end\r\n\r\n<div>before <audio src='sound.wav'></audio> after</div>"
        let text = source as NSString
        let presentation = MarkdownPresentationParser.parse(source)
        XCTAssertEqual(presentation.audioBlocks.count, 2)
        XCTAssertEqual(presentation.audioBlocks.map { text.substring(with: $0.range) }, ["<video controls><source src='a.mp4'>fallback **bold**</video>", "<audio src='sound.wav'></audio>"])
        XCTAssertTrue(presentation.audioBlocks.allSatisfy(\.isInline))
        XCTAssertEqual(presentation.iframeBlocks.map { text.substring(with: $0.range) }, ["<iframe src='https://example.invalid'>fallback</iframe>"])
        XCTAssertTrue(presentation.iframeBlocks.allSatisfy(\.isInline))
        XCTAssertTrue(presentation.iframeBlocks.first?.html.contains(">fallback</iframe>") == true)
        XCTAssertTrue(presentation.iframeBlocks.first?.html.contains("sandbox=\"allow-scripts\"") == true)
        let inert = "before <select><video src='hidden.mp4'></video></select> and <template><audio src='hidden.wav'></audio></template> after"
        let rejected = MarkdownPresentationParser.parse(inert)
        XCTAssertTrue(rejected.audioBlocks.isEmpty)
        XCTAssertTrue(rejected.iframeBlocks.isEmpty)
        let split = "before <video src='a.mp4'>\n\ntext\n\n</video> after"
        XCTAssertTrue(MarkdownPresentationParser.parse(split).audioBlocks.isEmpty)
        let fallback = "before <video src='a.mp4'><img src='fallback.png'></video> after"
        let fallbackPresentation = MarkdownPresentationParser.parse(fallback)
        XCTAssertEqual(fallbackPresentation.audioBlocks.count, 1)
        XCTAssertTrue(fallbackPresentation.images.isEmpty)
        let standalone = "<video src='a.mp4'><img src='fallback.png'></video>"
        let standalonePresentation = MarkdownPresentationParser.parse(standalone)
        XCTAssertEqual(standalonePresentation.audioBlocks.count, 1)
        XCTAssertTrue(standalonePresentation.images.isEmpty)
        let audioFallback = "before <audio src='a.wav'><img src='fallback.png'></audio> after"
        let audioFallbackPresentation = MarkdownPresentationParser.parse(audioFallback)
        XCTAssertEqual(audioFallbackPresentation.audioBlocks.count, 1)
        XCTAssertTrue(audioFallbackPresentation.images.isEmpty)
        let objectFallback = "before <object data='movie.mp4'><img src='fallback.png'></object> after"
        XCTAssertTrue(MarkdownPresentationParser.parse(objectFallback).images.isEmpty)
        XCTAssertEqual(try? MarkdownImageUploadService.images(in: objectFallback).map(\.address), ["fallback.png"])
        let mixedFallback = "before <video src='a.mp4'>![x](x.png) $x$ :smile:</video> after :smile:"
        let mixedPresentation = MarkdownPresentationParser.parse(mixedFallback, includeEmojiCandidates: true)
        XCTAssertEqual(mixedPresentation.audioBlocks.count, 1)
        XCTAssertTrue(mixedPresentation.images.isEmpty)
        XCTAssertTrue(mixedPresentation.inlineFormulas.isEmpty)
        XCTAssertEqual(mixedPresentation.emojiCandidates.count, 1)
    }
    func testImageSizingKeepsProportionsAndAppliesZoomBeforeFit() {
        let intrinsic = CGSize(width: 200, height: 100)
        func size(_ width: String? = nil, _ height: String? = nil, _ style: String? = nil) -> CGSize? {
            MarkdownHTMLMediaService.ImageSizing(width: width, height: height, style: style)
                .size(intrinsic: intrinsic, availableWidth: 100)
        }
        XCTAssertEqual(size(), CGSize(width: 100, height: 50))
        XCTAssertEqual(size("40"), CGSize(width: 40, height: 20))
        XCTAssertEqual(size(nil, "20px"), CGSize(width: 40, height: 20))
        XCTAssertEqual(size("80", "20"), CGSize(width: 80, height: 20))
        XCTAssertEqual(size("50%"), CGSize(width: 50, height: 25))
        XCTAssertEqual(size(nil, "50%"), CGSize(width: 100, height: 50))
        XCTAssertEqual(size("80", nil, "width:40px; zoom:50%"), CGSize(width: 20, height: 10))
        XCTAssertEqual(size("80", nil, "zoom:2"), CGSize(width: 100, height: 50))
        XCTAssertEqual(size("80", nil, "zoom:0"), CGSize(width: 80, height: 40))
        XCTAssertEqual(size("80", nil, "zoom:2; zoom:0"), CGSize(width: 80, height: 40))
        XCTAssertEqual(size("0"), CGSize.zero)
        XCTAssertEqual(size("40", "0"), CGSize(width: 40, height: 0))
        XCTAssertEqual(size("40", nil, "width:invalid; color:red"), CGSize(width: 40, height: 20))
        XCTAssertEqual(size("40", nil, "width:80"), CGSize(width: 40, height: 20))
        XCTAssertEqual(size("40", nil, "width:0"), CGSize.zero)
        XCTAssertNil(size("1" + String(repeating: "0", count: 308), "1", "zoom:10"))
        let sizing = MarkdownHTMLMediaService.ImageSizing(width: "80", height: nil, style: "width:50%; height:20px; zoom:50%; background:url(https://example.invalid)")
        XCTAssertEqual(sizing.css, "width:50.0%;height:20.0px;zoom:0.5;")
    }

    func testConfirmedHTMLImageReadsDecodedAttributesAndSizing() throws {
        let image = try XCTUnwrap(MarkdownHTMLMediaService.displayImage(in: "<IMG\n SRC=\"a&amp;b.png\" alt='中文' width=80 style='width:50%;zoom:50%;color:red'>"))
        XCTAssertEqual(image.source, "a&b.png")
        XCTAssertEqual(image.alt, "中文")
        XCTAssertEqual(image.sizing.size(intrinsic: CGSize(width: 200, height: 100), availableWidth: 100), CGSize(width: 25, height: 12.5))
        XCTAssertNil(MarkdownHTMLMediaService.displayImage(in: "<img src='a'><img src='b'>"))
        XCTAssertNil(MarkdownHTMLMediaService.displayImage(in: "<img>"))
    }

    func testImageMarkersRequireActualAdjacentImage() throws {
        let assembled = MarkdownHTMLMediaService.insertingMarkers(in: "😀ab", insertions: [(3, "B"), (2, "A")], isCancelled: { false })
        XCTAssertEqual(assembled, "😀AaBb")
        XCTAssertNil(MarkdownHTMLMediaService.insertingMarkers(in: "abc", insertions: [(1, "A"), (1, "B")], isCancelled: { false }))
        let html = "<p><select><!--hidden--><img src='x.png'></select><!--visible--><img src='a&amp;b.png'></p>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.confirmedImageMarkers(in: html, expected: ["hidden": "x.png", "visible": "a&b.png"], isCancelled: { false }))
        XCTAssertEqual(result, Set(["visible"]))
        let style = try XCTUnwrap(MarkdownInlineStyle(css: "color:red"))
        let owners: [MarkdownHTMLMediaService.ImageAncestor] = [.init(name: "div", style: nil), .init(name: "span", style: style), .init(name: "strong", style: nil)]
        let nested = "<div><span style='color:red'><strong><!--image--><img src='a'></strong></span></div>"
        XCTAssertEqual(try XCTUnwrap(MarkdownHTMLMediaService.confirmedImageMarkers(in: nested, expected: ["image": "a"], ancestors: ["image": owners], isCancelled: { false })), Set(["image"]))
        let mismatch = "<div><span style='color:yellow'><strong><!--image--><img src='a'></strong></span></div>"
        XCTAssertTrue(try XCTUnwrap(MarkdownHTMLMediaService.confirmedImageMarkers(in: mismatch, expected: ["image": "a"], ancestors: ["image": owners], isCancelled: { false })).isEmpty)
        let duplicate = "<!--one--><img src='a'><!--one--><img src='a'>"
        XCTAssertTrue(try XCTUnwrap(MarkdownHTMLMediaService.confirmedImageMarkers(in: duplicate, expected: ["one": "a"], isCancelled: { false })).isEmpty)
        XCTAssertNil(MarkdownHTMLMediaService.confirmedImageMarkers(in: html, expected: ["visible": "a&b.png"], isCancelled: { true }))
        let marker = MarkdownHTMLMediaService.ExportImageMarker(source: "a&b.png", address: "a%26b.png")
        let rendered = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<div>before<!--visible--><img src='a&amp;b.png' width='80' style='height:20px;background:url(x)'>after<video src='v'></video></div>", imageMarkers: ["visible": marker], imageOnly: true, resolveImage: { "data:,\($0)" }))
        XCTAssertTrue(rendered.html.contains("before<img"))
        XCTAssertTrue(rendered.html.contains("data:,a%26b.png"))
        XCTAssertTrue(rendered.html.contains("height:20.0px"))
        XCTAssertTrue(rendered.html.contains("after"))
        XCTAssertFalse(rendered.html.contains("background:"))
        XCTAssertFalse(rendered.html.contains("<video"))
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock("<div><!--visible--><img src='other.png'></div>", imageMarkers: ["visible": marker]))
    }
    func testCenteredMarkdownImageAndSafeHTML() throws {
        let markdown = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<center>![中文](image%23one.png \"title\")</center>"))
        XCTAssertEqual(markdown.html, "<center><img src=\"image%23one.png\" alt=\"中文\" title=\"title\"></center>")
        let resolved = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<center>![x](https://example.invalid/x.png)</center>", resolveImage: { _ in "data:image/png;base64,YQ==" }))
        XCTAssertTrue(resolved.html.contains("src=\"data:image/png;base64,YQ==\""))
        let html = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<center><strong>text</strong><img src='x.png'></center>"))
        XCTAssertEqual(html.html, "<center><strong>text</strong><img src=\"x.png\"></center>")
        let reference = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<center>![x][outside]</center>"))
        XCTAssertFalse(reference.html.contains("<img"))
        let localReference = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<center>![x][id]\n\n[id]: /image.png</center>"))
        XCTAssertFalse(localReference.html.contains("<img"))
        XCTAssertTrue(localReference.html.contains("[id]: /image.png"))
        let mixed = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<center>before ![x](x.png)</center>"))
        XCTAssertFalse(mixed.html.contains("<img"))
        var cancelled = false
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock("<center>![x](x.png)</center>", isCancelled: { cancelled }, resolveImage: { _ in
            cancelled = true
            return nil
        }))
    }
    func testExportBlockKeepsOnlyVerifiedMediaAndResolvesItsSource() throws {
        let original = "<video controls src='movie.mp4'>fallback</video>"
        let media = try XCTUnwrap(MarkdownHTMLMediaService.embeddedMedia(in: original))
        let markers: [String: MarkdownHTMLMediaService.ProvenMedia] = ["LACM0": .media(media)]
        let html = "<div>before <!--LACM0O-->\(original)<!--LACM0C--> after</div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(html, mediaMarkers: markers, imageOnly: true,
                                                                        resolveMedia: { _ in "data:video/mp4;base64,AQ==#t=2" }))
        XCTAssertTrue(result.html.contains("before "))
        XCTAssertTrue(result.html.contains(" after"))
        XCTAssertTrue(result.html.contains("data:video/mp4;base64,AQ==#t=2"))
        XCTAssertTrue(result.html.contains("fallback"))
        XCTAssertFalse(result.html.contains("LACM0"))
        let moved = "<div><!--LACM0O-->\(original) text<!--LACM0C--></div>"
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock(moved, mediaMarkers: markers, imageOnly: true))
        let changed = "<div><!--LACM0O--><video src='other.mp4'></video><!--LACM0C--></div>"
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock(changed, mediaMarkers: markers, imageOnly: true))
        let inert = "<template><!--LACM0O-->\(original)<!--LACM0C--></template>"
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock(inert, mediaMarkers: markers, imageOnly: true))
        let frame = try XCTUnwrap(MarkdownHTMLMediaService.iframe(in: "<iframe src='https://example.invalid/embed'>fallback</iframe>"))
        let markedFrame = "<div><!--LACM1O--><iframe src='https://example.invalid/embed'>fallback</iframe><!--LACM1C--></div>"
        let renderedFrame = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(markedFrame, mediaMarkers: ["LACM1": .frame(frame)], imageOnly: true))
        XCTAssertTrue(renderedFrame.html.contains("sandbox=\"allow-scripts\""))
        let localFrame = "<div><!--LACM1O--><iframe src='file:///tmp/test.html'>fallback</iframe><!--LACM1C--></div>"
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock(localFrame, mediaMarkers: ["LACM1": .frame(frame)], imageOnly: true))
    }

    func testExportBlockAcceptsOnlyVerifiedAnchorMarkers() throws {
        let marker = "lac-anchor-test", expected = [marker: ["中文&x"]]
        let valid = "<div>before<span id='lac-anchor-test'></span><a id='中文&amp;x'>target</a>after</div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(valid, anchorMarkers: expected))
        XCTAssertTrue(result.html.contains("before<span id=\"lac-anchor-test\"></span><a>target</a>after"))
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock("<div><span id='lac-anchor-test'></span><a id='other'></a></div>", anchorMarkers: expected))
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock("<div><span id='lac-anchor-test'></span><b>x</b><a id='中文&amp;x'></a></div>", anchorMarkers: expected))
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock("<div><span id='lac-anchor-test'></span><a id='中文&amp;x'></a><span id='lac-anchor-test'></span><a id='中文&amp;x'></a></div>", anchorMarkers: expected))
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock("<div></div>", anchorMarkers: expected))
        let distinct = "<span id='lac-anchor-test'></span><a id='é' name='e\u{301}'></a>"
        XCTAssertNotNil(MarkdownHTMLMediaService.exportBlock(distinct, anchorMarkers: [marker: ["é", "e\u{301}"]]))
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock(distinct, anchorMarkers: [marker: ["é"]]))
    }
    func testExportFragmentsRespectOverridesEmptyValuesAndExtra() {
        var options = MarkdownHTMLExportOptions()
        options.appendHead = "global head"
        options.appendBody = "global body"
        let values = ["append-head": "ordinary", "typora-append-head": "", "append-head-extra": "<meta content=\"${title}\">",
                      "append-body": "doc body", "typora-append-body-extra": " extra", "title": "A & B"]
        let disabled = MarkdownHTMLMediaService.exportFragments(options: options, variables: values)
        XCTAssertEqual(disabled.head, "global head")
        XCTAssertEqual(disabled.body, "global body")
        options.allowDocumentOverrides = true
        let enabled = MarkdownHTMLMediaService.exportFragments(options: options, variables: values)
        XCTAssertEqual(enabled.head, "<meta content=\"A &amp; B\">")
        XCTAssertEqual(enabled.body, "doc body extra")
    }

    func testExportVariablesOnlyChangeMetaAttributes() {
        let html = """
        <meta name="title" content="${title}">
        <META data-value=${value}>
        <!-- <meta content="${title}"> -->
        <script>let fake = '<meta content="${title}">';</script>
        <style>/* <meta content="${title}"> */</style>
        <p title="${title}">${title}</p>
        <meta content="${missing}">
        """
        let actual = MarkdownHTMLMediaService.substituteMetaVariables(in: html,
            variables: ["title": "中文 \"'&<> 😀", "value": "a b=1`x"])
        XCTAssertTrue(actual.contains("content=\"中文 &quot;&#39;&amp;&lt;&gt; 😀\""))
        XCTAssertTrue(actual.contains("data-value=a&#32;b&#61;1&#96;x"))
        XCTAssertTrue(actual.contains("<!-- <meta content=\"${title}\"> -->"))
        XCTAssertTrue(actual.contains("let fake = '<meta content=\"${title}\">'"))
        XCTAssertTrue(actual.contains("<p title=\"${title}\">${title}</p>"))
        XCTAssertTrue(actual.contains("<meta content=\"${missing}\">"))
        let boundaries = "<meta:foo content=\"${title}\"><meta! content=\"${title}\"><script:foo><meta content=\"${title}\"><script>ignored</script/><meta content=\"${title}\">"
        let converted = MarkdownHTMLMediaService.substituteMetaVariables(in: boundaries, variables: ["title": "done"])
        XCTAssertTrue(converted.contains("<meta:foo content=\"${title}\">"))
        XCTAssertTrue(converted.contains("<meta! content=\"${title}\">"))
        XCTAssertEqual(converted.components(separatedBy: "content=\"done\"").count - 1, 2)
        let doubleEscaped = "<script><!--<script></script><meta content=${title}>--></script><meta content=\"${title}\">"
        XCTAssertEqual(MarkdownHTMLMediaService.substituteMetaVariables(in: doubleEscaped, variables: ["title": "injected"]), doubleEscaped)
        let deceptiveEnd = "<script><!-- </scriptx> <script></script><meta content=\"${title}\">--></script>"
        XCTAssertEqual(MarkdownHTMLMediaService.substituteMetaVariables(in: deceptiveEnd, variables: ["title": "injected"]), deceptiveEnd)
        for prefix in ["<!-- text --!>", "<!-->", "<!--->"] {
            let result = MarkdownHTMLMediaService.substituteMetaVariables(in: prefix + "<meta content=\"${title}\">", variables: ["title": "done"])
            XCTAssertTrue(result.hasSuffix("<meta content=\"done\">"))
        }
    }

    func testStandaloneAudioSourcePreservesUnicodeAndDecodesXMLEntities() {
        XCTAssertEqual(MarkdownHTMLMediaService.audioSource(in: "<audio src=\"声音/песня 🎵.mp3\" />\r\n"),
                       "声音/песня 🎵.mp3")
        XCTAssertEqual(MarkdownHTMLMediaService.audioSource(in: "  <audio\tsrc='a&amp;b&#x20;c.mp3'/>  "),
                       "a&b c.mp3")
        XCTAssertEqual(MarkdownHTMLMediaService.audioSource(in: "<audio src='file:///tmp/song.mp3' />"),
                       "file:///tmp/song.mp3")
        XCTAssertEqual(MarkdownHTMLMediaService.audioSource(in: "<audio src='a&#x9;b.mp3'/>"), "a\tb.mp3")
    }

    func testUnsupportedFormsRemainSource() {
        for source in [
            "<audio src='song.mp3'>", "<audio src='song.mp3'></audio>",
            "<audio src='song.mp3' controls/>", "<audio src='song.mp3' onload='alert(1)'/>",
            "<audio><source src='song.mp3'/></audio>", "<video src='movie.mp4'/>",
            "<Audio src='song.mp3'/>", "<audio src=''/>", "<audio src=song.mp3/>",
            "<audio src='one.mp3' src='two.mp3'/>", "<audio src='one.mp3'/><audio src='two.mp3'/>",
            "<audio\nsrc='song.mp3'/>", "<audio src='a&b.mp3'/>", "<audio src='a\tb.mp3'/>",
            "<!DOCTYPE audio [<!ENTITY file SYSTEM 'file:///etc/passwd'>]><audio src='&file;'/>",
            "<!-- comment --><audio src='song.mp3'/>", "<audio src='song.mp3'/><!-- comment -->",
            "<audio src='song.mp3'><!-- comment --></audio>"
        ] {
            XCTAssertNil(MarkdownHTMLMediaService.audioSource(in: source), source)
        }
    }

    func testExportRecognizesPairedAudioWithoutDiscardingFallbackText() {
        XCTAssertEqual(MarkdownHTMLMediaService.audioSource(in: "<audio src='song.mp3'></audio>", allowPaired: true), "song.mp3")
        XCTAssertEqual(MarkdownHTMLMediaService.audioSource(in: "<AUDIO src='song.mp3'></AUDIO>", allowPaired: true), "song.mp3")
        XCTAssertNil(MarkdownHTMLMediaService.audioSource(in: "<audio src='song.mp3'>fallback</audio>", allowPaired: true))
    }

    func testExportRecognizesDocumentedStandaloneVideo() {
        XCTAssertEqual(MarkdownHTMLMediaService.videoSource(in: "<video src='movie.mp4' />"), "movie.mp4")
        XCTAssertNil(MarkdownHTMLMediaService.videoSource(in: "<video src='movie.mp4'>fallback</video>"))
    }

    func testEmbeddedAudioAndVideoUseHTMLSourcesAndAttributes() throws {
        let audio = try XCTUnwrap(MarkdownHTMLMediaService.embeddedMedia(in: "<AUDIO controls>\n<source src='声音&amp;一.ogg' type='audio/ogg'><source src=two.mp3>fallback</AUDIO>"))
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(audio.sources, ["声音&一.ogg", "two.mp3"])
        XCTAssertTrue(audio.controls)
        let video = try XCTUnwrap(MarkdownHTMLMediaService.embeddedMedia(in: "<video src='main.mp4' width='50%' height=240><source src='ignored.mp4'></video>"))
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.sources, ["main.mp4"])
        XCTAssertEqual(video.width, "50%")
        XCTAssertEqual(video.height, "240")
        XCTAssertFalse(video.controls)
        XCTAssertEqual(MarkdownHTMLMediaService.embeddedMedia(in: "<video src='movie.mp4' />")?.controls, true)
        for source in ["<video controls></video>", "<video src='a.mp4' width='bad'></video>", "<video src='a.mp4' width='1e2'></video>", "<audio onplay='x' src='a.mp3'></audio>", "<audio><source src=''></audio>", "<audio><img src='a.png'></audio>"] {
            XCTAssertNil(MarkdownHTMLMediaService.embeddedMedia(in: source), source)
        }
    }

    func testVideoInsertionUsesImagePathRulesAndUTF16() throws {
        let document = URL(fileURLWithPath: "/tmp/project/note.md")
        let file = URL(fileURLWithPath: "/tmp/project/视频 #\".mp4")
        let text = "😀 tail"
        let edit = try XCTUnwrap(MarkdownHTMLMediaService.videoInsertion(file: file, document: document, text: text, location: 2))
        XCTAssertEqual(edit.range, NSRange(location: 2, length: 0))
        XCTAssertTrue(edit.replacement.contains("<video src=\"%E8%A7%86%E9%A2%91%20%23%22.mp4\" />"))
        XCTAssertTrue(edit.replacement.hasPrefix("\n\n"))
        XCTAssertTrue(edit.replacement.hasSuffix("\n\n"))
        XCTAssertEqual(edit.selectionRange.location, 2 + (edit.replacement as NSString).length)
        XCTAssertNil(MarkdownHTMLMediaService.videoInsertion(file: file, document: document, text: text, location: 1))
        let unsaved = try XCTUnwrap(MarkdownHTMLMediaService.videoInsertion(file: file, document: nil, text: "", location: 0))
        XCTAssertTrue(unsaved.replacement.contains("file:///"))
        XCTAssertFalse(unsaved.replacement.contains("\n"))
        let crlf = try XCTUnwrap(MarkdownHTMLMediaService.videoInsertion(file: file, document: document, text: "a\r\nb", location: 4))
        XCTAssertTrue(crlf.replacement.hasPrefix("\r\n\r\n"))
    }

    func testConfirmedIframeParsesHTMLAttributesWithoutLoadingNetwork() throws {
        let source = "<iframe height='265' scrolling='no' title='Fancy &amp; 中文' src='//example.com/embed?a=1&amp;b=2' frameborder='no' allowtransparency='true' allowfullscreen='true' style='width: 100%;'>Fallback <a href='https://example.com'>link</a></iframe>"
        let frame = try XCTUnwrap(MarkdownHTMLMediaService.iframe(in: source))
        XCTAssertEqual(frame.source.absoluteString, "https://example.com/embed?a=1&b=2")
        XCTAssertEqual(frame.width, "100%")
        XCTAssertEqual(frame.height, "265")
        XCTAssertEqual(frame.title, "Fancy & 中文")
        XCTAssertTrue(frame.allowsFullscreen)
        XCTAssertEqual(frame.scrolling, "no")
        XCTAssertEqual(frame.frameBorder, "no")
        XCTAssertEqual(frame.allowTransparency, "true")
        XCTAssertEqual(frame.fallback, "Fallback <a href='https://example.com'>link</a>")
        let html = MarkdownHTMLMediaService.iframeHTML(frame)
        XCTAssertTrue(html.contains("sandbox=\"allow-scripts allow-presentation\""))
        XCTAssertFalse(html.contains("allow-same-origin"))
        XCTAssertTrue(html.contains("src=\"https://example.com/embed?a=1&amp;b=2\""))
        XCTAssertTrue(html.contains("style=\"width:100%;height:265px;\""))
        XCTAssertTrue(html.contains("Fallback <a href='https://example.com'>link</a>"))
    }

    @MainActor
    func testIframeFallbackRetainsBrowserRawText() async throws {
        _ = NSApplication.shared
        let source = "<iframe src='https://example.invalid'>A &amp; B <a href='https://example.invalid'>link</a></iframe>"
        let frame = try XCTUnwrap(MarkdownHTMLMediaService.iframe(in: source))
        let output = MarkdownHTMLMediaService.iframeHTML(frame)
        let html = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\"><div id=original>" + source + "</div><div id=result>" + output + "</div>"
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.loadHTMLString(html, baseURL: nil)
        var values: [String]?
        for _ in 0..<100 {
            if let result = try? await view.evaluateJavaScript("Array.from(document.querySelectorAll('iframe'), e => e.textContent)", in: nil, contentWorld: .defaultClient) as? [String], result.count == 2 {
                values = result
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let found = try XCTUnwrap(values)
        XCTAssertEqual(found[0], found[1])
        XCTAssertEqual(found[0], "A &amp; B <a href='https://example.invalid'>link</a>")
    }

    func testIframeRejectsLocalCodeAndAmbiguousContent() {
        for source in [
            "<iframe src='file:///tmp/private.html'></iframe>",
            "<iframe src='javascript:alert(1)'></iframe>",
            "<iframe src='data:text/html,hello'></iframe>",
            "<iframe src='https://'></iframe>",
            "<iframe src='https://example.com' onload='alert(1)'></iframe>",
            "<iframe src='https://example.com' sandbox='allow-same-origin'></iframe>",
            "before <iframe src='https://example.com'></iframe>",
            "<iframe src='https://example.com' style='position:fixed'></iframe>"
        ] { XCTAssertNil(MarkdownHTMLMediaService.iframe(in: source), source) }
    }

    func testExportBlockUsesHTMLSemanticsAndReportsOmissions() throws {
        let source = "<div>A &copy;<br><img SRC=photo.png ALT='' title='A &amp; B'><script>alert(1)</script><b style='color:red' onclick='evil()'>Text</b></div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(source))
        XCTAssertTrue(result.html.contains("A ©<br>"))
        XCTAssertTrue(result.html.contains("<img src=\"photo.png\" alt=\"\" title=\"A &amp; B\">"))
        XCTAssertFalse(result.html.contains("style="))
        XCTAssertTrue(result.html.contains("Text</b>"))
        XCTAssertFalse(result.html.contains("alert(1)"))
        XCTAssertFalse(result.html.contains("onclick"))
        XCTAssertTrue(result.omitted)
        let details = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<details><summary>Question?</summary>Answer.</details>"))
        XCTAssertTrue(details.html.contains("<summary>Question?</summary>"))
        XCTAssertFalse(details.omitted)
        let unstyled = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<div style='display:none;background:url(https://example.invalid/x)'>VISIBLE</div>"))
        XCTAssertTrue(unstyled.html.contains("VISIBLE"))
        XCTAssertFalse(unstyled.html.contains("style="))
        XCTAssertFalse(unstyled.html.contains("example.invalid"))
    }

    func testInlineStyleOpeningRequiresOneExactAttribute() throws {
        let parsed = try XCTUnwrap(MarkdownHTMLMediaService.inlineStyleOpening("<SPAN style='color:&#114;ed; font-size:2rem'>"))
        XCTAssertEqual(parsed, MarkdownInlineStyle(css: "color:red;font-size:2rem"))
        XCTAssertNotNil(MarkdownHTMLMediaService.inlineStyleOpening("<span style=color:red>"))
        for input in ["<span style='color:red' style='color:yellow'>", "<span style='color:red' title='x'>",
                      "<span style='color:blue'>", "<span style='background:url(x)'>", "<span style='color:red'/>",
                      "<span style='color:red'>extra"] {
            XCTAssertNil(MarkdownHTMLMediaService.inlineStyleOpening(input), input)
        }
        XCTAssertNil(MarkdownHTMLMediaService.inlineStyleOpening("<span style='color:red'>", isCancelled: { true }))
    }

    func testPageBreakRequiresExactEmptyDivAndSafeStyle() {
        for html in ["<div style=\"page-break-after:always\"></div>",
                     "<DIV style='page-break-after: always; break-after: page;'></DIV>"] {
            XCTAssertTrue(MarkdownHTMLMediaService.isPageBreak(html), html)
        }
        for html in ["<div style='page-break-after:always' style='break-after:page'></div>",
                     "<div style='page-break-after:always' title='x'></div>",
                     "<div style='page-break-after:always;color:red'></div>",
                     "<div style='page-break-after:always;page-break-after:always'></div>",
                     "<div style='break-after:page'></div>", "<div style='page-break-after:always'>x</div>",
                     "<div style='page-break-after:always'></div><script>x</script>"] {
            XCTAssertFalse(MarkdownHTMLMediaService.isPageBreak(html), html)
        }
        XCTAssertFalse(MarkdownHTMLMediaService.isPageBreak("<div style='page-break-after:always'></div>", isCancelled: { true }))
    }

    func testPageBreakDOMProofRequiresExactDecodedStyle() throws {
        let source = "<div style='page-break-after: always'></div>"
        let checked = try XCTUnwrap(MarkdownMathExtension.withDocument(source) { root, extensionNode, _ -> Bool in
            guard let node = cmark_node_first_child(root), let literal = cmark_node_get_literal(node) else { return false }
            let original = String(cString: literal)
            let accepted = MarkdownHTMLMediaService.provenPageBreaks(root: root, mathExtension: extensionNode, options: 0,
                text: source as NSString, candidates: [(node, 0, "page-break-after: always")], isCancelled: { false })
            let changed = MarkdownHTMLMediaService.provenPageBreaks(root: root, mathExtension: extensionNode, options: 0,
                text: source as NSString, candidates: [(node, 0, "page-break-after:always")], isCancelled: { false })
            return accepted.contains(node) && changed.isEmpty && cmark_node_get_literal(node).map { String(cString: $0) } == original
        })
        XCTAssertTrue(checked)
    }

    func testExportBlockProvesStyledSpansAndFallsBackForUnsupportedStyles() throws {
        let source = "<div>before <span style='color:&#114;ed'>red <span style='font-size:2rem;background:yellow'>中文</span></span> after<script><span style='color:red'>hidden</span></script></div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(source, fallbackSource: source))
        let red = try XCTUnwrap(MarkdownInlineStyle(css: "color:red"))
        let inner = try XCTUnwrap(MarkdownInlineStyle(css: "font-size:2rem;background:yellow"))
        XCTAssertTrue(result.html.contains("<span style=\"" + red.css + "\">red <span style=\"" + inner.css + "\">中文</span></span>"))
        XCTAssertTrue(result.html.contains("before "))
        XCTAssertTrue(result.html.contains(" after"))
        XCTAssertFalse(result.html.contains("hidden"))
        XCTAssertFalse(result.html.contains("LACSTYLE"))
        for source in ["<div><span style='position:fixed'>hidden</span></div>",
                       "<div><span style='color:red' style='color:yellow'>x</span></div>"] {
            let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(source, fallbackSource: source))
            XCTAssertTrue(result.sourceFallback)
            XCTAssertTrue(result.html.contains("&lt;span"))
            XCTAssertFalse(result.html.contains("<span"))
            XCTAssertNil(MarkdownHTMLMediaService.exportBlock(source))
        }
    }

    func testExportBlockKeepsDisplayNoneOnlyForConfirmedStyle() throws {
        let source = "<div>before <span style='color:red;display:none'>hidden <span style='background:yellow'>nested</span></span> after</div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(source, fallbackSource: source))
        XCTAssertFalse(result.sourceFallback)
        XCTAssertTrue(result.html.contains("display:none"))
        XCTAssertTrue(result.html.contains("hidden"))
        XCTAssertTrue(result.html.contains("after"))
        let unsupported = "<div><span style='display:none;position:fixed'>text</span></div>"
        XCTAssertTrue(try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(unsupported, fallbackSource: unsupported)).sourceFallback)
    }

    func testExportBlockCancelsDuringDOMTraversal() {
        let html = "<div>" + String(repeating: "<span>text</span>", count: 100) + "</div>"
        var checks = 0
        XCTAssertNil(MarkdownHTMLMediaService.exportBlock(html, isCancelled: {
            checks += 1
            return checks > 20
        }))
        XCTAssertGreaterThan(checks, 20)
    }

    func testExportBlockPreservesNestedSandboxedIframe() throws {
        let source = "<div>before <iframe src='https://example.com/embed' title='Example'>Fallback <a href='https://example.com'>link</a></iframe> after</div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(source))
        XCTAssertTrue(result.html.contains("before <iframe sandbox=\"allow-scripts\""))
        XCTAssertTrue(result.html.contains("Fallback <a href='https://example.com'>link</a></iframe> after"))
        XCTAssertFalse(result.omitted)
        let blocked = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<div><iframe src='file:///tmp/private'></iframe>safe</div>"))
        XCTAssertFalse(blocked.html.contains("<iframe"))
        XCTAssertTrue(blocked.html.contains("safe"))
        XCTAssertTrue(blocked.omitted)
    }

    func testExportBlockKeepsCheckboxAndDropsUnsupportedInput() throws {
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<div><input type=checkbox checked> Task <input type=text></div>"))
        XCTAssertTrue(result.html.contains("<input type=\"checkbox\" checked> Task"))
        XCTAssertFalse(result.html.contains("type=\"text\""))
        XCTAssertTrue(result.omitted)
    }

    func testExportBlockDoesNotActivateInertTemplateContent() throws {
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock("<div><template><img src='hidden.png'></template><img src='visible.png'></div>"))
        XCTAssertFalse(result.html.contains("hidden.png"))
        XCTAssertTrue(result.html.contains("visible.png"))
        XCTAssertTrue(result.omitted)
    }

    func testExportBlockPreservesStructuralHTMLAttributes() throws {
        let source = "<div><details open><summary>More</summary>text</details><ol start=5 reversed><li value=4>one</li></ol><table><tr><th scope=col colspan=2>Head</th></tr></table></div>"
        let result = try XCTUnwrap(MarkdownHTMLMediaService.exportBlock(source))
        XCTAssertTrue(result.html.contains("<details open>"))
        XCTAssertTrue(result.html.contains("<ol start=\"5\" reversed>"))
        XCTAssertTrue(result.html.contains("<li value=\"4\">one</li>"))
        XCTAssertTrue(result.html.contains("<th scope=\"col\" colspan=\"2\">Head</th>"))
        XCTAssertFalse(result.omitted)
    }
}
