import SwiftUI

/// Правая панель: переключатель сегментов и содержимое выбранного. Фонов нет (Liquid Glass); ширину задаёт `MainWindowView`.
struct InspectorPanelView: View {
    @ObservedObject var appState: AppState
    var openSettings: () -> Void

    private var selection: Binding<InspectorSegment> {
        Binding(
            get: { appState.effectiveInspectorSegment },
            set: { segment in
                appState.inspectorSegment = segment
                // Запоминается только выбор пользователя; программные смены сегмента на диск не пишутся.
                InspectorSegment.store(segment, isWriter: appState.inspectorIsWriterTab, isVault: appState.inspectorIsVaultTab)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.tr("检查器"), selection: selection) {
                ForEach(InspectorSegment.available(isWriter: appState.inspectorIsWriterTab, isVault: appState.inspectorIsVaultTab)) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityLabel(L10n.tr("检查器"))
            Divider()
            switch appState.effectiveInspectorSegment {
            case .scene:
                if let session = appState.writerSession {
                    SceneInspectorView(session: session, appState: appState)
                }
            case .style:
                StyleInspectorView(controller: appState.styleCheck, openSettings: openSettings)
            case .vaultNote:
                VaultNoteInspectorView(appState: appState)
            case .vaultLinks:
                VaultLinksInspectorView(appState: appState)
            case .vaultAsk:
                VaultAskInspectorView(appState: appState)
            case .ai:
                AIWritingView(controller: appState.aiWriting, openSettings: openSettings)
            }
        }
        .onChange(of: appState.inspectorIsWriterTab) { _, isWriter in
            appState.inspectorSegment = InspectorSegment.stored(isWriter: isWriter, isVault: appState.inspectorIsVaultTab)
        }
        .onChange(of: appState.inspectorIsVaultTab) { _, isVault in
            appState.inspectorSegment = InspectorSegment.stored(isWriter: appState.inspectorIsWriterTab, isVault: isVault)
        }
        .onAppear {
            // Панель была скрыта, пока вкладка стала вкладкой хранилища: onChange не сработал, берём сохранённый сегмент.
            if appState.inspectorIsVaultTab, !appState.inspectorIsWriterTab, !appState.inspectorSegmentIsExplicit {
                appState.inspectorSegment = InspectorSegment.stored(isWriter: false, isVault: true)
            }
        }
        .onDisappear { appState.inspectorSegmentIsExplicit = false }
    }
}
