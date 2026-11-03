import AppKit
import SwiftUI

/// Боковая панель режима хранилища: вместо библиотеки показывает имена заметок сервера (только имена, в памяти).
struct VaultSidebarView: View {
    @ObservedObject var session: VaultSession
    let appState: AppState
    let windowManager: WindowManager

    var body: some View {
        VaultSidebarContent(session: session, catalog: session.catalog, search: appState.vaultSearch,
                            appState: appState, windowManager: windowManager)
    }
}

private struct VaultSidebarContent: View {
    @ObservedObject var session: VaultSession
    @ObservedObject var catalog: VaultCatalog
    @ObservedObject var search: VaultSearchController
    let appState: AppState
    let windowManager: WindowManager

    @StateObject private var searchNavigation = FolderListNavigation()
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    /// Сегодняшняя дата для строки «Сегодня»: обновляется после полуночи.
    @State private var today = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hidden: Set<String> { Set(session.connection.hiddenRoots) }
    private var pinned: [String] { VaultPresentation.visiblePinned(session.pinnedPaths, hidden: hidden) }
    @State private var unsentExpanded = false
    @State private var conflictsExpanded = true
    private var unsentPaths: [String] { session.unsentSummary.attentionUnsent().map(\.serverPath) }
    private var conflictPaths: [String] { session.unsentSummary.conflicts.map(\.serverPath) }
    /// Строка раздела «Неотправленное» или «Конфликты» для заметки: слова состояния и допустимые действия.
    private func summaryRow(_ path: String) -> VaultUnsentRow? {
        (session.unsentSummary.unsent + session.unsentSummary.conflicts).first { $0.serverPath == path }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusLine
            stateAttention
            VaultSearchField(controller: search, navigation: searchNavigation,
                             focusEditor: { VaultSearchFocus.focusEditor(in: appState.hostWindow) })
            list
        }
        .onChange(of: appState.vaultNote?.path) { _, path in selection = path.map { Self.rowID("tree", $0) } }
        .onChange(of: session.isOnline) { _, online in search.connectivityChanged(isOnline: online) }
        .onChange(of: catalog.isFullListingLoaded) { _, _ in search.refreshNames() }
        .onChange(of: search.results) { _, results in searchNavigation.setOrder(results.map(VaultSearchRowView.rowID)) }
        .onAppear { selection = appState.vaultNote?.path.map { Self.rowID("tree", $0) } }
        .onReceive(appState.vaultUpload.$revealRequest.compactMap { $0 }) { request in
            switch request {
            case .unsent: unsentExpanded = true
            case .conflicts: conflictsExpanded = true
            }
        }
        // Раздел с отказом сервера раскрывается сам: человек должен это увидеть.
        .onChange(of: session.unsentSummary.unsent.contains { if case .rejected = $0.kind { true } else { false } }) { _, hasRejected in
            if hasRejected { unsentExpanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = Date() }
    }

    // MARK: Идентификаторы строк

    private static let todayID = "today"

    /// Одна заметка может стоять в нескольких разделах: идентификатор строки включает раздел, путь берётся после «|».
    static func rowID(_ section: String, _ path: String) -> String { section + "|" + path }

    private static func path(ofRow id: String) -> String? {
        guard let index = id.firstIndex(of: "|") else { return nil }
        return String(id[id.index(after: index)...])
    }

