import XCTest
@testable import LacEditor

final class DocumentSnapshotStoreTests: XCTestCase {
    private var directory: URL!
    private var base: URL!
    private var store: DocumentSnapshotStore!
    private let file = DocumentSnapshotLocation.file(path: "/tmp/novel/chapter.md")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        base = directory.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DocumentSnapshotStore(baseDirectory: base)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func add(_ text: String, _ name: String, at seconds: TimeInterval, keep: Int = 0,
                     location: DocumentSnapshotLocation? = nil) throws -> DocumentSnapshotInfo {
        try store.add(text: text, name: name, encodingName: "UTF-8", location: location ?? file, keepLast: keep,
                      now: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }

    func testAddAndListReturnsNewestFirst() throws {
        _ = try add("one", "A", at: 0)
        _ = try add("two", "B", at: 10)
        let list = store.list(location: file)
        XCTAssertEqual(list.map(\.name), ["B", "A"])
        XCTAssertEqual(list.first?.byteCount, 3)
        XCTAssertEqual(list.first?.encoding, "UTF-8")
    }

    func testEmptyNameGetsDate() throws {
        let info = try add("x", "   ", at: 0)
        XCTAssertFalse(info.name.isEmpty)
    }

    func testTextRoundTripKeepsUnicodeAndNewlines() throws {
        let text = "Привет, мир 🌍\r\nвторая строка\r\n\n你好"
        let info = try add(text, "U", at: 0)
        XCTAssertEqual(try store.text(id: info.id, location: file), text)
    }

    func testSha256MismatchThrowsCorrupted() throws {
        let info = try add("original", "S", at: 0)
        let url = store.directory(for: file).appendingPathComponent("\(info.id.uuidString).txt")
        try Data("changed".utf8).write(to: url)
        XCTAssertThrowsError(try store.text(id: info.id, location: file)) {
            XCTAssertEqual($0 as? DocumentSnapshotError, .corrupted)
        }
    }

    func testMissingTextFileThrowsCorrupted() throws {
        let info = try add("original", "S", at: 0)
        try FileManager.default.removeItem(at: store.directory(for: file).appendingPathComponent("\(info.id.uuidString).txt"))
        XCTAssertThrowsError(try store.text(id: info.id, location: file)) {
            XCTAssertEqual($0 as? DocumentSnapshotError, .corrupted)
        }
    }

    func testRenameAndDelete() throws {
        let first = try add("a", "A", at: 0)
        let second = try add("b", "B", at: 5)
        try store.rename(id: first.id, to: "  Новое имя ", location: file)
        XCTAssertEqual(store.list(location: file).map(\.name), ["B", "Новое имя"])
        XCTAssertThrowsError(try store.rename(id: first.id, to: "   ", location: file))
        XCTAssertEqual(store.list(location: file).last?.name, "Новое имя")
        try store.delete(id: second.id, location: file)
        XCTAssertEqual(store.list(location: file).map(\.id), [first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: file).appendingPathComponent("\(second.id.uuidString).txt").path))
        XCTAssertThrowsError(try store.delete(id: second.id, location: file)) {
            XCTAssertEqual($0 as? DocumentSnapshotError, .notFound)
        }
    }

