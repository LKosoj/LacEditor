import Foundation
import XCTest
@testable import LacEditor

final class MarkdownRenameLinkTests: XCTestCase {
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

    private func read(_ path: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// План строится до переноса, как в приложении.
    private func plan(_ root: URL, _ old: String, _ new: String, open: [FolderSearchService.OpenDocument] = []) throws -> MarkdownRenameLinkService.Plan {
        let oldURL = root.appendingPathComponent(old), newURL = root.appendingPathComponent(new)
        let rename = MarkdownRenameLinkService.Rename(oldURL: oldURL, newURL: newURL, root: root)
        return try FolderSearchService.renameReferences(rename: rename, identity: DocumentFileIdentity.resolve(oldURL), syntax: .init(), openDocuments: open)
    }

    /// Перенос и запись закрытых файлов плана.
    private func rename(_ root: URL, _ old: String, _ new: String) throws -> MarkdownRenameLinkService.Plan {
        let result = try plan(root, old, new)
        let newURL = root.appendingPathComponent(new)
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(old), to: newURL)
        for file in result.files {
            XCTAssertEqual(try MarkdownRenameLinkService.applyOnDisk(file, root: root), .replaced(file.edits.count))
        }
        return result
    }

    func testTargetRangeCoversOnlyTheTarget() {
        let text = "[[A]] [[ A ]] [[A#H]] [[A|x]] [[A#H|x]] [[中文😀]]" as NSString
        let links = MarkdownWikiLinkExtractor.links(in: text as String)
        XCTAssertEqual(links.count, 6)
        let targets = links.map { link in MarkdownWikiLinkExtractor.targetRange(of: link, in: text).map(text.substring(with:)) }
        XCTAssertEqual(targets, ["A", "A", "A", "A", "A", "中文😀"])
        XCTAssertNil(MarkdownWikiLinkExtractor.targetRange(of: links[0], in: "[[B]] [[A]]" as NSString))
    }

