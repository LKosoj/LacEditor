import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var recentFiles: RecentFilesStore
    @ObservedObject var library: SidebarLibraryStore
    var query = ""
    @State private var hoveredSection: SidebarLibrarySection?
    @FocusState private var focusedHeader: String?
    @StateObject private var dragState = SidebarDragState()

    private var filter: SidebarLibraryFilter { SidebarLibraryFilter(query: query) }
    private var favorites: [URL] { filter.files(library.favoriteURLs) }
    private var groups: [SidebarFileGroup] { filter.groups(library.groups) }
    private var recent: [URL] { filter.files(recentFiles.urls) }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 16) {
            if filter.isActive, favorites.isEmpty, groups.isEmpty, recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有匹配的文件").font(.system(size: 13, weight: .medium))
                    Text("试试文件名、扩展名或分组名称。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 8).padding(.vertical, 12)
            } else {
            sidebarSection(
                title: "收藏夹",
                section: .favorites,
                count: favorites.count
            ) {
                if favorites.isEmpty {
                    Text(filter.isActive ? "没有匹配的收藏" : "可从文件右键菜单添加收藏")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                } else {
                    fileList(urls: favorites, location: .favorites)
                }
            }

            sidebarSection(
                title: "分组",
                section: .groups,
                count: groups.count
            ) {
                if groups.isEmpty {
                    if filter.isActive {
                        Text("没有匹配的分组").font(.system(size: 11)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 32)
                    } else {
                    Button("新建分组") {
                        windowManager.requestCreateSidebarGroup()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30)
                    .frame(height: 26)
                    }
                } else {
                    ForEach(groups) { group in
                        SidebarGroupView(group: group, library: library, isFiltering: filter.isActive)
                    }
                    Color.clear.frame(height: 20).contentShape(Rectangle())
                        .sidebarDropArea(.groupsEnd, height: 20, library: library, enabled: !filter.isActive)
                }
            }

            sidebarSection(
                title: "最近文件",
                section: .recent,
                count: recent.count
            ) {
                if recent.isEmpty {
                    VStack(spacing: 7) {
                        Text(filter.isActive ? "没有匹配的最近文件" : "暂无最近文件")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        if !filter.isActive { Button("打开文件…") {
                            appState.openFiles()
                        }
                        .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    fileList(urls: recent, location: .recent)
                }
            }
            }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(NativeScrollViewConfigurator(indicatorOpacity: 0.6))
            .background(SidebarDragScrollAttachment(state: dragState))
        }
        .scrollIndicators(.automatic)
        .scrollContentBackground(.hidden)
        .environmentObject(dragState)
        .onDisappear { dragState.finish() }
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(
        title: String,
        section: SidebarLibrarySection,
        count: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = filter.isActive || library.isExpanded(section)
        let isHovering = hoveredSection == section || focusedHeader?.hasPrefix(title) == true
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    library.setExpanded(!isExpanded, for: section)
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.5)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(reduceMotion ? nil : LacEditorDesign.sidebarDisclosureAnimation, value: isExpanded)
                            .opacity(isHovering ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovering)
                            .frame(width: 9)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.section.\(section.rawValue)")
                .disabled(filter.isActive)
                .focused($focusedHeader, equals: title)
                .editorFocusRing(focusedHeader == title)
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
                if section == .groups {
                    Button {
                        windowManager.requestCreateSidebarGroup()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedHeader, equals: title + ".add")
                    .editorFocusRing(focusedHeader == title + ".add", radius: 4)
                    .opacity(isHovering ? 1 : 0)
                    .stableHelp("新建分组")
                    .accessibilityLabel("新建分组")
                }
                if section == .recent, !recentFiles.urls.isEmpty, isExpanded {
                    Button {
                        windowManager.requestClearRecentFiles()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedHeader, equals: title + ".clear")
                    .editorFocusRing(focusedHeader == title + ".clear", radius: 4)
                    .opacity(isHovering ? 1 : 0)
                    .stableHelp("清除最近文件")
                    .accessibilityLabel("清除最近文件")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .onHover { hoveredSection = $0 ? section : nil }
            .sidebarDropArea(section == .favorites ? .favoritesHeader : .unavailable,
                             height: 28, library: library, enabled: !filter.isActive)

            SidebarDisclosure(isExpanded: isExpanded) {
                content()
            }
        }
    }

    @ViewBuilder
    private func fileList(
        urls: [URL],
        location: SidebarFileLocation
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(urls, id: \.path) { url in
                SidebarFileRow(url: url, location: location)
                    .onDrag {
                        SidebarDragPayload.file(url, location: location).itemProvider()
                    }
                    .sidebarDropArea(.file(url, location), height: 46, library: library, enabled: !filter.isActive)
            }

            Color.clear.frame(height: 20).contentShape(Rectangle())
                .sidebarDropArea(.filesEnd(location), height: 20, library: library, enabled: !filter.isActive)
        }
    }
}

