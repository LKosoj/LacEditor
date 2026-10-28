import SwiftUI

struct AIFeatureSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let isActive: Bool
    let keyRevision: UUID
    @State private var selectedFeature: AIFeature = .clarity
    @State private var models: [String] = []
    @State private var modelError: String?
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.tr("后台 AI 功能"), isOn: $preferences.aiBackgroundEnabled)
            Toggle(L10n.tr("系统拼写检查"), isOn: $preferences.systemSpellingEnabled)
            Toggle(L10n.tr("系统语法检查"), isOn: $preferences.systemGrammarEnabled)
            Text(L10n.tr("AI 功能")).font(.system(size: 14, weight: .semibold))
            ForEach(AIFeature.allCases) { feature in
                Toggle(feature.title, isOn: Binding(
                    get: { preferences.aiFeatures.contains(feature) },
                    set: { enabled in
                        if enabled { preferences.aiFeatures.insert(feature) }
                        else { preferences.aiFeatures.remove(feature) }
                    }
                ))
            }
            Text(L10n.tr("为功能选择模型")).font(.system(size: 14, weight: .semibold))
            Picker(L10n.tr("功能"), selection: $selectedFeature) {
                ForEach(AIFeature.allCases.filter { $0 != .provenance }) { feature in
                    Text(feature.title).tag(feature)
                }
            }
            let roleProfile = preferences.aiConfiguration[selectedFeature.role]
            Text(L10n.tr("使用%@的服务地址：%@", roleName, roleProfile.baseURL))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(L10n.tr("留空使用默认模型：%@", roleProfile.modelID))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(L10n.tr("功能模型名称（留空使用默认值）"), text: modelBinding)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(L10n.tr("获取模型列表"), action: fetchModels).disabled(modelTask != nil || !isActive)
                if modelTask != nil { ProgressView().controlSize(.small) }
                if !models.isEmpty {
                    Menu(L10n.tr("选择模型")) {
                        ForEach(models, id: \.self) { model in
                            Button(model) { modelBinding.wrappedValue = model }
                        }
                    }
                }
            }
            if let modelError { Text(modelError).font(.system(size: 11)).foregroundStyle(.secondary) }
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
        modelError = nil
    }

    private func fetchModels() {
        let feature = selectedFeature
        let profile = preferences.aiConfiguration[feature.role]
        let id = UUID()
        requestID = id
        models = []
        modelError = nil
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
                } catch {
                    guard !Task.isCancelled, isActive, requestID == id else { return }
                    modelError = error.localizedDescription
                }
                if requestID == id { modelTask = nil }
            }
        } catch { modelError = error.localizedDescription }
    }
}
