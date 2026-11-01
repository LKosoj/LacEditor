import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class MarkdownMediaIntegrationTests: XCTestCase {
    private struct Editor {
        let document: EditorDocument
        let coordinator: EditorTextView.Coordinator
        let view: LacTextView
        let scroll: NSScrollView

        var shown: NSString { (view.textStorage?.string ?? "") as NSString }

        /// Правка так же, как делает AppKit: через shouldChangeText, потом замена и didChangeText.
        @discardableResult
        func edit(_ range: NSRange, _ text: String) -> Bool {
            guard view.shouldChangeText(in: range, replacementString: text) else { return false }
            view.textStorage?.replaceCharacters(in: range, with: text)
            view.didChangeText()
            return true
        }
    }

    private let sources = [
        "# Заголовок\r\n![a](data:image/png;base64,iVBORw0KGgo=)\r\nтекст 😀\r\n",
        "<img src=\"data:image/png;base64,AAAA\r\nBBBB\r\nCCCC\">\r\nконец",
    ]

    private func makeEditor(_ source: String, formatted: Bool = true) -> Editor {
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
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.attachLiveTextProvider()
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        coordinator.updateMarkdownPresentation()
        return Editor(document: document, coordinator: coordinator, view: view, scroll: scroll)
    }

    func testOpenShowsTokensAndSaveRestoresBytes() {
        for source in sources {
            let editor = makeEditor(source)
            defer { editor.coordinator.updateActivity(false) }
            XCTAssertTrue(editor.shown.contains("#lac-media-"))
            XCTAssertFalse(editor.shown.contains("BBBB") || editor.shown.contains("iVBOR"))
            // Любая правка заставляет модель взять текст через поставщика.
            XCTAssertTrue(editor.edit(NSRange(location: editor.shown.length, length: 0), "x"))
            let saved = editor.document.synchronizedText()
            XCTAssertEqual(Array(saved.utf16), Array((source + "x").utf16))
            XCTAssertFalse(editor.document.hasUnknownMediaTokens)
        }
    }

    func testSelectionMapsBetweenFileAndScreen() {
        let source = sources[0]
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false) }
        let end = NSRange(location: (source as NSString).length, length: 0)
        XCTAssertEqual(editor.coordinator.displayedRange(for: end), NSRange(location: editor.shown.length, length: 0))
    }

    func testEditCuttingTokenIsRefused() {
        let editor = makeEditor(sources[0])
        defer { editor.coordinator.updateActivity(false) }
        let marker = editor.shown.range(of: "#lac-media-")
        XCTAssertNotEqual(marker.location, NSNotFound)
        let before = editor.shown as String
        XCTAssertFalse(editor.edit(NSRange(location: marker.location + 2, length: 0), "x"))
        XCTAssertEqual(editor.shown as String, before)
    }

    /// Удаление, задевающее токен (Backspace у границы), забирает токен целиком одной правкой; отмена возвращает его.
    func testDeletionTouchingTokenRemovesWholeTokenWithOneUndo() {
        let source = sources[0]
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false) }
        editor.view.allowsUndo = true
        let span = try! XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first)
        let tokenRange = NSRange(location: span.displayStart, length: span.displayLength)
        let before = editor.shown as String
        // Последний символ токена, как при Backspace сразу за ним: правка отклоняется, но токен уже удалён вложенной правкой.
        XCTAssertFalse(editor.edit(NSRange(location: tokenRange.location + tokenRange.length - 1, length: 1), ""))
        XCTAssertEqual(editor.shown as String, (before as NSString).replacingCharacters(in: tokenRange, with: ""))
        XCTAssertEqual(editor.document.synchronizedText(), (source as NSString).replacingOccurrences(of: "data:image/png;base64,iVBORw0KGgo=", with: ""))
        editor.view.undoManager?.undo()
        XCTAssertEqual(editor.shown as String, before)
        XCTAssertEqual(editor.document.synchronizedText(), source)
    }

    func testPasteWithRealDataBecomesTokenAndKnownTokenStays() {
        let editor = makeEditor("начало\n")
        defer { editor.coordinator.updateActivity(false) }
        let entries = editor.document.mediaTable.entries.count
        let pasted = "![p](data:image/png;base64,QUJDREVGRw==)"
        editor.view.editSource = .pasted
        editor.view.insertText(pasted, replacementRange: NSRange(location: 7, length: 0))
        editor.view.editSource = .unknown
        XCTAssertFalse(editor.shown.contains("QUJD"))
        XCTAssertTrue(editor.shown.contains("#lac-media-"))
        XCTAssertEqual(editor.document.mediaTable.entries.count, entries + 1)
        XCTAssertEqual(editor.document.synchronizedText(), "начало\n" + pasted)
        // Токен из таблицы вставляется как есть, второй записи нет.
        let span = try! XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first)
        let token = editor.shown.substring(with: NSRange(location: span.displayStart, length: span.displayLength))
        editor.view.editSource = .pasted
        editor.view.insertText(token, replacementRange: NSRange(location: 0, length: 0))
        editor.view.editSource = .unknown
        XCTAssertEqual(editor.document.mediaTable.entries.count, entries + 1)
        // Выдуманный токен при вставке не блокирует сохранение: он становится обычными данными.
        let fake = "data:image/png;base64,AA==#lac-media-0123456789abcdef"
        editor.view.editSource = .pasted
        editor.view.insertText(" " + fake, replacementRange: NSRange(location: editor.shown.length, length: 0))
        editor.view.editSource = .unknown
        XCTAssertFalse(editor.document.hasUnknownMediaTokens)
        XCTAssertTrue(editor.document.synchronizedText().hasSuffix(" " + fake))
    }

    private func aiReplace(_ editor: Editor, range: NSRange, original: String, with text: String) -> EditorRangeReplacementRequest {
        let extraction = EditorTextExtractionRequest(documentID: editor.document.id, allowsTokenAtCaret: false, allowsWholeDocument: true)
        extraction.space = .display
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: extraction)
        let request = EditorRangeReplacementRequest(documentID: editor.document.id, range: range, originalText: original,
                                                    replacementText: text, expectedEditorRevision: extraction.result?.editorRevision ?? 0, actionName: "t")
        request.space = .display
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        return request
    }

    func testAIReplacementRejectsInventedTokenAndSubstitutesRealData() {
        let editor = makeEditor("abc")
        defer { editor.coordinator.updateActivity(false) }
        let fake = "data:image/png;base64,AA==#lac-media-0123456789abcdef"
        let refused = aiReplace(editor, range: NSRange(location: 0, length: 1), original: "a", with: "![z](\(fake))")
        XCTAssertFalse(refused.wasHandled)
        XCTAssertEqual(refused.failureMessage, L10n.tr("AI 返回的媒体标记无效，已拒绝插入"))
        XCTAssertEqual(editor.shown as String, "abc")
        let real = "![r](data:image/png;base64,QUJDREVGRw==)"
        let accepted = aiReplace(editor, range: NSRange(location: 0, length: 1), original: "a", with: real)
        XCTAssertTrue(accepted.wasHandled)
        XCTAssertFalse(editor.shown.contains("QUJD"))
        XCTAssertEqual(editor.document.synchronizedText(), real + "bc")
        // Токен без изменений сохраняется.
        let span = try! XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first)
        let token = editor.shown.substring(with: NSRange(location: span.displayStart, length: span.displayLength))
        let kept = aiReplace(editor, range: NSRange(location: editor.shown.length - 2, length: 2), original: "bc", with: "x ![k](\(token))")
        XCTAssertTrue(kept.wasHandled)
        XCTAssertEqual(editor.document.synchronizedText(), real + "x " + real.replacingOccurrences(of: "![r]", with: "![k]"))
    }

    func testAIReplacementPartlyCoveringTokenIsRefusedWithoutChanges() {
        let editor = makeEditor(sources[0])
        defer { editor.coordinator.updateActivity(false) }
        let span = try! XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first)
        let before = editor.shown as String
        let part = NSRange(location: span.displayStart + 2, length: 5)
        let request = aiReplace(editor, range: part, original: editor.shown.substring(with: part), with: "x")
        XCTAssertFalse(request.wasHandled)
        XCTAssertEqual(request.failureMessage, L10n.tr("原文位置已变化，请重新执行转换"))
        XCTAssertEqual(editor.shown as String, before)
    }

    func testSanitizerKeepsEditorTokenForModel() {
        let editor = makeEditor(sources[0])
        defer { editor.coordinator.updateActivity(false) }
        let sent = AIRequestMediaSanitizer.sanitize(editor.shown as String)
        XCTAssertTrue(sent.contains("#lac-media-"))
        XCTAssertFalse(sent.contains("[media omitted]"))
        XCTAssertEqual(AIRequestMediaSanitizer.sanitize(sources[0]).contains("[media omitted]"), true)
    }

    func testDeletingWholeTokenAndPuttingItBack() {
        let source = sources[0]
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false) }
        let span = try! XCTUnwrap(editor.document.mediaTable.spans(in: editor.shown).first)
        let tokenRange = NSRange(location: span.displayStart, length: span.displayLength)
        let token = editor.shown.substring(with: tokenRange)
        XCTAssertTrue(editor.edit(tokenRange, ""))
        let withoutImage = (source as NSString).replacingOccurrences(of: "data:image/png;base64,iVBORw0KGgo=", with: "")
        XCTAssertEqual(editor.document.synchronizedText(), withoutImage)
        // Так возвращает токен отмена: вставка текста с токеном должна снова стать картинкой.
        XCTAssertTrue(editor.edit(NSRange(location: tokenRange.location, length: 0), token))
        XCTAssertEqual(editor.document.synchronizedText(), source)
        XCTAssertFalse(editor.edit(NSRange(location: tokenRange.location + 1, length: 0), "x"))
    }

    func testRangeCoveringTokenIsAllowed() {
        let source = sources[0]
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false) }
        XCTAssertTrue(editor.edit(NSRange(location: 0, length: editor.shown.length), "пусто"))
        XCTAssertEqual(editor.document.synchronizedText(), "пусто")
    }

    func testUnknownTokenSetsFlagAndKeepsText() {
        let editor = makeEditor("абв")
        defer { editor.coordinator.updateActivity(false) }
        let fake = "data:image/png;base64,AA==#lac-media-0123456789abcdef"
        XCTAssertTrue(editor.edit(NSRange(location: 3, length: 0), fake))
        XCTAssertEqual(editor.document.synchronizedText(), "абв" + fake)
        XCTAssertTrue(editor.document.hasUnknownMediaTokens)
        XCTAssertTrue(editor.edit(NSRange(location: 3, length: (fake as NSString).length), ""))
        XCTAssertEqual(editor.document.synchronizedText(), "абв")
        XCTAssertFalse(editor.document.hasUnknownMediaTokens)
    }

    /// Смена режима оформления токены не трогает (см. `FoldTaskTests.testSourceModeKeepsMediaTokensAndUndo`); их снимает только смена языка.
    func testLanguageSwitchRestoresFileTextAndTokensReturn() {
        let source = sources[1]
        let editor = makeEditor(source)
        defer { editor.coordinator.updateActivity(false) }
        XCTAssertTrue(editor.shown.contains("#lac-media-"))
        editor.view.allowsUndo = true
        XCTAssertTrue(editor.edit(NSRange(location: editor.shown.length, length: 0), "x"))
        XCTAssertEqual(editor.view.undoManager?.canUndo, true)
        editor.document.language = .plainText
        editor.coordinator.updateMarkdownPresentation()
        XCTAssertEqual(editor.shown as String, source + "x")
        XCTAssertEqual(editor.view.undoManager?.canUndo, false)
        XCTAssertEqual(editor.document.synchronizedText(), source + "x")
        editor.document.language = .markdown
        editor.coordinator.updateMarkdownPresentation()
        XCTAssertTrue(editor.shown.contains("#lac-media-"))
        XCTAssertFalse(editor.shown.contains("BBBB"))
    }

    /// Редактор ячейки таблицы сам себе делегат: токен защищает его собственный код.
    func testTableCellEditorProtectsToken() {
        _ = NSApplication.shared
        var table = MarkdownMediaTable()
        let token = table.incoming("data:image/png;base64,iVBORw0KGgo=").text
        XCTAssertTrue(token.contains("#lac-media-"))
        let cell = MarkdownTableCellEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        cell.delegate = cell
        cell.string = "a" + token + "b"
        cell.mediaMap = { MarkdownMediaMap(spans: table.spans(in: cell.string as NSString)) }
        let length = (token as NSString).length
        XCTAssertFalse(cell.shouldChangeText(in: NSRange(location: 4, length: 0), replacementString: "x"), "набор внутри токена отклоняется")
        XCTAssertEqual(cell.string, "a" + token + "b")
        cell.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(cell.selectedRange().location == 1 || cell.selectedRange().location == 1 + length, "каретка не внутри токена")
        cell.insertText("", replacementRange: NSRange(location: length - 2, length: 3))
        XCTAssertEqual(cell.string, "ab", "удаление с захватом части забирает токен целиком")
    }

    /// Буфер ячейки несёт настоящие данные, вставка возвращает токен.
    func testTableCellEditorWritesAndReadsMediaSource() {
        _ = NSApplication.shared
        var table = MarkdownMediaTable()
        let address = "data:image/png;base64,iVBORw0KGgo="
        let token = table.incoming(address).text
        let cell = MarkdownTableCellEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        cell.string = "a" + token + "b"
        let payload = MediaClipboardPayload(plain: "ab", source: "a" + address + "b", displayRange: NSRange(location: 0, length: (cell.string as NSString).length))
        cell.mediaClipboard = { _ in payload }
        cell.setSelectedRange(payload.displayRange)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(cell.writeSelection(to: board, types: [.string]))
        XCTAssertEqual(board.string(forType: .string), "ab")
        XCTAssertEqual(board.string(forType: LacTextView.mediaSourceType), "a" + address + "b")

        XCTAssertTrue(cell.readablePasteboardTypes.contains(LacTextView.mediaSourceType))
        XCTAssertEqual(cell.preferredPasteboardType(from: [.string, LacTextView.mediaSourceType], restrictedToTypesFrom: nil), LacTextView.mediaSourceType)
        var pasted: String?
        cell.mediaPaste = { pasted = $0.string(forType: LacTextView.mediaSourceType); return true }
        XCTAssertTrue(cell.readSelection(from: board, type: LacTextView.mediaSourceType))
        XCTAssertEqual(pasted, "a" + address + "b")
    }

    func testBase64WithLineBreaksDecodesWithIgnoredCharacters() {
        let value = "iVBORw0K\r\nGgo="
        XCTAssertNil(Data(base64Encoded: value))
        XCTAssertEqual(Data(base64Encoded: value, options: .ignoreUnknownCharacters), Data(base64Encoded: "iVBORw0KGgo="))
    }

    /// Оглавление документа хранит координаты файла, хотя разбор идёт по тексту с токеном.
    func testOutlineHeadingsUseFileCoordinates() async throws {
        _ = NSApplication.shared
        let source = "![a](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==)\n\n# Title\n\n[go](#title)\n"
        let document = EditorDocument(text: source, language: .markdown)
        let projection = document.mediaTable.project(source)
        XCTAssertNotEqual(projection.text, source)
        let map = MarkdownMediaMap(spans: projection.spans)
        let storage = NSTextStorage(string: projection.text)
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 300))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
        let controller = MarkdownPresentationController(textView: view, layout: layout)
        controller.sourceMap = { map }
        controller.update(document: document, enabled: false, outlineVisible: true, isActive: true, revision: 0, currentRevision: { 0 })
        let deadline = Date().addingTimeInterval(2)
        while !document.isMarkdownOutlineCurrent && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let heading = try XCTUnwrap(document.markdownHeadings.first)
        XCTAssertEqual(heading.range.location, (source as NSString).range(of: "# Title").location)
        XCTAssertEqual((source as NSString).substring(with: heading.range), "# Title")
    }
}
