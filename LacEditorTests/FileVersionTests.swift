import XCTest
@testable import LacEditor

final class FileVersionServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadDiskTextUsesDocumentEncoding() throws {
        let url = directory.appendingPathComponent("a.txt")
        try "你好".write(to: url, atomically: true, encoding: .utf16)
        XCTAssertEqual(try FileVersionService.loadDiskText(at: url, encoding: .utf16, encodingName: "UTF-16"), "你好")
    }

    func testUndecodableBytesDoNotGuessEncoding() throws {
        let url = directory.appendingPathComponent("b.txt")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        XCTAssertThrowsError(try FileVersionService.loadDiskText(at: url, encoding: .utf8, encodingName: "UTF-8")) {
            guard case FileServiceError.unsupportedEncoding = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMissingDiskFileThrows() {
        XCTAssertThrowsError(try FileVersionService.loadDiskText(
            at: directory.appendingPathComponent("none.txt"), encoding: .utf8, encodingName: "UTF-8"))
    }

    func testLoadTextReadsVersionContent() throws {
        let url = directory.appendingPathComponent("v.txt")
        try "v1".write(to: url, atomically: true, encoding: .utf8)
        let info = FileVersionInfo(id: "1", date: nil, computerName: nil, contentURL: url)
        XCTAssertEqual(try FileVersionService.loadText(info, encoding: .utf8, encodingName: "UTF-8"), "v1")
    }

    func testRecordedVersionKeepsFileRevisionSnapshot() throws {
        let url = directory.appendingPathComponent("r.txt")
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let before = try FileRevisionSnapshot.capture(url)
        if let error = FileVersionService.recordVersion(of: url) {
            throw XCTSkip("Том не поддерживает хранилище версий: \(error)")
        }
        XCTAssertEqual(try FileRevisionSnapshot.capture(url), before)
    }
}

@MainActor
final class VersionHistoryControllerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/version-history-test.txt")

    private func makeController(
        document: EditorDocument,
        mode: VersionHistoryController.Mode = .history,
        apply: @escaping (String, DocumentTextSnapshot) -> String? = { _, _ in nil },
        text: @escaping @Sendable (FileVersionInfo, String.Encoding, String) async throws -> String = { info, _, _ in info.id }
    ) -> VersionHistoryController {
        VersionHistoryController(
            document: document, url: url, mode: mode, apply: apply,
            fetchVersions: { _ in [
                FileVersionInfo(id: "old", date: nil, computerName: nil, contentURL: URL(fileURLWithPath: "/x")),
                FileVersionInfo(id: "older", date: nil, computerName: nil, contentURL: URL(fileURLWithPath: "/y"))
            ] },
            fetchText: text,
            fetchDisk: { _, _, _ in "disk\n" }
        )
    }

    private func settle(_ controller: VersionHistoryController) async {
        for _ in 0..<200 where controller.isLoading { try? await Task.sleep(nanoseconds: 5_000_000) }
        await Task.yield()
    }

    func testSelectionShowsChangesAndEnablesRestore() async {
        let document = EditorDocument(text: "current\n", url: url)
        let controller = makeController(document: document)
        controller.start()
        await settle(controller)
        controller.select("old")
        await settle(controller)
        XCTAssertTrue(controller.hasResult)
        XCTAssertEqual(controller.changes.map(\.kind), [.removed, .added])
        XCTAssertTrue(controller.canRestore)
    }

    func testOnlyLastSelectionIsApplied() async {
        let document = EditorDocument(text: "current\n", url: url)
        let controller = makeController(document: document, text: { info, _, _ in
            if info.id == "old" { try await Task.sleep(nanoseconds: 100_000_000) }
            return info.id + "\n"
        })
        controller.start()
        await settle(controller)
        controller.select("old")
        controller.select("older")
        await settle(controller)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.changes.first?.text, "older\n")
    }

    func testChangedDocumentMakesResultStaleAndBlocksRestore() async {
        let document = EditorDocument(text: "current\n", url: url)
        var applied = false
        let controller = makeController(document: document, apply: { _, _ in applied = true; return nil })
        controller.start()
        await settle(controller)
        controller.select("old")
        await settle(controller)
        document.text = "edited\n"
        controller.restore()
        XCTAssertFalse(controller.canRestore)
        XCTAssertTrue(controller.isStale)
        XCTAssertFalse(applied)
    }

    func testDiskModeComparesWithoutRestore() async {
        let document = EditorDocument(text: "current\n", url: url)
        let controller = makeController(document: document, mode: .disk)
        controller.start()
        await settle(controller)
        XCTAssertEqual(controller.changes.count, 2)
        XCTAssertFalse(controller.canRestore)
    }

    func testRestoreFailureShowsMessageAndKeepsSheetOpen() async {
        let document = EditorDocument(text: "current\n", url: url)
        let controller = makeController(document: document, apply: { _, _ in "failure" })
        var restored = false
        controller.onRestored = { restored = true }
        controller.start()
        await settle(controller)
        controller.select("old")
        await settle(controller)
        controller.restore()
        XCTAssertEqual(controller.message, "failure")
        XCTAssertFalse(restored)
    }

    // MARK: Снимки

    private final class SnapshotBox: @unchecked Sendable {
        let lock = NSLock()
        var infos: [DocumentSnapshotInfo]
        var texts: [UUID: String]
        init(_ infos: [DocumentSnapshotInfo], _ texts: [UUID: String]) { self.infos = infos; self.texts = texts }
    }

    private func snapshotInfo(_ name: String, _ seconds: TimeInterval) -> DocumentSnapshotInfo {
        DocumentSnapshotInfo(id: UUID(), name: name, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
                             byteCount: 1, sha256: "", encoding: "UTF-8")
    }

    private func makeSnapshotController(document: EditorDocument, box: SnapshotBox,
                                        apply: @escaping (String, DocumentTextSnapshot) -> String? = { _, _ in nil }) -> VersionHistoryController {
        VersionHistoryController(
            document: document, url: url, mode: .snapshots, apply: apply,
            fetchSnapshots: { box.lock.lock(); defer { box.lock.unlock() }; return box.infos.sorted { $0.date > $1.date } },
            fetchSnapshotText: { id in
                box.lock.lock(); defer { box.lock.unlock() }
                guard let text = box.texts[id] else { throw DocumentSnapshotError.notFound }
                return text
            },
            renameSnapshot: { id, name in
                box.lock.lock(); defer { box.lock.unlock() }
                guard let index = box.infos.firstIndex(where: { $0.id == id }) else { throw DocumentSnapshotError.notFound }
                box.infos[index].name = name
            },
            deleteSnapshot: { id in
                box.lock.lock(); defer { box.lock.unlock() }
                box.infos.removeAll { $0.id == id }
                box.texts[id] = nil
            }
        )
    }

    func testSnapshotsModeLoadsListAndRestoresText() async {
        let old = snapshotInfo("Черновик", 0), newer = snapshotInfo("Перед правкой", 10)
        let box = SnapshotBox([old, newer], [old.id: "old\n", newer.id: "newer\n"])
        let document = EditorDocument(text: "current\n", url: url)
        var restoredText: String?
        let controller = makeSnapshotController(document: document, box: box, apply: { text, _ in restoredText = text; return nil })
        controller.start()
        await settle(controller)
        XCTAssertEqual(controller.versions.map(\.title), ["Перед правкой", "Черновик"])
        controller.select(old.id.uuidString)
        await settle(controller)
        XCTAssertTrue(controller.hasResult)
        XCTAssertTrue(controller.canRestore)
        controller.restore()
        XCTAssertEqual(restoredText, "old\n")
    }

    func testSnapshotsModeLargeFileSkipsDiffButAllowsRestore() async {
        let info = snapshotInfo("Большой", 0)
        let box = SnapshotBox([info], [info.id: "other\n"])
        let document = EditorDocument(text: "current\n", url: url)
        document.performanceProfile = .large
        let controller = makeSnapshotController(document: document, box: box)
        controller.start()
        await settle(controller)
        controller.select(info.id.uuidString)
        await settle(controller)
        XCTAssertTrue(controller.isDiffSkipped)
        XCTAssertTrue(controller.changes.isEmpty)
        XCTAssertTrue(controller.canRestore)
        XCTAssertEqual(controller.message, L10n.tr("文本过大，无法比较"))
    }

    func testInitialSelectionSelectsSnapshot() async {
        let first = snapshotInfo("A", 0), second = snapshotInfo("B", 10)
        let box = SnapshotBox([first, second], [first.id: "a\n", second.id: "b\n"])
        let document = EditorDocument(text: "current\n", url: url)
        let controller = makeSnapshotController(document: document, box: box)
        controller.initialSelection = first.id
        controller.start()
        await settle(controller)
        await settle(controller)
        XCTAssertEqual(controller.selectedID, first.id.uuidString)
        XCTAssertTrue(controller.hasResult)
    }

    func testRenameDeleteSnapshotReloadsList() async {
        let first = snapshotInfo("A", 0), second = snapshotInfo("B", 10)
        let box = SnapshotBox([first, second], [first.id: "a\n", second.id: "b\n"])
        let controller = makeSnapshotController(document: EditorDocument(text: "current\n", url: url), box: box)
        controller.start()
        await settle(controller)
        controller.select(second.id.uuidString)
        await settle(controller)
        controller.renameSnapshot(id: second.id.uuidString, name: "Новое")
        await settle(controller)
        await settle(controller)
        XCTAssertEqual(controller.versions.first?.title, "Новое")
        controller.deleteSnapshot(id: second.id.uuidString)
        await settle(controller)
        await settle(controller)
        XCTAssertEqual(controller.versions.map(\.id), [first.id.uuidString])
        XCTAssertEqual(controller.selectedID, first.id.uuidString)
    }
}
