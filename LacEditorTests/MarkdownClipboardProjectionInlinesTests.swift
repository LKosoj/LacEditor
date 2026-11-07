import Foundation
import XCTest
@testable import LacEditor

/// Строчные узлы проектора выделения на модели (U4.5.3): код, стили, ссылки, картинки, формулы, переносы.
/// Ожидания совпадают с `MarkdownClipboardCopyTests` и `MarkdownRubyOutputTests`.
final class MarkdownClipboardProjectionInlinesTests: XCTestCase {
    private func project(_ source: String, _ selection: NSRange? = nil, images: Bool = false) -> MarkdownClipboardCopyService.Fragment? {
        let range = selection ?? NSRange(location: 0, length: (source as NSString).length)
        return MarkdownClipboardCopyService.project(source, selection: range, includeImages: images, allowRemoteImages: images)
    }

    private func part(_ source: String, _ needle: String) -> NSRange { (source as NSString).range(of: needle) }

    func testInlineCodeDropsBackticksAndPaddingAndKeepsUnicode() throws {
        let copy = try XCTUnwrap(project("a `код 中😀` b"))
        XCTAssertEqual(copy.text, "a код 中😀 b")
        XCTAssertEqual(copy.html, "a <code>код 中😀</code> b")
        let padded = try XCTUnwrap(project("`` `x` ``"))
        XCTAssertEqual(padded.text, "`x`")
        let edge = try XCTUnwrap(project("a `код` b", NSRange(location: 3, length: 2)), "выделение внутри кода")
        XCTAssertEqual(edge.text, "ко")
        XCTAssertEqual(edge.html, "<code>ко</code>")
    }

    func testStrongEmphasisAndStrikethroughKeepSelectedText() throws {
        let source = "**жир** *курсив* ~~зачёрк~~ 中"
        XCTAssertEqual(try XCTUnwrap(project(source)).text, "жир курсив зачёрк 中")
        let inside = try XCTUnwrap(project(source, part(source, "ир")))
        XCTAssertEqual(inside.text, "ир")
        XCTAssertEqual(inside.html, "<strong>ир</strong>")
    }

    func testHighlightSuperscriptSubscriptAndMarkdownMarks() throws {
        let source = "==в== H~2~O x^2^ ~3~"
        let copy = try XCTUnwrap(project(source))
        XCTAssertEqual(copy.text, "в H2O x2 3")
    }

    func testHTMLPairTagsRejectCutTags() throws {
        let source = "до <u>подчёрк</u> после"
        let all = try XCTUnwrap(project(source))
        XCTAssertEqual(all.text, "до подчёрк после")
        XCTAssertNil(project(source, part(source, "u>подчёрк")), "режет открывающий тег")
        XCTAssertNil(project(source, part(source, "подчёрк</")), "режет закрывающий тег")
        XCTAssertEqual(try XCTUnwrap(project(source, part(source, "дчё"))).text, "дчё")
    }

    // Теги `<script>`/`<template>` не копируются, а текст внутри виден в панели и копируется обычным текстом.
    func testRawHTMLContextTagsGiveNilButTextCopies() throws {
        let cases = [("до <script>var x = 1;</script> после", "var x = 1;"), ("до <template>внутри</template> после", "внутри"),
                     ("до <textarea>текст 中文😀</textarea> после", "текст 中文😀")]
        for (source, inside) in cases {
            XCTAssertNil(project(source), source)
            XCTAssertEqual(project(source, part(source, "до "))?.text, "до ", source)
            XCTAssertEqual(project(source, part(source, inside))?.text, inside, source)
            XCTAssertEqual(project(source, part(source, inside))?.html, inside, source)
            XCTAssertNil(project(source, part(source, "<")), "режет тег: \(source)")
            let closing = source.contains("<template>") ? "</template>" : source.contains("<script>") ? "</script>" : "</textarea>"
            XCTAssertNil(project(source, part(source, inside + closing)), "текст и закрывающий тег: \(source)")
        }
        let styled = "x <template>**жирный**</template> y"
        XCTAssertNotNil(project(styled, part(styled, "жирный")), styled)
        XCTAssertEqual(project(styled, part(styled, "жирный"))?.text, "жирный", styled)
    }

