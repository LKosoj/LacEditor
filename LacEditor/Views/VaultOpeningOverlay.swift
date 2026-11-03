import SwiftUI

/// Вкладка заметки хранилища, у которой текст ещё не пришёл: «Загружается…», «Сервер отвечает медленно»,
/// «Заметка откроется, когда появится связь» или причина, по которой заметка не открылась. Ввод в приложении не блокируется.
struct VaultOpeningOverlay: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var message: String? {
        if let issue = appState.vaultOpeningIssue { return issue }
        switch appState.vaultOpening {
        case .loading: return L10n.tr("正在加载")
        case .slow: return L10n.tr("服务器响应较慢")
        case .waitingForConnection: return L10n.tr("笔记将在连接恢复后打开")
        case nil: return nil
        }
    }

    var body: some View {
        if let message {
            VStack(spacing: 10) {
                if appState.vaultOpening == .loading || appState.vaultOpening == .slow {
                    // Без анимации (Reduce Motion) крутящийся индикатор заменяется статичным значком.
                    if reduceMotion {
                        Image(systemName: "ellipsis.circle").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Image(systemName: appState.vaultOpeningIssue == nil ? "icloud.slash" : "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text(message).font(.callout).multilineTextAlignment(.center)
                if appState.vaultOpening == .slow {
                    Text(L10n.tr("正在加载")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if appState.vaultOpening == .waitingForConnection || appState.vaultOpeningIssue != nil {
                        Button(L10n.tr("重试")) { appState.retryVaultOpening() }
                    }
                    Button(L10n.tr("取消")) { appState.cancelVaultOpening() }
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .lacEditorBackground))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message)
            .onAppear { AccessibilityNotification.Announcement(message).post() }
            .onChange(of: message) { _, text in
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }
}
