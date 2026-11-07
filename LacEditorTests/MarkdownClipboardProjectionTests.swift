import Foundation
import XCTest
@testable import LacEditor

/// Каркас проектора выделения на модели (U4.5.1): вход, корневой цикл, сверка покрытия, запись текста.
/// Ожидания совпадают с `MarkdownClipboardCopyTests`: `text`, `html`, `runs`.
final class MarkdownClipboardProjectionTests: XCTestCase {
    private func project(_ source: String, _ selection: NSRange, syntax: MarkdownSyntaxOptions = .init()) -> MarkdownClipboardCopyService.Fragment? {
        MarkdownClipboardCopyService.project(source, selection: selection, syntax: syntax)
    }

    private func model(of source: String, includes: MarkdownDocumentModel.Includes = [.emoji], vault: Bool = false) -> MarkdownDocumentModel? {
        MarkdownDocumentParser.parse(source, options: .init(syntax: .init(), includes: includes, isVaultNote: vault, detectsFrontMatter: true))
    }

    private func whole(_ source: String) -> NSRange { NSRange(location: 0, length: (source as NSString).length) }

    func testEmptySelectionAndOutOfRangeSelectionGiveNil() {
        let source = "Привет мир"
        XCTAssertNil(project(source, NSRange(location: 3, length: 0)), "пустое выделение")
        XCTAssertNil(project(source, NSRange(location: NSNotFound, length: 1)), "нет позиции")
        XCTAssertNil(project(source, NSRange(location: 5, length: 100)), "выделение за концом текста")
        XCTAssertNil(project("", NSRange(location: 0, length: 0)), "пустой текст")
    }

    func testSelectionInsideOneParagraphKeepsTextHTMLAndRuns() throws {
        // Кириллица, CJK и эмодзи (суррогатная пара): позиции считаются в UTF-16.
        for source in ["Привет мир", "中文 текст", "эмодзи 😀 тут", "a < b & c > d"] {
            let raw = source as NSString
            let whole = try XCTUnwrap(project(source, NSRange(location: 0, length: raw.length)), source)
            XCTAssertEqual(whole.text, source, source)
            let escaped = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            XCTAssertEqual(whole.html, escaped, source)
            XCTAssertEqual(whole.runs.map(\.range), [NSRange(location: 0, length: raw.length)], source)
            XCTAssertFalse(whole.hasUnverifiedHTMLBlocks)
        }
        let source = "Привет 中文😀 мир"
        let part = (source as NSString).range(of: "中文😀")
        let partial = try XCTUnwrap(project(source, part))
        XCTAssertEqual(partial.text, "中文😀")
        XCTAssertEqual(partial.html, "中文😀")
        XCTAssertEqual(partial.runs.map(\.range), [NSRange(location: 0, length: 4)])
        XCTAssertEqual(partial.structuralParts.map(\.text), ["中文😀"])
    }

