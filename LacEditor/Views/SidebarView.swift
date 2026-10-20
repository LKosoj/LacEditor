import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var isSettingsHovering = false

    var body: some View {
        VStack(spacing: 0) {
            SidebarLibraryView(
                recentFiles: appState.recentFiles,
                library: windowManager.sidebarLibrary
            )
            .id(windowManager.primaryReopenGeneration)

            Button {
                SettingsWindowController.shared.present(windowManager: windowManager)
            } label: {
                HStack(spacing: 8) {
                    Label("设置", systemImage: "gearshape")
                    Spacer()
                    if AppEnvironment.isExperiment {
                        Text(AppEnvironment.experimentIteration)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(LacEditorDesign.selectionFill, in: Capsule())
                            .accessibilityLabel("界面实验 \(AppEnvironment.experimentIteration)")
                    }
                }
                    .font(.system(size: 13))
                    .foregroundStyle(isSettingsHovering ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .stableHelp("打开设置", shortcut: "⌘,")
            .frame(height: 40)
            .background(
                isSettingsHovering ? LacEditorDesign.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .onHover { isSettingsHovering = $0 }
        }
        .background(SidebarMaterialBackground())
    }
}
