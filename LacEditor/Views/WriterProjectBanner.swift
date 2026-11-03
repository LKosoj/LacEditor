import SwiftUI

/// Восстановленная вкладка, чей проект не найден.
struct WriterProjectIssue: Equatable {
    let projectTitle: String
    let rootPath: String
}

/// Плашка «Проект не найден» над текстом (образец — плашка внешнего изменения файла).
struct WriterProjectBanner: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let issue = appState.writerProjectIssue {
            let message = L10n.tr("找不到项目“%@”", issue.projectTitle)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Button(L10n.tr("指定文件夹…")) { appState.resolveMissingWriterProject(choosingFolder: true) }
                        .accessibilityIdentifier("writer.banner.choose")
                    Button(L10n.tr("作为普通标签页继续")) { appState.resolveMissingWriterProject(choosingFolder: false) }
                        .accessibilityIdentifier("writer.banner.continue")
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
            .accessibilityLabel(message)
            .accessibilityIdentifier("writer.banner")
            .onAppear { AccessibilityNotification.Announcement(message).post() }
        }
    }
}
