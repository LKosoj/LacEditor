import Foundation
import XCTest
@testable import LacEditor

/// Маскировка перед cmark (U2.2): инварианты длины и строк, правила замены и сверка с нынешними распознавателями.
final class MarkdownSourceMaskTests: XCTestCase {
    private let syntax = MarkdownSyntaxOptions()

    private func options(vault: Bool = true, critic: Bool = true, front: Bool = true) -> MarkdownSourceMask.Options {
        MarkdownSourceMask.Options(syntax: syntax, isVaultNote: vault, detectsFrontMatter: front, includesCritic: critic)
    }

    private func mask(_ text: String, vault: Bool = true, critic: Bool = true, excluded: [NSRange]? = nil) -> MarkdownSourceMask.Result {
        MarkdownSourceMask.mask(text, options: options(vault: vault, critic: critic), excluded: excluded)
    }

    /// Точные запрещённые диапазоны из дерева cmark — эталон для оценки.
    private func treeExcluded(_ text: String) -> [NSRange] {
        MarkdownPresentationBuilder.parse(text, syntax: syntax).elements.excludedRanges(intersecting: NSRange(location: 0, length: (text as NSString).length))
    }

    private func isCritic(_ kind: MarkdownSourceMask.Kind) -> Bool { if case .critic = kind { return true } else { return false } }

    private func lineBreakPositions(_ units: [UInt16]) -> [Int] {
        units.indices.filter { units[$0] == 10 || units[$0] == 13 }
    }

    /// Инварианты маски: длина, CR/LF на местах, изменения только внутри сегментов и только в заменитель или пробел.
    private func assertInvariants(_ text: String, _ result: MarkdownSourceMask.Result, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let original = Array(text.utf16), masked = Array(result.text.utf16)
        XCTAssertEqual(masked.count, original.count, message, file: file, line: line)
        guard masked.count == original.count else { return }
        XCTAssertEqual(lineBreakPositions(masked), lineBreakPositions(original), message, file: file, line: line)
        XCTAssertEqual(result.isIdentity, result.text == text, message, file: file, line: line)
        for index in original.indices where original[index] != masked[index] {
            XCTAssertTrue(result.segments.contains { NSLocationInRange(index, $0.range) }, "\(message): знак \(index) изменён вне сегментов", file: file, line: line)
            XCTAssertTrue(masked[index] == result.placeholder || masked[index] == 32, "\(message): знак \(index) заменён не заменителем", file: file, line: line)
            if masked[index] != result.placeholder && masked[index] != 32 { return }
        }
    }

    // MARK: - Инварианты

    func testInvariantsOnCorpusAndShortTexts() throws {
        let documents = try BaselineCorpus.documents() + BaselineCorpus.crlfDocuments()
        for item in documents {
            assertInvariants(item.text, mask(item.text), item.id)
        }
        let samples = [
            "{++你好😀++} и {>>комментарий😀\nвторая строка<<} %%скрыто%% текст",
            "---\ntitle: Заголовок 😀\n---\n\n%%x%%\n\n{--a--}",
            "a %%x\r\ny\r\nz%% b\r\n{~~а~>б~~}\r\n",
            "a\r%%x\r\r{==b==}\r",
            "{++a\u{2028}b++} %%c%%",
            "\u{FEFF}---\na: 1\n---\ntext",
        ]
        for sample in samples { assertInvariants(sample, mask(sample), sample) }
    }

    func testPlainTextIsIdentity() {
        let result = mask("# Заголовок\n\nОбычный текст {a} и %% без пары\n")
        XCTAssertTrue(result.isIdentity)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(mask("a %%b%% {++c++}", vault: false, critic: false).isIdentity)
    }

    // MARK: - Правила замены

    func testFrontMatterBecomesSpacesAndKeepsLineBreaks() {
        let text = "---\ntitle: Привет 😀\r\n---\nbody"
        let result = mask(text)
        XCTAssertEqual(result.text, String(repeating: " ", count: 3) + "\n" + String(repeating: " ", count: 16) + "\r\n   \nbody")
        XCTAssertEqual(result.segments.first?.kind, .frontMatter)
        XCTAssertEqual(result.segments.first?.markerRanges.count, 2)
        XCTAssertTrue(mask(text, vault: false, critic: false).segments.contains { $0.kind == .frontMatter })
    }