    func testLinksKeepTextAndRejectUnsafeScheme() throws {
        let source = "[ссылка](http://a.com) <a href=\"https://b.com\">лк</a> https://auto.com"
        let copy = try XCTUnwrap(project(source))
        XCTAssertEqual(copy.text, "ссылка лк https://auto.com")
        XCTAssertNil(project("<a href=\"javascript:alert(1)\">x</a>"))
        XCTAssertNil(project("[x](javascript:alert(1))"))
    }

    func testBreaksBecomeLineBreaks() throws {
        let hard = try XCTUnwrap(project("a  \nb\\\nc <br> d <br/> e"))
        XCTAssertEqual(hard.text, "a\nb\nc \n d \n e")
        XCTAssertEqual(hard.html, "a<br>b<br>c <br> d <br> e")
        XCTAssertNil(project("a <br class='x'> b"))
    }

    func testFormulaAndFootnoteReference() throws {
        let source = "先 $\\def\\foo{z}$ text $\\foo$ after"
        let formula = try XCTUnwrap(project(source, part(source, "$\\foo$")))
        XCTAssertEqual(formula.text, "$\\foo$")
        XCTAssertEqual(formula.mathExpressions.map(\.source), ["\\def\\foo{z}", "\\foo"])
        XCTAssertEqual(formula.mathImages.map(\.expressionIndex), [1])
        let footnoteSource = "Text[^1].\n\n[^1]: сноска"
        let footnote = try XCTUnwrap(project(footnoteSource, part(footnoteSource, "Text[^1].")))
        XCTAssertEqual(footnote.text, "Text1.")
        XCTAssertEqual(footnote.html, "Text<sup>1</sup>.")
    }

    func testImagesNeedIncludeImagesAndWholeSelection() throws {
        let source = "до ![alt](https://example.com/a.png) после"
        XCTAssertNil(project(source, images: false))
        let copy = try XCTUnwrap(project(source, images: true))
        XCTAssertEqual(copy.remoteImages.map(\.url.absoluteString), ["https://example.com/a.png"])
        XCTAssertNil(project(source, part(source, "alt](https"), images: true), "выделение режет картинку")
    }

    /// Все вхождения `needle` как отдельные выделения (точечные выделения внутри тегов, не только первое).
    private func parts(_ source: String, _ needle: String) -> [NSRange] {
        var result: [NSRange] = [], search = NSRange(location: 0, length: (source as NSString).length)
        while true {
            let found = (source as NSString).range(of: needle, options: [], range: search)
            if found.location == NSNotFound { return result }
            result.append(found)
            search = NSRange(location: NSMaxRange(found), length: (source as NSString).length - NSMaxRange(found))
        }
    }

