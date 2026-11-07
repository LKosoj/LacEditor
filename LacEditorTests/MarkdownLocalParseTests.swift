import XCTest
@testable import LacEditor

/// Локальный разбор (T5): результат после правки должен совпадать с полным разбором, а сомнительные случаи — уходить в полный разбор.
final class MarkdownLocalParseTests: XCTestCase {
    private let options = MarkdownParseOptions(includeReadableText: true, includeEmojiCandidates: true, includeUppercaseRuns: true)

    private func prepared(_ presentation: MarkdownPresentation) -> MarkdownPresentation {
        var copy = presentation
        copy.prepareForEditing()
        return copy
    }

    private func chapters(_ count: Int) -> String {
        (0..<count).map { index in
            "# Раздел \(index)\n\nАбзац **жирный** и *курсив* 😀 с `кодом`.\nВторая строка 中文.\n\n- пункт\n- [x] задача\n\n> цитата\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = \(index)\n```\n\n"
        }.joined()
    }

    private func edit(_ text: String, at location: Int, removing length: Int = 0, inserting insertion: String) -> String {
        let source = text as NSString
        return source.replacingCharacters(in: NSRange(location: location, length: length), with: insertion)
    }

    private func assertSame(_ local: MarkdownLocalParser.Result, _ text: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let full = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0)
        XCTAssertNil(MarkdownPresentation.firstDifference(prepared(local.presentation), prepared(full.presentation)), message, file: file, line: line)
        XCTAssertEqual(local.base?.index, full.base?.index, "индекс блоков: \(message)", file: file, line: line)
    }

    /// Случайные правки подряд на нескольких исходных документах (в том числе начинающемся с `---` и с табуляциями):
    /// локальные результаты совпадают с полными, а доля локальных заметна.
    func testRandomEditsMatchFullParse() throws {
        var seed: UInt64 = 12345
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }
        let snippets = ["x", " ", "\n", "\n\n", "\r\n", "# ", "- ", "> ", "```\n", "~~~\n", "**", "`", "Привет", "😀", "中文", "|", "[[Цель]]", ":smile:",
                        "---\n", "===\n", "\t", "]:", "[^1]", "<b>", "$$", "![i](a.png)", "- [ ] ", "[TOC]\n"]
        let sources = [chapters(12), "---\n\n" + chapters(12), chapters(12).replacingOccurrences(of: "Вторая", with: "\tВторая"),
                       chapters(12).replacingOccurrences(of: "\n", with: "\r\n")]
        var localCount = 0
        for (sourceIndex, source) in sources.enumerated() {
            var text = source
            var base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
            for step in 0..<40 {
                let length = (text as NSString).length
                var location = next(length + 1)
                if location > 0, location < length, UTF16.isTrailSurrogate((text as NSString).character(at: location)) { location -= 1 }
                let insertion = snippets[next(snippets.count)]
                text = edit(text, at: location, inserting: insertion)
                let result = MarkdownLocalParser.parse(text, options: options, base: base, minimumLength: 0)
                if result.usedLocal { localCount += 1 }
                assertSame(result, text, "документ \(sourceIndex), шаг \(step), вставка \(insertion.debugDescription) в \(location)")
                base = result.base
            }
        }
        XCTAssertGreaterThan(localCount, 10, "часть правок посреди длинного документа должна разбираться локально")
    }

    /// Документ начинается с `---` (это линия, пока нет закрывающей строки), а внизу набирается `---` или `...`:
    /// полный разбор делает из начала front matter, поэтому локальный разбор обязан уступить ему.
    func testClosingFrontMatterLineFarFromStartFallsBack() {
        let text = "---\n\n" + chapters(12)
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        XCTAssertNotNil(base)
        // Текст кончается на "```\n\n": позиция length - 1 - начало последней пустой строки, вставка получается отдельной строкой.
        let tail = (text as NSString).length - 1
        for insertion in ["---\n", "...\n"] {
            let edited = edit(text, at: tail, inserting: insertion)
            let result = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
            XCTAssertEqual(result.fallbackReason, "в тексте есть front matter", insertion.debugDescription)
            assertSame(result, edited, "закрытие front matter \(insertion.debugDescription)")
        }
        let bom = "\u{FEFF}" + text
        let bomBase = MarkdownLocalParser.parse(bom, options: options, base: nil, minimumLength: 0).base
        let bomEdited = edit(bom, at: (bom as NSString).length - 1, inserting: "---\n")
        assertSame(MarkdownLocalParser.parse(bomEdited, options: options, base: bomBase, minimumLength: 0), bomEdited, "BOM и закрытие front matter")
    }

    func testBaselineDocumentsMatchFullParseAfterEdit() throws {
        for name in ["note", "tables"] {
            let text = try MarkdownBaselineDocuments.fixture(name)
            let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
            let middle = (text as NSString).length / 2
            let edited = edit(text, at: middle, inserting: "слово ")
            let result = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
            assertSame(result, edited, name)
        }
    }

    /// Правка внутри абзаца длинного документа идёт локально и не меняет остальное.
    func testPlainEditInsideLongDocumentIsLocal() {
        let text = chapters(12)
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        let location = (text as NSString).range(of: "Абзац", options: [], range: NSRange(location: text.utf16.count / 2, length: text.utf16.count / 2 - 1)).location
        let edited = edit(text, at: location + 5, inserting: "ы")
        let result = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
        XCTAssertTrue(result.usedLocal, result.fallbackReason ?? "")
        assertSame(result, edited, "вставка буквы")
    }

    func testShortDocumentAndMissingBaseParseFully() {
        let text = chapters(2)
        let first = MarkdownLocalParser.parse(text, options: options, base: nil)
        XCTAssertEqual(first.fallbackReason, "нет базы")
        XCTAssertNotNil(first.base)
        let second = MarkdownLocalParser.parse(edit(text, at: 3, inserting: "x"), options: options, base: first.base)
        XCTAssertEqual(second.fallbackReason, "короткий документ")
    }

    func testRiskyEditsFallBackToFullParse() {
        let text = chapters(12)
        let middle = (text as NSString).length / 2
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        let expected: [String: String] = [
            "<b>x</b>": "в участке HTML", "[x]: http://a.b\n": "в документе есть «]:»", "[^1]": "в участке «[^»", "$$\n": "в участке «$$»",
        ]
        for (insertion, reason) in expected {
            let edited = edit(text, at: middle, inserting: insertion)
            let result = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
            XCTAssertFalse(result.usedLocal, "вставка \(insertion.debugDescription) должна уходить в полный разбор")
            XCTAssertEqual(result.fallbackReason, reason, "причина для \(insertion.debugDescription)")
            assertSame(result, edited, "вставка \(insertion.debugDescription)")
        }
        let changedOptions = MarkdownParseOptions(includeReadableText: false)
        XCTAssertEqual(MarkdownLocalParser.parse(text + "x", options: changedOptions, base: base, minimumLength: 0).fallbackReason, "параметры разбора изменились")
        let withHTML = MarkdownLocalParser.parse(text + "\n<div>x</div>\n", options: options, base: nil, minimumLength: 0)
        let afterHTML = MarkdownLocalParser.parse(edit(text + "\n<div>x</div>\n", at: middle, inserting: "x"), options: options, base: withHTML.base, minimumLength: 0)
        XCTAssertEqual(afterHTML.fallbackReason, "в документе есть HTML")
    }

    /// Абзацы однострочные: перевод строки внутри абзаца на Linux-стенде даёт «узлы без подтверждённой позиции» (как в `MarkdownLocalParseModelTests`).
    private func plainChapters(_ count: Int) -> String {
        (0..<count).map { index in
            "# Раздел \(index)\n\nАбзац **жирный** и *курсив* 😀 с `кодом` 中文.\n\n```swift\nlet x = 1\n```\n\nКонец главы.\n\n- пункт\n- [x] задача\n\n> цитата\n\n"
        }.joined()
    }

    /// Разметка критика и `%%` меняют маску всего текста: правка рядом со знаком (в старом или новом окне) уходит в полный разбор.
    /// `%%` отказывает только в заметке хранилища.
    func testCriticAndCommentMarkersFallBackToFullParse() {
        let text = plainChapters(12)
        let middle = (text as NSString).length / 2
        func rangeOfParagraph() -> NSRange {
            (text as NSString).range(of: "Абзац", options: [], range: NSRange(location: middle, length: middle - 1))
        }
        let place = rangeOfParagraph().location
        let vault = MarkdownParseOptions(includeReadableText: true, includeEmojiCandidates: true, includeUppercaseRuns: true, isVaultNote: true)
        for marker in ["{++", "{--", "{~~", "{>>", "{==", "++}", "--}", "~~}", "<<}", "==}", "~>"] {
            let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
            let result = MarkdownLocalParser.parse(edit(text, at: place, inserting: marker), options: options, base: base, minimumLength: 0)
            XCTAssertEqual(result.fallbackReason, "в тексте разметка критика или «%%»", "вставка \(marker)")
            assertSame(result, edit(text, at: place, inserting: marker), "вставка \(marker)")
        }
        // Знак уже стоял в окне и удаляется правкой: отказ по старому тексту.
        let withMarker = edit(text, at: place, inserting: "{++новое++}")
        let markerBase = MarkdownLocalParser.parse(withMarker, options: options, base: nil, minimumLength: 0).base
        let removed = edit(withMarker, at: place, removing: 11, inserting: "")
        XCTAssertEqual(MarkdownLocalParser.parse(removed, options: options, base: markerBase, minimumLength: 0).fallbackReason, "в тексте разметка критика или «%%»")
        // `%%`: в обычной заметке участок собирается локально, в заметке хранилища - полный разбор.
        let plainBase = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        let commented = edit(text, at: place, inserting: "%%")
        let plain = MarkdownLocalParser.parse(commented, options: options, base: plainBase, minimumLength: 0)
        XCTAssertTrue(plain.usedLocal, plain.fallbackReason ?? "")
        assertSame(plain, commented, "%% в обычной заметке")
        let vaultBase = MarkdownLocalParser.parse(text, options: vault, base: nil, minimumLength: 0).base
        let inVault = MarkdownLocalParser.parse(commented, options: vault, base: vaultBase, minimumLength: 0)
        XCTAssertEqual(inVault.fallbackReason, "в тексте разметка критика или «%%»")
        let vaultFull = MarkdownLocalParser.parse(commented, options: vault, base: nil, minimumLength: 0)
        XCTAssertNil(MarkdownPresentation.firstDifference(prepared(inVault.presentation), prepared(vaultFull.presentation)), "%% в заметке хранилища")
    }

    func testVaultNoteFlagChangeResetsBase() {
        let text = plainChapters(12)
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        var vault = options
        vault.isVaultNote = true
        let result = MarkdownLocalParser.parse(edit(text, at: 40, inserting: "x"), options: vault, base: base, minimumLength: 0)
        XCTAssertEqual(result.fallbackReason, "параметры разбора изменились")
    }

    /// Кириллица, CJK, эмодзи (суррогатная пара у границы правки) и \r\n: участок собирается локально и равен полному разбору.
    func testNonASCIIAndCRLFEditsAreLocalAndEqualToFull() {
        let lf = plainChapters(12)
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        for (name, text) in [("LF", lf), ("CRLF", crlf)] {
            let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
            let source = text as NSString
            let emoji = source.range(of: "😀", options: [], range: NSRange(location: source.length / 2, length: source.length / 2 - 1))
            let cjk = source.range(of: "中文", options: [], range: NSRange(location: source.length / 2, length: source.length / 2 - 1))
            XCTAssertNotEqual(emoji.location, NSNotFound)
            let edits: [(String, String)] = [
                ("замена эмодзи на другое (общая старшая половина пары)", edit(text, at: emoji.location, removing: 2, inserting: "😁")),
                ("вставка перед эмодзи", edit(text, at: emoji.location, inserting: "ё")),
                ("вставка после эмодзи", edit(text, at: emoji.location + 2, inserting: "👍🏽")),
                ("удаление эмодзи", edit(text, at: emoji.location, removing: 2, inserting: "")),
                ("правка CJK", edit(text, at: cjk.location + 1, removing: 1, inserting: "文字")),
            ]
            for (what, edited) in edits {
                let result = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
                XCTAssertTrue(result.usedLocal, "\(name), \(what): \(result.fallbackReason ?? "")")
                assertSame(result, edited, "\(name), \(what)")
            }
        }
    }

    /// Одинаковые заголовки по обе стороны правки: оформление не должно разойтись с полным разбором (суффиксы -1/-2 считаются по всем заголовкам).
    func testRepeatedHeadingsOnBothSidesOfEditMatchFullParse() {
        let text = (0..<30).map { _ in "# Повтор\n\nАбзац текста для заголовка.\n\n" }.joined()
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        let source = text as NSString
        let paragraph = source.range(of: "Абзац", options: [], range: NSRange(location: source.length / 2, length: source.length / 2 - 1))
        let heading = source.range(of: "Повтор", options: [], range: NSRange(location: source.length / 2, length: source.length / 2 - 1))
        let cases = [("правка абзаца", edit(text, at: paragraph.location + 5, inserting: "ы")),
                     ("правка заголовка", edit(text, at: heading.location + 6, inserting: "ы")),
                     ("вставка заголовка", edit(text, at: paragraph.location, inserting: "# Повтор\n\n"))]
        for (what, edited) in cases {
            let result = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
            assertSame(result, edited, what)
            XCTAssertEqual(prepared(result.presentation).headings.count, what == "вставка заголовка" ? 31 : 30, what)
        }
    }

    /// Пара `%%` или критика охватывает окно правки, не имея в нём знаков: в заметке хранилища - полный разбор, в обычной `%%` не мешает.
    func testMaskPairSpanningTheWindowFallsBackToFullParse() {
        let text = plainChapters(20)
        let source = text as NSString
        let vault = MarkdownParseOptions(includeReadableText: true, includeEmojiCandidates: true, includeUppercaseRuns: true, isVaultNote: true)
        let first = source.range(of: "Абзац").location
        let last = source.range(of: "Конец главы.", options: .backwards).location
        let marked = edit(edit(text, at: last, inserting: "%%"), at: first, inserting: "%%")
        let middle = source.length / 2
        let spot = (marked as NSString).range(of: "жирный", options: [], range: NSRange(location: middle, length: middle - 1)).location
        let edited = edit(marked, at: spot, inserting: "x")
        for (name, opts, local) in [("заметка хранилища", vault, false), ("обычная заметка", options, true)] {
            let base = MarkdownLocalParser.parse(marked, options: opts, base: nil, minimumLength: 0).base
            let result = MarkdownLocalParser.parse(edited, options: opts, base: base, minimumLength: 0)
            XCTAssertEqual(result.usedLocal, local, "\(name): \(result.fallbackReason ?? "")")
            let full = MarkdownLocalParser.parse(edited, options: opts, base: nil, minimumLength: 0)
            XCTAssertNil(MarkdownPresentation.firstDifference(prepared(result.presentation), prepared(full.presentation)), name)
        }
        // Критик: пара `{++ … ++}` через несколько блоков, правка внутри.
        let critic = "{++ a\n\n# h1\n\n# h2\n\n# h3\n\nb ++}\n\n" + plainChapters(20)
        let criticBase = MarkdownLocalParser.parse(critic, options: options, base: nil, minimumLength: 0).base
        let h2 = (critic as NSString).range(of: "# h2").location + 3
        let criticEdited = edit(critic, at: h2, inserting: "x")
        let criticResult = MarkdownLocalParser.parse(criticEdited, options: options, base: criticBase, minimumLength: 0)
        XCTAssertEqual(criticResult.fallbackReason, "в тексте разметка критика или «%%»")
        assertSame(criticResult, criticEdited, "правка внутри пары критика")
    }

    /// Многострочные абзацы (мягкий перенос, \r\n внутри абзаца, кириллица): результат равен полному разбору.
    /// На Linux локальный путь здесь может отказывать из-за узлов без подтверждённой позиции, поэтому `usedLocal` не требуется; на Mac проверить отдельно.
    func testMultilineParagraphsMatchFullParse() {
        for newline in ["\n", "\r\n"] {
            let text = chapters(12).replacingOccurrences(of: "\n", with: newline)
            let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
            let source = text as NSString
            let second = source.range(of: "Вторая строка", options: [], range: NSRange(location: source.length / 2, length: source.length / 2 - 1))
            for (what, edited) in [("вставка в первую строку", edit(text, at: second.location - 3, inserting: "ы")),
                                   ("вставка во вторую строку", edit(text, at: second.location + 3, inserting: "ё")),
                                   ("удаление переноса", edit(text, at: second.location - newline.utf16.count, removing: newline.utf16.count, inserting: " "))] {
                assertSame(MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0), edited, "\(what), \(newline.debugDescription)")
            }
        }
    }

    /// Незакрытое ограждение кода, набранное посреди документа, поглощает остальной текст: граница контекста не сходится, разбор полный.
    func testOpeningFenceSwallowingTheRestFallsBack() {
        let text = chapters(12)
        let base = MarkdownLocalParser.parse(text, options: options, base: nil, minimumLength: 0).base
        let range = (text as NSString).range(of: "Абзац", options: [], range: NSRange(location: text.utf16.count / 2, length: text.utf16.count / 2 - 1))
        let edited = edit(text, at: range.location, inserting: "```\n")
        let result = MarkdownLocalParser.parse(edited, options: options, base: base, minimumLength: 0)
        assertSame(result, edited, "открытое ограждение")
    }

    func testFirstDifferenceDetectsChangesAndIgnoresEqual() {
        let first = prepared(MarkdownLocalParser.parse("# A\n\ntext **b**\n", options: options, base: nil, minimumLength: 0).presentation)
        let same = prepared(MarkdownLocalParser.parse("# A\n\ntext **b**\n", options: options, base: nil, minimumLength: 0).presentation)
        let other = prepared(MarkdownLocalParser.parse("# A\n\ntext *b*\n", options: options, base: nil, minimumLength: 0).presentation)
        XCTAssertNil(MarkdownPresentation.firstDifference(first, same))
        XCTAssertNotNil(MarkdownPresentation.firstDifference(first, other))
    }

    /// Список сравниваемых полей обязан совпадать с настоящими свойствами оформления: новое поле нельзя забыть в сверке.
    func testComparedFieldsCoverEveryPresentationProperty() {
        let labels = Set(Mirror(reflecting: MarkdownPresentation(spans: [])).children.compactMap(\.label))
        XCTAssertEqual(labels, Set(MarkdownPresentation.comparedFields))
    }
}

