import XCTest
@testable import LacEditor

@MainActor
final class FileEncodingCommandTests: XCTestCase {
    private func makeState(_ document: EditorDocument) -> (AppState, UserDefaults, String) {
        let suiteName = "LacEditorEncodingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        return (state, defaults, suiteName)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func waitUntilIdle(_ document: EditorDocument) async throws {
        for _ in 0..<200 where document.ioState != .idle {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testEncodingChangeMakesDocumentDirtyUntilSaved() {
        let document = EditorDocument(text: "text")
        document.markSaved()
        XCTAssertFalse(document.isDirty)
        document.changeFileEncodingPendingSave(.isoLatin1)
        XCTAssertTrue(document.isDirty)
        document.changeFileEncodingPendingSave(.utf8)
        XCTAssertFalse(document.isDirty)
        document.changeFileEncodingPendingSave(.isoLatin1)
        let providerID = UUID()
        document.attachLiveTextProvider(id: providerID, provider: { nil }, acknowledgement: { _ in })
        document.detachLiveTextProvider(id: providerID)
        XCTAssertTrue(document.isDirty)
        document.markSaved()
        XCTAssertFalse(document.isDirty)
        document.refreshDirtyState()
        XCTAssertFalse(document.isDirty)
    }

    func testSaveEncodingCannotLoseCharactersAndKeepsFile() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("save.txt")
        try "中文".write(to: url, atomically: true, encoding: .utf8)
        let document = EditorDocument(text: "中文", url: url)
        let (state, defaults, suite) = makeState(document)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.applySaveEncoding(FileEncodingChoice(name: "Latin-1", encoding: .isoLatin1), to: document)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.fileEncoding, .isoLatin1)
        XCTAssertThrowsError(try FileService.write(document.text, to: url, encoding: document.fileEncoding, encodingName: "Latin-1"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "中文")

        let gb = FileService.gb18030Encoding
        state.applySaveEncoding(FileEncodingChoice(name: "GB", encoding: gb), to: document)
        try FileService.write(document.text, to: url, encoding: gb, encodingName: "GB")
        XCTAssertEqual(try String(contentsOf: url, encoding: gb), "中文")
    }

    func testReopenWithChosenEncoding() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("gb.txt")
        let gb = FileService.gb18030Encoding
        try XCTUnwrap("中文内容".data(using: gb)).write(to: url)
        let wrong = String(data: try Data(contentsOf: url), encoding: .isoLatin1) ?? ""
        let document = EditorDocument(text: wrong, url: url, fileEncoding: .isoLatin1)
        let (state, defaults, suite) = makeState(document)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.reopen(document, with: FileEncodingChoice(name: "GB", encoding: gb))
        XCTAssertEqual(document.ioState, .opening)
        try await waitUntilIdle(document)
        XCTAssertEqual(document.text, "中文内容")
        XCTAssertEqual(document.fileEncoding, gb)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.statusMessage, L10n.tr("已按%@重新打开", "GB"))
    }

    func testReopenFailureKeepsDocument() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bad.txt")
        try Data([0xff, 0xfe, 0xfd]).write(to: url)
        let document = EditorDocument(text: "local", url: url, isDirty: true)
        let (state, defaults, suite) = makeState(document)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.reopen(document, with: FileEncodingChoice(name: "UTF-8", encoding: .utf8))
        try await waitUntilIdle(document)
        XCTAssertEqual(document.text, "local")
        XCTAssertTrue(document.statusMessageIsError)
        XCTAssertEqual(document.fileEncoding, .utf8)
    }

    func testReopenKeepsEditsMadeWhileReading() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("race.txt")
        try "disk".write(to: url, atomically: true, encoding: .utf8)
        let document = EditorDocument(text: "disk", url: url)
        let (state, defaults, suite) = makeState(document)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.reopen(document, with: FileEncodingChoice(name: "UTF-8", encoding: .utf8))
        document.text = "edited"
        try await waitUntilIdle(document)
        XCTAssertEqual(document.text, "edited")
        XCTAssertEqual(document.statusMessage, L10n.tr("重新载入期间内容已变化，已保留本地修改"))
    }

    func testEncodingChoicesStartWithUTF8() {
        XCTAssertEqual(FileService.encodingChoices.first?.encoding, .utf8)
        XCTAssertEqual(FileService.encodingChoices.dropFirst().map(\.encoding), FileService.selectableEncodings.map(\.encoding))
    }

    func testLocalizedKeysExistInAllCatalogs() throws {
        let keys = ["换行符", "换行符：%@", "混合", "转换为 %@", "转换换行符", "以编码保存…", "以编码重新打开…",
                    "已按%@重新打开", "要丢弃未保存的修改并重新打开吗？"]
        for language in ["zh-Hans", "en", "ru"] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys { XCTAssertNotNil(table[key], "\(language): \(key)") }
        }
    }
}
