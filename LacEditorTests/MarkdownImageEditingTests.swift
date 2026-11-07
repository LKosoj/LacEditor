import Foundation
import AppKit
import XCTest
import Yams
@testable import LacEditor

final class MarkdownImageEditingTests: XCTestCase {
    @MainActor
    func testRootPathCommandUsesEditorAndOneUndo() throws {
        _ = NSApplication.shared
        let source = "---\ntypora-root-url: &base /old # keep\nother: *base\n---\n\ntext 😀"
        let document = EditorDocument(text: source, language: .markdown)
        let manager = WindowManager()
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: source), layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.string = source
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        let id = UUID()
        manager.preparePrimaryWindow(windowID: id, state: state)
        manager.register(windowID: id, state: state, window: window)
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.installObservers(scrollView: scroll)
        coordinator.attachLiveTextProvider()
        coordinator.updateActivity(true)
        // Headless AppKit fixtures may not make the test window key merely by
        // ordering it front; the command requires an actually visible owner.
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        view.isEditable = true
        // Keep the model's live-edit gate closed before issuing a command.
        _ = document.synchronizeLiveText()
        defer { coordinator.updateActivity(false); manager.unregister(windowID: id); window.close() }
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        state.presentMarkdownResourceRoot(choose: { URL(fileURLWithPath: "/tmp/新 folder", isDirectory: true) })
        let metadata = try XCTUnwrap(PandocExportService.yamlFrontMatter(view.string))
        XCTAssertEqual(metadata["typora-root-url"]?.scalar?.string, "/tmp/新 folder")
        XCTAssertEqual(metadata["other"]?.scalar?.string, "/tmp/新 folder")
        XCTAssertTrue(view.string.contains("# keep\nother: *base"))
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, source)
        state.presentMarkdownResourceRoot(choose: {
            let range = view.selectedRange()
            view.textStorage?.replaceCharacters(in: range, with: "changed")
            view.didChangeText()
            return URL(fileURLWithPath: "/tmp/elsewhere", isDirectory: true)
        })
        XCTAssertTrue(view.string.hasSuffix("changed"))
        XCTAssertTrue(view.string.contains("typora-root-url: &base /old"))
    }
    func testRootPathEditPreservesYAMLSourceAndAnchorSemantics() throws {
        let path = "/новая \"папка\"/😀"
        let cases = [
            ("text", "text"),
            ("---\r\ntitle: '中文😀' # keep\r\n---\r\nbody", "title: '中文😀' # keep"),
            ("---\ntypora-root-url: '../old' # keep\ntitle: x\n---\nbody", "# keep\ntitle: x"),
            ("---\ntypora-root-url: # keep\ntitle: x\n---\nbody", "# keep\ntitle: x"),
            ("---\ntypora-root-url: >-\n  /old\n  path\n# keep\ntitle: x\n---\nbody", "# keep\ntitle: x"),
            ("---\ntypora-root-url: &base /old # keep\nother: *base\n---\nbody", "&base "),
            ("---\nbase: &base /old\ntypora-root-url: *base # keep\nother: *base\n---\nbody", "other: *base"),
            ("---\n{typora-root-url: /old, title: x}\n---\nbody", "title: x"),
            ("---\n{title: x}\n---\nbody", "title: x"),
            ("---\n{title: x,}\n---\nbody", "title: x,"),
            ("\u{FEFF}---\ntitle: x\n---\nbody", "title: x"),
            ("\u{FEFF}---\n---\nbody", "body"),
            ("\u{FEFF}body", "body")
        ]
        for (source, unchanged) in cases {
            let position = (source as NSString).length
            let edit = try XCTUnwrap(MarkdownImageEditingService.rootPathEdit(in: source, path: path,
                selection: NSRange(location: position, length: 0)), source)
            let changed = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            let metadata = try XCTUnwrap(PandocExportService.yamlFrontMatter(changed))
            XCTAssertEqual(metadata["typora-root-url"]?.scalar?.string, path, source)
            XCTAssertTrue(changed.contains(unchanged), source)
            XCTAssertEqual(edit.selectionRange.location, (changed as NSString).length)
            if source.contains("typora-root-url: &base") { XCTAssertEqual(metadata["other"]?.scalar?.string, path) }
            if source.contains("typora-root-url: *base") { XCTAssertEqual(metadata["other"]?.scalar?.string, "/old") }
        }
        XCTAssertNil(MarkdownImageEditingService.rootPathEdit(in: "---\ninvalid: [\n---\nbody", path: path,
                                                             selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(MarkdownImageEditingService.rootPathEdit(in: "\u{FEFF}---\nunclosed", path: path,
                                                             selection: NSRange(location: 0, length: 0)))
    }
    func testResourceRootResolvesOnlyRootRelativeAddresses() throws {
        let document = URL(fileURLWithPath: "/tmp/posts/文章.md")
        let text = "---\ntypora-root-url: '../site/${filename}'\n---\n\nbody"
        let paths = try MarkdownResourcePaths(text: text, document: document)
        XCTAssertEqual(paths.resolve("/img/a%23b.png")?.path, "/tmp/site/文章.md/img/a#b.png")
        XCTAssertEqual(paths.resolve("/img/a#b.png")?.path, "/tmp/site/文章.md/img/a")
        XCTAssertEqual(paths.resolve("images/a.png")?.path, "/tmp/posts/images/a.png")
        XCTAssertEqual(paths.resolve("file:///tmp/a.png")?.path, "/tmp/a.png")
        XCTAssertEqual(paths.resolve("https://example.com/a.png")?.host, "example.com")
        XCTAssertEqual(paths.resolve("data:image/png;base64,AA==")?.scheme, "data")
        XCTAssertFalse(MarkdownResourcePaths.requiresRoot("//host/image.png"))
        XCTAssertEqual(paths.resolve("//host/image.png")?.absoluteString,
                       URL(string: "//host/image.png", relativeTo: URL(fileURLWithPath: "/", isDirectory: true))?.absoluteURL.absoluteString)
        XCTAssertEqual(paths.resolve("file://host/image.png")?.absoluteString, "file://host/image.png")
        let ordinary = try MarkdownResourcePaths(text: "body", document: document)
        XCTAssertEqual(ordinary.resolve("/tmp/a.png")?.path, "/tmp/a.png")
        XCTAssertThrowsError(try MarkdownResourcePaths(text: text, document: nil))
        for value in ["''", "[]", "https://example.com"] {
            XCTAssertThrowsError(try MarkdownResourcePaths(text: "---\ntypora-root-url: \(value)\n---\n", document: document))
        }
    }
    func testFileAddressUsesDocumentDirectoryAndEncodesPath() throws {
        let image = URL(fileURLWithPath: "/tmp/文档/图 (1)#%.png")
        let document = URL(fileURLWithPath: "/tmp/文档/note.md")
        let relative = try XCTUnwrap(MarkdownImageEditingService.address(for: image, document: document))
        XCTAssertEqual(relative, "%E5%9B%BE%20%281%29%23%25.png")
        XCTAssertEqual(MarkdownImageEditingService.address(for: image, document: nil), image.absoluteString)
        let nested = URL(fileURLWithPath: "/tmp/other/a.png")
        XCTAssertEqual(MarkdownImageEditingService.address(for: nested, document: document), "../other/a.png")
        XCTAssertNil(MarkdownImageEditingService.address(for: URL(string: "https://example.com/a.png")!, document: document))
    }

    func testInsertAndEditImageThroughCmark() throws {
        let source = "前 中文😀 后" as NSString
        let selected = source.range(of: "中文😀")
        let input = MarkdownImageInput(alt: "文]😀 *&", address: "img/%E5%9B%BE%20%281%29.png", title: "title \"q\"")
        let edit = try XCTUnwrap(MarkdownImageEditingService.edit(in: source, selection: selected, input: input))
        let result = source.replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertTrue(MarkdownHTMLRenderer.render(result, darkMode: false).contains("<img"))
        let image = try XCTUnwrap(MarkdownImageEditingService.initial(in: result as NSString, selection: NSRange(location: edit.range.location + 2, length: 0)))
        XCTAssertEqual(image, input)
        XCTAssertEqual((result as NSString).substring(with: edit.selectionRange), "文\\]😀 \\*\\&")
        let changed = MarkdownImageInput(alt: "", address: "file:///tmp/a.png", title: "")
        let updated = try XCTUnwrap(MarkdownImageEditingService.edit(in: result as NSString, selection: NSRange(location: edit.range.location + 2, length: 0), input: changed))
        let updatedText = (result as NSString).replacingCharacters(in: updated.range, with: updated.replacement)
        XCTAssertEqual(try XCTUnwrap(MarkdownImageEditingService.initial(in: updatedText as NSString, selection: NSRange(location: edit.range.location + 2, length: 0))), changed)
        XCTAssertTrue(updatedText.hasPrefix("前 ![](<file:///tmp/a.png>)"))
    }

    func testComplexImageAltIsNotEdited() {
        let source = "![a `code` **bold**](image.png)" as NSString
        let selection = NSRange(location: 3, length: 0)
        XCTAssertNil(MarkdownImageEditingService.initial(in: source, selection: selection))
        XCTAssertNil(MarkdownImageEditingService.edit(in: source, selection: selection,
            input: MarkdownImageInput(alt: "a code bold", address: "image.png", title: "")))
    }

    func testEmptyAndCodeAndInvalidSelection() throws {
        let empty = MarkdownImageInput(alt: "", address: "data:image/png;base64,AA==", title: "")
        let edit = try XCTUnwrap(MarkdownImageEditingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), input: empty))
        XCTAssertEqual(edit.replacement, "![](<data:image/png;base64,AA==>)")
        for text in ["`abc`", "``abc``", "```\nabc\n```", "[abc](url)", "![abc][ref]\n\n[ref]: x"] {
            let string = text as NSString
            let position = string.range(of: "abc").location
            XCTAssertNil(MarkdownImageEditingService.edit(in: string, selection: NSRange(location: position, length: 0), input: empty), text)
        }
        XCTAssertNil(MarkdownImageEditingService.edit(in: "😀" as NSString, selection: NSRange(location: 1, length: 0), input: empty))
        XCTAssertNil(MarkdownImageEditingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), input: MarkdownImageInput(alt: "a", address: "", title: "")))
        XCTAssertNil(MarkdownImageEditingService.edit(in: "" as NSString, selection: NSRange(location: 0, length: 0), input: MarkdownImageInput(alt: "a\nb", address: "x", title: "")))
    }

    // Подпись с выделением, кодом или переносом строки не правится; простая (с кириллицей и эмодзи) правится.
    func testImageWithNestedAltMarkupIsNotEdited() throws {
        for alt in ["**жирная** 😀", "`код` и 中文", "первая\nвторая"] {
            let source = "![\(alt)](pic.png)" as NSString
            let caret = NSRange(location: 3, length: 0)
            XCTAssertNil(MarkdownImageEditingService.initial(in: source, selection: caret), alt)
        }
        let plain = "до ![подпись 中文😀](pic.png \"т\") после" as NSString
        let initial = try XCTUnwrap(MarkdownImageEditingService.initial(in: plain, selection: NSRange(location: plain.range(of: "подпись").location, length: 0)))
        XCTAssertEqual(initial, MarkdownImageInput(alt: "подпись 中文😀", address: "pic.png", title: "т"))
    }

    // Скобка в подписи — отказ (определение `[b]: …` документа потерялось бы); экранированная скобка допустима.
    func testImageAltWithBracketsIsRefusedUnlessEscaped() throws {
        let linked = "![a [b] c](x)\n\n[b]: http://z" as NSString
        XCTAssertNil(MarkdownImageEditingService.initial(in: linked, selection: NSRange(location: 3, length: 0)))
        let escaped = "![a \\] b](pic.png)" as NSString
        XCTAssertEqual(MarkdownImageEditingService.initial(in: escaped, selection: NSRange(location: 3, length: 0))?.address, "pic.png")
        let crlf = "ñ中文\r\n![a *b*](x)" as NSString
        XCTAssertNil(MarkdownImageEditingService.initial(in: crlf, selection: NSRange(location: crlf.range(of: "a *").location, length: 0)))
    }

    // Внутри картинки cmark формулу не создаёт: `$…$` в подписи — обычный текст, подпись правится, как в панели.
    func testImageAltWithFormulaIsEditedAsPlainTextLikePanel() throws {
        let s = "до ![E=$mc^2$ 中文😀](p.png \"т\") после" as NSString
        let caret = NSRange(location: s.range(of: "E=").location, length: 0)
        XCTAssertEqual(MarkdownImageEditingService.initial(in: s, selection: caret),
                       MarkdownImageInput(alt: "E=$mc^2$ 中文😀", address: "p.png", title: "т"))
        let edit = try XCTUnwrap(MarkdownImageEditingService.edit(in: s, selection: caret,
            input: MarkdownImageInput(alt: "E=$mc^2$ 中文😀", address: "q.png", title: "")))
        XCTAssertEqual(s.replacingCharacters(in: edit.range, with: edit.replacement), "до ![E=$mc^2$ 中文😀](<q.png>) после")
        XCTAssertEqual((s.replacingCharacters(in: edit.range, with: edit.replacement) as NSString).substring(with: edit.selectionRange), "E=$mc^2$ 中文😀")

        let crlf = "ñ中文\r\n![E=$mc^2$](p.png)" as NSString
        let crlfCaret = NSRange(location: crlf.range(of: "E=").location, length: 0)
        XCTAssertEqual(MarkdownImageEditingService.initial(in: crlf, selection: crlfCaret)?.alt, "E=$mc^2$")
        let crlfEdit = try XCTUnwrap(MarkdownImageEditingService.edit(in: crlf, selection: crlfCaret,
            input: MarkdownImageInput(alt: "E=$mc^2$", address: "q.png", title: "")))
        XCTAssertEqual(crlfEdit.range.location, crlf.range(of: "![").location)
        XCTAssertEqual(crlfEdit.replacement, "![E=$mc^2$](<q.png>)")

        XCTAssertTrue(MarkdownHTMLRenderer.render("![E=$mc^2$](p.png)", darkMode: false).contains("alt=\"E=$mc^2$\""))

        for alt in ["a $*b*$", "a $`код`$", "a {++b++}", "a {--b--}", "я {++中文😀++} z", "$x$ [b]", "a $b$\nc"] {
            let source = "![\(alt)](x)" as NSString
            XCTAssertNil(MarkdownImageEditingService.initial(in: source, selection: NSRange(location: 3, length: 0)), alt)
        }
    }

    // Подпись берётся буквально: типографские замены (`'`, `"`, `--`, `...`) не попадают ни в диалог, ни в сохранённый текст.
    func testImageAltKeepsLiteralPunctuation() throws {
        let alt = "Bob's \"x\" -- y... 中文😀"
        let s = "ñ\r\n![\(alt)](p.png)" as NSString
        let caret = NSRange(location: s.range(of: "Bob").location, length: 0)
        XCTAssertEqual(MarkdownImageEditingService.initial(in: s, selection: caret), MarkdownImageInput(alt: alt, address: "p.png", title: ""))
        let edit = try XCTUnwrap(MarkdownImageEditingService.edit(in: s, selection: caret,
            input: MarkdownImageInput(alt: alt, address: "p.png", title: "")))
        XCTAssertEqual(s.replacingCharacters(in: edit.range, with: edit.replacement), "ñ\r\n![\(alt)](<p.png>)")
    }
}