    func testCriticDelimitersAndCommentBodyAreReplacedContentIsNot() throws {
        let text = "{++вставка++} {--x--} {~~а~>б~~} {==в==} {>>com\nment<<}"
        let result = mask(text)
        let p = String(UnicodeScalar(result.placeholder)!)
        let units = Array(result.text.utf16)
        XCTAssertEqual(result.text, "\(p)\(p)\(p)вставка\(p)\(p)\(p) \(p)\(p)\(p)x\(p)\(p)\(p) \(p)\(p)\(p)а\(p)\(p)б\(p)\(p)\(p) \(p)\(p)\(p)в\(p)\(p)\(p) " + String(repeating: p, count: 6) + "\n" + String(repeating: p, count: 7))
        XCTAssertEqual(units.count, text.utf16.count)
        XCTAssertEqual(result.segments.map(\.kind), [.critic(.insertion), .critic(.deletion), .critic(.substitution), .critic(.highlight), .critic(.comment)])
        let substitution = try XCTUnwrap(result.segments.first { $0.kind == .critic(.substitution) })
        XCTAssertEqual(substitution.markerRanges.count, 3)
        XCTAssertEqual((text as NSString).substring(with: try XCTUnwrap(substitution.separatorRange)), "~>")
    }

    func testCriticCommentWithBlankLineIsNotMasked() {
        XCTAssertTrue(mask("{>>a\n\nb<<}").isIdentity)
        XCTAssertFalse(mask("{>>a\nb<<}").isIdentity)
        XCTAssertEqual(mask("{>>a\nb<<}").text.utf16.filter { $0 == 10 }.count, 1)
    }

    func testCommentLineBetweenBlocksBecomesBlankLineAndInsideParagraphDoesNot() {
        let between = mask("текст\n\n%%комментарий%%\n\nещё")
        XCTAssertEqual(between.text, "текст\n\n" + String(repeating: " ", count: 15) + "\n\nещё")
        XCTAssertEqual(between.segments.first?.occupiesWholeLines, true)
        XCTAssertEqual(between.segments.first?.keepsParagraph, false)
        let inside = mask("первая\n%%комментарий%%\nвторая")
        let p = String(UnicodeScalar(inside.placeholder)!)
        XCTAssertEqual(inside.text, "первая\n" + String(repeating: p, count: 15) + "\nвторая")
        XCTAssertEqual(inside.segments.first?.keepsParagraph, true)
        let mid = mask("a %%b%% c")
        XCTAssertEqual(mid.text, "a " + String(repeating: String(UnicodeScalar(mid.placeholder)!), count: 5) + " c")
        XCTAssertEqual(mid.segments.first?.occupiesWholeLines, false)
    }

    func testMultilineCommentKeepsParagraphLinesFilledAndCRLF() {
        let text = "a\r\n%%x\r\ny%%\r\nb"
        let result = mask(text)
        let p = String(UnicodeScalar(result.placeholder)!)
        XCTAssertEqual(result.text, "a\r\n\(p)\(p)\(p)\r\n\(p)\(p)\(p)\r\nb")
        let separated = mask("a\n\n%%x\n\ny%%\n\nb")
        XCTAssertEqual(separated.text, "a\n\n   \n\n   \n\nb")
    }

    func testCommentInsideCriticCommentIsNotComment() {
        let result = mask("{>>a %%b<<} c %%")
        XCTAssertEqual(result.segments.map(\.kind), [.critic(.comment)])
        XCTAssertTrue(mask("{++ %%c%% ++}").segments.map(\.kind) == [.critic(.insertion), .comment])
    }

    func testCriticOverlappingCommentIsDroppedPartialAndFull() {
        XCTAssertEqual(mask("%%a {++b++} c%%").segments.map(\.kind), [.comment])
        XCTAssertEqual(mask("{++a %%b++} c%%").segments.map(\.kind), [.comment])
    }

