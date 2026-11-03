import AppKit
import SwiftUI

/// Запрос на показ листа подключения хранилища.
struct VaultConnectionSheetRequest: Identifiable {
    let id = UUID()
    /// Открыть сразу эту запись («Изменить подключение…»).
    var preselectedID: UUID? = nil
    /// Вход в режим хранилища; сохранение уже выполнено листом.
    var onConnect: (VaultConnection) -> Void
    /// Подключение удалено: вызывающий закрывает вкладки и чистит локальные файлы.
    var onDeleted: (UUID) -> Void = { _ in }
}

/// Черновик формы. Порты — строки, чтобы пустой ввод и «abc» не превращались в 0. Токен в `VaultConnection` не входит.
private struct VaultConnectionDraft: Equatable {
    var name = L10n.tr("第二大脑")
    var useSSH = true
    var host = ""
    var user = ""
    var sshPort = "22"
    var identityFile = ""
    var remoteAPIPort = "8765"
    var baseURL = VaultConnection.defaultBaseURL
    var token = ""
    var hiddenRoots: [String] = []

    init() {}

    init(connection: VaultConnection) {
        name = connection.name
        baseURL = connection.baseURL
        hiddenRoots = connection.hiddenRoots
        if let tunnel = connection.tunnel {
            useSSH = true
            host = tunnel.host
            user = tunnel.user
            sshPort = String(tunnel.sshPort)
            identityFile = tunnel.identityFile ?? ""
            remoteAPIPort = String(tunnel.remoteAPIPort)
        } else {
            useSSH = false
        }
    }

    func connection(id: UUID) -> VaultConnection {
        let tunnel = useSSH ? VaultTunnelSettings(
            host: host, user: user,
            sshPort: Int(sshPort.trimmingCharacters(in: .whitespaces)) ?? 0,
            identityFile: identityFile,
            remoteAPIPort: Int(remoteAPIPort.trimmingCharacters(in: .whitespaces)) ?? 0) : nil
        return VaultConnection(id: id, name: name, baseURL: baseURL, tunnel: tunnel, hiddenRoots: hiddenRoots)
    }

    /// Поля, от которых зависит результат проверки подключения.
    var checkKey: [String] { [String(useSSH), host, user, sshPort, identityFile, remoteAPIPort, baseURL, token] }
}

private enum VaultCheckState: Equatable {
    case idle, running, result(StatusMessage)
}

