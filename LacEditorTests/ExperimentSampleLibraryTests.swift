import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class ExperimentSampleLibraryTests: XCTestCase {
    func testSeedingPreservesEditsUserLibraryAndExplicitRemovals() async throws {
        let fixture = try SampleFixture()
        defer { fixture.dispose() }
        let userFile = fixture.directory.appendingPathComponent("用户自己的.txt")
        try "原有内容".write(to: userFile, atomically: true, encoding: .utf8)
        fixture.library.toggleFavorite(userFile)
        let userGroup = try XCTUnwrap(fixture.library.createGroup(named: "我的文件"))
        fixture.library.add(userFile, toGroup: userGroup)
        await fixture.samples.prepare(in: fixture.library)
        XCTAssertFalse(fixture.samples.isPreparing)
        XCTAssertNil(fixture.samples.errorMessage)
        XCTAssertEqual(fixture.library.groups.count, 4)
        XCTAssertTrue(fixture.library.isFavorite(userFile))
        XCTAssertEqual(fixture.library.groups.first { $0.id == userGroup }?.urls, [userFile])

        try "我编辑后的体验文档".write(to: fixture.samples.welcomeURL, atomically: true, encoding: .utf8)
        let removed = fixture.samples.rootURL.appendingPathComponent("代码与数据/sample.js")
        try FileManager.default.removeItem(at: removed)
        let sampleGroup = try XCTUnwrap(fixture.library.groups.first { $0.name == "代码与数据" })
        fixture.library.deleteGroup(sampleGroup.id)
        fixture.library.toggleFavorite(fixture.samples.welcomeURL)

        let restarted = ExperimentSampleLibrary(rootURL: fixture.samples.rootURL, defaults: fixture.defaults)
        await restarted.prepare(in: fixture.library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path), "Upgrades must respect user removals")
        XCTAssertFalse(fixture.library.isFavorite(restarted.welcomeURL))
        XCTAssertFalse(fixture.library.groups.contains { $0.id == sampleGroup.id })

        await restarted.prepare(in: fixture.library, supplement: true)
        XCTAssertNil(restarted.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertEqual(try String(contentsOf: restarted.welcomeURL, encoding: .utf8), "我编辑后的体验文档")
        XCTAssertEqual(fixture.library.groups.count, 4)
        XCTAssertEqual(Set(fixture.library.groups.map(\.name)).count, 4)
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "原有内容")
        let reloaded = SidebarLibraryStore(storageURL: fixture.directory.appendingPathComponent("library.json"))
        XCTAssertEqual(reloaded.groups, fixture.library.groups)
    }

    func testPreparationFailureCanRetryWithoutPermanentBusyState() async throws {
        let fixture = try SampleFixture()
        defer { fixture.dispose() }
        try "blocking file".write(to: fixture.samples.rootURL, atomically: true, encoding: .utf8)
        await fixture.samples.prepare(in: fixture.library)
        XCTAssertNotNil(fixture.samples.errorMessage)
        XCTAssertFalse(fixture.samples.isPreparing)
        XCTAssertTrue(fixture.library.groups.isEmpty)
        try FileManager.default.removeItem(at: fixture.samples.rootURL)
        await fixture.samples.prepare(in: fixture.library)
        XCTAssertNil(fixture.samples.errorMessage)
        XCTAssertFalse(fixture.samples.isPreparing)
        XCTAssertEqual(fixture.library.groups.count, 3)
    }

    func testFilenameAndGroupFilterIsCaseInsensitiveAndDoesNotMutateModel() {
        let a = URL(fileURLWithPath: "/例子/代码与数据/sample.js")
        let b = URL(fileURLWithPath: "/例子/写作与排版/日常便签.txt")
        let group = SidebarFileGroup(name: "我的项目", isExpanded: false, paths: [a.path, b.path])
        XCTAssertEqual(SidebarLibraryFilter(query: "  JS ").files([a, b]), [a])
        XCTAssertEqual(SidebarLibraryFilter(query: "日常").groups([group]).first?.paths, [b.path])
        XCTAssertEqual(SidebarLibraryFilter(query: "项目").groups([group]), [group])
        XCTAssertTrue(SidebarLibraryFilter(query: "未找到").groups([group]).isEmpty)
        XCTAssertEqual(SidebarLibraryFilter(query: " \n ").files([a, b]), [a, b])
        XCTAssertEqual(group.paths, [a.path, b.path])
        XCTAssertFalse(group.isExpanded)
    }

    func testSampleCatalogIsSmallValidAndCoversEditingScenarios() throws {
        let files = ExperimentSampleCatalog.files()
        XCTAssertEqual(files.count, 8)
        XCTAssertLessThan(files.reduce(0) { $0 + $1.text.utf8.count }, 1_500_000)
        XCTAssertEqual(Set(files.map { $0.group + "/" + $0.name }).count, files.count)
        let json = try XCTUnwrap(files.first { $0.name == "preferences.json" })
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.text.utf8)))
        XCTAssertTrue(files.first { $0.name == "日常便签.txt" }!.text.contains("\t"))
        XCTAssertEqual(files.first { $0.name == "多行文本.txt" }!.text.filter { $0 == "\n" }.count, 5_000)
    }
}

@MainActor
private final class SampleFixture {
    let directory: URL
    let suite = "LacEditorTests.samples.\(UUID().uuidString)"
    let defaults: UserDefaults
    let library: SidebarLibraryStore
    let samples: ExperimentSampleLibrary

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        library = SidebarLibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        samples = ExperimentSampleLibrary(rootURL: directory.appendingPathComponent("Examples"), defaults: defaults)
    }

    func dispose() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
