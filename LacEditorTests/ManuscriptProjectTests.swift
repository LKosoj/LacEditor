import XCTest
@testable import LacEditor

@MainActor
final class ManuscriptProjectTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeManifest(_ json: String) throws {
        let directory = root.appendingPathComponent(".laceditor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("project.json"))
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    private func manifest(nodes: String, version: Int = 1, extra: String = "") -> String {
        """
        {"version":\(version),"projectID":"\(UUID().uuidString)","title":"Book","statuses":["Draft"],"nodes":\(nodes)\(extra)}
        """
    }

    // MARK: Манифест

    func testProbeReportsNoneFoundUnreadableAndReadOnly() throws {
        XCTAssertEqual(ManuscriptProjectStore.probe(root: root), .none)
        try writeManifest(manifest(nodes: "[]"))
        guard case let .found(_, title, isReadOnly) = ManuscriptProjectStore.probe(root: root) else { return XCTFail("found") }
        XCTAssertEqual(title, "Book")
        XCTAssertFalse(isReadOnly)
        try writeManifest(manifest(nodes: "[]", version: 9))
        guard case let .found(_, _, newer) = ManuscriptProjectStore.probe(root: root) else { return XCTFail("found") }
        XCTAssertTrue(newer)
        try writeManifest("{broken")
        guard case .unreadable = ManuscriptProjectStore.probe(root: root) else { return XCTFail("unreadable") }
    }

    func testStatusReadAsStringOrObject() throws {
        let json = """
        {"version":1,"projectID":"\(UUID().uuidString)","title":"B","statuses":["Draft",{"title":"Done","color":"green"}],"nodes":[]}
        """
        let project = try JSONDecoder().decode(ManuscriptProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.statuses.map(\.title), ["Draft", "Done"])
        XCTAssertEqual(project.statuses[1].color, .green)
    }

    func testUnknownFieldsSurviveWriting() throws {
        try write("a.md", "a")
        let node = #"[{"id":"\#(UUID().uuidString)","kind":"text","title":"A","path":"a.md","future":{"x":1}}]"#
        try writeManifest(manifest(nodes: node, extra: #","world":{"k":[1,2]}"#))
        let store = ManuscriptProjectStore(rootURL: root)
        let id = try XCTUnwrap(store.project?.nodes.first?.id)
        try store.setInclude(false, nodeID: id)
        let data = try Data(contentsOf: ManuscriptProjectStore.manifestURL(root: root))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"future\""))
        XCTAssertTrue(text.contains("\"world\""))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testNewerVersionIsNeverOverwritten() throws {
        try writeManifest(manifest(nodes: "[]", version: 5))
        let before = try Data(contentsOf: ManuscriptProjectStore.manifestURL(root: root))
        let store = ManuscriptProjectStore(rootURL: root)
        XCTAssertEqual(store.state, .readOnlyNewerVersion(5))
        XCTAssertThrowsError(try store.update { $0.title = "X" })
        XCTAssertEqual(try Data(contentsOf: ManuscriptProjectStore.manifestURL(root: root)), before)
    }

    func testCorruptManifestIsMovedAsideOnRecreate() throws {
        try writeManifest("{broken")
        let store = ManuscriptProjectStore(rootURL: root)
        guard case .unreadable = store.state else { return XCTFail("unreadable") }
        try store.recreateAfterCorruption(title: "New", language: "en", files: [])
        XCTAssertEqual(store.state, .loaded)
        let directory = root.appendingPathComponent(".laceditor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.json.corrupt").path))
    }

