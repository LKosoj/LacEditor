import Combine
import SwiftUI

struct MarkdownOutlineView: View {
    @ObservedObject var document: EditorDocument
    var maximumLevel = 6
    let reveal: (MarkdownHeading) -> Void
    @State private var visibleHeadings: [MarkdownHeading] = []
    @State private var currentID: Int?
    @State private var contentHeight: CGFloat = 0
    @FocusState private var focusedID: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !document.isMarkdownOutlineCurrent {
                        Text(L10n.tr("正在更新大纲…"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else if visibleHeadings.isEmpty {
                        Text(L10n.tr("暂无标题"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(visibleHeadings) { heading in
                            MarkdownOutlineRow(heading: heading, isCurrent: heading.id == currentID) { reveal(heading) }
                                .focused($focusedID, equals: heading.id)
                                .editorFocusRing(focusedID == heading.id)
                                .id(heading.id)
                                .onKeyPress(.upArrow) { moveFocus(from: heading.id, offset: -1, proxy: proxy) }
                                .onKeyPress(.downArrow) { moveFocus(from: heading.id, offset: 1, proxy: proxy) }
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            // Короткое оглавление не оставляет пустого места, длинное прокручивается внутри 320 pt.
            .frame(height: min(contentHeight > 0 ? contentHeight : 320, 320))
        }
        .onReceive(Publishers.CombineLatest3(document.$markdownHeadings, document.$selectionRange,
                                             document.$isMarkdownOutlineCurrent)) { value in
            // значения берём из публикации: `@Published` сообщает до записи свойства
            let (headings, selection, isCurrent) = value
            let id = MarkdownOutlineCurrent.headingID(in: headings.filter { $0.level <= maximumLevel },
                                                      caret: selection.location, isCurrent: isCurrent)
            if id != currentID { currentID = id }
        }
        .onReceive(document.$markdownHeadings) { headings in
            visibleHeadings = headings.filter { $0.level <= maximumLevel }
        }
        .onChange(of: maximumLevel) { _, value in
            visibleHeadings = document.markdownHeadings.filter { $0.level <= value }
            currentID = MarkdownOutlineCurrent.headingID(in: visibleHeadings, caret: document.selectionRange.location,
                                                         isCurrent: document.isMarkdownOutlineCurrent)
        }
    }

    private func moveFocus(from id: Int, offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let next = SidebarKeyboardNavigation.moved(from: id, offset: offset, in: visibleHeadings.map(\.id)) else { return .ignored }
        focusedID = next
        proxy.scrollTo(next)
        return .handled
    }
}

private struct MarkdownOutlineRow: View {
    let heading: MarkdownHeading
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let title = heading.renderedTitle.isEmpty ? (heading.number ?? "") + L10n.tr("无标题") : heading.numberedTitle
        Button(action: action) {
            Text(title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(heading.level - 1) * 12)
        }
        .buttonStyle(SoftRowButtonStyle())
        .sidebarRowChrome(selected: isCurrent, hovering: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(L10n.tr("标题 %@ 级", String(heading.level)))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
