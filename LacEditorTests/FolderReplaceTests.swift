import AppKit
import Foundation
import XCTest
@testable import LacEditor

final class FolderReplaceTests: XCTestCase {
    private func request(_ query: String, _ replacement: String, _ options: TextSearchService.Options = .init(),
                         escapes: Bool = false) -> FolderReplaceService.Request {
        .init(query: query, replacement: replacement, options: options, interpretsEscapes: escapes)
    }

    private func replaced(_ text: String, _ request: FolderReplaceService.Request) throws -> String {
        try XCTUnwrap(FolderReplaceService.apply(FolderReplaceService.edits(in: text, request: request), to: text))
    }

    func testPlainCaseAndEmptyReplacement() throws {
        XCTAssertEqual(try replaced("Cat cat CAT", request("cat", "dog")), "dog dog dog")
        XCTAssertEqual(try replaced("Cat cat CAT", request("cat", "dog", .init(caseSensitive: true))), "Cat dog CAT")
        XCTAssertEqual(try replaced("a-b-c", request("-", "")), "abc")
    }

    func testRegexGroupsEscapesAndEmptyMatches() throws {
        let regex = TextSearchService.Options(usesRegex: true)
        XCTAssertEqual(try replaced("ann@site bob@home", request(#"(\w+)@(\w+)"#, "$2:$1", regex)), "site:ann home:bob")
        XCTAssertEqual(try replaced("price 5", request(#"\d"#, #"\$$0"#, regex)), "price $5")
        XCTAssertEqual(try replaced("a,b", request(",", #"\n"#, regex)), "a\nb")
        XCTAssertEqual(try replaced("a\nb", request("x*", "-", regex)), "a\nb")
        XCTAssertThrowsError(try FolderReplaceService.edits(in: "a", request: request("(", "x", regex))) { error in
            XCTAssertEqual(error as? TextSearchService.SearchError, .invalidPattern)
        }
    }

    func testWholeWord() throws {
        let word = TextSearchService.Options(wholeWord: true)
        XCTAssertEqual(try replaced("cat concat cat.", request("cat", "dog", word)), "dog concat dog.")
        XCTAssertEqual(try replaced("a C++ b", request("C++", "Go", word)), "a Go b")
        XCTAssertEqual(try replaced("x @foo y", request("@foo", "@bar", word)), "x @bar y")
    }

    func testUTF16RangesWithChineseEmojiAndCRLF() throws {
        let text = "你好 😀 needle\r\n👨‍👩‍👧 needle é"
        let edits = try FolderReplaceService.edits(in: text, request: request("needle", "иголка"))
        XCTAssertEqual(edits.count, 2)
        let source = text as NSString
        for edit in edits { XCTAssertEqual(source.substring(with: edit.range), "needle") }
        XCTAssertEqual(try replaced(text, request("needle", "иголка")), "你好 😀 иголка\r\n👨‍👩‍👧 иголка é")
    }

    func testOnlySelectedRangesChangeAndStaleSelectionFails() throws {
        let text = "a a a"
        let all = try FolderReplaceService.edits(in: text, request: request("a", "b"))
        let only = Set([all[1].range])
        let edits = try FolderReplaceService.edits(in: text, request: request("a", "b"), only: only)
        XCTAssertEqual(FolderReplaceService.apply(edits, to: text), "a b a")
        XCTAssertThrowsError(try FolderReplaceService.edits(in: text, request: request("a", "b"), only: [NSRange(location: 1, length: 1)])) {
            XCTAssertTrue($0 is FolderReplaceService.EditError)
        }
    }

    func testApplyRejectsMismatchedOriginal() {
        let edit = FolderReplaceService.Edit(range: NSRange(location: 0, length: 1), original: "x", replacement: "y")
        XCTAssertNil(FolderReplaceService.apply([edit], to: "abc"))
        XCTAssertNil(FolderReplaceService.apply([.init(range: NSRange(location: 2, length: 5), original: "c", replacement: "d")], to: "abc"))
    }

    func testEnclosingKeepsUnselectedTextBetweenEdits() throws {
        let text = "a a a a"
        let all = try FolderReplaceService.edits(in: text, request: request("a", "b"))
        let edits = [all[1], all[3]]
        let enclosing = try XCTUnwrap(FolderReplaceService.enclosing(edits, in: text))
        XCTAssertEqual(enclosing.original, "a a a")
        XCTAssertEqual(enclosing.replacement, "b a b")
        XCTAssertEqual(FolderReplaceService.apply(edits, to: text), "a b a b")
        XCTAssertNil(FolderReplaceService.enclosing(try FolderReplaceService.edits(in: "a", request: request("a", "a")), in: "a"))
    }

    func testMatchesTheSingleDocumentReplaceAll() throws {
        let samples = ["foo Foo FOO", "你好foo😀foo", "x\r\nfoo\nfoo\r\n", "foofoo"]
        for options in [TextSearchService.Options(), .init(caseSensitive: true), .init(usesRegex: true), .init(wholeWord: true)] {
            for text in samples {
                let expected = try TextSearchService.replaceAll(in: text, query: "foo", replacement: "[$0]x", options: options, interpretsEscapes: true)
                let actual = try replaced(text, request("foo", "[$0]x", options, escapes: true))
                XCTAssertEqual(actual, expected.text, "\(options) \(text)")
            }
        }
    }
}

final class FolderReplaceDiskTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private let request = FolderReplaceService.Request(query: "needle", replacement: "иголка", options: .init(), interpretsEscapes: false)

    private func search() throws -> [FolderSearchService.Match] {
        try FolderSearchService.search(root: root, query: "needle", caseSensitive: false, openDocuments: []).values
    }

    private func run(_ matches: [FolderSearchService.Match]) throws -> FolderReplaceService.Outcome {
        let first = try XCTUnwrap(matches.first)
        guard case let .disk(expected) = first.source else { throw XCTSkip("not disk") }
        return try FolderReplaceService.replaceOnDisk(file: first.file, expected: expected, matches: matches, request: request, root: root)
    }

    func testWritesUTF8BytesAndKeepsCRLF() throws {
        let file = root.appendingPathComponent("a.md")
        try "你好 needle\r\n😀 needle".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(search()), .replaced(2))
        XCTAssertEqual(try Data(contentsOf: file), Data("你好 иголка\r\n😀 иголка".utf8))
    }

    func testChangedFileIsSkippedAndNotTouched() throws {
        let file = root.appendingPathComponent("a.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let matches = try search()
        try "needle needle!".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(matches), .skipped(.changed))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle needle!")
    }

    func testSameSizeChangeWithOtherFragmentIsSkipped() throws {
        let file = root.appendingPathComponent("a.md")
        try "needle ab".write(to: file, atomically: true, encoding: .utf8)
        let matches = try search()
        try "xx needle".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(matches), .skipped(.changed))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "xx needle")
    }

    func testBOMFileIsNotGuessed() throws {
        let file = root.appendingPathComponent("bom.md")
        try Data([0xEF, 0xBB, 0xBF] + Array("needle".utf8)).write(to: file)
        let matches = try search()
        XCTAssertFalse(matches.isEmpty)
        let bom = Data([0xEF, 0xBB, 0xBF])
        XCTAssertEqual(try run(matches), .skipped(.notExactUTF8))
        XCTAssertEqual(try Data(contentsOf: file), bom + Data("needle".utf8))
    }

    func testSymbolicLinkIsSkipped() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("a.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let matches = try search()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let linked = FolderSearchService.File(url: link.appendingPathComponent("a.md"), relativePath: "link/a.md")
        guard case let .disk(expected) = try XCTUnwrap(matches.first).source else { return XCTFail() }
        let outcome = try FolderReplaceService.replaceOnDisk(file: linked, expected: expected, matches: matches, request: request, root: root)
        XCTAssertEqual(outcome, .skipped(.symbolicLink))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle")
    }

    func testSearchWithOptions() throws {
        try "Needle needles".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        func count(_ options: TextSearchService.Options?, query: String = "needle") throws -> Int {
            try FolderSearchService.search(root: root, query: query, caseSensitive: false, openDocuments: [], options: options).values.count
        }
        XCTAssertEqual(try count(nil), 2)
        XCTAssertEqual(try count(.init(caseSensitive: true)), 1)
        XCTAssertEqual(try count(.init(wholeWord: true)), 1)
        XCTAssertEqual(try count(.init(usesRegex: true), query: "needles?"), 2)
        XCTAssertThrowsError(try count(.init(usesRegex: true), query: "("))
    }
}

@MainActor
final class FolderReplaceControllerTests: XCTestCase {
    private func makeRoot(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return (root, file)
    }

    private func makeController(confirm: @escaping (FolderSearchController.ReplaceSummary) -> Bool,
                            snapshots: @escaping () -> [FolderSearchService.OpenDocument]? = { [] },
                            applyOpen: @escaping (FolderSearchController.OpenReplace) async -> FolderReplaceService.Outcome = { _ in .replaced(1) })
        -> FolderSearchController {
        FolderSearchController(snapshots: snapshots, open: { _ in nil }, reveal: { _, _ in false }, openFile: { _ in },
                               confirmReplace: confirm, applyOpen: applyOpen)
    }

    func testReplaceIsUnavailableOutsideTextMode() async throws {
        let (root, _) = try makeRoot("needle")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(confirm: { _ in true })
        controller.setRoot(root)
        controller.isReplaceEnabled = true
        controller.mode = .tags
        controller.query = "needle"
        await controller.start()?.value
        XCTAssertFalse(controller.canReplace)
        XCTAssertNil(controller.replaceSelected())
    }

    func testConfirmedReplaceWritesFileAndRestartsSearch() async throws {
        let (root, file) = try makeRoot("needle needle")
        defer { try? FileManager.default.removeItem(at: root) }
        var summary: FolderSearchController.ReplaceSummary?
        let controller = makeController(confirm: { summary = $0; return true })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        controller.isReplaceEnabled = true
        controller.replacement = "x"
        await controller.start()?.value
        let first = try XCTUnwrap(controller.matches.first)
        controller.toggle(first)
        await controller.replaceSelected()?.value
        XCTAssertEqual(summary, FolderSearchController.ReplaceSummary(matchCount: 1, fileCount: 1, openCount: 0))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle x")
        XCTAssertEqual(controller.report?.replacedCount, 1)
        XCTAssertEqual(controller.replaceState, .idle)
    }

    func testDeclinedConfirmationChangesNothing() async throws {
        let (root, file) = try makeRoot("needle")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(confirm: { _ in false })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        controller.isReplaceEnabled = true
        await controller.start()?.value
        await controller.replaceSelected()?.value
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle")
        XCTAssertNil(controller.report)
        XCTAssertEqual(controller.replaceState, .idle)
    }

    func testOpenDocumentGoesThroughApplyOpenAndIsNotWrittenToDisk() async throws {
        let (root, file) = try makeRoot("needle")
        defer { try? FileManager.default.removeItem(at: root) }
        let open = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "needle"))
        var applied = 0
        let controller = makeController(confirm: { _ in true }, snapshots: { [open] }, applyOpen: { _ in applied += 1; return .replaced(1) })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        controller.isReplaceEnabled = true
        await controller.start()?.value
        await controller.replaceSelected()?.value
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle")
    }

    func testChangedQueryOptionsInvalidateSelection() async throws {
        let (root, _) = try makeRoot("Needle needle")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(confirm: { _ in true })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        await controller.start()?.value
        XCTAssertEqual(controller.matches.count, 2)
        controller.caseSensitive = true
        XCTAssertTrue(controller.matches.isEmpty)
        await controller.start()?.value
        XCTAssertEqual(controller.matches.count, 1)
    }

    func testCancelledReplaceKeepsPartialReport() async throws {
        let (root, file) = try makeRoot("needle")
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("b.md")
        try "needle".write(to: other, atomically: true, encoding: .utf8)
        let open = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "needle"))
        var controller: FolderSearchController!
        controller = makeController(confirm: { _ in true }, snapshots: { [open] }, applyOpen: { _ in
            controller.cancelReplace()
            return .replaced(1)
        })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        controller.isReplaceEnabled = true
        controller.replacement = "x"
        await controller.start()?.value
        XCTAssertEqual(controller.matches.count, 2)
        await controller.replaceSelected()?.value
        let report = try XCTUnwrap(controller.report)
        XCTAssertTrue(report.isCancelled)
        XCTAssertEqual(report.replaced.count, 1)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "needle")
        XCTAssertEqual(controller.replaceState, .idle)
    }

    func testInvalidRegexIsReportedWithoutFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(confirm: { _ in true })
        controller.setRoot(root)
        controller.mode = .text
        controller.usesRegex = true
        controller.query = "("
        await controller.start()?.value
        XCTAssertEqual(controller.message, .invalidPattern)
        XCTAssertFalse(controller.isWorking)
    }

    func testEscapesFlagComesFromProvider() async throws {
        let (root, file) = try makeRoot("a,b")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = FolderSearchController(snapshots: { [] }, open: { _ in nil }, reveal: { _, _ in false }, openFile: { _ in },
                                                confirmReplace: { _ in true }, interpretsEscapes: { false })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = ","
        controller.isReplaceEnabled = true
        controller.replacement = #"\n"#
        await controller.start()?.value
        await controller.replaceSelected()?.value
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"a\nb"#)
    }

    func testOpenReplaceOfStaleDocumentIsSkipped() async throws {
        _ = NSApplication.shared
        let suite = "LacEditorTests.FolderReplace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = WindowManager(preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolderReplace-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("stale.md")
        try Data("needle".utf8).write(to: url)
        // Документ с путём: отказ должен идти из-за версии снимка, а не из-за отсутствия файла.
        let document = EditorDocument(text: "needle", url: url, language: .markdown)
        let state = AppState(initialDocument: document, recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowID = UUID()
        manager.preparePrimaryWindow(windowID: windowID, state: state)
        manager.register(windowID: windowID, state: state, window: window)
        defer {
            document.cancelMetricsRefresh()
            manager.unregister(windowID: windowID)
            window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = FolderSearchService.File(url: url, relativePath: "stale.md")
        let source = FolderSearchService.Source.open(documentID: document.id, revision: 99, identity: DocumentFileIdentity.resolve(url))
        let match = FolderSearchService.Match(file: file, range: NSRange(location: 0, length: 6), matchedText: "needle",
                                              contextRange: NSRange(location: 0, length: 6), context: "needle", source: source)
        let plan = FolderSearchController.ReplaceFilePlan(file: file, source: source, matches: [match])
        let request = FolderReplaceService.Request(query: "needle", replacement: "x", options: .init(), interpretsEscapes: true)
        let outcome = await manager.applyFolderReplace(.init(plan: plan, request: request))
        XCTAssertEqual(outcome, .skipped(.changed))
        XCTAssertEqual(document.synchronizedText(), "needle")
    }
}
