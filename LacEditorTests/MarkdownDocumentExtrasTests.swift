import Foundation
import XCTest
@testable import LacEditor

/// Дополнительные данные модели (U2.5b): поля модели, флаги `Includes` и отмена.
final class MarkdownDocumentExtrasTests: XCTestCase {
    private let everything: MarkdownDocumentModel.Includes = [.wikiLinks, .emoji, .uppercaseRuns, .readableText, .blockIndex, .editorContext]

    private func options(_ includes: MarkdownDocumentModel.Includes, vault: Bool = false,
                         syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions()) -> MarkdownDocumentModel.Options {
        MarkdownDocumentModel.Options(syntax: syntax, includes: includes, isVaultNote: vault, detectsFrontMatter: true)
    }

    private func model(_ text: String, _ includes: MarkdownDocumentModel.Includes, vault: Bool = false,
                       syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(), file: StaticString = #filePath, line: UInt = #line) -> MarkdownDocumentModel {
        guard let result = MarkdownDocumentParser.parse(text, options: options(includes, vault: vault, syntax: syntax)) else {
            XCTFail("разбор вернул nil", file: file, line: line)
            return MarkdownDocumentParser.parse("", options: options(includes))!
        }
        return result
    }

    /// Заголовки модели в порядке документа, как `MarkdownPresentation.headings` (без заголовков в сносках).
    private func headings(_ blocks: [MarkdownBlockNode]) -> [MarkdownBlockNode.Heading] {
        blocks.flatMap { block -> [MarkdownBlockNode.Heading] in
            var result: [MarkdownBlockNode.Heading] = []
            if case let .heading(heading) = block.kind, !heading.inUnsupportedContainer { result.append(heading) }
            return result + headings(block.children)
        }
    }

    private func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Характерные входы: кириллица, CJK, эмодзи, `\r\n`, заголовки с `<u>`, `<br>`, формулами, setext, wiki-ссылки, HTML.
    private let samples: [String] = [
        "# Привет :smile: мир\n\nТекст «цитаты» -- и \"кавычки\"... :tada:\n",
        "# 日本語 :heart: 見出し\n\n中文段落 *强调* 与 **粗体** `代码`\n",
        "## 👍 Эмодзи 🎉 :rocket:\n\nабзац 😀 текст\n",
        "# Один\r\n\r\nПервая :smile: строка\r\nвторая строка\r\n\r\n- пункт\r\n- пункт [[Цель#Раздел|Псевдоним]]\r\n",
        "# A <u>подчёркнутый</u> заголовок\n\n## B<br>перенос\n\n### C $x^2$ формула ![i](a.png)\n",
        "Setext заголовок\nвторая строка\n===\n\nДругой *заголовок*\n---\n",
        "Заголовок с хвостом   \nвторая  \nстрока\n===\n",
        "> # В цитате :smile:\n> текст\n\n- # В списке\n",
        "Ссылка [[Заметка]] и ![[Встраивание]] и `[[код]]` и \\[[экран]] и [текст [[внутри]]](u).\n\n# [[В заголовке]]\n\n| a | [[в таблице]] |\n|---|---|\n| 1 | 2 |\n",
        "<div>\n:smile: в блоке\n</div>\n\nТекст <span>:tada:</span> и <script>:x:</script> и <style>a</style>\n",
        "<details><summary>S</summary>\n\nтекст :smile:\n\n</details>\n\nконец\n",
        "Абзац\n\n[ref]: http://example.com\n\nПосле определения\n",
        "---\ntitle: Тест :smile:\n---\n\n# Заголовок\n\nТекст.\n",
        "Строка с\ttab\n\n- пункт\n\tпродолжение\n\n    отступный код\n\n```swift\nlet a = 1\n```\n",
        "> цитата\nленивое продолжение\n\n1. один\n2. два\n   вложено\n",
        "$$\nx = 1\n$$\n\nСтрочная $a$ формула :smile:\n\n[toc]\n\n[^1]: сноска\n\nТекст[^1]\n",
        "Текст &amp; сущность :smile: \\:не эмодзи\\: и `:код:`\n",
        "",
        "\n\n\n",
        // Узлы в многострочных абзацах: ветки отложенных узлов и маркеров ссылок (`delayedMappedSpans`, `delayedMappedLinks`).
        // Вход `1. [ссылка\n   на две](http://a.b)` сюда не входит: ядро берёт его диапазон из cmark и не помечает ненадёжным (решение 1, docs/unified-model/U2.5-plan.md, раздел 6); поведение проверяет `testMultilineLinkInListItemIsReliableInCore`.
        "- пункт *жирный\n  продолжение* конец\n",
        "> **начало\nленивое** конец\n",
        "- a\n\t*b\n\tc*\n",
        "> [текст\n> строка][ref]\n\n[ref]: http://x\n",
        "* пункт\n\n  > цитата ~~зачёркнут\n  > дальше~~ и [л\n  > и](u)\n",
        "\t- вложенный `код\n\tещё` и **ж\n\tж**\n",
        "- а\n\n\t> [x\n\t> y](u) `c\n\td`\n",
    ]

