import Foundation
import XCTest
@testable import LacEditor

final class MarkdownBacklinksServiceTests: XCTestCase {
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

    private func backlinks(_ root: URL, to path: String, open: [FolderSearchService.OpenDocument] = []) throws -> FolderSearchService.Result<FolderSearchService.Match> {
        let url = root.appendingPathComponent(path)
        let target = FolderSearchService.BacklinkTarget(url: url, identity: DocumentFileIdentity.resolve(url), syntax: .init())
        return try FolderSearchService.backlinks(root: root, target: target, openDocuments: open)
    }

    func testOrdinaryAndWikiLinksAreFoundAndOthersAreNot() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("цель", "b.md", in: root)
        try write("[a](b.md) [a](./sub/../b.md#h) [a](b) [[b]] [[B#h|псевдоним]]", "yes.md", in: root)
        try write("![](b.md) [a](#h) [a](http://example.com/b.md) [a](c.md) `[a](b.md)` \\[[b]]\n\n```\n[[b]]\n```", "no.md", in: root)
        try write("[x](../b.md)", "sub/deep.md", in: root)
        try write("[x](b.md)", "sub/wrong.md", in: root)
        let result = try backlinks(root, to: "b.md")
        let byFile = Dictionary(grouping: result.values, by: { $0.file.relativePath })
        XCTAssertEqual(byFile["yes.md"]?.count, 5)
        XCTAssertNil(byFile["no.md"])
        XCTAssertEqual(byFile["sub/deep.md"]?.count, 1)
        XCTAssertNil(byFile["sub/wrong.md"])
        XCTAssertNil(byFile["b.md"])
    }

    func testAmbiguousAndMissingWikiLinksAreIgnored() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "a/b.md", in: root)
        try write("", "c/b.md", in: root)
        try write("[[b]] [[a/b]] [[нет]]", "source.md", in: root)
        let result = try backlinks(root, to: "a/b.md")
        XCTAssertEqual(result.values.count, 1)
        XCTAssertEqual(result.values.first?.matchedText, "[[a/b]]")
    }

    func testRangesAreUTF16AndContextIsTheLine() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "b.md", in: root)
        let text = "第一行\r\n中文😀 [a](b.md) конец\r\nlast"
        try write(text, "source.md", in: root)
        let match = try XCTUnwrap(backlinks(root, to: "b.md").values.first)
        XCTAssertEqual(match.matchedText, "[a](b.md)")
        XCTAssertEqual((text as NSString).substring(with: match.range), match.matchedText)
        XCTAssertEqual(match.context, "中文😀 [a](b.md) конец\r\n")
    }

    func testCyrillicNameMatchesPercentEncodedAndDecomposedLinks() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "Сибирский край.md", in: root)
        try write("[a](%D0%A1%D0%B8%D0%B1%D0%B8%D1%80%D1%81%D0%BA%D0%B8%D0%B9%20%D0%BA%D1%80%D0%B0%D0%B9.md) [[сибирский край]]", "s.md", in: root)
        XCTAssertEqual(try backlinks(root, to: "Сибирский край.md").values.count, 2)
    }

    func testUnsavedSnapshotOverridesDiskAndTargetDocumentIsSkipped() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "b.md", in: root)
        try write("[a](b.md)", "disk.md", in: root)
        try write("пусто", "open.md", in: root)
        let openURL = root.appendingPathComponent("open.md")
        let snapshot = DocumentTextSnapshot(documentID: UUID(), revision: 3, text: "[[b]]")
        let document = FolderSearchService.OpenDocument(url: openURL, identity: DocumentFileIdentity.resolve(openURL), snapshot: snapshot)
        let targetURL = root.appendingPathComponent("b.md")
        let selfDocument = FolderSearchService.OpenDocument(url: targetURL, identity: DocumentFileIdentity.resolve(targetURL),
                                                            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "[[b]]"))
        let result = try backlinks(root, to: "b.md", open: [document, selfDocument])
        XCTAssertEqual(Set(result.values.map(\.file.relativePath)), ["disk.md", "open.md"])
        let fromOpen = try XCTUnwrap(result.values.first { $0.file.relativePath == "open.md" })
        XCTAssertEqual(fromOpen.source, .open(documentID: snapshot.documentID, revision: 3, identity: document.identity))
    }

    func testFileWithoutTargetNameIsNotParsed() {
        let target = FolderSearchService.BacklinkTarget(url: URL(fileURLWithPath: "/r/My Note.md"), identity: DocumentFileIdentity.resolve(URL(fileURLWithPath: "/r/My Note.md")), syntax: .init())
        let needles = MarkdownBacklinkScanner.needles(for: target)
        XCTAssertEqual(needles, ["My Note", "My%20Note"])
        XCTAssertFalse(MarkdownBacklinkScanner.mayLink("[a](other.md)" as NSString, needles: needles))
        XCTAssertTrue(MarkdownBacklinkScanner.mayLink("[a](my%20note.md)" as NSString, needles: needles))
    }

    func testNeedlesCoverDecomposedAndComposedNames() {
        let url = URL(fileURLWithPath: "/r/" + "Сибирский".decomposedStringWithCanonicalMapping + ".md")
        let target = FolderSearchService.BacklinkTarget(url: url, identity: DocumentFileIdentity.resolve(url), syntax: .init())
        let needles = MarkdownBacklinkScanner.needles(for: target)
        XCTAssertTrue(MarkdownBacklinkScanner.mayLink("[[Сибирский]]".precomposedStringWithCanonicalMapping as NSString, needles: needles))
        // Percent-кодирование NFC и NFD даёт разные ASCII-строки: каноническое сравнение их не сводит.
        let composed = "Сибирский".precomposedStringWithCanonicalMapping.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        XCTAssertTrue(MarkdownBacklinkScanner.mayLink("[a](\(composed).md)" as NSString, needles: needles))
    }

    func testCancellation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("", "b.md", in: root)
        try write("[a](b.md)", "s.md", in: root)
        let url = root.appendingPathComponent("b.md")
        let target = FolderSearchService.BacklinkTarget(url: url, identity: DocumentFileIdentity.resolve(url), syntax: .init())
        XCTAssertThrowsError(try FolderSearchService.backlinks(root: root, target: target, openDocuments: [], isCancelled: { true }))
    }
}