    // MARK: Заголовок и состояние

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "cloud").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(L10n.tr("笔记库“%@”", session.connection.name))
                .font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                Task { await session.checkAndReload() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L10n.tr("立即检查更新"))
                .accessibilityLabel(L10n.tr("立即检查更新"))
            Menu {
                Button(L10n.tr("笔记库设置…")) { appState.presentVaultConnectionSheet(preselectedID: session.connection.id) }
                Button(L10n.tr("关闭笔记库")) { Task { await windowManager.leaveVault() } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L10n.tr("笔记库菜单"))
        }
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
    }

    /// Цвет не единственный признак: рядом всегда слово состояния и значок своей формы.
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: session.status.symbolName).font(.caption).accessibilityHidden(true)
                Text(session.statusText).font(.caption)
            }
            .foregroundStyle(session.status == .online ? Color.secondary : Color.primary)
            if let issue = session.connectionIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    /// Повреждённое или не записывающееся локальное состояние: сообщение и действие, пока пользователь не подтвердит.
    @ViewBuilder
    private var stateAttention: some View {
        if session.needsStateAttention {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.isStateBlocked ? L10n.tr("无法保存本地状态，新笔记暂时无法打开") : L10n.tr("笔记库的本地状态已损坏"))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("处理…")) { appState.confirmVaultStateAttention() }
                    .buttonStyle(.link).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Список

    private var list: some View {
        List(selection: $selection) {
            if !search.isActive {
                todayRow
                if !pinned.isEmpty {
                    Section(L10n.tr("固定的笔记")) {
                        ForEach(pinned, id: \.self) { noteRow($0, showsFolder: true, section: "pin") }
                    }
                }
                Section(L10n.tr("分区")) {
                    if catalog.roots.isEmpty { emptyState }
                    ForEach(catalog.roots, id: \.path) { entry in
                        VaultTreeBranch(entry: entry, session: session, catalog: catalog, expanded: $expanded,
                                        row: { noteRow($0, showsFolder: $1, section: "tree") })
                    }
                }
                places
            } else {
                Section(L10n.tr("搜索结果")) {
                    VaultSearchStateView(controller: search)
                    ForEach(search.results) { result in
                        VaultSearchRowView(controller: search, result: result, query: search.query, navigation: searchNavigation)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowSeparator(.hidden)
                    }
                    VaultSearchFooter(controller: search)
                }
                places
            }
        }
        .listStyle(.sidebar)
        .transaction { if reduceMotion { $0.animation = nil } }
        // Стрелки только двигают выбор; открывают Return и двойной щелчок.
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, ids.count == 1, let path = Self.path(ofRow: id) { rowMenu(path) }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            if id == Self.todayID { windowManager.openVaultDailyNote(from: appState) }
            else if let path = Self.path(ofRow: id) { windowManager.openVaultNote(path: path, from: appState) }
        }
    }

    /// В папке `daily` уже загружен список, а сегодняшней заметки в нём нет: сервер ещё ничего не записал за день.
    private var isTodayMissing: Bool {
        guard let children = catalog.childrenByPath[VaultDailyNote.folder] else { return false }
        return !children.contains { $0.path == VaultDailyNote.path(for: today) }
    }

    @ViewBuilder
    private var todayRow: some View {
        let date = VaultDailyNote.date(fromPath: VaultDailyNote.path(for: today)) ?? ""
        if isTodayMissing {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(L10n.tr("今天"), systemImage: "sun.max")
                    Spacer()
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.tr("今天还没有记录")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("记录想法…")) { appState.presentVaultCapture() }
                    .buttonStyle(.link).font(.caption)
            }
            .accessibilityElement(children: .combine)
            .tag(Self.todayID)
        } else {
            HStack {
                Label(L10n.tr("今天"), systemImage: "sun.max")
                Spacer()
                Text(date).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .tag(Self.todayID)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.tr("打开今天的笔记"))
            .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if VaultPresentation.isCatalogEmptyBecauseOffline(rootsCount: catalog.roots.count, isOnline: session.isOnline, isConnecting: session.isConnecting) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("没有连接。连接恢复后将显示列表")).font(.callout).foregroundStyle(.secondary)
                Button(L10n.tr("重试")) { session.connectivityMayHaveChanged(); Task { await session.checkAndReload() } }
            }
        } else if session.isConnecting {
            Text(L10n.tr("连接中")).font(.callout).foregroundStyle(.secondary)
        } else if let issue = session.connectionIssue {
            // Ошибка не из-за сети (доступ, сервер): список не пуст по существу, а не загрузился.
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("无法加载列表")).font(.callout)
                Text(issue).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("重试")) { session.connectivityMayHaveChanged(); Task { await session.checkAndReload() } }
            }
        } else {
            Text(L10n.tr("笔记库中还没有笔记")).font(.callout).foregroundStyle(.secondary)
            Text(L10n.tr("用“记录想法”（⌃⌥⌘N）创建第一条")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var places: some View {
        if !unsentPaths.isEmpty || !conflictPaths.isEmpty {
            Section(L10n.tr("位置")) {
                if !unsentPaths.isEmpty {
                    DisclosureGroup(isExpanded: $unsentExpanded) {
                        ForEach(unsentPaths, id: \.self) { noteRow($0, showsFolder: true, section: "unsent") }
                    } label: {
                        Label(L10n.tr("未上传的笔记"), systemImage: "arrow.up.circle").badge(unsentPaths.count)
                    }
                }
                if !conflictPaths.isEmpty {
                    DisclosureGroup(isExpanded: $conflictsExpanded) {
                        ForEach(conflictPaths, id: \.self) { noteRow($0, showsFolder: true, section: "conflict") }
                    } label: {
                        Label(L10n.tr("冲突的笔记"), systemImage: "exclamationmark.triangle").badge(conflictPaths.count)
                    }
                }
            }
        }
    }

    // MARK: Строка заметки

    func noteRow(_ path: String, showsFolder: Bool, section: String) -> some View {
        VaultNoteRow(path: path, isPinned: session.isPinned(path), state: session.noteStates[path], showsFolder: showsFolder,
                     detail: summaryRow(path)?.statusText)
            .tag(Self.rowID(section, path))
    }

    @ViewBuilder
    private func rowMenu(_ path: String) -> some View {
        Button(L10n.tr("打开")) { windowManager.openVaultNote(path: path, from: appState) }
        Button(L10n.tr("在新标签页中打开")) { windowManager.openVaultNote(path: path, from: appState, inNewTab: true) }
        Divider()
        Button(session.isPinned(path) ? L10n.tr("取消固定") : L10n.tr("固定")) { session.togglePin(path) }
        Button(L10n.tr("复制 wiki 链接")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("[[\(VaultPresentation.displayName(ofPath: path))]]", forType: .string)
        }
        if let row = summaryRow(path) {
            Divider()
            if row.canSendNow { Button(L10n.tr("立即发送")) { appState.sendVaultNow(path) } }
            if row.canShowConflict { Button(L10n.tr("显示冲突…")) { appState.presentVaultConflict(serverPath: path) } }
            if row.canDiscard { Button(L10n.tr("撤销我的修改…")) { appState.discardVaultChanges(serverPath: path) } }
        }
    }
}

private struct VaultNoteRow: View {
    let path: String
    let isPinned: Bool
    let state: VaultNoteSyncState?
    let showsFolder: Bool
    /// Слова состояния из «Неотправленного» (ждёт отправки, нет связи, причина отказа); без них — по состоянию заметки.
    var detail: String?

    private var isServerManaged: Bool { VaultServerRules.isServerManaged(path) }

    private var stateText: String? {
        if let detail { return detail }
        switch state {
        case .modified, .uploading: L10n.tr("未上传")
        case .conflict: L10n.tr("冲突")
        case .newerOnServer: L10n.tr("服务器上有更新")
        case .deletedOnServer: L10n.tr("文件已在服务器上删除")
        default: nil
        }
    }

    private var folder: String? {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isPinned ? "star.fill" : "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(VaultPresentation.displayName(ofPath: path)).lineLimit(1).truncationMode(.middle)
                if showsFolder, let folder {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if isServerManaged {
                    Text(L10n.tr("由服务器更新")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isServerManaged { Image(systemName: "gearshape").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) }
            if let stateText { Text(stateText).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([VaultPresentation.displayName(ofPath: path), isPinned ? L10n.tr("已固定") : nil,
                             isServerManaged ? L10n.tr("由服务器更新") : nil, stateText]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// Папка или заметка раздела: содержимое папки запрашивается при раскрытии.
private struct VaultTreeBranch<Row: View>: View {
    let entry: VaultTreeEntry
    @ObservedObject var session: VaultSession
    @ObservedObject var catalog: VaultCatalog
    @Binding var expanded: Set<String>
    let row: (String, Bool) -> Row

    private var isServerManaged: Bool { VaultServerRules.isServerManaged(entry.path + "/") }

    var body: some View {
        if entry.kind == .directory {
            let children = catalog.childrenByPath[entry.path]
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(entry.path) },
                set: { isOpen in
                    if isOpen {
                        expanded.insert(entry.path)
                        Task { await session.loadFolder(entry.path) }
                    } else {
                        expanded.remove(entry.path)
                    }
                })) {
                if let children {
                    ForEach(children, id: \.path) { child in
                        VaultTreeBranch(entry: child, session: session, catalog: catalog, expanded: $expanded, row: row)
                    }
                } else {
                    Text(L10n.tr("正在加载")).font(.callout).foregroundStyle(.secondary)
                }
            } label: {
                HStack(spacing: 4) {
                    Label(entry.name, systemImage: "folder")
                    if isServerManaged {
                        Image(systemName: "gearshape").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(L10n.tr("由服务器更新")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .badge(children?.count ?? 0)
            }
            .accessibilityLabel(children.map { L10n.tr("文件夹 %@，%lld 项", entry.name, $0.count) } ?? L10n.tr("文件夹 %@", entry.name))
        } else if entry.path.lowercased().hasSuffix(".md") {
            row(entry.path, false)
        }
    }
}
