import SwiftUI

struct AISettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let isActive: Bool
    @State private var keyRevision = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AIFeatureSettingsView(preferences: preferences, isActive: isActive, keyRevision: keyRevision)
            AICustomChecksSettingsView(preferences: preferences)
            JinaSettingsView(preferences: preferences, isActive: isActive)
            ForEach(AIRole.allCases) { role in
                AIProfileSettingsView(preferences: preferences, role: role, isActive: isActive) { keyRevision = UUID() }
            }
        }
    }
}

private struct AIProfileSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let role: AIRole
    let isActive: Bool
    let keyChanged: () -> Void
    @State private var keyDraft = ""
    @State private var hasSavedKey = false
    @State private var keyError: String?
    @State private var modelError: String?
    @State private var models: [String] = []
    @State private var modelTask: Task<Void, Never>?
    @State private var requestID = UUID()
    private let keychain = AIKeychainStore()

    private var profile: Binding<AIModelProfile> {
        Binding(get: { preferences.aiConfiguration[role] }, set: { preferences.aiConfiguration[role] = $0 })
    }

    private var title: String {
        switch role {
        case .text: L10n.tr("文本模型")
        case .decisions: L10n.tr("判断模型")
        case .image: L10n.tr("图像模型")
        case .ocr: L10n.tr("文字识别模型")
        case .audio: L10n.tr("语音转写模型")
        }
    }

    private var protocols: [AIAPIProtocol] {
        switch role {
        case .text: [.responses, .chatCompletions]
        case .decisions: [.decisions, .responses, .chatCompletions]
        case .image: [.images]
        case .ocr: [.gatewayPDF, .responses, .chatCompletions]
        case .audio: [.transcriptions]
        }
    }

    private func protocolName(_ api: AIAPIProtocol) -> String {
        switch api {
        case .responses: "Responses"
        case .chatCompletions: "Chat Completions"
        case .decisions: "Decisions"
        case .images: "Images"
        case .gatewayPDF: "PDF Convert"
        case .transcriptions: "Audio Transcriptions"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle(L10n.tr("启用"), isOn: profile.isEnabled).toggleStyle(.switch)
            }
            LabeledContent(L10n.tr("服务地址")) {
                TextField("https://example.com/v1", text: profile.baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent(L10n.tr("接口格式")) {
                Picker(L10n.tr("接口格式"), selection: profile.api) {
                    ForEach(protocols, id: \.self) { api in Text(protocolName(api)).tag(api) }
                }.labelsHidden()
            }
            LabeledContent(L10n.tr("模型名称")) {
                TextField(L10n.tr("手动输入模型名称"), text: profile.modelID)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button(L10n.tr("获取模型列表"), action: fetchModels)
                    .disabled(modelTask != nil)
                if modelTask != nil { ProgressView().controlSize(.small) }
                if !models.isEmpty {
                    Menu(L10n.tr("选择模型")) {
                        ForEach(models, id: \.self) { model in
                            Button(model) { profile.wrappedValue.modelID = model }
                        }
                    }
                }
            }
            if let modelError { message(modelError) }
            LabeledContent(L10n.tr("API 密钥")) {
                SecureField(L10n.tr("输入新密钥"), text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button(L10n.tr("保存密钥"), action: saveKey).disabled(keyDraft.isEmpty)
                Button(L10n.tr("删除密钥"), action: deleteKey).disabled(!hasSavedKey)
                if keyError == nil {
                    Text(keyDraft.isEmpty ? (hasSavedKey ? L10n.tr("已保存密钥") : L10n.tr("未保存密钥")) : L10n.tr("密钥更改尚未保存"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let keyError { message(keyError) }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LacEditorDesign.outline))
        .onAppear(perform: refreshKey)
        .onChange(of: profile.wrappedValue.baseURL) { _, _ in
            keyDraft = ""
            refreshKey()
        }
        .onChange(of: profile.wrappedValue) { _, _ in invalidateModels() }
        .onChange(of: isActive) { _, active in
            if active { refreshKey() } else { invalidateModels(); keyDraft = "" }
        }
        .onDisappear { invalidateModels(); keyDraft = "" }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func refreshKey() {
        do {
            hasSavedKey = try keychain.load(for: role, baseURL: profile.wrappedValue.baseURL) != nil
            keyError = nil
        } catch {
            hasSavedKey = false
            keyError = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try keychain.save(keyDraft, for: role, baseURL: profile.wrappedValue.baseURL)
            invalidateModels()
            keyChanged()
            keyDraft = ""
            hasSavedKey = true
            keyError = nil
        } catch { keyError = error.localizedDescription }
    }

    private func deleteKey() {
        do {
            try keychain.delete(for: role, baseURL: profile.wrappedValue.baseURL)
            invalidateModels()
            keyChanged()
            keyDraft = ""
            hasSavedKey = false
            keyError = nil
        } catch { keyError = error.localizedDescription }
    }

    private func invalidateModels() {
        requestID = UUID()
        modelTask?.cancel()
        modelTask = nil
        models = []
        modelError = nil
    }

    private func fetchModels() {
        let selectedProfile = profile.wrappedValue
        let id = UUID()
        requestID = id
        models = []
        modelError = nil
        do {
            let key = try keychain.load(for: role, baseURL: selectedProfile.baseURL)
            modelTask = Task { @MainActor in
                do {
                    let result = try await AIClient().listModels(profile: selectedProfile, key: key)
                    guard !Task.isCancelled, requestID == id, profile.wrappedValue == selectedProfile else { return }
                    models = result
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    modelError = error.localizedDescription
                }
                if requestID == id { modelTask = nil }
            }
        } catch { modelError = error.localizedDescription }
    }
}
