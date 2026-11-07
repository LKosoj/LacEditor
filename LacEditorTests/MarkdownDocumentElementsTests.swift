import Foundation
import XCTest
@testable import LacEditor

/// Индекс элементов модели (U2.5c): `elements` модели, флаг и отмена.
final class MarkdownDocumentElementsTests: XCTestCase {
    private func options(_ includes: MarkdownDocumentModel.Includes, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions()) -> MarkdownDocumentModel.Options {
        MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: false, detectsFrontMatter: true)
    }

    private func elements(_ text: String) -> MarkdownElementIndex? {
        MarkdownDocumentParser.parse(text, options: options([.elementIndex, .wikiLinks]))?.elements
    }

    private func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Характерные входы: цитаты, пункты, задачи, сноски, таблицы, формулы, HTML, front matter, setext, CJK, эмодзи, `\r\n`.
    private let samples: [String] = [
        "---\ntitle: Тест\n---\n\n# Заголовок **жирный** [ссылка](https://example.com)\n\nтекст\n",
        "> цитата *курсив*\n\n> [!NOTE]\n> алерт `код`\n\n> [!warning]- Выноска\n> текст\n",
        "- пункт\n  - вложенный **пункт**\n\n- [x] задача\n- [ ] ещё ~~задача~~\n\n1. один\n2. два\n",
        "```swift\nlet a = 1\n```\n\n```\nпросто\n```\n\n    отступный код\n\n```js title=\"x\"\ncode\n```\n",
        "| a | **b** |\n|---|---|\n| 1 | [[в таблице]] |\n\nСноска[^1] и ещё[^2].\n\n[^1]: **текст** сноски\n[^2]: ![i](a.png)\n",
        "$$\nx^2\n$$\n\nСтрочная $a+b$ формула и **$c$**.\n\n<div>html блок</div>\n\nАбзац <span>с html</span>.\n",
        "你好 😀 **加粗** 😀 *斜体* [链接](u) `代码` tail\n\n# 日本語 ![картинка](a.png) заголовок\n",
        "Setext заголовок\nвторая строка\n===\n\nДругой *заголовок*\n---\n",
        "Ссылка [[Заметка|псевдоним]] и [ref][r] и <https://a.b> и ![[Встраивание]] и ![i][r].\n\n[r]: http://example.com\n",
        "> - цитата со списком\n>   - вложенный\n> ```\n> код в цитате\n> ```\n\n- > цитата в пункте\n",
        "- пункт\n\n  ```\n  код в пункте\n  ```\n\n  | a |\n  |---|\n  | b |\n",
        "<details><summary>S</summary>\n\nтекст **жирный**\n\n</details>\n\nконец\n",
        "Незакрытая **жирность и `код\n\n> незакрытая цитата\n- пункт *без закрытия\n",
        "Строка с\ttab\n\n- пункт\n\tпродолжение\n\n[toc]\n\n---\n\n***\n",
        "Текст <b>жирный</b> <em>курсив</em> <s>зачёркнутый</s> <a href=\"u\">ссылка</a> <u>подчёркнутый</u> и <i>**вложенный**</i>.\n\n| a |\n|---|\n| <b>в ячейке</b> $x$ |\n",
        "Текст <span style=\"font-family:serif\">**слово** $x$</span> дальше\n",
        "Текст <ruby>основа<rt>**k**</rt></ruby> и <br class=x> и <br> конец\n",
        "Ссылка [текст [вложенный](b)](a) и [![alt](i.png)](u) и ![внутри [ссылка](l)](i.png) конец\n",
        "> цитата <b>жирный</b> <a href=\"u\">ссылка</a> **x**\n\n- пункт <b>жирный</b> <a href=\"u\">ссылка</a>\n\nСноска[^1]\n\n[^1]: <b>жирный</b> <a href=\"u\">ссылка</a> $f$ и **x**\n",
        "> цитата\n> - пункт\n>\tс табом **x**\n> второй\n\n> `код` и $y$\n",
        "Текст <span style=\"font-family:serif\">[[Заметка]]</span> дальше и [[Открытая]] ещё\n",
        "Последняя строка без перевода",
        "# Заголовок в конце",
        "",
        "\n\n\n",
    ]

    private func corpus() throws -> [(id: String, text: String)] {
        var items = try BaselineCorpus.documents().map { ($0.id, $0.text) }
        items += try BaselineCorpus.crlfDocuments().map { ($0.id, $0.text) }
        items += samples.enumerated().map { ("sample\($0.offset)", $0.element) }
        items += samples.enumerated().map { ("sample\($0.offset)[crlf]", crlf($0.element)) }
        return items
    }

    // MARK: - Индекс элементов

    func testBareAutolinkRangeExcludesPrecedingSpace() throws {
        let text = "Текст www.example.com и 😀 https://example.com/a_b, <https://x.y> конец\n"
        let index = try XCTUnwrap(elements(text))
        let nsText = text as NSString
        let links = index.flattened.inlines.filter { $0.1 == .link }.map { nsText.substring(with: $0.0) }
        XCTAssertEqual(links, ["www.example.com", "https://example.com/a_b", "<https://x.y>"])
    }

    func testElementPathReportsKnownKinds() throws {
        let text = "## Заголовок **жирный**\n\n- [x] задача\n"
        let index = try XCTUnwrap(elements(text))
        let bold = (text as NSString).range(of: "жирный").location
        XCTAssertEqual(index.path(at: bold).elements.map(\.kind), [.heading(2), .strong])
        XCTAssertEqual(index.path(at: (text as NSString).range(of: "задача").location).elements.map(\.kind), [.task])
    }

    // MARK: - Флаг и отмена

    func testElementsAreNilWithoutFlag() throws {
        for (id, text) in try corpus() {
            let result = try XCTUnwrap(MarkdownDocumentParser.parse(text, options: options([.wikiLinks, .emoji, .readableText, .blockIndex, .editorContext])), id)
            XCTAssertNil(result.elements, "\(id): elements без флага")
            let flagged = try XCTUnwrap(MarkdownDocumentParser.parse(text, options: options([.elementIndex])), id)
            XCTAssertNotNil(flagged.elements, "\(id): elements с флагом")
        }
    }

    func testCancellationGivesNilWithElementIndex() {
        var calls = 0
        let text = "# Заголовок\n\nТекст **жирный**\n\n- пункт\n"
        let result = MarkdownDocumentParser.parse(text, options: options([.elementIndex]), isCancelled: { calls += 1; return calls > 40 })
        XCTAssertNil(result)
        XCTAssertGreaterThan(calls, 40, "отмена сработала не сразу")
    }

    func testDirectCallCancelledGivesNil() throws {
        let text = "# Заголовок **жирный**\n"
        let result = try XCTUnwrap(MarkdownDocumentParser.parse(text, options: options([.elementIndex])))
        XCTAssertNotNil(MarkdownDocumentParser.elementIndex(of: result, text: text as NSString, htmlPairs: [], isCancelled: { false }))
        XCTAssertNil(MarkdownDocumentParser.elementIndex(of: result, text: text as NSString, htmlPairs: [], isCancelled: { true }))
    }
}
