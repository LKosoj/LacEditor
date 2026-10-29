import SwiftUI

struct JinaSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(JinaServiceKind.allCases) { service in
                JinaServiceSettingsView(preferences: preferences, service: service, isActive: isActive)
            }
        }
    }
}

private struct JinaServiceSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let service: JinaServiceKind
    let isActive: Bool
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var status: StatusMessage?
    @State private var confirmDeleteKey = false
    private let keychain = AIKeychainStore()

    private var endpoint: Binding<String> {
        Binding(
            get: { service == .search ? preferences.jinaConfiguration.searchEndpoint : preferences.jinaConfiguration.readerEndpoint },
            set: {
                if service == .search { preferences.jinaConfiguration.searchEndpoint = $0 }
                else { preferences.jinaConfiguration.readerEndpoint = $0 }
            }
        )
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { service == .search ? preferences.jinaConfiguration.searchEnabled : preferences.jinaConfiguration.readerEnabled },
            set: {
                if service == .search { preferences.jinaConfiguration.searchEnabled = $0 }
                else { preferences.jinaConfiguration.readerEnabled = $0 }
            }
        )
    }

    private var serviceTitle: String {
        service == .search ? L10n.tr("Jina 搜索") : L10n.tr("Jina 网页读取")
    }

    var body: some View {
        PreferenceGroup(title: serviceTitle) {
            Toggle(serviceTitle, isOn: enabled).padding(.horizontal, 16).padding(.vertical, 8)
            SettingsRowDivider()
            PreferenceRow(title: L10n.tr("完整接口地址"), detail: "") {
                TextField(service == .search ? "https://s.jina.ai/search" : "https://r.jina.ai/", text: endpoint)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .accessibilityLabel(L10n.tr("完整接口地址"))
            }
            SettingsRowDivider()
            PreferenceRow(title: L10n.tr("API 密钥"),
                          detail: keyDraft.isEmpty
                          ? (hasKey ? L10n.tr("已保存密钥") : L10n.tr("未保存密钥"))
                          : L10n.tr("密钥更改尚未保存")) {
                SecureField(L10n.tr("输入新密钥"), text: $keyDraft)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
                    .accessibilityLabel("\(serviceTitle) \(L10n.tr("API 密钥"))")
            }
            HStack {
                Button(L10n.tr("保存密钥")) { saveKey() }.disabled(keyDraft.isEmpty)
                Button(L10n.tr("删除密钥"), role: .destructive) { confirmDeleteKey = true }.disabled(!hasKey)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            if let status {
                StatusMessageView(kind: status.kind, text: status.text)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .confirmationDialog(L10n.tr("删除已保存的密钥？"), isPresented: $confirmDeleteKey, titleVisibility: .visible) {
            Button(L10n.tr("删除密钥"), role: .destructive) { deleteKey() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("密钥将从系统钥匙串中移除。"))
        }
        .onAppear { refreshKey() }
        .onChange(of: endpoint.wrappedValue) { _, _ in
            let notice = AIKeyDraftNotice.message(forClearedDraft: keyDraft)
            keyDraft = ""
            refreshKey()
            if let notice, status == nil { status = notice }
        }
        .onChange(of: isActive) { _, active in
            if active { refreshKey() } else { keyDraft = "" }
        }
        .onDisappear { keyDraft = "" }
    }

    private func refreshKey() {
        do {
            hasKey = try keychain.load(for: service, baseURL: endpoint.wrappedValue) != nil
            status = nil
        } catch { hasKey = false; status = StatusMessage(kind: .error, text: error.localizedDescription) }
    }

    private func saveKey() {
        do {
            try keychain.save(keyDraft, for: service, baseURL: endpoint.wrappedValue)
            keyDraft = ""
            refreshKey()
            if status == nil { status = StatusMessage(kind: .success, text: L10n.tr("密钥已保存")) }
        } catch { status = StatusMessage(kind: .error, text: error.localizedDescription) }
    }

    private func deleteKey() {
        do {
            try keychain.delete(for: service, baseURL: endpoint.wrappedValue)
            keyDraft = ""
            refreshKey()
            if status == nil { status = StatusMessage(kind: .success, text: L10n.tr("密钥已删除")) }
        } catch { status = StatusMessage(kind: .error, text: error.localizedDescription) }
    }
}
