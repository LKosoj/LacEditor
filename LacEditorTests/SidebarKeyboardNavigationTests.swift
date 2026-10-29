import XCTest
@testable import LacEditor

@MainActor
final class SidebarKeyboardNavigationTests: XCTestCase {
    private typealias Focus = SidebarSelection.Focus

    func testMovedCrossesSectionBoundariesInVisualOrder() {
        let group = UUID()
        let order = [Focus(location: .favorites, path: "/a"), Focus(location: .favorites, path: "/b"),
                     Focus(location: .group(group), path: "/x"), Focus(location: .recent, path: "/r")]
        XCTAssertEqual(SidebarKeyboardNavigation.moved(from: order[1], offset: 1, in: order), order[2])
        XCTAssertEqual(SidebarKeyboardNavigation.moved(from: order[2], offset: -1, in: order), order[1])
        XCTAssertEqual(SidebarKeyboardNavigation.moved(from: order[0], offset: -1, in: order), order[0])
        XCTAssertEqual(SidebarKeyboardNavigation.moved(from: order[3], offset: 1, in: order), order[3])
        XCTAssertEqual(SidebarKeyboardNavigation.moved(from: nil as Focus?, offset: 1, in: order), order[0])
        XCTAssertEqual(SidebarKeyboardNavigation.moved(from: nil as Focus?, offset: -1, in: order), order[3])
        XCTAssertNil(SidebarKeyboardNavigation.moved(from: nil as Int?, offset: 1, in: []))
    }

    func testSelectionMovesAcrossSectionsAndShiftExtendsOnlyInsideSection() {
        let selection = SidebarSelection()
        let order = [Focus(location: .favorites, path: "/a"), Focus(location: .favorites, path: "/b"),
                     Focus(location: .favorites, path: "/c"), Focus(location: .recent, path: "/r")]
        selection.setNavigationOrder(order)
        selection.select(URL(fileURLWithPath: "/a"), in: .favorites, urls: [], command: false, shift: false)
        XCTAssertTrue(selection.moveFocus(from: order[0], offset: 1, extend: true))
        XCTAssertEqual(selection.focused, order[1])
        XCTAssertEqual(selection.paths, ["/a", "/b"])
        XCTAssertTrue(selection.moveFocus(from: order[2], offset: 1, extend: true))
        XCTAssertEqual(selection.focused, order[3])
        XCTAssertEqual(selection.location, .recent)
        XCTAssertEqual(selection.paths, ["/r"])
        XCTAssertFalse(SidebarSelection().moveFocus(from: order[0], offset: 1, extend: false))
    }

    func testTypeSelectMovesToNextNameWithPrefix() {
        let selection = SidebarSelection()
        let order = ["Notes.md", "readme.md", "Release.md"].map { Focus(location: .recent, path: "/d/" + $0) }
        selection.setNavigationOrder(order)
        XCTAssertTrue(selection.typeSelect("r", from: order[0]))
        XCTAssertEqual(selection.focused, order[1])
        XCTAssertTrue(selection.typeSelect("e", from: order[1]))
        XCTAssertEqual(selection.focused, order[1])
        XCTAssertTrue(selection.typeSelect("l", from: order[1]))
        XCTAssertEqual(selection.focused, order[2])
        XCTAssertFalse(selection.typeSelect("z", from: order[2]))
    }

    func testTypeSelectMatchesPrefixCaseAndDiacriticInsensitive() {
        XCTAssertEqual(SidebarTypeSelect.match(prefix: "re", names: ["Notes", "readme", "Release"], current: 0), 1)
        XCTAssertEqual(SidebarTypeSelect.match(prefix: "rel", names: ["Notes", "readme", "Release"], current: 1), 2)
        XCTAssertEqual(SidebarTypeSelect.match(prefix: "RE", names: ["Notes", "readme"], current: nil), 1)
        XCTAssertEqual(SidebarTypeSelect.match(prefix: "e", names: ["a", "école"], current: nil), 1)
        XCTAssertEqual(SidebarTypeSelect.match(prefix: "文", names: ["a.md", "文档.md"], current: nil), 1)
        XCTAssertNil(SidebarTypeSelect.match(prefix: "q", names: ["a", "b"], current: nil))
    }

    func testTypeSelectRepeatedLetterCycles() {
        let names = ["a1", "a2", "b"]
        XCTAssertEqual(SidebarTypeSelect.match(prefix: "aa", names: names, current: 0), 1)
        XCTAssertEqual(SidebarTypeSelect.match(prefix: "aa", names: names, current: 1), 0)
    }

    func testTypeSelectBufferResetsAfterOneSecond() {
        var state = SidebarTypeSelect()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        state.append("a", now: start)
        state.append("b", now: start.addingTimeInterval(0.5))
        XCTAssertEqual(state.buffer, "ab")
        state.append("c", now: start.addingTimeInterval(2))
        XCTAssertEqual(state.buffer, "c")
    }

