import CoreServices
import Foundation
import XCTest
@testable import LacEditor

/// Подменяемая проверка диска: считает вызовы и может задержать первый ответ.
private final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ExternalFileState?]
    private var count = 0
    let entered = DispatchSemaphore(value: 0)
    var gate: DispatchSemaphore?

    init(_ states: [ExternalFileState?]) { self.states = states }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func capture(_ url: URL) -> ExternalFileState? {
        lock.lock()
        count += 1
        let index = min(count - 1, states.count - 1)
        let state = states[index]
        let gate = count == 1 ? self.gate : nil
        lock.unlock()
        if let gate {
            entered.signal()
            gate.wait()
        }
        return state
    }
}

@MainActor
final class OpenFileWatcherTests: XCTestCase {
    /// FSEvents присылает пути с раскрытыми ссылками (/private/var), как и наблюдатель.
    private lazy var folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }()

    private func snapshot(_ number: Int) -> FileRevisionSnapshot {
        FileRevisionSnapshot(
            identity: DocumentFileIdentity(canonicalPath: "/watch/file", resourceIdentifier: "id\(number)"),
            modificationDate: Date(timeIntervalSince1970: Double(number)),
            fileSize: number
        )
    }

    private func document(_ name: String = "a.md", in directory: URL? = nil, baseline: FileRevisionSnapshot? = nil,
                          text: String = "local", isDirty: Bool = false,
                          profile: DocumentPerformanceProfile? = nil) -> EditorDocument {
        EditorDocument(text: text, url: (directory ?? folder).appendingPathComponent(name),
                       fileRevisionSnapshot: baseline ?? snapshot(1), isDirty: isDirty, performanceProfile: profile)
    }

    private func makeWatcher(_ documents: @escaping () -> [EditorDocument], probe: CaptureProbe,
                             sources: @escaping ([String]) -> Void = { _ in }) -> OpenFileWatcher {
        OpenFileWatcher(documents: documents, debounce: 0.01, retry: 0.01,
                        capture: { probe.capture($0) },
                        makeSource: { paths, _ in sources(paths); return nil })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func event(_ url: URL, flags: Int = 0) -> FolderWorkspaceEvents.Event {
        .init(path: url.path, flags: FSEventStreamEventFlags(flags))
    }

    func testExternalWriteShowsBannerAndKeepsText() async {
        let doc = document(isDirty: true)
        let probe = CaptureProbe([.present(snapshot(2))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        XCTAssertEqual(doc.externalChange, .present(snapshot(2)))
        XCTAssertEqual(doc.text, "local")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.fileRevisionSnapshot, snapshot(1))
    }

    func testOwnSaveDoesNotShowBanner() async throws {
        let suiteName = "LacEditorWatcherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = folder.appendingPathComponent("saved.txt")
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let doc = EditorDocument(text: "one", url: url, fileRevisionSnapshot: try FileRevisionSnapshot.capture(url))
        let state = AppState(initialDocument: doc, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        let watcher = OpenFileWatcher(documents: { [doc] }, debounce: 0.01, retry: 0.01, makeSource: { _, _ in nil })
        doc.text = "two, longer"
        XCTAssertTrue(state.save(doc))
        // Событие и проверка приходят, пока запись и запись версии файла ещё идут.
        watcher.receive([event(url)])
        try await waitUntil { doc.ioState == .idle && !doc.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two, longer")
        // Запись версии (NSFileVersion) идёт после снимка файла: ей даём закончиться.
        try await Task.sleep(for: .milliseconds(300))
        await watcher.checkNow(doc)
        XCTAssertNil(doc.externalChange)
        watcher.receive([event(url)])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(doc.externalChange)
    }

    func testRenameKeepsBaselineAndShowsNoBanner() async throws {
        let oldURL = folder.appendingPathComponent("before.txt")
        let newURL = folder.appendingPathComponent("after.txt")
        try "text".write(to: oldURL, atomically: true, encoding: .utf8)
        let doc = EditorDocument(text: "text", url: oldURL, fileRevisionSnapshot: try FileRevisionSnapshot.capture(oldURL))
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        doc.updateLocationAfterRename(from: oldURL, to: newURL)
        XCTAssertEqual(doc.fileRevisionSnapshot, try FileRevisionSnapshot.capture(newURL))
        let watcher = OpenFileWatcher(documents: { [doc] }, debounce: 0.01, retry: 0.01, makeSource: { _, _ in nil })
        await watcher.checkNow(doc)
        XCTAssertNil(doc.externalChange)
    }

    func testRenameWithChangedContentKeepsOldBaseline() async throws {
        let oldURL = folder.appendingPathComponent("before2.txt")
        let newURL = folder.appendingPathComponent("after2.txt")
        try "text".write(to: oldURL, atomically: true, encoding: .utf8)
        let baseline = try FileRevisionSnapshot.capture(oldURL)
        let doc = EditorDocument(text: "text", url: oldURL, fileRevisionSnapshot: baseline)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        try "text and more".write(to: newURL, atomically: false, encoding: .utf8)
        doc.updateLocationAfterRename(from: oldURL, to: newURL)
        XCTAssertEqual(doc.fileRevisionSnapshot, baseline, "правка при переименовании не скрывается")
        let watcher = OpenFileWatcher(documents: { [doc] }, debounce: 0.01, retry: 0.01, makeSource: { _, _ in nil })
        await watcher.checkNow(doc)
        XCTAssertNotNil(doc.externalChange)
    }

    func testCheckStartedBeforeSaveFinishedIsDiscarded() async throws {
        let doc = document()
        // Первая проверка видит старый диск, повторная — диск после сохранения.
        let probe = CaptureProbe([.present(snapshot(1)), .present(snapshot(2))])
        probe.gate = DispatchSemaphore(value: 0)
        let watcher = makeWatcher({ [doc] }, probe: probe)
        let check = Task { @MainActor in await watcher.checkNow(doc) }
        try await waitUntil { probe.calls == 1 }
        // Сохранение завершилось, пока проверка читала диск: baseline уже новый.
        doc.updateFileRevisionSnapshot(snapshot(2))
        probe.gate?.signal()
        await check.value
        XCTAssertNil(doc.externalChange)
        try await waitUntil { probe.calls == 2 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(probe.calls, 2, "проверка перепланирована ровно один раз")
        XCTAssertNil(doc.externalChange)
    }

    func testSavingStateDefersCheckUntilIdle() async throws {
        let doc = document()
        doc.ioState = .saving
        let probe = CaptureProbe([.present(snapshot(1))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.calls, 0)
        doc.ioState = .idle
        try await waitUntil { probe.calls == 1 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(probe.calls, 1)
    }

    func testFailedStateIsSkippedWithoutRetry() async throws {
        let doc = document()
        doc.ioState = .failed("error")
        let probe = CaptureProbe([.present(snapshot(2))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.calls, 0)
        XCTAssertNil(doc.externalChange)
    }

    func testReadingModeDocumentStillGetsBanner() async {
        let doc = document("a.md")
        doc.setReadingMode(true)
        let probe = CaptureProbe([.present(snapshot(2))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        XCTAssertEqual(doc.externalChange, .present(snapshot(2)))
    }

    func testLargeProfileDocumentGetsBanner() async {
        let doc = document(profile: .large)
        let probe = CaptureProbe([.present(snapshot(2))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        XCTAssertEqual(doc.externalChange, .present(snapshot(2)))
    }

    func testAtomicReplacementDetected() async throws {
        let url = folder.appendingPathComponent("atomic.txt")
        try "aaaa".write(to: url, atomically: true, encoding: .utf8)
        let baseline = try FileRevisionSnapshot.capture(url)
        let doc = EditorDocument(text: "aaaa", url: url, fileRevisionSnapshot: baseline)
        // Тот же размер и та же дата, но другой файл: подмена через временный файл.
        try "bbbb".write(to: url, atomically: true, encoding: .utf8)
        if let date = baseline.modificationDate {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let watcher = OpenFileWatcher(documents: { [doc] }, debounce: 0.01, retry: 0.01, makeSource: { _, _ in nil })
        await watcher.checkNow(doc)
        guard case let .present(found)? = doc.externalChange else { return XCTFail("нет плашки") }
        XCTAssertNotEqual(found, baseline)
        XCTAssertEqual(doc.text, "aaaa")
    }

    func testDeletedFileShowsMissing() async throws {
        let url = folder.appendingPathComponent("gone.txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        let doc = EditorDocument(text: "x", url: url, fileRevisionSnapshot: try FileRevisionSnapshot.capture(url))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(OpenFileWatcher.captureOnDisk(url), .missing)
        let watcher = OpenFileWatcher(documents: { [doc] }, debounce: 0.01, retry: 0.01, makeSource: { _, _ in nil })
        await watcher.checkNow(doc)
        XCTAssertEqual(doc.externalChange, .missing)
    }

    func testUnreadableErrorKeepsPreviousState() async {
        let doc = document()
        let probe = CaptureProbe([.present(snapshot(2)), nil])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        await watcher.checkNow(doc)
        XCTAssertEqual(probe.calls, 2)
        XCTAssertEqual(doc.externalChange, .present(snapshot(2)))
    }

    func testSecondChangeUpdatesExistingBannerState() async {
        let doc = document()
        let probe = CaptureProbe([.present(snapshot(2)), .present(snapshot(3))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        XCTAssertEqual(doc.externalChange, .present(snapshot(2)))
        await watcher.checkNow(doc)
        XCTAssertEqual(doc.externalChange, .present(snapshot(3)))
    }

    func testKeepMyVersionSuppressesUntilNextChange() async {
        let doc = document()
        let probe = CaptureProbe([.present(snapshot(2)), .present(snapshot(2)), .present(snapshot(3))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        doc.keepMyVersion()
        XCTAssertNil(doc.externalChange)
        await watcher.checkNow(doc)
        XCTAssertNil(doc.externalChange)
        await watcher.checkNow(doc)
        XCTAssertEqual(doc.externalChange, .present(snapshot(3)))
    }

    func testBannerClearsWhenDiskMatchesBaselineAgain() async {
        let doc = document()
        let probe = CaptureProbe([.present(snapshot(2)), .present(snapshot(1))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        await watcher.checkNow(doc)
        XCTAssertNotNil(doc.externalChange)
        await watcher.checkNow(doc)
        XCTAssertNil(doc.externalChange)
    }

    func testSkipsPlaceholdersAndDocumentsWithoutBaselineOrURL() async throws {
        let noBaseline = EditorDocument(text: "", url: folder.appendingPathComponent("b.md"))
        let noURL = EditorDocument(text: "", fileRevisionSnapshot: snapshot(1))
        let probe = CaptureProbe([.present(snapshot(2))])
        var sourceCalls = 0
        let watcher = makeWatcher({ [noBaseline, noURL] }, probe: probe, sources: { _ in sourceCalls += 1 })
        watcher.refreshTargets()
        await watcher.checkNow(noBaseline)
        await watcher.checkNow(noURL)
        watcher.checkAll()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(sourceCalls, 0)
        XCTAssertEqual(probe.calls, 0)
    }

    func testEventsMatchOnlyParentDirectory() async throws {
        let other = folder.appendingPathComponent("other")
        let doc = document()
        let probe = CaptureProbe([.present(snapshot(2))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        watcher.receive([event(other.appendingPathComponent("a.md"))])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(probe.calls, 0)
        watcher.receive([event(folder.appendingPathComponent("a.md"))])
        try await waitUntil { probe.calls == 1 }
        XCTAssertEqual(probe.calls, 1)
        let second = CaptureProbe([.present(snapshot(2))])
        let rescanWatcher = makeWatcher({ [doc] }, probe: second)
        rescanWatcher.receive([event(other, flags: Int(kFSEventStreamEventFlagMustScanSubDirs))])
        try await waitUntil { second.calls == 1 }
        XCTAssertEqual(second.calls, 1)
        let third = CaptureProbe([.present(snapshot(2))])
        let rootWatcher = makeWatcher({ [doc] }, probe: third)
        rootWatcher.receive([event(other, flags: Int(kFSEventStreamEventFlagRootChanged))])
        try await waitUntil { third.calls == 1 }
        XCTAssertEqual(third.calls, 1)
    }

    func testTwoDocumentsInSameDirectoryAreCheckedIndependently() async throws {
        let first = document("a.md")
        let second = document("b.md", baseline: snapshot(5))
        let probe = CaptureProbe([.present(snapshot(2))])
        let watcher = makeWatcher({ [first, second] }, probe: probe)
        watcher.receive([event(folder.appendingPathComponent("a.md"))])
        try await waitUntil { probe.calls == 2 }
        try await waitUntil { first.externalChange != nil && second.externalChange != nil }
        XCTAssertEqual(first.externalChange, .present(snapshot(2)))
        XCTAssertEqual(second.externalChange, .present(snapshot(2)))
    }

    func testClosingDocumentCancelsPendingCheckAndDropsDirectory() async throws {
        let otherFolder = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let first = document("a.md")
        let second = document("b.md", in: otherFolder)
        var open = [first, second]
        let probe = CaptureProbe([.present(snapshot(2))])
        var requested: [[String]] = []
        let watcher = OpenFileWatcher(documents: { open }, debounce: 0.2, retry: 0.01,
                                      capture: { probe.capture($0) },
                                      makeSource: { paths, _ in requested.append(paths); return nil })
        watcher.refreshTargets()
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.count, 1, "вложенный каталог отдельно не добавляется")
        watcher.receive([event(otherFolder.appendingPathComponent("b.md"))])
        open = [first]
        watcher.refreshTargets()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(probe.calls, 0)
        XCTAssertNil(second.externalChange)
        XCTAssertEqual(requested.count, 1, "набор каталогов не изменился: вложенный каталог был лишним")
    }

    func testRefreshTargetsRecreatesStreamOnlyWhenSetChanges() async throws {
        let first = document("a.md")
        let sibling = document("b.md")
        let elsewhere = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let third = document("c.md", in: elsewhere)
        var open = [first]
        var requested: [[String]] = []
        let probe = CaptureProbe([nil])
        let watcher = OpenFileWatcher(documents: { open }, capture: { probe.capture($0) },
                                      makeSource: { paths, _ in requested.append(paths); return nil })
        watcher.refreshTargets()
        watcher.refreshTargets()
        XCTAssertEqual(requested.count, 1)
        open = [first, sibling]
        watcher.refreshTargets()
        XCTAssertEqual(requested.count, 1, "тот же каталог")
        open = [first, sibling, third]
        watcher.refreshTargets()
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(requested.last?.count, 2)
        open = []
        watcher.refreshTargets()
        XCTAssertEqual(requested.count, 2, "без документов поток только останавливается")
    }

    func testCheckAllOnActivationFindsChangeWithoutEvents() async throws {
        let doc = document()
        let probe = CaptureProbe([.present(snapshot(2))])
        let watcher = makeWatcher({ [doc] }, probe: probe)
        watcher.checkAll()
        try await waitUntil { doc.externalChange != nil }
        XCTAssertEqual(doc.externalChange, .present(snapshot(2)))
    }
}
