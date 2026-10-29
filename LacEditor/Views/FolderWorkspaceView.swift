import SwiftUI
import AppKit

struct FolderWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: FolderWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("工作文件夹"))
                    .sidebarHeadingStyle()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if store.rootURL != nil {
                    Button { store.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .stableHelp(L10n.tr("刷新文件夹"))
                    .accessibilityLabel(L10n.tr("刷新文件夹"))
                }
            }
            if let root = store.rootURL {
                Text(root.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .stableHelp(root.path)
                    .contextMenu {
                        Button(L10n.tr("新建文件")) { appState.createFolderWorkspaceItem(in: root, isDirectory: false) }
                        Button(L10n.tr("新建文件夹")) { appState.createFolderWorkspaceItem(in: root, isDirectory: true) }
                    }
                HStack {
                    Menu(L10n.tr("显示方式")) {
                        Picker(L10n.tr("显示方式"), selection: Binding(get: { store.display }, set: { store.setDisplay($0) })) {
                            Text(L10n.tr("树形")).tag(FolderWorkspaceStore.Display.tree)
                            Text(L10n.tr("列表")).tag(FolderWorkspaceStore.Display.list)
                        }
                    }
                    Menu(L10n.tr("排序")) {
                        Picker(L10n.tr("排序"), selection: Binding(get: { store.sort }, set: { store.setSort($0) })) {
                            Text(L10n.tr("名称")).tag(FolderWorkspaceStore.Sort.name)
                            Text(L10n.tr("自然顺序")).tag(FolderWorkspaceStore.Sort.natural)
                            Text(L10n.tr("创建日期")).tag(FolderWorkspaceStore.Sort.created)
                            Text(L10n.tr("修改日期")).tag(FolderWorkspaceStore.Sort.modified)
                        }
                        Divider()
                        Picker(L10n.tr("排序方向"), selection: Binding(get: { store.ascending }, set: { store.setAscending($0) })) {
                            Text(L10n.tr("升序")).tag(true)
                            Text(L10n.tr("降序")).tag(false)
                        }
                        Toggle(L10n.tr("按文件夹分组"), isOn: Binding(get: { store.groupByFolder }, set: { store.setGroupByFolder($0) }))
                    }
                }
                if let error = store.watchError {
                    StatusMessageView(kind: .error, text: error)
                }
                if let notice = store.notice {
                    StatusMessageView(kind: .info, text: notice)
                }
            } else {
                Text(L10n.tr("选择包含文档的文件夹"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("打开文件夹…")) { appState.openFolder() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: store.watchError) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .onChange(of: store.notice) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}

struct FolderWorkspaceVisibleRow: Identifiable {
    enum Content {
        case entry(FolderWorkspaceEntry), group(String), loading, empty, error(String)
    }
    struct ID: Hashable {
        let url: URL
        let status: Bool
    }

    let id: ID
    let depth: Int
    let content: Content

    @MainActor
    static func rows(in store: FolderWorkspaceStore) -> [Self] {
        guard let root = store.rootURL else { return [] }
        var result: [Self] = []
        func appendDirectory(_ directory: URL, depth: Int) {
            if store.loading.contains(directory) {
                result.append(Self(id: ID(url: directory, status: true), depth: depth, content: .loading))
            } else if let error = store.errors[directory] {
                result.append(Self(id: ID(url: directory, status: true), depth: depth, content: .error(error)))
            } else if let children = store.entries[directory] {
                if children.isEmpty {
                    result.append(Self(id: ID(url: directory, status: true), depth: depth, content: .empty))
                } else {
                    for entry in children {
                        result.append(Self(id: ID(url: entry.url, status: false), depth: depth, content: .entry(entry)))
                        if store.display == .tree && entry.isDirectory && !entry.isSymbolicLink && store.expanded.contains(entry.url) {
                            appendDirectory(entry.url, depth: depth + 1)
                        }
                    }
                }
            }
        }
        if store.display == .list {
            if store.loading.contains(root) { result.append(Self(id: ID(url: root, status: true), depth: 0, content: .loading)) }
            else if let error = store.errors[root] { result.append(Self(id: ID(url: root, status: true), depth: 0, content: .error(error))) }
            else if store.listEntries.isEmpty { result.append(Self(id: ID(url: root, status: true), depth: 0, content: .empty)) }
            else {
                var previous: URL?
                for entry in store.listEntries {
                    let parent = entry.url.deletingLastPathComponent()
                    if store.groupByFolder && parent != previous {
                        let base = root.standardizedFileURL.pathComponents
                        let parts = parent.standardizedFileURL.pathComponents
                        let title = parts.starts(with: base) ? parts.dropFirst(base.count).joined(separator: "/") : parent.path
                        result.append(Self(id: ID(url: parent, status: true), depth: 0, content: .group(title.isEmpty ? root.lastPathComponent : title)))
                        previous = parent
                    }
                    result.append(Self(id: ID(url: entry.url, status: false), depth: 0, content: .entry(entry)))
                }
            }
        } else { appendDirectory(root, depth: 0) }
        return result
    }
}

/// Строка с клавиатурным фокусом в дереве папки или в результатах поиска: фокус = выделение.
/// `order` — только выбираемые строки в порядке показа; не сохраняется в сессии.
@MainActor
final class FolderListNavigation: ObservableObject {
    @Published var focused: AnyHashable?
    var order: [AnyHashable] = []
    /// Цель клавиатурного перехода, ещё не созданная ленивым списком; см. SidebarSelection.focusRequest.
    var focusRequest: AnyHashable?

    func setOrder(_ ids: [AnyHashable]) {
        order = ids
        if let focused, !ids.contains(focused) { self.focused = nil }
    }

    func move(from current: AnyHashable?, offset: Int) {
        if let next = SidebarKeyboardNavigation.moved(from: current, offset: offset, in: order) {
            focusRequest = next == current ? nil : next
            focused = next
        }
    }
}

/// Подсветка строки списка: выделение / hover; фокус рисует editorFocusRing снаружи.
struct SidebarRowChrome: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isSelected ? (activeState == .inactive ? Color.primary.opacity(0.07) : LacEditorDesign.selectionFill)
                                   : (isHovering ? LacEditorDesign.hoverFill : .clear),
                        in: RoundedRectangle(cornerRadius: LacEditorDesign.compactCornerRadius, style: .continuous))
    }
}

