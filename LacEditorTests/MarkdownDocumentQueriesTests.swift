import Foundation
import XCTest
@testable import LacEditor

/// Общие запросы к модели (U7.0): сверка с полями `MarkdownPresentationBuilder` на корпусе и малые случаи с позициями в UTF-16.
final class MarkdownDocumentQueriesTests: XCTestCase {
    private static let looseSyntax = MarkdownSyntaxOptions(strictMode: false, legacyInlineMath: true, smartPunctuation: false)

    private func model(_ text: String, syntax: MarkdownSyntaxOptions = MarkdownSyntaxOptions(), isVaultNote: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) throws -> MarkdownDocumentModel {
        let includes = MarkdownPresentationBuilder.editorIncludes(emojiCandidates: true, wikiLinks: true)
        return try XCTUnwrap(MarkdownPresentationBuilder.model(of: text, syntax: syntax, includes: includes, isVaultNote: isVaultNote),
                             "разбор вернул nil", file: file, line: line)
    }

    private func range(of part: String, in text: String, occurrence: Int = 0, file: StaticString = #filePath, line: UInt = #line) -> NSRange {
        let source = text as NSString
        var found = NSRange(location: NSNotFound, length: 0)
        var from = 0
        for _ in 0...occurrence {
            found = source.range(of: part, range: NSRange(location: from, length: source.length - from))
            XCTAssertNotEqual(found.location, NSNotFound, "в тексте нет «\(part)»", file: file, line: line)
            if found.location == NSNotFound { break }
            from = NSMaxRange(found)
        }
        return found
    }

    // MARK: - Корпус: запросы равны полям builder

