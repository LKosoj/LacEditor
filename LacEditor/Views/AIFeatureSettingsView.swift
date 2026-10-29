import SwiftUI

struct AIFeatureSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let isActive: Bool
    let keyRevision: UUID
    @State private var selectedFeature: AIFeature = .clarity
    @State private var models: [String] = []
    @State private var modelStatus: StatusMessage?
    @State private var modelTask: Task<Void, Never>?
    @State private var requestID = UUID()

    private var modelBinding: Binding<String> {
        Binding(get: { preferences.aiFeatureModelIDs[selectedFeature.rawValue] ?? "" }, set: { value in
            if value.isEmpty { preferences.aiFeatureModelIDs.removeValue(forKey: selectedFeature.rawValue) }
            else { preferences.aiFeatureModelIDs[selectedFeature.rawValue] = value }
        })
    }

    private var roleName: String {
        switch selectedFeature.role {
        case .text: L10n.tr("文本模型")
        case .decisions: L10n.tr("判断模型")
        case .image: L10n.tr("图像模型")
        case .ocr: L10n.tr("文字识别模型")
        case .audio: L10n.tr("语音转写模型")
        }
    }

    static func displayedValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.tr("未设置") : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PreferenceGroup(title: L10n.tr("通用")) {
                Toggle(L10n.tr("后台 AI 功能"), isOn: $preferences.aiBackgroundEnabled).padding(.horizontal, 16).padding(.vertical, 8)
                Divider().padding(.horizontal, 16).opacity(0.5)
                Toggle(L10n.tr("系统拼写检查"), isOn: $preferences.systemSpellingEnabled).padding(.horizontal, 16).padding(.vertical, 8)
                Divider().padding(.horizontal, 16).opacity(0.5)
                Toggle(L10n.tr("系统语法检查"), isOn: $preferences.systemGrammarEnabled).padding(.horizontal, 16).padding(.vertical, 8)
            }
            ForEach(AIFeatureGroup.allCases) { group in
                PreferenceGroup(title: group.title) {
                    let features = AIFeature.features(in: group)
                    ForEach(features) { feature in
                        Toggle(feature.title, isOn: Binding(
                            get: { preferences.aiFeatures.contains(feature) },
                            set: { enabled in
                                if enabled { preferences.aiFeatures.insert(feature) }
                                else { preferences.aiFeatures.remove(feature) }
                            }
                        )).padding(.horizontal, 16).padding(.vertical, 8)
                        if feature != features.last { Divider().padding(.horizontal, 16).opacity(0.5) }
                    }
                }
            }
            let roleProfile = preferences.aiConfiguration[selectedFeature.role]
            PreferenceGroup(title: L10n.tr("为功能选择模型")) {
                PreferenceRow(title: L10n.tr("功能"), detail: "") {
                    Picker(L10n.tr("功能"), selection: $selectedFeature) {
                        ForEach(AIFeature.allCases.filter { $0 != .provenance }) { feature in
                            Text(feature.title).tag(feature)
                        }
                    }.labelsHidden().frame(width: 220)
                }
                SettingsRowDivider()
                PreferenceRow(title: L10n.tr("模型名称"),
                              detail: L10n.tr("使用%@的服务地址：%@", roleName, Self.displayedValue(roleProfile.baseURL))
                              + "\n" + L10n.tr("留空使用默认模型：%@", Self.displayedValue(roleProfile.modelID))) {
                    TextField(L10n.tr("功能模型名称（留空使用默认值）"), text: modelBinding)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .accessibilityLabel(L10n.tr("功能模型名称（留空使用默认值）"))
                }
                SettingsRowDivider()
                PreferenceRow(title: L10n.tr("选择模型"),
                              detail: roleProfile.isEnabled ? "" : L10n.tr("未启用此功能所用的服务（%@）。请先在「%@」分区开启。", roleName, AISettingsPage.connections.title)) {
                    HStack {
                        Button(L10n.tr("获取模型列表"), action: fetchModels)
                            .disabled(modelTask != nil || !isActive || !roleProfile.isEnabled)
                            .help(roleProfile.isEnabled ? "" : L10n.tr("未启用此功能所用的服务（%@）。请先在「%@」分区开启。", roleName, AISettingsPage.connections.title))
                        if modelTask != nil { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在获取模型列表…")) }
                        if !models.isEmpty {
                            Menu(L10n.tr("选择模型")) {
                                ForEach(models, id: \.self) { model in
                                    Button(model) { modelBinding.wrappedValue = model }
                                }
                            }
                        }
                    }
                }
                if let modelStatus {
                    StatusMessageView(kind: modelStatus.kind, text: modelStatus.text)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .onChange(of: selectedFeature) { _, _ in invalidateModels() }
        .onChange(of: preferences.aiConfiguration) { _, _ in invalidateModels() }
        .onChange(of: keyRevision) { _, _ in invalidateModels() }
        .onChange(of: isActive) { _, active in if !active { invalidateModels() } }
        .onDisappear { invalidateModels() }
    }

    private func invalidateModels() {
        requestID = UUID()
        modelTask?.cancel()
        modelTask = nil
        models = []
        modelStatus = nil
    }

    private func fetchModels() {
        let feature = selectedFeature
        let profile = preferences.aiConfiguration[feature.role]
        let id = UUID()
        requestID = id
        models = []
        modelStatus = nil
        do {
            let key = try AIKeychainStore().load(for: feature.role, baseURL: profile.baseURL)
            modelTask = Task { @MainActor in
                do {
                    let result = try await AIClient().listModels(profile: profile, key: key)
                    guard !Task.isCancelled, isActive, requestID == id,
                          selectedFeature == feature, preferences.aiConfiguration[feature.role] == profile else { return }
                    guard try AIKeychainStore().load(for: feature.role, baseURL: profile.baseURL) == key else {
                        modelTask = nil
                        return
                    }
                    models = result
                    modelStatus = result.isEmpty
                        ? StatusMessage(kind: .info, text: L10n.tr("服务器没有返回模型"))
                        : StatusMessage(kind: .success, text: L10n.tr("找到 %d 个模型", result.count))
                } catch {
                    guard !Task.isCancelled, isActive, requestID == id else { return }
                    modelStatus = StatusMessage(kind: .error, text: error.localizedDescription)
                }
                if requestID == id { modelTask = nil }
            }
        } catch { modelStatus = StatusMessage(kind: .error, text: error.localizedDescription) }
    }
}
