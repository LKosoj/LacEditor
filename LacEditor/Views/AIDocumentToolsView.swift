import SwiftUI

/// Сообщение панели: тип и действие задаёт контроллер, а не текст сообщения.
struct AIPanelMessageView: View {
    let kind: StatusKind
    let text: String
    let action: AIMessageAction?
    var openSettings: () -> Void
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusMessageView(kind: kind, text: text)
            switch action {
            case .openSettings: Button(L10n.tr("打开 AI 设置")) { openSettings() }
            case .retry: Button(L10n.tr("重试")) { retry() }
            case nil: EmptyView()
            }
        }
    }
}

struct AIDocumentToolsView: View {
    @ObservedObject var controller: AIDocumentToolsController
    let feature: AIFeature
    var openSettings: () -> Void = {}

    private func submit() {
        guard controller.isEnabled(feature), !controller.isWorking, !controller.recorder.isRecording else { return }
        controller.run(feature)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.isEnabled(feature) {
                StatusMessageView(kind: .info, text: L10n.tr("AI 功能已关闭"))
                Button(L10n.tr("打开 AI 设置")) { openSettings() }
            }
            Group {
                if feature == .contextReview {
                Menu(L10n.tr("添加已打开的文档")) {
                    ForEach(controller.documents) { document in
                        Button(document.displayName) {
                            let input = AIContextInput.document(document.id)
                            if !controller.inputs.contains(input) { controller.inputs.append(input) }
                        }
                    }
                }
                Button(L10n.tr("添加文件")) { controller.addFiles() }
                ForEach(controller.inputs) { input in
                    HStack {
                        Text(controller.name(input)).lineLimit(1).truncationMode(.middle)
                        Button(L10n.tr("移除")) { controller.inputs.removeAll { $0 == input } }
                            .accessibilityLabel(L10n.tr("移除 %@", controller.name(input)))
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
                Button(L10n.tr("选择文件")) { controller.chooseFile(feature: feature) }.disabled(controller.isWorking)
                if let url = controller.fileURL { Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                if feature == .voiceDraft {
                    if controller.recorder.isRecording {
                        Button(L10n.tr("停止录音")) { controller.stopRecording() }
                        if let start = controller.recorder.startedAt {
                            TimelineView(.periodic(from: start, by: 1)) { context in
                                HStack(spacing: 6) {
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                    Text(Duration.seconds(Int(context.date.timeIntervalSince(start))).formatted(.time(pattern: .minuteSecond)))
                                        .monospacedDigit()
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(L10n.tr("正在录音"))
                            }
                        }
                    } else {
                        Button(L10n.tr("开始录音")) { controller.startRecording() }.disabled(controller.isWorking)
                    }
                }
            }
            if AIDocumentToolsController.usesOption(feature) {
                TextField(L10n.tr("其他要求"), text: $controller.option).onSubmit { submit() }
            }
            HStack {
                Button(controller.isWorking ? L10n.tr("停止") : L10n.tr("运行")) {
                    if controller.isWorking { controller.stop() } else { controller.run(feature) }
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 72)
                .disabled(!controller.isWorking && controller.recorder.isRecording)
                if controller.isWorking { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在执行…")) }
            }
            }
            .disabled(!controller.isEnabled(feature))
            if !controller.message.isEmpty {
                AIPanelMessageView(kind: controller.messageKind, text: controller.message, action: controller.messageAction,
                                   openSettings: openSettings, retry: { controller.run(feature) })
            }
            if controller.isResultStale { StatusMessageView(kind: .info, text: L10n.tr("参数已更改，下方结果对应之前的设置。请重新运行。")) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !controller.differences.isEmpty {
                        Text(L10n.tr("文本差异")).font(.headline).accessibilityAddTraits(.isHeader)
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
                                Button(L10n.tr("插入")) { controller.insert() }.disabled(controller.isResultStale)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onExitCommand(perform: controller.isWorking ? { controller.stop() } : nil)
        .onDisappear { controller.hidden() }
        .onChange(of: feature) { _, _ in controller.hidden(); controller.clearResult() }
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
