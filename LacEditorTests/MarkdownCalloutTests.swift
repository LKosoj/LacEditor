import XCTest
@testable import LacEditor

final class MarkdownCalloutTests: XCTestCase {
    private var suite: String?

    override func setUp() {
        super.setUp()
        use("en")
    }

    override func tearDown() {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        L10n.configure()
        super.tearDown()
    }

    private func use(_ language: String) {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let name = "MarkdownCalloutTests-\(UUID().uuidString)"
        suite = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(language, forKey: L10n.languageKey)
        L10n.configure(defaults: defaults)
    }

    private func html(_ markdown: String, forExport: Bool = false) -> String {
        MarkdownHTMLRenderer.renderPage(markdown, darkMode: false, forExport: forExport).body
    }

    func testMarkerParsing() throws {
        let plain = try XCTUnwrap(MarkdownCalloutRender.marker(in: "[!note] Title"))
        XCTAssertEqual(plain.marker, .init(type: "note", fold: .none))
        XCTAssertEqual(plain.length, 7)
        XCTAssertEqual(try XCTUnwrap(MarkdownCalloutRender.marker(in: "[!NOTE]")).marker.type, "NOTE")
        XCTAssertEqual(try XCTUnwrap(MarkdownCalloutRender.marker(in: "[!Note]+ x")).marker, .init(type: "Note", fold: .open))
        XCTAssertEqual(try XCTUnwrap(MarkdownCalloutRender.marker(in: "[!note]-\nbody")).marker, .init(type: "note", fold: .closed))
        XCTAssertEqual(try XCTUnwrap(MarkdownCalloutRender.marker(in: "[!my-type]  x")).marker.type, "my-type")
        XCTAssertNotNil(MarkdownCalloutRender.marker(in: "[!note]<br />x"))
    }

    func testTitleIsSeparatedWithAndWithoutSoftBreaks() {
        for keepsBreaks in [true, false] {
            let syntax = MarkdownSyntaxOptions(preserveEditingSoftBreaks: keepsBreaks)
            let result = MarkdownHTMLRenderer.renderPage("> [!note] Заголовок\n> текст тела", darkMode: false, syntax: syntax).body
            XCTAssertTrue(result.contains("<span class=\"lac-callout-text\">Заголовок</span>"), "\(keepsBreaks): \(result)")
            XCTAssertTrue(result.contains("текст тела</p>"), "\(keepsBreaks): \(result)")
            let bare = MarkdownHTMLRenderer.renderPage("> [!tip]\n> только тело", darkMode: false, syntax: syntax).body
            XCTAssertFalse(bare.contains("lac-callout-text"), "\(keepsBreaks): \(bare)")
            XCTAssertTrue(bare.contains("только тело"), "\(keepsBreaks): \(bare)")
            let nested = MarkdownHTMLRenderer.renderPage("- > [!note]- Внутри\n  > тело", darkMode: false, syntax: syntax).body
            XCTAssertTrue(nested.contains("lac-callout-text\">Внутри</span>") && nested.contains("тело"), "\(keepsBreaks): \(nested)")
            let code = MarkdownHTMLRenderer.renderPage("```\n> [!note] Код\n> текст\n```", darkMode: false, syntax: syntax).body
            XCTAssertFalse(code.contains("lac-callout"), code)
        }
        // Выноска считается только в начале цитаты; такой же текст в коде выноской не становится.
        let both = html("> [!note] T\n> x\n\n```\n> [!note] T\n> x\n```")
        XCTAssertEqual(both.components(separatedBy: "lac-callout-text\">T</span>").count - 1, 1, both)
        XCTAssertTrue(both.contains("[!note] T"), both)
        let notFirst = html("> text\n> [!note] T\n> x")
        XCTAssertFalse(notFirst.contains("lac-callout"), notFirst)
        XCTAssertTrue(notFirst.contains("[!note] T"), notFirst)
        let plain = html("plain [!note] text")
        XCTAssertFalse(plain.contains("lac-callout"), plain)
        XCTAssertTrue(plain.contains("plain [!note] text"), plain)
    }

    func testMarkerRejectsNonCallouts() {
        for text in ["[! note] x", "[!] x", "[!note x", "[!note]текст", "[!note]+текст", "[!a<b>] x", "note", "[!note"] {
            XCTAssertNil(MarkdownCalloutRender.marker(in: Substring(text)), text)
        }
    }

