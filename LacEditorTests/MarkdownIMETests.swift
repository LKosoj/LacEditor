import AppKit
import XCTest
@testable import LacEditor

/// T9: ввод через IME (японский, корейский, китайский) в оформленном Markdown. Композиция имитируется вызовами `setMarkedText`/`insertText`,
/// настоящий IME проверяется только на Mac вручную. Число групп отмены AppKit для композиции не утверждается.
/// Стенд - как в `MarkdownUndoGroupTests`.
@MainActor
final class MarkdownIMETests: XCTestCase {
    private typealias T = MarkdownEditTransaction

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

    // Японский: «に» заменяется кандидатом «日本», после подтверждения marked text нет, текст один раз.
    func testJapaneseCompositionReplacesMarkedRangeAndCommitsOnce() async throws {
        let source = "Привет **мир** 😀\r\nконец"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let end = editor.shown.range(of: "😀").upperBound
        editor.view.setSelectedRange(NSRange(location: end, length: 0))
        editor.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: end, length: 0))
        XCTAssertTrue(editor.view.hasMarkedText())
        XCTAssertEqual(editor.view.markedRange(), NSRange(location: end, length: 1))
        editor.view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.view.markedRange())
        XCTAssertEqual(editor.view.markedRange(), NSRange(location: end, length: 2))
        editor.view.insertText("日本", replacementRange: editor.view.markedRange())
        XCTAssertFalse(editor.view.hasMarkedText())
        XCTAssertEqual(editor.document.synchronizedText(), "Привет **мир** 😀日本\r\nконец")
        XCTAssertEqual(editor.document.synchronizedText().components(separatedBy: "日本").count, 2, "кандидат вставлен ровно один раз")
    }

    // Корейский: слог набирается по буквам, диапазон marked text всё время один и длиной 1.
    func testKoreanSyllableBuildUpKeepsSingleMarkedRange() async throws {
        let editor = makeEditor("Привет 中文\n")
        defer { finish(editor) }
        try await waitForParse(editor)
        let location = editor.shown.range(of: "中文").upperBound
        editor.view.setSelectedRange(NSRange(location: location, length: 0))
        var replacement = NSRange(location: location, length: 0)
        for step in ["ㅎ", "하", "한"] {
            editor.view.setMarkedText(step, selectedRange: NSRange(location: 1, length: 0), replacementRange: replacement)
            XCTAssertEqual(editor.view.markedRange(), NSRange(location: location, length: 1), step)
            replacement = editor.view.markedRange()
        }
        editor.view.unmarkText()
        XCTAssertFalse(editor.view.hasMarkedText())
        XCTAssertEqual(editor.document.synchronizedText(), "Привет 中文한\n")
    }

    // Китайский у границы жирного: каретка после «**» (скрытый маркер раскрыт каретка касанием), набор не портит маркеры.
    func testChineseCompositionNextToHiddenMarker() async throws {
        let source = "**жирный** текст"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let caret = editor.shown.range(of: "жирный").location
        editor.view.setSelectedRange(NSRange(location: caret, length: 0))
        editor.view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: caret, length: 0))
        editor.view.insertText("中文", replacementRange: editor.view.markedRange())
        XCTAssertFalse(editor.view.hasMarkedText())
        XCTAssertEqual(editor.document.synchronizedText(), "**中文жирный** текст")
    }

    // Пока идёт композиция, программные правки отказывают; после подтверждения снова работают, разбор остаётся рабочим.
    func testTransactionsRefuseDuringCompositionAndWorkAfter() async throws {
        let source = "# Заголовок\n\nтекст 😀"
        let editor = makeEditor(source)
        defer { finish(editor) }
        try await waitForParse(editor)
        let end = editor.shown.length
        editor.view.setSelectedRange(NSRange(location: end, length: 0))
        editor.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: end, length: 0))
        defer { editor.view.unmarkText() }
        let before = editor.shown as String
        for reason in [T.Reason.aiReplacement, .paste, .formatting] {
            XCTAssertEqual(editor.coordinator.perform(T(reason, range: NSRange(location: 0, length: 1), replacement: "X")),
                           .refused(.markedText), "\(reason)")
        }
        XCTAssertEqual(editor.shown as String, before)
        editor.view.insertText("日本", replacementRange: editor.view.markedRange())
        // После композиции разбор доезжает (ожидание опросом), правка проходит.
        for _ in 0..<30 where editor.ignoredRanges().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(editor.ignoredRanges().isEmpty, "после композиции разбор должен примениться")
        let outcome = editor.coordinator.perform(T(.formatting, range: NSRange(location: 0, length: 1), replacement: "#"))
        if case .refused(let reason) = outcome { XCTFail("правка после композиции отклонена: \(reason)") }
    }

    // Разбор, запланированный до композиции, не применяется, пока идёт marked text; после подтверждения ставится новый (ожидание опросом).
    func testParseResultDuringMarkedTextIsNotApplied() async throws {
        let editor = makeEditor("Заг\n\n**жирный** 😀")
        defer { finish(editor) }
        try await waitForParse(editor)
        let layout = try XCTUnwrap(editor.coordinator.foldLayoutManager)
        XCTAssertEqual(layout.markdownListsSnapshot["headings"], [], "до правки заголовков нет")
        // Правка делает первую строку заголовком и планирует разбор; сразу после неё начинается композиция.
        editor.view.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        let end = editor.shown.length
        editor.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: end, length: 0))
        XCTAssertTrue(editor.view.hasMarkedText())
        // Ждём дольше любой паузы разбора: пока идёт композиция, новая презентация не должна встать.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(editor.view.hasMarkedText())
        XCTAssertEqual(layout.markdownListsSnapshot["headings"], [], "во время marked text разбор не применяется")
        editor.view.insertText("日本", replacementRange: editor.view.markedRange())
        XCTAssertFalse(editor.view.hasMarkedText())
        for _ in 0..<30 where layout.markdownListsSnapshot["headings"] == [] { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotEqual(layout.markdownListsSnapshot["headings"], [], "после подтверждения должен примениться новый разбор")
    }

    // Японская и корейская композиция в ячейке таблицы: после подтверждения одна запись отмены в основном редакторе.
    func testJapaneseAndKoreanInTableCellCommitOnce() throws {
        let source = "| A | B |\n| --- | --- |\n| one | two |"
        for (marked, final) in [("に", "日本"), ("ㅎ", "한")] {
            let editor = makeEditor(source)
            defer { finish(editor) }
            let range = (source as NSString).range(of: "one")
            XCTAssertTrue(editor.coordinator.beginTableCell(range, frame: NSRect(x: 0, y: 0, width: 100, height: 30)))
            let child = try XCTUnwrap(editor.view.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first)
            child.setSelectedRange(NSRange(location: 0, length: 3))
            child.setMarkedText(marked, selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 3))
            XCTAssertTrue(child.hasMarkedText(), marked)
            child.insertText(final, replacementRange: child.markedRange())
            XCTAssertFalse(child.hasMarkedText(), marked)
            let expected = (source as NSString).replacingCharacters(in: range, with: final)
            XCTAssertEqual(editor.document.synchronizedSnapshot().text, expected, marked)
            XCTAssertEqual(editor.view.string, expected, marked)
            let undo = try XCTUnwrap(editor.view.undoManager)
            undo.undo()
            XCTAssertEqual(editor.view.string, source, marked)
            XCTAssertFalse(undo.canUndo, "\(marked): подтверждённая композиция - одна запись отмены")
            editor.coordinator.finishTableCell()
        }
    }
}
