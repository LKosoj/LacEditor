import SwiftUI

/// Состояние хранилища в строке состояния: значок и слово; при узкой ширине — только значок (подпись для VoiceOver остаётся).
struct VaultStatusBarItem: View {
    @ObservedObject var session: VaultSession
    let appState: AppState
    let compact: Bool

    var body: some View {
        let status = session.status
        menu(status: status)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(session.connectionIssue ?? L10n.tr("笔记库“%@”：%@", session.connection.name, session.statusText))
            .accessibilityLabel(L10n.tr("笔记库“%@”：%@", session.connection.name, session.statusText))
            .accessibilityIdentifier("status.vault")
            .onChange(of: session.isOnline) { _, isOnline in
                if isOnline { AccessibilityNotification.Announcement(L10n.tr("与服务器的连接已恢复")).post() }
            }
    }

    /// «Нужно внимание: N»: щелчок сразу ведёт к «Неотправленному» (или «Конфликтам»), меню открывается по стрелке.
    /// В остальных состояниях щелчок открывает меню.
    @ViewBuilder
    private func menu(status: VaultStatus) -> some View {
        if case .attention = status {
            Menu { items } label: { label(status) } primaryAction: {
                appState.showVaultUnsent(conflicts: session.attentionUnsentCount == 0 && session.conflictCount > 0)
            }
        } else {
            Menu { items } label: { label(status) }
        }
    }

    private func label(_ status: VaultStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName).font(.caption2)
            if !compact { Text(session.statusText).font(.subheadline).lineLimit(1) }
        }
        .foregroundStyle(status == .online ? Color.secondary : Color.primary)
    }

    @ViewBuilder
    private var items: some View {
        if session.needsStateAttention {
            Button(L10n.tr("处理本地状态…")) { appState.confirmVaultStateAttention() }
            Divider()
        }
        if session.unsentCount > 0 {
            Button(L10n.tr("未上传的笔记")) { appState.showVaultUnsent() }
        }
        if session.conflictCount > 0 {
            Button(L10n.tr("冲突的笔记")) { appState.showVaultUnsent(conflicts: true) }
        }
        if !session.isOnline || session.connectionIssue != nil {
            Button(L10n.tr("重试")) { session.connectivityMayHaveChanged(); Task { await session.checkAndReload() } }
        }
        Button(L10n.tr("立即检查更新")) { appState.checkVaultNow() }
        Button(L10n.tr("打开“今天”")) { appState.windowManager?.openVaultDailyNote(from: appState) }
        Divider()
        Button(L10n.tr("笔记库设置…")) { appState.presentVaultConnectionSheet(preselectedID: session.connection.id) }
        Button(L10n.tr("关闭笔记库")) { Task { await appState.windowManager?.leaveVault() } }
    }
}
