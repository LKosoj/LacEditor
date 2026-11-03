import XCTest
@testable import LacEditor

final class VaultNoteInfoTests: XCTestCase {
    private let states: [VaultNoteSyncState] = [.synced, .modified, .uploading, .newerOnServer, .conflict, .deletedOnServer, .loading]

    func testEveryStateHasWordAndSymbolAndTitlesDiffer() {
        let titles = states.map { VaultNoteStateDescription.title($0) }
        XCTAssertEqual(Set(titles).count, states.count)
        for state in states {
            XCTAssertFalse(VaultNoteStateDescription.title(state).isEmpty)
            XCTAssertFalse(VaultNoteStateDescription.symbol(state).isEmpty)
        }
    }

    func testOfflineAddsNoConnectionToSpokenText() {
        for state in states {
            let online = VaultNoteStateDescription.spoken(state, isOnline: true)
            let offline = VaultNoteStateDescription.spoken(state, isOnline: false)
            XCTAssertEqual(online, VaultNoteStateDescription.title(state))
            XCTAssertTrue(offline.hasPrefix(online))
            XCTAssertGreaterThan(offline.count, online.count)
        }
    }

    func testTones() {
        XCTAssertEqual(VaultNoteStateDescription.tone(.synced), .neutral)
        XCTAssertEqual(VaultNoteStateDescription.tone(.conflict), .warning)
        XCTAssertEqual(VaultNoteStateDescription.tone(.deletedOnServer), .danger)
    }

    func testMemoryKeepsOneEntryPerPath() {
        let memory = VaultServerUpdateMemory()
        let date = Date(timeIntervalSince1970: 100)
        memory.record(path: "a.md", previousText: "один", date: date)
        memory.record(path: "a.md", previousText: "два", date: date.addingTimeInterval(5))
        memory.record(path: "b.md", previousText: "три")
        XCTAssertEqual(memory.entry(for: "a.md"), .init(previousText: "два", date: date.addingTimeInterval(5)))
        XCTAssertEqual(memory.entry(for: "b.md")?.previousText, "три")
        memory.remove(path: "a.md")
        XCTAssertNil(memory.entry(for: "a.md"))
        memory.clear()
        XCTAssertNil(memory.entry(for: "b.md"))
    }

    func testMemoryDoesNotKeepHugeText() {
        let memory = VaultServerUpdateMemory()
        memory.record(path: "a.md", previousText: "старый")
        memory.record(path: "a.md", previousText: String(repeating: "я", count: VaultServerUpdateMemory.limit))
        XCTAssertNil(memory.entry(for: "a.md"))
        memory.record(path: "b.md", previousText: String(repeating: "x", count: VaultServerUpdateMemory.limit))
        XCTAssertNotNil(memory.entry(for: "b.md"))
    }
}
