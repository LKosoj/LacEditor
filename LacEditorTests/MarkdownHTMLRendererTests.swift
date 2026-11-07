import Foundation
import XCTest
@testable import LacEditor

/// Контрольные тесты HTML-адаптера единой модели (U3.1). Ожидания — точные строки, которые пишет cmark-gfm (`html.c`),
/// а для обёрток таблиц и `<pre>`, меток списков и номеров заголовков — эталоны корпуса; из адаптера они не берутся.
final class MarkdownHTMLRendererTests: XCTestCase {
    private let codeLabel = L10n.tr("代码块，可横向滚动")
    private let tableLabel = L10n.tr("表格，可横向滚动")

    private func render(_ markdown: String, syntax: MarkdownSyntaxOptions = .init(), forExport: Bool = false, numbers: Bool = false,
                        listStyles: Bool = false, positions: Bool = false, preview: Bool = false) -> MarkdownRenderedPage {
        MarkdownHTMLRenderer.renderPage(markdown, darkMode: false, syntax: syntax, forExport: forExport, includeHeadingNumbers: numbers,
                                        includeListStyles: listStyles, includeSourcePositions: positions, isPreview: preview)
    }

    private func body(_ markdown: String, syntax: MarkdownSyntaxOptions = .init(), forExport: Bool = false, numbers: Bool = false,
                      listStyles: Bool = false, positions: Bool = false, preview: Bool = false) -> String {
        render(markdown, syntax: syntax, forExport: forExport, numbers: numbers, listStyles: listStyles, positions: positions,
               preview: preview).body
    }

    /// Строки ожидаемого HTML; у каждой строки — перенос в конце.
    private func html(_ lines: String...) -> String { lines.map { $0 + "\n" }.joined() }

