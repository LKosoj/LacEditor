import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LacEditor

@MainActor
final class SidebarDragTests: XCTestCase {
    func testRowHalvesAndAppendHaveUnambiguousDestinations() {
        let url = URL(fileURLWithPath: "/tmp/a.md")
        let id = UUID()
        let file = SidebarDropTarget.file(url, .favorites)
        XCTAssertEqual(file.placement(y: 1, height: 46, isGroup: false), .before)
        XCTAssertEqual(file.placement(y: 45, height: 46, isGroup: false), .after)
        XCTAssertEqual(SidebarDropTarget.group(id).placement(y: 30, height: 32, isGroup: false), .inside)
        XCTAssertEqual(SidebarDropTarget.group(id).placement(y: 30, height: 32, isGroup: true), .after)
        XCTAssertFalse(file.accepts(isGroup: true))
        XCTAssertFalse(SidebarDropTarget.filesEnd(.recent).accepts(isGroup: false))
        XCTAssertTrue(SidebarDropTarget.groupsEnd.accepts(isGroup: true))
        XCTAssertFalse(SidebarDropTarget.groupsEnd.accepts(isGroup: false))
    }

    func testMovingBeforeAfterAndSelfPreservesOtherFilesAndPersists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("library.json")
        let library = SidebarLibraryStore(storageURL: storage)
        let a = folder.appendingPathComponent("a.md")
        let b = folder.appendingPathComponent("b.md")
        let c = folder.appendingPathComponent("c.md")
        let first = try XCTUnwrap(library.createGroup(named: "一"))
        let second = try XCTUnwrap(library.createGroup(named: "二"))
        let third = try XCTUnwrap(library.createGroup(named: "三"))
        [a, b, c].forEach { library.add($0, toGroup: first) }
        let payload = SidebarDragPayload.file(a, location: .group(first))
        SidebarDropTarget.file(c, .group(first)).apply(payload, placement: .after, library: library)
        XCTAssertEqual(library.groups[0].urls, [b, c, a])
        SidebarDropTarget.file(a, .group(first)).apply(payload, placement: .before, library: library)
        XCTAssertEqual(library.groups[0].urls, [b, c, a], "Dropping on itself must not move the file to the end")
        SidebarDropTarget.file(b, .group(first)).apply(payload, placement: .before, library: library)
        XCTAssertEqual(library.groups[0].urls, [a, b, c])
        SidebarDropTarget.group(second).apply(payload, placement: .inside, library: library)
        XCTAssertEqual(library.groups[0].urls, [a, b, c], "Cross-group drop is a copy of membership")
        XCTAssertEqual(library.groups[1].urls, [a])
        SidebarDropTarget.favoritesHeader.apply(payload, placement: .inside, library: library)
        SidebarDropTarget.favoritesHeader.apply(payload, placement: .inside, library: library)
        XCTAssertEqual(library.favoriteURLs, [a])
        SidebarDropTarget.group(third).apply(.group(first), placement: .after, library: library)
        XCTAssertEqual(library.groups.map(\.id), [second, third, first])
        SidebarDropTarget.group(first).apply(.group(first), placement: .before, library: library)
        XCTAssertEqual(library.groups.map(\.id), [second, third, first])
        SidebarDropTarget.groupsEnd.apply(.group(second), placement: .before, library: library)
        XCTAssertEqual(library.groups.map(\.id), [third, first, second])
        let restored = SidebarLibraryStore(storageURL: storage)
        XCTAssertEqual(restored.groups, library.groups)
        XCTAssertEqual(restored.favoritePaths, library.favoritePaths)
    }

    func testHoverAndCancelDoNotMutateOrReorderTheLibrary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SidebarLibraryStore(storageURL: folder.appendingPathComponent("library.json"))
        let id = try XCTUnwrap(library.createGroup(named: "保持原位"))
        library.setExpanded(false, for: id)
        let before = library.groups
        let state = SidebarDragState()
        state.hover(.group(id), placement: .inside, library: library)
        XCTAssertEqual(state.target, .group(id))
        XCTAssertEqual(library.groups, before)
        state.finish()
        XCTAssertNil(state.target)
        XCTAssertEqual(library.groups, before)
    }

    func testEdgeAutoscrollIsBoundedAndLeavesMiddleUntouched() {
        XCTAssertEqual(SidebarDragState.scrollDelta(y: -1, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollDelta(y: 401, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollDelta(y: 200, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollDelta(y: 0, viewportHeight: 400), -14)
        XCTAssertEqual(SidebarDragState.scrollDelta(y: 400, viewportHeight: 400), 14)
        XCTAssertGreaterThan(SidebarDragState.scrollDelta(y: 390, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollDelta(y: 0, viewportHeight: 0), 0)
    }

    func testPrivatePayloadRoundTripAndOrdinaryTextRejection() async throws {
        let first = URL(fileURLWithPath: "/tmp/第一个.md")
        let second = URL(fileURLWithPath: "/tmp/second.js")
        let providers = [first, second].map { SidebarDragPayload.file($0, location: .recent).itemProvider() }
        let done = expectation(description: "Ordered provider callbacks")
        var loaded: [String] = []
        XCTAssertTrue(SidebarDragPayload.load(providers: providers) { payload in
            XCTAssertEqual(payload.kind, .file)
            loaded.append(payload.path!)
            if loaded.count == 2 { done.fulfill() }
        })
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(loaded, [first.path, second.path])
        XCTAssertFalse(SidebarDragPayload.load(providers: [NSItemProvider(object: "not a file" as NSString)]) { _ in
            XCTFail("Arbitrary text must never be accepted as a library drop")
        })
        let group = SidebarDragPayload.group(UUID()).itemProvider()
        XCTAssertTrue(group.hasItemConformingToTypeIdentifier(SidebarDragPayload.groupType.identifier))
        XCTAssertFalse(group.hasItemConformingToTypeIdentifier(SidebarDragPayload.fileType.identifier))
    }

    func testFinderStyleURLsKeepOrderAndRejectFoldersAndUnsupportedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["一.md", "二.js", "ignore.png"].map { folder.appendingPathComponent($0) }
        for url in urls { try Data("local fixture".utf8).write(to: url) }
        let providers = (urls + [folder]).map { NSItemProvider(object: $0 as NSURL) }
        let done = expectation(description: "Supported Finder URLs loaded")
        var paths: [String] = []
        XCTAssertTrue(SidebarDragPayload.load(providers: providers) { payload in
            paths.append(payload.path!)
            if paths.count == 2 { done.fulfill() }
        })
        await fulfillment(of: [done], timeout: 3)
        // The sequential loader has no supported items after these two.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(paths, Array(urls.prefix(2)).map(\.path))
    }
}
