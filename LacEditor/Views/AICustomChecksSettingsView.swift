import SwiftUI

struct AICustomChecksSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("自定义检查")).font(.system(size: 14, weight: .semibold))
            ForEach($preferences.aiCustomChecks) { $check in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(L10n.tr("启用"), isOn: $check.isEnabled)
                        TextField(L10n.tr("检查名称"), text: $check.name)
                        Button(L10n.tr("删除")) {
                            preferences.aiCustomChecks.removeAll { $0.id == check.id }
                        }
                    }
                    TextField(L10n.tr("检查模型（留空使用功能模型）"), text: $check.modelID)
                    TextEditor(text: $check.instructions)
                        .frame(minHeight: 70)
                        .border(Color.secondary.opacity(0.3))
                }
            }
            Button(L10n.tr("添加检查")) { preferences.aiCustomChecks.append(AICustomCheck()) }
        }
    }
}
