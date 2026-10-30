import SwiftUI

struct MarkdownBacklinksView: View {
    @ObservedObject var controller: MarkdownBacklinksController
    let openFolder: () -> Void
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focusedIndex: Int?

    private var rows: [Int] { Array(controller.matches.indices) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content(proxy: proxy)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            // Как у оглавления: короткий список без пустого места, длинный прокручивается внутри 320 pt.
            .frame(height: min(contentHeight > 0 ? contentHeight : MarkdownOutlineView.estimatedHeight(rowCount: max(controller.matches.count, 1)),
                               MarkdownOutlineView.maximumHeight))
        }
    }

    @ViewBuilder
    private func content(proxy: ScrollViewProxy) -> some View {
        switch controller.state {
        case .inactive:
            EmptyView()
        case .noFolder:
            message(L10n.tr("打开文件夹后可查看反向链接"))
            Button(L10n.tr("打开文件夹…"), action: openFolder).padding(.bottom, 8)
        case .unsaved:
            message(L10n.tr("保存文档后可查看反向链接"))
        case .outsideFolder:
            message(L10n.tr("文档不在当前工作文件夹内"))
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.tr("正在查找反向链接…")).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            rowViews(proxy: proxy)
        case .stale:
            message(L10n.tr("反向链接已过期"))
            Button(L10n.tr("刷新"), action: controller.refreshNow).padding(.bottom, 8)
        case .failed:
            message(L10n.tr("查找反向链接失败"))
            Button(L10n.tr("刷新"), action: controller.refreshNow).padding(.bottom, 8)
        case .loaded:
            if controller.matches.isEmpty {
                message(L10n.tr("暂无反向链接"))
            } else {
                rowViews(proxy: proxy)
            }
            if controller.problemCount > 0 {
                Text(L10n.tr("有 %@ 个文件未能检查", String(controller.problemCount)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        }
    }

    private func rowViews(proxy: ScrollViewProxy) -> some View {
        ForEach(rows, id: \.self) { index in
            let match = controller.matches[index]
            MarkdownBacklinkRow(match: match, index: index) { controller.select(match) }
                .focused($focusedIndex, equals: index)
                .editorFocusRing(focusedIndex == index)
                .id(index)
                .onKeyPress(.upArrow) { moveFocus(from: index, offset: -1, proxy: proxy) }
                .onKeyPress(.downArrow) { moveFocus(from: index, offset: 1, proxy: proxy) }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    private func moveFocus(from index: Int, offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let next = SidebarKeyboardNavigation.moved(from: index, offset: offset, in: rows) else { return .ignored }
        focusedIndex = next
        proxy.scrollTo(next)
        return .handled
    }
}

private struct MarkdownBacklinkRow: View {
    let match: FolderSearchService.Match
    let index: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let context = match.context.trimmingCharacters(in: .whitespacesAndNewlines)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(match.file.relativePath)
                    .font(.caption.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(context)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .buttonStyle(SoftRowButtonStyle())
        .sidebarRowChrome(selected: false, hovering: isHovering)
        .onHover { isHovering = $0 }
        .stableHelp(match.file.relativePath)
        .accessibilityLabel(match.file.relativePath)
        .accessibilityValue(context)
        .accessibilityHint(L10n.tr("跳转到链接位置"))
        .accessibilityIdentifier("sidebar.backlinks.row.\(index)")
    }
}
