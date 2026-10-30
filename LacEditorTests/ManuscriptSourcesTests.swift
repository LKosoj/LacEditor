import Foundation
import XCTest
@testable import LacEditor

final class ManuscriptSourcesTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func file(_ path: String, in root: URL) -> FolderSearchService.File {
        .init(url: root.appendingPathComponent(path), relativePath: path)
    }

    func testOrderFollowsSelectionAndDuplicatesAreReadOnce() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.md", "b.md", "c.md"] { try write(name, name, in: root) }
        let result = try FolderSearchService.manuscriptSources(
            root: root, files: [file("c.md", in: root), file("a.md", in: root), file("c.md", in: root)], openDocuments: [])
        XCTAssertEqual(result.values.map(\.text), ["c.md", "a.md"])
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testOpenDocumentWinsOverDisk() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("disk", "a.md", in: root)
        let url = root.appendingPathComponent("a.md")
        let open = FolderSearchService.OpenDocument(url: url, identity: DocumentFileIdentity.resolve(url),
                                                    snapshot: .init(documentID: UUID(), revision: 1, text: "unsaved"))
        let result = try FolderSearchService.manuscriptSources(root: root, files: [file("a.md", in: root)], openDocuments: [open])
        XCTAssertEqual(result.values.map(\.text), ["unsaved"])
        XCTAssertEqual(result.values.map(\.isOpen), [true])
    }

    func testUnselectedBadFileIsIgnoredAndSelectedOneIsReported() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("ok", "a.md", in: root)
        try Data([0xFF, 0xFE, 0xFD]).write(to: root.appendingPathComponent("bad.md"))
        try Data([0xFF]).write(to: root.appendingPathComponent("other.md"))
        let result = try FolderSearchService.manuscriptSources(
            root: root, files: [file("a.md", in: root), file("bad.md", in: root)], openDocuments: [])
        XCTAssertEqual(result.values.map(\.text), ["ok"])
        XCTAssertEqual(result.problems.map(\.reason), [.invalidUTF8])
        XCTAssertEqual(result.problems.map { $0.url.lastPathComponent }, ["bad.md"])
    }

    func testSelectedFileRemovedAfterListingIsReported() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", "a.md", in: root)
        let result = try FolderSearchService.manuscriptSources(root: root, files: [file("a.md", in: root), file("gone.md", in: root)], openDocuments: [])
        XCTAssertEqual(result.values.map(\.text), ["a"])
        XCTAssertEqual(result.problems.map(\.reason), [.inaccessible])
        XCTAssertEqual(result.problems.first?.url.lastPathComponent, "gone.md")
    }

    func testSymbolicLinkIsReported() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("target", "real.md", in: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: root.appendingPathComponent("real.md"))
        let result = try FolderSearchService.manuscriptSources(root: root, files: [file("link.md", in: root)], openDocuments: [])
        XCTAssertTrue(result.values.isEmpty)
        XCTAssertEqual(result.problems.map(\.reason), [.symbolicLink])
    }
}
