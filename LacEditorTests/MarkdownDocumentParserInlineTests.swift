import Foundation
import XCTest
@testable import LacEditor

/// Единый разбор Markdown (U2.3b): строчные узлы по тексту — wiki-ссылки, `![[…]]`, эмодзи, подсветка, индексы, правки и комментарии.
final class MarkdownDocumentParserInlineTests: XCTestCase {
    private func parse(_ text: String, includes: MarkdownDocumentModel.Includes = [.wikiLinks, .noteEmbeds, .criticMarkup, .emoji],
                       vault: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> MarkdownDocumentModel {
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: includes, isVaultNote: vault, detectsFrontMatter: true)
        guard let model = MarkdownDocumentParser.parse(text, options: options) else {
            XCTFail("разбор вернул nil", file: file, line: line)
            return MarkdownDocumentParser.parse("", options: options)!
        }
        return model
    }

    private func all(_ nodes: [MarkdownInlineNode]) -> [MarkdownInlineNode] { nodes.flatMap { [$0] + all($0.children) } }

    private func inlines(_ blocks: [MarkdownBlockNode]) -> [MarkdownInlineNode] {
        blocks.flatMap { all($0.inlines) + inlines($0.children) }
    }

    private func nodes(_ model: MarkdownDocumentModel) -> [MarkdownInlineNode] { inlines(model.blocks) }

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

    private func texts(_ node: MarkdownInlineNode) -> String {
        node.children.compactMap { if case .text(let value) = $0.kind { return value } else { return nil } }.joined()
    }

    private func wikis(_ model: MarkdownDocumentModel) -> [MarkdownInlineNode] {
        nodes(model).filter { if case .wikiLink = $0.kind { return true } else { return false } }
    }

    // MARK: - wiki-ссылки и встраивания

    func testWikiLinkInParagraphWithCyrillicAndEmojiUsesUTF16Ranges() {
        let text = "Привет 😀 китайский 汉字 [[Заметка#Раздел|подпись]] конец\r\nвторая [[B]]"
        let model = parse(text)
        let found = wikis(model)
        XCTAssertEqual(found.count, 2)
        guard case .wikiLink(let data) = found[0].kind else { return XCTFail("нет wiki") }
        XCTAssertEqual(data.target, "Заметка")
        XCTAssertEqual(data.heading, "Раздел")
        XCTAssertEqual(data.alias, "подпись")
        XCTAssertEqual(found[0].range, range(of: "[[Заметка#Раздел|подпись]]", in: text))
        XCTAssertEqual(found[0].markerRanges.count >= 2, true)
        XCTAssertEqual(found[1].range, range(of: "[[B]]", in: text))
    }

    func testWikiLinkIsAbsentWhenIncludeIsOffAndInsideCodeLinkAndTable() {
        let text = "Просто [[A]]\n\n`[[B]]`\n\n[текст [[C]]](http://x.y)\n\n| h |\n|---|\n| [[D]] |\n"
        XCTAssertEqual(wikis(parse(text, includes: [.noteEmbeds])).count, 0, "Includes.wikiLinks выключен")
        let found = wikis(parse(text))
        XCTAssertEqual(found.count, 1, "остаётся только ссылка вне кода, ссылки и таблицы")
        XCTAssertEqual(found.first?.range, range(of: "[[A]]", in: text))
    }

    func testWikiLinkInsideStrongKeepsNesting() {
        let text = "**жирный [[Цель]] текст**"
        let model = parse(text)
        let strong = nodes(model).first { $0.kind == .strong }
        XCTAssertNotNil(strong)
        XCTAssertEqual(strong?.children.contains { if case .wikiLink = $0.kind { return true } else { return false } }, true)
    }

