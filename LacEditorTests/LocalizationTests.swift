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

    func testFormattingBarTextsExistInAllCatalogs() throws {
        let keys = ["普通文本", "此处无法应用该格式", "段落样式", "插入块"]
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

    func testStyleCheckTextsExistInAllCatalogs() throws {
        let keys = ["词语重复", "句首重复", "长句", "自定义词表", "空格", "套话", "官腔", "歧义", "节奏", "时态", "其他",
                    "检查文风", "AI 检查", "建议修改", "查看修改", "恢复默认", "文风检查设置", "文风与节奏",
                    "文本已变化，请重新检查", "文本已变化，结果可能过时", "此文档不可编辑", "没有可用的修改建议", "没有打开的文档",
                    "第 %lld 行", "“%@”在 %lld 个词内重复", "“%@”在 %lld 个字内重复", "相邻句子都以“%@”开头",
                    "句子有 %lld 个词，上限是 %lld 个", "句子有 %lld 个字，上限是 %lld 个", "词表中的词：%@",
                    "多余的连续空格", "标点前多余的空格", "文风检查完成，发现 %lld 个问题",
                    "有 %lld 条 AI 意见无法对应到原文，已略过", "AI 未发现问题", "AI 正在检查…"]
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

    func testSnapshotAndAutosaveTextsExistInAllCatalogs() throws {
        let keys = ["快照", "制作快照…", "制作快照", "浏览快照…", "快照名称", "为这个快照命名", "快照会保存当前文本，不会改动文件。",
                    "快照已保存", "无法保存快照", "快照由较新版本创建，无法修改", "快照已损坏", "还没有快照", "按 ⌃⌘S 保存当前文本的快照",
                    "保存文件后才能制作快照", "恢复快照", "已恢复快照，尚未保存", "删除此快照？", "自动保存", "启用自动保存",
                    "每隔选定时间保存已有磁盘路径的更改文件；新文档不受影响。", "自动保存间隔", "30 秒", "1 分钟", "5 分钟",
                    "保留的快照数量", "全部", "最近 %d 个", "自动保存于 %@", "自动保存已暂停：文件已在磁盘上更改", "自动保存失败：%@"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%d").count, key.components(separatedBy: "%d").count, "\(language): \(key)")
                XCTAssertEqual(text.components(separatedBy: "\n\"\(key)\" =").count - 1, 1, "\(language): \(key)")
            }
        }
    }

    func testTableMenuTextsExistInAllCatalogs() throws {
        let keys = ["表格", "在上方插入行", "在下方插入行", "删除行", "上移行", "下移行", "在左侧插入列", "在右侧插入列",
                    "删除列", "左移列", "右移列", "列对齐", "默认对齐", "左对齐", "居中对齐", "右对齐"]
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

    func testWriterBoardTextsExistInAllCatalogs() throws {
        let keys = ["卡片板", "合并预览", "卡片板 - %@", "合并预览 - %@", "显示 %d / %d", "所有状态", "所有标签", "上一级", "提前", "延后",
                    "%d 个场景", "没有符合筛选的卡片", "建议梗概", "用 AI 建议梗概", "场景没有可用文本", "正在生成…", "编辑梗概",
                    "打开场景", "进入分组", "设置标记…", "开启 AI 后可获得更贴切的梗概", "文本已变化", "合并预览为空",
                    "有 %d 个文件无法读取", "不在书稿中", "上移一行", "下移一行"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%d").count, key.components(separatedBy: "%d").count, "\(language): \(key)")
                XCTAssertEqual(text.components(separatedBy: "\n\"\(key)\" =").count - 1, 1, "\(language): \(key)")
            }
        }
    }

    func testWorldTextsExistInAllCatalogs() throws {
        let keys = ["设定", "人物", "地点", "组织", "物品", "规则", "卡片类型", "新建设定卡片", "新建%@卡片", "还没有设定卡片", "筛选设定",
                    "别名", "添加别名", "删除别名 %@", "关系", "关系类型", "添加关系", "删除关系", "目标卡片", "未找到该卡片", "提及", "暂无提及",
                    "还有 %lld 个", "此卡片不会发送给 AI", "查找候选…", "候选设定", "创建所选", "未找到候选", "用 AI 查找候选",
                    "出现 %lld 次", "添加卡片模板", "已添加 %lld 个卡片模板", "卡片模板已存在", "用 AI 补充", "用 AI 建议关系", "应用所选",
                    "没有可补充的内容", "修改卡片", "无法修改此卡片的头部（%@）", "头部使用了不支持的写法", "无法读取此卡片的头部。",
                    "已创建 %lld 张卡片", "添加提到的卡片", "已添加 %lld 张卡片", "没有可添加的卡片", "提及结果不完整", "仅适用于 Markdown 文档", "%@：%@，提及 %lld 次"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for language in ["zh-Hans", "en", "ru"] {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in keys {
                let value = try XCTUnwrap(catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, "\(language): \(key)")
                XCTAssertEqual(value.components(separatedBy: "%lld").count, key.components(separatedBy: "%lld").count, "\(language): \(key)")
                XCTAssertEqual(text.components(separatedBy: "\n\"\(key)\" =").count - 1, 1, "\(language): \(key)")
            }
        }
    }

    func testMindMapTextsExistInAllCatalogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func block(_ language: String) throws -> (text: String, catalog: [String: String], keys: [String]) {
            let url = root.appendingPathComponent("LacEditor/\(language).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            let text = try String(contentsOf: url, encoding: .utf8)
            let tail = try XCTUnwrap(text.components(separatedBy: "/* Писательский режим: этап 10 */").last)
            let keys = tail.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.hasPrefix("\""), let end = line.range(of: "\" =") else { return nil }
                return String(line[line.index(after: line.startIndex)..<end.lowerBound])
            }
            return (text, catalog, keys)
        }
        let reference = try block("zh-Hans")
        XCTAssertFalse(reference.keys.isEmpty)
        for language in ["zh-Hans", "en", "ru"] {
            let data = try block(language)
            XCTAssertEqual(data.keys, reference.keys, language)
            for key in reference.keys {
                let value = try XCTUnwrap(data.catalog[key], "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                for spec in ["%@", "%d", "%lld"] {
                    XCTAssertEqual(value.components(separatedBy: spec).count, key.components(separatedBy: spec).count, "\(language): \(key)")
                }
            }
        }
    }
}
