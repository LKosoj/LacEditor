import AppKit
import SwiftUI

struct AIWritingView: View {
    @ObservedObject var controller: AIWritingController
    @State private var option = ""
    @State private var metadataText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("AI 写作助手")).font(.headline)
            if controller.enabledFeatures.isEmpty {
                Text(L10n.tr("请在设置中启用 AI 功能")).foregroundStyle(.secondary)
            } else {
                Picker(L10n.tr("功能"), selection: $controller.requestedFeature) {
                    ForEach(controller.enabledFeatures) { feature in Text(feature.title).tag(feature) }
                }
            }
            if controller.requestedFeature.isDocumentTool {
                AIDocumentToolsView(controller: controller.documentTools, feature: controller.requestedFeature)
            } else {
                if controller.requestedFeature == .translation {
                    Picker(L10n.tr("目标语言"), selection: $controller.translationLanguage) {
                        ForEach(AITranslationLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    if controller.translationLanguage == .custom {
                        TextField(L10n.tr("输入目标语言"), text: $controller.customTranslationLanguage)
                    }
                } else {
                    TextField(L10n.tr("语言、语气或其他要求"), text: $option)
                }
                HStack {
                    Button(controller.requestedFeature == .translation ? L10n.tr("翻译") : L10n.tr("运行")) {
                        if controller.requestedFeature == .imageDescription { controller.describeImage() }
                        else { controller.run(controller.requestedFeature, option: controller.requestedFeature == .translation ? controller.translationTarget : option) }
                    }.disabled(!controller.enabledFeatures.contains(controller.requestedFeature) || controller.isWorking || (controller.requestedFeature == .translation && controller.translationTarget.isEmpty))
                    if controller.isWorking { Button(L10n.tr("取消")) { controller.cancel() }; ProgressView().controlSize(.small) }
                }
                if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.secondary).textSelection(.enabled) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let date = controller.generatedAt {
                            Text(date, style: .date).foregroundStyle(.secondary)
                            Text(date, style: .time).foregroundStyle(.secondary)
                            if let revision = controller.resultRevision {
                                Text(L10n.tr("文本版本：%llu", UInt64(revision))).foregroundStyle(.secondary)
                            }
                        }
                        if !controller.report.isEmpty {
                            if controller.feature == .metadata {
                                TextEditor(text: $metadataText).frame(minHeight: 100)
                                Button(L10n.tr("更新元数据")) { controller.updateMetadata(metadataText) }
                            } else {
                                Text((try? AttributedString(markdown: controller.report)) ?? AttributedString(controller.report)).textSelection(.enabled)
                            }
                        }
                        if controller.canInsertSummary {
                            Button(L10n.tr("插入摘要")) { controller.insertSummary() }
                        }
                        ForEach(controller.references) { reference in
                            Button(reference.quote) { controller.revealReference(reference) }
                        }
                        ForEach(controller.suggestions) { suggestion in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.tr("原文")).font(.caption).foregroundStyle(.secondary)
                                Text(suggestion.original).textSelection(.enabled)
                                Text(L10n.tr("转换结果")).font(.caption).foregroundStyle(.secondary)
                                Text(suggestion.replacement).textSelection(.enabled)
                                if !suggestion.explanation.isEmpty { Text(suggestion.explanation).foregroundStyle(.secondary) }
                                HStack {
                                    Button(L10n.tr("定位")) { controller.reveal(suggestion) }
                                    Button(L10n.tr("接受")) { controller.accept(suggestion) }
                                    Button(L10n.tr("拒绝")) { controller.reject(suggestion) }
                                }
                            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        if let data = controller.image, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit()
                            HStack {
                                Button(L10n.tr("保存图片")) { controller.saveImage() }
                                Button(L10n.tr("插入图片")) { controller.insertImage() }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .frame(minWidth: 260, idealWidth: 320)
        .onAppear {
            if !controller.enabledFeatures.contains(controller.requestedFeature), let first = controller.enabledFeatures.first { controller.requestedFeature = first }
        }
        .onChange(of: controller.report) { _, value in metadataText = value }
        .onChange(of: controller.enabledFeatures) { _, features in
            if !features.contains(controller.requestedFeature), let first = features.first { controller.requestedFeature = first }
        }
    }
}