    func testInlineEmbedProducesNoteEmbedNodeAndSurroundingText() {
        let text = "Перед ![[Файл#Раздел|вид]] после"
        let model = parse(text)
        let embeds = nodes(model).filter { if case .noteEmbed = $0.kind { return true } else { return false } }
        XCTAssertEqual(embeds.count, 1)
        XCTAssertEqual(embeds.first?.range, range(of: "![[Файл#Раздел|вид]]", in: text))
        XCTAssertEqual(embeds.first?.markerRanges.first?.length, 3)
        XCTAssertEqual(embeds.first?.markerRanges.last?.length, 2)
        XCTAssertEqual(parse(text, includes: [.wikiLinks]).blocks.flatMap(\.inlines).contains { if case .noteEmbed = $0.kind { return true } else { return false } }, false)
    }

    // MARK: - Эмодзи

    func testEmojiShortcodeBecomesNodeButNotInCodeOrEscaped() {
        let text = "Тут :smile: и \\:no: и `:code:` и :plus_one: или :+1:"
        let found = nodes(parse(text)).compactMap { node -> String? in if case .emoji(let name) = node.kind { return name } else { return nil } }
        XCTAssertEqual(found, ["smile", "plus_one", "+1"])
        let none = nodes(parse(text, includes: [.wikiLinks])).filter { if case .emoji = $0.kind { return true } else { return false } }
        XCTAssertTrue(none.isEmpty, "Includes.emoji выключен")
    }

    func testEmojiRangeIsUTF16AfterSupplementaryCharacters() {
        let text = "😀汉 :smile: ок"
        let node = nodes(parse(text)).first { if case .emoji = $0.kind { return true } else { return false } }
        XCTAssertEqual(node?.range, range(of: ":smile:", in: text))
    }

    // MARK: - Подсветка и индексы

    func testHighlightSuperscriptAndSubscriptNodes() {
        let text = "a ==важно== b x^2^ и H~2~O"
        let model = parse(text)
        let list = nodes(model)
        let highlight = list.first { $0.kind == .highlight }
        XCTAssertEqual(highlight?.range, range(of: "==важно==", in: text))
        XCTAssertEqual(highlight.map(texts), "важно")
        XCTAssertEqual(list.first { $0.kind == .superscriptText }?.range, range(of: "^2^", in: text))
        XCTAssertEqual(list.first { $0.kind == .subscriptText }?.range, range(of: "~2~", in: text))
    }

    func testDecorationsAreNotFoundInsideCodeAndLink() {
        let text = "`==a==` и [==b==](http://x.y)\n"
        let list = nodes(parse(text))
        XCTAssertFalse(list.contains { $0.kind == .highlight })
    }

    // MARK: - CriticMarkup (R1–R3)

    func testCriticInsertionInsideParagraphKeepsTextOutsideLiteral() {
        let text = "До {++вставка++} после"
        let model = parse(text)
        let list = nodes(model)
        let critic = list.first { $0.kind == .critic(.insertion) }
        XCTAssertEqual(critic?.range, range(of: "{++вставка++}", in: text))
        XCTAssertEqual(critic?.markerRanges.count, 2)
        XCTAssertEqual(critic.map(texts), "вставка")
        let outside = list.compactMap { node -> String? in if case .text(let value) = node.kind { return value } else { return nil } }
        XCTAssertFalse(outside.contains { $0.contains("{") }, "метки правки не остаются в тексте вне узла: \(outside)")
    }

    func testCriticSubstitutionHasThreeMarkersAndCommentHasNoChildren() {
        let text = "{~~было~>стало~~} и {>>заметка<<}"
        let list = nodes(parse(text))
        let substitution = list.first { $0.kind == .critic(.substitution) }
        XCTAssertEqual(substitution?.markerRanges.count, 3)
        XCTAssertEqual(substitution.map(texts), "былостало")
        let comment = list.first { $0.kind == .critic(.comment) }
        XCTAssertEqual(comment?.range, range(of: "{>>заметка<<}", in: text))
        XCTAssertEqual(comment?.children.count, 0)
    }

