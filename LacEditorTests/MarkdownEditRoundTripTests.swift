import AppKit
import XCTest
@testable import LacEditor

/// Сквозные проверки T11: цикл «source → оформленный вид → правка → source» на эталонных документах и повтор команд форматирования.
/// Стенд, ожидание разбора и версия текста - как в `MarkdownEditTransactionTests` и `MarkdownVisualFormattingInteractionTests`.
/// Диапазоны презентации напрямую недоступны, поэтому после правки сравнивается карта защищённых диапазонов (`ignoredRanges`)
/// с картой свежего редактора на том же тексте. Сверка локального и полного разбора - в `MarkdownLocalParseTests`.
@MainActor
final class MarkdownEditRoundTripTests: XCTestCase {
    private typealias T = MarkdownEditTransaction

    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }
        var undo: UndoManager? { view.undoManager }

        /// Версия текста редактора: `contentRevision` закрыт, поэтому берём её тем же путём, что ИИ и сниппеты.
        func revision() throws -> UInt {
            let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false, allowsWholeDocument: true)
            NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
            return try XCTUnwrap(request.result).editorRevision
        }

        func ignoredRanges() -> [NSRange] {
            coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: shown.length)).map(\.rangeValue)
        }

        func format(_ command: MarkdownFormattingCommand) {
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                                            object: MarkdownFormattingRequest(documentID: document.id, command: command))
        }

        /// Текст файла (UTF-16) и признак «есть несохранённые изменения» после обязательной синхронизации модели.
        func fileText() -> String { document.synchronizedText() }

        func isDirty() -> Bool {
            coordinator.flushModelText(reconcileDirtyState: true)
            return document.isDirty
        }

        func setFormatted(_ formatted: Bool) {
            document.isMarkdownFormatted = formatted
            coordinator.updateMarkdownPresentation()
        }
    }

    private func makeEditor(_ source: String, formatted: Bool) -> Editor {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = formatted
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text))
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        // Без окна у NSTextView нет undoManager.
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        view.allowsUndo = true
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.attachLiveTextProvider()
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        return Editor(document: document, coordinator: coordinator, view: view, window: window)
    }

    private func finish(_ editor: Editor) { editor.coordinator.updateActivity(false); editor.window.close() }

    /// Ждёт, пока Writing Tools получит карту текста (то есть готов разбор Markdown).
    private func waitForParse(_ editor: Editor, _ message: String = "") async throws {
        for _ in 0..<30 where editor.ignoredRanges().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(editor.ignoredRanges().isEmpty, "\(message): разбор Markdown не успел завершиться")
    }

    /// Сравнение по UTF-16 без огромного diff в отчёте.
    private func assertSameText(_ actual: String, _ expected: String, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual.utf16.elementsEqual(expected.utf16),
                      "\(message): текст не совпал (UTF-16: \(actual.utf16.count) вместо \(expected.utf16.count))", file: file, line: line)
    }

    // MARK: Эталонные документы

    /// Первые две таблицы D4 (целиком 3000 строк не нужно: окно и TextKit на них сильно тормозят).
    private func tablesSlice() throws -> String {
        let parts = try MarkdownBaselineDocuments.tables().components(separatedBy: "\r\n\r\n")
        return parts.prefix(3).joined(separator: "\r\n\r\n") + "\r\n"
    }

    // MARK: Цикл «source → formatted → правка → source»

    private enum Action {
        /// Замена выделенного (вставка - пустое выделение, удаление - пустая замена) через `perform(.formatting)`.
        case replace(String)
        /// Команда форматирования через уведомление; `insertion` - что должно встать на место выделения;
        /// `selectionShift` - где ожидается выделение после команды (смещение от начала и длина), nil - не проверять.
        case command(MarkdownFormattingCommand, insertion: String, selectionShift: (Int, Int)?)
    }

    private struct Case {
        let name: String
        let source: () throws -> String
        let target: (NSString) -> NSRange
        let action: Action
        /// В таблице выделение переносит редактор ячейки: его не сверяем.
        var checksSelection = true
    }

    private func word(_ text: String, offset: Int = 0, length: Int? = nil) -> (NSString) -> NSRange {
        { shown in
            let range = shown.range(of: text)
            if range.location == NSNotFound { XCTFail("в документе нет «\(text)»") }
            return NSRange(location: range.location + offset, length: length ?? range.length)
        }
    }

    private func caret(before text: String) -> (NSString) -> NSRange { word(text, length: 0) }
    private func caret(after text: String) -> (NSString) -> NSRange { word(text, offset: (text as NSString).length, length: 0) }

    /// Один полный цикл по плану T11 (шаги 1-6). Каждый шаг - assert с сообщением «документ/правка/шаг».
    private func runRoundTrip(_ item: Case) async throws {
        let source = try item.source()
        let name = item.name
        let editor = makeEditor(source, formatted: false)
        defer { finish(editor) }

        // 1. Открыт source: текст файла как есть, документ чистый, отмены нет.
        assertSameText(editor.fileText(), source, "\(name)/открытие в source")
        XCTAssertFalse(editor.isDirty(), "\(name)/открытие в source: документ чистый")

        // 2. Оформленный вид без правок ничего не меняет.
        editor.setFormatted(true)
        try await waitForParse(editor, "\(name)/оформленный вид")
        assertSameText(editor.fileText(), source, "\(name)/оформленный вид без правок")
        XCTAssertFalse(editor.isDirty(), "\(name)/оформленный вид без правок: документ чистый")
        XCTAssertEqual(editor.undo?.canUndo, false, "\(name)/оформленный вид без правок: отмены нет")

        // 3. Правка в оформленном виде.
        let before = editor.shown
        let target = item.target(before)
        XCTAssertLessThanOrEqual(NSMaxRange(target), before.length, "\(name)/правка: диапазон внутри текста")
        editor.view.setSelectedRange(target)
        let expected: String
        let expectedSelection: NSRange?
        let actionName: String
        switch item.action {
        case let .replace(replacement):
            var transaction = T(.formatting, range: target, replacement: replacement)
            transaction.expectedRevision = try editor.revision()
            transaction.expectedOriginal = before.substring(with: target)
            transaction.selectionBefore = target
            let caret = NSRange(location: target.location + (replacement as NSString).length, length: 0)
            transaction.selectionAfter = caret
            transaction.actionName = "правка"
            XCTAssertEqual(editor.coordinator.perform(transaction),
                           .applied(NSRange(location: target.location, length: (replacement as NSString).length)), "\(name)/правка: применена")
            expected = before.replacingCharacters(in: target, with: replacement)
            expectedSelection = caret
            actionName = "правка"
        case let .command(command, insertion, shift):
            editor.format(command)
            expected = before.replacingCharacters(in: target, with: insertion)
            expectedSelection = shift.map { NSRange(location: target.location + $0.0, length: $0.1) }
            actionName = command.actionName
        }
        assertSameText(editor.shown as String, expected, "\(name)/правка: текст редактора")
        assertSameText(editor.fileText(), expected, "\(name)/правка: текст файла")
        if item.checksSelection, let expectedSelection {
            XCTAssertEqual(editor.view.selectedRange(), expectedSelection, "\(name)/правка: выделение")
        }
        XCTAssertTrue(editor.isDirty(), "\(name)/правка: документ изменён")
        XCTAssertEqual(editor.undo?.undoActionName, actionName, "\(name)/правка: имя действия отмены")
        let selectionAfterEdit = editor.view.selectedRange()

        // 4. Возврат в source: текст, выделение, признак изменения и история отмены не меняются.
        editor.setFormatted(false)
        assertSameText(editor.fileText(), expected, "\(name)/возврат в source: текст")
        XCTAssertEqual(editor.view.selectedRange(), selectionAfterEdit, "\(name)/возврат в source: выделение")
        XCTAssertTrue(editor.isDirty(), "\(name)/возврат в source: документ изменён")
        XCTAssertEqual(editor.undo?.canUndo, true, "\(name)/возврат в source: отмена сохранилась")

        // 5. Снова оформленный вид: скрытые маркеры такие же, как при свежем открытии того же текста.
        editor.setFormatted(true)
        try await assertPresentationMatchesFreshOpen(editor, "\(name)/презентация после возврата")

        // 6. Отмена возвращает исходный текст, выделение и чистое состояние одной записью; повтор возвращает правку.
        let undo = try XCTUnwrap(editor.undo, "\(name)/отмена: есть undoManager")
        undo.undo()
        assertSameText(editor.fileText(), source, "\(name)/отмена: текст")
        XCTAssertEqual(editor.view.selectedRange(), target, "\(name)/отмена: выделение до правки")
        XCTAssertFalse(editor.isDirty(), "\(name)/отмена: документ снова чистый")
        XCTAssertFalse(undo.canUndo, "\(name)/отмена: правка отменяется одной записью")
        undo.redo()
        assertSameText(editor.fileText(), expected, "\(name)/повтор: текст")
        XCTAssertTrue(editor.isDirty(), "\(name)/повтор: документ изменён")
    }

    /// Защищённые диапазоны (скрытые маркеры, замены, исключённые части) после правок совпадают с картой свежего редактора.
    /// Выделение ставится в начало, как у свежего: раскрытие маркеров у каретки на карту не влияет.
    private func assertPresentationMatchesFreshOpen(_ editor: Editor, _ message: String) async throws {
        let text = editor.fileText()
        let fresh = makeEditor(text, formatted: true)
        defer { finish(fresh) }
        try await waitForParse(fresh, message)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        let expected = fresh.ignoredRanges()
        var actual = editor.ignoredRanges()
        for _ in 0..<30 where actual != expected {
            try await Task.sleep(for: .milliseconds(100))
            actual = editor.ignoredRanges()
        }
        XCTAssertEqual(actual, expected, message)
    }

    private func runAll(_ cases: [Case]) async throws {
        for item in cases { try await runRoundTrip(item) }
    }

    // E1-E3: заметка D1 (`\r\n`, кириллица, CJK, составные эмодзи).
    func testNoteEditsRoundTrip() async throws {
        let note: () throws -> String = { try MarkdownBaselineDocuments.note() }
        try await runAll([
            Case(name: "D1/E1 вставка в слове", source: note, target: caret(after: "Вв"), action: .replace("ё")),
            Case(name: "D1/E1 вставка перед эмодзи", source: note, target: caret(before: "😀."), action: .replace("中")),
            Case(name: "D1/E2 удаление буквы", source: note, target: word("Вводный", offset: 6, length: 1), action: .replace("")),
            Case(name: "D1/E2 удаление составного эмодзи", source: note, target: word("👨‍👩‍👧"), action: .replace("")),
            Case(name: "D1/E3 жирный", source: note, target: word("Вводный"),
                 action: .command(.bold, insertion: "**Вводный**", selectionShift: (2, 7))),
            Case(name: "D1/E3 курсив", source: note, target: word("абзац"),
                 action: .command(.italic, insertion: "*абзац*", selectionShift: (1, 5))),
            Case(name: "D1/E3 заголовок", source: note, target: caret(before: "Абзац с кириллицей"),
                 action: .command(.heading(2), insertion: "## ", selectionShift: nil)),
            Case(name: "D1/E3 список", source: note, target: caret(before: "Ссылки: [обычная]"),
                 action: .command(.bulletList, insertion: "- ", selectionShift: nil)),
        ])
    }

    // E4: media D2. Правки рядом с картинкой, не задевая её саму (отказ внутри картинки - отдельный тест).
    func testNoteWithMediaEditsRoundTrip() async throws {
        let media: () throws -> String = { try MarkdownBaselineDocuments.noteMedia() }
        try await runAll([
            Case(name: "D2/E4 вставка сразу после картинки", source: media, target: caret(after: "![local](images/pic.png)"),
                 action: .replace(" подпись 中文😀")),
            Case(name: "D2/E4 вставка перед картинкой", source: media, target: caret(before: "![local](images/pic.png)"),
                 action: .replace("Ё")),
            Case(name: "D2/E1 вставка в тексте после media", source: media, target: caret(before: "Конец media-блока"),
                 action: .replace("Вот: ")),
        ])
    }

    // E5: таблицы D4 (срез). Правка ячейки как обычного текста.
    func testTableCellEditsRoundTrip() async throws {
        let slice = try tablesSlice()
        let tables: () throws -> String = { slice }
        try await runAll([
            Case(name: "D4/E5 замена текста ячейки", source: tables, target: word("середина"),
                 action: .replace("центр 中文"), checksSelection: false),
            Case(name: "D4/E5 вставка эмодзи в ячейку", source: tables, target: caret(after: "| a"),
                 action: .replace("😀"), checksSelection: false),
            Case(name: "D4/E2 удаление текста ячейки", source: tables, target: word("первая<br>вторая"),
                 action: .replace(""), checksSelection: false),
        ])
    }

    // E6 и короткие примеры GFM: цитата, список, код, ссылка, жирный, CJK и эмодзи.
    func testShortGFMExamplesEditsRoundTrip() async throws {
        func fixed(_ text: String) -> () throws -> String { { text } }
        try await runAll([
            Case(name: "GFM/цитата", source: fixed("> Цитата 中文\r\n> вторая 😀\r\n"),
                 target: caret(after: "Цитата"), action: .replace("!")),
            Case(name: "GFM/список", source: fixed("- пункт один\r\n- пункт **два** 😀\r\n"),
                 target: word("один"), action: .replace("1")),
            Case(name: "GFM/код", source: fixed("```swift\r\nlet x = 1\r\n```\r\n\r\nпосле **жирный**\r\n"),
                 target: caret(after: "let x = 1"), action: .replace("2")),
            Case(name: "GFM/ссылка", source: fixed("Смотри [ссылку](https://example.invalid/a_b) и `код` 中文😀\r\n"),
                 target: word("ссылку"), action: .replace("ссылки")),
            Case(name: "E6/сразу после открывающих маркеров", source: fixed("Привет **жирный** мир\r\n\r\nконец 中文\r\n"),
                 target: caret(after: "Привет **"), action: .replace("x")),
            Case(name: "E6/удаление последней буквы под маркерами", source: fixed("Привет **жирный** мир\r\n\r\nконец 中文\r\n"),
                 target: word("жирный", offset: 5, length: 1), action: .replace("")),
            Case(name: "GFM/CJK и эмодзи: вставка перед эмодзи", source: fixed("**中文**😀 текст\r\nвторая\r\n"),
                 target: caret(before: "😀"), action: .replace("ж")),
            Case(name: "GFM/CJK и эмодзи: удаление эмодзи", source: fixed("**中文**😀 текст\r\nвторая\r\n"),
                 target: word("😀"), action: .replace("")),
            Case(name: "GFM/жирный на слове в цитате", source: fixed("> Цитата 中文\r\n> вторая 😀\r\n"),
                 target: word("вторая"), action: .command(.bold, insertion: "**вторая**", selectionShift: (2, 6))),
        ])
    }

    // Переключение source -> formatted -> source без правок не меняет ни текст, ни признак изменения, ни историю отмены.
    func testToggleWithoutEditsKeepsTextDirtyAndUndo() async throws {
        let sources = [try MarkdownBaselineDocuments.note(), try MarkdownBaselineDocuments.noteMedia(), try tablesSlice(),
                       "**中文**😀 текст\r\n> цитата\r\n- пункт\r\n"]
        for (index, source) in sources.enumerated() {
            let editor = makeEditor(source, formatted: false)
            defer { finish(editor) }
            let name = "документ \(index + 1)"
            for formatted in [true, false, true, false] {
                editor.setFormatted(formatted)
                if formatted { try await waitForParse(editor, name) }
                assertSameText(editor.fileText(), source, "\(name)/formatted=\(formatted)")
                XCTAssertFalse(editor.isDirty(), "\(name)/formatted=\(formatted): документ чистый")
                XCTAssertEqual(editor.undo?.canUndo, false, "\(name)/formatted=\(formatted): отмены нет")
            }
        }
    }

    // E4/E6: программная вставка (вставка из буфера) не должна начинаться внутри картинки или скрытого маркера.
    // Отказ ничего не меняет, поэтому им же ждём разбора; текст, признак изменения и отмена остаются прежними.
    func testPasteInsideImageOrHiddenMarkerIsRefusedAndNothingChanges() async throws {
        let cases: [(name: String, source: String, inside: (NSString) -> NSRange, elsewhere: String)] = [
            ("картинка", try MarkdownBaselineDocuments.noteMedia(), word("![local](images/pic.png)", offset: 3, length: 1), "Конец media-блока"),
            ("скрытый маркер", "Привет **жирный** мир\r\n\r\nконец 中文\r\n", word("**жирный**", offset: 1, length: 1), "конец"),
        ]
        for item in cases {
            let editor = makeEditor(item.source, formatted: true)
            defer { finish(editor) }
            try await waitForParse(editor, item.name)
            let inside = item.inside(editor.shown)
            func refused() -> Bool {
                switch editor.coordinator.perform(T(.paste, range: inside, replacement: "y")) {
                case .refused(.insideReplacement), .refused(.insideHiddenSyntax): return true
                default: return false
                }
            }
            // Каретка вдали: раскрытый маркер правится, а нужен скрытый.
            editor.view.setSelectedRange(editor.shown.range(of: item.elsewhere))
            for _ in 0..<30 where !refused() { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(refused(), "\(item.name): вставка внутри отклонена")
            assertSameText(editor.fileText(), item.source, "\(item.name): текст не изменился")
            XCTAssertFalse(editor.isDirty(), "\(item.name): документ чистый")
            XCTAssertEqual(editor.undo?.canUndo, false, "\(item.name): записи отмены нет")
        }
    }

    // MARK: Повторное применение команд форматирования

    private enum Repeated {
        /// Повтор снимает: итог равен исходному тексту.
        case removes
        /// Повтор отказывает: текст как после первого применения, в статусе сообщение об ошибке (списки, блок кода, разделитель).
        case refuses
        /// Повтор ничего не меняет, сообщение не проверяется (ссылка: в source отказ с сообщением, в оформленном виде выделение расширяется до ссылки и правка «не изменилась» молча).
        case keeps
    }

    private struct RepeatCase {
        let name: String
        let source: String
        let select: (NSString) -> NSRange
        let command: MarkdownFormattingCommand
        let outcome: Repeated
    }

    private func repeatCases() -> [RepeatCase] {
        let plain = "Привет мир 😀\r\n\r\nвторая 中文\r\n"
        return [
            RepeatCase(name: "жирный", source: "Привет мир 😀\r\nвторая строка", select: word("мир"), command: .bold, outcome: .removes),
            RepeatCase(name: "курсив", source: "Привет мир 😀\r\nвторая строка", select: word("мир"), command: .italic, outcome: .removes),
            RepeatCase(name: "зачёркнутый", source: "Привет мир 😀\r\nвторая строка", select: word("мир"), command: .strikethrough, outcome: .removes),
            RepeatCase(name: "код в строке", source: "Привет мир 😀\r\nвторая строка", select: word("мир"), command: .inlineCode, outcome: .removes),
            RepeatCase(name: "жирный CJK", source: "中文 текст 😀\r\n", select: word("中文"), command: .bold, outcome: .removes),
            RepeatCase(name: "заголовок 2", source: plain, select: caret(before: "Привет"), command: .heading(2), outcome: .removes),
            RepeatCase(name: "цитата", source: plain, select: caret(before: "Привет"), command: .quote, outcome: .removes),
            RepeatCase(name: "маркированный список", source: plain, select: caret(before: "Привет"), command: .bulletList, outcome: .refuses),
            RepeatCase(name: "нумерованный список", source: plain, select: caret(before: "Привет"), command: .numberedList, outcome: .refuses),
            RepeatCase(name: "список задач", source: plain, select: caret(before: "Привет"), command: .taskList, outcome: .refuses),
            RepeatCase(name: "блок кода", source: plain, select: caret(before: "Привет"), command: .fencedCode, outcome: .refuses),
            RepeatCase(name: "разделитель", source: plain, select: { shown in
                NSRange(location: shown.range(of: "\r\n\r\n").location + 2, length: 0)
            }, command: .horizontalRule, outcome: .refuses),
            RepeatCase(name: "ссылка", source: "Привет мир 😀\r\nвторая строка", select: word("мир"),
                       command: .link(MarkdownLinkInput(label: "мир", address: "https://example.com")), outcome: .keeps),
            RepeatCase(name: "обычный текст", source: "## Заголовок 中文\r\n\r\nтекст\r\n", select: caret(before: "Заголовок"),
                       command: .plainText, outcome: .keeps),
        ]
    }

    // Повтор той же команды на её результате: снимает разметку, отказывает с сообщением или не меняет текст; разметка не разрастается (`****x****`, `## ## `).
    // Итог не зависит от режима. Каждая применённая правка - одна запись отмены.
    func testRepeatingFormattingCommandRemovesRefusesOrKeepsAndNeverGrows() async throws {
        for item in repeatCases() {
            for formatted in [true, false] {
                let name = "\(item.name)/formatted=\(formatted)"
                let editor = makeEditor(item.source, formatted: formatted)
                defer { finish(editor) }
                if formatted { try await waitForParse(editor, name) }
                editor.view.setSelectedRange(item.select(editor.shown))

                editor.format(item.command)
                let first = editor.fileText()
                XCTAssertFalse(first.utf16.elementsEqual(item.source.utf16), "\(name)/первое применение меняет текст")

                editor.format(item.command)
                let second = editor.fileText()
                let backToSource = second.utf16.elementsEqual(item.source.utf16)
                let sameAsFirst = second.utf16.elementsEqual(first.utf16)
                switch item.outcome {
                case .removes: XCTAssertTrue(backToSource, "\(name)/повтор снимает разметку")
                case .refuses:
                    XCTAssertTrue(sameAsFirst, "\(name)/повтор не меняет текст")
                    XCTAssertEqual(editor.document.statusMessage, L10n.tr("此处无法应用该格式"), "\(name)/повтор сообщает об отказе")
                case .keeps: XCTAssertTrue(sameAsFirst, "\(name)/повтор не меняет текст")
                }
                XCTAssertTrue(editor.isDirty(), "\(name)/после первой команды документ изменён")

                // Отмена идёт по записям: снятие - две (повтор и первая команда), «не меняет» - одна.
                let undo = try XCTUnwrap(editor.undo, name)
                var steps = 0
                while undo.canUndo && steps < 4 {
                    undo.undo()
                    steps += 1
                    if steps == 1, backToSource { assertSameText(editor.fileText(), first, "\(name)/первая отмена возвращает результат первой команды") }
                }
                XCTAssertEqual(steps, backToSource ? 2 : 1, "\(name)/число записей отмены")
                assertSameText(editor.fileText(), item.source, "\(name)/отмена возвращает исходный текст")
                XCTAssertFalse(editor.isDirty(), "\(name)/после отмены документ чистый")
            }
        }
    }
}
