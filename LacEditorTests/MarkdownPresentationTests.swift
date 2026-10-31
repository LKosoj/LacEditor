import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownPresentationTests: XCTestCase {
    func testFormattingAndReturningToSourcePreserveTextAndSelection() async throws {
        _ = NSApplication.shared
        let source = "# Заголовок\n\n**中文 😀** and *text*"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), textContainer: container)
        view.font = lacEditorFont(size: 14)
        let selection = NSRange(location: 2, length: 3)
        view.setSelectedRange(selection)
        layout.ensureLayout(for: container)
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        var revision: UInt = 0
        var geometryChanges = 0
        controller.geometryDidChange = { geometryChanges += 1 }
        controller.update(document: document, enabled: true, isActive: true, revision: revision, currentRevision: { revision })
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        let headingFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(headingFont.pointSize, layout.textFont.pointSize)
        var attributeEdits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in attributeEdits += 1 }
        let previousGeometryChanges = geometryChanges
        for _ in 0..<5 { controller.viewportChanged() }
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(attributeEdits, 0)
        XCTAssertEqual(geometryChanges, previousGeometryChanges)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        controller.selectionChanged()
        XCTAssertGreaterThan(geometryChanges, previousGeometryChanges)
        let selectionGeometryChanges = geometryChanges
        controller.selectionChanged()
        XCTAssertEqual(geometryChanges, selectionGeometryChanges)
        let insertion = NSRange(location: 0, length: 0)
        controller.beforeEdit(range: insertion, replacementLength: 1)
        storage.replaceCharacters(in: insertion, with: "x")
        revision += 1
        controller.edited(revision: revision)
        try await Task.sleep(for: .milliseconds(500))
        var typing = view.typingAttributes
        typing[.font] = layout.markdownHeadingFont(level: 1)
        view.typingAttributes = typing
        controller.update(document: document, enabled: false, isActive: true, revision: revision, currentRevision: { revision })
        XCTAssertEqual(view.string, "x" + source)
        let restoredFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(restoredFont.pointSize, layout.textFont.pointSize)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("z", replacementRange: view.selectedRange())
        let insertedFont = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(insertedFont.pointSize, layout.textFont.pointSize)
        XCTAssertEqual(view.string, "zx" + source)
    }

    func testTaskCheckboxesDrawWithCursorLine() {
        _ = NSApplication.shared
        let source = "- [ ] a\n- [x] b"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        view.font = lacEditorFont(size: 14)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        layout.setMarkdownPresentation(MarkdownPresentationParser.parse(source), revealedRange: nil)
        layout.ensureLayout(for: container)
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus()
        layout.drawBackground(forGlyphRange: layout.glyphRange(for: container), at: .zero)
        image.unlockFocus()
        XCTAssertEqual(view.string, source)
    }

    func testInactiveEditorWaitsUntilActivationToApplyFormatting() async throws {
        _ = NSApplication.shared
        let source = "# Heading"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.font = lacEditorFont(size: 14)
        layout.ensureLayout(for: container)
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        controller.update(document: document, enabled: true, isActive: false, revision: 0, currentRevision: { 0 })
        try await Task.sleep(for: .milliseconds(300))
        let inactiveFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(inactiveFont.pointSize, layout.textFont.pointSize)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        try await Task.sleep(for: .milliseconds(500))
        let activeFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(activeFont.pointSize, layout.textFont.pointSize)
        XCTAssertEqual(view.string, source)
    }

    func testFormattingTogglePreservesUndoAndRedo() async throws {
        _ = NSApplication.shared
        let source = "# Heading\nbody"
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: 200))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.font = lacEditorFont(size: 14)
        view.isRichText = false
        view.allowsUndo = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.makeFirstResponder(view)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        undo.beginUndoGrouping()
        view.insertText("!", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        XCTAssertEqual(view.string, source + "!")
        XCTAssertTrue(undo.canUndo)

        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        XCTAssertFalse(document.isDirty)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { 0 })
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let font = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont,
               font.pointSize > layout.textFont.pointSize { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let formattedFont = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(formattedFont.pointSize, layout.textFont.pointSize)
        controller.update(document: document, enabled: false, isActive: true, revision: 0, currentRevision: { 0 })
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(view.string, source + "!")
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(view.string, source + "!")
    }

    func testHasOnlyTextStructureRejectsStatefulElements() {
        let plain = MarkdownPresentationParser.parse("# Title\n\nSome **bold** text\n", includeEmojiCandidates: true)
        XCTAssertTrue(plain.hasOnlyTextStructure)
        // Сноски быстрый путь не закрывают: ссылки и определения сдвигаются вместе с текстом.
        XCTAssertTrue(MarkdownPresentationParser.parse("text[^1]\n\n[^1]: note\n", includeEmojiCandidates: true).hasOnlyTextStructure)
        // Диаграммы и вставки (аудио, iframe, details, HTML-блоки, ruby) быстрый путь не закрывают.
        for source in ["```mermaid\ngraph TD; A-->B\n```\n", "<audio src=\"a.mp3\" controls></audio>\n",
                       "<iframe src=\"https://example.invalid\" width=\"50%\" height=\"60\"></iframe>\n",
                       "<details>\n<summary>Sum</summary>\n\nbody\n</details>\n", "<div>\nraw html\n</div>\n",
                       "Words <ruby>漢字<rt>kanji</rt></ruby> end\n"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source, includeEmojiCandidates: true).hasOnlyTextStructure, source)
        }
        // Картинки, эмодзи и формулы, в том числе в таблицах, быстрый путь не закрывают.
        for source in ["![a](b.png)\n", "text :smile: text\n", "Math $y$ end\n", "| a |\n|---|\n| ![i](b.png) $y$ :smile: |\n"] {
            XCTAssertTrue(MarkdownPresentationParser.parse(source, includeEmojiCandidates: true).hasOnlyTextStructure, source)
        }
        XCTAssertFalse(MarkdownPresentationParser.parse("# Title\n", includeEmojiCandidates: false).hasOnlyTextStructure)
        XCTAssertTrue(MarkdownPresentationParser.parse("text\n\n```\ncode\n```\n", includeEmojiCandidates: true).hasOnlyTextStructure)
    }

    func testShiftedForTextEditMatchesReparse() throws {
        let source = "# Title\n\nSome **bold** text with [link](https://a.b) and [[wiki]] end\n"
        let raw = source as NSString
        let bold = raw.range(of: "bold")
        let paragraphEnd = NSMaxRange(raw.range(of: " end"))
        let edits: [(NSRange, String)] = [
            (NSRange(location: bold.location + 2, length: 0), "x"),
            (NSRange(location: paragraphEnd, length: 0), "x"),
            (NSRange(location: 7, length: 0), "x"),
            (NSRange(location: 11, length: 0), "x"),
            (NSRange(location: 12, length: 1), "")
        ]
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeWikiLinks: true)
        for (edit, replacement) in edits {
            let shifted = try XCTUnwrap(presentation.shiftedForTextEdit(edit, replacementLength: (replacement as NSString).length, textLength: raw.length), "\(edit)")
            let changed = raw.replacingCharacters(in: edit, with: replacement)
            let reparsed = MarkdownPresentationParser.parse(changed, includeEmojiCandidates: true, includeWikiLinks: true)
            XCTAssertEqual(shifted.spans, reparsed.spans, "\(edit)")
            XCTAssertEqual(shifted.paragraphs, reparsed.paragraphs, "\(edit)")
            XCTAssertEqual(shifted.links, reparsed.links, "\(edit)")
            XCTAssertEqual(shifted.wikiLinks, reparsed.wikiLinks, "\(edit)")
        }
    }

    /// Допускает ли фильтр правку: место задаётся подстрокой `after` (вставка сразу после неё) и числом удаляемых символов.
    private func allowsTyping(_ source: String, after: String, insert: String, remove: Int = 0, offset: Int = 0) -> Bool {
        let raw = source as NSString
        let location = (after.isEmpty ? 0 : NSMaxRange(raw.range(of: after))) + offset
        return MarkdownPresentation.allowsTypingEdit(in: raw, range: NSRange(location: location, length: remove), replacement: insert)
    }

    func testProseCharactersAreAllowed() {
        let source = "# Heading\n\nSome words here\nsecond line\n\nLast"
        for insert in ["x", "я", "5", ",", ".", "!", "?", ";", ":", "(", ")", "-", "«", "»", "—", "…", "“", "😀"] {
            XCTAssertTrue(allowsTyping(source, after: "Som", insert: insert), insert)
        }
        XCTAssertTrue(allowsTyping(source, after: "Some wor", insert: " "))
        XCTAssertTrue(allowsTyping(source, after: "Som", insert: "", remove: 1))
        XCTAssertTrue(allowsTyping(source, after: "Some w", insert: "", remove: 2))
    }

    func testFirstLetterOfProseLineIsAllowed() {
        let source = "# Heading\n\nSome words\nsecond line\n\nLast"
        XCTAssertTrue(allowsTyping(source, after: "\n\n", insert: "x"))
        XCTAssertTrue(allowsTyping(source, after: "words\n", insert: "x"))
        XCTAssertTrue(allowsTyping(source, after: "line\n\n", insert: "x"))
        XCTAssertTrue(MarkdownPresentation.allowsTypingEdit(in: "word at start\n" as NSString, range: NSRange(location: 0, length: 0), replacement: "x"))
    }

    func testBlankLineAndEndOfLineSpaceAreRejected() {
        let source = "first\n\nsecond\n"
        XCTAssertFalse(allowsTyping(source, after: "first\n", insert: "x"))
        XCTAssertFalse(allowsTyping(source, after: "first", insert: " "))
        XCTAssertFalse(allowsTyping("word at start\n", after: "word ", insert: "", remove: 2))
    }

    func testRiskyPunctuationIsRejected() {
        XCTAssertFalse(allowsTyping("Wait..\n", after: "Wait..", insert: "."))
        XCTAssertFalse(allowsTyping("a-\n", after: "a-", insert: "-"))
        XCTAssertFalse(allowsTyping("see www\n", after: "www", insert: "."))
        XCTAssertFalse(allowsTyping("a :x\n", after: "a ", insert: ":"))
        XCTAssertFalse(allowsTyping("a [x\n", after: "a ", insert: "!"))
        XCTAssertFalse(allowsTyping("[b] text\n", after: "[b]", insert: "("))
        XCTAssertFalse(allowsTyping("a\\b\n", after: "a\\", insert: ","))
        XCTAssertFalse(allowsTyping("[a](b text\n", after: "[a](b", insert: ")"))
        XCTAssertFalse(allowsTyping("mail me@x.y\n", after: "mail me", insert: "x"))
        for insert in ["$", "<", "*", "|", "\"", "'", "@"] {
            XCTAssertFalse(allowsTyping("some text\n", after: "some", insert: insert), insert)
        }
    }

    func testBlockMarkerLineHeadIsRejected() {
        XCTAssertFalse(allowsTyping("2024 was\n", after: "2024", insert: "."))
        XCTAssertFalse(allowsTyping("- item\n", after: "", insert: "x"))
        XCTAssertFalse(allowsTyping("- [ ] task\n", after: "-", insert: "я"))
        XCTAssertFalse(allowsTyping("- [ ] task\n", after: "", insert: "я"))
        XCTAssertFalse(allowsTyping("1. item\n", after: "1", insert: "я"))
        XCTAssertFalse(allowsTyping("1 item\n", after: "1", insert: "."))
        XCTAssertFalse(allowsTyping("Title\n-|--\n", after: "Title\n", insert: "x"))
        XCTAssertFalse(allowsTyping("text\n", after: "", insert: "#"))
        XCTAssertFalse(allowsTyping("    code\n", after: "    c", insert: "x"))
        XCTAssertTrue(allowsTyping("- [ ] task words\n", after: "task", insert: "x"))
        XCTAssertTrue(allowsTyping("Page 5\n", after: "Page 5", insert: "."))
    }

    func testSplitEmojiIsRejected() {
        let source = "a😀b\n"
        XCTAssertFalse(MarkdownPresentation.allowsTypingEdit(in: source as NSString, range: NSRange(location: 2, length: 1), replacement: ""))
        XCTAssertTrue(MarkdownPresentation.allowsTypingEdit(in: source as NSString, range: NSRange(location: 1, length: 2), replacement: ""))
    }

    func testHTMLAtContentStartIsRejected() {
        for source in ["> </details>\n", "- <div>\n", "1. <div>\n", "  <summary>x</summary>\n"] {
            let edit = NSRange(location: (source as NSString).length - 3, length: 0)
            XCTAssertFalse(MarkdownPresentation.allowsTypingEdit(in: source as NSString, range: edit, replacement: "x"), source)
        }
        XCTAssertTrue(MarkdownPresentation.allowsTypingEdit(in: "words <b>bold</b> end\n" as NSString, range: NSRange(location: 19, length: 0), replacement: "x"))
    }

    func testLinkDefinitionLineIsRejected() {
        for source in ["> [r]: /path/abc\n", "- [s]: rel.html\n"] {
            let edit = NSRange(location: (source as NSString).length - 3, length: 0)
            XCTAssertFalse(MarkdownPresentation.allowsTypingEdit(in: source as NSString, range: edit, replacement: "x"), source)
        }
    }

    func testListLineKeepsLengthWhenNextLineGrows() throws {
        let source = "- item one\nparagraph after\n"
        let raw = source as NSString
        let edit = NSRange(location: raw.range(of: "paragraph").location, length: 0)
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeWikiLinks: true)
        let shifted = try XCTUnwrap(presentation.shiftedForTextEdit(edit, replacementLength: 1, textLength: raw.length))
        let reparsed = MarkdownPresentationParser.parse(raw.replacingCharacters(in: edit, with: "x"), includeEmojiCandidates: true, includeWikiLinks: true)
        XCTAssertEqual(shifted.listMarkers, reparsed.listMarkers)
    }

    func testListLineGrowsAtEndOfText() throws {
        let source = "- item"
        let raw = source as NSString
        let edit = NSRange(location: raw.length, length: 0)
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeWikiLinks: true)
        let shifted = try XCTUnwrap(presentation.shiftedForTextEdit(edit, replacementLength: 1, textLength: raw.length))
        let reparsed = MarkdownPresentationParser.parse(raw.replacingCharacters(in: edit, with: "x"), includeEmojiCandidates: true, includeWikiLinks: true)
        XCTAssertEqual(shifted.listMarkers, reparsed.listMarkers)
    }

    func testAllowedTypingShiftMatchesReparse() throws {
        let source = "# Title\n\nFirst line of text\nsecond line here\n\n> quote words\n\nLast one, with text\n"
        let raw = source as NSString
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeWikiLinks: true)
        var checked = 0
        for (marker, insert, remove) in [("First", "x", 0), ("Firs", ",", 0), ("\nsecond", ".", 0), ("\n\nLast", "я", 0), ("quote", "", 1), ("one", ",", 0), ("with", "", 2), ("\nsecond", "x", 0)] {
            let edit = NSRange(location: NSMaxRange(raw.range(of: marker)), length: remove)
            guard MarkdownPresentation.allowsTypingEdit(in: raw, range: edit, replacement: insert),
                  let shifted = presentation.shiftedForTextEdit(edit, replacementLength: (insert as NSString).length, textLength: raw.length) else { continue }
            checked += 1
            let reparsed = MarkdownPresentationParser.parse(raw.replacingCharacters(in: edit, with: insert), includeEmojiCandidates: true, includeWikiLinks: true)
            XCTAssertEqual(shifted.spans, reparsed.spans, "\(edit)")
            XCTAssertEqual(shifted.paragraphs, reparsed.paragraphs, "\(edit)")
            XCTAssertEqual(shifted.links, reparsed.links, "\(edit)")
            XCTAssertEqual(shifted.textReplacements, reparsed.textReplacements, "\(edit)")
        }
        XCTAssertGreaterThan(checked, 3)
    }

    func testShiftedForTextEditRejectsMarkersAndBoundaries() {
        let source = "# Title\n\nSome **bold** text [link](https://a.b)\n"
        let raw = source as NSString
        let presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true)
        let bold = raw.range(of: "**bold**")
        let link = raw.range(of: "[link](https://a.b)")
        let rejected = [
            NSRange(location: 1, length: 0),
            NSRange(location: bold.location + 1, length: 0),
            NSRange(location: bold.location + 2, length: 0),
            NSRange(location: NSMaxRange(bold) - 2, length: 0),
            NSRange(location: NSMaxRange(bold), length: 0),
            NSRange(location: link.location + 2, length: 0),
            NSRange(location: NSMaxRange(link), length: 0),
            NSRange(location: 8, length: 2)
        ]
        for edit in rejected {
            XCTAssertNil(presentation.shiftedForTextEdit(edit, replacementLength: 1, textLength: raw.length), "\(edit)")
        }
    }

    private static let shiftSource = "# Title\n\nSome **bold** text with [link](https://a.b) and [[wiki]] end\n\n> quote words\n> second line\n\n- item one\n- [x] done task\n  - [x] inner done\n- [ ] open task\n\nLast paragraph, with text\n"

    private func parsedForShift(_ source: String) -> MarkdownPresentation {
        var presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeWikiLinks: true)
        presentation.prepareForEditing()
        return presentation
    }

    /// Списки, которые сдвиг обязан вести так же, как полный разбор.
    private func assertSameLists(_ shifted: MarkdownPresentation, _ reparsed: MarkdownPresentation, _ message: String) {
        XCTAssertEqual(shifted.spans, reparsed.spans, message)
        XCTAssertEqual(shifted.spanEnds, reparsed.spanEnds, message)
        XCTAssertEqual(shifted.codeBlocks, reparsed.codeBlocks, message)
        XCTAssertEqual(shifted.paragraphs, reparsed.paragraphs, message)
        XCTAssertEqual(shifted.links, reparsed.links, message)
        XCTAssertEqual(shifted.wikiLinks, reparsed.wikiLinks, message)
        XCTAssertEqual(shifted.listMarkers, reparsed.listMarkers, message)
        XCTAssertEqual(shifted.taskCheckboxes, reparsed.taskCheckboxes, message)
        XCTAssertEqual(shifted.textReplacements, reparsed.textReplacements, message)
        XCTAssertEqual(shifted.completedTaskRanges, reparsed.completedTaskRanges, message)
        XCTAssertEqual(shifted.completedEnds, reparsed.completedEnds, message)
        XCTAssertEqual(shifted.images, reparsed.images, message)
        XCTAssertEqual(shifted.formulas, reparsed.formulas, message)
        XCTAssertEqual(shifted.inlineFormulas, reparsed.inlineFormulas, message)
        XCTAssertEqual(shifted.emojiCandidates, reparsed.emojiCandidates, message)
        XCTAssertEqual(shifted.namedAnchors, reparsed.namedAnchors, message)
        XCTAssertEqual(shifted.pageBreaks, reparsed.pageBreaks, message)
        XCTAssertEqual(shifted.tableOfContents, reparsed.tableOfContents, message)
        XCTAssertEqual(shifted.footnotes, reparsed.footnotes, message)
        XCTAssertEqual(shifted.diagrams, reparsed.diagrams, message)
        XCTAssertEqual(shifted.audioBlocks, reparsed.audioBlocks, message)
        XCTAssertEqual(shifted.iframeBlocks, reparsed.iframeBlocks, message)
        XCTAssertEqual(shifted.detailsBlocks, reparsed.detailsBlocks, message)
        XCTAssertEqual(shifted.htmlBlocks, reparsed.htmlBlocks, message)
        XCTAssertEqual(shifted.ruby, reparsed.ruby, message)
    }

    private static let elementSources = [
        "Intro words here\n\n![block](a.png)\n\nMiddle words with ![inline](b.png) image\n\nTail words here\n",
        "Start words\n\n$$\nx = 1\n$$\n\nInline $y^2$ math words\n\nTail words\n",
        "Words :smile: more\n\nPara 😀 with :heart: end\n\nTail :rocket: words\n",
        "Start words[^a] and more[^b] 😀 end.\n\nSecond para[^a] words.\n\n[^b]: Вторая сноска.\n\n[^a]: Первая 😀.\n\nTail words here.\n",
        "Intro words\n\n<a name=\"top\"></a>\n\n[toc]\n\n# One\n\ntext\n\n<div style=\"page-break-after: always\"></div>\n\nAfter break words\n",
        "Words <ruby>漢字<rt>kanji</rt></ruby> end\n\nSecond words here\n",
        "Intro words\n\n```mermaid\ngraph TD; A-->B\n```\n\nBetween words\n\n<details>\n<summary>Sum</summary>\n\nbody words\n</details>\n\nMore words\n\n<audio src=\"a.mp3\" controls></audio>\n\n<div>\nraw html\n</div>\n\nTail words\n",
    ]

    /// `canShiftElements` не смотрит на `hasOnlyTextStructure`: для элементов, закрывающих быстрый путь (сноски, диаграммы и т. п.), диапазоны тоже должны сдвигаться верно.
    func testShiftMovesElementsOutsideEdit() {
        var checked = 0
        for source in Self.elementSources {
            let raw = source as NSString
            for marker in ["Intro word", "Intro", "Start word", "Middle word", "Words", "Between word", "More word", "Second word", "Tail word", "Tail", "After break word", "text", "Second para"] {
                let found = raw.range(of: marker)
                guard found.location != NSNotFound else { continue }
                for (offset, insert) in [(0, "x"), (0, "😀")] {
                    let edit = NSRange(location: NSMaxRange(found) + offset, length: 0)
                    var presentation = parsedForShift(source)
                    let change = MarkdownTextEdit(range: edit, replacementLength: (insert as NSString).length, textLength: raw.length)
                    guard presentation.canShiftElements(change) else { continue }
                    checked += 1
                    presentation.shift(change)
                    assertSameLists(presentation, parsedForShift(raw.replacingCharacters(in: edit, with: insert)), "\(marker) \(source)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 25)
    }

    func testShiftChainWithElements() {
        let source = Self.elementSources[3]
        var text = source as NSString
        var presentation = parsedForShift(source)
        var steps = 0
        for marker in ["Tail words", "Second pa", "Start wor", "Tail wor"] {
            let edit = NSRange(location: NSMaxRange(text.range(of: marker)), length: 0)
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: text.length)
            guard presentation.canShiftElements(change) else { continue }
            presentation.shift(change)
            text = text.replacingCharacters(in: edit, with: "x") as NSString
            steps += 1
            assertSameLists(presentation, parsedForShift(text as String), marker)
        }
        XCTAssertGreaterThanOrEqual(steps, 3)
    }

    private static let insertSource = "Intro words\n\n```mermaid\ngraph TD; A-->B\n```\n\nBetween words\n\n<audio src=\"a.mp3\" controls></audio>\n\nAudio tail words\n\n<iframe src=\"https://example.invalid\" width=\"50%\" height=\"60\"></iframe>\n\nFrame tail words\n\n<details>\n<summary>Sum</summary>\n\nbody words\n</details>\n\nDetails tail words\n\n<div>\nraw html\n</div>\n\nHtml tail words\n\nRuby <ruby>漢字<rt>kanji</rt></ruby> end\n\nTail words\n"

    func testShiftMovesDiagramsAndInsertsLikeReparse() {
        let source = Self.insertSource
        let raw = source as NSString
        let original = parsedForShift(source)
        XCTAssertFalse(original.diagrams.isEmpty)
        XCTAssertFalse(original.audioBlocks.isEmpty)
        XCTAssertFalse(original.iframeBlocks.isEmpty)
        XCTAssertFalse(original.detailsBlocks.isEmpty)
        XCTAssertFalse(original.htmlBlocks.isEmpty)
        XCTAssertFalse(original.ruby.isEmpty)
        var checked = 0
        for marker in ["Intro wor", "Between wor", "Audio tail wor", "Frame tail wor", "Details tail wor", "Html tail wor", "Ruby ", "Tail wor"] {
            let edit = NSRange(location: NSMaxRange(raw.range(of: marker)), length: 0)
            var presentation = original
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)
            guard presentation.canShift(change) else { continue }
            checked += 1
            presentation.shift(change)
            assertSameLists(presentation, parsedForShift(raw.replacingCharacters(in: edit, with: "x")), marker)
        }
        XCTAssertGreaterThanOrEqual(checked, 6)
    }

    func testShiftChainWithInserts() {
        var text = Self.insertSource as NSString
        var presentation = parsedForShift(text as String)
        var steps = 0
        for marker in ["Tail wor", "Intro wor", "Html tail wor", "Between wor", "Intro wor"] {
            let edit = NSRange(location: NSMaxRange(text.range(of: marker)), length: 0)
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: text.length)
            guard presentation.canShift(change) else { continue }
            presentation.shift(change)
            text = text.replacingCharacters(in: edit, with: "x") as NSString
            steps += 1
            assertSameLists(presentation, parsedForShift(text as String), marker)
        }
        XCTAssertGreaterThanOrEqual(steps, 4)
    }

    func testSpacedKeepsGapAroundRawInserts() {
        let edit = MarkdownTextEdit(range: NSRange(location: 10, length: 0), replacementLength: 1, textLength: 40)
        XCTAssertEqual(edit.spaced(NSRange(location: 0, length: 8)), NSRange(location: 0, length: 8))
        XCTAssertNil(edit.spaced(NSRange(location: 0, length: 9)))
        XCTAssertNil(edit.spaced(NSRange(location: 0, length: 10)))
        XCTAssertNil(edit.spaced(NSRange(location: 10, length: 5)))
        XCTAssertNil(edit.spaced(NSRange(location: 11, length: 5)))
        XCTAssertEqual(edit.spaced(NSRange(location: 12, length: 5)), NSRange(location: 13, length: 5))
        let reach = edit.reaching(1)
        XCTAssertEqual(reach.range, NSRange(location: 9, length: 2))
        XCTAssertEqual(edit.reaching(100).range.location, 0)
    }

    func testShiftRejectsEditsNextToRawInserts() {
        let source = Self.insertSource
        let raw = source as NSString
        let original = parsedForShift(source)
        let html = original.htmlBlocks[0].range
        for (offset, accepted) in [(-3, true), (-1, false), (0, false), (1, false), (html.length, false), (html.length + 1, false), (html.length + 2, true)] {
            let edit = NSRange(location: html.location + offset, length: 0)
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)
            XCTAssertEqual(original.canShift(change), accepted, "\(offset)")
        }
        // Диаграмма и ruby: вплотную правка отклоняется, на расстоянии принимается.
        let diagram = original.diagrams[0].range, ruby = original.ruby[0].range
        for range in [diagram, ruby] {
            for edit in [NSRange(location: range.location, length: 0), NSRange(location: range.location + 1, length: 0), NSRange(location: NSMaxRange(range), length: 0)] {
                XCTAssertFalse(original.canShift(MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)), "\(edit)")
            }
        }
    }

    /// Печать "x" в каждой позиции текста: всё, что приняли `allowsTypingEdit` и `canShift`, обязано дать те же списки, что полный разбор. Возвращает число принятых правок.
    @discardableResult
    private func assertAcceptedEditsMatchReparse(_ source: String) -> Int {
        let raw = source as NSString
        let original = parsedForShift(source)
        var accepted = 0
        for location in 0...raw.length {
            let edit = NSRange(location: location, length: 0)
            guard MarkdownPresentation.allowsTypingEdit(in: raw, range: edit, replacement: "x") else { continue }
            var presentation = original
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)
            guard presentation.canShift(change) else { continue }
            accepted += 1
            presentation.shift(change)
            assertSameLists(presentation, parsedForShift(raw.replacingCharacters(in: edit, with: "x")), "\(location)")
        }
        return accepted
    }

    /// Вплотную к вставке (в самой вставке, на её границах и на соседней строке впритык) `canShift` отказывает, дальше принимает.
    /// Границы берутся из диапазона вставки и текста: `left` и `right` — слова по обе стороны, `separator` — разделитель между ними и вставкой.
    private func assertGapAroundInsert(_ source: String, block: NSRange, left: String, right: String, separator: String, accepts: Bool = true) {
        let raw = source as NSString
        let original = parsedForShift(source)
        let leftEnd = NSMaxRange(raw.range(of: left)), rightStart = raw.range(of: right).location
        XCTAssertEqual(leftEnd + (separator as NSString).length, block.location)
        XCTAssertEqual(NSMaxRange(block) + (separator as NSString).length, rightStart)
        for location in (block.location - 1)...(NSMaxRange(block) + 1) {
            let change = MarkdownTextEdit(range: NSRange(location: location, length: 0), replacementLength: 1, textLength: raw.length)
            XCTAssertFalse(original.canShift(change), "\(location)")
        }
        guard accepts else { return }
        for location in [leftEnd, rightStart] {
            let change = MarkdownTextEdit(range: NSRange(location: location, length: 0), replacementLength: 1, textLength: raw.length)
            XCTAssertTrue(original.canShift(change), "\(location)")
        }
    }

    func testSpacedEditsAroundHTMLBlock() throws {
        let source = "Before words\n\n<div><p>raw html</p></div>\n\nAfter words\n"
        let block = try XCTUnwrap(parsedForShift(source).htmlBlocks.first).range
        assertGapAroundInsert(source, block: block, left: "Before words", right: "After words", separator: "\n\n")
        XCTAssertGreaterThan(assertAcceptedEditsMatchReparse(source), 0)
    }

    func testSpacedRejectsEditFlushWithHTMLBlock() throws {
        // Блок вплотную к абзацу сверху: печать в конце слова меняла бы границу блока.
        let source = "Before words\n<div><p>raw html</p></div>\n\nAfter words\n"
        let original = parsedForShift(source)
        let block = try XCTUnwrap(original.htmlBlocks.first).range
        let leftEnd = NSMaxRange((source as NSString).range(of: "Before words"))
        XCTAssertEqual(leftEnd + 1, block.location)
        XCTAssertFalse(original.canShift(MarkdownTextEdit(range: NSRange(location: leftEnd, length: 0), replacementLength: 1, textLength: (source as NSString).length)))
        assertAcceptedEditsMatchReparse(source)
    }

    func testSpacedAtEndOfText() throws {
        // Блок в самом конце текста: печать у его конца отклоняется, у слова выше принимается.
        let ending = "Before words\n\n<div><p>raw html</p></div>"
        let original = parsedForShift(ending)
        let block = try XCTUnwrap(original.htmlBlocks.first).range
        let raw = ending as NSString
        XCTAssertEqual(NSMaxRange(block), raw.length)
        XCTAssertFalse(original.canShift(MarkdownTextEdit(range: NSRange(location: raw.length, length: 0), replacementLength: 1, textLength: raw.length)))
        XCTAssertTrue(original.canShift(MarkdownTextEdit(range: NSRange(location: NSMaxRange(raw.range(of: "Before words")), length: 0), replacementLength: 1, textLength: raw.length)))
        XCTAssertGreaterThan(assertAcceptedEditsMatchReparse(ending), 0)
        // Блок вначале, слово в конце текста без перевода строки: печать в конце слова принимается.
        let tail = "<div><p>raw html</p></div>\n\nTail words"
        let rawTail = tail as NSString
        let tailPresentation = parsedForShift(tail)
        XCTAssertFalse(tailPresentation.htmlBlocks.isEmpty)
        XCTAssertTrue(tailPresentation.canShift(MarkdownTextEdit(range: NSRange(location: rawTail.length, length: 0), replacementLength: 1, textLength: rawTail.length)))
        XCTAssertGreaterThan(assertAcceptedEditsMatchReparse(tail), 0)
    }

    func testSpacedWithCRLF() throws {
        let source = "Before words\r\n\r\n<div><p>raw html</p></div>\r\n\r\nAfter words\r\n"
        let block = try XCTUnwrap(parsedForShift(source).htmlBlocks.first).range
        // Принятие при CRLF быстрый путь может не обещать, поэтому проверяются отказы у вставки и совпадение принятого с разбором.
        assertGapAroundInsert(source, block: block, left: "Before words", right: "After words", separator: "\r\n\r\n", accepts: false)
        assertAcceptedEditsMatchReparse(source)
    }

    func testSpacedAroundDetailsWithNestedElements() throws {
        let details = "<details open><summary><strong>More &amp; 中文</strong></summary><em>Body</em> <a href='https://example.com'>link</a></details>"
        let source = "Before words\n\n" + details + "\n\nAfter words\n"
        let block = try XCTUnwrap(parsedForShift(source).detailsBlocks.first).range
        XCTAssertEqual((source as NSString).substring(with: block), details)
        assertGapAroundInsert(source, block: block, left: "Before words", right: "After words", separator: "\n\n")
        XCTAssertGreaterThan(assertAcceptedEditsMatchReparse(source), 0)
    }

    func testRubyInsideTableKeepsOldPath() {
        let source = "Intro words\n\n| a | b |\n|---|---|\n| <ruby>漢字<rt>kanji</rt></ruby> | 2 |\n\nTail words\n"
        let raw = source as NSString
        var presentation = MarkdownPresentationParser.parse(source, includeEmojiCandidates: true, includeWikiLinks: true)
        presentation.prepareForEditing()
        XCTAssertFalse(presentation.ruby.isEmpty)
        let edit = NSRange(location: NSMaxRange(raw.range(of: "Intro wor")), length: 0)
        XCTAssertNil(presentation.shiftedForTextEdit(edit, replacementLength: 1, textLength: raw.length))
        // Ruby вне таблицы при таблице в документе быстрый путь не закрывает.
        let outside = "Intro words\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nRuby <ruby>漢字<rt>kanji</rt></ruby> end\n\nTail words\n"
        let rawOutside = outside as NSString
        var other = MarkdownPresentationParser.parse(outside, includeEmojiCandidates: true, includeWikiLinks: true)
        other.prepareForEditing()
        XCTAssertFalse(other.ruby.isEmpty)
        XCTAssertNotNil(other.shiftedForTextEdit(NSRange(location: NSMaxRange(rawOutside.range(of: "Intro wor")), length: 0), replacementLength: 1, textLength: rawOutside.length))
    }

    func testShiftRejectsEditsTouchingElements() {
        let source = "Words ![inline](b.png) end.\n\nMath $y$ end.\n\nSecond[^a] para.\n\n[^a]: note\n"
        let raw = source as NSString
        let presentation = parsedForShift(source)
        let control = NSRange(location: 3, length: 0)
        XCTAssertTrue(presentation.canShiftElements(MarkdownTextEdit(range: control, replacementLength: 1, textLength: raw.length)))
        let image = raw.range(of: "![inline](b.png)")
        let formula = raw.range(of: "$y$")
        let marker = raw.range(of: "[^a]")
        for edit in [NSRange(location: image.location, length: 0), NSRange(location: image.location + 3, length: 0), NSRange(location: NSMaxRange(image), length: 0),
                     NSRange(location: formula.location + 1, length: 0), NSRange(location: NSMaxRange(formula), length: 0),
                     NSRange(location: marker.location + 1, length: 0), NSRange(location: NSMaxRange(marker), length: 0)] {
            XCTAssertFalse(presentation.canShiftElements(MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)), "\(edit)")
        }
    }

    func testShiftDropsHeadingTouchedByEdit() {
        let source = "# One\n\ntext words\n\n## Two\n\nmore words\n"
        let raw = source as NSString
        let edit = NSRange(location: NSMaxRange(raw.range(of: "## Tw")), length: 0)
        var presentation = parsedForShift(source)
        let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)
        XCTAssertTrue(presentation.canShiftElements(change))
        presentation.shift(change)
        XCTAssertEqual(presentation.headings.map(\.title), ["One"])
        let after = NSRange(location: NSMaxRange(raw.range(of: "text wor")), length: 0)
        var other = parsedForShift(source)
        let change2 = MarkdownTextEdit(range: after, replacementLength: 1, textLength: raw.length)
        XCTAssertTrue(other.canShiftElements(change2))
        other.shift(change2)
        XCTAssertEqual(other.headings, parsedForShift(raw.replacingCharacters(in: after, with: "x")).headings)
    }

    func testUnorderedElementsAreNotReadyForShift() {
        let first = MarkdownImage(range: NSRange(location: 0, length: 5), paragraphRange: NSRange(location: 0, length: 5), url: "a.png", alt: "", title: nil)
        let second = MarkdownImage(range: NSRange(location: 10, length: 5), paragraphRange: NSRange(location: 10, length: 5), url: "b.png", alt: "", title: nil)
        var ordered = MarkdownPresentation(spans: [], images: [first, second], emojiCandidatesIncluded: true)
        ordered.prepareForEditing()
        XCTAssertTrue(ordered.isReadyForShift)
        var reversed = MarkdownPresentation(spans: [], images: [second, first], emojiCandidatesIncluded: true)
        reversed.prepareForEditing()
        XCTAssertFalse(reversed.isReadyForShift)
    }

    func testInPlaceShiftMatchesReparseAndWrapper() throws {
        let source = Self.shiftSource
        let raw = source as NSString
        var checked = 0
        for (marker, insert, remove) in [("Some **bold", "x", 0), ("**bol", "я", 0), ("with [lin", "k", 0), ("and [[wi", "z", 0), ("quote", "s", 0), ("second", "", 1), ("item on", "e", 0),
                                         ("done tas", "k", 0), ("inner don", "e", 0), ("open ta", "", 2), ("Last paragraph, wi", "x", 0), ("text\n", "x", 0), ("# Titl", "e", 0), ("Last", ",", 0)] {
            let edit = NSRange(location: NSMaxRange(raw.range(of: marker)), length: remove)
            let length = (insert as NSString).length
            var presentation = parsedForShift(source)
            let change = MarkdownTextEdit(range: edit, replacementLength: length, textLength: raw.length)
            guard presentation.canShift(change) else { continue }
            checked += 1
            presentation.shift(change)
            let reparsed = parsedForShift(raw.replacingCharacters(in: edit, with: insert))
            assertSameLists(presentation, reparsed, "\(edit) \(insert)")
            let wrapped = try XCTUnwrap(parsedForShift(source).shiftedForTextEdit(edit, replacementLength: length, textLength: raw.length))
            assertSameLists(wrapped, presentation, "wrapper \(edit)")
        }
        XCTAssertGreaterThan(checked, 8)
    }

    func testShiftChainKeepsPrefixEndsAndOrder() {
        var text = Self.shiftSource as NSString
        var presentation = parsedForShift(text as String)
        for (marker, insert) in [("bold", "x"), ("second line", "y"), ("done task", "z"), ("Title", "w"), ("Some", "v"), ("inner done", "u")] {
            let edit = NSRange(location: NSMaxRange(text.range(of: marker)), length: 0)
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: text.length)
            guard presentation.canShift(change) else { continue }
            presentation.shift(change)
            text = text.replacingCharacters(in: edit, with: insert) as NSString
            XCTAssertEqual(presentation.spans.map(\.range.location), presentation.spans.map(\.range.location).sorted(), marker)
            var peak = 0
            XCTAssertEqual(presentation.spanEnds, presentation.spans.map { peak = max(peak, NSMaxRange($0.range)); return peak }, marker)
            peak = 0
            XCTAssertEqual(presentation.completedEnds, presentation.completedTaskRanges.map { peak = max(peak, NSMaxRange($0)); return peak }, marker)
            assertSameLists(presentation, parsedForShift(text as String), marker)
        }
    }

    func testParagraphBreakMatchesReparse() {
        for source in ["abc\n\nnext\n", "abc", "abc\n", "a\nb\n\nnext", "# H\n\nabc\n\nnext", "para\n\n\n\nlast\n\n", "Title\n=====\n\nbody\n",
                       "abc\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\ntail words", "abc\n\n```swift\nlet x = 1\n```\n\nafter words\n",
                       "abc\n| a | b |\n|---|---|\n| 1 | 2 |\n"] {
            let raw = source as NSString
            let presentation = parsedForShift(source)
            var accepted = 0
            for location in 0...raw.length {
                guard let change = presentation.paragraphBreakEdit(in: raw, at: location) else { continue }
                accepted += 1
                var shifted = presentation
                shifted.shift(change)
                let reparsed = parsedForShift(raw.replacingCharacters(in: NSRange(location: location, length: 0), with: "\n"))
                assertSameLists(shifted, reparsed, "\(source.debugDescription) at \(location)")
                XCTAssertEqual(shifted.emojiCompletionRanges, reparsed.emojiCompletionRanges, "\(source.debugDescription) at \(location)")
                XCTAssertEqual(shifted.tables, reparsed.tables, "\(source.debugDescription) at \(location)")
            }
            if source.hasPrefix("abc\n|") { XCTAssertEqual(accepted, 0, source) } else { XCTAssertGreaterThan(accepted, 0, source) }
        }
    }

    func testParagraphBreakAcceptsExpectedPlaces() {
        for (source, places) in [("abc\n\nnext\n", [3, 9]), ("abc", [3]), ("abc\n", [3])] {
            let presentation = parsedForShift(source)
            let raw = source as NSString
            let accepted = (0...raw.length).filter { presentation.paragraphBreakEdit(in: raw, at: $0) != nil }
            XCTAssertEqual(accepted, places, source)
        }
    }

    func testParagraphBreakFallsBack() {
        for (source, location) in [("abc\nnext\n", 3), ("ab\n\nx", 1), ("abc \n\nx", 4), ("abc\\\n\nx", 4), ("abc\n\n\nx", 4), ("# Head\n\nx", 6),
                                   ("> q\n\nx", 3), ("- item\n\nx", 6), ("1. num", 6), ("- a\n\n  b\n", 8), ("abc\r\n\r\nx", 3),
                                   ("http://a.b\n\nx", 10), ("| a |\n|---|\n| b |\n\nx", 5)] {
            let presentation = parsedForShift(source)
            XCTAssertNil(presentation.paragraphBreakEdit(in: source as NSString, at: location), "\(source.debugDescription) at \(location)")
        }
        let reference = parsedForShift("[r]: u\n\nx")
        XCTAssertNil(reference.paragraphBreakEdit(in: "[r]: u\n\nx" as NSString, at: 6))
    }

    func testParagraphBreakDoesNotChangeTypingRules() {
        let source = "abc\n\nnext\n"
        var presentation = parsedForShift(source)
        let change = MarkdownTextEdit(range: NSRange(location: 3, length: 0), replacementLength: 1, textLength: (source as NSString).length)
        XCTAssertFalse(change.lineBreak)
        XCTAssertTrue(presentation.canShift(change))
        presentation.shift(change)
        let reparsed = parsedForShift("abcx\n\nnext\n")
        assertSameLists(presentation, reparsed, "typing")
        XCTAssertEqual(presentation.emojiCompletionRanges, reparsed.emojiCompletionRanges)
    }

    private static let codeSources = [
        "intro text\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nafter words\n",
        "```js\nlet a;\n```\n\ntail words\n",
        "first words\n\n```c\nint a;\n```\n\nmiddle words\n\n```py\nprint(1)\n```\n\nlast words\n",
        "intro text\n\n~~~\nplain\n~~~\n\nafter words\n",
        "> quote line\n>\n> ```js\n> let a = 1;\n> ```\n>\n> after code\n\ntext\n",
        "- item words\n\n  ```py\n  print(1)\n  ```\n\n  more item\n- second\n",
        "intro\r\n\r\n```c\r\nint x;\r\n```\r\n\r\nafter\r\n",
        "intro text\n\n```\nunclosed body\nlines\n",
        "intro text\n\n```\nno language\n```\n\nafter words\n"
    ]

    func testShiftMovesCodeBlocksOutsideEdit() {
        var checked = 0
        for source in Self.codeSources {
            let raw = source as NSString
            XCTAssertFalse(parsedForShift(source).codeBlocks.isEmpty, source)
            for marker in ["intro tex", "intro", "first word", "middle word", "after word", "after", "last word", "tail word", "quote lin", "item word", "more ite", "second", "text\n"] {
                let found = raw.range(of: marker)
                guard found.location != NSNotFound else { continue }
                let edit = NSRange(location: NSMaxRange(found), length: 0)
                var presentation = parsedForShift(source)
                let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)
                guard presentation.canShift(change) else { continue }
                checked += 1
                presentation.shift(change)
                assertSameLists(presentation, parsedForShift(raw.replacingCharacters(in: edit, with: "x")), "\(marker) \(source)")
            }
        }
        XCTAssertGreaterThan(checked, 15)
    }

    func testShiftRejectsEditInsideCodeBlockCoveredByQuote() {
        let source = "> ```\n> let first = 1\n> ```\n"
        let raw = source as NSString
        let edit = NSRange(location: raw.range(of: "first").location + 2, length: 0)
        XCTAssertFalse(parsedForShift(source).canShift(MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)))
    }

    func testShiftRejectsEditInsideOrAtCodeBlockBoundary() {
        let source = "intro text\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nafter words\n"
        let raw = source as NSString
        let block = raw.range(of: "```swift\nlet x = 1\nlet y = 2\n```")
        let rejected = [
            NSRange(location: raw.range(of: "let x").location + 2, length: 0), NSRange(location: raw.range(of: "swift").location + 2, length: 0),
            NSRange(location: block.location, length: 0), NSRange(location: NSMaxRange(block), length: 0),
            NSRange(location: NSMaxRange(block) - 1, length: 0)
        ]
        let original = parsedForShift(source)
        for edit in rejected {
            let presentation = original
            XCTAssertFalse(presentation.canShift(MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)), "\(edit)")
            XCTAssertEqual(presentation.codeBlocks, original.codeBlocks, "\(edit)")
            XCTAssertEqual(presentation.spans, original.spans, "\(edit)")
        }
        let quoted = "> quote line\n>\n> ```js\n> let a = 1;\n> ```\n\ntext\n"
        let rawQuoted = quoted as NSString
        let inside = NSRange(location: rawQuoted.range(of: "let a").location + 2, length: 0)
        XCTAssertFalse(parsedForShift(quoted).canShift(MarkdownTextEdit(range: inside, replacementLength: 1, textLength: rawQuoted.length)))
    }

    func testShiftChainWithCodeBlocks() {
        var text = "first words\n\n```c\nint a;\n```\n\nmiddle words\n\n```py\nprint(1)\n```\n\nlast words\n" as NSString
        var presentation = parsedForShift(text as String)
        var applied = 0
        for (marker, insert) in [("first", "x"), ("middle", "y"), ("first", "z"), ("last", "v")] {
            let edit = NSRange(location: NSMaxRange(text.range(of: marker)), length: 0)
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: text.length)
            guard presentation.canShift(change) else { continue }
            presentation.shift(change)
            applied += 1
            text = text.replacingCharacters(in: edit, with: insert) as NSString
            assertSameLists(presentation, parsedForShift(text as String), marker)
        }
        XCTAssertGreaterThanOrEqual(applied, 3)
    }

    private static let footnoteSource = "Start words[^a] and more[^b] 😀 end.\n\nSecond para[^a] words.\n\n[^b]: Вторая сноска.\n\n[^a]: Первая 😀.\n\nTail words here.\n"

    func testShiftMovesFootnotesOutsideEdit() {
        let source = Self.footnoteSource
        let raw = source as NSString
        XCTAssertEqual(parsedForShift(source).footnotes.count, 3)
        var checked = 0
        for marker in ["Start", "Second", "Tail", "and mo"] {
            for insert in ["x", "😀", ""] {
                let found = raw.range(of: marker)
                let edit = NSRange(location: NSMaxRange(found) - (insert.isEmpty ? 1 : 0), length: insert.isEmpty ? 1 : 0)
                var presentation = parsedForShift(source)
                let change = MarkdownTextEdit(range: edit, replacementLength: (insert as NSString).length, textLength: raw.length)
                guard presentation.canShift(change) else { continue }
                checked += 1
                presentation.shift(change)
                assertSameLists(presentation, parsedForShift(raw.replacingCharacters(in: edit, with: insert)), "\(marker) \(insert)")
            }
        }
        XCTAssertGreaterThan(checked, 8)
    }

    func testShiftRejectsFootnoteBodyAndMarkerEdits() {
        // Правка в ленивой строке продолжения определения: `allowsTypingEdit` её пропускает, отказывает `covered` (тело определения не покрыто блоком).
        let lazy = "Text[^1] here.\n\n[^1]: Первая\nленивое продолжение\n\nПосле слов.\n"
        let inList = "- item[^1] words\n\n  [^1]: в пункте\n  продолжение\n\nПосле.\n"
        for (source, inside) in [(lazy, "продолжение"), (inList, "продолжение")] {
            let raw = source as NSString
            XCTAssertEqual(parsedForShift(source).footnotes.count, 1, source)
            let body = NSRange(location: raw.range(of: inside).location + 3, length: 0)
            XCTAssertTrue(MarkdownPresentation.allowsTypingEdit(in: raw, range: body, replacement: "x"), source)
            XCTAssertFalse(parsedForShift(source).canShift(MarkdownTextEdit(range: body, replacementLength: 1, textLength: raw.length)), source)
            let reference = raw.range(of: "[^1]")
            let definition = raw.range(of: "[^1]:")
            for location in [reference.location, NSMaxRange(reference), reference.location + 2, definition.location, definition.location + 2] {
                let edit = NSRange(location: location, length: 0)
                XCTAssertFalse(parsedForShift(source).canShift(MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)), "\(location) \(source)")
            }
        }
    }

    func testShiftChainWithFootnotes() {
        var text = Self.footnoteSource as NSString
        var presentation = parsedForShift(text as String)
        var applied = 0
        for (marker, insert) in [("Start", "x"), ("and more", "😀"), ("Second", "y"), ("Первая", "z"), ("Tail", "v")] {
            let edit = NSRange(location: NSMaxRange(text.range(of: marker)), length: 0)
            let change = MarkdownTextEdit(range: edit, replacementLength: (insert as NSString).length, textLength: text.length)
            guard presentation.canShift(change) else { continue }
            presentation.shift(change)
            applied += 1
            text = text.replacingCharacters(in: edit, with: insert) as NSString
            assertSameLists(presentation, parsedForShift(text as String), marker)
        }
        XCTAssertGreaterThanOrEqual(applied, 4)
    }

    private static let tableSource = "Intro words\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nbetween text\n\n> quote above\n>\n> | q1 | q2 |\n> |----|----|\n> | x  | y  |\n\n| c | d |\n|---|---|\n| 3 | 4 |\n\ntail words\n"

    func testInPlaceShiftMovesTablesOutsideEdit() throws {
        let source = Self.tableSource
        let raw = source as NSString
        var checked = 0
        for (marker, insert, remove) in [("Intro wo", "x", 0), ("between te", "я", 0), ("between", "", 1), ("quote ab", "x", 0), ("tail wo", "x", 0), ("tail", ",", 0)] {
            let edit = NSRange(location: NSMaxRange(raw.range(of: marker)), length: remove)
            let length = (insert as NSString).length
            var presentation = parsedForShift(source)
            let change = MarkdownTextEdit(range: edit, replacementLength: length, textLength: raw.length)
            guard presentation.canShift(change) else { continue }
            checked += 1
            presentation.shift(change)
            let reparsed = parsedForShift(raw.replacingCharacters(in: edit, with: insert))
            XCTAssertEqual(presentation.tables, reparsed.tables, "\(edit) \(insert)")
            XCTAssertEqual(presentation.tables.map(\.delimiterRange), reparsed.tables.map(\.delimiterRange), "\(edit) \(insert)")
            XCTAssertEqual(presentation.tables.flatMap(\.rows).flatMap(\.cells).map(\.range),
                           reparsed.tables.flatMap(\.rows).flatMap(\.cells).map(\.range), "\(edit) \(insert)")
            assertSameLists(presentation, reparsed, "\(edit) \(insert)")
        }
        XCTAssertGreaterThanOrEqual(checked, 4)
    }

    func testShiftRejectsEditsTouchingTables() {
        let source = Self.tableSource
        let raw = source as NSString
        let table = raw.range(of: "| a | b |"), delimiter = raw.range(of: "|---|---|"), lastRow = raw.range(of: "| 1 | 2 |")
        let rejected = [
            NSRange(location: table.location + 3, length: 0), NSRange(location: delimiter.location + 2, length: 0),
            NSRange(location: table.location, length: 0), NSRange(location: NSMaxRange(lastRow), length: 0),
            NSRange(location: NSMaxRange(lastRow) + 1, length: 0), NSRange(location: lastRow.location, length: 0)
        ]
        let original = parsedForShift(source)
        for edit in rejected {
            var presentation = original
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)
            XCTAssertFalse(presentation.canShift(change), "\(edit)")
            if presentation.canShift(change) { presentation.shift(change) }
            XCTAssertEqual(presentation.tables, original.tables, "\(edit)")
            assertSameLists(presentation, original, "\(edit)")
        }
    }

    func testShiftRejectsEditInsideTableCoveredByQuote() {
        let source = "> | first column text | second column text |\n> |---|---|\n> | one | two |\n"
        let raw = source as NSString
        let edit = NSRange(location: raw.range(of: "column").location + 2, length: 0)
        XCTAssertFalse(parsedForShift(source).canShift(MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)))
    }

    func testReplacingTableChecksOnlyNewTableCells() throws {
        let plain = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let withMath = "| $x$ | b |\n|---|---|\n| 1 | 2 |\n"
        let original = parsedForShift(plain)
        let oldRange = try XCTUnwrap(original.tables.first).range
        let edit = NSRange(location: 2, length: 1)
        var kept = original.replacingTable(try XCTUnwrap(parsedForShift(plain).tables.first), oldTable: oldRange, edit: edit, replacementLength: 1)
        kept.prepareForEditing()
        XCTAssertTrue(kept.isReadyForShift)
        var replaced = original.replacingTable(try XCTUnwrap(parsedForShift(withMath).tables.first), oldTable: oldRange, edit: edit, replacementLength: 3)
        replaced.prepareForEditing()
        XCTAssertFalse(replaced.isReadyForShift)
    }

    func testPreparedPresentationRejectsMathEmojiImageTables() {
        for cell in ["$x$", ":smile:", "![a](b.png)"] {
            XCTAssertFalse(parsedForShift("| \(cell) | b |\n|---|---|\n| 1 | 2 |\n").isReadyForShift, cell)
        }
        XCTAssertTrue(parsedForShift("| a | b |\n|---|---|\n| 1 | 2 |\n").isReadyForShift)
    }

    func testShiftChainKeepsTableOrder() {
        var text = Self.tableSource as NSString
        var presentation = parsedForShift(text as String)
        var accepted = 0
        for (marker, insert) in [("Intro", "x"), ("Intro", "y"), ("between", "z"), ("quote above", "w"), ("Intro", "v")] {
            let edit = NSRange(location: NSMaxRange(text.range(of: marker)), length: 0)
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: text.length)
            guard presentation.canShift(change) else { continue }
            accepted += 1
            presentation.shift(change)
            text = text.replacingCharacters(in: edit, with: insert) as NSString
            let reparsed = parsedForShift(text as String)
            XCTAssertEqual(presentation.tables, reparsed.tables, marker)
            XCTAssertEqual(presentation.tables.map(\.range.location), presentation.tables.map(\.range.location).sorted(), marker)
        }
        XCTAssertGreaterThanOrEqual(accepted, 4)
    }

    func testTableRowSameContentIgnoresPositionOnly() {
        func row(_ start: Int, text: String = "ab", length: Int = 6, column: Int = 0) -> MarkdownTableRow {
            MarkdownTableRow(range: NSRange(location: start, length: length + 4), cells: [
                MarkdownTableCell(range: NSRange(location: start + 2, length: length), column: column, displayText: text,
                                  displayRuns: [MarkdownTableTextRun(range: NSRange(location: 0, length: 2), kind: .strong)])
            ])
        }
        XCTAssertTrue(row(10).sameContent(as: row(500)))
        XCTAssertFalse(row(10).sameContent(as: row(10, text: "cd")))
        XCTAssertFalse(row(10).sameContent(as: row(10, length: 7)))
        XCTAssertFalse(row(10).sameContent(as: row(10, column: 1)))
    }

    func testRejectedShiftChangesNothing() {
        let source = Self.shiftSource
        let raw = source as NSString
        let bold = raw.range(of: "**bold**"), link = raw.range(of: "[link](https://a.b)")
        let rejected = [
            NSRange(location: 1, length: 0), NSRange(location: bold.location + 1, length: 0), NSRange(location: NSMaxRange(bold), length: 0),
            NSRange(location: link.location + 2, length: 0), NSRange(location: NSMaxRange(link), length: 0), NSRange(location: 8, length: 2)
        ]
        let original = parsedForShift(source)
        for edit in rejected {
            var presentation = original
            let change = MarkdownTextEdit(range: edit, replacementLength: 1, textLength: raw.length)
            XCTAssertFalse(presentation.canShift(change), "\(edit)")
            if presentation.canShift(change) { presentation.shift(change) }
            assertSameLists(presentation, original, "\(edit)")
            XCTAssertEqual(presentation.headings, original.headings, "\(edit)")
            XCTAssertTrue(presentation.isReadyForShift)
        }
    }

    func testTypingInTextKeepsFormattingUntilNewParse() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\nSome **bold** text")
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let edit = NSRange(location: 13, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        fixture.storage.replaceCharacters(in: edit, with: "x")
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        XCTAssertNotNil(fixture.controller.work)
        let kept = try XCTUnwrap(fixture.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(kept.pointSize, fixture.layout.textFont.pointSize)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(fixture.view.string, "# Heading\n\nSoxme **bold** text")
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let installed = try XCTUnwrap(fixture.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(installed.pointSize, fixture.layout.textFont.pointSize)
    }

    /// Блочное изображение слоя не входит в текстовое оформление: быстрый путь его не трогает, а старый стирает вместе с оформлением.
    private func typeWithBlockImage(_ replacement: String, storedText: String? = nil) async throws -> TypingFixture {
        let fixture = try await makeTypingFixture("# Heading\n\nSome **bold** text")
        fixture.layout.setMarkdownBlockImage(NSImage(size: NSSize(width: 4, height: 4)), for: NSRange(location: 20, length: 4))
        let edit = NSRange(location: 13, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: (replacement as NSString).length, replacement: replacement)
        fixture.storage.replaceCharacters(in: edit, with: storedText ?? replacement)
        fixture.controller.edited(revision: fixture.revision)
        return fixture
    }

    func testFastTypingKeepsReadyState() async throws {
        let fixture = try await typeWithBlockImage("x")
        XCTAssertTrue(fixture.layout.containsAtomicBlock(in: NSRange(location: 19, length: 8)))
        XCTAssertNotNil(fixture.controller.work)
    }

    func testFallbackEditClearsReadyState() async throws {
        let fixture = try await typeWithBlockImage("\n")
        XCTAssertFalse(fixture.layout.containsAtomicBlock(in: NSRange(location: 19, length: 8)))
    }

    func testUnconfirmedFastEditClearsReadyState() async throws {
        let fixture = try await typeWithBlockImage("x", storedText: "xx")
        XCTAssertFalse(fixture.layout.containsAtomicBlock(in: NSRange(location: 19, length: 8)))
        XCTAssertFalse(fixture.layout.isMarkdownMarkerHidden(at: 0))
    }

    func testFastTypingCancelsParse() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\nSome **bold** text")
        let edit = NSRange(location: 13, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        XCTAssertNil(fixture.controller.work)
        fixture.storage.replaceCharacters(in: edit, with: "x")
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertNotNil(fixture.controller.work)
    }

    func testLetterTypedInHeadingTakesHeadingStyle() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\nSome **bold** text")
        let edit = NSRange(location: 4, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        fixture.storage.replaceCharacters(in: edit, with: NSAttributedString(string: "x", attributes: [.font: fixture.layout.textFont]))
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let typed = try XCTUnwrap(fixture.storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(typed.pointSize, fixture.layout.textFont.pointSize)
    }

    func testEditInsideLineIndentFallsBack() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\n  - item")
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let edit = NSRange(location: 12, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        fixture.storage.replaceCharacters(in: edit, with: "x")
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertFalse(fixture.layout.isMarkdownMarkerHidden(at: 0))
    }

    func testMultilineOrMarkerEditFallsBack() async throws {
        for (edit, replacement) in [(NSRange(location: 13, length: 0), "\n"), (NSRange(location: 17, length: 0), "x"), (NSRange(location: 13, length: 0), "*")] {
            let fixture = try await makeTypingFixture("# Heading\n\nSome **bold** text")
            XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
            fixture.revision += 1
            fixture.controller.beforeEdit(range: edit, replacementLength: (replacement as NSString).length, replacement: replacement)
            fixture.storage.replaceCharacters(in: edit, with: replacement)
            fixture.controller.edited(revision: fixture.revision)
            XCTAssertFalse(fixture.layout.isMarkdownMarkerHidden(at: 0), replacement)
        }
    }

    func testEnterAtParagraphEndKeepsFormattingOnce() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\nSome text\n\nTail")
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let edit = NSRange(location: 20, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1, replacement: "\n")
        fixture.storage.replaceCharacters(in: edit, with: "\n")
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(fixture.view.string, "# Heading\n\nSome text\n\n\nTail")
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let second = NSRange(location: 21, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: second, replacementLength: 1, replacement: "\n")
        fixture.storage.replaceCharacters(in: second, with: "\n")
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertFalse(fixture.layout.isMarkdownMarkerHidden(at: 0))
    }

    func testHeadingFontReturnsAfterFallbackEdit() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\nSome **bold** text")
        let edit = NSRange(location: 13, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1)
        fixture.storage.replaceCharacters(in: edit, with: "x")
        fixture.controller.edited(revision: fixture.revision)
        let plain = try XCTUnwrap(fixture.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(plain.pointSize, fixture.layout.textFont.pointSize)
        try await Task.sleep(for: .milliseconds(500))
        let restored = try XCTUnwrap(fixture.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(restored.pointSize, fixture.layout.textFont.pointSize)
    }

    func testImageDocumentKeepsFormatting() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\nSome text ![a](missing.png)")
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let edit = NSRange(location: 13, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        fixture.storage.replaceCharacters(in: edit, with: "x")
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
    }

    func testAnchorDocumentUsesFallback() async throws {
        let fixture = try await makeTypingFixture("# Heading\n\nSome text\n\n<a name=\"top\"></a>\n")
        XCTAssertTrue(fixture.layout.isMarkdownMarkerHidden(at: 0))
        let edit = NSRange(location: 13, length: 0)
        fixture.revision += 1
        fixture.controller.beforeEdit(range: edit, replacementLength: 1, replacement: "x")
        fixture.storage.replaceCharacters(in: edit, with: "x")
        fixture.controller.edited(revision: fixture.revision)
        XCTAssertFalse(fixture.layout.isMarkdownMarkerHidden(at: 0))
    }

    private final class TypingFixture {
        let storage: NSTextStorage
        let layout: FoldLayoutManager
        let view: LacTextView
        let controller: MarkdownPresentationController
        let document: EditorDocument
        var revision: UInt = 0
        init(storage: NSTextStorage, layout: FoldLayoutManager, view: LacTextView, controller: MarkdownPresentationController, document: EditorDocument) {
            self.storage = storage
            self.layout = layout
            self.view = view
            self.controller = controller
            self.document = document
        }
    }

    /// Редактор с установленным разбором; курсор в конце текста, поэтому маркер заголовка скрыт.
    private func makeTypingFixture(_ source: String) async throws -> TypingFixture {
        _ = NSApplication.shared
        let storage = NSTextStorage(string: source)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: 500))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), textContainer: container)
        view.font = lacEditorFont(size: 14)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        layout.ensureLayout(for: container)
        let document = EditorDocument(text: source, language: .markdown)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        let fixture = TypingFixture(storage: storage, layout: layout, view: view, controller: controller, document: document)
        controller.update(document: document, enabled: true, isActive: true, revision: 0, currentRevision: { [unowned fixture] in fixture.revision })
        controller.selectionChanged()
        try await Task.sleep(for: .milliseconds(500))
        return fixture
    }

}
