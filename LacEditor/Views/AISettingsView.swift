import SwiftUI

enum AISettingsPage: String, CaseIterable, Identifiable {
    case features, connections, checks, jina

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: L10n.tr("AI 功能")
        case .connections: L10n.tr("连接")
        case .checks: L10n.tr("自定义检查")
        case .jina: "Jina"
        }
    }
}

struct AISettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let isActive: Bool
    @State private var keyRevision = UUID()
    @State private var page: AISettingsPage = .features

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.tr("AI 设置分区"), selection: $page) {
                ForEach(AISettingsPage.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("settings.ai.page")
            switch page {
            case .features:
                AIFeatureSettingsView(preferences: preferences, isActive: isActive, keyRevision: keyRevision)
            case .connections:
                ForEach(AIRole.allCases) { role in
                    AIProfileSettingsView(preferences: preferences, role: role, isActive: isActive) { keyRevision = UUID() }
                }
            case .checks:
                AICustomChecksSettingsView(preferences: preferences)
            case .jina:
                JinaSettingsView(preferences: preferences, isActive: isActive)
            }
        }
    }
}

/// Тонкий разделитель между строками внутри PreferenceGroup.
struct SettingsRowDivider: View {
    var body: some View { Divider().padding(.horizontal, 16).opacity(0.5) }
}

enum AIKeyDraftNotice {
    static func message(forClearedDraft draft: String) -> StatusMessage? {
        draft.isEmpty ? nil : StatusMessage(kind: .info, text: L10n.tr("密钥与服务地址绑定，地址已更改，未保存的密钥输入已清除。"))
    }
}

