import Foundation
import XCTest
@testable import LacEditor

final class FolderTagSearchTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func testWholeTagSearchReportsBadMetadataAndIgnoresBodyAndOtherLanguages() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "---\r\ntags: [Editor, '中文', 'a,b']\r\n---\r\n\r\nbody"
        try source.write(to: root.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try "---\ntags: Editor\n---".write(to: root.appendingPathComponent("skip.txt"), atomically: true, encoding: .utf8)
        try "body tags: Editor".write(to: root.appendingPathComponent("body.md"), atomically: true, encoding: .utf8)
        try "---\ntags: [\n---".write(to: root.appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)
        let result = try FolderSearchService.search(root: root, query: "editor", caseSensitive: false, openDocuments: [], kind: .tags)
        XCTAssertEqual(result.values.map(\.file.relativePath), ["one.md"])
        XCTAssertEqual(result.problems.filter { $0.reason == .invalidTags }.map(\.url.lastPathComponent), ["bad.md"])
        let match = try XCTUnwrap(result.values.first)
        XCTAssertTrue(match.matchedText.hasPrefix("---\r\n"))
        XCTAssertFalse(match.matchedText.contains("body"))
        XCTAssertTrue(try FolderSearchService.isCurrent(match, root: root))
        let partial = try FolderSearchService.search(root: root, query: "edit", caseSensitive: false, openDocuments: [], kind: .tags)
        XCTAssertTrue(partial.values.isEmpty)
        let comma = try FolderSearchService.search(root: root, query: "a,b", caseSensitive: true, openDocuments: [], kind: .tags)
        XCTAssertEqual(comma.values.count, 1)
        try source.replacingOccurrences(of: "Editor", with: "Changed").write(to: match.file.url, atomically: true, encoding: .utf8)
        XCTAssertFalse(try FolderSearchService.isCurrent(match, root: root))
    }

    func testDirtyAliasSnapshotWinsAndIsReturnedOnce() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.md"), second = root.appendingPathComponent("b.md")
        try "---\ntags: old\n---".write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: first, to: second)
        let open = FolderSearchService.OpenDocument(url: second, identity: DocumentFileIdentity.resolve(second),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 3, text: "---\ntags: 新\n---\n"))
        let result = try FolderSearchService.search(root: root, query: "新", caseSensitive: true, openDocuments: [open], kind: .tags)
        XCTAssertEqual(result.values.count, 1)
        XCTAssertEqual(result.values.first?.file.url, second)
        XCTAssertTrue(FolderSearchService.isCurrent(try XCTUnwrap(result.values.first), openDocument: open))
    }

    @MainActor
    func testTagControllerUsesCurrentSnapshotsAndRevealsMetadataWithoutSelectingTagText() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one.md")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let identity = DocumentFileIdentity.resolve(file)
        var open = FolderSearchService.OpenDocument(url: file, identity: identity,
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "---\ntags: 中文\n---\n"))
        var revealed: NSRange?
        let controller = FolderSearchController(snapshots: { [open] }, open: { _ in nil },
            reveal: { match, _ in revealed = match.range; return true }, openFile: { _ in XCTFail("Unexpected unvalidated file open") })
        controller.setRoot(root)
        controller.mode = .tags
        controller.query = "中文"
        await controller.start()?.value
        let match = try XCTUnwrap(controller.matches.first)
        await controller.select(match)?.value
        XCTAssertEqual(revealed, NSRange(location: 0, length: 0))
        revealed = nil
        open = .init(url: file, identity: identity,
            snapshot: DocumentTextSnapshot(documentID: open.snapshot.documentID, revision: 2, text: "---\ntags: other\n---\n"))
        await controller.select(match)?.value
        XCTAssertNil(revealed)
        XCTAssertEqual(controller.message, .stale)
    }
}
