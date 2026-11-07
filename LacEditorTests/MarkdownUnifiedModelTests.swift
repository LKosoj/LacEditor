import XCTest
@testable import LacEditor

/// Сквозные проверки единого слоя Markdown (U9.2): одна модель на версию текста, склейка равна полному разбору,
/// `data-sourcepos` указывает на строку исходника. AppKit не нужен; замыкание `renderer` у `MarkdownRenderActor`
/// (WebKit) проверяет `MarkdownPreviewTests.testRenderActorPassesModelToRenderer`.
final class MarkdownUnifiedModelTests: XCTestCase {
    // MARK: Одна модель на версию

    private let modelOptions = MarkdownDocumentModel.Options(syntax: .init(), includes: [.emoji], isVaultNote: false, detectsFrontMatter: true)

    private func parseModel(_ text: String) throws -> MarkdownDocumentModel {
        try XCTUnwrap(MarkdownDocumentParser.parse(text, options: modelOptions, isCancelled: { false }))
    }

    /// Модель, установленная в документ, выдаётся по текущей версии одной и той же. Здесь проверяются решение `accepts`
    /// и равенство вывода из модели и из строки; саму передачу модели в замыкание `renderer` проверяет
    /// `MarkdownPreviewTests.testRenderActorPassesModelToRenderer` (на Mac). Правка текста сбрасывает слот, а старая модель к новому тексту не подходит.
    func testModelIsStableForRevisionAcceptedByRulesAndDroppedByEdit() throws {
        let source = "# Привет 😀\r\n\r\nпара 中文 *курсив*\r\n\r\n- а\r\n- б\r\n"
        let document = EditorDocument(text: source, language: .markdown)
        let model = try parseModel(source)
        XCTAssertTrue(document.installMarkdownModel(model, source: source))
        let first = try XCTUnwrap(document.markdownModel(forRevision: document.textRevision))
        let second = try XCTUnwrap(document.markdownModel(forRevision: document.textRevision))
        XCTAssertEqual(first, second, "два запроса одной версии дают равные модели")
        XCTAssertEqual(first.revision, document.textRevision)

        // Предпросмотр принимает модель при тех же настройках и не принимает при других.
        func accepts(_ syntax: MarkdownSyntaxOptions, text: String, critic: CriticMarkupRenderMode? = nil) -> Bool {
            MarkdownHTMLRenderer.accepts(first, text: text, syntax: syntax, wiki: nil, critic: critic, documentURL: nil)
        }
        XCTAssertTrue(accepts(.init(), text: source))
        XCTAssertFalse(accepts(.init(), text: source, critic: .show), "другой набор вывода (CriticMarkup)")
        XCTAssertFalse(accepts(MarkdownSyntaxOptions(preserveEditingSoftBreaks: false), text: source), "другие настройки синтаксиса")
        XCTAssertFalse(accepts(.init(), text: source + "!"), "текст другой длины")

        // Смена темы: вывод из модели совпадает с выводом из строки.
        for dark in [false, true] {
            let fromModel = MarkdownHTMLRenderer.renderPage(first, text: source, darkMode: dark, renderEmoji: true, includeSourcePositions: true, isPreview: true)
            let fromString = MarkdownHTMLRenderer.renderPage(source, darkMode: dark, renderEmoji: true, includeSourcePositions: true, isPreview: true)
            XCTAssertEqual(fromModel.body, fromString.body, "тёмная тема: \(dark)")
            XCTAssertEqual(fromModel.headingIDs, fromString.headingIDs, "тёмная тема: \(dark)")
        }

        let oldRevision = document.textRevision
        document.text = source + "ещё 😀\r\n"
        XCTAssertNil(document.markdownModel(forRevision: oldRevision), "правка сбросила модель прежней версии")
        XCTAssertNil(document.markdownModel(forRevision: document.textRevision), "для новой версии модели ещё нет")
        XCTAssertFalse(MarkdownHTMLRenderer.accepts(first, text: document.text, syntax: .init(), wiki: nil, critic: nil, documentURL: nil))
    }

    // MARK: Склейка равна полному разбору

    private let parseOptions = MarkdownParseOptions(includeReadableText: true, includeEmojiCandidates: true, includeUppercaseRuns: true)

    private func prepared(_ presentation: MarkdownPresentation) -> MarkdownPresentation {
        var copy = presentation
        copy.prepareForEditing()
        return copy
    }

