import XCTest
@testable import LacEditor

final class MindMapModelTests: XCTestCase {
    private func apply(_ edit: MindMapTextEdit?, to text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let edit else { XCTFail("Правка не получена", file: file, line: line); return text }
        XCTAssertLessThanOrEqual(NSMaxRange(edit.range), (text as NSString).length, file: file, line: line)
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func titles(_ tree: MindMapTree) -> [String] { tree.nodes.map(\.title) }

    // MARK: Разбор

    func testSingleH1IsRealRoot() {
        let tree = MindMapDocumentParser.parse("# A\n## B\ntext\n## C\n", fallbackTitle: "Doc")
        XCTAssertEqual(tree.node(tree.rootID)?.title, "A")
        XCTAssertNotEqual(tree.node(tree.rootID)?.kind, .virtualRoot)
        let b = tree.nodes.first { $0.title == "B" }
        XCTAssertEqual(b?.subtreeRange, NSRange(location: 4, length: 10))
        XCTAssertEqual(b?.titleRange, NSRange(location: 7, length: 1))
        XCTAssertEqual(tree.node(tree.rootID)?.subtreeRange, NSRange(location: 0, length: 19))
    }

    func testTwoH1GiveVirtualRoot() {
        let tree = MindMapDocumentParser.parse("# A\n# B\n", fallbackTitle: "Doc")
        XCTAssertEqual(tree.node(tree.rootID)?.kind, .virtualRoot)
        XCTAssertEqual(tree.node(tree.rootID)?.title, "Doc")
        XCTAssertEqual(tree.node(tree.rootID)?.childIDs.count, 2)
    }

    func testFrontMatterAndCodeAreSkipped() {
        let text = "---\ntitle: x\n---\n# A\n```\n# not heading\n```\n## B\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        XCTAssertEqual(Set(titles(tree)), ["A", "B"])
    }

    func testEmptyDocumentHasNoStructure() {
        XCTAssertFalse(MindMapDocumentParser.parse("", fallbackTitle: "Doc").hasStructure)
        XCTAssertFalse(MindMapDocumentParser.parse("просто текст", fallbackTitle: "Doc").hasStructure)
    }

    func testListsAndCRLF() {
        let tree = MindMapDocumentParser.parse("- a\r\n  - b\r\n- c\r\n", fallbackTitle: "Doc")
        XCTAssertTrue(titles(tree).contains("a"))
        XCTAssertTrue(titles(tree).contains("b"))
        XCTAssertTrue(titles(tree).contains("c"))
        let a = tree.nodes.first { $0.title == "a" }
        XCTAssertEqual(a?.childIDs.count, 1)
    }

    func testTitlesInThreeLanguages() {
        let tree = MindMapDocumentParser.parse("# Книга\n## 第一章\n## Chapter\n", fallbackTitle: "Doc")
        XCTAssertEqual(titles(tree).sorted(), ["Chapter", "Книга", "第一章"].sorted())
    }

    func testLimitMarksTruncated() {
        let text = (1...20).map { "## H\($0)" }.joined(separator: "\n") + "\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc", limit: 5)
        XCTAssertTrue(tree.truncated)
        XCTAssertLessThanOrEqual(tree.nodes.count, 6)
    }

    // MARK: Правки

    func testRenameHeading() {
        let text = "# A\n## B\n## C\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let b = tree.nodes.first { $0.title == "B" }!
        XCTAssertEqual(apply(MindMapEditor.rename(tree, nodeID: b.id, newTitle: "Beta", in: text), to: text), "# A\n## Beta\n## C\n")
    }

