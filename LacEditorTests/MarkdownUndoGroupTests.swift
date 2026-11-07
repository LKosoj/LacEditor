import AppKit
import XCTest
@testable import LacEditor

/// T9: одна визуальная операция - одна запись отмены (один Cmd-Z). Команды идут через настоящий путь `formatMarkdown` и `insertNewline`.
/// Стенд и ожидание разбора - как в `MarkdownVisualFormattingInteractionTests`.
@MainActor
final class MarkdownUndoGroupTests: XCTestCase {
    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }
        var undo: UndoManager? { view.undoManager }

        func ignoredRanges() -> [NSRange] {
            coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: shown.length)).map(\.rangeValue)
        }

        func format(_ command: MarkdownFormattingCommand) {
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                                            object: MarkdownFormattingRequest(documentID: document.id, command: command))
        }
    }

    private func makeEditor(_ source: String, formatted: Bool = true) -> Editor {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = formatted
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text))
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 400))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
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
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return Editor(document: document, coordinator: coordinator, view: view, window: window)
    }

    private func finish(_ editor: Editor) { editor.coordinator.updateActivity(false); editor.window.close() }

    private func waitForParse(_ editor: Editor) async throws {
        for _ in 0..<30 where editor.ignoredRanges().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(editor.ignoredRanges().isEmpty, "разбор Markdown не успел завершиться")
    }

    /// Ровно одна отмена возвращает текст и выделение, больше отменять нечего; повтор возвращает результат.
    private func assertOneUndo(_ editor: Editor, original: String, changed: String, selection: NSRange, message: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let undo = try XCTUnwrap(editor.undo, message, file: file, line: line)
        undo.undo()
        XCTAssertEqual(editor.document.synchronizedText(), original, message, file: file, line: line)
        XCTAssertEqual(editor.view.selectedRange(), selection, "\(message): выделение после отмены", file: file, line: line)
        XCTAssertFalse(undo.canUndo, "\(message): правка должна отменяться одной записью", file: file, line: line)
        undo.redo()
        XCTAssertEqual(editor.document.synchronizedText(), changed, message, file: file, line: line)
    }

    // MARK: 1.1 Cmd-B

    func testBoldInFormattedModeIsOneUndoAndRestoresSelection() async throws {
        let source = "Привет мир 😀\r\nвторая строка"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let word = editor.shown.range(of: "мир")
        editor.view.setSelectedRange(word)
        editor.format(.bold)
        let changed = "Привет **мир** 😀\r\nвторая строка"
        XCTAssertEqual(editor.document.synchronizedText(), changed)
        XCTAssertEqual(editor.undo?.undoActionName, L10n.tr("加粗"))
        try assertOneUndo(editor, original: source, changed: changed, selection: word, message: "加粗")
    }

    // MARK: 1.2 Ссылка

    func testLinkCommandIsOneUndoWithSelectionOnLabel() async throws {
        let source = "Привет мир 😀"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let word = editor.shown.range(of: "мир")
        editor.view.setSelectedRange(word)
        editor.format(.link(MarkdownLinkInput(label: "мир", address: "https://example.com")))
        let changed = "Привет [мир](<https://example.com>) 😀"
        XCTAssertEqual(editor.document.synchronizedText(), changed)
        XCTAssertEqual(editor.shown.substring(with: editor.view.selectedRange()), "мир", "выделена подпись ссылки")
        XCTAssertEqual(editor.undo?.undoActionName, L10n.tr("链接"))
        try assertOneUndo(editor, original: source, changed: changed, selection: word, message: "链接")
    }

    // MARK: 1.3 Enter в списке

    // Нумерованный список в оформленном режиме: новый пункт и перенумерация следующих - одна отмена.
    func testListContinuationAndRenumberAreOneUndoInFormattedMode() async throws {
        let source = "1. a\n2. b\n"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 4, length: 0))
        editor.view.insertNewline(nil)
        let changed = "1. a\n2. \n3. b\n"
        for _ in 0..<30 where editor.document.synchronizedText() != changed { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(editor.document.synchronizedText(), changed)
        let undo = try XCTUnwrap(editor.undo)
        undo.undo()
        XCTAssertEqual(editor.document.synchronizedText(), source)
        XCTAssertFalse(undo.canUndo, "Enter с перенумерацией должен отменяться одной записью")
        undo.redo()
        XCTAssertEqual(editor.document.synchronizedText(), changed)
    }

    // Пустой пункт: Enter убирает маркер (выход из списка) одной отменой, кириллица и CJK в соседнем пункте не мешают.
    func testEmptyListItemExitIsOneUndo() async throws {
        let source = "- 中文 😀\n- "
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: editor.shown.length, length: 0))
        editor.view.insertNewline(nil)
        XCTAssertEqual(editor.document.synchronizedText(), "- 中文 😀\n")
        let undo = try XCTUnwrap(editor.undo)
        undo.undo()
        XCTAssertEqual(editor.document.synchronizedText(), source)
        XCTAssertFalse(undo.canUndo, "выход из списка должен отменяться одной записью")
        undo.redo()
        XCTAssertEqual(editor.document.synchronizedText(), "- 中文 😀\n")
    }

    // MARK: 1.5 Таблица

    private let tableSource = "| A | B |\n| --- | --- |\n| one | two |\n| три | 中文 |"

    /// Команды таблицы из активной ячейки (как в `testFormattingUsesActiveCellSelectionAndUndo`): строки и столбцы - одна отмена.
    func testEveryTableCommandIsOneUndoFromActiveCell() throws {
        let alwaysChange: [MarkdownTableCommand] = [
            .insertRowBefore, .insertRowAfter, .deleteRow, .moveRowUp,
            .insertColumnBefore, .insertColumnAfter, .deleteColumn, .moveColumnLeft
        ]
        let others: [MarkdownTableCommand] = [.moveRowDown, .moveColumnRight, .align(.center), .align(.right)]
        for command in alwaysChange + others {
            let editor = makeEditor(tableSource)
            defer { finish(editor) }
            let cellRange = (tableSource as NSString).range(of: "中文")
            XCTAssertTrue(editor.coordinator.beginTableCell(cellRange, frame: NSRect(x: 0, y: 0, width: 120, height: 30)), "\(command)")
            editor.format(.table(command))
            let undo = try XCTUnwrap(editor.undo)
            if alwaysChange.contains(command) { XCTAssertNotEqual(editor.view.string, tableSource, "\(command)") }
            if editor.view.string == tableSource {
                XCTAssertFalse(undo.canUndo, "\(command): отказ не оставляет записи отмены")
                continue
            }
            let changed = editor.view.string
            undo.undo()
            XCTAssertEqual(editor.view.string, tableSource, "\(command)")
            XCTAssertFalse(undo.canUndo, "\(command): одна запись отмены")
            undo.redo()
            XCTAssertEqual(editor.view.string, changed, "\(command)")
        }
    }

    // MARK: 1.7 Форматирование нескольких абзацев

    func testEveryFormattingCommandIsOneUndoOnMultiParagraphSelection() async throws {
        let source = "Первый абзац 😀\r\n\r\nВторой абзац 中文\r\n"
        let commands: [MarkdownFormattingCommand] = [
            .bold, .italic, .strikethrough, .inlineCode, .inlineMath, .blockMath,
            .heading(2), .quote, .bulletList, .numberedList, .taskList, .fencedCode, .horizontalRule
        ]
        var changedAny = false
        for command in commands {
            let editor = makeEditor(source)
            defer { finish(editor) }
            try await waitForParse(editor)
            let start = editor.shown.range(of: "абзац").location
            let end = NSMaxRange(editor.shown.range(of: "Второй"))
            let selection = NSRange(location: start, length: end - start)
            editor.view.setSelectedRange(selection)
            editor.format(command)
            let undo = try XCTUnwrap(editor.undo)
            // Строчные команды через несколько блоков отказывают (T4): отказ не оставляет записи отмены.
            if editor.document.synchronizedText() == source {
                XCTAssertFalse(undo.canUndo, "\(command): отказ не оставляет записи отмены")
                continue
            }
            changedAny = true
            let changed = editor.document.synchronizedText()
            undo.undo()
            XCTAssertEqual(editor.document.synchronizedText(), source, "\(command)")
            XCTAssertEqual(editor.view.selectedRange(), selection, "\(command): выделение после отмены")
            XCTAssertFalse(undo.canUndo, "\(command): одна запись отмены")
            undo.redo()
            XCTAssertEqual(editor.document.synchronizedText(), changed, "\(command)")
        }
        XCTAssertTrue(changedAny, "хотя бы блочные команды должны менять текст")
    }

    func testPlainTextCommandOnSeveralBlocksIsOneUndo() async throws {
        let source = "## Заг 😀\n\n> цитата 中文"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let selection = NSRange(location: 0, length: editor.shown.length)
        editor.view.setSelectedRange(selection)
        editor.format(.plainText)
        let changed = "Заг 😀\n\nцитата 中文"
        XCTAssertEqual(editor.document.synchronizedText(), changed)
        XCTAssertEqual(editor.undo?.undoActionName, L10n.tr("普通文本"))
        try assertOneUndo(editor, original: source, changed: changed, selection: selection, message: "普通文本")
    }
}