    func testCriticIsAbsentWhenIncludeIsOff() {
        let text = "До {++вставка++} после"
        let list = nodes(parse(text, includes: [.wikiLinks]))
        XCTAssertFalse(list.contains { if case .critic = $0.kind { return true } else { return false } })
    }

    func testObsidianInlineCommentInVaultNoteBecomesCommentNode() {
        let text = "Слово %%скрыто%% дальше"
        let list = nodes(parse(text, vault: true))
        let comment = list.first { $0.kind == .comment }
        XCTAssertEqual(comment?.range, range(of: "%%скрыто%%", in: text))
        XCTAssertEqual(comment?.children.count, 0)
        let outside = list.compactMap { node -> String? in if case .text(let value) = node.kind { return value } else { return nil } }
        XCTAssertFalse(outside.joined().contains("скрыто"))
    }

    // MARK: - Позиции и сравнение с рендером

    func testAllInlineRangesStayInsideTextWithCRLFAndNonASCII() {
        let text = "Ёж ==я== 😀 [[Ц]] :smile: {--汉--}\r\nвторая {>>c<<} строка ![[N]]"
        let length = (text as NSString).length
        for node in nodes(parse(text, vault: true)) {
            XCTAssertTrue(node.range.location >= 0 && NSMaxRange(node.range) <= length, "\(node.kind) \(node.range)")
            for marker in node.markerRanges {
                XCTAssertTrue(NSLocationInRange(marker.location, node.range) || marker.location == NSMaxRange(node.range), "\(node.kind) маркер \(marker)")
            }
        }
    }

    func testSmartQuotesInsideWikiTextDoNotBreakLink() {
        let text = "Он сказал \"да\" и [[Цель]] --- конец"
        XCTAssertEqual(wikis(parse(text)).first?.range, range(of: "[[Цель]]", in: text))
    }

    // MARK: - Замечания ревью U2.3b

    private func criticPieces(_ model: MarkdownDocumentModel, _ kind: CriticMarkupKind) -> [MarkdownInlineNode] {
        nodes(model).filter { $0.kind == .critic(kind) }
    }

    private func substring(_ text: String, _ range: NSRange) -> String { (text as NSString).substring(with: range) }

    /// R1: правка, пересекающая границу `**`, режется на два куска, у каждого свои маркеры.
    func testCriticCrossingStrongBoundaryGivesTwoPiecesWithOwnMarkers() {
        let text = "**a {++b** c++}"
        let pieces = criticPieces(parse(text), .insertion)
        XCTAssertEqual(pieces.count, 2)
        guard pieces.count == 2 else { return }
        XCTAssertEqual(pieces[0].range, range(of: "{++b", in: text))
        XCTAssertEqual(pieces[0].markerRanges, [range(of: "{++", in: text)])
        XCTAssertEqual(pieces[1].range, range(of: " c++}", in: text))
        XCTAssertEqual(pieces[1].markerRanges, [range(of: "++}", in: text)])
    }

    /// R1: правка через границу пунктов списка режется по пунктам, у каждого куска свои маркеры.
    func testCriticAcrossListItemsIsCutPerItem() {
        let text = "- {++Привет\n- 汉字++}"
        let pieces = criticPieces(parse(text), .insertion)
        XCTAssertEqual(pieces.count, 2)
        guard pieces.count == 2 else { return }
        XCTAssertEqual(pieces[0].range, range(of: "{++Привет", in: text))
        XCTAssertEqual(pieces[0].markerRanges, [range(of: "{++", in: text)])
        XCTAssertEqual(pieces[1].range, range(of: "汉字++}", in: text))
        XCTAssertEqual(pieces[1].markerRanges, [range(of: "++}", in: text)])
    }

    /// Пустая строка обрывает правку (как в `CriticMarkupService`): узла `.critic` нет, текст остаётся литералом.
    func testCriticDoesNotCrossBlankLine() {
        let list = nodes(parse("{++Привет\n\n汉字++}"))
        XCTAssertFalse(list.contains { if case .critic = $0.kind { return true } else { return false } })
    }

