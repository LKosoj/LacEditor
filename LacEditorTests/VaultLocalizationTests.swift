import XCTest
@testable import LacEditor

/// Только Mac: каталоги читаются по `#filePath`.
final class VaultLocalizationTests: XCTestCase {
    private func block(_ language: String, stage: Int = 2) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let marker = try XCTUnwrap(text.range(of: "/* Режим хранилища: этап \(stage) */"))
        let rest = text[marker.upperBound...]
        let body = rest.range(of: "/*").map { rest[..<$0.lowerBound] } ?? rest
        var result: [String: String] = [:]
        for line in body.split(separator: "\n") {
            let parts = line.components(separatedBy: "\" = \"")
            guard parts.count == 2 else { continue }
            result[String(parts[0].dropFirst())] = String(parts[1].dropLast(2))
        }
        return result
    }

    private func placeholders(_ text: String) -> [String] {
        text.components(separatedBy: "%").dropFirst().compactMap { $0.first.map { "%\($0)" } }
    }

    func testConnectionTextsExistInAllCatalogs() throws { try checkBlock(stage: 2) }

    func testCaptureAndAskTextsExistInAllCatalogs() throws { try checkBlock(stage: 7) }

    func testVaultModeTextsExistInAllCatalogs() throws { try checkBlock(stage: 4) }

    func testSearchTextsExistInAllCatalogs() throws { try checkBlock(stage: 9) }

    func testVaultInspectorTextsExistInAllCatalogs() throws { try checkBlock(stage: 6) }

    func testVaultUploadTextsExistInAllCatalogs() throws { try checkBlock(stage: 5) }

    private func checkBlock(stage: Int) throws {
        let zh = try block("zh-Hans", stage: stage)
        let en = try block("en", stage: stage)
        let ru = try block("ru", stage: stage)
        XCTAssertFalse(zh.isEmpty)
        XCTAssertEqual(Set(zh.keys), Set(en.keys))
        XCTAssertEqual(Set(zh.keys), Set(ru.keys))
        for key in zh.keys {
            XCTAssertFalse(en[key]?.isEmpty ?? true, key)
            XCTAssertFalse(ru[key]?.isEmpty ?? true, key)
            XCTAssertEqual(placeholders(key), placeholders(en[key] ?? ""), key)
            XCTAssertEqual(placeholders(key), placeholders(ru[key] ?? ""), key)
        }
    }
}