extension View {
    func sidebarRowChrome(selected: Bool, hovering: Bool) -> some View {
        modifier(SidebarRowChrome(isSelected: selected, isHovering: hovering))
    }
}

/// Общее поведение выбираемой строки дерева и поиска: hover, фокус, выделение, Вверх/Вниз/Return.
struct FolderListRowNavigation: ViewModifier {
    let id: AnyHashable
    @ObservedObject var navigation: FolderListNavigation
    let onReturn: () -> KeyPress.Result
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    init(id: AnyHashable, navigation: FolderListNavigation, onReturn: @escaping () -> KeyPress.Result) {
        self.id = id
        self.navigation = navigation
        self.onReturn = onReturn
    }

    private var isSelected: Bool { navigation.focused == id }

    func body(content: Content) -> some View {
        content
            .buttonStyle(SoftRowButtonStyle())
            .sidebarRowChrome(selected: isSelected, hovering: isHovering)
            .focused($isFocused)
            .editorFocusRing(isFocused)
            .onHover { isHovering = $0 }
            .onChange(of: navigation.focused) { _, value in if value == id { isFocused = true } }
            .onChange(of: isFocused) { _, focused in if focused { navigation.focused = id; navigation.focusRequest = nil } }
            .onAppear { if navigation.focusRequest == id { isFocused = true } }
            .onKeyPress(.upArrow) { navigation.move(from: id, offset: -1); return .handled }
            .onKeyPress(.downArrow) { navigation.move(from: id, offset: 1); return .handled }
            .onKeyPress(.return) { onReturn() }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct FolderWorkspaceRowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: FolderWorkspaceStore
    let row: FolderWorkspaceVisibleRow
    let rows: [FolderWorkspaceVisibleRow]
    let navigation: FolderListNavigation

    var body: some View {
        Group {
            switch row.content {
            case let .group(title):
                Text(title).fontWeight(.semibold).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            case .loading:
                Text(L10n.tr("正在读取文件夹…"))
                    .foregroundStyle(.secondary)
            case .empty:
                Text(L10n.tr("文件夹为空"))
                    .foregroundStyle(.secondary)
            case let .error(error):
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("无法读取文件夹：%@", error))
                        .foregroundStyle(.secondary)
                    if row.id.url == store.rootURL {
                        Button(L10n.tr("选择其他文件夹…")) { appState.openFolder() }.controlSize(.small)
                    }
                }
            case let .entry(entry):
                entryView(entry)
                    .contextMenu {
                        if !(entry.isDirectory && !entry.isSymbolicLink) {
                            Button(L10n.tr("打开")) { perform(.return) }
                            Divider()
                        }
                        if entry.isDirectory && !entry.isSymbolicLink {
                            Button(L10n.tr("新建文件")) { appState.createFolderWorkspaceItem(in: entry.url, isDirectory: false) }
                            Button(L10n.tr("新建文件夹")) { appState.createFolderWorkspaceItem(in: entry.url, isDirectory: true) }
                        }
                        Button(L10n.tr("复制文件或文件夹")) { appState.duplicateFolderWorkspaceItem(entry.url) }
                        Button(L10n.tr("重命名…")) { appState.moveFolderWorkspaceItem(entry.url, rename: true) }
                        Button(L10n.tr("移动到…")) { appState.moveFolderWorkspaceItem(entry.url, rename: false) }
                        Divider()
                        Button(L10n.tr("复制路径")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.url.path, forType: .string)
                        }
                        Button(L10n.tr("在 Finder 中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                        Divider()
                        Button(L10n.tr("移到废纸篓"), role: .destructive) { appState.trashFolderWorkspaceItem(entry.url) }
                    }
            }
        }
        .font(.callout)
        .padding(.leading, CGFloat(row.depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entryView(_ entry: FolderWorkspaceEntry) -> some View {
        let id = AnyHashable(row.id)
        if entry.isDirectory && !entry.isSymbolicLink {
            Button {
                navigation.focused = id
                perform(.return)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.display == .tree && store.expanded.contains(entry.url) ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    Label(entry.name, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityValue(L10n.tr(store.expanded.contains(entry.url) ? "已展开" : "已收起"))
            .accessibilityHint(L10n.tr(store.display == .tree ? "展开或收起文件夹" : "显示此文件夹的内容"))
            .modifier(FolderListRowNavigation(id: id, navigation: navigation) { perform(.return) })
            .onKeyPress(.leftArrow) { perform(.left) }
            .onKeyPress(.rightArrow) { perform(.right) }
        } else {
            Button {
                navigation.focused = id
                perform(.return)
            } label: {
                Label(entry.name, systemImage: entry.isSymbolicLink ? "doc.on.doc" : "doc.text")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(FolderListRowNavigation(id: id, navigation: navigation) { perform(.return) })
            .onKeyPress(.leftArrow) { perform(.left) }
            .onKeyPress(.rightArrow) { perform(.right) }
            .stableHelp(entry.url.path)
        }
    }

    /// Единый путь для клика и клавиш: действие выбирает `FolderTreeKeyResolver`.
    @discardableResult
    private func perform(_ key: FolderTreeKey) -> KeyPress.Result {
        guard case let .entry(entry) = row.content,
              let action = FolderTreeKeyResolver.resolve(key: key, row: row, rows: rows, display: store.display,
                                                         isExpanded: store.expanded.contains(entry.url)) else { return .ignored }
        switch action {
        case let .toggle(url): if store.expanded.contains(url) { store.collapse(url) } else { store.expand(url) }
        case let .showDirectory(url): store.showDirectory(url)
        case let .open(url): appState.openFile(url)
        case let .expand(url): store.expand(url)
        case let .collapse(url): store.collapse(url)
        case let .focus(id):
            navigation.focused = AnyHashable(id)
            navigation.focusRequest = AnyHashable(id)
        }
        return .handled
    }
}
