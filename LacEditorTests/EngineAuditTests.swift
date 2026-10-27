import AppKit
import XCTest
@testable import LacEditor

final class EngineAuditTests: XCTestCase {
    func testJSONErrorByteOffsetUsesCRLFAndCRAsLineBreaks() {
        let cases: [(String, Int, Int)] = [
            ("错误", 1, 3),
            ("a\nb", 2, 2),
            ("a\r\nb", 2, 2),
            ("a\rb", 2, 2),
            ("😀\r\n中\r文\n", 4, 1),
            ("😀中x", 1, 4)
        ]
        for (prefix, line, column) in cases {
            let error = NSError(domain: "JSON", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "bad",
                "NSJSONSerializationErrorIndex": prefix.utf8.count
            ])
            let message = JSONFormatter.userFacingError(error, in: prefix + "!")
            let expected = L10n.tr("JSON 无效") + L10n.tr("：第 %@ 行，第 %@ 列。%@", String(line), String(column), "bad")
            XCTAssertEqual(message, expected, "prefix=\(prefix)")
        }
    }

    func testIncrementalLineIndexMatchesFullScanAroundCRLF() {
        let original = "abc\r\n中文\rnext\nend\u{2028}last\u{2029}"
        let nsText = original as NSString
        let cases: [(NSRange, String)] = [
            (NSRange(location: 3, length: 0), "x"),
            (NSRange(location: 4, length: 0), "x"),
            (NSRange(location: 3, length: 1), ""),
            (NSRange(location: 4, length: 1), ""),
            (NSRange(location: 2, length: 7), "😀\r\nnew\r"),
            (NSRange(location: nsText.length, length: 0), "\r\n")
        ]
        for (range, replacement) in cases {
            let index = LogicalLineIndex(text: original)
            index.applyEdit(range: range, replacement: replacement, in: nsText)
            let updated = nsText.replacingCharacters(in: range, with: replacement)
            let expected = LogicalLineIndex(text: updated)
            XCTAssertEqual(index.textLength, expected.textLength)
            for location in 0...expected.textLength {
                XCTAssertEqual(index.lineNumber(at: location), expected.lineNumber(at: location),
                               "range=\(range), replacement=\(replacement), location=\(location)")
            }
        }
    }

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
    func testCancelledTreeEditDoesNotCorruptCachedVersion() {
        let backend = TreeSitterJavaScriptBackend()
        let id = UUID()
        let source = "const value = 1; // 中文"
        let oldRange = (source as NSString).range(of: "value")
        let updated = (source as NSString).replacingCharacters(in: oldRange, with: "longerName")
        let edit = DocumentEditDelta(documentID: id, revision: 2, editedRange: oldRange,
            replacementLength: 10, changeInLength: 5, changedLineRange: nil)
        func tokens(_ text: String, _ revision: UInt, _ documentID: UUID, _ edit: DocumentEditDelta? = nil,
                    _ cancelled: @escaping () -> Bool = { false }) -> [SyntaxHighlighter.Token] {
            backend.tokens(in: text, language: .javascript, range: NSRange(location: 0, length: (text as NSString).length),
                context: nil, revision: revision, documentID: documentID, edit: edit, isCancelled: cancelled)
        }
        func signature(_ tokens: [SyntaxHighlighter.Token]) -> [String] {
            tokens.map { "\($0.kind):\($0.range.location):\($0.range.length)" }
        }
        let original = signature(tokens(source, 1, id))
        XCTAssertFalse(original.isEmpty)
        var calls = 0
        _ = tokens(updated, 2, id, edit) { calls += 1; return calls == 3 }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(signature(tokens(source, 1, id)), original)
        XCTAssertEqual(signature(tokens(updated, 2, id, edit)), signature(tokens(updated, 2, UUID())))
        let next = updated + "\nlet next = 2;"
        let nextEdit = DocumentEditDelta(documentID: id, revision: 3,
            editedRange: NSRange(location: (updated as NSString).length, length: 0),
            replacementLength: (next as NSString).length - (updated as NSString).length,
            changeInLength: (next as NSString).length - (updated as NSString).length, changedLineRange: nil)
        XCTAssertEqual(signature(tokens(next, 3, id, nextEdit)), signature(tokens(next, 3, UUID())))
    }