    func testCreateProjectKeepsFilesUntouchedAndOrder() throws {
        try write("b.md", "bb")
        try write("a.md", "aa")
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: ["b.md", "a.md"])
        XCTAssertEqual(store.project?.nodes.compactMap(\.path), ["b.md", "a.md"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8), "aa")
        XCTAssertThrowsError(try store.createProject(title: "T", language: nil, files: []))
    }

    func testExternalChangeIsDetectedAndReloaded() throws {
        try writeManifest(manifest(nodes: "[]"))
        let store = ManuscriptProjectStore(rootURL: root)
        XCTAssertFalse(store.checkForExternalChange())
        try writeManifest(manifest(nodes: "[]", extra: #","note":"changed externally"#))
        XCTAssertTrue(store.checkForExternalChange())
        XCTAssertTrue(store.externalChangeNotice)
    }

    // MARK: Проверка и правки дерева

    func testValidationRejectsDuplicatePathsAndUnsafePaths() {
        let a = ManuscriptNode(kind: .text, title: "A", path: "a.md")
        let b = ManuscriptNode(kind: .text, title: "B", path: "a.md")
        XCTAssertTrue(ManuscriptProjectValidation.validate(ManuscriptProject(title: "", nodes: [a, b])).contains { $0.severity == .error })
        let evil = ManuscriptNode(kind: .text, title: "E", path: "../x.md")
        XCTAssertTrue(ManuscriptProjectValidation.validate(ManuscriptProject(title: "", nodes: [evil])).contains { $0.severity == .error })
        XCTAssertFalse(ManuscriptProjectValidation.isSafeRelativePath("/abs.md"))
    }

    func testMoveNodeRejectsMovingGroupIntoItself() throws {
        let child = ManuscriptNode(kind: .group, title: "Inner")
        let group = ManuscriptNode(kind: .group, title: "G", children: [child])
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: [])
        try store.insertNode(group, parent: nil, index: 0)
        XCTAssertThrowsError(try store.moveNode(id: group.id, toParent: child.id, index: 0))
        XCTAssertEqual(store.project?.nodes.count, 1)
    }

    func testRenameFileUpdatesNodePathsIncludingFolderPrefix() throws {
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: [])
        try store.insertNode(ManuscriptNode(kind: .text, title: "A", path: "ch/a.md"), parent: nil, index: 0)
        XCTAssertTrue(store.renameFile(oldURL: root.appendingPathComponent("ch"), newURL: root.appendingPathComponent("part")))
        XCTAssertEqual(store.project?.nodes.first?.path, "part/a.md")
    }

    // MARK: Дерево

    func testTreeRowsFollowExpandedGroupsAndCounts() {
        let scene = ManuscriptNode(kind: .text, title: "S", path: "s.md")
        let group = ManuscriptNode(kind: .group, title: "G", children: [scene])
        let project = ManuscriptProject(title: "", nodes: [group])
        XCTAssertEqual(ManuscriptTreeRows.rows(project: project, expanded: [], missing: [], counts: [:]).map(\.depth), [0])
        let rows = ManuscriptTreeRows.rows(project: project, expanded: [group.id], missing: [scene.id], counts: [scene.id: 7])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
        XCTAssertEqual(rows[1].words, 7)
        XCTAssertTrue(rows[1].isMissing)
    }

    func testDropDestinationAdjustsIndexAndForbidsCycles() {
        let a = ManuscriptNode(kind: .text, title: "A", path: "a.md")
        let b = ManuscriptNode(kind: .text, title: "B", path: "b.md")
        let inner = ManuscriptNode(kind: .group, title: "Inner")
        let group = ManuscriptNode(kind: .group, title: "G", children: [inner])
        let project = ManuscriptProject(title: "", nodes: [a, b, group])
        // A после B: индекс считается после изъятия A.
        let after = ManuscriptTreeRows.destination(project: project, dragged: a.id, target: .after(b.id), expanded: [])
        XCTAssertNil(after?.parent)
        XCTAssertEqual(after?.index, 1)
        // На прежнее место — ничего не меняется.
        XCTAssertNil(ManuscriptTreeRows.destination(project: project, dragged: a.id, target: .before(b.id), expanded: []))
        // В группу.
        let into = ManuscriptTreeRows.destination(project: project, dragged: a.id, target: .into(group.id), expanded: [])
        XCTAssertEqual(into?.parent, group.id)
        // Группу нельзя перенести в её же вложенную группу.
        XCTAssertNil(ManuscriptTreeRows.destination(project: project, dragged: group.id, target: .into(inner.id), expanded: []))
    }

    // MARK: Сборка

    func testSynopsesModeAndMissingSynopsis() throws {
        let file = FolderSearchService.File(url: root.appendingPathComponent("a.md"), relativePath: "a.md")
        let other = FolderSearchService.File(url: root.appendingPathComponent("b.md"), relativePath: "b.md")
        let parts = [
            ManuscriptService.Part(file: file, text: "Text A", title: "Chapter A", synopsis: "About A"),
            ManuscriptService.Part(file: other, text: "Text B", title: "Chapter B", synopsis: nil)
        ]
        let output = try ManuscriptService.merge(parts, skipped: [], syntax: MarkdownSyntaxOptions(),
                                                 options: .init(mode: .synopses))
        XCTAssertTrue(output.text.contains("# Chapter A"))
        XCTAssertTrue(output.text.contains("About A"))
        XCTAssertFalse(output.text.contains("Text A"))
        XCTAssertEqual(output.report.missingSynopses, ["Chapter B"])
    }

    func testProseWithSynopsesAndGroupTitles() throws {
        let file = FolderSearchService.File(url: root.appendingPathComponent("a.md"), relativePath: "a.md")
        let part = ManuscriptService.Part(file: file, text: "Text A", title: "A", synopsis: "Idea", groupPath: ["Part", "Sub"])
        let output = try ManuscriptService.merge([part], skipped: [], syntax: MarkdownSyntaxOptions(),
                                                 options: .init(mode: .proseWithSynopses, groupTitles: true))
        let text = output.text
        let positions = ["# Part", "## Sub", "*Idea*", "Text A"].compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, 4)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testUnclosedCodeBlockIsClosedAndDoesNotSwallowNextPart() throws {
        let first = FolderSearchService.File(url: root.appendingPathComponent("a.md"), relativePath: "a.md")
        let second = FolderSearchService.File(url: root.appendingPathComponent("b.md"), relativePath: "b.md")
        let output = try ManuscriptService.merge([
            ManuscriptService.Part(file: first, text: "```\ncode"),
            ManuscriptService.Part(file: second, text: "# Next")
        ], skipped: [], syntax: MarkdownSyntaxOptions())
        XCTAssertTrue(output.text.contains("```\ncode\n```"))
        XCTAssertTrue(output.text.hasSuffix("# Next"))
        XCTAssertEqual(output.report.closedCodeBlocks, ["a.md"])
        XCTAssertNil(ManuscriptService.closingOpenFence("```\nx\n```"))
    }

    func testControllerProjectModeKeepsManifestOrderAndMarksMissingAndUnsupported() throws {
        try write("b.md", "B")
        try write("s.fountain", "INT. ROOM")
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: ["b.md", "gone.md", "s.fountain"])
        let controller = ManuscriptController(snapshots: { [] }, syntax: { MarkdownSyntaxOptions() }, onBuilt: { _ in })
        controller.attachProject(store)
        XCTAssertEqual(controller.items.map(\.id), ["b.md", "gone.md", "s.fountain"])
        XCTAssertEqual(controller.items.map(\.isOn), [true, false, false])
        XCTAssertTrue(controller.items[1].isMissing)
        XCTAssertTrue(controller.items[2].isUnsupported)
        controller.setAll(true)
        XCTAssertEqual(controller.selectedCount, 1)
    }

    func testRememberSelectionWritesIncludeOnlyWhenAsked() throws {
        try write("a.md", "A")
        try write("b.md", "B")
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: ["a.md", "b.md"])
        let controller = ManuscriptController(snapshots: { [] }, syntax: { MarkdownSyntaxOptions() }, onBuilt: { _ in })
        controller.attachProject(store)
        controller.setItem("b.md", on: false)
        XCTAssertEqual(store.project?.nodes.map(\.include), [true, true])
        controller.rememberSelection()
        XCTAssertEqual(store.project?.nodes.map(\.include), [true, false])
    }

    func testWordCounterCountsFilesAndCaches() async throws {
        try write("a.md", "one two three")
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: ["a.md"])
        let counter = ManuscriptWordCounter()
        counter.refresh(store: store, openDocuments: nil)
        for _ in 0..<100 where counter.isCounting { try await Task.sleep(for: .milliseconds(20)) }
        let id = try XCTUnwrap(store.project?.nodes.first?.id)
        XCTAssertEqual(counter.counts[id], 3)
        XCTAssertEqual(counter.bookTotal, 3)
    }
}
