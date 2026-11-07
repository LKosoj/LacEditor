import Foundation
import XCTest
@testable import LacEditor

/// Блоки и контейнеры проектора выделения на модели (U4.5.2): цитата, выноска, список, задача, заголовок, hr, код, таблица, сноски.
/// Входы без строчных стилей: стили проверяет `MarkdownClipboardProjectionInlinesTests`.
final class MarkdownClipboardProjectionBlocksTests: XCTestCase {
    private func project(_ source: String, _ selection: NSRange? = nil) -> MarkdownClipboardCopyService.Fragment? {
        MarkdownClipboardCopyService.project(source, selection: selection ?? NSRange(location: 0, length: (source as NSString).length))
    }

    func testWholeHeadingAndParagraphKeepBreaksAndUTF16() throws {
        let source = "# Заголовок 中文😀\n\nтекст"
        let result = try XCTUnwrap(project(source))
        XCTAssertEqual(result.text, "Заголовок 中文😀\n\nтекст")
        XCTAssertEqual(result.html, "<h1>Заголовок 中文😀</h1><br><br>текст")
    }

    func testQuoteKeepsDepthAndSelectedPartOnly() throws {
        let source = "> внешняя\n>\n> > вложенная 😀"
        let whole = try XCTUnwrap(project(source))
        XCTAssertEqual(whole.text, "> внешняя\n> \n> > вложенная 😀")
        XCTAssertEqual(whole.html, "<blockquote>внешняя<br><br><blockquote>вложенная 😀</blockquote></blockquote>")
        let part = try XCTUnwrap(project(source, (source as NSString).range(of: "вложенная")))
        XCTAssertEqual(part.text, "вложенная")
        XCTAssertEqual(part.html, "вложенная")
    }

    func testListAndTaskItemsKeepMarkersAndState() throws {
        let source = "- один\n- два\n\n1. первый\n2. второй\n\n- [ ] открыта\n- [x] закрыта"
        let result = try XCTUnwrap(project(source))
        XCTAssertEqual(result.text, "• один\n• два\n\n1. первый\n2. второй\n\n• ☐ открыта\n• ☑ закрыта")
        XCTAssertEqual(result.html, "<ul><li>один</li><li>два</li></ul><br><br><ol start=\"1\"><li>первый</li><li>второй</li></ol><br><br><ul><li><input type=\"checkbox\" disabled> открыта</li><li><input type=\"checkbox\" disabled checked> закрыта</li></ul>")
    }

    func testPartialListItemSelectionCopiesOnlySelectedText() throws {
        let source = "- один\n- два три"
        let part = try XCTUnwrap(project(source, (source as NSString).range(of: "три")))
        XCTAssertEqual(part.text, "три")
    }

    func testFencedCodeKeepsLineBreaksForLFAndCRLF() throws {
        for source in ["```swift\n中😀 <x>\nnext\n```", "```swift\r\n中😀 <x>\r\nnext\r\n```", "```swift\r中😀 <x>\rnext\r```"] {
            let result = try XCTUnwrap(project(source), source.debugDescription)
            XCTAssertEqual(result.text, "中😀 <x>\nnext\n", source.debugDescription)
            XCTAssertEqual(result.html, "<pre><code class=\"language-swift\">中😀 &lt;x&gt;\nnext\n</code></pre>", source.debugDescription)
            XCTAssertEqual(result.runs.first?.code, true)
        }
    }

    func testIndentedCodeAndThematicBreak() throws {
        let code = try XCTUnwrap(project("    строка один\n    строка два"))
        XCTAssertEqual(code.text, "строка один\nстрока два")
        XCTAssertEqual(code.html, "<pre><code>строка один\nстрока два</code></pre>")
        let result = try XCTUnwrap(project("до\n\n---\n\nпосле"))
        XCTAssertEqual(result.text, "до\n\n---\n\nпосле")
        XCTAssertEqual(result.html, "до<br><br><hr><br><br>после")
    }

    func testTableCopiesCellTextAndPartialRowSelection() throws {
        let source = "| a | б |\n| - | :-: |\n| 1 | 中 |"
        let result = try XCTUnwrap(project(source))
        XCTAssertEqual(result.text, "a\tб\n1\t中")
        XCTAssertEqual(result.html, "<table><tr><th>a</th><th align=\"center\">б</th></tr><tr><td>1</td><td align=\"center\">中</td></tr></table>")
        XCTAssertEqual(project(source, (source as NSString).range(of: "中"))?.text, "中")
    }

