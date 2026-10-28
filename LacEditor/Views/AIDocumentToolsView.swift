import SwiftUI

struct AIDocumentToolsView: View {
    @ObservedObject var controller: AIDocumentToolsController
    let feature: AIFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if feature == .contextReview {
                Menu(L10n.tr("添加已打开的文档")) {
                    ForEach(controller.documents) { document in
                        Button(document.displayName) {
                            let input = AIContextInput.document(document.id)
                            if !controller.inputs.contains(input) { controller.inputs.append(input); controller.clearResult() }
                        }
                    }
                }
                Button(L10n.tr("添加文件")) { controller.addFiles() }
                ForEach(controller.inputs) { input in
                    HStack {
                        Text(controller.name(input)).lineLimit(1)
                        Button(L10n.tr("移除")) { controller.inputs.removeAll { $0 == input }; controller.clearResult() }
                    }
                }
            }
            if feature == .compareVersions {
                comparisonPicker(L10n.tr("原版本"), selection: $controller.before, isBefore: true)
                comparisonPicker(L10n.tr("新版本"), selection: $controller.after, isBefore: false)
            }
            if feature == .customCheck {
                Picker(L10n.tr("检查"), selection: $controller.checkID) {
                    Text(L10n.tr("请选择")).tag(Optional<UUID>.none)
                    ForEach(controller.checks) { check in Text(check.name).tag(Optional(check.id)) }
                }
                if let check = controller.checks.first(where: { $0.id == controller.checkID }) {
                    Text(check.instructions).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if feature == .recognizeDocument || feature == .voiceDraft {
                Button(L10n.tr("选择文件")) { controller.chooseFile(feature: feature) }
                if let url = controller.fileURL { Text(url.lastPathComponent).lineLimit(1) }
                if feature == .voiceDraft {
                    if controller.recorder.isRecording {
                        Button(L10n.tr("停止录音")) { controller.stopRecording() }
                    } else {
                        Button(L10n.tr("开始录音")) { controller.startRecording() }.disabled(controller.isWorking)
                    }
                }
            }
            if [.contextReview, .compareVersions, .customCheck, .mermaid, .explain].contains(feature) {
                TextField(L10n.tr("其他要求"), text: $controller.option)
            }
            HStack {
                Button(L10n.tr("运行")) { controller.run(feature) }.disabled(controller.isWorking || controller.recorder.isRecording)
                if controller.isWorking { Button(L10n.tr("取消")) { controller.clearResult() }; ProgressView().controlSize(.small) }
            }
            if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.secondary).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !controller.differences.isEmpty {
                        Text(L10n.tr("文本差异")).font(.headline)
                        Text(controller.differences).textSelection(.enabled)
                    }
                    if !controller.report.isEmpty {
                        Text(controller.report).textSelection(.enabled)
                        ForEach(controller.references) { reference in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(controller.referenceName(reference)).font(.caption).foregroundStyle(.secondary)
                                Text(reference.quote).textSelection(.enabled)
                                Button(controller.isOpenDocument(reference) ? L10n.tr("定位引用") : L10n.tr("打开来源文件")) {
                                    controller.openReference(reference)
                                }
                            }
                        }
                        HStack {
                            Button(L10n.tr("复制")) { controller.copy() }
                            if [.recognizeDocument, .voiceDraft, .mermaid].contains(feature) {
                                Button(L10n.tr("插入")) { controller.insert() }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(!controller.isEnabled(feature))
        .onDisappear { controller.hidden() }
        .onChange(of: feature) { _, _ in controller.hidden(); controller.clearResult() }
        .onChange(of: controller.before) { _, _ in controller.clearResult() }
        .onChange(of: controller.after) { _, _ in controller.clearResult() }
        .onChange(of: controller.checkID) { _, _ in controller.clearResult() }
        .onChange(of: controller.option) { _, _ in controller.clearResult() }
    }

    private func comparisonPicker(_ title: String, selection: Binding<AIContextInput?>, isBefore: Bool) -> some View {
        HStack {
            Picker(title, selection: selection) {
                Text(L10n.tr("请选择")).tag(Optional<AIContextInput>.none)
                ForEach(controller.documents) { document in
                    Text(document.displayName).tag(Optional(AIContextInput.document(document.id)))
                }
                if let input = selection.wrappedValue {
                    switch input {
                    case .file:
                        Text(controller.name(input)).tag(Optional(input))
                    case .document(let id):
                        if !controller.documents.contains(where: { $0.id == id }) {
                            Text(controller.name(input)).tag(Optional(input))
                        }
                    }
                }
            }
            Button(L10n.tr("选择文件")) { controller.chooseComparisonFile(before: isBefore) }
        }
    }
}
