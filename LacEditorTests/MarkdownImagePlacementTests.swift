import AppKit
import XCTest
@testable import LacEditor

/// Логика места нового изображения: решение по состоянию документа, имена, запись рядом с документом, уменьшение.
@MainActor
final class MarkdownImagePlacementTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func testDecisionForEachDocumentState() {
        let url = URL(fileURLWithPath: "/tmp/Заметка.md")
        XCTAssertEqual(MarkdownImagePlacement.decision(documentURL: nil, isVaultNote: false, remembered: nil), .embedWithoutQuestion)
        XCTAssertEqual(MarkdownImagePlacement.decision(documentURL: nil, isVaultNote: false, remembered: .besideDocument), .embedWithoutQuestion)
        XCTAssertEqual(MarkdownImagePlacement.decision(documentURL: url, isVaultNote: true, remembered: .besideDocument), .embedWithoutQuestion)
        XCTAssertEqual(MarkdownImagePlacement.decision(documentURL: url, isVaultNote: false, remembered: nil), .ask(remembered: nil))
        XCTAssertEqual(MarkdownImagePlacement.decision(documentURL: url, isVaultNote: false, remembered: .embedded), .ask(remembered: .embedded))
    }

    func testAssetsFolderDropsDocumentExtension() {
        let base = URL(fileURLWithPath: "/tmp/Папка с пробелом", isDirectory: true)
        let cases = [("Заметка.md", "Заметка.assets"), ("my note.md", "my note.assets"), ("a.b.md", "a.b.assets"),
                     ("文档 😀.md", "文档 😀.assets"), ("README", "README.assets")]
        for (name, expected) in cases {
            let folder = MarkdownImagePlacement.assetsFolder(for: base.appendingPathComponent(name))
            XCTAssertEqual(folder.lastPathComponent, expected, name)
            XCTAssertEqual(folder.deletingLastPathComponent().path, base.path, name)
        }
    }

    func testFileNameUsesTimestampExtensionAndNumber() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        XCTAssertEqual(MarkdownImagePlacement.fileName(now: now, fileExtension: "png", suffix: nil), "image-\(stamp).png")
        XCTAssertEqual(MarkdownImagePlacement.fileName(now: now, fileExtension: "jpeg", suffix: nil), "image-\(stamp).jpg")
        XCTAssertEqual(MarkdownImagePlacement.fileName(now: now, fileExtension: "JPG", suffix: 2), "image-\(stamp)-2.jpg")
    }

    func testSaveCreatesFolderForCyrillicDocumentWithSpaces() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("Моя заметка.md")
        let bytes = Data([1, 2, 3])
        let saved = try MarkdownImagePlacement.save(bytes, fileExtension: "png", nextTo: documentURL)
        XCTAssertEqual(saved.deletingLastPathComponent().lastPathComponent, "Моя заметка.assets")
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        XCTAssertNotNil(saved.lastPathComponent.range(of: #"^image-\d{8}-\d{6}\.png$"#, options: .regularExpression))
    }

    func testSaveWithSameNameGetsNumberAndKeepsFirstFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("note.md")
        let now = Date()
        let first = try MarkdownImagePlacement.save(Data([1]), fileExtension: "png", nextTo: documentURL, now: now)
        let second = try MarkdownImagePlacement.save(Data([2]), fileExtension: "png", nextTo: documentURL, now: now)
        let third = try MarkdownImagePlacement.save(Data([3]), fileExtension: "png", nextTo: documentURL, now: now)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-2.png"))
        XCTAssertTrue(third.lastPathComponent.hasSuffix("-3.png"))
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
        XCTAssertEqual(try Data(contentsOf: third), Data([3]))
    }

    func testSaveFailsWhenFolderNameIsOccupiedByFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("note.md")
        try Data().write(to: directory.appendingPathComponent("note.assets"))
        XCTAssertThrowsError(try MarkdownImagePlacement.save(Data([1]), fileExtension: "png", nextTo: documentURL))
        var isDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("note.assets").path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

    func testDataAddressBuildsBase64URI() {
        XCTAssertEqual(MarkdownImagePlacement.dataAddress(Data([1, 2]), mime: "image/png"), "data:image/png;base64,AQI=")
    }

    func testPreferencesRememberAndForgetChoicePerDocument() throws {
        let suite = "MarkdownImagePlacementTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let first = URL(fileURLWithPath: "/tmp/Папка/Заметка 1.md"), second = URL(fileURLWithPath: "/tmp/Папка/Заметка 2.md")
        XCTAssertNil(preferences.markdownImagePlacement(for: first))
        preferences.setMarkdownImagePlacement(.embedded, for: first)
        preferences.setMarkdownImagePlacement(.besideDocument, for: second)
        XCTAssertEqual(preferences.markdownImagePlacement(for: first), .embedded)
        XCTAssertEqual(preferences.markdownImagePlacement(for: second), .besideDocument)
        XCTAssertEqual(AppPreferences(defaults: defaults).markdownImagePlacement(for: first), .embedded)
        preferences.setMarkdownImagePlacement(nil, for: first)
        XCTAssertNil(preferences.markdownImagePlacement(for: first))
        XCTAssertEqual(preferences.markdownImagePlacement(for: second), .besideDocument)
    }

    func testPlacementTextsExistInAllCatalogs() throws {
        let keys = ["图片位置", "保存在文档旁边", "嵌入文档", "记住此文档的选择", "无法保存图片：%@"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, "\(language): \(key)")
            }
        }
    }

    // MARK: Уменьшение

    private func makeImage(width: Int, height: Int, transparent: Bool) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // Заполняем буфер напрямую: поэлементный setColor на 3000x1500 слишком медленный.
        let data = try XCTUnwrap(rep.bitmapData)
        for y in 0..<height {
            let row = data + y * rep.bytesPerRow
            for x in 0..<width {
                let half = transparent && x < width / 2
                row[x * 4] = half ? 64 : 255; row[x * 4 + 1] = 0; row[x * 4 + 2] = 0; row[x * 4 + 3] = half ? 128 : 255
            }
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func size(of data: Data) throws -> (Int, Int) {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    func testReducerShrinksLongSideAndWritesJPEGForOpaqueImage() throws {
        let source = try makeImage(width: 3000, height: 1500, transparent: false)
        let reduced = try XCTUnwrap(MarkdownImageReducer.reduced(source))
        let (width, height) = try size(of: reduced)
        XCTAssertEqual(width, 2048)
        XCTAssertEqual(height, 1024)
        XCTAssertEqual(Array(reduced.prefix(3)), [0xFF, 0xD8, 0xFF], "ожидался JPEG")
    }

    func testReducerKeepsPNGWhenImageHasTransparency() throws {
        let reduced = try XCTUnwrap(MarkdownImageReducer.reduced(try makeImage(width: 40, height: 20, transparent: true)))
        XCTAssertEqual(Array(reduced.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "ожидался PNG")
    }

    func testReducerDoesNotUpscaleSmallImage() throws {
        let reduced = try XCTUnwrap(MarkdownImageReducer.reduced(try makeImage(width: 100, height: 50, transparent: false)))
        let (width, height) = try size(of: reduced)
        XCTAssertEqual(width, 100)
        XCTAssertEqual(height, 50)
    }

    func testReducerReturnsNilForNonImage() {
        XCTAssertNil(MarkdownImageReducer.reduced(Data([1, 2, 3, 4])))
    }
}
