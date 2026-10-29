import Foundation

enum AIFeature: String, CaseIterable, Identifiable, Codable {
    case clarity, rephrase, shorten, expand, terminology, completion, toneReview, toneRewrite, structure, summary, contradictions, sources, metadata, provenance, translation, actionItems, decisions, extractDecisions, table, audienceReview, illustration, imageDescription, imageEdit
    case contextReview, compareVersions, customCheck, recognizeDocument, voiceDraft, mermaid, explain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clarity: L10n.tr("清晰表达")
        case .rephrase: L10n.tr("改写")
        case .shorten: L10n.tr("缩短")
        case .expand: L10n.tr("扩写")
        case .terminology: L10n.tr("术语一致性")
        case .completion: L10n.tr("自动续写")
        case .toneReview: L10n.tr("语气分析")
        case .toneRewrite: L10n.tr("调整语气")
        case .structure: L10n.tr("结构建议")
        case .summary: L10n.tr("文档摘要")
        case .contradictions: L10n.tr("矛盾检查")
        case .sources: L10n.tr("查找来源")
        case .metadata: L10n.tr("生成元数据")
        case .provenance: L10n.tr("文本来源报告")
        case .translation: L10n.tr("翻译")
        case .actionItems: L10n.tr("提取行动项")
        case .decisions: L10n.tr("判断问题")
        case .extractDecisions: L10n.tr("提取决策")
        case .table: L10n.tr("转换为表格")
        case .audienceReview: L10n.tr("读者审阅")
        case .illustration: L10n.tr("生成插图")
        case .imageDescription: L10n.tr("图片说明")
        case .imageEdit: L10n.tr("使用 AI 编辑图片")
        case .contextReview: L10n.tr("根据所选文档审阅")
        case .compareVersions: L10n.tr("比较文本版本")
        case .customCheck: L10n.tr("自定义检查")
        case .recognizeDocument: L10n.tr("识别图片或 PDF")
        case .voiceDraft: L10n.tr("语音草稿")
        case .mermaid: L10n.tr("生成 Mermaid 图表")
        case .explain: L10n.tr("解释所选内容")
        }
    }

    var isBackground: Bool {
        switch self {
        case .clarity, .terminology, .toneReview, .structure, .summary, .metadata, .completion: true
        default: false
        }
    }

    var isReplacement: Bool {
        switch self {
        case .rephrase, .shorten, .expand, .toneRewrite, .translation, .table: true
        default: false
        }
    }

    var role: AIRole {
        switch self {
        case .recognizeDocument: .ocr
        case .voiceDraft: .audio
        case .illustration, .imageEdit: .image
        case .decisions: .decisions
        default: .text
        }
    }

    var isDocumentTool: Bool {
        switch self {
        case .contextReview, .compareVersions, .customCheck, .recognizeDocument, .voiceDraft, .mermaid, .explain: true
        default: false
        }
    }

    var optionPrompt: String? {
        switch self {
        case .clarity: L10n.tr("可选：需要重点改善的清晰度问题")
        case .rephrase: L10n.tr("可选：期望的风格、措辞或限制")
        case .shorten: L10n.tr("可选：目标长度或必须保留的内容")
        case .expand: L10n.tr("可选：需要补充的方向或详细程度")
        case .terminology: L10n.tr("可选：领域、术语表或首选术语")
        case .completion: L10n.tr("可选：续写方向、长度或情节")
        case .toneReview: L10n.tr("可选：需要分析的语气方面")
        case .toneRewrite: L10n.tr("输入期望的语气，例如：正式、友好、简洁")
        case .structure: L10n.tr("可选：目标结构或需要重点检查的部分")
        case .summary: L10n.tr("可选：摘要长度、读者或关注重点")
        case .contradictions: L10n.tr("可选：需要重点核对的陈述或范围")
        case .sources: L10n.tr("输入简短的网页搜索查询，不要粘贴整篇文档")
        case .metadata: L10n.tr("可选：标签数量、描述长度或分类要求")
        case .translation: nil
        case .actionItems: L10n.tr("可选：负责人、期限或输出格式要求")
        case .decisions: L10n.tr("可选：输入需要判断的是非问题")
        case .extractDecisions: L10n.tr("可选：需要提取的决策类型或范围")
        case .table: L10n.tr("可选：列名、列顺序或表格格式要求")
        case .audienceReview: L10n.tr("描述目标读者，例如：新用户、开发人员、管理层")
        case .illustration: L10n.tr("描述需要生成的插图；留空则使用所选文本")
        case .imageEdit: L10n.tr("描述需要如何修改图片")
        case .provenance, .imageDescription: nil
        case .contextReview, .compareVersions, .customCheck, .recognizeDocument, .voiceDraft, .mermaid, .explain: nil
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
        case .clarity, .rephrase, .shorten, .expand, .completion, .toneRewrite, .translation, .table,
             .summary, .metadata, .actionItems: .writing
        case .terminology, .toneReview, .structure, .contradictions, .sources, .provenance,
             .decisions, .extractDecisions, .audienceReview, .contextReview, .compareVersions,
             .customCheck, .explain: .analysis
        case .illustration, .imageDescription, .imageEdit, .recognizeDocument, .voiceDraft, .mermaid: .media
        }
    }

    static func features(in group: AIFeatureGroup) -> [AIFeature] { allCases.filter { $0.group == group } }
}
