import Foundation

enum AIFeature: String, CaseIterable, Identifiable, Codable {
    case clarity, rewrite, completion, consistency, readerReview, structure, summary, sources, metadata, translation, tasksAndDecisions, table, illustration, imageDescription, imageEdit
    case contextReview, compareVersions, customCheck, recognizeDocument, voiceDraft, mermaid, ask, agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clarity: L10n.tr("清晰表达")
        case .rewrite: L10n.tr("重写")
        case .consistency: L10n.tr("一致性检查")
        case .readerReview: L10n.tr("读者视角")
        case .tasksAndDecisions: L10n.tr("任务与决策")
        case .completion: L10n.tr("自动续写")
        case .structure: L10n.tr("结构建议")
        case .summary: L10n.tr("文档摘要")
        case .sources: L10n.tr("查找来源")
        case .metadata: L10n.tr("生成元数据")
        case .translation: L10n.tr("翻译")
        case .table: L10n.tr("转换为表格")
        case .illustration: L10n.tr("生成插图")
        case .imageDescription: L10n.tr("图片说明")
        case .imageEdit: L10n.tr("使用 AI 编辑图片")
        case .contextReview: L10n.tr("根据所选文档审阅")
        case .compareVersions: L10n.tr("比较文本版本")
        case .customCheck: L10n.tr("自定义检查")
        case .recognizeDocument: L10n.tr("识别图片或 PDF")
        case .voiceDraft: L10n.tr("语音草稿")
        case .mermaid: L10n.tr("生成 Mermaid 图表")
        case .ask: L10n.tr("向文档提问")
        case .agent: L10n.tr("AI 代理")
        }
    }

    var isBackground: Bool {
        switch self {
        case .clarity, .consistency, .readerReview, .structure, .summary, .metadata, .completion: true
        default: false
        }
    }

    var isReplacement: Bool {
        switch self {
        case .rewrite, .translation, .table: true
        default: false
        }
    }

    var role: AIRole {
        switch self {
        case .recognizeDocument: .ocr
        case .voiceDraft: .audio
        case .illustration, .imageEdit: .image
        default: .text
        }
    }

    var isDocumentTool: Bool {
        switch self {
        case .contextReview, .compareVersions, .customCheck, .recognizeDocument, .voiceDraft, .mermaid, .ask, .agent: true
        default: false
        }
    }

    var optionPrompt: String? {
        switch self {
        case .clarity: L10n.tr("可选：需要重点改善的清晰度问题")
        case .rewrite: nil
        case .consistency: L10n.tr("可选：领域、术语表或首选术语")
        case .completion: L10n.tr("可选：续写方向、长度或情节")
        case .structure: L10n.tr("可选：目标结构或需要重点检查的部分")
        case .summary: L10n.tr("可选：摘要长度、读者或关注重点")
        case .sources: L10n.tr("输入简短的网页搜索查询，不要粘贴整篇文档")
        case .metadata: L10n.tr("可选：标签数量、描述长度或分类要求")
        case .translation: nil
        case .readerReview: L10n.tr("可选：描述目标读者，例如：新用户、开发人员、管理层；留空则按普通读者阅读")
        case .tasksAndDecisions: L10n.tr("可选：负责人、期限或输出格式要求")
        case .table: L10n.tr("可选：列名、列顺序或表格格式要求")
        case .illustration: L10n.tr("描述需要生成的插图；留空则使用所选文本")
        case .imageEdit: L10n.tr("描述需要如何修改图片")
        case .imageDescription: nil
        case .contextReview, .compareVersions, .customCheck, .recognizeDocument, .voiceDraft, .mermaid, .ask, .agent: nil
        }
    }
}

enum AIFeatureGroup: CaseIterable, Identifiable {
    case writing, analysis, media

    var id: Self { self }

    var title: String {
        switch self {
        case .writing: L10n.tr("文本编辑")
        case .analysis: L10n.tr("分析与检查")
        case .media: L10n.tr("图片、语音与图表")
        }
    }
}

