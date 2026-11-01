import SwiftUI

struct TextDiffRow: View {
    let change: AITextComparison.Change

    var body: some View {
        let isAdded = change.kind == .added
        let text = change.text.trimmingCharacters(in: .newlines)
        return HStack(alignment: .top, spacing: 8) {
            Text("\(change.line)").frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
            Text(isAdded ? "+" : "−")
            Text(text)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isAdded ? Color.green : Color.red).opacity(0.18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("%@，第 %lld 行：%@", isAdded ? L10n.tr("已添加") : L10n.tr("已删除"), change.line, text))
    }
}

func textDiffSummary(_ changes: [AITextComparison.Change]) -> String {
    let added = changes.filter { $0.kind == .added }.count
    return L10n.tr("新增 %lld 行，删除 %lld 行", added, changes.count - added)
}