    func testTypeSelectAcceptsOnlyPrintableCharactersWithoutCommandModifiers() {
        var state = SidebarTypeSelect()
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertTrue(state.accepts("a", hasModifiers: false, now: now))
        XCTAssertTrue(state.accepts("文", hasModifiers: false, now: now))
        XCTAssertFalse(state.accepts("a", hasModifiers: true, now: now))
        XCTAssertFalse(state.accepts("ab", hasModifiers: false, now: now))
        XCTAssertFalse(state.accepts("\r", hasModifiers: false, now: now))
        XCTAssertFalse(state.accepts("\t", hasModifiers: false, now: now))
        XCTAssertFalse(state.accepts("\u{1B}", hasModifiers: false, now: now))
        XCTAssertFalse(state.accepts("\u{F700}", hasModifiers: false, now: now))
        XCTAssertFalse(state.accepts(" ", hasModifiers: false, now: now))
        state.append("a", now: now)
        XCTAssertTrue(state.accepts(" ", hasModifiers: false, now: now.addingTimeInterval(0.5)))
        XCTAssertFalse(state.accepts(" ", hasModifiers: false, now: now.addingTimeInterval(2)))
    }

    func testFolderTreeKeyResolver() {
        let root = URL(fileURLWithPath: "/w", isDirectory: true)
        let dir = FolderWorkspaceEntry(url: root.appendingPathComponent("d"), name: "d", isDirectory: true, isSymbolicLink: false)
        let child = FolderWorkspaceEntry(url: dir.url.appendingPathComponent("c.md"), name: "c.md", isDirectory: false, isSymbolicLink: false)
        let other = FolderWorkspaceEntry(url: root.appendingPathComponent("o.md"), name: "o.md", isDirectory: false, isSymbolicLink: false)
        let rows = [dir, child, other].enumerated().map { index, entry in
            FolderWorkspaceVisibleRow(id: .init(url: entry.url, status: false), depth: index == 1 ? 1 : 0, content: .entry(entry))
        }
        func resolve(_ key: FolderTreeKey, _ index: Int, _ display: FolderWorkspaceStore.Display = .tree, expanded: Bool = false) -> FolderTreeAction? {
            FolderTreeKeyResolver.resolve(key: key, row: rows[index], rows: rows, display: display, isExpanded: expanded)
        }
        XCTAssertEqual(resolve(.right, 0), .expand(dir.url))
        XCTAssertEqual(resolve(.right, 0, expanded: true), .focus(rows[1].id))
        XCTAssertNil(resolve(.right, 2))
        XCTAssertEqual(resolve(.left, 0, expanded: true), .collapse(dir.url))
        XCTAssertEqual(resolve(.left, 1), .focus(rows[0].id))
        XCTAssertNil(resolve(.left, 2))
        XCTAssertEqual(resolve(.return, 0), .toggle(dir.url))
        XCTAssertEqual(resolve(.return, 0, .list), .showDirectory(dir.url))
        XCTAssertEqual(resolve(.return, 2), .open(other.url))
        XCTAssertNil(resolve(.left, 1, .list))
        XCTAssertNil(resolve(.right, 0, .list))
    }

    func testQuickOpenRowText() {
        let file = FolderSearchService.File(url: URL(fileURLWithPath: "/w/a/b/c.md"), relativePath: "a/b/c.md")
        XCTAssertEqual(QuickOpenRowText.title(.file(file)), "c.md")
        XCTAssertEqual(QuickOpenRowText.subtitle(.file(file)), "a/b/c.md")
        let folder = URL(fileURLWithPath: "/w/docs", isDirectory: true)
        XCTAssertEqual(QuickOpenRowText.title(.folder(folder)), "docs")
        XCTAssertEqual(QuickOpenRowText.subtitle(.folder(folder)), folder.path)
    }

    func testOutlineCurrentHeadingFollowsCaret() {
        let headings = [heading(10, "A"), heading(40, "B")]
        XCTAssertNil(MarkdownOutlineCurrent.headingID(in: headings, caret: 5, isCurrent: true))
        XCTAssertEqual(MarkdownOutlineCurrent.headingID(in: headings, caret: 10, isCurrent: true), 10)
        XCTAssertEqual(MarkdownOutlineCurrent.headingID(in: headings, caret: 39, isCurrent: true), 10)
        XCTAssertEqual(MarkdownOutlineCurrent.headingID(in: headings, caret: 500, isCurrent: true), 40)
        XCTAssertNil(MarkdownOutlineCurrent.headingID(in: headings, caret: 500, isCurrent: false))
    }

    private func heading(_ location: Int, _ title: String) -> MarkdownHeading {
        MarkdownHeading(level: 1, title: title, range: NSRange(location: location, length: title.utf16.count + 2))
    }
}