    private func requireImageSupport() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let data = try XCTUnwrap(Data(base64Encoded: png))
        try XCTSkipUnless((try? MarkdownImageUploadService.payload(data: data)) != nil, "нет ImageIO (стенд Linux)")
    }

    func testRubyCopiesOnlyWholeNodeWithExactTextAndHTML() throws {
        let ruby = "<ruby>漢<rt>kan</rt></ruby>"
        let source = "前😀 " + ruby + " после"
        let copy = try XCTUnwrap(project(source, part(source, ruby)))
        XCTAssertEqual(copy.text, "漢kan")
        XCTAssertEqual(copy.html, ruby)
        XCTAssertTrue(copy.hasUnverifiedHTMLBlocks)
        for needle in ["漢<rt>", "<ruby", "kan</rt></ruby>", "</ruby>"] {
            XCTAssertNil(project(source, part(source, needle)), "выделение режет ruby: \(needle)")
        }
        XCTAssertEqual(project(source, part(source, "前😀"))?.text, "前😀", "соседи ruby копируются")
    }

    // Стиль `<span>` в основании ruby записывается в редакторской форме (rgba).
    func testRubyWithStyledSpanBaseNormalizesStyle() throws {
        let ruby = "<ruby>**漢**<span style='color:red'>字</span><rt>kan</rt></ruby>"
        let source = "до " + ruby + " после"
        let copy = try XCTUnwrap(project(source, part(source, ruby)))
        XCTAssertEqual(copy.html, "<ruby><strong>漢</strong><span style=\"color:rgba(255.0,0.0,0.0,1.0)\">字</span><rt>kan</rt></ruby>")
    }

    // Запасной текст внутри video разобран cmark.
    func testVideoFallbackTextIsRenderedMarkdown() throws {
        let video = "<video src=\"https://example.invalid/a.mp4\" controls>fallback &amp; **bold**</video>"
        let source = "before " + video + " after"
        let copy = try XCTUnwrap(project(source, part(source, video)))
        XCTAssertEqual(copy.html, "<video controls src=\"https://example.invalid/a.mp4\">fallback &amp; <strong>bold</strong></video>")
    }

    // Запасной текст media размечается в контексте всего документа и с настройками синтаксиса.
    func testMediaFallbackUsesDocumentContextAndSyntaxOptions() throws {
        let video = "<video src=\"https://example.invalid/a.mp4\" controls>say \"hi\" [дом][h] **b**</video>"
        let source = "до " + video + " после\n\n[h]: /u"
        let smart = try XCTUnwrap(project(source, part(source, video)))
        XCTAssertTrue(smart.html.contains("<a href=\"/u\">дом</a>"), smart.html)
        XCTAssertTrue(smart.html.contains("<strong>b</strong>"), smart.html)
        XCTAssertTrue(smart.html.contains("\u{201C}hi\u{201D}"), smart.html)
        let plain = try XCTUnwrap(MarkdownClipboardCopyService.project(
            source, selection: part(source, video), syntax: MarkdownSyntaxOptions(smartPunctuation: false)))
        XCTAssertEqual(plain.html, "<video controls src=\"https://example.invalid/a.mp4\">say &quot;hi&quot; <a href=\"/u\">дом</a> <strong>b</strong></video>")
        let audio = "<audio src=\"https://example.invalid/a.mp3\" controls>**b**</audio>"
        XCTAssertTrue(try XCTUnwrap(project("x " + audio + " y", part("x " + audio + " y", audio))).html.contains("<strong>b</strong>"))
        let quoted = "> до <video src=\"https://example.invalid/a.mp4\" controls>\n> текст **b**\n> </video> после"
        let copy = try XCTUnwrap(project(quoted, part(quoted, "<video src=\"https://example.invalid/a.mp4\" controls>\n> текст **b**\n> </video>")))
        XCTAssertTrue(copy.html.contains("<strong>b</strong>"), copy.html)
    }

    // Два одинаковых media в документе: каждое получает свой запасной текст, разбор один на проекцию.
    func testIdenticalMediaEachGetOwnFallbackText() throws {
        let open = "<video src=\"https://example.invalid/a.mp4\" controls>"
        let source = "а " + open + "**x**</video> б " + open + "*y*</video> в"
        let copy = try XCTUnwrap(project(source))
        let tag = "<video controls src=\"https://example.invalid/a.mp4\">"
        XCTAssertTrue(copy.html.contains(tag + "<strong>x</strong></video>"), copy.html)
        XCTAssertTrue(copy.html.contains(tag + "<em>y</em></video>"), copy.html)
    }

    // Выделен только абзац с media; в документе ниже есть таблица с таким же media в строке без замыкающего `|`.
    func testMediaFallbackInParagraphBesideTableAndInQuote() throws {
        let video = "<video src=\"https://example.invalid/a.mp4\" controls>**x**</video>"
        let table = "| a | b |\n|---|---|\n| " + video + " | c"
        let source = "до " + video + " после\n\n" + table
        let copy = try XCTUnwrap(project(source, part(source, video)))
        XCTAssertEqual(copy.html, "<video controls src=\"https://example.invalid/a.mp4\"><strong>x</strong></video>")
        // Медиа в ячейке таблицы не копируется (nil).
        XCTAssertNil(project(table, part(table, video)))
        let audio = "<audio src=\"https://example.invalid/a.mp3\" controls>**x**</audio>"
        let quote = "> до " + audio + " после"
        let quoteCopy = try XCTUnwrap(project(quote, part(quote, audio)))
        XCTAssertEqual(quoteCopy.html, "<audio controls src=\"https://example.invalid/a.mp3\"><strong>x</strong></audio>")
    }

    func testMediaInsideLinkCopiesWithRenderedFallback() throws {
        let video = "<video src=\"https://example.invalid/a.mp4\" controls>**x**</video>"
        let source = "[" + video + "](https://example.com/u)"
        let copy = try XCTUnwrap(project(source, part(source, video)))
        XCTAssertEqual(copy.html, "<a href=\"https://example.com/u\"><video controls src=\"https://example.invalid/a.mp4\"><strong>x</strong></video></a>")
    }

    // Отказ: элемент перед меткой не совпадает с ожидаемым медиа -> результата для него нет.
    func testRenderedMediaFallbackRefusesMismatchedElement() throws {
        let video = "<video src=\"https://example.invalid/a.mp4\" controls>**x**</video>"
        let source = "до " + video + " после"
        let other = try XCTUnwrap(MarkdownHTMLMediaService.embeddedMedia(in: "<video src=\"https://example.invalid/other.mp4\" controls></video>"))
        let range = part(source, video)
        let mismatched = MarkdownHTMLProof.renderedInlineMediaHTML(markdown: source, media: [(range, .media(other))], syntax: MarkdownSyntaxOptions(), isCancelled: { false })
        XCTAssertEqual(mismatched, [:])
        let right = try XCTUnwrap(MarkdownHTMLMediaService.embeddedMedia(in: video))
        let matched = MarkdownHTMLProof.renderedInlineMediaHTML(markdown: source, media: [(range, .media(right))], syntax: MarkdownSyntaxOptions(), isCancelled: { false })
        XCTAssertEqual(matched?[range], "<video src=\"https://example.invalid/a.mp4\" controls><strong>x</strong></video>")
        XCTAssertNil(MarkdownHTMLProof.renderedInlineMediaHTML(markdown: source, media: [(range, .media(right))], syntax: MarkdownSyntaxOptions(), isCancelled: { true }))
    }

    func testMediaCopiesOnlyWholeNodeAndRejectsCutTags() throws {
        let audio = "<audio src=\"https://example.invalid/a.mp3\" controls></audio>"
        let source = "до " + audio + " после"
        let copy = try XCTUnwrap(project(source, part(source, audio)))
        XCTAssertEqual(copy.text, "")
        XCTAssertEqual(copy.html, "<audio controls src=\"https://example.invalid/a.mp3\"></audio>")
        XCTAssertTrue(copy.hasUnverifiedHTMLBlocks)
        for range in [NSRange(location: part(source, audio).location, length: 8), part(source, "controls></audio>"), part(source, "</audio>")] {
            XCTAssertNil(project(source, range), "выделение режет media")
        }
        let frame = "<iframe src=\"https://example.invalid/x\"></iframe>"
        let frameSource = "до " + frame + " после"
        let frameCopy = try XCTUnwrap(project(frameSource, part(frameSource, frame)))
        XCTAssertEqual(frameCopy.html, "<iframe sandbox=\"allow-scripts\" src=\"https://example.invalid/x\"></iframe>")
        XCTAssertNil(project(frameSource, part(frameSource, "src=\"https://example.invalid/x\">")))
    }

    func testInlineSVGNeedsImagesAndWholeNode() throws {
        let svg = "<svg width='40' height='20'><rect width='40' height='20' fill='red'/></svg>"
        let source = "前😀 " + svg + " after"
        let range = part(source, svg)
        XCTAssertNil(project(source, range, images: false), "без картинок")
        XCTAssertNil(project(source, NSRange(location: range.location, length: range.length - 1), images: true), "режет закрывающий тег")
        XCTAssertNil(project(source, part(source, "<rect"), images: true), "внутри тега")
        try requireImageSupport()
        let copy = try XCTUnwrap(project(source, range, images: true))
        XCTAssertTrue(copy.html.contains("data:image/svg+xml;base64,"), copy.html)
    }

    func testAutolinkInTableCellIsNotTreatedAsHTMLPair() throws {
        let source = "| A |\n| --- |\n| <https://example.com> |"
        let copy = try XCTUnwrap(project(source, part(source, "<https://example.com>")))
        XCTAssertEqual(copy.text, "https://example.com")
        XCTAssertEqual(copy.html, "<a href=\"https://example.com\">https://example.com</a>")
    }

    // В сыром контексте и `<template>` ядро не делает эмодзи: панель показывает `:smile:` буквально, копируется так же.
    func testEmojiShortcodeInsideScriptOrTemplateCopiesAsPlainText() {
        for source in ["x <script>:smile:</script> y", "x <template>:smile:</template> y"] {
            XCTAssertEqual(project(source, part(source, ":smile:"))?.text, ":smile:", source)
            XCTAssertEqual(project(source, part(source, ":smile:"))?.html, ":smile:", source)
            XCTAssertNil(project(source), source)
            XCTAssertEqual(project(source, part(source, "x "))?.text, "x ", source)
        }
    }

    // Эмодзи в абзаце между блоками `<template>` панель рисует глифом (блоки-теги пропускаются), копирование так же.
    func testEmojiParagraphBetweenTemplateBlocksCopiesGlyph() throws {
        let source = "<template>\n\n:smile:\n\n</template>"
        let copy = try XCTUnwrap(project(source, part(source, ":smile:")))
        XCTAssertEqual(copy.text, "😄")
        XCTAssertEqual(copy.html, "😄")
    }

    // Многострочная ссылка: конец выделения запоминается, лишнего перевода строки в конце нет; мягкий перенос после ссылки остаётся.
    func testMultilineLinkDoesNotAddTrailingLineBreak() throws {
        for n in ["\n", "\r\n"] {
            let source = "[a](u" + n + "\"t\") x"
            let copy = try XCTUnwrap(project(source), n.debugDescription)
            XCTAssertEqual(copy.text, "a x", n.debugDescription)
            XCTAssertEqual(copy.html, "<a href=\"u\">a</a> x", n.debugDescription)
        }
        let soft = try XCTUnwrap(project("[a](u)\nb"))
        XCTAssertEqual(soft.text, "a\nb")
    }

    func testAnyNodeInsideUnconfirmedPairGivesNil() {
        let inputs = ["до <span style='position:fixed'>**hidden**</span> после",
                      "до <video src=x onplay=y>`code`</video> после",
                      "до <video src=x onplay=y>:smile:</video> после",
                      "до <video src=x onplay=y>a<br>b</video> после"]
        let needles = ["hidden", "code", ":smile:", "<br>"]
        for (source, needle) in zip(inputs, needles) {
            for range in parts(source, needle) { XCTAssertNil(project(source, range), "\(source) / \(needle)") }
            XCTAssertEqual(project(source, part(source, "до"))?.text, "до", source)
        }
    }

    func testSpanWithoutStyleAttributeDoesNotBlockText() throws {
        for (source, needle) in [("a <span class=\"x\">bold</span> c", "bold"), ("a <span class=\"mystyle\">x</span> b", "x"),
                                 ("a <span data-style=\"1\">x</span> b", "x")] {
            let range = parts(source, needle).last!
            XCTAssertEqual(project(source, range)?.text, needle, source)
        }
    }

    func testSVGTagsWithoutModelNodeDoNotBlockText() {
        for source in ["до <svg>hidden</svg> после", "до <svg>hidden после"] {
            XCTAssertEqual(project(source, part(source, "hidden"))?.text, "hidden", source)
        }
    }

    func testImageAltWithHTMLOrLinkGivesNil() throws {
        for source in ["![a <b>x</b>](https://example.com/a.png)", "![a [b](https://example.com/u) c](https://example.com/a.png)"] {
            XCTAssertNil(project(source, images: true), source)
        }
        let plain = try XCTUnwrap(project("![a **x** `c`](https://example.com/a.png)", images: true))
        XCTAssertEqual(plain.html, "<img src=\"https://example.com/a.png\" alt=\"a x c\">")
    }

    func testStyledSpanInsideStrongInTableCell() throws {
        let source = "| Left | Right |\n| --- | --- |\n| **<span style='color:red'>中文\\|😀</span>** | x |"
        let cell = try XCTUnwrap(project(source, part(source, "**<span style='color:red'>中文\\|😀</span>**")))
        XCTAssertEqual(cell.text, "中文|😀")
        XCTAssertEqual(cell.html, "<span style=\"color:rgba(255.0,0.0,0.0,1.0)\"><strong>中文|😀</strong></span>")
        XCTAssertNil(project(source, NSRange(location: part(source, "<span").location, length: 3)), "режет открывающий тег")
    }

    func testFootnoteReferenceRejectsPartialSelection() throws {
        let source = "Text[^one] again 中😀\r\n\r\n[^one]: Note"
        XCTAssertNil(project(source, part(source, "^one]")), "выделение режет ссылку на сноску")
        XCTAssertNil(project(source, part(source, "Text[^")), "выделение режет ссылку на сноску")
        let whole = try XCTUnwrap(project(source, part(source, "Text[^one] again 中😀")))
        XCTAssertEqual(whole.text, "Text1 again 中😀")
    }

    func testTextInsideUnconfirmedMediaOrStylePairGivesNil() {
        for source in ["до <video src=\"https://example.invalid/a\" onplay=\"evil()\">hidden</video> после",
                       "до <span style='position:fixed'>hidden</span> после", "до <video src=\"https://example.invalid/a\">hidden"] {
            XCTAssertNil(project(source, part(source, "hidden")), source)
            XCTAssertEqual(project(source, part(source, "до"))?.text, "до", source)
        }
    }
}
