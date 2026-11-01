import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class SnippetTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-30 14:05:00 UTC
    private var date: Date { Date(timeIntervalSince1970: 1_793_369_100) }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url.standardizedFileURL
    }

    private func storeURL() throws -> URL {
        try temporaryDirectory().appendingPathComponent("Snippets.json")
    }

    private func render(_ template: String, selection: String = "") -> SnippetService.Rendered {
        SnippetService.render(template, selection: selection, date: date, timeZone: utc)
    }

    // MARK: Подстановки

    func testRenderSubstitutesSelectionDateAndTime() {
        XCTAssertEqual(render("{{date}} {{time}} [{{selection}}]", selection: "中😀").text, "2026-10-30 14:05 [中😀]")
    }

    func testRenderSubstitutesEverySelectionOccurrenceWithoutRescanning() {
        let result = render("{{selection}}|{{selection}}", selection: "{{date}}{{cursor}}")
        XCTAssertEqual(result.text, "{{date}}{{cursor}}|{{date}}{{cursor}}")
        XCTAssertEqual(result.cursorOffset, result.text.utf16.count)
    }

    func testRenderCursorOffsetIsUTF16() {
        let result = render("😀中{{cursor}}x")
        XCTAssertEqual(result.text, "😀中x")
        XCTAssertEqual(result.cursorOffset, 3)
    }

    func testRenderUsesFirstCursorAndDropsOthers() {
        let result = render("a{{cursor}}b{{cursor}}")
        XCTAssertEqual(result.text, "ab")
        XCTAssertEqual(result.cursorOffset, 1)
    }

    func testRenderWithoutCursorPutsCaretAtEnd() {
        let result = render("a😀")
        XCTAssertEqual(result.text, "a😀")
        XCTAssertEqual(result.cursorOffset, 3)
    }

    func testRenderKeepsUnknownAndBrokenTokens() {
        let template = "{{x}} { {{ {{cursor} {{ cursor }} {{Selection}} {{selection}\u{301}}"
        let result = render(template, selection: "S")
        XCTAssertEqual(result.text, template)
        XCTAssertEqual(result.cursorOffset, template.utf16.count)
    }

    func testRenderPreservesCRLFAndEmptyTemplate() {
        XCTAssertEqual(render("a\r\n{{selection}}\r\n", selection: "s").text, "a\r\ns\r\n")
        let empty = render("")
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.cursorOffset, 0)
    }

    func testRenderUsesGivenTimeZone() {
        let late = Date(timeIntervalSince1970: 1_793_403_000) // 2026-10-30 23:30 UTC
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(SnippetService.render("{{date}}", selection: "", date: late, timeZone: utc).text, "2026-10-30")
        XCTAssertEqual(SnippetService.render("{{date}}", selection: "", date: late, timeZone: auckland).text, "2026-10-31")
    }

    // MARK: Поиск в списке

    func testRankedEmptyQueryKeepsStoreOrder() {
        let list = [Snippet(name: "b", text: "1"), Snippet(name: "a", text: "2")]
        XCTAssertEqual(SnippetService.ranked(list, query: "  ").map(\.name), ["b", "a"])
    }

    func testRankedIsCaseInsensitiveAndPrefersExactName() {
        let list = [Snippet(name: "Hello world", text: "1"), Snippet(name: "h-e-l-l-o", text: "2"), Snippet(name: "HELLO", text: "3")]
        XCTAssertEqual(SnippetService.ranked(list, query: "hello").map(\.name), ["HELLO", "Hello world", "h-e-l-l-o"])
    }

    func testRankedReturnsEmptyWhenNothingMatches() {
        XCTAssertTrue(SnippetService.ranked([Snippet(name: "abc", text: "1")], query: "zzz").isEmpty)
    }

    func testSuggestedNameUsesFirstNonEmptyLineAndLimitsTo40Characters() {
        XCTAssertEqual(SnippetService.suggestedName(for: "\n  \n  привет  \nвторая"), "привет")
        XCTAssertEqual(SnippetService.suggestedName(for: String(repeating: "😀", count: 50)), String(repeating: "😀", count: 40))
        XCTAssertEqual(SnippetService.suggestedName(for: " \n\t"), "")
    }

    // MARK: Хранилище

    func testMissingFileGivesEmptyListWithoutIssue() throws {
        let store = SnippetStore(storageURL: try storeURL())
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertNil(store.issue)
        XCTAssertFalse(store.isReadOnly)
    }

    func testAddPersistsAndReloadsInOrder() throws {
        let url = try storeURL()
        let store = SnippetStore(storageURL: url)
        try store.add(name: "первый", text: "{{date}}\n中文😀")
        try store.add(name: "second", text: "x{{cursor}}y")
        let reloaded = SnippetStore(storageURL: url)
        XCTAssertEqual(reloaded.snippets, store.snippets)
        XCTAssertEqual(reloaded.snippets.map(\.name), ["первый", "second"])
        XCTAssertEqual(reloaded.snippets[0].text, "{{date}}\n中文😀")
        XCTAssertNil(reloaded.issue)
    }

    func testFileIsVersionedJSONWrittenAtomically() throws {
        let url = try storeURL()
        let store = SnippetStore(storageURL: url)
        try store.add(name: "a", text: "b")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["snippets"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["Snippets.json"])
    }

    func testAddRejectsEmptyOrWhitespaceNameAndEmptyText() throws {
        let url = try storeURL()
        let store = SnippetStore(storageURL: url)
        XCTAssertThrowsError(try store.add(name: " \n", text: "x")) { XCTAssertEqual($0 as? SnippetStore.StoreError, .emptyName) }
        XCTAssertThrowsError(try store.add(name: "a", text: "")) { XCTAssertEqual($0 as? SnippetStore.StoreError, .emptyText) }
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNameIsTrimmedAndTextIsKept() throws {
        let store = SnippetStore(storageURL: try storeURL())
        let snippet = try store.add(name: "  имя \n", text: "  текст \n")
        XCTAssertEqual(snippet.name, "имя")
        XCTAssertEqual(snippet.text, "  текст \n")
    }

    func testUpdateAndRemove() throws {
        let url = try storeURL()
        let store = SnippetStore(storageURL: url)
        let first = try store.add(name: "a", text: "1")
        let second = try store.add(name: "b", text: "2")
        try store.update(Snippet(id: first.id, name: " c ", text: "3"))
        XCTAssertEqual(store.snippets.map(\.name), ["c", "b"])
        XCTAssertEqual(store.snippets[0].text, "3")
        try store.remove(id: second.id)
        XCTAssertEqual(SnippetStore(storageURL: url).snippets.map(\.name), ["c"])
    }

    func testUpdateMissingIdThrowsNotFound() throws {
        let store = SnippetStore(storageURL: try storeURL())
        XCTAssertThrowsError(try store.update(Snippet(name: "a", text: "b"))) { XCTAssertEqual($0 as? SnippetStore.StoreError, .notFound) }
        XCTAssertThrowsError(try store.remove(id: UUID())) { XCTAssertEqual($0 as? SnippetStore.StoreError, .notFound) }
    }

    func testCorruptFileIsMovedAsideNotOverwritten() throws {
        let url = try storeURL()
        let bytes = Data("{broken".utf8)
        try bytes.write(to: url)
        let store = SnippetStore(storageURL: url)
        let backup = url.deletingLastPathComponent().appendingPathComponent("Snippets.json.corrupt")
        XCTAssertTrue(store.snippets.isEmpty)
        XCTAssertEqual(store.issue, .corrupt(backupName: "Snippets.json.corrupt"))
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try store.add(name: "a", text: "b")
        XCTAssertEqual(SnippetStore(storageURL: url).snippets.count, 1)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }

    func testSecondCorruptionUsesNextBackupName() throws {
        let url = try storeURL()
        let directory = url.deletingLastPathComponent()
        let old = Data("old".utf8)
        try old.write(to: directory.appendingPathComponent("Snippets.json.corrupt"))
        try Data("{new".utf8).write(to: url)
        let store = SnippetStore(storageURL: url)
        XCTAssertEqual(store.issue, .corrupt(backupName: "Snippets.json.corrupt-2"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Snippets.json.corrupt")), old)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Snippets.json.corrupt-2")), Data("{new".utf8))
    }

    func testNewerVersionIsUnavailableAndUntouched() throws {
        let url = try storeURL()
        let bytes = Data(#"{"version":2,"snippets":[]}"#.utf8)
        try bytes.write(to: url)
        let store = SnippetStore(storageURL: url)
        XCTAssertEqual(store.issue, .unavailable)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertThrowsError(try store.add(name: "a", text: "b")) { XCTAssertEqual($0 as? SnippetStore.StoreError, .readOnly) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testUnreadablePathIsUnavailable() throws {
        let url = try storeURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = SnippetStore(storageURL: url)
        XCTAssertEqual(store.issue, .unavailable)
        XCTAssertThrowsError(try store.add(name: "a", text: "b"))
    }

    func testBackupFailureMakesStoreUnavailable() throws {
        try XCTSkipIf(geteuid() == 0, "Права каталога не действуют для root")
        let url = try storeURL()
        let bytes = Data("{broken".utf8)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path)
        let store = SnippetStore(storageURL: url)
        XCTAssertEqual(store.issue, .unavailable)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFailedWriteKeepsMemoryUnchanged() throws {
        try XCTSkipIf(geteuid() == 0, "Права каталога не действуют для root")
        let url = try storeURL()
        let store = SnippetStore(storageURL: url)
        let kept = try store.add(name: "a", text: "b")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path)
        XCTAssertThrowsError(try store.add(name: "c", text: "d"))
        XCTAssertThrowsError(try store.remove(id: kept.id))
        XCTAssertEqual(store.snippets, [kept])
    }

    func testDefaultStorageURLUsesEnvironmentDirectory() {
        let url = SnippetStore.defaultStorageURL()
        XCTAssertEqual(url.lastPathComponent, "Snippets.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, AppEnvironment.dataDirectoryName)
    }

    func testIssueMessagesExistInAllLanguages() throws {
        let corrupt = try storeURL()
        try Data("{".utf8).write(to: corrupt)
        let first = SnippetStore(storageURL: corrupt)
        XCTAssertTrue(first.issueMessage?.contains("Snippets.json.corrupt") == true)
        let newer = try storeURL()
        try Data(#"{"version":9,"snippets":[]}"#.utf8).write(to: newer)
        XCTAssertFalse(SnippetStore(storageURL: newer).issueMessage?.isEmpty ?? true)
        XCTAssertNil(SnippetStore(storageURL: try storeURL()).issueMessage)
    }

    // MARK: Вставка в редактор

    private func makeEditor(_ text: String, language: EditorLanguage = .plainText, formatted: Bool = false)
        -> (EditorDocument, EditorTextView.Coordinator, LacTextView, NSWindow) {
        _ = NSApplication.shared
        let document = EditorDocument(text: text, language: language)
        if formatted { document.isMarkdownFormatted = true }
        let coordinator = EditorTextView.Coordinator(document: document)
        let storage = NSTextStorage(string: coordinator.displayedText(for: document.text), attributes: [.font: lacEditorFont(size: 14)])
        let layout = FoldLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = LacTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.isVerticallyResizable = true
        view.allowsUndo = true
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.textView = view
        coordinator.foldLayoutManager = layout
        view.delegate = coordinator
        coordinator.attachLiveTextProvider()
        coordinator.installObservers(scrollView: scroll)
        coordinator.updateActivity(true)
        window.makeFirstResponder(view)
        return (document, coordinator, view, window)
    }

    private func extract(_ document: EditorDocument) -> EditorTextSelectionSnapshot? {
        let request = EditorTextExtractionRequest(documentID: document.id, allowsTokenAtCaret: false,
            allowsInsertionPoint: true, requiresEditable: true)
        NotificationCenter.default.post(name: EditorCommandNotification.extractTextSelection, object: request)
        return request.result
    }

    private func insert(_ snippet: Snippet, into document: EditorDocument) throws -> EditorRangeReplacementRequest {
        let selection = try XCTUnwrap(extract(document))
        let request = SnippetService.insertionRequest(snippet: snippet, selection: selection, date: date, timeZone: utc)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        return request
    }

    func testInsertionRequestFields() {
        let selection = EditorTextSelectionSnapshot(documentID: UUID(), range: NSRange(location: 2, length: 3), text: "abc",
                                                    editorRevision: 7, wasExplicitSelection: true)
        let request = SnippetService.insertionRequest(snippet: Snippet(name: "n", text: "<{{selection}}>{{cursor}}"),
                                                      selection: selection, date: date, timeZone: utc)
        XCTAssertEqual(request.documentID, selection.documentID)
        XCTAssertEqual(request.range, NSRange(location: 2, length: 3))
        XCTAssertEqual(request.originalText, "abc")
        XCTAssertEqual(request.replacementText, "<abc>")
        XCTAssertEqual(request.expectedEditorRevision, 7)
        XCTAssertEqual(request.actionName, L10n.tr("插入文本片段"))
        XCTAssertTrue(request.groupsUndo)
        XCTAssertEqual(request.space, .source)
        XCTAssertEqual(request.resultingSelection, NSRange(location: 7, length: 0))
    }

    func testInsertionReplacesSelectionSubstitutesItOnceAndPlacesCaret() throws {
        let (document, coordinator, view, window) = makeEditor("a选中b")
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: 1, length: 2))
        let request = try insert(Snippet(name: "n", text: "<{{selection}}>{{cursor}}!"), into: document)
        XCTAssertTrue(request.wasHandled)
        XCTAssertEqual(view.string, "a<选中>!b")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testInsertionAtCaretWithoutSelection() throws {
        let (document, coordinator, view, window) = makeEditor("ab")
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let request = try insert(Snippet(name: "n", text: "[{{selection}}]{{date}}"), into: document)
        XCTAssertTrue(request.wasHandled)
        XCTAssertEqual(view.string, "a[]2026-10-30b")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1 + "[]2026-10-30".utf16.count, length: 0))
    }

    func testInsertionUndoIsOneStepAndRedoRestores() throws {
        let (document, coordinator, view, window) = makeEditor("a选中b")
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: 1, length: 2))
        XCTAssertTrue(try insert(Snippet(name: "n", text: "<{{selection}}>"), into: document).wasHandled)
        XCTAssertEqual(view.string, "a<选中>b")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "a选中b")
        try XCTUnwrap(view.undoManager).redo()
        XCTAssertEqual(view.string, "a<选中>b")
    }

    func testInsertionRefusedInReadingMode() throws {
        let (document, coordinator, view, window) = makeEditor("abc", language: .markdown)
        defer { coordinator.updateActivity(false); window.close() }
        let selection = try XCTUnwrap(extract(document))
        document.setReadingMode(true)
        view.isEditable = false
        XCTAssertNil(extract(document))
        let request = SnippetService.insertionRequest(snippet: Snippet(name: "n", text: "z"), selection: selection, date: date, timeZone: utc)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertFalse(request.wasHandled)
        XCTAssertEqual(request.failureMessage, L10n.tr("阅读模式下无法修改"))
        XCTAssertEqual(view.string, "abc")
    }

    func testInsertionRefusedDuringMarkedText() throws {
        let (document, coordinator, view, window) = makeEditor("abc")
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: 3, length: 0))
        let selection = try XCTUnwrap(extract(document))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertNil(extract(document))
        let request = SnippetService.insertionRequest(snippet: Snippet(name: "n", text: "z"), selection: selection, date: date, timeZone: utc)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertFalse(request.wasHandled)
        XCTAssertEqual(view.string, "abcni")
    }

    func testInsertionRefusedWhenEditorRevisionChanged() throws {
        let (document, coordinator, view, window) = makeEditor("abc")
        defer { coordinator.updateActivity(false); window.close() }
        let fresh = try XCTUnwrap(extract(document))
        let stale = EditorTextSelectionSnapshot(documentID: fresh.documentID, range: fresh.range, text: fresh.text,
                                                editorRevision: fresh.editorRevision + 1, wasExplicitSelection: fresh.wasExplicitSelection)
        let request = SnippetService.insertionRequest(snippet: Snippet(name: "n", text: "z"), selection: stale, date: date, timeZone: utc)
        NotificationCenter.default.post(name: EditorCommandNotification.applyRangeReplacement, object: request)
        XCTAssertFalse(request.wasHandled)
        XCTAssertEqual(view.string, "abc")
    }

    func testInsertionEqualToSelectionIsReportedNotApplied() throws {
        let (document, coordinator, view, window) = makeEditor("axb")
        defer { coordinator.updateActivity(false); window.close() }
        view.setSelectedRange(NSRange(location: 1, length: 1))
        let request = try insert(Snippet(name: "n", text: "{{selection}}"), into: document)
        XCTAssertFalse(request.wasHandled)
        XCTAssertEqual(request.failureMessage, L10n.tr("转换结果与原文相同"))
        XCTAssertEqual(view.string, "axb")
    }

    func testInsertionKeepsDataURIWhenSelectionContainsMediaToken() throws {
        let source = "до ![a](data:image/png;base64,iVBORw0KGgo=) после"
        let (document, coordinator, view, window) = makeEditor(source, language: .markdown, formatted: true)
        defer { coordinator.updateActivity(false); window.close() }
        XCTAssertTrue(view.string.contains("#lac-media-"))
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        let request = try insert(Snippet(name: "n", text: "<{{selection}}>"), into: document)
        XCTAssertTrue(request.wasHandled)
        XCTAssertEqual(document.synchronizedText(), "<" + source + ">")
        XCTAssertFalse(document.synchronizedText().contains("#lac-media-"))
    }

    // MARK: Панель и окно

    func testPickerPresentFilterChooseAndTakePendingOnce() {
        let controller = SnippetPickerController()
        let list = [Snippet(name: "alpha", text: "1"), Snippet(name: "beta", text: "2")]
        controller.present(snippets: list, message: nil)
        XCTAssertTrue(controller.isPresented)
        controller.query = "bet"
        XCTAssertEqual(controller.results.map(\.name), ["beta"])
        controller.choose(list[1])
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.takePending()?.name, "beta")
        XCTAssertNil(controller.takePending())
    }

    func testDismissDropsPending() {
        let controller = SnippetPickerController()
        let snippet = Snippet(name: "a", text: "b")
        controller.present(snippets: [snippet], message: "m")
        controller.choose(snippet)
        controller.dismiss()
        XCTAssertNil(controller.takePending())
        XCTAssertEqual(controller.message, "m")
    }

    func testPresentResetsQuery() {
        let controller = SnippetPickerController()
        controller.present(snippets: [], message: nil)
        controller.query = "abc"
        controller.present(snippets: [Snippet(name: "a", text: "b")], message: nil)
        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.results.count, 1)
    }

    private final class WindowFixture {
        let directory: URL
        let suite: String
        let defaults: UserDefaults
        let manager: WindowManager
        let document: EditorDocument
        let state: AppState

        @MainActor
        init(text: String = "текст\n", language: EditorLanguage = .plainText) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            suite = "LacEditorTests.snippets.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            manager = WindowManager(preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults),
                                    sidebarLibrary: SidebarLibraryStore(storageURL: directory.appendingPathComponent("library.json")))
            document = EditorDocument(text: text, language: language)
            state = manager.openNewWindow(with: document)
        }

        @MainActor
        func dispose() {
            state.closeAuxiliaryWindows()
            state.hostWindow?.delegate = nil
            state.hostWindow?.contentViewController = nil
            state.hostWindow?.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testPickerAndPaletteAndQuickOpenExcludeEachOther() throws {
        let fixture = try WindowFixture()
        defer { fixture.dispose() }
        let state = fixture.state
        let store = SnippetStore(storageURL: try storeURL())
        try store.add(name: "a", text: "b")
        state.showCommandPalette()
        XCTAssertTrue(state.commandPalette.isPresented)
        state.showSnippetPicker(store: store)
        XCTAssertTrue(state.snippetPicker.isPresented)
        XCTAssertFalse(state.commandPalette.isPresented)
        XCTAssertEqual(state.snippetPicker.snippets.count, 1)
        state.showCommandPalette()
        XCTAssertFalse(state.snippetPicker.isPresented)
        XCTAssertTrue(state.commandPalette.isPresented)
        state.showSnippetPicker(store: store)
        state.showQuickOpen()
        XCTAssertFalse(state.snippetPicker.isPresented)
        state.showSnippetPicker(store: store)
        XCTAssertTrue(state.snippetPicker.isPresented)
        state.showSnippetPicker(store: store)
        XCTAssertFalse(state.snippetPicker.isPresented)
    }

    func testPickerRefusedInReadingMode() throws {
        let fixture = try WindowFixture(text: "abc", language: .markdown)
        defer { fixture.dispose() }
        let store = SnippetStore(storageURL: try storeURL())
        fixture.document.setReadingMode(true)
        fixture.state.showSnippetPicker(store: store)
        XCTAssertFalse(fixture.state.snippetPicker.isPresented)
        fixture.document.setReadingMode(false)
        fixture.state.showSnippetPicker(store: store)
        XCTAssertTrue(fixture.state.snippetPicker.isPresented)
    }

    func testCloseAuxiliaryWindowsDismissesPicker() throws {
        let fixture = try WindowFixture()
        defer { fixture.dispose() }
        fixture.state.showSnippetPicker(store: SnippetStore(storageURL: try storeURL()))
        XCTAssertTrue(fixture.state.snippetPicker.isPresented)
        fixture.state.closeAuxiliaryWindows()
        XCTAssertFalse(fixture.state.snippetPicker.isPresented)
    }

    func testSnippetsSectionHasSearchKeysAndKeepsOrder() {
        XCTAssertTrue(SettingsSearch.sections(matching: "文本片段", localize: { $0 }).contains(.snippets))
        XCTAssertEqual(SettingsSection.snippets.rawValue, "文本片段")
        XCTAssertEqual(SettingsSection(rawValue: "文件与恢复"), .files)
        XCTAssertEqual(SettingsSection(rawValue: "文件关联"), .associations)
        let all = SettingsSection.allCases
        XCTAssertEqual(all.firstIndex(of: .snippets), all.firstIndex(of: .files).map { $0 + 1 })
    }

    func testNewSnippetStringsExistInAllCatalogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor")
        let keys = ["文本片段", "保存常用文字，随时插入到光标处。", "插入文本片段…", "将所选内容存为文本片段…", "搜索文本片段",
                    "没有匹配的文本片段", "还没有文本片段。可在设置中添加，或选中文字后使用「将所选内容存为文本片段…」。", "插入文本片段",
                    "存为文本片段", "文本片段名称", "请先选中要保存的文字", "已保存文本片段", "无法保存文本片段", "名称和内容不能为空",
                    "文本片段文件已损坏，已另存为 %@，当前列表为空。", "无法使用文本片段文件，修改将不会保存。", "文本片段列表", "添加文本片段",
                    "编辑文本片段", "内容", "删除此文本片段？", "尚未添加文本片段。",
                    "可用占位符：{{selection}} 所选文字，{{date}} 日期（yyyy-MM-dd），{{time}} 时间（HH:mm），{{cursor}} 插入后的光标位置。"]
        let placeholders = try NSRegularExpression(pattern: "\\{\\{[a-z]+\\}\\}")
        func tokens(_ text: String) -> [String] {
            placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
        }
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count - 1, key.components(separatedBy: "%@").count - 1, "\(language): \(key)")
                XCTAssertEqual(Set(tokens(value)), Set(tokens(key)), "\(language): \(key)")
            }
        }
    }
}
