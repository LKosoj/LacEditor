import AppKit
import SwiftUI

struct FileAssociationSettingsView: View {
    @StateObject private var service = FileAssociationService()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferenceGroup(title: L10n.tr("当前应用位置")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(service.identity.url.path).font(.subheadline).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.tr("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([service.identity.url]) }
                        Button(L10n.tr("刷新状态")) { service.refresh() }.disabled(service.changingID != nil)
                    }.controlSize(.small)
                    if !service.identity.canSetDefaults {
                        Text(L10n.tr("请从「应用程序」中的正式 LacEditor 打开此页。开发、验收、实验或未安装的副本不能设置默认应用。"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.tr("文件关联诊断")).font(.caption).bold()
                            Text(L10n.tr("Bundle ID：%@", service.identity.identifier ?? L10n.tr("未提供")))
                            Text(L10n.tr("文件类型声明：%@", service.identity.declaresAssociations ? "Alternate" : L10n.tr("未声明")))
                            Text(L10n.tr("安装路径匹配：%@", service.identity.isInstalledPath ? L10n.tr("是") : L10n.tr("否")))
                            Text(L10n.tr("解析后的路径：%@", service.identity.resolvedPath))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Text(L10n.tr("仅在点击按钮后更改。macOS 按内容类型关联文件，同类型的扩展名会一起更改；部分更改需要在系统提示中确认。已有单个文件的自定义打开方式可能优先于这里的设置。"))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PreferenceGroup(title: L10n.tr("文件格式")) {
                ForEach(service.rows) { row in
                    PreferenceRow(
                        title: row.format.title,
                        detail: row.format.isText ? L10n.tr("当前：%@", String(describing: row.applicationName)) : L10n.tr("系统将此扩展名识别为非文本类型，请在访达按文件设置。")
                    ) {
                        if service.changingID == row.id {
                            ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在更改默认应用"))
                        } else if row.isCurrentApplication {
                            Label(L10n.tr("已默认"), systemImage: "checkmark").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            let disabledReason: String? = !service.identity.canSetDefaults
                                ? L10n.tr("请从「应用程序」中的正式 LacEditor 打开此页。开发、验收、实验或未安装的副本不能设置默认应用。")
                                : !row.format.isText ? L10n.tr("系统将此扩展名识别为非文本类型，请在访达按文件设置。")
                                : service.changingID != nil ? L10n.tr("正在更改默认应用") : nil
                            Button(L10n.tr("设为默认")) { Task { await service.setDefault(for: row.id) } }
                                .controlSize(.small)
                                .disabled(disabledReason != nil)
                                .help(disabledReason ?? "")
                                .accessibilityLabel(L10n.tr("将 %@ 设为默认使用 LacEditor", String(describing: row.format.title)))
                        }
                    }
                    if row.id != service.rows.last?.id { SettingsRowDivider() }
                }
            }
            if let message = service.message {
                StatusMessageView(kind: service.messageKind, text: message)
                    .accessibilityIdentifier("associations.result")
            }
        }
        .onAppear { service.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in service.refresh() }
    }
}
