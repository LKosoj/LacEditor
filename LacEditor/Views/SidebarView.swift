import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var isSettingsHovering = false
    @State private var filterQuery = ""
    @FocusState private var filterFocused: Bool
    @FocusState private var settingsFocused: Bool
    @FocusState private var clearFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let document = appState.selectedDocument, document.language == .markdown {
                DisclosureGroup(isExpanded: $appState.isMarkdownOutlineExpanded) {
                    MarkdownOutlineView(document: document, maximumLevel: appState.preferences.markdownTOCMaxLevel) { heading in
                        appState.revealMarkdownHeading(heading, in: document)
                    }
                } label: {
                    Text(L10n.tr("文档大纲"))
                        .font(.subheadline.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                }
                // одна величина горизонтального отступа (10) для оглавления, фильтра и списка
                .padding(.horizontal, 10)
                .padding(.top, 12)
                BacklinksSection(document: document)
            }
            FolderTagsSection(store: appState.folderWorkspace, controller: appState.folderTags, search: appState.folderSearch)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(L10n.tr("筛选资料库文件"), text: $filterQuery)
                    .textFieldStyle(.plain).font(.callout)
                    .accessibilityLabel(L10n.tr("筛选资料库文件"))
                    .accessibilityHint(filterQuery.isEmpty ? L10n.tr("仅筛选资料库文件，不含工作文件夹") : "")
                    .focused($filterFocused)
                    .onExitCommand { filterQuery = "" }
                if !filterQuery.isEmpty {
                    Button { filterQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.tr("清除筛选"))
                        .focused($clearFocused).editorFocusRing(clearFocused, radius: 3)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)).allowsHitTesting(false))
            .editorFocusRing(filterFocused, radius: 7)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
            .stableHelp(L10n.tr("按文件名或分组筛选资料库，不搜索工作文件夹正文"))
            if !filterQuery.isEmpty {
                Text(L10n.tr("仅筛选资料库文件，不含工作文件夹"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }

            SidebarLibraryView(
                recentFiles: appState.recentFiles,
                library: windowManager.sidebarLibrary,
                folderWorkspace: appState.folderWorkspace,
                folderSearch: appState.folderSearch,
                query: filterQuery
            )
            .id(windowManager.primaryReopenGeneration)

            if let samples = windowManager.experimentSamples {
                ExperimentSampleControls(samples: samples)
            }

            SidebarOperationFeedback(state: appState.sidebarFeedback)

            Button {
                SettingsWindowController.shared.present(windowManager: windowManager)
            } label: {
                HStack(spacing: 8) {
                    Label(L10n.tr("设置"), systemImage: "gearshape")
                    Spacer()
                    if AppEnvironment.isExperiment {
                        Text(AppEnvironment.experimentIteration)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(LacEditorDesign.selectionFill, in: Capsule())
                            .accessibilityLabel(L10n.tr("界面实验 %@", String(describing: AppEnvironment.experimentIteration)))
                    }
                }
                    .font(.body)
                    .foregroundStyle(isSettingsHovering ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietActionButtonStyle())
            .focused($settingsFocused)
            .editorFocusRing(settingsFocused)
            .stableHelp(L10n.tr("打开设置"), shortcut: "⌘,")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .onHover { isSettingsHovering = $0 }
        }
        .background(SidebarMaterialBackground())
    }
}

/// Only this footer observes transient feedback. Its fixed height prevents
/// messages and expiry from moving the file list or the settings button.
private struct SidebarOperationFeedback: View {
    @ObservedObject var state: InlineFeedbackState
    @State private var hovering = false
    @FocusState private var undoFocused: Bool
    var body: some View {
        HStack(spacing: 6) {
            if let item = state.item {
                Image(systemName: item.symbol).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(item.title).lineLimit(1).stableHelp(item.title)
                    .accessibilityIdentifier("sidebar.feedback.message")
                Spacer(minLength: 0)
                if item.canUndo {
                    Button(L10n.tr("撤销")) { state.undo() }
                        .buttonStyle(.plain).foregroundStyle(LacEditorDesign.accent)
                        .padding(3).focused($undoFocused).editorFocusRing(undoFocused, radius: 3)
                        .accessibilityIdentifier("sidebar.feedback.undo")
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 18).frame(height: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0; state.setInteracting(hovering || undoFocused) }
        .onChange(of: undoFocused) { state.setInteracting(hovering || undoFocused) }
        .onChange(of: state.item) { old, item in
            // сообщение после «Отменить» с тем же заголовком не озвучиваем второй раз; новые события озвучиваем всегда
            guard let item, !(old?.canUndo == true && old?.title == item.title && !item.canUndo) else { return }
            AccessibilityNotification.Announcement(item.title).post()
        }
        .onDisappear { state.setInteracting(false) }
    }
}

private struct ExperimentSampleControls: View {
    @ObservedObject var samples: ExperimentSampleLibrary
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                windowManager.openExperimentWelcome(in: appState)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                    Text(samples.isPreparing ? L10n.tr("正在准备示例…") : L10n.tr("打开体验文档"))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 9))
                }.font(.subheadline).padding(.horizontal, 9).frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietActionButtonStyle())
            .focused($isFocused).editorFocusRing(isFocused)
            .foregroundStyle(.secondary)
            .disabled(samples.isPreparing)
            .contextMenu {
                Button(L10n.tr("补充缺失的示例文件"), systemImage: "arrow.clockwise") {
                    Task { await samples.prepare(in: windowManager.sidebarLibrary, supplement: true) }
                }
                Button(L10n.tr("在 Finder 中显示"), systemImage: "folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: samples.rootURL.path)
                }
            }
            if let error = samples.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9)
            }
        }.padding(.horizontal, 10)
    }
}

private struct BacklinksTrigger: Hashable {
    let documentID: UUID
    let isActive: Bool
}

private struct BacklinksSectionLabel: View {
    @ObservedObject var controller: MarkdownBacklinksController

    var body: some View {
        let count = controller.state == .loaded ? String(controller.matches.count) : nil
        HStack(spacing: 6) {
            Text(L10n.tr("反向链接"))
                .font(.subheadline.weight(.semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            if let count {
                Text(count).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { L10n.tr("反向链接，%@", $0) } ?? L10n.tr("反向链接"))
    }
}

/// Подписки привязаны к `@ObservedObject document`: при смене выбранного документа блок получает нового наблюдателя.
private struct BacklinksSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument

    private var isActive: Bool { appState.isBacklinksExpanded && appState.isSidebarEffectivelyVisible }

    var body: some View {
        DisclosureGroup(isExpanded: $appState.isBacklinksExpanded) {
            MarkdownBacklinksView(controller: appState.backlinks) { appState.openFolder() }
        } label: {
            BacklinksSectionLabel(controller: appState.backlinks)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .task(id: BacklinksTrigger(documentID: document.id, isActive: isActive)) {
            appState.backlinks.update(root: appState.folderWorkspace.rootURL, document: document, isActive: isActive)
        }
        // корень берётся из публикации: `@Published` сообщает до записи свойства
        .onReceive(appState.folderWorkspace.$rootURL.removeDuplicates()) { root in
            appState.backlinks.update(root: root, document: document, isActive: isActive)
        }
        .onReceive(document.$url.removeDuplicates().dropFirst()) { _ in
            appState.backlinks.update(root: appState.folderWorkspace.rootURL, document: document, isActive: isActive)
        }
        .onReceive(document.$isDirty.removeDuplicates().dropFirst().filter { !$0 }) { _ in appState.backlinks.refreshSoon() }
        .onDisappear { appState.backlinks.close() }
    }
}
