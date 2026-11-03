import Foundation
import XCTest
@testable import LacEditor

final class VaultCaptureDraftStoreTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-draft-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var store: VaultCaptureDraftStore { VaultCaptureDraftStore(fileURL: directory.appendingPathComponent("VaultCaptureDraft.txt")) }

    func testMissingFileReadsEmpty() {
        XCTAssertEqual(store.load(), "")
    }

    func testSaveAndLoadKeepsTextAsIs() throws {
        try store.save("  мысль\nвторая строка  ")
        XCTAssertEqual(store.load(), "  мысль\nвторая строка  ")
        try store.save("новая")
        XCTAssertEqual(store.load(), "новая")
    }

    func testBlankTextRemovesFile() throws {
        try store.save("текст")
        try store.save(" \n\t")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.load(), "")
    }

    func testPermissionsAreOwnerOnly() throws {
        try store.save("секрет")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testClear() throws {
        try store.save("текст")
        store.clear()
        XCTAssertEqual(store.load(), "")
    }

    func testMergedReturnsTextWithoutDuplicates() {
        XCTAssertEqual(VaultCaptureDraftStore.merged("  \n", returning: "мысль"), "мысль")
        XCTAssertEqual(VaultCaptureDraftStore.merged("черновик", returning: "мысль"), "черновик\n\nмысль")
        XCTAssertEqual(VaultCaptureDraftStore.merged("до\n\nмысль", returning: "мысль"), "до\n\nмысль")
    }
}
