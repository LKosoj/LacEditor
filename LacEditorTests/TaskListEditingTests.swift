import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class TaskListEditingTests: XCTestCase {
    private func newline(_ source: String, selection: NSRange, unit: String = "  ") throws -> (String, NSRange) {
        let edit = try XCTUnwrap(ListContinuationService.listNewlineEdit(in: source as NSString, selection: selection, indentUnit: unit))
        return ((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    func testTaskContinuationUnicodeAndLineEndings() throws {
        for ending in ["\n", "\r\n", "\r"] {
            for state in [" ", "x", "X"] {
                let source = "- [\(state)] 中文😀abc" + ending + "next"
                let caret = (source as NSString).range(of: "abc").location
                let (result, selection) = try newline(source, selection: NSRange(location: caret, length: 0))
                XCTAssertEqual(result, "- [\(state)] 中文😀" + ending + "- [ ] abc" + ending + "next")
                XCTAssertEqual(selection.location, (result as NSString).range(of: "abc").location)
            }
        }
    }

    func testNewlyRecognizedTaskTabsContinueAsUncheckedTasks() throws {
        for (source, nextPrefix) in [
            ("-\t[x] 中文😀", "- [ ] "),
            ("> -\t[X]\t中文😀", "> - [ ] "),
            ("- parent\r\n\t- [x]\tbody", "\t- [ ] "),
            ("7)\t[x] body", "8) [ ] ")
        ] {
            XCTAssertEqual(MarkdownPresentationParser.parse(source).taskCheckboxes.count, 1, source)
            let (result, selection) = try newline(source, selection: NSRange(location: (source as NSString).length, length: 0))
            let ending = source.contains("\r\n") ? "\r\n" : "\n"
            XCTAssertEqual(result, source + ending + nextPrefix)
            XCTAssertEqual(selection, NSRange(location: (result as NSString).length, length: 0))
            XCTAssertEqual(MarkdownPresentationParser.parse(result).taskCheckboxes.count, 2, source)
        }
    }

    func testQuoteNestedEmptyAndRemainingContent() throws {
        let source = ">   - [x] abc"
        let caret = (source as NSString).range(of: "abc").location + 1
        let (result, _) = try newline(source, selection: NSRange(location: caret, length: 0))
        XCTAssertEqual(result, ">   - [x] a\n>   - [ ] bc")
        let empty = ">   - [ ] "
        XCTAssertEqual(try newline(empty, selection: NSRange(location: (empty as NSString).length, length: 0)).0, "> ")
        let beforeContent = "- [ ] text"
        let before = (beforeContent as NSString).range(of: "text").location
        XCTAssertEqual(try newline(beforeContent, selection: NSRange(location: before, length: 0)).0, "- [ ] \n- [ ] text")
    }

    func testListIndentMovesContinuationAndLeavesNextItem() throws {
        let source = "- lead\r\n- one\r\n  more 😀\r\n- two"
        let caret = (source as NSString).range(of: "one").location + 1
        let edit = try XCTUnwrap(ListContinuationService.unorderedIndentEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  ", outdent: false))
        let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(result, "- lead\r\n  - one\r\n    more 😀\r\n- two")
        XCTAssertEqual(edit.selection.location, caret + 2)
    }

    func testCodeDoesNotBecomeList() {
        for source in ["```\n- [x] a\n```", "> ```\n> - item\n> ```", "    - item"] {
            let position = (source as NSString).range(of: source.contains("item") ? "item" : source.contains("code") ? "code" : "a").location
            XCTAssertNil(ListContinuationService.listNewlineEdit(in: source as NSString, selection: NSRange(location: position, length: 0), indentUnit: "  "), source)
            XCTAssertFalse(ListContinuationService.isListOutsideCode(in: source as NSString, at: position), source)
        }
    }
    func testEditorNewlineAndUndoAndLanguage() throws {
        _ = NSApplication.shared
        let document = EditorDocument(text: "- [x] 中文😀", language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: document.text)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        view.listIndentationHandler = { [weak coordinator] outdent in coordinator?.indentCurrentListItem(outdent: outdent) ?? false }
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        defer { coordinator.updateActivity(false); window.close() }
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- [x] 中文😀\n- [ ] ")
        let undo = try XCTUnwrap(view.undoManager)
        undo.undo()
        XCTAssertEqual(view.string, "- [x] 中文😀")
        undo.redo()
        XCTAssertEqual(view.string, "- [x] 中文😀\n- [ ] ")
        view.string = "- item"
        coordinator.currentLanguage = .plainText
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- item\n")
        coordinator.currentLanguage = .markdown
        view.string = "- item"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.isEditable = false
        XCTAssertFalse(view.listNewlineHandler?() ?? true)
        XCTAssertEqual(view.string, "- item")
        view.isEditable = true
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 6, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.listNewlineHandler?() ?? true)
        XCTAssertEqual(view.string, "- item中")
        view.unmarkText()
        view.string = "- lead\n- parent\n  - child\n- next"
        view.setSelectedRange(NSRange(location: 10, length: 0))
        let originalHTML = MarkdownRenderer.renderPage(view.string, darkMode: false).body
        XCTAssertTrue(originalHTML.contains("<li>lead</li>"))
        XCTAssertTrue(originalHTML.contains("<li>parent\n<ul>"))
        undo.removeAllActions()
        XCTAssertTrue(coordinator.indentCurrentListItem(outdent: false))
        XCTAssertEqual(view.string, "- lead\n    - parent\n      - child\n- next")
        undo.undo()
        XCTAssertEqual(view.string, "- lead\n- parent\n  - child\n- next")
        undo.redo()
        XCTAssertEqual(view.string, "- lead\n    - parent\n      - child\n- next")
        let nestedHTML = MarkdownRenderer.renderPage(view.string, darkMode: false).body
        XCTAssertTrue(nestedHTML.contains("<li>lead\n<ul>"))
        XCTAssertTrue(nestedHTML.contains("<li>parent\n<ul>"))
        XCTAssertFalse(nestedHTML.contains("<pre"))
        for source in ["- parent\n  - child\n- next", "- parent\n\n\n  child\n- next"] {
            view.string = source
            view.setSelectedRange(NSRange(location: 3, length: 0))
            view.doCommand(by: #selector(NSTextView.insertTab(_:)))
            XCTAssertEqual(view.string, source)
            view.doCommand(by: #selector(NSTextView.insertBacktab(_:)))
            XCTAssertEqual(view.string, source)
        }
        view.string = "- parent"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(coordinator.indentCurrentListItem(outdent: true))
        view.doCommand(by: #selector(NSTextView.insertBacktab(_:)))
        XCTAssertEqual(view.string, "-parent")
        view.string = "plain"
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.doCommand(by: #selector(NSTextView.insertTab(_:)))
        XCTAssertEqual(view.string, "plain    ")
    }
    func testIndentInQuoteAndOutdent() throws {
        let source = "> - lead\n> - [ ] item\n>   continuation\n> - next"
        let caret = (source as NSString).range(of: "item").location
        let edit = try XCTUnwrap(ListContinuationService.unorderedIndentEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  ", outdent: false))
        let indented = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(indented, "> - lead\n>   - [ ] item\n>     continuation\n> - next")
        let outdent = try XCTUnwrap(ListContinuationService.unorderedIndentEdit(in: indented as NSString, selection: edit.selection, indentUnit: "  ", outdent: true))
        XCTAssertEqual((indented as NSString).replacingCharacters(in: outdent.range, with: outdent.replacement), source)
    }

    func testNewlineDoesNotDeleteUnselectedRemainder() throws {
        let source = "- [x] a😀b"
        let selection = (source as NSString).range(of: "😀")
        let (result, caret) = try newline(source, selection: selection)
        XCTAssertEqual(result, "- [x] a\n- [ ] b")
        XCTAssertEqual(caret.location, (result as NSString).range(of: "b").location)
    }
    func testQuotedFenceEndsWithQuoteAndRespectsClosingFence() throws {
        for ending in ["\n", "\r\n"] {
            for source in ["> ```" + ending + "text" + ending + "- item", "> ```" + ending + "> code" + ending + "> ```" + ending + "- item"] {
                let caret = (source as NSString).range(of: "item").location + 4
                XCTAssertTrue(ListContinuationService.isListOutsideCode(in: source as NSString, at: caret), source)
                XCTAssertNotNil(ListContinuationService.listNewlineEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  "))
            }
            for source in ["> ```" + ending + "> - item", "> ```" + ending + "> - item" + ending] {
                let caret = (source as NSString).range(of: "item").location + 4
                XCTAssertFalse(ListContinuationService.isListOutsideCode(in: source as NSString, at: caret), source)
                XCTAssertNil(ListContinuationService.listNewlineEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  "))
            }
        }
    }

    func testIndentedCodeInsideListAndNestedList() {
        for child in ["- child", "- [ ] child", "1. child"] {
            let nested = "- parent\n  " + child
            let nestedCaret = (nested as NSString).range(of: "child").location
            XCTAssertTrue(ListContinuationService.isListOutsideCode(in: nested as NSString, at: nestedCaret), nested)
            let code = "- parent\n\n        code\n        " + child
            let codeCaret = (code as NSString).range(of: "child").location
            XCTAssertFalse(ListContinuationService.isListOutsideCode(in: code as NSString, at: codeCaret), code)
            XCTAssertNil(ListContinuationService.listNewlineEdit(in: code as NSString, selection: NSRange(location: codeCaret, length: 0), indentUnit: "  "))
        }
    }

    func testIndentMovesChildListsAndBlankSeparatedContinuation() throws {
        for ending in ["\n", "\r\n"] {
            for child in ["- child", "- [x] child", "1. child"] {
                let source = "- lead" + ending + "- parent" + ending + "  " + child + ending + "- next"
                let edit = try XCTUnwrap(ListContinuationService.unorderedIndentEdit(in: source as NSString, selection: NSRange(location: (source as NSString).range(of: "parent").location, length: 0), indentUnit: "  ", outdent: false))
                XCTAssertEqual((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "- lead" + ending + "  - parent" + ending + "    " + child + ending + "- next")
            }
            let source = "- lead" + ending + "- parent" + ending + "  first" + ending + ending + "  second" + ending + "- next"
            let edit = try XCTUnwrap(ListContinuationService.unorderedIndentEdit(in: source as NSString, selection: NSRange(location: (source as NSString).range(of: "parent").location, length: 0), indentUnit: "  ", outdent: false))
            XCTAssertEqual((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "- lead" + ending + "  - parent" + ending + "    first" + ending + ending + "    second" + ending + "- next")
        }
    }
    func testFenceInsideListEndsAtSibling() {
        for ending in ["\n", "\r\n"] {
            for closed in [false, true] {
                let closing = closed ? "  ```" + ending : ""
                let source = "- ```" + ending + "  code" + ending + closing + "- item"
                let caret = (source as NSString).range(of: "item").location + 4
                XCTAssertTrue(ListContinuationService.isListOutsideCode(in: source as NSString, at: caret))
                XCTAssertNotNil(ListContinuationService.listNewlineEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  "))
                let html = MarkdownRenderer.renderPage(source, darkMode: false).body
                XCTAssertTrue(html.contains("<code>code\n</code>"))
                XCTAssertTrue(html.contains("<li>item</li>"))
            }
            let source = "- ```" + ending + "  - item"
            let caret = (source as NSString).length
            XCTAssertFalse(ListContinuationService.isListOutsideCode(in: source as NSString, at: caret))
            XCTAssertNil(ListContinuationService.listNewlineEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  "))
            XCTAssertTrue(MarkdownRenderer.renderPage(source, darkMode: false).body.contains("<code>- item\n</code>"))
        }
    }
    func testFenceInListContinuationEndsAtSibling() {
        for ending in ["\n", "\r\n"] {
            for closed in [false, true] {
                let closing = closed ? "  ```" + ending : ""
                let source = "- parent" + ending + "  ```" + ending + "  code" + ending + closing + "- item"
                let caret = (source as NSString).range(of: "item").location + 4
                XCTAssertTrue(ListContinuationService.isListOutsideCode(in: source as NSString, at: caret), source)
                XCTAssertNotNil(ListContinuationService.listNewlineEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  "))
                let html = MarkdownRenderer.renderPage(source, darkMode: false).body
                XCTAssertTrue(html.contains("<code>code\n</code>"))
                XCTAssertTrue(html.contains("<li>item</li>"))
            }
            let source = "- parent" + ending + "  ```" + ending + "  - item"
            let caret = (source as NSString).length
            XCTAssertFalse(ListContinuationService.isListOutsideCode(in: source as NSString, at: caret))
            XCTAssertNil(ListContinuationService.listNewlineEdit(in: source as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "  "))
            XCTAssertTrue(MarkdownRenderer.renderPage(source, darkMode: false).body.contains("<code>- item\n</code>"))
        }
    }
    func testTabAfterMarkerUsesActualColumn() throws {
        for ending in ["\n", "\r\n"] {
            let nested = "- \tparent" + ending + "    - child"
            let caret = (nested as NSString).range(of: "child").location
            XCTAssertTrue(ListContinuationService.isListOutsideCode(in: nested as NSString, at: caret))
            XCTAssertNotNil(ListContinuationService.listNewlineEdit(in: nested as NSString, selection: NSRange(location: caret, length: 0), indentUnit: "    "))
            let html = MarkdownRenderer.renderPage(nested, darkMode: false).body
            XCTAssertTrue(html.contains("<li>parent\n<ul>"))
            XCTAssertTrue(html.contains("<li>child</li>"))
            let source = "- \tparent" + ending + "- child"
            let position = (source as NSString).range(of: "child").location
            let edit = try XCTUnwrap(ListContinuationService.unorderedIndentEdit(in: source as NSString, selection: NSRange(location: position, length: 0), indentUnit: "    ", outdent: false))
            let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            XCTAssertTrue(MarkdownRenderer.renderPage(result, darkMode: false).body.contains("<li>parent\n<ul>"))
        }
    }
    func testQuotedListMarkerTabUsesCommonMarkPadding() {
        for ending in ["\n", "\r\n"] {
            let nested = "> - \tparent" + ending + ">     - child"
            let caret = (nested as NSString).range(of: "child").location
            XCTAssertTrue(ListContinuationService.isListOutsideCode(in: nested as NSString, at: caret))
            let html = MarkdownRenderer.renderPage(nested, darkMode: false).body
            XCTAssertTrue(html.contains("<code>parent\n</code>"))
            XCTAssertTrue(html.contains("<ul>\n<li>child</li>"))
            XCTAssertTrue(html.contains("<li>child</li>"))
            let code = "> - \tparent" + ending + ">       - child"
            let position = (code as NSString).range(of: "child").location
            XCTAssertFalse(ListContinuationService.isListOutsideCode(in: code as NSString, at: position))
            XCTAssertTrue(MarkdownRenderer.renderPage(code, darkMode: false).body.contains("<code>parent\n- child\n</code>"))
        }
    }
}