    func testFootnoteDefinitionGetsNumberFromModel() throws {
        let result = try XCTUnwrap(project("Текст[^1].\n\n[^1]: Сноска 😀"))
        XCTAssertEqual(result.text, "Текст1.\n\n[1] Сноска 😀")
        XCTAssertEqual(result.html, "Текст<sup>1</sup>.<br><br>[1] Сноска 😀")
    }

    func testReferenceDefinitionBeforeParagraphKeepsSelectedSource() throws {
        let result = try XCTUnwrap(project("[a]: /x \"t\"\n\nабзац"))
        XCTAssertEqual(result.text, "[a]: /x \"t\"\n\nабзац")
        XCTAssertEqual(result.html, "<pre><code>[a]: /x &quot;t&quot;\n\n</code></pre>абзац")
    }

    // Срез маркера или заголовка выноски копируется обычным текстом исходника (без `> ` и без оформления).
    func testCalloutHeadPartsCopyAsPlainText() throws {
        for newline in ["\n", "\r\n"] {
            let source = "> [!warning] Заголовок 中文😀" + newline + "> тело"
            let raw = source as NSString
            for part in ["warning", "Заголовок", "arning] Заг", "Заголовок 中文😀"] {
                let result = try XCTUnwrap(project(source, raw.range(of: part)), part)
                XCTAssertEqual(result.text, part, part)
                XCTAssertEqual(result.html, part, part)
            }
            XCTAssertNotNil(project(source, raw.range(of: "тело")))
            XCTAssertEqual(project(source, raw.range(of: "] Заг"))?.text, "] Заг", "через границу маркера и заголовка")
        }
    }

