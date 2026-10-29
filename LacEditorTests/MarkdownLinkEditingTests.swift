import Foundation
import XCTest
@testable import LacEditor

final class MarkdownLinkEditingTests: XCTestCase {
    func testCreateAndEditInlineLinks() throws {
        let source = "До **中文😀** после" as NSString
        let selected = source.range(of: "**中文😀**")
        let input = MarkdownLinkInput(label: "**中文😀**", address: "docs/文件 (1).md")
        let edit = try XCTUnwrap(MarkdownLinkEditingService.edit(in: source, selection: selected, input: input))
        let output = source.replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual((output as NSString).substring(with: edit.selectionRange), "**中文😀**")
        XCTAssertTrue(MarkdownRenderer.render(output, darkMode: false).contains("<strong>中文😀</strong>"))
        let caret = NSRange(location: edit.selectionRange.location + 2, length: 0)
        let initial = try XCTUnwrap(MarkdownLinkEditingService.initial(in: output as NSString, selection: caret))
        XCTAssertEqual(initial, input)
        let updated = try XCTUnwrap(MarkdownLinkEditingService.edit(in: output as NSString, selection: caret,
                                                                   input: MarkdownLinkInput(label: "новая", address: "#часть")))
        XCTAssertEqual((output as NSString).replacingCharacters(in: updated.range, with: updated.replacement), "До [новая](<#часть>) после")
    }

    func testEmptyCaretAndExistingTitle() throws {
        let empty = try XCTUnwrap(MarkdownLinkEditingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0),
                                                                 input: MarkdownLinkInput(label: "A", address: "https://example.com")))
        XCTAssertEqual(empty.replacement, "[A](<https://example.com>)")
        let source = "[a](https://example.com \"title\")" as NSString
        let edit = try XCTUnwrap(MarkdownLinkEditingService.edit(in: source, selection: NSRange(location: 1, length: 0),
                                                                input: MarkdownLinkInput(label: "b", address: "relative.md")))
        XCTAssertEqual(edit.replacement, "[b](<relative.md> \"title\")")
        XCTAssertTrue(MarkdownRenderer.render(edit.replacement, darkMode: false).contains("title=\"title\""))
    }

    func testPreservesOriginalTitleSource() throws {
        for suffix in [" 'a &amp; b'", " \"a &amp; b\"", " 'a \\' b'"] {
            let source = ("[a](url" + suffix + ")") as NSString
            let edit = try XCTUnwrap(MarkdownLinkEditingService.edit(in: source, selection: NSRange(location: 1, length: 0),
                                                                    input: MarkdownLinkInput(label: "b", address: "next")))
            XCTAssertEqual(edit.replacement, "[b](<next>" + suffix + ")")
        }
    }

    func testUnrelatedTabAndUnicodeLineSeparatorsDoNotBlockLink() throws {
        for source in ["plain\n\n`a\tb`", "plain\n\nx\u{2028}y", "plain\n\nx\u{2029}y"] {
            let text = source as NSString
            let input = MarkdownLinkInput(label: "plain", address: "url")
            let edit = try XCTUnwrap(MarkdownLinkEditingService.edit(in: text, selection: text.range(of: "plain"), input: input))
            XCTAssertTrue(text.replacingCharacters(in: edit.range, with: edit.replacement).hasPrefix("[plain](<url>)"))
        }
        let source = "plain\n\n`a\tb`" as NSString
        let code = source.range(of: "`a")
        XCTAssertNil(MarkdownLinkEditingService.edit(in: source, selection: NSRange(location: code.location + 1, length: 1), input: MarkdownLinkInput(label: "a", address: "url")))
    }

    func testDialogStateDetectsDocumentRevisionAndSelectionChanges() {
        let id = UUID(), other = UUID()
        let selection = EditorTextSelectionSnapshot(documentID: id, range: NSRange(location: 0, length: 1), text: "a", editorRevision: 4, wasExplicitSelection: true)
        let document = DocumentTextSnapshot(documentID: id, revision: 3, text: "abc")
        let state = MarkdownLinkDialogState(document: document, selection: selection)
        XCTAssertTrue(state.matches(document: document, selection: selection))
        XCTAssertFalse(state.matches(document: DocumentTextSnapshot(documentID: other, revision: 3, text: "abc"), selection: selection))
        XCTAssertFalse(state.matches(document: DocumentTextSnapshot(documentID: id, revision: 4, text: "abc"), selection: selection))
        XCTAssertFalse(state.matches(document: document, selection: EditorTextSelectionSnapshot(documentID: id, range: NSRange(location: 1, length: 1), text: "a", editorRevision: 4, wasExplicitSelection: true)))
        XCTAssertFalse(state.matches(document: document, selection: EditorTextSelectionSnapshot(documentID: id, range: selection.range, text: "a", editorRevision: 5, wasExplicitSelection: true)))
        XCTAssertFalse(state.matches(document: document, selection: EditorTextSelectionSnapshot(documentID: other, range: selection.range, text: "a", editorRevision: 4, wasExplicitSelection: true)))
    }

    func testRejectsCodeImagesAndAmbiguousSelection() {
        for source in ["`hello`", "```\nhello\n```", "![hello](image.png)", "[hello][id]\n\n[id]: /x", "<https://example.com>"] {
            let text = source as NSString
            let location = text.range(of: source.hasPrefix("<") ? "https" : "hello").location
            XCTAssertNil(MarkdownLinkEditingService.edit(in: text, selection: NSRange(location: location, length: 0),
                                                        input: MarkdownLinkInput(label: "a", address: "b")), source)
        }
        let source = "[hello](url)" as NSString
        XCTAssertNil(MarkdownLinkEditingService.edit(in: source, selection: source.range(of: "hello"), input: MarkdownLinkInput(label: "a", address: "b")))
        XCTAssertNil(MarkdownLinkEditingService.edit(in: "a\n\nb" as NSString, selection: NSRange(location: 0, length: 4), input: MarkdownLinkInput(label: "a", address: "b")))
        XCTAssertNil(MarkdownLinkEditingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), input: MarkdownLinkInput(label: "", address: "b")))
        XCTAssertNil(MarkdownLinkEditingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), input: MarkdownLinkInput(label: "a", address: "b\nc")))
        let emoji = "😀" as NSString
        XCTAssertNil(MarkdownFormattingService.edit(in: emoji, selection: NSRange(location: 1, length: 0), command: .link(MarkdownLinkInput(label: "a", address: "b"))))
    }

    func testCodeSpanMarkersCannotBecomeLinks() throws {
        for marker in ["`", "``", "```"] {
            let code = marker + "hello" + marker
            let source = ("left " + code + " right") as NSString
            let range = source.range(of: code)
            let markerLength = (marker as NSString).length
            let input = MarkdownLinkInput(label: "x", address: "url")
            let selections = [
                NSRange(location: range.location, length: markerLength),
                NSRange(location: NSMaxRange(range) - markerLength, length: markerLength),
                NSRange(location: range.location - 1, length: markerLength + 1),
                NSRange(location: NSMaxRange(range) - markerLength, length: markerLength + 1)
            ]
            for selection in selections {
                XCTAssertNil(MarkdownLinkEditingService.edit(in: source, selection: selection, input: input), "\(code), \(selection)")
            }
            let selected = source.range(of: "left")
            let edit = try XCTUnwrap(MarkdownLinkEditingService.edit(in: source, selection: selected,
                                                                    input: MarkdownLinkInput(label: "left", address: "url")))
            XCTAssertEqual(source.replacingCharacters(in: edit.range, with: edit.replacement), "[left](<url>) " + code + " right")
        }
    }
}
