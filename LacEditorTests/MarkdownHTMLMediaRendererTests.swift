import Foundation
import XCTest
@testable import LacEditor

/// Тесты собственных блоков и инлайнов HTML-адаптера (U3.2): код, диаграммы, формулы, `[toc]`, эмодзи, строчные теги,
/// медиа, картинки и сырой HTML. Ожидания — наблюдаемые строки страницы, а не порядок вызовов.
final class MarkdownHTMLMediaRendererTests: XCTestCase {
    private let documentURL = URL(fileURLWithPath: "/lac-media-tests/doc.md")

    private func render(_ markdown: String, media: Bool = false, emoji: Bool = false, resolve: Bool = false, remote: Bool = false,
                        preserve: Bool = false, forExport: Bool = false, highlight: Bool = false, widgets: Bool = false,
                        numbers: Bool = false, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(inlineMath: true),
                        document: URL? = nil) -> MarkdownRenderedPage {
        MarkdownHTMLRenderer.renderPage(markdown, darkMode: false, includeHTMLMedia: media, renderEmoji: emoji, resolveLocalImages: resolve,
                                        documentURL: document ?? documentURL, prepareRemoteImages: remote, syntax: syntax, forExport: forExport,
                                        includeHeadingNumbers: numbers, staticWidgetFallback: widgets, preserveRawHTMLBlocks: preserve,
                                        highlightCode: highlight)
    }

    // MARK: Код и диаграммы

    func testDiagramFencesBecomePlaceholdersWhileMermaidStaysCode() {
        let page = render("中文😀\r\n\r\n```flow\r\ns=>start: <Start>\r\n```\r\n\r\n```sequence\r\nA->B: Hello\r\n```\r\n\r\n```mermaid\r\ngraph TD\r\n```")
        XCTAssertEqual(page.diagrams.map(\.kind), [.flow, .sequence])
        XCTAssertEqual(page.diagrams.map(\.source), ["s=>start: <Start>\n", "A->B: Hello\n"])
        XCTAssertTrue(page.body.contains("<pre data-lac-diagram=\"0\">s=&gt;start: &lt;Start&gt;\n</pre>"), page.body)
        XCTAssertTrue(page.body.contains("data-lac-diagram=\"1\""), page.body)
        XCTAssertTrue(page.body.contains("language-mermaid"), page.body)
        XCTAssertFalse(page.body.contains("<Start>"), page.body)
    }

    func testHighlightedCodeIsOptionalAndKeepsLanguageClass() {
        let source = "```swift\nlet value = 1\n```"
        let plain = render(source).body
        XCTAssertTrue(plain.contains("<code class=\"language-swift\">let value = 1\n</code>"), plain)
        let highlighted = render(source, highlight: true).body
        XCTAssertTrue(highlighted.contains("<code class=\"language-swift\">"), highlighted)
        XCTAssertTrue(highlighted.contains("<span"), "подсветка должна добавить элементы: \(highlighted)")
        XCTAssertTrue(highlighted.contains("value"), highlighted)
    }

    // MARK: Формулы

    func testInlineAndDisplayFormulasUsePlaceholdersAndEscapeSource() {
        let page = render("Формула $a<b$ и 漢字 😀\n\n$$\nx^2\n$$")
        XCTAssertEqual(page.formulas.map(\.display), [false, true])
        XCTAssertEqual(page.formulas.first?.source, "a<b")
        XCTAssertTrue(page.body.contains("<span data-lac-math=\"0\">$a&lt;b$</span>"), page.body)
        XCTAssertTrue(page.body.contains("<div data-lac-math=\"1\">$$\nx^2\n$$</div>"), page.body)
    }

    // MARK: Оглавление и эмодзи

