import Foundation

enum AIFeature: String, CaseIterable, Identifiable, Codable {
    case clarity, rephrase, shorten, expand, terminology, completion, toneReview, toneRewrite, structure, summary, contradictions, sources, metadata, provenance, translation, actionItems, decisions, extractDecisions, table, audienceReview, illustration, imageDescription
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
        case .illustration: .image
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
}