    /// Глава с кириллицей, CJK, эмодзи, таблицей, списком в цитате, блоком кода, а при `rich` — ещё с `%%` и CriticMarkup.
    private func chapter(_ index: Int, rich: Bool) -> String {
        "# Раздел \(index) 中文\n\nАбзац **жирный** 😀 и *курсив*" + (rich ? " %%скрытый \(index)%% с {++вставка++}" : "") + " текстом.\n\n"
        + (rich ? "> - пункт в цитате\n> - второй 漢字\n\n" : "> - пункт в цитате 漢字\n\n") + "| а | б |\n|---|---|\n| 1 | 😀 |\n\n```swift\nlet x = \(index)\n```\n\nКонец главы.\n\n"
    }

    /// Случайные правки подряд с фиксированным зерном: после каждой правки результат из базы (склейка или полный разбор)
    /// совпадает с разбором с нуля. Модель склейкой не собирается: у неё `model == nil`, у полного разбора модель есть.
    func testRandomEditsOfRichDocumentMatchFullParse() throws {
        var seed: UInt64 = 12345
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }
        let snippets = ["x", " ", "\n", "\n\n", "\r\n", "я", "😀", "中文", "|", "> ", "- ", "**", "`", "```\n", "[[Цель]]", "\t"]
        // В документах с `%%` и CriticMarkup правки тоже вносят эту разметку; в остальных её нет, иначе документ навсегда уйдёт в полный разбор.
        let markup = ["%%", "{++", "++}", "{--", "--}"]
        // Front matter, `%%` и CriticMarkup по правилам локального разбора уходят в полный разбор, поэтому для проверки самой
        // склейки (кириллица, CJK, эмодзи, `\r\n`, таблица, список в цитате, код) есть документы без них.
        let rich = (0..<10).map { chapter($0, rich: true) }.joined()
        let plain = (0..<10).map { chapter($0, rich: false) }.joined()
        let sources = ["---\ntitle: Заметка 😀\ntags: [a, б]\n---\n\n" + rich, rich.replacingOccurrences(of: "\n", with: "\r\n"),
                       plain, plain.replacingOccurrences(of: "\n", with: "\r\n")]
        var localCount = 0
        var reasons: [String: Int] = [:]
        for (sourceIndex, source) in sources.enumerated() {
            var text = source
            var base = MarkdownLocalParser.parse(text, options: parseOptions, base: nil, minimumLength: 0).base
            for step in 0..<60 {
                let ns = text as NSString
                var location = next(ns.length + 1)
                // Позиция не должна попасть между половинками суррогатной пары.
                if location > 0, location < ns.length, UTF16.isTrailSurrogate(ns.character(at: location)) { location -= 1 }
                let pool = sourceIndex < 2 ? snippets + markup : snippets
                let insertion = pool[next(pool.count)]
                text = ns.replacingCharacters(in: NSRange(location: location, length: 0), with: insertion)
                let message = "документ \(sourceIndex), шаг \(step), вставка \(insertion.debugDescription) в \(location)"
                let result = MarkdownLocalParser.parse(text, options: parseOptions, base: base, minimumLength: 0)
                let full = MarkdownLocalParser.parse(text, options: parseOptions, base: nil, minimumLength: 0)
                if result.usedLocal { localCount += 1 } else { reasons["\(sourceIndex): \(result.fallbackReason ?? "")", default: 0] += 1 }
                XCTAssertNil(MarkdownPresentation.firstDifference(prepared(result.presentation), prepared(full.presentation)), message)
                XCTAssertEqual(result.base?.index, full.base?.index, "индекс блоков: \(message)")
                // Модель отдаёт только полный разбор; склейка её не собирает (контракт `MarkdownLocalParser.Result.model`).
                if result.usedLocal { XCTAssertNil(result.model, "склейка не отдаёт модель: \(message)") }
                else { XCTAssertEqual(result.model?.textLength, (text as NSString).length, message) }
                base = result.base
            }
        }
        XCTAssertGreaterThan(localCount, 5, "часть правок должна собираться из участков: \(reasons)")
    }

    // MARK: data-sourcepos

    /// Образец источника: номера строк записаны в `expected` явно (считая с 1).
    private let sourcePosSource = [
        "---",                                   // 1
        "title: Заметка 😀",                     // 2
        "---",                                   // 3
        "",                                      // 4
        "# Заголовок 中文",                      // 5
        "",                                      // 6
        "Абзац %%скрытый%% с [[a]] и {++вставка++} 😀", // 7
        "",                                      // 8
        "{==выделено==}{>>комментарий<<}",       // 9
        "",                                      // 10
        "- пункт один",                          // 11
        "- пункт два",                           // 12
        "",                                      // 13
        "| а | б |",                             // 14
        "|---|---|",                             // 15
        "| 1 | 2 |",                             // 16
        "",                                      // 17
        "```swift",                              // 18
        "let x = 1",                             // 19
        "```",                                   // 20
        "",                                      // 21
        "> цитата",                              // 22
        "",                                      // 23
        "> [!note] Выноска",                     // 24
        "> текст выноски",                       // 25
        "",                                      // 26
        "![[note-a]]",                           // 27
        "",                                      // 28
        "Последний абзац 世界",                  // 29
        "",
    ].joined(separator: "\n")

    private func renderBody(_ text: String) -> String {
        let url = BaselinePaths.documentURL
        let wiki = MarkdownWikiLinkContext(
            resolver: MarkdownWikiLinkResolver(base: URL(fileURLWithPath: "/lac-baseline", isDirectory: true), paths: ["a.md", "note-a.md"]),
            documentURL: url)
        return MarkdownHTMLRenderer.renderPage(text, darkMode: false, renderEmoji: true, resolveLocalImages: true, documentURL: url,
            prepareRemoteImages: true, includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: true,
            isPreview: true, highlightCode: true, wiki: wiki, critic: .show, embeds: BaselineEmbedProvider(), hidesObsidianComments: true).body
    }

    /// Все `data-sourcepos` вместе с тегом: (тег, строка, колонка в байтах UTF-8).
    private func positions(_ html: String) -> [(tag: String, line: Int, column: Int)] {
        let expression = try! NSRegularExpression(pattern: "<([a-z0-9]+)[^>]*? data-sourcepos=\"(\\d+):(\\d+)-\\d+:\\d+\"")
        let ns = html as NSString
        return expression.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), Int(ns.substring(with: $0.range(at: 2)))!, Int(ns.substring(with: $0.range(at: 3)))!)
        }
    }

    /// После front matter, `%%`, wiki-ссылки, CriticMarkup, выноски и встраивания блоки получают `data-sourcepos`
    /// со строкой исходника (с CRLF то же), а строка начинается с первых символов узла.
    func testSourcePositionsPointToSourceLines() {
        // (тег, строка, что стоит в исходнике с колонки data-sourcepos: после префикса цитаты колонка указывает на текст узла)
        let expected: [(String, Int, String)] = [
            ("h1", 5, "# Заголовок"),
            ("p", 7, "Абзац"),
            ("ul", 11, "- пункт один"),
            ("li", 11, "- пункт один"),
            ("li", 12, "- пункт два"),
            ("table", 14, "| а | б |"),
            ("pre", 18, "```swift"),
            ("blockquote", 22, "> цитата"),
            ("p", 22, "цитата"),
            ("p", 29, "Последний абзац"),
        ]
        let lines = sourcePosSource.components(separatedBy: "\n")
        for (name, text) in [("LF", sourcePosSource), ("CRLF", sourcePosSource.replacingOccurrences(of: "\n", with: "\r\n"))] {
            let html = renderBody(text)
            let found = positions(html)
            for (tag, line, prefix) in expected {
                guard let item = found.first(where: { $0.tag == tag && $0.line == line }) else {
                    XCTFail("\(name): нет <\(tag)> со строкой \(line): \(html)")
                    continue
                }
                // Колонка считается в байтах UTF-8 от начала строки исходника.
                let bytes = Array(lines[line - 1].utf8)
                let tail = String(decoding: bytes[min(item.column - 1, bytes.count)...], as: UTF8.self)
                XCTAssertTrue(tail.hasPrefix(prefix), "\(name): <\(tag)> строка \(line) колонка \(item.column): в исходнике \(tail.debugDescription)")
            }
            // Выноска начинается на строке 24; встраивание на строке 27 не сдвигает последний абзац.
            XCTAssertTrue(found.contains { $0.line == 24 }, "\(name): выноска на строке 24: \(html)")
            XCTAssertTrue(found.contains { $0.tag == "p" && $0.line == 29 }, name)
            XCTAssertFalse(found.contains { $0.line > 29 }, "\(name): нет позиций за концом исходника: \(html)")
        }
    }

    // MARK: Отмена

    /// Отмена разбора возвращает `nil`; полный разбор через `MarkdownLocalParser` при отмене не отдаёт ни модель, ни базу.
    func testCancelledParseReturnsNil() {
        let text = "# Заголовок 😀\n\nтекст\n"
        XCTAssertNil(MarkdownDocumentParser.parse(text, options: modelOptions, isCancelled: { true }))
        let result = MarkdownLocalParser.parse(text, options: parseOptions, base: nil, minimumLength: 0, isCancelled: { true })
        XCTAssertNil(result.model)
        XCTAssertNil(result.base)
    }
}