/// Считает запросы картинки: локальный разбор не должен приводить к повторной загрузке готовой картинки.
private final class CountingImageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = 0
    static var requestCount: Int { lock.withLock { started } }
    static func reset() { lock.withLock { started = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.started += 1 }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Локальный разбор в контроллере (T5): база, сброс, поздние результаты, картинки. Стенд повторяет `ImageShiftFixture` из MarkdownImageTests.
@MainActor
final class MarkdownLocalParseControllerTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let storage: NSTextStorage
        let layout = FoldLayoutManager()
        let controller: MarkdownPresentationController
        let document: EditorDocument
        private let view: LacTextView
        private let scroll: NSScrollView
        private let window: NSWindow
        var revision: UInt = 0
        var parseCount = 0

        init(source: String, session: URLSession) {
            _ = NSApplication.shared
            document = EditorDocument(text: source, language: .markdown)
            document.allowsRemoteImages = true
            storage = NSTextStorage(string: source)
            storage.addLayoutManager(layout)
            let container = NSTextContainer(containerSize: NSSize(width: 400, height: 600))
            layout.addTextContainer(container)
            view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), textContainer: container)
            scroll = NSScrollView(frame: view.frame)
            scroll.documentView = view
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            controller = MarkdownPresentationController(textView: view, layout: layout)
            controller.imageSession = session
            controller.localParseMinimumLength = 0
            controller.update(document: document, enabled: true, isActive: true, revision: 0,
                              currentRevision: { [unowned self] in self.revision },
                              textProvider: { [unowned self] in self.storage.string })
            controller.parsedResultDidChange = { [unowned self] in self.parseCount += 1 }
            view.string = source
            view.layoutSubtreeIfNeeded()
            layout.ensureLayout(for: container)
            controller.viewportChanged()
        }

        nonisolated deinit { MainActor.assumeIsolated { window.close() } }

        /// Печать тем же путём, что в редакторе: `beforeEdit`, правка текста, `edited`.
        func type(after marker: String, _ text: String = "x") {
            let edit = NSRange(location: NSMaxRange(storage.mutableString.range(of: marker)), length: 0)
            revision += 1
            controller.beforeEdit(range: edit, replacementLength: (text as NSString).length, replacement: text)
            view.replaceCharacters(in: edit, with: text)
            if storage.string != view.string { storage.replaceCharacters(in: edit, with: text) }
            controller.edited(revision: revision)
        }

        /// Ждёт установки ещё одного разбора: опрос с пределом 100 x 100 мс.
        func waitForNextParse() async -> Bool {
            let target = parseCount + 1
            for _ in 0..<100 where parseCount < target { try? await Task.sleep(for: .milliseconds(100)) }
            return parseCount >= target
        }

        func finish() { controller.cancel(); withExtendedLifetime(scroll) {} }
    }

    private func assertNextParse(_ fixture: Fixture, _ message: String = "разбор не завершился", file: StaticString = #filePath, line: UInt = #line) async {
        let didParse = await fixture.waitForNextParse()
        XCTAssertTrue(didParse, message, file: file, line: line)
    }

    private func makeFixture() -> (Fixture, URLSession) {
        CountingImageURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CountingImageURLProtocol.self]
        let session = URLSession(configuration: config)
        let chapter = (0..<10).map { "# Раздел \($0)\n\nАбзац **жирный** номер \($0).\n\n- пункт\n- другой\n\n" }.joined()
        // Картинка в начале (в видимой области, её загрузка идёт сразу), правки ниже и далеко: участок разбора её не включает.
        return (Fixture(source: "![x](https://8.8.8.8/image.png)\n\n" + chapter, session: session), session)
    }

    /// Серия правок идёт локально, сверка не находит расхождений, готовая картинка не загружается повторно.
    func testLocalParseSeriesKeepsImageAndHasNoDivergence() async throws {
        let (fixture, session) = makeFixture()
        defer { fixture.finish(); session.invalidateAndCancel() }
        await assertNextParse(fixture, "первый разбор")
        for _ in 0..<100 where CountingImageURLProtocol.requestCount == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(CountingImageURLProtocol.requestCount, 1)
        var localCount = 0
        for index in 2..<7 {
            fixture.type(after: "Раздел \(index)")
            await assertNextParse(fixture, "разбор после правки \(index)")
            XCTAssertNil(fixture.controller.lastParseDivergence, "сверка нашла расхождение после правки \(index)")
            if fixture.controller.lastParseFallback == nil { localCount += 1 }
        }
        XCTAssertGreaterThan(localCount, 0, "хотя бы одна правка посреди документа должна разобраться локально")
        XCTAssertEqual(CountingImageURLProtocol.requestCount, 1, "локальный разбор не должен перезагружать картинку")
    }

    /// Смена параметров разбора и сброс оформления (`clear()`) обнуляют базу: следующий разбор полный.
    func testOptionChangeAndClearResetBase() async throws {
        let (fixture, session) = makeFixture()
        defer { fixture.finish(); session.invalidateAndCancel() }
        await assertNextParse(fixture)
        fixture.type(after: "Раздел 1")
        await assertNextParse(fixture)
        XCTAssertNil(fixture.controller.lastParseFallback, "перед проверкой база должна работать")
        // Читаемый текст выключен: параметры разбора другие, база прежняя не подходит.
        fixture.document.featureOverrides.wordCount = false
        fixture.type(after: "Раздел 2")
        await assertNextParse(fixture)
        XCTAssertEqual(fixture.controller.lastParseFallback, "параметры разбора изменились")
        // Оформление отключено и включено снова: `clear()` сбросил базу.
        fixture.controller.update(document: fixture.document, enabled: false, isActive: true, revision: fixture.revision,
                                  currentRevision: { [unowned fixture] in fixture.revision }, textProvider: { [unowned fixture] in fixture.storage.string })
        fixture.controller.update(document: fixture.document, enabled: true, isActive: true, revision: fixture.revision,
                                  currentRevision: { [unowned fixture] in fixture.revision }, textProvider: { [unowned fixture] in fixture.storage.string })
        fixture.type(after: "Раздел 3")
        await assertNextParse(fixture)
        XCTAssertEqual(fixture.controller.lastParseFallback, "нет базы")
    }

    /// Разбор, чья ревизия устарела до запуска, не применяется и базу не трогает.
    func testStaleRevisionDoesNotInstallOrChangeBase() async throws {
        let (fixture, session) = makeFixture()
        defer { fixture.finish(); session.invalidateAndCancel() }
        await assertNextParse(fixture)
        fixture.type(after: "Раздел 1")
        await assertNextParse(fixture)
        let before = fixture.controller.lastParseFallback
        let count = fixture.parseCount
        fixture.type(after: "Раздел 2")
        fixture.revision += 1
        // Отсутствие результата доказать можно только ожиданием: 20 x 100 мс, пауза разбора после правки меньше секунды.
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(fixture.parseCount, count, "устаревший разбор не должен устанавливаться")
        XCTAssertEqual(fixture.controller.lastParseFallback, before)
        // Правка с верной ревизией после этого: база цела, разбор снова локальный.
        fixture.type(after: "Раздел 3")
        await assertNextParse(fixture)
        XCTAssertNil(fixture.controller.lastParseFallback, "база не должна пострадать от устаревшего разбора")
        XCTAssertNil(fixture.controller.lastParseDivergence)
    }

    /// `fullParseCount` растёт только от установленных полных разборов: локальный и устаревший его не меняют.
    func testFullParseCountGrowsOnlyOnInstalledFullParses() async throws {
        let (fixture, session) = makeFixture()
        defer { fixture.finish(); session.invalidateAndCancel() }
        await assertNextParse(fixture, "первый разбор")
        XCTAssertEqual(fixture.controller.fullParseCount, 1, "первый разбор без базы полный")
        fixture.type(after: "Раздел 1")
        await assertNextParse(fixture, "локальная правка")
        XCTAssertNil(fixture.controller.lastParseFallback, "перед проверкой база должна работать")
        XCTAssertEqual(fixture.controller.fullParseCount, 1, "локальный разбор не считается")
        let count = fixture.parseCount
        fixture.type(after: "Раздел 2")
        fixture.revision += 1
        // Отсутствие результата доказать можно только ожиданием: 20 x 100 мс.
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(fixture.parseCount, count, "устаревший разбор не должен устанавливаться")
        XCTAssertEqual(fixture.controller.fullParseCount, 1, "устаревший результат не считается")
        fixture.document.featureOverrides.wordCount = false
        fixture.type(after: "Раздел 3")
        await assertNextParse(fixture, "разбор после смены параметров")
        XCTAssertEqual(fixture.controller.lastParseFallback, "параметры разбора изменились")
        XCTAssertEqual(fixture.controller.fullParseCount, 2, "полный откат считается")
    }

    /// Модель документа публикуется только после установленного полного разбора: локальный её не ставит, поздний результат тоже.
    func testModelIsPublishedOnlyAfterInstalledFullParse() async throws {
        let (fixture, session) = makeFixture()
        defer { fixture.finish(); session.invalidateAndCancel() }
        await assertNextParse(fixture, "первый разбор")
        XCTAssertNotNil(fixture.document.markdownModel(forRevision: fixture.document.textRevision), "после полного разбора модель есть")
        // Редактор записывает набранный текст в документ: прежняя модель сбрасывается.
        fixture.type(after: "Раздел 1")
        fixture.document.text = fixture.storage.string
        XCTAssertNil(fixture.document.markdownModel(forRevision: fixture.document.textRevision))
        await assertNextParse(fixture, "локальный разбор")
        XCTAssertNil(fixture.controller.lastParseFallback, "перед проверкой разбор должен быть локальным")
        XCTAssertNil(fixture.document.markdownModel(forRevision: fixture.document.textRevision), "локальный разбор модель не ставит")
        // Поздний результат гарантированно полного разбора (параметры сменились) модель не ставит: версия устарела до установки.
        let count = fixture.parseCount
        fixture.document.featureOverrides.wordCount = false
        fixture.type(after: "Раздел 2")
        fixture.document.text = fixture.storage.string
        fixture.revision += 1
        // Отсутствие результата доказать можно только ожиданием: 20 x 100 мс.
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(fixture.parseCount, count, "устаревший разбор не должен устанавливаться")
        XCTAssertNil(fixture.document.markdownModel(forRevision: fixture.document.textRevision))
        // Полный разбор (смена параметров) модель ставит снова.
        fixture.document.featureOverrides.wordCount = false
        fixture.type(after: "Раздел 3")
        fixture.document.text = fixture.storage.string
        await assertNextParse(fixture, "полный разбор")
        XCTAssertEqual(fixture.controller.lastParseFallback, "параметры разбора изменились")
        XCTAssertNotNil(fixture.document.markdownModel(forRevision: fixture.document.textRevision), "полный разбор ставит модель")
    }

    /// Документ с токенами media (непустая карта): модель не публикуется, разбор по-прежнему считается.
    func testModelIsNotPublishedWithMediaTokens() async throws {
        let (fixture, session) = makeFixture()
        defer { fixture.finish(); session.invalidateAndCancel() }
        let projection = EditorDocument(text: "", language: .markdown).mediaTable.project("![a](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==)")
        let map = MarkdownMediaMap(spans: projection.spans)
        XCTAssertFalse(map.isEmpty)
        fixture.controller.sourceMap = { map }
        await assertNextParse(fixture, "первый разбор")
        XCTAssertEqual(fixture.controller.fullParseCount, 1)
        XCTAssertNil(fixture.document.markdownModel(forRevision: fixture.document.textRevision))
    }

    /// Видимая панель предпросмотра сама просит разбор ради модели, даже когда оформление редактора выключено.
    func testVisiblePreviewRequestsModelWithoutDecoration() async throws {
        let (fixture, session) = makeFixture()
        defer { fixture.finish(); session.invalidateAndCancel() }
        await assertNextParse(fixture, "первый разбор")
        fixture.controller.update(document: fixture.document, enabled: false, isActive: true, revision: fixture.revision,
                                  currentRevision: { [unowned fixture] in fixture.revision }, textProvider: { [unowned fixture] in fixture.storage.string })
        fixture.document.featureOverrides.preview = true
        let notified = fixture.parseCount
        fixture.type(after: "Раздел 1")
        fixture.document.text = fixture.storage.string
        for _ in 0..<40 where fixture.document.markdownModel(forRevision: fixture.document.textRevision) == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(fixture.document.markdownModel(forRevision: fixture.document.textRevision), "панель получила модель")
        XCTAssertEqual(fixture.parseCount, notified, "разбор только ради модели не оповещает о результате")
    }
}
