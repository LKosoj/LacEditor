import Foundation
import XCTest
@testable import LacEditor

/// Оформление CriticMarkup, `%%`, выносок и `![[…]]` в TextKit-адаптере (U5a, часть А): диапазоны span-ов равны диапазонам
/// сервисов (`CriticMarkupService.items`, `MarkdownObsidianComment.ranges`, `MarkdownNoteEmbed.items`, `MarkdownCalloutRender.marker`).
final class MarkdownPresentationBuilderObsidianTests: XCTestCase {
    /// Документ корпуса (тот же загрузчик, что у эталонов); `crlf` — вариант с `\r\n`.
    private func corpus(_ name: String, crlf: Bool = false) throws -> String {
        let item = try XCTUnwrap(BaselineCorpus.documents().first { $0.id == "doc/Corpus/\(name)" }, "нет документа корпуса \(name)")
        return crlf ? BaselineCorpus.crlf(item.text) : item.text
    }

    private func build(_ text: String, includes: MarkdownDocumentModel.Includes = [], isVaultNote: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) throws -> (MarkdownPresentation, MarkdownDocumentModel) {
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: includes.union([.elementIndex, .editorContext]),
                                                    isVaultNote: isVaultNote, detectsFrontMatter: true)
        let model = try XCTUnwrap(MarkdownDocumentParser.parse(text, options: options), "разбор вернул nil", file: file, line: line)
        let build = MarkdownPresentationBuilder.BuildOptions(includeWikiLinks: true)
        return (MarkdownPresentationBuilder.build(model, text: text as NSString, options: build), model)
    }

    private func excluded(_ model: MarkdownDocumentModel, _ text: String) -> [NSRange] {
        (model.elements ?? .empty).excludedRanges(intersecting: NSRange(location: 0, length: (text as NSString).length))
    }

    private func criticSpans(_ presentation: MarkdownPresentation) -> [(CriticMarkupKind, NSRange, [NSRange])] {
        presentation.spans.compactMap { span in
            if case .critic(let kind) = span.kind { return (kind, span.range, span.markerRanges) }
            return nil
        }
    }

    // MARK: CriticMarkup

    func testCriticSpansMatchCriticMarkupServiceOnCorpusLFAndCRLF() throws {
        for crlf in [false, true] {
            let text = try corpus("critic", crlf: crlf)
            let (presentation, model) = try build(text, includes: [.criticMarkup])
            let items = CriticMarkupService.items(in: text as NSString, excluded: excluded(model, text))
            let spans = criticSpans(presentation)
            XCTAssertFalse(items.isEmpty, "корпус содержит правки (crlf=\(crlf))")
            XCTAssertEqual(spans.map(\.1), items.map(\.range), "диапазоны правок (crlf=\(crlf))")
            XCTAssertEqual(spans.map(\.0), items.map(\.kind), "виды правок (crlf=\(crlf))")
            for (span, item) in zip(spans, items) {
                XCTAssertFalse(span.2.isEmpty, "у правки есть маркеры (crlf=\(crlf))")
                XCTAssertTrue(span.2.allSatisfy { NSIntersectionRange($0, item.range) == $0 }, "маркеры внутри правки (crlf=\(crlf))")
            }
        }
    }

    func testCriticSubstitutionHasThreeMarkersAndEmojiCyrillicUTF16() throws {
        let text = "😀 Замена {~~старое~>новое~~} 汉字"
        let (presentation, _) = try build(text, includes: [.criticMarkup])
        let spans = criticSpans(presentation)
        let whole = (text as NSString).range(of: "{~~старое~>новое~~}")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.0, .substitution)
        XCTAssertEqual(spans.first?.1, whole)
        XCTAssertEqual(spans.first?.2.count, 3, "подмена: «{~~», «~>», «~~}»")
    }

    func testCriticSpansAbsentWithoutFlagAndInCode() throws {
        XCTAssertTrue(criticSpans(try build("Есть {++вставка++}.").0).isEmpty, "без флага .criticMarkup правки не оформляются")
        XCTAssertTrue(criticSpans(try build("Код `{++x++}` и \\{++y++}", includes: [.criticMarkup]).0).isEmpty)
    }

    // MARK: Комментарии %%

    func testObsidianCommentSpansMatchRangesOnCorpusLFAndCRLF() throws {
        for crlf in [false, true] {
            let text = try corpus("obsidian-comments", crlf: crlf)
            let (presentation, model) = try build(text, isVaultNote: true)
            let expected = MarkdownObsidianComment.ranges(in: text as NSString, excluded: excluded(model, text))
            let spans = presentation.spans.filter { $0.kind == .obsidianComment }
            XCTAssertEqual(expected.count, 2, "в корпусе строчный и блочный комментарий (crlf=\(crlf))")
            XCTAssertEqual(spans.map(\.range), expected, "диапазоны комментариев (crlf=\(crlf))")
            XCTAssertTrue(spans.allSatisfy { $0.markerRanges.count == 2 && $0.markerRanges.allSatisfy { (text as NSString).substring(with: $0) == "%%" } },
                          "маркеры — «%%» (crlf=\(crlf))")
        }
    }

    func testObsidianCommentSpansOnlyInVaultNote() throws {
        let text = "Текст 😀 %%комментарий%% дальше"
        XCTAssertTrue(try build(text, isVaultNote: false).0.spans.allSatisfy { $0.kind != .obsidianComment })
        let spans = try build(text, isVaultNote: true).0.spans.filter { $0.kind == .obsidianComment }
        XCTAssertEqual(spans.map(\.range), [(text as NSString).range(of: "%%комментарий%%")])
    }

    // MARK: Выноски

    func testCalloutSpansMatchMarkerAndKeepQuoteOnCorpusLFAndCRLF() throws {
        for crlf in [false, true] {
            let text = try corpus("callouts", crlf: crlf)
            let ns = text as NSString
            let (presentation, _) = try build(text)
            let callouts = presentation.spans.compactMap { span -> (NSRange, [NSRange], String, MarkdownCalloutKind?)? in
                if case .callout(let label, let kind) = span.kind { return (span.range, span.markerRanges, label, kind) }
                return nil
            }
            XCTAssertEqual(callouts.count, 4, "четыре выноски, обычная цитата не в счёт (crlf=\(crlf))")
            for callout in callouts {
                XCTAssertEqual(callout.1.count, 1)
                let marker = callout.1[0]
                // `marker` смотрит на `\n` как на отдельный символ; `\r\n` в Swift один символ, поэтому переводы строк приводим к `\n`.
                let parsed = MarkdownCalloutRender.marker(in: Substring(ns.substring(from: marker.location).replacingOccurrences(of: "\r\n", with: "\n")))
                XCTAssertNotNil(parsed, "в позиции маркера виден разбор выноски (crlf=\(crlf))")
                XCTAssertEqual(parsed.map { ns.substring(with: NSRange(location: marker.location, length: marker.length)).count == $0.length }, true,
                               "маркер — «[!тип]±» целиком (crlf=\(crlf))")
                XCTAssertTrue(ns.substring(with: marker).hasPrefix("[!"))
                XCTAssertTrue(presentation.spans.contains { $0.kind == .quote && $0.range == callout.0 }, "тело остаётся цитатой (crlf=\(crlf))")
            }
            let note = callouts[0]
            XCTAssertEqual(note.3, .note)
            XCTAssertEqual(note.2, MarkdownCalloutKind.note.symbol + " " + MarkdownCalloutKind.note.label)
            XCTAssertEqual(ns.substring(with: note.1[0]), "[!note]")
            XCTAssertEqual(ns.substring(with: callouts[1].1[0]), "[!warning]+")
            XCTAssertEqual(ns.substring(with: callouts[2].1[0]), "[!tip]-")
            let custom = callouts[3]
            XCTAssertEqual(custom.3, .note, "неизвестный тип оформляется как .note")
            XCTAssertEqual(custom.2, MarkdownCalloutKind.note.symbol + " Custom-type", "подпись — сам тип")
            let strong = presentation.spans.filter { $0.kind == .strong && $0.markerRanges.isEmpty }.map { ns.substring(with: $0.range) }
            XCTAssertTrue(strong.contains("Заголовок") && strong.contains("Раскрыта") && strong.contains("Свёрнута"), "заголовок выноски жирным: \(strong)")
        }
    }

    func testCalloutInsideListQuoteKeepsUTF16Ranges() throws {
        let text = "😀\n\n> [!tip] Совет 汉字\n> тело"
        let (presentation, _) = try build(text)
        let span = presentation.spans.first { if case .callout = $0.kind { true } else { false } }
        XCTAssertEqual(span?.markerRanges, [(text as NSString).range(of: "[!tip]")])
        XCTAssertTrue(presentation.spans.contains { $0.kind == .strong && $0.range == (text as NSString).range(of: "Совет 汉字") })
    }

    // MARK: Встраивания

    func testEmbedLinksMatchNoteEmbedItemsOnCorpusLFAndCRLF() throws {
        for crlf in [false, true] {
            let text = try corpus("embeds", crlf: crlf)
            let (presentation, model) = try build(text, includes: [.noteEmbeds])
            let items = MarkdownNoteEmbed.items(in: text as NSString, excluded: excluded(model, text))
            let links = presentation.wikiLinks.filter(\.isEmbed)
            XCTAssertEqual(items.count, 5)
            XCTAssertEqual(links.map(\.range), items.map(\.range), "диапазоны встраиваний (crlf=\(crlf))")
            XCTAssertEqual(links.map(\.target), items.map(\.target))
            XCTAssertEqual(links.map(\.heading), items.map(\.heading))
            for link in links {
                XCTAssertEqual((text as NSString).substring(with: link.markerRanges[0]), "![[", "(crlf=\(crlf))")
                XCTAssertEqual((text as NSString).substring(with: link.markerRanges[1]), "]]", "(crlf=\(crlf))")
                XCTAssertTrue(presentation.spans.contains { $0.kind == .link && $0.range == link.range && $0.markerRanges == link.markerRanges },
                              "span .link с теми же маркерами (crlf=\(crlf))")
            }
            XCTAssertTrue(presentation.wikiLinks.allSatisfy(\.isEmbed), "обычных wiki-ссылок в корпусе нет")
        }
    }

    func testInlineEmbedWithAliasAndWikiLinkSideBySide() throws {
        let text = "Кот 😀 ![[Заметка#Раздел | Подпись]] и [[Другая]]"
        let (presentation, _) = try build(text, includes: [.noteEmbeds, .wikiLinks])
        let ns = text as NSString
        let embed = presentation.wikiLinks.first(where: \.isEmbed)
        XCTAssertEqual(embed?.range, ns.range(of: "![[Заметка#Раздел | Подпись]]"))
        XCTAssertEqual(embed.map { ns.substring(with: $0.displayRange) }, "Подпись", "видна подпись после «|»")
        XCTAssertEqual(embed?.markerRanges, [ns.range(of: "![[Заметка#Раздел | "), ns.range(of: "]]")])
        XCTAssertEqual(embed?.target, "Заметка")
        XCTAssertEqual(embed?.heading, "Раздел")
        XCTAssertEqual(presentation.wikiLinks.filter { !$0.isEmbed }.count, 1, "обычная ссылка не стала встраиванием")
    }

    /// `[[[дом]]]`: wiki-ссылка внутри внешних скобок (диапазон без них), а строка `[[[дом]]]: /url` определением не становится.
    func testTripleBracketWikiLinkInsideBracketsAndNoReferenceDefinition() throws {
        let text = "[[[дом]]]\n\n[[[дом]]]: /url\n"
        let (presentation, _) = try build(text, includes: [.wikiLinks])
        let links = presentation.wikiLinks
        XCTAssertEqual(links.count, 2, "по одному wiki-узлу на строку, определения ссылки нет")
        XCTAssertEqual(links.map(\.range), [NSRange(location: 1, length: 7), NSRange(location: 12, length: 7)])
        XCTAssertEqual(links.map(\.markerRanges), [
            [NSRange(location: 1, length: 2), NSRange(location: 6, length: 2)],
            [NSRange(location: 12, length: 2), NSRange(location: 17, length: 2)]])
        XCTAssertEqual(links.map(\.target), ["дом", "дом"])
    }

    func testEmbedWithEmptyAliasIsNotCreatedLikeWikiLink() throws {
        for text in ["![[a|]]", "![[a| ]]", "Текст ![[a|  ]] 😀"] {
            XCTAssertTrue(try build(text, includes: [.noteEmbeds]).0.wikiLinks.isEmpty, "пустая подпись: \(text)")
        }
        XCTAssertTrue(try build("[[a|]]", includes: [.wikiLinks]).0.wikiLinks.isEmpty, "wiki-ссылка с пустой подписью не создаётся")
    }

    // MARK: Ячейки таблиц и сноски

    // Окраска пропускает таблицы (excludedRanges), но красит сноски: span-ы повторяют диапазоны сервиса.
    func testCriticSpansInFootnoteMatchServiceAndSkipTable() throws {
        let text = "| Колонка 😀 |\n| --- |\n| {++новое++} |\n\nТекст[^1]\n\n[^1]: {--старое--}\n"
        let (presentation, model) = try build(text, includes: [.criticMarkup])
        let items = CriticMarkupService.items(in: text as NSString, excluded: excluded(model, text))
        XCTAssertEqual(items.count, 1, "правка в таблице исключена из подсчёта")
        XCTAssertEqual(criticSpans(presentation).map(\.1), items.map(\.range), "правка в сноске есть, в ячейке нет")
    }

    func testCommentSpansInFootnoteMatchRangesAndSkipTable() throws {
        let text = "| Колонка |\n| --- |\n| %%заметка%% |\n\nТекст[^1]\n\n[^1]: %%в сноске%%\n"
        let (presentation, model) = try build(text, isVaultNote: true)
        let expected = MarkdownObsidianComment.ranges(in: text as NSString, excluded: excluded(model, text))
        XCTAssertEqual(expected.count, 1)
        XCTAssertEqual(presentation.spans.filter { $0.kind == .obsidianComment }.map(\.range), expected)
    }

    func testEmbedWithoutFlagIsPlainText() throws {
        XCTAssertTrue(try build("![[x]]").0.wikiLinks.isEmpty, "без флага .noteEmbeds встраивание — обычный текст")
    }
}
