import XCTest
@testable import LacEditor

/// Контрольные тесты HTML-адаптера для Obsidian и CriticMarkup (U3.3): правки, комментарии `%%`, wiki-ссылки, выноски,
/// алерты и встраивания.
final class MarkdownHTMLRendererObsidianTests: XCTestCase {
    private var suite: String?

    override func setUp() {
        super.setUp()
        useEnglish()
    }

    override func tearDown() {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        L10n.configure()
        super.tearDown()
    }

    /// Текст интерфейса попадает в HTML (подписи выносок, врезок), поэтому язык фиксируется.
    private func useEnglish() {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let name = "MarkdownHTMLRendererObsidianTests-\(UUID().uuidString)"
        suite = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.set("en", forKey: L10n.languageKey)
        L10n.configure(defaults: defaults)
    }

    // MARK: Стенд

    private let documentURL = BaselinePaths.documentURL
    private let wiki = MarkdownWikiLinkContext(
        resolver: MarkdownWikiLinkResolver(base: URL(fileURLWithPath: "/lac-baseline", isDirectory: true),
                                           paths: ["a.md", "sub/c.md", "x.md", "sub/x.md", "Корпус.md", "note-a.md"]),
        documentURL: BaselinePaths.documentURL)
    private let embeds = BaselineEmbedProvider()

