import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import LacEditor

@MainActor
final class FileAssociationTests: XCTestCase {
    private let installed = FileAssociationService.ApplicationIdentity(
        url: URL(fileURLWithPath: "/Applications/LacEditor.app"),
        identifier: "com.koslaceditor.app", declaresAssociations: true)

    func testCatalogGroupsAliasesAndDoesNotOfferVideoTransportStreams() throws {
        let formats = FileAssociationFormat.catalog()
        XCTAssertEqual(Set(formats.flatMap(\.extensions)), Set(FileAssociationFormat.supportedExtensions))
        XCTAssertEqual(Set(formats.map(\.id)).count, formats.count)
        let html = try XCTUnwrap(formats.first { $0.extensions.contains("html") })
        XCTAssertTrue(html.extensions.contains("htm"))
        XCTAssertTrue(html.isText)
        let transport = try XCTUnwrap(UTType("public.mpeg-2-transport-stream"))
        XCTAssertFalse(FileAssociationFormat(type: transport, extensions: ["ts"]).isText,
                       "Never take over a video type just because code also uses .ts")
    }

    func testOnlyInstalledAssociationEnabledFormalAppCanChangeDefaults() {
        XCTAssertTrue(installed.canSetDefaults)
        for identity in [
            FileAssociationService.ApplicationIdentity(url: installed.url, identifier: "com.laceditor.acceptance", declaresAssociations: true),
            .init(url: installed.url, identifier: "com.laceditor.development", declaresAssociations: true),
            .init(url: installed.url, identifier: "com.laceditor.ui-experiment", declaresAssociations: true),
            .init(url: URL(fileURLWithPath: "/tmp/LacEditor.app"), identifier: installed.identifier, declaresAssociations: true),
            .init(url: installed.url, identifier: installed.identifier, declaresAssociations: false)
        ] { XCTAssertFalse(identity.canSetDefaults) }
        XCTAssertEqual(AppEnvironment.dataDirectoryName(for: "com.laceditor.development"), "LacEditor-Development")
    }

    func testRefreshNeverSetsDefaultsAndDistinguishesAnotherCopy() throws {
        var writes = 0
        let service = FileAssociationService(identity: installed,
            formats: FileAssociationFormat.catalog(extensions: ["txt", "json"]),
            client: .init(defaultApplication: { _ in URL(fileURLWithPath: "/System/Applications/TextEdit.app") },
                          setDefault: { _, _ in writes += 1 }))
        service.refresh()
        service.refresh()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(service.rows.count, 2)
        XCTAssertTrue(service.rows.allSatisfy { !$0.isCurrentApplication && $0.applicationName == "TextEdit" })
        let current = FileAssociationService(identity: installed, formats: [service.rows[0].format],
            client: .init(defaultApplication: { _ in self.installed.url }, setDefault: { _, _ in writes += 1 }))
        current.refresh()
        XCTAssertTrue(try XCTUnwrap(current.rows.first).isCurrentApplication)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let otherURL = directory.appendingPathComponent("LacEditor.app")
        let contents = otherURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.koslaceditor.app"],
                                           format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let other = FileAssociationService(identity: installed, formats: [service.rows[0].format],
            client: .init(defaultApplication: { _ in otherURL }, setDefault: { _, _ in writes += 1 }))
        other.refresh()
        XCTAssertEqual(other.rows[0].applicationName, "LacEditor" + L10n.tr("（其他位置）"))
        XCTAssertFalse(other.rows[0].isCurrentApplication)
        XCTAssertEqual(writes, 0)
    }

    func testExplicitChangeTouchesOnlySelectedContentTypeAndReadsBack() async throws {
        let formats = FileAssociationFormat.catalog(extensions: ["txt", "json"])
        var defaults: [String: URL] = [:]
        var writes: [String] = []
        let service = FileAssociationService(identity: installed, formats: formats,
            client: .init(defaultApplication: { defaults[$0.identifier] }, setDefault: { url, type in
                XCTAssertEqual(url, self.installed.url)
                writes.append(type.identifier)
                defaults[type.identifier] = url
            }))
        service.refresh()
        XCTAssertTrue(writes.isEmpty)
        await service.setDefault(for: formats[0].id)
        XCTAssertEqual(writes, [formats[0].id])
        XCTAssertTrue(service.rows[0].isCurrentApplication)
        XCTAssertFalse(service.rows[1].isCurrentApplication)
        XCTAssertEqual(service.message, L10n.tr("已将 %@ 的默认打开应用设为 LacEditor。", formats[0].title))
        XCTAssertNil(service.changingID)
    }

    func testFailureOrUnconfirmedSystemChangeNeverClaimsSuccess() async {
        struct Denied: LocalizedError { var errorDescription: String? { "用户取消" } }
        let format = FileAssociationFormat.catalog(extensions: ["txt"])[0]
        for fails in [true, false] {
            let service = FileAssociationService(identity: installed, formats: [format],
                client: .init(defaultApplication: { _ in nil }, setDefault: { _, _ in if fails { throw Denied() } }))
            await service.setDefault(for: format.id)
            XCTAssertNil(service.changingID)
            XCTAssertFalse(service.rows[0].isCurrentApplication)
            XCTAssertNotEqual(service.message, L10n.tr("已将 %@ 的默认打开应用设为 LacEditor。", format.title))
            XCTAssertEqual(service.message, fails ? L10n.tr("未更改默认应用：%@", "用户取消") : L10n.tr("系统尚未应用更改，请确认系统提示后点击「刷新状态」。"))
        }
    }

    func testRestrictedCopyOrNonTextTypeCannotCallSystemSetter() async throws {
        let video = FileAssociationFormat(type: try XCTUnwrap(UTType("public.mpeg-2-transport-stream")), extensions: ["ts"])
        var writes = 0
        let client = FileAssociationService.Client(defaultApplication: { _ in nil }, setDefault: { _, _ in writes += 1 })
        let service = FileAssociationService(identity: installed, formats: [video], client: client)
        await service.setDefault(for: video.id)
        let copy = FileAssociationService(identity: .init(url: URL(fileURLWithPath: "/tmp/LacEditor.app"),
            identifier: installed.identifier, declaresAssociations: true), client: client)
        await copy.setDefault(for: UTType.plainText.identifier)
        XCTAssertEqual(writes, 0)
        XCTAssertNil(service.changingID)
        XCTAssertNil(copy.changingID)
    }

    func testInFlightChangeRejectsRepeatedRequests() async throws {
        let formats = FileAssociationFormat.catalog(extensions: ["txt", "json"])
        var continuation: CheckedContinuation<Void, Never>?
        var writes = 0
        let service = FileAssociationService(identity: installed, formats: formats,
            client: .init(defaultApplication: { _ in nil }, setDefault: { _, _ in
                writes += 1
                await withCheckedContinuation { continuation = $0 }
            }))
        let task = Task { await service.setDefault(for: formats[0].id) }
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(service.changingID, formats[0].id)
        await service.setDefault(for: formats[1].id)
        XCTAssertEqual(writes, 1)
        continuation?.resume()
        await task.value
        XCTAssertNil(service.changingID)
    }
}
