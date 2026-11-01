import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class FolderSearchControllerTests: XCTestCase {
    func testUnavailableSnapshotsRejectSearchInsteadOfSkippingDocuments() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = FolderSearchController(snapshots: { nil }, open: { _ in nil }, reveal: { _, _ in false }, openFile: { _ in })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        XCTAssertNil(controller.start())
        XCTAssertEqual(controller.message, .stale)
        XCTAssertFalse(controller.hasSearched)
    }

    func testUnavailableSnapshotsRejectSelection() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let openDocument = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "needle"))
        var available = true
        var revealed = false
        let controller = FolderSearchController(snapshots: { available ? [openDocument] : nil }, open: { _ in nil },
            reveal: { _, _ in revealed = true; return true }, openFile: { _ in })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        await controller.start()?.value
        let match = try XCTUnwrap(controller.matches.first)
        available = false
        await controller.select(match)?.value
        XCTAssertFalse(revealed)
        XCTAssertEqual(controller.message, .stale)
    }

    func testSubmitWithoutMatchesKeepsQuickOpenRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var opened: URL?
        let controller = FolderSearchController(snapshots: { nil }, open: { _ in nil },
            reveal: { _, _ in false }, openFile: { opened = $0 })
        controller.setRoot(root)
        controller.requestQuickOpen()
        controller.query = "нет-такого"
        await controller.submit()?.value
        XCTAssertNil(opened)
        XCTAssertTrue(controller.hasSearched)
        XCTAssertNotNil(controller.quickOpenRequest)
    }

    func testCancelQuickOpenClearsRequestAndResultsButKeepsRoot() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xff]).write(to: root.appendingPathComponent("ReleaseNotes.md"))
        let controller = FolderSearchController(snapshots: { nil }, open: { _ in nil },
            reveal: { _, _ in false }, openFile: { _ in })
        controller.cancelQuickOpen()
        XCTAssertNil(controller.quickOpenRequest)
        controller.setRoot(root)
        controller.requestQuickOpen()
        controller.query = "rlnt"
        await controller.start()?.value
        XCTAssertFalse(controller.quickOpenItems.isEmpty)
        controller.cancelQuickOpen()
        XCTAssertNil(controller.quickOpenRequest)
        XCTAssertTrue(controller.quickOpenItems.isEmpty)
        XCTAssertEqual(controller.root?.path, root.standardizedFileURL.path)
    }

    func testQuickOpenUsesFileSearchWithoutReadingLiveSnapshots() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ReleaseNotes.md")
        try Data([0xff]).write(to: file)
        var snapshotCalls = 0
        var opened: URL?
        let controller = FolderSearchController(snapshots: { snapshotCalls += 1; return nil },
            open: { _ in nil }, reveal: { _, _ in false }, openFile: { opened = $0 })
        controller.requestQuickOpen()
        XCTAssertNil(controller.quickOpenRequest)
        controller.setRoot(root)
        controller.mode = .tags
        controller.query = "rlnt"
        controller.requestQuickOpen()
        let firstRequest = try XCTUnwrap(controller.quickOpenRequest)
        XCTAssertEqual(controller.mode, .files)
        await controller.start()?.value
        XCTAssertEqual(snapshotCalls, 0)
        let result = try XCTUnwrap(controller.files.first)
        controller.select(result)
        XCTAssertEqual(opened, file)
        XCTAssertNil(controller.quickOpenRequest)
        controller.requestQuickOpen()
        XCTAssertNotEqual(firstRequest, controller.quickOpenRequest)
        controller.mode = .text
        XCTAssertNil(controller.quickOpenRequest)
        controller.requestQuickOpen()
        controller.query = "missing"
        opened = nil
        controller.select(result)
        XCTAssertNil(opened)
        controller.setRoot(nil)
        XCTAssertNil(controller.quickOpenRequest)
        XCTAssertTrue(controller.files.isEmpty)
    }

    func testImmediateQuickSubmitOpensAfterSearchAndChangedQueryCancelsOpening() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ReleaseNotes.md")
        try Data([0xff]).write(to: file)
        var opened: URL?
        let controller = FolderSearchController(snapshots: { nil }, open: { _ in nil },
            reveal: { _, _ in false }, openFile: { opened = $0 })
        controller.setRoot(root)
        controller.query = "rlnt"
        controller.requestQuickOpen()
        await controller.submit()?.value
        XCTAssertEqual(opened, file)
        XCTAssertNil(controller.quickOpenRequest)
        opened = nil
        controller.requestQuickOpen()
        let pending = controller.submit()
        controller.query = "missing"
        await pending?.value
        XCTAssertNil(opened)
        XCTAssertFalse(controller.hasSearched)
    }

    func testQuickFoldersWithoutRootUsePinnedOrderDeduplicateAndOpenOnImmediateEnter() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("中文😀笔记", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        var locations = [first, second, first]
        var opened: URL?
        let controller = FolderSearchController(snapshots: { nil }, open: { _ in nil }, reveal: { _, _ in false },
            openFile: { _ in XCTFail("A folder must not be opened as a file") },
            folderLocations: { locations }, openFolder: { opened = $0 })
        controller.requestQuickOpen()
        XCTAssertNotNil(controller.quickOpenRequest)
        await controller.start()?.value
        XCTAssertEqual(controller.quickOpenItems, [.folder(first), .folder(second)])
        controller.query = "中😀记"
        await controller.submit()?.value
        XCTAssertEqual(opened, first)
        XCTAssertNil(controller.root)
        opened = nil
        controller.requestQuickOpen()
        controller.query = ""
        await controller.start()?.value
        locations.removeAll { $0 == first }
        controller.select(.folder(first))
        XCTAssertNil(opened)
        XCTAssertEqual(controller.message, .stale)
        XCTAssertFalse(controller.hasSearched)
    }

    func testQuickFoldersAndFilesShareRankingAndChangedLocationsRejectPendingResult() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ReleaseNotes.md")
        try Data().write(to: file)
        let folder = root.appendingPathComponent("ReleaseNotes.md-archive", isDirectory: true)
        var locations = [folder]
        var opened: URL?
        let controller = FolderSearchController(snapshots: { nil }, open: { _ in nil }, reveal: { _, _ in false },
            openFile: { opened = $0 }, folderLocations: { locations }, openFolder: { opened = $0 })
        controller.setRoot(root)
        controller.query = "ReleaseNotes.md"
        controller.requestQuickOpen()
        await controller.start()?.value
        XCTAssertEqual(controller.quickOpenItems.first, .file(.init(url: file, relativePath: "ReleaseNotes.md")))
        await controller.submit()?.value
        XCTAssertEqual(opened, file)
        opened = nil
        controller.requestQuickOpen()
        let pending = controller.submit()
        locations = []
        await pending?.value
        XCTAssertNil(opened)
        XCTAssertEqual(controller.message, .stale)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testFileAndTextSearchUseCurrentSnapshotAndRejectStaleResult() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文.md")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let identity = DocumentFileIdentity.resolve(file)
        var document = FolderSearchService.OpenDocument(url: file, identity: identity,
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "😀 needle"))
        var providerCalls = 0
        var opened: URL?
        var revealed: NSRange?
        let controller = FolderSearchController(snapshots: { providerCalls += 1; return [document] },
            open: { _ in nil }, reveal: { match, _ in revealed = match.range; return true },
            openFile: { opened = $0 })
        controller.setRoot(root)
        controller.query = "中文"
        await controller.start()?.value
        XCTAssertEqual(providerCalls, 0)
        controller.select(try XCTUnwrap(controller.files.first))
        XCTAssertEqual(opened?.path, file.path)
        XCTAssertEqual(FolderSearchRow.rows(controller).count, controller.files.count + controller.problems.count)
        controller.mode = .text
        controller.query = "needle"
        await controller.start()?.value
        let match = try XCTUnwrap(controller.matches.first)
        XCTAssertEqual(FolderSearchRow.rows(controller).count, controller.matches.count + controller.problems.count)
        XCTAssertEqual(match.range, NSRange(location: 3, length: 6))
        await controller.select(match)?.value
        XCTAssertEqual(revealed, match.range)
        revealed = nil
        document = FolderSearchService.OpenDocument(url: file, identity: identity,
            snapshot: DocumentTextSnapshot(documentID: document.snapshot.documentID, revision: 2, text: "changed needle"))
        await controller.select(match)?.value
        XCTAssertNil(revealed)
        XCTAssertEqual(controller.message, .stale)
        controller.query = "other"
        XCTAssertNil(controller.select(match))
        XCTAssertTrue(controller.matches.isEmpty)
    }

    func testDelayedOpenCannotRevealAfterQueryChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let started = expectation(description: "open started")
        var continuation: CheckedContinuation<FolderSearchService.OpenDocument?, Never>?
        var documents: [FolderSearchService.OpenDocument] = []
        var revealed = false
        let controller = FolderSearchController(snapshots: { documents }, open: { _ in
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }, reveal: { _, _ in revealed = true; return true }, openFile: { _ in })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        await controller.start()?.value
        let match = try XCTUnwrap(controller.matches.first)
        let task = try XCTUnwrap(controller.select(match))
        await fulfillment(of: [started], timeout: 5)
        controller.query = "new query"
        let opened = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 0, text: "needle"))
        documents = [opened]
        continuation?.resume(returning: opened)
        await task.value
        XCTAssertFalse(revealed)
        XCTAssertTrue(controller.matches.isEmpty)
    }

    func testChangedDiskAndRootSwitchRejectOldRows() async throws {
        let first = try directory(), second = try directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let file = first.appendingPathComponent("file.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        var opened = false
        let controller = FolderSearchController(snapshots: { [] }, open: { _ in opened = true; return nil },
                                                reveal: { _, _ in false }, openFile: { _ in })
        controller.setRoot(first)
        controller.mode = .text
        controller.query = "needle"
        await controller.start()?.value
        let match = try XCTUnwrap(controller.matches.first)
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        await controller.select(match)?.value
        XCTAssertFalse(opened)
        XCTAssertEqual(controller.message, .stale)
        controller.setRoot(second)
        controller.setRoot(first)
        XCTAssertNil(controller.select(match))
    }

    func testDiskChangeDuringOpenRejectsReveal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let started = expectation(description: "open started")
        var continuation: CheckedContinuation<FolderSearchService.OpenDocument?, Never>?
        var documents: [FolderSearchService.OpenDocument] = []
        var revealed = false
        let controller = FolderSearchController(snapshots: { documents }, open: { _ in
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }, reveal: { _, _ in revealed = true; return true }, openFile: { _ in })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        await controller.start()?.value
        let task = try XCTUnwrap(controller.select(try XCTUnwrap(controller.matches.first)))
        await fulfillment(of: [started], timeout: 5)
        try "needle but changed".write(to: file, atomically: true, encoding: .utf8)
        let opened = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 0, text: "needle but changed"))
        documents = [opened]
        continuation?.resume(returning: opened)
        await task.value
        XCTAssertFalse(revealed)
        XCTAssertEqual(controller.message, .stale)
    }

    func testNewOpenDocumentInvalidatesDiskResultsBeforePublication() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let document = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "unsaved"))
        var calls = 0
        let controller = FolderSearchController(snapshots: {
            calls += 1
            return calls == 1 ? [] : [document]
        }, open: { _ in nil }, reveal: { _, _ in false }, openFile: { _ in })
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        await controller.start()?.value
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertEqual(controller.message, .stale)
        XCTAssertFalse(controller.hasSearched)
    }

    private func write(_ text: String, _ name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func textController(_ root: URL, confirm: Bool = false,
                                snapshots: @escaping () -> [FolderSearchService.OpenDocument]? = { [] },
                                extraction: @escaping (String, Int) -> Void = { _, _ in }) -> FolderSearchController {
        let controller = FolderSearchController(snapshots: snapshots, open: { _ in nil }, reveal: { _, _ in false }, openFile: { _ in },
                                                confirmReplace: { _ in confirm }, showExtraction: extraction)
        controller.setRoot(root)
        controller.mode = .text
        return controller
    }

    func testFileMaskChangeInvalidatesResultsAndAppliesOnlyToText() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", "a.md", in: root)
        try write("needle", "b.txt", in: root)
        let controller = textController(root)
        controller.query = "needle"
        await controller.start()?.value
        XCTAssertEqual(controller.matches.count, 2)
        controller.fileMask = "*.md"
        XCTAssertTrue(controller.matches.isEmpty)
        XCTAssertFalse(controller.hasSearched)
        await controller.start()?.value
        XCTAssertEqual(controller.matches.map(\.file.relativePath), ["a.md"])
    }

    func testMaskedSearchLimitsMatchesAndReplace() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", "a.md", in: root)
        try write("needle", "b.txt", in: root)
        let controller = textController(root, confirm: true)
        controller.query = "needle"
        controller.fileMask = "*.md"
        controller.isReplaceEnabled = true
        controller.replacement = "x"
        await controller.start()?.value
        XCTAssertEqual(controller.matches.count, 1)
        await controller.replaceSelected()?.value
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8), "x")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8), "needle")
    }

    func testExtractCreatesOneTabAndKeepsSearchResults() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("x needle\ny", "a.md", in: root)
        try write("needle", "sub/b.md", in: root)
        var shown: [(String, Int)] = []
        let controller = textController(root, extraction: { shown.append(($0, $1)) })
        controller.query = "needle"
        await controller.start()?.value
        let before = controller.matches
        await controller.extract(.line)?.value
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.0, "a.md:1: x needle\nsub/b.md:1: needle\n")
        XCTAssertEqual(shown.first?.1, 2)
        XCTAssertEqual(controller.matches, before)
        XCTAssertTrue(controller.hasSearched)
        XCTAssertFalse(controller.isExtracting)
        XCTAssertNil(controller.extractionNote)
    }

    func testExtractZeroMatchesShowsNoteAndCreatesNoTab() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("hay", "a.md", in: root)
        var calls = 0
        let controller = textController(root, extraction: { _, _ in calls += 1 })
        controller.query = "needle"
        await controller.extract(.match)?.value
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(controller.extractionNote, .empty)
        XCTAssertFalse(controller.isExtracting)
    }

    func testExtractCancelledCreatesNoTab() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", "a.md", in: root)
        var calls = 0
        let controller = textController(root, extraction: { _, _ in calls += 1 })
        controller.query = "needle"
        let task = controller.extract(.match)
        XCTAssertTrue(controller.isExtracting)
        controller.cancelExtraction()
        XCTAssertFalse(controller.isExtracting)
        await task?.value
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.extractionNote)
    }

    func testExtractStaleSnapshotsReportStale() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", "a.md", in: root)
        let unavailable = textController(root, snapshots: { nil })
        unavailable.query = "needle"
        XCTAssertNil(unavailable.extract(.match))
        XCTAssertEqual(unavailable.extractionNote, .stale)

        let file = root.appendingPathComponent("a.md")
        let document = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "needle"))
        var calls = 0
        var shown = 0
        let changing = textController(root, snapshots: { calls += 1; return calls == 1 ? [] : [document] }, extraction: { _, _ in shown += 1 })
        changing.query = "needle"
        await changing.extract(.match)?.value
        XCTAssertEqual(shown, 0)
        XCTAssertEqual(changing.extractionNote, .stale)
    }

    func testExtractInvalidPatternReportsInvalidPattern() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = textController(root)
        controller.usesRegex = true
        controller.query = "("
        XCTAssertNil(controller.extract(.match))
        XCTAssertEqual(controller.extractionNote, .invalidPattern)
    }

    func testExtractAppendsReadProblemsBlock() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", "a.md", in: root)
        try Data([0xff]).write(to: root.appendingPathComponent("bad.md"))
        var text = ""
        let controller = textController(root, extraction: { value, _ in text = value })
        controller.query = "needle"
        await controller.extract(.match)?.value
        XCTAssertEqual(text, "a.md:1: needle\n\n" + L10n.tr("未能读取的文件：") + "\nbad.md — " + L10n.tr("不是有效的 UTF-8") + "\n")
    }

    func testExtractUnavailableWhileSearchBusy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("needle", "a.md", in: root)
        var calls = 0
        let controller = textController(root, extraction: { _, _ in calls += 1 })
        controller.query = "needle"
        let search = controller.start()
        XCTAssertTrue(controller.isWorking)
        XCTAssertNil(controller.extract(.match))
        await search?.value
        XCTAssertEqual(calls, 0)
        controller.mode = .tags
        XCTAssertNil(controller.extract(.match))
    }
}
