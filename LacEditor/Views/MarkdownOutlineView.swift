import SwiftUI

struct MarkdownOutlineView: View {
    @ObservedObject var document: EditorDocument
    var maximumLevel = 6
    let reveal: (MarkdownHeading) -> Void
    @State private var visibleHeadings: [MarkdownHeading] = []

    var body: some View {
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
                        Button {
                            reveal(heading)
                        } label: {
                            Text(heading.renderedTitle.isEmpty ? (heading.number ?? "") + L10n.tr("无标题") : heading.numberedTitle)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, CGFloat(heading.level - 1) * 12)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .onReceive(document.$markdownHeadings) { headings in
            visibleHeadings = headings.filter { $0.level <= maximumLevel }
        }
        .onChange(of: maximumLevel) { _, value in
            visibleHeadings = document.markdownHeadings.filter { $0.level <= value }
        }
    }
}
