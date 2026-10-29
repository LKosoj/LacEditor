import Foundation
import XCTest
@testable import LacEditor

final class UIPolishCTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func settingsSource() throws -> String {
        try String(contentsOf: root.appendingPathComponent("LacEditor/Views/SettingsView.swift"), encoding: .utf8)
    }

    private func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testFirstMatchingTitlePicksFirstRowInPageOrder() {
        XCTAssertEqual(SettingsSearch.firstMatchingTitle(in: .export, query: "边距", localize: { $0 }), "自定义页边距")
        XCTAssertEqual(SettingsSearch.firstMatchingTitle(in: .export, query: "上边", localize: { $0 }), "上边距（点）")
        XCTAssertNil(SettingsSearch.firstMatchingTitle(in: .export, query: "  ", localize: { $0 }))
        XCTAssertNil(SettingsSearch.firstMatchingTitle(in: .export, query: "导出", localize: { _ in "x" }))
        XCTAssertEqual(SettingsSearch.firstMatchingTitle(in: .export, query: "PDF 页眉".uppercased(), localize: { $0 }), "PDF 页眉")
    }

    func testImagesSectionKeepsExistingRawValuesAndOwnsUploadKeys() throws {
        let old: [(String, SettingsSection)] = [("编辑器", .editor), ("外观", .appearance), ("文件与恢复", .files), ("文件关联", .associations),
                                                ("性能", .performance), ("导出", .export), ("人工智能", .ai), ("关于", .about)]
        for (raw, section) in old { XCTAssertEqual(SettingsSection(rawValue: raw), section) }
        XCTAssertTrue(SettingsSection.images.searchKeys.contains("图片上传"))
        XCTAssertFalse(SettingsSection.editor.searchKeys.contains("上传地址"))
        let all = SettingsSection.allCases
        XCTAssertEqual(all.firstIndex(of: .images), all.firstIndex(of: .editor).map { $0 + 1 })
        XCTAssertEqual(SettingsSearch.sections(matching: "上传地址", localize: { $0 }), [.images])
    }

    func testEveryRowTitleInSettingsViewIsSearchable() throws {
        let source = try settingsSource()
        let titles = try captures(#"(?:PreferenceRow\(title|PreferenceGroup\(title): L10n\.tr\("([^"]+)"\)"#, in: source)
            + captures(#"(?:exportRow|exportNumberRow)\(L10n\.tr\("([^"]+)"\)"#, in: source)
        XCTAssertFalse(titles.isEmpty)
        let all = Set(SettingsSection.allCases.flatMap(\.searchKeys))
        for title in Set(titles).subtracting(["关于这款编辑器"]) { XCTAssertTrue(all.contains(title), title) }
        let exportToggles = ["markdown.exportPreserveWhitespace", "允许文档 YAML 覆盖 HTML 导出设置", "附加到 head", "附加到 body", "顶级标题和脚注前分页",
                             "自定义页边距", "允许文档 YAML 覆盖页眉和页脚", "自定义图像字体大小", "图像字体大小（点）", "重置导出设置",
                             "删除不支持的导出项目", "添加自定义命令", "添加 PDF 引擎导出项目"]
        for key in exportToggles { XCTAssertTrue(SettingsSection.export.searchKeys.contains(key), key) }
    }

    func testEverySearchKeyIsUsedInViewsOfSettingsFile() throws {
        let source = try settingsSource()
        let viewsDir = root.appendingPathComponent("LacEditor/Views")
        let others = try FileManager.default.contentsOfDirectory(at: viewsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        // Ключи AI-страниц живут в других файлах: сверяем только с исходником настроек и остальными Views.
        for key in Set(SettingsSection.allCases.flatMap(\.searchKeys)) {
            XCTAssertTrue(source.contains("\"\(key)\"") || others.contains("\"\(key)\""), key)
        }
    }

    func testNumberInputParsing() {
        let en = Locale(identifier: "en_US"), ru = Locale(identifier: "ru_RU")
        XCTAssertEqual(SettingsNumberInput.parse("595.28", range: 72...14400, locale: en) ?? 0, 595.28, accuracy: 0.001)
        XCTAssertEqual(SettingsNumberInput.parse("595,28", range: 72...14400, locale: ru) ?? 0, 595.28, accuracy: 0.001)
        XCTAssertNil(SettingsNumberInput.parse("abc", range: 72...14400, locale: en))
        XCTAssertNil(SettingsNumberInput.parse("", range: 72...14400, locale: en))
        XCTAssertNil(SettingsNumberInput.parse("-1", range: 72...14400, locale: en))
        XCTAssertNil(SettingsNumberInput.parse("nan", range: 0...720, locale: en))
        XCTAssertNil(SettingsNumberInput.parse("1e999", range: 0...720, locale: en))
        XCTAssertEqual(SettingsNumberInput.parse("72", range: 72...14400, locale: en), 72)
        XCTAssertEqual(SettingsNumberInput.parse("14400", range: 72...14400, locale: en), 14400)
        XCTAssertNil(SettingsNumberInput.parse("14401", range: 72...14400, locale: en))
        XCTAssertEqual(SettingsNumberInput.parse("0", range: 0...720, locale: en), 0)
    }

    func testPicListEndpointInput() {
        XCTAssertEqual(PicListEndpointInput.parse("")?.endpoint, "")
        XCTAssertNil(PicListEndpointInput.parse("")?.key)
        let withKey = PicListEndpointInput.parse("http://h:1/upload?key=abc")
        XCTAssertEqual(withKey?.key, "abc")
        XCTAssertFalse(withKey?.endpoint.contains("key") ?? true)
        XCTAssertNil(PicListEndpointInput.parse("not a url"))
        XCTAssertNil(PicListEndpointInput.parse("ftp://h/x"))
        XCTAssertNil(PicListEndpointInput.parse("localhost:3000"))
    }

    func testSettingsSourceRules() throws {
        let source = try settingsSource()
        XCTAssertFalse(source.contains("set: setPicListEndpoint"))
        XCTAssertFalse(source.contains("Text(\"50 MB+\")"))
        XCTAssertEqual(source.components(separatedBy: "availableFontFamilies").count - 1, 1)
        XCTAssertTrue(source.contains("ScrollViewReader"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".confirmationDialog(").count - 1, 3)
        let normalize = try XCTUnwrap(source.components(separatedBy: "private func normalizePicListEndpoint()").last?
            .components(separatedBy: "private func commitPicListEndpoint()").first)
        XCTAssertFalse(normalize.contains("endpoint = \"\""))
        for line in source.split(separator: "\n") where line.contains("resetMarkdownExportConfiguration()") || line.contains("removeUnsupportedMarkdownExportEntries()") {
            XCTAssertTrue(line.contains("role: .destructive"), String(line))
        }
        let design = try String(contentsOf: root.appendingPathComponent("LacEditor/Views/LacEditorDesign.swift"), encoding: .utf8)
        XCTAssertTrue(design.contains(".id(title)"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".accessibilityLabel(L10n.tr(\"程序路径\"))").count - 1, 3)
    }
}
