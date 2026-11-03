import Foundation
import XCTest
@testable import LacEditor

final class VaultStateStoreTests: XCTestCase {
    private var tmp: URL!
    private var root: URL { tmp.appendingPathComponent("vault", isDirectory: true) }
    private var store: VaultStateStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vault-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = VaultStateStore(vaultID: UUID(), root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func record(_ path: String, state: VaultNoteSyncState = .synced) -> VaultOpenNoteRecord {
        VaultOpenNoteRecord(serverPath: path, baseETag: String(repeating: "a", count: 64), state: state)
    }

    func testRootHasMetadataNeverIndex() throws {
        try store.save([:])
        let marker = root.appendingPathComponent(".metadata_never_index")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: marker).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.openDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.openStateDirectory.path))
    }

    func testWriteNoteAtomicallyAndReadBack() throws {
        let data = Data("текст".utf8)
        let url = try store.writeNote(data, serverPath: "daily/2026-11-03.md")
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(url.standardizedFileURL, store.noteURL(for: "daily/2026-11-03.md")?.standardizedFileURL)
        XCTAssertEqual(url.standardizedFileURL.path, store.openDirectory.appendingPathComponent("daily/2026-11-03.md").standardizedFileURL.path)
        XCTAssertEqual(names(store.openDirectory.appendingPathComponent("daily")), ["2026-11-03.md"])
        XCTAssertEqual(try store.readNote(serverPath: "daily/2026-11-03.md"), data)
    }

    func testBadPathsAreRejectedAndNothingWritten() throws {
        for bad in ["../x.md", "/abs.md", "a\\b.md", "a//b.md", ".hidden.md", "a/./b.md", "", "a\0b.md"] {
            XCTAssertThrowsError(try store.writeNote(Data("x".utf8), serverPath: bad), bad) {
                XCTAssertEqual($0 as? VaultStateStoreError, .invalidPath, bad)
            }
            XCTAssertThrowsError(try store.writeBase(Data("x".utf8), serverPath: bad))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSymlinkInsideOpenIsRejected() throws {
        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.openDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.openDirectory.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.writeNote(Data("x".utf8), serverPath: "linked/a.md")) {
            XCTAssertEqual($0 as? VaultStateStoreError, .unsafePath)
        }
        XCTAssertThrowsError(try store.removeNote(serverPath: "linked/a.md"))
        XCTAssertEqual(names(outside), [])

        // Ссылка вместо самой open/.
        let other = VaultStateStore(vaultID: UUID(), root: tmp.appendingPathComponent("vault2", isDirectory: true))
        try FileManager.default.createDirectory(at: other.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: other.openDirectory, withDestinationURL: outside)
        XCTAssertThrowsError(try other.writeNote(Data("x".utf8), serverPath: "a.md")) {
            XCTAssertEqual($0 as? VaultStateStoreError, .unsafePath)
        }
        XCTAssertEqual(names(outside), [])
    }

    func testBaseRoundTripAndName() throws {
        XCTAssertNil(try store.readBase(serverPath: "a.md"))
        try store.writeBase(Data("база".utf8), serverPath: "a.md")
        XCTAssertEqual(try store.readBase(serverPath: "a.md"), Data("база".utf8))
        XCTAssertEqual(names(store.openStateDirectory), [VaultClient.sha256Hex(Data("a.md".utf8)) + ".base"])
    }

    func testStateJSONRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_793_369_100)
        let full = VaultOpenNoteRecord(serverPath: "b.md", baseETag: String(repeating: "b", count: 64), baseModifiedNs: 5, baseSize: 7,
                                       state: .conflict, queuedSHA256: "abc", queuedAt: date, pendingConflictID: "c1", isOpenInTab: false)
        let plain = record("a.md", state: .modified)
        try store.save(["b.md": full, "a.md": plain])
        let text = try String(contentsOf: store.stateFileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertEqual(try store.load(), ["b.md": full, "a.md": plain])
        try store.save(["a.md": plain])
        XCTAssertEqual(try store.load(), ["a.md": plain])
        XCTAssertEqual(names(root).filter { $0.hasPrefix("state") }, ["state.json"])
    }

    func testLoadMissingIsEmpty() throws {
        XCTAssertEqual(try store.load(), [:])
    }

    func testDamagedStateIsQuarantined() throws {
        _ = try store.writeNote(Data("x".utf8), serverPath: "a.md")
        try Data("мусор".utf8).write(to: store.stateFileURL)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? VaultStateStoreError, .stateDamaged) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json.corrupt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stateFileURL.path))
        XCTAssertEqual(names(store.openDirectory), ["a.md"])
        try Data("снова".utf8).write(to: store.stateFileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json.corrupt-2").path))
    }

    func testNewerVersionIsReadOnly() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = """
        {"version":99,"notes":[{"serverPath":"a.md","baseETag":"e","state":"synced"}]}
        """
        try Data(json.utf8).write(to: store.stateFileURL)
        XCTAssertEqual(try store.load().keys.sorted(), ["a.md"])
        XCTAssertThrowsError(try store.save([:])) { XCTAssertEqual($0 as? VaultStateStoreError, .readOnly) }
        XCTAssertEqual(try String(contentsOf: store.stateFileURL, encoding: .utf8), json)
    }

    func testRemoveNoteDeletesFilesAndEmptyFolders() throws {
        _ = try store.writeNote(Data("x".utf8), serverPath: "daily/deep/a.md")
        try store.writeBase(Data("x".utf8), serverPath: "daily/deep/a.md")
        try store.removeNote(serverPath: "daily/deep/a.md")
        XCTAssertEqual(names(store.openDirectory), [])
        XCTAssertEqual(names(store.openStateDirectory), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.openDirectory.path))
        XCTAssertNoThrow(try store.removeNote(serverPath: "daily/deep/a.md"))
    }

    func testCleanupOrphansKeepsOnlyListed() throws {
        _ = try store.writeNote(Data("1".utf8), serverPath: "keep.md")
        _ = try store.writeNote(Data("2".utf8), serverPath: "dir/keep2.md")
        _ = try store.writeNote(Data("3".utf8), serverPath: "dir/orphan.md")
        _ = try store.writeNote(Data("4".utf8), serverPath: "only/orphan2.md")
        try store.writeBase(Data("1".utf8), serverPath: "keep.md")
        try store.writeBase(Data("o".utf8), serverPath: "orphan-base.md")
        try Data("t".utf8).write(to: store.openDirectory.appendingPathComponent(".a.md.tmp"))
        let outside = tmp.appendingPathComponent("outside")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.openDirectory.appendingPathComponent("link.md"), withDestinationURL: outside)
        try Data("{}".utf8).write(to: root.appendingPathComponent("requests.json"))

        let removed = try store.cleanupOrphans(keeping: ["keep.md", "dir/keep2.md"])
        XCTAssertEqual(Set(removed), ["dir/orphan.md", "only/orphan2.md"])
        XCTAssertEqual(names(store.openDirectory), ["dir", "keep.md"])
        XCTAssertEqual(names(store.openDirectory.appendingPathComponent("dir")), ["keep2.md"])
        XCTAssertEqual(names(store.openStateDirectory), [VaultClient.sha256Hex(Data("keep.md".utf8)) + ".base"])
        XCTAssertEqual(try Data(contentsOf: outside), Data("secret".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("requests.json").path))
    }

    func testCleanupWithEmptyKeepingRemovesAttachments() throws {
        _ = try store.writeNote(Data("1".utf8), serverPath: "a.md")
        let attachments = root.appendingPathComponent("open-attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try store.cleanupOrphans(keeping: ["a.md"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments.path))
        try store.cleanupOrphans(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.path))
    }

    func testServerPathFromLocalURL() throws {
        let url = try store.writeNote(Data("x".utf8), serverPath: "daily/ё.md")
        XCTAssertEqual(store.serverPath(forLocalURL: url), "daily/ё.md")
        XCTAssertNil(store.serverPath(forLocalURL: store.openDirectory))
        XCTAssertNil(store.serverPath(forLocalURL: root.appendingPathComponent("state.json")))
        XCTAssertNil(store.serverPath(forLocalURL: store.openDirectory.appendingPathComponent("../state.json")))
        XCTAssertNil(store.serverPath(forLocalURL: store.openDirectory.appendingPathComponent("daily/../../x.md")))
    }

    func testRemoveAll() throws {
        _ = try store.writeNote(Data("x".utf8), serverPath: "a.md")
        try store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNoThrow(try store.removeAll())
    }
}