struct VaultConnectionSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: VaultConnectionSheetRequest
    /// Закрывает лист (окно листа держит `AppState`).
    let close: () -> Void
    @ObservedObject var store: VaultConnectionStore

    @State private var selection: UUID?
    @State private var newID = UUID()
    @State private var draft = VaultConnectionDraft()
    @State private var hasSavedToken = false
    /// Есть ли сохранённый токен по id: Связка ключей читается один раз за показ листа, а не при каждой смене строки.
    @State private var savedTokenCache: [UUID: Bool] = [:]
    /// Файл ключа не найден; обновляется при потере фокуса поля, а не на каждый символ.
    @State private var identityMissing = false
    @State private var touched: Set<VaultConnectionField> = []
    @State private var attempted = false
    @State private var checkState: VaultCheckState = .idle
    @State private var checkedRoots: [String]?
    @State private var showCopyCommand = false
    @State private var recoveryHint: String?
    @State private var saveError: String?
    @State private var confirmDelete = false
    @State private var rootsExpanded = false
    @State private var checkTask: Task<Void, Never>?
    @FocusState private var focus: VaultConnectionField?

    init(request: VaultConnectionSheetRequest, close: @escaping () -> Void, store: VaultConnectionStore? = nil) {
        self.request = request
        self.close = close
        self.store = store ?? VaultConnectionStore.shared
    }

    private var currentID: UUID { selection ?? newID }
    private var isRunning: Bool { checkState == .running }
    private var selectedConnection: VaultConnection? { store.connections.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.tr("笔记库连接"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("vault.connection.title")
            HStack(alignment: .top, spacing: 12) {
                sidebar.frame(width: 190)
                Divider()
                ScrollView { form.padding(.trailing, 4) }
            }
            if let saveError { StatusMessageView(kind: .error, text: saveError).frame(maxWidth: .infinity, alignment: .leading) }
            footer
        }
        .padding(16)
        .frame(width: 720, height: 560)
        .onExitCommand { closeSheet() }
        .onAppear {
            select(request.preselectedID.flatMap { id in store.connections.contains { $0.id == id } ? id : nil }
                   ?? store.connections.first?.id)
            DispatchQueue.main.async { focus = selection == nil && draft.useSSH ? .host : .name }
        }
        .onDisappear { checkTask?.cancel() }
        .onChange(of: focus) { old, _ in
            // Ошибка поля показывается после ухода из него, а не пока человек печатает.
            guard let old else { return }
            touched.insert(old)
            if old == .identityFile { updateIdentityMissing() }
        }
        .onChange(of: draft.checkKey) { _, _ in
            resetCheck()
            saveError = nil
        }
        .confirmationDialog(L10n.tr("删除连接“%@”？", selectedConnection?.name ?? ""), isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button(L10n.tr("删除连接"), role: .destructive) { deleteSelected() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("令牌将从系统钥匙串中移除，连接设置也会删除。"))
        }
    }

    // MARK: Список подключений

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("已保存的连接")).font(.subheadline).foregroundStyle(.secondary)
            if let message = store.issueMessage {
                StatusMessageView(kind: store.isReadOnly ? .error : .info, text: message)
            }
            List(selection: Binding(get: { selection }, set: { select($0) })) {
                ForEach(store.connections) { connection in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.name).lineLimit(1)
                        Text(subtitle(connection)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(Optional(connection.id))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(connection.name), \(subtitle(connection))")
                }
                Label(L10n.tr("新建连接"), systemImage: "plus")
                    .tag(Optional<UUID>.none)
                    .accessibilityLabel(L10n.tr("新建连接"))
            }
            .accessibilityIdentifier("vault.connection.list")
        }
    }

    private func subtitle(_ connection: VaultConnection) -> String {
        if let tunnel = connection.tunnel { return "\(tunnel.user)@\(tunnel.host)" }
        return connection.baseURL
    }

    // MARK: Форма

    private func fieldError(_ field: VaultConnectionField) -> String? {
        guard attempted || touched.contains(field) else { return nil }
        return issues()[field]
    }

    /// Ошибки формы по полям: настройки подключения и обязательный токен.
    private func issues(includingToken: Bool = true) -> [VaultConnectionField: String] {
        var result: [VaultConnectionField: String] = [:]
        for issue in draft.connection(id: currentID).normalized.validate() where result[issue.field] == nil {
            result[issue.field] = issue.message
        }
        let trimmedToken = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tokenIssue = VaultConnection.tokenIssue(trimmedToken) {
            result[.token] = tokenIssue.message
        } else if includingToken, trimmedToken.isEmpty, !hasSavedToken {
            result[.token] = L10n.tr("请输入访问令牌")
        }
        return result
    }

    private static let fieldOrder: [VaultConnectionField] = [.name, .host, .user, .sshPort, .identityFile, .remoteAPIPort, .baseURL, .token]

    @ViewBuilder
    private func errorLine(_ field: VaultConnectionField) -> some View {
        if let message = fieldError(field) { StatusMessageView(kind: .error, text: message) }
    }

    private var form: some View {
        Form {
            TextField(L10n.tr("连接名称"), text: $draft.name)
                .focused($focus, equals: .name)
                .accessibilityIdentifier("vault.connection.name")
            errorLine(.name)
            Toggle(L10n.tr("通过 SSH 连接"), isOn: $draft.useSSH)
                .accessibilityIdentifier("vault.connection.ssh")
            if draft.useSSH {
                TextField(L10n.tr("SSH 服务器"), text: $draft.host)
                    .focused($focus, equals: .host)
                    .accessibilityIdentifier("vault.connection.host")
                errorLine(.host)
                TextField(L10n.tr("SSH 用户名"), text: $draft.user)
                    .focused($focus, equals: .user)
                    .accessibilityIdentifier("vault.connection.user")
                errorLine(.user)
                TextField(L10n.tr("SSH 端口"), text: $draft.sshPort)
                    .frame(width: 90)
                    .focused($focus, equals: .sshPort)
                    .accessibilityIdentifier("vault.connection.sshPort")
                errorLine(.sshPort)
                TextField(L10n.tr("SSH 密钥文件"), text: $draft.identityFile)
                    .focused($focus, equals: .identityFile)
                    .accessibilityHint(L10n.tr("可选；留空则使用 ~/.ssh/config 和 ssh-agent 中的密钥"))
                    .accessibilityIdentifier("vault.connection.identity")
                Text(L10n.tr("可选；留空则使用 ~/.ssh/config 和 ssh-agent 中的密钥"))
                    .font(.caption).foregroundStyle(.secondary)
                errorLine(.identityFile)
                if let warning = identityWarning { StatusMessageView(kind: .info, text: warning) }
                TextField(L10n.tr("服务器上的 API 端口"), text: $draft.remoteAPIPort)
                    .frame(width: 90)
                    .focused($focus, equals: .remoteAPIPort)
                    .accessibilityIdentifier("vault.connection.remotePort")
                errorLine(.remoteAPIPort)
            } else {
                TextField(L10n.tr("笔记库地址"), text: $draft.baseURL)
                    .focused($focus, equals: .baseURL)
                    .accessibilityIdentifier("vault.connection.address")
                errorLine(.baseURL)
            }
            HStack {
                SecureField(L10n.tr("访问令牌"), text: $draft.token)
                    .focused($focus, equals: .token)
                    .accessibilityHint(hasSavedToken ? L10n.tr("已保存令牌；留空则不更改") : "")
                    .accessibilityIdentifier("vault.connection.token")
                Button(L10n.tr("粘贴")) { paste() }
                    .accessibilityLabel(L10n.tr("粘贴令牌"))
                    .accessibilityIdentifier("vault.connection.paste")
            }
            if hasSavedToken && draft.token.isEmpty {
                Text(L10n.tr("已保存令牌；留空则不更改")).font(.caption).foregroundStyle(.secondary)
            }
            errorLine(.token)
            checkBlock
            rootsBlock
        }
        .formStyle(.columns)
    }

    /// Мягкое предупреждение: ssh продолжит с ключами из агента, поэтому «Подключить» не блокируется.
    private var identityWarning: String? {
        identityMissing ? L10n.tr("未找到密钥文件，将改用 ssh-agent 中的密钥") : nil
    }

    private func updateIdentityMissing() {
        let path = draft.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        identityMissing = !path.isEmpty && !path.contains(where: \.isNewline)
            && !FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    private var checkBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(L10n.tr("检查连接")) { startCheck() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isRunning)
                    .accessibilityIdentifier("vault.connection.check")
                if isRunning {
                    if !reduceMotion {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(L10n.tr("正在检查连接…"))
                    }
                    Text(L10n.tr("正在检查连接…")).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if case .result(let message) = checkState {
                HStack(alignment: .firstTextBaseline) {
                    StatusMessageView(kind: message.kind, text: message.text)
                    if showCopyCommand {
                        Button(L10n.tr("复制命令")) { copyCommand() }
                    }
                }
                .accessibilityIdentifier("vault.connection.result")
                if let recoveryHint { StatusMessageView(kind: .info, text: recoveryHint) }
            }
        }
    }

    private var rootsBlock: some View {
        DisclosureGroup(isExpanded: $rootsExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                if let roots = checkedRoots {
                    Text(L10n.tr("未勾选的分区不会在目录树中显示，也无法打开"))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(roots, id: \.self) { root in
                                Toggle(root, isOn: Binding(
                                    get: { !draft.hiddenRoots.contains(root) },
                                    set: { shown in
                                        if shown { draft.hiddenRoots.removeAll { $0 == root } }
                                        else if !draft.hiddenRoots.contains(root) { draft.hiddenRoots.append(root) }
                                    }))
                                .accessibilityLabel(root)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } else {
                    Text(L10n.tr("检查连接后可选择要隐藏的分区")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("vault.connection.roots")
        } label: {
            HStack {
                Text(L10n.tr("隐藏分区"))
                Spacer()
                Text(L10n.tr("已隐藏：%d", draft.hiddenRoots.count)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        HStack {
            if selection != nil {
                Button(L10n.tr("删除连接"), role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("vault.connection.delete")
            }
            Spacer()
            Button(L10n.tr("关闭")) { closeSheet() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("vault.connection.close")
            Button(L10n.tr("连接笔记库")) { connect() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning)
                .accessibilityIdentifier("vault.connection.connect")
        }
    }

    // MARK: Действия

    private func closeSheet() {
        checkTask?.cancel()
        draft.token = ""
        close()
    }

    private func select(_ id: UUID?) {
        checkTask?.cancel()
        selection = id
        resetCheck()
        touched = []
        attempted = false
        saveError = nil
        rootsExpanded = false
        if let connection = store.connections.first(where: { $0.id == id }) {
            draft = VaultConnectionDraft(connection: connection)
            if let cached = savedTokenCache[connection.id] {
                hasSavedToken = cached
            } else {
                hasSavedToken = ((try? store.token(for: connection.id)) ?? nil)?.isEmpty == false
                savedTokenCache[connection.id] = hasSavedToken
            }
            updateIdentityMissing()
        } else {
            identityMissing = false
            selection = nil
            newID = UUID()
            draft = VaultConnectionDraft()
            hasSavedToken = false
        }
    }

    private func resetCheck() {
        checkTask?.cancel()
        checkTask = nil
        checkState = .idle
        checkedRoots = nil
        showCopyCommand = false
        recoveryHint = nil
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        draft.token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyCommand() {
        guard draft.useSSH else { return }
        let settings = draft.connection(id: currentID).normalized.tunnel
        guard let settings else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(VaultTunnelArguments.manualCommand(settings: settings), forType: .string)
        announce(L10n.tr("命令已复制"))
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// Показывает ошибки у полей, ставит фокус на первое проблемное поле. true — ошибок нет.
    private func validateForm(includingToken: Bool) -> Bool {
        attempted = true
        let found = issues(includingToken: includingToken)
        guard let field = Self.fieldOrder.first(where: { found[$0] != nil }) else { return true }
        focus = field
        if let message = found[field] { announce(message) }
        return false
    }

    private func startCheck() {
        guard !isRunning, validateForm(includingToken: false) else { return }
        var token = draft.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty, selection != nil { token = ((try? store.token(for: currentID)) ?? nil) ?? "" }
        guard !token.isEmpty else {
            focus = .token
            announce(L10n.tr("请输入访问令牌"))
            return
        }
        resetCheck()
        checkState = .running
        let connection = draft.connection(id: currentID).normalized
        checkTask = Task { await performCheck(connection, token: token) }
    }

    /// Проверка ничего не сохраняет; временный туннель гасится при любом исходе.
    @MainActor
    private func performCheck(_ connection: VaultConnection, token: String) async {
        var tunnel: VaultTunnel?
        defer { tunnel?.stop() }
        func fail(_ text: String, focusing field: VaultConnectionField? = nil) {
            guard !Task.isCancelled else { return }
            checkState = .result(StatusMessage(kind: .error, text: text))
            if let field { focus = field }
            announce(text)
        }
        do {
            let url: URL
            if let settings = connection.tunnel {
                let running = VaultTunnel(settings: settings)
                tunnel = running
                let port = try await running.start()
                guard let local = URL(string: "http://127.0.0.1:\(port)") else { throw VaultClientError.invalidResponse }
                url = local
            } else {
                url = try VaultAddressRule.check(connection.baseURL)
            }
            let client = VaultClient(baseURL: url, token: token)
            try await client.health()
            let page = try await client.tree(path: "", depth: 0, pageSize: 1000, pageToken: nil)
            try Task.checkCancellation()
            let roots = page.entries.filter { $0.kind == .directory }.map(\.path).sorted()
            let text = L10n.tr("已连接，分区数：%d", roots.count)
            checkedRoots = roots
            checkState = .result(StatusMessage(kind: .success, text: text))
            announce(text)
        } catch is CancellationError {
            return
        } catch let failure as VaultTunnelFailure {
            guard !Task.isCancelled else { return }
            fail(failure.userMessage)
            showCopyCommand = failure == .unknownHostKey
            recoveryHint = failure.recoveryHint
        } catch let issue as VaultSettingsIssue {
            fail(issue.message, focusing: issue.field)
        } catch let error as VaultClientError {
            switch error {
            case .notFound, .invalidResponse: fail(L10n.tr("此地址上没有笔记库服务"))
            case .unauthorized: fail(error.userMessage, focusing: .token)
            default: fail(error.userMessage)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func connect() {
        guard !isRunning, validateForm(includingToken: true) else { return }
        do {
            let connection = draft.connection(id: currentID)
            try store.save(connection, token: draft.token)
            let saved = store.connections.first { $0.id == currentID } ?? connection.normalized
            draft.token = ""
            checkTask?.cancel()
            request.onConnect(saved)
            close()
        } catch let error as VaultConnectionStoreError {
            if case .invalid(let issue) = error { focus = issue.field }
            saveError = error.localizedDescription
        } catch {
            saveError = L10n.tr("无法保存连接")
        }
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        do {
            try store.delete(id)
            savedTokenCache[id] = nil
            request.onDeleted(id)
            select(nil)
        } catch let error as VaultConnectionStoreError {
            saveError = error.localizedDescription
        } catch {
            saveError = L10n.tr("无法保存连接")
        }
    }
}
