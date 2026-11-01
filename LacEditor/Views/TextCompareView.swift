import SwiftUI

struct TextCompareView: View {
    @ObservedObject var controller: TextCompareController
    let close: () -> Void

    private func label(_ name: String, _ isUnsaved: Bool) -> String {
        isUnsaved ? L10n.tr("%@（未保存）", name) : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("比较文本"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if !controller.candidates.isEmpty || controller.canChooseFile {
                HStack {
                    Picker(L10n.tr("比较对象"), selection: Binding(
                        get: { controller.source?.id ?? "" },
                        set: { if !$0.isEmpty { controller.select($0) } }
                    )) {
                        if controller.source == nil { Text("—").tag("") }
                        ForEach(controller.candidates) { candidate in
                            Text(label(candidate.name, candidate.isUnsaved)).tag(candidate.id)
                        }
                    }
                    .accessibilityIdentifier("compare.picker")
                    if controller.canChooseFile {
                        Button(L10n.tr("选择文件…")) { controller.chooseFileTapped() }
                            .accessibilityIdentifier("compare.chooseFile")
                    }
                }
            }
            diff
            if let message = controller.message {
                StatusMessageView(kind: controller.messageKind, text: message)
            }
            HStack {
                if controller.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.tr("刷新")) { controller.refresh() }
                    .disabled(controller.source == nil)
                    .accessibilityIdentifier("compare.refresh")
                Button(L10n.tr("关闭")) { close() }
                    .accessibilityIdentifier("compare.close")
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 560)
        .onExitCommand { close() }
        .onAppear { controller.start() }
        .onDisappear { controller.cancel() }
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = controller.source {
                Text(L10n.tr("左侧：%@；右侧：%@",
                             label(source.name, source.isUnsaved),
                             label(controller.currentName, controller.currentIsUnsaved)))
                    .font(.caption).foregroundStyle(.secondary)
                if controller.hasResult {
                    Text(controller.changes.isEmpty ? L10n.tr("没有差异") : textDiffSummary(controller.changes))
                        .font(.subheadline)
                }
            } else {
                Text(L10n.tr("请选择要比较的文档或文件")).font(.subheadline).foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.changes.indices, id: \.self) { index in
                        TextDiffRow(change: controller.changes[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .border(Color(nsColor: .separatorColor))
            .accessibilityIdentifier("compare.diff")
        }
    }
}
