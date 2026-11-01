import CryptoKit
import Foundation
import XCTest
@testable import LacEditor

final class FolderReplaceBackupTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var backupDirectory: URL!
    private var store: FolderReplaceBackupStore!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        backupDirectory = base.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FolderReplaceBackupStore(directory: backupDirectory)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private let request = FolderReplaceService.Request(query: "needle", replacement: "иголка", options: .init(), interpretsEscapes: false)

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @discardableResult
    private func write(_ text: String, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Заменяет «needle» во всех файлах папки с копией; результаты по относительным путям.
    @discardableResult
    private func replaceAll(request: FolderReplaceService.Request? = nil,
                            recorder: FolderReplaceBackupStore.Recorder? = nil) throws -> [String: FolderReplaceService.Outcome] {
        let recorder = recorder ?? store.makeRecorder(root: root)
        let matches = try FolderSearchService.search(root: root, query: "needle", caseSensitive: false, openDocuments: []).values
        var result: [String: FolderReplaceService.Outcome] = [:]
        for group in Dictionary(grouping: matches, by: { $0.file.url }).values {
            let first = try XCTUnwrap(group.first)
            guard case let .disk(expected) = first.source else { continue }
            result[first.file.relativePath] = try FolderReplaceService.replaceOnDisk(
                file: first.file, expected: expected, matches: group, request: request ?? self.request, root: root, backup: recorder)
        }
        return result
    }

    private func operationDirectory() throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).first)
    }

    func testRecordCreatesManifestOrigAndEntry() throws {
        let recorder = store.makeRecorder(root: root)
        try recorder.record(originalText: "abc", futureText: "abd", relativePath: "sub/Папка 你好.md")
        let operation = try operationDirectory()
        for name in ["manifest.json", "00001.orig", "00001.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: operation.appendingPathComponent(name).path), name)
        }
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.manifest.rootPath, root.standardizedFileURL.path)
        XCTAssertEqual(loaded.manifest.version, 1)
        XCTAssertEqual(loaded.entries, [.init(index: 1, relativePath: "sub/Папка 你好.md",
                                              originalSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                              futureSHA256: sha(Data("abd".utf8)), originalByteCount: 3)])
        XCTAssertEqual(try Data(contentsOf: operation.appendingPathComponent("00001.orig")), Data("abc".utf8))
        XCTAssertTrue(store.hasBackup)
    }

    func testRevertRestoresChangedFileExactBytes() throws {
        let original = "你好 needle\r\n😀 needle без перевода строки"
        let file = try write(original, "a.md")
        XCTAssertEqual(try replaceAll(), ["a.md": .replaced(2)])
        XCTAssertNotEqual(try Data(contentsOf: file), Data(original.utf8))
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(reverted: 1))
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
    }

    func testRevertLeavesFileModifiedAfterReplace() throws {
        let a = try write("needle a", "a.md")
        let b = try write("needle b", "b.md")
        try replaceAll()
        try Data("изменено снаружи, длиннее".utf8).write(to: b)
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(reverted: 1, conflicts: 1))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "needle a")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "изменено снаружи, длиннее")
        XCTAssertEqual(store.load()?.entries.map(\.relativePath), ["b.md"])
    }

    func testRevertSkipsWhenFileNeverWritten() throws {
        let file = try write("needle", "a.md")
        try store.makeRecorder(root: root).record(originalText: "needle", futureText: "иголка", relativePath: "a.md")
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(notApplied: 1))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle")
        XCTAssertNil(store.load())
    }

    func testRevertConflictWhenFileDeleted() throws {
        let file = try write("needle", "a.md")
        try replaceAll()
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(conflicts: 1))
        XCTAssertNotNil(store.load())
    }

    func testRevertConflictWhenNotExactUTF8() throws {
        let file = try write("needle", "a.md")
        try replaceAll()
        try (Data([0xEF, 0xBB, 0xBF]) + Data("иголка".utf8)).write(to: file)
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(conflicts: 1))
        XCTAssertEqual(try Data(contentsOf: file), Data([0xEF, 0xBB, 0xBF]) + Data("иголка".utf8))
    }

    func testRevertRefusesSymlink() throws {
        let file = try write("needle", "a.md")
        let target = try write("иголка", "target.txt")
        try replaceAll()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let result = store.revert(isOpen: { _ in false })
        XCTAssertEqual(result.reverted, 0)
        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "иголка")
    }

    func testRevertCallsOpenCheck() throws {
        let file = try write("needle", "a.md")
        try replaceAll()
        XCTAssertEqual(store.revert(isOpen: { $0.lastPathComponent == "a.md" }), .init(openInEditor: 1))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "иголка")
        XCTAssertNotNil(store.load())
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(reverted: 1))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle")
    }

    func testRevertFailsWhenOrigCorrupted() throws {
        let file = try write("needle", "a.md")
        try replaceAll()
        try Data("испорчено".utf8).write(to: try operationDirectory().appendingPathComponent("00001.orig"))
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(failed: 1))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "иголка")
    }

    func testRevertRemovesOperationDirectoryWhenAllDone() throws {
        try write("needle", "a.md")
        try replaceAll()
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(reverted: 1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil), [])
        XCTAssertNil(store.load())
    }

    func testNewRecorderKeepsOldBackupUntilFirstEntry() throws {
        try write("needle", "a.md")
        try replaceAll()
        let old = try XCTUnwrap(store.load())
        let recorder = store.makeRecorder(root: root)
        XCTAssertEqual(store.load(), old)
        try recorder.record(originalText: "x", futureText: "y", relativePath: "b.md")
        let fresh = try XCTUnwrap(store.load())
        XCTAssertNotEqual(fresh.manifest.operationID, old.manifest.operationID)
        XCTAssertEqual(fresh.entries.map(\.relativePath), ["b.md"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).count, 1)
    }

    func testLoadReturnsNilForMissingOrBrokenManifest() throws {
        XCTAssertNil(store.load())
        let operation = backupDirectory.appendingPathComponent("op", isDirectory: true)
        try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true)
        XCTAssertNil(store.load())
        try Data("не json".utf8).write(to: operation.appendingPathComponent("manifest.json"))
        XCTAssertNil(store.load())
        let manifest = #"{"version":99,"operationID":"op","createdAt":"2026-11-01T18:00:00Z","rootPath":"/tmp"}"#
        try Data(manifest.utf8).write(to: operation.appendingPathComponent("manifest.json"))
        let entry = #"{"index":1,"relativePath":"a.md","originalSHA256":"a","futureSHA256":"b","originalByteCount":1}"#
        try Data(entry.utf8).write(to: operation.appendingPathComponent("00001.json"))
        XCTAssertNil(store.load())
    }

    func testOrphanOrigWithoutEntryIsIgnored() throws {
        let recorder = store.makeRecorder(root: root)
        try recorder.record(originalText: "x", futureText: "y", relativePath: "a.md")
        let operation = try operationDirectory()
        try Data("сирота".utf8).write(to: operation.appendingPathComponent("00002.orig"))
        XCTAssertEqual(store.load()?.entries.map(\.index), [1])
    }

    func testBackupFailureBlocksWrite() throws {
        let file = try write("needle", "a.md")
        // Вместо каталога копий лежит файл: создать подкаталог операции нельзя.
        try Data().write(to: backupDirectory)
        XCTAssertEqual(try replaceAll(), ["a.md": .skipped(.writeFailed)])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle")
    }

    func testCancelMidReplaceKeepsBackupOfWrittenFiles() throws {
        let a = try write("needle a", "a.md")
        let b = try write("needle b", "b.md")
        let recorder = store.makeRecorder(root: root)
        let matches = try FolderSearchService.search(root: root, query: "needle", caseSensitive: false, openDocuments: []).values
        func replace(_ name: String, cancelled: Bool) throws -> FolderReplaceService.Outcome {
            let group = matches.filter { $0.file.relativePath == name }
            let first = try XCTUnwrap(group.first)
            guard case let .disk(expected) = first.source else { throw XCTSkip("not disk") }
            return try FolderReplaceService.replaceOnDisk(file: first.file, expected: expected, matches: group, request: request,
                                                          root: root, backup: recorder, isCancelled: { cancelled })
        }
        XCTAssertEqual(try replace("a.md", cancelled: false), .replaced(1))
        XCTAssertThrowsError(try replace("b.md", cancelled: true)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(store.load()?.entries.map(\.relativePath), ["a.md"])
        XCTAssertEqual(store.revert(isOpen: { _ in false }), .init(reverted: 1))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "needle a")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "needle b")
    }

    func testNoBackupWhenOutputEqualsText() throws {
        try write("needle", "a.md")
        let same = FolderReplaceService.Request(query: "needle", replacement: "needle", options: .init(), interpretsEscapes: false)
        XCTAssertEqual(try replaceAll(request: same), ["a.md": .replaced(1)])
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDirectory.path))
    }
}

