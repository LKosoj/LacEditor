import XCTest
@testable import LacEditor

final class MarkdownObsidianCommentTests: XCTestCase {
    private let syntax = MarkdownSyntaxOptions()

    private func ranges(_ text: String) -> [String] {
        let source = text as NSString
        return MarkdownObsidianComment.commentRanges(in: text, syntax: syntax).map { source.substring(with: $0) }
    }

    /// Адрес заметки среди локальных копий хранилища: только там комментарии скрываются.
    private var vaultURL: URL {
        VaultStateStore.defaultRoot(vaultID: UUID()).appendingPathComponent("open/note.md")
    }

    private func lineCount(_ text: String) -> Int {
        text.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
    }

    func testInlineComments() {
        XCTAssertEqual(ranges("a %%hidden%% b"), ["%%hidden%%"])
        XCTAssertEqual(ranges("%%one%% x %%two%%"), ["%%one%%", "%%two%%"])
        XCTAssertEqual(ranges("%%start%% text"), ["%%start%%"])
        XCTAssertEqual(ranges("text %%end%%"), ["%%end%%"])
        XCTAssertEqual(ranges("a %%%% b"), ["%%%%"])
        XCTAssertEqual(MarkdownObsidianComment.hidden("a %%hidden%% b", syntax: syntax), "a  b")
    }

    func testMultilineComments() {
        XCTAssertEqual(ranges("a %%one\ntwo%% b"), ["%%one\ntwo%%"])
        XCTAssertEqual(ranges("%%one\n\ntwo%%\nz"), ["%%one\n\ntwo%%"])
        for newline in ["\n", "\r", "\r\n"] {
            let text = "a %%x\(newline)y\(newline)z%% b\(newline)c"
            let hidden = MarkdownObsidianComment.hidden(text, syntax: syntax)
            XCTAssertEqual(hidden, "a \(newline)\(newline) b\(newline)c")
            XCTAssertEqual(hidden.components(separatedBy: newline).count, text.components(separatedBy: newline).count)
        }
    }

    func testCodeFormulasHTMLTablesAndFrontMatterAreSkipped() {
        XCTAssertEqual(ranges("```\n%%a%%\n```\n"), [])
        XCTAssertEqual(ranges("`%%a%%` text"), [])
        XCTAssertEqual(ranges("<div>\n%%a%%\n</div>\n"), [])
        XCTAssertEqual(ranges("---\ntitle: %%a%%\n---\n\ntext"), [])
        XCTAssertEqual(ranges("| a | b |\n| - | - |\n| %%x%% | y |\n"), [])
        // Закрывающий `%%` в коде комментарий не закрывает.
        XCTAssertEqual(ranges("%%open `%%` still"), [])
        XCTAssertEqual(ranges("%%open\n\n```\n%%\n```\n\nend%% tail"), ["%%open\n\n```\n%%\n```\n\nend%%"])
    }

    func testUnclosedAndEscaped() {
        XCTAssertEqual(ranges("text %%never closed\nmore"), [])
        XCTAssertEqual(ranges("%%a%% then %%unclosed"), ["%%a%%"])
        XCTAssertEqual(ranges("100%% довольны"), [])
        XCTAssertEqual(ranges("\\%%not%% comment"), [])
        XCTAssertEqual(ranges("\\\\%%is%% comment"), ["%%is%%"])
        XCTAssertEqual(ranges("%%%"), [])
    }

    func testRangesWindowAndUTF16() {
        let text = "start 🙂 %%привет 你好 🙂\nline%% end 🙂" as NSString
        let all = MarkdownObsidianComment.ranges(in: text, excluded: [])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(text.substring(with: all[0]), "%%привет 你好 🙂\nline%%")
        // Окно начинается в середине комментария.
        let window = NSRange(location: all[0].location + 5, length: 3)
        XCTAssertEqual(MarkdownObsidianComment.ranges(in: text, window: window, excluded: []), all)
        XCTAssertEqual(MarkdownObsidianComment.ranges(in: text, window: NSRange(location: 0, length: 3), excluded: []), [])
    }

    func testHiddenKeepsLineCountAndPreview() {
        let text = "# Title\n\nbefore %%secret\nspread\n\nover lines%% after\n\nlast"
        let hidden = MarkdownObsidianComment.hidden(text, syntax: syntax)
        XCTAssertEqual(lineCount(hidden), lineCount(text))
        let page = MarkdownRenderer.renderPage(text, darkMode: false, documentURL: vaultURL, includeSourcePositions: true)
        XCTAssertFalse(page.body.contains("secret"))
        XCTAssertFalse(page.body.contains("%%"))
        XCTAssertTrue(page.body.contains("before"))
        XCTAssertTrue(page.body.contains("after"))
        XCTAssertTrue(page.body.contains("data-sourcepos=\"8:1-8:4\""), page.body)
        let plain = MarkdownRenderer.renderPage("# Title\n\nbefore \n\n\n after\n\nlast", darkMode: false, documentURL: vaultURL, includeSourcePositions: true)
        XCTAssertEqual(lineCount(plain.body), lineCount(page.body))
    }

    func testHeadingCalloutAndEmbedInsideCommentAreNotRendered() {
        let text = "%%\n# Hidden heading\n> [!note] Hidden\n![[Other]]\n%%\n\nvisible"
        let body = MarkdownRenderer.renderPage(text, darkMode: false, documentURL: vaultURL).body
        XCTAssertFalse(body.contains("Hidden"))
        XCTAssertFalse(body.contains("<h1"))
        XCTAssertFalse(body.contains("lac-callout"))
        XCTAssertFalse(body.contains("Other"))
        XCTAssertTrue(body.contains("visible"))
    }

