import AppKit
import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class OpenDocumentsSearchTests: XCTestCase {
    private typealias Service = OpenDocumentsSearchService

    private func source(_ title: String, _ text: String, id: UUID = UUID(), revision: UInt = 1,
                        skip: Service.SkipReason? = nil) -> Service.Source {
        let snapshot = skip == nil ? DocumentTextSnapshot(documentID: id, revision: revision, text: text) : nil
        return .init(documentID: id, title: title, snapshot: snapshot, skip: skip)
    }

    private func search(_ sources: [Service.Source], _ query: String, _ options: TextSearchService.Options = .init()) throws -> Service.Result {
        try Service.search(sources: sources, query: query, options: options)
    }

    // MARK: Группа A. Чистый поиск

    func testCountsMatchesAndDocumentsInSourceOrder() throws {
        let sources = [source("a", "cat cat"), source("b", "dog"), source("c", "Cat")]
        let result = try search(sources, "cat")
        XCTAssertEqual(result.documents.map(\.title), ["a", "c"])
        XCTAssertEqual(result.documents.map(\.documentID), [sources[0].documentID, sources[2].documentID])
        XCTAssertEqual(result.matchCount, 3)
        XCTAssertEqual(result.order, sources.map(\.documentID))
    }

    func testUnsavedDocumentParticipatesWithoutURL() throws {
        let unsaved = source("未命名", "needle")
        let result = try search([unsaved], "needle")
        XCTAssertEqual(result.documents.first?.ranges, [NSRange(location: 0, length: 6)])
        XCTAssertEqual(result.documents.first?.documentID, unsaved.documentID)
    }

    func testSkippedSourcesAreReportedAndNotSearched() throws {
        let sources = [source("open", "", skip: .opening), source("big", "", skip: .largeFile), source("ok", "needle")]
        let result = try search(sources, "needle")
        XCTAssertEqual(result.skipped.map(\.reason), [.opening, .largeFile])
        XCTAssertEqual(result.order, [sources[2].documentID])
        XCTAssertNil(sources[0].snapshot)
        XCTAssertEqual(result.matchCount, 1)
    }

    func testInvalidRegexThrowsInvalidPattern() {
        XCTAssertThrowsError(try search([source("a", "x")], "(", .init(usesRegex: true))) { error in
            XCTAssertEqual(error as? TextSearchService.SearchError, .invalidPattern)
        }
        // Даже без документов ошибка в выражении не теряется.
        XCTAssertThrowsError(try search([], "(", .init(usesRegex: true)))
    }

    func testCancellationThrows() {
        XCTAssertThrowsError(try Service.search(sources: [source("a", "cat")], query: "cat", options: .init(), isCancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSkipsDataAddressesInsideDocument() throws {
        let text = "![a](data:image/png;base64,Y2F0Y2F0) Y2F0"
        let result = try search([source("a", text)], "Y2F0")
        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.documents.first?.ranges.first?.location, (text as NSString).range(of: " Y2F0").location + 1)
    }

    func testRangesStayUTF16AfterEmojiAndChinese() throws {
        let text = "😀 中文 cat"
        let result = try search([source("a", text)], "cat")
        XCTAssertEqual(result.documents.first?.ranges, [(text as NSString).range(of: "cat")])
        XCTAssertEqual(result.documents.first?.ranges.first?.location, 6)
    }

    func testWholeWordAndRegexOptionsApply() throws {
        let sources = [source("a", "cat concat cat.")]
        XCTAssertEqual(try search(sources, "cat", .init(wholeWord: true)).matchCount, 2)
        XCTAssertEqual(try search(sources, "c.t", .init(usesRegex: true)).matchCount, 3)
        XCTAssertEqual(try search(sources, "CAT", .init(caseSensitive: true)).matchCount, 0)
    }

    // MARK: Группа B. Переходы

    private struct Fixture {
        let sources: [Service.Source]
        let result: Service.Result
        func position(_ index: Int, _ location: Int, length: Int = 3) -> Service.Position {
            .init(documentID: sources[index].documentID, range: NSRange(location: location, length: length))
        }
    }

    private func fixture(_ texts: [String], query: String = "cat") throws -> Fixture {
        let sources = texts.enumerated().map { source("d\($0.offset)", $0.element) }
        return Fixture(sources: sources, result: try search(sources, query))
    }

    func testStepForwardWithinDocumentThenNextDocument() throws {
        let f = try fixture(["cat cat", "xx cat"])
        XCTAssertEqual(Service.step(in: f.result, from: f.position(0, 0), backwards: false), f.position(0, 4))
        XCTAssertEqual(Service.step(in: f.result, from: f.position(0, 4), backwards: false), f.position(1, 3))
    }

    func testStepForwardFromLastMatchWrapsToFirstDocument() throws {
        let f = try fixture(["cat", "xx cat"])
        XCTAssertEqual(Service.step(in: f.result, from: f.position(1, 3), backwards: false), f.position(0, 0))
    }

    func testStepBackwardsFromFirstMatchWrapsToLastDocument() throws {
        let f = try fixture(["cat", "cat xx cat"])
        XCTAssertEqual(Service.step(in: f.result, from: f.position(0, 0), backwards: true), f.position(1, 7))
        XCTAssertEqual(Service.step(in: f.result, from: f.position(1, 7), backwards: true), f.position(1, 0))
        XCTAssertEqual(Service.step(in: f.result, from: f.position(1, 0), backwards: true), f.position(0, 0))
    }

    func testStepFromDocumentWithoutMatchesFollowsOrder() throws {
        let f = try fixture(["cat", "none", "xx cat"])
        XCTAssertEqual(Service.step(in: f.result, from: f.position(1, 0, length: 0), backwards: false), f.position(2, 3))
        XCTAssertEqual(Service.step(in: f.result, from: f.position(1, 0, length: 0), backwards: true), f.position(0, 0))
    }

    func testStepFromClosedDocumentStartsAtBeginningOrEnd() throws {
        let f = try fixture(["cat", "xx cat"])
        let closed = Service.Position(documentID: UUID(), range: NSRange(location: 5, length: 0))
        XCTAssertEqual(Service.step(in: f.result, from: closed, backwards: false), f.position(0, 0))
        XCTAssertEqual(Service.step(in: f.result, from: closed, backwards: true), f.position(1, 3))
    }

    func testStepInSingleDocumentWrapsToItself() throws {
        let f = try fixture(["cat xx cat"])
        XCTAssertEqual(Service.step(in: f.result, from: f.position(0, 7), backwards: false), f.position(0, 0))
        XCTAssertEqual(Service.step(in: f.result, from: f.position(0, 0), backwards: true), f.position(0, 7))
        let one = try fixture(["cat"])
        XCTAssertEqual(Service.step(in: one.result, from: one.position(0, 0), backwards: false), one.position(0, 0))
        XCTAssertEqual(Service.step(in: one.result, from: one.position(0, 0), backwards: true), one.position(0, 0))
    }

    func testStepWithoutMatchesReturnsNil() throws {
        let f = try fixture(["a", "b"])
        XCTAssertNil(Service.step(in: f.result, from: f.position(0, 0, length: 0), backwards: false))
        XCTAssertNil(Service.step(in: f.result, from: f.position(0, 0, length: 0), backwards: true))
        let empty = try search([], "cat")
        XCTAssertNil(Service.step(in: empty, from: .init(documentID: UUID(), range: NSRange(location: 0, length: 0)), backwards: false))
    }

    func testStepSkipsDocumentsWithoutMatches() throws {
        let f = try fixture(["cat", "-", "-", "-", "cat"])
        XCTAssertEqual(Service.step(in: f.result, from: f.position(0, 0), backwards: false), f.position(4, 0))
        XCTAssertEqual(Service.step(in: f.result, from: f.position(4, 0), backwards: true), f.position(0, 0))
    }

    // MARK: Извлечение

    func testExtractPrefixesTitleAndLineAndReportsSkipped() throws {
        let sources = [source("a.md", "x\ncat\ny"), source("big", "", skip: .largeFile), source("b", "cat")]
        let request = MatchExtractionService.Request(query: "cat", options: .init(), interpretsEscapes: true, replacement: "", mode: .line)
        let extraction = try Service.extract(sources: sources, request: request)
        XCTAssertEqual(extraction.records.map(\.text), ["a.md:2: cat", "b:1: cat"])
        XCTAssertEqual(extraction.skipped.map(\.title), ["big"])
    }

    // MARK: Группа C. Контроллер на замыканиях

    private final class Recorder {
        var replaceCalls: [(UUID, UInt)] = []
        var confirmations: [OpenDocumentsSearchController.ReplaceSummary] = []
        var outcomes: [FolderReplaceService.Outcome] = []
        var onReplace: (() -> Void)?
    }

    private func controller(_ sources: [Service.Source], confirm: Bool = true, recorder: Recorder) -> OpenDocumentsSearchController {
        OpenDocumentsSearchController(
            sources: { _ in sources },
            reveal: { _, _, _ in true },
            replace: { id, revision, _ in
                recorder.replaceCalls.append((id, revision))
                recorder.onReplace?()
                return recorder.outcomes.isEmpty ? .replaced(1) : recorder.outcomes.removeFirst()
            },
            confirmReplace: { summary in
                recorder.confirmations.append(summary)
                return confirm
            })
    }

    private func replaceRequest(_ query: String = "cat") -> FolderReplaceService.Request {
        .init(query: query, replacement: "dog", options: .init(), interpretsEscapes: true)
    }

    func testReplaceAllCancelledAtConfirmationDoesNotTouchDocuments() async throws {
        let recorder = Recorder()
        let sut = controller([source("a", "cat")], confirm: false, recorder: recorder)
        let report = try await sut.replaceAll(request: replaceRequest())
        XCTAssertNil(report)
        XCTAssertTrue(recorder.replaceCalls.isEmpty)
        XCTAssertEqual(recorder.confirmations.count, 1)
    }

    func testConfirmationReceivesMatchAndDocumentCounts() async throws {
        let recorder = Recorder()
        let sources = [source("a", "cat cat"), source("b", "dog"), source("c", "cat"), source("read", "cat cat cat", skip: .readingMode)]
        let sut = controller(sources, recorder: recorder)
        let report = try await sut.replaceAll(request: replaceRequest())
        XCTAssertEqual(recorder.confirmations, [.init(matchCount: 3, documentCount: 2)])
        XCTAssertEqual(report?.skipped.map(\.reason), [.readingMode])
    }

    func testReplaceAllWithoutMatchesDoesNotAsk() async throws {
        let recorder = Recorder()
        let sut = controller([source("a", "dog")], recorder: recorder)
        let report = try await sut.replaceAll(request: replaceRequest())
        XCTAssertEqual(report, .init(replaced: [], skipped: []))
        XCTAssertTrue(recorder.confirmations.isEmpty)
    }

    func testReplaceAllWithoutMatchesKeepsSkippedDocuments() async throws {
        let recorder = Recorder()
        let sut = controller([source("a", "dog"), source("big", "cat", skip: .largeFile)], recorder: recorder)
        let report = try await sut.replaceAll(request: replaceRequest())
        XCTAssertEqual(report?.skipped.map(\.title), ["big"])
        XCTAssertEqual(report?.skipped.map(\.reason), [.largeFile])
        XCTAssertTrue(recorder.confirmations.isEmpty)
    }

    func testReplaceAllReportsMixedOutcomes() async throws {
        let recorder = Recorder()
        recorder.outcomes = [.replaced(2), .skipped(.changed), .skipped(.openDocumentBusy), .skipped(.openInEditorFailed)]
        let sources = [source("a", "cat cat"), source("b", "cat"), source("c", "cat"), source("d", "cat")]
        let outcome = try await controller(sources, recorder: recorder).replaceAll(request: replaceRequest())
        let report = try XCTUnwrap(outcome)
        XCTAssertEqual(report.replaced, [.init(title: "a", count: 2)])
        XCTAssertEqual(report.replacedCount, 2)
        XCTAssertEqual(report.skipped.map(\.title), ["b", "c", "d"])
        XCTAssertEqual(report.skipped.map(\.reason), [.changed, .busy, .busy])
    }

    func testReplaceAllStopsAfterCancellation() async throws {
        let recorder = Recorder()
        let sources = [source("a", "cat"), source("b", "cat"), source("c", "cat")]
        let sut = controller(sources, recorder: recorder)
        var holder: Task<OpenDocumentsSearchController.ReplaceReport?, Error>?
        recorder.onReplace = { holder?.cancel() }
        let task = Task { try await sut.replaceAll(request: replaceRequest()) }
        holder = task
        let report = try await task.value
        XCTAssertEqual(recorder.replaceCalls.count, 1)
        XCTAssertEqual(report?.replaced.map(\.title), ["a"])
    }

    func testReplaceUsesRevisionFromCountedSnapshot() async throws {
        let recorder = Recorder()
        let sources = [source("a", "cat", revision: 7), source("b", "cat", revision: 42)]
        _ = try await controller(sources, recorder: recorder).replaceAll(request: replaceRequest())
        XCTAssertEqual(recorder.replaceCalls.map(\.0), sources.map(\.documentID))
        XCTAssertEqual(recorder.replaceCalls.map(\.1), [7, 42])
    }

    func testStepReturnsRevisionOfTargetDocument() async throws {
        let recorder = Recorder()
        let sources = [source("a", "xx", revision: 3), source("b", "cat", revision: 9)]
        let sut = controller(sources, recorder: recorder)
        let from = Service.Position(documentID: sources[0].documentID, range: NSRange(location: 0, length: 0))
        let outcome = try await sut.step(from: from, backwards: false, query: "cat", options: .init())
        XCTAssertEqual(outcome.target?.documentID, sources[1].documentID)
        XCTAssertEqual(outcome.revision, 9)
        XCTAssertEqual(outcome.result.matchCount, 1)
    }

    // MARK: Группа D. Менеджер окон

    private struct Windows {
        let manager: WindowManager
        let defaults: UserDefaults
        let suite: String
    }

    private func makeManager() throws -> Windows {
        _ = NSApplication.shared
        let suite = "LacEditorTests.OpenDocuments.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return Windows(manager: WindowManager(preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults)),
                       defaults: defaults, suite: suite)
    }

    /// Состояние с окном, зарегистрированное в менеджере; `cleanup` вызывать в defer.
    private func register(_ document: EditorDocument, in windows: Windows) -> (state: AppState, cleanup: () -> Void) {
        let state = AppState(initialDocument: document, recentFiles: windows.manager.recentFiles, preferences: windows.manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowID = UUID()
        windows.manager.preparePrimaryWindow(windowID: windowID, state: state)
        windows.manager.register(windowID: windowID, state: state, window: window)
        return (state, {
            document.cancelMetricsRefresh()
            windows.manager.unregister(windowID: windowID)
            window.close()
        })
    }

    func testSourcesIncludeUnsavedDocumentWithoutReadingDisk() throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let document = EditorDocument(text: "needle", language: .plainText)
        let (_, cleanup) = register(document, in: windows)
        defer { cleanup() }
        XCTAssertNil(document.url)
        let sources = windows.manager.openDocumentSearchSources(forReplace: false)
        let found = try XCTUnwrap(sources.first { $0.documentID == document.id })
        XCTAssertNil(found.skip)
        XCTAssertEqual(found.snapshot?.text, "needle")
        XCTAssertEqual(found.title, document.displayName)
    }

    func testSourcesSkipOpeningPlaceholder() throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let document = EditorDocument(text: "needle", language: .plainText)
        let (_, cleanup) = register(document, in: windows)
        defer { cleanup() }
        document.ioState = .opening
        let found = try XCTUnwrap(windows.manager.openDocumentSearchSources(forReplace: false).first { $0.documentID == document.id })
        XCTAssertEqual(found.skip, .opening)
        XCTAssertNil(found.snapshot)
    }

    func testSourcesSkipLargeFileProfile() throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let document = EditorDocument(text: "needle", language: .plainText, performanceProfile: .large)
        let (_, cleanup) = register(document, in: windows)
        defer { cleanup() }
        let found = try XCTUnwrap(windows.manager.openDocumentSearchSources(forReplace: false).first { $0.documentID == document.id })
        XCTAssertEqual(found.skip, .largeFile)
        XCTAssertNil(found.snapshot)
    }

    func testSourcesForReplaceSkipReadingMode() throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let document = EditorDocument(text: "needle", language: .plainText)
        let (_, cleanup) = register(document, in: windows)
        defer { cleanup() }
        document.setReadingMode(true)
        let forReplace = try XCTUnwrap(windows.manager.openDocumentSearchSources(forReplace: true).first { $0.documentID == document.id })
        XCTAssertEqual(forReplace.skip, .readingMode)
        XCTAssertNil(forReplace.snapshot)
        let forSearch = try XCTUnwrap(windows.manager.openDocumentSearchSources(forReplace: false).first { $0.documentID == document.id })
        XCTAssertNil(forSearch.skip)
        XCTAssertNotNil(forSearch.snapshot)
    }

    func testSourcesStartWithActiveWindowGroup() throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let first = EditorDocument(text: "one", language: .plainText)
        let second = EditorDocument(text: "two", language: .plainText)
        let firstState = windows.manager.openNewWindow(with: first)
        let secondState = windows.manager.openNewWindow(with: second)
        defer {
            for state in [firstState, secondState] {
                state.closeAuxiliaryWindows()
                state.hostWindow?.delegate = nil
                state.hostWindow?.contentViewController = nil
                state.hostWindow?.close()
            }
        }
        let sources = windows.manager.openDocumentSearchSources(forReplace: false)
        // Полнота набора проверяется всегда; порядок — только если у менеджера есть активное окно.
        XCTAssertEqual(Set(sources.map(\.documentID)), [first.id, second.id])
        if let active = windows.manager.activeState, let head = sources.first {
            XCTAssertTrue(active.documents.contains { $0.id == head.documentID })
        }
    }

    func testReplaceOfChangedDocumentIsSkipped() async throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let document = EditorDocument(text: "needle", language: .plainText)
        let (_, cleanup) = register(document, in: windows)
        defer { cleanup() }
        let request = FolderReplaceService.Request(query: "needle", replacement: "x", options: .init(), interpretsEscapes: true)
        let outcome = await windows.manager.applyOpenDocumentsReplace(documentID: document.id, revision: 99, request: request)
        XCTAssertEqual(outcome, .skipped(.changed))
        XCTAssertEqual(document.synchronizedText(), "needle")
        let closed = await windows.manager.applyOpenDocumentsReplace(documentID: UUID(), revision: 1, request: request)
        XCTAssertEqual(closed, .skipped(.changed))
    }

    func testReplaceOfReadingModeDocumentIsSkipped() async throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let document = EditorDocument(text: "needle", language: .plainText)
        let (_, cleanup) = register(document, in: windows)
        defer { cleanup() }
        let revision = document.synchronizedSnapshot().revision
        document.setReadingMode(true)
        let request = FolderReplaceService.Request(query: "needle", replacement: "x", options: .init(), interpretsEscapes: true)
        let outcome = await windows.manager.applyOpenDocumentsReplace(documentID: document.id, revision: revision, request: request)
        XCTAssertEqual(outcome, .skipped(.openDocumentBusy))
        XCTAssertEqual(document.synchronizedText(), "needle")
    }

    func testReplaceOfUnsavedDocumentDoesNotFailOnMissingURL() async throws {
        let windows = try makeManager()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let document = EditorDocument(text: "needle", language: .plainText)
        let (_, cleanup) = register(document, in: windows)
        defer { cleanup() }
        XCTAssertNil(document.url)
        XCTAssertNil(document.fileIdentity)
        let revision = document.synchronizedSnapshot().revision
        let request = FolderReplaceService.Request(query: "needle", replacement: "x", options: .init(), interpretsEscapes: true)
        let outcome = await windows.manager.applyOpenDocumentsReplace(documentID: document.id, revision: revision, request: request)
        // Живого редактора в тесте нет: допустим отказ редактора, но не «документ изменён» из-за отсутствия адреса.
        XCTAssertNotEqual(outcome, .skipped(.changed))
        XCTAssertNotEqual(outcome, .skipped(.openDocumentBusy))
    }

    // MARK: Группа E. Состояние панели

    private func makeState(_ text: String = "cat") throws -> (AppState, EditorDocument) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LacEditorOpenDocuments.\(UUID())"))
        let document = EditorDocument(text: text, language: .plainText)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        return (state, document)
    }

    func testDismissResetsScopeToDocument() throws {
        let (state, _) = try makeState()
        state.presentFindReplace(mode: .find)
        state.setFindScope(.openDocuments)
        XCTAssertEqual(state.findReplace.area, .openDocuments)
        state.dismissFindReplace()
        XCTAssertFalse(state.findReplace.searchesOpenDocuments)
        XCTAssertEqual(state.findReplace.area, .document)
    }

    func testAdoptCopiesQueryOptionsAndShowsBar() throws {
        let (state, _) = try makeState()
        let other = FindReplaceState()
        other.query = "needle"
        other.replacement = "x"
        other.isCaseSensitive = true
        other.usesRegex = true
        other.matchesWholeWord = true
        other.interpretsEscapes = false
        other.mode = .replace
        state.adoptOpenDocumentsSearch(from: other)
        let target = state.findReplace
        XCTAssertEqual(target.query, "needle")
        XCTAssertEqual(target.replacement, "x")
        XCTAssertTrue(target.isCaseSensitive)
        XCTAssertTrue(target.usesRegex)
        XCTAssertTrue(target.matchesWholeWord)
        XCTAssertFalse(target.interpretsEscapes)
        XCTAssertEqual(target.mode, .replace)
        XCTAssertEqual(target.area, .openDocuments)
        XCTAssertTrue(target.isBarVisible)
        state.dismissFindReplace()
    }

    func testScopeChangeClearsSummary() throws {
        let (state, _) = try makeState()
        state.presentFindReplace(mode: .find)
        state.setFindScope(.openDocuments)
        state.findReplace.setOpenDocumentsSummary(.init(matchCount: 2, documentCount: 1, skippedTitles: []))
        state.setFindScope(.document)
        XCTAssertNil(state.findReplace.openDocumentsSummary)
        XCTAssertEqual(state.findReplace.area, .document)
        state.dismissFindReplace()
    }

    // MARK: Тексты

    func testOpenDocumentsTextsExistInAllCatalogs() throws {
        let keys = ["查找范围", "当前文档", "在选区内", "全部打开的文档", "共 %@ 个匹配，%@ 个文档", "共 %@ 个匹配，%@ 个文档，跳过 %@ 个",
                    "已跳过：%@", "%@（%@）", "文档已变化", "大文件", "确认在所有打开的文档中替换？",
                    "文档：%d 个，替换：%d 处。每个文档作为一次编辑进行，可分别撤销，不会写入磁盘。",
                    "已替换 %@ 处（%@ 个文档）", "已替换 %@ 处（%@ 个文档），跳过 %@ 个：%@", "在所有打开的文档中替换"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                for token in ["%@", "%d"] {
                    XCTAssertEqual(value.components(separatedBy: token).count, key.components(separatedBy: token).count, "\(language): \(key)")
                }
            }
        }
    }
}
