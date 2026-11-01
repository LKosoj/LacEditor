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

    func testAIRegexTextsExistInAllCatalogs() throws {
        let keys = ["用 AI 生成正则表达式", "把查找框里的描述交给 AI 生成正则表达式；只发送这段描述，不发送文档内容", "取消生成",
                    "已生成正则表达式", "AI 生成的正则表达式无效，请换一种说法再试", "生成正则表达式的模型"]
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

    func testTextCompareTextsExistInAllCatalogs() throws {
        let keys = ["比较文本…", "比较文本", "比较对象", "选择文件…", "请选择要比较的文档或文件", "%@（未保存）",
                    "左侧：%@；右侧：%@", "没有差异", "文本过大，无法比较", "比较的文档已关闭"]
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

    func testSearchCoreTextsExistInAllCatalogs() throws {
        let keys = ["在选区内", "仅在启用时选中的文本范围内查找和替换", "请先选中文本", "文本已变化，已取消选区查找",
                    "文件过滤，例如 *.md, !build", "文件过滤",
                    "用逗号分隔。* 匹配任意字符，** 可跨文件夹，? 匹配一个字符，以 ! 开头表示排除。",
                    "提取", "匹配内容", "按模板提取", "匹配所在的行", "不含匹配的行", "使用“替换为”中的模板，例如 $1",
                    "请先在“替换为”中输入模板", "正在提取…", "已提取 %d 条", "没有可提取的内容", "提取失败", "未能读取的文件："]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%d").count, key.components(separatedBy: "%d").count, "\(language): \(key)")
            }
        }
    }

    func testSymbolOutlineTextsExistInAllCatalogs() throws {
        let keys = ["符号", "正在更新符号…", "暂无符号", "文件过大，无法生成大纲", "筛选符号", "没有匹配的符号",
                    "函数", "方法", "初始化器", "类", "结构体", "枚举", "接口或协议", "类型别名", "扩展", "命名空间", "属性",
                    "CSS 选择器", "CSS @ 规则", "HTML 标题", "HTML 元素", "键名", "数据表", "视图", "索引"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                XCTAssertFalse(try XCTUnwrap(catalog[key], "\(language): \(key)").isEmpty, "\(language): \(key)")
                XCTAssertEqual(text.components(separatedBy: "\n\"\(key)\" =").count - 1, 1, "\(language): \(key)")
            }
            let titles = OutlineSymbol.Kind.allCases.map(\.title)
            XCTAssertEqual(titles.count, 19)
            XCTAssertFalse(titles.contains(""))
        }
    }

    func testFolderReplaceRevertTextsExistInAllCatalogs() throws {
        let keys = ["撤销上次文件夹替换…", "撤销替换", "撤销文件夹替换？",
                    "将把 %d 个文件还原为 %@ 替换前的内容。替换后又被修改过的文件不会被改动。", "还原", "没有可撤销的文件夹替换",
                    "只保留最近一次替换的备份，且不包含当时已在编辑器中打开的文档。", "请先打开文件夹：%@", "已还原 %d 个文件",
                    "%d 个文件在替换后被修改，未改动", "%d 个文件已在编辑器中打开，未改动", "%d 个文件当时未写入，无需还原",
                    "%d 个文件无法还原", "文件夹替换已撤销",
                    "将在 %d 个文件中替换 %d 处。已关闭的文件将直接写入磁盘，可用“撤销上次文件夹替换”还原（仅限替换后未再修改的文件）；已打开的文档会作为一次编辑进行，可以撤销。"]
        let removed = "将在 %d 个文件中替换 %d 处。已关闭的文件将直接写入磁盘，此操作无法用“撤销”命令撤回；已打开的文档会作为一次编辑进行，可以撤销。"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // Число подстановок: русский текст может использовать нумерованные %1$d, %2$@.
        func placeholders(_ text: String) -> Int { text.components(separatedBy: "%").count - 1 }
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertEqual(placeholders(value), placeholders(key), "\(language): \(key)")
            }
            XCTAssertNil(catalog[removed], language)
        }
    }

    func testExternalChangeBannerTextsExistInAllCatalogs() throws {
        let keys = ["磁盘上的文件已被其他程序修改", "磁盘上的文件已被删除或移动", "比较", "保留我的版本", "重新载入"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                XCTAssertFalse(try XCTUnwrap(catalog[key], "\(language): \(key)").isEmpty, "\(language): \(key)")
                XCTAssertEqual(text.components(separatedBy: "\n\"\(key)\" =").count - 1, 1, "\(language): \(key)")
            }
        }
    }
}
