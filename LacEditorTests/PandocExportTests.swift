import Foundation
import XCTest
@testable import LacEditor

@MainActor
final class PandocExportTests: XCTestCase {
    func testLiveSnapshotDoesNotChangeSourceOrDirtyState() throws {
        let document = EditorDocument(text: "old", language: .markdown)
        document.attachLiveTextProvider(id: UUID(), provider: { "новый 中文 😀" }, acknowledgement: { _ in })
        document.noteLiveEdit(isEmpty: false)
        let snapshot = document.synchronizedSnapshot()
        XCTAssertEqual(snapshot.text, "новый 中文 😀")
        XCTAssertTrue(document.isDirty)
        XCTAssertNil(document.url)
    }

    func testConflictsIncludeSourceOtherOpenFilesAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.md")
        let other = directory.appendingPathComponent("other.txt")
        let link = directory.appendingPathComponent("link.txt")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "other".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertTrue(PandocExportService.conflicts(destination: source, source: source, openURLs: []))
        XCTAssertTrue(PandocExportService.conflicts(destination: link, source: source, openURLs: [other]))
        XCTAssertFalse(PandocExportService.conflicts(destination: directory.appendingPathComponent("new.html"), source: source, openURLs: [other]))
    }

    func testProcessFailurePreservesDestinationAndReturnsDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("pandoc")
        let destination = directory.appendingPathComponent("result.html")
        try "#!/bin/sh\nprintf 'conversion failed' >&2\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PandocExportService.prepare(text: "new", source: nil, destination: destination, format: .html, title: "Document", executable: executable)) { error in
            XCTAssertTrue(error.localizedDescription.contains("conversion failed"))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
    }

    func testInstallReplacesExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.html")
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        let replacementDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true
        )
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let prepared = replacementDirectory.appendingPathComponent("output.html")
        try "new".write(to: prepared, atomically: true, encoding: .utf8)
        try PandocExportService.install(prepared, at: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
    }

    func testHTMLIncludesRelativeImageAndDocumentTitle() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = directory.appendingPathComponent("source folder")
        let outputDirectory = directory.appendingPathComponent("output folder")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        try image.write(to: sourceDirectory.appendingPathComponent("image file.png"))
        let source = sourceDirectory.appendingPathComponent("original.md")
        let destination = outputDirectory.appendingPathComponent("result.html")
        let result = try PandocExportService.prepare(
            text: "![image](image%20file.png)", source: source, destination: destination,
            format: .html, title: "Название $ test", executable: executable
        )
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let html = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertTrue(html.contains("<title>Название $ test</title>"))
    }

    func testRealPandocExportsSnapshot() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.html")
        let result = try PandocExportService.prepare(text: "# 中文 😀\n\n| a | b |\n|---|---|\n| 1 | 2 |", source: nil, destination: destination, format: .html, title: "Document", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        try PandocExportService.install(result.preparedURL, at: destination)
        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Document</title>"))
        XCTAssertTrue(html.contains("中文 😀"))
        XCTAssertTrue(html.contains("<table>"))
    }

    func testRealPandocExportsFB2() throws {
        let executable = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.fb2")
        let result = try PandocExportService.prepare(text: "# 中文 😀\n\nText", source: nil, destination: destination, format: .fb2, title: "Document", executable: executable)
        defer { try? FileManager.default.removeItem(at: result.preparedURL.deletingLastPathComponent()) }
        let fb2 = try String(contentsOf: result.preparedURL, encoding: .utf8)
        XCTAssertTrue(fb2.contains("<FictionBook"))
        XCTAssertTrue(fb2.contains("中文 😀"))
    }
}
