import Foundation

/// Готовые задания для агента: выбор только подставляет текст в поле задания.
enum AIAgentPreset: String, CaseIterable, Identifiable, Sendable {
    case factCheck, translateLong, consistencyAcrossDocuments, folderEdit, draftFromNotes

    var id: String { rawValue }

    /// Название в меню.
    var title: String {
        switch self {
        case .factCheck: L10n.tr("核查事实")
        case .translateLong: L10n.tr("翻译长文")
        case .consistencyAcrossDocuments: L10n.tr("跨文档一致性检查")
        case .folderEdit: L10n.tr("批量修改文件夹中的文件")
        case .draftFromNotes: L10n.tr("根据笔记起草")
        }
    }

    /// Одно предложение: что делает сценарий.
    var summary: String {
        switch self {
        case .factCheck: L10n.tr("找出文档中可核查的论断，联网查证并给出来源；不修改文本。")
        case .translateLong: L10n.tr("分段翻译长文，术语表记在计划备注中；译文作为修改建议提出。")
        case .consistencyAcrossDocuments: L10n.tr("在工作文件夹的文档之间查找术语、名称、日期和事实的矛盾；不修改文本。")
        case .folderEdit: L10n.tr("在工作文件夹的文件中提出同一类修改；未打开的文件也可修改，经你审阅后再写入。")
        case .draftFromNotes: L10n.tr("阅读你指定的笔记并起草文本；缺少的事实可联网查证。")
        }
    }

    /// Текст задания; заканчивается меткой, которую пользователь дописывает.
    var taskText: String {
        switch self {
        case .factCheck:
            L10n.tr("核查文档中的事实。先通读文档，把可核查的论断（人名、日期、数字、引文）列入计划（update_plan），再用联网搜索核查重要的论断；如果没有联网搜索，就如实说明，只做文档内部的核对。对每条论断给出结论：已证实、被驳斥或未找到，并附上来源链接。不要修改文本，只列出问题。\n\n文档或文件夹：")
        case .translateLong:
            L10n.tr("分段翻译长文。先读目录，在计划备注（update_plan 的 notes）中建立术语表（原文术语与选定译法），每一段都按术语表翻译，术语表有变化时及时更新备注。按章节逐段翻译，每段用 propose_edit 提出修改，保持 Markdown 标记、链接和代码不变；译文会替换原文片段（原版本留在文件版本历史中）。如果待处理的修改建议达到上限，就停下并说明还剩什么；最后列出已翻译和未翻译的部分。\n\n目标语言：\n文档：")
        case .consistencyAcrossDocuments:
            L10n.tr("检查工作文件夹中各文档之间术语、名称、日期和事实是否一致。用 search_text 和 read_document 查找并阅读相关文档，把发现（文件、行号、相互矛盾的表述）记入计划备注。最后列出所有矛盾，并给出文件路径和行号。不要修改任何文本。\n\n范围（文件夹或文件）：")
        case .folderEdit:
            L10n.tr("对工作文件夹中的文件做同一类修改。先用 search_text 找出相关文件并记入计划（update_plan），再逐处用 propose_edit 提出修改，每处尽量小。未打开的文件也可以提出修改：我会先审阅，再自己应用到文件。不要触及无关内容。\n\n要做的修改：")
        case .draftFromNotes:
            L10n.tr("根据我的笔记起草文本。阅读我指定的笔记，用 document_links 和 search_text 找到相关笔记，把要点和事实记入计划备注。草稿直接写在回答里；如果我指定了目标文档，则用 propose_edit 提出修改。笔记里缺少的事实才联网查证，并注明来源；没有联网搜索时，不要编造事实。\n\n笔记与目标：")
        }
    }

    /// Сценарий выигрывает от интернета: панель подсказывает, но не включает.
    var usesWeb: Bool {
        switch self {
        case .factCheck, .draftFromNotes: true
        case .translateLong, .consistencyAcrossDocuments, .folderEdit: false
        }
    }

    static var webHintAvailable: String { L10n.tr("此场景建议开启“在互联网上搜索”；每次搜索前都会征求你的同意。") }
    static var webHintLocked: String { L10n.tr("此场景建议联网搜索：请开始新对话后再打开“在互联网上搜索”。") }
    static var webHintUnavailable: String { L10n.tr("此场景建议联网搜索：请先在设置中启用 Jina 搜索。") }

    /// Подсказка по текущему состоянию; nil — подсказка не нужна.
    static func webHint(for preset: AIAgentPreset, webEnabled: Bool, available: Bool, locked: Bool) -> String? {
        if !preset.usesWeb || webEnabled { return nil }
        if !available { return webHintUnavailable }
        return locked ? webHintLocked : webHintAvailable
    }

    /// Все тексты сценария, которые должны быть в каталогах.
    var catalogKeys: [String] { [title, summary, taskText] }
}
