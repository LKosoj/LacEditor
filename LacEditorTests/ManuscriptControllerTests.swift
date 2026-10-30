import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class ManuscriptControllerTests: XCTestCase {
    private func directory(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names { try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return root
    }

    private func controller(snapshots: @escaping () -> [FolderSearchService.OpenDocument]? = { [] },
                            onBuilt: @escaping (ManuscriptService.Output) -> Void = { _ in },
                            build: @escaping @Sendable (ManuscriptController.Request) async throws -> ManuscriptService.Output)
        -> ManuscriptController {
        ManuscriptController(snapshots: snapshots, syntax: { .init() }, onBuilt: onBuilt, build: build)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private let ok = ManuscriptService.Output(text: "t", report: { var r = ManuscriptService.Report(); r.mergedFiles = 1; return r }())

    func testListIsNaturalSortedAndKeepsStateOnReload() async throws {
        let root = try directory(["10.md", "2.md", "a.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = controller { _ in self.ok }
        controller.attach(root: root)
        await waitUntil { !controller.isLoading && !controller.items.isEmpty }
        XCTAssertEqual(controller.items.map(\.id), ["2.md", "10.md"])
        XCTAssertTrue(controller.items.allSatisfy(\.isOn))
        controller.moveSelected(by: 1)
        controller.setItem("2.md", on: false)
        controller.move(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(controller.items.map(\.id), ["10.md", "2.md"])
        try "x".write(to: root.appendingPathComponent("1.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("10.md"))
        controller.reload()
        await waitUntil { !controller.isLoading }
        XCTAssertEqual(controller.items.map(\.id), ["2.md", "1.md"])
        XCTAssertEqual(controller.items.map(\.isOn), [false, true])
        let other = try directory(["z.md"])
        defer { try? FileManager.default.removeItem(at: other) }
        controller.attach(root: other)
        XCTAssertTrue(controller.items.isEmpty)
    }

    func testHiddenFilesAreNotCheckedByDefault() async throws {
        let root = try directory(["a.md", ".draft.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = controller { _ in self.ok }
        controller.attach(root: root)
        await waitUntil { !controller.isLoading && !controller.items.isEmpty }
        XCTAssertEqual(Set(controller.items.filter(\.isOn).map(\.id)), ["a.md"])
    }

    func testMovesStayInBounds() async throws {
        let root = try directory(["a.md", "b.md", "c.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = controller { _ in self.ok }
        controller.attach(root: root)
        await waitUntil { controller.items.count == 3 }
        controller.selectedID = "a.md"
        controller.moveSelected(by: -1)
        XCTAssertEqual(controller.items.map(\.id), ["a.md", "b.md", "c.md"])
        controller.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(controller.items.map(\.id), ["b.md", "c.md", "a.md"])
        controller.moveSelected(by: 1)
        XCTAssertEqual(controller.items.map(\.id), ["b.md", "c.md", "a.md"])
        controller.setAll(false)
        XCTAssertFalse(controller.canBuild)
    }

    func testBuildPassesOnlyCheckedFilesInOrder() async throws {
        let root = try directory(["a.md", "b.md", "c.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box()
        let controller = controller(onBuilt: { box.output = $0 }) { request in
            box.files = request.files.map(\.relativePath)
            return self.ok
        }
        controller.attach(root: root)
        await waitUntil { controller.items.count == 3 }
        controller.setItem("b.md", on: false)
        controller.move(from: IndexSet(integer: 2), to: 0)
        controller.build()
        await waitUntil { box.output != nil }
        XCTAssertEqual(box.files, ["c.md", "a.md"])
        XCTAssertFalse(controller.isBuilding)
    }

    func testCancelDropsResult() async throws {
        let root = try directory(["a.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box()
        let controller = controller(onBuilt: { box.output = $0 }) { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return self.ok
        }
        controller.attach(root: root)
        await waitUntil { controller.items.count == 1 }
        controller.build()
        XCTAssertTrue(controller.isBuilding)
        controller.cancel()
        XCTAssertFalse(controller.isBuilding)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(box.output)
    }

    func testRootChangeDuringBuildDropsResult() async throws {
        let root = try directory(["a.md"])
        let other = try directory(["b.md"])
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let box = Box()
        let controller = controller(onBuilt: { box.output = $0 }) { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return self.ok
        }
        controller.attach(root: root)
        await waitUntil { controller.items.count == 1 }
        controller.build()
        controller.attach(root: other)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(box.output)
    }

    func testUnstableSnapshotsAndEmptyResultShowErrors() async throws {
        let root = try directory(["a.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Box()
        let unstable = controller(snapshots: { nil }) { _ in calls.files = ["called"]; return self.ok }
        unstable.attach(root: root)
        await waitUntil { unstable.items.count == 1 }
        unstable.build()
        XCTAssertEqual(unstable.message, L10n.tr("无法读取打开的文档，请稍后重试"))
        XCTAssertTrue(calls.files.isEmpty)
        let empty = controller { _ in ManuscriptService.Output(text: "", report: .init()) }
        empty.attach(root: root)
        await waitUntil { empty.items.count == 1 }
        empty.build()
        await waitUntil { empty.message != nil }
        XCTAssertEqual(empty.message, L10n.tr("没有可合并的文件"))
        XCTAssertEqual(empty.messageKind, .error)
    }

    private final class Box: @unchecked Sendable {
        var output: ManuscriptService.Output?
        var files: [String] = []
    }
}
