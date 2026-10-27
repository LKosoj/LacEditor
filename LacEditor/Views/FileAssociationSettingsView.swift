import AppKit
import SwiftUI

struct FileAssociationSettingsView: View {
    @StateObject private var service = FileAssociationService()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("当前应用位置")).font(.system(size: 13, weight: .medium))
                Text(service.identity.url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.tr("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([service.identity.url]) }
                    Button(L10n.tr("刷新状态")) { service.refresh() }.disabled(service.changingID != nil)
                }.controlSize(.small)
                if !service.identity.canSetDefaults {
                    Text(L10n.tr("请从「应用程序」中的正式 LacEditor 打开此页。开发、验收、实验或未安装的副本不能设置默认应用。"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(L10n.tr("仅在点击按钮后更改。macOS 按内容类型关联文件，同类型的扩展名会一起更改；部分更改需要在系统提示中确认。已有单个文件的自定义打开方式可能优先于这里的设置。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(service.rows) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.format.title).font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.format.isText ? L10n.tr("当前：%@", String(describing: row.applicationName)) : L10n.tr("系统将此扩展名识别为非文本类型，请在访达按文件设置。"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if service.changingID == row.id {
                            ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在更改默认应用"))
                        } else if row.isCurrentApplication {
                            Label(L10n.tr("已默认"), systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Button(L10n.tr("设为默认")) { Task { await service.setDefault(for: row.id) } }
                                .controlSize(.small)
                                .disabled(!service.identity.canSetDefaults || !row.format.isText || service.changingID != nil)
                                .accessibilityLabel(L10n.tr("将 %@ 设为默认使用 LacEditor", String(describing: row.format.title)))
                        }
                    }.padding(.vertical, 12).padding(.horizontal, 14)
                    if row.id != service.rows.last?.id { Divider().padding(.horizontal, 14) }
                }
            }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LacEditorDesign.outline))
            if let message = service.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("associations.result")
            }
        }
        .onAppear { service.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in service.refresh() }
    }
}
