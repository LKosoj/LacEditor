import XCTest
import AppKit
@testable import LacEditor

@MainActor
final class WriterComponentsTests: XCTestCase {
    func testStatusColorMapping() {
        XCTAssertEqual(StatusColor.allCases, [.gray, .blue, .orange, .green, .purple, .teal])
        XCTAssertEqual(StatusColor.allCases.map(\.rawValue), ["gray", "blue", "orange", "green", "purple", "teal"])
        let expected: [NSColor] = [.systemGray, .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemTeal]
        XCTAssertEqual(StatusColor.allCases.map(\.nsColor), expected)
    }

    func testFindingRowAccessibilityText() {
        let ai = FindingRow.accessibilityText(source: .ai, fragment: "very good", explanation: "weak word", location: "Scene 2", category: "Style")
        XCTAssertTrue(ai.hasPrefix(L10n.tr("AI 建议")))
        for part in ["very good", "weak word", "Scene 2", "Style"] { XCTAssertTrue(ai.contains(part)) }

        let rule = FindingRow.accessibilityText(source: .rule, fragment: "very good", explanation: nil, location: "", category: nil)
        XCTAssertTrue(rule.hasPrefix(L10n.tr("本地规则")))
        XCTAssertEqual(rule, L10n.tr("本地规则") + ", very good")
    }

    func testWriterStage1TextsExistInAllCatalogs() throws {
        let keys = ["检查器", "书稿场景", "文风", "显示或隐藏检查器", "显示或隐藏检查器（⌥⌘0）", "暂无场景信息", "暂无文风检查结果",
                    "AI 设置…", "隐藏此提示", "再次显示 AI 提示", "被你关闭的提示会重新显示。", "AI 建议", "本地规则",
                    "文风检查", "按含义扩展搜索词", "查找设定条目", "生成导图", "改编为 Fountain 剧本",
                    "需要：搜索词", "需要：要改编的场景文本，逐个场景发送",
                    "结果：文风问题清单，含原文引用，可逐条查看", "结果：近义词和相关词，可在搜索前删除",
                    "结果：人物、地点等设定条目候选，未经你确认不会创建", "结果：导图的节点结构建议",
                    "结果：Fountain 格式的剧本，在新标签页中打开"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                if language != "zh-Hans" {
                    XCTAssertNil(value.range(of: "\\p{Han}", options: .regularExpression), "\(language): \(key)")
                }
            }
            XCTAssertEqual(catalog["书稿场景"], ["zh-Hans": "场景", "en": "Scene", "ru": "Сцена"][language])
            if language == "en" { XCTAssertEqual(catalog["场景"], "Scenario") }
        }
    }
}