    func testLineBreaksInParagraphAndBetweenParagraphsBecomeBreaks() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let oneParagraph = "строка 一" + newline + "вторая 😀"
            let raw = oneParagraph as NSString
            let copy = try XCTUnwrap(project(oneParagraph, NSRange(location: 0, length: raw.length)), "абзац, перенос \(newline.debugDescription)")
            XCTAssertEqual(copy.text, "строка 一\nвторая 😀", "перенос \(newline.debugDescription)")
            XCTAssertEqual(copy.html, "строка 一<br>вторая 😀", "перенос \(newline.debugDescription)")
            XCTAssertEqual(copy.structuralParts.filter { $0.kind == .lineBreak }.count, 1)
            let twoParagraphs = "первый" + newline + newline + "второй 中"
            let twoRaw = twoParagraphs as NSString
            let two = try XCTUnwrap(project(twoParagraphs, NSRange(location: 0, length: twoRaw.length)), "два абзаца, перенос \(newline.debugDescription)")
            XCTAssertEqual(two.text, "первый\n\nвторой 中", "перенос \(newline.debugDescription)")
            XCTAssertEqual(two.html, "первый<br><br>второй 中", "перенос \(newline.debugDescription)")
        }
    }

    func testSelectionBoundaryInsideSurrogatePairGivesNil() {
        let source = "a😀b"
        XCTAssertNil(project(source, NSRange(location: 2, length: 1)), "начало между половинами пары")
        XCTAssertNil(project(source, NSRange(location: 0, length: 2)), "конец между половинами пары")
        XCTAssertEqual(project(source, NSRange(location: 1, length: 2))?.text, "😀")
    }

    func testSelectionInsideLateBlockDoesNotNeedEarlierBlocks() throws {
        // Выделение в последнем абзаце длинного текста: блоки до него пропускаются бинарным поиском.
        let blocks = (0..<200).map { "абзац \($0) 😀" }
        let source = blocks.joined(separator: "\r\n\r\n")
        let raw = source as NSString
        let selection = raw.range(of: "абзац 199")
        let copy = try XCTUnwrap(project(source, selection))
        XCTAssertEqual(copy.text, "абзац 199")
        XCTAssertEqual(copy.html, "абзац 199")
    }

    // Front matter не блок: от начала текста до абзаца идёт один зазор
    // "---\r\ntitle: 中文😀\r\n---\r\n\r\n". emitUnrepresented складывает его построчно как есть (с \r\n), видит
    // переводы строк (multiline) и пишет `<pre>`, а внутрь `emit` с code-стилем: html `<code>…</code>`, один run с code.
    // Затем абзац "текст": lastEnd совпал с его началом, переводов между ними не добавляется.
    func testFrontMatterWithBlankLinesIsOneGapPreBlock() throws {
        let source = "---\r\ntitle: 中文😀\r\n---\r\n\r\nтекст"
        let gap = "---\r\ntitle: 中文😀\r\n---\r\n\r\n"
        let copy = try XCTUnwrap(project(source, whole(source)))
        XCTAssertEqual(copy.text, gap + "текст")
        XCTAssertEqual(copy.html, "<pre><code>" + gap + "</code></pre>текст")
        XCTAssertEqual(copy.runs.map(\.range), [NSRange(location: 0, length: (gap as NSString).length),
                                                NSRange(location: (gap as NSString).length, length: 5)])
        XCTAssertEqual(copy.runs.map(\.code), [true, false])
        XCTAssertEqual(copy.structuralParts.map(\.text), [gap, "текст"])
    }

    func testBlankLinesBetweenBlocksAndAtEndOfText() throws {
        let source = "первый\n\n\nвторой"
        let copy = try XCTUnwrap(project(source, whole(source)))
        XCTAssertEqual(copy.text, "первый\n\n\nвторой")
        XCTAssertEqual(copy.html, "первый<br><br><br>второй")
        let onlyBlank = try XCTUnwrap(project(source, NSRange(location: 6, length: 3)))
        XCTAssertEqual(onlyBlank.text, "\n\n\n")
        XCTAssertEqual(onlyBlank.html, "<br><br><br>")
        // Конец файла без \n и с \n.
        let noEnd = "а\n\nб"
        XCTAssertEqual(project(noEnd, whole(noEnd))?.text, "а\n\nб")
        let withEnd = "а\n\nб\n"
        let ended = try XCTUnwrap(project(withEnd, whole(withEnd)))
        XCTAssertEqual(ended.text, "а\n\nб\n")
        XCTAssertEqual(ended.html, "а<br><br>б<br>")
    }

    func testSelectionExactlyOnBlockBoundaries() throws {
        let source = "первый\n\nвторой 中"
        let firstEnd = 6, secondStart = 8
        XCTAssertEqual(project(source, NSRange(location: 0, length: firstEnd))?.html, "первый")
        XCTAssertEqual(project(source, NSRange(location: secondStart, length: (source as NSString).length - secondStart))?.html, "второй 中")
        let withGap = try XCTUnwrap(project(source, NSRange(location: 0, length: secondStart)))
        XCTAssertEqual(withGap.text, "первый\n\n")
        XCTAssertEqual(withGap.html, "первый<br><br>")
        XCTAssertEqual(project(source, NSRange(location: firstEnd, length: 2))?.text, "\n\n")
    }

    func testSoftBreakBecomesSpaceWhenEditingSoftBreaksAreOff() throws {
        let source = "а\nб"
        let syntax = MarkdownSyntaxOptions(preserveEditingSoftBreaks: false)
        let copy = try XCTUnwrap(project(source, whole(source), syntax: syntax))
        XCTAssertEqual(copy.text, "а б")
        XCTAssertEqual(copy.html, "а б")
        XCTAssertEqual(project(source, whole(source))?.html, "а<br>б", "по умолчанию перенос сохраняется")
    }

    func testEscapeCoversQuoteAmpersandAndAngleBrackets() {
        XCTAssertEqual(MarkdownClipboardCopyService.ProjectionState.escape("a\"b<c>&d'e"), "a&quot;b&lt;c&gt;&amp;d'e")
    }

    func testCancelledTaskGivesNil() async throws {
        let source = "Привет 中文😀 мир\n\nвторой"
        let task = Task.detached { () -> Bool in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            let range = NSRange(location: 0, length: (source as NSString).length)
            return MarkdownClipboardCopyService.project(source, selection: range) == nil
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result, "отменённая задача даёт nil")
    }

    // Front matter не блок: всё от начала текста до абзаца — один зазор. emitUnrepresented берёт из зазора
    // только выделенную часть, строки добавляются от начала выделения (contentStart = max(position, начало строки)).
    func testFrontMatterSelectionStartingInsideAndEntirelyInside() throws {
        let source = "---\r\ntitle: 中文😀\r\n---\r\n\r\nтекст"
        let raw = source as NSString
        let start = raw.range(of: "itle").location
        let tail = raw.substring(from: start)
        let fromInside = try XCTUnwrap(project(source, NSRange(location: start, length: raw.length - start)))
        XCTAssertEqual(fromInside.text, tail)
        XCTAssertEqual(fromInside.html, "<pre><code>" + String(tail.dropLast(5)) + "</code></pre>текст")
        // Целиком внутри одной строки: переводов строк нет — без <pre>, только <code>.
        let inner = raw.range(of: "title: 中文😀")
        let inside = try XCTUnwrap(project(source, inner))
        XCTAssertEqual(inside.text, "title: 中文😀")
        XCTAssertEqual(inside.html, "<code>title: 中文😀</code>")
        XCTAssertEqual(inside.runs.map(\.code), [true])
    }

    // `[toc]` — абзац из одного текстового узла, копируется как текст; <br><br> — зазоры между абзацами.
    func testTableOfContentsMarkerIsCopiedAsPlainParagraph() throws {
        let source = "Привет\n\n[toc]\n\nконец"
        let copy = try XCTUnwrap(project(source, whole(source)))
        XCTAssertEqual(copy.text, "Привет\n\n[toc]\n\nконец")
        XCTAssertEqual(copy.html, "Привет<br><br>[toc]<br><br>конец")
        let alone = (source as NSString).range(of: "[toc]")
        XCTAssertEqual(project(source, alone)?.text, "[toc]")
    }

    // emit: :smile: в тексте заменяется на эмодзи из каталога (кандидаты берутся из модели).
    func testEmojiShortcodeIsReplacedInText() throws {
        let source = "a :smile: b"
        let copy = try XCTUnwrap(project(source, whole(source)))
        XCTAssertEqual(copy.text, "a 😄 b")
        XCTAssertEqual(copy.html, "a 😄 b")
    }

    // emit: подряд идущие пробелы схлопываются, при preserveEditingWhitespace — остаются в span с break-spaces.
    func testRepeatedSpacesCollapseUnlessEditingWhitespaceIsPreserved() throws {
        let source = "a  b"
        let collapsed = try XCTUnwrap(project(source, whole(source)))
        XCTAssertEqual(collapsed.text, "a b")
        XCTAssertEqual(collapsed.html, "a b")
        XCTAssertEqual(collapsed.runs.map(\.range), [NSRange(location: 0, length: 3)])
        let preserved = try XCTUnwrap(project(source, whole(source), syntax: .init(preserveEditingWhitespace: true)))
        XCTAssertEqual(preserved.text, "a  b")
        XCTAssertEqual(preserved.html, "<span style=\"white-space:break-spaces\">a  b</span>")
    }

    private func makeState(_ source: String, selection: NSRange) throws -> (MarkdownClipboardCopyService.ProjectionState, MarkdownDocumentModel) {
        let parsed = try XCTUnwrap(model(of: source))
        let candidates = (parsed.emoji?.candidates ?? []).filter { NSIntersectionRange($0.range, selection).length > 0 }
        let resolved = candidates.isEmpty ? [:] : try EmojiShortcodeResolver.resolve(candidates.map(\.name), isCancelled: { false })
        let state = MarkdownClipboardCopyService.ProjectionState(
            markdown: source, selection: selection, includeImages: false, documentURL: nil, allowRemoteImages: false,
            syntax: .init(), detailsOpenOverrides: [:], emojiCandidates: candidates, emoji: resolved, model: parsed)
        return (state, parsed)
    }

    // Каталог формул: порядок исходника, таблица/цитата/сноска/блок `$$` попадают, код, <template> и <script> — нет.
    func testMathCatalogCollectsFormulasInSourceOrderAndSkipsCodeAndRawContexts() throws {
        let source = "Первая $a$ и `$code$` 中文\n\n| x | y |\n|---|---|\n| $t$ | 😀 |\n\n> цитата $q$\n\n$$\nb = 1\n$$\n\n```\n$fence$\n```\n\n"
            + "после $z$ <template>$tpl$</template> и <script>$scr$</script> $w$\n\nсноска[^1]\n\n[^1]: тут $f$\n"
        let (state, _) = try makeState(source, selection: whole(source))
        XCTAssertTrue(state.buildMathCatalog())
        let sources = state.mathExpressions.map(\.source)
        for expected in ["a", "t", "q", "z", "w", "f"] { XCTAssertTrue(sources.contains(expected), "формула \(expected) должна быть в каталоге: \(sources)") }
        for forbidden in ["code", "fence", "tpl", "scr"] { XCTAssertFalse(sources.contains(forbidden), "формула \(forbidden) не должна быть в каталоге: \(sources)") }
        XCTAssertTrue(state.mathExpressions.contains { $0.display }, "блок $$ должен быть в каталоге")
        let locations = state.mathExpressions.map(\.range.location)
        XCTAssertEqual(locations, locations.sorted(), "порядок — по исходнику")
        XCTAssertTrue(state.mathContextValid)
    }

    // Общий `projectInlines`: соседние текст и эмодзи одного списка дают один run и один кусок HTML.
    func testAdjacentTextAndEmojiNodesAreEmittedAsOneRun() throws {
        let source = "**a :smile: b**"
        let inner = NSRange(location: 2, length: (source as NSString).length - 4)
        let (state, parsed) = try makeState(source, selection: inner)
        guard case .paragraph = parsed.blocks.first?.kind, let strong = parsed.blocks.first?.inlines.first,
              case .strong = strong.kind else { return XCTFail("ожидался абзац со strong: \(parsed.blocks)") }
        XCTAssertEqual(strong.children.count, 3, "текст, эмодзи, текст")
        state.projectInlines(strong.children, style: .init())
        XCTAssertFalse(state.invalid)
        XCTAssertEqual(state.html, "a 😄 b")
        XCTAssertEqual(state.runs.count, 1, "один run на склеенный текст")
        XCTAssertEqual(state.runs.first?.range, NSRange(location: 0, length: ("a 😄 b" as NSString).length))
    }

    // Выделение, обрывающее шорткод посередине, копирование отвергает.
    func testPartiallySelectedEmojiShortcodeGivesNil() {
        let source = "a :smile: b"
        XCTAssertNil(project(source, NSRange(location: 0, length: 6)), "обрыв внутри :smile:")
        XCTAssertNil(project(source, NSRange(location: 4, length: 7)), "начало внутри :smile:")
        XCTAssertNotNil(project(source, NSRange(location: 2, length: 7)), "целый шорткод")
    }

    // `[toc]` с хвостовыми пробелами и переводами строк: копируются ровно пять символов маркера.
    func testTableOfContentsMarkerWithTrailingSpacesAndCRLF() throws {
        let source = "Привет\r\n\r\n[toc]  \r\n\r\nконец"
        let marker = (source as NSString).range(of: "[toc]")
        XCTAssertEqual(project(source, marker)?.text, "[toc]")
        let all = try XCTUnwrap(project(source, whole(source)))
        XCTAssertTrue(all.text.contains("[toc]"), all.text)
        XCTAssertTrue(all.text.hasPrefix("Привет") && all.text.hasSuffix("конец"), all.text)
    }
}