    func testRenameEmptyListItemKeepsSpaceAfterMarker() {
        let text = "- a\n-\n- c\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        guard let empty = tree.nodes.first(where: { $0.kind == .listItem && $0.title.isEmpty }) else {
            return // пустой пункт разбор не создаёт: проверять нечего
        }
        XCTAssertEqual(apply(MindMapEditor.rename(tree, nodeID: empty.id, newTitle: "Foo", in: text), to: text), "- a\n- Foo\n- c\n")
    }

    func testAddChildAndSibling() {
        let text = "# A\n## B\n## C\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let a = tree.nodes.first { $0.title == "A" }!
        let b = tree.nodes.first { $0.title == "B" }!
        XCTAssertEqual(apply(MindMapEditor.addChild(tree, nodeID: a.id, in: text, title: "X"), to: text), "# A\n## B\n## C\n## X\n")
        XCTAssertEqual(apply(MindMapEditor.addChild(tree, nodeID: b.id, in: text, title: "Y"), to: text), "# A\n## B\n### Y\n## C\n")
        let withSibling = apply(MindMapEditor.addSibling(tree, nodeID: b.id, in: text, title: "Z"), to: text)
        XCTAssertEqual(withSibling, "# A\n## B\n## Z\n## C\n")
    }

    func testDeleteHeading() {
        let text = "# A\n## B\n## C\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let b = tree.nodes.first { $0.title == "B" }!
        XCTAssertEqual(apply(MindMapEditor.delete(tree, nodeID: b.id, in: text), to: text), "# A\n## C\n")
    }

    func testListEdits() {
        let text = "- a\n  - b\n- c\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let a = tree.nodes.first { $0.title == "a" }!
        let b = tree.nodes.first { $0.title == "b" }!
        XCTAssertEqual(apply(MindMapEditor.addChild(tree, nodeID: a.id, in: text, title: "x"), to: text), "- a\n  - b\n  - x\n- c\n")
        XCTAssertEqual(apply(MindMapEditor.addSibling(tree, nodeID: a.id, in: text, title: "N"), to: text), "- a\n  - b\n- N\n- c\n")
        XCTAssertEqual(apply(MindMapEditor.delete(tree, nodeID: b.id, in: text), to: text), "- a\n- c\n")
    }

    func testAddChildWithoutTrailingNewline() {
        let text = "# A"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let a = tree.nodes.first { $0.title == "A" }!
        XCTAssertEqual(apply(MindMapEditor.addChild(tree, nodeID: a.id, in: text, title: "X"), to: text), "# A\n## X")
    }

    func testMoveHeadingUnderSibling() {
        let text = "# A\n## B\n### B1\n## C\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let b = tree.nodes.first { $0.title == "B" }!
        let c = tree.nodes.first { $0.title == "C" }!
        guard case .edit(let edit) = MindMapEditor.move(tree, nodeID: b.id, toParent: c.id, index: 0, in: text) else {
            return XCTFail("Ожидалась правка")
        }
        XCTAssertEqual(apply(edit, to: text), "# A\n## C\n### B\n#### B1\n")
    }

    func testIndentAndOutdentViaMove() {
        let text = "# A\n## B\n## C\n### C1\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let b = tree.nodes.first { $0.title == "B" }!
        let c = tree.nodes.first { $0.title == "C" }!
        let c1 = tree.nodes.first { $0.title == "C1" }!
        // «Сделать дочерним предыдущему»: C становится последним ребёнком B.
        guard case .edit(let indent) = MindMapEditor.move(tree, nodeID: c.id, toParent: b.id, index: b.childIDs.count, in: text) else {
            return XCTFail("Ожидалась правка")
        }
        XCTAssertEqual(apply(indent, to: text), "# A\n## B\n### C\n#### C1\n")
        // «Поднять на уровень»: C1 встаёт после C у родителя A.
        let a = tree.node(tree.rootID)!
        let position = a.childIDs.firstIndex(of: c.id)!
        guard case .edit(let outdent) = MindMapEditor.move(tree, nodeID: c1.id, toParent: a.id, index: position + 1, in: text) else {
            return XCTFail("Ожидалась правка")
        }
        XCTAssertEqual(apply(outdent, to: text), "# A\n## B\n## C\n## C1\n")
    }

    func testMoveIntoOwnSubtreeIsRefused() {
        let text = "# A\n## B\n### B1\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let b = tree.nodes.first { $0.title == "B" }!
        let b1 = tree.nodes.first { $0.title == "B1" }!
        XCTAssertEqual(MindMapEditor.move(tree, nodeID: b.id, toParent: b1.id, index: 0, in: text), .refused)
    }

    func testAppendChildren() {
        let text = "# A\n"
        let tree = MindMapDocumentParser.parse(text, fallbackTitle: "Doc")
        let a = tree.nodes.first { $0.title == "A" }!
        XCTAssertEqual(apply(MindMapEditor.appendChildren(tree, nodeID: a.id, titles: ["X", "Y"], in: text), to: text), "# A\n## X\n## Y\n")
    }
}
