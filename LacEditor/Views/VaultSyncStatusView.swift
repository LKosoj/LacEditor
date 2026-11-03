import SwiftUI

/// Блок синхронизации заметки: слово, значок и цвет вместе; снимки; сравнение с версией сервера.
struct VaultSyncStatusView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: VaultInspectorModel
    let serverPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("同步")).font(.headline).accessibilityAddTraits(.isHeader)
            if let info = model.info {
                let title = VaultNoteStateDescription.title(info.state)
                Label(title, systemImage: VaultNoteStateDescription.symbol(info.state))
                    .foregroundStyle(color(VaultNoteStateDescription.tone(info.state)))
                    .accessibilityLabel(VaultNoteStateDescription.spoken(info.state, isOnline: info.isOnline))
                if !info.isOnline {
                    Label(L10n.tr("未连接"), systemImage: "wifi.slash").foregroundStyle(.secondary)
                }
                if let date = info.serverModified {
                    detail(L10n.tr("服务器版本"), date)
                }
                if let date = info.lastCheck {
                    detail(L10n.tr("最近检查"), date)
                }
                if info.compareSource != nil {
                    Button(L10n.tr("查看服务器的改动")) { appState.showVaultServerChanges(for: serverPath) }
                } else {
                    Text(L10n.tr("服务器在本次会话中尚未改动此笔记")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.tr("正在加载")).foregroundStyle(.secondary)
            }
            Divider()
            SnapshotsSectionView(appState: appState)
            Text(L10n.tr("快照仅在笔记打开期间保留")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ title: String, _ date: Date) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(date, format: .dateTime.day().month().hour().minute())
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func color(_ tone: VaultNoteStateDescription.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .accent: .accentColor
        case .warning: .orange
        case .danger: .red
        }
    }
}