    func testKeepLastRemovesOldestAndKeepsNew() throws {
        var ids: [UUID] = []
        for index in 0..<5 { ids.append(try add("t\(index)", "N\(index)", at: Double(index), keep: 3).id) }
        let list = store.list(location: file)
        XCTAssertEqual(list.map(\.id), [ids[4], ids[3], ids[2]])
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: file).path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(files.count, 3)
    }

    func testZeroKeepLastKeepsEverything() throws {
        for index in 0..<5 { _ = try add("t", "N\(index)", at: Double(index), keep: 0) }
        XCTAssertEqual(store.list(location: file).count, 5)
    }

    func testNewSnapshotIsNeverRemovedByLimit() throws {
        _ = try add("new", "Newest", at: 100, keep: 1)
        // Новый снимок с более ранней датой всё равно остаётся.
        let older = try add("old", "Older", at: 0, keep: 1)
        XCTAssertTrue(store.list(location: file).contains { $0.id == older.id })
    }

    func testProjectLocationUsesNodeIDDirectoryInsideRoot() throws {
        let root = directory.appendingPathComponent("book")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let node = UUID()
        let location = DocumentSnapshotLocation.project(root: root, nodeID: node)
        let info = try add("scene", "S", at: 0, location: location)
        let expected = root.appendingPathComponent(".laceditor/snapshots/\(node.uuidString)")
        XCTAssertEqual(store.directory(for: location).standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.appendingPathComponent("index.json").path))
        XCTAssertEqual(try store.text(id: info.id, location: location), "scene")
    }

    func testFileLocationUsesHashedDirectoryInBase() throws {
        _ = try add("x", "X", at: 0)
        let directory = store.directory(for: file)
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path, base.standardizedFileURL.path)
        XCTAssertEqual(directory.lastPathComponent.count, 32)
        XCTAssertNotEqual(directory, store.directory(for: .file(path: "/tmp/novel/other.md")))
    }

    func testMoveFileMovesDirectory() throws {
        let info = try add("moved", "M", at: 0)
        try store.moveFile(fromPath: "/tmp/novel/chapter.md", toPath: "/tmp/novel/renamed.md")
        XCTAssertTrue(store.list(location: file).isEmpty)
        let target = DocumentSnapshotLocation.file(path: "/tmp/novel/renamed.md")
        XCTAssertEqual(try store.text(id: info.id, location: target), "moved")
    }

    func testMoveFileDoesNotOverwriteExistingTarget() throws {
        let source = try add("source", "S", at: 0)
        let target = DocumentSnapshotLocation.file(path: "/tmp/novel/renamed.md")
        let existing = try add("target", "T", at: 1, location: target)
        try store.moveFile(fromPath: "/tmp/novel/chapter.md", toPath: "/tmp/novel/renamed.md")
        XCTAssertEqual(store.list(location: target).map(\.id), [existing.id])
        XCTAssertEqual(store.list(location: file).map(\.id), [source.id])
    }

    func testMoveFileWithoutSnapshotsDoesNothing() throws {
        XCTAssertNoThrow(try store.moveFile(fromPath: "/tmp/a.md", toPath: "/tmp/b.md"))
    }

    func testCorruptIndexIsRenamedAndListEmpty() throws {
        _ = try add("x", "X", at: 0)
        let folder = store.directory(for: file)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("index.json"))
        XCTAssertTrue(store.list(location: file).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json.corrupt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path))
        // Новый снимок после повреждения создаёт чистый индекс; второе повреждение получает номер.
        _ = try add("y", "Y", at: 1)
        try Data("[]".utf8).write(to: folder.appendingPathComponent("index.json"))
        XCTAssertTrue(store.list(location: file).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json.corrupt-2").path))
    }

    func testNewerIndexVersionIsReadOnly() throws {
        let info = try add("x", "X", at: 0)
        let folder = store.directory(for: file)
        let index = folder.appendingPathComponent("index.json")
        var text = try String(contentsOf: index, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        try text.write(to: index, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.list(location: file).map(\.id), [info.id])
        XCTAssertThrowsError(try add("y", "Y", at: 5)) { XCTAssertEqual($0 as? DocumentSnapshotError, .readOnly) }
        XCTAssertThrowsError(try store.rename(id: info.id, to: "Z", location: file)) { XCTAssertEqual($0 as? DocumentSnapshotError, .readOnly) }
        XCTAssertThrowsError(try store.delete(id: info.id, location: file)) { XCTAssertEqual($0 as? DocumentSnapshotError, .readOnly) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json.corrupt").path))
    }

    func testDidChangeNotificationPosted() throws {
        let expectation = XCTNSNotificationExpectation(name: DocumentSnapshotStore.didChangeNotification)
        _ = try add("x", "X", at: 0)
        wait(for: [expectation], timeout: 2)
    }

    func testSymlinkedSnapshotsDirectoryOutsideRootIsRejected() throws {
        let root = directory.appendingPathComponent("book")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".laceditor"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".laceditor/snapshots"), withDestinationURL: outside)
        let location = DocumentSnapshotLocation.project(root: root, nodeID: UUID())
        XCTAssertThrowsError(try add("x", "X", at: 0, location: location)) {
            XCTAssertEqual($0 as? DocumentSnapshotError, .unsafePath)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testAddAfterCorruptIndexQuarantinesAndStartsClean() throws {
        _ = try add("x", "X", at: 0)
        let folder = store.directory(for: file)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("index.json"))
        let info = try add("y", "Y", at: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json.corrupt").path))
        XCTAssertEqual(store.list(location: file).map(\.id), [info.id])
    }
}