#endif

    func testDirtyRangesFollowBothSidesOfReplacements() {
        let cases: [(NSRange, NSRange, Int, [NSRange])] = [
            (NSRange(location: 10, length: 5), NSRange(location: 12, length: 0), 2, [NSRange(location: 10, length: 7)]),
            (NSRange(location: 10, length: 5), NSRange(location: 8, length: 0), 2, [NSRange(location: 8, length: 2), NSRange(location: 12, length: 5)]),
            (NSRange(location: 10, length: 5), NSRange(location: 16, length: 0), 2, [NSRange(location: 10, length: 5), NSRange(location: 16, length: 2)]),
            (NSRange(location: 10, length: 5), NSRange(location: 10, length: 0), 2, [NSRange(location: 10, length: 7)]),
            (NSRange(location: 10, length: 5), NSRange(location: 13, length: 5), 1, [NSRange(location: 10, length: 4)]),
            (NSRange(location: 10, length: 5), NSRange(location: 8, length: 10), 2, [NSRange(location: 8, length: 2)])
        ]
        for (old, edit, replacementLength, expected) in cases {
            var accumulator = DirtyRangeAccumulator()
            accumulator.invalidate(old)
            accumulator.append(DocumentEditDelta(documentID: UUID(), revision: 1, editedRange: edit,
                replacementLength: replacementLength, changeInLength: replacementLength - edit.length, changedLineRange: nil))
            XCTAssertEqual(accumulator.ranges, expected)
        }
    }

    func testOrderedListNumberOverflowLeavesTextAndEditingAvailable() throws {
        let maximum = String(Int.max)
        let previous = String(Int.max - 1)
        XCTAssertNil(ListContinuationService.continuation(for: "\(maximum). item"))
        XCTAssertEqual(ListContinuationService.continuation(for: "\(previous). item"), "\(maximum). ")
        XCTAssertNil(ListContinuationService.continuation(for: "\(maximum)0. item"))
        XCTAssertEqual(ListContinuationService.continuation(for: "1. item"), "2. ")

        let text = "\(maximum). first\n    1. nested"
        let edits = try XCTUnwrap(ListContinuationService.indentationEdit(
            in: text as NSString, at: (text as NSString).length, indentUnit: "    ", outdent: true
        ))
        XCTAssertEqual(edits.count, 1)
        let updated = NSMutableString(string: text)
        for edit in edits.reversed() {
            updated.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertEqual(updated as String, "\(maximum). first\n1. nested")
        XCTAssertNil(ListContinuationService.normalizeOrderedList(in: updated as String, aroundUTF16Location: 0))
        XCTAssertNotNil(ListContinuationService.normalizeOrderedList(in: "1. a\n4. b", aroundUTF16Location: 0))
    }

    @MainActor
    func testOutdentAfterMaximumPreservesNumbering() {
        _ = NSApplication.shared
        let original = "\(Int.max). first\n    1. nested"
        let document = EditorDocument(text: original, language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = original
        textView.delegate = coordinator
        coordinator.textView = textView
        textView.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        XCTAssertTrue(coordinator.indentCurrentListItem(outdent: true))
        XCTAssertEqual(textView.string, "\(Int.max). first\n1. nested")
    }

    @MainActor
    func testListIndentIsAnUndoableLiveEdit() throws {
        _ = NSApplication.shared
        let original = "1. a\n2. b"
        let document = EditorDocument(text: original, url: URL(fileURLWithPath: "/tmp/list.md"), language: .markdown)
        let coordinator = EditorTextView.Coordinator(document: document)
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        textView.allowsUndo = true
        textView.string = original
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.attachLiveTextProvider()
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))

        XCTAssertTrue(coordinator.indentCurrentListItem(outdent: false))
        let indented = textView.string
        XCTAssertEqual(indented, "1. a\n    1. b")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.synchronizedText(), indented)
        XCTAssertEqual(coordinator.lineNumber(at: (indented as NSString).length), 2)
        let undo = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(textView.string, original)
        undo.redo()
        XCTAssertEqual(textView.string, indented)
        XCTAssertTrue(coordinator.indentCurrentListItem(outdent: true))
        XCTAssertEqual(document.synchronizedText(), original)
        textView.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: textView.selectedRange())
        let composing = textView.string
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertTrue(coordinator.indentCurrentListItem(outdent: false))
        XCTAssertEqual(textView.string, composing)
        XCTAssertTrue(textView.hasMarkedText())
    }
}