    /// Дети слитой пары HTML не получают второй `.critic`: один узел снаружи, `.keyboard` внутри.
    func testCriticAroundKbdPairIsNotDuplicatedInsideIt() {
        let text = "{++a <kbd>b</kbd> c++}"
        let pieces = criticPieces(parse(text), .insertion)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.children.contains { $0.kind == .keyboard }, true)
        XCTAssertEqual(nodes(parse(text)).filter { $0.kind == .keyboard }.first?.children.contains { if case .critic = $0.kind { return true } else { return false } }, false)
    }

    /// Неподтверждённый тег HTML гасит эмодзи и wiki-ссылки во всём тексте родителя; пара `<u>` — нет.
    func testUnconfirmedInlineHTMLSuppressesEmojiAndWikiOfWholeParent() {
        let suppressed = parse("Текст <kbd>Ctrl</kbd> и :smile: и [[A]]")
        XCTAssertFalse(nodes(suppressed).contains { if case .emoji = $0.kind { return true } else { return false } })
        XCTAssertTrue(wikis(suppressed).isEmpty)
        let allowed = parse("<u>x</u> и :smile: и [[A]]")
        XCTAssertTrue(nodes(allowed).contains { if case .emoji = $0.kind { return true } else { return false } })
        XCTAssertEqual(wikis(allowed).count, 1)
    }

    func testEmbedInsideHTMLTagAndWithMarkdownInTargetFollowsRenderer() {
        for (text, target) in [("<b>![[pic.png]]</b>", "pic.png"), ("до ![[a*b*c]] после", "a*b*c"), ("до <i>![[x_y_z.png]]</i> после", "x_y_z.png")] {
            let embeds = nodes(parse(text)).compactMap { node -> MarkdownBlockNode.NoteEmbed? in if case .noteEmbed(let data) = node.kind { return data } else { return nil } }
            XCTAssertEqual(embeds.map(\.target), [target], text)
        }
        // Отдельный абзац — блочное встраивание (R6), не строчное.
        let block = parse("![[a*b*c]]")
        XCTAssertTrue(block.blocks.contains { if case .noteEmbed = $0.kind { return true } else { return false } })
    }

    func testSubscriptSurvivesEmojiInsideIt() {
        let text = "H~2:a:b~O"
        let list = nodes(parse(text))
        XCTAssertEqual(list.first { $0.kind == .subscriptText }?.range, range(of: "~2:a:b~", in: text))
    }

    func testDecorationsAreNotFoundInLinkTableFootnoteAndStrikethrough() {
        let samples = ["[^x^](http://u.v)", "[~x~](http://u.v)", "| h |\n|---|\n| ^x^ ~y~ ==z== |\n", "т[^1]\n\n[^1]: a ^x^ ==z==", "~~^x^ ==z==~~"]
        for text in samples {
            let list = nodes(parse(text))
            XCTAssertFalse(list.contains { $0.kind == .superscriptText || $0.kind == .subscriptText || $0.kind == .highlight }, "узлы оформления в \(text.debugDescription)")
        }
    }

    /// Диапазоны и маркеры строчных узлов совпадают с исходником при `\r\n` и не-ASCII.
    func testInlineRangesAndMarkersMatchSourceWithCRLFAndNonASCII() {
        let text = "Ёж ==я== 😀 [[Ц|汉]] :smile: ![[N]]\r\nвторая {++вставка++} строка ^2^"
        let model = parse(text)
        var seen = Set<String>()
        for node in nodes(model) {
            switch node.kind {
            case .highlight: XCTAssertEqual(node.markerRanges.map { substring(text, $0) }, ["==", "=="]); seen.insert("highlight")
            case .wikiLink: XCTAssertEqual(node.markerRanges.map { substring(text, $0) }, ["[[Ц|", "]]"]); seen.insert("wiki")
            case .emoji: XCTAssertEqual(substring(text, node.range), ":smile:"); seen.insert("emoji")
            case .noteEmbed: XCTAssertEqual(substring(text, node.range), "![[N]]"); seen.insert("embed")
            case .critic: XCTAssertEqual(node.markerRanges.map { substring(text, $0) }, ["{++", "++}"]); seen.insert("critic")
            case .superscriptText: XCTAssertEqual(substring(text, node.range), "^2^"); seen.insert("sup")
            default: break
            }
        }
        XCTAssertEqual(seen, ["highlight", "wiki", "emoji", "embed", "critic", "sup"])
    }

    func testCancellationReturnsNil() {
        let options = MarkdownDocumentModel.Options(syntax: MarkdownSyntaxOptions(), includes: [.wikiLinks, .noteEmbeds, .criticMarkup, .emoji],
                                                    isVaultNote: false, detectsFrontMatter: true)
        XCTAssertNil(MarkdownDocumentParser.parse("a [[B]] :smile: ==c==", options: options, isCancelled: { true }))
    }

    // MARK: - Контракт U3.3 (R2, R3, R7) и дополнения U3.1 (U2.3d)

    private func wikiData(_ node: MarkdownInlineNode?) -> MarkdownInlineNode.WikiLink? {
        if let node, case .wikiLink(let data) = node.kind { return data }
        return nil
    }

    /// R7: поля `target/heading/alias/displayRange` для всех форм записи; `displayRange` — по тексту ссылки в UTF-16.
    func testWikiLinkFieldsFollowContractR7ForAllForms() {
        let text = "😀 [[Цель]] и [[ Заметка #Раздел 汉字 | подпись 😀 ]]\r\nи [[Файл#Раздел]] и [[Цель|alias]]"
        let found = wikis(parse(text))
        XCTAssertEqual(found.count, 4)
        guard found.count == 4 else { return }
        let plain = wikiData(found[0]), full = wikiData(found[1]), heading = wikiData(found[2]), alias = wikiData(found[3])
        XCTAssertEqual(plain?.target, "Цель")
        XCTAssertNil(plain?.heading)
        XCTAssertNil(plain?.alias)
        XCTAssertEqual(plain?.displayRange, range(of: "Цель", in: text))
        XCTAssertEqual(full?.target, "Заметка")
        XCTAssertEqual(full?.heading, "Раздел 汉字")
        XCTAssertEqual(full?.alias, "подпись 😀")
        XCTAssertEqual(full?.displayRange, range(of: "подпись 😀", in: text))
        XCTAssertEqual(heading?.target, "Файл")
        XCTAssertEqual(heading?.heading, "Раздел")
        XCTAssertNil(heading?.alias)
        XCTAssertEqual(heading?.displayRange, range(of: "Файл#Раздел", in: text), "без псевдонима показывается вся запись до `]]`")
        XCTAssertEqual(alias?.alias, "alias")
        XCTAssertEqual(alias?.displayRange, range(of: "alias", in: text))
        // Маркеры — те же, что у MarkdownWikiLink: до и после отображаемого текста.
        for node in found {
            guard let data = wikiData(node) else { continue }
            XCTAssertEqual(node.markerRanges.count, 2)
            XCTAssertEqual(node.markerRanges.first, NSRange(location: node.range.location, length: data.displayRange.location - node.range.location))
            XCTAssertEqual(node.markerRanges.last.map(NSMaxRange), NSMaxRange(node.range))
            XCTAssertEqual(node.markerRanges.last?.location, NSMaxRange(data.displayRange))
        }
    }

    /// R3: у подмены три маркера, а «было» и «стало» делятся по `markerRanges[1].upperBound`; текст берётся из исходника в UTF-16.
    func testCriticSubstitutionChildrenSplitByMiddleMarker() {
        let text = "Раз 😀 {~~было *курсив* 漢字~>стало **жирно** 😀~~}\r\nдва"
        guard let node = criticPieces(parse(text), .substitution).first else { return XCTFail("нет подмены") }
        XCTAssertEqual(criticPieces(parse(text), .substitution).count, 1)
        XCTAssertEqual(node.range, range(of: "{~~было *курсив* 漢字~>стало **жирно** 😀~~}", in: text))
        XCTAssertEqual(node.markerRanges, [range(of: "{~~", in: text), range(of: "~>", in: text), range(of: "~~}", in: text)])
        guard node.markerRanges.count == 3 else { return }
        let split = NSMaxRange(node.markerRanges[1])
        let before = node.children.filter { $0.range.location < split }
        let after = node.children.filter { $0.range.location >= split }
        XCTAssertEqual(before.count + after.count, node.children.count, "каждый ребёнок лежит по одну сторону от `~>`")
        XCTAssertTrue(before.allSatisfy { NSMaxRange($0.range) <= node.markerRanges[1].location }, "«было» целиком до `~>`")
        XCTAssertTrue(after.allSatisfy { NSMaxRange($0.range) <= node.markerRanges[2].location }, "«стало» целиком до `~~}`")
        XCTAssertEqual(before.compactMap { n -> String? in if case .text(let value) = n.kind { return value } else { return nil } }.joined(), "было  漢字")
        XCTAssertEqual(before.contains { $0.kind == .emphasis }, true)
        XCTAssertEqual(after.contains { $0.kind == .strong }, true)
        XCTAssertEqual(after.compactMap { n -> String? in if case .text(let value) = n.kind { return value } else { return nil } }.joined(), "стало  😀")
    }

    /// R2: у `.critic(.comment)` нет детей, а текст берётся срезом исходника между маркерами (в т. ч. с `\r\n`, кириллицей, CJK, эмодзи).
    func testCriticCommentTextIsSourceSliceBetweenMarkers() {
        let text = "До {>>комментарий 漢字 😀\r\nвторая строка<<} после"
        let comments = criticPieces(parse(text), .comment)
        XCTAssertEqual(comments.count, 1)
        guard let comment = comments.first else { return }
        XCTAssertTrue(comment.children.isEmpty)
        XCTAssertEqual(comment.markerRanges, [range(of: "{>>", in: text), range(of: "<<}", in: text)])
        guard comment.markerRanges.count == 2 else { return }
        let slice = NSRange(location: NSMaxRange(comment.markerRanges[0]), length: comment.markerRanges[1].location - NSMaxRange(comment.markerRanges[0]))
        XCTAssertEqual(substring(text, slice), "комментарий 漢字 😀\r\nвторая строка")
        XCTAssertEqual(comment.range, range(of: "{>>комментарий 漢字 😀\r\nвторая строка<<}", in: text))
    }

    /// Дополнение U3.1: модель оставляет текстовые узлы как есть, не склеивая их с соседями: эмодзи делит текст на три узла,
    /// а неизвестный шорткод остаётся внутри одного `.text` (от этого зависит число `<span data-lac-whitespace>`).
    func testTextNodesAreNotMergedAroundEmoji() {
        let text = "Привет 😀 汉字 :smile: мир :нет_такого: конец"
        let kinds = nodes(parse(text)).map(\.kind)
        XCTAssertEqual(kinds, [.text("Привет 😀 汉字 "), .emoji(name: "smile"), .text(" мир :нет_такого: конец")])
        let list = nodes(parse(text))
        XCTAssertEqual(list.map(\.range), [range(of: "Привет 😀 汉字 ", in: text), range(of: ":smile:", in: text), range(of: " мир :нет_такого: конец", in: text)])
    }

    /// Тот же принцип для wiki-ссылки: текст до и после — отдельные соседние узлы, диапазоны соседей не пересекаются.
    func testTextNodesAroundWikiLinkAreSeparateAndDoNotOverlap() {
        let text = "до 😀 [[Цель]] после 汉字"
        let list = nodes(parse(text))
        XCTAssertEqual(list.map(\.range), [range(of: "до 😀 ", in: text), range(of: "[[Цель]]", in: text), range(of: " после 汉字", in: text)])
        XCTAssertEqual(list.compactMap { node -> String? in if case .text(let value) = node.kind { return value } else { return nil } }, ["до 😀 ", " после 汉字"])
    }

    /// «Умные» замены и сущности неделимы: у границы среза они целиком достаются одному соседу, текст не теряется и не дублируется.
    func testSmartReplacementsAndEntitiesNextToSliceBordersStayWholeWithoutOverlap() {
        let text = "\"да\" -- :smile: &amp; [[A]]"
        let list = nodes(parse(text))
        XCTAssertEqual(list.map(\.kind), [.text("“да” – "), .emoji(name: "smile"), .text(" & ")] + list.dropFirst(3).map(\.kind))
        XCTAssertEqual(list.last?.range, range(of: "[[A]]", in: text))
        XCTAssertEqual(list[0].range, range(of: "\"да\" -- ", in: text))
        XCTAssertEqual(list[1].range, range(of: ":smile:", in: text))
        XCTAssertEqual(list[2].range, range(of: " &amp; ", in: text))
        for (left, right) in zip(list, list.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(left.range), right.range.location, "узлы пересекаются: \(left.kind) и \(right.kind)")
        }
    }

    /// Срез начинается с начала длинного куска текста: правка вырезается точно, соседи не склеиваются и не пересекаются.
    func testCriticAtStartOfLongTextSplitsNeighboursWithoutOverlap() {
        let text = "{++Привет++} длинный текст 汉字 😀 до конца строки"
        let list = parse(text).blocks.flatMap(\.inlines)
        XCTAssertEqual(list.map(\.range), [range(of: "{++Привет++}", in: text), range(of: " длинный текст 汉字 😀 до конца строки", in: text)])
        XCTAssertEqual(list.first?.kind, .critic(.insertion))
        XCTAssertEqual(list.last?.kind, .text(" длинный текст 汉字 😀 до конца строки"))
        let middle = "Начало длинного текста {--цель--} и хвост 汉字"
        let parts = parse(middle).blocks.flatMap(\.inlines)
        XCTAssertEqual(parts.map(\.range), [range(of: "Начало длинного текста ", in: middle), range(of: "{--цель--}", in: middle), range(of: " и хвост 汉字", in: middle)])
    }

    /// Абзац с определениями ссылок и табом в тексте: у cmark нет позиций строчных узлов, выделение, ссылка и текст за ними
    /// находят границы по маркерам и литералам (иначе копирование с оформлением получало `nil`).
    func testEmphasisAndLinkAfterReferenceDefinitionsWithTabsKeepExactRanges() {
        for newline in ["\n", "\r", "\r\n"] {
            let text = ["- [a]: /x", "  [b]: /y", "  中文\t**bold**\t[link][b] $x$"].joined(separator: newline)
            let list = nodes(parse(text))
            XCTAssertTrue(list.allSatisfy { !$0.isUnreliable }, "все узлы надёжны, перевод строки \(newline.debugDescription)")
            let strong = list.first { $0.kind == .strong }
            XCTAssertEqual(strong?.range, range(of: "**bold**", in: text))
            XCTAssertEqual(strong?.children.first?.range, range(of: "bold", in: text))
            let link = list.first { if case .link = $0.kind { return true } else { return false } }
            XCTAssertEqual(link?.range, range(of: "[link][b]", in: text))
            XCTAssertEqual(link?.children.first?.range, range(of: "link", in: text))
        }
    }

    /// Абзац на строке с табом (spec 9) и многострочная ссылка с заголовком (spec 518): границы подтверждаются по тексту, узлы надёжны.
    func testTabbedParagraphAndMultilineLinkKeepExactRanges() {
        for newline in ["\n", "\r\n"] {
            let tabbed = [" - foo 😀", "   - bar", "\t - 😀baz 中文"].joined(separator: newline) + newline
            let paragraphs = parse(tabbed).blocks.flatMap { collectParagraphs($0) }
            XCTAssertTrue(paragraphs.allSatisfy { !$0.isUnreliable }, "абзацы надёжны, перевод строки \(newline.debugDescription)")
            XCTAssertEqual(paragraphs.first?.range, range(of: "foo 😀", in: tabbed))
            XCTAssertEqual(paragraphs.last?.range, range(of: "😀baz 中文", in: tabbed))
            let link = ["[link](   /uri", "  \"title 中文\"  )"].joined(separator: newline) + newline
            let model = parse(link)
            XCTAssertTrue(model.blocks.allSatisfy { !$0.isUnreliable }, "ссылка надёжна, перевод строки \(newline.debugDescription)")
            let node = nodes(model).first { if case .link = $0.kind { return true } else { return false } }
            XCTAssertEqual(node?.range, NSRange(location: 0, length: (link as NSString).length - newline.utf16.count))
        }
    }

    private func collectParagraphs(_ block: MarkdownBlockNode) -> [MarkdownBlockNode] {
        (block.kind == .paragraph ? [block] : []) + block.children.flatMap { collectParagraphs($0) }
    }

    /// Выделение после определений ссылок: маркер может стоять первым на строке, после переноса, с `_`, вложенно, рядом с эмодзи и ссылкой.
    func testEmphasisAfterReferenceDefinitionsFindsMarkersInAllPositions() {
        func isStrong(_ node: MarkdownInlineNode) -> Bool { node.kind == .strong }
        func isEmphasis(_ node: MarkdownInlineNode) -> Bool { node.kind == .emphasis }
        // (исходник, [(часть исходника с выделением, проверка узла)]); все узлы, кроме отмеченных, должны быть надёжными.
        let cases: [(String, [(String, (MarkdownInlineNode) -> Bool)])] = [
            ("- [a]: /x\n  **bold**\tx", [("**bold**", isStrong)]),
            ("- [a]: /x\n  text\n  **b**\tz", [("**b**", isStrong)]),
            ("- [a]: /x\n  中文\t_it_ __st__ tail", [("_it_", isEmphasis), ("__st__", isStrong)]),
            ("- [a]: /x\n  q\t***a*** z", [("***a***", isEmphasis), ("**a**", isStrong)]),
            ("- [a]: /x\n  q\t*a **b*** z", [("*a **b***", isEmphasis), ("**b**", isStrong)]),
            ("- [a]: /x\n  :smile: 😀\t**b** 中", [("**b**", isStrong)]),
            ("- [a]: /x\n  q\t*[link][a]* z", [("*[link][a]*", isEmphasis), ("[link][a]", { if case .link = $0.kind { return true } else { return false } })]),
        ]
        for newline in ["\n", "\r", "\r\n"] {
            for (template, expected) in cases {
                let text = template.replacingOccurrences(of: "\n", with: newline)
                let list = nodes(parse(text))
                let label = "\(template.debugDescription), перевод строки \(newline.debugDescription)"
                XCTAssertTrue(list.allSatisfy { !$0.isUnreliable }, "все узлы надёжны: \(label)")
                for (part, check) in expected {
                    XCTAssertTrue(list.contains { check($0) && $0.range == range(of: part, in: text) }, "узел «\(part)»: \(label)")
                }
            }
        }
        // Сущность `&amp;` внутри выделения: литерал `a&` занимает `a&amp;` целиком, выделение подтверждено.
        let entity = "- [a]: /x\n  q\t*a&amp;* z"
        XCTAssertTrue(nodes(parse(entity)).contains { $0.kind == .emphasis && !$0.isUnreliable && $0.range == NSRange(location: 14, length: 8) })
        // Незакрытый маркер выделением не становится.
        XCTAssertFalse(nodes(parse("- [a]: /x\n  q\t*open **b**")).contains { $0.kind == .emphasis })
    }
}

