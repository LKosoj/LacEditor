import Darwin
import Foundation
import XCTest
@testable import LacEditor

final class ClipboardMarkdownConversionTests: XCTestCase {
    func testHTMLClipboardPreservesEmbeddedSVG() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc())
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 2 2'/>".utf8)
        let uri = "data:image/svg+xml;base64," + svg.base64EncodedString()
        let html = Data("<p>before <img alt='diagram' src='\(uri)'> after</p>".utf8)
        let result = try ClipboardMarkdownConversionService.convert(html, format: .html, executable: pandoc)
        XCTAssertTrue(result.markdown.contains(uri))
    }
    func testRTFPictureCountRecognizesOnlyAdjacentFallbackPairs() {
        func count(_ text: String) -> Int? { ClipboardMarkdownConversionService.rtfPictureCount(Data(text.utf8)) }
        XCTAssertEqual(count(#"{\rtf1 {\*\shppict{\pict\pngblip ab}}{\nonshppict{\pict\pngblip cd}}}"#), 1)
        XCTAssertEqual(count(#"{\rtf1 {\pict x}{\pict y}}"#), 2)
        XCTAssertEqual(count(#"{\rtf1 literal \\pict \{ignored\} {\pict x}}"#), 1)
        XCTAssertEqual(count(#"{\rtf1 {\*\shppict{\pict x}} text {\nonshppict{\pict y}}}"#), 2)
        XCTAssertEqual(count(#"{\rtf1 {\*\shppict{\pict x}{\pict y}}{\nonshppict{\pict z}}}"#), 3)
        XCTAssertNil(count(#"{\rtf1 {\pict x}"#))
        XCTAssertNil(count(#"{\rtf1 \'zz}"#))
        XCTAssertNil(count(#"{\rtf1 {\pict\bin4 data}}"#))
        XCTAssertNil(ClipboardMarkdownConversionService.rtfPictureCount(Data(#"{\rtf1 {\pict x}}"#.utf8), isCancelled: { true }))
    }

    func testBundledRTFMediaIsCapturedBeforeTemporaryDirectoryIsRemoved() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc())
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        let hex = png.map { String(format: "%02x", $0) }.joined()
        let rtf = Data("{\\rtf1\\ansi before {\\pict\\pngblip \(hex)} between {\\pict\\pngblip \(hex)} after}".utf8)
        let result = try ClipboardMarkdownConversionService.convertRTFWithMedia(rtf, executable: pandoc)
        let images = try MarkdownClipboardCopyService.embeddedImages(in: result.markdown)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images.map(\.data), [png, png])
        XCTAssertEqual(images.map(\.mime), ["image/png", "image/png"])
        XCTAssertTrue(result.markdown.contains("before"))
        XCTAssertTrue(result.markdown.contains("between"))
        XCTAssertTrue(result.markdown.contains("after"))
        XCTAssertFalse(result.markdown.contains("media/"))
        let pair = Data("{\\rtf1 before {\\*\\shppict{\\pict\\pngblip \(hex)}}{\\nonshppict{\\pict\\pngblip \(hex)}} after}".utf8)
        XCTAssertEqual(ClipboardMarkdownConversionService.rtfPictureCount(pair), 1)
        let pairedResult = try ClipboardMarkdownConversionService.convertRTFWithMedia(pair, executable: pandoc)
        let pairedImages = try MarkdownClipboardCopyService.embeddedImages(in: pairedResult.markdown)
        XCTAssertEqual(pairedImages.map(\.data), [png])
        XCTAssertTrue(pairedResult.markdown.contains("before"))
        XCTAssertTrue(pairedResult.markdown.contains("after"))
        XCTAssertThrowsError(try ClipboardMarkdownConversionService.convertRTFWithMedia(rtf, executable: pandoc, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testRTFMediaRejectsSymlinkAndRemovesTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("directory")
        let executable = directory.appendingPathComponent("converter")
        let outside = directory.appendingPathComponent("outside.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"))
        try png.write(to: outside)
        let path = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let target = "'" + outside.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\npwd > \(path)\nmkdir media\nln -s \(target) media/image.png\nprintf '%s' '![x](media/image.png)'\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertThrowsError(try ClipboardMarkdownConversionService.convertRTFWithMedia(Data("x".utf8), executable: executable))
        let temporary = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary))
    }

    func testBundledPandocConvertsHTMLRTFAndDataURI() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc(), "Bundled Pandoc must be executable")
        let html = Data("<p>中文😀 <strong>bold</strong> <a href=\"https://example.com\">link</a></p><p><img alt=\"icon\" src=\"data:image/png;base64,iVBORw0KGgo=\"></p>".utf8)
        let result = try ClipboardMarkdownConversionService.convert(html, format: .html, executable: pandoc)
        XCTAssertTrue(result.markdown.contains("中文😀"))
        XCTAssertTrue(result.markdown.contains("**bold**"))
        XCTAssertTrue(result.markdown.contains("https://example.com"))
        XCTAssertTrue(result.markdown.contains("data:image/png;base64,iVBORw0KGgo="))
        let rtf = Data("{\\rtf1\\ansi \\b bold\\b0  text}".utf8)
        let rich = try ClipboardMarkdownConversionService.convert(rtf, format: .rtf, executable: pandoc)
        XCTAssertTrue(rich.markdown.contains("**bold**"))
        XCTAssertTrue(rich.markdown.contains("text"))
    }

    func testSandboxDoesNotReadLocalIframe() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appendingPathComponent("private.html")
        try "private-clipboard-fixture".write(to: secret, atomically: true, encoding: .utf8)
        let html = Data("<p>safe</p><iframe src=\"\(secret.absoluteString)\"></iframe>".utf8)
        let result = try ClipboardMarkdownConversionService.convert(html, format: .html, executable: pandoc)
        XCTAssertTrue(result.markdown.contains("safe"))
        XCTAssertFalse(result.markdown.contains("private-clipboard-fixture"))
    }

    func testLargeOutputAndFailure() throws {
        let pandoc = try XCTUnwrap(PandocExportService.findPandoc())
        let html = "<p>start " + String(repeating: "text ", count: 50_000) + "finish</p>"
        let result = try ClipboardMarkdownConversionService.convert(Data(html.utf8), format: .html, executable: pandoc)
        XCTAssertTrue(result.markdown.contains("start"))
        XCTAssertTrue(result.markdown.contains("finish"))
        XCTAssertThrowsError(try ClipboardMarkdownConversionService.convert(Data(), format: .html, executable: URL(fileURLWithPath: "/usr/bin/false"))) {
            guard case ClipboardMarkdownConversionService.ConversionError.failed = $0 else { return XCTFail("Expected conversion failure: \($0)") }
        }
        XCTAssertThrowsError(try ClipboardMarkdownConversionService.convert(Data(), format: .html, executable: pandoc, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCancellationTerminatesProcessAndCleansTemporaryDirectory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("pandoc-test")
        let marker = folder.appendingPathComponent("started")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\ntrap '' TERM\npwd > \(quoted)\necho $$ >> \(quoted)\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let task = Task.detached {
            try ClipboardMarkdownConversionService.convert(Data("text".utf8), format: .html, executable: script,
                                                           isCancelled: { Task.isCancelled })
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(5)
        var markerContents: [String] = []
        while markerContents.count < 2 && Date() < deadline {
            markerContents = (try? String(contentsOf: marker, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            if markerContents.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(markerContents.count, 2)
        let workingDirectory = try XCTUnwrap(markerContents.first)
        let pid = try XCTUnwrap(markerContents.last.flatMap { Int32($0) })
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
