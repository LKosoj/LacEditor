import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class WriterModeTests: XCTestCase {
    private struct Fixture {
        let manager: WindowManager
        let state: AppState
        let window: NSWindow
        let defaults: UserDefaults
        let suite: String
    }

    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url.resolvingSymlinksInPath()
    }

    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let suite = "LacEditorTests.WriterMode.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = WindowManager(preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults))
        let state = AppState(recentFiles: manager.recentFiles, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let id = UUID()
        manager.preparePrimaryWindow(windowID: id, state: state)
        manager.register(windowID: id, state: state, window: window)
        return Fixture(manager: manager, state: state, window: window, defaults: defaults, suite: suite)
    }

    @discardableResult
    private func makeProject(root: URL, id: UUID = UUID(), title: String = "Book", files: [String] = []) throws -> UUID {
        let directory = root.appendingPathComponent(".laceditor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nodes = files.map { #"{"id":"\#(UUID().uuidString)","kind":"text","title":"\#($0)","path":"\#($0)"}"# }.joined(separator: ",")
        let json = #"{"version":1,"projectID":"\#(id.uuidString)","title":"\#(title)","statuses":[],"nodes":[\#(nodes)]}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("project.json"))
        return id
    }

    func testProjectWithManifestAttachesTabAndSharesSession() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try makeProject(root: root)
        fixture.state.startWriterProject(at: root)
        let session = try XCTUnwrap(fixture.state.writerSession)
        XCTAssertEqual(session.rootURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(fixture.manager.writerSessions.count, 1)
        // Вторая вкладка того же корня получает ту же сессию.
        let second = AppState(recentFiles: fixture.manager.recentFiles, preferences: fixture.manager.preferences)
        let probe = ManuscriptProjectStore.probe(root: root)
        let same = try XCTUnwrap(fixture.manager.writerSession(for: root, probe: probe))
        XCTAssertTrue(same === session)
        fixture.manager.attachWriter(same, to: second)
        XCTAssertEqual(session.attachedStateCount, 2)
    }

    func testFolderWithoutManifestHasNoSession() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        XCTAssertNil(fixture.manager.writerSession(for: root, probe: ManuscriptProjectStore.probe(root: root)))
        XCTAssertNil(fixture.state.writerSession)
    }

    func testExitWriterModeKeepsFolderAndDropsEmptySession() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try makeProject(root: root)
        fixture.state.startWriterProject(at: root)
        XCTAssertNotNil(fixture.state.writerSession)
        fixture.state.exitWriterMode()
        XCTAssertNil(fixture.state.writerSession)
        XCTAssertTrue(fixture.manager.writerSessions.isEmpty)
        XCTAssertNotNil(fixture.state.folderWorkspace.rootURL)
    }

    func testCloseProjectDetachesAllTabs() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try makeProject(root: root)
        fixture.state.startWriterProject(at: root)
        let session = try XCTUnwrap(fixture.state.writerSession)
        fixture.state.closeWriterProject()
        XCTAssertNil(fixture.state.writerSession)
        XCTAssertTrue(fixture.manager.states(of: session).isEmpty)
        XCTAssertTrue(fixture.manager.writerSessions.isEmpty)
    }

    func testRestoreWithSameProjectIDAttaches() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        let id = try makeProject(root: root)
        fixture.manager.restoreWriterProject(WriterProjectSession(rootPath: root.path, projectID: id), in: fixture.state)
        XCTAssertNotNil(fixture.state.writerSession)
        XCTAssertNil(fixture.state.writerProjectIssue)
    }

    func testRestoreWithMissingOrForeignProjectShowsBannerAndKeepsRecord() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try makeProject(root: root)
        let record = WriterProjectSession(rootPath: root.path, projectID: UUID())
        fixture.manager.restoreWriterProject(record, in: fixture.state)
        XCTAssertNil(fixture.state.writerSession)
        XCTAssertEqual(fixture.state.pendingWriterProject, record)
        XCTAssertNotNil(fixture.state.writerProjectIssue)
        // «Продолжить как обычную вкладку» снимает плашку и запись.
        fixture.state.resolveMissingWriterProject(choosingFolder: false)
        XCTAssertNil(fixture.state.writerProjectIssue)
        XCTAssertNil(fixture.state.pendingWriterProject)
    }

    func testInheritanceFollowsProjectRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try makeProject(root: root)
        fixture.state.startWriterProject(at: root)
        let session = try XCTUnwrap(fixture.state.writerSession)
        let inside = root.appendingPathComponent("a.md")
        let outside = try makeFolder().appendingPathComponent("b.md")
        XCTAssertTrue(fixture.manager.inheritedWriterSession(from: fixture.state, openingFileAt: inside) === session)
        XCTAssertTrue(fixture.manager.inheritedWriterSession(from: fixture.state, openingFileAt: nil) === session)
        XCTAssertNil(fixture.manager.inheritedWriterSession(from: fixture.state, openingFileAt: outside))
    }

    func testCreateSceneAndGroupAddNodesWithoutTouchingOtherFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try "keep".write(to: root.appendingPathComponent("old.md"), atomically: true, encoding: .utf8)
        try makeProject(root: root, files: ["old.md"])
        fixture.state.startWriterProject(at: root)
        let session = try XCTUnwrap(fixture.state.writerSession)
        let group = try XCTUnwrap(fixture.state.createGroup(parent: nil, after: nil))
        XCTAssertEqual(session.projectStore.project?.node(id: group)?.kind, .group)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("old.md")), "keep")
        fixture.state.toggleManuscriptInclude(group)
        XCTAssertEqual(session.projectStore.project?.node(id: group)?.include, false)
    }

    func testSessionRecordRoundTripAndLenientDecoding() throws {
        let record = WriterProjectSession(rootPath: "/tmp/x", projectID: UUID())
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(WriterProjectSession.self, from: data), record)
        let broken = try JSONDecoder().decode(WriterProjectSession.self, from: Data(#"{"rootPath":5}"#.utf8))
        XCTAssertFalse(broken.isValid)
    }

    // MARK: Сессия, вступление файла, окна, подсчёт слов

    func testWorkspaceSessionStoreRoundTripsWriterProject() throws {
        let folder = try makeFolder()
        let store = WorkspaceSessionStore(rootURL: folder.appendingPathComponent("workspace", isDirectory: true))
        let id = UUID()
        let record = WriterProjectSession(rootPath: folder.path, projectID: UUID())
        func snapshot(_ project: WriterProjectSession?) -> WorkspaceSessionSnapshot {
            let document = WorkspaceDocumentSnapshot(documentID: id, text: "t", sourceURL: nil, language: .markdown,
                encoding: .utf8, isDirty: true, selectionRange: NSRange(location: 0, length: 0), scrollPositionRatio: 0,
                isPreviewVisible: false, fileRevisionSnapshot: nil, writerProject: project)
            return WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(documents: [document], selectedDocumentID: id,
                                                                             isSidebarVisible: true, frame: nil)])
        }
        try store.saveForTesting(snapshot(record))
        XCTAssertEqual(try store.load()?.windows.first?.documents.first?.writerProject, record)
        // Прежний формат (без поля) читается как обычная вкладка.
        try store.saveForTesting(snapshot(nil))
        XCTAssertNil(try store.load()?.windows.first?.documents.first?.writerProject)
        // Испорченное поле отбрасывается через isValid, не ломая остальное.
        let broken = try JSONDecoder().decode(WriterProjectSession.self, from: Data(#"{"projectID":"x"}"#.utf8))
        XCTAssertFalse(broken.isValid)
    }

    func testOpeningAlreadyOpenProjectFileJoinsOrdinaryTabToProject() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try makeProject(root: root)
        let file = root.appendingPathComponent("a.md")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        fixture.state.beginOpeningFile(file)
        for _ in 0..<200 where fixture.state.selectedDocument?.ioState != .idle { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(fixture.state.writerSession)
        let writerTab = AppState(recentFiles: fixture.manager.recentFiles, preferences: fixture.manager.preferences)
        let session = try XCTUnwrap(fixture.manager.writerSession(for: root, probe: ManuscriptProjectStore.probe(root: root)))
        fixture.manager.attachWriter(session, to: writerTab)
        let match = fixture.manager.openFile(file, preferredState: writerTab, inheritsWriter: true)
        XCTAssertTrue(match?.state === fixture.state)
        XCTAssertTrue(fixture.state.writerSession === session)
    }

    func testLastProjectTabClosingReleasesSession() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let root = try makeFolder()
        try makeProject(root: root)
        fixture.state.startWriterProject(at: root)
        let session = try XCTUnwrap(fixture.state.writerSession)
        let other = AppState(recentFiles: fixture.manager.recentFiles, preferences: fixture.manager.preferences)
        fixture.manager.attachWriter(session, to: other)
        fixture.manager.detachWriter(from: fixture.state)
        XCTAssertFalse(fixture.manager.writerSessions.isEmpty, "вторая вкладка держит сессию")
        fixture.manager.detachWriter(from: other)
        XCTAssertTrue(fixture.manager.writerSessions.isEmpty)
        XCTAssertEqual(session.attachedStateCount, 0)
    }

    func testWordCounterCountsChineseAndRussian() async throws {
        let root = try makeFolder()
        try "我爱你们".write(to: root.appendingPathComponent("zh.md"), atomically: true, encoding: .utf8)
        try "один два три".write(to: root.appendingPathComponent("ru.md"), atomically: true, encoding: .utf8)
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: ["zh.md", "ru.md"])
        let counter = ManuscriptWordCounter()
        counter.refresh(store: store, openDocuments: nil)
        for _ in 0..<100 where counter.isCounting { try await Task.sleep(for: .milliseconds(20)) }
        let ids = try XCTUnwrap(store.project?.nodes.map(\.id))
        XCTAssertEqual(counter.counts[ids[0]], 4, "каждый иероглиф считается словом")
        XCTAssertEqual(counter.counts[ids[1]], 3)
        XCTAssertEqual(counter.bookTotal, 7)
    }

    func testStatusKeepsUnknownKeysAndRememberSelectionKeepsGroupChildren() throws {
        let json = #"{"title":"Done","color":"green","icon":"star"}"#
        let status = try JSONDecoder().decode(ManuscriptStatus.self, from: Data(json.utf8))
        let again = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertTrue(again.contains("\"icon\""))

        let root = try makeFolder()
        try "a".write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let store = ManuscriptProjectStore(rootURL: root)
        try store.createProject(title: "T", language: nil, files: [])
        let scene = ManuscriptNode(kind: .text, title: "A", path: "a.md")
        let group = ManuscriptNode(kind: .group, title: "G", include: false, children: [scene])
        try store.insertNode(group, parent: nil, index: 0)
        let controller = ManuscriptController(snapshots: { [] }, syntax: { MarkdownSyntaxOptions() }, onBuilt: { _ in })
        controller.attachProject(store)
        controller.rememberSelection()
        XCTAssertEqual(store.project?.node(id: scene.id)?.include, true)
    }
}
