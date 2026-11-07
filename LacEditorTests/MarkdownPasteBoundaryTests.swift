import AppKit
import XCTest
@testable import LacEditor

/// T9: обычная вставка текста у границ скрытых маркеров (`**`, `## `) в оформленном режиме. Вставка идёт через настоящий `paste(_:)`
/// и `NSPasteboard.general` (буфер сохраняется и возвращается). Стенд - как в `MarkdownUndoGroupTests`.
@MainActor
final class MarkdownPasteBoundaryTests: XCTestCase {
    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        savedItems = (NSPasteboard.general.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(savedItems)
        super.tearDown()
    }

    @MainActor private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let window: NSWindow

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }

        func ignoredRanges() -> [NSRange] {
            coordinator.textView(view, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: shown.length)).map(\.rangeValue)
        }
    }

    private func makeEditor(_ source: String) -> Editor {
        _ = NSApplication.shared
        let document = EditorDocument(text: source, language: .markdown)
        document.isMarkdownFormatted = true
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

    private func paste(_ text: String, into editor: Editor, selection: NSRange) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        editor.view.setSelectedRange(selection)
        editor.view.paste(nil)
    }

    // Вставка в начале жирного (после «**»), в конце (перед «**») и снаружи: текст попадает ровно туда, где стояла каретка, маркеры целы.
    func testPlainPasteAtBoldBoundariesKeepsMarkers() async throws {
        let source = "до **жирный** после 😀"
        let cases: [(String, (NSString) -> Int, String)] = [
            ("перед маркером", { $0.range(of: "**").location }, "до Ы**жирный** после 😀"),
            ("начало жирного", { $0.range(of: "жирный").location }, "до **Ыжирный** после 😀"),
            ("конец жирного", { NSMaxRange($0.range(of: "жирный")) }, "до **жирныйЫ** после 😀"),
            ("после маркера", { NSMaxRange($0.range(of: "жирный")) + 2 }, "до **жирный**Ы после 😀")
        ]
        for (name, position, expected) in cases {
            let editor = makeEditor(source)
            defer { finish(editor) }
            try await waitForParse(editor)
            paste("Ы", into: editor, selection: NSRange(location: position(source as NSString), length: 0))
            XCTAssertEqual(editor.document.synchronizedText(), expected, name)
            let undo = try XCTUnwrap(editor.view.undoManager, name)
            undo.undo()
            XCTAssertEqual(editor.document.synchronizedText(), source, name)
        }
    }

    // Вставка после префикса заголовка: «## » остаётся, текст идёт в заголовок; CRLF сохраняется.
    func testPlainPasteAfterHeadingPrefixKeepsPrefix() async throws {
        let source = "## Заголовок 中文\r\nтекст"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let start = editor.shown.range(of: "Заголовок").location
        paste("Новый ", into: editor, selection: NSRange(location: start, length: 0))
        XCTAssertEqual(editor.document.synchronizedText(), "## Новый Заголовок 中文\r\nтекст")
        let undo = try XCTUnwrap(editor.view.undoManager)
        undo.undo()
        XCTAssertEqual(editor.document.synchronizedText(), source)
    }

    // Вставка поверх выделения слова внутри жирного: заменяется только выделенное, «**» не трогаются; позиции в UTF-16.
    func testPlainPasteOverSelectionInsideBoldReplacesOnlySelection() async throws {
        let source = "😀 **один два** конец"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let word = editor.shown.range(of: "два")
        paste("три 中文", into: editor, selection: word)
        XCTAssertEqual(editor.document.synchronizedText(), "😀 **один три 中文** конец")
        let undo = try XCTUnwrap(editor.view.undoManager)
        undo.undo()
        XCTAssertEqual(editor.document.synchronizedText(), source)
        XCTAssertEqual(editor.view.selectedRange(), word)
    }

    // Программная вставка во время композиции отказывает (вставка Markdown идёт через ту же транзакцию).
    func testPasteTransactionDuringMarkedTextIsRefused() async throws {
        let editor = makeEditor("Привет **мир**")
        defer { finish(editor) }
        try await waitForParse(editor)
        editor.view.setSelectedRange(NSRange(location: 6, length: 0))
        editor.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 6, length: 0))
        defer { editor.view.unmarkText() }
        let outcome = editor.coordinator.perform(MarkdownEditTransaction(.paste, range: NSRange(location: 0, length: 0), replacement: "x"))
        XCTAssertEqual(outcome, .refused(.markedText))
    }
}
