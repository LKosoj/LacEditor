import XCTest
@testable import LacEditor

final class MarkdownDataMediaTests: XCTestCase {
    private let bytes = Data((0..<300).map { UInt8($0 % 256) })

    func testBase64WithLineBreaksAndParameters() throws {
        let base64 = bytes.base64EncodedString()
        var wrapped = "", index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 60, limitedBy: base64.endIndex) ?? base64.endIndex
            wrapped += base64[index..<end] + "\r\n  "
            index = end
        }
        let mp3 = try XCTUnwrap(MarkdownDataMedia.parse("data:audio/mpeg;base64," + wrapped))
        XCTAssertEqual(mp3.data, bytes)
        XCTAssertEqual(mp3.fileExtension, "mp3")
        XCTAssertEqual(MarkdownDataMedia.parse("DATA:Application/PDF;charset=utf-8;base64," + base64)?.data, bytes)
        XCTAssertEqual(MarkdownDataMedia.parse("data:application/pdf;base64," + base64.replacingOccurrences(of: "=", with: ""))?.data, bytes)
        XCTAssertEqual(MarkdownDataMedia.parse("data:video/mp4;base64," + base64 + "#part")?.data, bytes)
    }

    func testPercentEncodingAndUnknownTypes() {
        XCTAssertEqual(MarkdownDataMedia.parse("data:video/mp4,%00%FFab%20c")?.data, Data([0, 255, 97, 98, 32, 99]))
        XCTAssertNil(MarkdownDataMedia.parse("data:audio/wav;base64,AA==#lac-media-1234"))
        for address in ["data:text/html,<b>x</b>", "data:image/svg+xml,x", "data:application/x-msdownload;base64,AA==", "https://a.example/a.pdf"] {
            XCTAssertNil(MarkdownDataMedia.parse(address), address)
            XCTAssertNil(MarkdownDataMedia.fileExtension(forAddress: address), address)
        }
    }

    func testTemporaryFilesAreReusedAndRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lac-media-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MarkdownTemporaryMedia(documentID: UUID(), root: root)
        let address = "data:application/pdf;base64," + bytes.base64EncodedString()
        let file = try XCTUnwrap(try media.fileURL(forAddress: address))
        XCTAssertEqual(file.pathExtension, "pdf")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
        XCTAssertEqual(try media.fileURL(forAddress: address), file)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, Date(timeIntervalSince1970: 1000))
        XCTAssertNil(try media.fileURL(forAddress: "data:text/html,x"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).count, 1)
        media.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertNil(try media.fileURL(forAddress: address))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testStartupAndExitCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lac-media-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try MarkdownTemporaryMedia(documentID: UUID(), root: root).fileURL(forAddress: "data:audio/ogg,abc")
        // Каталог несуществующего процесса удаляется, свой остаётся.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2147483646"), withIntermediateDirectories: true)
        MarkdownTemporaryMedia.removeStale(root: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [String(getpid())])
        MarkdownTemporaryMedia.removeEverything(root: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testEmbeddedPDFOnlyFromDataAddress() {
        let pdf = "data:application/pdf;base64,JVBERi0="
        let embed = MarkdownHTMLMediaService.embeddedMedia(in: "<embed src=\"\(pdf)\" type=\"application/pdf\" width=\"400\" height=\"300\">")
        XCTAssertEqual(embed?.kind, .pdf)
        XCTAssertEqual(embed?.sources, [pdf])
        XCTAssertEqual(embed?.width, "400")
        XCTAssertEqual(MarkdownHTMLMediaService.embeddedMedia(in: "<object data=\"\(pdf)\" width=\"50%\"></object>")?.kind, .pdf)
        XCTAssertEqual(MarkdownHTMLMediaService.embeddedMedia(in: "<iframe src=\"\(pdf)\"></iframe>")?.kind, .pdf)
        for html in ["<embed src=\"https://e.example/a.pdf\">", "<object data=\"a.pdf\"></object>", "<object data=\"data:text/html,x\"></object>",
                     "<iframe src=\"https://e.example/\"></iframe>", "<embed src=\"\(pdf)\" type=\"text/html\">",
                     "<object data=\"\(pdf)\">fallback</object>"] {
            XCTAssertNil(MarkdownHTMLMediaService.embeddedMedia(in: html), html)
        }
        XCTAssertNil(MarkdownHTMLMediaService.iframe(in: "<iframe src=\"\(pdf)\"></iframe>"))
    }

    func testDataLinkDestinationOnlyForWhitelist() throws {
        XCTAssertEqual(try MarkdownLinkNavigationService.destination(for: "data:application/pdf;base64,JVBERi0=", documentURL: nil),
                       .data("data:application/pdf;base64,JVBERi0="))
        XCTAssertThrowsError(try MarkdownLinkNavigationService.destination(for: "data:text/html,x", documentURL: nil))
    }

    func testInlineEmbedGivesPDFBlock() throws {
        let pdf = "data:application/pdf;base64,JVBERi0="
        let source = "до <embed src=\"\(pdf)\" type=\"application/pdf\" width=\"400\"> после"
        let block = try XCTUnwrap(MarkdownPresentationBuilder.parse(source).audioBlocks.first)
        XCTAssertEqual(block.media.kind, .pdf)
        XCTAssertEqual(block.media.sources, [pdf])
        XCTAssertTrue(block.isInline)
        XCTAssertEqual((source as NSString).substring(with: block.range).hasPrefix("<embed"), true)
        XCTAssertTrue(MarkdownPresentationBuilder.parse("до <embed src=\"https://e.example/a.pdf\"> после").audioBlocks.isEmpty)
        let alone = MarkdownPresentationBuilder.parse("<embed src=\"\(pdf)\">").audioBlocks
        XCTAssertEqual(alone.count, 1, "отдельный блок не задваивается")
    }
}
