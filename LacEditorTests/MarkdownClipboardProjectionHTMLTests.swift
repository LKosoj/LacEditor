import Foundation
import XCTest
@testable import LacEditor

/// HTML-блоки в проекторе выделения на модели (U4.5.4): details, svg, twitter, media, вложенный HTML, картинки.
/// Ожидания совпадают с `MarkdownClipboardCopyTests`.
final class MarkdownClipboardProjectionHTMLTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    private func project(_ source: String, _ selection: NSRange, includeImages: Bool = false, allowRemoteImages: Bool = false, documentURL: URL? = nil,
                         detailsOpenOverrides: [NSRange: Bool] = [:]) -> MarkdownClipboardCopyService.Fragment? {
        MarkdownClipboardCopyService.project(source, selection: selection, includeImages: includeImages, documentURL: documentURL, allowRemoteImages: allowRemoteImages,
                                                      detailsOpenOverrides: detailsOpenOverrides)
    }

    /// Проверка и кодирование картинок идут через ImageIO; на Linux-стенде его нет, поэтому положительные проверки с картинками там пропускаются.
    private func requireImageSupport() throws {
        let data = try XCTUnwrap(Data(base64Encoded: png))
        try XCTSkipUnless((try? MarkdownImageUploadService.payload(data: data)) != nil, "нет ImageIO (стенд Linux)")
    }

    private func whole(_ source: String) -> NSRange { NSRange(location: 0, length: (source as NSString).length) }

    func testWholeDetailsCopyKeepsSummaryBodyAndOpenOverride() throws {
        for (details, expected) in [("<details><summary>More</summary><strong>Body</strong></details>", "More"),
                                    ("<details open><summary>More</summary><strong>Body 中文</strong><br>Next</details>", "More\nBody 中文\nNext")] {
            let source = ("before\n\n" + details + "\n\nafter") as NSString
            let range = source.range(of: details)
            let result = try XCTUnwrap(project(source as String, range), details)
            XCTAssertEqual(result.text, expected, details)
            XCTAssertTrue(result.html.contains("<details"), details)
            XCTAssertTrue(result.html.contains("<strong>Body"), details)
            XCTAssertTrue(result.hasUnverifiedHTMLBlocks, details)
            XCTAssertNil(project(source as String, source.range(of: "Body")), "часть details даёт nil: \(details)")
            let initialOpen = details.hasPrefix("<details open>")
            let toggled = try XCTUnwrap(project(source as String, range, detailsOpenOverrides: [range: !initialOpen]), details)
            XCTAssertEqual(toggled.text, initialOpen ? "More" : "More\nBody", details)
            XCTAssertEqual(toggled.html.contains("<details open"), !initialOpen, details)
        }
    }

    func testSVGBlockCopyNeedsWholeSelectionAndImages() throws {
        let svg = "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        for source in [svg, "before\n\n" + svg + "\n\nпосле 中文"] {
            let range = (source as NSString).range(of: svg)
            XCTAssertNil(project(source, NSRange(location: range.location, length: range.length - 1), includeImages: true), "часть svg: \(source)")
            XCTAssertNil(project(source, range, includeImages: false), "без includeImages: \(source)")
        }
        try requireImageSupport()
        for source in [svg, "before\n\n" + svg + "\n\nпосле 中文"] {
            let result = try XCTUnwrap(project(source, (source as NSString).range(of: svg), includeImages: true), source)
            XCTAssertTrue(result.html.contains("data:image/svg+xml;base64,"), source)
        }
    }

    func testTwitterWidgetCopyRequiresWholeBlock() throws {
        let widget = "<blockquote class='twitter-tweet'><p lang='en' dir='ltr'>Sunsets 中文</p>&mdash; User <a href='https://twitter.com/Interior/status/463440424141459456?ref_src=twsrc%5Etfw'>May 5, 2014</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>"
        let source = ("before\n\n" + widget + "\n\nafter") as NSString
        let only = try XCTUnwrap(project(source as String, source.range(of: widget)))
        XCTAssertEqual(only.text, "")
        XCTAssertTrue(only.hasUnverifiedHTMLBlocks)
        XCTAssertTrue(only.html.contains("sandbox=\"allow-scripts\""))
        XCTAssertTrue(only.html.contains("platform.twitter.com/embed/Tweet.html?id=463440424141459456"))
        XCTAssertFalse(only.html.contains("widgets.js"))
        let all = try XCTUnwrap(project(source as String, whole(source as String)))
        XCTAssertTrue(all.text.contains("before") && all.text.contains("after"))
        XCTAssertNil(project(source as String, source.range(of: "Sunsets 中文")), "часть виджета")
    }

    func testStandaloneSelfClosingMediaIsAtomic() throws {
        for tag in ["<audio src='https://example.invalid/a/b.wav' />", "<video src='https://example.invalid/a/b.mp4' />"] {
            let source = ("before\n\n" + tag + "\n\nafter") as NSString
            let range = source.range(of: tag)
            let result = try XCTUnwrap(project(source as String, range), tag)
            XCTAssertEqual(result.text, "", tag)
            XCTAssertTrue(result.hasUnverifiedHTMLBlocks, tag)
            XCTAssertTrue(result.html.contains("https://example.invalid/a/b."), tag)
            XCTAssertNil(project(source as String, NSRange(location: range.location, length: range.length - 1)), "часть тега: \(tag)")
        }
    }

    func testPairedMediaBlockCopyKeepsDOMAndRejectsPart() throws {
        let video = "<video src=\"https://example.invalid/a.mp4\" controls>\n<source src=\"https://example.invalid/b.mp4\" type=\"video/mp4\">\nfallback &amp; 中文\n</video>"
        let source = ("before\n\n" + video + "\n\nafter") as NSString
        let only = try XCTUnwrap(project(source as String, source.range(of: video)))
        XCTAssertEqual(only.text, "")
        XCTAssertTrue(only.hasUnverifiedHTMLBlocks)
        XCTAssertTrue(only.html.contains("<video"))
        XCTAssertTrue(only.html.contains("https://example.invalid/b.mp4"))
        XCTAssertNil(project(source as String, source.range(of: "fallback")), "часть медиа")
        XCTAssertNil(project(source as String, NSRange(location: source.range(of: video).location, length: 5)), "часть тега")
    }

    func testNestedHTMLBlockCopyPreservesBlockBoundaries() throws {
        for (source, expected) in [
            ("<div>a<div><strong>中文😀</strong></div>c</div>", "a\n中文😀\nc\n"),
            ("<div>a<p>b</p>c</div>", "a\nb\n\nc\n"),
            ("<div><div>a</div><div>b</div></div>", "a\nb\n"),
            ("<div>a<div></div>b</div>", "a\nb"),
            ("<div>中文😀\r\n<div>b</div>\r\nc</div>", "中文😀\nb\nc\n")
        ] {
            let copy = try XCTUnwrap(project(source, whole(source)), source)
            XCTAssertEqual(copy.text, expected, source)
            XCTAssertTrue(copy.html.contains("<div>"), source)
        }
    }

    func testPartialNestedHTMLBlockUsesSelectionBoundaries() throws {
        let source = "<div>AA<div>BB</div><p>CC</p>DD</div>" as NSString
        for (start, end, expected) in [("AA", "BB", "A\nB"), ("BB", "CC", "B\nC"), ("BB", "DD", "B\nCC\n\nD"), ("AA", "DD", "A\nBB\nCC\n\nD")] {
            let lower = source.range(of: start).location + 1, upper = source.range(of: end).location + 1
            let fragment = try XCTUnwrap(project(source as String, NSRange(location: lower, length: upper - lower)), "\(start)-\(end)")
            XCTAssertEqual(fragment.text, expected, "\(start)-\(end)")
            XCTAssertTrue(fragment.hasUnverifiedHTMLBlocks, "\(start)-\(end)")
        }
        XCTAssertNil(project(source as String, NSRange(location: 1, length: 2)), "часть тега")
    }

    func testStyledSpanInHTMLBlockUsesConfirmedDOM() throws {
        let source = "<div>before <span style='color:red'>red <span style='background:yellow;font-size:2rem'>中文😀</span></span> after</div>" as NSString
        let result = try XCTUnwrap(project(source as String, whole(source as String)))
        let range = (result.text as NSString).range(of: "中文😀")
        let run = try XCTUnwrap(result.runs.first { NSIntersectionRange($0.range, range).length > 0 })
        XCTAssertEqual(run.inlineStyle?.foreground, MarkdownSRGBColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(run.inlineStyle?.background, MarkdownSRGBColor(red: 1, green: 1, blue: 0))
        XCTAssertEqual(run.inlineStyle?.fontSize, 32)
        XCTAssertTrue(result.html.contains("font-size:2.0rem"))
        let unsupported = "<div><span style='position:fixed'>hidden</span></div>"
        XCTAssertNil(project(unsupported, whole(unsupported)), "неподдерживаемый стиль")
        XCTAssertNil(project(source as String, NSRange(location: source.range(of: "<span").location, length: 3)), "часть тега span")
    }

    func testHTMLImageInBlockCopiesSelectedResource() throws {
        let tag = "<img src='data:image/png;base64,\(png)' alt='中文' width='20'>"
        let block = "<div>before \(tag) after</div>"
        XCTAssertNil(project(block, (block as NSString).range(of: tag), includeImages: false), "без includeImages")
        try requireImageSupport()
        let selected = try XCTUnwrap(project(block, (block as NSString).range(of: tag), includeImages: true))
        XCTAssertEqual(selected.text, "中文")
        XCTAssertTrue(selected.html.contains("data:image/png;base64," + png))
        XCTAssertFalse(selected.html.contains("before"))
        XCTAssertFalse(selected.html.contains("after"))
        let quote = "> <div>\r\n> 中文 \(tag) after\r\n> </div>"
        let quoteImage = try XCTUnwrap(project(quote, (quote as NSString).range(of: tag), includeImages: true))
        XCTAssertEqual(quoteImage.text, "中文")
        XCTAssertTrue(quoteImage.html.contains("data:image/png;base64," + png))
        XCTAssertFalse(quoteImage.html.contains("after"))
    }

    func testUnknownHTMLBlockSelectionGivesNil() {
        for source in ["<center>текст 中文</center>", "<div onclick='x()'>текст</div>", "<table><tr><td>a</td></tr></table>"] {
            XCTAssertNil(project(source, whole(source)), source)
        }
    }

    // Текстовые промежутки HTML-блока доказываются по DOM одного литерала, поэтому в контейнерах и после
    // незакрытого `<div>` результат nil.
    func testHTMLBlockTextInsideContainerOrAfterUnclosedDivGivesNil() {
        let afterUnclosed = "<div>\n\n<div>a<p>b</p>c</div>"
        let tail = (afterUnclosed as NSString).range(of: "<div>a<p>b</p>c</div>")
        XCTAssertNil(project(afterUnclosed, tail), "после незакрытого div")
        for source in ["> <div>a<p>b</p>c</div>", "- <div>x <strong>y</strong></div>", "1. <div>中文 <strong>y</strong></div>"] {
            XCTAssertNil(project(source, whole(source)), source)
        }
        let closed = "<div>\n\n</div>\n\n<div>a<p>b</p>c</div>"
        XCTAssertNotNil(project(closed, (closed as NSString).range(of: "<div>a<p>b</p>c</div>")), "после закрытого div текст доказывается")
    }

    // Целиком выделенная цитата с HTML-блоком не копируется (nil); частичное выделение картинок без маркера `> ` копируется
    // без текстового доказательства (контекст нужен только тексту).
    func testImagesOnlyHTMLBlockInQuoteCopiesPartialSelectionOnly() throws {
        let first = "<img src='https://example.com/a.png'>", second = "<img src='https://example.com/b.png'>"
        let source = "> <div>" + first + second + "</div>" as NSString
        let start = source.range(of: first).location
        let both = NSRange(location: start, length: NSMaxRange(source.range(of: second)) - start)
        let copy = try XCTUnwrap(project(source as String, both, includeImages: true, allowRemoteImages: true))
        XCTAssertTrue(copy.html.contains("example.com/a.png") && copy.html.contains("example.com/b.png"), copy.html)
        XCTAssertNil(project(source as String, whole(source as String), includeImages: true, allowRemoteImages: true), "цитата целиком")
    }

    // Незакрытым считается не только `div`: любой элемент вне списка доказательства и строчный `rawHTML` абзаца.
    func testTextProofIsDeniedAfterAnyUnclosedElement() {
        for (source, needle) in [("<section>\n\n<div>a <strong>b</strong></div>", "<div>a <strong>b</strong></div>"),
                                 ("<details>\n<summary>S</summary>\n\n<div>x<p>y</p>z</div>\n\n</details>", "<div>x<p>y</p>z</div>"),
                                 ("текст <div>\n\n<div>a<p>b</p>c</div>", "<div>a<p>b</p>c</div>")] {
            let raw = source as NSString
            XCTAssertNil(project(source, raw.range(of: needle)), source)
        }
    }

    func testTopLevelDivWithSingleImageKeepsWrapperAndSpacedSourceIsRead() throws {
        try requireImageSupport()
        let tag = "<img src='data:image/png;base64,\(png)' alt='中文'>"
        let source = "<div>\n\(tag)\n</div>"
        let result = try XCTUnwrap(project(source, whole(source), includeImages: true))
        XCTAssertTrue(result.html.hasPrefix("<div>"), result.html)
        XCTAssertTrue(result.html.hasSuffix("</div>"), result.html)
        // Имя файла с пробелом: адрес берётся из тега исходника, а не из закодированного `%20`.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lac-html-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try XCTUnwrap(Data(base64Encoded: png)).write(to: directory.appendingPathComponent("my pic.png"))
        let spaced = "<div>до <img src='my pic.png'> после</div>"
        let range = (spaced as NSString).range(of: "<img src='my pic.png'>")
        let copy = try XCTUnwrap(project(spaced, range, includeImages: true, documentURL: directory.appendingPathComponent("doc.md")))
        XCTAssertTrue(copy.html.contains("data:image/png;base64,"), copy.html)
    }

    func testIframeBlockCopyAndUnsafeMediaNegatives() throws {
        let frame = "<iframe src=\"https://example.invalid/x\" width=\"300\"></iframe>"
        let source = ("до\n\n" + frame + "\n\nпосле") as NSString
        let copy = try XCTUnwrap(project(source as String, source.range(of: frame)))
        XCTAssertTrue(copy.html.contains("<iframe"), copy.html)
        XCTAssertTrue(copy.hasUnverifiedHTMLBlocks)
        XCTAssertNil(project(source as String, NSRange(location: source.range(of: frame).location, length: 10)), "часть iframe")
        for unsafe in ["<video src=\"https://example.invalid/a\" onplay=\"evil()\">hidden</video>",
                       "<video src=\"https://example.invalid/a\">hidden",
                       "<script><video src=\"https://example.invalid/a\">secret</video></script>"] {
            let raw = unsafe as NSString
            XCTAssertNil(project(unsafe, raw.range(of: raw.contains("secret") ? "secret" : "hidden")), unsafe)
        }
        for address in ["relative.wav", "javascript:alert(1)"] {
            let value = "<audio src=\"\(address)\">fallback</audio>"
            XCTAssertNil(project(value, whole(value)), address)
        }
    }

    // Самозакрытый `<iframe …/>` и `<video>` без закрывающего тега модель не считает медиа (`.raw`): копирования нет.
    func testSelfClosingIframeAndUnclosedVideoAreNotCopied() {
        for tag in ["<iframe src=\"https://example.invalid/x\"/>",
                    "<video src=\"https://example.invalid/a.mp4\" controls>\n<source src=\"https://example.invalid/b.mp4\">"] {
            let source = ("до\n\n" + tag + "\n\nпосле") as NSString
            XCTAssertNil(project(source as String, source.range(of: tag)), tag)
        }
    }

    // Панель собирает разорванный `<video>` и следующий html-блок в видео, копирование — нет, как и до единого слоя.
    func testBrokenVideoOpeningWithNextBlockIsNotCopied() {
        for n in ["\n", "\r\n"] {
            let opening: String = "<video src=\"https://example.invalid/a.mp4\"" + n + "controls>"
            let block: String = "<source src=\"https://example.invalid/b.mp4\">" + n + "</video>"
            let pair: String = opening + n + block
            let full: String = "до" + n + n + pair + n + n + "после 中文"
            let source = full as NSString
            XCTAssertNil(project(source as String, source.range(of: pair)), "вся пара")
            XCTAssertNil(project(source as String, source.range(of: block)), "только блок")
            XCTAssertNil(project(source as String, source.range(of: opening)), "только абзац")
            XCTAssertEqual(project(source as String, source.range(of: "до"))?.text, "до")
        }
    }

    func testCRLFMediaAndDetailsBlocks() throws {
        for tag in ["<details><summary>More</summary><strong>Body 中文</strong></details>", "<audio src='https://example.invalid/a/b.wav' />",
                    "<video src=\"https://example.invalid/a.mp4\" controls>\r\n<source src=\"https://example.invalid/b.mp4\" type=\"video/mp4\">\r\nfallback\r\n</video>"] {
            let source = ("до\r\n\r\n" + tag + "\r\n\r\nпосле") as NSString
            let range = source.range(of: tag)
            let copy = try XCTUnwrap(project(source as String, range), tag)
            XCTAssertTrue(copy.hasUnverifiedHTMLBlocks, tag)
            XCTAssertNil(project(source as String, NSRange(location: range.location, length: range.length - 1)), "часть: \(tag)")
        }
    }
}