    private func pre(_ code: String, language: String? = nil, extra: String = "") -> String {
        "<pre tabindex=\"0\" aria-label=\"\(codeLabel)\"\(extra)><code\(language.map { " class=\"language-\($0)\"" } ?? "")>\(code)</code></pre>\n"
    }

    private func tableOpen(_ attributes: String = "") -> String {
        "<div class=\"table-scroll\" role=\"region\" aria-label=\"\(tableLabel)\" tabindex=\"0\"><table\(attributes)>\n"
    }

    // MARK: Текст и инлайны

    func testTextEscapesOnlyAmpersandAngleBracketsAndQuotes() {
        // Апострофы и косая черта остаются как есть (режим `secure = 0` из html.c); умные кавычки выключены.
        XCTAssertEqual(body("a & b < c > \"d\" 'e' /", syntax: MarkdownSyntaxOptions(smartPunctuation: false)),
                       "<p>a &amp; b &lt; c &gt; &quot;d&quot; 'e' /</p>\n")
    }

    func testCyrillicCJKEmojiCRLFAndInlineMarks() {
        XCTAssertEqual(body("Привет, 世界 😀\r\n中文\r\n**жирный** _курсив_ ~~зачёркнуто~~ `код <b>`"),
                       html("<p>Привет, 世界 😀<br />", "中文<br />",
                            "<strong>жирный</strong> <em>курсив</em> <del>зачёркнуто</del> <code>код &lt;b&gt;</code></p>"))
    }

    func testNestedStrongDoesNotRepeatTags() {
        XCTAssertEqual(body("**a **b** c** *i **s** i*"), "<p><strong>a b c</strong> <em>i <strong>s</strong> i</em></p>\n")
    }

    func testLinkHrefIsPercentEncodedByteByByteAndTitleEscaped() {
        let source = "[ссылка](<https://example.com/путь а/😀?a=1&b='2'> \"Тут & \\\"кавычки\\\"\") [x](/a%20b/世界) [y](a\"b<c>d)"
        let expected = "<p><a href=\"https://example.com/%D0%BF%D1%83%D1%82%D1%8C%20%D0%B0/%F0%9F%98%80?a=1&amp;b=&#x27;2&#x27;\" "
            + "title=\"Тут &amp; &quot;кавычки&quot;\">ссылка</a> <a href=\"/a%20b/%E4%B8%96%E7%95%8C\">x</a> "
            + "<a href=\"a%22b%3Cc%3Ed\">y</a></p>\n"
        XCTAssertEqual(body(source), expected)
    }

    func testDangerousLinkSchemesGiveEmptyHrefButSafeImageDataStays() {
        let source = "[a](javascript:alert(1)) [b](JAVASCRIPT:x) [c](data:text/html,x) [d](vbscript:x) [e](file:///x) "
            + "[f](data:image/png;base64,AAA) [g](https://x/?a=1&amp;b)"
        XCTAssertEqual(body(source), "<p><a href=\"\">a</a> <a href=\"\">b</a> <a href=\"\">c</a> <a href=\"\">d</a> <a href=\"\">e</a> "
                       + "<a href=\"data:image/png;base64,AAA\">f</a> <a href=\"https://x/?a=1&amp;b\">g</a></p>\n")
        XCTAssertEqual(body("![d](data:image/png;base64,AAA) ![e](data:text/html,x) ![f](javascript:x)"),
                       "<p><img src=\"data:image/png;base64,AAA\" alt=\"d\" /> <img src=\"\" alt=\"e\" /> <img src=\"\" alt=\"f\" /></p>\n")
    }

    func testImageAltIsPlainTextOfDescriptionAndTitleIsEscaped() {
        XCTAssertEqual(body("![альт *x* 世](pic.png \"т\") ![](a b.png)"),
                       "<p><img src=\"pic.png\" alt=\"альт x 世\" title=\"т\" /> ![](a b.png)</p>\n")
    }

    func testEntitiesAreDecodedAndAutolinksGetEncodedHref() {
        XCTAssertEqual(body("а\u{00A0}б &amp; &copy; &#35;"), "<p>а\u{00A0}б &amp; © #</p>\n")
        XCTAssertEqual(body("<https://ex.com/путь> и https://ex.com/a_b www.ex.com"),
                       "<p><a href=\"https://ex.com/%D0%BF%D1%83%D1%82%D1%8C\">https://ex.com/путь</a> и <a href=\"https://ex.com/a_b\">https://ex.com/a_b</a> "
                       + "<a href=\"http://www.ex.com\">www.ex.com</a></p>\n")
    }

    func testSoftBreakBecomesBreakOrSpaceByOption() {
        let source = "a\nb  \nc\\\nd"
        XCTAssertEqual(body(source), html("<p>a<br />", "b<br />", "c<br />", "d</p>"))
        XCTAssertEqual(body(source, syntax: MarkdownSyntaxOptions(preserveEditingSoftBreaks: false)),
                       html("<p>a b<br />", "c<br />", "d</p>"))
        // Экспорт берёт свою настройку: по умолчанию перенос сохраняется, при `false` — пробел.
        XCTAssertEqual(body("a\nb", forExport: true), html("<p>a<br />", "b</p>"))
        XCTAssertEqual(body("a\nb", syntax: MarkdownSyntaxOptions(preserveExportSoftBreaks: false), forExport: true), "<p>a b</p>\n")
    }

    func testRawHTMLIsReplacedWithOmittedComment() {
        // Безопасный режим cmark: сырой HTML (блок и строчный) заменяется комментарием, но пара `<b>…</b>` выводится настоящим тегом, как в старом рендере.
        XCTAssertEqual(body("<div>x</div>\n\nинлайн <b>x</b> и <!-- c -->"),
                       html("<!-- raw HTML omitted -->", "<p>инлайн <strong>x</strong> и <!-- raw HTML omitted --></p>"))
        XCTAssertEqual(body("<!-- c -->\n\n<script>x</script>\n\n<br>\n\nтекст<br>ещё"),
                       html("<!-- raw HTML omitted -->", "<!-- raw HTML omitted -->", "<!-- raw HTML omitted -->", "<p>текст<!-- raw HTML omitted -->ещё</p>"))
    }

    // MARK: data-lac-whitespace

    func testPreserveWhitespaceWrapsEveryTextNodeButNotAltOrCode() {
        let syntax = MarkdownSyntaxOptions(preserveEditingWhitespace: true)
        let page = render("a   b\n\n# a  b\n\n[l  x](u)\n\n![a  b](u)\n\n`c  d`", syntax: syntax)
        XCTAssertTrue(page.preserveWhitespace)
        let span = { (text: String) in "<span data-lac-whitespace>\(text)</span>" }
        XCTAssertTrue(page.body.contains("<p>\(span("a   b"))</p>\n"), page.body)
        XCTAssertTrue(page.body.contains("<h1>\(span("a  b"))</h1>\n"), page.body)
        XCTAssertTrue(page.body.contains("<a href=\"u\">\(span("l  x"))</a>"), page.body)
        XCTAssertTrue(page.body.contains("<img src=\"u\" alt=\"a  b\" />"), page.body)
        XCTAssertTrue(page.body.contains("<code>c  d</code>"), page.body)
    }

    func testPreserveWhitespaceWrapsTableCells() {
        // Ожидание взято из правила плана U3.1: оборачивается каждый `.text`.
        let page = render("| c  d |\n|--|\n| e  f |", syntax: MarkdownSyntaxOptions(preserveEditingWhitespace: true))
        XCTAssertTrue(page.body.contains("<th><span data-lac-whitespace>c  d</span></th>"), page.body)
        XCTAssertTrue(page.body.contains("<td><span data-lac-whitespace>e  f</span></td>"), page.body)
    }

    func testPreserveWhitespaceInExportUsesBreakSpacesStyleAndOwnOption() {
        XCTAssertEqual(body("a   b ", syntax: MarkdownSyntaxOptions(preserveExportWhitespace: true), forExport: true),
                       "<p><span data-lac-whitespace style=\"white-space:break-spaces\">a   b</span></p>\n")
        // Настройка редактора на экспорт не влияет, а настройка экспорта — на предпросмотр.
        let editorOnly = render("a   b", syntax: MarkdownSyntaxOptions(preserveEditingWhitespace: true), forExport: true)
        XCTAssertFalse(editorOnly.preserveWhitespace)
        XCTAssertEqual(editorOnly.body, "<p>a   b</p>\n")
        XCTAssertEqual(body("世界  😀\r\nвторая  строка", syntax: MarkdownSyntaxOptions(preserveEditingWhitespace: true)),
                       html("<p><span data-lac-whitespace>世界  😀</span><br />", "<span data-lac-whitespace>вторая  строка</span></p>"))
    }

    // MARK: Блоки

    func testQuoteAndThematicBreaks() {
        XCTAssertEqual(body("> а\n> б\n>\n> > вложенная\n\n---\n***"),
                       html("<blockquote>", "<p>а<br />", "б</p>", "<blockquote>", "<p>вложенная</p>", "</blockquote>", "</blockquote>", "<hr />", "<hr />"))
    }

    func testOrderedListStartIsWrittenOnlyWhenNotOne() {
        XCTAssertEqual(body("3. один\n4. два\n\nтекст\n\n1. a\n2. b\n\nтекст\n\n0. x"),
                       html("<ol start=\"3\">", "<li>один</li>", "<li>два</li>", "</ol>", "<p>текст</p>", "<ol>", "<li>a</li>", "<li>b</li>", "</ol>",
                            "<p>текст</p>", "<ol start=\"0\">", "<li>x</li>", "</ol>"))
        XCTAssertEqual(body("> 2. а\n> 3. б"), html("<blockquote>", "<ol start=\"2\">", "<li>а</li>", "<li>б</li>", "</ol>", "</blockquote>"))
    }

    func testTightListHasNoParagraphsAndLooseListHas() {
        XCTAssertEqual(body("- а\n- 世界\n  - вложенный\n- 😀"),
                       html("<ul>", "<li>а</li>", "<li>世界", "<ul>", "<li>вложенный</li>", "</ul>", "</li>", "<li>😀</li>", "</ul>"))
        XCTAssertEqual(body("- а\n\n- б\n\n  второй абзац\n\n  ```\n  код\n  ```\n"),
                       html("<ul>", "<li>", "<p>а</p>", "</li>", "<li>", "<p>б</p>", "<p>второй абзац</p>")
                       + pre("код\n") + html("</li>", "</ul>"))
    }

    func testTaskItemsCheckedStateAndMarker() {
        // Отмечены `x` и `X`; `[-]` остаётся обычным текстом. У отмеченного пункта — служебная метка.
        XCTAssertEqual(body("- [x] готово\n- [ ] нет\n- [X] 大\n- [-] тире\n- обычный"),
                       html("<ul>",
                            "<li><input type=\"checkbox\" checked=\"\" disabled=\"\" /> ", "<span data-lac-checked-task></span>", "готово</li>",
                            "<li><input type=\"checkbox\" disabled=\"\" /> нет</li>",
                            "<li><input type=\"checkbox\" checked=\"\" disabled=\"\" /> ", "<span data-lac-checked-task></span>", "大</li>",
                            "<li>[-] тире</li>", "<li>обычный</li>", "</ul>"))
        XCTAssertEqual(body("- [x] а\n\n- [ ] б"),
                       html("<ul>", "<li><input type=\"checkbox\" checked=\"\" disabled=\"\" /> ", "<span data-lac-checked-task></span>", "<p>а</p>", "</li>",
                            "<li><input type=\"checkbox\" disabled=\"\" /> ", "<p>б</p>", "</li>", "</ul>"))
    }

    func testListStyleMarksAndDepthsOnlyWhenRequested() {
        let source = "- а\n  1. б\n     - в\n- [ ] з\n\n2. д"
        let page = render(source, listStyles: true)
        let mark = { (depth: Int, kind: String) in "<span hidden data-lac-list-depth=\"\(depth)\" data-lac-list-kind=\"\(kind)\"></span>" }
        XCTAssertEqual(page.body,
                       html("<ul>", "<li>", mark(1, "unordered"), "а", "<ol>", "<li>", mark(2, "ordered"), "б", "<ul>", "<li>", mark(3, "unordered"), "в</li>",
                            "</ul>", "</li>", "</ol>", "</li>", "<li><input type=\"checkbox\" disabled=\"\" /> з</li>", "</ul>",
                            "<ol start=\"2\">", "<li>", mark(1, "ordered"), "д</li>", "</ol>"))
        XCTAssertEqual(page.listDepths, [1, 2, 3])
        // Метка нужна и пункту свободного списка, но не пункту-задаче.
        let loose = render("- [x] а\n\n- б\n\n- [ ] в", listStyles: true)
        XCTAssertEqual(loose.body,
                       html("<ul>", "<li><input type=\"checkbox\" checked=\"\" disabled=\"\" /> ", "<span data-lac-checked-task></span>", "<p>а</p>", "</li>",
                            "<li>", mark(1, "unordered"), "<p>б</p>", "</li>", "<li><input type=\"checkbox\" disabled=\"\" /> ", "<p>в</p>", "</li>", "</ul>"))
        XCTAssertEqual(loose.listDepths, [1])
        let plain = render(source)
        XCTAssertFalse(plain.body.contains("data-lac-list-depth"))
        XCTAssertTrue(plain.listDepths.isEmpty)
    }

    func testTableWrapperAlignmentsEmptyCellsAndSpan() {
        XCTAssertEqual(body("| а | b | c |\n|:--|:-:|--:|\n| 1 | 世界 | 😀 |\n| x |"),
                       tableOpen() + html("<thead>", "<tr>", "<th align=\"left\">а</th>", "<th align=\"center\">b</th>", "<th align=\"right\">c</th>",
                                          "</tr>", "</thead>", "<tbody>", "<tr>", "<td align=\"left\">1</td>", "<td align=\"center\">世界</td>",
                                          "<td align=\"right\">😀</td>", "</tr>", "<tr>", "<td align=\"left\">x</td>", "<td></td>", "<td></td>",
                                          "</tr>", "</tbody>", "</table></div>"))
        // `colspan` пишется только при значении больше 1, ячейка-заполнитель не выводится.
        XCTAssertEqual(body("| a | b |\n|---|---|\n| wide ||\n"),
                       tableOpen() + html("<thead>", "<tr>", "<th>a</th>", "<th>b</th>", "</tr>", "</thead>", "<tbody>", "<tr>", "<td colspan=\"2\">wide</td>",
                                          "</tr>", "</tbody>", "</table></div>"))
        XCTAssertEqual(body("| `a` | **b** |\n|---|---|\n| [l](u) | ![i](p.png) |"),
                       tableOpen() + html("<thead>", "<tr>", "<th><code>a</code></th>", "<th><strong>b</strong></th>", "</tr>", "</thead>", "<tbody>", "<tr>",
                                          "<td><a href=\"u\">l</a></td>", "<td><img src=\"p.png\" alt=\"i\" /></td>", "</tr>", "</tbody>", "</table></div>"))
    }

    func testTableRowspanMarkerMergesCellsAndSkipsFiller() {
        // Ячейка `^` под ячейкой увеличивает её `rowspan`, сама не выводится (TABLE_SPANS в cmark-gfm).
        XCTAssertEqual(body("| а | b |\n|---|---|\n| x | y |\n| ^ | z |\n| ^ | 世界 |"),
                       tableOpen() + html("<thead>", "<tr>", "<th>а</th>", "<th>b</th>", "</tr>", "</thead>", "<tbody>", "<tr>",
                                          "<td rowspan=\"3\">x</td>", "<td>y</td>", "</tr>", "<tr>", "<td>z</td>", "</tr>", "<tr>",
                                          "<td>世界</td>", "</tr>", "</tbody>", "</table></div>"))
    }

    func testCodeBlocksLanguageEscapingAndEmptyBody() {
        let source = "```swift title\nlet x = \"<\" & 1\n```\n\n```\nplain & \n```\n\n    отступ\n\n```\n```\n\n~~~ c++ x\ny\n~~~\n\n```a\"b<\nz\n```"
        XCTAssertEqual(body(source),
                       pre("let x = &quot;&lt;&quot; &amp; 1\n", language: "swift") + pre("plain &amp; \n") + pre("отступ\n") + pre("")
                       + pre("y\n", language: "c++") + pre("z\n", language: "a&quot;b&lt;"))
        XCTAssertEqual(body("```swift\n```"), pre("", language: "swift"))
        XCTAssertEqual(body("```\nа\nб\n```\n\n```\n\n\n```"), pre("а\nб\n") + pre("\n\n"))
    }

    // MARK: Заголовки

    func testHeadingIDsComeFromModelAndRepeatedTitleGetsSuffix() {
        let page = render("# Привет мир\n\n## 世界\n\n# Привет мир\n\n### 😀 *x*\n\nSetext\n===")
        XCTAssertEqual(page.body,
                       html("<span id=\"lac-heading-привет-мир\"></span>", "<h1>Привет мир</h1>",
                            "<span id=\"lac-heading-世界\"></span>", "<h2>世界</h2>",
                            "<span id=\"lac-heading-привет-мир-1\"></span>", "<h1>Привет мир</h1>",
                            "<span id=\"lac-heading-x\"></span>", "<h3>😀 <em>x</em></h3>",
                            "<span id=\"lac-heading-setext\"></span>", "<h1>Setext</h1>"))
        XCTAssertEqual(page.headingIDs, ["lac-heading-привет-мир", "lac-heading-世界", "lac-heading-привет-мир-1", "lac-heading-x", "lac-heading-setext"])
    }

    func testHeadingNumbersFollowLevelsAndSkipAbsentOnes() {
        let page = render("# Привет мир\n\n## 世界\n\n## B\n\n# Привет мир\n\n### x", numbers: true)
        XCTAssertEqual(page.body,
                       html("<span id=\"lac-heading-привет-мир\"></span>", "<h1><span data-lac-heading-number=\"1. \"></span>Привет мир</h1>",
                            "<span id=\"lac-heading-世界\"></span>", "<h2><span data-lac-heading-number=\"1.1. \"></span>世界</h2>",
                            "<span id=\"lac-heading-b\"></span>", "<h2><span data-lac-heading-number=\"1.2. \"></span>B</h2>",
                            "<span id=\"lac-heading-привет-мир-1\"></span>", "<h1><span data-lac-heading-number=\"2. \"></span>Привет мир</h1>",
                            "<span id=\"lac-heading-x\"></span>", "<h3><span data-lac-heading-number=\"2.0.1. \"></span>x</h3>"))
        XCTAssertFalse(render("# А\n\n## Б").body.contains("data-lac-heading-number"))
    }

    func testHeadingWithLinkAndCodeGetsNumberBeforeContent() {
        XCTAssertEqual(body("# [с  с](u) `к`\n\n| # |\n|--|\n| x |", numbers: true),
                       html("<span id=\"lac-heading-с-с-к\"></span>", "<h1><span data-lac-heading-number=\"1. \"></span><a href=\"u\">с  с</a> <code>к</code></h1>")
                       + tableOpen() + html("<thead>", "<tr>", "<th>#</th>", "</tr>", "</thead>", "<tbody>", "<tr>", "<td>x</td>", "</tr>", "</tbody>", "</table></div>"))
    }

    func testHeadingInsideFootnoteDefinitionHasNoIDAndDoesNotShiftNumbers() {
        // Заголовок в определении сноски ID не получает: без `<span id>` и без номера; соседние заголовки нумеруются подряд.
        let page = render("# А\n\nТ[^1]\n\n[^1]: # заг\n\n# Б", numbers: true)
        XCTAssertEqual(page.body,
                       html("<span id=\"lac-heading-а\"></span>", "<h1><span data-lac-heading-number=\"1. \"></span>А</h1>",
                            "<p>Т<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" data-footnote-ref>1</a></sup></p>",
                            "<span id=\"lac-heading-б\"></span>", "<h1><span data-lac-heading-number=\"2. \"></span>Б</h1>",
                            "<section class=\"footnotes\" data-footnotes>", "<ol>", "<li id=\"fn-1\">", "<h1>заг</h1>",
                            "<a href=\"#fnref-1\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a>",
                            "</li>", "</ol>", "</section>"))
        XCTAssertEqual(page.headingIDs, ["lac-heading-а", "lac-heading-б"])
    }

    func testHeadingInsideQuoteAndListKeepsIDSpan() {
        XCTAssertEqual(body("> # q\n\n- # in list"),
                       html("<blockquote>", "<span id=\"lac-heading-q\"></span>", "<h1>q</h1>", "</blockquote>", "<ul>", "<li>",
                            "<span id=\"lac-heading-in-list\"></span>", "<h1>in list</h1>", "</li>", "</ul>"))
    }

    // MARK: Сноски

    func testFootnotesNumberByFirstReferenceAndAddBackrefs() {
        let source = "Текст[^a] и ещё[^a] и [^b], [^нет].\n\n[^a]: Определение **a**.\n[^b]: Второе\n\n    абзац\n[^unused]: не нужен\n"
        let back = { (id: String, index: String, text: String) in
            " <a href=\"#fnref-\(id)\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"\(index)\" "
                + "aria-label=\"Back to reference \(index)\">\(text)</a>"
        }
        XCTAssertEqual(body(source),
                       html("<p>Текст<sup class=\"footnote-ref\"><a href=\"#fn-a\" id=\"fnref-a\" data-footnote-ref>1</a></sup> и ещё"
                            + "<sup class=\"footnote-ref\"><a href=\"#fn-a\" id=\"fnref-a-2\" data-footnote-ref>1</a></sup> и "
                            + "<sup class=\"footnote-ref\"><a href=\"#fn-b\" id=\"fnref-b\" data-footnote-ref>2</a></sup>, [^нет].</p>",
                            "<section class=\"footnotes\" data-footnotes>", "<ol>", "<li id=\"fn-a\">",
                            "<p>Определение <strong>a</strong>." + back("a", "1", "↩") + back("a-2", "1-2", "↩<sup class=\"footnote-ref\">2</sup>") + "</p>",
                            "</li>", "<li id=\"fn-b\">", "<p>Второе</p>", "<p>абзац" + back("b", "2", "↩") + "</p>", "</li>", "</ol>", "</section>"))
    }

    func testFootnoteReferenceInsideDefinitionCountsInWalkOrder() {
        let source = "Раз[^1] и [^2]\n\n[^2]: Два со ссылкой[^1]\n[^1]: Один\n"
        let back = { (id: String, index: String, text: String) in
            " <a href=\"#fnref-\(id)\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"\(index)\" "
                + "aria-label=\"Back to reference \(index)\">\(text)</a>"
        }
        XCTAssertEqual(body(source),
                       html("<p>Раз<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" data-footnote-ref>1</a></sup> и "
                            + "<sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\" data-footnote-ref>2</a></sup></p>",
                            "<section class=\"footnotes\" data-footnotes>", "<ol>", "<li id=\"fn-1\">",
                            "<p>Один" + back("1", "1", "↩") + back("1-2", "1-2", "↩<sup class=\"footnote-ref\">2</sup>") + "</p>", "</li>",
                            "<li id=\"fn-2\">",
                            "<p>Два со ссылкой<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-2\" data-footnote-ref>1</a></sup>"
                            + back("2", "2", "↩") + "</p>", "</li>", "</ol>", "</section>"))
    }

    func testFootnoteDefinitionEndingWithListPutsBackrefAfterChildren() {
        XCTAssertEqual(body("Т[^x]\n\n[^x]: - пункт\n    - ещё\n"),
                       html("<p>Т<sup class=\"footnote-ref\"><a href=\"#fn-x\" id=\"fnref-x\" data-footnote-ref>1</a></sup></p>",
                            "<section class=\"footnotes\" data-footnotes>", "<ol>", "<li id=\"fn-x\">", "<ul>", "<li>пункт</li>", "<li>ещё</li>", "</ul>",
                            "<a href=\"#fnref-x\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" "
                            + "aria-label=\"Back to reference 1\">↩</a>", "</li>", "</ol>", "</section>"))
    }

    func testFootnoteLabelsAreCaseFoldedAndEncodedInIDs() {
        let output = body("А[^Ёж] б[^ёж] в[^世界]\n\n[^Ёж]: определение\n[^世界]: мир")
        // Метка в адресе — как написана в определении, побайтно закодированная.
        XCTAssertTrue(output.contains("<a href=\"#fn-%D0%81%D0%B6\" id=\"fnref-%D0%81%D0%B6\" data-footnote-ref>1</a>"), output)
        XCTAssertTrue(output.contains("id=\"fnref-%D0%81%D0%B6-2\""), output)
        XCTAssertTrue(output.contains("<li id=\"fn-%E4%B8%96%E7%95%8C\">"), output)
    }

    func testFootnotesWithoutDefinitionsAndUnusedDefinitionsWriteNoSection() {
        XCTAssertEqual(body("A[^zz] и [^yy]"), "<p>A[^zz] и [^yy]</p>\n")
        XCTAssertEqual(body("Текст\n\n[^u]: не нужен"), "<p>Текст</p>\n")
    }

    func testDuplicateFootnoteDefinitionDoesNotCrash() {
        // Какое определение выбирается при повторе метки, cmark не гарантирует: проверяем только, что страница строится.
        let output = body("A[^d]\n\n[^d]: one\n[^d]: two")
        XCTAssertTrue(output.contains("<section class=\"footnotes\" data-footnotes>"), output)
        XCTAssertEqual(output.components(separatedBy: "<li id=\"fn-d\">").count, 2, output)
    }

    // MARK: Пустой экран

    func testEmptyPreviewShowsHintOnlyForPreviewNotExport() {
        let hint = "<p class=\"lac-empty\">\(L10n.tr("预览为空。在编辑器中输入 Markdown 后，内容会显示在这里。"))</p>"
        XCTAssertEqual(body("", preview: true), hint)
        XCTAssertEqual(body(" \n\t\n ", preview: true), hint)
        XCTAssertEqual(body(""), "")
        XCTAssertEqual(body("  ", forExport: true, preview: true), "")
        XCTAssertNotEqual(body("текст", preview: true), hint)
    }

    // MARK: data-sourcepos

    /// Номера первых строк всех `data-sourcepos` в порядке документа.
    private func startLines(_ html: String) -> [Int] {
        let expression = try! NSRegularExpression(pattern: "data-sourcepos=\"(\\d+):\\d+-\\d+:\\d+\"")
        let ns = html as NSString
        return expression.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }
    }

    func testSourcePositionsLinesColumnsInUTF8AndOffInExport() {
        let source = "# Т\n\nпара 世界\n\n> цитата\n\n---\n\n```\nc\n```\n\n| a |\n|---|\n| 1 |"
        let output = body(source, positions: true)
        XCTAssertTrue(output.contains("<h1 data-sourcepos=\"1:1-1:4\">Т</h1>"), output)
        XCTAssertTrue(output.contains("<p data-sourcepos=\"3:1-3:15\">пара 世界</p>"), output)
        XCTAssertEqual(startLines(output), [1, 3, 5, 5, 7, 9, 13, 13, 13, 15, 15], output)
        XCTAssertTrue(output.contains(" data-sourcepos=\"9:1-11:3\"><code>c\n</code></pre>"), output)
        XCTAssertFalse(output.contains("<span id=\"lac-heading-т\" data-sourcepos"), output)
        XCTAssertFalse(output.contains("table-scroll\" role=\"region\" aria-label=\"\(tableLabel)\" tabindex=\"0\" data-sourcepos"), output)
        XCTAssertFalse(body(source, forExport: true, positions: true).contains("data-sourcepos"))
        XCTAssertFalse(body(source).contains("data-sourcepos"))
    }

    func testSourcePositionColumnsCountUTF8BytesAndCRLFLines() {
        // `я𝄞 *x*` — 2 + 4 + 1 + 3 = 10 байт; вторая строка абзаца после `\r\n` — 12 байт кириллицы.
        XCTAssertEqual(body("я𝄞 *x*\n\n世界\r\nвторая", positions: true),
                       html("<p data-sourcepos=\"1:1-1:10\">я𝄞 <em>x</em></p>", "<p data-sourcepos=\"3:1-4:12\">世界<br />", "вторая</p>"))
        let crlf = body("# Т\r\n\r\nпара\r\n", positions: true)
        XCTAssertEqual(startLines(crlf), [1, 3], crlf)
        XCTAssertTrue(crlf.contains("<p data-sourcepos=\"3:1-3:8\">пара</p>"), crlf)
    }

    func testSourcePositionsOfListsStartOnTheSameLinesAsCmark() {
        // Для списков и пунктов сверяются только номера начальных строк: конец контейнера может отличаться от cmark (план U3.1, п. 2.5).
        let output = body("- а\n- б\n\n  в\n\n1. г", positions: true)
        XCTAssertEqual(startLines(output), [1, 1, 1, 2, 2, 4, 6, 6], output)
        XCTAssertEqual(startLines(body("- [x] а\n- [ ] б", positions: true)), [1, 1, 2], body("- [x] а\n- [ ] б", positions: true))
    }

    // MARK: Две точки входа

    func testModelEntranceMatchesStringEntranceAndPageFieldsComeFromModel() {
        let source = "# Привет\n\n- а\n- [x] б\n\n| а |\n|---|\n| 世界 |\n\nТекст[^1]\n\n[^1]: сноска 😀\r\n"
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: true)
        guard let model = MarkdownDocumentParser.parse(source, options: options, isCancelled: { false }) else {
            return XCTFail("Модель не построена")
        }
        let fromModel = MarkdownHTMLRenderer.renderPage(model, text: source, darkMode: false, includeHeadingNumbers: true, includeListStyles: true,
                                                        includeSourcePositions: true, isPreview: true)
        let fromString = render(source, numbers: true, listStyles: true, positions: true, preview: true)
        XCTAssertEqual(fromModel.body, fromString.body)
        XCTAssertEqual(fromModel.headingIDs, Set(model.headingIDs))
        XCTAssertEqual(fromModel.listDepths, [1])
        XCTAssertTrue(fromModel.formulas.isEmpty)
        XCTAssertTrue(fromModel.diagrams.isEmpty)
        XCTAssertFalse(fromModel.omittedHTML)
        XCTAssertTrue(fromModel.rawHTMLBlocks.isEmpty)
    }

    func testFrontMatterAndNulCharacterDoNotBreakOutput() {
        // Front matter не выводится; NUL заменяется на U+FFFD и срезы остаются согласованными.
        XCTAssertEqual(body("---\ntitle: Заметка\n---\n\nТекст"), "<p>Текст</p>\n")
        XCTAssertEqual(body("а\u{0}б"), "<p>а\u{FFFD}б</p>\n")
    }

    func testCancelledParseGivesEmptyPageForStringEntrance() async {
        // Внутри отменённой задачи разбор возвращает nil: страница пустая, но поля настроек сохраняются.
        let syntax = MarkdownSyntaxOptions(preserveEditingWhitespace: true)
        let task = Task { () -> MarkdownRenderedPage in
            while !Task.isCancelled { await Task.yield() }
            return MarkdownHTMLRenderer.renderPage("# Заголовок\n\nТекст 世界", darkMode: false, syntax: syntax, isPreview: true)
        }
        task.cancel()
        let page = await task.value
        XCTAssertEqual(page.body, "")
        XCTAssertTrue(page.headingIDs.isEmpty)
        XCTAssertTrue(page.preserveWhitespace)
        // Готовая модель в отменённой задаче: тело пустое.
        let source = "# Заголовок"
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: true)
        let model = MarkdownDocumentParser.parse(source, options: options, isCancelled: { false })!
        let modelTask = Task { () -> MarkdownRenderedPage in
            while !Task.isCancelled { await Task.yield() }
            return MarkdownHTMLRenderer.renderPage(model, text: source, darkMode: false)
        }
        modelTask.cancel()
        let modelPage = await modelTask.value
        XCTAssertEqual(modelPage.body, "")
        // Без отмены тот же вход даёт обычную страницу.
        XCTAssertTrue(render("# Заголовок\n\nТекст 世界", syntax: syntax, preview: true).body.contains("Текст"))
    }
}
