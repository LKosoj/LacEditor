import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var recentFiles: RecentFilesStore
    @ObservedObject var library: SidebarLibraryStore
    @ObservedObject var folderWorkspace: FolderWorkspaceStore
    @ObservedObject var folderSearch: FolderSearchController
    var query = ""
    @State private var hoveredSection: SidebarLibrarySection?
    @State private var folderSearchExpanded = false
    @FocusState private var focusedHeader: String?
    @StateObject private var dragState = SidebarDragState()
    @StateObject private var selection = SidebarSelection()
    @StateObject private var treeNavigation = FolderListNavigation()
    @StateObject private var searchNavigation = FolderListNavigation()

    private var filter: SidebarLibraryFilter { SidebarLibraryFilter(query: query) }
    private var favorites: [URL] { filter.files(library.favoriteURLs) }
    private var groups: [SidebarFileGroup] { filter.groups(library.groups) }
    private var recent: [URL] { filter.files(recentFiles.urls) }
    private var pinnedFolders: [URL] { filter.files(library.pinnedFolderURLs) }
    private var recentFolders: [URL] { filter.files(recentFiles.folderURLs.filter { !library.isPinnedFolder($0) }) }
    private var visibleSelectionURLs: [URL] {
        switch selection.location {
        case .favorites: return library.favoriteSectionExpanded || filter.isActive ? favorites : []
        case .recent: return library.recentSectionExpanded || filter.isActive ? recent : []
        case let .group(id):
            guard library.groupsSectionExpanded || filter.isActive,
                  let group = groups.first(where: { $0.id == id }),
                  group.isExpanded || filter.isActive else { return [] }
            return group.urls
        case nil: return []
        }
    }

    /// Порядок совпадает с порядком секций в `body`: избранное, группы, недавние.
    private var navigationOrder: [SidebarSelection.Focus] {
        var result: [SidebarSelection.Focus] = []
        let all = filter.isActive
        if all || library.favoriteSectionExpanded {
            result += favorites.map { .init(location: .favorites, path: $0.path) }
        }
        if all || library.groupsSectionExpanded {
            for group in groups where all || group.isExpanded {
                result += group.urls.map { .init(location: .group(group.id), path: $0.path) }
            }
        }
        if all || library.recentSectionExpanded {
            result += recent.map { .init(location: .recent, path: $0.path) }
        }
        return result
    }

    var body: some View {
        let treeRows = FolderWorkspaceVisibleRow.rows(in: folderWorkspace)
        let searchRows = FolderSearchRow.rows(folderSearch)
        return ScrollViewReader { proxy in
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
            FolderWorkspaceView(store: folderWorkspace)
            if !pinnedFolders.isEmpty {
                Text(L10n.tr("固定文件夹")).sidebarHeadingStyle().padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)
                ForEach(pinnedFolders, id: \.self) { folderRow($0) }
            }
            if !recentFolders.isEmpty {
                Text(L10n.tr("最近使用的文件夹")).sidebarHeadingStyle().padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)
                ForEach(recentFolders, id: \.self) { folderRow($0) }
            }
            ForEach(treeRows) { row in
                FolderWorkspaceRowView(store: folderWorkspace, row: row, rows: treeRows, navigation: treeNavigation)
                    .padding(.top, 2)
            }
            if folderWorkspace.rootURL != nil || (folderSearch.isWorking && folderSearch.quickOpenRequest == nil) {
                Button {
                    folderSearchExpanded.toggle()
                } label: {
                    Label(L10n.tr("文件夹搜索"), systemImage: folderSearchExpanded ? "chevron.down" : "chevron.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .accessibilityValue(L10n.tr(folderSearchExpanded ? "已展开" : "已收起"))
                if folderSearchExpanded {
                    FolderSearchView(controller: folderSearch).padding(.top, 6)
                    ForEach(searchRows) { row in
                        FolderSearchRowView(controller: folderSearch, row: row, navigation: searchNavigation).padding(.top, 4)
                    }
                }
            }
            if filter.isActive, favorites.isEmpty, groups.isEmpty, recent.isEmpty, pinnedFolders.isEmpty, recentFolders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("没有匹配的文件")).font(.body.weight(.medium))
                    Text(L10n.tr("试试文件名、扩展名或分组名称。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.horizontal, 8).padding(.vertical, 12).padding(.top, 16)
            } else {
            sidebarSection(
                title: L10n.tr("收藏夹"),
                section: .favorites,
                count: favorites.count
            ) {
                if favorites.isEmpty {
                    Text(filter.isActive ? L10n.tr("没有匹配的收藏") : L10n.tr("可从文件右键菜单添加收藏"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                } else {
                    fileList(urls: favorites, location: .favorites)
                }
            }.padding(.top, 16)

            sidebarSection(
                title: L10n.tr("分组"),
                section: .groups,
                count: groups.count
            ) {
                if groups.isEmpty {
                    if filter.isActive {
                        Text(L10n.tr("没有匹配的分组")).font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 32)
                    } else {
                    Button(L10n.tr("新建分组")) {
                        windowManager.requestCreateSidebarGroup()
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
            }.padding(.top, 16)

            sidebarSection(
                title: L10n.tr("最近文件"),
                section: .recent,
                count: recent.count
            ) {
                if recent.isEmpty {
                    VStack(spacing: 7) {
                        Text(filter.isActive ? L10n.tr("没有匹配的最近文件") : L10n.tr("暂无最近文件"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !filter.isActive { Button(L10n.tr("打开文件…")) {
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
            }.padding(.top, 16)
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
        .environmentObject(selection)
        .onChange(of: treeRows.map(\.id), initial: true) { _, _ in
            treeNavigation.setOrder(treeRows.compactMap { row -> AnyHashable? in
                guard case .entry = row.content else { return nil }
                return AnyHashable(row.id)
            })
        }
        .onChange(of: searchRows.map(\.id), initial: true) { _, _ in
            searchNavigation.setOrder(FolderSearchRowView.selectableIDs(searchRows))
        }
        .onChange(of: navigationOrder, initial: true) { _, order in selection.setNavigationOrder(order) }
        .onChange(of: selection.navigationOrder) { _, order in
            // фокус не должен оставаться на строке свёрнутой секции
            if let focused = selection.focused, !order.contains(focused) { selection.focused = nil }
        }
        .onChange(of: visibleSelectionURLs) { _, urls in
            if let location = selection.location { selection.reconcile(in: location, urls: urls) }
        }
        .onDisappear { dragState.finish() }
        .onAppear {
            if windowManager.activeState === appState { appState.folderWorkspace.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            DispatchQueue.main.async {
                guard windowManager.activeState === appState else { return }
                appState.folderWorkspace.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === appState.hostWindow else { return }
            DispatchQueue.main.async {
                guard windowManager.activeState === appState, appState.hostWindow === window else { return }
                appState.folderWorkspace.refresh()
            }
        }
        .onChange(of: selection.focused) { _, focused in
            if let focused {
                proxy.scrollTo(focused.location.accessibilityID + focused.path)
            }
        }
        }
    }

    @ViewBuilder
    private func folderRow(_ url: URL) -> some View {
        Button { appState.openFolder(url) } label: {
            Label(url.lastPathComponent, systemImage: library.isPinnedFolder(url) ? "pin" : "folder")
                .font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).padding(.vertical, 4).stableHelp(url.path)
        .accessibilityHint(L10n.tr("打开此文件夹"))
        .contextMenu {
            Button(L10n.tr(library.isPinnedFolder(url) ? "取消固定文件夹" : "固定此文件夹")) {
                let previous = library.pinnedFolderPaths
                library.togglePinnedFolder(url)
                let expected = library.pinnedFolderPaths
                appState.sidebarFeedback.show(L10n.tr("文件夹列表已更新")) { [weak library = library] in
                    library?.restorePinnedFolders(previous, ifUnchanged: expected) ?? false
                }
            }
            if recentFiles.folderURLs.contains(url) {
                Button(L10n.tr("从最近文件夹移除")) {
                    let previous = recentFiles.folderURLs
                    recentFiles.removeFolder(url)
                    let expected = recentFiles.folderURLs
                    appState.sidebarFeedback.show(L10n.tr("文件夹列表已更新")) { [weak recentFiles = recentFiles] in
                        recentFiles?.restoreFolders(previous, ifUnchanged: expected) ?? false
                    }
                }
            }
            Button(L10n.tr("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func sidebarSection<Content: View>(
        title: String,
        section: SidebarLibrarySection,
        count: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = filter.isActive || library.isExpanded(section)
        let isHovering = hoveredSection == section || focusedHeader?.hasPrefix(section.rawValue) == true
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    library.setExpanded(!isExpanded, for: section)
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .tracking(0.5)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(reduceMotion ? nil : LacEditorDesign.sidebarDisclosureAnimation, value: isExpanded)
                            .accessibilityHidden(true)
                            .frame(width: 9)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.section.\(section.rawValue)")
                .accessibilityAddTraits(.isHeader)
                .disabled(filter.isActive)
                .focused($focusedHeader, equals: section.rawValue)
                .editorFocusRing(focusedHeader == section.rawValue)
                .accessibilityValue(isExpanded ? L10n.tr("已展开") : L10n.tr("已收起"))
                if section == .groups {
                    Button {
                        windowManager.requestCreateSidebarGroup()
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedHeader, equals: section.rawValue + ".add")
                    .editorFocusRing(focusedHeader == section.rawValue + ".add", radius: 4)
                    .opacity(isHovering ? 1 : 0.85)
                    .stableHelp(L10n.tr("新建分组"))
                    .accessibilityLabel(L10n.tr("新建分组"))
                }
                if section == .recent, !recentFiles.urls.isEmpty, isExpanded {
                    Button {
                        windowManager.requestClearRecentFiles()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 10))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedHeader, equals: section.rawValue + ".clear")
                    .editorFocusRing(focusedHeader == section.rawValue + ".clear", radius: 4)
                    .opacity(isHovering ? 1 : 0.85)
                    .stableHelp(L10n.tr("清除最近文件"))
                    .accessibilityLabel(L10n.tr("清除最近文件"))
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(count > 0 ? L10n.tr("%@，%lld 项", title, count) : title)
    }

    @ViewBuilder
    private func fileList(
        urls: [URL],
        location: SidebarFileLocation
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(urls, id: \.path) { url in
                SidebarFileRow(url: url, location: location, urls: urls)
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

/// Сдвиг элемента списка избранного/группы на одну позицию (контекстное меню вместо перетаскивания).
enum SidebarReorder {
    static func canMove(at index: Int, offset: Int, count: Int) -> Bool {
        index >= 0 && index < count && index + offset >= 0 && index + offset < count
    }

    /// Элемент, перед которым встаёт перемещаемый; nil — в конец списка.
    static func insertionTarget<T>(at index: Int, offset: Int, in items: [T]) -> T? {
        let target = offset < 0 ? index - 1 : index + 2
        return items.indices.contains(target) ? items[target] : nil
    }
}

private struct SidebarGroupView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: SidebarFileGroup
    @ObservedObject var library: SidebarLibraryStore
    var isFiltering = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    private var isExpanded: Bool { isFiltering || group.isExpanded }

    private func canMoveGroup(_ offset: Int) -> Bool {
        guard let index = library.groups.firstIndex(where: { $0.id == group.id }) else { return false }
        return SidebarReorder.canMove(at: index, offset: offset, count: library.groups.count)
    }

    /// Сдвиг группы на одну позицию; вниз — после нижнего соседа, как при перетаскивании.
    private func moveGroup(_ offset: Int) {
        let groups = library.groups
        guard let index = groups.firstIndex(where: { $0.id == group.id }),
              SidebarReorder.canMove(at: index, offset: offset, count: groups.count) else { return }
        let previousOrder = groups.map(\.id)
        let nextAfter = index + 1 < groups.count ? groups[index + 1].id : nil
        if offset < 0 {
            library.moveGroup(group.id, before: groups[index - 1].id)
        } else {
            library.moveGroup(group.id, before: groups[index + 1].id, after: true)
        }
        let expectedOrder = library.groups.map(\.id)
        guard previousOrder != expectedOrder else { return }
        appState.sidebarFeedback.show(L10n.tr("已调整顺序")) { [weak library = library, id = group.id] in
            guard let library, library.groups.map(\.id) == expectedOrder else { return false }
            library.moveGroup(id, before: nextAfter)
            return true
        }
    }

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
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : LacEditorDesign.sidebarDisclosureAnimation, value: isExpanded)
                        .accessibilityHidden(true)
                        .frame(width: 9)
                    Spacer()
                    if !group.paths.isEmpty {
                        Text("\(group.paths.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            .accessibilityValue(isExpanded ? L10n.tr("已展开") : L10n.tr("已收起"))
            .onHover { isHovering = $0 }
            .onDrag { SidebarDragPayload.group(group.id).itemProvider() }
            .sidebarDropArea(.group(group.id), height: 32, library: library, enabled: !isFiltering)
            .contextMenu {
                Button {
                    windowManager.requestRenameSidebarGroup(group)
                } label: {
                    Label(L10n.tr("重命名分组…"), systemImage: "pencil")
                }
                Button(L10n.tr("上移")) { moveGroup(-1) }.disabled(isFiltering || !canMoveGroup(-1))
                Button(L10n.tr("下移")) { moveGroup(1) }.disabled(isFiltering || !canMoveGroup(1))
                Divider()
                Button(role: .destructive) {
                    windowManager.requestDeleteSidebarGroup(group)
                } label: {
                    Label(L10n.tr("删除分组"), systemImage: "trash")
                }
            }

            SidebarDisclosure(isExpanded: isExpanded) {
                VStack(spacing: 2) {
                    ForEach(group.urls, id: \.path) { url in
                        SidebarFileRow(url: url, location: .group(group.id), urls: group.urls)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.name)
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

@MainActor
final class SidebarSelection: ObservableObject {
    @Published var location: SidebarFileLocation?
    @Published var paths: Set<String> = []
    struct Focus: Equatable {
        let location: SidebarFileLocation
        let path: String
    }

    @Published var focused: Focus?
    /// Видимые файловые строки в порядке показа (избранное -> группы -> недавние), без свёрнутых секций.
    @Published private(set) var navigationOrder: [Focus] = []
    private var anchor: String?
    private var typeSelectState = SidebarTypeSelect()
    /// Строка, куда фокус перенесён клавиатурой, но ещё не создана ленивым списком.
    /// Только она получает фокус при появлении: обычная прокрутка не забирает фокус у редактора.
    var focusRequest: Focus?

    func setNavigationOrder(_ order: [Focus]) {
        if order != navigationOrder { navigationOrder = order }
    }

    /// Стрелка Вверх/Вниз через границы секций. Shift расширяет диапазон только внутри секции:
    /// на другой секции `select` сбрасывает выделение, так что это обычное перемещение.
    @discardableResult
    func moveFocus(from current: Focus, offset: Int, extend: Bool) -> Bool {
        guard let target = SidebarKeyboardNavigation.moved(from: current, offset: offset, in: navigationOrder) else { return false }
        selectNavigationTarget(target, shift: extend && target.location == current.location)
        return true
    }

    func canTypeSelect(_ characters: String, hasModifiers: Bool) -> Bool {
        typeSelectState.accepts(characters, hasModifiers: hasModifiers)
    }

    /// Type-select: переходит к следующей строке, имя которой начинается с набранного.
    func typeSelect(_ characters: String, from current: Focus, now: Date = Date()) -> Bool {
        typeSelectState.append(characters, now: now)
        let names = navigationOrder.map { ($0.path as NSString).lastPathComponent }
        guard let hit = SidebarTypeSelect.match(prefix: typeSelectState.buffer, names: names,
                                                current: navigationOrder.firstIndex(of: current)) else { return false }
        // Переход в другую секцию не должен сбрасывать набираемый префикс.
        let state = typeSelectState
        selectNavigationTarget(navigationOrder[hit], shift: false)
        typeSelectState = state
        return true
    }

    private func selectNavigationTarget(_ target: Focus, shift: Bool) {
        // Строка, уже стоящая в фокусе, его не теряет: запрос для неё повис бы до следующего появления.
        let request = target == focused ? nil : target
        let urls = navigationOrder.filter { $0.location == target.location }.map { URL(fileURLWithPath: $0.path) }
        select(URL(fileURLWithPath: target.path), in: target.location, urls: urls, command: false, shift: shift)
        focusRequest = request
    }

    func select(_ url: URL, in location: SidebarFileLocation, urls: [URL], command: Bool, shift: Bool) {
        let path = url.path
        if self.location != location { paths = []; anchor = nil; typeSelectState.reset() }
        self.location = location
        if shift, let anchor, let start = urls.firstIndex(where: { $0.path == anchor }),
           let end = urls.firstIndex(where: { $0.path == path }) {
            paths = Set(urls[min(start, end)...max(start, end)].map(\.path))
        } else if command {
            if paths.contains(path) { paths.remove(path) } else { paths.insert(path) }
            anchor = path
        } else {
            paths = [path]
            anchor = path
        }
        focused = Focus(location: location, path: path)
    }

    func selectAll(in location: SidebarFileLocation, urls: [URL], focused: URL) {
        self.location = location
        paths = Set(urls.map(\.path))
        anchor = focused.path
        self.focused = Focus(location: location, path: focused.path)
    }

    func selected(_ url: URL, in location: SidebarFileLocation) -> Bool {
        self.location == location && paths.contains(url.path)
    }

    func reconcile(in location: SidebarFileLocation, urls: [URL]) {
        if self.location == location {
            paths.formIntersection(Set(urls.map(\.path)))
            if let anchor, !urls.contains(where: { $0.path == anchor }) { self.anchor = nil }
        }
        if let focused, focused.location == location, !urls.contains(where: { $0.path == focused.path }) {
            self.focused = nil
        }
    }
}

private struct SidebarFileRow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    let url: URL
    let location: SidebarFileLocation
    let urls: [URL]
    @EnvironmentObject private var selection: SidebarSelection
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
        let rowFocus = SidebarSelection.Focus(location: location, path: url.path)
        let selected = selection.selected(url, in: location)
        let button = Button {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            let modified = modifiers.contains(.command) || modifiers.contains(.shift)
            selection.select(url, in: location, urls: urls, command: modifiers.contains(.command),
                             shift: modifiers.contains(.shift))
            if modified { return }
            openFile()
        } label: {
            SidebarFileRowLabel(url: url, exists: exists, isOpen: isOpen,
                                isSelected: selected,
                                isHovering: isHovering, activeState: activeState)
        }
        .buttonStyle(SoftRowButtonStyle())
        .focused($isFocused)
        .editorFocusRing(isFocused)
        let decorated = button
        .id(location.accessibilityID + url.path)
        .accessibilityIdentifier("sidebar.file.\(location.accessibilityID).\(url.path)")
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : LacEditorDesign.hoverAnimation, value: isHovering)
        .stableHelp(url.path)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(!exists ? L10n.tr("文件已移动或删除") : (isOpen ? L10n.tr("已打开") : ""))
        return decorated
        .onChange(of: selection.focused) { _, focused in
            if focused == rowFocus { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { selection.focused = rowFocus; selection.focusRequest = nil }
        }
        .onChange(of: urls) { _, newURLs in selection.reconcile(in: location, urls: newURLs) }
        .onAppear { if selection.focusRequest == rowFocus { isFocused = true } }
        .onKeyPress(.upArrow) { moveFocus(-1) }
        .onKeyPress(.downArrow) { moveFocus(1) }
        .onKeyPress(.return) { openSelectedFile() }
        .onKeyPress("a") { selectAllFiles() }
        .onKeyPress(phases: .down) { press in typeSelect(press) }
        .modifier(SidebarFileMetadataModifier(url: url, windowIsActive: activeState != .inactive,
                                              fileExists: $fileExists, fileIdentity: $fileIdentity))
        .modifier(SidebarFileContextMenuModifier(isSelected: selected, menu: contextMenu) {
            selection.select(url, in: location, urls: urls, command: false, shift: false)
        })
    }

    private func openFile() {
        if FileManager.default.fileExists(atPath: url.path) {
            appState.openFile(url)
        } else {
            windowManager.requestRelocateSidebarFile(url)
        }
    }

    private func openSelectedFile() -> KeyPress.Result {
        selection.select(url, in: location, urls: urls, command: false, shift: false)
        openFile()
        return .handled
    }

    private func selectAllFiles() -> KeyPress.Result {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return .ignored }
        selection.selectAll(in: location, urls: urls, focused: url)
        return .handled
    }

    private func moveFocus(_ offset: Int) -> KeyPress.Result {
        let current = SidebarSelection.Focus(location: location, path: url.path)
        return selection.moveFocus(from: current, offset: offset,
                                   extend: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) ? .handled : .ignored
    }

    /// Только печатные символы без Cmd/Ctrl/Opt; `.handled` лишь при найденном совпадении.
    private func typeSelect(_ press: KeyPress) -> KeyPress.Result {
        let blocked: EventModifiers = [.command, .control, .option]
        guard selection.canTypeSelect(press.characters, hasModifiers: !press.modifiers.isDisjoint(with: blocked)) else { return .ignored }
        let current = SidebarSelection.Focus(location: location, path: url.path)
        return selection.typeSelect(press.characters, from: current) ? .handled : .ignored
    }

    private var selectedURLs: [URL] {
        selection.selected(url, in: location) ? urls.filter { selection.paths.contains($0.path) } : [url]
    }

    /// Полный список из хранилища; nil, если показан отфильтрованный или недавний список.
    private var reorderableURLs: [URL]? {
        let full: [URL]
        switch location {
        case .favorites: full = windowManager.sidebarLibrary.favoriteURLs
        case let .group(id): full = windowManager.sidebarLibrary.groups.first { $0.id == id }?.urls ?? []
        case .recent: return nil
        }
        return full == urls ? full : nil
    }

    private func canMove(_ offset: Int) -> Bool {
        guard let list = reorderableURLs, let index = list.firstIndex(of: url) else { return false }
        return SidebarReorder.canMove(at: index, offset: offset, count: list.count)
    }

    /// Сдвиг на одну позицию из контекстного меню; отмена через обратную связь боковой панели.
    private func move(_ offset: Int) {
        guard let list = reorderableURLs, let index = list.firstIndex(of: url),
              SidebarReorder.canMove(at: index, offset: offset, count: list.count) else { return }
        let library = windowManager.sidebarLibrary
        let before = SidebarReorder.insertionTarget(at: index, offset: offset, in: list)
        switch location {
        case .favorites:
            let previous = library.favoritePaths
            library.moveFavorite(url, before: before)
            let expected = library.favoritePaths
            guard previous != expected else { return }
            appState.sidebarFeedback.show(L10n.tr("已调整顺序")) { [weak library = library] in
                library?.restoreFavorites(previous, ifUnchanged: expected) ?? false
            }
        case let .group(id):
            let previous = library.groups.first { $0.id == id }?.paths ?? []
            library.moveFile(url, inGroup: id, before: before)
            let expected = library.groups.first { $0.id == id }?.paths ?? []
            guard previous != expected else { return }
            appState.sidebarFeedback.show(L10n.tr("已调整顺序")) { [weak library = library] in
                library?.restoreGroupFiles(previous, in: id, ifUnchanged: expected) ?? false
            }
        case .recent:
            break
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if selectedURLs.count > 1 {
            let existing = selectedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                Button(L10n.tr("将所选文件添加到收藏夹")) { appState.addSidebarFavorites(existing) }
                Menu(L10n.tr("将所选文件添加到分组")) {
                    ForEach(windowManager.sidebarLibrary.groups) { group in
                        Button(group.name) { appState.addSidebarFiles(existing, toGroup: group.id) }
                    }
                }
                Button(L10n.tr("在 Finder 中显示所选文件")) {
                    NSWorkspace.shared.activateFileViewerSelecting(existing)
                }
            }
            Button(L10n.tr("从列表中移除所选文件"), role: .destructive) {
                appState.removeSidebarFiles(selectedURLs, location: location)
            }
        } else if exists {
            Button {
                appState.openFile(url)
            } label: {
                Label(L10n.tr("打开"), systemImage: "doc.text")
            }
            Button {
                windowManager.openFileInNewWindow(url)
            } label: {
                Label(L10n.tr("用新窗口打开"), systemImage: "macwindow.badge.plus")
            }

            Divider()

            Button {
                appState.toggleSidebarFavorite(url)
            } label: {
                Label(
                    windowManager.sidebarLibrary.isFavorite(url)
                        ? L10n.tr("取消收藏")
                        : L10n.tr("添加到收藏夹"),
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
                    Label(L10n.tr("新建分组…"), systemImage: "folder.badge.plus")
                }
            } label: {
                Label(L10n.tr("添加到分组"), systemImage: "folder")
            }

            Divider()

            Button {
                windowManager.requestRenameFile(url)
            } label: {
                Label(L10n.tr("重命名…"), systemImage: "pencil")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label(L10n.tr("在 Finder 中显示"), systemImage: "folder")
            }
        } else {
            Button {
                windowManager.requestRelocateSidebarFile(url)
            } label: {
                Label(L10n.tr("重新定位…"), systemImage: "arrow.triangle.2.circlepath")
            }
        }

        if selectedURLs.count <= 1 {
        Divider()

        switch location {
        case .favorites:
            Button(L10n.tr("上移")) { move(-1) }.disabled(!canMove(-1))
            Button(L10n.tr("下移")) { move(1) }.disabled(!canMove(1))
            Divider()
            Button(role: .destructive) {
                appState.toggleSidebarFavorite(url)
            } label: {
                Label(L10n.tr("从收藏夹移除"), systemImage: "star.slash")
            }
        case let .group(id):
            Button(L10n.tr("上移")) { move(-1) }.disabled(!canMove(-1))
            Button(L10n.tr("下移")) { move(1) }.disabled(!canMove(1))
            Divider()
            Button(role: .destructive) {
                appState.removeSidebarFile(url, fromGroup: id)
            } label: {
                Label(L10n.tr("从分组中移除"), systemImage: "minus.circle")
            }
        case .recent:
            Button(role: .destructive) {
                appState.removeRecentSidebarFile(url)
            } label: {
                Label(L10n.tr("从最近文件中删除"), systemImage: "minus.circle")
            }
        }
        }
    }
}

private struct SidebarFileRowLabel: View {
    let url: URL
    let exists: Bool
    let isOpen: Bool
    let isSelected: Bool
    let isHovering: Bool
    let activeState: ControlActiveState

    var body: some View {
        let language = EditorLanguage.infer(from: url)
        let tint = LacEditorDesign.fileTint(for: language)
        let foreground = exists ? (activeState == .inactive ? Color.secondary : tint) : Color(nsColor: .systemOrange)
        let rowBackground = isSelected
            ? (activeState == .inactive ? Color.primary.opacity(0.07) : LacEditorDesign.selectionFill)
            : (isHovering ? LacEditorDesign.hoverFill : Color.clear)
        HStack(spacing: 9) {
            Image(systemName: exists ? language.icon : "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(tint.opacity(activeState == .inactive ? 0.035 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.body.weight(isOpen ? .semibold : .regular))
                    .foregroundStyle(exists ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(exists ? url.deletingLastPathComponent().lastPathComponent : L10n.tr("文件已移动或删除"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isOpen {
                Circle().fill(activeState == .inactive ? Color.secondary : LacEditorDesign.accent)
                    .frame(width: 4, height: 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .contentShape(Rectangle())
        .background(rowBackground, in: RoundedRectangle(cornerRadius: LacEditorDesign.compactCornerRadius, style: .continuous))
        .overlay(alignment: .leading) {
            if isOpen {
                Capsule().fill(activeState == .inactive ? Color.secondary.opacity(0.4) : LacEditorDesign.accent)
                    .frame(width: 2, height: 18)
                    .padding(.leading, 1)
            }
        }
    }
}

private struct SidebarFileContextMenuModifier<MenuContent: View>: ViewModifier {
    let isSelected: Bool
    let menu: MenuContent
    let select: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            menu.onAppear {
                if !isSelected { select() }
            }
        }
    }
}

private struct SidebarFileMetadataModifier: ViewModifier {
    private struct Request: Equatable {
        let url: URL
        let windowIsActive: Bool
    }

    let url: URL
    let windowIsActive: Bool
    @Binding var fileExists: Bool
    @Binding var fileIdentity: DocumentFileIdentity?

    func body(content: Content) -> some View {
        content.task(id: Request(url: url, windowIsActive: windowIsActive)) {
            let url = url
            let metadata = await Task.detached(priority: .utility) {
                (FileManager.default.fileExists(atPath: url.path), DocumentFileIdentity.resolve(url))
            }.value
            guard !Task.isCancelled else { return }
            fileExists = metadata.0
            fileIdentity = metadata.1
        }
    }
}

extension View {
    /// Заголовок группы в боковой панели: тот же шрифт, цвет и отступ, что у заголовков секций.
    func sidebarHeadingStyle() -> some View {
        font(.subheadline.weight(.semibold)).tracking(0.5)
            .foregroundStyle(.secondary).padding(.horizontal, 8)
    }
}
