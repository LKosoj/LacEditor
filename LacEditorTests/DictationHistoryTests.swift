import XCTest
@preconcurrency @testable import LacEditor

@MainActor
final class DictationHistoryTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_793_369_100)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url.standardizedFileURL
    }

    private func storeURL() throws -> URL {
        try temporaryDirectory().appendingPathComponent("DictationHistory.json")
    }

    private func makeStore(_ url: URL, _ clock: Clock) -> DictationHistoryStore {
        DictationHistoryStore(storageURL: url, now: { clock.now })
    }

    @discardableResult
    private func add(_ store: DictationHistoryStore, _ text: String, cleaned: String? = nil) throws -> DictationHistoryEntry {
        try store.add(rawText: text, cleanedText: cleaned, documentName: "a.md", transcriptionModel: "audio",
                      cleanupModel: cleaned == nil ? nil : "text")
    }

    func testAddStoresNewestFirstAndPersists() throws {
        let url = try storeURL()
        let clock = Clock()
        let store = makeStore(url, clock)
        try add(store, "первая")
        clock.now += 60
        try add(store, "вторая")
        XCTAssertEqual(store.entries.map(\.rawText), ["вторая", "первая"])
        XCTAssertEqual(makeStore(url, clock).entries.map(\.rawText), ["вторая", "первая"])
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\" : 1"))
    }

    func testLimitKeepsLast20() throws {
        let url = try storeURL()
        let clock = Clock()
        let store = makeStore(url, clock)
        for index in 1...25 {
            try add(store, "запись \(index)")
            clock.now += 60
        }
        XCTAssertEqual(store.entries.count, 20)
        XCTAssertEqual(store.entries.first?.rawText, "запись 25")
        XCTAssertEqual(store.entries.last?.rawText, "запись 6")
        let reloaded = makeStore(url, clock)
        XCTAssertEqual(reloaded.entries.count, 20)
        XCTAssertEqual(reloaded.entries.last?.rawText, "запись 6")
    }

    func testRetentionDropsOlderThan14Days() throws {
        let url = try storeURL()
        let clock = Clock()
        let store = makeStore(url, clock)
        try add(store, "старая")
        clock.now += DictationHistoryStore.defaultRetention - 1
        XCTAssertEqual(store.recent().map(\.rawText), ["старая"])
        clock.now += 2
        XCTAssertTrue(store.recent().isEmpty)
        try add(store, "новая")
        XCTAssertEqual(store.entries.map(\.rawText), ["новая"])
        XCTAssertEqual(makeStore(url, clock).entries.map(\.rawText), ["новая"])
    }

    func testLoadDropsExpiredAndRewritesFile() throws {
        let url = try storeURL()
        let clock = Clock()
        let store = makeStore(url, clock)
        try add(store, "старая")
        clock.now += DictationHistoryStore.defaultRetention + 10
        let reloaded = makeStore(url, clock)
        XCTAssertTrue(reloaded.entries.isEmpty)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("старая"))
    }

    func testClearRemovesEverything() throws {
        let url = try storeURL()
        let clock = Clock()
        let store = makeStore(url, clock)
        try add(store, "раз")
        try add(store, "два")
        try store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(makeStore(url, clock).entries.isEmpty)
    }

    func testEmptyTextIsRejected() throws {
        let url = try storeURL()
        let store = makeStore(url, Clock())
        XCTAssertThrowsError(try add(store, "  \n")) { error in
            XCTAssertEqual(error as? DictationHistoryStore.StoreError, .emptyText)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptFileMovedAside() throws {
        let url = try storeURL()
        let clock = Clock()
        try Data("{broken".utf8).write(to: url)
        let store = makeStore(url, clock)
        XCTAssertEqual(store.issue, .corrupt(backupName: "DictationHistory.json.corrupt"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isReadOnly)
        try add(store, "после повреждения")
        XCTAssertEqual(makeStore(url, clock).entries.count, 1)
        try FileManager.default.removeItem(at: url)
        try Data("{again".utf8).write(to: url)
        XCTAssertEqual(makeStore(url, clock).issue, .corrupt(backupName: "DictationHistory.json.corrupt-2"))
    }

    func testNewerVersionIsReadOnly() throws {
        let url = try storeURL()
        let bytes = Data(#"{"version":2,"entries":[]}"#.utf8)
        try bytes.write(to: url)
        let store = makeStore(url, Clock())
        XCTAssertEqual(store.issue, .unavailable)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertThrowsError(try add(store, "текст")) { error in
            XCTAssertEqual(error as? DictationHistoryStore.StoreError, .readOnly)
        }
        XCTAssertThrowsError(try store.clear()) { error in
            XCTAssertEqual(error as? DictationHistoryStore.StoreError, .readOnly)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testNewerVersionWithDifferentSchemaIsNotMovedAside() throws {
        let url = try storeURL()
        let bytes = Data(#"{"version":2,"items":[{"text":"x"}]}"#.utf8)
        try bytes.write(to: url)
        let store = makeStore(url, Clock())
        XCTAssertEqual(store.issue, .unavailable)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }

    func testWriteFailureKeepsMemory() throws {
        try XCTSkipIf(geteuid() == 0, "Права каталога не действуют для root")
        let url = try storeURL()
        let store = makeStore(url, Clock())
        let kept = try add(store, "сохранённая")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path)
        XCTAssertThrowsError(try add(store, "не запишется"))
        XCTAssertEqual(store.entries, [kept])
    }

    func testRoundTripUnicodeAndOptionalFields() throws {
        let url = try storeURL()
        let clock = Clock()
        let store = makeStore(url, clock)
        let first = try add(store, "你好 😀 мир")
        clock.now += 60
        let second = try add(store, "raw", cleaned: "Raw.")
        let reloaded = makeStore(url, clock).entries
        XCTAssertEqual(reloaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.last?.rawText, "你好 😀 мир")
        XCTAssertNil(reloaded.last?.cleanedText)
        XCTAssertNil(reloaded.last?.cleanupModel)
        XCTAssertEqual(reloaded.first?.cleanedText, "Raw.")
        XCTAssertEqual(reloaded.first?.cleanupModel, "text")
        XCTAssertEqual(reloaded.first?.transcriptionModel, "audio")
        XCTAssertEqual(reloaded.first?.documentName, "a.md")
    }

    func testDefaultStorageURLUsesEnvironmentDirectory() {
        let url = DictationHistoryStore.defaultStorageURL()
        XCTAssertEqual(url.lastPathComponent, "DictationHistory.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, AppEnvironment.dataDirectoryName)
    }

    func testDictationHistoryTextsExistInAllCatalogs() throws {
        let keys = ["最近的听写", "暂无听写", "插入整理后的文字", "插入原始识别文字", "无法插入听写文字", "保存听写历史",
                    "在本机保存最近 20 条听写，最长 14 天；不保存录音。关闭后已保存的记录不会自动删除。", "清除听写历史", "清除",
                    "听写历史已清除", "无法使用听写历史文件，修改将不会保存。", "听写历史文件已损坏，已另存为 %@，当前列表为空。",
                    "听写历史不能保存空文字。"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(text.components(separatedBy: "\n\"\(key)\" =").count - 1, 1, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, "\(language): \(key)")
            }
        }
    }
}
