import SwiftUI

/// Раздел «Теги» боковой панели: плоский список тегов рабочей папки, загружается при раскрытии, смене папки и по кнопке.
struct FolderTagsSection: View {
    @ObservedObject var store: FolderWorkspaceStore
    let controller: FolderTagsController
    let search: FolderSearchController
    @State private var isExpanded = false

    var body: some View {
        if store.rootURL != nil {
            DisclosureGroup(isExpanded: $isExpanded) {
                FolderTagsList(controller: controller, search: search)
            } label: {
                Text(L10n.tr("标签"))
                    .font(.subheadline.weight(.semibold)).tracking(0.5)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .onChange(of: isExpanded) { _, expanded in
                if expanded { _ = controller.reload() } else { controller.invalidate() }
            }
            .onChange(of: store.rootURL) { _, _ in
                if isExpanded { _ = controller.reload() }
            }
            .onAppear {
                if isExpanded, !controller.hasLoaded, !controller.isWorking { _ = controller.reload() }
            }
        }
    }
}

private struct FolderTagsList: View {
    @ObservedObject var controller: FolderTagsController
    let search: FolderSearchController
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focusedName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if controller.isWorking {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("正在读取标签…")).font(.caption).foregroundStyle(.secondary)
                } else if controller.hasProblems {
                    Text(L10n.tr("部分文件无法读取标签")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { _ = controller.reload() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("刷新标签"))
                .stableHelp(L10n.tr("刷新标签"))
            }
            if let message = controller.message {
                Text(message == .stale ? L10n.tr("标签列表已过期，请刷新") : L10n.tr("无法读取标签"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("刷新")) { _ = controller.reload() }
                    .controlSize(.small)
            } else if controller.hasLoaded && controller.tags.isEmpty {
                Text(L10n.tr("暂无标签")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            } else if !controller.tags.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(controller.tags, id: \.name) { entry in
                                FolderTagRow(entry: entry) { _ = search.searchTag(entry.name) }
                                    .focused($focusedName, equals: entry.name)
                                    .editorFocusRing(focusedName == entry.name)
                                    .id(entry.name)
                                    .onKeyPress(.upArrow) { moveFocus(from: entry.name, offset: -1, proxy: proxy) }
                                    .onKeyPress(.downArrow) { moveFocus(from: entry.name, offset: 1, proxy: proxy) }
                            }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                    }
                    .frame(height: min(contentHeight > 0 ? contentHeight : MarkdownOutlineView.estimatedHeight(rowCount: controller.tags.count),
                                       MarkdownOutlineView.maximumHeight))
                }
            }
        }
    }

    private func moveFocus(from name: String, offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let next = SidebarKeyboardNavigation.moved(from: name, offset: offset, in: controller.tags.map(\.name)) else { return .ignored }
        focusedName = next
        proxy.scrollTo(next)
        return .handled
    }
}

private struct FolderTagRow: View {
    let entry: FolderSearchService.TagEntry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("#" + entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(String(entry.fileCount)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SoftRowButtonStyle())
        .sidebarRowChrome(selected: false, hovering: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(L10n.tr("标签 %@", entry.name))
        .accessibilityValue(L10n.tr("%@ 个文件", String(entry.fileCount)))
    }
}
