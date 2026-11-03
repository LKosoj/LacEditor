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
                InspectorSegment.store(segment, isWriter: appState.inspectorIsWriterTab)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.tr("检查器"), selection: selection) {
                ForEach(InspectorSegment.available(isWriter: appState.inspectorIsWriterTab)) { segment in
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
            case .ai:
                AIWritingView(controller: appState.aiWriting, openSettings: openSettings)
            }
        }
        .onChange(of: appState.inspectorIsWriterTab) { _, isWriter in
            appState.inspectorSegment = InspectorSegment.stored(isWriter: isWriter)
        }
    }
}
