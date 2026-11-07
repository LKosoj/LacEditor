import XCTest
import cmark_gfm
import cmark_gfm_extensions
@testable import LacEditor

/// Приведение HTML к общему виду для сверки: убирает добавки LacEditor и различия в пробелах между тегами.
enum SpecHTMLNormalizer {
    /// Обёртки и атрибуты, которые `renderPage` добавляет сам (`MarkdownHTMLRenderer`): таблица в прокручиваемой области,
    /// доступность `<pre>`, служебные якоря и `data-lac-*`. Язык интерфейса должен быть `en`.
    static func normalizeRendered(_ html: String) -> String {
        var text = html
        let wrapper = "<div class=\"table-scroll\" role=\"region\" aria-label=\"\(L10n.tr("表格，可横向滚动"))\" tabindex=\"0\">"
        text = text.replacingOccurrences(of: wrapper, with: "")
            .replacingOccurrences(of: "</table></div>", with: "</table>")
            .replacingOccurrences(of: "<pre tabindex=\"0\" aria-label=\"\(L10n.tr("代码块，可横向滚动"))\"", with: "<pre")
        // Служебные пустые `<span id="…"></span>` перед заголовками и якорями и скрытые метки списков.
        text = replace(text, "<span id=\"[^\"]*\"></span>", "")
        text = replace(text, "<span (?:hidden )?data-lac-[^>]*></span>", "")
        // Служебные атрибуты `data-lac-*`.
        text = replace(text, " data-lac-[a-z-]+(=\"[^\"]*\")?", "")
        text = text.replacingOccurrences(of: "<!-- raw HTML omitted -->", with: rawToken)
        return normalize(text)
    }

    /// Токен вместо сырого HTML: безопасный режим cmark заменяет его на `<!-- raw HTML omitted -->`, спецификация выводит как есть.
    static let rawToken = "<!--RAW-->"

