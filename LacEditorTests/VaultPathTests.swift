import XCTest
@testable import LacEditor

final class VaultPathTests: XCTestCase {
    func testAcceptedPathsAreReturnedUnchanged() {
        for path in ["daily/2026-11-03.md", "notes/заметка.md", "笔记/今日.md", "a b/c d.md", "compiled/x.md",
                     "daily/😀.md", "a..b.md", "a/%2e%2e/b.md"] {
            XCTAssertEqual(VaultPath.validated(path), path, path)
        }
    }

    private let rejected = ["", "/etc/passwd", "/daily/a.md", "../a.md", "a/../b.md", "a/..", "..", ".", "a/./b.md",
                            "a//b.md", "a/b/", "\\a.md", "a\\b.md", "a\\..\\b.md", "a/b\u{0}.md", ".session/x.md",
                            "daily/.hidden.md", ".obsidian/app.json"]

    func testRejectedPaths() {
        for path in rejected { XCTAssertNil(VaultPath.validated(path), path) }
    }

    func testLocalURLInsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/vault-root")
        XCTAssertEqual(VaultPath.localURL(for: "daily/a.md", under: root)?.path, "/tmp/vault-root/daily/a.md")
        XCTAssertEqual(VaultPath.localURL(for: "笔记/今日.md", under: root)?.path, "/tmp/vault-root/笔记/今日.md")
        for path in rejected { XCTAssertNil(VaultPath.localURL(for: path, under: root), path) }
    }

    func testLocalURLWithOddRoots() {
        for root in ["/tmp/vault-root/", "/tmp/x/../vault-root"] {
            let url = VaultPath.localURL(for: "daily/a.md", under: URL(fileURLWithPath: root))
            XCTAssertEqual(url?.path, "/tmp/vault-root/daily/a.md", root)
            XCTAssertTrue(url?.path.hasPrefix("/tmp/vault-root/") ?? false)
        }
    }

    func testServerManagedPaths() {
        for path in ["compiled/a.md", "compiled/sub/a.md", "summaries/x.md", "MOC/compiled-index.md"] {
            XCTAssertTrue(VaultServerRules.isServerManaged(path), path)
        }
        for path in ["daily/a.md", "MOC/index.md", "compiled.md", "my/compiled/a.md", "Compiled/a.md",
                     "MOC/compiled-index.md.bak"] {
            XCTAssertFalse(VaultServerRules.isServerManaged(path), path)
        }
        XCTAssertEqual(VaultServerRules.systemFrontmatterFields, ["last_accessed", "relevance", "tier", "access_count"])
    }

    func testCombiningMarkAfterSlashIsStillSlash() {
        XCTAssertNil(VaultPath.validated("/\u{301}etc/x"))
        XCTAssertNil(VaultPath.validated("a/\u{301}/../b"))
        XCTAssertNil(VaultPath.validated("a/.\u{301}/x"))
        XCTAssertNil(VaultPath.localURL(for: "/\u{301}etc/x", under: URL(fileURLWithPath: "/tmp/vault-root")))
        XCTAssertNil(VaultPath.validated("a//\u{301}b"))
    }

    func testServerManagedWithCombiningMark() {
        XCTAssertTrue(VaultServerRules.isServerManaged("compiled/\u{301}x.md"))
        XCTAssertTrue(VaultServerRules.isServerManaged("summaries/\u{301}x.md"))
    }
}