    func testTOCListsHeadingsAndStaysParagraphWithoutHeadings() {
        let withHeadings = render("[toc]\n\n# Первый\n\n## Второй ✨").body
        XCTAssertTrue(withHeadings.contains("data-lac-toc"), withHeadings)
        XCTAssertTrue(withHeadings.contains("<li data-level=\"1\"><a href=\"#"), withHeadings)
        XCTAssertTrue(withHeadings.contains("<li data-level=\"2\"><a href=\"#"), withHeadings)
        XCTAssertTrue(withHeadings.contains("Второй ✨</a>"), withHeadings)
        XCTAssertEqual(render("[toc]").body, "<p>[toc]</p>\n")
    }

    func testEmojiShortcodesAreReplacedOnlyWhenRequested() {
        let source = "==:smile:== ^:heart:^ ~:smile:~ :smile: и :нет_такого:"
        let off = render(source).body
        XCTAssertTrue(off.contains(":smile:"), off)
        let on = render(source, emoji: true).body
        XCTAssertTrue(on.contains("<mark>😄</mark>"), on)
        XCTAssertTrue(on.contains("<sup>❤️</sup>"), on)
        XCTAssertTrue(on.contains("<sub>😄</sub>"), on)
        XCTAssertTrue(on.contains(":нет_такого:"), on)
    }

    // MARK: Строчные теги

    func testInlineMarkupTagsAndPairsOfHTMLTags() {
        let body = render("==a== ^b^ ~c~ <u>d</u> <kbd>e</kbd> <b>f</b> <i>g</i> <s>h</s> <del>i</del>").body
        for expected in ["<mark>a</mark>", "<sup>b</sup>", "<sub>c</sub>", "<u>d</u>", "<kbd>e</kbd>", "<strong>f</strong>", "<em>g</em>", "<del>h</del>", "<del>i</del>"] {
            XCTAssertTrue(body.contains(expected), "нет \(expected): \(body)")
        }
        XCTAssertFalse(body.contains("raw HTML omitted"), body)
    }

    func testInlineCSSSpanAndRubyTags() {
        let body = render("<span style=\"color: red\">красный</span> и <ruby>漢<rt>kan</rt></ruby>").body
        XCTAssertTrue(body.contains("<span style=\""), body)
        XCTAssertTrue(body.contains(">красный</span>"), body)
        XCTAssertTrue(body.contains("<ruby>漢<rt>kan</rt></ruby>"), body)
    }

    func testRubyWithNestedMarkupKeepsEscapedSource() {
        let body = render("before <ruby>==漢==<rt>kan</rt></ruby> after").body
        XCTAssertTrue(body.contains("&lt;ruby"), body)
        XCTAssertTrue(body.contains("&lt;/ruby&gt;"), body)
    }

    func testTableCellBreakIsRealLineBreak() {
        let body = render("| a |\n| - |\n| x<br>y |").body
        XCTAssertTrue(body.contains("<td>x<br>y</td>"), body)
    }

    func testHeadingLinkAliasPointsToHeadingID() {
        let page = render("# Раздел\n\n[к разделу](#раздел)")
        let id = page.headingIDs.first ?? ""
        XCTAssertFalse(id.isEmpty)
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
        XCTAssertTrue(page.body.contains("<a href=\"#\(encoded)\">к разделу</a>"), page.body)
    }

    // MARK: Блоки HTML и медиа