    /// Сырые HTML-фрагменты разметки (блоки и строчные теги) в порядке появления: их находит сам cmark, а не регулярное выражение.
    static func rawFragments(in markdown: String) -> [String] {
        cmark_gfm_core_extensions_ensure_registered()
        guard !markdown.utf8.contains(0), let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink"] {
            name.withCString { if let ext = cmark_find_syntax_extension($0) { cmark_parser_attach_syntax_extension(parser, ext) } }
        }
        markdown.withCString { cmark_parser_feed(parser, $0, markdown.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }
        var result: [String] = []
        let iterator = cmark_iter_new(root)
        defer { cmark_iter_free(iterator) }
        while let iterator, cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator),
                  let name = cmark_node_get_type_string(node), ["html_block", "html_inline"].contains(String(cString: name)),
                  let literal = cmark_node_get_literal(node) else { continue }
            result.append(String(cString: literal).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Ожидаемый HTML спецификации: каждый сырой фрагмент заменяется токеном (по порядку, слева направо).
    static func normalizeExpected(_ html: String, markdown: String) -> String {
        var text = html
        var cursor = 0
        for fragment in rawFragments(in: markdown) where !fragment.isEmpty {
            guard let range = text.range(of: fragment, range: text.index(text.startIndex, offsetBy: cursor)..<text.endIndex) else { continue }
            cursor = text.distance(from: text.startIndex, to: range.lowerBound) + rawToken.count
            text.replaceSubrange(range, with: rawToken)
        }
        return normalize(text)
    }

    /// Общая нормализация обеих сторон: пробелы между тегами и внутри текста сворачиваются, кроме содержимого `<pre>`.
    static func normalize(_ html: String) -> String {
        let source = html as NSString
        let pre = try! NSRegularExpression(pattern: "<pre[\\s\\S]*?</pre>")
        var result = ""
        var last = 0
        for match in pre.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            result += collapse(source.substring(with: NSRange(location: last, length: match.range.location - last)))
            result += source.substring(with: match.range)
            last = NSMaxRange(match.range)
        }
        result += collapse(source.substring(from: last))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapse(_ text: String) -> String {
        var text = replace(text, "\\s+", " ")
        // Пробел у границ блочных тегов и у переноса строки не значим в HTML.
        text = replace(text, " ?(</?(?:p|li|ul|ol|blockquote|h[1-6]|table|thead|tbody|tr|th|td|div|hr)\\b[^>]*>) ?", "$1")
        text = replace(text, " ?<br ?/> ?", "<br />")
        return text
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}

/// Сверка HTML `renderPage` со спецификацией GFM (U0.3): каждое несовпадение описано либо как намеренное расширение, либо как известная ошибка.
final class MarkdownSpecConformanceTests: XCTestCase {
    private struct SpecDifference {
        let corpus: String          // "spec" или "ext"
        let examples: [Int]
        let reason: String          // что и почему отличается
        let rule: String?           // правило docs/agents; только у намеренных расширений
        let fixIn: String?          // только у известных ошибок и у pendingU32

        func contains(_ key: String) -> Bool { examples.contains { "\(corpus)#\($0)" == key } }
    }

    /// Навсегда: возможности LacEditor, которых нет в спецификации.
    private static let intentionalExtensions: [SpecDifference] = [
        SpecDifference(corpus: "spec", examples: [138],
                       reason: "Строчный <del> входит в поддержанный HTML и выводится как настоящий тег, а не заменяется на «<!-- raw HTML omitted -->» (сырой HTML в остальных примерах сверяется через общий токен)",
                       rule: "docs/agents/markdown-html-media.md", fixIn: nil),
        SpecDifference(corpus: "ext", examples: [12],
                       reason: "Строчный <br> внутри ячейки таблицы входит в поддержанный HTML и выводится как настоящий тег, а не заменяется на «<!-- raw HTML omitted -->»",
                       rule: "docs/agents/markdown-html-media.md", fixIn: nil),
        SpecDifference(corpus: "spec", examples: [652],
                       reason: "Расширение tagfilter не включено: спецификация экранирует «<» у запрещённых тегов (title, style, xmp), а безопасный режим cmark заменяет любой сырой тег и блок на «<!-- raw HTML omitted -->»",
                       rule: "docs/agents/export-and-preview.md", fixIn: nil),
        SpecDifference(corpus: "ext", examples: [22],
                       reason: "Расширение tagfilter не включено: спецификация экранирует «<» у запрещённых тегов (xmp, textarea и др.), а безопасный режим cmark заменяет любой сырой тег и блок на «<!-- raw HTML omitted -->»; поддержанный <strong> выводится настоящим тегом",
                       rule: "docs/agents/export-and-preview.md", fixIn: nil),
        SpecDifference(corpus: "spec", examples: [66, 68],
                       reason: "Блок «---» в начале документа считается YAML-шапкой (front matter) и в HTML не выводится; в спецификации это thematic break и setext-заголовок. Отдельного правила в docs/agents нет: дописать при U3.4",
                       rule: "docs/agents/markdown-editor.md", fixIn: nil),
        SpecDifference(corpus: "spec", examples: [610, 614, 616, 619, 620],
                       reason: "Включено расширение GFM autolink: адрес и e-mail без «<>» становятся ссылками; примеры core-спецификации идут без расширений. Отдельного правила в docs/agents нет: дописать при U3.4",
                       rule: "docs/agents/markdown-editor.md", fixIn: nil),
        SpecDifference(corpus: "ext", examples: [14],
                       reason: "Опция cmark TABLE_SPANS: пустая ячейка «||» сливается с предыдущей через colspan, в расширении GFM она остаётся пустой ячейкой. Отдельного правила в docs/agents нет: дописать при U3.4",
                       rule: "docs/agents/markdown-editor.md", fixIn: nil),
        SpecDifference(corpus: "ext", examples: [17, 18],
                       reason: "Одинарные «~текст~» выводятся как нижний индекс <sub>, а не зачёркивание; двойные «~~» остаются <del>. Отдельного правила в docs/agents нет: дописать при U3.4",
                       rule: "docs/agents/markdown-editor.md", fixIn: nil),
    ]

    /// Временный список ошибок текущего рендера относительно spec: должен опустеть в U3.1 (проверка в U3.4).
    /// После первичного разбора (U0.3) ошибок не найдено: все 14 несовпадений — намеренные расширения.
    private static let knownDefects: [SpecDifference] = [
    ]

    /// Записи «до U3.2» выполнены: сырой строчный `<del>`/`<br>` адаптер выводит настоящим тегом, спец 138 и ext 12 снова в `intentionalExtensions`.
    private static let pendingU32: [SpecDifference] = []

    /// Нижняя планка точных совпадений после первичного разбора. Пример с `<IGNORE>` (проверяет только отсутствие падения) не считается.
    private static let minimumMatches = 685
    /// Планка адаптера (spec 138 и ext 12 снова намеренные расширения).
    private static let minimumMatchesHTMLRenderer = 685

    private var suite: String?

    override func setUp() {
        super.setUp()
        let name = "MarkdownSpecConformanceTests-\(UUID().uuidString)"
        suite = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.set("en", forKey: L10n.languageKey)
        L10n.configure(defaults: defaults)
    }

    override func tearDown() {
        if let suite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        L10n.configure()
        super.tearDown()
    }

    private struct Outcome {
        let corpus: String
        let example: GFMSpecCase
        let expected: String
        let actual: String
        /// `<IGNORE>` вместо HTML — соглашение cmark-gfm: пример проверяет только отсутствие падения, совпадения не даёт.
        var isIgnored: Bool { example.html.trimmingCharacters(in: .whitespacesAndNewlines) == "<IGNORE>" }
        var matches: Bool { expected == actual }
        var key: String { "\(corpus)#\(example.number)" }
    }

    /// Настройки без источников позиций, подсветки, wiki и правок: мягкий перенос выводится пробелом, нормализация его сворачивает.
    private func outcomes(inlineMath: Bool = true) throws -> [Outcome] {
        try outcomes(inlineMath: inlineMath) { markdown, syntax in
            MarkdownHTMLRenderer.renderPage(markdown, darkMode: false, syntax: syntax).body
        }
    }

    /// Те же примеры для произвольного рендера: `render` получает разметку и настройки, возвращает `body` страницы.
    private func outcomes(inlineMath: Bool = true, render: (String, MarkdownSyntaxOptions) -> String) throws -> [Outcome] {
        let syntax = MarkdownSyntaxOptions(inlineMath: inlineMath, smartPunctuation: false, preserveEditingSoftBreaks: false)
        var result: [Outcome] = []
        for (corpus, cases) in [("spec", try GFMSpecReader.spec()), ("ext", try GFMSpecReader.extensions())] {
            for example in cases where !example.isDisabled {
                let actual = SpecHTMLNormalizer.normalizeRendered(render(example.markdown, syntax))
                let expected = example.html.trimmingCharacters(in: .whitespacesAndNewlines) == "<IGNORE>" ? actual : SpecHTMLNormalizer.normalizeExpected(example.html, markdown: example.markdown)
                result.append(Outcome(corpus: corpus, example: example, expected: expected, actual: actual))
            }
        }
        return result
    }

    func testSpecReaderCounts() throws {
        let spec = try GFMSpecReader.spec(), ext = try GFMSpecReader.extensions()
        XCTAssertEqual(spec.count, 672)
        XCTAssertEqual(ext.count, 30)
        XCTAssertEqual((spec + ext).filter(\.isDisabled).count, 2)
        XCTAssertEqual(spec.first?.markdown, "\tfoo\tbaz\t\tbim\n")
        XCTAssertEqual(spec.first?.html, "<pre><code>foo\tbaz\t\tbim\n</code></pre>\n")
        XCTAssertEqual(spec.first?.section, "Tabs")
        XCTAssertEqual(Set(spec.map(\.tag)), ["", "table", "strikethrough", "autolink", "tagfilter", "disabled"])
    }

    func testNormalizerRemovesTableWrapper() {
        let wrapper = "<div class=\"table-scroll\" role=\"region\" aria-label=\"\(L10n.tr("表格，可横向滚动"))\" tabindex=\"0\">"
        let rendered = SpecHTMLNormalizer.normalizeRendered(wrapper + "<table>\n<tr><td>a</td></tr>\n</table></div>\n")
        XCTAssertEqual(rendered, SpecHTMLNormalizer.normalize("<table>\n<tr><td>a</td></tr>\n</table>\n"))
    }

    func testNormalizerRemovesPreAttributes() {
        let rendered = SpecHTMLNormalizer.normalizeRendered("<pre tabindex=\"0\" aria-label=\"\(L10n.tr("代码块，可横向滚动"))\"><code>a</code></pre>\n")
        XCTAssertEqual(rendered, "<pre><code>a</code></pre>")
    }

    func testNormalizerKeepsSpacesInPreAndCollapsesOutside() {
        XCTAssertEqual(SpecHTMLNormalizer.normalize("<p>a  \n b</p>\n<pre><code>a  \n b\n</code></pre>\n"), "<p>a b</p><pre><code>a  \n b\n</code></pre>")
    }

    func testNormalizerRemovesServiceMarkup() {
        let rendered = SpecHTMLNormalizer.normalizeRendered("<h1><span id=\"a\"></span>T</h1>\n<span hidden data-lac-list-depth=\"1\" data-lac-list-kind=\"ul\"></span><ul>\n<li data-lac-checked-task>x</li>\n</ul>\n")
        XCTAssertEqual(rendered, "<h1>T</h1><ul><li>x</li></ul>")
    }

    func testNormalizerReplacesRawHTMLWithSameToken() {
        let expected = SpecHTMLNormalizer.normalizeExpected("<div>\n*привет*\n</div>\n", markdown: "<div>\n*привет*\n</div>\n")
        let actual = SpecHTMLNormalizer.normalizeRendered("<!-- raw HTML omitted -->\n")
        XCTAssertEqual(expected, SpecHTMLNormalizer.rawToken)
        XCTAssertEqual(actual, SpecHTMLNormalizer.rawToken)
    }

    func testConformance() throws {
        let all = try outcomes()
        let failures = all.filter { !$0.matches }
        if let path = ProcessInfo.processInfo.environment["LAC_SPEC_REPORT"] {
            try report(all: all, failures: failures, path: path)
            return
        }
        checkConformance(all: all, lists: [("intentionalExtensions", Self.intentionalExtensions), ("knownDefects", Self.knownDefects)],
                         pending: [], minimum: Self.minimumMatches)
    }

    /// Проверка списка расхождений: каждое несовпадение описано, каждая запись жива, планка совпадений не упала.
    /// `pending` — записи «до U3.2»: пример обязан совпасть со спецификацией (инвертированная проверка), иначе поведение адаптера изменилось.
    private func checkConformance(all: [Outcome], lists: [(String, [SpecDifference])], pending: [SpecDifference], minimum: Int) {
        let failures = all.filter { !$0.matches }
        var covered: [String: (kind: String, difference: SpecDifference)] = [:]
        for (kind, list) in lists {
            for difference in list {
                XCTAssertFalse(difference.reason.isEmpty, "\(kind): нет причины у \(difference.corpus) \(difference.examples)")
                if kind != "intentionalExtensions" {
                    XCTAssertNotNil(difference.fixIn, "\(kind): нет fixIn у \(difference.corpus) \(difference.examples)")
                } else if let rule = difference.rule, rule.hasPrefix("docs/agents/") {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: BaselinePaths.projectRoot.appendingPathComponent(rule).path), "нет правила \(rule)")
                } else {
                    XCTFail("intentionalExtensions: нужно правило docs/agents у \(difference.corpus) \(difference.examples)")
                }
                for number in difference.examples {
                    let key = "\(difference.corpus)#\(number)"
                    XCTAssertNil(covered[key], "пример \(key) записан дважды")
                    covered[key] = (kind, difference)
                }
            }
        }
        for failure in failures where covered[failure.key] == nil && !pending.contains(where: { $0.contains(failure.key) }) {
            XCTFail("\(failure.key) [\(failure.example.section)] не совпал и не описан.\n  ожидалось: \(failure.expected)\n  получено:  \(failure.actual)")
        }
        let failed = Set(failures.map(\.key))
        for key in covered.keys.sorted() where !failed.contains(key) {
            XCTFail("запись про \(key) устарела: пример теперь совпадает со спецификацией")
        }
        for difference in pending {
            XCTAssertFalse(difference.reason.isEmpty, "pendingU32: нет причины у \(difference.corpus) \(difference.examples)")
            XCTAssertNotNil(difference.fixIn, "pendingU32: нет fixIn у \(difference.corpus) \(difference.examples)")
            for number in difference.examples {
                let key = "\(difference.corpus)#\(number)"
                XCTAssertNil(covered[key], "пример \(key) записан и в pendingU32, и в основном списке")
                XCTAssertFalse(failed.contains(key), "\(key) обязан совпасть со спецификацией до \(difference.fixIn ?? "?"), но не совпал: поведение адаптера изменилось")
            }
        }
        XCTAssertEqual(all.filter(\.isIgnored).count, 1, "примеров с <IGNORE> должно быть один (ext)")
        XCTAssertGreaterThanOrEqual(all.filter { $0.matches && !$0.isIgnored }.count, minimum, "число совпадений упало")
    }