    func testWikiLinksKeepTheirStyle() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        try write("[[Old]] [[Old#H]] [[Old|текст]] [[Old#H|т]] [[Old.md]] [[old]] [[./Old]] [[#Заголовок]] `[[Old]]` \\[[Old]] ![[Old]]", "source.md", in: root)
        let result = try rename(root, "Old.md", "New.md")
        XCTAssertEqual(result.linkCount, 7)
        XCTAssertEqual(try read("source.md", in: root),
                       "[[New]] [[New#H]] [[New|текст]] [[New#H|т]] [[New.md]] [[New]] [[./New]] [[#Заголовок]] `[[Old]]` \\[[Old]] ![[Old]]")
        let target = root.appendingPathComponent("New.md")
        let back = try FolderSearchService.backlinks(root: root, target: .init(url: target, identity: DocumentFileIdentity.resolve(target), syntax: .init()), openDocuments: [])
        XCTAssertEqual(back.values.count, 7)
    }

    func testMovedFileGetsPathWhenShortNameBecomesAmbiguous() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        try write("", "other/New.md", in: root)
        try write("[[Old]] [[a/../x]]", "source.md", in: root)
        _ = try rename(root, "Old.md", "sub/New.md")
        XCTAssertEqual(try read("source.md", in: root), "[[sub/New]] [[a/../x]]")
    }

    func testAmbiguousLinksAreCountedAndKept() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "a/Old.md", in: root)
        try write("", "b/Old.md", in: root)
        try write("[[Old]] [[a/Old]]", "source.md", in: root)
        let result = try rename(root, "a/Old.md", "a/New.md")
        XCTAssertEqual(result.skipped.ambiguous, 1)
        XCTAssertEqual(try read("source.md", in: root), "[[Old]] [[a/New]]")
    }

    func testOrdinaryLinksChangeOnlyThePath() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        try write("[t](Old.md) [t](./Old.md#h) [t](Old.md \"title\") [t](Old.md?x=1#h) [t](Old)", "source.md", in: root)
        try write("[t](../Old.md)", "a/x.md", in: root)
        try write("[t](../Old.md)", "sub/y.md", in: root)
        _ = try rename(root, "Old.md", "sub/New.md")
        XCTAssertEqual(try read("source.md", in: root), "[t](sub/New.md) [t](./sub/New.md#h) [t](sub/New.md \"title\") [t](sub/New.md?x=1#h) [t](sub/New)")
        XCTAssertEqual(try read("a/x.md", in: root), "[t](../sub/New.md)")
        XCTAssertEqual(try read("sub/y.md", in: root), "[t](New.md)")
    }

    func testSpacesAndPercentStyleAreKept() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "My Old.md", in: root)
        try write("[t](<My Old.md>) [t](My%20Old.md)", "source.md", in: root)
        _ = try rename(root, "My Old.md", "Your New.md")
        XCTAssertEqual(try read("source.md", in: root), "[t](<Your New.md>) [t](Your%20New.md)")
    }

    func testUnsafeNameKeepsWikiLinksAndEncodesOrdinaryOnes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        try write("[[Old]] [t](Old.md)", "source.md", in: root)
        let result = try rename(root, "Old.md", "a#b.md")
        XCTAssertEqual(result.skipped.unsafeName, 1)
        XCTAssertEqual(try read("source.md", in: root), "[[Old]] [t](a%23b.md)")
    }

    func testAmpersandInNewNameIsEncoded() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        try write("[t](Old.md)", "source.md", in: root)
        _ = try rename(root, "Old.md", "x&copy.md")
        XCTAssertEqual(try read("source.md", in: root), "[t](x%26copy.md)")
    }

    func testUnsupportedAndForeignLinksAreNotTouched() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        let text = "[t](file:///x/Old.md) [t][r] <a href=\"Old.md\">x</a> [t](Old&amp;x.md) ![](Old.md) [t](http://e.com/Old.md) `[t](Old.md)`\n\n[r]: Old.md\n"
        try write(text, "source.md", in: root)
        try write("[t](Old.md)", "other/Old.md", in: root)
        let result = try plan(root, "Old.md", "New.md")
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(try read("source.md", in: root), text)
    }

    func testOpenDocumentSnapshotWinsOverDisk() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        try write("нет", "open.md", in: root)
        let url = root.appendingPathComponent("open.md")
        let document = FolderSearchService.OpenDocument(url: url, identity: DocumentFileIdentity.resolve(url),
                                                        snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 2, text: "x [[Old]]"))
        let result = try plan(root, "Old.md", "New.md", open: [document])
        let file = try XCTUnwrap(result.files.first)
        XCTAssertTrue(file.isOpen)
        XCTAssertEqual(file.edits, [.init(range: NSRange(location: 4, length: 3), original: "Old", replacement: "New")])
    }

    func testRenamedFileItselfAndNoLinksGiveEmptyPlan() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[[Old]] [x](Old.md)", "Old.md", in: root)
        try write("без ссылок", "other.md", in: root)
        let result = try plan(root, "Old.md", "New.md")
        XCTAssertEqual(result.linkCount, 0)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testApplyOnDiskChecksFileState() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Old.md", in: root)
        try write("[[Old]]", "changed.md", in: root)
        try write("[[Old]]", "ok.md", in: root)
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("[[Old]]".utf8)
        try bom.write(to: root.appendingPathComponent("bom.md"))
        let result = try plan(root, "Old.md", "New.md")
        func file(_ path: String) throws -> MarkdownRenameLinkService.FilePlan {
            try XCTUnwrap(result.files.first { $0.file.relativePath == path })
        }
        try write("[[Old]] изменено", "changed.md", in: root)
        XCTAssertEqual(try MarkdownRenameLinkService.applyOnDisk(file("changed.md"), root: root), .skipped(.changed))
        XCTAssertEqual(try MarkdownRenameLinkService.applyOnDisk(file("bom.md"), root: root), .skipped(.notExactUTF8))
        XCTAssertThrowsError(try MarkdownRenameLinkService.applyOnDisk(file("ok.md"), root: root, isCancelled: { true }))
        XCTAssertEqual(try MarkdownRenameLinkService.applyOnDisk(file("ok.md"), root: root), .replaced(1))
        XCTAssertEqual(try read("ok.md", in: root), "[[New]]")
    }
}
