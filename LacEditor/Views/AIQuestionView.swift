import SwiftUI

struct AIQuestionView: View {
    @ObservedObject var controller: AIQuestionController
    var openSettings: () -> Void = {}

    private var canSend: Bool { !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() {
        guard controller.isEnabled, !controller.isWorking, canSend else { return }
        controller.ask()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.isEnabled {
                StatusMessageView(kind: .info, text: L10n.tr("AI 功能已关闭"))
                Button(L10n.tr("打开 AI 设置")) { openSettings() }
            }
            Group {
                Picker(L10n.tr("来源"), selection: $controller.sourceMode) {
                    ForEach(AIQuestionSourceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                sourceDetail
                if controller.isWebSearchAvailable {
                    Toggle(L10n.tr("在互联网上搜索"), isOn: $controller.webSearchEnabled)
                        .disabled(controller.isWorking)
                        .help(L10n.tr("模型可在回答前请求联网搜索（每个回答最多 3 次）。服务器需支持函数调用（tools）。"))
                        .accessibilityIdentifier("ai.question.webToggle")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(controller.turns) { turn in turnView(turn).id(turn.id) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: controller.turns.count) { _, _ in
                        if let last = controller.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                if let approval = controller.approval { approvalCard(approval) }
                if !controller.message.isEmpty {
                    AIPanelMessageView(kind: controller.messageKind, text: controller.message, action: controller.messageAction,
                                       openSettings: openSettings, retry: { controller.retry() },
                                       sendAnyway: { controller.sendAnyway() })
                }
                TextField(L10n.tr("向文档提问"), text: $controller.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .onSubmit { submit() }
                HStack {
                    Button(controller.isWorking ? L10n.tr("停止") : L10n.tr("发送")) {
                        if controller.isWorking { controller.stop() } else { submit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 72)
                    .disabled(!controller.isWorking && !canSend)
                    if controller.isWorking { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在执行…")) }
                    if controller.isWorking, controller.searchProgress > 0 {
                        Text(L10n.tr("正在联网搜索…（第 %lld 次，共 %lld 次）", controller.searchProgress, AIWebSearchSession.maxSearches))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.tr("新对话")) { controller.newConversation() }
                        .disabled(controller.turns.isEmpty && !controller.isWorking && controller.message.isEmpty)
                }
            }
            .disabled(!controller.isEnabled)
        }
        .onExitCommand(perform: controller.isWorking ? { controller.stop() } : nil)
        .onAppear { controller.refreshStaleness() }
        .onDisappear { controller.hidden() }
    }

    private func approvalCard(_ approval: AIQuestionWebApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("AI 想要联网搜索：")).font(.headline)
            Text(approval.query).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("搜索词会发送到 Jina；找到的网页内容会发送给 AI 服务器。")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.tr("允许")) { controller.resolveWebApproval(true) }.buttonStyle(.borderedProminent)
                Button(L10n.tr("拒绝")) { controller.resolveWebApproval(false) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("AI 请求联网搜索：%@", approval.query))
        .onAppear { AccessibilityNotification.Announcement(L10n.tr("AI 请求联网搜索：%@", approval.query)).post() }
    }

    @ViewBuilder private var sourceDetail: some View {
        switch controller.sourceMode {
        case .currentDocument:
            Text(L10n.tr("有选区时仅使用选区，否则使用整个文档。")).font(.caption).foregroundStyle(.secondary)
        case .openDocuments:
            Text(L10n.tr("当前窗口的 %lld 个文档", controller.availableDocuments.count)).font(.caption).foregroundStyle(.secondary)
        case .files:
            Button(L10n.tr("添加文件")) { controller.addFiles() }
            ForEach(controller.files, id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button(L10n.tr("移除")) { controller.removeFile(url) }
                        .accessibilityLabel(L10n.tr("移除 %@", url.lastPathComponent))
                }
            }
        }
    }

    private func turnView(_ turn: AIQuestionTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.question).font(.headline).textSelection(.enabled)
            Text(AttributedString(modelMarkdown: turn.answer, allowedURLs: Set(turn.webSources.map(\.url))))
                .textSelection(.enabled)
            ForEach(turn.citations) { citation in
                let stale = controller.staleCitationIDs.contains(citation.id)
                VStack(alignment: .leading, spacing: 2) {
                    Button { controller.openCitation(citation) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(citation.sourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text(citation.quote).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.right.circle").accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain).disabled(stale)
                    .help(citation.quote).accessibilityLabel(citation.quote).accessibilityHint(L10n.tr("定位引用"))
                    if stale { Text(L10n.tr("来源已更改")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !turn.webSources.isEmpty { webSourcesView(turn) }
            Text(([AIRequestSize.sent(label: turn.sourceSummary, bytes: turn.sentBytes)]
                  + (turn.skippedCitations > 0 ? [L10n.tr("未能验证 %lld 条引用", turn.skippedCitations)] : [])).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func webSourcesView(_ turn: AIQuestionTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("网络来源")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(turn.webSources) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Button { controller.openWebSource(source) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title.isEmpty ? source.url.absoluteString : source.title).lineLimit(1).truncationMode(.tail)
                            Text(source.url.host ?? source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.link)
                    .help(source.url.absoluteString).accessibilityHint(L10n.tr("打开链接"))
                    ForEach(turn.webCitations.filter { $0.sourceIndex == source.id }) { citation in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(citation.quote).italic().lineLimit(3).textSelection(.enabled)
                            Text(L10n.tr("已按网页内容核对")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !source.isVerified { Text(L10n.tr("未核对")).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("网络来源"))
        .accessibilityIdentifier("ai.question.webSources")
    }
}

extension AttributedString {
    /// Markdown из ответа модели: кликабельными остаются только http(s)-ссылки; если задан `allowedURLs`, то только точно совпавшие с ним.
    init(modelMarkdown text: String, allowedURLs: Set<URL>? = nil) {
        var result = (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs {
            guard let url = run.link else { continue }
            let scheme = url.scheme?.lowercased()
            if scheme != "http" && scheme != "https" || allowedURLs?.contains(url) == false { result[run.range].link = nil }
        }
        self = result
    }
}