    func testLineBreaksOfAllKindsInQuoteAndList() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "> цитата" + newline + "> вторая" + newline + newline + "- пункт" + newline + "- ещё"
            let result = try XCTUnwrap(project(source), newline.debugDescription)
            XCTAssertEqual(result.text, "> цитата\n> вторая\n\n• пункт\n• ещё", newline.debugDescription)
            XCTAssertEqual(result.html, "<blockquote>цитата<br>вторая</blockquote><br><br><ul><li>пункт</li><li>ещё</li></ul>", newline.debugDescription)
        }
    }

    func testCalloutSelectAllCopiesAsQuoteAndCutMarkerCopiesAsText() throws {
        let source = "> [!warning] Заголовок\n> текст"
        let whole = try XCTUnwrap(project(source))
        XCTAssertEqual(whole.text, "> [!warning] Заголовок\n> текст")
        XCTAssertEqual(whole.html, "<blockquote>[!warning] Заголовок<br>текст</blockquote>")
        let raw = source as NSString
        let body = try XCTUnwrap(project(source, raw.range(of: "текст")))
        XCTAssertEqual(body.text, "текст")
        let cut = try XCTUnwrap(project(source, NSRange(location: 4, length: raw.range(of: "текст").location - 4)), "выделение режет маркер")
        XCTAssertEqual(cut.text, "warning] Заголовок\n")
    }

    func testFootnoteNumbersFollowCmarkOrder() throws {
        let source = "X[^1]\n\n[^1]: n[^3]\n\nY[^2] и ещё [^2]\n\n[^2]: p\n\n[^3]: q"
        let raw = source as NSString
        XCTAssertEqual(project(source, raw.range(of: "X[^1]"))?.text, "X1")
        XCTAssertEqual(project(source, raw.range(of: "Y[^2] и ещё [^2]"))?.text, "Y3 и ещё 3")
        XCTAssertEqual(project(source, raw.range(of: "[^2]: p"))?.text, "[3] p")
        XCTAssertEqual(project(source, raw.range(of: "[^3]: q"))?.text, "[2] q")
    }

    func testFencedCodeRefusesSelectionCuttingCRLF() throws {
        let source = "```\r\nabc\r\ndef\r\n```"
        let raw = source as NSString
        let crlf = raw.range(of: "abc\r\n").location + 3
        XCTAssertNil(project(source, NSRange(location: crlf + 1, length: 5)), "начало между \\r и \\n")
        XCTAssertNil(project(source, NSRange(location: crlf - 3, length: 4)), "конец между \\r и \\n")
        XCTAssertEqual(project(source, NSRange(location: crlf - 3, length: 3))?.text, "abc")
    }

    func testTableWithColspanKeepsPlaceholderEmpty() throws {
        let source = "| a | б |\n| - | - |\n| в || \n"
        let whole = try XCTUnwrap(project(source))
        XCTAssertEqual(whole.text, "a\tб\nв\t\n")
        XCTAssertEqual(whole.html, "<table><tr><th>a</th><th>б</th></tr><tr><td>в</td><td></td></tr></table><br>")
    }

    func testNeighbourParagraphOfReferenceDefinitionsWithTabAndLink() throws {
        for newline in ["\n", "\r", "\r\n"] {
            let source = ["- [a]: /x", "  [b]: /y", "  中文\tbold\t[link][b] $x$"].joined(separator: newline)
            let result = try XCTUnwrap(project(source, (source as NSString).range(of: "bold")), newline.debugDescription)
            XCTAssertEqual(result.text, "bold", newline.debugDescription)
            XCTAssertEqual(result.html, "bold", newline.debugDescription)
        }
    }

    func testFootnoteReferenceInsideDefinitionBodyKeepsCmarkNumber() throws {
        let source = "X[^1]\n\n[^1]: n[^3]\n\n[^3]: q"
        let result = try XCTUnwrap(project(source))
        XCTAssertEqual(result.text, "X1\n\n[1] n2\n\n[2] q")
        XCTAssertEqual(result.html, "X<sup>1</sup><br><br>[1] n<sup>2</sup><br><br>[2] q")
    }

    /// Ячейка с данными, но без доказанного диапазона: частичное выделение таблицы не угадывает, а даёт `nil`.
    func testPartialTableSelectionWithCellWithoutContentRangeIsRefused() throws {
        let source = "| a | б |\n| - | - |\n| 1 | 2 |"
        var model = try XCTUnwrap(MarkdownDocumentParser.parse(source, options: .init(syntax: .init(), includes: [.emoji], isVaultNote: false, detectsFrontMatter: true)))
        let raw = source as NSString
        let selection = NSRange(location: raw.range(of: "| 1").location, length: raw.length - raw.range(of: "| 1").location)
        func run(_ model: MarkdownDocumentModel) -> MarkdownClipboardCopyService.Fragment? {
            MarkdownClipboardCopyService.ProjectionState(
                markdown: source, selection: selection, includeImages: false, documentURL: nil, allowRemoteImages: false,
                syntax: .init(), detailsOpenOverrides: [:], emojiCandidates: [], emoji: [:], model: model).run(model)
        }
        XCTAssertNotNil(run(model), "с целой моделью выделение копируется")
        guard let index = model.blocks.firstIndex(where: { if case .table = $0.kind { return true } else { return false } }),
              case var .table(table) = model.blocks[index].kind else { return XCTFail("нет таблицы") }
        table.rows[table.rows.count - 1].cells[0].range = NSRange(location: NSNotFound, length: 0)
        model.blocks[index].kind = .table(table)
        XCTAssertNil(run(model))
    }

    /// Выделение начинается внутри строки заголовка таблицы: ячейка выбрана по своему месту между `|`, а не по тексту.
    func testPartialTableStartingInsideHeaderRowKeepsTableAndColumns() throws {
        let source = "| L | R |\n| --- | --- |\n| 1 | x |"
        let result = try XCTUnwrap(project(source, NSRange(location: 3, length: (source as NSString).length - 3)))
        XCTAssertEqual(result.text, "\tR\n1\tx")
        XCTAssertEqual(result.html, "<table><tr><th></th><th>R</th></tr><tr><td>1</td><td>x</td></tr></table>")
    }

    /// Табуляция в начале строки после определения ссылки в текст не попадает (отступ абзаца, а не содержимое).
    func testIndentAfterReferenceDefinitionIsNotCopied() throws {
        let top = try XCTUnwrap(project("[id]: /url\n\thello"))
        XCTAssertEqual(top.text, "[id]: /url\nhello")
        XCTAssertEqual(top.html, "<pre><code>[id]: /url\n</code></pre>hello")
        let item = try XCTUnwrap(project("- [id]: /url\n\t中文 hello"))
        XCTAssertEqual(item.text, "• [id]: /url\n中文 hello")
        let crlf = try XCTUnwrap(project("- [id]: /url\r\n\t中文 hello"))
        XCTAssertEqual(crlf.text, "• [id]: /url\r\n中文 hello")
    }

    /// Цитата целиком с HTML-блоком не копируется: HTML-блок в цитате проекция не разбирает.
    func testWholeQuoteWithHTMLBlockIsRefused() {
        XCTAssertNil(project("> <div><img src='https://example.com/a.png'></div>"))
    }
}
