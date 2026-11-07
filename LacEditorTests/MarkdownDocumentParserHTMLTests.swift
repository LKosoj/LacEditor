import Foundation
import XCTest
@testable import LacEditor

/// Подтверждение HTML в едином разборе (U2.3c): блоки и строчные теги, позиции в UTF-16 исходника.
final class MarkdownDocumentParserHTMLTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> MarkdownDocumentModel {
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: true)
        guard let model = MarkdownDocumentParser.parse(text, options: options) else {
            XCTFail("разбор вернул nil", file: file, line: line)
            return MarkdownDocumentParser.parse("", options: options)!
        }
        return model
    }

    private func range(of part: String, in text: String, occurrence: Int = 0) -> NSRange {
        var search = NSRange(location: 0, length: (text as NSString).length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = (text as NSString).range(of: part, options: [], range: search)
            if found.location == NSNotFound { break }
            search = NSRange(location: NSMaxRange(found), length: (text as NSString).length - NSMaxRange(found))
        }
        XCTAssertNotEqual(found.location, NSNotFound, "в тексте нет «\(part)»")
        return found
    }

    private func htmlBlocks(_ blocks: [MarkdownBlockNode]) -> [(range: NSRange, html: MarkdownBlockNode.HTMLBlock)] {
        blocks.flatMap { block -> [(NSRange, MarkdownBlockNode.HTMLBlock)] in
            var result: [(NSRange, MarkdownBlockNode.HTMLBlock)] = []
            if case .html(let html) = block.kind { result.append((block.range, html)) }
            return result + htmlBlocks(block.children)
        }
    }

    private func flatten(_ nodes: [MarkdownInlineNode]) -> [MarkdownInlineNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    private func allInlines(_ blocks: [MarkdownBlockNode]) -> [MarkdownInlineNode] {
        blocks.flatMap { flatten($0.inlines) + allInlines($0.children) }
    }

    private func firstBlock(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (range: NSRange, html: MarkdownBlockNode.HTMLBlock)? {
        let found = htmlBlocks(parse(text, file: file, line: line).blocks).first
        XCTAssertNotNil(found, "html-блока нет", file: file, line: line)
        return found
    }

    // MARK: - Блоки

    func testPlainDetailsBlockIsConfirmedWithUTF16Range() {
        let text = "Начало 😀\n\n<details>\n<summary>Сводка 日本語</summary>\nТело\n</details>\n\nКонец"
        guard let block = firstBlock(text) else { return }
        guard case .details(let details) = block.html.kind else { return XCTFail("ожидался details, получено \(block.html.kind)") }
        XCTAssertEqual(details.summary, "Сводка 日本語")
        XCTAssertEqual(block.range.location, range(of: "<details>", in: text).location)
        XCTAssertEqual(details.range.location, block.range.location)
    }

    // Одна строка `<audio ...></audio>` — абзац со строчными тегами; html_block даёт тег на отдельной строке.
    func testAudioAndVideoBlocksWithFallbackBecomeMedia() {
        let text = "<audio controls>\n<source src=\"a.mp3\">\n</audio>\n\n<video controls width=\"320\">\n<source src=\"v.mp4\">\n</video>\n"
        let blocks = htmlBlocks(parse(text).blocks)
        XCTAssertEqual(blocks.count, 2)
        guard blocks.count == 2, case .media(let audio) = blocks[0].html.kind, case .media(let video) = blocks[1].html.kind else {
            return XCTFail("ожидались два media-блока: \(blocks.map(\.html.kind))")
        }
        XCTAssertEqual(audio.kind, .audio)
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.width, "320")
        XCTAssertEqual(blocks[1].range.location, range(of: "<video", in: text).location)
    }

    func testIframeBlockBecomesIframe() {
        let text = "<iframe src=\"https://example.com/embed\" width=\"320\" height=\"200\" title=\"Видео\"></iframe>\n"
        guard let block = firstBlock(text), case .iframe(let frame, _, _) = block.html.kind else { return XCTFail("ожидался iframe") }
        XCTAssertEqual(frame.width, "320")
        XCTAssertEqual(frame.title, "Видео")
    }

    func testSVGBlockBecomesSVGData() {
        let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">\n<rect width=\"10\" height=\"10\"/>\n</svg>\n"
        guard let block = firstBlock(text), case .svg(let data) = block.html.kind else { return XCTFail("ожидался svg") }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<rect"))
    }

    func testPageBreakBlock() {
        let text = "Первая страница\n\n<div style=\"page-break-after: always;\"></div>\n\nВторая"
        guard let block = firstBlock(text), case .pageBreak(let style) = block.html.kind else { return XCTFail("ожидался pageBreak") }
        XCTAssertTrue(style.contains("page-break-after"), style)
    }

    func testPlainHTMLBlockIsConfirmedWithDisplayHTML() {
        let text = "<div>\nПривет 😀\n</div>\n"
        guard let block = firstBlock(text) else { return }
        guard case .confirmed(let display) = block.html.kind else { return XCTFail("ожидался confirmed, получено \(block.html.kind)") }
        XCTAssertTrue(display.contains("Привет"), display)
    }

    func testHTMLBlockInsideQuoteIsConfirmedAfterPrefixStrip() {
        let text = "> <audio controls>\n> <source src=\"a.mp3\">\n> </audio>\n"
        guard let block = firstBlock(text) else { return }
        guard case .media = block.html.kind else { return XCTFail("в цитате ожидался media, получено \(block.html.kind)") }
        XCTAssertEqual(block.range.location, range(of: "<audio", in: text).location)
    }

    func testHTMLBlockInsideRawScriptIsNotConfirmed() {
        let text = "<script>\n<audio src=\"a.mp3\" controls></audio>\n</script>\n"
        let kinds = htmlBlocks(parse(text).blocks).map(\.html.kind)
        XCTAssertEqual(kinds, [.raw])
    }

    private func tableInlines(_ blocks: [MarkdownBlockNode]) -> [MarkdownInlineNode] {
        blocks.flatMap { block -> [MarkdownInlineNode] in
            var result: [MarkdownInlineNode] = []
            if case .table(let table) = block.kind {
                result = table.rows.flatMap { $0.cells.flatMap { flatten($0.inlines) } }
            }
            return result + tableInlines(block.children)
        }
    }

    private func isKeyboard(_ node: MarkdownInlineNode) -> Bool { if case .keyboard = node.kind { return true } else { return false } }

    // Незакрытый script в абзаце верхнего уровня не мешает следующему тегу на строке закрытия.
    func testScriptInTopLevelParagraphDoesNotResetContext() {
        let text = "Текст <script>\nvar a\n</script> и <kbd>x</kbd>\n"
        XCTAssertTrue(allInlines(parse(text).blocks).contains(where: isKeyboard), "\(allInlines(parse(text).blocks).map(\.kind))")
    }

    // В цитате и списке префиксы контейнера в тексте script доказаны (`scriptGapPrefixes`): <kbd> подтверждается.
    func testScriptInQuoteAndListKeepsConfirmedContext() {
        for text in ["> Текст <script>\n> var a\n> </script> и <kbd>x</kbd>\n", "- Текст <script>\n  var a\n  </script> и <kbd>x</kbd>\n"] {
            XCTAssertTrue(allInlines(parse(text).blocks).contains(where: isKeyboard), text)
        }
    }

    func testCancelledParseWithAngleBracketReturnsNil() {
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: [], isVaultNote: false, detectsFrontMatter: true)
        XCTAssertNil(MarkdownDocumentParser.parse("Текст <kbd>x</kbd>\n", options: options, isCancelled: { true }))
    }

    // В ячейке таблицы подтверждаются <img> и <kbd>.
    func testTableCellConfirmsImageAndKeyboard() {
        let text = "| A |\n|---|\n| <img src=\"a.png\" alt=\"x\"> <kbd>k</kbd> |\n"
        let nodes = tableInlines(parse(text).blocks)
        XCTAssertTrue(nodes.contains { if case .image = $0.kind { return true } else { return false } }, "\(nodes.map(\.kind))")
        XCTAssertTrue(nodes.contains(where: isKeyboard), "в ячейке `<kbd>` оформляется")
    }

    // В ячейке оформляются `<kbd>` и `<span style>`; `<b>` остаётся сырым HTML.
    func testTableCellPairsKeyboardAndStyleWithMarkers() {
        let text = "| Я 😀 |\r\n|---|\r\n| Слово <kbd>Ctrl</kbd> и <span style=\"color:red\">красный</span> <b>жирный</b> |\r\n"
        let nodes = tableInlines(parse(text).blocks)
        guard let keyboard = nodes.first(where: isKeyboard) else { return XCTFail("нет kbd: \(nodes.map(\.kind))") }
        XCTAssertEqual(keyboard.markerRanges, [range(of: "<kbd>", in: text), range(of: "</kbd>", in: text)])
        guard let style = nodes.first(where: { if case .inlineStyle = $0.kind { return true } else { return false } }) else { return XCTFail("нет inlineStyle") }
        XCTAssertEqual(style.markerRanges, [range(of: "<span style=\"color:red\">", in: text), range(of: "</span>", in: text)])
        XCTAssertFalse(nodes.contains { if case .strong = $0.kind { return true } else { return false } })
    }

    // Пара `<span style>` внутри `**…**` в ячейке: родитель тега — strong, позиции берутся у ячейки-предка (экранированная `|`, CJK, эмодзи).
    func testTableCellPairsStyleInsideStrongUsingCellPositions() {
        let text = "| Left | Right |\r\n| --- | --- |\r\n| **<span style='color:red'>中文\\|😀</span>** | x |\r\n"
        let nodes = tableInlines(parse(text).blocks)
        guard let style = nodes.first(where: { if case .inlineStyle = $0.kind { return true } else { return false } }) else {
            return XCTFail("нет inlineStyle: \(nodes.map(\.kind))")
        }
        XCTAssertEqual(style.markerRanges, [range(of: "<span style='color:red'>", in: text), range(of: "</span>", in: text)])
        XCTAssertEqual(style.range, NSRange(location: range(of: "<span", in: text).location, length: NSMaxRange(range(of: "</span>", in: text)) - range(of: "<span", in: text).location))
    }

    // Обычные ссылки в ячейках без ведущей `|`, после кириллицы, эмодзи и других ссылок, с CRLF: диапазоны по исходнику.
    func testRegularLinksInTableCellsKeepSourceRanges() {
        for eol in ["\n", "\r\n"] {
            let text = "[a](u) | Я 😀 [b](v) [c](w) 日本\(eol)---|---\(eol)[d](x) [e](y) | [f](z)\(eol)"
            let links = tableInlines(parse(text).blocks).filter { if case .link = $0.kind { return true } else { return false } }
            XCTAssertEqual(links.map(\.range), ["[a](u)", "[b](v)", "[c](w)", "[d](x)", "[e](y)", "[f](z)"].map { range(of: $0, in: text) }, "eol \(eol.count)")
        }
    }

    private func tableCells(_ text: String) -> [MarkdownBlockNode.Table.Cell] {
        parse(text).blocks.compactMap { if case .table(let table) = $0.kind { return table } else { return nil } }.first?.rows.flatMap(\.cells) ?? []
    }

    // Ячейки, добранные cmark до числа столбцов, — заполнители; настоящие (и со строкой с табом) — нет.
    func testPaddingCellsAreMarkedOnlyForAddedCells() {
        let short = tableCells("| A | B | C |\n|:-:|--:|---|\n| Я 😀 |\n")
        XCTAssertEqual(short.map(\.isPadding), [false, false, false, false, true, true])
        let tab = tableCells("| A | B |\n|:-:|--:|\n| a\t| b |\n")
        XCTAssertEqual(tab.count, 4)
        XCTAssertFalse(tab.contains(where: \.isPadding), "строка с табом: ячейки настоящие")
    }

    // Выравнивание столбца у настоящей ячейки в строке с табом сохраняется, у добранной — нет.
    func testAlignmentOfRealCellsInTabRowAndPadding() {
        let tab = MarkdownHTMLRenderer.renderPage("| A | B |\n|:-:|--:|\n| a\t| b |\n", darkMode: false).body
        XCTAssertTrue(tab.contains("<td align=\"center\">a</td>") && tab.contains("<td align=\"right\">b</td>"), tab)
        let short = MarkdownHTMLRenderer.renderPage("| A | B |\n|:-:|--:|\n| x |\n", darkMode: false).body
        XCTAssertTrue(short.contains("<td align=\"center\">x</td>\n<td></td>"), short)
    }

    // Голая ссылка в ячейке: диапазон узла — по исходному тексту (UTF-16), даже после кириллицы и эмодзи в ячейке.
    func testBareURLInTableCellHasSourceRange() {
        let text = "| A | B |\r\n|---|---|\r\n| Привет 😀 https://y.com/путь конец | 日本 www.z.com |\r\n"
        let links = tableInlines(parse(text).blocks).filter { if case .link = $0.kind { return true } else { return false } }
        XCTAssertEqual(links.map(\.range), [range(of: "https://y.com/путь", in: text), range(of: "www.z.com", in: text)])
    }

    // Ленивая строка абзаца: ссылка-определение и тег в одном абзаце.
    func testLazyParagraphWithReferenceLinkAndTag() {
        let text = "> Начало <kbd>x</kbd> [ссылка][r]\nлениво 😀 日本語\n\n[r]: https://example.com\n"
        let nodes = allInlines(parse(text).blocks)
        guard let node = nodes.first(where: isKeyboard) else { return XCTFail("нет keyboard: \(nodes.map(\.kind))") }
        XCTAssertEqual(node.markerRanges, [range(of: "<kbd>", in: text), range(of: "</kbd>", in: text)])
        XCTAssertTrue(nodes.contains { if case .link(let link) = $0.kind { return link.form == .reference } else { return false } })
    }

    // Модель решает по ленивой строке цитаты так же, как рендер: вид узла и подтверждение следующих тегов совпадают.
    func testLazyLineTagsMatchRendererDecision() {
        let cases: [(text: String, markers: [(model: (MarkdownInlineNode.Kind) -> Bool, render: String)])] = [
            ("> строка\n<img src=\"a.png\"> и <mark>x</mark>\n", [
                ({ if case .image = $0 { return true } else { return false } }, "<img"),
                ({ if case .highlight = $0 { return true } else { return false } }, "<mark>")]),
            ("> строка\n<span style=\"color:red\">x</span>\n", [
                ({ if case .inlineStyle = $0 { return true } else { return false } }, "<span style")]),
            ("> Начало\nлениво <u>y</u>\n", [
                ({ if case .underline = $0 { return true } else { return false } }, "<u>")]),
            // Рендер отказывает: обе стороны не подтверждают.
            ("> строка\n<img src=\"a.png\" onerror=\"x()\">\n", [({ if case .image = $0 { return true } else { return false } }, "<img")]),
            // `<script>` в начале строки — html-блок, прерывает абзац: внутри незакрытого script ничего не подтверждается.
            ("> строка\n<script>\n<img src=\"a.png\">\n", [({ if case .image = $0 { return true } else { return false } }, "<img")]),
            // Со `<span` в тексте ленивые диапазоны идут первыми.
            ("> строка\n<img src=\"a.png\"> и <mark>x</mark> <span class=\"x\">z</span>\n", [({ if case .image = $0 { return true } else { return false } }, "<img"), ({ if case .highlight = $0 { return true } else { return false } }, "<mark>")]),
            ("> Начало\nлениво <u>y</u> <span class=\"x\">z</span>\n", [
                ({ if case .underline = $0 { return true } else { return false } }, "<u>")]),
            // `<span` только в front matter.
            ("---\ntitle: \"<span>\"\n---\n\n> a\n<img src=\"a.png\"> и <mark>x</mark>\n", [({ if case .image = $0 { return true } else { return false } }, "<img"), ({ if case .highlight = $0 { return true } else { return false } }, "<mark>")]),
        ]
        for item in cases {
            let nodes = allInlines(parse(item.text).blocks)
            let body = MarkdownHTMLRenderer.renderPage(item.text, darkMode: false, resolveLocalImages: false).body
            for marker in item.markers {
                XCTAssertEqual(nodes.contains { marker.model($0.kind) }, body.contains(marker.render),
                               "\(item.text.debugDescription) \(marker.render): модель \(nodes.map(\.kind)), рендер \(body)")
            }
        }
    }

    func testImageBlockAndRichDetails() {
        let image = "<img src=\"a.png\" alt=\"x\">\n"
        let imageKinds = htmlBlocks(parse(image).blocks).map(\.html.kind)
        XCTAssertTrue(imageKinds.allSatisfy { if case .raw = $0 { return false } else { return true } }, "\(imageKinds)")
        let details = "<details>\n<summary>Сводка</summary>\n\n**жирный** текст\n\n</details>\n"
        let kinds = htmlBlocks(parse(details).blocks).map(\.html.kind)
        XCTAssertFalse(kinds.isEmpty)
    }

    // Перенос строки сразу после открывающего тега пары даёт надёжный softBreak внутри содержимого.
    func testPairContentLineBreakIsReliableSoftBreak() {
        let text = "Слово <mark>\nтекст</mark>\n"
        let nodes = allInlines(parse(text).blocks)
        guard let mark = nodes.first(where: { if case .highlight = $0.kind { return true } else { return false } }) else {
            return XCTFail("нет highlight: \(nodes.map(\.kind))")
        }
        guard let softBreak = mark.children.first(where: { if case .softBreak = $0.kind { return true } else { return false } }) else {
            return XCTFail("нет softBreak: \(mark.children.map(\.kind))")
        }
        XCTAssertFalse(softBreak.isUnreliable)
        XCTAssertEqual(softBreak.range, range(of: "\n", in: text))
    }

    // Неподтверждённый <br> (с атрибутом, в script, в template) попадает в blockedHTML; простой <br> — нет.
    func testUnconfirmedBreakTagsAreBlockedWithRange() {
        for marker in ["<br class='x'>", "<script><br></script>", "<template><br></template>"] {
            let text = "Строка 😀 \(marker) вторая\n"
            let model = parse(text)
            let br = range(of: "<br", in: text)
            XCTAssertTrue(model.blockedHTML.contains { NSLocationInRange(br.location, $0) }, "\(marker): \(model.blockedHTML)")
        }
        XCTAssertTrue(parse("Строка<br>вторая\n").blockedHTML.isEmpty)
    }

    func testTextWithoutAngleBracketsHasNoHTML() {
        let model = parse("Обычный текст 😀 日本語 без тегов\n")
        XCTAssertTrue(htmlBlocks(model.blocks).isEmpty)
        XCTAssertTrue(model.blockedHTML.isEmpty)
    }

    // MARK: - Строчные теги

    func testPairedInlineTagsBecomeStyledNodesWithMarkers() {
        let cases: [(String, String, (MarkdownInlineNode.Kind) -> Bool)] = [
            ("<kbd>", "</kbd>", { if case .keyboard = $0 { return true } else { return false } }),
            ("<u>", "</u>", { if case .underline = $0 { return true } else { return false } }),
            ("<mark>", "</mark>", { if case .highlight = $0 { return true } else { return false } }),
            ("<sub>", "</sub>", { if case .subscriptText = $0 { return true } else { return false } }),
            ("<sup>", "</sup>", { if case .superscriptText = $0 { return true } else { return false } }),
        ]
        for (open, close, matches) in cases {
            let text = "Слово 😀 \(open)日本語\(close) конец"
            let nodes = allInlines(parse(text).blocks)
            guard let node = nodes.first(where: { matches($0.kind) }) else { XCTFail("нет узла для \(open): \(nodes.map(\.kind))"); continue }
            XCTAssertEqual(node.markerRanges, [range(of: open, in: text), range(of: close, in: text)], open)
            XCTAssertEqual(node.range, NSUnionRange(range(of: open, in: text), range(of: close, in: text)), open)
            XCTAssertEqual(node.children.count, 1, open)
            if case .text(let value) = node.children.first?.kind { XCTAssertEqual(value, "日本語", open) } else { XCTFail("нет текста внутри \(open)") }
        }
    }

    // Теги `<b>`, `<em>`, `<del>` и другие — узлы strong/emphasis/strikethrough с маркерами-тегами.
    func testPairedFormattingTagsBecomeNodesWithTagMarkers() {
        let cases: [(String, String, String, (MarkdownInlineNode.Kind) -> Bool)] = [
            ("<b>", "</b>", "strong", { if case .strong = $0 { return true } else { return false } }),
            ("<strong>", "</strong>", "strong", { if case .strong = $0 { return true } else { return false } }),
            ("<em>", "</em>", "emphasis", { if case .emphasis = $0 { return true } else { return false } }),
            ("<i>", "</i>", "emphasis", { if case .emphasis = $0 { return true } else { return false } }),
            ("<s>", "</s>", "strikethrough", { if case .strikethrough = $0 { return true } else { return false } }),
            ("<del>", "</del>", "strikethrough", { if case .strikethrough = $0 { return true } else { return false } }),
        ]
        for (open, close, name, matches) in cases {
            let text = "Строка\r\nСлово 😀 \(open)日本語\(close) конец\r\n"
            let nodes = allInlines(parse(text).blocks)
            guard let node = nodes.first(where: { matches($0.kind) }) else { XCTFail("нет узла \(name) для \(open): \(nodes.map(\.kind))"); continue }
            XCTAssertEqual(node.markerRanges, [range(of: open, in: text), range(of: close, in: text)], open)
            XCTAssertEqual(node.range, NSUnionRange(range(of: open, in: text), range(of: close, in: text)), open)
            if case .text(let value) = node.children.first?.kind { XCTAssertEqual(value, "日本語", open) } else { XCTFail("нет текста внутри \(open)") }
            XCTAssertFalse(nodes.contains { if case .rawHTML = $0.kind { return true } else { return false } }, "теги \(open) остались сырым HTML")
        }
    }

    // У каждого `<img>` в HTML-блоке есть диапазон своего тега (UTF-16, CRLF, кириллица и эмодзи до тега).
    func testHTMLBlockImagesCarryTagRanges() {
        let text = "Привет 😀\r\n\r\n<img src=\"a.png\" alt=\"Рис\">\r\n<img src=\"b.png\" alt=\"日本\">\r\n"
        let kinds = htmlBlocks(parse(text).blocks).map(\.html.kind)
        guard case .images(let images)? = kinds.first else { return XCTFail("нет images: \(kinds)") }
        XCTAssertEqual(images.map(\.url), ["a.png", "b.png"])
        XCTAssertEqual(images.map(\.tagRange), [range(of: "<img src=\"a.png\" alt=\"Рис\">", in: text),
                                               range(of: "<img src=\"b.png\" alt=\"日本\">", in: text)])
    }

    // Абзац из одного `<svg>` с вложенным тегом — картинка-узел на весь абзац, а не сырой HTML.
    func testParagraphWithOnlySVGBecomesSVGNode() {
        let text = "Абзац 😀\r\n\r\n<svg width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\"/></svg>\r\n"
        let nodes = allInlines(parse(text).blocks)
        guard let node = nodes.first(where: { if case .svg = $0.kind { return true } else { return false } }) else {
            return XCTFail("нет svg: \(nodes.map(\.kind))")
        }
        XCTAssertEqual(node.range, range(of: "<svg width=\"40\" height=\"20\"><rect width=\"40\" height=\"20\"/></svg>", in: text))
    }

    func testStyledSpanBecomesInlineStyleAndCRLFShiftsPositions() {
        let text = "Строка один\r\nТекст <span style=\"color:red\">красный</span> 😀\r\n"
        let nodes = allInlines(parse(text).blocks)
        guard let node = nodes.first(where: { if case .inlineStyle = $0.kind { return true } else { return false } }) else {
            return XCTFail("нет inlineStyle: \(nodes.map(\.kind))")
        }
        XCTAssertEqual(node.markerRanges.first, range(of: "<span style=\"color:red\">", in: text))
        XCTAssertEqual(node.markerRanges.last, range(of: "</span>", in: text))
        XCTAssertEqual(node.range, NSUnionRange(range(of: "<span style=\"color:red\">", in: text), range(of: "</span>", in: text)))
        XCTAssertEqual(node.range.location, ("Строка один\r\nТекст " as NSString).length)
    }

    func testAnchorBecomesHTMLLink() {
        let text = "Смотри <a href=\"https://example.com/путь\">ссылка</a> ещё\n"
        let nodes = allInlines(parse(text).blocks)
        guard let node = nodes.first(where: { if case .link = $0.kind { return true } else { return false } }),
              case .link(let link) = node.kind else { return XCTFail("нет ссылки: \(nodes.map(\.kind))") }
        XCTAssertEqual(link.form, .html)
        XCTAssertEqual(node.markerRanges.count, 2)
    }

    func testInlineImageTagBecomesHTMLImage() {
        let text = "Картинка <img src=\"a.png\" alt=\"Рис 😀\" width=\"20\"> в строке\n"
        let nodes = allInlines(parse(text).blocks)
        guard let node = nodes.first(where: { if case .image = $0.kind { return true } else { return false } }),
              case .image(let image) = node.kind else { return XCTFail("нет изображения: \(nodes.map(\.kind))") }
        XCTAssertEqual(image.syntax, .html)
        XCTAssertEqual(image.url, "a.png")
        XCTAssertEqual(image.alt, "Рис 😀")
        XCTAssertEqual(node.range, range(of: "<img src=\"a.png\" alt=\"Рис 😀\" width=\"20\">", in: text))
    }

    func testRubyBecomesRubyNode() {
        let text = "Слово <ruby>漢<rt>kan</rt></ruby> дальше\n"
        let nodes = allInlines(parse(text).blocks)
        guard let node = nodes.first(where: { if case .ruby = $0.kind { return true } else { return false } }),
              case .ruby(let ruby) = node.kind else { return XCTFail("нет ruby: \(nodes.map(\.kind))") }
        XCTAssertEqual(ruby.base, "漢")
        XCTAssertEqual(ruby.reading, "kan")
        XCTAssertEqual(node.range, range(of: "<ruby>漢<rt>kan</rt></ruby>", in: text))
    }

    func testInlinePairedAudioBecomesMediaNode() {
        let text = "Звук <audio src=\"a.mp3\" controls></audio> тут\n"
        let nodes = allInlines(parse(text).blocks)
        guard let node = nodes.first(where: { if case .media = $0.kind { return true } else { return false } }),
              case .media(let media) = node.kind else { return XCTFail("нет media: \(nodes.map(\.kind))") }
        XCTAssertEqual(media.kind, .audio)
        XCTAssertEqual(node.range, range(of: "<audio src=\"a.mp3\" controls></audio>", in: text))
    }

    func testInlineSVGBecomesSVGNode() {
        let text = "Значок <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg> тут\n"
        let nodes = allInlines(parse(text).blocks)
        XCTAssertTrue(nodes.contains { if case .svg = $0.kind { return true } else { return false } }, "нет svg: \(nodes.map(\.kind))")
    }

    // MARK: - Неподтверждённые теги

    // span со style, который редактор не оформляет, попадает в blockedHTML; span без style — обычный сырой тег.
    func testSpanWithUnsupportedStyleIsBlocked() {
        let text = "Текст <span style=\"font-family:serif\">слово</span> дальше\n"
        let model = parse(text)
        XCTAssertFalse(allInlines(model.blocks).contains { if case .inlineStyle = $0.kind { return true } else { return false } })
        XCTAssertTrue(model.blockedHTML.contains { NSLocationInRange(range(of: "<span", in: text).location, $0) }, "\(model.blockedHTML)")
    }

    func testSpanWithoutStyleIsPlainRawHTML() {
        let model = parse("Текст <span class=\"x\">слово</span> дальше\n")
        XCTAssertFalse(allInlines(model.blocks).contains { if case .inlineStyle = $0.kind { return true } else { return false } })
        XCTAssertTrue(model.blockedHTML.isEmpty)
    }

    func testRubyWithoutBaseIsBlocked() {
        let text = "Слово <ruby><rt>kan</rt></ruby> дальше\n"
        let model = parse(text)
        XCTAssertFalse(allInlines(model.blocks).contains { if case .ruby = $0.kind { return true } else { return false } })
        XCTAssertFalse(model.blockedHTML.isEmpty)
    }

    func testTagsInsideCodeSpanAreNotHTML() {
        let model = parse("Код `<kbd>Ctrl</kbd>` без оформления\n")
        let nodes = allInlines(model.blocks)
        XCTAssertFalse(nodes.contains { if case .keyboard = $0.kind { return true } else { return false } })
        XCTAssertTrue(model.blockedHTML.isEmpty)
    }

    func testBreakTagStaysRawHTMLInline() {
        let nodes = allInlines(parse("Строка<br>вторая\n").blocks)
        guard let node = nodes.first(where: { if case .rawHTML = $0.kind { return true } else { return false } }) else {
            return XCTFail("нет rawHTML: \(nodes.map(\.kind))")
        }
        XCTAssertEqual(node.range, NSRange(location: 6, length: 4))
    }

    /// Виджет Twitter подтверждается как `.twitter` (диапазон блока в UTF-16, сдвиг после кириллицы, эмодзи и `\r\n`).
    func testTwitterBlockBecomesTwitterWidgetWithUTF16Range() {
        let text = "Начало 😀 漢字\r\n\r\n<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">Hello</p>&mdash; User (@user) <a href=\"https://twitter.com/user/status/1234567890\">January 1, 2020</a></blockquote>\r\n<script async src=\"https://platform.twitter.com/widgets.js\" charset=\"utf-8\"></script>\r\n\r\nКонец"
        guard let block = firstBlock(text), case .twitter(let widget) = block.html.kind else { return XCTFail("ожидался twitter") }
        XCTAssertEqual(widget.id, "1234567890")
        XCTAssertEqual(widget.postURL, "https://twitter.com/user/status/1234567890")
        XCTAssertEqual(block.range.location, range(of: "<blockquote", in: text).location)
        XCTAssertEqual(NSMaxRange(block.range), NSMaxRange(range(of: "</script>", in: text)))
        // Тот же вид блока, что решает рендер: iframe твита есть в итоговой странице.
        XCTAssertTrue(MarkdownHTMLRenderer.renderPage(text, darkMode: false, includeHTMLMedia: true).html.contains("platform.twitter.com/embed/Tweet.html?id=1234567890"))
    }
}