    func testKindsAndSynonyms() {
        let synonyms: [String: MarkdownCalloutKind] = [
            "summary": .abstract, "TLDR": .abstract, "hint": .tip, "important": .tip, "check": .success, "done": .success,
            "help": .question, "faq": .question, "caution": .warning, "attention": .warning, "fail": .failure, "missing": .failure,
            "error": .danger, "cite": .quote, "Note": .note
        ]
        for (type, kind) in synonyms { XCTAssertEqual(MarkdownCalloutKind.kind(forType: type), kind, type) }
        XCTAssertNil(MarkdownCalloutKind.kind(forType: "my-type"))
        XCTAssertEqual(MarkdownCalloutKind.allCases.count, 13)
        for kind in MarkdownCalloutKind.allCases {
            let result = html("> [!\(kind.rawValue)] T\n> body")
            XCTAssertTrue(result.contains("lac-callout lac-callout-\(kind.rawValue)"), kind.rawValue)
            XCTAssertTrue(result.contains("aria-hidden=\"true\">\(kind.symbol)</span>"), kind.rawValue)
            XCTAssertFalse(result.contains("<blockquote"), kind.rawValue)
        }
        XCTAssertTrue(html("> [!SUMMARY] T\n> b").contains("lac-callout-abstract"))
    }

    func testUnknownTypeIsNoteWithOwnLabel() {
        let result = html("> [!my-type] Title\n> body")
        XCTAssertTrue(result.contains("lac-callout-note"))
        XCTAssertTrue(result.contains("<span class=\"lac-callout-label\">My-type</span>"))
    }

    func testUnsafeTypeIsNotCallout() {
        let result = html("> [!a<b>] x\n> y")
        XCTAssertFalse(result.contains("lac-callout"))
        XCTAssertTrue(result.contains("<blockquote"))
    }

    func testTitleAndDefaultLabel() {
        let withTitle = html("> [!warning] Careful\n> body")
        XCTAssertTrue(withTitle.contains("<span class=\"lac-callout-label\">Warning</span><span class=\"lac-callout-text\">Careful</span>"))
        XCTAssertTrue(withTitle.contains("role=\"note\" aria-label=\"Warning: Careful\""))
        let bare = html("> [!warning]\n> body")
        XCTAssertFalse(bare.contains("lac-callout-text"))
        XCTAssertTrue(bare.contains("aria-label=\"Warning\""))
    }

    func testTitleKeepsInlineHTMLAndAriaLabelIsPlain() {
        let result = html("> [!tip] **Bold** & [link](https://example.com)\n> body")
        XCTAssertTrue(result.contains("<span class=\"lac-callout-text\"><strong>Bold</strong> &amp; <a href=\"https://example.com\">link</a></span>"), result)
        XCTAssertTrue(result.contains("aria-label=\"Tip: Bold &amp; link\""), result)
        let quote = html("> [!tip] Say 1 < 2 \"hi\"\n> body")
        XCTAssertTrue(quote.contains("aria-label=\"Tip: Say 1 &lt; 2 "), quote)
    }

    func testBodyKeepsBlocks() {
        let result = html("> [!info] T\n> first\n> second\n>\n> - one\n> - two\n>\n> ```\n> code\n> ```")
        XCTAssertTrue(result.contains("<div class=\"lac-callout-body\"><p>first<br />\nsecond</p>"), result)
        XCTAssertTrue(result.contains("<li>one</li>"), result)
        XCTAssertTrue(result.contains("<code>code\n</code>"))
        XCTAssertEqual(result.components(separatedBy: "<div").count, result.components(separatedBy: "</div>").count)
    }

    func testTitleOnlyHasNoBody() {
        let result = html("> [!note] Only title")
        XCTAssertTrue(result.contains("lac-callout-title"))
        XCTAssertFalse(result.contains("lac-callout-body"))
    }

    func testNestedCallouts() {
        let result = html("> [!note] Outer\n> text\n>\n> > [!tip] Inner\n> > inner text\n", forExport: false)
        XCTAssertEqual(result.components(separatedBy: "class=\"lac-callout ").count - 1, 2)
        XCTAssertTrue(result.contains("lac-callout-tip"))
        XCTAssertEqual(result.components(separatedBy: "<div").count, result.components(separatedBy: "</div>").count)
        XCTAssertFalse(result.contains("blockquote"))
    }

    func testSourcePositionMovesToCallout() {
        let page = MarkdownHTMLRenderer.renderPage("> [!note] T\n> body", darkMode: false, includeSourcePositions: true)
        XCTAssertTrue(page.body.contains("role=\"note\""))
        XCTAssertTrue(page.body.contains("data-sourcepos=\"1:1-2:"))
        XCTAssertFalse(page.body.contains("<blockquote"))
    }

