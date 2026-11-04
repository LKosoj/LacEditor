import XCTest
@testable import LacEditor

@MainActor
final class TextCompareControllerTests: XCTestCase {
    private func source(_ id: String, unsaved: Bool = true, load: @escaping @Sendable () async throws -> String) -> TextCompareSource {
        TextCompareSource(id: id, name: id, isUnsaved: unsaved, load: load)
    }

    /// Контроллер держит документ слабой ссылкой, поэтому тест хранит его до конца.
    private var documents: [EditorDocument] = []

    private func retained(_ text: String) -> EditorDocument {
        let document = EditorDocument(text: text)
        documents.append(document)
        return document
    }

    private func text(_ id: String, _ value: String) -> TextCompareSource {
        source(id) { value }
    }

    private func settle(_ controller: TextCompareController) async {
        for _ in 0..<200 where controller.isLoading { try? await Task.sleep(nanoseconds: 5_000_000) }
        await Task.yield()
    }

    func testTwoUnsavedTextsShowChanges() async {
        let document = EditorDocument(text: "current\n")
        let controller = TextCompareController(document: document, candidates: [text("a", "old\n")])
        XCTAssertTrue(controller.currentIsUnsaved)
        controller.select("a")
        await settle(controller)
        XCTAssertTrue(controller.hasResult)
        XCTAssertEqual(controller.changes.map(\.kind), [.removed, .added])
    }

    func testIdenticalTextsGiveEmptyResult() async {
        let controller = TextCompareController(document: retained("same\n"), candidates: [text("a", "same\n")])
        controller.select("a")
        await settle(controller)
        XCTAssertTrue(controller.hasResult)
        XCTAssertTrue(controller.changes.isEmpty)
    }

    func testCRLFAgainstLFDiffersOnEveryLine() async {
        let controller = TextCompareController(document: retained("a\nb\n"), candidates: [text("a", "a\r\nb\r\n")])
        controller.select("a")
        await settle(controller)
        XCTAssertEqual(controller.changes.count, 4)
    }

    func testRepeatedLinesGiveMinimalChanges() async {
        let controller = TextCompareController(document: retained("a\nb\n"), candidates: [text("a", "a\na\nb\n")])
        controller.select("a")
        await settle(controller)
        XCTAssertEqual(controller.changes.map(\.kind), [.removed])
    }

    func testLateResultAfterCancelIsIgnored() async {
        let slow = source("slow") { try await Task.sleep(nanoseconds: 100_000_000); return "old\n" }
        let controller = TextCompareController(document: retained("current\n"), candidates: [slow])
        controller.select("slow")
        controller.cancel()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(controller.changes.isEmpty)
        XCTAssertFalse(controller.hasResult)
    }

