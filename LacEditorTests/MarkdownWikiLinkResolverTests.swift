import Foundation
import XCTest
@testable import LacEditor

final class MarkdownWikiLinkResolverTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
    private lazy var resolver = MarkdownWikiLinkResolver(base: base, paths: ["notes/a.md", "b.md", "sub/b.md", "Заметка.md"])

    func testFindsFileByNameWithoutCaseAndExtension() {
        XCTAssertEqual(resolver.resolve(target: "a"), .file("notes/a.md"))
        XCTAssertEqual(resolver.resolve(target: "A"), .file("notes/a.md"))
        XCTAssertEqual(resolver.resolve(target: "a.md"), .file("notes/a.md"))
        XCTAssertEqual(resolver.resolve(target: "заметка"), .file("Заметка.md"))
    }

    func testPathAndDotSlashChooseOneOfSameNames() {
        XCTAssertEqual(resolver.resolve(target: "sub/b"), .file("sub/b.md"))
        XCTAssertEqual(resolver.resolve(target: "./b"), .file("b.md"))
    }

    func testSameNameIsAmbiguousAndNotGuessed() {
        XCTAssertEqual(resolver.resolve(target: "b"), .ambiguous(["b.md", "sub/b.md"]))
    }

    func testMissingAndInvalidTargets() {
        XCTAssertEqual(resolver.resolve(target: "new"), .missing("new.md"))
        XCTAssertEqual(resolver.resolve(target: "dir/new.md"), .missing("dir/new.md"))
        XCTAssertEqual(resolver.resolve(target: "../x"), .invalid)
        XCTAssertEqual(resolver.resolve(target: "/etc/x"), .invalid)
        XCTAssertEqual(resolver.resolve(target: ""), .currentDocument)
        XCTAssertEqual(MarkdownWikiLinkResolver(base: nil, paths: []).resolve(target: "a"), .invalid)
    }

    func testBaseIsRootOrDocumentDirectory() {
        let root = URL(fileURLWithPath: "/tmp/vault", isDirectory: true)
        let document = URL(fileURLWithPath: "/tmp/other/doc.md")
        XCTAssertEqual(MarkdownWikiLinkResolver.base(root: root, documentURL: document)?.path, "/tmp/vault")
        XCTAssertEqual(MarkdownWikiLinkResolver.base(root: nil, documentURL: document)?.path, "/tmp/other")
        XCTAssertNil(MarkdownWikiLinkResolver.base(root: nil, documentURL: nil))
    }

    func testURLStaysInsideBase() {
        XCTAssertEqual(resolver.url(for: "sub/b.md")?.path, "/tmp/vault/sub/b.md")
        XCTAssertNil(resolver.url(for: "../b.md"))
    }

    func testCompletionsListAllNamesWithoutLimitAndFilterByPrefix() {
        XCTAssertEqual(Set(resolver.completions(prefix: "")), ["a", "./b", "sub/b", "Заметка"])
        XCTAssertEqual(resolver.completions(prefix: "su"), ["sub/b"])
        XCTAssertEqual(resolver.completions(prefix: "ЗАМ"), ["Заметка"])
        XCTAssertTrue(resolver.completions(prefix: "zzz").isEmpty)
        // Фильтр работает и по пути; показывается форма, однозначно указывающая на файл.
        XCTAssertEqual(resolver.completions(prefix: "notes"), ["a"])
        XCTAssertEqual(Set(resolver.completions(prefix: "b")), ["./b", "sub/b"])
        let many = MarkdownWikiLinkResolver(base: base, paths: (0..<500).map { "n\($0).md" })
        XCTAssertEqual(many.completions(prefix: "").count, 500)
    }

    func testEveryCompletionResolvesToExactlyItsFile() {
        for value in resolver.completions(prefix: "") {
            guard case .file = resolver.resolve(target: value) else { return XCTFail("\(value) must resolve to a file") }
        }
    }
}
