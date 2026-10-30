import AppKit
import SwiftUI

struct AIWritingView: View {
    @ObservedObject var controller: AIWritingController
    var openSettings: () -> Void = {}
    @State private var option = ""
    @State private var metadataText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("AI 写作助手")).font(.headline).accessibilityAddTraits(.isHeader)
            if controller.enabledFeatures.isEmpty {
                ContentUnavailableView {
                    Label(L10n.tr("尚未启用 AI 功能"), systemImage: "sparkles")
                } description: {
                    Text(L10n.tr("请在设置中启用 AI 功能"))
                } actions: {
                    Button(L10n.tr("打开 AI 设置")) { openSettings() }.buttonStyle(.borderedProminent)
                }
            } else {
                Picker(L10n.tr("功能"), selection: $controller.requestedFeature) {
                    ForEach(controller.enabledFeatures) { feature in Text(feature.title).tag(feature) }
                }
            }
            if controller.enabledFeatures.contains(controller.requestedFeature) {
                Text(controller.requestedFeature.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(controller.requestedFeature.detail)
            }
            if controller.requestedFeature == .ask {
                AIQuestionView(controller: controller.question, openSettings: openSettings)
            } else if controller.requestedFeature.isDocumentTool {
                AIDocumentToolsView(controller: controller.documentTools, feature: controller.requestedFeature, openSettings: openSettings)
            } else {
                if controller.requestedFeature == .translation {
                    Picker(L10n.tr("目标语言"), selection: $controller.translationLanguage) {
                        ForEach(AITranslationLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    if controller.translationLanguage == .custom {
                        TextField(L10n.tr("输入目标语言"), text: $controller.customTranslationLanguage).onSubmit { if canRun { runCurrent() } }
                    }
                } else if controller.requestedFeature == .rewrite {
                    Picker(L10n.tr("改写方式"), selection: $controller.rewriteMode) {
                        ForEach(AIRewriteMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(controller.rewriteMode.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField(controller.rewriteMode.optionPrompt, text: $option)
                        .onSubmit { if canRun { runCurrent() } }
                } else if let prompt = controller.requestedFeature.optionPrompt {
                    TextField(prompt, text: $option)
                        .onSubmit { if canRun { runCurrent() } }
                }
                HStack {
                    Button(controller.isWorking ? L10n.tr("停止") : (controller.requestedFeature == .translation ? L10n.tr("翻译") : L10n.tr("运行"))) {
                        if controller.isWorking { controller.cancel() } else { runCurrent() }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 72)
                    .disabled(!controller.isWorking && !canRun)
                    if controller.isWorking { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在执行…")) }
                }
                if !controller.message.isEmpty {
                    AIPanelMessageView(kind: controller.messageKind, text: controller.message, action: controller.messageAction,
                                       openSettings: openSettings, retry: { runCurrent() },
                                       sendAnyway: { controller.sendAnyway() })
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if controller.requestedFeature == .imageEdit, let data = controller.imageEditSource, let source = NSImage(data: data) {
                            Text(L10n.tr("原图")).font(.caption).foregroundStyle(.secondary)
                            Image(nsImage: source).resizable().scaledToFit().accessibilityLabel(L10n.tr("原图"))
                        }
                        if !controller.report.isEmpty {
                            if controller.feature == .metadata {
                                TextEditor(text: $metadataText).frame(minHeight: 100)
                                Button(L10n.tr("更新元数据")) { controller.updateMetadata(metadataText) }
                            } else {
                                Text(AttributedString(modelMarkdown: controller.report)).textSelection(.enabled)
                            }
                        }
                        if controller.canInsertSummary {
                            Button(L10n.tr("插入摘要")) { controller.insertSummary() }
                        }
                        ForEach(controller.references) { reference in
                            Button { controller.revealReference(reference) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(reference.quote).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.right.circle").accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.plain).help(reference.quote).accessibilityLabel(reference.quote).accessibilityHint(L10n.tr("定位引用"))
                        }
                        if controller.suggestions.count > 1 {
                            HStack {
                                Button(L10n.tr("全部接受（%lld）", controller.suggestions.count)) { controller.acceptAll() }
                                    .buttonStyle(.borderedProminent)
                                Button(L10n.tr("全部拒绝")) { controller.rejectAll() }
                            }
                        }
                        ForEach(controller.suggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.tr("原文")).font(.caption).foregroundStyle(.secondary)
                                Text(controller.wordDiff(for: suggestion).original).textSelection(.enabled)
                                Text(L10n.tr("转换结果")).font(.caption).foregroundStyle(.secondary)
                                Text(controller.wordDiff(for: suggestion).replacement).textSelection(.enabled)
                                if !suggestion.explanation.isEmpty { Text(suggestion.explanation).foregroundStyle(.secondary) }
                                HStack {
                                    Button(L10n.tr("定位")) { controller.reveal(suggestion) }
                                    acceptButton(suggestion, prominent: controller.suggestions.count == 1)
                                    Button(L10n.tr("拒绝")) { controller.reject(suggestion) }
                                }
                            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        if let data = controller.image, let image = NSImage(data: data) {
                            if controller.feature == .imageEdit { Text(L10n.tr("编辑结果")).font(.caption).foregroundStyle(.secondary) }
                            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(L10n.tr("图片"))
                            HStack {
                                if controller.feature == .imageEdit {
                                    Button(L10n.tr("应用")) { controller.applyImageEdit() }.buttonStyle(.borderedProminent)
                                    Button(L10n.tr("另存为…")) { controller.saveEditedImage() }
                                } else {
                                    Button(L10n.tr("保存图片")) { controller.saveImage() }
                                    Button(L10n.tr("插入图片")) { controller.insertImage() }
                                }
                            }
                        }
                        if let sent = controller.sentSummary { Text(sent).font(.caption).foregroundStyle(.secondary) }
                        if let date = controller.generatedAt {
                            Text([date.formatted(date: .abbreviated, time: .shortened),
                                  controller.resultRevision.map { L10n.tr("文本版本：%llu", UInt64($0)) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .frame(minWidth: 260, idealWidth: 320)
        .onExitCommand(perform: controller.isWorking ? { controller.cancel() } : nil)
        .onAppear {
            if !controller.enabledFeatures.contains(controller.requestedFeature), let first = controller.enabledFeatures.first { controller.requestedFeature = first }
        }
        .onChange(of: controller.report) { _, value in metadataText = value }
        .onChange(of: controller.enabledFeatures) { _, features in
            if !features.contains(controller.requestedFeature), let first = features.first { controller.requestedFeature = first }
        }
        .onChange(of: controller.rewriteMode) { _, _ in option = "" }
        .onChange(of: controller.requestedFeature) { _, feature in if feature == .imageEdit { option = "" } }
        .onChange(of: controller.imageEditSource) { _, source in if source != nil { option = "" } }
    }

    private var canRun: Bool {
        controller.enabledFeatures.contains(controller.requestedFeature) && !controller.isWorking &&
            !(controller.requestedFeature == .translation && controller.translationTarget.isEmpty) &&
            !(controller.requestedFeature == .rewrite && controller.rewriteMode.requiresOption && option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
            (controller.requestedFeature != .sources || !option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
            (controller.requestedFeature != .imageEdit || (controller.imageEditSource != nil && !option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private func runCurrent() {
        if controller.requestedFeature == .imageDescription { controller.describeImage() }
        else if controller.requestedFeature == .imageEdit { controller.runImageEdit(prompt: option) }
        else { controller.run(controller.requestedFeature, option: controller.requestedFeature == .translation ? controller.translationTarget : option) }
    }

    @ViewBuilder private func acceptButton(_ suggestion: AIWritingSuggestion, prominent: Bool) -> some View {
        if prominent {
            Button(L10n.tr("接受")) { controller.accept(suggestion) }.buttonStyle(.borderedProminent)
        } else {
            Button(L10n.tr("接受")) { controller.accept(suggestion) }.buttonStyle(.bordered)
        }
    }
}