    /// Расхождения, которые не ошибка: перечень причин. Остальное падает как расхождение.
    /// 1. Ссылки в таблицах и определениях сносок: `links` builder берёт их, а `.link`-спан со скобками (`markers`) — нет (спан только вне таблиц).
    private func compare(_ item: BaselineItem, syntax: MarkdownSyntaxOptions, tally: inout [String: Int]) throws -> [String] {
        let model = try self.model(item.text, syntax: syntax, isVaultNote: true)
        let text = item.text
        let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
        guard let queries = model.queries() else { return ["\(item.id): запрос вернул nil"] }
        var issues: [String] = []
        func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got != want { issues.append("\(item.id) [\(name)]\n  запросы:  \(got)\n  builder:  \(want)") }
        }
        check("wikiLinks", queries.wikiLinks, presentation.wikiLinks.filter { !$0.isEmbed })
        check("links", queries.linkEntries.map(\.link), presentation.links)
        func heading(_ value: MarkdownHeading) -> String { "\(value.level)|\(value.title)|\(value.range.location),\(value.range.length)|\(value.isTopLevel)" }
        check("headings", queries.headings.map(heading), presentation.headings.map(heading))
        check("headingEmoji", queries.headings.map(\.emoji), presentation.headings.map(\.emoji))
        check("formulas", queries.formulas, presentation.formulas)
        check("inlineFormulas", queries.inlineFormulas, presentation.inlineFormulas)
        check("tableOfContents", queries.tableOfContentsRanges, presentation.tableOfContents)
        check("emojiCandidates", queries.emojiCandidates, presentation.emojiCandidates)
        check("emojiCompletionRanges", queries.emojiCompletionRanges, presentation.emojiCompletionRanges)
        let markers = presentation.spans.compactMap { span -> NSRange? in
            guard case .heading = span.kind else { return nil }
            return span.markerRanges.first
        }
        check("headingMarkers", queries.headingMarkerRanges, markers)
        // Хвост `](…)`: каждый двухмаркерный `.link`-спан builder есть среди запросов с теми же маркерами (обратное — ссылки в таблицах).
        let entriesByRange = Dictionary(queries.linkEntries.filter { $0.markers.count == 2 }.map { ($0.link.range, $0.markers) }, uniquingKeysWith: { first, _ in first })
        for span in presentation.spans where span.kind == .link && span.markerRanges.count == 2 {
            // Wiki-ссылка тоже получает `.link`-спан с двумя маркерами `[[`/`]]`: это не Markdown-ссылка.
            if presentation.wikiLinks.contains(where: { $0.range == span.range }) { continue }
            if entriesByRange[span.range] != span.markerRanges {
                issues.append("\(item.id) [linkTail] \(span.range): запросы \(String(describing: entriesByRange[span.range])), builder \(span.markerRanges)")
            }
        }
        tally["wikiLinks", default: 0] += queries.wikiLinks.count
        tally["links", default: 0] += queries.linkEntries.count
        tally["htmlLinks", default: 0] += queries.linkEntries.filter { $0.form == .html }.count
        tally["headings", default: 0] += queries.headings.count
        tally["formulas", default: 0] += queries.formulas.count
        tally["inlineFormulas", default: 0] += queries.inlineFormulas.count
        tally["tableOfContents", default: 0] += queries.tableOfContentsRanges.count
        tally["emojiCandidates", default: 0] += queries.emojiCandidates.count
        tally["emojiCompletionRanges", default: 0] += queries.emojiCompletionRanges.count
        tally["headingMarkers", default: 0] += queries.headingMarkerRanges.count
        let media = mediaCount(model.blocks)
        tally["mediaBlocks", default: 0] += media.blocks
        tally["mediaInlines", default: 0] += media.inlines
        tally["blockedHTML"] = (tally["blockedHTML"] ?? 0) + (model.blockedHTML.isEmpty ? 0 : 1)
        return issues
    }

    /// Сколько в модели блоков и строчных узлов-рамок медиа: по ним видно, что отсев по медиа на корпусе вообще проверялся.
    private func mediaCount(_ blocks: [MarkdownBlockNode]) -> (blocks: Int, inlines: Int) {
        var result = (blocks: 0, inlines: 0)
        func inlines(_ nodes: [MarkdownInlineNode]) {
            for node in nodes { if node.isMediaFrame { result.inlines += 1 }; inlines(node.children) }
        }
        func walk(_ list: [MarkdownBlockNode]) {
            for block in list {
                if case .html(let html) = block.kind, html.kind.isMediaFrame { result.blocks += 1 }
                inlines(block.inlines)
                if case .table(let table) = block.kind { for row in table.rows { for cell in row.cells { inlines(cell.inlines) } } }
                walk(block.children)
            }
        }
        walk(blocks)
        return result
    }

    func testQueriesEqualBuilderFieldsOnCorpusWithLFAndCRLF() throws {
        let items = try BaselineCorpus.spec() + BaselineCorpus.extensions() + BaselineCorpus.documents()
        let all = items + items.map { BaselineItem(id: $0.id + "[crlf]", section: "", text: BaselineCorpus.crlf($0.text)) }
        var issues: [String] = []
        var tally: [String: Int] = [:]
        for syntax in [MarkdownSyntaxOptions(), Self.looseSyntax] {
            for item in all {
                issues += try compare(item, syntax: syntax, tally: &tally)
            }
        }
        XCTAssertEqual(issues, [], "расхождения запросов и builder: \(issues.count)")
        // Корпус не должен проходить вхолостую: все виды данных встречаются.
        for key in ["wikiLinks", "links", "headings", "formulas", "inlineFormulas", "tableOfContents", "emojiCandidates",
                    "emojiCompletionRanges", "headingMarkers", "blockedHTML", "mediaBlocks", "mediaInlines"] {
            XCTAssertGreaterThan(tally[key] ?? 0, 0, "в корпусе нет данных «\(key)»")
        }
    }

    // MARK: - Малые случаи

    func testCyrillicCJKAndEmojiWikiLinksKeepUTF16Ranges() throws {
        let text = "Привет 😀 [[Цель#Заголовок|текст]] и 漢字 [[日本語#章|読む]] 🎉\n"
        let wiki = try model(text).wikiLinks
        XCTAssertEqual(wiki.count, 2)
        let first = range(of: "[[Цель#Заголовок|текст]]", in: text)
        XCTAssertEqual(wiki[0].range, first)
        XCTAssertEqual(wiki[0].target, "Цель")
        XCTAssertEqual(wiki[0].heading, "Заголовок")
        XCTAssertEqual(wiki[0].alias, "текст")
        XCTAssertEqual(wiki[0].displayRange, range(of: "текст", in: text))
        XCTAssertEqual(wiki[1].range, range(of: "[[日本語#章|読む]]", in: text))
        XCTAssertEqual(wiki[1].target, "日本語")
        XCTAssertEqual(wiki[1].displayRange, range(of: "読む", in: text))
        XCTAssertEqual(wiki[0].markerRanges.count, 2)
    }

    func testCRLFKeepsWikiLinkHeadingAndFormulaRanges() throws {
        let text = "# Глава 😀\r\n\r\nСм. [[Цель#Заголовок|текст]] и $x^2$.\r\n\r\n$$\r\ny=1\r\n$$\r\n"
        let model = try self.model(text)
        XCTAssertEqual(model.wikiLinks.map(\.range), [range(of: "[[Цель#Заголовок|текст]]", in: text)])
        XCTAssertEqual(model.headings.map(\.title), ["Глава 😀"])
        XCTAssertEqual(model.headings.map(\.range), [range(of: "# Глава 😀", in: text)])
        // Маркер ATX — `#` вместе с пробелом после него.
        XCTAssertEqual(model.headingMarkerRanges, [NSRange(location: 0, length: 2)])
        XCTAssertEqual(model.inlineFormulas.map(\.range), [range(of: "$x^2$", in: text)])
        XCTAssertEqual(model.inlineFormulas.map(\.source), ["x^2"])
        XCTAssertEqual(model.formulas.count, 1)
        XCTAssertEqual(model.formulas.first?.range, range(of: "$$\r\ny=1\r\n$$", in: text))
    }

    func testWikiLinkIsNotFoundInTableCodeAndFencedCode() throws {
        let text = """
        | Ссылка | Тест |
        | --- | --- |
        | [[Цель#Заголовок|текст]] | 漢字 |

        Код `[[в коде]]` и вне кода [[вне]].

        ```
        [[в блоке]]
        ```

        """
        let wiki = try model(text).wikiLinks
        XCTAssertEqual(wiki.map(\.target), ["вне"], "в таблице, строчном коде и блоке кода wiki-ссылок нет")
        XCTAssertEqual(wiki.first?.range, range(of: "[[вне]]", in: text))
    }

    func testWikiLinkInsideMarkdownLinkTextMatchesBuilder() throws {
        let text = "Вот [текст [[Цель#Заголовок|внутри]] ссылки](https://example.com/漢字) и [[снаружи]].\n"
        let model = try self.model(text)
        let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
        XCTAssertEqual(model.wikiLinks, presentation.wikiLinks.filter { !$0.isEmbed })
        XCTAssertEqual(model.linkEntries.map(\.link), presentation.links)
        XCTAssertTrue(model.wikiLinks.contains { $0.target == "снаружи" })
    }

    func testEmbedIsNotWikiLink() throws {
        let text = "Вложение ![[Цель]] и ссылка [[Цель]].\n"
        let wiki = try model(text).wikiLinks
        XCTAssertEqual(wiki.map(\.range), [range(of: "[[Цель]]", in: text, occurrence: 1)])
    }

    func testLinkEntriesCoverInlineReferenceAutolinkAndHTMLAnchor() throws {
        let text = "[текст](https://a.example/путь) [ссылка][id] <https://b.example> <a href=\"https://c.example\">HTML 漢字</a>\n\n[id]: https://d.example\n"
        let entries = try model(text).linkEntries
        XCTAssertEqual(entries.map(\.form), [.inline, .reference, .autolink, .html])
        XCTAssertEqual(entries.dropFirst().map(\.markers), [[], [], []], "маркеры `](…)` только у inline, как у builder")
        XCTAssertEqual(entries[0].link.range, range(of: "[текст](https://a.example/путь)", in: text))
        XCTAssertEqual(entries[0].markers.count, 2)
        XCTAssertEqual(entries[0].markers[1], range(of: "](https://a.example/путь)", in: text))
        XCTAssertEqual(entries[0].link.url, "https://a.example/путь")
        XCTAssertEqual(entries[1].link.url, "https://d.example")
        XCTAssertEqual(entries[2].link.url, "https://b.example")
        XCTAssertEqual(entries[3].link.url, "https://c.example")
        XCTAssertEqual(entries[3].link.range, range(of: "<a href=\"https://c.example\">HTML 漢字</a>", in: text))
    }

    func testHeadingsSkipFootnoteDefinitionsAndKeepQuoteAndSetext() throws {
        let text = "# Раздел 😀 ##\n\nЗаголовок 2\n-----\n\n> ## В цитате\n\nСсылка[^1].\n\n[^1]: Сноска\n\n    # не заголовок\n"
        let model = try self.model(text)
        XCTAssertEqual(model.headings.map(\.title), ["Раздел 😀", "Заголовок 2", "В цитате"])
        XCTAssertEqual(model.headings.map(\.level), [1, 2, 2])
        XCTAssertEqual(model.headings.map(\.isTopLevel), [true, true, false])
        XCTAssertEqual(model.headings[0].range, range(of: "# Раздел 😀 ##", in: text))
        // Маркер только у ATX (`#`/`##` с пробелом): у setext его нет.
        XCTAssertEqual(model.headingMarkerRanges, [NSRange(location: 0, length: 2), NSRange(location: range(of: "## В цитате", in: text).location, length: 3)])
        XCTAssertEqual(model.headings.count, model.headingIDs.filter { !$0.isEmpty }.count)
    }

    func testTableOfContentsAndFormulasIgnoreCodeAndTable() throws {
        let text = "[toc]\n\n```\n[toc]\n$$x$$\n```\n\n| a |\n| --- |\n| $y$ |\n\nТекст $z$ и `$c$`.\n"
        let model = try self.model(text)
        XCTAssertEqual(model.tableOfContentsRanges, [NSRange(location: 0, length: 5)])
        let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
        XCTAssertEqual(model.inlineFormulas, presentation.inlineFormulas)
        XCTAssertEqual(model.formulas, presentation.formulas)
        XCTAssertTrue(model.inlineFormulas.contains { $0.source == "z" })
        XCTAssertFalse(model.inlineFormulas.contains { $0.source == "c" }, "формула в строчном коде не берётся")
    }

    func testEmojiQueriesFollowModel() throws {
        let text = "Привет :smile: 漢字 :tada: и :sm\n"
        let model = try self.model(text)
        let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
        XCTAssertEqual(model.queries(.emoji)?.emojiCandidates, presentation.emojiCandidates)
        XCTAssertEqual(model.queries(.emoji)?.emojiCompletionRanges, presentation.emojiCompletionRanges)
        XCTAssertEqual(model.queries(.emoji)?.emojiCandidates.map(\.range), [range(of: ":smile:", in: text), range(of: ":tada:", in: text)])
    }

    /// Формула и эмодзи внутри audio/iframe закрыты медиа: в запросах их нет, как в оформлении (`overlapsMedia`).
    func testInlineFormulaAndEmojiInsideMediaMatchBuilder() throws {
        let text = "Раз $a$ :smile:\n\n<iframe src=\"https://example.com/漢字\" width=\"300\" height=\"200\">$b$ :tada:</iframe>\n\nДва $c$ :tada:\n"
        let model = try self.model(text)
        let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
        XCTAssertEqual(model.inlineFormulas, presentation.inlineFormulas)
        XCTAssertEqual(model.queries(.emoji)?.emojiCandidates, presentation.emojiCandidates)
        XCTAssertTrue(model.inlineFormulas.contains { $0.source == "a" } && model.inlineFormulas.contains { $0.source == "c" })
        XCTAssertFalse(model.inlineFormulas.contains { $0.source == "b" }, "формула под iframe закрыта медиа")
    }

    /// Таблица в определении сноски: builder в её ячейки не заходит, ссылок и формул оттуда нет и в запросах.
    func testTableInsideFootnoteDefinitionIsSkippedLikeBuilder() throws {
        let text = "Текст[^1] [у](https://v.example) $g$\n\n[^1]: Сноска\n\n    | a |\n    | --- |\n    | [x](https://u.example) $f$ |\n"
        let model = try self.model(text)
        // Без этого тест прошёл бы пустым: таблица должна лежать внутри определения сноски.
        func tableInFootnote(_ blocks: [MarkdownBlockNode], inside: Bool) -> Bool {
            blocks.contains { block in
                if case .table = block.kind, inside { return true }
                var nested = inside
                if case .footnoteDefinition = block.kind { nested = true }
                return tableInFootnote(block.children, inside: nested)
            }
        }
        XCTAssertTrue(tableInFootnote(model.blocks, inside: false), "в модели есть таблица внутри .footnoteDefinition")
        let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
        XCTAssertEqual(model.linkEntries.map(\.link), presentation.links)
        XCTAssertEqual(model.inlineFormulas, presentation.inlineFormulas)
        XCTAssertEqual(model.linkEntries.map(\.link.url), ["https://v.example"])
        XCTAssertEqual(model.inlineFormulas.map(\.source), ["g"])
    }

    /// Блочные audio и твит закрывают только себя: данные после блока остаются, как у builder.
    func testBlockAudioAndTweetHideOnlyTheirOwnRangeLikeBuilder() throws {
        let tweet = "<blockquote class='twitter-tweet'><p>Sunsets 中文</p><a href='https://x.com/Interior/status/463440424141459456'>Post</a></blockquote>\n<script async src='https://platform.twitter.com/widgets.js' charset='utf-8'></script>"
        for (name, block) in [("audio", "<audio controls>\n<source src=\"a.mp3\">\n$b$ :tada:\n</audio>"), ("twitter", tweet)] {
            let text = "До $a$ :smile:\n\n\(block)\n\nПосле $d$ :tada: и $e$\n"
            let model = try self.model(text)
            let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
            XCTAssertEqual(mediaCount(model.blocks).blocks, 1, "\(name): блок разобран как медиа")
            XCTAssertEqual(model.inlineFormulas, presentation.inlineFormulas, name)
            XCTAssertEqual(model.queries(.emoji)?.emojiCandidates, presentation.emojiCandidates, name)
            let sources = model.inlineFormulas.map(\.source)
            XCTAssertTrue(sources.contains("a") && sources.contains("d") && sources.contains("e"), "\(name): формулы до и после блока на месте: \(sources)")
            // :smile: до блока и :tada: после него есть; :tada: внутри <audio> нет (у твита своего текста внутри нет).
            let tadaAfter = range(of: ":tada:", in: text, occurrence: name == "audio" ? 1 : 0)
            XCTAssertEqual(model.queries(.emoji)?.emojiCandidates.map(\.name), ["smile", "tada"], name)
            XCTAssertEqual(model.queries(.emoji)?.emojiCandidates.map(\.range), [range(of: ":smile:", in: text), tadaAfter], name)
        }
    }

    /// Строчный audio закрывает формулу и эмодзи внутри себя (twitter бывает только блоком, строчного нет).
    func testInlineAudioHidesFormulaAndEmojiInsideIt() throws {
        let text = "Раз :smile: <audio src=\"a.mp3\">$b$ :tada:</audio> конец $c$\n"
        let model = try self.model(text)
        let presentation = MarkdownPresentationBuilder.presentation(model, of: text, emojiCandidates: true, wikiLinks: true)
        XCTAssertEqual(model.inlineFormulas, presentation.inlineFormulas)
        XCTAssertEqual(model.queries(.emoji)?.emojiCandidates, presentation.emojiCandidates)
        XCTAssertEqual(mediaCount(model.blocks).inlines, 1, "audio разобран как строчное медиа")
        XCTAssertEqual(model.inlineFormulas.map(\.source), ["c"])
    }

    // MARK: - parseOrEmpty и отмена

    func testParseOrEmptyReturnsEmptyModelOnCancellation() {
        let model = MarkdownDocumentParser.parseOrEmpty("# Заголовок\n\n[[Цель]]\n", includes: [.wikiLinks], isCancelled: { true })
        XCTAssertEqual(model.textLength, 0)
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertEqual(model.headings, [])
        XCTAssertEqual(model.wikiLinks, [])
    }

    func testParseOrEmptyParsesTextWithRequestedIncludes() {
        let text = "# Заголовок\n\nСм. [[Цель]].\n"
        let model = MarkdownDocumentParser.parseOrEmpty(text, includes: [.wikiLinks])
        XCTAssertEqual(model.textLength, (text as NSString).length)
        XCTAssertEqual(model.wikiLinks.map(\.target), ["Цель"])
        XCTAssertEqual(MarkdownDocumentParser.parseOrEmpty(text).wikiLinks, [], "без includes wiki-ссылок нет")
        XCTAssertEqual(model.headings.map(\.title), ["Заголовок"])
    }

    func testQueriesStopOnCancellationAndReturnNil() throws {
        let model = try self.model("# Заголовок\n\nТекст\n")
        XCTAssertNil(model.queries(isCancelled: { true }))
    }
}
