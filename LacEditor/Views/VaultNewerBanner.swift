import SwiftUI

/// Плашка над текстом заметки хранилища: «На сервере новее», «Файл удалён на сервере», конфликт, отказ сервера;
/// под ней — сообщение «Добавлены изменения с сервера» (образец — `WriterProjectBanner`).
struct VaultNewerBannerHost: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let kind = appState.vaultBanner {
                banner(kind)
            }
            VaultMergeNoticeRow(upload: appState.vaultUpload)
        }
    }

    private func banner(_ kind: VaultBannerKind) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: kind))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message(for: kind)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                switch kind {
                case .newerOnServer:
                    Button(L10n.tr("加载服务器版本")) { appState.loadVaultServerVersion() }
                        .accessibilityIdentifier("vault.banner.load")
                    Button(L10n.tr("保留我的修改")) { appState.keepLocalVaultVersion() }
                        .accessibilityIdentifier("vault.banner.keep")
                case .deletedOnServer:
                    Button(L10n.tr("保留我的修改")) { appState.keepLocalVaultVersion() }
                        .accessibilityIdentifier("vault.banner.keep")
                    // Общее «Сохранить как…» выводит заметку из хранилища: текст остаётся обычным файлом.
                    Button(L10n.tr("另存为…")) { appState.saveAs() }
                        .accessibilityIdentifier("vault.banner.saveAs")
                case .conflict:
                    Button(L10n.tr("解决冲突…")) {
                        if let path = appState.vaultNote?.path { appState.presentVaultConflict(serverPath: path) }
                    }
                    .accessibilityIdentifier("vault.banner.resolve")
                case .rejected(let issue):
                    if issue.isRetryable {
                        Button(L10n.tr("重试")) {
                            if let path = appState.vaultNote?.path { appState.sendVaultNow(path) }
                        }
                        .accessibilityIdentifier("vault.banner.retry")
                    }
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
        .accessibilityLabel(message(for: kind))
        .accessibilityIdentifier("vault.banner")
        .onAppear { AccessibilityNotification.Announcement(message(for: kind)).post() }
    }

    private func symbol(for kind: VaultBannerKind) -> String {
        switch kind {
        case .newerOnServer: "icloud.and.arrow.down"
        case .rejected: "xmark.octagon"
        default: "exclamationmark.triangle"
        }
    }

    private func message(for kind: VaultBannerKind) -> String {
        switch kind {
        case .newerOnServer: L10n.tr("服务器上有更新")
        case .deletedOnServer: L10n.tr("文件已在服务器上删除")
        case .conflict: L10n.tr("这篇笔记与服务器上的修改冲突。你的修改保存在此 Mac 上。")
        case .rejected(let issue): L10n.tr("服务器没有接受这篇笔记的修改（%@）", issue.userMessage)
        }
    }
}

/// «Добавлены изменения с сервера · Показать · Отменить»: пропадает само через 10 секунд.
struct VaultMergeNoticeRow: View {
    @ObservedObject var upload: VaultUploadUIState
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedButton: String?
    @State private var isHovered = false

    /// Курсор над сообщением или фокус на его кнопках: сообщение не скрывается само.
    private func updateEngaged() { upload.noticeIsEngaged = isHovered || focusedButton != nil }

    var body: some View {
        if upload.mergeNotice != nil {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(L10n.tr("已添加服务器的修改")).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(L10n.tr("查看改动")) { appState.showVaultMergeChanges() }
                        .focused($focusedButton, equals: "show")
                        .accessibilityIdentifier("vault.merge.show")
                    Button(L10n.tr("撤销")) { appState.undoVaultMerge() }
                        .focused($focusedButton, equals: "undo")
                        .accessibilityIdentifier("vault.merge.undo")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(LacEditorDesign.surface)
                Divider()
            }
            .onHover { isHovered = $0; updateEngaged() }
            .onChange(of: focusedButton) { _, _ in updateEngaged() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("已添加服务器的修改"))
            .accessibilityIdentifier("vault.merge")
        }
    }
}
