import AppKit
import XCTest
@testable import LacEditor

/// Визуальное форматирование на стенде координатора: частичное выделение, «Обычный текст», отказы, отмена и контекстное меню.
/// Стенд и ожидание разбора - как в `MarkdownEditTransactionTests`.
@MainActor
final class MarkdownVisualFormattingInteractionTests: XCTestCase {
    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }

        func ignoredRanges() -> [NSRange] {
            coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: shown.length)).map(\.rangeValue)
        }

        func format(_ command: MarkdownFormattingCommand) {
            NotificationCenter.default.post(name: EditorCommandNotification.formatMarkdown,
                                            object: MarkdownFormattingRequest(documentID: document.id, command: command))
        }
    }

    private func makeEditor(_ source: String, formatted: Bool = true, document existing: EditorDocument? = nil) -> Editor {
        _ = NSApplication.shared
        let document = existing ?? EditorDocument(text: source, language: .markdown)
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

    func testPartialBoldAndUndoRestoreTextAndSelection() async throws {
        let editor = makeEditor("**привет мир** 😀\r\nвторая")
        defer { finish(editor) }
        try await waitForParse(editor)
        let source = editor.document.synchronizedText()
        let word = (editor.shown).range(of: "привет")
        editor.view.setSelectedRange(NSRange(location: word.location, length: 3))
        editor.format(.bold)
        XCTAssertEqual(editor.document.synchronizedText(), "при**вет мир** 😀\r\nвторая")
        let undo = try XCTUnwrap(editor.view.undoManager)
        undo.undo()
        XCTAssertEqual(editor.document.synchronizedText(), source)
        XCTAssertEqual(editor.view.selectedRange(), NSRange(location: word.location, length: 3), "отмена возвращает выделение до команды")
        undo.redo()
        XCTAssertEqual(editor.document.synchronizedText(), "при**вет мир** 😀\r\nвторая")
    }

    func testPlainTextRemovesHeadingAndRepeatedCommandChangesNothing() async throws {
        let editor = makeEditor("## Заголовок\n\nтекст")
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 6, length: 0))
        editor.format(.plainText)
        XCTAssertEqual(editor.document.synchronizedText(), "Заголовок\n\nтекст")
        editor.format(.plainText)
        XCTAssertEqual(editor.document.synchronizedText(), "Заголовок\n\nтекст", "повтор ничего не меняет и не сообщает об ошибке")
        XCTAssertNil(editor.document.statusMessage)
    }

    func testRefusalInCodeBlockShowsStatusMessageAndKeepsText() async throws {
        let editor = makeEditor("```\nкод\n```\n\nтекст")
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 4, length: 3))
        editor.format(.bold)
        XCTAssertEqual(editor.document.synchronizedText(), "```\nкод\n```\n\nтекст")
        XCTAssertEqual(editor.document.statusMessage, L10n.tr("此处无法应用该格式"))
        XCTAssertTrue(editor.document.statusMessageIsError)
    }

    func testBlockCommandInTableIsRefused() async throws {
        let table = "| a | b |\n|---|---|\n| c | d |"
        let editor = makeEditor(table)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 2, length: 0))
        editor.format(.heading(2))
        XCTAssertEqual(editor.document.synchronizedText(), table)
        XCTAssertEqual(editor.document.statusMessage, L10n.tr("此处无法应用该格式"))
    }

    // Строчная команда в ячейке идёт через координатор и перенос выделения в таблицу: проверяем итоговый текст файла.
    func testInlineCommandInTableCellChangesOnlyThatCell() async throws {
        let table = "| a | b |\n|---|---|\n| c | d |"
        let editor = makeEditor(table)
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 2, length: 1))
        editor.format(.bold)
        for _ in 0..<30 where !editor.document.synchronizedText().contains("**a**") { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(editor.document.synchronizedText(), "| **a** | b |\n|---|---|\n| c | d |")
    }

    // Переключение режима настоящей командой приложения: текст файла и выделение остаются прежними.
    func testToggleMarkdownPresentationKeepsTextAndSelection() async throws {
        let source = "**жирный** текст 😀\r\nвторая"
        let document = EditorDocument(text: source, language: .markdown)
        let editor = makeEditor(source, document: document)
        defer { finish(editor) }
        try await waitForParse(editor)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditorVisualFormatting.\(UUID())"))
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        editor.view.setSelectedRange(NSRange(location: 12, length: 4))
        for expected in [false, true] {
            state.toggleMarkdownPresentation()
            XCTAssertEqual(document.isMarkdownFormatted, expected)
            XCTAssertEqual(document.synchronizedText(), source)
            XCTAssertEqual(editor.view.selectedRange(), NSRange(location: 12, length: 4))
        }
        document.setReadingMode(true)
        state.toggleMarkdownPresentation()
        XCTAssertFalse(document.isReadingMode)
        XCTAssertFalse(document.isMarkdownFormatted)
        XCTAssertEqual(document.synchronizedText(), source)
    }

    // Страница хранилища: правка вне раздела отклоняется системой, шаг отмены с выделением не остаётся.
    func testRejectedFormattingLeavesNoUndoStep() async throws {
        let page = "---\ntype: compiled\n---\n# Тема\n\n## Owner Notes\n\(VaultOwnerZone.startMarker)\nзаметка\n\(VaultOwnerZone.endMarker)\nХвост\n"
        let document = EditorDocument(text: page, language: .markdown)
        document.setVaultPageGuard(VaultPageGuard.make(serverPath: "compiled/x.md", text: page as NSString))
        let editor = makeEditor(page, document: document)
        defer { finish(editor) }
        try await waitForParse(editor)
        let title = editor.shown.range(of: "Тема")
        editor.view.setSelectedRange(title)
        editor.format(.bold)
        XCTAssertEqual(document.synchronizedText(), page)
        XCTAssertNotNil(document.statusMessage)
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
    }

    func testContextMenuHasFormatSubmenuAndSourceToggle() async throws {
        let editor = makeEditor("слово")
        defer { finish(editor) }
        try await waitForParse(editor)
        let items = try XCTUnwrap(editor.view.markdownFormatMenuHandler)()
        XCTAssertTrue(items.contains { $0.title == L10n.tr("Markdown 格式") && $0.submenu != nil })
        XCTAssertTrue(items.contains { $0.title == L10n.tr("显示 Markdown 源码") })
    }

    func testFormattingStateIsPublishedForCaret() async throws {
        let editor = makeEditor("# Заголовок **жир**")
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 14, length: 0))
        for _ in 0..<30 where editor.document.markdownFormattingState?.bold != true { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(editor.document.markdownFormattingState?.paragraph, .heading(1))
        XCTAssertEqual(editor.document.markdownFormattingState?.bold, true)
    }

    func testFormattingBarVisibilityConditions() {
        let document = EditorDocument(text: "текст", language: .markdown)
        document.isMarkdownFormatted = true
        XCTAssertTrue(MarkdownFormattingBar.isVisible(document: document, isDistractionFree: false))
        XCTAssertFalse(MarkdownFormattingBar.isVisible(document: document, isDistractionFree: true))
        document.isMarkdownFormatted = false
        XCTAssertFalse(MarkdownFormattingBar.isVisible(document: document, isDistractionFree: false))
        document.isMarkdownFormatted = true
        document.setReadingMode(true)
        XCTAssertFalse(MarkdownFormattingBar.isVisible(document: document, isDistractionFree: false))
        let code = EditorDocument(text: "x", language: .plainText)
        XCTAssertFalse(MarkdownFormattingBar.isVisible(document: code, isDistractionFree: false))
    }
}
