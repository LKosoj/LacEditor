import SwiftUI
import AppKit

struct FolderWorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: FolderWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("工作文件夹"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.rootURL != nil {
                    Button { store.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("刷新文件夹"))
                    .accessibilityLabel(L10n.tr("刷新文件夹"))
                }
            }
            if let root = store.rootURL {
                Text(root.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(root.path)
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
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if let notice = store.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(L10n.tr("打开文件夹…")) { appState.openFolder() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct FolderWorkspaceRowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: FolderWorkspaceStore
    let row: FolderWorkspaceVisibleRow

    var body: some View {
        Group {
            switch row.content {
            case let .group(title):
                Text(title).fontWeight(.semibold).foregroundStyle(.secondary)
            case .loading:
                Text(L10n.tr("正在读取文件夹…"))
                    .foregroundStyle(.secondary)
            case .empty:
                Text(L10n.tr("文件夹为空"))
                    .foregroundStyle(.secondary)
            case let .error(error):
                Text(L10n.tr("无法读取文件夹：%@", error))
                    .foregroundStyle(.secondary)
            case let .entry(entry):
                entryView(entry)
                    .contextMenu {
                        if entry.isDirectory && !entry.isSymbolicLink {
                            Button(L10n.tr("新建文件")) { appState.createFolderWorkspaceItem(in: entry.url, isDirectory: false) }
                            Button(L10n.tr("新建文件夹")) { appState.createFolderWorkspaceItem(in: entry.url, isDirectory: true) }
                        }
                        Button(L10n.tr("复制文件或文件夹")) { appState.duplicateFolderWorkspaceItem(entry.url) }
                        Button(L10n.tr("重命名")) { appState.moveFolderWorkspaceItem(entry.url, rename: true) }
                        Button(L10n.tr("移动到…")) { appState.moveFolderWorkspaceItem(entry.url, rename: false) }
                        Button(L10n.tr("移到废纸篓")) { appState.trashFolderWorkspaceItem(entry.url) }
                        Button(L10n.tr("复制路径")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.url.path, forType: .string)
                        }
                        Button(L10n.tr("在 Finder 中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                    }
            }
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(row.depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func entryView(_ entry: FolderWorkspaceEntry) -> some View {
        if entry.isDirectory && !entry.isSymbolicLink {
            Button {
                if store.display == .list { store.showDirectory(entry.url) }
                else if store.expanded.contains(entry.url) { store.collapse(entry.url) }
                else { store.expand(entry.url) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.display == .tree && store.expanded.contains(entry.url) ? "chevron.down" : "chevron.right")
                    Label(entry.name, systemImage: "folder")
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityValue(L10n.tr(store.expanded.contains(entry.url) ? "已展开" : "已收起"))
            .buttonStyle(.plain)
        } else {
            Button { appState.openFile(entry.url) } label: {
                Label(entry.name, systemImage: entry.isSymbolicLink ? "doc.on.doc" : "doc.text")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(entry.url.path)
        }
    }
}
