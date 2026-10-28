import SwiftUI

struct MarkdownOutlineView: View {
    @ObservedObject var document: EditorDocument
    let reveal: (MarkdownHeading) -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !document.isMarkdownOutlineCurrent {
                    Text(L10n.tr("正在更新大纲…"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if document.markdownHeadings.isEmpty {
                    Text(L10n.tr("暂无标题"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(document.markdownHeadings) { heading in
                        Button {
                            reveal(heading)
                        } label: {
                            Text(heading.title.isEmpty ? L10n.tr("无标题") : heading.title)
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
    }
}
