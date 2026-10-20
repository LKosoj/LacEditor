import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LacEditor

@MainActor
final class SidebarDragTests: XCTestCase {
    func testDetachingScrollAttachmentCancelsDisplayLinkAndPendingExpansion() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SidebarLibraryStore(storageURL: folder.appendingPathComponent("sidebar.json"))
        let group = try XCTUnwrap(library.createGroup(named: "不应展开"))
        library.setExpanded(false, for: group)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 800))
        scroll.documentView = document
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }
        let point = window.convertPoint(toScreen: scroll.contentView.convert(NSPoint(x: 100, y: 200), to: nil))
        var state: SidebarDragState? = SidebarDragState(mouseLocation: { point }, isDragging: { true })
        weak var released = state
        let attachment = SidebarDragScrollAttachment.Attachment(state: state!)
        document.addSubview(attachment)
        state?.hover(.group(group), placement: .inside, library: library)
        XCTAssertTrue(state?.isTrackingDrag == true)
        attachment.removeFromSuperview()
        XCTAssertNil(state?.target)
        XCTAssertFalse(state?.isTrackingDrag == true)
        state = nil
        XCTAssertNil(released, "The display-link target must not retain its sidebar")
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(library.groups[0].isExpanded)
    }

    func testHoverExpansionCancelsPreviousGroupAndStopsOnRelease() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SidebarLibraryStore(storageURL: folder.appendingPathComponent("library.json"))
        let first = try XCTUnwrap(library.createGroup(named: "First"))
        let second = try XCTUnwrap(library.createGroup(named: "Second"))
        library.setExpanded(false, for: first)
        library.setExpanded(false, for: second)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 1_000))
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }
        var dragging = true
        let point = window.convertPoint(toScreen: scroll.contentView.convert(NSPoint(x: 100, y: 200), to: nil))
        let state = SidebarDragState(mouseLocation: { point }, isDragging: { dragging })
        state.scrollView = scroll
        state.hover(.group(first), placement: .inside, library: library)
        try await Task.sleep(for: .milliseconds(150))
        state.hover(.group(second), placement: .inside, library: library)
        for _ in 0..<50 {
            if library.groups.first(where: { $0.id == second })?.isExpanded == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(try XCTUnwrap(library.groups.first { $0.id == first }).isExpanded)
        XCTAssertTrue(try XCTUnwrap(library.groups.first { $0.id == second }).isExpanded)
        dragging = false
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(state.target)
        XCTAssertEqual(library.groups.map(\.id), [first, second])
    }

    func testDisplayLinkedDragScrollsEdgeAndStopsAfterCancellationOrHiddenWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 260, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 2_000))
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SidebarLibraryStore(storageURL: folder.appendingPathComponent("library.json"))
        var point = window.convertPoint(toScreen: scroll.contentView.convert(NSPoint(x: 100, y: 398), to: nil))
        let state = SidebarDragState(mouseLocation: { point }, isDragging: { true })
        state.scrollView = scroll
        state.hover(.favoritesHeader, placement: .inside, library: library)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        let beforeRowExit = scroll.contentView.bounds.minY
        state.leave(.favoritesHeader)
        XCTAssertNil(state.target)
        XCTAssertTrue(state.isTrackingDrag, "Crossing rows must not restart scroll acceleration")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, beforeRowExit)
        state.finish()
        let stopped = scroll.contentView.bounds.minY
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scroll.contentView.bounds.minY, stopped)
        point = window.convertPoint(toScreen: scroll.contentView.convert(NSPoint(x: 100, y: stopped + 200), to: nil))
        state.hover(.favoritesHeader, placement: .inside, library: library)
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(state.target)
        XCTAssertEqual(scroll.contentView.bounds.minY, stopped)
    }

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
        XCTAssertEqual(SidebarDragState.scrollVelocity(y: -1, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollVelocity(y: 401, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollVelocity(y: 200, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollVelocity(y: 0, viewportHeight: 400), -420)
        XCTAssertEqual(SidebarDragState.scrollVelocity(y: 400, viewportHeight: 400), 420)
        XCTAssertGreaterThan(SidebarDragState.scrollVelocity(y: 390, viewportHeight: 400), 0)
        XCTAssertEqual(SidebarDragState.scrollVelocity(y: 0, viewportHeight: 0), 0)
    }

    func testEdgeScrollSpeedIsRefreshIndependentAndStopsWithoutMomentum() {
        func distance(at framesPerSecond: Int) -> CGFloat {
            var motion = SidebarEdgeScrollMotion()
            return (0..<framesPerSecond).reduce(0) { total, _ in
                total + motion.step(toward: 420, elapsed: 1 / Double(framesPerSecond))
            }
        }
        XCTAssertEqual(distance(at: 60), distance(at: 120), accuracy: 1)
        XCTAssertEqual(distance(at: 30), distance(at: 60), accuracy: 1)
        var motion = SidebarEdgeScrollMotion()
        for _ in 0..<10 { _ = motion.step(toward: 420, elapsed: 1.0 / 60) }
        XCTAssertLessThan(motion.step(toward: -420, elapsed: 1.0 / 60), 0)
        XCTAssertEqual(motion.step(toward: 0, elapsed: 1.0 / 60), 0)
        XCTAssertEqual(motion.velocity, 0)
        XCTAssertLessThanOrEqual(motion.step(toward: 420, elapsed: 2), 14)
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
