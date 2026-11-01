import Foundation
import XCTest
@testable import LacEditor

final class FolderFileFilterTests: XCTestCase {
    func testEmptyMaskIncludesEverything() {
        for mask in ["", "   ", " , ,"] {
            let filter = FolderFileFilter(mask)
            XCTAssertTrue(filter.isEmpty, mask)
            XCTAssertTrue(filter.includes(relativePath: "a.md"))
            XCTAssertTrue(filter.includes(relativePath: "x/y/z.bin"))
            XCTAssertFalse(filter.excludesDirectory(relativePath: "x"))
        }
    }

    func testExtensionPatternMatchesNameOnly() {
        let filter = FolderFileFilter("*.md")
        XCTAssertTrue(filter.includes(relativePath: "a.md"))
        XCTAssertTrue(filter.includes(relativePath: "x/y/a.md"))
        XCTAssertFalse(filter.includes(relativePath: "a.mdx"))
        XCTAssertFalse(filter.includes(relativePath: "a.txt"))
    }

    func testCaseInsensitive() {
        let filter = FolderFileFilter("*.MD")
        XCTAssertTrue(filter.includes(relativePath: "a.md"))
        XCTAssertTrue(filter.includes(relativePath: "B.Md"))
    }

    func testSeveralPositivePatterns() {
        let filter = FolderFileFilter("*.md, *.txt")
        XCTAssertTrue(filter.includes(relativePath: "a.md"))
        XCTAssertTrue(filter.includes(relativePath: "d/b.txt"))
        XCTAssertFalse(filter.includes(relativePath: "c.swift"))
    }

    func testNegationOnlyMeansEverythingExceptThat() {
        let filter = FolderFileFilter("!*.log")
        XCTAssertFalse(filter.includes(relativePath: "a.log"))
        XCTAssertFalse(filter.includes(relativePath: "x/a.log"))
        XCTAssertTrue(filter.includes(relativePath: "a.md"))
    }

    func testNegatedDirectoryExcludesNestedFilesAndPrunes() {
        let filter = FolderFileFilter("!node_modules")
        XCTAssertFalse(filter.includes(relativePath: "node_modules/a/b.js"))
        XCTAssertFalse(filter.includes(relativePath: "pkg/node_modules/b.js"))
        XCTAssertTrue(filter.includes(relativePath: "src/b.js"))
        XCTAssertTrue(filter.excludesDirectory(relativePath: "node_modules"))
        XCTAssertTrue(filter.excludesDirectory(relativePath: "pkg/node_modules"))
        XCTAssertFalse(filter.excludesDirectory(relativePath: "src"))
    }

    func testPathPatternComparesRelativePath() {
        let filter = FolderFileFilter("docs/*.md")
        XCTAssertTrue(filter.includes(relativePath: "docs/a.md"))
        XCTAssertFalse(filter.includes(relativePath: "docs/sub/a.md"))
        XCTAssertFalse(filter.includes(relativePath: "a.md"))
        let nested = FolderFileFilter("docs/**")
        XCTAssertTrue(nested.includes(relativePath: "docs/a.md"))
        XCTAssertTrue(nested.includes(relativePath: "docs/sub/a.md"))
        XCTAssertFalse(nested.includes(relativePath: "other/a.md"))
        let anywhere = FolderFileFilter("**/*.md")
        XCTAssertTrue(anywhere.includes(relativePath: "a.md"))
        XCTAssertTrue(anywhere.includes(relativePath: "x/a.md"))
        XCTAssertTrue(anywhere.includes(relativePath: "x/y/a.md"))
        XCTAssertFalse(anywhere.includes(relativePath: "x/a.txt"))
    }

    func testQuestionMarkMatchesOneCharacterAndNotSlash() {
        let name = FolderFileFilter("a?.md")
        XCTAssertTrue(name.includes(relativePath: "ab.md"))
        XCTAssertFalse(name.includes(relativePath: "a.md"))
        XCTAssertFalse(name.includes(relativePath: "abc.md"))
        let path = FolderFileFilter("x/a?b.md")
        XCTAssertTrue(path.includes(relativePath: "x/axb.md"))
        XCTAssertFalse(path.includes(relativePath: "x/a/b.md"))
    }

    func testStarDoesNotCrossSlash() {
        let filter = FolderFileFilter("docs/*.md")
        XCTAssertFalse(filter.includes(relativePath: "docs/a/b.md"))
    }

    func testPositiveAndNegativeTogether() {
        let filter = FolderFileFilter("*.md, !draft*")
        XCTAssertTrue(filter.includes(relativePath: "a.md"))
        XCTAssertFalse(filter.includes(relativePath: "draft1.md"))
        XCTAssertFalse(filter.includes(relativePath: "draft/a.md"))
        XCTAssertFalse(filter.includes(relativePath: "a.txt"))
    }

    func testLeadingDotSlashTrailingSlashAndSpacesAreTrimmed() {
        let filter = FolderFileFilter(" ./docs/*.md , !build/ ")
        XCTAssertTrue(filter.includes(relativePath: "docs/a.md"))
        XCTAssertFalse(filter.includes(relativePath: "docs/build/a.md"))
        XCTAssertTrue(filter.excludesDirectory(relativePath: "docs/build"))
        XCTAssertFalse(filter.includes(relativePath: "a.md"))
    }

    func testRegexMetacharactersAreLiteral() {
        XCTAssertTrue(FolderFileFilter("a+b.md").includes(relativePath: "a+b.md"))
        XCTAssertFalse(FolderFileFilter("a+b.md").includes(relativePath: "aab.md"))
        XCTAssertTrue(FolderFileFilter("[x].md").includes(relativePath: "[x].md"))
        XCTAssertFalse(FolderFileFilter("[x].md").includes(relativePath: "x.md"))
        XCTAssertTrue(FolderFileFilter("(1).md").includes(relativePath: "(1).md"))
        XCTAssertTrue(FolderFileFilter("{a}.md").includes(relativePath: "{a}.md"))
        XCTAssertFalse(FolderFileFilter("{a}.md").includes(relativePath: "a.md"))
    }

    func testNonAsciiNames() {
        let filter = FolderFileFilter("*.md")
        XCTAssertTrue(filter.includes(relativePath: "заметка.md"))
        XCTAssertTrue(filter.includes(relativePath: "笔记.md"))
        let excluded = FolderFileFilter("!черновики")
        XCTAssertFalse(excluded.includes(relativePath: "черновики/a.md"))
        XCTAssertFalse(excluded.includes(relativePath: "ЧЕРНОВИКИ/a.md"))
        XCTAssertTrue(excluded.includes(relativePath: "заметки/a.md"))
    }

    func testNegatedPathPatternDoesNotPruneItself() {
        let filter = FolderFileFilter("!build/**")
        XCTAssertFalse(filter.excludesDirectory(relativePath: "build"))
        XCTAssertFalse(filter.includes(relativePath: "build/a.md"))
    }

    func testEquatableAndIsEmpty() {
        XCTAssertEqual(FolderFileFilter("*.md"), FolderFileFilter(" *.md ,"))
        XCTAssertNotEqual(FolderFileFilter("*.md"), FolderFileFilter("*.txt"))
        XCTAssertNotEqual(FolderFileFilter("*.md"), FolderFileFilter("!*.md"))
        XCTAssertTrue(FolderFileFilter("").isEmpty)
        XCTAssertFalse(FolderFileFilter("*.md").isEmpty)
    }
}
