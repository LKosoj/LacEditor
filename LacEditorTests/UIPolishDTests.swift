import XCTest
@testable import LacEditor

/// Страницы AI-настроек: общий стиль строк, пустые состояния, сообщение о сброшенном ключе.
final class UIPolishDTests: XCTestCase {
    private let files = [
        "AISettingsView.swift", "AIFeatureSettingsView.swift", "AICustomChecksSettingsView.swift",
        "JinaSettingsView.swift", "FileAssociationSettingsView.swift"
    ]

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor/Views").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testStatusNoticeOnlyForNonEmptyDraft() {
        XCTAssertNil(AIKeyDraftNotice.message(forClearedDraft: ""))
        let notice = AIKeyDraftNotice.message(forClearedDraft: "abc")
        XCTAssertEqual(notice?.kind, .info)
        XCTAssertEqual(notice?.text, L10n.tr("密钥与服务地址绑定，地址已更改，未保存的密钥输入已清除。"))
    }

    func testEmptyAddressShownAsNotSet() {
        XCTAssertEqual(AIFeatureSettingsView.displayedValue(""), L10n.tr("未设置"))
        XCTAssertEqual(AIFeatureSettingsView.displayedValue("  "), L10n.tr("未设置"))
        XCTAssertEqual(AIFeatureSettingsView.displayedValue("https://x"), "https://x")
    }

    func testCustomChecksEmptyState() {
        XCTAssertEqual(AICustomChecksSettingsView.emptyStateText(isEmpty: true),
                       L10n.tr("尚未添加自定义检查。添加后可用自己的说明检查文档。"))
        XCTAssertNil(AICustomChecksSettingsView.emptyStateText(isEmpty: false))
    }

    func testAISettingsViewsUseCommonPreferenceStyle() throws {
        for name in files {
            let text = try source(name)
            XCTAssertFalse(text.contains("LabeledContent"), name)
            XCTAssertFalse(text.contains(".font(.title3"), name)
            XCTAssertFalse(text.contains(".font(.headline)"), name)
            if name != "JinaSettingsView.swift" || text.contains("PreferenceGroup(") {
                XCTAssertTrue(text.contains("PreferenceGroup("), name)
            }
        }
    }

    func testFieldsHaveAccessibilityLabels() throws {
        XCTAssertTrue(try source("AIFeatureSettingsView.swift")
            .contains(".accessibilityLabel(L10n.tr(\"功能模型名称（留空使用默认值）\"))"))
        let checks = try source("AICustomChecksSettingsView.swift")
        XCTAssertTrue(checks.contains(".accessibilityLabel(L10n.tr(\"检查名称\"))"))
        XCTAssertTrue(checks.contains(".accessibilityLabel(L10n.tr(\"检查模型（留空使用功能模型）\"))"))
        XCTAssertTrue(try source("JinaSettingsView.swift").contains("API 密钥\"))\")"))
    }

    func testIdentifiersPreserved() throws {
        XCTAssertTrue(try source("AISettingsView.swift").contains("settings.ai.page"))
        XCTAssertTrue(try source("FileAssociationSettingsView.swift").contains("associations.result"))
    }

    func testKeyDraftClearedBeforeNoticeOrder() throws {
        for name in ["AISettingsView.swift", "JinaSettingsView.swift"] {
            let text = try source(name)
            let notice = try XCTUnwrap(text.range(of: "AIKeyDraftNotice.message("), name)
            let refresh = try XCTUnwrap(text.range(of: "refreshKey()", range: notice.upperBound..<text.endIndex), name)
            let apply = try XCTUnwrap(text.range(of: "if let notice", range: notice.upperBound..<text.endIndex), name)
            XCTAssertLessThan(refresh.lowerBound, apply.lowerBound, name)
        }
    }
}
