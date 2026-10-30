import Foundation
import XCTest
@testable import LacEditor

final class FolderSearchTests: XCTestCase {
    func testIdentityLookupMatchesIdentityRules() {
        let a = DocumentFileIdentity(canonicalPath: "/a", resourceIdentifier: "one")
        let alias = DocumentFileIdentity(canonicalPath: "/b", resourceIdentifier: "one")
        let different = DocumentFileIdentity(canonicalPath: "/a", resourceIdentifier: "two")
        let missing = DocumentFileIdentity(canonicalPath: "/a", resourceIdentifier: nil)
        var index = FolderSearchService.IdentityLookup()
        index.insert(a, value: 0)
        index.insert(different, value: 1)
        index.insert(missing, value: 2)
        for identity in [a, alias, different, missing] {
            let expected = [a, different, missing].enumerated().compactMap { identity.matches($0.element) ? $0.offset : nil }
            XCTAssertEqual(Set(index.matches(identity)), Set(expected))
        }
    }

    func testHardLinksUseOpenDocumentSnapshotOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.md"), second = root.appendingPathComponent("b.md")
        try "disk".write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: first, to: second)
        let snapshot = DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "needle")
        let open = FolderSearchService.OpenDocument(url: second, identity: DocumentFileIdentity.resolve(second), snapshot: snapshot)
        let result = try FolderSearchService.search(root: root, query: "needle", caseSensitive: true, openDocuments: [open])
        XCTAssertEqual(result.values.count, 1)
        XCTAssertEqual(result.values.first?.file.url.path, second.path)
        XCTAssertTrue(FolderSearchService.isCurrent(try XCTUnwrap(result.values.first), openDocument: open))
    }

    func testManyMatchesShareOneLineContext() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.md")
        let line = String(repeating: "needle ", count: 10_000)
        try line.write(to: file, atomically: true, encoding: .utf8)
        let result = try FolderSearchService.search(root: root, query: "needle", caseSensitive: true, openDocuments: [])
        XCTAssertEqual(result.values.count, 10_000)
        XCTAssertEqual(result.values.first?.context, line)
        XCTAssertEqual(result.values.last?.context, line)
        XCTAssertEqual(Set(result.values.map(\.contextRange)), [NSRange(location: 0, length: (line as NSString).length)])
    }
    func testFuzzyNamesRankExactBeforeSubstringBeforeSubsequence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["rd.md", "rd-extra.md", "readme.md", "random.md", "other.md", "中文😀记录.md", "café.md"] {
            try Data([0xff]).write(to: root.appendingPathComponent(name))
        }
        let ranked = try FolderSearchService.files(root: root, query: "rd.md", caseSensitive: false)
        XCTAssertEqual(ranked.values.first?.relativePath, "rd.md")
        XCTAssertEqual(Set(ranked.values.dropFirst().map(\.relativePath)), ["random.md", "rd-extra.md", "readme.md"])
        XCTAssertEqual(try FolderSearchService.files(root: root, query: "rd.md", caseSensitive: false).values, ranked.values)
        let substring = try FolderSearchService.files(root: root, query: "rd", caseSensitive: false)
        XCTAssertEqual(Set(substring.values.prefix(2).map(\.relativePath)), ["rd-extra.md", "rd.md"])
        XCTAssertEqual(try FolderSearchService.files(root: root, query: "中😀记", caseSensitive: false).values.map(\.relativePath), ["中文😀记录.md"])
        XCTAssertEqual(try FolderSearchService.files(root: root, query: "CAÉ", caseSensitive: false).values.map(\.relativePath), ["café.md"])
        XCTAssertTrue(try FolderSearchService.files(root: root, query: "CAÉ", caseSensitive: true).values.isEmpty)
        XCTAssertTrue(try FolderSearchService.files(root: root, query: "xyz", caseSensitive: false).values.isEmpty)
    }

    func testFuzzyPathsAndCancellation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("Release.md"))
        XCTAssertEqual(try FolderSearchService.files(root: root, query: "nt/rl", caseSensitive: false).values.map(\.relativePath), ["Notes/Release.md"])
        var calls = 0
        XCTAssertThrowsError(try FolderSearchService.files(root: root, query: "zz", caseSensitive: false) {
            calls += 1
            return calls > 8
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPathsUnicodeOpenSnapshotsAndInvalidUTF8() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("中文", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("same.md")
        let second = folder.appendingPathComponent("same.md")
        try "disk only".write(to: first, atomically: true, encoding: .utf8)
        try "中文😀 needle\r\nnext line".write(to: second, atomically: true, encoding: .utf8)
        let bad = root.appendingPathComponent("bad.bin")
        try Data([0xff, 0xfe, 0xff]).write(to: bad)
        let names = try FolderSearchService.files(root: root, query: "same", caseSensitive: false)
        XCTAssertEqual(Set(names.values.map(\.relativePath)), ["same.md", "中文/same.md"])
        let snapshot = DocumentTextSnapshot(documentID: UUID(), revision: 7, text: "unsaved NEEDLE")
        let open = FolderSearchService.OpenDocument(url: first, identity: DocumentFileIdentity.resolve(first), snapshot: snapshot)
        let result = try FolderSearchService.search(root: root, query: "needle", caseSensitive: false, openDocuments: [open])
        XCTAssertEqual(result.values.count, 2)
        XCTAssertTrue(result.problems.contains { $0.url.path == bad.path && $0.reason == .invalidUTF8 })
        let live = try XCTUnwrap(result.values.first { $0.file.url.path == first.path })
        XCTAssertEqual(live.matchedText, "NEEDLE")
        XCTAssertTrue(FolderSearchService.isCurrent(live, openDocument: open))
        let changed = FolderSearchService.OpenDocument(url: first, identity: open.identity,
            snapshot: DocumentTextSnapshot(documentID: snapshot.documentID, revision: 8, text: snapshot.text))
        XCTAssertFalse(FolderSearchService.isCurrent(live, openDocument: changed))
        let disk = try XCTUnwrap(result.values.first { $0.file.url.path == second.path })
        XCTAssertEqual(disk.range, ("中文😀 needle\r\nnext line" as NSString).range(of: "needle"))
        XCTAssertEqual(disk.context, "中文😀 needle\r\n")
        XCTAssertTrue(try FolderSearchService.isCurrent(disk, root: root))
        let spanning = try FolderSearchService.search(root: root, query: "needle\r\nnext", caseSensitive: true, openDocuments: [])
        let spanningMatch = try XCTUnwrap(spanning.values.first)
        XCTAssertEqual(spanningMatch.context, "中文😀 needle\r\nnext line")
        try "changed content".write(to: second, atomically: true, encoding: .utf8)
        XCTAssertFalse(try FolderSearchService.isCurrent(disk, root: root))
    }

    func testDeletedOpenFileAndOutsideScope() throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let path = root.appendingPathComponent("deleted.md")
        try "disk".write(to: path, atomically: true, encoding: .utf8)
        let identity = DocumentFileIdentity.resolve(path)
        try FileManager.default.removeItem(at: path)
        let snapshot = DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "needle unsaved")
        let deleted = FolderSearchService.OpenDocument(url: path, identity: identity, snapshot: snapshot)
        let outsideURL = outside.appendingPathComponent("outside.md")
        let external = FolderSearchService.OpenDocument(url: outsideURL, identity: DocumentFileIdentity.resolve(outsideURL), snapshot: snapshot)
        let result = try FolderSearchService.search(root: root, query: "needle", caseSensitive: true, openDocuments: [deleted, external])
        XCTAssertEqual(result.values.map(\.file.relativePath), ["deleted.md"])
    }

    func testLinksCancellationAndConflictingSnapshots() throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let externalFile = outside.appendingPathComponent("secret.md")
        try "needle".write(to: externalFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir"), withDestinationURL: outside)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: externalFile)
        let file = root.appendingPathComponent("local.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let identity = DocumentFileIdentity.resolve(file)
        let a = FolderSearchService.OpenDocument(url: file, identity: identity,
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 0, text: "needle A"))
        let b = FolderSearchService.OpenDocument(url: file, identity: identity,
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 0, text: "needle B"))
        let result = try FolderSearchService.search(root: root, query: "needle", caseSensitive: true, openDocuments: [a, b])
        XCTAssertTrue(result.values.isEmpty)
        XCTAssertTrue(result.problems.contains { $0.url.path == file.path && $0.reason == .conflictingOpenDocuments })
        XCTAssertTrue(result.problems.contains { $0.url.path == link.path && $0.reason == .symbolicLink })
        var checks = 0
        XCTAssertThrowsError(try FolderSearchService.search(root: root, query: "needle", caseSensitive: true, openDocuments: [], isCancelled: {
            checks += 1
            return checks > 3
        })) { XCTAssertTrue($0 is CancellationError) }
    }

    func testMarkdownFilesListsOnlyMarkdownAndSkipsSymlinkedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("md-files-" + UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("md-outside-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("sub/b.MARKDOWN"), atomically: true, encoding: .utf8)
        try "t".write(to: root.appendingPathComponent("t.txt"), atomically: true, encoding: .utf8)
        try "o".write(to: outside.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let result = try FolderSearchService.markdownFiles(root: root)
        XCTAssertEqual(Set(result.values.map(\.relativePath)), ["a.md", "sub/b.MARKDOWN"])
    }
}