    func testOnlyLastSelectionIsApplied() async {
        let slow = source("slow") { try await Task.sleep(nanoseconds: 100_000_000); return "slow\n" }
        let controller = TextCompareController(document: retained("current\n"), candidates: [slow, text("fast", "fast\n")])
        controller.select("slow")
        controller.select("fast")
        await settle(controller)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.source?.id, "fast")
        XCTAssertEqual(controller.changes.first?.text, "fast\n")
    }

    func testDocumentEditMakesResultStaleAndRefreshFixesIt() async {
        let document = EditorDocument(text: "current\n")
        let controller = TextCompareController(document: document, candidates: [text("a", "old\n")])
        controller.select("a")
        await settle(controller)
        document.text = "edited\n"
        NotificationCenter.default.post(name: EditorCommandNotification.documentContentDidChange, object: document.id)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(controller.isStale)
        XCTAssertEqual(controller.message, L10n.tr("文档已更改，比较结果已过期"))
        controller.refresh()
        await settle(controller)
        XCTAssertFalse(controller.isStale)
        XCTAssertTrue(controller.hasResult)
        XCTAssertEqual(controller.changes.last?.text, "edited\n")
    }

    func testRefreshReloadsSource() async {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let counted = source("a") { counter.value += 1; return "old\n" }
        let controller = TextCompareController(document: retained("current\n"), candidates: [counted])
        controller.select("a")
        await settle(controller)
        controller.refresh()
        await settle(controller)
        XCTAssertEqual(counter.value, 2)
    }

    func testLoadFailuresShowMessages() async {
        let cases: [(Error, String)] = [
            (TextCompareError.tooLarge, L10n.tr("文本过大，无法比较")),
            (TextCompareError.closed, L10n.tr("比较的文档已关闭")),
            (FileServiceError.unsupportedEncoding, L10n.tr("无法按文档编码解码该内容"))
        ]
        for (error, expected) in cases {
            let failing = source("a") { throw error }
            let controller = TextCompareController(document: retained("current\n"), candidates: [failing])
            controller.select("a")
            await settle(controller)
            XCTAssertEqual(controller.message, expected)
            XCTAssertEqual(controller.messageKind, .error)
            XCTAssertFalse(controller.hasResult)
        }
    }

    func testChooseFileUsesReturnedSourceAndNilKeepsState() async {
        var next: TextCompareSource? = text("file", "old\n")
        let controller = TextCompareController(document: retained("current\n"), candidates: [], chooseFile: { next })
        XCTAssertTrue(controller.canChooseFile)
        controller.chooseFileTapped()
        await settle(controller)
        XCTAssertEqual(controller.source?.id, "file")
        XCTAssertTrue(controller.hasResult)
        next = nil
        controller.chooseFileTapped()
        await settle(controller)
        XCTAssertEqual(controller.source?.id, "file")
        XCTAssertTrue(controller.hasResult)
    }

    func testInitialSourceStartsComparison() async {
        let controller = TextCompareController(document: retained("current\n"), candidates: [], initial: text("disk", "disk\n"))
        XCTAssertFalse(controller.canChooseFile)
        controller.start()
        await settle(controller)
        XCTAssertEqual(controller.source?.id, "disk")
        XCTAssertTrue(controller.hasResult)
    }

    func testDiffSummaryCountsAddedAndRemoved() {
        let changes = AITextComparison.changes(before: "a\nb\n", after: "a\nc\nd\n")
        XCTAssertEqual(textDiffSummary(changes), L10n.tr("新增 %lld 行，删除 %lld 行", 2, 1))
    }
}

final class TextCompareServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadFileTextReadsUTF8() throws {
        let url = directory.appendingPathComponent("a.txt")
        try "你好".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try TextCompareService.loadFileText(url, fallback: .utf16, fallbackName: "UTF-16"), "你好")
    }

    func testNonUTF8UsesFallbackEncoding() throws {
        let url = directory.appendingPathComponent("b.txt")
        try "你好".write(to: url, atomically: true, encoding: .utf16)
        XCTAssertEqual(try TextCompareService.loadFileText(url, fallback: .utf16, fallbackName: "UTF-16"), "你好")
    }

    func testUndecodableThrowsUnsupportedEncoding() throws {
        let url = directory.appendingPathComponent("c.txt")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        XCTAssertThrowsError(try TextCompareService.loadFileText(url, fallback: .utf8, fallbackName: "UTF-8")) {
            guard case FileServiceError.unsupportedEncoding = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try TextCompareService.loadFileText(
            directory.appendingPathComponent("none.txt"), fallback: .utf8, fallbackName: "UTF-8"))
    }

    func testFileOverThresholdIsRejectedWithoutReading() throws {
        let url = directory.appendingPathComponent("big.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DocumentPerformanceProfile.largeFileByteThreshold + 1))
        try handle.close()
        XCTAssertThrowsError(try TextCompareService.loadFileText(url, fallback: .utf8, fallbackName: "UTF-8")) {
            guard case TextCompareError.tooLarge = $0 else { return XCTFail("\($0)") }
        }
    }

    @MainActor
    func testRefusalForLargeProfileDocument() {
        XCTAssertNotNil(TextCompareService.refusal(for: EditorDocument(text: "x", performanceProfile: .large)))
        XCTAssertNil(TextCompareService.refusal(for: EditorDocument(text: "x")))
    }

    @MainActor
    func testDocumentSourceFailsAfterDocumentIsReleased() async {
        var document: EditorDocument? = EditorDocument(text: "x")
        let source = TextCompareService.source(of: document!)
        document = nil
        do {
            _ = try await source.load()
            XCTFail("ожидалась ошибка")
        } catch {
            guard case TextCompareError.closed = error else { return XCTFail("\(error)") }
        }
    }
}