    func testCriticAndCommentsInsideCodeAndFormulaAreNotMasked() {
        for text in ["```\n{++a++} %%b%%\n```\n", "`{++a++}` `%%b%%`", "<div>\n{++a++}\n</div>\n", "| a |\n| - |\n| {++x++} |\n", "$$\n{++a++}\n$$\n", "    {++a++}\n"] {
            XCTAssertTrue(mask(text).isIdentity, text)
        }
    }

    func testPlaceholderAvoidsUserPrivateUseCharacters() {
        let text = "{++a++} \u{E000}\u{E001}"
        let result = mask(text)
        XCTAssertEqual(result.placeholder, 0xE002)
        XCTAssertTrue(result.text.hasSuffix("\u{E000}\u{E001}"))
        XCTAssertEqual(MarkdownSourceMask.mask("{++a++}", options: options()).placeholder, 0xE000)
    }

    // Если заняты все заменители, исходные символы нельзя выдавать за служебные и удалять.
    func testExhaustedPlaceholdersPreserveOriginalTextAndHeading() {
        let privateUse = String(decoding: Array(UInt16(0xE000)...UInt16(0xF8FF)), as: UTF16.self)
        let available = mask("{++x++}\n\n" + privateUse)
        XCTAssertFalse(available.isIdentity)
        XCTAssertEqual(available.placeholder, 0xFFFF)

        let text = "# Заголовок\u{FFFF}\n\n" + privateUse + "\n\n{++x++}"
        let result = mask(text)
        XCTAssertTrue(result.isIdentity)
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.segments.isEmpty)
        let model = MarkdownDocumentParser.parseOrEmpty(text, includes: [.criticMarkup])
        guard case let .heading(heading) = model.blocks.first?.kind else { return XCTFail("ожидается заголовок") }
        XCTAssertEqual(heading.title, "Заголовок\u{FFFF}")
    }

    func testMaskedTextHasNoSmartPunctuationOrStrikethroughTriggers() {
        let masked = mask("{--a--} {~~б~>в~~} {==г==}").text
        XCTAssertFalse(masked.contains("--"))
        XCTAssertFalse(masked.contains("~"))
        XCTAssertFalse(masked.contains("=="))
    }

    // MARK: - Сверка с нынешними распознавателями

    /// Критик и комментарии на оценке запретов совпадают с `CriticMarkupService` и `MarkdownObsidianComment` на точных диапазонах дерева.
    func testSegmentsMatchRecognizersOnCorpus() throws {
        let documents = try BaselineCorpus.documents() + BaselineCorpus.crlfDocuments()
        for item in documents {
            let text = item.text
            let result = mask(text)
            let critic = result.segments.filter { isCritic($0.kind) }
            let oldCritic = CriticMarkupRender.items(in: text, syntax: syntax)
            let oldComments = MarkdownObsidianComment.commentRanges(in: text, syntax: syntax)
            let comments = result.segments.filter { $0.kind == .comment }.map(\.range)
            // Критик внутри комментария отбрасывается новой маской, поэтому сравниваем с тем же отбором.
            let keptOld = oldCritic.filter { item in !oldComments.contains { NSIntersectionRange($0, item.range).length > 0 } }
            XCTAssertEqual(critic.map(\.range), keptOld.map(\.range), "\(item.id): критик")
            XCTAssertEqual(critic.map(\.contentRange), keptOld.map(\.content), "\(item.id): содержимое критика")
            XCTAssertEqual(comments, oldComments, "\(item.id): комментарии")
            let front = MarkdownFrontMatter.frontMatter(text)
            XCTAssertEqual(result.segments.first { $0.kind == .frontMatter }?.range, front?.range, "\(item.id): front matter")
            // Точные запреты дают тот же результат.
            let exact = mask(text, excluded: treeExcluded(text))
            XCTAssertEqual(exact.segments, result.segments, "\(item.id): оценка запретов расходится с деревом")
        }
    }

    /// Положение каждого токена (`%%`, начало правки) относительно запретных зон: оценка против дерева.
    func testEstimatedZonesAgreeWithTreeAroundTokens() throws {
        let documents = try BaselineCorpus.documents() + BaselineCorpus.crlfDocuments()
        let extra = [
            "- пункт\n\n  ```\n  {++a++}\n  ```\n\n  {++b++}\n",
            "> ```\n> %%a%%\n> ```\n%%b%%\n",
            "1. один\n\n       {++код++}\n\n{++вне++}\n",
            "| a | b |\n|---|---|\n| `{++x++}` | y |\n\n{++z++}\n",
            "<!-- {++a++} -->\n{++b++}\n<div>\n{++c++}\n\n{++d++}\n",
            "~~~~\n```\n{++a++}\n~~~~\n{++b++}\n",
            "``a ` {++b++} ``\n{++c++}\n",
            "$$\n{++a++}\n$$\n{++b++}\n",
            "текст\n    {++не код++}\n\n    {++код++}\n",
            // Цитата кончилась, не закрыв ограждение: следующая строка разбирается заново.
            "> ```\n> a\n```\n{++x++}\n",
            "> ```\n> a\n```\n{++x++}\n\n{++y++}\n",
            "> ```\n> a\n~~~\n{++x++}\n~~~\n{++y++}\n",
            "> ```\n> a\n<div>\n{++x++}\n\n{++y++}\n",
            "> ```\n> a\n| a |\n|---|\n| {++x++} |\n\n{++y++}\n",
            "- ```\n  a\n```\n{++x++}\n",
            // Ограждение в пункте списка внутри цитаты.
            "> - ```\n>   %% не комментарий %%\n>   ```\n",
            "> - ```\n>   {++x++}\n>   ```\n{++y++}\n",
            "- > ```\n  > {++a++}\n  > b\n",
            "> - ```\n>   {++a++}\n>\n>   {++b++}\n",
            "> - ```\r\n>   {++x++}\r\n>   ```\r\n{++y++}\r\n",
        ]
        let all = documents.map { ($0.id, $0.text) } + extra.map { ($0.replacingOccurrences(of: "\n", with: "↵").prefix(20) + "…", $0) }
        for (id, text) in all {
            let source = text as NSString
            guard text.contains("{") || text.contains("%%") else { continue }
            let estimated = MarkdownSourceMask.estimatedExcluded(text)
            let exact = treeExcluded(text)
            func inside(_ zones: [NSRange], _ location: Int) -> Bool { zones.contains { NSLocationInRange(location, $0) } }
            var location = 0
            while location < source.length {
                let found = source.range(of: "{++", range: NSRange(location: location, length: source.length - location))
                let percent = source.range(of: "%%", range: NSRange(location: location, length: source.length - location))
                let next = [found, percent].filter { $0.location != NSNotFound }.min { $0.location < $1.location }
                guard let token = next else { break }
                XCTAssertEqual(inside(estimated, token.location), inside(exact, token.location), "\(id): токен в позиции \(token.location)")
                location = token.location + 1
            }
        }
    }

    /// Пункт списка в цитате кончился строкой с меньшим отступом: ограждение закрыто вместе с пунктом, `{++y++}` — обычный абзац.
    /// Так по CommonMark (проверено `pandoc -f commonmark`: CodeBlock внутри пункта, затем Para).
    func testFenceInQuotedListItemEndsWithItem() {
        let text = "> - ```\n>   {++x++}\n> {++y++}\n"
        let zones = MarkdownSourceMask.estimatedExcluded(text)
        let source = text as NSString
        func inside(_ token: String) -> Bool { zones.contains { NSLocationInRange(source.range(of: token).location, $0) } }
        XCTAssertTrue(inside("{++x++}"))
        XCTAssertFalse(inside("{++y++}"))
    }

    /// Ограждение кончается, когда контейнер кончился (сверено `pandoc -f commonmark -t native`):
    /// строка `> b` левее содержимого пункта с цитатой, а пустая строка без `>` закрывает цитату.
    func testFenceEndsWithQuoteOrItemContainer() {
        let cases: [(text: String, inside: String, outside: String)] = [
            ("- > ```\n  > {++a++}\n> {++b++}\n", "{++a++}", "{++b++}"),
            ("- > ```\r\n  > {++a++}\r\n> {++b++}\r\n", "{++a++}", "{++b++}"),
            // Цитата в пункте кончилась строкой без отступа: `{++c++}` — абзац после списка (pandoc: BulletList, затем Para).
            ("- > ```\r\n  > {++a++}\r\n  > b\r\n{++c++}\r\n", "{++a++}", "{++c++}"),
            ("> ```\n> {++a++}\n\n> {++b++}\n", "{++a++}", "{++b++}"),
            ("> ```\r\n> {++a++}\r\n\r\n> {++b++}\r\n", "{++a++}", "{++b++}"),
            ("> - ```\n>   {++a++}\n\n>   {++b++}\n", "{++a++}", "{++b++}"),
            ("> - ```\r\n>   {++a++}\r\n\r\n>   {++b++}\r\n", "{++a++}", "{++b++}"),
            // Строка `>` ограждение в цитате не закрывает.
            ("> ```\n> {++a++}\n>\n> {++b++}\n", "{++a++}", ""),
            ("> ```\n> {++a++}\n>\n> {++b++}\n", "{++b++}", ""),
        ]
        for item in cases {
            let zones = MarkdownSourceMask.estimatedExcluded(item.text)
            let source = item.text as NSString
            func inside(_ token: String) -> Bool { zones.contains { NSLocationInRange(source.range(of: token).location, $0) } }
            XCTAssertTrue(inside(item.inside), item.text)
            if !item.outside.isEmpty { XCTAssertFalse(inside(item.outside), item.text) }
        }
    }

    /// Отмена во время оценки запретов: маска не выдаёт частичный результат.
    func testCancelledEstimationReturnsIdentity() {
        var text = ""
        for index in 0..<2000 { text += "строка \(index) {++a++}\n" }
        var calls = 0
        let result = MarkdownSourceMask.mask(text, options: options(), isCancelled: { calls += 1; return calls > 1 })
        XCTAssertTrue(result.isIdentity)
        XCTAssertEqual(result.text, text)
        XCTAssertFalse(mask(text).isIdentity)
    }

    /// Кириллица, CJK и эмодзи внутри `%%`: целые строки между блоками и внутри абзаца.
    func testCommentWithCyrillicCJKAndEmojiOnWholeLinesAndInsideParagraph() {
        let body = "скрыто 你好 😀"
        let blocks = mask("до\n\n%%\(body)%%\n\nпосле")
        XCTAssertEqual(blocks.text, "до\n\n" + String(repeating: " ", count: body.utf16.count + 4) + "\n\nпосле")
        XCTAssertEqual(blocks.segments.first?.occupiesWholeLines, true)
        XCTAssertEqual(blocks.segments.first?.keepsParagraph, false)
        let paragraph = mask("первая 😀\n%%\(body)\nещё 你好%%\nвторая")
        let p = String(UnicodeScalar(paragraph.placeholder)!)
        XCTAssertEqual(paragraph.segments.first?.keepsParagraph, true)
        XCTAssertEqual(paragraph.text, "первая 😀\n" + String(repeating: p, count: body.utf16.count + 2) + "\n" + String(repeating: p, count: "ещё 你好".utf16.count + 2) + "\nвторая")
        let middle = mask("слово 😀 %%\(body)%% 你好")
        XCTAssertEqual(middle.segments.first?.range, NSRange(location: 9, length: body.utf16.count + 4))
        XCTAssertEqual(middle.segments.first?.occupiesWholeLines, false)
        assertInvariants("слово 😀 %%\(body)%% 你好", middle, "комментарий в середине строки")
    }

    // MARK: - Подготовка для cmark

    func testMaskKeepsLineCountOfSource() {
        // Число строк маски равно числу `\n` исходника (номера строк исходника и маски совпадают).
        let samples = [("a {++b++} c\n\n{>>x\ny<<}\n- {--z--}", 4), ("{~~а~>б~~}\r\n{==в==}\r\n", 2)]
        for (sample, expected) in samples {
            let lines = mask(sample, critic: true).text.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            XCTAssertEqual(lines, expected, sample)
        }
    }
}
