import Foundation
import XCTest
@testable import LacEditor

final class FolderTagListingTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func testSearchFindsYAMLAndInlineTagsAndIgnoresOtherFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\ntags: [work]\n---\nA #work and #work/plan\nlast #WORK".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "#work".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "#network".write(to: root.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        let result = try FolderSearchService.search(root: root, query: "#work", caseSensitive: true, openDocuments: [], kind: .tags)
        XCTAssertEqual(result.values.map(\.matchedText).count, 4)
        XCTAssertEqual(Set(result.values.map(\.file.relativePath)), ["a.md"])
        XCTAssertTrue(result.values[0].matchedText.hasPrefix("---"))
        XCTAssertEqual(Array(result.values.dropFirst().map(\.matchedText)), ["#work", "#work/plan", "#WORK"])
        XCTAssertEqual(result.values[1].context, "A #work and #work/plan\n")
        for match in result.values { XCTAssertTrue(try FolderSearchService.isCurrent(match, root: root)) }
    }

    func testOpenSnapshotWinsForInlineTags() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.md")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let open = FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 2, text: "new #fresh"))
        let result = try FolderSearchService.search(root: root, query: "fresh", caseSensitive: false, openDocuments: [open], kind: .tags)
        XCTAssertEqual(result.values.count, 1)
        XCTAssertEqual(result.values.first?.range, NSRange(location: 4, length: 6))
        XCTAssertTrue(FolderSearchService.isCurrent(try XCTUnwrap(result.values.first), openDocument: open))
    }

    func testListingCountsFilesMergesCaseAndKeepsNestedTagsSeparate() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "---\ntags: [Work]\n---\n#work #work #a/b".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "#WORK #b".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "---\ntags: [\n---\n#c".write(to: root.appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)
        try "#skip".write(to: root.appendingPathComponent("t.txt"), atomically: true, encoding: .utf8)
        let result = try FolderSearchService.tagListing(root: root, openDocuments: [])
        XCTAssertEqual(result.values.map(\.name), ["a/b", "b", "c", "Work"])
        XCTAssertEqual(result.values.map(\.fileCount), [1, 1, 1, 2])
        XCTAssertEqual(result.problems.map(\.reason), [.invalidTags])
    }

    func testListingCancellation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "#a".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FolderSearchService.tagListing(root: root, openDocuments: [], isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    @MainActor
    func testControllerLoadsAndDropsOutdatedWork() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "#one".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let controller = FolderTagsController(snapshots: { [] })
        controller.setRoot(root)
        await controller.reload()?.value
        XCTAssertEqual(controller.tags.map(\.name), ["one"])
        XCTAssertTrue(controller.hasLoaded)
        let pending = controller.reload()
        controller.setRoot(nil)
        await pending?.value
        XCTAssertTrue(controller.tags.isEmpty)
        XCTAssertFalse(controller.hasLoaded)
    }

    @MainActor
    func testSearchTagSwitchesModeAndRequestsReveal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "#one".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let controller = FolderSearchController(snapshots: { [] }, open: { _ in nil }, reveal: { _, _ in true }, openFile: { _ in })
        controller.setRoot(root)
        XCTAssertNil(controller.revealRequest)
        await controller.searchTag("one")?.value
        XCTAssertEqual(controller.mode, .tags)
        XCTAssertEqual(controller.query, "one")
        XCTAssertNotNil(controller.revealRequest)
        XCTAssertEqual(controller.matches.map(\.matchedText), ["#one"])
    }
}
