import SwiftUI

struct AICustomChecksSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @State private var checkToDelete: UUID?

    static func emptyStateText(isEmpty: Bool) -> String? {
        isEmpty ? L10n.tr("尚未添加自定义检查。添加后可用自己的说明检查文档。") : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferenceGroup(title: L10n.tr("自定义检查")) {
                PreferenceRow(title: L10n.tr("自定义检查"),
                              detail: Self.emptyStateText(isEmpty: preferences.aiCustomChecks.isEmpty) ?? "") {
                    Button(L10n.tr("添加检查")) { preferences.aiCustomChecks.append(AICustomCheck()) }
                }
            }
            ForEach($preferences.aiCustomChecks) { $check in
                PreferenceGroup(title: check.name.isEmpty ? L10n.tr("未命名检查") : check.name, searchID: nil) {
                    PreferenceRow(title: L10n.tr("检查名称"), detail: "") {
                        TextField(L10n.tr("检查名称"), text: $check.name)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .accessibilityLabel(L10n.tr("检查名称"))
                    }
                    SettingsRowDivider()
                    PreferenceRow(title: L10n.tr("启用"), detail: "") {
                        Toggle(L10n.tr("启用"), isOn: $check.isEnabled).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel(check.name.isEmpty ? L10n.tr("启用") : check.name)
                    }
                    SettingsRowDivider()
                    PreferenceRow(title: L10n.tr("模型名称"), detail: L10n.tr("检查模型（留空使用功能模型）")) {
                        TextField(L10n.tr("检查模型（留空使用功能模型）"), text: $check.modelID)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .accessibilityLabel(L10n.tr("检查模型（留空使用功能模型）"))
                    }
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr("检查说明")).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $check.instructions)
                            .frame(minHeight: 70)
                            .border(Color.secondary.opacity(0.3))
                            .accessibilityLabel(L10n.tr("检查说明"))
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                    SettingsRowDivider()
                    HStack {
                        Button(L10n.tr("删除"), role: .destructive) { checkToDelete = check.id }
                        Spacer()
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .confirmationDialog(
            L10n.tr("删除此检查？"),
            isPresented: Binding(get: { checkToDelete != nil }, set: { if !$0 { checkToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("删除"), role: .destructive) {
                if let id = checkToDelete { preferences.aiCustomChecks.removeAll { $0.id == id } }
                checkToDelete = nil
            }
            Button(L10n.tr("取消"), role: .cancel) { checkToDelete = nil }
        } message: {
            Text(L10n.tr("此操作无法撤销。"))
        }
    }
}
