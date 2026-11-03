import SwiftUI

/// Плашка над текстом страницы хранилища, которую собирает сервер (образец — плашка внешнего изменения файла).
struct VaultPageBannerHost: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let document = appState.selectedDocument {
            VaultPageBanner(document: document)
                .id(document.id)
        }
    }
}

struct VaultPageBanner: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument

    private func message(for mode: VaultPageMode) -> String {
        switch mode {
        case .ownerZone: L10n.tr("页面由服务器生成。只能编辑“Owner Notes”分区")
        case .noZone: L10n.tr("此页面没有“Owner Notes”分区")
        case .damaged: L10n.tr("“Owner Notes”分区的标记已损坏，服务器不会更新此页面")
        case .serverReport: L10n.tr("报告由服务器重新生成")
        }
    }

    private func symbol(for mode: VaultPageMode) -> String {
        switch mode {
        case .ownerZone, .serverReport: "gearshape"
        case .noZone: "lock"
        case .damaged: "exclamationmark.triangle"
        }
    }

    /// Для страниц «только чтение» смысл запрета дублируется словами (значок скрыт от VoiceOver).
    private func spokenText(for mode: VaultPageMode) -> String {
        mode == .ownerZone ? message(for: mode) : message(for: mode) + ". " + L10n.tr("此页面不可编辑")
    }

    private func announce(_ mode: VaultPageMode) {
        guard document.vaultPageGuard?.takeAnnouncement(for: mode) == true else { return }
        AccessibilityNotification.Announcement(spokenText(for: mode)).post()
    }

    var body: some View {
        if let mode = document.vaultPageMode {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: mode))
                        .foregroundStyle(mode == .damaged ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                    Text(message(for: mode))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if mode == .ownerZone {
                        Button(L10n.tr("转到“Owner Notes”")) { appState.goToOwnerNotes() }
                            .fixedSize()
                            .accessibilityIdentifier("vault.page.banner.goto")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(LacEditorDesign.surface)
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(spokenText(for: mode))
            .accessibilityIdentifier("vault.page.banner")
            .onAppear { announce(mode) }
            .onChange(of: document.vaultPageMode) { _, new in
                if let new { announce(new) }
            }
        }
    }
}
