import SwiftUI

struct JinaSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jina").font(.headline)
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
    @State private var message: String?
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(service == .search ? L10n.tr("Jina 搜索") : L10n.tr("Jina 网页读取"), isOn: enabled)
            LabeledContent(L10n.tr("完整接口地址")) {
                TextField(service == .search ? "https://s.jina.ai/search" : "https://r.jina.ai/", text: endpoint)
            }
            SecureField(L10n.tr("输入新密钥"), text: $keyDraft)
            HStack {
                Button(L10n.tr("保存密钥")) { saveKey() }.disabled(keyDraft.isEmpty)
                Button(L10n.tr("删除密钥")) { deleteKey() }.disabled(!hasKey)
                Text(keyDraft.isEmpty
                     ? (hasKey ? L10n.tr("已保存密钥") : L10n.tr("未保存密钥"))
                     : L10n.tr("密钥更改尚未保存"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { refreshKey() }
        .onChange(of: endpoint.wrappedValue) { _, _ in keyDraft = ""; refreshKey() }
        .onChange(of: isActive) { _, active in
            if active { refreshKey() } else { keyDraft = "" }
        }
        .onDisappear { keyDraft = "" }
    }

    private func refreshKey() {
        do {
            hasKey = try keychain.load(for: service, baseURL: endpoint.wrappedValue) != nil
            message = nil
        } catch { hasKey = false; message = error.localizedDescription }
    }

    private func saveKey() {
        do {
            try keychain.save(keyDraft, for: service, baseURL: endpoint.wrappedValue)
            keyDraft = ""
            refreshKey()
        } catch { message = error.localizedDescription }
    }

    private func deleteKey() {
        do {
            try keychain.delete(for: service, baseURL: endpoint.wrappedValue)
            keyDraft = ""
            refreshKey()
        } catch { message = error.localizedDescription }
    }
}
