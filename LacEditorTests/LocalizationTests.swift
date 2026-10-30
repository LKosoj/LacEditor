import Foundation
import XCTest
@testable import LacEditor

final class LocalizationTests: XCTestCase {
    func testLanguageSelectionAndFallback() {
        XCTAssertEqual(L10n.resolvedLanguage(selection: "ru", preferredLanguages: ["en-US"]), "ru")
        XCTAssertEqual(L10n.resolvedLanguage(selection: "system", preferredLanguages: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.resolvedLanguage(selection: "system", preferredLanguages: ["ru-RU"]), "ru")
        XCTAssertEqual(L10n.resolvedLanguage(selection: "system", preferredLanguages: ["fr-FR"]), "en")
    }

    func testSelectionIsPersistedAndUsedAtStartup() throws {
        let name = "LacEditor.LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); L10n.configure() }
        L10n.configure(defaults: defaults)
        let previous = L10n.tr("设置")
        L10n.saveLanguageSelection("ru", defaults: defaults)
        XCTAssertEqual(L10n.tr("设置"), previous)
        L10n.configure(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: L10n.languageKey), "ru")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ru"])
        XCTAssertEqual(L10n.tr("设置"), "Настройки")
        L10n.saveLanguageSelection("system", defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
    }

    func testAIFeatureAndRewriteTextsExistInAllCatalogs() throws {
        let name = "LacEditor.LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); L10n.configure() }
        defaults.set("zh-Hans", forKey: L10n.languageKey)
        L10n.configure(defaults: defaults)
        let keys = AIFeature.allCases.flatMap { [$0.title, $0.needs, $0.result] }
            + AIRewriteMode.allCases.flatMap { [$0.title, $0.needs, $0.result] }
            + [AIError.truncated.errorDescription ?? ""]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys where !key.isEmpty {
                XCTAssertNotNil(catalog[key], "\(language): \(key)")
            }
        }
    }

    func testFormattedStringsAndMessagePrefixes() throws {
        let name = "LacEditor.LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); L10n.configure() }
        for language in ["zh-Hans", "en", "ru"] {
            defaults.set(language, forKey: L10n.languageKey)
            L10n.configure(defaults: defaults)
            XCTAssertTrue(L10n.tr("已替换 1 处").hasPrefix(L10n.tr("已替换")))
            XCTAssertTrue(L10n.tr("已替换 %@ 处", "3").hasPrefix(L10n.tr("已替换")))
            XCTAssertTrue(L10n.tr("当前文档：%@", "example").contains("example"))
            let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad"])
            XCTAssertTrue(JSONFormatter.userFacingError(error, in: "{").hasPrefix(L10n.tr("JSON 无效")))
        }
    }
}