extension AIFeature {
    var group: AIFeatureGroup {
        switch self {
        case .clarity, .rewrite, .completion, .translation, .table, .summary, .metadata, .tasksAndDecisions: .writing
        case .consistency, .readerReview, .structure, .sources, .contextReview, .compareVersions,
             .customCheck, .ask, .agent: .analysis
        case .illustration, .imageDescription, .imageEdit, .recognizeDocument, .voiceDraft, .mermaid: .media
        }
    }

    static func features(in group: AIFeatureGroup) -> [AIFeature] { allCases.filter { $0.group == group } }

    var needs: String {
        switch self {
        case .table: L10n.tr("需要：选中的文本")
        case .clarity, .structure, .summary, .metadata, .consistency, .tasksAndDecisions: L10n.tr("需要：选中的文本，没有选区时使用整篇文档")
        case .rewrite: L10n.tr("需要：选中的文本；选择「调整语气」时还需填写期望的语气")
        case .completion: L10n.tr("需要：光标前的文字（需开启后台 AI 功能）")
        case .readerReview: L10n.tr("需要：选中的文本或整篇文档；可填写目标读者，留空则按普通读者")
        case .sources: L10n.tr("需要：一条简短的网页搜索查询（需启用 Jina 搜索）")
        case .translation: L10n.tr("需要：选中的文本和目标语言")
        case .illustration: L10n.tr("需要：插图描述，或选中的文本")
        case .imageDescription: L10n.tr("需要：一张图片（在格式化视图中右键点击图片，或选择文件）")
        case .imageEdit: L10n.tr("需要：文档中的图片（右键菜单）和修改说明")
        case .contextReview: L10n.tr("需要：目标文本和至少一份参考文档")
        case .compareVersions: L10n.tr("需要：两个要比较的文本版本")
        case .customCheck: L10n.tr("需要：一条自定义检查规则")
        case .recognizeDocument: L10n.tr("需要：图片或 PDF 文件")
        case .voiceDraft: L10n.tr("需要：麦克风录音或音频文件")
        case .mermaid: L10n.tr("需要：选中的文本，并说明要绘制的图表")
        case .ask: L10n.tr("需要：一个问题，以及当前文档（选区或全文）、当前窗口已打开的文档或所选文件")
        case .agent: L10n.tr("需要：一个任务。代理会自行读取当前窗口已打开的文档和工作文件夹中的文件，读取的内容会发送给 AI 服务器")
        }
    }

    var result: String {
        switch self {
        case .clarity: L10n.tr("结果：逐条修改建议，可逐条接受或拒绝")
        case .rewrite: L10n.tr("结果：重写后的文本，接受前可对比，可撤销")
        case .completion: L10n.tr("结果：灰色续写提示，按 Tab 接受，Esc 取消")
        case .consistency: L10n.tr("结果：术语不一致与前后矛盾的报告，可点击引用定位")
        case .readerReview: L10n.tr("结果：语气分析，以及读者可能看不懂的地方")
        case .structure: L10n.tr("结果：结构改进建议")
        case .summary: L10n.tr("结果：文档摘要，可插入文末")
        case .sources: L10n.tr("结果：与文档陈述相关的网页来源；未启用 Reader 时仅为未核实的链接")
        case .metadata: L10n.tr("结果：简短描述和标签，可编辑")
        case .translation: L10n.tr("结果：译文，接受前可对比，可撤销")
        case .tasksAndDecisions: L10n.tr("结果：行动项、决策和待解决问题，并附原文依据")
        case .ask: L10n.tr("结果：仅依据所选来源的回答，附可核对、可定位的引用")
        case .agent: L10n.tr("结果：回答、已读取内容的记录和用量；修改只作为建议，已打开的文档接受后才会修改，未打开的文件只能通过单独的“应用到文件”按钮并确认后写入")
        case .table: L10n.tr("结果：Markdown 表格，接受前可对比，可撤销")
        case .illustration: L10n.tr("结果：生成的图片，可保存或插入文档")
        case .imageDescription: L10n.tr("结果：供屏幕阅读器使用的图片替代文字")
        case .imageEdit: L10n.tr("结果：修改后的图片，可应用或另存")
        case .contextReview: L10n.tr("结果：基于所选文档的审阅报告，引用可定位")
        case .compareVersions: L10n.tr("结果：对两个版本差异的说明")
        case .customCheck: L10n.tr("结果：按该规则生成的检查报告")
        case .recognizeDocument: L10n.tr("结果：识别出的文字，可插入文档")
        case .voiceDraft: L10n.tr("结果：转写出的文字，可插入文档")
        case .mermaid: L10n.tr("结果：Mermaid 图表代码，可插入文档")
        }
    }

