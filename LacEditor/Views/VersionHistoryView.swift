import SwiftUI

struct VersionHistoryView: View {
    @ObservedObject var controller: VersionHistoryController
    let fileName: String
    let close: () -> Void

    private var leftName: String {
        controller.mode == .history ? L10n.tr("历史版本") : L10n.tr("磁盘文件")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.mode == .history ? L10n.tr("历史版本") : L10n.tr("与磁盘文件比较"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(fileName).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                if controller.mode == .history { versionList.frame(width: 240) }
                diff
            }
            if let message = controller.message {
                StatusMessageView(kind: controller.messageKind, text: message)
            }
            HStack {
                if controller.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.tr("刷新")) { controller.refresh() }
                    .accessibilityIdentifier("versions.refresh")
                if controller.mode == .history {
                    Button(L10n.tr("恢复此版本")) { controller.restore() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.canRestore)
                        .accessibilityIdentifier("versions.restore")
                }
                Button(L10n.tr("关闭")) { close() }
                    .accessibilityIdentifier("versions.close")
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 560)
        .onExitCommand { close() }
        .onAppear { controller.start() }
        .onDisappear { controller.cancel() }
    }

    private var versionList: some View {
        List(selection: Binding(get: { controller.selectedID }, set: { if let id = $0 { controller.select(id) } })) {
            ForEach(controller.versions) { version in
                VStack(alignment: .leading, spacing: 2) {
                    if let date = version.date {
                        Text(date, format: .dateTime.year().month().day().hour().minute().second())
                    } else {
                        Text("—")
                    }
                    if let computer = version.computerName {
                        Text(L10n.tr("保存的计算机：%@", computer)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(version.id)
            }
        }
        .overlay {
            if controller.versions.isEmpty && !controller.isLoading {
                Text(L10n.tr("保存此文件时会自动记录历史版本。"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .accessibilityIdentifier("versions.list")
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("左侧：%@；右侧：当前文本", leftName)).font(.caption).foregroundStyle(.secondary)
            if controller.hasResult {
                if controller.changes.isEmpty {
                    Text(L10n.tr("与当前文本相同")).font(.subheadline)
                } else {
                    Text(summary).font(.subheadline)
                }
            }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.changes.indices, id: \.self) { index in
                        row(controller.changes[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .border(Color(nsColor: .separatorColor))
            .accessibilityIdentifier("versions.diff")
        }
    }

    private var summary: String {
        let added = controller.changes.filter { $0.kind == .added }.count
        return L10n.tr("新增 %lld 行，删除 %lld 行", added, controller.changes.count - added)
    }

    private func row(_ change: AITextComparison.Change) -> some View {
        let isAdded = change.kind == .added
        let text = change.text.trimmingCharacters(in: .newlines)
        return HStack(alignment: .top, spacing: 8) {
            Text("\(change.line)").frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
            Text(isAdded ? "+" : "−")
            Text(text)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isAdded ? Color.green : Color.red).opacity(0.18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("%@，第 %lld 行：%@", isAdded ? L10n.tr("已添加") : L10n.tr("已删除"), change.line, text))
    }
}