@MainActor
final class MarkdownBacklinksControllerTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func controller(snapshots: @escaping () -> [FolderSearchService.OpenDocument]? = { [] },
                            reveal: @escaping (FolderSearchService.Match, FolderSearchService.OpenDocument) -> Bool = { _, _ in false }) -> MarkdownBacklinksController {
        MarkdownBacklinksController(snapshots: snapshots, open: { _ in nil }, reveal: reveal)
    }

    func testStatesWithoutResults() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = controller()
        let unsaved = EditorDocument(text: "", language: .markdown)
        subject.update(root: nil, document: unsaved, isActive: true)
        XCTAssertEqual(subject.state, .noFolder)
        subject.update(root: root, document: unsaved, isActive: false)
        XCTAssertEqual(subject.state, .inactive)
        subject.update(root: root, document: unsaved, isActive: true)
        subject.refreshNow()
        XCTAssertEqual(subject.state, .unsaved)
        let outside = EditorDocument(text: "", url: URL(fileURLWithPath: "/tmp/outside-\(UUID().uuidString).md"), language: .markdown)
        subject.update(root: root, document: outside, isActive: true)
        subject.refreshNow()
        XCTAssertEqual(subject.state, .outsideFolder)
    }

    func testLoadsMatchesAndRejectsStaleSnapshots() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("b.md")
        try "".write(to: target, atomically: true, encoding: .utf8)
        try "[a](b.md)".write(to: root.appendingPathComponent("s.md"), atomically: true, encoding: .utf8)
        let document = EditorDocument(text: "", url: target, language: .markdown)
        var available = true
        let subject = controller(snapshots: { available ? [] : nil })
        subject.update(root: root, document: document, isActive: true)
        subject.refreshNow()
        try await waitUntil { subject.state == .loaded }
        XCTAssertEqual(subject.matches.map(\.file.relativePath), ["s.md"])
        available = false
        subject.refreshNow()
        XCTAssertEqual(subject.state, .stale)
        XCTAssertTrue(subject.matches.isEmpty)
        subject.update(root: root, document: document, isActive: false)
        XCTAssertEqual(subject.state, .inactive)
    }

    func testSelectOfChangedFileMarksStaleWithoutReveal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("b.md")
        let source = root.appendingPathComponent("s.md")
        try "".write(to: target, atomically: true, encoding: .utf8)
        try "[a](b.md)".write(to: source, atomically: true, encoding: .utf8)
        var revealed = false
        let subject = controller(reveal: { _, _ in revealed = true; return true })
        subject.update(root: root, document: EditorDocument(text: "", url: target, language: .markdown), isActive: true)
        subject.refreshNow()
        try await waitUntil { subject.state == .loaded }
        let match = try XCTUnwrap(subject.matches.first)
        try "изменено [a](b.md) позже, длиннее".write(to: source, atomically: true, encoding: .utf8)
        await subject.select(match)?.value
        XCTAssertFalse(revealed)
        XCTAssertEqual(subject.state, .stale)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
}