private struct AIProfileSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let role: AIRole
    let isActive: Bool
    let keyChanged: () -> Void
    @State private var keyDraft = ""
    @State private var hasSavedKey = false
    @State private var keyStatus: StatusMessage?
    @State private var modelStatus: StatusMessage?
    @State private var confirmDeleteKey = false
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
        PreferenceGroup(title: title) {
            PreferenceRow(title: L10n.tr("启用"), detail: profile.wrappedValue.isEnabled ? "" : L10n.tr("未启用，开启后可配置服务地址和密钥。")) {
                Toggle(L10n.tr("启用"), isOn: profile.isEnabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(title)
            }
            if profile.wrappedValue.isEnabled {
                SettingsRowDivider()
                PreferenceRow(title: L10n.tr("服务地址"), detail: "") {
                    TextField("https://example.com/v1", text: profile.baseURL)
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                        .accessibilityLabel(L10n.tr("服务地址"))
                }
                SettingsRowDivider()
                PreferenceRow(title: L10n.tr("接口格式"), detail: "") {
                    Picker(L10n.tr("接口格式"), selection: profile.api) {
                        ForEach(protocols, id: \.self) { api in Text(protocolName(api)).tag(api) }
                    }.labelsHidden().frame(width: 200)
                }
                SettingsRowDivider()
                PreferenceRow(title: L10n.tr("模型名称"), detail: "") {
                    TextField(L10n.tr("手动输入模型名称"), text: profile.modelID)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .accessibilityLabel(L10n.tr("模型名称"))
                }
                SettingsRowDivider()
                PreferenceRow(title: L10n.tr("选择模型"), detail: "") {
                    HStack {
                        if modelTask != nil { ProgressView().controlSize(.small) }
                        if !models.isEmpty {
                            Menu(L10n.tr("选择模型")) {
                                ForEach(models, id: \.self) { model in
                                    Button(model) { profile.wrappedValue.modelID = model }
                                }
                            }
                        }
                        Button(L10n.tr("获取模型列表"), action: fetchModels)
                            .disabled(modelTask != nil)
                    }
                }
                if let modelStatus {
                    StatusMessageView(kind: modelStatus.kind, text: modelStatus.text)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                SettingsRowDivider()
                PreferenceRow(title: L10n.tr("API 密钥"), detail: keyStatus == nil
                              ? (keyDraft.isEmpty ? (hasSavedKey ? L10n.tr("已保存密钥") : L10n.tr("未保存密钥")) : L10n.tr("密钥更改尚未保存"))
                              : "") {
                    SecureField(L10n.tr("输入新密钥"), text: $keyDraft)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .accessibilityLabel(L10n.tr("API 密钥"))
                }
                HStack {
                    Button(L10n.tr("保存密钥"), action: saveKey).disabled(keyDraft.isEmpty)
                    Button(L10n.tr("删除密钥"), role: .destructive) { confirmDeleteKey = true }.disabled(!hasSavedKey)
                }.padding(.horizontal, 16).padding(.vertical, 8)
                if let keyStatus {
                    StatusMessageView(kind: keyStatus.kind, text: keyStatus.text)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .onAppear(perform: refreshKey)
        .confirmationDialog(L10n.tr("删除已保存的密钥？"), isPresented: $confirmDeleteKey, titleVisibility: .visible) {
            Button(L10n.tr("删除密钥"), role: .destructive) { deleteKey() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("密钥将从系统钥匙串中移除。"))
        }
        .onChange(of: profile.wrappedValue.baseURL) { _, _ in
            let notice = AIKeyDraftNotice.message(forClearedDraft: keyDraft)
            keyDraft = ""
            refreshKey()
            if let notice, keyStatus == nil { keyStatus = notice }
        }
        .onChange(of: keyDraft) { _, draft in if !draft.isEmpty { keyStatus = nil } }
        .onChange(of: profile.wrappedValue.isEnabled) { _, enabled in
            if !enabled { invalidateModels(); keyDraft = "" }
        }
        .onChange(of: profile.wrappedValue) { _, _ in invalidateModels() }
        .onChange(of: isActive) { _, active in
            if active { refreshKey() } else { invalidateModels(); keyDraft = "" }
        }
        .onDisappear { invalidateModels(); keyDraft = "" }
    }

    private func refreshKey() {
        do {
            hasSavedKey = try keychain.load(for: role, baseURL: profile.wrappedValue.baseURL) != nil
            keyStatus = nil
        } catch {
            hasSavedKey = false
            keyStatus = StatusMessage(kind: .error, text: error.localizedDescription)
        }
    }

    private func saveKey() {
        do {
            try keychain.save(keyDraft, for: role, baseURL: profile.wrappedValue.baseURL)
            invalidateModels()
            keyChanged()
            keyDraft = ""
            hasSavedKey = true
            keyStatus = StatusMessage(kind: .success, text: L10n.tr("密钥已保存"))
        } catch { keyStatus = StatusMessage(kind: .error, text: error.localizedDescription) }
    }

    private func deleteKey() {
        do {
            try keychain.delete(for: role, baseURL: profile.wrappedValue.baseURL)
            invalidateModels()
            keyChanged()
            keyDraft = ""
            hasSavedKey = false
            keyStatus = StatusMessage(kind: .success, text: L10n.tr("密钥已删除"))
        } catch { keyStatus = StatusMessage(kind: .error, text: error.localizedDescription) }
    }

    private func invalidateModels() {
        requestID = UUID()
        modelTask?.cancel()
        modelTask = nil
        models = []
        modelStatus = nil
    }

    private func fetchModels() {
        let selectedProfile = profile.wrappedValue
        let id = UUID()
        requestID = id
        models = []
        modelStatus = nil
        do {
            let key = try keychain.load(for: role, baseURL: selectedProfile.baseURL)
            modelTask = Task { @MainActor in
                do {
                    let result = try await AIClient().listModels(profile: selectedProfile, key: key)
                    guard !Task.isCancelled, requestID == id, profile.wrappedValue == selectedProfile else { return }
                    models = result
                    modelStatus = result.isEmpty
                        ? StatusMessage(kind: .info, text: L10n.tr("服务器没有返回模型"))
                        : StatusMessage(kind: .success, text: L10n.tr("找到 %d 个模型", result.count))
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    modelStatus = StatusMessage(kind: .error, text: error.localizedDescription)
                }
                if requestID == id { modelTask = nil }
            }
        } catch { modelStatus = StatusMessage(kind: .error, text: error.localizedDescription) }
    }
}
