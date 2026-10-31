import AppKit
import SwiftUI

struct AIAgentView: View {
    @ObservedObject var controller: AIAgentController
    var openSettings: () -> Void = {}

    private var canSend: Bool { !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() {
        guard controller.isEnabled, !controller.isWorking, !controller.canResume, canSend else { return }
        controller.send()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.isEnabled {
                StatusMessageView(kind: .info, text: L10n.tr("AI 功能已关闭"))
                Button(L10n.tr("打开 AI 设置")) { openSettings() }
            }
            Group {
                if !controller.hasFolder {
                    Text(L10n.tr("未打开工作文件夹，代理只能读取已打开的文档。")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.isWebSearchAvailable {
                    Toggle(L10n.tr("在互联网上搜索"), isOn: $controller.webSearchEnabled)
                        .disabled(controller.isWorking || controller.hasConversation)
                        .help(L10n.tr("每次联网搜索前都会征求你的同意（每次对话最多 %lld 次）。服务器需支持函数调用（tools）。", AIAgentLimits().maxWebSearches))
                        .accessibilityIdentifier("ai.agent.webToggle")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(controller.turns) { turn in turnView(turn).id(turn.id) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: controller.turns.count) { _, _ in scrollToLast(proxy) }
                    .onChange(of: controller.turns.last?.journal.count) { _, _ in scrollToLast(proxy) }
                }
                if !controller.plan.isEmpty { planSection }
                if !controller.editGroups.isEmpty { editsSection }
                if controller.isApplyingFiles { applyingFilesRow }
                if let report = controller.fileReport { fileReportView(report) }
                if let approval = controller.approval { approvalCard(approval) }
                if !controller.message.isEmpty {
                    AIPanelMessageView(kind: controller.messageKind, text: controller.message, action: controller.messageAction,
                                       openSettings: openSettings, retry: { controller.resume() })
                }
                presetPicker
                TextField(L10n.tr("向代理描述任务"), text: $controller.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .onSubmit { submit() }
                if controller.counters.rounds > 0 { countersView }
                HStack {
                    Button(controller.isWorking ? L10n.tr("停止") : L10n.tr("运行")) {
                        if controller.isWorking { controller.stop() } else { submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 72)
                    .disabled(!controller.isWorking && (!canSend || controller.canResume || controller.isApplyingFiles))
                    if controller.isWorking { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在执行…")) }
                    if controller.canResume && !controller.isWorking { Button(L10n.tr("继续")) { controller.resume() }.disabled(controller.isApplyingFiles) }
                    Spacer(minLength: 0)
                    Button(L10n.tr("新对话")) { controller.newConversation() }
                        .disabled(controller.isApplyingFiles || (controller.turns.isEmpty && !controller.isWorking && controller.message.isEmpty))
                        .help(controller.editGroups.isEmpty ? "" : L10n.tr("未接受的修改建议将被丢弃"))
                }
                if controller.isWorking, controller.searchProgress > 0 {
                    Text(L10n.tr("正在联网搜索…（第 %lld 次，共 %lld 次）", controller.searchProgress, AIAgentLimits().maxWebSearches))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!controller.isEnabled)
        }
        .onExitCommand(perform: controller.isWorking ? { controller.stop() } : nil)
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu(L10n.tr("场景")) {
                ForEach(AIAgentPreset.allCases) { preset in
                    Button(preset.title) { controller.applyPreset(preset) }.help(preset.summary)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(controller.isWorking || controller.canResume)
            .accessibilityIdentifier("ai.agent.presetMenu")
            if let preset = controller.selectedPreset {
                Text(preset.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let hint = controller.presetWebHint {
                    Label(hint, systemImage: "globe").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(hint)
                }
            }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        if let last = controller.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var countersView: some View {
        let counters = controller.counters
        var parts = [L10n.tr("已发送 %@ · 上下文 %@ · %lld 轮", AIRequestSize.text(counters.sentBytes), AIRequestSize.text(counters.contextBytes), counters.rounds)]
        if counters.usage != AIUsage() { parts.append(L10n.tr("令牌：输入 %lld，输出 %lld", counters.usage.inputTokens, counters.usage.outputTokens)) }
        let text = parts.joined(separator: " · ")
        return Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    @State private var planExpanded = true

    private func statusWord(_ status: AIAgentPlanItem.Status) -> String {
        switch status {
        case .done: L10n.tr("已完成")
        case .inProgress: L10n.tr("进行中")
        case .pending: L10n.tr("待办")
        }
    }

    private func statusIcon(_ status: AIAgentPlanItem.Status) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .inProgress: "circle.inset.filled"
        case .pending: "circle"
        }
    }

    /// Только показ: план ведёт агент, пользователь его не правит.
    private var planSection: some View {
        let plan = controller.plan
        let title = plan.items.isEmpty ? L10n.tr("备注") : L10n.tr("计划（%lld/%lld）", plan.doneCount, plan.items.count)
        return DisclosureGroup(title, isExpanded: $planExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: statusIcon(item.status)).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(item.title).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(L10n.tr("%@，%@", item.title, statusWord(item.status)))
                    }
                    if !plan.notes.isEmpty {
                        if !plan.items.isEmpty { Text(L10n.tr("备注")).font(.caption).foregroundStyle(.secondary) }
                        // Заметки написаны моделью: не Markdown, чтобы не появлялись кликабельные адреса
                        Text(verbatim: plan.notes).font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.agent.plan")
    }

    private var editsSection: some View {
        let count = controller.editGroups.reduce(0) { $0 + $1.edits.count }
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("建议的修改（%lld）", count)).font(.headline)
            Text(L10n.tr("代理的修改只是建议：接受后才会写入文档。")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.tr("全部拒绝")) { controller.rejectAllEdits(in: nil) }
                .accessibilityIdentifier("ai.agent.edits.rejectAll")
                .disabled(controller.isApplyingFiles)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.editGroups) { editGroupView($0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            if controller.closedFileCount > 0 { applyFilesControls }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.agent.edits")
    }

    /// Запись в не открытые файлы: отдельная кнопка, только по действию пользователя.
    private var applyFilesControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(L10n.tr("应用到文件（%lld）", controller.closedFileCount)) { controller.applyToFiles() }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isWorking || controller.isApplyingFiles)
                .accessibilityIdentifier("ai.agent.edits.applyFiles")
            Text(L10n.tr("应用后将直接写入磁盘，不能用“撤销”撤回；写入前后会保存文件版本。")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var applyingFilesRow: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(L10n.tr("正在写入文件…")).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(L10n.tr("取消")) { controller.cancelFileApply() }
        }
        .accessibilityElement(children: .contain)
    }

    private func lineText(_ line: AIAgentFileReport.Line) -> String {
        var text: String
        switch line.status {
        case nil: text = L10n.tr("未处理")
        case let .written(applied, notApplied)?:
            text = notApplied == 0 ? L10n.tr("已写入 %lld 处修改", applied) : L10n.tr("已写入 %lld 处修改，%lld 处无法应用", applied, notApplied)
        case let .skipped(reason)?:
            switch reason {
            case .changed: text = L10n.tr("文件在磁盘上已被修改，建议已失效")
            case .openNow: text = L10n.tr("文件已在编辑器中打开，未写入；请关闭后重试")
            case .notExactUTF8: text = L10n.tr("文件不是纯 UTF-8（或带 BOM），未写入")
            case .symbolicLink: text = L10n.tr("路径包含符号链接，未写入")
            case .inaccessible: text = L10n.tr("无法读取文件，未写入")
            case .writeFailed: text = L10n.tr("写入失败，文件保持原样")
            case .nothingApplicable: text = L10n.tr("没有可应用的修改")
            }
        }
        if line.versionWarning { text += " · " + L10n.tr("未能保存文件版本") }
        return text
    }

    private func fileReportView(_ report: AIAgentFileReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("写入结果")).font(.headline)
            ForEach(report.lines) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.name).lineLimit(1).truncationMode(.middle)
                    Text(lineText(line)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.tr("%@，%@", line.name, lineText(line)))
                .help(line.path)
            }
            Button(L10n.tr("关闭")) { controller.dismissFileReport() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai.agent.fileReport")
    }

    private func editGroupView(_ group: AIAgentEditGroup) -> some View {
        let canAccept = controller.canAccept(in: group.id)
        let acceptable = group.edits.filter { $0.problem == nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(group.name).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
            if group.isClosedFile {
                if let path = group.edits.first?.path {
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(L10n.tr("未打开的文件，需通过“应用到文件”写入")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let edit = group.edits.first(where: { !$0.externalReferences.isEmpty }) { externalWarning(edit) }
            VStack(alignment: .leading, spacing: 6) {
                if group.isClosedFile {
                    EmptyView()
                } else if canAccept {
                    Button(L10n.tr("全部接受（%lld）", acceptable)) { controller.acceptAllEdits(in: group.id) }
                        .disabled(acceptable == 0)
                        .accessibilityIdentifier("ai.agent.edits.acceptAll")
                } else {
                    Text(L10n.tr("切换到此文档后才能接受修改")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.tr("显示文档")) { controller.showDocument(group.id) }
                }
                Button(L10n.tr("全部拒绝")) { controller.rejectAllEdits(in: group.id) }
                    .disabled(controller.isApplyingFiles)
            }
            ForEach(group.edits) { editView($0, group: group, canAccept: canAccept) }
        }
    }

    private func externalWarning(_ edit: AIAgentEdit) -> some View {
        let text = L10n.tr("新增外部地址：%@", edit.externalReferences.joined(separator: ", "))
        return Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    private func editView(_ edit: AIAgentEdit, group: AIAgentEditGroup, canAccept: Bool) -> some View {
        let diff = controller.diff(for: edit)
        let subject = edit.explanation.isEmpty ? group.name : edit.explanation
        return VStack(alignment: .leading, spacing: 4) {
            if !edit.explanation.isEmpty {
                Text(edit.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.tr("原文")).font(.caption2).foregroundStyle(.secondary)
            Text(diff.original).lineLimit(8).textSelection(.enabled)
            Text(L10n.tr("替换为")).font(.caption2).foregroundStyle(.secondary)
            Text(diff.replacement).lineLimit(8).textSelection(.enabled)
            if !edit.externalReferences.isEmpty { externalWarning(edit) }
            if let problem = edit.problem {
                Text(AIAgentController.reason(for: problem)).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !group.isClosedFile {
                    Button(L10n.tr("接受")) { controller.acceptEdit(edit.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(edit.problem != nil || !canAccept)
                        .accessibilityLabel(L10n.tr("接受修改：%@", subject))
                        .accessibilityIdentifier("ai.agent.edit.accept")
                }
                Button(L10n.tr("拒绝")) { controller.rejectEdit(edit.id) }
                    .disabled(controller.isApplyingFiles)
                    .accessibilityLabel(L10n.tr("拒绝修改：%@", subject))
                    .accessibilityIdentifier("ai.agent.edit.reject")
            }
        }
        .padding(6)
        .opacity(edit.problem == nil ? 1 : 0.7)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func approvalCard(_ approval: AIAgentApproval) -> some View {
        switch approval.content {
        case .webSearch(let query):
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("代理想要联网搜索：")).font(.headline)
                Text(query).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("搜索词会发送到 Jina；找到的网页内容会发送给 AI 服务器。")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Button(L10n.tr("允许")) { controller.resolve(.allowOnce) }.buttonStyle(.borderedProminent)
                    Button(L10n.tr("本次运行内允许")) { controller.resolve(.allowInRun) }
                    Button(L10n.tr("拒绝")) { controller.resolve(.deny) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("代理请求联网搜索：%@", query))
            .onAppear { AccessibilityNotification.Announcement(L10n.tr("代理请求联网搜索：%@", query)).post() }
        case .document(_, let name, let path):
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("代理想要访问文档：")).font(.headline)
                Text(name).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(L10n.tr("文档内容将发送给 AI 服务器。允许后，本次对话可访问此文档。")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.tr("允许")) { controller.resolve(.allowOnce) }.buttonStyle(.borderedProminent)
                    Button(L10n.tr("拒绝")) { controller.resolve(.deny) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("代理请求访问文档：%@", name))
            .onAppear { AccessibilityNotification.Announcement(L10n.tr("代理请求访问文档：%@", name)).post() }
        }
    }

    private func turnView(_ turn: AIAgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.question).font(.headline).textSelection(.enabled)
            if !turn.journal.isEmpty {
                DisclosureGroup(L10n.tr("读取记录（%lld）", turn.journal.count), isExpanded: expansion(turn)) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(turn.journal) { AIAgentJournalRow(entry: $0) }
                    }
                }
            }
            if !turn.answer.isEmpty {
                Text(AttributedString(modelMarkdown: turn.answer, allowedURLs: turn.allowedURLs)).textSelection(.enabled)
            }
            switch turn.status {
            case .paused: Text(L10n.tr("代理已暂停，可点击“继续”从中断处继续。")).font(.caption).foregroundStyle(.secondary)
            case .stopped: Text(L10n.tr("已停止")).font(.caption).foregroundStyle(.secondary)
            case .running, .answered, .partial: EmptyView()
            }
        }
    }

    /// Журнал раскрыт, пока ход идёт; потом пользователь сворачивает и разворачивает сам.
    @State private var userExpanded: [UUID: Bool] = [:]
    private func expansion(_ turn: AIAgentTurn) -> Binding<Bool> {
        Binding(get: { userExpanded[turn.id] ?? (turn.status == .running) },
                set: { userExpanded[turn.id] = $0 })
    }
}

private struct AIAgentJournalRow: View {
    let entry: AIAgentJournalEntry

    private var icon: String {
        switch entry.kind {
        case .listDocuments: "list.bullet"
        case .searchText: "magnifyingglass"
        case .readDocument: "doc.text"
        case .outline: "list.number"
        case .links: "link"
        case .webSearch: "globe"
        case .webPage: "doc.richtext"
        case .rejected: "exclamationmark.triangle"
        case .proposeEdit: "square.and.pencil"
        case .updatePlan: "checklist"
        case .contextCleared: "scissors"
        case .contextCondensed: "archivebox"
        case .contextCondenseFailed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        let subject = entry.subject ?? ""
        switch entry.kind {
        case .listDocuments: return subject.isEmpty ? L10n.tr("列出文件") : L10n.tr("列出文件：%@", subject)
        case .searchText: return L10n.tr("搜索“%@”", subject)
        case .readDocument: return L10n.tr("读取 %@", entry.documentName ?? subject)
        case .outline: return L10n.tr("目录 %@", entry.documentName ?? subject)
        case .links: return L10n.tr("链接与标签 %@", entry.documentName ?? subject)
        case .webSearch: return L10n.tr("联网搜索“%@”", subject)
        case .webPage: return L10n.tr("网页 %@", entry.documentName?.isEmpty == false ? entry.documentName ?? subject : subject)
        case .proposeEdit: return L10n.tr("建议修改 %@", entry.documentName ?? subject)
        case .updatePlan: return L10n.tr("更新计划 %@", subject)
        case .contextCleared: return L10n.tr("已清理旧结果（%lld 条）", entry.count)
        case .contextCondensed: return L10n.tr("已压缩上下文")
        case .contextCondenseFailed: return L10n.tr("压缩上下文失败")
        case .rejected:
            return entry.tool == "web_search" && entry.errorCode == nil
                ? L10n.tr("已拒绝联网搜索“%@”", subject) : L10n.tr("无效的工具调用：%@", subject.isEmpty ? entry.tool : subject)
        }
    }

    private var details: String {
        switch entry.kind {
        case .contextCleared: return L10n.tr("节省 %@", AIRequestSize.text(entry.savedBytes))
        case .contextCondensed: return L10n.tr("请求 %@ · 节省 %@", AIRequestSize.text(entry.sentBytes), AIRequestSize.text(entry.savedBytes))
        default: break
        }
        var parts = [AIRequestSize.text(entry.sentBytes)]
        if entry.files.first?.source == .unsaved { parts.append(L10n.tr("未保存的文本")) }
        if entry.files.first?.source == .draft { parts.append(L10n.tr("含建议修改的文本")) }
        if entry.truncated { parts.append(L10n.tr("已截断")) }
        if entry.errorCode != nil { parts.append(L10n.tr("出错")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let phrase = title + " · " + details
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(phrase)
        .help(entry.files.first?.path ?? entry.subject ?? title)
    }
}

/// Подтверждение записи в не открытые файлы; синхронный диалог, как в замене в папке.
enum AIAgentFileApplyAlert {
    @MainActor static func confirm(_ summary: AIAgentFileApplySummary) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("确认写入文件？")
        alert.informativeText = L10n.tr("代理建议的 %lld 处修改将直接写入 %lld 个未打开的文件。写入前后各会保存一份文件版本，可在版本历史中恢复；此操作无法用“撤销”撤回。\n%@",
                                        summary.editCount, summary.fileCount, summary.names.joined(separator: "\n"))
        alert.addButton(withTitle: L10n.tr("取消"))
        let write = alert.addButton(withTitle: L10n.tr("写入文件"))
        write.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