    /// Наборы настроек, как у `BaselineSet`, но через новый адаптер.
    private func renderNew(_ set: BaselineSet, _ markdown: String, dark: Bool = false) -> String {
        let url = documentURL
        let page: MarkdownRenderedPage
        switch set {
        case .previewVault:
            page = MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: true,
                isPreview: true, highlightCode: true, wiki: wiki, critic: .show, embeds: embeds, hidesObsidianComments: true)
        case .exportPDF:
            page = MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, forExport: true, includeHeadingNumbers: true, includeListStyles: true,
                staticWidgetFallback: true, highlightCode: true, wiki: wiki, embeds: embeds)
        case .exportHTML:
            page = MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, includeHTMLMedia: true, renderEmoji: true, resolveLocalImages: false,
                documentURL: url, prepareRemoteImages: false, forExport: true, includeHeadingNumbers: true, includeListStyles: true,
                staticWidgetFallback: false, preserveRawHTMLBlocks: true, highlightCode: false, wiki: wiki, critic: .result, embeds: embeds)
        case .exportNoBreaks:
            page = MarkdownHTMLRenderer.renderPage(markdown, darkMode: dark, renderEmoji: true, resolveLocalImages: true, documentURL: url,
                prepareRemoteImages: true, syntax: .init(preserveExportWhitespace: true, preserveExportSoftBreaks: false), forExport: true,
                includeHeadingNumbers: true, includeListStyles: true, staticWidgetFallback: true, highlightCode: true,
                wiki: wiki, critic: .original, embeds: embeds)
        default:
            fatalError("набор не относится к U3.3")
        }
        var markers = BaselineMarkers()
        return markers.apply(page.body)
    }

    /// Без `data-sourcepos`: колонки и конец абзацев с wiki, `%%`, правками и строкой-маркером выноски считаются по исходнику.
    private func withoutSourcePositions(_ html: String) -> String {
        html.replacingOccurrences(of: " data-sourcepos=\"[^\"]*\"", with: "", options: .regularExpression)
    }

    /// Выноски: тело начинается со своей строки, а не со строки маркера (В).
    func testCalloutBodyParagraphStartsAtBodyLine() {
        let html = renderNew(.previewVault, "> [!note] Заголовок\n> Текст\n")
        XCTAssertTrue(html.contains("data-sourcepos=\"1:1-2:12\""), html)
        XCTAssertTrue(html.contains("<p data-sourcepos=\"2:3-2:12\">Текст</p>"), html)
    }

    /// Выноски при `preserveWhitespace` распознаются (И): раньше оставалась простая цитата с текстом `[!note]`.
    func testCalloutIsRecognizedWithPreservedWhitespace() {
        let span = { (text: String) in "<span data-lac-whitespace style=\"white-space:break-spaces\">\(text)</span>" }
        let expected = "<div class=\"lac-callout lac-callout-note\" role=\"note\" aria-label=\"Note: Заголовок\">"
            + "<div class=\"lac-callout-title\"><span class=\"lac-callout-icon\" aria-hidden=\"true\">✎</span>"
            + "<span class=\"lac-callout-label\">Note</span><span class=\"lac-callout-text\">\(span("Заголовок"))</span></div>"
            + "<div class=\"lac-callout-body\"><p>\(span("Текст"))</p>\n</div></div>\n"
        XCTAssertEqual(renderNew(.exportNoBreaks, "> [!note] Заголовок\n> Текст\n"), expected)
    }

    /// Врезка при `preserveWhitespace` лежит на уровне блока, а не внутри абзаца со span (З).
    func testEmbedIsNotWrappedInParagraphWithPreservedWhitespace() {
        let html = renderNew(.exportNoBreaks, "![[note-a]]\n")
        XCTAssertTrue(html.hasPrefix("<section class=\"lac-embed\""), html)
        XCTAssertFalse(html.contains("<p><span data-lac-whitespace style=\"white-space:break-spaces\"><section"), html)
    }

    // MARK: Врезки: чтение и кэш

    private final class CountingProvider: MarkdownNoteEmbedProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func embeddedNote(for target: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            counts[target, default: 0] += 1
            return "Текст заметки\n\n![[\(target)]]\n"
        }
        func count(_ target: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[target] ?? 0 }
    }

    /// Одна и та же врезка читается один раз, а вложенная `![[…]]` внутри заметки не раскрывается (глубина 1).
    func testRepeatedEmbedIsReadOnceAndNestedEmbedIsNotExpanded() {
        let provider = CountingProvider()
        let markdown = String(repeating: "![[loop]]\n\n", count: 3)
        let page = MarkdownHTMLRenderer.renderPage(markdown, darkMode: false, documentURL: documentURL, wiki: wiki, embeds: provider)
        XCTAssertEqual(provider.count("loop"), 1)
        XCTAssertEqual(page.body.components(separatedBy: "<section class=\"lac-embed\"").count, 4)
        XCTAssertFalse(page.body.contains("lac-embed-body\"><section"), page.body)
    }

    // MARK: Отличия при `preserveWhitespace`

    /// Ненайденная wiki-ссылка при `preserveWhitespace` склеена с соседним текстом: один `data-lac-whitespace`.
    func testUnresolvedWikiLinkJoinsNeighbourTextWithPreservedWhitespace() {
        let html = renderNew(.exportNoBreaks, "до [[нет-файла]] после\n")
        XCTAssertEqual(html.components(separatedBy: "data-lac-whitespace").count - 1, 1, html)
    }

    // MARK: Позиции, экранирование, выноски

    /// Блоки после выноски, встраивания, wiki-ссылки, `%%` и правки: точные `data-sourcepos` (А, В).
    func testSourcePositionsAfterObsidianBlocksAndInlines() {
        XCTAssertTrue(renderNew(.previewVault, "> [!note] T\n> body\n\nafter\n").contains("<p data-sourcepos=\"4:1-4:5\">after</p>"))
        XCTAssertTrue(renderNew(.previewVault, "![[note-a]]\n\nafter\n").contains("<p data-sourcepos=\"3:1-3:5\">after</p>"))
        XCTAssertTrue(renderNew(.previewVault, "[[a]] текст\n").contains("<p data-sourcepos=\"1:1-1:16\">"))
        XCTAssertTrue(renderNew(.previewVault, "до %%скрыто%% после\n").contains("<p data-sourcepos=\"1:1-1:32\">"))
        XCTAssertTrue(renderNew(.previewVault, "a {++b++} c\n").contains("<p data-sourcepos=\"1:1-1:11\">"))
    }

    /// Wiki-ссылка внутри скобок `[[[цель]]]`: внешние `[` и `]` остаются текстом, а строка `[[[цель]]]: /url`
    /// не становится определением ссылки (так же, как в редакторе). Найденная цель даёт ссылку внутри скобок.
    func testTripleBracketWikiDoesNotBecomeReferenceDefinition() {
        let missing = renderNew(.previewVault, "[[[нет-файла]]]\n\n[[[нет-файла]]]: /url\n")
        XCTAssertTrue(missing.contains(">[нет-файла]</p>"), missing)
        XCTAssertTrue(missing.contains(">[нет-файла]: /url</p>"), missing)
        XCTAssertFalse(missing.contains("<a "), missing)
        let found = renderNew(.previewVault, "[[[a]]]\n\n[[[a]]]: /url\n")
        XCTAssertTrue(found.contains("[<a ") && found.contains("</a>]"), found)
        XCTAssertFalse(found.contains("href=\"/url\""), found)
    }

    func testEscapingInWikiCalloutAndCritic() {
        let html = renderNew(.previewVault, "{>>с \"кавычкой\" и <b><<}\n")
        XCTAssertTrue(html.contains("&quot;кавычкой&quot;") && !html.contains("<b>"), html)
    }

    // MARK: Встраивания

    private func renderEmbeds(_ markdown: String, wiki: MarkdownWikiLinkContext?, embeds: (any MarkdownNoteEmbedProvider)?, url: URL? = nil,
                              sourcePositions: Bool = true) -> String {
        let url = url ?? documentURL
        var markers = BaselineMarkers()
        let page = MarkdownHTMLRenderer.renderPage(markdown, darkMode: false, renderEmoji: true, resolveLocalImages: true, documentURL: url,
            prepareRemoteImages: true, includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: sourcePositions,
            isPreview: true, highlightCode: true, wiki: wiki, critic: .show, embeds: embeds, hidesObsidianComments: true)
        return withoutSourcePositions(markers.apply(page.body))
    }

    private struct TextProvider: MarkdownNoteEmbedProvider {
        let text: (String) -> String?
        func embeddedNote(for target: String) -> String? { text(target) }
    }

    /// Заметка длиннее 64 КиБ обрезается, суммарно читается не больше 1 МиБ (остальные врезки — «не найдено»).
    func testEmbedByteLimits() {
        let big = String(repeating: "строка 中文 😀\n\n", count: 6000)
        XCTAssertGreaterThan(big.utf8.count, MarkdownNoteEmbed.maxNoteBytes)
        let single = renderEmbeds("![[big]]\n", wiki: wiki, embeds: TextProvider { _ in big })
        XCTAssertTrue(single.contains("lac-embed"), single)
        let many = (0..<20).map { "![[n\($0)]]\n" }.joined(separator: "\n")
        let total = renderEmbeds(many, wiki: wiki, embeds: TextProvider { _ in big })
        XCTAssertTrue(total.contains("lac-embed-missing"), "после 1 МиБ врезки пропадают")
    }

    /// Найденные картинка и вложение `![[файл]]` (блочные и строчные) и ненайденная: настоящие файлы во временном каталоге.
    func testFileEmbeds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lac-obsidian-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: directory.appendingPathComponent("pic.png"))
        try Data("%PDF-1.4\n".utf8).write(to: directory.appendingPathComponent("doc.pdf"))
        let context = MarkdownWikiLinkContext(resolver: MarkdownWikiLinkResolver(base: directory, paths: ["pic.png", "doc.pdf"]),
                                              documentURL: directory.appendingPathComponent("doc.md"))
        let markdown = "![[pic.png]]\n\n![[doc.pdf]]\n\nстрока ![[pic.png]] и ![[doc.pdf]] текст\n\n![[нет.png]]\n"
        let result = renderEmbeds(markdown, wiki: context, embeds: embeds, url: directory.appendingPathComponent("doc.md"))
        XCTAssertTrue(result.contains("<img"), result)
        XCTAssertTrue(result.contains("<em>"), result)
    }

    /// Врезка не получает `data-sourcepos` вложенной заметки, а блок после неё сохраняет позицию.
    func testEmbeddedNoteHasNoSourcePositions() {
        let html = renderNew(.previewVault, "![[note-a]]\n\nпосле\n")
        let section = html.components(separatedBy: "</section>").first ?? ""
        XCTAssertFalse(section.contains("data-sourcepos"), section)
        XCTAssertTrue(html.contains("<p data-sourcepos=\"3:1-3:10\">после</p>"), html)
    }

    /// Отмена во время чтения врезки: страница пустая, без падения.
    func testCancellationDuringEmbedGivesEmptyPage() async {
        let provider = TextProvider { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return "# Заметка\n\nтекст\n"
        }
        let body = await Task {
            MarkdownHTMLRenderer.renderPage("![[x]]\n\n![[y]]\n", darkMode: false, documentURL: documentURL, wiki: wiki, embeds: provider).body
        }.value
        XCTAssertEqual(body, "")
    }

    /// Пустой экран определяется по выведенному телу (решение 5 U3.3): документ только из `%%…%%` в заметке хранилища
    /// или из одних удалённых правок в `.result` показывает подсказку; в экспорте подсказки нет.
    func testEmptyPreviewHintWhenOnlyHiddenContent() {
        useEnglish()
        let hint = "<p class=\"lac-empty\">\(L10n.tr("预览为空。在编辑器中输入 Markdown 后，内容会显示在这里。"))</p>"
        let comment = MarkdownHTMLRenderer.renderPage("%%только комментарий 汉字 😀%%\r\n", darkMode: false, isPreview: true,
                                                      hidesObsidianComments: true)
        XCTAssertEqual(comment.body, hint)
        let deleted = MarkdownHTMLRenderer.renderPage("{--удалено 汉字--}\n", darkMode: false, isPreview: true, critic: .result)
        XCTAssertEqual(deleted.body, hint)
        let export = MarkdownHTMLRenderer.renderPage("%%c%%\n", darkMode: false, forExport: true, isPreview: true, hidesObsidianComments: true)
        XCTAssertEqual(export.body, "")
        let visible = MarkdownHTMLRenderer.renderPage("%%c%% текст\n", darkMode: false, isPreview: true, hidesObsidianComments: true)
        XCTAssertNotEqual(visible.body, hint)
        // Front matter, определение ссылки и HTML-комментарий: подсказки нет.
        for source in ["---\ntitle: x\n---\n", "[a]: http://x\n", "<!-- комментарий -->\n"] {
            let new = MarkdownHTMLRenderer.renderPage(source, darkMode: false, isPreview: true, hidesObsidianComments: true)
            XCTAssertNotEqual(new.body, hint, source)
        }
    }
}
