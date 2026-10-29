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
}