    var detail: String { needs + "\n" + result }

    var opensPanelFirst: Bool { self == .translation || self == .readerReview || isDocumentTool }
}

enum AIRewriteMode: String, CaseIterable, Identifiable {
    case rephrase, shorten, expand, tone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rephrase: L10n.tr("改写")
        case .shorten: L10n.tr("缩短")
        case .expand: L10n.tr("扩写")
        case .tone: L10n.tr("调整语气")
        }
    }

    var optionPrompt: String {
        switch self {
        case .rephrase: L10n.tr("可选：期望的风格、措辞或限制")
        case .shorten: L10n.tr("可选：目标长度或必须保留的内容")
        case .expand: L10n.tr("可选：需要补充的方向或详细程度")
        case .tone: L10n.tr("输入期望的语气，例如：正式、友好、简洁")
        }
    }

    var requiresOption: Bool { self == .tone }

    var task: String {
        switch self {
        case .rephrase: "Rephrase the whole input. Return {\"replacement\":\"...\",\"report\":\"\"}."
        case .shorten: "Shorten the whole input without losing meaning. Return {\"replacement\":\"...\",\"report\":\"\"}."
        case .expand: "Expand the whole input without inventing facts. Return {\"replacement\":\"...\",\"report\":\"\"}."
        case .tone: "Rewrite the whole input in the requested tone. Return {\"replacement\":\"...\",\"report\":\"\"}."
        }
    }

    var needs: String {
        switch self {
        case .rephrase, .shorten, .expand: L10n.tr("需要：选中的文本")
        case .tone: L10n.tr("需要：选中的文本和期望的语气，例如正式、友好")
        }
    }

    var result: String {
        switch self {
        case .rephrase: L10n.tr("结果：换一种说法的文本，意思不变")
        case .shorten: L10n.tr("结果：更短的文本，保留原意")
        case .expand: L10n.tr("结果：更详细的文本，不添加虚构事实")
        case .tone: L10n.tr("结果：用该语气重写的文本")
        }
    }

    var detail: String { needs + "\n" + result }
}

enum AIFeatureMigration {
    static let merges: [(new: String, old: [String])] = [
        ("rewrite", ["rephrase", "shorten", "expand", "toneRewrite"]),
        ("consistency", ["terminology", "contradictions"]),
        ("readerReview", ["toneReview", "audienceReview"]),
        ("tasksAndDecisions", ["actionItems", "extractDecisions"]),
        ("ask", ["explain", "decisions"])]

    static func migrate(features: [String], models: [String: String]) -> (features: [String], models: [String: String], changed: Bool) {
        var features = features, models = models, changed = false
        func isEmpty(_ value: String?) -> Bool { value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
        for (new, old) in merges {
            if features.contains(where: { old.contains($0) }) {
                features.removeAll(where: { old.contains($0) })
                if !features.contains(new) { features.append(new) }
                changed = true
            }
            for name in old {
                guard let value = models[name] else { continue }
                if isEmpty(models[new]), !isEmpty(value) { models[new] = value }
                models.removeValue(forKey: name)
                changed = true
            }
        }
        return (features, models, changed)
    }
}