    private func corpus() throws -> [(id: String, text: String)] {
        var items = try BaselineCorpus.documents().map { ($0.id, $0.text) }
        items += try BaselineCorpus.crlfDocuments().map { ($0.id, $0.text) }
        items += samples.enumerated().map { ("sample\($0.offset)", $0.element) }
        items += samples.enumerated().map { ("sample\($0.offset)[crlf]", crlf($0.element)) }
        return items
    }

    // MARK: - Флаги и отмена

    func testFieldsAreEmptyWithoutTheirFlags() throws {
        for (id, text) in try corpus() {
            let plain = model(text, [])
            XCTAssertNil(plain.readableText, "\(id): readableText без флага")
            XCTAssertNil(plain.blockIndex, "\(id): blockIndex без флага")
            XCTAssertNil(plain.emoji, "\(id): emoji без флага")
            XCTAssertTrue(plain.wikiLinks.isEmpty, "\(id): wikiLinks без флага")
            XCTAssertTrue(plain.looseIndents.isEmpty, "\(id): looseIndents без флага")
            XCTAssertTrue(headings(plain.blocks).allSatisfy { $0.uppercaseRuns == nil && $0.emoji.isEmpty }, "\(id): данные заголовков без флага")
        }
    }

    func testOnlyRequestedFieldsAreFilled() {
        let text = "# Заголовок :smile:\n\nТекст [[Цель]]\n"
        let readable = model(text, [.readableText])
        XCTAssertNotNil(readable.readableText)
        XCTAssertNil(readable.blockIndex)
        XCTAssertNil(readable.emoji)
        let blocks = model(text, [.blockIndex])
        XCTAssertNotNil(blocks.blockIndex)
        XCTAssertEqual(blocks.blockIndex?.blocks.map(\.readableEnd), [0, 0], "без читаемого текста readableEnd равен нулю")
        XCTAssertNil(blocks.readableText)
        let emoji = model(text, [.emoji])
        XCTAssertEqual(emoji.emoji?.candidates.map(\.name), ["smile"])
        XCTAssertTrue(headings(emoji.blocks).allSatisfy { $0.uppercaseRuns == nil }, "uppercaseRuns только вместе с флагом")
        XCTAssertEqual(headings(model(text, [.emoji, .uppercaseRuns]).blocks).first?.emoji.map(\.name), ["smile"])
        XCTAssertNil(headings(model(text, [.uppercaseRuns]).blocks).first?.uppercaseRuns, "uppercaseRuns требует emoji")
        XCTAssertEqual(model(text, [.wikiLinks]).wikiLinks.map(\.target), ["Цель"])
    }

    /// Отмена на любом из вызовов `isCancelled` (включая участок `fillExtras` в конце) даёт nil, а не частичную модель.
    func testCancellationAtAnyCheckGivesNilForExtras() {
        let text = "---\ntitle: x\n---\n\n# Заголовок :smile: 日本\n\nТекст [[Цель]] и <u>тег</u> :tada:\n\n- пункт\n- ещё\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        var total = 0
        XCTAssertNotNil(MarkdownDocumentParser.parse(text, options: options(everything), isCancelled: { total += 1; return false }))
        XCTAssertGreaterThan(total, 0)
        // Все пороги, если вызовов немного; иначе равномерно плюс последние 100 (там работает `fillExtras`).
        let step = max(1, total / 300)
        let thresholds = Array(Set(Array(stride(from: 0, to: total, by: step)) + Array(max(0, total - 100)..<total))).sorted()
        for threshold in thresholds {
            var calls = 0
            let result = MarkdownDocumentParser.parse(text, options: options(everything), isCancelled: { calls += 1; return calls > threshold })
            XCTAssertNil(result, "отмена после \(threshold) из \(total) проверок: получена частичная модель")
        }
    }

    // MARK: - Маски

    private func assertVaultCommentExact(_ text: String, _ label: String) {
        let ns = text as NSString
        let result = model(text, everything, vault: true)
        let comment = ns.range(of: "%% скрыто %%")
        let tada = ns.range(of: ":tada:")
        XCTAssertEqual(result.emoji?.candidates, [MarkdownEmojiCandidate(name: "tada", range: tada)], "\(label): кандидат")
        // Текст вокруг комментария до конца строки (без перевода строки): места делятся по комментарию.
        let end = ns.range(of: "日本").upperBound
        let expected = [NSRange(location: 0, length: comment.location), NSRange(location: NSMaxRange(comment), length: end - NSMaxRange(comment))]
        XCTAssertEqual(result.emoji?.completionRanges, expected, "\(label): места автодополнения")
        XCTAssertEqual(result.emoji?.smartTextRanges, expected, "\(label): места умных замен")
        let whole = NSRange(location: 0, length: ns.length)
        XCTAssertNil(result.readableText?.text(in: whole, source: ns), "\(label): выделение над маской копируется обычным путём")
        XCTAssertNotNil(model(text, everything, vault: false).readableText?.text(in: whole, source: ns), "\(label): без маски выделение читается")
    }

