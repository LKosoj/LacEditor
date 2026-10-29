import XCTest
@testable import LacEditor

/// Проход по настройкам: id строк, скрытие полей, подписи, единицы и пороги, единый вид многострочных полей.
final class UIPolishHTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LacEditor/Views").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let taskFiles = [
        "SettingsView.swift", "AISettingsView.swift", "AIFeatureSettingsView.swift",
        "AICustomChecksSettingsView.swift", "JinaSettingsView.swift", "FileAssociationSettingsView.swift"
    ]

    func testPreferenceRowHasSearchIDAndHint() throws {
        let design = try source("LacEditorDesign.swift")
        XCTAssertTrue(design.contains("let searchID: String?"))
        XCTAssertTrue(design.contains(".id(searchID)"))
        XCTAssertTrue(design.contains(".accessibilityHint(detail)"))
        XCTAssertFalse(design.contains(".id(title)"))
    }

    func testRepeatedRowsDoNotUseTitleAsID() throws {
        let ai = try source("AISettingsView.swift")
        XCTAssertGreaterThanOrEqual(ai.components(separatedBy: "searchID: rowID(").count - 1, 5)
        XCTAssertTrue(try source("JinaSettingsView.swift").contains("searchID: ownsSearchID ?"))
        let checks = try source("AICustomChecksSettingsView.swift")
        let range = try XCTUnwrap(checks.range(of: "PreferenceRow(title: L10n.tr(\"自定义检查\")"))
        XCTAssertTrue(checks[range.lowerBound...].prefix(300).contains("searchID: nil"))
    }

    func testJinaHidesFieldsWhenDisabled() throws {
        let jina = try source("JinaSettingsView.swift")
        let gate = try XCTUnwrap(jina.range(of: "if enabled.wrappedValue"))
        let address = try XCTUnwrap(jina.range(of: "L10n.tr(\"完整接口地址\")"))
        XCTAssertLessThan(gate.lowerBound, address.lowerBound)
        let change = try XCTUnwrap(jina.range(of: ".onChange(of: enabled.wrappedValue)"))
        XCTAssertTrue(jina[change.lowerBound...].prefix(120).contains("keyDraft = \"\""))
    }

    func testFeatureModelFetchDisabledWithoutRole() throws {
        let feature = try source("AIFeatureSettingsView.swift")
        let button = try XCTUnwrap(feature.range(of: "Button(L10n.tr(\"获取模型列表\"), action: fetchModels)"))
        XCTAssertTrue(feature[button.lowerBound...].prefix(200).contains(".disabled(modelTask != nil || !isActive || !roleProfile.isEnabled)"))
        let label = "ProgressView().controlSize(.small).accessibilityLabel("
        XCTAssertEqual(feature.components(separatedBy: label).count - 1, 1)
        XCTAssertEqual(try source("AISettingsView.swift").components(separatedBy: label).count - 1, 1)
    }

    func testExportSearchKeysIncludeProfileFields() {
        let keys = ["扩展名，以空格分隔", "自定义命令", "命令输出", "显示命令输出", "PDF 中间格式", "PDF 引擎路径", "额外参数",
                    "Pandoc 输出格式", "原始类型", "模板", "样式参考文件", "EPUB 封面", "EPUB 目录深度"]
        for key in keys { XCTAssertTrue(SettingsSection.export.searchKeys.contains(key), key) }
        XCTAssertEqual(SettingsSearch.sections(matching: "EPUB 封面", localize: { $0 }), [.export])
        XCTAssertTrue(SettingsSearch.sections(matching: "模板", localize: { $0 }).contains(.export))
    }

    func testSearchEscapeClearsQuery() throws {
        XCTAssertTrue(try source("SettingsView.swift").contains(".onExitCommand { if !query.isEmpty { query = \"\" } }"))
    }

    func testNoHardcodedUnitsOrThresholds() throws {
        let settings = try source("SettingsView.swift")
        XCTAssertFalse(settings.contains(") pt\""))
        XCTAssertFalse(settings.contains("\"超过 20 MB"))
        XCTAssertFalse(settings.contains("\"50 MB 以上\""))
        XCTAssertTrue(settings.contains("DocumentPerformanceProfile.largeFileByteThreshold"))
        XCTAssertEqual(DocumentPerformanceProfile.largeFileByteThreshold / (1_024 * 1_024), 20)
        XCTAssertEqual(DocumentPerformanceProfile.extremeFileByteThreshold / (1_024 * 1_024), 50)
        XCTAssertEqual(DocumentPerformanceProfile.largeFileLineThreshold, 250_000)
    }

    func testFormattedSettingsStrings() {
        XCTAssertTrue(L10n.tr("%d pt", 14).contains("14"))
        let text = L10n.tr("超过 %d MB 或 %@ 行时自动启用，暂停换行、预览、折叠和实时字数统计。", 20, "250,000")
        XCTAssertTrue(text.contains("20"))
        XCTAssertTrue(text.contains("250,000"))
    }

    func testNoDottedL10nKeysInSettings() throws {
        for name in taskFiles { XCTAssertFalse(try source(name).contains("L10n.tr(\"markdown."), name) }
    }

    func testMultilineFieldsShareOneModifier() throws {
        XCTAssertTrue(try source("SettingsView.swift").contains("func settingsMultilineField(minHeight:"))
        for name in taskFiles {
            let lines = try source(name).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("TextEditor(") {
                let window = lines[index..<min(index + 3, lines.count)].joined(separator: "\n")
                XCTAssertTrue(window.contains("settingsMultilineField"), "\(name):\(index + 1)")
            }
        }
        XCTAssertFalse(try source("AICustomChecksSettingsView.swift").contains(".border("))
    }

    func testAssociationButtonHasHelpReason() throws {
        let source = try source("FileAssociationSettingsView.swift")
        let disabled = try XCTUnwrap(source.range(of: ".disabled(disabledReason != nil)"))
        XCTAssertTrue(source[disabled.lowerBound...].prefix(80).contains(".help("))
    }
}
