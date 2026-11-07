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

    /// Маска заметки хранилища: комментарии закрашиваются, длина и переводы строк прежние.
    private func mask(_ text: String) -> MarkdownSourceMask.Result {
        MarkdownSourceMask.mask(text, options: .init(syntax: syntax, isVaultNote: true, detectsFrontMatter: true, includesCritic: false))
    }

    /// Признаки первого комментария: (занимает строки целиком, не рвёт абзац).
    private func flags(_ text: String) -> [Bool] {
        let segment = mask(text).segments.first { $0.kind == .comment }
        return [segment?.occupiesWholeLines ?? false, segment?.keepsParagraph ?? false]
    }

    func testInlineComments() {
        XCTAssertEqual(ranges("a %%hidden%% b"), ["%%hidden%%"])
        XCTAssertEqual(ranges("%%one%% x %%two%%"), ["%%one%%", "%%two%%"])
        XCTAssertEqual(ranges("%%start%% text"), ["%%start%%"])
        XCTAssertEqual(ranges("text %%end%%"), ["%%end%%"])
        XCTAssertEqual(ranges("a %%%% b"), ["%%%%"])
        let body = MarkdownHTMLRenderer.renderPage("a %%hidden%% b", darkMode: false, documentURL: vaultURL).body
        XCTAssertFalse(body.contains("hidden") || body.contains("%%"), body)
        XCTAssertTrue(body.contains("<p>a  b</p>"), body)
    }

    func testMultilineComments() {
        XCTAssertEqual(ranges("a %%one\ntwo%% b"), ["%%one\ntwo%%"])
        XCTAssertEqual(ranges("%%one\n\ntwo%%\nz"), ["%%one\n\ntwo%%"])
        for newline in ["\n", "\r", "\r\n"] {
            let text = "a %%x\(newline)y\(newline)z%% b\(newline)c"
            let masked = mask(text)
            let comment = masked.segments.first { $0.kind == .comment }
            XCTAssertEqual(comment.map { (text as NSString).substring(with: $0.range) }, "%%x\(newline)y\(newline)z%%")
            // Переводы строк на своих местах, текст комментария закрашен.
            XCTAssertEqual(masked.text.components(separatedBy: newline).count, text.components(separatedBy: newline).count)
            XCTAssertEqual(masked.text.utf16.count, text.utf16.count)
            XCTAssertFalse(masked.text.contains("x") || masked.text.contains("z"), masked.text)
            XCTAssertTrue(masked.text.hasPrefix("a ") && masked.text.hasSuffix(" b\(newline)c"), masked.text)
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
        XCTAssertEqual(lineCount(mask(text).text), lineCount(text))
        let page = MarkdownHTMLRenderer.renderPage(text, darkMode: false, documentURL: vaultURL, includeSourcePositions: true)
        XCTAssertFalse(page.body.contains("secret"))
        XCTAssertFalse(page.body.contains("%%"))
        XCTAssertTrue(page.body.contains("before"))
        XCTAssertTrue(page.body.contains("after"))
        XCTAssertTrue(page.body.contains("data-sourcepos=\"8:1-8:4\""), page.body)
        let plain = MarkdownHTMLRenderer.renderPage("# Title\n\nbefore \n\n\n after\n\nlast", darkMode: false, documentURL: vaultURL, includeSourcePositions: true)
        XCTAssertEqual(lineCount(plain.body), lineCount(page.body))
    }

    func testHeadingCalloutAndEmbedInsideCommentAreNotRendered() {
        let text = "%%\n# Hidden heading\n> [!note] Hidden\n![[Other]]\n%%\n\nvisible"
        let body = MarkdownHTMLRenderer.renderPage(text, darkMode: false, documentURL: vaultURL).body
        XCTAssertFalse(body.contains("Hidden"))
        XCTAssertFalse(body.contains("<h1"))
        XCTAssertFalse(body.contains("lac-callout"))
        XCTAssertFalse(body.contains("Other"))
        XCTAssertTrue(body.contains("visible"))
    }

    func testExportKeepsCommentsHidden() {
        let body = MarkdownHTMLRenderer.renderPage("a %%gone%% b", darkMode: false, documentURL: vaultURL, forExport: true).body
        XCTAssertFalse(body.contains("gone"))
    }

    func testOrdinaryDocumentsKeepPercentText() {
        let text = "a %%b%% c\n\nd %%e\n\nf%% g"
        let ordinary = URL(fileURLWithPath: "/tmp/ordinary.md")
        XCTAssertFalse(MarkdownObsidianComment.appliesTo(documentURL: nil))
        XCTAssertFalse(MarkdownObsidianComment.appliesTo(documentURL: ordinary))
        XCTAssertTrue(MarkdownObsidianComment.appliesTo(documentURL: vaultURL))
        for url in [nil, ordinary] {
            let body = MarkdownHTMLRenderer.renderPage(text, darkMode: false, documentURL: url).body
            XCTAssertTrue(body.contains("%%b%%") && body.contains("%%e"), body)
        }
        let hidden = MarkdownHTMLRenderer.renderPage(text, darkMode: false, documentURL: vaultURL).body
        XCTAssertFalse(hidden.contains("%%") || hidden.contains(">b<"), hidden)
    }

    func testCommentLineDoesNotBreakParagraph() {
        // [занимает строки целиком, не рвёт абзац]
        XCTAssertEqual(flags("para\n%%c%%\npara2"), [true, true])
        XCTAssertEqual(lineCount(mask("para\n%%c%%\npara2").text), 2)
        XCTAssertEqual(flags("para\r\n  %%a\r\nb%%  \r\npara2"), [true, true])
        // Между блоками пустая строка остаётся пустой.
        XCTAssertEqual(flags("para\n\n%%c%%\n\npara2"), [true, false])
        XCTAssertEqual(flags("%%c%%\npara2"), [true, false])
        // Внутри цитаты и пункта списка префикс не мешает.
        XCTAssertEqual(flags("> a\n> %%c%%\n> b"), [true, true])
        XCTAssertEqual(flags("> a\n>> %%c%%\n> b"), [true, true])
        XCTAssertEqual(flags("- a\n  %%c%%\n  b"), [true, true])
        XCTAssertEqual(flags("- a\n- %%c%%\n- b"), [true, true])
        XCTAssertEqual(flags("1. a\n2) %%c%%\n3. b"), [true, true])
        // Пустая строка цитаты рвёт абзац и без нас.
        XCTAssertEqual(flags("> a\n>\n> %%c%%\n> b"), [true, false])
        // Текст рядом с комментарием на строке: строка не занята целиком.
        XCTAssertEqual(flags("para\nx %%c%%\npara2"), [false, false])
        // Плотный список выводит текст пункта без `<p>`: абзац не разорван, если пункт один и `<p` нет вовсе.
        for (text, tag, count) in [("para\n%%c%%\npara2", "<p", 1), ("para\r\n  %%c%%\r\npara2", "<p", 1),
                                   ("> a\n> %%c%%\n> b", "<p", 1), ("- a\n  %%c%%\n  b", "<li", 1)] {
            let body = MarkdownHTMLRenderer.renderPage(text, darkMode: false, documentURL: vaultURL).body
            XCTAssertEqual(body.components(separatedBy: tag).count - 1, count, "\(text.debugDescription): \(body)")
            if tag == "<li" { XCTAssertFalse(body.contains("<p"), body) }
            XCTAssertFalse(body.contains("%%") || body.contains(">c<"), "\(text.debugDescription): \(body)")
        }
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
        XCTAssertTrue(mask(big).isIdentity)
        XCTAssertEqual(MarkdownObsidianComment.removed(big, syntax: syntax), big)
    }

    func testMultiLanguageComments() {
        XCTAssertEqual(ranges("Привет %%скрыто%% мир"), ["%%скрыто%%"])
        XCTAssertEqual(ranges("Hello %%hidden%% world"), ["%%hidden%%"])
        XCTAssertEqual(ranges("你好 %%隐藏 🙂%% 世界"), ["%%隐藏 🙂%%"])
    }

    // Зоны исключения берутся из модели: `%%` в кодовом блоке, строчном коде и таблице комментарием не считается.
    func testCommentRangesSkipCodeBlockInlineCodeAndTable() {
        let text = "Заметка 😀 %%скрыто%% 中文\r\n\r\n```\r\n%%код%%\r\n```\r\n\r\n`%%строка%%`\r\n\r\n| a | b |\r\n| - | - |\r\n| %%в таблице%% | x |\r\n"
        XCTAssertEqual(ranges(text), ["%%скрыто%%"])
    }
}