    func testExportKeepsCommentsHidden() {
        let body = MarkdownRenderer.renderPage("a %%gone%% b", darkMode: false, documentURL: vaultURL, forExport: true).body
        XCTAssertFalse(body.contains("gone"))
    }

    func testOrdinaryDocumentsKeepPercentText() {
        let text = "a %%b%% c\n\nd %%e\n\nf%% g"
        let ordinary = URL(fileURLWithPath: "/tmp/ordinary.md")
        XCTAssertFalse(MarkdownObsidianComment.appliesTo(documentURL: nil))
        XCTAssertFalse(MarkdownObsidianComment.appliesTo(documentURL: ordinary))
        XCTAssertTrue(MarkdownObsidianComment.appliesTo(documentURL: vaultURL))
        for url in [nil, ordinary] {
            let body = MarkdownRenderer.renderPage(text, darkMode: false, documentURL: url).body
            XCTAssertTrue(body.contains("%%b%%") && body.contains("%%e"), body)
        }
        let hidden = MarkdownRenderer.renderPage(text, darkMode: false, documentURL: vaultURL).body
        XCTAssertFalse(hidden.contains("%%") || hidden.contains(">b<"), hidden)
    }

    func testCommentLineDoesNotBreakParagraph() {
        let hidden = MarkdownObsidianComment.hidden("para\n%%c%%\npara2", syntax: syntax)
        XCTAssertEqual(hidden, "para\n\u{200B}\npara2")
        XCTAssertEqual(lineCount(hidden), 2)
        XCTAssertEqual(MarkdownObsidianComment.hidden("para\r\n  %%a\r\nb%%  \r\npara2", syntax: syntax), "para\r\n  \u{200B}\r\n\u{200B}  \r\npara2")
        // Между блоками пустая строка остаётся пустой.
        XCTAssertEqual(MarkdownObsidianComment.hidden("para\n\n%%c%%\n\npara2", syntax: syntax), "para\n\n\n\npara2")
        XCTAssertEqual(MarkdownObsidianComment.hidden("%%c%%\npara2", syntax: syntax), "\npara2")
        // Внутри цитаты и пункта списка префикс не мешает.
        XCTAssertEqual(MarkdownObsidianComment.hidden("> a\n> %%c%%\n> b", syntax: syntax), "> a\n> \u{200B}\n> b")
        XCTAssertEqual(MarkdownObsidianComment.hidden("> a\n>> %%c%%\n> b", syntax: syntax), "> a\n>> \u{200B}\n> b")
        XCTAssertEqual(MarkdownObsidianComment.hidden("- a\n  %%c%%\n  b", syntax: syntax), "- a\n  \u{200B}\n  b")
        XCTAssertEqual(MarkdownObsidianComment.hidden("- a\n- %%c%%\n- b", syntax: syntax), "- a\n- \u{200B}\n- b")
        XCTAssertEqual(MarkdownObsidianComment.hidden("1. a\n2) %%c%%\n3. b", syntax: syntax), "1. a\n2) \u{200B}\n3. b")
        // Пустая строка цитаты рвёт абзац и без нас.
        XCTAssertEqual(MarkdownObsidianComment.hidden("> a\n>\n> %%c%%\n> b", syntax: syntax), "> a\n>\n> \n> b")
        let body = MarkdownRenderer.renderPage("para\n%%c%%\npara2", darkMode: false, documentURL: vaultURL).body
        XCTAssertEqual(body.components(separatedBy: "<p").count - 1, 1, body)
    }

    func testRemovedForPandoc() {
        XCTAssertEqual(MarkdownObsidianComment.removed("a %%x%% b", syntax: syntax), "a b")
        XCTAssertEqual(MarkdownObsidianComment.removed("a%%x%%b", syntax: syntax), "ab")
        XCTAssertEqual(MarkdownObsidianComment.removed("one\n%%only comment%%\ntwo", syntax: syntax), "one\ntwo")
        XCTAssertEqual(MarkdownObsidianComment.removed("one\n  %%a%% %%b%%  \ntwo", syntax: syntax), "one\ntwo")
        XCTAssertEqual(MarkdownObsidianComment.removed("one\n%%a\nb\nc%%\ntwo", syntax: syntax), "one\ntwo")
        XCTAssertEqual(MarkdownObsidianComment.removed("x %%a\nb%% y\ntwo", syntax: syntax), "x y\ntwo")
        XCTAssertEqual(MarkdownObsidianComment.removed("one\r\n%%c%%\r\ntwo\r\n", syntax: syntax), "one\r\ntwo\r\n")
        XCTAssertEqual(MarkdownObsidianComment.removed("no comments %", syntax: syntax), "no comments %")
        XCTAssertEqual(MarkdownObsidianComment.removed("```\n%%a%%\n```", syntax: syntax), "```\n%%a%%\n```")
    }

    func testPlainTextSkipsParsing() {
        XCTAssertFalse(MarkdownObsidianComment.mayContainComment("just 50% text"))
        XCTAssertTrue(MarkdownObsidianComment.mayContainComment("a %% b"))
        XCTAssertFalse(MarkdownObsidianComment.mayContainComment("just 50% text" as NSString))
        let big = String(repeating: "line of text without markers\n", count: 100_000)
        XCTAssertEqual(MarkdownObsidianComment.hidden(big, syntax: syntax), big)
        XCTAssertEqual(MarkdownObsidianComment.removed(big, syntax: syntax), big)
    }

    func testMultiLanguageComments() {
        XCTAssertEqual(ranges("Привет %%скрыто%% мир"), ["%%скрыто%%"])
        XCTAssertEqual(ranges("Hello %%hidden%% world"), ["%%hidden%%"])
        XCTAssertEqual(ranges("你好 %%隐藏 🙂%% 世界"), ["%%隐藏 🙂%%"])
    }
}