    func testCalloutInListAndPlainQuoteUntouched() {
        let list = html("- item\n  > [!warning] Inside\n  > text")
        XCTAssertTrue(list.contains("<li>"))
        XCTAssertTrue(list.contains("lac-callout-warning"))
        let quote = html("> plain\n> quote")
        XCTAssertTrue(quote.contains("<blockquote"))
        XCTAssertFalse(quote.contains("lac-callout"))
        let plainInCallout = html("> [!note] A\n> x\n\n> [!tip] B\n> y\n\n> normal")
        XCTAssertEqual(plainInCallout.components(separatedBy: "class=\"lac-callout ").count - 1, 2)
        XCTAssertEqual(plainInCallout.components(separatedBy: "<blockquote").count - 1, 1)
    }

    func testGitHubAlertKeepsOldPath() {
        let alert = html("> [!NOTE]\n> text")
        XCTAssertTrue(alert.contains("lac-alert"))
        XCTAssertFalse(alert.contains("lac-callout"))
        let titled = html("> [!NOTE] Title\n> text")
        XCTAssertTrue(titled.contains("lac-callout-note"))
        XCTAssertFalse(titled.contains("lac-alert"))
    }

    func testCodeIsUntouched() {
        let fenced = html("```\n> [!note] x\n```\n\n`> [!note]`")
        XCTAssertFalse(fenced.contains("lac-callout"))
        XCTAssertTrue(fenced.contains("[!note]"))
        let indentedQuoteInCode = html("```\n<blockquote>\n[!note]\n```")
        XCTAssertFalse(indentedQuoteInCode.contains("lac-callout"))
    }

    func testFolding() {
        let open = html("> [!tip]+ Open\n> body")
        XCTAssertTrue(open.contains("<details class=\"lac-callout lac-callout-tip\" open"))
        XCTAssertTrue(open.contains("<summary class=\"lac-callout-title\"><span class=\"lac-callout-icon\""))
        XCTAssertTrue(open.contains("</summary>"))
        XCTAssertTrue(open.contains("</details>"))
        let closed = html("> [!tip]- Closed\n> body")
        XCTAssertTrue(closed.contains("<details class=\"lac-callout lac-callout-tip\" aria-label"))
        XCTAssertFalse(closed.contains(" open"))
    }

    func testExportExpandsCollapsed() {
        XCTAssertTrue(html("> [!tip]- Closed\n> body", forExport: true).contains("<details class=\"lac-callout lac-callout-tip\" open"))
        let note = html("> [!note]- T\n> x", forExport: true)
        XCTAssertTrue(note.contains(" open"), note)
        XCTAssertTrue(html("> [!note]- T\n> x").contains("<details class=\"lac-callout lac-callout-note\" aria-label"))
    }

    func testOrdinaryMarkdownHasNoCallouts() {
        let page = html("text\n\n> quote\n")
        XCTAssertFalse(page.contains("lac-callout"), page)
        XCTAssertTrue(page.contains("<p>text</p>") && page.contains("<blockquote>") && page.contains("quote"), page)
        let marker = html("[!note]")
        XCTAssertFalse(marker.contains("lac-callout"), marker)
        XCTAssertTrue(marker.contains("[!note]"), marker)
    }

    func testStylesUseOnlyExistingVariables() {
        let css = MarkdownObsidianPreviewStyle.css
        XCTAssertTrue(css.contains(".lac-callout"))
        XCTAssertTrue(css.contains("@media print"))
        XCTAssertFalse(css.contains("#"), "в стилях выносок не должно быть литералов цвета")
        XCTAssertTrue(MarkdownHTMLRenderer.renderPage("x", darkMode: false).html.contains(".lac-callout-title"))
    }

    func testLabelsFollowInterfaceLanguage() {
        for language in ["en", "ru", "zh-Hans"] {
            use(language)
            let result = html("> [!warning] Title\n> body")
            let label = L10n.tr("标注·警告")
            XCTAssertTrue(result.contains("<span class=\"lac-callout-label\">\(label)</span>"), language)
            XCTAssertTrue(result.contains("aria-label=\"\(L10n.tr("标注标签 %@：%@", label, "Title"))\""), language)
        }
        use("ru")
        XCTAssertEqual(MarkdownCalloutKind.warning.label, "Предупреждение")
    }

    func testObsidianTextsExistInAllCatalogs() throws {
        let keys = [
            "标注·笔记", "标注·摘要", "标注·信息", "标注·待办", "标注·技巧", "标注·成功", "标注·疑问", "标注·警告", "标注·失败",
            "标注·危险", "标注·缺陷", "标注·示例", "标注·引文", "标注标签 %@：%@", "嵌入的笔记：%@", "打开笔记：%@", "未找到笔记：%@",
            "未找到章节：%@", "附件不可用：%@", "嵌入内容已截断"
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, "\(language): \(key)")
                XCTAssertEqual(text.components(separatedBy: "\n\"\(key)\" =").count - 1, 1, "\(language): \(key)")
            }
        }
    }
}