    /// Новый HTML-адаптер против той же спецификации. В U3.1 строчные `<del>`/`<br>` ещё не выводятся (U3.2), поэтому 138 и ext 12 совпадают «случайно».
    func testConformanceHTMLRenderer() throws {
        let all = try outcomes { markdown, syntax in
            MarkdownHTMLRenderer.renderPage(markdown, darkMode: false, syntax: syntax).body
        }
        let failures = all.filter { !$0.matches }
        if let path = ProcessInfo.processInfo.environment["LAC_SPEC_REPORT_HTML"] {
            var out = "примеров: \(all.count), не совпало: \(failures.count)\n"
            for failure in failures {
                out += "\(failure.key) | \(failure.example.section) | md=\(BaselineText.quoted(failure.example.markdown))\n  ожидалось: \(BaselineText.quoted(failure.expected))\n  получено:  \(BaselineText.quoted(failure.actual))\n"
            }
            try out.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        let pendingKeys = Set(Self.pendingU32.flatMap { difference in difference.examples.map { "\(difference.corpus)#\($0)" } })
        let intentional = Self.intentionalExtensions.compactMap { difference -> SpecDifference? in
            let rest = difference.examples.filter { !pendingKeys.contains("\(difference.corpus)#\($0)") }
            return rest.isEmpty ? nil : SpecDifference(corpus: difference.corpus, examples: rest, reason: difference.reason, rule: difference.rule, fixIn: difference.fixIn)
        }
        checkConformance(all: all, lists: [("intentionalExtensions", intentional), ("knownDefects", Self.knownDefects)],
                         pending: Self.pendingU32, minimum: Self.minimumMatchesHTMLRenderer)
    }

    /// Режим `LAC_SPEC_REPORT=<файл>`: тест не падает, а пишет список несовпадений и сводку по разделам.
    private func report(all: [Outcome], failures: [Outcome], path: String) throws {
        let withoutMath = Set(try outcomes(inlineMath: false).filter { !$0.matches }.map(\.key))
        var out = "примеров: \(all.count), совпало: \(all.filter { $0.matches && !$0.isIgnored }.count), без проверки (<IGNORE>): \(all.filter(\.isIgnored).count), не совпало: \(failures.count)\n"
        var bySection: [String: Int] = [:]
        for failure in failures {
            bySection["\(failure.corpus)/\(failure.example.section)", default: 0] += 1
            out += "\(failure.key) | \(failure.example.section) | tag=\(failure.example.tag) | md=\(BaselineText.quoted(failure.example.markdown)) | math=\(withoutMath.contains(failure.key) ? "no" : "yes")\n"
            out += "  ожидалось: \(BaselineText.quoted(failure.expected))\n  получено:  \(BaselineText.quoted(failure.actual))\n"
        }
        out += "\nСводка по разделам:\n" + bySection.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n") + "\n"
        out += "Исчезли без inlineMath: " + failures.filter { !withoutMath.contains($0.key) }.map(\.key).joined(separator: ", ") + "\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
