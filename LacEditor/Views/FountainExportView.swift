import SwiftUI

struct FountainExportView: View {
    @ObservedObject var controller: FountainExportController
    @EnvironmentObject private var appState: AppState
    let close: () -> Void

    private var isOversize: Bool {
        if case .confirmingOversize = controller.phase { return true }
        return false
    }

    private var aiAvailable: Bool { controller.aiAvailability == .available }

    private var progress: String? {
        switch controller.phase {
        case let .adapting(done, total): L10n.tr("正在改编第 %d 个场景，共 %d 个", min(done + 1, total), total)
        case let .confirmingOversize(scene, _): L10n.tr("第 %d 个场景", scene)
        case .preparing: L10n.tr("正在读取…")
        case .idle: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("导出为 Fountain 剧本"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(controller.scope == .project ? L10n.tr("整个项目") : L10n.tr("当前文档"))
                .font(.subheadline).foregroundStyle(.secondary)
            modePicker
            if let progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let status = controller.status {
                StatusMessageView(kind: status.kind, text: status.text)
            }
            buttons
        }
        .padding(16)
        .frame(minWidth: 480)
        .accessibilityIdentifier("fountainExportSheet")
        .onExitCommand { cancelOrClose() }
        .onDisappear { controller.windowClosed() }
        .onReceive(appState.preferences.objectWillChange.receive(on: DispatchQueue.main)) { _ in
            controller.refreshAvailability()
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            modeRow(.structure, title: L10n.tr("按结构转换"), detail: L10n.tr("不使用 AI，快速且结果可预测。"),
                    identifier: "fountainModeStructure", enabled: true)
            modeRow(.adaptation, title: L10n.tr("用 AI 改编为剧本"), detail: L10n.tr("AI 会按场景把叙述文字改写成剧本格式。"),
                    identifier: "fountainModeAdaptation", enabled: aiAvailable)
            if !aiAvailable {
                AIRecommendationHint(feature: .fountainAdaptation, message: L10n.tr("开启 AI，把叙述文字改写成剧本格式"))
            }
        }
        .disabled(controller.isWorking)
    }

    private func modeRow(_ mode: FountainExportController.Mode, title: String, detail: String, identifier: String, enabled: Bool) -> some View {
        Button {
            controller.mode = mode
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: controller.mode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(controller.mode == mode ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(controller.mode == mode ? .isSelected : [])
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(controller.isWorking ? L10n.tr("取消") : L10n.tr("关闭")) { cancelOrClose() }
                .accessibilityIdentifier("fountainCancelButton")
            if controller.mode == .structure {
                Button(L10n.tr("在新标签页打开")) { controller.start(saveToFile: false) }
                    .disabled(controller.isWorking)
                    .accessibilityIdentifier("fountainOpenTabButton")
                Button(L10n.tr("导出…")) { controller.start(saveToFile: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.isWorking)
                    .accessibilityIdentifier("fountainExportButton")
            } else if isOversize {
                Button(L10n.tr("仍然发送")) { controller.confirmOversize() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("fountainStartButton")
            } else {
                Button(L10n.tr("开始改编")) { controller.start(saveToFile: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.isWorking || !aiAvailable)
                    .accessibilityIdentifier("fountainStartButton")
            }
        }
    }

    private func cancelOrClose() {
        if controller.isWorking { controller.cancel() } else { close() }
    }
}