    func testVaultCommentGivesExactRangesWithNonBMPAndCJK() {
        assertVaultCommentExact("😀 %% скрыто %% :tada: 日本\n", "LF")
        assertVaultCommentExact("😀 %% скрыто %% :tada: 日本\r\n", "CRLF")
        let text = "Начало %% скрыто :smile: %% конец :tada: текст\n"
        XCTAssertEqual(model(text, everything, vault: true).emoji?.candidates.map(\.name), ["tada"], "эмодзи внутри комментария не кандидат")
    }

    func testHeadingEmojiShiftsPastRemovedMask() {
        let text = "# Заголовок %% c %% :smile:\n"
        let heading = headings(model(text, everything, vault: true).blocks).first
        XCTAssertEqual(heading?.title, "Заголовок  :smile:", "заменители маски убраны из названия")
        let title = (heading?.title ?? "") as NSString
        XCTAssertEqual(heading?.emoji.map(\.name), ["smile"])
        XCTAssertEqual(heading?.emoji.map(\.range), [title.range(of: ":smile:")], "диапазон эмодзи относится к очищенному названию")
        // Название с маской без смены длины невозможно: комментарий и маркеры всегда оставляют заменители в тексте узла.
        let critic = "# {++ новый ++} :tada: 日本\n"
        var criticOptions = options(everything)
        criticOptions.includes.insert(.criticMarkup)
        let criticHeading = headings((MarkdownDocumentParser.parse(critic, options: criticOptions) ?? model("", [])).blocks).first
        let criticTitle = (criticHeading?.title ?? "") as NSString
        XCTAssertEqual(criticHeading?.emoji.map(\.range), [criticTitle.range(of: ":tada:")])
    }

    func testBlockIndexWithFrontMatterKeepsFlag() {
        for text in ["---\ntitle: Тест\n---\n\n# Заголовок\n\nТекст.\n", "---\r\ntitle: Тест\r\n---\r\n\r\n# Заголовок\r\n\r\nТекст.\r\n"] {
            let result = model(text, everything)
            XCTAssertNotNil(result.blockIndex, "индекс с front matter строится")
            XCTAssertEqual(result.blockIndex?.hasFrontMatter, true)
            XCTAssertEqual(result.blockIndex?.blocks.count, 2)
        }
    }

    private func firstLink(_ blocks: [MarkdownBlockNode]) -> MarkdownInlineNode? {
        func inInlines(_ nodes: [MarkdownInlineNode]) -> MarkdownInlineNode? {
            for node in nodes {
                if case .link = node.kind { return node }
                if let found = inInlines(node.children) { return found }
            }
            return nil
        }
        for block in blocks {
            if let found = inInlines(block.inlines) ?? firstLink(block.children) { return found }
        }
        return nil
    }

    /// Многострочная ссылка в пункте списка: ядро берёт диапазон из cmark и не помечает её ненадёжной (решение 1, U2.5-plan.md, раздел 6).
    func testMultilineLinkInListItemIsReliableInCore() {
        for newline in ["\n", "\r\n"] {
            let text = "1. [ссылка\(newline)   на две](http://a.b)\(newline)"
            let ns = text as NSString
            let result = model(text, everything)
            XCTAssertEqual(result.unreliableRanges, [], "перевод строки \(newline.debugDescription): ненадёжных строк нет")
            let link = firstLink(result.blocks)
            XCTAssertNotNil(link, "ссылка найдена")
            XCTAssertEqual(link?.isUnreliable, false)
            let start = ns.range(of: "[").location
            let close = ns.range(of: "](").location
            let end = ns.range(of: ")").upperBound
            XCTAssertEqual(link?.range, NSRange(location: start, length: end - start), "перевод строки \(newline.debugDescription): диапазон")
            XCTAssertEqual(link?.markerRanges, [NSRange(location: start, length: 1), NSRange(location: close, length: end - close)],
                           "перевод строки \(newline.debugDescription): скобки")
        }
    }

    func testCriticMarkupMarkersAreNotTextPlaces() {
        let text = "До {++ вставка :smile: ++} после\n"
        var criticOptions = options(everything)
        criticOptions.includes.insert(.criticMarkup)
        let critic = MarkdownDocumentParser.parse(text, options: criticOptions)
        let ns = text as NSString
        let markers = ns.range(of: "{++"), closing = ns.range(of: "++}")
        for range in (critic?.emoji?.completionRanges ?? []) + (critic?.emoji?.smartTextRanges ?? []) {
            XCTAssertEqual(NSIntersectionRange(range, markers).length, 0, "место текста \(range) пересекает открывающий маркер")
            XCTAssertEqual(NSIntersectionRange(range, closing).length, 0, "место текста \(range) пересекает закрывающий маркер")
        }
        XCTAssertFalse((critic?.emoji?.smartTextRanges ?? []).isEmpty, "текст вокруг маркеров остаётся")
        XCTAssertEqual(critic?.emoji?.candidates, [MarkdownEmojiCandidate(name: "smile", range: ns.range(of: ":smile:"))])
        XCTAssertNotNil(critic?.readableText, "читаемый текст построен")
        XCTAssertNil(critic?.readableText?.text(in: NSRange(location: 0, length: ns.length), source: ns))
    }
}
