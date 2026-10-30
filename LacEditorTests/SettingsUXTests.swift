import Foundation
import XCTest
@testable import LacEditor

final class SettingsUXTests: XCTestCase {
    func testFeatureGroupsCoverEveryFeatureExactlyOnce() {
        let grouped = AIFeatureGroup.allCases.flatMap { AIFeature.features(in: $0) }
        XCTAssertEqual(grouped.count, AIFeature.allCases.count)
        XCTAssertEqual(Set(grouped), Set(AIFeature.allCases))
        for group in AIFeatureGroup.allCases { XCTAssertFalse(AIFeature.features(in: group).isEmpty) }
    }

    func testStatusKindsAreDistinct() {
        XCTAssertEqual(Set([StatusKind.error, .success, .info].map(\.symbol)).count, 3)
        XCTAssertEqual(StatusKind.error.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(StatusKind.success.symbol, "checkmark.circle.fill")
        XCTAssertFalse(StatusKind.error.accessibilityPrefix.isEmpty)
        XCTAssertTrue(StatusKind.info.accessibilityPrefix.isEmpty)
    }

    func testSearchEmptyQueryReturnsAllSections() {
        XCTAssertEqual(SettingsSearch.sections(matching: "  ", localize: { $0 }), SettingsSection.allCases)
    }

    func testSearchMatchesRowTitleAndSectionTitle() {
        XCTAssertEqual(SettingsSearch.sections(matching: "纸张", localize: { $0 }), [.export])
        XCTAssertTrue(SettingsSearch.sections(matching: "导出", localize: { $0 }).contains(.export))
        XCTAssertTrue(SettingsSearch.sections(matching: "zzzz", localize: { $0 }).isEmpty)
    }

    func testSearchUsesLocalizedTitlesInAllLanguages() throws {
        let name = "LacEditor.SettingsUXTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); L10n.configure() }
        for language in ["zh-Hans", "en", "ru"] {
            defaults.set(language, forKey: L10n.languageKey)
            L10n.configure(defaults: defaults)
            XCTAssertTrue(SettingsSearch.sections(matching: L10n.tr("PDF 页眉")).contains(.export), language)
            XCTAssertTrue(SettingsSearch.sections(matching: L10n.tr("文字字体")).contains(.editor), language)
        }
    }

    func testEverySearchKeyAndNewKeyExistsInAllCatalogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor")
        let keys = Set(SettingsSection.allCases.flatMap(\.searchKeys)).union([
            "文本编辑", "分析与检查", "图片、语音与图表", "连接", "AI 设置分区", "搜索设置", "没有匹配的设置", "打开 AI 设置", "正在录音"
        ])
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
            for key in keys {
                XCTAssertNotNil(catalog[key], "\(language): \(key)")
            }
        }
    }

    func testEveryAIFeatureHasDescription() {
        var pairs = AIFeature.allCases.map { ($0.title, $0.needs, $0.result, $0.detail) }
        pairs += AIRewriteMode.allCases.map { ($0.title, $0.needs, $0.result, $0.detail) }
        for (_, needs, result, detail) in pairs {
            XCTAssertFalse(needs.isEmpty)
            XCTAssertFalse(result.isEmpty)
            XCTAssertNotEqual(needs, result)
            XCTAssertTrue(detail.contains(needs) && detail.contains(result))
        }
    }
}
