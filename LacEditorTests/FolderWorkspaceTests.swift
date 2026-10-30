import Combine
import Foundation
import XCTest
@testable import LacEditor

private final class FolderTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

@MainActor
final class FolderWorkspaceTests: XCTestCase {
    func testSortDirectionAndFolderGroupingPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderWorkspaceStore { _, directory in
            [FolderWorkspaceEntry(url: directory.appendingPathComponent("z-folder", isDirectory: true), name: "z-folder", isDirectory: true, isSymbolicLink: false, creationDate: Date(timeIntervalSince1970: 3), modificationDate: Date(timeIntervalSince1970: 3)),
             FolderWorkspaceEntry(url: directory.appendingPathComponent("item2"), name: "item2", isDirectory: false, isSymbolicLink: false, creationDate: Date(timeIntervalSince1970: 2), modificationDate: Date(timeIntervalSince1970: 2)),
             FolderWorkspaceEntry(url: directory.appendingPathComponent("item10"), name: "item10", isDirectory: false, isSymbolicLink: false, creationDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 1))]
        }
        await store.setRoot(root)?.value
        func waitForLoad() async throws {
            for _ in 0..<100 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(store.loading.contains(root))
        }
        for sort in FolderWorkspaceStore.Sort.allCases {
            store.setSort(sort)
            store.setGroupByFolder(false)
            store.setAscending(true)
            try await waitForLoad()
            let ascending = try XCTUnwrap(store.entries[root]?.map(\.name))
            store.setAscending(false)
            try await waitForLoad()
            XCTAssertEqual(store.entries[root]?.map(\.name), Array(ascending.reversed()), "\(sort)")
            store.setGroupByFolder(true)
            try await waitForLoad()
            XCTAssertEqual(store.entries[root]?.first?.name, "z-folder")
        }
        let session = try XCTUnwrap(store.sessionState)
        let decoded = try JSONDecoder().decode(FolderWorkspaceSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.ascending, false)
        XCTAssertEqual(decoded.groupByFolder, true)
        let oldJSON = Data("{\"rootPath\":\"/tmp\",\"sort\":\"created\"}".utf8)
        let old = try JSONDecoder().decode(FolderWorkspaceSession.self, from: oldJSON)
        XCTAssertNil(old.ascending)
        XCTAssertNil(old.groupByFolder)
    }
    func testSortModesUseStableNamesAndDates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderWorkspaceStore { _, directory in
            [FolderWorkspaceEntry(url: directory.appendingPathComponent("item10"), name: "item10", isDirectory: false, isSymbolicLink: false, creationDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 3)),
             FolderWorkspaceEntry(url: directory.appendingPathComponent("item2"), name: "item2", isDirectory: false, isSymbolicLink: false, creationDate: Date(timeIntervalSince1970: 2), modificationDate: Date(timeIntervalSince1970: 1)),
             FolderWorkspaceEntry(url: directory.appendingPathComponent("folder"), name: "folder", isDirectory: true, isSymbolicLink: false)]
        }
        let first = try XCTUnwrap(store.setRoot(root))
        await first.value
        XCTAssertEqual(store.entries[root]?.map(\.name), ["folder", "item2", "item10"])
        store.setSort(.created)
        for _ in 0..<100 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.entries[root]?.map(\.name), ["folder", "item2", "item10"])
        store.setSort(.modified)
        for _ in 0..<100 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.entries[root]?.map(\.name), ["folder", "item10", "item2"])
    }

    func testSessionRestoreListAndSortKeepsExpandedTreePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("folder", isDirectory: true)
        let nested = first.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: nested.appendingPathComponent("10.md"), atomically: true, encoding: .utf8)
        let session = FolderWorkspaceSession(rootPath: root.path, expandedPaths: [["folder"], ["folder", "nested"]],
            sort: "name", view: "list", currentPath: ["folder", "nested"])
        let store = FolderWorkspaceStore()
        store.restore(session)
        for _ in 0..<100 where store.currentDirectory != nested || store.listEntries.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.display, .list)
        XCTAssertEqual(store.sort, .name)
        XCTAssertEqual(store.currentDirectory, nested)
        XCTAssertEqual(store.listEntries.first?.name, "10.md")
        XCTAssertEqual(store.sessionState?.expandedPaths, [["folder"], ["folder", "nested"]])
        store.setDisplay(.tree)
        for _ in 0..<100 where !store.expanded.contains(nested) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.expanded.contains(first))
        XCTAssertTrue(store.expanded.contains(nested))
    }

    func testListGroupsFilesAcrossFoldersAndSortsGlobally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("z.md"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let store = FolderWorkspaceStore()
        await store.setRoot(root)?.value
        store.setDisplay(.list)
        for _ in 0..<200 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.listEntries.map(\.name), ["z.md", "a.md"])
        XCTAssertEqual(FolderWorkspaceVisibleRow.rows(in: store).count, 4)
        store.setGroupByFolder(false)
        for _ in 0..<200 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.listEntries.map(\.name), ["a.md", "z.md"])
        XCTAssertEqual(FolderWorkspaceVisibleRow.rows(in: store).count, 2)
        store.setDisplay(.tree)
        for _ in 0..<200 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.entries[folder])
    }

    func testListRefreshesForNestedFileChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderWorkspaceStore()
        await store.setRoot(root)?.value
        store.setDisplay(.list)
        for _ in 0..<200 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.watchError)
        let updated = expectation(description: "nested change updates list")
        updated.assertForOverFulfill = false
        let subscription = store.$listEntries.sink { entries in
            if entries.contains(where: { $0.name == "new.md" }) { updated.fulfill() }
        }
        try "hello".write(to: folder.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        await fulfillment(of: [updated], timeout: 10)
        withExtendedLifetime(subscription) {}
    }

    func testListCancelsOldRootAndRejectsLateResult() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let started = expectation(description: "first listing started")
        let cancelled = expectation(description: "first listing was cancelled")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let store = FolderWorkspaceStore(enumerateList: { root, isCancelled in
            if root == first {
                started.fulfill()
                gate.wait()
                if isCancelled() { cancelled.fulfill() }
                let file = FolderSearchService.File(url: first.appendingPathComponent("old.md"), relativePath: "old.md")
                let item = FolderSearchService.ListedFile(file: file, isSymbolicLink: false, creationDate: nil, modificationDate: nil)
                return FolderSearchService.Result(root: first, values: [item], problems: [])
            }
            return FolderSearchService.Result(root: root, values: [], problems: [])
        })
        store.setDisplay(.list)
        let old = try XCTUnwrap(store.setRoot(first))
        await fulfillment(of: [started], timeout: 5)
        let current = try XCTUnwrap(store.setRoot(second))
        await current.value
        gate.signal()
        await old.value
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(store.rootURL, second)
        XCTAssertTrue(store.listEntries.isEmpty)
        XCTAssertFalse(store.loading.contains(second))
    }

    func testUnknownSessionOptionsAndUnsafeComponentsUseDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = FolderWorkspaceSession(rootPath: root.path, expandedPaths: [[".."], ["outside/file"]],
            sort: "future", view: "future", currentPath: [".."])
        let store = FolderWorkspaceStore()
        store.restore(session)
        for _ in 0..<100 where store.entries[root] == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.sort, .natural)
        XCTAssertEqual(store.display, .tree)
        XCTAssertEqual(store.expanded, [root])
        XCTAssertEqual(store.currentDirectory, root)
    }

    func testMissingRestoredRootStaysVisibleWithError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = FolderWorkspaceSession(rootPath: root.path, expandedPaths: [], sort: "natural", view: "tree", currentPath: [])
        let store = FolderWorkspaceStore()
        store.restore(session)
        for _ in 0..<100 where store.errors[root] == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.rootURL, root)
        XCTAssertNotNil(store.errors[root])
        XCTAssertNil(store.entries[root])
    }

    func testFSEventsRefreshOnlyActiveRootAndIgnoreOldRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FolderWorkspaceStore()
        let initial = try XCTUnwrap(store.setRoot(first))
        await initial.value
        XCTAssertNil(store.watchError)
        let detected = expectation(description: "FSEvents updates root")
        detected.assertForOverFulfill = false
        let token = store.$entries.sink { entries in
            if entries[first]?.contains(where: { $0.name == "new.md" }) == true { detected.fulfill() }
        }
        try "new".write(to: first.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        await fulfillment(of: [detected], timeout: 5)
        let next = try XCTUnwrap(store.setRoot(second))
        await next.value
        try "later".write(to: first.appendingPathComponent("late.md"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.rootURL, second)
        XCTAssertNil(store.entries[first])
        withExtendedLifetime(token) {}
    }

    func testFSEventsResortAfterExternalFileDateChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.md"), second = root.appendingPathComponent("b.md")
        try "a".write(to: first, atomically: true, encoding: .utf8)
        try "b".write(to: second, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: second.path)
        let store = FolderWorkspaceStore()
        let load = try XCTUnwrap(store.setRoot(root))
        await load.value
        store.setSort(.modified)
        for _ in 0..<100 where store.loading.contains(root) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.entries[root]?.map(\.name), ["b.md", "a.md"])
        let reordered = expectation(description: "file event updates modified order")
        reordered.assertForOverFulfill = false
        let token = store.$entries.sink { entries in
            if entries[root]?.map(\.name) == ["a.md", "b.md"] { reordered.fulfill() }
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: first.path)
        await fulfillment(of: [reordered], timeout: 5)
        withExtendedLifetime(token) {}
    }

    func testClosingRootReleasesWatcherAndStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var store: FolderWorkspaceStore? = FolderWorkspaceStore()
        weak var weakStore = store
        weakStore = store
        let load = try XCTUnwrap(store?.setRoot(root))
        await load.value
        _ = store?.setRoot(nil)
        store = nil
        for _ in 0..<100 where weakStore != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(weakStore)
    }

    func testWorkspaceFileOperationsRespectCollisionsAndSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = FileService()
        let folder = try service.createWorkspaceItem(named: "目录😀", in: root, root: root, isDirectory: true)
        let file = try service.createWorkspaceItem(named: "a.md", in: folder, root: root, isDirectory: false)
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.createWorkspaceItem(named: "a.md", in: folder, root: root, isDirectory: false))
        XCTAssertThrowsError(try service.createWorkspaceItem(named: "目录😀", in: root, root: root, isDirectory: true))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disk")
        let duplicate = try service.copyWorkspaceItem(file, named: "copy.md", root: root)
        XCTAssertEqual(try String(contentsOf: duplicate, encoding: .utf8), "disk")
        XCTAssertThrowsError(try service.copyWorkspaceItem(file, named: "copy.md", root: root))
        let snapshot = try service.workspaceItemSnapshot(duplicate)
        try "edit".write(to: duplicate, atomically: false, encoding: .utf8)
        XCTAssertNotEqual(try service.workspaceItemSnapshot(duplicate), snapshot)
        let moved = try service.moveWorkspaceItem(duplicate, to: root, named: "moved.md", root: root)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "edit")
        XCTAssertThrowsError(try service.moveWorkspaceItem(folder, to: folder, named: "nested", root: root))
        XCTAssertThrowsError(try service.workspaceDestination(named: "..", in: root, root: root))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let copiedLink = try service.copyWorkspaceItem(link, named: "link copy", root: root)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path), outside.path)
        XCTAssertThrowsError(try service.createWorkspaceItem(named: "no.md", in: link, root: root, isDirectory: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("no.md").path))
        let directorySnapshot = try service.workspaceItemSnapshot(root)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertNotEqual(try service.workspaceItemSnapshot(root), directorySnapshot)
    }

    func testUndoCreationDoesNotDeleteChangedOrNonemptyItems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileService()
        let file = try service.createWorkspaceItem(named: "a.md", in: root, root: root, isDirectory: false)
        let fileSnapshot = try service.workspaceItemSnapshot(file)
        try "later edit".write(to: file, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try service.removeEmptyWorkspaceItem(file, root: root, snapshot: fileSnapshot))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "later edit")
        let folder = try service.createWorkspaceItem(named: "folder", in: root, root: root, isDirectory: true)
        let folderSnapshot = try service.workspaceItemSnapshot(folder)
        try "child".write(to: folder.appendingPathComponent("child"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.removeEmptyWorkspaceItem(folder, root: root, snapshot: folderSnapshot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("child").path))
        let empty = try service.createWorkspaceItem(named: "empty", in: root, root: root, isDirectory: true)
        let emptySnapshot = try service.workspaceItemSnapshot(empty)
        try service.removeEmptyWorkspaceItem(empty, root: root, snapshot: emptySnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testLazyTreeNaturalOrderAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder2 = root.appendingPathComponent("Folder 2", isDirectory: true)
        let folder10 = root.appendingPathComponent("Folder 10", isDirectory: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder10, withIntermediateDirectories: true)
        try "text".write(to: root.appendingPathComponent("中文😀.md"), atomically: true, encoding: .utf8)
        try "nested".write(to: folder2.appendingPathComponent("child.md"), atomically: true, encoding: .utf8)
        let cycle = folder2.appendingPathComponent("ancestor")
        try FileManager.default.createSymbolicLink(at: cycle, withDestinationURL: root)
        let external = root.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at: external, withDestinationURL: FileManager.default.temporaryDirectory)
        let store = FolderWorkspaceStore()
        let rootLoaded = expectation(description: "root")
        let childLoaded = expectation(description: "expanded child")
        rootLoaded.assertForOverFulfill = false
        childLoaded.assertForOverFulfill = false
        let subscription = store.$entries.sink { entries in
            if entries[root] != nil { rootLoaded.fulfill() }
            if entries[folder2] != nil { childLoaded.fulfill() }
        }
        store.setRoot(root)
        await fulfillment(of: [rootLoaded], timeout: 5)
        let children = try XCTUnwrap(store.entries[root])
        XCTAssertEqual(Array(children.prefix(2).map(\.name)), ["Folder 2", "Folder 10"])
        XCTAssertTrue(children.contains { $0.name == "中文😀.md" })
        XCTAssertNil(store.entries[folder2])
        let link = try XCTUnwrap(children.first { $0.url == external })
        XCTAssertTrue(link.isSymbolicLink)
        store.expand(external)
        XCTAssertFalse(store.expanded.contains(external))
        store.expand(folder2)
        await fulfillment(of: [childLoaded], timeout: 5)
        XCTAssertTrue(try XCTUnwrap(store.entries[folder2]).contains { $0.url == cycle && $0.isSymbolicLink })
        store.expand(cycle)
        XCTAssertFalse(store.expanded.contains(cycle))
        store.collapse(folder2)
        XCTAssertNil(store.entries[folder2])
        XCTAssertFalse(store.expanded.contains(folder2))
        withExtendedLifetime(subscription) {}
    }

    func testMissingDirectoryIsErrorNotEmptyFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FolderWorkspaceStore()
        let failed = expectation(description: "unavailable")
        let subscription = store.$errors.sink { if $0[root] != nil { failed.fulfill() } }
        store.setRoot(root)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNil(store.entries[root])
        XCTAssertNotNil(store.errors[root])
        XCTAssertFalse(store.loading.contains(root))
        withExtendedLifetime(subscription) {}
    }

    func testEmptyDirectoryIsSuccessful() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderWorkspaceStore()
        let task = try XCTUnwrap(store.setRoot(root))
        await task.value
        XCTAssertEqual(store.entries[root], [])
        XCTAssertNil(store.errors[root])
        XCTAssertFalse(store.loading.contains(root))
    }

    func testDisappearingChildReportsItsOwnError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderWorkspaceStore()
        let rootTask = try XCTUnwrap(store.setRoot(root))
        await rootTask.value
        try FileManager.default.removeItem(at: child)
        let childTask = try XCTUnwrap(store.expand(child))
        await childTask.value
        XCTAssertNotNil(store.errors[child])
        XCTAssertNil(store.entries[child])
        XCTAssertNotNil(store.entries[root])
        XCTAssertNil(store.errors[root])
    }

    func testRefreshReadsRootAndExpandedButNotCollapsed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderWorkspaceStore()
        let rootLoaded = expectation(description: "root loaded")
        let childLoaded = expectation(description: "child loaded")
        let refreshed = expectation(description: "new file")
        let subscription = store.$entries.sink { entries in
            if entries[root]?.contains(where: { $0.url == child }) == true { rootLoaded.fulfill() }
            if entries[child] != nil { childLoaded.fulfill() }
            if entries[child]?.contains(where: { $0.name == "new.md" }) == true { refreshed.fulfill() }
        }
        rootLoaded.assertForOverFulfill = false
        childLoaded.assertForOverFulfill = false
        store.setRoot(root)
        await fulfillment(of: [rootLoaded], timeout: 5)
        store.expand(child)
        await fulfillment(of: [childLoaded], timeout: 5)
        try "new".write(to: child.appendingPathComponent("new.md"), atomically: true, encoding: .utf8)
        store.refresh()
        await fulfillment(of: [refreshed], timeout: 5)
        store.collapse(child)
        store.refresh()
        XCTAssertNil(store.entries[child])
        withExtendedLifetime(subscription) {}
    }

    func testOldRootResultIsDiscardedAfterSwitch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oldRoot = base.appendingPathComponent("old", isDirectory: true)
        let newRoot = base.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let oldStarted = expectation(description: "old started")
        let oldFinished = expectation(description: "old returned")
        let newLoaded = expectation(description: "new loaded")
        let release = DispatchSemaphore(value: 0)
        let store = FolderWorkspaceStore { _, url in
            if url == oldRoot {
                oldStarted.fulfill()
                release.wait()
                oldFinished.fulfill()
                return [FolderWorkspaceEntry(url: url.appendingPathComponent("old"), name: "old", isDirectory: false, isSymbolicLink: false)]
            }
            return [FolderWorkspaceEntry(url: url.appendingPathComponent("new"), name: "new", isDirectory: false, isSymbolicLink: false)]
        }
        let subscription = store.$entries.sink { if $0[newRoot] != nil { newLoaded.fulfill() } }
        let oldTask = try XCTUnwrap(store.setRoot(oldRoot))
        await fulfillment(of: [oldStarted], timeout: 5)
        store.setRoot(newRoot)
        await fulfillment(of: [newLoaded], timeout: 5)
        release.signal()
        await fulfillment(of: [oldFinished], timeout: 5)
        await oldTask.value
        XCTAssertEqual(store.rootURL, newRoot)
        XCTAssertNil(store.entries[oldRoot])
        XCTAssertEqual(store.entries[newRoot]?.map(\.name), ["new"])
        withExtendedLifetime(subscription) {}
    }

    func testCollapsedBranchRejectsPendingResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "child started")
        let release = DispatchSemaphore(value: 0)
        let store = FolderWorkspaceStore { _, url in
            if url == root {
                return [FolderWorkspaceEntry(url: child, name: "child", isDirectory: true, isSymbolicLink: false)]
            }
            started.fulfill()
            release.wait()
            return [FolderWorkspaceEntry(url: child.appendingPathComponent("late"), name: "late", isDirectory: false, isSymbolicLink: false)]
        }
        let rootTask = try XCTUnwrap(store.setRoot(root))
        await rootTask.value
        let childTask = try XCTUnwrap(store.expand(child))
        await fulfillment(of: [started], timeout: 5)
        store.collapse(child)
        release.signal()
        await childTask.value
        XCTAssertNil(store.entries[child])
        XCTAssertFalse(store.expanded.contains(child))
        XCTAssertFalse(store.loading.contains(child))
        XCTAssertNil(store.errors[child])
    }

    func testOldResultIsDiscardedAfterReturningToSameRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = base.appendingPathComponent("a", isDirectory: true)
        let second = base.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let started = expectation(description: "first A started")
        let release = DispatchSemaphore(value: 0)
        let counter = FolderTestCounter()
        let store = FolderWorkspaceStore { _, url in
            if url == first {
                if counter.next() == 1 {
                    started.fulfill()
                    release.wait()
                    return [FolderWorkspaceEntry(url: url.appendingPathComponent("old"), name: "old", isDirectory: false, isSymbolicLink: false)]
                }
                return [FolderWorkspaceEntry(url: url.appendingPathComponent("new"), name: "new", isDirectory: false, isSymbolicLink: false)]
            }
            return []
        }
        let old = try XCTUnwrap(store.setRoot(first))
        await fulfillment(of: [started], timeout: 5)
        let middle = try XCTUnwrap(store.setRoot(second))
        await middle.value
        let current = try XCTUnwrap(store.setRoot(first))
        await current.value
        XCTAssertEqual(store.entries[first]?.map(\.name), ["new"])
        release.signal()
        await old.value
        XCTAssertEqual(store.entries[first]?.map(\.name), ["new"])
        XCTAssertNil(store.entries[second])
    }

    func testOldResultIsDiscardedAfterReexpandingSameBranch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "first child read")
        let release = DispatchSemaphore(value: 0)
        let counter = FolderTestCounter()
        let store = FolderWorkspaceStore { _, url in
            if url == root { return [FolderWorkspaceEntry(url: child, name: "child", isDirectory: true, isSymbolicLink: false)] }
            if counter.next() == 1 {
                started.fulfill()
                release.wait()
                return [FolderWorkspaceEntry(url: child.appendingPathComponent("old"), name: "old", isDirectory: false, isSymbolicLink: false)]
            }
            return [FolderWorkspaceEntry(url: child.appendingPathComponent("new"), name: "new", isDirectory: false, isSymbolicLink: false)]
        }
        let rootTask = try XCTUnwrap(store.setRoot(root))
        await rootTask.value
        let old = try XCTUnwrap(store.expand(child))
        await fulfillment(of: [started], timeout: 5)
        store.collapse(child)
        let current = try XCTUnwrap(store.expand(child))
        await current.value
        XCTAssertEqual(store.entries[child]?.map(\.name), ["new"])
        release.signal()
        await old.value
        XCTAssertEqual(store.entries[child]?.map(\.name), ["new"])
    }

    func testReplacedDirectorySymlinksAreNotTraversed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        let outsideChild = outside.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: true)
        try "outside".write(to: outsideChild.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FolderWorkspaceStore()
        let rootTask = try XCTUnwrap(store.setRoot(root))
        await rootTask.value
        let parentTask = try XCTUnwrap(store.expand(parent))
        await parentTask.value
        let childTask = try XCTUnwrap(store.expand(child))
        await childTask.value
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outsideChild)
        let childSwapTask = try XCTUnwrap(store.expand(child))
        await childSwapTask.value
        XCTAssertNotNil(store.errors[child])
        XCTAssertNil(store.entries[child])
        try FileManager.default.removeItem(at: child)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        let parentSwapTask = try XCTUnwrap(store.expand(child))
        await parentSwapTask.value
        XCTAssertNotNil(store.errors[child])
        XCTAssertNil(store.entries[child])
        let refreshed = expectation(description: "root sees symbolic link")
        let subscription = store.$entries.sink { entries in
            if entries[root]?.contains(where: { $0.name == "parent" && $0.isSymbolicLink }) == true { refreshed.fulfill() }
        }
        store.refresh()
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertFalse(store.expanded.contains(parent))
        XCTAssertNil(store.entries[parent])
        XCTAssertNil(store.entries[child])
        withExtendedLifetime(subscription) {}
    }

    func testReplacedRootSymlinkIsNotTraversedOnRefresh() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "external".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FolderWorkspaceStore()
        let task = try XCTUnwrap(store.setRoot(root))
        await task.value
        XCTAssertEqual(store.entries[root], [])
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let rejected = expectation(description: "replaced root rejected")
        let subscription = store.$errors.sink { if $0[root] != nil { rejected.fulfill() } }
        store.refresh()
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertNil(store.entries[root])
        XCTAssertNotNil(store.errors[root])
        withExtendedLifetime(subscription) {}
    }
}
