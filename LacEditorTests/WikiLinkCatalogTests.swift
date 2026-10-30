import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class WikiLinkCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: directory.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: directory.appendingPathComponent("sub/b.markdown"), atomically: true, encoding: .utf8)
        try "t".write(to: directory.appendingPathComponent("t.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitForSnapshot(_ catalog: WikiLinkCatalog, where condition: (MarkdownWikiLinkResolver) -> Bool) async -> MarkdownWikiLinkResolver? {
        for _ in 0..<100 {
            if let snapshot = catalog.snapshot, condition(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func testListsOnlyMarkdownFilesOfRoot() async throws {
        let catalog = WikiLinkCatalog()
        XCTAssertNil(catalog.snapshot)
        catalog.ensure(root: directory, documentURL: nil)
        let snapshot = await waitForSnapshot(catalog) { _ in true }
        XCTAssertEqual(Set(try XCTUnwrap(snapshot).paths), ["a.md", "sub/b.markdown"])
    }

    func testWithoutFolderUsesDocumentDirectoryOnly() async throws {
        let catalog = WikiLinkCatalog()
        catalog.ensure(root: nil, documentURL: directory.appendingPathComponent("a.md"))
        let snapshot = await waitForSnapshot(catalog) { _ in true }
        XCTAssertEqual(try XCTUnwrap(snapshot).paths, ["a.md"])
    }

    func testInvalidateReloadsAfterFilesChange() async throws {
        let catalog = WikiLinkCatalog()
        catalog.ensure(root: directory, documentURL: nil)
        _ = await waitForSnapshot(catalog) { _ in true }
        try "n".write(to: directory.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        catalog.invalidate()
        let snapshot = await waitForSnapshot(catalog) { $0.paths.contains("new.md") }
        XCTAssertNotNil(snapshot)
    }

    func testBaseChangeDropsOldListFromResolution() async throws {
        let catalog = WikiLinkCatalog()
        catalog.ensure(root: directory, documentURL: nil)
        let first = await waitForSnapshot(catalog) { _ in true }
        let other = directory.appendingPathComponent("sub")
        catalog.ensure(root: other, documentURL: nil)
        let second = await waitForSnapshot(catalog) { $0.base?.lastPathComponent == "sub" }
        XCTAssertNotEqual(first?.base, second?.base)
        XCTAssertEqual(second?.paths, ["b.markdown"])
    }
}