    func testPageBreakSvgAndTwitterBlocks() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"></svg>"
        let body = render("<div style=\"page-break-after: always\"></div>\n\n\(svg)").body
        XCTAssertTrue(body.contains("<div style=\"page-break-after:always;break-after:page\"></div>"), body)
        XCTAssertTrue(body.contains("<img src=\"data:image/svg+xml;base64,"), body)
        // Твит: в предпросмотре и PDF вместо виджета остаётся цитата со ссылкой; скрипт виджета не выводится.
        let tweet = "<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">Hello</p>&mdash; User (@user) <a href=\"https://twitter.com/user/status/1234567890\">January 1, 2020</a></blockquote>\n<script async src=\"https://platform.twitter.com/widgets.js\" charset=\"utf-8\"></script>"
        let widget = render(tweet, widgets: true).body
        XCTAssertTrue(widget.contains(">https://twitter.com/user/status/1234567890</a>"), widget)
        XCTAssertFalse(widget.contains("<script"), widget)
    }

    func testAudioVideoAndIframeUseLocalMarkersOrAddresses() {
        let source = "<audio src=\"a.mp3\" controls></audio>\n\n<video src=\"v.mp4\" controls width=\"320\"></video>\n\n<iframe src=\"https://example.com/embed\" width=\"400\" height=\"200\"></iframe>"
        let page = render(source, resolve: true)
        XCTAssertEqual(page.localMediaMarkers.count, 2)
        XCTAssertEqual(Set(page.localMediaMarkers.values.map { $0.url.lastPathComponent }), ["a.mp3", "v.mp4"])
        XCTAssertTrue(page.body.contains("<audio controls>"), page.body)
        XCTAssertTrue(page.body.contains("<video controls style=\"width:320px;\">"), page.body)
        XCTAssertFalse(page.body.contains("<iframe src=\"https://example.com/embed\""), "в предпросмотре iframe заменяется заглушкой: \(page.body)")
        let exported = render(source, media: true, forExport: true)
        XCTAssertTrue(exported.body.contains("<iframe"), exported.body)
    }

    func testPreserveModeKeepsRawHTMLBlocksAndTagPairsAsMarkers() {
        let source = "<div>блок 漢</div>\n\nтекст <b>жирный</b> и <audio src=\"a.mp3\" controls></audio>"
        let page = render(source, media: true, preserve: true, forExport: true)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        XCTAssertFalse(page.body.contains("<div>"), page.body)
        XCTAssertFalse(page.body.contains("raw HTML omitted"), page.body)
        let originals = page.rawHTMLBlocks.map(\.html)
        XCTAssertTrue(originals.contains("<div>блок 漢</div>"), "\(originals)")
        XCTAssertTrue(originals.contains("<b>"), "\(originals)")
        XCTAssertTrue(originals.contains("</b>"), "\(originals)")
        XCTAssertTrue(originals.contains("<audio src=\"a.mp3\" controls>"), "\(originals)")
        XCTAssertTrue(originals.contains("</audio>"), "\(originals)")
        for block in page.rawHTMLBlocks { XCTAssertTrue(page.body.contains(block.marker), block.marker) }
    }

    func testDetailsBlockAndOmittedFlag() {
        let details = "<details><summary>Заголовок</summary>\n\nТекст\n\n</details>"
        let exported = render(details, media: true, forExport: true)
        XCTAssertTrue(exported.body.contains("<details"), exported.body)
        XCTAssertTrue(exported.body.contains("Заголовок"), exported.body)
        // Неподдержанный тег: предпросмотр пишет комментарий, а экспорт HTML ставит флаг `omittedHTML`.
        let unsupported = render("текст <blink>мигает</blink>", media: true, forExport: true)
        XCTAssertTrue(unsupported.omittedHTML, unsupported.body)
        XCTAssertFalse(render("текст <blink>мигает</blink>").omittedHTML)
    }

    // MARK: Картинки

    func testMarkdownImagesCenterOnlyWhenAloneInParagraph() {
        let alone = render("![подпись](x.png \"заголовок\")", resolve: true).body
        XCTAssertTrue(alone.contains("<span data-lac-centered-image><img src=\"x.png\" alt=\"подпись\" title=\"заголовок\" /></span>"), alone)
        let inline = render("текст ![a](x.png) текст", resolve: true).body
        XCTAssertFalse(inline.contains("data-lac-centered-image"), inline)
        XCTAssertFalse(render("![a](x.png)").body.contains("data-lac-centered-image"))
    }

    func testRemoteImagesGetMarkersOnlyWhenPrepared() {
        let source = "![a](https://example.com/p.png)"
        let off = render(source, resolve: true)
        XCTAssertTrue(off.remoteImageMarkers.isEmpty)
        XCTAssertTrue(off.body.contains("src=\"https://example.com/p.png\""), off.body)
        let on = render(source, resolve: true, remote: true)
        XCTAssertEqual(Array(on.remoteImageMarkers.values), ["https://example.com/p.png"])
        XCTAssertFalse(on.body.contains("example.com"), on.body)
    }

    func testHTMLImageIsOmittedInPreviewAndKeptInExport() {
        let source = "Картинка <img src=\"good.png\" alt=\"ok\" width=\"20\"> здесь"
        XCTAssertTrue(render(source).body.contains("raw HTML omitted"))
        let exported = render(source, media: true, forExport: true)
        XCTAssertTrue(exported.body.contains("<img src=\"good.png\" alt=\"ok\" width=\"20\">"), exported.body)
        XCTAssertFalse(exported.omittedHTML, exported.body)
    }

    func testDangerousImageAddressIsEmptied() {
        let body = render("![x](javascript:alert(1))", resolve: true).body
        XCTAssertTrue(body.contains("src=\"\""), body)
    }

    // MARK: Замечания ревью U3.2

    // Ruby собирается из разобранных полей: `&amp;` в основании экранируется один раз, стиль нормализуется.
    func testRubyIsBuiltFromParsedFieldsWithSingleEscapingAndNormalizedStyle() {
        let escaped = render("<ruby>漢&amp;字<rt>kan</rt></ruby>").body
        XCTAssertTrue(escaped.contains("<ruby>漢&amp;字<rt>kan</rt></ruby>"), escaped)
        XCTAssertFalse(escaped.contains("&amp;amp;"), escaped)
        let styled = render("<ruby><span style=\"COLOR:Red\">漢</span><rt>kan</rt></ruby>").body
        XCTAssertTrue(styled.contains("<ruby><span style=\"color:"), styled)
        XCTAssertFalse(styled.contains("COLOR:Red"), styled)
    }

    // Сырой блок, который не совпал с literal ядра (здесь — другой перевод строки внутри), помечает проверку проваленной.
    func testRawBlockThatDiffersFromLiteralMarksProofFailed() {
        let page = render("<div>a</div>", media: true, preserve: true, forExport: true)
        XCTAssertFalse(page.rawHTMLBlockProofFailed)
        let quoted = render("> <div>a\r\n> b</div>\r\n", media: true, preserve: true, forExport: true)
        XCTAssertFalse(quoted.rawHTMLBlockProofFailed, "CRLF и префиксы цитаты сверку не ломают")
        let broken = render("- <div>a\n\tb</div>\n\n<div>c</div>", media: true, preserve: true, forExport: true)
        XCTAssertTrue(broken.rawHTMLBlocks.contains { $0.html.contains("c") })
    }

    func testPreserveModeResolvesMediaInsideRawBlock() {
        let page = render("<div><audio src=\"a.mp3\"></audio></div>", media: true, resolve: true, preserve: true, forExport: true)
        XCTAssertEqual(page.localMediaMarkers.count, 1, page.body)
        let block = page.rawHTMLBlocks.first?.html ?? ""
        XCTAssertFalse(block.contains("a.mp3"), block)
        XCTAssertTrue(block.contains("<audio"), block)
    }

    func testPreserveModeKeepsInlineStyleScriptAndTextareaAsOneMarker() {
        let page = render("x <style>a *b* :smile:</style> y", emoji: true, preserve: true, forExport: true)
        XCTAssertTrue(page.rawHTMLBlocks.map(\.html).contains("<style>a *b* :smile:</style>"), "\(page.rawHTMLBlocks)")
        XCTAssertFalse(page.body.contains("<em>"), page.body)
        XCTAssertFalse(page.body.contains("😄"), page.body)
    }

    func testTOCUsesEmojiOfHeading() {
        let body = render("[toc]\n\n# :smile: Заголовок", emoji: true).body
        XCTAssertTrue(body.contains("😄 Заголовок</a>"), body)
        XCTAssertFalse(body.contains(":smile: Заголовок</a>"), body)
    }

    func testUnsupportedRubyInMultilineQuoteKeepsSourceWithoutQuoteMarkers() {
        let body = render("> <ruby>漢\n> <rt>kan</rt>").body
        XCTAssertTrue(body.contains("<pre"), body)
        XCTAssertTrue(body.contains("&lt;ruby&gt;漢\n&lt;rt&gt;kan&lt;/rt&gt;"), body)
        XCTAssertFalse(body.contains("&gt; &lt;rt"), body)
    }

    func testUnclosedFenceAndInfoWithSpaceKeepLanguageClass() {
        let unclosed = render("```swift\nlet a = 1").body
        XCTAssertTrue(unclosed.contains("<code class=\"language-swift\">let a = 1\n</code>"), unclosed)
        let spaced = render("``` swift title=1\ncode\n```").body
        XCTAssertTrue(spaced.contains("<code class=\"language-swift\">code\n</code>"), spaced)
    }

    func testLocalMarkdownImageBecomesDataURI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lac-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        try png.write(to: directory.appendingPathComponent("p.png"))
        let body = render("![a](p.png)", resolve: true, document: directory.appendingPathComponent("doc.md")).body
        XCTAssertTrue(body.contains("src=\"data:image/png;base64,"), body)
    }

    func testDetailsRenderInPreview() {
        let body = render("до\n\n<details><summary>Заголовок &amp; 中文</summary>Текст 😀</details>\n\nпосле").body
        XCTAssertTrue(body.contains("<details"), body)
        XCTAssertTrue(body.contains("Заголовок &amp; 中文"), body)
        XCTAssertFalse(body.contains("raw HTML omitted"), body)
    }

    func testFormulaInTableCellIsRenderedAsMathPlaceholder() {
        let page = render("| a |\n| - |\n| $x$ |")
        XCTAssertEqual(page.formulas.map(\.source), ["x"])
        XCTAssertTrue(page.body.contains("<td><span data-lac-math=\"0\">$x$</span></td>"), page.body)
    }

    // MARK: Именованные якоря

    func testNamedAnchorsUseGeneratedTargetsAndKeepHeadingPriority() {
        let page = render("[named](#中文) [heading](#title)\n\n<a id='中文'></a>\n\n<a name='title'></a>\n\n# Title\n\n<script><a id='hidden'></script>")
        XCTAssertTrue(page.body.contains("href=\"#lac-anchor-0\""), page.body)
        XCTAssertTrue(page.body.contains("id=\"lac-anchor-0\""), page.body)
        XCTAssertTrue(page.body.contains("href=\"#lac-heading-title\""), page.body)
        XCTAssertFalse(page.body.contains("id=\"中文\""), page.body)
        XCTAssertFalse(page.body.contains("hidden"), page.body)
    }

    func testNamedAnchorAfterReferenceDefinitionUsesConfirmedSource() {
        let body = render("[foo]: https://example.com\n<a id='x'></a>\n\n[go](#x)").body
        XCTAssertTrue(body.contains("href=\"#lac-anchor-0\""), body)
        XCTAssertTrue(body.contains("id=\"lac-anchor-0\""), body)
        XCTAssertTrue(render("[foo]: https://example.com\n\t<a id='x'></a>\n\n[go](#x)").body.contains("lac-anchor-0"))
    }

    func testNamedAnchorTargetsDistinguishUnicodeNormalizationForms() throws {
        let body = render("[a](#%C3%A9) [b](#e%CC%81)\n\n<a id='é'></a> <a id='e\u{301}'></a>").body as NSString
        let pattern = try NSRegularExpression(pattern: "href=\"#(lac-anchor-[^\"]+)\"")
        let matches = pattern.matches(in: body as String, range: NSRange(location: 0, length: body.length))
        XCTAssertEqual(matches.count, 2, body as String)
        guard matches.count == 2 else { return }
        XCTAssertNotEqual(body.substring(with: matches[0].range(at: 1)), body.substring(with: matches[1].range(at: 1)))
    }

    func testNestedNamedAnchorKeepsSafeHTMLPosition() {
        let source = "[jump](#inside)\n\n<div>before <a id='inside'>target</a> after <template><a id='hidden'></a></template></div>"
        let body = render(source).body
        XCTAssertTrue(body.contains("href=\"#lac-anchor-"), body)
        XCTAssertTrue(body.contains("before <span id=\"lac-anchor-"), body)
        XCTAssertTrue(body.contains("</span><a>target</a> after"), body)
        XCTAssertFalse(body.contains("hidden"), body)
        let plain = render(source, media: true)
        XCTAssertTrue(plain.body.contains("before <span id=\"lac-anchor-"), plain.body)
        XCTAssertTrue(plain.omittedHTML)
    }

    // MARK: Повторное ревью U3.2

    func testNamedAnchorInsideImageBlockGetsIDWithImageMarkers() {
        let source = "<img src=\"x.png\" alt=\"a\"><a name=\"x\"></a>\n\n[go](#x)"
        let body = render(source, resolve: true).body
        XCTAssertTrue(body.contains("href=\"#lac-anchor-"), body)
        XCTAssertTrue(body.contains("<span id=\"lac-anchor-"), body)
        XCTAssertTrue(body.contains("<img"), body)
    }

    func testPreserveModeMediaInRawBlockIsFoundStructurally() {
        func block(_ source: String) -> String {
            render(source, media: true, resolve: true, preserve: true, forExport: true).rawHTMLBlocks.first?.html ?? ""
        }
        let withComment = render("<!-- заметка --><video src=\"clip.mp4\"></video>", media: true, resolve: true, preserve: true, forExport: true)
        XCTAssertEqual(withComment.localMediaMarkers.count, 1, "\(withComment.rawHTMLBlocks)")
        XCTAssertFalse(withComment.rawHTMLBlocks.first?.html.contains("clip.mp4") ?? true)
        let preload = render("<div><preload></preload><audio src=\"a.mp3\"></audio></div>", media: true, resolve: true, preserve: true, forExport: true)
        XCTAssertEqual(preload.localMediaMarkers.count, 1, "\(preload.rawHTMLBlocks)")
        let attribute = block("<div title='<audio src=\"a.mp3\"></audio>'>x</div>")
        XCTAssertTrue(attribute.contains("a.mp3"), attribute)
        let unclosed = String(repeating: "<video src=\"v.mp4\" ", count: 2000)
        let page = render("<div>" + unclosed + "</div>", media: true, resolve: true, preserve: true, forExport: true)
        XCTAssertTrue(page.localMediaMarkers.isEmpty)
    }

    func testRubyInExportDecodesAllEntities() {
        let page = render("x <ruby>漢<rt>&#12354;&nbsp;&copy;</rt></ruby>", media: true, preserve: true, forExport: true)
        XCTAssertTrue(page.body.contains("あ\u{00A0}©"), page.body)
        XCTAssertFalse(page.body.contains("&copy;"), page.body)
    }

    // Закрывающий `</iframe>` в сыром блоке приходит из разбора отдельно: iframe с разрешёнными атрибутами пересобирается.
    func testPreserveModeRebuildsIframeInsideRawBlock() {
        let page = render("<div><iframe src=\"https://example.com/embed\" width=\"400\"></iframe></div>", media: true, preserve: true, forExport: true)
        let block = page.rawHTMLBlocks.first?.html ?? ""
        XCTAssertTrue(block.contains("sandbox="), block)
        XCTAssertTrue(block.contains("https://example.com/embed"), block)
    }

    // iframe с атрибутом вне белого списка не доказывается и остаётся сырым тегом.
    func testPreserveModeKeepsIframeWithUnsupportedAttributeRaw() {
        let source = "<div><iframe src=\"https://example.com/embed\" onload=\"x()\"></iframe></div>"
        let page = render(source, media: true, preserve: true, forExport: true)
        let block = page.rawHTMLBlocks.first?.html ?? ""
        XCTAssertEqual(block, source)
    }
}
