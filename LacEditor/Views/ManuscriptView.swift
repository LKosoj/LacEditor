import SwiftUI

struct ManuscriptView: View {
    @ObservedObject var controller: ManuscriptController
    let folderName: String
    let close: () -> Void

    private var selectedIndex: Int? {
        controller.items.firstIndex { $0.id == controller.selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("合并为文稿"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(folderName).font(.subheadline).foregroundStyle(.secondary)
            Text(L10n.tr("选择要合并的 Markdown 文件，拖动行或使用按钮调整顺序。"))
                .font(.caption).foregroundStyle(.secondary)
            fileList
            Text(L10n.tr("已选择 %d 个，共 %d 个文件", controller.selectedCount, controller.items.count))
                .font(.caption).foregroundStyle(.secondary)
            if let message = controller.message {
                StatusMessageView(kind: controller.messageKind, text: message)
            }
            HStack {
                Button(L10n.tr("上移")) { controller.moveSelected(by: -1) }
                    .disabled(selectedIndex == nil || selectedIndex == 0)
                    .accessibilityIdentifier("manuscript.up")
                Button(L10n.tr("下移")) { controller.moveSelected(by: 1) }
                    .disabled(selectedIndex == nil || selectedIndex == controller.items.count - 1)
                    .accessibilityIdentifier("manuscript.down")
                let allSelected = controller.selectedCount == controller.items.count
                Button(allSelected ? L10n.tr("取消全选") : L10n.tr("全选")) { controller.setAll(!allSelected) }
                    .disabled(controller.items.isEmpty)
                    .accessibilityIdentifier("manuscript.toggleAll")
                Spacer()
                if controller.isLoading || controller.isBuilding { ProgressView().controlSize(.small) }
                Button(L10n.tr("取消")) {
                    if controller.isBuilding { controller.cancel() } else { close() }
                }
                    .accessibilityIdentifier("manuscript.cancel")
                Button(L10n.tr("合并")) { controller.build() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canBuild)
                    .accessibilityIdentifier("manuscript.merge")
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .onExitCommand {
            if controller.isBuilding { controller.cancel() } else { close() }
        }
        .onDisappear { controller.cancel() }
    }

    private var fileList: some View {
        List(selection: $controller.selectedID) {
            ForEach(controller.items) { item in
                // Подпись отдельно от флажка: клик по ней выбирает строку, а не переключает файл.
                HStack(spacing: 6) {
                    Toggle(item.file.relativePath, isOn: Binding(get: { item.isOn }, set: { controller.setItem(item.id, on: $0) }))
                        .labelsHidden()
                    Text(item.file.relativePath).lineLimit(1).truncationMode(.middle)
                }
            }
            .onMove(perform: controller.move)
        }
        .overlay {
            if controller.items.isEmpty && !controller.isLoading {
                Text(L10n.tr("文件夹中没有 Markdown 文件"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .accessibilityIdentifier("manuscript.list")
    }
}
