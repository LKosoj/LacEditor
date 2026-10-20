import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var isSettingsHovering = false
    @State private var filterQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                TextField("筛选文件", text: $filterQuery)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("筛选侧边栏文件")
                    .onExitCommand { filterQuery = "" }
                if !filterQuery.isEmpty {
                    Button { filterQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("清除筛选")
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            .stableHelp("按文件名或分组筛选，不搜索文件正文")

            SidebarLibraryView(
                recentFiles: appState.recentFiles,
                library: windowManager.sidebarLibrary,
                query: filterQuery
            )
            .id(windowManager.primaryReopenGeneration)

            if let samples = windowManager.experimentSamples {
                ExperimentSampleControls(samples: samples)
            }

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
            .buttonStyle(SoftRowButtonStyle())
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

private struct ExperimentSampleControls: View {
    @ObservedObject var samples: ExperimentSampleLibrary
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                windowManager.openExperimentWelcome(in: appState)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                    Text(samples.isPreparing ? "正在准备示例…" : "打开体验文档")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 9))
                }.font(.system(size: 11)).padding(.horizontal, 9).frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietActionButtonStyle())
            .foregroundStyle(.secondary)
            .disabled(samples.isPreparing)
            .contextMenu {
                Button("补充缺失的示例文件", systemImage: "arrow.clockwise") {
                    Task { await samples.prepare(in: windowManager.sidebarLibrary, supplement: true) }
                }
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: samples.rootURL.path)
                }
            }
            if let error = samples.errorMessage {
                Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9)
            }
        }.padding(.horizontal, 10)
    }
}