private struct SidebarGroupView: View {
    @EnvironmentObject private var windowManager: WindowManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: SidebarFileGroup
    @ObservedObject var library: SidebarLibraryStore
    var isFiltering = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    private var isExpanded: Bool { isFiltering || group.isExpanded }

    var body: some View {
        VStack(spacing: 2) {
            Button {
                library.setExpanded(!isExpanded, for: group.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                    Text(group.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : LacEditorDesign.sidebarDisclosureAnimation, value: isExpanded)
                        .opacity(isHovering || isFocused ? 1 : 0)
                        .frame(width: 9)
                    Spacer()
                    if !group.paths.isEmpty {
                        Text("\(group.paths.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 32)
                .contentShape(Rectangle())
                .background(
                    isHovering ? LacEditorDesign.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
            }
            .buttonStyle(SoftRowButtonStyle())
            .accessibilityIdentifier("sidebar.group.\(group.id.uuidString)")
            .disabled(isFiltering)
            .focused($isFocused)
            .editorFocusRing(isFocused)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .onHover { isHovering = $0 }
            .onDrag { SidebarDragPayload.group(group.id).itemProvider() }
            .sidebarDropArea(.group(group.id), height: 32, library: library, enabled: !isFiltering)
            .contextMenu {
                Button {
                    windowManager.requestRenameSidebarGroup(group)
                } label: {
                    Label("重命名分组…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    windowManager.requestDeleteSidebarGroup(group)
                } label: {
                    Label("删除分组", systemImage: "trash")
                }
            }

            SidebarDisclosure(isExpanded: isExpanded) {
                VStack(spacing: 2) {
                    ForEach(group.urls, id: \.path) { url in
                        SidebarFileRow(url: url, location: .group(group.id))
                            .padding(.leading, 15)
                            .onDrag {
                                SidebarDragPayload.file(
                                    url,
                                    location: .group(group.id)
                                ).itemProvider()
                            }
                            .sidebarDropArea(.file(url, .group(group.id)), height: 46,
                                             library: library, enabled: !isFiltering)
                    }

                    Color.clear.frame(height: 20).contentShape(Rectangle())
                        .sidebarDropArea(.filesEnd(.group(group.id)), height: 20,
                                         library: library, enabled: !isFiltering)
                }
            }
        }
    }
}
enum SidebarFileLocation: Equatable {
    case favorites
    case group(UUID)
    case recent

    var accessibilityID: String {
        switch self {
        case .favorites: "favorites"
        case .recent: "recent"
        case let .group(id): "group.\(id.uuidString)"
        }
    }
}

private struct SidebarFileRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    let url: URL
    let location: SidebarFileLocation
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @State private var fileExists = true
    @State private var fileIdentity: DocumentFileIdentity?
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var exists: Bool { fileExists }

    private var isOpen: Bool {
        guard let fileIdentity else { return false }
        return appState.selectedDocument?.fileIdentity?.matches(fileIdentity) == true
    }

    var body: some View {
        Button {
            if FileManager.default.fileExists(atPath: url.path) {
                appState.openFile(url)
            } else {
                windowManager.requestRelocateSidebarFile(url)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: exists
                      ? EditorLanguage.infer(from: url).icon
                      : "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        exists
                            ? (activeState == .inactive ? Color.secondary : LacEditorDesign.fileTint(for: EditorLanguage.infer(from: url)))
                            : Color.orange
                    )
                    .frame(width: 28, height: 28)
                    .background(LacEditorDesign.fileTint(for: EditorLanguage.infer(from: url)).opacity(activeState == .inactive ? 0.035 : 0.08),
                                in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: isOpen ? .semibold : .regular))
                        .lineLimit(1)
                    Text(exists ? url.deletingLastPathComponent().lastPathComponent : "文件已移动或删除")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isOpen {
                    Circle().fill(activeState == .inactive ? Color.secondary : LacEditorDesign.accent)
                        .frame(width: 4, height: 4).accessibilityHidden(true)
                }
            }
            .opacity(exists ? 1 : 0.65)
            .padding(.horizontal, 8)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(
                isOpen ? (activeState == .inactive ? Color.primary.opacity(0.07) : LacEditorDesign.selectionFill)
                    : (isHovering ? LacEditorDesign.hoverFill : .clear),
                in: RoundedRectangle(
                    cornerRadius: LacEditorDesign.compactCornerRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .leading) {
                if isOpen {
                    Capsule().fill(activeState == .inactive ? Color.secondary.opacity(0.4) : LacEditorDesign.accent)
                        .frame(width: 2, height: 18).padding(.leading, 1)
                }
            }
        }
        .buttonStyle(SoftRowButtonStyle())
        .focused($isFocused)
        .editorFocusRing(isFocused)
        .accessibilityIdentifier("sidebar.file.\(location.accessibilityID).\(url.path)")
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : LacEditorDesign.hoverAnimation, value: isHovering)
        .stableHelp(url.path)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .task(id: url) {
            let url = url
            let metadata = await Task.detached(priority: .utility) {
                (FileManager.default.fileExists(atPath: url.path), DocumentFileIdentity.resolve(url))
            }.value
            guard !Task.isCancelled else { return }
            fileExists = metadata.0
            fileIdentity = metadata.1
        }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if exists {
            Button {
                appState.openFile(url)
            } label: {
                Label("打开", systemImage: "doc.text")
            }
            Button {
                windowManager.openFileInNewWindow(url)
            } label: {
                Label("用新窗口打开", systemImage: "macwindow.badge.plus")
            }

            Divider()

            Button {
                appState.toggleSidebarFavorite(url)
            } label: {
                Label(
                    windowManager.sidebarLibrary.isFavorite(url)
                        ? "取消收藏"
                        : "添加到收藏夹",
                    systemImage: windowManager.sidebarLibrary.isFavorite(url)
                        ? "star.slash"
                        : "star"
                )
            }

            Menu {
                ForEach(windowManager.sidebarLibrary.groups) { group in
                    Button {
                        appState.addSidebarFile(url, toGroup: group.id)
                    } label: {
                        Label(
                            group.name,
                            systemImage: windowManager.sidebarLibrary
                                .groupsContaining(url).contains(group.id)
                                ? "checkmark"
                                : "folder"
                        )
                    }
                }
                if !windowManager.sidebarLibrary.groups.isEmpty {
                    Divider()
                }
                Button {
                    windowManager.requestCreateSidebarGroup(adding: url)
                } label: {
                    Label("新建分组…", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("添加到分组", systemImage: "folder")
            }

            Divider()

            Button {
                windowManager.requestRenameFile(url)
            } label: {
                Label("重命名…", systemImage: "pencil")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
        } else {
            Button {
                windowManager.requestRelocateSidebarFile(url)
            } label: {
                Label("重新定位…", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        switch location {
        case .favorites:
            Button(role: .destructive) {
                appState.toggleSidebarFavorite(url)
            } label: {
                Label("从收藏夹移除", systemImage: "star.slash")
            }
        case let .group(id):
            Button(role: .destructive) {
                appState.removeSidebarFile(url, fromGroup: id)
            } label: {
                Label("从分组中移除", systemImage: "minus.circle")
            }
        case .recent:
            Button(role: .destructive) {
                appState.removeRecentSidebarFile(url)
            } label: {
                Label("从最近文件中删除", systemImage: "trash")
            }
        }
    }
}