@MainActor
final class FolderReplaceBackupControllerTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var store: FolderReplaceBackupStore!
    private var documents: [FolderSearchService.OpenDocument] = []
    private var previews: [FolderSearchController.RevertPreview] = []
    private var outcomes: [FolderSearchController.RevertOutcome] = []

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = FolderReplaceBackupStore(directory: base.appendingPathComponent("backup", isDirectory: true))
        documents = []
        previews = []
        outcomes = []
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeController(confirmReplace: @escaping (FolderSearchController.ReplaceSummary) -> Bool = { _ in true },
                                confirmRevert: @escaping (FolderSearchController.RevertPreview) -> Bool = { _ in true },
                                applyOpen: @escaping (FolderSearchController.OpenReplace) async -> FolderReplaceService.Outcome = { _ in .replaced(1) })
        -> FolderSearchController {
        FolderSearchController(snapshots: { [unowned self] in documents }, open: { _ in nil }, reveal: { _, _ in false }, openFile: { _ in },
                               confirmReplace: confirmReplace, applyOpen: applyOpen,
                               backupStore: store,
                               confirmRevert: { [unowned self] preview in previews.append(preview); return confirmRevert(preview) },
                               showRevertResult: { [unowned self] in outcomes.append($0) })
    }

    private func search(_ controller: FolderSearchController) async {
        controller.setRoot(root)
        controller.mode = .text
        controller.query = "needle"
        controller.isReplaceEnabled = true
        controller.replacement = "x"
        await controller.start()?.value
    }

    private func replaceAndWait(_ controller: FolderSearchController) async {
        await search(controller)
        await controller.replaceSelected()?.value
    }

    func testReplaceCreatesBackupAndRevertRestores() async throws {
        let file = try write("needle needle", "a.md")
        let controller = makeController()
        XCTAssertFalse(controller.hasReplaceBackup)
        await replaceAndWait(controller)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "x x")
        XCTAssertTrue(controller.hasReplaceBackup)
        await controller.revertLastReplace()?.value
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle needle")
        XCTAssertEqual(previews.map(\.fileCount), [1])
        XCTAssertEqual(outcomes, [.done(.init(reverted: 1))])
        XCTAssertFalse(controller.hasReplaceBackup)
        XCTAssertEqual(controller.replaceState, .idle)
    }

    func testRevertCancelledByUserDoesNothing() async throws {
        let file = try write("needle", "a.md")
        let controller = makeController(confirmRevert: { _ in false })
        await replaceAndWait(controller)
        XCTAssertNil(controller.revertLastReplace())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "x")
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(controller.replaceState, .idle)
        XCTAssertTrue(controller.hasReplaceBackup)
    }

    func testRevertWithoutBackupReportsNothing() async throws {
        let controller = makeController()
        controller.setRoot(root)
        XCTAssertNil(controller.revertLastReplace())
        XCTAssertEqual(outcomes, [.nothing])
        XCTAssertTrue(previews.isEmpty)
    }

    func testRevertRequiresSameRoot() async throws {
        let file = try write("needle", "a.md")
        let controller = makeController()
        await replaceAndWait(controller)
        let other = base.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        controller.setRoot(other)
        XCTAssertNil(controller.revertLastReplace())
        XCTAssertEqual(outcomes, [.otherFolder(root.standardizedFileURL.path)])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "x")
    }

    func testOpenDocumentDuringRevertIsNotTouched() async throws {
        let file = try write("needle", "a.md")
        let controller = makeController()
        await replaceAndWait(controller)
        documents = [FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "x"))]
        await controller.revertLastReplace()?.value
        XCTAssertEqual(outcomes, [.done(.init(openInEditor: 1))])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "x")
        documents = []
        await controller.revertLastReplace()?.value
        XCTAssertEqual(outcomes.last, .done(.init(reverted: 1)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "needle")
    }

    func testSecondOperationRejectedWhileBusy() async throws {
        let file = try write("needle", "a.md")
        let second = makeController(confirmReplace: { _ in false })
        await search(second)
        var rejected: [Bool] = []
        let first = makeController(confirmReplace: { _ in
            rejected.append(second.replaceSelected() == nil)
            rejected.append(second.revertLastReplace() == nil)
            return true
        })
        await replaceAndWait(first)
        XCTAssertEqual(rejected, [true, true])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "x")
        // После завершения первой вторая операция снова доступна (здесь пользователь отказывается в подтверждении).
        let task = second.replaceSelected()
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(second.replaceState, .idle)
    }

    func testOpenDocumentsAreNotBackedUp() async throws {
        let file = try write("needle", "a.md")
        documents = [FolderSearchService.OpenDocument(url: file, identity: DocumentFileIdentity.resolve(file),
            snapshot: DocumentTextSnapshot(documentID: UUID(), revision: 1, text: "needle"))]
        var applied = 0
        let controller = makeController(applyOpen: { _ in applied += 1; return .replaced(1) })
        await replaceAndWait(controller)
        XCTAssertEqual(applied, 1)
        XCTAssertNil(store.load())
        XCTAssertFalse(controller.hasReplaceBackup)
    }
}
